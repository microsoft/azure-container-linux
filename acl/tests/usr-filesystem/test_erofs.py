"""EROFS build safety tests; privileged filesystem coverage is separate."""
import argparse
import contextlib
import copy
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
loader = importlib.machinery.SourceFileLoader("disk_util", str(ROOT / "build_library" / "disk_util"))
spec = importlib.util.spec_from_loader(loader.name, loader)
disk = importlib.util.module_from_spec(spec)
loader.exec_module(disk)


class ErofsImageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.packed = self.directory / "usr.erofs"
        image = bytearray(4096)
        struct.pack_into("<I", image, 1024, 0xE0F5E1E2)
        image[1024 + 12] = 12
        struct.pack_into("<I", image, 1024 + 36, 1)
        self.packed.write_bytes(image)
        self.image = self.directory / "disk.bin"
        self.original = b"A" * 4096 + b"B" * 8192 + b"C" * 4096
        self.image.write_bytes(self.original)

    def test_bounded_copy_preserves_neighbors_and_zeroes_entire_padding(self):
        disk.CopyErofsPartition(str(self.packed), str(self.image), 4096, 8192)
        result = self.image.read_bytes()
        self.assertEqual(result[:4096], b"A" * 4096)
        self.assertEqual(result[4096:8192], self.packed.read_bytes())
        self.assertEqual(result[8192:12288], bytes(4096))
        self.assertEqual(result[12288:], b"C" * 4096)
        self.assertEqual(len(result), len(self.original))

    def test_invalid_bounds_never_modify_destination(self):
        for offset, capacity in ((-4096, 8192), (1, 8192), (4096, 8193),
                                 (12288, 8192), (4096, 0)):
            with self.subTest(offset=offset, capacity=capacity):
                with self.assertRaises(disk.InvalidLayout):
                    disk.CopyErofsPartition(str(self.packed), str(self.image), offset, capacity)
                self.assertEqual(self.image.read_bytes(), self.original)

    def test_overflow_never_modifies_destination(self):
        with self.packed.open("ab") as output:
            output.write(bytes(8192))
        with self.assertRaisesRegex(disk.InvalidLayout, "does not fit"):
            disk.CopyErofsPartition(str(self.packed), str(self.image), 4096, 8192)
        self.assertEqual(self.image.read_bytes(), self.original)

    def test_rejects_external_device_and_new_incompat_features(self):
        original = self.packed.read_bytes()
        for field, fmt, value in ((86, "<H", 1), (80, "<I", 1),
                                  (80, "<I", 8), (80, "<I", 32)):
            with self.subTest(field=field, value=value):
                data = bytearray(original)
                struct.pack_into(fmt, data, 1024 + field, value)
                self.packed.write_bytes(data)
                with self.assertRaises(disk.InvalidLayout):
                    disk.CopyErofsPartition(str(self.packed), str(self.image), 4096, 8192)
                self.assertEqual(self.image.read_bytes(), self.original)

    def test_rejects_inconsistent_superblock_size(self):
        data = bytearray(self.packed.read_bytes())
        struct.pack_into("<I", data, 1024 + 36, 2)
        self.packed.write_bytes(data)
        with self.assertRaisesRegex(disk.InvalidLayout, "superblock size"):
            disk.ValidateErofsImage(self.packed, 8192)

    def test_rejects_large_blocks_on_either_architecture(self):
        data = bytearray(self.packed.read_bytes())
        data[1024 + 12] = 16
        self.packed.write_bytes(data)
        with self.assertRaisesRegex(disk.InvalidLayout, "4096-byte"):
            disk.ValidateErofsImage(self.packed, 8192)

    def test_rejects_destination_as_source(self):
        with self.assertRaisesRegex(disk.InvalidLayout, "destination"):
            disk.CopyErofsPartition(str(self.packed), str(self.packed), 0, 4096)

    def test_volume_label_validation_is_byte_bounded(self):
        self.assertEqual(disk.ErofsVolumeLabel({}), "")
        for label in ("", "acl-usr", "x" * 16, "\u00e9" * 8):
            self.assertEqual(disk.ErofsVolumeLabel({"fs_label": label}), label)
        for label in (None, 1, "x" * 17, "\u00e9" * 9, "bad\0label"):
            with self.subTest(label=label), self.assertRaises(disk.InvalidLayout):
                disk.ErofsVolumeLabel({"fs_label": label})

    def test_packed_volume_label_must_match_before_copy(self):
        disk.ValidateErofsImage(self.packed, 8192, expected_label="")
        with self.assertRaisesRegex(disk.InvalidLayout, "label"):
            disk.ValidateErofsImage(self.packed, 8192, expected_label="acl-usr")
        for label in ("acl-usr", "x" * 16, "\u00e9" * 8):
            data = bytearray(self.packed.read_bytes())
            data[1088:1104] = label.encode("utf-8").ljust(16, b"\0")
            self.packed.write_bytes(data)
            disk.ValidateErofsImage(self.packed, 8192, expected_label=label)

    def test_staging_capacity_is_not_the_target_partition_capacity(self):
        staging = Path(disk.ErofsStagingPath(self.image))
        staging.mkdir()
        with (staging / "payload").open("wb") as payload:
            payload.truncate(32768)
        self.assertGreater((staging / "payload").stat().st_size, 8192)
        self.assertEqual(self.image.read_bytes(), self.original)

    def test_writable_mount_rejected_before_any_mount(self):
        parts = {
            "7": dict(fs_type="ext4", image_fs_type="ext4", mount="/", image_exists=True),
            "2": dict(fs_type="erofs", image_fs_type="erofs", mount="/usr", image_exists=True),
        }
        options = argparse.Namespace(disk_image=str(self.image), mount_dir=str(self.directory / "root"),
                                     writable_verity=True, read_only=False, erofs_staging=False)
        with patch.object(disk, "LoadPartitionConfig", return_value=({}, parts)), \
                patch.object(disk, "GetPartitionTableFromImage"), patch.object(disk, "Sudo") as sudo:
            with self.assertRaisesRegex(disk.InvalidLayout, "cannot be mounted writable"):
                disk.Mount(options)
            sudo.assert_not_called()

    def test_resize_rejected_before_gpt_write(self):
        parts = {"2": dict(fs_type="erofs", image_fs_type="erofs", first_byte=4096,
                           image_first_byte=4096, bytes=16384, image_bytes=8192)}
        with patch.object(disk, "LoadPartitionConfig", return_value=({}, parts)), \
                patch.object(disk, "GetPartitionTableFromImage"), \
                patch.object(disk, "WritePartitionTable") as write:
            with self.assertRaisesRegex(disk.InvalidLayout, "Cannot resize"):
                disk.Update(argparse.Namespace())
            write.assert_not_called()

    def test_known_formatter_version_and_usage_status_are_required(self):
        with patch.object(disk.subprocess, "run") as run, \
                patch.object(disk.subprocess, "check_output", return_value="fsck.erofs 1.7.1\n"):
            run.return_value = subprocess.CompletedProcess([], 1, "mkfs.erofs 1.7.1\n", "usage")
            disk.CheckErofsTools()
            for code, version in ((0, "1.7.1"), (1, "1.6"), (1, "1.8")):
                run.return_value = subprocess.CompletedProcess([], code, f"mkfs.erofs {version}\n", "")
                with self.assertRaisesRegex(disk.InvalidLayout, "SDK-pinned"):
                    disk.CheckErofsTools()


class ErofsKernelTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("bash"), "requires Bash")
    def test_target_kernel_features_are_required(self):
        source = ROOT / "build_library" / "rpm" / "dracut_install.sh"
        valid = ["CONFIG_EROFS_FS=m", "CONFIG_EROFS_FS_XATTR=y",
                 "CONFIG_EROFS_FS_POSIX_ACL=y", "CONFIG_EROFS_FS_SECURITY=y",
                 "CONFIG_EROFS_FS_ZIP=y"]
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config"
            script = (f"source '{source.as_posix()}'\n"
                      "die() { printf '%s\\n' \"$*\" >&2; exit 1; }\n"
                      "validate_erofs_kernel_config \"$1\"\n")
            for removed in (None, *valid):
                config.write_text("\n".join(line for line in valid if line != removed) + "\n")
                result = subprocess.run(["bash", "-s", "--", config.as_posix()], input=script,
                                        text=True, capture_output=True)
                with self.subTest(removed=removed):
                    self.assertEqual(result.returncode == 0, removed is None, result.stderr)
            config.write_text("\n".join(valid).replace("CONFIG_EROFS_FS=m", "CONFIG_EROFS_FS=y"))
            subprocess.run(["bash", "-s", "--", config.as_posix()], input=script,
                           text=True, check=True)


