"""uvn-status runner + ledger rules (firstmate 060). The gate is faked here; its own
behaviour is in intercom-verify-request.bats. No network, no Trino."""

from __future__ import annotations

import credit_test_env  # noqa: F401,E402 - first: test logs + the signed-head harness never reach production

import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from credit_review import fraud_lens, uvn_status, verify_ledger, verify_notify, withdrawal_confirm  # noqa: E402
from credit_review import verify_notify as _vn_r5  # noqa: E402
_vn_r5.PRESENTED_LOOKUP = lambda ids: {}  # r5: presented profile ids never come from the replica in tests

# The fake replica below answers every non-users query with request rows, so the real fraud lens
# (its own queries) is replaced here by one that holds nobody. The lens itself, and the runner's
# use of it (fatal load, fraud_held, ask_only), are tested in test_fraud_lens.py.
uvn_status.DEFAULT_LENS = lambda query, **kw: fraud_lens.null_lens

NOW = datetime.now(timezone.utc).replace(microsecond=0)  # proof-on-file freshness is judged on the real clock
FIXED = datetime(2026, 10, 20, 9, 0, tzinfo=timezone.utc)


def iso(h):
    return (NOW - timedelta(hours=h)).strftime("%Y-%m-%dT%H:%M:%SZ")


def proof(path, entries=()):
    users = {str(e["user_id"]) for e in entries}
    Path(path).write_text(json.dumps({
        "generated_at": iso(0.2), "users": len(users), "entries": list(entries),
        "sources": [{"name": "core", "generated_at": iso(0.2)},
                    {"name": "cs-intercom", "generated_at": iso(0.5), "stale": False},
                    {"name": "cs-gmail", "generated_at": iso(0.5), "stale": False}],
        "gmail_contacts_90d": {"generated_at": iso(0.5), "source": "test", "user_ids": []}}))


class FakeGate:
    """Records each send (argv, payload). A read-only --thread-contact lookup is answered with
    `thread` (the conversation's single contact) and recorded in `lookups`, not in `calls`."""

    def __init__(self, rc=0, out="POSTED email message=1 credits=1", thread=None):
        self.calls, self.rc, self.out, self.lookups = [], rc, out, []
        self.thread = thread or {"contacts": 1, "role": "user", "external_id": ""}

    def __call__(self, argv):
        payload = json.loads(Path(argv[argv.index("--credits-file") + 1]).read_text())
        if "--thread-contact" in argv:
            self.lookups.append((argv, payload))
            return subprocess.CompletedProcess(argv, 0, "THREAD_CONTACT " + json.dumps(self.thread), "")
        self.calls.append((argv, payload))
        return subprocess.CompletedProcess(argv, self.rc, self.out, "")


def query(rows_by_sql):
    def q(sql):
        if "proof_required_owed" in sql:                 # core proof_required read (status-team-review preflight)
            return rows_by_sql.get("proof_required", [["0", "0"]])
        return rows_by_sql["users" if "public.users" in sql else "requests"]
    return q


class LedgerGate(FakeGate):
    """Records each send in the ledger the way the real gate does (claim, then sent)."""

    def __init__(self, ledger):
        super().__init__()
        self.ledger = ledger

    def __call__(self, argv):
        res = super().__call__(argv)
        payload = self.calls[-1][1]
        db = verify_ledger.connect(self.ledger)
        try:
            c = verify_ledger.claim(db, campaign="uvn-status", user_key=payload["user"]["email"],
                                    day=NOW.strftime("%Y-%m-%d"), request_ids=[r["request_id"] for r in payload["credits"]],
                                    message_type="email", approved_by="U7RP6HKUZ", approval_ref="ref", now=NOW,
                                    user_id=payload["user"]["id"])
            if c["result"] != "claimed":
                return subprocess.CompletedProcess(argv, 0, "SKIPPED already-notified credits=1", "")
            verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id=str(len(self.calls)))
        finally:
            db.close()
        return res


class ScriptedGate(LedgerGate):
    """Per user id: 'unknown' claims in the ledger then fails the post check (rc 4, claim left
    'attempted'), 'lookup' fails before any claim (rc 4), 'defer' is an Intercom deferral (rc 3);
    anyone else is claimed and sent like LedgerGate."""

    def __init__(self, ledger, script):
        super().__init__(ledger)
        self.script = script

    def __call__(self, argv):
        payload = json.loads(Path(argv[argv.index("--credits-file") + 1]).read_text())
        what = self.script.get(payload["user"]["id"])
        if what is None:
            return super().__call__(argv)
        self.calls.append((argv, payload))
        if what == "defer":
            return subprocess.CompletedProcess(argv, 3, "DEFERRED messaged_7d credits=1 (we replied)", "")
        if what == "lookup":
            return subprocess.CompletedProcess(argv, 4, "", "CONTACT LOOKUP FAILED (curl); nothing was sent or claimed")
        db = verify_ledger.connect(self.ledger)
        try:
            c = verify_ledger.claim(db, campaign="uvn-status", user_key=payload["user"]["email"],
                                    day=NOW.strftime("%Y-%m-%d"), request_ids=[r["request_id"] for r in payload["credits"]],
                                    message_type="email", approved_by="U7RP6HKUZ", approval_ref="ref", now=NOW)
            verify_ledger.finalize(db, message_row=c["message_row"], status="attempted", reason="unverified response")
        finally:
            db.close()
        return subprocess.CompletedProcess(argv, 4, "", "POST NOT VERIFIED: expected an admin_message; left CLAIMED")


class RecentGate(FakeGate):
    """The gate's Intercom-side deferral (exit 3, messaged in 7 days) for these user ids."""

    def __init__(self, recent):
        super().__init__()
        self.recent = recent

    def __call__(self, argv):
        res = super().__call__(argv)
        if self.calls[-1][1]["user"]["id"] in self.recent:
            return subprocess.CompletedProcess(argv, 3, "DEFERRED messaged_7d credits=1 (we replied)", "")
        return res


class RefusingGate(FakeGate):
    """The gate refusing (exit 1) these user ids, e.g. an email matching two Intercom users."""

    def __init__(self, refused):
        super().__init__()
        self.refused = refused

    def __call__(self, argv):
        res = super().__call__(argv)
        if self.calls[-1][1]["user"]["id"] in self.refused:
            return subprocess.CompletedProcess(argv, 1, "", "REFUSED: the account email matches 2 Intercom users")
        return res


class LedgerRefusingGate(FakeGate):
    """The real gate's re-checkable refusal: records it in the ledger, exits 1."""

    def __init__(self, ledger, campaign):
        super().__init__()
        self.ledger, self.campaign, self.now = ledger, campaign, NOW

    def __call__(self, argv):
        super().__call__(argv)
        payload = self.calls[-1][1]
        db = verify_ledger.connect(self.ledger)
        try:
            verify_ledger.refuse(db, campaign=self.campaign, user_key=payload["user"]["email"],
                                 day=self.now.strftime("%Y-%m-%d"), request_ids=[r["request_id"] for r in payload["credits"]],
                                 message_type="email", approved_by="U7RP6HKUZ", approval_ref="ref",
                                 reason="the account email (u1@x.com) matches 2 Intercom users", user_id=payload["user"]["id"],
                                 now=self.now)
        finally:
            db.close()
        return subprocess.CompletedProcess(argv, 1, "", "REFUSED: the account email matches 2 Intercom users")


class Poster:
    def __init__(self, ok=True):
        self.ok, self.texts = ok, []

    def __call__(self, text):
        self.texts.append(text)
        return self.ok


def auth(u):
    """A realistic Auth0 subject as core users.auth0userid stores it."""
    return f"auth0|6f1c2a9e-0b7d-4c3e-9a51-{int(u):012d}"


def pro(u):
    """users.neptuneprofessionalid: the Auth0 subject (bare) for Auth0 accounts."""
    return f"6f1c2a9e-0b7d-4c3e-9a51-{int(u):012d}"


def replica(users, status=None, requests=None, no_auth=(), no_pro=(), verification=None, rows=None):
    """A replica fake that answers only for the user ids the SQL asks about, and only with the
    requests whose status (`status[user]`, default user_verification_needed) the SQL selects.
    `requests[user]` lists that user's pending request ids (default [r<user>]);
    `verification[request id]` is that request's verificationData and `rows[request id]` may set
    its title, role, popularity and metadata."""
    import re
    status, requests, verification, rows = status or {}, requests or {}, verification or {}, rows or {}

    def q(sql):
        if "proof_required_owed" in sql:
            return [["0", "0"]]
        ids = {int(x) for x in re.search(r"IN \(([0-9,]+)\)", sql).group(1).split(",")}
        if "public.users" in sql:
            return [[str(u), f"u{u}@x.com", f"N{u}", None if u in no_pro else pro(u), None if u in no_auth else auth(u)]
                    for u in sorted(ids & set(users))]
        wanted = set(re.findall(r"'([a-z_]+)'", re.search(r"status IN \(([^)]*)\)", sql).group(1)))
        return [[rid, str(u), "p", "t", rows.get(rid, {}).get("title", f"Song {rid}"), '[{"name":"Art"}]',
                 rows.get(rid, {}).get("role", "{Mixing}"),
                 rows.get(rid, {}).get("pop", "5"), json.dumps(verification.get(rid, {})),
                 json.dumps(rows.get(rid, {}).get("metadata", {})), rows.get(rid, {}).get("created", "")]
                for u in sorted(ids & set(users)) if status.get(u, "user_verification_needed") in wanted
                for rid in requests.get(u, [f"r{u}"])]
    return q


class UvnStatusTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="uvn-"))
        self.list = self.dir / "list.json"
        self.proof = self.dir / "proof.json"
        self.ledger = str(self.dir / "ledger.sqlite3")
        proof(self.proof)
        self.users = [
            {"user_id": 1, "paid": True, "skip": None, "request_ids": ["r1", "r2"]},
            {"user_id": 2, "paid": True, "skip": "document_on_file", "request_ids": ["r3"]},
            {"user_id": 3, "paid": False, "skip": None, "request_ids": ["r4"]},
            {"user_id": 4, "paid": True, "skip": None, "request_ids": ["r5"]},
        ]
        self.write_list()
        self.q = query({
            "users": [["1", "a@x.com", "Ann", pro(1), auth(1)], ["4", "d@x.com", "Dee", pro(4), auth(4)]],
            "requests": [["r1", "1", "p1", "t1", "Low", '[{"name":"Art"}]', "{Mixing}", "10"],
                         ["r2", "1", "p1", "t2", "High", '[{"name":"Art"}]', "{Mixing,Mastering}", "80"]],
        })

    def write_list(self, age_h=2):
        self.list.write_text(json.dumps({"generated_at": iso(age_h), "users": self.users}))

    def run_(self, **kw):
        gate = kw.pop("gate", FakeGate())
        rep = uvn_status.run(list_path=str(self.list), segment=kw.pop("segment", "paid"), mode=kw.pop("mode", "apply"),
                             max_users=kw.pop("max_users", 10), ledger_path=self.ledger, proof_path=str(self.proof),
                             query=kw.pop("query", self.q), runner=gate, wrapper=kw.pop("wrapper", self.gate_file()),
                             now=NOW, pace_seconds=0, **kw)
        return rep, gate

    def gate_file(self, uvn: int = 1) -> str:
        """The gate script the runner reads its locks from: uvn-status unlocked (captain 03:2xZ) unless told."""
        p = self.dir / f"gate-uvn{uvn}.sh"
        p.write_text(f"readonly UVN_STATUS_COPY_APPROVED={uvn}\nreadonly CREDIT_HOLD_STATUS_COPY_APPROVED=0\n")
        return str(p)

    def test_uvn_status_never_reaches_the_gate_on_a_real_run_while_its_lock_is_0(self):
        rep, gate = self.run_(wrapper=self.gate_file(0))
        self.assertEqual(gate.calls, [])
        self.assertIn("UVN_STATUS_COPY_APPROVED=0", rep.halted)
        rep, gate = self.run_(wrapper=self.gate_file(0), mode="dry-run")
        self.assertTrue(gate.calls)
        rep, gate = self.run_()
        self.assertEqual(rep.halted, "")
        self.assertTrue(gate.calls)

    def test_canary_reaches_past_users_the_gate_defers_for_recent_contact(self):
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in range(1, 8)]
        self.write_list()
        gate = RecentGate({"1", "2", "3"})
        rep, _ = self.run_(max_users=3, gate=gate, query=replica(range(1, 8)))
        self.assertEqual([p["user"]["id"] for _, p in gate.calls], ["1", "2", "3", "4", "5", "6"])
        self.assertEqual((rep.users, rep.sent_notes, rep.deferred_users, rep.over_daily_max), (3, 3, 3, 1))

    def test_a_second_concurrent_apply_run_sends_nothing(self):
        import fcntl
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in range(1, 4)]
        self.write_list()
        # QA #1617: the credit campaigns share ONE run lock (one budget) - a status-note apply holding it blocks the ask
        with open(f"{self.ledger}.credit-group.run.lock", "a+") as held:
            fcntl.flock(held.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            rep, gate = self.run_(query=replica(range(1, 4)))
        self.assertIn("in progress", rep.halted)
        self.assertEqual(gate.calls, [])
        rep, gate = self.run_(query=replica(range(1, 4)))  # the lock is free again
        self.assertEqual(len(gate.calls), 3)

    def test_the_daily_cap_is_re_read_before_every_batch(self):
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in range(1, 6)]
        self.write_list()
        gate = LedgerGate(self.ledger)
        orig = uvn_status.DAILY_MAX
        try:
            uvn_status.DAILY_MAX = 2
            rep, _ = self.run_(gate=gate, max_users=5, query=replica(range(1, 6)))
            self.assertEqual(rep.sent_notes, 2)
            rep, gate2 = self.run_(gate=LedgerGate(self.ledger), max_users=5, query=replica(range(1, 6)))
            self.assertEqual(gate2.calls, [])  # cap already used today, by another run
        finally:
            uvn_status.DAILY_MAX = orig

    def test_an_unverified_post_uses_the_daily_cap_and_the_run_stops_at_it(self):
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in range(1, 9)]
        self.write_list()
        gate = ScriptedGate(self.ledger, {"1": "unknown", "2": "defer", "4": "defer"})
        orig = uvn_status.DAILY_MAX
        try:
            uvn_status.DAILY_MAX = 4
            rep, _ = self.run_(gate=gate, max_users=10, query=replica(range(1, 9)))
        finally:
            uvn_status.DAILY_MAX = orig
        self.assertEqual([p["user"]["id"] for _, p in gate.calls], ["1", "2", "3", "4", "5", "6"])
        self.assertEqual((rep.sent_notes, rep.outcome_unknown, rep.deferred_users), (3, 1, 2))
        db = verify_ledger.connect(self.ledger)
        try:
            self.assertEqual(verify_ledger.sent_today(db, campaign="uvn-status", day=NOW.strftime("%Y-%m-%d")), 4)
        finally:
            db.close()

    def test_a_canary_of_3_stops_after_3_posts_whose_outcome_is_unknown(self):
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in range(1, 11)]
        self.write_list()
        script = {str(u): "unknown" for u in range(1, 11)}
        script["1"] = "lookup"
        gate = ScriptedGate(self.ledger, script)
        rep, _ = self.run_(gate=gate, max_users=3, query=replica(range(1, 11)))
        self.assertEqual([p["user"]["id"] for _, p in gate.calls], ["1", "2", "3", "4"])
        self.assertEqual((rep.sent_notes, rep.outcome_unknown, rep.failed_users, rep.users), (0, 3, 4, 0))
        self.assertIn("3 post(s) not verified (outcome unknown", uvn_status.render(rep, "apply", "paid"))

    def test_a_status_note_request_resolved_before_its_send_is_reported_not_pending(self):
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in (1, 2)]
        self.write_list()
        status = {1: "processing"}

        class ApprovesUser2(FakeGate):
            def __call__(self, argv):
                res = super().__call__(argv)
                status[2] = "approved"
                return res
        gate = ApprovesUser2()
        rep, _ = self.run_(gate=gate, query=replica((1, 2), status=status), campaign="status-doc-received")
        self.assertEqual([p["user"]["id"] for _, p in gate.calls], ["1"])
        self.assertEqual((rep.not_pending, rep.no_longer_uvn), (1, 0))
        self.assertIn("1 no request still pending (not closed)", uvn_status.render(rep, "apply", "paid"))

    def test_a_request_resolved_while_earlier_users_are_messaged_is_not_asked(self):
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in (1, 2)]
        self.write_list()
        status = {1: "user_verification_needed"}  # non-empty: replica() keeps this dict, so the change below is seen
        base = replica((1, 2), status=status)

        class ApprovesUser2(FakeGate):
            def __call__(self, argv):
                res = super().__call__(argv)
                status[2] = "approved"  # approved by the decider while user 1 was being messaged
                return res
        gate = ApprovesUser2()
        rep, _ = self.run_(gate=gate, query=base)
        self.assertEqual([p["user"]["id"] for _, p in gate.calls], ["1"])
        self.assertEqual(rep.no_longer_uvn, 1)
        self.assertEqual(rep.by_reason.get("changed_before_send"), 1)

    def test_gate_skips_and_failures_do_not_use_the_canary_budget(self):
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in range(1, 7)]
        self.write_list()

        class SkipsFirstTwo(FakeGate):
            def __call__(self, argv):
                res = super().__call__(argv)
                uid = self.calls[-1][1]["user"]["id"]
                if uid == "1":
                    return subprocess.CompletedProcess(argv, 0, "SKIPPED already-notified credits=1", "")
                if uid == "2":
                    return subprocess.CompletedProcess(argv, 2, "", "curl: (28) timeout")
                return res
        gate = SkipsFirstTwo()
        rep, _ = self.run_(gate=gate, max_users=3, query=replica(range(1, 7)))
        self.assertEqual((rep.sent_notes, rep.skipped, rep.failed_users), (3, 1, 1))
        self.assertEqual([p["user"]["id"] for _, p in gate.calls], ["1", "2", "3", "4", "5"])

    def test_status_note_canary_reaches_past_users_the_gate_refuses(self):
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in range(1, 8)]
        self.write_list()
        for campaign in ("status-doc-received", "status-team-review"):
            gate = RefusingGate({"1", "2", "3"})
            rep, _ = self.run_(max_users=3, gate=gate, query=replica(range(1, 8)), campaign=campaign)
            self.assertEqual([p["user"]["id"] for _, p in gate.calls], ["1", "2", "3", "4", "5", "6"], campaign)
            self.assertEqual((rep.users, rep.sent_notes, rep.refused_users), (3, 3, 3), campaign)
            self.assertIn("3 refused by the gate", uvn_status.render(rep, "apply", "paid"))
        gate = RefusingGate({str(u) for u in range(1, 8)})
        rep, _ = self.run_(max_users=1, gate=gate, query=replica(range(1, 8)), campaign="status-team-review")
        self.assertEqual((len(gate.calls), rep.users), (uvn_status.MAX_CALLS_PER_USER, 0))

    def test_status_note_refusal_is_rechecked_weekly_then_flagged_once_and_blocked(self):
        self.users = [{"user_id": 1, "paid": True, "skip": None, "request_ids": ["r1"]}]
        gate = LedgerRefusingGate(self.ledger, "status-team-review")
        post = Poster(ok=False)

        def run_at(days, **kw):
            now = NOW + timedelta(days=days)
            gate.now = now
            self.list.write_text(json.dumps({"generated_at": (now - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"),
                                             "users": self.users}))
            rep = uvn_status.run(list_path=str(self.list), segment="paid", mode="apply", max_users=3,
                                 ledger_path=self.ledger, query=replica((1,)), runner=gate, wrapper="/gate", now=now,
                                 pace_seconds=0, campaign="status-team-review", post=post, **kw)
            return rep

        rep = run_at(0)
        self.assertEqual((len(gate.calls), rep.refused_users, rep.users), (1, 1, 0))
        rep = run_at(6)
        self.assertEqual((len(gate.calls), rep.refused_recheck, rep.recheck_after), (1, 1, (NOW + timedelta(days=7)).strftime("%Y-%m-%d")))
        self.assertIn("1 refused, re-check after", uvn_status.render(rep, "apply", "paid"))
        rep = run_at(7.1)
        self.assertEqual(len(gate.calls), 2)
        db = verify_ledger.connect(self.ledger)
        self.assertEqual(db.execute("SELECT refusals FROM verify_refusal_holds WHERE user_key='u1@x.com'").fetchone()[0], 2)
        db.close()
        self.assertEqual(post.texts, [])
        rep = run_at(14.2)  # third refusal: the post fails, nothing is flagged, the run fails
        self.assertEqual(len(gate.calls), 3)
        self.assertEqual((rep.flagged, len(post.texts)), (0, 1))
        self.assertTrue(rep.failed)
        self.assertNotIn("u1@x.com", post.texts[0])
        self.assertIn("Muso user 1", post.texts[0])
        self.assertIn("status-team-review", post.texts[0])
        post.ok = True
        rep = run_at(15)  # still held; the flag post is retried and lands once
        self.assertEqual((len(gate.calls), rep.flagged, len(post.texts)), (3, 1, 2))
        self.assertFalse(rep.failed)
        rep = run_at(30)  # flagged: blocked, never picked or posted again
        self.assertEqual((len(gate.calls), rep.already_handled, rep.flagged, len(post.texts)), (3, 1, 0, 2))

    def test_a_held_user_is_skipped_even_when_the_listed_requests_drift(self):
        self.users = [{"user_id": 1, "paid": True, "skip": None, "request_ids": ["r1", "r2"]}]
        self.write_list()
        gate = LedgerRefusingGate(self.ledger, "status-team-review")
        rep, _ = self.run_(gate=gate, query=replica((1,), requests={1: ["r1"]}), campaign="status-team-review", post=Poster())
        self.assertEqual((len(gate.calls), rep.refused_users), (1, 1))
        # same list, r2 no longer pending: the user is still skipped, never handed to the gate
        rep, _ = self.run_(gate=gate, query=replica((1,), requests={1: ["r1"]}), campaign="status-team-review", post=Poster())
        self.assertEqual((len(gate.calls), rep.refused_recheck, rep.deferred_users, rep.users), (1, 1, 0, 0))
        self.assertIn("refused, re-check after", uvn_status.render(rep, "apply", "paid"))

    def test_holds_strikes_and_the_flag_are_per_user_whatever_the_requests(self):
        gate = LedgerRefusingGate(self.ledger, "status-team-review")
        post = Poster()

        def run_at(days, rids):
            now = NOW + timedelta(days=days)
            gate.now = now
            self.users = [{"user_id": 1, "paid": True, "skip": None, "request_ids": rids}]
            self.list.write_text(json.dumps({"generated_at": (now - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"),
                                             "users": self.users}))
            return uvn_status.run(list_path=str(self.list), segment="paid", mode="apply", max_users=3,
                                  ledger_path=self.ledger, query=replica((1,), requests={1: rids}), runner=gate,
                                  wrapper="/gate", now=now, pace_seconds=0, campaign="status-team-review", post=post)

        run_at(0, ["r1"])
        rep = run_at(2, ["r1", "r3"])  # a new request during the hold does not re-check the user
        self.assertEqual((len(gate.calls), rep.refused_recheck), (1, 1))
        run_at(7.1, ["r3"])
        run_at(14.2, ["r4"])  # third refusal of the USER, whichever requests: flagged once
        self.assertEqual((len(gate.calls), len(post.texts)), (3, 1))
        for days, rids in ((21.3, ["r5"]), (40, ["r1", "r6"])):
            rep = run_at(days, rids)  # flagged: never picked again, never posted again
            self.assertEqual((len(gate.calls), len(post.texts), rep.already_handled), (3, 1, 1))

    def test_users_are_matched_by_professional_id_and_only_a_missing_one_is_held(self):
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in (1, 2, 3)]
        self.write_list()
        rep, gate = self.run_(query=replica((1, 2, 3), no_auth={1}, no_pro={2}), campaign="status-doc-received")
        self.assertEqual([(p["user"]["id"], p["user"]["professional_id"], p["user"]["auth_id"]) for _, p in gate.calls],
                         [("1", pro(1), ""), ("3", pro(3), "6f1c2a9e-0b7d-4c3e-9a51-000000000003")])
        self.assertEqual((rep.no_professional_id, rep.by_reason.get("no_professional_id")), (1, 1))
        self.assertIn("1 account(s) held: no professional id on the account", uvn_status.render(rep, "apply", "paid"))
        db = verify_ledger.connect(self.ledger)
        self.assertEqual(verify_ledger.blocked_ids(db, ["r2"], "status-doc-received"), set())
        db.close()

    ADMIT = {"is_approved": True, "total_risk_percent": 12,
             "rule_risk_percent": {"review_role_credited_to_other_at_trusted_source": 0}}

    def test_uvn_status_never_asks_about_requests_the_approval_path_admits_or_already_on_the_profile(self):
        self.users = [{"user_id": 1, "paid": True, "skip": None, "request_ids": ["a1", "a2", "a3", "a4"]},
                      {"user_id": 2, "paid": True, "skip": None, "request_ids": ["b1"]}]
        self.write_list()
        q = replica((1, 2), requests={1: ["a1", "a2", "a3", "a4"], 2: ["b1"]},
                    verification={"a1": {"duplicate_of": "cr-9"}, "a2": self.ADMIT,
                                  "a3": {"is_approved": True, "total_risk_percent": 45}, "a4": self.ADMIT,
                                  "b1": dict(self.ADMIT, band_hint="B")},
                    rows={"a4": {"metadata": {"proofRequest": {"at": "2026-10-19"}}}})
        rep, gate = self.run_(query=q)
        self.assertEqual([(p["user"]["id"], [c["request_id"] for c in p["credits"]]) for _, p in gate.calls],
                         [("1", ["a3", "a4"])])
        self.assertEqual([c["track_title"] for c in gate.calls[0][1]["credits"]], ["Song a3", "Song a4"])
        self.assertNotIn("_no_ask", gate.calls[0][1]["credits"][0])
        self.assertEqual((rep.already_on_profile, rep.approval_path, rep.low_risk_asked, rep.no_longer_uvn), (1, 2, 1, 0))
        text = uvn_status.render(rep, "apply", "paid")
        self.assertIn("2 request(s) not asked about: on the approval path", text)
        self.assertIn("1 request(s) not asked about: already on the profile", text)
        self.assertIn("1 request(s) asked although low risk (server needs proof)", text)
        db = verify_ledger.connect(self.ledger)
        self.assertEqual(verify_ledger.blocked_ids(db, ["b1"], "uvn-status"), set())
        db.close()
        # the status notes keep their own rules: the same requests are named there
        rep, gate = self.run_(query=q, campaign="status-team-review")
        self.assertEqual([[c["request_id"] for c in p["credits"]] for _, p in gate.calls],
                         [["a1", "a2", "a3", "a4"], ["b1"]])

    def test_only_rows_the_approval_path_can_actually_admit_skip_the_ask(self):
        def cls(vd, role="Mixing", pop=5, meta=None):
            return uvn_status.ask_class({"verificationData": vd, "metadata": meta or {}, "spotifyPopularity": pop,
                                         "roles": [role]})

        admit = self.ADMIT
        self.assertEqual(cls(admit), "approval_path")
        self.assertEqual(cls(dict(admit, band_hint="B")), "approval_path")  # a band-hint-only stamp still qualifies
        self.assertEqual(cls({"is_approved": True, "total_risk_percent": 12}, role="Composer"), "approval_path")
        for name, row in {
            "pop 0": cls(admit, pop=0),
            "pop 60": cls(admit, pop=60),
            "pop unknown": cls(admit, pop=None),
            "one-person role credited elsewhere": cls(dict(admit, rule_risk_percent={
                "review_role_credited_to_other_at_trusted_source": 1})),
            "one-person role with no rule scores": cls({"is_approved": True, "total_risk_percent": 12}),
            "remix credited elsewhere": cls(dict(admit, rule_risk_percent={
                "review_role_credited_to_other_at_trusted_source": 1}), role="Remixer"),
            "remix with no rule scores": cls({"is_approved": True, "total_risk_percent": 12}, role="Remixer"),
            "profile risk (server needs proof)": cls(dict(admit, profile_risk_level="high")),
            "band hint plus another proof reason": cls(dict(admit, band_hint="C", profile_risk_level="critical")),
            "proof requested": cls(admit, meta={"proofRequest": {}}),
        }.items():
            self.assertEqual(row, "low_risk_asked", name)
        for name, row in {
            "risk 30": cls(dict(admit, total_risk_percent=30)),
            "risk unreadable": cls(dict(admit, total_risk_percent="8")),
            "risk missing": cls({k: v for k, v in admit.items() if k != "total_risk_percent"}),
            "not validator-approved": cls(dict(admit, is_approved=False)),
            "no verificationData": uvn_status.ask_class({"verificationData": None, "roles": ["Mixing"],
                                                         "spotifyPopularity": 5}),
        }.items():
            self.assertEqual(row, "", name)
        self.assertEqual(cls({"duplicate_of": "cr-1"}), "already_on_profile")

    def test_queued_wording_is_passed_to_the_gate_for_status_doc_received_only(self):
        rep, gate = self.run_(campaign="status-doc-received", wording="queued")
        argv = gate.calls[0][0]
        self.assertEqual(argv[argv.index("--copy") + 1], "queued")
        rep, gate = self.run_(campaign="status-doc-received")
        self.assertNotIn("--copy", gate.calls[0][0])
        for campaign in ("uvn-status", "status-team-review"):
            with self.assertRaises(ValueError):
                self.run_(campaign=campaign, wording="queued")

    def test_no_ask_wording_is_passed_to_the_gate_for_status_team_review_only(self):
        rep, gate = self.run_(campaign="status-team-review", wording="no-ask")
        argv = gate.calls[0][0]
        self.assertEqual(argv[argv.index("--copy") + 1], "no-ask")
        for campaign in ("uvn-status", "status-doc-received"):
            with self.assertRaises(ValueError):
                self.run_(campaign=campaign, wording="no-ask")

    def test_received_wording_never_reaches_the_gate_on_a_real_run_while_locked(self):
        # proof-loop card R1: send-locked in the gate. A real run halts before any gate call (a refusal of a
        # status note would hold and COUNT against the user); a dry run passes --copy received through.
        rep, gate = self.run_(campaign="status-doc-received", wording="received")
        self.assertEqual(gate.calls, [])
        self.assertIn("STATUS_RECEIVED_COPY_APPROVED=0", rep.halted)
        rep, gate = self.run_(campaign="status-doc-received", wording="received", mode="dry-run")
        argv = gate.calls[0][0]
        self.assertEqual(argv[argv.index("--copy") + 1], "received")
        # the gate script is the source of truth: unlocked there -> the real run goes
        unlocked = self.dir / "gate-unlocked.sh"
        unlocked.write_text("#!/bin/bash\nreadonly STATUS_RECEIVED_COPY_APPROVED=1\n")
        gate = FakeGate()
        rep = uvn_status.run(list_path=str(self.list), segment="paid", mode="apply", max_users=10,
                             ledger_path=self.ledger, proof_path=str(self.proof), query=self.q, runner=gate,
                             wrapper=str(unlocked), now=NOW, pace_seconds=0, campaign="status-doc-received",
                             wording="received")
        self.assertEqual(rep.halted, "")
        self.assertTrue(gate.calls)
        for campaign in ("uvn-status", "status-team-review"):
            with self.assertRaises(ValueError):
                self.run_(campaign=campaign, wording="received")
        self.assertFalse(uvn_status.gate_lock_open(str(self.dir / "missing.sh"), "STATUS_RECEIVED_COPY_APPROVED"))
        locked = self.dir / "gate-locked.sh"
        locked.write_text("#!/bin/bash\nreadonly STATUS_RECEIVED_COPY_APPROVED=0\nreadonly OTHER_COPY_APPROVED=1\n")
        self.assertFalse(uvn_status.gate_lock_open(str(locked), "STATUS_RECEIVED_COPY_APPROVED"))

    def test_the_lists_filing_conversation_reaches_the_gate_payload(self):
        # s1 guard G3: R1 goes only to the contact that filed the document; the list names its conversation
        self.users[0]["filing_conversation"] = "215476000000001"
        self.write_list()
        rep, gate = self.run_(campaign="status-doc-received", mode="dry-run")
        self.assertEqual(gate.calls[0][1]["user"].get("filing_conversation"), "215476000000001")
        self.assertNotIn("filing_conversation", gate.calls[-1][1]["user"]) if len(gate.calls) > 1 else None

    def test_credit_hold_status_never_reaches_the_gate_on_a_real_run_while_locked(self):
        # Fable S1 (card L14a): send-locked in the gate; a real run halts before any gate call, a dry run renders.
        rep, gate = self.run_(campaign="credit-hold-status")
        self.assertEqual(gate.calls, [])
        self.assertIn("CREDIT_HOLD_STATUS_COPY_APPROVED=0", rep.halted)
        rep, gate = self.run_(campaign="credit-hold-status", mode="dry-run")
        argv = gate.calls[0][0]
        self.assertEqual(argv[argv.index("--campaign") + 1], "credit-hold-status")
        locked = self.dir / "gate-locked.sh"
        locked.write_text("readonly CREDIT_HOLD_STATUS_COPY_APPROVED=0\nreadonly OTHER=1\n")
        self.assertFalse(uvn_status.campaign_lock_open(str(locked), "CREDIT_HOLD_STATUS_COPY_APPROVED"))
        unlocked = self.dir / "gate-unlocked.sh"
        unlocked.write_text("readonly CREDIT_HOLD_STATUS_COPY_APPROVED=1\n")
        gate = FakeGate()
        rep = uvn_status.run(list_path=str(self.list), segment="paid", mode="apply", max_users=10,
                             ledger_path=self.ledger, proof_path=str(self.proof), query=self.q, runner=gate,
                             wrapper=str(unlocked), now=NOW, pace_seconds=0, campaign="credit-hold-status")
        self.assertEqual(rep.halted, "")
        self.assertTrue(gate.calls)

    def test_the_doc_check_audit_matches_the_recipient_like_a_send(self):
        saved = verify_notify.IDENTITY_LOOKUP
        verify_notify.IDENTITY_LOOKUP = lambda ids: {"42": {"professional_id": "pro-42", "auth_id": ""}}
        try:
            gate = FakeGate(out="NO_DOCS")
            ps = [{"user": {"email": f"{u}@x.com", "id": u}, "credits": [{"request_id": f"r{u}"}]} for u in ("42", "43")]
            rep, out = verify_notify.Report(), self.dir / "audit.csv"
            verify_notify.audit_documents(ps, rep, path=str(out), campaign="retro-past", wrapper="/gate", runner=gate)
            self.assertEqual([p["user"]["professional_id"] for _, p in gate.calls], ["pro-42"])
            self.assertIn("--doc-check", gate.calls[0][0])
            rows = out.read_text().splitlines()
            self.assertIn("43,1,held: no professional id on the account", rows)
            self.assertIn("42,1,no_docs", rows)
            self.assertEqual(rep.no_professional_id, 1)
        finally:
            verify_notify.IDENTITY_LOOKUP = saved

    def test_send_all_attaches_the_professional_id_and_holds_accounts_without_one(self):
        seen = []

        def lookup(ids):
            seen.append(sorted(ids))
            return {"42": {"professional_id": "pro-42", "auth_id": "sub-42"}, "43": {"professional_id": "", "auth_id": ""}}

        saved = verify_notify.IDENTITY_LOOKUP
        verify_notify.IDENTITY_LOOKUP = lookup
        try:
            ps = [{"user": {"email": f"{u}@x.com", "id": u}, "credits": [{"request_id": f"r{u}"}]} for u in ("42", "43")]
            ps.append({"user": {"email": "owner@x.com", "id": ""}, "credits": [{"request_id": "rm"}]})
            rep, gate = verify_notify.Report(), FakeGate()
            verify_notify.send_all(ps, rep, mode="apply", wrapper="/gate", runner=gate)
            self.assertEqual(seen, [["42", "43"]])
            self.assertEqual([p["user"].get("professional_id") for _, p in gate.calls], ["pro-42", None])
            self.assertEqual(gate.calls[0][1]["user"]["auth_id"], "sub-42")
            self.assertEqual(rep.no_professional_id, 1)
            self.assertIn("no professional id on the account", rep.render("apply"))

            def down(ids):
                raise RuntimeError("trino down")
            verify_notify.IDENTITY_LOOKUP = down
            rep, gate = verify_notify.Report(), FakeGate()
            verify_notify.send_all(ps, rep, mode="apply", wrapper="/gate", runner=gate)
            self.assertEqual(gate.calls, [])
            self.assertIn("professional ids cannot be read", rep.halted)
        finally:
            verify_notify.IDENTITY_LOOKUP = saved

    def test_a_send_after_the_recheck_clears_the_refusal(self):
        db = verify_ledger.connect(self.ledger)
        verify_ledger.refuse(db, campaign="status-doc-received", user_key="a@x.com", day="2026-10-20", request_ids=["s1"],
                             message_type="email", approved_by="U7RP6HKUZ", approval_ref="ref", reason="no", user_id="7",
                             now=FIXED)
        self.assertIn("until", verify_ledger.refusal_hold(db, "status-doc-received", "a@x.com", FIXED + timedelta(days=6)))
        held = verify_ledger.claim(db, campaign="status-doc-received", user_key="a@x.com", day="2026-10-26", request_ids=["s9"],
                                   message_type="email", approved_by="U7RP6HKUZ", approval_ref="ref",
                                   now=FIXED + timedelta(days=6))
        self.assertEqual(held["result"], "refusal_hold")
        later = FIXED + timedelta(days=8)
        c = verify_ledger.claim(db, campaign="status-doc-received", user_key="a@x.com", day="2026-10-28", request_ids=["s1"],
                                message_type="email", approved_by="U7RP6HKUZ", approval_ref="ref", now=later)
        self.assertEqual(c["result"], "claimed")
        verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id="1", now=later)
        self.assertEqual(db.execute("SELECT COUNT(*) FROM verify_refusal_holds").fetchone()[0], 0)
        self.assertEqual(verify_ledger.refusal_hold(db, "status-doc-received", "a@x.com", later), {})
        self.assertEqual(verify_ledger.refusals_to_flag(db, verify_ledger.RECHECKABLE_REFUSALS), [])
        db.close()

    def test_gate_calls_are_bounded_when_everyone_is_deferred(self):
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in range(1, 21)]
        self.write_list()
        gate = RecentGate({str(u) for u in range(1, 21)})
        rep, _ = self.run_(max_users=2, gate=gate, query=replica(range(1, 21)))
        self.assertEqual(len(gate.calls), 2 * uvn_status.MAX_CALLS_PER_USER)
        self.assertEqual((rep.users, rep.sent_notes, rep.deferred_users), (0, 0, 10))

    def test_paid_segment_sends_still_waiting_requests_most_popular_first(self):
        rep, gate = self.run_()
        self.assertEqual(len(gate.calls), 1)  # user 4's request is no longer UVN
        argv, payload = gate.calls[0]
        self.assertIn("uvn-status", argv)
        self.assertEqual(payload["user"], {"email": "a@x.com", "id": "1", "first_name": "Ann",
                                           "professional_id": "6f1c2a9e-0b7d-4c3e-9a51-000000000001",
                                           "auth_id": "6f1c2a9e-0b7d-4c3e-9a51-000000000001"})
        self.assertEqual([c["track_title"] for c in payload["credits"]], ["High", "Low"])
        self.assertEqual(payload["credits"][0]["role"], "Mixing, Mastering")
        self.assertEqual((rep.sent_notes, rep.no_longer_uvn), (1, 1))

    def test_skip_rows_and_the_other_segment_are_never_offered(self):
        _, gate = self.run_(segment="free")
        self.assertEqual(gate.calls, [])

    def test_documents_on_file_are_never_asked_and_unknown_proof_sends_nothing(self):
        proof(self.proof, [{"user_id": 1, "request_id": None, "kind": "pending_doc", "source": "intercom", "ref": "x"}])
        rep, gate = self.run_()
        self.assertEqual([p["user"]["id"] for _, p in gate.calls], [])
        self.assertEqual(rep.proof_on_file, 1)
        self.proof.write_text("{}")
        rep, gate = self.run_()
        self.assertTrue(rep.halted)
        self.assertEqual(gate.calls, [])

    def test_status_notes_go_to_documented_users_with_their_own_campaign_and_no_ask_cap(self):
        proof(self.proof, [{"user_id": 1, "request_id": None, "kind": "pending_doc", "source": "intercom", "ref": "x"}])
        for campaign in ("status-doc-received", "status-team-review"):
            rep, gate = self.run_(campaign=campaign)
            self.assertEqual([p["user"]["id"] for _, p in gate.calls], ["1"], campaign)
            self.assertIn(campaign, gate.calls[0][0])
            self.assertEqual(rep.proof_on_file, 0)
        # an unreadable proof list does not stop a no-ask status note (it is not an ask)
        self.proof.write_text("{}")
        rep, gate = self.run_(campaign="status-doc-received")
        self.assertFalse(rep.halted)
        with self.assertRaises(ValueError):
            self.run_(campaign="retro-past")

    def test_each_campaign_rechecks_its_own_pending_statuses_and_status_notes_never_close(self):
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in (1, 2, 3)]
        self.write_list()
        q = replica((1, 2, 3), status={1: "processing", 2: "user_verification_needed", 3: "approved"})
        rep, gate = self.run_(query=q)
        self.assertEqual([p["user"]["id"] for _, p in gate.calls], ["2"])
        self.assertEqual((rep.no_longer_uvn, rep.not_pending), (2, 0))
        for campaign in ("status-doc-received", "status-team-review"):
            for _ in range(2):
                rep, gate = self.run_(campaign=campaign, query=q)
                self.assertEqual([p["user"]["id"] for _, p in gate.calls], ["1", "2"], campaign)
                self.assertEqual((rep.not_pending, rep.no_longer_uvn, rep.already_handled), (1, 0, 0), campaign)
                self.assertIn("no request still pending", uvn_status.render(rep, "apply", "paid"))
            db = verify_ledger.connect(self.ledger)
            try:
                self.assertEqual(verify_ledger.blocked_ids(db, ["r3"], campaign), set())
            finally:
                db.close()

    def test_a_stale_list_sends_nothing(self):
        self.write_list(age_h=31)
        rep, gate = self.run_()
        self.assertIn("re-run build.py", rep.halted)
        self.assertEqual(gate.calls, [])

    def test_canary_and_daily_cap(self):
        rep, gate = self.run_(max_users=1)
        self.assertEqual(len(gate.calls), 1)
        db = verify_ledger.connect(self.ledger)
        for i in range(uvn_status.DAILY_MAX):
            c = verify_ledger.claim(db, campaign="uvn-status", user_key=f"u{i}@x.com", day=NOW.strftime("%Y-%m-%d"),
                                    request_ids=[f"x{i}"], message_type="email", approved_by="U7RP6HKUZ",
                                    approval_ref="ref", now=NOW)
            verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id=str(i))
        db.close()
        rep, gate = self.run_()
        self.assertEqual(gate.calls, [])
        self.assertGreater(rep.over_daily_max, 0)

    def test_dry_run_preview_writes_one_file_per_user_named_by_user_id(self):
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in (1, 2, 3)]
        self.write_list()

        class Renders(FakeGate):
            def __call__(self, argv):
                super().__call__(argv)
                uid = self.calls[-1][1]["user"]["id"]
                return subprocess.CompletedProcess(argv, 0, f"DRY-RUN uvn-status initial email credits=1\nnote for {uid}\n", "")
        prev = self.dir / "preview"
        prev.mkdir()
        rep, gate = self.run_(mode="dry-run", gate=Renders(), query=replica((1, 2, 3)), preview_dir=str(prev))
        self.assertTrue(all("--dry-run" in a for a, _ in gate.calls))
        self.assertEqual(sorted(f for f in os.listdir(prev) if f.endswith(".txt")), ["1.txt", "2.txt", "3.txt"])
        self.assertEqual([(prev / f"{u}.txt").read_text().splitlines()[1] for u in (1, 2, 3)],
                         ["note for 1", "note for 2", "note for 3"])
        self.assertEqual(rep.validated, 3)

    def test_the_preview_renders_exactly_the_checks_accepted_set_past_ten_deferred_users(self):
        # t01b 584 (C page 6 on e4f65c4a): the 60-render preview hit its cap on users the check DEFERRED, so the last 3
        # accepted ids had no body. With --preview-accepted the preview renders the accepted set, whatever precedes it.
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in range(1, 16)]
        self.write_list()

        class Renders(FakeGate):
            def __call__(self, argv):
                super().__call__(argv)
                uid = self.calls[-1][1]["user"]["id"]
                return subprocess.CompletedProcess(argv, 0, f"DRY-RUN uvn-status initial email credits=1\nnote for {uid}\n", "")
        accepted = {"11", "12", "13", "14", "15"}                 # users 1-10 were deferred by the check
        prev = self.dir / "preview-acc"
        prev.mkdir()
        with unittest.mock.patch.object(uvn_status.verify_notify, "PREVIEW_ONLY", frozenset(accepted)):
            rep, gate = self.run_(mode="dry-run", gate=Renders(), query=replica(range(1, 16)), preview_dir=str(prev),
                                  max_users=15)
        self.assertEqual({f[:-4] for f in os.listdir(prev) if f.endswith(".txt")}, accepted)
        self.assertEqual({str(p["user"]["id"]) for _, p in gate.calls}, accepted)     # no render for a deferred user
        # without it, a run sized to the accepted count renders deferred users and misses accepted ones (the bug)
        prev2 = self.dir / "preview-cap"
        prev2.mkdir()
        rep, gate = self.run_(mode="dry-run", gate=Renders(), query=replica(range(1, 16)), preview_dir=str(prev2),
                              max_users=5)
        self.assertNotEqual({f[:-4] for f in os.listdir(prev2) if f.endswith(".txt")}, accepted)
    def test_a_check_walks_one_page_of_list_entries_in_parallel_and_accepts_the_list_order_prefix(self):
        # p1 599 / r5 598 (the 10:00Z check walked the whole 4,172-user list one gate call at a time for an hour):
        # --max-entries pages the WALK by list entries; the dry run's gate calls run on the parallel check workers;
        # the accepted set is the list-order prefix up to the run size (what the apply would send)
        import threading, time
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in range(1, 16)]
        self.write_list()

        class Checks(FakeGate):
            def __init__(self):
                super().__init__()
                self.live, self.peak, self.mu = 0, 0, threading.Lock()

            def __call__(self, argv):
                with self.mu:
                    self.live += 1
                    self.peak = max(self.peak, self.live)
                time.sleep(0.05)
                payload = json.loads(Path(argv[argv.index("--credits-file") + 1]).read_text())
                with self.mu:
                    self.live -= 1
                    self.calls.append((argv, payload))
                uid = int(payload["user"]["id"])
                if uid in (1, 2, 3):                                  # the gate defers the first three
                    return subprocess.CompletedProcess(argv, 1, "DEFERRED messaged_7d", "")
                return subprocess.CompletedProcess(argv, 0, "RECIPIENT OK uvn-status initial email credits=1", "")
        g = Checks()
        rep, _ = self.run_(mode="dry-run", gate=g, query=replica(range(1, 16)), check_recipients=True, max_users=4,
                           max_entries=10)
        self.assertEqual([a["user"] for a in rep.accepted], ["4", "5", "6", "7"])     # list order, the run's size
        self.assertGreater(g.peak, 1)                                                  # parallel check workers
        walked = {int(p["user"]["id"]) for _, p in g.calls}
        self.assertTrue(walked <= set(range(1, 11)), walked)                          # never past the 10-entry page
        g2 = Checks()
        rep, _ = self.run_(mode="dry-run", gate=g2, query=replica(range(1, 16)), check_recipients=True, max_users=100,
                           max_entries=5)
        self.assertEqual({int(p["user"]["id"]) for _, p in g2.calls}, {1, 2, 3, 4, 5})
        self.assertEqual(([a["user"] for a in rep.accepted], rep.not_walked), (["4", "5"], 10))

    def test_a_signed_paged_apply_reaches_the_signed_user_past_a_prefix_of_unsigned_ones(self):
        # QA #1611: the signed set is applied BEFORE the run-size slice - users 1-4 unsigned, 5 signed, --max-users 1
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in range(1, 6)]
        self.write_list()
        import unittest.mock
        with unittest.mock.patch.object(uvn_status.verify_notify, "APPLY_ONLY", frozenset({"5"})):
            rep, gate = self.run_(mode="apply", query=replica(range(1, 6)), max_users=1)
        self.assertEqual([p["user"]["id"] for _, p in gate.calls], ["5"])
        self.assertEqual(sorted(o["user"] for o in rep.outcomes if o["reason"] == "not_in_signed_accepted"),
                         ["1", "2", "3", "4"])

    def test_successive_pages_reach_past_a_page_of_persistent_deferrals(self):
        # QA #1612 (1): the first 5 entries are deferred on every run; the caller advances start_entry from report.page,
        # so the next run walks entries 6-10 and accepts there - candidate 6 is never starved
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in range(1, 11)]
        self.write_list()

        class Checks(FakeGate):
            def __call__(self, argv):
                super().__call__(argv)
                uid = int(self.calls[-1][1]["user"]["id"])
                return subprocess.CompletedProcess(argv, 0 if uid > 5 else 1,
                                                   "RECIPIENT OK c" if uid > 5 else "DEFERRED messaged_7d", "")
        rep, _ = self.run_(mode="dry-run", gate=Checks(), query=replica(range(1, 11)), check_recipients=True,
                           max_users=3, max_entries=5)
        self.assertEqual((rep.accepted, rep.page), ([], {"start": 0, "end": 5, "listed": 10, "page_end": 5}))
        rep, g = self.run_(mode="dry-run", gate=Checks(), query=replica(range(1, 11)), check_recipients=True,
                           max_users=3, max_entries=5, start_entry=rep.page["end"])
        self.assertEqual([a["user"] for a in rep.accepted], ["6", "7", "8"])
        self.assertTrue({int(p["user"]["id"]) for _, p in g.calls} <= set(range(6, 11)))
        # QA #1612 (round 2): the cap (3) was reached at entry 8 - page.end is the first entry NOT got to (9), not the
        # page's end (10): the next run starts there, so entries 9-10 are never skipped
        self.assertEqual(rep.page, {"start": 5, "end": 8, "listed": 10, "page_end": 10})
        rep, g = self.run_(mode="dry-run", gate=Checks(), query=replica(range(1, 11)), check_recipients=True,
                           max_users=3, max_entries=5, start_entry=rep.page["end"])
        self.assertEqual([a["user"] for a in rep.accepted], ["9", "10"])

    def test_the_status_team_review_preflight_reads_only_the_page(self):
        # QA #1612 (2): the proof_required preflight runs per user - only the page's users are read
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in range(1, 11)]
        self.write_list()
        import unittest.mock
        from credit_review import comm_state
        read = []
        with unittest.mock.patch.object(comm_state, "proof_required_owed", lambda uid, q: read.append(uid) or []):
            self.run_(mode="dry-run", campaign="status-team-review", query=replica(range(1, 11)), max_users=3,
                      max_entries=4, start_entry=2)
        self.assertEqual(read, [3, 4, 5, 6])

    def test_the_shared_cap_counts_every_credit_campaign_and_an_unreadable_policy_refuses(self):
        # QA #1617 (Critical): 3 status-doc-received sends today use the SAME budget as the ask (cap 4 -> 1 left)
        import unittest.mock
        db = verify_ledger.connect(self.ledger)
        for k in range(3):
            c = verify_ledger.claim(db, campaign="status-doc-received", user_key=f"s{k}@x.com", day=NOW.strftime("%Y-%m-%d"),
                                    request_ids=[f"s{k}"], message_type="email", approved_by="U", approval_ref="r",
                                    now=NOW, user_id=str(90 + k))
            verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id=f"8{k}")
        db.close()
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in range(1, 4)]
        self.write_list()
        with unittest.mock.patch.object(uvn_status, "DAILY_MAX", 4):
            rep, gate = self.run_(mode="apply", query=replica(range(1, 4)), max_users=5, gate=LedgerGate(self.ledger))
        self.assertEqual(len(gate.calls), 1)
        # QA #1617: a missing / malformed policy is a refusal (the CLI exits 2), never a silent 0-cap run
        with unittest.mock.patch.object(uvn_status, "POLICY_OK", False):
            rep, gate = self.run_(mode="apply", query=replica(range(1, 4)))
        self.assertEqual((gate.calls, rep.policy_error), ([], True))
        self.assertIn("cap_policy_unreadable", rep.halted)

    def test_a_signed_apply_short_of_cap_room_refuses_whole_and_a_cap_stop_balances_its_outcomes(self):
        # [key=uvn-daily-cap-400] (C p10: 5 of 53 sent, rc 0): whole or not at all before the first send; a paged / unsigned
        # run that the cap stops writes daily_cap for every user it left
        import unittest.mock
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in range(1, 6)]
        self.write_list()
        with unittest.mock.patch.object(uvn_status, "DAILY_MAX", 3), \
                unittest.mock.patch.object(uvn_status.verify_notify, "APPLY_ONLY", frozenset({"1", "2", "3", "4", "5"})), \
                unittest.mock.patch.object(uvn_status.verify_notify, "APPLY_PAGE", False):
            rep, gate = self.run_(mode="apply", query=replica(range(1, 6)), max_users=5)
        self.assertEqual((rep.cap_short, gate.calls), (True, []))
        self.assertIn("daily_cap_short: 3 left", rep.halted)
        self.assertEqual(sorted(o["user"] for o in rep.outcomes if o["reason"] == "daily_cap_short"), ["1", "2", "3", "4", "5"])
        # the tick's paged apply (or an unsigned run): sends what the cap takes, and every left user is a daily_cap row
        Path(self.ledger).unlink(missing_ok=True)
        with unittest.mock.patch.object(uvn_status, "DAILY_MAX", 3), \
                unittest.mock.patch.object(uvn_status.verify_notify, "APPLY_ONLY", frozenset({"1", "2", "3", "4", "5"})), \
                unittest.mock.patch.object(uvn_status.verify_notify, "APPLY_PAGE", True):
            rep, gate = self.run_(mode="apply", query=replica(range(1, 6)), max_users=5, gate=LedgerGate(self.ledger))
        self.assertEqual((rep.cap_short, len(gate.calls)), (False, 3))
        self.assertEqual(sorted(o["user"] for o in rep.outcomes if o["reason"] == "daily_cap"), ["4", "5"])
        # another sender takes the cap MID-batch (two more sends land while user 1 posts): the batch's rest are rows too
        Path(self.ledger).unlink(missing_ok=True)
        ledger = self.ledger

        class Busy(LedgerGate):
            def __call__(self, argv):
                res = super().__call__(argv)
                if len(self.calls) == 1:
                    db = verify_ledger.connect(ledger)
                    for k in (91, 92):
                        c = verify_ledger.claim(db, campaign="uvn-status", user_key=f"o{k}@x.com", day=NOW.strftime("%Y-%m-%d"),
                                                request_ids=[f"o{k}"], message_type="email", approved_by="U",
                                                approval_ref="r", now=NOW, user_id=str(k))
                        verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id=f"9{k}")
                    db.close()
                return res
        with unittest.mock.patch.object(uvn_status, "DAILY_MAX", 3), \
                unittest.mock.patch.object(uvn_status.verify_notify, "APPLY_ONLY", None):
            rep, gate = self.run_(mode="apply", query=replica(range(1, 6)), max_users=5, gate=Busy(self.ledger))
        self.assertEqual(len(gate.calls), 1)
        self.assertEqual(sorted(o["user"] for o in rep.outcomes if o["reason"] == "daily_cap"), ["2", "3", "4", "5"])

    def test_dry_run_validates_without_sending(self):
        _, gate = self.run_(mode="dry-run")
        self.assertIn("--validate", gate.calls[0][0])

    def test_a_dry_run_reports_the_gates_valid_answers_as_validated_not_skipped(self):
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in range(1, 4)]
        self.write_list()
        gate = FakeGate(out="VALID uvn-status initial email credits=1 copy=default")
        rep, _ = self.run_(mode="dry-run", gate=gate, query=replica(range(1, 4)))
        self.assertEqual((rep.validated, rep.skipped, rep.users), (3, 0, 3))
        text = uvn_status.render(rep, "dry-run", "paid")
        self.assertIn("3 validated (the gate would send)", text)
        self.assertNotIn("skipped by the gate", text)
        applied = uvn_status.UvnReport(skipped=2)
        self.assertIn("2 skipped by the gate", uvn_status.render(applied, "apply", "paid"))
        self.assertNotIn("validated", uvn_status.render(applied, "apply", "paid"))

    def test_a_user_asked_by_verify_live_eight_days_ago_is_deferred_as_asked_in_90_days(self):
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in range(1, 3)]
        self.write_list()
        db = verify_ledger.connect(self.ledger)
        try:
            c = verify_ledger.claim(db, campaign="verify-live", user_key="old1@x.com",
                                    day=(NOW - timedelta(days=8)).strftime("%Y-%m-%d"), request_ids=["v1"],
                                    message_type="email", approved_by="U7RP6HKUZ", approval_ref="ref",
                                    now=NOW - timedelta(days=8), user_id="1")
            verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id="1")
        finally:
            db.close()
        rep, gate = self.run_(query=replica(range(1, 3)))
        self.assertEqual([p["user"]["id"] for _, p in gate.calls], ["2"])
        self.assertEqual((rep.recently_asked, rep.deferred_users, rep.already_handled), (1, 0, 0))
        text = uvn_status.render(rep, "apply", "paid")
        self.assertIn("1 deferred (asked in the last 90 days)", text)
        self.assertNotIn("messaged in the last 7 days", text)
        db = verify_ledger.connect(self.ledger)
        try:
            self.assertEqual(verify_ledger.blocked_ids(db, ["r1"], "uvn-status"), set())
        finally:
            db.close()

    def test_repeated_runs_reach_new_users_instead_of_stalling_on_handled_ones(self):
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in range(1, 8)]
        self.write_list()
        gate = LedgerGate(self.ledger)
        q = replica(range(1, 8))
        rep1, _ = self.run_(max_users=3, gate=gate, query=q)
        rep2, _ = self.run_(max_users=3, gate=gate, query=q)
        rep3, _ = self.run_(max_users=3, gate=gate, query=q)
        sent = [p["user"]["id"] for _, p in gate.calls]
        self.assertEqual(sent, ["1", "2", "3", "4", "5", "6", "7"])
        self.assertEqual((rep1.sent_notes, rep2.sent_notes, rep3.sent_notes), (3, 3, 1))
        self.assertEqual((rep2.already_handled, rep3.already_handled), (3, 6))
        self.assertEqual((rep1.over_daily_max, rep3.over_daily_max), (4, 0))

    def test_users_done_by_email_are_closed_and_never_take_budget(self):
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in (1, 2)]
        self.write_list()
        db = verify_ledger.connect(self.ledger)
        c = verify_ledger.claim(db, campaign="uvn-status", user_key="u1@x.com", day="2026-01-01", request_ids=["old"],
                                message_type="email", approved_by="U7RP6HKUZ", approval_ref="ref",
                                now=datetime(2026, 1, 1, tzinfo=timezone.utc))
        verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id="1")
        db.close()
        gate = LedgerGate(self.ledger)
        rep, _ = self.run_(max_users=1, gate=gate, query=replica((1, 2)))
        self.assertEqual([p["user"]["id"] for _, p in gate.calls], ["2"])
        self.assertEqual(rep.by_reason.get("already_sent"), 1)
        db = verify_ledger.connect(self.ledger)
        self.assertEqual(verify_ledger.blocked_ids(db, ["r1"], "uvn-status"), {"r1"})
        db.close()

    def test_a_request_missing_its_title_is_held_not_closed_and_sent_once_repaired(self):
        self.users = [{"user_id": 1, "paid": True, "skip": None, "request_ids": ["r1"]}]
        self.write_list()
        gate = LedgerGate(self.ledger)
        rep, _ = self.run_(gate=gate, query=replica((1,), rows={"r1": {"title": "  "}}))
        self.assertEqual(gate.calls, [])
        self.assertEqual((rep.incomplete, rep.no_longer_uvn, rep.already_handled), (1, 0, 0))
        self.assertIn("blank or unshowable title, artist or role", uvn_status.render(rep, "apply", "paid"))
        db = verify_ledger.connect(self.ledger)
        self.assertEqual(verify_ledger.blocked_ids(db, ["r1"], "uvn-status"), set())
        db.close()
        rep, _ = self.run_(gate=gate, query=replica((1,)))
        self.assertEqual([(p["user"]["id"], [c["track_title"] for c in p["credits"]]) for _, p in gate.calls],
                         [("1", ["Song r1"])])
        self.assertEqual(rep.sent_notes, 1)

    def test_a_blank_or_unshowable_request_is_left_out_and_the_rest_of_the_note_goes(self):
        """firstmate 166 (2026-10-23): hold the bad row, send the rest. One bad row used to make the
        gate refuse the whole note; the left-out request stays pending in core."""
        self.users = [{"user_id": 1, "paid": True, "skip": None, "request_ids": ["r1", "r2", "r3"]}]
        self.write_list()
        gate = LedgerGate(self.ledger)
        rows = {"r2": {"title": ""}, "r3": {"title": "x" * 201}}
        rep, _ = self.run_(gate=gate, query=replica((1,), requests={1: ["r1", "r2", "r3"]}, rows=rows))
        self.assertEqual([[c["request_id"] for c in p["credits"]] for _, p in gate.calls], [["r1"]])
        self.assertEqual((rep.incomplete, rep.rows_held, rep.sent_notes), (0, 2, 1))
        self.assertIn("2 request(s) left out of a note", uvn_status.render(rep, "apply", "paid"))
        db = verify_ledger.connect(self.ledger)
        self.assertEqual(verify_ledger.blocked_ids(db, ["r2", "r3"], "uvn-status"), set())   # still open
        db.close()
        # firstmate 169: one note per user, ever. A later run records the left-out requests as
        # skipped in this campaign's ledger and sends nothing more.
        rep, _ = self.run_(gate=gate, query=replica((1,), requests={1: ["r1", "r2", "r3"]}, rows=rows))
        self.assertEqual(len(gate.calls), 1)
        self.assertEqual((rep.sent_notes, rep.rows_held, rep.by_reason.get("already_sent")), (0, 0, 1))
        db = verify_ledger.connect(self.ledger)
        self.assertEqual(verify_ledger.blocked_ids(db, ["r2", "r3"], "uvn-status"), {"r2", "r3"})
        db.close()

    def test_a_dry_run_counts_the_requests_it_would_leave_out(self):
        self.users = [{"user_id": 1, "paid": True, "skip": None, "request_ids": ["r1", "r2"]}]
        self.write_list()
        gate = FakeGate(out="VALID uvn-status initial email credits=1 copy=default")
        rep, _ = self.run_(mode="dry-run", gate=gate,
                           query=replica((1,), requests={1: ["r1", "r2"]}, rows={"r2": {"title": ""}}))
        self.assertEqual([[c["request_id"] for c in p["credits"]] for _, p in gate.calls], [["r1"]])
        self.assertEqual((rep.validated, rep.rows_held, rep.incomplete), (1, 1, 0))
        self.assertIn("1 request(s) left out of a note", uvn_status.render(rep, "dry-run", "paid"))

    def test_left_out_requests_are_not_counted_when_the_gate_does_not_send(self):
        self.users = [{"user_id": 1, "paid": True, "skip": None, "request_ids": ["r1", "r2"]}]
        self.write_list()
        q = replica((1,), requests={1: ["r1", "r2"]}, rows={"r2": {"title": ""}})
        for gate in (RecentGate({"1"}), RefusingGate({"1"}), FakeGate(out="SKIPPED already-notified credits=1")):
            rep, _ = self.run_(gate=gate, query=q)
            self.assertEqual(len(gate.calls), 1, type(gate).__name__)
            self.assertEqual((rep.sent_notes, rep.rows_held), (0, 0), type(gate).__name__)
            self.assertNotIn("left out of a note", uvn_status.render(rep, "apply", "paid"))

    def test_gate_shape_caps_mark_a_row_unshowable(self):
        f = uvn_status._row_incomplete
        self.assertFalse(f("Song", "Art", "Mixing", "p-1", "t-1"))
        for args in (("", "Art", "Mixing", "", ""), ("Song", "Art", "x" * 121, "", ""), ("x" * 201, "Art", "Mixing", "", ""),
                     ("Song", "x" * 201, "Mixing", "", ""), ("Song", "Art", "Mixing", "bad id!", ""),
                     ("Song", "Art", "Mixing", "", "t/1")):
            self.assertTrue(f(*args), args)

    def test_the_caps_are_measured_after_the_gates_clean_step(self):
        f = uvn_status._row_incomplete
        self.assertFalse(f("a  " * 66 + "abc", "Art", "Mixing", "", ""))   # 201 raw, 135 once collapsed
        self.assertFalse(f("Song\t\n", "Art", "Mixing", "\x00p-1", ""))
        self.assertTrue(f("\x00\x07", "Art", "Mixing", "", ""))           # blank once cleaned
        self.assertTrue(f("Song", "Art", "\x1b", "", ""))

    def test_a_user_whose_only_askable_request_is_unshowable_is_held_as_incomplete(self):
        self.users = [{"user_id": 1, "paid": True, "skip": None, "request_ids": ["r1", "r2"]}]
        self.write_list()
        gate = LedgerGate(self.ledger)
        rep, _ = self.run_(gate=gate, query=replica((1,), requests={1: ["r1", "r2"]}, rows={"r2": {"title": ""}},
                                                    verification={"r1": {"duplicate_of": "cr-9"}}))
        self.assertEqual(gate.calls, [])
        self.assertEqual((rep.incomplete, rep.rows_held, rep.no_longer_uvn), (1, 0, 0))
        self.assertIn("1 held: every pending request has a blank or unshowable", uvn_status.render(rep, "apply", "paid"))
        db = verify_ledger.connect(self.ledger)
        self.assertEqual(verify_ledger.blocked_ids(db, ["r1", "r2"], "uvn-status"), set())
        db.close()

    def test_a_no_ask_request_that_is_blank_is_not_counted_as_left_out(self):
        self.users = [{"user_id": 1, "paid": True, "skip": None, "request_ids": ["r1", "r2"]}]
        self.write_list()
        gate = LedgerGate(self.ledger)
        rep, _ = self.run_(gate=gate, query=replica((1,), requests={1: ["r1", "r2"]}, rows={"r2": {"title": ""}},
                                                    verification={"r2": {"duplicate_of": "cr-9"}}))
        self.assertEqual([[c["request_id"] for c in p["credits"]] for _, p in gate.calls], [["r1"]])
        self.assertEqual((rep.sent_notes, rep.rows_held, rep.incomplete), (1, 0, 0))

    def test_a_request_opened_after_the_list_was_built_holds_the_user_until_the_list_names_it(self):
        # QA @3258c41: the list names r1 (A); the user then opened r2 (B). Sending about A alone
        # would use their one-ever note, and B would never be mentioned.
        self.users = [{"user_id": 1, "paid": True, "skip": None, "request_ids": ["r1"]}]
        self.write_list()
        gate = LedgerGate(self.ledger)
        q = replica((1,), requests={1: ["r1", "r2"]})
        rep, _ = self.run_(gate=gate, query=q)
        self.assertEqual(gate.calls, [])
        self.assertEqual((rep.unlisted, rep.sent_notes, rep.no_longer_uvn), (1, 0, 0))
        self.assertIn("1 held: a request waiting on them is not on the list yet", uvn_status.render(rep, "apply", "paid"))
        db = verify_ledger.connect(self.ledger)
        self.assertEqual(verify_ledger.blocked_ids(db, ["r1", "r2"], "uvn-status"), set())
        db.close()
        # the rebuilt list names both: one note covering A and B
        self.users = [{"user_id": 1, "paid": True, "skip": None, "request_ids": ["r1", "r2"]}]
        self.write_list()
        rep, _ = self.run_(gate=gate, query=q)
        self.assertEqual([sorted(c["request_id"] for c in p["credits"]) for _, p in gate.calls], [["r1", "r2"]])
        self.assertEqual((rep.unlisted, rep.sent_notes), (0, 1))

    def _changes_after_the_batch(self, change, **kw):
        """A replica fake that applies `change()` right after its first credit_requests read (the
        batch), so only the read right before the send sees it."""
        base, reads = replica((1,), **kw), []

        def q(sql):
            out = base(sql)
            # one PASS = the primary (UVN) read; its [key=k-proof-required] companion read is part of the same pass
            if "credit_requests" in sql and "'user_verification_needed'" in sql:
                reads.append(sql)
                if len(reads) == 1:
                    change()
            return out
        return q, reads

    def test_a_request_opened_between_the_batch_and_the_send_holds_the_user(self):
        # QA @1f59d68: the list names r1 (A) and the batch is built with A only; the user opens
        # r2 (B) before A's send. A must not use their one-ever note without B.
        self.users = [{"user_id": 1, "paid": True, "skip": None, "request_ids": ["r1"]}]
        self.write_list()
        requests = {1: ["r1"]}
        q, reads = self._changes_after_the_batch(lambda: requests.update({1: ["r1", "r2"]}), requests=requests)
        gate = LedgerGate(self.ledger)
        rep, _ = self.run_(gate=gate, query=q)
        self.assertEqual(len(reads), 2)  # the batch, then the re-read right before the send
        self.assertEqual(gate.calls, [])
        self.assertEqual((rep.unlisted, rep.sent_notes, rep.no_longer_uvn), (1, 0, 0))
        db = verify_ledger.connect(self.ledger)
        self.assertEqual(verify_ledger.blocked_ids(db, ["r1", "r2"], "uvn-status"), set())
        db.close()

    def _proof_changes_after_first_send(self, change):
        gate = LedgerGate(self.ledger)
        send = gate.__call__

        def runner(argv):
            res = send(argv)
            if len(gate.calls) == 1:
                change()
            return res
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in (1, 2)]
        self.write_list()
        rep, _ = self.run_(gate=runner, query=replica((1, 2)))
        return rep, gate

    def test_proof_received_while_earlier_users_are_messaged_is_not_asked_for(self):
        # QA @3384f72: user 2's document reached support@ after the run started; the gate only
        # sees Intercom, so the proof-on-file list must be re-read right before 2's send.
        rep, gate = self._proof_changes_after_first_send(lambda: proof(self.proof, [
            {"user_id": 2, "request_id": None, "kind": "pending_doc", "source": "gmail", "ref": "m"}]))
        self.assertEqual([p["user"]["id"] for _, p in gate.calls], ["1"])
        self.assertEqual((rep.sent_notes, rep.proof_on_file), (1, 1))
        self.assertFalse(rep.halted)

    def test_a_proof_list_that_turns_unreadable_mid_run_stops_the_sends(self):
        rep, gate = self._proof_changes_after_first_send(lambda: self.proof.write_text("{}"))
        self.assertEqual([p["user"]["id"] for _, p in gate.calls], ["1"])
        self.assertTrue(rep.halted)
        self.assertIn("STOPPED after 1 sent", uvn_status.render(rep, "apply", "paid"))

    def test_a_listed_request_blanked_between_the_batch_and_the_send_is_left_out(self):
        self.users = [{"user_id": 1, "paid": True, "skip": None, "request_ids": ["r1", "r2"]}]
        self.write_list()
        rows = {"r1": {"title": "Song r1"}}
        q, _ = self._changes_after_the_batch(lambda: rows.update({"r2": {"title": ""}}),
                                             requests={1: ["r1", "r2"]}, rows=rows)
        gate = LedgerGate(self.ledger)
        rep, _ = self.run_(gate=gate, query=q)
        self.assertEqual([[c["request_id"] for c in p["credits"]] for _, p in gate.calls], [["r1"]])
        self.assertEqual((rep.incomplete, rep.rows_held, rep.sent_notes), (0, 1, 1))

    def test_the_only_askable_request_blanked_before_the_send_holds_the_user_as_incomplete(self):
        self.users = [{"user_id": 1, "paid": True, "skip": None, "request_ids": ["r1", "r2"]}]
        self.write_list()
        rows = {"r1": {"title": "Song r1"}}
        q, reads = self._changes_after_the_batch(lambda: rows.update({"r2": {"title": ""}}),
                                                 requests={1: ["r1", "r2"]}, rows=rows,
                                                 verification={"r1": {"duplicate_of": "cr-9"}})
        gate = LedgerGate(self.ledger)
        rep, _ = self.run_(gate=gate, query=q)
        self.assertEqual(len(reads), 2)
        self.assertEqual(gate.calls, [])
        self.assertEqual((rep.incomplete, rep.no_longer_uvn, rep.sent_notes), (1, 0, 0))

    def test_pg_text_array_odd_shape_leaves_the_request_out_and_sends_the_rest(self):
        self.users = [{"user_id": 1, "paid": True, "skip": None, "request_ids": ["r1", "r2"]}]
        self.write_list()
        gate = LedgerGate(self.ledger)
        from credit_review import runner
        saved_log, saved_flag = runner.log, verify_notify._odd_array_logged
        runner.log, verify_notify._odd_array_logged = [].append, False
        try:
            rep, _ = self.run_(gate=gate, query=replica((1,), requests={1: ["r1", "r2"]},
                                                        rows={"r2": {"role": "[Mixing]"}}))
        finally:
            runner.log, verify_notify._odd_array_logged = saved_log, saved_flag
        self.assertEqual([[c["request_id"] for c in p["credits"]] for _, p in gate.calls], [["r1"]])
        self.assertEqual((rep.sent_notes, rep.rows_held, rep.incomplete), (1, 1, 0))

    def test_an_unlisted_request_we_would_never_ask_about_does_not_hold_the_user(self):
        self.users = [{"user_id": 1, "paid": True, "skip": None, "request_ids": ["r1"]}]
        self.write_list()
        rep, gate = self.run_(query=replica((1,), requests={1: ["r1", "r2"]},
                                            verification={"r2": {"duplicate_of": "cr-9"}}))
        self.assertEqual([[c["request_id"] for c in p["credits"]] for _, p in gate.calls], [["r1"]])
        self.assertEqual(rep.unlisted, 0)

    def test_a_user_whose_email_changed_is_still_done(self):
        # u1 got the reminder under an old address; the replica now says u1@x.com.
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in (1, 2)]
        self.write_list()
        db = verify_ledger.connect(self.ledger)
        c = verify_ledger.claim(db, campaign="uvn-status", user_key="old1@x.com", day="2026-01-01", request_ids=["old"],
                                message_type="email", approved_by="U7RP6HKUZ", approval_ref="ref", user_id="1",
                                now=datetime(2026, 1, 1, tzinfo=timezone.utc))
        verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id="1")
        db.close()
        gate = LedgerGate(self.ledger)
        rep, _ = self.run_(max_users=2, gate=gate, query=replica((1, 2)))
        self.assertEqual([p["user"]["id"] for _, p in gate.calls], ["2"])
        self.assertEqual(rep.by_reason.get("already_sent"), 1)


