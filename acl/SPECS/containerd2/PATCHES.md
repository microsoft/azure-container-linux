# containerd2 patch series

Reference for the 12-patch series in the active spec. Engineering rationale,
history, and triage notes live here so the `.spec` stays terse.

## Layout

| # in spec | Origin | Purpose |
|-----------|--------|---------|
| Patch0-7  | AzureLinux 3.0-dev baseline | 8 carry-patches verbatim from microsoft/azurelinux@origin/3.0-dev:SPECS/containerd2 at commit 5a4864f9 (containerd2-2.2.4-2). |
| Patch8    | dm-verity baseline | Upstream `add-signature-support` (aadagarwal). Split off by author so it can be dropped once it merges into azurelinux, leaving Patch9-10 unchanged. |
| Patch9    | ACL integration | Derives referrer discovery and snapshotter-side formatting from the erofs differ's capability, and adds the ACL entry points. Leaves Patch8's defaults untouched. |
| Patch10   | precomputed artifacts | Consumes signed precomputed EROFS/Merkle bundles and selects the newest. |
| Patch11   | EROFS SELinux sharing | Strips the MCS categories from the shared layer's `context=` so one EROFS layer can be mounted by more than one container. Independent of dm-verity; touches only upstream code. |

## Source of truth

**These patch files are generated output. Do not hand-edit them.**

The series is maintained as ordinary git commits on branch `dadelan/acl-erofs`
in a containerd checkout, rooted at the exact upstream tag the spec builds:

```
v2.2.4  193637f7ee8ae5f5aa5248f49e7baa3e6164966e   ( == %define commit_hash )
  └─ 8 commits   AZL Patch0-7, replayed with git am (upstream authorship kept)
      tag acl/base-v2.2.4-azl    843e2a8d0b96cd50a5886ba0da7f1cac232a4394
      └─ 1 commit   Aadhar Agarwal's add-signature-support  -> Patch8
          tag acl/platform-v2.2.4  a15edb104acd75913f84e71aedc79e24ca1dcd24
          ├─ 9e59efb49  erofs: derive dm-verity referrer discovery from the differ
          ├─ 02191af08  erofs: support dm-verity referrers on OCI-layout imports
          ├─ 492478354  erofs: consume signed precomputed EROFS and dm-verity artifacts
          ├─ d04b266f5  erofs: select the newest precomputed bundle and fail closed
          └─ f347a5052  erofs: share layer mounts across containers under SELinux
```

The SHAs above are informational; the **trailers** are what the export commands
below actually resolve, so a rebase does not invalidate the procedure. The tag
does matter, and it has gone stale once: until 2026-08-04 `acl/platform-v2.2.4`
still pointed at `2a27bae8a` from before a branch regeneration, which was no
longer an ancestor of the branch, so the documented procedure would have
exported the wrong Patch8-10. If you rewrite the branch, **move the tag**, then
re-run the export and confirm the committed patch files come back unchanged.

Each ACL commit carries an `Acl-Patch-Group:` trailer naming the patch file it
belongs to. Four commits collapse into two patch files: the commits exist for
review and bisect, the patch files exist so the spec stays maintainable.

| Group trailer | Commits | Patch file |
|---|---|---|
| `acl-dmverity-integration` | `9e59efb49`, `02191af08` | Patch9 |
| `acl-dmverity-precomputed` | `492478354`, `d04b266f5` | Patch10 |
| `acl-erofs-selinux` | `f347a5052` | Patch11 |

containerd does **not** inspect IPE policy. Layer signatures are passed to the
kernel whenever they are present and the feature is enabled; the kernel alone
interprets IPE. Earlier revisions of this series read
`/sys/kernel/security/ipe/policies/*/policy` and substring-matched
`dmverity_signature` to decide, caching the answer in a `sync.Once` for process
lifetime. That is removed (source review findings 3.7 and 3.8): it made a
policy comment able to change containerd's behavior, never observed a policy
activated after startup, and put LSM interpretation in the wrong component.

## Patch0-7 — AzureLinux 3.0-dev baseline

Copied verbatim from `microsoft/azurelinux@origin/3.0-dev:SPECS/containerd2`.
Re-sync periodically by re-downloading from that path.

