"""Report ACL/ACL-T package decisions and removal candidates from an explicit TOML policy."""

from __future__ import annotations

import argparse
import csv
import fcntl
import hashlib
import html
import json
import os
import platform
import re
import shlex
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import threading
import time
import tomllib
import urllib.parse
import urllib.request
from collections import deque
from collections.abc import Callable, Generator, Mapping, Sequence
from contextlib import closing, contextmanager
from dataclasses import asdict, dataclass
from graphlib import CycleError, TopologicalSorter
from pathlib import Path
from typing import Any, BinaryIO, cast

TOOLS_IMAGE = "mcr.microsoft.com/azurelinux/base/core:3.0"
OCI_ARCHES_BY_NATIVE_ARCH = {"x86_64": "amd64", "aarch64": "arm64"}
ADO_RESOURCE = "499b84ac-1321-427f-aa17-267ca6975798"
CSV_HEADER = ("NVRA", "Size (MiB)", "Keep", "Reason", "Dependants Count", "Top-level Dependents")
RPM_FORMAT = "%{NAME}\\t%{VERSION}\\t%{RELEASE}\\t%{ARCH}\\t%{SIZE}\\n"
MAX_DB_BYTES = 256 * 1024 * 1024
MAX_IMAGE_BYTES = 128 * 1024 ** 3
MAX_OS_RELEASE_BYTES = 64 * 1024


class InventoryError(ValueError):
    """An input or external tool cannot support this inventory."""


def run(
    args: Sequence[str],
    *,
    timeout: int = 300,
    env: Mapping[str, str] | None = None,
) -> str:
    """Never invoke a shell, including for capabilities containing parentheses."""
    if env is None:
        result = subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)
    else:
        result = subprocess.run(
            args,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
            env=env,
        )

    if result.returncode:
        raise InventoryError(
            f"{args[0]} failed ({result.returncode}): "
            f"{result.stderr.strip() or result.stdout.strip()}",
        )

    return result.stdout


def root_run(args: Sequence[str], *, timeout: int = 300) -> str:
    return run([*(["sudo", "-n"] if os.geteuid() else []), *args], timeout=timeout)


def as_object(value: object) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise InventoryError("Unexpected JSON object in upstream response")

    return cast("dict[str, Any]", value)


def json_request(url: str, token: str, body: object | None = None) -> dict[str, Any]:
    payload = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(
        url,
        data=payload,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )

    with urllib.request.urlopen(request, timeout=120) as response:
        value: object = json.load(response)

    return as_object(value)


def artifact_files(
    artifact_nodes: object,
    filename: str | None,
    max_bytes: int,
) -> list[tuple[str, int]]:
    """Read the ADO artifact-browser tree; this read-only UI API is undocumented."""
    if not isinstance(artifact_nodes, list):
        raise InventoryError("Artifact-browser response has no file tree")

    matched_files: list[tuple[str, int]] = []

    for raw in cast(list[object], artifact_nodes):
        node = as_object(raw)
        source = node.get("sourcePath")
        selected = False
        if isinstance(source, str):
            selected = Path(source).name == filename if filename is not None else source.endswith("_rpmdb.sqlite")

        if selected:
            size = node.get("size")
            if not isinstance(size, int) or not 16 <= size <= max_bytes:
                file_kind = "RPM database" if filename is None else "file"
                raise InventoryError(f"Unexpected {file_kind} size in artifact")

            matched_files.append((str(source), size))

        child_nodes: object = node.get("items", [])
        if child_nodes is None and isinstance(source, str):
            child_nodes = []  # Azure DevOps emits items:null on file nodes.
        matched_files.extend(artifact_files(child_nodes, filename, max_bytes))

    return matched_files


def single_file_url(download_url: str, source: str) -> str:
    parsed = urllib.parse.urlsplit(download_url)
    if (parsed.scheme != "https" or parsed.username or parsed.password
            or not (parsed.hostname or "").endswith(".artifacts.visualstudio.com")):
        raise InventoryError("Unexpected artifact download host; refusing to send credentials")

    query = urllib.parse.urlencode({"format": "file", "subPath": source})
    file_url = parsed._replace(query=query)

    return urllib.parse.urlunsplit(file_url)


def validate_database(path: Path) -> None:
    with path.open("rb") as stream:
        if stream.read(16) != b"SQLite format 3\0":
            raise InventoryError(f"Not a SQLite RPM database: {path}")

    with closing(sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)) as connection:
        integrity_check_rows: list[tuple[str]] = connection.execute("PRAGMA quick_check").fetchall()
        if integrity_check_rows != [("ok",)]:
            raise InventoryError(f"SQLite integrity check failed: {path}")

        table_names_query = "SELECT name FROM sqlite_master WHERE type='table'"
        table_names = {str(row[0]) for row in connection.execute(table_names_query)}
        if "Packages" not in table_names:
            raise InventoryError(f"SQLite database has no RPM Packages table: {path}")


def backup_database(source: Path, destination: Path) -> None:
    """Copy directly unless a nonempty WAL needs merging into the snapshot."""
    wal = Path(str(source) + "-wal")
    if not wal.exists() or wal.stat().st_size == 0:
        shutil.copyfile(source, destination)
        validate_database(destination)

        return

    temporary = destination.with_suffix(".backup-partial")
    temporary.unlink(missing_ok=True)

    try:
        with closing(sqlite3.connect(source.resolve().as_uri() + "?mode=ro", uri=True)) as reader:
            with closing(sqlite3.connect(temporary)) as writer:
                reader.backup(writer)

        validate_database(temporary)
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def parse_acl_build(value: str) -> int:
    try:
        build = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError("must be a positive build ID") from None

    if build <= 0:
        raise argparse.ArgumentTypeError("must be a positive build ID")

    return build


