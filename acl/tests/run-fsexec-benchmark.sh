#!/bin/bash
# Measure filesystem read cost and exec cost on the node itself.
#
# This is general-perf: no containerd, no CNI, no kubelet, no registry. It reads
# files and it starts processes, which is what the two matrix axes actually tax:
#
#   EROFS + dm-verity  taxes the read path. Every block that comes off the image
#                      is hashed against the Merkle tree before it is handed to
#                      userspace, and on a compressed image it is decompressed
#                      too. Neither cost exists on a plain writable filesystem.
#
#   IPE                taxes the exec path. Every execve is checked against the
#                      policy before the binary is allowed to run.
#
# The container benchmark cannot separate these: a PullImage number folds
# network, unpack, hashing and mount into one figure. Here each is a single
# syscall in a loop, so a regression points at something specific.
#
# The control corpus is what makes the read numbers mean anything. A cold read
# of /usr on its own only says "this VM's disk was this fast today" -- Azure
# disk throughput varies enough between runs to swamp the effect being looked
# for. So the same bytes, in files of exactly the same sizes, are written to the
# writable filesystem and read back the same way in the same run. Both corpora
# sit on the same underlying disk, so dividing one by the other cancels the disk
# and leaves the filesystem.
#
# There is deliberately no in-run control for exec. IPE's whole purpose is to
# refuse execution of anything that is not verity-backed, so a binary copied to
# the writable filesystem would be *blocked* rather than slow on exactly the
# arms where IPE is enabled. The exec comparison is therefore across arms (IPE
# on vs off), not within a run.
#
# Emits the results document described in acl/tests/PERF-RESULTS.md.
#
# Tunables (env):
#   ACL_FS_IMAGE_PATH     read-only image tree to measure   (default /usr)
#   ACL_FS_CONTROL_PATH   scratch dir for the control corpus (default /var/tmp/acl-fsperf)
#   ACL_FS_BUDGET_MB      bytes read per sample             (default 64)
#   ACL_FS_COLD_SAMPLES   cold-cache repetitions            (default 5)
#   ACL_FS_WARM_SAMPLES   warm-cache repetitions            (default 10)
#   ACL_FS_RANDOM_READS   random 4 KiB reads per sample     (default 2000)
#   ACL_FS_STAT_FILES     files stat()ed per sample         (default 3000)
#   ACL_EXEC_SAMPLES      execve repetitions                (default 30)
#   ACL_FS_KEEP_CONTROL   leave the control corpus in place (default false)

# No `set -e`: a suite that cannot run should drop its rows and let the rest of
# the document through, the same way the boot suite omits phases the platform
# does not expose.
set -uo pipefail

IMAGE_PATH="${ACL_FS_IMAGE_PATH:-/usr}"
CONTROL_PATH="${ACL_FS_CONTROL_PATH:-/var/tmp/acl-fsperf}"
BUDGET_MB="${ACL_FS_BUDGET_MB:-64}"
COLD_SAMPLES="${ACL_FS_COLD_SAMPLES:-5}"
WARM_SAMPLES="${ACL_FS_WARM_SAMPLES:-10}"
RANDOM_READS="${ACL_FS_RANDOM_READS:-2000}"
STAT_FILES="${ACL_FS_STAT_FILES:-3000}"
EXEC_SAMPLES="${ACL_EXEC_SAMPLES:-30}"

RESULTS_JSON="${PERF_RESULTS_JSON:-/var/tmp/fsexec-results.json}"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

NODE_IMAGE="$( . /etc/os-release 2>/dev/null; echo "${IMAGE_ID:-${ID:-unknown}} ${IMAGE_VERSION:-${VERSION_ID:-}}" )"
NODE_KERNEL="$(uname -r)"
NODE_SELINUX="$(getenforce 2>/dev/null || echo unknown)"
NODE_CONTAINERD="$(containerd --version 2>/dev/null | awk '{print $3}')"

