#!/bin/bash
 
# Array of missing files
missing_files=(
  "/lib/systemd/systemd-networkd"
  "/lib/systemd/systemd-resolved"
  "/sbin/agetty"
  "/sbin/modprobe"
  "/usr/bin/chattr"
  "/usr/bin/plymouth"
  "/usr/bin/savelog"
  "/usr/bin/sensors"
  "./-udevadm"
  "/lib/ufw/ufw-init"
  "/opt/google/chrome-remote-desktop/chrome-remote-desktop"
  "/run/lxd_agent/lxd-agent"
  "/usr/lib/snapd/snapd-aa-prompt-listener"
  "/usr/libexec/blueman-mechanism"
  "/usr/sbin/netplan"
  "/usr/share/unattended-upgrades/unattended-upgrade-shutdown"
  "/usr/bin/dbus-daemon"
)
 
for file in "${missing_files[@]}"; do
  echo "Processing file: $file"
  # Find the package name using dpkg-query and apt-file
  package=$(dpkg-query -S "$file" 2>/dev/null | cut -d: -f1)
  if [ -z "$package" ]; then
    package=$(apt-file search "$file" 2>/dev/null | cut -d: -f1 | head -n 1)
  fi
  if [ -n "$package" ]; then
    echo "Reinstalling package: $package"
    sudo apt-get install --reinstall -y "$package"
  else
    echo "Package not found for file: $file"
  fi
done

