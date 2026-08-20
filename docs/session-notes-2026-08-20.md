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
     **This was right for llama and hermes and wrong for Wi-Fi** — see
     "After the first reboot" below. wpa_supplicant reads its secrets
     file itself, as an unprivileged user, not via `EnvironmentFile=`.
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


## After the first reboot: Wi-Fi did not come up

The box booted, but the console `IPv4:` line was blank and nothing answered
on the LAN. Diagnosed at the keyboard with `wifi-diag.sh`. The card, the
firmware, rfkill and the unit were all fine — the supplicant simply never
got the passphrase:

```
EXT PW FILE: could not open file '/var/lib/wifi/env': Permission denied
wlp195s0: EXT PW: No PSK found from external storage
wlp195s0: SAE: No password found from external storage
wlp195s0: Added BSSID ... into ignore list
```

**Cause: the secrets file was root-owned 0600, and wpa_supplicant does not
run as root.** The NixOS unit is hardened — `User=wpa_supplicant`,
`ProtectSystem=strict`, `RootDirectory=/run/wpa_supplicant` — and the
`ext_password` file backend opens `/var/lib/wifi/env` from inside the
service, *after* the privilege drop. So step 6 above generalised the wrong
rule: "systemd reads `EnvironmentFile=` as root before dropping privileges"
is true, and is why root:root 0600 is correct for the llama and hermes env
files, but the Wi-Fi file is not an `EnvironmentFile=` — it is read by the
daemon itself. Same-looking file, different reader.

Fixed by hand on the box:

```bash
sudo chgrp wpa_supplicant /var/lib/wifi /var/lib/wifi/env
sudo chmod 0750 /var/lib/wifi
sudo chmod 0640 /var/lib/wifi/env
sudo systemctl restart wpa_supplicant-wlp195s0.service
```

Associated and got a lease immediately.

Made durable in the repo, since a hand `chgrp` is exactly the kind of thing
the next reinstall loses:

- `configuration.nix` grows a `systemd.tmpfiles.rules` block setting
  `/var/lib/wifi` to `0750 root wpa_supplicant` and the env file to
  `0640 root wpa_supplicant`. `systemd-tmpfiles-setup.service` is ordered
  before the supplicant (verified with `systemctl show -p After`), so the
  ownership is corrected on every boot, including the first one after an
  install.
- `install.sh` keeps writing the file root:root 0600 — the ISO has no
  `wpa_supplicant` user to hand it to — but now refuses to run if that
  tmpfiles rule is missing from `configuration.nix`. Losing the rule
  silently produces a headless box, which is the worst possible failure on
  a machine with no ethernet.
- `wifi-diag.sh` no longer just prints the file's mode. It asks the unit
  which user it runs as and tests readability *as that user*, so this
  failure names itself instead of looking like a wrong passphrase. The
  "Permission denied" journal line is in the troubleshooting list too.
- `wifi-diag.sh` also stopped crying wolf at a link that is merely still
  coming up. Running a plain report immediately after
  `systemctl restart wpa_supplicant-...` caught the interface mid-negotiation
  — measured here as ~5s to associate and ~10s before dhcpcd has the lease
  and routes back — so it reported "not associated" and "no IPv4 address"
  about a link that `ip a` showed up and addressed seconds later. It now
  waits up to 20s for carrier plus an address before judging, and prints how
  long it waited. A genuinely dead link still fails, just 20s later.
- Guide §3 and `secrets/wifi.env.example` now give the group-readable
  `install` commands, with the /mnt variant called out separately.


### Proven end to end, not just asserted

The rule was tested against the failure it exists to prevent, rather than
against an already-correct file. Permissions were reset to exactly what
`install.sh` leaves behind, and the box rebooted from there:

```
15:38:39  chown root:root /var/lib/wifi /var/lib/wifi/env
15:38:49  chmod 0700 /var/lib/wifi ; chmod 0600 /var/lib/wifi/env
15:39:04  reboot
15:39:31  systemd-tmpfiles-setup.service: Finished
15:39:31  Started WPA Supplicant instance for interface wlp195s0
15:39:36  CTRL-EVENT-CONNECTED
```

`stat` afterwards shows `ctime=15:39:31.059` on both paths — tmpfiles
touched them during that boot, not some earlier hand fix — and the boot
carries zero `EXT PW FILE: could not open` lines, against many on the
14:21 boot. The ordering claim is therefore measured, not inferred from
the unit file.

Worth keeping in mind for the sops-nix/agenix upgrade in the deferred list:
the same distinction applies there. Whatever supplies this file has to make
it readable to `wpa_supplicant`, not just to root.

## Current state

Installed, booted, on the network, serving. Verified this session:
`MemTotal` 124 GiB (so the BIOS carve-out was corrected), the 32 GB
`GLM-4.7-Flash-Q8_0.gguf` is on the model disk, `llama-server` answers
`/health` and `hermes-agent` is active.

- [x] **BIOS UMA carve-out** set down — `free -g` now reports 124 GiB total
      to the OS, not 31
- [x] Rebooted, USB removed, box joins Wi-Fi and SSH works as `david`
      — but only after the secrets-file permission fix above; the first
      boot came up headless
- [x] `GLM-4.7-Flash-Q8_0.gguf` downloaded into `/var/lib/llama/models/`
- [x] Verify per guide §5 — measured after the reboot: BIOS carve-out now
      `VRAM: 1024M` (inside the 512 MB – 4 GB the guide asks for),
      `108000M of GTT memory ready` (so `ttm.pages_limit=27648000` is both
      in effect and reachable against 124 GiB of system RAM), and with the
      model loaded `mem_info_gtt_used` sits at 33.5 GiB — the Q8_0 weights
      are resident on the iGPU, not in a CPU fallback. A 24-token
      completion returned in 0.72s at **43.2 tok/s** decode, which is
      GPU-path speed; CPU-only on this model would be an order of
      magnitude slower. `n_ctx_slot = 131072`, `/health` ok, Hermes active.
- [x] `nix eval nixpkgs#linux-firmware.version` → `20260810`, not the
      ROCm-breaking `20251125`

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
