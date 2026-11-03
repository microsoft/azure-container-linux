# ARM64 tdnf timestamp-snapshot lookup benchmark

Measurement date: **2026-10-30**.

On the tested Azure Linux 3.0 ARM64 host, a warm `tdnf provides sed` lookup
took **0.071 seconds without snapshot filtering** and **13.427 seconds with
timestamp-based snapshot filtering**. That is approximately **190x more time
per lookup**, not a 190x slowdown of an entire RPM build.

The timed queries used already-downloaded metadata. Their output was identical,
and excluding the repository from snapshot filtering restored the fast path.

## Environment and method

| Item | Tested configuration |
|---|---|
| Host | Native ARM64 Azure VM, `Standard_D4ps_v5` |
| OS | Azure Linux `3.0.20260923` |
| Package manager | `tdnf-3.5.8-8.azl3.aarch64` and matching `tdnf-cli-libs` |
| Solver library | `libsolv-0.7.28-5.azl3.aarch64` |
| Repository | `https://packages.microsoft.com/azurelinux/3.0/prod/base/aarch64` |
| Query | `provides sed` |
| Snapshot cutoff | `1793282824` = `2026-10-29T14:07:04Z` |
| Samples | Six timed invocations per mode, 18 total |

An isolated tdnf configuration enabled only this repository, named `ab-base`,
with a separate metadata cache. `makecache` populated the cache before timing.
Each mode was warmed once, then measurements alternated between
`off, on, excluded_control` and `excluded_control, on, off`.

Every timed command used `--cacheonly`. Wall time was measured with Python
`time.perf_counter()` around a captured subprocess invocation; child user and
system CPU time came from `resource.getrusage(resource.RUSAGE_CHILDREN)`.

All 18 commands returned exit code 0 and byte-identical stdout. The SHA-256
digests of `repomd.xml` and compressed primary metadata were unchanged before
and after the experiment.

**Diagnostic configuration only:** `gpgcheck=0` and `repo_gpgcheck=0` were used
in the isolated query-only benchmark. No RPMs were installed. This does not
measure signature-verification overhead and is not a recommendation to disable
signature checks in production builds.

## Results

All times are seconds. CPU time is user plus system time.

| Mode | Snapshot options | Median wall | Wall range | Median CPU |
|---|---|---:|---:|---:|
| Off | None | 0.070730 | 0.070155 - 0.071263 | 0.070450 |
| On | `--snapshottime=1793282824` | 13.426932 | 13.349221 - 13.846840 | 13.426054 |
| Excluded control | Same timestamp plus `--snapshotexcluderepos=ab-base` | 0.071547 | 0.071364 - 0.072123 | 0.071256 |

The on/off wall-time ratio was **189.83x**. Snapshot CPU time was nearly equal
to wall time, consistent with local metadata processing rather than network
waiting. Keeping the timestamp option but excluding this repository gave
approximately the same timing as the no-snapshot case.

Recorded wall-time samples:

| Iteration | Off | On | Excluded control |
|---|---:|---:|---:|
| 1 | 0.070738 | 13.846840 | 0.071916 |
| 2 | 0.071263 | 13.349221 | 0.071364 |
| 3 | 0.071005 | 13.388886 | 0.071648 |
| 4 | 0.070680 | 13.476893 | 0.071430 |
| 5 | 0.070155 | 13.464315 | 0.071447 |
| 6 | 0.070722 | 13.389550 | 0.072123 |

The query returned repository entries for `sed-4.9-1.azl3.aarch64` and
`sed-4.9-2.azl3.aarch64`, plus the installed `sed-4.9-2.azl3.aarch64` entry,
in every mode.

## Relevant implementation

The Azure Linux tdnf snapshot patch at toolkit revision
`a526a629b8ff3db2ec8a9633803506bd61118bca` has two relevant behaviors:

