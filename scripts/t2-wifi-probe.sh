#!/bin/bash
# Wi-Fi association probe for the Apple T2 acceptance machine (MacBookPro16,2).
#
# What the captures established: the client associates, the supplicant settles on
# WPA2-PSK/CCMP, and then NO EAPOL frames flow at all (RX EAPOL-Key=0,
# TX EAPOL-Key=0) before the supplicant's own timeout disconnects it. A wrong
# passphrase cannot look like that -- a wrong passphrase still gets message 1 and
# fails the MIC check -- so the handshake never starts, and the same access point
# works from a t2linux (Ubuntu) install on this chassis with the same chip. That
# leaves two implementation-side candidates, and this script tests both in one
# run, plus NetworkManager last:
#
#   stage 1  facts: firmware revision, regulatory domain, rfkill
#   stage 2  wpa_supplicant with its own negotiation (no key_mgmt override)
#   stage 3  wpa_supplicant pinned to the working install's negotiation:
#            key_mgmt=WPA-PSK, ieee80211w=1 -- if this connects while stage 2 does
#            not, the image's supplicant is negotiating something the AP answers
#            by not starting the handshake
#   stage 4  firmware A/B: the alternative blob set copied to a writable staging
#            directory and bind-mounted over $FW_TARGET, a path the loader already
#            searches. Never brcmfmac's alternative_fw_path: request_firmware()
#            joins the requested name onto its own search path, so an absolute
#            value resolves to /lib/firmware//... and fails -2 (three attempts
#            died that way). The set is also installed under the board-less alias
#            when it carries one; on BCM4364B3 no generic name exists. The
#            interface is verified before the test rather than assumed, and the
#            firmware revision is logged after the reload so that an override
#            which did not take effect is VOID rather than negative evidence.
#   stage 5  NetworkManager, secret supplied, WPS disabled, key-mgmt wpa-psk
#   finally  restore: stock firmware, NetworkManager up, WPS property back
#
# Run as root, from the media that holds it:
#   sudo ./t2-wifi-probe.sh [/path/to/alternative/fw/dir]
# Default alternative directory: ./fw-ubuntu next to this script.
#
# SECRETS: every byte written to the log passes through redact(), which replaces
# the passphrase with <redacted-passphrase>. wpa_supplicant quotes the value back
# in its parse errors, so an unfiltered dump leaks it.
#
# A wpa_supplicant passphrase must be quoted, or be a raw 64-hex PSK; unquoted
# fails to parse ("Invalid PSK").

set -u
IFACE=wlp229s0
# The network to test is always supplied by the operator: a tracked script must
# not carry anyone's own SSID as a default, and a wrong default fails silently.
SSID="${WIFI_SSID:-}"
if [ -z "$SSID" ]; then
    echo "ERROR: set WIFI_SSID to the network name to test." >&2
    echo "       e.g. WIFI_SSID=MyNetwork sudo -E ./t2-wifi-probe.sh" >&2
    exit 2
fi
HERE="$(cd "$(dirname "$0")" && pwd)"
ALT_FW_DIR="${1:-$HERE/fw-ubuntu}"
OUT="${OUT:-$HERE/t2-diag}"
RUNDIR=/run/t2-wifi-probe
# A bind mount at a path the loader already searches, never alternative_fw_path:
# request_firmware() joins the requested name onto its own search path, so an
# ABSOLUTE alternative_fw_path becomes /lib/firmware//etc/firmware and fails -2
# for a file that exists. /usr is read-only on bootc, so the target must already
# exist in the image.
FW_TARGET="${FW_TARGET:-/usr/lib/firmware/brcm}"
FW_STAGE=/run/t2-wifi-probe/fw/brcm

# Dependency-light mount check. `mountpoint` ships in util-linux proper rather
# than util-linux-core, so it is not guaranteed present on a minimal image;
# /proc/mounts always is.
is_mounted() { awk -v t="$1" '$2==t{found=1} END{exit !found}' /proc/mounts; }
NM_KEYFILE="/etc/NetworkManager/system-connections/${SSID}.nmconnection"
mkdir -p "$OUT" "$RUNDIR"
chmod 700 "$RUNDIR"
LOG="$OUT/wifi-probe.txt"

PSK=""
redact() { if [ -n "${PSK}" ]; then sed "s|${PSK}|<redacted-passphrase>|g"; else cat; fi; }
msg() { echo "$*" | redact | tee -a "$LOG"; }
run() { { echo "\$ $*"; "$@" 2>&1; echo "(exit $?)"; } | redact >>"$LOG"; }
filter_wpa() {
    grep -aiE "State: |EAPOL|4-Way|4-way|Authentication|Associated|Trying to associate|CTRL-EVENT|reason=|Handshake|SCAN|WPS|firmware|Selected BSS|RSN|key_mgmt|nl80211: (Connect|Assoc|Disconnect|Deauthenticate|Authenticate)" "$1" 2>/dev/null \
        | grep -aivE "hexdump|PMK|PTK|GTK|key data|psk" | tail -120
}

