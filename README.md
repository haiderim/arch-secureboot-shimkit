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
 │   choose "Arch (SecureBoot)"│
 └─────────────┬──────────────┘
               │
               ▼
 ┌────────────────────────────┐
 │   MokManager appears       │
 │  → Enroll \EFI\arch\keys\MOK.cer │
 │  → Reboot                   │
 └─────────────┬──────────────┘
               │
               ▼
 ┌────────────────────────────┐
 │   Arch boots via shim →    │
 │ systemd-boot → signed kernel│
 └─────────────┬──────────────┘
               │
               ▼
 ┌────────────────────────────┐
 │   Post-reboot tasks:       │
 │  enable snapper + zram     │
 │  verify Secure Boot state  │
 └────────────────────────────┘
```

---

This visual makes it clear:
ISO → pre_install → chroot → post_install → reboot → MOK enrollment → boot → post-reboot setup.

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
5. Write down the values you will pass to the scripts (`DISK`, `HOSTNAME`, `NEWUSER`, `ROOT_PASS`, `USER_PASS`) so you can paste them without guesswork.

Once those prerequisites are satisfied, start with the checks below.

```bash
# Verify UEFI boot and network
ls /sys/firmware/efi/efivars  # Should show files (UEFI mode)
timedatectl set-ntp true
ping -c1 archlinux.org
```

Partition (example for SATA disk):

> **Heads-up:** The commands below wipe whatever lives on `$DISK`. Run `lsblk -f` (or `fdisk -l`) first, confirm the drive letter, and replace `/dev/sda` with your actual device.
>
> **Note:** `pre_install.sh` currently expects the disk name to end with a single digit (for example `/dev/sda`). If you're installing to NVMe or MMC devices (paths like `/dev/nvme0n1` or `/dev/mmcblk0`), edit the script to add the required `p` partition suffixes before running it, or use a SATA-style device.

```bash
# WARNING: This will erase all data on the disk!
DISK=/dev/sda
# Verify the disk is correct
lsblk "$DISK"
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+512MiB -t 1:ef00 -c 1:"EFI System" "$DISK"
sgdisk -n 2:0:0       -t 2:8300 -c 2:"Linux LUKS" "$DISK"
partprobe "$DISK"
# Verify partitions were created
lsblk "$DISK"
```

Run installation:

```bash
# Set environment variables (adjust as needed)
export DISK=/dev/sda
export HOSTNAME=myhost
export NEWUSER=myuser
export ROOT_PASS='myrootpass'
export USER_PASS='mynewuserpass'

