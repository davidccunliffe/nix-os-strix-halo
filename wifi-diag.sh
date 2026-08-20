#!/usr/bin/env bash
#
# Wi-Fi diagnostics for this box. Run it ON the machine, after logging in:
#
#   ./wifi-diag.sh              # report
#   ./wifi-diag.sh --restart    # bounce wpa_supplicant + dhcpcd, then report
#   ./wifi-diag.sh --watch      # follow the wpa_supplicant journal live
#
# Deliberately limited to tools a NixOS box with networking.wireless.enable
# already has. Nothing here needs `iw`, `nmcli` or `iwctl`: installing those
# means a nixos-rebuild, a rebuild means fetching from cache, and fetching
# needs the network that is by hypothesis broken. `wpa_cli` is on the box but
# useless here — networking.wireless.userControlled is off, so wpa_supplicant
# is started without a ctrl_interface and there is no socket to talk to.
#
# Interface, SSID and secrets path are read out of configuration.nix, so this
# stays correct if they change there.
#
# No `set -e`: a diagnostic that stops at the first failing command is the
# opposite of useful. Every check is expected to be able to fail.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION=report
case "${1:-}" in
  "")         ;;
  --restart)  ACTION=restart ;;
  --watch)    ACTION=watch ;;
  -h|--help)  sed -n '3,/^set -uo/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//; $d'; exit 0 ;;
  *)          printf '%s\n' "unknown option: $1 (try --help)" >&2; exit 2 ;;
esac

# Passwordless sudo for wheel is set in configuration.nix, so this is seamless
# — but journalctl -u and the secrets file both need root, and a report with
# those two missing is a report that cannot tell you what went wrong.
if [[ $EUID -ne 0 ]]; then
  exec sudo -p "sudo password for %u: " "$0" "$@"
fi

if [[ -t 1 ]]; then
  B=$'\e[1m'; R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; N=$'\e[0m'
else
  B=""; R=""; G=""; Y=""; N=""
fi
head1() { printf '\n%s== %s%s\n' "$B" "$*" "$N"; }
pass()  { printf '%s  ok  %s%s\n'   "$G" "$*" "$N"; }
fail()  { printf '%s FAIL %s%s\n'   "$R" "$*" "$N"; VERDICT+=("$*"); }
note()  { printf '      %s\n' "$*"; }
run()   { printf '\n%s$ %s%s\n' "$Y" "$*" "$N"; "$@" 2>&1 | sed 's/^/  /'; }

