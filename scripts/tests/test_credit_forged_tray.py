"""jan-forged -> executor tray converter (doc-verify 074 / r5 on #1470)."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from credit_review import forged_tray as ft  # noqa: E402

R1 = "11111111-1111-4111-8111-111111111111"
R2 = "22222222-2222-4222-8222-222222222222"


def row(rid="forged-abcd1234", executable=True, subject="credit", reqs=(R1,)):
    return {"ruling_id": rid, "proof_id": rid[7:] + "ffff", "intake_id": "i1", "user_id": 42, "subject": subject,
            "fraud_signals": [{"family": "F2", "id": "s1"}, {"family": "F5", "id": "s2"}],
            "fraud_pair": [{"id": "s1"}, {"id": "s2"}], "signal_ids": ["s1", "s2"],
            "requests": [{"request_id": r, "role": "Producer", "outcome_id": 7} for r in reqs],
            "executable": executable}


OPEN = lambda ids: {i.lower(): {"status": "unverified", "user_id": 42} for i in ids}  # noqa: E731


class ForgedTrayTest(unittest.TestCase):
    def test_zero_rulings_with_rows_refuses_the_batch(self):
        for text in ("", "nothing here", "```\nruling: forged-abcd1234 confirm\n```",
                     "- ruling: forged-abcd1234 confirm", "> ruling: forged-abcd1234 confirm",
                     "ruling: forged-abcd1234 confirm because"):
            with self.assertRaisesRegex(ft.BatchRefused, "ZERO rulings"):
                ft.build({"rows": [row()]}, text, OPEN)

    def test_no_rulings_file_with_rows_refuses(self):
        with self.assertRaises(ft.BatchRefused):
            ft.build({"rows": [row()]}, None, OPEN)

    def test_only_executable_rows_are_acted_on(self):
        doc = {"rows": [row(), row("forged-00000000", executable=False, reqs=(R2,))]}
        trays, rep = ft.build(doc, "ruling: forged-abcd1234 confirm\nruling: forged-00000000 confirm\n", OPEN)
        self.assertEqual([r["request_id"] for r in trays["unverified"]["rows"]], [R1])
        self.assertEqual((rep["executable"], rep["not_executable"]), (1, 1))
        r = trays["unverified"]["rows"][0]
        self.assertEqual((r["rule"], r["reason_code"], r["ruling_id"]), ("R-FRAUD-DOC", "fraud_document", "forged-abcd1234"))
        self.assertEqual(r["signal_ids"], ["s1", "s2"])
        self.assertGreaterEqual(len(r["evidence"]), 20)

    def test_executable_row_not_confirmed_refuses_the_batch(self):
        for text in ("ruling: forged-abcd1234 not", "ruling: forged-99999999 confirm"):
            with self.assertRaisesRegex(ft.BatchRefused, "not confirmed"):
                ft.build({"rows": [row()]}, text, OPEN)

    def test_claims_wait_and_closed_requests_skip(self):
        doc = {"rows": [row(subject="claim"), row("forged-bbbbbbbb", reqs=(R2,))]}
        st = lambda ids: {i.lower(): {"status": "approved", "user_id": 42} for i in ids}  # noqa: E731
        trays, rep = ft.build(doc, "ruling: forged-abcd1234 confirm\nruling: forged-bbbbbbbb confirm", st)
        self.assertEqual(trays, {})
        self.assertEqual((rep["claim_waits"], rep["not_open"]), (1, 1))

    def test_output_loads_as_an_executor_tray_with_the_fraud_audit_fields(self):
        import json, tempfile
        from credit_review import fable_executor as fx
        trays, _ = ft.build({"rows": [row()]}, "ruling: forged-abcd1234 confirm", OPEN)
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump(trays["unverified"], fh)
        r = fx.load_tray(fh.name).rows[0]
        extra = dict(r.audit_extra)
        self.assertEqual((r.rule, r.ruling_id, extra["reason_code"]), ("R-FRAUD-DOC", "forged-abcd1234", "fraud_document"))
        self.assertEqual(extra["signal_ids"], ["s1", "s2"])

    def test_parser_parity_with_upstream_grammar(self):
        # docverify.tray._RULING @979a9a15: full line, case-insensitive, flexible spaces/tabs (QA #1480)
        text = ("RULING:\tforged-ABCD1234 CONFIRM\nruling:forged-00000000   Not  \n"
                "Ruling: forged-11111111 confirm\n```\nruling: forged-22222222 confirm\n```\n"
                "- ruling: forged-33333333 confirm\nruling: forged-44444444 confirmed\n")
        self.assertEqual(ft.parse_rulings(text), {"forged-abcd1234": "confirm", "forged-00000000": "not",
                                                  "forged-11111111": "confirm"})
        trays, _ = ft.build({"rows": [row()]}, "RULING:\tforged-abcd1234 CONFIRM", OPEN)
        self.assertEqual(len(trays["unverified"]["rows"]), 1)

    def test_one_request_in_two_confirmed_documents_is_one_loadable_row(self):
        import json, tempfile
        from credit_review import fable_executor as fx
        doc = {"rows": [row("forged-bbbbbbbb", reqs=(R1, R2)), row("forged-aaaaaaaa", reqs=(R1,))]}
        trays, rep = ft.build(doc, "ruling: forged-aaaaaaaa confirm\nruling: forged-bbbbbbbb confirm", OPEN)
        rows = trays["unverified"]["rows"]
        self.assertEqual(sorted(r["request_id"] for r in rows), [R1, R2])
        r1 = next(r for r in rows if r["request_id"] == R1)
        self.assertEqual(r1["ruling_id"], "forged-aaaaaaaa")
        self.assertIn("1 more confirmed forged document(s)", r1["evidence"])
        self.assertEqual([c["ruling_id"] for c in r1["contributors"]], ["forged-aaaaaaaa", "forged-bbbbbbbb"])
        self.assertEqual(len(r1["outcome_ids"]), 2)
        self.assertEqual(rep["aggregated"], 1)
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump(trays["unverified"], fh)
        self.assertEqual(len(fx.load_tray(fh.name).rows), 2)          # the executor accepts it

    def test_twelve_documents_on_one_request_keep_every_contributor_in_the_audit(self):
        import json, tempfile
        from credit_review import fable_executor as fx
        ids = [f"forged-{i:08x}" for i in range(12)]
        doc = {"rows": [row(r) for r in ids]}
        trays, _ = ft.build(doc, "\n".join(f"ruling: {r} confirm" for r in ids), OPEN)
        [r] = trays["unverified"]["rows"]
        self.assertEqual([c["ruling_id"] for c in r["contributors"]], ids)
        self.assertTrue(all(c["proof_id"] and c["signal_ids"] for c in r["contributors"]))
        self.assertLessEqual(len(r["evidence"]), 600)
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump(trays["unverified"], fh)
        extra = dict(fx.load_tray(fh.name).rows[0].audit_extra)
        self.assertEqual(len(extra["contributors"]), 12)                 # reaches the executor audit verbatim

    def test_overlong_evidence_refuses_rather_than_truncates(self):
        big = row()
        big["signal_ids"] = ["s" * 700, "t"]
        with self.assertRaisesRegex(ft.BatchRefused, "refusing rather than truncating"):
            ft.build({"rows": [big]}, "ruling: forged-abcd1234 confirm", OPEN)

    def test_one_request_claimed_by_two_users_refuses_the_batch(self):
        other = row("forged-aaaaaaaa")
        other["user_id"] = 7
        with self.assertRaisesRegex(ft.BatchRefused, "different users"):
            ft.build({"rows": [row(), other]}, "ruling: forged-aaaaaaaa confirm\nruling: forged-abcd1234 confirm", OPEN)

    def test_empty_batch_is_not_a_refusal(self):
        trays, rep = ft.build({"rows": []}, "", OPEN)
        self.assertEqual((trays, rep["rows"]), ({}, 0))


if __name__ == "__main__":
    unittest.main()