echo "=== Filesystem and exec benchmark ==="
echo "  image path:   ${IMAGE_PATH}"
echo "  control path: ${CONTROL_PATH}"
echo "  budget:       ${BUDGET_MB} MiB per read sample"
echo "  node:         ${NODE_IMAGE} (kernel ${NODE_KERNEL})"

ACL_NODE_IMAGE="$NODE_IMAGE" \
ACL_KERNEL="$NODE_KERNEL" \
ACL_SELINUX="$NODE_SELINUX" \
ACL_CONTAINERD="$NODE_CONTAINERD" \
ACL_STARTED_AT="$STARTED_AT" \
ACL_FS_IMAGE_PATH="$IMAGE_PATH" \
ACL_FS_CONTROL_PATH="$CONTROL_PATH" \
ACL_FS_BUDGET_MB="$BUDGET_MB" \
ACL_FS_COLD_SAMPLES="$COLD_SAMPLES" \
ACL_FS_WARM_SAMPLES="$WARM_SAMPLES" \
ACL_FS_RANDOM_READS="$RANDOM_READS" \
ACL_FS_STAT_FILES="$STAT_FILES" \
ACL_EXEC_SAMPLES="$EXEC_SAMPLES" \
ACL_FS_KEEP_CONTROL="${ACL_FS_KEEP_CONTROL:-false}" \
python3 - "$RESULTS_JSON" <<'PY'
import json, os, random, shutil, stat, subprocess, sys, time

results_path = sys.argv[1]

IMAGE_PATH   = os.environ['ACL_FS_IMAGE_PATH']
CONTROL_PATH = os.environ['ACL_FS_CONTROL_PATH']
BUDGET       = int(os.environ['ACL_FS_BUDGET_MB']) * 1024 * 1024
COLD_SAMPLES = int(os.environ['ACL_FS_COLD_SAMPLES'])
WARM_SAMPLES = int(os.environ['ACL_FS_WARM_SAMPLES'])
RANDOM_READS = int(os.environ['ACL_FS_RANDOM_READS'])
STAT_FILES   = int(os.environ['ACL_FS_STAT_FILES'])
EXEC_SAMPLES = int(os.environ['ACL_EXEC_SAMPLES'])
KEEP_CONTROL = os.environ.get('ACL_FS_KEEP_CONTROL', 'false') == 'true'

# Files smaller than this are read as metadata rather than as data: at 4 KiB the
# open() dominates and the measurement stops being about throughput. They still
# take part in the stat walk, which is where per-file cost belongs.
MIN_DATA_FILE = 64 * 1024
RANDOM_BLOCK  = 4096
READ_CHUNK    = 1 << 20

def run(cmd, timeout=30):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.strip()
    except Exception:
        return 1, ''

def mount_info(path):
    """Filesystem backing a path. Recorded rather than assumed: the matrix arms
    deliberately differ here, and a number whose filesystem is unknown cannot be
    compared against another run."""
    rc, out = run(['findmnt', '-no', 'FSTYPE,SOURCE,TARGET', '--target', path])
    if rc == 0 and out:
        parts = out.split()
        while len(parts) < 3:
            parts.append('')
        return {'fstype': parts[0], 'source': parts[1], 'target': parts[2]}
    return {'fstype': 'unknown', 'source': '', 'target': ''}

def drop_caches():
    """Page cache, dentries and inodes. Without this a 'cold' read is a memcpy
    from RAM and every arm looks identical."""
    try:
        os.sync()
    except Exception:
        pass
    try:
        with open('/proc/sys/vm/drop_caches', 'w') as fh:
            fh.write('3\n')
        return True
    except OSError:
        pass
    rc, _ = run(['sudo', '-n', 'sh', '-c', 'sync; echo 3 > /proc/sys/vm/drop_caches'])
    return rc == 0

