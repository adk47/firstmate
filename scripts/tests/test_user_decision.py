"""User-level decision, row-level effect (scripts/credit_review/user_decision.py).

What these tests pin, in the order the change has to earn it:

  * EQUIVALENCE FIRST. The per-user answer equals the per-row answer row for row, on generated rows
    that include every shape the validator writes and shapes it should never write. The check itself
    CAN FAIL: a pass that forgets one fact a rule reads is caught, with the row named.
  * The per-row answer is the DECIDER'S answer, not this module's opinion of it: every stored-fact rule
    is run through the real ``decide.run`` and its ledger row is compared.
  * A row the pass cannot read is never covered by a batched verdict: it is walked on its own, counted,
    and still answered exactly as the per-row path answers it.
  * The unit: one read of the user-scope fact per person, one walk per group of like rows, a separate
    answer for every row. Nothing here approves.
"""
from __future__ import annotations

import credit_test_env  # noqa: F401,E402 - first: test logs never reach the production run.log
import base64
import importlib.util
import io
import json
import math
import os
import random
import re
import socket
import stat
import subprocess
import sys
import tempfile
import unittest
import warnings
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

import test_credit_trust_decide as D  # noqa: E402  (Base harness: the real decide.run on a fake admin)
from credit_review import decide  # noqa: E402
from credit_review import user_decision as ud  # noqa: E402
from credit_review.policy import validator_conflict, validator_rejected_rules  # noqa: E402

DENIED_USER = 666
DENIED_PROFILE = "dddddddd-0000-4000-8000-00000000dead"
POLICY = decide.Policy(deny_user_ids={DENIED_USER}, deny_profile_ids={DENIED_PROFILE},
                       editorial_role_terms=D.TERMS, approve_arm=True)


def row(rid, uid=500, *, rules=None, errors=None, pid="pppppppp-0000-4000-8000-000000000001", track="trk-1",
        codes=None, vd="object"):
    v = {"rule_risk_percent": dict(rules or {})} if vd == "object" else vd
    if vd == "object" and errors is not None:
        v["rule_errors"] = errors
    if vd == "object" and codes is not None:
        v["hold_reason_codes"] = codes
    return {"id": str(rid), "userId": uid, "profileId": pid, "trackId": track, "status": "unverified",
            "verificationData": v}


class CountingSet(set):
    """A deny list that counts how often it is asked."""
    asked = 0

    def __contains__(self, item):
        self.asked += 1
        return super().__contains__(item)


class Ladder(unittest.TestCase):
    def test_each_stored_fact_rule_answers_with_the_decider_wording_in_the_decider_order(self):
        cases = [
            (row(1, rules={"reject_artist_credit": 100, "review_x": 100}), ud.REJECT_RULE, "hold",
             "validator reject rule fired (reject_artist_credit): never approved or asked by automation; human review"),
            (row(2, uid=DENIED_USER, rules={"review_x": 100}), ud.DENY_USER, "support",
             "user on the fraud / PULL / HOLD / RE-VERIFY list"),
            (row(3, pid=DENIED_PROFILE.upper(), rules={"review_x": 100}), ud.DENY_PROFILE, "support",
             "profile on the fleet-scan / stillfloo deny list"),
            (row(4, track=None, rules={"review_x": 100}), ud.NO_TRACK, "defer",
             "track not ingested yet (no trackId): decided once the catalog has it"),
            (row(5, rules={"review_b": 30, "review_a": 99, "review_low": 29}, errors={"_hold_on_error": "x"}),
             ud.CONFLICT, "support",
             "validator conflict (the server refuses agent approvals of these): review_a,review_b,hold_on_error"),
            (row(6, rules={"track_credit": 70, "collaborations": 90}), ud.CONFLICT, "support",
             "validator conflict (the server refuses agent approvals of these): class_c"),
            (row(7, rules={"review_x": 29, "approve_owning_track": 0}), ud.PER_ROW, "", ud.PER_ROW_REASON),
        ]
        for r, rule, decision, reason in cases:
            for a in (ud.row_answer(r, POLICY), ud.decide_users([r], POLICY).answers[0]):
                self.assertEqual((a.rule, a.decision, a.reason), (rule, decision, reason), r["id"])

    def test_a_reject_rule_outranks_a_denied_user_and_names_no_live_read(self):
        a = ud.row_answer(row(1, uid=DENIED_USER, rules={"reject_x": 1}), POLICY)
        self.assertEqual((a.rule, a.live), (ud.REJECT_RULE, ud.LIVE_NONE))
        self.assertEqual(ud.row_answer(row(2, uid=DENIED_USER), POLICY).live, ud.LIVE_EVIDENCE)
        self.assertEqual(ud.row_answer(row(3, rules={"review_x": 30}), POLICY).live, ud.LIVE_TRACK)

    def test_nothing_in_this_module_can_approve(self):
        rows = generated(7, 600)
        seen = {a.decision for a in ud.decide_users(rows, POLICY).answers} | {a.decision for a in ud.decide_rows(rows, POLICY)}
        self.assertLessEqual(seen, {"hold", "support", "defer", ""})
        self.assertIn("", seen)

    def test_the_inventory_names_every_rule_the_walk_can_return_and_keeps_every_approval_per_row(self):
        units = {r.name: r.unit for r in ud.RULES}
        for name in (ud.REJECT_RULE, ud.DENY_USER, ud.DENY_PROFILE, ud.NO_TRACK, ud.CONFLICT):
            self.assertEqual(units[name], "user")
        for name in ("trusted_confirmation", "footprint", "web_check", "paid_provisional", "per_role_split",
                     "big_track", "document_contradiction"):
            self.assertEqual(units[name], "row")
        self.assertTrue(all(r.why for r in ud.RULES))


