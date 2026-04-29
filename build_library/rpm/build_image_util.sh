source "${BUILD_LIBRARY_DIR}/rpm/package_catalog.sh" || exit 1
source "${BUILD_LIBRARY_DIR}/rpm/rpm_install.sh" || exit 1
source "${BUILD_LIBRARY_DIR}/rpm/dracut_install.sh" || exit 1

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

    # Install azurelinux-repos and azurelinux-repos-cloud-native to get the official
    # repository definitions and GPG keys shipped by Azure Linux.
    rpm_install_package "${root_fs_dir}" azurelinux-repos azurelinux-repos-cloud-native azurelinux-release || {
        error "Failed to install azurelinux-repos packages"
        return 1
    }

    # Remove the bootstrap repo now that the package-provided repos are in place.
    rpm_use_official_repos "${root_fs_dir}"

    # Create sysusers.d configs and run systemd-sysusers to create users/groups
    # BEFORE any RPM packages are installed, since RPM %pre scriptlets may need them
    start_image_uids_rpm "${root_fs_dir}"

    # Download bootloader packages while /etc/yum.repos.d is still available
    download_bootloader_packages_rpm "${root_fs_dir}"
}

finish_image_rpm() {
  local root_fs_dir="$1"

    # Create /usr/share/oem -> ../../oem symlink for backward compatibility
    # The OEM partition is mounted at /oem, but legacy configs reference /usr/share/oem
    # Use relative symlink (../../oem) so it works correctly when accessed via /sysroot in initrd
    # See: https://github.com/flatcar/bootengine/pull/58
    sudo mkdir -p "${root_fs_dir}/usr/share"
    sudo ln -sfT ../../oem "${root_fs_dir}/usr/share/oem"

    # Preserve compatibility with agents that probe the Ubuntu CA anchor path.
    # /usr is read-only at runtime, so kubelet cannot create this via hostPath
    # DirectoryOrCreate after boot.
    sudo install -d -m 0755 "${root_fs_dir}/usr/local/share/ca-certificates"

    # Remove legacy coreos compat symlinks — ACL uses /usr/share/distro,
    # not /usr/share/flatcar, so these would be dead.
    sudo rm -f "${root_fs_dir}/usr/share/coreos"
    sudo rm -f "${root_fs_dir}/etc/coreos"

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

      # The kernel RPM creates a symlink /usr/lib/modules/<version>/vmlinuz ->
      # /boot/vmlinuz-<version> In UKI mode, uki_install.sh later removes
      # /boot/vmlinuz-* from the ESP (the kernel is embedded in the UKI),
      # leaving a dead symlink that fails the cl.filesystem/deadlinks test.
      # Remove it now while the rootfs is still mounted.
      if [[ "${BOOTLOADER_MODE}" == "uki" ]]; then
          local modules_vmlinuz="${root_fs_dir}/usr/lib/modules/${kernel_version}/vmlinuz"
          if [[ -L "${modules_vmlinuz}" ]]; then
              info "RPM mode: Removing kernel symlink ${modules_vmlinuz} (UKI embeds kernel)"
              sudo rm -f "${modules_vmlinuz}"
          fi

          # Copy it to /usr/lib/modules/<version>/config (on the rootfs) so
          # tools like kubeadm can still find the kernel config at runtime.
          local boot_config="${root_fs_dir}/boot/config-${kernel_version}"
          local modules_config="${root_fs_dir}/usr/lib/modules/${kernel_version}/config"
          if [[ -f "${boot_config}" ]]; then
              info "RPM mode: Copying kernel config to ${modules_config}"
              sudo cp "${boot_config}" "${modules_config}"
          fi
      fi
    else
      die "RPM mode: No kernel found in ${root_fs_dir}/boot/"
    fi

    # Generate an fstab for Image Customizer (IC) partition discovery.
    # IC scans image partitions for an fstab to discover the partition layout.
    #
    # This file is placed at /usr/share/ic/etc/fstab on USR-A, deliberately
    # outside the /etc overlay lowerdir (/usr/share/distro/etc/). This means:
    #   - systemd-fstab-generator never sees it, so no .mount unit conflicts
    #     with existing static units (e.g. oem.mount).
    #   - There is no /etc/fstab visible at runtime (matching Flatcar behavior).
    #   - IC searches for this path during offline partition discovery.
    #
    # /usr uses /dev/mapper/usr so that IC's verity detection recognizes it as a
    # dm-verity device.
    info "RPM mode: Generating /usr/share/ic/etc/fstab for Image Customizer"
    sudo mkdir -p "${root_fs_dir}/usr/share/ic/etc"
    sudo tee "${root_fs_dir}/usr/share/ic/etc/fstab" > /dev/null <<'FSTAB'
# ACL partition table — consumed by Image Customizer for offline customization.
# This file is NOT visible at runtime (/etc/fstab does not exist).
# It lives at /usr/share/ic/etc/fstab on the USR-A partition.
/dev/mapper/usr                                /usr   btrfs  ro,compress=zstd   0  0
LABEL=ROOT                                     /      ext4   rw                 0  1
LABEL=EFI-SYSTEM                               /boot  vfat   rw                 0  2
LABEL=OEM                                      /oem   btrfs  rw,compress=zlib   0  0
FSTAB
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

    # core user - retained for Flatcar/ACL compatibility (UID/GID 500)
    # Phase 1 hardening: core keeps /bin/bash and wheel but is removed from
    # the docker group (docker socket access is root-equivalent; users must
    # 'sudo docker' which is now gated by a password — see sudoers below).
    sudo tee "${root_fs_dir}/usr/lib/sysusers.d/core.conf" > /dev/null <<'SYSUSERS_CORE'
# Core user - primary administrative user
g core 500 -
u core 500:500 "ACL Admin" /home/core /bin/bash
m core wheel
m core systemd-journal
SYSUSERS_CORE

    # Run systemd-sysusers to create users in /etc/passwd and /etc/group
    info "RPM mode: Running systemd-sysusers to create users"
    sudo systemd-sysusers --root="${root_fs_dir}"

    info "RPM mode: Created sysusers.d configs for system users"
}