# ------------------------------------------------------------ what we are --
CFG="$REPO/configuration.nix"
if [[ -f "$CFG" ]]; then
  SSID="$(grep -oP 'networks\."\K[^"]+' "$CFG" | head -1)"
  IFACE="$(grep -oP 'interfaces\s*=\s*\[\s*"\K[^"]+' "$CFG" | head -1)"
  SECRETS="$(grep -oP 'secretsFile\s*=\s*"\K[^"]+' "$CFG" | head -1)"
  PSK_KEY="$(grep -oP 'pskRaw\s*=\s*"ext:\K[^"]+' "$CFG" | head -1)"
else
  # Running from somewhere other than the repo. Fall back to the one wireless
  # interface the kernel admits to.
  IFACE="$(for d in /sys/class/net/*/wireless; do [[ -e $d ]] && basename "$(dirname "$d")" && break; done)"
  SSID=""; SECRETS="/var/lib/wifi/env"; PSK_KEY=""
  printf '%s !! no configuration.nix next to this script; guessing %s%s\n' "$Y" "${IFACE:-nothing}" "$N"
fi
[[ -n "${IFACE:-}" ]] || { printf '%s !! no wireless interface found%s\n' "$R" "$N"; exit 1; }
UNIT="wpa_supplicant-${IFACE}.service"

if [[ "$ACTION" == "watch" ]]; then
  printf '%sfollowing %s — ctrl-c to stop%s\n' "$B" "$UNIT" "$N"
  exec journalctl -u "$UNIT" -f -n 50
fi

if [[ "$ACTION" == "restart" ]]; then
  head1 "Restarting"
  # wpa_supplicant re-reads both its config and the secrets file on start, so
  # this picks up an edited passphrase with no rebuild. dhcpcd follows once
  # the link is up, but kicking it saves waiting for the retry timer.
  run systemctl restart "$UNIT"
  sleep 3
  run systemctl restart dhcpcd.service
  note "giving DHCP 10s to land a lease"
  sleep 10
fi

VERDICT=()
printf '%sWi-Fi check — %s on %s%s\n' "$B" "${SSID:-<unknown ssid>}" "$IFACE" "$N"

# ----------------------------------------------------------- the six checks -
head1 "Verdict"

# 1. does the kernel have the card at all
if [[ -d "/sys/class/net/$IFACE" ]]; then
  pass "interface $IFACE exists"
else
  fail "interface $IFACE does not exist — driver or firmware did not load"
  note "have: $(ls /sys/class/net | tr '\n' ' ')"
fi

# 2. rfkill. A hard block is a physical switch; a soft block is software and
#    clears with 'rfkill unblock wifi'.
if command -v rfkill >/dev/null; then
  BLOCK="$(rfkill list wifi 2>/dev/null | grep -c 'blocked: yes')"
  if [[ "${BLOCK:-0}" -eq 0 ]]; then
    pass "not rfkill blocked"
  else
    fail "rfkill blocked — try 'rfkill unblock wifi'"
  fi
fi

# 3. the unit. Named per-interface because configuration.nix names the
#    interface; there is no plain wpa_supplicant.service to look at.
if systemctl is-active --quiet "$UNIT"; then
  pass "$UNIT active"
elif ! systemctl cat "$UNIT" >/dev/null 2>&1; then
  fail "$UNIT does not exist — is networking.wireless still enabled for $IFACE?"
else
  fail "$UNIT is $(systemctl is-active "$UNIT" 2>&1) — see the journal below"
fi

# 3b. Let a link that is still coming up finish before judging it. Measured
#     on this box after a supplicant restart: ~5s to associate, ~10s before
#     dhcpcd has the lease and the routes back. A plain report run inside
#     that window says "not associated" and "no IPv4 address" about a link
#     that is merely mid-negotiation, and reads identically to real
#     breakage — while `ip a` a few seconds later shows everything up.
#     Only waits when something is actually missing, and says how long it
#     waited, so a genuinely dead link still fails, 20s later.
if systemctl is-active --quiet "$UNIT"; then
  WAITED=0
  while [[ $WAITED -lt 20 ]]; do
    [[ "$(cat "/sys/class/net/$IFACE/carrier" 2>/dev/null || echo 0)" == "1" ]] \
      && [[ -n "$(ip -4 -br addr show "$IFACE" 2>/dev/null | awk '{print $3}')" ]] \
      && break
    sleep 2
    WAITED=$((WAITED + 2))
  done
  [[ $WAITED -gt 0 ]] && note "waited ${WAITED}s for the link to settle"
fi

# 4. associated. Without `iw`, carrier is the honest proxy: for a wireless
#    interface the kernel only raises it once the link is actually up.
CARRIER="$(cat "/sys/class/net/$IFACE/carrier" 2>/dev/null || echo 0)"
if [[ "$CARRIER" == "1" ]]; then
  pass "associated (carrier up)"
else
  fail "not associated with ${SSID:-the AP}"
fi

# 5. the lease
IPV4="$(ip -4 -br addr show "$IFACE" 2>/dev/null | awk '{print $3}')"
if [[ -n "$IPV4" ]]; then
  pass "IPv4 $IPV4"
else
  fail "no IPv4 address — associated but no DHCP lease, or not associated"
fi

# 6. and whether the lease is worth anything
GW="$(ip -4 route show default dev "$IFACE" 2>/dev/null | awk '{print $3; exit}')"
if [[ -n "$GW" ]] && ping -c1 -W3 -I "$IFACE" "$GW" >/dev/null 2>&1; then
  pass "gateway $GW reachable"
elif [[ -n "$GW" ]]; then
  fail "gateway $GW not answering"
else
  fail "no default route"
fi

if timeout 5 getent ahostsv4 github.com >/dev/null 2>&1; then
  pass "DNS resolves"
else
  fail "DNS does not resolve"
fi

# ----------------------------------------------------------------- detail --
head1 "Detail"
run ip -br addr
run ip -4 route
[[ -f "/sys/class/net/$IFACE/operstate" ]] && \
  note "operstate=$(cat "/sys/class/net/$IFACE/operstate") carrier=$CARRIER"
command -v rfkill >/dev/null && run rfkill list
run systemctl --no-pager --full status "$UNIT"
run systemctl --no-pager --full status dhcpcd.service

head1 "wpa_supplicant journal, this boot"
journalctl -b -u "$UNIT" --no-pager -o cat | tail -40 | sed 's/^/  /'

head1 "dhcpcd journal, this boot"
journalctl -b -u dhcpcd.service --no-pager -o cat | tail -20 | sed 's/^/  /'

head1 "Driver messages"
# Narrow on purpose: a bare 'firmware' also catches the GPU and half of
# systemd's boot chatter, and burying the one mt7925 line that matters is
# how you end up not reading this section at all.
dmesg 2>/dev/null | grep -iE "mt79|cfg80211|ieee80211|$IFACE|wlan[0-9]" | tail -20 | sed 's/^/  /' \
  || note "nothing from the wireless driver"

head1 "Secrets file"
if [[ -f "$SECRETS" ]]; then
  note "$SECRETS  $(stat -c '%a %U:%G' "$SECRETS")"
  # Mode and owner are not the question — "can the process that needs it
  # actually open it" is. The unit is hardened and runs as an unprivileged
  # user (User=wpa_supplicant), and the ext_password file backend opens this
  # file after that drop, so a root:root 0600 file silently yields no PSK.
  # Ask the unit who it runs as rather than assuming, and then test as them.
  SVC_USER="$(systemctl show -p User --value "$UNIT" 2>/dev/null)"
  SVC_USER="${SVC_USER:-root}"
  SVC_GROUP="$(systemctl show -p Group --value "$UNIT" 2>/dev/null)"
  SVC_GROUP="${SVC_GROUP:-$SVC_USER}"
  if sudo -u "$SVC_USER" test -r "$SECRETS" 2>/dev/null; then
    pass "readable by '$SVC_USER', the user $UNIT runs as"
  else
    fail "$SECRETS is not readable by '$SVC_USER' — the user $UNIT runs as"
    note "fix now:  sudo chgrp $SVC_GROUP $SECRETS && sudo chmod 0640 $SECRETS"
    note "          sudo chmod 0750 $(dirname "$SECRETS") && sudo chgrp $SVC_GROUP $(dirname "$SECRETS")"
    note "then:     ./wifi-diag.sh --restart"
    note "make it stick: the systemd.tmpfiles.rules block in configuration.nix"
  fi
  if [[ -n "$PSK_KEY" ]]; then
    if grep -q "^${PSK_KEY}=" "$SECRETS"; then
      # Never print the value. Length and shape are what actually go wrong.
      VAL="$(sed -n "s/^${PSK_KEY}=//p" "$SECRETS" | head -1)"
      note "key '$PSK_KEY' present, ${#VAL} chars"
      case "$VAL" in *'#'*) fail "value contains '#' — wpa_supplicant's parser truncates it there" ;; esac
      [[ "$VAL" == "${VAL#[[:space:]]}" && "$VAL" == "${VAL%[[:space:]]}" ]] \
        || fail "value has leading/trailing whitespace — the parser strips it"
      # wpa_supplicant takes either an 8-63 char passphrase (PBKDF2'd against
      # the SSID) or a 64-hex raw PSK. Anything else is rejected outright
      # with "EXT PW: Unexpected PSK length".
      if [[ ${#VAL} -eq 64 ]]; then
        note "64 chars — treated as a raw hex PSK, not a passphrase"
      elif [[ ${#VAL} -lt 8 || ${#VAL} -gt 63 ]]; then
        fail "value is ${#VAL} chars — wpa_supplicant needs 8-63, or exactly 64 hex"
      fi
    else
      fail "$SECRETS has no '$PSK_KEY=' line"
    fi
  fi
else
  fail "$SECRETS is missing — wpa_supplicant has no passphrase to use"
fi

# ------------------------------------------------------------- conclusion --
head1 "Summary"
if [[ ${#VERDICT[@]} -eq 0 ]]; then
  printf '%s  Wi-Fi is up and working.%s\n' "$G" "$N"
else
  printf '%s  %d check(s) failed:%s\n' "$R" "${#VERDICT[@]}" "$N"
  printf '    - %s\n' "${VERDICT[@]}"
  cat <<EOF

  Reading the wpa_supplicant journal above:

    "4-way handshake failed" / "WRONG_KEY"
        the passphrase in $SECRETS is wrong. Edit it and
        re-run this script with --restart. No rebuild needed.

    "EXT PW FILE: could not open file ... Permission denied"
        the file exists but the user wpa_supplicant runs as cannot
        read it. See the secrets-file check above for the fix; the
        durable one is the systemd.tmpfiles.rules block in
        configuration.nix, which sets it 0640 root:wpa_supplicant on
        every boot.

    "EXT PW: No PSK found from external storage"
        the '$PSK_KEY' line is missing or misnamed in that file.

    "EXT PW: Unexpected PSK length"
        the value is not 8-63 characters, or a '#' truncated it.

    "No suitable network found" / nothing at all
        the AP is not in range, or is on a band or security mode this
        card will not join.

  If the interface itself is missing, it is firmware, not config — check
  the driver messages above.

  Way back in regardless: dhcpcd runs on every interface, so an ethernet
  cable gets you a lease and an SSH login without touching Wi-Fi.
EOF
fi
echo
