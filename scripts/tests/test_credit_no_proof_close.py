"""C5 `no_proof_after_ask` (Fable [key=paid-to-zero]): the coded policy close, its holds, its ledger rows, and the
executor contract (an apply close row admits through the REAL coded-outcome check; a shadow row never does)."""
from __future__ import annotations

import json
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from credit_review import account_gate  # noqa: E402
from credit_review import fable_executor as fx  # noqa: E402
from credit_review import no_proof_close as npc  # noqa: E402

import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location(
    "credit_review._fx_real_for_no_proof", Path(__file__).resolve().parents[1] / "credit_review" / "fable_executor.py")
fx_real = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = fx_real
_spec.loader.exec_module(fx_real)   # a private copy: the executor test stubs fx.coded_outcome_refusal module-wide

R1 = "11111111-1111-4111-8111-111111111111"
R2 = "22222222-2222-4222-8222-222222222222"
NOW = datetime(2026, 11, 6, 12, 0, tzinfo=timezone.utc)
ALLOW = account_gate.GateResult("allow")


def facts(status="user_verification_needed", uid=42, pop=30, owns=False, deleted=False, source=""):
    return fx.Facts(status=status, user_id=uid, popularity=pop, deleted=deleted, rules={}, metadata_source=source, paid=None,
                    owns_profile=owns)


def ledger(rows, reminders=(("42", "2026-10-29T10:00:00Z", 1, None),)):
    d = tempfile.mkdtemp()
    p = f"{d}/ledger.sqlite3"
    db = sqlite3.connect(p)
    db.execute("CREATE TABLE verify_messages (id INTEGER PRIMARY KEY, campaign TEXT, kind TEXT, status TEXT, "
               "account_id TEXT, sent_at TEXT, created_at TEXT, request_ids_json TEXT, contact_id TEXT, "
               "conversation_id TEXT, last_reply_at TEXT, parent_row INTEGER)")
    for r in rows:
        db.execute("INSERT INTO verify_messages (campaign, kind, status, account_id, sent_at, request_ids_json, "
                   "contact_id, conversation_id, last_reply_at) VALUES (?,?,?,?,?,?,?,?,?)", r)
    for acct, at, parent, ids in reminders:
        db.execute("INSERT INTO verify_messages (campaign, kind, status, account_id, sent_at, parent_row, "
                   "request_ids_json) VALUES ('uvn-status', 'reminder-7', 'sent', ?, ?, ?, ?)",
                   (acct, at, parent, json.dumps(ids) if ids is not None else None))
    db.commit()
    return p, db


ASK = ("uvn-status", "initial", "sent", "42", "2026-10-22T11:00:00Z", json.dumps([R1, R2]), "c-1", "9", None)


