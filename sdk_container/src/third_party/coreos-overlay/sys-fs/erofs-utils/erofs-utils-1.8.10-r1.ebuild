# Copyright 2021-2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

inherit autotools

DESCRIPTION="Userspace tools for EROFS"
HOMEPAGE="https://git.kernel.org/pub/scm/linux/kernel/git/xiang/erofs-utils.git"
SRC_URI="https://git.kernel.org/pub/scm/linux/kernel/git/xiang/${PN}.git/snapshot/${P}.tar.gz"

LICENSE="GPL-2+"
SLOT="0"
KEYWORDS="amd64 arm64"
IUSE="+lz4"

RDEPEND="
	lz4? ( app-arch/lz4:0= )
"
DEPEND="${RDEPEND}"
BDEPEND="virtual/pkgconfig"

src_prepare() {
	default
	eautoreconf
}

src_configure() {
	local myeconfargs=(
		--disable-fuse
		--disable-lzma
		--disable-multithreading
		--disable-static-fuse
		--disable-werror
		$(use_enable lz4)
		--without-libdeflate
		--without-libzstd
		--without-qpl
		--without-selinux
		--without-uuid
		--without-xxhash
		--without-zlib
	)

	econf "${myeconfargs[@]}"
}