class ErofsSelectionTests(unittest.TestCase):
    def setUp(self):
        environment = patch.dict(os.environ, {
            "ACL_EXPERIMENTAL_USR_FS": "erofs", "PACKAGE_SOURCE_MODE": "RPM",
            "BOOTLOADER_MODE": "uki", "COREOS_OFFICIAL": "0",
        })
        environment.start()
        self.addCleanup(environment.stop)

    def layout(self, layout="base", arch="x86_64"):
        return disk.LoadPartitionConfig(argparse.Namespace(
            disk_layout_file=str(ROOT / "build_library" / "disk_layout_uki.json"),
            disk_layout=layout, arch=arch))

    def staged_parts(self):
        _, parts = self.layout()
        for part in parts.values():
            part.update(image_compat=True, image_exists=True,
                        image_fs_type=part.get("fs_type"))
        parts["2"]["image_fs_type"] = None
        return parts

    def test_erofs_preserves_base_geometry_on_both_architectures(self):
        for arch in ("x86_64", "aarch64"):
            for layout in ("base", "vm", "azure"):
                with self.subTest(arch=arch, layout=layout):
                    config, parts = self.layout(layout, arch)
                    with patch.dict(os.environ, {"ACL_EXPERIMENTAL_USR_FS": "btrfs"}):
                        baseline, original = self.layout(layout, arch)
                    self.assertEqual(config["metadata"]["bytes"], baseline["metadata"]["bytes"])
                    for number, part in parts.items():
                        self.assertEqual((part["first_byte"], part["bytes"]),
                                         (original[number]["first_byte"], original[number]["bytes"]))
                    self.assertEqual(parts["2"]["fs_type"], "erofs")
                    self.assertNotIn("fs_compression", parts["2"])
                    self.assertNotIn("fs_subvolume", parts["2"])
                    self.assertNotIn("fs_type", parts["4"])
                    self.assertEqual(parts["6"]["fs_type"], "btrfs")
                    self.assertEqual(parts["7"]["fs_type"], "ext4")

    def test_empty_usr_is_allowed_only_for_explicit_staging(self):
        parts = self.staged_parts()
        with self.assertRaises(disk.InvalidLayout):
            disk.ValidateUsrPartitions(parts)
        disk.ValidateUsrPartitions(parts, allow_erofs_staging=True)
        for change in ("geometry", "btrfs", "inactive"):
            parts = self.staged_parts()
            if change == "geometry":
                parts["3"]["image_compat"] = False
            elif change == "btrfs":
                parts["2"]["image_fs_type"] = "btrfs"
            else:
                parts["4"].update(fs_type="erofs", image_fs_type=None)
            with self.subTest(change=change), self.assertRaises(disk.InvalidLayout):
                disk.ValidateUsrPartitions(parts, allow_erofs_staging=True)

    def test_erofs_runs_shared_block_and_slot_validation_before_layout_changes(self):
        original = json.loads((ROOT / "build_library" / "disk_layout_uki.json").read_text())
        for kind in ("sector-size", "filesystem-block-size", "wrong-active-hash",
                     "wrong-inactive-hash", "missing-inactive-hash"):
            config = copy.deepcopy(original)
            if kind == "sector-size":
                config["metadata"]["block_size"] = 4096
            elif kind == "filesystem-block-size":
                config["metadata"]["fs_block_size"] = 1024
            elif kind == "wrong-active-hash":
                config["layouts"]["base"]["2"]["verity_hash"] = "5"
            elif kind == "wrong-inactive-hash":
                config["layouts"]["base"]["4"]["verity_hash"] = "3"
            else:
                config["layouts"]["base"]["4"].pop("verity_hash")
            before = copy.deepcopy(config)
            with self.subTest(kind=kind), self.assertRaises(disk.InvalidLayout):
                disk.ApplyExperimentalUsrLayout(config)
            self.assertEqual(config, before)

    def test_staging_format_rejects_existing_image_before_writes(self):
        _, parts = self.layout()
        with patch.object(disk, "LoadPartitionConfig", return_value=({}, parts)), \
                patch.object(disk, "WritePartitionTable") as write:
            with self.assertRaisesRegex(disk.InvalidLayout, "new image"):
                disk.Format(argparse.Namespace(create=False, erofs_staging=True))
            write.assert_not_called()

    def test_invalid_volume_label_rejected_before_format_writes(self):
        _, parts = self.layout()
        parts["2"]["fs_label"] = "x" * 17
        with patch.object(disk, "LoadPartitionConfig", return_value=({}, parts)), \
                patch.object(disk, "WritePartitionTable") as write:
            with self.assertRaisesRegex(disk.InvalidLayout, "fs_label"):
                disk.Format(argparse.Namespace(create=True, erofs_staging=True))
            write.assert_not_called()

    def test_failed_probe_is_not_treated_as_an_empty_staging_partition(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / "disk.bin"
            with image.open("wb") as stream:
                stream.truncate(3 * 1024**2)
            for code in (1, 2, 4, 32):
                part = dict(label="USR-A", type="flatcar-rootfs", fs_type="erofs",
                            first_block=2048, first_byte=1024**2, blocks=2048,
                            bytes=1024**2)
                with self.subTest(code=code), \
                        patch.object(disk.subprocess, "check_output", side_effect=[
                            b"2048 2048 2 usr\n", subprocess.CalledProcessError(code, "blkid")]), \
                        patch.object(disk, "PartitionLoop",
                                     return_value=contextlib.nullcontext("/dev/example")):
                    arguments = (argparse.Namespace(disk_image=str(image)),
                                 {"metadata": {"block_size": 512}}, {"2": part})
                    if code == 2:
                        disk.GetPartitionTableFromImage(*arguments)
                        self.assertIsNone(part["image_fs_type"])
                    else:
                        with self.assertRaises(subprocess.CalledProcessError):
                            disk.GetPartitionTableFromImage(*arguments)

    def test_unsealed_staging_cannot_be_hashed(self):
        parts = self.staged_parts()
        with patch.object(disk, "LoadPartitionConfig", return_value=({}, parts)), \
                patch.object(disk, "GetPartitionTableFromImage"), \
                patch.object(disk, "Sudo") as command:
            with self.assertRaises(disk.InvalidLayout):
                disk.Verity(argparse.Namespace())
            command.assert_not_called()

    def test_hash_capacity_checked_before_packing_or_writing(self):
        parts = self.staged_parts()
        parts["3"]["bytes"] = 4096
        with patch.object(disk, "LoadPartitionConfig", return_value=({}, parts)), \
                patch.object(disk, "GetPartitionTableFromImage"), \
                patch.object(disk, "Sudo") as command:
            with self.assertRaises(disk.InvalidLayout):
                disk.SealErofs(argparse.Namespace())
            command.assert_not_called()

    @unittest.skipUnless(shutil.which("bash"), "requires Bash")
    def test_shared_selector_and_mount_contract(self):
        source = ROOT / "build_library" / "usr_filesystem.sh"
        result = subprocess.run(
            ["bash", "-s"], input=f"source '{source.as_posix()}'\n"
            "acl_validate_usr_filesystem || exit 1\n"
            "acl_usr_filesystem\nacl_usr_mount_options\n", text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["erofs", "ro"])


if __name__ == "__main__":
    unittest.main()
