source "${BUILD_LIBRARY_DIR}/rpm/package_catalog.sh" || exit 1
source "${BUILD_LIBRARY_DIR}/rpm/package_source_config.sh" || exit 1
source "${BUILD_LIBRARY_DIR}/rpm/rpm_install.sh" || exit 1

run_localedef() {
  local root_fs_dir="$1" loader=()

  # For RPM mode, Azure Linux glibc already includes pre-compiled C.utf8 locale
  # at /usr/lib/locale/C.utf8, so we can skip running localedef
  info "Confirming presence of C.UTF-8 locale..."
  if [[ -d "${root_fs_dir}/usr/lib/locale/C.utf8" ]]; then
    info "C.utf8 locale already present from glibc RPM, skipping localedef"
    return 0
  fi

  error "C.utf8 locale not found in RPM mode, investigate."
  exit 1
}

# List packages installed from RPM database
# Returns non-zero if no packages found (to fail fast during build)
image_packages_portage() {
    local root_fs_dir="$1"
    
    local dbpath="${root_fs_dir}/var/lib/rpm"
    local pkg_count=0
    
    if [[ -d "${dbpath}" ]]; then
        pkg_count=$(rpm_query_packages "${root_fs_dir}" | wc -l)
        info "RPM database at ${dbpath}: ${pkg_count} packages"
        rpm_query_packages "${root_fs_dir}"
    elif [[ -n "${BUILD_DIR:-}" && -f "${BUILD_DIR}/.rpm_packages_installed.txt" ]]; then
        # Fallback: use the backup file created during installation
        pkg_count=$(wc -l < "${BUILD_DIR}/.rpm_packages_installed.txt" 2>/dev/null || echo 0)
        info "Using backup file ${BUILD_DIR}/.rpm_packages_installed.txt: ${pkg_count} packages"
        cat "${BUILD_DIR}/.rpm_packages_installed.txt"
    else
        error "RPM database not found and no backup available for ${root_fs_dir}"
        return 1
    fi
    
    # Fail fast if no packages found
    if [[ ${pkg_count} -eq 0 ]]; then
        error "ERROR: RPM package list is empty for ${root_fs_dir}"
        return 1
    fi
    
    return 0
}

# For RPM/DNF mode, RPM handles dependencies automatically
# Only need implicit packages in PORTAGE mode
image_packages_implicit() {
    return 0
}

get_metadata() {
    local prefix="$1"
    local pkg="$2"
    local key="$3"

    # Try RPM first if RPM database exists and package looks like RPM format
    local rpm_val=$(rpm_get_metadata "${prefix}" "${pkg}" "${key}" 2>/dev/null)
    if [[ -n "$rpm_val" ]]; then
        echo "$rpm_val"
        return 0
    fi

    # We should not be handling non-RPM packages here
    exit 1
}

start_image_rpm() {
  local root_fs_dir="$1"

    rpm_install_init "${root_fs_dir}"

    # Install filesystem RPM to provide basic directory structure
    # This replaces baselayout and creates /usr/lib, /etc, /bin -> usr/bin symlinks, etc.
    rpm_install_package "${root_fs_dir}" filesystem || {
        error "Failed to install filesystem package"
        return 1
    }

    # Install azurelinux-repos and azurelinux-repos-extended to get the official
    # repository definitions and GPG keys shipped by Azure Linux.
    rpm_install_package "${root_fs_dir}" azurelinux-repos azurelinux-repos-extended || {
        error "Failed to install azurelinux-repos packages"
        return 1
    }

    # Remove the bootstrap repo now that the package-provided repos are in place.
    rpm_use_official_repos "${root_fs_dir}"

    # Create sysusers.d configs and run systemd-sysusers to create users/groups
    # BEFORE any RPM packages are installed, since RPM %pre scriptlets may need them
    start_image_uids_rpm "${root_fs_dir}"
}

# Prepare chroot environment for dracut execution.
# Mounts pseudo-filesystems, creates udev/systemd symlinks, and sanitizes crypttab.
#
# Arguments:
#   $1 - root_fs_dir: path to the mounted root filesystem
_dracut_prepare_chroot() {
    local root_fs_dir="$1"

    # Mount required filesystems for dracut
    rpm_mount_pseudofs "${root_fs_dir}"

    # Ensure udevadm and systemd-udevd are findable
    # Azure Linux has udevadm at /usr/bin/udevadm and systemd-udevd at /usr/lib/systemd/systemd-udevd
    if [[ -x "${root_fs_dir}/usr/bin/udevadm" ]] && [[ ! -x "${root_fs_dir}/sbin/udevadm" ]]; then
        sudo ln -sf /usr/bin/udevadm "${root_fs_dir}/sbin/udevadm" 2>/dev/null || true
    fi
    if [[ -x "${root_fs_dir}/usr/lib/systemd/systemd-udevd" ]] && [[ ! -x "${root_fs_dir}/usr/bin/systemd-udevd" ]]; then
        sudo ln -sf /usr/lib/systemd/systemd-udevd "${root_fs_dir}/usr/bin/systemd-udevd" 2>/dev/null || true
        sudo ln -sf /usr/lib/systemd/systemd-udevd "${root_fs_dir}/sbin/systemd-udevd" 2>/dev/null || true
    fi
    # Also link udevd for compatibility
    if [[ -x "${root_fs_dir}/usr/lib/systemd/systemd-udevd" ]] && [[ ! -x "${root_fs_dir}/sbin/udevd" ]]; then
        sudo ln -sf /usr/lib/systemd/systemd-udevd "${root_fs_dir}/sbin/udevd" 2>/dev/null || true
    fi

    # If /etc/crypttab exists, ensure it doesn't contain fido2 entries
    # This prevents systemd-cryptsetup from requiring the fido2 module
    if [[ -f "${root_fs_dir}/etc/crypttab" ]]; then
        # Remove any fido2 entries if they exist
        sudo sed -i '/fido2-device=/d; /fido2-cid=/d' "${root_fs_dir}/etc/crypttab" 2>/dev/null || true
        die "Investigate further once this comes back."
    fi
}

