#!/usr/bin/env bash
# grub-chroot-install.sh
# Fixes grub-install failures from live USB (/cow path error)
# by auto-detecting root/EFI partitions and chrooting into the target system.
#
# Usage:
#   sudo ./grub-chroot-install.sh
#
# Overrides (optional env vars):
#   ROOT_DEV=/dev/sdXY   – skip auto-detection for root partition
#   EFI_DEV=/dev/sdXZ    – skip auto-detection for EFI partition
#   DISK=/dev/sdX        – skip auto-detection for target disk (grub install target)
#   MOUNT_POINT=/mnt/foo – use a custom mount point (default: /mnt/recovery)

set -euo pipefail

MOUNT_POINT="${MOUNT_POINT:-/mnt/recovery}"

# ─── helpers ────────────────────────────────────────────────────────────────

info()  { echo -e "\e[32m[INFO]\e[0m  $*" >&2; }
warn()  { echo -e "\e[33m[WARN]\e[0m  $*" >&2; }
error() { echo -e "\e[31m[ERROR]\e[0m $*" >&2; }
die()   { error "$*"; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "Run as root: sudo $0"
}

settle_udev() {
  # Make sure all block device nodes are present before we probe them
  if command -v udevadm &>/dev/null; then
    info "Waiting for udev to settle..."
    udevadm settle --timeout=10 2>/dev/null || true
  fi
  # Re-read partition tables — guard with -b to avoid "not a block device"
  local disk
  for disk in /dev/sd? /dev/nvme?n?; do
    [[ -b "$disk" ]] || continue
    blockdev --rereadpt "$disk" 2>/dev/null || true
  done
}

cleanup() {
  info "Cleaning up mounts under $MOUNT_POINT ..."
  umount -R "$MOUNT_POINT" 2>/dev/null || true
}

# ─── detect firmware mode ────────────────────────────────────────────────────

detect_firmware() {
  if [[ -d /sys/firmware/efi ]]; then
    echo "uefi"
  else
    echo "bios"
  fi
}

# ─── find the linux root partition ───────────────────────────────────────────
# Scoped to partitions on a specific disk. Mounts each ext4/xfs/btrfs candidate
# (read-only) and checks for /etc/os-release.

find_root_partition() {
  local disk="$1"
  info "Scanning for Linux root partition on $disk..."

  local candidates
  candidates=$(lsblk -lnpo NAME,FSTYPE "$disk" | awk '$2 ~ /^(ext[234]|xfs|btrfs)$/ {printf "%s\n", $1}')

  local found=""
  for dev in $candidates; do
    dev=$(echo "$dev" | tr -d '[:space:]')
    if [[ ! -b "$dev" ]]; then
      warn "Skipping $dev — block device node missing (udev not settled?)"
      continue
    fi
    local tmp
    tmp=$(mktemp -d)
    if mount -o ro "$dev" "$tmp" 2>/dev/null; then
      if [[ -f "$tmp/etc/os-release" ]]; then
        umount "$tmp"
        rmdir "$tmp"
        found="$dev"
        break
      fi
      umount "$tmp"
    fi
    rmdir "$tmp" 2>/dev/null || true
  done

  echo "$found"
}

# ─── find the EFI system partition ───────────────────────────────────────────
# Scoped to partitions on a specific disk.

find_efi_partition() {
  local disk="$1"
  info "Scanning for EFI System Partition on $disk..."

  # Primary: match by GPT partition type GUID on the target disk only
  local esp
  esp=$(lsblk -lnpo NAME,PARTTYPE "$disk" | \
    awk 'tolower($2) == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" {printf "%s\n", $1}' | head -1 | tr -d '[:space:]')

  # Fallback: vfat partition on the target disk containing an /EFI directory
  if [[ -z "$esp" ]]; then
    local vfat_devs
    vfat_devs=$(lsblk -lnpo NAME,FSTYPE "$disk" | awk '$2=="vfat"{printf "%s\n", $1}')
    for dev in $vfat_devs; do
      dev=$(echo "$dev" | tr -d '[:space:]')
      if [[ ! -b "$dev" ]]; then
        warn "Skipping $dev — block device node missing"
        continue
      fi
      local tmp
      tmp=$(mktemp -d)
      if mount -o ro "$dev" "$tmp" 2>/dev/null; then
        if [[ -d "$tmp/EFI" ]]; then
          umount "$tmp"
          rmdir "$tmp"
          esp="$dev"
          break
        fi
        umount "$tmp"
      fi
      rmdir "$tmp" 2>/dev/null || true
    done
  fi

  echo "$esp"
}

# ─── derive the parent disk from a partition ─────────────────────────────────

disk_of() {
  # tr strips the trailing newline lsblk embeds in PKNAME output
  lsblk -npo PKNAME "$1" | tr -d '[:space:]'
}

# ─── find the largest (internal) disk, excluding the live USB ────────────────
# The live USB is almost always the smallest removable disk.
# Strategy: find which disk backs the current live / mount, then pick the
# largest *other* disk as the install target.

