# T2 recovery and the first flash

Dakota's T2 enablement replaces the kernel, the initramfs and the boot path on a
machine whose root filesystem is LUKS-encrypted. This document is the recovery
procedure for the first flash onto a T2 Mac, and the checklist that has to be
walked *before* that flash. It is a live gate, not a record of a past run.

## Why a T2 Mac needs a recovery procedure at all

The internal keyboard and trackpad are not native devices. The T2 security chip
bridges them, and they reach the CPU as USB devices behind the T2's virtual HCI.
The Linux driver for that bridge is `t2bce`, which is **not upstream** — see the
[t2linux state table](https://wiki.t2linux.org/state/), where the keyboard is
listed as working but with no upstream driver. Two consequences follow.

- **GRUB cannot drive the internal keyboard.** GRUB is a UEFI application; it has
  no `t2bce` and sees only what Apple's firmware exposes. Whether Apple's
  firmware provides a text-input path for the internal keyboard at the GRUB menu
  cannot be determined from a running system. Assume it does not, and have a USB
  keyboard available.
- **The initramfs decides whether the LUKS prompt can be answered.** If the T2
  bridge drivers are missing from the initramfs, the kernel boots, the prompt
  appears, and no passphrase can be typed. From the user's seat that is
  indistinguishable from a dead machine — and it is exactly the failure this
  procedure exists to survive.

The path that does *not* depend on any Linux driver is the **Apple Startup
Manager**, which the T2 firmware runs itself. It is the last line of defence, and
it must be confirmed working *before* the flash rather than after.

## Pre-flash checklist

Walk this on the machine while it is still running its current, known-good
deployment.

- [ ] **Confirm you can reach a boot menu at all.** Reboot, hold `Option` (⌥) at
      the chime, and confirm the Startup Manager appears and that the keyboard can
      move the selection. If it cannot, stop: attach a USB keyboard and repeat
      before going any further.
- [ ] **Confirm the external-boot fallback.** From the Startup Manager, check that
      a bootable USB device is offered. macOS is wiped on this machine, so macOS
      Recovery is not an escape hatch; a Linux USB installer reached through the
      Startup Manager is the outermost fallback.
- [ ] **Confirm the rollback target is present and pin it** so a later deployment
      cannot evict it:
      ```
      rpm-ostree status
      sudo ostree admin pin rollback
      ```
      There is no `rpm-ostree pin`; the pinning command is `ostree admin pin`,
      which takes an index or the words `booted`, `pending`, `rollback`.
- [ ] **Confirm `bootc rollback` exists on this image:**
      ```
      bootc rollback --help
      ```
- [ ] **Confirm nothing will silently undo the rollback.** Automatic update agents
      are the documented way a rollback gets reverted:
      ```
      systemctl is-enabled bootc-fetch-apply-updates.timer rpm-ostreed-automatic.timer
      systemctl is-active  bootc-fetch-apply-updates.timer rpm-ostreed-automatic.timer
      ```
- [ ] **Confirm `/boot` can hold two kernel sets.** A new deployment adds a kernel
      and an initramfs beside the current ones. If `/boot` cannot hold both,
      ostree prunes the older boot directory and the rollback target loses its
      kernel. Check `df -h /boot` before flashing.
- [ ] **Record the known-good state** so you can tell afterwards whether you are
      actually back on it.

## Known-good state

Captured with `rpm-ostree status` and `rpm-ostree status --json` on the deployment
this checklist was prepared against. These values describe *that* deployment;
re-capture if the machine has been updated since, and re-capture after a
successful flash so the next target is recorded the same way.

| Field | Booted (current) | Other deployment (rollback target) |
|---|---|---|
| Deployment index | 0 | 1 |
| Checksum | `5398fbcb3ffe462cf9bce8bc6a7120f54fff8b6f9cc7c39658b8f55b8b2f20bd` | `fe49898cd1070486c46f4bf4fab819dec5049e31b6d573bcbc1021cf6af18317` |
| Base checksum | `fe49898cd1070486c46f4bf4fab819dec5049e31b6d573bcbc1021cf6af18317` | — |
| Version | `latest.20260925` | `latest.20260925` |
| Layered packages | `brave-origin-beta` | none |
| Pinned | no | no |
| Origin | `ostree-image-signed:docker://ghcr.io/kansei-os/t2-atomic-bluefin-dx:latest` | same |
| Container digest | `sha256:e99b66549c792cc425be1c2f4cb59113bd04a83d3f900aa0f726e93b623cfd1a` | same |

### The limitation this table exposes

Both deployments are the same version *and* the same container digest; the only
difference is the `brave-origin-beta` layer on the booted one. Both boot entries
also resolve to the **same** kernel and initramfs:
`/boot/ostree/default-056b4ca79f2ad586ebeabddd612c0fd75bf56489361454bcfbd9c28967965f61/vmlinuz-7.2.6-300.t2.fc44.x86_64`.

A rollback performed *today* therefore proves the mechanism works but returns to
an effectively identical image, including an identical kernel. It does not
rehearse the failure this procedure exists for. The rehearsal only becomes real
once the T2 image has been flashed and the new deployment carries its own kernel.

## Recovery paths

In the order to reach for them.

### 1. `bootc rollback` — only if the system boots

```
sudo bootc rollback          # reorders the bootloader entries
sudo bootc rollback --apply  # ...and reboots into it
```

This reorders existing bootloader entries, so it needs a booted system. Changes
made under `/etc` do not carry across a rollback; `/etc` reverts to that
deployment's state.

**If the new kernel never reaches the LUKS prompt, `bootc rollback` is
unreachable by definition**, and path 2 or 3 is what matters. `bootc rollback`
covers the case where the image boots but is broken. `rpm-ostree rollback` is the
equivalent on the current deployment.

### 2. The GRUB menu

The bootloader is **GRUB 2.12**, installed via the Fedora shim and managed by
`bootupd`. Both deployments are presented as separate, individually selectable
type-1 entries in `/boot/loader/entries/`:

| Entry | Title | `version` | Boot index |
|---|---|---|---|
| `ostree-1.conf` | `Bluefin (Version: 44.20260922) (ostree:1)` | 1 | `/ostree/boot.0/default/056b4ca…/1` |
| `ostree-2.conf` | `Bluefin (Version: 44.20260922) (ostree:0)` | 2 | `/ostree/boot.0/default/056b4ca…/0` |

Which entry wins when nothing is chosen is decided by GRUB's BLS ordering.
Select the entry explicitly rather than trusting the default.

Fedora's GRUB hides the menu after a successful boot; hold `Esc` (or `Shift`)
during boot to reveal it. After a *failed* boot the menu appears on its own. This
is the path that works when Linux cannot start — but it is also the path whose
keyboard support is unverified. Have the USB keyboard plugged in.

### 3. Apple Startup Manager — the firmware-level fallback

Power on and hold `Option` (⌥) until the startup manager appears, then select the
volume and boot it ([t2linux Startup Manager guide](https://wiki.t2linux.org/guides/startup-manager/)).

This runs in Apple's firmware, above any Linux driver stack, so it survives a
kernel that cannot bring up the T2 bridge. It is why a bad image stays
recoverable even in the worst case.

### 4. Pinning, so the target keeps existing

An unpinned deployment can be evicted by a later deployment or by garbage
collection, which is how a rollback target quietly stops existing.

```
ostree admin pin rollback
ostree admin pin --unpin rollback
```

## Why a bad flash is not a brick

The flash replaces the Linux deployment on the internal SSD. It does not write
the T2's own firmware, the Apple firmware or the Secure Enclave, and Secure Boot
is disabled on this machine. A kernel that does not boot, an initramfs with no
keyboard driver, and a corrupt deployment are all recoverable through the paths
above, up to and including a Linux USB installer reached via the Startup Manager.

The one thing that would be a brick-class event — a bad flash of the T2
controller firmware itself — is not part of this procedure. Nothing here touches it.

Prove it rather than assume it: the first two checklist items exist to confirm
the Startup Manager and the external-boot option actually work.

## Verification boundary

Hardware observation is not interchangeable with an image-content check. An
unverified item below is an open risk, not a pass.

| Claim | Status |
|---|---|
| Two deployments exist and neither is pinned | verified: `rpm-ostree status --json` |
| Both boot entries exist and are individually selectable | verified: `/boot/loader/entries/` |
| Kernel and initramfs for both boot indexes are on disk | verified: `/boot/ostree/` |
| `bootc rollback` exists in the deployed image | verified: `bootc rollback --help`, bootc 1.16.7 |
| `bootc rollback` exists in the image being flashed | verified: `Rollback(RollbackOpts)` in `crates/lib/src/cli.rs` at bootc `v1.16.14`, the ref pinned by `elements/gnomeos-deps/bootc.bst` |
| No automatic update agent will revert a rollback | verified: both timers disabled and inactive |
| `/boot` has room for a second kernel set | verified: 2.0 G total, 1.6 G free, 256 M per set |
| The internal keyboard works at the GRUB menu | **unverified** — not observable without rebooting; assume it does not, and carry a USB keyboard |
| The internal keyboard works at the Apple Startup Manager | **unverified** — human confirms before flashing (checklist item 1) |
| The previous deployment still boots after the flash | **human-only** — not observable by the agent that produced the image |
| The new image's initramfs carries the T2 bridge drivers | **human-only at the LUKS prompt** — the check this whole procedure protects |

Do not record a hardware check as satisfied because a file is present in an image.
