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
DIAG="$HERE/t2-diag"
SUMMARY="$DIAG/summary.txt"
WIFILOG="$DIAG/wifi-tests.txt"
ALT_FW_SET="$HERE/fw-ubuntu"
HASHES="$HERE/wifi-stack-hashes.expected"
# The firmware override is a bind mount at a path the loader already searches,
# never brcmfmac's alternative_fw_path. request_firmware() always joins the
# requested name onto its own search path, so an ABSOLUTE alternative_fw_path
# resolves to /lib/firmware//sysroot/... and fails -2 for a file that exists.
# Three attempts died that way (modprobe.d, the kernel cmdline, and /var plus
# /sysroot), which is why this script no longer stages onto that route at all.
#
# /usr/lib/firmware/brcm exists in the deployment, and /usr is read-only on bootc
# so mkdir cannot create a path there; a bind mount over the existing directory
# works. On a writable root (the t2linux Ubuntu install) the loader-preferred
# /lib/firmware/updates/brcm is available instead.
FW_TARGET="${FW_TARGET:-/usr/lib/firmware/brcm}"
FW_STAGE=/run/t2-tests/fw/brcm
IFACE="${IFACE:-wlp229s0}"
# Supplied by the operator: a tracked script must not carry anyone's own SSID as
# a default, and a wrong default fails silently and reads as a radio fault.
SSID="${WIFI_SSID:-}"
RUNDIR=/run/t2-tests
NM_KEYFILE="/etc/NetworkManager/system-connections/${SSID}.nmconnection"
MODE="${1:---auto}"

# Dependency-light mount check. `mountpoint` ships in util-linux proper rather
# than util-linux-core, so it is not guaranteed present on a minimal image;
# /proc/mounts always is. Exact field match, so a prefix cannot false-positive.
is_mounted() { awk -v t="$1" '$2==t{found=1} END{exit !found}' /proc/mounts; }

PSK=""
# Fixed-string replacement, not sed: a passphrase containing '|' or '\' would
# break or silently alter a sed expression, and a redactor that fails open is
# worse than none. ${var//pat/repl} with a quoted pattern is literal in bash.
redact() {
    if [ -n "${PSK}" ]; then
        local _line
        while IFS= read -r _line || [ -n "$_line" ]; do
            printf '%s\n' "${_line//"$PSK"/<redacted-passphrase>}"
        done
    else
        cat
    fi
}
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

# --check: prove the kit on the media is complete and report the plan. It returns
# before any of the side effects below, so it genuinely touches nothing.
if [ "$MODE" = "--check" ]; then
    rc=0
    echo "media: $HERE"
    if [ -d "$FW_TARGET" ]; then echo "  ok      override target $FW_TARGET"; else echo "  MISSING override target $FW_TARGET"; rc=1; fi
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
    echo "plan: read the image firmware, bind-mount the media set at $FW_TARGET, reload"
    echo "      brcmfmac, read again, unmount. Single pass, no reboot."
    exit "$rc"
fi

# Side effects start here, below the --check return, so --check is genuinely
# read-only instead of truncating the previous run's log on its way past.
mkdir -p "$DIAG" 2>/dev/null || true
mkdir -p "$RUNDIR" 2>/dev/null || true
chmod 700 "$RUNDIR" 2>/dev/null || true
: >"$WIFILOG" 2>/dev/null || true

if [ -z "$SSID" ]; then
    echo "ERROR: set WIFI_SSID to the network name to test." >&2
    echo "       e.g. WIFI_SSID=MyNetwork sudo -E ./run-tests.sh" >&2
    echo "       A tracked script must not carry someone else's SSID as a default." >&2
    exit 2
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
    say "override target: $FW_TARGET $([ -d "$FW_TARGET" ] && echo '(exists)' || echo '(MISSING)')"
    say "override mounted: $(is_mounted "$FW_TARGET" && echo "yes ($(find "$FW_TARGET" -maxdepth 1 -type f 2>/dev/null | wc -l) staged file(s))" || echo no)"
    say "staged set: $ALT_FW_SET ($(find "$FW_STAGE" -maxdepth 1 -type f 2>/dev/null | wc -l) file(s) in $FW_STAGE)"
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

