#!/usr/bin/env bash
set -Eeuo pipefail

BASE_ISO_URL="${BASE_ISO_URL:-https://releases.ubuntu.com/focal/ubuntu-20.04.6-desktop-amd64.iso}"
BASE_ISO_SHA256="${BASE_ISO_SHA256:-510ce77afcb9537f198bc7daa0e5b503b6e67aaed68146943c231baeaab94df1}"
BASE_ISO="${BASE_ISO:-$PWD/ubuntu-20.04.6-desktop-amd64.iso}"
OUTPUT_ISO="${OUTPUT_ISO:-$PWD/Trebo-20.04.6-amd64.iso}"
WORKDIR="${WORKDIR:-$PWD/trebo-work}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ISO_DIR="$WORKDIR/iso"
ROOTFS="$WORKDIR/rootfs"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

trap 'rc=$?; echo "Trebo host build failed at line $LINENO: $BASH_COMMAND (exit $rc)" >&2' ERR

required_commands=(
  curl sha256sum xorriso unsquashfs mksquashfs
  chroot mount umount sed awk grep find md5sum
  rsvg-convert readlink
)

for command_name in "${required_commands[@]}"; do
  command -v "$command_name" >/dev/null 2>&1 || die "Missing required command: $command_name"
done

[[ $EUID -eq 0 ]] || die "Run this script as root: sudo bash ./build-trebo.sh"

RESUME="${RESUME:-0}"
QUICK="${QUICK:-0}"
REFRESH_INITRD="${REFRESH_INITRD:-0}"

usage() {
  cat <<'EOF_USAGE'
Usage:
  sudo bash ./build-trebo.sh
      Full build: extract Ubuntu, install Linux 7, Focal -> Jammy -> Noble,
      customize Trebo, rebuild SquashFS, and create the ISO.

  sudo bash ./build-trebo.sh --quick
      Reuse trebo-work/rootfs. Skip Linux 7 installation, skip Focal/Jammy/
      Noble release upgrades, skip Ubiquity/Casper reinstalls when healthy,
      and preserve the existing Linux 7 initramfs. Apply desktop/theme/app
      changes and rebuild only the SquashFS/ISO.

  sudo bash ./build-trebo.sh --quick --refresh-initrd
      Same as --quick, but also regenerate the existing Linux 7 initramfs.
EOF_USAGE
}

for arg in "$@"; do
  case "$arg" in
    --quick)
      QUICK=1
      RESUME=1
      ;;
    --refresh-initrd)
      REFRESH_INITRD=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $arg"
      ;;
  esac
done

if [[ "$REFRESH_INITRD" == "1" && "$QUICK" != "1" ]]; then
  die "--refresh-initrd is only meaningful together with --quick"
fi

mkdir -p "$WORKDIR"

if [[ ! -f "$BASE_ISO" ]]; then
  echo "Downloading Ubuntu 20.04.6 desktop ISO..."
  curl -fL --retry 5 --retry-delay 3 --continue-at -     -o "$BASE_ISO" "$BASE_ISO_URL"
fi

echo "$BASE_ISO_SHA256  $BASE_ISO" | sha256sum -c -

if [[ "$RESUME" == "1" ]]; then
  echo "Resuming existing Trebo work tree..."
  [[ -d "$ISO_DIR" ]] || die "RESUME=1 requested but $ISO_DIR does not exist"
  [[ -d "$ROOTFS" ]] || die "RESUME=1 requested but $ROOTFS does not exist"

  mkdir -p "$ROOTFS/tmp"

  # A successful older build removed /tmp/trebo-kernel-version from the rootfs.
  # Restore it from the persistent workdir marker, or infer it from /boot.
  if [[ ! -f "$ROOTFS/tmp/trebo-kernel-version" ]]; then
    if [[ -f "$WORKDIR/kernel-version" ]]; then
      cp "$WORKDIR/kernel-version" "$ROOTFS/tmp/trebo-kernel-version"
    else
      KVER_RECOVERED="$(
        find "$ROOTFS/boot" -maxdepth 1 -type f -name 'vmlinuz-7.*' -printf '%f\n' \
          | sed 's/^vmlinuz-//' \
          | sort -V \
          | tail -n1
      )"
      [[ -n "$KVER_RECOVERED" ]] || die "Could not recover the existing Linux 7 version from trebo-work"
      [[ -f "$ROOTFS/boot/initrd.img-$KVER_RECOVERED" ]] || die "Existing Linux 7 initrd is missing for $KVER_RECOVERED"
      printf '%s\n' "$KVER_RECOVERED" > "$ROOTFS/tmp/trebo-kernel-version"
      printf '%s\n' "$KVER_RECOVERED" > "$WORKDIR/kernel-version"
    fi
  fi

  if [[ "$QUICK" == "1" ]]; then
    grep -Eq '^[[:space:]]*deb[[:space:]].*[[:space:]]noble([[:space:]]|$)' "$ROOTFS/etc/apt/sources.list" \
      || die "--quick requires an already-upgraded Noble trebo-work/rootfs"
    echo "QUICK MODE: reusing the existing Noble rootfs and Linux 7 kernel."
  fi
else
  echo "Preparing working tree..."
  rm -rf "$ISO_DIR" "$ROOTFS"
  mkdir -p "$ISO_DIR"

  xorriso -osirrox on -indev "$BASE_ISO" -extract / "$ISO_DIR"
  chmod -R u+w "$ISO_DIR"
  unsquashfs -d "$ROOTFS" "$ISO_DIR/casper/filesystem.squashfs"
fi

# Recreate assets even during resume so the working tree always uses the
# current repository versions. Also discard any stale temporary live initrd
# left by a hard-killed previous build; a new one is created when requested.
rm -f "$ROOTFS/tmp"/trebo-live-initrd-* 2>/dev/null || true
mkdir -p "$ROOTFS/tmp/trebo-assets"
rsvg-convert -w 1156 -h 867   -o "$ROOTFS/tmp/trebo-assets/background.png"   "$SCRIPT_DIR/assets/background.svg"
rsvg-convert -w 507 -h 444   -o "$ROOTFS/tmp/trebo-assets/logo.png"   "$SCRIPT_DIR/assets/logo.svg"
install -m0644 "$SCRIPT_DIR/assets/trebo-symbolic.svg" "$ROOTFS/tmp/trebo-assets/trebo-symbolic.svg"
install -m0644 "$SCRIPT_DIR/assets/installer-startup.ogg" "$ROOTFS/tmp/trebo-assets/installer-startup.ogg"

# Ubiquity's chrome expects a small logo, not the full 507x444 artwork. Render
# a compact dark logo for its light installer header/panel.
sed 's/currentColor/#202020/g' "$SCRIPT_DIR/assets/trebo-symbolic.svg" \
  > "$ROOTFS/tmp/trebo-assets/trebo-installer-logo.svg"
rsvg-convert -w 64 -h 56 \
  -o "$ROOTFS/tmp/trebo-assets/trebo-installer-logo.png" \
  "$ROOTFS/tmp/trebo-assets/trebo-installer-logo.svg"
rsvg-convert -w 96 -h 84 \
  -o "$ROOTFS/tmp/trebo-assets/trebo-installed.png" \
  "$ROOTFS/tmp/trebo-assets/trebo-installer-logo.svg"

cat > "$ROOTFS/tmp/trebo-customize.sh" <<'CHROOT_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

trap 'rc=$?; echo "Trebo inner build failed at line $LINENO: $BASH_COMMAND (exit $rc)" >&2' ERR

remove_obsolete_lupin_casper() {
  if dpkg-query -W -f='${db:Status-Status}\n' lupin-casper 2>/dev/null | grep -Fx installed >/dev/null; then
    echo "Removing obsolete Focal lupin-casper before Casper is upgraded..."
    if ! dpkg --no-act --remove lupin-casper; then
      echo "Refusing to remove lupin-casper because dpkg reports a dependency problem." >&2
      return 1
    fi
    dpkg --remove lupin-casper
  fi
}

remove_exact_optional_package() {
  local pkg="$1"

  if ! dpkg-query -W -f='${db:Status-Status}\n' "$pkg" 2>/dev/null | grep -Fx installed >/dev/null; then
    return 0
  fi

  if dpkg --no-act --remove "$pkg" >/dev/null 2>&1; then
    echo "Removing optional package: $pkg"
    dpkg --remove "$pkg"
  else
    echo "Keeping $pkg because another installed package requires it."
  fi
}

write_ubuntu_sources() {
  local suite="$1"

  cat > /etc/apt/sources.list <<EOF_SOURCES
deb http://archive.ubuntu.com/ubuntu $suite main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu $suite-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu $suite-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu $suite-security main restricted universe multiverse
EOF_SOURCES

  find /etc/apt/sources.list.d -maxdepth 1 -type f \
    \( -name '*.list' -o -name '*.sources' \) \
    -exec mv -f {} {}.trebo-disabled \; 2>/dev/null || true
}

guard_dist_upgrade() {
  local simulation
  simulation="$(mktemp)"
  apt-get -s full-upgrade > "$simulation"

  for critical in \
    ubiquity ubiquity-frontend-gtk casper \
    systemd initramfs-tools grub-pc grub-efi-amd64 \
    gdm3 gnome-shell ubuntu-desktop-minimal ubuntu-session \
    network-manager dbus udev sudo libc6 python3
  do
    if awk '$1 == "Remv" {print $2}' "$simulation" | grep -Fx "$critical" >/dev/null; then
      echo "Refusing repository upgrade because apt wants to remove critical package: $critical" >&2
      cat "$simulation" >&2
      rm -f "$simulation"
      return 1
    fi
  done

  rm -f "$simulation"
}

upgrade_to_suite() {
  local suite="$1"
  echo "Switching Trebo package repositories to $suite..."
  write_ubuntu_sources "$suite"
  apt-get update --allow-releaseinfo-change
  guard_dist_upgrade
  apt-get -y full-upgrade
  apt-get -f install -y
}

install_customization_packages() {
  local wanted=(
    gnome-tweaks
    plymouth
    plymouth-label
    plymouth-theme-spinner
    gnome-shell-extension-ubuntu-dock
    gnome-shell-extension-appindicator
    gnome-shell-extension-desktop-icons-ng
    gnome-shell-extension-ubuntu-tiling-assistant
    papirus-icon-theme
    bibata-cursor-theme
    orchis-gtk-theme
    qt5-gtk-platformtheme
    qt6-gtk-platformtheme
    gnome-software
    gparted
    vlc
    baobab
    file-roller

    # Productivity suite and daily-use desktop tools.
    libreoffice-writer
    libreoffice-calc
    libreoffice-impress
    libreoffice-gnome
    libreoffice-style-elementary
    evince
    gnome-calculator
    gnome-calendar
    simple-scan
    deja-dup
    gnome-disk-utility
    gnome-system-monitor
    seahorse
    software-properties-gtk

    gnome-session-canberra
    python3-gi
    gir1.2-gtk-3.0
    policykit-1
  )
  local missing=()
  local pkg

  for pkg in "${wanted[@]}"; do
    if [[ "$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null || true)" != "installed" ]]; then
      missing+=("$pkg")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    echo "Installing only missing Trebo customization packages:"
    printf '  %s\n' "${missing[@]}"
    apt-get update
    apt-get install -y --no-install-recommends "${missing[@]}"
  else
    echo "All Trebo customization packages are already installed; skipping APT install."
  fi
}

install_final_desktop() {
  echo 'gdm3 shared/default-x-display-manager select gdm3' | debconf-set-selections

  # Full builds repair the supported Noble desktop core once. Quick builds skip
  # this metapackage operation and only install any missing customization apps.
  apt-get install -y --no-install-recommends ubuntu-desktop-minimal
  install_customization_packages

  dpkg --configure -a
  apt-get -f install -y
  apt-get check
}