class PinnedToTheDecider(D.Base):
    """row_answer is only "today's answer" if the real decider writes the same thing. It does."""
    RAWS = {"small": [D.T.raw("Real Engineer", "mixer")]}

    def test_the_decider_ledger_row_of_every_stored_fact_rule_is_the_row_answer(self):
        policy = decide.Policy(deny_user_ids={DENIED_USER}, deny_profile_ids={D.T.PID_BAD.lower()},
                               editorial_role_terms=D.TERMS, approve_arm=True)
        rows = [D.req(D.uuid_of(1), vd_rules={"reject_artist_credit": 100}),
                D.req(D.uuid_of(2), uid=DENIED_USER),
                D.req(D.uuid_of(3), uid=501, pid=D.T.PID_BAD),
                D.req(D.uuid_of(4), uid=502, vd_rules={"review_big_track_without_trusted_credit": 100}),
                D.req(D.uuid_of(5), uid=503, vd_rules={"track_credit": 80, "collaborations": 95})]
        no_track = D.req(D.uuid_of(6), uid=504)
        no_track["trackId"] = None
        rows.append(no_track)
        expect = {r["id"]: ud.row_answer(r, policy) for r in rows}
        self.assertEqual([a.rule for a in expect.values()],
                         [ud.REJECT_RULE, ud.DENY_USER, ud.DENY_PROFILE, ud.CONFLICT, ud.CONFLICT, ud.NO_TRACK])
        self.go(rows, self.RAWS, judge=D.FakeJudge(D.credible()), mode="shadow", policy=policy)
        got = self.decisions()
        for rid, a in expect.items():
            self.assertEqual((got[rid]["decision"], got[rid]["reason"]), (a.decision, a.reason), a.rule)

    def test_a_person_with_many_reject_rows_gets_one_ledger_row_per_request_and_no_catalog_read(self):
        rows = [D.req(D.uuid_of(20 + n), uid=700, vd_rules={"reject_publisher_label_credit": 100}) for n in range(5)]
        admin_paths = []
        real = D.T.FakeAdmin.get

        def get(self, path, params=None):
            admin_paths.append(path)
            return real(self, path, params)

        with mock.patch.object(D.T.FakeAdmin, "get", get):
            res, w = self.go(rows, self.RAWS, judge=D.FakeJudge(D.credible()))
        got = self.decisions()
        self.assertEqual(sorted(got), sorted(r["id"] for r in rows))
        self.assertEqual({(d["decision"], d["user_id"]) for d in got.values()}, {("hold", 700)})
        self.assertEqual({d["reason"] for d in got.values()},
                         {ud.reject_hold_reason(["reject_publisher_label_credit"])})
        self.assertEqual(w.calls, [])
        self.assertFalse([p for p in admin_paths if p.startswith(("/admin/track/", "/admin/profile/"))])

    def test_a_reject_score_the_validator_never_writes_is_read_by_the_per_row_path_as_before(self):
        # A string score is not a score to validator_rejected_rules, so today this row is NOT held by the
        # reject rule. The user-level pass must not "repair" it into one: it falls back, and the decider
        # goes on to build evidence for it exactly as it did.
        odd = D.req(D.uuid_of(40), uid=710, vd_rules={"reject_artist_credit": "100"})
        self.assertIsNone(ud.row_view(odd, D.POLICY))
        self.assertEqual(validator_rejected_rules(odd["verificationData"]), [])
        self.go([odd], self.RAWS, judge=D.FakeJudge(D.credible()), mode="shadow")
        self.assertNotIn("reject rule fired", self.decisions()[D.uuid_of(40)]["reason"])


