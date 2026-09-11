#!/usr/bin/env bash
set -Eeuo pipefail

BASE_ISO_URL="https://releases.ubuntu.com/focal/ubuntu-20.04.6-desktop-amd64.iso"
BASE_ISO_SHA256="510ce77afcb9537f198bc7daa0e5b503b6e67aaed68146943c231baeaab94df1"
BASE_ISO="${BASE_ISO:-$PWD/ubuntu-20.04.6-desktop-amd64.iso}"
OUTPUT_ISO="${OUTPUT_ISO:-$PWD/Trebo-20.04.6-amd64.iso}"
WORKDIR="${WORKDIR:-$PWD/trebo-work}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ISO_DIR="$WORKDIR/iso"
ROOTFS="$WORKDIR/rootfs"

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }
for c in curl sha256sum xorriso unsquashfs mksquashfs chroot mount umount sed awk grep find md5sum; do need_cmd "$c"; done

if [[ ${EUID} -ne 0 ]]; then
  echo "Run this script as root (sudo ./build-trebo.sh)." >&2
  exit 1
fi

mkdir -p "$WORKDIR"

if [[ ! -f "$BASE_ISO" ]]; then
  echo "Downloading Ubuntu 20.04.6 desktop ISO..."
  curl -fL --retry 5 --retry-delay 3 --continue-at - -o "$BASE_ISO" "$BASE_ISO_URL"
fi

echo "$BASE_ISO_SHA256  $BASE_ISO" | sha256sum -c -

rm -rf "$ISO_DIR" "$ROOTFS"
mkdir -p "$ISO_DIR"

xorriso -osirrox on -indev "$BASE_ISO" -extract / "$ISO_DIR"
chmod -R u+w "$ISO_DIR"

unsquashfs -d "$ROOTFS" "$ISO_DIR/casper/filesystem.squashfs"

mkdir -p "$ROOTFS/tmp/trebo-assets"
base64 -d "$SCRIPT_DIR/assets/background.b64" > "$ROOTFS/tmp/trebo-assets/background.png"
base64 -d "$SCRIPT_DIR/assets/logo.b64" > "$ROOTFS/tmp/trebo-assets/logo.png"

cat > "$ROOTFS/tmp/trebo-customize.sh" <<'CHROOT_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

apt-get update
apt-get -y full-upgrade

echo 'gdm3 shared/default-x-display-manager select gdm3' | debconf-set-selections
apt-get install -y --no-install-recommends   gdm3 gnome-shell gnome-session gnome-control-center gnome-terminal nautilus   gnome-settings-daemon gnome-tweaks adwaita-icon-theme-full plymouth plymouth-themes

