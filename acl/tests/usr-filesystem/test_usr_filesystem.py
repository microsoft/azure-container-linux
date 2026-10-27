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
ENV = {"ACL_USR_FS": "erofs", "PACKAGE_SOURCE_MODE": "RPM",
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

    def image_parts(self, filesystem="erofs"):
        _, parts = self.layout()
        for part in parts.values():
            part.update(image_exists=True, image_compat=True,
                        image_fs_type=part.get("fs_type"),
                        image_bytes=part["bytes"], image_first_byte=part["first_byte"])
        parts["2"]["fs_type"] = parts["2"]["image_fs_type"] = filesystem
        return parts

    @unittest.skipUnless(hasattr(os, "setxattr"), "requires POSIX extended attributes")
    def test_sysext_io_installation_is_optin_and_preserves_binary_metadata(self):
        for filesystem in ("btrfs", "erofs"):
            with self.subTest(filesystem=filesystem), tempfile.TemporaryDirectory() as directory:
                binary = Path(directory) / "usr/bin/systemd-sysext"
                binary.parent.mkdir(parents=True)
                binary.write_bytes(b"original executable\n")
                binary.chmod(0o751)
                os.setxattr(binary, "user.acl-fixture", b"preserved")
                alias = binary.with_name("systemd-confext")
                alias.symlink_to(binary.name)
                hardlink = binary.with_name("hardlink-fixture")
                os.link(binary, hardlink)
                result = self.shell(
                    'sudo() { "$@"; }\nacl_install_sysext_io_default "$1"',
                    (directory,), ACL_USR_FS=filesystem,
                    BUILD_LIBRARY_DIR=str(REPO / "build_library"))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(hardlink.read_bytes(), b"original executable\n")
                if filesystem == "btrfs":
                    self.assertEqual(binary.read_bytes(), b"original executable\n")
                    self.assertFalse(binary.with_name(binary.name + ".acl-real").exists())
                    continue
                original = binary.with_name(binary.name + ".acl-real")
                self.assertEqual(original.read_bytes(), b"original executable\n")
                self.assertEqual(binary.read_bytes(), (REPO / "build_library/rpm/systemd-sysext").read_bytes())
                for path in (binary, original):
                    self.assertEqual(path.stat().st_mode & 0o777, 0o751)
                    self.assertEqual(os.getxattr(path, "user.acl-fixture"), b"preserved")
                self.assertTrue(alias.is_symlink())
                repeated = self.shell(
                    'sudo() { "$@"; }\nacl_install_sysext_io_default "$1"',
                    (directory,), BUILD_LIBRARY_DIR=str(REPO / "build_library"))
                self.assertNotEqual(repeated.returncode, 0)
                self.assertIn("existing wrapper", repeated.stderr)
                self.assertEqual(original.read_bytes(), b"original executable\n")

    def test_sysext_io_wrapper_preserves_overrides_alias_arguments_and_exit(self):
        template = str(REPO / "build_library/rpm/systemd-sysext")
        for name, requested, expected in (
            ("systemd-sysext", None, "0"), ("systemd-sysext", "1", "1"),
            ("systemd-sysext", "0", "0"), ("systemd-sysext", "", ""),
            ("systemd-confext", None, "unset"), ("systemd-confext", "1", "1"),
        ):
            with self.subTest(name=name, requested=requested):
                env = dict(os.environ)
                env.pop("SYSTEMD_LOOP_DIRECT_IO", None)
                if requested is not None:
                    env["SYSTEMD_LOOP_DIRECT_IO"] = requested
                result = subprocess.run(
                    [os.environ.get("BASH", "bash"), "-c",
                     'exec() { printf "%s\\0" "${SYSTEMD_LOOP_DIRECT_IO-unset}" "$@"; return 37; }; '
                     'template="$1"; shift; source "$template"',
                     name, template, "refresh", "argument with spaces", ""],
                    env=env, capture_output=True)
                self.assertEqual(result.returncode, 37, result.stderr)
                self.assertEqual(result.stdout.decode().split("\0"), [
                    expected, "-a", name, "/usr/bin/systemd-sysext.acl-real",
                    "refresh", "argument with spaces", "", ""])

    def test_sysext_io_installation_rejects_missing_binary(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.shell('acl_install_sysext_io_default "$1"', (directory,),
                                BUILD_LIBRARY_DIR=str(REPO / "build_library"))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing binary", result.stderr)

    def test_explicit_legacy_btrfs_layout_is_unchanged(self):
        for requested in ("btrfs",):
            with self.subTest(requested=requested):
                config = json.loads((REPO / "build_library/disk_layout_uki.json").read_text())
                expected = copy.deepcopy(config)
                with patch.dict(os.environ, {"ACL_USR_FS": requested}):
                    DISK.ApplyExperimentalUsrLayout(config)
                    _, parts = self.layout()
                self.assertEqual(config, expected)
                self.assertEqual(parts["2"]["fs_type"], "btrfs")
                self.assertEqual(parts["2"]["bytes"], 1024**3)
                self.assertEqual(parts["3"]["bytes"], 10 * 1024**2)

    def test_new_acl_default_is_erofs_including_official_builds(self):
        for selector in (None, "", "erofs"):
            for official in ("0", "1"):
                with self.subTest(selector=selector, official=official), \
                        patch.dict(os.environ, {"COREOS_OFFICIAL": official}):
                    if selector is None:
                        os.environ.pop("ACL_USR_FS", None)
                    else:
                        os.environ["ACL_USR_FS"] = selector
                    for arch in ("x86_64", "aarch64"):
                        _, parts = self.layout(arch=arch)
                        self.assertEqual(parts["2"]["fs_type"], "erofs")
                        self.assertEqual(parts["2"]["bytes"], 1024**3)
                        self.assertEqual(parts["3"]["bytes"], 10 * 1024**2)
                        self.assertEqual(parts["6"]["fs_type"], "btrfs")
                        self.assertEqual(parts["7"]["fs_type"], "ext4")
                    result = self.shell("acl_validate_usr_filesystem && acl_usr_filesystem")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.strip(), "erofs")

    def test_new_acl_accepts_explicit_formats_and_conversion_retains_them(self):
        for selector in ("btrfs", "erofs"):
            result = self.shell("acl_validate_usr_filesystem",
                                ACL_USR_FS=selector)
            self.assertEqual(result.returncode, 0, result.stderr)
        source = (REPO / "acl/build_rpm_image.sh").read_text()
        start = source.index('    parse_args "$@"', source.index("main() {")) + len('    parse_args "$@"')
        gate = source[start:source.index('    section "Azure Container Linux Image Builder"', start)]
        for build in ("true", "false"):
            for selector in ("btrfs", "erofs"):
                result = self.shell(gate, BUILD_IMAGE=build, ACL_USR_FS=selector)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_fresh_build_resolves_default_before_filesystem_hooks(self):
        builder = (REPO / "build_image").read_text()
        gate = builder[builder.index("acl_validate_usr_filesystem || exit 1"):
                       builder.index("# If downloading packages")]
        hooks = (REPO / "build_library/build_image_util.sh").read_text()
        start = hooks.index('  info "Using image type ${disk_layout}"')
        formatting = hooks[start:hooks.index('  trap "cleanup_mounts', start)]
        start = hooks.index('    if [[ "${ACL_USR_FS:-}" == "erofs" ]]',
                            hooks.index("# Make the filesystem un-mountable"))
        sealing = hooks[start:hooks.index("\n    fi", start) + len("\n    fi")]
        dracut = (REPO / "build_library/rpm/dracut_install.sh").read_text()
        start = dracut.index('    if [[ "${ACL_USR_FS:-}" == "erofs" ]]',
                            dracut.index("generate_initramfs_dracut() {"))
        kernel = dracut[start:dracut.index("\n    fi", start) + len("\n    fi")]
        with tempfile.TemporaryDirectory() as directory:
            tool = Path(directory) / "disk_util"
            tool.write_text('#!/bin/bash\nprintf "TOOL|%s\\n" "$*"\n')
            tool.chmod(0o755)
            code = """
set -eu
FLAGS_TRUE=0 FLAGS_FALSE=1 FLAGS_generate_update=1
FLAGS_enable_rootfs_verification=0 FLAGS_board=amd64-usr
BOARD=amd64-usr disk_layout=base disk_img=image.bin root_fs_dir=root kernel_version=fixture
info() { :; }
assert_image_size() { :; }
sudo() { printf 'SUDO|%s\\n' "$*"; }
die() { printf '%s\\n' "$*" >&2; exit 1; }
validate_erofs_kernel_config() { printf 'KERNEL_CHECK\\n'; }
""" + gate + "\nexercise_hooks() {\n" + formatting + sealing + "\n" + kernel + """
}
exercise_hooks
bash -c 'printf "EXPORTED|%s\\n" "${ACL_USR_FS-unset}"'
"""
            for selector in (None, "", "erofs", "btrfs"):
                with self.subTest(selector=selector):
                    result = self.shell(
                        code, args=("prod",), ACL_USR_FS=selector,
                        BUILD_LIBRARY_DIR=Path(directory).as_posix())
                    self.assertEqual(result.returncode, 0, result.stderr)
                    erofs = not selector or selector == "erofs"
                    self.assertEqual("format --erofs-staging" in result.stdout, erofs)
                    self.assertEqual("mount --writable_verity --erofs-staging" in result.stdout, erofs)
                    self.assertEqual("seal_erofs image.bin root/usr" in result.stdout, erofs)
                    self.assertEqual("KERNEL_CHECK" in result.stdout, erofs)
                    self.assertIn("EXPORTED|" + (selector or "erofs"), result.stdout)

    def test_supported_layouts_and_architectures(self):
        for arch in ("x86_64", "aarch64"):
            for name in ("base", "vm", "azure"):
                with self.subTest(arch=arch, name=name):
                    config, parts = self.layout(name, arch)
                    for number in ("2", "4"):
                        self.assertEqual(parts[number]["bytes"], 1024**3)
                        self.assertNotIn("fs_compression", parts[number])
                    for number in ("3", "5"):
                        self.assertEqual(parts[number]["bytes"], 10 * 1024**2)
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
        for key, value in (("ACL_USR_FS", "invalid"),
                           ("PACKAGE_SOURCE_MODE", "PORTAGE"),
                           ("BOOTLOADER_MODE", "grub")):
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
        with patch.dict(os.environ, {"ACL_USR_FS": "btrfs",
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


    def test_hash_capacity_matches_legacy_and_large_layouts(self):
        self.assertEqual(DISK.VerityHashBytes(260094, 4096), 8396800)
        self.assertEqual(DISK.VerityHashBytes(262144, 4096), 8462336)
        self.assertEqual(DISK.VerityHashBytes(1048576, 4096), 33824768)
        self.assertEqual(DISK.VerityHashBytes(1, 4096), 4096)
        for blocks, size in ((0, 4096), (-1, 4096), (1, 0), (10, 1000)):
            with self.assertRaises(DISK.InvalidLayout):
                DISK.VerityHashBytes(blocks, size)
        with patch.dict(os.environ, {"ACL_USR_FS": "btrfs"}):
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
        parts["4"].update(fs_type="erofs", image_fs_type="erofs")
        parts["5"]["bytes"] = 4096
        with patch.object(DISK, "LoadPartitionConfig", return_value=({}, parts)), \
             patch.object(DISK, "GetPartitionTableFromImage"), \
             patch.object(DISK, "Tune2fsReadWrite") as seal, \
             patch.object(DISK, "PartitionLoop") as loop:
            with self.assertRaises(DISK.InvalidLayout):
                DISK.Verity(SimpleNamespace())
            seal.assert_not_called()
            loop.assert_not_called()


    def test_verity_commands_for_supported_filesystems(self):
        for selector, layout_file in (("btrfs", "disk_layout.json"),
                                     ("btrfs", "disk_layout_uki.json"),
                                     ("erofs", "disk_layout_uki.json")):
            with self.subTest(selector=selector, layout=layout_file), \
                 patch.dict(os.environ, {"ACL_USR_FS": selector}), \
                 tempfile.TemporaryDirectory() as directory:
                config, parts = self.layout(file=layout_file)
                for part in parts.values():
                    part.update(image_compat=True, image_fs_type=part.get("fs_type"))
                data = next(p for p in parts.values() if p.get("mount") == "/usr")
                root = Path(directory)
                options = SimpleNamespace(root_hash=str(root / "root-hash"),
                                          fs_uuid=str(root / "fs-uuid"),
                                          verity_uuid=str(root / "verity-uuid"))
                fs_uuid = "11111111-1111-1111-1111-111111111111"
                verity_uuid = "22222222-2222-2222-2222-222222222222"
                verity_output = f"UUID: {verity_uuid}\nRoot hash: {'a' * 64}\n".encode()
                with patch.object(DISK, "LoadPartitionConfig", return_value=(config, parts)), \
                     patch.object(DISK, "GetPartitionTableFromImage"), \
                     patch.object(DISK, "PartitionLoop", side_effect=lambda options, part:
                                  contextlib.nullcontext("/dev/part" + str(part["num"]))), \
                     patch.object(DISK, "Tune2fsReadWrite") as ext4_seal, \
                     patch.object(DISK, "ReadWriteSubvol") as btrfs_seal, \
                     patch.object(DISK, "SudoOutput", side_effect=[
                         verity_output, fs_uuid.encode()]) as command:
                    DISK.Verity(options)
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
                if selector == "btrfs":
                    btrfs_seal.assert_called_once_with(options, data, disable_rw=True)
                    ext4_seal.assert_not_called()
                else:
                    btrfs_seal.assert_not_called()
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

    def test_root_growth_preserves_usr_slots(self):
        for selector in ("btrfs", "erofs"):
            with self.subTest(selector=selector), patch.dict(
                    os.environ, {"ACL_USR_FS": selector}):
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

    def test_metadata_legacy_btrfs_and_versioned_optins(self):
        for fs, version, requested in (("", "", ""), ("btrfs", "", "btrfs"),
                                       ("erofs", "1", ""), ("erofs", "1", "erofs")):
            result = self.shell('acl_restore_usr_filesystem "$REQUESTED" amd64-usr || exit 1\nacl_usr_filesystem',
                                ACL_USR_FS=fs,
                                ACL_USR_FS_METADATA_VERSION=version, REQUESTED=requested,
                                ACL_USR_BOARD="amd64-usr", ACL_USR_BOOTLOADER="uki")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), fs or "btrfs")

    def test_metadata_conflicts_and_unknown_versions_fail(self):
        for fs, version, requested in (("erofs", "", ""),
                                       ("btrfs", "", "erofs"), ("btrfs", "2", ""),
                                       ("erofs", "1", "btrfs"), ("btrfs", "1", "erofs"),
                                       ("invalid", "1", "")):
            result = self.shell('acl_restore_usr_filesystem "$REQUESTED" amd64-usr',
                                ACL_USR_FS=fs,
                                ACL_USR_FS_METADATA_VERSION=version, REQUESTED=requested,
                                ACL_USR_BOARD="amd64-usr", ACL_USR_BOOTLOADER="uki")
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(result.stderr)

    def test_old_metadata_is_read_but_never_overrides_new_metadata(self):
        for current, legacy, expected in (
                (None, "erofs", "erofs"), (None, "btrfs", "btrfs"),
                ("erofs", "erofs", "erofs"), ("btrfs", "btrfs", "btrfs"),
                ("erofs", "btrfs", None), ("btrfs", "erofs", None)):
            with self.subTest(current=current, legacy=legacy):
                result = self.shell(
                    'acl_restore_usr_filesystem "" amd64-usr || exit 1\n'
                    'printf "%s:%s" "$ACL_USR_FS" "${ACL_EXPERIMENTAL_USR_FS-unset}"',
                    ACL_USR_FS=current, ACL_EXPERIMENTAL_USR_FS=legacy,
                    ACL_USR_FS_METADATA_VERSION="1", ACL_USR_BOARD="amd64-usr",
                    ACL_USR_BOOTLOADER="uki")
                self.assertEqual(result.returncode == 0, expected is not None, result.stderr)
                if expected is not None:
                    self.assertEqual(result.stdout, expected + ":unset")
                else:
                    self.assertIn("conflicting filesystem metadata", result.stderr)

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
            for selector in ("erofs", "", "btrfs"):
                profile.write_text("export ACL_USR_FS='old'\n"
                                   "export ACL_EXPERIMENTAL_USR_FS='btrfs'\nexport KEEP_ME=kept\n")
                result = self.shell(
                    'acl_preserve_usr_filesystem "$PROFILE" || exit 1\n'
                    'unset ACL_USR_FS\nsource "$PROFILE"\n'
                    'printf "%s:%s" "$ACL_USR_FS" "$KEEP_ME"',
                    PROFILE=str(profile), ACL_USR_FS=selector)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, selector + ":kept")
                self.assertEqual(profile.read_text().count("export ACL_USR_FS="), 1)
                self.assertNotIn("ACL_EXPERIMENTAL_USR_FS", profile.read_text())
            original = profile.read_bytes()
            result = self.shell('acl_preserve_usr_filesystem "$PROFILE"',
                                PROFILE=str(profile), ACL_USR_FS="erofs'; echo INJECTED; #")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(profile.read_bytes(), original)
            result = self.shell('acl_preserve_usr_filesystem "$PROFILE"',
                                PROFILE=str(Path(directory) / "missing"))
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((Path(directory) / "missing").exists())

    def test_sdk_exec_always_overrides_reused_container_value(self):
        source = (REPO / "run_sdk_container").read_text()
        command = source[source.rindex("\ncall_docker exec ") + 1:]
        for selector in ("erofs", ""):
            result = self.shell(
                'name=existing-sdk\ntty=()\ncall_docker() { printf "%s\\n" "$@"; }\n' + command,
                ACL_USR_FS=selector)
            self.assertEqual(result.returncode, 0, result.stderr)
            args = result.stdout.splitlines()
            option = "ACL_USR_FS=" + selector
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

    def test_sdk_entrypoint_loads_helper_from_checkout_and_standalone_image(self):
        dockerfile = (REPO / "sdk_lib/Dockerfile.sdk-import").read_text()
        repository_path = "/mnt/host/source/src/scripts"
        self.assertIn("COPY --chown=sdk:sdk . " + repository_path, dockerfile)
        self.assertIn("COPY --chown=sdk:sdk build_library/usr_filesystem.sh /home/sdk", dockerfile)
        source = (REPO / "sdk_lib/sdk_entry.sh").read_text()
        prefix = source[:source.index('if [ -n "${SDK_USER_ID:-}" ]')]
        for layout in ("checkout", "standalone"):
            with self.subTest(layout=layout), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                entry = root / ("sdk_lib/sdk_entry.sh" if layout == "checkout"
                                else "home/sdk/sdk_entry.sh")
                helper = root / ("build_library/usr_filesystem.sh" if layout == "checkout"
                                 else "home/sdk/usr_filesystem.sh")
                entry.parent.mkdir(parents=True)
                helper.parent.mkdir(parents=True, exist_ok=True)
                helper.write_text((REPO / "build_library/usr_filesystem.sh").read_text(),
                                  newline="\n")
                profile = root / "bashrc"
                entry.write_text(prefix.replace("/home/sdk/.bashrc", '"$PROFILE"') +
                                 '\nacl_usr_filesystem\n', newline="\n")
                for filesystem, bootloader, accepted in (
                        ("erofs", "uki", True), ("btrfs", "uki", True),
                        ("invalid", "uki", False), ("", "grub", True),
                        ("btrfs", "grub", True), ("erofs", "grub", False)):
                    with self.subTest(filesystem=filesystem, bootloader=bootloader):
                        profile.write_text("export PACKAGE_SNAPSHOT_TIME=1600000000\n",
                                           newline="\n")
                        result = subprocess.run(
                            [os.environ.get("BASH", "bash"), str(entry)],
                            env={**os.environ, "ACL_USR_FS": filesystem,
                                 "BOOTLOADER_MODE": bootloader,
                                 "PROFILE": profile.as_posix(),
                                 "PACKAGE_SNAPSHOT_TIME": "1700000000"},
                            text=True, capture_output=True)
                        self.assertEqual(result.returncode == 0, accepted,
                                         result.stderr)
                        if result.returncode == 0:
                            self.assertEqual(result.stdout.strip(), filesystem or "erofs")
                            self.assertEqual(profile.read_text(),
                                             "export PACKAGE_SNAPSHOT_TIME=1700000000\n")

    def test_sdk_grub_operations_preserve_unselected_filesystem(self):
        source = (REPO / "run_sdk_container").read_text()
        start = source.index('export BOOTLOADER_MODE=')
        prefix = source[start:source.index("\narch=", start)]
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory) / "bashrc"
            profile.write_text("export ACL_USR_FS=erofs\n", newline="\n")
            result = self.shell(
                'set -e\n' + prefix +
                '\nacl_preserve_usr_filesystem "$PROFILE"\n'
                'source "$PROFILE"\nprintf "%s" "${ACL_USR_FS}"\n',
                ACL_USR_FS=None, BOOTLOADER_MODE="grub", PROFILE=profile.as_posix())
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")
            self.assertEqual(profile.read_text(), "export ACL_USR_FS=''\n")

    def test_grub_non_image_operations_do_not_select_a_new_usr_filesystem(self):
        source = (REPO / "acl/build_rpm_image.sh").read_text()
        source = source.replace(
            'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."',
            'SCRIPT_DIR="$WRAPPER_REPO"')
        source = source.rsplit('\nmain "$@"', 1)[0]
        source += '\ncheck_prerequisites() { echo REACHED_PREREQUISITES; exit 0; }\nmain "$@"\n'
        for args, accepted in (
                (("--build-rpms",), True),
                (("--start-vm",), True),
                (("--run-script=true",), True),
                (("--build-image",), False),
                (("--build-image", "--usr-fs=btrfs"), True),
                (("--build-rpms", "--usr-fs=invalid"), False)):
            with self.subTest(args=args):
                result = self.shell(source, args=args, ACL_USR_FS=None,
                                    WRAPPER_REPO=REPO.as_posix(), BOOTLOADER_MODE="grub")
                self.assertEqual(result.returncode == 0, accepted, result.stdout + result.stderr)
                self.assertEqual("REACHED_PREREQUISITES" in result.stdout, accepted)

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
                    ACL_USR_FS="")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected)

    def test_wrapper_cli_selector_and_empty_value(self):
        source = (REPO / "acl/build_rpm_image.sh").read_text()
        start = source.index("parse_args() {")
        parser = source[source.index("validate_ipe_boot_path() {"):
                        source.index("\n}\n", start) + 3]
        setup = """
RETRY_ATTEMPTS=0 GROUP=production BUILD_VM_IMAGE=false START_VM=false
REUSE_IMAGE=false ACG_IMAGE_VERSION_ID='' VM_TYPE=qemu
BUILD_IMAGE=true BUILD_TEST_IMAGE=false REUSE_VM=false RUN_KOLA_TESTS=false
ACL_IPE_MODE=disabled ACL_IPE_SIGNING_MODE=ephemeral
IPE_MODE_OVERRIDE_SET=false IPE_SIGNING_MODE_OVERRIDE_SET=false
error() { printf '%s\\n' "$*" >&2; }
"""
        code = setup + parser + '\nparse_args "$@"\nacl_validate_usr_filesystem || exit 1\nacl_usr_filesystem'
        for args, expected in (
                (("--usr-fs=btrfs",), "btrfs"), (("--usr-fs=erofs",), "erofs"),
                (("--usr-fs", "erofs"), "erofs")):
            result = self.shell(code, args=args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), expected)
        for vm_type in ("qemu", "azure"):
            result = self.shell(
                code + '\nprintf "%s:%s" "$BUILD_TEST_IMAGE" "$VM_TYPE"',
                args=("--usr-fs=erofs", "--build-test-image", "--vm-type=" + vm_type))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), ["erofs", "true:" + vm_type])
        for args in (("--usr-fs=",), ("--usr-fs",), ("--usr-fs=invalid",)):
            result = self.shell(code, args=args)
            self.assertNotEqual(result.returncode, 0)
        for filesystem in ("btrfs", "erofs"):
            for mode in ("disabled", "audit"):
                result = self.shell(
                    code + '\nprintf "%s:%s" "$ACL_IPE_MODE" "$ACL_IPE_SIGNING_MODE"',
                    args=("--usr-fs=" + filesystem, "--ipe-mode=" + mode,
                          "--ipe-signing-mode=esrp"))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), [filesystem, mode + ":esrp"])

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
            for selector in ("erofs",):
                for image_type, verified, accepted in (
                        ("prod", "0", True), ("prod", "1", False),
                        ("container", "0", False), ("prodtar", "0", False)):
                    with self.subTest(selector=selector, image=image_type, verified=verified):
                        result = self.shell(
                            code, args=(image_type,), ACL_USR_FS=selector,
                            BUILD_LIBRARY_DIR=Path(directory).as_posix(), VERIFIED=verified)
                        self.assertEqual(result.returncode == 0, accepted, result.stderr)
                        self.assertEqual("LAYOUT_CHECK" in result.stdout, accepted)
            result = self.shell(
                code, args=("container",), ACL_USR_FS="btrfs",
                BUILD_LIBRARY_DIR=Path(directory).as_posix(), VERIFIED="1")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("LAYOUT_CHECK", result.stdout)

    def test_test_and_prod_vm_dispatch_keep_selector_and_separate_injection(self):
        source = (REPO / "acl/build_rpm_image.sh").read_text()
        branches = source[source.index("    # Step 5a:"):source.index("    # Step 6:")]
        code = """
BUILD_TEST_IMAGE=true BUILD_VM_IMAGE=true IMG_NAME=acl_production
section() { :; }
info() { :; }
build_vm_image() {
    printf 'BUILD|%s|%s|%s|%s\\n' "$1" "$2" "$ACL_USR_FS" "$INJECT_DOCKER_SYSEXT"
}
mv() { printf 'MOVE|%s|%s\\n' "$1" "$2"; }
cp() { :; }
exercise() {
""" + branches + "\n}\nexercise\n"
        for selector in ("btrfs", "erofs"):
            for board in ("amd64-usr", "arm64-usr"):
                for vm_type, basename, suffix in (
                        ("qemu", "qemu_uefi", "img"), ("azure", "azure", "vhd")):
                    with self.subTest(selector=selector, board=board, vm=vm_type):
                        result = self.shell(code, ACL_USR_FS=selector,
                                            BOARD=board, VM_TYPE=vm_type)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        prefix = f"__build__/images/images/{board}/latest/acl_production_{basename}"
                        image = f"{prefix}_image.{suffix}"
                        test_image = f"{prefix}_test_image.{suffix}"
                        self.assertEqual(result.stdout.splitlines(), [
                            f"BUILD|{vm_type}|{image}|{selector}|true",
                            f"MOVE|{image}|{test_image}",
                            f"BUILD|{vm_type}|{image}|{selector}|false",
                        ])

    def test_vm_conversion_dispatches_image_to_vm_not_a_test_root_build(self):
        source = (REPO / "acl/build_rpm_image.sh").read_text()
        start = source.index("build_vm_image() {")
        function = source[start:source.index("\n}\n", start) + 3]
        ipe_helpers = (REPO / "build_library/rpm/ipe_artifact.sh").read_text()
        ipe_helpers += source[source.index("validate_ipe_boot_path() {"):
                              source.index("operation_uses_vm_image() {")]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sdk = root / "run_sdk_container"
            sdk.write_text(
                "#!/bin/bash\n"
                "printf 'FS=%s\\nINJECT=%s\\n' \"$ACL_USR_FS\" \"$INJECT_DOCKER_SYSEXT\"\n"
                "printf '%s\\n' \"$@\"\n")
            sdk.chmod(0o755)
            output = root / "stub.img"
            output.write_text("dispatch fixture, not an image")
            code = """
set -eu
BOARD=amd64-usr IMG_NAME=acl_production NO_TTY=false
ACL_IPE_MODE=disabled ACL_IPE_SIGNING_MODE=ephemeral
IPE_MODE_OVERRIDE_SET=false IPE_SIGNING_MODE_OVERRIDE_SET=false
export INJECT_DOCKER_SYSEXT=true
get_sdk_image() { printf '%s' 'fixture-sdk'; }
get_tty_flag() { :; }
info() { :; }
error() { printf '%s\\n' "$*" >&2; }
""" + ipe_helpers + function + '\nbuild_vm_image "$VM_TYPE" "$TEST_OUTPUT"\n'
            for vm_type, format_name in (("qemu", "qemu_uefi"), ("azure", "azure")):
                result = self.shell(
                    code, ACL_USR_FS="erofs", VM_TYPE=vm_type,
                    SCRIPT_DIR=root.as_posix(), TEST_OUTPUT=output.as_posix())
                self.assertEqual(result.returncode, 0, result.stderr)
                arguments = result.stdout.splitlines()
                self.assertIn("FS=erofs", arguments)
                self.assertIn("INJECT=true", arguments)
                self.assertIn("./image_to_vm.sh", arguments)
                self.assertIn("--format=" + format_name, arguments)
                self.assertNotIn("./build_image", arguments)

    def test_pipeline_default_is_not_an_explicit_btrfs_conversion_request(self):
        source = (REPO / "image_to_vm.sh").read_text()
        block = source[source.index('requested_usr_fs="${ACL_USR_FS:-}"'):
                       source.index("\nset_vm_paths ")]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for field, recorded in (("ACL_USR_FS", "btrfs"), ("ACL_USR_FS", "erofs"),
                                    ("ACL_EXPERIMENTAL_USR_FS", "btrfs"),
                                    ("ACL_EXPERIMENTAL_USR_FS", "erofs")):
                (root / "version.txt").write_text(
                    "FLATCAR_VERSION=fixture\nACL_USR_FS_METADATA_VERSION=1\n"
                    f"{field}={recorded}\n"
                    "ACL_USR_BOARD=amd64-usr\nACL_USR_BOOTLOADER=uki\n")
                for requested in ("", "btrfs", "erofs"):
                    with self.subTest(field=field, recorded=recorded, requested=requested):
                        result = self.shell(
                            'set -eu\nFLAGS_board=amd64-usr\n' + block + "\nacl_usr_filesystem\n",
                            ACL_USR_FS=requested, ACL_EXPERIMENTAL_USR_FS="invalid",
                            FLAGS_from=root.as_posix())
                        accepted = not requested or requested == recorded
                        self.assertEqual(result.returncode == 0, accepted, result.stderr)
                        if accepted:
                            self.assertEqual(result.stdout.strip(), recorded)

    def test_main_uki_keeps_usr_readonly_without_duplicate_addon_flags(self):
        source = (REPO / "build_library/rpm/uki_install.sh").read_text()
        main, addons = source.split("_uki_build_verity_addons() {", 1)
        self.assertIn("mount.usrflags=ro", main)
        self.assertNotIn("mount.usrflags", addons)


if __name__ == "__main__":
    unittest.main()
