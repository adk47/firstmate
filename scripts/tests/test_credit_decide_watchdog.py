"""[key=doc-approval-doctrine] The doc-verified T0/T1 class's two ruled alerts.

Fable d2's build list for the class names exactly two:

  * the decider approved **0 in 6 h while eligible > 0**
  * **dv-4 verified single-candidate docs with no approved_refs > 24 h**

Both are read-only and both are gated on the class being ARMED. Every test here builds
its own doc-verify store, proof store and ledger, so nothing touches prod.
"""
from __future__ import annotations

import importlib.util
import json
import sqlite3
import sys
import unittest
from unittest import mock
from datetime import datetime, timedelta, timezone
from pathlib import Path
from tempfile import TemporaryDirectory

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from credit_review import account_gate, admin as admin_api, decide, doc_approve, doc_measure  # noqa: E402

UTC = timezone.utc
NOW = datetime(2026, 11, 4, 18, 0, tzinfo=UTC)


def _load(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


WD = _load(Path(__file__).resolve().parents[1] / "credit-decide-watchdog.py", "credit_decide_watchdog")

R1, R2, R3 = "4bec612c-1111-2222-3333-444444444444", "52bf322f-1111-2222-3333-444444444444", \
             "ee3230af-1111-2222-3333-444444444444"


#: A dv-4 detail that passes the forensics and cross-check gates: a NAMED issuer and signatory with
#: confidence, and the cross-check verdicts the class requires. The watchdog measures through the
#: decider's own gates now, so its fixtures have to carry what those gates read.
_DETAIL = json.dumps({
    "h3": "PLAUSIBLE",
    "checks": {"xc_dsp": "positive", "xc_isrc": "positive", "xc_label": "unknown",
               "xc_domain": "skipped", "xc_signatory": "unknown"},
    "issuer": {"name": "Label Ltd", "type": "label", "confidence": 0.9},
    "signatory": {"name": "A Person", "title": "Head of A&R", "confidence": 0.9},
})


class _Allow:
    """What `account_gate.check` returns for a clean account."""

    allowed = True

    @staticmethod
    def why() -> str:
        return ""


def _doc_store(path: Path, *, rows: list[tuple[str, str, str, str, int]],
               proof_store: Path | None = None) -> None:
    """rows: (intake_id, request_id, outcome, at, user_id) in dv_outcomes (dv-4)."""
    db = sqlite3.connect(path)
    # the real dv_outcomes shape: the newest run is the highest row id, and every role of that run
    # (here one row per document) has to be `verified`
    db.executescript("""
        CREATE TABLE dv_outcomes (id INTEGER PRIMARY KEY AUTOINCREMENT, intake_id TEXT, request_id TEXT,
                                  run_id TEXT, user_id INTEGER, proof_id TEXT, role TEXT, outcome TEXT,
                                  account_hold INTEGER DEFAULT 0, at TEXT, version TEXT,
                                  h3_verdict TEXT, detail_json TEXT);
    """)
    pdb = sqlite3.connect(proof_store or path)
    # the real proof_intake columns the measurement reads: `user_id` (the filing's account) and
    # `subject` ('credit' | 'claim' - a claim filing is not a credit document).
    pdb.executescript("CREATE TABLE IF NOT EXISTS proof_intake (intake_id TEXT, user_id INTEGER,"
                      " subject TEXT, candidate_request_ids_json TEXT, file_sha256 TEXT);")
    for intake, rid, outcome, at, uid in rows:
        db.execute("INSERT INTO dv_outcomes (intake_id, request_id, run_id, user_id, proof_id, role,"
                   " outcome, account_hold, at, version, h3_verdict, detail_json)"
                   " VALUES (?,?,?,?,?,?,?,0,?,?,?,?)",
                   (intake, rid, f"run-{intake}", uid, f"sha-{intake}", "producer", outcome, at,
                    "dv-4", "PLAUSIBLE", _DETAIL))
        pdb.execute("INSERT INTO proof_intake VALUES (?,?,?,?,?)",
                    (intake, uid, "credit", json.dumps([rid]), f"sha-{intake}"))
    db.commit()
    db.close()
    pdb.commit()
    pdb.close()


def _decisions(path: Path, popularity: dict[str, int | None], *, profile_id: str = "prof-1") -> None:
    """The decider's `decisions` rows the shadow plan reads its popularity and profile from.

    `gate_tier` refuses a row whose popularity is unknown, so a shadow test that wants to exercise
    the CAPS has to supply one - otherwise the plan is empty for a reason unrelated to the caps.
    """
    db = sqlite3.connect(path)
    for rid, pop in popularity.items():
        # `decisions` is APPEND-ONLY (a trigger refuses UPDATE and DELETE), so this appends a newer
        # row - and it copies the OWNER from the row `self._docs` wrote, because a second row with a
        # different account would make the document's binding span two accounts.
        db.execute("INSERT INTO decisions (run_id, request_id, user_id, profile_id, popularity,"
                   " big_track, claimed_roles, decided_at, decision, reason, mode)"
                   " SELECT 'r2', request_id, user_id, ?, ?, big_track, claimed_roles, ?,"
                   " 'support', 'fixture', 'apply' FROM decisions WHERE request_id = ?"
                   " ORDER BY id DESC LIMIT 1",
                   (profile_id, pop, doc_approve.utc(NOW - timedelta(days=40)), rid))
    db.commit()
    db.close()


def _approvals(path: Path, rows: list[tuple[int, str, str]]) -> None:
    """`doc_approvals` rows already spent today: (user_id, profile_id, approved_at)."""
    db = sqlite3.connect(path)
    for i, (uid, pid, at) in enumerate(rows):
        db.execute("INSERT INTO doc_approvals (request_id, user_id, profile_id, intake_id, proof_id,"
                   " ref, tier, approved_at, expires_at, state)"
                   " VALUES (?, ?, ?, ?, ?, ?, 'T0', ?, ?, 'provisional')",
                   (f"spent-{i}", uid, pid, f"spent-{i}", f"sha-{i}", f"spent-{i}", at, at))
    db.commit()
    db.close()


def _registry(path: Path, *, approved: bool) -> None:
    path.write_text(json.dumps({"automations": {decide.DOC_AUTOMATION: {
        "approved": approved, "approved_by": "Fable" if approved else None,
        "approval_ref": "d2 2026-11-03 19:30Z" if approved else None}}}), encoding="utf-8")


class Base(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.doc_store = self.dir / "doc-verify.sqlite"
        self.proof_store = self.dir / "proof.sqlite"
        sqlite3.connect(self.proof_store).close()
        self.ledger = self.dir / "ledger.sqlite"
        db = sqlite3.connect(self.ledger)
        # the decider's own schema too: the watchdog measures through `doc_measure`, which reads
        # `decisions` for popularity/owner/roles. A ledger without it is not the decider's ledger.
        decide.ensure_schema(db)
        doc_approve.ensure_schema(db)
        db.close()
        self.registry = self.dir / "registry.json"
        _registry(self.registry, approved=True)
        # The watchdog measures through the decider's own gates, and `gate_claimant` needs core's
        # `user.createdAt` - which a test cannot fetch. Every fixture account is 60 days old at core.
        self.core_age = (NOW - timedelta(days=60)).strftime("%Y-%m-%dT%H:%M:%SZ")
        self._ages = mock.patch.object(doc_measure, "core_ages",
                                       side_effect=lambda _admin, row_map, **_kw:
                                       {rid: self.core_age for rid in row_map})
        self._ages.start()
        # the fraud-lens account gate is a live check; a fixture account is an allow.
        self._gate = mock.patch.object(account_gate, "Cached",
                                       return_value=lambda _uid: _Allow())
        self._gate.start()
        # qa-review #1766 r4 finding 2: `gate_not_frozen` reads the class's freeze marker, and the
        # default path is a REAL host path. On a host where the class is legitimately frozen (node-8
        # during the QA run) every fixture row was refused `not_frozen` and 15 of 42 tests failed,
        # while the same suite passed on a host without the marker. A suite whose result depends on
        # host state cannot validate the alert on the host that runs it, so the marker is pinned to a
        # path inside this fixture's temp dir - absent, so the class is unfrozen for every case.
        self.freeze = self.dir / "doc-approve.frozen"
        self._freeze = mock.patch.object(doc_approve, "FREEZE_PATH", self.freeze)
        self._freeze.start()

    def tearDown(self) -> None:
        self._freeze.stop()
        self._gate.stop()
        self._ages.stop()
        self.tmp.cleanup()

    def _decide(self, rid: str, user_id: int, *, popularity: int | None = 12,
                profile_id: str = "prof-1", roles: str = "producer") -> None:
        """The ledger row the decider's gates read for a request (popularity, owner, roles)."""
        db = sqlite3.connect(self.ledger)
        db.execute("INSERT INTO decisions (run_id, request_id, user_id, profile_id, popularity,"
                   " big_track, claimed_roles, decided_at, decision, reason, mode)"
                   " VALUES ('r1', ?, ?, ?, ?, 0, ?, ?, 'support', 'fixture', 'apply')",
                   (rid, user_id, profile_id, popularity, roles,
                    doc_approve.utc(NOW - timedelta(days=40))))
        db.commit()
        db.close()

    def _docs(self, rows, **kw) -> None:
        """The doc store AND the ledger rows the decider's gates need for those documents."""
        _doc_store(self.doc_store, proof_store=self.proof_store, rows=rows)
        for _intake, rid, _outcome, _at, uid in rows:
            self._decide(rid, uid, **kw)

    def evaluate(self, now: datetime = NOW) -> dict:
        return WD.evaluate(now=now, ledger=self.ledger, doc_store=self.doc_store,
                           proof_store=self.proof_store, registry=self.registry)

    def approve(self, rid: str, at: datetime, *, state: str = "provisional") -> None:
        db = sqlite3.connect(self.ledger)
        doc_approve.ensure_schema(db)
        db.execute("INSERT INTO doc_approvals (request_id, user_id, intake_id, proof_id, ref, popularity, tier,"
                   " approved_at, expires_at, state) VALUES (?,?,?,?,?,?,?,?,?,?)",
                   (rid, 145833, "i-1", "sha", f"dv4:sha:i-1", 12, "T0",
                    doc_approve.utc(at), doc_approve.utc(at + timedelta(days=7)), state))
        db.commit()
        db.close()


class Hermeticity(Base):
    def test_the_suite_does_not_read_the_HOSTS_freeze_marker(self):
        """qa-review #1766 r4 finding 2, pinned: the fixture's freeze path is its own, and absent.

        Without this the suite's verdict depends on whether the host happens to have the class
        frozen - which is exactly the state the alert exists to report, so the one host that most
        needs the test to run is the one where it silently fails.
        """
        self.assertEqual(doc_approve.FREEZE_PATH, self.freeze)
        self.assertFalse(self.freeze.exists())
        self.assertNotEqual(Path(doc_approve.FREEZE_PATH), Path(doc_approve.DEFAULT_FREEZE_PATH))
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=2)), 1)])
        self.assertEqual(self.evaluate()["eligible"], 1,
                         "an absent fixture marker must leave the class unfrozen")

    def test_a_FROZEN_class_is_still_measured_as_frozen(self):
        """The pin must not make the freeze invisible: a marker at the fixture path still refuses."""
        self.freeze.write_text("frozen by a fixture\n")
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=2)), 1)])
        self.assertEqual(self.evaluate()["eligible"], 0)