mapfile -t purge_pkgs < <(
  dpkg-query -W -f='${binary:Package}
' 2>/dev/null |   grep -E '^(ubuntu-desktop|ubuntu-desktop-minimal|ubuntu-minimal|ubuntu-standard|ubuntu-session|ubuntu-settings|ubuntu-wallpapers[^:]*|ubuntu-docs|ubuntu-report|gnome-shell-extension-ubuntu-dock)(:.*)?$' || true
)
if ((${#purge_pkgs[@]})); then
  apt-get purge -y "${purge_pkgs[@]}"
fi
apt-get clean
rm -rf /var/lib/apt/lists/*

cat > /etc/os-release <<'EOF_OS'
NAME="Trebo Linux"
PRETTY_NAME="Trebo Linux 20.04.6"
ID=trebo
ID_LIKE="debian"
VERSION_ID="20.04"
VERSION="20.04.6"
VERSION_CODENAME=focal
HOME_URL="https://github.com/itswiktoragain/Trebo"
SUPPORT_URL="https://github.com/itswiktoragain/Trebo"
BUG_REPORT_URL="https://github.com/itswiktoragain/Trebo/issues"
EOF_OS
cp /etc/os-release /usr/lib/os-release
cat > /etc/lsb-release <<'EOF_LSB'
DISTRIB_ID=Trebo
DISTRIB_RELEASE=20.04
DISTRIB_CODENAME=focal
DISTRIB_DESCRIPTION="Trebo Linux 20.04.6"
EOF_LSB
printf 'Trebo Linux 20.04.6 \\n \\l\n' > /etc/issue
printf 'Trebo Linux 20.04.6\n' > /etc/issue.net

while IFS= read -r -d '' f; do
  sed -i -E '/^(Name|GenericName|Comment|Keywords)(\[[^]]+\])?=/ s/Ubuntu/Trebo/g; /^(Name|GenericName|Comment|Keywords)(\[[^]]+\])?=/ s/ubuntu/Trebo/g' "$f" || true
done < <(find /usr/share/applications /etc/xdg/autostart -type f -name '*.desktop' -print0 2>/dev/null)

install -Dm0644 /tmp/trebo-assets/background.png /usr/share/backgrounds/trebo-background.png
install -Dm0644 /tmp/trebo-assets/logo.png /usr/share/pixmaps/trebo-logo.png

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

[org/gnome/shell]
enabled-extensions=[]
EOF_DCONF
dconf update || true

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
html,body{width:100%;height:100%;margin:0;overflow:hidden;background:#202020;font-family:DejaVu Sans,sans-serif;}
body{background-image:url('trebo-background.png');background-size:100% 100%;background-position:center;background-repeat:no-repeat;display:flex;align-items:center;justify-content:center;color:white;}
#text{font-size:34px;font-weight:600;text-shadow:0 1px 4px rgba(0,0,0,.7);}
</style>
</head>
<body><div id="text">Trebo is installing</div></body>
</html>
EOF_SLIDE
  cat > "$SLIDES/directory.jsonp" <<'EOF_DIR'
JSONP({"slides":["index.html"]});
EOF_DIR
fi

for p in /usr/share/ubiquity/pixmaps/ubuntu_installed.png /usr/share/ubiquity/pixmaps/ubuntu-logo.png; do
  [[ -e "$p" ]] && cp /tmp/trebo-assets/logo.png "$p"
done

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
cat > "$THEME/trebo.script" <<'EOF_SCRIPT'
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
EOF_SCRIPT

update-alternatives --install /usr/share/plymouth/themes/default.plymouth default.plymouth "$THEME/trebo.plymouth" 500
update-alternatives --set default.plymouth "$THEME/trebo.plymouth"

if [[ -f /sbin/casper-stop ]]; then
  sed -i -E 's|^MSG=.*$|MSG="Please remove media"|; s|^MSG_FALLBACK=.*$|MSG_FALLBACK="Please remove media"|' /sbin/casper-stop
fi

for f in /usr/share/ubiquity/gtk/*.ui; do
  [[ -f "$f" ]] || continue
  sed -i 's/>Ubuntu</>Trebo</g; s/Welcome to Ubuntu/Welcome to Trebo/g; s/Install Ubuntu/Install Trebo/g' "$f" || true
done

update-initramfs -u -k all || true

rm -rf /tmp/trebo-assets /tmp/trebo-customize.sh
CHROOT_EOF
chmod +x "$ROOTFS/tmp/trebo-customize.sh"

mount --bind /dev "$ROOTFS/dev"
mount --bind /dev/pts "$ROOTFS/dev/pts"
mount -t proc proc "$ROOTFS/proc"
mount -t sysfs sys "$ROOTFS/sys"
mount --bind /run "$ROOTFS/run"

cleanup_mounts() {
  set +e
  umount -lf "$ROOTFS/run" 2>/dev/null || true
  umount -lf "$ROOTFS/sys" 2>/dev/null || true
  umount -lf "$ROOTFS/proc" 2>/dev/null || true
  umount -lf "$ROOTFS/dev/pts" 2>/dev/null || true
  umount -lf "$ROOTFS/dev" 2>/dev/null || true
}
trap cleanup_mounts EXIT

if [[ -L "$ROOTFS/etc/resolv.conf" || -e "$ROOTFS/etc/resolv.conf" ]]; then
  cp -a "$ROOTFS/etc/resolv.conf" "$ROOTFS/etc/resolv.conf.trebo-backup" || true
  rm -f "$ROOTFS/etc/resolv.conf"
fi
cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

chroot "$ROOTFS" /bin/bash /tmp/trebo-customize.sh

rm -f "$ROOTFS/etc/resolv.conf"
if [[ -e "$ROOTFS/etc/resolv.conf.trebo-backup" || -L "$ROOTFS/etc/resolv.conf.trebo-backup" ]]; then
  mv "$ROOTFS/etc/resolv.conf.trebo-backup" "$ROOTFS/etc/resolv.conf"
fi

cleanup_mounts
trap - EXIT

for f in "$ISO_DIR/boot/grub/grub.cfg" "$ISO_DIR/isolinux/txt.cfg" "$ISO_DIR/isolinux/menu.cfg" "$ISO_DIR/isolinux/isolinux.cfg"; do
  [[ -f "$f" ]] || continue
  sed -i 's/Ubuntu/Trebo/g; s/ubuntu/Trebo/g' "$f"
done

for f in "$ISO_DIR/boot/grub/grub.cfg" "$ISO_DIR/isolinux/txt.cfg"; do
  [[ -f "$f" ]] || continue
  sed -i 's|file=/cdrom/preseed/Trebo.seed|file=/cdrom/preseed/ubuntu.seed|g' "$f"
done

rm -f "$ISO_DIR/casper/filesystem.squashfs" "$ISO_DIR/casper/filesystem.squashfs.gpg"
mksquashfs "$ROOTFS" "$ISO_DIR/casper/filesystem.squashfs" -comp xz -b 1M -noappend -no-progress

chroot "$ROOTFS" dpkg-query -W --showformat='${Package} ${Version}\n' > "$ISO_DIR/casper/filesystem.manifest"
printf '%s\n' "$(du -sx --block-size=1 "$ROOTFS" | cut -f1)" > "$ISO_DIR/casper/filesystem.size"

(
  cd "$ISO_DIR"
  rm -f md5sum.txt
  find . -type f ! -path './isolinux/boot.cat' ! -path './md5sum.txt' -print0 | sort -z | xargs -0 md5sum > md5sum.txt
)

rm -f "$OUTPUT_ISO"
xorriso   -indev "$BASE_ISO"   -outdev "$OUTPUT_ISO"   -update_r "$ISO_DIR" /   -volid "TREBO_20_04_6"   -boot_image any replay   -commit

sha256sum "$OUTPUT_ISO" | tee "$OUTPUT_ISO.sha256"
echo "Built: $OUTPUT_ISO"
