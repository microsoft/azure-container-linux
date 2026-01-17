# Hybrid Package Management System for Flatcar

*To note, this document is a bit out of date, but still provides useful information.*

This implementation adds support for using Azure Linux RPM packages alongside traditional Portage packages in Flatcar builds.

## Overview

The hybrid build system allows Flatcar to use packages from multiple sources:
- **Portage/Gentoo**: Traditional Flatcar packages (TBZ2 format)
- **Azure Linux RPM**: Packages from Microsoft's Azure Linux repository

## Build Modes

### PORTAGE_ONLY (Default)
Traditional Flatcar build using only Gentoo/Portage packages. This is the current behavior and maintains full backward compatibility.

```bash
export PACKAGE_SOURCE_MODE="PORTAGE_ONLY"
```

### HYBRID (Recommended)
Uses Azure Linux RPMs for base system components (kernel, systemd, gcc, etc.) while keeping Flatcar-specific packages (ignition, update-engine, OEM packages) from Portage.

```bash
export PACKAGE_SOURCE_MODE="HYBRID"
export RPM_REPO_URL="https://packages.microsoft.com/azurelinux/3.0/prod/base"
export RPM_ARCH="x86_64"
export KERNEL_SOURCE="RPM"
export IGNITION_SOURCE="PORTAGE"
export UPDATE_ENGINE_SOURCE="PORTAGE"
```

### RPM_ONLY (Experimental)
Attempts to use only Azure Linux RPM packages. Requires all Flatcar-specific packages to be available as RPMs.

```bash
export PACKAGE_SOURCE_MODE="RPM_ONLY"
export RPM_REPO_URL="https://packages.microsoft.com/azurelinux/3.0/prod/base"
```

## Build Optimization

For faster builds, you can build only the minimal set of Portage packages:

- **Full build**: Build all ~200 packages, then use hybrid mode during image creation
- **Minimal build**: Build only ~20-40 packages that have no RPM equivalent

See [MINIMAL_BUILD_GUIDE.md](MINIMAL_BUILD_GUIDE.md) for details on minimal package builds.

## Components

### Core Modules

- **`package_catalog.sh`**: Maps Portage package names to Azure Linux RPM equivalents
- **`package_source_config.sh`**: Configuration and package source decision logic
- **`rpm_install.sh`**: RPM installation backend using tdnf/dnf
- **`package_install.sh`**: Unified installation wrapper routing to appropriate backend
- **`resolve_minimal_deps.sh`**: Resolves minimal package dependencies for optimized builds

### Build Scripts

- **`build_packages_minimal`**: Build only packages needed for hybrid mode (optional optimization)

### Modified Files

- **`build_image_util.sh`**: Updated to support both Portage and RPM packages
  - `emerge_to_image()` now routes to appropriate installer
  - `image_packages()` queries both Portage and RPM databases
  - `get_metadata()` handles metadata from both sources

- **`prod_image_util.sh`**: Updated production image build
  - Conditional GCC library installation based on mode
  - Uses unified package installer

### Tools

- **`test_hybrid_build.sh`**: Test and validate hybrid build configuration
- **`report_package_availability.sh`**: Generate reports on package availability

### Configuration Examples

- `config.examples/portage_only.conf`: Traditional Portage-only build
- `config.examples/hybrid.conf`: Recommended hybrid configuration
- `config.examples/rpm_only.conf`: Experimental RPM-only mode

## Usage

### Quick Start (Full Build)

1. **Check package availability:**
```bash
./scripts/report_package_availability.sh --format=text
```

2. **Build all packages:**
```bash
./build_packages --board=amd64-usr
```

3. **Build image with hybrid mode:**
```bash
PACKAGE_SOURCE_MODE=HYBRID ./build_image --board=amd64-usr
```

### Quick Start (Minimal Build - Faster)

1. **Resolve minimal dependencies (in SDK):**
```bash
./build_library/resolve_minimal_deps.sh
```

2. **Build only required packages:**
```bash
./build_packages_minimal --board=amd64-usr
```

3. **Build image with hybrid mode:**
```bash
PACKAGE_SOURCE_MODE=HYBRID ./build_image --board=amd64-usr
```

See [MINIMAL_BUILD_GUIDE.md](MINIMAL_BUILD_GUIDE.md) for full details on minimal builds.

