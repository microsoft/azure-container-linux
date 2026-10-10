#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Check PID-correlated IPE evidence, not merely successful command exits."""
import json
from pathlib import Path
import re
import sys

PROBES = {
    "signed-true", "signed-ls", "signed-bash", "overlay-true", "overlay-copy",
    "unsigned-true", "plain-true", "writable-true", "enforcing-signed",
    "enforcing-writable",
}
TRUSTED = {"signed-true", "signed-ls", "signed-bash", "overlay-true", "enforcing-signed"}


def verify(text, patched):
    if "BTRFS_IPE_COMPLETE" not in text or "BTRFS_IPE_FAILURE" in text:
        raise ValueError("Guest did not complete successfully")
    if re.search(r"callbacks suppressed|audit.*(?:backlog limit exceeded|rate limit exceeded)", text):
        raise ValueError("Audit output was suppressed")
    if "BTRFS_IPE_CORRUPT_SIGNATURE_REJECTED" not in text:
        raise ValueError("Missing corrupt-signature rejection")
    status = re.search(r"BTRFS_IPE_AUDIT_STATUS_BEGIN(.*?)BTRFS_IPE_AUDIT_STATUS_END", text, re.S)
    if not status or not re.search(r"(?m)^lost 0\r?$", status[1]):
        raise ValueError("Missing zero-loss audit status")
    kernel = re.search(r"BTRFS_IPE_KERNEL ([^\r\n]+)", text)
    expected_suffix = "-b473-patched" if patched else "-b473-stock"
    if not kernel or not kernel[1].endswith(expected_suffix):
        raise ValueError("Unexpected running kernel")
    usr_denials = [line for line in text.splitlines()
                   if "ipe_op=EXECUTE " in line and 'path="/usr/' in line
                   and "action=DENY" in line]
    if patched and usr_denials:
        raise ValueError("Unexpected /usr denial outside or inside the trusted probes")
    matches = re.findall(
        r"BTRFS_IPE_PROBE name=([\w-]+) pid=(\d+) rc=(\d+) expected=(allow|deny)", text
    )
    if len(matches) != len(PROBES) or {p[0] for p in matches} != PROBES:
        raise ValueError("Missing or duplicate probes")
    if len({p[1] for p in matches}) != len(PROBES) or any(int(p[1]) <= 0 for p in matches):
        raise ValueError("Missing or duplicate probe PIDs")
    result = {}
    for name, pid, rc, expected in matches:
        trusted = name in TRUSTED
        if expected != ("allow" if trusted else "deny"):
            raise ValueError(f"{name}: incorrect expectation")
        records = [line for line in text.splitlines()
                   if "ipe_op=EXECUTE " in line and re.search(rf"\bpid={pid}\b", line)]
        if not records:
            raise ValueError(f"{name}: no correlated IPE records")
        enforcing = name.startswith("enforcing-")
        if any(not re.search(rf"\benforcing={int(enforcing)}\b", r) for r in records):
            raise ValueError(f"{name}: incorrect or missing IPE enforcement state")
        denials = [r for r in records if "action=DENY" in r]
        signature_allows = [r for r in records
                            if "dmverity_signature=TRUE" in r and "action=ALLOW" in r]
        should_allow = patched and trusted
        if should_allow:
            if denials or not signature_allows or int(rc):
                raise ValueError(f"{name}: missing positive signature allow, denial or execution failure")
            if not any("ipe_hook=BPRM_CHECK" in r for r in signature_allows):
                raise ValueError(f"{name}: missing BPRM signature evidence")
            if not any("ipe_hook=MMAP" in r for r in signature_allows):
                raise ValueError(f"{name}: missing executable MMAP signature evidence")
        elif not any("ipe_hook=BPRM_CHECK" in r for r in denials):
            raise ValueError(f"{name}: expected an executable-load denial")
        if enforcing and ((int(rc) == 0) != should_allow):
            raise ValueError(f"{name}: incorrect enforced result")
        if not enforcing and int(rc):
            raise ValueError(f"{name}: audit-mode execution failed")
        result[name] = {"pid": int(pid), "exit_code": int(rc),
                        "denials": len(denials), "signature_allows": len(signature_allows)}
    return {"kernel": kernel[1], "audit_lost": 0, "usr_denials": len(usr_denials), "probes": result}


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: verify-results.py STOCK_SERIAL PATCHED_SERIAL")
    print(json.dumps({
        "scope": "AMD64 nested-VM filesystem fixture; not a complete ACL image or SELinux qualification",
        "stock": verify(Path(sys.argv[1]).read_text(), False),
        "patched": verify(Path(sys.argv[2]).read_text(), True),
    }, indent=2))
