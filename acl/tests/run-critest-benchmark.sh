#!/bin/bash
# Performance test: run the upstream cri-tools CRI benchmark against containerd.
#
# All measurement is done by `critest -benchmark` (kubernetes-sigs/cri-tools,
# shipped in the image via package_catalog.yaml). This script only supplies the
# parameters critest needs, then summarizes the datapoints critest writes out.
#
# critest creates and destroys its own pod sandboxes, so it must run on a node
# with no kubelet competing for the runtime. That holds for a plain ACL test VM.
#
# Tunables (env):
#   CRITEST_SAMPLES   pods/containers per benchmark suite  (default 30)
#   CRITEST_IMAGES    image benchmark iterations           (default 10)
#   CRITEST_IMAGE_SET  space-separated "label=imageref" variants to benchmark
#   CRITEST_TIMEOUT   overall wall-clock budget in seconds (default 2400)

# No `set -e`: critest's exit code must survive to the summarizer below, which
# reports the collected datapoints before deciding pass/fail.
set -uo pipefail

SAMPLES="${CRITEST_SAMPLES:-30}"
IMAGES="${CRITEST_IMAGES:-10}"
BUDGET="${CRITEST_TIMEOUT:-2400}"

# notaryaksegistry and notarycontainerregistry both have anonymous pull enabled,
# so no ACR credentials are needed on the test VM.
REGISTRY="${ACL_PERF_REGISTRY:-notarycontainerregistry.azurecr.io}"

# Image ladder, spanning roughly 2 MB to 130 MB so each measurement can be read
# against image size rather than as a single number.
#
# Published by sessions/dmverity-prototype/files/acl-perf/publish-ab-ladder.sh.
LADDER="${CRITEST_LADDER:-busybox:1-glibc pause:3.6 livenessprobe:v2.18.0 azure-cloud-node-manager:v1.34.8-2 kube-proxy:v1.34.7-2 azurefile-csi:v1.34.5}"

# A node runs one snapshotter, so the ladder is measured once per node and the
# *node image* is the variable: running this same ladder on each build of the
# IPE x EROFS matrix produces the comparison. Pairing two image variants inside
# a single run, as this used to do, measured something narrower -- both arms
# were served by the erofs snapshotter, so it compared precomputed EROFS against
# locally-built EROFS and never against overlayfs at all.
#
# perf-erofs and perf-plain are byte-identical and share a manifest digest; only
# perf-erofs carries the vnd.cncf.notary.dmverity.v1 referrers, and those are
# fetched only by a node that has EROFS enabled. Pulling perf-erofs everywhere
# therefore holds the input constant across the matrix while still exercising
# the precomputed path wherever the node supports it.
REPO="${CRITEST_IMAGE_REPO:-perf-erofs}"

# critest's imagePullingBenchmarkImage takes exactly one reference, so each rung
# needs its own critest pass. Each gets its own output directory and its suites
# are reported under "<rung>/<suite>".
build_image_set() {
    local rung name
    for rung in $LADDER; do
        name="${rung%%:*}"
        printf '%s=%s/%s/%s ' "$name" "$REGISTRY" "$REPO" "$rung"
    done
}
IMAGE_SET="${CRITEST_IMAGE_SET:-$(build_image_set)}"

# The pod sandbox suite is image-independent: the sandbox image comes from
# containerd's own config, not from anything critest is told, so repeating it
# per rung would burn budget re-measuring one number. Only the first variant
# runs it.
POD_SAMPLES="${CRITEST_SAMPLES:-30}"

# The container suite is a different story. critest has no benchmark parameter
# for the container image, but `-test-images-file` overrides the image the
# suites build containers from, so pointing it at a rung makes
# CreateContainer/StartContainer measure that rung.
#
# This is the half of the ledger PullImage cannot show. Precomputed EROFS costs
# extra bytes on pull; what it should buy back is container start, where a ready
# EROFS image is mounted instead of layers being assembled. Measuring only pull
# reports the cost and never the benefit.
CONTAINER_SAMPLES="${CRITEST_CONTAINER_SAMPLES:-${CRITEST_SAMPLES:-30}}"