# Patch bootengine dracut modules for Azure Linux compatibility.
# Removes unsupported modules, fixes ignition/disk-uuid/network-cleanup for ACL,
# and resolves systemd dependency cycles.
#
# Arguments:
#   $1 - root_fs_dir: path to the mounted root filesystem
_dracut_patch_bootengine_modules() {
    local root_fs_dir="$1"

    # Remove dracut modules that require hardware we don't have in VMs
    # This prevents systemd-cryptsetup from depending on fido2/pkcs11/tpm2-tss
    # which would cause dracut-systemd to fail
    for mod in 91fido2 91pkcs11 91tpm2-tss; do
        if [[ -d "${root_fs_dir}/usr/lib/dracut/modules.d/${mod}" ]]; then
            info "RPM mode: Removing dracut module ${mod} (not needed for VM boot)"
            sudo rm -rf "${root_fs_dir}/usr/lib/dracut/modules.d/${mod}"
        fi
    done

    # Remove bootengine's verity-generator - we use systemd's systemd-veritysetup-generator instead
    if [[ -d "${root_fs_dir}/usr/lib/dracut/modules.d/10verity-generator" ]]; then
        info "RPM mode: Removing bootengine 10verity-generator (using systemd-veritysetup-generator)"
        sudo rm -rf "${root_fs_dir}/usr/lib/dracut/modules.d/10verity-generator"
    fi

    # Remove bootengine's usr-generator - systemd-fstab-generator handles mount.usr= automatically
    # Our grub.cfg passes mount.usr=/dev/mapper/usr which systemd handles natively
    if [[ -d "${root_fs_dir}/usr/lib/dracut/modules.d/10usr-generator" ]]; then
        info "RPM mode: Removing bootengine 10usr-generator (using systemd-fstab-generator)"
        sudo rm -rf "${root_fs_dir}/usr/lib/dracut/modules.d/10usr-generator"
    fi

    # Remove Flatcar-specific and unsupported sections from ignition module-setup.sh
    local ignition_module_setup="${root_fs_dir}/usr/lib/dracut/modules.d/30ignition/module-setup.sh"
    if [[ -f "${ignition_module_setup}" ]]; then
        info "RPM mode: Removing Flatcar-specific sections from ignition module-setup.sh"
        # Remove cloud_aws_ebs_nvme_id (AWS-specific, doesn't exist in Azure Linux)
        sudo sed -i '/# Flatcar: add cloud_aws_ebs_nvme_id/,/\/usr\/lib\/udev\/cloud_aws_ebs_nvme_id"/d' "${ignition_module_setup}"
        # Remove clevis binding section (clevis not available in Azure Linux)
        sudo sed -i '/# Needed for clevis binding/,/tpm2_create$/d' "${ignition_module_setup}"
        # Remove s390x z/VM section (not supported)
        sudo sed -i "/# Required by s390x's z\/VM installation/,/inst_multiple -o chccwdev vmur$/d" "${ignition_module_setup}"
        # Remove clevis symlink entries from the executable wrapper loop
        sudo sed -i '/\/usr\/bin\/clevis\*,\\$/d' "${ignition_module_setup}"
        sudo sed -i '/\/usr\/libexec\/clevis\*\\$/d' "${ignition_module_setup}"
        # Fix trailing comma on systemd-reply-password (now last entry after removing clevis)
        sudo sed -i 's|/usr/lib/systemd/systemd-reply-password,\\|/usr/lib/systemd/systemd-reply-password\\|' "${ignition_module_setup}"
        # Replace /usr/bin/xfs_db and xfs_repair with /usr/sbin versions (Azure Linux path)
        sudo sed -i 's|/usr/bin/xfs_db,\\|/usr/sbin/xfs_db,\\|' "${ignition_module_setup}"
        sudo sed -i 's|/usr/bin/xfs_repair,\\|/usr/sbin/xfs_repair,\\|' "${ignition_module_setup}"
        # NOTE: Keep the /sysusr/usr wrapper paths! systemd-fstab-generator mounts
        # the verity /usr to /sysusr/usr, so wrappers pointing there are correct.
    fi

    # Remove cgpt from 30disk-uuid module (cgpt not available in Azure Linux)
    local disk_uuid_script="${root_fs_dir}/usr/lib/dracut/modules.d/30disk-uuid/disk-uuid.sh"
    local disk_uuid_module_setup="${root_fs_dir}/usr/lib/dracut/modules.d/30disk-uuid/module-setup.sh"
    if [[ -f "${disk_uuid_script}" ]]; then
        info "RPM mode: Removing cgpt call from disk-uuid.sh"
        sudo sed -i '/\/usr\/bin\/cgpt repair/d' "${disk_uuid_script}"
    fi
    if [[ -f "${disk_uuid_module_setup}" ]]; then
        info "RPM mode: Removing cgpt from 30disk-uuid/module-setup.sh"
        sudo sed -i '/cgpt$/d' "${disk_uuid_module_setup}"
    fi

    # Patch disk-uuid.service to order before systemd-veritysetup@usr.service
    # Bootengine's disk-uuid.service has "Before=verity-setup.service" for Flatcar's custom verity,
    # but ACL uses systemd's standard systemd-veritysetup-generator which creates
    # systemd-veritysetup@usr.service. Without this ordering, disk-uuid's sgdisk call
    # can cause udev activity that races with/terminates the verity setup process.
    local disk_uuid_service="${root_fs_dir}/usr/lib/dracut/modules.d/30disk-uuid/disk-uuid.service"
    if [[ -f "${disk_uuid_service}" ]]; then
        info "RPM mode: Adding Before=systemd-veritysetup@usr.service to disk-uuid.service"
        sudo sed -i 's/Before=ignition-setup.service ignition-disks.service verity-setup.service/Before=ignition-setup.service ignition-disks.service verity-setup.service systemd-veritysetup@usr.service/' "${disk_uuid_service}"
    fi

    # Patch ignition-setup.sh for systemd-based initramfs
    # In upstream Flatcar, initramfs /usr is a tmpfs that can be remounted rw.
    # In our systemd-native setup, /usr may already be mounted from verity device.
    # The "mount -o remount,rw" would fail because:
    # 1. /usr is not mounted (just initramfs tmpfs) - remount fails
    # 2. /usr is verity-protected - can't be made writable
    # Solution: Create /usr/lib/ignition without remounting - it's on initramfs tmpfs
    local ignition_setup_script="${root_fs_dir}/usr/lib/dracut/modules.d/30ignition/ignition-setup.sh"
    if [[ -f "${ignition_setup_script}" ]]; then
        info "RPM mode: Patching ignition-setup.sh - remove remount (initramfs /usr is already writable)"
        # Remove the remount command - initramfs /usr is tmpfs and already writable
        # The mkdir will work on the initramfs tmpfs /usr
        sudo sed -i '/mount -o remount,rw \/usr/d' "${ignition_setup_script}"
    fi

    # Remove bootengine's sysusr-usr-revdeps.conf which creates cyclic dependencies
    # Bootengine expects sysusr-usr.mount for its custom boot flow, and systemd-fstab-generator
    # creates exactly this unit! So the dependencies are correct.
    # Only remove sysusr-usr-revdeps.conf which creates extra cryptsetup dependencies we don't need.
    local sysusr_revdeps="${root_fs_dir}/usr/lib/dracut/modules.d/30ignition/sysusr-usr-revdeps.conf"
    if [[ -f "${sysusr_revdeps}" ]]; then
        info "RPM mode: Removing sysusr-usr-revdeps.conf (cryptsetup dep not needed)"
        sudo rm -f "${sysusr_revdeps}"
    fi
    # Also remove the inst_simple lines from module-setup.sh that install it (spans 2 lines)
    if [[ -f "${ignition_module_setup}" ]]; then
        # Remove both lines: "inst_simple ... sysusr-usr-revdeps.conf \" and the continuation line
        sudo sed -i '/inst_simple.*sysusr-usr-revdeps\.conf/,/sysusr-usr\.conf"/d' "${ignition_module_setup}"
    fi

    # NOTE: Keep sysusr-usr.mount dependencies! systemd-fstab-generator creates this unit
    # to mount /dev/mapper/usr at /sysusr/usr. Services need to wait for it.

    # Fix cyclic dependency: ignition-setup.service → sysusr-usr.mount → local-fs-pre.target → ignition-setup.service
    # The ignition-generator creates services with "Requires/Before=local-fs-pre.target" but
    # sysusr-usr.mount (created by systemd-fstab-generator) has ordering with local-fs-pre.target.
    # Solution: Remove the local-fs-pre.target dependency from ignition services.
    # They only need sysusr-usr.mount (for /usr access), not local-fs-pre.target.
    local ignition_generator="${root_fs_dir}/usr/lib/dracut/modules.d/30ignition/ignition-generator"
    if [[ -f "${ignition_generator}" ]]; then
        info "RPM mode: Patching ignition-generator to remove local-fs-pre.target cycle"
        # Remove the Requires=local-fs-pre.target and Before=local-fs-pre.target lines
        # from both ignition-setup-pre.service and ignition-setup.service generation
        sudo sed -i '/Requires=local-fs-pre.target/d' "${ignition_generator}"
        sudo sed -i '/Before=local-fs-pre.target/d' "${ignition_generator}"
    fi

    # Also patch static ignition service files that have local-fs-pre.target dependencies
    local ignition_mod_dir="${root_fs_dir}/usr/lib/dracut/modules.d/30ignition"
    for service_file in "${ignition_mod_dir}"/ignition-*.service; do
        if [[ -f "${service_file}" ]] && grep -q "local-fs-pre.target" "${service_file}"; then
            info "RPM mode: Patching $(basename "${service_file}") to remove local-fs-pre.target"
            sudo sed -i '/Requires=local-fs-pre.target/d' "${service_file}"
            sudo sed -i '/Before=local-fs-pre.target/d' "${service_file}"
        fi
    done

    # Patch network-cleanup.service to stop before initrd-cleanup while /usr/bin/ip is accessible
    # The service runs in initrd and uses /usr/bin/ip in ExecStop. Without this fix, the stop
    # happens after switch-root when the initrd binaries are gone, causing exit code 203/EXEC.
    # We add `-` prefix to ExecStop to make failures non-fatal (binary may be gone during switch-root)
    local network_cleanup_svc="${root_fs_dir}/usr/lib/dracut/modules.d/03flatcar-network/network-cleanup.service"
    if [[ -f "${network_cleanup_svc}" ]]; then
        info "RPM mode: Patching network-cleanup.service for initrd stop handling"
        # Add ConditionPathExists to only run in initrd
        sudo sed -i '/ConditionKernelCommandLine=!netroot/a # Only run in initrd\nConditionPathExists=/etc/initrd-release' "${network_cleanup_svc}"
        # Add initrd-cleanup.service and initrd-switch-root.service to Before= line
        # This ensures ExecStop runs before the switch-root happens and before cleanup
        sudo sed -i 's/Before=systemd-networkd.service initrd-switch-root.target/Before=systemd-networkd.service initrd-switch-root.target initrd-switch-root.service initrd-cleanup.service/' "${network_cleanup_svc}"
        # Add initrd-cleanup.service and initrd-switch-root.service to Conflicts= line
        # Conflicts triggers stop when these units start
        sudo sed -i 's/Conflicts=initrd-switch-root.target/Conflicts=initrd-switch-root.target initrd-switch-root.service initrd-cleanup.service/' "${network_cleanup_svc}"
        # Add StopWhenUnneeded=true to end of [Unit] section so service stops as soon as nothing needs it
        sudo sed -i '/^ConditionPathExists=\/etc\/initrd-release$/a StopWhenUnneeded=true' "${network_cleanup_svc}"
        # Make ExecStop commands optional with - prefix (won't fail if binary missing during switch-root)
        sudo sed -i 's|ExecStop=/usr/bin/ip|ExecStop=-/usr/bin/ip|g' "${network_cleanup_svc}"

        # Also install network-cleanup.service on the real root filesystem
        # This is needed because PartOf=systemd-networkd.service causes systemd to try
        # stopping the service after switch-root. With the service file on real root,
        # the stop will succeed using the real /usr/bin/ip.
        info "RPM mode: Installing network-cleanup.service on real root for post-switch-root stop"
        sudo cp "${network_cleanup_svc}" "${root_fs_dir}/usr/lib/systemd/system/network-cleanup.service"
    fi
}

