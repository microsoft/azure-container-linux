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
    local boot_id=fa8a7b1c-0c08-4915-9707-3d3ce9879c4e
    directory="$(mktemp -d)"
    trap 'rm -rf -- "${directory}"' EXIT
    event='IPE_ACCESS ipe_op=EXECUTE ipe_hook=BPRM_CHECK enforcing=0 pid=123 path="/var/tmp/probe" rule="DEFAULT op=EXECUTE action=DENY"'
    sleep() { :; }
    cat() {
        if [[ "$1" == /proc/sys/kernel/random/boot_id ]]; then
            if [[ "${mode}" == reboot-after-control && "${count}" -gt 0 ]]; then
                printf '11111111-2222-3333-4444-555555555555\n'
            else
                printf '%s\n' "${boot_id}"
            fi
        else
            command cat "$@"
        fi
    }
    journalctl() {
        if ! [[ "$1" =~ ^--boot=[[:xdigit:]]{32}$ ]]; then
            echo "Failed to parse boot descriptor '${1#--boot=}'" >&2
            return 1
        fi
        [[ "$*" == "--boot=fa8a7b1c0c08491597073d3ce9879c4e --after-cursor=cursor _TRANSPORT=audit --no-pager -o cat" ]] || return 1
        count=$((count + 1))
        case "${mode}" in
            delayed) [[ "${count}" -lt 3 ]] || printf '%s\n' "${event}" ;;
            missing) : ;;
            stale) printf '%s\n' "${event/pid=123/pid=122}" ;;
            mmap) printf '%s\n' "${event/BPRM_CHECK/MMAP}" ;;
            unreadable) return 1 ;;
            lost-after-control) [[ "${count}" -ne 1 ]] || printf '%s\n' "${event}" ;;
            unreadable-after-control)
                [[ "${count}" -eq 1 ]] || return 1
                printf '%s\n' "${event}"
                ;;
            reboot-after-control) printf '%s\n' "${event}" ;;
        esac
        return 0
    }
    ipe_collect_probe_audit "${directory}" "${boot_id}" cursor /var/tmp/probe 123
    [[ "${count}" == 4 ]]
    for mode in missing stale mmap unreadable lost-after-control unreadable-after-control reboot-after-control; do
        count=0
        if ipe_collect_probe_audit "${directory}" "${boot_id}" cursor /var/tmp/probe 123; then
            echo "Invalid ${mode} telemetry passed collection" >&2
            return 1
        fi
    done
    mode=delayed
    count=0
    if ipe_collect_probe_audit "${directory}" 11111111-2222-3333-4444-555555555555 cursor /var/tmp/probe 123 ||
        ipe_collect_probe_audit "${directory}" "${boot_id}" stale-cursor /var/tmp/probe 123 ||
        ipe_collect_probe_audit "${directory}" not-a-boot-id cursor /var/tmp/probe 123; then
        echo "Wrong/invalid boot or unreadable cursor passed collection" >&2
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
    [[ "${output}" == $'\n=== Probe: version ===\nCommand: '*$'\nstdout:\n  version output\nstderr:\n  <empty>\nIPE_PROBE '* ]]
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
    [[ "${output}" == *$'\nstdout:\n  <empty>\nstderr:\n  deliberate-failure\nIPE_PROBE '* ]]
    [[ "$(grep -c '^ *deliberate-failure$' <<< "${output}")" == 1 ]]
)

test_probe_command_and_output_logging() (
    local directory output command expected
    directory="$(mktemp -d)"
    trap 'rm -rf -- "${directory}"' EXIT
    ipe_run_probe "${directory}" quoted bash -c 'printf "<%s>\n" "$@"' -- \
        'two words' '' "a'b" '$HOME; $(false)' $'line1\nline2'
    command="$(cat "${directory}/quoted.command")"
    expected="$(cat "${directory}/quoted.stdout")"
    [[ "${command}" != *$'\n'* ]]
    [[ "$(bash --noprofile --norc -p -c "${command}")" == "${expected}" ]]
    : > "${directory}/audit.log"
    output="$(ipe_report_probe "${directory}" quoted /usr/bin/bash allow pass)"
    grep -Fxq "Command: ${command}" <<< "${output}"

    ipe_run_probe "${directory}" unterminated bash -c 'printf "last line"; printf "warning" >&2'
    output="$(ipe_report_probe "${directory}" unterminated /usr/bin/bash allow pass)"
    [[ "${output}" == *$'\nstdout:\n  last line\nstderr:\n  warning\nIPE_PROBE '* ]]
    grep -Fq 'result=PASS' <<< "${output}"
    rm "${directory}/unterminated.stderr"
    if output="$(ipe_report_probe "${directory}" unterminated /usr/bin/bash allow pass)"; then
        echo "Missing output was treated as an empty successful stream" >&2
        return 1
    fi
    grep -Fq 'result=FAIL reason=missing-stderr' <<< "${output}"
)

