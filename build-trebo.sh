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

echo "Updating the Focal package base..."
apt-get update
apt-get -y full-upgrade

# Focal keeps the generic GNOME session and Tweaks in Universe.
apt-get install -y software-properties-common
add-apt-repository -y universe
apt-get update

echo 'gdm3 shared/default-x-display-manager select gdm3' | debconf-set-selections

# IMPORTANT:
# Trebo intentionally does not apt remove, apt purge, or apt autoremove
# Ubuntu-named packages. Focal's desktop stack has many reverse dependencies
# through those packages. We keep the package graph intact and neutralize
# visible branding/files after all package operations are finished.
apt-get install -y --no-install-recommends   gdm3   gnome-shell   gnome-session   gnome-control-center   gnome-terminal   nautilus   gnome-settings-daemon   gnome-tweaks   adwaita-icon-theme   fonts-cantarell   ubiquity   ubiquity-frontend-gtk   plymouth   plymouth-label   plymouth-theme-spinner

# Rebrand the operating-system identity. On Focal /etc/os-release normally
# points at /usr/lib/os-release, so write the canonical target directly.
cat > /usr/lib/os-release <<'EOF_OS_RELEASE'
NAME="Trebo Linux"
PRETTY_NAME="Trebo Linux 20.04.6"
ID=trebo
ID_LIKE="ubuntu debian"
VERSION_ID="20.04"
VERSION="20.04.6"
VERSION_CODENAME=focal
UBUNTU_CODENAME=focal
HOME_URL="https://github.com/itswiktoragain/Trebo"
SUPPORT_URL="https://github.com/itswiktoragain/Trebo"
BUG_REPORT_URL="https://github.com/itswiktoragain/Trebo/issues"
EOF_OS_RELEASE
ln -sfn /usr/lib/os-release /etc/os-release

cat > /etc/lsb-release <<'EOF_LSB'
DISTRIB_ID=Trebo
DISTRIB_RELEASE=20.04
DISTRIB_CODENAME=focal
DISTRIB_DESCRIPTION="Trebo Linux 20.04.6"
EOF_LSB

printf 'Trebo Linux 20.04.6 \\n \\l\n' > /etc/issue
printf 'Trebo Linux 20.04.6\n' > /etc/issue.net

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

# Build installed-system initramfs images normally. We deliberately do not
# manufacture a replacement casper/live initrd here; the ISO keeps Canonical's
# known-good live initrd so the remaster cannot be made unbootable by a bad
# hand-built initramfs.
update-initramfs -u -k all

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

# Media identity.
printf '%s\n' 'Trebo Linux 20.04.6 - Release amd64' > "$ISO_DIR/.disk/info"

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
