# ACL Container Runtime Performance

**Updated:** 2026-09-01

## Perf Results

| Question | Result |
|---|---|
| Did adding passive IPE files while keeping IPE off degrade performance? | **No broad difference is visible.** Base, passive-assets, and patched-overlayfs builds remain closely grouped across startup, Kubernetes exec, and OS-disk reads. However, base and passive-assets are different complete image generations, so this is not a one-variable asset isolate. |
| Does the patched runtime regress performance while it still uses overlayfs? | **Not broadly.** Pod-start and exec results remain aligned. Its signed-image cached pull is about **0.36 seconds slower** than base. |
| Does the active IPE + patched EROFS profile degrade performance? | **Yes in the accepted pre-optimization runs, specifically in container pull and startup.** A candidate containerd cache fix substantially improved pod startup, especially when images were cached on the host, but did not improve direct image pulls. That candidate has one run and is not yet promoted into the accepted tables or graphs. |
| Did the containerd snapshotter-cache fix work? | **The first run strongly supports its intended effect.** Relative to the two accepted EROFS runs, mean pod startup improved by **10% to 60%** across all six image/cache conditions, and every new node mean was below every prior node mean. Direct cached pull was unchanged, which is expected because the fix targets repeated sandbox-image handling during pod creation rather than application-image pull time. A repeat run is still required. |
| Is the remaining slowdown isolated to IPE auditing? | **No.** The image changes IPE policy evaluation, EROFS, dm-verity, signature handling, and runtime patches together. ACL build [1194357](https://dev.azure.com/mariner-org/ACL/_build/results?buildId=1194357) and MAP build [1194631](https://dev.azure.com/mariner-org/mariner/_build/results?buildId=1194631) provide the missing official-containerd + overlayfs image input, but the same-MAP IPE-off/permissive performance pair has not run yet. |
| Did broad exec or read/write performance regress? | **No broad exec or read regression is demonstrated.** Kubernetes exec and OS-disk reads are closely grouped. The old harness discarded the active host-local scalar after observing expected audit-mode DENYs, and the unreplicated write results are too variable for feature attribution. |
| Do we have variability and tail data? | **Yes for Kubernetes startup.** The retained raw samples support sample standard deviation, p50, p90, p95, and maximum values. Direct pull and general-exec artifacts retained standard deviation and other aggregates, but not the raw vectors needed to calculate defensible p90/p95 values. |

## Configurations

| Display label | What it means |
|---|---|
| **Base image, base overlayfs** | Baseline ACL image and overlayfs runtime |
| **IPE off, passive assets** | Base containerd with overlayfs, passive IPE files are present but no policy is loaded |
| **IPE off, passive assets + patched overlayfs** | EROFS-capable patched containerd and passive IPE files are present, but overlayfs is selected and no IPE policy is loaded |
| **IPE audit, patched EROFS** | IPE is enabled in audit mode, the patched containerd configured with EROFS/dm-verity is present |

Every percentage below is relative to **Base image, base overlayfs** for the same metric.

## Statistical reporting

- **SD** is the sample standard deviation of the retained timing samples.
- **p90** and **p95** use the empirical nearest-rank percentile: 90% or 95%
  of observed timings were at or below that value.
- Kubernetes startup cells pool two equal-sized accepted runs: 30 samples per
  run, producing `n=60`. Because the runs have equal sample counts, the pooled
  mean gives each run equal weight.
- Those 60 values are repeated measurements nested inside only two independent
  pipeline runs and three nodes per run. They describe the observed timing
  distribution; they are not 60 independent cluster replications or a
  confidence interval for all future clusters.
- The lifecycle scenario published mean, median, minimum, maximum, SD, and
  sample count, but did not retain its ten individual pull samples. Therefore
  this document does not invent pull p90/p95 values.

## 1. General performance

![General execution and OS-disk performance](./acl-general-performance.svg)

The graph remains an executive mean comparison. The table below adds the
available spread. `kubectl exec` has one run with 20 operations per build.
Host-local results pool two runs with 50 batch means per run; every batch
contains 2,000 direct host executions.

| Configuration | `kubectl exec` mean (SD) | `kubectl exec` p50 / max | Host-local `/bin/true` mean (SD) |
|---|---:|---:|---:|
| Base image, base overlayfs | 241.7 ms (16.9 ms) (**baseline**) | 240.2 / 283.5 ms | 731.1 us (105.7 us) per exec (**baseline**) |
| IPE off, passive assets | 254.1 ms (17.3 ms) (**+5.1%**) | 250.9 / 280.8 ms | 733.0 us (128.5 us) per exec (**+0.3%**) |
| IPE off, passive assets + patched overlayfs | 246.9 ms (15.7 ms) (**+2.1%**) | 245.1 / 276.0 ms | 737.0 us (98.3 us) per exec (**+0.8%**) |
| IPE audit, patched EROFS | 233.1 ms (17.8 ms) (**-3.6%**) | 232.7 / 268.3 ms | **Test failed; no value published or plotted** |

The accepted artifacts did not retain the individual `kubectl exec` or
host-local batch vectors, so p90/p95 cannot be reconstructed for these rows.
The SD values above are the distributions published by the harness, or the
exact pooled SD derived from equal-sized run distributions.

| Configuration | Sequential read | Random read | Sequential write | Random write |
|---|---:|---:|---:|---:|
| Base image, base overlayfs | 19,166.7 IOPS (**baseline**) | 19,251.5 IOPS (**baseline**) | 3,433.9 IOPS (**baseline**) | 2,812.8 IOPS (**baseline**) |
| IPE off, passive assets | 19,388.5 IOPS (**+1.2%**) | 19,405.8 IOPS (**+0.8%**) | 2,655.2 IOPS (**-22.7%**) | 3,353.7 IOPS (**+19.2%**) |
| IPE off, passive assets + patched overlayfs | 19,336.8 IOPS (**+0.9%**) | 19,271.1 IOPS (**+0.1%**) | 3,064.9 IOPS (**-10.7%**) | 2,189.4 IOPS (**-22.2%**) |
| IPE audit, patched EROFS | 19,559.8 IOPS (**+2.1%**) | 19,562.2 IOPS (**+1.6%**) | 1,651.1 IOPS (**-51.9%**) | 2,306.6 IOPS (**-18.0%**) |

## 2. Container lifecycle

![Unsigned pod startup and signed-image lifecycle](./acl-container-lifecycle.svg)

The figure has two explicitly different panels:

| Measurement | Image and layer shape | Operation and timing boundary |
|---|---|---|
| **Unsigned Kubernetes startup** | Unsigned Alpine, 1 layer, about 3.6 MB; unsigned nginx-compatible image, 8 layers, about 21 MB | The timer starts immediately before `kubectl run`, not `kubectl apply`, and ends when tight polling observes Kubernetes pod phase `Running` on the pinned node. Cold proves the image absent and uses `imagePullPolicy=Always`; cached proves it is already cached on the host and uses `imagePullPolicy=Never`. |
| **Signed image pull** | One immutable signed nginx-compatible image, exactly 8 layers, about 21 MB | Direct node-side `crictl pull`, timed inside the node command after verifying that the image is absent or already cached on the host. Debug-pod setup is outside the timer. |
| **Signed Kubernetes startup** | The same signed 8-layer image | The same `kubectl run` to observed `Running` boundary as the unsigned panel. Cold includes pull and layer setup; cached uses the image already cached on the host with `imagePullPolicy=Never`. |

### Unsigned Kubernetes startup

Each run measures three nodes with ten iterations, so every displayed condition has
`runs=2, n=60`.

| Configuration | 1-layer cold | 1-layer cached | 8-layer cold | 8-layer cached |
|---|---:|---:|---:|---:|
| Base image, base overlayfs | 3.632 s (**baseline**) | 1.278 s (**baseline**) | 4.570 s (**baseline**) | 1.286 s (**baseline**) |
| IPE off, passive assets | 3.696 s (**+1.8%**) | 1.293 s (**+1.2%**) | 4.583 s (**+0.3%**) | 1.352 s (**+5.2%**) |
| IPE off, passive assets + patched overlayfs | 3.788 s (**+4.3%**) | 1.263 s (**-1.2%**) | 4.714 s (**+3.2%**) | 1.246 s (**-3.1%**) |
| IPE audit, patched EROFS | 5.111 s (**+40.7%**) | 3.057 s (**+139.2%**) | 6.847 s (**+49.8%**) | 3.254 s (**+153.1%**) |

Detailed pooled distributions:

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
| IPE audit, patched EROFS | 1-layer cold | 60 | 5.111 s | 0.810 s | 4.914 s | 5.475 s | 5.809 s | 10.321 s |
| IPE audit, patched EROFS | 1-layer cached | 60 | 3.057 s | 0.587 s | 3.131 s | 3.194 s | 3.219 s | 6.051 s |
| IPE audit, patched EROFS | 8-layer cold | 60 | 6.847 s | 0.468 s | 6.848 s | 7.050 s | 7.111 s | 9.754 s |
| IPE audit, patched EROFS | 8-layer cached | 60 | 3.254 s | 0.256 s | 3.192 s | 3.252 s | 4.081 s | 4.266 s |

### Signed 8-layer pull and startup

The summary graph and table use the equal-weight average of valid run medians
for direct pulls, which is less sensitive to the large pull outliers. Pod
values are equal-weight means of the two run means.

| Configuration | Cold pull | Cached pull | Cold pod | Cached pod |
|---|---:|---:|---:|---:|
| Base image, base overlayfs | 2.568 s (**baseline**) | 0.346 s (**baseline**) | 4.458 s (**baseline**) | 1.286 s (**baseline**) |
| IPE off, passive assets | 2.528 s (**-1.5%**) | 0.338 s (**-2.2%**) | 4.473 s (**+0.3%**) | 1.310 s (**+1.9%**) |
| IPE off, passive assets + patched overlayfs | 2.730 s (**+6.3%**) | 0.702 s (**+102.9%**) | 4.704 s (**+5.5%**) | 1.262 s (**-1.9%**) |
| IPE audit, patched EROFS | 6.596 s (**+156.9%**) | 4.332 s (**+1,151.8%**) | 10.897 s (**+144.4%**) | 3.320 s (**+158.2%**) |

Signed Kubernetes startup distributions:

| Configuration | Condition | n | Mean | SD | p50 | p90 | p95 | Max |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Base image, base overlayfs | Cold | 60 | 4.458 s | 0.347 s | 4.475 s | 4.849 s | 4.982 s | 5.552 s |
| Base image, base overlayfs | Cached | 60 | 1.286 s | 0.109 s | 1.286 s | 1.350 s | 1.375 s | 1.919 s |
| IPE off, passive assets | Cold | 60 | 4.473 s | 0.327 s | 4.512 s | 4.918 s | 4.965 s | 5.106 s |
| IPE off, passive assets | Cached | 60 | 1.310 s | 0.125 s | 1.298 s | 1.351 s | 1.378 s | 1.969 s |
| IPE off, passive assets + patched overlayfs | Cold | 60 | 4.704 s | 0.458 s | 4.660 s | 5.285 s | 5.533 s | 6.295 s |
| IPE off, passive assets + patched overlayfs | Cached | 60 | 1.262 s | 0.112 s | 1.261 s | 1.330 s | 1.376 s | 1.943 s |
| IPE audit, patched EROFS | Cold | 60 | 10.897 s | 0.571 s | 10.913 s | 11.602 s | 11.689 s | 13.235 s |
| IPE audit, patched EROFS | Cached | 60 | 3.320 s | 0.418 s | 3.212 s | 3.262 s | 4.201 s | 5.687 s |

Direct node-side pull variability:

| Configuration | Condition | n | Mean | SD | Run-median average | Max |
|---|---|---:|---:|---:|---:|---:|
| Base image, base overlayfs | Cold | 20 | 2.567 s | 0.103 s | 2.568 s | 2.767 s |
| Base image, base overlayfs | Cached | 20 | 0.344 s | 0.017 s | 0.346 s | 0.374 s |
| IPE off, passive assets | Cold | 20 | 2.626 s | 0.418 s | 2.528 s | 4.324 s |
| IPE off, passive assets | Cached | 20 | 0.368 s | 0.122 s | 0.338 s | 0.878 s |
| IPE off, passive assets + patched overlayfs | Cold | 20 | 3.237 s | 2.056 s | 2.730 s | 11.903 s |
| IPE off, passive assets + patched overlayfs | Cached | 20 | 0.818 s | 0.431 s | 0.702 s | 2.603 s |
| IPE audit, patched EROFS | Cold | 10 | 6.630 s | 0.196 s | 6.596 s | 6.946 s |
| IPE audit, patched EROFS | Cached | 10 | 4.353 s | 0.101 s | 4.332 s | 4.529 s |

The pull means for passive assets and especially patched overlayfs are above
their median estimators because a few slow pulls inflate the mean. Pull
p90/p95 cannot be calculated from the retained aggregate-only lifecycle
output.

## 3. Candidate Patch17 EROFS cache optimization

This section is intentionally separate from the accepted tables and graphs.
It reports one candidate run and does not replace the two-run EROFS baseline
until the result is replicated.

The build chain was:

- ACL build [1194633](https://dev.azure.com/mariner-org/ACL/_build/results?buildId=1194633),
  source commit `7c98294482301121caa83fc8c179b6afa447ec63`;
- MAP build [1194696](https://dev.azure.com/mariner-org/mariner/_build/results?buildId=1194696),
  output `3.0_20260901_1194696`;
- performance run [1194985](https://dev.azure.com/mariner-org/mariner/_build/results?buildId=1194985),
  using `ipeMode=permissive`.

The new ACL source is exactly one commit after the accepted EROFS source
`8f45080489f3fa7562e9b8ea248d40145f6c821b`. That commit adds containerd
Patch17, which refreshes the CRI image record's snapshotter set after the same
image is unpacked into another snapshotter. Without the refresh, CRI could
re-enter pull handling for the cached pause image when creating later pod
sandboxes. The source diff contains only the patch, its spec wiring, and patch
documentation.

Treatment evidence from the candidate run proves one active IPE policy with
enforcement disabled, the EROFS CRI snapshotter, tar-index and dm-verity
enabled, and an eight-layer signed image producing eight attributable signed
layers and eight dm-verity devices. Runtime configuration matches the prior
EROFS runs. The complete image generation changed from
`3.0.20260826` to `3.0.20260831`, so a second independently provisioned run is
still required even though the ACL source change is isolated.

The startup comparison uses the two accepted EROFS runs as the prior
distribution (`runs=2, n=60`) and the candidate as `runs=1, n=30`:

| Condition | Prior mean / p95 | Patch17 mean / p95 | Mean change |
|---|---:|---:|---:|
| Unsigned 1-layer cold | 5.111 / 5.809 s | 3.892 / 4.312 s | **-23.9%** |
| Unsigned 1-layer cached | 3.057 / 3.219 s | 1.236 / 1.313 s | **-59.6%** |
| Unsigned 8-layer cold | 6.847 / 7.111 s | 5.574 / 6.247 s | **-18.6%** |
| Unsigned 8-layer cached | 3.254 / 4.081 s | 2.262 / 2.309 s | **-30.5%** |
| Signed 8-layer cold | 10.897 / 11.689 s | 9.761 / 10.913 s | **-10.4%** |
| Signed 8-layer cached | 3.320 / 4.201 s | 2.332 / 2.814 s | **-29.8%** |

All three candidate node means were lower than all six prior node means for
every condition. The two accepted runs varied by at most 6.3% between their
condition means, while the candidate improvements range from 10.4% to 59.6%.
That separation makes ordinary prior run-to-run drift an unlikely explanation
for the full result, but it does not replace replication.

The direct pull and paired cold-start results identify what changed:

| Measurement | Prior EROFS run `1192978` | Patch17 run `1194985` | Change |
|---|---:|---:|---:|
| Signed cold pull mean | 6.630 s | 7.066 s | **+6.6% slower** |
| Signed cached pull mean | 4.353 s | 4.366 s | **+0.3%, unchanged** |
| Paired unsigned cold start mean | 7.040 s | 5.741 s | **-18.5%** |
| Paired signed cold start mean | 10.905 s | 9.595 s | **-12.0%** |
| Paired signed-minus-unsigned delta | 3.864 s | 3.854 s | **-0.3%, unchanged** |

This is the expected signature of a common pod-sandbox optimization: pod
creation improves for unsigned and signed images, while direct application
image pulls and the incremental signed-path delta do not. It should not be
described as a general cached-pull or dm-verity latency improvement.

Seven scenarios produced usable evidence. `AclExecOverhead` measured
622.9 us per host execution and retained 51 expected permissive-IPE denial
records; those records are part of the measured audit-mode cost and do not
invalidate the result. `AclIpeBenchmark` produced no publishable timing
because its integrity probe detected audit/journal record loss or suppression
after the benchmark. The current harness did not retain the exact matching
journal line, so this failure cannot yet be classified as IPE audit overflow
or unrelated kernel-message loss. The microbenchmark must be rerun after that
diagnostic evidence is preserved.

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
