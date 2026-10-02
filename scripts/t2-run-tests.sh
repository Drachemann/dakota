#!/bin/bash
# T2 acceptance test runner — one command per boot:
#
#   sudo ./run-tests.sh              # full cycle, reboots itself once
#   sudo ./run-tests.sh --no-reboot  # collect this phase only
#
# It runs in two phases, tracked by .t2-phase next to this script (persistent, on
# the media), because the firmware A/B cannot be done inside one boot: unloading
# brcmfmac on this chassis does not re-probe the PCIe radio, and the reloaded
# driver dies with "Dongle setup failed" / brcmf_fw_crashed. So phase 1 collects
# the baseline on the image's own firmware, stages the alternative blob set as a
# modprobe option, and reboots; phase 2 verifies which firmware actually loaded,
# repeats the same tests, reverts the staging and writes the summary.
#
# Output, all on the media next to this script:
#   t2-diag/summary.txt      <- the file to send; everything below, condensed
#   t2-diag/all.txt          <- full boot diagnostics (scripts/t2-boot-diagnostics.sh)
#   t2-diag/wifi-tests.txt   <- full Wi-Fi test log
#
# The passphrase is read from NetworkManager's keyfile if present, otherwise
# prompted for once. It is never printed: every byte written to a log passes
# through redact(), and the keyfile this script writes uses psk-flags=0 so that a
# root shell can supply the secret (an agent-owned secret cannot be).

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
STATE="$HERE/.t2-phase"
DIAG="$HERE/t2-diag"
SUMMARY="$DIAG/summary.txt"
WIFILOG="$DIAG/wifi-tests.txt"
ALT_FW_SET="$HERE/fw-ubuntu"
HASHES="$HERE/wifi-stack-hashes.expected"
FWDIR=/var/firmware-alt/brcm
MODPROBE=/etc/modprobe.d/brcmfmac-altfw.conf
# The blobs live in /var (a persistent subvolume), but the firmware loader runs
# before /var and /etc are mounted: with alternative_fw_path=/var/firmware-alt the
# driver asked for a file that exists and got -2, and the same reason explains why
# /etc/modprobe.d never took effect. /sysroot comes from the initramfs, so the
# same directory is reachable there before any module loads.
ALT_ROOT=/var/firmware-alt
# -T collapses into -Tno and findmnt then rejects the path argument; --target is
# the form that works. FSROOT is /state/os/default/var on a composefs deployment
# and / if /var is not a separate mount, in which case fall back to the layout
# this image actually uses.
_fsroot=$(findmnt -no FSROOT --target /var 2>/dev/null)
case "$_fsroot" in ""|"/") _fsroot=/state/os/default/var ;; esac
ALT_PATH="/sysroot${_fsroot}/firmware-alt"
IFACE=wlp229s0
SSID="${WIFI_SSID:-Nakama}"
RUNDIR=/run/t2-tests
NM_KEYFILE="/etc/NetworkManager/system-connections/${SSID}.nmconnection"
MODE="${1:---auto}"
PHASE="$(cat "$STATE" 2>/dev/null || echo stock)"

mkdir -p "$DIAG" 2>/dev/null || true
mkdir -p "$RUNDIR" 2>/dev/null || true
chmod 700 "$RUNDIR" 2>/dev/null || true
: >"$WIFILOG" 2>/dev/null || true

PSK=""
redact() { if [ -n "${PSK}" ]; then sed "s|${PSK}|<redacted-passphrase>|g"; else cat; fi; }
say() { echo "$*" | redact | tee -a "$SUMMARY" | tee -a "$WIFILOG" >/dev/null; }
wlog() { echo "$*" | redact >>"$WIFILOG"; }
run() { { echo "\$ $*"; "$@" 2>&1; echo "(exit $?)"; } | redact >>"$WIFILOG"; }
filter_wpa() {
    grep -aiE "State: |EAPOL|4-Way|4-way|Authentication|Associated|Trying to associate|CTRL-EVENT|reason=|Handshake|SCAN|WPS|firmware|Selected BSS|RSN|key_mgmt|nl80211: (Connect|Assoc|Disconnect|Deauthenticate|Authenticate)" "$1" 2>/dev/null \
        | grep -aivE "hexdump|PMK|PTK|GTK|key data|psk" | tail -80
}

firmware_revision() {
    journalctl -k -b --no-pager 2>/dev/null | sed -n 's/.*Firmware: BCM4364\/4 //p' | tail -1
}

