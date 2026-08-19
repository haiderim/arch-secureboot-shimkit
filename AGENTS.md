# AGENTS.md

Guidance for agents working on this repo. Read this before editing `pre_install.sh` or `post_install.sh`.

## What this repo does

Automates an Arch Linux install with Secure Boot via shim + MOK (for machines where Secure Boot
cannot be disabled in firmware). `pre_install.sh` partitions/encrypts/installs from the Arch ISO;
`post_install.sh` runs inside the chroot to build shim, sign the kernel/loader, and install pacman
hooks that keep signatures current across updates.

## Script conventions

- **Every user-configurable value is an env var with a sensible default**, validated up front in
  `validate_parameters()` before any destructive disk operation runs. Pattern:
  `VAR="${VAR:-default}"` at the top, a fail-fast check in `validate_parameters()`. Follow this for
  any new configurable value — never hardcode something a different machine/user would need to
  change (see `DISK`, `HOSTNAME`, `NEWUSER`, `TIMEZONE`, `LOCALE`, `MIRROR_COUNTRIES`).
- **Never guess device/partition naming schemes.** `EFI_PART`/`CRYPT_PART` are derived from live
  `lsblk` output after partitioning (`pre_install.sh` around the `DISK_PARTS` array), not by
  string-concatenating a suffix. This is what makes the scripts work unmodified across SATA, NVMe,
  and MMC disks. Do not reintroduce suffix-guessing.
- **Never guess CPU vendor from a static default.** The `linux` initrd microcode line is derived
  from whichever ucode image `mkinitcpio` actually staged on the ESP (`UCODE_INITRD` in the chroot
  block), not from a hardcoded `intel-ucode`. Same "trust live state, don't guess" principle.
- Both scripts are `set -euo pipefail`; keep new code compatible with that (no unchecked non-zero
  exits you don't intend to be fatal — guard with `|| true` deliberately, not accidentally).

## Testing changes: use a real VM, not a container

Containers (Docker/Podman, even `--privileged`, even rootful) **cannot** test this repo properly:
no loop devices without real root (rootless podman can't attach host loop devices even privileged),
no real UEFI firmware/NVRAM, no Secure Boot state. Use QEMU/KVM instead — see if `/dev/kvm` is
group-accessible (`stat -c '%U %G %a' /dev/kvm`) before assuming you need sudo.

Minimum real end-to-end test loop (see chat history / commit log for a worked example):

1. **Firmware**: copy `/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd` (read-only pflash) and
   `OVMF_VARS.4m.fd` (writable pflash) — `edk2-ovmf` package, no install needed if already present.
2. **Disk**: `qemu-img create -f qcow2 nvme-disk.qcow2 40G`, attach via
   `-device nvme,drive=...` to exercise the NVMe-naming path specifically (the case that used to be
   broken).
3. **Display**: use `-display none` + QMP `screendump` (PPM→PNG via ffmpeg) to inspect guest
   framebuffer state. Do **not** rely on `-display gtk` + host screenshot tools — Wayland portal
   capture permission is commonly unavailable in sandboxed/headless sessions
   (`desktop.capabilities().capture === false`), and QMP screendump reads the guest framebuffer
   directly regardless of host display permissions.
4. **Control**: QMP unix socket (`-qmp unix:...,server,nowait`) for `send-key`/`screendump`;
   SSH via `-netdev user,...,hostfwd=tcp::2222-:22` once you've set a root password and started
   sshd from the console (archiso auto-logs root on tty1, no password, but sshd isn't running by
   default and the *installed* system doesn't have openssh at all — console-only after first boot).
5. **Repo access in-guest**: `-fsdev local,...,security_model=mapped-xattr` +
   `-device virtio-9p-pci,fsdev=...,mount_tag=repo`, then
   `mount -t 9p -o trans=virtio,version=9p2000.L repo /root/repo` in the guest. Exec bits can be
   lost when copying out of the 9p mount into the target chroot — `chmod +x` after copying.
- **`cryptsetup luksFormat` needs a real pty**, not piped stdin — it reads its confirmation and
  passphrase prompts from the controlling terminal, not raw stdin (`ssh -tt`, or a
  `pty`+`select`-based expect loop). It also prompts **twice**: once during `luksFormat` (confirm +
  passphrase + verify) and once more during the immediately following `cryptsetup open` (passphrase
  again) — four total reads, not three.
- **Secure Boot enforcement**: default `OVMF_VARS.4m.fd` ships in Setup Mode (no PK enrolled,
  `SecureBoot` efivar = 0) — booting against it proves nothing about signature verification. Use
  `virt-firmware`'s `virt-fw-vars` (`pip install virt-firmware` in a venv if not installed; no root
  needed) with `--enroll-microsoft` to get a realistic enrolled PK/KEK/db, and
  `--add-mok <guid> MOK.cer` to inject the repo's generated MOK cert directly into `MokList` — this
  is equivalent to completing the manual "Enroll key from disk" MokManager flow without scripting
  literal keystrokes through the text UI. Extract `MOK.cer` from the guest (plaintext on the FAT32
  ESP at `/boot/EFI/arch/keys/MOK.cer`) via `scp` before doing this offline against the vars file.
  Confirm actual enforcement from inside the booted system with `bootctl status | grep -i 'secure
  boot'` → must read `enabled (user)`, not merely "the VM booted".
- **DNS in the chroot**: `pacstrap`'d systems ship an empty `/etc/resolv.conf`. Before running
  `post_install.sh` in the chroot (it needs network for the AUR `shim-signed` build), copy the live
  ISO's resolver: `cp /etc/resolv.conf /mnt/etc/resolv.conf` (network namespace is shared with
  `arch-chroot`, so the live environment's `systemd-resolved` stub at `127.0.0.53` is reachable from
  inside the chroot too).
- Verify hook behavior with **real pacman transactions**, not by hand-invoking the sbin scripts:
  `pacman -S --noconfirm linux` fires `95-secureboot-sign.hook`; `pacman -S --noconfirm systemd`
  fires `96-secureboot-sync-loader.hook`. Confirm re-signing actually happened (not a no-op) by
  hashing the target file before/after, not just checking the hook's own success log line.

## Known gap (not yet fixed)

The installed system enables `systemd-networkd`/`systemd-resolved`/`iwd` but `pre_install.sh` never
writes a `.network` file, so wired ethernet does not get a DHCP lease after first boot without the
user creating `/etc/systemd/network/*.network` manually. Discovered during VM testing; out of scope
for the hardware-portability work that prompted this file — flagging for whoever picks it up next.
