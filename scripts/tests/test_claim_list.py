"""claim_list: the scheduled claim-list build (claim-list-build.timer). Every external read is faked; no network,
no node-8 path. What is pinned: the audience rules of the signed batches, core's proof code (vectors printed by
core's own codeFor), and the property the schedule exists for - a read that does not answer FAILS the run and
leaves the live list byte-for-byte as it was."""
from __future__ import annotations

import credit_test_env  # noqa: F401,E402 - first: test logs never reach the production run.log
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from credit_review import claim_list as cl  # noqa: E402
from credit_review import claim_proof_ask, verify_notify  # noqa: E402
from credit_review import claim_status_list as csl  # noqa: E402

HEAD = "a" * 40
HEAD2 = "b" * 40
SECRET = "test-secret-at-least-16-chars"
P = ["00000000-0000-4000-8000-00000000000%d" % n for n in range(10)]


def now_iso(hours_ago: float = 0.0) -> str:
    return (datetime.now(timezone.utc) - timedelta(hours=hours_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")


def decider_text(lines: list[str], *, in_scope: int | None = None, mode: str = "dry-run", scope: str = "paid first",
                 end: bool = True, written: bool = False) -> str:
    n = len(lines) if in_scope is None else in_scope
    out = ["[ads] kycRequired=false",
           f"claim-review-decider: {n} pending claim(s) in scope ({scope}), mode={mode}, maxApprove=25",
           "info: [Executing] x-getProfile", *lines, "===== CLAIM REVIEW DIGEST BEGIN =====",
           '{"decisions": [{"written": %s}]}' % ("true" if written else "false")]
    if end:
        out.append("===== CLAIM REVIEW DIGEST END =====")
    return "\n".join(out) + "\n"


def dline(cid: int, paid: bool, ptype: str, band: str, action: str) -> str:
    return f"claim {cid} {'PAID' if paid else 'free'} {ptype} pop=12 age=3d: CRS 61 {band} {action}: reasons"


# claim, paid, type, band, action, user, profile
QUEUE = [
    (101, True, "person", "B", "request_proof", 1, P[1]),    # ask (spotify surface)
    (102, True, "person", "A", "hold", 2, P[2]),             # status_hold
    (103, False, "organization", "B", "request_proof", 3, P[3]),   # status_org
    (104, False, "person", "D", "decline", 4, P[4]),         # status_band_d
    (105, False, "person", "C", "request_proof", 5, P[5]),   # no readable surface -> status
    (106, False, "person", "B", "request_proof", 6, P[6]),   # already asked -> counted, not listed
    (107, False, "person", "B", "request_proof", 7, P[7]),   # fraud-held -> never listed
    (108, False, "person", "B", "request_proof", 1, P[8]),   # user 1 again: hold -> status, dropped (owes the code)
]
SURFACES = {P[1]: ["spotify_bio:abc"], P[6]: ["spotify_bio:x"], P[7]: ["well_known:x"], P[8]: []}


def facts(queue=QUEUE) -> csl.Facts:
    f = csl.Facts()
    f.claims = [{"id": c, "user_id": u, "team_id": f"t{u}", "profile_id": p, "profile_type": t,
                 "created_at": f"2026-11-0{1 + i % 9}T00:00:00Z"} for i, (c, _, t, _, _, u, p) in enumerate(queue)]
    f.at_risk_teams = {"t2"}
    return f


def make_ledger(path: Path, rows: list[tuple] = ()) -> None:
    con = sqlite3.connect(path)
    con.execute("create table verify_messages (campaign text, account_id text, request_ids_json text, status text, "
                "reason text, api_log text, sent_at text, created_at text, attempts integer default 0)")
    con.executemany("insert into verify_messages (campaign, account_id, request_ids_json, status, reason, api_log, "
                "sent_at, created_at) values (?,?,?,?,?,?,?,?)", rows)
    con.commit()
    con.close()


class Env:
    """One temp node-8: a live list, a state dir, a ledger, and fakes for every read."""

    def __init__(self, tc: unittest.TestCase):
        self.dir = Path(tempfile.mkdtemp(prefix="claim-list-test-"))
        tc.addCleanup(lambda: __import__("shutil").rmtree(self.dir, ignore_errors=True))
        self.live = self.dir / "outbound" / "claim-list.json"
        self.live.parent.mkdir()
        self.state = self.dir / "state"
        self.kill = self.dir / "claim-list-build.disabled"
        self.ledger = self.dir / "ledger.sqlite3"
        make_ledger(self.ledger, [("claim-proof-ask", "6", '["claim-106"]', "sent", "", "", now_iso(400), now_iso(400))])
        self.heads = [HEAD]
        self.decider_out = decider_text([dline(c, pd, t, b, a) for c, pd, t, b, a, _, _ in QUEUE])
        self.held = {"7"}
        self.daily = {"owner": "claim-proof-check", "last_run_at": now_iso(0.5)}
        self.unreadable_profiles: set[str] = set()
        self.calls: list[str] = []

    def head(self) -> str:
        return self.heads.pop(0) if len(self.heads) > 1 else self.heads[0]

    def _decider(self):
        self.calls.append("decider")
        return self.decider_out, ""

    def reads(self, **over) -> cl.Reads:
        def profile(pid):
            return None if pid in self.unreadable_profiles else {"id": pid, "name": f"Name {pid[-1]}", "subType": "person"}

        base = dict(decider=self._decider, facts=facts, ledger=lambda sql: cl.ledger_rows(sql, self.ledger),
                    holds=lambda: cl.Holds(set(self.held)), profile=profile,
                    bound=lambda pr: SURFACES.get(pr["id"], []), daily_check=lambda: dict(self.daily),
                    secret=lambda: SECRET, head=self.head)
        base.update(over)
        return cl.Reads(**base)

    def run(self, **kw) -> cl.Outcome:
        reads = kw.pop("reads", None) or self.reads()
        return cl.run(reads, live=self.live, state=self.state, kill=self.kill, **kw)


class CodeTests(unittest.TestCase):
    # printed by core's own codeFor (src/services/claiming/claimProofFlow.js) under node 22 with this secret
    VECTORS = [((77, "p-1", "5"), "MUSO-SK2K"),
               ((1621321, "0b1c7c2e-6f0a-4c0e-9a51-2f6f3d1f9b11", "14643"), "MUSO-98G9"),
               ((9, "abc", None), "MUSO-EG6J"),
               ((1604304, "ffffffff-0000-4000-8000-000000000000", "310729"), "MUSO-F2SH")]

    def test_code_matches_cores_own_vectors(self):
        for args, want in self.VECTORS:
            self.assertEqual(cl.code_for(*args, SECRET), want)

    def test_code_shape_is_the_one_the_ask_copy_prints(self):
        self.assertRegex(cl.code_for(1, "p", "2", SECRET), cl.CODE_RE)
        for banned in "01OI":
            self.assertNotIn(banned, cl.CODE_ALPHABET)

    def test_no_secret_no_code(self):
        with self.assertRaises(cl.Unmeasured):
            cl.code_for(1, "p", "2", "")

    def test_a_changed_code_refuses_the_run(self):
        row = {"claim_id": 1, "profile_id": "p", "user_id": 2, "audience": "proof_ask", "code": "MUSO-AAAA"}
        prev = {"claims": [{**row, "code": "MUSO-BBBB"}]}
        with self.assertRaises(cl.Unmeasured) as ctx:
            cl.assert_codes_unchanged(prev, {"claims": [row]})
        self.assertEqual(ctx.exception.code, "code_changed")
        self.assertEqual(cl.assert_codes_unchanged({"claims": [dict(row)]}, {"claims": [row]}), 1)
        self.assertEqual(cl.assert_codes_unchanged(None, {"claims": [row]}), 0)


class DeciderTests(unittest.TestCase):
    L = [dline(1, True, "person", "B", "request_proof"), dline(2, False, "person", "D", "decline")]

    def refused(self, text, code, **kw):
        with self.assertRaises(cl.Unmeasured) as ctx:
            cl.parse_decider(text, **kw)
        self.assertEqual(ctx.exception.code, code)

    def test_a_whole_dry_run_parses(self):
        d = cl.parse_decider(decider_text(self.L))
        self.assertEqual(d.band, {1: ("person", "B", "request_proof"), 2: ("person", "D", "decline")})
        self.assertEqual(d.paid, {1: True, 2: False})

    def test_a_capped_run_is_refused(self):   # 11-04: a --limit 2000 run of a 2,057 queue dropped 57 claims silently
        self.refused(decider_text(self.L), "decider_capped", limit=2)

    def test_a_cut_off_run_is_refused(self):
        self.refused(decider_text(self.L, end=False), "decider_cut_off")
        self.refused(decider_text(self.L, in_scope=3), "decider_incomplete")

    def test_an_applying_run_is_refused(self):
        self.refused(decider_text(self.L, mode="APPLY"), "decider_not_dry_run")
        self.refused(decider_text(self.L, written=True), "decider_wrote")
        with self.assertRaises(cl.Unmeasured):
            cl.run_decider(("node", "x.js", "--apply"))

    def test_a_partial_scope_or_empty_output_is_refused(self):
        self.refused(decider_text(self.L, scope="paid only"), "decider_scope")
        self.refused("", "decider_no_header")
        self.refused(decider_text([]), "decider_empty")

    def test_mostly_unreadable_claims_refuse_and_a_few_do_not(self):
        bad = [f"claim {n} free person: UNREADABLE boom" for n in range(10, 13)]
        self.refused(decider_text(self.L + bad), "decider_unreadable")
        many = [dline(n, False, "person", "D", "decline") for n in range(100, 130)]
        d = cl.parse_decider(decider_text(many + bad[:1]))
        self.assertEqual((d.in_scope, d.unreadable, len(d.band)), (31, 1, 30))

    def test_the_scheduled_command_is_a_dry_run_of_the_whole_queue(self):
        self.assertNotIn("--apply", cl.DECIDER_CMD)
        self.assertNotIn("--paid-only", cl.DECIDER_CMD)
        self.assertIn("--no-judge", cl.DECIDER_CMD)
        self.assertEqual(cl.DECIDER_CMD[cl.DECIDER_CMD.index("--limit") + 1], str(cl.DECIDER_LIMIT))

    def test_a_failing_decider_command_is_unmeasured(self):
        with self.assertRaises(cl.Unmeasured) as ctx:
            cl.run_decider(("false",))
        self.assertEqual(ctx.exception.code, "decider_failed")
        with self.assertRaises(cl.Unmeasured):
            cl.run_decider(("/nonexistent/claim-list-test-binary",))


class ReadTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="claim-list-reads-"))
        self.addCleanup(lambda: __import__("shutil").rmtree(self.dir, ignore_errors=True))

    def code(self, fn, *a, **kw) -> str:
        with self.assertRaises(cl.Unmeasured) as ctx:
            fn(*a, **kw)
        return ctx.exception.code

    def test_holds_missing_or_unparseable_is_never_nobody_held(self):
        p = self.dir / "holds.jsonl"
        self.assertEqual(self.code(cl.read_holds, p), "holds_unreadable")            # missing
        p.write_text('{"user_id": 7}\n{"user_id": 8')
        self.assertEqual(self.code(cl.read_holds, p), "holds_unreadable")            # half-written
        p.write_text('{"user_id": 7}\n\n{"user_id": "8"}\n')
        self.assertEqual(cl.read_holds(p).ids, {"7", "8"})

    def test_a_valid_empty_holds_file_is_healthy(self):
        p = self.dir / "holds.jsonl"
        p.write_text("")
        h = cl.read_holds(p)
        self.assertEqual((h.ids, h.state), (set(), "empty"))

    def test_a_release_row_clears_a_hold_and_a_later_hold_stands(self):
        p = self.dir / "holds.jsonl"
        b = self.dir / "bands.json"
        b.write_text(json.dumps({"users": {}, "failed_chunks_users": []}))
        p.write_text('{"user_id": 7, "kind": "approval_hold", "at": "2026-11-01T00:00:00Z"}\n'
                     '{"user_id": 7, "kind": "release", "at": "2026-11-02T00:00:00Z"}\n'
                     '{"user_id": 8, "kind": "release", "at": "2026-11-01T00:00:00Z"}\n'
                     '{"user_id": 8, "kind": "approval_hold", "at": "2026-11-02T00:00:00Z"}\n')
        self.assertEqual(cl.read_holds(p, b).ids, {"8"})

    def test_a_stale_or_future_holds_file_is_unmeasured(self):
        p = self.dir / "holds.jsonl"
        p.write_text('{"user_id": 7}\n')
        old = time.time() - cl.ACCOUNT_HOLDS_MAX_AGE - 60
        os.utime(p, (old, old))
        self.assertEqual(self.code(cl.read_holds, p), "holds_stale")
        p.write_text("")
        os.utime(p, (old, old))
        self.assertEqual(self.code(cl.read_holds, p), "holds_stale")                # empty but stale is stale
        future = time.time() + 600
        os.utime(p, (future, future))
        self.assertEqual(self.code(cl.read_holds, p), "holds_stale")

    def test_ledger_unreadable_is_never_nobody_asked(self):
        missing = self.dir / "none.sqlite3"
        self.assertEqual(self.code(cl.read_asked, lambda s: cl.ledger_rows(s, missing)), "ledger_unreadable")
        self.assertFalse(missing.exists())                                           # read-only: never created
        empty = self.dir / "empty.sqlite3"
        sqlite3.connect(empty).close()
        self.assertEqual(self.code(cl.read_asked, lambda s: cl.ledger_rows(s, empty)), "ledger_unreadable")
        self.assertEqual(self.code(cl.read_asked, lambda s: [("not json", "sent", 1)]), "ledger_unreadable")

    def test_ledger_reads(self):
        led = self.dir / "l.sqlite3"
        make_ledger(led, [
            ("claim-proof-ask", "6", '["claim-106", "claim-x", "req-1"]', "refused", "", "", None, now_iso(1)),
            ("claim-proof-ask", "13", '["claim-113"]', "deferred", "", "", None, now_iso(1)),
            ("claim-proof-ask", "14", '["claim-114"]', "rejected", "", "", None, now_iso(1)),
            ("claim-proof-ask", "15", '["claim-115"]', "rejected", "", "", None, now_iso(1)),
            ("uvn-status", "9", "[]", "failed", "Intercom: ACTION_FORBIDDEN", "", None, now_iso(1)),
            ("uvn-status", "10", "[]", "sent", "", "", now_iso(24), now_iso(24)),
            ("uvn-status", "11", "[]", "sent", "", "", now_iso(24 * 8), now_iso(24 * 8)),
            ("uvn-status", "12", "[]", "refused", "", "", None, now_iso(1))])
        con = sqlite3.connect(led)
        con.execute("update verify_messages set attempts=3 where account_id='15'")
        con.commit()
        con.close()
        rows = lambda s: cl.ledger_rows(s, led)   # noqa: E731
        self.assertEqual(cl.read_asked(rows), {106, 115})   # deferred / retryable rejected are not asks
        self.assertEqual(cl.read_ask_users({106, 113, 114, 115}, rows), {"6", "13", "14", "15"})
        self.assertEqual(cl.read_ask_users({106}, rows), {"6"})   # a closed claim's ask does not silence a new one
        self.assertEqual(cl.read_forbidden(rows), {"9"})
        self.assertEqual(cl.read_messaged_7d(rows), {"10"})

    def test_daily_check_must_be_named_and_recent(self):
        p = self.dir / "last-run.json"
        self.assertEqual(self.code(cl.read_daily_check, p), "daily_check_unreadable")
        p.write_text(json.dumps({"owner": "", "last_run_at": now_iso(1)}))
        self.assertEqual(self.code(cl.read_daily_check, p), "daily_check_unreadable")
        p.write_text(json.dumps({"owner": "c2", "last_run_at": now_iso(claim_proof_ask.DAILY_CHECK_MAX_AGE_H + 1)}))
        self.assertEqual(self.code(cl.read_daily_check, p), "daily_check_stale")
        p.write_text(json.dumps({"owner": "c2", "last_run_at": now_iso(1), "asked": 347}))
        self.assertEqual(set(cl.read_daily_check(p)), {"owner", "last_run_at"})

    def test_secret_must_be_real(self):
        p = self.dir / "secret"
        self.assertEqual(self.code(cl.read_secret, p), "code_secret_unreadable")
        p.write_text("short\n")
        self.assertEqual(self.code(cl.read_secret, p), "code_secret_unreadable")
        p.write_text(SECRET + "\n")
        self.assertEqual(cl.read_secret(p), SECRET)

    def test_a_catalog_outage_is_a_failed_run_not_a_list(self):
        ids = [f"p{n}" for n in range(100)]
        self.assertEqual(self.code(cl.read_profiles, ids, lambda p: None), "catalog_unreadable")
        out = cl.read_profiles(ids, lambda p: None if p == "p3" else {"id": p})
        self.assertIsNone(out["p3"])
        self.assertEqual(len(out), 100)
        ticks = iter(range(0, 10 ** 9, cl.PROFILE_BUDGET_S))
        self.assertEqual(self.code(cl.read_profiles, ids, lambda p: {"id": p}, clock=lambda: next(ticks)),
                         "catalog_too_slow")


