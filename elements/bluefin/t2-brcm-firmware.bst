# Broadcom Wi-Fi/Bluetooth firmware for the Apple T2 radio in the
# MacBookPro16,2 (BCM4364B3 Wi-Fi + BCM4377b3 Bluetooth).
#
# WHY THIS ELEMENT EXISTS
#
# Both radios are FullMAC: the kernel driver uploads a firmware blob from
# /usr/lib/firmware/brcm at probe time, and without it there is no wlan
# interface at all. This chassis has no wired NIC, so an absent Wi-Fi blob is
# the difference between a usable machine and an offline one. Nothing upstream
# provides these files, so they are vendored here as build-time image content.
#
# PROVENANCE
#
#   Source repo:  https://github.com/kansei-os/t2-atomic
#   Commit:       ed2e7f9580485d8b821399d8814eac2bdfb4aa6c
#   Path:         build_files/common/radio.tar
#   ref:          sha256 9d09b3682008700a65d22852cff755db3f2260f4c6281a34e3e5b1af7521ee17
#   Contents:     163 flat entries, no directory prefix
#
# The pinned commit is a commit, not a branch, and the sha256 in `ref` is
# verified by BuildStream on every download, so the vendored bytes are fixed.
#
# NO UPSTREAM ORIGIN EXISTS. These blobs are not in linux-firmware: kernel.org's
# brcm/ tree has brcmfmac4354 and brcmfmac4356 adjacent with no 4355, and its
# WHENCE file has ZERO entries for "apple,", "ekans", "formosa" or "4364".
# Fedora's brcmfmac-firmware package ships 144 paths and ZERO "apple,"-suffixed
# files. There is therefore no upstream licence record, no WHENCE entry, and no
# redistributable licence for these bytes to point at. t2-atomic is itself an
# explicitly not-ready-for-public-consumption personal image.
#
# LICENCE POSTURE: these are Apple's proprietary radio blobs, taken from a
# publicly reachable repository, for a personal single-user build on hardware
# the owner physically possesses. That posture is accepted ONLY for this build.
# It is not a redistribution licence and it MUST be re-examined before this
# element is published in any public image, at which point the correct route is
# extraction from the machine's own macOS partition (impossible here: macOS has
# been wiped) or a platform-firmware mechanism outside the image.
#
# THE FILE LIST IS A PROBE RESULT, NOT radio.tar
#
# radio.tar carries 163 files because it is a multi-Mac bundle: 98.4% of it
# belongs to other Mac models. The seven files installed below are what this
# machine's silicon and firmware loader actually resolve to.
#
# 1. Wi-Fi chip and revision, read from the running machine:
#      PCI 14e4:4464 (rev 04) -> BCM4364, chip revision 4.
#      dmesg: "brcmf_fw_alloc_request: using brcm/brcmfmac4364b3-pcie for chip
#      BCM4364/4".
#    brcmfmac selects the firmware name with the revision bitmask in
#    BRCMF_FW_ENTRY(); 4364B2 is mask 0x0000000F (revisions 0-3) and 4364B3 is
#    mask 0xFFFFFFF0 (revisions 4+). Revision 4 is therefore 4364B3, and the B2
#    family (ekans, kauai, lanai, maui, midway, nihau) is NOT this machine. That
#    is why the 15 "ekans" files - all of which are brcmfmac4364b2-pcie, not
#    b3 - are excluded.
#
# 2. Board ("island") name for revision B3. Apple's board type is the ACPI _DSM
#    island name, which is why brcmfmac.ko carries the format string "apple,%s"
#    and no hardcoded Mac table. The B3 island table from the upstream series
#    ("brcmfmac: pcie: Perform correct BCM4364 firmware selection",
#    https://lkml.iu.edu/hypermail/linux/kernel/2112.3/00686.html) is:
#      bali     MacBook Pro 16" (2019)
#      borneo   MacBook Pro 16" (2019, 5600M)
#      trinidad MacBook Pro 13" (2020, 4 TB3)   <- DMI product_name
#      kahana   Mac Pro (2019) / (2019, Rack)      MacBookPro16,2
#      hanauma  iMac 27" (5K, 2020)
#      kure     iMac 27" (5K, 2020, 5700/XT)
#    /sys/class/dmi/id/product_name is MacBookPro16,2, which is the 13-inch
#    MacBook Pro (2020, four Thunderbolt 3 ports): island "trinidad". The
#    radio.tar B3 file set contains exactly those island names (plus "sid" for a
#    later Mac), which is the cross-check that the naming matches.
#
# 3. Which of the island's files the loader requests. dmesg confirms the TxCap
#    path is live ("brcmf_c_process_txcap_blob: TxCap blob found, loading") and
#    that a board-specific binary was loaded, since no generic
#    brcmfmac4364b3-pcie.bin exists for it to fall back to. The NVRAM is
#    requested under both module-vendor variants and both therefore ship: the
#    vendor comes from chip OTP, which cannot be read without a destructive
#    module reload on a working machine.
#
# Deliberately NOT installed, with the reason:
#   * every brcmfmac4364b2-pcie.* file (71) - wrong chip revision, see (1);
#   * brcmfmac4364b3-pcie.apple,{bali,borneo,hanauma,kahana,kure,sid}.* (30) -
#     other Macs' islands, see (2). With radio.tar pinned by sha256 these can
#     only go stale by editing this list, and the whole island set is one
#     commit away if the inference in (2) is ever contradicted;
#   * brcmfmac4377b3-pcie.apple,{fiji,formosa,tahiti}.* (15) - BCM4377b3 as a
#     Wi-Fi chip. This machine's Wi-Fi is BCM4364 (PCI 14e4:4464); there is no
#     second Broadcom network controller on the bus.
#
# BLUETOOTH - read this before treating the radio as covered
#
# The two brcmbt4377b3-apple,formosa files are the BCM4377b3 Bluetooth firmware
# named by this milestone, and they are the only BCM4377b3 Bluetooth payload in
# radio.tar. Their only in-kernel consumer is hci_bcm4377, whose modaliases are
# PCI 14e4:5f69/5f71/5f72/5fa0 - NONE of which this machine has. On
# MacBookPro16,2 the Bluetooth controller arrives over the T2's Apple UART
# (ACPI BCM2E7C, DRIVER=hci_uart_bcm), and that path requests brcm/BCM.hcd,
# which is in neither radio.tar nor Fedora's brcmfmac-firmware, and which the
# reference image does not have either. Shipping the formosa pair therefore
# records complete provenance for the chip the milestone names; it does NOT by
# itself make Bluetooth work, and Bluetooth stays an open item and a best-effort
# check rather than something this element can claim to have fixed.
kind: manual
description: |
  Apple T2 Broadcom radio firmware (BCM4364B3 Wi-Fi, BCM4377b3 Bluetooth) for
  the MacBookPro16,2, probe-derived from kansei-os/t2-atomic radio.tar.

