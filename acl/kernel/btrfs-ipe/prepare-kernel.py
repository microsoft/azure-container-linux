#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Render an experimental spec tree without modifying the stock ACL specs."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
FILES = (
    "kernel.spec", "kernel.signatures.json", "config", "config_aarch64",
    "sha512hmac-openssl.sh", "azurelinux-ca-20230216.pem", "cpupower",
    "cpupower.service", "0001-add-mstflint-kernel-4.28.0.patch",
)


def render_spec(spec, version, release):
    old = f"Version:        {version}\nRelease:        1%{{?dist}}\n"
    if (spec.count(old) != 1 or spec.splitlines().count("%prep") != 1
            or spec.count("\nBuildRequires:  audit-devel") != 1
            or "Patch1:" in spec
            or "%autosetup -p1" not in spec):
        raise ValueError("Unexpected upstream kernel spec; refusing an unverified override")
    spec = spec.replace(old, f"Version:        {version}\nRelease:        {release}%{{?dist}}\n")
    return spec.replace("\nBuildRequires:  audit-devel", "\nPatch1:         btrfs-ipe.patch\nBuildRequires:  audit-devel", 1)


def prepare(azurelinux, base, output):
    metadata = json.loads((HERE / "source.json").read_text())
    commit = metadata["azurelinux_commit"]
    actual = subprocess.check_output(
        ["git", "-C", str(azurelinux), "rev-parse", "HEAD"], text=True
    ).strip()
    if actual != commit:
        raise ValueError(f"Expected Azure Linux toolkit {commit}, found {actual}; use a fresh build directory")
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError("Output spec directory must be empty")
    shutil.copytree(base, output, dirs_exist_ok=True)
    target = output / "kernel"
    target.mkdir()
    for name in FILES:
        data = subprocess.check_output(["git", "-C", str(azurelinux), "show", f"{commit}:SPECS/kernel/{name}"])
        (target / name).write_bytes(data)
    spec = (target / "kernel.spec").read_text()
    (target / "kernel.spec").write_text(
        render_spec(spec, metadata["version"], metadata["release"]), newline="\n"
    )
    patch = (HERE / "btrfs-ipe.patch").read_bytes().replace(b"\r\n", b"\n")
    (target / "btrfs-ipe.patch").write_bytes(patch)
    metadata["patch_sha256"] = hashlib.sha256(patch).hexdigest()
    signatures = json.loads((target / "kernel.signatures.json").read_text())
    signatures["Signatures"]["btrfs-ipe.patch"] = metadata["patch_sha256"]
    (target / "kernel.signatures.json").write_text(json.dumps(signatures, indent=2) + "\n")
    return metadata


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--azurelinux", required=True, type=Path)
    parser.add_argument("--base", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    args = parser.parse_args()
    metadata = prepare(args.azurelinux, args.base, args.output)
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.write_text(json.dumps(metadata, indent=2) + "\n")
