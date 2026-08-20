# ai-os-nixos

NixOS flake for the AI OS box: a Strix Halo (gfx1151, 128 GB unified memory) inference node running llama-server on Vulkan/RADV and Nous Research's Hermes Agent, everything local, nothing routed to a cloud provider.

Full walkthrough (BIOS, install, secrets, verification, benchmarking, troubleshooting): see `ai-os-nixos-guide.md`.

## Layout

```
flake.nix                  inputs: nixpkgs unstable, hermes-agent, (optional) nix-strix-halo
flake.lock                 created by nix on first build; commit it
configuration.nix          bootloader, user, SSH, firewall, podman
hardware-configuration.nix EXAMPLE, overwrite with your generated one
modules/strix-halo.nix     kernel, firmware, GTT sizing, RADV, monitoring
modules/llama-server.nix   Vulkan llama-server systemd service
modules/hermes.nix         services.hermes-agent pointed at llama-server
secrets/*.env.example      templates for the two runtime env files
```

## Quickstart

Placeholders to change before the first build: the SSH key in `configuration.nix`, `modelFile` and `modelAlias` in `modules/llama-server.nix` (alias must match `settings.model.default` in `modules/hermes.nix`), and `hardware-configuration.nix` (replace with the generated file).

```bash
git init && git add -A     # flakes only see tracked files

# On the machine, after copying the real hardware-configuration.nix in:
sudo nixos-rebuild switch --flake .#ai-os

# Runtime secrets (see secrets/ for the templates, guide section 3
# for the exact install commands):
#   /var/lib/wifi/env     psk_foxyap=...       (Wi-Fi passphrase, needed at first boot)
#   /var/lib/llama/env    LLAMA_API_KEY=...
#   /var/lib/hermes/env   OPENAI_API_KEY=...   (same value)

# Update later:
nix flake update && sudo nixos-rebuild switch --flake .#ai-os
```

`flake.lock` does not ship in this scaffold; the first `nix flake lock` or rebuild writes it. Commit it so every rebuild is reproducible, and check `nix eval nixpkgs#linux-firmware.version` is not 20251125 after any nixpkgs bump.
