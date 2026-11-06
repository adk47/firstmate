"""sentinel-demote: the seeded demotion harness and the invariants that make it safe.

The one case the dispatch names explicitly (§5): **a seeded manipulated HIGH action on a
`canary` row demotes it to `shadow`, writes the kill file, and the mirror PR body
renders** — end to end, with fakes, no network and no host touch.

Everything else here exists because a demotion engine that is wrong in the other
direction is worse than none:
  * the runtime state can only demote (a promote is a PR, never a write);
  * a kill file path outside /etc/hydra is refused even if a registry row asks for it;
  * "we could not measure it" never reads as healthy, and never fires a trigger either;
  * no account id, user id or conversation id ever reaches a Slack line or a PR body;
  * `promote` renders and refuses — it never flips a state.

stdlib unittest only (no pytest, no network), like the rest of tests/.
"""
from __future__ import annotations

import contextlib
import io
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
SCRIPTS = REPO / "scripts"
sys.path.insert(0, str(SCRIPTS))

from sentinel import demote, mirror, outcomes, registry, report  # noqa: E402

FIXTURE_REGISTRY = REPO / "tests" / "fixtures" / "sentinel" / "registry.json"
NOW = datetime(2026, 11, 3, 2, 30, tzinfo=timezone.utc)


def utc(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


# ── fake stores (the real schemas, not mocks) ─────────────────────────────────
class Fakes:
    """A temp dir holding the six source stores the tick reads."""

    def __init__(self, tmp: Path):
        self.tmp = tmp
        self.ledger = tmp / "action-ledger.sqlite"
        self.evals = tmp / "evaluations.sqlite"
        self.decisions = tmp / "decisions.sqlite"
        self.complaints = tmp / "complaints.jsonl"
        self.spot = tmp / "spot-audit.jsonl"
        self.contra = tmp / "contra-appr.jsonl"
        self.paths = {
            "action_ledger_db": str(self.ledger),
            "contra_store": str(self.contra),
            "decisions_db": str(self.decisions),
            "complaints_store": str(self.complaints),
            "spot_audit_store": str(self.spot),
            "evaluations_db": str(self.evals),
        }

    # ACTION-AUDIT (action-audit-ledger-a1 §1)
    def action_ledger(self, rows):
        db = sqlite3.connect(self.ledger)
        db.executescript(
            """
            CREATE TABLE action_ledger (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              at TEXT NOT NULL,
              actor_kind TEXT, actor_id TEXT,
              action_type TEXT NOT NULL,
              target_ids TEXT, evidence_ids TEXT, inverse TEXT,
              risk_class TEXT NOT NULL DEFAULT 'normal',
              capability_id TEXT,
              reverted_at TEXT, reverted_by TEXT
            );
            CREATE TRIGGER action_ledger_no_update BEFORE UPDATE ON action_ledger
            BEGIN SELECT RAISE(ABORT,'action_ledger is append-only'); END;
            """
        )
        for r in rows:
            db.execute(
                "INSERT INTO action_ledger (at, actor_kind, actor_id, action_type, risk_class,"
                " capability_id, reverted_at, reverted_by)"
                " VALUES (?,?,?,?,?,?,?,?)",
                (r["at"], r.get("actor_kind", "ops_agent"), r.get("actor_id", "agent-7"),
                 r.get("action_type", "credit.approve"), r.get("risk_class", "high"),
                 r.get("capability_id"), r.get("reverted_at"), r.get("reverted_by")),
            )
        db.commit()
        db.close()

    # The watcher's verdict rows (A1 §2 — verdict ∈ consistent|manipulated|unverifiable)
    def audit_verdicts(self, rows):
        db = sqlite3.connect(self.ledger)
        db.executescript(
            """
            CREATE TABLE audit_verdicts (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              at TEXT NOT NULL, action_id INTEGER, campaign TEXT,
              verdict TEXT NOT NULL, capability_id TEXT, evidence TEXT
            );
            """
        )
        for r in rows:
            db.execute(
                "INSERT INTO audit_verdicts (at, action_id, verdict, capability_id, evidence)"
                " VALUES (?,?,?,?,?)",
                (r["at"], r.get("action_id", 1), r["verdict"], r.get("capability_id"), r.get("evidence")),
            )
        db.commit()
        db.close()

    # Sentinel evaluations (sentinel-core-s0 §2.5)
    def evaluations(self, rows):
        db = sqlite3.connect(self.evals)
        db.executescript(
            """
            CREATE TABLE IF NOT EXISTS sentinel_evaluations (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              at TEXT NOT NULL, intake TEXT, request_ref TEXT, class TEXT, sub_class TEXT,
              capability_id TEXT, band TEXT, decision TEXT,
              waiting_on TEXT, due_at TEXT, agreed INTEGER, requested_action TEXT
            );
            """
        )
        db.execute("DELETE FROM sentinel_evaluations")
        for r in rows:
            db.execute(
                "INSERT INTO sentinel_evaluations (at, intake, request_ref, class, sub_class,"
                " capability_id, band, decision, waiting_on, due_at, agreed, requested_action)"
                " VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                (r["at"], r.get("intake", "intercom"), r.get("request_ref", "conv-1"),
                 r.get("class", "R1"), r.get("sub_class", "single"), r.get("capability_id"),
                 r.get("band", "GREEN"), r.get("decision", "act"),
                 r.get("waiting_on"), r.get("due_at"), r.get("agreed"),
                 r.get("requested_action")),
            )
        db.commit()
        db.close()

    def jsonl(self, path: Path, rows):
        path.write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.registry_path = self.tmp / "registry.json"
        self.registry_path.write_text(FIXTURE_REGISTRY.read_text(encoding="utf-8"), encoding="utf-8")
        self.runtime_path = self.tmp / "registry-state.json"
        self.kill_root = self.tmp / "etc-hydra"
        self.kill_root.mkdir()
        self.fakes = Fakes(self.tmp)
        self.pages = []
        # Every host lever this module touches is redirected into the temp dir.
        self._env = mock.patch.dict(os.environ, {
            "SENTINEL_KILL_ROOT": str(self.kill_root),
            "SENTINEL_DEMOTE_KILL_FILE": str(self.tmp / "sentinel-demote.disabled"),
            "SENTINEL_KILL_FILE": str(self.tmp / "sentinel.disabled"),
            "SENTINEL_BLIND_PAGE_STATE": str(self.tmp / "blind-page.json"),
            "SENTINEL_REGISTRY_SEEN": str(self.tmp / "registry-seen"),
            "SENTINEL_DEMOTION_LOG": str(self.tmp / "demotions.jsonl"),
            "SENTINEL_CAP_TRIPS_STORE": str(self.tmp / "cap-trips.jsonl"),
            "SENTINEL_LOCK_FILE": str(self.tmp / "run.lock"),
            "SENTINEL_LOCK_TIMEOUT": "2",
        })
        self._env.start()
        # Modules bind these paths at import time, so rebind them for the test as well.
        self._consts = mock.patch.multiple(
            demote,
            KILL_ROOT=self.kill_root,
            DEMOTE_KILL_FILE=self.tmp / "sentinel-demote.disabled",
            SENTINEL_KILL_FILE=self.tmp / "sentinel.disabled",
            BLIND_PAGE_STATE=self.tmp / "blind-page.json",
            REGISTRY_SEEN=self.tmp / "registry-seen",
            DEMOTION_LOG=self.tmp / "demotions.jsonl",
            LOCK_FILE=self.tmp / "run.lock",
            LOCK_TIMEOUT_S=2,
        )
        self._consts.start()
        self._slack = mock.patch.object(demote, "_slack", side_effect=self._record_page)
        self._slack.start()

    def tearDown(self):
        self._slack.stop()
        self._consts.stop()
        self._env.stop()
        self._tmp.cleanup()

    def _record_page(self, text, critical):
        self.pages.append((text, critical))
        return True

    def run_cli(self, *argv, now=NOW):
        """Run the CLI exactly as the unit does, with a pinned clock."""
        args = list(argv) + [
            "--registry", str(self.registry_path),
            "--runtime-state", str(self.runtime_path),
            "--paths-json", json.dumps(self.fakes.paths),
            "--no-page",
        ]
        with mock.patch.object(demote, "_now", create=True, return_value=now):
            return demote.main(args)

    def run_tick(self, *argv, now=NOW):
        """cmd_run directly (so pages are captured) with the clock pinned."""
        args = demote.build_parser().parse_args(list(argv) + [
            "--registry", str(self.registry_path),
            "--runtime-state", str(self.runtime_path),
            "--paths-json", json.dumps(self.fakes.paths),
        ])
        return demote.cmd_run(args, now=now)

    def runtime(self):
        return registry.RuntimeState(self.runtime_path).load()

    def registry_doc(self):
        return json.loads(self.registry_path.read_text(encoding="utf-8"))


