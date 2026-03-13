#!/bin/bash
set -euo pipefail

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
  if sbverify --list "$dst" >/dev/null 2>&1; then
    log_info "Verified signature on $dst"
  else
    log_warn "Signature verification failed for $dst"
  fi
fi