def download_acl(
    work: Path,
    build: int,
    *,
    acl_template: bool = False,
) -> tuple[Path, dict[str, object]]:
    if type(build) is not int or build <= 0:
        raise InventoryError("Downloading requires a positive numeric build ID")

    download_kind = "image" if acl_template else "RPM database"
    print(f"Downloading {download_kind} from build {build}...", flush=True)

    oci_arch = OCI_ARCHES_BY_NATIVE_ARCH[native_architecture()]
    if acl_template:
        artifact_name = f"drop_build_acl_template_{oci_arch}_customize_and_sign"
    else:
        artifact_name = f"drop_build_rpm_image_{oci_arch}_build_azure"

    token_command = [
        "az",
        "account",
        "get-access-token",
        "--resource",
        ADO_RESOURCE,
        "--query",
        "accessToken",
        "--output",
        "tsv",
    ]

    # Capture the Azure CLI token privately; never log it or put it in a URL.
    token = run(token_command).strip()
    if not token or any(character.isspace() for character in token):
        raise InventoryError("Azure CLI did not return an access token; run az login")

    base = "https://dev.azure.com/mariner-org"
    build_info = json_request(f"{base}/ACL/_apis/build/builds/{build}?api-version=7.1", token)
    project = as_object(build_info["project"])
    project_id = str(project["id"])

    artifact_query = urllib.parse.urlencode({"artifactName": artifact_name, "api-version": "7.1"})
    artifact_url = f"{base}/{project_id}/_apis/build/builds/{build}/artifacts?{artifact_query}"
    artifact = json_request(artifact_url, token)
    resource = as_object(artifact["resource"])
    if resource.get("type") != "PipelineArtifact":
        raise InventoryError("Expected an Azure DevOps PipelineArtifact")

    tree_body: dict[str, object] = {
        "contributionIds": ["ms.vss-build-web.run-artifacts-data-provider"],
        "dataProviderContext": {
            "properties": {
                "artifactId": artifact["id"],
                "buildId": build,
                "sourcePage": {"routeValues": {"project": "ACL"}},
            },
        },
    }
    tree_url = f"{base}/_apis/Contribution/HierarchyQuery/project/{project_id}?api-version=7.1-preview.1"
    tree = json_request(tree_url, token, tree_body)
    providers_by_id = as_object(tree["dataProviders"])
    provider = as_object(providers_by_id["ms.vss-build-web.run-artifacts-data-provider"])

    if acl_template:
        selected_file = "acl_template_image.vhdx"
        matched_files = artifact_files(
            provider["items"],
            selected_file,
            MAX_IMAGE_BYTES,
        )
    else:
        selected_file = "*_rpmdb.sqlite"
        matched_files = artifact_files(provider["items"], None, MAX_DB_BYTES)

    if len(matched_files) != 1:
        raise InventoryError(f"Expected one {selected_file} in {artifact_name}; got {matched_files}")

    source, size = matched_files[0]
    target = work / ("acl-t-image.vhdx" if acl_template else "acl-rpmdb.sqlite")
    url = single_file_url(str(resource["downloadUrl"]), source)
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    temporary = target.with_suffix(".partial")

    try:
        with urllib.request.urlopen(request, timeout=120) as response, temporary.open("wb") as stream:
            total = 0
            while chunk := response.read(1024 * 1024):
                total += len(chunk)
                if total > size:
                    raise InventoryError("Artifact response exceeds expected file size")

                stream.write(chunk)

        if total != size:
            raise InventoryError("Truncated artifact download")

        if not acl_template:
            validate_database(temporary)

        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)

    provenance: dict[str, object] = {
        "build_id": build,
        "build_number": build_info["buildNumber"],
        "artifact": artifact_name,
        "source_path": source,
    }

    if acl_template:
        provenance["image_path"] = str(target)
        database = extract_image_database(target, work)

        return database, provenance

    return target, provenance


def sha256(path: Path) -> str:
    digest = hashlib.sha256()

    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)

    return digest.hexdigest()


def image_path(root: Path, relative: str) -> Path:
    """Resolve image symlinks with absolute targets anchored to the image root."""
    pending_path_parts = deque(Path(relative).parts)
    current = root
    links = 0

    while pending_path_parts:
        part = pending_path_parts.popleft()
        if part in {"/", "."}:
            continue

        if part == "..":
            if current == root:
                raise InventoryError(f"Image symlink escapes --root-dir: {relative}")

            current = current.parent
            continue

        candidate = current / part
        mode = candidate.lstat().st_mode
        if stat.S_ISLNK(mode):
            links += 1
            if links > 40:
                raise InventoryError(f"Too many image symlinks: {relative}")

            target = candidate.readlink()
            if target.is_absolute():
                current = root
            pending_path_parts.extendleft(reversed(target.parts))
        else:
            if pending_path_parts and not stat.S_ISDIR(mode):
                raise InventoryError(f"Image path has a non-directory component: {relative}")

            current = candidate

    return current


def current_sources(root: Path) -> dict[str, Path]:
    """Locate just the image database, optional WAL, and a small os-release file."""
    resolved_database_paths: set[Path] = set()
    database_paths = (
        "var/lib/rpm/rpmdb.sqlite",
        "usr/lib/sysimage/rpm/rpmdb.sqlite",
        "usr/share/rpm/rpmdb.sqlite",
    )

    for relative in database_paths:
        try:
            resolved_database_paths.add(image_path(root, relative))
        except FileNotFoundError:
            continue

    if len(resolved_database_paths) != 1:
        raise InventoryError(f"Expected exactly one RPM database in --root-dir; found {len(resolved_database_paths)}")

    database = resolved_database_paths.pop()
    sources_by_filename = {"rpmdb.sqlite": database}
    wal_relative = str(database.relative_to(root)) + "-wal"

    try:
        sources_by_filename["rpmdb.sqlite-wal"] = image_path(root, wal_relative)
    except FileNotFoundError:
        pass

    for relative in ("etc/os-release", "usr/lib/os-release"):
        try:
            sources_by_filename["os-release"] = image_path(root, relative)
            break
        except FileNotFoundError:
            continue

    if "os-release" not in sources_by_filename:
        raise InventoryError("--root-dir has no readable os-release")

    for filename, source in sources_by_filename.items():
        info = source.lstat()
        limit = MAX_OS_RELEASE_BYTES if filename == "os-release" else MAX_DB_BYTES
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise InventoryError(f"Image {filename} must be a regular file of at most {limit} bytes")

    with open_image_file(root, database) as stream:
        if stream.read(16) != b"SQLite format 3\0":
            raise InventoryError(f"Not a SQLite RPM database: {database}")

    return sources_by_filename


def validate_current_paths(root: Path, work: Path, output: Path) -> tuple[Path, Path, Path]:
    try:
        root = root.resolve(strict=True)
        work, output = work.resolve(), output.resolve()
    except RuntimeError as error:
        # Python 3.11 reports path symlink loops as RuntimeError, not OSError.
        raise InventoryError(f"Invalid current image/work/output path: {error}") from error

    if not root.is_dir():
        raise InventoryError("--root-dir must be a directory")

    for name, directory in (("--work-dir", work), ("--output-dir", output)):
        try:
            directory_mode = directory.stat().st_mode
        except FileNotFoundError:
            continue

        if not stat.S_ISDIR(directory_mode):
            raise InventoryError(f"{name} must be a directory")

    current_sources(root)

    return root, work, output