if [[ "${TREBO_QUICK:-0}" == "1" ]]; then
  echo "QUICK MODE: skipping Linux 7 installation and all release upgrades."
  KVER="$(cat /tmp/trebo-kernel-version)"
  [[ "$KVER" == 7.* ]] || {
    echo "Quick mode expected an existing Linux 7 kernel, got: $KVER" >&2
    exit 1
  }
  [[ -f "/boot/vmlinuz-$KVER" ]] || {
    echo "Quick mode cannot find /boot/vmlinuz-$KVER" >&2
    exit 1
  }
  [[ -f "/boot/initrd.img-$KVER" ]] || {
    echo "Quick mode cannot find /boot/initrd.img-$KVER" >&2
    exit 1
  }

  current_suite="$(
    awk '$1 == "deb" && $2 ~ /archive\.ubuntu\.com\/ubuntu/ && $3 !~ /-/ {print $3; exit}' \
      /etc/apt/sources.list
  )"
  [[ "$current_suite" == "noble" ]] || {
    echo "Quick mode requires an already-completed Noble userspace; found: $current_suite" >&2
    exit 1
  }

  # Quick mode is for a completed rootfs, not a half-configured dpkg state.
  # Repair harmless pending configuration first and refuse to customize on top
  # of unresolved package dependency damage.
  dpkg --configure -a
  apt-get -f install -y
  apt-get check

  install_customization_packages
elif [[ "${TREBO_RESUME_AFTER_UPGRADE:-0}" != "1" ]]; then
echo "Preparing Focal only far enough to install Linux 7..."
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl initramfs-tools initramfs-tools-core \
  kmod linux-base software-properties-common


# Fail fast on Trebo's dconf syntax BEFORE the kernel download and release
# upgrades. An empty GSettings string-array needs an explicit GVariant type:
#   @as []
# Without it, dconf cannot infer the type and would otherwise fail near the
# very end of a long build.
if command -v dconf >/dev/null 2>&1; then
  rm -rf /tmp/trebo-dconf-preflight.d /tmp/trebo-dconf-preflight
  mkdir -p /tmp/trebo-dconf-preflight.d
  cat > /tmp/trebo-dconf-preflight.d/00-trebo <<'EOF_DCONF_PREFLIGHT'
[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/trebo-background.png'
picture-options='stretched'
primary-color='#202020'

[org/gnome/desktop/screensaver]
picture-uri='file:///usr/share/backgrounds/trebo-background.png'
picture-options='stretched'

[org/gnome/desktop/interface]
gtk-theme='Trebo'
icon-theme='Papirus-Trebo'
cursor-theme='Bibata-Modern-Ice'
color-scheme='default'
font-name='Cantarell 11'
document-font-name='Cantarell 11'
monospace-font-name='Monospace 11'

[org/gnome/shell]
disable-user-extensions=false
enabled-extensions=['ubuntu-dock@ubuntu.com','ubuntu-appindicators@ubuntu.com','ding@rastersoft.com','tiling-assistant@ubuntu.com']

[org/gnome/shell/extensions/dash-to-dock]
dock-position='LEFT'
dock-fixed=true
autohide=false
intellihide=false
extend-height=true
show-show-apps-button=true
show-apps-at-top=false
dash-max-icon-size=48
EOF_DCONF_PREFLIGHT

  dconf compile /tmp/trebo-dconf-preflight /tmp/trebo-dconf-preflight.d
  rm -rf /tmp/trebo-dconf-preflight.d /tmp/trebo-dconf-preflight
  echo "Trebo dconf syntax preflight passed."
fi

# ---------------------------------------------------------------------------
# PHASE 1: KERNEL FIRST
# ---------------------------------------------------------------------------
# Do this while the rootfs is still entirely Focal. The latest stable v7.x
# Ubuntu Mainline build is discovered dynamically, so this does not hardcode a
# particular 7.x point release.
MAINLINE_ROOT="https://kernel.ubuntu.com/mainline/"
KERNEL_DIR="$(
  curl -fsSL "$MAINLINE_ROOT" \
    | grep -oE 'href="v7\.[0-9]+(\.[0-9]+)?/"' \
    | sed -E 's/^href="//; s/"$//' \
    | sort -V \
    | tail -n1
)"

[[ -n "$KERNEL_DIR" ]] || {
  echo "Could not find a stable Linux 7.x build in Ubuntu Mainline." >&2
  exit 1
}

KERNEL_URL="${MAINLINE_ROOT}${KERNEL_DIR}amd64/"
echo "Installing Linux 7 from: $KERNEL_URL"

rm -rf /tmp/trebo-kernel7
mkdir -p /tmp/trebo-kernel7
curl -fsSL "$KERNEL_URL" -o /tmp/trebo-kernel7/index.html

mapfile -t kernel_debs < <(
  grep -oE 'href="[^"]+\.deb"' /tmp/trebo-kernel7/index.html \
    | sed -E 's/^href="//; s/"$//' \
    | grep -E '^linux-(image-unsigned|modules|modules-extra)-.*-generic_.*_amd64\.deb$' \
    | sort -u
)

(( ${#kernel_debs[@]} >= 2 )) || {
  echo "Ubuntu Mainline Linux 7 package set was incomplete:" >&2
  printf '  %s\n' "${kernel_debs[@]}" >&2
  exit 1
}

for deb in "${kernel_debs[@]}"; do
  echo "Downloading $deb"
  curl -fL --retry 5 --retry-delay 2 \
    -o "/tmp/trebo-kernel7/$deb" "${KERNEL_URL}$deb"
done

# Ubuntu Mainline 7.2 packages currently contain maintainer scripts which call
# run-parts with BOTH /etc/kernel/*.d and /usr/share/kernel/*.d in one command.
# run-parts accepts one directory, so the package preinst aborts with:
#   run-parts: missing operand
# Patch those maintainer scripts in our local copies before installation.
# This does not alter the kernel payload itself.
apt-get install -y --no-install-recommends python3

rm -rf /tmp/trebo-kernel7/fixed /tmp/trebo-kernel7/unpacked
mkdir -p /tmp/trebo-kernel7/fixed /tmp/trebo-kernel7/unpacked

cat > /tmp/trebo-kernel7/fix-run-parts.py <<'PY_FIX'
#!/usr/bin/env python3
import pathlib
import re
import sys

PAT_WITH_IMAGE = re.compile(
    r'''(?m)
    ^(?P<indent>[ \t]*)
    DEB_MAINT_PARAMS="\$\*"\s+run-parts\s+--report\s+--exit-on-error\s+
    --arg=\$version\s*\\\n
    [ \t]*--arg=(?P<img>"?\$image_path"?)\s+
    (?P<dir1>/etc/kernel/[A-Za-z0-9_.-]+\.d)\s+
    (?P<dir2>/usr/share/kernel/[A-Za-z0-9_.-]+\.d)
    ''',
    re.VERBOSE,
)

PAT_NO_IMAGE = re.compile(
    r'''(?m)
    ^(?P<indent>[ \t]*)
    DEB_MAINT_PARAMS="\$\*"\s+run-parts\s+--report\s+--exit-on-error\s+
    --arg=\$version\s*\\\n
    [ \t]*(?P<dir1>/etc/kernel/[A-Za-z0-9_.-]+\.d)\s+
    (?P<dir2>/usr/share/kernel/[A-Za-z0-9_.-]+\.d)
    ''',
    re.VERBOSE,
)

def with_image(match):
    indent = match.group("indent")
    image = match.group("img")
    d1 = match.group("dir1")
    d2 = match.group("dir2")
    rp = (
        'DEB_MAINT_PARAMS="$*" run-parts --report --exit-on-error '
        '--arg=$version --arg=' + image
    )
    return (
        f"{indent}if [ -d {d1} ]; then {rp} {d1}; fi\n"
        f"{indent}if [ -d {d2} ]; then {rp} {d2}; fi"
    )

def no_image(match):
    indent = match.group("indent")
    d1 = match.group("dir1")
    d2 = match.group("dir2")
    rp = (
        'DEB_MAINT_PARAMS="$*" run-parts --report --exit-on-error '
        '--arg=$version'
    )
    return (
        f"{indent}if [ -d {d1} ]; then {rp} {d1}; fi\n"
        f"{indent}if [ -d {d2} ]; then {rp} {d2}; fi"
    )

total = 0
for arg in sys.argv[1:]:
    path = pathlib.Path(arg)
    if not path.is_file():
        continue
    text = path.read_text()
    text, n1 = PAT_WITH_IMAGE.subn(with_image, text)
    text, n2 = PAT_NO_IMAGE.subn(no_image, text)
    if n1 or n2:
        path.write_text(text)
        print(f"Patched {path}: {n1 + n2} run-parts call(s)")
        total += n1 + n2

if total == 0:
    print("No dual-directory run-parts workaround was needed.")
PY_FIX
chmod +x /tmp/trebo-kernel7/fix-run-parts.py

patched_calls=0
for deb in "${kernel_debs[@]}"; do
  src="/tmp/trebo-kernel7/$deb"
  pkgdir="/tmp/trebo-kernel7/unpacked/${deb%.deb}"

  dpkg-deb -R "$src" "$pkgdir"

  mapfile -t maint_scripts < <(
    find "$pkgdir/DEBIAN" -maxdepth 1 -type f \
      \( -name preinst -o -name postinst -o -name prerm -o -name postrm \) \
      -print
  )

  if (( ${#maint_scripts[@]} > 0 )); then
    # Some packages (for example modules) may not contain the broken pattern,
    # so patch per-package without requiring every package to match.
    before="$(
      { grep -hE '/etc/kernel/[^ ]+\.d[[:space:]]+/usr/share/kernel/[^ ]+\.d' "${maint_scripts[@]}" 2>/dev/null || true; } \
        | wc -l
    )"
    if (( before > 0 )); then
      /tmp/trebo-kernel7/fix-run-parts.py "${maint_scripts[@]}"
      patched_calls=$((patched_calls + before))
    fi
  fi

  dpkg-deb -b "$pkgdir" "/tmp/trebo-kernel7/fixed/$deb"
done

if (( patched_calls > 0 )); then
  echo "Patched $patched_calls Linux 7 mainline maintainer-script run-parts call(s)."
else
  echo "Linux 7 mainline packages no longer need the run-parts compatibility workaround."
fi

# Install modules first, then the image. Do NOT run apt-get -f here: these
# mainline packages are local files and are not present in the Focal archive,
# so apt cannot re-download a half-installed image package.
mapfile -t module_debs < <(
  find /tmp/trebo-kernel7/fixed -maxdepth 1 -type f \
    \( -name 'linux-modules-*.deb' -o -name 'linux-modules-extra-*.deb' \) \
    -print | sort
)
mapfile -t image_debs < <(
  find /tmp/trebo-kernel7/fixed -maxdepth 1 -type f \
    -name 'linux-image-unsigned-*.deb' -print | sort
)

(( ${#module_debs[@]} > 0 )) || {
  echo "No patched Linux 7 modules package was produced." >&2
  exit 1
}
(( ${#image_debs[@]} == 1 )) || {
  echo "Expected exactly one patched Linux 7 image package." >&2
  exit 1
}

dpkg -i "${module_debs[@]}"
dpkg -i "${image_debs[@]}"

KVER="$(
  find /lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
    | grep -E '^7\.' \
    | sort -V \
    | tail -n1
)"

[[ -n "$KVER" ]] || {
  echo "Linux 7 modules were not installed." >&2
  exit 1
}

[[ "$(dpkg-query -W -f='${db:Status-Status}' "linux-modules-$KVER" 2>/dev/null || true)" == "installed" ]] || {
  echo "Linux 7 modules package is not fully installed." >&2
  exit 1
}
[[ "$(dpkg-query -W -f='${db:Status-Status}' "linux-image-unsigned-$KVER" 2>/dev/null || true)" == "installed" ]] || {
  echo "Linux 7 image package is not fully installed." >&2
  exit 1
}

[[ -f "/boot/vmlinuz-$KVER" ]] || {
  echo "Linux 7 kernel image /boot/vmlinuz-$KVER is missing." >&2
  exit 1
}

if [[ -f "/boot/initrd.img-$KVER" ]]; then
  update-initramfs -u -k "$KVER"
else
  update-initramfs -c -k "$KVER"
fi

printf '%s\n' "$KVER" > /tmp/trebo-kernel-version
echo "Linux 7 installed first: $KVER"

# Seed Ubiquity/Casper before the release transitions. Do NOT hold Ubiquity:
# Noble still ships a native Ubiquity 24.04.x stack, and freezing the old Focal
# 20.04 packages across Jammy/Noble creates a mixed, broken installer.
apt-get install -y --no-install-recommends \
  ubiquity ubiquity-frontend-gtk ubiquity-casper casper

# ---------------------------------------------------------------------------
# PHASE 2: MODERNIZE THE USERSpace REPOSITORIES
# ---------------------------------------------------------------------------
# Move through supported LTS suites in order instead of pointing a Focal rootfs
# straight at a much newer release in one jump.
# Focal -> Jammy -> Noble. Jammy's Casper 1.470.x already owns
# casper-premount/20iso_scan, so Focal's obsolete lupin-casper MUST be gone
# before the very first release upgrade begins.
remove_obsolete_lupin_casper
upgrade_to_suite jammy
printf '%s\n' jammy > /tmp/trebo-userspace-stage

upgrade_to_suite noble
printf '%s\n' noble > /tmp/trebo-userspace-stage

install_final_desktop
touch /tmp/trebo-userspace-noble-complete

# The final Linux 7 initramfs is deliberately rebuilt later, after the
# Trebo Plymouth theme is installed and selected. Rebuilding it here would
# embed Ubuntu's Plymouth theme into early userspace and cause a brief Ubuntu
# splash before Trebo takes over.
KVER="$(cat /tmp/trebo-kernel-version)"

[[ -f "/boot/vmlinuz-$KVER" ]] || {
  echo "Linux 7 kernel disappeared during the userspace upgrade." >&2
  exit 1
}
else
  KVER="$(cat /tmp/trebo-kernel-version)"
  [[ "$KVER" == 7.* ]] || {
    echo "Resume marker does not describe a Linux 7 kernel: $KVER" >&2
    exit 1
  }
  [[ -f "/boot/vmlinuz-$KVER" ]] || {
    echo "Resume requested but /boot/vmlinuz-$KVER is missing." >&2
    exit 1
  }

  if [[ -f /tmp/trebo-userspace-noble-complete ]]; then
    echo "Skipping completed Linux 7 and Noble userspace-upgrade stages."
  else
    echo "Resume detected an incomplete userspace release upgrade; repairing it instead of restarting."

    # The known Focal -> Jammy failure leaves hundreds of packages unpacked
    # after Jammy Casper collides with lupin-casper. Remove that obsolete helper
    # first, then let dpkg finish configuring what was already unpacked.
    remove_obsolete_lupin_casper

    current_suite="$(
      awk '$1 == "deb" && $2 ~ /archive\.ubuntu\.com\/ubuntu/ && $3 !~ /-/ {print $3; exit}' \
        /etc/apt/sources.list
    )"

    case "$current_suite" in
      focal)
        echo "Resuming from Focal userspace."
        upgrade_to_suite jammy
        printf '%s\n' jammy > /tmp/trebo-userspace-stage
        ;;
      jammy)
        echo "Repairing interrupted Jammy upgrade..."
        apt-get update --allow-releaseinfo-change
        dpkg --configure -a
        apt-get -f install -y
        guard_dist_upgrade
        apt-get -y full-upgrade
        apt-get -f install -y
        printf '%s\n' jammy > /tmp/trebo-userspace-stage
        ;;
      noble)
        echo "Repairing interrupted Noble upgrade..."
        apt-get update --allow-releaseinfo-change
        dpkg --configure -a
        apt-get -f install -y
        guard_dist_upgrade
        apt-get -y full-upgrade
        apt-get -f install -y
        printf '%s\n' noble > /tmp/trebo-userspace-stage
        ;;
      *)
        echo "Cannot determine resume userspace suite from /etc/apt/sources.list: $current_suite" >&2
        exit 1
        ;;
    esac

    if [[ "$current_suite" != "noble" ]]; then
      upgrade_to_suite noble
      printf '%s\n' noble > /tmp/trebo-userspace-stage
    fi

    install_final_desktop
    touch /tmp/trebo-userspace-noble-complete
  fi
fi

# ---------------------------------------------------------------------------
# NATIVE NOBLE UBIQUITY
# ---------------------------------------------------------------------------
# Resume builds may still contain an old/broken Ubiquity stack. Quick mode first
# tests the existing Noble installer and skips the reinstall when it is healthy.
apt-mark unhold \
  ubiquity ubiquity-frontend-gtk ubiquity-casper \
  ubiquity-ubuntu-artwork ubiquity-slideshow-ubuntu casper \
  >/dev/null 2>&1 || true

UBIQUITY_VERSION="$(dpkg-query -W -f='${Version}' ubiquity 2>/dev/null || true)"
UBIQUITY_HEALTHY=0
if [[ "$UBIQUITY_VERSION" == 24.04.* ]] && \
   PYTHONPATH=/usr/lib/ubiquity python3 -c 'import ubiquity' >/dev/null 2>&1 && \
   python3 -m py_compile /usr/lib/ubiquity/ubiquity/frontend/gtk_ui.py; then
  UBIQUITY_HEALTHY=1
fi

if [[ "${TREBO_QUICK:-0}" == "1" && "$UBIQUITY_HEALTHY" == "1" ]]; then
  echo "QUICK MODE: existing Noble Ubiquity is healthy; skipping its reinstall."
else
  apt-mark unhold ubiquity ubiquity-frontend-gtk ubiquity-casper casper 2>/dev/null || true
  apt-get update

  UBIQUITY_SIMULATION="$(mktemp)"
  apt-get -s install --reinstall \
    ubiquity ubiquity-frontend-gtk ubiquity-casper ubiquity-ubuntu-artwork \
    ubiquity-slideshow-ubuntu > "$UBIQUITY_SIMULATION"

  for critical in systemd initramfs-tools gdm3 gnome-shell casper; do
    if awk '$1 == "Remv" {print $2}' "$UBIQUITY_SIMULATION" | grep -Fx "$critical" >/dev/null; then
      echo "Refusing Ubiquity repair because apt wants to remove critical package: $critical" >&2
      cat "$UBIQUITY_SIMULATION" >&2
      rm -f "$UBIQUITY_SIMULATION"
      exit 1
    fi
  done
  rm -f "$UBIQUITY_SIMULATION"

  apt-get install -y --reinstall --no-install-recommends \
    ubiquity ubiquity-frontend-gtk ubiquity-casper ubiquity-ubuntu-artwork \
    ubiquity-slideshow-ubuntu
fi

UBIQUITY_VERSION="$(dpkg-query -W -f='${Version}' ubiquity 2>/dev/null || true)"
case "$UBIQUITY_VERSION" in
  24.04.*) ;;
  *)
    echo "Expected Noble Ubiquity 24.04.x, got: $UBIQUITY_VERSION" >&2
    exit 1
    ;;
