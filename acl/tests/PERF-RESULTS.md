# Performance results contract

Every performance benchmark under `acl/tests/` emits the same results document,
so a consumer can read all of them without knowing which suites exist. The
pipeline merges one document per benchmark into a single `perf-results.json`
artifact and **fails the merge** if a producer drifts from this contract.

## Producers

| script | suites | where it runs |
|---|---|---|
| `run-critest-benchmark.sh` | `PodSandbox`, `container`, `image_lifecycle` | in the VM |
| `run-exec-benchmark.sh` | `exec` | in the VM |
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

Rows are phases (`Firmware`, `Loader`, `Kernel`, `Initrd`, `Userspace`, `Total`,
`RebootWallClock`) plus a `unit:<name>` row per interesting unit. Phase values
come from systemd's own timestamps via `systemctl show`, not from
`systemd-analyze time` prose, whose wording changes between releases.

systemd cannot *observe* most of a boot — `CLOCK_MONOTONIC` starts at kernel
start, so it reconstructs. The kernel's duration is the monotonic clock read the
instant PID 1 starts in the initrd; the initrd's is serialized across
`switch-root`. Firmware and boot loader run *before* the clock exists, so systemd
cannot time them at all — it reads `LoaderTimeInitUSec` / `LoaderTimeExecUSec`,
EFI variables written by the boot loader.

**On Azure Gen2 those variables are not published.** ACL boots systemd-boot 255
launching a UKI, and `bootctl` confirms the stub measures the image, but the
Hyper-V firmware gives systemd-boot no usable timestamp source, so it publishes
`Loader*` identity variables without the `LoaderTime*` timing ones.
`systemd-analyze time` on the same VM likewise prints no firmware/loader line.
This is a platform limitation, not a build option — so `Firmware` and `Loader`
rows are **omitted rather than reported as 0** (a zero would claim instantaneous
firmware; an absent row admits the measurement was unavailable), and `Total`
covers kernel onward. The script prints a coverage line stating which case
applied.

`RebootWallClock` exists so that blindness is bounded rather than silent. It is
measured host-side from issuing the reboot to the VM answering with a new
`boot_id`, so it covers everything: shutdown, platform firmware, systemd-boot,
the UKI stub, and the guest boot itself. `RebootWallClock - Total` is therefore
the unaccounted time, and the coverage line prints it. On a `Standard_D2s_v5` it
runs about 5.5 s against a ~9.2 s `Total`. It is an **upper bound**: it inherits
the reboot poll interval and the SSH reconnect, so treat it as a bracket, not a
precise firmware measurement.

### Is that good enough?

For the IPE and EROFS comparison, yes. The unaccounted segment is dominated by
Azure firmware and boot-loader time, which depends on the platform and VM size
rather than on image contents, so it is very close to a constant that cancels
when two variants are differenced. More importantly, **the work those axes
actually do is inside the measured window**: IPE loads its policy and
`systemd-veritysetup` activates the verity device during the initrd, and `Initrd`
is measured directly. The one part that can move with image content is the stub's
load and TPM measurement of the UKI — the UKI embeds the initramfs, so a larger
initramfs costs slightly more there — and that lands in the unaccounted segment.
`RebootWallClock` is what catches it: if a variant grows the initramfs enough to
matter, the wall clock moves while `Total` does not.

For an absolute "time until this node can run a pod", no. `Total` ends at
default-target, which is **not** node-ready — containerd, kubelet and CNI come
after, which is what the `unit:` rows are for — and neither number includes
hypervisor scheduling or VM provisioning, so this is *guest* boot, not
`az vm create` → ready.

The current boot is discarded rather than sampled: it is the provisioning boot,
carrying cloud-init and disk-growth work that never recurs. Measured on a
`Standard_D2s_v5`, that boot took 27.3 s against ~9.4 s for subsequent reboots,
so counting it would have biased every run by roughly 18 s of one-time work.

## What the `exec` suite measures

This is the general-perf counterpart to the container benchmark: no containerd,
no CNI, no registry. It exists because a `PullImage` number folds network,
unpack, hashing and mount into a single figure, so when it moves there is no way
to say which part moved.

The suite measures the exec path and nothing else, because that is the entire
surface IPE taxes. The kernel documentation is explicit: enforcement "is
triggered automatically by the kernel during `execve()`, `execveat()`, `mmap()`
and `mprotect()` syscalls when loading executable content."

Rows are `fork`, `spawn_verity`, `spawn_unverified` and `dynlib`.

### Why there are no read or stat rows

An earlier revision measured cold and warm reads of `/usr` and presented them as
an IPE and EROFS metric. They were neither, and the rows have been removed
rather than relabelled.

* **IPE has no hook on `read()` or `stat()`.** Toggling IPE cannot move a read
  number.
* **dm-verity hashes blocks at the device-mapper layer** whether IPE is loaded
  or not, so its cost is present on every arm equally.
* **EROFS in this matrix is a containerd *snapshotter* choice.** It applies to
  container layers under the snapshotter root, not to the host rootfs. `/usr` is
  byte-identical on all four arms, so those rows could only ever have reported
  disk noise — while being labelled as the numbers to compare across arms.

### The two exec paths

