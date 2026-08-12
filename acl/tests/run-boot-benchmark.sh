#!/bin/bash
# Measure node boot time across repeated reboots.
#
# Runs on the host against an already-provisioned VM, because the thing being
# measured is the boot itself: an in-VM script only ever sees the one boot that
# happened to run it. Rebooting from the host is what turns boot time from an
# anecdote into a distribution.
#
# This is the general-perf counterpart to run-critest-benchmark.sh. Where that
# one measures the container lifecycle, this measures what the node costs before
# it can run any container at all — which is the number the IPE and dm-verity
# axes are most likely to move, since IPE loads a signed policy from the
# initramfs and verity sets up the root device, both of them pre-userspace.
#
# Emits the same results document as run-critest-benchmark.sh; the contract is
# described in acl/tests/PERF-RESULTS.md.

set -uo pipefail

source "${SCRIPT_DIR}/acl/validate/validate_common.sh"

# validate_common.sh sets `-euo pipefail`, so sourcing it silently turns on the
# errexit this script deliberately left off two lines above. That matters here
# more than anywhere else: every node probe below is a `$(ssh_cmd ... | tr)`
# pipeline, and with errexit and pipefail both on, one transient SSH failure
# kills the script mid-probe with no message at all -- not even from the guards
# written to explain exactly that situation, because they never get to run.
#
# Build 1179949 died this way: 10.7 seconds of total silence between "SSH
# connection established!" and the harness reporting a failed host script, with
# nothing on stdout or stderr to say which probe failed or why.
#
# This script handles its own failures explicitly (see the guards below), so
# restore the intended behaviour rather than removing the guards' reason to
# exist.
set +e

# Each sample costs a full reboot plus SSH reconnect, so this trades wall clock
# for confidence directly. Five is enough to see a p50 move without doubling the
# stage runtime.
BOOT_SAMPLES="${BOOT_SAMPLES:-5}"

# Units whose start time says something about node readiness rather than about
# systemd itself. Missing units are skipped, so this list is safe to over-specify
# across image variants that do not all ship the same services.
BOOT_UNITS="${BOOT_UNITS:-containerd.service kubelet.service multi-user.target}"

RESULTS_JSON="${PERF_RESULTS_JSON:-${DIAGNOSTICS_DIR:-/tmp}/boot-results.json}"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SAMPLES_RAW="$(mktemp)"
trap 'rm -f "$SAMPLES_RAW"' EXIT

# systemd only publishes FinishTimestampMonotonic once startup has settled, so
# reading too early yields 0 and would silently look like an impossibly fast boot.
wait_for_boot_complete() {
    local deadline=$(( $(date +%s) + 180 )) state
    while (( $(date +%s) < deadline )); do
        state=$(ssh_cmd 'systemctl is-system-running' 2>/dev/null | tr -d '\r')
        # "degraded" still means startup finished; some units failing is a
        # correctness question, not a timing one, and is caught by the health test.
        [[ "$state" == "running" || "$state" == "degraded" ]] && return 0
        sleep 3
    done
    warn "system never reported startup complete; skipping this sample"
    return 1
}

# Read raw monotonic microsecond timestamps rather than parsing the prose from
# `systemd-analyze time`, whose wording has changed between systemd releases.
collect_sample() {
    ssh_cmd "systemctl show -p FirmwareTimestampMonotonic -p LoaderTimestampMonotonic \
             -p InitRDTimestampMonotonic -p UserspaceTimestampMonotonic \
             -p FinishTimestampMonotonic 2>/dev/null;
             for u in ${BOOT_UNITS}; do
                 systemctl show \"\$u\" -p Id -p ActiveEnterTimestampMonotonic 2>/dev/null \
                   | sed \"s/^/UNIT_\$u|/\";
             done" 2>/dev/null | tr -d '\r'
}