esac

PYTHONPATH=/usr/lib/ubiquity python3 -c 'import ubiquity'
python3 -m py_compile /usr/lib/ubiquity/ubiquity/frontend/gtk_ui.py
echo "Ubiquity GTK frontend validation passed without opening a display."

# ---------------------------------------------------------------------------
# LIVE-BOOT INTEGRITY
# ---------------------------------------------------------------------------
# The rootfs is now Noble-based (or a resumed Noble work tree). Full/resume
# builds refresh Casper from Noble. Quick mode avoids even the APT refresh when
# the existing Casper package and its initramfs files are already healthy.
CASPER_HEALTHY=0
if [[ "$(dpkg-query -W -f='${db:Status-Status}' casper 2>/dev/null || true)" == "installed" ]] && \
   [[ -f /usr/share/initramfs-tools/scripts/casper ]] && \
   [[ -f /usr/share/initramfs-tools/hooks/casper ]]; then
  CASPER_HEALTHY=1
fi

if [[ "${TREBO_QUICK:-0}" == "1" && "$CASPER_HEALTHY" == "1" ]]; then
  echo "QUICK MODE: existing Casper is healthy; skipping all Casper APT work."
else
  apt-mark unhold casper 2>/dev/null || true
  apt-get update

  # Focal's obsolete lupin-casper owns 20iso_scan; modern Casper owns it itself.
  remove_obsolete_lupin_casper

  casper_simulation="$(mktemp)"
  apt-get -s install --reinstall casper > "$casper_simulation"
  for critical in ubiquity ubiquity-frontend-gtk systemd initramfs-tools gdm3 gnome-shell; do
    if awk '$1 == "Remv" {print $2}' "$casper_simulation" | grep -Fx "$critical" >/dev/null; then
      echo "Refusing Casper refresh because apt wants to remove critical package: $critical" >&2
      cat "$casper_simulation" >&2
      rm -f "$casper_simulation"
      exit 1
    fi
  done
  rm -f "$casper_simulation"

  apt-get install -y --reinstall --no-install-recommends casper
fi

# initramfs-tools dispatches the root-mount script through /scripts/$BOOT.
# Without BOOT=casper, a freshly generated initrd can be perfectly valid for
# an installed system while being useless as an Ubuntu/Trebo live ISO.
mkdir -p /etc/initramfs-tools/conf.d
cat > /etc/initramfs-tools/conf.d/trebo-live <<'EOF_TREBO_LIVE'
BOOT=casper
MODULES=most
FRAMEBUFFER=y
RESUME=none
EOF_TREBO_LIVE

# Fail before spending time rebuilding the initramfs if the Casper package is
# incomplete or incompatible with the final userspace.
[[ -f /usr/share/initramfs-tools/scripts/casper ]] || {
  echo "Casper root-mount script is missing from the rootfs." >&2
  dpkg -L casper >&2 || true
  exit 1
}
[[ -f /usr/share/initramfs-tools/hooks/casper ]] || {
  echo "Casper initramfs hook is missing from the rootfs." >&2
  dpkg -L casper >&2 || true
  exit 1
}
chmod +x /usr/share/initramfs-tools/scripts/casper /usr/share/initramfs-tools/hooks/casper

# Rebrand the final Noble-based userspace as Trebo.
cat > /usr/lib/os-release <<'EOF_OS_RELEASE'
NAME="Trebo Linux"
PRETTY_NAME="Trebo Linux 1.0"
ID=trebo
ID_LIKE="ubuntu debian"
VERSION_ID="1.0"
VERSION="1.0"
VERSION_CODENAME=trebo
UBUNTU_CODENAME=noble
HOME_URL="https://github.com/itswiktoragain/Trebo"
SUPPORT_URL="https://github.com/itswiktoragain/Trebo"
BUG_REPORT_URL="https://github.com/itswiktoragain/Trebo/issues"
EOF_OS_RELEASE
ln -sfn /usr/lib/os-release /etc/os-release

cat > /etc/lsb-release <<'EOF_LSB'
DISTRIB_ID=Trebo
DISTRIB_RELEASE=1.0
# Keep the archive suite real. Ubiquity's choose-mirror reads this exact
# field and would otherwise try to use a nonexistent "trebo" Ubuntu suite.
DISTRIB_CODENAME=noble
DISTRIB_DESCRIPTION="Trebo Linux 1.0"
EOF_LSB

printf 'Trebo Linux 1.0 \\n \\l\n' > /etc/issue
printf 'Trebo Linux 1.0\n' > /etc/issue.net

# Brand the Casper live session itself. The installed machine's hostname is
# still chosen by Ubiquity and written into /target during installation.
cat > /etc/casper.conf <<'EOF_TREBO_CASPER'
export USERNAME="trebo"
export USERFULLNAME="Trebo Live User"
export HOST="trebo"
export BUILD_SYSTEM="Ubuntu"
export FLAVOUR="trebo"
EOF_TREBO_CASPER

printf 'trebo\n' > /etc/hostname
if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
  sed -i -E 's/^127\.0\.1\.1[[:space:]].*/127.0.1.1 trebo/' /etc/hosts
else
  printf '127.0.1.1 trebo\n' >> /etc/hosts
fi