# Install new initramfs assets that dracut will pick up.
# Creates the sysroot-oem dracut module, flatcar-tmpfiles stub, tmpfiles.d configs,
# and systemd drop-ins for verity device timing. Must run BEFORE dracut execution.
#
# Arguments:
#   $1 - root_fs_dir: path to the mounted root filesystem
_dracut_install_initramfs_assets() {
    local root_fs_dir="$1"

    # Create sysroot-oem.mount unit matching Flatcar's diskless-generator behavior.
    # This unit is created but NOT added to initrd-root-fs.target.requires, so it
    # won't be automatically started. Instead, ignition-files.service has:
    #   ExecStartPre=-systemctl start sysroot-oem.mount
    # which starts it when needed (the - prefix means failure is ignored).
    #
    # Note: cl.ignition.oem.regular test is excluded from ACL because it uses
    # the old /usr/share/oem path which requires Ignition patch 0020's umount
    # path translation that we don't have. cl.ignition.oem.regular.new uses
    # the new /oem path and works correctly.
    info "RPM mode: Creating sysroot-oem.mount for OEM partition handling"
    local sysroot_oem_dracut_module="${root_fs_dir}/usr/lib/dracut/modules.d/35sysroot-oem"
    sudo mkdir -p "${sysroot_oem_dracut_module}"
    cat <<'EOF' | sudo tee "${sysroot_oem_dracut_module}/sysroot-oem.mount" > /dev/null
# Matches Flatcar's diskless-generator behavior
# (Ignition's OEM mounting can also (de)activate the unit)
[Mount]
What=/dev/disk/by-label/OEM
Where=/sysroot/oem
Type=auto
Options=nodev
EOF

    # Create module-setup.sh to install sysroot-oem.mount into initramfs
    cat <<'SETUP_EOF' | sudo tee "${sysroot_oem_dracut_module}/module-setup.sh" > /dev/null
#!/bin/bash
# dracut module for sysroot-oem mount unit

check() {
    return 0
}

depends() {
    return 0
}

install() {
    inst_simple "${moddir}/sysroot-oem.mount" "${systemdsystemunitdir}/sysroot-oem.mount"
}
SETUP_EOF
    sudo chmod +x "${sysroot_oem_dracut_module}/module-setup.sh"

    # NOTE: /etc overlay is handled by bootengine's 99setup-root/initrd-setup-root
    # We need to create the required files BEFORE dracut runs so they get included in initramfs

    # Create flatcar-tmpfiles stub script required by bootengine's initrd-setup-root
    # Must be created before dracut so it gets included in initramfs
    info "RPM mode: Creating flatcar-tmpfiles stub for bootengine compatibility"
    sudo mkdir -p "${root_fs_dir}/usr/sbin"
    cat <<'EOF' | sudo tee "${root_fs_dir}/usr/sbin/flatcar-tmpfiles" > /dev/null
#!/bin/bash
# Stub for flatcar-tmpfiles - Azure Linux handles user/group creation differently
# This script is called by bootengine's initrd-setup-root to initialize shadow database
# In Azure Linux, the shadow database is pre-populated by RPM packages
SYSROOT="${1:-/sysroot}"
# Ensure essential directories exist
mkdir -p "${SYSROOT}/etc" 
# Ensure basic shadow files exist (if not already present)
for f in passwd group shadow gshadow; do
    if [[ ! -f "${SYSROOT}/etc/${f}" ]] && [[ -f "${SYSROOT}/usr/share/flatcar/etc/${f}" ]]; then
        cp "${SYSROOT}/usr/share/flatcar/etc/${f}" "${SYSROOT}/etc/${f}"
    fi
done
exit 0
EOF
    sudo chmod +x "${root_fs_dir}/usr/sbin/flatcar-tmpfiles"

    # Create tmpfiles.d configs required by bootengine's initrd-setup-root
    # These are minimal configs - Azure Linux already provides most paths via its own tmpfiles
    # We only include entries not already in Azure Linux's standard tmpfiles configs
    info "RPM mode: Creating tmpfiles.d configs for bootengine compatibility"
    local tmpfiles_dir="${root_fs_dir}/usr/lib/tmpfiles.d"
    sudo mkdir -p "${tmpfiles_dir}"

    # baselayout.conf - only entries not in Azure Linux's var.conf/tmp.conf
    cat <<'EOF' | sudo tee "${tmpfiles_dir}/baselayout.conf" > /dev/null
# Bootengine compatibility - journal directory for early boot
d /var/log/journal 0755 root root -
d /var/log/journal/remote 0755 root root -
d /run/lock 0755 root root -
# Mount points required by bootengine
d /var/log/audit 0755 root root -
d /boot 0755 root root -
d /oem 0755 root root -
d /media 0755 root root -
EOF

    # baselayout-usr.conf - required by bootengine's initrd-setup-root which
    # explicitly runs: systemd-tmpfiles --create baselayout-usr.conf
    # Empty because /usr/local dirs are created at build time and /usr is read-only,
    # so tmpfiles would only trigger SELinux relabel warnings.
    cat <<'EOF' | sudo tee "${tmpfiles_dir}/baselayout-usr.conf" > /dev/null
# Intentionally empty - /usr/local dirs exist at build time; /usr is read-only
EOF

    # baselayout-home.conf - only core user home (not /home itself)
    cat <<'EOF' | sudo tee "${tmpfiles_dir}/baselayout-home.conf" > /dev/null
# Core user home directory
d /home/core 0700 core core -
EOF

    # base_image_var.conf - only entries not in Azure Linux's var.conf
    cat <<'EOF' | sudo tee "${tmpfiles_dir}/base_image_var.conf" > /dev/null
# Additional /var structure for bootengine
d /var/lib/systemd/coredump 0755 root root -
EOF

    # Remove baselayout-ldso.conf — it creates a symlink /etc/ld.so.conf -> ../usr/lib/ld.so.conf
    # but Azure Linux's glibc RPM installs /etc/ld.so.conf as a regular file (with different
    # content and layout). The symlink target doesn't exist, producing a dead link.
    sudo rm -f "${tmpfiles_dir}/baselayout-ldso.conf"

    # Note: chrony tmpfiles (var/lib/chrony dir, chrony.keys copy) are installed
    # by the oem-azure sysext via manglefs.sh

    # Create systemd drop-ins for verity device timing
    # These ensure udev has finished device enumeration before verity setup runs
    local systemd_dropin_dir="${root_fs_dir}/usr/lib/systemd/system"

    # Drop-in for dev-mapper-usr.device - disable job timeout
    info "RPM mode: Creating drop-in for dev-mapper-usr.device (no job timeout)"
    sudo mkdir -p "${systemd_dropin_dir}/dev-mapper-usr.device.d"
    cat <<'EOF' | sudo tee "${systemd_dropin_dir}/dev-mapper-usr.device.d/no-job-timeout.conf" > /dev/null
[Unit]
# Disable job timeout to allow verity setup to wait for slow device enumeration
JobRunningTimeoutSec=infinity
EOF

    # Drop-in for systemd-veritysetup@usr.service - wait for udev settle
    info "RPM mode: Creating drop-in for systemd-veritysetup@usr.service (wait for udev)"
    sudo mkdir -p "${systemd_dropin_dir}/systemd-veritysetup@usr.service.d"
    cat <<'EOF' | sudo tee "${systemd_dropin_dir}/systemd-veritysetup@usr.service.d/wait-for-udev.conf" > /dev/null
[Unit]
# Wait for udev to finish device enumeration before attempting verity setup
After=systemd-udev-settle.service
Wants=systemd-udev-settle.service
EOF
}

# Generate initramfs using dracut inside the root filesystem chroot.
# Orchestrates chroot preparation, bootengine module patching, asset installation,
# and dracut execution to produce the initramfs.
#
# Arguments:
#   $1 - root_fs_dir: path to the mounted root filesystem
#   $2 - kernel_version: kernel version string (e.g. 6.6.112.1-2.azl3)
#   $3 - boot_fc_path: path to /boot/flatcar inside root_fs_dir
generate_initramfs_dracut() {
    local root_fs_dir="$1"
    local kernel_version="$2"
    local boot_fc_path="$3"

    if ! [[ -x "${root_fs_dir}/usr/bin/dracut" ]] && ! [[ -x "${root_fs_dir}/sbin/dracut" ]]; then
        die "RPM mode: dracut not found - cannot generate initramfs required for Azure Linux kernel"
    fi

    info "RPM mode: Generating initramfs with dracut"

    _dracut_prepare_chroot "${root_fs_dir}"
    _dracut_patch_bootengine_modules "${root_fs_dir}"
    _dracut_install_initramfs_assets "${root_fs_dir}"

    # Create dracut config to work around issues in chroot environment
    # We rely on standard systemd-udevd module to include libudev.so
    sudo mkdir -p "${root_fs_dir}/etc/dracut.conf.d"
    sudo cp "${BUILD_LIBRARY_DIR}/rpm/additional_files/99-hybrid-build.conf" "${root_fs_dir}/etc/dracut.conf.d/99-hybrid-build.conf"

    # Create a wrapper script that sets up the environment properly for dracut
    sudo cp "${BUILD_LIBRARY_DIR}/rpm/additional_files/run-dracut.sh" "${root_fs_dir}/tmp/run-dracut.sh"
    sudo chmod +x "${root_fs_dir}/tmp/run-dracut.sh"

    # Run dracut via the wrapper script with verbose logging
    # Output goes to log file only to reduce noise in build output
    local dracut_log="${root_fs_dir}/tmp/dracut-verbose.log"
    info "RPM mode: Running dracut (log: ${dracut_log})..."
    local initramfs_path="${boot_fc_path}/initramfs-a.img"
    # For chroot, use path relative to chroot environment
    local initramfs_chroot_path="/boot/flatcar/initramfs-a.img"
    sudo chroot "${root_fs_dir}" /tmp/run-dracut.sh \
      --force \
      --no-hostonly \
      --no-early-microcode \
      --verbose \
      --kver "${kernel_version}" \
        "${initramfs_chroot_path}" > "${dracut_log}" 2>&1 || {
        error "RPM mode: dracut failed. Log saved to ${dracut_log}"
        error "Last 50 lines of dracut log:"
        tail -50 "${dracut_log}" | while read line; do error "  $line"; done
        # Copy dracut log to build output for analysis
        if cp "${dracut_log}" "${BUILD_DIR}/dracut-verbose.log" 2>/dev/null; then
            error "RPM mode: dracut log saved to ${BUILD_DIR}/dracut-verbose.log"
        fi
        # Clean up before failing
        sudo rm -f "${root_fs_dir}/tmp/run-dracut.sh"
        rpm_umount_pseudofs "${root_fs_dir}"
        die "RPM mode: dracut initramfs generation failed"
      }

    # Copy dracut log to build output for analysis
    if [[ -f "${dracut_log}" ]] && cp "${dracut_log}" "${BUILD_DIR}/dracut-verbose.log" 2>/dev/null; then
        info "RPM mode: dracut log saved to ${BUILD_DIR}/dracut-verbose.log"
    fi

    # Clean up wrapper script
    sudo rm -f "${root_fs_dir}/tmp/run-dracut.sh"

    # Unmount filesystems
    rpm_umount_pseudofs "${root_fs_dir}"

    if [[ -f "${initramfs_path}" ]]; then
      info "RPM mode: initramfs generated successfully"
      ls -la "${initramfs_path}"
    else
      die "RPM mode: initramfs was not generated at ${initramfs_path}"
    fi
}

