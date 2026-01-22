source "${BUILD_LIBRARY_DIR}/rpm/package_catalog.sh" || exit 1
source "${BUILD_LIBRARY_DIR}/rpm/package_source_config.sh" || exit 1
source "${BUILD_LIBRARY_DIR}/rpm/rpm_install.sh" || exit 1
source "${BUILD_LIBRARY_DIR}/rpm/package_install.sh" || exit 1

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

# Unified package installation wrapper.
# Routes packages to appropriate source (Portage or RPM) based on configuration.
emerge_to_image() {
  local root_fs_dir="$1"; shift

  # Filter out emerge options, only pass actual package names
  local packages=()
  local emerge_opts=()
  for arg in "$@"; do
    if [[ "$arg" == -* ]]; then
      emerge_opts+=("$arg")
    else
      packages+=("$arg")
    fi
  done

  install_packages_to_image "${root_fs_dir}" "${packages[@]}"

  # Make sure profile.env has been generated (for Portage packages)
  if [[ -d "${root_fs_dir}/etc/portage" ]]; then
    sudo -E ROOT="${root_fs_dir}" env-update --no-ldconfig 2>/dev/null || true
  fi

  # Run content validation
  ROOT="${root_fs_dir}" PORTAGE_CONFIGROOT="${BUILD_DIR}"/configroot \
      test_image_content "${root_fs_dir}" 2>/dev/null || true
}

# List packages installed from RPM database
image_packages_portage() {
    local root_fs_dir="$1"
    if [[ -d "${root_fs_dir}/var/lib/rpm" ]]; then
        rpm_query_packages "${root_fs_dir}" "%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}" 2>/dev/null || true
    fi
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

    info "RPM mode: Installing filesystem RPM instead of baselayout"
    # Install filesystem RPM to provide basic directory structure
    # This replaces baselayout and creates /usr/lib, /etc, /bin -> usr/bin symlinks, etc.
    local filesystem_rpm=""
    if [[ -n "${RPM_STAGING_DIR:-}" ]] && [[ -d "${RPM_STAGING_DIR}" ]]; then
      filesystem_rpm=$(find "${RPM_STAGING_DIR}" -maxdepth 1 -name "filesystem-*.rpm" | head -1)
    fi

    if [[ -n "$filesystem_rpm" ]]; then
      info "Installing filesystem RPM: $(basename $filesystem_rpm)"
      # Initialize RPM database
      sudo rpm --root="${root_fs_dir}" --initdb
      # Install filesystem without scripts (Lua scripts need interpreter)
      sudo rpm --root="${root_fs_dir}" \
        --install \
        --nodeps \
        --noscripts \
        "$filesystem_rpm"

      # Manually create symlinks that filesystem's %post Lua script would create
      # These are from the %post scriptlet in filesystem.spec
      sudo mkdir -p "${root_fs_dir}/usr/lib/debug/usr"
      [[ -e "${root_fs_dir}/usr/lib/debug/lib64" ]] || sudo ln -sf lib "${root_fs_dir}/usr/lib/debug/lib64"
      [[ -e "${root_fs_dir}/usr/lib/debug/usr/bin" ]] || sudo ln -sf ../bin "${root_fs_dir}/usr/lib/debug/usr/bin"
      [[ -e "${root_fs_dir}/usr/lib/debug/usr/sbin" ]] || sudo ln -sf ../sbin "${root_fs_dir}/usr/lib/debug/usr/sbin"
      [[ -e "${root_fs_dir}/usr/lib/debug/usr/lib" ]] || sudo ln -sf ../lib "${root_fs_dir}/usr/lib/debug/usr/lib"
      [[ -e "${root_fs_dir}/usr/lib/debug/usr/lib64" ]] || sudo ln -sf ../lib "${root_fs_dir}/usr/lib/debug/usr/lib64"
      [[ -e "${root_fs_dir}/usr/lib/debug/usr/.dwz" ]] || sudo ln -sf ../.dwz "${root_fs_dir}/usr/lib/debug/usr/.dwz"

      # Create /proc and /sys directories (from %pretrans)
      sudo mkdir -p "${root_fs_dir}/proc" "${root_fs_dir}/sys"
      sudo chmod 555 "${root_fs_dir}/proc" "${root_fs_dir}/sys"

      # Ensure /root home directory exists with proper permissions
      sudo mkdir -p "${root_fs_dir}/root"
      sudo chmod 700 "${root_fs_dir}/root"

      info "filesystem RPM installed successfully"
    else
      warn "filesystem RPM not found in ${RPM_STAGING_DIR:-not set}, creating minimal directories"
      error "aborting"
      exit 1
    fi
}