class ZeroApprovalsAlert(Base):
    def test_armed_eligible_and_no_approval_in_6h_fires(self):
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=2)), 1)])
        res = self.evaluate()
        self.assertTrue(res["armed"])
        self.assertEqual(res["eligible"], 1)
        self.assertEqual([a["key"] for a in res["alerts"]], ["approved_0_in_6h"])

    def test_an_approval_inside_the_6h_window_silences_it(self):
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=2)), 1)])
        self.approve(R1, NOW - timedelta(hours=1))
        res = self.evaluate()
        self.assertEqual(res["approved_6h"], 1)
        self.assertEqual(res["alerts"], [])

    def test_an_approval_older_than_the_window_does_not_count(self):
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=2)), 1)])
        self.approve(R2, NOW - timedelta(hours=7))
        res = self.evaluate()
        self.assertEqual(res["approved_6h"], 0)
        self.assertEqual([a["key"] for a in res["alerts"]], ["approved_0_in_6h"])

    def test_a_released_slot_is_not_an_approval(self):
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=2)), 1)])
        self.approve(R1, NOW - timedelta(hours=1), state="released")
        self.assertEqual(self.evaluate()["approved_6h"], 0)

    def test_nothing_eligible_never_pages(self):
        self._docs([])
        res = self.evaluate()
        self.assertEqual(res["eligible"], 0)
        self.assertEqual(res["alerts"], [])


