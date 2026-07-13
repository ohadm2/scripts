#!/bin/bash
# basic-chroot.sh — Mount a target root partition and chroot into it for repair.
#
# Usage:
#   sudo ./basic-chroot.sh [/dev/sdXN]         # interactive repair shell (default)
#   sudo ./basic-chroot.sh [/dev/sdXN] --grub  # auto-reinstall GRUB then drop to shell
#
# If no device is given, the script tries to auto-detect the root partition.

set -euo pipefail

MNT="${MNT:-/mnt/chroot-repair}"
DISK=""          # parent disk (for BIOS grub-install)
ROOT_DEV=""      # root partition
MODE="shell"     # default: interactive shell

# ─── helpers ──────────────────────────────────────────────────────────────────
info()  { echo -e "\e[32m[*]\e[0m $*"; }
warn()  { echo -e "\e[33m[!]\e[0m $*"; }
error() { echo -e "\e[31m[!]\e[0m $*"; }
die()   { error "$*"; exit 1; }

usage() {
    echo "Usage: sudo $0 [/dev/sdXN] [--grub]"
    echo ""
    echo "  /dev/sdXN   Root partition to mount (auto-detected if omitted)"
    echo "  --grub      Reinstall GRUB automatically, then drop to shell"
    echo ""
    echo "  Env overrides: MNT=/mnt/somewhere"
    exit 0
}

# ─── parse args ───────────────────────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        /dev/*)   ROOT_DEV="$arg" ;;
        --grub)   MODE="grub" ;;
        -h|--help) usage ;;
        *) die "Unknown argument: $arg" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "Run as root: sudo $0 $*"