# Download grub/shim/systemd-boot packages for later use by grub_install.sh and uki_install.sh
# Must be called while /etc/yum.repos.d is still available in the root_fs_dir
download_bootloader_packages_rpm() {
    local root_fs_dir="$1"

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
    #sudo setfiles -Dv -r "${root_fs_dir}" "${file_contexts}" "${root_fs_dir}" >/dev/null
    sudo setfiles -Dv -r "${root_fs_dir}" "${file_contexts}" "${root_fs_dir}/etc" >/dev/null
    #sudo setfiles -Dv -r "${root_fs_dir}" "${file_contexts}" "${root_fs_dir}/usr" >/dev/null
}

# ── Machine-id: remove for first-boot detection ──────────────────────────────
_remove_machine_id_rpm() {
    local root_fs_dir="$1"

    # Remove /etc/machine-id so that the later bulk-copy of /etc to the
    # overlay lowerdir naturally excludes it.  Without machine-id in the
    # lowerdir, systemd sees a missing file after overlay mount and triggers
    # first-boot logic (ConditionFirstBoot=yes, systemd-firstboot, etc.).
    # Nothing between here and the cp -a recreates the file.
    info "RPM mode: Removing /etc/machine-id for first-boot detection"
    sudo rm -f "${root_fs_dir}/etc/machine-id"
}

