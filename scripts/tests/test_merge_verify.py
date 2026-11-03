#!/usr/bin/env python3
"""Profile-merge verifier (scripts/merge_verify, scripts/merge-verify.py): the rule order, UNKNOWN
never approves, the industry guards, the exact command, the m1 regression over the frozen 235-ticket
set, and that nothing in the package can merge, write a ticket or message anyone. Stdlib only."""
from __future__ import annotations

import ast
import gzip
import importlib.util
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from merge_verify import collect, eval_log, rules, snapshot, store  # noqa: E402

_spec = importlib.util.spec_from_file_location("merge_verify_cli", ROOT / "scripts" / "merge-verify.py")
cli = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cli)  # type: ignore[union-attr]

K = "11111111-1111-4111-8111-111111111111"
L = "22222222-2222-4222-8222-222222222222"
L2 = "33333333-3333-4333-8333-333333333333"
TEAM = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
TEAM2 = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"


def prof(**kw):
    p = {"found": True, "type": "artist", "sub_type": "artist", "credits": 40, "popularity": 30,
         "spotify": ["sp1"], "tidal": ["td1"]}
    p.update(kw)
    return p


def facts(**kw):
    f = {
        "ticket": "t1", "tags": ["action:profile-merge"], "conv": "215400000000001", "keep": K, "dups": [L],
        "profiles": {K: prof(credits=50), L: prof(credits=10)},
        "claims": {K: [{"status": "processed", "user_id": "7", "team_id": TEAM, "flagged": False}],
                   L: [{"status": "processed", "user_id": "7", "team_id": TEAM, "flagged": False}]},
        "identity": [], "merges": [], "watchlist": {"profile_ids": [], "requester_hit": False},
        "paid": {K: [], L: []},
        "threads": [{"conv": "215400000000001", "bound": True, "named_ids": [K, L]}],
        "pairs": {L: {"name_relation": "identical", "same_name_others": False}},
    }
    f.update(kw)
    return f