class Unit(unittest.TestCase):
    def test_thirty_like_rows_of_one_person_are_one_walk_and_thirty_answers(self):
        rows = [row(n, rules={"review_hourly_velocity_profile": 100}) for n in range(30)]
        plan = ud.decide_users(rows, POLICY)
        self.assertEqual((plan.rows, plan.users, plan.walks, plan.fallback), (30, 1, 1, 0))
        self.assertEqual(len(plan.answers), 30)
        v = plan.verdicts[0]
        self.assertTrue(v.uniform)
        self.assertEqual([(a.rule, len(ids)) for a, ids in v.groups], [(ud.CONFLICT, 30)])
        self.assertEqual([rid for rid, _ in v.answers], [str(n) for n in range(30)])

    def test_the_user_scope_fact_is_read_once_per_person_not_once_per_row(self):
        rows = [row(n, uid=DENIED_USER, rules={"review_x": n % 3 * 50}) for n in range(40)]
        per_row = decide.Policy(deny_user_ids=CountingSet({DENIED_USER}), deny_profile_ids=set(),
                                editorial_role_terms=D.TERMS)
        ud.decide_rows(rows, per_row)
        per_user = decide.Policy(deny_user_ids=CountingSet({DENIED_USER}), deny_profile_ids=set(),
                                 editorial_role_terms=D.TERMS)
        plan = ud.decide_users(rows, per_user)
        self.assertEqual((per_row.deny_user_ids.asked, per_user.deny_user_ids.asked), (40, 1))
        self.assertEqual({a.rule for a in plan.answers}, {ud.DENY_USER})

    def test_a_person_holding_different_rows_gets_a_different_answer_for_each_kind(self):
        rows = ([row(n, rules={"reject_x": 100}) for n in range(3)] + [row(10 + n) for n in range(4)]
                + [row(20 + n, rules={"review_x": 100}) for n in range(5)])
        v = ud.decide_users(rows, POLICY).verdicts[0]
        self.assertEqual([(a.rule, len(ids)) for a, ids in v.groups],
                         [(ud.CONFLICT, 5), (ud.PER_ROW, 4), (ud.REJECT_RULE, 3)])
        self.assertEqual((v.walks, v.per_row, v.uniform), (3, 4, False))

    def test_a_verdict_never_crosses_from_one_person_to_another(self):
        same = {"rules": {"review_x": 10}}
        rows = [row(1, uid=DENIED_USER, **same), row(2, uid=501, **same), row(3, uid=DENIED_USER, **same)]
        plan = ud.decide_users(rows, POLICY)
        self.assertEqual([a.rule for a in plan.answers], [ud.DENY_USER, ud.PER_ROW, ud.DENY_USER])
        self.assertEqual((plan.users, plan.walks), (2, 2))

    def test_answers_come_back_in_the_order_of_the_rows_whatever_the_interleaving(self):
        rows = [row(n, uid=500 + n % 7, rules={"reject_x": n % 2}) for n in range(70)]
        random.Random(3).shuffle(rows)
        self.assertEqual(ud.decide_users(rows, POLICY).answers, ud.decide_rows(rows, POLICY))

    def test_a_rule_the_ladder_does_not_read_never_splits_a_group(self):
        rows = [row(n, rules={"review_x": 100, "approve_owning_track": n, "total_noise": n * 1.5}) for n in range(9)]
        self.assertEqual(ud.decide_users(rows, POLICY).walks, 1)

    def test_a_null_score_is_what_the_validator_writes_and_is_not_a_fallback(self):
        # 4,665 of the first 5,976 real rows carry a JSON null beside a rule name. Reading that as
        # "ambiguous" sent three rows in four to the per-row path and made the unit change a no-op.
        rows = [row(n, rules={"review_role_cardinality": None, "review_x": 100, "reject_y": None}) for n in range(4)]
        plan = ud.decide_users(rows, POLICY)
        self.assertEqual((plan.fallback, plan.walks, {a.rule for a in plan.answers}), (0, 1, {ud.CONFLICT}))
        self.assertEqual(plan.answers, ud.decide_rows(rows, POLICY))