finish_image_rpm() {
  local root_fs_dir="$1"
    
    # Create /usr/share/oem -> ../../oem symlink for backward compatibility
    # The OEM partition is mounted at /oem, but legacy configs reference /usr/share/oem
    # Use relative symlink (../../oem) so it works correctly when accessed via /sysroot in initrd
    # See: https://github.com/flatcar/bootengine/pull/58
    sudo mkdir -p "${root_fs_dir}/usr/share"
    sudo ln -sfT ../../oem "${root_fs_dir}/usr/share/oem"

    # In RPM mode, the kernel is installed by Azure Linux RPM to /boot/vmlinuz-*.
    # Find and copy it to the expected location for grub.cfg
    local kernel_file
    kernel_file=$(ls "${root_fs_dir}"/boot/vmlinuz-* 2>/dev/null | grep -v ".hmac" | head -1)
    if [[ -n "${kernel_file}" ]]; then
      BOOT_FC_PATH="${root_fs_dir}/boot/flatcar"
      LINUX_KERNEL_DIR_A="${BOOT_FC_PATH}/vmlinuz-a"
      info "RPM mode: Copying kernel from ${kernel_file} to ${LINUX_KERNEL_DIR_A}"
      sudo cp "${kernel_file}" "${LINUX_KERNEL_DIR_A}"

      # Extract kernel version from filename (e.g., vmlinuz-6.6.112.1-2.azl3 -> 6.6.112.1-2.azl3)
      local kernel_version
      kernel_version=$(basename "${kernel_file}" | sed 's/vmlinuz-//')
      info "RPM mode: Kernel version is ${kernel_version}"

      generate_initramfs_dracut "${root_fs_dir}" "${kernel_version}" "${BOOT_FC_PATH}"
    else
      die "RPM mode: No kernel found in ${root_fs_dir}/boot/"
    fi
}

# Create sysusers.d configs for all system users/groups needed by ACL
# Called early from start_image_rpm() so users exist before RPM %pre scriptlets run
start_image_uids_rpm() {
  local root_fs_dir="$1"

    # RPM mode: Create sysusers.d configs for system users that Azure Linux expects
    # but doesn't provide via sysusers.d (normally created by RPM scriptlets)
    info "RPM mode: Creating sysusers.d configs for essential system users"
    sudo mkdir -p "${root_fs_dir}/usr/lib/sysusers.d"

    # D-Bus messagebus user - required for dbus.service
    sudo tee "${root_fs_dir}/usr/lib/sysusers.d/dbus.conf" > /dev/null <<'SYSUSERS_DBUS'
# D-Bus system message bus user
u messagebus 81 "System Message Bus" /run/dbus
SYSUSERS_DBUS
    
    # polkitd user - Fedora setup uses UID 114
    sudo tee "${root_fs_dir}/usr/lib/sysusers.d/polkit.conf" > /dev/null <<'SYSUSERS_POLKIT'
# PolicyKit daemon user
g polkitd 114 -
u polkitd 114:114 "PolicyKit Daemon Owner" /etc/polkit-1 /bin/false
SYSUSERS_POLKIT
    
    # tss user/group - Azure Linux tpm2-tss uses UID/GID 59 (matches Gentoo)
    sudo tee "${root_fs_dir}/usr/lib/sysusers.d/tss.conf" > /dev/null <<'SYSUSERS_TSS'
# TCG Software Stack (TPM2) user
g tss 59 -
u tss 59:59 "TCG Software Stack" /var/lib/tpm /bin/false
SYSUSERS_TSS

    # sshd user - required for OpenSSH privilege separation
    # Alas, 74 which is used by Fedora, is already taken in 3.0 filesystem package, so for now we will dynamically allocate
    sudo tee "${root_fs_dir}/usr/lib/sysusers.d/sshd.conf" > /dev/null <<'SYSUSERS_SSHD'
# SSH privilege separation user
g sshd - -
u sshd - "Privilege-separated SSH" /usr/share/empty.sshd
SYSUSERS_SSHD
    
    # systemd-coredump user - for coredump handling
    sudo tee "${root_fs_dir}/usr/lib/sysusers.d/systemd-coredump.conf" > /dev/null <<'SYSUSERS_COREDUMP'
# systemd coredump user
u systemd-coredump - "systemd Core Dumper" /
SYSUSERS_COREDUMP

    # systemd-network user - for networkd
    sudo tee "${root_fs_dir}/usr/lib/sysusers.d/systemd-network.conf" > /dev/null <<'SYSUSERS_NETWORK'
# systemd network management user
u systemd-network - "systemd Network Management" /
SYSUSERS_NETWORK

    # systemd-resolve user - for resolved
    sudo tee "${root_fs_dir}/usr/lib/sysusers.d/systemd-resolve.conf" > /dev/null <<'SYSUSERS_RESOLVE'
# systemd DNS resolver user
u systemd-resolve - "systemd Resolver" /
SYSUSERS_RESOLVE

    # systemd-timesync user - for timesyncd
    sudo tee "${root_fs_dir}/usr/lib/sysusers.d/systemd-timesync.conf" > /dev/null <<'SYSUSERS_TIMESYNC'
# systemd time synchronization user
u systemd-timesync - "systemd Time Synchronization" /
SYSUSERS_TIMESYNC

    # chrony user - for chrony, required for oem-azure sysext
    sudo tee "${root_fs_dir}/usr/lib/sysusers.d/chrony.conf" > /dev/null <<'SYSUSERS_CHRONY'
# chrony time daemon user
g chrony - -
u chrony - "chrony time daemon" /var/lib/chrony /sbin/nologin
SYSUSERS_CHRONY

    # docker group - for docker socket permissions
    sudo tee "${root_fs_dir}/usr/lib/sysusers.d/docker.conf" > /dev/null <<'SYSUSERS_DOCKER'
# Docker group for socket access
g docker - -
SYSUSERS_DOCKER

    # systemd-journal group - for reading journal logs (GID 190 from Flatcar)
    # core user needs to be a member for journalctl access
    sudo tee "${root_fs_dir}/usr/lib/sysusers.d/systemd-journal.conf" > /dev/null <<'SYSUSERS_JOURNAL'
# systemd journal group - allows reading system logs
g systemd-journal 190 -
SYSUSERS_JOURNAL

    # wheel and sudo groups - for administrative access
    sudo tee "${root_fs_dir}/usr/lib/sysusers.d/admin-groups.conf" > /dev/null <<'SYSUSERS_ADMIN'
# Administrative groups
g wheel 10 -
g sudo 150 -
SYSUSERS_ADMIN

    # core user - primary user for Flatcar/ACL (UID/GID 500)
    # This is the default non-root user for SSH access and container operations
    sudo tee "${root_fs_dir}/usr/lib/sysusers.d/core.conf" > /dev/null <<'SYSUSERS_CORE'
# Core user - primary administrative user
g core 500 -
u core 500:500 "ACL Admin" /home/core /bin/bash
m core wheel
m core sudo
m core docker
m core systemd-journal
SYSUSERS_CORE

    # Run systemd-sysusers to create users in /etc/passwd and /etc/group
    info "RPM mode: Running systemd-sysusers to create users"
    sudo systemd-sysusers --root="${root_fs_dir}"

    info "RPM mode: Created sysusers.d configs for system users"

    # NOTE: /home/core directory creation happens in initramfs via etc-overlay.sh
    # The finish_image() function deletes everything except /boot, /usr, /oem at build time,
    # so any directories we create here would be removed. The etc-overlay.sh script 
    # (part of the 99etc-overlay dracut module) creates /home/core with proper permissions
    # BEFORE ignition-files.service runs, which is when ignition writes SSH keys.

    # Download grub/shim/systemd-boot packages for later use by grub_install.sh and uki_install.sh
    # Must be done here while /etc/yum.repos.d is still available
    info "RPM mode: Pre-downloading bootloader packages (grub2, shim, systemd-boot)"
    rpm_staging=$(rpm_get_staging_dir)
    rpm_download_packages "${rpm_staging}" "${root_fs_dir}" grub2 grub2-efi grub2-efi-binary shim systemd-boot
}

finish_image_cleanup_issue_rpm() {
    local root_fs_dir="$1"

    # Remove /etc/issue files and tmpfiles.d entries that conflict with bootengine's issuegen.conf.
    # Azure Linux packages install /etc/issue and tmpfiles.d rules, but we want issuegen.conf
    # to be the sole source for /etc/issue → ../run/issue symlink creation at boot.
    info "RPM mode: Cleaning up /etc/issue conflicts (issuegen.conf will manage /etc/issue at boot)"
    
    # Remove physical files
    sudo rm -f "${root_fs_dir}/etc/issue" "${root_fs_dir}/etc/issue.net"
    sudo rm -f "${root_fs_dir}/usr/lib/issue" "${root_fs_dir}/usr/lib/issue.net"
    sudo rm -f "${root_fs_dir}/usr/share/factory/etc/issue" "${root_fs_dir}/usr/share/factory/etc/issue.net"

    # Remove conflicting tmpfiles.d entries
    # etc.conf has: C! /etc/issue - - - -
    # provision.conf has: f^ /etc/issue.d/50-provision.conf - - - - login.issue
    if [[ -f "${root_fs_dir}/usr/lib/tmpfiles.d/etc.conf" ]]; then
        sudo sed -i '/\/etc\/issue[^.].*$/d' "${root_fs_dir}/usr/lib/tmpfiles.d/etc.conf"
    fi
    if [[ -f "${root_fs_dir}/usr/lib/tmpfiles.d/provision.conf" ]]; then
        sudo sed -i '/\/etc\/issue\.d/d' "${root_fs_dir}/usr/lib/tmpfiles.d/provision.conf"
    fi
}