class EvaluateTest(unittest.TestCase):
    def run_rule(self, ask=ASK, f=None, docs=(), ic=(), replies=(), anchors=None, gate=ALLOW, now=NOW, reminders=None,
                 paid=frozenset({42})):
        _p, db = ledger([ask], **({} if reminders is None else {"reminders": reminders}))
        asks = npc.latest_asks(db)
        f = f if f is not None else {R1: facts(), R2: facts(status="unverified")}
        anchors = anchors if anchors is not None else {R1: "no_anchor", R2: "no_anchor"}
        return npc.evaluate(now, asks, npc.reminders(db), f, lambda u, k, s: list(docs),
                            lambda c, s: {"docs": list(ic), "replies": list(replies)},
                            anchors, lambda u: gate, paid)

    def test_asked_reminded_nothing_filed_closes_with_the_status_it_read(self):
        rows, _ = self.run_rule()
        self.assertEqual([(r.request_id, r.decision, r.expected_status) for r in rows],
                         [(R1, "close", "user_verification_needed"), (R2, "close", "unverified")])
        self.assertEqual(rows[0].evidence["deadline"], "2026-11-05T11:00:00Z")
        self.assertTrue(rows[0].paid)

    def test_not_due_before_ask_plus_14_days(self):
        rows, skipped = self.run_rule(now=datetime(2026, 11, 5, 10, 59, tzinfo=timezone.utc))
        self.assertEqual((rows, skipped), ([], {"not_due": 2}))

    def test_a_newer_ask_restarts_the_clock(self):
        _p, db = ledger([ASK, ("gap-ask", "initial", "sent", "42", "2026-10-30T09:00:00Z", json.dumps([R1]), "c-1",
                               "9", None)])
        asks = npc.latest_asks(db)
        self.assertEqual((asks[R1].campaign, asks[R2].campaign), ("gap-ask", "uvn-status"))

    def test_claim_asks_and_unsent_rows_are_not_credit_asks(self):
        _p, db = ledger([("claim-proof-ask", "initial", "sent", "42", "2026-10-01T00:00:00Z", json.dumps([R1]), "", "",
                          None),
                         ("uvn-status", "initial", "refused", "42", "2026-10-01T00:00:00Z", json.dumps([R2]), "", "",
                          None)])
        self.assertEqual(npc.latest_asks(db), {})

    def test_every_hold(self):
        cases = [
            ({"docs": ["proof_intake"]}, "proof_on_file"),
            ({"ic": ["intercom_attachment:5"]}, "proof_on_file"),
            ({"ask": ASK[:8] + ("2026-10-25T00:00:00Z",)}, "replied_after_ask"),
            ({"replies": ["intercom_reply:5"]}, "replied_after_ask"),                    # a TEXT reply in Intercom
            ({"reminders": ()}, "no_reminder_yet"),
            ({"reminders": (("42", "2026-10-20T00:00:00Z", 1, None),)}, "no_reminder_yet"),   # BEFORE the ask
            # QA #1536: a reminder about ANOTHER ask / request never satisfies this one
            ({"reminders": (("42", "2026-10-29T10:00:00Z", 99, ["33333333-3333-4333-8333-333333333333"]),)},
             "no_reminder_yet"),
            ({"anchors": {R1: "anchor", R2: "anchor"}}, "dsp_anchor"),
            ({"anchors": {}}, "v9_unread"),
            ({"f": {R1: facts(pop=0), R2: facts(pop=60)}}, "big_or_unknown_popularity"),
            ({"f": {R1: facts(pop=None), R2: facts(source="client")}}, "big_or_unknown_popularity"),
            ({"f": {R1: facts(owns=True), R2: facts(owns=None)}}, "submitter_has_claim_on_profile"),
            ({"f": {R1: facts(uid=7), R2: facts(uid=7)}}, "user_mismatch"),
            ({"gate": account_gate.GateResult("hold", ("x",))}, "account_gate_hold"),
            ({"gate": account_gate.GateResult("allow", ("on the watchlist",))}, "watchlisted_account"),
        ]
        for kw, want in cases:
            rows, _ = self.run_rule(**kw)
            self.assertTrue(rows and all(r.decision == "hold" for r in rows), (kw, rows))
            self.assertTrue(rows[0].reason.startswith(want), (kw, rows[0].reason))

    def test_unreadable_inputs_hold_never_close(self):
        _p, db = ledger([ASK])
        asks = npc.latest_asks(db)
        f = {R1: facts(), R2: facts()}

        def boom(*a):
            raise RuntimeError("down")
        none = {"docs": [], "replies": []}
        for docs, ic, gate in ((boom, lambda c, s: none, lambda u: ALLOW), (lambda u, k, s: [], boom, lambda u: ALLOW),
                               (lambda u, k, s: [], lambda c, s: none, boom)):
            rows, _ = npc.evaluate(NOW, asks, npc.reminders(db), f, docs, ic, {R1: "no_anchor", R2: "no_anchor"},
                                   gate, None)
            self.assertEqual({r.decision for r in rows}, {"hold"})
            self.assertTrue(rows[0].reason.startswith("unknown:"))

    def test_a_reminder_naming_the_request_counts_without_a_parent(self):
        rows, _ = self.run_rule(reminders=(("42", "2026-10-29T10:00:00Z", None, [R1]),))
        self.assertEqual({r.request_id: r.decision for r in rows}, {R1: "close", R2: "hold"})

    def test_decided_or_deleted_requests_get_no_row(self):
        rows, skipped = self.run_rule(f={R1: facts(status="approved"), R2: facts(deleted=True)})
        self.assertEqual(rows, [])
        self.assertEqual(skipped, {"not_open:approved": 1, "not_open:deleted": 1})


