import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_usr_filesystem import DISK


@unittest.skipUnless(sys.platform.startswith("linux") and shutil.which("veritysetup"),
                    "Requires existing Linux veritysetup; no automatic installation")
class VerityToolsTests(unittest.TestCase):
    def test_real_verity_size_and_corruption_detection(self):
        def run(command, **kwargs):
            return subprocess.run(list(map(str, command)), check=True, capture_output=True).stdout

        with tempfile.TemporaryDirectory() as directory:
            image, tree = Path(directory) / "usr.data", Path(directory) / "usr.hash"
            with image.open("wb") as stream:
                stream.truncate(32 * 1024**2)
            # Do not preallocate: measure the hash tree actually produced by veritysetup.
            tree.touch()
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
