# Performance results contract

Every performance benchmark under `acl/tests/` emits the same results document,
so a consumer can read all of them without knowing which suites exist. The
pipeline merges one document per benchmark into a single `perf-results.json`
artifact and **fails the merge** if a producer drifts from this contract.

## Producers

| script | suites | where it runs |
|---|---|---|
| `run-critest-benchmark.sh` | `PodSandbox`, `container`, `image_lifecycle` | in the VM |
| `run-fsexec-benchmark.sh` | `filesystem`, `exec` | in the VM |
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

## What the `filesystem` and `exec` suites measure

These are the general-perf counterpart to the container benchmark: no
containerd, no CNI, no registry. They exist because a `PullImage` number folds
network, unpack, hashing and mount into a single figure, so when it moves there
is no way to say which of them moved. Here each row is one syscall in a loop.

Rows are `read_cold`, `read_warm`, `read_random_cold` and `stat_cold`, each
suffixed `:image` or `:control`, plus a single `fork_exec` row. Each row also
carries `fstype`, `device`, `path`, `bytes` and `files`, because the matrix arms
deliberately differ in what backs `/usr` and a timing whose filesystem is
unknown cannot be compared with anything.

The two axes land in different places. **EROFS and dm-verity tax the read
path**: every block coming off the image is checked against the Merkle tree
before userspace sees it, and on a compressed image it is decompressed as well.
**IPE taxes the exec path**: every `execve` is evaluated against policy.

### The control corpus

A cold read of `/usr` on its own says only "this VM's disk was this fast today".
Azure disk throughput varies between runs by more than the effect being looked
for, so the same bytes — files of exactly the same sizes, in the same order —
are written to the writable filesystem and read back identically in the same
run. Both corpora sit on the same underlying disk, so the `image / control`
ratio the script prints cancels the disk and leaves the filesystem.

`read_warm` doubles as a check on that reasoning. Both warm rows are served from
the page cache, so they should land close to 1.00x regardless of filesystem; a
warm ratio far from 1 means something other than the filesystem is differing and
the cold ratio should not be trusted either.

The byte count is clipped to land exactly on the budget rather than taking whole
files. Otherwise one large binary overshoots by tens of megabytes, and since the
arms ship different binaries each would read a different total — leaving
throughput as the only comparable column. Clipping keeps `bytes` identical
everywhere, so the raw milliseconds compare too.

The metadata corpus is mirrored the same way, as empty files at the same
relative paths, so the control stat walk covers the same number of entries in
the same tree shape. Mirroring only the data files would leave the control
walking a couple of dozen entries against the image's thousands, and the
resulting ratio would report that count difference rather than anything about
the filesystem.

### Reading the output

The raw per-arm milliseconds are the product; the ratios are scaffolding. A
single run of a single arm has nothing to compare against, so the script prints
the rows meant to be diffed across the matrix — `read_cold`, `read_random_cold`,
`stat_cold`, `fork_exec` — together with what each one prices, and keeps the
control ratios in a separate section labelled as a disk-speed correction rather
than a result. The control answers "how does the image filesystem compare to
whatever the writable one happens to be", which is a different question from the
one the matrix asks.

`/usr` on ACL is a stacked mount — a sysext overlay over the dm-verity backing
store. The backing store is what the rows report, because that is the axis the
matrix varies, but the full stack is recorded in `mountStack` and called out in
a note: the upper layers sit in the image read path and not in the control's.

### Why there is no exec control

IPE's purpose is to refuse anything that is not verity-backed, so a binary
copied to the writable filesystem is *blocked* rather than slow on exactly the
arms where IPE is enabled — an in-run control would measure a denial, not a
cost. The exec comparison is therefore across arms (IPE on vs off), not within
a run. `fork_exec` includes the surrounding `fork` and `wait`, which are
constant overhead on every arm and cancel in that comparison.

### Cold measurements can be unavailable

Cold rows require dropping the page cache, which needs root or passwordless
sudo. Where that fails the cold rows are **omitted and a note is printed**,
rather than reported from a warm cache — a warm read presented as cold would
look like the filesystem had become dramatically faster. This follows the same
rule as the absent `Firmware` and `Loader` rows in the boot suite: a missing
measurement is stated, never substituted.



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
