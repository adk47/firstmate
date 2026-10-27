"""scripts/paid-status/classify2.classify: never "nothing else is needed" (Copy A / Copy B0) to a user who still
owes proof (captain 2026-10-27 12:55Z, item 5). On 10-27 the deployed copy's dry run listed 96 of 151 A/B users
with user_verification_needed rows: B because of any proof-on-file entry (often a whole-user approval for OTHER
credits) or an ask in 90 days, A because a document is on file. Stdlib only."""
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("classify2", os.path.join(HERE, "..", "paid-status", "classify2.py"))
c2 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c2)
CUT = "2026-07-29T00:00:00+00:00"


def row(status, asked=""):
    return {"id": "r", "status": status, "asked": asked}


class ClassifyTest(unittest.TestCase):
    def k(self, rs, documented=False, pending_doc=False):
        return c2.classify(rs, documented=documented, pending_doc=pending_doc, cutoff=CUT)

    def test_a_user_with_a_uvn_row_never_gets_a_or_b(self):
        for documented, pending, asked in ((True, False, ""), (False, True, ""), (False, False, "2026-10-20"),
                                           (True, True, "2026-10-20")):
            got = self.k([row("unverified"), row("user_verification_needed", asked)], documented, pending)
            self.assertEqual(got, "HOLD_OWES", (documented, pending, asked))

    def test_an_undocumented_never_asked_uvn_user_is_the_ask(self):
        self.assertEqual(self.k([row("user_verification_needed")]), "UVN_ASK")
        self.assertEqual(self.k([row("user_verification_needed", "2026-01-01")]), "UVN_ASK")  # asked > 90 days ago

    def test_users_owing_nothing_get_the_status_notes(self):
        self.assertEqual(self.k([row("unverified"), row("processing")]), "B_TEAM")
        self.assertEqual(self.k([row("unverified")], documented=True), "B_TEAM")
        self.assertEqual(self.k([row("pending")], pending_doc=True), "A_DOC")


class MainEndToEndTest(unittest.TestCase):
    """classify2.main over a fake replica (10-27 13:00Z: the HOLD_OWES change shipped with a NameError on the
    UVN_ASK path that only main() reached; daily.sh failed closed and nothing was sent)."""

    def test_main_writes_every_class_and_holds_owe_proof_users(self):
        import json, sys, tempfile
        d = tempfile.mkdtemp()
        proof = os.path.join(d, "pof.json"); paying = os.path.join(d, "paying.json")
        json.dump({"entries": [{"user_id": 3, "kind": "human_approved_after_doc", "request_id": None},
                               {"user_id": 4, "kind": "pending_doc", "request_id": None}]}, open(proof, "w"))
        json.dump({"ids": [1, 2, 3, 4]}, open(paying, "w"))
        open(os.path.join(d, "support-held-17.txt"), "w").write("")
        users = os.path.join(d, "users.txt"); open(users, "w").write("user_id: 1\nuser_id: 2\nuser_id: 3\nuser_id: 4\n")
        rows = {1: "user_verification_needed", 2: "unverified", 3: "user_verification_needed", 4: "unverified"}

        def fake(sql):
            if "credit_requests" in sql:
                return [[f"r{u}", str(u), st, f"T{u}", "2026-10-01", "", "Art", "{Mixing}"] for u, st in rows.items()]
            return [[str(u), "N", "true"] for u in rows]
        saved = (c2.trino, c2.PROOF, c2.PAYING, sys.argv, os.environ.get("PWR_DIR"))
        c2.trino, c2.PROOF, c2.PAYING = fake, proof, paying
        sys.argv = ["classify2.py", "--users", users, "--out-dir", d]
        os.environ["PWR_DIR"] = d
        try:
            self.assertEqual(c2.main(), 0)
        finally:
            c2.trino, c2.PROOF, c2.PAYING, sys.argv = saved[:4]
            if saved[4] is None:
                os.environ.pop("PWR_DIR", None)
            else:
                os.environ["PWR_DIR"] = saved[4]
        out = json.load(open([os.path.join(d, f) for f in os.listdir(d) if f.startswith("dry-run-")][0]))
        self.assertEqual({o["user_id"]: o["class"] for o in out}, {1: "UVN_ASK", 2: "B_TEAM", 4: "A_DOC"})  # 3 held


if __name__ == "__main__":
    unittest.main()
