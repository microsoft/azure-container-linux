"""Privileged SDK tests. Opt in with ACL_RUN_PRIVILEGED_FS_TESTS=1."""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from test_erofs import ROOT, disk


@unittest.skipUnless(os.environ.get("ACL_RUN_PRIVILEGED_FS_TESTS") == "1",
                     "requires explicit privileged SDK test opt-in")
class ErofsSdkIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.assertEqual(platform.system(), "Linux", "run inside the Linux ACL SDK")
        self.assertEqual(os.geteuid(), 0, "mount/loop/metadata checks require root")
        for command in ("cgpt", "sudo", "mkfs.erofs", "fsck.erofs", "veritysetup", "setcap"):
            self.assertIsNotNone(shutil.which(command), f"SDK is missing {command}")
        disk.CheckErofsTools()
        environment = patch.dict(os.environ, {
            "ACL_EXPERIMENTAL_USR_FS": "erofs", "PACKAGE_SOURCE_MODE": "RPM",
            "BOOTLOADER_MODE": "uki", "COREOS_OFFICIAL": "0",
        })
        environment.start()
        self.addCleanup(environment.stop)
        self.directory = Path(tempfile.mkdtemp(prefix="acl-erofs-test-"))
        self.image = self.directory / "disk.bin"
        self.root = self.directory / "root"
        self.root.mkdir()
        layout = json.loads((ROOT / "build_library" / "disk_layout_uki.json").read_text())
        base = layout["layouts"]["base"]
        base["2"]["fs_label"] = "acl-erofs-test"
        for number in ("2", "4"):
            base[number]["blocks"] = 8192
            base[number]["fs_blocks"] = 1024
        for number in ("3", "5"):
            base[number]["blocks"] = 4096
        base["7"]["blocks"] = 131072
        layout["layouts"] = {"base": base}
        config = self.directory / "layout.json"
        config.write_text(json.dumps(layout))
        self.options = argparse.Namespace(
            disk_layout_file=str(config), disk_layout="base", arch="x86_64",
            disk_image=str(self.image), erofs_staging=True,
            create=True, mount_dir=str(self.root), writable_verity=True,
            read_only=False, source=str(self.root / "usr"),
            root_hash=str(self.directory / "root.hash"),
            verity_uuid=str(self.directory / "verity.uuid"),
            fs_uuid=str(self.directory / "fs.uuid"),
            capacity_report=str(self.directory / "capacity.json"),
        )
        self.mounted = False
        self.addCleanup(self.cleanup_image)
        disk.Format(self.options)
        self.mounted = True
        disk.Mount(self.options)

    def cleanup_image(self):
        if self.mounted:
            disk.Umount(self.options)
        shutil.rmtree(self.directory)

    def test_full_staging_larger_than_slot_preserves_metadata_and_verity(self):
        usr = self.root / "usr"
        binary = usr / "payload"
        binary.write_bytes(b"EROFS full staging test\n" * 400000)
        binary.chmod(0o751)
        os.chown(binary, 123, 456)
        os.setxattr(binary, "user.acl-erofs-test", b"metadata preserved")
        subprocess.run(["setcap", "cap_net_bind_service=ep", str(binary)], check=True)
        (usr / "payload-link").hardlink_to(binary)
        (usr / "payload-symlink").symlink_to("payload")
        expected_xattrs = {name: os.getxattr(binary, name) for name in os.listxattr(binary)}
        expected_stat = binary.stat()
        self.assertGreater(expected_stat.st_size, 4 * 1024 * 1024)
        _, parts = disk.LoadPartitionConfig(self.options)
        part = disk.GetPartition(parts, "USR-A")
        with self.image.open("rb") as image:
            image.seek(part["first_byte"] - 4096)
            before = image.read(4096)
            image.seek(part["first_byte"] + part["bytes"])
            after = image.read(4096)

        disk.SealErofs(self.options)
        with self.image.open("rb") as image:
            image.seek(part["first_byte"] - 4096)
            self.assertEqual(image.read(4096), before)
            image.seek(part["first_byte"] + part["bytes"])
            self.assertEqual(image.read(4096), after)
        self.assertFalse(Path(disk.ErofsStagingPath(self.image)).exists())
        disk.Verity(self.options)
        with disk.PartitionLoop(self.options, parts["2"]) as data, \
                disk.PartitionLoop(self.options, parts["3"]) as hashes:
            label = subprocess.check_output(
                ["blkid", "-p", "-s", "LABEL", "-o", "value", data], text=True).strip()
            self.assertEqual(label, "acl-erofs-test")
            subprocess.run(["veritysetup", "verify", data, hashes,
                            Path(self.options.root_hash).read_text().strip()], check=True)
        disk.Umount(self.options)
        self.mounted = False
        self.options.erofs_staging = False
        self.options.read_only = True
        self.options.writable_verity = False
        self.mounted = True
        disk.Mount(self.options)
        actual_stat = binary.stat()
        self.assertEqual((actual_stat.st_uid, actual_stat.st_gid, stat.S_IMODE(actual_stat.st_mode)),
                         (123, 456, 0o751))
        self.assertEqual(actual_stat.st_ino, (usr / "payload-link").stat().st_ino)
        self.assertEqual(os.readlink(usr / "payload-symlink"), "payload")
        self.assertEqual({name: os.getxattr(binary, name) for name in os.listxattr(binary)},
                         expected_xattrs)
        self.assertEqual(binary.read_bytes(), b"EROFS full staging test\n" * 400000)
        with self.assertRaises(OSError):
            (usr / "must-not-write").write_text("read-only")
        report = json.loads(Path(str(self.image) + ".erofs.json").read_text())
        self.assertEqual(report["uuid"], Path(self.options.fs_uuid).read_text().strip())
        self.assertEqual(report["label"], "acl-erofs-test")
        self.assertLess(report["packedBytes"], report["dataBytes"])

    def test_incompressible_overflow_keeps_target_partition_unchanged(self):
        _, parts = disk.LoadPartitionConfig(self.options)
        part = disk.GetPartition(parts, "USR-A")
        (self.root / "usr" / "incompressible").write_bytes(os.urandom(8 * 1024 * 1024))
        with self.image.open("rb") as image:
            image.seek(part["first_byte"])
            before = image.read(part["bytes"])
        with self.assertRaisesRegex(disk.InvalidLayout, "does not fit"):
            disk.SealErofs(self.options)
        with self.image.open("rb") as image:
            image.seek(part["first_byte"])
            self.assertEqual(image.read(part["bytes"]), before)


if __name__ == "__main__":
    unittest.main()
