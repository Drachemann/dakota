# freedesktop-sdk stable kernel for non-gaming Dakota variants.
#
# This reproduces the x86_64/aarch64 recipe of the linux.bst element at
# Dakota's pinned freedesktop-sdk 26.08 ref (elements/components/linux.bst
# plus elements/include/linux.yml, with build-depends junction-prefixed).
# The vendored files/linux/ scripts and the fdsdk-owned entries in
# patches/linux/ are verbatim copies from that ref; re-sync all of them at
# every fdsdk bump. patches/linux/ additionally carries the Apple T2 series:
#   - one reserved band, 1000-9999, imported from t2linux/linux-t2-patches
#     (branch main, 9e773c88, KVER=7.2.7) and applied in lexicographic
#     filename order with fdsdk's 0001-riscv... and gcc15.patch, which keep
#     their names;
#   - numbers stay upstream's (1001 t2bce, 2008-9002 subsystems) and carry
#     upstream's internal order; every file has its own Upstream-Status,
#     Source and Exit headers for the next re-sync;
#   - 3001 comes from the series' main revision too. It is rebased onto the
#     applesmc.c that v7.2.7 shipped, and v7.2.7 and v7.2.8 carry identical
#     applesmc.c, so it applies to this tree unchanged. It previously had to be
#     held one revision back (fea007484b84) only while this element pinned
#     v7.2.6: applesmc.c changed between v7.2.6 and v7.2.7, so the main revision
#     did not apply. Re-check that if the kernel ref ever moves backwards;
#   - files/linux/dakota-config.sh drives the T2 symbols, and the Kconfig
#     entries only the band provides are exempt from the pruning pass below
#     so that losing the band fails the build instead of quietly shipping a
#     kernel with no T2 support.
#
# As of 26.08, upstream builds ATH12K, strips modules (INSTALL_MOD_STRIP=1),
# and splits vmlinux/System.map to the devel domain itself, so those former
# Dakota deltas are gone. The remaining Dakota deltas are:
#   CRYPTO_ZSTD forced =y: the zswap.compressor=zstd karg
#   (bluefin/zswap-config.bst, all variants) needs the compressor
#   built in, not =m.
#   T2BCE_CORE and T2BCE_VHCI forced =y: the internal keyboard, trackpad and
#   Touch Bar are devices on the T2's virtual USB controller, and the LUKS
#   passphrase prompt needs the keyboard from vmlinuz.
#   CFG80211 and MAC80211 demoted to =m: x86_64's defconfig builds both in, and
#   config-utils' module() leaves an already-=y symbol alone, so
#   files/linux/fdsdk-config.sh removes them before requesting the module form.
#   A built-in cfg80211 requests regulatory.db during early init, before the
#   root filesystem exists, where the GNOME OS initramfs cannot supply it. This
#   element only refuses to ship the regression again; the mechanism, the
#   boot-visible symptom and the fix belong to files/linux/fdsdk-config.sh.
#
# Exit condition: only drop this element in favor of components/linux.bst
# if upstream ships CONFIG_CRYPTO_ZSTD=y (or zswap moves off the karg),
# CFG80211 stays =m, and both are re-verified on a booted image.
kind: make
description: freedesktop-sdk stable Linux kernel (CRYPTO_ZSTD built in, Apple T2 series)

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-make.bst
- freedesktop-sdk.bst:components/bison.bst
- freedesktop-sdk.bst:components/cpio.bst
- freedesktop-sdk.bst:components/flex.bst
- freedesktop-sdk.bst:components/bc.bst
- freedesktop-sdk.bst:components/gzip.bst
- freedesktop-sdk.bst:components/pahole.bst
- freedesktop-sdk.bst:components/python3.bst
- freedesktop-sdk.bst:components/rsync.bst
- freedesktop-sdk.bst:components/rust.bst
- freedesktop-sdk.bst:components/rust-bindgen.bst
- freedesktop-sdk.bst:components/rust-src.bst
- freedesktop-sdk.bst:components/util-linux.bst
- freedesktop-sdk.bst:components/zstd.bst
- filename: freedesktop-sdk.bst:components/linux-module-cert.bst
  strict: true

variables:
  indep-libdir: '%{prefix}/lib'
  # Modules are stripped by kbuild (INSTALL_MOD_STRIP=1) *before* the
  # module signature is appended; a post-build strip pass would tear
  # the signatures off again.
  strip-binaries: ''
  kernel_arch: '%{arch}'
  src-arch: '%{kernel_arch}'
  image-name: '$(make -s image_name)'
  optimize-debug: false
  (?):
  - arch == "x86_64":
      src-arch: x86
  - arch == "aarch64":
      kernel_arch: arm64

environment:
  ARCH: '%{kernel_arch}'
  # compile.h has a hardcoded timestamp; seed it for reproducibility.
  KBUILD_BUILD_TIMESTAMP: 'Thu Nov 10 15:00:00 UTC 2011'
  KBUILD_BUILD_USER: 'tomjon'
  MAXJOBS: "%{max-jobs}"
  # arch/x86/Makefile hardcodes -march=x86-64 -mtune=generic, overriding
  # gcc's --with-arch_64 default. KCFLAGS is appended after KBUILD_CFLAGS,
  # so a later -march wins.
  (?):
  - x86_64_v3:
      KCFLAGS: "-march=x86-64-v3 -mtune=skylake"

environment-nocache:
- MAXJOBS