find_internal_disk() {
  # Disk that the running live session is on (backs /, /run/live, or /cdrom)
  local live_disk=""
  local live_part=""
  live_part=$(findmnt -nro SOURCE / 2>/dev/null | head -1 | tr -d '[:space:]') || true
  if [[ -n "$live_part" && -b "$live_part" ]]; then
    live_disk=$(lsblk -npo PKNAME "$live_part" 2>/dev/null | tr -d '[:space:]') || true
  fi

  # Pick the largest disk that is NOT the live disk
  # lsblk -d: disks only (no partitions), SIZE in bytes with -b
  local best_disk=""
  local best_size=0
  local dev=""
  local size=""
  while IFS= read -r line; do
    dev=$(echo "$line"  | awk '{print $1}' | tr -d '[:space:]')
    size=$(echo "$line" | awk '{print $2}' | tr -d '[:space:]')
    [[ -b "$dev" ]]              || continue
    [[ -n "$size" ]]             || continue
    [[ "$dev" != "$live_disk" ]] || continue
    if (( size > best_size )); then
      best_size=$size
      best_disk=$dev
    fi
  done < <(lsblk -bdnpo NAME,SIZE 2>/dev/null)

  echo "$best_disk"
}

# ─── mount everything needed for the chroot ──────────────────────────────────

do_mounts() {
  local root_dev="$1"
  local efi_dev="$2"
  local firmware="$3"

  info "Mounting $root_dev -> $MOUNT_POINT"
  mkdir -p "$MOUNT_POINT"
  mount "$root_dev" "$MOUNT_POINT"

  # EFI partition
  if [[ "$firmware" == "uefi" && -n "$efi_dev" ]]; then
    local efi_dir="$MOUNT_POINT/boot/efi"
    info "Mounting EFI partition $efi_dev -> $efi_dir"
    mkdir -p "$efi_dir"
    mount "$efi_dev" "$efi_dir"
  fi

  # Virtual filesystems required by grub-install
  for fs in dev dev/pts proc sys run; do
    info "Bind-mounting /$fs"
    mkdir -p "$MOUNT_POINT/$fs"
    mount --bind "/$fs" "$MOUNT_POINT/$fs"
  done

  # efivarfs (UEFI only)
  if [[ "$firmware" == "uefi" ]]; then
    local efivars="$MOUNT_POINT/sys/firmware/efi/efivars"
    if [[ -d /sys/firmware/efi/efivars ]]; then
      info "Mounting efivarfs"
      mkdir -p "$efivars"
      mount --bind /sys/firmware/efi/efivars "$efivars" 2>/dev/null || \
        mount -t efivarfs efivarfs "$efivars" 2>/dev/null || \
        warn "Could not mount efivarfs — UEFI variable writes may fail"
    fi
  fi
}

# ─── run grub-install + update-grub inside the chroot ────────────────────────

run_grub() {
  local disk="$1"
  local firmware="$2"

  info "Running grub-install inside chroot (firmware=$firmware, disk=$disk)..."

  if [[ "$firmware" == "uefi" ]]; then
    chroot "$MOUNT_POINT" grub-install \
      --target=x86_64-efi \
      --efi-directory=/boot/efi \
      --bootloader-id=ubuntu \
      --recheck
  else
    chroot "$MOUNT_POINT" grub-install --recheck "$disk"
  fi

  info "Running update-grub..."
  chroot "$MOUNT_POINT" update-grub

  info "grub-install completed successfully."
}

# ─── main ────────────────────────────────────────────────────────────────────

main() {
  require_root
  trap cleanup EXIT

  settle_udev

  local firmware
  firmware=$(detect_firmware)
  info "Firmware mode detected: $firmware"

  # Target disk — detect first so partition scans are scoped to it
  local disk="${DISK:-}"
  if [[ -z "$disk" ]]; then
    disk=$(find_internal_disk)
    [[ -n "$disk" ]] || die \
      "Could not detect internal disk. Override with:  sudo DISK=/dev/sdX $0"
  fi
  info "Target disk: $disk"
  local root_dev="${ROOT_DEV:-}"
  if [[ -z "$root_dev" ]]; then
    root_dev=$(find_root_partition "$disk")
    [[ -n "$root_dev" ]] || die \
      "Could not auto-detect root partition on $disk.\n" \
      "Override with:  sudo ROOT_DEV=/dev/sdXY $0"
  fi
  info "Root partition: $root_dev"

  # EFI partition — allow env override, scoped to the internal disk
  local efi_dev="${EFI_DEV:-}"
  if [[ "$firmware" == "uefi" && -z "$efi_dev" ]]; then
    efi_dev=$(find_efi_partition "$disk")
    if [[ -z "$efi_dev" ]]; then
      warn "Could not auto-detect EFI partition on $disk. Continuing — may fail on UEFI."
    else
      info "EFI partition: $efi_dev"
    fi
  fi

  # Summary + confirmation
  echo ""
  echo "  ┌─────────────────────────────────────────┐"
  echo "  │           grub-chroot-install            │"
  echo "  ├─────────────────────────────────────────┤"
  printf "  │  Root partition : %-22s│\n" "$root_dev"
  [[ -n "$efi_dev" ]] && printf "  │  EFI partition  : %-22s│\n" "$efi_dev"
  printf "  │  Disk           : %-22s│\n" "$disk"
  printf "  │  Firmware       : %-22s│\n" "$firmware"
  printf "  │  Mount point    : %-22s│\n" "$MOUNT_POINT"
  echo "  └─────────────────────────────────────────┘"
  echo ""
  read -rp "Proceed? [y/N] " confirm
  [[ "${confirm,,}" == "y" ]] || die "Aborted."

  do_mounts "$root_dev" "$efi_dev" "$firmware"
  run_grub  "$disk"     "$firmware"

  echo ""
  info "All done. Safe to reboot."
}

main "$@"