# ── SSH: config, authorized_keys, socket activation ──────────────────────────
_configure_ssh_rpm() {
    local root_fs_dir="$1"

    # sshd privilege separation directory
    sudo tee "${root_fs_dir}/usr/lib/tmpfiles.d/sshd.conf" > /dev/null <<'TMPFILES_SSHD'
# SSH privilege separation directory
d /var/lib/sshd 0755 root root - -
TMPFILES_SSHD

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

    # Phase 1 hardening: disable SSH password authentication at build time.
    # Closes the window between boot and WALinuxAgent provisioning where
    # PasswordAuthentication defaults to 'yes'. Key-based login is unaffected.
    # Also disable KbdInteractiveAuthentication and ChallengeResponseAuthentication
    # to prevent password-based logins via keyboard-interactive/PAM.
    # Consistent with Flatcar's 80-flatcar-walinuxagent.conf behaviour.
    info "RPM mode: Disabling SSH password authentication"
    sudo tee "${ssh_config_dir}/sshd_config.d/50-acl-no-password-auth.conf" > /dev/null <<'SSHD_NOPASSWD'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
SSHD_NOPASSWD
    sudo chmod 644 "${ssh_config_dir}/sshd_config.d/50-acl-no-password-auth.conf"

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
    # Disable sshd.service (enabled by 90-default.preset) and enable sshd.socket instead
    printf "disable sshd.service\nenable sshd.socket\n" | \
    sudo tee "${root_fs_dir}/usr/lib/systemd/system-preset/50-acl-sshd.preset" > /dev/null
    # Remove any existing sshd.service enable symlinks from the RPM
    sudo rm -f "${root_fs_dir}/etc/systemd/system/multi-user.target.wants/sshd.service"
    sudo rm -f "${root_fs_dir}/usr/lib/systemd/system/multi-user.target.wants/sshd.service"
}

# ── Sudo: Flatcar-compatible sudoers policy ──────────────────────────────────
_configure_sudo_rpm() {
    local root_fs_dir="$1"

    # Configure sudo to match Flatcar's sudoers policy:
    # - wheel group requires password
    # - sudo group gets NOPASSWD (override base sudoers password-required rule)
    # - core user gets explicit NOPASSWD (matches Flatcar's /usr/share/baselayout/sudoers)
    # - LESSCHARSET preserved for systemd commands that call less
    info "RPM mode: Configuring sudoers drop-in for Flatcar parity"
    sudo mkdir -p "${root_fs_dir}/etc/sudoers.d"
    sudo tee "${root_fs_dir}/etc/sudoers.d/flatcar-compat" > /dev/null <<'SUDOERS_EOF'
## Flatcar-compatible sudo policy for ACL
## See: https://github.com/flatcar/baselayout/blob/dda76ffe75112a6e9150c925e4d969950d048711/share/baselayout/sudoers

## Pass LESSCHARSET through for systemd commands run through sudo that call less.
Defaults env_keep += "LESSCHARSET"

## enable passwordless access for sudo group
%sudo ALL=(ALL) NOPASSWD: ALL

## core can sudo but requires a password (none is set by default,
## so sudo is effectively blocked unless a password is provisioned
## via Ignition or WALinuxAgent). The Azure-provisioned admin user
## gets its own NOPASSWD entry and is unaffected.
core ALL=(ALL) ALL
SUDOERS_EOF
    sudo chmod 440 "${root_fs_dir}/etc/sudoers.d/flatcar-compat"
}

# ── NTP / NFS / RPC service fixes ────────────────────────────────────────────
_fix_ntp_nfs_services_rpm() {
    local root_fs_dir="$1"

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

    # Re-enable systemd-timesyncd.service via direct symlink.
    # azurelinux-release's 90-default.preset explicitly disables systemd-timesyncd,
    # but the linux.ntp and acl.basic/ServicesActive tests expect timesyncd to be active.
    info "RPM mode: Re-enabling systemd-timesyncd.service"
    sudo mkdir -p "${root_fs_dir}/usr/lib/systemd/system/sysinit.target.wants"
    sudo ln -sf ../systemd-timesyncd.service "${root_fs_dir}/usr/lib/systemd/system/sysinit.target.wants/systemd-timesyncd.service"

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
}