# ...but only one rung can carry it. critest's container suite runs a command
# inside the container, and every AKS image in the ladder is distroless, so
# StartContainer fails on all of them. busybox is critest's own default test
# image and is published through the same pipeline, so it measures container
# start without leaving the upstream path.
#
# Empty by default because this needs a containerd carrying the EROFS SELinux
# layer-sharing fix. An EROFS layer is shared by every container using it, but
# all those mounts resolve to one superblock, and containerd labels each with
# the consuming container's MCS pair -- so the second container to want a layer
# is rejected with "SELinux: mount invalid. Same superblock, different security
# settings". Overlayfs is unaffected, since each container gets its own overlay
# superblock, which is why this went unnoticed: every container benchmarked
# before now came from an overlayfs snapshot.
#
# Set CRITEST_CONTAINER_RUNG=busybox on a node whose containerd has the fix.
CONTAINER_RUNG="${CRITEST_CONTAINER_RUNG:-}"
ENDPOINT="unix:///run/containerd/containerd.sock"
OUT=/var/tmp/critest-out

command -v critest >/dev/null 2>&1 || { echo "critest is not installed" >&2; exit 1; }
systemctl is-active --quiet containerd || { echo "containerd is not active" >&2; exit 1; }

# critest's pod sandbox benchmarks need a usable CNI network. The image ships
# containernetworking-plugins but no default config, so drop in a minimal
# bridge conflist. Guarded: never clobber a real network configuration.
if [ -z "$(ls -A /etc/cni/net.d 2>/dev/null)" ]; then
    mkdir -p /etc/cni/net.d
    cat >/etc/cni/net.d/10-aclperf-bridge.conflist <<'CNI_EOF'
{
  "cniVersion": "1.0.0",
  "name": "aclperf",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "cni0",
      "isGateway": true,
      "ipMasq": true,
      "promiscMode": true,
      "ipam": {
        "type": "host-local",
        "ranges": [[{"subnet": "10.244.0.0/16"}]],
        "routes": [{"dst": "0.0.0.0/0"}]
      }
    },
    {"type": "portmap", "capabilities": {"portMappings": true}}
  ]
}
CNI_EOF
fi

# Wait for containerd to report the network as ready rather than sleeping a
# fixed interval. containerd watches conf_dir with fsnotify, and starting a
# benchmark while that reload is still in flight makes CNI plugin execs fail
# with "interrupted system call" (EINTR) partway through the run.
network_ready() {
    crictl --runtime-endpoint "$ENDPOINT" info 2>/dev/null | python3 -c '
import json, sys
try:
    conditions = json.load(sys.stdin).get("status", {}).get("conditions", [])
except Exception:
    sys.exit(1)
sys.exit(0 if any(c.get("type") == "NetworkReady" and c.get("status") for c in conditions) else 1)
'
}

for _ in $(seq 1 30); do
    network_ready && break
    sleep 2
done
if ! network_ready; then
    echo "containerd never reported NetworkReady; CNI config is not usable" >&2
    exit 1
fi

rm -rf "$OUT"; mkdir -p "$OUT"

# Which snapshotter actually served the run.
#
# This is recorded rather than assumed because `containerd config dump` is not
# a reliable answer: it reported snapshotter = "overlayfs" on a node where the
# ACL EROFS handler was taking every pull. An earlier round of these benchmarks
# was read as "EROFS vs overlayfs" on the strength of that field when in fact
# both arms ran on erofs. Counting committed snapshots per snapshotter before
# and after the run shows which one did the work, so the results carry their own
# evidence and the node image stays the only variable being compared.
SNAPSHOTTERS="${CRITEST_SNAPSHOTTERS:-overlayfs erofs}"
# CRI puts its snapshots in the k8s.io namespace, not ctr's "default".
CTR_NS="${CRITEST_NAMESPACE:-k8s.io}"
snapshot_counts() {
    local s n
    for s in $SNAPSHOTTERS; do
        n=$(ctr -n "$CTR_NS" --address /run/containerd/containerd.sock snapshots --snapshotter "$s" list 2>/dev/null | tail -n +2 | wc -l)
        printf '%s=%s ' "$s" "$n"
    done
}
SNAP_PROBE_BEFORE=""
SNAP_PROBE_AFTER=""

