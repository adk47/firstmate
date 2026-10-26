"""Intercom external_id reconcile (credit_review/intercom_reconcile.py; Fable
ruling-intercom-external-id-1026 Ruling A). Classifier A1-A5 incl. the recycled-email and 2+-contact
cases, write conditions (dropping "no other account ever held this email" must go red), dry run
writes nothing, ledger row before each write, first-run cap 50, refusal hold lifted only for fixed
rows, --revert. Intercom and Trino are faked: no network."""
from __future__ import annotations

import hashlib
import json
import re
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from credit_review import fraud_lens, intercom_reconcile as R, verify_ledger  # noqa: E402

NOW = datetime(2026, 10, 26, 3, 0, tzinfo=timezone.utc)
OLD = NOW - timedelta(days=400)
MISMATCH = "the Intercom user for this email belongs to a different Muso account (external_id mismatch); not sending."
NO_EXT = "the Intercom user for this email has no external_id, so it cannot be matched to this Muso account; not sending."
SEVERAL = "the account email matches 2 Intercom users (need exactly 1, or exactly one whose external_id is this account); not sending."
FORBIDDEN = "intercom error: action_forbidden"


def pro(u):
    return f"9e1c2a9e-0b7d-4c3e-9a51-{int(u):012d}"


def orphan(n):
    return f"0dead000-0000-4000-8000-{int(n):012d}"


def acct(u=1, **kw):
    a = R.Account(user_id=u, email=kw.pop("email", f"u{u}@x.com"), email_confirmed=kw.pop("confirmed", True),
                  created_at=kw.pop("created", OLD), professional_id=kw.pop("pro", pro(u)), auth_id=kw.pop("auth", ""),
                  paid=kw.pop("paid", True), sources=kw.pop("sources", ["status-team-review:mismatch"]))
    for k, v in kw.items():
        setattr(a, k, v)
    return a


def contact(cid, email, ext="", role="user"):
    return {"type": "contact", "id": cid, "email": email, "external_id": ext or None, "role": role}


CLEAN = fraud_lens.Verdict()


