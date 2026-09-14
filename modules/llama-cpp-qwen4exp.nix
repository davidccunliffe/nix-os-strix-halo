{ config, lib, pkgs, ... }:

# llama.cpp for Qwen3.8-Flash-Next (arch `qwen4exp`) with its MTP draft head.
#
# This is the configuration that was actually measured on this box on
# 2026-09-12, and it is deliberately NOT the recipe from the Windows
# write-up that prompted the work. See modules/llama-cpp-rdna-boosts.nix for
# that route and why it is parked: its patch set is pinned to a fork point
# inside a window where qwen4exp silently generates fluent text that ignores
# the prompt entirely, on every backend including CPU.
#
# Here the base is pinned PAST that window, and the only thing layered on is
# the MTP draft head itself:
#
#   base    982937a33 (Sep 11 master) — contains the fix, verified coherent
#   patch   PR #28243, vendored as the exact 982937a33..b7dca7a1c delta
#
# The patch is vendored rather than fetched from GitHub's /pull/28243.patch
# because that URL's content changes every time the PR is updated, which
# would turn an unrelated upstream push into a hash failure here. The file
# in patches/ is byte-for-byte the tree that produced the numbers below.
#
# Measured, Vulkan/RADV, AP-IQ4_XS + mtp-...-Q8_0.gguf sidecar, unique
# prompts so nothing is served from cache:
#
#            2k      8k      16k
#   baseline 26      24      22   tok/s decode
#   MTP      34      31      30   tok/s decode   (+31% / +29% / +36%)
#   accept   100%    85%     86%
#   GTT      59.5 GiB baseline, 64.5 GiB with the draft head
#
# When #28243 merges, delete this module and its patch, drop the `bin`
# override in llama-server.nix, and let a nixpkgs bump carry it. Until then
# a nixpkgs bump does NOT affect this package — it is pinned end to end.
#
# Re-validate with qwen4exp-build/verify-iq3.sh (point BIN at the store path)
# after ANY change here. MTP on this platform has a documented history of
# doubling the token rate while emitting garbage, so the token rate is not
# evidence of anything on its own.

let
  llamaQwen4exp = (pkgs.llama-cpp.override { vulkanSupport = true; }).overrideAttrs (old: {
    pname = "llama-cpp-qwen4exp";

    # MUST stay numeric. nixpkgs bakes this straight into build-info.cpp as
    # LLAMA_BUILD_NUMBER, so anything with letters in it fails the build
    # with "unable to find numeric literal operator". b10909 is the nearest
    # tag to the pinned commit; the PR it carries is recorded above, not
    # here.
    version = "10909";

    src = pkgs.fetchFromGitHub {
      owner = "ggml-org";
      repo = "llama.cpp";
      rev = "982937a3337f7e97ef08fd5603f4157575ece7e1";
      hash = "sha256-k7VjuSO2VdB+nyaWQMzQYzdFZtamBPDNmElpSa+IKZo=";
    };

    patches = (old.patches or [ ]) ++ [ ./patches/qwen4exp-mtp-pr28243.patch ];
  });
in
{
  nixpkgs.overlays = [
    (final: prev: { llama-cpp-qwen4exp = llamaQwen4exp; })
  ];
}