| # | File | Purpose |
|---|------|---------|
| 0 | `multi-snapshotters-support.patch` | Multi-snapshotter routing (image pull + unpack tracks which snapshotters have unpacked each image). |
| 1 | `tardev-support.patch` | tardev-snapshotter handler registration. |
| 2 | `CVE-2026-39882.patch` | CVE backport. |
| 3 | `CVE-2026-33814.patch` | CVE backport. |
| 4 | `fix-TestCgroupNamespace-cgroupv1.patch` | Unit-test fix for cgroup v1 hosts. |
| 5 | `CVE-2026-39821.patch` | CVE backport (1.7 MB — includes vendor dep bumps). |
| 6 | `CVE-2026-42506.patch` | CVE backport. |
| 7 | `CVE-2026-27136.patch` | CVE backport. |

## Patch8 — upstream dm-verity signature support

Split **by author** along the clean commit boundary
`55df3ca38` on `dallasd1/containerd@dadelan/snapshotter-dmverity-format`
(`origin` = `aadhar-agarwal/containerd`). Everything up to and including
`55df3ca38` is Aadhar Agarwal's upstream `add-signature-support` work.

The split is deliberately along the author boundary (not by feature) so that
when `add-signature-support` lands in azurelinux upstream, **Patch8 is simply
dropped and Patch9-10 apply unchanged** on top of the upstream base. Feature
grouping is applied *within* the ACL patches, where it does not fight this.

Patch8 covers: dm-verity layer formatting, OCI referrer signing, per-layer
signature verification, the `require_signatures` policy, and vendored
`go-dmverity`.

### Corrections folded into Patch8

