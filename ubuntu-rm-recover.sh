#!/usr/bin/env bash
# ubuntu-rm-recover.sh
# Triage and recovery for a system where "rm -rf /" (or similar) was run.
#
# With internet + a working live session, even a "gutted" install is
# recoverable: missing apt keyrings are copied from the live system, apt
# sources are rewritten for the detected release, and the base system can be
# re-bootstrapped from the archive.
#
# Modes:
#   assess              Mount damaged root READ-ONLY, report what survived.
#   salvage  --dest DIR rsync surviving files to safe (external) storage.
#   netfix              Fix apt sources + networking (resolv, WiFi profiles) in chroot.
#   reinstall           Reinstall every installed package to restore deleted files
#                       (needs the package system to have survived).
#   rebuild             debootstrap a fresh base system from the archive (for the
#                       "package system gone" case). Preserves /home.
#   minimal             Install a minimal Ubuntu base (enough for apt + recovery
#                       modes) if apt is functional but the system is gutted.
#   recovery            Interactive recovery menu (like Ubuntu's boot recovery mode):
#                       resume, clean, dpkg, fsck, network, root, grub, system-summary.
#   shell               Mount + bind + chroot into the target for an interactive
#                       repair shell; auto-unmounts everything on exit.
#   fstab               Regenerate /etc/fstab (root + ESP + swap) by UUID.
#
# Usage:
#   sudo ./ubuntu-rm-recover.sh assess              [--root /dev/XXX]
#   sudo ./ubuntu-rm-recover.sh salvage --dest DIR  [--root /dev/XXX]
#   sudo ./ubuntu-rm-recover.sh netfix              [--root /dev/XXX]
#   sudo ./ubuntu-rm-recover.sh reinstall           [--root /dev/XXX] [--yes]
#   sudo ./ubuntu-rm-recover.sh rebuild             [--root /dev/XXX] [--yes]
#   sudo ./ubuntu-rm-recover.sh minimal             [--root /dev/XXX] [--yes]
#   sudo ./ubuntu-rm-recover.sh recovery            [--root /dev/XXX]
#   sudo ./ubuntu-rm-recover.sh shell               [--root /dev/XXX]
#   sudo ./ubuntu-rm-recover.sh fstab               [--root /dev/XXX]
#
# Overrides: ROOT_DEV=/dev/XXX  RELEASE_CODENAME=noble  MOUNT_POINT=/mnt/foo
#
# WARNING: 'reinstall'/'rebuild' WRITE to the disk and destroy any chance of
# undeleting files. If you need deleted data back, image the disk first
# (ddrescue) and run photorec/extundelete on the image.

set -euo pipefail

MODE=""
ROOT_DEV="${ROOT_DEV:-}"
DEST=""
ASSUME_YES=0
MOUNT_POINT="${MOUNT_POINT:-/mnt/rm-recover}"
RELEASE_CODENAME="${RELEASE_CODENAME:-}"

# ─── logging to stderr (keeps $(func) capture clean) ──────────────────────────
info()  { echo -e "\e[32m[INFO]\e[0m  $*" >&2; }
warn()  { echo -e "\e[33m[WARN]\e[0m  $*" >&2; }
error() { echo -e "\e[31m[ERROR]\e[0m $*" >&2; }
ok()    { echo -e "\e[32m  [OK]\e[0m $*" >&2; }
bad()   { echo -e "\e[31m  [--]\e[0m $*" >&2; }
die()   { error "$*"; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || die "Run as root: sudo $0"; }
usage() { grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; }

# ─── arg parsing ──────────────────────────────────────────────────────────────
parse_args() {
  [[ $# -gt 0 ]] || { usage; exit 1; }
  MODE="$1"; shift
  case "$MODE" in
    assess|salvage|netfix|reinstall|rebuild|minimal|recovery|shell|fstab) ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown mode '$MODE' (assess|salvage|netfix|reinstall|rebuild|minimal|recovery|shell|fstab)";;
  esac
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root)  ROOT_DEV="${2:?--root needs a device}"; shift ;;
      --dest)  DEST="${2:?--dest needs a directory}"; shift ;;
      -y|--yes) ASSUME_YES=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
    shift
  done
}

confirm() {  # confirm <prompt> <expected-word>
  [[ "$ASSUME_YES" == 1 ]] && return 0
  local reply; read -rp "$1 " reply
  [[ "$reply" == "$2" ]]
}

# ─── mounting ─────────────────────────────────────────────────────────────────
try_mount_ro() {
  local dev="$1" tmp; tmp=$(mktemp -d)
  if mount -o ro,noload "$dev" "$tmp" 2>/dev/null \
     || mount -o ro "$dev" "$tmp" 2>/dev/null; then
    echo "$tmp"; return 0
  fi
  rmdir "$tmp" 2>/dev/null || true; return 1
}

