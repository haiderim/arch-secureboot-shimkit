# AGENTS.md

Guidance for agents working on this repo. Read this before editing `pre_install.sh` or `post_install.sh`.

## What this repo does

Automates an Arch Linux install with Secure Boot via shim + MOK (for machines where Secure Boot
cannot be disabled in firmware). `pre_install.sh` partitions/encrypts/installs from the Arch ISO;
`post_install.sh` runs inside the chroot to build shim, sign the kernel/loader, and install pacman
hooks that keep signatures current across updates.

## Script conventions

- **Every user-configurable value is an env var with a sensible default**, validated up front in
  `validate_parameters()` before any destructive disk operation runs:
  `VAR="${VAR:-default}"` at the top, a fail-fast check in `validate_parameters()`. Never hardcode
  something a different machine/user would need to change (see `DISK`, `HOSTNAME`, `NEWUSER`,
  `TIMEZONE`, `LOCALE`, `MIRROR_COUNTRIES`).
- **Never guess device/partition naming or CPU vendor from a static default — derive from live
  state.** `EFI_PART`/`CRYPT_PART` come from `lsblk` output after partitioning, not a
  string-concatenated suffix (works unmodified across SATA/NVMe/MMC). The initrd microcode line
  references whichever ucode image `mkinitcpio` actually staged on the ESP, not a hardcoded
  `intel-ucode`. Don't reintroduce guessing in either place.
- **Network stack is NetworkManager + wpa_supplicant.** Enabled in `pre_install.sh`'s chroot phase
  (`systemctl enable NetworkManager systemd-resolved`); `wpa_supplicant` is dbus-activated by
  NetworkManager on demand, never enabled as its own unit. Do not reintroduce `iwd` or
  `systemd-networkd` — two network managers on the same interfaces fight over DHCP/link state.
- Both scripts are `set -euo pipefail`. Guard intentional non-fatal failures with `|| true`
  explicitly; don't let one slip in by accident.

## Testing changes: use a real VM, not a container

Containers (Docker/Podman, even `--privileged`, even rootful) **cannot** test this repo: no loop
devices without real root (rootless podman can't attach host loop devices even privileged), no real
UEFI firmware/NVRAM, no Secure Boot state. Use QEMU/KVM — check `/dev/kvm` group access
(`stat -c '%U %G %a' /dev/kvm`) before assuming you need sudo.

**Setup:**

1. **Firmware**: copy `/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd` (read-only pflash) and
   `OVMF_VARS.4m.fd` (writable pflash) from the `edk2-ovmf` package.
2. **Disk**: `qemu-img create -f qcow2 nvme-disk.qcow2 40G`, attach via `-device nvme,drive=...` to
   exercise the NVMe-naming path specifically.
3. **Display**: `-display none` + QMP `screendump` (PPM→PNG via ffmpeg) to inspect the guest
   framebuffer. Don't rely on `-display gtk` + host screenshot tools — Wayland portal capture
   permission is commonly unavailable in sandboxed/headless sessions; QMP screendump reads the
   guest framebuffer directly regardless of host display permissions.
4. **Control**: QMP unix socket (`-qmp unix:...,server,nowait`) for `send-key`/`screendump`; SSH via
   `-netdev user,...,hostfwd=tcp::2222-:22` once you've set a root password and started sshd from
   the console (archiso auto-logs root on tty1, no password, but sshd isn't running by default and
   the *installed* system has no openssh at all — console-only after first boot).
5. **Repo access in-guest**: `-fsdev local,...,security_model=mapped-xattr` +
   `-device virtio-9p-pci,fsdev=...,mount_tag=repo`, then in the guest
   `mount -t 9p -o trans=virtio,version=9p2000.L repo /root/repo`. Exec bits can be lost copying out
   of the 9p mount — `chmod +x` after copying into the target chroot.

**Gotchas:**

- `cryptsetup luksFormat` needs a real pty, not piped stdin — it reads its confirmation and
  passphrase prompts from the controlling terminal (`ssh -tt`, or a `pty`+`select` expect loop). It
  prompts **four** times total: confirm + passphrase + verify during `luksFormat`, then passphrase
  again during the immediately following `cryptsetup open`.
- Default `OVMF_VARS.4m.fd` ships in Setup Mode (no PK enrolled, Secure Boot effectively off) —
  booting against it proves nothing about signature verification. Use `virt-firmware`'s
  `virt-fw-vars` (`pip install virt-firmware` in a venv; no root needed) with `--enroll-microsoft`
  for a realistic enrolled PK/KEK/db, and `--add-mok <guid> MOK.cer` to inject the repo's generated
  MOK cert directly into `MokList` (equivalent to completing manual MokManager enrollment). Extract
  `MOK.cer` from the guest first — it's plaintext on the FAT32 ESP at
  `/boot/EFI/arch/keys/MOK.cer`. Confirm enforcement from inside the booted system:
  `bootctl status | grep -i 'secure boot'` must read `enabled (user)`, not merely "the VM booted".
- `pacstrap`'d systems ship an empty `/etc/resolv.conf`. Before running `post_install.sh` in the
  chroot (needs network for the AUR `shim-signed` build), copy the live ISO's resolver:
  `cp /etc/resolv.conf /mnt/etc/resolv.conf` — the network namespace is shared with `arch-chroot`,
  so the live environment's resolver stub is reachable from inside the chroot too.
- Verify pacman-hook behavior with **real transactions**, not by hand-invoking the sbin scripts:
  `pacman -S --noconfirm linux` fires `95-secureboot-sign.hook`; `pacman -S --noconfirm systemd`
  fires `96-secureboot-sync-loader.hook`. Confirm re-signing actually happened by hashing the target
  file before/after, not just by reading the hook's own success log line.
- "Service enabled" is not "service configured." `systemctl is-enabled` passing doesn't mean a
  service did anything — verify actual state (`ip a`, on-disk config) after any
  network/service-provisioning change, not just that the unit is enabled.
