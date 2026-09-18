#!/usr/bin/env python3

import argparse
import copy
import dataclasses
import datetime
import hashlib
import json
import os
import re
import sys
import urllib.parse
import uuid
from collections.abc import Callable
from typing import Any

# spdxVersion field value.
# -- https://github.com/spdx/spdx-spec/blob/development/v2.2.2/chapters/document-creation-information.md#61-spdx-version-field-
SPDX_VERSION = "SPDX-2.2"

# dataLicense field value.
# -- https://github.com/spdx/spdx-spec/blob/development/v2.2.2/chapters/document-creation-information.md#62-data-license-field-
DATA_LICENSE = "CC0-1.0"

# SPDXID field value for the document itself.
# -- https://github.com/spdx/spdx-spec/blob/development/v2.2.2/chapters/document-creation-information.md#63-spdx-identifier-field-
SPDXID = "SPDXRef-DOCUMENT"

# SPDXID field value for the package standing in for the artifact as a whole.
# -- https://github.com/spdx/spdx-spec/blob/development/v2.2.2/chapters/package-information.md#72-package-spdx-identifier-field-
ROOT_SPDXID = "SPDXRef-DocumentRoot"

# SPDXID field value for each package. The "SPDXRef-" prefix is mandated and what
# follows it has to be unique across every element in the document, so index is
# included, since package names alone cannot guarantee this.
# -- https://github.com/spdx/spdx-spec/blob/development/v2.2.2/chapters/package-information.md#72-package-spdx-identifier-field-
PACKAGE_SPDXID_FORMAT = "SPDXRef-Package-{index}-{name}"

# SPDXID field value's validation mechanism for packages. This regex is used to
# replace invalid characters in a package name with a dash, so the resulting
# SPDXID is a valid "idstring" per the spec.
# -- https://github.com/spdx/spdx-spec/blob/development/v2.2.2/chapters/package-information.md#72-package-spdx-identifier-field-
NON_SPDXID = re.compile(r"[^A-Za-z0-9.\-]")

# documentNamespace field value base. It doesn't need to be a resolvable URL.
# It just needs to be a unique URI for the document.
# -- https://github.com/spdx/spdx-spec/blob/development/v2.2.2/chapters/document-creation-information.md#65-spdx-document-namespace-field-
DOCUMENT_NAMESPACE_BASE = "https://spdx.org/spdxdocs"

# This regex validates --manifest-name, which becomes a path segment of documentNamespace.
# The spec requires to be an absolute RFC 3986 URI, "#" excepted.
# This regex admits exactly what RFC 3986 allows in a path segment.
# -- https://github.com/spdx/spdx-spec/blob/development/v2.2.2/chapters/document-creation-information.md#65-spdx-document-namespace-field-
# -- https://www.rfc-editor.org/rfc/rfc3986#section-3.3
MANIFEST_NAME_RE = re.compile(r"(?:[A-Za-z0-9\-._~!$&'()*+,;=:@]|%[0-9A-Fa-f]{2})+")

# externalRefs[0].referenceCategory field value for each package.
# -- https://github.com/spdx/spdx-spec/blob/development/v2.2.2/chapters/package-information.md#721-external-reference-field-
REFERENCE_CATEGORY = "PACKAGE_MANAGER"

# externalRefs[0].referenceType field value. Describes the reference locator.
# Annex F registers purl under the PACKAGE_MANAGER category.
# -- https://github.com/spdx/spdx-spec/blob/development/v2.2.2/chapters/external-repository-identifiers.md#f35-purl-
REFERENCE_TYPE = "purl"

# externalRefs[0].referenceLocator field value's namespace for each package.
# Reference locators are RPM-type PURLs, and their namespace is the vendor. This
# value is taken from Azure Container Linux's os-release ID.
# -- https://github.com/package-url/purl-spec/blob/main/docs/types/definitions/rpm-definition.md#namespace-definition
PURL_NAMESPACE = "azurelinux"

# relationships[].relationshipType field value tying the document to the root
# package.
# -- https://github.com/spdx/spdx-spec/blob/development/v2.2.2/chapters/relationships-between-SPDX-elements.md#111-relationship-field-
DESCRIBES_RELATIONSHIP_TYPE = "DESCRIBES"