# Node identity, so results from different builds of the IPE x EROFS matrix can
# be told apart and joined after the fact.
NODE_IMAGE="$( . /etc/os-release 2>/dev/null; echo "${IMAGE_ID:-${ID:-unknown}} ${IMAGE_VERSION:-${VERSION_ID:-}}" )"
NODE_SELINUX="$(getenforce 2>/dev/null || echo unknown)"

echo "=== ACL CRI benchmark (upstream critest) ==="
critest --version 2>/dev/null || true
echo "Node image: ${NODE_IMAGE}"
echo "Kernel:     $(uname -r)"
echo "Runtime:    $(ctr --version 2>/dev/null || echo unknown)"
echo "SELinux:    ${NODE_SELINUX}"
echo "Image repo: ${REPO}"
echo "Samples:    ${POD_SAMPLES} pods (first rung), ${CONTAINER_SAMPLES} containers/rung, ${IMAGES} image iterations"
echo "Rungs:      $(echo $IMAGE_SET | wc -w)"
echo

CRITEST_RC=0
first=1

# Remove every published copy of a rung, not just the one variant being run.
# perf-plain/X and perf-erofs/X are byte-identical, so they resolve to the same
# chainIDs and containerd keeps a snapshot alive while either image references
# it. Evicting only one leaves the other's unpack already done.
purge_rung() {
    local ref="$1" rung sibling
    rung="${ref##*/}"
    for sibling in perf-plain perf-erofs; do
        crictl -r "$ENDPOINT" rmi "${REGISTRY}/${sibling}/${rung}" >/dev/null 2>&1 || true
    done
    crictl -r "$ENDPOINT" rmi "$ref" >/dev/null 2>&1 || true
}

# Which snapshotter actually serves a pull on this node.
#
# A dedicated probe rather than a before/after around the whole run, because
# critest's image_lifecycle suite removes each image as one of its measured
# operations, so snapshot counts return to baseline and a run-level delta shows
# nothing. One explicit pull, counted on both sides, answers it directly.
detect_snapshotter() {
    local probe="$1"
    purge_rung "$probe"
    SNAP_PROBE_BEFORE="$(snapshot_counts)"
    crictl -r "$ENDPOINT" pull "$probe" >/dev/null 2>&1 || true
    SNAP_PROBE_AFTER="$(snapshot_counts)"
    purge_rung "$probe"
}

first_image="${IMAGE_SET%% *}"; first_image="${first_image#*=}"
detect_snapshotter "$first_image"
echo "Snapshotter probe: ${SNAP_PROBE_BEFORE}-> ${SNAP_PROBE_AFTER}"
echo

for variant in $IMAGE_SET; do
    label="${variant%%=*}"
    image="${variant#*=}"
    if [ "$label" = "$variant" ] || [ -z "$image" ]; then
        echo "skipping malformed variant '${variant}', expected label=imageref" >&2
        continue
    fi

    # The pod sandbox suite does not touch the benchmarked image, so run it only
    # once instead of repeating it for every rung of the ladder.
    if [ "$first" = 1 ]; then
        pods="$POD_SAMPLES"; first=0
    else
        pods=0
    fi

    # Only the runnable rung can host the container suite; see CONTAINER_RUNG.
    if [ "$label" = "$CONTAINER_RUNG" ]; then
        containers="$CONTAINER_SAMPLES"
    else
        containers=0
    fi

    # Both halves of a rung are byte-identical, so they share chainIDs. Whichever
    # half runs second would otherwise find the first half's snapshots already
    # committed and skip unpack entirely, quietly flattering it. `crictl rmi`
    # alone is not enough: it will not evict a snapshot another image still
    # references. Dropping both halves before each variant leaves the snapshot
    # unreferenced so containerd can release it, which is what makes the two
    # arms independent.
    purge_rung "$image"

    # critest does not create -benchmarking-output-dir; every result write fails
    # with only a log-level error (and a zero exit code) if it is missing.
    mkdir -p "${OUT}/${label}"

    # Only override the container image when this variant is actually measuring
    # containers. critest's "start a container from scratch" pod benchmark also
    # builds from defaultTestContainerImage, so pointing this at a ladder image
    # on a variant that is not measuring containers would fail that benchmark
    # for no benefit. Left unset, critest uses its own busybox default.
    images_arg=()
    if [ "$containers" -gt 0 ]; then
        cat >/var/tmp/critest-images.yaml <<IMAGES_EOF
