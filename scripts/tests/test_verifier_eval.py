#!/usr/bin/env python3
"""scripts/verifier_eval: shared shadow evaluation harness (credits / claims / merges).

Locks: the must-be-zero metrics (false-approve, approve on known-bad, guard violations); the
independent protection audit (UNKNOWN never approves, gate, same-run Spotify+Tidal id anchor,
big/flagged guard, name match never anchors); recorded-log replay; the committed frozen sets
validate and the reference verifiers score CLEAN on them while the unsafe controls do not;
nightly honours the kill switch and writes only under its root. Stdlib only, no network.
"""
import credit_test_env  # noqa: F401
import gzip
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from verifier_eval import protections as P  # noqa: E402
from verifier_eval import runner, verifiers as V  # noqa: E402
from verifier_eval.schema import APPROVE, DECLINE, UNKNOWN, WAIT, Verdict, validate_item  # noqa: E402

CLI = SCRIPTS / "verifier-eval.py"


def src(state="CAPTURED", verdict="UNKNOWN", reason="person_not_linked_on_spotify", complete=True,
        name_match=False, n=0):
    return {"state": state, "verdict": verdict, "reason": reason, "complete": complete,
            "name_match": name_match, "n_credited": n}


CRED = src(verdict="CREDITED", reason="person_credited_in_role_family", n=1)
ABSENT = src(verdict="NOT_CREDITED", reason="person_absent_from_complete_snapshot", n=1)
NOREC = src(state="NO_RECORDING", reason="no_tidal_recording_on_track", complete=False)
NAME = src(reason="name_only_credit_in_role_family", name_match=True)


def credit(roles=None, dsp=None, label=WAIT, pop=10, gate="allow", flags=None, known_bad=False,
           segment="paid", approved_roles=None, ident="r1", validator=None):
    roles = roles or ["Producer"]
    return {"set": "credits", "id": ident, "segment": segment, "label": label, "approved_roles": approved_roles,
            "known_bad": known_bad, "label_source": "test", "label_strength": "human", "label_ref": "t",
            "user_id": "1", "evidence": {"roles": roles, "popularity": pop, "gate": {"decision": gate},
                                         "flags": flags or {}, "validator": validator or {"fraud_rules": []},
                                         "dsp": dsp if dsp is not None else
                                         {r: {"sources": {"spotify": CRED, "tidal": NOREC}} for r in roles}}}


