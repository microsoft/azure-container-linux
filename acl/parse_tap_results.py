#!/usr/bin/env python3
"""
Parse TAP (Test Anything Protocol) files and summarize test results.
Groups failing tests by error message and shows statistics.
"""

import re
import sys
from collections import defaultdict
from pathlib import Path


def parse_tap_file(filepath):
    """Parse a TAP file and return test results."""
    passing = []
    failing = []
    skipped = []
    
    current_test = None
    current_error = []
    in_error_block = False
    
    with open(filepath, 'r') as f:
        lines = f.readlines()
    
    i = 0
    while i < len(lines):
        line = lines[i].rstrip()
        
        # Match test result lines
        ok_match = re.match(r'^ok\s+-\s+(.+?)(?:\s+#\s+SKIP.*)?$', line)
        not_ok_match = re.match(r'^not ok\s+-\s+(.+)$', line)
        skip_match = re.match(r'^ok\s+-\s+(.+?)\s+#\s+SKIP', line)
        
        if skip_match:
            skipped.append(skip_match.group(1))
            i += 1
            continue
        elif ok_match:
            passing.append(ok_match.group(1))
            i += 1
            continue
        elif not_ok_match:
            test_name = not_ok_match.group(1)
            # Look for error block
            error_lines = []
            i += 1
            
            # Check for YAML-like error block
            if i < len(lines) and lines[i].strip() == '---':
                i += 1
                while i < len(lines):
                    if lines[i].strip() == '...':
                        i += 1
                        break
                    error_lines.append(lines[i].rstrip())
                    i += 1
            
            # Extract error message
            error_msg = ""
            for eline in error_lines:
                if eline.strip().startswith('Error:'):
                    error_msg = eline.strip()
                    break
            
            if not error_msg and error_lines:
                error_msg = ' '.join(error_lines)
            
            failing.append((test_name, error_msg))
            continue
        
        i += 1
    
    return passing, failing, skipped


