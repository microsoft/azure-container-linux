# RPM dependency snapshots

When `PACKAGE_SNAPSHOT_TIME` is set, `acl/build.sh` prepares upstream repository
metadata once before building packages. This avoids tdnf 3.5.8 rebuilding its
snapshot-filtered metadata for every dependency lookup.

The helper reads repository definitions from the toolkit's worker archive,
verifies signed upstream repomd using the worker's configured GPG keys, verifies
metadata checksums, and keeps packages whose publication (`time file`)
timestamp is at or before the cutoff. Packages without that timestamp are
excluded. Malformed timestamps or metadata fail the build. Filelists and other
package metadata are restricted to the retained package checksum IDs; advisory
metadata is not exposed by this build-only view.

Prepared metadata is served on loopback only while `make build-packages` runs.
Eligible RPM URLs redirect to their original HTTPS locations. Package checksums
and repository package-signature settings are preserved. The derived local
repomd is not upstream-signed; its trust comes from verifying the original
repomd signature and its metadata checksum chain before transformation.
The toolkit's default
upstream repositories are disabled for dependency selection, so unavailable
snapshot packages cannot fall back to newer packages in the live repositories.
The toolkit still performs its normal initial metadata refresh.

The view and downloaded-RPM cache are keyed by cutoff, repository configuration,
original repomd/signature/key checksums, and materializer format version. Local build outputs
and pinned toolchain RPMs retain the toolkit's existing priority and snapshot
exceptions. The original cutoff remains the pipeline's provenance value.

The supported upstreams are the worker's Azure Linux 3.0 PMC repositories with
XML/gzip metadata. GPG verifies upstream metadata using only the keys configured
in the worker. Large expanded metadata is streamed through temporary files on
the build volume, not held in memory or placed on a small `/tmp` filesystem.
External `REPO_LIST`, `PACKAGE_CACHE_SUMMARY`, mirrorlists, and per-package
`xml:base` are rejected rather than silently bypassed. Package-signature
verification is not disabled.

Set `ACL_RPM_SNAPSHOT_MODE=tdnf` to explicitly select the previous per-lookup
snapshot implementation for diagnosis or rollback. The default is
`materialized`. A preparation failure never switches modes automatically.
Without `PACKAGE_SNAPSHOT_TIME`, the previous build path is unchanged.

Run the focused portable tests with:

```sh
python3 -m unittest discover -s acl/tests -p test_materialize_rpm_snapshot.py -v
```

Linux validation should compare package selection and downloaded checksums
against the original tdnf snapshot path, then exercise the toolkit chroot build.
On an isolated ARM64 Azure Linux 3.0 host with tdnf, the live comparison is:

```sh
sudo python3 acl/tests/validate_snapshot_tdnf.py --output /tmp/snapshot-comparison.json
```

It uses temporary repository/cache directories, tests synthetic cutoff boundaries,
compares live PMC queries and a downloaded RPM, and measures repeated warm
lookups. It does not install packages.
