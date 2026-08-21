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
  # Download onto the box with:
  #   sudo -u llama curl -L -o /var/lib/llama/models/GLM-4.7-Flash-Q8_0.gguf \
  #     https://huggingface.co/ggml-org/GLM-4.7-Flash-GGUF/resolve/main/GLM-4.7-Flash-Q8_0.gguf
  modelFile  = "/var/lib/llama/models/GLM-4.7-Flash-Q8_0.gguf";
  modelAlias = "local-main";   # must match settings.model.default in hermes.nix
  port       = 8000;

  # Hermes hard-rejects any model advertising under 64k context at startup,
  # so keep the slot Hermes talks to at 65536 minimum. Remember -c is the
  # TOTAL across slots: at --parallel 3 you need 3x the per-agent window.
  ctxSize  = 131072;
  parallel = 1;

  # The KV cache is left at f16 deliberately. --cache-type-k/v q8_0 used to be
  # set here; removing it is worth about a factor of two. Measured against
  # this server with an identical 19k-token prompt, before and after:
  #
  #            prompt processing      decode      GTT used
  #   q8_0        170 tok/s (113s)   19.4 tok/s   33.6 GiB
  #   f16         336 tok/s  (57s)   29.1 tok/s   36.8 GiB
  #
  # Note the decode column, because llama-bench does not show it: its tg64
  # test runs at trivial depth, where the cache is small enough that its
  # format hardly matters (50.6 vs 49.8, indistinguishable). At 19k of real
  # context every generated token reads the whole cache, so dequantizing it
  # costs on both phases. Benchmark the depth you actually run at.
  #
  # The 3.2 GiB it costs is nothing against 105 GiB of GTT, and agent turns
  # resend the whole conversation every time — so prompt processing is the
  # cost that dominates here, and quantizing the cache is precisely the knob
  # that makes it worse.

  # 16 = the physical core count of the Ryzen AI MAX+ 395 (16C/32T).
  # Deliberately not 32: llama.cpp gains nothing from SMT siblings on a
  # memory-bandwidth-bound workload and usually loses a little to
  # contention. Mostly this matters for prompt processing and any CPU
  # fallback — at -ngl 99 decode barely touches it. This box does nothing
  # but inference, so there is no reason to leave cores for anything else.
  threads = 16;

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
      --no-mmap \
      --threads ${toString threads}
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

    # /var/lib/llama/models is its own filesystem (nvme1n1). Ordering against
    # it explicitly means the service cannot start against an empty mountpoint
    # and crash-loop on a "missing" GGUF if the model disk is slow to appear.
    unitConfig.RequiresMountsFor = [ "/var/lib/llama/models" ];

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
