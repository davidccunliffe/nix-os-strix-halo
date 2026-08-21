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

  # The secrets file has to be readable by the *service*, not just by root.
  # The NixOS unit is hardened and runs as User=wpa_supplicant, and the
  # ext_password file backend opens the file after that privilege drop —
  # unlike systemd's own EnvironmentFile=, which is read as root beforehand.
  # A root:root 0600 file therefore fails, and fails quietly as far as the
  # console is concerned:
  #
  #   EXT PW FILE: could not open file '/var/lib/wifi/env': Permission denied
  #   wlp195s0: EXT PW: No PSK found from external storage
  #
  # leaving the box headless with no lease. Group-read for wpa_supplicant is
  # the narrowest fix that works. Enforced here rather than left to whoever
  # created the file: systemd-tmpfiles-setup.service is ordered before the
  # supplicant, so it is corrected on every boot — including the first one
  # after nixos-install, where the installer cannot set the ownership itself
  # because the user does not exist on the ISO.
  systemd.tmpfiles.rules = [
    "d /var/lib/wifi 0750 root wpa_supplicant -"
    "z /var/lib/wifi/env 0640 root wpa_supplicant -"
  ];

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
    # "hermes" is what makes the CLI usable. addToSystemPackages puts
    # `hermes` on PATH and points HERMES_HOME at /var/lib/hermes/.hermes so
    # the shell and the gateway share one set of sessions, memory and skills
    # — but that directory is 0770 hermes:hermes, so without this the CLI
    # dies before it prints anything:
    #   PermissionError: [Errno 13] Permission denied:
    #   '/var/lib/hermes/.hermes/.env'
    # The setgid bit on those directories keeps files created from the shell
    # group-owned by hermes, so the sharing actually works both ways.
    extraGroups = [ "wheel" "video" "render" "hermes" ];
    # Password auth is disabled below; this key is "macbook-personal"
    # from 1Password.
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKU06G//LXXxju8FgP15WA7JBqfV07JCgIneei01tyS5 david@macbook-personal"
    ];
  };

  # Headless, Wi-Fi-only box: without this the console shows no address and
  # there is no way to learn where to SSH short of the router's DHCP table.
  # \4{iface} is an agetty escape, resolved when the prompt is drawn — so it
  # follows the lease rather than baking an address into the Nix store.
  # Shows blank until the interface has an address; that itself is a useful
  # signal that Wi-Fi did not come up.
  services.getty.helpLine = ''
    IPv4: \4{wlp195s0}
  '';

  # mDNS, so `ssh david@ai-os.local` works from the LAN without knowing the
  # address at all. Complements the line above rather than replacing it: the
  # console still tells you the truth when name resolution is the problem.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };
  networking.firewall.allowedUDPPorts = [ 5353 ];

  # Headless box reached only by key-authenticated SSH, so the key is
  # already the strong factor and a sudo password adds little. It removes a
  # specific lockout: no password is set for `david` in this repo (a hash
  # here would be public and offline-crackable), so without this the first
  # boot gives you a shell you cannot administer from. Set a console
  # password with `passwd` for physical recovery — that is a separate path.
  security.sudo.wheelNeedsPassword = false;

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
    # Pushing this repo from the box needs credentials, and the installer
    # ISO has none (and is tmpfs, so setting them up there is wasted).
    # `gh auth login` once here, then `gh auth setup-git` routes git's
    # HTTPS credentials through it. Note the personal vs work account
    # split: check `gh auth status` before pushing.
    gh
    vim
    btop
    # Long-running agent sessions outlive the SSH link that started
    # them; without a multiplexer a dropped connection kills the run.
    tmux
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