# --check: prove the kit on the media is complete and report the plan, without
# touching anything. Run it once before the first reboot.
if [ "$MODE" = "--check" ]; then
    rc=0
    echo "media: $HERE"
    echo "phase file: $STATE -> $PHASE"
    for f in runlogs.sh fw-ubuntu wifi-stack-hashes.expected; do
        if [ -e "$HERE/$f" ]; then echo "  ok      $f"; else echo "  MISSING $f"; rc=1; fi
    done
    n=$(ls -1 "$ALT_FW_SET" 2>/dev/null | wc -l)
    [ "$n" -ge 5 ] && echo "  ok      fw-ubuntu has $n blobs" || { echo "  MISSING fw-ubuntu blobs ($n)"; rc=1; }
    k=$(wc -l <"$HASHES" 2>/dev/null || echo 0)
    echo "  ok      $k expected hashes"
    if [ -r "$NM_KEYFILE" ]; then
        echo "  ok      passphrase available from $NM_KEYFILE"
    else
        echo "  note    no stored passphrase; the run will prompt for it"
    fi
    echo "plan: phase $PHASE; then $([ "$PHASE" = stock ] && echo 'stage alternative firmware and reboot' || echo 'revert staging and finish')"
    exit "$rc"
fi

# ---------------------------------------------------------------- passphrase
if [ -r "$NM_KEYFILE" ]; then
    PSK=$(awk -F= '/^psk=/{print $2}' "$NM_KEYFILE")
fi
if [ -z "$PSK" ]; then
    echo "Enter the Wi-Fi passphrase for '$SSID' (not echoed, not logged):"
    read -rsp "passphrase: " PSK
    echo
fi
if [ -z "$PSK" ]; then
    say "RESULT: no passphrase available - nothing to test"
    exit 1
fi
case "${PSK}" in
    *[!0-9a-fA-F]*) PSK_LINE="psk=\"${PSK}\"" ;;
    *) if [ "${#PSK}" -eq 64 ]; then PSK_LINE="psk=${PSK}"; else PSK_LINE="psk=\"${PSK}\""; fi ;;
esac
( umask 077
  printf 'ctrl_interface=%s\nap_scan=1\nnetwork={\n\tssid="%s"\n\t%s\n}\n' \
      "$RUNDIR" "$SSID" "$PSK_LINE" >"$RUNDIR/wpa.conf"
  printf '802-11-wireless-security.psk:%s\n' "$PSK" >"$RUNDIR/passwd"
)
# System-owned keyfile, so a root shell can activate the connection without an
# agent. Writing it directly also avoids putting the secret on a command line.
write_nm_keyfile() {
    ( umask 077
      cat >"$NM_KEYFILE" <<EOF
[connection]
id=$SSID
type=wifi
interface-name=$IFACE

[wifi]
mode=infrastructure
ssid=$SSID

[wifi-security]
key-mgmt=wpa-psk
psk=$PSK
psk-flags=0

[ipv4]
method=auto

[ipv6]
method=auto
EOF
    )
    chmod 600 "$NM_KEYFILE"
    nmcli con reload >/dev/null 2>&1
}

