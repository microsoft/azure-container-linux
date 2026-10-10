#!/usr/bin/env python3
"""Validate the checked-in experimental kernel package and source fingerprints."""
import hashlib
import json
from pathlib import Path
import re
import unittest

ACL = Path(__file__).resolve().parents[3]
KERNEL = ACL / "SPECS/kernel"


class KernelSpecTests(unittest.TestCase):
    def test_version_and_patch_are_declared(self):
        metadata = json.loads((KERNEL / "source.json").read_text())
        spec = (KERNEL / "kernel.spec").read_text()
        self.assertIn(f'Version:        {metadata["version"]}\n', spec)
        self.assertIn(f'Release:        {metadata["release"]}%{{?dist}}\n', spec)
        self.assertIn("Patch0:         0001-add-mstflint-kernel-%{mstflintver}.patch\n", spec)
        self.assertEqual(spec.count("Patch1:         btrfs-ipe.patch\n"), 1)
        self.assertIn("%autosetup -p1", spec)
        self.assertTrue((KERNEL / "0001-add-mstflint-kernel-4.28.0.patch").is_file())

    def test_checked_in_source_checksums(self):
        metadata = json.loads((KERNEL / "source.json").read_text())
        signatures = json.loads((KERNEL / "kernel.signatures.json").read_text())["Signatures"]
        remote = f'kernel-{metadata["version"]}.tar.gz'
        self.assertIn(remote, signatures)
        for name in ("config", "config_aarch64", "btrfs-ipe.patch",
                     "azurelinux-ca-20230216.pem", "sha512hmac-openssl.sh",
                     "cpupower", "cpupower.service"):
            with self.subTest(source=name):
                data = (KERNEL / name).read_bytes()
                self.assertEqual(hashlib.sha256(data).hexdigest(), signatures[name])
        self.assertEqual(set(signatures), {
            remote, "config", "config_aarch64", "btrfs-ipe.patch",
            "azurelinux-ca-20230216.pem", "sha512hmac-openssl.sh",
            "cpupower", "cpupower.service",
        })

    def test_kernel_is_not_a_default_package(self):
        packages = re.findall(r"^\s+-\s+(\S+)", (ACL / "packages.yaml").read_text(), re.M)
        self.assertIn("coreos-init", packages)
        self.assertNotIn("kernel", packages)

    def test_sdk_preserves_explicit_kernel_opt_in(self):
        root = ACL.parent
        container = (root / "run_sdk_container").read_text()
        entry = (root / "sdk_lib/sdk_entry.sh").read_text()
        self.assertIn('-e ACL_BTRFS_IPE_KERNEL="${ACL_BTRFS_IPE_KERNEL:-0}"', container)
        self.assertIn('case "${ACL_BTRFS_IPE_KERNEL:-0}" in', entry)
        self.assertIn('/^export ACL_BTRFS_IPE_KERNEL=/d', entry)
        self.assertIn('>> /home/sdk/.bashrc', entry)


if __name__ == "__main__":
    unittest.main()
