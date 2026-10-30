#!/usr/bin/env python3
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
"""Run an RPM build against a once-filtered view of its upstream repositories."""

import argparse
import configparser
from contextlib import contextmanager
import errno
import gzip
import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import threading
from urllib.parse import unquote, urljoin, urlsplit
from urllib.request import urlopen
import xml.etree.ElementTree as ET
from xml.parsers import expat


REPOMD = "http://linux.duke.edu/metadata/repo"
MAX_METADATA = 512 * 1024 * 1024
MAX_EXPANDED_METADATA = 8 * 1024 * 1024 * 1024
FORMAT_VERSION = 1


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def file_sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def upstream_url(base, href):
    if ".." in unquote(urlsplit(href).path).split("/"):
        raise ValueError(f"Traversing upstream location: {href}")
    url = urljoin(base.rstrip("/") + "/", href)
    parsed = urlsplit(url)
    if (
        parsed.scheme != "https"
        or parsed.netloc != "packages.microsoft.com"
        or not parsed.path.startswith(("/azurelinux/3.0/", "/cbl-mariner/3.0/"))
        or parsed.query
        or parsed.fragment
        or ".." in unquote(parsed.path).split("/")
    ):
        raise ValueError(f"Unsupported upstream URL: {url}")
    return url


def download(url):
    with urlopen(url, timeout=120) as response:
        data = response.read(MAX_METADATA + 1)
    if len(data) > MAX_METADATA:
        raise ValueError(f"Metadata exceeds size limit: {url}")
    return data


def worker_repositories(worker, architecture):
    files = {}
    keys = {}
    with tarfile.open(worker, "r|gz") as archive:
        for member in archive:
            name = member.name.removeprefix("./")
            is_repo = re.fullmatch(r"etc/yum\.repos\.d/[^/]+\.repo", name)
            is_key = re.fullmatch(r"etc/pki/rpm-gpg/[^/]+", name)
            if is_repo or is_key:
                if not member.isfile() or member.size > 1024 * 1024:
                    raise ValueError(f"Invalid worker repository/key file: {name}")
                data = archive.extractfile(member).read()
                if is_repo:
                    files[name] = data.decode()
                else:
                    keys["file:///" + name] = data
    repositories = {}
    for name, text in sorted(files.items()):
        parser = configparser.ConfigParser(interpolation=None)
        parser.read_string(text, source=name)
        for repo_id in parser.sections():
            if repo_id == "mariner-preview":
                continue
            if repo_id in repositories:
                raise ValueError(f"Duplicate worker repository: {repo_id}")
            options = dict(parser[repo_id])
            if "baseurl" not in options or "mirrorlist" in options or "metalink" in options:
                raise ValueError(f"Repository requires a single baseurl: {repo_id}")
            if options.get("repo_gpgcheck", "0").lower() not in ("0", "false", "1", "true"):
                raise ValueError(f"Invalid repo_gpgcheck setting: {repo_id}")
            base = options["baseurl"]
            for variable, value in (("basearch", architecture), ("releasever", "3.0")):
                base = base.replace("${" + variable + "}", value).replace("$" + variable, value)
            if "$" in base or any(char.isspace() for char in base):
                raise ValueError(f"Unresolved worker repository URL: {repo_id}")
            options["baseurl"] = upstream_url(base, "")
            repositories[repo_id] = options
    if not repositories:
        raise ValueError("Worker contains no supported upstream repositories")
    return repositories, keys


def verify_repomd(repomd, signature, keys):
    executable = shutil.which("gpg") or shutil.which("gpg2")
    if executable is None:
        raise ValueError("gpg is required to verify upstream repository metadata")
    with tempfile.TemporaryDirectory(prefix="acl-repomd-verify-") as directory:
        root = Path(directory)
        key_file = root / "keys.asc"
        key_file.write_bytes(b"\n".join(keys))
        (root / "repomd.xml").write_bytes(repomd)
        (root / "repomd.xml.asc").write_bytes(signature)
        command = [executable, "--no-options", "--homedir", directory, "--batch"]
        for operation in (
            ["--import", str(key_file)],
            ["--no-auto-key-retrieve", "--verify",
             str(root / "repomd.xml.asc"), str(root / "repomd.xml")],
        ):
            result = subprocess.run(
                command + operation, capture_output=True, text=True, timeout=60
            )
            if result.returncode:
                raise ValueError(f"Repository signature verification failed: {result.stderr.strip()}")