finish_image_kernel_config_rpm() {
    local root_fs_dir="$1"

    # In RPM mode, kernel config is at /boot/config-* (Azure Linux layout)
    local config_file
    config_file=$(ls "${root_fs_dir}"/boot/config-* 2>/dev/null | head -1)
    if [[ -n "${config_file}" ]]; then
        cp "${config_file}" "${BUILD_DIR}/${image_kconfig}"
    else
        die "RPM mode: No kernel config found in /boot/"
    fi
}

finish_image_selinux_rpm() {
    local root_fs_dir="$1"

    # Use the targeted policy file_contexts to label the filesystem
    local file_contexts="${root_fs_dir}/etc/selinux/targeted/contexts/files/file_contexts"
    info "RPM mode: Labeling filesystem with targeted SELinux policy"
    sudo setfiles -Dv -r "${root_fs_dir}" "${file_contexts}" "${root_fs_dir}" >/dev/null
    sudo setfiles -Dv -r "${root_fs_dir}" "${file_contexts}" "${root_fs_dir}/etc" >/dev/null
    sudo setfiles -Dv -r "${root_fs_dir}" "${file_contexts}" "${root_fs_dir}/usr" >/dev/null
}

finish_image_tmpfiles_rpm() {
    local root_fs_dir="$1"

    sudo "${root_fs_dir}"/usr/sbin/flatcar-tmpfiles "${root_fs_dir}"

    # sshd privilege separation directory
    sudo tee "${root_fs_dir}/usr/lib/tmpfiles.d/sshd.conf" > /dev/null <<'TMPFILES_SSHD'
# SSH privilege separation directory
d /var/lib/sshd 0755 root root - -
TMPFILES_SSHD

    # Remove umask.sh installed by Azure Linux bash RPM to align with upstream Flatcar behavior
    sudo rm -f "${root_fs_dir}/etc/profile.d/umask.sh"

    # Configure sshd to look for authorized_keys in the ignition location
    # Ignition places SSH keys in ~/.ssh/authorized_keys.d/ignition
    info "RPM mode: Configuring sshd AuthorizedKeysFile for Ignition"
    local ssh_config_dir="${root_fs_dir}/etc/ssh"
    sudo mkdir -p "${ssh_config_dir}/sshd_config.d"
    sudo tee "${ssh_config_dir}/sshd_config.d/10-authorized-keys.conf" > /dev/null <<'SSHD_CONF'
# Support both traditional authorized_keys and Ignition's authorized_keys.d/ignition
AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys.d/ignition
SSHD_CONF
    sudo chmod 644 "${ssh_config_dir}/sshd_config.d/10-authorized-keys.conf"

    # Ensure sshd_config includes the .d directory
    local sshd_config="${ssh_config_dir}/sshd_config"
    if [[ ! -f "${sshd_config}" ]]; then
        # sshd_config doesn't exist - create a minimal one with Include
        info "RPM mode: Creating sshd_config with Include directive"
        sudo tee "${sshd_config}" > /dev/null <<'SSHD_CONFIG_EOF'
# Include drop-in configurations
Include /etc/ssh/sshd_config.d/*.conf
SSHD_CONFIG_EOF
        sudo chmod 644 "${sshd_config}"
    elif ! sudo grep -q "^Include.*/etc/ssh/sshd_config.d" "${sshd_config}"; then
        info "RPM mode: Adding Include directive to existing sshd_config"
        sudo sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "${sshd_config}"
    else
        info "RPM mode: sshd_config already has Include directive"
    fi

    # Configure sudo for wheel group (passwordless)
    info "RPM mode: Configuring passwordless sudo for wheel group"
    sudo mkdir -p "${root_fs_dir}/etc/sudoers.d"
    sudo tee "${root_fs_dir}/etc/sudoers.d/wheel-nopasswd" > /dev/null <<'SUDOERS_EOF'
%wheel ALL=(ALL:ALL) NOPASSWD: ALL
SUDOERS_EOF
    sudo chmod 440 "${root_fs_dir}/etc/sudoers.d/wheel-nopasswd"

    # Install update-ssh-keys replacement script
    info "RPM mode: Installing update-ssh-keys replacement script"
    sudo cp "${BUILD_LIBRARY_DIR}/rpm/additional_files/update-ssh-keys" "${root_fs_dir}/usr/bin/update-ssh-keys"
    sudo chmod +x "${root_fs_dir}/usr/bin/update-ssh-keys"

    # Enable systemd-networkd service
    info "RPM mode: Enabling systemd-networkd.service"
    sudo mkdir -p "${root_fs_dir}/usr/lib/systemd/system/multi-user.target.wants"
    sudo ln -sf ../systemd-networkd.service "${root_fs_dir}/usr/lib/systemd/system/multi-user.target.wants/systemd-networkd.service"

    # Enable systemd-resolved service (for DNS)
    info "RPM mode: Enabling systemd-resolved.service"
    sudo ln -sf ../systemd-resolved.service "${root_fs_dir}/usr/lib/systemd/system/multi-user.target.wants/systemd-resolved.service"

    # Fix ntpdate-wrapper - Azure Linux has ntpdate at /usr/bin but wrapper
    # script expects /usr/sbin
    # Tracked by https://dev.azure.com/mariner-org/ACL/_workitems/edit/17804
    if [[ -f "${root_fs_dir}/usr/libexec/ntpdate-wrapper" ]]; then
        info "RPM mode: Patching ntpdate-wrapper to use /usr/bin/ntpdate"
        sudo sed -i 's|/usr/sbin/ntpdate|/usr/bin/ntpdate|g' "${root_fs_dir}/usr/libexec/ntpdate-wrapper"
    fi

    # Add drop-in for ntpdate.service to ensure DNS is ready before running
    # The service has After=nss-lookup.target but DNS servers may not be configured yet
    # We add retries to handle the race between DHCP configuring DNS and ntpdate running
    if [[ -f "${root_fs_dir}/usr/lib/systemd/system/ntpdate.service" ]]; then
        info "RPM mode: Adding ntpdate.service drop-in for DNS retry handling and timesyncd conflict"
        sudo mkdir -p "${root_fs_dir}/usr/lib/systemd/system/ntpdate.service.d"
        cat <<'EOF' | sudo tee "${root_fs_dir}/usr/lib/systemd/system/ntpdate.service.d/10-flatcar.conf" > /dev/null
[Unit]
# Ensure DNS resolution is available before trying to resolve NTP server names
After=systemd-resolved.service
Wants=systemd-resolved.service
# Conflict with systemd-timesyncd - only one NTP client should run
Conflicts=systemd-timesyncd.service

[Service]
# Retry on failure - DNS may not be configured immediately after resolved starts
# DHCP needs time to provide DNS servers to systemd-resolved
Restart=on-failure
RestartSec=5
StartLimitInterval=60
StartLimitBurst=5
EOF
    fi

    # TODO: reevaluate the approach, tracked by https://dev.azure.com/mariner-org/mariner/_workitems/edit/17500
    # Add drop-in for nfs-mountd.service to ensure rpcbind is ready before starting
    # Without this ordering, rpc.mountd blocks trying to register with portmapper,
    # exceeds the 45s TimeoutStartSec, and gets killed - failing nfs-server.service too
    if [[ -f "${root_fs_dir}/usr/lib/systemd/system/nfs-mountd.service" ]]; then
        info "RPM mode: Adding nfs-mountd.service drop-in for rpcbind dependency"
        sudo mkdir -p "${root_fs_dir}/usr/lib/systemd/system/nfs-mountd.service.d"
        cat <<'EOF' | sudo tee "${root_fs_dir}/usr/lib/systemd/system/nfs-mountd.service.d/10-rpcbind-dependency.conf" > /dev/null
[Unit]
# rpc.mountd needs rpcbind to register its RPC program number.
# Ordering after rpcbind.service (not just .socket) avoids a 60-second
# libtirpc timeout caused by socket-activation handoff races: mountd's
# first RPC registration call can stall when rpcbind.service hasn't
# finished starting yet, exceeding the 45s TimeoutStartSec.
Wants=rpcbind.service
After=rpcbind.service
EOF
    fi

    # Fix rpc-statd.service - the Azure Linux unit uses Type=forking with a legacy
    # PIDFile=/var/run/rpc.statd.pid path.  Switch to foreground mode and fix the path.
    if [[ -f "${root_fs_dir}/usr/lib/systemd/system/rpc-statd.service" ]]; then
        info "RPM mode: Fixing rpc-statd.service (foreground mode + /var/run → /run)"
        sudo sed -i 's|/var/run/|/run/|g' "${root_fs_dir}/usr/lib/systemd/system/rpc-statd.service"
        sudo mkdir -p "${root_fs_dir}/usr/lib/systemd/system/rpc-statd.service.d"
        cat <<'EOF' | sudo tee "${root_fs_dir}/usr/lib/systemd/system/rpc-statd.service.d/10-foreground.conf" > /dev/null
[Service]
Type=simple
ExecStart=
ExecStart=/usr/sbin/rpc.statd --no-notify -F
PIDFile=
EOF
    fi

    # Fix rpcbind.socket - uses legacy /var/run/ path
    if [[ -f "${root_fs_dir}/usr/lib/systemd/system/rpcbind.socket" ]]; then
        info "RPM mode: Fixing rpcbind.socket (/var/run → /run)"
        sudo sed -i 's|/var/run/|/run/|g' "${root_fs_dir}/usr/lib/systemd/system/rpcbind.socket"
    fi

    # Create /var/lib/nfs directories needed by rpc-statd and NFS server via tmpfiles
    # The nfs-utils RPM only creates v4recovery; sm and sm.bak are missing from the package
    # /var is stateful so we use tmpfiles.d to create these at boot, not mkdir at build time
    info "RPM mode: Adding tmpfiles.d config for NFS state directories"
    cat <<'EOF' | sudo tee "${root_fs_dir}/usr/lib/tmpfiles.d/nfs-utils.conf" > /dev/null
# NFS state directories required by rpc-statd and NFS server
d /var/lib/nfs 0755 root root -
d /var/lib/nfs/sm 0755 root root -
d /var/lib/nfs/sm.bak 0755 root root -
d /var/lib/nfs/v4recovery 0755 root root -
d /var/lib/nfs/v4root 0755 root root -
d /var/lib/nfs/rpc_pipefs 0755 root root -
EOF

    # Disable ntpdate.service - systemd-timesyncd is preferred for time sync
    # Use a preset file to disable ntpdate and remove existing symlinks
    info "RPM mode: Disabling ntpdate.service via preset (using systemd-timesyncd instead)"
    sudo mkdir -p "${root_fs_dir}/usr/lib/systemd/system-preset"
    echo "disable ntpdate.service" | sudo tee "${root_fs_dir}/usr/lib/systemd/system-preset/50-acl-ntp.preset" > /dev/null

    # Disable rsyncd.service - should not run by default (security: listens on port 873)
    info "RPM mode: Disabling rsyncd.service via preset"
    echo "disable rsyncd.service" | sudo tee "${root_fs_dir}/usr/lib/systemd/system-preset/50-acl-rsyncd.preset" > /dev/null
    sudo rm -f "${root_fs_dir}/usr/share/flatcar/etc/systemd/system/multi-user.target.wants/ntpdate.service"
    sudo rm -f "${root_fs_dir}/etc/systemd/system/multi-user.target.wants/ntpdate.service"

    # Switch sshd to socket activation (matching Flatcar behavior)
    # The Azure Linux openssh RPM only ships sshd.service (traditional daemon).
    # Socket activation means systemd listens on port 22 and spawns sshd per-connection,
    # which is more efficient and matches what Flatcar's cl.network.listeners test expects.
    info "RPM mode: Setting up sshd socket activation"
    # Create sshd.socket - systemd will listen on port 22
    sudo tee "${root_fs_dir}/usr/lib/systemd/system/sshd.socket" > /dev/null <<'SSHD_SOCKET'
[Unit]
Description=OpenSSH Server Socket
Conflicts=sshd.service

[Socket]
ListenStream=22
Accept=yes

[Install]
WantedBy=sockets.target
SSHD_SOCKET
    # Create sshd@.service - per-connection sshd instance (template)
    sudo tee "${root_fs_dir}/usr/lib/systemd/system/sshd@.service" > /dev/null <<'SSHD_AT_SERVICE'
[Unit]
Description=OpenSSH per-connection server daemon

[Service]
ExecStart=-/usr/sbin/sshd -i -e
StandardInput=socket
StandardError=journal
SSHD_AT_SERVICE
    # Add drop-in to ensure host keys are generated before accepting connections
    sudo mkdir -p "${root_fs_dir}/usr/lib/systemd/system/sshd@.service.d"
    sudo tee "${root_fs_dir}/usr/lib/systemd/system/sshd@.service.d/sshd-keygen.conf" > /dev/null <<'SSHD_KEYGEN_DROPIN'
[Unit]
Wants=sshd-keygen.service
After=sshd-keygen.service
SSHD_KEYGEN_DROPIN
    # Disable traditional sshd.service, enable sshd.socket instead
    printf "disable sshd.service\nenable sshd.socket\n" | \
    sudo tee "${root_fs_dir}/usr/lib/systemd/system-preset/50-acl-sshd.preset" > /dev/null
    # Remove any existing sshd.service enable symlinks from the RPM
    sudo rm -f "${root_fs_dir}/etc/systemd/system/multi-user.target.wants/sshd.service"
    sudo rm -f "${root_fs_dir}/usr/lib/systemd/system/multi-user.target.wants/sshd.service"

    # Remove extend-filesystems - uses cgpt (not available in Azure Linux) and
    # the coreos-resize GPT partition type which ACL does not use
    info "RPM mode: Removing extend-filesystems (requires cgpt, not available)"
    sudo rm -f "${root_fs_dir}/usr/lib/flatcar/extend-filesystems"
    sudo rm -f "${root_fs_dir}/usr/lib/systemd/system/extend-filesystems.service"
    sudo rm -f "${root_fs_dir}/usr/lib/systemd/system/multi-user.target.wants/extend-filesystems.service"

    # Note: /etc/issue cleanup was moved to finish_image_rpm() to run before systemd-tmpfiles --create

    # Remove flatcar-setup-environment.service - requires /oem/bin/flatcar-setup-environment
    # which is an OEM-specific script that ACL does not provide. Also strip references
    # from any dependent units (system-config.target, user-cloudinit, user-config*, etc.)
    info "RPM mode: Removing flatcar-setup-environment.service (no OEM script)"
    sudo rm -f "${root_fs_dir}/usr/lib/systemd/system/flatcar-setup-environment.service"
    # Strip Requires= and After= references from units that depend on it
    for unit_file in \
        "${root_fs_dir}/usr/lib/systemd/system/system-config.target" \
        "${root_fs_dir}/usr/lib/systemd/system/user-cloudinit@.service" \
        "${root_fs_dir}/usr/lib/systemd/system/user-cloudinit-proc-cmdline.service" \
        "${root_fs_dir}/usr/lib/systemd/system/user-configdrive.service" \
        "${root_fs_dir}/usr/lib/systemd/system/user-configvirtfs.service" \
        "${root_fs_dir}/usr/lib/systemd/system/user-config-ovfenv.service"; do
        if [[ -f "${unit_file}" ]]; then
            sudo sed -i '/flatcar-setup-environment\.service/d' "${unit_file}"
        fi
    done

    # Remove dead links
    sudo rm -f "${root_fs_dir}/usr/lib/systemd/system/sysinit.target.wants/ignition-delete-config.service"

    # Remove the /var/log/README symlink rule from legacy.conf — the target
    # (/usr/share/doc/systemd/README.logs) doesn't exist because Azure Linux
    # builds systemd with create-log-dirs disabled. A build-time rm is not
    # enough because systemd-tmpfiles recreates the symlink at every boot.
    sudo sed -i '\|/var/log/README|d' "${root_fs_dir}/usr/lib/tmpfiles.d/legacy.conf"

    # Enable systemd-repart + systemd-growfs for rootfs auto-grow
    # The ROOT partition uses the DPS (Discoverable Partitions Spec) root type GUID,
    # resolved at build time by disk_util from the "dps-root" placeholder in disk_layout.json
    # (x86-64: 4F68BCE3-..., aarch64: B921B045-...).
    # systemd-repart grows the partition to fill available disk space,
    # then systemd-growfs-root grows the ext4 filesystem to match.
    info "RPM mode: Enabling systemd-repart and systemd-growfs for rootfs auto-grow"

    # Create repart.d config to grow the ROOT partition
    sudo mkdir -p "${root_fs_dir}/usr/lib/repart.d"
    sudo tee "${root_fs_dir}/usr/lib/repart.d/10-root.conf" > /dev/null <<'REPART_EOF'
[Partition]
Type=root
Label=ROOT
GrowFileSystem=no
REPART_EOF

    # Enable systemd-repart.service (grows partition at boot)
    sudo mkdir -p "${root_fs_dir}/usr/lib/systemd/system/sysinit.target.wants"
    sudo ln -sf ../systemd-repart.service "${root_fs_dir}/usr/lib/systemd/system/sysinit.target.wants/systemd-repart.service"

    # Drop-in for systemd-repart.service: make partition growth best-effort.
    # Use "-" prefix on ExecStart so any failure is non-fatal.  This handles:
    #   - RAID/LVM roots where repart can't resolve / to a single GPT disk (exit 76)
    #   - No GPT partition table found (exit 77)
    #   - Not enough free space to grow the partition (exit 1, e.g. RAID0 tests)
    # Root partition growth is opportunistic — if there's space, grow; if not, boot anyway.
    sudo mkdir -p "${root_fs_dir}/usr/lib/systemd/system/systemd-repart.service.d"
    cat <<'EOF' | sudo tee "${root_fs_dir}/usr/lib/systemd/system/systemd-repart.service.d/10-best-effort.conf" > /dev/null
[Service]
ExecStart=
ExecStart=-/usr/bin/systemd-repart --dry-run=no
EOF

    # Enable systemd-growfs-root.service (grows filesystem after partition resize)
    sudo ln -sf ../systemd-growfs-root.service "${root_fs_dir}/usr/lib/systemd/system/sysinit.target.wants/systemd-growfs-root.service"

    # Mask kdump.service - requires crashkernel= kernel parameter which we don't set
    info "RPM mode: Masking kdump.service (no crash kernel memory reserved)"
    sudo ln -sf /dev/null "${root_fs_dir}/usr/lib/systemd/system/kdump.service"

    # Mask iSCSI services and sockets - not needed for ACL and cause boot failures
    # These were pulled in as Azure Linux RPM dependencies
    info "RPM mode: Masking iSCSI services and sockets"
    sudo ln -sf /dev/null "${root_fs_dir}/etc/systemd/system/iscsi-init.service"
    sudo ln -sf /dev/null "${root_fs_dir}/etc/systemd/system/iscsid.service"
    sudo ln -sf /dev/null "${root_fs_dir}/etc/systemd/system/iscsiuio.service"
    sudo ln -sf /dev/null "${root_fs_dir}/etc/systemd/system/iscsi.service"
    sudo ln -sf /dev/null "${root_fs_dir}/etc/systemd/system/iscsid.socket"
    sudo ln -sf /dev/null "${root_fs_dir}/etc/systemd/system/iscsiuio.socket"

    # Mask nftables.service - missing /etc/sysconfig/nftables.conf config file
    info "RPM mode: Masking nftables.service"
    sudo ln -sf /dev/null "${root_fs_dir}/etc/systemd/system/nftables.service"

    # Remove etcd server and etcdutl binaries - we only need etcdctl from the etcd RPM.
    # The etcd server runs inside a Docker container via etcd-wrapper, not natively.
    if [[ -f "${root_fs_dir}/usr/bin/etcd" ]]; then
        info "RPM mode: Removing /usr/bin/etcd (etcd server runs in Docker via etcd-wrapper)"
        sudo rm -f "${root_fs_dir}/usr/bin/etcd"
    fi
    if [[ -f "${root_fs_dir}/usr/bin/etcdutl" ]]; then
        info "RPM mode: Removing /usr/bin/etcdutl (not needed)"
        sudo rm -f "${root_fs_dir}/usr/bin/etcdutl"
    fi
    # Also remove the native etcd.service - etcd-member.service (Docker-based) is used instead
    if [[ -f "${root_fs_dir}/usr/lib/systemd/system/etcd.service" ]]; then
        info "RPM mode: Removing native etcd.service (using etcd-member.service instead)"
        sudo rm -f "${root_fs_dir}/usr/lib/systemd/system/etcd.service"
    fi
    # Remove the etcd preset file (refers to the native etcd.service we just removed)
    sudo rm -f "${root_fs_dir}/usr/lib/systemd/system-preset/50-etcd.preset"
    # Remove etcd config file (native etcd.service config, not used with etcd-wrapper)
    sudo rm -f "${root_fs_dir}/etc/etcd/etcd-default-conf.yml"

    # Disable etcd-member.service by default via preset.
    # It should only start when explicitly enabled via CLC/Ignition (etcd: section).
    # Without this, systemd-firstboot preset-all enables it because no preset matches,
    # causing crashes on systems without Docker (e.g. sysext.disable-containerd test).
    echo "disable etcd-member.service" | sudo tee "${root_fs_dir}/usr/lib/systemd/system-preset/50-etcd-member.preset" > /dev/null

    # Install etcd-wrapper - runs etcd in a Docker container with sdnotify-proxy.
    # These files come from the Flatcar etcd-wrapper package in sdk_container.
    local etcd_wrapper_src="${BUILD_LIBRARY_DIR}/../sdk_container/src/third_party/coreos-overlay/app-admin/etcd-wrapper/files"
    local etcd_version="3.5.16"
    if [[ ! -d "${etcd_wrapper_src}" ]]; then
        die "etcd-wrapper source not found at ${etcd_wrapper_src}"
    fi
    info "RPM mode: Installing etcd-wrapper from sdk_container sources"
    # etcd-wrapper script -> /usr/lib/flatcar/etcd-wrapper
    sudo mkdir -p "${root_fs_dir}/usr/lib/flatcar"
    sudo cp "${etcd_wrapper_src}/etcd-wrapper" "${root_fs_dir}/usr/lib/flatcar/etcd-wrapper"
    sudo chmod 0755 "${root_fs_dir}/usr/lib/flatcar/etcd-wrapper"
    # CLC transpiler generates ExecStart=/usr/lib/coreos/etcd-wrapper
    # Create compat symlink so /usr/lib/coreos -> flatcar resolves
    sudo ln -sfT flatcar "${root_fs_dir}/usr/lib/coreos"
    # Additional coreos -> flatcar compat symlinks expected by tests and tooling
    sudo ln -sfT flatcar "${root_fs_dir}/etc/coreos"
    sudo ln -sfT flatcar "${root_fs_dir}/usr/share/coreos"
    # etcd-member.service -> /usr/lib/systemd/system/ (substitute image tag)
    sudo sed "s|@ETCD_IMAGE_TAG@|v${etcd_version}|g" \
        "${etcd_wrapper_src}/etcd-member.service" \
        | sudo tee "${root_fs_dir}/usr/lib/systemd/system/etcd-member.service" > /dev/null
    # etcd-wrapper.conf -> /usr/lib/tmpfiles.d/ (creates /var/lib/etcd 0700 etcd:etcd)
    sudo cp "${etcd_wrapper_src}/etcd-wrapper.conf" "${root_fs_dir}/usr/lib/tmpfiles.d/etcd-wrapper.conf"
    # sysusers.d config to create the etcd user/group (needed by etcd-wrapper)
    # The etcd RPM doesn't create this user, but etcd-wrapper needs it for:
    #   - chown etcd:etcd on the data directory
    #   - id -u/-g to map the user into the Docker container
    cat <<'SYSUSERS_EOF' | sudo tee "${root_fs_dir}/usr/lib/sysusers.d/etcd.conf" > /dev/null
u etcd - "etcd user" /var/lib/etcd
SYSUSERS_EOF

    # CA certificates compatibility for etcd-wrapper Docker mount.
    # etcd-wrapper bind-mounts /usr/share/ca-certificates:/usr/share/ca-certificates:ro
    # into the Docker container. On ACL this directory doesn't exist, and Docker
    # tries to mkdir it on the read-only /usr partition, causing the container to
    # fail with "mkdir /usr/share/ca-certificates: read-only file system".
    # Fix: create the directory in the image with a symlink to the ACL CA bundle.
    # (The other mount, ETCD_SSL_DIR=/etc/ssl/certs, already works because ACL
    # has /etc/ssl/certs -> /etc/pki/tls/certs symlink.)
    info "RPM mode: Creating /usr/share/ca-certificates for etcd-wrapper Docker mount"
    sudo mkdir -p "${root_fs_dir}/usr/share/ca-certificates"
    sudo ln -sf /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem \
        "${root_fs_dir}/usr/share/ca-certificates/ca-certificates.crt"

    # Install flannel-wrapper - runs flanneld in a Docker container (like etcd-wrapper).
    # These files come from the Flatcar flannel-wrapper package in sdk_container.
    local flannel_wrapper_src="${BUILD_LIBRARY_DIR}/../sdk_container/src/third_party/coreos-overlay/app-admin/flannel-wrapper/files"
    local flannel_version="0.14.0"
    if [[ ! -d "${flannel_wrapper_src}" ]]; then
        die "flannel-wrapper source not found at ${flannel_wrapper_src}"
    fi
    info "RPM mode: Installing flannel-wrapper from sdk_container sources"
    # flannel-wrapper script -> /usr/lib/flatcar/flannel-wrapper
    # (resolves via /usr/lib/coreos -> flatcar symlink created above)
    sudo cp "${flannel_wrapper_src}/flannel-wrapper" "${root_fs_dir}/usr/lib/flatcar/flannel-wrapper"
    sudo chmod 0755 "${root_fs_dir}/usr/lib/flatcar/flannel-wrapper"
    # flanneld.service -> /usr/lib/systemd/system/ (substitute image tag)
    sudo sed "s|@FLANNEL_IMAGE_TAG@|v${flannel_version}|g" \
        "${flannel_wrapper_src}/flanneld.service" \
        | sudo tee "${root_fs_dir}/usr/lib/systemd/system/flanneld.service" > /dev/null
    # flannel-docker-opts.service -> /usr/lib/systemd/system/ (substitute image tag)
    sudo sed "s|@FLANNEL_IMAGE_TAG@|v${flannel_version}|g" \
        "${flannel_wrapper_src}/flannel-docker-opts.service" \
        | sudo tee "${root_fs_dir}/usr/lib/systemd/system/flannel-docker-opts.service" > /dev/null
    # networkd configs for flannel interfaces
    sudo cp "${flannel_wrapper_src}/50-flannel.network" "${root_fs_dir}/usr/lib/systemd/network/50-flannel.network"
    sudo cp "${flannel_wrapper_src}/50-flannel.link" "${root_fs_dir}/usr/lib/systemd/network/50-flannel.link"

    # Disable flanneld.service and flannel-docker-opts.service by default via preset.
    # They should only start when explicitly enabled via CLC/Ignition (flannel section).
    # Without this, systemd-firstboot preset-all enables them because no preset matches.
    echo "disable flanneld.service" | sudo tee "${root_fs_dir}/usr/lib/systemd/system-preset/50-flannel.preset" > /dev/null
    echo "disable flannel-docker-opts.service" | sudo tee -a "${root_fs_dir}/usr/lib/systemd/system-preset/50-flannel.preset" > /dev/null

    # Placeholder audit-rules.service - Azure Linux doesn't provide this but kola tests expect it as a common dependency
    if [[ ! -f "${root_fs_dir}/usr/lib/systemd/system/audit-rules.service" ]]; then
        info "RPM mode: Installing placeholder audit-rules.service"
        sudo cp "${BUILD_LIBRARY_DIR}/rpm/additional_files/audit-rules.service" "${root_fs_dir}/usr/lib/systemd/system/audit-rules.service"
    fi

    # Create tmpfiles.d entry for logrotate state directory.
    # The Azure Linux 3 logrotate RPM doesn't ship a tmpfiles.d drop-in,
    # so /var/lib/logrotate is not recreated at boot on ACL's immutable rootfs.
    echo 'd /var/lib/logrotate 0755 root root -' | sudo tee "${root_fs_dir}/usr/lib/tmpfiles.d/logrotate.conf" > /dev/null

    # Create /etc/resolv.conf symlink to point to systemd-resolved
    info "RPM mode: Configuring /etc/resolv.conf for systemd-resolved"
    sudo rm -f "${root_fs_dir}/etc/resolv.conf"
    sudo ln -sf /run/systemd/resolve/stub-resolv.conf "${root_fs_dir}/etc/resolv.conf"

    # Create /etc/fstab with /boot and /oem mount points
    # Using Type=auto for /oem allows Ignition to reformat it to different filesystems
    info "RPM mode: Creating /etc/fstab with /boot and /oem mount points"
    sudo tee "${root_fs_dir}/etc/fstab" > /dev/null <<'FSTAB_EOF'
# /etc/fstab: static file system information
# <device>      <mount point>   <type>  <options>       <dump>  <pass>
LABEL=EFI-SYSTEM /boot          vfat    umask=077       0       2
LABEL=OEM        /oem           auto    nodev           0       2
FSTAB_EOF
    sudo chmod 644 "${root_fs_dir}/etc/fstab"

    # Enable serial-getty on ttyS0 (autologin is controlled by generator based on cmdline)
    sudo mkdir -p "${root_fs_dir}/usr/lib/systemd/system/getty.target.wants"
    sudo ln -sf ../serial-getty@.service "${root_fs_dir}/usr/lib/systemd/system/getty.target.wants/serial-getty@ttyS0.service"

    # Remove ImportCredential= from getty services (credentials directory doesn't exist)
    info "RPM mode: Removing ImportCredential from getty services"
    sudo sed -i '/ImportCredential=/d' "${root_fs_dir}/usr/lib/systemd/system/getty@.service" 2>/dev/null || true
    sudo sed -i '/ImportCredential=/d' "${root_fs_dir}/usr/lib/systemd/system/serial-getty@.service" 2>/dev/null || true

    # Create /etc/profile.d directory for additional scripts
    info "RPM mode: Creating profile.d directory"
    sudo mkdir -p "${root_fs_dir}/etc/profile.d"

    # Ensure /root home directory exists with proper permissions
    sudo mkdir -p "${root_fs_dir}/root"
    sudo chmod 700 "${root_fs_dir}/root"
}

