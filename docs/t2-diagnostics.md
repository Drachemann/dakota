# T2 boot diagnostics

The Apple T2 milestone (MacBookPro16,2) is verified by booting real hardware, not
by CI: the initramfs, the LUKS prompt, the T2 bridge devices and both radios have
no VM equivalent. `scripts/t2-boot-diagnostics.sh` is the evidence-collecting
half of that loop, and this document is the key to reading its output.

## Collecting a report

1. Copy `scripts/t2-boot-diagnostics.sh` onto media the booted image can mount.
2. Boot the image, unlock the desktop, and attempt one Wi-Fi connection. The
   journal then holds a real activation attempt instead of an idle radio.
3. `sudo ./t2-boot-diagnostics.sh` — it writes `./t2-diag/all.txt` (override with
   `OUT=`) and prints its `VERDICT` section.

Read the verdict first. Every check that can hang is bounded by `timeout`, so a
stalled capture is itself a finding rather than a reason to interrupt the script.

## Failure modes that belong to this image

| Signature in the report | Cause | Fixed by |
|---|---|---|
| `bluefin-swapfile-init`: `Failed with result 'timeout'`, `systemd-analyze blame` showing it at 15 min, other boot-time units (ldconfig, device enumeration) taking minutes | The zswap backing store is on the `sysinit.target` path through `swap.target`, so its whole write time is boot time, and on a ~6 MB/s stick an 8 GiB `dd` starves every other reader (ldconfig took 14 minutes in one capture) | `files/swapfile/bluefin-swapfile-init` measures the write itself: a 32 MiB `conv=fsync` probe, and creation is skipped when the full size would exceed a 120 s budget. On a live USB boot the unit must report **success with an empty `/proc/swaps`** — that is the intended result, not a missing feature |
| The skip never fires and the unit times out anyway | An earlier revision classified the media instead of measuring it, resolving `/var`'s backing block device from `mountinfo` and skipping when it was on a USB bus. It mis-detected the bootc composefs deployment: on the shipped image `/var` is a btrfs subvolume (`/dev/sda3[/state/os/default/var]`) whose resolution inside the unit did not reach the USB check, so the store was still written to the stick. Measuring the write cannot be fooled by an unusual mount layout, and also catches slow fixed media a media test would allow | `files/swapfile/bluefin-swapfile-init` |
| `swapfile.part` or `.write-probe` left in `/var/swap` | Creation was interrupted by a reset. The next boot reclaims the leftovers; a file that survives several boots means the script is failing before its reclaim step | `files/swapfile/bluefin-swapfile-init` (temporary name plus rename, so a partial file is never mistaken for a complete one) |
| `fs-verity (sda3, inode N): FILE CORRUPTED!` | The flash was **sparse** (`dd conv=sparse`) over media that previously held a different image. Zero blocks in the image are skipped, so the device keeps the older bytes; composefs stores its EROFS objects as sparse files under `/sysroot/composefs/objects/`, so those retained bytes land exactly inside a verity-protected file. The tell is the `real_hash` of a stale region repeating across flashes, and the harness's locator resolves the inode to the object path | Flash the raw image densely (`conv=fsync`, no `conv=sparse`) unless the target is known to be zeroed. A sparse flash is only safe when every block the image leaves zero is already zero on the device |
| `cfg80211: failed to load regulatory.db` | `CONFIG_CFG80211=y`, so the database is requested during early init, before the root filesystem is mounted. The GNOME OS initramfs stages firmware only for the modules it carries, and its resolver for built-in modules reads `modules.builtin.modinfo` and then looks for `/usr/lib/firmware/<name>.xz`, while fdsdk's `wireless-regdb-bin` installs `regulatory.db` uncompressed. The radio then runs on the world regulatory domain: the upper 2.4 GHz channels are passive-only and 5 GHz is unusable | `module MAC80211` in `files/linux/fdsdk-config.sh` (a `=y` request silently promoted `CONFIG_CFG80211` to `=y`), held by the exact `=m` gates in `elements/core/linux-fdsdk.bst` |
| `advertising packet type` in the Bluetooth log | Patch 9002 dropped from the T2 band | `patches/linux/9002-*` |
| `systemd-analyze` reports the boot never finished | Something on the `sysinit.target` path is blocking; the failed unit names it | Depends on the unit — `systemd-analyze blame` and `systemctl --failed` |

