# ai-os-nixos

NixOS flake for the AI OS box: a Strix Halo (gfx1151, 128 GB unified memory) inference node running llama-server on Vulkan/RADV and Nous Research's Hermes Agent, everything local, nothing routed to a cloud provider.

Full walkthrough (BIOS, install, secrets, verification, benchmarking, troubleshooting): see `ai-os-nixos-guide.md`.

## Layout

```
flake.nix                  inputs: nixpkgs unstable, hermes-agent, (optional) nix-strix-halo
flake.lock                 pinned inputs; committed
configuration.nix          bootloader, user, SSH, firewall, podman
hardware-configuration.nix generated on this machine; real, not a placeholder
modules/strix-halo.nix     kernel, firmware, GTT sizing, RADV, monitoring
modules/llama-server.nix   Vulkan llama-server systemd service
modules/hermes.nix         services.hermes-agent pointed at llama-server
secrets/*.env.example      templates for the three runtime env files
docs/session-notes-*.md    what was actually done, and what bit us
```

## Disk layout

Installed 2026-08-20. Both NVMe drives are in use:

| Disk | Layout |
| --- | --- |
| `nvme0n1` | `p1` 1 GB ESP (vfat, `/boot`) · `p2` rest ext4 (`/`) · no swap |
| `nvme1n1` | `p1` whole-disk ext4, mounted at `/var/lib/llama/models` |

The model store is its own disk, so `modules/llama-server.nix` orders the
unit against that mount (`RequiresMountsFor`). No swap anywhere — it would
fight the GTT pool.

## Quickstart

Day-to-day, from a checkout on the box:

```bash
sudo nixos-rebuild switch --flake .#ai-os

# Update later:
nix flake update && sudo nixos-rebuild switch --flake .#ai-os
```

Runtime secrets, none of them in this repo (templates in `secrets/`, exact
commands in guide §3):

```
/var/lib/wifi/env     psk_foxyap=...          Wi-Fi passphrase; needed at first boot or the box is headless and offline
/var/lib/llama/env    LLAMA_API_KEY=...
/var/lib/hermes/env   OPENAI_API_KEY=...      same value as above
                      DISCORD_BOT_TOKEN=...   optional, see guide §6
                      DISCORD_ALLOWED_USERS=...
```

Check `nix eval nixpkgs#linux-firmware.version` is not `20251125` after any
nixpkgs bump — that release breaks ROCm on Strix Halo.

## BIOS

Three settings, and the first one is easy to get wrong:

1. **iGPU / UMA frame buffer: 512 MB – 4 GB.** Not larger. The Vulkan/GTT
   path allocates dynamically from the unified pool; a big static carve-out
   permanently strands that memory and starves the host. This box shipped
   with **96 GiB** carved out, which left the OS 31 GiB and made the
   105 GiB `ttm.pages_limit` in `modules/strix-halo.nix` unreachable.
   Verify after boot with `free -h` — expect ~124 GiB, not ~31 GiB.
2. IOMMU enabled.
3. Secure Boot disabled (NixOS does not do Secure Boot out of the box).