# ── Generate hwdb.bin in /usr/lib/udev during image build ───────────────────────────────
_generate_hwdb_rpm() {
    local root_fs_dir="$1"

    # Generating hwdb.bin in /usr/lib/udev during image build.
    # During image build, post install scripts in systemd-udevd package generates
    # /etc/udev/hwdb.bin.
    # When systemd detects that /etc needs to be updated for ex during first boot, systemd-hwdb-update
    # service runs and regenerates this binary hardware db in /etc/udev itself.
    # Regenerating this file during image build, we are
    # - making the hwdb db immutable, since it lies in /usr
    # - avoids situations when systemd-hwdb-update service can fail due to low space on medium backing
    #   the writeable /etc upper dir in overlayfs (for ex service runs before systemd has performed the resize)
    if [ -d "${root_fs_dir}/usr/lib/udev/hwdb.d" ]; then
        info "RPM mode: generating hwdb.bin in /usr"
        if [ -f "${root_fs_dir}/usr/bin/systemd-hwdb" ]; then
            info "RPM mode: /usr/bin/systemd-hwdb is present, running update"
            local -a build_args
            if [[ "${BOARD}" == "arm64-usr" ]]; then
                build_args+=(QEMU_LD_PREFIX="${root_fs_dir}")
            else
                build_args+=("${root_fs_dir}/usr/lib/ld-linux-x86-64.so.2" \
                                "--library-path" "${root_fs_dir}/usr/lib/systemd:${root_fs_dir}/usr/lib")
            fi
            if sudo "${build_args[@]}" "${root_fs_dir}/usr/bin/systemd-hwdb" --usr --root="${root_fs_dir}" update; then
                if [ -f "${root_fs_dir}/etc/udev/hwdb.bin" ]; then
                    info "RPM mode: removing /etc/udev/hwdb.bin"
                    sudo rm -f "${root_fs_dir}/etc/udev/hwdb.bin"
                fi
            else
                error "RPM mode: Failed to generate hwdb.bin in /usr"
            fi
        fi
    fi
}

# ── Remove Flatcar components not used by ACL ────────────────────────────────
_remove_unused_flatcar_components_rpm() {
    local root_fs_dir="$1"

    # Remove extend-filesystems - uses cgpt (not available in Azure Linux) and
    # the coreos-resize GPT partition type which ACL does not use
    info "RPM mode: Removing extend-filesystems (requires cgpt, not available)"
    sudo rm -f "${root_fs_dir}/usr/lib/flatcar/extend-filesystems"
    sudo rm -f "${root_fs_dir}/usr/lib/systemd/system/extend-filesystems.service"
    sudo rm -f "${root_fs_dir}/usr/lib/systemd/system/multi-user.target.wants/extend-filesystems.service"

    # Remove flatcar-update/flatcar-install - ACL uses a different update mechanism
    info "RPM mode: Removing flatcar-update, flatcar-install, and flatcar-reset (not used by ACL)"
    sudo rm -f "${root_fs_dir}/usr/lib/tmpfiles.d/flatcar-update.conf"
    sudo rm -f "${root_fs_dir}/usr/bin/flatcar-update"
    sudo rm -f "${root_fs_dir}/usr/bin/flatcar-install"
    sudo rm -f "${root_fs_dir}/usr/bin/coreos-install"
    sudo rm -f "${root_fs_dir}/etc/flatcar/update.conf"
    # removing flatcar-reset for GA, let's revisit whether we want to support this on ACL
    sudo rm -f "${root_fs_dir}/usr/bin/flatcar-reset"

    # Remove motdgen - watches /etc/flatcar/update.conf
    info "RPM mode: Removing motdgen (depends on flatcar update.conf)"
    sudo rm -f "${root_fs_dir}/usr/lib/flatcar/motdgen"
    sudo rm -f "${root_fs_dir}/usr/lib/systemd/system/motdgen.path"
    sudo rm -f "${root_fs_dir}/usr/lib/systemd/system/motdgen.service"
    sudo rm -f "${root_fs_dir}/usr/lib/systemd/system/multi-user.target.wants/motdgen.path"
    sudo rm -f "${root_fs_dir}/usr/lib/systemd/system/multi-user.target.wants/motdgen.service"

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
}

# ── Disk auto-grow: systemd-repart + growfs ──────────────────────────────────
_configure_disk_autogrow_rpm() {
    local root_fs_dir="$1"

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
}