# ── the seeded case (§5 of the dispatch) ──────────────────────────────────────
class SeededDemotion(Base):
    def seed_manipulated_high(self):
        """One HIGH-risk, manipulated, already-reverted action on a canary capability."""
        self.fakes.action_ledger([{
            "at": utc(NOW - timedelta(hours=3)),
            "action_type": "credit.approve",
            "risk_class": "high",
            "capability_id": "credit.add.decide",
            "reverted_at": utc(NOW - timedelta(hours=2)),
            "reverted_by": "action-audit",
            "actor_id": "agent-7",
        }])
        self.fakes.audit_verdicts([{
            "at": utc(NOW - timedelta(hours=2)),
            "verdict": "manipulated",
            "capability_id": "credit.add.decide",
            "evidence": "injection-watch row: prompt-crafted inbound 10 min before the approve",
        }])

    def test_manipulated_high_action_demotes_canary_to_shadow_and_drops_kill_file(self):
        self.seed_manipulated_high()
        rc = self.run_tick("run", now=NOW)
        self.assertEqual(rc, demote.EXIT_TRIPPED)

        rt = self.runtime()
        self.assertEqual(rt.state_of("credit.add.decide"), "shadow",
                         "canary must step down to shadow, never further")
        ent = rt.entry("credit.add.decide")
        self.assertEqual(ent["previous"], "canary")
        self.assertIn("audit_fail_any", ent["reason"])

        kill = self.kill_root / "credit-trust-decide.disabled"
        self.assertTrue(kill.exists(), "the capability's kill file must exist on disk")
        body = kill.read_text(encoding="utf-8")
        self.assertIn("sentinel-demote", body)
        self.assertIn("credit.add.decide", body)

        # No other capability was touched.
        self.assertIsNone(rt.state_of("credit.remove.self"))
        self.assertIsNone(rt.state_of("support.answer"))

        # The page fired critical, names counts, and names no account.
        critical = [t for t, c in self.pages if c]
        self.assertEqual(len(critical), 1)
        self.assertIn("credit.add.decide", critical[0])
        self.assertIn("canary →", critical[0])
        self.assertNotIn("agent-7", critical[0])

        # The demotion is on the local evidence log.
        log = (self.tmp / "demotions.jsonl").read_text(encoding="utf-8").strip().splitlines()
        self.assertEqual(len(log), 1)
        self.assertEqual(registry.effective_state(
            registry.index_by_id(registry.load(self.registry_path))["credit.add.decide"], rt), "shadow")

    def test_mirror_pr_body_renders_and_the_repo_row_flips(self):
        self.seed_manipulated_high()
        trip = demote.evaluate(
            registry.load(self.registry_path),
            self._counters(),
            registry.RuntimeState(self.runtime_path),
            now=NOW,
        )
        self.assertEqual(len(trip), 1)
        doc = mirror.apply_demotions(self.registry_doc(), trip, utc(NOW))
        row = registry.index_by_id(doc["capabilities"])["credit.add.decide"]
        self.assertEqual(row["rollout"]["state"], "shadow")
        self.assertEqual(row["rollout"]["previous_state"], "canary")
        self.assertEqual(row["rollout"]["since"], utc(NOW))
        self.assertEqual(row["rollout"]["demoted"]["kill_file"],
                         "/etc/hydra/credit-trust-decide.disabled")
        # approval_ref is NOT cleared: the promotion ruling stays on the record.
        self.assertEqual(row["rollout"]["approval_ref"], "ruling-sentinel-1028")

        body = report.mirror_pr_body(trip, utc(NOW), mirror.REGISTRY_REL)
        self.assertIn("sentinel-demote: mirror a HOST demotion", body)
        self.assertIn("| `credit.add.decide` | canary | **shadow** |", body)
        self.assertIn("audit_fail_any", body)
        self.assertIn("does not promote anything", body)
        self.assertIn("three independent stops", body.lower())
        # The third stop is left to the reviewer, deliberately.
        self.assertIn("does not touch the actor's own flag", body)
        self.assertNotIn("agent-7", body)

    def _counters(self):
        rows = registry.load(self.registry_path)
        c = outcomes.collect(paths=self.fakes.paths, attribution=registry.attribution_map(rows), now=NOW)
        outcomes.blind_counters(rows, c)
        return c

    def test_pr_dry_run_renders_the_body_and_records_no_url(self):
        self.seed_manipulated_high()
        mirror_repo = self.tmp / "mirror"
        (mirror_repo / ".git").mkdir(parents=True)
        (mirror_repo / "policies").mkdir()
        (mirror_repo / mirror.REGISTRY_REL).write_text(self.registry_path.read_text(), encoding="utf-8")
        rc = self.run_tick("run", "--pr-dry-run", "--mirror-repo", str(mirror_repo), now=NOW)
        self.assertEqual(rc, demote.EXIT_TRIPPED)
        self.assertEqual(self.runtime().state_of("credit.add.decide"), "shadow")
        self.assertIsNone(self.runtime().entry("credit.add.decide").get("mirror_pr"),
                          "a rendered body is not a PR and must never be recorded as one")
        # The repo file was NOT rewritten: nothing pushed, nothing mirrored.
        self.assertEqual(json.loads((mirror_repo / mirror.REGISTRY_REL).read_text())
                         ["capabilities"][1]["rollout"]["state"], "canary")

    def test_a_kill_file_that_could_not_be_written_is_paged_as_failed_not_dropped(self):
        self.seed_manipulated_high()
        with mock.patch.object(demote, "drop_kill_file", return_value=(False, "EACCES (simulated)")):
            self.run_tick("run", now=NOW)
        self.assertEqual(self.runtime().state_of("credit.add.decide"), "shadow",
                         "the registry stop is independent of the kill file")
        critical = "\n".join(t for t, c in self.pages if c)
        self.assertIn("was NOT dropped", critical)
        self.assertIn("Registry state was still demoted", critical)
        self.assertNotIn("kill file dropped: `", critical)

    def test_second_tick_does_not_repage_the_same_state(self):
        self.seed_manipulated_high()
        self.assertEqual(self.run_tick("run", now=NOW), demote.EXIT_TRIPPED)
        self.pages.clear()
        self.assertEqual(self.run_tick("run", now=NOW + timedelta(minutes=30)), demote.EXIT_TRIPPED)
        self.assertEqual([p for p in self.pages if p[1]], [],
                         "shadow->shadow inside the dedupe window must not page again")

    def test_reverts_threshold_demotes_live_to_canary_only_one_step(self):
        now = NOW
        self.fakes.action_ledger([
            {"at": utc(now - timedelta(hours=1 + i)), "action_type": "profile.edit",
             "capability_id": "credit.remove.self", "reverted_at": utc(now - timedelta(hours=i))}
            for i in range(6)
        ])
        rc = self.run_tick("run", now=NOW)
        self.assertEqual(rc, demote.EXIT_TRIPPED)
        rt = self.runtime()
        self.assertEqual(rt.state_of("credit.remove.self"), "canary",
                         "live steps to canary; it must not jump to shadow")
        self.assertTrue((self.kill_root / "sentinel-credit-remove-self.disabled").exists())

    def test_audit_fail_any_fires_on_a_single_spot_audit_fail(self):
        self.fakes.jsonl(self.fakes.spot, [{
            "at": utc(NOW - timedelta(hours=2)), "capability_id": "credit.add.decide",
            "ok": False, "sample": "fable-2h", "why": "the inverse did not restore the row",
        }])
        self.assertEqual(self.run_tick("run", "--fast", now=NOW), demote.EXIT_TRIPPED)
        self.assertEqual(self.runtime().state_of("credit.add.decide"), "shadow")

    def test_revert_rows_are_not_counted_as_reverted_actions(self):
        """A revert is itself a ledger row (A1: reverts are revertible). Counting a revert
        row as a reverted action would let one bad approve trip a threshold twice."""
        self.fakes.action_ledger([
            {"at": utc(NOW - timedelta(hours=4)), "action_type": "action.revert",
             "capability_id": None, "reverted_at": utc(NOW - timedelta(hours=3))},
        ])
        rows = registry.load(self.registry_path)
        c = outcomes.collect(paths=self.fakes.paths,
                            attribution=registry.attribution_map(rows), now=NOW)
        self.assertNotIn("reverts_7d", c.of("credit.add.decide"))


    def test_mirror_checkout_that_already_agrees_opens_nothing_and_does_not_page_a_failure(self):
        """`git status` empty means the repo ALREADY carries the demotion (an earlier
        tick's PR, or a merge between ticks). That is not a failure and must not page
        like one — but it must not be recorded as a URL either."""
        self.seed_manipulated_high()
        mirror_repo = self.tmp / "mirror2"
        (mirror_repo / ".git").mkdir(parents=True)
        (mirror_repo / "policies").mkdir()
        (mirror_repo / mirror.REGISTRY_REL).write_text(self.registry_path.read_text(), encoding="utf-8")
        with mock.patch.object(mirror, "open_pr", side_effect=mirror.MirrorUnavailable(
                "nothing to commit on sentinel/demote-x (the repo already has this state)")):
            rc = self.run_tick("run", "--mirror-repo", str(mirror_repo), now=NOW)
        self.assertEqual(rc, demote.EXIT_TRIPPED)
        self.assertIsNone(self.runtime().entry("credit.add.decide").get("mirror_pr"))
        page = [t for t, crit in self.pages if crit][0]
        self.assertIn("already carries this state", page)
        self.assertNotIn("NOT opened", page)


# ── thresholds and windows ────────────────────────────────────────────────────
class RevertCounting(Base):
    """QA r5: the `reverts_7d` counter was windowed on the action's CREATION time and
    counted revert rows as reverts — so a capability could revert daily and read zero,
    or read double and be demoted while healthy."""

    def _reverts(self, rows):
        self.fakes.action_ledger(rows)
        c = outcomes.collect(paths=self.fakes.paths, attribution={}, now=NOW)
        outcomes.blind_counters([], c)
        return c.per_cap.get("credit.add.decide", {}).get("reverts_7d", 0)

    def test_an_old_action_reverted_this_week_counts(self):
        row = {"at": utc(NOW - timedelta(days=30)), "capability_id": "credit.add.decide",
               "action_type": "credit.approve", "reverted_at": utc(NOW - timedelta(days=1))}
        self.assertEqual(self._reverts([row]), 1,
                         "reverted yesterday is a revert this week, whenever it was created")

    def test_an_old_action_reverted_long_ago_does_not_count(self):
        row = {"at": utc(NOW - timedelta(days=30)), "capability_id": "credit.add.decide",
               "action_type": "credit.approve", "reverted_at": utc(NOW - timedelta(days=20))}
        self.assertEqual(self._reverts([row]), 0)

    def test_a_reverted_revert_does_not_double_count(self):
        rows = [
            {"at": utc(NOW - timedelta(days=1)), "capability_id": "credit.add.decide",
             "action_type": "credit.approve", "reverted_at": utc(NOW - timedelta(days=1))},
            {"at": utc(NOW - timedelta(days=1)), "capability_id": "credit.add.decide",
             "action_type": "credit.revert", "reverted_at": utc(NOW - timedelta(days=1))},
        ]
        self.assertEqual(self._reverts(rows), 1,
                         "the revert row is the other half of the same revert, not a second one")

    def test_two_genuine_reverts_still_count_twice(self):
        rows = [
            {"at": utc(NOW - timedelta(days=1)), "capability_id": "credit.add.decide",
             "action_type": "credit.approve", "reverted_at": utc(NOW - timedelta(days=1))},
            {"at": utc(NOW - timedelta(days=2)), "capability_id": "credit.add.decide",
             "action_type": "credit.approve", "reverted_at": utc(NOW - timedelta(days=1))},
        ]
        self.assertEqual(self._reverts(rows), 2)


class WatcherVerdicts(Base):
    """QA r11: `action_ledger()` returned early when the revert ledger was absent or
    lacked a time/reverted column, which also skipped `_watcher_verdicts` — so a store
    carrying a fresh `manipulated` verdict but no usable ledger recorded no
    `manipulated_7d` at all, and the strongest manipulation signal could not demote."""

    def _verdicts(self):
        c = outcomes.collect(paths=self.fakes.paths, attribution={}, now=NOW)
        outcomes.blind_counters([], c)
        return c.per_cap.get("credit.add.decide", {}).get("manipulated_7d", 0)

    def test_a_verdict_is_counted_when_the_ledger_table_is_absent(self):
        db = sqlite3.connect(self.fakes.ledger)
        db.executescript(
            """
            CREATE TABLE audit_verdicts (
              at TEXT NOT NULL, verdict TEXT NOT NULL,
              capability_id TEXT, action_type TEXT
            );
            """
        )
        db.execute("INSERT INTO audit_verdicts VALUES (?,?,?,?)",
                   (utc(NOW - timedelta(hours=2)), "manipulated", "credit.add.decide",
                    "credit.approve"))
        db.commit()
        db.close()
        self.assertEqual(self._verdicts(), 1,
                         "a missing revert table is a fact about reverts, not about verdicts")

    def test_a_verdict_is_counted_when_the_ledger_lacks_a_reverted_column(self):
        db = sqlite3.connect(self.fakes.ledger)
        db.executescript(
            """
            CREATE TABLE action_ledger (
              at TEXT NOT NULL, action_type TEXT NOT NULL, capability_id TEXT,
              watcher_verdict TEXT
            );
            """
        )
        db.execute("INSERT INTO action_ledger VALUES (?,?,?,?)",
                   (utc(NOW - timedelta(hours=2)), "credit.approve", "credit.add.decide",
                    "manipulated"))
        db.commit()
        db.close()
        self.assertEqual(self._verdicts(), 1)


class Thresholds(Base):
    def test_overdue_trigger_is_strictly_greater_than_five_percent_of_the_day(self):
        def rows(late, total):
            out = []
            for i in range(total):
                is_late = i < late
                out.append({
                    "at": utc(NOW - timedelta(hours=6)),
                    "capability_id": "support.answer",
                    "decision": "decide_within_24h",
                    "waiting_on": "us",
                    "due_at": utc(NOW - timedelta(hours=1)) if is_late else utc(NOW + timedelta(hours=6)),
                })
            return out

        self.fakes.evaluations(rows(1, 20))  # exactly 5 %
        self.assertNotEqual(self.run_tick("run", now=NOW), demote.EXIT_TRIPPED)
        self.assertIsNone(self.runtime().state_of("support.answer"))

        self.fakes.evals.unlink()
        self.fakes.evaluations(rows(2, 20))  # 10 %
        self.assertEqual(self.run_tick("run", now=NOW), demote.EXIT_TRIPPED)
        self.assertEqual(self.runtime().state_of("support.answer"), "canary")

    def test_old_rows_outside_the_7_day_window_do_not_count(self):
        self.fakes.action_ledger([
            {"at": utc(NOW - timedelta(days=9, hours=i)), "capability_id": "credit.remove.self",
             "reverted_at": utc(NOW - timedelta(days=9))} for i in range(10)
        ])
        self.assertNotEqual(self.run_tick("run", now=NOW), demote.EXIT_TRIPPED)

    def test_fast_mode_evaluates_only_the_audit_and_manipulated_triggers(self):
        # 6 reverts on a row whose reverts threshold is 5, but no audit failure.
        self.fakes.action_ledger([
            {"at": utc(NOW - timedelta(hours=i + 1)), "capability_id": "credit.remove.self",
             "reverted_at": utc(NOW - timedelta(hours=i))} for i in range(6)
        ])
        self.assertEqual(self.run_tick("run", "--fast", now=NOW), demote.EXIT_OK,
                         "the hourly tick must not act on a slow counter")
        self.assertIsNone(self.runtime().state_of("credit.remove.self"))
        self.assertEqual(self.run_tick("run", now=NOW), demote.EXIT_TRIPPED,
                         "the nightly tick sees every trigger")

    def test_dry_run_changes_nothing(self):
        self.fakes.action_ledger([
            {"at": utc(NOW - timedelta(hours=i + 1)), "capability_id": "credit.remove.self",
             "reverted_at": utc(NOW - timedelta(hours=i))} for i in range(6)
        ])
        rc = self.run_cli("run", "--dry-run", "--json", now=NOW)
        self.assertEqual(rc, demote.EXIT_TRIPPED)
        self.assertFalse(self.runtime_path.exists(), "dry-run must not write the runtime state")
        self.assertFalse((self.kill_root / "sentinel-credit-remove-self.disabled").exists())


