# containerd2 patch series

Reference for the 18-patch series in the active spec. Engineering rationale,
history, and triage notes live here so the `.spec` stays terse.

## Layout

| # in spec | Origin | Purpose |
|-----------|--------|---------|
| Patch0-7  | AzureLinux 3.0-dev baseline | 8 carry-patches verbatim from microsoft/azurelinux@origin/3.0-dev:SPECS/containerd2 at commit 5a4864f9 (containerd2-2.2.4-2). |
| Patch8    | dm-verity baseline | Upstream `add-signature-support` (aadagarwal). Split off by author so it can be dropped once it merges into azurelinux, leaving Patch9-17 unchanged. |
| Patch9    | ACL integration | Derives referrer discovery and snapshotter-side formatting from the erofs differ's capability, and adds the ACL entry points. Leaves Patch8's defaults untouched. |
| Patch10   | precomputed artifacts | Consumes signed precomputed EROFS/Merkle bundles and selects the newest. |
| Patch11   | EROFS SELinux sharing | Makes every consumer of an EROFS layer request one synthesised `context=`, so a layer can be mounted by more than one container. Independent of dm-verity; touches only upstream code. |
| Patch12   | selected-applier binding | Binds dm-verity referrer discovery to the applier selected for the active pull path and fails closed when that applier cannot consume the artifacts. Also recognises built-in dm-verity and makes the shared layer SELinux context configurable. |
| Patch13   | dm-verity mount lock  | Widens the dm-verity mutex from "guard the create" to "guard the mount lifecycle", closing a window in which a mapper could be removed between another container's verify and its `mount(2)`. |
| Patch14   | test compatibility | Updates the existing dm-verity snapshot test for Patch12's mount-handler constructor argument so the RPM `%check` phase compiles. No runtime behavior changes. |
| Patch15   | deferred signed unpack | Retains the selected signed EROFS referrer graph for fetch-only and non-capable unpack paths, including overlayfs, and reconstructs it during first-use EROFS unpack with fail-closed applier enforcement. |
| Patch16   | signed tar-index replacement | Replaces full precomputed EROFS blobs with compact signed tar indexes and Merkle trees, then reconstructs and verifies the EROFS data device from the OCI tar stream. |
| Patch17   | multi-snapshotter cache refresh | Refreshes the CRI image cache after a same-image unpack so its snapshotter set follows authoritative content labels and cached sandbox images are not pulled again. |

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
          ├─ 2b81b1336  erofs: share layer mounts across containers under SELinux
          ├─ 6e9236725  erofs: bind dm-verity enforcement to the selected applier
          ├─ 88f2a85a6  erofs: hold the dm-verity lock across the mount
          ├─ a1d272319  test(erofs): pass default shared layer context
          ├─ e670c411f  feat: retain dm-verity artifacts for deferred unpack
          ├─ 636e3078a  transfer: retain dm-verity refs across overlay unpack
          ├─ b90e6ec66  test(transfer): cover overlay referrer retention
          └─ 3f2b140ed  transfer: advertise dm-verity referrer retention
              └─ 20fcf6669  erofs: consume signed dm-verity tar indexes
                  └─ 38aa4465f  cri: refresh cached snapshotters after unpack