# ── Remove systemd components not built by Flatcar ──────────────────────────
_remove_unused_systemd_components_rpm() {
    local root_fs_dir="$1"

    # Remove systemd-homed — Flatcar does not build these (USE flag "homed" is
    # off). Remove the service units, daemons, CLI tool, and PAM module shipped
    # by the Azure Linux systemd-udev RPM to stay in parity.
    info "RPM mode: Removing systemd-homed (not built by Flatcar)"
    # /usr/lib64 -> lib, so only /usr/lib paths are needed.
    sudo rm -f "${root_fs_dir}/usr/lib/systemd/system/systemd-homed.service"
    sudo rm -f "${root_fs_dir}/usr/lib/systemd/system/systemd-homed-activate.service"
    sudo rm -f "${root_fs_dir}/usr/lib/systemd/systemd-homed"
    sudo rm -f "${root_fs_dir}/usr/lib/systemd/systemd-homework"
    sudo rm -f "${root_fs_dir}/usr/bin/homectl"
    sudo rm -f "${root_fs_dir}/usr/lib/security/pam_systemd_home.so"
    
    # Also clean up /etc symlinks left by RPM presets — dangling links here
    # cause "Link has been severed" and abort the entire preset population,
    # which prevents sshd.socket (and others) from being enabled at first boot.
    sudo rm -f "${root_fs_dir}/etc/systemd/system/multi-user.target.wants/systemd-homed.service"
    sudo rm -f "${root_fs_dir}/etc/systemd/system/dbus-org.freedesktop.home1.service"
    sudo rm -rf "${root_fs_dir}/etc/systemd/system/systemd-homed.service.wants"

    # Remove systemd-boot-update.service — Flatcar does not build this on the
    # target image (USE flag "boot" is SDK-only). Keep bootctl binary (useful
    # for inspecting the ESP).
    info "RPM mode: Removing systemd-boot-update.service (not built by Flatcar)"
    sudo rm -f "${root_fs_dir}/usr/lib/systemd/system/systemd-boot-update.service"

    # Removing packet-phone-home.service. This service is NOT needed for ACL images.
    # Reference: https://github.com/flatcar/init/pull/107 Needed for packet/equinix instances.
    # For now, this is the ONLY service which pulls in coreos-metadata.service as dependency,
    # and thus coreos-metadata (default disabled, even via preset) runs in every boot.
    # The packet-phone-home service itself does not run due to unmet conditions (not packet instance/not first boot)
    if [ -f "${root_fs_dir}/usr/lib/systemd/system/packet-phone-home.service" ]; then
        info "RPM mode: Removing packet-phone-home.service (not needed for ACL)"
        sudo rm -f "${root_fs_dir}/usr/lib/systemd/system/packet-phone-home.service"
        for target in "${root_fs_dir}/usr/lib/systemd/system" "${root_fs_dir}/etc/systemd/system"; do
            sudo find "${target}" -type l -name "packet-phone-home.service" -exec rm -f {} \;
        done
    fi
}

# ── PCRlock: Secure Boot condition + arm64 SHA-256 restriction ───────────────
_configure_pcrlock_rpm() {
    local root_fs_dir="$1"

    # Add drop-in for systemd-pcrlock-secureboot-policy.service to skip cleanly
    # when Secure Boot is not available. The upstream unit only gates on
    # ConditionSecurity=measured-uki but lock-secureboot-policy reads the
    # SecureBoot EFI variable and fails with exit-code 1 when it is absent. The
    # drop-in makes this a clean condition skip instead of a hard failure.
    local sb_dropin_dir="${root_fs_dir}/etc/systemd/system/systemd-pcrlock-secureboot-policy.service.d"
    info "RPM mode: Adding Secure Boot condition to pcrlock-secureboot-policy"
    sudo install -d -m 0755 "${sb_dropin_dir}"
    printf '[Unit]\nConditionPathExists=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c\n' \
        | sudo tee "${sb_dropin_dir}/condition-secureboot.conf" > /dev/null
    sudo chmod 0644 "${sb_dropin_dir}/condition-secureboot.conf"

    # Restrict pcrlock to SHA-256 only on arm64. Azure's arm64 vTPM allocates
    # only sha256 PCR banks, but the firmware event log still contains sha1 and
    # sha384 digest entries. systemd-pcrlock discovers all three algorithms from
    # the event log, tries to replay them all against the TPM, and fails.
    if [[ "${BOARD}" == "arm64-usr" ]]; then
        local pcrlock_services=(
            systemd-pcrlock-firmware-code.service
            systemd-pcrlock-firmware-config.service
            systemd-pcrlock-make-policy.service
            systemd-pcrlock-secureboot-authority.service
            systemd-pcrlock-secureboot-policy.service
        )
        info "RPM mode: Restricting pcrlock services to SHA-256 algorithm only (arm64)"
        for svc in "${pcrlock_services[@]}"; do
            local dropin_dir="${root_fs_dir}/etc/systemd/system/${svc}.d"
            sudo install -d -m 0755 "${dropin_dir}"
            printf '[Service]\nEnvironment=SYSTEMD_TPM2_HASH_ALGORITHMS=sha256\n' \
                | sudo tee "${dropin_dir}/sha256-only.conf" > /dev/null
            sudo chmod 0644 "${dropin_dir}/sha256-only.conf"
        done
    fi
}

