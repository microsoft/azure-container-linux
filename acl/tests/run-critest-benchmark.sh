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
#   ACL_CNI_BIN_DIR   where CNI plugin binaries live       (default /opt/cni/bin)
#   ACL_CNI_VERSION   containernetworking/plugins release  (default v1.6.2)
#   ACL_CNI_TARBALL   pre-staged plugins tarball; skips the download entirely

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
# This was empty until containerd2-2.2.4-6017.verity. An EROFS layer is shared
# by every container using it, but all those mounts resolve to one superblock,
# and two containerd paths disagreed about the security settings to mount it
# with -- so the second container to want a layer was rejected with "SELinux:
# mount invalid. Same superblock, different security settings". Overlayfs is
# unaffected, since each container gets its own overlay superblock, which is why
# this went unnoticed for so long: every container benchmarked before then came
# from an overlayfs snapshot.
#
# It defaults on now, and deliberately on every arm rather than only the EROFS
# ones. A container-start number from an EROFS node means nothing on its own;
# it is only readable against the same number from an overlayfs node. Gating
# this to the arms that have a snapshotter to show off would leave the
# comparison with nothing to compare against.
#
# Set CRITEST_CONTAINER_RUNG= (empty) to skip it -- needed on a node whose
# containerd predates the fix, where the second container start would fail.
CONTAINER_RUNG="${CRITEST_CONTAINER_RUNG-busybox}"

# A rung naming an image the ladder does not carry would match no variant, and
# the container suite would then never run while the document still claimed to
# have measured everything it was asked to. Since the rung defaults on, that
# would most likely happen to someone who narrowed CRITEST_LADDER for a quick
# run and did not realise busybox was load-bearing. Say so instead.
if [ -n "$CONTAINER_RUNG" ]; then
    case " $(for r in $LADDER; do printf '%s ' "${r%%:*}"; done)" in
        *" $CONTAINER_RUNG "*) ;;
        *) echo "WARNING: CRITEST_CONTAINER_RUNG='$CONTAINER_RUNG' matches no rung in the ladder; the container suite will not run" >&2 ;;
    esac
fi
ENDPOINT="unix:///run/containerd/containerd.sock"
OUT=/var/tmp/critest-out

# Results are emitted twice: as a file for anyone running this by hand on a
# node, and as a single greppable stdout line because the pipeline runs this on
# a remote VM and only stdout is guaranteed to come back.
RESULTS_JSON="${CRITEST_RESULTS_JSON:-/var/tmp/critest-results.json}"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# How many times a variant may be re-run when, and only when, it trips the
# known-transient loopback CNI failure described at the retry loop below.
CRITEST_MAX_ATTEMPTS="${CRITEST_MAX_ATTEMPTS:-3}"

command -v critest >/dev/null 2>&1 || { echo "critest is not installed" >&2; exit 1; }
systemctl is-active --quiet containerd || { echo "containerd is not active" >&2; exit 1; }

# critest's pod and container suites need a working CNI network; the image
# suites do not. ACL ships no CNI plugins at all -- on a real node AKS installs
# them at provisioning time -- so a bare test VM has an empty /opt/cni/bin and
# every RunPodSandbox fails with `failed to find plugin "bridge" in path`.
# Stage the upstream plugins ourselves, pinned and checksummed. /usr is
# read-only (dm-verity + sysext) so this has to land in /opt, which is writable.
CNI_BIN_DIR="${ACL_CNI_BIN_DIR:-/opt/cni/bin}"
# v1.7.1 is the floor, not a preference. Anything older links
# vishvananda/netlink v1.3.0, which reports a dump the kernel flagged with
# NLM_F_DUMP_INTR as a plain EINTR -- and that is the "loopback failed (add):
# interrupted system call" this suite kept dying on. See the retry loop below
# for the full mechanism. v1.7.1 was the first release to pick up netlink
# v1.3.1, where that condition became its own error type; v1.9.1 carries the
# same netlink and is simply current.
CNI_VERSION="${ACL_CNI_VERSION:-v1.9.1}"
CNI_PLUGINS="bridge host-local loopback portmap"
CNI_AVAILABLE=1