class Rule(unittest.TestCase):
    def test_eligible_with_exact_command_and_self_serve(self):
        v = rules.decide(facts(), fresh=True)
        self.assertEqual((v.verdict, v.eval), ("eligible", "APPROVE"))
        lv = v.losers[0]
        self.assertEqual(lv.command, f"muso --env prod profiles merge --into {K} --from {L} --requester caroline@muso.ai "
                                     f"--yes --confirmed-by <captain handle> --approval-ref '215400000000001|mv-1'")
        self.assertEqual(lv.self_serve["path"], "/api/v4/user/profiles/merge")
        self.assertEqual(lv.self_serve["body"], {"mainProfileId": K, "mergeProfileIds": [L]})
        self.assertIn("shared_dsp_identity spotify:sp1,tidal:td1", lv.basis)
        self.assertTrue(v.fresh_read)

    def test_snapshot_eligible_is_marked_measurement_only(self):
        v = rules.decide(facts(), fresh=False)
        self.assertFalse(v.fresh_read)
        self.assertTrue(any("measurement only" in r for r in v.losers[0].reasons))

    def test_unread_sections_are_unknown_never_approve(self):
        for section in ("profiles", "merges", "watchlist", "claims", "identity"):
            v = rules.decide(facts(**{section: None}), fresh=True)
            self.assertEqual((v.verdict, v.eval), ("unknown", "UNKNOWN"), section)
        for section, why in (("paid", "unread:paid_seats"), ("threads", "unread:requester_threads")):
            v = rules.decide(facts(**{section: None}), fresh=True)
            self.assertEqual(v.losers[0].verdict, "unknown", section)
            self.assertIn(why, v.losers[0].reasons)
        f = facts()
        f["profiles"][L] = {"found": None}
        self.assertEqual(rules.decide(f, fresh=True).verdict, "unknown")
        f = facts(pairs={L: {"same_name_others": None}})
        self.assertEqual(rules.decide(f, fresh=True).losers[0].reasons, ["unread:same_name_census"])
        f = facts()
        f["profiles"][K]["popularity"] = None
        self.assertEqual(rules.decide(f, fresh=True).verdict, "unknown")

    def test_ids(self):
        self.assertEqual(rules.decide(facts(keep=None)).verdict, "needs_ids")
        self.assertEqual(rules.decide(facts(dups=[])).verdict, "needs_ids")
        f = facts()
        f["profiles"][L] = {"found": False}
        self.assertEqual(rules.decide(f).verdict, "needs_ids")

    def test_already_merged_follows_verified_chain_only(self):
        f = facts(merges=[{"loser": L, "survivor": L2, "status": "verified"},
                          {"loser": L2, "survivor": K, "status": "verified"}])
        v = rules.decide(f)
        self.assertEqual((v.verdict, v.m1_state), ("already_merged", "merged-not-told"))
        f["tags"].append("merge-outcome-notified")
        self.assertEqual(rules.decide(f).m1_state, "merged-told")
        f = facts(merges=[{"loser": L, "survivor": K, "status": "callback_received"}])
        v = rules.decide(f, fresh=True)
        self.assertEqual(v.losers[0].verdict, "wait:merge_in_flight")

    def test_watchlist_org_claim_contested_login_order(self):
        self.assertEqual(rules.decide(facts(watchlist={"profile_ids": [L], "requester_hit": False})).verdict, "held_watchlist")
        self.assertEqual(rules.decide(facts(watchlist={"profile_ids": [], "requester_hit": True})).verdict, "held_watchlist")
        f = facts()
        f["profiles"][L]["sub_type"] = "organization"
        f["watchlist"] = {"profile_ids": [L], "requester_hit": False}
        self.assertEqual(rules.decide(f).verdict, "held_watchlist")  # watchlist first
        f["watchlist"] = {"profile_ids": [], "requester_hit": False}
        self.assertEqual(rules.decide(f).verdict, "refused:ORG_PROFILE")
        f = facts()
        f["claims"][L] = [{"status": "pending", "user_id": "7", "team_id": TEAM}]
        v = rules.decide(f)
        self.assertEqual((v.verdict, v.m1_state), ("needs_claim", "needs-claim-first"))
        self.assertIn("pending 22222222", v.reasons[0])
        f = facts()
        f["claims"][L] = [{"status": "processed", "user_id": "8", "team_id": TEAM2}]
        self.assertEqual(rules.decide(f).verdict, "refused:OPEN_CLAIM")
        f = facts()
        f["claims"][L].append({"status": "pending", "user_id": "9", "team_id": TEAM2})
        self.assertEqual(rules.decide(f).verdict, "refused:OPEN_CLAIM")
        f = facts(identity=[{"profile_id": L, "user_id": "8", "kind": "primary"}])
        self.assertEqual(rules.decide(f).verdict, "refused:LOGIN_OR_PRIMARY_LOSER")

    def test_login_loser_exempt_when_keep_is_the_same_accounts(self):
        f = facts(identity=[{"profile_id": L, "user_id": "7", "kind": "login"},
                            {"profile_id": K, "user_id": "7", "kind": "primary"}])
        self.assertEqual(rules.decide(f, fresh=True).verdict, "eligible")

    def test_empty_login_shell_type_mismatch_paid_seat(self):
        f = facts(identity=[{"profile_id": K, "user_id": "7", "kind": "login"}])
        f["profiles"][K]["credits"] = 0
        self.assertEqual(rules.decide(f).losers[0].verdict, "refused:EMPTY_SHELL_MAIN")
        f = facts()
        f["profiles"][L]["type"] = "professional"
        self.assertEqual(rules.decide(f).verdict, "refused:TYPE_MISMATCH")
        f = facts(paid={K: [], L: [TEAM2]})
        self.assertEqual(rules.decide(f).verdict, "refused:PAID_SEAT")
        f = facts(paid={K: [], L: [TEAM]})
        self.assertEqual(rules.decide(f, fresh=True).verdict, "eligible")

    def test_owner_thread_must_be_bound_and_name_both(self):
        for th in ([{"conv": "1", "bound": False, "named_ids": [K, L]}],
                   [{"conv": "1", "bound": True, "named_ids": [K]}], []):
            self.assertEqual(rules.decide(facts(threads=th)).losers[0].verdict, "wait:owner_thread")

    def test_big_common_flagged_direction_guard(self):
        f = facts()
        f["profiles"][L]["popularity"] = 61
        self.assertEqual(rules.decide(f).losers[0].verdict, "needs_human:big_profile")
        f = facts()
        f["profiles"][L]["credits"] = 99
        self.assertEqual(rules.decide(f).losers[0].verdict, "needs_human:direction")
        f = facts(pairs={L: {"same_name_others": True}})
        self.assertEqual(rules.decide(f).losers[0].verdict, "needs_human:common_name")
        f = facts()
        f["claims"][K][0]["flagged"] = True
        self.assertEqual(rules.decide(f).losers[0].verdict, "needs_human:flagged_claim")
        f = facts()
        f["claims"][K][0]["flagged"] = None
        v = rules.decide(f, fresh=True)
        self.assertEqual(v.verdict, "eligible")
        self.assertTrue(any("screening flags are not on the replica" in r for r in v.losers[0].reasons))

    def test_same_person_needs_a_spotify_or_tidal_identity_on_both(self):
        f = facts()
        f["profiles"][L].update(spotify=["other"], tidal=[])
        v = rules.decide(f, fresh=True)
        self.assertEqual((v.losers[0].verdict, v.eval), ("needs_evidence:same_person", "WAIT"))
        self.assertIsNone(v.losers[0].command)
        f["profiles"][L]["tidal"] = ["td1"]
        self.assertEqual(rules.decide(f, fresh=True).verdict, "eligible")

    def test_partial_and_ticket_level(self):
        f = facts(dups=[L, L2])
        f["profiles"][L2] = prof(spotify=["x"], tidal=["y"], credits=5)
        f["claims"][L2] = [{"status": "processed", "user_id": "7", "team_id": TEAM, "flagged": False}]
        f["paid"][L2] = []
        f["threads"][0]["named_ids"].append(L2)
        f["pairs"][L2] = {"same_name_others": False}
        v = rules.decide(f, fresh=True)
        self.assertEqual((v.verdict, v.eval), ("partial", "WAIT"))
        self.assertEqual([x.command is not None for x in v.losers], [True, False])

    def test_command_refuses_non_uuid(self):
        with self.assertRaises(ValueError):
            rules.command_for("abc", L, "1")

    def test_name_relation_port(self):
        self.assertEqual(rules.name_relation("Beyoncé", "beyonce"), "fold_equal")
        self.assertEqual(rules.name_relation("Jay Dee", "J Dee"), "shared_token")
        self.assertEqual(rules.name_relation("Mangueman", "Manguemann"), "near")
        self.assertEqual(rules.name_relation("Liz Mueller", "Liz"), "token_subset")


