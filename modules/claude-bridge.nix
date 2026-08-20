{ config, lib, pkgs, ... }:

# A one-way bridge letting Hermes consult Claude Code for planning.
#
# Hermes runs on the local model for everything; when it hits a question where
# a frontier model is worth the money — an architecture decision, a design
# tradeoff, a plan worth a second opinion before implementing — it shells out
# to `claude -p` through the wrapper below.
#
# Why a wrapper rather than pointing Hermes at Anthropic directly: Hermes'
# `anthropic` provider reads CLAUDE_CODE_OAUTH_TOKEN as one of three accepted
# key variables. Putting a subscription token anywhere Hermes can see it would
# silently turn the whole agent into a Claude client billed to the Pro/Max
# plan, which is not what those credentials are for — Anthropic's position is
# that OAuth is for ordinary use of Claude Code itself, and that third-party
# applications calling the API should authenticate with an API key. Here, the
# token is read by the wrapper and exported only into the `claude` process, so
# Claude Code is the thing using it. It is deliberately NOT in
# /var/lib/hermes/env, and must not be moved there.
#
# Cost: consults spend the shared Pro/Max interactive limits — the same budget
# `5h`/`wk` track in the status line — rather than the separate Agent SDK
# credit. That is the intended tradeoff: this path is for occasional,
# deliberate consults. Anything autonomous and high-volume wants an API key
# and its own billing.

let
  # Read by the wrapper as the hermes user, so it is group-readable rather
  # than root-only. /var/lib/hermes/env can stay root:root 0600 because only
  # activation reads that one; this file has a different reader, which is the
  # whole lesson from the wpa_supplicant secrets file.
  tokenFile = "/var/lib/claude-bridge/env";
  group = "hermes";

  timeoutSecs = 300;

  consult = pkgs.writeShellScript "claude-consult" ''
    set -u

    TOKEN_FILE=${tokenFile}
    DIR=""

    usage() {
      cat >&2 <<'USAGE'
    usage: consult.sh [-d DIR] "question"

    Ask Claude Code a planning question. Read-only: it may read, grep and glob,
    and cannot edit anything. Pass -d to grant access to a directory the
    calling user can reach; otherwise include the context in the question.
    USAGE
      exit 64
    }

    while getopts ":d:h" opt; do
      case "$opt" in
        d) DIR=$OPTARG ;;
        h) usage ;;
        *) usage ;;
      esac
    done
    shift $((OPTIND - 1))

    [ "$#" -ge 1 ] || usage
    PROMPT=$*

    if [ ! -r "$TOKEN_FILE" ]; then
      echo "claude-consult: cannot read $TOKEN_FILE." >&2
      echo "Create it with a CLAUDE_CODE_OAUTH_TOKEN= line from 'claude setup-token'." >&2
      exit 2
    fi

    # The file is root-owned and only ever written by hand, so sourcing it is
    # safe; it exists to keep the token out of Hermes' own environment.
    set -a
    . "$TOKEN_FILE"
    set +a

    if [ -z "''${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
      echo "claude-consult: $TOKEN_FILE has no CLAUDE_CODE_OAUTH_TOKEN= line." >&2
      exit 2
    fi

    # Start somewhere the caller can actually read. Without this, claude
    # inherits the caller's cwd — and when Hermes (as the hermes user) is
    # invoked from a shell sitting in /home/david, that directory is 0700 and
    # unreadable, so the model looks around, finds nothing, and reports that
    # the file does not exist rather than that it could not look.
    if [ -n "$DIR" ]; then
      cd "$DIR" || { echo "claude-consult: cannot enter $DIR" >&2; exit 1; }
    elif cd /var/lib/hermes/workspace 2>/dev/null; then
      :
    else
      cd /tmp || exit 1
    fi

    # Read-only by construction. Planning does not need Write, Edit or Bash,
    # and withholding them means a consult cannot fight the local agent over
    # the same files — two agents writing one tree is a bad afternoon.
    set -- \
      -p "$PROMPT" \
      --allowed-tools Read,Grep,Glob \
      --permission-mode plan \
      --output-format text \
      --append-system-prompt 'You are being consulted by another agent for planning, not implementation. Answer the question directly and concisely. Give a recommendation rather than a survey of options, and say plainly when the honest answer is that you lack the context to judge. Do not attempt to edit files.'

    [ -n "$DIR" ] && set -- "$@" --add-dir "$DIR"
    [ -n "''${CONSULT_MODEL:-}" ] && set -- "$@" --model "$CONSULT_MODEL"

    # A hung consult must not hang the agent that called it.
    exec ${pkgs.coreutils}/bin/timeout ${toString timeoutSecs} \
      ${pkgs.claude-code}/bin/claude "$@"
  '';

  skill = ''
    ---
    name: claude-consult
    description: Consult Claude Code for architecture decisions, design tradeoffs and plan review, when a frontier model is worth the cost.
    version: 1.0.0
    license: MIT
    platforms: [linux]
    metadata:
      hermes:
        tags: [planning, architecture, review]
        category: local
        requires_toolsets: [terminal]
    ---

    # Consulting Claude for planning

    This box runs a local model for everything by default. `consult.sh` reaches
    a frontier model (Claude Code) instead. It costs real money from a personal
    subscription, so it is worth using well and worth not using casually.

    ## Call it

    ```bash
    /etc/claude-bridge/consult.sh "your question, with the context inline"
    /etc/claude-bridge/consult.sh -d /some/dir "question about that directory"
    ```

    It is read-only — it can read, grep and glob, and cannot edit anything. It
    returns prose on stdout. Each call is a fresh session with no memory of
    previous ones, so include the context that matters in the question itself.

    ## Reach for it when

    - An architecture or design decision has consequences that are expensive to
      reverse: a schema, a module boundary, a protocol, a data layout.
    - A plan is about to be implemented and a second opinion is cheaper than
      the rework: "here is what I intend to do, what breaks?"
    - The problem is unfamiliar and a wrong first move would cost real time.
    - A tradeoff needs judgement rather than recall, and being wrong is costly.

    ## Do not reach for it when

    - The local model can answer it. Most questions qualify.
    - It is a factual lookup, a syntax question, or something the repo already
      documents — read the repo instead.
    - You are midway through mechanical work. Finish it.
    - You have already consulted on this exact question. Re-asking a fresh
      session the same thing gets you a similar answer at full price.

    ## Ask it well

    Because the session is stateless, a bare question wastes the call. Include
    what was tried, what the constraints are, and what decision is actually
    pending. State the question you want answered, not the topic. "Should this
    live in a systemd unit or a tmpfiles rule, given it must run before
    wpa_supplicant?" beats "thoughts on ordering?".
  '';
in
{
  # Directory and secret ownership, corrected on every boot rather than left
  # to whoever created the file.
  systemd.tmpfiles.rules = [
    "d /var/lib/claude-bridge 0750 root ${group} -"
    "z ${tokenFile} 0640 root ${group} -"
  ];

  environment.etc."claude-bridge/consult.sh" = {
    source = consult;
    mode = "0555";
  };

  # Installed into HERMES_HOME by the module, so the skill is declarative and
  # survives a reinstall like everything else here.
  services.hermes-agent.hermesHomeFiles."skills/local/claude-consult/SKILL.md" = skill;
}