finish_image_backup_etc_rpm() {
    local root_fs_dir="$1"
    local FLATCAR_SHARE="${root_fs_dir}/usr/share/flatcar"
    local ETC_FULL_PATH="${FLATCAR_SHARE}/etc"

    # Bulk-copy all of /etc to /usr/share/flatcar/etc.
    # This is the overlay lowerdir — at boot, /etc is a tmpfs overlay
    # whose lower layer is this directory.  Mirrors the Portage-mode
    # "sudo cp -a /etc /usr/share/flatcar/etc" in build_image_util.sh.
    info "RPM mode: Copying /etc to ${ETC_FULL_PATH} for overlay lowerdir"
    sudo rm -rf "${ETC_FULL_PATH}"
    sudo cp -a "${root_fs_dir}/etc" "${ETC_FULL_PATH}"

    # Create etc-no-whiteouts file required by bootengine's initrd-setup-root
    # This file lists /etc paths that should not be treated as overlay whiteouts
    # (character devices with major:minor 0:0 that represent deletions)
    # For now, create an empty file - Azure Linux doesn't have pre-existing whiteouts
    info "RPM mode: Creating etc-no-whiteouts for bootengine compatibility"
    sudo mkdir -p "${FLATCAR_SHARE}"
    sudo touch "${FLATCAR_SHARE}/etc-no-whiteouts"

    # NOTE: flatcar-tmpfiles is created earlier in finish_image_rpm() before dracut runs
    # so it gets included in the initramfs
  
    # IMPORTANT: For first-boot detection with bootengine's /etc overlay:
    # - The rootfs upperdir (/etc) should NOT contain machine-id - it will be deleted with the rest of /etc
    # - The lowerdir (/usr/share/flatcar/etc) must NOT have machine-id either
    # After overlay mount, no /etc/machine-id exists, so systemd triggers first-boot logic.
    # bootengine's initrd-setup-root handles both cases:
    # 1. If machine-id exists with COREOS_BLANK_MACHINE_ID placeholder -> removes it
    # 2. If machine-id doesn't exist -> that's fine, no action needed
    # Either way, after overlay mount systemd sees no /etc/machine-id and first boot is detected.
    info "Removing machine-id from /usr/share/flatcar/etc (overlay lowerdir) for first-boot detection"
    sudo rm -f "${FLATCAR_SHARE}/etc/machine-id"
}