@contextmanager
def open_image_file(root: Path, path: Path) -> Generator[BinaryIO, None, None]:
    """Open an already-resolved path without following replaced directory symlinks."""
    path_parts = path.relative_to(root).parts
    directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)

    try:
        for part in path_parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child

        descriptor = os.open(path_parts[-1], os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
        with os.fdopen(descriptor, "rb") as stream:
            yield stream
    finally:
        os.close(directory)


def current_fingerprint(
    root: Path,
    copies: Path | None = None,
) -> dict[str, tuple[str, int, int, int, int, int, str]]:
    """Hash every source input, including WAL bytes, using only read-only file I/O."""
    fingerprints_by_filename: dict[str, tuple[str, int, int, int, int, int, str]] = {}

    for filename, source in current_sources(root).items():
        limit = MAX_OS_RELEASE_BYTES if filename == "os-release" else MAX_DB_BYTES
        digest = hashlib.sha256()
        total = 0

        with open_image_file(root, source) as stream:
            before = os.fstat(stream.fileno())
            if not stat.S_ISREG(before.st_mode) or before.st_size > limit:
                raise InventoryError(f"Invalid current image file: {source}")

            # No SQLite connection is ever opened against the source image:
            # even mode=ro can create or update its shared-memory sidecar.
            destination = (copies / filename).open("xb") if copies is not None else None

            try:
                while chunk := stream.read(1024 * 1024):
                    total += len(chunk)
                    if total > limit:
                        raise InventoryError(f"Current image file exceeds {limit} bytes: {source}")

                    digest.update(chunk)
                    if destination is not None:
                        destination.write(chunk)
            finally:
                if destination is not None:
                    destination.close()

            after = os.fstat(stream.fileno())

        before_metadata = (
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
        )
        after_metadata = (
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        )
        if before_metadata != after_metadata or total != before.st_size:
            raise InventoryError("Current image inputs changed during collection; rerun")

        fingerprints_by_filename[filename] = (
            str(source),
            before.st_dev,
            before.st_ino,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
            digest.hexdigest(),
        )

    return fingerprints_by_filename


@contextmanager
def current_image_snapshot(
    root: Path,
    work: Path,
) -> Generator[tuple[Path, dict[str, object]], None, None]:
    """Merge a private database/WAL copy, and invalidate any changed source inputs."""
    root, work = root.resolve(strict=True), work.resolve()
    if not root.is_dir():
        raise InventoryError("--root-dir must be a directory")

    with tempfile.TemporaryDirectory(prefix=".acl-current-", dir=work) as temporary:
        private = Path(temporary)
        copies, snapshot = private / "source", private / "root"
        copies.mkdir(mode=0o700)
        snapshot.mkdir(mode=0o700)

        before_by_filename = current_fingerprint(root, copies)
        if current_fingerprint(root) != before_by_filename:
            raise InventoryError("Current image inputs changed during collection; rerun")

        database = snapshot / "var/lib/rpm/rpmdb.sqlite"
        database.parent.mkdir(parents=True, mode=0o700)
        (snapshot / "etc").mkdir(mode=0o700)
        backup_database(copies / "rpmdb.sqlite", database)
        shutil.copyfile(copies / "os-release", snapshot / "etc/os-release")

        provenance: dict[str, object] = {
            "root": str(root),
            "database_path": before_by_filename["rpmdb.sqlite"][0],
            "sha256": sha256(database),
        }

        yield snapshot, provenance

        # This deliberately invalidates WAL appends/checkpoints as well as
        # database replacements; a main-file-only hash can miss committed WAL.
        if current_fingerprint(root) != before_by_filename:
            raise InventoryError("Current image inputs changed during collection; rerun")


def native_architecture() -> str:
    native_arches_by_machine = {
        "x86_64": "x86_64",
        "amd64": "x86_64",
        "aarch64": "aarch64",
        "arm64": "aarch64",
    }
    architecture = native_arches_by_machine.get(platform.machine())
    if platform.system() != "Linux" or architecture is None:
        raise InventoryError("Native collection requires x86_64/aarch64 Linux")

    return architecture


def native_tools(root: Path, package_manager: str) -> tuple[str, str]:
    if package_manager not in {"tdnf", "dnf5"}:
        raise InventoryError("Current build ID package manager must be tdnf or dnf5")

    tool_paths: list[str] = []

    for name in ("rpm", package_manager):
        executable = shutil.which(name)
        if executable is None:
            raise InventoryError(f"Current build ID requires native {name} on PATH in the SDK")

        path = Path(executable).resolve()
        if root != Path("/") and path.is_relative_to(root):
            raise InventoryError(f"Current build ID must not execute the image's {name}")

        tool_paths.append(str(path))

    return tool_paths[0], tool_paths[1]


@contextmanager
def nbd_image(image: Path) -> Generator[str, None, None]:
    """Reserve a free device cooperatively; never disconnect another attachment."""
    root_run(["modprobe", "nbd", "max_part=16"])

    lock_directory = Path("/run/lock/image-rpm-inventory")
    root_run(["mkdir", "-p", str(lock_directory)])
    root_run(["chmod", "1777", str(lock_directory)])

    for device in sorted(Path("/sys/class/block").glob("nbd*")):
        # sysfs also lists partitions, which have no attachment pid file.
        if re.fullmatch(r"nbd[0-9]+", device.name) is None:
            continue

        lock_path = lock_directory / f"{device.name}.lock"
        with lock_path.open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                continue

            if (device / "pid").exists():
                continue

            block = f"/dev/{device.name}"
            if not Path(block).exists():
                major, minor = (device / "dev").read_text().strip().split(":")
                root_run(["mknod", block, "b", major, minor])

            root_run(["qemu-nbd", "--read-only", "--format=vhdx", "--connect", block, str(image)])
            try:
                root_run(["partprobe", block])
                root_run(["udevadm", "settle"])
                yield block
            finally:
                root_run(["qemu-nbd", "--disconnect", block])

            return

    raise InventoryError("No free network-block device is available")


def extract_image_database(image: Path, work: Path) -> Path:
    """Copy a VHDX image's RPM database using read-only partition mounts."""
    destination = work / "acl-t-rpmdb.sqlite"
    mount = work / "acl-t-mount"
    mount.mkdir(exist_ok=True)

    copied = work / "acl-t-rpmdb-source"
    copied.mkdir(exist_ok=True)

    for filename in ("rpmdb.sqlite", "rpmdb.sqlite-wal", "rpmdb.sqlite-shm"):
        (copied / filename).unlink(missing_ok=True)

    with nbd_image(image) as device:
        listing: dict[str, Any] = json.loads(
            run(
                [
                    "lsblk",
                    "--json",
                    "--paths",
                    "--output",
                    "NAME,FSTYPE",
                    device,
                ],
            ),
        )
        disks: list[dict[str, Any]] = listing["blockdevices"]
        partitions: list[dict[str, Any]] = disks[0].get("children", [])
        found = 0

        for partition in partitions:
            filesystem = partition.get("fstype")
            if filesystem not in {"ext4", "xfs", "btrfs"}:
                continue

            options_by_fstype = {"ext4": "ro,noload", "xfs": "ro,norecovery", "btrfs": "ro,nologreplay"}
            root_run(
                [
                    "mount",
                    "-t",
                    str(filesystem),
                    "-o",
                    options_by_fstype[filesystem],
                    str(partition["name"]),
                    str(mount),
                ],
            )
            try:
                # Treat symlinks as paths inside the mounted image, never on the host.
                database_paths = (
                    "var/lib/rpm/rpmdb.sqlite",
                    "usr/lib/sysimage/rpm/rpmdb.sqlite",
                    "usr/share/rpm/rpmdb.sqlite",
                )
                candidate_database_paths: list[Path] = []

                for relative in database_paths:
                    candidate = mount / relative
                    if not candidate.is_file():
                        continue

                    if not candidate.resolve().is_relative_to(mount.resolve()):
                        continue

                    candidate_database_paths.append(candidate)

                unique_database_paths = {path.resolve() for path in candidate_database_paths}
                if len(unique_database_paths) > 1:
                    raise InventoryError("Multiple RPM databases on image root partition")

                if unique_database_paths:
                    source = unique_database_paths.pop()

                    for suffix in ("", "-wal"):
                        original = Path(str(source) + suffix)
                        if original.exists():
                            copy = copied / ("rpmdb.sqlite" + suffix)
                            root_run(["cp", str(original), str(copy)])
                            root_run(["chown", f"{os.getuid()}:{os.getgid()}", str(copy)])

                    found += 1
            finally:
                root_run(["umount", str(mount)])

        if found != 1:
            raise InventoryError(f"Expected exactly one image root RPM database; found {found}")

    backup_database(copied / "rpmdb.sqlite", destination)

    return destination


def prepare_tools(work: Path, image: str) -> Path:
    tools = work / "tools-dir"
    marker = tools / ".bootstrap-complete"
    marker_contents = f"{image}\n"
    if marker.is_file() and marker.read_text() == marker_contents:
        return tools

    if tools.exists():
        root_run(["rm", "-rf", "--", str(tools)])

    tools.mkdir()
    root_run(["docker", "pull", image], timeout=900)
    container = root_run(["docker", "create", image]).strip()
    archive = work / "tools-rootfs.tar"

    try:
        root_run(["docker", "export", "--output", str(archive), container])
        root_run(["tar", "--extract", "--file", str(archive), "--directory", str(tools)])
    finally:
        root_run(["docker", "rm", "-f", container])
        root_run(["rm", "-f", "--", str(archive)])

    root_run(["cp", "--remove-destination", "/etc/resolv.conf", str(tools / "etc/resolv.conf")])

    null = tools / "dev/null"
    if not null.exists() or not stat.S_ISCHR(null.stat().st_mode):
        root_run(["rm", "-f", "--", str(null)])
        root_run(["mknod", str(null), "c", "1", "3"])
    root_run(["chmod", "666", str(null)])

    root_run(["chroot", str(tools), "rpm", "--version"])
    root_run(["chroot", str(tools), "tdnf", "--version"])

    # No systemd installation: inventory queries do not rebuild images or UKIs.
    root_run(["chown", f"{os.getuid()}:{os.getgid()}", str(tools)])
    marker.write_text(marker_contents)

    return tools


@dataclass(frozen=True)
class Package:
    name: str
    version: str
    release: str
    arch: str
    size: int

    @property
    def nvra(self) -> str:
        return f"{self.name}-{self.version}-{self.release}.{self.arch}"


def image_architecture(packages: Sequence[Package]) -> str:
    """Infer a single supported target from installed RPMs, ignoring noarch data."""
    package_arches = {package.arch for package in packages if package.arch != "noarch"}
    if len(package_arches) != 1 or not package_arches.issubset(OCI_ARCHES_BY_NATIVE_ARCH):
        raise InventoryError(
            "Current image must contain exactly one supported package architecture "
            f"(x86_64 or aarch64); found {sorted(package_arches)}",
        )

    return package_arches.pop()


def validate_package_architectures(
    packages: Sequence[Package],
    architecture: str,
) -> None:
    mismatched_arches = {package.arch for package in packages} - {architecture, "noarch"}
    if mismatched_arches:
        raise InventoryError(
            f"Image package architectures {sorted(mismatched_arches)} do not match "
            f"native host architecture {architecture}",
        )


def parse_packages(output: str) -> list[Package]:
    packages: list[Package] = []

    for line in output.splitlines():
        package_fields = line.split("\t")
        if len(package_fields) != 5 or not all(package_fields[:4]) or not package_fields[4].isdecimal():
            raise InventoryError(f"Malformed RPM inventory row: {line!r}")

        packages.append(Package(package_fields[0], package_fields[1], package_fields[2], package_fields[3], int(package_fields[4])))

    if not packages:
        raise InventoryError("RPM inventory is empty")

    seen_nvras: set[str] = set()

    for package in packages:
        if package.nvra in seen_nvras:
            raise InventoryError(f"Ambiguous installed package after ignoring epoch: {package.nvra}")

        seen_nvras.add(package.nvra)

    return packages


def validate_unique_package_names(packages: Sequence[Package]) -> None:
    seen_pkgnames: set[str] = set()

    for package in packages:
        if package.name in seen_pkgnames:
            raise InventoryError(f"Duplicate installed package name: {package.name}")

        seen_pkgnames.add(package.name)


def parse_matches(output: str, installed_nvras: set[str], package_manager: str = "tdnf") -> set[str]:
    matched_nvras: set[str] = set()

    for line in output.splitlines():
        line = line.strip()
        if not line or line == "No data available":
            continue

        nvra = re.sub(r"(?<=-)[0-9]+:", "", line, count=1)
        if nvra not in installed_nvras:
            raise InventoryError(f"Unexpected {package_manager} result (not in image inventory): {line!r}")

        matched_nvras.add(nvra)

    return matched_nvras


def removal_dependents(output: str, target: str, installed_nvras: set[str]) -> set[str]:
    """Return the complete tdnf removal set, including transitive dependents."""
    plan = as_object(json.loads(output))
    removal_records: object = plan.get("Remove")
    if not isinstance(removal_records, list):
        raise InventoryError("tdnf JSON response has no Remove array")

    removed_nvras: set[str] = set()

    for raw in cast(list[object], removal_records):
        item = as_object(raw)
        name, vr, arch = item.get("Name"), item.get("Evr"), item.get("Arch")
        if not all(isinstance(value, str) and value for value in (name, vr, arch)):
            raise InventoryError("Malformed package in tdnf removal plan")

        vr = str(vr).split(":", 1)[-1]
        nvra = f"{name}-{vr}.{arch}"
        if nvra not in installed_nvras:
            raise InventoryError(f"tdnf removal plan contains an unknown package: {nvra}")

        removed_nvras.add(nvra)

    if target not in removed_nvras:
        raise InventoryError(f"tdnf removal plan does not contain its target: {target}")

    return removed_nvras - {target}


def dnf5_removal_dependents(output: str, target: str, installed_nvras: set[str]) -> set[str]:
    """Read the stored-transaction schema emitted by DNF5 5.2.6.0.

    See libdnf5/transaction/transaction_sr.cpp and transaction_item_action.cpp:
    https://github.com/rpm-software-management/dnf5/tree/5.2.6.0/libdnf5/transaction
    """
    plan = as_object(json.loads(output))
    if plan.get("version") != "1.0":
        raise InventoryError("Unsupported dnf5 transaction version; expected '1.0'")

    removal_records: object = plan.get("rpms")
    if not isinstance(removal_records, list):
        raise InventoryError("dnf5 transaction JSON has no rpms array")

    for field in ("groups", "environments"):
        group_or_environment_records: object = plan.get(field, [])
        if not isinstance(group_or_environment_records, list) or group_or_environment_records:
            raise InventoryError(f"Unexpected {field} in dnf5 installed-package removal plan")

    removed_nvras: set[str] = set()

    for raw in cast(list[object], removal_records):
        item = as_object(raw)
        if item.get("action") != "Remove":
            raise InventoryError(f"dnf5 removal plan contains a non-Remove action: {item.get('action')!r}")

        nevra = item.get("nevra")
        if not isinstance(nevra, str) or not nevra:
            raise InventoryError("Malformed nevra in dnf5 removal plan")

        nvra = re.sub(r"(?<=-)[0-9]+:", "", nevra, count=1)
        if nvra not in installed_nvras:
            raise InventoryError(f"dnf5 removal plan contains an unknown package: {nevra!r}")

        removed_nvras.add(nvra)

    if target not in removed_nvras:
        raise InventoryError(f"dnf5 removal plan does not contain its target: {target}")

    return removed_nvras - {target}


def query_database(
    tools: Path | None,
    database: Path | None,
    *,
    snapshot: Path | None,
    rpm_executable: str,
    package_manager_executable: str | None,
    package_manager: str,
) -> tuple[list[Package], dict[str, set[str]], str]:
    """Query a copied database in chroot tools or an already-private native snapshot."""
    runner: Callable[[Sequence[str]], str]
    solver_executable = package_manager_executable or package_manager
    inside = "/analysis"

    if snapshot is None:
        if tools is None or database is None:
            raise InventoryError("Chroot queries require tools and a database")

        if rpm_executable != "rpm" or package_manager_executable is not None or package_manager != "tdnf":
            raise InventoryError("Chroot queries support only tdnf without native options")

        print("Validating and copying RPM database...", flush=True)
        validate_database(database)

        target = tools / inside.lstrip("/")
        if target.exists():
            root_run(["rm", "-rf", "--", str(target)])

        root_run(["mkdir", "-p", str(target / "var/lib/rpm"), str(target / "etc")])
        root_run(["cp", str(database), str(target / "var/lib/rpm/rpmdb.sqlite")])
        root_run(["cp", str(tools / "etc/os-release"), str(target / "etc/os-release")])

        print("Reading installed RPM packages...", flush=True)
        rpm_command = ["chroot", str(tools), "rpm", "--root", inside, "--dbpath", "/var/lib/rpm"]
        runner = root_run
    else:
        if tools is not None or database is not None:
            raise InventoryError("Native queries require a snapshot without chroot tools or a database")

        if package_manager not in {"tdnf", "dnf5"}:
            raise InventoryError("Current build ID package manager must be tdnf or dnf5")

        rpm_command = [rpm_executable, "--root", str(snapshot), "--dbpath", "/var/lib/rpm"]
        runner = run

    packages = [package for package in parse_packages(runner([*rpm_command, "-qa", "--qf", RPM_FORMAT]))
                if package.name != "gpg-pubkey"]
    if not packages:
        raise InventoryError("RPM database contains no installed packages (only signing keys)")

    validate_unique_package_names(packages)

    if snapshot is not None and package_manager == "dnf5":
        architecture = image_architecture(packages)
        dependents_by_nvra = collect_current_dnf5(
            snapshot,
            rpm_executable,
            solver_executable,
            packages,
            architecture,
        )

        return packages, dependents_by_nvra, architecture

    architecture = native_architecture()
    validate_package_architectures(packages, architecture)

    if snapshot is not None:
        # Keep host/image repos, plugins, locks, and history out of the model. Only
        # installed RPM dependencies are used, without history-based orphan removal.
        config = snapshot / "etc/tdnf/tdnf.conf"
        config.parent.mkdir(mode=0o700)
        (snapshot / "etc/yum.repos.d").mkdir(mode=0o700)
        config.write_text(
            "[main]\n"
            "plugins=0\n"
            "clean_requirements_on_remove=0\n"
            "repodir=/etc/yum.repos.d\n"
            "cachedir=/var/cache/tdnf\n"
            "persistdir=/var/lib/tdnf\n",
            encoding="utf-8",
        )

        command = [
            solver_executable,
            "--config",
            str(config),
            "--noplugins",
            "--disablerepo=*",
            "--releasever=3.0",
            "--installroot",
            str(snapshot),
            "--rpmdefine",
            "_dbpath /var/lib/rpm",
        ]
        installed_command = [*command, "--quiet", "repoquery", "--installed"]
        removal_command = [*command, "--json", "--assumeno", "remove"]
    else:
        print(f"Checking {len(packages)} packages against tdnf inventory...", flush=True)
        installed_command = [
            "chroot",
            str(tools),
            "tdnf",
            "--quiet",
            "--disablerepo=*",
            "--releasever=3.0",
            "--installroot",
            inside,
            "repoquery",
            "--installed",
        ]
        removal_command = [
            "chroot",
            str(tools),
            "tdnf",
            "--json",
            "--disablerepo=*",
            "--releasever=3.0",
            "--installroot",
            inside,
            "--assumeno",
            "remove",
        ]

    installed_nvras = {package.nvra for package in packages}
    queried_installed_nvras = parse_matches(runner(installed_command), installed_nvras)
    if queried_installed_nvras != installed_nvras:
        raise InventoryError("tdnf and RPM disagree on the image's installed package inventory")

    dependents_by_nvra = collect_dependents(
        packages,
        removal_command,
        runner,
        parse_plan=removal_dependents,
    )

    return packages, dependents_by_nvra, architecture


def collect_dependents(
    packages: list[Package],
    removal_command: Sequence[str],
    runner: Callable[[Sequence[str]], str],
    parse_plan: Callable[[str, str, set[str]], set[str]],
) -> dict[str, set[str]]:
    installed_nvras = {package.nvra for package in packages}
    started = time.monotonic()
    progress = (0, packages[0].nvra)
    stopped = threading.Event()

    def report() -> None:
        completed, current = progress
        elapsed = time.monotonic() - started
        message = (
            f"Collected {completed}/{len(packages)} removal plans; "
            f"elapsed {elapsed:.0f}s; current {current}"
        )

        print(message, flush=True)

    def heartbeat() -> None:
        while not stopped.wait(10):
            report()

    report()
    reporter = threading.Thread(target=heartbeat, daemon=True)
    reporter.start()

    dependents_by_nvra: dict[str, set[str]] = {}

    try:
        for index, package in enumerate(packages, start=1):
            progress = (index - 1, package.nvra)
            dependents_by_nvra[package.nvra] = parse_plan(
                runner([*removal_command, package.nvra]),
                package.nvra,
                installed_nvras,
            )
            progress = (index, package.nvra)
    finally:
        stopped.set()
        reporter.join()
        report()

    return dependents_by_nvra


def collect_current_dnf5(
    snapshot: Path,
    rpm: str,
    dnf5: str,
    packages: list[Package],
    architecture: str,
) -> dict[str, set[str]]:
    """Store removal plans with native DNF5, entirely inside the private work tree."""
    print(f"Image target architecture {architecture}", flush=True)

    config = snapshot / "etc/dnf/dnf.conf"
    config.parent.mkdir(mode=0o700)
    repos = snapshot / "etc/yum.repos.d"
    repos.mkdir(mode=0o700)
    (config.parent / "vars").mkdir(mode=0o700)

    home, temporary = snapshot / ".home", snapshot / ".tmp"

    for directory in (home / "config", home / "cache", home / "state", temporary):
        directory.mkdir(parents=True, mode=0o700)

    env = {
        **os.environ,
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(home / "config"),
        "XDG_CACHE_HOME": str(home / "cache"),
        "XDG_STATE_HOME": str(home / "state"),
        "DNF5_PLUGINS_DIR": "",
        "LC_ALL": "C",
        **{name: str(temporary) for name in ("TMPDIR", "TMP", "TEMP", "TEMPDIR")},
    }

    # --no-plugins disables library plugins; DNF5_PLUGINS_DIR also disables
    # application plugins, which 5.2.6.0 loads before parsing CLI options.
    # libsolv 0.7.30 consults the native RPM _dbpath macro, not --dbpath.
    # Any alternate location is a private alias of the same merged database.
    dbpath = Path(run([rpm, "--eval", "%{_dbpath}"], env=env).strip())
    if not dbpath.is_absolute() or dbpath == Path("/") or ".." in dbpath.parts:
        raise InventoryError("Native RPM _dbpath must be an absolute directory without '..'")

    database_directory = snapshot / "var/lib/rpm"
    alias = snapshot / dbpath.relative_to("/")
    if alias != database_directory:
        alias.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        alias.symlink_to(os.path.relpath(database_directory, alias.parent), target_is_directory=True)

    # Paths in this configuration are rooted by DNF5 in --installroot. The
    # disabled file repo lets --disable-repo=* match something: 5.2.6.0
    # errors on an unmatched repo pattern even for installed-only queries.
    config_contents = (
        "[main]\n"
        "plugins=False\n"
        "use_host_config=False\n"
        "reposdir=/etc/yum.repos.d\n"
        "varsdir=/etc/dnf/vars\n"
        "cachedir=/var/cache/dnf5\n"
        "system_cachedir=/var/cache/dnf5\n"
        "logdir=/var/log/dnf5\n"
        "persistdir=/var/lib/dnf5\n"
        "system_state_dir=/var/lib/dnf5\n"
        "transaction_history_dir=/var/lib/dnf5\n"
        "clean_requirements_on_remove=False\n"
        "[acl-inventory]\n"
        "name=Installed image packages only\n"
        "enabled=False\n"
        f"baseurl={repos.as_uri()}\n"
    )
    config.write_text(config_contents, encoding="utf-8")

    command = [
        dnf5,
        "--config",
        str(config),
        "--no-plugins",
        "--disable-repo=*",
        "--forcearch",
        architecture,
        "--releasever=3.0",
        "--installroot",
        str(snapshot),
        "--setopt=clean_requirements_on_remove=False",
        "--setopt=protected_packages=",
        "--setopt=protect_running_kernel=False",
    ]

    installed_nvras = {package.nvra for package in packages}
    # 5.2.6.0's formatter supports full_nevra but not nevra, and needs an
    # explicit newline. parse_matches removes both zero and nonzero epochs.
    queried_installed_nvras = parse_matches(
        run(
            [
                *command,
                "--quiet",
                "repoquery",
                "--installed",
                "--queryformat=%{full_nevra}\\n",
            ],
            env=env,
        ),
        installed_nvras,
        "dnf5",
    )
    if queried_installed_nvras != installed_nvras:
        raise InventoryError("dnf5 and RPM disagree on the image's installed package inventory")

    def store_removal(args: Sequence[str]) -> str:
        with tempfile.TemporaryDirectory(prefix=".dnf5-remove-", dir=snapshot.parent) as directory:
            store = Path(directory)

            # --store and --no-autoremove belong AFTER remove. 5.2.6.0 asks
            # for confirmation before storing; --assumeno aborts without JSON.
            # --store returns before transaction.run(), so no scriptlets run.
            run([*args[:-1], f"--store={store}", args[-1]], env=env)

            transaction = store / "transaction.json"
            if transaction.is_symlink() or not transaction.is_file():
                raise InventoryError(f"dnf5 did not store a regular transaction.json for {args[-1]}")

            return transaction.read_text(encoding="utf-8")

    return collect_dependents(
        packages,
        [*command, "--assumeyes", "remove", "--no-autoremove"],
        store_removal,
        parse_plan=dnf5_removal_dependents,
    )


def read_inventory(
    path: Path,
    cache_key: dict[str, object],
) -> tuple[list[Package], dict[str, set[str]]] | None:
    """Reuse only complete inventories with matching collection inputs."""
    if not path.is_file():
        return None

    try:
        data = as_object(json.loads(path.read_text(encoding="utf-8")))
        stored_key = as_object(data.get("cache_key", {}))
        if type(stored_key.get("version")) is not int or stored_key != cache_key:
            return None

        raw_package_records: object = data.get("packages")
        if not isinstance(raw_package_records, list) or not raw_package_records:
            raise InventoryError("cached inventory has no packages")

        packages: list[Package] = []
        installed_nvras: set[str] = set()

        for raw in cast(list[object], raw_package_records):
            item = as_object(raw)
            name, version, release, arch = (item.get(field) for field in ("name", "version", "release", "arch"))
            size: object = item.get("size")
            if (not all(isinstance(value, str) and value for value in (name, version, release, arch))
                    or isinstance(size, bool) or not isinstance(size, int) or size < 0):
                raise InventoryError("malformed cached package")

            package = Package(str(name), str(version), str(release), str(arch), size)
            if item.get("nvra") != package.nvra or package.nvra in installed_nvras:
                raise InventoryError("inconsistent or ambiguous cached NVRA")

            packages.append(package)
            installed_nvras.add(package.nvra)

        validate_unique_package_names(packages)

        raw_dependents_by_nvra = as_object(data.get("dependents"))
        if raw_dependents_by_nvra.keys() != installed_nvras:
            raise InventoryError("cached removal plans do not cover the inventory")

        dependents_by_nvra: dict[str, set[str]] = {}

        for nvra, raw_dependent_nvras in raw_dependents_by_nvra.items():
            if not isinstance(raw_dependent_nvras, list):
                raise InventoryError("malformed cached removal plan")

            dependent_nvras: set[str] = set()

            for value in cast(list[object], raw_dependent_nvras):
                if not isinstance(value, str) or value not in installed_nvras:
                    raise InventoryError("unknown package in cached removal plan")

                dependent_nvras.add(value)

            dependents_by_nvra[nvra] = dependent_nvras

        return packages, dependents_by_nvra
    except (OSError, ValueError, TypeError) as error:
        print(f"Warning: ignoring invalid inventory cache {path}: {error}", file=sys.stderr, flush=True)
        return None


def write_inventory(
    path: Path,
    packages: list[Package],
    dependents_by_nvra: dict[str, set[str]],
    *,
    cache_key: dict[str, object] | None = None,
) -> None:
    """Persist collected data before report-only Keep rules and filtering."""
    data: dict[str, object] = {
        "packages": [{"nvra": package.nvra, **asdict(package)} for package in packages],
        "dependents": {nvra: sorted(dependent_nvras) for nvra, dependent_nvras in dependents_by_nvra.items()},
    }
    if cache_key is not None:
        data["cache_key"] = cache_key

    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".json.partial")

    try:
        temporary.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def validate_no_dependency_cycles(dependents_by_nvra: dict[str, set[str]]) -> None:
    """Reject cycles in the complete inventory before removal-policy filtering."""
    try:
        TopologicalSorter(dependents_by_nvra).prepare()
    except CycleError as error:
        cycle_nvras = cast(list[str], error.args[1])
        # The sorter takes predecessors, so reverse its path to follow dependents.
        raise InventoryError("Dependency cycle detected: " + " -> ".join(reversed(cycle_nvras))) from error


