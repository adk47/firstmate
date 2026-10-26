"""Fraud lens (credit_review/fraud_lens.py; Fable ruling-intercom-external-id-1026 Ruling B) and the
uvn-status runner's use of it: the >= 10 single-signal threshold, velocity bands, watchlist + named
holds (missing = fatal), ask-only users never get Copy A / B0. Trino and the gate are faked."""
from __future__ import annotations

import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "scripts" / "tests"))

from credit_review import fraud_lens, uvn_status, watchlist  # noqa: E402
import test_uvn_status as T  # noqa: E402  (its fixtures: replica, FakeGate, proof, iso, NOW)

SINGLE = json.dumps({"hold_reason_codes": ["review_big_track_without_trusted_credit"]})
WEAK = json.dumps({"hold_reason_codes": ["review_big_track_weak_footprint"]})
SHORTCUT = json.dumps({"shortcut_source": "spotify_credits"})
TRUSTED = json.dumps({"hold_reason_codes": ["something_else"]})


class ThresholdTests(unittest.TestCase):
    def test_threshold_is_ten(self):
        self.assertEqual(fraud_lens.SINGLE_SIGNAL_HOLD_MIN, 10)

    def test_nine_single_signal_rows_are_released_to_the_ask_only(self):
        v = fraud_lens.verdict(single_signal_rows=9)
        self.assertEqual(v.held, [])
        self.assertTrue(v.ask_only)

    def test_ten_single_signal_rows_stay_held(self):
        v = fraud_lens.verdict(single_signal_rows=10)
        self.assertEqual(len(v.held), 1)
        self.assertIn("big-track claim on a single signal: 10", v.held[0])
        self.assertFalse(v.ask_only)

    def test_no_single_signal_rows_is_clean(self):
        v = fraud_lens.verdict()
        self.assertEqual((v.held, v.ask_only), ([], False))

    def test_velocity_bands_hold_above_the_band_only(self):
        self.assertEqual(fraud_lens.verdict(max_rows_day=300).held, [])
        self.assertIn("level B'", fraud_lens.verdict(max_rows_day=301).held[0])
        self.assertEqual(fraud_lens.verdict(max_big_day=10).held, [])
        self.assertIn("level C", fraud_lens.verdict(max_big_day=11).held[0])

    def test_velocity_or_watchlist_hold_wins_over_ask_only(self):
        v = fraud_lens.verdict(watch=["watchlist fraud user"], single_signal_rows=2)
        self.assertTrue(v.held)
        self.assertFalse(v.ask_only)
        self.assertFalse(fraud_lens.verdict(max_rows_day=900, single_signal_rows=1).ask_only)

    def test_single_signal_row_predicate(self):
        self.assertTrue(fraud_lens.single_signal("60", SINGLE))
        self.assertTrue(fraud_lens.single_signal(75, WEAK))
        self.assertTrue(fraud_lens.single_signal("80", SHORTCUT))
        self.assertTrue(fraud_lens.single_signal("80", json.dumps(SINGLE)))  # double-encoded replica json
        self.assertFalse(fraud_lens.single_signal("59", SINGLE))
        self.assertFalse(fraud_lens.single_signal("90", TRUSTED))
        self.assertFalse(fraud_lens.single_signal("", SINGLE))
        self.assertFalse(fraud_lens.single_signal("90", "not json"))


def lens_replica(rows_by_user, velocity=None, emails=None):
    """Answers the Lens's three queries for the ids the SQL names. rows_by_user[u] = [(profile, pop, vd)]."""
    velocity, emails = velocity or {}, emails or {}

    def q(sql):
        ids = {int(x) for x in re.search(r"(?:id|userid) IN \(([0-9,]+)\)", sql).group(1).split(",")}
        if "public.users" in sql:
            return [[str(u), emails.get(u, f"u{u}@x.com")] for u in sorted(ids)]
        if "max(n)" in sql:
            return [[str(u), str(velocity.get(u, (1, 0))[0]), str(velocity.get(u, (1, 0))[1])] for u in sorted(ids)]
        return [[str(u), p, str(pop), vd] for u in sorted(ids) for p, pop, vd in rows_by_user.get(u, [])]
    return q