class UvnLedgerTests(unittest.TestCase):
    def test_email_change_does_not_reopen_a_status_campaign(self):
        db = verify_ledger.connect(":memory:")
        for n, campaign in enumerate(sorted(verify_ledger.STATUS_CAMPAIGNS)):
            uid, old, new = str(40 + n), f"old{n}@x.com", f"new{n}@x.com"
            c = verify_ledger.claim(db, campaign=campaign, user_key=old, day="2026-10-01",
                                    request_ids=[f"{campaign}-1"], message_type="email", approved_by="U7RP6HKUZ",
                                    approval_ref="ref", user_id=uid, now=FIXED - timedelta(days=30))
            verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id=f"{campaign}-1")
            # a NEW request under the NEW address, well past the 7-day spacing
            r = verify_ledger.claim(db, campaign=campaign, user_key=new, day="2026-10-20",
                                    request_ids=[f"{campaign}-2"], message_type="email", approved_by="U7RP6HKUZ",
                                    approval_ref="ref", user_id=uid, now=FIXED)
            self.assertEqual((campaign, r["result"], r.get("reason")), (campaign, "user_done", "already_sent"))
            self.assertEqual(verify_ledger.uvn_user_done(db, new, now=FIXED, campaign=campaign,
                                                         user_id=uid), "already_sent")
            # an unrelated account is not this user
            self.assertEqual(verify_ledger.uvn_user_done(db, "other@x.com", now=FIXED, campaign=campaign,
                                                         user_id="99"), "")

    def test_hold_silent_blocks_the_status_notes_for_good_but_not_the_ask(self):
        # Fable ruling 017 (2026-10-27): the 40 users told 'nothing else is needed' while they owe proof.
        db = verify_ledger.connect(":memory:")
        out = verify_ledger.hold_silent(db, user_ids=["42", "43"], reason="owe-proof-told-nothing-needed", now=FIXED)
        self.assertEqual(out, {"held": 4, "already": 0})
        later = FIXED + timedelta(days=400)
        for campaign in verify_ledger.STATUS_NOTE_CAMPAIGNS:
            self.assertEqual(verify_ledger.refusal_hold(db, campaign, "new@x.com", later, "42"), {"flagged": True})
            c = verify_ledger.claim(db, campaign=campaign, user_key="new@x.com", day="2026-12-01", request_ids=["s1"],
                                    message_type="email", approved_by="U7RP6HKUZ", approval_ref="ref", user_id="42",
                                    now=later)
            self.assertEqual(c["result"], "refusal_hold")
        self.assertEqual(verify_ledger.refusal_hold(db, "uvn-status", "new@x.com", later, "42"), {})
        self.assertEqual(verify_ledger.refusal_hold(db, "status-team-review", "x@x.com", later, "44"), {})
        self.assertEqual(verify_ledger.refusals_to_flag(db, verify_ledger.RECHECKABLE_REFUSALS), [])
        self.assertEqual(verify_ledger.hold_silent(db, user_ids=["42"], reason="owe-proof-told-nothing-needed"),
                         {"held": 0, "already": 2})
        reasons = {r[0] for r in db.execute("SELECT reason FROM verify_refusal_holds")}
        self.assertEqual(reasons, {"owe-proof-told-nothing-needed"})
        for bad in (dict(user_ids=["4a"], reason="ok-reason"), dict(user_ids=["1"], reason="Not A Slug"),
                    dict(user_ids=["1"], reason="ok-reason", campaigns=("uvn-status",))):
            with self.assertRaises(ValueError):
                verify_ledger.hold_silent(db, **bad)

    def test_hold_silent_flags_an_existing_refusal_hold_instead_of_adding_one(self):
        db = verify_ledger.connect(":memory:")
        verify_ledger.refuse(db, campaign="status-team-review", user_key="a@x.com", day="2026-10-20",
                             request_ids=["s1"], message_type="email", approved_by="U7RP6HKUZ", approval_ref="ref",
                             reason="no", user_id="42", now=FIXED)
        verify_ledger.hold_silent(db, user_ids=["42"], reason="owe-proof-told-nothing-needed",
                                  campaigns=("status-team-review",), now=FIXED)
        rows = db.execute("SELECT user_key, reason, flagged_at IS NOT NULL FROM verify_refusal_holds").fetchall()
        self.assertEqual([tuple(r) for r in rows], [("a@x.com", "owe-proof-told-nothing-needed", 1)])

    def test_a_refusal_hold_follows_the_user_id_across_an_email_change(self):
        db = verify_ledger.connect(":memory:")
        kw = dict(campaign="status-doc-received", request_ids=["s1"], message_type="email", approved_by="U7RP6HKUZ",
                  approval_ref="ref", reason="no", user_id="42")
        verify_ledger.refuse(db, user_key="old@x.com", day="2026-10-20", now=FIXED, **kw)
        tomorrow = FIXED + timedelta(days=1)
        self.assertIn("until", verify_ledger.refusal_hold(db, "status-doc-received", "new@x.com", tomorrow, "42"))
        self.assertEqual(verify_ledger.refusal_hold(db, "status-doc-received", "new@x.com", tomorrow, "43"), {})
        held = verify_ledger.claim(db, campaign="status-doc-received", user_key="new@x.com", day="2026-10-21",
                                   request_ids=["s1"], message_type="email", approved_by="U7RP6HKUZ",
                                   approval_ref="ref", user_id="42", now=tomorrow)
        self.assertEqual(held["result"], "refusal_hold")
        # the strikes carry on under the new address: the third refusal is flagged, not a fresh first
        for n in (1, 2):
            r = verify_ledger.refuse(db, user_key="new@x.com", day="2026-10-28", now=FIXED + timedelta(days=8 * n), **kw)
            self.assertEqual(r["refusals"], n + 1)
        self.assertEqual([(f["user_id"], f["refusals"]) for f in
                          verify_ledger.refusals_to_flag(db, verify_ledger.RECHECKABLE_REFUSALS)], [("42", 3)])
        # a send after the re-check clears the hold whatever address it was recorded under
        verify_ledger.mark_flagged(db, campaign="status-doc-received", user_key="old@x.com", now=FIXED + timedelta(days=17))
        self.assertEqual(verify_ledger.refusal_hold(db, "status-doc-received", "new@x.com", FIXED + timedelta(days=99), "42"),
                         {"flagged": True})
        db.close()

    def test_a_send_clears_the_refusal_hold_recorded_under_an_old_email(self):
        db = verify_ledger.connect(":memory:")
        verify_ledger.refuse(db, campaign="status-team-review", user_key="old@x.com", day="2026-10-20",
                             request_ids=["s1"], message_type="email", approved_by="U7RP6HKUZ", approval_ref="ref",
                             reason="no", user_id="42", now=FIXED)
        later = FIXED + timedelta(days=8)
        c = verify_ledger.claim(db, campaign="status-team-review", user_key="new@x.com", day="2026-10-28",
                                request_ids=["s1"], message_type="email", approved_by="U7RP6HKUZ", approval_ref="ref",
                                user_id="42", now=later)
        self.assertEqual(c["result"], "claimed")
        self.assertEqual(db.execute("SELECT COUNT(*) FROM verify_refusal_holds").fetchone()[0], 0)
        db.close()

    def test_once_ever_and_seven_days_across_campaigns(self):
        db = verify_ledger.connect(":memory:")
        self.assertEqual(verify_ledger.uvn_user_done(db, "a@x.com", now=FIXED), "")
        c = verify_ledger.claim(db, campaign="retro-past", user_key="a@x.com", day="2026-10-17", request_ids=["p1"],
                                message_type="email", approved_by="U7RP6HKUZ", approval_ref="ref", now=FIXED)
        verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id="9")
        self.assertEqual(verify_ledger.uvn_user_done(db, "a@x.com", now=FIXED), "messaged_7d")
        r = verify_ledger.claim(db, campaign="uvn-status", user_key="a@x.com", day="2026-10-20", request_ids=["u1"],
                                message_type="email", approved_by="U7RP6HKUZ", approval_ref="ref", now=FIXED)
        self.assertEqual(r["result"], "recent")
        # Day 8 after another campaign's ASK: the shared one-ask-per-90-days lock defers it
        # (QA @59645fb), nothing closed; a different credit (u1, never asked) changes nothing.
        later = FIXED + timedelta(days=8)
        self.assertEqual(verify_ledger.uvn_user_done(db, "a@x.com", now=later), "recently_asked")
        r = verify_ledger.claim(db, campaign="uvn-status", user_key="a@x.com", day="2026-10-28", request_ids=["u1"],
                                message_type="email", approved_by="U7RP6HKUZ", approval_ref="ref", now=later)
        self.assertEqual((r["result"], r.get("reason")), ("recent", "recently_asked"))
        self.assertEqual(verify_ledger.blocked_ids(db, ["u1"], "uvn-status"), set())
        # Once the lock lapses the reminder may go, once.
        lapsed = FIXED + timedelta(days=95)
        day = lapsed.strftime("%Y-%m-%d")
        r = verify_ledger.claim(db, campaign="uvn-status", user_key="a@x.com", day=day, request_ids=["u1"],
                                message_type="email", approved_by="U7RP6HKUZ", approval_ref="ref", now=lapsed)
        self.assertEqual(r["result"], "claimed")
        verify_ledger.finalize(db, message_row=r["message_row"], status="sent", message_id="10")
        self.assertEqual(verify_ledger.uvn_user_done(db, "a@x.com", now=lapsed + timedelta(days=30)), "already_sent")

    def test_a_verify_live_ask_eight_days_ago_defers_the_uvn_reminder_by_account_id(self):
        db = verify_ledger.connect(":memory:")
        c = verify_ledger.claim(db, campaign="verify-live", user_key="old@x.com", day="2026-10-12", request_ids=["v1"],
                                message_type="email", approved_by="U7RP6HKUZ", approval_ref="ref", now=FIXED,
                                user_id="42")
        verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id="1")
        # a different credit, a changed email: still the same user, still inside 90 days
        self.assertEqual(verify_ledger.uvn_user_done(db, "new@x.com", now=FIXED, user_id="42"), "recently_asked")
        # status notes are not asks: the lock does not apply to them
        self.assertEqual(verify_ledger.uvn_user_done(db, "new@x.com", now=FIXED, user_id="42",
                                                     campaign="status-team-review"), "")

    def _sent(self, db, campaign, user, rid, day):
        c = verify_ledger.claim(db, campaign=campaign, user_key=user, day=day, request_ids=[rid], message_type="email",
                                approved_by="U7RP6HKUZ", approval_ref="ref", now=FIXED)
        verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id=f"{campaign}-{rid}")

    def _retro(self, db, user, rid, day):
        return verify_ledger.claim(db, campaign="retro-past", user_key=user, day=day, request_ids=[rid],
                                   message_type="email", approved_by="U7RP6HKUZ", approval_ref="ref", now=FIXED)

    def test_notices_and_confirmations_never_close_a_users_asks(self):
        db = verify_ledger.connect(":memory:")
        self._sent(db, "withdrawal-confirm", "a@x.com", "w1", "2026-10-18")
        self._sent(db, "removal-notice", "b@x.com", "ev1", "2026-10-18")
        self._sent(db, "takeback-notice", "c@x.com", "p3", "2026-10-18")
        for user, rid in (("a@x.com", "p1"), ("b@x.com", "p2"), ("c@x.com", "p4")):
            self.assertEqual(verify_ledger.past_user_done(db, user), "")
            self.assertEqual(self._retro(db, user, rid, "2026-10-20")["result"], "claimed")

    def test_status_note_and_email_changed_refusals_are_held_for_a_recheck(self):
        db = verify_ledger.connect(":memory:")
        for campaign in ("status-doc-received", "status-team-review", "email-changed", "email-changed-dup"):
            for days, count in ((0, 1), (3, 1), (7, 2)):
                r = verify_ledger.refuse(db, campaign=campaign, user_key="a@x.com", day="2026-10-20", request_ids=["x1"],
                                         message_type="comment", approved_by="U7RP6HKUZ", approval_ref="ref",
                                         reason="no", now=FIXED + timedelta(days=days))
                self.assertEqual((r["result"], r["refusals"]), ("refused_recheck", count))
            self.assertIn("until", verify_ledger.refusal_hold(db, campaign, "a@x.com", FIXED + timedelta(days=13)))
            self.assertEqual(verify_ledger.refusal_hold(db, campaign, "a@x.com", FIXED + timedelta(days=15)), {})
            self.assertEqual(verify_ledger.refusal_hold(db, campaign, "b@x.com", FIXED + timedelta(days=1)), {})
            self.assertEqual(db.execute("SELECT COUNT(*) FROM verify_messages").fetchone()[0], 0)
        verify_ledger.refuse(db, campaign="withdrawal-confirm", user_key="a@x.com", day="2026-10-20",
                             request_ids=["w1"], message_type="comment", approved_by="U7RP6HKUZ",
                             approval_ref="ref", reason="no", now=FIXED)
        self.assertEqual(verify_ledger.blocked_ids(db, ["w1"], "withdrawal-confirm"), {"w1"})

    def test_an_earlier_ask_still_closes_a_users_retro_ask(self):
        db = verify_ledger.connect(":memory:")
        self._sent(db, "retro-past", "a@x.com", "p1", "2026-10-18")
        self._sent(db, "uvn-status", "b@x.com", "u1", "2026-10-18")
        for user in ("a@x.com", "b@x.com"):
            self.assertEqual(verify_ledger.past_user_done(db, user), "already_asked")
            r = self._retro(db, user, "p9" + user[0], "2026-10-20")
            self.assertEqual((r["result"], r.get("reason")), ("user_done", "already_asked"))