```

Patch0-15 live on `dadelan/acl-erofs`. Patch16 is the exact child commit
`20fcf6669` on the isolated `dadelan/erofs-tar-index-prototype` branch. The
earlier SHAs are informational; their **trailers** are what the grouped export
commands below resolve, so a rebase does not invalidate the procedure. Patch16
is intentionally pinned by exact SHA while it remains an isolated replacement
prototype. Patch17 is its exact child commit `38aa4465f` on
`dadelan/erofs-latency-cache-fix`.

The platform tag does matter, and it has gone stale once: until 2026-08-04
`acl/platform-v2.2.4` still pointed at `2a27bae8a` from before a branch
regeneration, which was no longer an ancestor of the branch, so the documented
procedure would have exported the wrong Patch8-10. If you rewrite the branch,
**move the tag**, then re-run the export and confirm the committed patch files
come back unchanged.

Grouped ACL commits carry an `Acl-Patch-Group:` trailer naming the patch file
they belong to. Patch12 is pinned by exact SHA. Patch15 begins with the original
ungrouped deferred-unpack commit and ends at the last
`acl-dmverity-deferred-unpack` commit, so its source range includes all four
reviewable commits while the spec keeps one cohesive patch.

| Group trailer | Commits | Patch file |
|---|---|---|
| `acl-dmverity-integration` | `9e59efb49`, `02191af08` | Patch9 |
| `acl-dmverity-precomputed` | `492478354`, `d04b266f5` | Patch10 |
| `acl-erofs-selinux` | `2b81b1336` | Patch11 |
| *(ungrouped exact commit)* | `6e9236725` | Patch12 |
| `acl-dmverity-mount-lock` | `88f2a85a6` | Patch13 |
| `acl-dmverity-test-fix` | `a1d272319` | Patch14 |
| `acl-dmverity-deferred-unpack` (plus predecessor) | `e670c411f`, `636e3078a`, `b90e6ec66`, `3f2b140ed` | Patch15 |
| *(isolated exact commit)* | `20fcf6669` | Patch16 |
| `acl-multi-snapshotter-cache-fix` | `38aa4465f` | Patch17 |

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
dropped and Patch9-17 apply unchanged** on top of the upstream base. Feature
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
consumer, and the two containerd paths that reach the handler disagree about
what to ask for:

- **container creation** activates the layer with no `context=` at all;
- **task creation** goes through `client.getRootFS`, which appends the consuming
  container's mount label, carrying a per-container MCS category pair.

So the first mount fixes the superblock and any later one that disagrees is
rejected:

```
SELinux: mount invalid.  Same superblock, different security settings for (dev dm-31, type erofs)
```

containerd surfaces this as a bare `EINVAL` from the mount handler.

This is fatal on a Kubernetes node rather than merely inconvenient, because
**every pod sandbox shares the pause image** and **CoreDNS ships two replicas of
one image by default** — so it reproduces on a stock cluster. It failed all nine
`kubeadm.v1.{32.4,33.0,34.1}.{calico,cilium,flannel}.base` kola cases in builds
1175150 and 1175414, through five reruns each. Single-container tests passed,
which fits — the defect needs two live consumers of one layer before it can fire,
and that is also why `cl.verity` and critest stayed green throughout.

The fix makes every consumer request **one synthesised label** rather than
rewriting whatever the caller supplied. **Isolation is unaffected**, for the
same reason overlayfs is unaffected: the per-container overlay stacked above the
layer still carries the full MCS pair, and that overlay is what the container
actually sees. Overlayfs lowerdirs already sit on disk as
`container_ro_file_t:s0` with no categories — confirmed on an ACL node with
`matchpathcon` — so the EROFS layer was the outlier, and this brings it to
parity rather than loosening anything.

### Why rewriting the caller's label was not enough

6016.verity stripped the MCS categories from `context=`. That is sufficient when
every consumer supplies a label, so it fixed the pause-image case: rejections on
build 1175414 fell from 274 to 7. It cannot fix the general case, because an
**unlabelled** mount and a **labelled** one disagree no matter how the label is
rewritten. The 1175414 journals show exactly that residue — 24 unlabelled
activations from container creation against 4 labelled ones from task creation,
all on the one device carrying the CoreDNS layer, mounting and being rejected in
alternation.

Synthesising the value is therefore not a stylistic choice; it is the only way
both paths converge. Details that matter if you touch `sharedLayerMountOptions`:

- `context=` is **dropped and re-added**, never edited in place. Editing only
  normalises labels that exist, which is the bug above.
- It is re-added **only when SELinux is enabled** — `mount(2)` rejects
  `context=` outright otherwise, so synthesising it unconditionally would break
  every EROFS mount on a permissive-disabled node.
- The value is quoted. The kernel needs quoting for labels containing commas,
  and quoting unconditionally keeps the emitted option byte-identical between
  the two paths, which is what the superblock comparison actually requires.
- `loop` and `X-containerd.dmverity=` are consumed earlier in `Mount` and must
  still be filtered out here.

`plugin_linux_test.go` covers each of the above and asserts the property the fix
depends on: the labelled path, the unlabelled path, and a second pod with a
different MCS pair all produce identical option slices.

Verified on an enforcing ACL node by starting two sandboxes from one image from
a known-clean state, with the running binary's version asserted per arm: stock
2.2.4 started 1 of 2 with one superblock rejection, while the overlays above kept
their distinct MCS pairs. **Not yet reproven through kola** — that needs a build
carrying 6017.verity, and kola is the gate that matters, since 6016.verity passed
node-level validation and still lost every kubeadm case.

## Patch12 — bind dm-verity to the selected applier

Referrer discovery previously asked whether **any loaded** diff plugin advertised
dm-verity support. Layer application asks a different question: which differ is
actually selected for the pull path. The transfer service reads its differ from
`unpack_config`, while CRI local pull reads the ordered applier chain from the
diff service. Its default begins with the walking differ, so a local pull could
fetch dm-verity artifacts, discard them, and still leave configuration looking
as though verification was active.

Local pull is not an exceptional path. Settings including
`disable_snapshot_annotations`, registry mirrors/configs, and
`max_concurrent_downloads` select it. Patch12 therefore reports the selected
applier chain and fails plugin initialisation when discovery is enabled but no
selected applier can consume the artifacts. It warns when a capable differ is
present but not first because an earlier differ can still win.

The same source commit closes two adjacent fail-open cases:

- `IsSupported` recognises `/sys/module/dm_verity`, which exists for both a
  loaded module and `CONFIG_DM_VERITY=y`; checking only `/proc/modules` silently
  disabled verification on built-in kernels.
- `shared_layer_context` makes the shared EROFS SELinux label configurable while
  retaining the already validated value as the default. The ACL profile needs
  no new key unless that default intentionally changes.

## Patch13 — hold the dm-verity lock through mount

Patch13 serialises lookup/create, verification, and `mount(2)` against mapper
removal. Without it, one consumer could observe and verify a mapper after a
concurrent unmount dropped the kernel open count to zero but before that
unmount removed the mapper. The resulting failure looked like an integrity
violation even though the verified device had simply disappeared before mount.

The lock remains outside `openOrReuseDmverityDevice` so its caller can hold it
until mount completes; putting the lock back inside would deadlock because Go
mutexes are not reentrant.

## Patch14 — preserve `%check` compatibility

Patch12 gives `NewErofsMountHandler` a shared-layer-context argument. The
existing dm-verity snapshot test constructs that handler directly and must pass
the empty value to select the production default. This is only a one-line test
compatibility change, but the RPM runs `make test` during `%check`, so omitting
it makes the package build fail before an image can be produced.

## Patch15 — retain signed artifacts for deferred unpack

AgentBaker preserves its existing cache policy: images below the compressed
size threshold are unpacked into the active bake-time snapshotter, while larger
images remain fetch-only until first use. An immediate capable EROFS unpack can
consume dm-verity artifacts transiently. Fetch-only and non-capable unpack
paths, including overlayfs, must instead preserve those artifacts because a
later EROFS unpack has no registry resolver with which to rediscover them.

Patch15 retains only the selected signed referrer manifest and its config,
signature, EROFS, and Merkle-tree children. Standard
`containerd.io/gc.ref.content.*` labels root the complete graph from the image
manifest, and the subject marker is published last only after every descriptor
has been fetched and verified at its declared size. Only an immediate unpack
through a capable EROFS snapshotter keeps the non-retaining wrapper, because
that path materializes the artifacts before the transfer completes. Overlayfs
unpack retains the graph so the same VHD can switch to EROFS at runtime without
another registry traversal.

Deferred CRI and generic `Image.Unpack` paths reconstruct layer annotations
locally from the retained graph. Generic unpack resolves a multi-platform image
once and reuses that exact manifest descriptor for reconstruction, avoiding a
second platform traversal that could select a different manifest.

Activation is capability-driven on both sides: the EROFS differ must advertise
artifact consumption and the active snapshotter must explicitly set
`dmverity_mode = "auto"` or `"on"`. ACL sets `"auto"` so unsigned layers remain
valid and IPE remains the enforcement authority. The generic diff service also
requires the capable EROFS differ to be first for an annotated EROFS mount;
ordinary overlay mounts continue to fall through to walking unchanged.

## Patch16 — replace full EROFS blobs with signed tar indexes

Patch16 replaces Patch10's full precomputed EROFS payload with a compact
replacement-only artifact containing one EROFS tar index, Merkle tree, and
PKCS#7 root-hash signature per source layer. The differ reconstructs the exact
data device as:

```
[512-byte-aligned EROFS tar index][decompressed OCI tar][zero padding to 4096]
```

The OCI tar alone remains the diffID input. The EROFS UUID binds the index to
the source-layer digest, and dm-verity covers the complete padded device with
SHA-256, 512-byte data and hash blocks, and the fixed 32-byte zero salt. The
512-byte block size is required because `mkfs.erofs --tar=i` emits a filesystem
with 512-byte logical blocks; a 4096-byte dm-verity mapping verifies but cannot
be mounted by EROFS.

Discovery treats every referrer using the replacement artifact type as
authoritative. Before selecting the newest bundle, containerd validates every
matching manifest, signature/root hash, artifact descriptor, and exact source
layer coverage. Any malformed matching bundle fails the pull rather than
downgrading to the older full-EROFS format.

## Patch17 — refresh the multi-snapshotter image cache

Patch0 tracks each image's unpacked snapshotters from
`containerd.io/gc.ref.snapshot.<snapshotter>` labels on its config blob. An
unpack into EROFS changes those labels but not the image ID, and the existing
same-ID, same-pin update path returned before refreshing the cached
`Snapshotters` set. CRI therefore treated the cached pause image as missing
from EROFS and repeated its registry pull for every pod sandbox.

Patch17 refreshes the existing image-store entry before that fast return. The
snapshotter set is replaced from the current labels rather than unioned, so
removed labels cannot leave stale-positive cache entries. Existing reference
aggregation and per-reference pin handling remain unchanged.

## Regeneration procedure

Patches are **exported from commits**, not diffed between hand-built trees:

```bash
cd <containerd-checkout>              # branch dadelan/acl-erofs
BASE=$(git rev-parse acl/base-v2.2.4-azl^{})
AADHAR=$(git rev-parse acl/platform-v2.2.4^{})
INT=$(git rev-list -1 dadelan/acl-erofs --grep='Acl-Patch-Group: acl-dmverity-integration')
PRE=$(git rev-list -1 dadelan/acl-erofs --grep='Acl-Patch-Group: acl-dmverity-precomputed')
SEL=$(git rev-list -1 dadelan/acl-erofs --grep='Acl-Patch-Group: acl-erofs-selinux')
APPLIER=$(git rev-parse 6e9236725198aabe6479e73a4fa0fb93d062d437)
LOCK=$(git rev-list -1 dadelan/acl-erofs --grep='Acl-Patch-Group: acl-dmverity-mount-lock')
TESTFIX=$(git rev-list -1 dadelan/acl-erofs --grep='Acl-Patch-Group: acl-dmverity-test-fix')
DEFERRED=$(git rev-list -1 dadelan/acl-erofs --grep='Acl-Patch-Group: acl-dmverity-deferred-unpack')
TARINDEX=$(git rev-parse 20fcf666959f20ff85029905febd23b59d9beb3f)
CACHEFIX=$(git rev-parse 38aa4465f55980b51aa787a8823adea874aed54b)

