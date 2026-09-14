{ config, lib, pkgs, ... }:

# Hermes Agent via the official NixOS module (services.hermes-agent).
#
# Managed mode: with this module, config is declarative. `hermes setup`,
# `hermes config edit/set`, and `hermes gateway install/uninstall` are
# BLOCKED at the CLI with a pointer back here. To change anything: edit
# this file, `sudo nixos-rebuild switch`.
#
# Mode: native (default). Hardened systemd unit, agent can only use tools
# on the Nix-provided PATH (add via extraPackages).
#
# Note the distinction, because the two are easy to conflate: the agent can
# RUN containers (podman, rootless — see extraPackages and the block after
# it), but it does not RUN INSIDE one. container.enable = true is the
# separate switch that puts Hermes itself in a container so it can apt/pip/
# npm install for itself; it is still off, and driving compose from in there
# would mean nested containers. Running a compose stack does not need it.

let
  # Pinned, not discovered. Rootless podman needs XDG_RUNTIME_DIR to point at
  # /run/user/<uid>, and that path has to be written into the unit at build
  # time. The obvious trick — systemd's %U specifier — does NOT work here:
  # for a system unit %U is the UID of the service MANAGER (root, 0), not the
  # one in User=, so it silently produced /run/user/0 and podman lost its
  # session bus. The uid was already 997 by dynamic allocation; naming it
  # changes nothing today and stops it drifting underneath this path later.
  hermesUid = 997;