def collect_corpus(root):
    """Walk once, deterministically, gathering a data corpus (large files, up to
    the byte budget) and a metadata corpus (every file seen, up to the stat
    count). Sorted so the same image always yields the same corpus; different
    images will not, which is why the file count and byte total are reported."""
    data, data_bytes, meta = [], 0, []
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames.sort()
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            try:
                st = os.lstat(path)
            except OSError:
                continue
            if not stat.S_ISREG(st.st_mode):
                continue
            if len(meta) < STAT_FILES:
                meta.append(path)
            if data_bytes < BUDGET and st.st_size >= MIN_DATA_FILE:
                # Clip the last file to land exactly on the budget. Taking whole
                # files instead would let one large binary overshoot by tens of
                # megabytes, and since the arms ship different binaries each
                # would read a different number of bytes -- leaving throughput
                # as the only comparable figure. Clipping keeps the byte count
                # identical everywhere, so the raw milliseconds compare too.
                take = min(st.st_size, BUDGET - data_bytes)
                data.append((path, take))
                data_bytes += take
            if data_bytes >= BUDGET and len(meta) >= STAT_FILES:
                return data, data_bytes, meta
    return data, data_bytes, meta

def build_control(dirpath, sizes):
    """Mirror the image corpus onto the writable filesystem: same file count,
    same sizes, same order. Real bytes, never a sparse file, or the control
    would read back without touching the disk at all."""
    shutil.rmtree(dirpath, ignore_errors=True)
    os.makedirs(dirpath, exist_ok=True)
    block = os.urandom(READ_CHUNK)
    out, total = [], 0
    for i, size in enumerate(sizes):
        path = os.path.join(dirpath, 'f%05d.bin' % i)
        remaining = size
        try:
            with open(path, 'wb', buffering=0) as fh:
                while remaining > 0:
                    fh.write(block[:min(remaining, len(block))])
                    remaining -= min(remaining, len(block))
        except OSError:
            continue
        out.append((path, size))
        total += size
    try:
        os.sync()
    except Exception:
        pass
    return out, total

def read_sequential(files):
    total = 0
    for path, length in files:
        remaining = length
        try:
            with open(path, 'rb', buffering=0) as fh:
                while remaining > 0:
                    chunk = fh.read(min(READ_CHUNK, remaining))
                    if not chunk:
                        break
                    total += len(chunk)
                    remaining -= len(chunk)
        except OSError:
            continue
    return total

def read_random(files, count, seed=1234):
    """Random offsets, fixed seed so every arm reads the same pattern. File
    descriptors are opened up front and reused: reopening per read would fold
    path lookup into what is meant to be a read measurement, and dm-verity's
    cost shows up in the read."""
    candidates = [(p, s) for p, s in files if s > RANDOM_BLOCK]
    if not candidates:
        return 0, 0
    rng = random.Random(seed)
    fds, sizes = [], []
    for path, size in candidates[:256]:
        try:
            fds.append(os.open(path, os.O_RDONLY))
            sizes.append(size)
        except OSError:
            continue
    if not fds:
        return 0, 0
    total, done = 0, 0
    try:
        for _ in range(count):
            idx = rng.randrange(len(fds))
            offset = rng.randrange(0, max(1, sizes[idx] - RANDOM_BLOCK))
            try:
                total += len(os.pread(fds[idx], RANDOM_BLOCK, offset))
                done += 1
            except OSError:
                continue
    finally:
        for fd in fds:
            try:
                os.close(fd)
            except OSError:
                pass
    return total, done

def stat_walk(paths):
    done = 0
    for path in paths:
        try:
            os.stat(path)
            done += 1
        except OSError:
            continue
    return done

def exec_once(binary):
    """fork + execv + wait. The fork and the wait are constant overhead that is
    identical on every arm, so they cancel in a comparison; the execve in the
    middle is where IPE evaluates its policy."""
    pid = os.fork()
    if pid == 0:
        try:
            os.execv(binary, [binary])
        except BaseException:
            os._exit(127)
    _, status = os.waitpid(pid, 0)
    return status

def timed(fn, *args):
    start = time.perf_counter_ns()
    result = fn(*args)
    return (time.perf_counter_ns() - start) / 1e6, result