class RecordTest(unittest.TestCase):
    def setUp(self):
        self.path, self.db = ledger([ASK])
        npc.ensure_columns(self.db)

    def rows(self, n=2):
        rs = [npc.Row(f"{i:08d}-1111-4111-8111-111111111111", 42, "close", "asked, reminded, nothing filed",
                      "user_verification_needed", 30, True, "allow", "no_anchor", "2026-11-05T11:00:00Z", {"ask_id": 1})
              for i in range(n)]
        return rs

    def test_shadow_rows_carry_the_contract_columns_and_a_shadow_outcome(self):
        rec = npc.record(self.db, "run-1", "shadow", self.rows(2) + [npc.Row(R2, 42, "hold", "no_reminder_yet", "unverified",
                                                                     30, True, "allow", "no_anchor", "d")], NOW)
        self.assertEqual((rec["close"], rec["hold"]), (2, {"no_reminder_yet": 1}))
        got = self.db.execute("SELECT decision, mode, reason_code, evidence_kind, rule_version, expected_status, "
                              "gate_state, v9_anchor FROM decisions ORDER BY id").fetchall()
        self.assertEqual(got[0][:4], ("close", "shadow", "no_proof_after_ask", "no_proof_after_ask"))
        self.assertTrue(got[0][4].startswith("C5:no_proof_after_ask/v1+"))
        self.assertEqual(got[0][5:], ("user_verification_needed", "allow", "no_anchor"))
        self.assertEqual(self.db.execute("SELECT action, outcome FROM decision_outcomes").fetchall(),
                         [("close", "shadow"), ("close", "shadow")])

    def test_a_rerun_never_duplicates_a_close(self):
        npc.record(self.db, "run-1", "shadow", self.rows(2), NOW)
        rec = npc.record(self.db, "run-2", "shadow", self.rows(2), NOW)
        self.assertEqual((rec["close"], rec["duplicate"]), (0, 2))

    def test_apply_caps_closes_per_day_and_holds_the_rest(self):
        rec = npc.record(self.db, "run-1", "apply", self.rows(5), NOW, daily_cap=3)
        self.assertEqual((rec["close"], rec["hold"]), (3, {"daily_cap": 2}))
        rec = npc.record(self.db, "run-2", "apply", [npc.Row(R2, 42, "close", "x", "unverified", 30, True, "allow",
                                                             "no_anchor", "d")], NOW, daily_cap=3)
        self.assertEqual((rec["close"], rec["hold"]), (0, {"daily_cap": 1}))

    def test_decisions_stay_append_only(self):
        npc.record(self.db, "run-1", "shadow", self.rows(1), NOW)
        with self.assertRaises(sqlite3.DatabaseError):
            self.db.execute("UPDATE decisions SET mode = 'apply'")


class ExecutorContractTest(unittest.TestCase):
    """The tray the rule emits loads in the executor, and its rows admit through the REAL coded-outcome check only
    when the ledger row is an apply close for the same request."""

    def test_apply_tray_loads_and_admits_shadow_never_does(self):
        path, db = ledger([ASK])
        npc.ensure_columns(db)
        row = npc.Row(R1, 42, "close", "asked 2026-10-22 (uvn-status), reminded, nothing filed by the deadline",
                      "user_verification_needed", 30, True, "allow", "no_anchor", "d")
        for mode, want in (("apply", None), ("shadow", "coded_outcome_not_apply:shadow")):
            db2 = sqlite3.connect(path)
            rec = npc.record(db2, f"run-{mode}", mode, [row], NOW)
            trays = npc.tray_docs(rec["close_ids"])
            doc = trays["user_verification_needed"]
            f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
            json.dump(doc, f)
            f.close()
            tray = fx.load_tray(f.name)
            self.assertEqual((tray.action, tray.expected_status, tray.rows[0].rule), ("reject", "user_verification_needed",
                                                                                   npc.RULE_ID))
            outcomes = fx_real.ledger_outcomes([tray.rows[0].coded_outcome], path=path)
            self.assertEqual(fx_real.coded_outcome_refusal(tray, tray.rows[0], outcomes), want, mode)


