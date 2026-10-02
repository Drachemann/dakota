# Historical path note: despite the directory name, this is Dakota's package
# manifest. Add or remove image content via `.bst` elements here — never via
# dnf/RPM/Containerfile overlay logic.
kind: stack

depends:
  - gnome-build-meta.bst:gnomeos-deps/deps.bst

  - bluefin/gnome-shell-extensions.bst

  # IBus Rime; users select their own input sources in GNOME.
  - bluefin/ibus-rime.bst

  - bluefin/brew.bst
  - bluefin/brew-tarball.bst

  - bluefin/tailscale.bst
  - bluefin/uupd.bst
  - bluefin/chairlift.bst


  - bluefin/ghostty.bst

  - bluefin/fastfetch.bst
  - bluefin/nerd-fonts-symbols.bst
  - bluefin/gum.bst
  - bluefin/tealdeer.bst
  - bluefin/ydotool.bst
  - bluefin/umotd.bst
  - bluefin/uwelcome.bst

  - bluefin/common.bst
  - bluefin/user-avatars.bst
  - bluefin/just-overrides.bst
  - bluefin/zswap-config.bst
  - bluefin/swapfile.bst
  - bluefin/firstboot-date.bst
  - bluefin/firstboot-services.bst
  - bluefin/flatpak-apps.bst
  - bluefin/wallpaper-month.bst
  - bluefin/bootc-install-config.bst
  - bluefin/composefs-loop-udisks-ignore.bst
  - bluefin/udev-groups.bst
  - bluefin/gnome-epub-thumbnailer.bst
  # Papers' thumbnailer and PDF backend. The full package already reaches the
  # image through gnome-build-meta's sushi, and the Papers Flatpak's desktop
  # entry takes precedence in XDG_DATA_DIRS, so users see one Papers app.
  - gnome-build-meta.bst:core/papers.bst
  - bluefin/wallpapers.bst

  - bluefin/uutils-coreutils.bst
  - bluefin/sudo-rs.bst
  - bluefin/fprintd-system-auth.bst
  - bluefin/fprintd-fingerprint-auth.bst
  - bluefin/efibootmgr.bst
  - bluefin/xdg-terminal-exec.bst
  - bluefin/nautilus-python.bst
  - bluefin/gnome-ponytail-daemon.bst
  # Restores the VTE typelibs the app-drop strips out (dakota#1022)
  - bluefin/vte.bst
  - bluefin/network.bst
  - bluefin/wireplumber-pcsp.bst
  - bluefin/alsa-utils.bst
  - bluefin/brlaser.bst
  # - bluefin/lsp-plugins-lv2.bst

  # Apple T2 (MacBookPro16,2) userspace. The kernel patch band and config
  # fragment live in patches/linux/ and files/linux/dakota-config.sh on
  # core/linux-fdsdk.bst, and the brcm firmware is a separate element.
  # Source-first for all three: t2fanrd is built from a pinned upstream commit
  # with generated Cargo sources, and the other two are pinned config/data
  # installs.
  #
  # tiny-dfr is deliberately NOT installed. The mainline hid-appletb-kbd driver
  # drives the Touch Bar in Boot Camp mode and the T2's own firmware renders
  # Escape plus the function/media keys, so no userspace daemon is required. The
  # daemon additionally holds stale device descriptors across suspend with
  # t2bce. This matches the field-proven Omarchy T2 configuration, which removed
  # tiny-dfr for exactly that reason.
  - bluefin/t2fanrd.bst
  - bluefin/t2linux-audio.bst
  - bluefin/t2linux-config.bst
  # Narrow, pinned brcm Wi-Fi/BT blob set for BCM4364b3 (trinidad) +
  # BCM4377b3 (formosa). Must stay listed here: an element that is authored but
  # unreferenced never enters the image closure and no firmware ships.
  - bluefin/t2-brcm-firmware.bst

  # Include things missing from the gnomeos base image
  - gnome-build-meta.bst:core-deps/fwupd.bst

  # system-monitor shell extension needs GTop-2.0.typelib; only reaches the image
  # transitively via gnome-control-center otherwise (projectbluefin/dakota#1163)
  - gnome-build-meta.bst:core-deps/libgtop.bst

  - bluefin/virtualization.bst

  - freedesktop-sdk.bst:components/buildstream2.bst
  - freedesktop-sdk.bst:components/containers-common.bst
  - freedesktop-sdk.bst:components/debuginfod.bst
  - freedesktop-sdk.bst:components/dmidecode.bst
  - freedesktop-sdk.bst:components/git-lfs.bst
  - freedesktop-sdk.bst:components/git.bst
  - freedesktop-sdk.bst:components/podman.bst
  - freedesktop-sdk.bst:components/skopeo.bst
  - freedesktop-sdk.bst:components/flatpak-builder.bst

  - freedesktop-sdk.bst:components/bpf-maybe.bst
  - gnome-build-meta.bst:gnomeos-deps/bpftop.bst
  - gnome-build-meta.bst:core/sysprof-app.bst

  - bluefin/distrobox.bst
  - bluefin/nspawn.bst
  - gnome-build-meta.bst:gnomeos-deps/just.bst
  - gnome-build-meta.bst:gnomeos-deps/wl-clipboard.bst

  - bluefin/bindmounts.bst
  - bluefin/migrate-var-home-passwd.bst

  - gnome-build-meta.bst:gnomeos-deps/snapd.bst

(?):
- arch == "x86_64":
    depends:
      (>):
      - bluefin/intel-media-driver.bst
