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
ESP_DEV="$(findmnt -no SOURCE /boot)"
ESP_DISK="/dev/$(lsblk -no pkname "$ESP_DEV")"
ESP_PARTNUM="$(cat /sys/class/block/$(basename "$ESP_DEV")/partition)"

# Clear any existing Arch entries before recreating
for num in $(efibootmgr | awk '/Arch \(SecureBoot\)/{print substr($1,5,4)}'); do
  efibootmgr -b "$num" -B || true
done

# Register a fresh Arch entry pointing to shimx64.efi
efibootmgr -c -d "$ESP_DISK" -p "$ESP_PARTNUM" \
  -L "Arch (SecureBoot)" \
  -l '\EFI\arch\shimx64.efi'

# --- Set boot order preference (Arch first, then Windows) ---
echo "[EFI-CLEANUP] Setting Arch (SecureBoot) as primary boot, Windows second..."
ARCH_NUM=$(efibootmgr | awk '/Arch \(SecureBoot\)/{print substr($1,5,4); exit}')
WIN_NUM=$(efibootmgr | awk '/Windows Boot Manager/{print substr($1,5,4); exit}')

if [[ -n "$ARCH_NUM" && -n "$WIN_NUM" ]]; then
  efibootmgr -o "$ARCH_NUM,$WIN_NUM"
  echo "[EFI-CLEANUP] BootOrder set to Arch first, Windows second"
elif [[ -n "$ARCH_NUM" ]]; then
  efibootmgr -o "$ARCH_NUM"
  echo "[EFI-CLEANUP] BootOrder set to Arch only (Windows not found)"
elif [[ -n "$WIN_NUM" ]]; then
  efibootmgr -o "$WIN_NUM"
  echo "[EFI-CLEANUP] BootOrder set to Windows only (Arch not found)"
else
  echo "[EFI-CLEANUP] No Arch or Windows entries found to reorder!"
fi

echo "[EFI-CLEANUP] EFI cleanup and rebuild complete."
