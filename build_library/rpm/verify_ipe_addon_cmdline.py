#!/usr/bin/env python3
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

"""Reject addon arguments that override the verified IPE or signed /usr binding."""

import argparse
import re
import shlex
import sys


def validate(cmdline: str, required: bool, reserved_slot: bool) -> None:
    # The initrd policy loader splits raw whitespace, even inside quoted values.
    if any(word.startswith("acl.ipe.policy_sha256=") for word in re.split(r"[ \t\n]+", cmdline)):
        raise ValueError("IPE UKI addon must not set acl.ipe.policy_sha256")

    if "\r" in cmdline:
        raise ValueError("Unsupported carriage return in IPE command line")
    # systemd-stub turns C0 controls and DEL into spaces before parsing.
    if any((ord(c) < 32 and c not in "\t\n") or ord(c) == 127 for c in cmdline):
        raise ValueError("Unsupported control character in IPE command line")

    # systemd v255 UNQUOTE|RETAIN_ESCAPE: quotes group words; escapes and
    # comments are disabled. No shell expansion or evaluation takes place.
    lexer = shlex.shlex(cmdline, posix=True)
    lexer.whitespace_split = True
    lexer.whitespace = " \t\n\r"
    lexer.commenters = ""
    lexer.escape = ""
    try:
        words = list(lexer)
    except ValueError as error:
        # Unlike systemd RELAX, do not let open quotes consume the next addon.
        raise ValueError("Unbalanced quoting in IPE command line") from error

    for word in words:
        if word.startswith("acl.ipe.policy_sha256="):
            raise ValueError("IPE UKI addon must not set acl.ipe.policy_sha256")
        if not required:
            continue
        if word.startswith(("rd.systemd.verity", "rd.usrhash=", "mount.usr",
                            "rd.mount.usr", "systemd.verity=")):
            raise ValueError("Addon overrides required /usr verification")
        if not reserved_slot:
            key = word.partition("=")[0].removeprefix("rd.").replace("-", "_")
            if (key in ("usrhash", "root_hash_signature")
                    or key.startswith(("systemd.verity", "mount.usr"))
                    or "root-hash-signature=" in word):
                raise ValueError("Unexpected slot addon or signed /usr metadata")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("disabled", "required"))
    parser.add_argument("reserved_slot", choices=("false", "true"))
    parser.add_argument("source", help="addon path for diagnostics")
    args = parser.parse_args()
    try:
        # Preserve CR bytes so newline translation cannot hide invalid input.
        validate(sys.stdin.buffer.read().decode("utf-8"),
                 args.mode == "required", args.reserved_slot == "true")
    except ValueError as error:
        print(f"{error}: {args.source}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