# ---------------------------------------------------------------- wi-fi tests
supplicant_test() {
    local label="$1" rx tx st km best="" i
    ip link set "$IFACE" up >>"$WIFILOG" 2>&1
    rm -f "$RUNDIR/wpa.log" "$RUNDIR/$IFACE"
    wpa_supplicant -D nl80211 -B -i "$IFACE" -c "$RUNDIR/wpa.conf" \
        -f "$RUNDIR/wpa.log" -dd >"$RUNDIR/wpa.stderr" 2>&1
    sleep 3
    if ! pgrep -x wpa_supplicant >/dev/null 2>&1 || [ ! -S "$RUNDIR/$IFACE" ]; then
        say "[$label] supplicant did not start; its own output follows"
        head -20 "$RUNDIR/wpa.stderr" | redact >>"$WIFILOG" 2>&1
        head -20 "$RUNDIR/wpa.log" | redact >>"$WIFILOG" 2>&1
        return 1
    fi
    # Up to 60 s: the radio scans (2.4 + 5 GHz) before it can associate, and this
    # AP's retry cycle can spend most of that in SCANNING.
    for i in $(seq 1 30); do
        sleep 2
        wpa_cli -p "$RUNDIR" -i "$IFACE" status >"$RUNDIR/status.txt" 2>&1
        st=$(sed -n 's/^wpa_state=//p' "$RUNDIR/status.txt" 2>/dev/null)
        [ -n "$st" ] && best="$st"
        case "$st" in
            COMPLETED)  break ;;
            ASSOCIATED) sleep 12; break ;;
        esac
    done
    rx=$(grep -ac 'RX EAPOL-Key' "$RUNDIR/wpa.log" 2>/dev/null)
    tx=$(grep -ac 'TX EAPOL-Key' "$RUNDIR/wpa.log" 2>/dev/null)
    st=$(sed -n 's/^wpa_state=//p' "$RUNDIR/status.txt" 2>/dev/null)
    km=$(sed -n 's/^key_mgmt=//p' "$RUNDIR/status.txt" 2>/dev/null)
    wlog "--- [$label] status (last sample)"; redact <"$RUNDIR/status.txt" >>"$WIFILOG"
    wlog "--- [$label] events"; filter_wpa "$RUNDIR/wpa.log" | redact >>"$WIFILOG"
    if grep -aq "wpa_state=COMPLETED" "$RUNDIR/status.txt"; then
        say "[$label] CONNECTED (wpa_state=COMPLETED key_mgmt=$km RX EAPOL-Key=$rx TX EAPOL-Key=$tx)"
        wpa_cli -p "$RUNDIR" -i "$IFACE" terminate >/dev/null 2>&1
        return 0
    fi
    if [ "${rx}" -gt 0 ]; then
        say "[$label] wpa_state=$st (best seen: $best) key_mgmt=$km RX EAPOL-Key=$rx TX EAPOL-Key=$tx -> AP is talking, key exchange failing"
    else
        say "[$label] wpa_state=$st (best seen: $best) key_mgmt=$km RX EAPOL-Key=0 TX EAPOL-Key=$tx -> no EAPOL in either direction"
    fi
    wpa_cli -p "$RUNDIR" -i "$IFACE" terminate >/dev/null 2>&1
    sleep 2
    return 1
}

nm_state() {
    local st
    systemctl start NetworkManager >/dev/null 2>&1
    sleep 8
    st=$(nmcli -t -f GENERAL.STATE dev show "$IFACE" 2>/dev/null | head -1)
    wlog "$ nmcli -t -f GENERAL.STATE dev show $IFACE"; wlog "$st"
    say "[NetworkManager] $st"
}