# Run the script
bash ./pre_install.sh
```

**Script assumptions and defaults**

- `pre_install.sh` enforces strong passwords: at least 8 characters, with upper and lower case letters and a number, and the root and user passwords must differ. Let the script prompt interactively if your values fail validation.
- Timezone defaults to `Asia/Kolkata` and locale to `en_US.UTF-8`. Update `/etc/localtime`, `/etc/locale.conf`, and `/etc/locale.gen` after install (or edit the script before running) if you need different regional settings.
- Reflector seeds mirrors for India, Singapore, Germany, and the Netherlands. Adjust `/etc/reflector.conf` or rerun reflector with countries closer to you if required.
- Only `intel-ucode` is installed by default. If you're on AMD hardware, run the following inside the chroot **before** `post_install.sh` so microcode updates are applied on the first Secure Boot:

  ```bash
  pacman -S --noconfirm amd-ucode
  sed -i 's#/intel-ucode.img#/amd-ucode.img#g' /boot/loader/entries/*.conf
  mkinitcpio -P
  pacman -Rns --noconfirm intel-ucode  # optional, removes unused Intel microcode
  ```

  Re-run `bootctl update` if you edit the loader entries by hand, and confirm `/boot/loader/entries/*` now reference `amd-ucode.img`.
- After entering the chroot (see the next section) and before running `post_install.sh`, change the regional defaults if you need to:
  - `ln -sf /usr/share/zoneinfo/<Region>/<City> /etc/localtime`
  - Open `/etc/locale.gen` with `nano`, uncomment your locale, then run `locale-gen`
  - Write your locale to `/etc/locale.conf`, for example `echo 'LANG=en_GB.UTF-8' > /etc/locale.conf`
  - Edit `/etc/reflector.conf` to replace the preconfigured countries with ones nearer to you
  _Replace the placeholders with your own values before running the commands._

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
* The values you plan to use for `DISK`, `HOSTNAME`, `NEWUSER`, `ROOT_PASS`, and `USER_PASS` written down or copied somewhere safe.
* AC power (or a fully charged battery) so the installation cannot be interrupted halfway through.
* On the live ISO, `curl` is already installed. Use it to download the scripts, or install `wget` manually if you prefer that tool. Inside the chroot the scripts install the rest of the required packages automatically.

---

## Partition & Install

Clone the repo so `post_install.sh` can install the required hook and helper files from the same directory:

```bash
git clone https://github.com/haiderim/arch_setup.git
cd arch_setup
chmod +x pre_install.sh post_install.sh efi_cleanup.sh secureboot-sign-kernels.sh secureboot-sync-loader.sh
```

Why clone instead of downloading only `pre_install.sh` and `post_install.sh`:

* `post_install.sh` installs companion assets from the repo directory
* The Secure Boot maintenance path now depends on six extra files:
* `95-secureboot-sign.hook`
* `96-secureboot-sync-loader.hook`
* `secureboot-sign-kernels.sh`
* `secureboot-sync-loader.sh`
* `secureboot-restore-hooks.sh`
* `secureboot-post-rollback.service`

If those files are missing, `post_install.sh` will now stop with an error instead of continuing with an incomplete Secure Boot setup.

Run pre-install (from ISO):

```bash
export DISK=/dev/sda
export HOSTNAME=myhost
export NEWUSER=myuser
export ROOT_PASS='StrongRootPass'
export USER_PASS='StrongUserPass'

bash ./pre_install.sh
```

---

## Secure Boot Setup: Run post_install.sh in Chroot

`pre_install.sh` leaves your target system mounted at `/mnt`. Copy the scripts into the installed system so they're available once you chroot, then change root and finish the secure-boot setup:

```bash
cp -r arch_setup /mnt/root/
arch-chroot /mnt
cd /root/arch_setup
USER_NAME=myuser ./post_install.sh
exit
umount -R /mnt
cryptsetup close cryptroot
reboot
```

Inside the chroot, take a moment to run `lsblk` or inspect `/etc` before starting `post_install.sh`. This is where you should apply the regional changes or AMD microcode steps noted earlier. Once the script reports success, run `exit`, unmount `/mnt`, close `cryptroot`, and reboot into firmware for MOK enrollment.

**What happens automatically**:

* MOK keys created at `/root/secureboot/`
* `shim-signed` built (AUR) and installed
* `shimx64.efi`, `MokManager.efi`, and signed `systemd-bootx64.efi` staged in `\EFI\arch`
* Kernels signed (`/boot/vmlinuz-*`)
* **Automatic kernel signing and systemd-boot sync hooks installed** for future pacman updates
* **Hook recovery service installed** (`secureboot-post-rollback.service`) to restore missing hooks and re-sign kernels automatically on every boot
* Boot entry created: **Arch (SecureBoot)**
* ZRAM configured (50% of RAM, zstd compression)
* Snapper configured for Btrfs snapshots (timeline disabled, 5 snapshots max)
* Boot permissions secured (700 on /boot and /boot/loader)
* Reflector configured for optimal mirror selection

### Automatic Signing And Loader Sync System

The setup installs a pacman hook system for both kernels and the shim-loaded `systemd-boot` binary:

* `95-secureboot-sign.hook` + `secureboot-sign-kernels.sh` sign new kernels after kernel package updates
* `96-secureboot-sync-loader.hook` + `secureboot-sync-loader.sh` refresh and re-sign `systemd-boot` after `systemd` package updates

This means:

* No manual intervention required after kernel updates
* No manual intervention required after `systemd` updates
* Kernels are signed immediately after installation/upgrade
* The shim-loaded `\EFI\arch\grubx64.efi` stays in sync with the current `systemd-boot`
* System remains bootable with Secure Boot enabled after `pacman -Syu`
* Signing scripts include verification and error handling
* Comprehensive logging for troubleshooting

The kernel hook triggers on kernel package upgrades, and the loader hook triggers on `systemd` upgrades. Together they keep both the kernel and the shim-loaded bootloader signed across normal system updates.

#### Hook Recovery Service

The pacman hooks live in `/etc/pacman.d/hooks/` on the root btrfs subvolume (`@`). They can disappear silently in two ways:

* **btrfs rollback** — `snap-pac` snapshots `@` before every pacman transaction. Rolling back `@` wipes the hooks, but `/var/log` (on the separate `@var_log` subvolume) is untouched, so the pacman log still shows them running. The next kernel upgrade proceeds unsigned.
* **accidental deletion** — manual cleanup or tooling that clears `/etc/pacman.d/hooks/`.

`post_install.sh` installs a oneshot systemd service to recover automatically:

* `secureboot-post-rollback.service` runs on every boot after `local-fs.target`
* `secureboot-restore-hooks.sh` checks whether the hooks and sbin scripts are present; if any are missing it recreates them from embedded content (no dependency on the source repo)
* It also checks whether any kernel on the ESP is unsigned and re-signs if needed

```bash
# Check recovery service status
systemctl status secureboot-post-rollback.service
```

---

## First Boot & MOK Enrollment

At first boot, MokManager will launch:

1. Select **Enroll key from disk**
2. Navigate to `\EFI\arch\keys\MOK.cer`
3. Enroll → reboot

Now shim trusts your MOK, and systemd-boot will load signed kernels and a signed bootloader binary.

---

## Post-Reboot Helper

After successful boot:

```bash
# Enable snapper + cleanup timers
systemctl enable --now snapper-cleanup.timer
systemctl enable --now snapperd.service 2>/dev/null || true

# Verify zram
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
cd /root/arch_setup
./efi_cleanup.sh
```

What it does:

- Creates a timestamped backup of `/boot/EFI` before making changes.
- Removes duplicate `Arch (SecureBoot)` and `Linux Boot Manager` entries.
- Re-creates a single `Arch (SecureBoot)` entry pointing at `\EFI\arch\shimx64.efi`.
- Attempts to set the boot order to prefer Arch while keeping Windows second if detected.

Review the backup (`/root/esp-backup-*.tar.gz`) and restore manually if you want to undo the changes.

---

## Verification

```bash
# Secure Boot status
mokutil --sb-state           # Should show "enabled"
efibootmgr -v | grep "Arch (SecureBoot)"  # Should show shimx64.efi

# Kernel signatures
sbverify --list /boot/vmlinuz-linux  # Should show signature info

# File permissions
ls -ld /boot                 # Should be drwx------ (0700)
ls -l /boot/loader/random-seed   # Should be -rw------- (0600)

# Automatic signing verification
ls -la /etc/pacman.d/hooks/95-secureboot-sign.hook  # Should exist and be readable
ls -la /etc/pacman.d/hooks/96-secureboot-sync-loader.hook  # Should exist and be readable
ls -la /usr/local/sbin/secureboot-sign-kernels.sh   # Should exist and be executable
ls -la /usr/local/sbin/secureboot-sync-loader.sh    # Should exist and be executable
cat /etc/pacman.d/hooks/95-secureboot-sign.hook     # Verify kernel hook configuration
cat /etc/pacman.d/hooks/96-secureboot-sync-loader.hook  # Verify loader hook configuration

# Test the signing system (optional)
sudo /usr/local/sbin/secureboot-sign-kernels.sh      # Should report "0/0 kernels signed" or similar
sudo /usr/local/sbin/secureboot-sync-loader.sh       # Should update/sign systemd-boot and exit successfully

# ZRAM status
swapon --show | grep zram    # Should show ZRAM swap device
zramctl                     # Should show ZRAM compression stats

# Snapper configuration
snapper -c root list-configs # Should show root config
ls /.snapshots              # Should exist (timeline disabled but manual possible)
```

Expected:

* Secure Boot **enabled** (mokutil shows enabled)
* Boot entry points to **shimx64.efi** (not systemd-boot directly)
* Kernels are **signed** (sbverify shows signature info)
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
* **ZRAM not activating** → Run `systemctl restart swap.target` or check `/etc/systemd/zram-generator.conf`.
* **Snapper services not starting** → Enable timers: `systemctl enable snapper-cleanup.timer`.
* **Secure Boot validation fails** → Ensure MOK key is enrolled in firmware settings.
* **Network not working post-install** → Enable services: `systemctl enable systemd-networkd systemd-resolved iwd`.
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

# 5. Bind system directories
mount --rbind /dev  /mnt/dev
mount --rbind /proc /mnt/proc
mount --rbind /sys  /mnt/sys
mount --rbind /run  /mnt/run

# 6. Chroot into your system
arch-chroot /mnt

# 7. (Optional) Regenerate fstab if needed
genfstab -U /mnt >> /mnt/etc/fstab
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

**Q: Do I need UKI?**
A: No — shim + MOK works on locked Secure Boot machines without firmware key enrollment.

**Q: Do I need to sign initramfs/microcode?**
A: No, only PE executables (EFI + kernels).

**Q: Do I need to re-sign after updates?**
A: No — pacman hooks handle it automatically. The setup installs two maintenance paths: `95-secureboot-sign.hook` with `secureboot-sign-kernels.sh` for kernel upgrades, and `96-secureboot-sync-loader.hook` with `secureboot-sync-loader.sh` for `systemd` upgrades. Together they keep both the kernels and the shim-loaded `systemd-boot` binary signed across `pacman -Syu`.

**Q: What if I have multiple users?**
A: Override with `USER_NAME=youruser`.

**Q: What mirror countries are configured?**
A: India, Singapore, Germany, Netherlands are configured in reflector for optimal speed.

**Q: Why is Snapper timeline creation disabled?**
A: To conserve space, only manual snapshots are enabled by default with 5 snapshot limit.

**Q: How do I create manual Btrfs snapshots?**
A: Use `sudo snapper create -d "Description"` or `sudo btrfs subvolume snapshot / /.snapshots/snapshot-`.

**Q: Can I use this on NVMe drives?**
A: The scripts currently assume disk names like `/dev/sda`. For NVMe or MMC devices you need to edit `pre_install.sh` first to add the `p` partition suffixes (e.g., `EFI_PART="${DISK}p1"`). Until then, stick to SATA-style devices or be ready to adjust the script manually.

**Q: What if I forget my LUKS password?**
A: Data is irrecoverable without the password. This is intentional full-disk encryption.

**Q: How do I switch between kernels?**
A: Both regular and LTS kernels are installed. Use `sudo reboot` and select from boot menu, or edit `/boot/loader/entries/`.