finish_image_rpm() {
  local root_fs_dir="$1"

    # In RPM mode, the kernel is installed by Azure Linux RPM to /boot/vmlinuz-*
    # Find and copy it to the expected location for Flatcar's grub.cfg
    local kernel_file
    kernel_file=$(ls "${root_fs_dir}"/boot/vmlinuz-* 2>/dev/null | grep -v ".hmac" | head -1)
    if [[ -n "${kernel_file}" ]]; then
      info "RPM mode: Copying kernel from ${kernel_file} to /boot/flatcar/vmlinuz-a"
      sudo cp "${kernel_file}" "${root_fs_dir}/boot/flatcar/vmlinuz-a"

      # Extract kernel version from filename (e.g., vmlinuz-6.6.112.1-2.azl3 -> 6.6.112.1-2.azl3)
      local kernel_version
      kernel_version=$(basename "${kernel_file}" | sed 's/vmlinuz-//')
      info "RPM mode: Kernel version is ${kernel_version}"

      # Generate initramfs using dracut if available
      if [[ -x "${root_fs_dir}/usr/bin/dracut" ]] || [[ -x "${root_fs_dir}/sbin/dracut" ]]; then
        info "RPM mode: Generating initramfs with dracut"

        # Mount required filesystems for dracut
        sudo mount --bind /dev "${root_fs_dir}/dev" || true
        sudo mount --bind /proc "${root_fs_dir}/proc" || true
        sudo mount --bind /sys "${root_fs_dir}/sys" || true

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

        # Ensure /etc/crypttab exists but doesn't contain fido2 entries
        # This prevents systemd-cryptsetup from requiring the fido2 module
        if [[ ! -f "${root_fs_dir}/etc/crypttab" ]]; then
            sudo touch "${root_fs_dir}/etc/crypttab"
        else
            # Remove any fido2 entries if they exist
            sudo sed -i '/fido2-device=/d; /fido2-cid=/d' "${root_fs_dir}/etc/crypttab" 2>/dev/null || true
        fi

        # Remove dracut modules that require hardware we don't have in VMs
        # This prevents systemd-cryptsetup from depending on fido2/pkcs11/tpm2-tss
        # which would cause dracut-systemd to fail
        for mod in 91fido2 91pkcs11 91tpm2-tss; do
            if [[ -d "${root_fs_dir}/usr/lib/dracut/modules.d/${mod}" ]]; then
                info "RPM mode: Removing dracut module ${mod} (not needed for VM boot)"
                sudo rm -rf "${root_fs_dir}/usr/lib/dracut/modules.d/${mod}"
            fi
        done

        # Create custom dracut module for /etc overlay setup (like Flatcar's bootengine)
        # Key insight: Must use a systemd service in initrd (not a dracut hook) so the mount
        # survives switch-root. Dracut hooks run outside systemd's mount tracking.
        info "RPM mode: Creating dracut module for /etc overlay (systemd service approach)"
        sudo mkdir -p "${root_fs_dir}/usr/lib/dracut/modules.d/99flatcar-etc"

        # Module setup script (module-setup.sh)
        # Based on Flatcar's 99setup-root approach which uses a systemd service
        sudo cp "${BUILD_LIBRARY_DIR}/rpm/additional_files/module-setup.sh" "${root_fs_dir}/usr/lib/dracut/modules.d/99flatcar-etc/module-setup.sh"
        sudo chmod +x "${root_fs_dir}/usr/lib/dracut/modules.d/99flatcar-etc/module-setup.sh"

        # The systemd service that sets up /etc overlay in initrd
        # Running as a systemd service (not hook) ensures the mount survives
        # switch-root
        sudo cp "${BUILD_LIBRARY_DIR}/rpm/additional_files/initrd-setup-etc-overlay.service" "${root_fs_dir}/usr/lib/dracut/modules.d/99flatcar-etc/initrd-setup-etc-overlay.service"

        # The actual /etc overlay setup script that runs in initramfs
        # This is like Flatcar's initrd-setup-root but just handles /etc overlay
        # NOTE: Must avoid grep/mountpoint commands that may not be in initramfs
        sudo cp "${BUILD_LIBRARY_DIR}/rpm/additional_files/flatcar-etc-overlay.sh" "${root_fs_dir}/usr/lib/dracut/modules.d/99flatcar-etc/flatcar-etc-overlay.sh"
        sudo chmod +x "${root_fs_dir}/usr/lib/dracut/modules.d/99flatcar-etc/flatcar-etc-overlay.sh"

        # TODO: only for QEMU testing, remove or refactor later
        # Ignition config drive loader - loads ignition config from CDROM labeled "ignition"
        # This runs before ignition services and copies config to /usr/lib/ignition/user.ign
        sudo cp "${BUILD_LIBRARY_DIR}/rpm/additional_files/ignition-config-drive.sh" "${root_fs_dir}/usr/lib/dracut/modules.d/99flatcar-etc/ignition-config-drive.sh"
        sudo chmod +x "${root_fs_dir}/usr/lib/dracut/modules.d/99flatcar-etc/ignition-config-drive.sh"
        sudo cp "${BUILD_LIBRARY_DIR}/rpm/additional_files/ignition-config-drive.service" "${root_fs_dir}/usr/lib/dracut/modules.d/99flatcar-etc/ignition-config-drive.service"

        # TODO: remove post SELinux enablement
        # Dummy setfiles for SELinux-disabled systems - Ignition calls it even with SELINUX=disabled
        sudo cp "${BUILD_LIBRARY_DIR}/rpm/additional_files/setfiles" "${root_fs_dir}/usr/lib/dracut/modules.d/99flatcar-etc/setfiles"
        sudo chmod +x "${root_fs_dir}/usr/lib/dracut/modules.d/99flatcar-etc/setfiles"

        info "RPM mode: Created dracut module 99flatcar-etc with systemd service for /etc overlay"

        # Create dracut config to work around issues in chroot environment
        # We rely on standard systemd-udevd module to include libudev.so
        sudo mkdir -p "${root_fs_dir}/etc/dracut.conf.d"
        sudo cp "${BUILD_LIBRARY_DIR}/rpm/additional_files/99-hybrid-build.conf" "${root_fs_dir}/etc/dracut.conf.d/99-hybrid-build.conf"

        # Create a wrapper script that sets up the environment properly for
        # dracut
        sudo cp "${BUILD_LIBRARY_DIR}/rpm/additional_files/run-dracut.sh" "${root_fs_dir}/tmp/run-dracut.sh"
        sudo chmod +x "${root_fs_dir}/tmp/run-dracut.sh"

        # Run dracut via the wrapper script with verbose logging
        info "RPM mode: Running dracut with verbose output..."
        sudo chroot "${root_fs_dir}" /tmp/run-dracut.sh \
          --force \
          --no-hostonly \
          --no-early-microcode \
          --verbose \
          --kver "${kernel_version}" \
          "/boot/flatcar/initramfs-a.img" 2>&1 | tee "${root_fs_dir}/tmp/dracut-verbose.log" || {
            error "RPM mode: dracut failed. Log saved to ${root_fs_dir}/tmp/dracut-verbose.log"
            cat "${root_fs_dir}/tmp/dracut-verbose.log"
            # Clean up before failing
            sudo rm -f "${root_fs_dir}/tmp/run-dracut.sh"
            sudo umount "${root_fs_dir}/sys" 2>/dev/null || true
            sudo umount "${root_fs_dir}/proc" 2>/dev/null || true
            sudo umount "${root_fs_dir}/dev" 2>/dev/null || true
            die "RPM mode: dracut initramfs generation failed"
          }

        # Copy dracut log to build output for analysis
        if [[ -f "${root_fs_dir}/tmp/dracut-verbose.log" ]]; then
            cp "${root_fs_dir}/tmp/dracut-verbose.log" "${BUILD_DIR}/dracut-verbose.log" 2>/dev/null || true
            info "RPM mode: dracut log saved to ${BUILD_DIR}/dracut-verbose.log"
        fi

        # Clean up wrapper script
        sudo rm -f "${root_fs_dir}/tmp/run-dracut.sh"

        # Unmount filesystems
        sudo umount "${root_fs_dir}/sys" 2>/dev/null || true
        sudo umount "${root_fs_dir}/proc" 2>/dev/null || true
        sudo umount "${root_fs_dir}/dev" 2>/dev/null || true

        if [[ -f "${root_fs_dir}/boot/flatcar/initramfs-a.img" ]]; then
          info "RPM mode: initramfs generated successfully"
          ls -la "${root_fs_dir}/boot/flatcar/initramfs-a.img"
        else
          die "RPM mode: initramfs was not generated at ${root_fs_dir}/boot/flatcar/initramfs-a.img"
        fi
      else
        die "RPM mode: dracut not found - cannot generate initramfs required for Azure Linux kernel"
      fi
    else
      die "RPM mode: No kernel found in ${root_fs_dir}/boot/"
    fi
}

