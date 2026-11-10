#!/bin/bash

# Test the SMBIOS profile selector's image-build wiring with temporary fixtures.
# Check package selection, automatic selector wiring, EFI layout and signing inputs.
# SDK, privileged operations and signing are mocked; no image is built or booted.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ARM64 UKI uses HWE; AMD64 and GRUB keep their defaults.
while read -r board bootloader expected expected_bpftool; do
    result="$(BOARD="${board}" BOOTLOADER_MODE="${bootloader}" \
        bash -c 'source "$1"; get_rpm_package_name sys-kernel/coreos-kernel; get_rpm_package_name sys-kernel/coreos-modules; get_rpm_package_name dev-util/bpftool' \
        _ "${REPO}/build_library/rpm/package_catalog.sh")"
    [[ "${result}" == "$(printf '%s\n%s\n%s' "${expected}" "${expected}" "${expected_bpftool}")" ]] || {
        echo "Unexpected packages for ${board}/${bootloader}: ${result}" >&2
        exit 1
    }
done <<'CASES'
arm64-usr uki kernel-hwe bpftool-hwe
arm64-usr grub kernel bpftool
amd64-usr uki kernel bpftool
amd64-usr grub kernel bpftool
CASES

# Run the real sysext helper through catalog initialization, without SDK or disk operations.
mkdir -p "${WORK}/builder/build_library"
cp "${REPO}/build_library/sysext_prod_builder" "${WORK}/builder/build_library/"
cat > "${WORK}/builder/common.sh" <<'SH'
BUILD_LIBRARY_DIR="$(dirname "${BASH_SOURCE[0]}")/build_library"
assert_inside_chroot() { :; }
switch_to_strict_mode() { set -e; }
SH
cat > "${WORK}/builder/build_library/build_image_util.sh" <<'SH'
source "${TEST_REPO}/build_library/rpm/package_catalog.sh"
get_rpm_package_name sys-kernel/coreos-kernel
exit
SH
result="$(env -i PATH="${PATH}" TEST_REPO="${REPO}" \
    BOOTLOADER_MODE=uki \
    bash "${WORK}/builder/build_library/sysext_prod_builder" arm64-usr)"
[[ "${result}" == kernel-hwe ]] || { echo "Sysext helper lost the ARM64 board" >&2; exit 1; }

cp "${REPO}/image_to_vm.sh" "${WORK}/builder/"
cat >> "${WORK}/builder/common.sh" <<'SH'
assert_not_root_user() { :; }
DEFAULT_BOARD=amd64-usr DEFAULT_MEM=0 FLAGS_FALSE=1 FLAGS_TRUE=0
DEFINE_string() { printf -v "FLAGS_$1" '%s' "$2"; }
DEFINE_integer() { DEFINE_string "$@"; }
DEFINE_boolean() { DEFINE_string "$@"; }
FLAGS() {
    FLAGS_ARGV=""
    for arg; do
        case "$arg" in
            --board=*) FLAGS_board="${arg#*=}" ;;
            --format=*) FLAGS_format="${arg#*=}" ;;
        esac
    done
}
SH
mkdir -p "${WORK}/builder/build_library/rpm"
touch "${WORK}/builder/build_library/"{toolchain_util.sh,cros_vm_constants.sh,release_util.sh,rpm/ipe_artifact.sh}
printf 'set_vm_type() { :; }\n' > "${WORK}/builder/build_library/vm_image_util.sh"
printf 'BOARD="${FLAGS_board}"\n' > "${WORK}/builder/build_library/board_options.sh"
result="$(env -i PATH="${PATH}" TEST_REPO="${REPO}" \
    BOOTLOADER_MODE=uki \
    bash "${WORK}/builder/image_to_vm.sh" --board=arm64-usr --format=azure)"
[[ "${result}" == kernel-hwe ]] || { echo "VM conversion lost the ARM64 board" >&2; exit 1; }

# The open-driver sysext uses HWE on ARM64 and keeps cuda-open on AMD64.
source "${REPO}/build_library/standalone_sysext_util.sh"
for board in amd64-usr arm64-usr; do
    expected_driver_package=cuda-open
    if [[ "${board}" == arm64-usr ]]; then
        expected_driver_package=cuda-open-hwe
    fi
    actual_sysexts="$(parse_standalone_sysexts_yaml "${REPO}/acl/sysexts.yaml" "${board}" gpu)"
    [[ " ${actual_sysexts} " == *" nvidia-driver-cuda-open|${expected_driver_package} "* ]] || {
        echo "Unexpected NVIDIA open-driver package for ${board}: ${actual_sysexts}" >&2
        exit 1
    }
done

# Exercise the real build and install conditions without SDK or firmware tools.
sed -n '/^    if \[\[ "${BOARD}" == "arm64-usr".*/,/^    fi/p' \
    "${REPO}/acl/build_rpm_image.sh" > "${WORK}/selector-build.sh"
sed -n '/^    if \[\[ "${EFI_ARCH}" == "aa64" \]\]; then/,/^    fi/p' \
    "${REPO}/build_library/rpm/uki_install.sh" > "${WORK}/selector-install.sh"
