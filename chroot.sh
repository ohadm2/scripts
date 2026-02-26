#!/bin/bash
# chroot-rescue.sh - Mount and chroot into a system partition
# Usage: ./chroot-rescue.sh [/dev/sdXY]
# If no partition is given, auto-detects the largest Linux partition.

set -e

DIR=/media/rescue

mkdir -p "$DIR"

if [ "$1" ]; then
  PART="$1"
else
  # Find the largest non-mounted Linux partition
  # First try: partitions with known Linux filesystems
  # Fallback: largest unmounted partition >10G (FSTYPE may be blank if not probed)
  PART=$(lsblk -lnpo NAME,SIZE,FSTYPE,MOUNTPOINT,TYPE \
    | awk '$5 == "part" && $1 !~ /loop|mapper/ && $4 == "" && $3 ~ /ext4|xfs|btrfs/ {print $2, $1}' \
    | sort -h | tail -1 | awk '{print $2}')

  if [ -z "$PART" ]; then
    PART=$(lsblk -lnpo NAME,SIZE,FSTYPE,MOUNTPOINT,TYPE \
      | awk '$5 == "part" && $1 !~ /loop|mapper/ && $4 == "" && $3 !~ /vfat|swap|ntfs/ {
          gsub(/[^0-9.]/, "", $2); if ($2+0 > 10) print $2, $1
        }' \
      | sort -h | tail -1 | awk '{print $2}')
  fi

  if [ -z "$PART" ]; then
    echo "ERROR: No unmounted Linux partition found."
    echo "Usage: $0 /dev/sdXY"
    exit 1
  fi
  echo "Auto-detected partition: $PART"
fi

echo "Mounting $PART on $DIR..."
mount "$PART" "$DIR"

# Mount EFI partition if found
EFI=$(lsblk -lnpo NAME,FSTYPE,MOUNTPOINT | awk '$2 == "vfat" && $3 == "" {print $1; exit}')
if [ "$EFI" ] && [ -d "$DIR/boot/efi" ]; then
  echo "Mounting EFI partition: $EFI"
  mount "$EFI" "$DIR/boot/efi"
fi

# Bind-mount virtual filesystems
mount -o bind /dev "$DIR/dev"
mount -o bind /run "$DIR/run"
mount -t proc proc "$DIR/proc"
mount -t sysfs sys "$DIR/sys"

echo "Entering chroot... (type 'exit' to leave)"
chroot "$DIR" /bin/bash

# Cleanup on exit
echo "Cleaning up mounts..."
umount -l "$DIR/dev" "$DIR/run" "$DIR/proc" "$DIR/sys" 2>/dev/null
[ "$EFI" ] && umount -l "$DIR/boot/efi" 2>/dev/null
umount -l "$DIR" 2>/dev/null
echo "Done."
