# Session notes — 2026-08-20 (first install onto the box)

Sanitized log of the Claude Code session that took this repo from
"prepared" to "installed". Run from the minimal ISO, on the machine.
Secrets, passphrases, LAN addresses and device serials are omitted; none
were ever committed.

Continues from [`session-notes-2026-08-19.md`](session-notes-2026-08-19.md).

## Starting state

Booted from the 26.05 minimal ISO with Wi-Fi already up via `nmcli` (guide
§2 works as written). Nothing mounted, nothing installed. The repo's
`hardware-configuration.nix` had been regenerated in a previous attempt
**without `/mnt` mounted**, so it carried kernel modules but no
`fileSystems` entries at all — it would not have booted. Discarded and
regenerated properly (below).

## Disk layout decided this session

The box has two 1.9 TB NVMe drives. `nvme0n1` was blank; `nvme1n1` held an
intact ZFS-on-root install (the factory image — `bpool`/`rpool`, plus its
own ESP and an 8 GB swap partition). Both pools imported cleanly, so this
was a live OS, not leftovers.

Chosen layout — **the factory install was deliberately destroyed**:

| Disk | Layout |
| --- | --- |
| `nvme0n1` | `p1` 1 GB ESP (vfat, `/boot`) · `p2` rest ext4 (`/`) · no swap |
| `nvme1n1` | `p1` single ext4 volume, whole disk, mounted at `/var/lib/llama/models` |

Rationale: keeps the OS and the model store on separate spindles, gives
the GGUFs a dedicated 1.9 TB that a root-filesystem mishap can't touch,
and leaves no swap to fight the GTT pool (per `modules/strix-halo.nix`).
`mkfs.ext4 -m 0` on the model disk — no point reserving 5% root space on a
volume that only ever holds model weights.

## What was done, in order

1. **Partitioned and formatted `nvme0n1`**, mounted `/` and `/boot`.

2. **Destroyed the ZFS pools on `nvme1n1`** (`zpool labelclear`, `wipefs`,
   `sgdisk --zap-all`), repartitioned as one ext4 volume, mounted at
   `/mnt/var/lib/llama/models`. Confirmed `zpool import` afterwards
   reports no pools.

3. **Regenerated `hardware-configuration.nix`** with all three
   filesystems mounted, and copied it into the repo. It now carries a
   third `fileSystems` entry for the model disk, so the layout is
   declarative rather than something to remount by hand.

   **Gotcha worth remembering:** the first regeneration emitted *duplicate*
   `fileSystems."/"` and `fileSystems."/boot"` attributes — a Nix syntax
   error that would have failed the install. Cause was `/mnt` being
   mounted twice: a compound `set -e` command reported failure after the
   `mount` had already succeeded, and the retry stacked a second mount on
   top. `nixos-generate-config` reads `/proc/self/mountinfo` verbatim, so a
   stacked mount becomes a duplicate attribute. If the generated file looks
   doubled, check `grep ' /mnt' /proc/self/mountinfo` before blaming the
   generator, and `umount -R /mnt` in a loop until it's clean.

4. **Added mount ordering to `modules/llama-server.nix`:**
   `unitConfig.RequiresMountsFor = [ "/var/lib/llama/models" ]`. Only
   needed because the models directory became its own filesystem this
   session — without it the service can start against an empty mountpoint
   and crash-loop on a "missing" GGUF if the disk is slow to appear.
   Note this belongs in `unitConfig`, not `serviceConfig`:
   `RequiresMountsFor=` is a `[Unit]` directive.

5. **Verified the whole flake evaluates** (`nix eval
   ...system.build.toplevel.drvPath`) before committing to a long install.
   Cheap, and catches exactly the class of error in step 3.

6. **Created the three secret files under `/mnt`**, all `0600`:
   `/mnt/var/lib/wifi/env`, `/mnt/var/lib/llama/env`,
   `/mnt/var/lib/hermes/env`. The llama and hermes files share one
   generated key, verified identical.

   Two deviations from guide §3, both deliberate:
   - Files are `root:root`, not owned by the `llama` service account.
     systemd reads `EnvironmentFile=`/`environmentFiles` as root before
     dropping privileges, so this works and keeps the key off a service
     account. (The `models` *directory* still gets `llama:llama` from the
     `systemd.tmpfiles` rule at boot.)
   - The Wi-Fi passphrase was lifted straight from the ISO's saved
     NetworkManager connection rather than retyped, so it never passed
     through a terminal or a transcript.

7. **`nixos-install --flake .#ai-os --no-root-password`** → `installation
   finished!`. Generation 1, Linux 7.2, systemd-boot installed.

   Flag: `nixos-install` does **not** accept `--extra-experimental-features`.
   The first attempt died instantly on the unknown option. Pass flakes
   config via the environment instead:
   `sudo NIX_CONFIG='experimental-features = nix-command flakes' nixos-install ...`