class ReplicaShapeTests(unittest.TestCase):
    def test_uvn_requests_parses_the_credits_literal_and_never_casts_it(self):
        seen = []

        def q(sql):
            seen.append(sql)
            return [["r1", "7", "p", "t", "Song", '[{"name":"Art"}]', '{"Record Label"}', "12", "{}", "{}"],
                    ["r2", "7", "p", "t", "Other", '[{"name":"Art"}]', '{Mixing,Mastering}', "40", "{}", "{}"]]
        got = uvn_status.uvn_requests([7], q)
        self.assertNotIn("array(varchar)", seen[0])
        self.assertEqual(sorted(r["role"] for r in got[7]), ["Mixing, Mastering", "Record Label"])
        self.assertFalse(any(r["_incomplete"] for r in got[7]))

    def test_pg_text_array(self):
        f = verify_notify.pg_text_array
        self.assertEqual(f('{"Record Label"}'), "Record Label")
        self.assertEqual(f('{Mixing,"Mastering Engineer"}'), "Mixing, Mastering Engineer")
        self.assertEqual(f("{}"), "")
        self.assertEqual(f(None), "")
        self.assertEqual(f('{"Mixing, Mastering",NULL,""}'), "Mixing, Mastering")
        self.assertEqual(f('{"say \\"hi\\""}'), 'say "hi"')

    def test_any_other_shape_is_no_role_holds_the_user_and_is_logged_once(self):
        from credit_review import runner
        logged = []
        saved_log, saved_flag = runner.log, verify_notify._odd_array_logged
        runner.log, verify_notify._odd_array_logged = logged.append, False
        try:
            for odd in ("Mixing, Mastering", '["Mixing"]', "{Mixing"):
                self.assertEqual(verify_notify.pg_text_array(odd), "")
            got = uvn_status.uvn_requests([7], lambda sql: [
                ["r1", "7", "p", "t", "Song", '[{"name":"Art"}]', '["Mixing"]', "12", "{}", "{}"]])
        finally:
            runner.log, verify_notify._odd_array_logged = saved_log, saved_flag
        self.assertEqual(len(logged), 1)
        self.assertIn("not a Postgres text[] literal", logged[0])
        self.assertEqual((got[7][0]["role"], got[7][0]["_incomplete"]), ("", True))
        self.assertEqual(uvn_status.plan({"r1"}, got[7], True), ("incomplete_fields", []))


