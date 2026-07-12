#!/bin/bash
set -e

MNT="/mnt"
DISK="/dev/sda"

echo "[*] Binding system directories..."
mount --bind /dev "$MNT/dev"
mount --bind /proc "$MNT/proc"
mount --bind /sys "$MNT/sys"

if [ -d "$MNT/boot/efi" ]; then
    echo "[*] EFI system detected, binding EFI..."
    mount --bind /run "$MNT/run" 2>/dev/null || true
fi

echo "[*] Entering chroot..."
chroot "$MNT" /bin/bash <<'EOF'
set -e

echo "[*] Detecting package manager..."
if command -v apt >/dev/null 2>&1; then
    echo "[*] Using apt…"
    # apt update may fail if network or sources are broken — don't exit chroot
    apt update || echo "[!] apt update failed, continuing anyway"
elif command -v pacman >/dev/null 2>&1; then
    echo "[*] Using pacman…"
    pacman -Sy || echo "[!] pacman -Sy failed, continuing anyway"
elif command -v dnf >/dev/null 2>&1; then
    echo "[*] Using dnf…"
    dnf makecache || echo "[!] dnf makecache failed, continuing anyway"
else
    echo "[!] No known package manager found"
fi

echo "[*] Reinstalling GRUB..."
if [ -d /sys/firmware/efi ]; then
    echo "[*] EFI mode detected"
    if grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB; then
        echo "[*] GRUB installed (EFI)"
    else
        echo "[!] grub-install failed in EFI mode"
    fi
else
    echo "[*] BIOS mode detected"
    if grub-install "$DISK"; then
        echo "[*] GRUB installed (BIOS)"
    else
        echo "[!] grub-install failed in BIOS mode"
    fi
fi

echo "[*] Generating GRUB config..."
if grub-mkconfig -o /boot/grub/grub.cfg; then
    echo "[*] GRUB config generated"
else
    echo "[!] grub-mkconfig failed"
fi

EOF

echo "[*] Unmounting..."
umount -l "$MNT/dev"
umount -l "$MNT/proc"
umount -l "$MNT/sys"
if mountpoint -q "$MNT/run"; then umount -l "$MNT/run"; fi

echo "[*] GRUB reinstall complete."
