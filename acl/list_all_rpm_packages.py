#!/usr/bin/env python3
"""
Generate a consolidated list of all RPM packages across the ACL image components.

This script combines packages from:
- Base production image (acl_production_image_packages.txt)
- OEM Azure layer (oem-azure_packages.txt)
- Containerd sysext (containerd_packages.txt)
- Docker sysext (docker_packages.txt)

Usage:
    ./list_all_rpm_packages.py [--build-dir PATH] [--format FORMAT] [--output FILE]

Options:
    --build-dir PATH    Path to build output directory
                        Default: ../__build__/images/images/amd64-usr/latest
    --format FORMAT     Output format: 'list', 'table', 'json', 'markdown'
                        Default: list
    --output FILE       Write output to file instead of stdout
    --by-component      Group packages by component
    --unique-only       Only show packages (no component info)
    --show-duplicates   Highlight packages present in multiple components
"""

import argparse
import json
import os
import sys
from collections import defaultdict
from pathlib import Path


# Package file locations relative to build directory
PACKAGE_FILES = {
    'base': 'acl_production_image_packages.txt',
    'oem-azure': 'oem-azure_packages.txt',
    'containerd': 'rootfs-included-sysexts/containerd_packages.txt',
    'docker': 'rootfs-included-sysexts/docker_packages.txt',
}

# Friendly names for components
COMPONENT_NAMES = {
    'base': 'Base Image',
    'oem-azure': 'OEM Azure',
    'containerd': 'Containerd Sysext',
    'docker': 'Docker Sysext',
}


def parse_package_file(filepath: Path) -> set:
    """Parse a packages.txt file and return set of package names."""
    packages = set()
    if not filepath.exists():
        return packages
    
    with open(filepath, 'r') as f:
        for line in f:
            line = line.strip()
            # Skip empty lines and comments
            if not line or line.startswith('#'):
                continue
            packages.add(line)
    
    return packages


def load_all_packages(build_dir: Path) -> dict:
    """Load packages from all component files."""
    components = {}
    
    for component, filename in PACKAGE_FILES.items():
        filepath = build_dir / filename
        packages = parse_package_file(filepath)
        components[component] = {
            'file': str(filepath),
            'exists': filepath.exists(),
            'packages': packages,
            'count': len(packages),
        }
    
    return components


def get_all_unique_packages(components: dict) -> set:
    """Get all unique packages across all components."""
    all_packages = set()
    for data in components.values():
        all_packages.update(data['packages'])
    return all_packages


def get_package_sources(components: dict) -> dict:
    """Map each package to the components it appears in."""
    package_sources = defaultdict(list)
    
    for component, data in components.items():
        for pkg in data['packages']:
            package_sources[pkg].append(component)
    
    return dict(package_sources)


def format_list(components: dict, unique_only: bool = False, 
                by_component: bool = False, show_duplicates: bool = False) -> str:
    """Format output as simple list."""
    lines = []
    
    if by_component:
        for component, data in components.items():
            if not data['exists']:
                lines.append(f"\n# {COMPONENT_NAMES[component]} (file not found)")
                continue
            
            lines.append(f"\n# {COMPONENT_NAMES[component]} ({data['count']} packages)")
            lines.append(f"# Source: {data['file']}")
            for pkg in sorted(data['packages']):
                lines.append(pkg)
    else:
        all_packages = get_all_unique_packages(components)
        package_sources = get_package_sources(components)
        
        lines.append(f"# Total unique packages: {len(all_packages)}")
        lines.append("")
        
        for pkg in sorted(all_packages):
            if show_duplicates and len(package_sources[pkg]) > 1:
                sources = ', '.join(package_sources[pkg])
                lines.append(f"{pkg}  # in: {sources}")
            else:
                lines.append(pkg)
    
    return '\n'.join(lines)


def format_table(components: dict, show_duplicates: bool = False) -> str:
    """Format output as ASCII table."""
    lines = []
    all_packages = get_all_unique_packages(components)
    package_sources = get_package_sources(components)
    
    # Header
    lines.append("=" * 100)
    lines.append("ACL RPM Package Inventory")
    lines.append("=" * 100)
    lines.append("")
    
    # Summary
    lines.append("Component Summary:")
    lines.append("-" * 50)
    for component, data in components.items():
        status = f"{data['count']} packages" if data['exists'] else "FILE NOT FOUND"
        lines.append(f"  {COMPONENT_NAMES[component]:20} {status}")
    lines.append("-" * 50)
    lines.append(f"  {'Total Unique':20} {len(all_packages)} packages")
    lines.append("")
    
    if show_duplicates:
        # Show packages in multiple components
        duplicates = {pkg: sources for pkg, sources in package_sources.items() 
                     if len(sources) > 1}
        if duplicates:
            lines.append("Packages in Multiple Components:")
            lines.append("-" * 80)
            for pkg in sorted(duplicates.keys()):
                sources = ', '.join(duplicates[pkg])
                lines.append(f"  {pkg}")
                lines.append(f"    -> {sources}")
            lines.append("")
    
    # Full package list
    lines.append("All Packages (sorted):")
    lines.append("-" * 80)
    for pkg in sorted(all_packages):
        lines.append(f"  {pkg}")
    
    return '\n'.join(lines)


