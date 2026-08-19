{ config, lib, pkgs, ... }:

# Host tuning for the Corsair AI Workstation 300 (Strix Halo / gfx1151,
# 128 GB unified memory), targeting llama.cpp on Vulkan/RADV with weights
# in GTT.
#
# Known-good floor from the kyuz0 toolboxes project: kernel 6.18.4 or newer
# (older kernels have a gfx1151 stability bug), and do NOT run
# linux-firmware 20251125 (breaks ROCm on Strix Halo). nixos-unstable's
# linuxPackages_latest is well past the kernel floor; check the firmware
# version after each flake update:
#
#   nix eval nixpkgs#linux-firmware.version
#
# If a nixpkgs bump ever lands you on a bad firmware, pin nixpkgs back or
# override the linux-firmware package until it moves past it.

{
  boot.kernelPackages = pkgs.linuxPackages_latest;

  hardware.enableRedistributableFirmware = true;

  # Let GTT span most of the unified pool so llama.cpp (Vulkan) can place
  # weights + KV there. 27648000 pages x 4 KiB = ~105 GiB, leaving ~23 GB
  # for the OS, Hermes, and containers. Pair this with a SMALL dedicated
  # iGPU carve-out in BIOS (512 MB to 4 GB): the Vulkan/GTT path allocates
  # dynamically and a big static UMA carve-out just wastes memory.
  boot.kernelParams = [
    "ttm.pages_limit=27648000"
    "ttm.page_pool_size=27648000"
  ];

  # Mesa (which includes RADV, the Vulkan driver you want) and the loader.
  hardware.graphics.enable = true;

  environment.systemPackages = with pkgs; [
    vulkan-tools   # vulkaninfo: confirm "AMD Radeon Graphics (RADV GFX1151)"
    amdgpu_top     # GPU / GTT / VRAM utilization
    lm_sensors
  ];

  # Headless server.
  services.xserver.enable = false;

  # Avoid swap fighting the GTT pool under memory pressure. If your
  # hardware-configuration.nix picked up a swap partition, consider
  # removing it or keeping it small.
  zramSwap.enable = false;
}