main() {
    parse_validate_args "$@"
    section "Boot Time Benchmark"

    read_vm_state
    setup_ssh_opts

    info "VM: ${VM_NAME} (RG: ${VM_RG:-n/a}, IP: ${VM_IP})"
    info "Samples: ${BOOT_SAMPLES} reboots"
    info "Units:   ${BOOT_UNITS}"

    if ! wait_for_ssh "$VM_IP" "$VM_SSH_TIMEOUT"; then
        error "Cannot reach VM via SSH"
        # The VM was alive moments ago — the benchmarks that ran before this
        # one used it. Something took it down in between, and the resource
        # group is deleted as soon as the suite finishes, so the serial
        # console has to be read now or the evidence is gone.
        capture_vm_diagnostics "$VM_IP" "boot-benchmark-unreachable"
        exit 1
    fi

    # Node identity is read once, from the VM, for the same reason the critest
    # harness reads it: a number is only comparable if you know what produced it.
    #
    # Each probe records its SSH exit status. The `2>/dev/null` below is there to
    # keep SSH's banner noise out of the values, but it also discards the reason
    # a probe came back empty, and an empty value is exactly what the guards
    # further down refuse to publish on. Keeping the status costs nothing and is
    # the difference between "the IPE probe was blank" and "SSH exited 255".
    NODE_IMAGE=$(ssh_cmd '. /etc/os-release 2>/dev/null; echo "${IMAGE_ID:-${ID:-unknown}} ${IMAGE_VERSION:-${VERSION_ID:-}}"' 2>/dev/null | tr -d '\r')
    local rc_image=$?
    NODE_KERNEL=$(ssh_cmd 'uname -r' 2>/dev/null | tr -d '\r')
    local rc_kernel=$?
    NODE_SELINUX=$(ssh_cmd 'getenforce 2>/dev/null || echo unknown' 2>/dev/null | tr -d '\r')
    NODE_CONTAINERD=$(ssh_cmd 'containerd --version 2>/dev/null | awk "{print \$3}"' 2>/dev/null | tr -d '\r')

    # Which cell of the IPE x EROFS matrix this node actually is. Boot time is
    # the one suite where both axes are expected to move the number and neither
    # is otherwise visible in the output, so without this a run of I1E1 and a run
    # of I0E0 produce results that are impossible to tell apart afterwards.
    #
    # Both are measured on the node rather than read from the build parameters.
    # A parameter says what was requested; only the node says what shipped, and
    # the whole failure mode being guarded against here is the two disagreeing.
    # Read under sudo: securityfs directories are traversable but the attribute
    # files themselves are root-only, so an unprivileged probe still globs the
    # policy directory and then fails every read -- reporting "enforce=?
    # success_audit=? policies=none" on a node whose IPE is loaded and active.
    NODE_IPE=$(ssh_cmd 'b=/sys/kernel/security/ipe
        if [ -d "$b" ]; then
            e=$(sudo cat "$b/enforce" 2>/dev/null || echo "?")
            s=$(sudo cat "$b/success_audit" 2>/dev/null || echo "?")
            a=$(for p in "$b"/policies/*/; do
                    [ -f "${p}active" ] || continue
                    [ "$(sudo cat "${p}active" 2>/dev/null)" = "1" ] || continue
                    basename "$p"
                done | paste -sd, -)
            echo "on enforce=${e} success_audit=${s} policies=${a:-none}"
        else
            echo "off"
        fi' 2>/dev/null | tr -d '\r')
    local rc_ipe=$?
    # The 90-acl-profile.conf drop-in ships only in the containerd2-erofs
    # subpackage, so its presence is exactly the EROFS axis -- and unlike a
    # snapshotter probe it needs no image pull, which this suite never does.
    NODE_EROFS=$(ssh_cmd 'if [ -e /usr/lib/systemd/system/containerd.service.d/90-acl-profile.conf ]; then echo on; else echo off; fi' 2>/dev/null | tr -d '\r')
    local rc_erofs=$?

    # Whether the dm-verity trust anchor actually reached the running kernel.
    # validate_azure.sh enrolls the OS Guard CA into the SIG image version's
    # UEFI db, and LOAD_UEFI_KEYS is then supposed to import db into .platform
    # at boot. AzureLinux leaves CONFIG_SYSTEM_TRUSTED_KEYS empty and sets
    # DM_VERITY_VERIFY_ROOTHASH_SIG_PLATFORM_KEYRING, so .platform is the only
    # keyring a signed layer's root-hash signature can be checked against.
    #
    # Every link in that chain has been assumed rather than measured. It is
    # worth measuring because a missing anchor does not fail at boot: the layer
    # signature is only checked when the verity table is loaded, so it surfaces
    # much later as EKEYREJECTED at container start, which reads like an
    # unrelated runtime fault. Recording it here attributes it in one line.
    #
    # awk rather than `grep -c` on purpose: grep prints 0 and *also* exits 1
    # when it matches nothing, which is the common case being probed for.
    NODE_ANCHOR=$(ssh_cmd 'if ! command -v keyctl >/dev/null 2>&1; then
            echo "unknown (keyctl absent)"
        elif ! k=$(sudo keyctl list %:.platform 2>/dev/null); then
            echo "unknown (.platform unreadable)"
        else
            n=$(printf "%s\n" "$k" | awk "/OS Guard CA/{c++} END{print c+0}")
            t=$(printf "%s\n" "$k" | awk "/asymmetric/{c++} END{print c+0}")
            if [ "$n" -gt 0 ]; then echo "present (${n} of ${t} keys)"
            else echo "absent (${t} keys in .platform)"; fi
        fi' 2>/dev/null | tr -d '\r')

    # Verity devices actually active. On an E1 arm with signed layers this is
    # the difference between "erofs is configured" -- which is all the
    # 90-acl-profile.conf probe above can tell you -- and "erofs is verifying".
    NODE_VERITY=$(ssh_cmd 'if command -v dmsetup >/dev/null 2>&1; then
            sudo dmsetup ls --target verity 2>/dev/null | awk "!/No devices/&&NF{c++} END{print c+0}"
        else echo unknown; fi' 2>/dev/null | tr -d '\r')

    # "off" is a legitimate arm; blank is not. A blank value means the probe
    # itself failed, and an unlabelled boot number is worse than no number --
    # it will sit in a results table looking like data.
    if [[ -z "${NODE_IPE}" || -z "${NODE_EROFS}" ]]; then
        error "could not determine the IPE/EROFS matrix cell for this node" \
              "(ipe='${NODE_IPE}' erofs='${NODE_EROFS}')"
        error "probe ssh exit status: image=${rc_image} kernel=${rc_kernel}" \
              "ipe=${rc_ipe} erofs=${rc_erofs} (255 means SSH itself failed)"
        error "refusing to publish boot numbers that cannot be attributed to an arm"
        exit 1
    fi

    # A "?" is the probe reporting that a read failed, which the blank check
    # above does not catch: the string is non-empty and looks like an answer.
    # "policies=none" is deliberately not fatal here -- IPE present with nothing
    # loaded is a real arm -- but an unreadable enforce leaves the IPE axis
    # genuinely unknown, which is the one thing this label exists to record.
    if [[ "${NODE_IPE}" == *"=?"* ]]; then
        error "IPE state could not be read from this node: '${NODE_IPE}'"
        error "refusing to publish boot numbers that cannot be attributed to an arm"
        exit 1
    fi

    info "Node image: ${NODE_IMAGE}"
    info "Kernel:     ${NODE_KERNEL}"
    info "IPE:        ${NODE_IPE}"
    info "EROFS:      ${NODE_EROFS}"
    info "Anchor:     ${NODE_ANCHOR:-unknown} (OS Guard CA in .platform)"
    info "Verity dev: ${NODE_VERITY:-unknown}"
    # Not fatal: "no anchor" is the correct state on an E0 arm, and on an E1 arm
    # it is a finding to record rather than a reason to throw away good boot
    # numbers. Warn loudly instead, because the failure it predicts appears far
    # from here.
    if [[ "${NODE_EROFS}" == "on" && "${NODE_ANCHOR}" == absent* ]]; then
        warn "EROFS is on but the OS Guard CA is not in .platform:" \
             "signed dm-verity layers will fail the table load with EKEYREJECTED"
    fi

    # The boot that is already running is the provisioning boot: it carries
    # first-boot work (cloud-init, disk growth, image specialization) that never
    # recurs, so including it would bias every run upward by a constant nobody
    # experiences twice. Measure only reboots.
    info "Discarding the provisioning boot; measuring ${BOOT_SAMPLES} reboots"

    local collected=0 i
    for (( i = 1; i <= BOOT_SAMPLES; i++ )); do
        info "--- sample ${i}/${BOOT_SAMPLES}"
        if ! reboot_and_wait; then
            warn "sample ${i}: reboot failed; stopping collection"
            break
        fi
        if ! wait_for_boot_complete; then
            continue
        fi
        {
            echo "=== SAMPLE ${i}"
            echo "RebootWallClockMs=${REBOOT_WALL_MS:-0}"
            collect_sample
        } >> "$SAMPLES_RAW"
        collected=$(( collected + 1 ))
    done

    if (( collected == 0 )); then
        error "collected no boot samples"
        exit 1
    fi
    info "Collected ${collected}/${BOOT_SAMPLES} samples"

    ACL_NODE_IMAGE="$NODE_IMAGE" \
    ACL_KERNEL="$NODE_KERNEL" \
    ACL_SELINUX="$NODE_SELINUX" \
    ACL_CONTAINERD="$NODE_CONTAINERD" \
    ACL_IPE="$NODE_IPE" \
    ACL_EROFS="$NODE_EROFS" \
    ACL_ANCHOR="$NODE_ANCHOR" \
    ACL_VERITY="$NODE_VERITY" \
    ACL_STARTED_AT="$STARTED_AT" \
    ACL_BOOT_UNITS="$BOOT_UNITS" \
    python3 - "$SAMPLES_RAW" "$RESULTS_JSON" <<'PY'
import json, os, sys, time

raw_path, results_path = sys.argv[1], sys.argv[2]

# Parse the per-sample `systemctl show` output back into one dict per boot.
samples, current = [], None
with open(raw_path, errors='replace') as fh:
    for line in fh:
        line = line.strip()
        if line.startswith('=== SAMPLE'):
            current = {}
            samples.append(current)
            continue
        if current is None or '=' not in line:
            continue
        key, _, value = line.partition('=')
        current[key.strip()] = value.strip()

def usec(sample, key):
    try:
        return int(sample.get(key, '') or 0)
    except ValueError:
        return 0

# systemd's monotonic clock starts when the kernel starts, so each timestamp is
# an offset from kernel start and the phases are the gaps between them.
# Firmware/loader sit before that epoch and are reported separately; on cloud VMs
# they are frequently absent, so they are only emitted when actually present.
def phases(sample):
    initrd_start = usec(sample, 'InitRDTimestampMonotonic')
    userspace_start = usec(sample, 'UserspaceTimestampMonotonic')
    finish = usec(sample, 'FinishTimestampMonotonic')
    if finish <= 0 or userspace_start <= 0:
        return None

    out = {}
    firmware = usec(sample, 'FirmwareTimestampMonotonic')
    loader = usec(sample, 'LoaderTimestampMonotonic')
    if firmware > loader > 0:
        out['Firmware'] = firmware - loader
    if loader > 0:
        out['Loader'] = loader

    # No initrd means the kernel hands straight to userspace; reporting an
    # Initrd phase of 0 in that case would imply a stage that does not exist.
    if initrd_start > 0:
        out['Kernel'] = initrd_start
        out['Initrd'] = userspace_start - initrd_start
    else:
        out['Kernel'] = userspace_start
    out['Userspace'] = finish - userspace_start
    # systemd-analyze counts firmware and loader toward the total, so include
    # them when the platform exposed them. Otherwise 'Total' quietly means
    # "since kernel start" and would disagree with what `systemd-analyze time`
    # prints on the very same machine.
    out['Total'] = finish + out.get('Firmware', 0) + out.get('Loader', 0)

    # Host-observed wall clock for the whole reboot. It is a superset of Total:
    # it also covers shutdown and the pre-kernel segments (platform firmware,
    # systemd-boot, UKI stub) that run before any monotonic clock exists and
    # that systemd therefore cannot report on this platform. Keeping it means
    # the unaccounted time is visible as Wallclock - Total instead of being
    # silently dropped.
    wall = sample.get('RebootWallClockMs')
    if wall:
        try:
            wall_usec = float(wall) * 1000.0
            if wall_usec > 0:
                out['RebootWallClock'] = wall_usec
        except ValueError:
            pass
    return out

# Unit readiness, keyed by the unit's own Id so a missing unit cannot silently
# borrow the previous unit's timestamp.
def unit_times(sample):
    out = {}
    for key, value in sample.items():
        if not key.startswith('UNIT_'):
            continue
        requested, _, field = key[len('UNIT_'):].partition('|')
        if field != 'ActiveEnterTimestampMonotonic':
            continue
        try:
            enter = int(value or 0)
        except ValueError:
            continue
        if enter > 0:
            out[f'unit:{requested}'] = enter
    return out

series = {}
for sample in samples:
    measured = phases(sample)
    if measured is None:
        continue
    measured.update(unit_times(sample))
    for name, value in measured.items():
        series.setdefault(name, []).append(value)

def pct(ordered, p):
    if not ordered:
        return None
    k = max(0, min(len(ordered) - 1, int(round((len(ordered) - 1) * p / 100.0))))
    return round(ordered[k] / 1e3, 2)  # microseconds -> milliseconds

node = {
    'image': os.environ.get('ACL_NODE_IMAGE', '').strip(),
    'kernel': os.environ.get('ACL_KERNEL', ''),
    'containerd': os.environ.get('ACL_CONTAINERD', ''),
    'selinux': os.environ.get('ACL_SELINUX', ''),
    # The matrix cell, as measured on the node. 'ipe' is the raw probe string
    # rather than a bool because "IPE is loaded but enforce=0 and no policy is
    # active" is a distinct and very easy state to mistake for a working arm.
    'ipe': os.environ.get('ACL_IPE', ''),
    'erofs': os.environ.get('ACL_EROFS', ''),
    # Whether the dm-verity root-hash anchor and any verified device were
    # actually observed, as opposed to merely configured. Kept as raw strings
    # for the same reason as 'ipe': "unknown" and "absent" are different
    # answers, and collapsing either to a bool loses the one that matters.
    'verityAnchor': os.environ.get('ACL_ANCHOR', ''),
    'verityDevices': os.environ.get('ACL_VERITY', ''),
    'matrixCell': 'I{}E{}'.format(
        1 if os.environ.get('ACL_IPE', '').startswith('on') else 0,
        1 if os.environ.get('ACL_EROFS', '') == 'on' else 0),
}

# Phases first and in boot order, then units; sorting alphabetically would put
# Userspace before Kernel and make the table read as nonsense.
ORDER = ['Firmware', 'Loader', 'Kernel', 'Initrd', 'Userspace', 'Total',
         'RebootWallClock']
def rank(name):
    return (ORDER.index(name), '') if name in ORDER else (len(ORDER), name)

metrics = []
for name in sorted(series, key=rank):
    ordered = sorted(series[name])
    metrics.append({
        'suite': 'boot',
        'image': '',
        'operation': name,
        # This suite pulls no images, so there is no snapshotter to report --
        # leaving it blank is the honest answer. The arm is carried by
        # matrixCell instead, on every row, so a flattened results table cannot
        # lose which configuration produced the number.
        'snapshotter': '',
        'matrixCell': node['matrixCell'],
        'nodeImage': node['image'],
        'containerd': node['containerd'],
        'unit': 'ms',
        'n': len(ordered),
        'minMs': pct(ordered, 0),
        'p50Ms': pct(ordered, 50),
        'maxMs': pct(ordered, 100),
        # The measurements themselves. min/median/max are each an actual
        # observation, but they are still a summary; these are the data.
        'samplesMs': [round(v / 1e3, 2) for v in ordered],
    })

print(f"\n--- Boot time over {len(series.get('Total', []))} reboots "
      f"(node: {node['image'] or 'unknown'}, arm: {node['matrixCell']})")
print(f"      IPE: {node['ipe']}   EROFS: {node['erofs']}")
print(f"      dm-verity anchor: {node['verityAnchor'] or 'unknown'}"
      f"   active verity devices: {node['verityDevices'] or 'unknown'}")
print(f"      {'phase':<28} {'n':>3} {'min ms':>10} {'med ms':>10} {'max ms':>10}   samples (ms)")
for row in metrics:
    print(f"      {row['operation']:<28} {row['n']:>3} {row['minMs']:>10} "
          f"{row['p50Ms']:>10} {row['maxMs']:>10}   "
          f"{' '.join(str(v) for v in row['samplesMs'])}")

# Say plainly which phases this run actually covered. Firmware and loader come
# from the boot loader's EFI variables, not from the monotonic clock, so their
# absence is a property of the platform rather than a fast boot -- and without
# saying so, a Total that begins at kernel start is indistinguishable from one
# that begins at power-on.
covered = {row['operation']: row for row in metrics}
if 'Firmware' in covered or 'Loader' in covered:
    print("      coverage: Total includes firmware/loader (EFI loader variables present)")
else:
    print("      coverage: no EFI loader variables on this platform, so Total covers "
          "kernel onward and excludes firmware/boot-loader time")
    # Quantify what is missing rather than only naming it. The gap is shutdown
    # plus firmware, systemd-boot and the UKI stub; reporting it means a reader
    # can judge whether the blind spot is material instead of assuming.
    if 'RebootWallClock' in covered and 'Total' in covered:
        gap = round(covered['RebootWallClock']['p50Ms'] - covered['Total']['p50Ms'], 2)
        print(f"      coverage: RebootWallClock - Total = {gap} ms unaccounted at the "
              f"median (shutdown + firmware + boot loader + UKI stub)")

document = {
    'schemaVersion': 1,
    'run': {
        'startedAt': os.environ.get('ACL_STARTED_AT', ''),
        'finishedAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'suites': ['boot'],
    },
    'node': node,
    'metrics': metrics,
    'suites': {},
}

try:
    with open(results_path, 'w') as fh:
        json.dump(document, fh, indent=2, sort_keys=True)
    print(f"\nResults written to {results_path} ({len(metrics)} metric rows)")
except OSError as exc:
    print(f"\ncould not write {results_path}: {exc}", file=sys.stderr)

print("ACL_PERF_RESULTS=" + json.dumps(document, sort_keys=True))

if not metrics:
    print("no boot samples produced usable timings", file=sys.stderr)
    sys.exit(1)
PY
    rc=$?

    if [[ $rc -ne 0 ]]; then
        error "Boot benchmark failed"
        exit $rc
    fi
    info "✅ Boot benchmark complete"
}

main "$@"
