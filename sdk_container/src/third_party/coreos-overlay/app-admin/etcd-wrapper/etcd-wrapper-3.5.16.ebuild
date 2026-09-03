# Copyright (c) 2016 CoreOS, Inc.. All rights reserved.
# Distributed under the terms of the GNU General Public License v2

EAPI=8

inherit systemd tmpfiles

DESCRIPTION="etcd (System Application Container)"
HOMEPAGE="https://github.com/etcd-io/etcd"
S="${WORKDIR}"
LICENSE="Apache-2.0"
SLOT="0"
KEYWORDS="amd64 arm64"

RDEPEND=">=app-admin/sdnotify-proxy-0.1.0"

src_install() {
	# MCR publishes a single multi-arch index per version; no per-arch tag suffix.
	local tag="v${PV}"

	exeinto /usr/lib/flatcar
	doexe "${FILESDIR}"/etcd-wrapper

	sed "s|@ETCD_IMAGE_TAG@|${tag}|g" \
		"${FILESDIR}"/etcd-member.service > "${T}"/etcd-member.service
	systemd_dounit "${T}"/etcd-member.service
	dotmpfiles "${FILESDIR}"/etcd-wrapper.conf
}
