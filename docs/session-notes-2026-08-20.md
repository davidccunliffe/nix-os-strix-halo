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


## Hermes: running, but not usable until three things were fixed

The gateway service had been up since the install and looked healthy, which
hid the fact that nothing could actually reach the agent.

**1. No messaging platform.** The journal says it plainly —
`gateway.run: No messaging platforms enabled` — because `/var/lib/hermes/env`
holds only `OPENAI_API_KEY`. Discord is guide §6a: browser work in the
Developer Portal, then the token and `DISCORD_ALLOWED_USERS` appended to that
file, then a rebuild. Not done yet; the box has no bot registered.

**2. The CLI was unusable for `david`** — and it is the same shape of bug as
the Wi-Fi one, a service-owned path the human is not a member of:

```
PermissionError: [Errno 13] Permission denied: '/var/lib/hermes/.hermes/.env'
```

`/var/lib/hermes` is `0770 hermes:hermes`; `david` was in `wheel video
render` and not `hermes`. Guide §6 promised that the shell's `hermes` and the
gateway share one HERMES_HOME, which was true in intent and false in
practice. Fixed by adding `"hermes"` to `extraGroups`. The setgid bit already
on those directories means files created from the shell stay group-owned by
hermes, so sharing works in both directions. Group membership only lands at
login, so it needs a fresh session — `sudo -u david -i` is enough to test.

**3. The agent refused to run at all**, with an error that points away from
the cause:

```
hermes -z: agent failed: No LLM provider configured.
```

while `hermes status` simultaneously reported `Model: local-main` and
`Provider: Custom endpoint`. `modules/hermes.nix` set `model.base_url` and
`model.default` but no `model.provider`, and base_url only says *where* to
send inference — not which adapter to route it through. With none resolved,
Hermes gives up before opening a socket. Setting `provider = "openai-api"`
(the OpenAI-compatible adapter in its `PROVIDER_REGISTRY`, which reads
`OPENAI_API_KEY`) fixed it: `hermes -z` now answers from the local model, as
`david`, in 0.7s.

Worth recording how misleading the intermediate states were. Forcing
`--provider openai-api` on the command line got as far as llama-server and
came back `HTTP 401: Missing Authentication header`, which looks like a key
problem and is not one — the key was fine all along; the config-level
provider is what makes Hermes attach it.

### Two follow-on findings

- **`compression.summary_model` is deprecated and ignored**, replaced by
  `auxiliary.compression = { model, provider }`. Left as it was, the setting
  reads as "summaries stay local" while they would go to the default
  provider — a silent egress of conversation summaries on a box whose whole
  premise is that nothing leaves it. `hermes doctor` now reports
  `No deprecated config keys or env vars`.
- **The module deep-merges into `config.yaml` and keeps keys it no longer
  manages.** That is deliberate (it lets the TUI and `hermes config set`
  write there too), but it means *removing* a setting from
  `modules/hermes.nix` does not remove it from disk: `summary_model` survived
  the rebuild and doctor kept flagging it until it was deleted from the file
  by hand. Anyone dropping a setting from that module has to do the same.

`hermes doctor` still notes `Config version outdated (v0 → v38)`. That is
informational — upstream has settings this config does not set — not a
failure, and `hermes migrate` is left alone deliberately: it rewrites
`config.yaml`, which the module owns.


## Discord bot: working, and four corrections to guide §6a

The bot is live — DM answered, so Discord → Hermes → llama-server → back is
proven end to end. Getting there turned up four things §6a had wrong or
missing, all now fixed.

**The switch does not restart the service.** The one that actually cost
time. Adding secrets to `/var/lib/hermes/env` does not change the system
closure, so `nixos-rebuild switch` produced a byte-identical store path,
systemd saw an unchanged unit, and left the running gateway alive with its
old environment. The activation *did* merge the new keys into
`$HERMES_HOME/.env` — but the process that needed them had been running
since before they existed, and kept logging `No messaging platforms
enabled` as though nothing had been configured. An explicit
`systemctl restart hermes-agent` is what applies it. Same shape as the
Wi-Fi bug in a way: the config was right on disk and the consumer never
saw it.

**Public Bot should be OFF, not ON.** §6a said to enable it, to use
Discord's provided invite link — but §6a already tells you to hand-build the
OAuth2 URL, so the reason never applied to its own procedure. Private costs
nothing and matters here: this bot feeds an agent with `toolsets = [ "all" ]`
and a local terminal backend, and `DISCORD_ALLOWED_USERS` is the only gate
in front of it. Public means anyone with the URL can put traffic against
that single gate.

**The permission integer documented eight permissions and described
seven.** `274878286912` decodes to View Channels, Send Messages, Read
Message History, Embed Links, Attach Files, Add Reactions, Send Messages in
Threads — *and* Use External Emojis (1<<18), which the prose never
mentioned. Verified by decoding the bits rather than trusting the comment.
The guide now leads with `274878024768`, the same set minus the emoji bit,
and lists what is deliberately excluded and why.

**Nothing said what success looks like.** Hermes logs no "logged in as"
line, so the signal is the absence of a failure: `No messaging platforms
enabled` disappearing and `hermes_plugins.discord_platform.adapter`
appearing. Two lines look like failures and are not — `Opus codec not
found` is voice-only, and `Main process exited, code=exited,
status=1/FAILURE` at restart is the *previous* process returning 1 on
SIGTERM.

### One more trap, found while iterating

Duplicate keys propagate through the merge. Appending the same key twice
to `/var/lib/hermes/env` puts both lines into `$HERMES_HOME/.env` at the
next activation — this box reached three `DISCORD_BOT_TOKEN` lines and two
`DISCORD_ALLOWED_USERS` that way. Measured afterwards rather than assumed:
the merge mirrors the source, it does not multiply it, so deduping the
source and re-activating yields one line per key. The parser takes
the last occurrence, so it keeps working while quietly accumulating, which
is exactly the kind of thing that is baffling six months later. §6a now
carries a dedupe recipe that keeps the last of each key.

Also folded into §9: five troubleshooting rows covering the mute bot, the
ignored user, secrets-not-applied, `could not find a flake.nix file` (`.#ai-os`
resolves against the *current* directory, which bites when you are one
directory up), and the `hermes` CLI PermissionError from a session that
predates the group change.

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
