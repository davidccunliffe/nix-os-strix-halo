# ai-os-nixos

NixOS flake for the AI OS box: a Strix Halo (gfx1151, 128 GB unified memory) inference node running llama-server on Vulkan/RADV and Nous Research's Hermes Agent, everything local, nothing routed to a cloud provider.

Full walkthrough (BIOS, install, secrets, verification, benchmarking, troubleshooting): see `ai-os-nixos-guide.md`.

## Layout

```
install.sh                 bare-metal installer: disks, install, secrets, model
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

## Quickstart — bare metal to working agent

From the NixOS **minimal ISO**, booted in UEFI mode. Roughly an hour, most
of it the build and the model download.

### 1. Get the installer online

The minimal ISO ships NetworkManager. Do **not** hand-run `wpa_supplicant`
— it fights NetworkManager for the interface and leaves you associated but
with no lease. Two commands:

```bash
sudo nmcli device wifi connect "YOUR_SSID" password "your-passphrase"
ping -c3 nixos.org
```

`nmcli device wifi list` to scan. A temporary ethernet cable also works and
needs no configuration.

### 2. Set the BIOS

Reboot into firmware and set the **iGPU / UMA frame buffer to 512 MB – 4 GB**.
Not larger. This box shipped at 96 GiB, which leaves the host 31 GiB and
silently starves everything — see the BIOS section below. Also: IOMMU on,
Secure Boot off.

Easier now than after the install.

### 3. Run the installer

```bash
git clone https://github.com/davidccunliffe/nix-os-strix-halo
cd nix-os-strix-halo

sudo ./install.sh --dry-run    # prints the plan, touches nothing
sudo ./install.sh              # asks you to type DESTROY, then goes
```

**This wipes both NVMe drives, including any existing OS.** The dry run
shows exactly what is on them first.

It partitions both disks, generates and commits the real
`hardware-configuration.nix`, writes the three secret files, runs
`nixos-install`, **downloads the model**, copies this repo to
`/home/david/` and fixes the EFI boot order.

Just before the DESTROY prompt it asks whether to set a console password
for `david`. This repo commits no password — a hash here would be public
and offline-crackable — so by default the installed box has console login
disabled and is reachable only by SSH key, which is no way in at all if
Wi-Fi does not come up on the first boot. Answering yes writes `ChangeMe`
and immediately expires it, so the first login has to replace it. Skip the
question with `--set-password` / `--no-set-password`, or choose your own
with `--password=…`.

While the password is expired, an interactive `ssh david@…` still works and
runs `passwd` for you; non-interactive SSH (`scp`, `rsync`, `ssh host cmd`)
is refused until it has been changed, because there is no TTY to run
`passwd` on.

The model download happens *before* the reboot on purpose: llama-server
and Hermes both come up working on first boot instead of crash-looping on
a missing GGUF.

### 4. Reboot

Pull the USB. Then confirm the stack (details in guide §5):

```bash
free -h                                  # ~124 GiB — if ~31 GiB, step 2 was missed
systemctl status llama-server hermes-agent
hermes chat
```

### 5. Discord bot — optional, after the box is up

Not covered by the script: it needs a bot token from the Discord Developer
Portal, which only exists in a signed-in browser session. **A `discord.gg`
invite link cannot add a bot** — you need an OAuth2 URL built from your own
Application ID.

Full walkthrough in **guide §6a**. The short version: create the app,
enable **Message Content Intent** *and* **Server Members Intent** (skipping
these is why a bot sits online and never replies), copy the token, invite
via the OAuth2 URL, then:

```bash
sudo tee -a /var/lib/hermes/env >/dev/null <<'EOF'
DISCORD_BOT_TOKEN=...
DISCORD_ALLOWED_USERS=your-discord-user-id
EOF
sudo nixos-rebuild switch --flake .#ai-os
```

Remote access to the Hermes dashboard is off by default — guide §6b.

## Day to day

From the checkout on the box:

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