test_base_probes() (
    local directory true_probe bash_probe name target pid output spec
    directory="$(mktemp -d)"
    trap 'rm -rf -- "${directory}"' EXIT
    true_probe="$(type -P true)"
    bash_probe="$(type -P bash)"
    cat > "${directory}/systemctl" <<'EOF'
#!/bin/bash -p
[[ "$#" == 1 && "$1" == --version ]] || exit 1
printf 'systemd test version\n'
EOF
    chmod +x "${directory}/systemctl"
    printf 'exit 99\n' > "${directory}/startup"
    export BASH_ENV="${directory}/startup"
    ipe_run_base_probes "${directory}" "${true_probe}" "${bash_probe}" "${directory}/systemctl"
    [[ ! -s "${directory}/base.stdout" && ! -s "${directory}/base-bash.stdout" ]]
    [[ "$(cat "${directory}/base-systemctl.stdout")" == 'systemd test version' ]]
    for spec in "base:${true_probe}" "base-bash:${bash_probe}" "base-systemctl:${directory}/systemctl"; do
        name="${spec%%:*}"
        target="${spec#*:}"
        pid="$(cat "${directory}/${name}.pid")"
        [[ "${pid}" =~ ^[1-9][0-9]*$ && "$(cat "${directory}/${name}.status")" == 0 ]]
        : > "${directory}/audit.log"
        output="$(ipe_report_probe "${directory}" "${name}" "${target}" allow pass)"
        if [[ "${name}" == base || "${name}" == base-bash ]]; then
            [[ "${output}" == *$'\nstdout:\n  <empty>\nstderr:\n  <empty>\nIPE_PROBE '* ]]
        else
            [[ "${output}" == *$'\nstdout:\n  systemd test version\nstderr:\n  <empty>\nIPE_PROBE '* ]]
        fi
        if ipe_report_probe "${directory}" "${name}" "${target}" deny pass; then
            echo "Unsigned ${name} passed without its target denial" >&2
            return 1
        fi
        printf 'IPE_ACCESS ipe_op=EXECUTE ipe_hook=BPRM_CHECK enforcing=0 pid=%s path="%s" rule="DEFAULT op=EXECUTE action=DENY"\n' \
            "${pid}" "${target}" > "${directory}/audit.log"
        ipe_report_probe "${directory}" "${name}" "${target}" deny pass
        printf 'IPE_ACCESS ipe_op=EXECUTE ipe_hook=MMAP enforcing=0 pid=%s path="/usr/lib64/libc.so.6" rule="DEFAULT op=EXECUTE action=DENY"\n' \
            "${pid}" > "${directory}/audit.log"
        if output="$(ipe_report_probe "${directory}" "${name}" "${target}" allow pass)"; then
            echo "Signed ${name} passed with a dependency denial" >&2
            return 1
        fi
        grep -Fq 'result=FAIL' <<< "${output}"
    done
)

test_probe_matrix_summary() (
    local directory output pid
    directory="$(mktemp -d)"
    trap 'rm -rf -- "${directory}"' EXIT
    ipe_run_probe "${directory}" base bash -c ':'
    ipe_run_probe "${directory}" writable bash -c ':'
    pid="$(cat "${directory}/writable.pid")"
    printf 'IPE_ACCESS ipe_op=EXECUTE ipe_hook=BPRM_CHECK enforcing=0 pid=%s path="/var/tmp/probe" rule="DEFAULT op=EXECUTE action=DENY"\n' \
        "${pid}" > "${directory}/audit.log"
    output="$(ipe_report_probe_matrix "${directory}" pass base /usr/bin/bash allow writable /var/tmp/probe deny)"
    [[ "${output}" == *'OVERALL: PASS'*'IPE verification'*'=== Probe: base ==='*'=== Probe: writable ==='* ]]
    grep -Eq '^base +PASS +PASS$' <<< "${output}"
    grep -Eq '^writable +PASS +PASS$' <<< "${output}"

    : > "${directory}/audit.log"
    if output="$(ipe_report_probe_matrix "${directory}" pass base /usr/bin/bash allow writable /var/tmp/probe deny)"; then
        echo "Matrix passed without an expected denial" >&2
        return 1
    fi
    grep -Eq '^writable +PASS +FAIL$' <<< "${output}"

    printf "Failed to parse boot descriptor 'example'\n" > "${directory}/audit-error.log"
    if output="$(ipe_report_probe_matrix "${directory}" fail base /usr/bin/bash allow writable /var/tmp/probe deny)"; then
        echo "Matrix passed without audit telemetry" >&2
        return 1
    fi
    [[ "${output}" == *'OVERALL: FAIL - audit collection failed'*'Failed to parse boot descriptor'*'IPE verification'*'=== Probe: base ==='* ]]
    [[ "$(grep -c 'Failed to parse boot descriptor' <<< "${output}")" == 1 ]]
    grep -Eq '^base +PASS +UNVERIFIED$' <<< "${output}"
    grep -Eq '^writable +PASS +UNVERIFIED$' <<< "${output}"
    grep -Fq 'observed=UNKNOWN' <<< "${output}"

    ipe_run_probe "${directory}" failure bash -c 'exit 7'
    if output="$(ipe_report_probe_matrix "${directory}" pass failure /usr/bin/bash allow)"; then
        echo "Matrix passed with failed execution" >&2
        return 1
    fi
    grep -Eq '^failure +FAIL +UNVERIFIED$' <<< "${output}"
    rm "${directory}/base.stdout"
    if output="$(ipe_report_probe_matrix "${directory}" pass base /usr/bin/bash allow)"; then
        echo "Matrix passed with missing output" >&2
        return 1
    fi
    grep -Eq '^base +ERROR +UNVERIFIED$' <<< "${output}"
    grep -Fq 'reason=missing-stdout' <<< "${output}"
)

test_inventory
test_target_events
test_probe_payload
test_capture
test_execution_and_reporting
test_probe_command_and_output_logging
test_base_probes
test_probe_matrix_summary
echo "IPE audit probe tests passed"
