#!/usr/bin/env bash
#
# Unattended-ish installer for this flake, run from the NixOS minimal ISO.
#
# Does everything between "the ISO is online" and "ready to reboot":
# partitions both disks, installs from the flake, writes the runtime
# secrets, downloads the model, and copies this repo onto the target so it
# survives the reboot.
#
#   sudo ./install.sh              # do it
#   sudo ./install.sh --dry-run    # print the plan and exit
#
# Options:
#   --dry-run             print the plan and exit, touch nothing
#   --set-password        set the default console password without asking
#   --no-set-password     do not set one, do not ask
#   --password=PW         use PW instead of the built-in default; implies
#                         --set-password
#
# Given neither --set-password nor --no-set-password, the script asks — just
# before the DESTROY confirmation, so the answer is part of the same decision.
#
# DESTRUCTIVE. It wipes BOTH disks named below, including any existing OS.
#
set -euo pipefail

# ---------------------------------------------------------------- config --
OS_DISK="${OS_DISK:-/dev/nvme0n1}"        # -> ESP + root
MODEL_DISK="${MODEL_DISK:-/dev/nvme1n1}"  # -> /var/lib/llama/models
TARGET_USER="${TARGET_USER:-david}"
FLAKE_ATTR="${FLAKE_ATTR:-ai-os}"
# Written to the installed system as an *expired* password, so the first
# console login is forced to replace it. Never written unless asked for.
DEFAULT_PASSWORD="${DEFAULT_PASSWORD:-ChangeMe}"
MODEL_URL="${MODEL_URL:-https://huggingface.co/ggml-org/GLM-4.7-Flash-GGUF/resolve/main/GLM-4.7-Flash-Q8_0.gguf}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0
SET_PASSWORD=ask   # ask | yes | no
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)         DRY_RUN=1 ;;
    --set-password)    SET_PASSWORD=yes ;;
    --no-set-password) SET_PASSWORD=no ;;
    --password=*)      DEFAULT_PASSWORD="${1#*=}"; SET_PASSWORD=yes
                       [[ -n "$DEFAULT_PASSWORD" ]] || { printf '%s\n' '--password= needs a value' >&2; exit 2; } ;;
    -h|--help)         sed -n '3,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//; $d'; exit 0 ;;
    *)                 printf 'unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------- output --
if [[ -t 1 ]]; then
  B=$'\e[1m'; R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; N=$'\e[0m'
else
  B=""; R=""; G=""; Y=""; N=""
