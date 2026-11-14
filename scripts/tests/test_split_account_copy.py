#!/usr/bin/env python3
"""The multi-account refusal copy still hashes to the bytes the outbound copy gate approved.

The gate approves a message by hash (`body_sha256` + `subject_sha256` in the signed statement), so the copy
constant in `scripts/intercom-verify-request.sh` is only approved while it hashes to the value the reviewer
signed. Editing one character of the text silently voids the approval; without this test that would only surface
at send time, on node-8, as a held message. The hash constants are the byte contract with the gate; nothing else
about the sender is checked here.

Verdict of record (2026-11-14T10:31:53Z, reviewer mac-pool/claude-fable-5-1, rubric default
2c505d21f105afe8922204c32c27d1cfc345d09e99ee605b8d3dfa2d022a7cfa): ocv-49139bdc4dfc3e75, verdict `approve`.
"""
from __future__ import annotations

import hashlib
import re
import unittest
from pathlib import Path

SENDER = Path(__file__).resolve().parents[1] / "intercom-verify-request.sh"


def _constant(name: str) -> str:
    """The value of `readonly NAME='...'` (single-quoted, may span lines) or `readonly NAME="..."`."""
    text = SENDER.read_text(encoding="utf-8")
    m = re.search(rf"^readonly {name}='(.*?)'\s*$", text, re.M | re.S)
    if m:
        return m.group(1)
    m = re.search(rf'^readonly {name}="([^"]*)"\s*$', text, re.M)
    if m:
        return m.group(1)
    m = re.search(rf"^readonly {name}=(\S+)\s*$", text, re.M)
    if not m:
        raise AssertionError(f"{name} is not declared in {SENDER.name}")
    return m.group(1)


class SplitAccountCopyTests(unittest.TestCase):
    def test_the_body_still_hashes_to_the_approved_verdict(self):
        body = _constant("SPLIT_ACCOUNT_COPY_BODY")
        self.assertEqual(hashlib.sha256(body.encode("utf-8")).hexdigest(),
                         _constant("SPLIT_ACCOUNT_COPY_SHA256"),
                         "the copy text changed: the outbound copy gate's approval (ocv-49139bdc4dfc3e75) is void, "
                         "so this text must be re-reviewed before it can send")

    def test_the_subject_still_hashes_to_the_approved_verdict(self):
        subject = _constant("SPLIT_ACCOUNT_COPY_SUBJECT")
        self.assertEqual(hashlib.sha256(subject.encode("utf-8")).hexdigest(),
                         _constant("SPLIT_ACCOUNT_COPY_SUBJECT_SHA256"),
                         "the subject changed: the approved verdict is void")


if __name__ == "__main__":
    unittest.main(verbosity=2)
