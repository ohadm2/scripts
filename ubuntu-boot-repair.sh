#!/usr/bin/env bash
# ubuntu-boot-repair.sh
# Detect and fix common Ubuntu startup/boot problems from a live USB (or in place).
#
# What it repairs:
#   • Broken/missing GRUB bootloader        (grub-install)
#   • Missing/stale GRUB menu               (update-grub)
#   • Broken initramfs / missing modules    (update-initramfs -u -k all)
#   • Corrupt root/EFI filesystem           (fsck, chroot mode only)
#   • Missing UEFI NVRAM boot entry         (grub-install --recheck on UEFI)
#
# Usage:
#   sudo ./ubuntu-boot-repair.sh                 # auto-detect everything
#   sudo ./ubuntu-boot-repair.sh --yes           # skip the confirmation prompt
#   sudo ./ubuntu-boot-repair.sh --no-fsck       # don't run fsck
#   sudo ./ubuntu-boot-repair.sh --removable     # also install to \EFI\BOOT fallback
#                                                # (fixes firmware "boot device not found")
#   sudo ROOT_DEV=/dev/nvme0n1p5 ./ubuntu-boot-repair.sh
#
# Overrides (env vars):
#   ROOT_DEV=/dev/XXX     skip root auto-detection
#   DISK=/dev/XXX         grub-install target disk (BIOS mode); default = disk holding root
#   MOUNT_POINT=/mnt/foo  chroot mount point (default: /mnt/boot-repair)
#
# NOTE: reads the target's /etc/fstab to locate /boot and /boot/efi, so it works
# regardless of partition numbering (GPT, MBR+extended, nvme, etc).

set -euo pipefail

MOUNT_POINT="${MOUNT_POINT:-/mnt/boot-repair}"
ASSUME_YES=0
DO_FSCK=1
REMOVABLE=0

# ─── logging (ALWAYS to stderr so $(func) capture stays clean) ────────────────

info()  { echo -e "\e[32m[INFO]\e[0m  $*" >&2; }
warn()  { echo -e "\e[33m[WARN]\e[0m  $*" >&2; }
error() { echo -e "\e[31m[ERROR]\e[0m $*" >&2; }
die()   { error "$*"; exit 1; }

# ─── arg parsing ──────────────────────────────────────────────────────────────

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes)      ASSUME_YES=1 ;;
      --no-fsck)     DO_FSCK=0 ;;
      --removable)   REMOVABLE=1 ;;
      -h|--help)     grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *)             die "Unknown argument: $1 (try --help)" ;;
    esac
    shift
  done
}

require_root() { [[ $EUID -eq 0 ]] || die "Run as root: sudo $0"; }

# ─── prep block devices ───────────────────────────────────────────────────────

settle_udev() {
  if command -v udevadm &>/dev/null; then
    info "Waiting for udev to settle..."
    udevadm settle --timeout=10 2>/dev/null || true
  fi
}

# ─── firmware mode ─────────────────────────────────────────────────────────────

detect_firmware() {
  [[ -d /sys/firmware/efi ]] && echo "uefi" || echo "bios"
}

# ─── mount a filesystem read-only, tolerating a dirty ext journal ────────────────
# Prints the tmp mountpoint on success (stdout); returns non-zero on failure.

try_mount_ro() {
  local dev="$1" fstype="$2" tmp
  tmp=$(mktemp -d)
  # ext* with an unclean journal refuses a plain -o ro mount; noload skips replay.
  if [[ "$fstype" == ext* ]]; then
    if mount -o ro,noload "$dev" "$tmp" 2>/dev/null || mount -o ro "$dev" "$tmp" 2>/dev/null; then
      echo "$tmp"; return 0
    fi
  else
    if mount -o ro "$dev" "$tmp" 2>/dev/null; then
      echo "$tmp"; return 0
    fi
  fi
  rmdir "$tmp" 2>/dev/null || true
  return 1
}

# ─── is this partition part of the running LIVE medium? ──────────────────────────