class WithdrawalConfirmTests(unittest.TestCase):
    RID = "a9f8e7c0-8183-47e2-8f9e-f27338192f48"
    OTHER = "0499ded8-7d04-4335-8aeb-02350d53b784"
    THIRD = "5d1c3e2a-7b9f-4c60-a8d2-1e4f6b0c9a37"

    def setUp(self):
        self.ledger = str(Path(tempfile.mkdtemp(prefix="wc-")) / "ledger.sqlite3")

    def test_only_requester_withdrawals_are_confirmed_with_role_and_title_from_the_row(self):
        rows = [[self.RID, "rejected", "requester", "Nowhere Fast", '[{"name":"Art"}]', "{Mastering}", "12609", "a@x.com", "Ann", pro(12609), auth(12609)],
                [self.OTHER, "rejected", None, "obsessed", "[]", "{Mixing}", "104906", "b@x.com", "", pro(104906), auth(104906)]]
        gate = FakeGate()
        rep, refused, _, _ = withdrawal_confirm.run([self.RID, self.OTHER], mode="apply", query=lambda sql: rows,
                                              runner=gate, wrapper="/gate")
        self.assertEqual(len(gate.calls), 1)
        argv, payload = gate.calls[0]
        self.assertIn("withdrawal-confirm", argv)
        self.assertEqual(payload["credits"][0]["role"], "Mastering")
        self.assertEqual(payload["credits"][0]["track_title"], "Nowhere Fast")
        self.assertEqual(rep.sent_notes, 1)
        self.assertTrue(any("not a requester withdrawal" in r for r in refused))

    def test_the_replica_credits_literal_is_parsed_and_never_cast_in_sql(self):
        """2026-10-22 prod: credit_requests.credits reaches Trino as a Postgres text[] literal in
        a varchar; CAST(credits AS array(varchar)) failed every live query."""
        seen = []
        rows = [[self.RID, "rejected", "requester", "Nowhere Fast", '[{"name":"Art"}]', '{Mixing,"Mastering Engineer"}',
                 "12609", "a@x.com", "Ann", pro(12609), auth(12609)]]

        def q(sql):
            seen.append(sql)
            return rows
        gate = FakeGate()
        withdrawal_confirm.run([self.RID], mode="apply", query=q, runner=gate, wrapper="/gate")
        self.assertNotIn("array(varchar)", seen[0])
        self.assertEqual(gate.calls[0][1]["credits"][0]["role"], "Mixing, Mastering Engineer")
        rows[0][5] = "Mixing, Mastering Engineer"  # not a text[] literal: no role, never sent
        gate = FakeGate()
        _, refused, _, _ = withdrawal_confirm.run([self.RID], mode="apply", query=q, runner=gate, wrapper="/gate")
        self.assertEqual((gate.calls, refused), ([], [f"{self.RID}: no title, role or account email"]))

    def test_a_request_with_a_conversation_is_answered_in_that_thread(self):
        rows = [[self.RID, "rejected", "requester", "Nowhere Fast", '[{"name":"Art"}]', "{Mastering}", "12609", "a@x.com", "Ann", pro(12609), auth(12609)],
                [self.OTHER, "rejected", "requester", "obsessed", "[]", "{Mixing}", "104906", "b@x.com", "", pro(104906), auth(104906)]]
        gate = FakeGate()
        withdrawal_confirm.run([f"{self.RID}:215476464925099", self.OTHER], mode="apply", query=lambda sql: rows,
                               runner=gate, wrapper="/gate")
        argv = {p["credits"][0]["request_id"]: a for a, p in gate.calls}
        self.assertEqual(argv[self.RID][argv[self.RID].index("--conversation") + 1], "215476464925099")
        self.assertNotIn("--conversation", argv[self.OTHER])
        _, refused, _, _ = withdrawal_confirm.run([f"{self.RID}:abc"], mode="apply", query=lambda sql: rows,
                                            runner=gate, wrapper="/gate")
        self.assertEqual(len(gate.calls), 2)
        self.assertTrue(refused)

    OPS_COMMANDS = (["uvn-status", "--list", "/nonexistent/list.json", "--segment", "paid", "--mode", "apply"],
                    ["withdrawal-confirm", "--request-ids", RID, "--mode", "apply"],
                    ["email-changed", "--user-id", "42", "--conversation", "777", "--ticket", "t1", "--mode", "apply"])

    def test_the_ops_notes_kill_switch_stops_uvn_status_withdrawal_confirm_and_email_changed(self):
        with tempfile.TemporaryDirectory() as d:
            ks = Path(d) / "credit-ops-notes.disabled"
            ks.write_text("")
            env = {**os.environ, "CREDIT_OPS_NOTES_KILL_SWITCH": str(ks),
                   "CREDIT_VERIFY_NOTIFY_KILL_SWITCH": str(Path(d) / "absent"),
                   "CREDIT_VERIFY_NOTIFY_WRAPPER": str(Path(d) / "no-gate"),
                   "CREDIT_REVIEW_LOG": str(Path(d) / "run.log")}
            for argv in self.OPS_COMMANDS:
                p = subprocess.run([sys.executable, str(ROOT / "scripts" / "credit-review.py"), *argv],
                                   capture_output=True, text=True, env=env, timeout=60, check=False)
                self.assertEqual((p.returncode, p.stdout.strip()), (0, "NO_REPLY"), (argv[0], p.stderr))

    def test_only_the_ops_notes_switch_stops_them_never_the_verify_notify_one(self):
        import contextlib
        import importlib.util
        import io
        spec = importlib.util.spec_from_file_location("credit_review_cli_ks", ROOT / "scripts" / "credit-review.py")
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)
        ran = []
        saved = (cli.uvn_status.run, cli.withdrawal_confirm.run, cli.withdrawal_confirm.email_changed)
        cli.uvn_status.run = lambda **kw: ran.append("uvn-status") or uvn_status.UvnReport()
        cli.withdrawal_confirm.run = lambda ids, **kw: ran.append("withdrawal-confirm") or (verify_notify.Report(), [], [], [])
        cli.withdrawal_confirm.email_changed = lambda **kw: ran.append("email-changed") or (verify_notify.Report(), [])

        def outputs():
            outs = []
            for argv in self.OPS_COMMANDS:
                args = cli.parser().parse_args(argv)
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    args.fn(args)
                outs.append(out.getvalue().strip())
            return outs

        try:
            with tempfile.TemporaryDirectory() as d:
                on, off = Path(d) / "present.disabled", Path(d) / "absent.disabled"
                on.write_text("")
                cli.VERIFY_NOTIFY_KILL_SWITCH, cli.CREDIT_OPS_NOTES_KILL_SWITCH = on, off
                outs = outputs()
                self.assertEqual(ran, ["uvn-status", "withdrawal-confirm", "email-changed"])
                self.assertNotIn("NO_REPLY", outs)
                ran.clear()
                cli.VERIFY_NOTIFY_KILL_SWITCH, cli.CREDIT_OPS_NOTES_KILL_SWITCH = off, on
                self.assertEqual(outputs(), ["NO_REPLY"] * 3)
                self.assertEqual(ran, [])
        finally:
            cli.uvn_status.run, cli.withdrawal_confirm.run, cli.withdrawal_confirm.email_changed = saved

    def test_email_changed_is_a_threaded_reply_for_the_account(self):
        gate = FakeGate(out="POSTED comment conversation=215476442050417 message=1 credits=1")
        rep, refused = withdrawal_confirm.email_changed(user_id=297990, conversation="215476442050417", ticket="869abc",
                                                        mode="apply", query=lambda sql: [["297990", "new@x.com", "1d2c9b7e-55aa-4f0e-8b1c-6a7d0e3f2b91",
                                                                           "auth0|1d2c9b7e-55aa-4f0e-8b1c-6a7d0e3f2b91"]],
                                                        runner=gate, wrapper="/gate", ledger_path=self.ledger, post=Poster())
        self.assertEqual(refused, [])
        argv, payload = gate.calls[0]
        self.assertEqual(argv[argv.index("--campaign") + 1], "email-changed")
        self.assertEqual(argv[argv.index("--conversation") + 1], "215476442050417")
        self.assertEqual(payload["user"], {"email": "new@x.com", "id": "297990", "first_name": "",
                                           "professional_id": "1d2c9b7e-55aa-4f0e-8b1c-6a7d0e3f2b91",
                                           "auth_id": "1d2c9b7e-55aa-4f0e-8b1c-6a7d0e3f2b91",
                                           "thread_external_id": "", "ext_other_account": False})
        self.assertEqual(payload["credits"], [{"request_id": "email-change-869abc"}])
        gate = FakeGate()
        withdrawal_confirm.email_changed(user_id=293649, conversation="1", ticket="t", dup=True, mode="apply",
                                         query=lambda sql: [["293649", "z@x.com", "aa", "auth0|aa"]], runner=gate, wrapper="/gate",
                                         ledger_path=self.ledger, post=Poster())
        self.assertIn("email-changed-dup", gate.calls[0][0])
        _, refused = withdrawal_confirm.email_changed(user_id=1, conversation="abc", ticket="t", query=lambda sql: [],
                                                      runner=FakeGate(), wrapper="/gate")
        self.assertTrue(refused)

    def test_email_changed_reports_a_deferral_and_exits_3(self):
        import contextlib
        import importlib.util
        import io
        spec = importlib.util.spec_from_file_location("credit_review_cli", ROOT / "scripts" / "credit-review.py")
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)
        real = withdrawal_confirm.email_changed
        deferring = FakeGate(rc=3, out="DEFERRED daily-cap credits=1")

        def fake(**kw):
            return real(query=lambda sql: [["42", "a@x.com", pro(42), auth(42)]], runner=deferring, wrapper="/gate",
                        ledger_path=self.ledger, post=Poster(ok=False), **kw)

        with tempfile.TemporaryDirectory() as d:
            cli.CREDIT_OPS_NOTES_KILL_SWITCH = Path(d) / "absent"
            cli.withdrawal_confirm.email_changed = fake
            try:
                args = cli.parser().parse_args(["email-changed", "--user-id", "42", "--conversation", "777",
                                                "--ticket", "t1", "--mode", "apply"])
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    rc = args.fn(args)
            finally:
                cli.withdrawal_confirm.email_changed = real
        self.assertEqual(rc, 3)
        self.assertIn("sent 0", out.getvalue())
        self.assertIn("deferred 1", out.getvalue())
        self.assertEqual(len(deferring.calls), 1)

    def test_email_changed_flags_a_ticket_refused_three_times(self):
        with tempfile.TemporaryDirectory() as d:
            ledger = str(Path(d) / "l.sqlite3")
            db = verify_ledger.connect(ledger)
            for days in (0, 8, 16):
                verify_ledger.refuse(db, campaign="email-changed", user_key="a@x.com", day="2026-10-20",
                                     request_ids=["email-change-t9"], message_type="comment", approved_by="U7RP6HKUZ",
                                     approval_ref="ref", reason="conversation 777 has 2 contacts", user_id="42",
                                     now=FIXED + timedelta(days=days))
            db.close()
            post = Poster()
            rep, refused = withdrawal_confirm.email_changed(user_id=42, conversation="777", ticket="t9", mode="apply",
                                                            query=lambda sql: [["42", "a@x.com", pro(42), auth(42)]],
                                                            runner=FakeGate(rc=3, out="DEFERRED refused-recheck credits=1"),
                                                            wrapper="/gate", ledger_path=ledger, post=post)
            self.assertEqual((refused, rep.flagged, len(post.texts)), ([], 1, 1))
            self.assertIn("Muso user 42", post.texts[0])
            db = verify_ledger.connect(ledger)
            self.assertEqual(verify_ledger.refusal_hold(db, "email-changed", "a@x.com", FIXED + timedelta(days=99)),
                             {"flagged": True})
            db.close()

    def test_withdrawal_passes_the_professional_id_and_holds_only_accounts_without_one(self):
        legacy_pro = "0c9e7b3a-5d2f-4a18-9e6b-3f1d8c2a7b54"
        rows = [[self.RID, "rejected", "requester", "Nowhere Fast", '[{"name":"Art"}]', "{Mastering}", "12609", "a@x.com", "Ann", pro(12609), auth(12609)],
                [self.OTHER, "rejected", "requester", "obsessed", "[]", "{Mixing}", "104906", "b@x.com", "", legacy_pro, None],
                [self.THIRD, "rejected", "requester", "x", "[]", "{Mixing}", "5", "c@x.com", "", None, None]]
        gate = FakeGate()
        rep, refused, held, _ = withdrawal_confirm.run([self.RID, self.OTHER, self.THIRD], mode="apply",
                                                       query=lambda sql: rows, runner=gate, wrapper="/gate")
        self.assertEqual([(p["user"]["professional_id"], p["user"]["auth_id"]) for _, p in gate.calls],
                         [(pro(12609), "6f1c2a9e-0b7d-4c3e-9a51-000000012609"), (legacy_pro, "")])
        self.assertEqual((rep.no_professional_id, refused, held), (1, [], [self.THIRD]))

    def test_thread_pre_flight_reports_the_gates_refusal_and_read_failures_apart(self):
        rows = [[self.RID, "rejected", "requester", "Nowhere Fast", '[{"name":"Art"}]', "{Mastering}", "12609", "a@x.com", "Ann", pro(12609), auth(12609)]]

        class Gate(FakeGate):
            def __init__(self, rc, err):
                super().__init__()
                self.pre = (rc, err)

            def __call__(self, argv):
                if "--thread-contact" in argv:
                    return subprocess.CompletedProcess(argv, self.pre[0], "", self.pre[1])
                return super().__call__(argv)

        gate = Gate(1, "REFUSED: the rendered note contains a word Caroline's outbound sanitizer redacts ('ticket')\n")
        rep, _, _, _ = withdrawal_confirm.run([f"{self.RID}:777"], mode="apply", query=lambda sql: rows, runner=gate,
                                              wrapper="/gate")
        self.assertEqual((gate.calls, rep.refused_users, rep.failed_users), ([], 1, 0))
        self.assertIn("sanitizer redacts ('ticket')", rep.refusals[0])
        gate = Gate(4, "CONVERSATION READ FAILED (curl); nothing was sent or claimed:\n")
        rep, _, _, _ = withdrawal_confirm.run([f"{self.RID}:777"], mode="apply", query=lambda sql: rows, runner=gate,
                                              wrapper="/gate")
        self.assertEqual((gate.calls, rep.refused_users, rep.failed_users), ([], 0, 1))
        self.assertIn("could not be read (rc=4): CONVERSATION READ FAILED", rep.failures[0])
        # an external_id the replica cannot be asked about is left unchecked (the gate refuses it)
        gate = FakeGate(thread={"contacts": 1, "role": "user", "external_id": "someone@else"})
        withdrawal_confirm.run([f"{self.RID}:777"], mode="apply", query=lambda sql: rows, runner=gate, wrapper="/gate")
        self.assertNotIn("ext_other_account", gate.calls[0][1]["user"])
        self.assertEqual(gate.calls[0][1]["user"]["thread_external_id"], "someone@else")

    def test_in_thread_legacy_id_match_is_not_held_and_checks_the_thread_external_id_on_the_replica(self):
        legacy = "4f0b6d2e-8a1c-4e7f-b3d9-2c5a7e9f1b03"
        legacy_pro = "0c9e7b3a-5d2f-4a18-9e6b-3f1d8c2a7b54"
        rows = [[self.RID, "rejected", "requester", "Nowhere Fast", '[{"name":"Art"}]', "{Mastering}", "12609", "a@x.com", "Ann", legacy_pro, None]]

        def replica_with(owners):
            def q(sql):
                return [[o] for o in owners] if "neptuneprofessionalid = '" in sql else rows
            return q

        for owners, other in (([], False), (["12609"], False), (["777"], True)):
            gate = FakeGate(out="POSTED comment conversation=215476464925099 message=1 credits=1",
                            thread={"contacts": 1, "role": "user", "external_id": legacy})
            rep, refused, held, _ = withdrawal_confirm.run([f"{self.RID}:215476464925099"], mode="apply",
                                                           query=replica_with(owners), runner=gate, wrapper="/gate")
            self.assertEqual((held, refused, rep.no_professional_id), ([], [], 0))
            self.assertIn("--conversation", gate.lookups[0][0])
            user = gate.calls[0][1]["user"]
            self.assertEqual((user["auth_id"], user["thread_external_id"], user["ext_other_account"]), ("", legacy, other))
        # a dry run reads nothing from Intercom
        gate = FakeGate(thread={"contacts": 1, "role": "user", "external_id": legacy})
        withdrawal_confirm.run([f"{self.RID}:215476464925099"], mode="dry-run", query=replica_with([]), runner=gate,
                               wrapper="/gate")
        self.assertEqual(gate.lookups, [])
        # the thread contact's external_id is this account's professional id: no replica check needed
        gate = FakeGate(out="POSTED comment conversation=215476464925099 message=1 credits=1",
                        thread={"contacts": 1, "role": "user", "external_id": legacy_pro})
        withdrawal_confirm.run([f"{self.RID}:215476464925099"], mode="apply", query=replica_with(["999"]),
                               runner=gate, wrapper="/gate")
        self.assertEqual(gate.calls[0][1]["user"]["ext_other_account"], False)
        # email-changed: an account without an Auth0 subject is answered in its thread, not held
        gate = FakeGate(thread={"contacts": 1, "role": "user", "external_id": legacy})
        rep, refused = withdrawal_confirm.email_changed(user_id=42, conversation="777", ticket="t1", mode="apply",
                                                        query=lambda sql: [] if "neptuneprofessionalid = '" in sql
                                                        else [["42", "a@x.com", legacy_pro, ""]], runner=gate,
                                                        wrapper="/gate", ledger_path=self.ledger, post=Poster())
        self.assertEqual((len(gate.calls), refused), (1, []))
        self.assertEqual(gate.calls[0][1]["user"]["ext_other_account"], False)
        _, refused = withdrawal_confirm.email_changed(user_id=42, conversation="777", ticket="t1", mode="apply",
                                                      query=lambda sql: [["42", "a@x.com", None, ""]], runner=FakeGate(),
                                                      wrapper="/gate", ledger_path=self.ledger, post=Poster())
        self.assertIn("no professional id", refused[0])

    def test_withdrawal_confirm_names_a_deferred_request_and_exits_3(self):
        import contextlib
        import importlib.util
        import io
        spec = importlib.util.spec_from_file_location("credit_review_cli_wd", ROOT / "scripts" / "credit-review.py")
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)
        rows = [[self.RID, "rejected", "requester", "Nowhere Fast", '[{"name":"Art"}]', "{Mastering}", "12609", "a@x.com", "Ann", pro(12609), auth(12609)]]
        real = withdrawal_confirm.run
        gate = FakeGate(rc=3, out="DEFERRED daily-cap credits=1 (this user already had a verify message)")

        def fake(ids, **kw):
            return real(ids, query=lambda sql: rows, runner=gate, wrapper="/gate", **kw)

        with tempfile.TemporaryDirectory() as d:
            cli.CREDIT_OPS_NOTES_KILL_SWITCH = Path(d) / "absent"
            cli.withdrawal_confirm.run = fake
            try:
                args = cli.parser().parse_args(["withdrawal-confirm", "--request-ids", f"{self.RID}:215476464925099",
                                                "--mode", "apply"])
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    rc = args.fn(args)
            finally:
                cli.withdrawal_confirm.run = real
        self.assertEqual(rc, 3)
        self.assertIn("deferred 1", out.getvalue())
        self.assertIn(f"{self.RID}: deferred, daily cap: retry tomorrow", out.getvalue())

    def test_withdrawal_confirm_mixed_run_names_the_held_request_and_exits_3(self):
        import contextlib
        import importlib.util
        import io
        spec = importlib.util.spec_from_file_location("credit_review_cli_wc", ROOT / "scripts" / "credit-review.py")
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)
        rows = [[self.RID, "rejected", "requester", "Nowhere Fast", '[{"name":"Art"}]', "{Mastering}", "12609", "a@x.com", "Ann", None, None],
                [self.OTHER, "rejected", "requester", "obsessed", "[]", "{Mixing}", "104906", "b@x.com", "", pro(104906), auth(104906)]]
        real = withdrawal_confirm.run
        gate = FakeGate()

        def fake(ids, **kw):
            return real(ids, query=lambda sql: rows, runner=gate, wrapper="/gate", **kw)

        with tempfile.TemporaryDirectory() as d:
            cli.CREDIT_OPS_NOTES_KILL_SWITCH = Path(d) / "absent"
            cli.withdrawal_confirm.run = fake
            try:
                args = cli.parser().parse_args(["withdrawal-confirm", "--request-ids", f"{self.RID},{self.OTHER}",
                                                "--mode", "apply"])
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    rc = args.fn(args)
            finally:
                cli.withdrawal_confirm.run = real
        self.assertEqual((rc, [p["credits"][0]["request_id"] for _, p in gate.calls]), (3, [self.OTHER]))
        self.assertIn("WITHDRAWAL CONFIRM: sent 1,", out.getvalue())
        self.assertIn("held (no professional id) 1", out.getvalue())
        self.assertIn(f"{self.RID}: held, no professional id on the account", out.getvalue())

    def test_malformed_or_unknown_ids_send_nothing(self):
        gate = FakeGate()
        _, refused, _, _ = withdrawal_confirm.run(["x'; drop"], mode="apply", query=lambda sql: [], runner=gate, wrapper="/gate")
        self.assertEqual(gate.calls, [])
        self.assertTrue(refused)
        _, refused, _, _ = withdrawal_confirm.run([self.RID], mode="apply", query=lambda sql: [], runner=gate, wrapper="/gate")
        self.assertEqual(refused, [f"{self.RID}: not found"])


