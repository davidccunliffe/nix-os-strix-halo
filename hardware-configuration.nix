# =====================================================================
# EXAMPLE ONLY. Replace this ENTIRE file with the one generated on the
# actual machine:
#
#   during install:        nixos-generate-config --root /mnt
#   on a running system:   sudo nixos-generate-config
#
# then copy /etc/nixos/hardware-configuration.nix over this file.
# The UUIDs below are placeholders and will not boot.
#
# Note the split: this file only contains what the generator emits
# (kernel modules, filesystems, microcode). The bootloader lives in
# configuration.nix, so replacing this file never loses it.
# =====================================================================
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  # Typical set for this platform; your generated file is authoritative.
  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "thunderbolt" "usbhid" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/REPLACE-WITH-ROOT-UUID";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/REPLACE-WITH-ESP-UUID";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  # Per modules/strix-halo.nix: prefer no swap, or keep it small, so it
  # never fights the GTT pool.
  swapDevices = [ ];

  networking.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
