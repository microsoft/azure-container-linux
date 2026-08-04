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

# notaryaksegistry has anonymous pull enabled, so no ACR credentials are needed
# on the test VM.
REGISTRY="${ACL_PERF_REGISTRY:-notaryaksegistry.azurecr.io}"

# Pinned by digest on purpose. This manifest carries the precomputed EROFS
# dm-verity referrers (application/vnd.cncf.notary.dmverity.v1). The
# :validation-20260709-1630 tag currently resolves to this same digest, but the
# tag has been re-pointed before; pinning keeps a re-push from silently
# benchmarking the ordinary unpacking path instead of the precomputed one.
PRECOMPUTED_IMAGE="${REGISTRY}/dmverity-precomputed-test/pause@sha256:7c38f24774e3cbd906d2d33c38354ccf787635581c122965132c9bd309754d4a"
UNSIGNED_IMAGE="${REGISTRY}/test-unsigned/busybox:1.36"

# critest's imagePullingBenchmarkImage takes exactly one reference, so the only
# way to benchmark more than one image is to run critest once per variant. Each
# variant gets its own output directory and its suites are reported under
# "<label>/<suite>".
#
# NOTE: the two defaults are NOT a controlled A/B. The precomputed pause layer
# is ~316 KB and the unsigned busybox layer is ~2.2 MB, so any PullImage
# difference between them is dominated by image size, not by the dm-verity
# path. Isolating the precomputed path needs two images with identical content
# where only one carries the referrers; until such a pair exists these are
# reported side by side without a delta.
IMAGE_SET="${CRITEST_IMAGE_SET:-precomputed=${PRECOMPUTED_IMAGE} unsigned=${UNSIGNED_IMAGE}}"
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
echo "Samples:   ${SAMPLES} pods/containers, ${IMAGES} image iterations"
echo "Variants:  ${IMAGE_SET}"
echo

CRITEST_RC=0
for variant in $IMAGE_SET; do
    label="${variant%%=*}"
    image="${variant#*=}"
    if [ "$label" = "$variant" ] || [ -z "$image" ]; then
        echo "skipping malformed variant '${variant}', expected label=imageref" >&2
        continue
    fi

    # critest does not create -benchmarking-output-dir; every result write fails
    # with only a log-level error (and a zero exit code) if it is missing.
    mkdir -p "${OUT}/${label}"

    # The parameters file must be flat lowerCamelCase. Nesting these keys makes
    # critest silently fall back to its defaults, which run a single sample and
    # emit no data files at all.
    cat >/var/tmp/critest-params.yaml <<PARAMS_EOF
containersNumber: ${SAMPLES}
containersNumberParallel: 1
containerBenchmarkTimeoutSeconds: 60
podsNumber: ${SAMPLES}
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
        -benchmarking-params-file /var/tmp/critest-params.yaml \
        -benchmarking-output-dir "${OUT}/${label}" 2>&1 | tail -40
    rc=${PIPESTATUS[0]}
    [ "$rc" -ne 0 ] && CRITEST_RC=$rc
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

# PullImage side by side. Deliberately no percentage delta: the variants are
# different images, so a delta would mostly reflect layer size rather than the
# dm-verity path. Compare these only against the same variant on another image.
pulls = {b['variant']: b['operations']['PullImage']
         for b in suites.values()
         if b['suite'] == 'image_lifecycle' and 'PullImage' in b['operations']}
if len(pulls) > 1:
    print("\n--- PullImage by image variant (different images; not a controlled A/B)")
    for variant in sorted(pulls):
        stats = pulls[variant]
        print(f"      {variant:<28} p50 {stats['p50Ms']:>9} ms   "
              f"p95 {stats['p95Ms']:>9} ms")

print("ACL_CRITEST_JSON=" + json.dumps({'critestRc': rc, 'suites': suites}, sort_keys=True))

if rc != 0:
    print(f"critest exited {rc}", file=sys.stderr)
    sys.exit(1)
if not suites:
    print("critest produced no benchmark data", file=sys.stderr)
    sys.exit(1)
PY
