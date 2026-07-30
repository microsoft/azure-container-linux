#!/bin/bash
# Install RPM tools into running Flatcar SDK container

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Installing RPM into Flatcar SDK ==="
echo

echo "Installing RPM package in SDK (this may take several minutes)..."
echo

"${SCRIPT_DIR}/run_sdk_container" -- bash <<'INSTALL_SCRIPT'
set -e

echo "→ Checking current RPM status..."
if rpm --version &>/dev/null 2>&1 && rpm --showrc 2>/dev/null | grep -q "PayloadIsXz"; then
    echo "✓ RPM is already installed"
    rpm --version | head -1
    exit 0
fi
echo "✗ RPM not available, installing..."
echo

echo "→ Creating local portage overlay..."
sudo mkdir -p /usr/local/portage/app-arch/rpm

echo "→ Copying ebuild files..."
if [[ -f /mnt/host/source/src/third_party/portage-stable/app-arch/rpm-4.20.1-r2.ebuild ]]; then
    sudo cp /mnt/host/source/src/third_party/portage-stable/app-arch/rpm*.ebuild /usr/local/portage/app-arch/rpm/
    echo "  ✓ Copied ebuild files"
else
    echo "  ✗ ERROR: RPM ebuild not found"
    echo "  Expected: /mnt/host/source/src/third_party/portage-stable/app-arch/rpm-*.ebuild"
    exit 1
fi

echo "→ Configuring local overlay..."
if ! sudo grep -q "location = /usr/local/portage" /etc/portage/repos.conf/*.conf 2>/dev/null; then
    sudo mkdir -p /etc/portage/repos.conf
    echo '[local]' | sudo tee /etc/portage/repos.conf/local.conf > /dev/null
    echo 'location = /usr/local/portage' | sudo tee -a /etc/portage/repos.conf/local.conf > /dev/null
    echo 'priority = 100' | sudo tee -a /etc/portage/repos.conf/local.conf > /dev/null
    echo 'auto-sync = no' | sudo tee -a /etc/portage/repos.conf/local.conf > /dev/null
    echo "  ✓ Configured local overlay"
else
    echo "  ✓ Local overlay already configured"
fi

echo "→ Generating manifest..."
cd /usr/local/portage/app-arch/rpm
EBUILD=$(ls -1 rpm-*.ebuild | sort -V | tail -1)
echo "  Using: $EBUILD"
sudo ebuild "$EBUILD" manifest
echo "  ✓ Manifest generated"
echo

echo "→ Configuring RPM USE flags..."
# Enable caps (file capabilities) - required for Azure Linux packages.
# lzma/bzip2 add the matching rpmlib(PayloadIs*) capabilities; Azure
# Linux 4 ships xz-compressed kernel packages that need lzma.
sudo mkdir -p /etc/portage/package.use
echo "app-arch/rpm caps acl sqlite zstd lzma bzip2" | sudo tee /etc/portage/package.use/rpm
echo "  ✓ Enabled: caps acl sqlite zstd lzma bzip2"
echo

echo "→ Installing RPM and dependencies..."
export FEATURES="-ipc-sandbox -network-sandbox -pid-sandbox -sandbox"
sudo FEATURES="$FEATURES" emerge --ask=n --newuse app-arch/rpm
echo

echo "→ Verifying installation..."
if rpm --version &>/dev/null 2>&1; then
    echo "✓ RPM successfully installed!"
    rpm --version
else
    echo "✗ Installation verification failed"
    exit 1
fi
INSTALL_SCRIPT

echo
echo "=== Installation Complete ==="
echo
echo "✓ RPM tools are now available in your SDK"
echo "✓ Hybrid builds will automatically use native RPM"
echo
echo "Next: Run a hybrid build with:"
echo "  export PACKAGE_SOURCE_MODE=HYBRID"
echo "  ./run_sdk_container -- ./build_image --board=amd64-usr"