class Fallback(unittest.TestCase):
    AMBIGUOUS = [
        ("a string score", row(1, rules={"review_x": "100"})),
        ("a boolean score", row(2, rules={"reject_x": True})),
        ("a score that is not finite", row(3, rules={"review_x": math.inf})),
        ("verificationData is a list", row(4, vd=["review_x"])),
        ("verificationData is missing", row(5, vd=None)),
        ("the rules are a list", row(6, vd={"rule_risk_percent": ["review_x"]})),
        ("the rule errors are a string", row(7, vd={"rule_risk_percent": {}, "rule_errors": "_hold_on_error"})),
        ("the profile id is a number", row(8, pid=12)),
        ("the track id is a number", row(9, track=0)),
        ("no user id", row(10, uid=None, rules={"review_x": 100})),
        ("a boolean user id", row(11, uid=True, rules={"review_x": 100})),
        ("a string user id", row(12, uid="500", rules={"review_x": 100})),
    ]

    def test_an_ambiguous_row_is_walked_on_its_own_counted_and_answered_as_the_per_row_path_answers_it(self):
        for name, odd in self.AMBIGUOUS:
            like = [row(100 + n, rules={"review_x": 100}) for n in range(3)]
            rows = like[:2] + [odd] + like[2:]
            plan = ud.decide_users(rows, POLICY)
            self.assertEqual(plan.fallback, 1, name)
            self.assertEqual([rid for v in plan.verdicts for rid in v.fallback], [odd["id"]], name)
            self.assertEqual(plan.answers, ud.decide_rows(rows, POLICY), name)
            self.assertEqual(plan.walks, 2, name)       # one for the three like rows, one for the odd row

    def test_two_ambiguous_rows_that_look_alike_are_still_two_walks(self):
        rows = [row(n, rules={"review_x": "100"}) for n in range(5)]
        plan = ud.decide_users(rows, POLICY)
        self.assertEqual((plan.fallback, plan.walks), (5, 5))

    def test_rows_with_no_person_are_never_grouped_with_each_other(self):
        rows = [row(n, uid=None, rules={"review_x": 100}) for n in range(4)]
        plan = ud.decide_users(rows, POLICY)
        self.assertEqual((plan.users, plan.fallback, plan.walks), (0, 4, 4))
        self.assertEqual(plan.answers, ud.decide_rows(rows, POLICY))


RULE_NAMES = ("reject_artist_credit", "reject_publisher_label_credit", "review_hourly_velocity_profile",
              "review_big_track_without_trusted_credit", "review_role_cardinality", "track_credit", "collaborations",
              "approve_owning_track", "approve_credit_exists")
SCORES = (0, 0, 0, None, None, 1, 29, 30, 69, 70, 89, 90, 100, 29.999, 30.0, 0.0, -1)
ODD_SCORES = ("100", True, False, math.nan, math.inf, [100], {"v": 100})


def generated(seed: int, n: int, odd: float = 0.04) -> list[dict]:
    """Rows in the shapes the validator writes, a few it should never write, for a handful of people."""
    rnd = random.Random(seed)
    out = []
    for i in range(n):
        rules = {k: rnd.choice(SCORES) for k in rnd.sample(RULE_NAMES, rnd.randint(0, len(RULE_NAMES)))}
        if rnd.random() < odd:
            rules[rnd.choice(RULE_NAMES)] = rnd.choice(ODD_SCORES)
        r = row(f"g{seed}-{i}", uid=rnd.choice((500, 501, 502, 503, DENIED_USER)), rules=rules,
                errors=rnd.choice((None, None, {}, {"_hold_on_error": "boom"}, {"other": 1})),
                pid=rnd.choice(("pppppppp-0000-4000-8000-000000000001", DENIED_PROFILE, DENIED_PROFILE.upper(), None, "")),
                track=rnd.choice(("trk-1", "trk-2", None, "")),
                codes=rnd.choice((None, [], ["review_hourly_velocity_profile"], ["risk_score_at_or_above_threshold"])))
        if rnd.random() < odd:
            r["verificationData"] = rnd.choice((None, [], "x", 3, {"rule_risk_percent": None}, {"rule_errors": None},
                                                {"rule_risk_percent": [], "rule_errors": {}}))
        if rnd.random() < odd:
            r["userId"] = rnd.choice((None, "500", True, 5.0))
        if rnd.random() < odd:
            r[rnd.choice(("profileId", "trackId"))] = rnd.choice((7, 0, ["x"], False))
        out.append(r)
    return out