# ── Misc: kernel modules, resolv.conf, serial console, etc. ─────────────────
_configure_misc_rpm() {
    local root_fs_dir="$1"

    # Remove umask.sh installed by Azure Linux bash RPM to align with upstream Flatcar behavior
    sudo rm -f "${root_fs_dir}/etc/profile.d/umask.sh"

    # Blacklist cfg80211 (wireless) — the Azure Linux kernel ships it as a
    # module but no WiFi hardware exists on cloud/VM targets, and the
    # regulatory.db firmware file is not present.
    sudo install -d -m 0755 "${root_fs_dir}/usr/lib/modprobe.d"
    echo "blacklist cfg80211" | sudo_clobber "${root_fs_dir}/usr/lib/modprobe.d/no-wifi.conf"
    sudo chmod 0644 "${root_fs_dir}/usr/lib/modprobe.d/no-wifi.conf"

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

    # Enable serial-getty (autologin is controlled by generator based on cmdline)
    # arm64 uses ttyAMA0 (PL011 UART), x86_64 uses ttyS0 (8250 UART)
    local serial_tty="ttyS0"
    if [[ "${BOARD}" == "arm64-usr" ]]; then
        serial_tty="ttyAMA0"
    fi
    sudo mkdir -p "${root_fs_dir}/usr/lib/systemd/system/getty.target.wants"
    sudo ln -sf ../serial-getty@.service "${root_fs_dir}/usr/lib/systemd/system/getty.target.wants/serial-getty@${serial_tty}.service"

    # Remove ImportCredential= from getty services (credentials directory doesn't exist)
    info "RPM mode: Removing ImportCredential from getty services"
    sudo sed -i '/ImportCredential=/d' "${root_fs_dir}/usr/lib/systemd/system/getty@.service" 2>/dev/null || true
    sudo sed -i '/ImportCredential=/d' "${root_fs_dir}/usr/lib/systemd/system/serial-getty@.service" 2>/dev/null || true

    # Create /etc/profile.d directory for additional scripts
    sudo mkdir -p "${root_fs_dir}/etc/profile.d"

    # Workaround hanging issue when connecting via SAC/OneSAC serial console.
    # The console-login-helper-messages package's serial-console.sh uses
    # "read -sd" which blocks forever on non-interactive consoles (OneSAC,
    # DCM Explorer, QEMU text-file redirect). Adding a 1s timeout prevents
    # the hang. See AZL Bug 59925731, ACL Bug 18531.
    if [[ -f "${root_fs_dir}/etc/profile.d/serial-console.sh" ]]; then
        info "RPM mode: Fixing serial-console.sh read timeout"
        sudo sed -i 's/read -sd/read -t 1 -sd/g' \
            "${root_fs_dir}/etc/profile.d/serial-console.sh"
    fi

    # Ensure /root home directory exists with proper permissions
    sudo mkdir -p "${root_fs_dir}/root"
    sudo chmod 700 "${root_fs_dir}/root"

    # Disable read-ahead on squashfs-backed loop devices to prevent I/O errors.
    # The kernel's block-layer read-ahead can overshoot the end of
    # loop-backed squashfs files (sysext .raw images), producing:
    #   "I/O error, dev loopN, sector XXXX op 0x0:(READ)"
    # Setting read_ahead_kb=0 on squashfs loop devices avoids the overshoot.
    info "RPM mode: Adding udev rule to disable loop device read-ahead for sysext squashfs"
    sudo mkdir -p "${root_fs_dir}/etc/udev/rules.d"
    sudo tee "${root_fs_dir}/etc/udev/rules.d/60-loop-read-ahead.rules" > /dev/null <<'UDEV_LOOP'
# Prevent I/O errors from read-ahead overshooting loop-backed squashfs files
SUBSYSTEM=="block", KERNEL=="loop*", ENV{ID_FS_TYPE}=="squashfs", ATTR{queue/read_ahead_kb}="0"
UDEV_LOOP
    sudo chmod 644 "${root_fs_dir}/etc/udev/rules.d/60-loop-read-ahead.rules"
}