defaultTestContainerImage: "${image}"
webServerTestImage: "${image}"
IMAGES_EOF
        images_arg=(-test-images-file /var/tmp/critest-images.yaml)
    fi

    # The parameters file must be flat lowerCamelCase. Nesting these keys makes
    # critest silently fall back to its defaults, which run a single sample and
    # emit no data files at all.
    cat >/var/tmp/critest-params.yaml <<PARAMS_EOF
containersNumber: ${containers}
containersNumberParallel: 1
containerBenchmarkTimeoutSeconds: 60
podsNumber: ${pods}
podsNumberParallel: 1
podBenchmarkTimeoutSeconds: 60
imagesNumber: ${IMAGES}
imagesNumberParallel: 1
imageBenchmarkTimeoutSeconds: 120
imagePullingBenchmarkImage: "${image}"
podContainerStartBenchmarkTimeoutSeconds: 60
imageListingBenchmarkImages:
  - "${image}"
PARAMS_EOF

    echo "--- variant ${label}: ${image}"
    timeout "$BUDGET" critest -benchmark \
        -runtime-endpoint "$ENDPOINT" \
        -image-endpoint "$ENDPOINT" \
        "${images_arg[@]}" \
        -benchmarking-params-file /var/tmp/critest-params.yaml \
        -benchmarking-output-dir "${OUT}/${label}" 2>&1 | tail -15
    rc=${PIPESTATUS[0]}
    [ "$rc" -ne 0 ] && CRITEST_RC=$rc

    # Leave nothing cached for the next variant, for the same reason as the
    # purge above.
    purge_rung "$image"
    echo
done

# Summarize critest's own datapoints. critest emits raw per-operation
# nanosecond durations; percentiles are computed here only for readability,
# the raw files are left in $OUT for anything that wants them.
ACL_NODE_IMAGE="$NODE_IMAGE" \
ACL_KERNEL="$(uname -r)" \
ACL_SELINUX="$NODE_SELINUX" \
ACL_REPO="$REPO" \
ACL_SNAP_BEFORE="$SNAP_PROBE_BEFORE" \
ACL_SNAP_AFTER="$SNAP_PROBE_AFTER" \
ACL_CONTAINERD="$(containerd --version 2>/dev/null | awk '{print $3}')" \
python3 - "$OUT" "$CRITEST_RC" <<'PY'
import glob, json, os, sys

out_dir, rc = sys.argv[1], int(sys.argv[2])

def pct(samples, p):
    if not samples:
        return None
    k = max(0, min(len(samples) - 1, int(round((len(samples) - 1) * p / 100.0))))
    return round(samples[k] / 1e6, 2)

suites = {}
for path in sorted(glob.glob(os.path.join(out_dir, '*', '*.json'))):
    with open(path) as fh:
        data = json.load(fh)
    names = data.get('operationsNames', [])
    columns = {name: [] for name in names}
    totals = []
    for point in data.get('datapoints', []):
        durations = point.get('operationsDurationsNs', [])
        for index, name in enumerate(names):
            if index < len(durations):
                columns[name].append(durations[index])
        totals.append(point['endTime'] - point['startTime'])
    operations = {}
    for name in names:
        ordered = sorted(columns[name])
        if ordered:
            operations[name] = {
                'n': len(ordered),
                'minMs': pct(ordered, 0),
                'p50Ms': pct(ordered, 50),
                'p95Ms': pct(ordered, 95),
                'maxMs': pct(ordered, 100),
            }
    ordered_totals = sorted(totals)
    variant = os.path.basename(os.path.dirname(path))
    suite = os.path.basename(path).replace('_benchmark_data.json', '')
    suites[f'{variant}/{suite}'] = {
        'variant': variant,
        'suite': suite,
        'samples': len(totals),
        'totalP50Ms': pct(ordered_totals, 50),
        'totalP95Ms': pct(ordered_totals, 95),
        'operations': operations,
    }

