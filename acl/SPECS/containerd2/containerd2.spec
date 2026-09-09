%global debug_package %{nil}
%define upstream_name containerd
%define commit_hash db8809540e1a7a9da5d518876894933ff55692ab

Summary: Industry-standard container runtime
Name: %{upstream_name}2
Version: 2.3.4
Release: 9005.mirrortest%{?dist}
License: ASL 2.0
Group: Tools/Container
URL: https://www.containerd.io
Vendor: Microsoft Corporation
Distribution: Azure Linux

Source0: https://github.com/containerd/containerd/archive/v%{version}.tar.gz#/%{upstream_name}-%{version}.tar.gz
Source1: containerd.service
Source2: containerd.toml
Source3: containerd-acl-erofs.toml
Source4: containerd-acl-config.toml
Source5: containerd-acl-profile.conf
Source6: containerd-acl-tmpfiles.conf
Source7: containerd-acl-erofs-runtime.toml
Source8: containerd-acl-erofs-config.toml
Source9: containerd-acl-select-profile
Source10: mcr-mirror-hosts.toml

Patch0:	multi-snapshotters-support.patch
Patch1:	tardev-support.patch
Patch2:	fix-TestCgroupNamespace-cgroupv1.patch
Patch3:	CVE-2026-56852.patch
Patch4:	0001-erofs-add-signed-dm-verity-mapper-foundation.patch
Patch5:	0002-erofs-consume-signed-referrer-materializations.patch
Patch6:	0003-remotes-bound-OCI-referrers-traversal.patch
Patch7:	0004-cri-integrate-signed-runtime-snapshotters.patch
Patch8:	0005-tests-cover-signed-EROFS-referrer-lifecycle.patch

%{?systemd_requires}

# Temporarily stay on Go 1.26 until the Go 1.27 ML-KEM backend is fixed.
BuildRequires: golang >= 1.26.7
BuildRequires: golang < 1.27
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
Requires: erofs-utils

%description erofs
Provides the opt-in EROFS and signed dm-verity runtime profile used by Azure
Container Linux. The main containerd2 package remains behavior-neutral.

%prep
%autosetup -p1 -n %{upstream_name}-%{version}

%build
export GOEXPERIMENT=ms_nocgo_opensslcrypto
export BUILDTAGS="-mod=vendor"
make VERSION="%{version}" REVISION="%{commit_hash}" binaries man

%check
export GOEXPERIMENT=ms_nocgo_opensslcrypto
export BUILDTAGS="-mod=vendor"
make VERSION="%{version}" REVISION="%{commit_hash}" test

%install
make VERSION="%{version}" REVISION="%{commit_hash}" DESTDIR="%{buildroot}" PREFIX="/usr" install install-man

mkdir -p %{buildroot}/%{_unitdir}
install -D -p -m 0644 %{SOURCE1} %{buildroot}%{_unitdir}/containerd.service
install -D -p -m 0644 %{SOURCE2} %{buildroot}%{_sysconfdir}/containerd/config.toml
install -vdm 755 %{buildroot}/opt/containerd/{bin,lib}

install -D -p -m 0644 %{SOURCE3} %{buildroot}%{_datadir}/containerd2/acl-erofs.toml
install -D -p -m 0644 %{SOURCE4} %{buildroot}%{_datadir}/containerd2/acl-config.toml
install -D -p -m 0644 %{SOURCE5} %{buildroot}%{_prefix}/lib/systemd/system/containerd.service.d/90-acl-profile.conf
install -D -p -m 0644 %{SOURCE6} %{buildroot}%{_prefix}/lib/tmpfiles.d/10-containerd-acl.conf
install -D -p -m 0644 %{SOURCE7} %{buildroot}%{_datadir}/containerd2/acl-erofs-runtime.toml
install -D -p -m 0644 %{SOURCE8} %{buildroot}%{_datadir}/containerd2/acl-erofs-config.toml
install -D -p -m 0755 %{SOURCE9} %{buildroot}%{_libexecdir}/containerd2/acl-select-profile
install -D -p -m 0644 %{SOURCE10} %{buildroot}%{_datadir}/containerd2/certs.d/mcr.microsoft.com/hosts.toml

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
%{_datadir}/containerd2/certs.d/mcr.microsoft.com/hosts.toml
%{_prefix}/lib/systemd/system/containerd.service.d/90-acl-profile.conf
%{_prefix}/lib/tmpfiles.d/10-containerd-acl.conf
%dir %{_datadir}/containerd2
%dir %{_datadir}/containerd2/certs.d
%dir %{_datadir}/containerd2/certs.d/mcr.microsoft.com
%dir %{_libexecdir}/containerd2
%dir %{_prefix}/lib/systemd/system/containerd.service.d