# Copy the media's blob set into a writable staging directory and bind-mount it
# over a path the firmware loader already searches. This replaces the
# alternative_fw_path route entirely; see the note on FW_TARGET above.
stage_alt_firmware() {
    local n
    [ -d "$ALT_FW_SET" ] || { say "    ERROR: $ALT_FW_SET does not exist on the media."; return 1; }
    rm -rf "$FW_STAGE"
    install -d -m 755 "$FW_STAGE"
    for f in "$ALT_FW_SET"/*; do
        [ -f "$f" ] || continue
        local b g
        b=$(basename "$f")
        install -Dm644 "$f" "$FW_STAGE/$b"
        # brcmfmac falls back to the board-less name. On BCM4364B3 no generic
        # brcmfmac4364b3-pcie.bin exists (see elements/bluefin/t2-brcm-firmware.bst),
        # but stage the alias when the set carries one so a partial set cannot
        # silently prove nothing.
        g=$(printf '%s' "$b" | sed 's/\.apple,trinidad//')
        [ "$g" != "$b" ] && install -Dm644 "$f" "$FW_STAGE/$g"
    done
    # Count files, not the directory: install -d satisfies a -d test on its own, so
    # a -d gate passed on an empty set and reported a firmware failure that was
    # really an empty medium.
    n=$(find "$FW_STAGE" -maxdepth 1 -type f 2>/dev/null | wc -l)
    [ "$n" -gt 0 ] || { say "    ERROR: $ALT_FW_SET contains no files; nothing staged."; return 1; }
    [ -d "$FW_TARGET" ] || {
        say "    ERROR: override target $FW_TARGET does not exist. /usr is read-only on"
        say "    bootc, so the target must already be in the image. Set FW_TARGET to an"
        say "    existing searched directory (e.g. /lib/firmware/updates/brcm on a"
        say "    writable root) and re-run."
        return 1
    }
    mount --bind "$FW_STAGE" "$FW_TARGET" || { say "    ERROR: bind mount onto $FW_TARGET failed."; return 1; }
    say "    staged $n blob(s) from $ALT_FW_SET, bind-mounted over $FW_TARGET"
    return 0
}

reload_brcmfmac() {
    # A reload is only safe when the firmware it asks for resolves: with a valid
    # path it re-probes, and with a broken one the driver dies and takes the radio
    # with it. The bind mount above is the validity check; the revision line in the
    # next collect is the confirmation.
    say "    reloading brcmfmac"
    modprobe -r brcmfmac_wcc 2>/dev/null || true
    if ! modprobe -r brcmfmac 2>/dev/null; then
        say "    WARNING: brcmfmac would not unload; the next reading may still show the image firmware."
        return 1
    fi
    sleep 2
    modprobe brcmfmac 2>/dev/null || true
    sleep 3
    say "    firmware after reload: $(firmware_revision)"
    return 0
}

revert_alt_firmware() {
    # /usr is read-only and no boot entry or modprobe.d file was touched, so the
    # unmount is the whole revert, and a reboot clears it regardless.
    if is_mounted "$FW_TARGET"; then
        umount "$FW_TARGET" && say "    $FW_TARGET unmounted" || say "    WARNING: umount $FW_TARGET failed"
    fi
    rm -rf "$FW_STAGE"
    modprobe -r brcmfmac_wcc 2>/dev/null || true
    modprobe -r brcmfmac 2>/dev/null || true
    sleep 2
    modprobe brcmfmac 2>/dev/null || true
    sync
}

# ---------------------------------------------------------------- run
# Single pass, no reboot. The two-phase design existed only because
# alternative_fw_path has to be applied at boot; a bind mount applies live.
say "=== baseline (image firmware)"
collect "image firmware" || true
say ""
say "--- staging the alternative firmware for the second reading"
if ! stage_alt_firmware; then
    say "RESULT: staging failed; the image-firmware reading above stands unchanged."
    exit 1
fi
say "--- reloading brcmfmac onto the staged set"
reload_brcmfmac || true
say ""
collect "alternative firmware ($ALT_FW_SET)" || true
say ""
say "--- reverting the staging"
revert_alt_firmware
say "RESULT: both readings are in this summary. Compare the 'firmware:' lines:"
say "        if they are identical the override did not take effect and this run is VOID."
exit 0