case "$(uname -m)" in
    x86_64)  CNI_ARCH=amd64; CNI_SHA256=b98f74a0f8522f0a83867178729c1aa70f2158f90c45a2ca8fa791db1c76b303 ;;
    aarch64) CNI_ARCH=arm64; CNI_SHA256=56171987d3947707c3563db2f4001bccaf50fd63468611b9f3cbecb1375ee7ec ;;
    *)       CNI_ARCH=""; CNI_SHA256="" ;;
esac

missing_cni_plugins() {
    local p missing=""
    for p in $CNI_PLUGINS; do
        [ -x "${CNI_BIN_DIR}/${p}" ] || missing="${missing} ${p}"
    done
    printf '%s' "${missing# }"
}

install_cni_plugins() {
    local tarball="${ACL_CNI_TARBALL:-}" tmp
    if [ -z "$tarball" ]; then
        [ -n "$CNI_ARCH" ] || { echo "no CNI build for $(uname -m)" >&2; return 1; }
        tmp="$(mktemp -d)"
        tarball="${tmp}/cni-plugins.tgz"
        curl -sSL --retry 3 --retry-delay 2 -m 120 -o "$tarball" \
            "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-${CNI_ARCH}-${CNI_VERSION}.tgz" \
            || { echo "could not download CNI plugins ${CNI_VERSION}/${CNI_ARCH}" >&2; return 1; }
        # Verify before extracting: this is a network artifact being unpacked as
        # root into a directory containerd will exec from.
        echo "${CNI_SHA256}  ${tarball}" | sha256sum -c - >/dev/null 2>&1 \
            || { echo "CNI plugins checksum mismatch; refusing to install" >&2; return 1; }
    fi
    mkdir -p "$CNI_BIN_DIR"
    tar -xzf "$tarball" -C "$CNI_BIN_DIR" $(printf './%s ' $CNI_PLUGINS) \
        || { echo "could not extract CNI plugins" >&2; return 1; }
    return 0
}

if [ -n "$(missing_cni_plugins)" ]; then
    echo "CNI plugins missing from ${CNI_BIN_DIR} ($(missing_cni_plugins)); installing ${CNI_VERSION}"
    install_cni_plugins || CNI_AVAILABLE=0
    still_missing="$(missing_cni_plugins)"
    if [ "$CNI_AVAILABLE" = 1 ] && [ -n "$still_missing" ]; then
        echo "CNI plugins still missing after install:${still_missing}" >&2
        CNI_AVAILABLE=0
    fi
fi

# Drop in a minimal bridge conflist. Guarded: never clobber a real network
# configuration, and never advertise a config whose plugins we could not stage.
if [ "$CNI_AVAILABLE" = 1 ] && [ -z "$(ls -A /etc/cni/net.d 2>/dev/null)" ]; then
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

# Every plugin type named by the active conflist must resolve to a binary.
# containerd reports NetworkReady once it has *parsed* a conflist -- it never
# checks that the referenced plugins exist -- so NetworkReady alone is a false
# green. That is exactly how a whole benchmark run got to exec time before
# failing on a missing bridge plugin.
cni_types_resolve() {
    local conf types t
    conf="$(ls -1 /etc/cni/net.d/*.conflist /etc/cni/net.d/*.conf 2>/dev/null | head -1)"
    [ -n "$conf" ] || { echo "no CNI configuration in /etc/cni/net.d" >&2; return 1; }
    types="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for p in d.get("plugins", [d]):
    if p.get("type"): print(p["type"])
    ipam = p.get("ipam") or {}
    if ipam.get("type"): print(ipam["type"])
' "$conf" 2>/dev/null)" || { echo "could not parse ${conf}" >&2; return 1; }
    for t in $types; do
        [ -x "${CNI_BIN_DIR}/${t}" ] || { echo "CNI config ${conf} needs plugin '${t}', absent from ${CNI_BIN_DIR}" >&2; return 1; }
    done
    return 0
}

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