class StaleEligibleAlert(Base):
    def test_verified_over_24h_with_no_ref_fires(self):
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=25)), 1)])
        res = self.evaluate()
        # both fire: nothing was approved in the window either
        self.assertEqual(sorted(a["key"] for a in res["alerts"]),
                         ["approved_0_in_6h", "verified_no_ref_over_24h"])
        stale = [a for a in res["alerts"] if a["key"] == "verified_no_ref_over_24h"][0]
        self.assertEqual(stale["requests"], [R1])

    def test_a_standing_ref_clears_it(self):
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=25)), 1)])
        self.approve(R1, NOW - timedelta(hours=20))
        res = self.evaluate()
        self.assertEqual(res["stale"], 0)
        # A request with a standing ref is not WAITING, so it is not in the eligible set at all and
        # neither alert fires: the class has already acted on it.
        self.assertEqual(res["eligible"], 0)
        self.assertEqual(res["alerts"], [])

    def test_verified_within_24h_is_not_stale_yet(self):
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=2)), 1)])
        self.assertEqual(self.evaluate()["stale"], 0)

    def test_a_contradicted_document_is_not_eligible_at_all(self):
        self._docs([("i-1", R1, "contradicted", doc_approve.utc(NOW - timedelta(hours=40)), 1)])
        res = self.evaluate()
        self.assertEqual(res["eligible"], 0)
        self.assertEqual(res["alerts"], [])

    def test_a_document_binding_two_requests_of_ONE_user_makes_BOTH_eligible(self):
        """2026-11-04 ruling: the binding is per request, so a document may prove several credits of
        the same person - and the alert counts REQUESTS, one per binding."""
        self._docs([
            ("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1),
            ("i-1", R2, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1)])
        db = sqlite3.connect(self.proof_store)
        db.execute("UPDATE proof_intake SET candidate_request_ids_json = ?", (json.dumps([R1, R2]),))
        db.commit()
        db.close()
        res = self.evaluate()
        self.assertEqual(res["eligible"], 2)
        self.assertEqual(res["eligible_users"], 1)

    def test_a_document_whose_bindings_span_TWO_accounts_is_not_eligible(self):
        self._docs([
            ("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1),
            ("i-1", R2, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 2)])
        db = sqlite3.connect(self.proof_store)
        db.execute("UPDATE proof_intake SET candidate_request_ids_json = ?", (json.dumps([R1, R2]),))
        db.commit()
        db.close()
        res = self.evaluate()
        self.assertEqual(res["eligible"], 0)

    def test_the_shadow_report_counts_users_and_requests_under_the_caps(self):
        rows = [("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1)]
        rows += [("i-1", f"r-{i}", "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1)
                 for i in range(40)]
        self._docs(rows)
        db = sqlite3.connect(self.proof_store)
        db.execute("UPDATE proof_intake SET candidate_request_ids_json = ?",
                   (json.dumps([R1] + [f"r-{i}" for i in range(40)]),))
        db.commit()
        db.close()
        # the tier line needs a popularity for every row, or `gate_tier` refuses it and the plan is
        # empty for a reason that has nothing to do with the caps (QA #1766 r1 finding 5).
        _decisions(self.ledger, {R1: 12, **{f"r-{i}": 12 for i in range(40)}})
        res = self.evaluate()
        sh = res["shadow"]
        self.assertEqual(sh["would_users"], 1)
        self.assertEqual(sh["would_requests"], doc_approve.PER_USER_DAILY_MAX)   # 5 of 41 (R22)
        self.assertEqual(sh["rolled_to_tomorrow"], 41 - doc_approve.PER_USER_DAILY_MAX)
        # while SHADOW this is the daily measurement; the moment the class is armed the two
        # throughput alerts are the measurement and this line stands down.
        line = WD.render_shadow({**res, "armed": False})
        self.assertIn("SHADOW", line)
        self.assertIn(f"{doc_approve.PER_USER_DAILY_MAX} request(s)", line)
        self.assertIn(f"{doc_approve.PER_PROFILE_DAILY_MAX}/profile", line)
        self.assertEqual(WD.render_shadow({**res, "armed": True}), "NO_REPLY")

    def test_the_shadow_report_SHOWS_the_tier_split_and_never_calls_zero_unknown(self):
        """l1 / Fable 553: the class's stated basis is "0 < 60 reads as T0", and `0` is falsy in Python.
        A reader of the shadow line must be able to tell a zero-popularity track tiered T0 (known and
        small) from one whose popularity could not be read - and only the latter is "unknown"."""
        rows = [(f"i-{i}", f"r-{i}", "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1)
                for i in range(3)]
        self._docs(rows)
        db = sqlite3.connect(self.proof_store)
        for i in range(3):
            db.execute("UPDATE proof_intake SET candidate_request_ids_json = ? WHERE intake_id = ?",
                       (json.dumps([f"r-{i}"]), f"i-{i}"))
        db.commit()
        db.close()
        _decisions(self.ledger, {"r-0": 0, "r-1": 41, "r-2": None})
        res = self.evaluate()
        sh = res["shadow"]
        # QA #1766 r1 finding 5: popularity 0 is REFUSED by `gate_tier` (R22a D1), so it is not a
        # T0 row and must not be counted as one. Only the 41-popularity row survives the tier line.
        self.assertEqual(sh["tiers"], {"T0": 0, "T1": 1, "unknown": 0}, sh["tiers"])
        self.assertEqual(sh["tier_refused"], 2, "popularity 0 and an unreadable popularity")
        self.assertEqual(sh["zero_popularity_refused"], 1)
        line = WD.render_shadow({**res, "armed": False})
        self.assertIn("T1 1", line)
        self.assertIn("2 refused by the tier line, of which 1 at popularity 0", line)
        self.assertIn("A popularity of 0 is REFUSED by the tier line", line)


class DormantTest(Base):
    def test_an_unapproved_registry_entry_pages_nothing_but_still_counts(self):
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1)])
        _registry(self.registry, approved=False)
        res = self.evaluate()
        self.assertFalse(res["armed"])
        self.assertEqual(res["eligible"], 1)
        self.assertEqual(res["stale"], 1)
        self.assertEqual(res["alerts"], [])
        self.assertIn("dormant", res["why"])

    def test_the_kill_switch_alone_dormants_it(self):
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1)])
        kill = self.dir / "kill"
        kill.write_text("")
        import os
        old = os.environ.get("CREDIT_DOC_APPROVE_KILL_SWITCH")
        os.environ["CREDIT_DOC_APPROVE_KILL_SWITCH"] = str(kill)
        try:
            res = self.evaluate()
        finally:
            if old is None:
                os.environ.pop("CREDIT_DOC_APPROVE_KILL_SWITCH", None)
            else:
                os.environ["CREDIT_DOC_APPROVE_KILL_SWITCH"] = old
        self.assertFalse(res["armed"])
        self.assertEqual(res["alerts"], [])