class Protections(unittest.TestCase):
    def test_clean_id_anchor_has_no_violation(self):
        self.assertEqual(P.audit_approve(credit()), [])

    def test_unknown_never_approves(self):
        it = credit()
        it["evidence"] = None
        self.assertEqual(P.audit_approve(it), ["approve_on_missing_evidence"])

    def test_gate_hold_and_unknown_block(self):
        for g in ("hold", "unknown", None):
            self.assertTrue(any(v.startswith("gate_not_allow") for v in P.audit_approve(credit(gate=g))), g)

    def test_big_watchlist_idp_fraud_rule_block(self):
        self.assertIn("big_track_pop_60", P.audit_approve(credit(pop=60)))
        self.assertIn("watchlist:review", P.audit_approve(credit(flags={"watchlist": "review"})))
        self.assertIn("idp_credit_hold", P.audit_approve(credit(flags={"idp_hold": True})))
        v = P.audit_approve(credit(validator={"fraud_rules": ["reject_high_velocity_profile"]}))
        self.assertTrue(any(x.startswith("validator_fraud_rule") for x in v))
        # a risk-score line is NOT a fraud rule (d3 §1.4)
        self.assertEqual(P.audit_approve(credit(validator={"fraud_rules": [],
                                                           "hold_reason_codes": ["risk_score_at_or_above_threshold"]})), [])

    def test_name_match_is_never_an_anchor(self):
        it = credit(dsp={"Producer": {"sources": {"spotify": NAME, "tidal": NOREC}}})
        self.assertIn("no_id_anchor:Producer", P.audit_approve(it))

    def test_both_lanes_must_be_read_same_run(self):
        it = credit(dsp={"Producer": {"sources": {"spotify": CRED, "tidal": src(state="WAITING")}}})
        self.assertIn("tidal_not_read_same_run:Producer:WAITING", P.audit_approve(it))
        it = credit(dsp={"Producer": {"sources": {"spotify": CRED}}})
        self.assertIn("tidal_not_read_same_run:Producer:None", P.audit_approve(it))

    def test_every_approved_role_needs_its_own_anchor(self):
        it = credit(roles=["Producer", "Mixing"],
                    dsp={"Producer": {"sources": {"spotify": CRED, "tidal": NOREC}},
                         "Mixing": {"sources": {"spotify": ABSENT, "tidal": NOREC}}})
        self.assertEqual(P.audit_approve(it, ["Producer"]), [])
        self.assertIn("no_id_anchor:Mixing", P.audit_approve(it))
        self.assertIn("approved_unclaimed_roles:Bass", P.audit_approve(it, ["Bass"]))

    def test_one_person_role_contradicted_by_the_other_source(self):
        it = credit(roles=["Mixing"], dsp={"Mixing": {"sources": {"spotify": CRED, "tidal": ABSENT}}})
        self.assertIn("one_person_role_contradicted:Mixing", P.audit_approve(it))

    def test_claims_need_bound_proof(self):
        it = {"set": "claims", "id": "c", "evidence": {"gate": {"decision": "allow"}, "flags": {}, "proof": {}}}
        self.assertIn("no_bound_proof", P.audit_approve(it))
        it["evidence"]["proof"] = {"e1_bound_code_verified": True}
        self.assertEqual(P.audit_approve(it), [])
        it["evidence"]["popularity"] = 70
        self.assertIn("big_profile_single_signal_pop_70", P.audit_approve(it))

    def test_merges_unknown_fact_is_a_violation(self):
        it = {"set": "merges", "id": "m", "evidence": {"no_login_or_primary_loser": False}}
        v = P.audit_approve(it)
        self.assertIn("login_or_primary_loser", v)
        self.assertIn("unknown:no_org_profile", v)