# Skip the Portage check, as AzL RPMs use dynamic UID allocation
finish_image_uids_rpm() {
  local root_fs_dir="$1"

  # RPM mode: Create sysusers.d configs for system users that Azure Linux expects
  # but doesn't provide via sysusers.d (normally created by RPM scriptlets)
    info "RPM mode: Creating sysusers.d configs for essential system users"

    # D-Bus messagebus user - required for dbus.service
    sudo tee "${root_fs_dir}/usr/lib/sysusers.d/dbus.conf" > /dev/null <<'SYSUSERS_DBUS'
# D-Bus system message bus user
u messagebus 81 "System Message Bus" /run/dbus
SYSUSERS_DBUS

    # polkitd user - used by polkit if installed
    sudo tee "${root_fs_dir}/usr/lib/sysusers.d/polkit.conf" > /dev/null <<'SYSUSERS_POLKIT'
# PolicyKit daemon user
u polkitd 27 "PolicyKit Daemon Owner" /
SYSUSERS_POLKIT

    # sshd user - required for OpenSSH privilege separation
    sudo tee "${root_fs_dir}/usr/lib/sysusers.d/sshd.conf" > /dev/null <<'SYSUSERS_SSHD'
# SSH privilege separation user
g sshd 74 -
u sshd 74:74 "Privilege-separated SSH" /usr/share/empty.sshd
SYSUSERS_SSHD

    # sshd privilege separation directory
    sudo tee "${root_fs_dir}/usr/lib/tmpfiles.d/sshd.conf" > /dev/null <<'TMPFILES_SSHD'
# SSH privilege separation directory
d /var/lib/sshd 0755 root root - -
TMPFILES_SSHD

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

    info "RPM mode: Created sysusers.d configs for system users"
}

