# Copyright 2024-2025 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

PYTHON_COMPAT=( python3_{10..13} )

inherit cmake python-single-r1

DESCRIPTION="DNF package manager (Python version)"
HOMEPAGE="https://github.com/rpm-software-management/dnf"
SRC_URI="https://github.com/rpm-software-management/dnf/archive/${PV}/${P}.tar.gz"

LICENSE="GPL-2"
SLOT="0"
KEYWORDS="amd64 arm64"
IUSE="test"
REQUIRED_USE="${PYTHON_REQUIRED_USE}"

RESTRICT="!test? ( test )"

RDEPEND="
	${PYTHON_DEPS}
	>=app-arch/rpm-4.14.0[python]
	>=dev-libs/libdnf-0.73.0[python]
"
DEPEND="
	${RDEPEND}
"
BDEPEND="
	sys-devel/gettext
	virtual/pkgconfig
"

src_configure() {
	local mycmakeargs=(
		-DPYTHON_DESIRED=3
		-DWITH_MAN=OFF
	)
	cmake_src_configure
}

src_install() {
	# Skip doc installation by modifying cmake_install.cmake
	sed -i '/include.*doc.*cmake_install.cmake/d' "${BUILD_DIR}/cmake_install.cmake" || die
	
	cmake_src_install
	
	# Fix shebang lines to use system Python instead of build-time temp Python
	python_fix_shebang "${ED}/usr/bin"
	
	python_optimize
	
	# Create DNF directories
	keepdir /etc/dnf/vars
	keepdir /etc/dnf/aliases.d
	keepdir /etc/dnf/plugins
	keepdir /etc/dnf/modules.d
	keepdir /etc/dnf/modules.defaults.d
	keepdir /etc/dnf/protected.d
	
	keepdir /var/log
	keepdir /var/lib/dnf
	keepdir /var/lib/dnf/yumdb
	keepdir /var/lib/dnf/history
	
	# Create log files
	touch "${ED}"/var/log/dnf.log || die
	touch "${ED}"/var/log/dnf.librepo.log || die
	touch "${ED}"/var/log/dnf.rpm.log || die
	touch "${ED}"/var/log/dnf.plugin.log || die
	
	# Create plugin directory
	keepdir /usr/lib/python*/site-packages/dnf-plugins
}

pkg_postinst() {
	elog "DNF is a package manager for RPM packages."
	elog "Configuration files are in /etc/dnf/"
}
