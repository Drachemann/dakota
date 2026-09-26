# Shared Dakota kernel capabilities, applied after fdsdk-config.sh (and the
# OGC fragments on gaming builds). Keep this file shared with next: kernel
# versions and vendored upstream configuration remain stream-specific.
# Uses config-utils.sh enable/module so every option lands in
# expected-configs and the post-olddefconfig gate verifies it survived.

# Libvirt's nftables backend uses HTB + u32 + csum for DHCP checksum repair,
# even without configured bandwidth limits. The remaining options support
# libvirt's inbound/outbound bandwidth controls. No queue defaults change.
# https://github.com/libvirt/libvirt/blob/v12.7.0/src/network/network_nftables.c
# https://github.com/libvirt/libvirt/blob/v12.7.0/src/util/virnetdevbandwidth.c
# Request the parent menus explicitly rather than relying on arch defconfig.
enable NET_SCHED
enable NET_CLS_ACT
module NET_SCH_HTB
module NET_CLS_U32
module NET_ACT_CSUM
module NET_SCH_SFQ
module NET_CLS_FW
module NET_SCH_INGRESS
module NET_ACT_POLICE

# Make existing libvirt/Podman direct-LAN modes available; do not create
# interfaces or change the default networking mode.
module MACVLAN
module MACVTAP

# UAS-capable USB disks can use queued I/O instead of bulk-only transport.
module USB_UAS

# Allow cgroup disk-rate limits without imposing any limits by default.
enable BLK_DEV_THROTTLING

# The OGC fragment requests the timer trigger, but olddefconfig drops it
# unless IIO_SW_TRIGGER is enabled. Register both as expected capabilities
# on both kernels; these modules do not create or activate a sensor trigger.
module IIO_SW_TRIGGER
module IIO_HRTIMER_TRIGGER

# IPU7 lives in drivers/staging/media; these open the menu (they build
# nothing by themselves, staging drivers still need explicit enables).
enable STAGING
enable STAGING_MEDIA

# The power/GPIO half of the Intel IPU camera stack (audit found IPU6 shipped
# without it, so laptop MIPI webcams could not probe). Lives outside the
# audit's bucket regexes, hence listed here explicitly.
module INTEL_SKL_INT3472

enable ATH10K_DEBUGFS
module ATH10K_SDIO
enable FUSION
module FUSION_CTL
enable FUSION_LOGGING
# FUSION_MAX_SGE=128 skipped: int tunable already at upstream default
module FUSION_SAS
module FUSION_SPI
module HID_APPLE
enable HID_BPF
module HID_CHICONY
module HID_GOODIX_SPI
enable HID_HAPTIC
module HID_ITE
module HID_MICROSOFT
module HID_RAZER
module HID_SENSOR_PROX
module HYPERV_VSOCKETS
module MEGARAID_MAILBOX
module MEGARAID_MM
enable MEGARAID_NEWGEN
module MEGARAID_SAS
module MT7663S
module PATA_ACPI
module PATA_ALI
module PATA_ARTOP
module PATA_ATIIXP
module PATA_ATP867X
module PATA_CMD64X
module PATA_HPT366
module PATA_HPT37X
module PATA_HPT3X2N
module PATA_HPT3X3
module PATA_IT8213
module PATA_IT821X
module PATA_JMICRON
module PATA_MARVELL
module PATA_NETCELL
module PATA_NINJA32
module PATA_PCMCIA
module PATA_PDC2027X
module PATA_PDC_OLD
module PATA_SERVERWORKS
module PATA_SIL680
module PATA_SIS
module PATA_VIA
enable RTL8XXXU_UNTESTED
module RTW89_8852AU
module RTW89_8852CU
module SATA_AHCI_PLATFORM
module SATA_MV
module SATA_NV
module SATA_PROMISE
module SATA_SIL24
module SATA_SIL
module SATA_SIS
module SATA_ULI
module SATA_VIA
module SCSI_3W_9XXX
module SCSI_3W_SAS
module SCSI_AACRAID
module SCSI_AIC79XX
module SCSI_AIC7XXX
module SCSI_AM53C974
module SCSI_ARCMSR
module SCSI_BUSLOGIC
module SCSI_ESAS2R
module SCSI_HPSA
module SCSI_ISCI
# SCSI_MPT2SAS_MAX_SGE=128 skipped: int tunable already at upstream default
module SCSI_MPT3SAS
# SCSI_MPT3SAS_MAX_SGE=128 skipped: int tunable already at upstream default
module SCSI_MVSAS
module SCSI_PM8001
module SCSI_SMARTPQI
module SCSI_STEX
module SENSORS_ASUS_ROG_RYUJIN
module SENSORS_GIGABYTE_WATERFORCE
module SENSORS_NZXT_KRAKEN2
module SENSORS_NZXT_KRAKEN3
module SENSORS_NZXT_SMART2
module SENSORS_SURFACE_FAN
module SENSORS_SURFACE_TEMP
module SENSORS_YOGAFAN
module SND_AMD_ASOC_ACP63
module SND_AMD_ASOC_REMBRANDT
module SND_AMD_ASOC_RENOIR
module SND_HDA_CODEC_CM9825
module SND_HDA_CODEC_SENARYTECH
enable SND_HDA_INTEL_HDMI_SILENT_STREAM
module SND_HDA_SCODEC_TAS2781_SPI
enable SND_SEQ_UMP
module SND_SEQ_UMP_CLIENT
module SND_SOC_AMD_ACP_PCI
module SND_SOC_SOF_AMD_ACP70
module SND_SOC_SOF_AMD_RENOIR
module SND_UMP
enable SND_UMP_LEGACY_RAWMIDI
enable SND_USB_AUDIO_MIDI_V2
module TOUCHSCREEN_CHIPONE_ICN8505
enable TOUCHSCREEN_DMI
module TOUCHSCREEN_ELAN
module USB_XEN_HCD
module VBOXSF_FS
module VIDEO_HI846
module VIDEO_HI847
module VIDEO_IMX208
module VIDEO_IMX319
module VIDEO_IMX355
module VIDEO_INTEL_IPU7
module VIDEO_OG01A1B
module VIDEO_OV02C10
module VIDEO_OV02E10
module VIDEO_OV08D10
module VIDEO_OV5675
module VIDEO_OV9734
module VMWARE_VMCI_VSOCKETS
module VMXNET3
enable XEN_GRANT_DMA_OPS
enable XEN_PVH
enable XEN_VIRTIO
module XEN_WDT

