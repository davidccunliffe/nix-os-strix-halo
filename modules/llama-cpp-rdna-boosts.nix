{ config, lib, pkgs, ... }:

# !! DO NOT IMPORT THIS YET — it builds, and the binary it builds is WRONG. !!
#
# Measured 2026-09-12: the fork point this patch set is pinned to,
# 9113cc188 (Sep 8), sits inside a window where qwen4exp generates fluent
# text that completely ignores the prompt. "The capital of Japan is" ->
# " Professional Corporation, a professional corporation organized under...".
# Reproduced on two quants from different publishers, on the stock Sep 6
# master build AND this patched build, on Vulkan AND on CPU-only (-ngl 0),
# with identical junk tokens across backends. A GLM-4.7-Flash control
# through this same Nix-built binary is perfectly coherent, so the binary
# and the harness are fine — the fork point is not.
#
# Today's master (c069aa7) is FIXED: " Tokyo.". The fix is somewhere in
# 9113cc188..982937a33, which contains #28330 (hybrid indexer).
#
# The patch set does NOT rebase onto fixed master — block 01 conflicts in
# tools/server/server-context.cpp under `git am -3`. So this file is parked
# until stew675 re-bases (that repo re-based on 09-02, 09-06, 09-07, 09-08,
# so it should be days) — then re-pin BOTH revs and re-run
# qwen4exp-build/verify-iq3.sh before trusting a single token of output.
#
# THE WORKING CONFIGURATION, validated on this box the same day, is plain
# master + PR #28243 and none of these kernel patches:
#
#   base   982937a33 (Sep 11 master, post-fix)  +  PR #28243 merge ref
#   model  Qwen3.8-Flash-Next-AP-IQ4_XS.gguf + mtp-...-Q8_0.gguf sidecar
#   flags  -ngl 99 -fa on --fit off -md <sidecar> --spec-type draft-mtp
#          --spec-draft-n-min 2 --spec-draft-n-max 4 --spec-draft-p-min 0.75
#
#   decode  2k/8k/16k   baseline 26/24/22 -> MTP 34/31/30 tok/s
#   accept  100% / 85% / 86%
#   GTT     59.5 GiB baseline, 64.5 GiB with the draft head
#
# That is +29-36%, not the 2x the Windows write-up reports. Worth having,
# not worth a fork-of-a-fork.
#
# Quant choice is settled by measurement, against unsloth UD-IQ3_XXS on the
# same base: IQ3_XXS ran 32/30/29 at 93% accept and 56.4 GiB. So the LARGER
# IQ4_XS is faster at every depth AND higher fidelity, for ~8 GiB more GTT —
# the better target agrees with the draft head more often, which pays for
# its own weight. Use IQ4_XS; the IQ3_XXS shards are the ones to delete.
#
# ---------------------------------------------------------------------
#
# llama.cpp with stew675's rdna-boosts patch set, for Qwen3.8-Flash-Next
# (arch `qwen4exp`) with its MTP draft head.
#
# Why a fork at all: the MTP draft head lives in PRs #27836 and #28243, and
# the on-device recurrent checkpoints in #28118. All three are still DRAFT
# upstream. The base architecture IS merged — llama.cpp master has
# src/models/qwen4exp.cpp and loads the model fine on Vulkan, which this box
# verified on 2026-09-06 — so the fork buys exactly one thing: the draft head
# that makes decode worth having. Stock nixpkgs (b10408) is behind even that;
# it has no `qwen4exp` at all.
#
# This is a SECOND package, deliberately not a replacement. Its fork point
# (9113cc188) is older than the nixpkgs llama-cpp that serves the workhorse,
# so pointing everything at it would be a regression on every other model.
# modules/llama-server.nix picks per model.
#
# What the patched binary adds to `--spec-type`, verified on the Nix build:
#   draft-mtp, draft-mtp-adaptive
# Block 01's adaptive draft depth is that second VALUE — not a separate
# `--spec-draft-adaptive` flag, which does not exist in this patch set
# despite appearing in the upstream Vulkan report.
#
# When #28243 and #28118 merge, delete this file, drop the `cmd` override in
# llama-server.nix, and let the nixpkgs bump carry it. Nothing else changes.

let
  # The patch set. 15 blocks (00-14), `git am`-clean against the fork point
  # below; block 14 is the qwen4exp support. No renames and no binary hunks
  # in any of them, which is why the plain `patches` list works here rather
  # than a git-apply dance. Verified applied cleanly against 9113cc188 on
  # 2026-09-12.
  rdnaBoosts = pkgs.fetchFromGitHub {
    owner = "stew675";
    repo = "llama-cpp-rdna-boosts";
    rev = "b9a332e13b9d9257db6dd7834b150c2826194de0";
    hash = "sha256-NWtFhL6kqFnWSHiPigVm7lAkDMscXqWdGQeifRkM4Ts=";
  };

  # Order matters: git am applies these sequentially and later blocks depend
  # on earlier ones. Listed explicitly rather than globbed so a change in the
  # upstream repo shows up as a build failure instead of a silent reorder.
  blocks = [
    "0000-rdna-boosts-block-00-structural-and-architecture-fix.patch"
    "0001-rdna-boosts-block-01-adaptive-MTP-draft-depth.patch"
    "0002-rdna-boosts-block-02-fused-chunked-gated-delta-net-p.patch"
    "0003-rdna-boosts-block-03-BF16-KV-cache-and-native-BF16-f.patch"
    "0004-rdna-boosts-block-04-RDNA4-WMMA-flash-attn-Q6_K-mmq-.patch"
    "0005-rdna-boosts-block-05-CPU-bit-identical-decode-verify.patch"
    "0006-rdna-boosts-block-06-host-buffer-revert-for-discrete.patch"
    "0007-rdna-boosts-block-07-meta-device-wrapper-skip.patch"
    "0008-rdna-boosts-block-08-fused-core-prefill-kernels-and-.patch"
    "0009-rdna-boosts-block-09-meta-buffer-compute-container-h.patch"
    "0010-rdna-boosts-block-10-k-quant-boosts-Q4_K-Q5_K-Q6_K-Q.patch"
    "0011-rdna-boosts-block-11-skip-CUDA-graphs-for-multi-toke.patch"
    "0012-rdna-boosts-block-12-hybrid-HIP-all-reduce-RDNA4-gat.patch"
    "0013-rdna-boosts-block-13-fused-MoE-gate-up-GLU-MMQ-mmvq-.patch"
    "0014-rdna-boosts-block-14-qwen4exp-support.patch"
  ];
in
{
  nixpkgs.overlays = [
    (final: prev: {
      llama-cpp-rdna-boosts =
        (prev.llama-cpp.override { vulkanSupport = true; }).overrideAttrs (old: {
          pname = "llama-cpp-rdna-boosts";
          version = "9113cc188-rdna15";

          # The patches are static against this exact commit — the upstream
          # repo re-bases them every few days and stale hunks fail loudly
          # rather than half-applying. If a bump breaks the build, read
          # BASELINE.md in the patch repo for the new fork point, then
          # re-pin both revs together.
          src = final.fetchFromGitHub {
            owner = "ggml-org";
            repo = "llama.cpp";
            rev = "9113cc1880763bf590774490f51a661bf22403a4";
            hash = "sha256-ybH/xs7+YlngxJ+7zK+8s0QNtz4xUrtVdk4QmOxQW8w=";
          };

          patches = (old.patches or [ ]) ++
            map (f: "${rdnaBoosts}/patches/${f}") blocks;
        });
    })
  ];
}