class Regression(unittest.TestCase):
    """The frozen m1 re-read (235 open tickets, 2026-10-27/28): the verifier reproduces m1's state on
    every ticket except the listed ones, each stricter or core's own rule."""

    EXPECTED_DISAGREEMENTS = {
        # core's merge route exempts a login/primary loser when the keep is that same account's
        # own login/primary (findLoginOrPrimaryLosers); m1's own 10-28 ~08:00Z correction moves the
        # same 9 tickets D2 -> executable-L7 (merge-states-1028.md "D2 was over-counted")
        "1amvh554z8z", "1amvh554wk6", "1amvh554wb3", "869dr76yx", "869dr3ttn", "869dn3x52",
        # ...and three of those then fold a populated duplicate into an empty login shell (core EMPTY_SHELL_MAIN)
        "1amvh554wjt", "1amvh554whf", "869dp84nn",
        # the requester's account is on the fraud watchlist (m1 matched profile ids only): stricter
        "869de0rj9",
    }

    def test_frozen_set_matches_m1(self):
        rows = snapshot.load_set()
        self.assertEqual(len(rows), 235)
        dis = {r["ticket"] for r in rows if rules.decide(r).m1_state != r["m1_state"]}
        self.assertEqual(dis, self.EXPECTED_DISAGREEMENTS)

    def test_snapshot_never_approves_without_paid_read(self):
        for r in snapshot.load_set():
            self.assertNotEqual(rules.decide(r).eval, "APPROVE", r["ticket"])

    def test_frozen_set_carries_no_names_or_emails(self):
        with gzip.open(snapshot.SET_PATH, "rt") as f:
            text = f.read()
        self.assertNotIn('"names"', text)
        self.assertNotRegex(text, r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}")

    def test_m1_states_parser(self):
        md = "## Every ticket\n| ticket | state | age d |\n|---|---|---|\n| 869dd731b | executable-L7 | 159.4 | - |\n"
        self.assertEqual(snapshot.m1_states(md), {"869dd731b": "executable-L7"})


