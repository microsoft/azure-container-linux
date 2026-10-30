#!/usr/bin/env python3
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
"""Linux/root integration check: package equivalence, downloads, and warm timings."""

import argparse
from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import re
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urlsplit
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import materialize_rpm_snapshot as snapshot
from test_materialize_rpm_snapshot import BASE, CUTOFF, REPOS, upstream


@contextmanager
def serve(directory, manifest):
    with snapshot.SnapshotServer(directory, manifest) as server:
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        try:
            yield server
        finally:
            server.shutdown()
            thread.join()


def configuration(root, url):
    (root / "repos").mkdir(parents=True)
    (root / "repos" / "test.repo").write_text(
        f"[comparison]\nbaseurl={url}\nenabled=1\nmetadata_expire=never\n"
        "gpgcheck=0\n"
    )
    config = root / "tdnf.conf"
    config.write_text(
        f"[main]\nreposdir={root / 'repos'}\ncachedir={root / 'cache'}\ngpgcheck=0\n"
    )
    return ["tdnf", "-c", str(config), "--releasever=3.0"]


def run(command, *args, missing=False):
    start = time.perf_counter()
    result = subprocess.run([*command, *args], text=True, capture_output=True, timeout=300)
    elapsed = time.perf_counter() - start
    expected = (0, 243) if missing else (0,)
    if result.returncode not in expected:
        raise RuntimeError(f"{result.args}: {result.returncode}\n{result.stdout}\n{result.stderr}")
    return elapsed, result.returncode, result.stdout


def packages(output):
    return sorted(re.findall(r"^(\S+\.(?:aarch64|x86_64|noarch))\s*:", output, re.MULTILINE))


def compare_query(old, new, cutoff, name):
    left = run(old, "--cacheonly", f"--snapshottime={cutoff}", "provides", name, missing=True)
    right = run(new, "--cacheonly", "provides", name, missing=True)
    if (left[1], packages(left[2])) != (right[1], packages(right[2])):
        raise AssertionError(f"Different selection for {name}:\n{left}\n{right}")
    return packages(left[2])


def boundary_check(root):
    responses = upstream([CUTOFF - 1, CUTOFF, CUTOFF + 1, None])
    original = root / "original"
    for url, data in responses.items():
        path = original / "repo-0" / url.removeprefix(BASE)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    original_manifest = {
        "files": {str(p.relative_to(original)): snapshot.sha256(p.read_bytes())
                  for p in original.rglob("*") if p.is_file()},
        "repositories": {"repo-0": {"options": REPOS["azurelinux-official-base"],
                                    "redirects": {}}},
    }
    with patch.object(snapshot, "download", side_effect=lambda url: responses[url]):
        frozen, manifest = snapshot.materialize(REPOS, CUTOFF, root / "views")
    with serve(original, original_manifest) as before, serve(frozen, manifest) as after:
        old = configuration(root / "old-config", f"http://127.0.0.1:{before.server_port}/{before.token}/repo-0/")
        new = configuration(root / "new-config", f"http://127.0.0.1:{after.server_port}/{after.token}/repo-0/")
        run(old, "makecache", "-y")
        run(new, "makecache", "-y")
        selected = compare_query(old, new, CUTOFF, "snapshot-demo")
        if selected != ["snapshot-demo-1-1.noarch", "snapshot-demo-2-1.noarch"]:
            raise AssertionError(f"Cutoff boundary or missing timestamp was not enforced: {selected}")
        return selected


def live_check(root):
    cutoff = 1793282824
    start = time.perf_counter()
    repos = {name: {**options, "repo_gpgcheck": "1"} for name, options in REPOS.items()}
    key_uri = repos["azurelinux-official-base"]["gpgkey"]
    keys = {key_uri: Path(urlsplit(key_uri).path).read_bytes()}
    frozen, manifest = snapshot.materialize(repos, cutoff, root / "live-views", keys)
    prepare_seconds = time.perf_counter() - start
    old = configuration(root / "live-old", BASE)
    run(old, "makecache", "-y")
    metadata = list((root / "live-old" / "cache").rglob("repomd.xml"))
    expected_hash = manifest["identity"]["repositories"][0][2]
    if not any(snapshot.sha256(p.read_bytes()) == expected_hash for p in metadata):
        raise AssertionError("Live repository changed between old/new metadata capture")
    with serve(frozen, manifest) as server:
        new = configuration(
            root / "live-new", f"http://127.0.0.1:{server.server_port}/{server.token}/repo-0/"
        )
        run(new, "makecache", "-y")
        selected = {
            name: compare_query(old, new, cutoff, name)
            for name in ("sed", "cargo", "acl-nonexistent-snapshot-package")
        }
        timings = {"old": [], "new": []}
        for iteration in range(3):
            order = ("old", "new") if iteration % 2 == 0 else ("new", "old")
            for mode in order:
                command = old if mode == "old" else new
                flags = [f"--snapshottime={cutoff}"] if mode == "old" else []
                elapsed, _, _ = run(command, "--cacheonly", *flags, "provides", "sed")
                timings[mode].append(elapsed)
        downloaded = {}
        for mode, command in (("old", old), ("new", new)):
            destination = root / f"downloads-{mode}"
            destination.mkdir()
            flags = [f"--snapshottime={cutoff}"] if mode == "old" else []
            run(command, *flags, "reinstall", "--downloadonly", "--nodeps", "-y",
                "--downloaddir", str(destination), "sed")
            downloaded[mode] = {
                p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                for p in destination.glob("*.rpm")
            }
        if not downloaded["old"] or downloaded["old"] != downloaded["new"]:
            raise AssertionError(f"Different downloaded packages: {downloaded}")
        return {
            "cutoff": cutoff, "source_repomd_sha256": expected_hash,
            "prepare_seconds": prepare_seconds, "selection": selected,
            "timings": timings,
            "median_seconds": {mode: statistics.median(values) for mode, values in timings.items()},
            "downloaded": downloaded["new"],
        }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="acl-snapshot-equivalence-") as directory:
        root = Path(directory)
        result = {
            "tdnf": subprocess.check_output(["rpm", "-q", "tdnf"], text=True).strip(),
            "boundary_selection": boundary_check(root),
            "live": live_check(root),
        }
        args.output.write_text(json.dumps(result, indent=2))
        print(json.dumps(result))


if __name__ == "__main__":
    main()
