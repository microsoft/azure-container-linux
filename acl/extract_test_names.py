#!/usr/bin/env python3
"""
Extract test names from a TAP (Test Anything Protocol) file.
Outputs one test name per line, sorted alphabetically.

Usage:
    ./extract_test_names.py <tap_file>
    ./extract_test_names.py results.tap
"""

import re
import sys


def extract_test_names(tap_file: str) -> list[str]:
    """Extract unique test names from a TAP file."""
    test_names = set()
    
    # Match lines like:
    # "ok - test.name"
    # "not ok - test.name"
    pattern = re.compile(r'^(ok|not ok)\s+-\s+(.+)$')
    
    with open(tap_file, 'r') as f:
        for line in f:
            line = line.rstrip()
            match = pattern.match(line)
            if match:
                test_name = match.group(2).strip()
                test_names.add(test_name)
    
    return sorted(test_names)


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <tap_file>", file=sys.stderr)
        sys.exit(1)
    
    tap_file = sys.argv[1]
    
    try:
        test_names = extract_test_names(tap_file)
        for name in test_names:
            print(name)
    except FileNotFoundError:
        print(f"Error: File not found: {tap_file}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