def filter_stream(source, target, *, cutoff=None, allowed=None, temporary_dir=None):
    """Keep original XML fragments: libsolv depends on the rpm: namespace prefix."""
    parser = expat.ParserCreate()
    depth = 0
    start = None
    root_start = None
    root_end = None
    first_package = None
    count = 0
    declared_count = None
    current = {}
    checksum_text = []
    reading_checksum = False
    kept = 0
    package_ids = set()
    locations = []

    def reject_doctype(*_):
        raise ValueError("DTD declarations are not allowed in repository metadata")

    def begin(name, attrs):
        nonlocal depth, start, root_start, first_package, declared_count, current, checksum_text
        nonlocal reading_checksum
        depth += 1
        local = name.rsplit(":", 1)[-1]
        if depth == 1:
            root_start = parser.CurrentByteIndex
            expected = ("metadata",) if cutoff is not None else ("filelists", "otherdata")
            if local not in expected:
                raise ValueError(f"Unexpected metadata root: {name}")
            declared_count = int(attrs["packages"])
        elif depth == 2:
            if local != "package":
                raise ValueError(f"Unexpected metadata child: {name}")
            start = parser.CurrentByteIndex
            if first_package is None:
                first_package = start
            current = dict(attrs)
            checksum_text = []
        elif depth == 3 and local == "time":
            current["file_time"] = attrs.get("file")
        elif depth == 3 and local == "location":
            if "xml:base" in attrs:
                raise ValueError("Per-package xml:base is unsupported")
            current["location"] = attrs["href"]
        elif depth == 3 and local == "checksum":
            reading_checksum = True

    def text(data):
        if reading_checksum:
            checksum_text.append(data)

    def end(name):
        nonlocal depth, count, root_end, reading_checksum, kept
        local = name.rsplit(":", 1)[-1]
        if depth == 3 and local == "checksum":
            reading_checksum = False
        elif depth == 2:
            count += 1
            if cutoff is not None:
                timestamp = current.get("file_time")
                if timestamp is not None and not re.fullmatch(r"[0-9]+", timestamp):
                    raise ValueError(f"Invalid package publication time: {timestamp}")
                keep = timestamp is not None and int(timestamp) <= cutoff
                pkgid = "".join(checksum_text).strip()
            else:
                pkgid = current["pkgid"]
                keep = pkgid in allowed
            if keep:
                if not re.fullmatch(r"[a-fA-F0-9]{40,128}", pkgid):
                    raise ValueError("Kept package has no valid checksum ID")
                index = parser.CurrentByteIndex
                position = source.tell()
                source.seek(index)
                closing = source.read(256)
                finish = (
                    index + closing.index(b">") + 1
                    if closing.startswith(f"</{name}".encode()) else index
                )
                source.seek(start)
                remaining = finish - start
                while remaining:
                    chunk = source.read(min(remaining, 1024 * 1024))
                    if not chunk:
                        raise ValueError("Unexpected EOF inside package metadata")
                    body.write(chunk)
                    remaining -= len(chunk)
                source.seek(position)
                kept += 1
                package_ids.add(pkgid)
                if cutoff is not None:
                    locations.append(current["location"])
        elif depth == 1:
            root_end = parser.CurrentByteIndex
        depth -= 1

    parser.StartElementHandler = begin
    parser.EndElementHandler = end
    parser.CharacterDataHandler = text
    parser.StartDoctypeDeclHandler = reject_doctype
    with tempfile.TemporaryFile(dir=temporary_dir) as body:
        while chunk := source.read(1024 * 1024):
            parser.Parse(chunk, False)
        parser.Parse(b"", True)
        if count != declared_count or root_end is None:
            raise ValueError("Metadata package count does not match its contents")
        prefix_length = first_package if first_package is not None else root_end
        if prefix_length > 1024 * 1024:
            raise ValueError("Metadata header exceeds size limit")
        source.seek(0)
        prefix = source.read(prefix_length)
        header, replacements = re.subn(
            rb"\bpackages\s*=\s*(['\"])[0-9]+\1",
            b'packages="' + str(kept).encode() + b'"',
            prefix[root_start:],
            count=1,
        )
        if replacements != 1:
            raise ValueError("Metadata root has no package count")
        target.write(prefix[:root_start] + header)
        body.seek(0)
        shutil.copyfileobj(body, target, 1024 * 1024)
        source.seek(root_end)
        shutil.copyfileobj(source, target, 1024 * 1024)
    return package_ids, locations


