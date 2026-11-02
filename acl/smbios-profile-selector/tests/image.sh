#!/bin/bash

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

for enabled in false true; do
    expected=kernel
    expected_bpftool=bpftool
    if [[ "${enabled}" == true ]]; then
        expected=kernel-hwe
        expected_bpftool=bpftool-hwe
    fi
    result="$(BOARD=arm64-usr BOOTLOADER_MODE=uki ACL_SMBIOS_PROFILE_SELECTOR="${enabled}" \
        bash -c 'source "$1"; get_rpm_package_name sys-kernel/coreos-kernel; get_rpm_package_name sys-kernel/coreos-modules; get_rpm_package_name dev-util/bpftool' \
        _ "${REPO}/build_library/rpm/package_catalog.sh")"
    [[ "${result}" == "$(printf '%s\n%s\n%s' "${expected}" "${expected}" "${expected_bpftool}")" ]]
done
if BOARD=amd64-usr BOOTLOADER_MODE=uki ACL_SMBIOS_PROFILE_SELECTOR=true \
    bash -c 'source "$1"' _ "${REPO}/build_library/rpm/package_catalog.sh" >"${WORK}/invalid-arch.log" 2>&1; then
    echo "Selector mode unexpectedly accepted an AMD64 image" >&2
    exit 1
fi

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
    BOOTLOADER_MODE=uki ACL_SMBIOS_PROFILE_SELECTOR=true \
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
    BOOTLOADER_MODE=uki ACL_SMBIOS_PROFILE_SELECTOR=true \
    bash "${WORK}/builder/image_to_vm.sh" --board=arm64-usr --format=azure)"
[[ "${result}" == kernel-hwe ]] || { echo "VM conversion lost the ARM64 board" >&2; exit 1; }

source "${REPO}/build_library/standalone_sysext_util.sh"
for board in amd64-usr arm64-usr; do
    if [[ "${board}" == arm64-usr ]]; then
        expected_sysexts=("nvidia-driver-cuda-open|cuda-open-hwe")
    else
        expected_sysexts=("nvidia-driver-cuda-open|cuda-open" "nvidia-driver-cuda|cuda" "nvidia-driver-vgpu|nvidia-vgpu-guest-driver")
    fi
    expected_sysexts+=("nvidia-container-toolkit|nvidia-container-toolkit" "nvidia-fabric-manager|nvidia-fabric-manager")
    actual_sysexts="$(parse_standalone_sysexts_yaml "${REPO}/acl/sysexts.yaml" "${board}" gpu)"
    [[ "${actual_sysexts% }" == "${expected_sysexts[*]}" ]] || {
        echo "Unexpected GPU sysext packages for ${board}: ${actual_sysexts}" >&2
        exit 1
    }
done

# Exercise the SDK exports in a fresh environment, as the sdk login shell does.
awk '
    /^case.*ACL_SMBIOS_PROFILE_SELECTOR/ { copying=1 }
    /^if \[ \$# -gt 0 \]/ { exit }
    copying { print }
' "${REPO}/sdk_lib/sdk_entry.sh" |
    sed "s#/home/sdk/.bashrc#${WORK}/sdk.bashrc#g" > "${WORK}/sdk-exports.sh"
touch "${WORK}/sdk.bashrc"
for enabled in true false ''; do
    env -i PATH="${PATH}" ACL_SMBIOS_PROFILE_SELECTOR="${enabled}" bash "${WORK}/sdk-exports.sh"
    result="$(env -i PATH="${PATH}" bash -c 'source "$1"; printf "%s" "${ACL_SMBIOS_PROFILE_SELECTOR:-unset}"' _ "${WORK}/sdk.bashrc")"
    [[ "${result}" == "${enabled:-false}" ]] || {
        echo "SDK login lost selector setting '${enabled:-false}' (got '${result}')" >&2
        exit 1
    }
    [[ "$(grep -c '^export ACL_SMBIOS_PROFILE_SELECTOR=' "${WORK}/sdk.bashrc")" == 1 ]]
done
if env -i PATH="${PATH}" ACL_SMBIOS_PROFILE_SELECTOR=invalid \
    bash "${WORK}/sdk-exports.sh" >"${WORK}/invalid-sdk-setting.log" 2>&1; then
    echo "SDK login accepted an invalid selector setting" >&2
    exit 1
fi
grep -qF 'ACL_SMBIOS_PROFILE_SELECTOR must be true or false' "${WORK}/invalid-sdk-setting.log"

# Exercise the installer itself without entering the SDK or requiring root.
source <(sed -n '/^_uki_install_smbios_selector() {/,/^}/p' "${REPO}/build_library/rpm/uki_install.sh")
declare -F _uki_install_smbios_selector >/dev/null
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
_uki_install_smbios_selector "${esp}" "${WORK}/stub.efi" "${WORK}/systemd-boot.efi"
cmp "${WORK}/systemd-boot.efi" "${esp}/EFI/BOOT/3rdaa64.efi"
cmp "${project}/target/boot/efitreeloader.efi" "${esp}/EFI/BOOT/grubaa64.efi"
cmp "${project}/target/boot/smbios-profile-selector.efi" "${esp}/EFI/BOOT/smbios-profile-selector.efi"
[[ -s "${esp}/EFI/BOOT/profiles/nvidia-grace.addon.efi" ]]
[[ ! -e "${esp}/loader/addons/acl-nvidia-grace.addon.efi" ]]
[[ "$(cat "${esp}/EFI/BOOT/BOOTAA64.EFI")" == "original shim" ]]
! grep -Eq '^--(linux|uname)' "${WORK}/ukify-arguments"

mkdir -p "${WORK}/bin" "${WORK}/cert" "${WORK}/cert-output" "${esp}/EFI/Linux" "${esp}/acl/uki-addons"
printf 'UKI' > "${esp}/EFI/Linux/vmlinuz-test.efi"
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
echo "SMBIOS image build/install/signing checks passed"
