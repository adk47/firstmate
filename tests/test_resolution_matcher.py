"""Behavioral tests for scripts/resolution-matcher.py.

This script runs UNATTENDED daily (`--apply` via resolution-matcher.timer) and
both MESSAGES customers and CLOSES their conversations/tickets autonomously, on
the strength of an action_log "the fix you reported shipped" backtest. The whole
reason that is safe with no human in the loop is the same guard stack the sibling
notifiers carry — so a regression in any of them silently messages the wrong
person, double-messages, or auto-closes on a phantom fix. These tests lock those
invariants:

  - the backtest only matches an admin DATA-FIX route touching the EXACT entity
    the customer cited, AFTER they reported (no cite -> never matched);
  - SQL is built only from validated values (no injection from cites/routes);
  - a fresh-deploy COLD START seeds and sends NOTHING;
  - a wiped/mangled-state CIRCUIT BREAKER aborts instead of blasting;
  - per-conversation dedup (acted-once, ever);
  - a wrong-customer / closed / human-handled conversation is suppressed before
    any outbound;
  - an action_log query error fails CLOSED (that member stays open).

Stdlib unittest + stubs only — no pytest dependency, no network — so it runs
under the same bare `python3 -m unittest` the py-tests CI job already uses.
"""
import importlib.util
import json
import os
import pathlib
import tempfile
import unittest

# Hyphenated filename can't be imported by name; load it from its path as `rm`.
_SCRIPT = (
    pathlib.Path(__file__).resolve().parent.parent
    / "scripts"
    / "resolution-matcher.py"
)
_spec = importlib.util.spec_from_file_location("resolution_matcher", _SCRIPT)
rm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rm)

UUID = "78d7dcd3-3b1c-4aaa-bbbb-0123456789ab"
NOW = 1782000000  # fixed clock for determinism


def feed_line(conv_id, email, cites, age_hours=5, paged_at=NOW - 3600,
              slug="credits-misattribution", title="Credits misattribution"):
    return json.dumps({
        "paged_at": paged_at, "issue_slug": slug, "title": title,
        "symptom": "wrong name on credits",
        "members": [{"conv_id": conv_id, "email": email, "cites": cites,
                     "age_hours": age_hours}],
    })


def conv(cid="111", email="a@b.com", state="open", parts=None, assignee=None, tags=None):
    c = {"id": cid, "source": {"author": {"type": "user", "email": email}},
         "state": state,
         "conversation_parts": {"conversation_parts": parts or []}}
    if assignee is not None:
        c["admin_assignee_id"] = assignee
    if tags is not None:
        c["tags"] = {"tags": [{"name": t} for t in tags]}
    return c


