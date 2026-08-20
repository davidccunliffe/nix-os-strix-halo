# Session notes — 2026-08-19/20 (repo prep + install debugging)

Sanitized log of the Claude Code session that prepared this repo for first
deployment. Secrets, tokens, passphrases, and account identifiers are omitted;
none were ever committed.

## What was done, in order

1. **Repo published** to the personal GitHub account at
   `davidccunliffe/nix-os-strix-halo`. The machine's default git/`gh`
   credentials were the work account, so the first push 403'd; fixed by adding
   the personal account to `gh` (`gh auth login`), switching with
   `gh auth switch`, and routing git credentials through `gh auth setup-git`.
   Both accounts remain logged in — check `gh auth status` before pushing from
   this Mac. The initial commit was re-authored from the work email to
   `davidccunliffe@gmail.com` before anything was pushed, and this repo's local
   git config now uses the personal identity.

2. **SSH key** — the placeholder in `configuration.nix` was replaced with the
   real ed25519 public key (the personal MacBook key, stored in 1Password).
   Password/root SSH auth stay disabled.

3. **Model selected: GLM-4.7-Flash Q8_0** (official `ggml-org` GGUF, ~32 GB).
   Rationale: latest GLM generation (Jan 2026), current community standard on
   Strix Halo, carries the `nextn` MTP head matching the speculative-decode
   notes in `modules/llama-server.nix`, and Q8_0 fits the ~105 GiB GTT pool
   with the full 131k context — no reason to drop to Q4. Download command is
   commented next to `modelFile` in `modules/llama-server.nix`.

4. **Declarative Wi-Fi added** (`networking.wireless` in `configuration.nix`):
   wpa_supplicant pinned to interface `wlp195s0`, SSID `FoxyAP`, passphrase
   read at runtime from `/var/lib/wifi/env` via `pskRaw = "ext:psk_foxyap"`
   (template: `secrets/wifi.env.example`). The passphrase never enters the
   repo or the Nix store. **Wi-Fi does not come up unless that file exists**,
   so during install it must be created under `/mnt` before the first reboot.

5. **Installer Wi-Fi debugging** (the hard-won part — see guide §2 for the
   final procedure):
   - The minimal ISO **ships NetworkManager**. The entire manual
     wpa_supplicant/wpa_passphrase dance is unnecessary and actively harmful:
     a hand-run wpa_supplicant fights NetworkManager for the interface,
     leaving it associated but leaseless.
   - Working method: `sudo pkill wpa_supplicant` (if one was started), then
     `sudo nmcli device wifi connect "FoxyAP" password "<passphrase>"` — one
     command handles association + DHCP.
   - There is no `dhcpcd` command or service on this ISO.
   - Wireless interface on this hardware is `wlp195s0`. Note `eno1` exists —
     the box has an ethernet port, so a temporary cable is a zero-config
     fallback.
   - Misc: wpa_supplicant's "could not set interface p2p-dev-..." warning is
     harmless; `wpa_cli` needs `-i <real interface>` and a
     `ctrl_interface=/run/wpa_supplicant` line in the conf to connect at all.

6. **Repo made PRIVATE and stays private.** The SSID had been pushed while the
   repo was public (~1 day exposure, passphrase never committed). SSIDs are
   wardriving-indexable and linkable to a location via a named GitHub account,
   so private is the resting state. Standing rule from this session: **ask
   before publishing anything potentially sensitive** (SSIDs, hostnames,
   network layout), even gray-zone data.

7. **Housekeeping** — `.DS_Store` untracked and gitignored; `claude-code`
   added to `environment.systemPackages` for on-box debugging (verified
   present in nixos-unstable; run `claude login` once after first boot).

## Current state

Repo-side work is **complete**. Everything below happens on the box:

- [ ] Install NixOS from minimal ISO (Wi-Fi via `nmcli`, guide §2)
- [ ] `nixos-generate-config --root /mnt`; copy the real
      `hardware-configuration.nix` over the placeholder in this repo; commit it
- [ ] Create `/mnt/var/lib/wifi/env` (`psk_foxyap=...`) **before rebooting**
- [ ] `nixos-install --flake .#ai-os`, reboot, confirm the box appears on
      FoxyAP and SSH works as `david`
- [ ] Create `/var/lib/llama/env` (`LLAMA_API_KEY=`) and `/var/lib/hermes/env`
      (`OPENAI_API_KEY=` — same value); guide §3
- [ ] Download `GLM-4.7-Flash-Q8_0.gguf` into `/var/lib/llama/models/`
- [ ] Commit `flake.lock` after first build; verify
      `nix eval nixpkgs#linux-firmware.version` ≠ `20251125`
- [ ] Verify per guide §5 (RADV visible, GTT ~105 GiB, llama-server answering,
      Hermes up)

Note: the repo is private, so cloning on the box needs auth — `gh auth login`
there, or `scp` the repo over from the Mac once SSH is up.

## Deferred / optional follow-ups

- MTP speculative decode: `--parallel` is 1, so GLM-4.7-Flash qualifies for
  the `--spec-type draft-mtp` flags commented in `modules/llama-server.nix`.
  Try after the base deploy verifies; check acceptance rate in logs.
- `--threads 8` could go to 16 (CPU has 16 cores); irrelevant while fully
  offloaded with `-ngl 99`.
- `system.stateVersion` is `26.05` — correct only if installing from a 26.05
  or current-unstable ISO; set to the actual installer release, then freeze.
- ROCm vs Vulkan A/B benchmarking via the kyuz0 podman toolboxes (guide §7),
  re-run after each llama.cpp/Mesa bump.
- Secrets upgrade path: sops-nix or agenix replacing the plain
  `/var/lib/*/env` files.
