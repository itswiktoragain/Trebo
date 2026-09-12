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

trap 'echo "Trebo build failed at line $LINENO." >&2' ERR

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

echo "Preparing working tree..."
rm -rf "$ISO_DIR" "$ROOTFS"
mkdir -p "$ISO_DIR"

xorriso -osirrox on -indev "$BASE_ISO" -extract / "$ISO_DIR"
chmod -R u+w "$ISO_DIR"
unsquashfs -d "$ROOTFS" "$ISO_DIR/casper/filesystem.squashfs"

mkdir -p "$ROOTFS/tmp/trebo-assets"
rsvg-convert -w 1156 -h 867   -o "$ROOTFS/tmp/trebo-assets/background.png"   "$SCRIPT_DIR/assets/background.svg"
rsvg-convert -w 507 -h 444   -o "$ROOTFS/tmp/trebo-assets/logo.png"   "$SCRIPT_DIR/assets/logo.svg"

cat > "$ROOTFS/tmp/trebo-customize.sh" <<'CHROOT_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

echo "Preparing Focal only far enough to install Linux 7..."
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl initramfs-tools initramfs-tools-core \
  kmod linux-base software-properties-common

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
    before="$(grep -hEc '/etc/kernel/[^ ]+\.d[[:space:]]+/usr/share/kernel/[^ ]+\.d' "${maint_scripts[@]}" || true)"
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

# Keep the original Ubiquity/Casper installer stack before moving the userspace
# forward. Noble no longer treats Ubiquity as its normal desktop installer, but
# Trebo explicitly requires Ubiquity, so these packages are protected.
apt-get install -y --no-install-recommends \
  ubiquity ubiquity-frontend-gtk casper
apt-mark hold ubiquity ubiquity-frontend-gtk casper || true

# ---------------------------------------------------------------------------
# PHASE 2: MODERNIZE THE USERSpace REPOSITORIES
# ---------------------------------------------------------------------------
# Move through supported LTS suites in order instead of pointing a Focal rootfs
# straight at a much newer release in one jump.
write_ubuntu_sources() {
  local suite="$1"

  cat > /etc/apt/sources.list <<EOF_SOURCES
deb http://archive.ubuntu.com/ubuntu $suite main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu $suite-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu $suite-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu $suite-security main restricted universe multiverse
EOF_SOURCES

  # Prevent an old ISO-specific source fragment from mixing releases.
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
    if awk '$1 == "Remv" {print $2}' "$simulation" | grep -qx "$critical"; then
      echo "Refusing repository upgrade because apt wants to remove critical package: $critical" >&2
      cat "$simulation" >&2
      rm -f "$simulation"
      exit 1
    fi
  done

  rm -f "$simulation"
}

upgrade_to_suite() {
  local suite="$1"
  echo "Switching Trebo package repositories to $suite..."
  write_ubuntu_sources "$suite"
  apt-get update --allow-releaseinfo-change

  # Let apt perform the release transition, but only after the simulation above
  # proves it is not taking the boot/desktop/installer core with it.
  guard_dist_upgrade
  apt-get -y full-upgrade
  apt-get -f install -y
}

# Focal -> Jammy -> Noble. This gives Trebo a modern LTS userspace while the
# Linux 7 kernel was already installed before either repository transition.
upgrade_to_suite jammy
upgrade_to_suite noble

# Install/reassert the generic GNOME desktop from the final repositories.
echo 'gdm3 shared/default-x-display-manager select gdm3' | debconf-set-selections
apt-get install -y --no-install-recommends \
  gdm3 \
  gnome-shell \
  gnome-session \
  gnome-control-center \
  gnome-terminal \
  nautilus \
  gnome-settings-daemon \
  gnome-tweaks \
  adwaita-icon-theme \
  fonts-cantarell \
  plymouth \
  plymouth-label \
  plymouth-theme-spinner

# The final Linux 7 initramfs is deliberately rebuilt later, after the
# Trebo Plymouth theme is installed and selected. Rebuilding it here would
# embed Ubuntu's Plymouth theme into early userspace and cause a brief Ubuntu
# splash before Trebo takes over.
KVER="$(cat /tmp/trebo-kernel-version)"

[[ -f "/boot/vmlinuz-$KVER" ]] || {
  echo "Linux 7 kernel disappeared during the userspace upgrade." >&2
  exit 1
}

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

# Remove only visible Ubuntu session/desktop payloads from the finished image.
# No package database operation is used here.
rm -f   /usr/share/xsessions/ubuntu.desktop   /usr/share/xsessions/ubuntu-xorg.desktop   /usr/share/wayland-sessions/ubuntu.desktop   /usr/share/wayland-sessions/ubuntu-wayland.desktop

rm -rf /usr/share/gnome-shell/extensions/ubuntu-dock@ubuntu.com

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
gtk-theme='Adwaita'
icon-theme='Adwaita'
font-name='Cantarell 11'
document-font-name='Cantarell 11'
monospace-font-name='Monospace 11'

[org/gnome/shell]
enabled-extensions=[]
EOF_DCONF

dconf update

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

# Replace installer artwork where those files exist.
for installer_art in   /usr/share/ubiquity/pixmaps/ubuntu_installed.png   /usr/share/ubiquity/pixmaps/ubuntu-logo.png
do
  if [[ -e "$installer_art" ]]; then
    cp /tmp/trebo-assets/logo.png "$installer_art"
  fi
done

# Replace obvious user-facing Ubuntu text in Ubiquity UI definitions.
for ui_file in /usr/share/ubiquity/gtk/*.ui; do
  [[ -f "$ui_file" ]] || continue
  sed -i     -e 's/Welcome to Ubuntu/Welcome to Trebo/g'     -e 's/Install Ubuntu/Install Trebo/g'     -e 's/>Ubuntu</>Trebo</g'     "$ui_file"
done

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
echo "Rebuilding Linux 7 initramfs with Trebo Plymouth embedded..."
update-initramfs -u -k "$KVER"

# Refuse to publish an ISO unless the live initramfs has both Casper and the
# Trebo Plymouth assets. This catches the exact Ubuntu-then-Trebo regression.
if ! lsinitramfs "/boot/initrd.img-$KVER" | grep -qE '(^|/)scripts/casper(/|$)'; then
  echo "Linux 7 initramfs does not contain Casper; refusing to create a broken ISO." >&2
  exit 1
fi

if ! lsinitramfs "/boot/initrd.img-$KVER" | grep -q 'usr/share/plymouth/themes/trebo/trebo.plymouth'; then
  echo "Linux 7 initramfs does not contain the Trebo Plymouth theme." >&2
  exit 1
fi

if ! lsinitramfs "/boot/initrd.img-$KVER" | grep -q 'usr/share/plymouth/themes/trebo/background.png'; then
  echo "Linux 7 initramfs does not contain the Trebo Plymouth background." >&2
  exit 1
fi

echo "Final Trebo live kernel: $KVER"

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
chroot "$ROOTFS" /bin/bash /tmp/trebo-customize.sh

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