# Keep Noble's Ubuntu GNOME session machinery because it wires the supported
# dock/portal/session pieces together. Rebrand only the chooser-visible names.
for session_file in \
  /usr/share/xsessions/ubuntu.desktop \
  /usr/share/xsessions/ubuntu-xorg.desktop \
  /usr/share/wayland-sessions/ubuntu.desktop \
  /usr/share/wayland-sessions/ubuntu-wayland.desktop
do
  [[ -f "$session_file" ]] || continue
  sed -i -E \
    -e 's/^Name=.*/Name=Trebo/' \
    -e 's/^Comment=.*/Comment=Trebo Linux desktop session/' \
    "$session_file"
done

# Keep Noble's Ubuntu Dock extension: Trebo uses it for the left-side dock and
# replaces the Show Applications glyph with the Trebo logo.
[[ -d /usr/share/gnome-shell/extensions/ubuntu-dock@ubuntu.com ]] || {
  echo "Ubuntu Dock extension is missing after installation." >&2
  exit 1
}

# Force the Show Applications actor to use Trebo's SVG directly instead of
# relying on the current icon theme's stock 3x3 grid symbol.
DOCK_APPICONS=/usr/share/gnome-shell/extensions/ubuntu-dock@ubuntu.com/appIcons.js
[[ -f "$DOCK_APPICONS" ]] || {
  echo "Ubuntu Dock appIcons.js is missing." >&2
  exit 1
}
python3 - "$DOCK_APPICONS" <<'PY_DOCK_ICON'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()

trebo_path = "/usr/share/icons/hicolor/scalable/apps/trebo-symbolic.svg"
replacement = """this._iconActor.iconName = null;
        this._iconActor.gicon = Gio.Icon.new_for_string('/usr/share/icons/hicolor/scalable/apps/trebo-symbolic.svg');"""

# Quick mode is intentionally repeatable. If a previous run already patched
# Ubuntu Dock, treat that as success instead of failing because the original
# source line is gone.
if trebo_path in text:
    print("Ubuntu Dock Show Applications icon is already Trebo.")
    raise SystemExit(0)

patterns = [
    r"this\._iconActor\.iconName\s*=\s*\`view-app-grid-\$\{Main\.sessionMode\.currentMode\}-symbolic\`;",
    r"this\._iconActor\.icon_name\s*=\s*\`view-app-grid-\$\{Main\.sessionMode\.currentMode\}-symbolic\`;",
    r"this\._iconActor\.iconName\s*=\s*['\"]view-app-grid-symbolic['\"];",
    r"this\._iconActor\.icon_name\s*=\s*['\"]view-app-grid-symbolic['\"];",
]

for pattern in patterns:
    text, count = re.subn(pattern, replacement, text, count=1)
    if count:
        path.write_text(text)
        print("Patched Ubuntu Dock Show Applications icon to Trebo.")
        break
else:
    # Do not brick a quick rebuild merely because Ubuntu changed this internal
    # implementation. Papirus-Trebo also overrides the view-app-grid symbolic
    # names, so the dock still has a supported theme-based fallback.
    print("Ubuntu Dock source layout changed; using Papirus-Trebo app-grid icon fallback.")
PY_DOCK_ICON

find /usr/share/backgrounds -maxdepth 2 -type f   \( -iname '*ubuntu*' -o -iname '*focal*' \)   -delete 2>/dev/null || true

# Replace visible Ubuntu naming in application metadata without changing
# package identifiers, executable paths, repository names, or dependencies.
while IFS= read -r -d '' desktop_file; do
  sed -i -E     '/^(Name|GenericName|Comment|Keywords)(\[[^]]+\])?=/ s/Ubuntu/Trebo/g'     "$desktop_file" || true
done < <(
  find /usr/share/applications /etc/xdg/autostart     -type f -name '*.desktop' -print0 2>/dev/null
)

install -Dm0644 /tmp/trebo-assets/background.png   /usr/share/backgrounds/trebo-background.png
install -Dm0644 /tmp/trebo-assets/logo.png   /usr/share/pixmaps/trebo-logo.png
install -Dm0644 /tmp/trebo-assets/trebo-symbolic.svg \
  /usr/share/icons/hicolor/scalable/apps/trebo-symbolic.svg


# ---------------------------------------------------------------------------
# TREBO UPDATER
# ---------------------------------------------------------------------------
# ubuntu-desktop-minimal depends on Ubuntu's update-manager package, so removing
# the package itself would break the desktop metapackage. Keep the dependency
# satisfied but completely replace its user-facing launcher/notifier with a
# Trebo-native GTK updater.
mkdir -p /usr/lib/trebo

cat > /usr/lib/trebo/trebo-updater-helper <<'EOF_TREBO_UPDATE_HELPER'
#!/bin/sh
set -eu

action="${1:-}"
APT_LOCK="-o DPkg::Lock::Timeout=120"

case "$action" in
  check)
    apt-get $APT_LOCK update -qq
    apt list --upgradable 2>/dev/null || true
    ;;
  install)
    apt-get $APT_LOCK update -qq
    DEBIAN_FRONTEND=noninteractive apt-get $APT_LOCK -y --no-remove --with-new-pkgs upgrade
    dpkg --audit
    apt-get $APT_LOCK check
    printf '\nTREBO_REMAINING_UPDATES\n'
    apt list --upgradable 2>/dev/null || true
    if [ -e /run/reboot-required ]; then
      printf '\nTREBO_RESTART_REQUIRED\n'
    fi
    ;;
  *)
    echo "Usage: trebo-updater-helper {check|install}" >&2
    exit 2
    ;;
esac
EOF_TREBO_UPDATE_HELPER
chmod 0755 /usr/lib/trebo/trebo-updater-helper

cat > /usr/lib/trebo/trebo-updater.py <<'PY_TREBO_UPDATER'
#!/usr/bin/env python3
import subprocess
import threading

import gi
gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk

HELPER = "/usr/lib/trebo/trebo-updater-helper"


class TreboUpdater(Gtk.Window):
    def __init__(self):
        super().__init__(title="Trebo Updater")
        self.set_default_size(720, 500)
        self.set_border_width(18)
        self.set_icon_name("trebo-symbolic")

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        self.add(outer)

        title = Gtk.Label()
        title.set_markup("<span size='xx-large' weight='bold'>Trebo Updater</span>")
        title.set_xalign(0)
        outer.pack_start(title, False, False, 0)

        subtitle = Gtk.Label(label="Keep Trebo Linux and installed applications up to date.")
        subtitle.set_xalign(0)
        outer.pack_start(subtitle, False, False, 0)

        self.status = Gtk.Label(label="Ready to check for updates.")
        self.status.set_xalign(0)
        outer.pack_start(self.status, False, False, 0)

        scroller = Gtk.ScrolledWindow()
        scroller.set_hexpand(True)
        scroller.set_vexpand(True)
        outer.pack_start(scroller, True, True, 0)

        self.output = Gtk.TextView()
        self.output.set_editable(False)
        self.output.set_cursor_visible(False)
        self.output.set_monospace(True)
        self.output.set_wrap_mode(Gtk.WrapMode.NONE)
        scroller.add(self.output)

        actions = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        outer.pack_start(actions, False, False, 0)

        self.check_button = Gtk.Button(label="Check for updates")
        self.check_button.connect("clicked", lambda *_: self.run_action("check"))
        actions.pack_start(self.check_button, False, False, 0)

        self.install_button = Gtk.Button(label="Install updates")
        self.install_button.get_style_context().add_class("suggested-action")
        self.install_button.connect("clicked", lambda *_: self.run_action("install"))
        actions.pack_start(self.install_button, False, False, 0)

        close_button = Gtk.Button(label="Close")
        close_button.connect("clicked", lambda *_: self.close())
        actions.pack_end(close_button, False, False, 0)

    def set_busy(self, busy):
        self.check_button.set_sensitive(not busy)
        self.install_button.set_sensitive(not busy)

    def set_text(self, text):
        buf = self.output.get_buffer()
        buf.set_text(text.strip() + ("\n" if text.strip() else ""))

    def run_action(self, action):
        self.set_busy(True)
        self.status.set_text(
            "Checking package repositories..."
            if action == "check"
            else "Installing updates safely..."
        )
        self.set_text("Administrator authorization may be requested.")
        threading.Thread(target=self.worker, args=(action,), daemon=True).start()

    def worker(self, action):
        try:
            proc = subprocess.run(
                ["pkexec", HELPER, action],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
            output = proc.stdout or ""
            if proc.returncode == 0:
                if action == "check":
                    lines = [
                        line for line in output.splitlines()
                        if line and not line.startswith("Listing...")
                    ]
                    if lines:
                        message = f"{len(lines)} update(s) available."
                        body = "\n".join(lines)
                    else:
                        message = "Trebo is up to date."
                        body = "No package updates are available."
                else:
                    restart_required = "TREBO_RESTART_REQUIRED" in output
                    output = output.replace("TREBO_RESTART_REQUIRED", "")
                    output = output.replace("TREBO_REMAINING_UPDATES", "\nRemaining updates:")
                    message = (
                        "Updates installed. Restart required."
                        if restart_required
                        else "Updates installed successfully."
                    )
                    body = output
            elif proc.returncode == 126:
                message = "Update cancelled."
                body = output or "Administrator authorization was cancelled."
            else:
                message = "Updater encountered an error."
                body = output or f"Update helper exited with status {proc.returncode}."
        except Exception as exc:
            message = "Updater encountered an error."
            body = str(exc)

        GLib.idle_add(self.finish_action, message, body)

    def finish_action(self, message, body):
        self.status.set_text(message)
        self.set_text(body)
        self.set_busy(False)
        return False


win = TreboUpdater()
win.connect("destroy", Gtk.main_quit)
win.show_all()
Gtk.main()
PY_TREBO_UPDATER
chmod 0755 /usr/lib/trebo/trebo-updater.py

cat > /usr/share/applications/trebo-updater.desktop <<'EOF_TREBO_UPDATER_DESKTOP'
[Desktop Entry]
Type=Application
Name=Trebo Updater
GenericName=Software Updates
Comment=Check for and install Trebo Linux updates
Exec=/usr/lib/trebo/trebo-updater.py
Icon=trebo-symbolic
Terminal=false
Categories=System;Settings;
Keywords=update;upgrade;software;packages;
StartupNotify=true
EOF_TREBO_UPDATER_DESKTOP

# Keep update-manager installed because ubuntu-desktop-minimal depends on it,
# but divert its user-facing binary and desktop file. dpkg-divert makes this
# survive future update-manager package upgrades instead of being overwritten.
ensure_local_diversion() {
  local path="$1"
  local diverted="$2"
  local owner

  owner="$(dpkg-divert --listpackage "$path" 2>/dev/null || true)"
  case "$owner" in
    LOCAL)
      ;;
    "")
      if [[ -e "$diverted" || -L "$diverted" ]]; then
        echo "Cannot create diversion: $diverted already exists but $path is not diverted." >&2
        return 1
      fi
      dpkg-divert --quiet --local --rename --add --divert "$diverted" "$path"
      ;;
    *)
      echo "Refusing to replace existing non-local diversion for $path (owner: $owner)." >&2
      return 1
      ;;
  esac
}

ensure_local_diversion /usr/bin/update-manager /usr/bin/update-manager.ubuntu
cat > /usr/bin/update-manager <<'EOF_TREBO_UPDATE_WRAPPER'
#!/bin/sh
exec /usr/lib/trebo/trebo-updater.py "$@"
EOF_TREBO_UPDATE_WRAPPER
chmod 0755 /usr/bin/update-manager

if [[ -e /usr/share/applications/update-manager.desktop || \
      -e /usr/share/applications/update-manager.desktop.ubuntu ]]; then
  ensure_local_diversion \
    /usr/share/applications/update-manager.desktop \
    /usr/share/applications/update-manager.desktop.ubuntu

  # Keep update-manager's desktop ID as a hidden compatibility alias. The
  # visible menu entry is ONLY trebo-updater.desktop, preventing GNOME Shell
  # from showing two identical Trebo Updater applications.
  cat > /usr/share/applications/update-manager.desktop <<'EOF_TREBO_UPDATE_ALIAS'
