%global debug_package %{nil}
%define upstream_name containerd

# Source: official upstream containerd v2.2.4 release tarball
# build-rpm.sh reads these globals and downloads:
#   https://github.com/<github_owner>/<github_repo>/archive/<branch_name>.tar.gz
# saving it as ${spec_name}-${Version}.tar.gz next to this spec.
# GitHub returns an immutable archive for a tag ref, giving us reproducible
# source between rebuilds.
%global github_owner containerd
%global github_repo  containerd
%global branch_name  v%{version}
# GitHub tag archives extract to: <repo>-<version>
%global extracted_dir %{github_repo}-%{version}

# REVISION metadata embedded in `containerd --version`. v2.2.4 commit pin from
# https://github.com/containerd/containerd/releases/tag/v2.2.4.
%define commit_hash 193637f7ee8ae5f5aa5248f49e7baa3e6164966e

Summary: Industry-standard container runtime
Name: %{upstream_name}2
# Tracks the AzureLinux 3.0-dev containerd2 baseline at Version 2.2.4.
Version: 2.2.4
# Release "6000.verity" distinguishes this dadelan fork build from any
# future official AzureLinux containerd2-2.2.4-N release (which start at
# Release: 1, 2, ...). The 6xxx range succeeds the prior 5xxx steamboat
# RPM stream and the 4xxx 2.2.0-patch-based / 3xxx fork-tarball builds.
# The ".verity" suffix marks the dm-verity erofs snapshotter patch set
# (Patch8-16 of PATCHES.md). No .commit_hash tag since the upstream is an
# immutable release tag.
# IMPORTANT: any future official AzureLinux containerd2-2.2.4-N release
# will be considered OLDER than this; bump Epoch or pin to a higher Version
# if you ever need to deprecate this stream.
Release: 6022.verity%{?dist}
License: ASL 2.0
Group: Tools/Container
URL: https://www.containerd.io
Vendor: Microsoft Corporation
Distribution: Azure Linux

# AzureLinux toolkit downloads from GitHub using github_owner/repo/branch_name
# above and stores it as ${upstream_name}-${Version}.tar.gz in the toolchain
# cache; the SHA in containerd2.signatures.json gates the download.
Source0: https://github.com/%{github_owner}/%{github_repo}/archive/%{branch_name}.tar.gz#/%{upstream_name}-%{version}.tar.gz
Source1: containerd.service
# Stock Azure Linux configuration remains active by default.
Source2: containerd.toml
# EROFS/dm-verity capability shared by both ACL runtime profiles.
Source3: containerd-acl-erofs.toml
# Overlayfs-capability composition root.
Source4: containerd-acl-config.toml
# systemd drop-in selecting the composition root; "90-" must sort after
# AgentBaker's "50-default-config.conf". Also pulls in modprobe@erofs and
# modprobe@dm_verity, which is the only ordering-correct way to load them on
# ACL (systemd-sysext merges /usr after systemd-modules-load has run).
Source5: containerd-acl-profile.conf
# Guarantees /etc/containerd/config.toml exists before containerd starts, so
# the composition root's literal import always resolves.
Source6: containerd-acl-tmpfiles.conf
# Runtime-only delta that switches CRI and the generic diff service to EROFS.
Source7: containerd-acl-erofs-runtime.toml
# Composition root selected after IPE activation or for static EROFS images.
Source8: containerd-acl-erofs-config.toml
# Atomically selects the overlayfs-capability or EROFS runtime root at startup.
Source9: containerd-acl-select-profile

# ============================================================================
# Patches
# ============================================================================
# Patch0-7: AzureLinux 3.0-dev containerd2 baseline patches, copied verbatim
#           from microsoft/azurelinux@origin/3.0-dev:SPECS/containerd2 at
#           commit 5a4864f9 (Release: 2). Includes:
#             - multi-snapshotters-support / tardev-support carry-patches
#             - 5 CVE backports (CVE-2026-{39882,33814,39821,42506,27136})
#             - fix-TestCgroupNamespace-cgroupv1 test fix
# Patch8:   Upstream dm-verity "add-signature-support" work (aadagarwal), i.e.
#           layer-signature formatting, referrer signing, and require_signatures
#           policy. Isolated so it can be dropped once it lands in azurelinux.
# Patch9:   ACL integration, gated off by default. Patch8 costs every EROFS user
#           a referrers round trip per pull; this restores stock upstream
#           behavior unless the erofs differ's enable_dmverity is configured.
#           Referrer discovery is derived from that one setting via a plugin
#           capability rather than configured separately, and Patch8's defaults
#           are left untouched. Also adds OCI-layout import wiring, differ-side
#           signature writing, and a shared FormatLayerBlob with rollback.
#           Touches nothing under plugins/snapshots/erofs.
# Patch10:  UUID-bound precomputed EROFS and dm-verity artifact consumption
#           with newest-bundle selection. containerd does not inspect IPE
#           policy; the kernel alone interprets it.
# Patch15:  Retain the selected signed EROFS referrer graph for fetch-only and
#           non-capable unpack paths, including overlayfs, then reconstruct it
#           during deferred first-use EROFS unpack. Capability and applier
#           checks fail closed before signed EROFS layers reach a walking differ.
# Patch16:  Replace full precomputed EROFS blobs with signed tar indexes and
#           Merkle trees. Reconstruct the exact EROFS data device from the
#           decompressed OCI tar stream and verify it before use.
#           See PATCHES.md for the author/commit provenance.
# ============================================================================