# ── etcd: remove native server, keep etcdctl, prepare for Docker wrapper ─────
_configure_etcd_rpm() {
    local root_fs_dir="$1"

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

    # sysusers.d config to create the etcd user/group (needed by etcd-wrapper).
    # The etcd RPM doesn't create this user, but etcd-wrapper needs it for:
    #   - chown etcd:etcd on the data directory
    #   - id -u/-g to map the user into the Docker container
    # This MUST be in the rootfs (not the sysext) so systemd-sysusers creates
    # the user before the docker sysext is mounted.
    cat <<'SYSUSERS_EOF' | sudo tee "${root_fs_dir}/usr/lib/sysusers.d/etcd.conf" > /dev/null
u etcd - "etcd user" /var/lib/etcd
SYSUSERS_EOF

    # CLC transpiler generates ExecStart=/usr/lib/coreos/etcd-wrapper
    # Create compat symlink so /usr/lib/coreos -> flatcar resolves
    sudo ln -sfT flatcar "${root_fs_dir}/usr/lib/coreos"

    # etcd-member.service and etcd-wrapper.conf MUST be in the rootfs (not the
    # sysext) because Ignition runs before sysext merge. If the unit file only
    # exists in the sysext, Ignition cannot read its [Install] WantedBy= section
    # to create the multi-user.target.wants symlink, so the service never starts.
    local etcd_wrapper_src="${SCRIPT_ROOT}/sdk_container/src/third_party/coreos-overlay/app-admin/etcd-wrapper/files"
    local etcd_version="3.5.16"
    if [[ ! -d "${etcd_wrapper_src}" ]]; then
        die "etcd-wrapper source not found at ${etcd_wrapper_src}"
    fi
    # etcd-member.service (substitute image tag)
    sed "s|@ETCD_IMAGE_TAG@|v${etcd_version}|g" \
        "${etcd_wrapper_src}/etcd-member.service" \
        | sudo tee "${root_fs_dir}/usr/lib/systemd/system/etcd-member.service" > /dev/null
    # etcd-wrapper.conf -> /usr/lib/tmpfiles.d/ (creates /var/lib/etcd 0700 etcd:etcd)
    sudo cp "${etcd_wrapper_src}/etcd-wrapper.conf" "${root_fs_dir}/usr/lib/tmpfiles.d/etcd-wrapper.conf"
}

