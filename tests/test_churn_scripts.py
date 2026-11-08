"""End-to-end tests for the three campaign stages, driven through their real CLIs.

These run the actual scripts against a scratch state dir and a fixture audience, so the wiring
(arg parsing, policy paths, ledger, switch gates, exit codes) is exercised the way cron will run
it - not through the library API only. The assertions are deliberately about what a run REFUSES:

* route is idempotent (a second run writes nothing new),
* a dry run creates no state at all,
* read-back marks Seen only from real evidence,
* the sender refuses a live run without the three switches, and
* a rehearsal never consumes the one message a user may ever get.
"""

import contextlib
import io
import json
import os
import pathlib
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
POLICY = ROOT / "policies" / "winback-fix.json"
SCHEDULE = tuple(json.loads(POLICY.read_text())["readback"]["backoff_hours"])

sys.path.insert(0, str(SCRIPTS))

import churn_returns  # noqa: E402
import fix_readback  # noqa: E402
import winback_fix_send  # noqa: E402
from churn import audience, cli, model, readback, render, returns, tickets  # noqa: E402
from lib import clickup_client  # noqa: E402


def run(script, *args, env=None):
    proc = subprocess.run(
        [sys.executable, str(SCRIPTS / script), *args],
        capture_output=True, text=True, cwd=str(ROOT), env={**os.environ, **(env or {})}, timeout=120,
    )
    return proc


def _try_lock(path):
    with fix_readback.run_lock(path) as won:
        return won


def age_routed(state, hours=2.0):
    """Backdate routing so the ticket is past the policy's first read-back interval."""
    with tickets.TicketStore(state / "tickets.sqlite") as store:
        store.db.execute("UPDATE fix_tickets SET routed_at = routed_at - ?", (hours * 3600.0,))
        store.db.commit()


def doc(proc):
    try:
        return json.loads(proc.stdout)
    except ValueError:  # pragma: no cover - a failing script prints diagnostics
        raise AssertionError(f"stdout was not JSON:\n{proc.stdout}\n--- stderr ---\n{proc.stderr}")


def candidates(path: pathlib.Path, n=3):
    now = 1_700_000_000.0
    rows = []
    causes = ["open_told_wait:credits_not_approved", "no_reply:proof_sent_no_update",
              "open_told_wait:analytics_stale_wrong", "promise_not_kept", "merge_claim_stuck"]
    for i in range(n):
        rows.append({
            "user_id": str(7000 + i),
            "tier": "T2-open-told-wait" if i % 2 else "T1-unanswered",
            "primary": causes[i % len(causes)],
            "classes": [causes[i % len(causes)].split(":")[-1]],
            "mrr": 49.0 - i,
            "plan": "muso_team_pro_graduated_monthly",
            "reason": "cancellation_requested",
            "cancel_at": now - (5 + i) * 86400,
            "request_at": now - 20 * 86400,
            "wait_days": 30.0 + i,
            "evidence": [f"intercom 21547{i}: open at cancel"],
            "intercom_convs": [f"21547{i}"],
            "refunds": 0,
            "disputes": 0,
        })
    path.write_text(json.dumps({"generated_at": now, "candidates": rows}))
    return path