%changelog
* Wed Sep 09 2026 Dallas Delaney <dadelan@microsoft.com> - 2.3.4-9005.mirrortest
- Add the isolated fail-closed MCR tar-index mirror for AKS validation.
- Restore the packaged hosts.toml before every containerd start.
- Keep the PR-ready 2.3.4 signed EROFS carry unchanged on its separate branch.

* Wed Sep 09 2026 Dallas Delaney <dadelan@microsoft.com> - 2.3.4-6025.verity
- Rebase the signed EROFS/dm-verity carry onto containerd 2.3.4.
- Keep signed OCI referrer handling separate from upstream local dm-verity.
- Preserve the ordinary overlayfs lifecycle and add package-time regression tests.

* Tue Sep 08 2026 Dallas Delaney <dadelan@microsoft.com> - 2.2.4-6024.verity
- Add four production-only patches for signed EROFS/dm-verity materialization,
  bounded referrer pagination, and CRI snapshotter-cache refresh.
- Add the opt-in ACL EROFS runtime profile; the base package remains unchanged.
- Keep Go 1.26 ACL builds on the cgo-less system-crypto experiment while
  preserving the Go 1.27 behavior inherited from Azure Linux 3.0-dev.

* Wed Sep 02 2026 Muhammad Falak R Wani <mwani@microsoft.com> - 2.2.4-7
- Drop 'GOEXPERIMENT=ms_nocgo_opensslcrypto', removed in Go 1.27. Systemcrypto is
  now selected automatically and supports CGO_ENABLED=0 on Linux.

* Mon Jul 27 2026 Azure Linux Security Servicing Account <azurelinux-security@microsoft.com> - 2.2.4-6
- Patch for CVE-2026-56852

* Thu Jul 09 2026 Aadhar Agarwal <aadagarwal@microsoft.com> - 2.2.4-5
- Remove 'BuildRequires: golang < 1.25' and set GOEXPERIMENT=ms_nocgo_opensslcrypto
  to build with the default Go toolchain, resolving Go stdlib CVE-2026-25679,
  CVE-2026-27139, CVE-2026-33811, CVE-2026-39836 (was built on Go 1.24.13).

* Fri Jun 19 2026 Azure Linux Security Servicing Account <azurelinux-security@microsoft.com> - 2.2.4-4
- Patch for CVE-2026-42502, CVE-2026-25681, CVE-2026-25680

* Tue Jun 16 2026 Henry Beberman <henry.beberman@microsoft.com> - 2.2.4-3
- Patch for CVE-2026-50195, CVE-2026-53488, CVE-2026-53492, CVE-2026-53489, CVE-2026-47262

* Sat May 30 2026 Jon Slobodzian <joslobo@microsoft.com> - 2.2.4-2
- Resolve merge from fasttrack, bring patches for CVE-2026-42506, CVE-2026-39821, CVE-2026-27136 forward to 2.2.4 version of containerd2.