class DocumentPostdatesRequestTest(unittest.TestCase):
    """p1 198 / Fable 199 (rule, from Lamberto 298376): a document filed BEFORE a request was created cannot be its
    proof, so it never blocks the ask about that request. One naming the request, or arriving after it, still does."""

    def pof(self, *entries):
        d = verify_notify.ProofOnFile()
        for rid, kind, at in entries:
            d.setdefault("298376", []).append((rid, kind))
            d.dated.setdefault("298376", []).append((rid, kind, at))
        return d

    def test_lamberto_march_documents_do_not_block_an_october_request(self):
        d = self.pof((None, "human_approved_after_doc", "2026-03-29T11:40:36Z"),
                     (None, "human_approved_after_doc", "2026-03-29T11:30:52Z"))
        ask = ["5915db5d-fb40-4f5d-b204-45c19d4a6a47"]
        self.assertTrue(uvn_status.documents_block(d, "298376", ask, set()))                         # date unknown
        self.assertFalse(uvn_status.documents_block(d, "298376", ask, set(), "2026-10-15 07:21:38.896000 UTC"))
        self.assertFalse(uvn_status.documents_block(d, "298376", ask, set(),
                                                    uvn_status.oldest_created([{"_created": "2026-10-15 07:21:38 UTC"}])))

    def test_a_later_document_or_one_naming_the_request_still_blocks(self):
        ask = ["5915db5d"]
        later = self.pof((None, "pending_doc", "2026-10-20T00:00:00Z"))
        self.assertTrue(uvn_status.documents_block(later, "298376", ask, set(), "2026-10-15 07:21:38 UTC"))
        named = self.pof(("5915db5d", "approved_doc", "2026-03-01T00:00:00Z"))
        self.assertTrue(uvn_status.documents_block(named, "298376", ask, set(), "2026-10-15 07:21:38 UTC"))
        undated = self.pof((None, "pending_doc", ""))
        self.assertTrue(uvn_status.documents_block(undated, "298376", ask, set(), "2026-10-15 07:21:38 UTC"))
        # unknown request date (any row without createdat): fail closed
        self.assertIsNone(uvn_status.oldest_created([{"_created": "2026-10-15 07:21:38 UTC"}, {"_created": ""}]))

    def test_load_keeps_proof_at(self):
        d = verify_notify.ProofOnFile()
        self.assertEqual(d.dated, {})


class DryRunEqualsApplyTest(UvnStatusTests):
    """QA #1508 (b1): the dry run IS the code the send runs - with only March proof for an October request, dry run and
    apply select the same users (the apply path's early 'documented' guard ran before the date filter)."""

    def run_both(self, entries):
        proof(self.proof, entries)
        self.users = [{"user_id": 7, "paid": True, "skip": None, "request_ids": ["r7"], "oldest": "2026-10-15 07:21:38.896000 UTC"}]
        self.write_list()
        q = replica([7], rows={"r7": {"created": "2026-10-15 07:21:38.896000 UTC"}})
        got = {}
        for mode in ("dry-run", "apply"):
            Path(self.ledger).unlink(missing_ok=True)
            _rep, gate = self.run_(mode=mode, query=q)
            got[mode] = sorted(p["user"]["id"] for _, p in gate.calls)
            self.since = getattr(self, "since", {})
            self.since[mode] = next((p["user"].get("requests_since") for _, p in gate.calls), None)
        return got

    def test_march_proof_for_an_october_request_asks_in_both_modes(self):
        got = self.run_both([{"user_id": 7, "request_id": None, "kind": "human_approved_after_doc", "source": "intercom",
                              "ref": "x", "proof_at": "2026-03-29T11:40:36Z"}])
        self.assertEqual(got["dry-run"], got["apply"])
        self.assertEqual(got["apply"], ["7"])
        # ... and the gate gets the request date for its own document check (user.requests_since), in both modes
        self.assertEqual(self.since, {"dry-run": "2026-10-15T07:21:38.896000+00:00", "apply": "2026-10-15T07:21:38.896000+00:00"})

    def test_proof_after_the_request_holds_in_both_modes(self):
        got = self.run_both([{"user_id": 7, "request_id": None, "kind": "pending_doc", "source": "intercom",
                              "ref": "x", "proof_at": "2026-10-20T00:00:00Z"}])
        self.assertEqual(got, {"dry-run": [], "apply": []})


class ReplyDueListTest(unittest.TestCase):
    def test_a_list_row_with_reply_due_becomes_the_gate_args(self):
        p = uvn_status.with_reply_due({"user": {}, "credits": []}, {"reply_due": {"part": "57000000001", "conversation": "215473681300330"}})
        self.assertEqual(p["extra"], ["--conversation", "215473681300330", "--reply-due", "57000000001"])
        for bad in ({"part": "1; rm", "conversation": "2"}, {"part": "1"}, "x", None):
            self.assertNotIn("extra", uvn_status.with_reply_due({"user": {}}, {"reply_due": bad}))


class ReplyDueRunnerTest(UvnStatusTests):
    """QA #1509: the real runner carries a reply_due row to the gate in BOTH modes, past the 7-day note cooldown
    (the ledger filter dropped it, and the apply rebuild lost its gate args)."""

    def run_both(self, with_reply_due=True):
        got = {}
        for mode in ("dry-run", "apply"):
            Path(self.ledger).unlink(missing_ok=True)
            db = verify_ledger.connect(self.ledger)
            old = NOW - timedelta(days=2)
            r = verify_ledger.claim(db, user_key="u7@x.com", day=old.strftime("%Y-%m-%d"), request_ids=["x7"],
                                    message_type="email", approved_by="U", approval_ref="ref", campaign="status-team-review",
                                    user_id="7", now=old)
            verify_ledger.finalize(db, message_row=int(r["message_row"]), status="sent", message_id="1", now=old)
            db.close()
            row = {"user_id": 7, "paid": True, "skip": None, "request_ids": ["r7"], "oldest": "2026-10-15 07:21:38 UTC"}
            if with_reply_due:
                row["reply_due"] = {"part": "57000000001", "conversation": "215473681300330"}
            self.users = [row]
            self.write_list()
            _rep, gate = self.run_(mode=mode, query=replica([7], rows={"r7": {"created": "2026-10-15 07:21:38 UTC"}}))
            got[mode] = [(p["user"]["id"], a[a.index("--reply-due") + 1] if "--reply-due" in a else "",
                          a[a.index("--conversation") + 1] if "--conversation" in a else "") for a, p in gate.calls]
        return got

    def test_the_answer_reaches_the_gate_in_both_modes_with_its_args(self):
        got = self.run_both()
        self.assertEqual(got["dry-run"], got["apply"])
        self.assertEqual(got["apply"], [("7", "57000000001", "215473681300330")])

    def test_the_dry_run_lists_prior_note_and_assignee_per_reply_due_row(self):
        # r5 bars (e)/(j) on [key=lamberto-reply-due]: the reviewer reads the thread facts the gate will act on
        from unittest import mock
        facts = {"prior_note": {"part": "56450261657", "campaign": "unledgered (#1510 backfill class)", "at": 1760900000},
                 "assignee": {"id": "5465657", "name": "Jan Delmo", "action": "handoff", "handoff_part": "", "handoff_at": 0,
                              "human_replied_after": False, "last_part_at": 0},
                 "trigger_class": {"class": "status", "why": "status term 'under review'", "part_age_d": 4.6}}
        row = {"user_id": 7, "paid": True, "skip": None, "request_ids": ["r7"], "oldest": "2026-10-15 07:21:38 UTC",
               "reply_due": {"part": "57000000001", "conversation": "215473681300330"}}
        self.users = [row]; self.write_list()
        keys_seen = []
        with mock.patch.object(uvn_status.comm_state, "reply_due_thread", lambda conv, ic, **k: facts), \
                mock.patch.object(uvn_status.comm_state, "intercom", lambda m, p, b=None: {}), \
                mock.patch.object(uvn_status.comm_state, "status_trigger",
                                  lambda uid, keys, *a, **k: keys_seen.append(list(keys)) or facts["trigger_class"]):
            rep, _gate = self.run_(mode="dry-run", query=replica([7], rows={"r7": {"created": "2026-10-15 07:21:38 UTC"}}))
            # QA #1517: through run(), the row is classified on the payload's request ids (what the gate receives)
            self.assertEqual(keys_seen, [["r7"]])
            self.assertEqual(rep.reply_due_rows, [{"user": "7", "part": "57000000001", "conversation": "215473681300330", **facts}])
            text = uvn_status.render(rep, "dry-run", "paid")
            self.assertIn("reply_due user 7 part 57000000001 conversation 215473681300330: prior_note 56450261657 "
                          "(unledgered (#1510 backfill class)); assignee 5465657 Jan Delmo action=handoff; "
                          "trigger_class status (status term 'under review', 4.6 d)", text)
            Path(self.ledger).unlink(missing_ok=True)
            rep2, _ = self.run_(mode="apply", query=replica([7], rows={"r7": {"created": "2026-10-15 07:21:38 UTC"}}))
            self.assertEqual(rep2.reply_due_rows, [])                     # the send re-reads in the gate; no report row

    def test_every_reply_due_row_is_rendered(self):
        # QA #1517: 21 rows -> 21 rendered (no silent cut a reviewer could miss)
        rep = uvn_status.UvnReport(listed=21)
        rep.reply_due_rows = [{"user": str(i), "part": str(1000 + i), "conversation": "2", "prior_note": None, "assignee": None}
                              for i in range(21)]
        text = uvn_status.render(rep, "dry-run", "paid")
        self.assertEqual(text.count("reply_due user "), 21)
        self.assertIn("reply_due user 20 part 1020", text)

    def test_without_reply_due_the_7_day_cooldown_still_defers(self):
        self.assertEqual(self.run_both(with_reply_due=False), {"dry-run": [], "apply": []})


