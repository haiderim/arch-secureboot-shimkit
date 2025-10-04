#!/bin/bash
set -euo pipefail

# Secure Boot kernel signing script
# This script signs all kernels on the ESP after pacman updates

# Configuration
MOK_DIR="${MOK_DIR:-/root/secureboot}"
ESP_MOUNT="${ESP_MOUNT:-/boot}"

# Logging
log_info() { echo "[INFO] [secureboot-sign] $*" >&2; }
log_error() { echo "[ERROR] [secureboot-sign] $*" >&2; }
log_warn() { echo "[WARN] [secureboot-sign] $*" >&2; }

# Check if Secure Boot environment is set up
if [[ ! -f "$MOK_DIR/MOK.key" || ! -f "$MOK_DIR/MOK.crt" ]]; then
  log_error "MOK keys not found at $MOK_DIR. Skipping kernel signing."
  log_error "Run the post_install.sh script first to set up Secure Boot."
  exit 0
fi

if ! command -v sbsign >/dev/null 2>&1; then
  log_error "sbsign not found. Install sbsigntools package."
  exit 1
fi

# Check if ESP is mounted
if ! mountpoint -q "$ESP_MOUNT"; then
  log_error "ESP $ESP_MOUNT is not mounted. Cannot sign kernels."
  exit 1
fi

# Sign function (same as post_install.sh)
sign_in_place() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  log_info "Signing $f"
  local tmp="${f}.signed"
  if sbsign --key "$MOK_DIR/MOK.key" --cert "$MOK_DIR/MOK.crt" --output "$tmp" "$f"; then
    mv -f "$tmp" "$f"
    log_info "Successfully signed $f"
  else
    log_error "Failed to sign $f"
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
}

# Count kernels to process
kernel_count=0
signed_count=0

# Sign all kernels on ESP
for k in "$ESP_MOUNT"/vmlinuz-*; do
  if [[ -f "$k" ]]; then
    ((kernel_count++)) || true
    if sign_in_place "$k"; then
      ((signed_count++)) || true
    fi
  fi
done

if [[ $kernel_count -eq 0 ]]; then
  log_warn "No kernels found in $ESP_MOUNT"
else
  log_info "Kernel signing completed: $signed_count/$kernel_count kernels signed"
fi

# Verify signatures (optional but helpful)
if command -v sbverify >/dev/null 2>&1; then
  log_info "Verifying kernel signatures..."
  verified_count=0
  for k in "$ESP_MOUNT"/vmlinuz-*; do
    if [[ -f "$k" ]]; then
      if sbverify --list "$k" >/dev/null 2>&1; then
        ((verified_count++)) || true
      else
        log_warn "Signature verification failed for $k"
      fi
    fi
  done
  log_info "Signature verification: $verified_count/$kernel_count kernels verified"
fi

exit 0