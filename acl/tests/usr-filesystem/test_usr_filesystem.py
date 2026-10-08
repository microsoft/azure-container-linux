import contextlib
import copy
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[3]
loader = importlib.machinery.SourceFileLoader("disk_util", str(REPO / "build_library/disk_util"))
DISK = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(DISK)
ENV = {"ACL_EXPERIMENTAL_USR_FS": "ext4", "PACKAGE_SOURCE_MODE": "RPM",
       "BOOTLOADER_MODE": "uki", "COREOS_OFFICIAL": "0"}


class FilesystemTests(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ, ENV)
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def layout(self, name="base", arch="x86_64", file="disk_layout_uki.json"):
        return DISK.LoadPartitionConfig(SimpleNamespace(
            disk_layout=name, arch=arch, disk_layout_file=str(REPO / "build_library" / file)))

    def shell(self, code, args=(), **overrides):
        env = dict(os.environ, USR_FS_HELPER=str(REPO / "build_library/usr_filesystem.sh"))
        for key, value in overrides.items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = value
        return subprocess.run(
            [os.environ.get("BASH", "bash"), "-s", "--", *args],
            input='source "$USR_FS_HELPER" || exit 1\n' + code,
            env=env, text=True, capture_output=True)

    def image_parts(self, filesystem="ext4"):
        _, parts = self.layout()
        for part in parts.values():
            part.update(image_exists=True, image_compat=True,
                        image_fs_type=part.get("fs_type"),
                        image_bytes=part["bytes"], image_first_byte=part["first_byte"])
        parts["2"]["fs_type"] = parts["2"]["image_fs_type"] = filesystem
        return parts

    def test_btrfs_default_layout_is_unchanged(self):
        for requested in ("", "btrfs"):
            with self.subTest(requested=requested):
                config = json.loads((REPO / "build_library/disk_layout_uki.json").read_text())
                expected = copy.deepcopy(config)
                with patch.dict(os.environ, {"ACL_EXPERIMENTAL_USR_FS": requested}):
                    DISK.ApplyExperimentalUsrLayout(config)
                    _, parts = self.layout()
                self.assertEqual(config, expected)
                self.assertEqual(parts["2"]["fs_type"], "btrfs")
                self.assertEqual(parts["2"]["bytes"], 1024**3)
                self.assertEqual(parts["3"]["bytes"], 10 * 1024**2)

    def test_supported_layouts_and_architectures(self):
        for arch in ("x86_64", "aarch64"):
            for name in ("base", "vm", "azure"):
                with self.subTest(arch=arch, name=name):
                    config, parts = self.layout(name, arch)
                    for number in ("2", "4"):
                        self.assertEqual(parts[number]["bytes"], 4 * 1024**3)
                        self.assertNotIn("fs_compression", parts[number])
                    for number in ("3", "5"):
                        self.assertEqual(parts[number]["bytes"], 64 * 1024**2)
                    self.assertNotIn("fs_type", parts["4"])
                    self.assertEqual(parts["6"]["fs_type"], "btrfs")
                    self.assertEqual(parts["7"]["fs_type"], "ext4")
                    end = DISK.GPT_RESERVED_SECTORS * 512
                    for part in sorted(parts.values(), key=lambda part: part["first_byte"]):
                        self.assertGreaterEqual(part["first_byte"], end)
                        self.assertLessEqual(part["fs_bytes"], part["bytes"])
                        end = part["first_byte"] + part["bytes"]
                    self.assertLessEqual(end + DISK.GPT_RESERVED_SECTORS * 512,
                                         config["metadata"]["bytes"])

    def test_unsupported_build_modes_fail(self):
        for key, value in (("ACL_EXPERIMENTAL_USR_FS", "invalid"),
                           ("PACKAGE_SOURCE_MODE", "PORTAGE"),
                           ("BOOTLOADER_MODE", "grub"), ("COREOS_OFFICIAL", "1")):
            with self.subTest(key=key), patch.dict(os.environ, {key: value}):
                with self.assertRaises(DISK.InvalidLayout):
                    self.layout()
                result = self.shell("acl_validate_usr_filesystem")
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(result.stderr)
        for kwargs in ({"name": "container"}, {"name": "vagrant"},
                       {"arch": "riscv64"}, {"file": "disk_layout.json"}):
            with self.assertRaises(DISK.InvalidLayout):
                self.layout(**kwargs)

    def test_btrfs_preserves_grub_portage_and_official_modes(self):
        with patch.dict(os.environ, {"ACL_EXPERIMENTAL_USR_FS": "btrfs",
                                    "PACKAGE_SOURCE_MODE": "PORTAGE",
                                    "BOOTLOADER_MODE": "grub", "COREOS_OFFICIAL": "1"}):
            _, parts = self.layout(file="disk_layout.json")
            self.assertEqual(parts["3"]["fs_type"], "btrfs")
            result = self.shell("acl_validate_usr_filesystem")
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_invalid_optin_geometry_is_rejected_during_configuration(self):
        original = json.loads((REPO / "build_library/disk_layout_uki.json").read_text())
        for kind in ("block-size", "duplicate", "wrong-hash-slot"):
            config = copy.deepcopy(original)
            if kind == "block-size":
                config["metadata"]["fs_block_size"] = 1024
            elif kind == "duplicate":
                config["layouts"]["base"]["8"] = copy.deepcopy(config["layouts"]["base"]["2"])
            else:
                config["layouts"]["base"]["2"]["verity_hash"] = "5"
            with self.assertRaises(DISK.InvalidLayout):
                DISK.ApplyExperimentalUsrLayout(config)

    def test_checksum_safe_seal_and_unseal(self):
        for readonly in (False, True):
            with patch.object(DISK, "Sudo") as command:
                DISK.SetNativeExt4Readonly("/dev/example", readonly)
            self.assertEqual([call.args[0] for call in command.call_args_list], [
                ["e2fsck", "-fn", "/dev/example"],
                ["tune2fs", "-O", "read-only" if readonly else "^read-only", "/dev/example"],
                ["e2fsck", "-fn", "/dev/example"]])

    def test_fsck_failure_prevents_feature_mutation(self):
        with patch.object(DISK, "Sudo", side_effect=subprocess.CalledProcessError(4, "e2fsck")) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                DISK.SetNativeExt4Readonly("/dev/example", True)
        self.assertEqual(run.call_count, 1)

    def test_native_readonly_is_scoped_to_selected_usr(self):
        self.assertTrue(DISK.NativeExt4Readonly({"label": "USR-A", "fs_type": "ext4"}))
        self.assertFalse(DISK.NativeExt4Readonly({"label": "ROOT", "fs_type": "ext4"}))
        with patch.dict(os.environ, {"ACL_EXPERIMENTAL_USR_FS": ""}):
            self.assertFalse(DISK.NativeExt4Readonly({"label": "USR-A", "fs_type": "ext4"}))

    def test_formatter_preserves_checksums_and_default_commands(self):
        part = {"label": "USR-A", "fs_type": "ext4", "type": "flatcar-rootfs",
                "fs_block_size": 4096, "fs_blocks": 8192}
        with patch.object(DISK, "Sudo") as run:
            DISK.FormatExt(part, "/dev/example")
        self.assertIn("^has_journal,metadata_csum", run.call_args_list[0].args[0])
        self.assertIn("lazy_itable_init=0", run.call_args_list[0].args[0])
        self.assertNotIn("^metadata_csum", " ".join(map(str, run.call_args_list[0].args[0])))
        with patch.dict(os.environ, {"ACL_EXPERIMENTAL_USR_FS": ""}):
            with patch.object(DISK, "Sudo") as run:
                DISK.FormatExt(part, "/dev/example")
        self.assertEqual(run.call_args_list[0].args[0], [
            "mke2fs", "-q", "-t", "ext4", "-b", 4096, "-i", 4096, "-I", 256,
            "/dev/example", 8192])
        self.assertEqual(run.call_args_list[1].args[0],
                         ["tune2fs", "-e", "remount-ro", "/dev/example"])

    def test_native_feature_detection_and_truncation(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / "image"
            image.write_bytes(b"\0" * 4096)
            options = SimpleNamespace(disk_image=str(image))
            part = {"label": "USR-A", "fs_type": "ext4", "first_byte": 0}
            self.assertTrue(DISK.IsE2fsReadWrite(options, part))
            with image.open("r+b") as stream:
                stream.seek(0x464)
                stream.write((0x1000).to_bytes(4, "little"))
            self.assertFalse(DISK.IsE2fsReadWrite(options, part))
            image.write_bytes(b"short")
            with self.assertRaises(DISK.InvalidLayout):
                DISK.IsE2fsReadWrite(options, part)

    def test_hash_capacity_matches_legacy_and_large_layouts(self):
        self.assertEqual(DISK.VerityHashBytes(260094, 4096), 8396800)
        self.assertEqual(DISK.VerityHashBytes(262144, 4096), 8462336)
        self.assertEqual(DISK.VerityHashBytes(1048576, 4096), 33824768)
        self.assertEqual(DISK.VerityHashBytes(1, 4096), 4096)
        for blocks, size in ((0, 4096), (-1, 4096), (1, 0), (10, 1000)):
            with self.assertRaises(DISK.InvalidLayout):
                DISK.VerityHashBytes(blocks, size)
        with patch.dict(os.environ, {"ACL_EXPERIMENTAL_USR_FS": ""}):
            for file in ("disk_layout.json", "disk_layout_uki.json"):
                _, parts = self.layout(file=file)
                for part in parts.values():
                    part["image_compat"] = True
                self.assertEqual(len(DISK.VerityPlan(parts)), 1)

    def test_hash_destinations_and_overflow_fail(self):
        for change in ("missing", "empty", "self", "mounted", "wrong-slot", "overflow", "incompatible"):
            with self.subTest(change=change):
                parts = self.image_parts()
                if change == "missing":
                    parts["2"]["verity_hash"] = "999"
                elif change == "empty":
                    parts["2"]["verity_hash"] = ""
                elif change == "self":
                    parts["2"]["verity_hash"] = "2"
                elif change == "mounted":
                    parts["3"]["mount"] = "/data"
                elif change == "wrong-slot":
                    parts["2"]["verity_hash"] = "5"
                elif change == "overflow":
                    parts["3"]["bytes"] = 4096
                else:
                    parts["3"]["image_compat"] = False
                with self.assertRaises(DISK.InvalidLayout):
                    DISK.VerityPlan(parts)

    def test_incompatible_images_fail_before_writes(self):
        for kind in ("geometry", "filesystem"):
            with self.subTest(kind=kind):
                parts = self.image_parts()
                if kind == "geometry":
                    parts["3"]["image_compat"] = False
                else:
                    parts["2"]["image_fs_type"] = "btrfs"
                with patch.object(DISK, "LoadPartitionConfig", return_value=({}, parts)), \
                     patch.object(DISK, "GetPartitionTableFromImage"), \
                     patch.object(DISK, "Tune2fsReadWrite") as seal, \
                     patch.object(DISK, "Sudo") as write:
                    with self.assertRaises(DISK.InvalidLayout):
                        DISK.Verity(SimpleNamespace())
                    seal.assert_not_called()
                    write.assert_not_called()
                with patch.object(DISK, "GetPartitionTableFromImage"), \
                     patch.object(DISK.subprocess, "check_call") as cgpt:
                    with self.assertRaises(DISK.InvalidLayout):
                        DISK.WritePartitionTable(SimpleNamespace(create=False),
                                                 {"metadata": {"bytes": 100}}, parts)
                    cgpt.assert_not_called()

    def test_all_verity_destinations_checked_before_first_seal(self):
        parts = self.image_parts()
        parts["4"].update(fs_type="ext4", image_fs_type="ext4")
        parts["5"]["bytes"] = 4096
        with patch.object(DISK, "LoadPartitionConfig", return_value=({}, parts)), \
             patch.object(DISK, "GetPartitionTableFromImage"), \
             patch.object(DISK, "Tune2fsReadWrite") as seal, \
             patch.object(DISK, "PartitionLoop") as loop:
            with self.assertRaises(DISK.InvalidLayout):
                DISK.Verity(SimpleNamespace())
            seal.assert_not_called()
            loop.assert_not_called()

    def test_filesystem_size_checked_before_seal(self):
        parts = self.image_parts()
        with patch.object(DISK, "LoadPartitionConfig", return_value=({}, parts)), \
             patch.object(DISK, "GetPartitionTableFromImage"), \
             patch.object(DISK, "PartitionLoop", return_value=contextlib.nullcontext("/dev/example")), \
             patch.object(DISK, "Ext4Capacity", return_value={"filesystem_bytes": 4096}), \
             patch.object(DISK, "Tune2fsReadWrite") as seal:
            with self.assertRaises(DISK.InvalidLayout):
                DISK.Verity(SimpleNamespace())
            seal.assert_not_called()

    def test_capacity_records_bytes_and_inodes(self):
        output = b"Block count: 8192\nFree blocks: 4096\nBlock size: 4096\nInode count: 1024\nFree inodes: 900\n"
        with patch.object(DISK, "SudoOutput", return_value=output):
            capacity = DISK.Ext4Capacity("/dev/example")
        self.assertEqual(capacity, {"filesystem_bytes": 33554432, "free_bytes": 16777216,
                                    "used_bytes": 16777216, "inode_count": 1024, "free_inodes": 900})
        for bad in (b"", output.replace(b"Free blocks: 4096", b"Free blocks: 99999")):
            with patch.object(DISK, "SudoOutput", return_value=bad):
                with self.assertRaises(DISK.InvalidLayout):
                    DISK.Ext4Capacity("/dev/example")

    def test_verity_report_and_commands_for_btrfs_and_ext4(self):
        for selector, layout_file in (("btrfs", "disk_layout.json"),
                                     ("btrfs", "disk_layout_uki.json"),
                                     ("ext4", "disk_layout_uki.json")):
            with self.subTest(selector=selector, layout=layout_file), \
                 patch.dict(os.environ, {"ACL_EXPERIMENTAL_USR_FS": selector}), \
                 tempfile.TemporaryDirectory() as directory:
                config, parts = self.layout(file=layout_file)
                for part in parts.values():
                    part.update(image_compat=True, image_fs_type=part.get("fs_type"))
                data = next(p for p in parts.values() if p.get("mount") == "/usr")
                root = Path(directory)
                options = SimpleNamespace(root_hash=str(root / "root-hash"),
                                          fs_uuid=str(root / "fs-uuid"),
                                          verity_uuid=str(root / "verity-uuid"),
                                          capacity_report=str(root / "capacity.json"))
                fs_uuid = "11111111-1111-1111-1111-111111111111"
                verity_uuid = "22222222-2222-2222-2222-222222222222"
                verity_output = f"UUID: {verity_uuid}\nRoot hash: {'a' * 64}\n".encode()
                with patch.object(DISK, "LoadPartitionConfig", return_value=(config, parts)), \
                     patch.object(DISK, "GetPartitionTableFromImage"), \
                     patch.object(DISK, "PartitionLoop", side_effect=lambda options, part:
                                  contextlib.nullcontext("/dev/part" + str(part["num"]))), \
                     patch.object(DISK, "Ext4Capacity", return_value={
                         "filesystem_bytes": data["fs_bytes"], "free_bytes": 4096,
                         "used_bytes": data["fs_bytes"] - 4096, "inode_count": 100, "free_inodes": 50}), \
                     patch.object(DISK, "Tune2fsReadWrite") as ext4_seal, \
                     patch.object(DISK, "ReadWriteSubvol") as btrfs_seal, \
                     patch.object(DISK, "SudoOutput", side_effect=[
                         verity_output, fs_uuid.encode()]) as command:
                    DISK.Verity(options)
                report = json.loads(Path(options.capacity_report).read_text())
                self.assertEqual(report["schema_version"], 1)
                self.assertEqual(len(report["partitions"]), 1)
                capacity = report["partitions"][0]
                self.assertEqual(capacity["filesystem"], selector)
                self.assertEqual(capacity["hash_free_bytes"],
                                 capacity["hash_capacity_bytes"] - capacity["hash_required_bytes"])
                self.assertEqual(Path(options.root_hash).read_text(), "a" * 64 + "\n")
                self.assertEqual(Path(options.fs_uuid).read_text(), fs_uuid + "\n")
                self.assertEqual(Path(options.verity_uuid).read_text(), verity_uuid + "\n")
                arguments = command.call_args_list[0].args[0]
                self.assertEqual(arguments[0:3], ["veritysetup", "format", "--hash=sha256"])
                self.assertEqual(arguments[arguments.index("--data-blocks") + 1], data["fs_blocks"])
                if "verity_hash" in data:
                    self.assertNotIn("--hash-offset", arguments)
                    self.assertEqual(arguments[-1], "/dev/part" + str(data["verity_hash"]))
                else:
                    self.assertEqual(arguments[arguments.index("--hash-offset") + 1], data["fs_bytes"])
                    self.assertEqual(arguments[-1], arguments[-2])
                if selector == "ext4":
                    ext4_seal.assert_called_once_with(options, data, disable_rw=True)
                    btrfs_seal.assert_not_called()
                    self.assertEqual(capacity["free_inodes"], 50)
                else:
                    btrfs_seal.assert_called_once_with(options, data, disable_rw=True)
                    ext4_seal.assert_not_called()

    def test_probing_uses_actual_not_expanded_geometry(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / "image"
            image.write_bytes(b"\0" * (3 * 1024**2))
            part = {"num": 1, "label": "ROOT", "type": "data", "fs_type": "ext4",
                    "first_block": 2048, "first_byte": 1024**2,
                    "blocks": 4096, "bytes": 2 * 1024**2}
            with patch.object(DISK.subprocess, "check_output",
                              side_effect=[b"2048 2048 1 root\n", b"ext4\n"]), \
                 patch.object(DISK, "PartitionLoop",
                              return_value=contextlib.nullcontext("/dev/example")) as loop:
                DISK.GetPartitionTableFromImage(SimpleNamespace(disk_image=str(image)),
                                                {"metadata": {"block_size": 512}}, {"1": part})
            self.assertEqual(loop.call_args.args[1]["bytes"], 1024**2)
            self.assertEqual(loop.call_args.args[1]["first_byte"], 1024**2)
            self.assertTrue(part["image_compat"])

    def test_overlapping_or_out_of_file_extents_rejected_before_probes(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / "image"
            image.write_bytes(b"\0" * (3 * 1024**2))
            for table in (b"2048 2048 1 a\n3000 1024 2 b\n", b"2048 4096 1 a\n"):
                with patch.object(DISK.subprocess, "check_output", return_value=table), \
                     patch.object(DISK, "PartitionLoop") as loop:
                    with self.assertRaises(DISK.InvalidLayout):
                        DISK.GetPartitionTableFromImage(SimpleNamespace(disk_image=str(image)),
                                                        {"metadata": {"block_size": 512}}, {})
                    loop.assert_not_called()

    def test_last_usable_gpt_sector_is_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / "image"
            sectors = 4096
            image.write_bytes(b"\0" * (sectors * 512))
            blocks = sectors - 2048 - (DISK.GPT_RESERVED_SECTORS - 1)
            with patch.object(DISK.subprocess, "check_output",
                              return_value=f"2048 {blocks} 1 root\n".encode()):
                DISK.GetPartitionTableFromImage(SimpleNamespace(disk_image=str(image)),
                                                {"metadata": {"block_size": 512}}, {})

    def test_root_growth_preserves_btrfs_and_ext4_slots(self):
        for selector in ("btrfs", "ext4"):
            with self.subTest(selector=selector), patch.dict(
                    os.environ, {"ACL_EXPERIMENTAL_USR_FS": selector}):
                source_config, source = self.layout("base")
                target_config, target = self.layout("azure")
                table = "".join(f'{p["first_block"]} {p["blocks"]} {p["num"]} partition\n'
                                for p in source.values()).encode()
                responses = [table] + [p["fs_type"].encode() for p in target.values()
                                       if p.get("fs_type")]
                with patch.object(DISK.os.path, "isfile", return_value=True), \
                     patch.object(DISK.os.path, "getsize", return_value=source_config["metadata"]["bytes"]), \
                     patch.object(DISK.subprocess, "check_output", side_effect=responses), \
                     patch.object(DISK, "PartitionLoop", return_value=contextlib.nullcontext("/dev/example")):
                    DISK.GetPartitionTableFromImage(SimpleNamespace(disk_image="image"),
                                                    target_config, target)
                DISK.ValidateUsrPartitions(target)
                self.assertTrue(all(part["image_compat"] for part in target.values()))
                self.assertGreater(target["7"]["bytes"], source["7"]["bytes"])
                for number in ("2", "3", "4", "5"):
                    self.assertEqual(target[number]["bytes"], source[number]["bytes"])

    def test_metadata_legacy_btrfs_and_versioned_ext4(self):
        for fs, version, requested in (("", "", ""), ("btrfs", "", "btrfs"),
                                       ("ext4", "1", ""), ("ext4", "1", "ext4")):
            result = self.shell('acl_restore_usr_filesystem "$REQUESTED" amd64-usr || exit 1\nacl_usr_filesystem',
                                ACL_EXPERIMENTAL_USR_FS=fs,
                                ACL_USR_FS_METADATA_VERSION=version, REQUESTED=requested,
                                ACL_USR_BOARD="amd64-usr", ACL_USR_BOOTLOADER="uki")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), fs or "btrfs")

    def test_metadata_conflicts_and_unknown_versions_fail(self):
        for fs, version, requested in (("ext4", "", ""), ("ext4", "1", "btrfs"),
                                       ("btrfs", "", "ext4"), ("btrfs", "2", ""),
                                       ("invalid", "1", "")):
            result = self.shell('acl_restore_usr_filesystem "$REQUESTED" amd64-usr',
                                ACL_EXPERIMENTAL_USR_FS=fs,
                                ACL_USR_FS_METADATA_VERSION=version, REQUESTED=requested,
                                ACL_USR_BOARD="amd64-usr", ACL_USR_BOOTLOADER="uki")
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(result.stderr)

    def test_conversion_rejects_board_and_bootloader_mismatch(self):
        for board, boot in (("arm64-usr", "uki"), ("amd64-usr", "grub"), ("", "uki")):
            result = self.shell('acl_restore_usr_filesystem "" amd64-usr',
                                ACL_USR_FS_METADATA_VERSION="1", ACL_USR_BOARD=board,
                                ACL_USR_BOOTLOADER=boot)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("board/bootloader", result.stderr)

    def test_sdk_profile_refresh_clear_and_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory) / "bashrc"
            for selector in ("ext4", "", "btrfs"):
                profile.write_text("export ACL_EXPERIMENTAL_USR_FS='old'\nexport KEEP_ME=kept\n")
                result = self.shell(
                    'acl_preserve_usr_filesystem "$PROFILE" || exit 1\n'
                    'unset ACL_EXPERIMENTAL_USR_FS\nsource "$PROFILE"\n'
                    'printf "%s:%s" "$ACL_EXPERIMENTAL_USR_FS" "$KEEP_ME"',
                    PROFILE=str(profile), ACL_EXPERIMENTAL_USR_FS=selector)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, selector + ":kept")
                self.assertEqual(profile.read_text().count("export ACL_EXPERIMENTAL_USR_FS="), 1)
            original = profile.read_bytes()
            result = self.shell('acl_preserve_usr_filesystem "$PROFILE"',
                                PROFILE=str(profile), ACL_EXPERIMENTAL_USR_FS="ext4'; echo INJECTED; #")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(profile.read_bytes(), original)
            result = self.shell('acl_preserve_usr_filesystem "$PROFILE"',
                                PROFILE=str(Path(directory) / "missing"))
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((Path(directory) / "missing").exists())

    def test_sdk_exec_always_overrides_reused_container_value(self):
        source = (REPO / "run_sdk_container").read_text()
        command = source[source.rindex("\ncall_docker exec ") + 1:]
        for selector in ("ext4", ""):
            result = self.shell(
                'name=existing-sdk\ntty=()\ncall_docker() { printf "%s\\n" "$@"; }\n' + command,
                ACL_EXPERIMENTAL_USR_FS=selector)
            self.assertEqual(result.returncode, 0, result.stderr)
            args = result.stdout.splitlines()
            option = "ACL_EXPERIMENTAL_USR_FS=" + selector
            self.assertIn(option, args)
            self.assertEqual(args[args.index(option) - 1], "-e")
            for option in ("PACKAGE_SOURCE_MODE=RPM", "BOOTLOADER_MODE=uki"):
                self.assertIn(option, args)
                self.assertEqual(args[args.index(option) - 1], "-e")

    def test_sdk_default_bootloader_is_resolved_before_validation(self):
        source = (REPO / "run_sdk_container").read_text()
        start = source.index('export BOOTLOADER_MODE=')
        end = source.index("\narch=", start)
        result = self.shell('set -e\n' + source[start:end] + '\nprintf "%s" "$BOOTLOADER_MODE"',
                            BOOTLOADER_MODE=None)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "uki")

    def test_sdk_mode_profile_does_not_retain_old_container_modes(self):
        source = (REPO / "sdk_lib/sdk_entry.sh").read_text()
        start = source.index("# Preserve HYBRID mode")
        end = source.index('if [[ -n "${SYSEXT_COMPRESSION:-}" ]]', start)
        block = source[start:end].replace("/home/sdk/.bashrc", '"$PROFILE"')
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory) / "bashrc"
            for package, boot, expected in (("RPM", "uki", "RPM:uki"), ("", "", "default:default")):
                profile.write_text("export PACKAGE_SOURCE_MODE=PORTAGE\nexport BOOTLOADER_MODE=grub\n")
                result = self.shell(
                    block + '\nunset PACKAGE_SOURCE_MODE BOOTLOADER_MODE\nsource "$PROFILE"\n'
                    'printf "%s:%s" "${PACKAGE_SOURCE_MODE-default}" "${BOOTLOADER_MODE-default}"',
                    PROFILE=str(profile), PACKAGE_SOURCE_MODE=package, BOOTLOADER_MODE=boot,
                    ACL_EXPERIMENTAL_USR_FS="")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected)

    def test_wrapper_cli_selector_and_empty_value(self):
        source = (REPO / "acl/build_rpm_image.sh").read_text()
        start = source.index("parse_args() {")
        parser = source[start:source.index("\n}\n", start) + 3]
        setup = """
RETRY_ATTEMPTS=0 GROUP=production BUILD_VM_IMAGE=false START_VM=false
REUSE_IMAGE=false ACG_IMAGE_VERSION_ID='' VM_TYPE=qemu
error() { printf '%s\\n' "$*" >&2; }
"""
        code = setup + parser + '\nparse_args "$@"\nacl_validate_usr_filesystem || exit 1\nacl_usr_filesystem'
        for args in (("--usr-fs=ext4",), ("--usr-fs", "ext4"), ("--usr-fs=btrfs",)):
            result = self.shell(code, args=args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "btrfs" if "btrfs" in args[0] else "ext4")
        for args in (("--usr-fs=",), ("--usr-fs",), ("--usr-fs=invalid",)):
            result = self.shell(code, args=args)
            self.assertNotEqual(result.returncode, 0)

    def test_optin_image_gate_rejects_unverified_and_nonprod_before_layout_checks(self):
        source = (REPO / "build_image").read_text()
        gate = source[source.index("acl_validate_usr_filesystem || exit 1"):
                      source.index("# If downloading packages")]
        with tempfile.TemporaryDirectory() as directory:
            tool = Path(directory) / "disk_util"
            tool.write_text("#!/bin/bash\nprintf 'LAYOUT_CHECK\\n'\n")
            tool.chmod(0o755)
            code = """
set -eu
FLAGS_TRUE=0 FLAGS_FALSE=1 FLAGS_generate_update=1
FLAGS_enable_rootfs_verification="$VERIFIED"
FLAGS_board=amd64-usr
die() { printf '%s\\n' "$*" >&2; exit 1; }
""" + gate
            for selector in ("ext4",):
                for image_type, verified, accepted in (
                        ("prod", "0", True), ("prod", "1", False),
                        ("container", "0", False), ("prodtar", "0", False)):
                    with self.subTest(selector=selector, image=image_type, verified=verified):
                        result = self.shell(
                            code, args=(image_type,), ACL_EXPERIMENTAL_USR_FS=selector,
                            BUILD_LIBRARY_DIR=Path(directory).as_posix(), VERIFIED=verified)
                        self.assertEqual(result.returncode == 0, accepted, result.stderr)
                        self.assertEqual("LAYOUT_CHECK" in result.stdout, accepted)
            result = self.shell(
                code, args=("container",), ACL_EXPERIMENTAL_USR_FS="btrfs",
                BUILD_LIBRARY_DIR=Path(directory).as_posix(), VERIFIED="1")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("LAYOUT_CHECK", result.stdout)

    def test_mount_flags_are_slot_specific(self):
        for fs, flags in (("btrfs", "ro"), ("ext4", "ro,noload")):
            result = self.shell("acl_usr_mount_options", ACL_EXPERIMENTAL_USR_FS=fs)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), flags)
        source = (REPO / "build_library/rpm/uki_install.sh").read_text()
        main, addons = source.split("_uki_build_verity_addons() {", 1)
        self.assertNotIn("noload", main)
        self.assertIn('cmdline+=" mount.usrflags=${usr_options}"', addons)


if __name__ == "__main__":
    unittest.main()
