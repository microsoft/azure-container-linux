# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

EAPI=7

inherit autotools

DESCRIPTION="EROFS image creation and verification tools for the ACL SDK"
HOMEPAGE="https://erofs.docs.kernel.org/"
SRC_URI="https://git.kernel.org/pub/scm/linux/kernel/git/xiang/${PN}.git/snapshot/${P}.tar.gz"

LICENSE="GPL-2+"
SLOT="0"
KEYWORDS="amd64 arm64"

DEPEND="
	>=app-arch/lz4-1.9:=
	sys-apps/util-linux
"
RDEPEND="${DEPEND}"
BDEPEND="virtual/pkgconfig"

src_prepare() {
	default
	eautoreconf
}

src_configure() {
	econf --enable-lz4 --disable-lzma --disable-fuse --without-zlib --without-libdeflate
}

src_test() {
	mkdir "${T}/input" || die
	printf '%131072s\n' 'EROFS SDK LZ4 round trip' > "${T}/input/payload" || die
	./mkfs/mkfs.erofs -b4096 -zlz4hc,12 -Elegacy-compress \
		-U 11111111-2222-3333-4444-555555555555 \
		"${T}/test.erofs" "${T}/input" || die
	./fsck/fsck.erofs --extract="${T}/output" "${T}/test.erofs" || die
	cmp "${T}/input/payload" "${T}/output/payload" || die
}