class CampaignCliTest(unittest.TestCase):
    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.state = self.dir / "state"
        self.cands = candidates(self.dir / "candidates.json")
        self.common = ["--source", "json", "--candidates", str(self.cands), "--state-dir", str(self.state)]

    # ── stage 1: route ──────────────────────────────────────────────────────
    def test_dry_run_routes_nothing_and_creates_no_state(self):
        proc = run("route_fix.py", *self.common, "--dry-run", "--no-clickup")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        payload = doc(proc)
        self.assertTrue(payload["dry_run"])
        self.assertEqual(sum(payload["routed"].values()), 2)
        self.assertEqual(payload["skipped"], {"analytics": 1})
        self.assertFalse(self.state.exists())

    def test_route_writes_one_ticket_per_user_into_the_owning_lane(self):
        proc = run("route_fix.py", *self.common, "--no-clickup")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        payload = doc(proc)
        self.assertEqual(payload["routed"], {"credit-review": 1, "proof": 1})
        self.assertEqual(payload["skipped"], {"analytics": 1})  # --no-clickup reports, never drops silently
        # The credit/proof lanes supply the decider's ORDER, not a second queue: the one file this
        # stage writes is the priority list scripts/credit_review/decide.py reads.
        priority = json.loads((self.state / "intake" / "churn-priority.json").read_text())
        self.assertEqual(priority["schema"], "churn-priority/v1")
        self.assertEqual(len(priority["entries"]), 2)
        self.assertTrue(all(entry["until"] > 0 for entry in priority["entries"]))
        self.assertEqual(sorted(p.name for p in (self.state / "intake").iterdir()), ["churn-priority.json"])

    def test_route_records_the_churn_window_floor_for_the_read_back(self):
        # The read-back dates a fix against the user's wait raised to the snapshot's window start.
        # Only this stage holds the measured snapshot, so it has to write the floor down.
        proc = run("route_fix.py", *self.common, "--no-clickup")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        churn_days = int(json.loads(POLICY.read_text())["windows"]["churn_days"])
        floor = 1_700_000_000.0 - churn_days * 86400.0
        with tickets.TicketStore(self.state / "tickets.sqlite", readonly=True) as store:
            rows = [json.loads(r[0]) for r in store.db.execute("SELECT candidate_json FROM fix_tickets")]
        self.assertEqual(len(rows), 2)
        for candidate in rows:
            self.assertAlmostEqual(candidate["churn_window_start"], floor)

    def test_board_lanes_without_a_token_are_unrouted_not_routed(self):
        # A placeholder lane_ref would persist as "already routed" and could never be read back.
        # Exit 2 on purpose: an unreachable intake is an operator problem, not a quiet night.
        # The empty credentials are explicit: run() inherits os.environ, and on a host that exports
        # CLICKUP_API_KEY this test would otherwise POST to the production support board.
        proc = run("route_fix.py", *self.common,
                   env={"CLICKUP_API_KEY": "", "MUSOAI_CLICKUP_API_KEY": ""})
        self.assertEqual(proc.returncode, 2)
        self.assertIn("unrouted", proc.stderr)
        payload = doc(proc)
        self.assertEqual(payload["unrouted"], {"analytics": 1})
        self.assertEqual(payload["routed"], {"credit-review": 1, "proof": 1})

    def test_a_second_route_run_is_a_no_op(self):
        first = run("route_fix.py", *self.common, "--no-clickup")
        self.assertEqual(first.returncode, 0, first.stderr)
        second = run("route_fix.py", *self.common, "--no-clickup")
        payload = doc(second)
        self.assertEqual(payload["routed"], {})
        self.assertEqual(sum(payload["already_routed"].values()), 2)
        counts = payload["ledger_counts"]["by_state"]
        self.assertEqual(counts, {"routed": 2})

    def test_limit_rehearses_only_the_top_of_the_list(self):
        proc = run("route_fix.py", *self.common, "--no-clickup", "--limit", "1")
        payload = doc(proc)
        self.assertEqual(sum(payload["routed"].values()), 1)

    # ── stage 2: read back ──────────────────────────────────────────────────
    def test_readback_without_a_ledger_exits_1(self):
        proc = run("fix_readback.py", "--state-dir", str(self.state))
        self.assertEqual(proc.returncode, 1)
        self.assertIn("route_fix.py", proc.stderr)

    def test_readback_holds_every_ticket_whose_fix_is_not_seen(self):
        run("route_fix.py", *self.common, "--no-clickup")
        age_routed(self.state)
        proc = run("fix_readback.py", "--state-dir", str(self.state),
                   "--ledger", str(self.dir / "no-ledger.sqlite3"))
        payload = doc(proc)
        self.assertEqual(proc.returncode, 3, proc.stderr)  # a source outage, never "no fixes yet"
        self.assertEqual(payload["seen"], [])
        self.assertEqual(payload["checked"], 2)
        self.assertEqual(payload["unreadable"], 2)  # the credit lane has no readable ledger: UNKNOWN
        self.assertEqual(payload["not_yet"], 0)

    def test_a_ticket_routed_just_now_is_not_read_until_its_first_interval(self):
        run("route_fix.py", *self.common, "--no-clickup")
        proc = run("fix_readback.py", "--state-dir", str(self.state),
                   "--ledger", str(self.dir / "no-ledger.sqlite3"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(doc(proc)["checked"], 0)

    def test_a_ticket_with_no_start_of_wait_is_undatable_not_an_outage(self):
        # A DATA gap in one ticket must never be reported as "the ledger is down", and must never
        # contribute to the exit-3 test: nothing is wrong with the source.
        run("route_fix.py", *self.common, "--no-clickup")
        with tickets.TicketStore(self.state / "tickets.sqlite") as store:
            for ticket in store.by_state(tickets.ROUTED):
                candidate = dict(ticket.candidate)
                candidate.pop("request_at", None)
                candidate["credit_open"] = {}
                store.db.execute("UPDATE fix_tickets SET candidate_json = ? WHERE ticket_id = ?",
                                 (json.dumps(candidate), ticket.ticket_id))
            store.db.commit()
        age_routed(self.state)
        proc = run("fix_readback.py", "--state-dir", str(self.state),
                   "--ledger", str(self.dir / "no-ledger.sqlite3"))
        payload = doc(proc)
        self.assertEqual(proc.returncode, 0, proc.stderr)  # not an outage
        self.assertEqual(payload["undatable"], 2)
        self.assertEqual(payload["unreadable"], 0)
        with tickets.TicketStore(self.state / "tickets.sqlite", readonly=True) as store:
            reasons = [json.loads(r[0])["reason"] for r in store.db.execute(
                "SELECT readback_json FROM fix_tickets WHERE state = ?", (tickets.ROUTED,))]
        self.assertTrue(all(reason.startswith("undatable") for reason in reasons), reasons)

    def test_a_second_readback_exits_cleanly_while_one_is_running(self):
        run("route_fix.py", *self.common, "--no-clickup")
        age_routed(self.state)
        (self.state / "readback.lock").write_text(f"{os.getpid()}\n")
        proc = run("fix_readback.py", "--state-dir", str(self.state),
                   "--ledger", str(self.dir / "no-ledger.sqlite3"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("another read-back is running", proc.stderr)
        self.assertEqual(list((self.state / "reports").glob("readback-*")), [])

    def _lock(self, **payload):
        path = self.state / "readback.lock"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload) + "\n")
        return path

    def test_a_recycled_pid_is_not_treated_as_alive(self):
        run("route_fix.py", *self.common, "--no-clickup")
        age_routed(self.state)
        self._lock(pid=os.getpid(), start="1",  # one live pid, but the wrong start time
                   boot_id=fix_readback._boot_id(), at=time.time())
        with contextlib.redirect_stderr(io.StringIO()) as err:
            proc_rc = fix_readback.main(["--state-dir", str(self.state),
                                        "--ledger", str(self.dir / "no-ledger.sqlite3")])
        self.assertEqual(proc_rc, 3)  # it ran the read-back, so the recycled pid did not wedge it
        self.assertIn("taking over stale read-back lock", err.getvalue())

    def test_a_lock_from_another_boot_is_stale(self):
        run("route_fix.py", *self.common, "--no-clickup")
        age_routed(self.state)
        self._lock(pid=os.getpid(), start=fix_readback._proc_start(os.getpid()),
                   boot_id="00000000-0000-0000-0000-000000000000", at=time.time())
        with contextlib.redirect_stderr(io.StringIO()) as err:
            proc_rc = fix_readback.main(["--state-dir", str(self.state),
                                        "--ledger", str(self.dir / "no-ledger.sqlite3")])
        self.assertEqual(proc_rc, 3)
        self.assertIn("taking over stale read-back lock", err.getvalue())

    def test_a_live_lock_is_never_removed(self):
        run("route_fix.py", *self.common, "--no-clickup")
        age_routed(self.state)
        path = self._lock(pid=os.getpid(), start=fix_readback._proc_start(os.getpid()),
                          boot_id=fix_readback._boot_id(), at=time.time())
        with contextlib.redirect_stderr(io.StringIO()) as err:
            proc_rc = fix_readback.main(["--state-dir", str(self.state),
                                        "--ledger", str(self.dir / "no-ledger.sqlite3")])
        self.assertEqual(proc_rc, 0)
        self.assertIn("another read-back is running (lock held by pid %d since" % os.getpid(),
                      err.getvalue())
        self.assertTrue(path.exists())

    def test_a_live_lock_older_than_a_long_run_is_still_never_removed(self):
        """Age is not proof of death: a run that has held the lock for more than 12 hours (a
        large batch, or a hung reader) still owns the ledger, and taking it over would run two
        read-backs concurrently over the same tickets."""
        run("route_fix.py", *self.common, "--no-clickup")
        age_routed(self.state)
        path = self._lock(pid=os.getpid(), start=fix_readback._proc_start(os.getpid()),
                          boot_id=fix_readback._boot_id(), at=time.time() - 13 * 3600.0)
        with contextlib.redirect_stderr(io.StringIO()) as err:
            proc_rc = fix_readback.main(["--state-dir", str(self.state),
                                        "--ledger", str(self.dir / "no-ledger.sqlite3")])
        self.assertEqual(proc_rc, 0)
        self.assertIn("another read-back is running (lock held by pid %d since" % os.getpid(),
                      err.getvalue())
        self.assertTrue(path.exists())

    def test_two_simultaneous_takeovers_have_exactly_one_winner(self):
        lock = self.state / "readback.lock"
        lock.parent.mkdir(parents=True, exist_ok=True)
        dead = subprocess.Popen([sys.executable, "-c", "pass"])
        dead.wait()
        lock.write_text(json.dumps({"pid": dead.pid, "start": "1",
                                    "boot_id": fix_readback._boot_id(), "at": time.time()}) + "\n")
        results: list[bool] = []
        holding = threading.Event()
        release = threading.Event()

        def contender():
            with fix_readback.run_lock(lock) as won:
                results.append(won)
                if won:
                    holding.set()
                    release.wait(5)
                else:
                    holding.wait(5)

        threads = [threading.Thread(target=contender) for _ in range(2)]
        for thread in threads:
            thread.start()
        self.assertTrue(holding.wait(5), results)
        deadline = time.time() + 5
        while len(results) < 2 and time.time() < deadline:
            time.sleep(0.01)
        release.set()
        for thread in threads:
            thread.join(5)
        self.assertEqual(results.count(True), 1, results)
        self.assertEqual(results.count(False), 1, results)
        self.assertFalse(lock.exists())  # the winner released it

    def test_a_third_contender_lock_is_never_replaced_by_a_stale_takeover(self):
        """Three contenders: P1 is mid-takeover of a stale lock, P2 is waiting to claim, and P3
        creates a live lock in the gap. P2 must obey P3's lock, never rename it away and restore
        the stale one over it (which would leave P1 and P3 both running)."""
        lock = self.state / "readback.lock"
        lock.parent.mkdir(parents=True, exist_ok=True)
        dead = subprocess.Popen([sys.executable, "-c", "pass"])
        dead.wait()
        lock.write_text(json.dumps({"pid": dead.pid, "start": "1",
                                    "boot_id": fix_readback._boot_id(), "at": time.time()}) + "\n")
        results: list[bool] = []
        with fix_readback._claim_mutex(lock):
            # P1 holds the claim mutex, so P2 cannot reach the create/rename steps yet.
            contender = threading.Thread(
                target=lambda: results.append(_try_lock(lock)))
            contender.start()
            # P3 creates a live lock while P1 is mid-takeover.
            live = {"pid": os.getpid(), "start": fix_readback._proc_start(os.getpid()),
                    "boot_id": fix_readback._boot_id(), "at": time.time()}
            lock.write_text(json.dumps(live) + "\n")
        contender.join(5)
        self.assertEqual(results, [False], "P2 must not claim over P3's live lock")
        self.assertEqual(json.loads(lock.read_text()), live, "P3's lock is left untouched")

    def test_a_stale_lock_is_taken_over(self):
        run("route_fix.py", *self.common, "--no-clickup")
        age_routed(self.state)
        dead = subprocess.Popen([sys.executable, "-c", "pass"])
        dead.wait()
        (self.state / "readback.lock").write_text(f"{dead.pid}\n")
        proc = run("fix_readback.py", "--state-dir", str(self.state),
                   "--ledger", str(self.dir / "no-ledger.sqlite3"))
        self.assertEqual(proc.returncode, 3, proc.stderr)
        self.assertIn("taking over stale read-back lock", proc.stderr)
        self.assertFalse((self.state / "readback.lock").exists())

    def _route_lane_ticket(self, *, lane, lane_ref, user_id="7200", cause="merge_claim_stuck"):
        with tickets.TicketStore(self.state / "tickets.sqlite") as store:
            row = tickets.draft(model.Candidate(user_id=user_id, tier="T1-unanswered",
                                                primary_class=cause, mrr_cents=4900,
                                                cancel_at=1_700_000_000.0 - 30 * 86400),
                                lane=lane, now=1_700_000_000.0, paid_priority_days=30)
            store.route(row, now=time.time() - 2 * 3600)
            store.set_lane_ref(row["ticket_id"], lane_ref)
            return row["ticket_id"]

    def _attempts(self, ticket_id):
        with tickets.TicketStore(self.state / "tickets.sqlite", readonly=True) as store:
            return int(store.db.execute("SELECT readback_attempts FROM fix_tickets WHERE ticket_id = ?",
                                        (ticket_id,)).fetchone()[0])

    def _read_back_with_clickup_answering(self, status):
        self._route_lane_ticket(lane=model.MERGE, lane_ref="abc123")
        err = urllib.error.HTTPError("https://api.clickup.com/api/v2/task/abc123", status,
                                     "HTTP Error %d" % status, None, None)
        client = clickup_client.ClickUp("test-token", urlopen=lambda *a, **k: (_ for _ in ()).throw(err))
        with mock.patch.object(readback.lanes, "clickup_token", lambda: "test-token"), \
                mock.patch.object(clickup_client, "shared", lambda *a, **k: client), \
                contextlib.redirect_stderr(io.StringIO()):
            proc_rc = fix_readback.main(["--state-dir", str(self.state),
                                        "--ledger", str(self.dir / "no-ledger.sqlite3")])
        report = json.loads(next((self.state / "reports").glob("readback-*")).read_text())
        return proc_rc, report

    def test_a_deleted_clickup_task_spends_an_attempt_and_lands_in_datagap(self):
        proc_rc, report = self._read_back_with_clickup_answering(404)
        self.assertEqual(proc_rc, 0)          # nothing is down: a deleted task is not an outage
        self.assertEqual(report["datagap"], 1)
        self.assertEqual(report["unreadable"], 0)
        self.assertEqual(self._attempts(self._ticket_id()), 1)

    def test_a_clickup_outage_spends_no_attempt_and_raises_the_outage_signal(self):
        proc_rc, report = self._read_back_with_clickup_answering(500)
        self.assertEqual(proc_rc, 3)
        self.assertEqual(report["unreadable"], 1)
        self.assertEqual(report["datagap"], 0)
        self.assertEqual(self._attempts(self._ticket_id()), 0)

    def _ticket_id(self):
        with tickets.TicketStore(self.state / "tickets.sqlite", readonly=True) as store:
            return store.db.execute("SELECT ticket_id FROM fix_tickets").fetchone()[0]

    def test_the_exhausted_budget_is_reported_once_and_the_ticket_stays_routed(self):
        run("route_fix.py", *self.common, "--no-clickup")
        with tickets.TicketStore(self.state / "tickets.sqlite") as store:
            for ticket in store.by_state(tickets.ROUTED):
                candidate = dict(ticket.candidate)
                candidate.pop("request_at", None)   # never proves a fix, so it cannot become Seen
                candidate["credit_open"] = {}
                store.db.execute(
                    "UPDATE fix_tickets SET candidate_json = ?, readback_attempts = ?, readback_at = ? "
                    "WHERE ticket_id = ?",
                    (json.dumps(candidate), len(SCHEDULE) - 1, time.time() - 30 * 86400, ticket.ticket_id))
            store.db.commit()
        proc = run("fix_readback.py", "--state-dir", str(self.state),
                   "--ledger", str(self.dir / "no-ledger.sqlite3"))
        payload = doc(proc)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(payload["readback_exhausted"], 2)
        self.assertEqual(payload["not_yet"], 0)
        self.assertEqual(proc.stderr.count("need firstmate: task readback_exhausted 2 tickets"), 1)
        self.assertEqual(payload["still_routed"], 2)  # never auto-ineligible
        # Glob the read-back report by name: route_fix.py writes route-<day>.json into the same
        # directory, and iterdir() order is arbitrary, so the bare iterdir() picked whichever
        # report the filesystem happened to list first.
        report = json.loads(next((self.state / "reports").glob("readback-*")).read_text())
        self.assertEqual(report["readback_exhausted"], 2)

    def test_readback_stdout_redacts_the_staff_reply_the_report_keeps(self):
        # stdout is a capture channel (the documented hourly cadence), so the staff-authored text
        # the 0600 report exists to protect must not ride out on it.
        reply = (
            "Thanks for chasing this. You were right that these two profiles are the same person, "
            "and the merge is fixed now so your catalog shows on one page. The payout report you "
            "were waiting for has been merged as well, and the numbers now show what the app shows. "
            "Sorry it took a support thread to get here."
        )
        with tickets.TicketStore(self.state / "tickets.sqlite") as store:
            row = tickets.draft(model.Candidate(user_id="7100", tier="T1-unanswered",
                                                primary_class="no_reply", mrr_cents=4900,
                                                cancel_at=1_700_000_000.0 - 30 * 86400),
                                lane=model.CAROLINE, now=1_700_000_000.0, paid_priority_days=30)
            store.route(row, now=1_700_000_000.0)
        verdict = readback.Verdict(eligible=True, reason="closed by a human answer",
                                   evidence={"human_reply": reply}, human_reply=reply)
        out = io.StringIO()
        with mock.patch.object(readback, "read", return_value=verdict), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            rc = fix_readback.main(["--state-dir", str(self.state)])
        self.assertEqual(rc, 0)
        printed = json.loads(out.getvalue())
        self.assertEqual(printed["seen"][0]["user_id"], "7100")
        self.assertNotIn("these two profiles are the same person", out.getvalue())
        self.assertEqual(printed["seen"][0]["human_reply"],
                         "<redacted, %d words>" % len(reply.split()))
        report = next((self.state / "reports").iterdir())
        self.assertEqual(report.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads(report.read_text())["seen"][0]["human_reply"], reply)

    # ── stage 3: send ───────────────────────────────────────────────────────
    def test_send_without_a_ledger_exits_1(self):
        proc = run("winback_fix_send.py", "--state-dir", str(self.state))
        self.assertEqual(proc.returncode, 1)

    def test_live_is_refused_without_the_three_switches(self):
        run("route_fix.py", *self.common, "--no-clickup")
        proc = run("winback_fix_send.py", "--state-dir", str(self.state), "--live",
                   "--live-flag", str(self.dir / "absent.flag"), "--no-people-lookup")
        self.assertEqual(proc.returncode, 2)
        payload = doc(proc)
        self.assertTrue(payload["live_refused"])
        self.assertIsNone(payload["handoff"])
        self.assertFalse((self.state / "outbound").exists())

    def test_a_rehearsal_reports_nothing_to_send_and_consumes_no_ledger_row(self):
        run("route_fix.py", *self.common, "--no-clickup")
        proc = run("winback_fix_send.py", "--state-dir", str(self.state), "--ledger",
                   str(self.dir / "no-ledger.sqlite3"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        payload = doc(proc)
        self.assertEqual(payload["eligible_tickets"], 0)
        self.assertEqual(payload["send"], 0)
        self.assertIsNone(payload["handoff"])
        self.assertEqual(payload["live"], False)

    # ── stage 4: measure ────────────────────────────────────────────────────
    def test_returns_without_a_ledger_exits_1(self):
        proc = run("churn_returns.py", "--state-dir", str(self.state), "--dry-run")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("nothing has been routed yet", proc.stderr)
        self.assertIn(str(self.state / "tickets.sqlite"), proc.stderr)

    def _route_a_holdout(self):
        """One held-back user, so the returns run gets past the nothing-to-measure guard."""
        policy = json.loads(POLICY.read_text())
        modulus = int(policy["holdout"]["modulus"])
        residue = int(policy["holdout"]["residue"])
        uid = next(u for u in (str(n) for n in range(1, 500)) if model.holdout(u, modulus, residue))
        now = time.time()
        with tickets.TicketStore(self.state / "tickets.sqlite") as store:
            _, ticket = store.route(tickets.draft(
                model.Candidate(user_id=uid, tier="T2-open-told-wait", primary_class="credits_not_approved"),
                lane="credit-review", now=now, paid_priority_days=30))
            store.mark_seen(ticket.ticket_id, evidence={"note": "fixture"}, at=now)

    def test_returns_with_a_missing_trino_wrapper_exits_3_and_writes_no_artifact(self):
        self._route_a_holdout()
        proc = run("churn_returns.py", "--state-dir", str(self.state),
                   env={"CHURN_TRINO": str(self.dir / "no-such-trino-wrapper")})
        self.assertEqual(proc.returncode, 3, proc.stderr)
        self.assertIn("no returns were measured", proc.stderr)
        self.assertFalse((self.state / "returns").exists())

    def test_a_trino_timeout_exits_3_and_writes_no_artifact(self):
        self._route_a_holdout()
        with mock.patch.object(readback.subprocess, "run",
                               side_effect=subprocess.TimeoutExpired(cmd="trino-query.sh", timeout=180)):
            rc = churn_returns.main(["--state-dir", str(self.state)])
        self.assertEqual(rc, 3)
        self.assertFalse((self.state / "returns").exists())

    def test_returns_dry_run_reads_no_subscriptions(self):
        run("route_fix.py", *self.common, "--no-clickup")
        proc = run("churn_returns.py", "--state-dir", str(self.state), "--dry-run")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        payload = doc(proc)
        self.assertTrue(payload["dry_run"])
        self.assertEqual(payload["intent_to_treat"], 2)  # routed users, measured or not
        self.assertEqual(payload["holdout"], 0)
        self.assertFalse((self.state / "returns").exists())

    # ── the muso-messaging drop-in ──────────────────────────────────────────
    def test_the_template_exporter_writes_the_dropin_and_ships_disabled(self):
        out = self.dir / "dropin"
        proc = run("winback_fix_template.py", "--out", str(out))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        payload = doc(proc)
        self.assertFalse(payload["enabled"])
        self.assertIsNone(payload["fable_go_ref"])
        self.assertTrue((out / "native" / "wb_fix_1" / "body.txt").exists())
        self.assertTrue((out / "wb_fix_1.native-entry.json").exists())
        self.assertIn("{% unsubscribe_url %}", (out / "native" / "wb_fix_1" / "body.txt").read_text())

    def test_render_proof_prints_all_six_variants(self):
        proc = run("winback_fix_send.py", "--render-proof", "6")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        for cause in ("credits_not_approved", "proof_sent_no_update", "merge_claim_stuck",
                      "analytics_stale_wrong", "billing_confusion", "other"):
            self.assertIn(f"## {cause}", proc.stdout)
        self.assertEqual(proc.stdout.count("guard: pass"), 6)


class PolicyGuardrailTest(unittest.TestCase):
    def test_the_template_starts_disabled(self):
        policy = json.loads(POLICY.read_text())
        self.assertFalse(policy["template"]["enabled"])
        self.assertIsNone(policy["template"]["fable_go_ref"])

    def test_a_payment_failed_link_survives_a_reencoded_offer_parameter(self):
        policy = json.loads(POLICY.read_text())
        self.assertNotIn("offer=", render.offer_url_for(
            annual=False, plan="monthly", reason="payment_failed", policy=policy))
        policy["offers"] = {**policy["offers"],
                            "offer_url": "https://muso.ai/pricing?period={period}&offer={slug}"}
        with self.assertRaises(render.PolicyGap):
            render.offer_url_for(annual=False, plan="monthly", reason="payment_failed",
                                 policy=policy)


class OneMessagePerUserTest(unittest.TestCase):
    def test_two_seen_tickets_select_the_highest_priority_one_and_one_decision(self):
        root = pathlib.Path(tempfile.mkdtemp())
        with tickets.TicketStore(root / "tickets.sqlite") as store:
            for tier, mrr, cause in (("T2-open-told-wait", 1900, "proof_sent_no_update"),
                                     ("T1-unanswered", 9900, "no_reply")):
                row = tickets.draft(model.Candidate(user_id="7301", tier=tier, primary_class=cause,
                                                    mrr_cents=mrr),
                                    lane=model.CAROLINE, now=1_700_000_000.0, paid_priority_days=30)
                store.route(row, now=1_700_000_000.0)
                store.mark_seen(row["ticket_id"], evidence={"credits_approved": 1},
                                at=time.time())
            eligible = store.eligible(window_days=7)
        self.assertEqual(len(eligible), 2)
        batch = audience.select(eligible, policy=json.loads(POLICY.read_text()),
                                people=people_for("7301"),
                                verdicts={"7301": {"verdict": "none", "coverage": "full"}})
        self.assertEqual(len(batch.send), 1)
        chosen = next(t for t in eligible if str(t.user_id) == batch.send[0].user_id)
        self.assertEqual(chosen.mrr_cents, 9900)


def people_for(*user_ids):
    return {uid: audience.Recipient(uid, f"sam{uid}@musofan.net", "Sam", True, False, 0)
            for uid in user_ids}


def patch_live_reads(test, people):
    """The two live reads that need a network or a secret; every other line stays the real code."""
    verdicts = {uid: {"verdict": "none", "coverage": "full"} for uid in people}
    for owner, name, value in ((winback_fix_send, "_watchlist", lambda policy: None),
                               (winback_fix_send, "_affiliation", lambda policy: verdicts),
                               (audience, "resolve_people",
                                lambda ids, run_sql: {k: v for k, v in people.items() if k in ids})):
        patcher = mock.patch.object(owner, name, value)
        patcher.start()
        test.addCleanup(patcher.stop)


class LiveSendCase(unittest.TestCase):
    """A scratch state dir, the three switches, and the two live reads pointed at fixtures."""

    def _policy(self, **template):
        policy = json.loads(POLICY.read_text())
        policy["template"] = {**policy["template"], "enabled": True, "fable_go_ref": "TEST-GO", **template}
        path = self.dir / "policy.json"
        path.write_text(json.dumps(policy))
        return path

    def _run(self, policy):
        return winback_fix_send.main(["--policy", str(policy), "--state-dir", str(self.state), "--live",
                                      "--live-flag", str(self.flag),
                                      "--ledger", str(self.dir / "ledger.sqlite3")])

    def _ledger(self):
        with tickets.TicketStore(self.state / "tickets.sqlite") as store:
            return (store.state_counts(),
                    store.db.execute("SELECT COUNT(*) FROM send_messages").fetchone()[0])


class SendRefusalTest(LiveSendCase):
    """A refusal that is about the copy must never be paid for by the users in the batch."""

    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.state = self.dir / "state"
        proc = run("route_fix.py", "--source", "json", "--candidates",
                   str(candidates(self.dir / "candidates.json")), "--state-dir", str(self.state),
                   "--no-clickup")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        with tickets.TicketStore(self.state / "tickets.sqlite") as store:
            for ticket in store.by_state(tickets.ROUTED):
                store.mark_seen(ticket.ticket_id, evidence={"credits_approved": 2}, at=time.time())
        self.flag = self.dir / "live.flag"
        self.flag.write_text("")
        patch_live_reads(self, people_for("7000", "7001"))

    def test_a_guard_refusal_refuses_the_batch_and_moves_no_ticket(self):
        # A policy edit that trips the guard must not burn a batch of already-fixed users to a
        # permanent `ineligible`: the fault is in the copy, so the batch is refused and a corrected
        # policy can send tomorrow.
        policy = self._policy(body=[*json.loads(POLICY.read_text())["template"]["body"],
                                    "This note comes from our churn lane."])
        self.assertEqual(self._run(policy), 2)
        states, messages = self._ledger()
        self.assertEqual(states, {"seen": 2})
        self.assertEqual(messages, 0)
        self.assertFalse((self.state / "outbound").exists())

    def test_a_manifest_that_cannot_be_written_claims_no_message(self):
        # The ledger rows exist to guarantee one message ever. A batch that never reached the
        # sender seat must not consume that entitlement, so the claims roll back with the manifest.
        def boom(*args, **kwargs):
            raise OSError("No space left on device")

        with mock.patch.object(winback_fix_send, "_write_manifest", boom):
            self.assertEqual(self._run(self._policy()), 4)
        states, messages = self._ledger()
        self.assertEqual(states, {"seen": 2})
        self.assertEqual(messages, 0)
        self.assertFalse((self.state / "outbound").exists())

    def test_a_commit_failure_leaves_no_manifest_for_the_sender_seat(self):
        # The manifest is the file the sender seat reads. A commit that fails after it was staged
        # must leave nothing behind: the claims rolled back, so those users are still owed their
        # one message and a manifest on disk would send it twice.
        @contextlib.contextmanager
        def failing_commit(store):
            yield
            store.db.rollback()
            raise sqlite3.OperationalError("database or disk is full")

        with mock.patch.object(tickets.TicketStore, "transaction", failing_commit):
            self.assertEqual(self._run(self._policy()), 4)
        states, messages = self._ledger()
        self.assertEqual(states, {"seen": 2})
        self.assertEqual(messages, 0)
        self.assertEqual(list((self.state / "outbound").iterdir()), [])

    def test_a_permission_hardening_failure_after_the_commit_does_not_strand_the_batch(self):
        # _lock_down chmods the ledger AFTER the commit. If that raises, the claims are already
        # committed: the manifest must still be published, or those users' one message is spent
        # on a batch the sender seat never sees.
        real_chmod = os.chmod
        real_write = winback_fix_send._write_manifest
        armed = {"on": False}

        def write_then_arm(*args, **kwargs):
            path = real_write(*args, **kwargs)
            armed["on"] = True
            return path

        def chmod(path, mode, *args, **kwargs):
            if armed["on"] and str(path).endswith("tickets.sqlite"):
                raise OSError("Read-only file system")
            return real_chmod(path, mode, *args, **kwargs)

        with mock.patch.object(winback_fix_send, "_write_manifest", write_then_arm), \
                mock.patch.object(tickets.os, "chmod", chmod):
            self.assertEqual(self._run(self._policy()), 0)
        states, messages = self._ledger()
        self.assertEqual(states, {"seen": 2})
        self.assertEqual(messages, 2)
        self.assertEqual(len(list((self.state / "outbound").iterdir())), 1)

    def test_two_hand_offs_in_the_same_second_do_not_overwrite_each_other(self):
        policy = json.loads(POLICY.read_text())
        first = winback_fix_send._write_manifest(
            [{"user_id": "1"}], policy=policy, state_dir=self.state, now=123.0)
        second = winback_fix_send._write_manifest(
            [{"user_id": "2"}], policy=policy, state_dir=self.state, now=123.0)
        a = winback_fix_send._publish_manifest(first)
        b = winback_fix_send._publish_manifest(second)
        self.assertNotEqual(a, b)
        self.assertTrue(a.exists())
        self.assertTrue(b.exists())

    def test_a_manifest_that_cannot_be_published_releases_the_claims(self):
        # The claims commit before the manifest becomes visible. If the rename fails, the rows
        # must be released: a `handed` row with no manifest would strand the user for ever.
        def boom(*args, **kwargs):
            raise OSError("Read-only file system")

        with mock.patch.object(winback_fix_send, "_publish_manifest", boom):
            self.assertEqual(self._run(self._policy()), 4)
        states, messages = self._ledger()
        self.assertEqual(states, {"seen": 2})
        self.assertEqual(messages, 0)
        self.assertEqual(list((self.state / "outbound").iterdir()), [])

    def test_a_live_hand_off_claims_the_batch_once(self):
        self.assertEqual(self._run(self._policy()), 0)
        states, messages = self._ledger()
        self.assertEqual(states, {"seen": 2})
        self.assertEqual(messages, 2)
        manifests = sorted((self.state / "outbound").iterdir())
        self.assertEqual(len(manifests), 1)
        self.assertEqual(oct(manifests[0].stat().st_mode & 0o777), oct(0o600))
        self.assertEqual(json.loads(manifests[0].read_text())["count"], 2)
        self.assertEqual([p.name for p in manifests if p.suffix == ".tmp"], [])

    def test_the_manifest_is_never_readable_between_create_and_rename(self):
        # The file carries bodies and addresses. Creating it under the umask and chmod-ing it after
        # leaves a window where another local user can read it, so the mode is set at create time.
        seen = []
        real_replace = os.replace

        def watching_replace(src, dst, *args, **kwargs):
            seen.append((str(src), oct(os.stat(src).st_mode & 0o777)))
            return real_replace(src, dst, *args, **kwargs)

        with mock.patch.object(winback_fix_send.os, "replace", watching_replace):
            self.assertEqual(self._run(self._policy()), 0)
        manifest = [row for row in seen if row[0].endswith(".json.tmp") and "/outbound/" in row[0]]
        self.assertEqual(len(manifest), 1, seen)
        self.assertEqual(manifest[0][1], oct(0o600))

    def test_a_policy_gap_leaves_every_ticket_sendable(self):
        # The reviewer's trace: blank offers.offer_url breaks render for the whole batch. Pre-fix
        # the run walked every Seen ticket to `ineligible` and exited 0, permanently disqualifying
        # the users the campaign exists to win back. A gap in the policy is not a dead end for them.
        policy = json.loads(POLICY.read_text())
        policy["template"] = {**policy["template"], "enabled": True, "fable_go_ref": "TEST-GO"}
        policy["offers"]["offer_url"] = ""
        broken = self.dir / "broken.json"
        broken.write_text(json.dumps(policy))
        self.assertEqual(self._run(broken), 2)
        states, messages = self._ledger()
        self.assertEqual(states, {"seen": 2})
        self.assertEqual(messages, 0)
        self.assertFalse((self.state / "outbound").exists())
        with tickets.TicketStore(self.state / "tickets.sqlite") as store:
            notes = [dict(r) for r in store.db.execute(
                "SELECT event, detail FROM fix_events WHERE event = 'render:policy-gap'")]
        self.assertEqual(len(notes), 2)  # every held ticket records WHY, on its own event log
        self.assertTrue(all("offer_url" in note["detail"] for note in notes), notes)
        # And the ticket is still there to send: the fix is a policy edit, not a person's loss.
        self.assertEqual(self._run(self._policy()), 0)
        self.assertEqual(self._ledger()[1], 2)

class MixedReplyRefusalTest(LiveSendCase):
    """One user's unsendable quoted answer must not refuse everybody else's batch."""

    REPLY = ("You were right that the credits were stuck, and the threshold signal is now "
             "updated on your account with both credits approved, so the two pending requests "
             "now show as approved when you open your profile page on the website.")

    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.state = self.dir / "state"
        now = time.time()
        with tickets.TicketStore(self.state / "tickets.sqlite") as store:
            for uid, cause, lane, evidence in (
                ("7000", "other", model.CAROLINE, {"human_reply": self.REPLY}),
                ("7001", "credits_not_approved", model.CREDIT_REVIEW, {"credits_approved": 2}),
            ):
                row = tickets.draft(
                    model.Candidate(user_id=uid, tier="T2-open-told-wait", primary_class=cause,
                                    mrr_cents=4900, plan="muso_team_pro_graduated_monthly",
                                    reason="cancellation_requested", cancel_at=now - 5 * 86400),
                    lane=lane, now=now, paid_priority_days=30)
                store.route(row, now=now)
                store.mark_seen(row["ticket_id"], evidence=evidence, at=now)
        self.flag = self.dir / "live.flag"
        self.flag.write_text("")
        patch_live_reads(self, people_for("7000", "7001"))

    def test_the_quote_closes_its_own_ticket_and_the_batch_continues(self):
        # The body for 7000 carries that answer verbatim, and the guard sees "threshold"/"signal"
        # in it. Pre-fix that refused the WHOLE batch on every run until the ticket aged out of the
        # 7-day window, so the 324 users with sendable bodies were never messaged at all.
        self.assertEqual(self._run(self._policy()), 0)
        with tickets.TicketStore(self.state / "tickets.sqlite") as store:
            states = {r["user_id"]: r["state"] for r in store.db.execute(
                "SELECT user_id, state FROM fix_tickets")}
            reasons = [json.loads(r["detail"]).get("reason") for r in store.db.execute(
                "SELECT detail FROM fix_events WHERE event = 'ineligible'")]
        self.assertEqual(states, {"7000": "ineligible", "7001": "seen"})
        self.assertEqual(reasons, ["the human answer we would quote names something we cannot send"])
        self.assertEqual(self._ledger()[1], 1)
        manifest = json.loads(next((self.state / "outbound").iterdir()).read_text())
        self.assertEqual([m["user_id"] for m in manifest["messages"]], ["7001"])

class QuoteGapSendTest(LiveSendCase):
    """A reply with no quotable fix sentence is OUR gap, so its ticket must stay sendable."""

    REPLY = ("Hi Nadia, thanks so much for waiting. I hope this note finds you well, and that "
             "things have calmed down a little since we last spoke about all of this.")

    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.state = self.dir / "state"
        now = time.time()
        with tickets.TicketStore(self.state / "tickets.sqlite") as store:
            row = tickets.draft(
                model.Candidate(user_id="7000", tier="T2-open-told-wait", primary_class="other",
                                mrr_cents=4900, plan="muso_team_pro_graduated_monthly",
                                reason="cancellation_requested", cancel_at=now - 5 * 86400),
                lane=model.CAROLINE, now=now, paid_priority_days=30)
            store.route(row, now=now)
            store.mark_seen(row["ticket_id"], evidence={"human_reply": self.REPLY}, at=now)
        self.flag = self.dir / "live.flag"
        self.flag.write_text("")
        patch_live_reads(self, people_for("7000"))

    def test_a_quote_gap_leaves_the_ticket_sendable(self):
        self.assertEqual(self._run(self._policy()), 2)
        with tickets.TicketStore(self.state / "tickets.sqlite") as store:
            states = {r["user_id"]: r["state"] for r in store.db.execute(
                "SELECT user_id, state FROM fix_tickets")}
            gaps = [json.loads(r["detail"]) for r in store.db.execute(
                "SELECT detail FROM fix_events WHERE event = 'render:policy-gap'")]
        self.assertEqual(states, {"7000": "seen"})
        self.assertEqual(len(gaps), 1, gaps)
        self.assertIn("names the fix", gaps[0]["reason"])
        self.assertEqual(self._ledger()[1], 0)


class ArtifactModeTest(unittest.TestCase):
    """Run artifacts carry staff-authored text, so they are never world-readable, even briefly."""

    def test_every_artifact_is_0600_inside_a_0700_directory(self):
        writers = {
            "reports": lambda state: cli.write_report({"human_reply": "the reply we would quote"},
                                                      state=state, name="readback", day="2026-11-04"),
            "returns": lambda state: returns.write_report({"intent_to_treat": {"n": 0}},
                                                          state_dir=state, day="2026-11-04"),
        }
        for label, write in writers.items():
            with self.subTest(label), tempfile.TemporaryDirectory() as d:
                out = write(pathlib.Path(d) / "state")
                self.assertEqual(oct(out.stat().st_mode & 0o777), oct(0o600), label)
                self.assertEqual(oct(out.parent.stat().st_mode & 0o777), oct(0o700), label)
                self.assertEqual([p.name for p in out.parent.iterdir()], [out.name], label)

    def test_the_temp_file_is_created_0600_not_from_the_umask(self):
        seen = []
        real_open = os.open

        def watching(path, flags, mode=0o777, *args, **kwargs):
            seen.append((str(path), mode))
            return real_open(path, flags, mode, *args, **kwargs)

        with tempfile.TemporaryDirectory() as d, mock.patch.object(cli.os, "open", watching):
            cli.write_report({"human_reply": "x"}, state=pathlib.Path(d) / "state",
                             name="readback", day="2026-11-04")
        temps = [mode for path, mode in seen if path.endswith(".json.tmp")]
        self.assertTrue(temps, seen)
        self.assertEqual(set(temps), {0o600})


class LedgerModeTest(unittest.TestCase):
    """The ledger holds the same staff reply as the artifacts, so it is private too."""

    def test_the_ledger_is_0600_in_a_0700_state_dir_and_stays_so_on_reopen(self):
        with tempfile.TemporaryDirectory() as d:
            state = pathlib.Path(d) / "state"
            state.mkdir()
            os.chmod(state, 0o755)  # a state dir an older, umask-driven run created
            for attempt in range(2):
                with self.subTest(open=attempt), tickets.TicketStore(state / "tickets.sqlite") as store:
                    db = state / "tickets.sqlite"
                    self.assertEqual(oct(state.stat().st_mode & 0o777), oct(0o700))
                    self.assertEqual(oct(db.stat().st_mode & 0o777), oct(0o600))
                    store.route(tickets.draft(
                        model.Candidate(user_id="7000", tier="T2-open-told-wait",
                                        primary_class="credits_not_approved"),
                        lane="credit-review", now=1_700_000_000.0, paid_priority_days=30))
                    self.assertEqual(oct(db.stat().st_mode & 0o777), oct(0o600))


class CouponCheckTest(unittest.TestCase):
    """The at-send read: HELD appends the price sentence, LAPSED and UNVERIFIED never do."""

    def test_a_customer_discount_is_held(self):
        check = winback_fix_send.coupons.CouponCheck(
            run=lambda args: {"discount": {"coupon": {"id": "reg40", "name": "Regional Discount 40%"}}})
        self.assertEqual(check.verdict("cus_1", "Regional Discount 40%"), "held")

    def test_a_subscription_discount_is_held_when_the_customer_has_none(self):
        calls = []

        def run(args):
            calls.append(args)
            if args[0] == "customers":
                return {"id": "cus_1", "discount": None}
            return {"data": [{"discount": {"coupon": {"id": "reg40",
                                                      "name": "Regional Discount 40%"}}}]}

        check = winback_fix_send.coupons.CouponCheck(run=run)
        self.assertEqual(check.verdict("cus_1", "Regional Discount 40%"), "held")
        self.assertEqual([c[0] for c in calls], ["customers", "subscriptions"])

    def test_a_shorter_live_name_is_not_the_recorded_coupon(self):
        check = winback_fix_send.coupons.CouponCheck(
            run=lambda args: {"discount": {"coupon": {"id": "reg", "name": "Regional"}}})
        self.assertEqual(check.verdict("cus_1", "Regional Discount 40%"), "lapsed")

    def test_a_different_coupon_id_with_a_matching_name_is_not_held(self):
        check = winback_fix_send.coupons.CouponCheck(
            run=lambda args: {"discount": {"coupon": {"id": "other40",
                                                      "name": "Regional Discount 40%"}}})
        self.assertEqual(check.verdict("cus_1", "reg40"), "lapsed")

    def test_punctuation_and_case_do_not_change_the_coupon(self):
        check = winback_fix_send.coupons.CouponCheck(
            run=lambda args: {"discount": {"coupon": {"id": "reg40",
                                                      "name": "REGIONAL DISCOUNT 40%"}}})
        self.assertEqual(check.verdict("cus_1", "Regional Discount 40%"), "held")

    def test_an_empty_recorded_discount_is_unverified(self):
        check = winback_fix_send.coupons.CouponCheck(run=lambda args: {"discount": None})
        self.assertEqual(check.verdict("cus_1", ""), "unverified")

    def test_a_read_that_shows_nothing_is_lapsed(self):
        check = winback_fix_send.coupons.CouponCheck(run=lambda args: {"discount": None})
        self.assertEqual(check.verdict("cus_1", "Regional Discount 40%"), "lapsed")

    def test_a_failed_read_is_unverified(self):
        check = winback_fix_send.coupons.CouponCheck(run=lambda args: None)
        self.assertEqual(check.verdict("cus_1", "Regional Discount 40%"), "unverified")

    def test_one_read_per_customer(self):
        calls = []

        def run(args):
            calls.append(args)
            return {"discount": {"coupon": {"id": "reg40", "name": "Regional Discount 40%"}}}

        check = winback_fix_send.coupons.CouponCheck(run=run)
        check.verdict("cus_1", "Regional Discount 40%")
        check.verdict("cus_1", "Regional Discount 40%")
        self.assertEqual(len(calls), 1)

    def test_a_rehearsal_never_calls_stripe(self):
        check = winback_fix_send.coupons.CouponCheck(run=winback_fix_send.coupons.offline)
        self.assertEqual(check.verdict("cus_1", "Regional Discount 40%"), "unverified")


class RegionalCouponSendTest(LiveSendCase):
    """The regional sentence ships only to a user whose country coupon is live at send time."""

    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.state = self.dir / "state"
        now = time.time()
        with tickets.TicketStore(self.state / "tickets.sqlite") as store:
            row = tickets.draft(
                model.Candidate(user_id="7100", tier="T2-open-told-wait",
                                primary_class="credits_not_approved", mrr_cents=4900,
                                plan="muso_team_pro_graduated_monthly",
                                reason="cancellation_requested", cancel_at=now - 5 * 86400,
                                discount="Regional Discount 40%", customer_id="cus_regional"),
                lane=model.CREDIT_REVIEW, now=now, paid_priority_days=30)
            store.route(row, now=now)
            store.mark_seen(row["ticket_id"], evidence={"credits_approved": 2}, at=now)
        self.flag = self.dir / "live.flag"
        self.flag.write_text("")
        patch_live_reads(self, people_for("7100"))

    def _stripe(self, doc):
        patcher = mock.patch.object(winback_fix_send.coupons, "_stripe", lambda args: doc)
        patcher.start()
        self.addCleanup(patcher.stop)

    def _manifest(self):
        return json.loads(next((self.state / "outbound").iterdir()).read_text())

    def _report(self):
        return json.loads(next((self.state / "reports").glob("send-live-*.json")).read_text())

    def test_a_live_coupon_keeps_the_sentence(self):
        self._stripe({"id": "cus_regional",
                      "discount": {"coupon": {"id": "reg40", "name": "Regional Discount 40%"}}})
        self.assertEqual(self._run(self._policy()), 0)
        self.assertIn("regional discount still applies", self._manifest()["messages"][0]["body"])
        report = self._report()
        self.assertEqual(report["sent_with_suffix"], 1)
        self.assertEqual(report["sent_without_suffix"], 0)

    def test_a_lapsed_coupon_drops_the_sentence_and_still_sends(self):
        self._stripe({"id": "cus_regional", "discount": None})
        self.assertEqual(self._run(self._policy()), 0)
        self.assertNotIn("regional discount still applies", self._manifest()["messages"][0]["body"])
        report = self._report()
        self.assertEqual(report["sent_without_suffix"], 1)
        self.assertEqual(report["held_coupon_lapsed"], 1)

    def test_an_unreadable_coupon_drops_the_sentence_and_still_sends(self):
        self._stripe(None)
        self.assertEqual(self._run(self._policy()), 0)
        self.assertNotIn("regional discount still applies", self._manifest()["messages"][0]["body"])
        report = self._report()
        self.assertEqual(report["coupon_unverified"], 1)
        self.assertEqual(report["sent_without_suffix"], 1)

    def test_a_refused_batch_reports_no_sent_coupons(self):
        self._stripe({"id": "cus_regional",
                      "discount": {"coupon": {"id": "reg40", "name": "Regional Discount 40%"}}})
        policy = json.loads(POLICY.read_text())
        policy["template"] = {**policy["template"], "enabled": True, "fable_go_ref": "TEST-GO",
                              "body": [*policy["template"]["body"],
                                       "This note comes from our churn lane."]}
        path = self.dir / "policy.json"
        path.write_text(json.dumps(policy))
        self.assertEqual(self._run(path), 2)
        report = self._report()
        self.assertEqual(report["send"], 0)
        self.assertEqual(report["sent_with_suffix"], 0)
        self.assertEqual(report["sent_without_suffix"], 0)
        self.assertIn("refused", report["refused_reason"])

    def test_a_manifest_failure_reports_no_sent_coupons(self):
        self._stripe({"id": "cus_regional",
                      "discount": {"coupon": {"id": "reg40", "name": "Regional Discount 40%"}}})

        def boom(*args, **kwargs):
            raise OSError("No space left on device")

        with mock.patch.object(winback_fix_send, "_write_manifest", boom):
            self.assertEqual(self._run(self._policy()), 4)
        report = self._report()
        self.assertEqual(report["send"], 0)
        self.assertEqual(report["sent_with_suffix"], 0)
        self.assertEqual(report["sent_without_suffix"], 0)
        self.assertIn("manifest", report["refused_reason"])

    def test_without_the_go_the_regional_user_is_held(self):
        policy = json.loads(POLICY.read_text())
        policy["template"] = {**policy["template"], "enabled": True, "fable_go_ref": "TEST-GO"}
        policy["offers"]["regional_suffix"]["fable_go_ref"] = None
        path = self.dir / "policy.json"
        path.write_text(json.dumps(policy))
        self._stripe({"id": "cus_regional",
                      "discount": {"coupon": {"id": "reg40", "name": "Regional Discount 40%"}}})
        self.assertEqual(self._run(path), 2)
        self.assertFalse((self.state / "outbound").exists())
        with tickets.TicketStore(self.state / "tickets.sqlite") as store:
            self.assertEqual(store.state_counts().get("seen"), 1)


if __name__ == "__main__":
    unittest.main()