class ClassifyTests(unittest.TestCase):
    def setUp(self):
        self.decider = cl.parse_decider(decider_text([dline(c, pd, t, b, a) for c, pd, t, b, a, _, _ in QUEUE]))
        self.prof = {p: {"id": p, "name": " Name ", "subType": "person"} for p in P}
        self.bound = lambda pr: SURFACES.get(pr["id"], [])

    def go(self, **kw):
        args = dict(asked={106}, held={"7"}, prof=self.prof)
        args.update(kw)
        return cl.classify(self.decider, facts(), args["asked"], args["held"], args["prof"], self.bound)

    def test_the_rule_set_of_the_signed_batches(self):
        rows, counts = self.go()
        by = {r["claim_id"]: r for r in rows}
        self.assertEqual({c: r["audience"] for c, r in by.items()},
                         {101: "proof_ask", 102: "status", 103: "status", 104: "status", 105: "status", 108: "status"})
        self.assertEqual(by[101]["platform"], "spotify")
        self.assertEqual(by[101]["profile_name"], "Name")
        self.assertTrue(by[102]["at_risk"])
        self.assertEqual(by[101]["profile_url"], f"https://credits.muso.ai/profile/{P[1]}")
        self.assertEqual({k: counts[k] for k in ("ask", "status", "status_hold", "status_org", "status_band_d",
                                                 "status_no_readable_surface", "status_already_asked",
                                                 "excluded_fraud_held", "decider_paid", "decider_free")},
                         {"ask": 1, "status": 6, "status_hold": 1, "status_org": 1, "status_band_d": 1,
                          "status_no_readable_surface": 2, "status_already_asked": 1, "excluded_fraud_held": 1,
                          "decider_paid": 2, "decider_free": 6})

    def test_a_held_account_is_never_listed_in_any_audience(self):
        rows, _ = self.go(held={"1", "7"})
        self.assertFalse([r for r in rows if r["user_id"] in (1, 7)])

    def test_an_asked_claim_is_never_asked_again_nor_told_we_are_working(self):
        rows, _ = self.go(asked={101, 106})
        self.assertNotIn(101, {r["claim_id"] for r in rows})

    def test_the_trays_are_never_listed(self):
        tray = sorted(cl.DECLINE_TRAY)[0]
        queue = [(tray, False, "person", "B", "request_proof", 1, P[1]),
                 (sorted(cl.CLASS_A_REVERTED)[0], False, "person", "B", "request_proof", 2, P[2])]
        d = cl.parse_decider(decider_text([dline(c, pd, t, b, a) for c, pd, t, b, a, _, _ in queue]))
        rows, counts = cl.classify(d, facts(queue), set(), set(), self.prof, self.bound)
        self.assertEqual((rows, counts["decline_tray"]), ([], 2))

    def test_a_claim_no_longer_pending_and_an_unreadable_profile(self):
        f = facts(QUEUE[1:])
        prof = dict(self.prof)
        prof[P[5]] = None
        rows, counts = cl.classify(self.decider, f, set(), set(), prof, self.bound)
        self.assertEqual(counts["not_pending_now"], 1)
        self.assertEqual(counts["status_profile_unreadable"], 1)
        self.assertEqual([r for r in rows if r["claim_id"] == 105][0]["profile_name"], "")

    def test_one_audience_over_all_claims_and_the_order(self):
        rows, counts = self.go()
        rows = cl.apply_audience(rows, counts, ask_users={"3"}, forbidden={"4"}, messaged={"5"})
        self.assertEqual([r["claim_id"] for r in rows], [101, 102])           # the ask first; 108 (user 1) dropped
        self.assertEqual(counts["status_user_owes_code_ask"], 1)
        self.assertEqual(counts["status_user_owes_code_ask_elsewhere"], 1)
        self.assertEqual(counts["no_channel_tray"], [104])
        self.assertEqual(counts["dropped_messaged_7d"], 1)


