# RPM-Based Image Build System for Azure Container Linux derivative of Flatcar Linux

This document describes the RPM-based image build system for Flatcar, which
enables building Azure Container Linux images using packages from Azure Linux
3.0 repositories.

Currently targetting `stable-4459.2.2` of Flatcar Linux upstream. Upstream build is available here: [images](https://bincache.flatcar-linux.net/images/amd64/4459.2.2/), [test results](https://bincache.flatcar-linux.net/testing/4459.2.2/amd64/qemu/).

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
- **Azure CLI**: Only for Azure VM testing

Install on Debian/Ubuntu:

```bash
sudo apt-get install docker-ce qemu-kvm libvirt-daemon-system libvirt-clients \
  bridge-utils expect curl createrepo-c golang-1.23 rpm genisoimage ovmf

# For Azure VM testing, also install Azure CLI:
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
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

### Azure Authentication (Required for Azure VM Testing)

For testing on an Azure VM, you must be authenticated to Azure CLI:

```bash
# Login to Azure (interactive)
az login

# Or login with service principal
az login --service-principal -u <app-id> -p <password> --tenant <tenant>
```

### System Requirements

- **Disk Space**: 50GB+ for SDK container, RPMs, and build artifacts
- **RAM**: 8GB+ recommended
- **Network**: Access to Azure Linux package repositories

### SDK Container

The build system requires the Flatcar SDK container, which includes all build tools.

## Quick Start: Hydrate from CI

The fastest way to set up a local build environment is to pull pre-built
containers and RPMs from the CI pipeline. This avoids rebuilding the SDK
container, downloading RPMs, and building custom RPMs locally.

### Prerequisites

- **Azure CLI** with the **azure-devops** extension
- **Docker** (for pulling containers)
- Reader access to the ACL Azure DevOps organization
- Reader access to the acl resource group in EdgeOS_Mariner_Platform_AKS_test. Refer to internal documentation for accessing the Azure Portal and locating the resource group.

```bash
# Install or upgrade azure-devops extension
az extension add --name azure-devops --upgrade

# Login to Azure and the acldevel container registry
az login
az acr login --name acldevel
```

### Hydrate from Latest CI Build

```bash
./acl/build_rpm_image.sh --hydrate
```

This will:

1. Query the latest successful aclmain pipeline main branch build
2. Pull the build's SDK and mantle containers from ACR
3. Download and extract the RPM staging tarball from the build
4. Update `sdk_container/.repo/manifests/mantle-container`
5. Print an `export ACL_SDK_IMAGE=...` statement to configure your environment

### Hydrate from a Specific Build

To hydrate from a specific build in the aclmain or acldevel pipelines you can use `--hydrate-build-id=<BUILD_ID>`

```bash
./acl/build_rpm_image.sh --hydrate-build-id=1053102
```

### After Hydrating

Set the SDK image and build:

```bash
# Copy the export statement printed by --hydrate
export ACL_SDK_IMAGE="acldevel.azurecr.io/flatcar-sdk-all:4459.0.0-rpm.1053102"

# Build an image using the SDK and RPMs from the pipeline
./acl/build_rpm_image.sh --rebuild
```

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
- When RPM/dnf5 tools need updates
- If SDK container is corrupted
- To be confirmed: Also needed after changing a commit.

### Phase 2: Build Custom RPM Packages

**Important**: This step is required because `ignition` is not available in Azure Linux repositories.

Build custom RPM packages using the Azure Linux toolkit:

```bash
# Build custom RPMs and add them to staging
./acl/build_rpm_image.sh --build-rpms

# Clean staging and build RPM directories before rebuilding custom RPMs
./acl/build_rpm_image.sh --clean --build-rpms
```

This step:

- Clones Azure Linux 3.0 toolkit if not present
- Builds packages defined in `acl/SPECS/`
- Copies built RPMs to the staging directory
- Updates repository metadata automatically

**Build output:** Custom RPMs are added to `__build__/rpm-staging/`

### Phase 3: Build the Image

Build the Flatcar production image using hybrid package sources.

```bash
# Build image
./acl/build_rpm_image.sh --rebuild
```

**Build output location:** `__build__/images/images/amd64-usr/latest/`

### Phase 4: Build VM Image (Optional)

Convert the production image to a VM-ready format. The script supports building two different types of images:

- QEMU image (default)
- Azure VHD

```bash
# Build a QEMU VM image after main image build
./acl/build_rpm_image.sh --build-vm-image --vm-type=qemu

# To support backward compatibility, when --vm-type is NOT specified, the tool will build a QEMU image, by default
./acl/build_rpm_image.sh --build-vm-image

# Build an Azure VHD image
./acl/build_rpm_image.sh --build-vm-image --vm-type=azure
```


#### Build Test VM Image (Optional)

The `--build-test-image` flag builds a test VM image that includes the docker sysext, which is required for running kola tests.

```bash
# Build a QEMU test VM image
./acl/build_rpm_image.sh --build-test-image --vm-type=qemu

# Build an Azure VHD test VM image
./acl/build_rpm_image.sh --build-test-image --vm-type=azure

# When --vm-type is not specified, QEMU is used by default
./acl/build_rpm_image.sh --build-test-image
```

#### VM Image Output

- QEMU:

```bash
__build__/images/images/amd64-usr/latest/acl_production_qemu_uefi_image.img
```

- Azure:

```bash
__build__/images/images/amd64-usr/latest/acl_production_azure_image.vhd
```

- QEMU Test Image:

```bash
__build__/images/images/amd64-usr/latest/acl_production_qemu_uefi_test_image.img
```

- Azure Test Image:

```bash
__build__/images/images/amd64-usr/latest/acl_production_azure_test_image.vhd
```

### Phase 5: Start VM and Run Tests

The `acl/build_rpm_image.sh` script can be used to start an ACL VM and run integrated tests on it. The script supports starting a VM of two different types:

- QEMU image (default)
- Azure VHD

1. **Start a QEMU VM**

The script automatically configures libvirt (default network, URI) on Azure Linux 3. On Ubuntu, libvirt's networking works out-of-the-box.

```bash
# Just start the VM and observe the boot sequence, get access to interactive console.
./acl/build_rpm_image.sh --start-vm

# Start VM without secure boot (e.g. for UKI bootloader mode)
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
  --run-script=./acl/tests/run-container-test.sh \
  --run-script=./acl/tests/run-systemd-health-test.sh \
  --run-script=./acl/tests/run-dmesg-io-error-test.sh
```

Subsequent runs will clean up the VM automatically. To manually clean up the VM:

```bash
# Stop VM
virsh destroy acl

# Remove VM
virsh undefine --nvram acl
```

1. **Start an Azure VM**

For Azure VM testing, ensure that you have Azure CLI downloaded and are authenticated into Azure. The script automatically validates and if necessary, creates the required Azure infrastructure. Resources are created inside default Azure subscription and region. To override, use `--az-sub-id` and `--az-region` as outlined below.

By default, before starting a new Azure VM, all the pre-existing resource groups and VMs created by the current user earlier are scheduled for deletion. If you want to keep your older VMs, override this behavior with `--no-cleanup`.

```bash
# Basic Azure VM testing
./acl/build_rpm_image.sh --start-vm --vm-type=azure

# Override Azure subscription, region, and storage account for uploading the Azure VHD
./acl/build_rpm_image.sh --start-vm --vm-type=azure \
  --az-sub-id=<custom-subscription-id> \
  --az-region=<custom-region> \
  --az-storage-account=<custom-storage-account-name>

# Start a new Azure VM while preserving pre-existing VMs
./acl/build_rpm_image.sh --start-vm --vm-type=azure --no-cleanup
```

#### Access the VM

1. **SSH Access (Default):**

- The script generates an Ignition ISO with your SSH public keys from `~/.ssh/id_*.pub`
- SSH user: `core` (default) - customize with `--ssh-user=USER`
- Ignition runs on first boot only

1. **Serial Console Access (Alternative):**

- Use `--use-serial` flag for console-based script execution
- Uses `expect` to automate console login
- Customize: `--console-user=core --console-password=mypass`

#### Collect Parity Data

```bash
# Collect OS data from VM for parity analysis against upstream flatcar
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

### Phase 6: Run Flatcar E2E Tests (Optional)

Run the full Flatcar E2E test suite against the built QEMU VM image:

```bash
# Run Flatcar E2E tests
./acl/build_rpm_image.sh --run-kola-tests
```

At the moment, the full run takes about 4 hours. To add retries for flaky tests, set `MAX_RUNS` to number higher than 1.

To produce results MD summary with grouping of failures, you can use `./acl/parse_tap_results.py`:

```bash
./acl/parse_tap_results.py __TESTS__/qemu-uefi/results-run-*.tap
```

Additional results are also produced at the root of the repo: `results-qemu_uefi*`.

To run a specific test (e.g. `cl.sysext.fallbackdownload`), you can use `run_local_tests.sh` directly:

```bash
PACKAGE_SOURCE_MOD=RPM ./run_local_tests.sh amd64 2 cl.sysext.fallbackdownload
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

- **Issue**: VM fails to boot with UKI bootloader mode
  **Cause**: UKI images are not yet signed; secure boot rejects them.
  **Solution**: Use `--no-secure-boot` flag (this is done automatically when `BOOTLOADER_MODE=uki`):

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
