#!/usr/bin/env python3
"""Fail-closed tests for the experimental kernel spec override."""
import importlib.util
from pathlib import Path
import unittest

PATH = Path(__file__).resolve().parents[3] / "kernel/btrfs-ipe/prepare-kernel.py"
spec = importlib.util.spec_from_file_location("prepare_kernel", PATH)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
BASE = """Version:        6.6.157.1
Release:        1%{?dist}
Patch0:         existing.patch
BuildRequires:  audit-devel
%prep
%autosetup -p1
"""


class RenderTests(unittest.TestCase):
    def test_preserves_vendor_patch_and_applies_candidate(self):
        result = module.render_spec(BASE, "6.6.157.1", "1.btrfsipe1")
        self.assertIn("Release:        1.btrfsipe1%{?dist}\n", result)
        self.assertIn("Patch0:         existing.patch\n", result)
        self.assertEqual(result.count("Patch1:         btrfs-ipe.patch\n"), 1)
        self.assertIn("%autosetup -p1", result)

    def test_rejects_changed_or_duplicate_upstream_layout(self):
        for old, new in (
            ("6.6.157.1", "6.6.158.1"),
            ("Release:        1", "Release:        2"),
            ("BuildRequires:  audit-devel", "BuildRequires:  other"),
            ("Patch0:", "Patch1:"),
            ("%autosetup -p1", "%setup"),
            ("%prep", "%prep\n%prep"),
        ):
            with self.subTest(old=old):
                with self.assertRaises(ValueError):
                    module.render_spec(BASE.replace(old, new), "6.6.157.1", "1.btrfsipe1")


if __name__ == "__main__":
    unittest.main()
