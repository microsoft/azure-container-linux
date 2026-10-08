import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from test_usr_filesystem import DISK, ENV


@unittest.skipUnless(sys.platform.startswith("linux") and all(
    shutil.which(command) for command in ("mke2fs", "tune2fs", "e2fsck", "dumpe2fs", "veritysetup")),
    "Requires existing Linux e2fsprogs and veritysetup; no automatic installation")
class Ext4ToolsTests(unittest.TestCase):
    def test_real_format_seal_unseal_and_verity(self):
        def run(command, **kwargs):
            return subprocess.run(list(map(str, command)), check=True, capture_output=True).stdout

        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, ENV), \
             patch.object(DISK, "Sudo", side_effect=run), patch.object(DISK, "SudoOutput", side_effect=run):
            image, tree = Path(directory) / "usr.ext4", Path(directory) / "usr.hash"
            with image.open("wb") as stream:
                stream.truncate(32 * 1024**2)
            # Do not preallocate: measure the hash tree actually produced by veritysetup.
            tree.touch()
            part = {"label": "USR-A", "fs_type": "ext4", "type": "flatcar-rootfs",
                    "fs_block_size": 4096, "fs_blocks": 8192, "first_byte": 0}
            DISK.FormatExt(part, str(image))
            for readonly in (True, False, True):
                DISK.SetNativeExt4Readonly(str(image), readonly)
                self.assertEqual(DISK.IsE2fsReadWrite(SimpleNamespace(disk_image=str(image)), part),
                                 not readonly)
            capacity = DISK.Ext4Capacity(str(image))
            self.assertEqual(capacity["filesystem_bytes"], image.stat().st_size)
            self.assertGreater(capacity["free_bytes"], 0)
            details = run(["dumpe2fs", "-h", image]).decode()
            features = next(line for line in details.splitlines() if line.startswith("Filesystem features:"))
            self.assertIn("metadata_csum", features)
            self.assertNotIn("has_journal", features)
            output = run(["veritysetup", "format", "--hash=sha256", "--data-block-size=4096",
                          "--hash-block-size=4096", "--data-blocks=8192", image, tree]).decode()
            root_hash = next(line.split()[-1] for line in output.splitlines() if line.startswith("Root hash:"))
            run(["veritysetup", "verify", image, tree, root_hash])
            hash_bytes = tree.stat().st_size
            self.assertEqual(DISK.VerityHashBytes(8192, 4096), hash_bytes)
            short_tree = Path(directory) / "short.hash"
            shutil.copyfile(tree, short_tree)
            with short_tree.open("r+b") as stream:
                stream.truncate(hash_bytes - 4096)
            with self.assertRaises(subprocess.CalledProcessError):
                run(["veritysetup", "verify", image, short_tree, root_hash])
            with image.open("r+b") as stream:
                stream.seek(image.stat().st_size - 1)
                original = stream.read(1)
                stream.seek(-1, os.SEEK_CUR)
                stream.write(bytes([original[0] ^ 1]))
            with self.assertRaises(subprocess.CalledProcessError):
                run(["veritysetup", "verify", image, tree, root_hash])


if __name__ == "__main__":
    unittest.main()
