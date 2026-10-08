#!/usr/bin/env python3

import pathlib
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[2] / "build_library/rpm/sysext/sysext_mangle_artifact-streaming"


class ArtifactStreamingLayoutTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        for name in ("bin/acr", "bin/acr-config", "tools/overlaybd/install.sh", "tools/mirror/setup.sh"):
            path = self.root / "opt/acr" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("#!/bin/sh\nexit 0\n")
            path.chmod(0o755)
        for unit in ("acr-mirror", "overlaybd-tcmu", "overlaybd-snapshotter"):
            path = self.root / "usr/lib/systemd/system" / (unit + ".service")
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("[Service]\nExecStart=/opt/acr/bin/acr\n")

    def relocate(self):
        return subprocess.run(
            ["bash", "-c", 'source "$1"; relocate_artifact_streaming "$2"', "test", str(SCRIPT), str(self.root)],
            capture_output=True, text=True,
        )

    def test_payload_is_immutable_but_runtime_paths_are_created_later(self):
        result = self.relocate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "opt/acr").exists())
        self.assertTrue((self.root / "usr/libexec/artifact-streaming/acr/bin/acr").is_file())
        self.assertEqual(
            (self.root / "usr/lib/tmpfiles.d/artifact-streaming.conf").read_text(),
            "L /opt/acr - - - - /usr/libexec/artifact-streaming/acr\n",
        )
        self.assertFalse((self.root / "etc/systemd/system/multi-user.target.wants/acr-mirror.service").exists())

    def test_missing_dependency_does_not_make_a_partial_extension(self):
        (self.root / "usr/lib/systemd/system/overlaybd-tcmu.service").unlink()
        result = self.relocate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing streaming service overlaybd-tcmu.service", result.stderr)
        self.assertTrue((self.root / "opt/acr/bin/acr").is_file())

    def test_incomplete_mirror_payload_is_rejected(self):
        (self.root / "opt/acr/tools/overlaybd/install.sh").unlink()
        result = self.relocate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Incomplete ACR Mirror payload", result.stderr)

    def test_existing_payload_is_not_overwritten(self):
        (self.root / "usr/libexec/artifact-streaming/acr").mkdir(parents=True)
        result = self.relocate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to overwrite", result.stderr)

    def test_vendor_checksum_failure_prevents_rpm_install(self):
        result = subprocess.run(
            ["bash", "-c", r'''
source "$1"
rpm() {
    if [[ "$*" == *"--query"* ]]; then printf x86_64; else echo UNEXPECTED_RPM_INSTALL; fi
}
curl() {
    printf wrong-payload > "${@: -1}"
}
install_acr_mirror "$2"
''', "test", str(SCRIPT), str(self.root)],
            capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("UNEXPECTED_RPM_INSTALL", result.stdout)

    def test_unsupported_architecture_does_not_download(self):
        result = subprocess.run(
            ["bash", "-c", r'''
source "$1"
rpm() { printf unsupported; }
curl() { echo UNEXPECTED_DOWNLOAD; }
install_acr_mirror "$2"
''', "test", str(SCRIPT), str(self.root)],
            capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unsupported artifact-streaming architecture", result.stderr)
        self.assertNotIn("UNEXPECTED_DOWNLOAD", result.stdout)


if __name__ == "__main__":
    unittest.main()
