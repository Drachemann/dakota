---
name: dakota-image
description: OCI layer assembly, boot testing, installer boundaries, VM work, and local OTA verification for Dakota images.
metadata:
  context7-sources:
    - /bootc-dev/bootc
---

# Dakota Image Integration

Use this skill when filesystem content crosses from BuildStream artifacts into OCI layers, or when testing and booting a local Dakota image.

## When to Use

- Modifying layer composition under `elements/oci/layers/`
- Changing post-install integration steps in `elements/oci/bluefin.bst`
- Running local VM boot tests (`just boot-test`, `just boot-fast`, `just boot-vm`)
- Validating transactional OTA updates or testing local registries (`references/local-ota.md`)
- Enforcing the installer boundary between Dakota and live installer tools

## When NOT to Use

- Building individual source packages or libraries → load `dakota-packaging`
- Packaging GNOME Shell extensions → load `dakota-extensions`
- Modifying GitHub Actions CI export or publication → load `dakota-ci`

## Core Process

1. **Layer Composition**: Compose layers with `kind: compose`. Build dependencies define layer contents.
2. **Order Post-Install Steps**:
   - `systemd-sysusers --root /layer`
   - `glib-compile-schemas /layer/usr/share/glib-2.0/schemas`
   - `dconf update /layer/etc/dconf/db`
   - `ldconfig -r /layer` (must run LAST before `build-oci`)
3. **Validate**: Run `just validate` to verify the composition graph.
4. **Boot Verification Ladder**:
   - Level 1: `just validate` (graph structure)
   - Level 2: `just lint` (bootc container structure)
   - Level 3: `just boot-test` (automated headless smoke test)
   - Level 4: `just boot-fast` (interactive ephemeral VM with virtiofs)
   - Level 5: Local OTA testing (`references/local-ota.md`) for hardware verification

## Invariants

- **Layer Element Kind**: All layer elements in `elements/oci/layers/` MUST use `kind: compose`. `kind: stack` produces empty artifacts and will break filesystem generation.
- **Linker Cache Load-Bearing Invariant**: `ldconfig -r /layer` must execute after all library updates and before `build-oci`. Any command altering `/usr/lib` must precede `ldconfig`.
- **Installer Separation**: Installer-specific Flatpaks or setup tools are purged on first boot via `files/firstboot/`. Installer UI changes belong in `projectbluefin/bootc-installer`, not Dakota.
- **Evidence Before Assertion**: Never assert boot success without executing one of the boot test recipes.
- **Ownership Validation Needs an Unlabelled Host**: `just export` validates the squashed root through a live `podman image mount`, and `scripts/ownership_metadata.py rebind-exported` compares `xattrs` exactly. On an SELinux-enforcing host that mount exposes `security.selinux` on files whose sidecar recorded `xattrs: {}`, so the export aborts at `os-release export change is not an allowed VERSION_ID/IMAGE_VERSION substitution`. The identical comparison fails `scripts.test_ownership_metadata.test_oci_finalization_and_immutable_image_rebinding` under `just validate`. CI runs on `ubuntu-*` runners, which carry no SELinux, so this never reproduces upstream. Permissive mode is not a remedy: SELinux labels inodes and mount accesses regardless of enforcement, which only governs denials.
- **Validation Aborts Do Not Corrupt the Image**: The export squashes and tags before it validates. A validation abort leaves `IMAGE_NAME:IMAGE_TAG` present in Podman, which is all `just generate-bootable-image` requires. Only the regenerated ownership TSV, consumed by the publishing path rather than by boot, is absent.

## Common Rationalizations

| Rationalization | Reality |
|---|---|
| "The element built, so the layer is fine." | Build success does not guarantee runtime inclusion or correct compose filters. |
| "I can put `ldconfig` anywhere in the post-install list." | If run before schema or dconf steps that copy libraries, `/etc/ld.so.cache` will be stale on boot. |
| "Booting in QEMU isn't necessary for a small change." | Desktop regression (e.g. GDM loop) only manifests at real boot. |
| "The export failed, so the image is unusable." | The image is already tagged in Podman; only the ownership TSV is missing. Boot it with `just generate-bootable-image` and complete an export later on an unlabelled host if you need to publish. |

## Red Flags

- `kind: stack` inside `elements/oci/layers/`
- New post-install commands inserted after `ldconfig -r /layer`
- Using `rpm-ostree` or `dnf` in layer integration scripts
- Modifying live installer code directly in Dakota instead of upstream repos
- Treating an ownership-validation abort on an SELinux host as image corruption, or concluding the branch is unbuildable from it

## Verification

- [ ] `just validate` passes, or every failure is proven environmental by reproducing it on a pristine tree at the base commit
- [ ] `just lint` passes on the exported container
- [ ] `just boot-test` exits 0 (GDM desktop reaches ready state)
- [ ] `/etc/ld.so.cache` contains newly introduced shared libraries
- [ ] First-boot service cleanup scripts succeed
- [ ] On an SELinux host, the ownership-validation abort is confirmed to leave `IMAGE_NAME:IMAGE_TAG` present in Podman before relying on it

## References

- [`docs/oci-assembly.md`](../../../docs/oci-assembly.md)
- [`docs/t2-recovery.md`](../../../docs/t2-recovery.md) — recovery path and pre-flash gate for T2 hardware
- [`references/local-ota.md`](references/local-ota.md)
- [`elements/oci/`](../../../elements/oci/)
- [`files/firstboot/`](../../../files/firstboot/)
