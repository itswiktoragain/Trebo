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

mkdir -p "$WORKDIR"

if [[ ! -f "$BASE_ISO" ]]; then
  echo "Downloading Ubuntu 20.04.6 desktop ISO..."
  curl -fL --retry 5 --retry-delay 3 --continue-at -     -o "$BASE_ISO" "$BASE_ISO_URL"
fi

echo "$BASE_ISO_SHA256  $BASE_ISO" | sha256sum -c -

RESUME="${RESUME:-0}"

if [[ "$RESUME" == "1" ]]; then
  echo "Resuming existing Trebo work tree..."
  [[ -d "$ISO_DIR" ]] || die "RESUME=1 requested but $ISO_DIR does not exist"
  [[ -d "$ROOTFS" ]] || die "RESUME=1 requested but $ROOTFS does not exist"
  [[ -f "$ROOTFS/tmp/trebo-kernel-version" ]] || die "RESUME=1 requested but the Linux 7 stage marker is missing"
else
  echo "Preparing working tree..."
  rm -rf "$ISO_DIR" "$ROOTFS"
  mkdir -p "$ISO_DIR"

  xorriso -osirrox on -indev "$BASE_ISO" -extract / "$ISO_DIR"
  chmod -R u+w "$ISO_DIR"
  unsquashfs -d "$ROOTFS" "$ISO_DIR/casper/filesystem.squashfs"
fi

# Recreate assets even during resume so the working tree always uses the
# current repository versions.
mkdir -p "$ROOTFS/tmp/trebo-assets"
rsvg-convert -w 1156 -h 867   -o "$ROOTFS/tmp/trebo-assets/background.png"   "$SCRIPT_DIR/assets/background.svg"
rsvg-convert -w 507 -h 444   -o "$ROOTFS/tmp/trebo-assets/logo.png"   "$SCRIPT_DIR/assets/logo.svg"
install -m0644 "$SCRIPT_DIR/assets/trebo-symbolic.svg" "$ROOTFS/tmp/trebo-assets/trebo-symbolic.svg"

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
    gdm3 gnome-shell
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

install_final_desktop() {
  echo 'gdm3 shared/default-x-display-manager select gdm3' | debconf-set-selections

  # Re-establish Canonical's supported Noble desktop core. --no-install-recommends
  # avoids pulling the optional Ubuntu wallpaper/Yaru recommendation bundle,
  # while still installing the session, PipeWire, portals, dock and desktop
  # services that GNOME expects to have together.
  apt-get install -y --no-install-recommends \
    ubuntu-desktop-minimal \
    gnome-tweaks \
    plymouth \
    plymouth-label \
    plymouth-theme-spinner \
    papirus-icon-theme \
    bibata-cursor-theme \
    orchis-gtk-theme \
    qt5-gtk-platformtheme \
    qt6-gtk-platformtheme \
    gnome-software \
    gparted \
    vlc \
    baobab \
    file-roller

  dpkg --configure -a
  apt-get -f install -y
  apt-get check
}

if [[ "${TREBO_RESUME_AFTER_UPGRADE:-0}" != "1" ]]; then
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
gtk-theme='Adwaita'
icon-theme='Papirus-Trebo'
cursor-theme='Bibata-Modern-Ice'
font-name='Cantarell 11'
document-font-name='Cantarell 11'
monospace-font-name='Monospace 11'

[org/gnome/shell]
enabled-extensions=['ubuntu-dock@ubuntu.com']

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
    raise SystemExit("No buggy dual-directory run-parts calls were found")
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
    before="$(grep -hE '/etc/kernel/[^ ]+\.d[[:space:]]+/usr/share/kernel/[^ ]+\.d' "${maint_scripts[@]}" 2>/dev/null | wc -l)"
    if (( before > 0 )); then
      /tmp/trebo-kernel7/fix-run-parts.py "${maint_scripts[@]}"
      patched_calls=$((patched_calls + before))
    fi
  fi

  dpkg-deb -b "$pkgdir" "/tmp/trebo-kernel7/fixed/$deb"