class ReferenceVerifiers(unittest.TestCase):
    def test_credits_approves_only_anchored_roles(self):
        it = credit(roles=["Producer", "Guitar"],
                    dsp={"Producer": {"sources": {"spotify": CRED, "tidal": NOREC}},
                         "Guitar": {"sources": {"spotify": src(), "tidal": NOREC}}})
        v = V.credits_rules_v1(it)
        self.assertEqual((v.verdict, v.approved_roles), (APPROVE, ["Producer"]))

    def test_credits_guarded_anchor_waits(self):
        self.assertEqual(V.credits_rules_v1(credit(gate="hold")).verdict, WAIT)
        self.assertEqual(V.credits_rules_v1(credit(pop=75)).verdict, WAIT)

    def test_credits_decline_only_on_one_person_contradiction(self):
        one = credit(roles=["Mixing"], dsp={"Mixing": {"sources": {"spotify": ABSENT, "tidal": NOREC}}})
        self.assertEqual(V.credits_rules_v1(one).verdict, DECLINE)
        multi = credit(roles=["Producer"], dsp={"Producer": {"sources": {"spotify": ABSENT, "tidal": NOREC}}})
        self.assertEqual(V.credits_rules_v1(multi).verdict, WAIT)  # others-only on a multi-person role = not found
        conflict = credit(roles=["Mixing"], dsp={"Mixing": {"sources": {"spotify": ABSENT, "tidal": CRED}}})
        self.assertNotEqual(V.credits_rules_v1(conflict).verdict, DECLINE)
        waiting = credit(roles=["Mixing"],
                         dsp={"Mixing": {"sources": {"spotify": ABSENT, "tidal": src(state="WAITING")}}})
        self.assertEqual(V.credits_rules_v1(waiting).verdict, WAIT)  # second lane unread = unknown

    def test_credits_missing_capture_is_unknown(self):
        self.assertEqual(V.credits_rules_v1(credit(dsp={})).verdict, UNKNOWN)

    def test_claims_rules(self):
        base = {"set": "claims", "id": "c", "evidence": {"gate": {"decision": "allow"}, "flags": {}, "proof": {},
                                                         "popularity": 10}}
        self.assertEqual(V.claims_rules_v1(base).verdict, WAIT)
        fraud = json.loads(json.dumps(base))
        fraud["evidence"]["flags"] = {"watchlist": "fraud"}
        self.assertEqual(V.claims_rules_v1(fraud).verdict, DECLINE)
        org = json.loads(json.dumps(base))
        org["evidence"].update(profile_type="organization", company_claim_on_add=True, email_class="free",
                               popularity=95)
        self.assertEqual(V.claims_rules_v1(org).reasons, ["org_claim_role_contradiction"])
        org["evidence"]["created_by_user_org"] = True  # a reject would publish a catalog delete
        self.assertEqual(V.claims_rules_v1(org).verdict, WAIT)
        proof = json.loads(json.dumps(base))
        proof["evidence"]["proof"] = {"e1_bound_code_verified": True}
        self.assertEqual(V.claims_rules_v1(proof).verdict, APPROVE)
        proof["evidence"]["competing_users"] = 1
        self.assertEqual(V.claims_rules_v1(proof).verdict, WAIT)

    def test_merges_rules(self):
        ok = {"set": "merges", "id": "m", "evidence": {k: True for k in V.MERGE_FACTS} | {"flags": {}}}
        self.assertEqual(V.merges_rules_v1(ok).verdict, APPROVE)
        ok["evidence"]["max_popularity"] = 61
        self.assertEqual(V.merges_rules_v1(ok).verdict, WAIT)
        refused = {"set": "merges", "id": "m", "evidence": {"no_login_or_primary_loser": False}}
        self.assertEqual(V.merges_rules_v1(refused).verdict, WAIT)
        self.assertEqual(V.merges_rules_v1({"set": "merges", "id": "m", "evidence": {"flags": {}}}).verdict, UNKNOWN)


