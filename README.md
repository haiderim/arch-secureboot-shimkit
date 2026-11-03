# Automated Arch Linux Secure Boot Setup with shim/MOK

> **⚠️ CRITICAL**
> Run `post_install.sh` **in chroot before rebooting**.
> Skipping it will make the system unbootable with Secure Boot enabled.
>
> **💡 Always review scripts before execution.**

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [Use Case](#use-case-locked-machines-with-forced-secure-boot)
3. [Prerequisites](#prerequisites)
4. [Partition & Install](#partition--install)
5. [Secure Boot Setup](#secure-boot-setup-run-post_installsh-in-chroot)
   - [Automatic Signing And Loader Sync System](#automatic-signing-and-loader-sync-system)
6. [First Boot & MOK Enrollment](#first-boot--mok-enrollment)
7. [Post-Reboot Helper](#post-reboot-helper)
8. [EFI Cleanup Utility](#efi-cleanup-utility)
9. [Verification](#verification)
10. [Troubleshooting](#troubleshooting)
11. [Advanced Recovery](#advanced-recovery)
12. [FAQ](#faq)

---

## Installation Flow (Diagram)

```
 ┌────────────────────────────┐
 │  Boot Arch ISO (UEFI mode) │
 └─────────────┬──────────────┘
               │
               ▼
 ┌────────────────────────────┐
 │   Run pre_install.sh       │
 │  (partitions, LUKS, base)  │
 └─────────────┬──────────────┘
               │
               ▼
 ┌────────────────────────────┐
 │   Chroot into /mnt         │
 │  run post_install.sh       │
 │  (shim + MOK + signing)    │
 └─────────────┬──────────────┘
               │
               ▼
 ┌────────────────────────────┐
 │   Reboot into firmware     │
 │  choose Arch (SecureBoot)  │
 └─────────────┬──────────────┘
               │
               ▼
 ┌────────────────────────────┐
 │   MokManager appears       │
 │  → Enroll keys\MOK.cer     │
 │  → Reboot                  │
 └─────────────┬──────────────┘
               │
               ▼
 ┌────────────────────────────┐
 │   Arch boots via shim →    │
 │ systemd-boot → signed UKI  │
 └─────────────┬──────────────┘
               │
               ▼
 ┌────────────────────────────┐
 │   Post-reboot checks:      │
 │  verify Secure Boot state  │
 │  verify snapper + zram     │
 └────────────────────────────┘
```

---

This visual makes it clear:
ISO → pre_install → chroot → post_install → reboot → MOK enrollment → boot → post-reboot checks.

## Quick Start

If you're new to the Arch installer, make sure you cover these basics before running the quick commands below:

1. Boot the [latest Arch Linux ISO](https://archlinux.org/download/) and choose the firmware entry labelled `UEFI`. The live environment drops you at a root shell as `root`.
2. Connect to the internet. Plug in ethernet if possible. For Wi-Fi, use `iwctl` to join your network:
   ```bash
   iwctl
   device list
   station wlan0 scan
   station wlan0 get-networks
   station wlan0 connect "YourSSID"
   exit
   ```
   Replace `wlan0` and `"YourSSID"` with the values shown by `device list` and `station ... get-networks`.
3. Keep the machine on AC power and disable any firmware sleep timers so the install is not interrupted.
4. Back up anything important on the disk you plan to reuse—the next steps destroy its current partition table.
5. Write down the values you will pass to the scripts (`DISK`, `TARGET_HOSTNAME`, `NEWUSER`, `ROOT_PASS`, `USER_PASS`) so you can paste them without guesswork.

Once those prerequisites are satisfied, start with the checks below.

```bash
# Verify UEFI boot and network
ls /sys/firmware/efi/efivars  # Should show files (UEFI mode)
timedatectl set-ntp true
ping -c1 archlinux.org
```

> **Heads-up:** `pre_install.sh` erases everything on `$DISK`. Run `lsblk -f` (or `fdisk -l`) first and confirm the device. Don't partition it yourself: the script creates the GPT layout (1 GiB ESP, the rest LUKS), then derives `EFI_PART`/`CRYPT_PART` from `lsblk`, so SATA (`/dev/sda`), NVMe (`/dev/nvme0n1`), and MMC (`/dev/mmcblk0`) all work unmodified.

Run installation:

```bash
# Set environment variables (adjust as needed)
export DISK=/dev/sda
export TARGET_HOSTNAME=myhost
export NEWUSER=myuser
export ROOT_PASS='MyRootPass1'
export USER_PASS='MyUserPass1'
# Optional — override regional defaults (shown values are the script's defaults)
export TIMEZONE=Asia/Kolkata
export LOCALE=en_US.UTF-8
export MIRROR_COUNTRIES=India,Singapore,Germany,Netherlands

# Run the script
bash ./pre_install.sh
```

**Script assumptions and defaults**

- `pre_install.sh` enforces strong passwords: at least 8 characters, with upper and lower case letters and a number, and the root and user passwords must differ. If `ROOT_PASS` or `USER_PASS` is unset, the script prompts for it, and the same rules apply.
- The hostname comes from `TARGET_HOSTNAME` (default `archhost`). `HOSTNAME` is ignored, because bash sets that variable itself.
- Timezone defaults to `Asia/Kolkata`, locale to `en_US.UTF-8`, and mirror countries to `India,Singapore,Germany,Netherlands`. Override any of these by exporting `TIMEZONE`, `LOCALE`, or `MIRROR_COUNTRIES` before running `pre_install.sh` — no script edits needed. `TIMEZONE` must match a path under `/usr/share/zoneinfo` (e.g. `America/New_York`), `LOCALE` must exist in `/usr/share/i18n/SUPPORTED` (e.g. `en_GB.UTF-8`), and `MIRROR_COUNTRIES` is a comma-separated Reflector country list (e.g. `United States,Canada`); the script validates all three up front and fails fast on typos.
- CPU vendor is auto-detected: `pre_install.sh` installs `intel-ucode` or `amd-ucode` based on `/proc/cpuinfo`, and mkinitcpio's `microcode` hook embeds it in the UKI. No manual steps needed on AMD hardware.
- Clock stays correct after install: `pre_install.sh` sets the hardware clock once (`hwclock --systohc`) and enables `systemd-timesyncd` for continuous NTP sync going forward.
- Networking works automatically post-install: `pre_install.sh` installs and enables `NetworkManager` (Wi-Fi via `wpa_supplicant`, started on demand — no separate unit to enable) which also manages DNS through `/etc/resolv.conf`. Wired interfaces get DHCP with no extra config; for Wi-Fi use `nmcli device wifi connect <SSID> --ask` or `nmtui` after first boot. `systemd-networkd`/`iwd` are intentionally not used, to avoid two managers fighting over the same interfaces.
- Missed setting `TIMEZONE`/`LOCALE`/`MIRROR_COUNTRIES` before running? Change them after entering the chroot (see the next section) and before running `post_install.sh`:
  - `ln -sf /usr/share/zoneinfo/<Region>/<City> /etc/localtime`
  - Open `/etc/locale.gen` with `nano`, uncomment your locale, then run `locale-gen`
  - Write your locale to `/etc/locale.conf`, for example `echo 'LANG=en_GB.UTF-8' > /etc/locale.conf`
  - Edit `/etc/xdg/reflector/reflector.conf` to replace the preconfigured countries with ones nearer to you

---

## Use Case: Locked Machines with Forced Secure Boot

Choose this method if:

* Secure Boot cannot be disabled in firmware.
* Firmware refuses unsigned EFI binaries.
* You need full-disk encryption with compliance.

Skip if:

* You can disable Secure Boot freely.
* This is personal hardware with no restrictions.

---

## Prerequisites

Make sure you have everything below sorted before you touch the scripts:

* The official Arch Linux ISO, written to a USB stick and booted in **UEFI** mode (the Quick Start section shows how to confirm this).
* Firmware access to the machine so you can choose the USB device and, if necessary, disable any temporary boot restrictions.
* Reliable internet. Wired connections come up automatically; for Wi-Fi you can use `iwctl` (commands shown above) before running the scripts.
* A recent backup of anything important on the target disk—`pre_install.sh` wipes it without additional prompts.
* The values you plan to use for `DISK`, `TARGET_HOSTNAME`, `NEWUSER`, `ROOT_PASS`, and `USER_PASS` written down or copied somewhere safe.
* AC power (or a fully charged battery) so the installation cannot be interrupted halfway through.
* On the live ISO, `curl` is already installed. Use it to download the scripts, or install `wget` manually if you prefer that tool. Inside the chroot the scripts install the rest of the required packages automatically.

---

## Partition & Install

Clone the repo so `post_install.sh` can install the required hook and helper files from the same directory:

```bash
git clone https://github.com/haiderim/arch-secureboot-shimkit.git
cd arch-secureboot-shimkit
```

Why clone instead of downloading only `pre_install.sh` and `post_install.sh`:

* `post_install.sh` installs companion assets from the repo directory
* The Secure Boot maintenance path depends on seven extra files:
  * `95-secureboot-sign.hook`
  * `96-secureboot-sync-loader.hook`
  * `secureboot-sign-kernels.sh`
  * `secureboot-sync-loader.sh`
  * `secureboot-restore-hooks.sh`
  * `secureboot-post-rollback.service`
  * `secureboot-mkinitcpio-post`

If those files are missing, `post_install.sh` stops with an error instead of continuing with an incomplete Secure Boot setup.

Run pre-install (from ISO):

```bash
export DISK=/dev/sda
export TARGET_HOSTNAME=myhost
export NEWUSER=myuser
export ROOT_PASS='StrongRootPass1'
export USER_PASS='StrongUserPass1'

bash ./pre_install.sh
```

---

## Secure Boot Setup: Run post_install.sh in Chroot

`pre_install.sh` leaves your target system mounted at `/mnt`. Copy the scripts into the installed system so they're available once you chroot, then change root and finish the secure-boot setup:

```bash
cp -r ../arch-secureboot-shimkit /mnt/root/
arch-chroot /mnt
cd /root/arch-secureboot-shimkit
USER_NAME=myuser ./post_install.sh
exit
umount -R /mnt
cryptsetup close cryptroot
reboot
```

Inside the chroot, take a moment to run `lsblk` or inspect `/etc` before starting `post_install.sh`. This is where you should apply regional changes (timezone/locale) noted earlier. Once the script reports success, run `exit`, unmount `/mnt`, close `cryptroot`, and reboot into firmware for MOK enrollment. The script exits non-zero if the signed boot chain isn't in place; don't reboot until that is fixed.

Optional settings for `post_install.sh`:

* `USER_NAME`: the account that builds `shim-signed` (default: first account with UID ≥ 1000)
* `MOK_DIR`: where the signing keys live (default `/root/secureboot`), saved to `/etc/secureboot-shimkit.conf` for the hooks
* `SHIM_SIGNED_REF`: the AUR commit of `shim-signed` to build (default: a pinned commit)
* `ESP_MOUNT`: must be `/boot`, because the mkinitcpio presets and boot setup assume it

**What happens automatically**:

* MOK keys created at `/root/secureboot/`
* `shim-signed` built from a pinned AUR commit and installed
* Shim, MokManager and signed `systemd-boot` staged in `\EFI\arch`, with a fallback copy in `\EFI\BOOT`
* Unified kernel images in `/boot/EFI/Linux/` (built by `pre_install.sh`) signed, covering the kernel, initramfs, microcode and cmdline
* **Automatic UKI signing and systemd-boot sync hooks installed** for future updates
* **Boot-time safety net installed** (`secureboot-post-rollback.service`) to restore missing hooks and sign any unsigned UKI on every boot
* Boot entry created: **Arch (SecureBoot)**
* ZRAM configured (50% of RAM, zstd compression)
* Snapper configured for Btrfs snapshots: `snap-pac` snapshots each pacman transaction, timeline disabled, 5 numbered snapshots kept
* Boot permissions secured (`umask=0077` on the ESP)

### Automatic Signing And Loader Sync System

The setup installs hooks for both UKIs and the shim-loaded `systemd-boot` binary:

* `/etc/initcpio/post/secureboot-sign` signs each UKI whenever mkinitcpio builds one, including rebuilds caused by firmware or `systemd` updates
* `95-secureboot-sign.hook` + `secureboot-sign-kernels.sh` check and sign UKIs after kernel package updates
* `96-secureboot-sync-loader.hook` + `secureboot-sync-loader.sh` refresh and re-sign `systemd-boot`, and copy shim and MokManager to the ESP, after `systemd` or `shim-signed` package updates

`shim-signed` comes from the AUR, so `pacman -Syu` won't upgrade it. `post_install.sh` builds a pinned AUR commit; to update shim, review the newer package and re-run with `SHIM_SIGNED_REF=<commit> ./post_install.sh`, or use an AUR helper.

If signing fails, pacman prints `error: command failed to execute correctly` but still exits 0, so don't chain `pacman -Syu && reboot`. Fix the error before rebooting: an unsigned UKI will not boot under Secure Boot.

This means:

* No manual intervention required after kernel updates
* No manual intervention required after `systemd` updates
* UKIs are signed immediately after every rebuild
* The shim-loaded `\EFI\arch\grubx64.efi` stays in sync with the current `systemd-boot`
* System remains bootable with Secure Boot enabled after `pacman -Syu`
* Signing scripts include verification and error handling
* Comprehensive logging for troubleshooting

The kernel hook triggers whenever any package installs a kernel image, and the loader hook triggers on `systemd` and `shim-signed` updates. Together with the post hook, they keep the UKIs and the shim-loaded bootloader signed across normal system updates.

#### Boot-Time Safety Net

`secureboot-post-rollback.service` runs `secureboot-restore-hooks.sh` on every boot. It restores any missing signing hook and signs any UKI that isn't signed by your MOK, such as a spare kernel left unsigned by a failed update.

Its limits:

* It only runs after a successful boot, so it can't rescue a system whose default UKI won't boot. Use another menu entry, or [Advanced Recovery](#advanced-recovery).
* The service and its scripts live on `@` with the hooks, so a rollback to before `post_install.sh` removes them too.
* It doesn't restore the sbin scripts. If those are missing, re-run `post_install.sh`.

```bash
systemctl status secureboot-post-rollback.service
```

#### Rolling Back a Snapshot

Snapshots only cover the Btrfs subvolumes. UKIs live on the ESP, so after rolling back `@` the UKI may be newer than the modules on root. Boot, then run `pacman -S linux linux-lts` to rebuild and re-sign matching images. The cmdline is fixed to `rootflags=subvol=@`, so restore a snapshot by replacing `@` from the ISO; `snapper rollback` changes the default subvolume, which this cmdline ignores.

> These rollback steps haven't been tested end to end yet, so try them on a non-critical system first.

---

## First Boot & MOK Enrollment

At first boot, shim shows `Verification failed: (0x1A) Security Violation`, because your key isn't trusted yet. This is expected.

1. Select **OK**, then press any key within 10 seconds at **Press any key to perform MOK management**
2. Select **Enroll key from disk**
3. Navigate to `\EFI\arch\keys\MOK.cer`
4. Enroll → reboot

Now shim trusts your MOK, and systemd-boot will load signed UKIs and a signed bootloader binary.

---

## Post-Reboot Helper

After a successful boot, zram and the Snapper cleanup timer are already active. To confirm:

```bash
systemctl status snapper-cleanup.timer
swapon --show
zramctl
```

Optional: clean up duplicate boot entries:

```bash
efibootmgr -v
efibootmgr -b <num> -B   # remove duplicates
```

---

## EFI Cleanup Utility

`efi_cleanup.sh` helps tidy up duplicate EFI boot entries after testing or rerunning the Secure Boot setup. Run it from the installed system (root, with the ESP mounted at `/boot`):

```bash
cd /root/arch-secureboot-shimkit
./efi_cleanup.sh
```

What it does:

- Creates a timestamped backup of `/boot/EFI` before making changes.
- Removes duplicate `Arch (SecureBoot)` and `Linux Boot Manager` entries.
- Re-creates a single `Arch (SecureBoot)` entry pointing at `\EFI\arch\shimx64.efi`.
- Sets the boot order to Arch first and Windows second if detected, keeping all other entries after them.

Review the backup (`/root/esp-backup-*.tar.gz`) and restore manually if you want to undo the changes.

---

## Verification

```bash
# Secure Boot status
bootctl status | grep -i "secure boot"  # Should show "enabled (user)"
mokutil --sb-state           # Should show "enabled"
efibootmgr -v | grep "Arch (SecureBoot)"  # Should show shimx64.efi

# Kernel signatures
sbverify --cert /root/secureboot/MOK.crt /boot/EFI/Linux/arch-linux.efi  # Should print "Signature verification OK"

# File permissions
ls -ld /boot                 # Should be drwx------ (0700)
ls -l /boot/loader/random-seed   # Should be -rw------- (0600)

# Automatic signing verification
ls -la /etc/pacman.d/hooks/95-secureboot-sign.hook  # Should exist and be readable
ls -la /etc/pacman.d/hooks/96-secureboot-sync-loader.hook  # Should exist and be readable
ls -la /usr/local/sbin/secureboot-sign-kernels.sh   # Should exist and be executable
ls -la /usr/local/sbin/secureboot-sync-loader.sh    # Should exist and be executable
ls -la /etc/initcpio/post/secureboot-sign           # Should exist and be executable
cat /etc/pacman.d/hooks/95-secureboot-sign.hook     # Verify kernel hook configuration
cat /etc/pacman.d/hooks/96-secureboot-sync-loader.hook  # Verify loader hook configuration

# Test the signing system (optional)
sudo /usr/local/sbin/secureboot-sign-kernels.sh      # Should report every UKI as signed and verified
sudo /usr/local/sbin/secureboot-sync-loader.sh       # Should update/sign systemd-boot and exit successfully

# ZRAM status
swapon --show | grep zram    # Should show ZRAM swap device
zramctl                     # Should show ZRAM compression stats

# Snapper configuration
snapper list-configs         # Should show root config
ls /.snapshots              # Should exist (timeline disabled but manual possible)
```

Expected:

* Secure Boot **enabled** (mokutil shows enabled)
* Boot entry points to **shimx64.efi** (not systemd-boot directly)
* UKIs are **signed** (sbverify prints "Signature verification OK")
* **Automatic signing hooks** are installed and configured
* **ZRAM** is active as swap device
* **Snapper** is configured for Btrfs snapshots
* **Boot permissions** are secure (700/600)

---

## Troubleshooting

* **UEFI not detected** → Ensure booting in UEFI mode, not Legacy/CSM.
* **Password prompts failing** → Let script prompt interactively instead of passing in command line.
* **Partition errors** → Verify disk path with `lsblk` before partitioning.
* **Duplicate boot entries** → Remove with: `efibootmgr -v` then `efibootmgr -b XXXX -B`.
* **Rebooted before post-install** → Use Advanced Recovery section to re-enter chroot and rerun `post_install.sh`.
* **MOK enrollment not appearing** → Reboot and select boot entry manually, firmware may need multiple reboots.
* **Custom Btrfs layout** → Update Snapper config in `/etc/snapper/configs/root`.
* **ZRAM not activating** → Run `systemctl start systemd-zram-setup@zram0.service` or check `/etc/systemd/zram-generator.conf`.
* **Snapper services not starting** → Enable timers: `systemctl enable snapper-cleanup.timer`.
* **`post_install.sh` validation fails** → Fix each item marked `✗` in its output and re-run it before rebooting.
* **Security Violation at boot after setup** → Enroll the MOK (see First Boot). If it is already enrolled, boot another entry or use Advanced Recovery, then run `secureboot-sign-kernels.sh`.
* **`error: command failed to execute correctly` from pacman** → A signing hook failed. Run `secureboot-sign-kernels.sh` and fix what it reports before rebooting.
* **Network not working post-install** → Check `systemctl status NetworkManager` — it should be enabled and active (DHCP on wired is automatic once it's up). For Wi-Fi, connect with `nmcli device wifi connect "<SSID>" --ask` or `nmtui`; there's no automatic Wi-Fi join.
* **Mirror download speeds slow** → Run `sudo reflector --country US,DE,JP --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist`.

---

## Advanced Recovery

If you rebooted before completing `post_install.sh`, or need to repair/update your system later, follow these steps from the Arch ISO:

```bash
# 1. Unlock the encrypted root (adjust disk path as needed)
cryptsetup open /dev/sda2 cryptroot
# For NVMe: cryptsetup open /dev/nvme0n1p2 cryptroot

# 2. Mount root Btrfs subvolume
mount -o subvol=@,compress=zstd /dev/mapper/cryptroot /mnt

# 3. Mount other subvolumes (adjust if your layout differs)
mkdir -p /mnt/{boot,home,var,.snapshots,srv}
mount -o subvol=@home       /dev/mapper/cryptroot /mnt/home
mount -o subvol=@srv        /dev/mapper/cryptroot /mnt/srv
mount -o subvol=@var_log    /dev/mapper/cryptroot /mnt/var/log
mount -o subvol=@var_pkgs   /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg
mount -o subvol=@.snapshots /dev/mapper/cryptroot /mnt/.snapshots

# 4. Mount EFI system partition
mount /dev/sda1 /mnt/boot
# For NVMe disks, use /dev/nvme0n1p1 instead of /dev/sda1
# For other disk types, adjust partition numbers accordingly

# 5. Chroot into your system (arch-chroot sets up /dev, /proc, /sys and /run)
arch-chroot /mnt
```

You are now inside your installed Arch system. From here you can:

* Re-run `post_install.sh` if Secure Boot wasn't set up yet.
* Repair bootloader or kernel issues.
* Use `pacman` or other tools as if you had booted normally.

When done:

```bash
exit
umount -R /mnt
cryptsetup close cryptroot
reboot
```

---

## FAQ

**Q: Why unified kernel images?**
A: A separate initramfs and loader-entry options sit unsigned on the unencrypted ESP, so someone with physical access could alter them to capture your LUKS passphrase. A UKI puts them inside the signed file. The kernel cmdline lives in `/etc/kernel/cmdline`; run `mkinitcpio -P` after changing it. The ESP still holds the unsigned `/boot/vmlinuz-*` copies, but they are not used for booting.

**Q: Do I need to sign initramfs/microcode separately?**
A: No. They are inside the UKI, and a mkinitcpio post hook signs it after every rebuild.

**Q: Do I need to re-sign after updates?**
A: No. A mkinitcpio post hook signs UKIs on every rebuild, `95-secureboot-sign.hook` checks them after kernel updates, and `96-secureboot-sync-loader.hook` re-signs `systemd-boot` after `systemd` updates. Watch for pacman errors, because a failed hook doesn't change pacman's exit code.

**Q: What if I have multiple users?**
A: `NEWUSER` (required, `pre_install.sh`) is the account created during install. `post_install.sh` runs later and auto-detects the admin user as the first UID ≥ 1000 account in `/etc/passwd` — if you created more than one user by hand before running it, pin the right one with `USER_NAME=youruser ./post_install.sh`.

**Q: What timezone, locale, and mirror countries are configured?**
A: `Asia/Kolkata`, `en_US.UTF-8`, and `India,Singapore,Germany,Netherlands` by default. Override any of them with `export TIMEZONE=...`, `export LOCALE=...`, or `export MIRROR_COUNTRIES="United States,Canada"` before running `pre_install.sh` — all three are validated up front and the script fails fast on a typo.

**Q: Why is Snapper timeline creation disabled?**
A: To conserve space. `snap-pac` still snapshots each pacman transaction, you can create manual snapshots, and cleanup keeps 5 numbered snapshots.

**Q: How do I create manual Btrfs snapshots?**
A: Use `sudo snapper create -d "Description"`.

**Q: Can I use this on NVMe drives?**
A: Yes. `pre_install.sh` partitions `$DISK` with `parted`, then reads back the resulting partition device paths from `lsblk` instead of guessing a `sdX`/`nvmeXnYp` suffix. SATA, NVMe, and MMC all work with `DISK` set to the base device (e.g. `/dev/sda`, `/dev/nvme0n1`, `/dev/mmcblk0`) — no script edits required.

**Q: Does this work on AMD CPUs?**
A: Yes, no manual steps needed. `pre_install.sh` detects the CPU vendor from `/proc/cpuinfo` and installs `amd-ucode` or `intel-ucode` accordingly, and mkinitcpio embeds it in the UKI.

**Q: Does networking work right after install?**
A: Wired ethernet does — `pre_install.sh` installs and enables `NetworkManager`, which brings up DHCP on Ethernet automatically. Wi-Fi does not auto-join — connect with `nmcli device wifi connect "<SSID>" --ask` or `nmtui` after first boot; `wpa_supplicant` is already installed as NetworkManager's backend.

**Q: What if I forget my LUKS password?**
A: Data is irrecoverable without the password. This is intentional full-disk encryption.

**Q: How do I switch between kernels?**
A: Both regular and LTS kernels are installed, and systemd-boot lists both automatically. Other kernels need a UKI too: in `/etc/mkinitcpio.d/<kernel>.preset`, comment out `default_image`, set `default_uki="/boot/EFI/Linux/arch-<kernel>.efi"`, then run `mkinitcpio -p <kernel>`.

**Q: How do I move an older install from separate kernel files to UKIs?**
A: Install `systemd-ukify`, put your current options in `/etc/kernel/cmdline`, edit both presets as above, and set `default arch-linux.efi` in `/boot/loader/loader.conf`. Re-run `post_install.sh`, check `sbverify` passes on the new UKIs, then delete the old files in `/boot/loader/entries/`. These steps haven't been tested end to end yet, so keep a way to recover (see Advanced Recovery).
