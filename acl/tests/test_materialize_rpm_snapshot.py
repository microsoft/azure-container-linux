#!/usr/bin/env python3
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

import gzip
import hashlib
import http.client
import io
from pathlib import Path
import sys
import tarfile
import tempfile
import threading
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import materialize_rpm_snapshot as snapshot


CUTOFF = 1700000000
BASE = "https://packages.microsoft.com/azurelinux/3.0/prod/base/aarch64/"
COMMON = "http://linux.duke.edu/metadata/common"
REPOS = {"azurelinux-official-base": {
    "name": "Base", "baseurl": BASE, "enabled": "1", "gpgcheck": "1",
    "gpgkey": "file:///etc/pki/rpm-gpg/MICROSOFT-RPM-GPG-KEY",
}}


def primary(times):
    packages = []
    for version, timestamp in enumerate(times, 1):
        pkgid = hashlib.sha256(f"version-{version}".encode()).hexdigest()
        published = "" if timestamp is None else f' file="{timestamp}"'
        packages.append(
            '<package type="rpm"><name>snapshot-demo</name><arch>noarch</arch>'
            f'<version epoch="0" ver="{version}" rel="1"/>'
            f'<checksum type="sha256" pkgid="YES">{pkgid}</checksum>'
            '<summary>Snapshot test package</summary><description>Snapshot fixture</description>'
            '<packager>ACL tests</packager><url>https://example.invalid</url>'
            f'<time build="1600000000"{published}/>'
            '<size package="10" installed="10" archive="10"/>'
            f'<location href="Packages/s/snapshot-demo-{version}-1.noarch.rpm"/>'
            '<format><rpm:provides>'
            f'<rpm:entry name="snapshot-demo" flags="EQ" epoch="0" ver="{version}" rel="1"/>'
            '</rpm:provides></format></package>'
        )
    return (
        '<?xml version="1.0"?>'
        f'<metadata xmlns="{COMMON}" xmlns:rpm="http://linux.duke.edu/metadata/rpm" '
        f'packages="{len(packages)}">'
        + "".join(packages) + "</metadata>"
    ).encode()


def ancillary(kind, versions):
    root = "filelists" if kind == "filelists" else "otherdata"
    records = "".join(
        '<package pkgid="' + hashlib.sha256(f"version-{version}".encode()).hexdigest()
        + f'" name="snapshot-demo" arch="noarch"><version epoch="0" ver="{version}" rel="1"/>'
        + ("<file>/usr/bin/snapshot-demo</file>" if kind == "filelists" else "")
        + "</package>"
        for version in versions
    )
    return (
        f'<{root} xmlns="http://linux.duke.edu/metadata/{kind}" packages="{len(versions)}">'
        f"{records}</{root}>"
    ).encode()


def upstream(times):
    ET.register_namespace("", snapshot.REPOMD)
    index = ET.Element(f"{{{snapshot.REPOMD}}}repomd")
    ET.SubElement(index, f"{{{snapshot.REPOMD}}}revision").text = str(CUTOFF)
    responses = {}
    data = {"primary": primary(times)}
    for kind in ("filelists", "other"):
        data[kind] = ancillary(kind, list(range(1, len(times) + 1)))
    for kind, raw in data.items():
        packed = gzip.compress(raw, mtime=0)
        href = f"repodata/{kind}.xml.gz"
        entry = ET.SubElement(index, f"{{{snapshot.REPOMD}}}data", type=kind)
        ET.SubElement(entry, f"{{{snapshot.REPOMD}}}location", href=href)
        ET.SubElement(entry, f"{{{snapshot.REPOMD}}}checksum", type="sha256").text = snapshot.sha256(packed)
        ET.SubElement(entry, f"{{{snapshot.REPOMD}}}open-checksum", type="sha256").text = snapshot.sha256(raw)
        ET.SubElement(entry, f"{{{snapshot.REPOMD}}}timestamp").text = str(CUTOFF)
        ET.SubElement(entry, f"{{{snapshot.REPOMD}}}size").text = str(len(packed))
        ET.SubElement(entry, f"{{{snapshot.REPOMD}}}open-size").text = str(len(raw))
        responses[BASE + href] = packed
    responses[BASE + "repodata/repomd.xml"] = ET.tostring(index)
    return responses


