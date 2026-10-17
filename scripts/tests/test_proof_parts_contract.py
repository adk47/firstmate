"""The proof-on-file completeness contract, Python side.

The same fixture file (scripts/tests/fixtures/proof-parts-contract.json) is run against
Caroline's support tool (plugins/support-tools/tests/proof-on-file.test.ts), so both readers
answer every case the same way (captain via firstmate 034/035: one contract, strict). Both
Python readers answer it too: verify_notify.load_proof_on_file (the verify notes) and
credit_retro.takeback's proof-on-file read (the take-back gate), each through proof_parts."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from credit_retro import takeback  # noqa: E402
from credit_review import verify_notify  # noqa: E402

CONTRACT = json.loads((ROOT / "scripts" / "tests" / "fixtures" / "proof-parts-contract.json").read_text())
NOW = datetime(2026, 10, 17, 18, 0, tzinfo=timezone.utc)


def iso(age_h: float) -> str:
    return (NOW - timedelta(hours=age_h)).isoformat().replace("+00:00", "Z")


def contract_doc(case: dict) -> dict:
    sources = []
    for src in case["sources"]:
        src = dict(src)
        age = src.pop("age_h", None)
        if age is not None and "generated_at" not in src:
            src["generated_at"] = iso(age)
        sources.append(src)
    doc = {"generated_at": iso(0.1), "sources": sources, "entries": case.get("entries", [])}
    users = case.get("users", 0)
    if users is not None:
        doc["users"] = users
    if "gmail_contacts_90d" in case:
        lst = dict(case["gmail_contacts_90d"])
        lst["generated_at"] = iso(lst.pop("generated_at_age_h"))
        doc["gmail_contacts_90d"] = lst
    return doc


class ContractTests(unittest.TestCase):
    def test_every_case(self):
        self.assertGreater(len(CONTRACT["cases"]), 10)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "proof-on-file.json"
            for case in CONTRACT["cases"]:
                with self.subTest(case["name"]):
                    path.write_text(json.dumps(contract_doc(case)), encoding="utf-8")
                    try:
                        verify_notify.load_proof_on_file(str(path), max_age_h=3, now=NOW)
                        got = "ok"
                    except verify_notify.ProofFileError:
                        got = "unknown"
                    self.assertEqual(got, case["expect"])
                    try:
                        takeback._read_proof_on_file(str(path), NOW)
                        removal_gate = "ok"
                    except ValueError:
                        removal_gate = "unknown"
                    self.assertEqual(removal_gate, case["expect"], "take-back gate")


if __name__ == "__main__":
    unittest.main()