if [ "$CNI_AVAILABLE" = 1 ]; then
    for _ in $(seq 1 30); do
        network_ready && break
        sleep 2
    done
    if ! network_ready; then
        echo "containerd never reported NetworkReady" >&2
        CNI_AVAILABLE=0
    elif ! cni_types_resolve; then
        CNI_AVAILABLE=0
    fi
fi

# Degrade instead of failing the build. The image suites need no sandbox, and
# PullImage is the headline erofs metric, so a node without usable networking
# still produces the numbers this benchmark exists to collect. The results
# document records cniAvailable so a consumer can tell "not measured" apart
# from "measured as zero".
if [ "$CNI_AVAILABLE" != 1 ]; then
    echo "WARNING: no usable CNI; skipping pod and container suites, image suites still run" >&2
    POD_SAMPLES=0
    CONTAINER_SAMPLES=0
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
if [ -n "$CONTAINER_RUNG" ]; then
    container_line="${CONTAINER_SAMPLES} containers on ${CONTAINER_RUNG}"
else
    container_line="no container rung"
fi
echo "Samples:    ${POD_SAMPLES} pods (first rung), ${container_line}, ${IMAGES} image iterations"
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

# Sandboxes and containers left behind by an earlier run hold references to
# committed snapshots, so `crictl rmi` removes the image record but cannot
# release the snapshot. Everything downstream then silently degrades: the
# snapshotter probe sees a zero delta because its pull reuses the surviving
# snapshot, and purge_rung stops isolating variants, so a later rung is
# credited with an unpack that never happened. Clear the runtime before
# measuring anything.
reset_runtime_state() {
    crictl -r "$ENDPOINT" rmp -fa >/dev/null 2>&1 || true
    crictl -r "$ENDPOINT" rm -fa >/dev/null 2>&1 || true
}

reset_runtime_state

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
    # critest's "start a container from scratch" spec builds its own sandbox and
    # is not gated by podsNumber, so podsNumber=0 does not stop it from running
    # and failing on a node with no usable CNI. Skip it explicitly instead.
    skip_arg=()
    if [ "$CNI_AVAILABLE" != 1 ]; then
        skip_arg=(-ginkgo.skip 'start a container from scratch')
    fi
    # Keep the whole run: on failure critest prints the reason *above* its
    # summary, so tailing the output discards exactly the lines that explain
    # what went wrong. Show a tail when it passes, the full log when it does not.
    variant_log="${OUT}/${label}.critest.log"
    # The loopback CNI plugin can fail sandbox setup with `plugin
    # type="loopback" failed (add): interrupted system call`. Despite the
    # wording this is not a signal interrupting a syscall: the kernel sets
    # NLM_F_DUMP_INTR on a netlink dump whose underlying table changed while
    # it was being walked, and vishvananda/netlink up to v1.3.0 surfaced that
    # flag as a bare EINTR, which the plugin treats as fatal. A benchmark that
    # creates and tears down sandboxes back to back is close to a worst case
    # for it -- one sandbox's veth teardown perturbs the dump another sandbox's
    # setup is walking -- which is why it lands here far more often than in
    # ordinary use, and why it is not a property of the image under test.
    #
    # Pinning CNI >= v1.7.1 above (netlink v1.3.1, where the condition became
    # its own error type) is the actual fix. This retry stays as a backstop,
    # but it was never a sufficient one: at the rate the old pin failed, three
    # attempts still lost roughly a third of builds outright. Builds 1181555
    # (failed 3/3) and 1181557 (failed 2, passed on the third) were the same
    # code on the same day, differing only in luck -- which is what ruled out
    # the IPE toggle they appeared to correlate with. Every other failure is
    # still fatal on its first occurrence.
    attempt=1
    while :; do
        timeout "$BUDGET" critest -benchmark \
            -runtime-endpoint "$ENDPOINT" \
            -image-endpoint "$ENDPOINT" \
            "${images_arg[@]}" \
            "${skip_arg[@]}" \
            -benchmarking-params-file /var/tmp/critest-params.yaml \
            -benchmarking-output-dir "${OUT}/${label}" >"$variant_log" 2>&1
        rc=$?
        [ "$rc" -eq 0 ] && break
        grep -q 'interrupted system call' "$variant_log" || break
        [ "$attempt" -ge "$CRITEST_MAX_ATTEMPTS" ] && break
        echo "--- critest hit the loopback netlink-dump EINTR for ${label} (attempt ${attempt}/${CRITEST_MAX_ATTEMPTS}); retrying"
        # A retry has to start as cold as the first attempt did. The failed run
        # leaves its pulled image and committed snapshots behind, so without a
        # purge the retry would measure the warm path and report a cold pull
        # that never happened. Its partial datapoint files have to go too, or
        # the summarizer below averages them in with the retry's.
        purge_rung "$image"
        rm -rf "${OUT:?}/${label}"
        mkdir -p "${OUT}/${label}"
        attempt=$((attempt + 1))
    done
    if [ "$rc" -ne 0 ]; then
        CRITEST_RC=$rc
        echo "--- critest FAILED for ${label} (exit ${rc}) after ${attempt} attempt(s); full output follows:"
        cat "$variant_log"
    else
        [ "$attempt" -gt 1 ] && echo "--- critest passed for ${label} on attempt ${attempt}/${CRITEST_MAX_ATTEMPTS}"
        tail -15 "$variant_log"
    fi

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
ACL_STARTED_AT="$STARTED_AT" \
ACL_LADDER="$LADDER" \
ACL_CNI_AVAILABLE="$CNI_AVAILABLE" \
python3 - "$OUT" "$CRITEST_RC" "$RESULTS_JSON" <<'PY'
import glob, json, os, sys, time

