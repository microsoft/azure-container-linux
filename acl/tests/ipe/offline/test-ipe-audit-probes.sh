#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "${SCRIPT_DIR}/acl/tests/ipe/run-ipe-audit-test.sh"

test_inventory() {
    local available active output
    available='[{"name":"containerd","type":"raw","path":"/etc/extensions/containerd.raw"},
        {"name":"oem-azure","type":"raw","path":"/etc/extensions/oem-azure.raw"}]'
    active='[{"hierarchy":"/opt","extensions":"none"},
        {"hierarchy":"/usr","extensions":["containerd","oem-azure","optional"]}]'
    output="$(ipe_check_sysext_inventory "${available}" "${active}")"
    grep -Fq 'name=optional active=true coverage=UNPROBED' <<< "${output}"
    if ipe_check_sysext_inventory '[]' "${active}" ||
        ipe_check_sysext_inventory "${available}" '[{"hierarchy":"/usr","extensions":["containerd"]}]' ||
        ipe_check_sysext_inventory "${available}" '[{"hierarchy":"/usr","extensions":"none"}]' ||
        ipe_check_sysext_inventory '{}' "${active}"; then
        echo "Invalid or incomplete extension inventory passed" >&2
        return 1
    fi
}

test_target_events() {
    local event='IPE_ACCESS ipe_op=EXECUTE ipe_hook=BPRM_CHECK enforcing=0 pid=123 path="/usr/bin/containerd" dev="overlay" ino=3 rule="DEFAULT op=EXECUTE action=DENY"'
    ipe_assert_probe_audit "${event}" /usr/bin/containerd 123 deny
    for event in "${event/BPRM_CHECK/MMAP}" "${event/pid=123/pid=1234}" \
        "${event/enforcing=0/enforcing=1}" "${event/IPE_ACCESS/NOT_IPE}" \
        "${event/\/usr\/bin\/containerd/\/usr\/lib\/libexample.so}"; do
        if ipe_assert_probe_audit "${event}" /usr/bin/containerd 123 deny; then
            echo "Unrelated or MMAP-only record satisfied the exec denial" >&2
            return 1
        fi
    done
    event='IPE_ACCESS ipe_op=EXECUTE ipe_hook=MMAP enforcing=0 pid=123 path="/usr/lib64/libc.so.6" rule="DEFAULT op=EXECUTE action=DENY"'
    if ipe_assert_usr_probe_audit "${event}" /usr/bin/true 123 required; then
        echo "Signed base probe accepted a dependency denial" >&2
        return 1
    fi
    ipe_assert_usr_probe_audit "${event}" /usr/bin/true 124 required
}

test_probe_payload() (
    local directory target
    directory="$(mktemp -d)"
    trap 'rm -rf -- "${directory}"' EXIT
    mkdir -p "${directory}/base/bin" "${directory}/containerd/usr/bin" "${directory}/oem-azure/usr/bin"
    printf 'base payload\n' > "${directory}/base/bin/true"
    target="${directory}/base/bin/true"
    ipe_check_probe_payload "${directory}" base bin/true "${target}"
    # An extension's link resolves through the merged namespace to the base file.
    ln -s "${target}" "${directory}/oem-azure/usr/bin/eject"
    ipe_check_probe_payload "${directory}" base bin/true \
        "$(readlink -f "${directory}/oem-azure/usr/bin/eject")"
    cp "${target}" "${directory}/containerd/usr/bin/true"
    if ipe_check_probe_payload "${directory}" base bin/true "${target}"; then
        echo "Ambiguous provider passed provenance validation" >&2
        return 1
    fi
    rm "${directory}/containerd/usr/bin/true"
    if ipe_check_probe_payload "${directory}" containerd bin/true "${target}" ||
        ipe_check_probe_payload "${directory}" base bin/missing "${target}"; then
        echo "Incorrect or missing provider passed provenance validation" >&2
        return 1
    fi
)

