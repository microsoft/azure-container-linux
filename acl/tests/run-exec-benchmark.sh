#!/bin/bash
# Measure the cost IPE adds to the exec path, on the node itself.
#
# This is general-perf: no containerd, no CNI, no kubelet, no registry. It only
# starts processes and loads shared libraries, because that is the entire
# surface IPE taxes. From the kernel's IPE documentation:
#
#   "For compiled executables, enforcement is triggered automatically by the
#    kernel during execve(), execveat(), mmap() and mprotect() syscalls when
#    loading executable content."
#
# There is deliberately no read() or stat() measurement here. IPE has no hook on
# either, and dm-verity hashes blocks at the device-mapper layer whether IPE is
# loaded or not, so a read benchmark cannot move when IPE is toggled. An earlier
# revision of this script measured reads of /usr and presented them as an IPE and
# EROFS metric; they were neither. EROFS in this matrix is a *containerd
# snapshotter* choice that applies to container layers, not to the host rootfs,
# so /usr is byte-identical on every arm and those rows could only ever have
# reported disk noise.
#
# What ACL ships (uki_install.sh: "ipe.enforce=0 ipe.success_audit=0") decides
# the shape of the measurement:
#
#   enforce=0        Permissive. Violations are logged, not blocked. So a binary
#                    that fails the policy still runs -- which is what makes an
#                    in-run control possible at all.
#   success_audit=0  Allowed execs emit no audit record. Only violations do.
#
# Against the shipped policy:
#
#   DEFAULT                             action=ALLOW
#   DEFAULT op=EXECUTE                  action=DENY
#   op=EXECUTE boot_verified=TRUE       action=ALLOW
#   op=EXECUTE dmverity_signature=TRUE  action=ALLOW
#
# that gives two distinct exec paths on one machine:
#
#   verity      a binary under /usr matches dmverity_signature=TRUE -> ALLOW.
#               Cost is rule evaluation only, and nothing is audited.
#   unverified  the same binary copied to a writable filesystem matches no ALLOW
#               rule, falls through to DEFAULT DENY, and under enforce=0 runs
#               anyway -- paying rule evaluation *plus* an audit record.
#
# The difference between those two is the cost of an IPE audit event, measured
# inside a single run on a single VM. That matters: it cancels VM, disk and
# noisy-neighbour variation instead of relying on comparing absolute numbers
# across arms that ran on different machines on different days.
#
# ACL ships no auditd, so those records go to printk and land in the kernel ring
# buffer (the same place run-selinux-avc-test.sh looks for AVC denials). printk
# is rate limited, so the record count is reported too -- if the kernel starts
# suppressing messages the measured audit cost is an undercount, and the run says
# so rather than quietly reporting a small number.
#
# ---------------------------------------------------------------------------
# Why stress-ng, and why the `spawn` stressor specifically
#
# The measurement is stress-ng rather than a hand-rolled exec loop. Its own
# manual says it is "never intended to be used as a precise benchmark test
# suite", but sanctions exactly the use here: "useful to
# observe performance changes across different operating system releases". So
# this reports *relative* differences between two configurations on one machine
# and does not claim absolute per-execve latency. For an absolute figure the
# canonical tools are lmbench lat_proc and `perf bench syscall execve`; neither is
# packaged for Azure Linux today.
#
# The stressor choice is not cosmetic. Both `exec` and `spawn` re-execute
# /proc/self/exe, so running a *copy* of stress-ng is what moves the exec off the
# verity device -- there is no --exec-path option in the packaged 0.17.06.
# But strace of the `exec` stressor shows it also writes a temporary copy of
# itself into the current working directory and execs that, roughly one exec in
# five:
#
#   327 execve("/tmp/sng-copy/stress-ng"
#    73 execve("./tmp-stress-ng-exec-<pid>-0/stress-ng-exec-...")
#
# That temp copy necessarily lives on a writable filesystem, so it is unverified
# even when the stressor binary itself is on /usr. It would have quietly mixed
# audited execs into the supposedly-clean ALLOW baseline. `spawn` has no such
# behaviour -- every bogo op is exactly one execve of the binary's own resolved
# path:
#
#   execve("/tmp/sng-copy/stress-ng", ["...", "--exec-exit"]) = 0
#
# so one bogo op is one execve of a binary whose backing device we chose.
# ---------------------------------------------------------------------------
#
# Emits the results document described in acl/tests/PERF-RESULTS.md.
#
# Tunables (env):
#   ACL_EXEC_SCRATCH      writable dir for the unverified copy (default /var/tmp/acl-execperf)
#   ACL_EXEC_OPS          execs per repetition      (default 400)
#   ACL_EXEC_REPS         repetitions per scenario  (default 7)
#   ACL_EXEC_DYNLIB_OPS   dlopen ops per repetition (default 200)
#   ACL_EXEC_KEEP_SCRATCH leave the copy in place   (default false)