done

(( patched_calls > 0 )) || {
  echo "Expected the Linux 7 mainline run-parts bug, but no affected maintainer script was found." >&2
  exit 1
}

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
# Resume builds may still contain the previously-held Focal Ubiquity packages.
# Noble provides Ubiquity 24.04.x, so repair the entire installer stack from
# the final repositories before applying Trebo branding.
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

UBIQUITY_VERSION="$(dpkg-query -W -f='${Version}' ubiquity 2>/dev/null || true)"
case "$UBIQUITY_VERSION" in
  24.04.*) ;;
  *)
    echo "Expected Noble Ubiquity 24.04.x, got: $UBIQUITY_VERSION" >&2
    exit 1
    ;;
esac

# Test the Python GTK frontend imports before wasting time rebuilding the
# SquashFS. This catches mixed-release Ubiquity/library problems at build time.
PYTHONPATH=/usr/lib/ubiquity python3 - <<'PY_UBIQUITY_TEST'
import ubiquity
import ubiquity.frontend.gtk_ui
print("Ubiquity GTK frontend import test passed.")
PY_UBIQUITY_TEST

# ---------------------------------------------------------------------------
# LIVE-BOOT INTEGRITY
# ---------------------------------------------------------------------------
# The rootfs is now Noble-based (or a resumed Noble work tree). Refresh Casper
# from the final repositories so its initramfs scripts match the final
# initramfs-tools version. This is intentionally done AFTER the kernel-first
# stage and the release transitions.
apt-mark unhold casper 2>/dev/null || true
apt-get update

# Focal's old Wubi helper, lupin-casper, owns
# /usr/share/initramfs-tools/scripts/casper-premount/20iso_scan.
# Modern Casper owns that file itself, so leaving lupin-casper installed makes
# dpkg abort the Casper upgrade with a file-ownership collision.
#
# Do NOT use apt remove/purge here: that could expand into dependency changes.
# dpkg --no-act verifies that removing this exact obsolete Wubi helper is safe,
# and dpkg --remove then removes ONLY that package.
remove_obsolete_lupin_casper

# A previous interrupted Casper unpack can leave dpkg's status database in a
# partial state. Reinstall the single target package directly from the current
# Noble archive rather than asking apt to perform a broad dependency repair.
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
DISTRIB_CODENAME=trebo
DISTRIB_DESCRIPTION="Trebo Linux 1.0"
EOF_LSB

printf 'Trebo Linux 1.0 \\n \\l\n' > /etc/issue
printf 'Trebo Linux 1.0\n' > /etc/issue.net

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
import sys

path = Path(sys.argv[1])
text = path.read_text()
needle = "this._iconActor.iconName = `view-app-grid-${Main.sessionMode.currentMode}-symbolic`;"
replacement = """this._iconActor.iconName = null;
        this._iconActor.gicon = Gio.Icon.new_for_string('/usr/share/icons/hicolor/scalable/apps/trebo-symbolic.svg');"""
if needle not in text:
    raise SystemExit("Ubuntu Dock Show Apps icon assignment was not found")
path.write_text(text.replace(needle, replacement, 1))
print("Patched Ubuntu Dock Show Applications icon to Trebo.")
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

# A leftover Yaru icon directory must not win icon lookup.
find /usr/share/icons -mindepth 1 -maxdepth 1 -type d -name 'Yaru*' \
  -exec rm -rf {} + 2>/dev/null || true

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f "$TREBO_ICONS" || true
  [[ -d /usr/share/icons/Papirus ]] && gtk-update-icon-cache -f /usr/share/icons/Papirus || true
fi

# Trebo GTK theme: use the Noble-packaged Orchis-Grey implementation (including
# its GTK4 assets), but publish it under Trebo's own theme name.
[[ -d /usr/share/themes/Orchis-Grey ]] || {
  echo "Orchis-Grey GTK theme is missing." >&2
  exit 1
}
rm -rf /usr/share/themes/Trebo
cp -a /usr/share/themes/Orchis-Grey /usr/share/themes/Trebo
if [[ -f /usr/share/themes/Trebo/index.theme ]]; then
  sed -i -E 's/^(Name=).*/\1Trebo/' /usr/share/themes/Trebo/index.theme || true
