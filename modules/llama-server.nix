{ config, lib, pkgs, ... }:

# llama-server as a hardened systemd service on the Vulkan/RADV backend.
#
# Backend choice: on gfx1151, Vulkan decodes faster than ROCm/HIP for
# interactive serving, while ROCm wins prefill. ROCm 7.x also has the
# severe prefill regression on this GPU. So: Vulkan on the host as the
# daily driver, ROCm via the kyuz0 podman toolboxes when you want to
# re-benchmark. Re-run the A/B after each llama.cpp or Mesa bump.

let
  # nixpkgs llama-cpp built with the Vulkan backend. If the override attr
  # ever changes on unstable, the fallback is the nix-strix-halo flake's
  # llama-cpp-vulkan / llama-cpp-master-vulkan outputs.
  llamaPkg = pkgs.llama-cpp.override { vulkanSupport = true; };

  # ---- Edit per model ----
  modelFile  = "/var/lib/llama/models/CHANGE-ME.gguf";
  modelAlias = "local-main";   # must match settings.model.default in hermes.nix
  port       = 8000;

  # Hermes hard-rejects any model advertising under 64k context at startup,
  # so keep the slot Hermes talks to at 65536 minimum. Remember -c is the
  # TOTAL across slots: at --parallel 3 you need 3x the per-agent window.
  ctxSize  = 131072;
  parallel = 1;

  startScript = pkgs.writeShellScript "llama-server-start" ''
    exec ${llamaPkg}/bin/llama-server \
      -m ${modelFile} \
      -a ${modelAlias} \
      --host 0.0.0.0 --port ${toString port} \
      --api-key "$LLAMA_API_KEY" \
      -ngl 99 \
      -fa on \
      --jinja \
      --ctx-size ${toString ctxSize} \
      --parallel ${toString parallel} \
      --cache-type-k q8_0 --cache-type-v q8_0 \
      --no-mmap \
      --threads 8
  '';
  # When you land the router config (multi-model planner/worker setup),
  # replace the single -m invocation above with your router flags. Your
  # previous MTP speculative-decode flags, if the model bundles a nextn
  # head, went: --spec-type draft-mtp --spec-draft-p-min 0.75
  # --spec-draft-n-max 3. MTP regresses badly at --parallel > 1, so only
  # enable it on single-slot servers and verify acceptance rate in logs.
in
{
  users.users.llama = {
    isSystemUser = true;
    group = "llama";
    home = "/var/lib/llama";
    createHome = true;
  };
  users.groups.llama = { };

  systemd.tmpfiles.rules = [
    "d /var/lib/llama/models 0750 llama llama -"
  ];

  systemd.services.llama-server = {
    description = "llama-server (Vulkan/RADV) OpenAI-compatible endpoint";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      User = "llama";
      Group = "llama";
      # GPU access for the RADV device nodes under /dev/dri.
      SupplementaryGroups = [ "video" "render" ];

      # Contains LLAMA_API_KEY=... (created in the guide, mode 0600).
      EnvironmentFile = "/var/lib/llama/env";

      ExecStart = startScript;
      Restart = "always";
      RestartSec = 5;

      # Moderate hardening. Deliberately no PrivateDevices/DeviceAllow:
      # GPU device sandboxing on amdgpu is a footgun.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ "/var/lib/llama" ];
      PrivateTmp = true;
    };
  };
}