class ClassifierTests(unittest.TestCase):
    def go(self, a, contacts, owners=None, pro_contacts=None, verdict=CLEAN):
        owners = owners if owners is not None else {R.ext_of(c): set() for c in contacts if R.ext_of(c)}
        return R.classify(a, contacts, owners, now=NOW, pro_contacts=pro_contacts or [], verdict=verdict)

    def test_a1_empty_external_id_is_fixed(self):
        r = self.go(acct(), [contact("c1", "u1@x.com")])
        self.assertEqual((r.cls, r.decision, r.contact_id, r.old_external_id, r.new_external_id),
                         ("A1", R.FIX, "c1", "", pro(1)))

    def test_a2_orphan_is_fixed(self):
        r = self.go(acct(), [contact("c1", "u1@x.com", orphan(1))])
        self.assertEqual((r.cls, r.decision, r.old_external_id), ("A2", R.FIX, orphan(1)))

    def test_a3_another_accounts_id_is_refused_for_cs_with_both_ids(self):
        r = self.go(acct(), [contact("c1", "u1@x.com", pro(2))], owners={pro(2): {"2"}})
        self.assertEqual((r.cls, r.decision, r.other_account_ids), ("A3", R.REFUSE_CS, ["2"]))

    def test_a3_bare_numeric_id_of_another_account(self):
        r = self.go(acct(), [contact("c1", "u1@x.com", "77")], owners={"77": {"77"}})
        self.assertEqual((r.cls, r.decision), ("A3", R.REFUSE_CS))

    def test_own_numeric_id_is_not_rewritten(self):
        r = self.go(acct(), [contact("c1", "u1@x.com", "1")], owners={"1": {"1"}})
        self.assertEqual(r.decision, R.REFUSE_CS)

    def test_unchecked_external_id_is_never_treated_as_orphan(self):
        r = self.go(acct(), [contact("c1", "u1@x.com", orphan(1))], owners={})
        self.assertEqual(r.decision, R.REFUSE_CS)

    # -- write conditions (A2 -> A3 on any failure) --------------------------------------------------

    def test_recycled_email_another_account_holds_it_now(self):
        """Mutation guard: dropping the "no other live account ever held this email" check goes red."""
        r = self.go(acct(other_holders=["9"]), [contact("c1", "u1@x.com", orphan(1))])
        self.assertEqual((r.cls, r.decision), ("A3", R.REFUSE_CS))
        self.assertIn("another Muso account holds this email", r.why)

    def test_recycled_email_admin_gave_it_to_another_account(self):
        r = self.go(acct(admin_history=["PUT /api/v3/admin/user/:id (account 9)"]), [contact("c1", "u1@x.com", orphan(1))])
        self.assertEqual((r.cls, r.decision), ("A3", R.REFUSE_CS))
        self.assertIn("an admin gave this email to another account", r.why)

    def test_recycled_email_another_accounts_lead_carries_it(self):
        r = self.go(acct(), [contact("c1", "u1@x.com", orphan(1)), contact("l1", "u1@x.com", pro(9), role="lead")],
                    owners={orphan(1): set(), pro(9): {"9"}})
        self.assertEqual((r.cls, r.decision, r.other_account_ids), ("A3", R.REFUSE_CS, ["9"]))

    def test_each_condition_blocks_the_write(self):
        for kw, why in (({"confirmed": False}, "not confirmed"), ({"created": NOW - timedelta(days=29)}, "younger"),
                        ({"created": None}, "younger"), ({"paid": False}, "not paid")):
            r = self.go(acct(**kw), [contact("c1", "u1@x.com", orphan(1))])
            self.assertEqual((r.cls, r.decision), ("A3", R.REFUSE_CS), kw)
            self.assertIn(why, r.why, kw)

    def test_a1_is_held_to_the_same_conditions(self):
        r = self.go(acct(other_holders=["9"]), [contact("c1", "u1@x.com")])
        self.assertEqual((r.cls, r.decision), ("A1", R.REFUSE_CS))

    def test_thirty_day_old_account_passes(self):
        r = self.go(acct(created=NOW - timedelta(days=30)), [contact("c1", "u1@x.com", orphan(1))])
        self.assertEqual(r.decision, R.FIX)

    def test_professional_id_already_on_another_contact_blocks(self):
        r = self.go(acct(), [contact("c1", "u1@x.com", orphan(1))],
                    pro_contacts=[contact("c9", "old@x.com", pro(1))])
        self.assertEqual(r.decision, R.REFUSE_CS)
        self.assertIn("already the external_id of another Intercom contact", r.why)

    def test_fraud_lens_hold_is_never_written(self):
        r = self.go(acct(), [contact("c1", "u1@x.com")], verdict=fraud_lens.Verdict(held=["watchlist fraud user"]))
        self.assertEqual(r.decision, R.FRAUD_HOLD)
        r = self.go(acct(), [contact("c1", "u1@x.com")], verdict=None)
        self.assertEqual(r.decision, R.FRAUD_HOLD)

    def test_ask_only_user_may_be_fixed(self):
        r = self.go(acct(), [contact("c1", "u1@x.com")], verdict=fraud_lens.Verdict(single_signal_rows=3))
        self.assertEqual(r.decision, R.FIX)

    # -- A4 -----------------------------------------------------------------------------------------

    def test_a4_two_fixable_contacts_is_refused(self):
        r = self.go(acct(sources=["status-team-review:several_contacts"]),
                    [contact("c1", "u1@x.com", orphan(1)), contact("c2", "u1@x.com")])
        self.assertEqual((r.cls, r.decision), ("A4", R.REFUSE_CS))
        self.assertIn("2 would become the match", r.why)

    def test_a4_one_fixable_and_one_other_accounts_contact_is_refused_by_the_owner_condition(self):
        r = self.go(acct(), [contact("c1", "u1@x.com", orphan(1)), contact("c2", "u1@x.com", pro(9))],
                    owners={orphan(1): set(), pro(9): {"9"}})
        self.assertEqual((r.cls, r.decision, r.other_account_ids), ("A4", R.REFUSE_CS, ["9"]))

    def test_a4_one_fixable_and_one_own_legacy_contact_fixes_exactly_one(self):
        r = self.go(acct(), [contact("c1", "u1@x.com", orphan(1)), contact("c2", "u1@x.com", "1")],
                    owners={orphan(1): set(), "1": {"1"}})
        self.assertEqual((r.cls, r.decision, r.contact_id), ("A4", R.FIX, "c1"))

    def test_one_contact_already_matching_is_ok(self):
        r = self.go(acct(), [contact("c1", "u1@x.com", orphan(1)), contact("c2", "u1@x.com", pro(1))])
        self.assertEqual((r.cls, r.decision), ("OK", R.ALREADY_OK))

    # -- A5 / none ---------------------------------------------------------------------------------

    def test_a5_action_forbidden_is_held_for_cs_never_written(self):
        r = self.go(acct(sources=["status-team-review:action_forbidden"]), [contact("c1", "u1@x.com")])
        self.assertEqual((r.cls, r.decision), ("A5", R.HOLD_CS))

    def test_no_intercom_user(self):
        r = self.go(acct(), [contact("l1", "u1@x.com", role="lead")])
        self.assertEqual((r.cls, r.decision), ("NONE", R.NO_CONTACT))

    def test_no_professional_id(self):
        r = self.go(acct(pro=""), [contact("c1", "u1@x.com")])
        self.assertEqual(r.decision, R.NO_PRO_ID)

    def test_auth_subject_counts_as_this_account(self):
        r = self.go(acct(auth="abc123"), [contact("c1", "u1@x.com", "auth0|abc123")])
        self.assertEqual(r.decision, R.ALREADY_OK)