- The snapshot-enabled path calls `TDNFInitRepoFromMetadata` instead of taking
  the normal `SolvUseMetaDataCache` path:
  [cache selection](https://github.com/microsoft/azurelinux/blob/a526a629b8ff3db2ec8a9633803506bd61118bca/SPECS/tdnf/virtual-repo-snapshot.patch#L108-L140).
- It filters primary metadata for the cutoff and removes the filtered
  temporary file after loading:
  [filtering and cleanup](https://github.com/microsoft/azurelinux/blob/a526a629b8ff3db2ec8a9633803506bd61118bca/SPECS/tdnf/virtual-repo-snapshot.patch#L1221-L1244).

Thus, having the original XML metadata cached on disk does not mean the parsed
solver metadata is reused in snapshot mode. Repeated package-manager commands
can repeatedly pay this preparation cost.

## Reproducing the comparison

Use an isolated Azure Linux 3.0 ARM64 test host with the package versions above.
Run as root, or with equivalent permissions for tdnf. These commands create only
a temporary diagnostic configuration/cache and perform queries, not installs.

```bash
work=$(mktemp -d /var/tmp/tdnf-snapshot-benchmark.XXXXXX)
mkdir -p "$work/repos" "$work/cache"

cat > "$work/repos/benchmark.repo" <<'EOF'
[ab-base]
name=Snapshot benchmark base repository
baseurl=https://packages.microsoft.com/azurelinux/3.0/prod/base/aarch64
enabled=1
gpgcheck=0
repo_gpgcheck=0
metadata_expire=never
EOF

cat > "$work/tdnf.conf" <<EOF
[main]
reposdir=$work/repos
cachedir=$work/cache
gpgcheck=0
keepcache=1
EOF

rpm -q tdnf tdnf-cli-libs libsolv
tdnf -c "$work/tdnf.conf" --releasever=3.0 makecache -y

# The three command variants used by the measurement harness:
tdnf -c "$work/tdnf.conf" --releasever=3.0 --cacheonly provides sed
tdnf -c "$work/tdnf.conf" --releasever=3.0 --cacheonly \
  --snapshottime=1793282824 provides sed
tdnf -c "$work/tdnf.conf" --releasever=3.0 --cacheonly \
  --snapshottime=1793282824 --snapshotexcluderepos=ab-base provides sed
```

Warm each variant once, then time six repetitions in the alternating orders
described above. Capture stdout/stderr, exit codes, wall time, and child CPU
time for every command. Compare output and metadata hashes before interpreting
the timings. Retain the diagnostic directory with the results, then remove it
when no longer needed.

Original metadata SHA-256 digests:

```text
repomd.xml:
e0e7cfdadc0a1410a5a496f8080556767dbd8f2d73e6ca855d768d53cf2c17ea

compressed primary XML:
b0250b3b80cb6a75d5811a6d8f7761a3ea6b8eb1b946e4df69ab54836383cd12
```

The historical metadata payloads are not included with this report. PMC
metadata changes over time, so a rerun against the live repository is a new
measurement; exact reproduction of these numbers is not guaranteed.

## Separate materialized-metadata experiment

A follow-up ACL-side prototype prepared a cutoff-filtered repository view once
and then used normal cached tdnf lookups. In that separate ARM64 experiment:

| Measurement | Result |
|---|---:|
| One-time preparation | 34.952 seconds |
| Original snapshot lookup, median of three | 13.447535 seconds |
| Materialized-view lookup, median of three | 0.085047 seconds |

Package-selection comparisons covered `sed`, `cargo`, a missing package, and
synthetic cutoff-boundary cases. Old and new paths downloaded the same `sed`
RPM with the same SHA-256. A representative native ARM64 Judy toolkit build
also succeeded, but it was not a controlled end-to-end speed comparison.

The prototype is recorded in
[commit 4ee8554333](https://github.com/microsoft/azure-container-linux/commit/4ee8554333531bc327f02a412d00f1acf7f7d1bb).
This report does not imply that the prototype is merged or deployed.

## Scope and limitations

- The controlled on/off result is for one query, repository, architecture, and
  tdnf/libsolv version combination. It is not a general benchmark of all RPM
  operations, DNF5, or newer package-manager versions.
- The cutoff did not change this query's result. Queries whose eligible
  packages differ can also change dependency resolution and the amount of work.
- Six samples on one VM establish the large observed effect, not a population
  confidence interval. The order alternated but was not fully randomized.
- No controlled snapshot-on/off comparison of an entire RPM build was run.
  Do not multiply a full build's duration by 190 or attribute all dependency
  fetching time to this one mechanism.
- Production optimization must preserve the cutoff semantics, metadata trust,
  package checksums/signatures, and repository isolation.
