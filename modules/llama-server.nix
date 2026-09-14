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

  # The planner runs a DIFFERENT binary, from modules/llama-cpp-qwen4exp.nix:
  # nixpkgs' llama-cpp has no `qwen4exp` architecture at all, and the MTP
  # draft head is still an unmerged PR. Two binaries is the price of running
  # this model before it lands upstream; the workhorse stays on nixpkgs.
  qwen4expPkg = pkgs.llama-cpp-qwen4exp;

  # ---- Edit per model ----
  # Download onto the box with:
  #   sudo -u llama curl -fL -C - -o /var/lib/llama/models/<file>.gguf <url>
  workhorseFile = "/var/lib/llama/models/GLM-4.7-Flash-Q8_0.gguf";
  plannerFile   = "/var/lib/llama/models/Qwen3.8-Flash-Next-AP-IQ4_XS.gguf";

  # The MTP draft head, as a separate GGUF loaded with -md. It is one
  # qwen4exp block trained jointly with the model, so it drafts tokens the
  # target accepts 85-100% of the time — which is the whole reason this
  # model decodes faster than its 177B size suggests.
  plannerDraft  = "/var/lib/llama/models/mtp-Qwen3.8-Flash-Next-Q8_0.gguf";

  # Kept, not deleted: 59 GiB of already-downloaded model, still reachable
  # by name for an A/B against the new planner.
  gptossFile    = "/var/lib/llama/models/gpt-oss-120b-MXFP4.gguf";

  port = 8000;

  # Hermes hard-rejects any model advertising under 64k context at startup,
  # so every model reachable from Hermes needs at least 65536. Remember -c is
  # the TOTAL across slots: at --parallel 3 you need 3x the per-agent window.
  workhorseCtx = 131072;
  plannerCtx   = 65536;

  # 65536 rather than the 32768 the A/B was run at, because Hermes rejects
  # anything advertising under 64k. qwen4exp is a hybrid: most layers are
  # gated-delta-net with a recurrent state that does not grow with context,
  # so doubling the window costs far less KV than a dense model would.
  # Measured headroom at 32k was ~41 GiB, so this is not close to the edge —
  # but it is EXTRAPOLATED, not measured. Re-run the depth sweep at 64k
  # before trusting it under real load.
  qwen4expCtx  = 65536;

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
      # --no-mmap moved OUT of the shared macro and onto the models that
      # want it. It is fine for a 32 GiB model and actively harmful for an
      # 84 GiB one: forcing the whole file into anonymous memory is reported
      # to OOM at that size, and every run that worked on this box used
      # mmap. With 512 experts, demand paging also means only the experts
      # actually touched are ever resident — the planner measures 59.5 GiB
      # against an 84 GiB file for exactly that reason.
      "server": >
        ${llamaPkg}/bin/llama-server
        --host 127.0.0.1 --port ''${PORT}
        --api-key "''${env.LLAMA_API_KEY}"
        -ngl 99 -fa on --jinja
        --threads ${toString threads}

      # Same shape, different binary: the pinned build that knows qwen4exp.
      # --fit off because the fitter sizes against the small BIOS VRAM carve
      # rather than the 105 GiB GTT pool, and this model must not be
      # silently trimmed.
      "server-qwen4exp": >
        ${qwen4expPkg}/bin/llama-server
        --host 127.0.0.1 --port ''${PORT}
        --api-key "''${env.LLAMA_API_KEY}"
        -ngl 99 -fa on --jinja --fit off
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
          --no-mmap
        name: "GLM-4.7-Flash Q8_0"
        description: "Workhorse: coding, tools, ordinary turns"
        ttl: 0

      # The planner: asked for by name when a task needs more capacity than
      # the workhorse has. 177B total but ~6B active, decoding at 30-34
      # tok/s with the MTP draft head — faster than the 120b it replaced and
      # a much stronger model. Unloads after 30 minutes idle rather than
      # sitting on 64 GiB.
      #
      # --spec-type draft-mtp is the whole point: the draft head proposes
      # tokens and the target verifies them in one pass, which is lossless
      # at temperature 0. Measured 2026-09-12 at 2k/8k/16k:
      #   baseline 26/24/22 -> 34/31/30 tok/s, acceptance 100%/85%/86%.
      # p-min 0.75 is the confidence gate the model card calls essential for
      # prose; n-max 4 was the depth measured. Raising n-max without
      # re-measuring acceptance is how you get a slower server.
      "planner":
        cmd: |
          ''${server-qwen4exp}
          --model ${plannerFile}
          --ctx-size ${toString qwen4expCtx}
          --parallel 1
          --spec-draft-model ${plannerDraft}
          --spec-type draft-mtp
          --spec-draft-n-min 2
          --spec-draft-n-max 4
          --spec-draft-p-min 0.75
        name: "Qwen3.8-Flash-Next IQ4_XS + MTP"
        description: "Planner: architecture, design, review"
        ttl: 1800

      # The previous planner, kept reachable by name so the two can be
      # compared without editing this file. qwen4exp-build/bench-planner.sh
      # points at whichever id you give it.
      "planner-gptoss":
        cmd: |
          ''${server}
          --model ${gptossFile}
          --ctx-size ${toString plannerCtx}
          --parallel 1
          --no-mmap
        name: "gpt-oss-120b MXFP4"
        description: "Planner (previous): architecture, design, review"
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
    # 0750 on the home too, not just models. createHome makes it 0700, which
    # blocks traversal for llama-group members and so makes the 0750 on
    # models below unreachable — the same shape of trap as a 0700 /home/david.
    # Members of the llama group need to walk through here to reach the GGUFs
    # from a benchmarking container. /var/lib/llama/env stays root:root 0600,
    # so the API key is not exposed by this.
    "d /var/lib/llama 0750 llama llama -"
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
