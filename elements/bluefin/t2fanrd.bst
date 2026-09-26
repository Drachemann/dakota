# T2 fan-curve daemon. The T2 SMC keeps autonomous fan control until userspace
# writes fanN_manual=1, so without this daemon the machine is thermally degraded
# (observed ~88 C at ~2600 RPM, throttled) rather than in danger — but it is a
# blocking check for the first milestone nonetheless.
#
# kind: make rather than the community `kind: cargo` element: Dakota's
# project.conf does not register the `cargo` element plugin, and every Rust
# package already in this tree (sudo-rs, uutils-coreutils, bootc) drives
# `cargo build --release` from a `kind: cargo2` generated source block under
# kind: make. Adding a plugin registration to project.conf solely for this
# element would be a wider change than the packaging needs.
kind: make

sources:
- kind: git_repo
  url: github:GnomedDev/T2FanRD.git
  # Upstream publishes no tags and no releases, so there is no `track` pattern
  # and no honest version string. This commit is the same one the t2linux
  # Fedora package pins as %global commit. Its Cargo.toml says version 0.1.0;
  # the 0.1.1 in Fedora's spec is a packaging artifact, so 0.1.1 is not
  # claimed here.
  ref: 48baf962697ec3d4d969c74cf601ee8e15b7aeaa
- kind: cargo2
  url: crates:crates
  ref:
  - kind: registry
    name: arraydeque
    version: 0.5.1
    sha: 7d902e3d592a523def97af8f317b08ce16b7ab854c1985a0c671e6f15cebc236
  - kind: registry
    name: cfg-if
    version: 1.0.0
    sha: baf1de4339761588bc0619e3cbc0120ee582ebb74b53b4efbf79117bd2da40fd
  - kind: registry
    name: const-random
    version: 0.1.17
    sha: 5aaf16c9c2c612020bcfd042e170f6e32de9b9d75adb5277cdbbd2e2c8c8299a
  - kind: registry
    name: const-random-macro
    version: 0.1.16
    sha: f9d839f2a20b0aee515dc581a6172f2321f96cab76c1a38a4c584a194955390e
  - kind: registry
    name: crunchy
    version: 0.2.2
    sha: 7a81dae078cea95a014a339291cec439d2f232ebe854a9d672b796c6afafa9b7
  - kind: registry
    name: dlv-list
    version: 0.5.2
    sha: 442039f5147480ba31067cb00ada1adae6892028e40e45fc5de7b7df6dcc1b5f
  - kind: registry
    name: getrandom
    version: 0.2.12
    sha: 190092ea657667030ac6a35e305e62fc4dd69fd98ac98631e5d3a2b1575a12b5
  - kind: registry
    name: glob
    version: 0.3.1
    sha: d2fabcfbdc87f4758337ca535fb41a6d701b65693ce38287d856d1674551ec9b
  - kind: registry
    name: hashbrown
    version: 0.14.3
    sha: 290f1a1d9242c78d09ce40a5e87e7554ee637af1351968159f4952f028f75604
  - kind: registry
    name: libc
    version: 0.2.152
    sha: 13e3bf6590cbc649f4d1a3eefc9d5d6eb746f5200ffb04e5e142700b8faa56e7
  - kind: registry
    name: nonempty
    version: 0.10.0
    sha: 303e8749c804ccd6ca3b428de7fe0d86cb86bc7606bc15291f100fd487960bb8
  - kind: registry
    name: once_cell
    version: 1.19.0
    sha: 3fdb12b2476b595f9358c5161aa467c2438859caa136dec86c26fdd2efe17b92
  - kind: registry
    name: ordered-multimap
    version: 0.7.1
    sha: a4d6a8c22fc714f0c2373e6091bf6f5e9b37b1bc0b1184874b7e0a4e303d318f
  - kind: registry
    name: proc-macro2
    version: 1.0.78
    sha: e2422ad645d89c99f8f3e6b88a9fdeca7fabeac836b1002371c4367c8f984aae
  - kind: registry
    name: quote
    version: 1.0.35
    sha: 291ec9ab5efd934aaf503a6466c5d5251535d108ee747472c3977cc5acc868ef
  - kind: registry
    name: rust-ini
    version: 0.21.0
    sha: 0d625ed57d8f49af6cfa514c42e1a71fadcff60eb0b1c517ff82fe41aa025b41
  - kind: registry
    name: signal-hook
    version: 0.3.17
    sha: 8621587d4798caf8eb44879d42e56b9a93ea5dcd315a6487c357130095b62801
  - kind: registry
    name: signal-hook-registry
    version: 1.4.1
    sha: d8229b473baa5980ac72ef434c4415e70c4b5e71b423043adb4ba059f89c99a1
  - kind: registry
    name: syn
    version: 2.0.48
    sha: 0f3531638e407dfc0814761abb7c00a5b54992b849452a0646b7f65c9f770f3f
  - kind: registry
    name: thiserror
    version: 1.0.56
    sha: d54378c645627613241d077a3a79db965db602882668f9136ac42af9ecb730ad
  - kind: registry
    name: thiserror-impl
    version: 1.0.56
    sha: fa0faa943b50f3db30a20aa7e265dbc66076993efed8463e8de414e5d06d3471
  - kind: registry
    name: tiny-keccak
    version: 2.0.2
    sha: 2c9d3793400a45f954c52e73d068316d76b6f4e36977e3fcebb13a2721e80237
  - kind: registry
    name: trim-in-place
    version: 0.1.7
    sha: 343e926fc669bc8cde4fa3129ab681c63671bae288b1f1081ceee6d9d37904fc
  - kind: registry
    name: unicode-ident
    version: 1.0.12
    sha: 3354b9ac3fae1ff6755cb6db53683adb661634f67557942dea4facebec0fee4b
  - kind: registry
    name: wasi
    version: 0.11.0+wasi-snapshot-preview1
    sha: 9c8d87e72b64a3b4db28d11ce29237c246188f4f51057d65a7eab63b7987e423