* Fri May 29 2026 Aadhar Agarwal <aadagarwal@microsoft.com> - 2.2.4-1
- Upgrade to 2.2.4
- Pulls in CVE-2026-46680 fix (PR #13448 / 0a8f65bef)
- Remove CVE-2026-34986.patch (in v2.2.4: go-jose/v4 v4.1.4, PR #13292 / 4413816ce)
- Remove CVE-2026-35469.patch (in v2.2.3: spdystream v0.5.1 / 31bd34a06)
- Remove fix-credential-leak-in-cri-errors.patch (in v2.2.2: PR #12491 / cb3ae2119)
- Retain CVE-2026-39882.patch (otel v1.35.0 lacks PR #8108)
- Retain CVE-2026-33814.patch (x/net v0.47.0 lacks 1e71bd86e)
- Add fix-TestCgroupNamespace-cgroupv1.patch (PR #13240; allows %check on cgroup-v1 build hosts)
- Regenerate multi-snapshotters-support.patch against v2.2.4 (upstream absorbed runtimeHandler plumbing in v2.2.3)

* Fri May 29 2026 Azure Linux Security Servicing Account <azurelinux-security@microsoft.com> - 2.1.6-5
- Patch for CVE-2026-33814

* Thu May 28 2026 Azure Linux Security Servicing Account <azurelinux-security@microsoft.com> - 2.1.6-4
- Patch for CVE-2026-39882

* Wed May 27 2026 Azure Linux Security Servicing Account <azurelinux-security@microsoft.com> - 2.1.6-3
- Patch for CVE-2026-42506, CVE-2026-39821, CVE-2026-27136

* Fri Apr 24 2026 Jyoti Kanase <v-jykanase@microsoft.com> - 2.1.6-2
- Modify CVE-2026-35469 patch for 2.1.6
- Patch for CVE-2026-34986

* Fri Apr 17 2026 Jyoti Kanase <v-jykanase@microsoft.com> - 2.1.6-1
- Upgrade to 2.1.6
- Remove CVE patches fixed in upstream: CVE-2024-25621, CVE-2024-40635,
  CVE-2024-45338, CVE-2025-22872, CVE-2025-27144, CVE-2025-47291,
  CVE-2025-47911, CVE-2025-58190, CVE-2025-64329
- Modify fix-credential-leak-in-cri-errors patch to keep only 2/2 not yet merged in upstream
- Rebase multi-snapshotters-support patch for 2.1.6

* Tue Apr 07 2026 Kanishk Bansal <kanbansal@microsoft.com> - 2.0.0-19
- Patch CVE-2026-35469

* Thu Feb 12 2026 Azure Linux Security Servicing Account <azurelinux-security@microsoft.com> - 2.0.0-18
- Patch for CVE-2025-58190, CVE-2025-47911

* Wed Jan 21 2026 Aadhar Agarwal <aadagarwal@microsoft.com> - 2.0.0-17
- Backport fix for credential leak in CRI error logs

* Mon Nov 24 2025 Azure Linux Security Servicing Account <azurelinux-security@microsoft.com> - 2.0.0-16
- Patch for CVE-2025-64329

* Tue Nov 11 2025 Azure Linux Security Servicing Account <azurelinux-security@microsoft.com> - 2.0.0-15
- Patch for CVE-2024-25621

* Sun Aug 31 2025 Andrew Phelps <anphel@microsoft.com> - 2.0.0-14
- Set BR for golang to < 1.25

* Mon Jul 21 2025 Saul Paredes <saulparedes@microsoft.com> - 2.0.0-13
- Add "Provides/Obsoletes:" to shift all installs of moby-containerd-cc to containerd2

* Tue Jun 10 2025 Mitch Zhu <mitchzhu@microsoft.com> - 2.0.0-12
- Add updated tardev-snapshotter support patch

* Tue Jun 10 2025 Mitch Zhu <mitchzhu@microsoft.com> - 2.0.0-11
- Add updated multi-snapshotters-support patch

* Fri May 30 2025 Durga Jagadeesh Palli <v-dpalli@microsoft.com> - 2.0.0-10
- Patch CVE-2025-47291

* Thu May 22 2025 Aninda Pradhan <v-anipradhan@microsoft.com> - 2.0.0-9
- Patch CVE-2025-22872

* Wed Apr 09 2025 Aadhar Agarwal <aadagarwal@microsoft.com> - 2.0.0-8
- Fix CVE-2024-40635

* Tue Apr 01 2025 Nan Liu <liunan@microsoft.com> - 2.0.0-7
- Remove the tardev-snapshotter patch for Kata CC support.

* Fri Mar 21 2025 Dallas Delaney <dadelan@microsoft.com> - 2.0.0-6
- Fix CVE-2025-27144

* Mon Mar 03 2025 Nan Liu <liunan@microsoft.com> - 2.0.0-5
- Add "Provides/Obsoletes:" to shift all installs of containerd and moby-containerd to containerd2

* Mon Feb 03 2025 Mitch Zhu <mitchzhu@microsoft.com> - 2.0.0-4
- Fix ptest in tardev-snapshotter support patch

* Sun Jan 26 2025 Mitch Zhu <mitchzhu@microsoft.com> - 2.0.0-3
- Added patch to support tardev-snapshotter for Kata CC.

* Thu Jan 23 2025 Kavya Sree Kaitepalli <kkaitepalli@microsoft.com> - 2.0.0-2
- Fix CVE-2024-45338 by an unstream patch

* Wed Dec 11 2024 Nan Liu <liunan@microsoft.com> - 2.0.0-1
- Created a standalone package for containerd 2.0.0
- Initial CBL-Mariner import from Azure
- Initial version and License verified