# ── missing sources ──────────────────────────────────────────────────────────
class Unmeasured(Base):
    def test_an_unattributable_overdue_source_is_unknown_not_ok(self):
        """QA r5: an evaluation table with at/waiting_on/due_at but no capability column
        reported `ok` with `per_cap={}` over a genuinely overdue row — so every
        `overdue_pct` trigger was unable to fire while reading as measured."""
        import sqlite3
        db = self.tmp / "no-cap.sqlite"
        conn = sqlite3.connect(db)
        conn.execute("CREATE TABLE sentinel_evaluations (at TEXT, waiting_on TEXT, due_at TEXT)")
        conn.execute("INSERT INTO sentinel_evaluations VALUES (?,?,?)",
                     (utc(NOW - timedelta(hours=2)), "us", utc(NOW - timedelta(hours=1))))
        conn.commit()
        conn.close()
        c = outcomes.Counters(window_start=outcomes.utc(NOW - timedelta(days=7)),
                              window_end=outcomes.utc(NOW))
        outcomes.overdue(c, str(db), NOW)
        self.assertEqual([s.status for s in c.sources], ["unknown"])
        self.assertIn("capability_id", c.sources[0].detail)
        self.assertEqual(c.per_cap, {}, "nothing may be attributed to a capability")
        # ...and the same store WITH the column attributes the row normally.
        conn = sqlite3.connect(db)
        conn.execute("DROP TABLE sentinel_evaluations")
        conn.execute("CREATE TABLE sentinel_evaluations (at TEXT, waiting_on TEXT, due_at TEXT,"
                     " capability_id TEXT)")
        conn.execute("INSERT INTO sentinel_evaluations VALUES (?,?,?,?)",
                     (utc(NOW - timedelta(hours=2)), "us", utc(NOW - timedelta(hours=1)),
                      "credit.add.decide"))
        conn.commit()
        conn.close()
        c2 = outcomes.Counters(window_start=outcomes.utc(NOW - timedelta(days=7)),
                               window_end=outcomes.utc(NOW))
        outcomes.overdue(c2, str(db), NOW)
        self.assertEqual([s.status for s in c2.sources], ["ok"])
        self.assertEqual(c2.per_cap["credit.add.decide"]["overdue_rows"], 1.0)

    def test_the_overdue_trigger_cannot_fire_off_an_unattributable_store(self):
        """The point of `unknown`: blind reports it and no capability can be demoted on it."""
        import sqlite3
        db = self.tmp / "no-cap.sqlite"
        conn = sqlite3.connect(db)
        conn.execute("CREATE TABLE sentinel_evaluations (at TEXT, waiting_on TEXT, due_at TEXT)")
        for i in range(60):
            conn.execute("INSERT INTO sentinel_evaluations VALUES (?,?,?)",
                         (utc(NOW - timedelta(hours=2)), "us", utc(NOW - timedelta(hours=1))))
        conn.commit()
        conn.close()
        self.fakes.paths["evaluations_db"] = str(db)
        self.assertEqual(self.run_tick("run", now=NOW), demote.EXIT_OK,
                         "60 overdue rows must not demote a capability it cannot attribute")
        out = io.StringIO()
        with mock.patch("sys.stdout", out):
            rc = self.run_cli("digest", "--json", now=NOW)
        self.assertEqual(rc, demote.EXIT_OK)
        doc = json.loads(out.getvalue())
        self.assertEqual(doc["counters"], {}, "an unattributable store credits nobody")
        self.assertTrue(any(s["status"] == "unknown" for s in doc["sources"]),
                        "the digest must show the source as unknown, not ok")

    def test_no_sources_means_unknown_and_no_demotion(self):
        for p in (self.fakes.ledger, self.fakes.evals, self.fakes.decisions,
                  self.fakes.complaints, self.fakes.spot, self.fakes.contra):
            if p.exists():
                p.unlink()
        self.assertEqual(self.run_tick("run", now=NOW), demote.EXIT_OK)
        self.assertFalse(self.runtime_path.exists())
        self.assertEqual([p for p in self.pages if p[1]], [], "no source is not an alert storm")

        rows = registry.load(self.registry_path)
        c = outcomes.collect(paths=self.fakes.paths, attribution=registry.attribution_map(rows), now=NOW)
        outcomes.blind_counters(rows, c)
        text = report.digest(rows, c, {"credit.remove.self": "live"}, utc(NOW))
        self.assertIn("UNMEASURED", text)
        self.assertIn("cannot fire", text)
        self.assertIn("not evidence of health", text)

    def test_a_source_that_raises_is_unknown_not_fatal(self):
        (self.tmp / "garbage.sqlite").write_text("this is not a database", encoding="utf-8")
        paths = dict(self.fakes.paths, action_ledger_db=str(self.tmp / "garbage.sqlite"))
        rows = registry.load(self.registry_path)
        c = outcomes.collect(paths=paths, attribution=registry.attribution_map(rows), now=NOW)
        self.assertIn(c.status("action_ledger"), ("unknown", "absent"))

    def test_an_unmeasured_trigger_blocks_promotion(self):
        rows = registry.load(self.registry_path)
        c = outcomes.collect(paths={k: str(self.tmp / f"missing-{k}") for k in self.fakes.paths},
                             attribution=registry.attribution_map(rows), now=NOW)
        outcomes.blind_counters(rows, c)
        row = registry.index_by_id(rows)["credit.remove.self"]
        gates = demote._parity_gates(row, c, row["rollout"], "ruling-x", NOW, None)
        self.assertFalse(gates["demotion_triggers"]["pass"])
        self.assertIn("UNMEASURED", gates["demotion_triggers"]["measured"])


# ── the registry contract ────────────────────────────────────────────────────
class RegistryContract(Base):
    def test_a_registry_that_has_not_landed_yet_is_a_clean_skip_not_a_page(self):
        """sentinel-core-s0 has not merged the registry yet, so exit 2 is the expected
        state of the world: the units skip it (ConditionPathExists) and 2 is in
        SuccessExitStatus. Paging ~1/day about a file another task owns is how an alert
        channel gets ignored — but the exit code must still be non-zero."""
        rc = demote.main(["run", "--registry", str(self.tmp / "absent.json"),
                          "--runtime-state", str(self.runtime_path),
                          "--paths-json", json.dumps(self.fakes.paths)])
        self.assertEqual(rc, demote.EXIT_NO_REGISTRY)
        self.assertEqual(rc, 2)
        self.assertEqual(self.pages, [], "a not-yet-landed registry must not page")
        self.assertFalse(self.runtime_path.exists())

    def test_a_registry_that_vanishes_after_a_good_load_pages_and_exits_4(self):
        """QA r11: a missing registry was ALWAYS a clean exit 2, and the units also gated
        on ConditionPathExists, so a deleted or failed-to-deploy registry left automatic
        demotion blind with no page and no failed unit. "Never landed" and "was here and
        is gone" are different worlds: the first is expected, the second is an outage."""
        # A good tick records that this host has loaded a registry.
        self.assertEqual(self.run_tick("run", "--nightly"), demote.EXIT_OK)
        self.assertTrue((self.tmp / "registry-seen").exists())
        # Now the registry disappears.
        self.registry_path.unlink()
        self.pages.clear()
        rc = self.run_tick("run", "--nightly")
        self.assertEqual(rc, demote.EXIT_BAD_STATE)
        self.assertEqual(rc, 4)
        self.assertTrue(self.pages, "a vanished registry must page")
        self.assertIn("disappeared after a successful load", self.pages[0][0])

    def test_a_registry_that_exists_but_is_unusable_pages_and_exits_4(self):
        bad = self.tmp / "bad-registry.json"
        bad.write_text('{"capabilities": [{"id": ""}]}', encoding="utf-8")
        rc = demote.main(["run", "--registry", str(bad),
                          "--runtime-state", str(self.runtime_path),
                          "--paths-json", json.dumps(self.fakes.paths)])
        self.assertEqual(rc, demote.EXIT_BAD_STATE)
        self.assertEqual(demote.EXIT_BAD_STATE, 4)
        self.assertTrue(any("cannot demote anything" in t for t, _ in self.pages),
                        "a broken registry must page (the unit also fails: exit 4)")
        self.assertFalse(self.runtime_path.exists())

    def test_missing_registry_is_loud_and_changes_nothing(self):
        self.registry_path.unlink()
        rc = self.run_cli("run", "--no-page", now=NOW)
        self.assertEqual(rc, demote.EXIT_NO_REGISTRY)
        self.assertFalse(self.runtime_path.exists())

    def test_invalid_state_is_refused(self):
        doc = self.registry_doc()
        doc["capabilities"][0]["rollout"]["state"] = "enabled"
        self.registry_path.write_text(json.dumps(doc), encoding="utf-8")
        with self.assertRaises(registry.RegistryInvalid):
            registry.load(self.registry_path)

    def test_a_row_without_a_demotion_block_cannot_be_registered(self):
        doc = self.registry_doc()
        del doc["capabilities"][1]["demotion"]
        self.registry_path.write_text(json.dumps(doc), encoding="utf-8")
        with self.assertRaises(registry.RegistryInvalid):
            registry.load(self.registry_path)

    def test_duplicate_ids_are_refused(self):
        doc = self.registry_doc()
        doc["capabilities"].append(dict(doc["capabilities"][0]))
        self.registry_path.write_text(json.dumps(doc), encoding="utf-8")
        with self.assertRaises(registry.RegistryInvalid):
            registry.load(self.registry_path)

    def test_kill_file_outside_etc_hydra_is_refused(self):
        for bad in ("/tmp/x.disabled", "/etc/hydra/../passwd.disabled", "/etc/hydra/x",
                    "/etc/shadow", "", "/etc/hydra/sub/x.disabled"):
            with self.assertRaises(registry.RegistryInvalid, msg=bad):
                registry.kill_file_of({"id": "c", "kill_file": bad})
        self.assertEqual(registry.kill_file_of({"id": "c", "kill_file": "/etc/hydra/a-b_c.1.disabled"}),
                         "/etc/hydra/a-b_c.1.disabled")
        ok, why = demote.drop_kill_file("/tmp/not-a-kill-file", "x")
        self.assertFalse(ok)
        self.assertIn("refusing", why)

    def test_runtime_state_can_only_demote(self):
        rows = registry.index_by_id(registry.load(self.registry_path))
        rt = registry.RuntimeState(self.runtime_path)
        rt.set_state("credit.remove.self", "canary", reason="t", at=utc(NOW), previous="live")
        rt.save()
        rt2 = registry.RuntimeState(self.runtime_path).load()
        self.assertEqual(registry.effective_state(rows["credit.remove.self"], rt2), "canary")
        with self.assertRaises(registry.RegistryInvalid):
            rt2.set_state("credit.remove.self", "live", reason="promote? no", at=utc(NOW))

        # A repo row that is already shadow is never raised by a stale host row.
        rt2.set_state("profile.edit.self", "shadow", reason="t", at=utc(NOW))
        self.assertEqual(registry.effective_state(rows["profile.edit.self"], rt2), "shadow")

    def test_a_malformed_runtime_state_file_is_an_error_never_a_reset(self):
        """`{}` or `{'capabilities': []}` parse fine. Treating them as `no demotions`
        reads a demoted capability back at its repo state and lets the next tick
        overwrite the evidence — so every unexpected shape must raise."""
        for payload in ({}, {"capabilities": []}, {"capabilities": "x"},
                        {"capabilities": {"credit.add.decide": "live"}},
                        {"capabilities": {"credit.add.decide": {"state": "bogus"}}}):
            p = self.tmp / "rt-bad.json"
            p.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaises(registry.RegistryInvalid, msg=str(payload)):
                registry.RuntimeState(p).load()
        # The shapes we actually write stay valid.
        good = self.tmp / "rt-good.json"
        good.write_text(json.dumps({"version": 1, "capabilities": {}}), encoding="utf-8")
        self.assertEqual(registry.RuntimeState(good).load().data["capabilities"], {})

    def test_a_corrupt_runtime_state_refuses_to_act(self):
        self.runtime_path.write_text('{"capabilities": []}', encoding="utf-8")
        self.fakes.action_ledger([{
            "at": utc(NOW - timedelta(hours=3)), "capability_id": "credit.add.decide",
            "reverted_at": utc(NOW - timedelta(hours=2)),
        }])
        self.assertEqual(self.run_tick("run", now=NOW), demote.EXIT_BAD_STATE)
        self.assertEqual(json.loads(self.runtime_path.read_text()), {"capabilities": []},
                         "the corrupt file must be left exactly as found")
        self.assertFalse((self.kill_root / "credit-trust-decide.disabled").exists())

    def test_a_stateless_runtime_entry_is_refused_not_read_as_repo_state(self):
        """QA r5: `{"capabilities": {"x": {}}}` validated (missing `state` was allowed),
        state_of() returned None, and effective_state() then reported the row at its repo
        state — silently discarding a host demotion. Every entry must record a state."""
        self.runtime_path.write_text('{"capabilities": {"credit.add.decide": {}}}', encoding="utf-8")
        self.fakes.action_ledger([{
            "at": utc(NOW - timedelta(hours=3)), "capability_id": "credit.add.decide",
            "reverted_at": utc(NOW - timedelta(hours=2)),
        }])
        self.assertEqual(self.run_tick("run", now=NOW), demote.EXIT_BAD_STATE)
        self.assertEqual(json.loads(self.runtime_path.read_text()),
                         {"capabilities": {"credit.add.decide": {}}},
                         "the unreadable file must be left exactly as found")
        self.assertFalse((self.kill_root / "credit-trust-decide.disabled").exists())
        # And the join must not paper over it either.
        with self.assertRaises(registry.RegistryInvalid):
            registry.RuntimeState(self.runtime_path).load()

    def test_set_mirror_pr_refuses_to_create_a_stateless_entry(self):
        rt = registry.RuntimeState(self.runtime_path)
        with self.assertRaises(registry.RegistryInvalid):
            rt.set_mirror_pr("credit.add.decide", "https://github.com/Muso-AI/hydra/pull/1")
        rt.set_state("credit.add.decide", "canary", reason="t", at=utc(NOW))
        rt.set_mirror_pr("credit.add.decide", "https://github.com/Muso-AI/hydra/pull/1")
        rt.save()
        reloaded = registry.RuntimeState(self.runtime_path).load()
        self.assertEqual(reloaded.entry("credit.add.decide")["mirror_pr"],
                         "https://github.com/Muso-AI/hydra/pull/1")

    def test_runtime_state_is_0600_and_atomic(self):
        rt = registry.RuntimeState(self.runtime_path)
        rt.set_state("credit.add.decide", "shadow", reason="t", at=utc(NOW), previous="canary")
        rt.save()
        self.assertEqual(self.runtime_path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads(self.runtime_path.read_text())["capabilities"]["credit.add.decide"]["state"], "shadow")
        self.assertEqual(list(self.tmp.glob(".registry-state.json.*")), [], "no temp files left behind")

    def test_effective_state_join(self):
        rt = registry.RuntimeState(self.runtime_path)
        live = {"id": "x", "rollout": {"state": "live"}}
        shadow = {"id": "y", "rollout": {"state": "shadow"}}
        rt.set_state("x", "canary", reason="t", at=utc(NOW))
        rt.set_state("y", "canary", reason="t", at=utc(NOW))
        self.assertEqual(registry.effective_state(live, rt), "canary")
        self.assertEqual(registry.effective_state(shadow, rt), "shadow")