class TeamReviewProofRequiredTest(unittest.TestCase):
    """v1 STOP-CLASS / [key=k-proof-required]: a status-team-review (/k) run REFUSES when any listed user has an open
    proof_required=true row (or a fresh capture pending) per core - the list was built wrong; nothing is sent."""
    setUp = UvnStatusTests.setUp
    write_list = UvnStatusTests.write_list
    run_ = UvnStatusTests.run_
    gate_file = UvnStatusTests.gate_file

    def pr_query(self, pr):
        base = replica(range(1, 4), status={1: "unverified", 2: "unverified", 3: "unverified"})

        def q(sql):
            if "proof_required_owed" in sql:
                uid = int(__import__("re").search(r"userid = ([0-9]+)", sql).group(1))
                return [pr.get(uid, ["0", "0"])]
            return base(sql)
        return q

    def test_one_proof_required_user_refuses_the_whole_run(self):
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in range(1, 4)]
        self.write_list()
        rep, gate = self.run_(campaign="status-team-review", query=self.pr_query({2: ["1", "0"]}))
        self.assertEqual(gate.calls, [])
        self.assertIn("owe proof per core proof_required", rep.halted)
        self.assertIn("2:owes:proof_required", rep.halted)
        rep, gate = self.run_(campaign="status-team-review", query=self.pr_query({3: ["0", "1"]}))
        self.assertEqual(gate.calls, []); self.assertIn("3:owes:fresh_capture_pending", rep.halted)

    def test_an_unreadable_read_refuses_and_a_clean_list_goes(self):
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in range(1, 4)]
        self.write_list()
        rep, gate = self.run_(campaign="status-team-review", query=self.pr_query({1: ["x"]}))
        self.assertEqual(gate.calls, []); self.assertIn("proof_required read failed", rep.halted)
        rep, gate = self.run_(campaign="status-team-review", query=self.pr_query({}))
        self.assertEqual(rep.halted, "")
        self.assertEqual(len(gate.calls), 3)


class ProofRequiredAskTest(unittest.TestCase):
    """v1 / [key=k-proof-required]: an open unverified/processing row with core proof_required = true (no reviewStage)
    is named by the uvn-status ASK; one without it, or with a review-stage mark, is not."""
    setUp = UvnStatusTests.setUp
    write_list = UvnStatusTests.write_list
    run_ = UvnStatusTests.run_
    gate_file = UvnStatusTests.gate_file

    def test_the_ask_names_proof_required_rows(self):
        import re

        status = {"ru": "user_verification_needed", "rp": "unverified", "rn": "unverified", "rs": "processing"}
        vd = {"rp": {"proof_required": True}, "rn": {"proof_required": False}, "rs": {"proof_required": True}}
        md = {"rs": {"reviewStage": "manual"}}

        def q(sql):
            if "public.users" in sql:
                return [["1", "a@x.com", "Ann", pro(1), auth(1)]]
            m = re.search(r"status IN \(([^)]*)\)", sql)
            wanted = set(re.findall(r"'([a-z_]+)'", m.group(1))) if m else set(status.values())
            return [[rid, "1", "p1", "t1", f"Song {rid}", '[{"name":"Art"}]', "{Mixing}", "10",
                     json.dumps(vd.get(rid, {})), json.dumps(md.get(rid, {})), ""]
                    for rid, st in status.items() if st in wanted]
        self.users = [{"user_id": 1, "paid": True, "skip": None, "class": "uvn", "request_ids": ["rn", "rp", "rs", "ru"]}]
        self.write_list()
        rep, gate = self.run_(mode="apply", query=q)
        self.assertEqual(len(gate.calls), 1, rep)
        self.assertEqual(sorted(c["request_id"] for c in gate.calls[0][1]["credits"]), ["rp", "ru"])

    def test_core_proof_required_overrides_the_approval_path_exclusion(self):
        # QA #1565 (reproduced): an approval-path-shaped verdict that ALSO says proof_required is asked, never dropped
        import re
        vd = {"rp": {"proof_required": True, "is_approved": True, "total_risk_percent": 0, "rule_risk_percent": {},
                     "band_hint": "A"},
              "ra": {"proof_required": False, "is_approved": True, "total_risk_percent": 0, "rule_risk_percent": {},
                     "band_hint": "A"}}
        # no plain UVN row: the proof_required row is the user's ONLY owed row (QA: plan() = nothing_to_ask without the fix)
        status = {"rp": "unverified", "ra": "user_verification_needed"}

        def q(sql):
            if "public.users" in sql:
                return [["1", "a@x.com", "Ann", pro(1), auth(1)]]
            m = re.search(r"status IN \(([^)]*)\)", sql)
            wanted = set(re.findall(r"'([a-z_]+)'", m.group(1))) if m else set(status.values())
            return [[rid, "1", "p1", "t" + rid, f"Song {rid}", '[{"name":"Art"}]', "{Mixing}", "10",
                     json.dumps(vd.get(rid, {})), "{}", ""] for rid, st in status.items() if st in wanted]
        self.users = [{"user_id": 1, "paid": True, "skip": None, "class": "uvn", "request_ids": ["ra", "rp"]}]
        self.write_list()
        rep, gate = self.run_(mode="apply", query=q)
        self.assertEqual(len(gate.calls), 1, rep)
        named = sorted(c["request_id"] for c in gate.calls[0][1]["credits"])
        self.assertIn("rp", named)                      # proof_required wins over the approval path
        self.assertNotIn("ra", named)                   # a plain approval-path row is still not asked

    def test_plan_keeps_a_proof_required_row_that_looks_like_the_approval_path(self):
        # QA #1565's exact reproduction at plan(): proof_required + an approval-path-shaped verdict, popularity 10
        vd = {"proof_required": True, "is_approved": True, "total_risk_percent": 0, "rule_risk_percent": {}, "band_hint": "A"}
        row = {"request_id": "rp", "_no_ask": uvn_status._no_ask_of("{Mixing}", "10", json.dumps(vd), "{}"),
               "_proof_required": True, "_incomplete": False}
        self.assertNotEqual(uvn_status.plan({"rp"}, [row], True)[0], "nothing_to_ask")
        plain = {**vd, "proof_required": False}
        self.assertEqual(uvn_status._no_ask_of("{Mixing}", "10", json.dumps(plain), "{}"), "approval_path")

    def test_an_owing_proof_list_is_verified_against_the_replica_before_any_ask(self):
        # QA #1565: --verify-facts is ENFORCED by the runner - a user whose owed set changed since the build (a newly owed
        # row the ask would omit) is taken out, never asked or closed; an edited list halts; a re-read failure halts
        import re
        from unittest import mock
        from credit_review import owing_proof

        def q(sql):
            if "public.users" in sql:
                return [["1", "a@x.com", "Ann", pro(1), auth(1)]]
            m = re.search(r"status IN \(([^)]*)\)", sql)
            wanted = set(re.findall(r"'([a-z_]+)'", m.group(1))) if m else {"user_verification_needed"}
            return [["ru", "1", "p1", "t1", "Song ru", '[{"name":"Art"}]', "{Mixing}", "10", "{}", "{}", ""]] \
                if "user_verification_needed" in wanted else []
        self.users = [{"user_id": 1, "paid": True, "skip": None, "class": "uvn", "request_ids": ["ru"],
                       "facts": [["ru", "user_verification_needed", False]]}]
        self.list.write_text(json.dumps({"generated_at": iso(2), "users": self.users,
                                         "replica_facts": owing_proof.facts_header(self.users)}))
        seen = []
        def vf(answer):
            def f(doc, query, **kw):
                seen.append(doc["replica_facts"]["sha256"])
                if isinstance(answer, Exception):
                    raise answer
                return answer
            return f
        with mock.patch.object(owing_proof, "verify_facts", vf(["1: listed [['ru'...]] -> now [['ru'...], ['rp'...]]"])):
            rep, gate = self.run_(mode="apply", query=q)
        self.assertEqual((gate.calls, rep.facts_changed, rep.halted), ([], ["1"], ""))
        self.assertTrue(seen)                                                       # the runner called it, on THIS list
        self.assertIn("owed requests changed since the list was built", uvn_status.render(rep, "apply", "paid"))
        with mock.patch.object(owing_proof, "verify_facts", vf(["header: replica_facts.sha256 x does not match"])):
            rep, gate = self.run_(mode="apply", query=q)
        self.assertIn("replica_facts.sha256", rep.halted); self.assertEqual(gate.calls, [])
        with mock.patch.object(owing_proof, "verify_facts", vf(RuntimeError("trino down"))):
            rep, gate = self.run_(mode="apply", query=q)
        self.assertIn("re-read failed", rep.halted); self.assertEqual(gate.calls, [])
        with mock.patch.object(owing_proof, "verify_facts", vf([])):                # unchanged: the ask goes
            rep, gate = self.run_(mode="apply", query=q)
        self.assertEqual(len(gate.calls), 1, rep)


class ReplyDueTitleParityTest(unittest.TestCase):
    """QA #1517 / b1 270: the dry-run row classifies the part with the SAME function as the send gate's comm_state.check
    (comm_state.status_trigger: open titles + filed-request evidence), on the payload's own request ids."""

    def test_the_dry_run_uses_status_trigger_with_the_named_requests(self):
        from unittest import mock
        seen = {}
        def st(uid, keys, conversation, part, query, ic, conv=None):
            seen.update({"uid": uid, "keys": list(keys), "conversation": conversation, "part": part})
            return {"class": "status", "why": "names their track", "part_age_d": 1.0}
        with mock.patch.object(uvn_status.comm_state, "reply_due_thread", lambda conv, ic, **k: {"prior_note": None, "assignee": None}), \
                mock.patch.object(uvn_status.comm_state, "status_trigger", st):
            row = uvn_status.reply_due_row(7, {"reply_due": {"part": "9", "conversation": "2"},
                                               "credits": [{"request_id": "r7"}]}, query=lambda sql: [])
        self.assertEqual(seen, {"uid": 7, "keys": ["r7"], "conversation": "2", "part": "9"})
        self.assertEqual(row["trigger_class"]["class"], "status")

    def test_check_uses_the_same_function(self):
        import inspect
        src = inspect.getsource(uvn_status.comm_state.check)
        self.assertIn("status_trigger(uid, keys, conversation, reply_due_part, query, ic)", src)
        self.assertNotIn("trigger_class(", src)


class ReplyDueRowKeysTest(unittest.TestCase):
    """QA #1517: the dry-run row passes the PAYLOAD's request ids to status_trigger (the list row has request_ids)."""

    def test_keys_come_from_the_payload(self):
        from unittest import mock
        seen = {}
        def st(uid, keys, conversation, part, query, ic, conv=None):
            seen["keys"] = list(keys)
            return {"class": "status", "why": "x", "part_age_d": 1.0}
        with mock.patch.object(uvn_status.comm_state, "reply_due_thread", lambda conv, ic, **k: {"prior_note": None, "assignee": None}), \
                mock.patch.object(uvn_status.comm_state, "status_trigger", st):
            uvn_status.reply_due_row(7, {"request_ids": ["r7"], "reply_due": {"part": "9", "conversation": "2"},
                                         "credits": [{"request_id": "r7"}]}, query=lambda sql: [])
        self.assertEqual(seen["keys"], ["r7"])
        src = open(uvn_status.__file__).read()
        self.assertIn('reply_due_row(uid, {**u, "credits": payload.get("credits") or []}, query=query)', src)


class AsksScopedProofOnFileTest(unittest.TestCase):
    """r5 [key=asks-scoped-pof] (Fable 08:29Z): the ask path reuses claim_proof_ask.claim_holds VERBATIM. Only cs-gmail
    stale: admit on fresh core + cs-intercom, hold + LIST every user cs-gmail could vouch for; a last good scan > 24 h
    holds everyone; any other part unusable refuses all; a fully fresh export is the strict read, unchanged."""
    setUp0 = UvnStatusTests.setUp
    write_list = UvnStatusTests.write_list
    run_ = UvnStatusTests.run_
    gate_file = UvnStatusTests.gate_file

    def setUp(self):
        self.setUp0()
        from credit_review import claim_proof_ask
        self.cpa = claim_proof_ask
        self.saved = claim_proof_ask.PROOF_STORE
        claim_proof_ask.PROOF_STORE = str(self.dir / "proof.sqlite")
        import sqlite3
        db = sqlite3.connect(claim_proof_ask.PROOF_STORE)
        db.execute("CREATE TABLE proof_intake (user_id INTEGER, source TEXT)")
        db.execute("INSERT INTO proof_intake VALUES (9, 'email')")
        db.commit(); db.close()
        verify_ledger.connect(self.ledger).close()      # claim_holds reads the ledger's support@ refs (it always exists live)
        self.users = [{"user_id": 1, "paid": True, "skip": None, "request_ids": ["r1", "r2"]},
                      {"user_id": 4, "paid": True, "skip": None, "request_ids": ["r5"]}]
        self.write_list()
        self.q = query({"users": [["1", "a@x.com", "Ann", pro(1), auth(1)], ["4", "d@x.com", "Dee", pro(4), auth(4)]],
                        "requests": [["r1", "1", "p1", "t1", "Low", '[{"name":"Art"}]', "{Mixing}", "10"],
                                     ["r5", "4", "p4", "t5", "Hi", '[{"name":"Art"}]', "{Mixing}", "10"]]})

    def tearDown(self):
        self.cpa.PROOF_STORE = self.saved

    def feed(self, gmail_h=12.0, intercom_stale=False, contacts=("1",)):
        self.proof.write_text(json.dumps({
            "generated_at": iso(0.2), "users": 0, "entries": [],
            "sources": [{"name": "core", "generated_at": iso(0.2)},
                        {"name": "cs-intercom", "generated_at": iso(0.5), "stale": intercom_stale},
                        {"name": "cs-gmail", "generated_at": iso(gmail_h), "stale": True}],
            "gmail_contacts_90d": {"generated_at": iso(gmail_h), "source": "test", "user_ids": list(contacts)}}))

    def run_scoped(self, mode="apply"):
        return self.run_(mode=mode)                 # run_ passes proof_path=self.proof to the runner

    def test_gmail_vouched_users_are_held_and_listed_the_rest_are_asked(self):
        self.feed(gmail_h=12.0, contacts=("1",))
        rep, gate = self.run_scoped()
        self.assertEqual(rep.halted, "")
        self.assertEqual(sorted(str(p["user"]["id"]) for _, p in gate.calls), ["4"])
        self.assertIn(("1", "held", "stale_source:cs-gmail"), [(o["user"], o["result"], o.get("reason")) for o in rep.outcomes])

    def test_the_o_run_asks_ONLY_the_held_set_with_the_flag_and_stops_when_gmail_is_fresh(self):
        # [key=gmail-o-forward]: an /o run = the frozen did-vouch set ONLY (the rest are skipped), each gate call carries
        # --gmail-fallback-o; cs-gmail fresh (not scoped) = the stop rule: the run halts, nothing is sent
        self.feed(gmail_h=12.0, contacts=("1",))
        rep, gate = self.run_(mode="apply", gmail_fallback_o=True)
        self.assertEqual(rep.halted, "")
        self.assertEqual(sorted(str(p["user"]["id"]) for _, p in gate.calls), ["1"])
        self.assertTrue(all("--gmail-fallback-o" in argv for argv, _ in gate.calls))
        self.assertNotIn("stale_source:cs-gmail", [o.get("reason") for o in rep.outcomes])
        self.assertTrue(rep.by_reason.get("not_in_gmail_held_set"))
        real = self.cpa.claim_holds
        self.cpa.claim_holds = lambda *a, **kw: self.cpa.ClaimHolds(frozenset(), scoped=False)
        try:
            rep, gate = self.run_(mode="apply", gmail_fallback_o=True)
        finally:
            self.cpa.claim_holds = real
        self.assertIn("cs-gmail is stale", rep.halted)
        self.assertEqual(gate.calls, [])

    def test_a_user_vouched_for_between_the_cut_and_the_send_is_held_at_send(self):
        # the re-read right before each send (an email filing that arrived mid-run): documents_block holds them there
        self.feed(gmail_h=12.0, contacts=())
        real, calls = self.cpa.claim_holds, []
        def holds(*a, **kw):
            calls.append(1)
            h = real(*a, **kw)
            return self.cpa.ClaimHolds(frozenset(h.held) | ({"4"} if len(calls) > 1 else set()), scoped=h.scoped)
        self.cpa.claim_holds = holds
        try:
            rep, gate = self.run_scoped()
        finally:
            self.cpa.claim_holds = real
        self.assertGreater(len(calls), 1)
        self.assertNotIn("4", [str(p["user"]["id"]) for _, p in gate.calls])
        self.assertIn(("4", "held", "stale_source:cs-gmail"), [(o["user"], o["result"], o.get("reason")) for o in rep.outcomes])   # LISTED

    def test_holds_and_entries_come_from_one_snapshot(self):
        # QA #1573: the export replaced between claim_holds and the parse must never pair A's holds with B's entries
        self.feed(gmail_h=12.0, contacts=())
        real, b = self.cpa.claim_holds, self.proof.read_text()
        def holds(path, **kw):
            h = real(path, **kw)                                   # validated on snapshot A (user 4 not a contact)
            d = json.loads(b); d["gmail_contacts_90d"]["user_ids"] = ["4"]
            d["entries"] = [{"user_id": "4", "request_id": "r5", "kind": "approved_doc", "source": "cs-intercom", "ref": "x"}]
            self.proof.write_text(json.dumps(d))                   # ... then the live file becomes snapshot B
            return h
        self.cpa.claim_holds = holds
        try:
            pof = uvn_status.asks_proof_on_file(str(self.proof), ledger_path=self.ledger)
        finally:
            self.cpa.claim_holds = real
        self.assertNotIn("4", pof)                                 # entries are A's (no document for 4), not B's

    def test_the_dry_run_holds_and_lists_them_too(self):
        # the signed list is the dry run: a held user is never previewed or validated (the send-time re-read is apply-only)
        self.feed(gmail_h=12.0, contacts=("1",))
        rep, gate = self.run_scoped(mode="dry-run")
        self.assertEqual(sorted(str(p["user"]["id"]) for _, p in gate.calls), ["4"])
        self.assertIn(("1", "held", "stale_source:cs-gmail"), [(o["user"], o["result"], o.get("reason")) for o in rep.outcomes])

    def test_a_gmail_held_user_waits_on_gmail_with_a_due_time_and_is_counted_paid_free(self):
        # Fable [key=gmail-held-fallback]: a stage with an owner and a clock, listed and counted on every run
        self.feed(gmail_h=12.0, contacts=("1",))
        rep, gate = self.run_scoped(mode="dry-run")
        row = next(o for o in rep.outcomes if o["user"] == "1")
        self.assertEqual((row["waiting_on"], row["due_at"], row["paid"]), ("third_party:gmail", "2026-11-02T16:00:00Z", True))
        self.assertIn("held by the Gmail outage: 1 paid / 0 free", uvn_status.render(rep, "dry-run", "paid"))
        self.assertEqual(sorted(str(p["user"]["id"]) for _, p in gate.calls), ["4"])        # no trace: admitted
        self.users.append({"user_id": 3, "paid": False, "skip": None, "request_ids": ["r4"]})
        self.write_list(); self.feed(gmail_h=12.0, contacts=("3",))
        rep, _ = self.run_(mode="dry-run", segment="free")
        self.assertIn("held by the Gmail outage: 0 paid / 1 free", uvn_status.render(rep, "dry-run", "free"))

    def test_past_a_day_the_frozen_did_vouch_set_is_held_and_the_rest_asked(self):
        # Fable FINAL [key=gmail-held-fallback] (3): the snapshot (user 1) is frozen, user 4 (no trace) is still asked
        self.feed(gmail_h=30.0, contacts=("1",))
        rep, gate = self.run_scoped()
        self.assertEqual(sorted(str(p["user"]["id"]) for _, p in gate.calls), ["4"])
        self.assertEqual([o["user"] for o in rep.outcomes if o.get("reason") == "stale_source:cs-gmail"], ["1"])

    def test_another_part_unusable_refuses_all(self):
        self.feed(gmail_h=2.0, intercom_stale=True)
        rep, gate = self.run_scoped()
        self.assertTrue(rep.halted)
        self.assertEqual(gate.calls, [])

    def test_a_fresh_export_is_the_strict_read(self):
        proof(self.proof)
        pof = uvn_status.asks_proof_on_file(str(self.proof))
        self.assertFalse(pof.scoped)
        rep, gate = self.run_scoped()
        self.assertEqual(sorted(str(p["user"]["id"]) for _, p in gate.calls), ["1", "4"])