class RunTests(unittest.TestCase):
    def setUp(self):
        self.env = Env(self)

    def test_a_build_signs_on_the_deployed_head_and_installs(self):
        o = self.env.run()
        self.assertEqual((o.result, o.rc, o.signed_on, o.attempts), ("installed", 0, HEAD, 1), cl.render(o))
        doc = json.loads(self.env.live.read_text())
        self.assertEqual(doc["signed_on"], HEAD)
        self.assertEqual(doc["daily_check"], self.env.daily)
        self.assertEqual([(r["claim_id"], r["audience"]) for r in doc["claims"]],
                         [(101, "proof_ask"), (102, "status"), (103, "status"), (104, "status"), (105, "status")])
        self.assertEqual(doc["claims"][0]["code"], cl.code_for(101, P[1], "1", SECRET))
        self.assertTrue(all(not r["code"] for r in doc["claims"][1:]))
        self.assertEqual(o.sha256, cl.sha256_file(self.env.live))
        self.assertEqual((o.rows, o.users, o.proof_ask, o.status, o.prev_sha256), (5, 5, 1, 4, ""))
        self.assertEqual(o.holds, "1")
        self.assertEqual(oct(self.env.live.stat().st_mode & 0o777), "0o600")
        self.assertIn("INSTALLED sha256 " + o.sha256, cl.render(o))

    def test_the_deployed_loader_accepts_what_was_installed(self):
        self.env.run()
        was = verify_notify.LIST_SIGNED_ON
        self.addCleanup(lambda: setattr(verify_notify, "LIST_SIGNED_ON", was))
        claims, why = claim_proof_ask.load_list(str(self.env.live))
        self.assertEqual((len(claims), why), (5, ""))
        self.assertEqual(verify_notify.LIST_SIGNED_ON, HEAD)

    def test_the_build_does_not_leave_the_loaders_binding_behind(self):
        was = verify_notify.LIST_SIGNED_ON
        self.env.run()
        self.assertEqual(verify_notify.LIST_SIGNED_ON, was)

    def test_two_consecutive_builds_both_sign_and_the_first_is_backed_up(self):
        first = self.env.run()
        t1 = datetime.now(timezone.utc) + timedelta(seconds=5)
        second = self.env.run(now=lambda: t1)
        self.assertEqual((first.result, second.result), ("installed", "installed"))
        self.assertEqual(second.prev_sha256, first.sha256)
        self.assertEqual(second.codes_compared, 1)
        baks = list((self.env.state / "prev").iterdir())
        self.assertEqual([cl.sha256_file(b) for b in baks], [first.sha256])
        lines = (self.env.state / "builds.jsonl").read_text().splitlines()
        self.assertEqual([json.loads(x)["result"] for x in lines], ["installed", "installed"])
        self.assertEqual(json.loads((self.env.state / "last-run.json").read_text())["sha256"], second.sha256)

    def test_a_new_deploy_gets_a_list_signed_on_the_new_head(self):
        self.env.run()
        self.env.heads = [HEAD2]
        o = self.env.run(now=lambda: datetime.now(timezone.utc) + timedelta(seconds=5))
        self.assertEqual((o.result, json.loads(self.env.live.read_text())["signed_on"]), ("installed", HEAD2))

    def test_a_deploy_landing_mid_build_is_rebuilt_on_the_new_head(self):
        self.env.heads = [HEAD, HEAD2, HEAD2]          # read at start; changed by the pre-install re-read
        o = self.env.run()
        self.assertEqual((o.result, o.attempts, o.signed_on), ("installed", 2, HEAD2), cl.render(o))
        self.assertEqual(json.loads(self.env.live.read_text())["signed_on"], HEAD2)
        self.assertEqual(self.env.calls, ["decider", "decider"])

    def test_a_head_that_keeps_moving_fails_and_installs_nothing(self):
        flip = iter([HEAD, HEAD2] * 20)
        o = self.env.run(reads=self.env.reads(head=lambda: next(flip)))
        self.assertEqual((o.result, o.reason, o.rc), ("failed", "head_moved", 1))
        self.assertFalse(self.env.live.exists())

    def test_a_valid_empty_holds_file_builds_a_real_list(self):
        self.env.held = set()
        o = self.env.run()
        self.assertEqual((o.result, o.holds), ("installed", "0 (file valid, no account held)"), cl.render(o))
        self.assertIn("holds 0 (file valid, no account held)", cl.render(o))
        self.assertEqual(json.loads((self.env.state / "last-run.json").read_text())["holds"], o.holds)

    def test_dry_run_touches_nothing_live(self):
        self.env.live.write_text("OLD")
        o = self.env.run(dry_run=True)
        self.assertEqual((o.result, o.rc), ("dry_run", 0))
        self.assertEqual(self.env.live.read_text(), "OLD")
        staged = json.loads((Path(o.run_dir) / "claim-list.json").read_text())
        self.assertEqual(staged["signed_on"], HEAD)

    def assert_fails_and_live_untouched(self, reason: str, **reads_over):
        self.env.live.write_text('{"old": true}')
        before = cl.sha256_file(self.env.live)
        o = self.env.run(reads=self.env.reads(**reads_over))
        self.assertEqual((o.result, o.reason, o.rc), ("failed", reason, 1), cl.render(o))
        self.assertEqual(cl.sha256_file(self.env.live), before)
        self.assertFalse((self.env.state / "prev").exists())
        self.assertIn("nothing installed", cl.render(o))
        self.assertEqual(json.loads((self.env.state / "last-run.json").read_text())["reason"], reason)

    def test_every_unmeasured_read_fails_the_run_and_leaves_the_live_list(self):
        def boom(code):
            def f(*a):
                raise cl.Unmeasured(code, "x")
            return f

        def trino_down():
            raise RuntimeError("trino failed: boom")

        cases = {"decider_failed": dict(decider=boom("decider_failed")),
                 "decider_capped": dict(decider=lambda: (decider_text(["x"], in_scope=cl.DECIDER_LIMIT), "")),
                 "facts_unreadable": dict(facts=trino_down),
                 "holds_unreadable": dict(holds=boom("holds_unreadable")),
                 "ledger_unreadable": dict(ledger=boom("ledger_unreadable")),
                 "daily_check_stale": dict(daily_check=boom("daily_check_stale")),
                 "code_secret_unreadable": dict(secret=boom("code_secret_unreadable")),
                 "deployed_head_unreadable": dict(head=boom("deployed_head_unreadable")),
                 "catalog_unreadable": dict(profile=lambda p: None)}
        for reason, over in cases.items():
            with self.subTest(reason=reason):
                self.assert_fails_and_live_untouched(reason, **over)

    def test_no_pending_claim_from_the_replica_is_unmeasured_not_an_empty_list(self):
        self.assert_fails_and_live_untouched("facts_unreadable", facts=lambda: csl.Facts())

    def test_a_list_with_no_rows_is_not_installed(self):
        self.env.held = {str(u) for *_, u, _ in QUEUE}
        self.assert_fails_and_live_untouched("empty_list")

    def test_a_stale_daily_check_is_refused_before_the_decider_runs(self):
        def stale():
            raise cl.Unmeasured("daily_check_stale", "x")
        self.env.run(reads=self.env.reads(daily_check=stale))
        self.assertEqual(self.env.calls, [])

    def test_a_changed_code_is_not_installed(self):
        self.env.run()
        o = self.env.run(reads=self.env.reads(secret=lambda: SECRET + "-rotated"),
                         now=lambda: datetime.now(timezone.utc) + timedelta(seconds=5))
        self.assertEqual((o.result, o.reason), ("failed", "code_changed"))
        self.assertEqual(json.loads(self.env.live.read_text())["claims"][0]["code"], cl.code_for(101, P[1], "1", SECRET))

    def test_a_list_the_loader_refuses_is_not_installed(self):
        orig = cl._utc
        cl._utc = lambda now=None: now_iso(claim_proof_ask.LIST_MAX_AGE_H + 2)
        self.addCleanup(lambda: setattr(cl, "_utc", orig))
        self.assert_fails_and_live_untouched("loader_refused")

    def test_a_bug_is_a_failed_run_too(self):
        def bug():
            raise KeyError("oops")
        self.assert_fails_and_live_untouched("builder_error", holds=bug)

    def test_kill_file_builds_nothing(self):
        self.env.kill.write_text("")
        o = self.env.run()
        self.assertEqual((o.result, o.rc, self.env.calls), ("held", 0, []))
        self.assertFalse(self.env.live.exists())
        self.assertIn("nothing built", cl.render(o))

    def test_a_second_build_at_once_does_nothing(self):
        import fcntl
        self.env.state.mkdir()
        with open(self.env.state / "build.lock", "a") as fh:
            fcntl.flock(fh, fcntl.LOCK_EX)
            o = self.env.run()
        self.assertEqual((o.result, o.rc, self.env.calls), ("busy", 0, []))

    def test_old_runs_and_backups_are_pruned(self):
        t0 = datetime(2026, 11, 12, tzinfo=timezone.utc)
        orig = cl.KEEP_RUNS, cl.KEEP_BACKUPS
        cl.KEEP_RUNS, cl.KEEP_BACKUPS = 2, 2
        self.addCleanup(lambda: (setattr(cl, "KEEP_RUNS", orig[0]), setattr(cl, "KEEP_BACKUPS", orig[1])))
        gen = cl._utc
        for n in range(5):
            cl._utc = lambda now=None: now_iso()
            self.env.daily = {"owner": "c", "last_run_at": now_iso(0.1 * n)}   # a different file each time
            self.assertEqual(self.env.run(now=lambda n=n: t0 + timedelta(hours=n)).result, "installed")
        cl._utc = gen
        self.assertEqual(len(list((self.env.state / "runs").iterdir())), 2)
        self.assertEqual(len(list((self.env.state / "prev").iterdir())), 2)


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="claim-list-install-"))
        self.addCleanup(lambda: __import__("shutil").rmtree(self.dir, ignore_errors=True))
        self.staged, self.live, self.state = self.dir / "staged.json", self.dir / "live.json", self.dir / "state"
        self.staged.write_text('{"new": 1}')

    def test_backup_then_one_rename_and_both_hashes(self):
        self.live.write_text('{"old": 1}')
        old = cl.sha256_file(self.live)
        prev, got = cl.install(self.staged, self.live, self.state, stamp="20261112T000000Z")
        self.assertEqual((prev, got), (old, cl.sha256_file(self.staged)))
        bak = self.state / "prev" / f"20261112T000000Z-claim-list.{old[:12]}.json"
        self.assertEqual(bak.read_text(), '{"old": 1}')
        self.assertEqual(oct(bak.stat().st_mode & 0o777), "0o600")
        self.assertEqual([p.name for p in self.dir.iterdir() if p.name.startswith(".claim-list.new")], [])

    def test_a_failed_copy_leaves_the_live_list(self):
        self.live.write_text('{"old": 1}')
        orig = cl.os.replace

        def no_replace(a, b):
            raise OSError("disk")
        cl.os.replace = no_replace
        self.addCleanup(lambda: setattr(cl.os, "replace", orig))
        with self.assertRaises(OSError):
            cl.install(self.staged, self.live, self.state, stamp="s")
        self.assertEqual(self.live.read_text(), '{"old": 1}')
        self.assertEqual([p.name for p in self.dir.iterdir() if p.name.startswith(".claim-list.new")], [])