# ── pages and content rules ──────────────────────────────────────────────────
class MalformedSources(Base):
    """A source we cannot read must never report as healthy-with-zero. QA r5 reproduced
    `([], None)` from a corrupted spot-audit row, i.e. `audit_fail_any` never fired."""

    def setUp(self):
        super().setUp()
        self.fakes = Fakes(self.tmp)
        self.paths = self.fakes.paths

    def _counters(self, path):
        c = outcomes.Counters(outcomes.utc(NOW - timedelta(days=7)), outcomes.utc(NOW))
        outcomes.spot_audit(c, str(path), {}, NOW - timedelta(days=7), NOW)
        return c

    def test_a_malformed_row_makes_the_source_unknown(self):
        bad = self.tmp / "spot-audit.jsonl"
        good = {"at": utc(NOW - timedelta(hours=2)), "capability_id": "credit.add.decide",
                "verdict": "fail"}
        bad.write_text(json.dumps(good) + "\n{not json at all\n", encoding="utf-8")
        c = self._counters(bad)
        src = [s for s in c.sources if s.name == "spot_audit"][0]
        self.assertEqual(src.status, "unknown",
                         "a corrupted failure row must not read as a healthy zero-count source")
        self.assertIn("malformed", src.detail)

    def test_a_torn_final_line_is_tolerated_and_nothing_else_is(self):
        torn = self.tmp / "torn.jsonl"
        row = json.dumps({"at": utc(NOW - timedelta(hours=2)), "capability_id": "credit.add.decide",
                          "verdict": "fail"})
        torn.write_text(row + "\n" + '{"at": "2026-11-04T0', encoding="utf-8")  # no trailing \n
        rows, err = outcomes._read_jsonl(str(torn))
        self.assertIsNone(err, "a partial final write was never durably committed")
        self.assertEqual(len(rows), 1)
        # A malformed line that is NOT the tail is corruption.
        mid = self.tmp / "mid.jsonl"
        mid.write_text("{oops\n" + row + "\n", encoding="utf-8")
        rows, err = outcomes._read_jsonl(str(mid))
        self.assertIsNotNone(err)
        self.assertEqual(rows, [])

    def test_a_non_object_line_is_malformed_too(self):
        p = self.tmp / "arr.jsonl"
        p.write_text('["not", "a", "row"]\n', encoding="utf-8")
        self.assertIsNotNone(outcomes._read_jsonl(str(p))[1])


class Concurrency(Base):
    """QA r5: the hourly --fast and nightly ticks share the runtime file and the mirror
    checkout, and both save the WHOLE document. Without a lock the second save erases the
    first tick's demotion, silently re-arming a host stop until its mirror PR merges."""

    def test_the_clobber_the_lock_exists_to_prevent(self):
        """Documented failure mode, reproduced directly: two loaded snapshots, two saves."""
        nightly = registry.RuntimeState(self.runtime_path).load()
        fast = registry.RuntimeState(self.runtime_path).load()
        nightly.set_state("credit.add.decide", "shadow", reason="slow trigger", at=utc(NOW))
        nightly.save()
        fast.set_state("support.answer", "shadow", reason="fast trigger", at=utc(NOW))
        fast.save()
        caps = registry.RuntimeState(self.runtime_path).load().data["capabilities"]
        self.assertEqual(sorted(caps), ["support.answer"],
                         "unserialized ticks really do drop the other tick's demotion")

    def test_the_host_lock_is_exclusive_and_released(self):
        first = demote.HostLock(self.tmp / "run.lock", timeout=0)
        with first:
            with self.assertRaises(demote.LockBusy):
                with demote.HostLock(self.tmp / "run.lock", timeout=0):
                    pass
        # Released: the next tick gets it.
        with demote.HostLock(self.tmp / "run.lock", timeout=0):
            pass

    def test_a_tick_that_cannot_get_the_lock_changes_nothing(self):
        """The lock is held for the whole tick, so a second tick must skip — not block
        forever and not save a stale snapshot over the running one."""
        self.fakes.action_ledger([{
            "at": utc(NOW - timedelta(hours=3)), "capability_id": "credit.add.decide",
            "reverted_at": utc(NOW - timedelta(hours=2)),
        }])
        with demote.HostLock(self.tmp / "run.lock", timeout=0), \
                mock.patch.object(demote, "LOCK_TIMEOUT_S", 0):
            rc = self.run_tick("run", now=NOW)
        self.assertEqual(rc, demote.EXIT_OK)
        self.assertFalse(self.runtime_path.exists(), "a skipped tick must write nothing")
        self.assertFalse((self.kill_root / "credit-trust-decide.disabled").exists())
        self.assertEqual(self.pages, [])

    def test_the_lock_is_held_across_load_save_and_the_mirror_pr(self):
        """Ordering matters: acquiring after the load would still let two ticks interleave."""
        seen = []
        real_load = registry.RuntimeState.load

        def spy_load(inner_self):
            # If the lock is held, taking it again must fail; that proves it is already ours.
            try:
                with demote.HostLock(self.tmp / "run.lock", timeout=0):
                    seen.append("NOT-LOCKED")
            except demote.LockBusy:
                seen.append("LOCKED")
            return real_load(inner_self)

        self.fakes.action_ledger([{
            "at": utc(NOW - timedelta(hours=3)), "capability_id": "credit.add.decide",
            "reverted_at": utc(NOW - timedelta(hours=2)),
        }])
        with mock.patch.object(registry.RuntimeState, "load", spy_load):
            self.run_tick("run", now=NOW)
        self.assertEqual(seen, ["LOCKED"], "the runtime file must be loaded under the lock")


    def test_an_unusable_lock_fails_loud_instead_of_skipping(self):
        """A skip on an unusable lock would switch the whole sentinel off while looking
        healthy — the exact "silent stop" this feature exists to prevent."""
        blocker = self.tmp / "not-a-dir"
        blocker.write_text("x", encoding="utf-8")
        with mock.patch.object(demote, "LOCK_FILE", blocker / "run.lock"):
            with self.assertRaises(demote.LockUnavailable):
                with demote.HostLock(timeout=0):
                    pass
            rc = self.run_tick("run", now=NOW)
        self.assertEqual(rc, demote.EXIT_ERROR)
        self.assertFalse(self.runtime_path.exists())


class ContentRules(Base):
    def test_no_account_ids_reach_the_page_or_the_pr_body(self):
        # Every source row carries an account-ish identifier. None may survive aggregation.
        self.fakes.action_ledger([{
            "at": utc(NOW - timedelta(hours=3)), "capability_id": "credit.add.decide",
            "action_type": "credit.approve", "risk_class": "high",
            "reverted_at": utc(NOW - timedelta(hours=2)), "actor_id": "agent-7",
            "reverted_by": "action-audit",
        }])
        self.fakes.jsonl(self.fakes.complaints, [
            {"at": utc(NOW - timedelta(hours=5)), "conv_id": "2154742388",
             "user_id": 987654, "intercom_tag": "ai:support-answer", "reason": "wrong answer"},
            {"at": utc(NOW - timedelta(hours=5)), "conv_id": "2154742389",
             "user_id": 987654, "intercom_tag": "ai:support-answer", "reason": "wrong answer"},
        ] * 6)
        self.run_tick("run", now=NOW)
        text = "\n".join(t for t, _ in self.pages)
        self.assertIn("credit.add.decide", text)
        for bad in ("2154742388", "987654", "agent-7"):
            self.assertNotIn(bad, text)

    def test_page_says_counts_and_the_three_stops(self):
        text = report.demotion_page([demote.Trip(
            capability_id="credit.add.decide", prev_state="canary", next_state="shadow",
            reasons=["audit_fail_any"], reason_text=["audit_fail_any (manipulated=1, spot_fails=0)"],
            counts={"manipulated_7d": 1}, kill_file="/etc/hydra/credit-trust-decide.disabled",
        )], utc(NOW))
        self.assertIn("canary → *shadow*", text)
        self.assertIn("manipulated=1", text)
        self.assertIn("three independent stops", text.lower())
        self.assertIn("Nothing was promoted", text)


# ── the mirror PR machinery (fake runner) ────────────────────────────────────
class FakeRunner:
    """Records commands, answers `git status --porcelain` with a fake diff and
    `gh pr create` with a URL. Nothing is executed."""

    def __init__(self, status=""):
        self.calls = []
        self.cwds = []          # parallel to `calls`: a cwd=None inherited `/` on node-8
        self.status = status

    def __call__(self, cmd, cwd=None, capture_output=True, text=True):
        self.calls.append(list(cmd))
        self.cwds.append(cwd)
        out, rc = "", 0
        if "status" in cmd and "--porcelain" in cmd:
            out = self.status
        if cmd[:3] == ["gh", "pr", "create"]:
            out = "https://github.com/Muso-AI/hydra/pull/9999"
        return mock.Mock(returncode=rc, stdout=out, stderr="")