wifi_stack_integrity() {
    local f exp got bad=0 n=0
    say "--- Wi-Fi stack file hashes (expected file: $HASHES)"
    while read -r exp f; do
        # Only accept well-formed "<16 hex> <absolute path>" lines: anything else
        # in the file (comments, stray listing output) must never turn into a
        # phantom mismatch.
        case "$exp" in \#*) continue ;; esac
        case "$exp" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) continue ;; esac
        case "$f" in /*) ;; *) continue ;; esac
        n=$((n + 1))
        got=$(sha256sum "$f" 2>/dev/null | cut -c1-16)
        if [ "$got" = "$exp" ]; then
            say "  MATCH    $(basename "$f")"
        else
            say "  MISMATCH $(basename "$f")  expected=$exp got=${got:-<unreadable>}"
            bad=1
        fi
    done <"$HASHES"
    [ "$n" -gt 0 ] || say "  (no usable entries in $HASHES)"
    [ "$bad" -eq 0 ] || say "  (a mismatch or unreadable file points at the medium, not the driver)"
}

collect() {
    local label="$1"
    say ""
    say "=== $label"
    say "firmware: $(firmware_revision)"
    say "alt fw path in effect: '$(cat /sys/module/brcmfmac/parameters/alternative_fw_path 2>/dev/null)'"
    say "alt fw staged: $(find "$ALT_ROOT" -maxdepth 2 -type f 2>/dev/null | wc -l) file(s) in $ALT_ROOT"
    say "alt fw reachable at load time: $([ -d "$ALT_PATH/brcm" ] && echo "yes ($ALT_PATH)" || echo "NO ($ALT_PATH)")"
    say "cmdline: $(tr ' ' '\n' </proc/cmdline | grep -c brcmfmac.alternative_fw_path) parameter(s)"
    say "uptime: $(cut -d' ' -f1 /proc/uptime)s"
    wifi_stack_integrity
    say "--- boot diagnostics (harness)"
    ( cd "$HERE" && ./runlogs.sh >/dev/null 2>&1 )
    if [ -f "$DIAG/all.txt" ]; then
        sed -n '/=== VERDICT/,$p' "$DIAG/all.txt" | while IFS= read -r l; do say "  $l"; done
    else
        say "  harness produced no all.txt"
    fi
    systemctl stop wpa_supplicant >/dev/null 2>&1
    systemctl stop NetworkManager >/dev/null 2>&1
    sleep 4
    if supplicant_test "$label"; then
        say "RESULT($label): the supplicant connected -> see summary above"
        systemctl start NetworkManager >/dev/null 2>&1
        return 0
    fi
    nm_state
    say "RESULT($label): no connection"
    return 1
}

stage_alt_firmware() {
    install -d -m 755 "$FWDIR"
    for f in "$ALT_FW_SET"/*; do
        local b g
        b=$(basename "$f")
        install -Dm644 "$f" "$FWDIR/$b"
        g=$(printf '%s' "$b" | sed 's/\.apple,trinidad//')
        [ "$g" != "$b" ] && install -Dm644 "$f" "$FWDIR/$g"
    done
    # Kernel cmdline, not modprobe.d: this boot proved /etc/modprobe.d is not in
    # effect when brcmfmac loads, while modprobe always reads /proc/cmdline.
    if ! esp=$(find_esp); then
        say "    WARNING: no ESP found; cannot add the cmdline parameter"
        return 1
    fi
    local entry
    entry=$(ls "$esp"/loader/entries/*.conf 2>/dev/null | head -1)
    [ -n "$entry" ] || { say "    WARNING: no boot entry under $esp/loader/entries"; return 1; }
    cp -a "$entry" "$HERE/$(basename "$entry").backup"
    grep -q 'brcmfmac.alternative_fw_path' "$entry" && { echo altfw >"$STATE"; return 0; }
    sed -i "s|^options |options brcmfmac.alternative_fw_path=$ALT_PATH |" "$entry"
    say "    boot entry $(basename "$entry") now carries brcmfmac.alternative_fw_path=$ALT_PATH"
    say "    (backup kept on the media as $(basename "$entry").backup)"
    if [ ! -d "$ALT_PATH/brcm" ]; then
        say "    ERROR: $ALT_PATH/brcm is not reachable, so the driver would still get -2."
        say "    mount layout: $(findmnt -no SOURCE,FSROOT --target /var 2>/dev/null)"
        say "    staging kept; entry restored; not rebooting."
        return 1
    fi
    echo altfw >"$STATE"
    sync
    return 0
}

find_esp() {
    local d
    for d in /boot /boot/efi /efi; do
        [ -d "$d/loader/entries" ] && { echo "$d"; return 0; }
    done
    mkdir -p /mnt/t2esp
    if mount -L EFI-SYSTEM /mnt/t2esp 2>/dev/null; then echo /mnt/t2esp; return 0; fi
    return 1
}

revert_alt_firmware() {
    local esp entry
    if esp=$(find_esp); then
        entry=$(ls "$esp"/loader/entries/*.conf 2>/dev/null | head -1)
        # Restore the backed-up entry verbatim: simpler and safer than editing the
        # options line back out.
        if [ -n "$entry" ] && [ -f "$HERE/$(basename "$entry").backup" ]; then
            cp -a "$HERE/$(basename "$entry").backup" "$entry"
            say "    boot entry $(basename "$entry") restored from backup"
        else
            [ -n "$entry" ] && sed -i "s| *brcmfmac.alternative_fw_path=$ALT_PATH||" "$entry"
        fi
    fi
    rm -rf "$ALT_ROOT"
    rm -f "$MODPROBE"
    echo stock >"$STATE"
    sync
}

# ---------------------------------------------------------------- phases
case "$PHASE" in
stock)
    say "=== phase 1 (image firmware)"
    collect "stock firmware" || true
    say ""
    say "--- staging the alternative firmware for phase 2"
    if ! stage_alt_firmware; then
        say "RESULT: staging failed, nothing rebooted. Send this summary."
        exit 1
    fi
    say "    blobs installed in $FWDIR, option written to $MODPROBE"
    say "    (phase 2 will remove both again after testing)"
    if [ "$MODE" = "--no-reboot" ]; then
        say "RESULT: staged, not rebooting (--no-reboot). Reboot, then run again."
        exit 0
    fi
    say "RESULT: rebooting in 15 s to load the alternative firmware; Ctrl-C to abort"
    sleep 15
    systemctl reboot
    ;;
altfw)
    say "=== phase 2 (alternative firmware)"
    collect "alternative firmware" || true
    say ""
    say "--- reverting the staging so the next boot is stock again"
    revert_alt_firmware
    say "RESULT: cycle complete. Reboot when convenient; send t2-diag/summary.txt"
    ;;
*)
    say "state file $STATE is unreadable ('$PHASE'); falling back to stock phase"
    echo stock >"$STATE"
    exit 1
    ;;
esac
exit 0