out_dir, rc, results_path = sys.argv[1], int(sys.argv[2]), sys.argv[3]

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
                'maxMs': pct(ordered, 100),
                # The measurements themselves. critest's own raw JSON stays on
                # the VM and dies with it, so this is the only surviving copy.
                'samplesMs': [round(v / 1e6, 2) for v in ordered],
            }
    ordered_totals = sorted(totals)
    variant = os.path.basename(os.path.dirname(path))
    suite = os.path.basename(path).replace('_benchmark_data.json', '')
    suites[f'{variant}/{suite}'] = {
        'variant': variant,
        'suite': suite,
        'samples': len(totals),
        'totalMinMs': pct(ordered_totals, 0),
        'totalP50Ms': pct(ordered_totals, 50),
        'totalMaxMs': pct(ordered_totals, 100),
        'totalSamplesMs': [round(v / 1e6, 2) for v in ordered_totals],
        'operations': operations,
    }

for suite, body in suites.items():
    print(f"--- {suite}: {body['samples']} samples, "
          f"total min {body['totalMinMs']} / med {body['totalP50Ms']} / "
          f"max {body['totalMaxMs']} ms")
    for name, stats in body['operations'].items():
        print(f"      {name:<28} min {stats['minMs']:>9}   med {stats['p50Ms']:>9}   "
              f"max {stats['maxMs']:>9} ms")

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
    # False means the pod and container suites were skipped for lack of a
    # usable CNI, not that they measured zero.
    'cniAvailable': os.environ.get('ACL_CNI_AVAILABLE', '1') == '1',
    'snapshotters': snap_delta(os.environ.get('ACL_SNAP_BEFORE', ''),
                               os.environ.get('ACL_SNAP_AFTER', '')),
}

# The snapshotter that gained snapshots is the one that served the run. Stated
# explicitly so a result can never be attributed to the wrong storage path.
# The probe delta is the primary signal, but it goes blind if a pull was served
# from a snapshot that survived the purge. Absolute counts still answer the
# question in that case, so fall back to them rather than reporting 'unknown'
# and losing the attribution the whole A/B matrix depends on. How it was
# decided is recorded, so a consumer never has to guess how much to trust it.
active = [k for k, v in node['snapshotters'].items() if v['delta'] > 0]
if len(active) == 1:
    node['activeSnapshotter'] = active[0]
    node['activeSnapshotterSource'] = 'probeDelta'
else:
    nonzero = [k for k, v in node['snapshotters'].items() if v['after'] > 0]
    if len(nonzero) == 1:
        node['activeSnapshotter'] = nonzero[0]
        node['activeSnapshotterSource'] = 'absoluteCount'
    else:
        node['activeSnapshotter'] = active or nonzero or ['unknown']
        node['activeSnapshotterSource'] = 'ambiguous'

