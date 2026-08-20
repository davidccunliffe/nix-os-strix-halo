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
2. Confirm the IOMMU is enabled.
3. Secure Boot: NixOS does not do Secure Boot out of the box. Disable it, or plan on lanzeboote later. You already know this dance from the Bazzite shim episode.

## 2. Install NixOS

Use the minimal ISO. No ethernet drop where the box lives, so get the installer online over Wi-Fi first. The wireless interface on this machine is `wlp195s0` (check `ip link` if in doubt), and the ISO's wpa_supplicant unit is unreliable — run the daemon directly:

```bash
sudo sh -c 'echo "ctrl_interface=/run/wpa_supplicant" > /etc/wpa_supplicant.conf; wpa_passphrase "FoxyAP" "the-passphrase" >> /etc/wpa_supplicant.conf'
sudo pkill wpa_supplicant
sudo wpa_supplicant -B -i wlp195s0 -c /etc/wpa_supplicant.conf
sudo dhcpcd wlp195s0
ip a && ping -c 3 nixos.org   # inet on wlp195s0, then you're online
```

(To discover an SSID: write the conf with only the ctrl_interface line, start the daemon the same way, then `sudo wpa_cli -i wlp195s0 scan` and `scan_results`. A "could not set interface p2p-dev-..." warning from wpa_supplicant is harmless.)

Then install:

```bash
# Partition and mount as usual, then:
nixos-generate-config --root /mnt

# Copy the generated hardware config into this repo:
cp /mnt/etc/nixos/hardware-configuration.nix /path/to/ai-os-nixos/

# Install from the flake (from the repo directory):
nixos-install --flake .#ai-os
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

Model download, as the llama user's directory:

```bash
sudo -u llama mkdir -p /var/lib/llama/models
# hf CLI, curl from Hugging Face, or scp from the Mac; then update
# modelFile in modules/llama-server.nix to the real filename.
```

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

Messaging (Telegram, Discord, Slack) is off by default here. To enable: uncomment `extraDependencyGroups = [ "messaging" ]` in `modules/hermes.nix`, add the bot token to `/var/lib/hermes/env`, add the platform config under `settings`, rebuild, restart. Runtime pip installs cannot work in the sealed Nix venv, which is why the dependency group must be declared.

The web dashboard (port 9119) is deliberately not in the firewall list. If you turn it on, reach it over the existing VPN or an SSH tunnel only.

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