# relationships[].relationshipType field value tying each package to the root.
# -- https://github.com/spdx/spdx-spec/blob/development/v2.2.2/chapters/relationships-between-SPDX-elements.md#111-relationship-field-
CONTAINS_RELATIONSHIP_TYPE = "CONTAINS"

# Prefix for a package's supplier, which is the RPM vendor. syft builds the same
# string for an rpmdb entry, taking the organization from the vendor tag, and its
# Supplier() falls through to that for RPMs.
# -- https://github.com/spdx/spdx-spec/blob/development/v2.2.2/chapters/package-information.md#75-package-supplier-field-
SUPPLIER_ORGANIZATION_PREFIX = "Organization: "

# Stands in for a field the document creator has not determined.
NOASSERTION = "NOASSERTION"

# What rpm's query format prints for a tag the package does not carry.
RPM_TAG_NONE = "(none)"

# rpmdb pseudo-entries for imported signing keys, which have no architecture.
# This cannot match real package NEVRAs, which always end in ".<arch>".
GPG_PUBKEY_RE = re.compile(r"^gpg-pubkey-[0-9a-f-]+\Z")

# --packages-format values, named for the expected per-line input layout.
PACKAGES_FORMAT_NEVRA = "nevra"
PACKAGES_FORMAT_TDNF = "tdnf"
PACKAGES_FORMAT_CONTAINER_MANIFEST_2 = "container-manifest-2"
PACKAGES_FORMATS = [
    PACKAGES_FORMAT_NEVRA,
    PACKAGES_FORMAT_TDNF,
    PACKAGES_FORMAT_CONTAINER_MANIFEST_2,
]

# Column count of a `tdnf list installed` line.
TDNF_COLUMNS = 3

# Column count of a container-manifest-2 line.
RPM_MANIFEST_COLUMN_NUM = 10

# Column indices of the container-manifest-2 fields this script reads.
RPM_MANIFEST_NAME = 0
RPM_MANIFEST_VERSION_RELEASE = 1
RPM_MANIFEST_VENDOR = 4
RPM_MANIFEST_EPOCH = 5
RPM_MANIFEST_ARCH = 7

# This regex validates --created-epoch.
CREATED_EPOCH_RE = re.compile(r"[0-9]+")


@dataclasses.dataclass(frozen=True)
class Package:
    name: str
    epoch: int | None
    version: str
    release: str
    arch: str
    vendor: str | None

    @property
    def evr(self) -> str:
        epoch = f"{self.epoch}:" if self.epoch is not None else ""
        return f"{epoch}{self.version}-{self.release}"

    @property
    def evra(self) -> str:
        return f"{self.evr}.{self.arch}"

    @property
    def nevra(self) -> str:
        return f"{self.name}-{self.evra}"

    @property
    def supplier(self) -> str:
        if self.vendor == NOASSERTION:
            print(
                f"WARNING: Clearing vendor ({self.vendor}) for package ({self.name}): "
                "Reserved SPDX keyword and cannot be used",
                file=sys.stderr,
            )
            return NOASSERTION

        if not self.vendor:
            return NOASSERTION

        return f"{SUPPLIER_ORGANIZATION_PREFIX}{self.vendor}"


def create_package(name: str, epoch: str, version: str, release: str, arch: str, vendor: str = "") -> Package:
    """Validate raw RPM identity fields and normalize the epoch and vendor."""
    name = name.strip()
    epoch = epoch.strip()
    version = version.strip()
    release = release.strip()
    arch = arch.strip()
    vendor = vendor.strip()

    if not name:
        raise ValueError("empty package name")

    if not version:
        raise ValueError("empty package version")

    if not release:
        raise ValueError("empty package release")

    if not arch:
        raise ValueError("empty package architecture")

    return Package(
        name=name,
        epoch=int(epoch) if epoch else None,
        version=version,
        release=release,
        arch=arch,
        vendor=vendor or None,
    )


