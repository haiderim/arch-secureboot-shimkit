# AGENTS.md

Guidance for agents working on this repo. Read this before editing `pre_install.sh` or `post_install.sh`.

## What this repo does

Automates an Arch Linux install with Secure Boot via shim + MOK (for machines where Secure Boot
cannot be disabled in firmware). `pre_install.sh` partitions/encrypts/installs from the Arch ISO;
`post_install.sh` runs inside the chroot to build shim, sign the UKIs/loader, and install hooks
that keep signatures current across updates.

## Script conventions

- **Every user-configurable value is an env var with a sensible default**, validated up front in
  `validate_parameters()` before any destructive disk operation runs:
  `VAR="${VAR:-default}"` at the top, a fail-fast check in `validate_parameters()`. Never hardcode
  something a different machine/user would need to change (see `DISK`, `TARGET_HOSTNAME`, `NEWUSER`, `IMPORT_WIFI`,
  `TIMEZONE`, `LOCALE`, `MIRROR_COUNTRIES`, `MOK_DIR`, `SHIM_SIGNED_REF`). Don't name one after a
  variable bash sets itself: `HOSTNAME` never used its default. `ESP_MOUNT` must stay `/boot`, because
  presets and boot setup assume it, and validation rejects anything else.
- **Never guess device/partition naming or CPU vendor from a static default — derive from live
  state.** `EFI_PART`/`CRYPT_PART` come from `lsblk` output after partitioning, sorted explicitly by
  the `PARTN` column (actual GPT partition number) — not a string-concatenated suffix, and not
  `lsblk`'s emission order either, which is NOT guaranteed to match partition number (seen reversed
  on a disk that previously held a different partition table — silently swapped `EFI_PART`/
  `CRYPT_PART` and broke the install). Don't reintroduce guessing, or trust unsorted list order.
- **Don't leave a machine unreachable.** `sshd` is enabled by default, and `pre_install.sh` converts
  the ISO's `iwd` Wi-Fi profile into a NetworkManager keyfile, since `iwd` isn't on the installed system.
- **Network stack is NetworkManager + wpa_supplicant.** Enabled in `pre_install.sh`'s chroot phase
  (`systemctl enable NetworkManager`, which also writes `/etc/resolv.conf`); `wpa_supplicant` is
  dbus-activated by NetworkManager on demand, never enabled as its own unit. Do not reintroduce `iwd` or
  `systemd-networkd` — two network managers on the same interfaces fight over DHCP/link state.
- **Dropping a config file isn't enough — check whether the tool has a separate registry.**
  `post_install.sh` writes `/etc/snapper/configs/root` directly (Snapper has no `create-config` path
  that works against an already-mounted root subvolume), but Arch's `snapper` CLI and `snap-pac`'s
  pacman hooks only recognize configs listed in `/etc/conf.d/snapper`'s `SNAPPER_CONFIGS` — without
  that line, snapshots silently never happen despite every other artifact looking correctly set up.
  Register it there too, before `snapperd` first starts.
- **Boot through signed UKIs only.** Kernel, initramfs, microcode and cmdline all live inside
  `/boot/EFI/Linux/arch-*.efi`. Don't reintroduce loader entries or separate initrds: Secure Boot
  doesn't authenticate them. UKIs are rebuilt by more than kernel updates (firmware, `systemd`,
  manual `mkinitcpio -P`), so signing lives in the mkinitcpio post hook, not only a pacman hook.
- **`sbverify --list` exits 0 on unsigned files.** Check signatures with `sbverify --cert`. Re-running
  `sbsign` adds a signature rather than replacing one, so skip files that already verify.
- **Pacman hooks get a clean environment, and pacman exits 0 when a hook fails.** Persist settings in
  `/etc/secureboot-shimkit.conf`, exit non-zero on failure, and don't assume callers will notice.
- **An automounted ESP gives `findmnt` two sources** (`systemd-1` and the device). Filter with
  `-t vfat`. Commented-out lines can also match unanchored `grep`s when editing `fstab`.
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
   the *installed* system runs `sshd` but refuses root password login — for test runs, add a key
   to `/root/.ssh/authorized_keys` from the chroot, or log in as `NEWUSER`).
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
- The Arch ISO isn't signed, so install with the default Setup Mode vars, then enroll keys into a copy
  of those vars with `--input`. Starting from pristine vars loses the NVRAM boot entry, which is a
  useful way to test the `EFI/BOOT` fallback path: without a MOK it must reach MokManager.
- `post_install.sh` needs network in the chroot for the AUR build. `arch-chroot` provides a working
  resolver (confirmed on the 2026.11.01 ISO), so no manual `resolv.conf` copy is needed.
- Verify pacman-hook behavior with **real transactions**, not by hand-invoking the sbin scripts:
  `pacman -S --noconfirm linux` fires the post hook and `95-secureboot-sign.hook`; `pacman -S
  --noconfirm systemd` rebuilds UKIs and fires `96-secureboot-sync-loader.hook`. Confirm re-signing
  actually happened by hashing the UKI or `grubx64.efi` before/after and checking `sbverify --cert`,
  not just by reading the hook's own success log line. To prove enforcement, corrupt a spare UKI,
  `bootctl set-oneshot` it, and confirm it doesn't boot.
- `bootctl update` exits 1 when the loader version is unchanged. That is why
  `secureboot-sync-loader.sh` treats it as non-fatal; it also leaves shim at `EFI/BOOT` alone.
- Real hardware: a Lenovo 20KES5JL1A booted with Secure Boot enforced (Nov 2026), including enrolling
  the key by hand in MokManager. Its install ran over ISO Wi-Fi, where a slow mirror failed
  `post_install.sh` once; re-running it fixed that.
- Not yet tested end to end: snapshot rollback, the older-install UKI migration in the README, the LTS
  UKI and kernel updates on real hardware, and machines that only trust the 2023 CA.
- Same tty/pipe rule applies to any remote `sudo` automation, not just `cryptsetup`: `echo pw | sudo
  -S cmd` breaks stdin for whatever `cmd` itself needs to read from the terminal (same "Nothing to
  read on input." failure). Use a real pty (`ssh -tt` + `expect`, or the `pty`+`select` pattern) and
  type the sudo password as a keystroke, not a pipe. Nested quoting through
  `ssh -tt … "sudo bash -c '...'"` chains is a real trap — a mangled password sent to `sudo` still
  counts as a failed attempt. Enough of those can trip `pam_faillock` if it's active, locking the
  account out of **both** `sudo` and SSH password auth, not just `sudo` — recoverable only via
  `faillock --user <user> --reset` at the physical console (or an already-authenticated key-based
  session). Prefer SSH keys over `sshpass` for repeated remote automation to avoid feeding an
  account password through a fragile pipe repeatedly in the first place.
- "Service enabled" is not "service configured." `systemctl is-enabled` passing doesn't mean a
  service did anything — verify actual state (`ip a`, on-disk config) after any
  network/service-provisioning change, not just that the unit is enabled.
