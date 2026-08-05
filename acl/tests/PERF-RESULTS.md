# Performance results contract

Every performance benchmark under `acl/tests/` emits the same results document,
so a consumer can read all of them without knowing which suites exist. The
pipeline merges one document per benchmark into a single `perf-results.json`
artifact and **fails the merge** if a producer drifts from this contract.

## Producers

| script | suites | where it runs |
|---|---|---|
| `run-critest-benchmark.sh` | `PodSandbox`, `container`, `image_lifecycle` | in the VM |
| `run-boot-benchmark.sh` | `boot` | on the host, against the VM |

## Emission

Each script prints the document as a **single line** prefixed `ACL_PERF_RESULTS=`
and also writes it to a file. The line is what the pipeline consumes: benchmarks
run inside (or against) a VM that is destroyed afterwards, so only stdout is
guaranteed to survive. The file exists for anyone running the script by hand.

## Document

```json
{
  "schemaVersion": 1,
  "run":  { "startedAt": "...", "finishedAt": "...", "suites": ["boot", "..."] },
  "node": { "image": "...", "kernel": "...", "containerd": "...",
            "selinux": "...", "activeSnapshotter": "erofs" },
  "metrics": [ { "suite": "...", "operation": "...", "unit": "ms",
                 "n": 30, "minMs": 1.0, "p50Ms": 2.0, "maxMs": 4.0,
                 "samplesMs": [1.0, 2.0, 3.0] } ],
  "suites": { }
}
```

### Raw numbers, not percentiles

Phase 1 reports `minMs`, `p50Ms` (median) and `maxMs`, plus `samplesMs` — every
individual measurement. Each of those three is an actual observation rather than
an interpolation, so nothing in the summary is synthesised.

There is deliberately **no p95**. The percentile index rounds onto the last
sample whenever n is 10 or fewer, so a p95 column would have silently repeated
`maxMs` for the boot suite (n=5) and the image suite (n=10) — including
`PullImage`, the metric the erofs comparison turns on. A single unlucky pull
would have been presented as a tail estimate. Only the n=30 suites could produce
an honest p95, and a column that means one thing in two suites and another in
the rest is worse than no column.

A median is still reported alongside min/max because these distributions are
right-skewed: one slow sample from a page-cache miss or a noisy neighbour moves
a mean and leaves a median alone, so a mean would make runs look different when
only the noise differed.

`samplesMs` carries every measurement. It lets a reader recompute any statistic
honestly — including a percentile later, once sample counts justify one — lets a
dashboard aggregate across runs instead of averaging averages, and it is the only
copy that survives: critest's own raw JSON stays on the VM and dies with it.

`metrics` is the array a dashboard should ingest. It is deliberately flat and
denormalized: one row per measured operation, each row carrying every key needed
to group it (`suite`, `image`, `operation`, `snapshotter`, `nodeImage`,
`containerd`). Adding a suite or an operation **appends rows** rather than
reshaping the document, so a consumer written today keeps working.

`suites` retains each producer's own nested shape for detail. It mirrors upstream
tooling output and will churn as that tooling changes — do not build on it.

### Required row keys

The merge validates `suite`, `operation`, `unit`, `n`, `p50Ms`, `samplesMs` on
every row, and rejects any document whose `schemaVersion` is not 1. This is
enforcement rather than documentation: a producer that drifts fails the build
instead of quietly emitting a half-shaped document that a dashboard would
misread months later.

## What the `boot` suite measures

Rows are phases (`Firmware`, `Loader`, `Kernel`, `Initrd`, `Userspace`, `Total`)
plus a `unit:<name>` row per interesting unit. Values come from systemd's own
timestamps via `systemctl show`, not from `systemd-analyze time` prose, whose
wording changes between releases.

systemd cannot *observe* most of a boot — `CLOCK_MONOTONIC` starts at kernel
start, so it reconstructs. The kernel's duration is the monotonic clock read the
instant PID 1 starts in the initrd; the initrd's is serialized across
`switch-root`. Firmware and boot loader run *before* the clock exists, so systemd
cannot time them at all — it reads `LoaderTimeInitUSec` / `LoaderTimeExecUSec`,
EFI variables written by the boot loader.

**`Total` therefore depends on the platform**, and the script prints a coverage
line saying which case applied:

- EFI variables present — `Total` spans firmware through default-target and
  matches `systemd-analyze time` on the same machine. ACL builds
  `bootloaderMode=uki` and systemd-stub writes these variables, so this is the
  expected case.
- EFI variables absent (no efivarfs at runtime) — the `Firmware` and `Loader`
  rows are **omitted rather than reported as 0**, and `Total` covers kernel
  onward. A zero would claim instantaneous firmware; an absent row admits the
  measurement was unavailable.

Two limits apply either way. `Total` ends at default-target, which is **not**
node-ready — containerd, kubelet and CNI come up after it, which is what the
`unit:` rows are for. And it measures *guest* boot only: hypervisor and VM
provisioning are outside it, so this is not `az vm create` → ready.

The current boot is discarded rather than sampled: it is the provisioning boot,
carrying cloud-init and disk-growth work that never recurs, so counting it would
bias every run by a constant nobody experiences twice.

## Identity

Benchmarks record what they can observe from the VM (`node`, timings). Build
identity — `buildId`, `galleryImageId`, `branch`, `commit` — is stamped on by the
pipeline, because those variables exist on the agent and not in the VM.

The join key is `run.galleryImageId`: it names the exact node image that was
measured and embeds the build id, and unlike a branch name it cannot later point
somewhere else.

## Adding a suite

1. Emit the document above, with your rows tagged with a new `suite` value.
2. Name the script `*-benchmark.sh` — the pipeline tees any script matching that
   pattern and feeds it to the merge.
3. Register it in `run_smoke_tests.sh` behind `ACL_RUN_PERF_TESTS`, in
   `SMOKE_TESTS` (runs in the VM) or `HOST_TESTS` (runs against the VM).