def parse_nevra_package(nevra: str) -> Package | None:
    """`rpm -qa --qf '%{NEVRA}\\n'` line -> Package.

    The lines are <name>-[<epoch>:]<version>-<release>.<arch>, which is the
    NEVRA format.
    """
    nevra = nevra.strip()
    if GPG_PUBKEY_RE.fullmatch(nevra):
        return None

    nevr, _, arch = nevra.rpartition(".")
    nev, _, release = nevr.rpartition("-")
    name, _, ev = nev.rpartition("-")
    epoch, _, version = ev.rpartition(":")

    return create_package(
        name=name,
        epoch=epoch,
        version=version,
        release=release,
        arch=arch,
    )


def parse_tdnf_package(line: str) -> Package:
    """`tdnf list installed` line -> Package.

    The columns are <name>.<arch>, <[epoch:]version-release> and @<repo>,
    space-padded to align. An image carrying tdnf but no rpm binary can still
    produce this.
    """
    columns = line.split()
    if len(columns) != TDNF_COLUMNS:
        raise ValueError(
            f"expected '<name>.<arch> <[epoch:]version-release> @<repo>' "
            f"[columns={len(columns)}, expected {TDNF_COLUMNS}]"
        )

    name_arch, evr, _ = columns

    name, _, arch = name_arch.rpartition(".")
    ev, _, release = evr.rpartition("-")
    epoch, _, version = ev.rpartition(":")

    return create_package(
        name=name,
        epoch=epoch,
        version=version,
        release=release,
        arch=arch,
    )


def parse_container_manifest_2_package(line: str) -> Package | None:
    """container-manifest-2 line -> Package."""
    raw_columns = line.split("\t")
    if len(raw_columns) != RPM_MANIFEST_COLUMN_NUM:
        raise ValueError(
            f"expected a tab-separated container-manifest-2 line "
            f"[columns={len(raw_columns)}, expected {RPM_MANIFEST_COLUMN_NUM}]"
        )

    columns = ["" if c == RPM_TAG_NONE else c for c in raw_columns]
    if not columns[RPM_MANIFEST_ARCH]:
        return None

    version, _, release = columns[RPM_MANIFEST_VERSION_RELEASE].rpartition("-")

    return create_package(
        name=columns[RPM_MANIFEST_NAME],
        epoch=columns[RPM_MANIFEST_EPOCH],
        version=version,
        release=release,
        arch=columns[RPM_MANIFEST_ARCH],
        vendor=columns[RPM_MANIFEST_VENDOR],
    )


def read_entries(packages_file: str) -> list[tuple[int, str]]:
    """Line number and content of every nonempty line in a package list."""
    entries: list[tuple[int, str]] = []

    with open(packages_file, "r", encoding="utf-8") as f:
        for number, line in enumerate(f, 1):
            entry = line.rstrip("\r\n")
            if entry.strip():
                entries.append((number, entry))

    return entries


def read_packages(packages_file: str, parse: Callable[[str], Package | None]) -> list[Package]:
    seen: set[str] = set()
    packages: list[Package] = []

    for number, entry in read_entries(packages_file):
        try:
            package = parse(entry)
        except ValueError as error:
            raise ValueError(f"{packages_file}:{number}: {error} [line={entry!r}]") from error

        if package is None:
            continue

        if package.nevra in seen:
            print(
                f"WARNING: {packages_file}:{number}: Duplicate installed package NEVRA [id={package.nevra}] [line={entry!r}]",
                file=sys.stderr,
            )

        seen.add(package.nevra)
        packages.append(package)

    if not packages:
        raise ValueError("the image reported no installed packages")

    return packages


def purl_encode(component_data: str) -> str:
    """Percent-encode purl component data.

    Preserve alphanumerics, ".-_~", and ":", matching PURL. Other characters are
    encoded, so the "+" in libstdc++ becomes "%2B".
    -- https://github.com/package-url/purl-spec/blob/main/docs/specification/standard/specification.md#character-encoding
    """
    return urllib.parse.quote(component_data, safe=":")


def package_url(package: Package) -> str:
    """Package URL for an RPM, per the purl rpm type."""
    qualifiers = [f"arch={purl_encode(package.arch)}"]
    if package.epoch is not None:
        qualifiers.append(f"epoch={package.epoch}")

    name = purl_encode(package.name)
    version = purl_encode(f"{package.version}-{package.release}")

    return f"pkg:rpm/{PURL_NAMESPACE}/{name}@{version}?{'&'.join(qualifiers)}"


