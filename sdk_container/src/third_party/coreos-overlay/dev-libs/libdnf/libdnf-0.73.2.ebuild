# Copyright 2024-2025 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

PYTHON_COMPAT=( python3_{10..13} )

inherit cmake python-single-r1

DESCRIPTION="Library providing simplified C and Python API to libsolv"
HOMEPAGE="https://github.com/rpm-software-management/libdnf"
SRC_URI="https://github.com/rpm-software-management/libdnf/archive/${PV}/${P}.tar.gz"

LICENSE="LGPL-2.1+"
SLOT="0"
KEYWORDS="amd64 arm64"
IUSE="python"
REQUIRED_USE="python? ( ${PYTHON_REQUIRED_USE} )"

RESTRICT="test"

RDEPEND="
	>=app-arch/rpm-4.14.0
	dev-db/sqlite:3
	dev-libs/glib:2
	dev-libs/json-c
	dev-libs/libsolv[rpm]
	>=net-libs/librepo-1.15.0
	>=sys-libs/libmodulemd-2.0
	net-misc/curl
	sys-libs/zlib
	python? ( ${PYTHON_DEPS} )
"
DEPEND="
	${RDEPEND}
"
BDEPEND="
	sys-devel/gettext
	virtual/pkgconfig
"

src_prepare() {
	# Fix CMake policy errors by removing old policy settings
	sed -i '/cmake_policy(SET CMP0005 OLD)/d' CMakeLists.txt || die
	
	# Remove check (test framework) dependency since we disable tests
	sed -i '/pkg_check_modules.*check/d' CMakeLists.txt || die
	
	# Don't process tests directory to avoid cppunit dependency
	sed -i -E '/ADD_SUBDIRECTORY.*(tests|Tests)/Id' CMakeLists.txt || die
	sed -i -E '/ENABLE_TESTING/Id' CMakeLists.txt || die
	
	# Also disable Python bindings tests
	sed -i -E '/ADD_SUBDIRECTORY.*(tests|Tests)/Id' python/hawkey/CMakeLists.txt || die
	
	# Fix quote escaping in defines - replace escaped quotes with simple quotes
	sed -i 's/\\"\\\\\\"\\"libdnf\\\\\\"\\"/"libdnf"/g' libdnf/CMakeLists.txt || die
	sed -i 's/add_definitions.*GETTEXT_DOMAIN/#&/' libdnf/CMakeLists.txt || die
	sed -i 's/add_definitions.*G_LOG_DOMAIN/#&/' libdnf/CMakeLists.txt || die
	
	cmake_src_prepare
}

src_configure() {
	# Fix quote escaping issues by setting defines directly in compiler flags
	export CXXFLAGS="${CXXFLAGS} -DG_LOG_DOMAIN=\\\"libdnf\\\" -DGETTEXT_DOMAIN=\\\"libdnf\\\""
	
	local mycmakeargs=(
		-DWITH_GTKDOC=OFF
		-DWITH_HTML=OFF
		-DWITH_MAN=OFF
		-DWITH_ZCHUNK=OFF
		-DWITH_BINDINGS=$(usex python ON OFF)
		-DPYTHON_DESIRED=3
	)
	cmake_src_configure
}

src_install() {
	cmake_src_install
	
	if use python; then
		python_optimize
	fi
}
