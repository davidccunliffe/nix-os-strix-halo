{ config, lib, pkgs, ... }:

# The inference stack: llama-swap on :8000, spawning llama-server per model.
#
# Backend choice: on gfx1151, Vulkan decodes faster than ROCm/HIP for
# interactive serving, while ROCm wins prefill. ROCm 7.x also has the
# severe prefill regression on this GPU. So: Vulkan on the host as the
# daily driver, ROCm via the kyuz0 podman toolboxes when you want to
# re-benchmark. Re-run the A/B after each llama.cpp or Mesa bump.
#
# Why llama-swap rather than a bare llama-server: this build of llama.cpp
# serves exactly one model per process, and Hermes can only be pointed at a
# single base_url. llama-swap fronts both — one endpoint on :8000 that routes
# by the model name in the request and starts the right llama-server behind
# it. Adding a model is a block in the config below plus a download; nothing
# in modules/hermes.nix changes.
#
# The two models load exclusively, which is deliberate. The workhorse is
# ~37 GiB resident and the planner ~59 GiB before its KV cache; both at once
# would leave nothing spare out of 105 GiB of GTT. So asking for the planner
# evicts the workhorse and vice versa, at the cost of a reload — ~18s for the
# small one, longer for the planner. That is a fine price for a planning turn
# and a terrible one per-turn, which is exactly how the two are meant to be
# used.

let
  # nixpkgs llama-cpp built with the Vulkan backend. If the override attr
  # ever changes on unstable, the fallback is the nix-strix-halo flake's
  # llama-cpp-vulkan / llama-cpp-master-vulkan outputs.
  llamaPkg = pkgs.llama-cpp.override { vulkanSupport = true; };

  # ---- Edit per model ----
  # Download onto the box with:
  #   sudo -u llama curl -fL -C - -o /var/lib/llama/models/<file>.gguf <url>
  workhorseFile = "/var/lib/llama/models/GLM-4.7-Flash-Q8_0.gguf";
  plannerFile   = "/var/lib/llama/models/gpt-oss-120b-MXFP4.gguf";

  port = 8000;

  # Hermes hard-rejects any model advertising under 64k context at startup,
  # so every model reachable from Hermes needs at least 65536. Remember -c is
  # the TOTAL across slots: at --parallel 3 you need 3x the per-agent window.
  workhorseCtx = 131072;
  plannerCtx   = 65536;

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
  # n_ubatch is settled too: 512 (the default) beat both 1024 and 2048 on
  # pp2048 and pp8192, so there is nothing to gain there.

  # 16 = the physical core count of the Ryzen AI MAX+ 395 (16C/32T).
  # Deliberately not 32: llama.cpp gains nothing from SMT siblings on a
  # memory-bandwidth-bound workload and usually loses a little to
  # contention. Mostly this matters for prompt processing and any CPU
  # fallback — at -ngl 99 decode barely touches it.
  threads = 16;

  # ''${PORT} and ''${env.X} escape past Nix into llama-swap's own macro
  # syntax: it assigns each model a port and substitutes the environment.
  swapConfig = pkgs.writeText "llama-swap.yaml" ''
    logLevel: info

    # "both", not the default "proxy": llama-server writes the prompt- and
    # token-rate lines that diagnosed the KV cache regression, and with only
    # proxy logs they never reach the journal. Losing that telemetry is how
    # a slow box becomes a mysterious box.
    logToStdout: both
    startPort: 10001

    # A 63 GB model takes well over a minute to become healthy on this box,
    # and the default timeout would give up long before that.
    healthCheckTimeout: 900

    macros:
      "server": >
        ${llamaPkg}/bin/llama-server
        --host 127.0.0.1 --port ''${PORT}
        --api-key "''${env.LLAMA_API_KEY}"
        -ngl 99 -fa on --jinja --no-mmap
        --threads ${toString threads}

    models:
      # The workhorse: every ordinary agent turn. ttl 0 keeps it loaded, so
      # the common path never pays a reload.
      "local-main":
        cmd: |
          ''${server}
          --model ${workhorseFile}
          --ctx-size ${toString workhorseCtx}
          --parallel 1
        name: "GLM-4.7-Flash Q8_0"
        description: "Workhorse: coding, tools, ordinary turns"
        ttl: 0

      # The planner: asked for by name when a task needs more capacity than
      # the workhorse has. 117B total but ~5B active, so it decodes at a
      # usable rate despite its size. Unloads after 30 minutes idle rather
      # than sitting on 59 GiB.
      "planner":
        cmd: |
          ''${server}
          --model ${plannerFile}
          --ctx-size ${toString plannerCtx}
          --parallel 1
        name: "gpt-oss-120b MXFP4"
        description: "Planner: architecture, design, review"
        ttl: 1800
  '';
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

  systemd.services.llama-swap = {
    description = "llama-swap: model routing in front of llama-server (Vulkan/RADV)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    # /var/lib/llama/models is its own filesystem (nvme1n1). Ordering against
    # it explicitly means the service cannot start against an empty mountpoint
    # and hand out "missing model" errors if the model disk is slow to appear.
    unitConfig.RequiresMountsFor = [ "/var/lib/llama/models" ];

    serviceConfig = {
      User = "llama";
      Group = "llama";
      # GPU access for the RADV device nodes under /dev/dri.
      SupplementaryGroups = [ "video" "render" ];

      # Contains LLAMA_API_KEY=... (created in the guide, mode 0600). systemd
      # reads it as root before dropping privileges, so root:root 0600 is
      # right here — unlike /var/lib/wifi/env, whose daemon reads it itself.
      EnvironmentFile = "/var/lib/llama/env";

      ExecStart = "${pkgs.llama-swap}/bin/llama-swap -config ${swapConfig} -listen 0.0.0.0:${toString port}";
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
