#!/bin/bash
# shellcheck disable=SC2154 # The dracut build supplies these paths.

depends() {
    echo systemd-veritysetup systemd-networkd
}

install() {
    inst_multiple systemctl timeout lsblk blockdev \
        dd wc base64 grep sleep cat mkdir mv rm uname chmod dmsetup
    # Bootengine wraps some /usr tools through /sysusr. Early boot cannot use those.
    local tool
    for tool in curl jq openssl; do
        inst_binary "$(command -v "${tool}")" "/usr/lib/acl/initrd-bin/${tool}"
    done
    inst_script "${moddir}/acl-verity-setup.sh" /usr/bin/acl-verity-setup
    inst_script "${moddir}/acl-verity-generator.sh" \
        "${systemdutildir}/system-generators/acl-verity-generator"
    inst_simple "${moddir}/acl-usr-verity-payload.sh" /usr/lib/acl/acl-usr-verity-payload.sh
    inst_simple "${moddir}/verity-setup.conf" \
        "${systemdsystemunitdir}/systemd-veritysetup@usr.service.d/50-acl-signature.conf"
}
