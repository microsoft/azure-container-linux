# ACL Container Runtime Performance

**Updated:** 2026-09-01

## Perf Results

| Question | Result |
|---|---|
| Did adding passive IPE files while keeping IPE off degrade performance? | **No broad difference is visible.** Base, passive-assets, and patched-overlayfs builds remain closely grouped across startup, Kubernetes exec, and OS-disk reads. However, base and passive-assets are different complete image generations, so this is not a one-variable asset isolate. |
| Does the patched runtime regress performance while it still uses overlayfs? | **Not broadly.** Pod-start and exec results remain aligned. Its signed-image cached pull is about **0.36 seconds slower** than base. |
| Does the active IPE + patched EROFS profile degrade performance? | **Yes, but less broadly after the containerd cache fix.** One-layer startup is now close to base, while eight-layer cached startup remains about **76% slower** and signed cached startup about **81% slower**. Direct signed pulls remain the largest regression. |
| Did the containerd snapshotter-cache fix work? | **Yes for its intended pod-sandbox path.** Mean pod startup improved by **10% to 60%** versus the superseded EROFS runs, while direct cached pull remained unchanged. The report now uses the Patch17 image as the forward EROFS baseline. |
| Is the remaining slowdown isolated to IPE auditing? | **No.** The image changes IPE policy evaluation, EROFS, dm-verity, signature handling, and runtime patches together. ACL build [1194357](https://dev.azure.com/mariner-org/ACL/_build/results?buildId=1194357) and MAP build [1194631](https://dev.azure.com/mariner-org/mariner/_build/results?buildId=1194631) provide the missing official-containerd + overlayfs image input, but the same-MAP IPE-off/permissive performance pair has not run yet. |
| Did broad exec or read/write performance regress? | **No host-local exec regression is visible.** The Patch17 run measured 622.9 us per execution with expected permissive DENY records. It did not run Kubernetes exec or OS-disk I/O, so the superseded EROFS values for those tests have been removed rather than mixed with the current runtime. |
| Do we have variability and tail data? | **Yes for Kubernetes startup.** The retained raw samples support sample standard deviation, p50, p90, p95, and maximum values. Direct pull and general-exec artifacts retained standard deviation and other aggregates, but not the raw vectors needed to calculate defensible p90/p95 values. |

## Configurations

| Display label | What it means |
|---|---|
| **Base image, base overlayfs** | Baseline ACL image and overlayfs runtime |
| **IPE off, passive assets** | Base containerd with overlayfs, passive IPE files are present but no policy is loaded |
| **IPE off, passive assets + patched overlayfs** | EROFS-capable patched containerd and passive IPE files are present, but overlayfs is selected and no IPE policy is loaded |
| **IPE audit, Patch17 EROFS** | IPE is enabled in audit mode and Patch17 containerd uses signed EROFS/dm-verity tar-index layers |

Every percentage below is relative to **Base image, base overlayfs** for the same metric.

## Statistical reporting

- **SD** is the sample standard deviation of the retained timing samples.
- **p90** and **p95** use the empirical nearest-rank percentile: 90% or 95%
  of observed timings were at or below that value.
- Kubernetes startup cells for the three IPE-off configurations pool two
  equal-sized accepted runs, producing `runs=2, n=60`. The Patch17 EROFS
  configuration currently has `runs=1, n=30`.
- Those values are repeated measurements nested inside pipeline runs and three
  nodes per run. They describe the observed timing distribution; they are not
  30 or 60 independent cluster replications or a confidence interval for all
  future clusters.
- The lifecycle scenario published mean, median, minimum, maximum, SD, and
  sample count, but did not retain its ten individual pull samples. Therefore
  this document does not invent pull p90/p95 values.

## 1. General performance

![General execution and OS-disk performance](./acl-general-performance.svg)

The graph remains an executive mean comparison. The table below adds the
available spread. `kubectl exec` has one historical run with 20 operations
for each IPE-off build. Host-local results pool two runs with 50 batch means
per run for each IPE-off build; the Patch17 EROFS result has one run with 50
batch means. Every batch contains 2,000 direct host executions.

| Configuration | `kubectl exec` mean (SD) | `kubectl exec` p50 / max | Host-local `/bin/true` mean (SD) |
|---|---:|---:|---:|
| Base image, base overlayfs | 241.7 ms (16.9 ms) (**baseline**) | 240.2 / 283.5 ms | 731.1 us (105.7 us) per exec (**baseline**) |
| IPE off, passive assets | 254.1 ms (17.3 ms) (**+5.1%**) | 250.9 / 280.8 ms | 733.0 us (128.5 us) per exec (**+0.3%**) |
| IPE off, passive assets + patched overlayfs | 246.9 ms (15.7 ms) (**+2.1%**) | 245.1 / 276.0 ms | 737.0 us (98.3 us) per exec (**+0.8%**) |
| IPE audit, Patch17 EROFS | **Not run in `1194985`** | **Not run** | 622.9 us (10.5 us) per exec (**-14.8%**) |

The accepted artifacts did not retain the individual `kubectl exec` or
host-local batch vectors, so p90/p95 cannot be reconstructed for these rows.
The SD values above are the distributions published by the harness, or the
exact pooled SD derived from equal-sized run distributions.

The Patch17 host-local run retained 51 expected permissive-IPE DENY records.
Those records are part of the measured audit-mode cost and do not invalidate
the result.

| Configuration | Sequential read | Random read | Sequential write | Random write |
|---|---:|---:|---:|---:|
| Base image, base overlayfs | 19,166.7 IOPS (**baseline**) | 19,251.5 IOPS (**baseline**) | 3,433.9 IOPS (**baseline**) | 2,812.8 IOPS (**baseline**) |
| IPE off, passive assets | 19,388.5 IOPS (**+1.2%**) | 19,405.8 IOPS (**+0.8%**) | 2,655.2 IOPS (**-22.7%**) | 3,353.7 IOPS (**+19.2%**) |
| IPE off, passive assets + patched overlayfs | 19,336.8 IOPS (**+0.9%**) | 19,271.1 IOPS (**+0.1%**) | 3,064.9 IOPS (**-10.7%**) | 2,189.4 IOPS (**-22.2%**) |
| IPE audit, Patch17 EROFS | **Not run in `1194985`** | **Not run** | **Not run** | **Not run** |

## 2. Container lifecycle

![Unsigned pod startup and signed-image lifecycle](./acl-container-lifecycle.svg)

The figure has two explicitly different panels:

| Measurement | Image and layer shape | Operation and timing boundary |
|---|---|---|
| **Unsigned Kubernetes startup** | Unsigned Alpine, 1 layer, about 3.6 MB; unsigned nginx-compatible image, 8 layers, about 21 MB | The timer starts immediately before `kubectl run`, not `kubectl apply`, and ends when tight polling observes Kubernetes pod phase `Running` on the pinned node. Cold proves the image absent and uses `imagePullPolicy=Always`; cached proves it is already cached on the host and uses `imagePullPolicy=Never`. |
| **Signed image pull** | One immutable signed nginx-compatible image, exactly 8 layers, about 21 MB | Direct node-side `crictl pull`, timed inside the node command after verifying that the image is absent or already cached on the host. Debug-pod setup is outside the timer. |
| **Signed Kubernetes startup** | The same signed 8-layer image | The same `kubectl run` to observed `Running` boundary as the unsigned panel. Cold includes pull and layer setup; cached uses the image already cached on the host with `imagePullPolicy=Never`. |

### Unsigned Kubernetes startup

Each run measures three nodes with ten iterations. The three IPE-off
configurations have `runs=2, n=60`; Patch17 EROFS has `runs=1, n=30`.

| Configuration | 1-layer cold | 1-layer cached | 8-layer cold | 8-layer cached |
|---|---:|---:|---:|---:|
| Base image, base overlayfs | 3.632 s (**baseline**) | 1.278 s (**baseline**) | 4.570 s (**baseline**) | 1.286 s (**baseline**) |
| IPE off, passive assets | 3.696 s (**+1.8%**) | 1.293 s (**+1.2%**) | 4.583 s (**+0.3%**) | 1.352 s (**+5.2%**) |
| IPE off, passive assets + patched overlayfs | 3.788 s (**+4.3%**) | 1.263 s (**-1.2%**) | 4.714 s (**+3.2%**) | 1.246 s (**-3.1%**) |
| IPE audit, Patch17 EROFS | 3.892 s (**+7.2%**) | 1.236 s (**-3.3%**) | 5.574 s (**+22.0%**) | 2.262 s (**+75.9%**) |

Detailed distributions:

| Configuration | Condition | n | Mean | SD | p50 | p90 | p95 | Max |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Base image, base overlayfs | 1-layer cold | 60 | 3.632 s | 0.343 s | 3.608 s | 4.083 s | 4.134 s | 4.310 s |
| Base image, base overlayfs | 1-layer cached | 60 | 1.278 s | 0.120 s | 1.275 s | 1.371 s | 1.378 s | 1.914 s |
| Base image, base overlayfs | 8-layer cold | 60 | 4.570 s | 0.359 s | 4.601 s | 4.957 s | 5.293 s | 5.423 s |
| Base image, base overlayfs | 8-layer cached | 60 | 1.286 s | 0.123 s | 1.301 s | 1.369 s | 1.375 s | 1.907 s |
| IPE off, passive assets | 1-layer cold | 60 | 3.696 s | 0.669 s | 3.584 s | 4.106 s | 4.170 s | 8.024 s |
| IPE off, passive assets | 1-layer cached | 60 | 1.293 s | 0.151 s | 1.278 s | 1.340 s | 1.422 s | 1.905 s |
| IPE off, passive assets | 8-layer cold | 60 | 4.583 s | 0.489 s | 4.559 s | 4.931 s | 5.178 s | 6.804 s |
| IPE off, passive assets | 8-layer cached | 60 | 1.352 s | 0.179 s | 1.321 s | 1.393 s | 1.811 s | 2.018 s |
| IPE off, passive assets + patched overlayfs | 1-layer cold | 60 | 3.788 s | 0.416 s | 3.861 s | 4.161 s | 4.300 s | 5.128 s |
| IPE off, passive assets + patched overlayfs | 1-layer cached | 60 | 1.263 s | 0.281 s | 1.230 s | 1.344 s | 1.359 s | 3.022 s |
| IPE off, passive assets + patched overlayfs | 8-layer cold | 60 | 4.714 s | 0.566 s | 4.606 s | 5.278 s | 5.526 s | 7.187 s |
| IPE off, passive assets + patched overlayfs | 8-layer cached | 60 | 1.246 s | 0.080 s | 1.248 s | 1.332 s | 1.340 s | 1.352 s |
| IPE audit, Patch17 EROFS | 1-layer cold | 30 | 3.892 s | 0.361 s | 3.916 s | 4.283 s | 4.312 s | 4.330 s |
| IPE audit, Patch17 EROFS | 1-layer cached | 30 | 1.236 s | 0.052 s | 1.239 s | 1.300 s | 1.313 s | 1.349 s |
| IPE audit, Patch17 EROFS | 8-layer cold | 30 | 5.574 s | 0.359 s | 5.535 s | 5.946 s | 6.247 s | 6.602 s |
| IPE audit, Patch17 EROFS | 8-layer cached | 30 | 2.262 s | 0.038 s | 2.268 s | 2.303 s | 2.309 s | 2.339 s |

### Signed 8-layer pull and startup

The summary graph and table use the equal-weight average of valid run medians
for direct pulls, which is less sensitive to large pull outliers. The three
IPE-off pod values are equal-weight means of two run means; Patch17 EROFS uses
the mean from run `1194985`.

| Configuration | Cold pull | Cached pull | Cold pod | Cached pod |
|---|---:|---:|---:|---:|
| Base image, base overlayfs | 2.568 s (**baseline**) | 0.346 s (**baseline**) | 4.458 s (**baseline**) | 1.286 s (**baseline**) |
| IPE off, passive assets | 2.528 s (**-1.5%**) | 0.338 s (**-2.2%**) | 4.473 s (**+0.3%**) | 1.310 s (**+1.9%**) |
| IPE off, passive assets + patched overlayfs | 2.730 s (**+6.3%**) | 0.702 s (**+102.9%**) | 4.704 s (**+5.5%**) | 1.262 s (**-1.9%**) |
| IPE audit, Patch17 EROFS | 6.984 s (**+172.0%**) | 4.372 s (**+1,163.7%**) | 9.761 s (**+119.0%**) | 2.332 s (**+81.3%**) |

Signed Kubernetes startup distributions:

| Configuration | Condition | n | Mean | SD | p50 | p90 | p95 | Max |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Base image, base overlayfs | Cold | 60 | 4.458 s | 0.347 s | 4.475 s | 4.849 s | 4.982 s | 5.552 s |
| Base image, base overlayfs | Cached | 60 | 1.286 s | 0.109 s | 1.286 s | 1.350 s | 1.375 s | 1.919 s |
| IPE off, passive assets | Cold | 60 | 4.473 s | 0.327 s | 4.512 s | 4.918 s | 4.965 s | 5.106 s |
| IPE off, passive assets | Cached | 60 | 1.310 s | 0.125 s | 1.298 s | 1.351 s | 1.378 s | 1.969 s |
| IPE off, passive assets + patched overlayfs | Cold | 60 | 4.704 s | 0.458 s | 4.660 s | 5.285 s | 5.533 s | 6.295 s |
| IPE off, passive assets + patched overlayfs | Cached | 60 | 1.262 s | 0.112 s | 1.261 s | 1.330 s | 1.376 s | 1.943 s |
| IPE audit, Patch17 EROFS | Cold | 30 | 9.761 s | 0.534 s | 9.645 s | 10.539 s | 10.913 s | 11.117 s |
| IPE audit, Patch17 EROFS | Cached | 30 | 2.332 s | 0.206 s | 2.292 s | 2.332 s | 2.814 s | 3.281 s |

Direct node-side pull variability:

| Configuration | Condition | n | Mean | SD | Run-median average | Max |
|---|---|---:|---:|---:|---:|---:|
| Base image, base overlayfs | Cold | 20 | 2.567 s | 0.103 s | 2.568 s | 2.767 s |
| Base image, base overlayfs | Cached | 20 | 0.344 s | 0.017 s | 0.346 s | 0.374 s |
| IPE off, passive assets | Cold | 20 | 2.626 s | 0.418 s | 2.528 s | 4.324 s |
| IPE off, passive assets | Cached | 20 | 0.368 s | 0.122 s | 0.338 s | 0.878 s |
| IPE off, passive assets + patched overlayfs | Cold | 20 | 3.237 s | 2.056 s | 2.730 s | 11.903 s |
| IPE off, passive assets + patched overlayfs | Cached | 20 | 0.818 s | 0.431 s | 0.702 s | 2.603 s |
| IPE audit, Patch17 EROFS | Cold | 10 | 7.066 s | 0.327 s | 6.984 s | 7.537 s |
| IPE audit, Patch17 EROFS | Cached | 10 | 4.366 s | 0.102 s | 4.372 s | 4.572 s |

The pull means for passive assets and especially patched overlayfs are above
their median estimators because a few slow pulls inflate the mean. Pull
p90/p95 cannot be calculated from the retained aggregate-only lifecycle
output.

## 3. Current Patch17 EROFS provenance and validity

The forward EROFS baseline is:

- ACL build [1194633](https://dev.azure.com/mariner-org/ACL/_build/results?buildId=1194633),
  source branch `dadelan/dmverity-tar-index-mirror-cache-fix`, commit
  `7c98294482301121caa83fc8c179b6afa447ec63`;
- MAP build [1194696](https://dev.azure.com/mariner-org/mariner/_build/results?buildId=1194696),
  output `3.0_20260901_1194696`, MAP branch
  `dadelan/acl-bootstrap-official-ab` at
  `9715c31db3c8e90aa8763feb9cae7987e8dce202`, and AgentBaker branch
  `dadelan/aks-pr-precache-auto-referrers`;
- performance run [1194985](https://dev.azure.com/mariner-org/mariner/_build/results?buildId=1194985),
  performance branch `dadelan/acl-perf-suite` at `560b5c92`, Kubernetes
  `1.35.6`, `westus3`, `aclGenPurposeHost`, registry profile `tar-index`,
  and `ipeMode=permissive`.

The ACL source differs from the superseded EROFS source only by containerd
Patch17, its RPM spec wiring, and patch documentation. Patch17 refreshes the
CRI image record's snapshotter set after the same image is unpacked into
another snapshotter, preventing repeated cached pause-image pull handling
during later pod-sandbox creation.

Treatment evidence proves one active IPE policy with enforcement disabled,
the EROFS CRI snapshotter, `enable_tar_index=true`, `enable_dmverity=true`,
and an eight-layer signed image producing eight attributable signed layers
and eight dm-verity devices. All lifecycle, startup, paired pull/start,
host-local exec, and state metrics from the run are accepted.

`AclIpeBenchmark` is the only excluded scenario. Its audit-integrity probe
detected journal or audit record loss after the benchmark, so no
microbenchmark timing was published. This does not invalidate the other
scenario artifacts or the 51 expected permissive DENY records retained by
`AclExecOverhead`.

## 4. Official containerd + active IPE isolate

ACL build [1194357](https://dev.azure.com/mariner-org/ACL/_build/results?buildId=1194357)
completed successfully and supplies the image input needed for the missing
IPE-only comparison. Its expanded build configuration confirms:

- ACL pipeline branch `dadelan/ipe-runtime-containerd-build` at
  `754d1edb6c8d41535cd4a4764d04d701b3e555af`;
- ACL source branch `dadelan/ipe-stock-containerd-overlayfs`, whose decoupling
  change is
  `bc33cdb63e2e5905c649bc221ae577c9019cb120`;
- `ACL_IPE_ASSET_MODE=ephemeral`;
- `ACL_EROFS_ENABLE=0`;
- `RPM_SOURCE=default`;
- `ACL_IPE_VERITY_SIGNATURE=false`.

MAP build [1194631](https://dev.azure.com/mariner-org/mariner/_build/results?buildId=1194631)
completed successfully from `dadelan/acl-bootstrap-official-ab` at
`9715c31db3c8e90aa8763feb9cae7987e8dce202`. It used ACL build `1194357`,
AgentBaker branch `dadelan/aks-pr-precache-auto-referrers`,
`rpmBuddyBuildId=0`, and `rpmAndVHDBuildId=0`. Its output is
`3.0_20260901_1194631`.

This is a ready MAP image input, not a performance result. It makes IPE assets
available while retaining official containerd and overlayfs, but leaves IPE
inactive by default. It is therefore not added to either graph or to the
measured configuration tables yet.

The remaining sequence is:

1. Run the performance pipeline against MAP `1194631` with `ipeMode=off`.
2. Run it again against the same MAP with `ipeMode=permissive`.
3. Accept the comparison only if both runs prove official containerd and
   overlayfs, the permissive run alone proves one active IPE policy with
   `ipe.enforce=0`, and both show zero EROFS mounts, zero container dm-verity
   devices, and zero signed-layer/device rises.

That first same-MAP pair isolates active IPE from EROFS and containerd
changes. Repeat each setting once more before promoting it into the replicated
executive graph at the same evidence level as the existing two-run arms.