class ReadOnly(unittest.TestCase):
    FILES = [ROOT / "scripts" / "merge-verify.py", *sorted((ROOT / "scripts" / "merge_verify").glob("*.py"))]

    def test_no_executor_reachable(self):
        for path in self.FILES:
            tree = ast.parse(path.read_text())
            docs = {id(n.body[0].value) for n in ast.walk(tree)
                    if isinstance(n, (ast.Module, ast.FunctionDef, ast.ClassDef)) and n.body
                    and isinstance(n.body[0], ast.Expr) and isinstance(n.body[0].value, ast.Constant)}
            for node in ast.walk(tree):
                if isinstance(node, (ast.Import, ast.ImportFrom)):
                    names = [a.name for a in node.names] + [getattr(node, "module", "") or ""]
                    self.assertFalse(any(n.split(".")[0] in ("subprocess", "requests", "http") for n in names),
                                     f"{path.name} imports {names}")
                if isinstance(node, ast.Constant) and isinstance(node.value, str) and id(node) not in docs:
                    s = node.value
                    for bad in ("/admin/profiles/merge", "/unmerge", "/decide", "merge-outcome:", "/tag/",
                                "/conversations/reply", "/reply", "PUT", "DELETE", "PATCH"):
                        self.assertNotIn(bad, s, f"{path.name}: {s[:120]!r}")

    def test_http_methods_are_get_or_intercom_search(self):
        calls = []

        def http(method, url, headers, body=None):
            calls.append((method, url))
            if "contacts/search" in url:
                return {"data": [{"id": "c1"}]}
            if "conversations/search" in url:
                return {"conversations": [{"id": "99"}]}
            return {"source": {"author": {"type": "user", "id": "c1"}, "body": f"merge {L} into {K}"},
                    "conversation_parts": {"conversation_parts": []}, "contacts": {"contacts": [{"id": "c1"}]}}

        ic = collect.Intercom("tok", http=http, pace=0)
        th = collect.requester_threads("a@b.example", ic)
        self.assertEqual([(t["conv"], t["bound"], t["named_ids"]) for t in th], [("99", True, sorted([K, L]))])
        self.assertEqual({m for m, _ in calls}, {"GET", "POST"})
        self.assertTrue(all(m == "GET" or u.endswith(("/contacts/search", "/conversations/search")) for m, u in calls))
        for m, p in (("POST", "/conversations/99/reply"), ("PUT", "/conversations/99"), ("GET", "/contacts/c1")):
            with self.assertRaises(collect.ReadOnlyViolation):
                ic.call(m, p, {})

    def test_a_lead_with_the_same_email_is_ignored_and_two_users_unbind(self):
        def mk(contacts):
            def http(method, url, headers, body=None):
                if "contacts/search" in url:
                    return {"data": contacts}
                if "conversations/search" in url:
                    return {"conversations": [{"id": "99"}]}
                return {"source": {"author": {"type": "user", "id": "u1"}, "body": f"{K} {L}"},
                        "conversation_parts": {"conversation_parts": []}, "contacts": {"contacts": [{"id": "u1"}]}}
            return collect.Intercom("t", http=http, pace=0)
        th = collect.requester_threads("a@b.example", mk([{"id": "u1", "role": "user"}, {"id": "l1", "role": "lead"}]))
        self.assertEqual([t["bound"] for t in th], [True])
        th = collect.requester_threads("a@b.example", mk([{"id": "u1", "role": "user"}, {"id": "u2", "role": "user"}]))
        self.assertFalse(any(t["bound"] for t in th))
        self.assertEqual(collect.requester_threads("a@b.example", mk([{"id": "l1", "role": "lead"}])), [])

    def test_admin_part_bound_by_another_contact_is_not_the_requesters(self):
        def http(method, url, headers, body=None):
            if "contacts/search" in url:
                return {"data": [{"id": "c1"}]}
            if "conversations/search" in url:
                return {"conversations": [{"id": "99"}]}
            return {"source": {"author": {"type": "admin", "id": "a1"}, "body": f"{K} {L}"},
                    "conversation_parts": {"conversation_parts": []}, "contacts": {"contacts": [{"id": "c1"}, {"id": "c2"}]}}
        th = collect.requester_threads("a@b.example", collect.Intercom("t", http=http, pace=0))
        self.assertEqual((th[0]["bound"], th[0]["named_ids"]), (False, []))

    def test_parse_ticket(self):
        ar = {"intercom_conversation_id": "215400000000009",
              "details": {"merge_intake": {"keep": f"https://muso.ai/profile/{K}", "others": [L.upper()]}}}
        t = collect.parse_ticket({"id": "x1", "status": {"status": "to do"}, "tags": [{"name": "action:profile-merge"}],
                                  "date_created": "5", "description": "---ACTION-REQUEST---\n" + json.dumps(ar)
                                  + "\n---END-ACTION-REQUEST---\ncustomer_email: \"a@b.example\""})
        self.assertEqual((t["keep"], t["dups"], t["conv"]), (K, [L], "215400000000009"))

    def test_open_tickets_exclude_done_type_statuses(self):
        class CU:
            def get(self, path):
                return {"last_page": True, "tasks": [
                    {"id": "a", "status": {"status": "to do", "type": "open"}},
                    {"id": "b", "status": {"status": "complete", "type": "done"}},
                    {"id": "c", "status": {"status": "in progress", "type": "custom"}},
                    {"id": "d", "status": {"status": "closed", "type": "closed"}}]}
        self.assertEqual([t["ticket"] for t in collect.open_merge_tickets(CU())], ["a", "c"])

    def test_ledger_rows_follow_the_verified_chain(self):
        rows = [{"loser": L, "survivor": L2, "status": "verified"}, {"loser": L2, "survivor": K, "status": "verified"},
                {"loser": "x", "survivor": "y", "status": "verified"}]
        self.assertEqual(collect.ledger_rows(rows, [K, L]), rows[:2])

    def test_catalog_chunk_retry_isolates_one_bad_read(self):
        ids = [f"{i:08x}-0000-4000-8000-000000000000" for i in range(20)]

        class Admin:
            def get(self, path):
                if ids[3] in path:
                    raise RuntimeError("bad")
                return {"items": [{"id": i, "type": "artist"} for i in ids if i in path]}
        got = collect.catalog_facts(ids, Admin())
        self.assertEqual(sum(1 for v in got.values() if v["found"] is None), 10)
        self.assertEqual(sum(1 for v in got.values() if v["found"]), 10)

    def test_census_walks_every_page_so_a_page_two_conflict_is_found(self):
        # 60 other profiles, then the exact-name claimed one at result 61: page 1 alone would answer
        # "nobody else" and let `eligible` skip needs_human:common_name (QA finding 2026-10-28).
        others = [{"id": f"{i:08x}-0000-4000-8000-000000000000", "name": f"Other {i}"} for i in range(60)]
        hit = {"id": L2, "name": "Same Name", "isClaimed": True, "creditCount": 0}
        pages = {1: others[:50], 2: others[50:] + [hit]}

        class Admin:
            def __init__(self):
                self.pages = []
            def get(self, path):
                page = int(path.rsplit("page=", 1)[1])
                self.pages.append(page)
                if page not in pages:
                    return {"items": []}
                return {"items": pages[page]}

        a = Admin()
        self.assertIs(collect.same_name_others("Same Name", {K, L}, a), True)
        self.assertEqual(a.pages, [1, 2])

    def test_census_is_unknown_when_it_cannot_be_exhausted(self):
        full = [{"id": f"{i:08x}-0000-4000-8000-000000000000", "name": f"Other {i}"} for i in range(50)]

        class Full:
            def get(self, path):
                return {"items": full}

        class Boom:
            def __init__(self):
                self.n = 0
            def get(self, path):
                self.n += 1
                if self.n == 2:
                    raise RuntimeError("page 2 down")
                return {"items": full}

        class Silent:
            def get(self, path):
                return {"result": "ok", "code": 200}

        class Short:
            def get(self, path):
                return {"items": full[:3]}

        self.assertIsNone(collect.same_name_others("Same Name", {K}, Full()))
        self.assertIsNone(collect.same_name_others("Same Name", {K}, Boom()))
        self.assertIsNone(collect.same_name_others("Same Name", {K}, Silent()))
        self.assertIs(collect.same_name_others("Same Name", {K}, Short()), False)
        self.assertIsNone(collect.same_name_others("   ", {K}, Short()))

    def test_catalog_read_failure_is_unknown(self):
        class Boom:
            def get(self, path):
                raise RuntimeError("down")
        self.assertEqual(collect.catalog_facts([K], Boom()), {K: {"found": None}})

    def test_replica_queries_are_selects(self):
        seen = []
        collect.replica_facts([K], lambda sql: seen.append(sql) or [])
        self.assertTrue(seen and all(s.lstrip().upper().startswith("SELECT") for s in seen))
        with self.assertRaises(AssertionError):
            self.assertIn("'; drop", collect._q(["x'; drop table users; --"]))


