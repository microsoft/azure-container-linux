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
  bridge-utils expect curl createrepo-c golang-1.23 rpm genisoimage ovmf
```

**Note**: `golang-1.23` is explicitly pinned because the default `golang` metapackage installs Go 1.22. The `rpm` package provides `rpmkeys` needed by the build system. The `genisoimage` package is needed for Ignition ISO creation. The `ovmf` package provides UEFI firmware for VM testing.

**Note**: `docker.io` (instead of `docker-ce`) might work as well.

Install on Azure Linux:

```bash
sudo tdnf install -y moby-engine docker-cli qemu-kvm libvirt libvirt-client expect curl createrepo_c edk2-ovmf cdrkit swtpm make golang-1.24.3 acl rpm-build
```

**Note**: Go 1.24.3 is explicitly pinned. Go 1.25+ on Azure Linux uses `systemcrypto` which requires `CGO_ENABLED=1`, but the Azure Linux toolkit currently only supports `CGO_ENABLED=0`.

**Important**: On Azure Linux, `moby-engine` does not include the Docker CLI - you must install `docker-cli` separately.

### Start Services and Configure Groups (Azure Linux)

After installation, start required services:

```bash
sudo systemctl start docker libvirtd
sudo systemctl enable docker libvirtd
```

Add your user to the required groups:

```bash
sudo usermod -aG docker,libvirt $USER
```

**Note**: Group membership requires logout/login or reboot to take effect.

### SSH Key Setup (Required for VM Access)

The build script uses Ignition to provision SSH keys into the VM. Generate an SSH keypair if you don't have one:

```bash
[ ! -f ~/.ssh/id_ed25519 ] && ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
```

The script will automatically use keys from `~/.ssh/id_*.pub` when starting the VM.

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
./acl/build_rpm_image.sh --build-sdk-container
```

**When to rebuild SDK:**

- First time setup
- After updating SDK dependencies
- When RPM/dnf tools need updates
- If SDK container is corrupted
- To be confirmed: Also needed after changing a commit.

### Phase 2: Download Azure Linux RPM Packages

Download required RPM packages from Azure Linux repositories:

```bash
# Download all required RPMs (recommended - handles repo creation)
./acl/build_rpm_image.sh --download-rpms

# Force re-download (clean staging first)
./acl/build_rpm_image.sh --clean --download-rpms
```

**Download behavior:**

- Checks for existing RPMs in staging directory
- Only downloads missing packages (incremental)
- Resolves and downloads all dependencies automatically
- Creates local repository metadata with `createrepo_c`

Note that only a subset of packages is downloaded, as majority of packages is
downloaded during the image build using `dnf`.

**Staging directory:** `__build__/rpm-staging/`

### Phase 2.5: Build Custom RPM Packages

**Important**: This step is required because `ignition` is not available in Azure Linux repositories.

Build custom RPM packages using the Azure Linux toolkit:

```bash
# Build custom RPMs and add them to staging
./acl/build_rpm_image.sh --build-rpms
```

This step:

- Clones Azure Linux 3.0 toolkit if not present
- Builds packages defined in `acl/SPECS/`
- Copies built RPMs to the staging directory
- Updates repository metadata automatically

**Build output:** Custom RPMs are added to `__build__/rpm-staging/`

### Phase 2.6: Download Unofficial Kernel

For testing with unofficial/unsigned kernel builds from Azure DevOps CI:

```bash
# Download kernel RPMs from default build ID
./acl/build_rpm_image.sh --download-unofficial-kernel

# Download from a specific build ID
./acl/build_rpm_image.sh --download-unofficial-kernel --unofficial-kernel-build-id=1028516
```

**Prerequisites for unofficial kernel download:**

1. **Azure CLI**: Install the Azure CLI:

   ```bash
   # Ubuntu/Debian
   curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

   # Azure Linux
   sudo tdnf install -y azure-cli
   ```

2. **Azure DevOps Extension**: The script will auto-install if missing, or install manually:

   ```bash
   az extension add --name azure-devops
   ```

3. **Azure Login**: Authenticate with Azure:

   ```bash
   az login
   ```

**Note**: The unofficial kernel is unsigned and requires `--no-secure-boot` when starting the VM (see Phase 5).

### Phase 3: Build the Image

Build the Flatcar production image using hybrid package sources.

```bash
# Download RPMs and build image in one command
./acl/build_rpm_image.sh --rebuild
```

**Build output location:** `__build__/images/images/amd64-usr/latest/`

### Phase 4: Build VM Image (Optional)

Convert the production image to a VM-ready format.

```bash
# Build VM image after main build
./acl/build_rpm_image.sh --build-vm-image
```

**VM image output:** `__build__/images/images/amd64-usr/latest/acl_production_qemu_uefi_image.img`

### Phase 5: Start VM and Run Tests

#### Using build_rpm_image.sh (Integrated Testing)

The script automatically configures libvirt (default network, URI) on Azure Linux 3. On Ubuntu, libvirt's networking works out-of-the-box.

```bash
# Just start the VM and observe the boot sequence, get access to interactive console.
./acl/build_rpm_image.sh --start-vm

# Start VM without secure boot (required for unsigned/unofficial kernels)
./acl/build_rpm_image.sh --start-vm --no-secure-boot

# Start VM and run inline command via SSH
./acl/build_rpm_image.sh --start-vm \
  --run-script="cat /etc/os-release"

# Run test script on VM (this script is included and used for a basic smoke test for now)
./acl/build_rpm_image.sh --start-vm \
  --run-script=./acl/tests/run-container-test.sh

# Run multiple test scripts
./acl/build_rpm_image.sh --start-vm \
  --run-script=./acl/tests/run-secureboot-test.sh \
  --run-script=./acl/tests/run-container-test.sh
```

