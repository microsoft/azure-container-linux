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

# Controlled A/B ladder. Each rung is published twice from the same source with
# byte-identical content and a shared manifest digest; only perf-erofs/* carries
# the application/vnd.cncf.notary.dmverity.v1 referrers. Comparing a rung's two
# variants therefore isolates the precomputed EROFS path, and comparing across
# rungs shows how that difference scales with image size (2 MB to 130 MB).
#
# Published by sessions/dmverity-prototype/files/acl-perf/publish-ab-ladder.sh.
LADDER="${CRITEST_LADDER:-busybox:1-glibc pause:3.6 livenessprobe:v2.18.0 azure-cloud-node-manager:v1.34.8-2 kube-proxy:v1.34.7-2 azurefile-csi:v1.34.5}"

# critest's imagePullingBenchmarkImage takes exactly one reference, so each
# variant needs its own critest pass. Each gets its own output directory and its
# suites are reported under "<variant>/<suite>".
build_image_set() {
    local rung name
    for rung in $LADDER; do
        name="${rung%%:*}"
        printf 'plain-%s=%s/perf-plain/%s ' "$name" "$REGISTRY" "$rung"
        printf 'erofs-%s=%s/perf-erofs/%s ' "$name" "$REGISTRY" "$rung"
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
# image and is published through the same A/B pipeline, so it measures the
# precomputed EROFS path on container start without leaving the upstream path.
#
# Empty by default because the measurement is currently blocked by a real bug,
# not by anything in this script: on an SELinux-enforcing node no container can
# start from an erofs snapshot at all. containerd passes the SELinux label to
# mount(2) in the monolithic data string as
#   context="system_u:object_r:container_file_t:s0:c260,c546"
# and the kernel splits that string on commas without honouring the quotes, so
# erofs is handed the second MCS category on its own and rejects the mount with
# "Unknown parameter 'c546'" (EINVAL). Every container gets a unique MCS pair,
# so this affects all of them. Verified directly against a layer.erofs: no
# context mounts, a single category mounts, an unquoted pair fails, a quoted
# pair mounts. Overlayfs is unaffected, which is why this went unnoticed --
# every previously benchmarked container came from an overlayfs snapshot.
#
# Set CRITEST_CONTAINER_RUNG=busybox to run it once the mount path is fixed.
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

echo "=== ACL CRI benchmark (upstream critest) ==="
critest --version 2>/dev/null || true
echo "Kernel:    $(uname -r)"
echo "Runtime:   $(ctr --version 2>/dev/null || echo unknown)"
echo "Samples:   ${POD_SAMPLES} pods (first variant), ${CONTAINER_SAMPLES} containers/variant, ${IMAGES} image iterations"
echo "Variants:  $(echo $IMAGE_SET | wc -w)"
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
    if [ "${label#*-}" = "$CONTAINER_RUNG" ]; then
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

# Controlled A/B: plain-<rung> and erofs-<rung> are the same content and share a
# manifest digest, differing only in the dm-verity referrer, so this delta
# isolates the precomputed EROFS path rather than image size.
#
# Two operations are compared, because they pull in opposite directions:
# PullImage pays for the extra bytes the precomputed artifacts add, while
# CreateContainer/StartContainer is where a ready-made EROFS image should earn
# them back by being mounted instead of unpacked. Reporting only the first would
# show the cost and hide the benefit.
def collect(suite_name, op):
    found = {}
    for body in suites.values():
        if body['suite'] != suite_name or op not in body['operations']:
            continue
        variant = body['variant']
        if '-' not in variant:
            continue
        arm, rung = variant.split('-', 1)
        found.setdefault(rung, {})[arm] = body['operations'][op]
    return found

def report(title, data):
    paired = {r: a for r, a in data.items() if 'plain' in a and 'erofs' in a}
    if not paired:
        return set(data)
    print(f"\n--- {title}: precomputed EROFS vs plain (identical content)")
    print(f"      {'image':<28} {'plain p50':>10} {'erofs p50':>10} {'delta':>9}   "
          f"{'plain p95':>10} {'erofs p95':>10}")
    for rung in sorted(paired, key=lambda r: paired[r]['plain']['p50Ms'] or 0):
        plain, erofs = paired[rung]['plain'], paired[rung]['erofs']
        delta = (f"{(erofs['p50Ms'] - plain['p50Ms']) / plain['p50Ms'] * 100:+.1f}%"
                 if plain['p50Ms'] else 'n/a')
        print(f"      {rung:<28} {plain['p50Ms']:>10} {erofs['p50Ms']:>10} {delta:>9}   "
              f"{plain['p95Ms']:>10} {erofs['p95Ms']:>10}")
    return set(data) - set(paired)

pulls = collect('image_lifecycle', 'PullImage')
unpaired = report('PullImage', pulls)
for op in ('CreateContainer', 'StartContainer'):
    report(op, collect('container', op))

if unpaired:
    print(f"      (no plain/erofs pair for: {', '.join(sorted(unpaired))})")

print("ACL_CRITEST_JSON=" + json.dumps({'critestRc': rc, 'suites': suites}, sort_keys=True))

if rc != 0:
    print(f"critest exited {rc}", file=sys.stderr)
    sys.exit(1)
if not suites:
    print("critest produced no benchmark data", file=sys.stderr)
    sys.exit(1)
PY