def report_dependents(
    packages: list[Package],
    dependents_by_nvra: dict[str, set[str]],
    explicit_keep_decisions_by_pkgname: dict[str, bool],
) -> dict[str, set[str]]:
    """Filter removal plans and reject removals with remaining dependents."""
    excluded_nvras = {package.nvra for package in packages
                if explicit_keep_decisions_by_pkgname.get(package.name) is False}
    remaining_dependents_by_nvra = {package.nvra: dependents_by_nvra[package.nvra] - excluded_nvras - {package.nvra}
                  for package in packages}

    conflict_messages: list[str] = []

    for package in packages:
        if explicit_keep_decisions_by_pkgname.get(package.name) is False and remaining_dependents_by_nvra[package.nvra]:
            conflict_messages.append(
            f"Package {package.name!r} ({package.nvra}) is marked for removal "
                f"but has Dependants Count={len(remaining_dependents_by_nvra[package.nvra])}; "
                f"Dependents: {', '.join(sorted(remaining_dependents_by_nvra[package.nvra]))}"
            )

    if conflict_messages:
        raise InventoryError("\n".join(conflict_messages))

    return remaining_dependents_by_nvra


def write_csv(
    path: Path,
    packages: list[Package],
    dependents_by_nvra: dict[str, set[str]],
    effective_keep_decisions_by_pkgname: dict[str, bool],
    explicit_keep_decisions_by_pkgname: dict[str, bool] | None = None,
    keep_reasons_by_pkgname: dict[str, str] | None = None,
    *,
    remaining_dependents_by_nvra: dict[str, set[str]] | None = None,
) -> None:
    reasons_by_pkgname = keep_reasons_by_pkgname or {}
    if remaining_dependents_by_nvra is None:
        remaining_dependents_by_nvra = report_dependents(
            packages,
            dependents_by_nvra,
            explicit_keep_decisions_by_pkgname or {},
        )

    sizes_by_nvra = {package.nvra: package.size for package in packages}
    pkgnames_by_nvra = {package.nvra: package.name for package in packages}
    removed_pkgnames_by_nvra = {package.nvra: package.name for package in packages
                     if effective_keep_decisions_by_pkgname.get(package.name) is False}

    top_level_nvras = {nvra for nvra, dependent_nvras in remaining_dependents_by_nvra.items() if not dependent_nvras}

    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".csv.partial")

    try:
        with temporary.open("w", encoding="utf-8", newline="") as stream:
            writer = csv.writer(stream)
            writer.writerow(CSV_HEADER)

            csv_rows: list[tuple[str, str, str, str, int, str]] = []

            for package in packages:
                dependent_nvras = remaining_dependents_by_nvra[package.nvra]
                top_level_dependent_nvras = sorted(dependent_nvras & top_level_nvras)
                keep = ""
                if package.name in effective_keep_decisions_by_pkgname:
                    keep = "YES" if effective_keep_decisions_by_pkgname[package.name] else "NO"

                reason = reasons_by_pkgname.get(package.name, "") if keep else ""
                if top_level_dependent_nvras:
                    top_level_dependent_pkgnames = sorted({
                        pkgnames_by_nvra[nvra] for nvra in top_level_dependent_nvras
                    })
                    required_by = "Required by another package: " + ", ".join(top_level_dependent_pkgnames)
                    reason = required_by + (f"; {reason}" if reason else "")

                if keep == "NO":
                    removed_dependent_pkgnames = sorted({
                        removed_pkgnames_by_nvra[nvra] for nvra in dependents_by_nvra[package.nvra]
                        if nvra in removed_pkgnames_by_nvra and removed_pkgnames_by_nvra[nvra] != package.name
                    })
                    if removed_dependent_pkgnames:
                        reason = (f"{reason} " if reason else "") + (
                            "Dependents also selected for removal: "
                            + ", ".join(removed_dependent_pkgnames) + "."
                        )

                row = (
                    package.nvra,
                    f"{package.size / (1024 ** 2):.2f}",
                    keep,
                    reason,
                    len(dependent_nvras),
                    "\n".join(f"- {nvra}" for nvra in top_level_dependent_nvras),
                )
                csv_rows.append(row)

            # Sort by Top-level Dependents text, ascending with empty lists first;
            # then Keep (blank, NO, YES), byte size descending, and NVRA ascending.
            for row in sorted(csv_rows, key=lambda row: (row[5], row[2], -sizes_by_nvra[row[0]], row[0])):
                writer.writerow(row)

        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def write_markdown(csv_path: Path, title: str) -> Path:
    """Render the finished CSV as a heading and source-aligned table in CSV order."""
    path = csv_path.with_suffix(".md")
    temporary = path.with_suffix(".md.partial")

    def table_row(cell_values: Sequence[str], column_widths: Sequence[int]) -> str:
        return "| " + " | ".join(value.ljust(width) for value, width in zip(cell_values, column_widths)) + " |\n"

    try:
        with csv_path.open(encoding="utf-8", newline="") as source, \
                temporary.open("w", encoding="utf-8", newline="\n") as stream:
            reader = csv.reader(source)
            csv_header = next(reader, None)
            if not csv_header:
                raise InventoryError(f"CSV report has no header: {csv_path}")

            csv_rows: list[list[str]] = [csv_header, *reader]
            if any(len(row) != len(csv_header) for row in csv_rows):
                raise InventoryError(f"CSV report has inconsistent columns: {csv_path}")

            markdown_rows: list[list[str]] = []

            for row in csv_rows:
                escaped_cells: list[str] = []

                for value in row:
                    cell = html.escape(value, quote=False)
                    cell = cell.replace("\\", "\\\\")
                    cell = cell.replace("|", "\\|")
                    cell = cell.replace("\r\n", "\n")
                    cell = cell.replace("\r", "\n")
                    cell = cell.replace("\n", "<br>")
                    escaped_cells.append(cell)

                markdown_rows.append(escaped_cells)

            column_widths = [max(3, max(len(row[index]) for row in markdown_rows)) for index in range(len(csv_header))]

            stream.write(f"# {title}\n\n")
            stream.write(table_row(markdown_rows[0], column_widths))
            stream.write(table_row(["-" * width for width in column_widths], column_widths))
            for cell_values in markdown_rows[1:]:
                stream.write(table_row(cell_values, column_widths))

        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)

    return path