class FilterTests(unittest.TestCase):
    def test_cutoff_is_inclusive_and_missing_time_is_excluded(self):
        raw = primary([CUTOFF - 1, CUTOFF, CUTOFF + 1, None])
        filtered, package_ids, locations = snapshot.filter_packages(raw, cutoff=CUTOFF)
        tree = ET.fromstring(filtered)
        self.assertEqual(tree.attrib["packages"], "2")
        self.assertEqual(
            [p.find(f"{{{COMMON}}}version").attrib["ver"] for p in tree], ["1", "2"]
        )
        self.assertEqual(len(package_ids), 2)
        self.assertEqual(len(locations), 2)
        self.assertIn(b'<rpm:entry name="snapshot-demo"', filtered)
        self.assertIn(b'xmlns:rpm="http://linux.duke.edu/metadata/rpm"', filtered)

    def test_malformed_time_and_dtd_are_rejected(self):
        for raw in (
            primary(["invalid"]),
            primary([CUTOFF]).replace(b'<?xml version="1.0"?>', b'<!DOCTYPE metadata []>'),
        ):
            with self.subTest(raw=raw[:80]), self.assertRaises(ValueError):
                snapshot.filter_packages(raw, cutoff=CUTOFF)

    def test_empty_snapshot_and_ancillary_pruning(self):
        _, allowed, _ = snapshot.filter_packages(
            primary([CUTOFF, CUTOFF + 1]), cutoff=CUTOFF
        )
        for kind in ("filelists", "other"):
            filtered, _, _ = snapshot.filter_packages(
                ancillary(kind, [1, 2]), allowed=allowed
            )
            root = ET.fromstring(filtered)
            self.assertEqual(root.attrib["packages"], "1")
            self.assertEqual(root[0].attrib["pkgid"], next(iter(allowed)))
        filtered, _, _ = snapshot.filter_packages(primary([CUTOFF + 1]), cutoff=CUTOFF)
        self.assertEqual(len(ET.fromstring(filtered)), 0)

    def test_count_mismatch_fails(self):
        with self.assertRaises(ValueError):
            snapshot.filter_packages(
                primary([CUTOFF]).replace(b'packages="1"', b'packages="2"'),
                cutoff=CUTOFF,
            )

    def test_fragment_offsets_across_stream_chunks_and_self_closing_records(self):
        long_text = b"x" * 700000
        raw = primary([CUTOFF + 1, CUTOFF]).replace(b"Snapshot test package", long_text)
        filtered, allowed, _ = snapshot.filter_packages(raw, cutoff=CUTOFF)
        root = ET.fromstring(filtered)
        self.assertEqual(root.attrib["packages"], "1")
        self.assertEqual(root[0].find(f"{{{COMMON}}}summary").text, long_text.decode())
        raw = (
            '<filelists xmlns="http://linux.duke.edu/metadata/filelists" packages="1">'
            f'<package pkgid="{next(iter(allowed))}" /></filelists>'
        ).encode()
        filtered, _, _ = snapshot.filter_packages(raw, allowed=allowed)
        self.assertEqual(len(ET.fromstring(filtered)), 1)