def created(created_epoch: int) -> str:
    """Build creationInfo.created, which the spec fixes to UTC to the second.

    -- https://github.com/spdx/spdx-spec/blob/development/v2.2.2/chapters/document-creation-information.md#69-created-field-
    """
    return datetime.datetime.fromtimestamp(created_epoch, tz=datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def creator() -> str:
    """Build creationInfo.creators, which is spec'd as "toolidentifier-version".

    This script ships with the repo and has no release of its own, so the version
    is a digest of its own source. A hand-maintained constant would drift.
    -- https://github.com/spdx/spdx-spec/blob/development/v2.2.2/chapters/document-creation-information.md#68-creator-field-
    """
    name = os.path.splitext(os.path.basename(__file__))[0]

    with open(__file__, "rb") as f:
        version = hashlib.sha256(f.read()).hexdigest()

    return f"Tool: {name}-{version}"


def json_dumps(document: dict[str, Any]) -> str:
    """Match Image Customizer's indented JSON, including its trailing newline."""
    serialized = json.dumps(document, indent=2, ensure_ascii=False, sort_keys=True)
    return serialized.replace("\u2028", "\\u2028").replace("\u2029", "\\u2029") + "\n"


def document_namespace(document: dict[str, Any]) -> str:
    """Build the documentNamespace URI.

    Follows the recommended [CreatorWebsite]/[pathToSpdx]/[DocumentName]-[UUID]
    shape, building a version 5 UUID over entire document, so the same document
    will always produce the same documentNamespace.
    -- https://github.com/spdx/spdx-spec/blob/development/v2.2.2/chapters/document-creation-information.md#65-spdx-document-namespace-field-
    """
    seed = json_dumps(document)
    unique = uuid.uuid5(uuid.NAMESPACE_URL, seed)

    return f"{DOCUMENT_NAMESPACE_BASE}/{document['name']}-{unique}"


def create_package_manifest(
    manifest_name: str,
    manifest_version: str,
    packages: list[Package],
    created_epoch: int,
) -> dict[str, Any]:
    packages = sorted(packages, key=lambda package: package.nevra)

    spdx_packages: list[dict[str, Any]] = [
        {
            "name": manifest_name,
            "SPDXID": ROOT_SPDXID,
            "versionInfo": manifest_version,
            "supplier": NOASSERTION,
            "downloadLocation": NOASSERTION,
            "filesAnalyzed": False,
            "licenseConcluded": NOASSERTION,
            "licenseDeclared": NOASSERTION,
            "copyrightText": NOASSERTION,
        }
    ]
    spdx_package_ids: list[str] = []

    for index, package in enumerate(packages):
        spdx_package_id = PACKAGE_SPDXID_FORMAT.format(
            index=index,
            name=NON_SPDXID.sub("-", package.name)
        )
        spdx_package_ids.append(spdx_package_id)
        spdx_packages.append(
            {
                "name": package.name,
                "SPDXID": spdx_package_id,
                "versionInfo": package.evr,
                "supplier": package.supplier,
                "downloadLocation": NOASSERTION,
                "filesAnalyzed": False,
                "licenseConcluded": NOASSERTION,
                "licenseDeclared": NOASSERTION,
                "copyrightText": NOASSERTION,
                "externalRefs": [
                    {
                        "referenceCategory": REFERENCE_CATEGORY,
                        "referenceType": REFERENCE_TYPE,
                        "referenceLocator": package_url(package),
                    }
                ],
            }
        )

    relationships: list[dict[str, str]] = [
        {
            "spdxElementId": SPDXID,
            "relatedSpdxElement": ROOT_SPDXID,
            "relationshipType": DESCRIBES_RELATIONSHIP_TYPE,
        }
    ]
    relationships.extend(
        {
            "spdxElementId": ROOT_SPDXID,
            "relatedSpdxElement": spdx_id,
            "relationshipType": CONTAINS_RELATIONSHIP_TYPE,
        }
        for spdx_id in spdx_package_ids
    )

    document: dict[str, Any] = {
        "spdxVersion": SPDX_VERSION,
        "dataLicense": DATA_LICENSE,
        "SPDXID": SPDXID,
        "name": manifest_name,
        "documentNamespace": "",
        "creationInfo": {
            "creators": [creator()],
            "created": created(created_epoch),
        },
        "packages": spdx_packages,
        "relationships": relationships,
    }
    document["documentNamespace"] = document_namespace(document)
    return document


def write_json(path: str, document: dict[str, Any]) -> None:
    with open(path, "w", encoding="utf-8") as f:
        f.write(json_dumps(document))


def validate_input_file(value: str) -> str:
    if not os.path.isfile(value):
        raise argparse.ArgumentTypeError(
            f"expected an existing file [value={value!r}]"
        )

    return value


def validate_manifest_name(value: str) -> str:
    if not MANIFEST_NAME_RE.fullmatch(value):
        raise argparse.ArgumentTypeError(
            f"expected a non-empty URI path segment [value={value!r}]"
        )

    return value


def validate_manifest_version(value: str) -> str:
    if not value.strip():
        raise argparse.ArgumentTypeError(
            f"expected a non-empty version [value={value!r}]"
        )

    return value


def validate_created_epoch(value: str) -> int:
    if not CREATED_EPOCH_RE.fullmatch(value):
        raise argparse.ArgumentTypeError(
            f"expected a non-negative Unix timestamp [value={value!r}]"
        )

    return int(value)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate an SPDX 2.2 package manifest from an installed package list."
    )

    parser.add_argument(
        "--packages-file",
        required=True,
        type=validate_input_file,
        help="The path to the package list to convert, one package per line. (required)",
    )

    parser.add_argument(
        "--packages-format",
        default=PACKAGES_FORMAT_CONTAINER_MANIFEST_2,
        choices=PACKAGES_FORMATS,
        help=(
            f"The format of --packages-file. "
            f"'{PACKAGES_FORMAT_NEVRA}' is one NEVRA per line. "
            f"'{PACKAGES_FORMAT_TDNF}' is `tdnf list installed` output, for an image "
            f"carrying no rpm binary. "
            f"'{PACKAGES_FORMAT_CONTAINER_MANIFEST_2}' is a tab-separated RPM listing. "
            f"The latter is recommended since only it includes RPM vendor information. "
            f"(optional, default: {PACKAGES_FORMAT_CONTAINER_MANIFEST_2})"
        ),
    )

    parser.add_argument(
        "--manifest-file",
        required=True,
        help=(
            "The path to the SPDX document to generate. Its parent directory must already exist. (required)"
        ),
    )

    parser.add_argument(
        "--manifest-name",
        required=True,
        type=validate_manifest_name,
        help="The SPDX document name, e.g. the image or sysext name. (required)",
    )

    parser.add_argument(
        "--manifest-version",
        required=True,
        type=validate_manifest_version,
        help=(
            "The version of the image or sysext being described. Becomes the "
            "root package's versionInfo. (required)"
        ),
    )

    parser.add_argument(
        "--created-epoch",
        required=True,
        type=validate_created_epoch,
        help="The Unix timestamp for the document's created field. (required)",
    )

    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite the SPDX document if it already exists. (optional)",
    )

    args = parser.parse_args()

    if not args.force and os.path.lexists(args.manifest_file):
        parser.error(
            f"manifest file already exists, pass --force to overwrite it "
            f"[value={args.manifest_file!r}]"
        )

    return args


def main() -> int:
    args = parse_args()
    packages_file: str = args.packages_file
    packages_format: str = args.packages_format
    manifest_file: str = args.manifest_file
    manifest_name: str = args.manifest_name
    manifest_version: str = args.manifest_version
    created_epoch: int = args.created_epoch

    if packages_format == PACKAGES_FORMAT_TDNF:
        parse = parse_tdnf_package
    elif packages_format == PACKAGES_FORMAT_CONTAINER_MANIFEST_2:
        parse = parse_container_manifest_2_package
    else:
        parse = parse_nevra_package

    try:
        packages = read_packages(packages_file, parse)
    except ValueError as error:
        print(
            f"{os.path.basename(__file__)}: failed to read packages: {error}",
            file=sys.stderr,
        )
        return 1

    manifest = create_package_manifest(
        manifest_name,
        manifest_version,
        packages,
        created_epoch,
    )
    write_json(manifest_file, manifest)

    return 0


if __name__ == "__main__":
    sys.exit(main())
