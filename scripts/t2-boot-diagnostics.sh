#!/bin/bash
# Boot diagnostics for the Apple T2 acceptance machine (MacBookPro16,2).
#
# The T2 milestone is verified on hardware, not in CI, so this harness is the
# evidence-gathering step: copy it onto the boot media (or any partition you can
# mount from the booted image), boot the image, then run it with sudo. It writes
# ./t2-diag/all.txt and prints the verdict section.
#
# Run it AFTER using the machine for a moment: unlock the desktop and attempt
# one Wi-Fi connection, so the journal holds a real activation attempt rather
# than an idle radio.
#
# Sections are ordered image-first (what the deployment could have got wrong),
# then hardware, then the platform noise that is expected on this chassis. The
# final VERDICT reduces the whole file to PASS/FAIL per known failure mode, and
# every expected-noise line is annotated where it appears, so a triager can tell
# noise from a regression without re-deriving it: see docs/t2-diagnostics.md.
#
# Override the output directory with OUT=/path/to/dir.

OUT="${OUT:-./t2-diag}"
mkdir -p "$OUT"

# The saved NetworkManager connection to inspect. Supplied by the operator: a
# tracked script must not carry anyone's own SSID, and this file is collected into
# a report that gets shared. Unset means the section is skipped.
WIFI_SSID="${WIFI_SSID:-}"
IFACE="${IFACE:-wlp229s0}"

# Never let one unresponsive command hold the whole capture; never let a missing
# privileged command abort it.
T=20
t() { timeout "$T" "$@" 2>&1 || echo "(timeout/failure: $*)"; }