# No `set -e`: a suite that cannot run should drop its rows and let the rest of
# the document through, the same way the boot suite omits phases the platform
# does not expose.
set -uo pipefail

SCRATCH="${ACL_EXEC_SCRATCH:-/var/tmp/acl-execperf}"
EXEC_OPS="${ACL_EXEC_OPS:-400}"
EXEC_REPS="${ACL_EXEC_REPS:-7}"
DYNLIB_OPS="${ACL_EXEC_DYNLIB_OPS:-200}"
KEEP_SCRATCH="${ACL_EXEC_KEEP_SCRATCH:-false}"

RESULTS_JSON="${PERF_RESULTS_JSON:-/var/tmp/exec-results.json}"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

NODE_IMAGE="$( . /etc/os-release 2>/dev/null; echo "${IMAGE_ID:-${ID:-unknown}} ${IMAGE_VERSION:-${VERSION_ID:-}}" )"
NODE_KERNEL="$(uname -r)"
NODE_SELINUX="$(getenforce 2>/dev/null || echo unknown)"
NODE_CONTAINERD="$(containerd --version 2>/dev/null | awk '{print $3}')"

echo "=== Exec benchmark (IPE) ==="
echo "  scratch: ${SCRATCH}"
echo "  node:    ${NODE_IMAGE} (kernel ${NODE_KERNEL})"

if ! command -v stress-ng >/dev/null 2>&1; then
    echo "[WARN] stress-ng not present; exec benchmark cannot run"
    echo "[WARN] it must be on the verity-backed rootfs, which means building"
    echo "[WARN] the image with ACL_PERF_TOOLS=1. A sysext will not do: the"
    echo "[WARN] binary would resolve but would not be verity-backed, and the"
    echo "[WARN] suite would report a zero IPE cost that is pure artifact."
fi

ACL_NODE_IMAGE="$NODE_IMAGE" \
ACL_KERNEL="$NODE_KERNEL" \
ACL_SELINUX="$NODE_SELINUX" \
ACL_CONTAINERD="$NODE_CONTAINERD" \
ACL_STARTED_AT="$STARTED_AT" \
ACL_EXEC_SCRATCH="$SCRATCH" \
ACL_EXEC_OPS="$EXEC_OPS" \
ACL_EXEC_REPS="$EXEC_REPS" \
ACL_EXEC_DYNLIB_OPS="$DYNLIB_OPS" \
ACL_EXEC_KEEP_SCRATCH="$KEEP_SCRATCH" \
python3 - "$RESULTS_JSON" <<'PY'
import json, os, re, shutil, subprocess, sys, tempfile, time

results_path = sys.argv[1]

SCRATCH    = os.environ['ACL_EXEC_SCRATCH']
EXEC_OPS   = int(os.environ['ACL_EXEC_OPS'])
REPS       = int(os.environ['ACL_EXEC_REPS'])
DYNLIB_OPS = int(os.environ['ACL_EXEC_DYNLIB_OPS'])
KEEP       = os.environ.get('ACL_EXEC_KEEP_SCRATCH', 'false') == 'true'

notes = []