node = {
    'image': os.environ.get('ACL_NODE_IMAGE', '').strip(),
    'kernel': os.environ.get('ACL_KERNEL', ''),
    'containerd': os.environ.get('ACL_CONTAINERD', ''),
    'selinux': os.environ.get('ACL_SELINUX', ''),
}

metrics = []
notes = []

def add_row(suite, operation, samples, **extra):
    if not samples:
        return
    ordered = sorted(samples)
    row = {
        'suite': suite,
        'image': '',
        'operation': operation,
        'snapshotter': '',
        'nodeImage': node['image'],
        'containerd': node['containerd'],
        'unit': 'ms',
        'n': len(ordered),
        'minMs': round(ordered[0], 3),
        'p50Ms': round(ordered[len(ordered) // 2], 3),
        'maxMs': round(ordered[-1], 3),
        'samplesMs': [round(v, 3) for v in ordered],
    }
    row.update(extra)
    metrics.append(row)

cold_ok = drop_caches()
if not cold_ok:
    # Reporting a warm read as if it were cold would be worse than reporting
    # nothing: it would look like the filesystem got dramatically faster.
    notes.append('cold-cache measurements unavailable (cannot drop caches; '
                 'need root or passwordless sudo) -- cold rows omitted')

image_mount = mount_info(IMAGE_PATH)
print("\n--- corpus")
data_files, data_bytes, meta_files = collect_corpus(IMAGE_PATH)
print(f"      image   {IMAGE_PATH}: {len(data_files)} data files, "
      f"{data_bytes / 1048576:.1f} MiB, {len(meta_files)} files for stat "
      f"[{image_mount['fstype']} on {image_mount['source']}]")

targets = []
if data_files:
    targets.append(('image', IMAGE_PATH, data_files, data_bytes, meta_files, image_mount))
else:
    notes.append(f'no files >= {MIN_DATA_FILE} bytes under {IMAGE_PATH} -- '
                 'filesystem suite skipped')

# The control only means something if it lands on a different filesystem. If the
# scratch directory turns out to be on the image mount there is nothing to
# compare, so say so rather than emitting two rows that measure the same thing.
control_files, control_bytes, control_mount = [], 0, {}
if data_files:
    os.makedirs(CONTROL_PATH, exist_ok=True)
    control_mount = mount_info(CONTROL_PATH)
    if control_mount['source'] and control_mount['source'] == image_mount['source']:
        notes.append(f'control path {CONTROL_PATH} is on the same filesystem as '
                     f'{IMAGE_PATH} ({control_mount["source"]}) -- control rows omitted')
    else:
        control_files, control_bytes = build_control(
            CONTROL_PATH, [size for _, size in data_files])
        print(f"      control {CONTROL_PATH}: {len(control_files)} files, "
              f"{control_bytes / 1048576:.1f} MiB "
              f"[{control_mount['fstype']} on {control_mount['source']}]")
        if control_files:
            targets.append(('control', CONTROL_PATH, control_files, control_bytes,
                            [p for p, _ in control_files], control_mount))

for label, path, files, total_bytes, meta, mnt in targets:
    context = {
        'path': path,
        'fstype': mnt.get('fstype', ''),
        'device': mnt.get('source', ''),
        'bytes': total_bytes,
        'files': len(files),
    }

    if cold_ok:
        samples = []
        for _ in range(COLD_SAMPLES):
            drop_caches()
            elapsed, read = timed(read_sequential, files)
            if read > 0:
                samples.append(elapsed)
        add_row('filesystem', f'read_cold:{label}', samples, **context)

    # Warm needs no drop; the preceding cold pass has already populated the
    # cache. Where cold could not run, the first warm sample absorbs the fill,
    # which is why min/median are reported alongside it.
    read_sequential(files)
    samples = []
    for _ in range(WARM_SAMPLES):
        elapsed, read = timed(read_sequential, files)
        if read > 0:
            samples.append(elapsed)
    add_row('filesystem', f'read_warm:{label}', samples, **context)

    if cold_ok:
        samples, performed = [], 0
        for _ in range(COLD_SAMPLES):
            drop_caches()
            elapsed, (_, done) = timed(read_random, files, RANDOM_READS)
            if done > 0:
                samples.append(elapsed)
                performed = done
        add_row('filesystem', f'read_random_cold:{label}', samples,
                reads=performed, blockBytes=RANDOM_BLOCK, **context)

        samples, walked = [], 0
        for _ in range(COLD_SAMPLES):
            drop_caches()
            elapsed, done = timed(stat_walk, meta)
            if done > 0:
                samples.append(elapsed)
                walked = done
        # A stat walk touches no file data, so the data corpus byte count would
        # only invite someone to divide by it.
        meta_context = {k: v for k, v in context.items() if k not in ('files', 'bytes')}
        add_row('filesystem', f'stat_cold:{label}', samples,
                statted=walked, files=len(meta), **meta_context)

# ── exec ──────────────────────────────────────────────────────────────────
exec_binary = os.path.join(IMAGE_PATH, 'bin', 'true')
if not os.path.isfile(exec_binary):
    exec_binary = shutil.which('true') or ''

if exec_binary:
    exec_mount = mount_info(exec_binary)
    exec_once(exec_binary)  # warm the page cache; policy is still evaluated
    samples = []
    for _ in range(EXEC_SAMPLES):
        elapsed, status = timed(exec_once, exec_binary)
        if os.WIFEXITED(status) and os.WEXITSTATUS(status) != 127:
            samples.append(elapsed)
    if samples:
        add_row('exec', 'fork_exec', samples,
                path=exec_binary,
                fstype=exec_mount.get('fstype', ''),
                device=exec_mount.get('source', ''))
    else:
        notes.append(f'every exec of {exec_binary} failed -- exec suite skipped')
else:
    notes.append('no usable binary found to exec -- exec suite skipped')

# ── report ────────────────────────────────────────────────────────────────
for row in metrics:
    if row['suite'] == 'filesystem' and row['operation'].startswith(('read_cold', 'read_warm')):
        if row['p50Ms'] > 0 and row.get('bytes'):
            row['throughputMBps'] = round(
                (row['bytes'] / 1048576.0) / (row['p50Ms'] / 1000.0), 2)

print(f"\n--- Filesystem and exec (node: {node['image'] or 'unknown'})")
print(f"      {'operation':<28} {'fs':<8} {'n':>3} {'min ms':>10} {'med ms':>10} "
      f"{'max ms':>10} {'MB/s':>9}")
for row in metrics:
    print(f"      {row['operation']:<28} {str(row.get('fstype', '')):<8} {row['n']:>3} "
          f"{row['minMs']:>10} {row['p50Ms']:>10} {row['maxMs']:>10} "
          f"{row.get('throughputMBps', ''):>9}")

# The ratio is the point of the control, so compute it here rather than leaving
# every reader to do it: it is the number that survives a noisy disk.
by_op = {row['operation']: row for row in metrics}
for kind in ('read_cold', 'read_warm', 'read_random_cold', 'stat_cold'):
    img, ctl = by_op.get(f'{kind}:image'), by_op.get(f'{kind}:control')
    if img and ctl and ctl['p50Ms'] > 0:
        ratio = img['p50Ms'] / ctl['p50Ms']
        print(f"      {kind}: image is {ratio:.2f}x the control "
              f"({img['fstype']} vs {ctl['fstype']})")

for note in notes:
    print(f"      note: {note}")

if not KEEP_CONTROL:
    shutil.rmtree(CONTROL_PATH, ignore_errors=True)

suites = sorted({row['suite'] for row in metrics})
document = {
    'schemaVersion': 1,
    'run': {
        'startedAt': os.environ.get('ACL_STARTED_AT', ''),
        'finishedAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'suites': suites,
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
    print("no filesystem or exec measurements were produced", file=sys.stderr)
    sys.exit(1)
PY
rc=$?

if [[ $rc -ne 0 ]]; then
    echo "[ERROR] Filesystem and exec benchmark failed" >&2
    exit $rc
fi
echo "✅ Filesystem and exec benchmark complete"