git diff $BASE   $AADHAR  # -> Patch8   (prepend the From:/Subject: header)
git diff $AADHAR $INT     # -> Patch9
git diff $INT    $PRE     # -> Patch10
git diff $PRE    $SEL     # -> Patch11
git diff $SEL    $APPLIER # -> Patch12
git diff $APPLIER $LOCK   # -> Patch13
git diff $LOCK   $TESTFIX # -> Patch14
git diff $TESTFIX $DEFERRED # -> Patch15 (prepend the documented squash header)
git format-patch -1 --stdout --no-signature $TARINDEX # -> Patch16
git format-patch -1 --stdout --no-signature $CACHEFIX # -> Patch17
```

Grouped boundaries are the **last** commit carrying their group trailer, so the
groups must stay contiguous and in patch order on the branch. Patch12,
Patch15's original `e670c411f` commit, Patch16's `20fcf6669` commit, and
Patch17's `38aa4465f` commit remain fixed points in the series; Patch15's
grouped boundary must descend from its original commit, Patch16 must remain an
immediate child of that boundary, and Patch17 must remain an immediate child
of Patch16.

Each exported file keeps a `From:`/`Subject:` header plus a body listing the
commits it squashes, so a reviewer can always get back to the individual
commits. `patch -p1` ignores the header, exactly as it does for a
`git format-patch` file.

### Verification gates

Run all five after regenerating. The first is the one that matters most: it is
what proves the patch files and the branch have not diverged.

1. **Tree equality.** Apply Patch0-17 to the pristine `Source0` tarball with
   `patch -p1 --fuzz=0 --no-backup-if-mismatch` (what `%autosetup -p1` does)
   and `diff -r` the result against a worktree at exact commit `38aa4465f`
   (`dadelan/erofs-latency-cache-fix`). Must be **identical**.
2. **Cross-compile.** `GOOS=linux`, `GOOS=windows`, and `GOOS=darwin`
   `go build ./...` must all pass. `plugins/snapshots/erofs/erofs.go` carries
   no build constraint, so Linux-only symbols referenced from it break the
   non-Linux builds — this has regressed before.
3. **gofmt.** `gofmt -l` must be silent. containerd CI enforces it.
4. **Feature tests.**
   `go test ./core/images/... ./core/transfer/local/... ./internal/cri/opts/... ./internal/cri/server/images/... ./internal/cri/store/image/... ./internal/dmverity/... ./internal/erofsutils/... ./pkg/snapshotters/... ./plugins/cri/images/... ./plugins/diff/erofs/... ./plugins/mount/erofs/... ./plugins/services/diff/... ./plugins/snapshots/erofs/...`
   Then run `go test -race ./internal/cri/store/image/...` for Patch17's
   same-ID metadata and pin-state path.
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
