#!/usr/bin/env bash
set -euo pipefail

echo "[EFI-CLEANUP] Backing up ESP before cleanup..."
BACKUP="/root/esp-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
tar -czf "$BACKUP" -C /boot/EFI .
echo "[EFI-CLEANUP] Backup stored at $BACKUP"

# --- Remove redundant Arch (SecureBoot) entries ---
echo "[EFI-CLEANUP] Removing duplicate Arch (SecureBoot) boot entries..."
for num in $(efibootmgr | awk '/Arch \(SecureBoot\)/{print substr($1,5,4)}' | tail -n +2); do
  efibootmgr -b "$num" -B || true
done

# --- Remove redundant Linux Boot Manager/systemd-boot entries ---
echo "[EFI-CLEANUP] Removing duplicate Linux Boot Manager/systemd-boot entries..."
for num in $(efibootmgr | awk '/Linux Boot Manager/{print substr($1,5,4)}' | tail -n +2); do
  efibootmgr -b "$num" -B || true
done

# --- Recreate a single Arch (SecureBoot) entry ---
echo "[EFI-CLEANUP] Re-adding Arch (SecureBoot) entry..."
ESP_DEV="$(findmnt -no SOURCE -t vfat /boot)"
ESP_DISK="/dev/$(lsblk -no pkname "$ESP_DEV")"
ESP_PARTNUM="$(cat "/sys/class/block/$(basename "$ESP_DEV")/partition")"

# Clear any existing Arch entries before recreating
for num in $(efibootmgr | awk '/Arch \(SecureBoot\)/{print substr($1,5,4)}'); do
  efibootmgr -b "$num" -B || true
done

# Register a fresh Arch entry pointing to shimx64.efi
efibootmgr -c -d "$ESP_DISK" -p "$ESP_PARTNUM" \
  -L "Arch (SecureBoot)" \
  -l '\EFI\arch\shimx64.efi'

# --- Set boot order preference (Arch first, then Windows, then everything else) ---
echo "[EFI-CLEANUP] Setting Arch (SecureBoot) as primary boot, Windows second..."
ARCH_NUM=$(efibootmgr | awk '/Arch \(SecureBoot\)/{print substr($1,5,4); exit}')
WIN_NUM=$(efibootmgr | awk '/Windows Boot Manager/{print substr($1,5,4); exit}')
CURRENT_ORDER=$(efibootmgr | awk '/^BootOrder:/{print $2}')

# Keep every other entry (USB, PXE, other OSes) in its existing relative order.
NEW_ORDER=""
for num in $ARCH_NUM $WIN_NUM ${CURRENT_ORDER//,/ }; do
  [[ ",$NEW_ORDER," == *",$num,"* ]] || NEW_ORDER="${NEW_ORDER:+$NEW_ORDER,}$num"
done

if [[ -n "$NEW_ORDER" ]]; then
  efibootmgr -o "$NEW_ORDER"
  echo "[EFI-CLEANUP] BootOrder set to $NEW_ORDER"
else
  echo "[EFI-CLEANUP] No boot entries found to reorder!"
fi

echo "[EFI-CLEANUP] EFI cleanup and rebuild complete."