def write_removal_list(
    path: Path,
    packages: list[Package],
    explicit_keep_decisions_by_pkgname: dict[str, bool],
) -> None:
    """Write unique installed package names whose final Keep decision is NO."""
    removal_pkgnames: set[str] = set()

    for package in packages:
        if explicit_keep_decisions_by_pkgname.get(package.name) is False:
            removal_pkgnames.add(package.name)

    sorted_removal_pkgnames = sorted(removal_pkgnames)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".txt.partial")

    try:
        temporary.write_text("".join(name + "\n" for name in sorted_removal_pkgnames), encoding="utf-8")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def warn_blank_keep(
    packages: Sequence[Package],
    effective_keep_decisions_by_pkgname: dict[str, bool],
    remaining_dependents_by_nvra: dict[str, set[str]],
) -> None:
    """Warn for undecided ACL packages with no remaining dependents."""
    for package in sorted(packages, key=lambda item: item.nvra):
        if package.name in effective_keep_decisions_by_pkgname:
            continue

        if remaining_dependents_by_nvra[package.nvra]:
            continue

        message = f"Package {package.nvra} does not have any remaining dependents but has no Keep decision."
        message = message.replace("%", "%AZP25").replace("\r", "%0D").replace("\n", "%0A")
        print(f"##vso[task.logissue type=warning]{message}", flush=True)