def table(title, suite_name, op):
    rows = {}
    for body in suites.values():
        if body['suite'] == suite_name and op in body['operations']:
            rows[body['variant']] = body['operations'][op]
    if not rows:
        return
    print(f"\n--- {title} on {node['activeSnapshotter']} "
          f"(node: {node['image'] or 'unknown'})")
    print(f"      {'image':<28} {'n':>3} {'min ms':>10} {'med ms':>10} {'max ms':>10}   samples (ms)")
    for rung in sorted(rows, key=lambda r: rows[r]['p50Ms'] or 0):
        s = rows[rung]
        print(f"      {rung:<28} {s['n']:>3} {s['minMs']:>10} {s['p50Ms']:>10} "
              f"{s['maxMs']:>10}   {' '.join(str(v) for v in s['samplesMs'])}")

table('PullImage', 'image_lifecycle', 'PullImage')
for op in ('CreateContainer', 'StartContainer'):
    table(op, 'container', op)

deltas = ', '.join('{} {:+d}'.format(k, v['delta']) for k, v in node['snapshotters'].items())
print(f"\nActive snapshotter: {node['activeSnapshotter']}  ({deltas})")

# Identity of the run itself. Without this a datapoint cannot be plotted over
# time or joined back to the build that produced it, which is the difference
# between a log line and a dashboard. The ADO variables are read from the
# environment so the script stays runnable by hand, where they are simply absent.
run = {
    'startedAt': os.environ.get('ACL_STARTED_AT', ''),
    'finishedAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    'buildId': os.environ.get('BUILD_BUILDID', ''),
    'buildNumber': os.environ.get('BUILD_BUILDNUMBER', ''),
    'pipeline': os.environ.get('SYSTEM_DEFINITIONNAME', ''),
    'jobName': os.environ.get('AGENT_JOBNAME', ''),
    'branch': os.environ.get('ACL_SCRIPTS_REF', '') or os.environ.get('BUILD_SOURCEBRANCH', ''),
    'commit': os.environ.get('BUILD_SOURCEVERSION', ''),
    'ladder': os.environ.get('ACL_LADDER', '').split(),
}

# Nested `suites` mirrors critest's own shape and will churn as critest changes.
# `metrics` is the flat, denormalized view a dashboard should ingest: one row per
# measured operation, with every key it needs to group by already on the row.
# Adding a suite or an operation appends rows instead of reshaping the document.
metrics = []
for body in suites.values():
    common = {
        'suite': body['suite'],
        'image': body['variant'],
        'snapshotter': node['activeSnapshotter'],
        'nodeImage': node['image'],
        'containerd': node['containerd'],
    }
    for name, stats in body['operations'].items():
        metrics.append(dict(common, operation=name, unit='ms', **stats))
    metrics.append(dict(common, operation='TOTAL', unit='ms',
                        n=body['samples'], minMs=body['totalMinMs'],
                        p50Ms=body['totalP50Ms'], maxMs=body['totalMaxMs'],
                        samplesMs=body['totalSamplesMs']))
metrics.sort(key=lambda m: (m['suite'], m['image'], m['operation']))

document = {
    'schemaVersion': 1,
    'critestRc': rc,
    'run': run,
    'node': node,
    'metrics': metrics,
    'suites': suites,
}

try:
    with open(results_path, 'w') as fh:
        json.dump(document, fh, indent=2, sort_keys=True)
    print(f"\nResults written to {results_path} ({len(metrics)} metric rows)")
except OSError as exc:
    print(f"\ncould not write {results_path}: {exc}", file=sys.stderr)

# Single line, no embedded newlines: the pipeline runs this on a remote VM and
# recovers the payload by grepping this prefix out of the job log.
print("ACL_PERF_RESULTS=" + json.dumps(document, sort_keys=True))

if rc != 0:
    print(f"critest exited {rc}", file=sys.stderr)
    sys.exit(1)
if not suites:
    print("critest produced no benchmark data", file=sys.stderr)
    sys.exit(1)
PY
