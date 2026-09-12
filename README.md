# Trebo Linux

Trebo starts from the Ubuntu 20.04.6 desktop image, installs a Linux 7.x mainline kernel first, then moves the userspace through Jammy to Noble before applying the Trebo GNOME desktop and branding.

The build downloads the official Ubuntu 20.04.6 AMD64 desktop ISO and verifies its SHA-256. While the rootfs is still Focal, it discovers and installs the newest stable Ubuntu Mainline Linux 7.x generic kernel. Only after Linux 7 is installed does it move APT through Jammy and then Noble, reassert GNOME, rebuild and validate the Linux 7 Casper initramfs, apply Trebo branding, rebuild the SquashFS, and recreate a hybrid BIOS/UEFI bootable ISO.

The final userspace uses Noble repositories. Ubiquity and Casper are deliberately retained from the original installer stack because Trebo requires Ubiquity. The script never runs apt remove, apt purge, or apt autoremove; release transitions are simulated first and are aborted if APT wants to remove critical boot, desktop, or installer packages.

## Build

On a Debian/Ubuntu host with enough free disk space, install every required host-side build package first:

```bash
sudo apt update && sudo apt install -y curl xorriso squashfs-tools librsvg2-bin coreutils util-linux sed gawk grep findutils
```

Then build Trebo:

```bash
sudo bash ./build-trebo.sh
```

Output:

```
Trebo-20.04.6-amd64.iso
Trebo-20.04.6-amd64.iso.sha256
```

The GitHub Actions workflow also builds the ISO automatically and uploads it as a workflow artifact.