class Equivalence(unittest.TestCase):
    def test_per_user_equals_per_row_row_for_row_on_generated_rows(self):
        rules, fallbacks = set(), 0
        for seed in range(60):
            rows = generated(seed, 250)
            e = ud.equivalence(rows, POLICY, repeat=1)
            self.assertTrue(e.equivalent, e.disagreements[:3])
            self.assertEqual((e.agree, e.walks_per_row), (len(rows), len(rows)))
            self.assertLess(e.walks_per_user, e.walks_per_row)
            rules |= set(e.answers)
            fallbacks += e.fallback
        self.assertEqual(rules, {ud.REJECT_RULE, ud.DENY_USER, ud.DENY_PROFILE, ud.NO_TRACK, ud.CONFLICT, ud.PER_ROW})
        self.assertGreater(fallbacks, 500)        # the generator really does produce unreadable rows

    def test_the_view_answer_is_the_real_rule_functions_answer_on_the_full_row(self):
        # Independent of row_answer: straight to the policy functions the decider calls.
        for r in generated(99, 3000, odd=0):
            a = ud.decide_users([r], POLICY).answers[0]
            vd = r["verificationData"]
            self.assertEqual(a.rule == ud.REJECT_RULE, bool(validator_rejected_rules(vd)))
            if a.rule == ud.CONFLICT:
                self.assertEqual(a.reason, ud.conflict_reason(validator_conflict(vd)))
            if a.rule == ud.PER_ROW:
                self.assertIsNone(validator_conflict(vd))
                self.assertTrue(r["trackId"])

    def test_the_check_can_fail_a_pass_that_forgets_a_fact_is_caught_with_the_row_named(self):
        rows = [row(1, rules={"review_x": 100}), row(2, rules={"review_x": 100}, track=None)]
        real = ud.row_view

        def forgets_the_track(r, policy):
            v = real(r, policy)
            return None if v is None else v[:3] + (True,)

        with mock.patch.object(ud, "row_view", forgets_the_track):
            e = ud.equivalence(rows, POLICY, repeat=1)
        self.assertFalse(e.equivalent)
        self.assertEqual([(d["request_id"], d["per_row"][0], d["per_user"][0]) for d in e.disagreements],
                         [("2", ud.NO_TRACK, ud.CONFLICT)])

        def forgets_the_person(view, user_denied):
            return real_answer(view, False)

        real_answer = ud.view_answer
        with mock.patch.object(ud, "view_answer", forgets_the_person):
            e = ud.equivalence([row(3, uid=DENIED_USER)], POLICY, repeat=1)
        self.assertEqual((e.equivalent, e.agree, len(e.disagreements)), (False, 0, 1))


class Cohorts(unittest.TestCase):
    def test_the_census_label_of_a_row_comes_from_the_validator_hold_reason_codes(self):
        cases = [(None, ud.NO_CODES), ([], ud.NO_CODES),
                 (["review_hourly_velocity_profile", "risk_score_at_or_above_threshold"], ud.R8_VOLUME),
                 (["reject_publisher_label_credit", "risk_score_at_or_above_threshold"], ud.R8_HARD),
                 (["risk_score_at_or_above_threshold", "review_big_track_without_trusted_credit"], ud.SCORE_ONLY),
                 (["review_big_track_without_trusted_credit"], ud.NAMED_REVIEW),
                 (["fraud_hold", "review_held_submitter"], ud.NAMED_REVIEW)]
        for codes, want in cases:
            self.assertEqual(ud.cohort(row(1, codes=codes)), want, codes)
        self.assertEqual(ud.cohort(row(1, vd=None)), ud.NO_CODES)

    def test_a_label_is_never_an_input_to_an_answer(self):
        a = [row(n, rules={"review_x": 100}, codes=c) for n, c in enumerate(([], ["risk_score_at_or_above_threshold"],
                                                                              ["review_hourly_velocity_profile"]))]
        plan = ud.decide_users(a, POLICY)
        self.assertEqual((plan.walks, len(set(plan.answers))), (1, 1))

    def test_a_sample_takes_whole_people_from_both_ends_of_every_cohort(self):
        rows = []
        for u in range(12):
            rows += [row(f"v{u}-{n}", uid=1000 + u, codes=["review_hourly_velocity_profile"]) for n in range(u + 1)]
            rows += [row(f"s{u}-{n}", uid=2000 + u, codes=["risk_score_at_or_above_threshold"]) for n in range(u + 1)]
        rows.append(row("extra", uid=1011, codes=["review_other"]))
        got = ud.sample_users(rows, 2)
        users = {r["userId"] for r in got}
        self.assertEqual(users, {1011, 1010, 1000, 1001, 2011, 2010, 2000, 2001})
        self.assertEqual(len(got), sum(1 for r in rows if r["userId"] in users))
        self.assertIn("extra", {r["id"] for r in got})

    def test_the_summary_counts_people_lines_and_what_stays_per_row(self):
        rows = ([row(n, uid=1, rules={"review_x": 100}) for n in range(6)] + [row(10 + n, uid=2) for n in range(3)]
                + [row(20, uid=3, rules={"reject_x": 1}), row(21, uid=3), row(22, uid=3, rules={"review_x": "9"})])
        s = ud.summary(rows, POLICY)
        self.assertEqual({k: s[k] for k in ("rows", "users", "walks_per_row", "walks_per_user", "fallback",
                                            "worklist_lines", "users_one_answer", "users_fully_decided",
                                            "users_all_per_row", "rows_decided", "rows_per_row")},
                         {"rows": 12, "users": 3, "walks_per_row": 12, "walks_per_user": 5, "fallback": 1,
                          "worklist_lines": 4, "users_one_answer": 2, "users_fully_decided": 1,
                          "users_all_per_row": 1, "rows_decided": 7, "rows_per_row": 5})


def cell(value) -> str:
    return base64.b64encode(("" if value is ... else json.dumps(value)).encode()).decode()


def line(rid, uid, pid, tid, shape, rules=..., errors=..., codes=...):
    return ",".join(f'"{c}"' for c in (rid, uid, pid, tid, shape, cell(rules), cell(errors), cell(codes)))