[Desktop Entry]
Type=Application
Name=Trebo Updater
Exec=/usr/bin/update-manager
Icon=trebo-symbolic
Terminal=false
NoDisplay=true
StartupNotify=false
Categories=System;Settings;
EOF_TREBO_UPDATE_ALIAS
fi

# Disable Ubuntu's automatic Update Notifier so it cannot reopen Update Manager.
if [[ -f /etc/xdg/autostart/update-notifier.desktop ]]; then
  if grep -q '^Hidden=' /etc/xdg/autostart/update-notifier.desktop; then
    sed -i 's/^Hidden=.*/Hidden=true/' /etc/xdg/autostart/update-notifier.desktop
  else
    printf '\nHidden=true\n' >> /etc/xdg/autostart/update-notifier.desktop
  fi
fi

mkdir -p /etc/systemd/user
for notifier_unit in \
  update-notifier-crash.path \
  update-notifier-crash.service \
  update-notifier-livepatch.path \
  update-notifier-livepatch.service \
  update-notifier-release.path \
  update-notifier-release.service
do
  ln -sfn /dev/null "/etc/systemd/user/$notifier_unit"
done

# ---------------------------------------------------------------------------
# PAPIRUS-TREBO + BIBATA MODERN ICE
# ---------------------------------------------------------------------------
# Use a tiny overlay theme that inherits Papirus. This keeps all Papirus
# updates/coverage while overriding only Trebo's distro and app-grid symbols.
TREBO_ICONS=/usr/share/icons/Papirus-Trebo
rm -rf "$TREBO_ICONS"
mkdir -p \
  "$TREBO_ICONS/symbolic/actions" \
  "$TREBO_ICONS/symbolic/apps" \
  "$TREBO_ICONS/symbolic/places"

cat > "$TREBO_ICONS/index.theme" <<'EOF_TREBO_ICONS'
[Icon Theme]
Name=Papirus Trebo
Comment=Papirus with Trebo distribution symbols
Inherits=Papirus,hicolor
Directories=symbolic/actions,symbolic/apps,symbolic/places

[symbolic/actions]
Size=16
MinSize=8
MaxSize=512
Type=Scalable
Context=Actions

[symbolic/apps]
Size=16
MinSize=8
MaxSize=512
Type=Scalable
Context=Applications

[symbolic/places]
Size=16
MinSize=8
MaxSize=512
Type=Scalable
Context=Places
EOF_TREBO_ICONS

for icon_name in \
  view-app-grid-symbolic \
  view-app-grid-user-symbolic \
  view-app-grid-ubuntu-symbolic \
  show-apps-symbolic
do
  cp /tmp/trebo-assets/trebo-symbolic.svg \
    "$TREBO_ICONS/symbolic/actions/$icon_name.svg"
done

for icon_name in \
  trebo-symbolic \
  distributor-logo-symbolic \
  system-logo-symbolic \
  start-here-symbolic \
  ubuntu-logo-symbolic
do
  cp /tmp/trebo-assets/trebo-symbolic.svg \
    "$TREBO_ICONS/symbolic/apps/$icon_name.svg"
  cp /tmp/trebo-assets/trebo-symbolic.svg \
    "$TREBO_ICONS/symbolic/places/$icon_name.svg"
done

# Remove Yaru ICONS as an exact package operation. dpkg --no-act guarantees
# this cannot expand into an autoremove/dependency cascade.
remove_exact_optional_package yaru-theme-icon
remove_exact_optional_package libreoffice-style-yaru

# Remove the old games inherited from the 20.04 desktop image. Each package is
# removed only when dpkg proves nothing installed requires it.
for game_pkg in \
  aisleriot \
  gnome-chess \
  gnome-mahjongg \
  gnome-mines \
  gnome-nibbles \
  gnome-robots \
  gnome-sudoku \
  gnome-taquin \
  gnome-tetravex \
  iagno \
  lightsoff \
  quadrapassel \
  swell-foop \
  tali \
  five-or-more \
  four-in-a-row
do
  remove_exact_optional_package "$game_pkg"
done

# Never delete files from a package that dpkg had to keep. Papirus-Trebo is
# the configured icon theme, so a retained Yaru package is harmless and
# remains internally consistent.
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f "$TREBO_ICONS" || true
  [[ -d /usr/share/icons/Papirus ]] && gtk-update-icon-cache -f /usr/share/icons/Papirus || true
fi

# Trebo GTK theme: expose Noble's packaged Orchis-Grey under the Trebo name
# through a symlink. Unlike copying the directory, this follows future Noble
# Orchis fixes automatically.
[[ -d /usr/share/themes/Orchis-Grey ]] || {
  echo "Orchis-Grey GTK theme is missing." >&2
  exit 1
}
rm -rf /usr/share/themes/Trebo
ln -s Orchis-Grey /usr/share/themes/Trebo

mkdir -p /etc/dconf/profile /etc/dconf/db/local.d

cat > /etc/dconf/profile/user <<'EOF_DCONF_PROFILE'
user-db:user
system-db:local
EOF_DCONF_PROFILE

cat > /etc/dconf/db/local.d/00-trebo <<'EOF_DCONF'
[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/trebo-background.png'
picture-options='stretched'
primary-color='#202020'

[org/gnome/desktop/screensaver]
picture-uri='file:///usr/share/backgrounds/trebo-background.png'
picture-options='stretched'

[org/gnome/desktop/interface]
gtk-theme='Trebo'
icon-theme='Papirus-Trebo'
cursor-theme='Bibata-Modern-Ice'
color-scheme='default'
font-name='Cantarell 11'
document-font-name='Cantarell 11'
monospace-font-name='Monospace 11'

[org/gnome/shell]
disable-user-extensions=false
enabled-extensions=['ubuntu-dock@ubuntu.com','ubuntu-appindicators@ubuntu.com','ding@rastersoft.com','tiling-assistant@ubuntu.com']

[org/gnome/shell/extensions/dash-to-dock]
dock-position='LEFT'
dock-fixed=true
autohide=false
intellihide=false
extend-height=true
show-show-apps-button=true
show-apps-at-top=false
dash-max-icon-size=48
EOF_DCONF

# Ubuntu ships lower-numbered schema overrides that default back to Yaru.
# A 99_ Trebo override makes new live/installed accounts inherit Trebo's
# theme and dock even before their personal dconf database exists.
cat > /usr/share/glib-2.0/schemas/99_trebo.gschema.override <<'EOF_TREBO_SCHEMA'
[org.gnome.desktop.interface]
gtk-theme='Trebo'
icon-theme='Papirus-Trebo'
cursor-theme='Bibata-Modern-Ice'
color-scheme='default'

[org.gnome.shell]
disable-user-extensions=false
enabled-extensions=['ubuntu-dock@ubuntu.com','ubuntu-appindicators@ubuntu.com','ding@rastersoft.com','tiling-assistant@ubuntu.com']

[org.gnome.desktop.interface:ubuntu]
gtk-theme='Trebo'
icon-theme='Papirus-Trebo'
cursor-theme='Bibata-Modern-Ice'
color-scheme='default'

[org.gnome.shell:ubuntu]
disable-user-extensions=false
enabled-extensions=['ubuntu-dock@ubuntu.com','ubuntu-appindicators@ubuntu.com','ding@rastersoft.com','tiling-assistant@ubuntu.com']

[org.gnome.shell.extensions.dash-to-dock]
dock-position='LEFT'
dock-fixed=true
autohide=false
intellihide=false
extend-height=true
show-show-apps-button=true
show-apps-at-top=false
dash-max-icon-size=48
EOF_TREBO_SCHEMA

glib-compile-schemas --strict /usr/share/glib-2.0/schemas
dconf update

rm -f /etc/skel/.config/dconf/user /root/.config/dconf/user 2>/dev/null || true

# Qt 5 and Qt 6 use Ubuntu's supported GTK3 platform bridges and therefore
# follow Trebo's Orchis GTK theme instead of their mismatched stock styles.
mkdir -p /etc/profile.d
cat > /etc/profile.d/trebo-qt-theme.sh <<'EOF_TREBO_QT'
export QT_QPA_PLATFORMTHEME=gtk3
EOF_TREBO_QT
chmod 0644 /etc/profile.d/trebo-qt-theme.sh

if grep -q '^QT_QPA_PLATFORMTHEME=' /etc/environment 2>/dev/null; then
  sed -i 's/^QT_QPA_PLATFORMTHEME=.*/QT_QPA_PLATFORMTHEME=gtk3/' /etc/environment
else
  printf '\nQT_QPA_PLATFORMTHEME=gtk3\n' >> /etc/environment
fi

# ---------------------------------------------------------------------------
# TREBO UBIQUITY AUDIO + COMPLETION DIALOG
# ---------------------------------------------------------------------------
install -Dm0644 /tmp/trebo-assets/installer-startup.ogg   /usr/share/sounds/trebo/stereo/installer-startup.ogg

# Ubiquity's GTK frontend waits for sound.target and normally launches
# canberra-gtk-play with the generic "system-ready" event. Point that one
# installer-only event at Trebo's supplied audio file instead, so changing the
# installer sound does not replace the normal desktop login/event sounds.
UBIQUITY_GTK=/usr/lib/ubiquity/ubiquity/frontend/gtk_ui.py
[[ -f "$UBIQUITY_GTK" ]] || {
  echo "Ubiquity GTK frontend file is missing: $UBIQUITY_GTK" >&2
  exit 1
}
python3 - "$UBIQUITY_GTK" <<'PY_TREBO_UBIQUITY_AUDIO'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
replacement = "['canberra-gtk-play', '--file=/usr/share/sounds/trebo/stereo/installer-startup.ogg']"

patterns = [
    r"\['canberra-gtk-play',\s*'--id=system-ready'\]",
    r'\["canberra-gtk-play",\s*"--id=system-ready"\]',
]

changed = False
for pattern in patterns:
    text, count = re.subn(pattern, replacement, text, count=1)
    if count:
        changed = True
        break

# Quick mode may run against a tree already patched by an earlier quick build.
if not changed and "installer-startup.ogg" not in text:
    raise SystemExit("Could not locate Ubiquity's system-ready sound command")

path.write_text(text)
PY_TREBO_UBIQUITY_AUDIO

command -v canberra-gtk-play >/dev/null || {
  echo "canberra-gtk-play is missing even though gnome-session-canberra should provide it." >&2
  exit 1
}

# Fix the actual final Ubiquity dialog rather than abusing
# ubuntu_installed.png. That pixmap belongs to the first language/choice page.
# Keep the completion dialog compact, give it a normal-sized symbolic Trebo
# icon, and use short Trebo-specific completion text.
UBIQUITY_UI=/usr/share/ubiquity/gtk/ubiquity.ui
[[ -f "$UBIQUITY_UI" ]] || {
  echo "Ubiquity main GTK UI is missing: $UBIQUITY_UI" >&2
  exit 1
}
python3 - "$UBIQUITY_UI" <<'PY_TREBO_FINISHED_DIALOG'
from pathlib import Path
import xml.etree.ElementTree as ET
import sys

path = Path(sys.argv[1])
tree = ET.parse(path)
root = tree.getroot()

def prop(obj, name, value):
    for node in obj.findall("property"):
        if node.get("name") == name:
            node.text = value
            return
    node = ET.SubElement(obj, "property", {"name": name})
    node.text = value

live = root.find(".//object[@id='live_installer']")
if live is None:
    raise SystemExit("Ubiquity live_installer window was not found")
prop(live, "title", "Install Trebo Linux")

finished = root.find(".//object[@id='finished_dialog']")
if finished is None:
    raise SystemExit("Ubiquity finished_dialog was not found")

prop(finished, "title", "Trebo installation complete")
prop(finished, "resizable", "False")
prop(finished, "border_width", "12")

icon = finished.find(".//object[@id='image1']")
if icon is not None:
    prop(icon, "icon_name", "trebo-symbolic")
    prop(icon, "icon-size", "5")
    prop(icon, "xpad", "8")
    prop(icon, "ypad", "8")

label = finished.find(".//object[@id='finished_label']")
if label is None:
    raise SystemExit("Ubiquity finished_label was not found")
prop(label, "label", "Trebo Linux has been installed successfully. Restart the computer to start using the new installation.")
prop(label, "wrap", "True")
prop(label, "max-width-chars", "46")
prop(label, "xpad", "8")
prop(label, "ypad", "8")

quit_button = finished.find(".//object[@id='quit_button']")
if quit_button is not None:
    prop(quit_button, "label", "Continue testing Trebo")

reboot_button = finished.find(".//object[@id='reboot_button']")
if reboot_button is not None:
    prop(reboot_button, "label", "Restart now")

shutdown_button = finished.find(".//object[@id='shutdown_button']")
if shutdown_button is not None:
    prop(shutdown_button, "label", "Shut down")

tree.write(path, encoding="utf-8", xml_declaration=True)
PY_TREBO_FINISHED_DIALOG

# Replace Ubiquity's installation-progress view with pure GTK. The previous
# WebKit/file:// implementation could render as a completely white rectangle
# even though installation itself continued. Pure GTK removes WebKit, HTML,
# locale, JSONP and file-URL permissions from this screen entirely.
SLIDES=/usr/share/ubiquity-slideshow/slides
mkdir -p "$SLIDES"
cp /tmp/trebo-assets/background.png "$SLIDES/trebo-background.png"

python3 - "$UBIQUITY_GTK" <<'PY_TREBO_SLIDESHOW'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

start_marker = "    def start_slideshow(self):\n"
end_marker = "    def customize_installer(self):\n"
start = text.find(start_marker)
end = text.find(end_marker, start + len(start_marker))
if start < 0 or end < 0:
    raise SystemExit("Could not locate Ubiquity start_slideshow() method boundaries")

method = r'''    def start_slideshow(self):
        # Trebo renders the installer progress page with GTK directly. This
        # cannot turn into WebKit's blank white page when file:// loading,
        # slideshow JavaScript, translations or cache state misbehave.
        misc.drop_privileges_save()
        self.progress_mode.set_current_page(
            self.progress_pages['progress_bar'])
        telemetry.get().add_stage('user_done')

        self.page_section.hide()

        gi.require_version('GdkPixbuf', '2.0')
        from gi.repository import GdkPixbuf

        source = GdkPixbuf.Pixbuf.new_from_file(
            '/usr/share/backgrounds/trebo-background.png')

        overlay = Gtk.Overlay()
        canvas = Gtk.DrawingArea()
        canvas.set_hexpand(True)
        canvas.set_vexpand(True)

        cache = {'width': 0, 'height': 0, 'pixbuf': None}

        def draw_background(widget, cr):
            allocation = widget.get_allocation()
            width = max(1, allocation.width)
            height = max(1, allocation.height)

            if (cache['pixbuf'] is None or
                    cache['width'] != width or
                    cache['height'] != height):
                cache['pixbuf'] = source.scale_simple(
                    width, height, GdkPixbuf.InterpType.BILINEAR)
                cache['width'] = width
                cache['height'] = height

            Gdk.cairo_set_source_pixbuf(cr, cache['pixbuf'], 0, 0)
            cr.paint()
            return False

        canvas.connect('draw', draw_background)
        overlay.add(canvas)

        panel = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        panel.set_name('trebo-install-panel')
        panel.set_halign(Gtk.Align.CENTER)
        panel.set_valign(Gtk.Align.CENTER)

        title = Gtk.Label(label='Trebo is installing')
        title.set_name('trebo-install-title')
        panel.pack_start(title, False, False, 0)

        subtitle = Gtk.Label(
            label='You can continue using the computer while files are copied.')
        subtitle.set_name('trebo-install-subtitle')
        panel.pack_start(subtitle, False, False, 0)

        overlay.add_overlay(panel)

        # The details expander sits on a dark progress bar. Orchis can inherit
        # a dark arrow color there, making the disclosure button look wrong.
        # Give this one control an explicit Trebo foreground.
        details = self.builder.get_object('install_details_expander')
        if details is not None:
            details.set_name('trebo-install-details')

        provider = Gtk.CssProvider()
        provider.load_from_data(b'''
#trebo-install-panel {
    background-color: rgba(20, 20, 20, 0.58);
    border-radius: 14px;
    padding: 18px 28px;
}
#trebo-install-title {
    color: #ffffff;
    font-size: 30px;
    font-weight: 600;
}
#trebo-install-subtitle {
    color: rgba(255, 255, 255, 0.88);
    font-size: 16px;
}
#trebo-install-details > title,
#trebo-install-details > title > arrow,
#trebo-install-details > title label {
    color: #ffffff;
    -gtk-icon-shadow: none;
}
''')
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_USER)

        overlay.show_all()
        self.page_mode.insert_page(overlay, None, 1)
        self.page_mode.show()
        self.page_mode.set_current_page(1)
        misc.regain_privileges_save()

'''