class RepositoryTests(unittest.TestCase):
    def test_worker_inventory_includes_disabled_feeds_and_preserves_trust(self):
        with tempfile.TemporaryDirectory() as temporary:
            worker = Path(temporary) / "worker.tar.gz"
            text = (
                "[azurelinux-official-base]\n"
                "baseurl=https://packages.microsoft.com/azurelinux/$releasever/prod/base/$basearch\n"
                "enabled=0\ngpgcheck=1\nrepo_gpgcheck=1\n"
                "gpgkey=file:///etc/pki/rpm-gpg/MICROSOFT-RPM-GPG-KEY\n"
                "[mariner-preview]\nbaseurl=https://example.invalid/preview\n"
            ).encode()
            with tarfile.open(worker, "w:gz") as archive:
                info = tarfile.TarInfo("./etc/yum.repos.d/test.repo")
                info.size = len(text)
                archive.addfile(info, io.BytesIO(text))
                key = tarfile.TarInfo("./etc/pki/rpm-gpg/MICROSOFT-RPM-GPG-KEY")
                key.size = 10
                archive.addfile(key, io.BytesIO(b"public-key"))
            repos, keys = snapshot.worker_repositories(worker, "aarch64")
            self.assertEqual(list(repos), ["azurelinux-official-base"])
            self.assertEqual(repos["azurelinux-official-base"]["baseurl"], BASE)
            self.assertEqual(repos["azurelinux-official-base"]["enabled"], "0")
            self.assertEqual(repos["azurelinux-official-base"]["gpgcheck"], "1")
            self.assertEqual(keys[repos["azurelinux-official-base"]["gpgkey"]], b"public-key")

    def test_untrusted_or_traversing_urls_fail(self):
        for href in (
            "https://example.invalid/repo", "//example.invalid/repo",
            "repodata/%2e%2e/secret", "repodata/../secret", "repodata/x?token=secret",
        ):
            with self.subTest(href=href), self.assertRaises(ValueError):
                snapshot.upstream_url(BASE, href)

    def test_materialized_view_cache_and_invalidation(self):
        responses = upstream([CUTOFF, CUTOFF + 1])
        with tempfile.TemporaryDirectory() as temporary, patch.object(
            snapshot, "download", side_effect=lambda url: responses[url]
        ) as fetch:
            root, manifest = snapshot.materialize(REPOS, CUTOFF, Path(temporary))
            self.assertEqual(manifest["repositories"]["repo-0"]["packages"], 1)
            self.assertEqual(len(manifest["files"]), 4)
            fetch.reset_mock()
            reused, _ = snapshot.materialize(REPOS, CUTOFF, Path(temporary))
            self.assertEqual(root, reused)
            self.assertEqual(fetch.call_count, 1)
            changed_cutoff, _ = snapshot.materialize(REPOS, CUTOFF + 1, Path(temporary))
            self.assertNotEqual(root, changed_cutoff)
            responses.update(upstream([CUTOFF - 1, CUTOFF + 1]))
            changed_metadata, _ = snapshot.materialize(REPOS, CUTOFF, Path(temporary))
            self.assertNotEqual(root, changed_metadata)

    def test_checksum_failure_never_publishes_a_view(self):
        responses = upstream([CUTOFF])
        responses[BASE + "repodata/primary.xml.gz"] += b"corruption"
        with tempfile.TemporaryDirectory() as temporary, patch.object(
            snapshot, "download", side_effect=lambda url: responses[url]
        ):
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                snapshot.materialize(REPOS, CUTOFF, Path(temporary))
            self.assertEqual(list(Path(temporary).glob("*/provenance.json")), [])

    def test_signed_metadata_requires_worker_key_and_valid_signature(self):
        responses = upstream([CUTOFF])
        responses[BASE + "repodata/repomd.xml.asc"] = b"signature"
        repos = {name: {**options, "repo_gpgcheck": "1"} for name, options in REPOS.items()}
        key_name = repos["azurelinux-official-base"]["gpgkey"]
        with tempfile.TemporaryDirectory() as temporary, patch.object(
            snapshot, "download", side_effect=lambda url: responses[url]
        ):
            cache = Path(temporary)
            with self.assertRaisesRegex(ValueError, "signing key"):
                snapshot.materialize(repos, CUTOFF, cache)
            with patch.object(snapshot, "verify_repomd", side_effect=ValueError("bad signature")):
                with self.assertRaisesRegex(ValueError, "bad signature"):
                    snapshot.materialize(repos, CUTOFF, cache, {key_name: b"key"})
            self.assertEqual(list(cache.glob("*/provenance.json")), [])
            with patch.object(snapshot, "verify_repomd") as verify:
                _, manifest = snapshot.materialize(repos, CUTOFF, cache, {key_name: b"key"})
                verify.assert_called_once_with(
                    responses[BASE + "repodata/repomd.xml"], b"signature", [b"key"]
                )
                self.assertEqual(
                    manifest["identity"]["repositories"][0][3]["key_sha256"],
                    [snapshot.sha256(b"key")],
                )

    def test_corrupted_cached_metadata_fails_closed(self):
        responses = upstream([CUTOFF])
        with tempfile.TemporaryDirectory() as temporary, patch.object(
            snapshot, "download", side_effect=lambda url: responses[url]
        ):
            root, manifest = snapshot.materialize(REPOS, CUTOFF, Path(temporary))
            (root / next(iter(manifest["files"]))).write_bytes(b"corrupted")
            with self.assertRaisesRegex(ValueError, "Corrupted snapshot"):
                snapshot.materialize(REPOS, CUTOFF, Path(temporary))

    def test_http_serves_only_frozen_metadata_and_eligible_package_redirects(self):
        responses = upstream([CUTOFF, CUTOFF + 1])
        with tempfile.TemporaryDirectory() as temporary, patch.object(
            snapshot, "download", side_effect=lambda url: responses[url]
        ):
            root, manifest = snapshot.materialize(REPOS, CUTOFF, Path(temporary))
            with snapshot.SnapshotServer(root, manifest) as server:
                thread = threading.Thread(target=server.serve_forever)
                thread.start()
                try:
                    repo_file = Path(temporary) / "view.repo"
                    snapshot.repository_file(server, repo_file)
                    config = repo_file.read_text()
                    self.assertIn("gpgcheck=1", config)
                    self.assertIn("skip_if_unavailable=0", config)
                    connection = http.client.HTTPConnection(*server.server_address)
                    prefix = f"/{server.token}/repo-0/"
                    cases = (
                        ("repodata/repomd.xml", 200),
                        ("Packages/s/snapshot-demo-1-1.noarch.rpm", 302),
                        ("Packages/s/snapshot-demo-2-1.noarch.rpm", 404),
                        ("../../provenance.json", 404),
                    )
                    for suffix, expected in cases:
                        with self.subTest(suffix=suffix):
                            connection.request("GET", prefix + suffix)
                            result = connection.getresponse()
                            self.assertEqual(result.status, expected)
                            if expected == 302:
                                self.assertEqual(result.getheader("Location"), BASE + suffix)
                            result.read()
                    connection.close()
                finally:
                    server.shutdown()
                    thread.join()


if __name__ == "__main__":
    unittest.main()