### Configuration Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PACKAGE_SOURCE_MODE` | `PORTAGE_ONLY` | Build mode: `PORTAGE_ONLY`, `HYBRID`, or `RPM_ONLY` |
| `RPM_REPO_URL` | `https://packages.microsoft.com/azurelinux/3.0/prod/base` | Azure Linux repository URL |
| `RPM_RELEASEVER` | `3.0` | Azure Linux release version |
| `RPM_ARCH` | `x86_64` | Architecture: `x86_64` or `aarch64` |
| `RPM_FALLBACK_TO_PORTAGE` | `true` | Fall back to Portage if RPM unavailable |
| `KERNEL_SOURCE` | `RPM` | Source for kernel: `RPM` or `PORTAGE` |
| `IGNITION_SOURCE` | `PORTAGE` | Source for ignition: `RPM` or `PORTAGE` |
| `UPDATE_ENGINE_SOURCE` | `PORTAGE` | Source for update-engine: `RPM` or `PORTAGE` |

## Package Mapping

The `package_catalog.sh` maintains mappings between Portage and RPM packages:

```bash
["sys-kernel/coreos-kernel"]="kernel:AVAILABLE:azure_linux_kernel"
["sys-apps/systemd"]="systemd:AVAILABLE"
["app-admin/ignition"]="ignition:FLATCAR_PREFERRED:can_port_to_rpm"
["coreos-base/oem-azure"]="FLATCAR_ONLY:oem_specific"
```

Status values:
- `AVAILABLE`: Available in Azure Linux with direct mapping
- `FLATCAR_PREFERRED`: Can use either source, Portage preferred
- `FLATCAR_ONLY`: Only available in Portage
- `MISSING`: Not available in either source

## RPM Installation

The RPM installer (`rpm_install.sh`):
1. Initializes RPM database in target rootfs
2. Configures Azure Linux repository
3. Mounts pseudo-filesystems (`/dev`, `/proc`, `/sys`) for scriptlets
4. Uses `tdnf`/`dnf` with `--installroot` for package installation
5. Automatically resolves and installs all dependencies
6. Executes RPM `%post` scriptlets for system configuration

## Benefits

1. **Standard base system**: Use well-tested Azure Linux packages for core components
2. **Reduced maintenance**: Leverage Microsoft's package updates for base system
3. **Flexibility**: Keep Flatcar-specific components in Portage
4. **Gradual migration**: Transition incrementally from Portage to RPM
5. **Dependency management**: Automatic dependency resolution via RPM

## Limitations

1. **File conflicts**: Mixing Portage and RPM packages may cause file conflicts
2. **Path differences**: Azure Linux uses standard FHS paths vs. Gentoo conventions
3. **Package availability**: Not all Flatcar packages available as RPMs
4. **Testing**: Hybrid mode requires extensive testing for production use

## Testing

### Validate Configuration
```bash
./scripts/test_hybrid_build.sh --mode=HYBRID --check_only
```

### Show Package Sources
```bash
./scripts/test_hybrid_build.sh --mode=HYBRID --show_sources
```

### Generate Availability Report
```bash
./scripts/report_package_availability.sh --format=text
./scripts/report_package_availability.sh --format=json --output=report.json
```

## Migration Path

1. **Phase 1**: Test HYBRID mode with kernel from Azure Linux
2. **Phase 2**: Add more base system packages from RPM
3. **Phase 3**: Port ignition and update-engine to RPM build
4. **Phase 4**: Move to RPM_ONLY for base images

## Troubleshooting

### RPM installation fails
- Check repository connectivity: `curl -I ${RPM_REPO_URL}/${RPM_ARCH}/repodata/repomd.xml`
- Verify tdnf/dnf installed: `which tdnf` or `which dnf`
- Check RPM database initialized: `ls -la /path/to/rootfs/var/lib/rpm/`

### Package not found
- Check package catalog: `grep "package-name" scripts/build_library/package_catalog.sh`
- Verify RPM availability: `dnf repoquery --repofrompath=... package-name`
- Add to fallback: `export RPM_FALLBACK_TO_PORTAGE=true`

### File conflicts
- Review conflict: error messages show conflicting files
- Adjust package mapping to exclude conflicting package
- Consider keeping package in Portage-only

## Contributing

To add new package mappings:

1. Edit `scripts/build_library/package_catalog.sh`
2. Add mapping: `["portage/package"]="rpm-name:STATUS:notes"`
3. Test: `./scripts/test_hybrid_build.sh --show_sources`
4. Update availability report: `./scripts/report_package_availability.sh`

## Future Enhancements

- [ ] Automatic package mapping discovery
- [ ] Conflict detection and resolution
- [ ] Performance benchmarking (Portage vs RPM)
- [ ] CI/CD integration tests
- [ ] Support for custom RPM repositories
- [ ] Package version pinning
- [ ] Delta RPM support for updates