class PublishTest(unittest.TestCase):
    """QA #1536: publication re-checks proof/reply, is exactly once (stable identity, marks before rename, reconcile),
    trays expire, and the cap/duplicate gate is atomic."""

    def setUp(self):
        self.path, self.db = ledger([ASK])
        npc.ensure_columns(self.db)
        self.dir = tempfile.mkdtemp()

    def close_row(self, rid=R1):
        return npc.Row(rid, 42, "close", "asked, reminded, nothing filed by the deadline", "user_verification_needed",
                       30, True, "allow", "no_anchor", "d", {"ask_id": 1, "ask_sent_at": "2026-10-22T11:00:00Z", "contact_id": "c-1"})

    ok = staticmethod(lambda uid, rids, since, contact: "")

    def test_publish_once_with_a_stable_name_and_an_expiry(self):
        npc.record(self.db, "run-1", "apply", [self.close_row()], NOW)
        res = npc.publish(self.db, "run-2", self.dir, NOW, self.ok)
        self.assertEqual(len(res["trays"]), 1)
        doc = json.loads(Path(res["trays"][0]).read_text())
        self.assertEqual(([r["request_id"] for r in doc["rows"]], doc["expires_at"]), ([R1], "2026-11-06T13:00:00Z"))
        self.assertEqual(Path(res["trays"][0]).name, npc.tray_name("user_verification_needed", [1]))
        self.assertEqual(npc.publish(self.db, "run-3", self.dir, NOW, self.ok)["trays"], [])     # never twice
        self.assertFalse(list(Path(self.dir).glob("*.tmp")))
        self.assertEqual(npc.already_decided(self.db, "apply", NOW), {R1})                     # live until expiry

    def test_proof_or_a_reply_since_the_decision_expires_the_close_and_frees_the_request(self):
        npc.record(self.db, "run-1", "apply", [self.close_row()], NOW)
        seen = []

        def changed(uid, rids, since, contact):
            seen.append((uid, rids, since, contact))
            return "replied_after_ask:intercom_reply:7"
        res = npc.publish(self.db, "run-2", self.dir, NOW, changed)
        self.assertEqual((res["trays"], res["expired"]), ([], {"replied_after_ask": 1}))
        self.assertEqual(seen, [(42, [R1], "2026-10-22T11:00:00", "c-1")])
        self.assertEqual(npc.already_decided(self.db, "apply", NOW), set())                    # decided again later
        self.assertEqual(npc.unpublished(self.db), [])

    def test_an_unreadable_recheck_expires_never_publishes(self):
        npc.record(self.db, "run-1", "apply", [self.close_row()], NOW)

        def boom(*a):
            raise RuntimeError("intercom down")
        res = npc.publish(self.db, "run-2", self.dir, NOW, boom)
        self.assertEqual((res["trays"], list(res["expired"])), ([], ["unknown"]))

    def test_a_crash_between_the_marks_and_the_rename_is_reconciled_under_the_same_name(self):
        npc.record(self.db, "run-1", "apply", [self.close_row()], NOW)
        real = npc.os.replace
        npc.os.replace = lambda a, b: (_ for _ in ()).throw(OSError("killed"))
        try:
            with self.assertRaises(OSError):
                npc.publish(self.db, "run-2", self.dir, NOW, self.ok)
        finally:
            npc.os.replace = real
        name = npc.tray_name("user_verification_needed", [1])
        self.assertTrue((Path(self.dir) / (name + ".tmp")).exists())
        res = npc.publish(self.db, "run-3", self.dir, NOW, self.ok)
        self.assertEqual((res["reconciled"], res["trays"]), ([name], []))       # same file, no second tray
        self.assertEqual(sorted(p.name for p in Path(self.dir).iterdir()), [name])

    def test_an_expired_leftover_is_removed_and_its_rows_decided_again(self):
        npc.record(self.db, "run-1", "apply", [self.close_row()], NOW)
        real = npc.os.replace
        npc.os.replace = lambda a, b: (_ for _ in ()).throw(OSError("killed"))
        try:
            with self.assertRaises(OSError):
                npc.publish(self.db, "run-2", self.dir, NOW, self.ok)
        finally:
            npc.os.replace = real
        later = NOW + npc.TRAY_TTL
        res = npc.publish(self.db, "run-3", self.dir, later, self.ok)
        self.assertEqual((res["reconciled"], list(Path(self.dir).iterdir())), ([], []))
        self.assertEqual(npc.already_decided(self.db, "apply", later), set())

    def test_trays_ask_the_executor_for_the_v9_and_evidence_rechecks(self):
        npc.record(self.db, "run-1", "apply", [self.close_row()], NOW)
        path = npc.publish(self.db, "run-2", self.dir, NOW, self.ok)["trays"][0]
        t = fx_real.load_tray(path, now=NOW)
        self.assertEqual((t.refuse_if_dsp_anchor, t.recheck_evidence), (True, "no_proof_after_ask"))

    def test_recheck_decisions_reads_the_rows_own_ask_and_refuses_strangers(self):
        npc.record(self.db, "run-1", "apply", [self.close_row()], NOW)
        npc.record(self.db, "run-1", "shadow", [self.close_row(R2)], NOW)
        seen = []

        def rc(uid, rids, since, contact):
            seen.append((uid, rids, since, contact))
            return ""
        got = npc.recheck_decisions({R1: 1, R2: 2, "33333333-3333-4333-8333-333333333333": 1}, rc, self.path)
        self.assertEqual(got[R1], "")
        self.assertEqual(seen, [(42, [R1], "2026-10-22T11:00:00", "c-1")])
        self.assertTrue(got[R2].startswith("unknown:"))                                      # a shadow row
        self.assertTrue(got["33333333-3333-4333-8333-333333333333"].startswith("unknown:"))  # another request

        def boom(*a):
            raise RuntimeError("down")
        self.assertTrue(npc.recheck_decisions({R1: 1}, boom, self.path)[R1].startswith("unknown:down"))

    def newer_ask(self):
        self.db.execute("INSERT INTO verify_messages (campaign, kind, status, account_id, sent_at, request_ids_json, "
                        "contact_id) VALUES ('gap-ask', 'initial', 'sent', '42', '2026-11-06T12:30:00Z', ?, 'c-1')",
                        (json.dumps([R1]),))
        self.db.commit()

    def test_a_newer_ask_after_the_decision_expires_it_at_publication(self):
        npc.record(self.db, "run-1", "apply", [self.close_row()], NOW)
        self.newer_ask()
        res = npc.publish(self.db, "run-2", self.dir, NOW, self.ok)
        self.assertEqual((res["trays"], res["expired"]), ([], {"newer_ask": 1}))
        self.assertEqual(npc.already_decided(self.db, "apply", NOW), set())

    def test_a_newer_ask_after_publication_refuses_the_row_at_execution(self):
        npc.record(self.db, "run-1", "apply", [self.close_row()], NOW)
        npc.publish(self.db, "run-2", self.dir, NOW, self.ok)
        self.assertEqual(npc.recheck_decisions({R1: 1}, self.ok, self.path), {R1: ""})
        self.newer_ask()
        self.assertEqual(npc.recheck_decisions({R1: 1}, self.ok, self.path), {R1: "newer_ask:3"})

    def test_latest_ask_id_ignores_other_requests_and_unsent_asks(self):
        self.db.execute("INSERT INTO verify_messages (campaign, kind, status, account_id, sent_at, request_ids_json) "
                        "VALUES ('uvn-status', 'initial', 'refused', '42', '2026-11-01T00:00:00Z', ?)", (json.dumps([R1]),))
        self.db.execute("INSERT INTO verify_messages (campaign, kind, status, account_id, sent_at, request_ids_json) "
                        "VALUES ('uvn-status', 'initial', 'sent', '42', '2026-11-01T00:00:00Z', ?)",
                        (json.dumps(["33333333-3333-4333-8333-333333333333"]),))
        self.assertEqual(npc.latest_ask_id(self.db, R1), 1)

    def test_two_publishers_never_put_one_decision_in_two_trays(self):
        """QA #1559 (same race as validator_reject): B publishes after A's slow re-check but before A's lock."""
        npc.record(self.db, "run-1", "apply", [self.close_row()], NOW)
        db_b = sqlite3.connect(self.path, timeout=5)
        b_paths = []

        def recheck_then_race(uid, rids, since, contact):
            if not b_paths:
                b_paths.append(npc.publish(db_b, "run-b", self.dir, NOW, self.ok)["trays"])
            return ""
        a_paths = npc.publish(self.db, "run-a", self.dir, NOW, recheck_then_race)["trays"]
        self.assertEqual((len(b_paths[0]), a_paths), (1, []))              # B took it; A publishes nothing
        self.assertEqual(len(list(Path(self.dir).glob("*.json"))), 1)

    def test_shadow_rows_are_never_published(self):
        npc.record(self.db, "run-1", "shadow", [self.close_row()], NOW)
        self.assertEqual(npc.unpublished(self.db), [])

    def test_the_executor_refuses_an_expired_or_unreadable_tray(self):
        npc.record(self.db, "run-1", "apply", [self.close_row()], NOW)
        path = npc.publish(self.db, "run-2", self.dir, NOW, self.ok)["trays"][0]
        self.assertEqual(fx_real.load_tray(path, now=NOW).rows[0].request_id, R1)
        with self.assertRaisesRegex(fx_real.TrayError, "expired"):
            fx_real.load_tray(path, now=NOW + npc.TRAY_TTL)
        doc = json.loads(Path(path).read_text())
        for bad in ("soon", "2026-11-06T13:00:00"):          # unreadable / no timezone
            Path(path).write_text(json.dumps({**doc, "expires_at": bad}))
            with self.assertRaisesRegex(fx_real.TrayError, "expires_at unreadable"):
                fx_real.load_tray(path, now=NOW)

    def test_two_concurrent_runs_never_overspend_the_cap_or_close_twice(self):
        # the second connection reads its cap/duplicate snapshot inside BEGIN IMMEDIATE, after the first commits
        db2 = sqlite3.connect(self.path, timeout=5)
        rows = [self.close_row(f"{i:08d}-1111-4111-8111-111111111111") for i in range(3)]
        a = npc.record(self.db, "run-a", "apply", rows, NOW, daily_cap=2)
        b = npc.record(db2, "run-b", "apply", rows, NOW, daily_cap=2)
        self.assertEqual((a["close"], b["close"], b["duplicate"]), (2, 0, 2))
        self.assertEqual(b["hold"], {"daily_cap": 1})
        self.assertEqual(self.db.execute("SELECT count(*) FROM decisions WHERE decision='close' AND mode='apply'")
                         .fetchone()[0], 2)

    def test_a_writer_racing_inside_the_gate_is_blocked_so_the_cap_holds(self):
        """The race QA named: run A reads its cap / duplicate snapshot, run B commits closes, A then writes on its
        stale snapshot. With the reads inside BEGIN IMMEDIATE, B cannot commit in between (it times out)."""
        db2 = sqlite3.connect(self.path, timeout=0.2)
        rows_b = [self.close_row(f"{i:08d}-2222-4222-8222-222222222222") for i in range(2)]
        real = npc.applied_today
        raced = []

        def racing(db, now):
            n = real(db, now)
            if not raced:
                raced.append(True)
                try:
                    npc.applied_today = real
                    raced.append(npc.record(db2, "run-b", "apply", rows_b, NOW, daily_cap=2)["close"])
                except sqlite3.OperationalError as exc:
                    raced.append(f"blocked:{exc}")
            return n
        npc.applied_today = racing
        try:
            a = npc.record(self.db, "run-a", "apply", [self.close_row(f"{i:08d}-1111-4111-8111-111111111111")
                                                      for i in range(2)], NOW, daily_cap=2)
        finally:
            npc.applied_today = real
        self.assertTrue(str(raced[1]).startswith("blocked:"), raced)
        self.assertEqual(a["close"], 2)
        self.assertEqual(self.db.execute("SELECT count(*) FROM decisions WHERE decision='close' AND mode='apply'")
                         .fetchone()[0], 2)

    def test_one_run_never_closes_the_same_request_twice(self):
        rec = npc.record(self.db, "run-1", "apply", [self.close_row(), self.close_row()], NOW)
        self.assertEqual((rec["close"], rec["duplicate"]), (1, 1))

    def test_the_write_lock_makes_a_second_writer_wait(self):
        db2 = sqlite3.connect(self.path, timeout=0.2)
        self.db.execute("BEGIN IMMEDIATE")
        try:
            with self.assertRaises(sqlite3.OperationalError):
                npc.record(db2, "run-b", "apply", [self.close_row()], NOW)
        finally:
            self.db.rollback()