fi
step() { printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%s !! %s%s\n' "$Y" "$*" "$N"; }
die()  { printf '%s !! %s%s\n' "$R" "$*" "$N" >&2; exit 1; }
ok()   { printf '%s  ✓ %s%s\n' "$G" "$*" "$N"; }

# -------------------------------------------------------------- preflight --
step "Preflight"

[[ $EUID -eq 0 ]] || die "run as root (sudo $0)"
[[ -d /sys/firmware/efi ]] || die "not booted in UEFI mode; this flake assumes systemd-boot"
[[ -b $OS_DISK ]]    || die "$OS_DISK is not a block device"
[[ -b $MODEL_DISK ]] || die "$MODEL_DISK is not a block device"
[[ "$OS_DISK" != "$MODEL_DISK" ]] || die "OS_DISK and MODEL_DISK are the same device"
[[ -f "$REPO/flake.nix" ]] || die "no flake.nix next to this script (expected $REPO/flake.nix)"
command -v git >/dev/null || die "git not found"

# Refuse to run against the disk we booted from.
BOOT_SRC="$(findmnt -no SOURCE / || true)"
for d in "$OS_DISK" "$MODEL_DISK"; do
  if [[ "$BOOT_SRC" == "$d"* ]]; then die "refusing to wipe $d — it is the running root"; fi
done
[[ -d /iso ]] || warn "no /iso — are you sure this is the installer ISO and not the installed system?"

# Model filename is derived from llama-server.nix so the two cannot drift.
MODEL_PATH="$(grep -oP 'modelFile\s*=\s*"\K[^"]+' "$REPO/modules/llama-server.nix" || true)"
[[ -n "$MODEL_PATH" ]] || die "could not read modelFile from modules/llama-server.nix"
MODEL_NAME="$(basename "$MODEL_PATH")"

# Everything about Wi-Fi likewise comes from configuration.nix — single
# source of truth. The secrets file this script writes has to agree with the
# generated wpa_supplicant config on all three of these (interface, secrets
# path, and the key name behind `ext:`), and a silent disagreement means a
# headless box with no network. Read them rather than restating them.
SSID="$(grep -oP 'networks\."\K[^"]+' "$REPO/configuration.nix" | head -1 || true)"
WIFI_IFACE="$(grep -oP 'interfaces\s*=\s*\[\s*"\K[^"]+' "$REPO/configuration.nix" | head -1 || true)"
WIFI_SECRETS="$(grep -oP 'secretsFile\s*=\s*"\K[^"]+' "$REPO/configuration.nix" | head -1 || true)"
PSK_KEY="$(grep -oP 'pskRaw\s*=\s*"ext:\K[^"]+' "$REPO/configuration.nix" | head -1 || true)"
[[ -n "$SSID" ]]         || die "could not read the Wi-Fi SSID from configuration.nix"
[[ -n "$WIFI_IFACE" ]]   || die "could not read networking.wireless.interfaces from configuration.nix"
[[ -n "$WIFI_SECRETS" ]] || die "could not read networking.wireless.secretsFile from configuration.nix"
[[ -n "$PSK_KEY" ]]      || die "could not read the pskRaw ext: key name from configuration.nix"

# configuration.nix pins one interface by name. If the installed kernel calls
# the card something else there is no Wi-Fi and no way in — catch it now,
# while there is still a working network to fix it over.
[[ -d "/sys/class/net/$WIFI_IFACE" ]] \
  || die "configuration.nix pins '$WIFI_IFACE' but this box has no such interface: $(ls /sys/class/net | tr '\n' ' ')"

ok "repo        $REPO"
ok "flake       .#$FLAKE_ATTR"
ok "model       $MODEL_NAME"
ok "ssid        $SSID on $WIFI_IFACE (psk from $WIFI_SECRETS, key '$PSK_KEY')"

# ------------------------------------------------------------------ plan --
printf '\n%sPlan%s\n\n' "$B" "$N"
printf '  %sDESTROYS%s %-14s -> p1 1G ESP (/boot) + p2 rest ext4 (/), no swap\n' "$R" "$N" "$OS_DISK"
printf '  %sDESTROYS%s %-14s -> p1 whole-disk ext4 at %s\n' "$R" "$N" "$MODEL_DISK" "${MODEL_PATH%/*}"

case "$SET_PASSWORD" in
  yes) PW_PLAN="set $TARGET_USER's password to '$DEFAULT_PASSWORD', expired" ;;
  no)  PW_PLAN="leave $TARGET_USER with no password (SSH key only)" ;;
  *)   PW_PLAN="console password for $TARGET_USER: asked below" ;;
esac

cat <<EOF

  then: nixos-install --flake .#$FLAKE_ATTR
        write $WIFI_SECRETS and /var/lib/{llama,hermes}/env
        $PW_PLAN
        copy this repo to /home/$TARGET_USER/
        put this install's ESP first in the EFI boot order
        download $MODEL_NAME (~32 GB) — last, so a failure here
          leaves a box you can still boot and log into

${B}Currently on those disks${N}
EOF
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$OS_DISK" "$MODEL_DISK" | sed 's/^/  /'
if zpool import 2>/dev/null | grep -q 'pool:'; then
  echo
  warn "ZFS pools present — these will be destroyed:"
  zpool import 2>/dev/null | grep 'pool:' | sed 's/^/    /'
fi

if [[ $DRY_RUN -eq 1 ]]; then
  echo; ok "dry run — nothing done"; exit 0
fi

# ----------------------------------------------------- console password ---
# Asked before the DESTROY confirmation on purpose: by the time you type
# DESTROY every decision this run makes is already settled.
if [[ "$SET_PASSWORD" == "ask" ]]; then
  step "Console password for $TARGET_USER"
  info "This repo commits no password for $TARGET_USER, so out of the box the"
  info "installed system has console login disabled and is reachable only by"
  info "SSH key. If Wi-Fi does not come up on the first boot, that is no way"
  info "in at all — you would be sitting at a login prompt that refuses you."
  info ""
  info "Saying yes sets '$DEFAULT_PASSWORD' and immediately expires it, so the"
  info "first login has to replace it before it gets a shell. Nothing is"
  info "committed to the repo either way; this is written to the installed"
  info "system, not to Nix."
  info ""
  info "While it is expired, an interactive 'ssh $TARGET_USER@...' still works"
  info "and runs passwd for you, but non-interactive SSH (scp, rsync, ssh with"
  info "a command) is refused until the password has been changed."
  echo
  read -rp "    Set a default password for $TARGET_USER? [y/N]: " answer
  case "$answer" in
    [Yy]|[Yy][Ee][Ss]) SET_PASSWORD=yes ;;
    *)                 SET_PASSWORD=no  ;;
  esac
fi
if [[ "$SET_PASSWORD" == "yes" ]]; then
  ok "will set '$DEFAULT_PASSWORD' for $TARGET_USER, expired on first use"
else
  warn "no console password — if Wi-Fi fails on first boot, plug in ethernet"
  warn "or re-run this installer; the login prompt will not let you in"
fi

echo
read -rp "Type DESTROY to continue: " confirm
[[ "$confirm" == "DESTROY" ]] || die "aborted"

# ---------------------------------------------------------------- wifi pw --
step "Wi-Fi passphrase for '$SSID'"

NM_CONN="/etc/NetworkManager/system-connections/${SSID}.nmconnection"
PSK=""
if [[ -f "$NM_CONN" ]]; then
  PSK="$(awk -F= '/^psk=/{sub(/^psk=/,""); print; exit}' "$NM_CONN" || true)"
  [[ -n "$PSK" ]] && info "taken from the ISO's saved NetworkManager connection (never echoed)"
fi
if [[ -z "$PSK" ]]; then
  read -rsp "    passphrase (8-63 chars, not echoed): " PSK; echo
fi
[[ ${#PSK} -ge 8 && ${#PSK} -le 63 ]] || die "passphrase must be 8-63 characters (wpa_supplicant limit)"

# The secrets file is read by wpa_supplicant's file ext_password backend,
# which parses it with wpa_config_get_line() — the same parser as
# wpa_supplicant.conf. That parser strips a '#' and everything after it, and
# strips leading and trailing whitespace. A passphrase containing either is
# not rejected: it is silently truncated, PBKDF2'd into the wrong PSK, and
# the box comes up associating and failing forever. Refuse it here instead.
case "$PSK" in
  *'#'*) die "passphrase contains '#': the secrets-file parser treats it as a comment and would silently use a truncated key" ;;
esac
[[ "$PSK" == "${PSK#[[:space:]]}" && "$PSK" == "${PSK%[[:space:]]}" ]] \
  || die "passphrase has leading or trailing whitespace: the secrets-file parser strips it and the key would be wrong"
if ! printf '%s' "$PSK" | LC_ALL=C grep -qE '^[[:print:]]+$'; then
  die "passphrase has non-ASCII or non-printable characters; store a 64-hex PSK in $WIFI_SECRETS by hand instead"
fi
ok "passphrase accepted (${#PSK} chars, safe for the secrets-file parser)"

# --------------------------------------------------------------- unmount --
step "Clearing any existing mounts under /mnt"
for _ in 1 2 3 4 5; do umount -R /mnt 2>/dev/null || true; done
grep -q ' /mnt ' /proc/self/mountinfo && die "/mnt still mounted; unmount by hand and re-run"
ok "/mnt clean"

# -------------------------------------------------------------- os disk ---
step "Partitioning $OS_DISK"
sgdisk --zap-all "$OS_DISK" >/dev/null
sgdisk -n1:0:+1G -t1:EF00 -c1:ESP  "$OS_DISK" >/dev/null
sgdisk -n2:0:0   -t2:8300 -c2:root "$OS_DISK" >/dev/null
partprobe "$OS_DISK"; udevadm settle; sleep 2

ESP_PART="$(lsblk -lnpo NAME "$OS_DISK" | sed -n 2p)"
ROOT_PART="$(lsblk -lnpo NAME "$OS_DISK" | sed -n 3p)"
mkfs.vfat -F32 -n ESP "$ESP_PART"  >/dev/null
mkfs.ext4 -L nixos -F "$ROOT_PART" >/dev/null
ok "$ESP_PART = ESP, $ROOT_PART = root"

# ------------------------------------------------------------ model disk --
step "Wiping $MODEL_DISK"
# ZFS labels live at both ends of the device; wipefs alone misses them.
for p in $(lsblk -lnpo NAME "$MODEL_DISK" | tail -n +2); do
  swapoff "$p" 2>/dev/null || true
  zpool labelclear -f "$p" 2>/dev/null || true
  wipefs -a "$p" >/dev/null 2>&1 || true
done
sgdisk --zap-all "$MODEL_DISK" >/dev/null
partprobe "$MODEL_DISK"; udevadm settle; sleep 2

if zpool import 2>/dev/null | grep -q 'pool:'; then die "ZFS pools still importable after wipe"; fi

sgdisk -n1:0:0 -t1:8300 -c1:models "$MODEL_DISK" >/dev/null
partprobe "$MODEL_DISK"; udevadm settle; sleep 2
MODEL_PART="$(lsblk -lnpo NAME "$MODEL_DISK" | sed -n 2p)"
# -m 0: no reserved-block tax on a volume that only holds model weights.
mkfs.ext4 -L models -m 0 -F "$MODEL_PART" >/dev/null
ok "$MODEL_PART = models"

# ----------------------------------------------------------------- mount --
step "Mounting"
udevadm settle
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot "/mnt${MODEL_PATH%/*}"
mount -o umask=0077 "$ESP_PART" /mnt/boot
mount "$MODEL_PART" "/mnt${MODEL_PATH%/*}"

# nixos-generate-config transcribes /proc/self/mountinfo literally, so a
# stacked mount becomes a duplicate fileSystems attribute and the build
# fails with a confusing Nix error. Catch it here instead.
n=$(grep -c ' /mnt' /proc/self/mountinfo || true)
[[ "$n" -eq 3 ]] || die "expected 3 mounts under /mnt, found $n — stacked mount, unmount and re-run"
findmnt -R /mnt -o TARGET,SOURCE,FSTYPE | sed 's/^/    /'
ok "3 filesystems mounted"

# ------------------------------------------------------------ hw config ---
step "Generating hardware-configuration.nix"
nixos-generate-config --root /mnt >/dev/null 2>&1
grep -q "${MODEL_PATH%/*}" /mnt/etc/nixos/hardware-configuration.nix \
  || die "generated config is missing the model mount — check the mount table"
cp /mnt/etc/nixos/hardware-configuration.nix "$REPO/hardware-configuration.nix"
# Flakes only see tracked files.
git -C "$REPO" -c safe.directory="$REPO" add -A
ok "copied into the repo and staged"

# ---------------------------------------------------------------- secrets --
step "Writing secrets under /mnt"
install -d -m 0700 "/mnt$(dirname "$WIFI_SECRETS")"
printf '%s=%s\n' "$PSK_KEY" "$PSK" > "/mnt$WIFI_SECRETS"
chmod 0600 "/mnt$WIFI_SECRETS"
unset PSK

# One key, shared: Hermes authenticates against llama-server.
KEY="$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 43)"
install -d -m 0755 /mnt/var/lib/llama
printf 'LLAMA_API_KEY=%s\n' "$KEY" > /mnt/var/lib/llama/env
chmod 0600 /mnt/var/lib/llama/env
install -d -m 0700 /mnt/var/lib/hermes
printf 'OPENAI_API_KEY=%s\n' "$KEY" > /mnt/var/lib/hermes/env
chmod 0600 /mnt/var/lib/hermes/env
unset KEY
ok "wifi, llama and hermes env files written 0600"

# --------------------------------------------------------------- preflight -
step "Evaluating the flake before the long build"
nix --extra-experimental-features 'nix-command flakes' \
  eval --no-write-lock-file "$REPO#nixosConfigurations.${FLAKE_ATTR}.config.system.build.toplevel.drvPath" >/dev/null
ok "evaluates"

# ---------------------------------------------------------------- install --
step "nixos-install (this is the slow part)"
# nixos-install does NOT accept --extra-experimental-features; it dies on
# the unknown option. Pass flake support through the environment instead.
NIX_CONFIG='experimental-features = nix-command flakes' \
  nixos-install --flake "$REPO#${FLAKE_ATTR}" --no-root-password
ok "installed"

# ----------------------------------------------------- console password ---
step "Console password for $TARGET_USER"
if [[ "$SET_PASSWORD" == "yes" ]]; then
  # Done through nixos-enter so the target's own shadow tooling and crypt
  # settings apply, rather than whatever the ISO happens to ship. Absolute
  # paths because chroot resolves the command against the ISO's PATH.
  # users.mutableUsers is true, so this survives later nixos-rebuilds; a
  # hashedPassword in the repo would be public and offline-crackable, which
  # is exactly why this lives here and not in configuration.nix.
  printf '%s:%s\n' "$TARGET_USER" "$DEFAULT_PASSWORD" \
    | nixos-enter --root /mnt --silent -- /run/current-system/sw/bin/chpasswd
  # Last-changed 0 = expired. login(1) and sshd both demand a replacement
  # before handing over a shell.
  nixos-enter --root /mnt --silent -- /run/current-system/sw/bin/chage -d 0 "$TARGET_USER"

  ENTRY="$(awk -F: -v u="$TARGET_USER" '$1==u{print $2":"$3}' /mnt/etc/shadow || true)"
  [[ -n "$ENTRY" ]] || die "no shadow entry for $TARGET_USER after chpasswd"
  [[ "${ENTRY%%:*}" == \$* ]] || die "password did not take — shadow field is '${ENTRY%%:*}'"
  [[ "${ENTRY##*:}" == "0" ]] || die "password set but not expired (last-changed '${ENTRY##*:}', wanted 0)"
  ok "'$DEFAULT_PASSWORD' set and expired — first login must replace it"
else
  warn "no password set; console login for $TARGET_USER stays disabled"
fi

# -------------------------------------------------------- wifi preflight --
# Everything needed for the first boot to reach the network, checked against
# the system that was actually built rather than against the flake source.
step "Wi-Fi readiness for the first boot"
[[ -f "/mnt$WIFI_SECRETS" ]] || die "$WIFI_SECRETS missing from the target"
[[ "$(stat -c '%a %U' "/mnt$WIFI_SECRETS")" == "600 root" ]] \
  || die "$WIFI_SECRETS is $(stat -c '%a %U' "/mnt$WIFI_SECRETS"), wanted '600 root'"
grep -q "^${PSK_KEY}=" "/mnt$WIFI_SECRETS" || die "$WIFI_SECRETS has no '$PSK_KEY=' line"

# /mnt/etc is a farm of symlinks into /etc/static, which resolve against the
# ISO's /etc from out here — read the generated config from inside the target.
WPA_CONF="$(nixos-enter --root /mnt --silent -- /run/current-system/sw/bin/cat /etc/wpa_supplicant/nixos.conf 2>/dev/null || true)"
grep -q "ssid=\"$SSID\""                        <<<"$WPA_CONF" || die "generated wpa_supplicant config does not mention SSID '$SSID'"
grep -q "psk=ext:$PSK_KEY"                      <<<"$WPA_CONF" || die "generated wpa_supplicant config does not read psk from ext:$PSK_KEY"
grep -q "ext_password_backend=file:$WIFI_SECRETS" <<<"$WPA_CONF" || die "generated wpa_supplicant config points at a different secrets file than $WIFI_SECRETS"

# Naming an interface makes NixOS emit a per-interface unit rather than the
# plain wpa_supplicant.service — worth knowing before you go looking for it.
WPA_UNIT="wpa_supplicant-${WIFI_IFACE}.service"
nixos-enter --root /mnt --silent -- \
  /run/current-system/sw/bin/test -e "/etc/systemd/system/multi-user.target.wants/$WPA_UNIT" \
  || die "$WPA_UNIT is not wanted by multi-user.target — Wi-Fi would not start"
ok "$WPA_UNIT enabled, reads '$PSK_KEY' from $WIFI_SECRETS, joins $SSID"
info "dhcpcd runs on all interfaces (networking.useDHCP), so the lease follows"

# ------------------------------------------------------------- repo copy ---
step "Copying the repo onto the target"
# The ISO's home is tmpfs. Without this, the repo and its history die with
# the reboot.
TU_UID="$(awk -F: -v u="$TARGET_USER" '$1==u{print $3}' /mnt/etc/passwd)"
TU_GID="$(awk -F: -v u="$TARGET_USER" '$1==u{print $4}' /mnt/etc/passwd)"
if [[ -n "$TU_UID" ]]; then
  install -d -m 0700 -o "$TU_UID" -g "$TU_GID" "/mnt/home/$TARGET_USER"
  cp -a "$REPO" "/mnt/home/$TARGET_USER/"
  chown -R "$TU_UID:$TU_GID" "/mnt/home/$TARGET_USER/$(basename "$REPO")"
  ok "/home/$TARGET_USER/$(basename "$REPO")"
else
  warn "user '$TARGET_USER' not found in /mnt/etc/passwd — repo NOT copied"
fi

# ------------------------------------------------------------- boot order --
step "EFI boot order"
# A wiped disk's old entry usually still sorts first, so the box would come
# up on a dead entry.
#
# Match on the ESP's partition GUID, not on the entry's label. Every install
# onto this box leaves behind another entry called "Linux Boot Manager"
# pointing at an ESP that no longer exists, and reinstalling gives the new
# ESP a fresh GUID — so picking the first entry by name reliably selects a
# *stale* one and the box boots nothing. The GUID is unambiguous.
# `systemd-bootx64.efi` excludes the "-fallbackx64" entry, which shares it.
ESP_PARTUUID="$(blkid -s PARTUUID -o value "$ESP_PART" || true)"
[[ -n "$ESP_PARTUUID" ]] || die "could not read the PARTUUID of $ESP_PART"
BOOTNUM="$(efibootmgr | awk -v id="$ESP_PARTUUID" '
  BEGIN { id = tolower(id) }
  /^Boot[0-9A-Fa-f]{4}/ {
    line = tolower($0)
    if (index(line, id) && index(line, "systemd-bootx64.efi")) {
      print substr($1, 5, 4); exit
    }
  }')"
if [[ -n "$BOOTNUM" ]]; then
  REST="$(efibootmgr | awk -v b="$BOOTNUM" '/^Boot[0-9A-Fa-f]{4}/{n=substr($1,5,4); if(n!=b) printf "%s,", n}')"
  efibootmgr -o "${BOOTNUM},${REST%,}" >/dev/null
  ok "Boot$BOOTNUM first — systemd-boot on $ESP_PART ($ESP_PARTUUID)"
  info "$(efibootmgr | grep '^BootOrder:')"
  info "the other 'Linux Boot Manager' entries are dead ESPs from earlier"
  info "installs; harmless once this one sorts first, delete from the BIOS"
else
  warn "no EFI entry points at this ESP ($ESP_PARTUUID) — set the boot order"
  warn "by hand, or the box will not come up on this install"
fi

# ------------------------------------------------------------------ model --
# Deliberately last. It is the only step measured in tens of minutes and the
# only one that can die on a flaky link, and everything that makes the box
# reachable — password, boot entry, repo — is already done by the time it
# starts. An interrupted download then costs you a resume, not a reinstall:
# llama-server crash-loops on the missing GGUF, but you can log in and fix
# it. Losing the download used to take the repo copy and the boot order with
# it, which is a far worse place to be.
step "Downloading $MODEL_NAME (~32 GB)"
info "resumable — re-run 'curl -C - -o $MODEL_PATH $MODEL_URL' on the box"
LLAMA_UID="$(awk -F: '/^llama:/{print $3}' /mnt/etc/passwd)"
LLAMA_GID="$(awk -F: '/^llama:/{print $4}' /mnt/etc/passwd)"
curl -fL --progress-bar -C - -o "/mnt${MODEL_PATH}" "$MODEL_URL"
if [[ -n "$LLAMA_UID" && -n "$LLAMA_GID" ]]; then
  chown "$LLAMA_UID:$LLAMA_GID" "/mnt${MODEL_PATH}"
  chown "$LLAMA_UID:$LLAMA_GID" "/mnt${MODEL_PATH%/*}"
  chmod 0750 "/mnt${MODEL_PATH%/*}"
fi
ok "$(du -h "/mnt${MODEL_PATH}" | cut -f1) at $MODEL_PATH"

# ------------------------------------------------------------------- done --
ETH_IFACE="$(ls /sys/class/net | grep -E '^(en|eth)' | head -1 || true)"
if [[ "$SET_PASSWORD" == "yes" ]]; then
  PW_NOTE="${B}Console login${N}

  $TARGET_USER / $DEFAULT_PASSWORD — already expired, so the first login has
  to replace it. Do that at the console before you rely on scp or
  'ssh $TARGET_USER@ai-os.local <command>': those are refused while the
  password is expired, because there is no TTY to run passwd on."
else
  PW_NOTE="${B}Console login${N}

  $TARGET_USER has no password, so the console login prompt will refuse you.
  SSH key only. Re-run with --set-password if you want a way in at the
  keyboard."
fi

cat <<EOF

${G}${B}Done.${N}

  1. Reboot and remove the USB.
  2. ${Y}While you are in the BIOS: set the iGPU / UMA frame buffer to
     512 MB - 4 GB.${N} Guide §1. Verify after boot with 'free -h' — you
     want ~124 GiB, not ~31 GiB.
  3. At the console, read the IPv4 line above the login prompt. Blank means
     Wi-Fi did not come up — see below.
  4. Log in as $TARGET_USER and verify (guide §5):
       systemctl status llama-server hermes-agent
  5. Discord bot, if you want one: guide §6a.

${B}If the console shows no IPv4${N}

  Log in at the keyboard and run the diagnostic that ships with this repo:

    cd ~/$(basename "$REPO") && ./wifi-diag.sh

  It checks the card, rfkill, the unit, association, the lease, the route
  and DNS, prints the relevant journals, and tells you which of those is
  the actual problem. --restart bounces wpa_supplicant and dhcpcd.

  "4-way handshake failed" means the passphrase in $WIFI_SECRETS
  is wrong. "No suitable PSK available" means the '$PSK_KEY' line is
  malformed. Either way, edit that file and re-run with --restart — the
  passphrase is not in the Nix store, so no rebuild is needed.

  Fallback that always works: dhcpcd runs on every interface, so plugging a
  cable into ${ETH_IFACE:-the ethernet port} gets you a lease and an SSH
  login without touching Wi-Fi at all.

${PW_NOTE}
EOF
