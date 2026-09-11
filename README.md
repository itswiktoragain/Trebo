# Trebo Linux

Trebo is a remastered Ubuntu 20.04.6 desktop image with a plain GNOME desktop and Trebo branding.

The build downloads the official Ubuntu 20.04.6 AMD64 desktop ISO, verifies its official SHA-256, fully upgrades the live filesystem, installs the GNOME desktop components, removes the most visible Ubuntu desktop/branding packages, replaces user-facing release identity with Trebo Linux, installs the supplied Trebo background and logo, replaces the Ubiquity slideshow, adds a custom Plymouth startup/shutdown/media-removal screen, rebuilds the SquashFS, and recreates a hybrid BIOS/UEFI bootable ISO.

The package base remains Ubuntu Focal internally where changing package names, repository URLs, or package provenance would break updates and dependencies. User-facing OS branding is changed to Trebo.

## Build

On a Debian/Ubuntu host with enough free disk space:

```bash
sudo apt-get update
sudo apt-get install -y xorriso squashfs-tools curl
sudo ./build-trebo.sh
```

Output:

```
Trebo-20.04.6-amd64.iso
Trebo-20.04.6-amd64.iso.sha256
```

The GitHub Actions workflow also builds the ISO automatically and uploads it as a workflow artifact.