text = text[:start] + method + text[end:]

# The stock code later overwrites GtkBuilder's icon with "ubiquity".
text = text.replace(
    "self.live_installer.set_icon_name('ubiquity')",
    "self.live_installer.set_icon_name('trebo-installer-symbolic')",
)

path.write_text(text)
print("Installed pure-GTK Trebo Ubiquity progress screen.")
PY_TREBO_SLIDESHOW

# Replace only Ubiquity's small logo with a correctly sized dark Trebo mark.
# The old build copied a 507x444 white image into both artwork slots.
if [[ -e /usr/share/ubiquity/pixmaps/ubuntu-logo.png ]]; then
  install -m0644 /tmp/trebo-assets/trebo-installer-logo.png \
    /usr/share/ubiquity/pixmaps/ubuntu-logo.png
fi
# This image is used on Ubiquity's first language/choice page, not the final
# completion dialog. Keep it intentionally small so it cannot dominate the UI.
if [[ -e /usr/share/ubiquity/pixmaps/ubuntu_installed.png ]]; then
  install -m0644 /tmp/trebo-assets/trebo-installed.png \
    /usr/share/ubiquity/pixmaps/ubuntu_installed.png
fi

# Replace obvious user-facing Ubuntu text in Ubiquity UI definitions.
for ui_file in /usr/share/ubiquity/gtk/*.ui; do
  [[ -f "$ui_file" ]] || continue
  sed -i     -e 's/Welcome to Ubuntu/Welcome to Trebo/g'     -e 's/Install Ubuntu/Install Trebo/g'     -e 's/>Ubuntu</>Trebo</g'     "$ui_file"
done


[[ -f /usr/share/applications/ubiquity.desktop ]] || {
  echo "Noble Ubiquity desktop launcher is missing." >&2
  exit 1
}
sed -i -E \
  -e 's/^(Name=).*/\1Install Trebo/' \
  -e 's/^(GenericName=).*/\1Trebo Installer/' \
  -e 's/^(Comment=).*/\1Install Trebo Linux/' \
  /usr/share/applications/ubiquity.desktop

# Give the installer launcher Trebo's logo without altering Ubiquity's program.
install -Dm0644 /tmp/trebo-assets/trebo-symbolic.svg \
  /usr/share/icons/hicolor/scalable/apps/trebo-installer-symbolic.svg
sed -i -E 's/^Icon=.*/Icon=trebo-installer-symbolic/' \
  /usr/share/applications/ubiquity.desktop


# Ubiquity officially runs executable scripts from /usr/lib/ubiquity/target-config
# after copying the live filesystem. Use that supported hook point to make sure
# the installed OS is no longer configured like a Casper live session.
mkdir -p /usr/lib/ubiquity/target-config
cat > /usr/lib/ubiquity/target-config/99trebo-installed <<'EOF_TREBO_TARGET'
#!/bin/sh
set -eu

TARGET=/target
[ -d "$TARGET" ] || exit 0

rm -f "$TARGET/etc/initramfs-tools/conf.d/trebo-live"
if [ -f "$TARGET/etc/initramfs-tools/initramfs.conf" ]; then
  if grep -q '^BOOT=' "$TARGET/etc/initramfs-tools/initramfs.conf"; then
    sed -i 's/^BOOT=.*/BOOT=local/' "$TARGET/etc/initramfs-tools/initramfs.conf"
  else
    printf '\nBOOT=local\n' >> "$TARGET/etc/initramfs-tools/initramfs.conf"
  fi
fi
rm -f "$TARGET/etc/systemd/system/trebo-casper-noprompt.service"
rm -f "$TARGET/etc/systemd/system/multi-user.target.wants/trebo-casper-noprompt.service"
rm -f "$TARGET/var/lib/systemd/random-seed"

# Each installed machine must get its own identity rather than inheriting the
# live image's ID. --root deliberately avoids reusing the live session ID.
rm -f "$TARGET/etc/machine-id" "$TARGET/var/lib/dbus/machine-id"
: > "$TARGET/etc/machine-id"
systemd-machine-id-setup --root="$TARGET" >/dev/null
mkdir -p "$TARGET/var/lib/dbus"
ln -sfn /etc/machine-id "$TARGET/var/lib/dbus/machine-id"

# The live image's /boot/initrd is Casper-enabled. Rebuild target initrds after
# removing the live-only configuration so installed Trebo boots normally.
if [ -x "$TARGET/usr/sbin/update-initramfs" ]; then
  chroot "$TARGET" /usr/sbin/update-initramfs -u -k all
fi

rm -f "$TARGET/usr/lib/ubiquity/target-config/99trebo-installed"
exit 0
EOF_TREBO_TARGET
chmod 0755 /usr/lib/ubiquity/target-config/99trebo-installed

# Trebo Plymouth theme for the installed OS.
THEME=/usr/share/plymouth/themes/trebo
mkdir -p "$THEME"
cp /tmp/trebo-assets/background.png "$THEME/background.png"

cat > "$THEME/trebo.plymouth" <<'EOF_PLYMOUTH'
[Plymouth Theme]
Name=Trebo
Description=Trebo startup and shutdown screen
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/trebo
ScriptFile=/usr/share/plymouth/themes/trebo/trebo.script
EOF_PLYMOUTH

cat > "$THEME/trebo.script" <<'EOF_PLYMOUTH_SCRIPT'
background_image = Image("background.png");
background_image = background_image.Scale(Window.GetWidth(), Window.GetHeight());
background_sprite = Sprite(background_image);
background_sprite.SetPosition(0, 0, -1000);

text_sprite = Sprite();
last_mode = "";
forced_message = "";

fun show_text(text) {
    text_image = Image.Text(text, 1.0, 1.0, 1.0, 1.0, "Sans 24");
    text_sprite.SetImage(text_image);
    text_sprite.SetPosition(
        Window.GetWidth() / 2 - text_image.GetWidth() / 2,
        Window.GetHeight() / 2 - text_image.GetHeight() / 2,
        1000
    );
}

fun text_for_mode(mode) {
    if (mode == "boot")
        return "Trebo is starting";
    if (mode == "resume")
        return "Trebo is resuming";
    if (mode == "shutdown")
        return "Trebo is closing";
    if (mode == "reboot")
        return "Trebo is restarting";
    if (mode == "suspend")
        return "Trebo is suspending";
    if (mode == "updates")
        return "Trebo is installing updates";
    if (mode == "system-upgrade")
        return "Trebo is upgrading";
    if (mode == "firmware-upgrade")
        return "Trebo is updating firmware";
    return "Trebo is working";
}

fun refresh_callback() {
    mode = Plymouth.GetMode();

    # Plymouth can change mode after the script has already loaded. The old
    # theme only checked GetMode() once, which is why "Trebo is starting"
    # leaked into shutdown/reboot/update screens.
    if (mode != last_mode) {
        last_mode = mode;
        if (forced_message == "")
            show_text(text_for_mode(mode));
    }
}

fun message_callback(text) {
    if (text == "Please remove media") {
        forced_message = "Please remove media";
        show_text(forced_message);
    }
}

show_text(text_for_mode(Plymouth.GetMode()));
last_mode = Plymouth.GetMode();

Plymouth.SetRefreshFunction(refresh_callback);
Plymouth.SetMessageFunction(message_callback);
EOF_PLYMOUTH_SCRIPT

