# AI OS on NixOS: Strix Halo + llama-server + Hermes Agent

Single-node build for the Corsair AI Workstation 300 (Strix Halo, gfx1151, 128 GB unified memory). The host runs NixOS unstable, serves models with llama-server on the Vulkan/RADV backend, and runs Nous Research's Hermes Agent as a declaratively managed systemd service pointed at that local endpoint. Nothing routes to a cloud provider: the whole point is keeping client AWS context on the LAN.

Why NixOS over the Ubuntu plan: Hermes ships an official Nix flake and NixOS module (config in Nix, secrets via env files, hardened unit, no runtime pip), the gfx1151 kernel and firmware pins become declarative instead of apt holds, and the whole box becomes one more Git-managed system alongside the Talos/Flux homelab. Caveats worth knowing up front: Hermes treats Nix as a Tier 2 best-effort platform, and the community Strix Halo material assumes Ubuntu or Fedora, so host tuning lives in `modules/strix-halo.nix` here rather than in a distro guide.

## Repo layout

```
ai-os-nixos/
|-- flake.nix                  # inputs: nixpkgs unstable, hermes-agent, (optional) nix-strix-halo
|-- configuration.nix          # user, SSH, firewall, podman
|-- hardware-configuration.nix # generated during install, copied in by you
`-- modules/
    |-- strix-halo.nix         # kernel, firmware, GTT sizing, RADV, monitoring
    |-- llama-server.nix       # Vulkan llama-server systemd service
    `-- hermes.nix             # services.hermes-agent, pointed at llama-server
```

Put this directory in a Git repo. `nixos-rebuild` against a flake requires the files to be tracked (`git add` is enough, no commit needed, but commit anyway).

## 1. BIOS

Three settings before installing:

1. Set the dedicated iGPU memory (UMA frame buffer) to a small value, 512 MB to 4 GB. The Vulkan/GTT path allocates dynamically from the shared pool, and `modules/strix-halo.nix` sizes GTT to roughly 105 GiB via `ttm.pages_limit`. A big static carve-out just strands memory.

   **This machine shipped with 96 GiB carved out and it was missed on the first install.** The symptom is quiet — nothing errors, the box just behaves as if it has a quarter of the RAM it does:

   ```
   amdgpu: VRAM: 98304M    <- 96 GiB permanently committed to the iGPU
   MemTotal:      31.0 GiB <- everything else fights over this
   ```

   Worse than the lost capacity: GTT is allocated from *system* RAM, so a 105 GiB `ttm.pages_limit` against a 31 GiB host is both unreachable and useless as a safety limit, which is the entire point of that knob. Check it every time you touch firmware:

   ```bash
   free -h                                    # want ~124 GiB, not ~31 GiB
   sudo dmesg | grep -i 'amdgpu.*VRAM'        # want a small number here
   ```
2. Confirm the IOMMU is enabled.
3. Secure Boot: NixOS does not do Secure Boot out of the box. Disable it, or plan on lanzeboote later. You already know this dance from the Bazzite shim episode.

## 2. Install NixOS

Use the minimal ISO. No ethernet drop where the box lives, so get the installer online over Wi-Fi first. The minimal ISO ships NetworkManager (verified on this machine), so do NOT hand-run wpa_supplicant — it fights NetworkManager for the interface and you end up associated but leaseless. One command does association + DHCP:

```bash
sudo pkill wpa_supplicant    # only if you started one by hand
sudo nmcli device wifi connect "FoxyAP" password "the-passphrase"
ip a && ping -c 3 nixos.org  # inet on wlp195s0, then you're online
```

To scan for SSIDs: `nmcli device wifi list`. The wireless interface on this machine is `wlp195s0`; check `ip link` if in doubt. (The installed system uses declarative wpa_supplicant from this repo, not NetworkManager — that only applies to the ISO.)

Then install:

**Most of this section is automated by `./install.sh`** (see the README
quickstart) — it does the partitioning, install, secrets, model download
and repo copy, with a `--dry-run` that prints the plan first. What follows
is the same procedure by hand, and the reasoning behind each step. Read it
if the script fails, or if the hardware differs.

