# t2linux-audio 2.2.0 (MIT) — ALSA UCM2 half only.
#
# Upstream is sharpenedblade/KaiT2en-Fedora, the same repository the Fedora
# t2linux-audio spec points %{forgeurl} at. The repository publishes no tags, so
# the pin is a bare commit: the spec's %global commit.
kind: manual

sources:
  - kind: git_repo
    url: github:sharpenedblade/KaiT2en-Fedora.git
    ref: 9527bffcd9d2293345ce89112329780e1b66b501

build-depends:
  - core/sandbox-tools.bst
  - freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

depends:
  # The AppleT2 profiles begin with
  #   Include.pcm_split.File "/common/pcm/split.conf"
  # which resolves inside the ucm2 root, so the alsa-ucm-conf tree must be
  # present. gnomeos-deps already installs it to %{datadir}/alsa/ucm2; the
  # dependency is declared so the requirement is explicit and the closure is
  # guaranteed.
  - gnome-build-meta.bst:gnomeos-deps/alsa-ucm-conf.bst

variables:
  strip-binaries: ""

# Only modules/t2bce_audio-alsa-ucm-conf/ucm2 is installed. The other half of
# t2linux-audio — modules/t2bce_audio-dsp (wireplumber.conf, the UCM rename
# rule and the per-model FIR data under firs/) — is deferred: it needs
# pipewire-module-filter-chain-lv2 plus the lsp-plugins-lv2, lv2-bankstown,
# lv2-triforce and lv2-swh-plugins LV2 elements, and lsp-plugins-lv2.bst is
# still commented out at elements/bluefin/deps.bst. t2bce_audio-dsp would
# install fine as files but would do nothing without the LV2 plugins.
#
# The card profiles land in conf.d/AppleT2x{2,4,6}/, named after the ALSA card
# id rather than the machine, so one element covers every T2 speaker count.
# alsa-ucm-conf 1.2.16.1 contains no Apple-named profiles at all, so this is
# purely additive and cannot collide with it.
#
# No compilation, so no LV2 or pipewire runtime dependency is claimed here.
config:
  install-commands:
  - install -Dm644 LICENSE "%{install-root}%{datadir}/licenses/t2linux-audio/LICENSE"
  - install -d "%{install-root}%{datadir}/alsa/ucm2"
  - cp -a modules/t2bce_audio-alsa-ucm-conf/ucm2/. "%{install-root}%{datadir}/alsa/ucm2/"
  - install -Dm644 modules/t2bce_audio-alsa-ucm-conf/README.md "%{install-root}%{datadir}/doc/t2linux-audio/README.md"
  - "%{install-extra}"