for suite, body in suites.items():
    print(f"--- {suite}: {body['samples']} samples, "
          f"total p50 {body['totalP50Ms']} ms / p95 {body['totalP95Ms']} ms")
    for name, stats in body['operations'].items():
        print(f"      {name:<28} p50 {stats['p50Ms']:>9} ms   p95 {stats['p95Ms']:>9} ms")

# One node, one snapshotter: there is no in-run pair to difference, so report
# each operation across the ladder and let the comparison happen between runs on
# different node images. The node block below is what makes those runs joinable.
#
# Three operations are reported because they pull in opposite directions.
# PullImage pays for the extra bytes precomputed EROFS artifacts add;
# CreateContainer/StartContainer is where a ready-made EROFS image should earn
# them back by being mounted instead of unpacked. Reporting only the first shows
# the cost and hides the benefit.
def snap_delta(before, after):
    def parse(s):
        return dict((k, int(v)) for k, v in
                    (kv.split('=', 1) for kv in s.split() if '=' in kv))
    b, a = parse(before), parse(after)
    return {k: {'before': b[k], 'after': a.get(k, b[k]),
                'delta': a.get(k, b[k]) - b[k]} for k in b}

node = {
    'image': os.environ.get('ACL_NODE_IMAGE', '').strip(),
    'kernel': os.environ.get('ACL_KERNEL', ''),
    'containerd': os.environ.get('ACL_CONTAINERD', ''),
    'selinux': os.environ.get('ACL_SELINUX', ''),
    'imageRepo': os.environ.get('ACL_REPO', ''),
    'snapshotters': snap_delta(os.environ.get('ACL_SNAP_BEFORE', ''),
                               os.environ.get('ACL_SNAP_AFTER', '')),
}

# The snapshotter that gained snapshots is the one that served the run. Stated
# explicitly so a result can never be attributed to the wrong storage path.
active = [k for k, v in node['snapshotters'].items() if v['delta'] > 0]
node['activeSnapshotter'] = active[0] if len(active) == 1 else (active or ['unknown'])

def table(title, suite_name, op):
    rows = {}
    for body in suites.values():
        if body['suite'] == suite_name and op in body['operations']:
            rows[body['variant']] = body['operations'][op]
    if not rows:
        return
    print(f"\n--- {title} on {node['activeSnapshotter']} "
          f"(node: {node['image'] or 'unknown'})")
    print(f"      {'image':<28} {'n':>4} {'p50 ms':>10} {'p95 ms':>10} {'max ms':>10}")
    for rung in sorted(rows, key=lambda r: rows[r]['p50Ms'] or 0):
        s = rows[rung]
        print(f"      {rung:<28} {s['n']:>4} {s['p50Ms']:>10} {s['p95Ms']:>10} {s['maxMs']:>10}")

table('PullImage', 'image_lifecycle', 'PullImage')
for op in ('CreateContainer', 'StartContainer'):
    table(op, 'container', op)

deltas = ', '.join('{} {:+d}'.format(k, v['delta']) for k, v in node['snapshotters'].items())
print(f"\nActive snapshotter: {node['activeSnapshotter']}  ({deltas})")

print("ACL_CRITEST_JSON=" + json.dumps(
    {'critestRc': rc, 'node': node, 'suites': suites}, sort_keys=True))

if rc != 0:
    print(f"critest exited {rc}", file=sys.stderr)
    sys.exit(1)
if not suites:
    print("critest produced no benchmark data", file=sys.stderr)
    sys.exit(1)
PY