def run(cmd, timeout=600):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except Exception as exc:
        return 1, '', str(exc)


# ---------------------------------------------------------------- environment

def stress_ng_path():
    return shutil.which('stress-ng')


def stress_ng_version(binary):
    rc, out, err = run([binary, '--version'], timeout=30)
    if rc != 0:
        return None
    text = (out or err).strip()
    match = re.search(r'version\s+(\S+)', text)
    return match.group(1) if match else (text.split()[-1] if text else None)


def supports_spawn(binary):
    rc, _, _ = run([binary, '--spawn', '1', '--spawn-ops', '1', '--timeout', '10'],
                   timeout=60)
    return rc == 0


def ipe_state():
    """Record what IPE is actually doing. A number from a machine where IPE never
    loaded is not a no-IPE data point, it is a broken run, and the two have to be
    distinguishable after the fact."""
    base = '/sys/kernel/security/ipe'
    state = {'present': os.path.isdir(base)}
    if not state['present']:
        return state

    def read(path):
        try:
            with open(path) as fh:
                return fh.read().strip()
        except Exception:
            return None

    state['enforce'] = read(os.path.join(base, 'enforce'))
    state['successAudit'] = read(os.path.join(base, 'success_audit'))
    policies = os.path.join(base, 'policies')
    active = []
    if os.path.isdir(policies):
        try:
            for name in sorted(os.listdir(policies)):
                if read(os.path.join(policies, name, 'active')) == '1':
                    active.append(name)
        except Exception:
            pass
    state['activePolicies'] = active
    return state


def cmdline_ipe():
    try:
        with open('/proc/cmdline') as fh:
            return sorted(t for t in fh.read().split() if t.startswith('ipe.'))
    except Exception:
        return []


def backing_device(path):
    """Which device backs a path. The whole verity/unverified split rests on the
    two binaries sitting on different devices, so it is recorded rather than
    assumed -- if a future image puts /var/tmp on the same verity device this
    benchmark must report that instead of a confident zero."""
    rc, out, _ = run(['findmnt', '-n', '-o', 'SOURCE,FSTYPE', '--target', path],
                     timeout=30)
    if rc != 0 or not out.strip():
        return None
    return out.strip().splitlines()[0].strip()


def verity_backed(path):
    """Whether a path is actually on a dm-verity device.

    The verity arm is only a verity arm if the kernel really verified the bytes.
    Everything about this benchmark reads the same whether that is true or not:
    the binary still resolves under /usr, still runs, still produces timings --
    the delta just quietly goes to zero, and a zero delta is indistinguishable
    from "IPE costs nothing". A sysext is the way this goes wrong in practice,
    since it merges over /usr as an overlay with no verity beneath it.

    Returns True, False, or None when it cannot be determined."""
    rc, out, _ = run(['findmnt', '-n', '-o', 'SOURCE', '--target', path], timeout=30)
    if rc != 0 or not out.strip():
        return None
    source = out.strip().splitlines()[0].strip()
    rc, out, _ = run(['dmsetup', 'table', os.path.basename(source)], timeout=30)
    if rc != 0:
        # Not a device-mapper device at all: an overlay, a loop, a plain
        # partition. None of those are verity, so this is an answer.
        return False
    fields = out.split()
    return len(fields) >= 3 and fields[2] == 'verity'


# ------------------------------------------------------------ audit accounting

def journal_cursor():
    rc, out, _ = run(['journalctl', '-k', '-n', '0', '--show-cursor'], timeout=60)
    if rc != 0:
        return None
    for line in out.splitlines():
        if line.startswith('-- cursor:'):
            return line.split('-- cursor:', 1)[1].strip()
    return None


def journal_since(cursor):
    if not cursor:
        return ''
    rc, out, _ = run(['journalctl', '-k', '--no-pager', '--after-cursor', cursor],
                     timeout=120)
    return out if rc == 0 else ''


IPE_RECORD = re.compile(r'ipe_op=\S+')
SUPPRESSED = re.compile(r'callbacks suppressed|messages suppressed')