# Install flannel service units into the rootfs so Ignition can enable them.
# Same rationale as etcd-member.service above: Ignition runs before sysext
# merge, so it can't read [Install] sections from sysext-only unit files.
# The flannel-wrapper binary stays in the docker sysext (it depends on Docker).
_configure_flannel_services_rpm() {
    local root_fs_dir="$1"

    local flannel_wrapper_src="${SCRIPT_ROOT}/sdk_container/src/third_party/coreos-overlay/app-admin/flannel-wrapper/files"
    local flannel_version="0.14.0"
    if [[ ! -d "${flannel_wrapper_src}" ]]; then
        die "flannel-wrapper source not found at ${flannel_wrapper_src}"
    fi

    info "RPM mode: Installing flannel service units into rootfs (Ignition visibility)"
    # flanneld.service (substitute image tag)
    sed "s|@FLANNEL_IMAGE_TAG@|v${flannel_version}|g" \
        "${flannel_wrapper_src}/flanneld.service" \
        | sudo tee "${root_fs_dir}/usr/lib/systemd/system/flanneld.service" > /dev/null
    # flannel-docker-opts.service (substitute image tag)
    sed "s|@FLANNEL_IMAGE_TAG@|v${flannel_version}|g" \
        "${flannel_wrapper_src}/flannel-docker-opts.service" \
        | sudo tee "${root_fs_dir}/usr/lib/systemd/system/flannel-docker-opts.service" > /dev/null
}

# ── Orchestrator: post-tmpfiles image customization ──────────────────────────
finish_image_post_tmpfiles_rpm() {
    local root_fs_dir="$1"

    _remove_machine_id_rpm "${root_fs_dir}"
    _configure_ssh_rpm "${root_fs_dir}"
    _configure_sudo_rpm "${root_fs_dir}"
    _fix_ntp_nfs_services_rpm "${root_fs_dir}"
    _remove_unused_flatcar_components_rpm "${root_fs_dir}"
    _configure_disk_autogrow_rpm "${root_fs_dir}"
    _remove_unused_systemd_components_rpm "${root_fs_dir}"
    _configure_pcrlock_rpm "${root_fs_dir}"
    _configure_etcd_rpm "${root_fs_dir}"
    _configure_flannel_services_rpm "${root_fs_dir}"
    _configure_misc_rpm "${root_fs_dir}"
    _generate_hwdb_rpm "${root_fs_dir}"
}

finish_image_backup_etc_rpm() {
    local root_fs_dir="$1"
    local DISTRO_SHARE="${root_fs_dir}${DISTRO_SHARE_DIR}"
    local ETC_FULL_PATH="${DISTRO_SHARE}/etc"

    # Uninstall repo definition packages — they are only needed during the
    # build for package installs and bootloader downloads.  Sysext builds
    # use the sysext base squashfs (created before this point) which still
    # contains the repos, so they are unaffected.  Removing these avoids
    # shipping internal build-infra details and trims the image.
    # Flags:
    #   --nodeps  — other packages may have weak dependencies on repos RPMs
    #   --noscripts — skip %preun/%postun scriptlets; the repos-shared
    #     scriptlet tries to run gpg-agent which fails in the chroot
    #     (no /dev/null).  Safe because we wipe /etc/yum.repos.d next.
    info "RPM mode: Uninstalling repo definition packages from image"
    local repo_pkgs
    repo_pkgs=$(sudo rpm --dbpath="${root_fs_dir}/var/lib/rpm" -qa "azurelinux-repos*" 2>/dev/null | sort -u)
    if [[ -n "${repo_pkgs}" ]]; then
        info "RPM mode: Removing repo packages: ${repo_pkgs//$'\n'/ }"
        if ! sudo rpm --root="${root_fs_dir}" --dbpath="/var/lib/rpm" -e --nodeps --noscripts ${repo_pkgs}; then
            error "RPM mode: Failed to remove some repo packages, aborting build"
            exit 1
        fi
    fi
    # Also remove the manually-created Nvidia repo file and any leftovers
    sudo rm -rf "${root_fs_dir}/etc/yum.repos.d"

    # Bulk-copy all of /etc to ${DISTRO_SHARE_DIR}/etc.
    # This is the overlay lowerdir — at boot, /etc is a tmpfs overlay
    # whose lower layer is this directory.  Mirrors the Portage-mode
    # "sudo cp -a /etc ${DISTRO_SHARE_DIR}/etc" in build_image_util.sh.
    info "RPM mode: Copying /etc to ${ETC_FULL_PATH} for overlay lowerdir"
    sudo rm -rf "${ETC_FULL_PATH}"
    sudo cp -a "${root_fs_dir}/etc" "${ETC_FULL_PATH}"
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