test_capture() (
    local directory event count=0 mode=delayed
    directory="$(mktemp -d)"
    trap 'rm -rf -- "${directory}"' EXIT
    event='IPE_ACCESS ipe_op=EXECUTE ipe_hook=BPRM_CHECK enforcing=0 pid=123 path="/var/tmp/probe" rule="DEFAULT op=EXECUTE action=DENY"'
    sleep() { :; }
    cat() {
        if [[ "$1" == /proc/sys/kernel/random/boot_id ]]; then
            printf 'boot-id\n'
        else
            command cat "$@"
        fi
    }
    journalctl() {
        [[ "$*" == *"--boot=boot-id --after-cursor=cursor _TRANSPORT=audit"* ]] || return 1
        count=$((count + 1))
        case "${mode}" in
            delayed) [[ "${count}" -lt 3 ]] || printf '%s\n' "${event}" ;;
            missing) : ;;
            stale) printf '%s\n' "${event/pid=123/pid=122}" ;;
            mmap) printf '%s\n' "${event/BPRM_CHECK/MMAP}" ;;
            unreadable) return 1 ;;
            lost-after-control) [[ "${count}" -ne 1 ]] || printf '%s\n' "${event}" ;;
        esac
        return 0
    }
    ipe_collect_probe_audit "${directory}" boot-id cursor /var/tmp/probe 123
    [[ "${count}" == 4 ]]
    for mode in missing stale mmap unreadable lost-after-control; do
        count=0
        if ipe_collect_probe_audit "${directory}" boot-id cursor /var/tmp/probe 123; then
            echo "Invalid ${mode} telemetry passed collection" >&2
            return 1
        fi
    done
    if ipe_collect_probe_audit "${directory}" different-boot cursor /var/tmp/probe 123 ||
        ipe_collect_probe_audit "${directory}" boot-id stale-cursor /var/tmp/probe 123; then
        echo "Wrong boot or unreadable cursor passed collection" >&2
        return 1
    fi
)

test_execution_and_reporting() (
    local directory output pid
    directory="$(mktemp -d)"
    trap 'rm -rf -- "${directory}"' EXIT
    ipe_run_probe "${directory}" version bash -c 'printf "version output\n"'
    pid="$(cat "${directory}/version.pid")"
    [[ "${pid}" =~ ^[1-9][0-9]*$ ]]
    [[ "$(cat "${directory}/version.stdout")" == 'version output' ]]
    [[ "$(cat "${directory}/version.status")" == 0 ]]
    : > "${directory}/audit.log"
    output="$(ipe_report_probe "${directory}" version /usr/bin/version allow pass)"
    grep -Fq 'observed=NO_DENIAL_OBSERVED hooks=- result=PASS' <<< "${output}"
    if output="$(ipe_report_probe "${directory}" version /usr/bin/version allow fail)"; then
        echo "Missing telemetry turned absence into a pass" >&2
        return 1
    fi
    grep -Fq 'observed=UNKNOWN' <<< "${output}"
    printf 'IPE_ACCESS ipe_op=EXECUTE ipe_hook=MMAP enforcing=0 pid=%s path="/usr/lib64/libc.so.6" rule="DEFAULT op=EXECUTE action=DENY"\n' \
        "${pid}" > "${directory}/audit.log"
    if output="$(ipe_report_probe "${directory}" version /usr/bin/version allow pass)"; then
        echo "Dependency denial did not fail the signed probe report" >&2
        return 1
    fi
    grep -Fq 'result=FAIL' <<< "${output}"
    grep -Fq 'path="/usr/lib64/libc.so.6"' <<< "${output}"
    ipe_run_probe "${directory}" failure bash -c 'echo deliberate-failure >&2; exit 7'
    if output="$(ipe_report_probe "${directory}" failure /usr/bin/failure deny pass)"; then
        echo "Failed execution passed" >&2
        return 1
    fi
    grep -Fq 'exit=7' <<< "${output}"
    grep -Fq 'deliberate-failure' <<< "${output}"
)

test_inventory
test_target_events
test_probe_payload
test_capture
test_execution_and_reporting
echo "IPE audit probe tests passed"
