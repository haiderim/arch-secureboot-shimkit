#!/bin/bash
set -euo pipefail

# Installed by post_install.sh; hooks run with a clean environment, so custom
# MOK_DIR/ESP_MOUNT values must be persisted here. An explicit env var still wins.
[[ -r /etc/secureboot-shimkit.conf ]] && . /etc/secureboot-shimkit.conf
MOK_DIR="${MOK_DIR:-/root/secureboot}"
ESP_MOUNT="${ESP_MOUNT:-/boot}"

log_info() { echo "[INFO] [secureboot-loader] $*" >&2; }
log_error() { echo "[ERROR] [secureboot-loader] $*" >&2; }
log_warn() { echo "[WARN] [secureboot-loader] $*" >&2; }

require_file() {
  local path="$1"
  local label="$2"
  if [[ ! -f "$path" ]]; then
    log_error "$label not found: $path"
    exit 1
  fi
}

if [[ ! -f "$MOK_DIR/MOK.key" || ! -f "$MOK_DIR/MOK.crt" ]]; then
  log_error "MOK keys not found at $MOK_DIR. Cannot sign systemd-boot."
  exit 1
fi

if ! command -v bootctl >/dev/null 2>&1; then
  log_error "bootctl not found."
  exit 1
fi

if ! command -v sbsign >/dev/null 2>&1; then
  log_error "sbsign not found. Install sbsigntools."
  exit 1
fi

if ! mountpoint -q "$ESP_MOUNT"; then
  log_error "ESP $ESP_MOUNT is not mounted."
  exit 1
fi

log_info "Updating systemd-boot on $ESP_MOUNT"
if ! bootctl --esp-path="$ESP_MOUNT" update; then
  log_warn "bootctl update reported a non-fatal issue; continuing with signing."
fi

src="$ESP_MOUNT/EFI/systemd/systemd-bootx64.efi"
dst="$ESP_MOUNT/EFI/arch/grubx64.efi"
fallback="$ESP_MOUNT/EFI/BOOT/grubx64.efi"
tmp="${dst}.signed"

require_file "$src" "systemd-boot EFI binary"
require_file "$ESP_MOUNT/EFI/arch/shimx64.efi" "shim EFI binary"

install -d -m 755 "$ESP_MOUNT/EFI/arch" "$ESP_MOUNT/EFI/BOOT"

log_info "Signing $src -> $dst"
sbsign --key "$MOK_DIR/MOK.key" --cert "$MOK_DIR/MOK.crt" --output "$tmp" "$src"
mv -f "$tmp" "$dst"
install -m 644 "$dst" "$fallback"

if command -v sbverify >/dev/null 2>&1; then
  # --list exits 0 even on unsigned images; --cert really checks the signature.
  if sbverify --cert "$MOK_DIR/MOK.crt" "$dst" >/dev/null 2>&1; then
    log_info "Verified signature on $dst"
  else
    log_error "Signature verification failed for $dst"
    exit 1
  fi
fi

# Keep shim and MokManager on the ESP in step with the installed shim-signed.
shim_src="/usr/share/shim-signed"
if [[ -f "$shim_src/shimx64.efi" && -f "$shim_src/mmx64.efi" ]]; then
  log_info "Refreshing shim and MokManager on $ESP_MOUNT"
  install -m 644 "$shim_src/shimx64.efi" "$ESP_MOUNT/EFI/arch/shimx64.efi"
  install -m 644 "$shim_src/mmx64.efi"   "$ESP_MOUNT/EFI/arch/mmx64.efi"
  install -m 644 "$shim_src/mmx64.efi"   "$ESP_MOUNT/EFI/arch/MokManager.efi"
  install -m 644 "$shim_src/shimx64.efi" "$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI"
  install -m 644 "$shim_src/mmx64.efi"   "$ESP_MOUNT/EFI/BOOT/mmx64.efi"
else
  log_warn "shim-signed package files not found in $shim_src; leaving shim on the ESP unchanged"
fi
