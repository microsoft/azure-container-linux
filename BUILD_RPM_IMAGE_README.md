# RPM-Based Image Build System for Azure Container Linux derivative of Flatcar Linux

This document describes the RPM-based image build system for Flatcar, which
enables building Azure Container Linux images using packages from Azure Linux
3.0 repositories.

## Overview

The build system supports package source modes:

- **PORTAGE**: (default) Traditional Flatcar build using only Portage packages
- **RPM**: (new) Azure Container Linux build using Azure Linux RPM packages

This RPM approach provides:

- Faster builds (pre-built RPM binaries vs. compiling from source)
- Better alignment with Azure Linux & Fedora ecosystem
- Maintained compatibility with Flatcar-specific tooling

## Prerequisites

### Required Tools

- **Docker**: For SDK container management
- **libvirt/KVM**: For VM testing (optional but recommended)
- **virsh**: VM management CLI
- **expect**: For serial console automation (VM testing)
- **curl**: For downloading RPMs
- **createrepo_c**: For creating local RPM repository metadata

Install on Debian/Ubuntu:

```bash
sudo apt-get install docker-ce qemu-kvm libvirt-daemon-system libvirt-clients \
  bridge-utils expect curl createrepo-c
```

Note that `docker.io` (instead of `docker-ce`) might work as well.

Install on Azure Linux:

```bash
sudo tdnf install -y moby-engine qemu-kvm libvirt libvirt-client expect curl createrepo_c edk2-ovmf
```

### System Requirements

- **Disk Space**: 50GB+ for SDK container, RPMs, and build artifacts
- **RAM**: 8GB+ recommended
- **Network**: Access to Azure Linux package repositories

### SDK Container

The build system requires the Flatcar SDK container, which includes all build tools.

## Complete Build Workflow

### Phase 1: SDK Container Setup

#### Rebuild SDK Container

```bash
# Rebuild SDK container with updated tools or dependencies
./build_rpm_image.sh --build-sdk-container
```

**When to rebuild SDK:**

- First time setup
- After updating SDK dependencies
- When RPM/dnf tools need updates
- If SDK container is corrupted
- To be confirmed: Also needed after changing a commit.

### Phase 2: Download Azure Linux RPM Packages

Download required RPM packages from Azure Linux repositories.

The `build_rpm_image.sh` script can handle downloading automatically, but you can also run the download step separately:

```bash
# Download all required RPMs
./download_azure_linux_rpms.sh

# Force re-download (refresh all packages)
./download_azure_linux_rpms.sh --force
```

**Download behavior:**

- Checks for existing RPMs in staging directory
- Only downloads missing packages (incremental)
- Resolves and downloads all dependencies automatically
- Creates local repository metadata with `createrepo_c`

Note that only a subset of packages is downloaded, as majority of packages is
downloaded during the image build using `dnf`.

**Staging directory:** `__build__/rpm-staging/`

### Phase 3: Build the Image

Build the Flatcar production image using hybrid package sources.

```bash
# Download RPMs and build image in one command
./build_rpm_image.sh --rebuild
```

**Build output location:** `__build__/images/images/amd64-usr/latest/`

### Phase 4: Build VM Image (Optional)

Convert the production image to a VM-ready format.

```bash
# Build VM image after main build
./build_rpm_image.sh --build-vm-image
```

**VM image output:** `__build__/images/images/amd64-usr/latest/flatcar_production_qemu_uefi_image.img`

### Phase 5: Start VM and Run Tests

#### Using build_rpm_image.sh (Integrated Testing)

```bash
# Just start the VM and observe the boot sequence, get access to interactive console.
./build_rpm_image.sh --start-vm

# Start VM and run inline command via serial console
./build_rpm_image.sh --start-vm \
  --run-script="cat /etc/os-release"

# Run test script on VM (this script is included and used for a basic smoke test for now)
./build_rpm_image.sh --skip-download --start-vm \
  --run-script=./run-container-test.sh

# Run multiple test scripts
./build_rpm_image.sh --skip-download --start-vm \
  --run-script=./tests/01-boot.sh \
  --run-script=./tests/02-network.sh \
  --run-script=./tests/03-services.sh
```

**Serial Console Access (Default):**

- No SSH or ignition configuration needed
- Uses `expect` to automate console login
- Default user: `root` (no password)
- Customize: `--console-user=core --console-password=mypass`

#### Cleanup

Subsequent runs will clean up the VM automatically. To manually clean up the VM:

```bash
# Stop VM
virsh destroy flatcar-hybrid

# Remove VM
virsh undefine --nvram flatcar-hybrid
```

## Common Workflows

### Development Iteration

Efficient workflow for iterative development:

```bash
# Quick rebuild after packaging/script changes
./build_rpm_image.sh --rebuild

# Rebuild and retest
./build_rpm_image.sh --rebuild --build-vm-image --start-vm \
  --run-script=./build_library/rpm/tests/run-container-test.sh

# Or use the short cut of the command above (runs additional tests as well):
./build_rpm_image.sh --rebuild-and-test
```

## Troubleshooting

### Common Issues

- **Issue**: Red block preceeded by: `sudo: rpm: command not found`
  **Solution**: Ensure SDK container is rebuilt with RPM tools:

  ```bash
  ./build_rpm_image.sh --build-sdk-container
  ```
