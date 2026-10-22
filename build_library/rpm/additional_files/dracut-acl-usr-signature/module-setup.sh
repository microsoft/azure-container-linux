#!/bin/bash
# shellcheck disable=SC2154 # dracut supplies the installation paths.

depends() {
    echo systemd-veritysetup flatcar-network
}

install() {
    inst_multiple bash cat mkdir mv sleep ln || return 1
    # Bootengine may already have installed /sysusr wrappers at the normal paths.
    inst_binary /usr/bin/curl /usr/lib/acl/early/curl || return 1
    inst_binary /usr/bin/jq /usr/lib/acl/early/jq || return 1
    inst_binary /usr/lib/systemd/systemd-veritysetup /usr/lib/acl/real/systemd-veritysetup || return 1

    inst_simple "${moddir}/acl-node-security-profile.sh" \
        /usr/lib/acl/acl-node-security-profile.sh || return 1
    inst_script "${moddir}/acl-security-profile-early.sh" /usr/bin/acl-security-profile-early || return 1
    inst_simple "${moddir}/acl-security-profile-early.service" \
        "${systemdsystemunitdir}/acl-security-profile-early.service" || return 1
    inst_script "${moddir}/acl-usr-signature-generator" \
        "${systemdutildir}/system-generators/acl-usr-signature-generator" || return 1

    # inst_script skips existing files; replace the binary installed by our dependency.
    rm -f "${initdir}/usr/lib/systemd/systemd-veritysetup" || return 1
    inst_script "${moddir}/systemd-veritysetup" /usr/lib/systemd/systemd-veritysetup
}