8. **Fixed the EFI boot order.** After install, firmware still listed the
   (now destroyed) factory entry first, so the box would not have come up
   on NixOS. Reordered with `efibootmgr -o` to put `Linux Boot Manager`
   first. The dead factory and Windows entries were left in place rather
   than deleted — they dangle harmlessly, and firmware variable deletion
   is not worth the risk. Clean them from the BIOS menu at leisure.

## Verified before reboot

- `/boot/loader/entries/nixos-*.conf` present, kernel + initrd in
  `/boot/EFI/nixos/`
- Boot entry carries the expected `ttm.pages_limit` / `ttm.page_pool_size`
  GTT sizing from `modules/strix-halo.nix`
- `/nix/var/nix/profiles/system` → `system-1-link`
- All three env files survived the install with `0600` intact
- `efibootmgr` shows `Linux Boot Manager` first

Note: `/boot` is mounted `dmask=0077`, so a non-root `ls` of it returns
nothing and looks alarmingly like a failed bootloader install. Use `sudo`.

## ⚠ BIOS memory carve-out is wrong — guide §1 step 1 was skipped

Measured from the live ISO, **before** the first NixOS boot:

```
amdgpu: VRAM: 98304M  (96.0 GiB statically carved out in BIOS)
MemTotal:      31.0 GiB  (all the OS gets)
                       -> ~126 GiB installed, as expected
```

Guide §1 step 1 says to set the UMA frame buffer to **512 MB – 4 GB**.
It is currently at **96 GiB**, which is the exact "big static carve-out
just strands memory" case `modules/strix-halo.nix` warns about.

Why it matters here specifically:

- `ttm.pages_limit=27648000` asks for a **105.47 GiB** GTT pool. GTT is
  allocated from *system* RAM, and system RAM is 31 GiB. The cap is
  therefore both unreachable and useless as a safety limit — it no longer
  bounds GTT below physical memory, which is what that knob is for.
- The Vulkan/GTT path this repo is built around allocates dynamically from
  the shared pool. Carving 96 GiB off as dedicated VRAM defeats the design:
  the memory is committed to the iGPU whether or not a model is loaded, and
  the OS, Hermes and podman are left sharing 31 GiB.
- The live ISO showed `GTT: 15862M` — that is the kernel default (roughly
  half of system RAM), not our setting, since the ISO doesn't carry our
  kernel params. Expect GTT after reboot to be bounded by the 31 GiB of
  system RAM, nowhere near 105 GiB.

**Fix: reboot into BIOS, set the UMA / iGPU dedicated memory down to
512 MB – 4 GB.** No repo change is needed — `strix-halo.nix` is already
correct *for the intended BIOS setting*. Only the firmware is wrong.

Do this before benchmarking or drawing any conclusion about performance;
a 32 GB Q8_0 model plus a 131k KV cache will behave very differently on a
31 GiB host pool than on a ~124 GiB one.

## Current state

Installed, not yet rebooted. Remaining:

- [ ] **Set BIOS UMA carve-out to 512 MB – 4 GB** (see above) — do this on
      the same trip to the BIOS as removing the USB

- [ ] Reboot, remove the USB, confirm the box joins Wi-Fi and SSH works as
      `david`
- [ ] Download `GLM-4.7-Flash-Q8_0.gguf` (~32 GB) into
      `/var/lib/llama/models/`
- [ ] Verify per guide §5 (RADV visible, GTT ~105 GiB, llama-server
      answering, Hermes up)
- [ ] Confirm `nix eval nixpkgs#linux-firmware.version` ≠ `20251125`

## Correction to the previous session's notes

`session-notes-2026-08-19.md` item 6 records the repo as having been made
private and staying private. **That is no longer accurate — the repo is
public** (verified unauthenticated against the GitHub API this session).

The reasoning in that item still stands on its merits: the SSID is
committed in `configuration.nix`, and an SSID plus a named GitHub account
is wardriving-indexable and locatable. Nothing secret is exposed — the
passphrase has never been committed and still isn't — but the network name
is, and that was the exposure the earlier decision was meant to close.
Left as-is pending a decision; see the open question below.

## Open questions

- **Repo visibility vs. the committed SSID.** Either flip back to private,
  or scrub the SSID from `configuration.nix` (it can move into
  `/var/lib/wifi/env` alongside the passphrase and be referenced
  indirectly), the guide, the README, and both session-notes files. Worth
  settling before the repo accumulates more history — scrubbing later
  means rewriting it.

## Deferred / optional follow-ups

Carried forward unchanged from the previous session: MTP speculative
decode, `--threads` tuning, ROCm vs Vulkan A/B benchmarking, and the
sops-nix / agenix secrets upgrade. See
[`session-notes-2026-08-19.md`](session-notes-2026-08-19.md).

`system.stateVersion` is settled: `26.05`, matching the ISO actually
installed from. Do not bump it.