{
  echo "### collected"; date -u '+%Y-%m-%dT%H:%M:%SZ'; echo "uptime: $(cut -d' ' -f1 /proc/uptime)s"

  echo
  echo "### identity"
  t cat /etc/os-release
  echo "--- bootc status"
  t bootc status
  echo "--- uname"
  uname -a
  echo "--- cmdline"
  cat /proc/cmdline

  echo
  echo "=== 1. BOOT TIMING =============================================="
  echo "--- systemd-analyze (finish time; 'not yet finished' means something is still blocking)"
  t systemd-analyze
  echo "--- systemd-analyze blame (top 25)"
  systemd-analyze blame 2>/dev/null | head -25 || echo "(blame unavailable: boot not finished)"
  echo "--- systemd-analyze critical-chain"
  t systemd-analyze critical-chain
  echo "--- failed units"
  t systemctl --failed --no-pager
  echo "--- jobs still running (empty = boot completed)"
  t systemctl list-jobs --no-pager
  echo "--- snapd seeding (the unit that normally holds multi-user.target open in this image)"
  systemctl status snapd.seeded --no-pager 2>&1 | head -12
  journalctl -b -u snapd.seeded --no-pager 2>&1 | tail -8

  echo
  echo "=== 2. SWAP / ZSWAP ============================================="
  echo "--- bluefin-swapfile-init (expect: success; on slow media it must SKIP fast, not run for 15 min)"
  t systemctl status bluefin-swapfile-init --no-pager
  echo "--- its journal (the measured-write-speed skip reason is printed here)"
  journalctl -b -u bluefin-swapfile-init --no-pager 2>&1 | tail -20
  echo "--- swap devices (expect empty when the unit skipped)"
  t cat /proc/swaps
  t swapon --show
  echo "--- /var/swap contents (leftover 'swapfile.part' or '.write-probe' means an interrupted run)"
  ls -la /var/swap/ 2>&1
  echo "--- what /var lives on (the unit budgets itself against the write speed it measures here)"
  findmnt -no SOURCE,FSTYPE,TARGET /var 2>&1
  echo "--- block devices (uutils lsblk in this image rejects -o with REMOVABLE/FSTYPE, so read sysfs)"
  lsblk 2>&1 | head -20
  for d in /sys/block/*/; do
      n=${d%/}; n=${n##*/}
      case "$n" in loop*|zram*|ram*|dm-*) continue ;; esac
      printf '%s removable=%s\n' "$n" "$(cat "$d/removable" 2>/dev/null || echo -)"
  done
  echo "--- zswap active?"
  grep -H . /sys/module/zswap/parameters/enabled /sys/module/zswap/parameters/compressor 2>&1

  echo
  echo "=== 3. WIRELESS REGULATORY DATABASE ============================="
  echo "--- expect NO 'failed to load regulatory.db' below"
  journalctl -k -b --no-pager 2>&1 | grep -iE "regulatory|cfg80211" | head -10
  echo "--- cfg80211 must be a MODULE (built in, it asks for regulatory.db before / is mounted)"
  lsmod | grep -E "^cfg80211|^mac80211" || echo "NOT LOADED AS A MODULE -> regression, see elements/core/linux-fdsdk.bst"
  echo "--- regdomain parameter (00 = world; expected, the database overrides it per AP country IE)"
  cat /sys/module/cfg80211/parameters/ieee80211_regdom 2>&1
  echo "--- the database itself"
  ls -la /lib/firmware/regulatory.db* 2>&1

  echo
  echo "=== 4. WI-FI ===================================================="
  echo "--- try the connection from the desktop menu BEFORE this script so the attempt is in the log"
  t nmcli device status
  echo "--- interface details"
  nmcli -f GENERAL,WIFI-PROPERTIES dev show wlp229s0 2>&1 | head -40
  echo "--- visible access points"
  t nmcli -f SSID,CHAN,FREQ,SIGNAL,SECURITY dev wifi list
  echo "--- saved connection: security settings (key-mgmt 'wpa-psk' is what works on this AP)"
  if [ -n "$WIFI_SSID" ]; then
    nmcli -f 802-11-wireless-security.key-mgmt,802-11-wireless-security.pmf,802-11-wireless-security.auth-alg con show "$WIFI_SSID" 2>&1
  else
    echo "(WIFI_SSID unset: skipping the saved-connection dump; re-run with WIFI_SSID=<name> to include it)"
  fi
  echo "--- association outcome (look for 'Associated with' then a 4-way handshake result)"
  journalctl -b -u wpa_supplicant --no-pager 2>&1 | grep -iE "Trying to associate|Associated with|Authentication with|Handshake|reason=|SSID-TEMP-DISABLED|WPS" | tail -30
  echo "--- NetworkManager activation failures"
  journalctl -b -u NetworkManager --no-pager 2>&1 | grep -iE "failed|no-secrets|association took too long|secrets" | tail -20
  echo "--- brcmfmac probe + P2P (the -52 p2p lines are expected on this chassis)"
  journalctl -k -b --no-pager 2>&1 | grep -iE "brcmfmac|brcmf_|ieee80211 phy" | head -20
  echo "--- rfkill"
  t rfkill list

  echo
  echo "=== 5. BLUETOOTH ================================================"
  echo "--- 'firmware Patch file not found, tried brcm/BCM.hcd' is EXPECTED on this chassis"
  echo "--- 'advertising packet type' must NOT appear (patch 9002 regression signature)"
  journalctl -k -b --no-pager 2>&1 | grep -iE "Bluetooth|hci0|hci_uart|btbcm" | head -25
  echo "--- advertising signature (expect no output)"
  journalctl -k -b --no-pager 2>&1 | grep -i "advertising packet type"
  echo "--- controller"
  t bluetoothctl show
  echo "--- known devices (a paired Magic Trackpad proves the radio works end to end)"
  t bluetoothctl devices
  echo "--- service"
  t systemctl status bluetooth --no-pager
  echo "--- 'ConfigurationDirectory bluetooth ... mode is different' is EXPECTED (bluez unit, same on Ubuntu)"
  journalctl -b -u bluetooth --no-pager 2>&1 | grep -iE "ConfigurationDirectory|Failed|error" | head -10

  echo
  echo "=== 6. RADIO FIRMWARE ==========================================="
  ls -la /lib/firmware/brcm/ 2>&1 | grep -iE "apple,|\.hcd" | head -15
  echo "apple, files: $(ls /lib/firmware/brcm/ 2>/dev/null | grep -c 'apple,')"
  echo "--- Wi-Fi firmware actually loaded"
  journalctl -k -b --no-pager 2>&1 | grep -iE "Firmware: BCM|brcmf_fw_alloc_request|TxCap" | head -5

  echo
  echo "=== 7. T2 HARDWARE =============================================="
  echo "--- t2bce / touch bar / smc"
  journalctl -k -b --no-pager 2>&1 | grep -iE "t2bce|appletb|applesmc|appletbdrm" | head -30
  echo "--- 'intel-lpss ... IRQ index 0 not found' and 'failed to request DMA' are EXPECTED on this chassis"
  journalctl -k -b --no-pager 2>&1 | grep -iE "intel-lpss|dw-apb-uart|ttyS" | head -10
  echo "--- fans"
  t systemctl status t2fanrd --no-pager
  ls /sys/devices/platform/applesmc.768/ 2>/dev/null | head -5
  echo "--- modules of interest (expect brcmfmac, hci_uart, bt bcm, applesmc, t2bce built in)"
  lsmod 2>/dev/null | grep -E "brcmfmac|hci_uart|btbcm|applesmc|appletb|cfg80211|mac80211|t2bce"
  echo "--- t2bce modules are built into vmlinuz, so absence from lsmod is expected"
  ls -la /lib/modules/*/vmlinuz 2>&1
  echo "--- input devices (the internal keyboard/trackpad must be here)"
  t cat /proc/bus/input/devices

  echo
  echo "=== 8. AUDIO ===================================================="
  echo "--- alsa-utils is not in this image, so /proc/asound is the evidence"
  command -v aplay || echo "(aplay not installed: expected, alsa-utils is not shipped)"
  echo "--- cards"
  t cat /proc/asound/cards
  echo "--- device nodes"
  ls -la /dev/snd/ 2>&1 | head -10
  echo "--- card profiles: the AppleT2xN directory must match the card driver name"
  ls /usr/share/alsa/ucm2/conf.d/ 2>&1 | grep -i apple
  echo "--- sound servers"
  pgrep -a -f "pipewire|wireplumber|pulseaudio" | head -10
  echo "--- session-side view (needs the desktop session, ignores failure when run from a TTY)"
  loginctl list-sessions 2>&1 | head -5

  echo
  echo "=== 9. STORAGE / INTEGRITY ======================================"
  echo "--- 'FILE CORRUPTED' from fs-verity means a file on the boot media failed its hash tree"
  journalctl -b -k --no-pager 2>&1 | grep -iE "verity|FILE CORRUPTED" | head -10
  echo "--- I/O errors (a flaky stick shows up here)"
  journalctl -b -k --no-pager 2>&1 | grep -iE "I/O error|medium error|unable to read|reset (SuperSpeed|high-speed)" | head -15
  echo "--- loop devices and squashfs mounts that used them"
  t losetup -a
  findmnt -t squashfs 2>&1
  echo "--- snapd (with snapd in the image, its snap mounts explain loop/squashfs/verity lines)"
  snap list 2>&1 | head -10
  echo "--- journald on btrfs without NOCOW is slow; this is informational"
  journalctl -b -k --no-pager 2>&1 | grep -i "copy-on-write" | head -3

  # fs-verity is checked per block as a file is read, so a corrupt block reports
  # the inode it lives in the first time anything touches that range. Locating it
  # is what turns the report into a repairable finding: the boot media is the
  # suspect, and a re-flash is the remedy.
  verity_inode=$(journalctl -b -k --no-pager 2>/dev/null \
      | sed -n 's/.*fs-verity (\([^)]*\), inode \([0-9][0-9]*\)).*/\2/p' | head -1)
  if [ -n "${verity_inode}" ]; then
      echo "--- fs-verity named inode ${verity_inode}; locating it (bounded, can be slow)"
      findmnt -no SOURCE,FSTYPE /sysroot 2>&1
      if command -v find >/dev/null 2>&1; then
          timeout 120 find /sysroot -xdev -inum "${verity_inode}" -printf '%i %s %p\n' 2>/dev/null | head -5
      else
          echo "(no find(1) in this image; locate the inode from a rescue shell)"
      fi
      ls -la /sysroot/composefs/ 2>&1 | head -5
      grep -o 'composefs=[0-9a-f]*' /proc/cmdline | head -1
  fi

  echo
  echo "=== 10. CLOCK / RTC ============================================"
  echo "--- this chassis' CMOS RTC reads garbage at cold boot; systemd applies its"
  echo "--- clock-epoch fallback until NTP answers, which is why pre-sync timestamps read 2011"
  t timedatectl
  ls -la /usr/lib/clock-epoch 2>&1
  cat /proc/driver/rtc 2>&1 | head -6
  echo "--- rtc devices"
  for r in /sys/class/rtc/rtc*; do echo "$r: $(cat "$r/name" 2>/dev/null) date=$(cat "$r/date" 2>/dev/null) time=$(cat "$r/time" 2>/dev/null)"; done
  journalctl -k -b --no-pager 2>&1 | grep -iE "setting system clock|rtc_cmos|acpi-tad" | head -10

  echo
  echo "=== VERDICT ====================================================="
  # Each check prints PASS or FAIL with the reason, so a triager can read the
  # last screenful instead of the whole file.
  verdict() { printf '%-42s %s\n' "$1" "$2"; }
  if ! systemd-analyze >/dev/null 2>&1; then
      verdict "boot completed" "FAIL (boot never finished; see section 1)"
  else
      verdict "boot completed" "PASS"
  fi
  if ! systemctl cat bluefin-swapfile-init >/dev/null 2>&1; then
      verdict "bluefin-swapfile-init" "N/A (unit absent from this image)"
  elif [ "$(systemctl show -p Result --value bluefin-swapfile-init 2>/dev/null)" = "success" ]; then
      verdict "bluefin-swapfile-init" "PASS"
  else
      verdict "bluefin-swapfile-init" "FAIL ($(systemctl show -p Result --value bluefin-swapfile-init 2>/dev/null); see section 2)"
  fi
  if journalctl -k -b --no-pager 2>&1 | grep -q "failed to load regulatory.db"; then
      verdict "regulatory.db loaded" "FAIL (see section 3)"
  else
      verdict "regulatory.db loaded" "PASS"
  fi
  if lsmod | grep -q "^cfg80211"; then
      verdict "cfg80211 is a module" "PASS"
  else
      verdict "cfg80211 is a module" "FAIL (built in; see section 3)"
  fi
  if journalctl -k -b --no-pager 2>&1 | grep -q "advertising packet type"; then
      verdict "BT advertising (patch 9002)" "FAIL (see section 5)"
  else
      verdict "BT advertising (patch 9002)" "PASS"
  fi
  # Wi-Fi is three checks, not one. Association is what already succeeds in the
  # T2 failure being chased, so a single "connected" check cannot tell a working
  # radio from that bug. See docs/t2-diagnostics.md, "Wi-Fi on this chassis".
  if nmcli -t -f GENERAL.STATE dev show "$IFACE" 2>/dev/null | grep -q "100 (connected)"; then
      verdict "wifi-assoc" "PASS"
  else
      verdict "wifi-assoc" "FAIL/NOT ATTEMPTED (see section 4)"
  fi

  # Handshake stage. NetworkManager's own supplicant owns the interface, so read it
  # through its control socket; the journal is the fallback and records the same
  # completion without the socket. The RX/TX EAPOL-Key counters are deliberately
  # NOT read here: they exist only in a standalone supplicant's debug log, which
  # means stopping NetworkManager, and that cannot coexist with wifi-assoc in one
  # passive pass. t2-wifi-probe.sh is where those counters come from.
  hs_src=""; hs_state=""
  hs_state=$(timeout "$T" wpa_cli -i "$IFACE" status 2>/dev/null | sed -n 's/^wpa_state=//p')
  if [ -n "$hs_state" ]; then
      hs_src="wpa_cli"
  elif journalctl -b --no-pager 2>&1 | grep -qE "WPA: Key negotiation completed|CTRL-EVENT-CONNECTED"; then
      hs_state=COMPLETED; hs_src="journal"
  fi
  case "$hs_state" in
      COMPLETED) verdict "wifi-handshake" "PASS ($hs_src: wpa_state=COMPLETED)" ;;
      "")        verdict "wifi-handshake" "FAIL/NOT ATTEMPTED (no supplicant state and no handshake in the journal)" ;;
      *)         verdict "wifi-handshake" "FAIL ($hs_src: wpa_state=$hs_state; associated but the four-way handshake did not complete)" ;;
  esac

  # Traffic stage: the only check that shows the radio carries payload, which is
  # what "Wi-Fi works" means. NetworkManager performs the fetch itself, so this
  # needs no external tool: curl is NOT in this image (it appears only as a
  # build-dependency of libvirt), and a missing curl would read as a radio fault.
  # NM's default probe URI is plain HTTP, so the T2's pre-NTP 2011 clock cannot
  # fail it on certificate validation and confound a Wi-Fi result with a clock one.
  pay_state=$(timeout 30 nmcli networking connectivity check 2>/dev/null | tail -1)
  case "$pay_state" in
      full)    verdict "wifi-payload" "PASS (NetworkManager connectivity check: full)" ;;
      limited) verdict "wifi-payload" "FAIL (connectivity 'limited': reached a network but not the internet, or the tether is absent)" ;;
      portal)  verdict "wifi-payload" "FAIL (connectivity 'portal': a captive portal answered; see section 4)" ;;
      none)    verdict "wifi-payload" "FAIL (connectivity 'none': no route out over any interface)" ;;
      *)       verdict "wifi-payload" "FAIL/NOT ATTEMPTED (connectivity check returned '${pay_state:-<nothing>}')" ;;
  esac
  if journalctl -b -k --no-pager 2>&1 | grep -q "FILE CORRUPTED"; then
      verdict "boot media integrity" "FAIL (fs-verity mismatch; see section 9)"
  else
      verdict "boot media integrity" "PASS"
  fi
  if [ -d /dev/snd ] && [ -n "$(ls -A /dev/snd 2>/dev/null)" ]; then
      verdict "ALSA devices present" "PASS"
  else
      verdict "ALSA devices present" "FAIL (see section 8)"
  fi
  if [ "$(systemctl --failed --no-legend 2>/dev/null | wc -l)" -eq 0 ]; then
      verdict "no failed units" "PASS"
  else
      verdict "no failed units" "FAIL ($(systemctl --failed --no-legend 2>/dev/null | wc -l) units; see section 1)"
  fi
} > "$OUT/all.txt" 2>&1

echo "written to $OUT/all.txt ($(wc -l < "$OUT/all.txt") lines)"
echo "--- verdict ---"
sed -n '/=== VERDICT/,$p' "$OUT/all.txt"
