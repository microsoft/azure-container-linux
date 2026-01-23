# Paths Parity between Flatcar and Azure Container Linux (ACL)

This document describes the parity between the key OS image paths in Flatcar vs ACL. Initially, we're prioritizing testing parity, meaning that we will mostly preserve the Flatcar paths in the ACL builds, to avoid any potential test failures. In the long run, we want to rename as many of these paths as possible, to maintain consistent ACL branding.

## Paths Preserved from Flatcar

The following paths are presrved from Flatcar into ACL builds:

### `/usr/share/flatcar/etc`

This is the lower dir in the `/etc` overlay, or `etc-overlay`, setup. Path referenced in:

- `build_library/rpm/additional_files/etc-overlay.sh`
- `build_library/rpm/additional_files/etc-overlay-populate.service`
- `build_library/rpm/additional_files/copy-files-etc.conf`
- `build_library/rpm/additional_files/initrd-setup-etc-overlay.service`
- `build_library/rpm/additional_files/module-setup.sh`
- `build_library/rpm/build_image_util.sh`

### `/boot/flatcar`

This is the dedicated Flatcar directory inside `/boot`, which contains a number of key directories and files, including the GRUB directory, initramfs, Linux kernel, etc.

- `build_library/rpm/grub`
- `build_library/rpm/build_image_util.sh`
