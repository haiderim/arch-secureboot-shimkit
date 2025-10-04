#!/usr/bin/env bash
set -euo pipefail

# Structured logging
log_info(){ echo "[INFO] [post-install] $*" >&2; }
log_warn(){ echo "[WARN] [post-install] $*" >&2; }
log_error(){ echo "[ERROR] [post-install] $*" >&2; }
log(){ log_info "$*"; }

# --- Configurable inputs with sensible defaults ---
USER_NAME="${USER_NAME:-$(awk -F: '$3>=1000 && $1!="nobody"{print $1; exit}' /etc/passwd)}"
MOK_DIR="${MOK_DIR:-/root/secureboot}"
ESP_MOUNT="${ESP_MOUNT:-/boot}"

# Trap errors so we can report context before exiting
handle_error() {
    local exit_code=$?
    log_error "Command failed with exit code $exit_code"
    log_error "Command: $BASH_COMMAND"
    log_error "Line: ${BASH_LINENO[0]}"
    exit $exit_code
}
trap handle_error ERR

# --- Helper to detect whether we are running inside a chroot ---
in_chroot() {
    [[ -f /run/systemd/system ]] || return 0   # Treat missing systemd tree as evidence of a chroot
    ! systemctl is-system-running --quiet
}

# --- Validate required parameters before continuing ---
validate_parameters() {
    [[ -n "$USER_NAME" ]] || { log_error "USER_NAME parameter is required"; exit 1; }
    [[ -n "$MOK_DIR"   ]] || { log_error "MOK_DIR parameter is required"; exit 1; }
    [[ -n "$ESP_MOUNT" ]] || { log_error "ESP_MOUNT parameter is required"; exit 1; }
    [[ -d "$ESP_MOUNT" ]] || { log_error "ESP mount point $ESP_MOUNT does not exist"; exit 1; }
    id "$USER_NAME" >/dev/null 2>&1 || { log_error "User $USER_NAME does not exist"; exit 1; }
    log_info "All parameters validated successfully"
}

# --- Preflight checks and package prerequisites ---
if ! mountpoint -q "$ESP_MOUNT"; then
  log_error "$ESP_MOUNT is not mounted. Mount your ESP and re-run."
  exit 1
fi
[[ $EUID -eq 0 ]] || { log_error "Run as root."; exit 1; }
validate_parameters

command -v efibootmgr >/dev/null || pacman -Sy --noconfirm efibootmgr
pacman -Sy --noconfirm --needed base-devel git sbsigntools openssl

# --- Lock down ESP permissions and update fstab entry ---
chmod 700 "$ESP_MOUNT" || true
mkdir -p "$ESP_MOUNT/loader"
chmod 700 "$ESP_MOUNT/loader" || true
install -m 600 /dev/null "$ESP_MOUNT/loader/random-seed" 2>/dev/null || true
chmod 600 "$ESP_MOUNT/loader/random-seed" || true

ESP_DEV="$(findmnt -no SOURCE "$ESP_MOUNT")"
ESP_UUID="$(blkid -s UUID -o value "$ESP_DEV" || true)"
if [[ -n "$ESP_UUID" ]]; then
  cp /etc/fstab "/etc/fstab.$(date +%Y%m%d-%H%M%S).bak"
  sed -i 's@^\(.*[[:space:]]/boot[[:space:]].*\)$@# \1@g' /etc/fstab
  grep -q "UUID=${ESP_UUID}[[:space:]]\+/boot" /etc/fstab || \
    echo "UUID=$ESP_UUID  /boot  vfat  umask=0077,shortname=mixed  0  2" >> /etc/fstab
  mount -o remount "$ESP_MOUNT" || true
fi

# --- Ensure systemd-boot binaries are installed and current ---
bootctl --graceful install || true
bootctl --graceful update  || true

# --- Generate or reuse Machine Owner Keys (MOK) ---
mkdir -p "$MOK_DIR"
if [[ ! -s "$MOK_DIR/MOK.key" || ! -s "$MOK_DIR/MOK.crt" ]]; then
  openssl req -new -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -subj "/CN=Arch SecureBoot MOK/" \
    -keyout "$MOK_DIR/MOK.key" -out "$MOK_DIR/MOK.crt"
fi
openssl x509 -in "$MOK_DIR/MOK.crt" -outform DER -out "$MOK_DIR/MOK.cer"

install -d -m 755 "$ESP_MOUNT/EFI/arch/keys"
install -m 644 "$MOK_DIR/MOK.cer" "$ESP_MOUNT/EFI/arch/keys/MOK.cer"

# --- Build and install shim-signed from the AUR when needed ---
if [[ ! -f /usr/share/shim-signed/shimx64.efi ]]; then
  su - "$USER_NAME" -c '
    set -e
    rm -rf ~/shim-signed
    git clone https://aur.archlinux.org/shim-signed.git ~/shim-signed
    cd ~/shim-signed
    makepkg -f --noconfirm
  '
  pacman -U --noconfirm "/home/$USER_NAME/shim-signed/"*.pkg.tar.*
fi

SHIM_SRC="/usr/share/shim-signed"
install -d -m 755 "$ESP_MOUNT/EFI/arch" "$ESP_MOUNT/EFI/BOOT"
install -m 644 "$SHIM_SRC/shimx64.efi" "$ESP_MOUNT/EFI/arch/shimx64.efi"
install -m 644 "$SHIM_SRC/mmx64.efi"   "$ESP_MOUNT/EFI/arch/mmx64.efi"
install -m 644 "$SHIM_SRC/mmx64.efi"   "$ESP_MOUNT/EFI/arch/MokManager.efi"
install -m 644 "$SHIM_SRC/shimx64.efi" "$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"