_WORD = re.compile(r"[A-Za-z_][A-Za-z_0-9]*")
_LITERAL = re.compile(r"'(?:[^']|'')*'|\d+(?:\.\d+)?")
_OPERATOR = re.compile(r"<=|>=|<>|!=|=|<|>")
_COMPARE = {"=", "<>", "!=", "<", ">", "<=", ">="}


def tokens(sql: str) -> list[tuple[str, str]]:
    """The statement as (kind, text) tokens, so assertions read its structure and not its spelling."""
    out, pos = [], 0
    while pos < len(sql):
        ch = sql[pos]
        if ch.isspace():
            pos += 1
            continue
        for kind, pattern in (("literal", _LITERAL), ("word", _WORD), ("operator", _OPERATOR)):
            m = pattern.match(sql, pos)
            if m:
                out.append((kind, m.group().strip("'").replace("''", "'")))
                pos = m.end()
                break
        else:
            out.append((ch, ch))
            pos += 1
    return out


def _dotted(toks: list[tuple[str, str]], i: int) -> tuple[str | None, int]:
    if i >= len(toks) or toks[i][0] != "word":
        return None, i
    parts, i = [toks[i][1]], i + 1
    while i + 1 < len(toks) and toks[i] == (".", ".") and toks[i + 1][0] == "word":
        parts.append(toks[i + 1][1])
        i += 2
    return ".".join(parts), i


def _operator(toks: list[tuple[str, str]], j: int) -> tuple[str | None, int]:
    if j >= len(toks):
        return None, j
    kind, val = toks[j]
    if kind == "operator" and val in _COMPARE:
        return val, j + 1
    if kind == "word" and val.upper() == "IS":
        parts, j = ["is"], j + 1
        if j < len(toks) and toks[j][0] == "word" and toks[j][1].upper() == "NOT":
            parts.append("not")
            j += 1
        if j < len(toks) and toks[j][0] == "word" and toks[j][1].upper() in ("NULL", "TRUE", "FALSE"):
            parts.append(toks[j][1].lower())
            j += 1
        return " ".join(parts), j
    return None, j


class Statement:
    """What a SQL statement MEANS: its command, how many statements it is, the tables it reads and the
    comparisons it makes. Assertions are made on this, never on substrings of the generated text."""

    def __init__(self, sql: str):
        toks = tokens(sql)
        self.command = toks[0][1].upper() if toks else ""
        self.statements = 1 if toks else 0
        self.tables: list[str] = []
        self.comparisons: list[tuple[str, str, str | None]] = []
        i = 0
        while i < len(toks):
            kind, val = toks[i]
            if kind == ";":
                self.statements += 1
                i += 1
            elif kind == "word" and val.upper() in ("FROM", "JOIN"):
                name, i = _dotted(toks, i + 1)
                if name:
                    self.tables.append(name)
            elif kind == "word":
                name, j = _dotted(toks, i)
                op, k = _operator(toks, j)
                if op is None:
                    i = j
                    continue
                literal = toks[k][1] if k < len(toks) and toks[k][0] == "literal" else None
                self.comparisons.append((name, op, literal))
                i = k + 1 if literal is not None else k
            else:
                i += 1