update-alternatives   --install /usr/share/plymouth/themes/default.plymouth   default.plymouth "$THEME/trebo.plymouth" 500
update-alternatives   --set default.plymouth "$THEME/trebo.plymouth"

# Casper uses this message when the live medium should be removed.
if [[ -f /sbin/casper-stop ]]; then
  sed -i -E     's|^MSG=.*$|MSG="Please remove media"|; s|^MSG_FALLBACK=.*$|MSG_FALLBACK="Please remove media"|'     /sbin/casper-stop
fi

# Prevent the live session from hanging forever waiting for Enter during
# shutdown/reboot. Casper explicitly honours /run/casper-no-prompt. This unit
# only creates the marker when the machine is actually booted from live media;
# on an installed Trebo system /cdrom/casper does not exist.
cat > /etc/systemd/system/trebo-casper-noprompt.service <<'EOF_TREBO_NOPROMPT'
[Unit]
Description=Trebo live-session non-blocking shutdown
DefaultDependencies=no
After=local-fs.target
Before=casper.service shutdown.target reboot.target poweroff.target
ConditionPathExists=/cdrom/casper

[Service]
Type=oneshot
ExecStart=/usr/bin/touch /run/casper-no-prompt
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_TREBO_NOPROMPT

systemctl enable trebo-casper-noprompt.service >/dev/null 2>&1 || true

# IMPORTANT: build the live Linux 7 initramfs only AFTER Trebo's Plymouth
# theme has been installed and made the default. The initramfs is the first
# userspace visible during boot. If it contains Ubuntu's default Plymouth
# theme, the machine briefly shows Ubuntu and only switches to Trebo after the
# real root filesystem mounts.
KVER="$(cat /tmp/trebo-kernel-version)"
REBUILD_LIVE_INITRD=1
if [[ "${TREBO_QUICK:-0}" == "1" && "${TREBO_REFRESH_INITRD:-0}" != "1" ]]; then
  REBUILD_LIVE_INITRD=0
  echo "QUICK MODE: preserving the existing normal rootfs initrd and Casper ISO initrd."
  [[ -f "/boot/initrd.img-$KVER" ]] || {
    echo "Quick mode cannot preserve a missing rootfs initrd: /boot/initrd.img-$KVER" >&2
    exit 1
  }
fi

if [[ "$REBUILD_LIVE_INITRD" == "1" ]]; then
  echo "Rebuilding Linux 7 LIVE initramfs with Casper + Trebo Plymouth..."
  rm -f "/boot/initrd.img-$KVER"
  BOOT=casper update-initramfs -c -k "$KVER"

  # Capture the complete listing ONCE, then inspect the file. Do not use
  # "lsinitramfs | grep -q" while pipefail is enabled: grep -q exits as soon
  # as it finds a match, which can SIGPIPE lsinitramfs.
  INITRD_LIST="$(mktemp)"
  if ! lsinitramfs "/boot/initrd.img-$KVER" > "$INITRD_LIST"; then
    echo "Could not list Linux 7 live initramfs contents." >&2
    rm -f "$INITRD_LIST"
    exit 1
  fi

  if ! grep -Fx 'scripts/casper' "$INITRD_LIST" >/dev/null; then
    echo "Linux 7 live initramfs is missing /scripts/casper." >&2
    echo "Casper-related files that DID make it into the initramfs:" >&2
    grep -i casper "$INITRD_LIST" >&2 || true
    echo "Source Casper files in the rootfs:" >&2
    find /usr/share/initramfs-tools -maxdepth 3 -iname '*casper*' -print >&2 || true
    rm -f "$INITRD_LIST"
    exit 1
  fi

  if ! grep -F 'usr/share/plymouth/themes/trebo/trebo.plymouth' "$INITRD_LIST" >/dev/null; then
    echo "Linux 7 live initramfs does not contain the Trebo Plymouth theme." >&2
    rm -f "$INITRD_LIST"
    exit 1
  fi

  if ! grep -F 'usr/share/plymouth/themes/trebo/background.png' "$INITRD_LIST" >/dev/null; then
    echo "Linux 7 live initramfs does not contain the Trebo Plymouth background." >&2
    rm -f "$INITRD_LIST"
    exit 1
  fi

  echo "Verified Linux 7 live initramfs contains Casper and Trebo Plymouth."
  rm -f "$INITRD_LIST"

  # Keep the Casper-enabled initrd OUTSIDE /boot before returning the rootfs
  # to normal installed-system semantics.
  cp -f "/boot/initrd.img-$KVER" "/tmp/trebo-live-initrd-$KVER"
fi

# /etc/initramfs-tools/conf.d/trebo-live exists only to build the live ISO
# initrd. Remove it, then rebuild /boot/initrd.img-* as a normal installed
# system initrd. Ubiquity's target hook performs the same repair again after
# installation as a second line of defence.
rm -f /etc/initramfs-tools/conf.d/trebo-live
if grep -q '^BOOT=' /etc/initramfs-tools/initramfs.conf; then
  sed -i 's/^BOOT=.*/BOOT=local/' /etc/initramfs-tools/initramfs.conf
else
  printf '\nBOOT=local\n' >> /etc/initramfs-tools/initramfs.conf
fi

if [[ "${TREBO_QUICK:-0}" != "1" || "${TREBO_REFRESH_INITRD:-0}" == "1" ]]; then
  echo "Rebuilding rootfs Linux 7 initramfs for normal installed-system boot..."
  update-initramfs -u -k "$KVER"
fi

echo "Final Trebo Linux kernel: $KVER"

grep -Fq "installer-startup.ogg" "$UBIQUITY_GTK" || {
  echo "Trebo installer startup audio patch is missing." >&2
  exit 1
}
grep -Fq "Trebo installation complete" "$UBIQUITY_UI" || {
  echo "Trebo Ubiquity completion dialog patch is missing." >&2
  exit 1
}

python3 -m py_compile /usr/lib/trebo/trebo-updater.py
grep -Fq "trebo.html" "$UBIQUITY_GTK" || {
  echo "Trebo direct installer progress-screen patch is missing." >&2
  exit 1
}
[[ -f /usr/share/applications/trebo-updater.desktop ]] || {
  echo "Trebo Updater desktop launcher is missing." >&2
  exit 1
}