class FakeIntercom:
    """Contacts by id. `put_status` forces a PUT answer; `keep_on_null` ignores external_id=null."""

    def __init__(self, contacts, put_status=200, keep_on_null=False, on_put=None):
        self.c = {c["id"]: dict(c) for c in contacts}
        self.put_status, self.keep_on_null, self.on_put = put_status, keep_on_null, on_put
        self.puts: list[tuple[str, dict]] = []

    def __call__(self, method, path, body):
        if method == "POST" and path == "/contacts/search":
            f, v = body["query"]["field"], body["query"]["value"]
            hits = [c for c in self.c.values() if (str(c.get(f) or "").lower() == v.lower() if f == "email"
                                                   else str(c.get(f) or "") == v)]
            return 200, {"type": "list", "data": [dict(c) for c in hits], "pages": {}}
        m = re.match(r"^/contacts/([A-Za-z0-9]+)$", path)
        if m and method == "GET":
            c = self.c.get(m.group(1))
            return (200, dict(c)) if c else (404, {"type": "error.list"})
        if m and method == "PUT":
            self.puts.append((m.group(1), dict(body)))
            if self.on_put:
                self.on_put(m.group(1), body)
            if self.put_status != 200:
                return self.put_status, {"type": "error.list", "errors": [{"code": "conflict", "message": "exists"}]}
            if body["external_id"] is None and self.keep_on_null:
                return 200, dict(self.c[m.group(1)])
            self.c[m.group(1)]["external_id"] = body["external_id"]
            return 200, dict(self.c[m.group(1)])
        raise AssertionError((method, path))


class World:
    """A fake core replica: users {id: dict}; requests {request id: user id}; admin email changes."""

    def __init__(self, users, requests=None, history=()):
        self.users, self.requests, self.history = users, requests or {}, list(history)

    def __call__(self, sql):
        def in_list(after):
            m = re.search(re.escape(after) + r" IN \(([^)]*)\)", sql)
            return [x.strip().strip("'") for x in m.group(1).split(",")] if m else []
        if "public.credit_requests WHERE CAST(id AS varchar) IN" in sql:
            return [[rid, str(self.requests[rid])] for rid in in_list("CAST(id AS varchar)") if rid in self.requests]
        if "public.subscriptions" in sql:
            ids = {int(x) for x in in_list("userid")}
            return [[str(u)] for u in sorted(ids) if self.users.get(u, {}).get("paid", True)]
        if "public.action_log" in sql:
            emails = set(in_list("lower(json_extract_scalar(requestdata, '$.body.email'))"))
            return [[route, method, email] for route, method, email in self.history if email in emails]
        if "emailconfirmed" in sql:
            ids = {int(x) for x in in_list("WHERE id")}
            return [[str(u), d["email"], str(d.get("confirmed", True)).lower(), d.get("created", "2024-01-01 00:00:00.000 UTC"),
                     d.get("pro", pro(u)), d.get("auth")] for u, d in sorted(self.users.items()) if u in ids]
        if "WHERE lower(email) IN" in sql:
            emails = set(in_list("lower(email)"))
            return [[str(u), d["email"]] for u, d in sorted(self.users.items()) if d["email"] in emails]
        if "neptuneprofessionalid IN" in sql:
            vals = set(in_list("neptuneprofessionalid"))
            return [[str(u), d.get("pro", pro(u)), d.get("auth")] for u, d in sorted(self.users.items())
                    if d.get("pro", pro(u)) in vals]
        raise AssertionError(sql)