Patch0:  multi-snapshotters-support.patch
Patch1:  tardev-support.patch
Patch2:  CVE-2026-39882.patch
Patch3:  CVE-2026-33814.patch
Patch4:  fix-TestCgroupNamespace-cgroupv1.patch
Patch5:  CVE-2026-39821.patch
Patch6:  CVE-2026-42506.patch
Patch7:  CVE-2026-27136.patch
# dm-verity series — see PATCHES.md for provenance.
Patch8:  0004-dm-verity-add-signature-support-upstream.patch
Patch9:  0005-dm-verity-acl-integration.patch
Patch10: 0006-dm-verity-precomputed-erofs-artifacts.patch
# Independent of the dm-verity series; touches only upstream code.
Patch11: 0007-erofs-selinux-shared-layer-context.patch
# Bind referrer discovery to the selected applier so local pulls cannot silently
# discard dm-verity artifacts. Also recognises built-in dm-verity kernels and
# makes the shared EROFS SELinux context configurable.
Patch12: 0008-erofs-bind-dmverity-to-selected-applier.patch
# Concurrency fix for the dm-verity mount path. Kept separate from Patch8 so it
# can be dropped or folded independently; belongs in 0004 once that settles.
Patch13: 0009-erofs-dmverity-mount-lifecycle-lock.patch
# Build compatibility for Patch12's mount-handler constructor change. The RPM
# runs the existing containerd test suite in %check, so the stale zero-argument
# test call must use the constructor's empty-value default.
Patch14: 0010-erofs-test-pass-default-shared-layer-context.patch
# Preserve signed referrers for AgentBaker's fetch-only and overlayfs cache
# paths, then reconstruct them when the image is unpacked into EROFS.
Patch15: 0011-erofs-retain-referrers-for-deferred-unpack.patch
# Replacement-only signed EROFS tar-index wire format.
Patch16: 0012-erofs-use-signed-tar-index-referrers.patch

%{?systemd_requires}

BuildRequires: golang < 1.25
BuildRequires: go-md2man
BuildRequires: make
BuildRequires: systemd-rpm-macros

Requires: runc >= 1.2.2

# This package replaces the old name of containerd
Provides: containerd = %{version}-%{release}
Obsoletes: containerd < %{version}-%{release}

# This package replaces the old name of moby-containerd
Provides: moby-containerd = %{version}-%{release}
Obsoletes: moby-containerd < %{version}-%{release}

# This package replaces moby-containerd-cc
Provides: moby-containerd-cc = %{version}-%{release}
Obsoletes: moby-containerd-cc < %{version}-%{release}

%description
containerd is an industry-standard container runtime with an emphasis on
simplicity, robustness and portability. It is available as a daemon for Linux
and Windows, which can manage the complete container lifecycle of its host
system: image transfer and storage, container execution and supervision,
low-level storage and network attachments, etc.

containerd is designed to be embedded into a larger system, rather than being
used directly by developers or end-users.

%package erofs
Summary: EROFS/dm-verity profile for Azure Container Linux
Requires: %{name} = %{version}-%{release}
# Runtime dependency for the dm-verity erofs differ. This belongs here, not on
# the main package: stock Azure Linux containerd2 has no EROFS or dm-verity
# behavior and must not drag it onto every consumer.
#   erofs-utils  - provides mkfs.erofs, exec'd by internal/erofsutils to convert
#                  tar layers into erofs filesystems before verity hashing.
# It is in the azurelinux-official-base repo so dependency resolution works
# during VHD build and on customer-provisioned nodes.
#
# veritysetup is deliberately NOT required: hash-tree formatting and device
# activation go through the vendored go-dmverity library and dm ioctls. The
# CLI is never exec'd -- the only occurrence of the name in the containerd
# tree is a comment in internal/dmverity/dmverity.go.
Requires: erofs-utils

%description erofs
Provides EROFS and dm-verity image verification capability for containerd on
Azure Container Linux (ACL) images.