config:
  configure-commands:
  - |
    make defconfig

  - |
    . ./config-utils.sh
    rm -f expected-configs
    . ./fdsdk-config.sh "%{arch}"

  - |
    # Dakota deltas go through config-utils.sh enable/module so they land in
    # expected-configs and the post-olddefconfig gate verifies they survived.
    . ./config-utils.sh

    # The zswap.compressor=zstd karg needs the compressor built in, not =m.
    enable CRYPTO_ZSTD

    # Hardware-enablement deltas from the Fedora config audit (VM guests,
    # homelab HBAs, laptop camera/audio/input completion); shared with the
    # testing-stream kernels.
    . ./dakota-config.sh

  - |
    # Drop expectations for options this newer stable tree no longer offers.
    # Existing symbols whose dependencies are not met remain hard failures.
    find . -name 'Kconfig*' -exec grep -h '^\(menu\)\{0,1\}config ' {} + \
      | awk '{print $2}' | sort -u > .kconfig-symbols
    cp expected-configs expected-configs.orig
    while IFS= read -r cfg; do
      sym=${cfg#CONFIG_}
      # Symbols the T2 band introduces are exempt: if the series stops
      # providing them, the missing-config check below must fail the build
      # rather than prune the expectation away.
      case "$sym" in
        T2BCE_CORE|T2BCE_VHCI|T2BCE_DMA|T2BCE_AUDIO|T2BCE_AVE|APFS_FS) continue ;;
      esac
      if ! grep -qx "$sym" .kconfig-symbols; then
        echo "note: pruning expectation for ${cfg} (absent from this tree)" 1>&2
        sed -i "/^\(CONFIG_\)\{0,1\}${sym}$/d" expected-configs
      fi
    done < expected-configs.orig
    rm -f expected-configs.orig

  - |
    make -j1 olddefconfig

  - |
    . ./config-utils.sh

    missing_configs=0
    for config in $(cat expected-configs); do
      if ! has "${config}"; then
        echo "Missing ${config}" 1>&2
        missing_configs=1
      fi
    done
    case "%{arch}" in
      x86_64|aarch64)
        [ "${missing_configs}" = 0 ]
      ;;
    esac

    # has() accepts =m; the zswap karg requires =y.
    grep -q '^CONFIG_CRYPTO_ZSTD=y$' .config

    # has() also accepts =m, but the T2 keyboard, trackpad and Touch Bar are
    # behind the T2's virtual USB controller: as modules with no initramfs
    # allowlist entry there is no input device at the LUKS passphrase prompt,
    # so hold both bridge drivers in vmlinuz.
    grep -q '^CONFIG_T2BCE_CORE=y$' .config
    grep -q '^CONFIG_T2BCE_VHCI=y$' .config

    # has() accepts =y too, so the expectation above passes whether the symbol
    # is =m or =y. The module form is load-bearing: built in, cfg80211 asks for
    # regulatory.db before the root filesystem is mounted, which fails on every
    # boot and leaves the radio on the world regulatory domain. See the
    # CFG80211/MAC80211 bullet in this element's header.
    grep -q '^CONFIG_CFG80211=m$' .config
    grep -q '^CONFIG_MAC80211=m$' .config

  install-commands:
  - |
    release=$(make -s kernelrelease)
    install -Dm644 "%{image-name}" "%{install-root}%{indep-libdir}/modules/${release}/vmlinuz"
    install -Dm644 vmlinux "%{install-root}%{indep-libdir}/modules/${release}/vmlinux"
    install -Dm644 System.map "%{install-root}%{indep-libdir}/modules/${release}/System.map"
    install -Dm644 .config "%{install-root}%{indep-libdir}/modules/${release}/config"
    ZSTD_CLEVEL=19 make -j1 INSTALL_MOD_PATH="%{install-root}%{prefix}" INSTALL_MOD_STRIP=1 modules_install

  - |
    release=$(make -s kernelrelease)
    targetdir="%{install-root}%{prefix}/src/linux-${release}"

    rm "%{install-root}%{indep-libdir}/modules/${release}"/build

    to_copy=(
      Makefile
      Module.symvers
      .config
      "arch/%{src-arch}/include"
      "arch/%{src-arch}/Makefile"
      scripts
      include
    )
    if [ "$(scripts/config -s OBJTOOL)" = y ]; then
      to_copy+=(tools/objtool/objtool)
    fi
    for file in "${to_copy[@]}"; do
      targetfile="${targetdir}/${file}"
      dir="$(dirname "${targetfile}")"
      [ -d "${dir}" ] || install -d "${dir}"
      cp -aT "${file}" "${targetfile}"
    done

    ln -sr "${targetdir}" "%{install-root}%{indep-libdir}/modules/${release}/build"

  - |
    %{install-extra}

  (?):
  - arch == "aarch64":
      install-commands:
        (>):
        - |
          release=$(make -s kernelrelease)
          make -j1 INSTALL_DTBS_PATH="%{install-root}%{indep-libdir}/modules/${release}/dtbs" dtbs_install

public:
  bst:
    split-rules:
      devel:
        (>):
        - '%{indep-libdir}/modules/*/System.map'
        # DEBUG_INFO=y (via the shared config's DEBUG_INFO_BTF) makes
        # vmlinux ~0.5 GB; runtime consumers read /sys/kernel/btf/vmlinux,
        # not this file, so keep it out of the composed images.
        - '%{indep-libdir}/modules/*/vmlinux'
    overlap-whitelist:
    - "%{project_licensedir}"
    - "%{project_licensedir}/**"

sources:
- kind: git_repo
  url: kernel:linux/kernel/git/stable/linux.git
  # Testing tracks the 7.2 stable series; rc kernels stay on next.
  track: v7.2.*
  ref: v7.2.8-0-g9a66fdc0d7fd55f54235524a73435af99051e46f
- kind: patch_queue
  path: patches/linux
- kind: local
  path: files/linux/config-utils.sh
- kind: local
  path: files/linux/fdsdk-config.sh
- kind: local
  path: files/linux/dakota-config.sh
