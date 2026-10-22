#!/usr/bin/env python3
"""Exercise snapshot filtering through DNF's repository query and download paths."""

import gzip
import hashlib
import subprocess
import tempfile
from pathlib import Path
from xml.etree import ElementTree as ET


CUTOFF = 1700000000
COMMON = "http://linux.duke.edu/metadata/common"
RPM = "http://linux.duke.edu/metadata/rpm"
REPOMD = "http://linux.duke.edu/metadata/repo"
ET.register_namespace("rpm", RPM)


def element(parent, tag, text=None, **attributes):
    child = ET.SubElement(parent, tag, attributes)
    child.text = text
    return child


def write_repo(directory, packages):
    directory.mkdir()
    metadata = ET.Element(f"{{{COMMON}}}metadata", {"packages": str(len(packages))})
    for name, version, published in packages:
        filename = f"{name}-{version}-1.noarch.rpm"
        payload = filename.encode()
        (directory / filename).write_bytes(payload)
        package = element(metadata, f"{{{COMMON}}}package", type="rpm")
        element(package, f"{{{COMMON}}}name", name)
        element(package, f"{{{COMMON}}}arch", "noarch")
        element(package, f"{{{COMMON}}}version", epoch="0", ver=version, rel="1")
        element(
            package,
            f"{{{COMMON}}}checksum",
            hashlib.sha256(payload).hexdigest(),
            type="sha256",
            pkgid="YES",
        )
        element(package, f"{{{COMMON}}}summary", filename)
        element(package, f"{{{COMMON}}}description", filename)
        element(package, f"{{{COMMON}}}packager", "SDK test")
        element(package, f"{{{COMMON}}}url", "https://example.invalid")
        time_attrs = {"build": str(CUTOFF - 100)}
        if published is not None:
            time_attrs["file"] = str(published)
        element(package, f"{{{COMMON}}}time", **time_attrs)
        size = str(len(payload))
        element(package, f"{{{COMMON}}}size", package=size, installed=size, archive=size)
        element(package, f"{{{COMMON}}}location", href=filename)
        element(package, f"{{{COMMON}}}format")

    ET.register_namespace("", COMMON)
    raw = ET.tostring(metadata, encoding="utf-8", xml_declaration=True)
    compressed = gzip.compress(raw, mtime=0)
    repodata = directory / "repodata"
    repodata.mkdir()
    (repodata / "primary.xml.gz").write_bytes(compressed)
    index = ET.Element(f"{{{REPOMD}}}repomd")
    entry = element(index, f"{{{REPOMD}}}data", type="primary")
    element(entry, f"{{{REPOMD}}}checksum", hashlib.sha256(compressed).hexdigest(), type="sha256")
    element(entry, f"{{{REPOMD}}}open-checksum", hashlib.sha256(raw).hexdigest(), type="sha256")
    element(entry, f"{{{REPOMD}}}location", href="repodata/primary.xml.gz")
    element(entry, f"{{{REPOMD}}}timestamp", str(CUTOFF))
    element(entry, f"{{{REPOMD}}}size", str(len(compressed)))
    element(entry, f"{{{REPOMD}}}open-size", str(len(raw)))
    ET.register_namespace("", REPOMD)
    (repodata / "repomd.xml").write_bytes(ET.tostring(index, encoding="utf-8", xml_declaration=True))


def main():
    with tempfile.TemporaryDirectory(prefix="dnf5-snapshot-") as temporary:
        root = Path(temporary)
        write_repo(
            root / "upstream",
            [
                ("snapshot-demo", "1", CUTOFF - 1),
                ("snapshot-demo", "2", CUTOFF),
                ("snapshot-demo", "3", CUTOFF + 1),
                ("snapshot-demo", "4", None),
                ("grub2", "1", CUTOFF - 1),
                ("grub2", "2", CUTOFF + 1),
            ],
        )
        write_repo(
            root / "local",
            [("grub2", "9", CUTOFF + 1), ("snapshot-local", "1", CUTOFF + 1)],
        )
        repos = root / "repos"
        repos.mkdir()
        (repos / "snapshot.repo").write_text(
            "[snapshot-test]\n"
            f"baseurl={(root / 'upstream').as_uri()}\n"
            "enabled=1\ngpgcheck=0\n"
            "[azurelinux-local-cache]\n"
            f"baseurl={(root / 'local').as_uri()}\n"
            "enabled=1\ngpgcheck=0\npriority=1\n"
            "excludepkgs=grub2 grub2-efi grub2-efi-binary shim systemd-boot\n"
        )
        base = [
            "/usr/bin/dnf5",
            "--quiet",
            f"--setopt=reposdir={repos}",
            f"--setopt=cachedir={root / 'cache'}",
            "--disable-repo=*",
            "--enable-repo=snapshot-test",
            "--enable-repo=azurelinux-local-cache",
        ]

        def run(*args):
            try:
                return subprocess.run(
                    [*base, *args], check=True, text=True, capture_output=True
                ).stdout
            except subprocess.CalledProcessError as error:
                raise RuntimeError(
                    f"DNF5 failed: {error.cmd!r}\n"
                    f"stdout:\n{error.stdout}\nstderr:\n{error.stderr}"
                ) from error

        def versions(time, package):
            output = run(
                f"--snapshot-time={time}",
                "--snapshot-exclude-repos=azurelinux-local-cache",
                "repoquery",
                "--available",
                "--queryformat=%{name}-%{version}\n",
                package,
            )
            return set(output.splitlines())

        for time, expected in [
            (CUTOFF - 2, set()),
            (CUTOFF - 1, {"snapshot-demo-1"}),
            (CUTOFF, {"snapshot-demo-1", "snapshot-demo-2"}),
            (CUTOFF + 1, {"snapshot-demo-1", "snapshot-demo-2", "snapshot-demo-3"}),
        ]:
            actual = versions(time, "snapshot-demo")
            if actual != expected:
                raise AssertionError(f"snapshot-demo at {time}: expected {expected}, got {actual}")

        if versions(CUTOFF, "snapshot-local") != {"snapshot-local-1"}:
            raise AssertionError("Locally built packages must remain eligible after the cutoff")
        if versions(CUTOFF, "grub2") != {"grub2-1"}:
            raise AssertionError("Retained local or newer upstream bootloader RPM bypassed the cutoff")

        destination = root / "downloads"
        run(
            f"--snapshot-time={CUTOFF}",
            "--snapshot-exclude-repos=azurelinux-local-cache",
            "--disable-repo=azurelinux-local-cache",
            "download",
            f"--destdir={destination}",
            "grub2",
            "snapshot-demo",
        )
        actual = {path.name for path in destination.iterdir()}
        expected = {"grub2-1-1.noarch.rpm", "snapshot-demo-2-1.noarch.rpm"}
        if actual != expected:
            raise AssertionError(f"Downloaded {actual}, expected {expected}")


if __name__ == "__main__":
    main()