def audit_delta(text):
    """IPE emits one AUDIT_IPE_ACCESS record per violation. With no auditd those
    go to printk, which drops messages under load -- so a suppression notice means
    the count is a floor, not a total."""
    return {
        'ipeRecords': len(IPE_RECORD.findall(text)),
        'printkSuppressed': bool(SUPPRESSED.search(text)),
    }


# ------------------------------------------------------------------- stress-ng

YAML_OPS  = re.compile(r'^\s*bogo-ops:\s*([0-9.]+)\s*$', re.M)
YAML_RATE = re.compile(r'^\s*bogo-ops-per-second-real-time:\s*([0-9.]+)\s*$', re.M)


def stress_once(binary, args, ops):
    """One stress-ng invocation. Returns milliseconds per bogo-op, taken from the
    machine-readable YAML rather than by scraping the human-readable table."""
    with tempfile.NamedTemporaryFile(suffix='.yaml', delete=False) as tmp:
        yaml_path = tmp.name
    try:
        started = time.monotonic()
        rc, out, err = run([binary, *args, '--yaml', yaml_path, '--metrics'],
                           timeout=900)
        elapsed = time.monotonic() - started
        if rc != 0:
            tail = (err or out).strip().splitlines()
            return None, [tail[-1] if tail else 'stress-ng failed']
        try:
            with open(yaml_path) as fh:
                doc = fh.read()
        except Exception:
            doc = ''
        rate = YAML_RATE.search(doc)
        if rate and float(rate.group(1)) > 0:
            return 1000.0 / float(rate.group(1)), []
        # No usable rate in the YAML: fall back to wall clock over the ops that
        # actually completed, so a stress-ng that reports differently still
        # yields a number instead of silently dropping the row.
        done = YAML_OPS.search(doc)
        completed = float(done.group(1)) if done else float(ops)
        if completed > 0 and elapsed > 0:
            return (elapsed * 1000.0) / completed, ['derived from wall clock']
        return None, ['stress-ng produced no usable metrics']
    finally:
        try:
            os.unlink(yaml_path)
        except Exception:
            pass


def sample(binary, args, ops, reps):
    samples, issues = [], []
    for _ in range(reps):
        value, problem = stress_once(binary, args, ops)
        if value is not None:
            samples.append(value)
        issues.extend(problem)
    # Identical complaints from every repetition are one problem, not seven.
    return samples, sorted(set(issues))


