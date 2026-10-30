# Package reports and removal policy

[`report_image_packages.py`](../../build_library/rpm/report_image_packages.py) reports installed RPM packages, policy decisions, reasons, and their remaining dependents. It can be run against a mounted image or an ACL/ACL-T build artifact. The standalone script only reports; it never removes packages from the source image.

RPM image builds also use the reporter. A separate build hook reads its removal list and, by default, erases those packages before building embedded system extensions and generating SBOMs.

## Why this exists

1. **Remove unnecessary packages with dependency checks.** Removing unused packages reduces the software shipped on every node, along with its maintenance and vulnerability-tracking burden. Package sizes and top-level dependents help identify what can be removed and which applications keep libraries installed. The build fails if a package being kept depends on a package selected for removal. Runtime testing is still necessary for uses that RPM dependencies do not describe.

2. **Make package decisions reviewable.** The checked-in TOML policy records each explicit keep or remove decision and its reason. Reviewers can see why a package ships, challenge that decision, and preserve the rationale for future changes. The reports connect those decisions to the installed package versions.

3. **Surface new removal candidates during builds.** A package with no remaining dependents and no policy entry produces a warning. This gives maintainers a prompt to review unexplained packages as the image changes.

## Policy and outputs

The build uses [`acl/package-decisions.toml`](../package-decisions.toml). Each package table has a Boolean `keep` and a string `reason`:

| Decision | Behavior |
| --- | --- |
| `keep = true` | Keep the installed package. |
| `keep = false` | Select the installed package for removal. |
| No entry | Keep the package, but warn if it has no remaining dependents. |

A package with no remaining dependents is a candidate for removal, but it may still be needed directly at runtime. If it has no TOML entry, the reporter warns so you can record an explicit keep or remove decision and its reason. The warning alone does not select the package for removal.

The reporter writes these files under `--output-dir`:

| File | Contents |
| --- | --- |
| `package-decisions.csv` | Installed package identities, sizes, decisions, reasons, and remaining dependents. |
| `package-decisions.md` | The same report as a Markdown table. |
| `packages-selected-for-removal.txt` | Sorted installed package names selected for removal, one per line. |
| `package-decisions-provenance.json` | Collection inputs, database identity, and applied decisions. |

It also prints package-size totals and estimated savings. These are RPM package sizes, not measured disk-image savings.

## Analyze a mounted image

Run the examples from the repository root. The script requires Python 3.11 or newer on x86_64/aarch64 Linux, plus native `rpm` and `dnf5` on `PATH`. The image must still contain its SQLite RPM database and an `os-release` file, with its separate `/usr` mounted if applicable.

Replace `/path/to/mounted-image` with the mounted image root:

```bash
python3 -B build_library/rpm/report_image_packages.py \
  --root-dir /path/to/mounted-image \
  --package-decisions-file acl/package-decisions.toml \
  --work-dir _tmp/package-report-work \
  --output-dir _tmp/package-reports
```

DNF5 is the default solver and supports cross-architecture image analysis. `--package-manager tdnf` selects the alternative native solver, which requires matching host and image package architectures.

## Analyze a build artifact

Supply a positive numeric `--build-id`. Exactly one of `--build-id` and `--root-dir` is required. Artifact collection requires Python 3.11 or newer on x86_64/aarch64 Linux matching the artifact architecture, Docker, and permission to run the privileged tools through noninteractive sudo when not root.

Downloading also requires Azure CLI authentication and access to the selected Azure DevOps build. Sign in with `az login` before running:

```bash
python3 -B build_library/rpm/report_image_packages.py \
  --build-id 1237844 \
  --package-decisions-file acl/package-decisions.toml \
  --work-dir _tmp/build-package-report-work \
  --output-dir _tmp/build-package-reports
```

| Optional flag | Purpose |
| --- | --- |
| `--acl-template` | Download the build's ACL-T VHDX and extract its RPM database using read-only mounts. Requires `qemu-nbd`, partition tools, and an available NBD device. |
| `--build-rpmdb PATH` | Use an existing SQLite RPM database and skip the artifact download. Azure CLI authentication is then unnecessary. |
| `--tools-image IMAGE` | Override the tools image, defaulting to `mcr.microsoft.com/azurelinux/base/core:3.0`. |

The script exports the tools image into a work-directory chroot and uses its RPM and tdnf tools.

## Build and pipeline modes

All pipelines that build RPM base images expose `packageOperation` at queue time, including development, official, nightly, production, fast-track, and PR validation pipelines. They forward the selection as `PACKAGE_OPERATION` through base-image assembly and the SDK login shell.

| `packageOperation` / `PACKAGE_OPERATION` | Behavior |
| --- | --- |
| `report-and-remove` | Default. Run dependency checks and cycle validation, generate reports, then erase selected packages. |
| `report-only` | Run dependency checks and cycle validation and generate reports, but skip selected-package removal. |
| `disabled` | Skip dependency checks, cycle validation, reporting, and selected-package removal. |

The default is `report-and-remove`. An unset or empty environment value also selects that default.

Pipelines that only test, customize, or publish existing images do not expose this option. The setting only applies when the run builds an RPM base image; it has no effect when the run reuses an existing image.

For a local report-only build:

```bash
PACKAGE_OPERATION=report-only ./acl/build_rpm_image.sh --rebuild
```

This command builds an image. Use the standalone reporter above to analyze an existing image without rebuilding it. `PACKAGE_OPERATION` does not change the reporter scripts's behavior when run by itself.

The integration is implemented by [`report_and_remove_image_packages_rpm`](../../build_library/rpm/build_image_util.sh) and called from [`create_prod_image`](../../build_library/prod_image_util.sh). See the [build guide](BUILD_RPM_IMAGE_README.md#phase-3-build-the-image) for the complete image-build workflow.