def format_markdown(components: dict, show_duplicates: bool = False) -> str:
    """Format output as Markdown."""
    lines = []
    all_packages = get_all_unique_packages(components)
    package_sources = get_package_sources(components)
    
    lines.append("# ACL RPM Package Inventory")
    lines.append("")
    
    # Summary table
    lines.append("## Summary")
    lines.append("")
    lines.append("| Component | Package Count | Status |")
    lines.append("|-----------|---------------|--------|")
    for component, data in components.items():
        status = "✅" if data['exists'] else "❌ Not Found"
        count = data['count'] if data['exists'] else "-"
        lines.append(f"| {COMPONENT_NAMES[component]} | {count} | {status} |")
    lines.append(f"| **Total Unique** | **{len(all_packages)}** | |")
    lines.append("")
    
    # By component
    lines.append("## Packages by Component")
    lines.append("")
    for component, data in components.items():
        lines.append(f"### {COMPONENT_NAMES[component]}")
        lines.append("")
        if not data['exists']:
            lines.append(f"*File not found: `{data['file']}`*")
        elif not data['packages']:
            lines.append("*No packages*")
        else:
            lines.append(f"*{data['count']} packages from `{data['file']}`*")
            lines.append("")
            lines.append("```")
            for pkg in sorted(data['packages']):
                lines.append(pkg)
            lines.append("```")
        lines.append("")
    
    if show_duplicates:
        duplicates = {pkg: sources for pkg, sources in package_sources.items() 
                     if len(sources) > 1}
        if duplicates:
            lines.append("## Packages in Multiple Components")
            lines.append("")
            lines.append("| Package | Components |")
            lines.append("|---------|------------|")
            for pkg in sorted(duplicates.keys()):
                sources = ', '.join(COMPONENT_NAMES[c] for c in duplicates[pkg])
                lines.append(f"| `{pkg}` | {sources} |")
            lines.append("")
    
    return '\n'.join(lines)


def format_json(components: dict) -> str:
    """Format output as JSON."""
    all_packages = get_all_unique_packages(components)
    package_sources = get_package_sources(components)
    
    output = {
        'summary': {
            'total_unique_packages': len(all_packages),
            'components': {}
        },
        'components': {},
        'all_packages': sorted(all_packages),
        'package_sources': {pkg: sorted(sources) for pkg, sources in package_sources.items()}
    }
    
    for component, data in components.items():
        output['summary']['components'][component] = {
            'name': COMPONENT_NAMES[component],
            'count': data['count'],
            'exists': data['exists'],
            'file': data['file'],
        }
        output['components'][component] = {
            'name': COMPONENT_NAMES[component],
            'file': data['file'],
            'exists': data['exists'],
            'packages': sorted(data['packages']),
        }
    
    return json.dumps(output, indent=2)


def main():
    parser = argparse.ArgumentParser(
        description='Generate consolidated list of ACL RPM packages',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )
    
    # Determine default build directory
    script_dir = Path(__file__).parent
    default_build_dir = script_dir.parent / '__build__' / 'images' / 'images' / 'amd64-usr' / 'latest'
    
    parser.add_argument('--build-dir', '-d', type=Path, default=default_build_dir,
                        help=f'Path to build output directory (default: {default_build_dir})')
    parser.add_argument('--format', '-f', choices=['list', 'table', 'json', 'markdown', 'md'],
                        default='list', help='Output format (default: list)')
    parser.add_argument('--output', '-o', type=Path,
                        help='Write output to file instead of stdout')
    parser.add_argument('--by-component', '-c', action='store_true',
                        help='Group packages by component (list format only)')
    parser.add_argument('--unique-only', '-u', action='store_true',
                        help='Only show unique package names')
    parser.add_argument('--show-duplicates', '-D', action='store_true',
                        help='Highlight packages in multiple components')
    parser.add_argument('--quiet', '-q', action='store_true',
                        help='Suppress informational messages')
    
    args = parser.parse_args()
    
    # Validate build directory
    if not args.build_dir.exists():
        print(f"Error: Build directory not found: {args.build_dir}", file=sys.stderr)
        print("Run a build first or specify --build-dir", file=sys.stderr)
        sys.exit(1)
    
    # Load all packages
    if not args.quiet:
        print(f"Loading packages from: {args.build_dir}", file=sys.stderr)
    
    components = load_all_packages(args.build_dir)
    
    # Check for missing files
    missing = [c for c, d in components.items() if not d['exists']]
    if missing and not args.quiet:
        print(f"Warning: Missing package files for: {', '.join(missing)}", file=sys.stderr)
    
    # Format output
    fmt = args.format.lower()
    if fmt == 'md':
        fmt = 'markdown'
    
    if fmt == 'list':
        output = format_list(components, args.unique_only, args.by_component, args.show_duplicates)
    elif fmt == 'table':
        output = format_table(components, args.show_duplicates)
    elif fmt == 'json':
        output = format_json(components)
    elif fmt == 'markdown':
        output = format_markdown(components, args.show_duplicates)
    else:
        print(f"Unknown format: {fmt}", file=sys.stderr)
        sys.exit(1)
    
    # Write output
    if args.output:
        with open(args.output, 'w') as f:
            f.write(output)
            f.write('\n')
        if not args.quiet:
            print(f"Output written to: {args.output}", file=sys.stderr)
    else:
        print(output)


if __name__ == '__main__':
    main()
