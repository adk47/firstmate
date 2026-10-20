"""The proof-on-file completeness contract, Python side.

The same fixture file (scripts/tests/fixtures/proof-parts-contract.json) is run against
Caroline's support tool (plugins/support-tools/tests/proof-on-file.test.ts), so both readers
answer every case the same way (captain via firstmate 034/035: one contract, strict). Both
Python readers answer it too: verify_notify.load_proof_on_file (the verify notes),
credit_retro.takeback's proof-on-file read (the take-back gate) and decide.proof_on_file
(the credit decider), each through proof_parts. The decider additionally requires the
gmail_contacts_90d list (it holds those users, firstmate 041), so the decider check adds
one where a case has none; with it, the decider answers every case exactly the same."""

from __future__ import annotations

import credit_test_env  # noqa: F401,E402 - first: test logs never reach the production run.log
import json
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from credit_retro import takeback  # noqa: E402
from credit_review import decide, verify_notify  # noqa: E402

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
                    # The senders (verify notes, decider) also need the support@ contact
                    # list; add one where a case has none (completeness never depends on it).
                    doc = contract_doc(case)
                    doc.setdefault("gmail_contacts_90d", {"generated_at": iso(0.5), "source": "t", "user_ids": []})
                    path.write_text(json.dumps(doc), encoding="utf-8")
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
                    proof, why = decide.proof_on_file(path, now=NOW)
                    self.assertEqual("ok" if proof is not None else "unknown", case["expect"], f"decider: {why}")

    def test_the_senders_without_a_contact_list_are_unknown(self):
        """Stricter, never looser: no support@ contact list means nobody is asked or noted."""
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "proof-on-file.json"
            doc = contract_doc(CONTRACT["cases"][0])
            doc.pop("gmail_contacts_90d")
            path.write_text(json.dumps(doc), encoding="utf-8")
            proof, why = decide.proof_on_file(path, now=NOW)
            self.assertIsNone(proof)
            self.assertIn("gmail_contacts_90d", why)
            with self.assertRaises(verify_notify.ProofFileError) as raised:
                verify_notify.load_proof_on_file(str(path), max_age_h=3, now=NOW)
            self.assertIn("gmail_contacts_90d", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
