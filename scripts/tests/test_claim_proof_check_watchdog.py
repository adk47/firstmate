"""scripts/claim-proof-check-watchdog.py - the reader alarm that lets claim-proof-ask carry a date.

p1 rule 8 / QA on #1758 Important 1: the 30h freshness gate in claim_proof_ask.load_list refuses NEW asks once
the daily code check is stale, and says nothing about the asks already out - whose replies then go unread with
no page. These tests lock the alarm's decisions: healthy, stale heartbeat, stale digest, a digest that names
nothing, asks the reader never looked at, held rows that are not asks, and exit 2 when it cannot measure.

Every test builds its own last-run.json / digest / ledger in a temp dir; nothing reads a production path (the
module's defaults are only defaults) and nothing touches the network.
"""
from __future__ import annotations

import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "claim-proof-check-watchdog.py"
NOW = datetime(2026, 11, 4, 18, 0, tzinfo=timezone.utc)


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


class WatchdogTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        self.ledger = self.dir / "ledger.sqlite3"
        con = sqlite3.connect(self.ledger)
        con.execute("create table verify_messages (campaign text, request_ids_json text, sent_at text)")
        con.commit()
        con.close()

    def tearDown(self):
        self._tmp.cleanup()

    # --- fixtures ---------------------------------------------------------------------------------------
    def ask(self, claim_id, hours_ago, sent=True, campaign="claim-proof-ask"):
        """One ledger row. sent=False is a HOLD (sent_at NULL) - it is not an ask and never counts."""
        con = sqlite3.connect(self.ledger)
        con.execute(
            "insert into verify_messages values (?,?,?)",
            (campaign, json.dumps(["claim-%d" % claim_id]), iso(NOW - timedelta(hours=hours_ago)) if sent else None),
        )
        con.commit()
        con.close()

    def heartbeat(self, hours_ago, asked, owner="claim-lane-resume-c2"):
        (self.dir / "last-run.json").write_text(json.dumps(
            {"owner": owner, "last_run_at": iso(NOW - timedelta(hours=hours_ago)), "asked": asked}))

    def digest(self, hours_ago, claim_ids):
        (self.dir / "proof-check-2026-11-04-digest.json").write_text(json.dumps({
            "batch": "proof-check-2026-11-04",
            "generatedAt": iso(NOW - timedelta(hours=hours_ago)),
            "asked": len(claim_ids),
            "claims": [{"id": cid, "status": "not_found"} for cid in claim_ids],
        }))

    def run_wd(self, *extra, ledger=None, state_dir=None):
        p = subprocess.run(
            [sys.executable, str(SCRIPT), "--state-dir", str(state_dir or self.dir),
             "--ledger", str(ledger or self.ledger), "--now", iso(NOW)] + list(extra),
            capture_output=True, text=True)
        return p.returncode, p.stdout

    # --- the decisions ----------------------------------------------------------------------------------
    def test_a_fresh_reader_that_looked_at_every_ask_is_healthy(self):
        self.ask(101, 5)
        self.ask(102, 40)
        self.heartbeat(0.5, asked=2)
        self.digest(0.5, [101, 102])
        rc, out = self.run_wd()
        self.assertEqual(rc, 0, out)
        self.assertTrue(out.startswith("OK "), out)
        self.assertIn("2 ledger ask(s)", out)
        self.assertNotIn("ALARM", out)

    def test_a_missing_heartbeat_is_an_alarm_not_an_assumption_of_health(self):
        # fail closed: a reader that cannot say it ran has not run. Silence here is the exact defect the alarm exists for.
        rc, out = self.run_wd()
        self.assertEqual(rc, 1, out)
        self.assertIn("ALARM missing:", out)

    def test_a_stale_heartbeat_pages_with_the_population_that_goes_unread(self):
        self.ask(101, 33)
        self.heartbeat(31, asked=262)
        self.digest(0.5, [101])
        rc, out = self.run_wd()
        self.assertEqual(rc, 1, out)
        self.assertIn("ALARM stale:", out)
        self.assertIn("262 asked codes", out)
        self.assertIn("claim-lane-resume-c2", out)

    def test_a_stale_digest_pages_even_when_the_heartbeat_is_fresh(self):
        # the heartbeat can be written by a check that then fails before it looks at anything
        self.ask(101, 31)
        self.heartbeat(0.2, asked=262)
        self.digest(31, [101])
        rc, out = self.run_wd()
        self.assertEqual(rc, 1, out)
        self.assertIn("ALARM digest:", out)
        self.assertIn("proof-check-2026-11-04", out)

    def test_a_digest_that_names_no_asks_is_not_healthy(self):
        self.heartbeat(0.2, asked=0)
        self.digest(0.2, [])
        rc, out = self.run_wd()
        self.assertEqual(rc, 1, out)
        self.assertIn("names no asks", out)

    def test_an_ask_the_reader_never_looked_at_is_the_unread_class(self):
        self.ask(101, 30)
        self.ask(102, 30)
        self.ask(103, 2)      # too young to call unread yet
        self.heartbeat(0.2, asked=1)
        self.digest(0.2, [101])
        rc, out = self.run_wd()
        self.assertEqual(rc, 1, out)
        self.assertIn("ALARM untracked: 1 ask(s)", out)
        self.assertIn("claim-102", out)
        self.assertNotIn("claim-103", out)

    def test_a_held_row_is_not_an_ask(self):
        self.ask(101, 30, sent=False)
        self.heartbeat(0.2, asked=1)
        self.digest(0.2, [101])
        rc, out = self.run_wd()
        self.assertEqual(rc, 0, out)
        self.assertIn("0 ledger ask(s)", out)

    def test_another_campaigns_asks_do_not_count(self):
        self.ask(101, 30, campaign="claim-status")
        self.heartbeat(0.2, asked=1)
        self.digest(0.2, [101])
        rc, out = self.run_wd()
        self.assertEqual(rc, 0, out)

    def test_it_says_it_cannot_measure_rather_than_reporting_healthy(self):
        self.heartbeat(0.2, asked=1)
        self.digest(0.2, [101])
        rc, out = self.run_wd(ledger=self.dir / "absent.sqlite3")
        self.assertEqual(rc, 2, out)
        self.assertIn("cannot measure:", out)

    def test_a_summary_on_an_alarm_run_is_a_state_line_not_an_ok_line(self):
        # "ALARM stale: ... 40.0h ago" immediately followed by "OK reader ran 40.0h ago" on a rc=1 run reads as a
        # healthy verdict. The summary still prints (a tick must be able to say what it saw), but it does not
        # claim OK while the same output carries an alarm.
        self.heartbeat(31, asked=262)
        self.digest(0.5, [])
        rc, out = self.run_wd()
        self.assertEqual(rc, 1, out)
        self.assertIn("\nSTATE reader ran 31.0h ago", out)
        self.assertNotIn("\nOK ", out)
        self.assertTrue(out.rstrip().splitlines()[-1].startswith("SIGNATURE "))

    def test_json_is_the_same_verdict(self):
        self.heartbeat(0.2, asked=0)
        self.digest(0.2, [])
        rc, out = self.run_wd("--json")
        self.assertEqual(rc, 1, out)
        d = json.loads(out)
        self.assertEqual(len(d["alarms"]), 1)
        self.assertIn("names no asks", d["alarms"][0])

    # --- QA #1758 Important 2: a future-dated artefact is an alarm, never freshness ----------------------
    def test_a_future_dated_heartbeat_is_an_alarm(self):
        # the exact fail-open the review named: age goes NEGATIVE, so `age > limit_h` is false and a stopped reader
        # with a skewed clock reads as fresh until the clock catches up.
        self.ask(101, 30)
        self.heartbeat(-3, asked=1)          # 3 hours in the FUTURE
        self.digest(0.2, [101])
        rc, out = self.run_wd()
        self.assertEqual(rc, 1, out)
        self.assertIn("ALARM future: the daily code check's last_run_at is 3.0h in the FUTURE", out)
        self.assertNotIn("ALARM stale:", out)

    def test_a_future_dated_digest_is_an_alarm(self):
        self.ask(101, 0.2)
        self.heartbeat(0.2, asked=1)
        self.digest(-2, [101])               # 2 hours in the FUTURE
        rc, out = self.run_wd()
        self.assertEqual(rc, 1, out)
        self.assertIn("ALARM future: the newest digest", out)
        self.assertIn("in the FUTURE", out)

    def test_a_future_dated_ask_is_an_alarm_not_an_untracked_silence(self):
        # a future sent_at makes `hours(now - sent)` negative, so the row would silently fall out of the untracked
        # test and be treated as too young to worry about - unmeasurable is not the same as young.
        self.ask(101, -4)
        self.heartbeat(0.2, asked=1)
        self.digest(0.2, [])
        rc, out = self.run_wd()
        self.assertEqual(rc, 1, out)
        self.assertIn("ALARM future: 1 ask(s) carry a sent_at in the FUTURE", out)
        self.assertIn("claim-101", out)

    def test_ordinary_clock_skew_is_not_an_alarm(self):
        # NTP slew of a minute or two is not a broken writer; the guard must not page on it.
        self.ask(101, 5)
        self.heartbeat(-0.01, asked=1)       # 36 seconds ahead
        self.digest(-0.01, [101])
        rc, out = self.run_wd()
        self.assertEqual(rc, 0, out)
        self.assertNotIn("ALARM", out)

    # --- QA #1758 Important 1: the cooldown key must not move on its own ---------------------------------
    def test_the_signature_is_stable_across_two_ticks_of_the_same_outage(self):
        # THE DEFECT: the tick hashed the watchdog's TEXT, which carries elapsed ages, so a persistent reader outage
        # produced a new digest every two hours and paged every time despite CLAIM_PROOF_REPEAT_MIN=360.
        self.ask(101, 31)
        self.ask(102, 31)
        self.heartbeat(31, asked=2)
        self.digest(31, [])
        rc1, out1 = self.run_wd()
        self.assertEqual(rc1, 1, out1)
        sig1 = [l for l in out1.splitlines() if l.startswith("SIGNATURE ")][-1]
        # two hours later, same outage, nothing repaired: every age in the text has moved
        two_h_later = NOW + timedelta(hours=2)
        p = subprocess.run([sys.executable, str(SCRIPT), "--state-dir", str(self.dir),
                            "--ledger", str(self.ledger), "--now", iso(two_h_later)],
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 1, p.stdout)
        sig2 = [l for l in p.stdout.splitlines() if l.startswith("SIGNATURE ")][-1]
        self.assertNotEqual(out1.replace("31.0h", ""), p.stdout, "the text must move (ages) - that is why it was wrong")
        self.assertEqual(sig1, sig2, "the same outage must keep the same signature, or the cooldown is dead")

    def test_the_signature_changes_when_the_alarm_set_changes(self):
        self.ask(101, 31)
        self.heartbeat(31, asked=1)
        self.digest(31, [101])
        rc1, out1 = self.run_wd()
        self.assertEqual(rc1, 1, out1)
        sig1 = [l for l in out1.splitlines() if l.startswith("SIGNATURE ")][-1]
        self.ask(102, 31)                    # one MORE unread ask: a worsening state must page at once
        rc2, out2 = self.run_wd()
        self.assertEqual(rc2, 1, out2)
        sig2 = [l for l in out2.splitlines() if l.startswith("SIGNATURE ")][-1]
        self.assertNotEqual(sig1, sig2)
        self.assertIn("claim-102", out2)

    def test_the_signature_names_the_affected_asks_not_the_counts(self):
        mod = self._module()
        self.assertEqual(mod.signature(["untracked-1", "stale"]), mod.signature(["stale", "untracked-1"]),
                         "order must not matter")
        self.assertNotEqual(mod.signature(["untracked-1"]), mod.signature(["untracked-2"]),
                            "a different ask is a different state")
        self.assertEqual(len(mod.signature([])), 16)

    def _module(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("claim_proof_check_watchdog_sig", SCRIPT)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod


class TickWiringTests(unittest.TestCase):
    """The alarm must run BEFORE the kill gate in the tick.

    A kill file stops the sender; the reader going stale is exactly when the asks already out stop being read, so the
    one tick that must still page about the reader is the one that then exits. This is a static order assertion - the
    behavioural proof is the first tick that runs with the alarm deployed (its state line is written every run).
    """

    def test_the_tick_calls_the_reader_alarm_before_the_kill_gate(self):
        src = (ROOT / "scripts" / "credit-verify-outbound.sh").read_text(encoding="utf-8")
        call = src.index("\nclaim_proof_check_alarm\n")
        gate = src.index('killed && { echo')
        self.assertLess(call, gate, "the reader alarm must be invoked above the kill gate")
        self.assertIn("PAGE NOT DELIVERED", src[call - 3000:call + 1],
                      "an undeliverable page must be stated, never swallowed")

    def test_the_repeat_cooldown_keys_on_the_signature_not_on_the_text(self):
        # QA #1758 Important 1: the text carries elapsed ages, so hashing it made CLAIM_PROOF_REPEAT_MIN dead -
        # a persistent outage changed the digest every tick and paged every two hours.
        src = (ROOT / "scripts" / "credit-verify-outbound.sh").read_text(encoding="utf-8")
        body = src[src.index("claim_proof_check_alarm() {"):src.index("\nclaim_proof_check_alarm\n")]
        self.assertIn("s/^SIGNATURE //p", body, "the marker must be keyed on the watchdog's signature line")
        self.assertLess(body.index("s/^SIGNATURE //p"), body.index('sha256sum'),
                        "the signature is read FIRST; the text hash is only the fallback for an older watchdog")


class MaintenanceGuardTests(unittest.TestCase):
    """A planned fleet window may pause the reader on purpose, and the guard may only ever SUPPRESS.

    The daily code check is a fleet job, so a maintenance window can legitimately stop it; paging "the reader is
    stale" through a window is exactly the false page scripts/hydra-maintenance.sh exists to prevent. What must
    never happen is the other direction: a helper that is missing, unrunnable or answers anything unexpected is
    NOT a maintenance window, so a broken guard cannot silence the alarm.
    """

    def _module(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("claim_proof_check_watchdog", SCRIPT)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def test_guard_is_structural_not_a_comment(self):
        src = SCRIPT.read_text(encoding="utf-8")
        self.assertIn('["bash", helper, "is-active"]', src)
        self.assertIn("def in_maintenance()", src)

    def test_maintenance_active_skips_with_a_state_line(self):
        mod = self._module()
        with unittest.mock.patch.object(mod, "in_maintenance", return_value=True), \
                unittest.mock.patch("sys.stdout") as out:
            rc = mod.main(["--state-dir", str(self.state), "--ledger", str(self.ledger)])
        self.assertEqual(rc, 0)
        self.assertIn("SKIPPED maintenance window active", "".join(c.args[0] for c in out.write.call_args_list))

    def test_guard_returns_false_when_the_helper_cannot_be_run(self):
        mod = self._module()
        with unittest.mock.patch("subprocess.run", side_effect=OSError("missing")):
            self.assertFalse(mod.in_maintenance(), "a guard that cannot be read must not silence the alarm")

    def test_guard_returns_false_on_a_nonzero_verdict(self):
        mod = self._module()
        done = unittest.mock.Mock(returncode=3)
        with unittest.mock.patch("subprocess.run", return_value=done):
            self.assertFalse(mod.in_maintenance())

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state = Path(self.tmp.name) / "state"
        self.state.mkdir()
        self.ledger = Path(self.tmp.name) / "ledger.sqlite3"
        con = sqlite3.connect(self.ledger)
        con.execute("create table verify_messages (campaign text, request_ids_json text, sent_at text)")
        con.commit()
        con.close()
        (self.state / "last-run.json").write_text(
            json.dumps({"owner": "t", "last_run_at": iso(NOW - timedelta(hours=1)), "asked": 0}),
            encoding="utf-8")
        (self.state / "proof-check-2026-11-04-digest.json").write_text(
            json.dumps({"claim_ids": []}), encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