# ─── auto-detect root partition if not specified ──────────────────────────────
if [[ -z "$ROOT_DEV" ]]; then
    info "No device specified — scanning for Linux root partitions..."
    # Exclude the live session's disk
    live_disk=$(lsblk -no PKNAME "$(findmnt -nro SOURCE / 2>/dev/null | head -1)" 2>/dev/null | head -1 | tr -d '[:space:]')

    candidates=()
    while IFS= read -r dev; do
        # Skip partitions on the live disk
        pk=$(lsblk -no PKNAME "$dev" 2>/dev/null | head -1 | tr -d '[:space:]')
        [[ "$pk" == "$live_disk" ]] && continue
        candidates+=("$dev")
    done < <(lsblk -lnpo NAME,FSTYPE,TYPE | awk '$3=="part" && ($2=="ext4" || $2=="ext3" || $2=="btrfs" || $2=="xfs"){print $1}')

    if [[ ${#candidates[@]} -eq 0 ]]; then
        die "No Linux partitions found. Specify explicitly: sudo $0 /dev/sdXN"
    elif [[ ${#candidates[@]} -eq 1 ]]; then
        ROOT_DEV="${candidates[0]}"
        info "Auto-detected: $ROOT_DEV"
    else
        warn "Multiple Linux partitions found:"
        for i in "${!candidates[@]}"; do
            size=$(lsblk -dno SIZE "${candidates[$i]}" 2>/dev/null | tr -d '[:space:]')
            fs=$(lsblk -dno FSTYPE "${candidates[$i]}" 2>/dev/null | tr -d '[:space:]')
            printf "   [%d] %-20s %s  %s\n" "$((i+1))" "${candidates[$i]}" "$size" "$fs"
        done
        read -rp "Select [1-${#candidates[@]}]: " sel
        [[ "$sel" =~ ^[0-9]+$ ]] && (( sel>=1 && sel<=${#candidates[@]} )) || die "Invalid selection."
        ROOT_DEV="${candidates[$((sel-1))]}"
    fi
fi

[[ -b "$ROOT_DEV" ]] || die "$ROOT_DEV is not a block device."

# Determine the parent disk (for BIOS grub-install)
DISK="/dev/$(lsblk -no PKNAME "$ROOT_DEV" 2>/dev/null | head -1 | tr -d '[:space:]')"
[[ -b "$DISK" ]] || DISK=""

# ─── mount the root partition ─────────────────────────────────────────────────
info "Mounting $ROOT_DEV at $MNT"
mkdir -p "$MNT"

if mountpoint -q "$MNT"; then
    warn "$MNT is already mounted — using as-is."
else
    mount "$ROOT_DEV" "$MNT" || die "Failed to mount $ROOT_DEV at $MNT"
fi

# ─── cleanup on exit ─────────────────────────────────────────────────────────
cleanup() {
    info "Unmounting..."
    # Unmount in reverse order; lazy unmount in case something is held
    for mp in "$MNT/sys/firmware/efi/efivars" "$MNT/run" "$MNT/sys" "$MNT/dev/pts" "$MNT/proc" "$MNT/dev" "$MNT/boot/efi" "$MNT"; do
        mountpoint -q "$mp" 2>/dev/null && umount -l "$mp" 2>/dev/null || true
    done
    info "Done."
}
trap cleanup EXIT

# ─── bind system directories ─────────────────────────────────────────────────
info "Binding system directories..."
for fs in dev dev/pts proc sys run; do
    mkdir -p "$MNT/$fs"
    if ! mountpoint -q "$MNT/$fs"; then
        mount --bind "/$fs" "$MNT/$fs"
    fi
done

# EFI vars if applicable
if [[ -d /sys/firmware/efi/efivars ]]; then
    mkdir -p "$MNT/sys/firmware/efi/efivars"
    mount --bind /sys/firmware/efi/efivars "$MNT/sys/firmware/efi/efivars" 2>/dev/null || true
fi

# ─── mount /boot/efi if target has an ESP in fstab ────────────────────────────
if [[ -f "$MNT/etc/fstab" ]]; then
    efi_spec=$(awk '$1!~/^#/ && $2=="/boot/efi"{print $1}' "$MNT/etc/fstab" | head -1)
    if [[ -n "$efi_spec" ]]; then
        efi_dev=""
        case "$efi_spec" in
            UUID=*|LABEL=*|PARTUUID=*) efi_dev=$(findfs "$efi_spec" 2>/dev/null || true) ;;
            /dev/*) efi_dev="$efi_spec" ;;
        esac
        if [[ -n "$efi_dev" && -b "$efi_dev" ]]; then
            mkdir -p "$MNT/boot/efi"
            if ! mountpoint -q "$MNT/boot/efi"; then
                mount "$efi_dev" "$MNT/boot/efi" && info "Mounted ESP: $efi_dev -> /boot/efi"
            fi
        fi
    fi
fi

# ─── DNS resolution ──────────────────────────────────────────────────────────
if [[ -L "$MNT/etc/resolv.conf" ]]; then
    # Dangling symlink from systemd-resolved; replace with working copy
    rm -f "$MNT/etc/resolv.conf"
fi
if [[ -r /run/systemd/resolve/resolv.conf ]]; then
    cp -f /run/systemd/resolve/resolv.conf "$MNT/etc/resolv.conf"
elif [[ -r /etc/resolv.conf ]]; then
    grep -v '127.0.0.53' /etc/resolv.conf > "$MNT/etc/resolv.conf" 2>/dev/null || true
fi
# Ensure at least something is there
if ! grep -q '^nameserver' "$MNT/etc/resolv.conf" 2>/dev/null; then
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$MNT/etc/resolv.conf"
fi

# ─── GRUB mode: auto-reinstall ───────────────────────────────────────────────
if [[ "$MODE" == "grub" ]]; then
    info "Reinstalling GRUB inside chroot..."
    chroot "$MNT" /bin/bash -c "
        set -e
        if [ -d /sys/firmware/efi ]; then
            echo '[*] EFI mode'
            grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck || echo '[!] grub-install failed'
        else
            echo '[*] BIOS mode'
            grub-install '${DISK}' || echo '[!] grub-install failed'
        fi
        update-grub || echo '[!] update-grub failed'
        update-initramfs -u -k all || echo '[!] update-initramfs failed'
    " || warn "GRUB reinstall had errors."
    info "GRUB reinstall done. Dropping to shell for any further fixes..."
fi

# ─── interactive shell with suggested commands ────────────────────────────────
info "Entering chroot at $MNT (root: $ROOT_DEV, disk: ${DISK:-unknown})"
echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │              Chroot Repair Shell                            │"
echo "  ├─────────────────────────────────────────────────────────────┤"
echo "  │  Suggested repair commands:                                 │"
echo "  │                                                             │"
echo "  │  apt update && apt upgrade              # update packages   │"
echo "  │  apt --fix-broken install               # fix broken deps   │"
echo "  │  dpkg --configure -a                    # repair dpkg       │"
echo "  │  update-grub                            # regenerate grub   │"
echo "  │  grub-install /dev/sdX                  # reinstall grub    │"
echo "  │  update-initramfs -u -k all             # rebuild initramfs │"
echo "  │  passwd <user>                          # reset password    │"
echo "  │  ln -sf /lib/systemd/system/NetworkManager.service \\        │"
echo "  │    /etc/systemd/system/multi-user.target.wants/            │"
echo "  │                                  # enable NetworkManager   │"
echo "  │                                                             │"
echo "  │  Type 'exit' or Ctrl-D to leave chroot.                    │"
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""

# Find a shell in the target
SHELL_BIN=""
for s in /bin/bash /usr/bin/bash /bin/sh /usr/bin/sh; do
    [[ -x "$MNT$s" ]] && { SHELL_BIN="$s"; break; }
done
[[ -n "$SHELL_BIN" ]] || die "No shell found in target. System is too damaged — use a full recovery tool."

PS1='(chroot) \u@\h:\w# ' chroot "$MNT" "$SHELL_BIN" || true

info "Left chroot. Cleanup will unmount automatically."
