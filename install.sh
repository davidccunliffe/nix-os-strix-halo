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
# DESTRUCTIVE. It wipes BOTH disks named below, including any existing OS.
#
set -euo pipefail

# ---------------------------------------------------------------- config --
OS_DISK="${OS_DISK:-/dev/nvme0n1}"        # -> ESP + root
MODEL_DISK="${MODEL_DISK:-/dev/nvme1n1}"  # -> /var/lib/llama/models
TARGET_USER="${TARGET_USER:-david}"
FLAKE_ATTR="${FLAKE_ATTR:-ai-os}"
MODEL_URL="${MODEL_URL:-https://huggingface.co/ggml-org/GLM-4.7-Flash-GGUF/resolve/main/GLM-4.7-Flash-Q8_0.gguf}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

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

# SSID likewise comes from configuration.nix — single source of truth.
SSID="$(grep -oP 'networks\."\K[^"]+' "$REPO/configuration.nix" || true)"
[[ -n "$SSID" ]] || die "could not read the Wi-Fi SSID from configuration.nix"

ok "repo        $REPO"
ok "flake       .#$FLAKE_ATTR"
ok "model       $MODEL_NAME"
ok "ssid        $SSID"

# ------------------------------------------------------------------ plan --
printf '\n%sPlan%s\n\n' "$B" "$N"
printf '  %sDESTROYS%s %-14s -> p1 1G ESP (/boot) + p2 rest ext4 (/), no swap\n' "$R" "$N" "$OS_DISK"
printf '  %sDESTROYS%s %-14s -> p1 whole-disk ext4 at %s\n' "$R" "$N" "$MODEL_DISK" "${MODEL_PATH%/*}"

cat <<EOF

  then: nixos-install --flake .#$FLAKE_ATTR
        write /var/lib/{wifi,llama,hermes}/env
        download $MODEL_NAME (~32 GB)
        copy this repo to /home/$TARGET_USER/
        put "Linux Boot Manager" first in the EFI boot order

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
ok "passphrase accepted (${#PSK} chars)"

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
install -d -m 0700 /mnt/var/lib/wifi
printf 'psk_foxyap=%s\n' "$PSK" > /mnt/var/lib/wifi/env
chmod 0600 /mnt/var/lib/wifi/env
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

# ------------------------------------------------------------------ model --
step "Downloading $MODEL_NAME (~32 GB)"
info "resumable — safe to re-run this script's download step if interrupted"
LLAMA_UID="$(awk -F: '/^llama:/{print $3}' /mnt/etc/passwd)"
LLAMA_GID="$(awk -F: '/^llama:/{print $4}' /mnt/etc/passwd)"
curl -fL --progress-bar -C - -o "/mnt${MODEL_PATH}" "$MODEL_URL"
if [[ -n "$LLAMA_UID" && -n "$LLAMA_GID" ]]; then
  chown "$LLAMA_UID:$LLAMA_GID" "/mnt${MODEL_PATH}"
  chown "$LLAMA_UID:$LLAMA_GID" "/mnt${MODEL_PATH%/*}"
  chmod 0750 "/mnt${MODEL_PATH%/*}"
fi
ok "$(du -h "/mnt${MODEL_PATH}" | cut -f1) at $MODEL_PATH"

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
# Anchor on "* Linux Boot Manager" so this does not match the entry named
# "Fallback Linux Boot Manager".
BOOTNUM="$(efibootmgr | awk '/\* Linux Boot Manager/{print substr($1,5,4); exit}')"
if [[ -n "$BOOTNUM" ]]; then
  REST="$(efibootmgr | awk -v b="$BOOTNUM" '/^Boot[0-9A-F]{4}/{n=substr($1,5,4); if(n!=b) printf "%s,", n}')"
  efibootmgr -o "${BOOTNUM},${REST%,}" >/dev/null
  ok "Boot$BOOTNUM (Linux Boot Manager) first"
else
  warn "could not find 'Linux Boot Manager' — set the boot order by hand"
fi

# ------------------------------------------------------------------- done --
cat <<EOF

${G}${B}Done.${N}

  1. Reboot and remove the USB.
  2. ${Y}While you are in the BIOS: set the iGPU / UMA frame buffer to
     512 MB - 4 GB.${N} Guide §1. Verify after boot with 'free -h' — you
     want ~124 GiB, not ~31 GiB.
  3. Log in as $TARGET_USER and verify (guide §5):
       systemctl status llama-server hermes-agent
  4. Discord bot, if you want one: guide §6a.

EOF