is_live_medium() {
  local mp; mp=$(lsblk -no MOUNTPOINT "$1" 2>/dev/null | tr -d '[:space:]')
  case "$mp" in /|/cdrom|/isodevice|/run/live/*|/rofs) return 0 ;; esac
  return 1
}

# ─── refuse writing modes against an in-use / live system ─────────────────────
# Writing modes must target an UNMOUNTED damaged disk (i.e. run from a live USB).
# If the chosen device — or any partition of its parent disk — is already
# mounted, we are almost certainly on a running system; fail safe.
assert_target_offline() {
  local dev="$1" disk here mounts
  here=$(findmnt -nro SOURCE / 2>/dev/null | head -1 | tr -d '[:space:]')

  # 1. the device itself mounted anywhere?
  mounts=$(findmnt -rno TARGET,SOURCE 2>/dev/null | awk -v d="$dev" '$2==d{print $1}')

  # 2. any sibling partition on the SAME disk mounted (root+/boot/efi of a live OS)?
  disk=$(lsblk -npo PKNAME "$dev" 2>/dev/null | head -1 | tr -d '[:space:]')
  if [[ -n "$disk" ]]; then
    local sib
    while IFS= read -r sib; do
      [[ -b "$sib" ]] || continue
      local m; m=$(findmnt -rno TARGET --source "$sib" 2>/dev/null | tr '\n' ' ')
      [[ -n "$m" ]] && mounts+=$'\n'"$sib -> $m"
    done < <(lsblk -lnpo NAME "$disk" 2>/dev/null | tail -n +2)
  fi

  if [[ -n "${mounts//[$'\n\t ']/}" ]]; then
    error "Refusing to run writing mode '$MODE': the target disk is currently IN USE."
    error "Mounted here:"
    while IFS= read -r line; do [[ -n "$line" ]] && error "    $line"; done <<<"$mounts"
    [[ "$here" == "$dev" ]] && error "    (it is the live root '/')"
    error ""
    error "Writing modes (netfix/reinstall/rebuild) must be run from a LIVE USB against"
    error "the UNMOUNTED damaged disk — never on a booted, working system."
    exit 1
  fi
}

BOUND=()   # track bind mounts for teardown
bind_chroot_fs() {
  local mp="$1" fs
  for fs in dev dev/pts proc sys run; do
    mkdir -p "$mp/$fs"
    mountpoint -q "$mp/$fs" || { mount --bind "/$fs" "$mp/$fs"; BOUND+=("$mp/$fs"); }
  done
  [[ -d /sys/firmware/efi/efivars ]] && {
    mkdir -p "$mp/sys/firmware/efi/efivars"
    mount --bind /sys/firmware/efi/efivars "$mp/sys/firmware/efi/efivars" 2>/dev/null || true
  }
}

# ─── resolve an fstab spec (UUID=/LABEL=/PARTUUID=//dev/..) to a device node ──
resolve_spec() {
  case "$1" in
    UUID=*|LABEL=*|PARTUUID=*|PARTLABEL=*) findfs "$1" 2>/dev/null || true ;;
    /dev/*)                                echo "$1" ;;
    *)                                     echo "" ;;
  esac
}

# ─── mount the target's /boot and /boot/efi as declared in its fstab ─────────
# Needed so an installed kernel + grub land on the real partitions (esp. the ESP).
mount_target_boot() {
  local mp="$1"
  [[ -f "$mp/etc/fstab" ]] || { warn "No /etc/fstab in target — /boot/(efi) not auto-mounted."; return 0; }
  local m spec dev
  # shallowest mountpoint first so /boot mounts before /boot/efi
  while read -r m spec; do
    dev=$(resolve_spec "$spec")
    if [[ -z "$dev" || ! -b "$dev" ]]; then
      warn "fstab entry $m -> '$spec' could not be resolved; skipping."
      continue
    fi
    mkdir -p "$mp$m"
    mountpoint -q "$mp$m" && continue
    if mount "$dev" "$mp$m"; then info "Mounted $dev at $mp$m (from fstab)";
    else warn "Could not mount $dev at $m"; fi
  done < <(awk '$1!~/^#/ && ($2=="/boot" || $2=="/boot/efi"){print length($2), $2, $1}' \
               "$mp/etc/fstab" | sort -n | awk '{print $2, $3}')
}

MP=""
cleanup() { [[ -n "$MP" ]] && { umount -R "$MP" 2>/dev/null || true; }; }

# ─── regenerate /etc/fstab from the actual on-disk partitions ─────────────────
# Rebuilds root + ESP (+ swap) entries by UUID for the root device's disk.
generate_fstab() {
  local mp="$1" root_dev="$2"
  local disk root_uuid root_fs efi_dev="" sw_dev="" name fstype

  disk="/dev/$(lsblk -no PKNAME "$root_dev" 2>/dev/null | head -1 | tr -d '[:space:]')"
  root_uuid=$(blkid -s UUID -o value "$root_dev" 2>/dev/null || true)
  root_fs=$(blkid -s TYPE -o value "$root_dev" 2>/dev/null || true); root_fs=${root_fs:-ext4}
  [[ -n "$root_uuid" ]] || die "Could not read UUID of $root_dev (damaged superblock?). Cannot build fstab."

  # scan sibling partitions on the same disk for the ESP and swap
  while read -r name fstype; do
    [[ "$name" == "$root_dev" ]] && continue
    if part_is_esp "$name" || [[ "$fstype" == "vfat" ]]; then efi_dev="$name"
    elif [[ "$fstype" == "swap" ]]; then sw_dev="$name"; fi
  done < <(lsblk -lnpo NAME,FSTYPE "$disk" 2>/dev/null | tail -n +2)

  mkdir -p "$mp/etc"
  [[ -f "$mp/etc/fstab" ]] && { cp -a "$mp/etc/fstab" "$mp/etc/fstab.bak.$(date +%s)"; info "Backed up existing fstab."; }

  {
    echo "# /etc/fstab — regenerated by ubuntu-rm-recover $(date -u +%FT%TZ)"
    echo "# <file system>                          <mount point>  <type>  <options>            <dump> <pass>"
    printf 'UUID=%-36s /          %-6s errors=remount-ro 0 1\n' "$root_uuid" "$root_fs"
    if [[ -n "$efi_dev" ]]; then
      local eu; eu=$(blkid -s UUID -o value "$efi_dev" 2>/dev/null || true)
      [[ -n "$eu" ]] && printf 'UUID=%-36s /boot/efi  vfat   umask=0077        0 1\n' "$eu"
    fi
    if [[ -n "$sw_dev" ]]; then
      local su; su=$(blkid -s UUID -o value "$sw_dev" 2>/dev/null || true)
      [[ -n "$su" ]] && printf 'UUID=%-36s none       swap   sw               0 0\n' "$su"
    fi
  } > "$mp/etc/fstab"

  info "Regenerated $mp/etc/fstab:"
  sed 's/^/    /' "$mp/etc/fstab" >&2
  [[ -z "$efi_dev" ]] && warn "No ESP/vfat found on $disk — no /boot/efi entry written."
  warn "Review it: a separate /boot or extra mounts (e.g. /home) are NOT auto-detected."
}

# ─── detect the damaged root (robust, no --root needed) ───────────────────────
# Strategy: exclude the disk(s) backing the live session, then MOUNT-PROBE every
# remaining partition (ignoring the reported FSTYPE, which is blank on a damaged
# superblock) and score it by how much it looks like a Linux root.

part_is_esp() {
  local pt; pt=$(lsblk -no PARTTYPE "$1" 2>/dev/null | tr 'A-Z' 'a-z' | tr -d '[:space:]')
  [[ "$pt" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]]
}

# disks that back the running live session (to exclude from candidates)
live_disks() {
  local m s d; declare -A seen=()
  for m in / /run/live/medium /cdrom /isodevice /rofs /run/initramfs/live /run/live/persistence; do
    s=$(findmnt -nro SOURCE "$m" 2>/dev/null | head -1 | sed 's/\[.*//')
    [[ -n "$s" && -b "$s" ]] || continue
    d=$(lsblk -no PKNAME "$s" 2>/dev/null | head -1 | tr -d '[:space:]')
    [[ -z "$d" ]] && d=$(lsblk -no KNAME "$s" 2>/dev/null | head -1 | tr -d '[:space:]')
    [[ -n "$d" ]] && seen["/dev/$d"]=1
  done
  printf '%s\n' "${!seen[@]}"
}