# --- Sign systemd-boot and expose it as grubx64.efi ---
if [[ -f "$ESP_MOUNT/EFI/systemd/systemd-bootx64.efi" ]]; then
  sbsign --key "$MOK_DIR/MOK.key" --cert "$MOK_DIR/MOK.crt" \
    --output "$ESP_MOUNT/EFI/arch/grubx64.efi" \
    "$ESP_MOUNT/EFI/systemd/systemd-bootx64.efi"
  install -m 644 "$ESP_MOUNT/EFI/arch/grubx64.efi" "$ESP_MOUNT/EFI/BOOT/grubx64.efi"
fi

# --- Sign each kernel currently staged on the ESP ---
sign_in_place() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  log "Signing $f"
  local tmp="${f}.signed"
  sbsign --key "$MOK_DIR/MOK.key" --cert "$MOK_DIR/MOK.crt" --output "$tmp" "$f"
  mv -f "$tmp" "$f"
}
for k in "$ESP_MOUNT"/vmlinuz-*; do
  [[ -f "$k" ]] && sign_in_place "$k"
done

# --- Install pacman hooks for automatic kernel signing ---
mkdir -p /etc/pacman.d/hooks
mkdir -p /usr/local/sbin

# Install hook files from the current directory
if [[ -f "$(dirname "$0")/95-secureboot-sign.hook" ]]; then
  cp "$(dirname "$0")/95-secureboot-sign.hook" /etc/pacman.d/hooks/
  log_info "Pacman hook installed: 95-secureboot-sign.hook"
else
  log_warn "Hook file 95-secureboot-sign.hook not found in script directory"
fi

if [[ -f "$(dirname "$0")/secureboot-sign-kernels.sh" ]]; then
  cp "$(dirname "$0")/secureboot-sign-kernels.sh" /usr/local/sbin/
  chmod +x /usr/local/sbin/secureboot-sign-kernels.sh
  log_info "Kernel signing script installed: secureboot-sign-kernels.sh"
else
  log_warn "Signing script secureboot-sign-kernels.sh not found in script directory"
fi

# --- Recreate a single Arch (SecureBoot) boot entry ---
ESP_DISK="/dev/$(lsblk -no pkname "$ESP_DEV")"
ESP_PARTNUM="$(cat "/sys/class/block/$(basename "$ESP_DEV")/partition")"
while efibootmgr | grep -q "Arch (SecureBoot)"; do
  BOOTNUM=$(efibootmgr | grep "Arch (SecureBoot)" | head -n1 | awk '{print $1}' | tr -d '*')
  [[ -n "$BOOTNUM" ]] && efibootmgr -b "${BOOTNUM}" -B || break
done
efibootmgr -c -d "$ESP_DISK" -p "$ESP_PARTNUM" \
  -L "Arch (SecureBoot)" \
  -l '\EFI\arch\shimx64.efi' || true

# --- Configure zram-based swap ---
log_info "Setting up ZRAM"
cat >/etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
EOF
if in_chroot; then
  log_warn "Running in chroot → skipping ZRAM activation; will auto-start on next boot"
else
  systemctl daemon-reexec && systemctl restart swap.target || log_warn "ZRAM activation failed"
fi

# --- Configure Snapper policy and timers ---
log_info "Setting up Snapper"
mkdir -p /etc/snapper/configs
cat >/etc/snapper/configs/root <<'EOF'
SUBVOLUME="/"
FSTYPE="btrfs"
ALLOW_GROUPS="wheel"
TIMELINE_CREATE="no"
TIMELINE_CLEANUP="yes"
NUMBER_CLEANUP="yes"
NUMBER_LIMIT="5"
EOF
ln -sfn /etc/snapper/configs/root /etc/snapper/config
if in_chroot; then
  log_warn "Running in chroot → skipping snapperd start; enable timers after boot"
  systemctl enable snapper-cleanup.timer || true
else
  systemctl enable --now snapper-cleanup.timer
  systemctl enable --now snapperd.service || true
fi

# --- Summarize Secure Boot artifacts for sanity checking ---
validate_secureboot() {
    local checks=0
    [[ -f "$MOK_DIR/MOK.key" && -f "$MOK_DIR/MOK.crt" ]] && { log_info "✓ MOK keys present"; ((checks++)) || true; }
    [[ -f "$ESP_MOUNT/EFI/arch/shimx64.efi" ]] && { log_info "✓ Shim installed"; ((checks++)) || true; }
    [[ -f "$ESP_MOUNT/EFI/arch/grubx64.efi" ]] && { log_info "✓ systemd-boot signed"; ((checks++)) || true; }
    [[ -f "/etc/pacman.d/hooks/95-secureboot-sign.hook" ]] && { log_info "✓ Pacman hooks installed"; ((checks++)) || true; }
    efibootmgr | grep -q "Arch (SecureBoot)" && { log_info "✓ Boot entry exists"; ((checks++)) || true; }
    echo $checks
}
secureboot_score=$(validate_secureboot)
log_info "Secure Boot validation score: $secureboot_score/5"

log_info "Post-install complete. Reboot, enroll MOK, and enable services if needed."