def filter_packages(raw, *, cutoff=None, allowed=None):
    result = io.BytesIO()
    package_ids, locations = filter_stream(
        io.BytesIO(raw), result, cutoff=cutoff, allowed=allowed
    )
    return result.getvalue(), package_ids, locations


def checksum_algorithm(element):
    if element is None or not element.text:
        raise ValueError("Repository metadata is missing its checksum")
    algorithm = element.attrib["type"]
    algorithm = "sha1" if algorithm == "sha" else algorithm
    if algorithm not in ("sha256", "sha512", "sha1"):
        raise ValueError(f"Unsupported metadata checksum: {algorithm}")
    return algorithm


def verify_checksum(data, element):
    if hashlib.new(checksum_algorithm(element), data).hexdigest() != element.text.strip():
        raise ValueError("Repository metadata checksum mismatch")


@contextmanager
def read_metadata(base, entry, temporary_dir=None):
    location = entry.find(f"{{{REPOMD}}}location")
    if location is None:
        raise ValueError("Repository metadata has no location")
    data = download(upstream_url(base, location.attrib["href"]))
    verify_checksum(data, entry.find(f"{{{REPOMD}}}checksum"))
    opened = entry.find(f"{{{REPOMD}}}open-checksum")
    digest = hashlib.new(checksum_algorithm(opened)) if opened is not None else None
    stream = gzip.GzipFile(fileobj=io.BytesIO(data)) if data.startswith(b"\x1f\x8b") else io.BytesIO(data)
    with stream, tempfile.TemporaryFile(dir=temporary_dir) as raw:
        size = 0
        while chunk := stream.read(1024 * 1024):
            size += len(chunk)
            if size > MAX_EXPANDED_METADATA:
                raise ValueError("Expanded repository metadata exceeds size limit")
            raw.write(chunk)
            if digest is not None:
                digest.update(chunk)
        if digest is not None and digest.hexdigest() != opened.text.strip():
            raise ValueError("Expanded repository metadata checksum mismatch")
        raw.seek(0)
        yield raw


def add_metadata(directory, repomd, kind, raw, cutoff):
    temporary = directory / "repodata" / f"{kind}.xml.gz"
    raw.seek(0)
    digest = hashlib.sha256()
    size = 0
    with temporary.open("wb") as file:
        with gzip.GzipFile(filename="", fileobj=file, mode="wb", compresslevel=1, mtime=0) as packed:
            while chunk := raw.read(1024 * 1024):
                digest.update(chunk)
                size += len(chunk)
                packed.write(chunk)
    compressed_hash = file_sha256(temporary)
    relative = f"repodata/{compressed_hash}-{kind}.xml.gz"
    temporary.rename(directory / relative)
    entry = ET.SubElement(repomd, f"{{{REPOMD}}}data", type=kind)
    for name, value, attrs in (
        ("checksum", compressed_hash, {"type": "sha256"}),
        ("open-checksum", digest.hexdigest(), {"type": "sha256"}),
        ("location", None, {"href": relative}),
        ("timestamp", str(cutoff), {}),
        ("size", str((directory / relative).stat().st_size), {}),
        ("open-size", str(size), {}),
    ):
        node = ET.SubElement(entry, f"{{{REPOMD}}}{name}", attrs)
        node.text = value