# --------------------------------------------------------------------------
# Pure logic
# --------------------------------------------------------------------------
class PureLogic(unittest.TestCase):
    def test_self_test_passes(self):
        self.assertTrue(rm._self_test())

    def test_entity_extraction(self):
        self.assertEqual(
            rm.extract_entity_ids([f"https://credits.muso.ai/track/{UUID}", UUID.upper(), "x"]),
            [UUID])
        self.assertEqual(rm.extract_entity_ids([]), [])
        self.assertEqual(rm.extract_entity_ids(["no id at all"]), [])

    def test_sql_injection_safe(self):
        with self.assertRaises(ValueError):
            rm.build_action_log_sql(["not-a-uuid"], 0, 60)
        sql = rm.build_action_log_sql([UUID], 1000, 60)
        self.assertIn("from_unixtime(1000)", sql)
        self.assertNotIn("';", sql)  # no statement break

    def test_sql_matches_route_not_requestdata(self):
        # The fix for merge-loser / claim-denial false positives: the cited id
        # must appear in the ROUTE (primary target), never anywhere in requestdata.
        sql = rm.build_action_log_sql([UUID], 1000, 60)
        self.assertIn(f"route LIKE '%{UUID}%'", sql)
        # Form-agnostic: the entire WHERE clause (route predicates + method + time +
        # id match) must not reference requestdata — so ANY requestdata-match
        # regression fails. The legitimate columns (route, email) live in the SELECT.
        where_part = sql.split("WHERE", 1)[1]
        self.assertNotIn("requestdata", where_part)

    def test_fix_route_predicates_credits_and_profile_edit(self):
        # node-8-validated route set: credit edits + bare profile edits, attributed
        # via the action_log `email` actor column (requestdata.requester is empty).
        sql = rm.build_action_log_sql([UUID], 1000, 60)
        self.assertIn("route LIKE '%/credits%'", sql)               # credit add/remove
        self.assertIn("regexp_like(route, '^/api/v3/admin/profile/", sql)  # bare profile edit
        self.assertIn("COALESCE(email, '') AS requester", sql)      # attribution = actor email
        # merge / noise routes are not literally in the predicates (excluded).
        self.assertNotIn("/api/v3/admin/profiles/merge", sql)
        self.assertNotIn("cache", sql)

    def test_reported_at_caps_and_validates_age(self):
        big = rm.MAX_REPORT_LOOKBACK_HOURS + 1000
        self.assertEqual(rm.member_reported_at({"paged_at": 10**9, "age_hours": big}, 0), 10**9)
        self.assertEqual(rm.member_reported_at({"paged_at": 10**9, "age_hours": -3}, 0), 10**9)
        self.assertEqual(rm.member_reported_at({"paged_at": 10**9, "age_hours": 2}, 0),
                         10**9 - 2 * 3600)

    def test_compact_feed_drops_past_horizon(self):
        d = tempfile.mkdtemp()
        path = os.path.join(d, "feed.jsonl")
        with open(path, "w") as f:
            f.write(feed_line("111", "a@b.com", [UUID], paged_at=NOW - 3600) + "\n")   # in
            f.write(feed_line("222", "c@d.com", [UUID], paged_at=NOW - 200 * 86400) + "\n")  # out
        rm.compact_feed(path, NOW, 60)
        with open(path) as f:
            rows = [json.loads(l) for l in f if l.strip()]
        self.assertEqual([m["conv_id"] for r in rows for m in r["members"]], ["111"])

    def test_reported_at(self):
        self.assertEqual(rm.member_reported_at({"paged_at": 10000, "age_hours": 1}, 0), 10000 - 3600)
        self.assertEqual(rm.member_reported_at({"paged_at": 10000}, 0), 10000)
        self.assertEqual(rm.member_reported_at({}, 777), 777)

    def test_suppression_gates(self):
        ok = conv(email="a@b.com")
        self.assertIsNone(rm.conversation_suppressed(ok, "a@b.com", rm.CAROLINE_ADMIN_ID))
        self.assertEqual(rm.conversation_suppressed(ok, "other@x.com", rm.CAROLINE_ADMIN_ID),
                         "email-mismatch")
        self.assertEqual(rm.conversation_suppressed(ok, "", rm.CAROLINE_ADMIN_ID),
                         "email-mismatch")  # empty member email fails closed
        self.assertEqual(
            rm.conversation_suppressed(conv(state="closed"), "a@b.com", rm.CAROLINE_ADMIN_ID),
            "not-open")
        human = conv(parts=[{"author": {"type": "admin", "id": "999"}}])
        self.assertEqual(rm.conversation_suppressed(human, "a@b.com", rm.CAROLINE_ADMIN_ID),
                         "human-reply")
        cust = conv(parts=[{"author": {"type": "user", "id": "u1"}}])
        self.assertIsNone(rm.conversation_suppressed(cust, "a@b.com", rm.CAROLINE_ADMIN_ID))
        self.assertEqual(
            rm.conversation_suppressed(conv(assignee="42"), "a@b.com", rm.CAROLINE_ADMIN_ID),
            "assignee-human")
        self.assertEqual(
            rm.conversation_suppressed(conv(tags=["instagram"]), "a@b.com", rm.CAROLINE_ADMIN_ID),
            "blocked-tag")

    def test_detect_fix(self):
        m = {"cites": [f"track/{UUID}"], "paged_at": 1000, "age_hours": 0}
        captured = {}

        def ok(sql, b):
            captured["sql"] = sql
            return [{"route": "/api/v3/admin/profile/abc/credits", "method": "PUT",
                     "requester": "aaron@muso.ai", "at": "2026-06-29 10:00:00 UTC"}]
        fix = rm.detect_fix(m, 2000, "muso", 60, _query=ok)
        self.assertEqual(fix["requester"], "aaron@muso.ai")
        # Bind the SQL floor to member_reported_at — the "AFTER they reported"
        # invariant must be wired end-to-end, not just unit-tested in isolation. A
        # regression passing the wrong floor (e.g. 0, or now_epoch) fails here.
        self.assertIn(f"from_unixtime({rm.member_reported_at(m, 2000)})", captured["sql"])
        self.assertIsNone(rm.detect_fix({"cites": ["no uuid"], "paged_at": 1000},
                                        2000, "muso", 60, _query=ok))
        self.assertIsNone(rm.detect_fix(m, 2000, "muso", 60, _query=lambda s, b: []))

    def test_load_feed_dedup_horizon_anon(self):
        d = tempfile.mkdtemp()
        path = os.path.join(d, "feed.jsonl")
        with open(path, "w") as f:
            f.write(feed_line("111", "A@B.com", [f"track/{UUID}"], paged_at=NOW - 7200) + "\n")
            f.write(feed_line("111", "A@B.com", [f"track/{UUID}"], paged_at=NOW - 3600) + "\n")  # newer
            f.write(feed_line("222", "", ["no id"], paged_at=NOW - 3600) + "\n")  # anon
            f.write("{ not json\n")  # bad line ignored
            f.write(feed_line("333", "c@d.com", [UUID], paged_at=NOW - 200 * 86400) + "\n")  # past horizon
        members = rm.load_feed(path, NOW, 60)
        ids = {m["conv_id"]: m for m in members}
        self.assertEqual(set(ids), {"111", "222"})  # 333 dropped (horizon), bad line skipped
        self.assertEqual(ids["111"]["paged_at"], NOW - 3600)  # newest line wins
        self.assertEqual(ids["111"]["email"], "a@b.com")  # normalized
        self.assertEqual(ids["222"]["email"], "")  # anon