## Expected noise on this chassis

Each line below was confirmed identical on a t2linux (Ubuntu) install running the
same MacBookPro16,2, so a boot that prints them is not regressing.

| Signature | Why it is expected |
|---|---|
| `hci_uart_bcm serial0-0: Unexpected ACPI gpio_int_idx: -1`, `Unexpected number of ACPI GPIOs: 0`, `No reset resource, using default baud rate` | Apple's DSDT gives the Bluetooth UART no GPIO or reset resources; the driver falls back to its defaults |
| `Bluetooth: hci0: BCM: firmware Patch file not found, tried: 'brcm/BCM.hcd'`, `failed to write update baudrate (-16)`, `Failed to set baudrate` | No BCM4364B3-over-UART patch file exists in linux-firmware, in fdsdk's tree, or in the macOS extraction the t2linux ecosystem ships. The controller comes up on its factory firmware, reports `BCM4364B3 Trinidad Olympic GEN (MFG)`, and pairs devices (a paired Magic Trackpad 2 in `bluetoothctl devices` is the end-to-end evidence) |
| `ieee80211 phy0: brcmf_p2p_set_firmware: failed to update device address ret -52` and the `p2p-dev-*` `add_iface` failure that follows | The firmware refuses a P2P device address. Station mode is unaffected. 7.x `brcmfmac` exposes only `alternative_fw_path`, `debug` and `roamoff`, so there is no supported knob that disables the feature |
| `intel-lpss INT34BA:00: error -ENXIO: IRQ index 0 not found` | Apple's firmware description gives the LPSS UART controller no interrupt resource for index 0; the port still registers |
| `dw-apb-uart dw-apb-uart.0: failed to request DMA` | The UART falls back to PIO and Bluetooth still initialises, but this line does **not** appear in the reference install's log. Treat it as unexplained: if a Bluetooth regression ever accompanies it, start from the DMA and LPSS support in the kernel config |
| `rtc_cmos rtc_cmos: setting system clock to 1970-01-12...`, every timestamp before the first NTP sync reading 2011-11-11 | The T2's CMOS RTC returns garbage on a cold boot, so systemd applies its clock-epoch fallback. The image ships no `/usr/lib/clock-epoch`, so the fallback is systemd's own build timestamp — 2011-11-11T11:11:11Z, the reproducible-build epoch that also dates every file in the image. `systemd-timesyncd` corrects it as soon as any network is up, including USB tethering. Nothing on this chassis can be authenticated with TLS until then |
| `bluetooth.service: ConfigurationDirectory 'bluetooth' already exists but the mode is different. (File system: 755 ConfigurationDirectoryMode: 555)` | bluez's unit declares both `StateDirectory=bluetooth` (0755) and `ConfigurationDirectory=bluetooth` (0555) for the same directory; whichever creates it first wins |
| `thunderbolt 0000:00:0d.2: can't derive routing for PCI INT A`, `device links to tunneled native ports are missing!` | Apple firmware describes the Thunderbolt host routers without the interrupt routing Linux expects |
| `systemd-journald: Creating journal file ... copy-on-write is enabled. This is likely to slow down journal access substantially` | `/var/log/journal` inherits COW from the btrfs root |
| `t2bce_audio: module is from the staging directory, the quality is unknown, you have been warned.` | The in-tree staging driver behind the T2 audio card |
| `applesmc APP0001:00: hwmon_device_register() is deprecated` | Driver-side API deprecation, harmless to fan control |
| `hid-appletb-bl ...: hid_field_extract() called with n (64) > 32!` | The Touch Bar backlight driver reads a 64-byte report field; the backlight still registers and is restored by `systemd-backlight@backlight:appletb_backlight` |

## Wi-Fi on this chassis