class Metrics(unittest.TestCase):
    def rows(self, pairs):
        items = [credit(label=lab, known_bad=kb, ident=f"i{n}", segment=seg)
                 for n, (lab, kb, seg, _v) in enumerate(pairs)]
        verdicts = {f"i{n}": v for n, (*_x, v) in enumerate(pairs)}
        return runner.replay(items, lambda it: Verdict(verdicts[it["id"]]))

    def test_false_approve_counts_declines_and_known_bad(self):
        m = runner.metrics(self.rows([(APPROVE, False, "paid", APPROVE), (DECLINE, False, "paid", APPROVE),
                                      (WAIT, True, "paid", APPROVE), (WAIT, False, "paid", APPROVE),
                                      (DECLINE, False, "paid", DECLINE), (APPROVE, False, "paid", DECLINE)]))
        self.assertEqual(m["approve"], {"predicted": 4, "tp": 1, "precision": 0.25, "recall": 0.5,
                                        "label_defects": 0, "precision_adjudicated": 0.25})
        self.assertEqual((m["false_approve"], m["approve_on_known_bad"], m["over_approve_vs_wait"]), (2, 1, 1))
        self.assertEqual((m["decline"]["precision"], m["false_decline"]), (0.5, 1))

    def test_paid_first_and_clean_flag(self):
        s = runner.score(self.rows([(APPROVE, False, "free", APPROVE), (WAIT, False, "paid", WAIT)]))
        self.assertEqual(list(s["by_segment"]), ["paid", "free"])
        self.assertTrue(s["clean"])
        s = runner.score(self.rows([(DECLINE, False, "paid", APPROVE)]))
        self.assertFalse(s["clean"])

    def test_adjudicated_label_defect_counts_only_in_the_adjudicated_precision(self):
        items = [credit(ident="a", label=WAIT), credit(ident="b", label=APPROVE)]
        adj = {"a": {"finding": "label_defect_truncated_roles"}}
        m = runner.metrics(runner.replay(items, lambda it: Verdict(APPROVE, approved_roles=["Producer"]), adj))
        self.assertEqual((m["approve"]["precision"], m["approve"]["precision_adjudicated"]), (0.5, 1.0))
        self.assertEqual(m["false_approve"], 0)

    def test_committed_adjudications_point_at_frozen_items(self):
        adj = runner.load_adjudications()
        ids = {i["id"] for i in runner.load_set("credits")}
        for k, v in adj.items():
            self.assertIn(k, ids)
            self.assertTrue(v["finding"].startswith("label_") or v["finding"].startswith("verifier_"), k)

    def test_verifier_exception_is_unknown_not_a_crash(self):
        def boom(_it):
            raise RuntimeError("x")
        rows = runner.replay([credit()], boom)
        self.assertEqual((rows[0]["verdict"], rows[0]["error"][:12]), (UNKNOWN, "RuntimeError"))

    def test_a_verifier_that_raises_on_every_item_is_never_clean(self):
        # QA 2026-10-28: replay() catches a raising verifier as UNKNOWN, so a run with errors=1 and
        # nothing judged must not reach the board as [clean].
        def boom(_it):
            raise RuntimeError("x")
        rows = runner.replay([credit(label=DECLINE)], boom)
        s = runner.score(rows)
        self.assertEqual((s["overall"]["errors"], s["overall"]["judged"]), (1, 0))
        self.assertFalse(s["clean"])

    def test_recorded_log_verdict_must_be_supported(self):
        # QA 2026-10-28: a misspelt recorded verdict used to become WAIT - a judgement that was never
        # made, able to satisfy coverage and the merges self-serve precondition. It fails closed now.
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "log.jsonl"
            for bad in ("eligble", "", "approved:maybe"):
                p.write_text(json.dumps({"id": "r1", "verdict": bad}) + "\n")
                with self.assertRaises(ValueError, msg=bad):
                    runner.load_recorded(str(p))
            p.write_text(json.dumps({"verdict": "eligible"}) + "\n")
            with self.assertRaises(ValueError):
                runner.load_recorded(str(p))
            # the documented aliases and every real verdict still load
            for good in ("eligible", "refused:LOGIN_OR_PRIMARY_LOSER", "queued_review", "WAIT", "UNKNOWN"):
                p.write_text(json.dumps({"id": "r1", "verdict": good}) + "\n")
                runner.load_recorded(str(p))

    def test_recorded_log_replay(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "log.jsonl"
            p.write_text(json.dumps({"id": "r1", "verdict": "verified", "approved_roles": ["Producer"]}) + "\n")
            fn = runner.load_recorded(str(p))
            self.assertEqual(fn(credit()).verdict, APPROVE)
            self.assertEqual(fn(credit(ident="other")).verdict, UNKNOWN)

    def test_recorded_duplicate_ids_score_the_riskiest_event(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "log.jsonl"
            p.write_text(json.dumps({"id": "r1", "verdict": "APPROVE", "approved_roles": ["Producer"]}) + "\n"
                         + json.dumps({"id": "r1", "verdict": "WAIT"}) + "\n")
            rows = runner.replay([credit(label=DECLINE)], runner.load_recorded(str(p)))
            self.assertEqual(rows[0]["verdict"], APPROVE)
            m = runner.metrics(rows)
            self.assertEqual(m["false_approve"], 1)
            self.assertFalse(runner.score(rows)["clean"])

    def test_merge_replay_agreement_is_the_self_serve_precondition(self):
        def item(i, lab):
            return {"set": "merges", "id": i, "segment": "unknown", "label": lab, "known_bad": False,
                    "label_source": "t", "label_strength": "audit", "evidence": None}
        items = [item("a", APPROVE), item("b", DECLINE), item("c", WAIT)]
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "core-verify.jsonl"
            p.write_text("".join(json.dumps(r) + "\n" for r in (
                {"id": "a", "verdict": "eligible"}, {"id": "b", "verdict": "refused:LOGIN_OR_PRIMARY_LOSER"},
                {"id": "c", "verdict": "queued_review"})))
            auth = {"merges": "merges@relabel-20261028"}
            ag = runner.score(runner.replay(items, runner.load_recorded(str(p))), "merges@relabel-20261028",
                              auth)["agreement"]
            self.assertEqual((ag["binary"], ag["exact"], ag["precondition_met"]), (1.0, 1.0, True))
            p.write_text("".join(json.dumps(r) + "\n" for r in (
                {"id": "a", "verdict": "eligible"}, {"id": "b", "verdict": "eligible"})))
            ag = runner.score(runner.replay(items, runner.load_recorded(str(p))), "merges@relabel-20261028",
                              auth)["agreement"]
            self.assertFalse(ag["precondition_met"])
            self.assertEqual(sorted(x["id"] for x in ag["binary_disagreement_list"]), ["b", "c"])  # c unjudged
            # QA 2026-11-03: only an AUTHORITATIVE set may issue the gate. A sensitivity variant that
            # matches perfectly reports the same agreement and no readiness.
            # the QA case: the same three rows are WAIT under the strict labels (unread hold source) and
            # APPROVE under the assumed-clean sensitivity variant. An endpoint that says eligible for all
            # three agrees 3/3 with the sensitivity variant and disagrees 3/3 with the strict one.
            sens = {"merges": "merges@relabel-20261028"}
            p2 = Path(d) / "all-eligible.jsonl"
            p2.write_text("".join(json.dumps({"id": i, "verdict": "eligible"}) + "\n" for i in "abc"))
            log = runner.load_recorded(str(p2))
            strict_items = [item(i, WAIT) for i in "abc"]
            sens_items = [item(i, APPROVE) for i in "abc"]
            a_sens = runner.score(runner.replay(sens_items, log), "merges@relabel-20261028-holdsassumedclean",
                                  sens)["agreement"]
            a_strict = runner.score(runner.replay(strict_items, log), "merges@relabel-20261028", sens)["agreement"]
            self.assertEqual((a_sens["binary"], a_sens["precondition_met"], a_sens["gate_set"]), (1.0, False, False))
            self.assertEqual((a_strict["binary"], a_strict["precondition_met"]), (0.0, False))
            # and with no manifest at all nothing may declare readiness
            ag = runner.score(runner.replay(items, runner.load_recorded(str(p))),
                              "merges@relabel-20261028", {})["agreement"]
            self.assertFalse(ag["precondition_met"])

    def test_only_a_hold_verified_set_is_authoritative(self):
        auth = runner.authoritative_sets()
        self.assertEqual(auth.get("merges"), "merges@relabel-20261028")
        for base, name in auth.items():
            self.assertIn(name, runner.set_variants(base), f"{name} is not a committed set")
            self.assertNotIn("holdsassumedclean", name)  # a sensitivity variant never gates readiness

    def test_missing_or_empty_set_fails_closed(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(FileNotFoundError):
                runner.load_set("credits", d)
            with gzip.open(Path(d) / "claims.jsonl.gz", "wt") as fh:
                fh.write("")
            with self.assertRaises(ValueError):
                runner.load_set("claims", d)
            with self.assertRaises(FileNotFoundError):
                runner.run(["credits-rules-v1"], Path(d) / "out", sets_dir=d)
        self.assertFalse(runner.score([])["clean"])

    def test_write_set_is_deterministic(self):
        with tempfile.TemporaryDirectory() as d:
            items = [credit(ident="b"), credit(ident="a")]
            runner.write_set("credits", items, d)
            a = (Path(d) / "credits.jsonl.gz").read_bytes()
            runner.write_set("credits", list(reversed(items)), d)
            self.assertEqual(a, (Path(d) / "credits.jsonl.gz").read_bytes())
            self.assertEqual([i["id"] for i in runner.load_set("credits", d)], ["a", "b"])

    def test_invalid_items_refused(self):
        self.assertTrue(validate_item({"set": "credits", "id": "x", "label": APPROVE, "known_bad": True,
                                       "segment": "paid", "label_strength": "human", "label_source": "t"}))


class CommittedSets(unittest.TestCase):
    """The frozen sets shipped in the repo validate, and the reference verifiers stay CLEAN on them."""

    @classmethod
    def setUpClass(cls):
        cls.sets = {s: runner.load_set(s) for s in ("credits", "claims", "merges")}

    def test_sets_present_and_split(self):
        for s, items in self.sets.items():
            self.assertGreater(len(items), 100, s)
            self.assertEqual({i["set"] for i in items}, {s})
        segs = {i["segment"] for i in self.sets["credits"]}
        self.assertTrue({"paid", "free"} <= segs)
        self.assertTrue(any(i["label_strength"] == "human" and i["known_bad"] for i in self.sets["credits"]))

    def test_no_names_or_emails_in_sets(self):
        banned = {"title", "track_title", "artist", "artists", "user_name", "profile_name", "account_name",
                  "email", "email_domain", "person_name", "credited_in_family", "verificationLinks"}

        def keys(x):
            if isinstance(x, dict):
                for k, v in x.items():
                    yield k
                    yield from keys(v)
            elif isinstance(x, list):
                for v in x:
                    yield from keys(v)

        for s, items in self.sets.items():
            raw = gzip.open(runner.SETS_DIR / f"{s}.jsonl.gz", "rt", encoding="utf-8").read()
            self.assertNotRegex(raw, r"[\w.+-]+@[\w-]+\.[a-z]{2,}", s)
            found = {k for it in items for k in keys(it)} & banned
            self.assertEqual(found, set(), f"{s} carries {found}")

    def test_reference_verifiers_clean_and_controls_dirty(self):
        for name, r in V.REGISTRY.items():
            rows = runner.replay(self.sets[r["set"]], r["fn"])
            s = runner.score(rows)
            if r["kind"] == "reference":
                self.assertTrue(s["clean"], f"{name}: {s['overall']}")
            if r["kind"] == "control":
                self.assertFalse(s["clean"], f"{name} control scored clean: the harness is not catching")
            self.assertEqual(s["overall"]["errors"], 0, name)


class MergeRelabel(unittest.TestCase):
    """Independent merges ground truth from facts (scripts/verifier_eval/merge_relabel.py)."""
    K, L = "k" * 8 + "-0000-0000-0000-000000000000", "a" * 8 + "-0000-0000-0000-000000000000"

    def facts(self, **over):
        f = {"items": {"t:aaaaaaaa": {"kind": "pair", "keep": self.K, "losers": [self.L]}},
             "profiles": {self.K: {"read": "ok", "forwarded": False, "type": "artist", "subType": "artist",
                                   "creditCount": 10, "raw_ids": ["spotify:x"]},
                          self.L: {"read": "ok", "forwarded": False, "type": "artist", "subType": "artist",
                                   "creditCount": 3, "raw_ids": ["spotify:y"]}},
             "claims": [{"profileId": self.K, "userId": 7, "teamId": "T", "status": "processed"},
                        {"profileId": self.L, "userId": 7, "teamId": "T", "status": "processed"}],
             "login": [], "primary": [], "admins": [{"userId": 7, "teamId": "T"}],
             "default_teams": [{"userId": "7", "teamId": "t"}], "paid_seats": [], "profile_merges": [],
             "staff_holds": [], "staff_hold_table_present": True}
        f.update(over)
        return f

    def lab(self, f):
        from verifier_eval.merge_relabel import relabel_all
        return relabel_all(f)["t:aaaaaaaa"]

    def test_clean_own_claims_are_eligible(self):
        self.assertEqual(self.lab(self.facts())["label"], "eligible")

    def test_unreadable_hold_source_is_never_eligible(self):
        # QA 2026-10-28 on merge_relabel.py:133: with the hold table absent, staff_holds is empty for
        # the wrong reason, so `eligible` would execute a merge whose legal hold was never checked.
        lab = self.lab(self.facts(staff_hold_table_present=False))
        self.assertEqual(lab["label"], "queued_review:LEGAL_HOLD_UNKNOWN")
        self.assertTrue(any(b.startswith("staff_hold_source_absent:") for b in lab["basis"]), lab["basis"])
        # recorded, not inferred: the snapshot says which source answered (or none)
        f = self.facts(staff_hold_table_present=False, staff_hold_table="profile_search_visibility")
        self.assertIn("staff_hold_source_absent:profile_search_visibility", self.lab(f)["basis"])
        # a run that never reaches the eligible branch is unaffected: it refuses on its own reason
        f = self.facts(staff_hold_table_present=False,
                       claims=[{"profileId": self.K, "userId": 7, "teamId": "T", "status": "processed"}])
        self.assertEqual(self.lab(f)["label"], "refused:NOT_CLAIMED")
        # a real hold still refuses, table or not
        f = self.facts(staff_holds=[{"profileId": self.L}])
        self.assertEqual(self.lab(f)["label"], "refused:LEGAL_HOLD")

    def test_forwarded_loser_is_already_merged_or_elsewhere(self):
        f = self.facts()
        f["profiles"][self.L].update(forwarded=True, served_id=self.K)
        self.assertEqual(self.lab(f)["label"], "already_merged")
        f["profiles"][self.L].update(served_id="z" * 36)
        self.assertEqual(self.lab(f)["label"], "refused:MERGE_IN_PROGRESS")

    def test_open_claim_and_unclaimed(self):
        f = self.facts()
        f["claims"].append({"profileId": self.L, "userId": 9, "teamId": "U", "status": "pending"})
        self.assertEqual(self.lab(f)["label"], "refused:OPEN_CLAIM")
        f = self.facts(claims=[{"profileId": self.K, "userId": 7, "teamId": "T", "status": "processed"}])
        self.assertEqual(self.lab(f)["label"], "refused:NOT_CLAIMED")

    def test_core_409_with_same_user_exemption(self):
        f = self.facts(login=[{"profileId": self.L, "userId": "7"}])
        self.assertEqual(self.lab(f)["core"], "409")
        f = self.facts(login=[{"profileId": self.L, "userId": "7"}], primary=[{"profileId": self.K, "userId": "7"}])
        self.assertEqual(self.lab(f)["core"], "accepts")

    def test_seat_claimed_main_cannot_take_the_users_own_login(self):
        f = self.facts(login=[{"profileId": self.L, "userId": "7"}])
        f["claims"][0]["userId"] = None  # seat claim on the main, even in the user's default workspace
        self.assertEqual(self.lab(f)["label"], "refused:PRIMARY_PROFILE")
        f["claims"][0]["userId"] = 7
        self.assertEqual(self.lab(f)["label"], "eligible")

    def test_empty_login_shell_main(self):
        f = self.facts(login=[{"profileId": self.K, "userId": "7"}])
        f["profiles"][self.K]["creditCount"] = 0
        self.assertEqual(self.lab(f)["label"], "refused:EMPTY_SHELL_MAIN")

    def test_review_triggers_never_land_on_eligible_without_proof(self):
        f = self.facts(default_teams=[])  # workspace trigger, no shared raw DSP id
        self.assertEqual(self.lab(f)["label"], "queued_review")
        f["profiles"][self.L]["raw_ids"] = ["spotify:x"]
        self.assertEqual(self.lab(f)["label"], "eligible")
        f = self.facts(paid_seats=[{"profileId": self.L, "teamId": "OTHER"}])
        self.assertEqual(self.lab(f)["label"], "refused:PAID_SEAT")

    def test_committed_variant_and_recorded_log(self):
        self.assertIn("merges@relabel-20261028", runner.set_variants("merges"))
        items = runner.load_set("merges@relabel-20261028")
        self.assertEqual(len(items), len(runner.load_set("merges")))
        logs = [r for r in runner.repo_recorded() if r[1] == "merges"]
        self.assertTrue(logs)
        with self.assertRaises(ValueError):
            with tempfile.TemporaryDirectory() as d:
                runner.write_set("credits@x", [credit()], d)
                (Path(d) / "claims@x.jsonl.gz").write_bytes((Path(d) / "credits@x.jsonl.gz").read_bytes())
                runner.load_set("claims@x", d)  # a credits item inside a claims variant


class Cli(unittest.TestCase):
    def run_cli(self, *args, env=None):
        e = dict(os.environ, **(env or {}))
        return subprocess.run([sys.executable, str(CLI), *args], capture_output=True, text=True, env=e)

    def test_nightly_writes_run_latest_history_and_board(self):
        with tempfile.TemporaryDirectory() as d:
            inbox = Path(d) / "inbox" / "merges"
            inbox.mkdir(parents=True)
            (inbox / "core-verify.jsonl").write_text(json.dumps({"id": "nope", "verdict": "PASS"}) + "\n")
            stale = Path(d) / "20200101T000000Z"
            stale.mkdir()
            (stale / "report.md").write_text("old")
            r = self.run_cli("nightly", "--root", d, env={"VERIFIER_EVAL_KILL_SWITCH": str(Path(d) / "off"),
                                                          "VERIFIER_EVAL_KEEP_RUNS": "1"})
            self.assertFalse(stale.exists(), "retention kept a run beyond KEEP_RUNS")
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertTrue(r.stdout.startswith("eval: "), r.stdout)
            latest = Path(d) / "latest"
            for f in ("metrics.json", "report.md", "board.txt", "board.json", "verdicts.jsonl"):
                self.assertTrue((latest / f).exists(), f)
            m = json.loads((latest / "metrics.json").read_text())
            self.assertTrue(m["shadow"])
            self.assertIn("log:core-verify", [x["verifier"] for x in m["results"]])
            self.assertEqual(len((Path(d) / "history.jsonl").read_text().splitlines()), 1)

    def test_kill_switch_stops_nightly(self):
        with tempfile.TemporaryDirectory() as d:
            ks = Path(d) / "verifier-eval.disabled"
            ks.write_text("")
            r = self.run_cli("nightly", "--root", str(Path(d) / "root"), env={"VERIFIER_EVAL_KILL_SWITCH": str(ks)})
            self.assertEqual(r.returncode, 0)
            self.assertIn("kill switch", r.stdout)
            self.assertFalse((Path(d) / "root").exists())

    def test_package_has_no_write_path(self):
        """Shadow by construction: the package imports no network / Muso / Intercom / Slack client."""
        import re
        bad = re.compile(r"^\s*(from|import)\s+(requests|urllib|http|socket|credit_review|credit_trust|"
                         r"credit_retro|smtplib|subprocess)\b", re.M)
        for f in (SCRIPTS / "verifier_eval").glob("*.py"):
            text = f.read_text()
            self.assertIsNone(bad.search(text), f"{f.name}: {bad.search(text)}")
            self.assertNotIn("conditional-status", text, f.name)


if __name__ == "__main__":
    unittest.main()