class Snapshot(unittest.TestCase):
    def test_a_replica_line_becomes_the_row_the_decider_reads_and_an_absent_key_stays_absent(self):
        out = "\n".join([line("r1", "7", "P1", "T1", "{", {"review_x": None, "reject_y": 100},
                                ..., ["review_x"]),
                          line("r2", "", "", "", "[")])
        rows = ud.parse_snapshot(out)
        self.assertEqual(rows[0], {"id": "r1", "userId": 7, "profileId": "P1", "trackId": "T1", "status": "unverified",
                                   "verificationData": {"rule_risk_percent": {"review_x": None, "reject_y": 100},
                                                        "hold_reason_codes": ["review_x"]}})
        self.assertEqual(rows[1], {"id": "r2", "userId": None, "profileId": None, "trackId": None,
                                   "status": "unverified", "verificationData": None})
        self.assertEqual(ud.decide_users(rows, POLICY).fallback, 1)

    def test_a_line_that_cannot_be_read_stops_the_snapshot_instead_of_dropping_the_row(self):
        with self.assertRaises(ValueError):
            ud.parse_snapshot('"r1","7","P1","T1"')
        with self.assertRaises(ValueError):
            ud.parse_snapshot('"r1","7","P","T","{","!!not-base64!!","",""')
        with self.assertRaises(ValueError):
            ud.parse_snapshot('"r1","7","P","T","{","%s","",""' % base64.b64encode(b"{not json").decode())

    def test_one_line_that_is_not_a_row_fails_the_whole_snapshot(self):
        """QA reproduced two non-banner lines yielding one parsed row: the extra line was skipped and the
        partial file read as agreement. Any line that is not a CSV row now raises, so a truncated row
        or stray banner cannot shrink the population the equivalence proof is claimed over."""
        good = line("r1", "7", "P1", "T1", "{", {"review_x": None, "reject_y": 100}, ..., ["review_x"])
        for bad in ("WARNING: Unable to create a system terminal", "r2,9,P2,T2,{", '"r2","9"', "\n"):
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    ud.parse_snapshot("\n".join([good, bad]))
                with self.assertRaises(ValueError):
                    ud.parse_snapshot("\n".join([bad, good]))
        self.assertEqual(len(ud.parse_snapshot(good)), 1)

    def test_the_snapshot_statement_is_one_read_of_the_deciders_population(self):
        open_requests = Statement(ud.snapshot_sql(ud.COURT_UNVERIFIED))
        self.assertEqual((open_requests.command, open_requests.statements), ("SELECT", 1))
        self.assertEqual(open_requests.tables, ["postgresql_core.public.credit_requests"])
        self.assertIn(("cr.status", "=", "unverified"), open_requests.comparisons)
        self.assertIn(("cr.deletedat", "is null", None), open_requests.comparisons)

        paid_held = Statement(ud.snapshot_sql(ud.COURT_PAID_HELD))
        self.assertEqual((paid_held.command, paid_held.statements), ("SELECT", 1))
        self.assertEqual(paid_held.tables, ["postgresql_core.public.credit_requests",
                                            "postgresql_core.public.subscriptions"])
        self.assertIn(("cr.status", "=", "unverified"), paid_held.comparisons)
        with self.assertRaises(ValueError):
            ud.snapshot_sql("everything")

    def test_a_failed_or_empty_read_is_an_error_never_an_empty_queue(self):
        with tempfile.TemporaryDirectory() as tmp:
            def cmd(body):
                p = Path(tmp) / "trino.sh"
                p.write_text("#!/bin/sh\ncat >/dev/null\n" + body, encoding="utf-8")
                p.chmod(p.stat().st_mode | stat.S_IXUSR)
                return str(p)
            with self.assertRaisesRegex(RuntimeError, "rc=7"):
                ud.snapshot(cmd("echo boom >&2; exit 7\n"))
            with self.assertRaises(ValueError):
                ud.snapshot(cmd("echo 'WARNING: nothing'\n"))
            with self.assertRaisesRegex(RuntimeError, "no rows"):
                ud.snapshot(cmd("true\n"))
            good = line("r1", "7", "P1", "T1", "{", {"reject_y": 100})
            self.assertEqual(len(ud.snapshot(cmd(f"cat <<'EOF'\n{good}\nEOF\n"))), 1)