is_live_medium() {
  local dev="$1" mp
  mp=$(lsblk -no MOUNTPOINT "$dev" 2>/dev/null | tr -d '[:space:]')
  case "$mp" in
    /|/cdrom|/isodevice|/run/live/*|/rofs) return 0 ;;
  esac
  return 1
}

# ─── find every plausible Ubuntu/Linux root partition on the system ──────────────
# Scans ALL disks (not just the largest). A root must contain /etc/os-release
# and /etc/fstab. Prints one device per line.

find_root_candidates() {
  info "Scanning all disks for a Linux root filesystem..."
  local line dev fstype tmp found=()

  while IFS= read -r line; do
    dev=$(awk '{print $1}' <<<"$line")
    fstype=$(awk '{print $2}' <<<"$line")
    [[ -b "$dev" ]] || continue
    is_live_medium "$dev" && { info "Skipping live medium $dev"; continue; }

    if tmp=$(try_mount_ro "$dev" "$fstype"); then
      if [[ -f "$tmp/etc/os-release" && -f "$tmp/etc/fstab" ]]; then
        info "Found root candidate: $dev ($(sed -n 's/^PRETTY_NAME=//p' "$tmp/etc/os-release" | tr -d '\"'))"
        found+=("$dev")
      fi
      umount "$tmp" 2>/dev/null || true
      rmdir "$tmp" 2>/dev/null || true
    fi
  done < <(lsblk -lnpo NAME,FSTYPE | awk '$2 ~ /^(ext[234]|xfs|btrfs)$/')

  # Only emit when non-empty, otherwise mapfile would capture a stray blank line.
  (( ${#found[@]} )) && printf '%s\n' "${found[@]}"
}

# ─── pick a single root (prompt if several) ──────────────────────────────────────

choose_root() {
  local candidates=("$@")
  local n=${#candidates[@]}
  if (( n == 0 )); then
    return 1
  elif (( n == 1 )); then
    echo "${candidates[0]}"; return 0
  fi
  warn "Multiple Linux installations found:"
  local i
  for i in "${!candidates[@]}"; do
    printf "   [%d] %s\n" "$((i+1))" "${candidates[$i]}" >&2
  done
  local sel
  read -rp "Select the root partition to repair [1-$n]: " sel
  [[ "$sel" =~ ^[0-9]+$ ]] && (( sel>=1 && sel<=n )) || die "Invalid selection."
  echo "${candidates[$((sel-1))]}"
}

# ─── resolve an fstab spec (UUID=/LABEL=/PARTUUID=//dev/..) to a device node ──────

resolve_spec() {
  local spec="$1"
  case "$spec" in
    UUID=*|LABEL=*|PARTUUID=*|PARTLABEL=*) findfs "$spec" 2>/dev/null || true ;;
    /dev/*)                                echo "$spec" ;;
    *)                                     echo "" ;;
  esac
}

# ─── parent disk of a partition ───────────────────────────────────────────────────

disk_of() { lsblk -npo PKNAME "$1" 2>/dev/null | head -1 | tr -d '[:space:]'; }

# ─── optional fsck of an UNMOUNTED filesystem ─────────────────────────────────────

fsck_dev() {
  local dev="$1"
  info "Running filesystem check on $dev ..."
  # -y: auto-repair. fsck dispatches to the right fs helper by superblock.
  fsck -y "$dev" || warn "fsck on $dev returned non-zero (may have fixed errors)."
}

# ─── mount root + fstab-declared /boot and /boot/efi + virtual filesystems ─────────

MOUNTED_EXTRA=()   # track for teardown ordering

do_mounts() {
  local root_dev="$1"

  info "Mounting root $root_dev -> $MOUNT_POINT"
  mkdir -p "$MOUNT_POINT"
  mount "$root_dev" "$MOUNT_POINT"

  # Parse target /etc/fstab for /boot and /boot/efi, mount shallowest first.
  if [[ -f "$MOUNT_POINT/etc/fstab" ]]; then
    local spec mp rest dev
    # sort by mountpoint length so /boot mounts before /boot/efi
    while read -r mp spec; do
      dev=$(resolve_spec "$spec")
      if [[ -z "$dev" || ! -b "$dev" ]]; then
        warn "fstab entry for $mp -> '$spec' could not be resolved; skipping."
        continue
      fi
      info "Mounting $dev -> $MOUNT_POINT$mp (from fstab)"
      mkdir -p "$MOUNT_POINT$mp"
      if mount "$dev" "$MOUNT_POINT$mp"; then
        MOUNTED_EXTRA+=("$MOUNT_POINT$mp")
      else
        warn "Could not mount $dev at $mp"
      fi
    done < <(awk '$1!~/^#/ && ($2=="/boot" || $2=="/boot/efi"){print length($2), $2, $1}' \
                 "$MOUNT_POINT/etc/fstab" | sort -n | awk '{print $2, $3}')
  fi

  # Virtual filesystems required by grub-install / update-initramfs.
  local fs
  for fs in dev dev/pts proc sys run; do
    mkdir -p "$MOUNT_POINT/$fs"
    mount --bind "/$fs" "$MOUNT_POINT/$fs"
    MOUNTED_EXTRA+=("$MOUNT_POINT/$fs")
  done

  # efivarfs (UEFI only) — needed to write the NVRAM boot entry.
  if [[ -d /sys/firmware/efi/efivars ]]; then
    local ev="$MOUNT_POINT/sys/firmware/efi/efivars"
    mkdir -p "$ev"
    mount --bind /sys/firmware/efi/efivars "$ev" 2>/dev/null \
      || mount -t efivarfs efivarfs "$ev" 2>/dev/null \
      || warn "Could not mount efivarfs — UEFI variable writes may fail."
  fi
}

cleanup() {
  info "Unmounting everything under $MOUNT_POINT ..."
  # -R recursive handles nested binds/efivars/boot in the right order.
  umount -R "$MOUNT_POINT" 2>/dev/null || true
}

# ─── run the actual repairs inside the chroot ─────────────────────────────────────

run_repairs() {
  local disk="$1" firmware="$2"

  info "Repair 1/3 — reinstalling GRUB (firmware=$firmware)"
  if [[ "$firmware" == "uefi" ]]; then
    chroot "$MOUNT_POINT" grub-install \
      --target=x86_64-efi --efi-directory=/boot/efi \
      --bootloader-id=ubuntu --recheck
    if [[ "$REMOVABLE" == 1 ]]; then
      info "Also installing GRUB to the removable/fallback path (\\EFI\\BOOT\\BOOTX64.EFI)"
      # Firmware that ignores or drops NVRAM entries still boots this path.
      chroot "$MOUNT_POINT" grub-install \
        --target=x86_64-efi --efi-directory=/boot/efi \
        --removable --recheck
    fi
  else
    [[ -n "$disk" ]] || die "BIOS mode needs a target disk (set DISK=/dev/XXX)."
    chroot "$MOUNT_POINT" grub-install --target=i386-pc --recheck "$disk"
  fi

  info "Repair 2/3 — regenerating GRUB config (update-grub)"
  chroot "$MOUNT_POINT" update-grub

  info "Repair 3/3 — rebuilding initramfs (update-initramfs -u -k all)"
  chroot "$MOUNT_POINT" update-initramfs -u -k all || \
    warn "update-initramfs returned non-zero; check output above."

  info "All repairs completed."

  # Show the firmware boot entries so you can confirm/adjust boot order.
  if [[ "$firmware" == "uefi" ]] && command -v efibootmgr &>/dev/null; then
    info "Current UEFI boot entries (efibootmgr -v):"
    efibootmgr -v >&2 || warn "efibootmgr could not read NVRAM (efivars not mounted?)."
  fi
}

# ─── main ──────────────────────────────────────────────────────────────────────

main() {
  parse_args "$@"
  require_root
  trap cleanup EXIT
  settle_udev

  local firmware; firmware=$(detect_firmware)
  info "Firmware mode: $firmware"

  # 1. Root partition
  local root_dev="${ROOT_DEV:-}"
  if [[ -z "$root_dev" ]]; then
    local candidates=()
    mapfile -t candidates < <(find_root_candidates)
    root_dev=$(choose_root "${candidates[@]}") \
      || die "No Ubuntu/Linux root partition found. Override with: sudo ROOT_DEV=/dev/XXX $0"
  fi
  [[ -b "$root_dev" ]] || die "Root device $root_dev is not a block device."
  info "Root partition: $root_dev"

  # 2. Target disk (for BIOS grub-install; on UEFI grub uses the ESP)
  local disk="${DISK:-}"
  [[ -z "$disk" ]] && disk=$(disk_of "$root_dev")
  info "Target disk: ${disk:-<n/a>}"

  # 3. Confirm
  echo "" >&2
  echo "  ┌──────────────────────────────────────────┐" >&2
  echo "  │            ubuntu-boot-repair             │" >&2
  echo "  ├──────────────────────────────────────────┤" >&2
  printf "  │  Root partition : %-23s│\n" "$root_dev"        >&2
  printf "  │  Target disk    : %-23s│\n" "${disk:-<n/a>}"   >&2
  printf "  │  Firmware       : %-23s│\n" "$firmware"        >&2
  printf "  │  fsck           : %-23s│\n" "$([[ $DO_FSCK == 1 ]] && echo enabled || echo disabled)" >&2
  printf "  │  Mount point    : %-23s│\n" "$MOUNT_POINT"     >&2
  echo "  └──────────────────────────────────────────┘" >&2
  echo "" >&2
  if [[ "$ASSUME_YES" != 1 ]]; then
    local confirm
    read -rp "Proceed with repair? [y/N] " confirm
    [[ "${confirm,,}" == "y" ]] || die "Aborted."
  fi

  # 4. fsck root while it is still unmounted
  if [[ "$DO_FSCK" == 1 ]]; then
    fsck_dev "$root_dev"
  fi

  # 5. Mount + chroot repairs
  do_mounts "$root_dev"
  run_repairs "$disk" "$firmware"

  echo "" >&2
  info "Done. Unmounting and exiting — you can reboot now."
}

main "$@"