WPROFILE = "aaaaaaaa-0000-4000-8000-000000000001"


class LensTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="lens-"))
        wl = self.dir / "wl.json"
        wl.write_text(json.dumps({"entries": [
            {"tier": "fraud", "reason": "r", "evidence": "e", "added_at": "x", "added_by": "y", "user_ids": [5]},
            {"tier": "review", "reason": "r", "evidence": "e", "added_at": "x", "added_by": "y", "profile_ids": [WPROFILE]}]}))
        self.wl = watchlist.load(wl, required=True)

    def lens(self, q, holds=None):
        return fraud_lens.Lens(q, self.wl, holds or {})

    def test_lens_counts_single_signal_rows_per_user(self):
        q = lens_replica({1: [("p", 70, SINGLE)] * 10, 2: [("p", 70, SINGLE)] * 3 + [("p", 90, TRUSTED)], 3: []})
        v = self.lens(q)([1, 2, 3])
        self.assertTrue(v[1].held)
        self.assertEqual((v[2].held, v[2].ask_only, v[2].single_signal_rows), ([], True, 3))
        self.assertEqual((v[3].held, v[3].ask_only), ([], False))

    def test_watchlist_user_profile_and_named_hold_are_held(self):
        q = lens_replica({7: [(WPROFILE, 5, "{}")]})
        v = self.lens(q, holds={8: "a1 audit PULL account"})([5, 7, 8, 9])
        self.assertIn("watchlist fraud user", v[5].held)
        self.assertTrue(any("profile" in r for r in v[7].held))
        self.assertIn("fraud-lens hold: a1 audit PULL account", v[8].held)
        self.assertEqual(v[9].held, [])

    def test_velocity_from_the_replica(self):
        v = self.lens(lens_replica({}, velocity={1: (313, 0), 2: (5, 44)}))([1, 2, 3])
        self.assertTrue(v[1].held and v[2].held)
        self.assertEqual(v[3].held, [])

    def test_split(self):
        q = lens_replica({1: [("p", 70, SINGLE)] * 12, 2: [("p", 70, SINGLE)]})
        out = fraud_lens.split([1, 2, 3], self.lens(q))
        self.assertEqual(([h["user_id"] for h in out["held"]], out["ask_only"], out["clean"]), ([1], [2], [3]))


class HoldsFileTests(unittest.TestCase):
    def test_repo_holds_file_loads_and_carries_the_named_accounts(self):
        holds = fraud_lens.load_holds()
        for u in (350590, 256637, 219737, 305363, 184149, 335445, 53136, 340552, 128308):
            self.assertIn(u, holds)

    def test_missing_or_malformed_holds_file_is_fatal(self):
        d = Path(tempfile.mkdtemp(prefix="holds-"))
        with self.assertRaises(ValueError):
            fraud_lens.load_holds(d / "missing.json")
        bad = d / "bad.json"
        bad.write_text(json.dumps({"entries": [{"reason": "x", "evidence": "y", "user_ids": ["12"]}]}))
        with self.assertRaises(ValueError):
            fraud_lens.load_holds(bad)

    def test_missing_watchlist_is_fatal_for_the_default_lens(self):
        with self.assertRaises(ValueError):
            fraud_lens.default_lens(lambda q: [], watchlist_path="/nonexistent/fraud-watchlist.json")