class Plumbing(unittest.TestCase):
    def test_store_audit_rows(self):
        with tempfile.TemporaryDirectory() as d:
            st = store.Store(os.path.join(d, "s.sqlite"))
            f = facts()
            n = st.record("r1", "test", 0.0, [(f, rules.decide(f, fresh=True)), (facts(keep=None), rules.decide(facts(keep=None)))], {})
            self.assertEqual(n, 2)
            rows = st.latest()
            self.assertEqual([r["verdict"] for r in rows], ["eligible", "needs_ids"])
            self.assertEqual(rows[0]["facts_sha256"], store.facts_sha(f))
            self.assertIn("profiles merge", rows[0]["command"])
            self.assertEqual(oct(os.stat(os.path.join(d, "s.sqlite")).st_mode & 0o777), "0o600")
            st.db.close()

    def test_eval_log_rows(self):
        judged = [(facts(), rules.decide(facts(), fresh=True)),
                  (facts(ticket="t2", identity=[{"profile_id": L, "user_id": "8", "kind": "login"}]), None)]
        judged[1] = (judged[1][0], rules.decide(judged[1][0]))
        rs = eval_log.rows(judged)
        self.assertEqual([(r["id"], r["verdict"]) for r in rs],
                         [("t1", "eligible"), ("t1:22222222", "eligible"),
                          ("t2", "refused:LOGIN_OR_PRIMARY_LOSER"), ("t2:22222222", "refused:LOGIN_OR_PRIMARY_LOSER")])
        self.assertEqual(eval_log._v("wait:owner_thread"), "queued_review")
        self.assertEqual(eval_log._v("unknown"), "UNKNOWN")

    def test_kill_switch_reads_nothing(self):
        with tempfile.NamedTemporaryFile() as k:
            os.environ["MERGE_VERIFY_DISABLED_FILE"] = k.name
            try:
                out = StringIO()
                with redirect_stdout(out):
                    self.assertEqual(cli.main(["run"]), 0)
                self.assertIn("disabled", out.getvalue())
            finally:
                del os.environ["MERGE_VERIFY_DISABLED_FILE"]

    def test_replay_cli_agreement(self):
        out = StringIO()
        with redirect_stdout(out):
            self.assertEqual(cli.main(["replay", "--agreement"]), 0)
        self.assertIn("agreement with m1 merge-states-1028: 225/235", out.getvalue())


if __name__ == "__main__":
    unittest.main()