Two defects in the current `add-signature-support` branch are pre-applied in
Patch8 so they represent the *corrected* upstream state. They are expected to be
fixed at the source (in Aadhar's branch) before it merges to azurelinux; folding
them into Patch8 now keeps Patch9 free of them so it will not churn:

1. **Referrer strings** (`pkg/snapshotters/signatures.go`): the branch used
   placeholder constants (`containerd.io/snapshot/cri.layer-*`,
   `image.layer.*`, `application/vnd.oci.mt.pkcs7`). Patch8 uses the canonical
   values that match the signer output: `containerd.io/dmverity/layer-*`,
   `io.cncf.notary.dmverity.layer-*`, and
   `application/vnd.cncf.notary.dmverity.v1`.
2. **Superblock UUID** (`plugins/diff/erofs/dmverity_linux.go`): the branch
   generated a **random** dm-verity superblock UUID (`uuid.New()`) on every
   format, making the formatted blob non-reproducible. Patch8 leaves the UUID
   unset so the superblock (and its digest) is deterministic.

   **Open defect:** this correction only holds in the Patch8-only tree. Patch9
   moves `formatDmverityLayer`'s body into
   `internal/dmverity.FormatLayerBlob`, which starts from
   `DefaultDmverityOptions()` (no UUID) and then does
   `if opts.UUID == "" { opts.UUID = uuid.New().String() }`. So the shipping
   tree still writes a random dm-verity superblock UUID on every local format.
   The root hash is unaffected — it covers the data blocks, and the salt is a
   fixed zero string — so signatures still verify and this is not a
   correctness bug. It does mean two nodes formatting the same layer produce
   byte-different blobs, and it is inconsistent with the *EROFS* filesystem
   UUID, which `differ.go` derives deterministically with
   `uuid.NewSHA1(uuid.NameSpaceURL, "erofs:blobs/"+digest)` and
   `precomputed.go` verifies. Fix by deriving the dm-verity UUID from the
   layer digest the same way, or by threading the differ's UUID through
   `FormatLayerBlob`.
3. **`IsSupported()` cannot report "unsupported"** (`internal/dmverity/dmverity_linux.go:33`):
   it returns `(false, error)` both when `/proc/modules` is unreadable and when
   `dm_verity` is absent from it, and never `(false, nil)`. The erofs differ
   plugin branches on those two cases separately, intending to skip cleanly via
   `plugin.ErrSkipPlugin` when dm-verity is merely unavailable — but that branch
   is unreachable, so the plugin hard-fails instead. Observed with
   `enable_dmverity = true` on a host without the module: the differ fails, and
   `io.containerd.service.v1.diff-service` and `io.containerd.grpc.v1.diff` fail
   with it. A kernel with `CONFIG_DM_VERITY=y` rather than a module hits the
   same path, since a built-in does not appear in `/proc/modules`. ACL nodes are
   unaffected because `modules-load.d` loads it, but this is fragile.
   **Report upstream to Aadhar's branch.**

### IPE introspection removed from Patch8

Until this regeneration Patch8 also carried ACL's IPE policy introspection —
`ipeRequiresDmveritySignatures`, `ipePolicyRequiresDmveritySignatures`, their
`!linux` stub, their test, and the `switch` in `differ.go` that consulted them.
None of that is Aadhar's; it is ACL code that leaked across the author boundary
because the old generation method built Patch8 by *reverting the ACL changes out
of a combined tree*, and the revert simply missed it. So Patch8's "contains no
ACL changes" claim was never actually true.

Exporting Patch8 from a commit rooted directly on Aadhar's work makes that
boundary structural rather than aspirational: Patch8 is now exactly
`git diff acl/base-v2.2.4-azl acl/platform-v2.2.4`, and nothing can drift into
it without appearing as a commit. The IPE code is gone from the series entirely
— see the note above on containerd not inspecting IPE policy.

## Patch9-10 — ACL series

| # | File | Contents |
|---|------|----------|
| 9 | `0005-dm-verity-acl-integration.patch` | A `dmverity-referrers` plugin capability the erofs differ advertises when `enable_dmverity` is set, read by the transfer service and the CRI image service, so referrer discovery is never configured separately. Plus OCI-layout import wiring (`contentstore_fetcher`), signature writing on the differ's `Apply` path whenever a layer carries one, and the move of the format body into `internal/dmverity.FormatLayerBlob` (with rollback and a `!linux` stub). Touches nothing under `plugins/snapshots/erofs`. Patch8's defaults are left untouched. |
| 10 | `0006-dm-verity-precomputed-erofs-artifacts.patch` | UUID-bound precomputed EROFS/Merkle bundle verification and materialization, and newest-bundle selection with fail-closed behavior. |

The gate lands **first**, before any ACL behavior. Patch8 wires the referrer
handler into every pull, so on its own it costs every existing EROFS user a
referrers round trip on upgrade. Patch9 makes that conditional on the erofs
differ actually consuming the result, which means every later hunk is reviewable
as gated and off-by-default rather than as a change to default behavior.

Patch9 deliberately changes **no** default that Patch8 sets. Everything it gates
is gated on `enable_dmverity`, which is already false by default. This keeps
Patch9 free of context conflicts with Patch8 when Patch8 is dropped in favour of
an upstream release, and avoids a silent revert: a default flip carried in
Patch8's own file would disappear the moment Patch8 is deleted.

Neither ACL patch touches `plugins/snapshots/erofs`. Formatting the `layer.erofs`
that the snapshotter's `commitBlock` path builds from an overlay upperdir was
considered and dropped. It buys nothing — `commitBlock` has no signature to
write, so the result is unsigned dm-verity, which is integrity without
authenticity and is not enforceable — and nothing breaks without it, because
`dmverity_mode` defaults to `auto`, under which a layer with no sidecar mounts
as plain EROFS.

It is also not implementable. Deciding whether to format requires knowing
whether a differ handles dm-verity, and a snapshotter cannot learn that at init:
the metadata plugin already requires `SnapshotPlugin`, so any `Requires` edge
from the erofs snapshotter to `DiffPlugin` closes the cycle

    SnapshotPlugin -> DiffPlugin -> MetadataPlugin -> SnapshotPlugin

which `Registry.Graph` does not detect — it marks a registration as added only
*after* recursing into its requirements — so containerd dies at startup with a
stack overflow. Drop the edge and the erofs differ initializes after the erofs
snapshotter (index 16 versus 9 in the resolved graph), so the capability is
never visible and the check silently reads false. Gate 5 exists to catch exactly
this.

## Patch11 — EROFS layer sharing under SELinux

Independent of everything above. It fixes upstream code
(`plugins/mount/erofs/plugin_linux.go`), predates none of the dm-verity work,
and can be dropped on its own the moment an equivalent lands upstream.

`context=` is a **superblock-wide** SELinux mount option, and an EROFS layer is
a single block device, so every container that uses a given image shares one
superblock for that layer. The mount manager creates a new activation per
container and `client.getRootFS` appends the consuming container's mount label
to every mount it gets back from the snapshotter — and that label carries a
per-container MCS category pair. So the first container's label fixes the
superblock and the next one is rejected:

```
SELinux: mount invalid.  Same superblock, different security settings for (dev dm-1, type erofs)
```

containerd surfaces this as a bare `EINVAL` from the mount handler.

This is fatal on a Kubernetes node rather than merely inconvenient, because
**every pod sandbox shares the pause image**: only the first pod on a node can
start. It is what failed all nine
`kubeadm.v1.{32.4,33.0,34.1}.{calico,cilium,flannel}.base` kola cases in build
1175150, through five reruns each. The captured journals show 274 superblock
rejections against a single device carrying the pause layer, with 274 distinct
MCS pairs requested against it. Single-container tests passed, which fits — the
defect needs two consumers of one layer before it can fire.

The fix strips the MCS categories from the shared layer's label so every
consumer requests an identical superblock. **Isolation is unaffected**, for the
same reason overlayfs is unaffected: the per-container overlay stacked above the
layer still carries the full MCS pair, and that overlay is what the container
actually sees. Overlayfs lowerdirs already sit on disk as
`container_ro_file_t:s0` with no categories — confirmed on an ACL node with
`matchpathcon` — so the EROFS layer was the outlier, and this brings it to
parity rather than loosening anything.

Details that matter if you touch `stripMCSCategories`:

- A label is `user:role:type:level` and only `level` may contain further colons,
  so `SplitN(label, ":", 4)` is what isolates it.
- Categories are whatever follows the first colon on each side of a `-` range,
  so `s0-s0:c1,c2` and `s0:c1,c2` both reduce to `s0`.
- A degenerate range `s0-s0` collapses to `s0` so it matches what a
  non-range mount asks for. Without that, two consumers can still disagree.
- Quoting is preserved. The kernel quotes labels containing commas; a useful
  tell when reading `/proc/mounts` is that stripped labels appear **unquoted**
  and unstripped ones **quoted**.

`plugin_linux_test.go` covers all of the above, plus the convergence property
the fix actually depends on — that any two labels differing only in categories
strip to the same string — and idempotency.

Verified on an enforcing ACL node by starting two sandboxes from one image from
a known-clean state, with the running binary's version asserted per arm: stock
2.2.4 started 1 of 2 with one superblock rejection, the patched build started
2 of 2 with none and mounted the shared layer twice concurrently, while the
overlays above kept their distinct MCS pairs. **Not yet reproven through kola**
— that needs a build carrying this patch.

## Regeneration procedure

Patches are **exported from commits**, not diffed between hand-built trees:

```bash
cd <containerd-checkout>              # branch dadelan/acl-erofs
BASE=$(git rev-parse acl/base-v2.2.4-azl^{})
AADHAR=$(git rev-parse acl/platform-v2.2.4^{})
INT=$(git rev-list -1 dadelan/acl-erofs --grep='Acl-Patch-Group: acl-dmverity-integration')
PRE=$(git rev-list -1 dadelan/acl-erofs --grep='Acl-Patch-Group: acl-dmverity-precomputed')
SEL=$(git rev-list -1 dadelan/acl-erofs --grep='Acl-Patch-Group: acl-erofs-selinux')

git diff $BASE   $AADHAR  # -> Patch8   (prepend the From:/Subject: header)
git diff $AADHAR $INT     # -> Patch9
git diff $INT    $PRE     # -> Patch10
git diff $PRE    $SEL     # -> Patch11
```

Each boundary is the **last** commit carrying a given group trailer, so the
groups must stay contiguous and in patch order on the branch.

Each exported file keeps a `From:`/`Subject:` header plus a body listing the
commits it squashes, so a reviewer can always get back to the individual
commits. `patch -p1` ignores the header, exactly as it does for a
`git format-patch` file.

### Verification gates

Run all five after regenerating. The first is the one that matters most: it is
what proves the patch files and the branch have not diverged.

1. **Tree equality.** Apply Patch0-11 to the pristine `Source0` tarball with
   `patch -p1 --fuzz=0` (what `%autosetup -p1` does) and `diff -r` the result
   against a worktree at `dadelan/acl-erofs`. Must be **identical**.
2. **Cross-compile.** `GOOS=linux`, `GOOS=windows`, and `GOOS=darwin`
   `go build ./...` must all pass. `plugins/snapshots/erofs/erofs.go` carries
   no build constraint, so Linux-only symbols referenced from it break the
   non-Linux builds — this has regressed before.
3. **gofmt.** `gofmt -l` must be silent. containerd CI enforces it.
4. **Feature tests.**
   `go test ./internal/dmverity/... ./plugins/diff/erofs/... ./plugins/mount/erofs/... ./plugins/snapshots/erofs/... ./pkg/snapshotters/... ./core/transfer/local/...`
5. **Plugin graph.** `go build -o /tmp/ctrd ./cmd/containerd && /tmp/ctrd config dump`
   must exit 0. `registry.Graph` has no cycle detection, so a bad `Requires` edge
   is a startup stack overflow that compiles, passes `gofmt`, passes every unit
   test, and passes gate 1 — the tree is identical, the bug is semantic. This
   gate is the only one that executes the plugin graph. Stronger still, and
   worth doing before any RPM: run the daemon against the real profile with
   `containerd -c acl-erofs.toml` and check `ctr plugins ls`.

Gates 2-5 should also pass at **every intermediate commit**, not just at the
tip. The previous tree-partition method could not check this, and did not: it
produced a Patch8 that failed to compile, and a Patch9 that broke the
non-Linux builds, and neither was visible because only the final tree was
ever built.

### Why this replaced tree-diffing

The previous procedure built `T_base`, `T_full`, and a hand-reverted `T_aada`,
then defined `Patch8 = diff(T_base, T_aada)` and `Patch9 = diff(T_aada, T_full)`.
Its stated invariant only ever required `T_full` to compile. That meant no
commit ancestry at the v2.2.4 base, no bisect, no way to apply a review fix as
an ordinary commit, and defects in intermediate trees were structurally
invisible. Both bugs listed in the gates above were found by rebuilding this as
commits.

## Port notes (2.2.0 → 2.2.4)

The dm-verity work was authored against ~v2.2.0; porting to v2.2.4 + the AZL
8-patch stack required hand-fixing 5 context-only rejects (all now baked into
Patch8):

1. `docs/snapshotters/erofs.md` — trailing `## TODO` section grew new
   entries in v2.2.4; removed only the `DMVerity support.` bullet.
2. `go.mod` — context shift from 18 unrelated dep bumps in v2.2.4; added
   `github.com/containerd/go-dmverity` entry in the new location.
3. `go.sum` — same as go.mod, with new checksum entries.
4. `plugins/snapshots/erofs/erofs.go` — 6 hunks rejected due to upstream
   commit `9da97686d` ("Use default writable size in erofs snapshotter for
   non-Linux hosts"), which restructured `SnapshotterConfig`/`snapshotter`
   structs. Added `dmverity` import, `dmverityMode` config/struct fields,
   and the `applyDmverityPolicy` + `createErofsMount` helpers. Renamed
   v2.2.4's `mounts(snap, _ snapshots.Info)` to `mounts(ctx, snap, info)`
   to accept the context our policy hooks need.
5. `plugins/snapshots/erofs/plugin/plugin.go` — context shift from a
   neighbouring field's relocation. Added `DmverityMode` toml field and
   the `WithDmverityMode` Opt wiring.

Boltdb label-cap fix (rename `containerd.io/snapshot/dmverity.*` keys to
`containerd.io/dmverity/*`) is preserved inside Patch8 — verified by
`grep "containerd.io/dmverity/" 0004-*.patch` returning the expected hits.

## Drift to monitor

- AzureLinux 3.0-dev tracks `Release: 2` of containerd2-2.2.4. When AZL
  publishes new CVE backports or carry-patches, re-download the 8 baseline
  patches from `microsoft/azurelinux@origin/3.0-dev:SPECS/containerd2`, replay
  them onto the branch with `git am`, and bump the steamboat spec Release
  accordingly. Because Patch0-7 are commits at the base of the branch, a new
  AZL patch is inserted as a commit and the ACL commits rebase over it — the
  ACL patch files are then re-exported, not re-derived by hand.

- If upstream containerd (or azurelinux) merges the `add-signature-support`
  work, **drop Patch8 entirely** and rebase the ACL commits onto the new base —
  the author-boundary split is designed to make this a clean removal rather
  than a hunk-by-hunk edit.

- Upstream containerd has since published v2.2.5, v2.2.6, and v2.3.0-v2.3.3.
  The branch is pinned at v2.2.4 to match the spec. Rebasing is a decision to
  take with the AzureLinux base, not independently.
