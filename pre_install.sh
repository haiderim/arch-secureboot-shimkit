#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[pre-install] $*"; }

# --- Required environment inputs (set via env or prompts) ---
DISK="${DISK:-}"
HOSTNAME="${HOSTNAME:-archhost}"
NEWUSER="${NEWUSER:-}"
TIMEZONE="${TIMEZONE:-Asia/Kolkata}"
LOCALE="${LOCALE:-en_US.UTF-8}"
MIRROR_COUNTRIES="${MIRROR_COUNTRIES:-India,Singapore,Germany,Netherlands}"

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
    [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]] || { echo "ERROR: Unknown TIMEZONE '$TIMEZONE' (expected e.g. 'Region/City', see /usr/share/zoneinfo)" >&2; exit 1; }
    grep -qE "^#?${LOCALE//./\\.} " /usr/share/i18n/SUPPORTED 2>/dev/null || { echo "ERROR: Unknown LOCALE '$LOCALE' (expected e.g. 'en_US.UTF-8', see /usr/share/i18n/SUPPORTED)" >&2; exit 1; }
    [[ "$MIRROR_COUNTRIES" =~ ^[A-Za-z\ ]+(,[A-Za-z\ ]+)*$ ]] || { echo "ERROR: MIRROR_COUNTRIES must be a comma-separated country name list" >&2; exit 1; }
    log "All parameters validated successfully"
}

validate_parameters

# --- Partition disk, encrypt root, and mount subvolumes ---
log "Creating GPT partition table on $DISK"
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart primary fat32 1MiB 1025MiB
parted -s "$DISK" mkpart primary 1025MiB 100%
parted -s "$DISK" set 1 boot on
partprobe "$DISK"
sleep 2
udevadm settle || true

# Derive partition device paths from the live kernel state instead of
# guessing a naming suffix (sdX vs nvmeXnYp vs mmcblkXp vs vdX/loopXp).
# Works for any bus type and stays correct if the naming scheme changes.
# lsblk's listing order is NOT guaranteed to match partition number (seen
# reversed on a disk that previously held a different partition layout) --
# sort explicitly by the PARTN column, the actual GPT partition number.
mapfile -t DISK_PARTS < <(lsblk -lnpo NAME,TYPE,PARTN "$DISK" | awk '$2=="part"{print $3, $1}' | sort -n | awk '{print $2}')
[[ "${#DISK_PARTS[@]}" -eq 2 ]] || { echo "ERROR: expected 2 partitions on $DISK, found ${#DISK_PARTS[@]}" >&2; exit 1; }
EFI_PART="${DISK_PARTS[0]}"
CRYPT_PART="${DISK_PARTS[1]}"
log "EFI partition: $EFI_PART"
log "LUKS partition: $CRYPT_PART"

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
reflector --country "$MIRROR_COUNTRIES" --latest 10 --protocol http --sort rate --save /etc/pacman.d/mirrorlist || pacman -Syy --noconfirm

log "Installing base system"
# Detect CPU vendor to install the matching microcode package; the
# mkinitcpio "microcode" hook auto-detects whichever package is present.
UCODE_PKG="intel-ucode"
case "$(awk -F: '/vendor_id/{print $2; exit}' /proc/cpuinfo | tr -d ' ')" in
  AuthenticAMD) UCODE_PKG="amd-ucode" ;;
  GenuineIntel) UCODE_PKG="intel-ucode" ;;
  *) log "WARNING: unrecognized CPU vendor_id, defaulting to intel-ucode" ;;
esac
log "Detected microcode package: $UCODE_PKG"
packages=(base linux linux-lts linux-firmware btrfs-progs cryptsetup efibootmgr "$UCODE_PKG" snapper snap-pac sbsigntools zram-generator reflector vi less git openssl networkmanager wpa_supplicant nano sudo)
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
  TIMEZONE="${TIMEZONE}" \
  LOCALE="${LOCALE}" \
  MIRROR_COUNTRIES="${MIRROR_COUNTRIES}" \
  bash -s <<'CHROOT_EOF'
set -euo pipefail

# Minimal logger for chroot phase
log(){ echo "[chroot] $*"; }

log "Starting chroot configuration..."
log "Environment check:"
log "  HOSTNAME: $HOSTNAME"
log "  NEWUSER: $NEWUSER" 
log "  CRYPT_PART: $CRYPT_PART"
log "  TIMEZONE: $TIMEZONE"
log "  LOCALE: $LOCALE"

ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc
systemctl enable systemd-timesyncd || true
grep -q "^#${LOCALE} " /etc/locale.gen || { log "ERROR: LOCALE '$LOCALE' not found in /etc/locale.gen"; exit 1; }
sed -i "s/^#${LOCALE} /${LOCALE} /" /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "$HOSTNAME" > /etc/hostname

# Configure initramfs hooks for encrypted Btrfs
perl -0777 -pe 's/^HOOKS=.*$/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap block encrypt filesystems btrfs fsck)/m' -i /etc/mkinitcpio.conf
mkinitcpio -P

# Install systemd-boot and write loader entries
bootctl install
ROOT_UUID=$(blkid -s UUID -o value "$CRYPT_PART")

# Use whichever microcode image mkinitcpio actually staged on the ESP,
# rather than re-deriving CPU vendor. Self-corrects for any vendor string
# and omits the line cleanly if no microcode package applies.
UCODE_INITRD=""
[[ -f /boot/intel-ucode.img ]] && UCODE_INITRD="initrd  /intel-ucode.img"
[[ -f /boot/amd-ucode.img ]] && UCODE_INITRD="initrd  /amd-ucode.img"

cat > /boot/loader/loader.conf <<EOF2
default arch.conf
timeout 3
editor no
EOF2

cat > /boot/loader/entries/arch.conf <<EOF2
title   Arch Linux
linux   /vmlinuz-linux
$UCODE_INITRD
initrd  /initramfs-linux.img
options cryptdevice=UUID=$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw
EOF2

cat > /boot/loader/entries/arch-fallback.conf <<EOF2
title   Arch Linux (Fallback)
linux   /vmlinuz-linux
$UCODE_INITRD
initrd  /initramfs-linux-fallback.img
options cryptdevice=UUID=$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw
EOF2

if [[ -f /boot/vmlinuz-linux-lts ]]; then
  cat > /boot/loader/entries/arch-lts.conf <<EOF2
title   Arch Linux (LTS)
linux   /vmlinuz-linux-lts
$UCODE_INITRD
initrd  /initramfs-linux-lts.img
options cryptdevice=UUID=$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw
EOF2
  cat > /boot/loader/entries/arch-lts-fallback.conf <<EOF2
title   Arch Linux (LTS Fallback)
linux   /vmlinuz-linux-lts
$UCODE_INITRD
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

# Enable essential network daemons. NetworkManager (backed by
# wpa_supplicant for Wi-Fi, started automatically as needed — no separate
# unit to enable) brings up DHCP on wired and wireless interfaces without
# any extra config; systemd-networkd is intentionally left disabled to
# avoid both managers fighting over the same interfaces.
systemctl enable NetworkManager systemd-resolved || true

# Seed reflector with preferred mirror configuration
cat > /etc/reflector.conf <<EOF2
--save /etc/pacman.d/mirrorlist
--country ${MIRROR_COUNTRIES}
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
systemctl is-enabled NetworkManager &>/dev/null && ((checks++)) && log "✓ Network services enabled"

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