: >"$LOG"
msg "=== t2 wifi probe $(date -u '+%Y-%m-%dT%H:%M:%SZ')  ssid=$SSID iface=$IFACE"
msg "=== alternative firmware set: $ALT_FW_DIR"

echo "--- stage 1: facts" >>"$LOG"
run nmcli -f GENERAL.DEVICE,GENERAL.STATE,GENERAL.DRIVER,GENERAL.FIRMWARE-VERSION dev show "$IFACE"
run rfkill list
run cat /sys/module/cfg80211/parameters/ieee80211_regdom
run sh -c "journalctl -k -b --no-pager | grep -aiE 'Firmware: BCM|brcmf_fw_alloc_request' | tail -3"
run ls -la "$ALT_FW_DIR"

# The boot media may be carrying fs-verity damage (a sparse flash over old bytes
# leaves composefs objects inconsistent). Any file whose bytes live in a damaged
# region fails to read, so hashing the Wi-Fi stack's own files separates "the
# medium is lying to us" from a genuine driver or supplicant fault. Compare these
# against wifi-stack-hashes.expected next to this script; a blank hash means the
# read failed outright.
echo "--- integrity of the Wi-Fi stack's files:" >>"$LOG"
for f in "/usr/lib/firmware/brcm/brcmfmac4364b3-pcie.apple,trinidad.bin" \
         "/usr/lib/firmware/brcm/brcmfmac4364b3-pcie.apple,trinidad.clm_blob" \
         "/usr/lib/firmware/brcm/brcmfmac4364b3-pcie.apple,trinidad.txcap_blob" \
         /usr/sbin/wpa_supplicant /usr/sbin/wpa_cli \
         /usr/lib/modules/*/kernel/net/wireless/cfg80211.ko \
         /usr/lib/modules/*/kernel/net/mac80211/mac80211.ko \
         /usr/lib/modules/*/kernel/drivers/net/wireless/broadcom/brcm80211/brcmfmac/brcmfmac.ko; do
    printf '%s %s\n' "$(sha256sum $f 2>/dev/null | cut -c1-16)" "$f" >>"$LOG"
done

if [ -r "$NM_KEYFILE" ]; then
    PSK=$(awk -F= '/^psk=/{print $2}' "$NM_KEYFILE")
    [ -n "$PSK" ] && msg "--- passphrase taken from NetworkManager's keyfile (never printed)"
fi
if [ -z "$PSK" ]; then
    msg "--- no stored passphrase: enter it now (input not echoed, not logged)"
    read -rsp "Wi-Fi passphrase for $SSID: " PSK
    echo
fi
if [ -z "$PSK" ]; then
    msg "RESULT: NO PASSPHRASE - nothing to test"
    exit 1
fi
# 64 hex digits is a raw PSK and must stay unquoted; anything else is a
# passphrase and must be quoted.
case "${PSK}" in
    *[!0-9a-fA-F]*) PSK_LINE="psk=\"${PSK}\"" ;;
    *) if [ "${#PSK}" -eq 64 ]; then PSK_LINE="psk=${PSK}"; else PSK_LINE="psk=\"${PSK}\""; fi ;;
esac
( umask 077
  printf 'ctrl_interface=%s\nap_scan=1\nnetwork={\n\tssid="%s"\n\t%s\n}\n' \
      "$RUNDIR" "$SSID" "$PSK_LINE" >"$RUNDIR/wpa.conf"
  printf 'ctrl_interface=%s\nap_scan=1\nnetwork={\n\tssid="%s"\n\t%s\n\tkey_mgmt=WPA-PSK\n\tieee80211w=1\n}\n' \
      "$RUNDIR" "$SSID" "$PSK_LINE" >"$RUNDIR/wpa-explicit.conf"
  printf '802-11-wireless-security.psk:%s\n' "$PSK" >"$RUNDIR/passwd"
)

supplicant_start() {
    local conf="$1" tag="$2"
    rm -f "$RUNDIR/wpa.log" "$RUNDIR/$IFACE"
    wpa_supplicant -D nl80211 -B -i "$IFACE" -c "$conf" \
        -f "$RUNDIR/wpa.log" -dd >"$RUNDIR/wpa.stderr" 2>&1
    sleep 3
    echo "--- [$tag] supplicant processes:" >>"$LOG"
    pgrep -a wpa_supplicant >>"$LOG" 2>&1
    echo "--- [$tag] control socket directory:" >>"$LOG"
    ls -la "$RUNDIR" >>"$LOG" 2>&1
    if ! pgrep -x wpa_supplicant >/dev/null 2>&1 || [ ! -S "$RUNDIR/$IFACE" ]; then
        echo "--- [$tag] supplicant did not come up; its own first output:" >>"$LOG"
        head -40 "$RUNDIR/wpa.stderr" | redact >>"$LOG" 2>&1
        head -40 "$RUNDIR/wpa.log" | redact >>"$LOG" 2>&1
        return 1
    fi
    return 0
}

manual_test() {
    local label="$1" conf="$2" tag="$3" rx tx st
    ip link set "$IFACE" up >>"$LOG" 2>&1
    if ! supplicant_start "$conf" "$tag"; then
        echo "--- $label: SUPPLICANT START FAILED" >>"$LOG"
        return 1
    fi
    sleep 28
    wpa_cli -p "$RUNDIR" -i "$IFACE" status >"$RUNDIR/status.txt" 2>&1
    echo "--- $label: wpa_cli status" >>"$LOG"
    redact <"$RUNDIR/status.txt" >>"$LOG"
    echo "--- $label: events (key material filtered out)" >>"$LOG"
    filter_wpa "$RUNDIR/wpa.log" | redact >>"$LOG"
    rx=$(grep -ac 'RX EAPOL-Key' "$RUNDIR/wpa.log" 2>/dev/null)
    tx=$(grep -ac 'TX EAPOL-Key' "$RUNDIR/wpa.log" 2>/dev/null)
    st=$(sed -n 's/^wpa_state=//p' "$RUNDIR/status.txt" 2>/dev/null)
    km=$(sed -n 's/^key_mgmt=//p' "$RUNDIR/status.txt" 2>/dev/null)
    echo "--- $label: summary" >>"$LOG"
    if [ "${rx}" -gt 0 ]; then
        echo "wpa_state=${st} key_mgmt=${km} RX EAPOL-Key=${rx} TX EAPOL-Key=${tx} -> AP is talking; key exchange is failing" >>"$LOG"
    else
        echo "wpa_state=${st} key_mgmt=${km} RX EAPOL-Key=0 TX EAPOL-Key=${tx} -> AP never starts the handshake with this client" >>"$LOG"
    fi
    wpa_cli -p "$RUNDIR" -i "$IFACE" terminate >/dev/null 2>&1
    sleep 2
    grep -aq "wpa_state=COMPLETED" "$RUNDIR/status.txt"
}

restore() {
    wpa_cli -p "$RUNDIR" -i "$IFACE" terminate >/dev/null 2>&1
    if is_mounted "$FW_TARGET"; then umount "$FW_TARGET" >/dev/null 2>&1; fi
    modprobe -r brcmfmac_wcc brcmfmac 2>/dev/null
    modprobe brcmfmac 2>/dev/null
    rm -rf /etc/firmware/brcm "$FW_STAGE"
    # The passphrase must not survive the run on ANY exit path. This used to be
    # deleted only on the fall-through at the end, so the four early exits left
    # /run/t2-wifi-probe/passwd behind for the machine's uptime.
    rm -f "$RUNDIR/passwd" "$RUNDIR/wpa.conf" "$RUNDIR/wpa-explicit.conf"
    systemctl start NetworkManager >/dev/null 2>&1
}
trap restore EXIT

echo "--- stage 2: wpa_supplicant, its own negotiation, image firmware" >>"$LOG"
systemctl stop NetworkManager >/dev/null 2>&1
systemctl stop wpa_supplicant >/dev/null 2>&1
sleep 4
if manual_test "stage 2 (default negotiation)" "$RUNDIR/wpa.conf" default; then
    msg "RESULT: CONNECTED with the supplicant's own negotiation -> NetworkManager's"
    msg "        activation flow is the fault, not the radio"
    exit 0
fi

echo "--- stage 3: wpa_supplicant pinned to key_mgmt=WPA-PSK, ieee80211w=1" >>"$LOG"
if manual_test "stage 3 (pinned negotiation)" "$RUNDIR/wpa-explicit.conf" pinned; then
    msg "RESULT: CONNECTED only when key_mgmt/PMF were pinned to what the working"
    msg "        install uses -> the image's supplicant negotiates something this AP"
    msg "        answers by never starting the handshake. That is a fixable setting."
    exit 0
fi

echo "--- stage 4: alternative firmware via a bind mount over $FW_TARGET" >>"$LOG"
if [ ! -d "$ALT_FW_DIR" ]; then
    msg "stage 4 skipped: no alternative blob set at $ALT_FW_DIR"
elif ! modprobe -r brcmfmac_wcc brcmfmac 2>>"$LOG"; then
    msg "stage 4 skipped: could not unload brcmfmac (something still holds $IFACE)"
else
    rm -rf "$FW_STAGE"
    install -d -m 755 "$FW_STAGE"
    n=0
    # Install each blob under its own name and under the board-less alias, so a
    # request for either resolves to the alternative set. (On BCM4364B3 no generic
    # brcmfmac4364b3-pcie.bin exists, so the alias is normally absent.)
    for f in "$ALT_FW_DIR"/*; do
        [ -f "$f" ] || continue
        b=$(basename "$f")
        install -Dm644 "$f" "$FW_STAGE/$b"; n=$((n + 1))
        g=$(printf '%s' "$b" | sed 's/\.apple,trinidad//')
        [ "$g" != "$b" ] && install -Dm644 "$f" "$FW_STAGE/$g"
    done
    run ls -la "$FW_STAGE"
    if [ "$n" -eq 0 ]; then
        msg "stage 4 skipped: $ALT_FW_DIR contains no files"
    elif [ ! -d "$FW_TARGET" ]; then
        msg "stage 4 skipped: override target $FW_TARGET does not exist on this root."
        msg "        /usr is read-only on bootc; set FW_TARGET to an existing searched"
        msg "        directory (e.g. /lib/firmware/updates/brcm on a writable root)."
    elif ! mount --bind "$FW_STAGE" "$FW_TARGET" 2>>"$LOG"; then
        msg "stage 4 skipped: bind mount onto $FW_TARGET failed"
    else
        modprobe brcmfmac 2>>"$LOG"
        sleep 8
        echo "--- stage 4: kernel messages during the reload" >>"$LOG"
        journalctl -k --since "-4 min" --no-pager 2>&1 \
            | grep -aiE "brcmfmac|firmware|wlp229s0|cfg80211" | redact >>"$LOG"
        # Confirm the override actually took effect before reading any result: if
        # the revision line is unchanged the run is VOID, not negative evidence.
        rev=$(journalctl -k --since "-4 min" --no-pager 2>/dev/null | sed -n 's/.*Firmware: BCM4364\/4 //p' | tail -1)
        echo "--- stage 4: firmware revision after reload: ${rev:-<none>}" >>"$LOG"
        if [ ! -e "/sys/class/net/$IFACE" ]; then
            msg "stage 4 inconclusive: the interface did not come back after the reload."
        elif manual_test "stage 4 (alternative firmware)" "$RUNDIR/wpa.conf" altfw; then
            msg "RESULT: CONNECTED only with the alternative firmware blob set -> this"
            msg "        image's vendored blobs are the fault; swap the blob source in"
            msg "        elements/bluefin/t2-brcm-firmware.bst"
            exit 0
        else
            msg "stage 4: did not connect with the alternative firmware either"
        fi
    fi
fi

echo "--- stage 5: NetworkManager, secret supplied, WPS disabled, wpa-psk" >>"$LOG"
restore
sleep 8
run nmcli con mod "$SSID" 802-11-wireless-security.wps-method 1
run nmcli con mod "$SSID" 802-11-wireless-security.key-mgmt wpa-psk
run nmcli con up "$SSID" passwd-file "$RUNDIR/passwd"
sleep 25
run nmcli -f GENERAL.STATE,GENERAL.REASON dev show "$IFACE"
if nmcli -t -f GENERAL.STATE dev show "$IFACE" 2>/dev/null | grep -q "100 (connected)"; then
    msg "RESULT: CONNECTED through NetworkManager with WPS off and wpa-psk pinned ->"
    msg "        this image needs those two connection settings for this AP"
    exit 0
fi
run nmcli con mod "$SSID" 802-11-wireless-security.wps-method 0

msg "RESULT: no path connects. Stage 2/3 summaries say whether the AP ever starts"
msg "        the handshake (RX EAPOL-Key) and which key management was used. With"
msg "        RX=0 in every stage, the remaining implementation difference from the"
msg "        working install is the kernel: brcmfmac 7.2.6 here, 7.2.8 there."
msg "        Do NOT target 7.2.7: it carries the same brcmfmac as 7.2.6 (newest"
msg "        commit f26e1b1690 in both) and would move nothing on the radio. 7.2.8"
msg "        is the target: it adds c5f73cde72 'fix lost 802.1x TX completion"
msg "        wakeup'. Settle firmware against kernel with the bind-mount 2x2 in"
msg "        docs/t2-wifi-handoff.md before spending a build."
# passwd is removed by restore() on every exit path, including this one.
exit 0