# Do not ship crash reports generated while upgrading packages inside chroot;
# they trigger bogus first-boot "System program problem detected" dialogs.
rm -rf /var/crash/* 2>/dev/null || true

dpkg --configure -a
apt-get -f install -y
apt-get check
glib-compile-schemas --strict /usr/share/glib-2.0/schemas
ldconfig
update-desktop-database /usr/share/applications 2>/dev/null || true
update-mime-database /usr/share/mime 2>/dev/null || true
fc-cache -f 2>/dev/null || true

AUDIT_OUTPUT="$(dpkg --audit || true)"
if [[ -n "$AUDIT_OUTPUT" ]]; then
  echo "dpkg audit is not clean:" >&2
  printf '%s\n' "$AUDIT_OUTPUT" >&2
  exit 1
fi

for kernel_pkg in "linux-image-unsigned-$KVER" "linux-modules-$KVER"; do
  [[ "$(dpkg-query -W -f='${db:Status-Status}' "$kernel_pkg" 2>/dev/null || true)" == "installed" ]] || {
    echo "Linux 7 package disappeared or is not configured: $kernel_pkg" >&2
    exit 1
  }
done

for pkg in \
  ubuntu-desktop-minimal \
  ubuntu-session \
  gnome-shell \
  gdm3 \
  pipewire-pulse \
  wireplumber \
  xdg-desktop-portal-gnome \
  gnome-shell-extension-ubuntu-dock \
  gnome-shell-extension-appindicator \
  gnome-shell-extension-desktop-icons-ng \
  gnome-shell-extension-ubuntu-tiling-assistant \
  papirus-icon-theme \
  bibata-cursor-theme \
  orchis-gtk-theme
do
  [[ "$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null || true)" == "installed" ]] || {
    echo "Required final Trebo package is not fully installed: $pkg" >&2
    exit 1
  }
done

# Catch branding/session/updater/live-vs-installed regressions before the
# expensive SquashFS stage.
[[ ! -e /etc/initramfs-tools/conf.d/trebo-live ]] || {
  echo "Live-only initramfs config leaked into the reusable rootfs." >&2
  exit 1
}
grep -q '^BOOT=local$' /etc/initramfs-tools/initramfs.conf || {
  echo "Reusable rootfs is not configured for normal local-root initramfs boot." >&2
  exit 1
}
if [[ "${TREBO_QUICK:-0}" != "1" || "${TREBO_REFRESH_INITRD:-0}" == "1" ]]; then
  [[ -s "/tmp/trebo-live-initrd-$KVER" ]] || {
    echo "Validated Casper initrd copy is missing before ISO packaging." >&2
    exit 1
  }
fi
[[ -x /usr/lib/ubiquity/target-config/99trebo-installed ]] || {
  echo "Trebo Ubiquity installed-system cleanup hook is missing." >&2
  exit 1
}
[[ "$(dpkg-divert --listpackage /usr/bin/update-manager 2>/dev/null || true)" == "LOCAL" ]] || {
  echo "Trebo Updater diversion for /usr/bin/update-manager is missing." >&2
  exit 1
}
grep -Fq "GdkPixbuf.Pixbuf.new_from_file" "$UBIQUITY_GTK" || {
  echo "Ubiquity is not wired to Trebo's pure-GTK progress screen." >&2
  exit 1
}
grep -Fq "trebo-install-details" "$UBIQUITY_GTK" || {
  echo "Trebo installer details-expander styling is missing." >&2
  exit 1
}
grep -Fq "Install Trebo Linux" "$UBIQUITY_UI" || {
  echo "Ubiquity main window title is not Trebo-branded." >&2
  exit 1
}
python3 -m py_compile /usr/lib/trebo/trebo-updater.py "$UBIQUITY_GTK"

for ext in \
  ubuntu-dock@ubuntu.com \
  ubuntu-appindicators@ubuntu.com \
  ding@rastersoft.com \
  tiling-assistant@ubuntu.com
do
  [[ -d "/usr/share/gnome-shell/extensions/$ext" ]] || {
    echo "Required GNOME Shell extension directory is missing: $ext" >&2
    exit 1
  }
done

if [[ "$(dpkg-query -W -f='${db:Status-Status}' lupin-casper 2>/dev/null || true)" == "installed" ]]; then
  echo "Obsolete lupin-casper survived into final Trebo." >&2
  exit 1
fi

if grep -E '^[[:space:]]*deb[[:space:]].*[[:space:]](focal|jammy)([-[:alnum:]]*)?[[:space:]]' \
  /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; then
  echo "Old Focal/Jammy repository is still active in final Trebo." >&2
  exit 1
fi

HELD_PACKAGES="$(apt-mark showhold 2>/dev/null || true)"
for installer_pkg in ubiquity ubiquity-frontend-gtk ubiquity-casper casper; do
  if printf '%s\n' "$HELD_PACKAGES" | grep -Fx "$installer_pkg" >/dev/null; then
    echo "Legacy installer package hold survived: $installer_pkg" >&2
    exit 1
  fi
done

# This rootfs is a reusable live/install image. Do not clone build-time machine
# identity, random seed, crash state, or old package-manager logs into every
# Trebo boot/install.
rm -f /var/lib/systemd/random-seed /var/lib/systemd/credential.secret
rm -f /var/crash/* 2>/dev/null || true
: > /etc/machine-id
mkdir -p /var/lib/dbus
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

for log_file in /var/log/dpkg.log /var/log/alternatives.log; do
  [[ -f "$log_file" ]] && : > "$log_file"
done
rm -f /var/log/apt/history.log /var/log/apt/term.log 2>/dev/null || true

apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/trebo-assets /tmp/trebo-customize.sh
CHROOT_EOF

chmod +x "$ROOTFS/tmp/trebo-customize.sh"

mounted=0
cleanup_mounts() {
  # Every unmount is individually best-effort. Do NOT use "set +e" here:
  # this function is also called normally before ISO packaging, and changing
  # errexit inside a shell function persists in the caller. The old version
  # accidentally disabled fail-fast behavior for the entire SquashFS/ISO stage.
  if [[ $mounted -eq 1 ]]; then
    umount -lf "$ROOTFS/run" 2>/dev/null || true
    umount -lf "$ROOTFS/sys" 2>/dev/null || true
    umount -lf "$ROOTFS/proc" 2>/dev/null || true
    umount -lf "$ROOTFS/dev/pts" 2>/dev/null || true
    umount -lf "$ROOTFS/dev" 2>/dev/null || true
    mounted=0
  fi

  # If the chroot fails, restore the rootfs resolver immediately instead of
  # leaving a copy of the host's resolv.conf behind until the next run.
  if [[ -e "$ROOTFS/etc/resolv.conf.trebo-backup" || \
        -L "$ROOTFS/etc/resolv.conf.trebo-backup" ]]; then
    rm -f "$ROOTFS/etc/resolv.conf"
    mv "$ROOTFS/etc/resolv.conf.trebo-backup" "$ROOTFS/etc/resolv.conf"
  fi
}
trap cleanup_mounts EXIT

mkdir -p "$ROOTFS/dev/pts" "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/run"

# Recover from a previous build that was killed before its EXIT trap ran.
umount -lf "$ROOTFS/run" 2>/dev/null || true
umount -lf "$ROOTFS/sys" 2>/dev/null || true
umount -lf "$ROOTFS/proc" 2>/dev/null || true
umount -lf "$ROOTFS/dev/pts" 2>/dev/null || true
umount -lf "$ROOTFS/dev" 2>/dev/null || true

mount --bind /dev "$ROOTFS/dev"
mount --bind /dev/pts "$ROOTFS/dev/pts"
mount -t proc proc "$ROOTFS/proc"
mount -t sysfs sys "$ROOTFS/sys"

# Give the chroot a private /run instead of exposing the host's systemd, D-Bus,
# Wayland, Polkit and user-session sockets. This prevents maintainer scripts
# and validation code from accidentally talking to the running host desktop.
mount -t tmpfs -o mode=755,nosuid,nodev tmpfs "$ROOTFS/run"
mkdir -p "$ROOTFS/run/lock"
mounted=1

# Recover cleanly from a previous interrupted build before replacing DNS for
# the chroot. Preserve symlink metadata rather than dereferencing it.
if [[ -e "$ROOTFS/etc/resolv.conf.trebo-backup" || -L "$ROOTFS/etc/resolv.conf.trebo-backup" ]]; then
  rm -f "$ROOTFS/etc/resolv.conf"
  mv "$ROOTFS/etc/resolv.conf.trebo-backup" "$ROOTFS/etc/resolv.conf"
fi

if [[ -e "$ROOTFS/etc/resolv.conf" || -L "$ROOTFS/etc/resolv.conf" ]]; then
  cp -a --no-dereference "$ROOTFS/etc/resolv.conf" "$ROOTFS/etc/resolv.conf.trebo-backup"
fi
rm -f "$ROOTFS/etc/resolv.conf"
cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

echo "Customizing Trebo root filesystem..."
CHROOT_LOG="$WORKDIR/trebo-chroot.log"

CHROOT_ENV=(
  /usr/bin/env -i
  HOME=/root
  USER=root
  LOGNAME=root
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  LANG=C
  LC_ALL=C
  DEBIAN_FRONTEND=noninteractive
)

if [[ "$QUICK" == "1" ]]; then
  if ! chroot "$ROOTFS" "${CHROOT_ENV[@]}" \
    TREBO_RESUME_AFTER_UPGRADE=1 \
    TREBO_QUICK=1 \
    TREBO_REFRESH_INITRD="$REFRESH_INITRD" \
    /bin/bash /tmp/trebo-customize.sh 2>&1 | tee "$CHROOT_LOG"; then
    rc=${PIPESTATUS[0]}
    echo >&2
    echo "Trebo QUICK customization failed inside the chroot (exit $rc)." >&2
    echo "The exact inner command is shown above. Last 80 log lines:" >&2
    tail -n 80 "$CHROOT_LOG" >&2 || true
    exit "$rc"
  fi
elif [[ "$RESUME" == "1" ]]; then
  if ! chroot "$ROOTFS" "${CHROOT_ENV[@]}" \
    TREBO_RESUME_AFTER_UPGRADE=1 \
    /bin/bash /tmp/trebo-customize.sh 2>&1 | tee "$CHROOT_LOG"; then
    rc=${PIPESTATUS[0]}
    echo >&2
    echo "Trebo customization failed inside the chroot (exit $rc)." >&2
    echo "The exact inner command is shown above. Last 80 log lines:" >&2
    tail -n 80 "$CHROOT_LOG" >&2 || true
    exit "$rc"
  fi
else
  if ! chroot "$ROOTFS" "${CHROOT_ENV[@]}" \
    /bin/bash /tmp/trebo-customize.sh 2>&1 | tee "$CHROOT_LOG"; then
    rc=${PIPESTATUS[0]}
    echo >&2
    echo "Trebo customization failed inside the chroot (exit $rc)." >&2
    echo "The exact inner command is shown above. Last 80 log lines:" >&2
    tail -n 80 "$CHROOT_LOG" >&2 || true
    exit "$rc"
  fi
fi

rm -f "$ROOTFS/etc/resolv.conf"
if [[ -e "$ROOTFS/etc/resolv.conf.trebo-backup" || -L "$ROOTFS/etc/resolv.conf.trebo-backup" ]]; then
  mv "$ROOTFS/etc/resolv.conf.trebo-backup" "$ROOTFS/etc/resolv.conf"
fi

# Noble's desktop uses systemd-resolved. Repair old work trees where a failed
# build or the previous -L backup logic turned this into a static host file.
if [[ -e "$ROOTFS/usr/lib/systemd/system/systemd-resolved.service" ]]; then
  rm -f "$ROOTFS/etc/resolv.conf"
  ln -s ../run/systemd/resolve/stub-resolv.conf "$ROOTFS/etc/resolv.conf"
elif [[ ! -e "$ROOTFS/etc/resolv.conf" && ! -L "$ROOTFS/etc/resolv.conf" ]]; then
  cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
fi

cleanup_mounts
mounted=0
trap - EXIT

# The live ISO now boots the same Linux 7 kernel installed in the rootfs.
KVER="$(cat "$ROOTFS/tmp/trebo-kernel-version")"
[[ "$KVER" == 7.* ]] || die "Refusing to publish ISO: expected Linux 7, got $KVER"
[[ -f "$ROOTFS/boot/vmlinuz-$KVER" ]] || die "Missing Linux 7 vmlinuz"
[[ -f "$ROOTFS/boot/initrd.img-$KVER" ]] || die "Missing normal Linux 7 rootfs initrd"

cp "$ROOTFS/boot/vmlinuz-$KVER" "$ISO_DIR/casper/vmlinuz"

if [[ "$QUICK" == "1" && "$REFRESH_INITRD" != "1" ]]; then
  [[ -f "$ISO_DIR/casper/initrd" ]] \
    || die "Quick mode requested initrd preservation but ISO/casper/initrd is missing"
  echo "QUICK MODE: preserving the existing validated Casper ISO initrd."
else
  LIVE_INITRD="$ROOTFS/tmp/trebo-live-initrd-$KVER"
  [[ -s "$LIVE_INITRD" ]] || die "Missing validated Casper live initrd copy"
  cp "$LIVE_INITRD" "$ISO_DIR/casper/initrd"
  rm -f "$LIVE_INITRD"
fi

# Keep a persistent host-side marker for future --quick runs, while removing
# the temporary marker from the filesystem that is shipped in the ISO.
printf '%s\n' "$KVER" > "$WORKDIR/kernel-version"
rm -f "$ROOTFS/tmp/trebo-kernel-version"

# Media identity.
printf '%s\n' 'Trebo Linux 1.0 - Release amd64' > "$ISO_DIR/.disk/info"

if [[ -f "$ISO_DIR/README.diskdefines" ]]; then
  sed -i 's/Ubuntu/Trebo Linux/g' "$ISO_DIR/README.diskdefines"
fi

# Change only visible boot-menu text. Do not rewrite lowercase package paths,
# preseed paths, boot parameters, or repository identifiers.
for boot_file in \
  "$ISO_DIR/boot/grub/grub.cfg" \
  "$ISO_DIR/boot/grub/loopback.cfg" \
  "$ISO_DIR/isolinux/txt.cfg" \
  "$ISO_DIR/isolinux/menu.cfg" \
  "$ISO_DIR/isolinux/isolinux.cfg"
do
  [[ -f "$boot_file" ]] || continue
  sed -i 's/Ubuntu/Trebo/g' "$boot_file"

  # Casper's documented noprompt boot option prevents live shutdown/reboot
  # from waiting indefinitely for a keypress after the installation media
  # prompt. Add it only to boot=casper kernel command lines and only once.
  sed -i -E '/boot=casper/ {
    /(^|[[:space:]])noprompt([[:space:]]|$)/! s/(boot=casper)([[:space:]])/\1 noprompt\2/
  }' "$boot_file"
done

echo "Updating filesystem manifests..."

# Ubiquity exposes "Minimal installation" when this file exists. The source
# file describes Focal, not Trebo's Noble package graph, so keeping it would
# remove an obsolete package set from the installed system.
rm -f "$ISO_DIR/casper/filesystem.manifest-minimal-remove"

chroot "$ROOTFS" dpkg-query -W --showformat='${Package} ${Version}\n' \
  | LC_ALL=C sort > "$ISO_DIR/casper/filesystem.manifest"

# Ubiquity treats filesystem.manifest-remove as the authoritative list of
# live-only packages to remove from the installed target. Never reuse the
# Ubuntu 20.04 ISO's stale list after converting the rootfs to Noble.
awk '
  $1 == "casper" ||
  $1 == "user-setup" ||
  $1 == "oem-config" ||
  $1 ~ /^oem-config-/ ||
  $1 == "ubiquity" ||
  $1 ~ /^ubiquity-/ { print }
' "$ISO_DIR/casper/filesystem.manifest" \
  > "$ISO_DIR/casper/filesystem.manifest-remove"

# Keep the older manifest-desktop compatibility path correct too.
awk '
  NR == FNR { remove[$1]=1; next }
  !($1 in remove) { print }
' "$ISO_DIR/casper/filesystem.manifest-remove" \
  "$ISO_DIR/casper/filesystem.manifest" \
  > "$ISO_DIR/casper/filesystem.manifest-desktop"

grep -q '^casper ' "$ISO_DIR/casper/filesystem.manifest-remove" \
  || die "Generated manifest-remove does not contain casper"
grep -q '^ubiquity ' "$ISO_DIR/casper/filesystem.manifest-remove" \
  || die "Generated manifest-remove does not contain ubiquity"

printf '%s\n' "$(du -sx --block-size=1 "$ROOTFS" | cut -f1)" \
  > "$ISO_DIR/casper/filesystem.size"

echo "Rebuilding SquashFS..."
rm -f   "$ISO_DIR/casper/filesystem.squashfs"   "$ISO_DIR/casper/filesystem.squashfs.gpg"

mksquashfs "$ROOTFS" "$ISO_DIR/casper/filesystem.squashfs"   -comp xz -b 1M -noappend -no-progress

echo "Refreshing ISO checksums..."
(
  cd "$ISO_DIR"
  rm -f md5sum.txt
  find . -type f     ! -path './isolinux/boot.cat'     ! -path './md5sum.txt'     -print0     | sort -z     | xargs -0 md5sum     > md5sum.txt
)

echo "Creating Trebo ISO..."
rm -f "$OUTPUT_ISO" "$OUTPUT_ISO.sha256"

xorriso   -indev "$BASE_ISO"   -outdev "$OUTPUT_ISO"   -update_r "$ISO_DIR" /   -volid "TREBO_20_04_6"   -boot_image any replay   -commit

sha256sum "$OUTPUT_ISO" | tee "$OUTPUT_ISO.sha256"

echo
echo "Trebo build completed successfully."
echo "ISO: $OUTPUT_ISO"
echo "SHA256: $OUTPUT_ISO.sha256"