[[ -s "${WORK}/selector-build.sh" && -s "${WORK}/selector-install.sh" ]]
for board in arm64-usr amd64-usr; do
    for bootloader in uki grub; do
        result="$(
            BOARD="${board}" BOOTLOADER_MODE="${bootloader}"
            SCRIPT_DIR="${REPO}" EFITREELOADER_DIR="${WORK}/loader"
            bash() { printf '%s\n' "$@"; }
            source "${WORK}/selector-build.sh"
        )"
        if [[ "${board}" == arm64-usr && "${bootloader}" == uki ]]; then
            [[ "${result}" == "$(printf '%s\n%s' "${REPO}/acl/smbios-profile-selector/build-smbios-selector-and-loader.sh" "${WORK}/loader")" ]]
        else
            [[ -z "${result}" ]]
        fi
    done
done
for arch in aa64 x64; do
    result="$(
        EFI_ARCH="${arch}" ESP_DIR=esp efi_stub=stub sd_boot_efi=systemd-boot
        _uki_install_smbios_selector() { printf '%s\n' "$@"; }
        source "${WORK}/selector-install.sh"
    )"
    if [[ "${arch}" == aa64 ]]; then
        [[ "${result}" == "$(printf '%s\n%s\n%s' esp stub systemd-boot)" ]]
    else
        [[ -z "${result}" ]]
    fi
done

# Exercise the installer itself without entering the SDK or requiring root.
source <(sed -n '/^_uki_install_smbios_selector() {/,/^}/p' "${REPO}/build_library/rpm/uki_install.sh")
sudo() { "$@"; }
info() { :; }
die() { echo "$*" >&2; exit 1; }
ukify() {
    printf '%s\n' "$@" > "${WORK}/ukify-arguments"
    for arg in "$@"; do
        case "${arg}" in --output=*) printf 'addon' > "${arg#*=}" ;; esac
    done
}

SCRIPT_ROOT="${WORK}/source"
EFI_ARCH=aa64
project="${SCRIPT_ROOT}/acl/smbios-profile-selector"
esp="${WORK}/esp"
mkdir -p "${project}/target/boot" "${project}/boot" "${esp}/EFI/BOOT"
printf 'selector' > "${project}/target/boot/smbios-profile-selector.efi"
printf 'tree loader' > "${project}/target/boot/efitreeloader.efi"
printf 'parameters' > "${project}/boot/nvidia-grace-kernel-parameters.txt"
printf 'systemd-boot' > "${WORK}/systemd-boot.efi"
printf 'original shim' > "${esp}/EFI/BOOT/BOOTAA64.EFI"
printf 'stub' > "${WORK}/stub.efi"
_uki_install_smbios_selector "${esp}" "${WORK}/stub.efi" "${WORK}/systemd-boot.efi"
cmp "${WORK}/systemd-boot.efi" "${esp}/EFI/BOOT/3rdaa64.efi"
cmp "${project}/target/boot/efitreeloader.efi" "${esp}/EFI/BOOT/grubaa64.efi"
cmp "${project}/target/boot/smbios-profile-selector.efi" "${esp}/EFI/BOOT/smbios-profile-selector.efi"
[[ -s "${esp}/EFI/BOOT/profiles/nvidia-grace.addon.efi" ]]
[[ ! -e "${esp}/loader/addons/acl-nvidia-grace.addon.efi" ]]
[[ "$(cat "${esp}/EFI/BOOT/BOOTAA64.EFI")" == "original shim" ]]
if grep -Eq '^--(linux|uname)' "${WORK}/ukify-arguments"; then
    echo "Grace addon must not contain a kernel image or kernel-version restriction" >&2
    exit 1
fi

mkdir -p "${WORK}/bin" "${WORK}/cert" "${WORK}/cert-output" "${esp}/EFI/Linux" "${esp}/acl/uki-addons"
printf 'UKI' > "${esp}/EFI/Linux/vmlinuz-test.efi"
printf 'unrelated EFI' > "${esp}/EFI/BOOT/3rd-unrelated.efi"
printf 'certificate' > "${WORK}/cert/uki-signing-ca.pem"
printf 'private key' > "${WORK}/cert/ca.key"
cat > "${WORK}/bin/sbsign" <<'SH'
#!/bin/bash
set -euo pipefail
while [[ $# -gt 0 ]]; do
    case "$1" in
        --key|--cert) shift 2 ;;
        --output) output="$2"; shift 2 ;;
        *) input="$1"; shift ;;
    esac
done
printf '%s\n' "$(basename "${input}")" >> "${SIGNED_FILES}"
cp "${input}" "${output}"
SH
chmod +x "${WORK}/bin/sbsign"
export -f sudo
PATH="${WORK}/bin:${PATH}" SIGNED_FILES="${WORK}/signed-files" \
    bash "${REPO}/build_library/rpm/sign_uki_ephemeral.sh" "${esp}" "${WORK}/cert-output" "${WORK}/cert"
printf '%s\n' 3rdaa64.efi grubaa64.efi nvidia-grace.addon.efi smbios-profile-selector.efi vmlinuz-test.efi \
    | sort > "${WORK}/expected-files"
sort "${WORK}/signed-files" > "${WORK}/actual-files"
cmp "${WORK}/expected-files" "${WORK}/actual-files"
[[ "$(cat "${esp}/EFI/BOOT/BOOTAA64.EFI")" == "original shim" ]]
echo "SMBIOS profile selector image-wiring checks passed"
