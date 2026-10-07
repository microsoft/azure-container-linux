# Based on the Azure Linux 3.0 cryptsetup recipe; retain the distro build options.
Summary:        A utility for setting up encrypted disks
Name:           cryptsetup
Version:        2.4.3
Release:        7%{?dist}
License:        GPLv2+ AND LGPLv2+
Vendor:         Microsoft Corporation
Distribution:   Azure Linux
Group:          Applications/System
URL:            https://gitlab.com/cryptsetup/cryptsetup
Source0:        https://www.kernel.org/pub/linux/utils/cryptsetup/v2.4/%{name}-%{version}.tar.xz
Patch0:         cryptsetup-add-system-library-paths.patch
Patch1:         cryptsetup-verity-key-errors.patch
BuildRequires:  device-mapper-devel >= 2.03.23
BuildRequires:  findutils
BuildRequires:  gcc
BuildRequires:  gettext-devel
BuildRequires:  json-c-devel
BuildRequires:  libblkid-devel
BuildRequires:  libpwquality-devel
BuildRequires:  libtool
BuildRequires:  openssl-devel
BuildRequires:  pkgconfig
BuildRequires:  popt-devel
BuildRequires:  util-linux
BuildRequires:  libssh-devel
Requires:       cryptsetup-libs = %{version}-%{release}
Requires:       libpwquality >= 1.2.0
Provides:       cryptsetup-luks = %{version}-%{release}

%description
The cryptsetup package contains a utility for setting up
disk encryption using dm-crypt kernel module.

%package devel
Summary:        Headers and libraries for using encrypted file systems
Group:          Development/Libraries
Requires:       %{name} = %{version}-%{release}
Requires:       pkgconfig
Provides:       cryptsetup-luks-devel = %{version}-%{release}

%description devel
The cryptsetup-devel package contains libraries and header files
used for writing code that makes use of disk encryption.

%package libs
Summary:        Cryptsetup shared library
Group:          System Environment/Libraries
Requires:       json-c
Provides:       cryptsetup-luks-libs = %{version}-%{release}
Provides:       acl-verity-key-errors = 1

%description libs
This package contains the cryptsetup shared library, libcryptsetup.
ACL preserves dm-verity signature key errors separately from storage errors.

%package ssh-token
Summary:        Cryptsetup LUKS2 SSH token
Requires:       cryptsetup-libs = %{version}-%{release}

%description ssh-token
This package contains the LUKS2 SSH token.

%package -n veritysetup
Summary:        A utility for setting up dm-verity volumes
Group:          Applications/System
Requires:       cryptsetup-libs = %{version}-%{release}

%description -n veritysetup
The veritysetup package contains a utility for setting up
disk verification using dm-verity kernel module.

%package -n integritysetup
Summary:        A utility for setting up dm-integrity volumes
Group:          Applications/System
Requires:       cryptsetup-libs = %{version}-%{release}

%description -n integritysetup
The integritysetup package contains a utility for setting up
disk integrity protection using dm-integrity kernel module.

%package reencrypt
Summary:        A utility for offline reencryption of LUKS encrypted disks.
Group:          Applications/System
Requires:       cryptsetup-libs = %{version}-%{release}

%description reencrypt
This package contains cryptsetup-reencrypt utility which
can be used for offline reencryption of disk in situ.

%prep
%setup -q -n cryptsetup-%{version}
%patch 0 -p1
%patch 1 -p1
chmod -x misc/dracut_90reencrypt/*

%build
./autogen.sh
%configure \
    --enable-fips \
    --enable-pwquality \
    --enable-internal-sse-argon2 \
    --with-default-luks-format=LUKS2
make %{?_smp_mflags}

%install
make install DESTDIR=%{buildroot}
find %{buildroot} -type f -name "*.la" -delete -print
mkdir -p %{buildroot}%{_datadir}/acl
echo 1 > %{buildroot}%{_datadir}/acl/cryptsetup-verity-key-errors
%find_lang cryptsetup

%post -n cryptsetup-libs -p /sbin/ldconfig
%postun -n cryptsetup-libs -p /sbin/ldconfig

%files
%license COPYING
%doc AUTHORS FAQ docs/*ReleaseNotes
%{_mandir}/man8/cryptsetup.8.gz
%{_sbindir}/cryptsetup

%files -n veritysetup
%license COPYING
%{_mandir}/man8/veritysetup.8.gz
%{_sbindir}/veritysetup

%files -n integritysetup
%license COPYING
%{_mandir}/man8/integritysetup.8.gz
%{_sbindir}/integritysetup

%files reencrypt
%license COPYING
%doc misc/dracut_90reencrypt
%{_mandir}/man8/cryptsetup-reencrypt.8.gz
%{_sbindir}/cryptsetup-reencrypt

%files devel
%doc docs/examples/*
%{_includedir}/libcryptsetup.h
%{_libdir}/libcryptsetup.so
%{_libdir}/pkgconfig/libcryptsetup.pc

%files libs -f cryptsetup.lang
%license COPYING COPYING.LGPL
%{_libdir}/libcryptsetup.so.*
%{_datadir}/acl/cryptsetup-verity-key-errors
%exclude %{_tmpfilesdir}/cryptsetup.conf
%ghost %dir /run/cryptsetup

%files ssh-token
%license COPYING COPYING.LGPL
%{_libdir}/%{name}/libcryptsetup-token-ssh.so
%{_mandir}/man8/cryptsetup-ssh.8.gz
%{_sbindir}/cryptsetup-ssh

%changelog
* Tue Oct 06 2026 Aadhar Agarwal <aadagarwal@microsoft.com> - 2.4.3-7
- Preserve kernel key errors for dm-verity signature-only fallback.