class RenderTest(Base):
    def test_no_reply_when_dormant(self):
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1)])
        _registry(self.registry, approved=False)
        self.assertEqual(WD.render(self.evaluate()), "NO_REPLY")

    def test_no_reply_when_healthy(self):
        self._docs([])
        self.assertEqual(WD.render(self.evaluate()), "NO_REPLY")

    def test_one_line_per_firing_alert(self):
        self._docs([
            ("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1),
            ("i-2", R2, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 2)])
        out = WD.render(self.evaluate())
        self.assertEqual(len(out.splitlines()), 2)
        for line in out.splitlines():
            self.assertIn("doc-verified T0/T1 class", line)

    def test_an_unreadable_store_never_reports_a_healthy_class(self):
        """QA #1766 r1 finding 6: it used to return NO_REPLY and exit 0, so a missing or corrupt
        store after arming left every tick blind while the watcher looked quiet."""
        res = self.evaluate()          # doc store file never created
        self.assertTrue(res["unreadable"])
        self.assertEqual(res["alerts"], [])
        out = WD.render(res)
        self.assertNotEqual(out, "NO_REPLY", "a blind watchdog must PAGE, not go quiet")
        self.assertIn("BLIND", out)
        self.assertIn("doc-verify store could not be read", out)

    def test_an_unreadable_store_makes_the_SHADOW_report_say_UNKNOWN_not_zero(self):
        res = self.evaluate()
        out = WD.render_shadow({**res, "armed": False})
        self.assertNotEqual(out, "NO_REPLY")
        self.assertIn("UNKNOWN, not zero", out)


class CliTest(Base):
    def test_json_mode_reports_the_evaluation(self):
        import io
        from contextlib import redirect_stdout
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1)])
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = WD.main(["--json", "--now", "2026-11-04T18:00:00Z", "--ledger", str(self.ledger),
                          "--doc-verify-store", str(self.doc_store), "--proof-store", str(self.proof_store),
                          "--registry", str(self.registry)])
        self.assertEqual(rc, 0)
        res = json.loads(buf.getvalue())
        self.assertEqual(res["eligible"], 1)
        self.assertEqual(sorted(a["key"] for a in res["alerts"]),
                         ["approved_0_in_6h", "verified_no_ref_over_24h"])

    def test_a_bad_now_is_an_error_not_a_default(self):
        with self.assertRaises(SystemExit):
            WD.main(["--now", "not-a-time"])

    def test_a_maintenance_window_stands_down_without_evaluating(self):
        """A planned window stops the scheduled jobs on purpose, so "0 approvals in 6h" is the
        window talking, not a stalled decider. The evaluation must not even run."""
        import io
        from contextlib import redirect_stdout
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1)])
        buf = io.StringIO()
        with mock.patch.object(WD, "_maintenance_active", return_value=True), \
                mock.patch.object(WD, "evaluate") as ev, redirect_stdout(buf):
            rc = WD.main(["--now", "2026-11-04T18:00:00Z", "--ledger", str(self.ledger),
                          "--doc-verify-store", str(self.doc_store),
                          "--proof-store", str(self.proof_store), "--registry", str(self.registry)])
        self.assertEqual(rc, 0)
        self.assertEqual(buf.getvalue().strip(), "NO_REPLY")
        ev.assert_not_called()

    def test_json_mode_still_evaluates_during_a_maintenance_window(self):
        """A human asking for the numbers during a window wants the numbers."""
        import io
        from contextlib import redirect_stdout
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1)])
        buf = io.StringIO()
        with mock.patch.object(WD, "_maintenance_active", return_value=True), \
                redirect_stdout(buf):
            rc = WD.main(["--json", "--now", "2026-11-04T18:00:00Z", "--ledger", str(self.ledger),
                          "--doc-verify-store", str(self.doc_store),
                          "--proof-store", str(self.proof_store), "--registry", str(self.registry)])
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(buf.getvalue())["eligible"], 1)