**SSH Access (Default):**

- The script generates an Ignition ISO with your SSH public keys from `~/.ssh/id_*.pub`
- SSH user: `core` (default) - customize with `--ssh-user=USER`
- Ignition runs on first boot only

**Serial Console Access (Alternative):**

- Use `--use-serial` flag for console-based script execution
- Uses `expect` to automate console login
- Customize: `--console-user=core --console-password=mypass`

**Parity Data Collection:**

```bash
# Collect OS data from VM for parity  analysis against upstream flatcar
./acl/build_rpm_image.sh --start-vm --parity

# Or specify custom os-diff directory
./acl/build_rpm_image.sh --start-vm --parity=/path/to/os-diff
```

- Requires the [os-diff](https://dev.azure.com/mariner-org/ACL/_git/os-diff) repo cloned as sibling directory (default: `../os-diff`)
- Runs `os-data-collector` to gather system data and `os-comparison-reporter` for analysis
- Output:
  - Data: `__build__/data-collection/{TIMESTAMP}-comparison-data.json`
  - Report: `__build__/data-collection/{TIMESTAMP}-report.md`
- For collecting data from external hosts (e.g., Azure nodes), use `acl/collect_vm_data.sh` directly

  **Collecting upstream Flatcar baseline data from Azure:**

  ```bash
  # 1. Create Azure VM with Flatcar Container Linux image
  # 2. SSH in and update to target version:
  sudo flatcar-update --to-version 4459.2.2 --disable-afterwards
  # 3. Reboot and collect data:
  ./acl/collect_vm_data.sh --host=<VM_IP> --collector=/path/to/os-diff/os-data-collector --output=upstream-fc-comparison-data.json
  ```

  **Adding compressed image size to baseline data:**

  ```bash
  # Download, recompress with bzip2 -9, and get size
  VERSION=4459.2.2
  curl -O https://stable.release.flatcar-linux.net/amd64-usr/${VERSION}/flatcar_production_azure_image.vhd.bz2
  bunzip2 flatcar_production_azure_image.vhd.bz2
  bzip2 -9 flatcar_production_azure_image.vhd
  COMPRESSED_SIZE=$(stat -c%s flatcar_production_azure_image.vhd.bz2)
  # Add to JSON (requires jq)
  jq --argjson size "$COMPRESSED_SIZE" '.os_info.compressed_image_size = $size' \
    upstream-fc-comparison-data.json > tmp.json && mv tmp.json upstream-fc-comparison-data.json
  ```

- For kernel config comparison, use `acl/kconfig_diff.sh` with two comparison-data.json files (requires diffconfig from kernel-headers)

#### Cleanup

Subsequent runs will clean up the VM automatically. To manually clean up the VM:

```bash
# Stop VM
virsh destroy acl

# Remove VM
virsh undefine --nvram acl
```

### Phase 6: Run Flatcar E2E Tests (Optional)
Run the full Flatcar E2E test suite against the built VM image:

```bash
# Run Flatcar E2E tests
./acl/build_rpm_image.sh --run-kola-tests
```

The prerequisites for running Kola tests is to build customized `mantle` container. You need to checkout the `mantle` repository next to the `acl-scripts` repository:

```bash
git clone https://mariner-org@dev.azure.com/mariner-org/ACL/_git/mantle
```

Then build the `mantle` container with ACL support:

```bash
docker build -t mantle .
```

## Common Workflows

### Development Iteration

Efficient workflow for iterative development:

```bash
# Quick rebuild after packaging/script changes
./acl/build_rpm_image.sh --rebuild

# Build custom RPMs and rebuild image
./acl/build_rpm_image.sh --build-rpms --rebuild

# Rebuild and retest
./acl/build_rpm_image.sh --rebuild --build-vm-image --start-vm \
  --run-script=./acl/tests/run-container-test.sh

# Or use the short cut of the command above (runs additional tests as well):
./acl/build_rpm_image.sh --rebuild-and-test
```

## Troubleshooting

### Common Issues

- **Issue**: VM fails to boot with unofficial/unsigned kernel
  **Cause**: Secure boot rejects unsigned kernels.
  **Solution**: Use `--no-secure-boot` flag:

  ```bash
  ./acl/build_rpm_image.sh --start-vm --no-secure-boot
  ```

- **Issue**: Red block preceded by: `sudo: rpm: command not found`
  **Solution**: Ensure SDK container is rebuilt with RPM tools:

  ```bash
  ./acl/build_rpm_image.sh --build-sdk-container
  ```

- **Issue**: VM startup fails with `tpm-emulator: could not send INIT` (Azure Linux 3)
  **Cause**: swtpm on some Azure Linux 3 builds crashes due to SECCOMP blocking the `clone3` syscall.
  **Solution**: Create a wrapper script that disables SECCOMP:

  ```bash
  # Create wrapper script
  cat << 'EOF' | sudo tee /usr/local/bin/swtpm-wrapper
  #!/bin/bash
  exec /usr/bin/swtpm.orig "$@" --seccomp action=none
  EOF
  sudo chmod +x /usr/local/bin/swtpm-wrapper

  # Replace swtpm with wrapper
  sudo mv /usr/bin/swtpm /usr/bin/swtpm.orig
  sudo ln -s /usr/local/bin/swtpm-wrapper /usr/bin/swtpm
  ```
