#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[pre-install] $*"; }

# --- Required environment inputs (set via env or prompts) ---
DISK="${DISK:-}"
HOSTNAME="${HOSTNAME:-archhost}"
NEWUSER="${NEWUSER:-}"

# Ensure NEWUSER is provided and not set to root
if [[ -z "$NEWUSER" ]]; then
    echo "ERROR: NEWUSER must be provided via environment variable" >&2
    exit 1
fi

if [[ "$NEWUSER" == "root" ]]; then
    echo "ERROR: NEWUSER cannot be 'root'" >&2
    exit 1
fi

# Prompt for passwords if env vars are unset
get_secure_password() {
    local prompt="$1"
    local password password_confirm
    while true; do
        read -r -s -p "$prompt: " password
        echo >&2
        read -r -s -p "Confirm $prompt: " password_confirm
        echo >&2
        if [[ "$password" == "$password_confirm" ]]; then
            if [[ ${#password} -ge 8 ]]; then
                echo "$password"
                break
            else
                echo "ERROR: Password must be at least 8 characters long" >&2
            fi
        else
            echo "ERROR: Passwords do not match" >&2
        fi
    done
}

ROOT_PASS="${ROOT_PASS:-$(get_secure_password "Root password")}"
USER_PASS="${USER_PASS:-$(get_secure_password "User password for $NEWUSER")}"

log "Target disk: $DISK"

# --- Helper routines to validate inputs and disk state ---
validate_disk() {
    local disk="$1"
    [[ -b "$disk" ]] || { echo "ERROR: $disk is not a block device" >&2; exit 1; }
    [[ "$disk" =~ ^/dev/ ]] || { echo "ERROR: Invalid disk path: $disk" >&2; exit 1; }
    [[ -w "$disk" ]] || { echo "ERROR: No write permission for $disk" >&2; exit 1; }
}

validate_password() {
    local pass="$1" pass_type="$2"
    [[ ${#pass} -ge 8 ]] || { echo "ERROR: $pass_type password must be at least 8 characters" >&2; exit 1; }
    [[ "$pass" =~ [A-Z] ]] || { echo "ERROR: $pass_type password must contain uppercase letters" >&2; exit 1; }
    [[ "$pass" =~ [a-z] ]] || { echo "ERROR: $pass_type password must contain lowercase letters" >&2; exit 1; }
    [[ "$pass" =~ [0-9] ]] || { echo "ERROR: $pass_type password must contain numbers" >&2; exit 1; }
}

validate_parameters() {
    [[ -n "$DISK" ]] || { echo "ERROR: DISK parameter is required" >&2; exit 1; }
    [[ -n "$HOSTNAME" ]] || { echo "ERROR: HOSTNAME parameter is required" >&2; exit 1; }
    [[ -n "$NEWUSER" ]] || { echo "ERROR: NEWUSER parameter is required" >&2; exit 1; }
    [[ -n "$ROOT_PASS" ]] || { echo "ERROR: ROOT_PASS parameter is required" >&2; exit 1; }
    [[ -n "$USER_PASS" ]] || { echo "ERROR: USER_PASS parameter is required" >&2; exit 1; }
    validate_disk "$DISK"
    [[ "$NEWUSER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "ERROR: Invalid username format" >&2; exit 1; }
    [[ "$HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || { echo "ERROR: Invalid hostname format" >&2; exit 1; }
    validate_password "$ROOT_PASS" "Root"
    validate_password "$USER_PASS" "User"
    [[ "$ROOT_PASS" != "$USER_PASS" ]] || { echo "ERROR: Root and user passwords must be different" >&2; exit 1; }
    log "All parameters validated successfully"
}

validate_parameters

EFI_PART="${DISK}1"
CRYPT_PART="${DISK}2"

# --- Partition disk, encrypt root, and mount subvolumes ---
log "Creating GPT partition table on $DISK"
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart primary fat32 1MiB 1025MiB
parted -s "$DISK" mkpart primary 1025MiB 100%
parted -s "$DISK" set 1 boot on
partprobe "$DISK"
sleep 2

log "Formatting EFI partition"
mkfs.fat -F32 "$EFI_PART"

log "Setting up LUKS"
sleep 5
cryptsetup luksFormat --type luks2 "$CRYPT_PART"
cryptsetup open "$CRYPT_PART" cryptroot

log "Creating Btrfs filesystem and subvolumes"
mkfs.btrfs "/dev/mapper/cryptroot"
mount "/dev/mapper/cryptroot" /mnt
for subvol in @ @home @.snapshots @srv @var_log @var_pkgs; do
    btrfs subvolume create "/mnt/$subvol"
done
umount /mnt

mount -o "subvol=@,compress=zstd" "/dev/mapper/cryptroot" /mnt
for m in "home:@home" ".snapshots:@.snapshots" "srv:@srv" "var/log:@var_log" "var/cache/pacman/pkg:@var_pkgs"; do
    dir="${m%%:*}"; subvol="${m##*:}"
    mkdir -p "/mnt/$dir"
    mount -o "subvol=${subvol},compress=zstd" "/dev/mapper/cryptroot" "/mnt/$dir"
done

mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

# --- Install base packages and seed configuration ---
log "Optimizing mirrors with reflector"
reflector --country India,Singapore,Germany,Netherlands --latest 10 --protocol http --sort rate --save /etc/pacman.d/mirrorlist || pacman -Syy --noconfirm

log "Installing base system"
packages=(base linux linux-lts linux-firmware btrfs-progs cryptsetup efibootmgr intel-ucode snapper snap-pac sbsigntools zram-generator reflector vi less git openssl iwd nano sudo)
pacman -Sy --noconfirm
pacstrap /mnt "${packages[@]}"

log "Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab

# --- Configure the new system from within the chroot ---
log "Entering chroot to configure system"
arch-chroot /mnt /usr/bin/env \
  PATH="/usr/local/sbin:/usr/local/bin:/usr/bin:/sbin:/bin" \
  HOSTNAME="${HOSTNAME}" \
  NEWUSER="${NEWUSER}" \
  ROOT_PASS="${ROOT_PASS}" \
  USER_PASS="${USER_PASS}" \
  CRYPT_PART="${CRYPT_PART}" \
  bash -s <<'CHROOT_EOF'
set -euo pipefail

# Minimal logger for chroot phase
log(){ echo "[chroot] $*"; }

log "Starting chroot configuration..."
log "Environment check:"
log "  HOSTNAME: $HOSTNAME"
log "  NEWUSER: $NEWUSER" 
log "  CRYPT_PART: $CRYPT_PART"

ln -sf /usr/share/zoneinfo/Asia/Kolkata /etc/localtime
hwclock --systohc
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "$HOSTNAME" > /etc/hostname

# Configure initramfs hooks for encrypted Btrfs
perl -0777 -pe 's/^HOOKS=.*$/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap block encrypt filesystems btrfs fsck)/m' -i /etc/mkinitcpio.conf
mkinitcpio -P

# Install systemd-boot and write loader entries
bootctl install
ROOT_UUID=$(blkid -s UUID -o value "$CRYPT_PART")

cat > /boot/loader/loader.conf <<EOF2
default arch.conf
timeout 3
editor no
EOF2

cat > /boot/loader/entries/arch.conf <<EOF2
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options cryptdevice=UUID=$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw
EOF2

cat > /boot/loader/entries/arch-fallback.conf <<EOF2
title   Arch Linux (Fallback)
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux-fallback.img
options cryptdevice=UUID=$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw
EOF2

if [[ -f /boot/vmlinuz-linux-lts ]]; then
  cat > /boot/loader/entries/arch-lts.conf <<EOF2
title   Arch Linux (LTS)
linux   /vmlinuz-linux-lts
initrd  /intel-ucode.img
initrd  /initramfs-linux-lts.img
options cryptdevice=UUID=$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw
EOF2
  cat > /boot/loader/entries/arch-lts-fallback.conf <<EOF2
title   Arch Linux (LTS Fallback)
linux   /vmlinuz-linux-lts
initrd  /intel-ucode.img
initrd  /initramfs-linux-lts-fallback.img
options cryptdevice=UUID=$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw
EOF2
fi

# --- Create administrative user and configure access ---
log "Setting up user accounts..."
log "Username: $NEWUSER"

# Set the root account password
echo "root:$ROOT_PASS" | chpasswd && log "Root password set successfully" || log "ERROR: Failed to set root password"

# Create the non-root admin user if it does not exist
if ! id "$NEWUSER" &>/dev/null; then
    log "Creating user $NEWUSER..."
    if useradd -m -G wheel -s /bin/bash "$NEWUSER"; then
        log "User $NEWUSER created successfully"
    else
        log "ERROR: Failed to create user $NEWUSER"
        exit 1
    fi
else
    log "User $NEWUSER already exists, skipping creation"
    # Ensure the admin user belongs to the wheel group
    if ! groups "$NEWUSER" | grep -q wheel; then
        if usermod -aG wheel "$NEWUSER"; then
            log "Added $NEWUSER to wheel group"
        else
            log "ERROR: Failed to add $NEWUSER to wheel group"
        fi
    fi
fi

# Verify the admin user now exists
if id "$NEWUSER" &>/dev/null; then
    log "User verification: $NEWUSER exists"
    log "User groups: $(groups $NEWUSER)"
else
    log "ERROR: User $NEWUSER was not created properly"
    exit 1
fi

# Assign the chosen password to the admin user
if echo "${NEWUSER}:${USER_PASS}" | chpasswd; then
    log "User password set successfully"
else
    log "ERROR: Failed to set user password"
    exit 1
fi

# Enable sudo for members of the wheel group
cp /etc/sudoers /etc/sudoers.bak
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
log "Sudo access configured for wheel group"

# Enable essential network daemons
systemctl enable systemd-networkd systemd-resolved iwd || true

# Seed reflector with preferred mirror configuration
cat > /etc/reflector.conf <<EOF2
--save /etc/pacman.d/mirrorlist
--country India,Singapore,Germany,Netherlands
--protocol http
--latest 10
--sort rate
--age 12
--completion-percent 100
EOF2
systemctl enable reflector.timer || true
systemctl start reflector.timer || true

# Enable pacman quality-of-life options
sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 5/' /etc/pacman.conf || echo "ParallelDownloads = 5" >> /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf
sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' /etc/pacman.conf

# Run final validation checks before exiting
log "Performing final validation checks..."
checks=0
[[ -f "/boot/EFI/systemd/systemd-bootx64.efi" ]] && ((checks++)) && log "✓ systemd-boot installed"
[[ -f "/boot/vmlinuz-linux" ]] && ((checks++)) && log "✓ Linux kernel installed"
id "$NEWUSER" &>/dev/null && ((checks++)) && log "✓ User $NEWUSER exists"
groups "$NEWUSER" | grep -q wheel && ((checks++)) && log "✓ User in wheel group"
systemctl is-enabled systemd-networkd &>/dev/null && ((checks++)) && log "✓ Network services enabled"

echo "[INFO] Validation score: $checks/5"
if [[ $checks -ge 4 ]]; then
    echo "[SUCCESS] Pre-installation completed successfully!"
else
    echo "[WARNING] Some components may need manual verification"
    exit 1
fi
CHROOT_EOF

log "Pre-install complete. System is ready for first boot!"
log "Remember to reboot and remove installation media."