# Escape a string for JSON - handles quotes, backslashes, and control characters
json_escape() {
    local str="$1"
    # Remove control characters (except newline which we'll handle)
    str=$(echo "$str" | tr -d '\000-\011\013-\037')
    # Escape backslashes first, then quotes, then convert newlines
    str=$(echo "$str" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
    echo "$str"
}

# Normalize RPM license strings to Portage license file names
# RPM uses SPDX expressions like "GPL-2.0-or-later AND MIT" or "GPLv2+ or LGPLv2+"
# This function extracts individual license names and maps them to Portage equivalents
normalize_rpm_license() {
    local lic="$1"
    
    # Replace SPDX operators with spaces (use word boundaries via spaces)
    # Handle: " AND ", " OR ", " WITH ", " and ", " or ", " with "
    local normalized
    normalized=$(echo " $lic " | \
        sed -e 's/ AND / /g' \
            -e 's/ OR / /g' \
            -e 's/ WITH / /g' \
            -e 's/ and / /g' \
            -e 's/ or / /g' \
            -e 's/ with / /g' \
            -e 's/[(),]/ /g' \
            -e 's/  */ /g' \
            -e 's/^ *//' \
            -e 's/ *$//')
    
    # Map common RPM/SPDX license names to Portage license file names
    local result=""
    for l in $normalized; do
        local mapped="$l"
        case "$l" in
            # Skip version numbers, fragments, and empty strings
            [0-9]*|""|2-Clause|3-Clause) continue ;;
            # SPDX to Portage mappings - GPL family
            GPL-2.0-only|GPL-2.0) mapped="GPL-2" ;;
            GPL-2.0-or-later|GPL-2.0+) mapped="GPL-2+" ;;
            GPL-3.0-only|GPL-3.0) mapped="GPL-3" ;;
            GPL-3.0-or-later|GPL-3.0+) mapped="GPL-3+" ;;
            GPLv2) mapped="GPL-2" ;;
            GPLv2+) mapped="GPL-2+" ;;
            GPLv3) mapped="GPL-3" ;;
            GPLv3+) mapped="GPL-3+" ;;
            GPL+) mapped="GPL-2+" ;;
            GPL2) mapped="GPL-2" ;;
            # LGPL family
            LGPL-2.0-only|LGPL-2.0) mapped="LGPL-2" ;;
            LGPL-2.0-or-later|LGPL-2.0+) mapped="LGPL-2+" ;;
            LGPL-2.1-only|LGPL-2.1) mapped="LGPL-2.1" ;;
            LGPL-2.1-or-later|LGPL-2.1+) mapped="LGPL-2.1+" ;;
            LGPL-3.0-only|LGPL-3.0) mapped="LGPL-3" ;;
            LGPL-3.0-or-later|LGPL-3.0+) mapped="LGPL-3+" ;;
            LGPLv2) mapped="LGPL-2" ;;
            LGPLv2+) mapped="LGPL-2+" ;;
            LGPLv2.1) mapped="LGPL-2.1" ;;
            LGPLv2.1+) mapped="LGPL-2.1+" ;;
            LGPLv3) mapped="LGPL-3" ;;
            LGPLv3+) mapped="LGPL-3+" ;;
            # Apache
            Apache-2.0|Apache-2.0\)) mapped="Apache-2.0" ;;
            ASL|ASL2.0) mapped="Apache-2.0" ;;
            # BSD family
            BSD) mapped="BSD" ;;
            BSD-2-Clause) mapped="BSD-2" ;;
            BSD-3-Clause|BSD-3) mapped="BSD" ;;
            BSD-4-Clause) mapped="BSD-4" ;;
            # MIT and similar
            MIT|MIT\)|MIT-CMU) mapped="MIT" ;;
            X11|XFree86) mapped="MIT" ;;
            # Mozilla
            MPL-2.0|MPL-2.0\)|MPLv2.0) mapped="MPL-2.0" ;;
            # Other common licenses
            ISC) mapped="ISC" ;;
            Zlib|Zlib\)|zlib) mapped="ZLIB" ;;
            PSF|PSF-2.0) mapped="PSF-2" ;;
            Artistic|Artistic\)|Artistic-1.0) mapped="Artistic" ;;
            Artistic-2.0) mapped="Artistic-2" ;;
            CC0|CC0-1.0) mapped="CC0-1.0" ;;
            CC-BY-3.0) mapped="CC-BY-3.0" ;;
            CC-BY-4.0|CC-BY) mapped="CC-BY-SA-3.0" ;;
            GFDL-1.3-or-later) mapped="FDL-1.3+" ;;
            GFDL-1.3-no-invariants-or-later) mapped="FDL-1.3+" ;;
            BSL-1.0|BSL-1.0\)) mapped="Boost-1.0" ;;
            Unlicense|Unlicense\)) mapped="public-domain" ;;
            OpenSSL|OpenSSL\)) mapped="openssl" ;;
            OpenLDAP) mapped="OPENLDAP" ;;
            curl) mapped="curl" ;;
            Vim) mapped="vim" ;;
            Inner-Net) mapped="inner-net" ;;
            # Public domain variations
            Public|Domain|public|domain) mapped="public-domain" ;;
            LicenseRef-Fedora-Public-Domain) mapped="public-domain" ;;
            # Exceptions and modifiers - skip these
            LLVM-exception|eCos-exception-2.0) continue ;;
            exceptions|modification|permitted|advertising|no|Redistributable|Redistributable,) continue ;;
            # Handle parenthesized versions that sneak through
            \(GPL+|\(GPLv2|\(GPLv2+|\(MIT|\(Apache-2.0|\(LGPLv3+|\(MPL-2.0|\(Unlicense|\(ASL) continue ;;
            GPLv2+\)|LGPLv2+\)|LGPLv3+\)) continue ;;
            GPLv2,) mapped="GPL-2" ;;
            # Licenses that have different names in portage-stable
            AFL) mapped="AFL-2.1" ;;
            Beerware) mapped="BEER-WARE" ;;
            # Licenses that don't have portage equivalents - suppress warnings
            # TTWL, HSRL, Rdisc, UCD are obscure licenses from specific packages
            # Unknown means the package has no specified license
            TTWL|HSRL|Rdisc|UCD|Unknown|Nmap|pubkey) continue ;;
        esac
        if [[ -n "$mapped" ]]; then
            result="$result $mapped"
        fi
    done
    echo "$result"
}