class MirrorPR(Base):
    def _repo(self):
        repo = self.tmp / "mirror-repo"
        (repo / ".git").mkdir(parents=True)
        (repo / "policies").mkdir()
        (repo / mirror.REGISTRY_REL).write_text(self.registry_path.read_text(), encoding="utf-8")
        return repo

    def test_command_sequence_and_pr_url(self):
        repo = self._repo()
        doc = mirror.apply_demotions(self.registry_doc(), [demote.Trip(
            capability_id="credit.add.decide", prev_state="canary", next_state="shadow",
            reason_text=["audit_fail_any"], counts={"manipulated_7d": 1},
            kill_file="/etc/hydra/credit-trust-decide.disabled")], utc(NOW))
        (repo / mirror.REGISTRY_REL).write_text(json.dumps(doc), encoding="utf-8")
        runner = FakeRunner(status=" M policies/sentinel-capabilities.json")
        with mock.patch("sentinel.mirror.shutil.which", return_value="/usr/bin/gh"), \
                mock.patch("sentinel.mirror.remote_slug", return_value="Muso-AI/hydra"):
            url = mirror.open_pr(
                title="fix(sentinel): demote credit.add.decide", body="body",
                branch="sentinel/demote-1", paths=[mirror.REGISTRY_REL],
                repo_dir=str(repo), runner=runner,
            )
        self.assertEqual(url, "https://github.com/Muso-AI/hydra/pull/9999")
        flat = [" ".join(c) for c in runner.calls]
        self.assertTrue(any(c.startswith("git -C") and "fetch" in c for c in flat))
        self.assertTrue(any("checkout" in c and "-B sentinel/demote-1 origin/main" in c for c in flat))
        self.assertTrue(any("commit" in c and "sentinel-demote" not in c for c in flat))
        self.assertTrue(any("push" in c and "sentinel/demote-1" in c for c in flat))
        pr = [c for c in runner.calls if c[:3] == ["gh", "pr", "create"]][0]
        self.assertIn("--body-file", pr)
        self.assertIn("--head", pr)

    def test_gh_pr_create_runs_inside_the_checkout_with_an_explicit_repo(self):
        """The timer runs with cwd=/ (no WorkingDirectory in the unit), so a `gh pr
        create` that relies on cwd inference answers "not a git repository" and the
        mirror PR never opens. Assert the real invocation context, not just the argv."""
        repo = self._repo()
        doc = mirror.apply_demotions(self.registry_doc(), [demote.Trip(
            capability_id="credit.add.decide", prev_state="canary", next_state="shadow",
            reason_text=["audit_fail_any"], kill_file="/etc/hydra/credit-trust-decide.disabled")], utc(NOW))
        (repo / mirror.REGISTRY_REL).write_text(json.dumps(doc), encoding="utf-8")
        runner = FakeRunner(status=" M policies/sentinel-capabilities.json")
        with mock.patch("sentinel.mirror.shutil.which", return_value="/usr/bin/gh"), \
                mock.patch("sentinel.mirror.remote_slug", return_value="Muso-AI/hydra"):
            mirror.open_pr(title="t", body="b", branch="sentinel/demote-1",
                           paths=[mirror.REGISTRY_REL], repo_dir=str(repo), runner=runner)
        idx = [i for i, c in enumerate(runner.calls) if c[:3] == ["gh", "pr", "create"]][0]
        self.assertEqual(runner.cwds[idx], str(repo),
                         "gh must run inside the checkout, not in the service's cwd=/")
        self.assertIn("--repo", runner.calls[idx])
        self.assertIn("Muso-AI/hydra", runner.calls[idx])

    def test_remote_slug_parses_the_shapes_we_clone(self):
        import subprocess as sp
        for url in ("git@github.com:Muso-AI/hydra.git", "https://github.com/Muso-AI/hydra.git",
                    "https://github.com/Muso-AI/hydra"):
            done = mock.Mock(returncode=0, stdout=url + "\n", stderr="")
            with mock.patch.object(mirror.subprocess, "run", return_value=done):
                self.assertEqual(mirror.remote_slug(self.tmp), "Muso-AI/hydra", url)

    def test_missing_checkout_refuses_loudly(self):
        with self.assertRaises(mirror.MirrorUnavailable) as ctx:
            mirror.open_pr(title="t", body="b", branch="x", paths=[mirror.REGISTRY_REL],
                           repo_dir=str(self.tmp / "nope"), runner=FakeRunner())
        self.assertIn("not a git checkout", str(ctx.exception))

    def test_nothing_to_commit_is_reported_not_swallowed(self):
        repo = self._repo()
        with mock.patch("sentinel.mirror.shutil.which", return_value="/usr/bin/gh"):
            with self.assertRaises(mirror.MirrorUnavailable) as ctx:
                mirror.open_pr(title="t", body="b", branch="x", paths=[mirror.REGISTRY_REL],
                               repo_dir=str(repo), runner=FakeRunner(status=""))
        self.assertIn("nothing to commit", str(ctx.exception))

    def test_dry_run_touches_nothing(self):
        runner = FakeRunner()
        url = mirror.open_pr(title="t", body="b", branch="x", paths=[mirror.REGISTRY_REL],
                             repo_dir=str(self.tmp), runner=runner, dry_run=True, log=lambda *_: None)
        self.assertTrue(url.startswith("DRY-RUN"))
        self.assertEqual(runner.calls, [])


class TwoDemotionsAgainstRealGit(Base):
    """QA r5: with a REAL origin, the second demotion could not open its mirror PR.

    `_open_mirror_pr` wrote the registry before `open_pr()` switched branches, so with
    the previous demotion's branch still checked out and `origin/main` still carrying
    the old blob, git refused the switch ("Your local changes would be overwritten") and
    the mirror half of the feature died on its second use. The fake git runner used by
    every other test never models a persistent branch, which is why it passed CI.

    This drives the real git binary: only `gh` is stubbed.
    """

    def _origin_and_clone(self):
        import subprocess
        origin = self.tmp / "origin.git"
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(origin)], check=True)
        seed = self.tmp / "seed"
        subprocess.run(["git", "clone", "-q", str(origin), str(seed)], check=True)
        (seed / mirror.REGISTRY_REL).parent.mkdir(parents=True)
        (seed / mirror.REGISTRY_REL).write_text(self.registry_path.read_text(), encoding="utf-8")
        for cmd in (["add", "-A"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "registry"],
                    ["push", "-q", "origin", "HEAD:main"]):
            subprocess.run(["git", "-C", str(seed), *cmd], check=True)
        checkout = self.tmp / "mirror-repo"
        subprocess.run(["git", "clone", "-q", str(origin), str(checkout)], check=True)
        return origin, checkout

    @staticmethod
    def _hybrid_runner(seen):
        import subprocess
        def runner(cmd, cwd=None, capture_output=True, text=True):
            if cmd and cmd[0] == "gh":
                seen.append(list(cmd))
                return mock.Mock(returncode=0, stdout="https://github.com/Muso-AI/hydra/pull/9999\n",
                                 stderr="")
            return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
        return runner

    def test_a_second_demotion_still_opens_its_pr(self):
        import subprocess
        origin, checkout = self._origin_and_clone()
        seen = []
        runner = self._hybrid_runner(seen)
        trips = [demote.Trip(capability_id="credit.add.decide", prev_state="live", next_state="canary",
                             reason_text=["reverts_7d"], counts={"reverts_7d": 6},
                             kill_file="/etc/hydra/credit-trust-decide.disabled")]

        def prepare_for(state):
            def prepare(repo):
                raw = json.loads((repo / mirror.REGISTRY_REL).read_text(encoding="utf-8"))
                doc = mirror.apply_demotions(raw, [demote.Trip(
                    capability_id="credit.add.decide", prev_state="live", next_state=state,
                    reason_text=trips[0].reason_text, counts=trips[0].counts,
                    kill_file=trips[0].kill_file)], utc(NOW))
                (repo / mirror.REGISTRY_REL).write_text(json.dumps(doc), encoding="utf-8")
            return prepare

        with mock.patch("sentinel.mirror.shutil.which", return_value="/usr/bin/gh"), \
                mock.patch("sentinel.mirror.remote_slug", return_value="Muso-AI/hydra"):
            first = mirror.open_pr(title="demote 1", body="b", branch="sentinel/demote-canary",
                                   paths=[mirror.REGISTRY_REL], repo_dir=str(checkout),
                                   runner=runner, prepare=prepare_for("canary"), log=lambda *_: None)
            # The first PR is still UNMERGED: origin/main still says live, the checkout
            # sits on sentinel/demote-canary. The second demotion must still work.
            second = mirror.open_pr(title="demote 2", body="b", branch="sentinel/demote-shadow",
                                    paths=[mirror.REGISTRY_REL], repo_dir=str(checkout),
                                    runner=runner, prepare=prepare_for("shadow"), log=lambda *_: None)
        self.assertEqual(first, "https://github.com/Muso-AI/hydra/pull/9999")
        self.assertEqual(second, first, "the second demotion must open a PR too")
        self.assertEqual(len(seen), 2)
        branches = subprocess.run(["git", "-C", str(origin), "branch", "--list"],
                                  capture_output=True, text=True).stdout
        self.assertIn("sentinel/demote-canary", branches)
        self.assertIn("sentinel/demote-shadow", branches)
        # Each branch carries ITS OWN state — the second did not silently reuse the first.
        shown = subprocess.run(["git", "-C", str(origin), "show",
                                "sentinel/demote-shadow:policies/sentinel-capabilities.json"],
                               capture_output=True, text=True).stdout
        self.assertIn('"shadow"', shown)

    def test_a_dirty_checkout_left_by_a_killed_run_self_heals(self):
        import subprocess
        origin, checkout = self._origin_and_clone()
        (checkout / mirror.REGISTRY_REL).write_text('{"capabilities": "half written"', encoding="utf-8")
        runner = self._hybrid_runner([])
        with mock.patch("sentinel.mirror.shutil.which", return_value="/usr/bin/gh"), \
                mock.patch("sentinel.mirror.remote_slug", return_value="Muso-AI/hydra"):
            url = mirror.open_pr(title="t", body="b", branch="sentinel/demote-x",
                                 paths=[mirror.REGISTRY_REL], repo_dir=str(checkout), runner=runner,
                                 prepare=lambda repo: (repo / mirror.REGISTRY_REL).write_text(
                                     json.dumps({"capabilities": []}), encoding="utf-8"),
                                 log=lambda *_: None)
        self.assertTrue(url.startswith("https://github.com/"))
        self.assertNotIn("half written",
                         subprocess.run(["git", "-C", str(origin), "show",
                                         "sentinel/demote-x:policies/sentinel-capabilities.json"],
                                        capture_output=True, text=True).stdout)