def materialize(repositories, cutoff, cache, trusted_keys=None):
    sources = []
    for repo_id, options in repositories.items():
        repomd = download(upstream_url(options["baseurl"], "repodata/repomd.xml"))
        authentication = None
        if options.get("repo_gpgcheck", "0").lower() in ("1", "true"):
            key_names = options.get("gpgkey", "").split()
            if not key_names or any(name not in (trusted_keys or {}) for name in key_names):
                raise ValueError(f"Repository signing key is not available in the worker: {repo_id}")
            signature = download(upstream_url(options["baseurl"], "repodata/repomd.xml.asc"))
            keys = [trusted_keys[name] for name in key_names]
            verify_repomd(repomd, signature, keys)
            authentication = {
                "signature_sha256": sha256(signature),
                "key_sha256": [sha256(key) for key in keys],
            }
        sources.append((repo_id, options, repomd, authentication))
    identity = {
        "format": FORMAT_VERSION,
        "cutoff": cutoff,
        "repositories": [
            [repo_id, options, sha256(repomd), authentication]
            for repo_id, options, repomd, authentication in sources
        ],
    }
    key = sha256(json.dumps(identity, sort_keys=True).encode())
    destination = cache / key
    if destination.exists():
        manifest = json.loads((destination / "provenance.json").read_text())
        if manifest["identity"] != identity:
            raise ValueError("Snapshot cache identity mismatch")
        for name, digest in manifest["files"].items():
            if file_sha256(destination / name) != digest:
                raise ValueError(f"Corrupted snapshot cache file: {name}")
        return destination, manifest

    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="preparing-", dir=cache) as temporary:
        root = Path(temporary)
        manifest = {"identity": identity, "repositories": {}, "files": {}}
        for index, (repo_id, options, repomd_bytes, _) in enumerate(sources):
            source = ET.fromstring(repomd_bytes)
            if source.tag != f"{{{REPOMD}}}repomd":
                raise ValueError(f"Invalid repomd root: {repo_id}")
            entries = {}
            for entry in source.findall(f"{{{REPOMD}}}data"):
                kind = entry.attrib["type"]
                if kind in entries:
                    raise ValueError(f"Duplicate metadata type: {kind}")
                entries[kind] = entry
            if "primary" not in entries:
                raise ValueError(f"Missing primary metadata: {repo_id}")
            slug = f"repo-{index}"
            directory = root / slug
            (directory / "repodata").mkdir(parents=True)
            result = ET.Element(f"{{{REPOMD}}}repomd")
            ET.SubElement(result, f"{{{REPOMD}}}revision").text = str(cutoff)
            with read_metadata(options["baseurl"], entries["primary"], root) as raw:
                with tempfile.TemporaryFile(dir=root) as filtered:
                    package_ids, locations = filter_stream(
                        raw, filtered, cutoff=cutoff, temporary_dir=root
                    )
                    add_metadata(directory, result, "primary", filtered, cutoff)
            for kind in ("filelists", "other"):
                if kind in entries:
                    with read_metadata(options["baseurl"], entries[kind], root) as raw:
                        with tempfile.TemporaryFile(dir=root) as filtered:
                            filter_stream(
                                raw, filtered, allowed=package_ids, temporary_dir=root
                            )
                            add_metadata(directory, result, kind, filtered, cutoff)
            ET.register_namespace("", REPOMD)
            (directory / "repodata" / "repomd.xml").write_bytes(
                ET.tostring(result, encoding="utf-8", xml_declaration=True)
            )
            redirects = {}
            for location in locations:
                url = upstream_url(options["baseurl"], location)
                if not urlsplit(location).scheme:
                    redirects[unquote(location)] = url
            manifest["repositories"][slug] = {
                "id": repo_id, "options": options, "redirects": redirects,
                "packages": len(package_ids),
            }
        manifest["files"] = {
            str(path.relative_to(root)).replace(os.sep, "/"): file_sha256(path)
            for path in sorted(root.glob("repo-*/repodata/*"))
        }
        (root / "provenance.json").write_text(json.dumps(manifest, sort_keys=True))
        # Another build may have published the same immutable view concurrently.
        try:
            root.rename(destination)
        except OSError as error:
            if error.errno not in (errno.EEXIST, errno.ENOTEMPTY):
                raise
            return materialize(repositories, cutoff, cache, trusted_keys)
    return destination, manifest


class SnapshotServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, directory, manifest):
        self.directory = directory
        self.manifest = manifest
        self.token = os.urandom(16).hex()
        super().__init__(("127.0.0.1", 0), SnapshotHandler)


class SnapshotHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parts = unquote(urlsplit(self.path).path).lstrip("/").split("/", 2)
        if len(parts) != 3 or parts[0] != self.server.token:
            self.send_error(404)
            return
        _, slug, relative = parts
        repo = self.server.manifest["repositories"].get(slug)
        filename = f"{slug}/{relative}"
        if repo is None:
            self.send_error(404)
        elif filename in self.server.manifest["files"]:
            with (self.server.directory / filename).open("rb") as stream:
                self.send_response(200)
                self.send_header("Content-Length", str(os.fstat(stream.fileno()).st_size))
                self.end_headers()
                shutil.copyfileobj(stream, self.wfile, 1024 * 1024)
        elif relative in repo["redirects"]:
            self.send_response(302)
            self.send_header("Location", repo["redirects"][relative])
            self.end_headers()
        else:
            self.send_error(404)

    def log_message(self, fmt, *args):
        if len(args) < 2 or str(args[1]) not in ("200", "302"):
            print(f"Snapshot HTTP: {fmt % args}", file=sys.stderr)


def repository_file(server, path):
    parser = configparser.ConfigParser(interpolation=None)
    for slug, repo in server.manifest["repositories"].items():
        options = dict(repo["options"])
        options["baseurl"] = f"http://127.0.0.1:{server.server_port}/{server.token}/{slug}/"
        options["skip_if_unavailable"] = "0"
        options["metadata_expire"] = "never"
        # Upstream signatures were verified before transforming this local view.
        options["repo_gpgcheck"] = "0"
        parser[f"acl-snapshot-{slug}"] = options
    with path.open("w") as stream:
        parser.write(stream, space_around_delimiters=False)


def run_build(directory, manifest, command):
    with SnapshotServer(directory, manifest) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory(prefix="run-", dir=directory.parent) as run:
                repo_file = Path(run) / "snapshot.repo"
                repository_file(server, repo_file)
                args = [
                    *command, f"REPO_LIST={repo_file}", "DISABLE_DEFAULT_REPOS=y",
                    "REPO_SNAPSHOT_TIME=",
                    f"CACHED_RPMS_DIR={directory / 'rpm-cache'}",
                ]
                process = subprocess.Popen(args, start_new_session=True)
                try:
                    return process.wait()
                finally:
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGTERM)
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            os.killpg(process.pid, signal.SIGKILL)
                            process.wait()
        finally:
            server.shutdown()
            thread.join()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worker-tar", type=Path, required=True)
    parser.add_argument("--cutoff", required=True)
    parser.add_argument("--architecture", choices=("aarch64", "x86_64"), required=True)
    parser.add_argument("--cache-dir", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not re.fullmatch(r"[1-9][0-9]{9}", args.cutoff):
        parser.error("cutoff must be a ten-digit Unix timestamp")
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a build command is required after --")
    pkggen = Path("scripts/pkggen.mk").read_text()
    if (
        "$(if $(filter y,$(DISABLE_DEFAULT_REPOS)), --disable-default-repos)" not in pkggen
        or "graphpkgfetcher_extra_flags += --disable-default-repos" not in pkggen
    ):
        raise ValueError("Toolkit lacks the required default-repository isolation controls")
    repos, keys = worker_repositories(args.worker_tar, args.architecture)
    directory, manifest = materialize(repos, int(args.cutoff), args.cache_dir, keys)
    print(f"RPM snapshot view: {directory}", flush=True)

    def interrupted(*_):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    return run_build(directory, manifest, command)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit("Snapshot build interrupted")
    except (OSError, ValueError, KeyError, ET.ParseError, expat.ExpatError,
            configparser.Error, tarfile.TarError) as error:
        sys.exit(f"RPM snapshot preparation failed: {error}")