class NoCorrectionFlagTest(unittest.TestCase):
    """[key=scale-now] (p1 18:42Z): run(no_correction=True) - the timer's class-C rail - reaches EVERY gate call as
    --no-correction (the gate then defers a /c2 ask, check and send alike); off by default."""
    setUp = UvnStatusTests.setUp
    write_list = UvnStatusTests.write_list
    run_ = UvnStatusTests.run_
    gate_file = UvnStatusTests.gate_file

    def test_the_flag_rides_every_gate_call_and_only_when_asked(self):
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in range(1, 3)]
        self.write_list()
        rep, gate = self.run_(mode="apply", query=replica(range(1, 3)), no_correction=True)
        self.assertTrue(gate.calls, rep)
        self.assertTrue(all("--no-correction" in argv for argv, _ in gate.calls))
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in range(3, 5)]
        self.write_list()
        rep, gate = self.run_(mode="apply", query=replica(range(3, 5)))
        self.assertTrue(gate.calls, rep)
        self.assertFalse(any("--no-correction" in argv for argv, _ in gate.calls))


class JudgeFactsTest(unittest.TestCase):
    """[key=scale-now-openclaw] (p1 485 / r5): every previewed body has the RENDERER's facts beside it, a JSON object
    (class, owes_proof, distinct tracks + roles, document dates) - the batch judge's contract; never derived later."""
    setUp = UvnStatusTests.setUp
    write_list = UvnStatusTests.write_list
    run_ = UvnStatusTests.run_
    gate_file = UvnStatusTests.gate_file

    def test_preview_writes_the_renderers_facts_beside_each_body(self):
        self.users = [{"user_id": 1, "paid": True, "skip": None, "request_ids": ["r1"]}]
        self.write_list()
        d = Path(tempfile.mkdtemp())
        rep, gate = self.run_(mode="dry-run", query=replica(range(1, 2)), preview_dir=str(d))
        files = sorted(d.glob("*.facts.json"))
        self.assertTrue(files, rep)
        f = json.loads(files[0].read_text())
        self.assertEqual((f["class"], f["campaign"], f["owes_proof"], f["source"]), ("ask", "uvn-status", True, "renderer"))
        self.assertEqual(f["distinct_tracks"], len(f["tracks"]))
        self.assertEqual(oct(files[0].stat().st_mode & 0o777), "0o600")


class MixedUserTest(unittest.TestCase):
    """r5 on #1541 (rule a): a user with UVN AND held (H1/H2) rows - the uvn-status note names ONLY the UVN rows; the held
    row is never named, claimed or closed by this campaign (it stays for the per-request campaigns)."""

    setUp = UvnStatusTests.setUp
    write_list = UvnStatusTests.write_list
    run_ = UvnStatusTests.run_
    gate_file = UvnStatusTests.gate_file

    def test_the_uvn_note_names_uvn_rows_only(self):
        import re
        import sqlite3
        self.users = [{"user_id": 1, "paid": True, "skip": None, "class": "uvn", "request_ids": ["ru", "rh"]}]
        self.write_list()
        status = {"ru": "user_verification_needed", "rh": "unverified"}

        def q(sql):
            if "public.users" in sql:
                return [["1", "a@x.com", "Ann", pro(1), auth(1)]]
            m = re.search(r"status IN \(([^)]*)\)", sql)
            wanted = set(re.findall(r"'([a-z_]+)'", m.group(1))) if m else set(status.values())
            return [[rid, "1", "p1", "t1", f"Song {rid}", '[{"name":"Art"}]', "{Mixing}", "10"]
                    for rid, st in status.items() if st in wanted]
        rep, gate = self.run_(mode="apply", query=q)
        self.assertEqual(len(gate.calls), 1)
        _argv, payload = gate.calls[0]
        self.assertEqual([c["request_id"] for c in payload["credits"]], ["ru"])
        db = sqlite3.connect(self.ledger)
        named = " ".join(r[0] or "" for r in db.execute("SELECT request_ids_json FROM verify_messages"))
        self.assertNotIn("rh", named)


class SegmentDailyCapTest(unittest.TestCase):
    """QA #1541: the policy's per-segment daily cap is enforced BY THE RUNNER under its run lock, re-read before every
    send, from the runner's own segment record (the list's paid flag at send time)."""
    setUp = UvnStatusTests.setUp
    write_list = UvnStatusTests.write_list
    run_ = UvnStatusTests.run_
    gate_file = UvnStatusTests.gate_file

    def recs(self):
        p = Path(f"{self.ledger}.segments.jsonl")
        return [json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []

    def test_the_cap_binds_and_every_send_is_recorded_for_its_segment(self):
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in range(1, 8)]
        self.write_list()
        rep, gate = self.run_(max_users=10, query=replica(range(1, 8)), segment_daily_cap=3)
        self.assertEqual(len(gate.calls), 3)
        self.assertEqual([(r["segment"], r["user"], r["n"]) for r in self.recs()], [("paid", "1", 1), ("paid", "2", 1), ("paid", "3", 1)])
        self.assertEqual(uvn_status.segment_sent_today(self.ledger, "uvn-status", "paid", NOW.strftime("%Y-%m-%d")), 3)
        self.assertEqual(uvn_status.segment_sent_today(self.ledger, "uvn-status", "free", NOW.strftime("%Y-%m-%d")), 0)

    def test_slots_another_run_used_after_the_wrappers_read_are_honoured(self):
        # a hand-run batch took 9 of 10 paid slots after the timer's pre-check: this run sends 1, never 10
        day = NOW.strftime("%Y-%m-%d")
        uvn_status.record_segment(self.ledger, "uvn-status", "paid", day, "900", 9)
        uvn_status.record_segment(self.ledger, "uvn-status", "free", day, "901", 50)      # another segment: not counted
        uvn_status.record_segment(self.ledger, "uvn-status", "paid", "2000-01-01", "902", 50)   # another day: not counted
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in range(1, 8)]
        self.write_list()
        rep, gate = self.run_(max_users=10, query=replica(range(1, 8)), segment_daily_cap=10)
        self.assertEqual(len(gate.calls), 1)
        self.assertEqual(rep.over_daily_max > 0, True)

    def test_unrecorded_ledger_sends_count_against_both_segments(self):
        # QA #1541: a hand run WITHOUT --segment-daily-cap sent 8 today (ledger rows, no segment record): unknown
        # segment = charged to this one too; a recorded user's rows are not double counted
        day = NOW.strftime("%Y-%m-%d")
        db = verify_ledger.connect(self.ledger)
        for i in range(8):                                   # the real claim path, as a hand run's gate writes it
            c = verify_ledger.claim(db, campaign="uvn-status", user_key=f"u{800 + i}@x.com", day=day,
                                    request_ids=[f"h{i}"], message_type="email", approved_by="U7RP6HKUZ",
                                    approval_ref="ref", now=NOW, user_id=str(800 + i))
            verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id=str(900 + i))
        db.close()
        uvn_status.record_segment(self.ledger, "uvn-status", "free", day, "800", 1)   # one of them is known (free)
        self.assertEqual(uvn_status.segment_used_today(self.ledger, "uvn-status", "paid", day), 7)
        self.assertEqual(uvn_status.segment_used_today(self.ledger, "uvn-status", "free", day), 8)
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in range(1, 8)]
        self.write_list()
        rep, gate = self.run_(max_users=10, query=replica(range(1, 8)), segment_daily_cap=9)
        self.assertEqual(len(gate.calls), 2)                                        # 9 - 7 unknown-segment sends

    def test_no_cap_records_nothing_and_a_broken_record_fails_closed(self):
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in range(1, 3)]
        self.write_list()
        self.run_(max_users=10, query=replica(range(1, 3)))
        self.assertEqual(self.recs(), [])
        Path(f"{self.ledger}.segments.jsonl").write_text("not json\n")
        with self.assertRaises(ValueError):
            self.run_(max_users=10, query=replica(range(1, 3)), segment_daily_cap=10)


class OpsKillDryRunTest(unittest.TestCase):
    """r5 (10-31 05:19Z) + QA #1564: under the credit-ops-notes kill, uvn-status --mode apply refuses (NO_REPLY), and a
    dry run / --check-recipients for an ELIGIBLE user still runs through the real CLI: exit 0, the gate's dry-run /
    check-recipient action runs for that user, and not one row lands in any verify-ledger table."""
    setUp = UvnStatusTests.setUp
    write_list = UvnStatusTests.write_list
    gate_file = UvnStatusTests.gate_file

    def cli(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("credit_review_cli_kill", ROOT / "scripts" / "credit-review.py")
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)
        return cli

    def rows(self):
        import sqlite3
        db = sqlite3.connect(self.ledger)
        names = [r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")]
        return {n: db.execute(f'SELECT count(*) FROM "{n}"').fetchone()[0] for n in names}

    def run_cli(self, *extra, gate=None, kill=True):
        import contextlib
        import io
        cli = self.cli()
        ks = self.dir / "credit-ops-notes.disabled"
        if kill:
            ks.write_text("")
        gate = gate or FakeGate()
        real = uvn_status.run
        cli.uvn_status.run = lambda **kw: real(**{**kw, "query": self.q, "runner": gate, "wrapper": self.gate_file(),
                                                  "now": NOW, "pace_seconds": 0})
        out = io.StringIO()
        try:
            with mock.patch.object(cli, "CREDIT_OPS_NOTES_KILL_SWITCH", ks), \
                 mock.patch.dict(os.environ, {"CREDIT_REVIEW_LOG": str(self.dir / "run.log")}), \
                 contextlib.redirect_stdout(out):
                rc = cli.main(["--ledger", self.ledger, "uvn-status", "--list", str(self.list), "--segment", "paid",
                               "--proof-on-file", str(self.proof), "--max-users", "10", *extra])
        finally:
            cli.uvn_status.run = real
            ro = verify_ledger.READ_ONLY_PROCESS
            verify_ledger.READ_ONLY_PROCESS = False      # one CLI run per process in prod; reset between tests
        self.last_read_only = ro
        return rc, out.getvalue(), gate

    def test_apply_refuses_under_the_kill(self):
        verify_ledger.connect(self.ledger).close()
        before = self.rows()
        rc, out, gate = self.run_cli("--mode", "apply")
        self.assertEqual((rc, out.strip()), (0, "NO_REPLY"))
        self.assertEqual(gate.calls, [])
        self.assertEqual(self.rows(), before)

    def test_a_dry_run_under_the_kill_runs_the_gate_dry_and_writes_nothing(self):
        verify_ledger.connect(self.ledger).close()
        before = self.rows()
        self.assertTrue(before and not any(before.values()), before)        # every table exists and is empty
        rc, out, gate = self.run_cli("--mode", "dry-run")
        self.assertEqual(rc, 0, out)
        self.assertIn("KILL SWITCH PRESENT", out)
        self.assertIn("no messages are sent and no verify-ledger entries are recorded", out)
        self.assertEqual(sorted({str(p["user"]["id"]) for _, p in gate.calls}), ["1"], out)   # the one eligible paid user (4 has no open row)
        # the runner's dry run is the gate's offline --validate (render only: no Intercom, no ledger) - never a send
        self.assertTrue(all("--validate" in a and "--dry-run" not in a or "--dry-run" in a for a, _ in gate.calls))
        self.assertFalse([a for a, _ in gate.calls if not ({"--validate", "--dry-run", "--check-recipient"} & set(a))])
        self.assertEqual(self.rows(), before)

    def test_a_missing_or_pre_migration_ledger_is_never_created_or_migrated_under_the_kill(self):
        # QA #1564: verify_ledger.connect would create a missing file / ALTER an old one - under the kill it refuses
        import sqlite3
        Path(self.ledger).unlink(missing_ok=True)
        rc, out, gate = self.run_cli("--mode", "dry-run")
        self.assertEqual(rc, 2, out)
        self.assertIn("does not exist", out)
        self.assertFalse(Path(self.ledger).exists())                               # never created
        self.assertEqual(gate.calls, [])
        db = sqlite3.connect(self.ledger)                                           # an OLD ledger: one table, few columns
        db.execute("CREATE TABLE verify_messages (id INTEGER PRIMARY KEY, campaign TEXT)"); db.commit(); db.close()
        before = sqlite3.connect(self.ledger).execute("SELECT sql FROM sqlite_master").fetchall()
        rc, out, gate = self.run_cli("--mode", "dry-run")
        self.assertEqual(rc, 2, out)
        self.assertIn("needs a migration", out)
        self.assertEqual(sqlite3.connect(self.ledger).execute("SELECT sql FROM sqlite_master").fetchall(), before)

    def test_a_ledger_missing_only_an_index_is_refused_untouched_under_the_kill(self):
        # QA #1564 round 2 (reproduced: schema_version 8 -> 9): all columns present, verify_messages_msg dropped
        import sqlite3
        verify_ledger.connect(self.ledger).close()
        db = sqlite3.connect(self.ledger); db.execute("DROP INDEX verify_messages_msg"); db.commit(); db.close()
        snap = lambda: (sqlite3.connect(self.ledger).execute("PRAGMA schema_version").fetchone()[0],
                        sqlite3.connect(self.ledger).execute("SELECT type, name, sql FROM sqlite_master ORDER BY name").fetchall(),
                        Path(self.ledger).read_bytes())
        before = snap()
        rc, out, gate = self.run_cli("--mode", "dry-run")
        self.assertEqual(rc, 2, out)
        self.assertIn("verify_messages_msg", out)
        self.assertEqual(gate.calls, [])
        self.assertEqual(snap(), before)                                            # schema AND bytes unchanged
        with self.assertRaises(verify_ledger.ReadOnlyLedgerError):
            verify_ledger.connect_ro(self.ledger)

    def test_a_schema_change_after_the_precheck_is_still_never_written_under_the_kill(self):
        # QA #1564 round 3: the index disappears AFTER the precheck (another process) - the runner's own opens must
        # not recreate it: every open in the process is read-only once the kill is seen
        import sqlite3
        from unittest import mock
        verify_ledger.connect(self.ledger).close()
        real_run = uvn_status.run
        def drop_then_run(**kw):
            db = sqlite3.connect(self.ledger); db.execute("DROP INDEX verify_messages_msg"); db.commit(); db.close()
            return real_run(**kw)
        with mock.patch.object(uvn_status, "run", drop_then_run):
            rc, out, gate = self.run_cli("--mode", "dry-run")
        self.assertTrue(self.last_read_only)
        self.assertNotEqual(rc, 0, out)
        self.assertEqual(gate.calls, [])
        names = {n for (n,) in sqlite3.connect(self.ledger).execute("SELECT name FROM sqlite_master WHERE type='index'")}
        self.assertNotIn("verify_messages_msg", names)                              # never recreated

    def test_a_path_with_a_question_mark_opens_THAT_file_read_only(self):
        # QA #1564: 'ledger.db?tag' must never become file:ledger.db (writable) - write attempts fail, both files unchanged
        import sqlite3
        d = Path(self.ledger).parent
        plain, odd = str(d / "l2.db"), str(d / "l2.db?tag")
        for f in (plain, odd):
            verify_ledger.connect(f).close()
        before = {f: Path(f).read_bytes() for f in (plain, odd)}
        db = verify_ledger.connect_ro(odd)
        with self.assertRaises(sqlite3.OperationalError):
            db.execute("INSERT INTO verify_messages (campaign, day, status) VALUES ('x', '2026-10-31', 'sent')")
        db.close()
        self.assertEqual({f: Path(f).read_bytes() for f in (plain, odd)}, before)

    def test_the_ledger_cli_readonly_never_writes(self):
        import sqlite3
        Path(self.ledger).unlink(missing_ok=True)
        p = subprocess.run([sys.executable, str(ROOT / "scripts" / "credit_review" / "verify_ledger.py"), "--db", self.ledger,
                            "--readonly", "pending", "--campaign", "uvn-status", "--user-key", "a@x.com", "--day", "2026-10-31",
                            "--request-ids", "r1"], capture_output=True, text=True, timeout=60, check=False)
        self.assertEqual(p.returncode, 0, p.stderr)                                  # a missing ledger reads as empty
        self.assertFalse(Path(self.ledger).exists())                                 # ... and is never created
        import sqlite3
        db = sqlite3.connect(self.ledger)                                            # an OLD ledger is refused, untouched
        db.execute("CREATE TABLE verify_messages (id INTEGER PRIMARY KEY, campaign TEXT)"); db.commit(); db.close()
        before = sqlite3.connect(self.ledger).execute("SELECT sql FROM sqlite_master").fetchall()
        p = subprocess.run([sys.executable, str(ROOT / "scripts" / "credit_review" / "verify_ledger.py"), "--db", self.ledger,
                            "--readonly", "pending", "--campaign", "uvn-status", "--user-key", "a@x.com", "--day", "2026-10-31",
                            "--request-ids", "r1"], capture_output=True, text=True, timeout=60, check=False)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(sqlite3.connect(self.ledger).execute("SELECT sql FROM sqlite_master").fetchall(), before)
        Path(self.ledger).unlink()
        verify_ledger.connect(self.ledger).close()
        p = subprocess.run([sys.executable, str(ROOT / "scripts" / "credit_review" / "verify_ledger.py"), "--db", self.ledger,
                            "--readonly", "pending", "--campaign", "uvn-status", "--user-key", "a@x.com", "--day", "2026-10-31",
                            "--request-ids", "r1"], capture_output=True, text=True, timeout=60, check=False)
        self.assertEqual(p.returncode, 0, p.stderr)                                  # a current ledger reads fine

    def test_check_recipients_under_the_kill_writes_nothing(self):
        verify_ledger.connect(self.ledger).close()
        before = self.rows()
        gate = FakeGate(out="RECIPIENT OK uvn-status initial copy=uvnstatus credits=2")
        rc, out, gate = self.run_cli("--mode", "dry-run", "--check-recipients", gate=gate)
        self.assertEqual(rc, 0, out)
        self.assertIn("KILL SWITCH PRESENT", out)
        self.assertTrue(gate.calls, out)
        self.assertTrue(all("--check-recipient" in a for a, _ in gate.calls), [a for a, _ in gate.calls])
        self.assertEqual(self.rows(), before)


if __name__ == "__main__":
    unittest.main()
