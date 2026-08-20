{ config, pkgs, ... }:

{
  networking.hostName = "ai-os";
  time.timeZone = "America/New_York";

  # Wi-Fi: the box has no ethernet drop where it lives, so it joins FoxyAP
  # over WLAN. Only the SSID is committed; the passphrase lives in
  # /var/lib/wifi/env (see secrets/wifi.env.example) — anything written in
  # a Nix expression lands world-readable in /nix/store. Wi-Fi does not
  # come up until that file exists, so during nixos-install create it under
  # /mnt before the first reboot.
  networking.wireless = {
    enable = true;
    interfaces = [ "wlp195s0" ];
    secretsFile = "/var/lib/wifi/env";
    networks."FoxyAP".pskRaw = "ext:psk_foxyap";
  };

  # Bootloader lives here on purpose: nixos-generate-config does not emit
  # loader settings, so keeping them out of hardware-configuration.nix
  # means that file can be replaced wholesale without losing boot config.
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;
  boot.loader.efi.canTouchEfiVariables = true;

  # Flakes + allow unfree (firmware, some tooling).
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;

  users.users.david = {
    isNormalUser = true;
    extraGroups = [ "wheel" "video" "render" ];
    # Password auth is disabled below; this key is "macbook-personal"
    # from 1Password.
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKU06G//LXXxju8FgP15WA7JBqfV07JCgIneei01tyS5 david@macbook-personal"
    ];
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # 22 = SSH, 8000 = llama-server (key-protected, LAN only behind the UDM
  # Pro Max + VPN). The Hermes dashboard (9119) is intentionally NOT opened;
  # reach it over the VPN or an SSH tunnel if you enable it.
  networking.firewall.allowedTCPPorts = [ 22 8000 ];

  # Podman: lets the kyuz0 amd-strix-halo-toolboxes containers run unchanged
  # for ROCm vs Vulkan A/B benchmarking, without committing the host to a
  # ROCm userspace. distrobox gives the same toolbox-style workflow as on
  # Fedora.
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
  };

  environment.systemPackages = with pkgs; [
    git
    vim
    btop
    distrobox
    curl
    jq
    # On-box debugging of this setup. Unfree (allowUnfree is set above);
    # authenticate once per machine with `claude login`.
    claude-code
  ];

  # Set to the release you FIRST installed from and never bump afterwards.
  system.stateVersion = "26.05";
}
