# ACL Container Runtime Performance

**Updated:** 2026-09-15

## Configurations

| Display label | What it means |
|---|---|
| **Base ACL image** | Base ACL image without any modifications |
| **Overlayfs + IPE assets** | Patched containerd and overlayfs with IPE assets installed but no active IPE policy |
| **Prebuilt EROFS referrers** | Patched containerd using EROFS and dm-verity with permissive IPE auditing and complete prebuilt EROFS images supplied as referrers |
| **Tar-index EROFS referrers** | Patched containerd using EROFS and dm-verity with permissive IPE auditing and compact tar indexes supplied as referrers |

Percentages are relative to Base ACL image.

## 1. Container lifecycle

| Test | Why it matters |
|---|---|
| **Cold pod start** | Represents the first use of an image on a node. It includes image acquisition, snapshotter loading, container creation, and startup. The snapshotter cache is cleared between each iteration. |
| **Cached pod start** | Represents ordinary restarts and scale-out when the image is already present and `imagePullPolicy: IfNotPresent` can use it locally. |
| **Always-pull pod start** | Represents `imagePullPolicy: Always`, including clusters that apply the `AlwaysPullImages` admission policy. Kubelet checks the image with the container runtime before creating the container even when the image is cached. |
| **Cold image acquisition without pod start** | This is not a normal user operation. Removes the exact image and calls the container runtime image-acquisition API directly. No pod is created and kubelet is not involved. This diagnostic isolates the image-acquisition portion of cold startup. |

### Unsigned Kubernetes startup

![Unsigned container lifecycle](./acl-container-lifecycle-unsigned.svg)

Each cell is **mean / p90 / p95** in seconds. Base ACL image, Overlayfs + IPE
assets, and Tar-index EROFS referrers use `n=60`. Prebuilt EROFS referrers use
`n=30`.

| Configuration | 1-layer cold pod start | 1-layer cached pod start | 8-layer cold pod start | 8-layer cached pod start |
|---|---:|---:|---:|---:|
| Base ACL image | 3.641 / 4.087 / 4.202 | 1.384 / 2.026 / 2.037 | 4.545 / 4.941 / 5.011 | 1.390 / 1.989 / 2.040 |
| Overlayfs + IPE assets | 3.781 / 4.054 / 4.338 | 1.160 / 1.216 / 1.909 | 4.527 / 4.901 / 4.919 | 1.194 / 1.760 / 1.945 |
| Prebuilt EROFS referrers | 5.181 / 5.762 / 5.816 | 3.137 / 3.232 / 3.242 | 6.939 / 7.439 / 8.151 | 3.497 / 4.180 / 4.212 |
| Tar-index EROFS referrers | 3.773 / 4.193 / 4.305 | 1.180 / 1.850 / 1.915 | 4.705 / 5.293 / 5.547 | 1.209 / 1.525 / 1.995 |

Unsigned tar-index EROFS remained within 3.6% of the base image on cold
startup and did not show a cached-start regression.

### Signed Kubernetes startup

![Signed container lifecycle](./acl-container-lifecycle-signed.svg)

Each cell is **mean / p90 / p95** in seconds. Base ACL image, Overlayfs + IPE
assets, and Tar-index EROFS referrers use `n=60`. Prebuilt EROFS referrers use
`n=30` where shown.

| Configuration | 1-layer cold pod start | 1-layer cached pod start | 1-layer always-pull pod start | 8-layer cold pod start | 8-layer cached pod start | 8-layer always-pull pod start |
|---|---:|---:|---:|---:|---:|---:|
| Base ACL image | 3.605 / 4.143 / 4.177 | 1.492 / 1.992 / 2.058 | 1.994 / 2.107 / 2.114 | 4.572 / 4.930 / 5.087 | 1.409 / 1.952 / 1.971 | 2.056 / 2.117 / 2.736 |
| Overlayfs + IPE assets | 3.698 / 4.132 / 4.146 | 1.231 / 1.936 / 2.002 | 2.061 / 2.128 / 2.163 | 4.643 / 5.047 / 5.106 | 1.215 / 1.868 / 2.028 | 2.109 / 2.167 / 2.185 |
| Prebuilt EROFS referrers | N/A | N/A | N/A | 11.699 / 12.572 / 12.693 | 3.536 / 4.180 / 4.201 | N/A |
| Tar-index EROFS referrers | 4.339 / 4.702 / 4.921 | 1.522 / 1.583 / 1.640 | 3.563 / 3.696 / 4.265 | 9.917 / 10.890 / 11.121 | 1.377 / 1.527 / 1.554 | 7.399 / 8.236 / 8.342 |

Signed eight-layer cached startup remained near the baseline

## 2. Cached ten-pod scale-out

This test represents a Deployment or DaemonSet burst on a node where the image
is already cached. This is the time from Deployment creation until
all ten pods are Running and Ready. 