What ACL ships decides the shape of the measurement. `uki_install.sh` boots with
`ipe.enforce=0 ipe.success_audit=0`: permissive, and allowed execs are not
audited. Against the shipped policy:

```
DEFAULT                             action=ALLOW
DEFAULT op=EXECUTE                  action=DENY
op=EXECUTE boot_verified=TRUE       action=ALLOW
op=EXECUTE dmverity_signature=TRUE  action=ALLOW
```

that yields two different exec paths on one machine:

| row | binary | policy outcome | cost |
|---|---|---|---|
| `spawn_verity` | stress-ng on `/usr` | `dmverity_signature=TRUE` → ALLOW | rule evaluation only, nothing audited |
| `spawn_unverified` | a copy on a writable filesystem | no ALLOW rule matches → `DEFAULT` DENY, permissive so it still runs | rule evaluation **plus an audit record** |

`spawn_unverified - spawn_verity` is therefore the cost of an IPE audit event,
measured within a single run on a single VM. That in-run control is the point:
it cancels VM, disk and noisy-neighbour variation instead of relying on
comparing absolute numbers across arms that ran on different machines on
different days. `fork` is measured alongside as the floor, since every spawn
also pays for a process creation.

ACL ships no auditd, so those records go to printk and land in the kernel ring
buffer — the same place `run-selinux-avc-test.sh` looks for AVC denials. printk
is rate limited, so `auditRecords` is reported next to the timing and a
suppression notice marks the count as a floor.

### Why stress-ng, and why `spawn`

The measurement is stress-ng rather than a
hand-rolled exec loop. Its manual says it is "never intended to be used as a
precise benchmark test suite" but sanctions exactly this use: "useful to observe
performance changes across different operating system releases". So the suite
reports *relative* differences between two configurations on one machine and
makes no claim about absolute per-`execve` latency. The canonical tools for an
absolute figure are lmbench `lat_proc` and `perf bench syscall execve`; neither
is packaged for Azure Linux today.

The stressor choice is not cosmetic. There is no `--exec-path` in the packaged
0.17.06, so both `exec` and `spawn` re-execute `/proc/self/exe` — which is why
running a *copy* of stress-ng is what moves the exec off the verity device. But
`strace` shows the `exec` stressor also writes a temporary copy of itself into
the working directory and execs that, roughly one exec in five:

```
327 execve("/tmp/sng-copy/stress-ng"
 73 execve("./tmp-stress-ng-exec-<pid>-0/stress-ng-exec-...")
```

That temp copy necessarily lives on a writable filesystem, so it is unverified
even when the stressor binary is on `/usr`, and it would have mixed audited
execs into the supposedly clean baseline. `spawn` has no such behaviour: one
bogo op is exactly one `execve` of the binary's own resolved path.

`dynlib` exercises the `mmap` hook rather than the `execve` hook. IPE checks
both, and a binary linking many libraries pays the check once per library, so
this is the row that scales with how much a workload links. Its libraries come
off `/usr` either way, so it compares across arms rather than within a run.

### Reading the output

A spawn re-executes the whole stress-ng binary, so one op costs milliseconds
while an IPE check may cost microseconds. The delta is therefore compared
against the spread of the baseline's own repetitions, and when it does not clear
that spread the run prints **NOT RESOLVABLE** and says to treat the result as
"no measurable cost" rather than as the printed number. `auditCostResolvable`
and `baselineSpreadMs` carry the same judgement in the document.

That guard exists because the previous revision of this suite reported a `53.03x`
filesystem result that was purely an artifact of the two corpora walking
different numbers of files.

### Rows can be unavailable

The suite drops rows and prints a note rather than substituting a number it did
not measure — the same rule as the absent `Firmware` and `Loader` rows in the
boot suite. Rows are omitted when stress-ng is missing, when it has no usable
`spawn` stressor, or when the writable copy cannot be executed. Notes are also
emitted when IPE is absent, when it is enforcing (an unverified binary is then
refused rather than audited, so the row is not comparable), when success
auditing is on (the verity row is then not an audit-free baseline), and when
both binaries land on the same backing device, which would make the comparison
meaningless.

### stress-ng has to be in the image, not a sysext

The suite needs stress-ng on the dm-verity-backed `/usr`, which means building
the image with `ACL_PERF_TOOLS=1`. The pipeline sets it whenever `runPerfTests`
is on; it is off otherwise, since a benchmarking tool has no place on a
production node.

A sysext looks like it would do the job and does not. Sysexts are plain
squashfs images overlaid onto `/usr` with no verity beneath them, so a
stress-ng merged from `lisa-testing` resolves on `PATH` and runs, but satisfies
neither `boot_verified=TRUE` nor `dmverity_signature=TRUE`. Both arms of the
comparison would then be unverified, the delta would collapse to zero, and the
suite would report that IPE costs nothing — a broken measurement that reads
exactly like a clean result. Installing at runtime fails for the same reason
the property is worth having: `/usr` is read-only.

The suite therefore checks that its binary is genuinely on a dm-verity device
(`findmnt` for the backing store, then `dmsetup table` for the target type) and
drops the `spawn_*` rows with a note if it is not. The check is recorded as
`devices.verityBacked` in the document.


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