def summarise(suite, operation, samples, unit='ms', **extra):
    if not samples:
        return None
    ordered = sorted(samples)
    row = {
        'suite': suite,
        'operation': operation,
        'unit': unit,
        'n': len(ordered),
        'minMs': round(ordered[0], 6),
        'p50Ms': round(ordered[len(ordered) // 2], 6),
        'maxMs': round(ordered[-1], 6),
        'samplesMs': [round(v, 6) for v in ordered],
    }
    row.update(extra)
    return row


# ------------------------------------------------------------ unverified copy

def prepare_copy(binary, scratch):
    """A copy of stress-ng itself on a writable filesystem. The spawn stressor
    re-executes its own resolved path, so running this copy means every measured
    execve targets a binary that is not on a dm-verity device -- same bytes, same
    linking, same work, different backing store."""
    try:
        os.makedirs(scratch, exist_ok=True)
        dest = os.path.join(scratch, 'stress-ng')
        shutil.copy2(binary, dest)
        os.chmod(dest, 0o755)
    except Exception as exc:
        return None, f'could not stage a writable copy of stress-ng: {exc}'

    rc, _, err = run([dest, '--version'], timeout=60)
    if rc != 0:
        # SELinux ships enforcing, and a file created under /var/tmp may carry a
        # type the calling domain may not execute. That is an SELinux denial, not
        # an IPE result, so relabel and retry before giving up on the row.
        run(['chcon', '-t', 'bin_t', dest], timeout=30)
        rc, _, err = run([dest, '--version'], timeout=60)
        if rc != 0:
            return None, f'writable copy of stress-ng is not executable: {err.strip()}'
    return dest, None


# ------------------------------------------------------------------------ main

metrics = []
binary = stress_ng_path()
version = stress_ng_version(binary) if binary else None
ipe = ipe_state()
cmdline = cmdline_ipe()
spawn_ok = False

if not binary or not version:
    notes.append('stress-ng is unavailable; no exec rows were produced')
else:
    spawn_ok = supports_spawn(binary)
    if not spawn_ok:
        notes.append('this stress-ng has no usable spawn stressor, so the verity '
                     'vs unverified comparison was skipped')

if ipe.get('present') and ipe.get('enforce') == '1':
    notes.append('IPE is enforcing on this node, so an unverified binary is '
                 'refused rather than audited; the unverified row measures a '
                 'blocked exec and is not comparable to a permissive run')
if ipe.get('present') and ipe.get('successAudit') == '1':
    notes.append('IPE success auditing is on, so allowed execs are audited too '
                 'and the verity row is not an audit-free baseline')
if not ipe.get('present'):
    notes.append('IPE is not loaded on this node (expected on the no-IPE arms); '
                 'these rows are the IPE-free baseline')

copy_path = None
# Initialised up front: several paths below skip the audit measurement entirely
# (no stress-ng, no spawn, an unexecutable copy) and every one of them still has
# to produce a document.
audit = {'ipeRecords': None, 'printkSuppressed': False}
devices = {}
verity_ok = None

if binary and version:
    # fork is the floor every spawn sample also pays for. Measured on the same
    # machine in the same run rather than assumed, so a reader can tell how much
    # of the spawn number is execve and how much is just process creation.
    samples, issues = sample(binary, ['--fork', '1', '--fork-ops', str(EXEC_OPS)],
                             EXEC_OPS, REPS)
    row = summarise('exec', 'fork', samples)
    if row:
        metrics.append(row)
    notes.extend(issues)

if binary and version and spawn_ok:
    devices['verity'] = backing_device(binary)
    verity_ok = verity_backed(binary)
    devices['verityBacked'] = verity_ok

if binary and version and spawn_ok and verity_ok is not True:
    # Not a reason to measure nothing. The policy ACL ships is
    #
    #   DEFAULT op=EXECUTE                  action=DENY
    #   op=EXECUTE boot_verified=TRUE       action=ALLOW
    #   op=EXECUTE dmverity_signature=TRUE  action=ALLOW
    #
    # so a binary that is on no verity device matches neither ALLOW rule,
    # falls through to DEFAULT DENY and -- under enforce=0 -- runs anyway
    # while emitting an AUDIT_IPE_ACCESS record. Every exec pays for an audit
    # record. That is not a degraded measurement, it is IPE's worst case, and
    # it is the whole cost the feature is suspected of imposing.
    #
    # It is also the only thing that can be measured on an E0 arm, where
    # there is no dm-verity anywhere on the node by construction. Refusing to
    # produce rows here left the erofs-off arms with no exec data at all --
    # exactly the arms whose numbers the IPE comparison needs.
    #
    # What is genuinely lost is the *within-run* delta: with one binary there
    # is no audit-free counterpart on the same machine, so machine-to-machine
    # variation no longer cancels. The row is therefore named for what it
    # actually is, and the comparison moves across runs (I1E0 against I0E0)
    # rather than within one.
    label = 'spawn_audited' if ipe.get('present') else 'spawn_no_ipe'
    notes.append('the stress-ng being measured is not on a dm-verity device '
                 '(backing store: %s), so there is no audit-free counterpart '
                 'on this machine and no within-run delta; measuring the '
                 'single available path instead and reporting it as %s'
                 % (devices.get('verity') or 'unknown', label))
    if ipe.get('present') and ipe.get('enforce') != '1':
        notes.append('every exec measured here falls through to DEFAULT DENY '
                     'and is audited, so this row is IPE\'s worst case; compare '
                     'it against the same row from an IPE-off build to get the '
                     'audit cost')
    cursor = journal_cursor()
    samples, issues = sample(binary, ['--spawn', '1', '--spawn-ops', str(EXEC_OPS)],
                             EXEC_OPS, REPS)
    row = summarise('exec', label, samples)
    if row:
        metrics.append(row)
    notes.extend(issues)
    if ipe.get('present'):
        audit = audit_delta(journal_since(cursor))
        if audit['printkSuppressed']:
            notes.append('printk rate limiting suppressed messages during this '
                         'run, so the audit record count is a floor rather than '
                         'a total')

if binary and version and spawn_ok and verity_ok is True:
    samples, issues = sample(binary, ['--spawn', '1', '--spawn-ops', str(EXEC_OPS)],
                             EXEC_OPS, REPS)
    row = summarise('exec', 'spawn_verity', samples)
    if row:
        metrics.append(row)
    notes.extend(issues)

    copy_path, problem = prepare_copy(binary, SCRATCH)
    if problem:
        notes.append(problem)
    else:
        devices['unverified'] = backing_device(copy_path)
        if devices.get('verity') and devices['verity'] == devices.get('unverified'):
            notes.append('the verity and unverified binaries are on the same '
                         'device, so this run cannot separate them')
        cursor = journal_cursor()
        samples, issues = sample(copy_path,
                                 ['--spawn', '1', '--spawn-ops', str(EXEC_OPS)],
                                 EXEC_OPS, REPS)
        row = summarise('exec', 'spawn_unverified', samples)
        if row:
            metrics.append(row)
        notes.extend(issues)
        audit = audit_delta(journal_since(cursor))
        if audit['printkSuppressed']:
            notes.append('the kernel suppressed printk messages during the '
                         'unverified run, so the audit record count is a floor '
                         'and the measured cost is an undercount')

    # dlopen exercises the MMAP hook rather than the execve hook. IPE checks both,
    # and a binary linking many libraries pays the mmap check once per library, so
    # this is the axis that scales with how much a workload links. The libraries
    # come off /usr either way, so this row compares across arms, not within one.
    samples, issues = sample(binary, ['--dynlib', '1', '--dynlib-ops', str(DYNLIB_OPS)],
                             DYNLIB_OPS, REPS)
    row = summarise('exec', 'dynlib', samples)
    if row:
        metrics.append(row)
    notes.extend(issues)

if copy_path and not KEEP:
    shutil.rmtree(SCRATCH, ignore_errors=True)

# The delta is the headline: the same binary, the same machine, the same run,
# differing only in whether IPE could match an ALLOW rule.
by_op = {row['operation']: row for row in metrics}
delta = None
spread = None
resolvable = None
if 'spawn_verity' in by_op and 'spawn_unverified' in by_op:
    delta = round(by_op['spawn_unverified']['p50Ms'] - by_op['spawn_verity']['p50Ms'], 6)
    # A spawn re-executes the whole stress-ng binary, so one op costs milliseconds
    # while an IPE check may cost microseconds. Comparing the delta against the
    # spread of the baseline is what keeps a run from presenting its own noise as
    # a measurement -- which is exactly how the previous revision of this suite
    # reported a 53x filesystem "result" that was an artifact.
    spread = round(by_op['spawn_verity']['maxMs'] - by_op['spawn_verity']['minMs'], 6)
    resolvable = abs(delta) > spread

document = {
    'schemaVersion': 1,
    'run': {
        'startedAt': os.environ['ACL_STARTED_AT'],
        'finishedAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'suites': ['exec'],
    },
    'node': {
        'image': os.environ['ACL_NODE_IMAGE'],
        'kernel': os.environ['ACL_KERNEL'],
        'selinux': os.environ['ACL_SELINUX'],
        'containerd': os.environ['ACL_CONTAINERD'],
    },
    'metrics': metrics,
    'suites': {
        'exec': {
            'stressNgVersion': version,
            'execOpsPerRep': EXEC_OPS,
            'backingDevices': devices,
            'ipe': ipe,
            'ipeCmdline': cmdline,
            'auditRecords': audit.get('ipeRecords'),
            'auditPrintkSuppressed': audit.get('printkSuppressed'),
            'auditCostMsPerExec': delta,
            'auditCostResolvable': resolvable,
            'baselineSpreadMs': spread,
            'notes': notes,
        },
    },
}

with open(results_path, 'w') as fh:
    json.dump(document, fh, indent=2)

print()
print('=== IPE exec cost ===')
if ipe.get('present'):
    print(f"  IPE:       loaded, enforce={ipe.get('enforce')} "
          f"success_audit={ipe.get('successAudit')} "
          f"policies={','.join(ipe.get('activePolicies') or []) or 'none'}")
else:
    print('  IPE:       not loaded')
if cmdline:
    print(f"  cmdline:   {' '.join(cmdline)}")
print(f"  stress-ng: {version or 'unavailable'}")
for label, device in devices.items():
    print(f"  {label + ' binary on:':<11} {device}")
print()

if metrics:
    print(f"  {'operation':<20} {'n':>3} {'min ms':>10} {'p50 ms':>10} {'max ms':>10}")
    for row in metrics:
        print(f"  {row['operation']:<20} {row['n']:>3} "
              f"{row['minMs']:>10.4f} {row['p50Ms']:>10.4f} {row['maxMs']:>10.4f}")
    print()

# Spelled out because the raw table invites the wrong comparison: spawn minus
# fork is mostly execve itself, which IPE does not change.
if delta is not None:
    print('  The number to read:')
    print(f'    spawn_unverified - spawn_verity = {delta:+.4f} ms per exec')
    print('    Same binary, same run, different backing device. The difference is')
    print('    what IPE costs when a binary fails the policy and the violation is')
    print('    audited.')
    print(f"    IPE audit records emitted during that run: {audit.get('ipeRecords')}")
    if resolvable is False:
        print(f'    NOT RESOLVABLE: the baseline itself varied by {spread:.4f} ms')
        print('    across repetitions, which is larger than the delta. Treat this')
        print('    as "no measurable cost", not as the number above. Raise')
        print('    ACL_EXEC_REPS or ACL_EXEC_OPS to tighten the baseline.')
    if audit.get('ipeRecords') == 0 and ipe.get('present'):
        print('    No records were seen despite IPE being loaded -- treat the')
        print('    delta as unexplained rather than as a real cost.')
    if audit.get('printkSuppressed'):
        print('    printk suppressed messages -- the count is a floor.')
else:
    print('  No verity/unverified pair was produced, so this run does not measure')
    print('  IPE audit cost. See notes.')

if notes:
    print()
    print('  Notes:')
    for note in notes:
        print(f'    - {note}')

print()
print('ACL_PERF_RESULTS=' + json.dumps(document, separators=(',', ':')))

# A benchmark that measured nothing must not report success. Every path that
# leaves `metrics` empty -- stress-ng missing, no usable spawn stressor -- means
# the IPE exec axis has no data at all, and a green result here is worse than a
# red one: it is indistinguishable from a real run that found no IPE cost, so
# the gap silently persists across every future run. Build 1176362 reported this
# suite as PASSED while measuring nothing.
#
# Emptiness is the right trigger rather than a missing delta. The no-IPE arms
# legitimately produce no delta, but they still produce exec rows; zero rows
# only happens when the measurement itself could not be taken.
#
# No env escape hatch: run_scripts_on_vm invokes this as a bare `sudo <script>`
# with no environment passed through, so one would be unreachable from the
# pipeline anyway. Skipping the suite is what ACL_RUN_PERF_TESTS is for.
if not metrics:
    print()
    print('[ERROR] exec benchmark produced no metrics, so nothing was measured.')
    for note in notes:
        print(f'[ERROR]   - {note}')
    print('[ERROR] Rebuild the image with ACL_PERF_TOOLS=1, or turn the perf')
    print('[ERROR] suite off; do not read this run as "no IPE cost".')
    sys.exit(1)
PY