class CronWiring(unittest.TestCase):
    """The two cron entries this PR adds, checked against the file they actually live in.

    openclaw keys a cron job by `id`, so two entries sharing one id are ONE job: the second
    silently replaces the first and the hourly alert never runs. `credit-jan-tray-dm.bats`
    asserts id-uniqueness for the whole file, but that is an unrelated suite - this PR owns
    its own invariant, and it caught a real duplicate here (both watchdog entries shipped
    with `c1d2e3f4-05a6-5b7c-8d9e-0f1a2b3c4d5e`).
    """

    @classmethod
    def setUpClass(cls):
        cls.jobs = json.loads((Path(__file__).resolve().parents[2]
                               / "cron-jobs.json").read_text())["jobs"]

    def test_every_cron_id_is_unique(self):
        ids = [j["id"] for j in self.jobs]
        dupes = sorted({i for i in ids if ids.count(i) > 1})
        self.assertEqual(dupes, [], "two cron jobs sharing an id are one job: the second wins")

    def test_the_two_watchdog_entries_are_distinct_jobs(self):
        mine = {j["name"]: j for j in self.jobs if j["name"].startswith("credit-decide-watchdog")}
        self.assertEqual(sorted(mine), ["credit-decide-watchdog-hourly",
                                        "credit-decide-watchdog-shadow-daily"])
        self.assertNotEqual(mine["credit-decide-watchdog-hourly"]["id"],
                            mine["credit-decide-watchdog-shadow-daily"]["id"])
        self.assertEqual(mine["credit-decide-watchdog-hourly"]["schedule"]["expr"], "17 * * * *")
        self.assertEqual(mine["credit-decide-watchdog-shadow-daily"]["schedule"]["expr"],
                         "17 7 * * *")
        for job in mine.values():
            self.assertEqual(job["payload"]["argv"][:2],
                             ["bash", "/opt/hydra/scripts/credit-decide-watchdog.sh"])
            self.assertEqual(job["delivery"]["mode"], "none",
                             "a read-only alert posts through the wrapper, never a cron delivery")