build-depends:
- freedesktop-sdk.bst:components/rust.bst
- freedesktop-sdk.bst:public-stacks/buildsystem-make.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

config:
  build-commands:
  - cargo build --release

  install-commands:
  - install -Dm755 target/release/t2fanrd "%{install-root}%{bindir}/t2fanrd"
  # Upstream ships no unit, so it is authored here. The content follows the
  # t2linux Fedora package's t2fanrd.service (Source1 in t2fanrd.spec) with two
  # corrections: ExecStart is absolute rather than relying on systemd's fixed
  # search path, and the duplicated ProtectHostname= line is collapsed to one.
  # The hardening intentionally does not set ProtectKernelTunables: fan control
  # is a sysfs write to fanN_manual, and a read-only /sys would break it.
  # Enablement comes from usr/lib/systemd/system-preset/91-t2linux.preset,
  # installed by bluefin/t2linux-config.bst.
  - |
    install -Dm644 /dev/null "%{install-root}%{indep-libdir}/systemd/system/t2fanrd.service"
    cat > "%{install-root}%{indep-libdir}/systemd/system/t2fanrd.service" <<'SERVICE'
    [Unit]
    Description=T2FanRD daemon to manage fan curves for T2 Macs

    [Service]
    Type=exec
    ExecStart=/usr/bin/t2fanrd
    Restart=always

    PrivateTmp=true
    ProtectSystem=true
    ProtectHome=true
    ProtectClock=true
    ProtectHostname=true
    ProtectControlGroups=true
    ProtectKernelLogs=true
    ProtectKernelModules=true
    ProtectProc=invisible
    PrivateDevices=true
    PrivateNetwork=true
    NoNewPrivileges=true
    DevicePolicy=closed
    KeyringMode=private
    LockPersonality=true
    MemoryDenyWriteExecute=true
    PrivateUsers=yes
    RemoveIPC=yes
    RestrictNamespaces=yes
    RestrictRealtime=yes
    RestrictSUIDSGID=yes
    SystemCallArchitectures=native

    [Install]
    WantedBy=multi-user.target
    SERVICE
  # Upstream spells the licence file LICENCE.
  - install -Dm644 LICENCE "%{install-root}%{datadir}/licenses/t2fanrd/LICENCE"
  - '%{install-extra}'