in
{
  users.users.hermes.uid = hermesUid;

  services.hermes-agent = {
    enable = true;

    # Puts `hermes` on the system PATH and sets HERMES_HOME globally, so
    # your interactive CLI shares state (sessions, skills, cron, memory)
    # with the gateway service instead of creating a second ~/.hermes.
    addToSystemPackages = true;

    # NOTE: the module deep-merges these into $HERMES_HOME/config.yaml and
    # keeps every key it does not manage — which is what lets the TUI and
    # `hermes config set` write there too. The corollary bites: *deleting* a
    # setting here does not delete it from config.yaml. When
    # compression.summary_model was moved to auxiliary.compression below, the
    # old key sat on disk through a rebuild and `hermes doctor` kept flagging
    # it as deprecated. Removing a setting means removing it from the file by
    # hand, once:
    #   sudo -e /var/lib/hermes/.hermes/config.yaml   (root:hermes, 0660)
    settings = {
      # Everything stays on-box: client AWS account details must not leave
      # the LAN, so the provider is the local llama-server, not OpenRouter
      # (which is what Hermes defaults to when base_url is unset).
      model = {
        base_url = "http://127.0.0.1:8000/v1";
        default = "local-main";   # must match -a alias in llama-server.nix

        # Without this the agent will not run at all: `hermes -z` dies with
        # "No LLM provider configured", while `hermes status` cheerfully
        # reports "Model: local-main / Provider: Custom endpoint" — which is
        # what makes it confusing. base_url says *where* to send inference;
        # it does not say which provider adapter to route it through, and
        # with none resolved Hermes refuses before it ever opens a socket.
        # "openai-api" is the OpenAI-compatible adapter in Hermes'
        # PROVIDER_REGISTRY, and it takes its key from OPENAI_API_KEY in the
        # environmentFiles below — the same key llama-server checks.
        provider = "openai-api";

        # Must match --ctx-size for local-main in llama-server.nix.
        # Hermes probes /props to learn this, and llama-swap does not proxy
        # that path — the request carries no model name, so there is nothing
        # to route it to. Unset, Hermes logs "Could not detect context length
        # ... defaulting to 256,000 tokens" and then believes it has twice
        # the room it does, so compression fires too late and turns die on
        # context overflow instead of being summarised. Stating it is both
        # the fix and the more honest configuration.
        context_length = 131072;
      };

      # Not [ "all" ]. Tool definitions are re-sent on every API call, and
      # "all" was costing 12,243 tokens a turn — 9.3% of the window, paid 50
      # times in one session — to describe browser, computer-use, Spotify,
      # Home Assistant, Feishu, image-gen, TTS and video tools that this box
      # does not have. `hermes doctor` lists most of them as "system
      # dependency not met" and Tavily has no key, so they were pure tax.
      # This is the set the agent actually uses here; add one back the moment
      # it is genuinely needed and pay for it deliberately.
      toolsets = [
        "terminal"        # the tool everything here runs through
        "file"            # read/write in the workspace
        "code_execution"  # observed in use during the Terraform builds
        "skills"          # how it finds claude-consult and local-plan
        "memory"
        "todo"
        "session_search"  # the FTS index over past sessions
        "clarify"
      ];

      # The bundled "claude-code" skill tells the agent to run `claude`
      # directly and to authenticate by running it once for a browser login.
      # Neither works here: the gateway runs as the unprivileged `hermes`
      # user, which has no Claude credentials and no browser, so every
      # delegation fails with "Not logged in · Please run /login" after the
      # agent has already announced it is delegating. Worse, the obvious fix —
      # putting CLAUDE_CODE_OAUTH_TOKEN in Hermes' environment — would also
      # silently enable Hermes' own `anthropic` provider, which is the thing
      # modules/claude-bridge.nix exists to avoid. Disabled so the agent finds
      # the wrapper instead, which holds the credential correctly.
      skills.disabled = [ "claude-code" ];
      terminal = {
        backend = "local";
        # 600, not the 180 this started at: a cold planner load is a 59 GiB
        # model coming off disk before it answers anything, and a tool
        # timeout shorter than that makes the planner tier unusable exactly
        # when it is first reached. A genuinely hung command still dies.
        timeout = 600;
      };

      memory = {
        memory_enabled = true;
        user_profile_enabled = true;
      };

      # Context compression: route the summarizer to the SAME local model,
      # otherwise the module example's default sends summaries to a cloud
      # model via OpenRouter.
      compression = {
        enabled = true;
        # 0.35, not 0.85. At 0.85 of a 131k window it summarises at ~111k
        # tokens, long after this box stops being pleasant: decode measures
        # 48 tok/s at 2k context, 29 at 19k, and keeps falling, because every
        # generated token attends over the whole KV cache. Compressing at
        # ~46k keeps sessions in the fast band. The tradeoff is that
        # compression rewrites history and so invalidates llama.cpp's prefix
        # cache — one expensive turn, against spending the rest of the
        # session in the slow band.
        threshold = 0.35;
      };

      # The summarizer moved out of `compression` in newer Hermes:
      # `compression.summary_model` is deprecated and, more to the point,
      # *ignored* — `hermes doctor` flags it but nothing migrates it, so the
      # setting reads as "summaries stay local" while they would actually go
      # to whatever the default provider is. Provider is repeated here
      # because auxiliary tasks resolve their own; left at "auto" it does not
      # inherit the main model's.
      auxiliary.compression = {
        model = "local-main";
        provider = "openai-api";
      };

      # Without this the gateway prompts "No home channel is set for Discord"
      # on every fresh chat and waits for /sethome. /sethome writes the same
      # thing into $HERMES_HOME state, so setting it here just states up front
      # what the answer always was — and it survives a rebuild, which a
      # hand-run slash command does not.
      #
      # This is the delivery target for cron output and for any cross-platform
      # message that names a platform without naming a channel.
      discord.home_channel = {
        platform = "discord";
        chat_id = "1540119647586619412";
        name = "Hermes-Alerts";
      };

      agent = {

        max_turns = 60;
        verbose = false;
      };
    };

    # Discord bot credentials are NOT declared here. They are secrets, and
    # anything in `settings` or `environment` lands world-readable in
    # /nix/store. They go in the environmentFiles path below, which the
    # module merges into $HERMES_HOME/.env at activation:
    #
    #   DISCORD_BOT_TOKEN=...            # Developer Portal -> Bot -> Reset Token
    #   DISCORD_ALLOWED_USERS=...        # your Discord user ID; comma-separate for more
    #
    # DISCORD_ALLOWED_USERS is the authorization gate — leaving it unset
    # does not mean "allow everyone by accident", but do set it explicitly.
    # In server channels the bot only answers when @mentioned; DMs always.
    # Both "Message Content Intent" and "Server Members Intent" must be ON
    # in the Developer Portal or the bot connects but reads empty messages.

    # Bootstrap: plain root-owned 0600 file (created in the guide). Upgrade
    # path is sops-nix or agenix; the module docs show both. Never put keys
    # in `settings` or `environment`: those land world-readable in
    # /nix/store.
    environmentFiles = [ "/var/lib/hermes/env" ];

    # Discord/Telegram/Slack adapters. Required on Nix: the venv is sealed
    # and read-only, so a missing extra cannot be pip-installed at runtime —
    # it has to be resolved into the venv at build time. Without this the
    # gateway starts but logs "No adapter available for discord".
    extraDependencyGroups = [ "messaging" ];

    # Extra tools the agent may call from its terminal:
    extraPackages = with pkgs; [
      ripgrep
      jq
      curl
      # Terraform comes from the flake rather than tfenv or a curl|unzip dance:
      # the agent has no unzip and NixOS has no FHS for a downloaded toolchain
      # to land in, and pinning here means `nix flake update` is the version
      # bump. Without it the agent writes HCL it cannot fmt, validate or plan,
      # which for infrastructure code leaves you as the only check.
      terraform

      # Containers, rootless, as the hermes user. See the block below for the
      # three prerequisites that make these actually run rather than just
      # exist on PATH.
      #
      # podman-compose and not docker-compose: compose v2 is a docker CLI
      # plugin that talks to a daemon socket, and there is no daemon on this
      # box — `docker` here is only the dockerCompat shim onto podman.
      # podman-compose drives the podman CLI directly, so it needs no socket,
      # no lingering user session, and no API service running.
      podman
      podman-compose
    ];
  };

  # --- What it takes to give a hardened service user working rootless podman.
  #
  # 1. subuid/subgid ranges. Without them podman refuses with "no subuid
  #    ranges found for user hermes" and falls back to a single-id mapping
  #    that breaks most images. /etc/subuid listed only david, because he is
  #    the only account with autoSubUidGidRange set. 200000 keeps clear of
  #    david's 100000-165535.
  users.users.hermes = {
    subUidRanges = [{ startUid = 200000; count = 65536; }];
    subGidRanges = [{ startGid = 200000; count = 65536; }];

    # Lingering, so systemd starts a user manager for hermes at boot even
    # though it never logs in. This is not cosmetic: podman runs container
    # healthchecks as transient systemd user units, so without a user manager
    # `--health-cmd` never fires, container health stays "starting" forever,
    # and any compose service with `depends_on: condition: service_healthy`
    # waits on a status that will never arrive. The agent's own compose stack
    # depends on postgres exactly that way. It also stops podman falling back
    # from the systemd cgroup manager to cgroupfs on every single invocation.
    linger = true;
  };

  systemd.services.hermes-agent = {
    # 2. newuidmap/newgidmap. Rootless podman shells out to these to apply the
    #    ranges above, and finds them by PATH, not by absolute path. They are
    #    setuid wrappers under /run/wrappers/bin, which is on the default
    #    system PATH but NOT on a systemd unit's — the unit builds its PATH
    #    from this `path` list alone. Omit this and podman fails at container
    #    creation, long after `podman info` looks healthy.
    path = [ "/run/wrappers" ];

    serviceConfig = {
      # 4. NoNewPrivileges OFF. This is the one that actually blocked it, and
      #    it is not optional: newuidmap is a SETUID binary, and NoNewPrivileges
      #    is precisely the flag that stops a setuid binary acquiring
      #    privileges. With it on, podman gets
      #
      #      running `/run/wrappers/bin/newuidmap ...`:
      #      failed to inherit capabilities: Operation not permitted
      #      Error: ... unable to create a new pause process
      #
      #    and no amount of subuid configuration helps, because the ranges are
      #    fine and the tool that applies them is neutered.
      #
      #    What it costs: hermes can now execute setuid binaries. It has no
      #    sudoers entry, so this is not a path to root — it is the difference
      #    between "can use newuidmap/mount/ping" and "cannot". The agent
      #    already has a terminal and arbitrary code execution as its own user;
      #    this does not widen that meaningfully.
      #
      #    Beware when testing this: `sudo -u hermes` and a plain systemd-run
      #    do NOT carry this flag, so podman succeeds under both while failing
      #    in the real unit. Worse, once ANY invocation has created the
      #    rootless pause process, later ones join the existing namespace
      #    without calling newuidmap at all — so a contaminated box passes a
      #    test it should fail. Kill the pause process first, or you are
      #    testing nothing.
      #    mkForce because the upstream hermes-agent module sets this to true
      #    as part of its own hardening; without it the two definitions
      #    conflict and evaluation fails.
      NoNewPrivileges = lib.mkForce false;
    };

    environment = {
      # 3. A runtime directory, which is where podman keeps its locks and
      #    transient state and where the user session bus lives. With
      #    lingering enabled above this is the real one at /run/user/<uid>,
      #    shared with the user manager, rather than a private RuntimeDirectory
      #    that would leave podman's systemd integration talking to nothing.
      #
      #    The uid is pinned in the let block above rather than discovered,
      #    for the reason documented there.
      XDG_RUNTIME_DIR = "/run/user/${toString hermesUid}";
      DBUS_SESSION_BUS_ADDRESS = "unix:path=/run/user/${toString hermesUid}/bus";
    };
  };
}