# --------------------------------------------------------------------------
# main() integration — monkeypatched seams, no network
# --------------------------------------------------------------------------
class MainFlow(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.feed = os.path.join(self.d, "feed.jsonl")
        self.state = os.path.join(self.d, "state.json")
        self.shadow = os.path.join(self.d, "shadow.jsonl")
        os.environ.update({
            "RESOLUTION_SKIP_HOST_GUARD": "1",
            "MUSOAI_INTERCOM_TOKEN": "fake",
            "RESOLUTION_FEED_PATH": self.feed,
            "RESOLUTION_STATE_PATH": self.state,
            "RESOLUTION_SHADOW_LOG": self.shadow,
            "RESOLUTION_NOW": str(NOW),
            "RESOLUTION_MATCHER_MAX": "15",
        })
        os.environ.pop("CLICKUP_API_KEY", None)  # no ClickUp index
        # Seams: record calls, never touch network.
        self.calls = {"reply": [], "close": []}
        self._orig = {k: getattr(rm, k) for k in
                      ("get_conversation", "post_intercom_reply", "close_conversation",
                       "query_action_log", "post_slack")}
        rm.get_conversation = lambda cid, tok: conv(cid=cid, email="a@b.com")
        rm.post_intercom_reply = lambda cid, aid, msg, tok: self.calls["reply"].append(cid)
        rm.close_conversation = lambda cid, aid, tok: self.calls["close"].append(cid)
        rm.query_action_log = lambda sql, b: [
            {"route": "/api/v3/admin/profile/x/credits", "method": "PUT",
             "requester": "aaron@muso.ai", "at": "2026-06-29 10:00:00 UTC"}]
        rm.post_slack = lambda *a, **k: True

    def tearDown(self):
        for k, v in self._orig.items():
            setattr(rm, k, v)
        for k in ("RESOLUTION_SKIP_HOST_GUARD", "MUSOAI_INTERCOM_TOKEN",
                  "RESOLUTION_FEED_PATH", "RESOLUTION_STATE_PATH", "RESOLUTION_SHADOW_LOG",
                  "RESOLUTION_NOW", "RESOLUTION_MATCHER_MAX"):
            os.environ.pop(k, None)

    def _write_feed(self, *lines):
        with open(self.feed, "w") as f:
            for ln in lines:
                f.write(ln + "\n")

    def test_cold_start_seeds_and_sends_nothing(self):
        self._write_feed(feed_line("111", "a@b.com", [f"track/{UUID}"]))
        rc = rm.main(["--apply"])
        self.assertEqual(rc, 0)
        self.assertEqual(self.calls["reply"], [])  # nothing sent on cold start
        self.assertEqual(self.calls["close"], [])
        seeded = json.load(open(self.state))
        self.assertIn(rm.SEED_SENTINEL, seeded)
        self.assertIn("conv:111", seeded)  # member seeded as already-seen

    def test_second_run_sends_and_closes(self):
        # Pre-seed state WITHOUT this member so it is "fresh".
        rm.write_state(self.state, {rm.SEED_SENTINEL: NOW - 86400})
        self._touch_old(self.state)  # state file old -> breaker won't trip
        self._write_feed(feed_line("111", "a@b.com", [f"track/{UUID}"]))
        rc = rm.main(["--apply"])
        self.assertEqual(rc, 0)
        self.assertEqual(self.calls["reply"], ["111"])
        self.assertEqual(self.calls["close"], ["111"])
        with open(self.state) as f:
            st = json.load(f)
        self.assertIn("conv:111", st)  # acted, recorded
        with open(self.shadow) as f:
            shadow = [json.loads(l) for l in f]
        self.assertEqual(shadow[0]["conv_id"], "111")

    def test_close_failure_does_not_double_send(self):
        # If close fails AFTER the reply sent, the send must be recorded so the
        # next daily run does NOT re-message the still-open conv (our own bot
        # reply is not a human-reply suppression). Exactly-once is the invariant.
        rm.write_state(self.state, {rm.SEED_SENTINEL: NOW - 86400})
        self._touch_old(self.state)

        def boom_close(cid, aid, tok):
            raise RuntimeError("intercom close 500")
        rm.close_conversation = boom_close
        self._write_feed(feed_line("111", "a@b.com", [f"track/{UUID}"]))
        rc = rm.main(["--apply"])
        self.assertEqual(rc, 0)  # close failure is best-effort, not a run failure
        self.assertEqual(self.calls["reply"], ["111"])  # the message DID go out
        with open(self.state) as f:
            st = json.load(f)
        self.assertIn("conv:111", st)  # recorded despite the close failure
        # Next daily run with the same feed must NOT re-send.
        self.calls["reply"].clear()
        self._touch_old(self.state)
        rc2 = rm.main(["--apply"])
        self.assertEqual(rc2, 0)
        self.assertEqual(self.calls["reply"], [])  # exactly-once

    def test_dedup_already_acted(self):
        rm.write_state(self.state, {rm.SEED_SENTINEL: NOW - 86400, "conv:111": NOW - 100})
        self._touch_old(self.state)
        self._write_feed(feed_line("111", "a@b.com", [f"track/{UUID}"]))
        rc = rm.main(["--apply"])
        self.assertEqual(rc, 0)
        self.assertEqual(self.calls["reply"], [])  # already acted -> not re-sent

    def test_wrong_customer_suppressed_transient_not_persisted(self):
        # email-mismatch is TRANSIENT (possibly stale Intercom author data) — must
        # NOT be recorded acted, so a later run can re-evaluate.
        rm.write_state(self.state, {rm.SEED_SENTINEL: NOW - 86400})
        self._touch_old(self.state)
        rm.get_conversation = lambda cid, tok: conv(cid=cid, email="someone-else@x.com")
        self._write_feed(feed_line("111", "a@b.com", [f"track/{UUID}"]))
        rc = rm.main(["--apply"])
        self.assertEqual(rc, 0)
        self.assertEqual(self.calls["reply"], [])  # email mismatch -> no send
        self.assertEqual(self.calls["close"], [])
        with open(self.state) as f:
            st = json.load(f)
        self.assertNotIn("conv:111", st)  # transient -> not recorded

    def test_durable_suppression_is_persisted(self):
        # a human last-replied -> a stable decision -> record acted (don't re-GET).
        rm.write_state(self.state, {rm.SEED_SENTINEL: NOW - 86400})
        self._touch_old(self.state)
        rm.get_conversation = lambda cid, tok: conv(
            cid=cid, email="a@b.com", parts=[{"author": {"type": "admin", "id": "999"}}])
        self._write_feed(feed_line("111", "a@b.com", [f"track/{UUID}"]))
        rc = rm.main(["--apply"])
        self.assertEqual(rc, 0)
        self.assertEqual(self.calls["reply"], [])  # human handled -> no send
        with open(self.state) as f:
            st = json.load(f)
        self.assertIn("conv:111", st)  # durable -> recorded

    def test_circuit_breaker_aborts(self):
        # Seeded state (so not cold-start) but members are fresh; MAX=1, 2 matched,
        # state file just written -> breaker trips, nothing sent, exit 2.
        os.environ["RESOLUTION_MATCHER_MAX"] = "1"
        rm.write_state(self.state, {rm.SEED_SENTINEL: NOW - 86400})
        os.utime(self.state, (NOW - 60, NOW - 60))  # recent -> breaker armed
        self._write_feed(
            feed_line("111", "a@b.com", [f"track/{UUID}"]),
            feed_line("222", "c@d.com", [f"track/{UUID}"], slug="other-issue"))
        rc = rm.main(["--apply"])
        self.assertEqual(rc, 2)
        self.assertEqual(self.calls["reply"], [])

    def test_query_error_fails_closed(self):
        rm.write_state(self.state, {rm.SEED_SENTINEL: NOW - 86400})
        self._touch_old(self.state)
        def boom(sql, b):
            raise RuntimeError("trino down")
        rm.query_action_log = boom
        self._write_feed(feed_line("111", "a@b.com", [f"track/{UUID}"]))
        rc = rm.main(["--apply"])
        self.assertEqual(rc, 0)  # not a hard failure
        self.assertEqual(self.calls["reply"], [])  # member left open, nothing sent

    def test_no_cite_never_matched(self):
        rm.write_state(self.state, {rm.SEED_SENTINEL: NOW - 86400})
        self._touch_old(self.state)
        self._write_feed(feed_line("111", "a@b.com", ["no entity id here"]))
        rc = rm.main(["--apply"])
        self.assertEqual(rc, 0)
        self.assertEqual(self.calls["reply"], [])  # un-backtestable -> never messaged

    def _touch_old(self, path):
        old = NOW - 48 * 3600
        os.utime(path, (old, old))


# --------------------------------------------------------------------------
# Phase 2a shadow wiring (docs/plans/jev-adoption.md #2a). The resolution-match
# Jev call fires strictly AFTER detect_fix() already matched a member to a fix
# row, and must never change `matched`, `to_act`, stdout, or the exit code —
# regardless of whether jev.sh succeeds, fails, hangs, or is disabled.
# --------------------------------------------------------------------------
_FAKE_JEV = str(
    pathlib.Path(__file__).resolve().parent.parent
    / "scripts" / "tests" / "fixtures" / "jev" / "fake-jev-sh.sh"
)
_REAL_JEV = str(
    pathlib.Path(__file__).resolve().parent.parent / "scripts" / "lib" / "jev.sh"
)


class JevShadowWiring(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.feed = os.path.join(self.d, "feed.jsonl")
        self.state = os.path.join(self.d, "state.json")
        self.shadow = os.path.join(self.d, "shadow.jsonl")
        self.jev_shadow_dir = os.path.join(self.d, "jev-shadow")
        os.makedirs(self.jev_shadow_dir, exist_ok=True)
        os.environ.update({
            "RESOLUTION_SKIP_HOST_GUARD": "1",
            "MUSOAI_INTERCOM_TOKEN": "fake",
            "RESOLUTION_FEED_PATH": self.feed,
            "RESOLUTION_STATE_PATH": self.state,
            "RESOLUTION_SHADOW_LOG": self.shadow,
            "RESOLUTION_NOW": str(NOW),
            "RESOLUTION_MATCHER_MAX": "15",
            "JEV_SHADOW_DIR": self.jev_shadow_dir,
        })
        os.environ.pop("CLICKUP_API_KEY", None)
        self.calls = {"reply": [], "close": []}
        self._orig = {k: getattr(rm, k) for k in
                      ("get_conversation", "post_intercom_reply", "close_conversation",
                       "query_action_log", "post_slack", "shadow_judge")}
        rm.get_conversation = lambda cid, tok: conv(cid=cid, email="a@b.com")
        rm.post_intercom_reply = lambda cid, aid, msg, tok: self.calls["reply"].append(cid)
        rm.close_conversation = lambda cid, aid, tok: self.calls["close"].append(cid)
        rm.query_action_log = lambda sql, b: [
            {"route": "/api/v3/admin/profile/x/credits", "method": "PUT",
             "requester": "aaron@muso.ai", "at": "2026-06-29 10:00:00 UTC"}]
        rm.post_slack = lambda *a, **k: True

    def tearDown(self):
        for k, v in self._orig.items():
            setattr(rm, k, v)
        for k in ("RESOLUTION_SKIP_HOST_GUARD", "MUSOAI_INTERCOM_TOKEN",
                  "RESOLUTION_FEED_PATH", "RESOLUTION_STATE_PATH", "RESOLUTION_SHADOW_LOG",
                  "RESOLUTION_NOW", "RESOLUTION_MATCHER_MAX", "JEV_SHADOW_DIR",
                  "JEV_SH", "JEV_SHADOW_FAKE_MODE", "JEV_DISABLED_FILE"):
            os.environ.pop(k, None)

    def _write_feed(self, *lines):
        with open(self.feed, "w") as f:
            for ln in lines:
                f.write(ln + "\n")

    def _touch_old(self, path):
        old = NOW - 48 * 3600
        os.utime(path, (old, old))

    def _run_scenario(self, jev_sh, disabled_file=None):
        rm.write_state(self.state, {rm.SEED_SENTINEL: NOW - 86400})
        self._touch_old(self.state)
        self._write_feed(feed_line("111", "a@b.com", [f"track/{UUID}"]))
        os.environ["JEV_SH"] = jev_sh
        if disabled_file:
            os.environ["JEV_DISABLED_FILE"] = disabled_file
        else:
            os.environ.pop("JEV_DISABLED_FILE", None)
        rc = rm.main(["--apply"])
        with open(self.state) as f:
            state = json.load(f)
        return {"rc": rc, "reply": list(self.calls["reply"]),
                "close": list(self.calls["close"]), "state": state}

    def test_shadow_call_never_changes_outcome_across_ok_rc2_hang_killswitch(self):
        os.environ["JEV_SHADOW_FAKE_MODE"] = "ok"
        baseline = self._run_scenario(_FAKE_JEV)
        self.assertEqual(baseline["reply"], ["111"])  # sanity: this member did act

        for mode in ("rc2", "hang"):
            self.calls["reply"].clear()
            self.calls["close"].clear()
            os.environ["JEV_SHADOW_FAKE_MODE"] = mode
            result = self._run_scenario(_FAKE_JEV)
            self.assertEqual(result, baseline, f"mode={mode} changed observable behaviour")

        # Kill switch: real jev.sh, JEV_DISABLED_FILE present -> jev.sh exits 6.
        self.calls["reply"].clear()
        self.calls["close"].clear()
        ks_file = os.path.join(self.d, "jev.disabled")
        with open(ks_file, "w"):
            pass
        result = self._run_scenario(_REAL_JEV, disabled_file=ks_file)
        self.assertEqual(result, baseline, "kill switch changed observable behaviour")

    def test_shadow_actual_is_matched_for_a_would_act_member(self):
        captured = []
        rm.shadow_judge = lambda surface, item_id, state, questions, actual=None: (
            captured.append((surface, item_id, actual)) or None)
        rm.write_state(self.state, {rm.SEED_SENTINEL: NOW - 86400})
        self._touch_old(self.state)
        self._write_feed(feed_line("111", "a@b.com", [f"track/{UUID}"]))
        rc = rm.main(["--apply"])
        self.assertEqual(rc, 0)
        self.assertEqual(captured, [("resolution-match", "111", "matched")])

    def test_build_state_is_a_lazy_callable_not_a_pre_built_dict(self):
        # Regression for the review-flagged bug class: the shadow state used
        # to be a dict literal built as a bare argument to shadow_judge --
        # evaluated BEFORE its own try/except boundary is ever entered, so
        # any failure while building it (a bad m/fix lookup) would raise
        # straight through the match loop.
        #
        # Unlike the other two Phase-2a call sites (close-duplicate's extra
        # GETs, resolve-notify's conversation-part walk), this call site's
        # `m`/`fix` are ALREADY plain, fully-realized dicts by the time the
        # lambda is built (`m = dict(m, fix=fix)` runs first), and `fix` is
        # unconditionally embedded verbatim in the script's OWN audit trail
        # (shadow_append) regardless of Jev -- so there is no data shape that
        # makes state-building raise in isolation without also breaking the
        # script's own non-shadow logic. The property that actually matters
        # here, and the one the fix (docs/plans/jev-adoption.md #2a review)
        # asked for, is structural: state must be passed as a zero-arg
        # callable, not a pre-built dict, so ANY future failure mode in this
        # construction runs inside shadow_judge's boundary by construction.
        captured = []
        rm.shadow_judge = lambda surface, item_id, state, questions, actual=None: (
            captured.append((surface, item_id, state, actual)) or None)
        rm.write_state(self.state, {rm.SEED_SENTINEL: NOW - 86400})
        self._touch_old(self.state)
        self._write_feed(feed_line("111", "a@b.com", [f"track/{UUID}"]))
        rc = rm.main(["--apply"])
        self.assertEqual(rc, 0)
        self.assertEqual(len(captured), 1)
        surface, item_id, state, actual = captured[0]
        self.assertEqual((surface, item_id, actual), ("resolution-match", "111", "matched"))
        self.assertTrue(callable(state), state)  # NOT a pre-built dict
        self.assertEqual(state(), {
            "customer_report": {"title": "Credits misattribution",
                                 "symptom": "wrong name on credits"},
            "action_log_row": {"route": "/api/v3/admin/profile/x/credits", "method": "PUT",
                                "requester": "aaron@muso.ai", "at": "2026-06-29 10:00:00 UTC",
                                "matched_entity": UUID}})


if __name__ == "__main__":
    unittest.main()