class IntercomReadTest(unittest.TestCase):
    SINCE = "2026-10-22T11:00:00"
    T0 = int(datetime(2026, 10, 22, 11, tzinfo=timezone.utc).timestamp())

    def ic(self, parts, total=None):
        def call(method, path, body):
            if method == "POST":
                return {"conversations": [{"id": "7"}], "total_count": total or 1}
            return {"source": {"author": {"type": "admin"}, "created_at": self.T0 - 10},
                    "conversation_parts": {"conversation_parts": parts}}
        return call

    def test_a_text_reply_after_the_ask_is_a_reply_not_a_document(self):
        got = npc.intercom_read("c", self.SINCE, self.ic([{"author": {"type": "user"}, "created_at": self.T0 + 60,
                                                           "body": "what do you need from me?"}]))
        self.assertEqual(got, {"docs": [], "replies": ["intercom_reply:7"]})

    def test_an_attachment_is_both_and_older_or_admin_parts_are_ignored(self):
        got = npc.intercom_read("c", self.SINCE, self.ic([
            {"author": {"type": "user"}, "created_at": self.T0 - 60, "body": "old"},
            {"author": {"type": "admin"}, "created_at": self.T0 + 60, "body": "our reminder"},
            {"author": {"type": "user"}, "created_at": self.T0 + 90, "body": "", "attachments": [{"url": "x"}]}]))
        self.assertEqual(got, {"docs": ["intercom_document:7"], "replies": ["intercom_reply:7"]})
        self.assertEqual(npc.intercom_read("c", self.SINCE, self.ic([{"author": {"type": "admin"},
                                                                      "created_at": self.T0 + 5}])),
                         {"docs": [], "replies": []})

    def test_a_user_message_before_the_ask_is_not_a_reply(self):
        got = npc.intercom_read("c", self.SINCE, self.ic([{"author": {"type": "user"}, "created_at": self.T0 - 1,
                                                           "body": "here is my proof https://drive.google.com/x"}]))
        self.assertEqual(got, {"docs": [], "replies": []})

    def test_too_many_conversations_reads_as_replied_and_no_contact_raises(self):
        self.assertEqual(npc.intercom_read("c", self.SINCE, self.ic([], total=500), conv_cap=60)["replies"],
                         ["intercom:more_conversations_than_checked"])
        with self.assertRaises(RuntimeError):
            npc.intercom_read("", self.SINCE, self.ic([]))


class ApplyGateTest(unittest.TestCase):
    def test_apply_is_refused_until_the_policy_is_flipped_with_a_closing_line(self):
        ok = {"apply_enabled": True, "approved_by": "fable", "approval_ref": "x", "closing_line_campaign": "c"}
        self.assertIsNone(npc.apply_refusal(ok, kill_files=()))
        for broken in ({**ok, "apply_enabled": False}, {**ok, "approved_by": None},
                       {**ok, "closing_line_campaign": None}, {}):
            self.assertIsNotNone(npc.apply_refusal(broken, kill_files=()))
        d = tempfile.mkdtemp()
        Path(f"{d}/k").write_text("")
        self.assertIn("kill file", npc.apply_refusal(ok, kill_files=(f"{d}/k",)))

    def test_the_shipped_policy_is_shadow_only(self):
        self.assertIn("apply_enabled", npc.apply_refusal(npc.policy(), kill_files=()))


if __name__ == "__main__":
    unittest.main()