class CheckRowsTests(unittest.TestCase):
    def doc(self, **over):
        r = {k: "" for k in cl.ROW_KEYS}
        r.update(claim_id=1, user_id=2, profile_id="p", paid=True, band="B", code="MUSO-AB2C", platform="spotify",
                 code_found=False, at_risk=False, audience="proof_ask")
        r.update(over)
        return {"signed_on": HEAD, "claims": [r]}

    def bad(self, doc, code="bad_row", head=HEAD):
        with self.assertRaises(cl.Unmeasured) as ctx:
            cl.check_rows(doc, head)
        self.assertEqual(ctx.exception.code, code)

    def test_shapes(self):
        cl.check_rows(self.doc(), HEAD)
        cl.check_rows(self.doc(audience="status", code="", platform=""), HEAD)
        self.bad(self.doc(code=""))                              # an ask with no code
        self.bad(self.doc(code="MUSO-AB1C"))                     # a character core never prints
        self.bad(self.doc(platform="instagram"))                 # not a surface the check can read
        self.bad(self.doc(audience="status"))                    # a status row carrying a code
        self.bad(self.doc(audience="other"))
        self.bad(self.doc(user_id="2"))
        self.bad({"signed_on": HEAD, "claims": []}, "empty_list")
        self.bad(self.doc(), "not_signed", head=HEAD2)
        self.bad({**self.doc(), "signed_on": "abc"}, "not_signed", head="abc")
        two = self.doc()
        two["claims"].append(dict(two["claims"][0]))
        self.bad(two)                                            # the same claim twice


class CliTests(unittest.TestCase):
    def test_help_runs_as_a_file_the_way_the_unit_runs_it(self):
        p = subprocess.run([sys.executable, str(ROOT / "scripts" / "claim-list-build.py"), "--help"],
                           capture_output=True, text=True, check=False)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("--dry-run", p.stdout)

    def test_production_paths_are_constants_not_environment(self):
        self.assertEqual(str(cl.LIVE_LIST), "/var/lib/hydra/credit-verify-outbound/claim-list.json")
        self.assertFalse(str(cl.STATE_DIR).startswith("/opt/hydra"))


if __name__ == "__main__":
    unittest.main()