class QaR1(Base):
    """QA #1766 r1: the ledger default, the backlog naming, and the shadow plan's caps."""

    def test_the_ledger_default_is_the_DECIDERS_ledger(self):
        """Finding 3: this module hardcoded `/var/lib/hydra-credit-review/ledger.sqlite`, a path the
        decider has never written. `_ro` returns None for a missing file, so a live class with real
        approvals read as "0 approvals, no standing refs" and paged a false stall every hour."""
        from credit_review import ledger as _ledger
        self.assertEqual(WD.LEDGER_DEFAULT, Path(_ledger.DEFAULT_PATH))
        self.assertNotIn("hydra-credit-review", str(WD.LEDGER_DEFAULT),
                         "the decider's ledger is /var/lib/hydra/credit-review/ledger.sqlite3")

    def test_the_no_override_cron_path_reads_the_deciders_ledger(self):
        """The cron passes no --ledger, so the default is the only path it ever uses."""
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1)])
        _registry(self.registry, approved=True)
        _decisions(self.ledger, {R1: 12})
        _approvals(self.ledger, [(1, "prof-1", doc_approve.utc(NOW - timedelta(hours=1)))])
        with mock.patch.object(WD, "LEDGER_DEFAULT", self.ledger):
            res = WD.evaluate(now=NOW, doc_store=self.doc_store, proof_store=self.proof_store,
                              registry=self.registry)
        self.assertEqual(res["approved_6h"], 1,
                         "the default ledger is the one the decider writes, so its approvals count")

    def test_the_stall_alert_counts_the_DECIDERS_eligible_set_not_a_smaller_one(self):
        """Finding 4: `eligible` was only `gate_one_request`, so a class whose documents all fail
        forensics/tier/claimant paged a stalled-decider alert every hour. It is now the decider's own
        read-only verdict, and `per_guard` says which gate refused what."""
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1)])
        _registry(self.registry, approved=True)
        res = self.evaluate()
        self.assertEqual(res["eligible"], 1)
        self.assertEqual(res["per_guard"], {"would_approve": 1})
        self.assertIn("pass every row gate", res["alerts"][0]["text"])

    def test_a_document_that_fails_a_LATER_gate_is_not_eligible_and_does_not_page(self):
        """The carried-forward case: zero approvals is CORRECT when every document fails a gate the
        old watchdog never asked, so paging a stalled decider would be a false alarm."""
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1)],
                   popularity=0)          # `gate_tier` refuses popularity 0 (R22a D1)
        res = self.evaluate()
        self.assertEqual(res["eligible"], 0)
        self.assertEqual(res["per_guard"], {"tier": 1})
        self.assertEqual(res["alerts"], [])

    def test_the_shadow_plan_counts_the_slots_ALREADY_SPENT_today(self):
        """Finding 5: the plan started from an empty day, so 49 users already approved today still
        reported 50 more. `plan_caps` simulates today's ledger, so only ONE new user fits."""
        rows = [(f"i-{i}", f"r-{i}", "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1000 + i)
                for i in range(2)]
        self._docs(rows)
        db = sqlite3.connect(self.proof_store)
        for i in range(2):
            db.execute("UPDATE proof_intake SET candidate_request_ids_json = ? WHERE intake_id = ?",
                       (json.dumps([f"r-{i}"]), f"i-{i}"))
        db.commit()
        db.close()
        _decisions(self.ledger, {f"r-{i}": 12 for i in range(2)})
        _approvals(self.ledger, [(900 + i, f"prof-{i}", doc_approve.utc(NOW - timedelta(hours=2)))
                                 for i in range(doc_approve.DAILY_USER_CAP - 1)])
        sh = self.evaluate()["shadow"]
        self.assertEqual(sh["spent_users_today"], doc_approve.DAILY_USER_CAP - 1)
        self.assertEqual(sh["would_users"], 1, "one slot is left under the 50-user day cap")
        self.assertEqual(sh["would_requests"], 1)
        self.assertEqual(sh["rolled_to_tomorrow"], 1, "the second user rolls, it is not dropped")

    def test_the_shadow_plan_respects_the_PER_PROFILE_cap(self):
        """Finding 5: the 10/profile cap was not applied at all."""
        rows = [(f"i-{i}", f"r-{i}", "verified", doc_approve.utc(NOW - timedelta(hours=40)), 2000 + i)
                for i in range(3)]
        self._docs(rows)
        db = sqlite3.connect(self.proof_store)
        for i in range(3):
            db.execute("UPDATE proof_intake SET candidate_request_ids_json = ? WHERE intake_id = ?",
                       (json.dumps([f"r-{i}"]), f"i-{i}"))
        db.commit()
        db.close()
        _decisions(self.ledger, {f"r-{i}": 12 for i in range(3)}, profile_id="prof-shared")
        _approvals(self.ledger, [(3000 + i, "prof-shared", doc_approve.utc(NOW - timedelta(hours=2)))
                                 for i in range(doc_approve.PER_PROFILE_DAILY_MAX - 1)])
        sh = self.evaluate()["shadow"]
        self.assertEqual(sh["would_requests"], 1, "one slot is left on the shared profile")
        self.assertEqual(sh["rolled_to_tomorrow"], 2)

    def test_the_shadow_plan_REFUSES_a_popularity_zero_row_instead_of_calling_it_T0(self):
        """Finding 5: `gate_tier` refuses popularity 0 (R22a D1), so counting it T0 overstated the
        arming measurement by exactly the rows the decider would never write."""
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1)])
        _decisions(self.ledger, {R1: 0})
        sh = self.evaluate()["shadow"]
        self.assertEqual(sh["would_requests"], 0)
        self.assertEqual(sh["tiers"], {"T0": 0, "T1": 0, "unknown": 0})
        self.assertEqual(sh["zero_popularity_refused"], 1)



class QaR2(Base):
    """qa-review #1766 r2: a ledger that cannot be read is BLIND, never zero approvals."""

    def test_a_MISSING_ledger_is_BLIND_not_zero_approvals(self):
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1)])
        res = WD.evaluate(now=NOW, ledger=self.dir / "nope.sqlite", doc_store=self.doc_store,
                          proof_store=self.proof_store, registry=self.registry)
        self.assertTrue(res["unreadable"], "a missing ledger is not an empty one")
        self.assertIn("missing or unreadable", res["unreadable"])
        self.assertEqual(res["alerts"], [])
        out = WD.render(res)
        self.assertNotEqual(out, "NO_REPLY", "a blind watchdog must PAGE")
        self.assertIn("BLIND", out)

    def test_a_CORRUPT_ledger_is_BLIND_too(self):
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1)])
        bad = self.dir / "corrupt.sqlite"
        bad.write_bytes(b"this is not a sqlite database")
        res = WD.evaluate(now=NOW, ledger=bad, doc_store=self.doc_store,
                          proof_store=self.proof_store, registry=self.registry)
        self.assertTrue(res["unreadable"])
        self.assertNotEqual(WD.render(res), "NO_REPLY")

    def test_a_ledger_with_no_decisions_table_is_BLIND(self):
        """The decider's ledger always has `decisions`; one without it is not the decider's ledger."""
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1)])
        bare = self.dir / "bare.sqlite"
        db = sqlite3.connect(bare)
        doc_approve.ensure_schema(db)
        db.close()
        res = WD.evaluate(now=NOW, ledger=bare, doc_store=self.doc_store,
                          proof_store=self.proof_store, registry=self.registry)
        self.assertTrue(res["unreadable"])
        self.assertIn("decisions", res["unreadable"])