def normalize_error_for_grouping(error_msg):
    """Remove UUIDs and other variable parts from error messages for better grouping."""
    if not error_msg:
        return "No error message"
    
    # Remove UUIDs (e.g., d4e53d20-fc27-4ac2-89a9-86cdb210db4d)
    error_msg = re.sub(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', '<UUID>', error_msg, flags=re.IGNORECASE)
    
    # Remove IP addresses (e.g., 10.0.0.2, 192.168.1.1)
    error_msg = re.sub(r'\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b', '<IP>', error_msg)
    
    # Remove port numbers after IPs (e.g., :22, :41617)
    error_msg = re.sub(r'<IP>:\d+', '<IP>:<PORT>', error_msg)
    
    # Remove timestamps (various formats)
    error_msg = re.sub(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z?', '<TIMESTAMP>', error_msg)
    
    # Remove temp file paths like /tmp/tmp.xxxxx
    error_msg = re.sub(r'/tmp/tmp\.[A-Za-z0-9]+', '/tmp/tmp.<RANDOM>', error_msg)
    
    return error_msg


def extract_error_category(error_msg):
    """Extract a category/pattern from an error message for grouping."""
    if not error_msg:
        return "Unknown error"
    
    # Clean up the error message
    error_msg = error_msg.replace('Error: "', '').rstrip('"')
    
    # Common patterns to group by
    patterns = [
        (r'command not found', 'Command not found'),
        (r'No such file or directory', 'File/directory not found'),
        (r'failed basic checks.*systemd units failed', 'Systemd units failed at boot'),
        (r'unable to setup cluster', 'Cluster setup failed'),
        (r'Device .* does not exist', 'Network device missing'),
        (r'docker\.service.*failed', 'Docker service failed'),
        (r'sysext-services\.service.*failed', 'Sysext services failed'),
        (r'SELinux.*not.*enabled', 'SELinux not enabled'),
        (r'selinux.*disabled', 'SELinux disabled'),
        (r'veritysetup.*command not found', 'veritysetup missing'),
        (r'grub\.cfg.*No such file', 'OEM grub.cfg missing'),
        (r'etcd.*failed', 'etcd failure'),
        (r'Process exited with status \d+', 'Process exit failure'),
    ]
    
    for pattern, category in patterns:
        if re.search(pattern, error_msg, re.IGNORECASE):
            return category
    
    # Truncate long messages for grouping
    if len(error_msg) > 100:
        # Try to get the first meaningful part
        first_part = error_msg[:100]
        if ':' in first_part:
            return first_part.split(':')[0] + '...'
        return first_part + '...'
    
    return error_msg


def main():
    if len(sys.argv) < 2:
        # Default path
        tap_file = Path(__file__).parent / "__TESTS__/qemu_uefi/_kola_temp/qemu-2026-01-28-0158-12/test.tap"
        if not tap_file.exists():
            print("Usage: parse_tap_results.py <tap_file>")
            print("Or run from acl-scripts directory with default test.tap location")
            sys.exit(1)
    else:
        tap_file = Path(sys.argv[1])
    
    if not tap_file.exists():
        print(f"Error: File not found: {tap_file}")
        sys.exit(1)
    
    passing, failing, skipped = parse_tap_file(tap_file)
    
    total = len(passing) + len(failing) + len(skipped)
    pass_pct = 100*len(passing)/total if total > 0 else 0
    fail_pct = 100*len(failing)/total if total > 0 else 0
    skip_pct = 100*len(skipped)/total if total > 0 else 0
    
    # Markdown output
    print(f"# Test Results Summary")
    print(f"\n**Source:** `{tap_file}`\n")
    
    # Summary table
    print("## Summary\n")
    print("| Metric | Count | Percentage |")
    print("|--------|------:|-----------:|")
    print(f"| ✅ Passing | {len(passing)} | {pass_pct:.1f}% |")
    print(f"| ❌ Failing | {len(failing)} | {fail_pct:.1f}% |")
    print(f"| ⏭️ Skipped | {len(skipped)} | {skip_pct:.1f}% |")
    print(f"| **Total** | **{total}** | 100% |")
    print()
    
    # List skipped tests
    if skipped:
        print("## Skipped Tests\n")
        print("<details>")
        print(f"<summary>Show {len(skipped)} skipped test(s)</summary>\n")
        for test_name in sorted(skipped):
            print(f"- `{test_name}`")
        print("</details>\n")
    
    # List passing tests
    if passing:
        print("## Passing Tests\n")
        print("<details>")
        print(f"<summary>Show {len(passing)} passing test(s)</summary>\n")
        for test_name in sorted(passing):
            print(f"- `{test_name}`")
        print("</details>\n")
    
    if not failing:
        print("## 🎉 All tests passed!")
        return
    
    # Group failures by error category
    error_groups = defaultdict(list)
    for test_name, error_msg in failing:
        category = extract_error_category(error_msg)
        error_groups[category].append((test_name, error_msg))
    
    # Sort by group size (descending)
    sorted_groups = sorted(error_groups.items(), key=lambda x: len(x[1]), reverse=True)
    
    print("## Failure Groups\n")
    print("Failures grouped by error category, ordered by count:\n")
    
    for i, (category, tests) in enumerate(sorted_groups, 1):
        print(f"### {i}. {category} ({len(tests)} tests)\n")
        
        # Subdivide by unique error messages within the group
        error_subgroups = defaultdict(list)
        for test_name, error_msg in tests:
            # Normalize and shorten for subgrouping
            normalized = normalize_error_for_grouping(error_msg)
            short_error = normalized[:200] if normalized else "No error message"
            error_subgroups[short_error].append(test_name)
        
        if len(error_subgroups) == 1:
            # Single error message, just list tests
            print("**Tests:**\n")
            for test_name, _ in tests:
                print(f"- `{test_name}`")
        else:
            # Multiple unique errors, subdivide
            # Sort by error message lexicographically
            sorted_subgroups = sorted(error_subgroups.items(), key=lambda x: x[0])
            for j, (sub_error, sub_tests) in enumerate(sorted_subgroups, 1):
                # Show a snippet of the error
                error_snippet = sub_error[:100].replace('\\n', ' ').replace('\n', ' ')
                if len(sub_error) > 100:
                    error_snippet += "..."
                print(f"<details>")
                print(f"<summary><b>{i}.{j}.</b> {len(sub_tests)} test(s) - <code>{error_snippet[:60]}...</code></summary>\n")
                print(f"**Error pattern:**")
                print(f"```")
                print(f"{error_snippet}")
                print(f"```\n")
                print(f"**Tests:**")
                for test_name in sorted(sub_tests):
                    print(f"- `{test_name}`")
                print(f"</details>\n")
        print()
    
    # Detailed errors section
    print("## Detailed Errors\n")
    print("One example error per category:\n")
    
    for i, (category, tests) in enumerate(sorted_groups, 1):
        test_name, error_msg = tests[0]
        print(f"<details>")
        print(f"<summary><b>{i}. {category}</b> ({len(tests)} tests)</summary>\n")
        print(f"**Example test:** `{test_name}`\n")
        print(f"**Error:**")
        print(f"```")
        # Pretty print the error
        error_clean = error_msg.replace('\\n', '\n').replace('\\t', '  ')
        print(f"{error_clean[:800]}")
        if len(error_msg) > 800:
            print("[truncated...]")
        print(f"```")
        print(f"</details>\n")


if __name__ == "__main__":
    main()
