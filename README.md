# Trebo Linux

Trebo starts from the Ubuntu 20.04.6 desktop image, installs a Linux 7.x mainline kernel first, then moves the userspace through Jammy to Noble before applying the Trebo GNOME desktop and branding.

The build downloads the official Ubuntu 20.04.6 AMD64 desktop ISO and verifies its SHA-256. While the rootfs is still Focal, it discovers and installs the newest stable Ubuntu Mainline Linux 7.x generic kernel. Only after Linux 7 is installed does it move APT through Jammy and then Noble, reassert GNOME, rebuild and validate the Linux 7 Casper initramfs, apply Trebo branding, rebuild the SquashFS, and recreate a hybrid BIOS/UEFI bootable ISO.

The final userspace uses Noble repositories. Trebo repairs Ubiquity and Casper to the Noble versions after the release transition, then applies Trebo branding and desktop customization. The script never runs apt remove, apt purge, or apt autoremove; release transitions are simulated first and are aborted if APT wants to remove critical boot, desktop, or installer packages.

## Build

On a Debian/Ubuntu host with enough free disk space, install every required host-side build package first:

```bash
sudo apt update && sudo apt install -y curl xorriso squashfs-tools librsvg2-bin coreutils util-linux sed gawk grep findutils
```

Then build Trebo:

```bash
sudo bash ./build-trebo.sh
```

For fast desktop/theme/app iterations after you already have a completed Noble `trebo-work` tree, use quick mode:

```bash
sudo bash ./build-trebo.sh --quick
```

Quick mode reuses the existing Linux 7 kernel and Noble root filesystem. It skips the Linux 7 download/install, skips Focal -> Jammy -> Noble, avoids reinstalling healthy Ubiquity/Casper, and preserves the existing initramfs. It still applies Trebo customization and rebuilds the SquashFS/ISO.

If you deliberately changed Plymouth or other early-boot files and need only the initramfs refreshed:

```bash
sudo bash ./build-trebo.sh --quick --refresh-initrd
```

Output:

```
Trebo-20.04.6-amd64.iso
Trebo-20.04.6-amd64.iso.sha256
```

The GitHub Actions workflow also builds the ISO automatically and uploads it as a workflow artifact.