The main containerd2 package stays behavior-neutral: it ships the stock Azure
Linux configuration and the dm-verity code paths remain default-off. Installing
this subpackage loads the capability while preserving overlayfs by default. A
late systemd selector activates the EROFS CRI profile only after the ACL IPE
policy is active, or when the image carries an explicit static EROFS marker.

All files are installed under /usr. ACL is an immutable OS whose image bake
discards RPM-contributed paths under /etc, and only /usr survives into the
sysext.

This subpackage is inert on stock Azure Linux, whose containerd.service does
not pass --config and therefore ignores CONTAINERD_CONFIG.

%prep
%autosetup -p1 -n %{extracted_dir}

%build
export BUILDTAGS="-mod=vendor"
make VERSION="%{version}" REVISION="%{commit_hash}" binaries man

%check
export BUILDTAGS="-mod=vendor"
make VERSION="%{version}" REVISION="%{commit_hash}" test

%install
make VERSION="%{version}" REVISION="%{commit_hash}" DESTDIR="%{buildroot}" PREFIX="/usr" install install-man

mkdir -p %{buildroot}/%{_unitdir}
install -D -p -m 0644 %{SOURCE1} %{buildroot}%{_unitdir}/containerd.service
install -vdm 755 %{buildroot}/opt/containerd/{bin,lib}

# Keep the stock Azure Linux config active for non-ACL systems.
install -D -p -m 0644 %{SOURCE2} %{buildroot}%{_sysconfdir}/containerd/config.toml

# --- containerd2-erofs -----------------------------------------------------
# Everything below is ACL-only and must live under /usr: the immutable-OS bake
# discards RPM-contributed /etc paths, and sysexts only ship /usr.

# EROFS/dm-verity capability shared by overlayfs and EROFS runtime roots.
install -D -p -m 0644 %{SOURCE3} %{buildroot}%{_datadir}/containerd2/acl-erofs.toml

# Overlayfs-capability composition root and startup selector.
install -D -p -m 0644 %{SOURCE4} %{buildroot}%{_datadir}/containerd2/acl-config.toml
install -D -p -m 0644 %{SOURCE5} %{buildroot}%{_prefix}/lib/systemd/system/containerd.service.d/90-acl-profile.conf

# Seeds /etc/containerd/config.toml on platforms that have no provisioning
# agent, so the composition root's literal import always resolves.
install -D -p -m 0644 %{SOURCE6} %{buildroot}%{_prefix}/lib/tmpfiles.d/10-containerd-acl.conf

# EROFS runtime delta and composition root.
install -D -p -m 0644 %{SOURCE7} %{buildroot}%{_datadir}/containerd2/acl-erofs-runtime.toml
install -D -p -m 0644 %{SOURCE8} %{buildroot}%{_datadir}/containerd2/acl-erofs-config.toml
install -D -p -m 0755 %{SOURCE9} %{buildroot}%{_libexecdir}/containerd2/acl-select-profile

%post
%systemd_post containerd.service

if [ $1 -eq 1 ]; then # Package install
	systemctl enable containerd.service > /dev/null 2>&1 || :
	systemctl start containerd.service > /dev/null 2>&1 || :
fi

%preun
%systemd_preun containerd.service

%postun
%systemd_postun_with_restart containerd.service