class QaR3(Base):
    """qa-review #1766 r3: an unmeasured input is a refusal, and "approvable work" is post-cap.

    Five findings, one shape: the watchdog reported a NUMBER where it should have reported that it
    could not measure, or counted work the decider is not allowed to do today as work it is failing
    to do. Both read as a healthy-looking tick and page the wrong thing.
    """

    def test_the_stall_alert_uses_the_CAP_ADMITTED_plan_not_pre_cap_rows(self):
        """Finding 1: `would_approve` is PRE-cap. With every daily slot spent, zero approvals is the
        correct answer, so paging a stalled decider is a false alarm about correct behaviour."""
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1)])
        # every one of today's 50 user slots is already spent
        _approvals(self.ledger, [(5000 + i, f"prof-{i}", doc_approve.utc(NOW - timedelta(hours=2)))
                                 for i in range(doc_approve.DAILY_USER_CAP)])
        res = self.evaluate()
        self.assertEqual(res["per_guard"].get("would_approve"), 1, "the row passes every row gate")
        self.assertEqual(res["eligible"], 0, "but the caps admit nothing today")
        self.assertEqual(res["rolled_to_tomorrow"], 1)
        self.assertEqual(res["alerts"], [], "a spent cap is not a stalled decider")
        self.assertEqual(WD.render(res), "NO_REPLY")

    def test_a_doc_approvals_query_error_is_BLIND_not_zero_approvals(self):
        """Finding 4: `_approvals_since`/`_standing` swallowed a query error as 0/empty, which pages
        a false stall and a false stale set instead of saying the watchdog cannot see.

        Asserted on the two readers directly: through `evaluate` the same broken table is caught
        earlier by `_spent_today`, so an end-to-end assertion would pass for the wrong reason and
        would not pin this fix at all.
        """
        db = sqlite3.connect(self.ledger)
        db.execute("DROP TABLE doc_approvals")
        db.commit()
        with self.assertRaises(sqlite3.Error):
            WD._approvals_since(db, doc_approve.utc(NOW - timedelta(hours=6)))
        with self.assertRaises(sqlite3.Error):
            WD._standing(db)
        db.close()

    def test_a_doc_approvals_query_error_reaches_the_operator_as_BLIND(self):
        """The end-to-end half: whatever raises, the tick must PAGE that it is blind."""
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1)])
        db = sqlite3.connect(self.ledger)
        db.execute("DROP TABLE doc_approvals")
        db.commit()
        db.close()
        res = self.evaluate()
        self.assertTrue(res["unreadable"], "an unreadable approvals table is not an empty one")
        self.assertEqual(res["alerts"], [])
        self.assertIn("BLIND", WD.render(res))

    def test_a_core_read_failure_is_BLIND_not_a_quiet_tick(self):
        """Finding 5: a core outage left `ages={}`, so every row measured `claimant_no_history`,
        `eligible` became 0 and the tick looked like a healthy quiet one."""
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1)])
        with mock.patch.object(doc_measure, "core_ages",
                               side_effect=admin_api.AdminError("core is down")):
            res = self.evaluate()
        self.assertTrue(res["unreadable"], "a core outage is BLIND, not quiet")
        self.assertIn("core could not be read", res["unreadable"])
        self.assertIn("BLIND", WD.render(res))

    def test_an_unreadable_policy_is_BLIND_not_an_empty_hold_set(self):
        """Finding 3: `load_policy` returned None and `measure` then held nobody, so a denied user
        could appear as approvable work while the decider itself fails closed on the same policy."""
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1)])
        with mock.patch.object(doc_measure, "load_policy", return_value=None):
            res = self.evaluate()
        self.assertTrue(res["unreadable"], "an unreadable policy is not an empty hold set")
        self.assertIn("deny/hold policy", res["unreadable"])
        self.assertIn("BLIND", WD.render(res))

    def test_a_second_doc_store_read_failure_is_BLIND_not_a_fabricated_stale_alert(self):
        """Finding 2: `_verdict_at` returned `{}` on failure, and `(verdict_at.get(rid) or "") <=
        cutoff` is then TRUE for every row - a 24 h stale alert with no age evidence at all."""
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1)])
        with mock.patch.object(WD, "_verdict_at", side_effect=sqlite3.OperationalError("gone")):
            res = self.evaluate()
        self.assertTrue(res["unreadable"], "a failed age read is not evidence of staleness")
        self.assertIn("verdict ages", res["unreadable"])
        self.assertEqual(res["alerts"], [])
        self.assertIn("BLIND", WD.render(res))


