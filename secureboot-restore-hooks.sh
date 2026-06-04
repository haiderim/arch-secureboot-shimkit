#!/bin/bash
# Restores missing pacman hooks and re-signs unsigned kernels on every boot.
# Handles hooks lost to btrfs rollback, accidental deletion, or any other cause.
# Exits early if everything is already in order.
set -euo pipefail

HOOKS_DIR="/etc/pacman.d/hooks"
SBIN_DIR="/usr/local/sbin"
MOK_DIR="${MOK_DIR:-/root/secureboot}"
ESP_MOUNT="${ESP_MOUNT:-/boot}"

log() { echo "[secureboot-restore] $*"; }

# --- Restore hooks if missing ---
# Hook content is embedded so this script has no dependency on the source repo.

hooks_missing=0
for f in 95-secureboot-sign.hook 96-secureboot-sync-loader.hook; do
    [[ -f "$HOOKS_DIR/$f" ]] || { hooks_missing=1; break; }
done

if [[ $hooks_missing -eq 1 ]]; then
    log "Pacman hooks missing — restoring"
    mkdir -p "$HOOKS_DIR"

    install -m 644 /dev/stdin "$HOOKS_DIR/95-secureboot-sign.hook" <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = linux
Target = linux-lts
Target = linux-zen
Target = linux-hardened


[Action]
Description = Sign kernel for Secure Boot
When = PostTransaction
Exec = /usr/local/sbin/secureboot-sign-kernels.sh
EOF

    install -m 644 /dev/stdin "$HOOKS_DIR/96-secureboot-sync-loader.hook" <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = systemd

[Action]
Description = Update and sign systemd-boot for Secure Boot
When = PostTransaction
Exec = /usr/local/sbin/secureboot-sync-loader.sh
EOF

    log "Hooks restored"
fi

# --- Re-sign unsigned kernels ---

[[ -f "$MOK_DIR/MOK.key" && -f "$MOK_DIR/MOK.crt" ]] || { log "MOK keys not found — skipping signing"; exit 0; }
mountpoint -q "$ESP_MOUNT"                              || { log "ESP not mounted — skipping signing"; exit 0; }
command -v sbverify &>/dev/null                         || { log "sbverify not found — skipping signing"; exit 0; }

for k in "$ESP_MOUNT"/vmlinuz-*; do
    [[ -f "$k" ]] || continue
    if ! sbverify --list "$k" &>/dev/null; then
        log "Unsigned kernel found — re-signing"
        "$SBIN_DIR/secureboot-sign-kernels.sh"
        break
    fi
done