# ── promotion is never automatic ─────────────────────────────────────────────
class Promotion(Base):
    def _row(self, **over):
        row = json.loads(json.dumps(registry.index_by_id(registry.load(self.registry_path))["credit.add.decide"]))
        row["rollout"].update(over)
        return row

    def test_all_gates_measured_and_passing_renders_pass_but_flips_nothing(self):
        self.registry_path.write_text(json.dumps({"capabilities": [self._row(since=utc(NOW - timedelta(days=9)))]}),
                                      encoding="utf-8")
        rows = [{"at": utc(NOW - timedelta(hours=i % 100)), "capability_id": "credit.add.decide",
                 "band": "GREEN", "decision": "act", "agreed": 1} for i in range(300)]
        self.fakes.action_ledger([])
        self.fakes.audit_verdicts([])
        self.fakes.jsonl(self.fakes.contra, [])
        self.fakes.jsonl(self.fakes.complaints, [])
        self.fakes.jsonl(self.fakes.spot, [])
        self.fakes.jsonl(self.tmp / "cap-trips.jsonl", [])
        self.fakes.evaluations(rows + [{
            "at": utc(NOW - timedelta(hours=1)), "capability_id": "credit.add.decide",
            "waiting_on": "us", "due_at": utc(NOW + timedelta(hours=4)), "decision": "decide_within_24h",
        }])
        before = self.runtime_path.read_bytes() if self.runtime_path.exists() else None
        rc = self.run_cli("promote", "--capability", "credit.add.decide", "--ruling", "ruling-2026-11", now=NOW)
        self.assertEqual(rc, demote.EXIT_OK)
        self.assertEqual(self.runtime_path.read_bytes() if self.runtime_path.exists() else None, before,
                         "promote must never write the runtime state")
        self.assertEqual(json.loads(self.registry_path.read_text())["capabilities"][0]["rollout"]["state"],
                         "canary", "promote must never flip the repo row either")
        row = self._row(since=utc(NOW - timedelta(days=9)))
        c = outcomes.collect(paths=self.fakes.paths, attribution={}, now=NOW)
        outcomes.blind_counters([row], c)
        gates = demote._parity_gates(row, c, row["rollout"], "ruling-2026-11", NOW, str(self.fakes.evals))
        self.assertTrue(gates["evidence_window"]["pass"])
        self.assertTrue(gates["evaluations"]["pass"])
        self.assertTrue(gates["agreement"]["pass"])
        self.assertTrue(gates["false_act"]["pass"])
        self.assertTrue(gates["ruling"]["pass"])
        text = report.parity_report(capability_id="credit.add.decide", ruling="ruling-2026-11",
                                    rollout=row["rollout"], gates=gates, at=utc(NOW))
        self.assertIn("ALL GATES PASS", text)
        self.assertIn("does not flip it", text)

    def test_too_few_evaluations_and_no_ruling_blocks(self):
        row = self._row(since=utc(NOW - timedelta(days=9)), approval_ref=None)
        c = outcomes.collect(paths=self.fakes.paths, now=NOW)
        gates = demote._parity_gates(row, c, row["rollout"], None, NOW, str(self.fakes.evals))
        self.assertFalse(gates["evaluations"]["pass"])
        self.assertFalse(gates["ruling"]["pass"])
        text = report.parity_report(capability_id="credit.add.decide", ruling=None,
                                    rollout=row["rollout"], gates=gates, at=utc(NOW))
        self.assertIn("PROMOTION BLOCKED", text)

    def test_one_paired_row_does_not_satisfy_agreement(self):
        """QA r5: 200 evaluations with a single `agreed=1` and 199 NULLs reported
        "100.00% agreement" and promoted. A percentage over one row is not evidence."""
        row = self._row(since=utc(NOW - timedelta(days=9)))
        self.fakes.evaluations([
            {"at": utc(NOW - timedelta(minutes=i)), "capability_id": "credit.add.decide",
             "band": "GREEN", "decision": "act", "agreed": 1 if i == 0 else None}
            for i in range(200)
        ])
        c = outcomes.collect(paths=self.fakes.paths, attribution={}, now=NOW)
        gates = demote._parity_gates(row, c, row["rollout"], "ruling-2026-11", NOW, str(self.fakes.evals))
        self.assertTrue(gates["evaluations"]["pass"], "200 rows is enough volume")
        self.assertFalse(gates["agreement"]["pass"], "1 paired row is not 99% agreement")
        self.assertIn("TOO FEW PAIRED ROWS", gates["agreement"]["measured"])
        self.assertIn("TOO SPARSE", gates["agreement"]["measured"])

    def test_a_store_without_the_comparison_columns_is_unmeasured_not_clean(self):
        """A missing `agreed`/`band`/`decision` column rendered as "0 false acts" and
        "no paired rows" — an absent measurement passing as a clean one."""
        import sqlite3
        db = self.tmp / "no-columns.sqlite"
        conn = sqlite3.connect(db)
        conn.execute("CREATE TABLE sentinel_evaluations (capability_id TEXT, at TEXT)")
        for i in range(200):
            conn.execute("INSERT INTO sentinel_evaluations VALUES (?,?)",
                         ("credit.add.decide", utc(NOW - timedelta(minutes=i))))
        conn.commit()
        conn.close()
        row = self._row(since=utc(NOW - timedelta(days=9)))
        c = outcomes.collect(paths=self.fakes.paths, attribution={}, now=NOW)
        gates = demote._parity_gates(row, c, row["rollout"], "ruling-2026-11", NOW, str(db))
        self.assertTrue(gates["evaluations"]["pass"])
        self.assertFalse(gates["agreement"]["pass"])
        self.assertIn("UNMEASURED", gates["agreement"]["measured"])
        self.assertIn("agreed", gates["agreement"]["measured"])
        self.assertFalse(gates["false_act"]["pass"],
                         "0 false acts of 0 rows means nothing when band/decision are absent")
        self.assertIn("UNMEASURED", gates["false_act"]["measured"])

    def test_a_recently_promoted_row_fails_the_window_gate(self):
        row = self._row(since=utc(NOW - timedelta(days=2)))
        c = outcomes.collect(paths=self.fakes.paths, now=NOW)
        gates = demote._parity_gates(row, c, row["rollout"], "ruling-2026-11", NOW, None)
        self.assertFalse(gates["evidence_window"]["pass"])


# ── the weekly proposal ─────────────────────────────────────────────────────
class ProposalPRAgainstRealGit(Base):
    """QA r5: `_open_proposal_pr` wrote the registry BEFORE `open_pr()`, which resets the
    checkout — the tracked registry edit was discarded while the untracked proposal
    markdown survived, so the PR could carry only the .md while its body claimed it had
    registered the shadow row. Driven against the real git binary."""

    def test_both_the_shadow_row_and_the_proposal_land_in_the_branch(self):
        import subprocess
        origin = self.tmp / "origin.git"
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(origin)], check=True)
        seed = self.tmp / "seed"
        subprocess.run(["git", "clone", "-q", str(origin), str(seed)], check=True, capture_output=True)
        (seed / mirror.REGISTRY_REL).parent.mkdir(parents=True)
        (seed / mirror.REGISTRY_REL).write_text(self.registry_path.read_text(), encoding="utf-8")
        for cmd in (["add", "-A"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "r"],
                    ["push", "-q", "origin", "HEAD:main"]):
            subprocess.run(["git", "-C", str(seed), *cmd], check=True)
        checkout = self.tmp / "mirror-repo"
        subprocess.run(["git", "clone", "-q", str(origin), str(checkout)], check=True, capture_output=True)

        out = self.tmp / "proposals"
        out.mkdir()
        rel = "2026-W45-support-status.md"
        (out / rel).write_text("# proposal body\n", encoding="utf-8")
        proposed = demote._proposed_row(
            {"class": "support", "sub_class": "status", "requested_action": "support.status_reply",
             "count_30d": 3, "name": "support / status"}, "support-status", "2026-W45", at=utc(NOW))

        class A:
            mirror_repo = str(checkout)
            base = "main"
            out_dir = str(out)
            open_pr = True

        with mock.patch("sentinel.mirror.shutil.which", return_value="/usr/bin/gh"), \
                mock.patch("sentinel.mirror.remote_slug", return_value="Muso-AI/hydra"), \
                mock.patch.object(demote, "_slack", return_value=True):
            demote._open_proposal_pr(A(), at=utc(NOW), rel_path=rel, proposed=proposed)

        branch = "sentinel/propose-2026-W45-support-status"
        files = subprocess.run(["git", "-C", str(origin), "ls-tree", "-r", "--name-only", branch],
                               capture_output=True, text=True).stdout.split()
        self.assertIn(mirror.REGISTRY_REL, files, "the shadow row must be committed, not reset away")
        self.assertIn(f"data/sentinel/proposals/{rel}", files, "the proposal markdown must be committed")
        shown = subprocess.run(["git", "-C", str(origin), "show", f"{branch}:{mirror.REGISTRY_REL}"],
                               capture_output=True, text=True).stdout
        self.assertIn(proposed["id"], shown, "the PR body claims a registry row; it must be there")
        self.assertIn('"shadow"', shown)


class Proposals(Base):
    def test_money_legal_classes_are_forced_to_handoff_by_code(self):
        out = self.tmp / "proposals"
        self.fakes.evaluations([
            {"at": utc(NOW - timedelta(days=2)), "class": "refund", "sub_class": "chargeback",
             "decision": "unhandled", "requested_action": "refund.issue"},
            {"at": utc(NOW - timedelta(days=2)), "class": "support", "sub_class": "status",
             "decision": "handoff", "requested_action": "support.status_reply"},
        ])
        rc = self.run_cli("propose", "--out-dir", str(out), "--week", "2026-W45", now=NOW)
        self.assertEqual(rc, demote.EXIT_OK)
        files = sorted(p.name for p in out.glob("*.md"))
        self.assertEqual(len(files), 2)
        refund = json.loads((self.tmp / "proposals" / [f for f in files if "refund" in f][0])
                            .read_text().split("```json\n")[1].split("\n```")[0])
        self.assertEqual(refund["action"]["type"], "handoff")
        self.assertEqual(refund["rollout"]["state"], "shadow")
        support = json.loads((self.tmp / "proposals" / [f for f in files if "support" in f][0])
                             .read_text().split("```json\n")[1].split("\n```")[0])
        self.assertEqual(support["action"]["type"], "message_line")
        self.assertTrue((self.tmp / "proposals" / files[0]).read_text().count("_generated") == 1)

    def test_caller_text_is_never_published_in_a_proposal(self):
        """QA r8: `_unhandled_clusters` grouped on UNVALIDATED class / sub_class /
        requested_action and `_proposed_row` copied them into a committed file and the PR
        body, so a row whose requested_action was "approve user@example.test account
        12345" published real identifiers. Only bare code tokens may leave the process.

        QA r9: a code-SHAPED identifier still passed — `user_12345` and a bare UUID both
        satisfy the token regex, so shape alone is not the boundary; identifier shapes
        (3+ digit runs, UUIDs, long hex) are rejected too.

        The `credit` row guards the fix from over-correcting: the forced-handoff fence must
        still read the RAW sub_class, or a prose `refund request …` would redact to
        `unknown`, the fence would miss `credit`, and a refund would propose an ACTOR type.
        """
        out = self.tmp / "proposals"
        uuid = "a1234567-1234-1234-1234-123456789abc"
        self.fakes.evaluations([
            {"at": utc(NOW - timedelta(days=1)), "class": "support",
             "sub_class": "user@example.test", "decision": "unhandled",
             "requested_action": "approve user@example.test account 12345"},
            {"at": utc(NOW - timedelta(days=1)), "class": "support",
             "sub_class": "user_12345", "decision": "unhandled",
             "requested_action": uuid},
            {"at": utc(NOW - timedelta(days=1)), "class": "credit",
             "sub_class": "refund request for user@example.test", "decision": "unhandled",
             "requested_action": "refund"},
        ])
        rc = self.run_cli("propose", "--out-dir", str(out), "--week", "2026-W45", now=NOW)
        self.assertEqual(rc, demote.EXIT_OK)
        files = sorted(out.glob("*.md"))
        self.assertTrue(files, "a proposal is still written; the fields are what is dropped")
        for p in files:
            self.assertNotIn("@", p.name, "an identifier must not reach the committed filename")
        blob = "\n".join(p.read_text(encoding="utf-8") for p in files)
        for leak in ("user@", "example.test", "12345", "refund request", "user_12345", uuid):
            self.assertNotIn(leak, blob, f"{leak!r} leaked into the proposal")
        rows = [json.loads(p.read_text(encoding="utf-8").split("```json\n")[1].split("\n```")[0])
                for p in files]
        support = [r for r in rows if r["class"] == "support"][0]
        self.assertEqual(support["sub_class"], "unknown")
        self.assertIsNone(support["action"]["requested"])
        self.assertIn("not published", blob, "the proposal must say a field was withheld")
        # Two support rows collapse onto one `support / unknown` view; the merge must sum
        # the volume rather than let the later write overwrite the earlier file.
        self.assertEqual(len([r for r in rows if r["class"] == "support"]), 1)
        self.assertIn("**2 requests / 30 d**", blob, "the merged view must sum the volume")
        credit = [r for r in rows if r["class"] == "credit"][0]
        self.assertEqual(credit["action"]["type"], "handoff",
                         "the money fence must read the raw sub_class, not the redacted view")
        self.assertEqual(credit["reversibility"], "irreversible")

    def test_short_alphabetic_identifiers_are_not_codes(self):
        """QA r10: shape cannot separate an identifier from a code — `user_12` and
        `acct_ab` are short and alphabetic, so every shape rule let them through. The
        boundary is membership in a vocabulary this repo owns, so a value the registry
        never declares is dropped however code-like it looks."""
        out = self.tmp / "proposals"
        self.fakes.evaluations([
            {"at": utc(NOW - timedelta(days=1)), "class": "support",
             "sub_class": "user_12", "decision": "unhandled",
             "requested_action": "acct_ab"},
        ])
        rc = self.run_cli("propose", "--out-dir", str(out), "--week", "2026-W45", now=NOW)
        self.assertEqual(rc, demote.EXIT_OK)
        files = sorted(out.glob("*.md"))
        self.assertEqual(len(files), 1)
        blob = files[0].read_text(encoding="utf-8")
        for leak in ("user_12", "acct_ab"):
            self.assertNotIn(leak, blob, f"{leak!r} leaked into the proposal")
            self.assertNotIn(leak, files[0].name, f"{leak!r} leaked into the filename")
        self.assertIn("unknown", files[0].name)

    def test_a_money_requested_action_forces_handoff_even_with_a_plain_sub_class(self):
        """QA r10: the fence read only class/sub_class, so `class=credit, sub_class=normal,
        requested_action=refund` proposed `hydra_executor` — an ACTOR type for a refund.
        The requested action is part of what the cluster asks for, so it is fenced too."""
        self.assertTrue(demote._is_forced_class("credit", "normal", "refund"))
        self.assertTrue(demote._is_forced_class("support", "status", "chargeback"))
        self.assertFalse(demote._is_forced_class("support", "status", "support.status_reply"))
        row = demote._proposed_row(
            {"class": "credit", "sub_class": "normal", "requested_action": "refund",
             "count_30d": 3, "name": "credit / normal"},
            "credit-normal-refund", "2026-W45", at=utc(NOW))
        self.assertEqual(row["action"]["type"], "handoff")
        self.assertEqual(row["reversibility"], "irreversible")

    def test_no_unhandled_rows_means_no_proposals(self):
        rc = self.run_cli("propose", "--out-dir", str(self.tmp / "p2"), now=NOW)
        self.assertEqual(rc, demote.EXIT_OK)
        self.assertEqual(list((self.tmp / "p2").glob("*.md")) if (self.tmp / "p2").exists() else [], [])

    def test_new_row_is_added_in_shadow_and_duplicate_ids_refused(self):
        doc = self.registry_doc()
        row = demote._proposed_row({"class": "legal", "sub_class": "dmca",
                                    "requested_action": "takedown", "count_30d": 4},
                                   "legal-dmca", "2026-W45", utc(NOW))
        self.assertEqual(row["rollout"]["since"], utc(NOW))
        self.assertEqual(row["reversibility"], "irreversible")
        doc2 = mirror.add_shadow_row(doc, row)
        self.assertEqual(doc2["capabilities"][-1]["rollout"]["state"], "shadow")
        self.assertEqual(row["action"]["type"], "handoff")
        with self.assertRaises(mirror.MirrorUnavailable):
            mirror.add_shadow_row(doc2, row)