def load_cli():
    spec = importlib.util.spec_from_file_location("credit_user_decisions", HERE.parent / "credit-user-decisions.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Cli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.cli = load_cli()
        self.policy = Path(self.tmp.name) / "policy.json"
        self.policy.write_text(json.dumps({"deny_user_ids": [DENIED_USER], "deny_profile_ids": [DENIED_PROFILE],
                                           "editorial_role_terms": ["editor"]}), encoding="utf-8")

    def rows_file(self, rows):
        p = Path(self.tmp.name) / "rows.json"
        p.write_text(json.dumps(rows), encoding="utf-8")
        return str(p)

    def run_cli(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            rc = self.cli.main(list(argv))
        return rc, out.getvalue(), err.getvalue()

    def people(self, n):
        return [row(f"{u}-{i}", uid=3000 + u, rules={"review_x": 100 if u % 2 else 0},
                    codes=["review_hourly_velocity_profile"] if u % 2 else ["risk_score_at_or_above_threshold"])
                for u in range(n) for i in range(1 + u % 4)]

    def test_equivalence_exits_zero_only_when_every_row_agrees_on_enough_people(self):
        f = self.rows_file(self.people(60))
        rc, out, _ = self.run_cli("equivalence", "--rows", f, "--policy", str(self.policy), "--per-cohort", "15",
                                  "--repeat", "1", "--json")
        got = json.loads(out)
        self.assertEqual(rc, 0)
        self.assertEqual(got["measurements"][0]["scope"], "SAMPLE")
        self.assertEqual(got["measurements"][0]["users"], 60)
        self.assertTrue(all(m["equivalent"] and m["disagreement_count"] == 0 for m in got["measurements"]))
        self.assertEqual({m["scope"] for m in got["measurements"]}, {"SAMPLE", "ALL", ud.R8_VOLUME, ud.SCORE_ONLY})

    def test_a_sample_of_too_few_people_is_not_called_a_proof(self):
        rc, _, err = self.run_cli("equivalence", "--rows", self.rows_file(self.people(60)), "--policy",
                                  str(self.policy), "--per-cohort", "3", "--repeat", "1")
        self.assertEqual(rc, 3)
        self.assertIn("proves nothing", err)

    def test_a_disagreement_exits_one_and_prints_the_row(self):
        real = ud.view_answer
        with mock.patch.object(ud, "view_answer", lambda view, user_denied: real(view[:3] + (True,), user_denied)):
            rc, out, _ = self.run_cli("equivalence", "--rows",
                                      self.rows_file(self.people(60) + [row("lost", uid=3001, track=None)]),
                                      "--policy", str(self.policy), "--per-cohort", "15", "--repeat", "1")
        self.assertEqual(rc, 1)
        self.assertIn('DISAGREE ALL {"request_id": "lost"', out)

    def test_an_unreadable_or_empty_rows_file_is_exit_two(self):
        for body in ("{not json", "[]", '{"rows": []}', "[1, 2]"):
            p = Path(self.tmp.name) / "bad.json"
            p.write_text(body, encoding="utf-8")
            for cmd in ("equivalence", "plan"):
                rc, out, err = self.run_cli(cmd, "--rows", str(p), "--policy", str(self.policy))
                self.assertEqual((rc, out), (2, ""), body)
                self.assertIn("unreadable input", err)
        rc, _, _ = self.run_cli("plan", "--rows", self.rows_file(self.people(3)), "--policy", "/nonexistent.json")
        self.assertEqual(rc, 2)

    def test_the_plan_is_one_entry_per_person_with_every_request_id_under_exactly_one_answer(self):
        rows = self.people(9) + [row("odd", uid=3001, rules={"review_x": "100"})]
        rc, out, _ = self.run_cli("plan", "--rows", self.rows_file(rows), "--policy", str(self.policy), "--json")
        plan = json.loads(out)
        self.assertEqual(rc, 0)
        self.assertEqual(len(plan), 9)
        listed = [rid for p in plan for a in p["answers"] for rid in a["request_ids"]]
        self.assertEqual(sorted(listed), sorted(r["id"] for r in rows))
        self.assertEqual([p["fallback"] for p in plan if p["user_id"] == 3001], [["odd"]])
        self.assertEqual(plan[0]["rows"], max(p["rows"] for p in plan))
        rc, text, _ = self.run_cli("plan", "--rows", self.rows_file(rows), "--policy", str(self.policy), "--top", "2")
        self.assertEqual((rc, text.count("\nuser ")), (0, 2))

    def test_a_failed_snapshot_writes_no_file(self):
        out_file = Path(self.tmp.name) / "snap.json"
        rc, _, err = self.run_cli("snapshot", "--out", str(out_file), "--trino", "/bin/false")
        self.assertEqual((rc, out_file.exists()), (2, False))
        self.assertIn("snapshot failed", err)

    def test_no_command_writes_a_credit_spawns_a_writer_or_opens_a_socket(self):
        out = Path(self.tmp.name) / "snap.json"
        trino = Path(self.tmp.name) / "trino.sh"
        anchor = line("r1", "3000", "P1", "T1", "{")
        trino.write_text("#!/bin/sh\ncat >/dev/null\ncat <<'EOF'\n" + anchor + "\nEOF\n", encoding="utf-8")
        trino.chmod(trino.stat().st_mode | stat.S_IXUSR)
        rows = self.rows_file(self.people(4))
        written, spawned, sockets = [], [], []
        real_write, real_run = Path.write_text, subprocess.run

        def write_text(self, *a, **k):
            written.append(str(self))
            return real_write(self, *a, **k)

        def run(*a, **k):
            spawned.append(list(a[0]) if isinstance(a[0], (list, tuple)) else [a[0]])
            return real_run(*a, **k)

        def connect(*a, **k):
            sockets.append(a)
            raise OSError("no socket in this test")

        with mock.patch.object(Path, "write_text", write_text), mock.patch.object(subprocess, "run", run), \
                mock.patch.object(socket, "create_connection", connect), \
                mock.patch.object(socket.socket, "connect", connect):
            for argv in (("plan", "--rows", rows, "--policy", str(self.policy), "--json"),
                         ("equivalence", "--rows", rows, "--policy", str(self.policy), "--per-cohort", "2",
                          "--min-users", "1", "--repeat", "1", "--json"),
                         ("snapshot", "--out", str(out), "--trino", str(trino))):
                self.assertEqual(self.run_cli(*argv)[0], 0, argv)
        self.assertEqual(written, [str(out)])
        self.assertEqual(spawned, [[str(trino)]])
        self.assertEqual(sockets, [])
        self.assertTrue(os.access(HERE.parent / "credit-user-decisions.py", os.X_OK))


if __name__ == "__main__":
    warnings.filterwarnings("ignore", category=ResourceWarning)
    unittest.main(verbosity=1, warnings="")