sources:
  # The commit-pinned raw URL is immutable and `ref` is the sha256 of the
  # 12185600-byte radio.tar, so this is content-addressed, not branch-tracked.
  # Spelled through the project's github-raw alias rather than a literal
  # https://raw.githubusercontent.com/ prefix so the mirror can move without a
  # rebuild; the pinned commit is the path component after the alias.
  - kind: tar
    url: github-raw:kansei-os/t2-atomic/ed2e7f9580485d8b821399d8814eac2bdfb4aa6c/build_files/common/radio.tar
    ref: 9d09b3682008700a65d22852cff755db3f2260f4c6281a34e3e5b1af7521ee17
    # radio.tar is flat - 163 files, no top-level directory - so the tar
    # source's default base-dir of '*' matches every entry and fails. An empty
    # base-dir extracts the archive root, which is what the install list below
    # expects.
    base-dir: ""

build-depends:
  - core/sandbox-tools.bst
  - freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  strip-binaries: ""

config:
  install-commands:
    - |
      # /usr/lib/firmware is the loader's first search path and is in no
      # split-rule domain in this project, so these files survive the compose
      # filter with no split-rule work. Each install is unguarded on purpose:
      # if radio.tar ever stops carrying one of these names the build fails
      # instead of quietly shipping a radio with no firmware.
      fwdir="%{install-root}/usr/lib/firmware/brcm"
      install -d "$fwdir"
      for f in \
          'brcmfmac4364b3-pcie.apple,trinidad.bin' \
          'brcmfmac4364b3-pcie.apple,trinidad.clm_blob' \
          'brcmfmac4364b3-pcie.apple,trinidad.txcap_blob' \
          'brcmfmac4364b3-pcie.apple,trinidad-HRPN-m.txt' \
          'brcmfmac4364b3-pcie.apple,trinidad-HRPN-u.txt' \
          'brcmbt4377b3-apple,formosa.bin' \
          'brcmbt4377b3-apple,formosa.ptb'
      do
          install -Dm644 "$f" "$fwdir/$f"
      done
    - "%{install-extra}"
