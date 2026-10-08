#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("verifier", Path(__file__).with_name("verify-results.py"))
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


def evidence(patched):
    lines = [f"BTRFS_IPE_KERNEL 6.6.157.1-b473-{'patched' if patched else 'stock'}",
             "BTRFS_IPE_CORRUPT_SIGNATURE_REJECTED"]
    for pid, name in enumerate(sorted(verifier.PROBES), 100):
        trusted = name in verifier.TRUSTED
        allow = patched and trusted
        rule = "op=EXECUTE dmverity_signature=TRUE action=ALLOW" if allow else "DEFAULT action=DENY"
        for hook in ("BPRM_CHECK", "MMAP"):
            lines.append(f'ipe_op=EXECUTE ipe_hook={hook} enforcing={int(name.startswith("enforcing-"))} pid={pid} rule="{rule}"')
        rc = 126 if name.startswith("enforcing-") and not allow else 0
        lines.append(f"BTRFS_IPE_PROBE name={name} pid={pid} rc={rc} expected={'allow' if trusted else 'deny'}")
    lines += ["BTRFS_IPE_AUDIT_STATUS_BEGIN", "lost 0", "BTRFS_IPE_AUDIT_STATUS_END",
              "BTRFS_IPE_COMPLETE"]
    return "\n".join(lines)


class EvidenceTests(unittest.TestCase):
    def test_stock_and_patched(self):
        for patched in (False, True):
            self.assertEqual(len(verifier.verify(evidence(patched), patched)["probes"]), 10)

    def test_rejects_incomplete_or_misleading_evidence(self):
        text = evidence(True)
        for altered in (
            text.replace("BTRFS_IPE_COMPLETE", ""),
            text.replace("lost 0", "lost 1"),
            text.replace("dmverity_signature=TRUE", "boot_verified=TRUE"),
            text.replace("ipe_hook=MMAP", "ipe_hook=OTHER"),
            text.replace("ipe_op=EXECUTE", "ipe_op=OTHER"),
            text.replace("BTRFS_IPE_CORRUPT_SIGNATURE_REJECTED", ""),
            text.replace("-b473-patched", "-unknown"),
            text + "\nBTRFS_IPE_FAILURE failed",
            text.replace("expected=deny", "expected=allow"),
            text.replace("enforcing=1", "enforcing=0"),
            text.replace("ipe_hook=BPRM_CHECK", "ipe_hook=OTHER"),
            text + "\naudit_printk_skb: 42 callbacks suppressed",
            text + '\nipe_op=EXECUTE pid=999 path="/usr/bin/unexpected" rule="DEFAULT action=DENY"',
        ):
            with self.subTest(altered=altered[-80:]), self.assertRaises(ValueError):
                verifier.verify(altered, True)

    def test_rejects_one_denial_on_trusted_probe(self):
        text = evidence(True)
        pid = 100 + sorted(verifier.PROBES).index("signed-true")
        with self.assertRaises(ValueError):
            verifier.verify(text + f'\nipe_op=EXECUTE pid={pid} rule="DEFAULT action=DENY"', True)


if __name__ == "__main__":
    unittest.main()