# ── the tick's own kill switch ──────────────────────────────────────────────
class KillSwitch(Base):
    def test_demote_kill_file_stops_the_tick_and_says_so(self):
        (self.tmp / "sentinel-demote.disabled").write_text("", encoding="utf-8")
        self.fakes.action_ledger([{
            "at": utc(NOW - timedelta(hours=3)), "capability_id": "credit.add.decide",
            "reverted_at": utc(NOW - timedelta(hours=2)),
        }])
        self.assertEqual(self.run_tick("run", now=NOW), demote.EXIT_KILLED)
        self.assertFalse(self.runtime_path.exists())
        self.assertFalse((self.kill_root / "credit-trust-decide.disabled").exists())

    def test_global_sentinel_kill_file_stops_the_tick_too(self):
        """`/etc/hydra/sentinel.disabled` is documented as "stop the whole sentinel".
        Ignoring it meant a global stop still demoted live capabilities."""
        (self.tmp / "sentinel.disabled").write_text("", encoding="utf-8")
        self.fakes.action_ledger([{
            "at": utc(NOW - timedelta(hours=3)), "capability_id": "credit.add.decide",
            "reverted_at": utc(NOW - timedelta(hours=2)),
        }])
        self.assertEqual(self.run_tick("run", now=NOW), demote.EXIT_KILLED)
        self.assertFalse(self.runtime_path.exists(), "a global stop must not write runtime state")
        self.assertFalse((self.kill_root / "credit-trust-decide.disabled").exists())

    def test_propose_also_respects_the_global_stop(self):
        (self.tmp / "sentinel.disabled").write_text("", encoding="utf-8")
        rc = demote.main(["propose", "--registry", str(self.registry_path),
                          "--paths-json", json.dumps(self.fakes.paths),
                          "--out-dir", str(self.tmp / "proposals")])
        self.assertEqual(rc, demote.EXIT_KILLED)

    def test_digest_lists_every_registered_capability(self):
        rows = registry.load(self.registry_path)
        c = outcomes.collect(paths=self.fakes.paths, now=NOW)
        text = report.digest(rows, c, {"credit.remove.self": "live"}, utc(NOW))
        for cap in ("credit.remove.self", "credit.add.decide", "support.answer", "profile.edit.self"):
            self.assertIn(cap, text)