# ---------------------------------------------------------------------------
# Apple T2 (MacBookPro16,2) support, driven by the t2linux/linux-t2-patches
# series in patches/linux/ (reserved 1000-9999 band; see
# elements/core/linux-fdsdk.bst). Three facts shape this block:
#
#   * T2BCE_* exist only once that band applies: the series sources its Kconfig
#     inside drivers/staging's `if STAGING` block, so STAGING (enabled above)
#     is a hard prerequisite, and APFS_FS comes from the series' fs/apfs tree.
#     Those symbols are exempt from the element's absent-symbol pruning, so
#     dropping the band fails the build instead of silently shipping a kernel
#     with no T2 support.
#   * The internal keyboard, trackpad and Touch Bar sit behind the T2's virtual
#     USB controller. t2bce_core and t2bce_vhci therefore have to be in vmlinuz
#     rather than in a module the initramfs does not carry: root is LUKS
#     encrypted and there is no input device at the passphrase prompt if they
#     are =m without an allowlist entry. The element asserts both are =y;
#     everything else here is loadable.
#   * The BCM4364 Wi-Fi and BCM4377b3 Bluetooth parts need their Broadcom
#     transports. fdsdk already registers BRCMFMAC, BT_HCIBCM4377,
#     BT_HCIUART_BCM, HID_MAGICMOUSE, HID_SENSOR_ALS, SENSORS_APPLESMC,
#     APPLE_GMUX and FW_LOADER_COMPRESS_ZSTD, some of them only inside an arch
#     conditional; the whole set is restated here so a junction bump cannot
#     drop a T2 requirement unnoticed.
#
# Driver build order follows upstream's extra_config. Do not add
# CONFIG_APPLE_BCE: no such symbol exists in this series.
enable T2BCE_CORE
enable T2BCE_VHCI
module T2BCE_DMA
module T2BCE_AUDIO
module T2BCE_AVE

# Fans (t2fanrd drives fanN_manual), the gmux backlight switch, and the Touch
# Bar's display plus its keyboard backlight.
module SENSORS_APPLESMC
module APPLE_GMUX
module DRM_APPLETBDRM
module HID_APPLETB_KBD
module HID_APPLETB_BL

# Trackpad and ambient light sensor; the Apple HID transport (HID_APPLE) is
# already registered above.
module HID_MAGICMOUSE
module HID_SENSOR_ALS

# Read-only access to an APFS container on an external disk. macOS is wiped on
# this chassis, so nothing here mounts APFS at boot.
module APFS_FS

module BRCMFMAC
module BT_BCM
module BT_HCIBCM4377
enable BT_HCIUART_BCM

# fdsdk installs /usr/lib/firmware zstd-compressed; without the decompressor
# the T2 kernel cannot see the brcm blobs it has to load.
enable FW_LOADER_COMPRESS_ZSTD