finish_image_kernel_config_rpm() {
    local root_fs_dir="$1"

      # In RPM mode, kernel config is at /boot/config-* (Azure Linux layout)
      local config_file
      config_file=$(ls "${root_fs_dir}"/boot/config-* 2>/dev/null | head -1)
      if [[ -n "${config_file}" ]]; then
        cp "${config_file}" "${BUILD_DIR}/${image_kconfig}"
      else
        info "RPM mode: No kernel config found in /boot/, skipping"
      fi
}

finish_image_tmpfiles_rpm() {
  local root_fs_dir="$1"

    # RPM mode: flatcar-tmpfiles may not exist, skip or use fallback
    if [[ -x "${root_fs_dir}/usr/sbin/flatcar-tmpfiles" ]]; then
      sudo "${root_fs_dir}"/usr/sbin/flatcar-tmpfiles "${root_fs_dir}"
    else
      info "RPM mode: flatcar-tmpfiles not available, relocating /etc configs to /usr/share/flatcar/etc"

      # In Flatcar, /etc is a tmpfs that gets populated from /usr/share/flatcar/etc at boot
      # RPMs install configs to /etc, but we need them in /usr/share/flatcar/etc for persistence
      # Move essential configs from /etc to /usr/share/flatcar/etc

      sudo mkdir -p "${root_fs_dir}/usr/share/flatcar/etc"

      # Move PAM configs (from shadow-utils RPM) - CRITICAL for login
      if [[ -d "${root_fs_dir}/etc/pam.d" ]]; then
        info "RPM mode: Moving /etc/pam.d to /usr/share/flatcar/etc/pam.d"
        sudo mv "${root_fs_dir}/etc/pam.d" "${root_fs_dir}/usr/share/flatcar/etc/"
        ls "${root_fs_dir}/usr/share/flatcar/etc/pam.d"
      fi

      # Move security configs (from pam RPM)
      if [[ -d "${root_fs_dir}/etc/security" ]]; then
        info "RPM mode: Moving /etc/security to /usr/share/flatcar/etc/security"
        sudo mv "${root_fs_dir}/etc/security" "${root_fs_dir}/usr/share/flatcar/etc/"
      fi

      # Move SSH configs if present
      if [[ -d "${root_fs_dir}/etc/ssh" ]]; then
        info "RPM mode: Moving /etc/ssh to /usr/share/flatcar/etc/ssh"
        sudo mv "${root_fs_dir}/etc/ssh" "${root_fs_dir}/usr/share/flatcar/etc/"
      fi

      # Update root's shell in /etc/passwd BEFORE copying to /usr/share/flatcar/etc
      # This fixes the shadow-utils login stdout issue
      if [[ -f "${root_fs_dir}/etc/passwd" ]]; then
        info "RPM mode: Updating root's shell in /etc/passwd to use bash-login wrapper"
        sudo sed -i 's|^root:\([^:]*:[^:]*:[^:]*:[^:]*:[^:]*\):.*|root:\1:/usr/local/bin/bash-login|' "${root_fs_dir}/etc/passwd"
      fi

      # Set empty root password for passwordless console login
      # Users can set a password after logging in with 'passwd'
      # This is standard for cloud VMs where SSH key auth is primary
      if [[ -f "${root_fs_dir}/etc/shadow" ]]; then
        info "RPM mode: Setting empty root password for console login"
        sudo sed -i 's|^root:[^:]*:|root::|' "${root_fs_dir}/etc/shadow"
      fi

      # Move individual essential config files (except profile - we create our own)
      for cfg in passwd group shadow gshadow login.defs nsswitch.conf shells environment; do
        if [[ -f "${root_fs_dir}/etc/${cfg}" ]]; then
          sudo cp -a "${root_fs_dir}/etc/${cfg}" "${root_fs_dir}/usr/share/flatcar/etc/"
        fi
      done

      # Move profile.d if exists
      if [[ -d "${root_fs_dir}/etc/profile.d" ]]; then
        sudo cp -a "${root_fs_dir}/etc/profile.d" "${root_fs_dir}/usr/share/flatcar/etc/"
      fi

      # Move default directory (useradd defaults)
      if [[ -d "${root_fs_dir}/etc/default" ]]; then
        sudo cp -a "${root_fs_dir}/etc/default" "${root_fs_dir}/usr/share/flatcar/etc/"
      fi

      # Move skel directory if exists
      if [[ -d "${root_fs_dir}/etc/skel" ]]; then
        sudo cp -a "${root_fs_dir}/etc/skel" "${root_fs_dir}/usr/share/flatcar/etc/"
      fi

      # TODO: remove post SELinux enablement
      # Create SELinux config (required by Ignition even if SELinux is disabled)
      # Ignition requires SELINUXTYPE even when disabled, and looks for file_contexts
      # We create an empty file_contexts so relabeling is a no-op
      info "RPM mode: Creating SELinux config (disabled) with empty policy"
      sudo mkdir -p "${root_fs_dir}/usr/share/flatcar/etc/selinux/targeted/contexts/files"
      sudo tee "${root_fs_dir}/usr/share/flatcar/etc/selinux/config" > /dev/null <<'SELINUX_EOF'
# This file controls the state of SELinux on the system.
# SELINUX=disabled - No SELinux policy is loaded.
SELINUX=disabled
SELINUXTYPE=targeted
SELINUX_EOF
      # Create empty file_contexts so Ignition's relabeling is a no-op
      sudo touch "${root_fs_dir}/usr/share/flatcar/etc/selinux/targeted/contexts/files/file_contexts"

      # Configure sshd to look for authorized_keys in the ignition location
      # Ignition places SSH keys in ~/.ssh/authorized_keys.d/ignition
      # NOTE: /etc/ssh was moved to /usr/share/flatcar/etc/ssh above, so we modify it there
      info "RPM mode: Configuring sshd AuthorizedKeysFile for Ignition"
      local ssh_config_dir="${root_fs_dir}/usr/share/flatcar/etc/ssh"
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
      elif ! grep -q "^Include.*/etc/ssh/sshd_config.d" "${sshd_config}"; then
        info "RPM mode: Adding Include directive to existing sshd_config"
        sudo sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "${sshd_config}"
      else
        info "RPM mode: sshd_config already has Include directive"
      fi

      # Configure sudo for wheel group (passwordless)
      info "RPM mode: Configuring passwordless sudo for wheel group"
      sudo mkdir -p "${root_fs_dir}/usr/share/flatcar/etc/sudoers.d"
      sudo tee "${root_fs_dir}/usr/share/flatcar/etc/sudoers.d/wheel-nopasswd" > /dev/null <<'SUDOERS_EOF'
%wheel ALL=(ALL:ALL) NOPASSWD: ALL
SUDOERS_EOF
      sudo chmod 440 "${root_fs_dir}/usr/share/flatcar/etc/sudoers.d/wheel-nopasswd"

      info "RPM mode: Creating tmpfiles.d entries to populate /etc at boot"
      # Create tmpfiles.d entries to populate /etc at boot time
      sudo cp "${BUILD_LIBRARY_DIR}/rpm/additional_files/hybrid-etc.conf" "${root_fs_dir}/usr/lib/tmpfiles.d/hybrid-etc.conf"
      info "RPM mode: Created /usr/lib/tmpfiles.d/hybrid-etc.conf"

      # Create an early-boot service to populate /etc from /usr/share/flatcar/etc
      # This runs VERY early, before any login services, to ensure PAM configs are available
      info "RPM mode: Creating hybrid-etc-populate.service for early /etc population"
      sudo cp "${BUILD_LIBRARY_DIR}/rpm/additional_files/hybrid-etc-populate.service" "${root_fs_dir}/usr/lib/systemd/system/hybrid-etc-populate.service"
      # Enable the service in sysinit.target (very early)
      sudo mkdir -p "${root_fs_dir}/usr/lib/systemd/system/sysinit.target.wants"
      sudo ln -sf ../hybrid-etc-populate.service "${root_fs_dir}/usr/lib/systemd/system/sysinit.target.wants/hybrid-etc-populate.service"
      info "RPM mode: Enabled hybrid-etc-populate.service in sysinit.target"

      # Create systemd-networkd configuration for DHCP
      info "RPM mode: Creating systemd-networkd configuration for DHCP"
      sudo mkdir -p "${root_fs_dir}/etc/systemd/network"
      sudo cp "${BUILD_LIBRARY_DIR}/rpm/additional_files/99-dhcp-all.network" "${root_fs_dir}/etc/systemd/network/99-dhcp-all.network"
      sudo chmod 644 "${root_fs_dir}/etc/systemd/network/99-dhcp-all.network"

      # Enable systemd-networkd service
      info "RPM mode: Enabling systemd-networkd.service"
      sudo mkdir -p "${root_fs_dir}/usr/lib/systemd/system/multi-user.target.wants"
      sudo ln -sf ../systemd-networkd.service "${root_fs_dir}/usr/lib/systemd/system/multi-user.target.wants/systemd-networkd.service"

      # Enable systemd-resolved service (for DNS)
      info "RPM mode: Enabling systemd-resolved.service"
      sudo ln -sf ../systemd-resolved.service "${root_fs_dir}/usr/lib/systemd/system/multi-user.target.wants/systemd-resolved.service"

      # Create /etc/resolv.conf symlink to point to systemd-resolved
      info "RPM mode: Configuring /etc/resolv.conf for systemd-resolved"
      sudo rm -f "${root_fs_dir}/etc/resolv.conf"
      sudo ln -sf /run/systemd/resolve/stub-resolv.conf "${root_fs_dir}/etc/resolv.conf"

      # Enable containerd service
      info "RPM mode: Enabling containerd.service"
      sudo ln -sf ../containerd.service "${root_fs_dir}/usr/lib/systemd/system/multi-user.target.wants/containerd.service"

      # Enable serial-getty on ttyS0 with AUTOLOGIN
      # This bypasses PAM login and drops directly to root shell
      info "RPM mode: Creating autologin serial-getty@ttyS0"
      sudo mkdir -p "${root_fs_dir}/usr/lib/systemd/system/serial-getty@ttyS0.service.d"
      sudo tee "${root_fs_dir}/usr/lib/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" > /dev/null <<'AUTOLOGIN_CONF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud %I 115200,38400,9600 $TERM
AUTOLOGIN_CONF

      # Enable serial-getty on ttyS0
      sudo mkdir -p "${root_fs_dir}/usr/lib/systemd/system/getty.target.wants"
      sudo ln -sf ../serial-getty@.service "${root_fs_dir}/usr/lib/systemd/system/getty.target.wants/serial-getty@ttyS0.service"

      # Create /etc/profile.d directory for additional scripts
      info "RPM mode: Creating profile.d directory"
      sudo mkdir -p "${root_fs_dir}/usr/share/flatcar/etc/profile.d"

      # Create a complete /etc/profile
      info "RPM mode: Creating /etc/profile"
      sudo cp "${BUILD_LIBRARY_DIR}/rpm/additional_files/profile" "${root_fs_dir}/usr/share/flatcar/etc/profile"

      # Create fallback /etc/shells
      info "RPM mode: Creating fallback /etc/shells"
      sudo cp "${BUILD_LIBRARY_DIR}/rpm/additional_files/shells" "${root_fs_dir}/usr/share/flatcar/etc/shells"

      # Create bash-login wrapper to fix shadow-utils login stdout issue
      # shadow-utils' login sets stdout to a pipe instead of TTY, causing shell to exit immediately
      info "RPM mode: Creating bash-login wrapper to fix login stdout issue"
      sudo mkdir -p "${root_fs_dir}/usr/local/bin"
      sudo cp "${BUILD_LIBRARY_DIR}/rpm/additional_files/bash-login" "${root_fs_dir}/usr/local/bin/bash-login"
      sudo chmod +x "${root_fs_dir}/usr/local/bin/bash-login"

      # Note: root's shell was already updated in /etc/passwd earlier (before copying to /usr/share/flatcar/etc)
      # Verify it's correct in both places
      info "RPM mode: Verifying root's shell is set to bash-login"
      if [[ -f "${root_fs_dir}/etc/passwd" ]]; then
        grep "^root:" "${root_fs_dir}/etc/passwd" || true
      fi

      # Create /root with proper .bashrc and .bash_profile
      info "RPM mode: Creating /root home directory with shell configs"
      sudo mkdir -p "${root_fs_dir}/root"
      sudo chmod 700 "${root_fs_dir}/root"

      # Create .bash_profile for login shells
      sudo cp "${BUILD_LIBRARY_DIR}/rpm/additional_files/.bash_profile" "${root_fs_dir}/root/.bash_profile"

      # Create .bashrc for interactive shells
      sudo cp "${BUILD_LIBRARY_DIR}/rpm/additional_files/.bashrc" "${root_fs_dir}/root/.bashrc"
    fi
}

finish_image_backup_etc_rpm() {
    local root_fs_dir="$1"

    info "RPM mode: Skipping /usr/share/flatcar/etc recreation (already set up with PAM configs)"
    # In RPM mode, we already moved configs to /usr/share/flatcar/etc earlier
    # We just need to ensure any remaining /etc files are also copied
    # Use rsync-like behavior: copy files that don't exist in destination
    if [[ -d "${root_fs_dir}/etc" ]]; then
      sudo cp -an "${root_fs_dir}/etc/." "${root_fs_dir}/usr/share/flatcar/etc/" 2>/dev/null || true
    fi
}