class QaR5(Base):
    """qa-review #1766 r5: the shadow line's tier split must describe the SAME set as its headline.

    The headline (`would_users`/`would_requests`) is the cap-admitted plan; the tier split was the
    pre-cap `would_approve` population. With today's slots spent the two disagree, and the tier split
    is the diagnostic an operator reads to decide whether to arm - a number that contradicts its own
    headline is worse than no number.
    """

    def test_the_tier_split_counts_the_CAP_ADMITTED_set_not_pre_cap_rows(self):
        """Finding 1: 49 of 50 fleet slots spent, two eligible T1 requests -> the headline admits ONE
        request, so the split must say T1 1, not T1 2."""
        # TWO DIFFERENT accounts, or the per-user cap (5) would admit both and the fleet cap would
        # never be asked. Same profile, so the 10/profile bound is not what bites either.
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 145833),
                    ("i-2", R2, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 145834)],
                   popularity=40)   # T1: `tier_of` puts anything under 30 in T0
        # 49 distinct users already approved today: one fleet slot left, no per-user or profile
        # pressure (each spent row is its own profile).
        _approvals(self.ledger, [(5000 + i, f"prof-{i}", doc_approve.utc(NOW - timedelta(hours=2)))
                                 for i in range(doc_approve.DAILY_USER_CAP - 1)])
        res = self.evaluate()
        sh = res["shadow"]
        self.assertEqual(res["per_guard"].get("would_approve"), 2, "both rows pass every row gate")
        self.assertEqual(sh["would_requests"], 1, "the caps admit exactly one of them today")
        self.assertEqual(sh["tiers"]["T1"], 1, "the split must agree with the headline")
        self.assertEqual(sh["pre_cap_tiers"]["T1"], 2, "and the pre-cap population is still named")
        self.assertEqual(sh["largest_user"], 1, "one admitted request is one holder")
        self.assertEqual(res["eligible"], 1)

    def test_the_shadow_line_NAMES_the_pre_cap_population_when_the_caps_bite(self):
        """The gap between admitted and pre-cap IS the cap pressure, so it is shown, not dropped."""
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 145833),
                    ("i-2", R2, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 145834)],
                   popularity=40)
        _approvals(self.ledger, [(5000 + i, f"prof-{i}", doc_approve.utc(NOW - timedelta(hours=2)))
                                 for i in range(doc_approve.DAILY_USER_CAP - 1)])
        _registry(self.registry, approved=False)   # the shadow line only renders while DORMANT
        line = WD.render_shadow(self.evaluate())
        self.assertIn("1 request(s)", line)
        self.assertIn("before today's caps: T0 0, T1 2", line)

    def test_the_shadow_line_stays_QUIET_about_pre_cap_when_nothing_rolled(self):
        """No cap pressure means no second number: the line must not grow a redundant clause."""
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1)])
        _registry(self.registry, approved=False)   # the shadow line only renders while DORMANT
        line = WD.render_shadow(self.evaluate())
        self.assertIn("1 request(s)", line)
        self.assertNotIn("before today's caps", line)


class QaR6(Base):
    """qa-review #1766 r6: an INDETERMINATE row is not a completed approval.

    `state != 'released'` counted it, so a row whose core write outcome is explicitly unknown
    suppressed the stall alert - the one alert that exists to say the decider is not clearing the
    class. Counting it asserts a fact the system did not measure.
    """

    def test_an_INDETERMINATE_row_does_not_suppress_the_stall_alert(self):
        """The finding: one indeterminate row in the window, eligible work waiting, no alert.

        R1 is the row whose outcome is unknown; R2 is separate eligible work still waiting, because
        approving R1 makes R1 itself ineligible (`gate_one_per_request`) and the stall alert needs
        something left to clear.
        """
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1),
                    ("i-2", R2, "verified", doc_approve.utc(NOW - timedelta(hours=1)), 1)])
        self.approve(R1, NOW - timedelta(hours=2), state="indeterminate")
        res = self.evaluate()
        self.assertEqual(res["approved_6h"], 0, "an unknown outcome is not a known approval")
        self.assertEqual(res["indeterminate_6h"], 1, "but it is reported, not hidden")
        self.assertEqual([a["key"] for a in res["alerts"]], ["approved_0_in_6h"])
        self.assertIn("INDETERMINATE", WD.render(res))

    def test_a_CONFIRMED_row_still_suppresses_the_stall_alert(self):
        """The positive control: a real approval in the window is a working decider."""
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1)])
        self.approve(R1, NOW - timedelta(hours=2), state="confirmed")
        res = self.evaluate()
        self.assertEqual(res["approved_6h"], 1)
        self.assertEqual(res["indeterminate_6h"], 0)
        self.assertEqual(res["alerts"], [])

    def test_a_PULLED_row_counts_as_an_approval(self):
        """A pull is the decider running and the sweep reverting it, not a stall."""
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1)])
        self.approve(R1, NOW - timedelta(hours=2), state="pulled")
        self.assertEqual(self.evaluate()["approved_6h"], 1)

    def test_a_RELEASED_row_is_not_an_approval(self):
        """The core write did not confirm, so the slot went back and nothing was approved.

        Both verdicts are fresh: a released slot returns the request to the eligible set, so an old
        verdict here would also (correctly) raise the 24 h stale alert and blur what is asserted.
        """
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=1)), 1),
                    ("i-2", R2, "verified", doc_approve.utc(NOW - timedelta(hours=1)), 1)])
        self.approve(R1, NOW - timedelta(hours=2), state="released")
        res = self.evaluate()
        self.assertEqual(res["approved_6h"], 0)
        self.assertEqual([a["key"] for a in res["alerts"]], ["approved_0_in_6h"])

    def test_the_window_boundary_still_holds_for_every_state(self):
        """A row just OUTSIDE the 6 h window is not counted, whatever its state."""
        self._docs([("i-1", R1, "verified", doc_approve.utc(NOW - timedelta(hours=40)), 1)])
        old = NOW - timedelta(hours=7)
        for i, state in enumerate(("provisional", "confirmed", "pulled", "indeterminate")):
            self.approve(f"old-{i}", old, state=state)
        res = self.evaluate()
        self.assertEqual(res["approved_6h"], 0)
        self.assertEqual(res["indeterminate_6h"], 0)


if __name__ == "__main__":
    unittest.main()