def format_size(size: int) -> str:
    return f"{size / (1024 ** 2):,.2f} MiB"


def load_keep_file(path: Path) -> tuple[set[str], set[str], dict[str, str]]:
    """Read TOML package selections without collecting or changing inventories."""
    data_by_pkgname: dict[Any, Any] = tomllib.loads(path.read_text(encoding="utf-8"))
    selections_by_pkgname: dict[str, tuple[bool, str]] = {}

    for name, value in data_by_pkgname.items():
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_+][A-Za-z0-9_.+-]*", name.strip()):
            raise InventoryError("keep file keys must be valid package-name strings")

        if not isinstance(value, dict):
            raise InventoryError(f"keep file entry for {name!r} must be a map with keep and reason keys")

        entry = cast(dict[object, object], value)
        if entry.keys() != {"keep", "reason"}:
            raise InventoryError(f"keep file entry for {name!r} must have exactly keep and reason keys")

        keep, reason = entry["keep"], entry["reason"]
        if not isinstance(keep, bool):
            raise InventoryError(f"keep for {name!r} must be true or false")

        if not isinstance(reason, str):
            raise InventoryError(f"reason for {name!r} must be a string")

        selections_by_pkgname[name.strip()] = keep, reason

    keep_pkgnames: set[str] = set()
    do_not_keep_pkgnames: set[str] = set()
    keep_reasons_by_pkgname: dict[str, str] = {}

    for name, (keep, reason) in selections_by_pkgname.items():
        if keep:
            keep_pkgnames.add(name)
        else:
            do_not_keep_pkgnames.add(name)
        keep_reasons_by_pkgname[name] = reason

    return keep_pkgnames, do_not_keep_pkgnames, keep_reasons_by_pkgname


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--work-dir",
        type=Path,
        required=True,
        help="directory for temporary collection data and cached inventories",
    )
    parser.add_argument("--output-dir", type=Path, required=True)

    source_group = parser.add_mutually_exclusive_group(required=True)
    source_group.add_argument(
        "--build-id",
        type=parse_acl_build,
        metavar="ID",
        help="positive ACL build ID to analyze",
    )
    source_group.add_argument(
        "--root-dir",
        type=Path,
        help="mounted image root or host root '/' to analyze locally",
    )

    parser.add_argument(
        "--acl-template",
        action="store_true",
        help="analyze the selected build's ACL-T Azure image instead of ACL",
    )
    parser.add_argument(
        "--package-manager",
        choices=("tdnf", "dnf5"),
        help="native solver for current build ID only (default: dnf5)",
    )
    parser.add_argument("--tools-image", default=TOOLS_IMAGE)
    parser.add_argument("--build-rpmdb", type=Path, help="use a local ACL/ACL-T database instead of downloading")
    parser.add_argument(
        "--package-decisions-file",
        type=Path,
        metavar="TOML",
        help="TOML package tables containing explicit keep (bool) and reason (string) decisions",
    )

    args = parser.parse_args(argv)

    if args.build_id is None and args.acl_template:
        parser.error("--acl-template requires a numeric --build-id")

    image_name = "acl-t" if args.acl_template else "acl"
    image_title = "ACL-T" if args.acl_template else "ACL"

    if args.build_id is None and args.build_rpmdb is not None:
        parser.error("--build-rpmdb is forbidden when --build-id is omitted")

    if args.build_id is not None and args.package_manager is not None:
        parser.error("--package-manager is forbidden with a numeric --build-id")

    package_manager: str = args.package_manager or "dnf5"
    keep_pkgnames: set[str] = set()
    do_not_keep_pkgnames: set[str] = set()
    keep_reasons_by_pkgname: dict[str, str] = {}

    if args.package_decisions_file is not None:
        try:
            keep_pkgnames, do_not_keep_pkgnames, keep_reasons_by_pkgname = load_keep_file(args.package_decisions_file)
        except (InventoryError, OSError, UnicodeError, tomllib.TOMLDecodeError) as error:
            parser.error(f"--package-decisions-file: {error}")

    try:
        architecture = native_architecture()
        work: Path = args.work_dir
        output: Path = args.output_dir
        root: Path | None = None
        rpm, tdnf = "", ""

        if args.root_dir is not None:
            root, work, output = validate_current_paths(args.root_dir, work, output)
            rpm, tdnf = native_tools(root, package_manager)
        else:
            work, output = work.resolve(), output.resolve()

        work.mkdir(parents=True, exist_ok=True)

        with (work / ".lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

            provenance: dict[str, object] = {}

            if root is not None:
                print(f"Querying current ACL image at {root}...", flush=True)
                with current_image_snapshot(root, work) as (snapshot, source):
                    packages, dependents_by_nvra, architecture = query_database(
                        tools=None,
                        database=None,
                        snapshot=snapshot,
                        rpm_executable=rpm,
                        package_manager_executable=tdnf,
                        package_manager=package_manager,
                    )

                source.update({"packages": len(packages), "architecture": architecture})
                build_id = os.environ.get("BUILD_BUILDID", "")
                if build_id.isdecimal() and int(build_id) > 0:
                    source["build_id"] = int(build_id)

                provenance.update({"mode": "current", "package_manager": package_manager, "acl": source})

                inventory_path = work / "inventories" / "acl-current.json"
                write_inventory(inventory_path, packages, dependents_by_nvra)
                print(f"Wrote raw inventory {inventory_path}", flush=True)
            else:
                assert args.build_id is not None
                provenance["tools_image"] = args.tools_image

                build_rpmdb: Path | None = args.build_rpmdb
                if build_rpmdb is None:
                    if args.acl_template:
                        build_rpmdb, provenance[image_name] = download_acl(work, args.build_id, acl_template=True)
                    else:
                        build_rpmdb, provenance[image_name] = download_acl(work, args.build_id)

                reuse_arguments = [
                    "--build-rpmdb",
                    str(build_rpmdb.resolve()),
                ]
                print(
                    "To skip the database download on the next run, add:\n  " + shlex.join(reuse_arguments),
                    flush=True,
                )

                inventory_path = work / "inventories" / f"{image_name}.json"
                database_digest = sha256(build_rpmdb)
                cache_key: dict[str, object] = {
                    "version": 1,
                    "rpmdb_sha256": database_digest,
                    "tools_image": args.tools_image,
                }
                cached = read_inventory(inventory_path, cache_key)

                if cached is not None:
                    packages, dependents_by_nvra = cached
                    print(f"Reusing cached {image_name} inventory {inventory_path}", flush=True)
                else:
                    print("Preparing Azure Linux tools directory...", flush=True)
                    tools = prepare_tools(work, args.tools_image)
                    provenance["tools_inspect"] = json.loads(root_run(["docker", "image", "inspect", args.tools_image]))

                    print(f"Querying {image_name} RPM database...", flush=True)
                    packages, dependents_by_nvra, _ = query_database(
                        tools,
                        build_rpmdb.resolve(),
                        snapshot=None,
                        rpm_executable="rpm",
                        package_manager_executable=None,
                        package_manager="tdnf",
                    )

                    if sha256(build_rpmdb) != database_digest:
                        raise InventoryError(f"{image_name} RPM database changed during collection; rerun")

                validate_package_architectures(packages, architecture)

                if cached is None:
                    write_inventory(inventory_path, packages, dependents_by_nvra, cache_key=cache_key)
                    print(f"Wrote raw inventory {inventory_path}", flush=True)

                provenance[image_name + "_database"] = {
                    "path": str(build_rpmdb),
                    "sha256": database_digest,
                    "packages": len(packages),
                    "cached": cached is not None,
                }

            validate_no_dependency_cycles(dependents_by_nvra)

            explicit_keep_decisions_by_pkgname = dict.fromkeys(do_not_keep_pkgnames, False)
            explicit_keep_decisions_by_pkgname.update(dict.fromkeys(keep_pkgnames, True))
            remaining_dependents_by_nvra = report_dependents(packages, dependents_by_nvra, explicit_keep_decisions_by_pkgname)

            if args.package_decisions_file is not None:
                provenance["keep_file"] = str(args.package_decisions_file.resolve())

            provenance["keep"] = sorted(keep_pkgnames)
            provenance["do_not_keep"] = sorted(do_not_keep_pkgnames)

            output.mkdir(parents=True, exist_ok=True)

            csv_path = output / "package-decisions.csv"
            write_csv(
                csv_path,
                packages,
                dependents_by_nvra,
                effective_keep_decisions_by_pkgname=explicit_keep_decisions_by_pkgname,
                explicit_keep_decisions_by_pkgname=explicit_keep_decisions_by_pkgname,
                keep_reasons_by_pkgname=keep_reasons_by_pkgname,
                remaining_dependents_by_nvra=remaining_dependents_by_nvra,
            )
            print(f"Wrote {csv_path} ({len(packages)} packages)")

            markdown_path = write_markdown(csv_path, image_title)
            print(f"Wrote {markdown_path}")

            removal_path = output / "packages-selected-for-removal.txt"
            write_removal_list(removal_path, packages, explicit_keep_decisions_by_pkgname)
            print(f"Wrote {removal_path}")

            total_size = sum(package.size for package in packages)
            kept_size = sum(
                package.size for package in packages
                if explicit_keep_decisions_by_pkgname.get(package.name) is not False
            )
            saved_size = total_size - kept_size
            savings_percent = saved_size / total_size * 100 if total_size else 0.0

            print(f"{image_title} total package size: {format_size(total_size)}", flush=True)
            print(f"{image_title} package size excluding removal candidates: {format_size(kept_size)}", flush=True)
            print(f"{image_title} savings: {format_size(saved_size)} ({savings_percent:.2f}%)", flush=True)

            provenance_filename = "package-decisions-provenance.json"
            (output / provenance_filename).write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")

            warn_blank_keep(packages, explicit_keep_decisions_by_pkgname, remaining_dependents_by_nvra)
    except (InventoryError, OSError, subprocess.SubprocessError, sqlite3.Error,
            KeyError, json.JSONDecodeError) as error:
        parser.exit(1, f"Error: {error}\n")


if __name__ == "__main__":
    main()
