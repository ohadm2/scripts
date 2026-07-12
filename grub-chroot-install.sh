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
#   MOUNT_POINT=/mnt/foo – use a custom mount point (default: /mnt/recovery)

set -euo pipefail

MOUNT_POINT="${MOUNT_POINT:-/mnt/recovery}"

# ─── helpers ────────────────────────────────────────────────────────────────

info()  { echo -e "\e[32m[INFO]\e[0m  $*"; }
warn()  { echo -e "\e[33m[WARN]\e[0m  $*"; }
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
  # Re-read partition tables in case the kernel missed them
  for disk in /dev/sd? /dev/nvme?n?; do
    [[ -b "$disk" ]] && blockdev --rereadpt "$disk" 2>/dev/null || true
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
# Mounts each ext4/xfs/btrfs candidate (read-only) and checks for /etc/os-release.

find_root_partition() {
  info "Scanning for Linux root partition..."

  local candidates
  # Use printf to strip any stray whitespace/carriage-returns from lsblk output
  candidates=$(lsblk -lnpo NAME,FSTYPE | awk '$2 ~ /^(ext[234]|xfs|btrfs)$/ {printf "%s\n", $1}')

  local found=""
  for dev in $candidates; do
    # Guard: must be an actual block device node — lsblk can list things udev
    # hasn't materialised yet, which causes "not a block device" errors.
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

find_efi_partition() {
  info "Scanning for EFI System Partition..."

  # Primary: match by GPT partition type GUID
  local esp
  esp=$(lsblk -lnpo NAME,PARTTYPE | \
    awk 'tolower($2) == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" {printf "%s\n", $1}' | head -1)

  # Fallback: vfat partition containing an /EFI directory
  if [[ -z "$esp" ]]; then
    local vfat_devs
    vfat_devs=$(lsblk -lnpo NAME,FSTYPE | awk '$2=="vfat"{printf "%s\n", $1}')
    for dev in $vfat_devs; do
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
  lsblk -npo PKNAME "$1" | head -1
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
  for fs in dev dev/pts proc sys; do
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

  # Root partition — allow env override
  local root_dev="${ROOT_DEV:-}"
  if [[ -z "$root_dev" ]]; then
    root_dev=$(find_root_partition)
    [[ -n "$root_dev" ]] || die \
      "Could not auto-detect root partition.\n" \
      "Override with:  sudo ROOT_DEV=/dev/sdXY $0"
  fi
  info "Root partition: $root_dev"

  # EFI partition — allow env override
  local efi_dev="${EFI_DEV:-}"
  if [[ "$firmware" == "uefi" && -z "$efi_dev" ]]; then
    efi_dev=$(find_efi_partition)
    if [[ -z "$efi_dev" ]]; then
      warn "Could not auto-detect EFI partition. Continuing — may fail on UEFI."
    else
      info "EFI partition: $efi_dev"
    fi
  fi

  # Parent disk
  local disk
  disk=$(disk_of "$root_dev")
  info "Parent disk: $disk"

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