The acceptance access point runs WPA2/WPA3 transition mode on both bands, and the
t2linux (Ubuntu) install on the same chassis associates to it with
`key-mgmt=wpa-psk` and the default PMF setting. A Dakota association failure is
therefore not automatically a driver gap. It looks like this:

```
wlp229s0: Trying to associate with SSID '<ssid>'
wlp229s0: Associated with <bssid>
wlp229s0: Authentication with <bssid> timed out.
wlp229s0: CTRL-EVENT-SSID-TEMP-DISABLED ... reason=CONN_FAILED
NetworkManager: device (wlp229s0): Activation: (wifi) asking for new secrets
```

Association succeeds and the four-way handshake never completes. Discriminators,
in the order worth trying:

1. Re-enter the passphrase. A connection created from the live session's desktop
   menu is the common source of a one-character difference, and NetworkManager
   reports it the same way as a radio problem.
2. Run `scripts/t2-wifi-probe.sh` from the boot media. It stops NetworkManager and
   drives `wpa_supplicant` directly, then repeats with a different firmware blob
   set through `brcmfmac`'s `alternative_fw_path`. Its two exit meanings are the
   whole point: connecting with the supplicant alone puts the fault in
   NetworkManager's activation flow (this image runs NetworkManager 1.58, which
   enters WPS-PBC on every activation — the working t2linux install's 1.46 does
   not), and connecting only with the second blob set puts it in the image's
   vendored firmware.
3. Constrain the negotiation and watch the supplicant:
   `nmcli con mod <name> 802-11-wireless-security.key-mgmt wpa-psk` then
   `journalctl -fu wpa_supplicant` while reconnecting.
4. Compare against the printed `Firmware: BCM4364/4 wl0: ...` line. The image's
   vendored set and the macOS extraction a t2linux install uses are different
   builds: same file sizes, differing only in the embedded version, date and FWID
   strings (75 bytes of 820,013 in `trinidad.bin`) plus calibration data in the
   txcap blob.

Radio-level errors accompany these failures and are worth grepping for on their
own: `brcmf_cfg80211_scan: scan error (-52)` and the `p2p-dev-*` `add_iface`
failure. The P2P one appears on the working install too, but scan errors do not,
so a scan error is a stronger signal than the P2P noise.

MAC randomization is not a factor: NetworkManager resets the interface to its
permanent address before connecting, and the randomized addresses appear only on
the scans, marked `(scanning)`.

Two mechanics that cost test cycles, worth knowing before instrumenting again:

- **Firmware can be overridden, but only from inside the search path.**
  `alternative_fw_path` must not be absolute: `request_firmware()` always joins the
  requested name onto its own search path, so `/sysroot/...` becomes
  `/lib/firmware//sysroot/...` and the load fails with `-2` (ENOENT) for a file that
  is plainly present. `/lib/firmware/updates/` is searched *before*
  `/lib/firmware/`, so a bind mount there overrides the image's blobs and reverts on
  reboot:

      sudo mkdir -p /lib/firmware/updates/brcm
      sudo mount --bind "$ALT_BLOBS" /lib/firmware/updates/brcm
      sudo modprobe -r brcmfmac_wcc brcmfmac && sudo modprobe brcmfmac
      journalctl -k -b | grep "Firmware: BCM" | tail -1

  Stage both the board-specific and the board-less names, and confirm the revision
  in that last line before testing anything: if it does not change, the override did
  not take effect. A `modprobe.d` option does not apply at boot on this image — the
  module loads before the deployment's `/etc` is visible — while a module parameter
  on the kernel command line does. Reload only when the path resolves: with valid
  firmware the radio re-probes, and with a broken one the driver dies
  (`brcmf_pcie_setup: Dongle setup failed`, then `brcmf_fw_crashed`) and the
  interface never returns.
- **The connection's secret is agent-owned.** A root shell has no
  NetworkManager agent, so `nmcli con up <name>` fails with "Secrets were
  required, but not provided" even with a `passwd-file`; the desktop session
  supplies the same secret silently. For a root-side test either drive
  `wpa_supplicant` directly (it takes the passphrase from the keyfile) or clear
  the flag first with `nmcli con mod <name> 802-11-wireless-security.psk-flags 0`.