%files
%license LICENSE NOTICE
%{_bindir}/*
%{_mandir}/*
%config(noreplace) %{_unitdir}/containerd.service
%config(noreplace) %{_sysconfdir}/containerd/config.toml
%dir %{_sysconfdir}/containerd
%dir /opt/containerd
%dir /opt/containerd/bin
%dir /opt/containerd/lib

%files erofs
%{_datadir}/containerd2/acl-erofs.toml
%{_datadir}/containerd2/acl-config.toml
%{_datadir}/containerd2/acl-erofs-runtime.toml
%{_datadir}/containerd2/acl-erofs-config.toml
%{_libexecdir}/containerd2/acl-select-profile
%{_prefix}/lib/systemd/system/containerd.service.d/90-acl-profile.conf
%{_prefix}/lib/tmpfiles.d/10-containerd-acl.conf
%dir %{_datadir}/containerd2
%dir %{_libexecdir}/containerd2
%dir %{_prefix}/lib/systemd/system/containerd.service.d

%changelog
* Wed Aug 26 2026 Dallas Delaney <dadelan@microsoft.com> - 2.2.4-6022.verity
- Patch16: replace full precomputed EROFS blobs with compact signed tar indexes
  and reconstruct each verified data device from the OCI tar stream.
- Fail closed on malformed matching bundles and enforce the 512-byte dm-verity
  block contract required by EROFS tar-index filesystems.
- Complete Patch15's transfer-plugin capability advertisement so AgentBaker can
  detect when fetch-only dm-verity referrer retention is active.

* Mon Aug 24 2026 Dallas Delaney <dadelan@microsoft.com> - 2.2.4-6021.verity
- Keep overlayfs active while IPE is off, but load EROFS/dm-verity and both
  transfer unpack combinations so VHD baking can retain signed referrers.
- Patch15: retain the selected graph when a transfer unpacks into overlayfs;
  only immediate capable EROFS unpack consumes it transiently.
- Select the EROFS CRI and diff-service profile at containerd startup only
  after the ACL IPE policy is active, or for an explicitly static EROFS image.

* Mon Aug 24 2026 Dallas Delaney <dadelan@microsoft.com> - 2.2.4-6020.verity
- Patch15: retain the selected dm-verity referrer manifest and all signature,
  EROFS, and Merkle-tree content for fetch-only transfers and OCI imports, then
  reconstruct the signed layer annotations during deferred first-use unpack.
- Keep immediate-unpack artifacts transient and root retained content through
  standard content-store GC labels only while the cached image remains.
- Explicitly opt the ACL EROFS snapshotter into permissive dm-verity auto mode
  and order the EROFS differ before walking. Overlayfs remains unchanged, while
  signed EROFS layers fail closed if a capable applier is unavailable or loses
  first position.

* Fri Aug 21 2026 Dallas Delaney <dadelan@microsoft.com> - 2.2.4-6019.verity
- Patch12: bind dm-verity enforcement to the selected applier so CRI local
  pulls cannot silently discard discovered verification artifacts.
- Patch13: retain the shared mapper mount-lifecycle lock after the new
  selected-applier guard.
- Patch14: update the existing dm-verity snapshot test for Patch12's
  shared-layer-context constructor argument.

* Thu Aug 06 2026 Dallas Delaney <dadelan@microsoft.com> - 2.2.4-6018.verity
- Patch12: hold the dm-verity lock across the mount, not just the create. The
  lock covered lookup-and-create only; the mount(2) that follows it and the
  removal on the unmount side both ran unlocked. A device could therefore be
  removed after another container had verified it but before that container had
  mounted it, and the victim reported "verification failed" -- an integrity
  error for what was really a device pulled out from under it. Live mounts were
  never at risk (the kernel returns EBUSY while the mapper is open); the window
  is the moment the open count reaches zero. Seen as 1 failure in a burst of 10
  concurrent containers sharing one image, 0 in 20 sequential starts.

* Wed Aug 05 2026 Dallas Delaney <dadelan@microsoft.com> - 2.2.4-6017.verity
- Patch11: synthesise the shared EROFS layer label instead of rewriting the
  caller's. 6016.verity stripped the MCS categories from context=, which fixed
  the all-labelled case (the pause image, 274 rejections in build 1175150) but
  not the general one: container creation activates a layer with no context= at
  all, while task creation appends the consuming container's label, so an
  unlabelled mount and a labelled one still disagreed however the label was
  rewritten. Build 1175414 still lost all nine kubeadm kola cases through five
  reruns each, with 24 unlabelled activations against 4 labelled on the single
  device carrying the CoreDNS layer -- CoreDNS ships two replicas of one image,
  so it reproduces on a stock cluster. Request one synthesised label from every
  consumer, applied only when SELinux is enabled since mount(2) rejects
  context= otherwise. Isolation is unchanged: the per-container overlay stacked
  above the layer still carries the full MCS pair.

* Tue Aug 04 2026 Dallas Delaney <dadelan@microsoft.com> - 2.2.4-6016.verity
- Patch11: share EROFS layer mounts across containers under SELinux. context=
  is a superblock-wide option and an EROFS layer is one block device, so the
  first container's per-container MCS pair fixed the label for every later
  consumer and the kernel rejected the second mount with "Same superblock,
  different security settings". Any image used more than once failed to start
  on an enforcing node; because every pod sandbox shares the pause image, only
  the first pod on a node could start, which is what failed all nine kubeadm
  kola cases in build 1175150. Strip the MCS categories from the shared layer's
  label so every consumer requests the same superblock, matching what overlayfs
  already does with its lowerdirs. Isolation is unchanged: the per-container
  overlay stacked above the layer still carries the full MCS pair.

* Fri Jul 31 2026 Dallas Delaney <dadelan@microsoft.com> - 2.2.4-6015.verity
- Patch8: serialize the dm-verity device existence check against creation.
  Mapper names derive from the snapshot ID, so concurrent mounts of the same
  layer -- routine when several pods start from one image -- could both observe
  the device as absent and both attempt creation. The losing DM_DEV_CREATE
  fails on the taken name and go-dmverity's cleanup then removes the winning
  caller's device out from under a live mount.
- Patch8: pin the goroutine to its OS thread while opening a signed device.
  go-dmverity adds the root-hash signature to KEY_SPEC_THREAD_KEYRING and names
  it in the device-mapper table; the kernel resolves that name against the
  calling thread's keyrings. Go may migrate the goroutine between the add_key
  and the ioctls, intermittently rejecting a valid signature and leaking the
  key because the deferred unlink misses the originating thread too.
- Every commit in the series now builds independently, verified per commit.
- Known deferred: three defects in the vendored go-dmverity module (mapper
  cleanup armed before creation, thread-keyring affinity at source, and a hash
  device descriptor leaked in verify mode). These require an upstream fix plus
  a module bump -- hand-editing vendor/ would fail containerd's verify-vendor
  gate. The first two are neutralized by the containerd-side fixes above.

* Fri Jul 31 2026 Dallas Delaney <dadelan@microsoft.com> - 2.2.4-6014.verity
- Regenerate all three dm-verity patches with a second round of corrections from
  the source review, covering remote-input hardening and cross-feature isolation.
- Patch10: validate referrer descriptors before use. Descriptors are returned by
  a registry's referrers response verbatim (FetchReferrers hands back
  index.Manifests unchecked, and dockerFetcher.Fetch is lazy and validates
  nothing), so a crafted digest reached go-digest's Digest.Verifier(), which
  panics instead of returning an error. A hostile or compromised registry could
  therefore crash containerd on any pull with dm-verity enabled. The digest is
  now validated first, and the attacker-controlled descriptor size is bounded by
  maxManifestSize before io.ReadAll allocates on the strength of it.
- Patch10: stop failing the pull when precomputed dm-verity annotations are
  present but dm-verity is disabled. Those annotations can arrive straight off
  an image manifest without any referrer discovery, so erroring let any registry
  make a node that never opted into the feature refuse an image. Such layers are
  now converted the ordinary way.
- Patch8: never wrap a dm-verity mapper in a loop device. Once forceloop latches
  -- which happens on any kernel without file-backed EROFS mounts (< 6.12), and
  so on every ACL node, as soon as one plain EROFS layer is mounted -- the
  handler rewrote the mount source from /dev/mapper/containerd-erofs-<id> to
  /dev/loopN. Unmount identifies the device to tear down from the mount source,
  so it stopped recognising the mapper and dmverity.Close was never called,
  leaking a device-mapper device and its loops on every container stop. Reachable
  on any node running a mix of signed and unsigned images.
- Patch9: compose the CRI image-handler wrappers rather than overwriting them.
  RemoteContext.HandlerWrapper is a single field, so passing
  WithImageHandlerWrapper twice kept only the last: turning on dm-verity
  referrers silently dropped the remote-snapshot annotations used by
  stargz/nydus/overlaybd. Not reachable with the default
  disable_snapshot_annotations, and not used by ACL, but it silently disables an
  unrelated feature.
- Split the native-EROFS correction across Patch8 and Patch10 so that every
  commit in the series builds on its own: Patch8 formats the hash tree, and
  Patch10 adds the signature write, since it is the patch that introduces
  writeLayerSignature. The previous generation called writeLayerSignature from
  Patch8, where it does not yet exist, leaving the first three commits
  uncompilable.
* Fri Jul 31 2026 Dallas Delaney <dadelan@microsoft.com> - 2.2.4-6013.verity
- Regenerate Patch8 with four fail-closed corrections found by a source review
  of the dm-verity series. Patch9/Patch10 are unchanged apart from hunk offsets.
- Patch8: treat unusable dm-verity metadata as an error instead of as "no
  dm-verity". Both the erofs mount handler and the snapshotter's
  applyDmverityPolicy previously mapped every ReadMetadata failure onto the
  plain-EROFS path, so truncating or corrupting a single .dmverity sidecar
  silently downgraded a verity-protected layer to an unverified mount, and mode
  "on" could be satisfied by a file that only had to exist. A genuinely absent
  sidecar (ENOENT) still mounts plainly under mode "auto"; unparseable metadata
  now fails the mount.
- Patch8: verify an existing dm-verity device before reusing it. Device-mapper
  names are host-global while snapshot IDs are only unique within a snapshotter
  root, so the reuse branch could adopt a mapper belonging to another layer. It
  now calls the previously unused dmverity.VerifyDevice against the expected
  root hash and refuses the mount on mismatch.
- Patch8: apply the dm-verity policy to native EROFS layers. The native branch
  in the erofs differ returned before hash-tree formatting and signature
  enforcement, so a registry could bypass both -- including require_signatures
  -- just by publishing its layers with an EROFS media type.
- Patch8: reject require_signatures=true with enable_dmverity=false at plugin
  init. require_signatures is only consumed inside the dm-verity block, so that
  combination previously gave an operator who asked for mandatory signatures no
  enforcement whatsoever.
- No spec-level config or dependency changes; non-ACL nodes are unaffected,
  since the erofs differ only advertises the dmverity-referrers capability when
  enable_dmverity is explicitly set, which only the ACL profile does.

* Fri Jul 31 2026 Dallas Delaney <dadelan@microsoft.com> - 2.2.4-6012.verity
- Drop the unused Requires: veritysetup from containerd2-erofs. Hash-tree
  formatting and device activation go through the vendored go-dmverity library
  and dm ioctls; the CLI is never exec'd. The only occurrence of the name in
  the containerd tree is a comment in internal/dmverity/dmverity.go. erofs-utils
  is retained -- internal/erofsutils/mount.go really does exec mkfs.erofs.
- Drop aks-dmverity-modules.conf (modules-load.d) entirely. Both copies were
  dead payload. On ACL the /etc copy is stripped by the immutable-OS bake and
  the /usr copy is merged by systemd-sysext only after
  systemd-modules-load.service has run, so neither is ever read -- confirmed on
  a live node from build 1171833, where /etc/modules-load.d/aks-dmverity.conf
  does not exist and erofs/dm_verity are instead loaded by modprobe@erofs and
  modprobe@dm_verity (both Result=success), pulled in by 90-acl-profile.conf.
  The drop-in also covers the plain-RPM case the files were retained for: its
  [Unit] Wants=/After= apply to containerd.service regardless of whether the
  Environment= line is honored, and it ships in this same subpackage. Renumber
  Source5-7 to Source4-6.

* Mon Jul 27 2026 Dallas Delaney <dadelan@microsoft.com> - 2.2.4-6011.verity
- Rebuild the dm-verity patch series from real git commits instead of diffing
  hand-built trees. The four ACL patches 0005-0008 collapse into two,
  0005-dm-verity-acl-integration and
  0006-dm-verity-precomputed-erofs-artifacts, exported from five reviewable
  commits on containerd branch dadelan/acl-erofs rooted at v2.2.4. Patch8
  remains split by author so it can be dropped when add-signature-support
  merges upstream. No functional change on Linux beyond the two fixes below.
- Keep the erofs snapshotter byte-identical to the upstream signature-support
  patch. The ACL series no longer formats dm-verity at snapshot commit time.
  That path wrote a hash tree but never a signature, so the mount handler --
  which treats the signature sidecar as optional -- opened the device unsigned:
  integrity without authenticity, which IPE cannot enforce on. Gating it on a
  differ capability was worse still: the snapshotter plugin had to declare
  Requires on the diff plugin, and because the metadata plugin already requires
  the snapshot plugin that closes a cycle. containerd's plugin registry walks
  Requires with a depth-first traversal that marks a node visited only after
  recursing into it, so it has no cycle detection and the daemon dies at
  startup with "fatal error: stack overflow" before any plugin initializes.
  Dropping Requires does not help either: the resolved order puts the
  snapshotter ahead of the differ, so the capability always reads false.
  Signed dm-verity comes from the precomputed referrer path in Patch10, which
  is the only signing mechanism ACL ships. Plugin-graph resolution against the
  real ACL profile is now a documented regeneration gate.
- Add a non-Linux stub for internal/dmverity.FormatLayerBlob. The erofs
  snapshotter has no build constraint, so referencing the Linux-only symbol
  from it broke GOOS=windows and GOOS=darwin builds of the tree this spec
  compiles. Cross-compilation is now a documented regeneration gate.
- Drop an orphaned "time" import from the upstream signature-support patch and
  carry it with its consumer instead. The old tree-diff generation left the
  import behind without its code, so that patch could not compile on its own.
  The combined tree was unaffected, which is why it went unnoticed.
- Apply gofmt to the series; containerd CI enforces it and the previous
  patches did not pass.
- Move ACL's IPE policy introspection out of the upstream signature-support
  patch. It was never Aadhar's code; it leaked in because the old generation
  method built that patch by reverting the ACL changes out of a combined tree
  and the revert missed it, so the patch's "no ACL changes" claim was false.
  The code is now removed from the series outright -- containerd passes a
  layer signature whenever one is present and the kernel alone interprets IPE
  policy -- and the author boundary is enforced by commit ancestry rather than
  by hand. No change to the built tree.

* Mon Jul 27 2026 Dallas Delaney <dadelan@microsoft.com> - 2.2.4-6010.verity
- Load erofs and dm_verity from the 90-acl-profile.conf drop-in via
  modprobe@.service instead of relying on modules-load.d. On ACL this package
  ships inside the containerd sysext, and systemd-sysext merges /usr AFTER
  systemd-modules-load.service has run, so modules-load.d/aks-dmverity.conf did
  not yet exist at the only moment it would be read and erofs was never loaded.
  containerd then skipped the erofs snapshotter ("EROFS unsupported, please
  `modprobe erofs`"), the transfer plugin could not resolve that snapshotter,
  and the Transfer gRPC service went unregistered -- so every image pull failed
  with "unknown service containerd.services.transfer.v1.Transfer". Observed on
  build 1168478 (03:39:56 modules-load finished, 03:39:58 sysext merged,
  03:40:01 containerd start); confirmed fixed by loading erofs and restarting
  containerd, after which "ctr image pull" and "ctr run" both succeed.
- Move the /etc/modules-load.d/aks-dmverity.conf copy from the main package to
  containerd2-erofs. Autoloading erofs and dm_verity is ACL behavior, and the
  main package is meant to be behavior-neutral on stock Azure Linux.

* Sun Jul 26 2026 Dallas Delaney <dadelan@microsoft.com> - 2.2.4-6009.verity
- Split the ACL EROFS/dm-verity profile into a containerd2-erofs subpackage so
  the main package is behavior- and dependency-neutral. Move erofs-utils and
  veritysetup off the main package; stock Azure Linux no longer pulls them.
- Activate the profile from the package instead of from provisioning: ship an
  ACL composition root at %%{_datadir}/containerd2/acl-config.toml and select it
  with a "90-" systemd drop-in, which sorts after AgentBaker's "50-" drop-in.
- Keep the composition root free of settings. containerd merges a file before
  its imports and later imports override earlier ones, so the ACL delta has to
  be the last import to override the node-specific base config.
- Seed /etc/containerd/config.toml via tmpfiles.d on platforms with no
  provisioning agent. Without it, non-AKS ACL images would resolve the
  composition root's literal import to a missing file, and would also lose the
  image's base containerd configuration entirely.
- Install every ACL path under /usr; the immutable-OS bake discards
  RPM-contributed /etc paths and sysexts ship only /usr.
* Thu Jul 23 2026 Dallas Delaney <dadelan@microsoft.com> - 2.2.4-6008.verity
- Restore the stock containerd configuration and ship ACL EROFS/dm-verity
  settings as an explicit, inactive import profile.
- Disable dm-verity referrer discovery and EROFS dm-verity mounting by default.
* Thu Jul 23 2026 Dallas Delaney <dadelan@microsoft.com> - 2.2.4-6007.verity
- Use the normal MCR pause image and retain the package-owned ACL dm-verity
  configuration.
* Tue Jul 21 2026 Dallas Delaney <dadelan@microsoft.com> - 2.2.4-6006.verity
- Select the newest precomputed dm-verity bundle by OCI creation time, matching
  the existing legacy-referrer behavior.
- Parse only the selected newest bundle so malformed replacement publications
  fail closed instead of falling back to an older valid bundle.
* Fri Jul 10 2026 Dallas Delaney <dadelan@microsoft.com> - 2.2.4-6005.verity
- Verify signed precomputed EROFS/dm-verity OCI bundles, fetch their EROFS and
  Merkle-tree blobs before unpack, and materialize them as a separate hash
  device without running mkfs.erofs or dm-verity formatting on the node.
- Preserve kernel PKCS#7 validation and IPE signature enforcement. Validate
  source-layer mapping through the deterministic, root-covered EROFS UUID and
  fail closed on malformed, incomplete, or mismatched artifacts.
* Thu Jul 09 2026 Dallas Delaney <dadelan@microsoft.com> - 2.2.4-6004.verity
- Read active IPE policy text from the kernel's securityfs "policy" file
  instead of the nonexistent "raw" file, allowing dm-verity signatures to be
  passed when the active policy references dmverity_signature.
* Tue Jul 08 2026 Dallas Delaney <dadelan@microsoft.com> - 2.2.4-6003.verity
- Decouple dm-verity signature PASS-THROUGH from require_signatures and gate it
  on the active IPE policy: the erofs differ now reads /sys/kernel/security/ipe
  and, when an active IPE policy consumes the dmverity_signature property,
  writes the .dmverity signature sidecar for any signed layer (so signed layers
  set IPE's dmverity_signature=TRUE even with require_signatures=false). When no
  such IPE policy is active the signature is NOT passed, so an untrusted
  signature can never fail the mount on a node that does not require signatures.
  Previously the sidecar was written only under require_signatures, so relaxing
  it dropped all signatures.
- Ship the dm-verity config relaxed (dmverity_mode=auto, require_signatures
  =false) so unsigned layers still mount and the node comes up, delegating
  "must be signed" enforcement to the IPE boot policy (audit mode) baked into
  the kernel. NOTE: AgentBaker components.json containerd2 pin must be bumped
  to 2.2.4-6003.verity.azl3 to match.
* Fri Jun 05 2026 Dallas Delaney <dadelan@microsoft.com> - 2.2.4-6002.verity
- Make the dm-verity config + mcr->notaryaksegistry redirect active on
  ACL at FIRST BOOT, before any image is pulled, instead of only after
  AKS CSE runs. Aligned with azurelinux + steamboat containerd2-2.2.4-6002.verity.
- Move the containerd.service.d/dmverity-overlay.conf drop-in from
  /etc/systemd/system to %{_unitdir} (/usr/lib/systemd/system). The /etc
  copy is stripped by the ACL immutable-OS bake, so on ACL the drop-in
  never ran and config.toml/hosts.toml were only restored by CSE at
  provisioning time -- AFTER first-boot prefetch had already cached
  unsigned layers pulled straight from MCR. The /usr/lib drop-in survives
  the bake and runs ExecStartPre on every containerd start.
- Extend the drop-in to also restore certs.d/mcr.microsoft.com/hosts.toml
  (not just config.toml) from the /usr/share/containerd2 stash.
- Also ship modules-load.d/aks-dmverity.conf under /usr/lib. All no-ops
  on standard AzureLinux V3 where /etc/* is preserved.

* Wed Jun 04 2026 Dallas Delaney <dadelan@microsoft.com> - 2.2.4-6001.verity
- Also stash hosts.toml under /usr/share/containerd2/certs.d/mcr.microsoft.com/.
- ACL's immutable-OS image bake strips every /etc/* path contributed by
  RPMs (only /usr/* survives extraction), which silently dropped the
  /etc/containerd/certs.d/mcr.microsoft.com/hosts.toml introduced in
  2.0.1-3012. Without the redirect, kubelet pulls go straight to MCR which
  has no dm-verity referrers, so every signed-image pull fails with
  "dm-verity signature required but not present on layer ...". The
  /usr/share/ copy mirrors the existing /usr/share/containerd2/config.toml
  pattern so AgentBaker's cse_config.sh can re-overlay it onto /etc at
  every bootstrap. No-op on standard AzureLinux V3 VHDs where /etc/* is
  preserved -- the cse_config.sh overlay is idempotent there.
  Validated end-to-end on dadelan-acl-test (ACL VHD 1.1780543260.12214)
  2026-06-04: manual hosts.toml deploy + containerd restart took the
  cluster from "every kube-system pod ImagePullBackOff with dm-verity
  signature required" to all pods Running with zero rejections.

* Tue Jun 02 2026 Dallas Delaney <dadelan@microsoft.com> - 2.2.4-5000
- Port to upstream containerd v2.2.4 + AzureLinux 3.0-dev baseline.
- Drop 0001 (diff-walking mount-manager): merged upstream in v2.2.2
  (PR #13186 / commit 409f75be8), ancestor of v2.2.4.
- Drop 0002 (tardev-support): now provided by AzureLinux baseline as
  tardev-support.patch (Patch1).
- Drop 0003 (cri credential leak): merged upstream in v2.2.2 (PR #12491 /
  commit cb3ae2119), ancestor of v2.2.4.
- Adopt AzureLinux 3.0-dev's 8-patch baseline verbatim (Patch0-7):
  multi-snapshotters-support, tardev-support, 5 CVE backports
  (CVE-2026-{39882,33814,39821,42506,27136}), fix-TestCgroupNamespace-cgroupv1.
- Regenerate 0004 + 0005 against v2.2.4 tree (5 context-only conflicts in
  0004 hand-fixed: docs/snapshotters/erofs.md trailing TODO, go.mod, go.sum,
  plugins/snapshots/erofs/erofs.go, plugins/snapshots/erofs/plugin/plugin.go;
  0005 applied cleanly with offsets). Preserves boltdb label-cap fix
  (containerd.io/dmverity/* keys).
- Switch Source0 from per-commit GitHub archive to v%{version} release tag.
- Switch %autosetup target dir from %{extracted_dir}=<repo>-<sha> to
  %{extracted_dir}=<repo>-<version> to match release-tarball layout.

* Tue Jun 02 2026 Dallas Delaney <dadelan@microsoft.com> - 2.2.0-4001.cb15e731a
- 0004 patch fix: rename TargetLayer{Signature,RootHash}Label prefix from
  containerd.io/snapshot/ to containerd.io/dmverity/. The old prefix matched
  snapshots.FilterInheritedLabels and auto-promoted the base64 PKCS#7 sig
  into a boltdb snapshot label, which exceeded the 4096-byte label cap
  for enterprise ESRP signatures (RSA-4096 leaf + intermediates + RFC3161
  timestamp = ~5.7KB). Pull failed with InvalidArgument. Sidecar-file
  flow into veritysetup is unchanged; label persistence was unread fallout.

* Sun Jun 01 2026 Dallas Delaney <dadelan@microsoft.com> - 2.2.0-4000.cb15e731a
- Patch-based spec. Source pinned to upstream containerd@cb15e731a (immutable)
  with 5 patches (see PATCHES.md). Enables ADO builds without committing
  binary tarballs. Behaviorally equivalent to steamboat 3012.