class RunnerLensTests(unittest.TestCase):
    """uvn_status.run loads the lens itself (watchlist required) and applies it per user."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="uvn-lens-"))
        self.list, self.proof, self.ledger = self.dir / "list.json", self.dir / "proof.json", str(self.dir / "l.sqlite3")
        T.proof(self.proof)
        self.users = [{"user_id": u, "paid": True, "skip": None, "request_ids": [f"r{u}"]} for u in (1, 2, 3)]
        self.list.write_text(json.dumps({"generated_at": T.iso(1), "users": self.users}))
        self.saved = uvn_status.DEFAULT_LENS
        uvn_status.DEFAULT_LENS = fraud_lens.default_lens   # the deployed factory (test_uvn_status swaps it)

    def tearDown(self):
        uvn_status.DEFAULT_LENS = self.saved

    def run_(self, campaign="uvn-status", **kw):
        gate = T.FakeGate()
        status = None if campaign == "uvn-status" else {u: "unverified" for u in (1, 2, 3)}
        rep = uvn_status.run(list_path=str(self.list), segment="paid", mode="apply", max_users=10,
                             ledger_path=self.ledger, proof_path=str(self.proof), query=T.replica([1, 2, 3], status=status),
                             runner=gate, wrapper="/gate", now=T.NOW, pace_seconds=0, campaign=campaign,
                             post=lambda text: True, **kw)
        return rep, gate

    def test_missing_watchlist_halts_the_run_and_sends_nothing(self):
        rep, gate = self.run_(watchlist_path=str(self.dir / "missing.json"))
        self.assertIn("fraud lens unavailable", rep.halted)
        self.assertEqual(gate.calls, [])

    def test_missing_holds_file_halts_the_run(self):
        rep, gate = self.run_(holds_path=str(self.dir / "missing.json"))
        self.assertIn("fraud lens unavailable", rep.halted)
        self.assertEqual(gate.calls, [])

    def lens(self, held=(), ask=()):
        return lambda ids: {u: fraud_lens.Verdict(held=["x"] if u in held else [],
                                                  single_signal_rows=2 if u in ask else 0) for u in ids}

    def test_fraud_held_user_is_never_sent_or_closed(self):
        rep, gate = self.run_(lens=self.lens(held={2}))
        self.assertEqual(sorted(p["user"]["id"] for _, p in gate.calls), ["1", "3"])
        self.assertEqual(rep.fraud_held, 1)
        self.assertIn("held by the fraud lens", uvn_status.render(rep, "apply", "paid"))

    def test_ask_only_user_gets_the_uvn_ask_but_never_copy_a_or_b0(self):
        for campaign in ("status-doc-received", "status-team-review"):
            rep, gate = self.run_(campaign=campaign, lens=self.lens(ask={1}))
            self.assertNotIn("1", [p["user"]["id"] for _, p in gate.calls], campaign)
            self.assertEqual(rep.ask_only, 1, campaign)
        rep, gate = self.run_(lens=self.lens(ask={1}))
        self.assertIn("1", [p["user"]["id"] for _, p in gate.calls])
        self.assertEqual(rep.ask_only, 0)

    def test_fraud_held_user_is_never_closed_even_on_a_closing_branch(self):
        """QA @214ea86: the lens runs before no_email / done / no-longer-waiting can close the user."""
        from credit_review import verify_ledger
        gate = T.FakeGate()
        rep = uvn_status.run(list_path=str(self.list), segment="paid", mode="apply", max_users=10,
                             ledger_path=self.ledger, proof_path=str(self.proof), query=T.replica([1, 3]),  # 2: no email
                             runner=gate, wrapper="/gate", now=T.NOW, pace_seconds=0, post=lambda text: True,
                             lens=self.lens(held={2}))
        self.assertEqual(rep.fraud_held, 1)
        self.assertEqual(rep.no_email, 0)
        db = verify_ledger.connect(self.ledger)
        try:
            self.assertEqual(verify_ledger.blocked_ids(db, ["r2"], "uvn-status"), set())
        finally:
            db.close()
        # The same user, not held, takes the no_email branch and IS closed (the branch is real).
        uvn_status.run(list_path=str(self.list), segment="paid", mode="apply", max_users=10, ledger_path=self.ledger,
                       proof_path=str(self.proof), query=T.replica([1, 3]), runner=T.FakeGate(), wrapper="/gate",
                       now=T.NOW, pace_seconds=0, post=lambda text: True, lens=self.lens())
        db = verify_ledger.connect(self.ledger)
        try:
            self.assertEqual(verify_ledger.blocked_ids(db, ["r2"], "uvn-status"), {"r2"})
        finally:
            db.close()

    def test_a_user_the_lens_returns_no_verdict_for_is_held(self):
        rep, gate = self.run_(lens=lambda ids: {})
        self.assertEqual(gate.calls, [])
        self.assertEqual(rep.fraud_held, 3)


if __name__ == "__main__":
    unittest.main()