fi

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
enabled-extensions=['ubuntu-dock@ubuntu.com']

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
enabled-extensions=['ubuntu-dock@ubuntu.com']

[org.gnome.desktop.interface:ubuntu]
gtk-theme='Trebo'
icon-theme='Papirus-Trebo'
cursor-theme='Bibata-Modern-Ice'
color-scheme='default'

[org.gnome.shell:ubuntu]
disable-user-extensions=false
enabled-extensions=['ubuntu-dock@ubuntu.com']

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

glib-compile-schemas /usr/share/glib-2.0/schemas
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

# Replace the Ubiquity slideshow with the Trebo installation screen.
SLIDES=/usr/share/ubiquity-slideshow/slides
if [[ -d "$SLIDES" ]]; then
  rm -rf "$SLIDES"/*
  cp /tmp/trebo-assets/background.png "$SLIDES/trebo-background.png"

  cat > "$SLIDES/index.html" <<'EOF_SLIDE'
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<style>
html,body {
  width:100%;
  height:100%;
  margin:0;
  overflow:hidden;
  background:#202020;
  font-family:Cantarell,DejaVu Sans,sans-serif;
}
body {
  background-image:url('trebo-background.png');
  background-size:100% 100%;
  background-position:center;
  background-repeat:no-repeat;
  display:flex;
  align-items:center;
  justify-content:center;
  color:white;
}
#text {
  font-size:34px;
  font-weight:600;
  text-shadow:0 1px 4px rgba(0,0,0,.7);
}
</style>
</head>
<body><div id="text">Trebo is installing</div></body>
</html>
EOF_SLIDE

  cat > "$SLIDES/directory.jsonp" <<'EOF_DIRECTORY'
JSONP({"slides":["index.html"]});
EOF_DIRECTORY
fi

# Replace only Ubiquity's small logo with a correctly sized dark Trebo mark.
# The old build copied a 507x444 white image into both artwork slots.
if [[ -e /usr/share/ubiquity/pixmaps/ubuntu-logo.png ]]; then
  install -m0644 /tmp/trebo-assets/trebo-installer-logo.png \
    /usr/share/ubiquity/pixmaps/ubuntu-logo.png
fi
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

fun show_text(text) {
    text_image = Image.Text(text, 1.0, 1.0, 1.0, 1.0, "Sans 24");
    text_sprite.SetImage(text_image);
    text_sprite.SetPosition(
        Window.GetWidth() / 2 - text_image.GetWidth() / 2,
        Window.GetHeight() / 2 - text_image.GetHeight() / 2,
        1000
    );
}

if (Plymouth.GetMode() == "shutdown")
    show_text("Trebo is closing");
else
    show_text("Trebo is starting");

fun message_callback(text) {
    if (text == "Please remove media")
        show_text("Please remove media");
}

Plymouth.SetMessageFunction(message_callback);
EOF_PLYMOUTH_SCRIPT

update-alternatives   --install /usr/share/plymouth/themes/default.plymouth   default.plymouth "$THEME/trebo.plymouth" 500
update-alternatives   --set default.plymouth "$THEME/trebo.plymouth"

# Casper uses this message when the live medium should be removed.
if [[ -f /sbin/casper-stop ]]; then
  sed -i -E     's|^MSG=.*$|MSG="Please remove media"|; s|^MSG_FALLBACK=.*$|MSG_FALLBACK="Please remove media"|'     /sbin/casper-stop
fi

# IMPORTANT: build the live Linux 7 initramfs only AFTER Trebo's Plymouth
# theme has been installed and made the default. The initramfs is the first
# userspace visible during boot. If it contains Ubuntu's default Plymouth
# theme, the machine briefly shows Ubuntu and only switches to Trebo after the
# real root filesystem mounts.
KVER="$(cat /tmp/trebo-kernel-version)"
echo "Rebuilding Linux 7 LIVE initramfs with Casper + Trebo Plymouth..."
rm -f "/boot/initrd.img-$KVER"
BOOT=casper update-initramfs -c -k "$KVER"

# Capture the complete listing ONCE, then inspect the file. Do not use
# "lsinitramfs | grep -q" while pipefail is enabled: grep -q exits as soon as
# it finds a match, which can SIGPIPE lsinitramfs and make a successful check
# look like a failed pipeline.
INITRD_LIST="$(mktemp)"
if ! lsinitramfs "/boot/initrd.img-$KVER" > "$INITRD_LIST"; then
  echo "Could not list Linux 7 initramfs contents." >&2
  rm -f "$INITRD_LIST"
  exit 1
fi

if ! grep -Fx 'scripts/casper' "$INITRD_LIST" >/dev/null; then
  echo "Linux 7 initramfs is missing /scripts/casper." >&2
  echo "Casper-related files that DID make it into the initramfs:" >&2
  grep -i casper "$INITRD_LIST" >&2 || true
  echo "Source Casper files in the rootfs:" >&2
  find /usr/share/initramfs-tools -maxdepth 3 -iname '*casper*' -print >&2 || true
  rm -f "$INITRD_LIST"
  exit 1
fi

if ! grep -F 'usr/share/plymouth/themes/trebo/trebo.plymouth' "$INITRD_LIST" >/dev/null; then
  echo "Linux 7 initramfs does not contain the Trebo Plymouth theme." >&2
  rm -f "$INITRD_LIST"
  exit 1
fi

if ! grep -F 'usr/share/plymouth/themes/trebo/background.png' "$INITRD_LIST" >/dev/null; then
  echo "Linux 7 initramfs does not contain the Trebo Plymouth background." >&2
  rm -f "$INITRD_LIST"
  exit 1
fi

echo "Verified Linux 7 initramfs contains Casper and Trebo Plymouth."
rm -f "$INITRD_LIST"

echo "Final Trebo live kernel: $KVER"

# Do not ship crash reports generated while upgrading packages inside chroot;
# they trigger bogus first-boot "System program problem detected" dialogs.
rm -rf /var/crash/* 2>/dev/null || true

dpkg --configure -a
apt-get -f install -y
apt-get check
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

for pkg in \
  ubuntu-desktop-minimal \
  ubuntu-session \
  gnome-shell \
  gdm3 \
  pipewire-pulse \
  wireplumber \
  xdg-desktop-portal-gnome \
  gnome-shell-extension-ubuntu-dock \
  papirus-icon-theme \
  bibata-cursor-theme \
  orchis-gtk-theme
do
  [[ "$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null || true)" == "installed" ]] || {
    echo "Required final Trebo package is not fully installed: $pkg" >&2
    exit 1
  }
done

apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/trebo-assets /tmp/trebo-customize.sh
CHROOT_EOF

chmod +x "$ROOTFS/tmp/trebo-customize.sh"

mounted=0
cleanup_mounts() {
  set +e
  if [[ $mounted -eq 1 ]]; then
    umount -lf "$ROOTFS/run" 2>/dev/null || true
    umount -lf "$ROOTFS/sys" 2>/dev/null || true
    umount -lf "$ROOTFS/proc" 2>/dev/null || true
    umount -lf "$ROOTFS/dev/pts" 2>/dev/null || true
    umount -lf "$ROOTFS/dev" 2>/dev/null || true
  fi
}
trap cleanup_mounts EXIT

mount --bind /dev "$ROOTFS/dev"
mount --bind /dev/pts "$ROOTFS/dev/pts"
mount -t proc proc "$ROOTFS/proc"
mount -t sysfs sys "$ROOTFS/sys"
mount --bind /run "$ROOTFS/run"
mounted=1

if [[ -e "$ROOTFS/etc/resolv.conf" || -L "$ROOTFS/etc/resolv.conf" ]]; then
  cp -aL "$ROOTFS/etc/resolv.conf" "$ROOTFS/etc/resolv.conf.trebo-backup" || true
fi
rm -f "$ROOTFS/etc/resolv.conf"
cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

echo "Customizing Trebo root filesystem..."
CHROOT_LOG="$WORKDIR/trebo-chroot.log"
if [[ "$RESUME" == "1" ]]; then
  if ! chroot "$ROOTFS" /usr/bin/env TREBO_RESUME_AFTER_UPGRADE=1 /bin/bash /tmp/trebo-customize.sh 2>&1 | tee "$CHROOT_LOG"; then
    rc=${PIPESTATUS[0]}
    echo >&2
    echo "Trebo customization failed inside the chroot (exit $rc)." >&2
    echo "The exact inner command is shown above. Last 80 log lines:" >&2
    tail -n 80 "$CHROOT_LOG" >&2 || true
    exit "$rc"
  fi
else
  if ! chroot "$ROOTFS" /bin/bash /tmp/trebo-customize.sh 2>&1 | tee "$CHROOT_LOG"; then
    rc=${PIPESTATUS[0]}
    echo >&2
    echo "Trebo customization failed inside the chroot (exit $rc)." >&2
    echo "The exact inner command is shown above. Last 80 log lines:" >&2
    tail -n 80 "$CHROOT_LOG" >&2 || true
    exit "$rc"
  fi
fi

rm -f "$ROOTFS/etc/resolv.conf"
if [[ -f "$ROOTFS/etc/resolv.conf.trebo-backup" ]]; then
  mv "$ROOTFS/etc/resolv.conf.trebo-backup" "$ROOTFS/etc/resolv.conf"
else
  ln -s /run/systemd/resolve/stub-resolv.conf "$ROOTFS/etc/resolv.conf" || true
fi

cleanup_mounts
mounted=0
trap - EXIT

# The live ISO now boots the same Linux 7 kernel installed in the rootfs.
KVER="$(cat "$ROOTFS/tmp/trebo-kernel-version")"
[[ "$KVER" == 7.* ]] || die "Refusing to publish ISO: expected Linux 7, got $KVER"
[[ -f "$ROOTFS/boot/vmlinuz-$KVER" ]] || die "Missing Linux 7 vmlinuz"
[[ -f "$ROOTFS/boot/initrd.img-$KVER" ]] || die "Missing Linux 7 initrd"

cp "$ROOTFS/boot/vmlinuz-$KVER" "$ISO_DIR/casper/vmlinuz"
cp "$ROOTFS/boot/initrd.img-$KVER" "$ISO_DIR/casper/initrd"

# Keep the version marker until after the live kernel has been copied.
rm -f "$ROOTFS/tmp/trebo-kernel-version"

# Media identity.
printf '%s\n' 'Trebo Linux 1.0 - Release amd64' > "$ISO_DIR/.disk/info"

if [[ -f "$ISO_DIR/README.diskdefines" ]]; then
  sed -i 's/Ubuntu/Trebo Linux/g' "$ISO_DIR/README.diskdefines"
fi

# Change only visible boot-menu text. Do not rewrite lowercase package paths,
# preseed paths, boot parameters, or repository identifiers.
for boot_file in   "$ISO_DIR/boot/grub/grub.cfg"   "$ISO_DIR/isolinux/txt.cfg"   "$ISO_DIR/isolinux/menu.cfg"   "$ISO_DIR/isolinux/isolinux.cfg"
do
  [[ -f "$boot_file" ]] || continue
  sed -i 's/Ubuntu/Trebo/g' "$boot_file"
done

echo "Updating filesystem manifest..."
chroot "$ROOTFS" dpkg-query -W --showformat='${Package} ${Version}\n'   > "$ISO_DIR/casper/filesystem.manifest"

printf '%s\n' "$(du -sx --block-size=1 "$ROOTFS" | cut -f1)"   > "$ISO_DIR/casper/filesystem.size"

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