![Signed cached ten-pod scale-out](./acl-concurrent-scale-out-signed.svg)

Each row uses `n=24` signed ten-pod deployment bursts.

| Configuration | Median | p90 | p95 | Median change versus Base ACL image |
|---|---:|---:|---:|---:|
| Base ACL image | 2.633 s | 2.968 s | 3.096 s | **baseline** |
| Overlayfs + IPE assets | 2.558 s | 2.919 s | 2.989 s | **-2.8%** |
| Tar-index EROFS referrers | 2.762 s | 3.173 s | 3.347 s | **+4.9%** |

One tar-index EROFS cluster had a long first timed burst of 13.14s. Later bursts were
`2.357-3.214 s`, so the median remains the primary comparison.

## 3. Cached image after node reboot

This test represents dm-verity maintenance after node restart. It verifies that a cached
signed image remains usable without another image pull and the time it takes for the kernel
dm-verity mappings to be recreated when the first cached pod starts.

![Cached signed image startup after node reboot](./acl-cached-reboot.svg)

Each row uses `n=20` accepted cached pod starts after a real node reboot.

| Configuration | Mean | p90 | p95 | Mean change versus Base ACL image |
|---|---:|---:|---:|---:|
| Base ACL image | 1.346 s | 1.705 s | 1.719 s | **baseline** |
| Overlayfs + IPE assets | 1.418 s | 1.759 s | 1.897 s | **+5.4%** |
| Tar-index EROFS referrers | 1.591 s | 1.983 s | 2.001 s | **+18.2%** |

Every reboot cleared the eight active container mappings, and the first cached pod recreated all `8/8`.

## 4. General performance

These tests look for broad host or runtime regressions outside image
acquisition and pod startup. Each `kubectl exec` sample starts a fresh
`kubectl` process and runs `/bin/true` in an already-running pod. It includes
the client, API server, konnectivity, and runtime round trip without pod
scheduling. The host's `/bin/true` binary isolates local process overhead.
OS-disk I/O checks whether general node storage performance changed.

![General execution and OS-disk performance](./acl-general-performance.svg)

Each result is **mean / p90 / p95**. The `kubectl exec` totals are `n=40` for
Base ACL image, Overlayfs + IPE assets, and Tar-index EROFS referrers, and
`n=20` for Prebuilt EROFS referrers. Base, Overlayfs, and tar-index host-local
results each contain 100 groups of 2,000 executions, or 200,000 executions.
The prebuilt result contains 50 groups, or 100,000 executions. OS-disk reads
use three node-level jobs for Base, Overlayfs, and tar-index and one for
prebuilt. Writes use three for Base and Overlayfs, two for tar-index, and one
for prebuilt.

| Measurement | Base ACL image | Overlayfs + IPE assets | Overlayfs mean change versus base | Prebuilt EROFS referrers | Prebuilt mean change versus base | Tar-index EROFS referrers | Tar-index mean change versus base |
|---|---:|---:|---:|---:|---:|---:|---:|
| `kubectl exec` | 237.835 / 260.8 / 268.5 ms | 235.935 / 259.8 / 262.6 ms | **-0.80%** | 233.888 / 248.7 / 251.6 ms | **-1.66%** | 237.960 / 267.3 / 268.0 ms | **+0.05%** |
| Host `/bin/true` | 675.542 / N/A / N/A us | 687.416 / N/A / N/A us | **+1.76%** | 1,433.491 / N/A / N/A us | **+112.20%** | 600.784 / N/A / N/A us | **-11.07%** |
| Sequential OS-disk read | 19,455.698 / 19,572.404 / 19,572.404 IOPS | 19,569.740 / 19,572.417 / 19,572.417 IOPS | **+0.59%** | 19,314.945 / N/A / N/A IOPS | **-0.72%** | 19,368.207 / 19,394.449 / 19,394.449 IOPS | **-0.45%** |
| Random OS-disk read | 19,549.872 / 19,555.169 / 19,555.169 IOPS | 18,933.476 / 18,957.609 / 18,957.609 IOPS | **-3.15%** | 19,259.203 / N/A / N/A IOPS | **-1.49%** | 19,224.276 / 19,367.024 / 19,367.024 IOPS | **-1.67%** |
| Sequential OS-disk write | 3,548.985 / 3,555.267 / 3,555.267 IOPS | 2,510.520 / 3,553.911 / 3,553.911 IOPS | **-29.26%** | 2,628.773 / N/A / N/A IOPS | **-25.93%** | 3,539.640 / 3,540.012 / 3,540.012 IOPS | **-0.26%** |
| Random OS-disk write | 3,412.007 / 3,553.644 / 3,553.644 IOPS | 2,845.111 / 3,384.644 / 3,384.644 IOPS | **-16.61%** | 3,506.154 / N/A / N/A IOPS | **+2.76%** | 3,517.186 / 3,520.906 / 3,520.906 IOPS | **+3.08%** |