detect_root() {
  [[ -n "$ROOT_DEV" ]] && { echo "$ROOT_DEV"; return 0; }

  local excl=() e; mapfile -t excl < <(live_disks)
  (( ${#excl[@]} )) && info "Excluding live/boot disk(s): ${excl[*]}"

  # Gather candidate partitions: TYPE=part, not swap/vfat/iso/squashfs, not ESP,
  # not on a live disk.
  local cands=() name fstype ptype pkdisk skip
  while IFS=$'\t' read -r name fstype ptype; do
    [[ "$ptype" == "part" ]] || continue
    case "$fstype" in swap|vfat|iso9660|squashfs|LVM2_member|crypto_LUKS) continue ;; esac
    part_is_esp "$name" && continue
    pkdisk="/dev/$(lsblk -no PKNAME "$name" 2>/dev/null | head -1 | tr -d '[:space:]')"
    skip=0; for e in "${excl[@]}"; do [[ "$pkdisk" == "$e" ]] && { skip=1; break; }; done
    (( skip )) && continue
    [[ -b "$name" ]] && cands+=("$name")
  done < <(lsblk -lnpo NAME,FSTYPE,TYPE | tr -s ' ' '\t')

  if (( ${#cands[@]} == 0 )); then
    error "No candidate Linux partition found. What lsblk sees:"
    lsblk -po NAME,FSTYPE,SIZE,TYPE,MOUNTPOINT >&2 || true
    error "If the root is on LVM/LUKS, activate/unlock it first (vgchange -ay / cryptsetup open)."
    die "Or name it explicitly:  sudo $0 $MODE --root /dev/XXX"
  fi

  # Score each by mount-probing; combine score with size as tiebreaker.
  local best="" best_metric=-1 strong=() dev tmp score size metric
  for dev in "${cands[@]}"; do
    score=0
    if tmp=$(try_mount_ro "$dev"); then
      [[ -e "$tmp/etc/fstab"    ]] && score=$((score+5))
      [[ -d "$tmp/usr"          ]] && score=$((score+3))
      [[ -e "$tmp/etc/os-release" ]] && score=$((score+3))
      [[ -d "$tmp/etc"          ]] && score=$((score+2))
      [[ -d "$tmp/boot"         ]] && score=$((score+1))
      [[ -d "$tmp/home"         ]] && score=$((score+1))
      umount "$tmp" 2>/dev/null || true; rmdir "$tmp" 2>/dev/null || true
    else
      continue   # not mountable → not a usable root
    fi
    (( score >= 5 )) && strong+=("$dev")
    size=$(lsblk -bdno SIZE "$dev" 2>/dev/null | tr -d '[:space:]'); size=${size:-0}
    metric=$(( score * 1000000000000000 + size ))
    if (( metric > best_metric )); then best_metric=$metric; best="$dev"; fi
  done

  [[ -n "$best" ]] || die "Found partitions but none were mountable (damaged fs?). Try fsck, or use --root."

  # Only prompt if genuinely ambiguous: more than one full-looking OS.
  if (( ${#strong[@]} > 1 )); then
    warn "Multiple Linux installations detected — pick the damaged one:"
    local i
    for i in "${!strong[@]}"; do
      printf "   [%d] %-18s %s\n" "$((i+1))" "${strong[$i]}" \
        "$(lsblk -dno SIZE "${strong[$i]}" 2>/dev/null | tr -d '[:space:]')" >&2
    done
    local sel; read -rp "Select [1-${#strong[@]}]: " sel
    [[ "$sel" =~ ^[0-9]+$ ]] && (( sel>=1 && sel<=${#strong[@]} )) || die "Invalid selection."
    echo "${strong[$((sel-1))]}"; return 0
  fi

  info "Auto-detected root: $best"
  echo "$best"
}

# ─── architecture (for mirror + debootstrap) ──────────────────────────────────
detect_arch() {
  local mp="$1" a=""
  [[ -x "$mp/usr/bin/dpkg" ]] && a=$(chroot "$mp" dpkg --print-architecture 2>/dev/null || true)
  [[ -z "$a" ]] && command -v dpkg &>/dev/null && a=$(dpkg --print-architecture 2>/dev/null || true)
  if [[ -z "$a" ]]; then
    case "$(uname -m)" in
      x86_64) a=amd64 ;; aarch64) a=arm64 ;; armv7l) a=armhf ;;
      i?86) a=i386 ;; ppc64le) a=ppc64el ;; riscv64) a=riscv64 ;; *) a=amd64 ;;
    esac
  fi
  echo "$a"
}

# archive vs ports mirror by arch
mirror_for_arch() {
  case "$1" in
    amd64|i386) echo "http://archive.ubuntu.com/ubuntu|http://security.ubuntu.com/ubuntu" ;;
    *)          echo "http://ports.ubuntu.com/ubuntu-ports|http://ports.ubuntu.com/ubuntu-ports" ;;
  esac
}

# ─── detect the Ubuntu release codename/version of the target ─────────────────
DETECTED_VID=""
detect_release() {
  local mp="$1" cn="" vid=""
  if [[ -n "$RELEASE_CODENAME" ]]; then echo "$RELEASE_CODENAME"; return 0; fi

  if [[ -r "$mp/etc/os-release" ]]; then
    cn=$(sed -n 's/^VERSION_CODENAME=//p'  "$mp/etc/os-release" | tr -d '"')
    vid=$(sed -n 's/^VERSION_ID=//p'       "$mp/etc/os-release" | tr -d '"')
  fi
  [[ -z "$cn" && -r "$mp/etc/lsb-release" ]] && \
    cn=$(sed -n 's/^DISTRIB_CODENAME=//p' "$mp/etc/lsb-release")
  # try existing apt sources
  if [[ -z "$cn" ]]; then
    cn=$(grep -rhoE '\b(focal|jammy|noble|oracular|plucky|questing)\b' \
           "$mp/etc/apt/" 2>/dev/null | head -1 || true)
  fi
  # last resort: assume same as the live session
  if [[ -z "$cn" && -r /etc/os-release ]]; then
    cn=$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release | tr -d '"')
    vid=$(sed -n 's/^VERSION_ID=//p'      /etc/os-release | tr -d '"')
    [[ -n "$cn" ]] && warn "Target release unknown; assuming live session's: $cn"
  fi
  [[ -n "$cn" ]] || die "Could not detect release. Set RELEASE_CODENAME=<codename>."
  DETECTED_VID="$vid"
  echo "$cn"
}

# ─── copy apt trust keyrings from the live session if missing ─────────────────
ensure_keyrings() {
  local mp="$1"
  mkdir -p "$mp/usr/share/keyrings" "$mp/etc/apt/trusted.gpg.d"
  local k
  for k in ubuntu-archive-keyring.gpg ubuntu-keyring-2018-archive.gpg; do
    if [[ ! -e "$mp/usr/share/keyrings/$k" && -e "/usr/share/keyrings/$k" ]]; then
      cp -a "/usr/share/keyrings/$k" "$mp/usr/share/keyrings/$k" && \
        info "Restored keyring $k from live session"
    fi
  done
  # one-line sources.list relies on trusted.gpg.d
  if [[ -d /etc/apt/trusted.gpg.d ]]; then
    cp -an /etc/apt/trusted.gpg.d/. "$mp/etc/apt/trusted.gpg.d/" 2>/dev/null || true
  fi
}

# ─── rewrite apt sources for the detected release ─────────────────────────────
repair_sources() {
  local mp="$1" cn="$2" arch="$3"
  local pair mirror sec
  pair=$(mirror_for_arch "$arch"); mirror="${pair%%|*}"; sec="${pair##*|}"

  local ts; ts=$(date +%s)
  mkdir -p "$mp/etc/apt/sources.list.d"
  [[ -f "$mp/etc/apt/sources.list" ]] && cp -a "$mp/etc/apt/sources.list" "$mp/etc/apt/sources.list.bak.$ts"
  [[ -f "$mp/etc/apt/sources.list.d/ubuntu.sources" ]] && \
    cp -a "$mp/etc/apt/sources.list.d/ubuntu.sources" "$mp/etc/apt/sources.list.d/ubuntu.sources.bak.$ts"

  # Decide format: DEB822 if the release ships it (>=24.04) or it already exists.
  local use_deb822=0 major="${DETECTED_VID%%.*}"
  if [[ -f "$mp/etc/apt/sources.list.d/ubuntu.sources" ]]; then use_deb822=1
  elif [[ -n "$major" && "$major" =~ ^[0-9]+$ && "$major" -ge 24 ]]; then use_deb822=1
  fi

  if (( use_deb822 )); then
    info "Writing DEB822 sources for '$cn' ($arch)"
    cat > "$mp/etc/apt/sources.list.d/ubuntu.sources" <<EOF
Types: deb
URIs: $mirror
Suites: $cn $cn-updates $cn-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: $sec
Suites: $cn-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
    : > "$mp/etc/apt/sources.list"   # blank to avoid duplicate-source errors
  else
    info "Writing classic sources.list for '$cn' ($arch)"
    cat > "$mp/etc/apt/sources.list" <<EOF
deb $mirror $cn main restricted universe multiverse
deb $mirror $cn-updates main restricted universe multiverse
deb $mirror $cn-backports main restricted universe multiverse
deb $sec $cn-security main restricted universe multiverse
EOF
  fi
}

# ─── DNS resolver inside the chroot ───────────────────────────────────────────
ensure_resolv() {
  local mp="$1"
  # A symlink left by systemd-resolved would dangle in the chroot; replace it.
  [[ -L "$mp/etc/resolv.conf" ]] && rm -f "$mp/etc/resolv.conf"
  # Prefer the live session's *real* upstream servers over the 127.0.0.53 stub.
  if [[ -r /run/systemd/resolve/resolv.conf ]]; then
    cp -f /run/systemd/resolve/resolv.conf "$mp/etc/resolv.conf"
  elif [[ -r /etc/resolv.conf ]]; then
    grep -v '127.0.0.53' /etc/resolv.conf > "$mp/etc/resolv.conf" 2>/dev/null || true
  fi
  if ! grep -q '^nameserver' "$mp/etc/resolv.conf" 2>/dev/null; then
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$mp/etc/resolv.conf"
    info "No usable resolver found — wrote public DNS (1.1.1.1 / 8.8.8.8)."
  fi
}

# ─── connectivity checks (+ light fixes) ──────────────────────────────────────
check_connectivity() {
  local mp="$1" host="archive.ubuntu.com" fail=0

  info "Connectivity check:"
  if ip route get 1.1.1.1 &>/dev/null; then ok "default route present";
  else bad "no default route — connect the live session to a network first"; fail=1; fi

  if getent hosts "$host" &>/dev/null; then ok "DNS resolves $host";
  else bad "DNS cannot resolve $host"; fail=1; fi

  # reachability (host stack; chroot shares it)
  if command -v curl &>/dev/null; then
    if curl -sSI --max-time 10 "http://$host/ubuntu/dists/" &>/dev/null; then ok "HTTP reachable: $host";
    else bad "cannot reach http://$host"; fail=1; fi
  elif command -v wget &>/dev/null; then
    if wget -q --timeout=10 --spider "http://$host/ubuntu/dists/"; then ok "HTTP reachable: $host";
    else bad "cannot reach http://$host"; fail=1; fi
  fi

  if (( fail )); then
    warn "Connectivity problems detected. If this machine uses WiFi, run 'netfix'"
    warn "to import WiFi profiles, or connect the live session via 'nmtui' first."
  fi
  return 0
}

# ─── detect & apply NetworkManager WiFi profiles (for the recovered system) ───
repair_network_profiles() {
  local mp="$1"
  local live_nm="/etc/NetworkManager/system-connections"
  local tgt_nm="$mp/etc/NetworkManager/system-connections"
  mkdir -p "$tgt_nm"

  local imported=0 kept=0 f base
  shopt -s nullglob
  # keep whatever survived on the target
  for f in "$tgt_nm"/*; do kept=$((kept+1)); done
  # import any profile from the live session that the target doesn't already have
  if [[ -d "$live_nm" ]]; then
    for f in "$live_nm"/*; do
      base=$(basename "$f")
      if [[ ! -e "$tgt_nm/$base" ]]; then
        cp -a "$f" "$tgt_nm/$base" && { imported=$((imported+1)); info "Imported network profile: $base"; }
      fi
    done
  fi
  shopt -u nullglob
  # NM refuses profiles that are group/world-readable
  chmod 600 "$tgt_nm"/* 2>/dev/null || true
  chown root:root "$tgt_nm"/* 2>/dev/null || true

  info "Network profiles — kept $kept from target, imported $imported from live."
  if (( kept + imported == 0 )); then
    warn "No WiFi profiles found anywhere. After boot, connect with: nmtui  (or nmcli)."
  fi

  # Make sure netplan yields device management to NetworkManager if its configs are gone.
  if [[ -d "$mp/etc/netplan" ]]; then
    shopt -s nullglob
    local yamls=("$mp"/etc/netplan/*.yaml "$mp"/etc/netplan/*.yml)
    shopt -u nullglob
    if (( ${#yamls[@]} == 0 )); then
      cat > "$mp/etc/netplan/01-network-manager-all.yaml" <<'EOF'
network:
  version: 2
  renderer: NetworkManager
EOF
      chmod 600 "$mp/etc/netplan/01-network-manager-all.yaml"
      info "Wrote netplan config handing control to NetworkManager."
    fi
  fi
}

enable_network_services() {
  local mp="$1"
  [[ -x "$mp/usr/bin/systemctl" || -x "$mp/bin/systemctl" ]] || return 0
  chroot "$mp" systemctl enable NetworkManager 2>/dev/null && info "Enabled NetworkManager service." || true
  chroot "$mp" systemctl enable systemd-resolved 2>/dev/null || true
}

# ─── assessment ───────────────────────────────────────────────────────────────
VERDICT=""; HAVE_PKGSYS=0
assess_root() {
  local mp="$1"
  echo "" >&2; info "Damage assessment for root at $mp"
  echo "  ── critical system paths ──────────────────────" >&2
  local score=0 pkgsys=1
  check() { local p="$mp$1"; if [[ -e "$p" ]]; then ok "$3 ($1)"; score=$((score+$2)); else bad "MISSING: $3 ($1)"; return 1; fi; }
  check /bin      2 "core binaries"  || pkgsys=0
  check /usr/bin  2 "user binaries"  || pkgsys=0
  check /lib      2 "libraries"      || true
  check /etc      1 "system config"  || true
  check /boot     1 "boot / kernels" || true
  check /sbin/init 1 "init"          || true
  echo "  ── package system ─────────────────────────────" >&2
  check /usr/bin/dpkg        0 "dpkg"           || pkgsys=0
  check /usr/bin/apt-get     0 "apt-get"        || pkgsys=0
  check /var/lib/dpkg/status 0 "dpkg database"  || pkgsys=0
  echo "  ── user data ──────────────────────────────────" >&2
  if [[ -d "$mp/home" ]]; then
    local n; n=$(find "$mp/home" -mindepth 2 -maxdepth 4 -type f 2>/dev/null | head -1000 | wc -l)
    (( n > 0 )) && ok "/home has data (~$n+ files sampled)" || warn "/home exists but looks empty"
  else bad "MISSING: /home"; fi
  echo "  ───────────────────────────────────────────────" >&2

  HAVE_PKGSYS=$pkgsys
  if (( score >= 8 )); then
    VERDICT="intact";     info "VERDICT: largely INTACT — rm likely stopped early. Verify before drastic action."
  elif (( pkgsys == 1 )); then
    VERDICT="repairable"; info "VERDICT: damaged but package system SURVIVED → 'reinstall' can restore files."
  else
    VERDICT="needs-rebuild"
    warn "VERDICT: package system is gone → use 'rebuild' (debootstrap from archive)."
    warn "  Recovery is still possible: internet + live session provide the missing pieces."
  fi
}

# ─── salvage ──────────────────────────────────────────────────────────────────
do_salvage() {
  local mp="$1"
  [[ -n "$DEST" ]] || die "salvage needs --dest DIR (external/other disk)."
  mkdir -p "$DEST"
  local dsrc ssrc
  dsrc=$(findmnt -nro SOURCE --target "$DEST" 2>/dev/null | head -1)
  ssrc=$(findmnt -nro SOURCE --target "$mp"   2>/dev/null | head -1)
  [[ "$dsrc" != "$ssrc" ]] || die "--dest is on the SAME disk as the damaged system. Use external storage."
  command -v rsync &>/dev/null || die "rsync missing (sudo apt install rsync on the live session)."
  local d
  for d in home etc var/log var/lib var/www srv opt root; do
    [[ -e "$mp/$d" ]] || continue
    info "Salvaging /$d -> $DEST/$d"; mkdir -p "$DEST/$d"
    rsync -aAXH --numeric-ids --info=progress2 "$mp/$d/" "$DEST/$d/" \
      || warn "rsync of /$d finished with errors."
  done
  info "Salvage complete. Review $DEST before writing to the damaged disk."
}

# ─── remount rw + prepare chroot networking ───────────────────────────────────
prepare_chroot() {
  local mp="$1" cn arch
  info "Remounting $mp read-write"
  mount -o remount,rw "$mp" || die "Could not remount rw."
  bind_chroot_fs "$mp"
  mount_target_boot "$mp"
  arch=$(detect_arch "$mp"); info "Target architecture: $arch"
  cn=$(detect_release "$mp"); info "Target release: $cn ${DETECTED_VID:+($DETECTED_VID)}"
  ensure_keyrings "$mp"
  repair_sources "$mp" "$cn" "$arch"
  ensure_resolv "$mp"
  check_connectivity "$mp"
  echo "$cn|$arch"
}

# ─── netfix: sources + networking only ────────────────────────────────────────
do_netfix() {
  local mp="$1"
  prepare_chroot "$mp" >/dev/null
  repair_network_profiles "$mp"
  enable_network_services "$mp"
  info "Network/apt configuration repaired. Test with: chroot $mp apt-get update"
}

# ─── fstab: regenerate /etc/fstab from on-disk partitions ─────────────────────
do_fstab() {
  local mp="$1" root_dev="$2"
  info "Remounting $mp read-write to write /etc/fstab"
  mount -o remount,rw "$mp" || die "Could not remount rw."
  generate_fstab "$mp" "$root_dev"
  info "fstab written. (Re-run 'shell' to chroot with /boot and /boot/efi mounted.)"
}

# ─── shell: interactive chroot, auto-cleanup on exit ──────────────────────────
do_shell() {
  local mp="$1"
  info "Remounting $mp read-write for interactive chroot"
  mount -o remount,rw "$mp" || warn "Could not remount rw — shell will be read-only."
  bind_chroot_fs "$mp"
  mount_target_boot "$mp"
  ensure_resolv "$mp"

  # Find a usable shell inside the target (rm -rf may have removed bash).
  local sh="" cand
  for cand in /bin/bash /usr/bin/bash /bin/sh /usr/bin/sh; do
    [[ -x "$mp$cand" ]] && { sh="$cand"; break; }
  done
  [[ -n "$sh" ]] || die "No shell in target (/bin/bash, /bin/sh missing) — too damaged for a chroot shell. Run 'rebuild' first."

  info "Entering chroot: $mp   (shell: $sh)"
  info "Type 'exit' or press Ctrl-D to leave — all mounts unmount automatically."
  # PS1 marks the chroot; '|| true' so a non-zero exit from the shell doesn't
  # trip 'set -e' before cleanup runs.
  PS1='(chroot) \u@\h:\w\$ ' chroot "$mp" "$sh" || true
  info "Left chroot; unmounting."
}

# ─── reinstall: restore deleted files by reinstalling every package ───────────
do_reinstall() {
  local mp="$1"
  (( HAVE_PKGSYS )) || die "Package system is gone — use 'rebuild' instead of 'reinstall'."
  warn "This WRITES to the disk and ends any chance of undeleting files."
  confirm "Type 'REINSTALL' to continue:" "REINSTALL" || die "Aborted."

  prepare_chroot "$mp" >/dev/null
  info "apt-get update"
  chroot "$mp" apt-get update || warn "apt-get update failed — check connectivity/sources above."

  local pkgs
  pkgs=$(chroot "$mp" dpkg-query -W -f='${Package}\n' 2>/dev/null | tr '\n' ' ')
  [[ -n "$pkgs" ]] || die "dpkg has no package list — use 'rebuild'."
  info "Reinstalling ALL packages (restores deleted files; slow)…"
  # shellcheck disable=SC2086
  chroot "$mp" apt-get install --reinstall -y \
    -o Dpkg::Options::="--force-confmiss" $pkgs \
    || warn "Some packages failed — review output."

  repair_network_profiles "$mp"
  enable_network_services "$mp"

  info "Reinstalling GRUB + initramfs"
  [[ -d /sys/firmware/efi ]] && \
    chroot "$mp" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck || true
  chroot "$mp" update-grub || warn "update-grub failed."
  chroot "$mp" update-initramfs -u -k all || warn "update-initramfs failed."
  info "Reinstall pass complete. Reboot and test. (User data in /home is NOT restored by this.)"
}

# ─── rebuild: debootstrap a fresh base when the package system is gone ─────────
do_rebuild() {
  local mp="$1" cn arch pair mirror
  warn "'rebuild' installs a fresh base system over the damaged root."
  warn "It PRESERVES /home but replaces system files. Salvage first if unsure."
  confirm "Type 'REBUILD' to continue:" "REBUILD" || die "Aborted."

  info "Remounting $mp read-write"; mount -o remount,rw "$mp" || die "remount rw failed."
  cn=$(detect_release "$mp"); arch=$(detect_arch "$mp")
  pair=$(mirror_for_arch "$arch"); mirror="${pair%%|*}"
  info "Rebuilding Ubuntu '$cn' ($arch) from $mirror"

  ensure_resolv "$mp"
  if ! command -v debootstrap &>/dev/null; then
    warn "debootstrap not on the live session; attempting to install it (needs internet)…"
    apt-get install -y debootstrap || die "Install debootstrap on the live session first: sudo apt install debootstrap"
  fi

  debootstrap --arch="$arch" --components=main,restricted,universe,multiverse \
    "$cn" "$mp" "$mirror" || die "debootstrap failed — check connectivity."

  bind_chroot_fs "$mp"
  mount_target_boot "$mp"
  ensure_keyrings "$mp"
  repair_sources "$mp" "$cn" "$arch"
  ensure_resolv "$mp"

  info "Installing kernel, bootloader, networking, standard tools into the new base"
  chroot "$mp" apt-get update || warn "apt-get update failed."
  chroot "$mp" apt-get install -y \
    linux-generic grub-efi-amd64 grub-pc-bin os-prober \
    ubuntu-standard network-manager netplan.io sudo || warn "base package install had errors."

  repair_network_profiles "$mp"
  enable_network_services "$mp"

  [[ -d /sys/firmware/efi ]] && \
    chroot "$mp" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck || true
  chroot "$mp" update-grub || warn "update-grub failed."
  chroot "$mp" update-initramfs -u -k all || warn "update-initramfs failed."

  warn "Base system rebuilt. IMPORTANT next steps inside the chroot:"
  warn "  • set a user/password:   chroot $mp passwd <user>   (users in /etc/passwd may be gone)"
  warn "  • verify /etc/fstab is correct for this machine"
  warn "  • install the desktop:   chroot $mp apt-get install -y ubuntu-desktop"
  info "Rebuild pass complete."
}

# ─── minimal: install the smallest Ubuntu base that enables recovery ──────────
# Requires apt to be functional (dpkg + apt-get + dpkg database present).
# Installs just enough to boot, run apt, and allow reinstall/rebuild to work.
do_minimal() {
  local mp="$1"
  (( HAVE_PKGSYS )) || die "apt/dpkg not functional — use 'rebuild' (debootstrap) instead."
  warn "'minimal' installs the smallest viable base so the system can boot and"
  warn "run apt for further recovery. This WRITES to the disk."
  confirm "Type 'MINIMAL' to continue:" "MINIMAL" || die "Aborted."

  local info_pair cn arch
  info_pair=$(prepare_chroot "$mp")
  cn="${info_pair%%|*}"; arch="${info_pair##*|}"

  info "apt-get update (in chroot)"
  chroot "$mp" apt-get update || die "apt-get update failed — check connectivity/sources."

  # The minimal package set: just enough to boot + apt + networking + recovery
  # ubuntu-minimal is the official minimal metapackage (coreutils, apt, dpkg,
  # systemd, login, networking basics). We add kernel + bootloader + NM.
  local minimal_pkgs=(
    ubuntu-minimal          # official meta: coreutils, apt, systemd, login, etc.
    linux-generic           # kernel + modules
    initramfs-tools         # generate initrd
    sudo                    # user privilege escalation
    network-manager         # networking (WiFi + wired)
    netplan.io              # network config renderer
  )

  # Bootloader: pick UEFI or BIOS grub
  if [[ -d /sys/firmware/efi ]]; then
    minimal_pkgs+=(grub-efi-amd64 shim-signed)
  else
    minimal_pkgs+=(grub-pc)
  fi

  info "Installing minimal recovery base: ${minimal_pkgs[*]}"
  chroot "$mp" apt-get install -y --no-install-recommends \
    -o Dpkg::Options::="--force-confmiss" \
    -o Dpkg::Options::="--force-confdef" \
    "${minimal_pkgs[@]}" || warn "Some packages failed — review output above."

  # Networking
  repair_network_profiles "$mp"
  enable_network_services "$mp"

  # Bootloader installation
  if [[ -d /sys/firmware/efi ]]; then
    chroot "$mp" grub-install --target=x86_64-efi --efi-directory=/boot/efi \
      --bootloader-id=ubuntu --recheck 2>/dev/null || warn "grub-install (EFI) failed."
  else
    # Try to find the parent disk for BIOS grub
    local disk
    disk="/dev/$(lsblk -no PKNAME "$ROOT_DEV" 2>/dev/null | head -1 | tr -d '[:space:]')"
    [[ -b "$disk" ]] && chroot "$mp" grub-install "$disk" 2>/dev/null || warn "grub-install (BIOS) failed."
  fi
  chroot "$mp" update-grub 2>/dev/null || warn "update-grub failed."
  chroot "$mp" update-initramfs -u -k all 2>/dev/null || warn "update-initramfs failed."

  info "Minimal install complete. The system should boot to a console."
  info "Next steps:"
  info "  • Set root password:  chroot $mp passwd root"
  info "  • Full desktop:       chroot $mp apt-get install ubuntu-desktop"
  info "  • Or run 'reinstall' mode to restore all previously-installed packages."
}

# ─── recovery: interactive recovery menu (Ubuntu-style) ───────────────────────
# Mimics the recovery mode menu that Ubuntu shows at boot (from the GRUB
# 'recovery mode' entry), but works from a live session against a damaged disk.
do_recovery() {
  local mp="$1"

  # We need at least RW + bind mounts for most operations
  info "Preparing target for recovery menu…"
  mount -o remount,rw "$mp" 2>/dev/null || warn "Could not remount rw — some options will fail."
  bind_chroot_fs "$mp"
  mount_target_boot "$mp"
  ensure_resolv "$mp"

  while true; do
    echo "" >&2
    echo "  ┌─────────────────────────────────────────────────────────┐" >&2
    echo "  │           Recovery Menu  (ubuntu-rm-recover)            │" >&2
    echo "  ├─────────────────────────────────────────────────────────┤" >&2
    echo "  │  resume     - Attempt normal boot (exit recovery)       │" >&2
    echo "  │  clean      - Free up disk space (apt autoremove/clean) │" >&2
    echo "  │  dpkg       - Repair broken packages (dpkg --configure) │" >&2
    echo "  │  fsck       - Check all filesystems                     │" >&2
    echo "  │  network    - Repair networking + enable connectivity   │" >&2
    echo "  │  root       - Drop to a root shell in chroot            │" >&2
    echo "  │  grub       - Reinstall/update GRUB bootloader          │" >&2
    echo "  │  summary    - System summary (assess damage)            │" >&2
    echo "  │  fstab      - Regenerate /etc/fstab                     │" >&2
    echo "  │  passwd     - Reset a user's password                   │" >&2
    echo "  │  failsafe-x - Fix graphics (reconfigure Xorg/display)  │" >&2
    echo "  │  quit       - Exit recovery menu                        │" >&2
    echo "  └─────────────────────────────────────────────────────────┘" >&2
    echo "" >&2
    local choice
    read -rp "  recovery> " choice

    case "$choice" in
      resume)
        info "Syncing and exiting. Reboot when ready."
        sync
        break
        ;;

      clean)
        info "Cleaning up disk space…"
        chroot "$mp" apt-get autoremove -y 2>/dev/null || warn "autoremove failed."
        chroot "$mp" apt-get autoclean 2>/dev/null || true
        chroot "$mp" apt-get clean 2>/dev/null || true
        # Clean old kernels (keep running + latest)
        if chroot "$mp" dpkg -l 'linux-image-*' &>/dev/null 2>&1; then
          local cur_kern
          cur_kern=$(chroot "$mp" uname -r 2>/dev/null || true)
          if [[ -n "$cur_kern" ]]; then
            info "Current kernel: $cur_kern (kept)"
          fi
        fi
        # Clean journal
        chroot "$mp" journalctl --vacuum-size=50M 2>/dev/null || true
        # Report disk usage
        df -h "$mp" 2>/dev/null | tail -1 | awk '{print "  Disk usage: "$3" used / "$4" available (" $5 " full)"}' >&2
        ok "Cleanup done."
        ;;

      dpkg)
        info "Repairing broken packages…"
        chroot "$mp" dpkg --configure -a 2>&1 | tail -20 || warn "dpkg --configure -a had errors."
        chroot "$mp" apt-get install -f -y 2>&1 | tail -20 || warn "apt-get install -f failed."
        ok "Package repair pass complete."
        ;;

      fsck)
        warn "fsck requires unmounted filesystems. Checking non-root partitions…"
        # We can't fsck the root while mounted; inform the user.
        local root_dev_now
        root_dev_now=$(findmnt -nro SOURCE "$mp" 2>/dev/null | head -1)
        warn "Root ($root_dev_now) is MOUNTED — cannot fsck live. Will check others."
        # Check any other fstab entries
        if [[ -f "$mp/etc/fstab" ]]; then
          local fdev fmp
          while read -r fdev fmp; do
            [[ "$fmp" == "/" ]] && continue
            local resolved
            resolved=$(resolve_spec "$fdev")
            if [[ -n "$resolved" && -b "$resolved" ]]; then
              if ! mountpoint -q "$mp$fmp" 2>/dev/null; then
                info "Checking $resolved ($fmp)…"
                fsck -y "$resolved" 2>&1 | tail -5 || true
              else
                warn "$fmp is mounted — skipping fsck."
              fi
            fi
          done < <(awk '$1!~/^#/ && $2!="none" && $3!="swap"{print $1, $2}' "$mp/etc/fstab" 2>/dev/null)
        fi
        warn "To fsck root: unmount it, or run 'fsck $root_dev_now' from the live session (outside this script)."
        ;;

      network)
        info "Repairing network configuration…"
        local cn arch
        cn=$(detect_release "$mp"); arch=$(detect_arch "$mp")
        ensure_keyrings "$mp"
        repair_sources "$mp" "$cn" "$arch"
        ensure_resolv "$mp"
        repair_network_profiles "$mp"
        enable_network_services "$mp"
        check_connectivity "$mp"
        ok "Network repair done."
        ;;

      root)
        info "Dropping to root shell in chroot. Type 'exit' to return to menu."
        local sh=""
        for cand in /bin/bash /usr/bin/bash /bin/sh /usr/bin/sh; do
          [[ -x "$mp$cand" ]] && { sh="$cand"; break; }
        done
        if [[ -n "$sh" ]]; then
          PS1='(recovery-chroot) \u@\h:\w# ' chroot "$mp" "$sh" || true
        else
          warn "No shell available in target. Run 'minimal' or 'rebuild' first."
        fi
        ;;

      grub)
        info "Reinstalling GRUB…"
        if [[ -d /sys/firmware/efi ]]; then
          chroot "$mp" grub-install --target=x86_64-efi --efi-directory=/boot/efi \
            --bootloader-id=ubuntu --recheck 2>&1 | tail -5 || warn "grub-install (EFI) failed."
        else
          local disk
          disk="/dev/$(lsblk -no PKNAME "$ROOT_DEV" 2>/dev/null | head -1 | tr -d '[:space:]')"
          if [[ -b "$disk" ]]; then
            chroot "$mp" grub-install "$disk" 2>&1 | tail -5 || warn "grub-install (BIOS) failed."
          else
            warn "Could not determine parent disk for BIOS grub. Use: grub-install /dev/sdX"
          fi
        fi
        chroot "$mp" update-grub 2>&1 | tail -10 || warn "update-grub failed."
        chroot "$mp" update-initramfs -u -k all 2>&1 | tail -5 || warn "update-initramfs failed."
        ok "GRUB update done."
        ;;

      summary)
        assess_root "$mp"
        ;;

      fstab)
        local root_dev_now
        root_dev_now=$(findmnt -nro SOURCE "$mp" 2>/dev/null | head -1)
        if [[ -n "$root_dev_now" ]]; then
          generate_fstab "$mp" "$root_dev_now"
        else
          warn "Cannot determine root device for fstab generation."
        fi
        ;;

      passwd)
        local target_user
        # List available users
        if [[ -f "$mp/etc/passwd" ]]; then
          info "Users with login shells:"
          awk -F: '$7 ~ /(bash|sh|zsh|fish)$/ && $3 >= 1000 && $3 < 65534 {print "  " $1 " (uid=" $3 ")"}' \
            "$mp/etc/passwd" >&2
          echo "  root (uid=0)" >&2
        fi
        read -rp "  Username to reset: " target_user
        if [[ -n "$target_user" ]]; then
          chroot "$mp" passwd "$target_user" || warn "passwd failed."
        fi
        ;;

      failsafe-x|failsafe)
        info "Attempting to fix display/graphics…"
        # Remove Xorg configs that might force a broken driver
        if [[ -f "$mp/etc/X11/xorg.conf" ]]; then
          mv "$mp/etc/X11/xorg.conf" "$mp/etc/X11/xorg.conf.recovery-bak" && \
            info "Moved xorg.conf aside (was possibly forcing a broken driver)."
        fi
        # Reconfigure display manager
        chroot "$mp" dpkg-reconfigure -f noninteractive gdm3 2>/dev/null || \
          chroot "$mp" dpkg-reconfigure -f noninteractive lightdm 2>/dev/null || \
          warn "No display manager found to reconfigure."
        # Try reinstalling the GPU driver stack
        info "Reinstalling mesa (safe generic GPU driver)…"
        chroot "$mp" apt-get install --reinstall -y libgl1-mesa-dri 2>/dev/null || true
        ok "Graphics fixup done. Try rebooting."
        ;;

      quit|exit|q)
        info "Exiting recovery menu."
        break
        ;;

      "")
        continue
        ;;

      *)
        warn "Unknown option: '$choice'"
        ;;
    esac
  done
}

# ─── main ─────────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"
  require_root
  trap cleanup EXIT

  local root; root=$(detect_root)
  [[ -b "$root" ]] || die "$root is not a block device."
  info "Damaged root device: $root"

  # Fail safe: writing modes are never allowed against a mounted/in-use disk.
  case "$MODE" in
    netfix|reinstall|rebuild|minimal|recovery|shell|fstab) assert_target_offline "$root" ;;
  esac

  MP=$(try_mount_ro "$root") || die "Could not mount $root (fs may be damaged — try fsck or image it)."
  MOUNT_POINT="$MP"

  case "$MODE" in
    assess)    assess_root "$MP" ;;
    salvage)   assess_root "$MP"; do_salvage "$MP" ;;
    netfix)    assess_root "$MP"; do_netfix "$MP" ;;
    reinstall) assess_root "$MP"; do_reinstall "$MP" ;;
    rebuild)   assess_root "$MP"; do_rebuild "$MP" ;;
    minimal)   assess_root "$MP"; do_minimal "$MP" ;;
    recovery)  do_recovery "$MP" ;;
    shell)     do_shell "$MP" ;;
    fstab)     do_fstab "$MP" "$root" ;;
  esac
}

main "$@"
