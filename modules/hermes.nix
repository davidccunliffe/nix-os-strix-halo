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

    settings = {
      # Everything stays on-box: client AWS account details must not leave
      # the LAN, so the provider is the local llama-server, not OpenRouter
      # (which is what Hermes defaults to when base_url is unset).
      model = {
        base_url = "http://127.0.0.1:8000/v1";
        default = "local-main";   # must match -a alias in llama-server.nix
      };

      toolsets = [ "all" ];
      terminal = {
        backend = "local";
        timeout = 180;
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
        summary_model = "local-main";
      };

      agent = {
        max_turns = 60;
        verbose = false;
      };
    };

    # Bootstrap: plain root-owned 0600 file (created in the guide). Upgrade
    # path is sops-nix or agenix; the module docs show both. Never put keys
    # in `settings` or `environment`: those land world-readable in
    # /nix/store.
    environmentFiles = [ "/var/lib/hermes/env" ];

    # Uncomment to enable the Telegram/Discord/Slack gateway deps in the
    # sealed venv (runtime pip install is impossible on Nix):
    # extraDependencyGroups = [ "messaging" ];

    # Extra tools the agent may call from its terminal:
    extraPackages = with pkgs; [
      ripgrep
      jq
      curl
    ];
  };
}
