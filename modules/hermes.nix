{ config, lib, pkgs, ... }:

# Hermes Agent via the official NixOS module (services.hermes-agent).
#
# Managed mode: with this module, config is declarative. `hermes setup`,
# `hermes config edit/set`, and `hermes gateway install/uninstall` are
# BLOCKED at the CLI with a pointer back here. To change anything: edit
# this file, `sudo nixos-rebuild switch`.
#
# Mode: native (default). Hardened systemd unit, agent can only use tools
# on the Nix-provided PATH (add via extraPackages). If you later want the
# agent to apt/pip/npm install for itself, flip container.enable = true
# and set container.backend = "podman" (docker is the module default), plus
# the passwordless-sudo-for-podman rule from the Hermes Nix docs.

{
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
      };

      toolsets = [ "all" ];

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
        threshold = 0.85;
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
    ];
  };
}
