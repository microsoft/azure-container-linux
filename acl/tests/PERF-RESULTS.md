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
                 "n": 30, "minMs": 1.0, "p50Ms": 2.0,
                 "p95Ms": 3.0, "maxMs": 4.0 } ],
  "suites": { }
}
```

`metrics` is the array a dashboard should ingest. It is deliberately flat and
denormalized: one row per measured operation, each row carrying every key needed
to group it (`suite`, `image`, `operation`, `snapshotter`, `nodeImage`,
`containerd`). Adding a suite or an operation **appends rows** rather than
reshaping the document, so a consumer written today keeps working.

`suites` retains each producer's own nested shape for detail. It mirrors upstream
tooling output and will churn as that tooling changes — do not build on it.

### Required row keys

The merge validates `suite`, `operation`, `unit`, `n`, `p50Ms`, `p95Ms` on every
row, and rejects any document whose `schemaVersion` is not 1. This is enforcement
rather than documentation: a producer that drifts fails the build instead of
quietly emitting a half-shaped document that a dashboard would misread months
later.

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