class RegistryGate(Base):
    """scripts/check-sentinel-registry.py — the CI half of the same contract."""

    @staticmethod
    def gate():
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "check_sentinel_registry", REPO / "scripts" / "check-sentinel-registry.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def test_the_seeded_kill_file_is_a_switched_actor_the_fleet_already_reads(self):
        """The dispatch's DoD, mechanically: the file a demotion drops must be one that
        existing code already honours (`grep -r '.disabled' scripts/`)."""
        kill = json.loads(self.registry_path.read_text())["capabilities"][1]["kill_file"]
        self.assertEqual(kill, "/etc/hydra/credit-trust-decide.disabled")
        hits = [p for p in (REPO / "scripts").rglob("*")
                if p.is_file() and p.suffix in (".sh", ".py") and kill in p.read_text(
                    encoding="utf-8", errors="replace")]
        self.assertTrue(hits, f"{kill} is honoured nowhere under scripts/ — a stop nothing reads")

    def test_gate_flags_a_kill_file_nobody_honours(self):
        gate = self.gate()
        rows = json.loads(self.registry_path.read_text())["capabilities"]
        bad, _ = gate.check(rows, honoured="", prev={})
        self.assertTrue(any("not honoured" in b for b in bad))
        honoured = "\n".join(r["kill_file"] for r in rows)
        bad, _ = gate.check(rows, honoured=honoured, prev={})
        self.assertFalse([b for b in bad if "not honoured" in b])

    def test_gate_blocks_a_promotion_without_a_ruling_and_allows_a_demotion(self):
        gate = self.gate()
        rows = json.loads(self.registry_path.read_text())["capabilities"]
        honoured = "\n".join(r["kill_file"] for r in rows)
        by_id = {r["id"]: r for r in rows}
        # canary → live with no approval_ref: refused.
        up = json.loads(json.dumps(by_id["credit.add.decide"]))
        up["rollout"]["state"] = "live"
        up["rollout"]["approval_ref"] = None
        bad, _ = gate.check([up], honoured, {"credit.add.decide": "canary"})
        self.assertTrue(any("PROMOTION" in b and "approval_ref" in b for b in bad))
        # live → canary (the demote direction) never needs a ruling.
        down = json.loads(json.dumps(by_id["credit.remove.self"]))
        down["rollout"]["state"] = "canary"
        down["rollout"]["approval_ref"] = None
        bad, _ = gate.check([down], honoured, {"credit.remove.self": "live"})
        self.assertEqual(bad, [])

    def test_a_kill_file_is_matched_exactly_never_as_a_substring(self):
        """QA r11: `kill_file not in honoured` was SUBSTRING membership, so a live row
        naming `/etc/hydra/sentinel-foo.disabled` passed when the only honoured path was
        `/etc/hydra/sentinel-foo.disabled.disabled` — and the demoter then wrote a file
        the actor never checks."""
        gate = self.gate()
        rows = json.loads(self.registry_path.read_text())["capabilities"]
        row = json.loads(json.dumps(rows[1]))
        row["kill_file"] = "/etc/hydra/sentinel-foo.disabled"
        row["rollout"]["state"] = "live"
        bad, _ = gate.check([row], "/etc/hydra/sentinel-foo.disabled.disabled", {})
        self.assertTrue(any("not honoured" in b for b in bad),
                        f"a longer path must not vouch for a shorter one, got {bad}")
        bad, _ = gate.check([row], "/etc/hydra/sentinel-foo.disabled", {})
        self.assertFalse([b for b in bad if "not honoured" in b])

    def test_a_demotion_trigger_the_demoter_cannot_act_on_is_refused(self):
        """QA r11: the gate only checked that `demotion` was non-empty, so
        `reverts_7d: "five"` and `audit_fail_any: "true"` passed while `_rule_hits()`
        ignored both — a row could ship with 99 reverts and a manipulated verdict and
        never demote."""
        gate = self.gate()
        rows = json.loads(self.registry_path.read_text())["capabilities"]
        honoured = "\n".join(r["kill_file"] for r in rows)
        base = json.loads(json.dumps(rows[1]))
        for demotion, needle in (
            ({"reverts_7d": "five", "audit_fail_any": True}, "must be a number"),
            ({"reverts_7d": True, "audit_fail_any": True}, "must be a number"),
            ({"reverts_7d": 0, "audit_fail_any": True}, "must be > 0"),
            ({"reverts_7d": 3, "audit_fail_any": "true"}, "must be the boolean true"),
            ({"reverts_7d": 3, "audit_fail_any": True, "revert_7d": 3}, "not a trigger"),
            ({"reverts_7d": 3, "audit_fail_any": True, "on_trip": "gone"}, "on_trip"),
            # QA r12: json.loads accepts the bare tokens NaN/Infinity, and every comparison
            # against NaN is False, so `reverts_7d: NaN` passed the `<= 0` check and then
            # ignored even 99 reverts.
            ({"reverts_7d": float("nan"), "audit_fail_any": True}, "must be a finite number"),
            ({"reverts_7d": float("inf"), "audit_fail_any": True}, "must be a finite number"),
            ({"reverts_7d": 3, "overdue_pct": float("-inf"), "audit_fail_any": True},
             "must be a finite number"),
        ):
            row = json.loads(json.dumps(base))
            row["demotion"] = demotion
            bad, _ = gate.check([row], honoured, {})
            self.assertTrue(any(needle in b for b in bad),
                            f"{demotion!r} must be refused with {needle!r}, got {bad}")
        # The fixture's own blocks are valid, so a clean registry stays clean.
        bad, _ = gate.check(rows, honoured, {})
        self.assertEqual([b for b in bad if "demotion." in b], [])

    def test_a_non_finite_threshold_cannot_fire_at_runtime_either(self):
        """QA r12, runtime half: the host reads the file the gate does not own, so `_num`
        must refuse NaN/Infinity itself rather than trusting CI to have caught it."""
        for bad in (float("nan"), float("inf"), float("-inf")):
            self.assertIsNone(demote._num(bad), f"{bad!r} must not be a usable threshold")
        self.assertEqual(demote._num(3), 3.0)
        self.assertEqual(demote._num("3"), 3.0)
        self.assertIsNone(demote._num(True))
        # A NaN threshold must not demote, and must not be read as "no threshold".
        hits = demote._rule_hits({"reverts_7d": float("nan"), "audit_fail_any": True},
                                  {"reverts_7d": 99}, fast=False)
        self.assertEqual([h for h in hits if "revert" in h], [])

    def test_a_state_only_edit_cannot_reuse_the_previous_ruling(self):
        """QA r10: the promotion rule checked only that `approval_ref`/`since` were
        TRUTHY, so a base `canary` row that already cited a ruling could be flipped to
        `live` by editing `rollout.state` alone — the old ruling, which authorized the
        canary step, silently authorized the promotion. The metadata must be for THIS
        promotion, so it is compared against the base row."""
        gate = self.gate()
        rows = json.loads(self.registry_path.read_text())["capabilities"]
        honoured = "\n".join(r["kill_file"] for r in rows)
        base = json.loads(json.dumps({r["id"]: r for r in rows}["credit.add.decide"]))
        base["rollout"].update({"state": "canary", "since": "2026-10-01T00:00:00Z",
                                 "approval_ref": "request-sentinel-fable-s1"})
        prev_rollout = {base["id"]: dict(base["rollout"])}
        # State-only edit: same ruling, same since, new state.
        up = json.loads(json.dumps(base))
        up["rollout"]["state"] = "live"
        bad, _ = gate.check([up], honoured, {base["id"]: "canary"}, prev_rollout)
        self.assertTrue(any("reuses the base row" in b and "approval_ref" in b for b in bad),
                        f"a state-only promotion must be refused, got {bad}")
        # A fresh ruling + since for THIS promotion passes.
        up["rollout"].update({"since": "2026-11-06T00:00:00Z",
                              "approval_ref": "request-sentinel-fable-s2"})
        bad, _ = gate.check([up], honoured, {base["id"]: "canary"}, prev_rollout)
        self.assertEqual([b for b in bad if "reuses the base row" in b], [])
        # A demotion is never asked for a ruling, so it is never asked for fresh metadata.
        down = json.loads(json.dumps(base))
        down["rollout"]["state"] = "shadow"
        bad, _ = gate.check([down], honoured, {base["id"]: "canary"}, prev_rollout)
        self.assertEqual(bad, [])

    def _git_repo(self):
        """A real temp git repo, because base_states shells out to git on purpose."""
        import subprocess
        repo = self.tmp / "repo"
        (repo / "policies").mkdir(parents=True)
        def git(*a):
            return subprocess.run(["git", "-C", str(repo), *a], capture_output=True, text=True)
        git("init", "-q", "-b", "main")
        git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "base")
        return repo, git

    def test_gate_fails_closed_when_the_base_ref_or_registry_cannot_be_read(self):
        """`{}` from base_states used to mean both "first introduction" AND "git failed",
        so an unreadable base accepted `shadow → live` with no approval_ref. Only a
        genuinely absent registry may be empty; everything else must fail the gate."""
        gate = self.gate()
        repo, _git = self._git_repo()
        # Absent on base: legitimately `{}` (this PR introduces the file).
        self.assertEqual(gate.base_states(repo, "main"), {})
        # A ref that does not resolve is a hard error, never a silent pass.
        with self.assertRaises(gate.BaseUnreadable):
            gate.base_states(repo, "no-such-ref")
        # A registry committed on base is read back...
        (_git("add", "policies/sentinel-capabilities.json"))
        doc = {"capabilities": [{"id": "credit.add.decide", "rollout": {"state": "shadow"}}]}
        (repo / "policies" / "sentinel-capabilities.json").write_text(json.dumps(doc), encoding="utf-8")
        _git("add", "-A")
        _git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "registry")
        self.assertEqual(gate.base_states(repo, "main"), {"credit.add.decide": "shadow"})
        # ...and unparseable bytes on base are an error, not "no previous state".
        (repo / "policies" / "sentinel-capabilities.json").write_text("{not json", encoding="utf-8")
        _git("add", "-A")
        _git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "broken")
        with self.assertRaises(gate.BaseUnreadable):
            gate.base_states(repo, "main")

    def test_a_base_registry_of_literal_empty_json_is_unreadable_not_empty(self):
        """QA r5: a base committed as valid JSON `{}` returned `{}` previous states, so
        `shadow → live` with no approval_ref passed the gate. A document that exists but
        carries no `capabilities` list is a BROKEN registry, not an absent one."""
        gate = self.gate()
        repo, _git = self._git_repo()
        doc = repo / "policies" / "sentinel-capabilities.json"
        for i, payload in enumerate(('{}', '[]', '{"capabilities": {}}', '{"rows": []}')):
            doc.write_text(payload, encoding="utf-8")
            _git("add", "-A")
            _git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", f"empty-{i}")
            with self.assertRaises(gate.BaseUnreadable, msg=f"payload {payload!r} must not read as {{}}"):
                gate.base_states(repo, "main")

    def test_a_kill_file_named_only_in_a_comment_is_not_honoured(self):
        """QA r5 (carried forward): dropping test paths fixed only half of it —
        `honoured_names()` still counted a COMMENT in a production file, so a `live` row
        could name a switch that appears in `scripts/actor.py` as prose while the actor
        never touches the disk. Evidence now requires an existence check."""
        gate = self.gate()
        repo = self.tmp / "repo"
        (repo / "scripts").mkdir(parents=True)
        actor = repo / "scripts" / "actor.py"
        kill = "/etc/hydra/fake-switch.disabled"
        for text, honoured in (
            (f"# TODO: maybe check {kill} one day\nprint('hi')\n", False),
            (f'"""{kill} is the switch"""\nprint("hi")\n', False),
            (f'SWITCH = "{kill}"\nprint(SWITCH)\n', False),  # bound but never checked
            (f'SWITCH = pathlib.Path("{kill}")\nif SWITCH.exists():\n    raise SystemExit(3)\n', True),
            (f'if os.path.exists("{kill}"):\n    raise SystemExit(3)\n', True),
        ):
            actor.write_text(text, encoding="utf-8")
            got = gate.honoured_names(repo)
            self.assertEqual(kill in got, honoured, text)
            # ...and the gate refuses a live row on the non-evidenced cases.
            row = {"id": "x", "class": "R1", "action": {"type": "core_write"},
                   "rollout": {"state": "live", "since": "2026-01-01T00:00:00Z"},
                   "demotion": {"audit_fail_any": True}, "kill_file": kill}
            bad, _ = gate.check([row], got, {})
            self.assertEqual(any("not honoured" in b for b in bad), not honoured, text)

    def test_deleting_an_established_registry_fails_the_gate(self):
        """QA r5: once the registry is on base, deleting it turns every sentinel unit into
        a clean exit-2 skip — automatic demotion stops and the gate used to report success."""
        import subprocess
        gate = self.gate()
        repo = self.tmp / "repo"
        repo.mkdir()
        rel = gate.REGISTRY_REL
        (repo / rel).parent.mkdir(parents=True)

        def git(*args):
            return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)

        def commit(msg, allow_empty=False):
            subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t",
                            "commit", "-qm", msg] + (["--allow-empty"] if allow_empty else []),
                           check=True, capture_output=True)

        git("init", "-q", "-b", "main")
        commit("empty base", allow_empty=True)
        # 1. never landed: absence is a clean skip, the note says S0 owns it
        self.assertEqual(gate.main(["--repo", str(repo), "--base", "main"]), 0)
        # 2. land it, commit, then delete it
        (repo / rel).write_text(json.dumps({"capabilities": []}), encoding="utf-8")
        git("add", "-A")
        commit("registry lands")
        landed = git("rev-parse", "HEAD").stdout.strip()
        self.assertEqual(gate.main(["--repo", str(repo), "--base", landed]), 0,
                         "an empty registry is valid; nothing misbehaves")
        git("rm", "-q", rel)
        commit("delete the registry")
        rc = gate.main(["--repo", str(repo), "--base", landed])
        self.assertEqual(rc, 1, "deleting an established registry must fail the gate")
        # ...and the same PR-with-no-base run cannot detect it, so it says so out loud
        self.assertEqual(gate.main(["--repo", str(repo)]), 0)

    def test_an_inline_comment_cannot_masquerade_as_a_check(self):
        """QA r5: `KILL = "<path>"  # .exists()` satisfied the idiom on prose, so an
        acting row could ship a switch no actor reads."""
        gate = self.gate()
        repo = self.tmp / "repo"
        (repo / "scripts").mkdir(parents=True)
        kill = "/etc/hydra/no-real-switch.disabled"
        actor = repo / "scripts" / "a.py"
        cases = (
            (f'KILL = "{kill}"  # .exists()\n', False),
            (f'KILL = "{kill}"  # if KILL.exists(): raise SystemExit(3)\n', False),
            (f'KILL = "{kill}"  # TODO: test -e {kill}\n', False),
            (f'KILL = pathlib.Path("{kill}")\nif KILL.exists():  # guarded\n    pass\n', True),
            (f'if os.path.exists("{kill}"):  # guarded\n    pass\n', True),
        )
        for text, honoured in cases:
            actor.write_text(text, encoding="utf-8")
            self.assertEqual(kill in gate.honoured_names(repo), honoured, text)

    def test_an_unrelated_name_in_another_file_cannot_vouch_for_a_switch(self):
        """QA r5: matching "some file checks this NAME" tree-wide was unsound — an
        unrelated `UNUSED = Path(<path>)` plus an unrelated `UNUSED.exists()` elsewhere
        was accepted, so a `live` row could name a switch nothing checks."""
        gate = self.gate()
        repo = self.tmp / "repo"
        (repo / "scripts").mkdir(parents=True)
        kill = "/etc/hydra/fake-switch.disabled"
        (repo / "scripts" / "a.py").write_text(f'UNUSED = pathlib.Path("{kill}")\n', encoding="utf-8")
        (repo / "scripts" / "b.py").write_text("if UNUSED.exists():\n    pass\n", encoding="utf-8")
        self.assertNotIn(kill, gate.honoured_names(repo))

        # ...but a REAL cross-file check still counts: the binding lives in `a`, and `b`
        # imports `a` and checks `a.UNUSED.exists()`. That is the shape the live
        # `credit.add.decide` row relies on (decide.py binds, credit-review.py checks).
        (repo / "scripts" / "b.py").write_text("import a\nif a.UNUSED.exists():\n    pass\n",
                                               encoding="utf-8")
        self.assertIn(kill, gate.honoured_names(repo))

        # A qualifier naming a module the file never imports is not evidence either.
        (repo / "scripts" / "b.py").write_text("if a.UNUSED.exists():\n    pass\n", encoding="utf-8")
        self.assertNotIn(kill, gate.honoured_names(repo))

    def test_the_real_credit_decide_switch_is_evidenced_across_files(self):
        """Guards the fix from over-correcting: decide.py binds KILL_SWITCH, the check
        lives in credit-review.py as `decide.KILL_SWITCH.exists()`."""
        gate = self.gate()
        got = gate.honoured_names(REPO)
        self.assertIn("/etc/hydra/credit-trust-decide.disabled", got)

    def test_a_kill_file_named_only_in_a_test_is_not_honoured(self):
        """QA r5: honoured_names() scanned scripts/tests/*.bats, so a `live` row could
        ship a switch nothing in production reads and still pass the gate. Evidence has
        to be code that runs — a bats comment is not an actor reading the file."""
        gate = self.gate()
        repo = self.tmp / "repo"
        (repo / "scripts" / "tests").mkdir(parents=True)
        (repo / "tests").mkdir()
        kill = "/etc/hydra/fake-switch.disabled"
        (repo / "scripts" / "tests" / "x.bats").write_text(f"# {kill}\n", encoding="utf-8")
        (repo / "tests" / "test_x.py").write_text(f"# {kill}\n", encoding="utf-8")
        (repo / "scripts" / "real.sh").write_text("echo hi\n", encoding="utf-8")
        self.assertNotIn(kill, gate.honoured_names(repo),
                         "a test-only mention must not count as honouring the switch")
        # The same name in a production script IS evidence.
        (repo / "scripts" / "real.sh").write_text(f"[ -e {kill} ] && exit 3\n", encoding="utf-8")
        self.assertIn(kill, gate.honoured_names(repo))
        # And the one REAL acting row's switch is honoured from production code (the
        # fixture's other rows invent kill files on purpose, which the gate refuses).
        rows = json.loads(self.registry_path.read_text())["capabilities"]
        real = [r for r in rows if r["id"] == "credit.add.decide"][0]
        self.assertEqual(real["kill_file"], "/etc/hydra/credit-trust-decide.disabled")
        self.assertIn(real["kill_file"], gate.honoured_names(REPO))

    def test_a_suffixed_sibling_cannot_vouch_for_the_live_switch(self):
        """QA r8: `KILL_PATH_IN_TEXT` had no trailing boundary, so it matched the PREFIX of
        a longer name — `KILL = Path("/etc/hydra/case.disabled.backup")` + `KILL.exists()`
        reported `/etc/hydra/case.disabled` as honoured. A `live` row could then pass CI
        naming a switch the actor never reads, while demotion drops the file nobody checks."""
        gate = self.gate()
        repo = self.tmp / "repo"
        (repo / "scripts").mkdir(parents=True)
        actor = repo / "scripts" / "actor.py"
        kill = "/etc/hydra/case.disabled"
        cases = (
            (f'KILL = pathlib.Path("{kill}.backup")\nif KILL.exists():\n    raise SystemExit(3)\n', False),
            (f'if os.path.exists("{kill}.backup"):\n    raise SystemExit(3)\n', False),
            (f'if os.path.exists("{kill}.bak"):\n    raise SystemExit(3)\n', False),
            (f'if os.path.exists("{kill}/nested"):\n    raise SystemExit(3)\n', False),
            (f'KILL = pathlib.Path("{kill}")\nif KILL.exists():\n    raise SystemExit(3)\n', True),
            (f'if os.path.exists("{kill}"):\n    raise SystemExit(3)\n', True),
            (f'[ -e {kill} ] && exit 3\n', True),
        )
        for text, honoured in cases:
            actor.write_text(text, encoding="utf-8")
            got = gate.honoured_names(repo)
            self.assertEqual(kill in got, honoured, text)
            self.assertNotIn(f"{kill}.backup", got, text)

    def test_gate_exits_nonzero_when_the_base_ref_is_unusable(self):
        gate = self.gate()
        repo, _git = self._git_repo()
        import contextlib, io
        with contextlib.redirect_stdout(io.StringIO()):
            rc = gate.main(["--repo", str(repo), "--path", str(self.registry_path),
                            "--base", "no-such-ref"])
        self.assertEqual(rc, 1, "an unverifiable base must fail the gate, not pass it silently")

    def test_gate_treats_a_missing_registry_as_not_yet_landed(self):
        gate = self.gate()
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(gate.main(["--path", str(self.tmp / "absent.json")]), 0)
            self.assertEqual(gate.main(["--path", str(self.registry_path)]), 1,
                             "the fixture's invented kill files must be refused for an acting row")

    def test_gate_refuses_a_malformed_row(self):
        gate = self.gate()
        bad, _ = gate.check([{"id": "x", "class": "R1"}], honoured="", prev={})
        self.assertTrue(any("action.type" in b for b in bad))
        self.assertTrue(any("rollout.state" in b for b in bad))
        self.assertTrue(any("demotion" in b for b in bad))
        self.assertTrue(any("kill_file" in b for b in bad))


if __name__ == "__main__":
    unittest.main()