def seed(ledger, holds=(), refused=(), forbidden=()):
    db = verify_ledger.connect(ledger)
    try:
        for uid, email, reason in holds:
            verify_ledger.recheck_refusal(db, campaign="status-team-review", user_key=email, reason=reason,
                                          user_id=str(uid), now=NOW - timedelta(days=1))
        for email, rids, reason in refused:
            verify_ledger.refuse(db, user_key=email, day="2026-10-25", request_ids=rids, message_type="email",
                                 approved_by="U7RP6HKUZ", approval_ref="ref", reason=reason, campaign="uvn-status",
                                 now=NOW - timedelta(days=1))
        for uid, email in forbidden:
            c = verify_ledger.claim(db, user_key=email, day="2026-10-25", request_ids=[f"f{uid}"], message_type="email",
                                    approved_by="U7RP6HKUZ", approval_ref="ref", campaign="status-team-review",
                                    now=NOW - timedelta(days=1), user_id=str(uid))
            verify_ledger.finalize(db, message_row=c["message_row"], status="rejected", reason=FORBIDDEN)
    finally:
        db.close()


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class RunTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="irc-"))
        self.ledger = str(self.dir / "ledger.sqlite3")
        self.users = {1: {"email": "u1@x.com"}, 2: {"email": "u2@x.com"}, 3: {"email": "u3@x.com"},
                      4: {"email": "u4@x.com"}, 5: {"email": "u5@x.com"}, 9: {"email": "u9@x.com"}}
        self.world = World(self.users, requests={"r4": 4})
        seed(self.ledger,
             holds=[(1, "u1@x.com", NO_EXT), (2, "u2@x.com", MISMATCH), (3, "u3@x.com", MISMATCH)],
             refused=[("u4@x.com", ["r4"], MISMATCH)], forbidden=[(5, "u5@x.com")])
        self.api = FakeIntercom([contact("c1", "u1@x.com"), contact("c2", "u2@x.com", orphan(2)),
                                 contact("c3", "u3@x.com", pro(9)), contact("c4", "u4@x.com", orphan(4)),
                                 contact("c5", "u5@x.com", pro(5))])

    def run_(self, **kw):
        kw.setdefault("lens", fraud_lens.null_lens)
        return R.run(ledger_path=self.ledger, query=self.world, api=self.api, now=NOW, **kw)

    def dry(self):
        res = self.run_()
        files = R.write_outputs(res, str(self.dir / "out"))
        return res, files[0]

    def by_account(self, res):
        return {r.account_id: (r.cls, r.decision) for r in res.rows}

    def test_population_classes_and_dry_run_writes_nothing(self):
        before = sha(self.ledger)
        res, path = self.dry()
        self.assertEqual(self.by_account(res), {1: ("A1", R.FIX), 2: ("A2", R.FIX), 3: ("A3", R.REFUSE_CS),
                                                4: ("A2", R.FIX), 5: ("A5", R.HOLD_CS)})
        self.assertEqual(self.api.puts, [])
        self.assertEqual(sha(self.ledger), before)
        db = sqlite3.connect(self.ledger)
        self.assertIsNone(db.execute("SELECT 1 FROM sqlite_master WHERE name='intercom_identity_fix'").fetchone())
        db.close()
        self.assertEqual(res.cap, R.FIRST_RUN_CAP)
        out = Path(path).read_text() + Path(path.replace(".json", ".md")).read_text() + \
            Path(path.replace(".json", "-cs.json")).read_text()
        self.assertNotIn("@x.com", out)    # ids only, never an email
        cs = json.loads(Path(path.replace(".json", "-cs.json")).read_text())["rows"]
        self.assertEqual(sorted(r["account_id"] for r in cs), [3, 5])
        self.assertEqual(next(r for r in cs if r["account_id"] == 3)["other_account_ids"], ["9"])

    def test_apply_needs_the_approved_dry_run(self):
        res = self.run_(mode="apply")
        self.assertIn("--approved", res.halted)
        self.assertEqual(self.api.puts, [])

    def test_apply_writes_ledger_first_fixes_and_lifts_only_fixed_holds(self):
        _, approved = self.dry()

        def check_ledger_first(cid, body):
            if body["external_id"] is None:
                return
            db = sqlite3.connect(self.ledger)
            row = db.execute("SELECT status, old_external_id FROM intercom_identity_fix WHERE contact_id=? "
                             "ORDER BY id DESC", (cid,)).fetchone()
            db.close()
            self.assertEqual(row[0], "pending", "the ledger row must exist before the write")
            self.assertEqual(row[1], R.ext_of(self.api.c[cid]))
        self.api.on_put = check_ledger_first
        res = self.run_(mode="apply", approved=approved)
        self.assertEqual(sorted(c for c, _ in self.api.puts), ["c1", "c2", "c4"])
        self.assertEqual((res.applied, res.failed, res.unverified), (3, 0, 0))
        self.assertEqual(self.api.c["c2"]["external_id"], pro(2))
        self.assertEqual(self.api.c["c3"]["external_id"], pro(9))     # A3 untouched
        db = verify_ledger.connect(self.ledger)
        try:
            for uid, lifted in ((1, True), (2, True), (3, False)):
                h = verify_ledger.refusal_hold(db, "status-team-review", f"u{uid}@x.com", NOW, str(uid))
                self.assertEqual(h == {}, lifted, uid)
            rows = db.execute("SELECT account_id, old_external_id, new_external_id, class, status FROM intercom_identity_fix "
                              "ORDER BY account_id").fetchall()
        finally:
            db.close()
        self.assertEqual([tuple(r) for r in rows], [("1", "", pro(1), "A1", "applied"), ("2", orphan(2), pro(2), "A2", "applied"),
                                                    ("4", orphan(4), pro(4), "A2", "applied")])

    def test_apply_writes_only_rows_fix_in_the_approved_dry_run(self):
        _, approved = self.dry()
        doc = json.loads(Path(approved).read_text())
        doc["rows"] = [r for r in doc["rows"] if r["account_id"] == 2]
        Path(approved).write_text(json.dumps(doc))
        res = self.run_(mode="apply", approved=approved)
        self.assertEqual([c for c, _ in self.api.puts], ["c2"])
        self.assertEqual(res.applied, 1)

    def test_apply_classes_filter(self):
        _, approved = self.dry()
        self.run_(mode="apply", approved=approved, classes=("A2",))
        self.assertEqual(sorted(c for c, _ in self.api.puts), ["c2", "c4"])

    def test_contact_changed_since_the_approved_dry_run_is_not_written(self):
        _, approved = self.dry()
        self.api.c["c2"]["external_id"] = orphan(77)
        self.run_(mode="apply", approved=approved, classes=("A2",))
        self.assertEqual([c for c, _ in self.api.puts], ["c4"])   # c2 re-classified with a new old id: not approved

    def test_contact_changed_between_classification_and_write_is_not_written(self):
        _, approved = self.dry()
        inner, searched = self.api, set()

        def api(method, path, body):
            if method == "POST":
                searched.add(body["query"]["value"])
            elif method == "GET" and path == "/contacts/c2" and "u2@x.com" in searched:
                inner.c["c2"]["external_id"] = "changed-meanwhile"   # the re-read right before the write
            return inner(method, path, body)
        res = R.run(ledger_path=self.ledger, query=self.world, api=api, now=NOW, lens=fraud_lens.null_lens,
                    mode="apply", approved=approved, classes=("A2",))
        self.assertEqual([c for c, _ in self.api.puts], ["c4"])
        self.assertEqual(res.skipped, 1)
        self.assertIn("changed since it was classified", res.errors[0])

    def test_every_write_condition_is_rechecked_right_before_each_write(self):
        """QA @28ddcca: a condition that changes while earlier rows are written blocks the later write."""
        _, approved = self.dry()
        held = set()

        def lens(ids):
            return {u: fraud_lens.Verdict(held=["watchlist"] if u in held else []) for u in ids}

        def meanwhile(cid, body):
            if cid == "c1":
                self.users[99] = {"email": "u4@x.com"}                         # another account takes u4's email
                self.api.c["c88"] = contact("c88", "other@x.com", pro(2))      # pro(2) appears on another contact
        self.api.on_put = meanwhile
        res = self.run_(mode="apply", approved=approved, lens=lens)
        self.assertEqual([c for c, _ in self.api.puts], ["c1"])
        self.assertEqual((res.applied, res.skipped), (1, 2))
        self.assertTrue(any("another Muso account holds this email (99)" in e for e in res.errors), res.errors)
        self.assertTrue(any("already the external_id of another Intercom contact" in e for e in res.errors), res.errors)
        # and a user the lens starts holding mid-run
        self.setUp()
        _, approved = self.dry()
        self.api.on_put = lambda cid, body: held.add(4)
        res = self.run_(mode="apply", approved=approved, lens=lens, classes=("A2",))
        self.assertEqual([c for c, _ in self.api.puts], ["c2"])
        self.assertTrue(any("fraud_hold" in e for e in res.errors), res.errors)

    def test_an_email_shaped_external_id_never_reaches_the_artifacts(self):
        self.api.c["c3"]["external_id"] = "somebody.private@gmail.com"
        res, path = self.dry()
        self.assertEqual(self.by_account(res)[3], ("A3", R.REFUSE_CS))
        for f in (path, path.replace(".json", ".md"), path.replace(".json", "-cs.json")):
            text = Path(f).read_text()
            self.assertNotIn("@", text, f)
        self.assertIn("<redacted sha256:", Path(path.replace(".json", "-cs.json")).read_text())

    def test_failed_write_is_recorded_and_lifts_no_hold(self):
        _, approved = self.dry()
        self.api.put_status = 409
        res = self.run_(mode="apply", approved=approved)
        self.assertEqual((res.applied, res.failed), (0, 3))
        db = verify_ledger.connect(self.ledger)
        try:
            self.assertTrue(verify_ledger.refusal_hold(db, "status-team-review", "u2@x.com", NOW, "2"))
            self.assertEqual({r[0] for r in db.execute("SELECT status FROM intercom_identity_fix")}, {"failed"})
        finally:
            db.close()

    def test_revert_restores_old_ids_and_holds(self):
        _, approved = self.dry()
        res = self.run_(mode="apply", approved=approved, classes=("A2",))
        dry = R.revert(res.run_id, ledger_path=self.ledger, api=self.api, now=NOW)
        self.assertEqual((dry.reverted, len(self.api.puts)), (2, 2))  # dry revert: reads only
        rv = R.revert(res.run_id, mode="apply", ledger_path=self.ledger, api=self.api, now=NOW)
        self.assertEqual((rv.reverted, rv.failed, rv.holds_restored), (2, 0, 1))
        self.assertEqual(self.api.c["c2"]["external_id"], orphan(2))
        self.assertEqual(self.api.c["c4"]["external_id"], orphan(4))
        db = verify_ledger.connect(self.ledger)
        try:
            self.assertTrue(verify_ledger.refusal_hold(db, "status-team-review", "u2@x.com", NOW, "2"))
            self.assertEqual({r[0] for r in db.execute("SELECT status FROM intercom_identity_fix")}, {"reverted"})
        finally:
            db.close()
        again = R.revert(res.run_id, mode="apply", ledger_path=self.ledger, api=self.api, now=NOW)
        self.assertIn("nothing to revert", again.halted)

    def test_revert_refuses_a_contact_changed_since_the_fix(self):
        _, approved = self.dry()
        res = self.run_(mode="apply", approved=approved, classes=("A2",))
        self.api.c["c2"]["external_id"] = "someone-else"
        rv = R.revert(res.run_id, mode="apply", ledger_path=self.ledger, api=self.api, now=NOW)
        self.assertEqual((rv.reverted, rv.refused), (1, 1))
        self.assertEqual(self.api.c["c2"]["external_id"], "someone-else")

    def test_interrupted_revert_is_recovered_by_a_retry(self):
        """QA @214ea86: a crash after `reverting` is written must not strand the row."""
        _, approved = self.dry()
        res = self.run_(mode="apply", approved=approved, classes=("A2",))

        def crash(cid, body):
            raise ConnectionError("network died mid-revert")
        self.api.on_put = crash
        with self.assertRaises(ConnectionError):
            R.revert(res.run_id, mode="apply", ledger_path=self.ledger, api=self.api, now=NOW)
        db = sqlite3.connect(self.ledger)
        self.assertIn("reverting", {r[0] for r in db.execute("SELECT status FROM intercom_identity_fix")})
        db.close()
        self.api.on_put = None
        rv = R.revert(res.run_id, mode="apply", ledger_path=self.ledger, api=self.api, now=NOW)
        self.assertEqual((rv.reverted, rv.failed, rv.holds_restored), (2, 0, 1))
        self.assertEqual((self.api.c["c2"]["external_id"], self.api.c["c4"]["external_id"]), (orphan(2), orphan(4)))

    def test_revert_refuses_a_contact_moved_to_another_email(self):
        """QA @214ea86: same external_id, different owner: the old id is not written onto it."""
        _, approved = self.dry()
        res = self.run_(mode="apply", approved=approved, classes=("A2",))
        self.api.c["c2"]["email"] = "somebody-else@x.com"
        rv = R.revert(res.run_id, mode="apply", ledger_path=self.ledger, api=self.api, now=NOW)
        self.assertEqual((rv.reverted, rv.refused), (1, 1))
        self.assertEqual(self.api.c["c2"]["external_id"], pro(2))
        self.assertEqual([c for c, b in self.api.puts if b["external_id"] == orphan(2)], [])
        db = sqlite3.connect(self.ledger)
        owner = db.execute("SELECT contact_owner FROM intercom_identity_fix WHERE contact_id='c2'").fetchone()[0]
        db.close()
        self.assertRegex(owner, r"^[0-9a-f]{64}$")      # hashed, never the email

    def test_revert_and_apply_share_one_lock(self):
        """QA @0df73a9: a revert never overlaps an apply (or another revert): whichever comes second
        writes nothing."""
        import fcntl
        _, approved = self.dry()
        res = self.run_(mode="apply", approved=approved, classes=("A2",))
        puts = len(self.api.puts)
        with open(f"{self.ledger}.intercom-reconcile.lock", "a+") as held:
            fcntl.flock(held.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            rv = R.revert(res.run_id, mode="apply", ledger_path=self.ledger, api=self.api, now=NOW)
            again = self.run_(mode="apply", approved=approved)
        self.assertIn("in progress", rv.halted)
        self.assertIn("in progress", again.halted)
        self.assertEqual(len(self.api.puts), puts)
        self.assertEqual(self.api.c["c2"]["external_id"], pro(2))
        # the dry-run revert only reads: it takes no lock
        with open(f"{self.ledger}.intercom-reconcile.lock", "a+") as held:
            fcntl.flock(held.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(R.revert(res.run_id, ledger_path=self.ledger, api=self.api, now=NOW).halted, "")
        # with the lock free, the revert goes through
        rv = R.revert(res.run_id, mode="apply", ledger_path=self.ledger, api=self.api, now=NOW)
        self.assertEqual((rv.halted, rv.reverted), ("", 2))

    def test_the_lock_is_held_for_the_whole_revert(self):
        import fcntl
        _, approved = self.dry()
        res = self.run_(mode="apply", approved=approved, classes=("A2",))
        seen = []

        def probe(cid, body):
            with open(f"{self.ledger}.intercom-reconcile.lock", "a+") as fh:
                try:
                    fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                    seen.append("free")
                    fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
                except OSError:
                    seen.append("held")
        self.api.on_put = probe
        R.revert(res.run_id, mode="apply", ledger_path=self.ledger, api=self.api, now=NOW)
        self.assertEqual(seen, ["held", "held"])

    def test_a1_revert_that_intercom_will_not_clear_is_reported_for_a_human(self):
        _, approved = self.dry()
        self.api.keep_on_null = True
        res = self.run_(mode="apply", approved=approved, classes=("A1",))
        rv = R.revert(res.run_id, mode="apply", ledger_path=self.ledger, api=self.api, now=NOW)
        self.assertEqual((rv.reverted, rv.failed), (0, 1))
        self.assertIn("a human must restore this A1 contact", rv.rows[0]["result"])
        db = sqlite3.connect(self.ledger)
        self.assertEqual(db.execute("SELECT status FROM intercom_identity_fix").fetchone()[0], "revert_failed")
        db.close()

    def test_fraud_held_user_is_not_written(self):
        res = self.run_(lens=lambda ids: {u: fraud_lens.Verdict(held=["x"] if u == 2 else []) for u in ids})
        self.assertEqual(self.by_account(res)[2], ("A2", R.FRAUD_HOLD))

    def test_segment_paid_drops_unpaid_accounts(self):
        self.users[2]["paid"] = False
        res = self.run_()
        self.assertNotIn(2, self.by_account(res))
        self.assertEqual(res.not_in_segment, 1)

    def test_missing_watchlist_halts_before_any_read(self):
        self.saved = R.fraud_lens.default_lens
        R.fraud_lens.default_lens = lambda q: (_ for _ in ()).throw(ValueError("fraud watchlist missing: x"))
        try:
            res = R.run(ledger_path=self.ledger, query=self.world, api=self.api, now=NOW)
        finally:
            R.fraud_lens.default_lens = self.saved
        self.assertIn("fraud lens unavailable", res.halted)


class CapTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="irc-cap-"))
        self.ledger = str(self.dir / "ledger.sqlite3")
        n = 60
        users = {u: {"email": f"u{u}@x.com"} for u in range(1, n + 1)}
        self.world = World(users)
        seed(self.ledger, holds=[(u, f"u{u}@x.com", MISMATCH) for u in users])
        self.api = FakeIntercom([contact(f"c{u}", f"u{u}@x.com", orphan(u)) for u in users])

    def test_first_apply_run_is_capped_at_50_then_uncapped(self):
        dry = R.run(ledger_path=self.ledger, query=self.world, api=self.api, now=NOW, lens=fraud_lens.null_lens,
                    max_users=500)
        self.assertEqual(dry.cap, 50)
        approved = R.write_outputs(dry, str(self.dir / "out"))[0]
        first = R.run(mode="apply", approved=approved, ledger_path=self.ledger, query=self.world, api=self.api, now=NOW,
                      lens=fraud_lens.null_lens, max_users=500)
        self.assertEqual((first.cap, first.applied, first.over_cap), (50, 50, 10))
        second = R.run(mode="apply", approved=approved, ledger_path=self.ledger, query=self.world, api=self.api, now=NOW,
                       lens=fraud_lens.null_lens, max_users=500)
        self.assertEqual((second.cap, second.applied, second.over_cap), (500, 10, 0))
        self.assertEqual(len(self.api.puts), 60)

    def test_max_users_below_the_cap(self):
        dry = R.run(ledger_path=self.ledger, query=self.world, api=self.api, now=NOW, lens=fraud_lens.null_lens)
        approved = R.write_outputs(dry, str(self.dir / "out"))[0]
        res = R.run(mode="apply", approved=approved, ledger_path=self.ledger, query=self.world, api=self.api, now=NOW,
                    lens=fraud_lens.null_lens, max_users=3)
        self.assertEqual((res.applied, res.over_cap), (3, 57))


class ReasonTests(unittest.TestCase):
    def test_reason_kinds(self):
        self.assertEqual(R.reason_kind(MISMATCH), "mismatch")
        self.assertEqual(R.reason_kind(NO_EXT), "no_external_id")
        self.assertEqual(R.reason_kind(SEVERAL), "several_contacts")
        self.assertEqual(R.reason_kind("the account email matches 0 Intercom users (need exactly 1); not sending."),
                         "no_contact")
        self.assertEqual(R.reason_kind(FORBIDDEN), "action_forbidden")
        self.assertEqual(R.reason_kind("credits has 1209 entries"), "")


if __name__ == "__main__":
    unittest.main()