```bash
# Two disks: nvme0n1 becomes the OS, nvme1n1 becomes the model store.
sgdisk --zap-all /dev/nvme0n1
sgdisk -n1:0:+1G -t1:EF00 -c1:ESP  /dev/nvme0n1
sgdisk -n2:0:0   -t2:8300 -c2:root /dev/nvme0n1
partprobe /dev/nvme0n1

mkfs.vfat -F32 -n ESP /dev/nvme0n1p1
mkfs.ext4 -L nixos -F /dev/nvme0n1p2

# Model store. -m 0: no point reserving 5% root space on a disk that
# only ever holds model weights.
sgdisk --zap-all /dev/nvme1n1
sgdisk -n1:0:0 -t1:8300 -c1:models /dev/nvme1n1
partprobe /dev/nvme1n1
mkfs.ext4 -L models -m 0 -F /dev/nvme1n1p1

# Mount all three BEFORE generating, or the generated file is missing
# filesystems and will not boot.
mount /dev/disk/by-label/nixos /mnt
mkdir -p /mnt/boot /mnt/var/lib/llama/models
mount -o umask=0077 /dev/disk/by-label/ESP /mnt/boot
mount /dev/disk/by-label/models /mnt/var/lib/llama/models

# Sanity check: exactly three lines, no duplicates. See the gotcha below.
grep ' /mnt' /proc/self/mountinfo

nixos-generate-config --root /mnt

# Copy the generated hardware config into this repo:
cp /mnt/etc/nixos/hardware-configuration.nix /path/to/ai-os-nixos/

# Install from the flake (from the repo directory). Note the NIX_CONFIG:
# nixos-install does NOT accept --extra-experimental-features and dies
# instantly on the unknown option.
sudo NIX_CONFIG='experimental-features = nix-command flakes' \
  nixos-install --flake .#ai-os
```

If the ZFS pools of a previous install are in the way, clear them first — `wipefs` alone is not enough, ZFS labels live at both ends of the device:

```bash
swapoff /dev/nvme1n1p3
zpool labelclear -f /dev/nvme1n1p2
zpool labelclear -f /dev/nvme1n1p4
wipefs -a /dev/nvme1n1p1 /dev/nvme1n1p2 /dev/nvme1n1p3 /dev/nvme1n1p4
sgdisk --zap-all /dev/nvme1n1
zpool import          # expect "no pools available to import"
```

**Gotcha: duplicated `fileSystems` entries.** `nixos-generate-config` transcribes `/proc/self/mountinfo` literally, so if a mount got stacked twice it emits `fileSystems."/"` twice — a duplicate-attribute error that fails the build. This is easy to cause: a compound `set -e` command can report failure *after* its `mount` already succeeded, and the obvious retry stacks a second mount. If the generated file looks doubled, don't blame the generator:

```bash
grep ' /mnt' /proc/self/mountinfo         # more lines than filesystems?
for i in 1 2 3 4 5; do umount -R /mnt; done
# remount once, then regenerate
```

Cheap insurance before committing to a long install — this catches the above in seconds:

```bash
nix --extra-experimental-features 'nix-command flakes' \
  eval .#nixosConfigurations.ai-os.config.system.build.toplevel.drvPath
```

**After the install finishes, check the EFI boot order.** If the disk you wiped held the previous OS, its firmware entry usually still sorts first and the box comes up on a dead entry:

```bash
efibootmgr                          # find the "Linux Boot Manager" number
efibootmgr -o 0001,0004,...         # put it first
```

Dangling entries for the destroyed OS can be left alone; they fail over harmlessly.

**The installer's home directory is tmpfs.** If you cloned this repo into the live ISO's `/home/nixos`, it — and any commits made there — evaporate on reboot. Copy it onto the target before rebooting:

```bash
cp -a /path/to/ai-os-nixos /mnt/home/david/
chown -R 1000:100 /mnt/home/david/ai-os-nixos
```

If you would rather install stock first and convert after, that works too: install normally, clone this repo, drop `hardware-configuration.nix` in, then `sudo nixos-rebuild switch --flake .#ai-os`.

Before the first rebuild, edit two placeholders:

1. `configuration.nix`: replace the SSH public key.
2. `modules/llama-server.nix`: set `modelFile` to a real GGUF path and pick your `modelAlias`. The alias must match `settings.model.default` in `modules/hermes.nix` (both ship as `local-main`).

## 3. Secrets and the model

Three env files, all root-owned and 0600. The Wi-Fi one must exist before the first headless boot (no file, no network); the llama-server one must exist before its service starts; the Hermes one can be created right after the first rebuild (the service crash-loops harmlessly until the file exists, then a restart fixes it).

```bash
# Wi-Fi passphrase for FoxyAP (during nixos-install, prefix the paths
# with /mnt so the installed system boots straight onto the network):
sudo install -d -m 0700 /var/lib/wifi
echo 'psk_foxyap=the-passphrase' | sudo install -m 0600 /dev/stdin /var/lib/wifi/env

# llama-server API key (invent one, keep it long):
sudo install -d -m 0750 -o llama -g llama /var/lib/llama
echo 'LLAMA_API_KEY=change-me-long-random' | sudo install -m 0600 -o llama /dev/stdin /var/lib/llama/env

# Hermes provider key: same value, since Hermes authenticates against
# llama-server. OPENAI_API_KEY is the conventional variable for a custom
# OpenAI-compatible base_url; if auth fails, `hermes config` and the
# Environment Variables reference in the Hermes docs will show the exact
# name the release expects.
echo 'OPENAI_API_KEY=change-me-long-random' | sudo install -m 0600 /dev/stdin /var/lib/hermes/env
```

These plain files are the bootstrap path the Hermes docs themselves suggest. The upgrade is sops-nix or agenix feeding `services.hermes-agent.environmentFiles`; since you already run YubiKey-gated age for the vault, age keys plus agenix would be the natural fit here. Do not ever move keys into `settings` or `environment` in the Nix files: anything in a Nix expression lands world-readable in /nix/store.

Model download. `install.sh` does this during the install, before the first
reboot, so llama-server and Hermes come up working instead of crash-looping
on a missing GGUF. By hand, on a running system:

```bash
sudo -u llama curl -fL -C - \
  -o /var/lib/llama/models/GLM-4.7-Flash-Q8_0.gguf \
  https://huggingface.co/ggml-org/GLM-4.7-Flash-GGUF/resolve/main/GLM-4.7-Flash-Q8_0.gguf
```

`-C -` resumes a partial file — worth having on a 32 GB download over
Wi-Fi. The filename must match `modelFile` in `modules/llama-server.nix`;
`install.sh` derives one from the other so they cannot drift.

## 4. First deploy

```bash
cd /path/to/ai-os-nixos
sudo nixos-rebuild switch --flake .#ai-os
```

First build is the slow one: kernel, Mesa, the Hermes closure (uv2nix builds every Python dep as a derivation), and llama-cpp with Vulkan.

## 5. Verify

Work up the stack in order:

```bash
# GPU visible to Vulkan? Expect "AMD Radeon Graphics (RADV GFX1151)".
vulkaninfo --summary

# GTT sizing took? Look for the ~105 GiB gtt total.
amdgpu_top -d

# llama-server up and serving?
systemctl status llama-server
curl -H "Authorization: Bearer $LLAMA_API_KEY" http://127.0.0.1:8000/v1/models

# Hermes service and CLI:
systemctl status hermes-agent
journalctl -u hermes-agent -f
hermes version
hermes config        # shows the Nix-generated config
hermes chat          # first conversation, routed through llama-server
```

Two startup gotchas that look like breakage but are config:

- Hermes refuses any model advertising under 64k context. The service log will say so. Fix is in `modules/llama-server.nix` (`ctxSize`), remembering that `-c` is the total across slots, not per slot.
- `Cannot save configuration: managed by NixOS` from any `hermes setup` or `hermes config set` attempt is the managed-mode guard working as designed. Edit `modules/hermes.nix` and rebuild instead.

## 6. Day-to-day Hermes

State lives in `/var/lib/hermes` (HERMES_HOME is `/var/lib/hermes/.hermes`): memory, skills, sessions, cron, state.db. Back that directory up; it is the part of the agent that grows.

