{ config, lib, pkgs, ... }:

# Claude Code status line, built by Nix instead of hand-edited in $HOME.
#
# The status line is a command Claude Code runs on every render, feeding it a
# JSON blob on stdin and printing whatever comes back. Configuring it by hand
# means a script in ~/.claude that nothing tracks and a settings.json key that
# a fresh machine does not have — exactly the "reconfigure it again later"
# problem this module exists to remove.
#
# Two halves, because the two files have different owners:
#
#   - the script itself is pure derivation output at a stable path under /etc,
#     so it is versioned with the repo and updated by nixos-rebuild;
#   - ~/.claude/settings.json belongs to Claude Code, which writes its own keys
#     there (theme, notification prefs, and more over time). It is therefore
#     merged into rather than replaced — see the activation script below.

let
  user = "david";
  home = config.users.users.${user}.home;

  # Interpolated so the script never depends on the caller's PATH. A status
  # line that silently prints nothing because jq was not found is a miserable
  # thing to debug.
  jq = "${pkgs.jq}/bin/jq";
  git = "${pkgs.git}/bin/git";
  whoami = "${pkgs.coreutils}/bin/whoami";

  # The host is known at build time, so ask Nix rather than shelling out to
  # `hostname` on every single render.
  host = config.networking.hostName;

  # Mirrors the system PS1 from /etc/bashrc:
  #   PS1="\n\[\033[1;32m\][\u@\h:\w]\$\[\033[0m\] "
  # rendered without the trailing "$", then the git branch, the current agent,
  # context-window usage and weekly (7-day) rate-limit usage.
  #
  # Deliberately NOT writeShellApplication: that adds `set -euo pipefail`, and
  # this script is built to tolerate failure everywhere. Every field except
  # workspace.current_dir is optional in the payload, jq exits non-zero on
  # malformed input, and git fails outside a repo — under strict mode each of
  # those aborts the script and the user gets an empty status line instead of
  # a degraded one.
  statusline = pkgs.writeShellScript "claude-statusline" ''
    input=$(${pkgs.coreutils}/bin/cat)

    GREEN=$'\033[1;32m'
    YELLOW=$'\033[1;33m'
    RED=$'\033[1;31m'
    DIM=$'\033[2m'
    RESET=$'\033[0m'

    # `// empty` rather than `// ""` so a missing key yields nothing at all —
    # the literal string "null" leaking into a status line is the classic bug.
    jqr() { printf '%s' "$input" | ${jq} -r "$1" 2>/dev/null; }

    cwd=$(jqr '.workspace.current_dir // empty')
    [ -n "$cwd" ] || cwd=$PWD

    # Abbreviate $HOME with ~, exactly as \w does in PS1.
    case "$cwd" in
      "$HOME") dir="~" ;;
      "$HOME"/*) dir="~''${cwd#"$HOME"}" ;;
      *) dir="$cwd" ;;
    esac

    user=$(${whoami} 2>/dev/null)

    branch=""
    if ${git} -C "$cwd" --no-optional-locks rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      b=$(${git} -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null)
      [ -n "$b" ] && branch=" ($b)"
    fi

    out="''${GREEN}[''${user}@${host}:''${dir}]''${RESET}''${branch}"

    # The whole point of colouring these is noticing when to compact, so the
    # thresholds sit where there is still room to act: amber with a fifth of
    # the window left, red with a tenth.
    colour_for() {
      case "$1" in
        ""|*[!0-9]*) return ;;
      esac
      if [ "$1" -lt 60 ]; then
        printf '%s' "$GREEN"
      elif [ "$1" -lt 80 ]; then
        printf '%s' "$YELLOW"
      else
        printf '%s' "$RED"
      fi
    }

    segments=()

    # .agent.name is only present while an agent is active; fall back to the
    # model so the segment reads correctly either way.
    agent=$(jqr '.agent.name // .model.display_name // empty')
    [ -n "$agent" ] && segments+=("''${DIM}''${agent}''${RESET}")

    # used_percentage is already 0-100, not a fraction.
    ctx_raw=$(jqr '.context_window.used_percentage // empty')
    if [ -n "$ctx_raw" ]; then
      ctx=$(printf '%.0f' "$ctx_raw" 2>/dev/null)
      if [ -n "$ctx" ]; then
        c=$(colour_for "$ctx")
        segments+=("''${DIM}ctx ''${RESET}''${c}''${ctx}%''${RESET}")
      fi
    fi

    # The two rate-limit windows are independent: the five-hour bucket is what
    # stops you mid-afternoon, the weekly one is what stops you on Thursday.
    # Seeing only the weekly figure tells you nothing about the wall you are
    # about to hit in twenty minutes.
    fh_raw=$(jqr '.rate_limits.five_hour.used_percentage // empty')
    if [ -n "$fh_raw" ]; then
      fh=$(printf '%.0f' "$fh_raw" 2>/dev/null)
      if [ -n "$fh" ]; then
        c=$(colour_for "$fh")
        segments+=("''${DIM}5h ''${RESET}''${c}''${fh}%''${RESET}")
      fi
    fi

    # rate_limits is absent entirely on plans that do not report it, so this
    # segment has to disappear cleanly rather than render "wk n/a".
    wk_raw=$(jqr '.rate_limits.seven_day.used_percentage // empty')
    if [ -n "$wk_raw" ]; then
      wk=$(printf '%.0f' "$wk_raw" 2>/dev/null)
      if [ -n "$wk" ]; then
        c=$(colour_for "$wk")
        segments+=("''${DIM}wk ''${RESET}''${c}''${wk}%''${RESET}")
      fi
    fi

    if [ "''${#segments[@]}" -gt 0 ]; then
      joined="''${segments[0]}"
      for seg in "''${segments[@]:1}"; do
        joined="''${joined} ''${DIM}·''${RESET} ''${seg}"
      done
      out="''${out} ''${DIM}·''${RESET} ''${joined}"
    fi

    printf '%s' "''${out}''${RESET}"
    exit 0
  '';

  settingsFile = "${home}/.claude/settings.json";
in
{
  # Stable path, so settings.json can point at something that does not change
  # every time the script does. /etc is a symlink into the store, so a rebuild
  # swaps the target atomically and the next render picks it up.
  environment.etc."claude-code/statusline.sh" = {
    source = statusline;
    mode = "0555";
  };

  # settings.json is Claude Code's file, not ours: it writes theme,
  # notification preferences and whatever else it grows. So merge our one key
  # in rather than generating the file, and only write when the result differs
  # — an unconditional rewrite would churn the mtime on every rebuild and
  # could clobber a setting the app wrote seconds earlier.
  system.activationScripts.claudeStatusLine = {
    deps = [ "users" ];
    text = ''
      set -u
      settings="${settingsFile}"
      desired='${builtins.toJSON { type = "command"; command = "/etc/claude-code/statusline.sh"; }}'

      if [ ! -e "$settings" ]; then
        ${pkgs.coreutils}/bin/install -D -m 0644 \
          -o ${user} -g ${config.users.users.${user}.group} \
          /dev/null "$settings"
        printf '{}\n' > "$settings"
      fi

      # A settings.json that is not valid JSON is the user's problem to fix,
      # but it must not take the rebuild down with it.
      if ! ${jq} -e . "$settings" >/dev/null 2>&1; then
        echo "claude-code: $settings is not valid JSON, leaving statusLine alone" >&2
      else
        merged=$(${jq} --argjson sl "$desired" '.statusLine = $sl' "$settings")
        if [ "$merged" != "$(${pkgs.coreutils}/bin/cat "$settings")" ]; then
          printf '%s\n' "$merged" > "$settings.new"
          ${pkgs.coreutils}/bin/chown ${user}:${config.users.users.${user}.group} "$settings.new"
          ${pkgs.coreutils}/bin/chmod 0644 "$settings.new"
          ${pkgs.coreutils}/bin/mv "$settings.new" "$settings"
        fi
      fi
    '';
  };
}
