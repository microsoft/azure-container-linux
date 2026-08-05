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

SSH_OPTS=()
setup_ssh_opts() {
    SSH_OPTS=(
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o BatchMode=yes
        -o ConnectTimeout=10
        -i "$VM_SSH_KEY"
    )
}

ssh_cmd() { ssh "${SSH_OPTS[@]}" "${VM_SSH_USER}@${VM_IP}" "$@"; }

boot_id() { ssh_cmd 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null; }

# Reboot and wait for the boot_id to change. Waiting on SSH alone is not enough:
# the outgoing sshd can still answer while the machine is shutting down, which
# would attribute the previous boot's numbers to this sample.
reboot_and_wait() {
    local old new
    old=$(boot_id) || { error "Cannot read boot_id — VM unreachable?"; return 1; }
    info "Rebooting ${VM_NAME} (old boot_id=${old})..."
    ssh_cmd "sudo systemctl reboot" || true
    local deadline=$(( $(date +%s) + VM_SSH_TIMEOUT ))
    while (( $(date +%s) < deadline )); do
        new=$(boot_id) && [[ -n "$new" && "$new" != "$old" ]] && {
            info "Back up (new boot_id=${new})"
            return 0
        }
        sleep 2
    done
    error "VM did not come back within ${VM_SSH_TIMEOUT}s"
    return 1
}

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
        exit 1
    fi

    # Node identity is read once, from the VM, for the same reason the critest
    # harness reads it: a number is only comparable if you know what produced it.
    NODE_IMAGE=$(ssh_cmd '. /etc/os-release 2>/dev/null; echo "${IMAGE_ID:-${ID:-unknown}} ${IMAGE_VERSION:-${VERSION_ID:-}}"' 2>/dev/null | tr -d '\r')
    NODE_KERNEL=$(ssh_cmd 'uname -r' 2>/dev/null | tr -d '\r')
    NODE_SELINUX=$(ssh_cmd 'getenforce 2>/dev/null || echo unknown' 2>/dev/null | tr -d '\r')
    NODE_CONTAINERD=$(ssh_cmd 'containerd --version 2>/dev/null | awk "{print \$3}"' 2>/dev/null | tr -d '\r')

    info "Node image: ${NODE_IMAGE}"
    info "Kernel:     ${NODE_KERNEL}"

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
    out['Total'] = finish
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
}

# Phases first and in boot order, then units; sorting alphabetically would put
# Userspace before Kernel and make the table read as nonsense.
ORDER = ['Firmware', 'Loader', 'Kernel', 'Initrd', 'Userspace', 'Total']
def rank(name):
    return (ORDER.index(name), '') if name in ORDER else (len(ORDER), name)

metrics = []
for name in sorted(series, key=rank):
    ordered = sorted(series[name])
    metrics.append({
        'suite': 'boot',
        'image': '',
        'operation': name,
        'snapshotter': '',
        'nodeImage': node['image'],
        'containerd': node['containerd'],
        'unit': 'ms',
        'n': len(ordered),
        'minMs': pct(ordered, 0),
        'p50Ms': pct(ordered, 50),
        'p95Ms': pct(ordered, 95),
        'maxMs': pct(ordered, 100),
    })

print(f"\n--- Boot time over {len(series.get('Total', []))} reboots "
      f"(node: {node['image'] or 'unknown'})")
print(f"      {'phase':<36} {'n':>4} {'p50 ms':>10} {'p95 ms':>10} {'max ms':>10}")
for row in metrics:
    print(f"      {row['operation']:<36} {row['n']:>4} {row['p50Ms']:>10} "
          f"{row['p95Ms']:>10} {row['maxMs']:>10}")

document = {
    'schemaVersion': 1,
    'critestRc': 0,
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