Because `addToSystemPackages = true`, your shell's `hermes` and the gateway service share that state. The agent's persona file is `/var/lib/hermes/.hermes/SOUL.md`, managed directly on disk, and workspace context files can be installed declaratively via the module's `documents` option (`USER.md` is the conventional one).

## 6a. Discord bot

`extraDependencyGroups = [ "messaging" ]` is set in `modules/hermes.nix`. On Nix this is not optional the way it is elsewhere: the venv is sealed and read-only, so a missing extra cannot be pip-installed at runtime and must be resolved in at build time. Without it the gateway starts and logs `No adapter available for discord`.

Everything else is browser work in the [Discord Developer Portal](https://discord.com/developers/applications), because the bot token is shown exactly once and only to a signed-in session.

1. **New Application.** Note the **Application ID**.
2. **Bot** tab → **Public Bot** ON (required to use the Discord-provided invite link; if you want it private you must build the OAuth2 URL by hand).
3. **Privileged Gateway Intents** → enable **Message Content Intent** *and* **Server Members Intent**. Save.

   Do not skip this. It is the single most common failure mode: without Message Content Intent the bot connects, shows online, and receives message events whose text is *empty*, so it silently never answers. A bot that is online and mute is almost always this.
4. **Reset Token**, copy it immediately.
5. **Invite it.** A `discord.gg/...` link is a *server* invite for humans and cannot add a bot. You need an OAuth2 authorize URL built from your own Application ID:

   ```
   https://discord.com/oauth2/authorize?client_id=YOUR_APP_ID&scope=bot+applications.commands&permissions=274878286912
   ```

   `274878286912` = View Channels, Send Messages, Read Message History, Attach Files, Embed Links, Send Messages in Threads, Add Reactions. You need **Manage Server** on the target server to authorize.
6. **Your Discord user ID:** Settings → Advanced → Developer Mode ON, then right-click your name → Copy User ID.

Then on the box — credentials go in the env file, never in `settings` or `environment`, which land world-readable in `/nix/store`:

```bash
sudo tee -a /var/lib/hermes/env >/dev/null <<'EOF'
DISCORD_BOT_TOKEN=...
DISCORD_ALLOWED_USERS=your-user-id      # comma-separate for more
EOF
sudo chmod 0600 /var/lib/hermes/env

sudo nixos-rebuild switch --flake .#ai-os   # slow: messaging pulls a large dep set
systemctl restart hermes-agent
journalctl -u hermes-agent -f
```

`environmentFiles` is **not** a systemd `EnvironmentFile=` — the module merges those files into `$HERMES_HOME/.env` at activation, so the unit has no `EnvironmentFile` line and changes need a `nixos-rebuild switch`, not just a restart. Confirm with:

```bash
sudo cut -d= -f1 /var/lib/hermes/.hermes/.env    # key names only
```

Behaviour once it is up: **DMs** get answered every time, **server channels** only on `@mention`. Each user in a shared channel gets their own session by default (`group_sessions_per_user: true`) so two people in one channel do not share a transcript. To make a channel mention-free, add it to `DISCORD_FREE_RESPONSE_CHANNELS`.

Hermes needs llama-server answering before any of this works — the bot will come online and then fail on every message if no model is loaded. Get §5 green first.

## 6b. Remote access to Hermes

`backend.mode` defaults to `"none"`, and `modules/hermes.nix` does not set it. The unit runs `hermes gateway`, which is the *messaging* gateway only. The web dashboard and the `/api/ws` + `/api/pty` sockets that Hermes Desktop connects to come from a different process (`hermes serve` / `hermes dashboard`). So out of the box the only remote access is SSH in and run `hermes` interactively — which works fine and shares state with the service.

For a real endpoint, in `modules/hermes.nix`:

```nix
backend.mode = "dashboard";   # or "serve" for no UI, Desktop sockets only
backend.port = 9119;
```

Reach it over an SSH tunnel; 9119 is deliberately absent from the firewall list in `configuration.nix`:

```bash
ssh -L 9119:127.0.0.1:9119 david@<box>
# then http://127.0.0.1:9119
```

The tunnel is not just caution. The backend binds `127.0.0.1` by default, any other bind address turns on an authentication gate, and it rejects requests whose `Host` header does not match the address it bound to as a DNS-rebinding defence. Tunnelling to `127.0.0.1:9119` satisfies all of that; exposing it on the LAN means solving both.

Claude Code as a second client of the same endpoint keeps working exactly as documented in your stack notes: `ANTHROPIC_BASE_URL` at the llama-server endpoint, attribution header disabled in settings.json, and mind the process-global URL scope.

## 7. ROCm A/B benchmarking

The host stays Vulkan. When you want to re-check the ROCm side (the 7.x prefill regression on gfx1151 is exactly why you benchmark before committing):

Option A, kyuz0 toolboxes, unchanged from the Fedora days since podman + distrobox are installed:

```bash
distrobox create --image docker.io/kyuz0/amd-strix-halo-toolboxes:rocm7 rocm-bench
distrobox enter rocm-bench
llama-bench -m /var/lib/llama/models/<model>.gguf -ngl 99 -fa 1 -p 512,2048,8192 -n 128
```

Run the same `llama-bench` matrix against the host Vulkan build and compare prefill (pp) and decode (tg) side by side at your production `--parallel`.

Option B, the `nix-strix-halo` flake (uncomment in `flake.nix`): gives `llama-cpp-rocm` built against the TheRock SDK plus `llama-cpp-master-vulkan` for HEAD builds, all as Nix packages. Treat it as a benchmarking convenience, not a foundation: upstream marks it pre-1.0 with an explicit no-support warning.

## 8. Updating

```bash
cd /path/to/ai-os-nixos
nix flake update            # or: nix flake update hermes-agent
sudo nixos-rebuild switch --flake .#ai-os
```

Before switching after a nixpkgs bump, check the one known landmine:

```bash
nix eval nixpkgs#linux-firmware.version   # must not be 20251125
```

Rollback is `sudo nixos-rebuild switch --rollback`, or pick the previous generation in the boot menu. This is the concrete win over the Ubuntu path: a bad kernel, Mesa, or ROCm bump is one reboot away from undone.

Because llama.cpp and Mesa both move fast and both change the Vulkan-vs-ROCm balance, re-run the section 7 A/B after any update that touches either.

## 9. Troubleshooting

| Symptom | Likely cause, fix |
| --- | --- |
| `vulkaninfo` shows no gfx1151 device | Kernel or firmware mismatch. Confirm `linuxPackages_latest` is 6.18.4 or newer and recheck the firmware version. |
| Model load fails with allocation errors | GTT too small. Confirm `ttm.pages_limit` params are live: `cat /proc/cmdline`, and check `amdgpu_top` GTT total. |
| Hermes exits citing model context | Serve at 64k or more for the slot Hermes uses; `-c` is total across `--parallel` slots. |
| Hermes cannot authenticate | Wrong env var name or value mismatch with `LLAMA_API_KEY`. Inspect `sudo -u hermes cat /var/lib/hermes/.hermes/.env`. |
| `hermes setup` or `config set` refuses | Managed mode. Edit `modules/hermes.nix`, rebuild. |
| Messaging platform "no adapter available" | Dependency group missing from the sealed venv. Set `extraDependencyGroups = [ "messaging" ]`, rebuild, restart. |
| ROCm container cannot see the GPU | Toolbox needs `/dev/kfd` and `/dev/dri` plus video/render groups; distrobox passes these by default, plain `podman run` needs `--device` flags. |
| Service works, `hermes` CLI shows stale state | `addToSystemPackages` was toggled after first use, leaving a second `~/.hermes`. Remove the stray one. |

## Deferred decisions, on purpose

Router mode with the planner/worker/task-agent split drops into `modules/llama-server.nix` when you land it: swap the single `-m` invocation for the router flags, keep MTP off any server running `--parallel` above 1. Secrets graduate from plain files to agenix when convenient. And if the agent ever needs to install its own tooling at runtime, that is the module's container mode (with the podman backend), one flag away without touching the rest of this setup.
