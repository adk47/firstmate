"""Tests for scripts/intercom-backlog/intake_proposals.py: identity-link PROPOSALS for unmatched
proof documents, by verified email only. Pure functions only (no Trino, no Intercom, no ledger).
Stdlib unittest; safe to run as root on node-8."""
import datetime as dt
import importlib.util
import json
import os
import sys
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
spec = importlib.util.spec_from_file_location(
    "ib_intake", os.path.join(ROOT, "scripts", "intercom-backlog", "intake_proposals.py"))
ip = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ip)
Account = ip.rec.Account

NOW = time.time()
OLD = NOW - 10 * 86400
TRAY = {"why": "unresolved: the external_id is not a Muso account", "files": "['a', 'b']"}


def contact(email="x@y.io", role="user", ext="", created=OLD):
    return {"email": email, "role": role, "external_id": ext, "created_at": created}


def acct(uid=7, confirmed=True, others=(), admin=(), paid=False):
    return Account(user_id=uid, email="x@y.io", email_confirmed=confirmed,
                   created_at=dt.datetime(2024, 1, 1, tzinfo=dt.timezone.utc),
                   other_holders=list(others), admin_history=list(admin), paid=paid)


def propose(contacts, *, by_email=None, facts=None, owners=None, reverted=None, presented=None):
    return ip.propose_one("c1", TRAY, contacts,
                          accounts_by_email={"x@y.io": [7]} if by_email is None else by_email,
                          facts={7: acct()} if facts is None else facts,
                          ext_owner=owners or {}, now=NOW, reverted=reverted, presented=presented)


class Propose(unittest.TestCase):
    def test_orphan_external_id_verified_email_is_a2(self):
        r = propose([contact(ext="orphan-1")])
        self.assertEqual((r["decision"], r["account_id"]), ("propose", 7))
        self.assertTrue(r["intercom_fix"].startswith("A2"))
        self.assertEqual(r["files"], 2)
        self.assertNotIn("x@y.io", json.dumps(r))  # emails never in output

    def test_empty_external_id_is_a1_and_lead_flagged(self):
        self.assertTrue(propose([contact()])["intercom_fix"].startswith("A1"))
        r = propose([contact(role="lead")])
        self.assertTrue(r["intercom_fix"].startswith("LEAD"))
        self.assertEqual(r["flags"], ["lead-email"])

    def test_presented_profile_is_r5(self):
        r = propose([contact(ext="prof-1")], owners={"prof-1": {"7"}}, presented={"prof-1": {"7"}})
        self.assertTrue(r["intercom_fix"].startswith("R5"))

    def test_refusals(self):
        cases = [
            (dict(contacts=None), "unreadable"),
            (dict(contacts=[]), "no contacts"),
            (dict(contacts=[contact(email="")]), "no contact on the thread has an email"),
            (dict(contacts=[contact(), contact(email="z@y.io")]), "different emails"),
            (dict(contacts=[contact()], by_email={}), "no Muso account"),
            (dict(contacts=[contact()], by_email={"x@y.io": [7, 8]}), "2 Muso accounts"),
            (dict(contacts=[contact()], facts={7: acct(confirmed=False)}), "not confirmed"),
            (dict(contacts=[contact()], facts={7: acct(others=["9"])}), "another account holds"),
            (dict(contacts=[contact()], facts={7: acct(admin=["PUT /admin/user/:id"])}), "admin gave"),
            (dict(contacts=[contact(ext="e1")], owners={"e1": {"9"}}), "names another Muso account"),
            (dict(contacts=[contact(ext="e1")], reverted={"e1": {"9"}}), "reverted claim"),
        ]
        for kw, why in cases:
            with self.subTest(why=why):
                c = kw.pop("contacts")
                r = propose(c, **kw)
                self.assertEqual(r["decision"], "no-proposal")
                self.assertIn(why, r["reason"])

    def test_young_contact_waits(self):
        self.assertEqual(propose([contact(created=NOW - 3600)])["decision"], "wait")

    def test_never_by_name(self):
        # a contact with a matching NAME but no email is never proposed
        c = contact(email="")
        c["name"] = "Same Name"
        self.assertEqual(propose([c])["decision"], "no-proposal")


class TrayAndLine(unittest.TestCase):
    def test_tray_dedupes_to_newest_row(self):
        d = tempfile.mkdtemp()
        p = os.path.join(d, "t.jsonl")
        with open(p, "w") as f:
            f.write(json.dumps({"conversation_id": "1", "at": "2026-10-28T00:00:00Z", "why": "old"}) + "\n")
            f.write(json.dumps({"conversation_id": "1", "at": "2026-10-29T00:00:00Z", "why": "new"}) + "\n\n")
            f.write(json.dumps({"conversation_id": "2", "at": "2026-10-29T00:00:00Z", "why": "x"}) + "\n")
        rows = ip.tray_rows(p)
        self.assertEqual(sorted(rows), ["1", "2"])
        self.assertEqual(rows["1"]["why"], "new")

    def test_daily_line_counts_new_only_once(self):
        res = [{"conversation_id": "1", "decision": "propose"}, {"conversation_id": "2", "decision": "wait"}]
        line, st = ip.daily_line(res, {}, "2026-10-29")
        self.assertIn("new 2 / linked 0 / still unresolved 2", line)
        line2, _ = ip.daily_line(res, st, "2026-10-30")
        self.assertIn("new 0 / linked 0 / still unresolved 2", line2)
        line3, _ = ip.daily_line(res, dict(st, linked=["1"]), "2026-10-30")
        self.assertIn("linked 1 / still unresolved 1", line3)


class Cron(unittest.TestCase):
    def test_daily_cron_is_registered_read_only(self):
        with open(os.path.join(ROOT, "cron-jobs.json")) as f:
            jobs = json.load(f)["jobs"]
        j = [x for x in jobs if x["name"] == "intake-unresolved-proposals-daily"]
        self.assertEqual(len(j), 1)
        argv = j[0]["payload"]["argv"]
        self.assertEqual(argv[1], "/opt/hydra/scripts/intercom-backlog/intake_proposals.py")
        self.assertIn("--quiet", argv)
        self.assertEqual(j[0]["delivery"]["mode"], "none")


if __name__ == "__main__":
    unittest.main()
