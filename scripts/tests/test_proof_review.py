"""The coded proof review (scripts/ops_intake/proof_review.py).

Two frozen fixture sets, no network, no stores on this host:

  fixtures/proof_review/census-asks-1104.json
      the real Jan proof asks from the 2026-10-21..11-04 census (census.md section 5), with
      the evidence H3, doc-verify, dsp-verify and the fraud lens carried on 2026-11-04
      23:0xZ, and the counts/state/campaign the precedence must produce - including the
      six verdicts firstmate hand-posted that evening, so a disagreement is visible rather
      than silent.

  fixtures/proof_review/precedence-cases.json
      one hand-built case per arm of the precedence, including the arms no production
      account happens to show today (a same-run DSP anchor, screenshots only, unreadable
      once vs twice, a forged document, a co-writer split sheet that is not reuse).

What is pinned here, in order of how much it would hurt to get wrong:

  * the precedence itself, arm by arm, and that a later verified read promotes an unapproved
    role and never demotes one stage 2 already approved;
  * that a card never carries the word "approved" without a decision ledger row, never
    carries an account name or email, and says which campaign was sent;
  * that no customer message is ever built here: the only action is naming a campaign for
    the single sender, and a HOLD, a DECLINE, an UNKNOWN, a kill switch or the per-account
    daily card cap all stop it;
  * that the account and the requests come from the H3 filing and the store, never from a
    document's own text.
"""

from __future__ import annotations

import dataclasses
import json
import os
import sqlite3
import sys
import tempfile
import unittest
import unittest.mock
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from ops_intake import proof_review as pr  # noqa: E402

FIXTURES = ROOT / "scripts" / "tests" / "fixtures" / "proof_review"
CENSUS = json.loads((FIXTURES / "census-asks-1104.json").read_text())
CASES = json.loads((FIXTURES / "precedence-cases.json").read_text())


def _documents(raw: list[dict]) -> tuple[pr.Document, ...]:
    return tuple(pr.Document(proof_id=d["proof_id"], doc_kind=d.get("doc_kind", ""),
                             reuse=tuple(pr.Reuse(name=r["name"], severity=r["severity"])
                                         for r in d.get("reuse", [])),
                             injection=d.get("injection", "")) for d in raw)


def _roles(raw: list[dict]) -> tuple[pr.RoleProof, ...]:
    return tuple(pr.RoleProof(role=r["role"], stage2=r.get("stage2", ""), dv=r.get("dv", ""),
                              dv_need=r.get("dv_need", ""), proof_id=r.get("proof_id", ""),
                              # load_stage2 records the same document in both fields, so a stage-2 row's
                              # supporting document defaults to its proof_id; a fixture can split them.
                              stage2_proof_id=r.get("stage2_proof_id", r.get("proof_id", "")),
                              undetermined_runs=int(r.get("undetermined_runs") or 0),
                              unknown_runs=int(r.get("unknown_runs") or 0)) for r in raw)


def ask_of(bundle: dict) -> pr.Ask:
    def _claimed(r: dict) -> tuple[str, ...]:
        # The fixture's claim as the decider recorded it: what the fixture names, else exactly the roles
        # its judges read (the census fixtures predate the claimed-role check).
        if "claimed_roles" in r:
            return tuple(r["claimed_roles"])
        return tuple(x["role"] for x in r.get("roles") or [])

    return pr.Ask(ask_id=bundle.get("conversation_id") or "ask",
                  conversation_id=bundle.get("conversation_id", ""),
                  account_h=bundle.get("contact_h") or "",
                  user_ids=tuple(bundle.get("user_ids") or ()),
                  documents=_documents(bundle.get("documents") or []),
                  requests=tuple(pr.RequestProof(request_id=r["request_id"],
                                                 user_id=(bundle.get("user_ids") or [None])[0],
                                                 roles=_roles(r.get("roles") or []),
                                                 dsp_anchor=r.get("dsp_anchor", "none"),
                                                 claimed_roles=_claimed(r))
                                 for r in bundle.get("requests") or []),
                  fraud_held=tuple(bundle.get("fraud_held") or ()))


# ── the precedence, arm by arm ───────────────────────────────────────────────
class PrecedenceCases(unittest.TestCase):
    def test_every_case_lands_on_its_arm(self):
        for case in CASES["cases"]:
            with self.subTest(case=case["name"]):
                ask = ask_of(case)
                if not ask.requests:
                    # An ask that names no request decides nothing, whatever the documents are.
                    rev = pr.review(ask)
                    self.assertEqual(rev.verdicts, ())
                    self.assertEqual(rev.state, "unfiled" if not ask.documents else "unknown")
                    continue
                rev = pr.review(ask)
                self.assertEqual([v.verdict for v in rev.verdicts], [case["expected"]] * len(ask.requests),
                                 f"{case['name']}: {[v.why for v in rev.verdicts]}")
                if case["why"]:
                    self.assertIn(case["why"], rev.verdicts[0].why, case["name"])

    def test_an_injection_hit_never_changes_the_verdict_rule(self):
        # A document whose text carries an instruction pattern is still just a document that
        # does not verify: it is reported on the card, never acted on, never a hold, never an
        # approval. (lib.injection_watch records the hit; detection only.)
        case = next(c for c in CASES["cases"] if c["name"].startswith("a document H3 read as an injection"))
        rev = pr.review(ask_of(case))
        self.assertEqual(rev.verdicts[0].verdict, pr.GAP_ASK)
        self.assertIn("injection:high", rev.card)
        self.assertNotIn("approv", rev.card.replace("approval", "X"))

    def test_screenshot_only_is_not_a_document_of_record(self):
        case = next(c for c in CASES["cases"] if c["name"].startswith("only screenshots"))
        ask = ask_of(case)
        self.assertTrue(all(d.screenshot_only for d in ask.documents))
        self.assertEqual(pr.review(ask).verdicts[0].verdict, pr.UVN_STATUS)

    def test_a_positive_shared_split_sheet_is_not_reuse(self):
        case = next(c for c in CASES["cases"] if c["name"].startswith("a co-writer split sheet"))
        ask = ask_of(case)
        self.assertIsNone(ask.documents[0].holding_reuse)
        self.assertEqual(pr.review(ask).verdicts[0].verdict, pr.SUFFICIENT)

    def test_the_latest_read_wins_in_both_directions(self):
        # doc-verify is read as the LATEST row per request x role, so a request whose later
        # read verified it is sufficient and one whose later read did not is not - the order of
        # the documents cannot matter (load_doc_verify already collapses to the latest row).
        db = _dv_fixture([("req", "Composer", "unverifiable"), ("req", "Composer", "verified")])
        got = pr.load_doc_verify(["req"], dv_db=db)[("req")]["Composer"]
        self.assertEqual(got.dv, "verified")
        db = _dv_fixture([("req", "Composer", "verified"), ("req", "Composer", "unverifiable")])
        self.assertEqual(pr.load_doc_verify(["req"], dv_db=db)["req"]["Composer"].dv, "unverifiable")

    def test_a_later_read_promotes_and_never_demotes(self):
        # Stage 2 read the first document need_more; the user sent a better one and doc-verify read
        # it verified LATER. The later read promotes the role.
        role = pr.RoleProof(role="Composer", stage2="need_more", stage2_at="2026-11-04T10:00:00Z",
                            dv="verified", dv_at="2026-11-04T12:00:00Z", proof_id="a" * 64,
                            stage2_proof_id="a" * 64)
        v = pr.request_verdict(
            pr.RequestProof("r", 1, (role,), dsp_anchor="both", claimed_roles=("Composer",)),
            (pr.Document("a" * 64),))
        self.assertEqual(v.verdict, pr.SUFFICIENT, v.why)
        # The mirror is NOT symmetric: stage 2 approved, and a LATER doc-verify read could not
        # verify the document. "We could not read it" is already a non-approval, so it buys no
        # safety - and demoting here would ask the user for proof that is already on file.
        role = pr.RoleProof(role="Composer", stage2="approve", stage2_at="2026-11-04T10:00:00Z",
                            dv="unverifiable", dv_at="2026-11-04T12:00:00Z", dv_need="split_sheet",
                            proof_id="a" * 64, stage2_proof_id="a" * 64)
        v = pr.request_verdict(
            pr.RequestProof("r", 1, (role,), dsp_anchor="both", claimed_roles=("Composer",)),
            (pr.Document("a" * 64),))
        self.assertEqual(v.verdict, pr.SUFFICIENT, v.why)
        # An OLDER verified read does not promote over a later need_more.
        role = pr.RoleProof(role="Composer", stage2="need_more", stage2_at="2026-11-04T12:00:00Z",
                            dv="verified", dv_at="2026-11-04T10:00:00Z")
        claim = ("Composer",)
        v = pr.request_verdict(pr.RequestProof("r", 1, (role,), dsp_anchor="both", claimed_roles=claim),
                               (pr.Document("a" * 64),))
        self.assertEqual(v.verdict, pr.GAP_ASK, v.why)
        # When the timestamps cannot order the two reads, stage 2 is the read: a missing doc-verify
        # time never promotes over a need_more.
        role = pr.RoleProof(role="Composer", stage2="need_more", stage2_at="2026-11-04T10:00:00Z",
                            dv="verified", dv_at="")
        v = pr.request_verdict(pr.RequestProof("r", 1, (role,), dsp_anchor="both", claimed_roles=claim),
                               (pr.Document("a" * 64),))
        self.assertEqual(v.verdict, pr.GAP_ASK, v.why)
        role = pr.RoleProof(role="Composer", stage2="need_more", stage2_at="",
                            dv="verified", dv_at="2026-11-04T12:00:00Z")
        v = pr.request_verdict(pr.RequestProof("r", 1, (role,), dsp_anchor="both", claimed_roles=claim),
                               (pr.Document("a" * 64),))
        self.assertEqual(v.verdict, pr.GAP_ASK, v.why)

    def test_a_partial_role_read_never_reads_as_every_claimed_role(self):
        # The request claims Composer and Producer; only the Composer row was ever written. The
        # judged list is all-supporting, which is exactly what a complete two-role read looks like -
        # so the claim, not the judged rows, decides: UNKNOWN, no ask, no approval.
        roles = (pr.RoleProof(role="Composer", stage2="approve", dv="verified", proof_id="a" * 64,
                              stage2_proof_id="a" * 64),)
        v = pr.request_verdict(
            pr.RequestProof("r", 1, roles, dsp_anchor="both", claimed_roles=("Composer", "Producer")),
            (pr.Document("a" * 64),))
        self.assertEqual(v.verdict, pr.UNKNOWN, v.why)
        self.assertIn("Producer", v.why)
        # The same request with both roles read is sufficient.
        both = roles + (pr.RoleProof(role="Producer", stage2="approve", dv="verified", proof_id="a" * 64,
                                     stage2_proof_id="a" * 64),)
        v = pr.request_verdict(
            pr.RequestProof("r", 1, both, dsp_anchor="both", claimed_roles=("Composer", "Producer")),
            (pr.Document("a" * 64),))
        self.assertEqual(v.verdict, pr.SUFFICIENT, v.why)
        # A claim the decider never recorded cannot be checked, so it approves nothing.
        v = pr.request_verdict(pr.RequestProof("r", 1, roles, dsp_anchor="both"), (pr.Document("a" * 64),))
        self.assertEqual(v.verdict, pr.UNKNOWN, v.why)
        self.assertIn("not recorded", v.why)
        # An incomplete read whose evidence is NOT supporting still asks (nothing is approved there).
        ask_roles = (pr.RoleProof(role="Composer", dv="unverifiable", dv_need="split_sheet"),)
        v = pr.request_verdict(
            pr.RequestProof("r", 1, ask_roles, dsp_anchor="both", claimed_roles=("Composer", "Producer")),
            (pr.Document("a" * 64),))
        self.assertEqual(v.verdict, pr.GAP_ASK, v.why)

    def test_an_injection_hit_cannot_support_a_role(self):
        # A document whose extracted text carries an instruction pattern is unverifiable whatever
        # doc-verify read it as: the gap ask, never sufficient, never a hold.
        doc = pr.Document("a" * 64, injection="high")
        role = pr.RoleProof(role="Composer", dv="verified", proof_id="a" * 64,
                            dv_need="readable_document")
        v = pr.request_verdict(pr.RequestProof("r", 1, (role,), dsp_anchor="both"), (doc,))
        self.assertEqual(v.verdict, pr.GAP_ASK, v.why)
        self.assertIn("injection_hit", v.why)
        # ... and stage 2 read the same (tainted) document, so its `approve` cannot cover the role
        # either: the two judges read the same text, and tainted text supports nothing.
        for dv in ("verified", ""):
            role = pr.RoleProof(role="Composer", stage2="approve", dv=dv, proof_id="a" * 64)
            v = pr.request_verdict(pr.RequestProof("r", 1, (role,), dsp_anchor="both"), (doc,))
            self.assertEqual(v.verdict, pr.GAP_ASK, f"dv={dv!r}: {v.why}")
            self.assertIn("injection_hit", v.why)
        # An approval resting on an UNTAINTED document is untouched.
        role = pr.RoleProof(role="Composer", stage2="approve", dv="verified", proof_id="b" * 64,
                            stage2_proof_id="b" * 64)
        v = pr.request_verdict(pr.RequestProof("r", 1, (role,), dsp_anchor="both",
                                               claimed_roles=("Composer",)),
                               (doc, pr.Document("b" * 64)))
        self.assertEqual(v.verdict, pr.SUFFICIENT, v.why)

    def test_a_tainted_document_can_neither_approve_nor_deny(self):
        # A document whose text carries an instruction pattern must not be able to build an
        # autonomous DENY either: `contradicted` from tainted text is unverifiable, the gap ask.
        doc = pr.Document("a" * 64, injection="high")
        role = pr.RoleProof(role="Composer", dv="contradicted", proof_id="a" * 64,
                            dv_need="readable_document")
        v = pr.request_verdict(pr.RequestProof("r", 1, (role,), dsp_anchor="both"), (doc,))
        self.assertEqual(v.verdict, pr.GAP_ASK, v.why)
        self.assertIn("injection_hit", v.why)
        # A forged read is a HOLD and stays one: neutralizing it would weaken a fail-closed signal.
        role = pr.RoleProof(role="Composer", dv="forged", proof_id="a" * 64)
        v = pr.request_verdict(pr.RequestProof("r", 1, (role,), dsp_anchor="both"), (doc,))
        self.assertEqual(v.verdict, pr.HOLD, v.why)

    def test_a_stage2_hold_wins_over_a_contradicted_document(self):
        # A contradicted document with an applicable stage-2 hold must HOLD, not decline: a row that
        # should pause for a human is never refused to the customer.
        for held in ("reject_hold", "review", "human"):
            roles = (pr.RoleProof(role="Composer", dv="contradicted", proof_id="a" * 64),
                     pr.RoleProof(role="Lyricist", stage2=held))
            v = pr.request_verdict(pr.RequestProof("r", 1, roles, dsp_anchor="both"),
                                   (pr.Document("a" * 64),))
            self.assertEqual(v.verdict, pr.HOLD, f"{held}: {v.why}")
            self.assertIn(held, v.why)

    def test_the_loaders_carry_the_time_of_each_read(self):
        db = _dv_fixture([("req", "Composer", "verified")])
        self.assertEqual(pr.load_doc_verify(["req"], dv_db=db)["req"]["Composer"].dv_at, "2026-11-04T00:00:00Z")

    def test_unreadable_twice_reads_as_no_document_and_once_does_not(self):
        db = _dv_fixture([("req", "Composer", "unknown"), ("req", "Composer", "unknown")])
        got = pr.load_doc_verify(["req"], dv_db=db)["req"]["Composer"]
        self.assertEqual((got.dv, got.unknown_runs), ("unknown", 2))
        role = pr.RoleProof(role="Composer", dv="unknown", unknown_runs=1)
        v = pr.request_verdict(pr.RequestProof("r", 1, (role,)), (pr.Document("a" * 64),))
        self.assertEqual(v.verdict, pr.UNKNOWN)
        role2 = pr.RoleProof(role="Composer", dv="unknown", unknown_runs=2)
        self.assertEqual(pr.request_verdict(pr.RequestProof("r", 1, (role2,)), (pr.Document("a" * 64),)).verdict,
                         pr.UVN_STATUS)

    def test_an_all_unknown_review_is_not_an_answer_and_stays_open(self):
        case = next(c for c in CASES["cases"]
                    if c["name"] == "unreadable ONCE is unknown: no ask, no approval")
        rev = pr.review(ask_of(case))
        self.assertEqual([v.verdict for v in rev.verdicts], [pr.UNKNOWN])
        self.assertEqual((rev.state, rev.campaign), ("ask", "uvn-status"))
        self.assertEqual(rev.sent, "none")
        self.assertIn("sent: none", rev.card)


def _dv_fixture(rows: list[tuple[str, str, str]]) -> str:
    """A doc-verify store with these (request, role, outcome) rows in insert order."""
    d = tempfile.mkdtemp(prefix="proof-review-dv-")
    path = os.path.join(d, "dv.sqlite")
    import sqlite3
    db = sqlite3.connect(path)
    db.executescript(
        "CREATE TABLE dv_outcomes (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL, at TEXT NOT NULL,"
        " proof_id TEXT NOT NULL, request_id TEXT NOT NULL, role TEXT NOT NULL, user_id INTEGER, source_ref TEXT,"
        " h3_verdict TEXT, outcome TEXT NOT NULL, reason TEXT NOT NULL, need TEXT,"
        " account_hold INTEGER NOT NULL DEFAULT 0, detail_json TEXT NOT NULL, version TEXT NOT NULL);")
    for i, (rid, role, outcome) in enumerate(rows):
        db.execute("INSERT INTO dv_outcomes (run_id, at, proof_id, request_id, role, outcome, reason, detail_json,"
                   " version) VALUES (?,?,?,?,?,?,?,?,?)",
                   ("r", "2026-11-04T00:00:00Z", f"{i:064x}", rid, role, outcome, "why", "{}", "v"))
    db.commit()
    db.close()
    return path


# ── the census: every real ask yields its card ───────────────────────────────
class CensusAsks(unittest.TestCase):
    def test_every_census_ask_produces_the_expected_card(self):
        self.assertTrue(CENSUS["asks"])
        for bundle in CENSUS["asks"]:
            with self.subTest(conversation=bundle["conversation_id"][:24]):
                exp = bundle["expected"]
                rev = pr.review(ask_of(bundle))
                self.assertEqual(rev.counts, exp["counts"], bundle["expected"].get("note", ""))
                self.assertEqual(rev.state, exp["state"])
                self.assertEqual(rev.campaign, exp["campaign"])
                self.assertEqual(sum(rev.counts.values()), len(bundle["requests"]))

    def test_the_11_04_six_agree_or_say_why_they_do_not(self):
        # Each of the six verdicts firstmate hand-posted on 2026-11-04 18:48-18:49Z (census §5)
        # is either reproduced by the coded rule or carries a recorded reason for the difference.
        six = [b for b in CENSUS["asks"] if "human_2026_11_04" in b["expected"]
               and b["expected"]["human_2026_11_04"] != "none (this case is not one of Jan's asks)"]
        self.assertGreaterEqual(len(six), 6)
        for bundle in six:
            note = bundle["expected"]["note"]
            agree = note.startswith("MATCHES")
            diverge = note.startswith("DIVERGES")
            self.assertTrue(agree or diverge, f"{bundle['conversation_id']}: say MATCHES or DIVERGES")
            if diverge:
                self.assertTrue(note.strip())

    def test_the_reuse_case_holds_and_sends_nothing(self):
        bundle = next(b for b in CENSUS["asks"] if b["conversation_id"] == "215476642230886")
        rev = pr.review(ask_of(bundle))
        self.assertEqual(rev.counts[pr.HOLD], 31)
        self.assertEqual(rev.campaign, "")
        self.assertIn("another account already sent", rev.verdicts[0].why)
        self.assertIn("shared_document_claimant_undetermined/info", rev.card)

    def test_the_mixed_case_counts_the_unknowns_and_still_asks(self):
        bundle = next(b for b in CENSUS["asks"] if b["conversation_id"] == "215476433322735")
        rev = pr.review(ask_of(bundle))
        self.assertEqual((rev.counts[pr.GAP_ASK], rev.counts[pr.UVN_STATUS], rev.counts[pr.UNKNOWN]), (4, 44, 12))
        self.assertEqual(rev.campaign, "gap-ask")
        self.assertIn("12 unknown", rev.card)

    def test_an_unfiled_ask_says_so_instead_of_rendering_a_zero(self):
        for conv in ("215476629616641", "215476495717959"):
            rev = pr.review(ask_of(next(b for b in CENSUS["asks"] if b["conversation_id"] == conv)))
            self.assertEqual(rev.state, "unfiled")
            self.assertIn("nothing is filed", rev.gate_reason)
            self.assertIn("0 requests", rev.card)


# ── the card contract ────────────────────────────────────────────────────────
class Card(unittest.TestCase):
    def setUp(self):
        self.rev = pr.review(ask_of(next(b for b in CENSUS["asks"]
                                         if b["conversation_id"] == "215476650000000"
                                         or b["conversation_id"] == "215476665383647")))

    def test_the_shape_j2_asked_for(self):
        card = self.rev.card
        for field in ("proof-review", "acct ", " requests:", " sufficient / ", " gap-ask / ", " uvn-status / ",
                      " hold / ", " contradicted", " documents:", " sent: ", " ledger "):
            self.assertIn(field, card, card)
        self.assertNotIn("\n", card)

    def test_no_approval_word_without_a_ledger_row(self):
        self.assertNotIn("approv", self.rev.card.lower())

    def test_the_word_is_refused_even_if_someone_adds_it(self):
        ask = ask_of(next(b for b in CENSUS["asks"] if b["conversation_id"] == "215476472196994"))
        rev = pr.review(ask)
        rev.ledger = "none"
        rev.gate_reason = "approved by the captain"
        with self.assertRaises(pr.ProofReviewError):
            pr.render_card(rev)
        # ... and a decision ledger row is what licenses the word.
        rev.decision = "0db01148@2026-11-04T19:00:00Z"
        self.assertIn("approv", pr.render_card(rev).lower())

    def test_no_account_name_email_or_professional_id_on_the_card(self):
        for bundle in CENSUS["asks"]:
            rev = pr.review(ask_of(bundle))
            card = rev.card
            for forbidden in ("@", "user_id", "104776", "127169", "Jose", "Sudduth"):
                self.assertNotIn(forbidden, card)
            self.assertRegex(card, r"acct (unknown|[0-9a-f]{8})")

    def test_the_hash_never_falls_back_to_a_name(self):
        self.assertEqual(len(pr._account_h([42])), 16)
        self.assertNotIn("42", pr._account_h([42]))


# ── the next coded step, and the sender it never replaces ────────────────────
class NextStep(unittest.TestCase):
    def _filed(self, bundle):
        conv = bundle.get("conversation_id") or ""
        users = bundle.get("user_ids") or ()
        if conv and users:
            old = pr.PROOF_DB
            pr.PROOF_DB = _proof_fixture([("a" * 64, int(users[0]), conv, "")], {}, {})
            self.addCleanup(setattr, pr, "PROOF_DB", old)

    def _apply(self, bundle, **kw):
        rev_ask = ask_of(bundle)
        self._filed(bundle)
        store = pr.ReviewStore(os.path.join(tempfile.mkdtemp(prefix="proof-review-store-"), "s.sqlite"))
        self.addCleanup(store.close)
        sent: list[tuple[str, int, str]] = []
        rev = pr.run(rev_ask, store=store, mode="apply",
                     sender=lambda c, u, s: (sent.append((c, u, s)) or ("none", "gate: not released")), **kw)
        return rev, sent, store

    def test_dry_run_sends_nothing_and_writes_nothing(self):
        bundle = next(b for b in CENSUS["asks"] if b["conversation_id"] == "215476472196994")
        store = pr.ReviewStore(os.path.join(tempfile.mkdtemp(), "s.sqlite"))
        self.addCleanup(store.close)
        calls = []
        rev = pr.run(ask_of(bundle), store=store, mode="dry-run", sender=lambda *a: calls.append(a))
        self.assertEqual(calls, [])
        self.assertEqual(store.board(), [])
        self.assertEqual(rev.campaign, "gap-ask")

    def test_apply_names_the_campaign_and_never_builds_a_message(self):
        bundle = next(b for b in CENSUS["asks"] if b["conversation_id"] == "215476665383647")
        rev, sent, store = self._apply(bundle, segment="paid")
        self.assertEqual(sent, [("gap-ask", 103302, "paid")])
        self.assertEqual(rev.sent, "none")            # the sender refused; nothing was sent
        self.assertIn("not released", rev.gate_reason)
        self.assertEqual(len(store.board()), 1)

    def test_a_hold_sends_nothing_even_in_apply_mode(self):
        bundle = next(b for b in CENSUS["asks"] if b["conversation_id"] == "215476642230886")
        rev, sent, _ = self._apply(bundle)
        self.assertEqual(sent, [])
        self.assertEqual(rev.state, "hold")

    def test_an_all_unknown_ask_is_handed_uvn_status_and_claims_no_send(self):
        bundle = {
            "conversation_id": "215476444480749", "user_ids": [103302],
            "documents": [{"proof_id": "f" * 64}],
            "requests": [{"request_id": "req-unk1",
                          "roles": [{"role": "Producer", "dv": "unknown", "unknown_runs": 1}]}],
        }
        rev, sent, store = self._apply(bundle, segment="paid")
        self.assertEqual(sent, [("uvn-status", 103302, "paid")])
        self.assertEqual((rev.state, rev.campaign), ("ask", "uvn-status"))
        self.assertEqual(rev.sent, "none")      # the stub sender reports nothing sent
        self.assertIn("sent: none", rev.card)
        self.assertEqual(store.board()[0]["state"], "ask")

    def test_a_sufficient_ask_waits_for_a_route_and_sends_nothing(self):
        bundle = next(b for b in CENSUS["asks"] if b["conversation_id"].startswith("(none"))
        rev, sent, _ = self._apply(bundle, segment="paid")
        # This real case still carries an open gap for three of its five claimed roles, so the
        # coded step is the gap ask - and the ask is the ONLY thing that happens.
        self.assertEqual(sent, [("gap-ask", 66747, "paid")])
        self.assertEqual(rev.state, "asked")
        # ... and a purely sufficient one:
        case = next(c for c in CASES["cases"] if c["name"].startswith("every role supported and a"))
        rev2, sent2, _ = self._apply(case)
        self.assertEqual(sent2, [])
        self.assertEqual(rev2.state, "waiting_route")
        self.assertTrue(rev2.ledger.startswith("card:"), rev2.ledger)   # this card's own ledger row
        self.assertEqual(rev2.decision, "none")                          # no decision was recorded
        self.assertNotIn("approv", rev2.card.lower())

    def test_the_per_account_daily_card_cap(self):
        bundle = next(b for b in CENSUS["asks"] if b["conversation_id"] == "215476472196994")
        self._filed(bundle)
        store = pr.ReviewStore(os.path.join(tempfile.mkdtemp(), "s.sqlite"))
        self.addCleanup(store.close)
        sent = []
        for _ in range(4):
            pr.run(ask_of(bundle), store=store, mode="apply", segment="paid",
                   sender=lambda c, u, s: (sent.append(c) or ("none", "x")))
        self.assertEqual(len(sent), 3, "the fourth card in one UTC day must not page the lane again")
        self.assertEqual(len(store.board()), 3)

    def test_the_kill_switch_stops_every_send(self):
        d = tempfile.mkdtemp()
        kill = os.path.join(d, "credit-verify.disabled")
        Path(kill).write_text("")
        old = pr.KILL_SWITCH
        pr.KILL_SWITCH = kill
        try:
            bundle = next(b for b in CENSUS["asks"] if b["conversation_id"] == "215476472196994")
            rev, sent, _ = self._apply(bundle)
        finally:
            pr.KILL_SWITCH = old
        self.assertEqual(sent, [])
        self.assertIn("kill switch", rev.gate_reason)

    def test_only_the_two_ask_campaigns_exist(self):
        with self.assertRaises(pr.ProofReviewError):
            pr.send_campaign("verify-live", 1, "paid", runner=lambda a: (0, "x"))

    def test_an_ask_covering_two_accounts_is_refused_not_half_sent(self):
        bundle = next(b for b in CENSUS["asks"] if b["conversation_id"] == "215476665383647")
        both = dataclasses.replace(ask_of(bundle), user_ids=(103302, 66747))
        store = pr.ReviewStore(os.path.join(tempfile.mkdtemp(prefix="proof-review-store-"), "s.sqlite"))
        self.addCleanup(store.close)
        sent: list[tuple[str, int, str]] = []
        rev = pr.run(both, store=store, mode="apply", segment="paid",
                     sender=lambda c, u, s: (sent.append((c, u, s)) or (c, "")))
        self.assertEqual(sent, [], "the sender takes one account; a two-account ask is a person's to split")
        self.assertEqual(rev.sent, "none")
        self.assertIn("2 accounts", rev.gate_reason)
        self.assertIn("split", rev.gate_reason)
        self.assertNotIn("sent: gap-ask", rev.card)
        self.assertEqual(len(store.board()), 1)

    def test_apply_refuses_an_account_that_does_not_own_the_conversation(self):
        bundle = next(b for b in CENSUS["asks"] if b["conversation_id"] == "215476665383647")
        proof = _proof_fixture([("a" * 64, 66747, "215476665383647", "")], {}, {})
        old = pr.PROOF_DB
        pr.PROOF_DB = proof
        self.addCleanup(setattr, pr, "PROOF_DB", old)
        store = pr.ReviewStore(os.path.join(tempfile.mkdtemp(prefix="proof-review-store-"), "s.sqlite"))
        self.addCleanup(store.close)
        sent: list[tuple[str, int, str]] = []
        rev = pr.run(ask_of(bundle), store=store, mode="apply", segment="paid",
                     sender=lambda c, u, s: (sent.append((c, u, s)) or (c, "")))
        self.assertEqual(sent, [], "unknown is a refusal")
        self.assertEqual(rev.sent, "none")
        self.assertIn("another account", rev.gate_reason)

    def test_the_segment_is_the_accounts_own_paid_flag(self):
        from credit_review import stage2_verdicts
        pop = [{"user_id": 7, "paid": False, "skip": None, "request_ids": ["r"]},
               {"user_id": 8, "paid": True, "skip": None, "request_ids": ["r2"]}]
        with unittest.mock.patch.object(stage2_verdicts, "population", return_value=pop):
            self.assertEqual(pr._segment_for("gap-ask", 7), ("free", ""))
            self.assertEqual(pr._segment_for("gap-ask", 8), ("paid", ""))
            seg, why = pr._segment_for("gap-ask", 9)
        self.assertIsNone(seg)
        self.assertIn("not in the gap-ask population", why)

    def test_a_send_is_reported_only_on_the_senders_own_record(self):
        from credit_review import stage2_verdicts
        old = pr.STATE_DIR
        pr.STATE_DIR = tempfile.mkdtemp(prefix="proof-review-send-")
        self.addCleanup(setattr, pr, "STATE_DIR", old)

        def runner(sent):
            def run(argv):
                Path(argv[argv.index("--outcomes-json") + 1]).write_text(
                    json.dumps({"sent": sent}), encoding="utf-8")
                return 0, "NOTHING sent: nobody was offered"
            return run

        with unittest.mock.patch.object(stage2_verdicts, "population", return_value=[]):
            self.assertEqual(pr.send_campaign("gap-ask", 7, "paid", runner=runner([])),
                             ("none", "NOTHING sent: nobody was offered"))
            self.assertEqual(pr.send_campaign("gap-ask", 7, "paid",
                                              runner=runner([{"user": "7", "campaign": "gap-ask"}])),
                             ("gap-ask", "NOTHING sent: nobody was offered"))
            # QA on #1945: a run that messaged somebody else never reads as this account's send.
            self.assertEqual(pr.send_campaign("gap-ask", 7, "paid",
                                              runner=runner([{"user": "8", "campaign": "gap-ask"}])),
                             ("none", "sender reported another account (8), not 7"))
            self.assertEqual(pr.send_campaign("gap-ask", 7, "paid",
                                              runner=runner([{"user": "7", "campaign": "gap-ask"},
                                                             {"user": "8", "campaign": "gap-ask"}])),
                             ("none", "sender reported another account (8), not 7"))

    def test_the_sender_is_scoped_positively_to_the_requested_account(self):
        old = pr.STATE_DIR
        pr.STATE_DIR = tempfile.mkdtemp(prefix="proof-review-send-")
        self.addCleanup(setattr, pr, "STATE_DIR", old)
        seen = {}

        def runner(argv):
            # What the sender itself is given: the population filter names our account, and the
            # exclusion snapshot (the unsound inverse) is gone.
            seen["only-users"] = Path(argv[argv.index("--only-users") + 1]).read_text().split()
            seen["has-exclude"] = "--exclude-users" in argv
            Path(argv[argv.index("--outcomes-json") + 1]).write_text(
                json.dumps({"sent": [{"user": "7", "campaign": "gap-ask"}]}), encoding="utf-8")
            return 0, "GAP ASK (paid): 1 sent"

        self.assertEqual(pr.send_campaign("gap-ask", 7, "paid", runner=runner),
                         ("gap-ask", "GAP ASK (paid): 1 sent"))
        self.assertEqual(seen, {"only-users": ["7"], "has-exclude": False})


class ResolverStep(unittest.TestCase):
    def test_filing_shells_out_to_the_filer_and_never_to_a_judge(self):
        seen = []

        def runner(argv):
            seen.append(argv)
            return 0, "filed 2"

        old = pr.STATE_DIR
        pr.STATE_DIR = tempfile.mkdtemp(prefix="proof-review-state-")
        self.addCleanup(setattr, pr, "STATE_DIR", old)
        ok, why = pr.file_conversation("215476472196994", runner=runner)
        self.assertTrue(ok)
        self.assertEqual(why, "filed 2")
        self.assertEqual(len(seen), 1)
        argv = seen[0]
        self.assertIn("credit-proof.py", argv[1])
        self.assertEqual(argv[2:4], ["file", "--conversations"])
        self.assertIn("--apply", argv)
        # No metered model call and no doc-verify run: that read stays with its own cron.
        self.assertFalse(any("credit-doc-verify" in a or "credit_trust" in a for a in argv))
        # The temp conversation list is 0600 and is removed again.
        self.assertFalse(os.path.exists(argv[argv.index("--conversations") + 1]))


class Route(unittest.TestCase):
    def test_missing_malformed_or_unknown_reads_off(self):
        d = tempfile.mkdtemp()
        self.assertEqual(pr.route_mode(os.path.join(d, "absent.json")), "off")
        for body in ("not json", "{}", '{"approval_route": {"mode": "yes"}}', '{"approval_route": "on"}'):
            p = Path(d) / "p.json"
            p.write_text(body)
            self.assertEqual(pr.route_mode(str(p)), "off", body)

    def test_no_lens_is_offline_and_does_not_guess_a_hold(self):
        case = next(c for c in CASES["cases"] if c["name"].startswith("every role supported and a"))
        ask = pr.build_ask(ask_id="offline", user_ids=(), request_ids=(), lens=None)
        self.assertEqual(ask.fraud_held, ())            # no accounts to hold
        rev = pr.review(ask_of(case))
        self.assertEqual(rev.verdicts[0].verdict, pr.SUFFICIENT)

    def test_the_committed_policy_is_off(self):
        self.assertEqual(pr.route_mode(), "off")
        doc = json.loads((ROOT / "policies" / "proof-review-route.json").read_text())
        self.assertEqual(doc["approval_route"]["mode"], "off")
        self.assertIsNone(doc["approval_route"]["enabled_by"])

    def test_sufficient_never_sends_even_with_the_route_on(self):
        # `on` does not approve: this lane has no approval writer, so the ask still waits.
        bundle = next(b for b in CENSUS["asks"] if "human_2026_11_04" in b["expected"]
                      and b["expected"]["state"] == "asked")
        role = pr.RoleProof(role="Composer", stage2="approve", stage2_proof_id="b" * 64)
        ask = pr.Ask(ask_id="route-on", account_h="a" * 8, user_ids=(7,), route="on",
                     documents=(pr.Document("b" * 64),),
                     requests=(pr.RequestProof("r1", 7, (role,), dsp_anchor="both",
                                               claimed_roles=("Composer",)),))
        rev = pr.review(ask)
        self.assertEqual(rev.state, "waiting_route")
        self.assertEqual(rev.campaign, "")
        self.assertTrue(bundle)                        # the census fixture still pins the live cases


# ── the facts come from the stores, never from a document's text ─────────────
class Loaders(unittest.TestCase):
    def test_documents_carry_h3_reuse_and_kind_and_ignore_unknown_kind(self):
        path = _proof_fixture([
            ("a" * 64, 7, "conv1", "c" * 40),
            ("b" * 64, 7, "conv1", None),
        ], {"a" * 64: ("shared_document_claimant_undetermined", "info"),
            "b" * 64: ("reupload_same_account", "info")},
            {"a" * 64: "catalog_page", "b" * 64: "unknown"})
        docs = pr.load_documents([7], proof_db=path)
        self.assertEqual([d.proof_id for d in docs], ["a" * 64, "b" * 64])
        self.assertEqual(docs[0].doc_kind, "catalog_page")
        self.assertEqual(docs[1].doc_kind, "")          # `unknown` is not a kind
        self.assertIsNotNone(docs[0].holding_reuse)
        self.assertIsNone(docs[1].holding_reuse)         # this account's own re-upload is not reuse

    def test_an_unreadable_store_refuses_instead_of_guessing(self):
        with self.assertRaises(pr.ProofReviewError):
            pr.load_documents([7], proof_db="/nonexistent/proof.sqlite")

    def test_the_same_document_in_two_conversations_is_one_document(self):
        # One sha filed in two conversations is one document on file: the card must not list it
        # twice, and its reuse signal must survive the merge.
        path = _proof_fixture([("a" * 64, 7, "conv2", None), ("a" * 64, 8, "conv1", None)],
                              {"a" * 64: ("shared_document_claimant_undetermined", "info")}, {})
        docs = pr.load_documents([7, 8], proof_db=path)
        self.assertEqual([d.proof_id for d in docs], ["a" * 64])
        self.assertEqual(docs[0].conversation_id, "conv1")
        self.assertIsNotNone(docs[0].holding_reuse)

    def test_an_unreadable_injection_ledger_refuses_instead_of_reading_quiet(self):
        # `recent_hits` answers [] for a failed read unless told to raise, and [] is
        # indistinguishable from a quiet day: the taint set must never be silently empty.
        with self.assertRaises(pr.ProofReviewError):
            pr.injection_hits([pr.Document("a" * 64)], ledger=Path("/nonexistent/injection.jsonl"))

    def test_the_injection_window_starts_at_the_oldest_document(self):
        # The ledger cuts on the real clock, so the fixture is built against it: a fixed date
        # would go red on a calendar day rather than on a change in the window logic.
        now = pr.utcnow()
        ledger = _injection_ledger([(_ago(100), "a" * 64, "high")])
        old = pr.Document("a" * 64, filed_at=_ago(200))
        self.assertEqual(pr.injection_hits([old], ledger=ledger, now=now), {"a" * 64: "high"})
        fresh = pr.Document("a" * 64, filed_at=_ago(1))
        self.assertEqual(pr.injection_hits([fresh], ledger=ledger, now=now), {})

    def test_a_document_that_cannot_be_dated_means_no_bound(self):
        # One undated document beside a dated one must not shorten the window to the dated one's
        # age: an old hit on the undated document would fall outside the cut and stop tainting it.
        now = pr.utcnow()
        ledger = _injection_ledger([(_ago(100), "a" * 64, "high")])
        docs = [pr.Document("a" * 64, filed_at=""), pr.Document("b" * 64, filed_at=_ago(1))]
        self.assertEqual(pr.injection_hits(docs, ledger=ledger, now=now), {"a" * 64: "high"})

    def test_a_duplicate_filing_keeps_the_earliest_stamp(self):
        # The same sha filed twice: the stamp is the earliest filing, not the one from the lowest
        # conversation id, or a later duplicate would shorten the injection window.
        path = _proof_fixture([("a" * 64, 7, "100", None, "2026-11-10T00:00:00Z"),
                               ("a" * 64, 7, "200", None, "2026-10-01T00:00:00Z")], {}, {})
        docs = pr.load_documents([7], proof_db=path)
        self.assertEqual([d.proof_id for d in docs], ["a" * 64])
        self.assertEqual(docs[0].conversation_id, "100")
        self.assertEqual(docs[0].filed_at, "2026-10-01T00:00:00Z")

    def test_an_undated_duplicate_keeps_the_filing_time_unknown(self):
        # The same sha filed undated in one conversation and dated in another: the dated row must not
        # stand in for the undated one, or the injection window shrinks to a time the document was
        # never known to be on file at, and an older hit on it stops counting.
        path = _proof_fixture([("a" * 64, 7, "100", None, ""),
                               ("a" * 64, 7, "200", None, "2026-11-10T00:00:00Z")], {}, {})
        docs = pr.load_documents([7], proof_db=path)
        self.assertEqual([d.proof_id for d in docs], ["a" * 64])
        self.assertEqual(docs[0].filed_at, "")
        ledger = _injection_ledger([(_ago(24 * 500), "a" * 64, "high")])
        self.assertEqual(pr.injection_hits(docs, ledger=ledger), {"a" * 64: "high"})

    def test_an_unchecked_injection_ledger_holds_every_request(self):
        # "We could not check these documents for injection" is a system fault, not a gap in the
        # customer's proof: hold, never ask them to re-send what they already sent.
        path = _proof_fixture([("a" * 64, 7, "conv1", None)], {}, {})
        dv = _dv_fixture([("req", "Composer", "verified")])
        with unittest.mock.patch.object(pr, "injection_hits",
                                        side_effect=pr.ProofReviewError("the injection ledger could not be read: "
                                                                        "OSError: gone")):
            ask = pr.build_ask(ask_id="inj", user_ids=[7], request_ids=["req"], proof_db=path, dv_db=dv,
                               lens=lambda ids: {u: _Lens([], []) for u in ids})
        rev = pr.review(ask)
        self.assertEqual(rev.verdicts[0].verdict, pr.HOLD, rev.verdicts[0].why)
        self.assertIn("injection check could not run", rev.verdicts[0].why)
        self.assertEqual(rev.campaign, "")

    def test_a_store_this_reader_cannot_query_refuses_instead_of_escaping(self):
        # A partial migration leaves proof_intake in place but forensics gone; the module's contract
        # is that every broken store raises its own error, so the router can page instead of the
        # turn dying on a raw sqlite error.
        path = _proof_fixture([("a" * 64, 7, "conv", "")], {}, {})
        db = sqlite3.connect(path)
        db.execute("DROP TABLE forensics")
        db.commit()
        db.close()
        with self.assertRaises(pr.ProofReviewError) as caught:
            pr.load_documents([7], proof_db=path)
        self.assertIn("forensics", str(caught.exception))
        self.assertEqual(pr._filed_accounts("conv", proof_db=path), [7])

    def test_a_stage2_store_that_is_there_and_unreadable_refuses(self):
        # No store at all is no evidence (doc-verify alone decides); a store that is there and
        # unreadable is a broken reader, and falling back would drop a recorded reject_hold.
        d = tempfile.mkdtemp(prefix="proof-review-s2-")
        self.assertEqual(pr.load_stage2(["r"], proof_db=os.path.join(d, "absent.sqlite")), {})
        broken = os.path.join(d, "broken.sqlite")
        Path(broken).write_text("not a database")
        with self.assertRaises(pr.ProofReviewError):
            pr.load_stage2(["r"], proof_db=broken)
        # A store stage 2 has never written to is no evidence, not a broken reader.
        empty = os.path.join(d, "empty.sqlite")
        import sqlite3
        sqlite3.connect(empty).close()
        self.assertEqual(pr.load_stage2(["r"], proof_db=empty), {})
        # ... but a stage2_shadow table this reader cannot read is a broken reader.
        drifted = os.path.join(d, "drifted.sqlite")
        db = sqlite3.connect(drifted)
        db.execute("CREATE TABLE stage2_shadow (id INTEGER PRIMARY KEY)")
        db.commit()
        db.close()
        with self.assertRaises(pr.ProofReviewError):
            pr.load_stage2(["r"], proof_db=drifted)

    def test_only_the_current_analyzer_version_is_read(self):
        # `forensics` is append-only and versioned: a re-analysis under the current version is the
        # read, so an older HARD reuse row it cleared no longer holds, and the latest kind wins.
        path = _proof_fixture([("a" * 64, 7, "conv1", "c" * 40)], {}, {})
        _forensics_rows(path, [
            ("a" * 64, "pf-1", "F2", "reused_by_another_account", "hard", None),
            ("a" * 64, "pf-1", "F5a", "document_kind", "info", {"kind": "catalog_page"}),
            ("a" * 64, pr._forensics_version(), "F5a", "document_kind", "info", {"kind": "contract"}),
        ])
        doc = pr.load_documents([7], proof_db=path)[0]
        self.assertIsNone(doc.holding_reuse)
        self.assertEqual(doc.doc_kind, "contract")
        # A current-version HARD reuse row still holds, and the latest kind of that version wins.
        _forensics_rows(path, [
            ("a" * 64, pr._forensics_version(), "F2", "reused_by_another_account", "hard", None),
            ("a" * 64, pr._forensics_version(), "F5a", "document_kind", "info", {"kind": "daw_session"}),
        ])
        doc = pr.load_documents([7], proof_db=path)[0]
        self.assertIsNotNone(doc.holding_reuse)
        self.assertEqual(doc.doc_kind, "daw_session")

    def test_a_reverted_approval_no_longer_licenses_the_word(self):
        self.assertTrue(pr.ledger_row(["r1"], ledger=_ledger_fixture([("r1", "approve", "approved")])))
        self.assertEqual(pr.ledger_row(["r1"], ledger=_ledger_fixture(
            [("r1", "approve", "approved"), ("r1", "revert", "unverified")])), "")
        # A take-back the server refused leaves the approval standing.
        self.assertTrue(pr.ledger_row(["r1"], ledger=_ledger_fixture(
            [("r1", "approve", "approved"), ("r1", "revert", "skipped:needs_human_review")])))
        # A re-approval after a successful take-back stands again.
        self.assertTrue(pr.ledger_row(["r1"], ledger=_ledger_fixture(
            [("r1", "approve", "approved"), ("r1", "revert", "unverified"),
             ("r1", "approve", "approved")])))

    def test_a_lens_that_cannot_be_built_holds_every_account(self):
        from unittest import mock
        with mock.patch("credit_review.fraud_lens.default_lens", side_effect=ValueError("watchlist missing")):
            lens = pr._real_lens()          # building it must not raise past the fail-closed guard
            held = pr.load_fraud_lens([5], lens)
        self.assertIn("fraud lens unavailable (ValueError)", held[5][0][0])

    def test_a_conversation_filed_under_another_account_is_refused(self):
        path = _proof_fixture([("a" * 64, 7, "conv1", "c" * 40)], {}, {})
        # collision_owner reads the configured store; drive it through the env instead.
        old = pr.PROOF_DB
        pr.PROOF_DB = path
        try:
            self.assertEqual(pr.collision_owner(7, "conv1"), (True, ""))
            ok, why = pr.collision_owner(8, "conv1")
            self.assertFalse(ok)
            self.assertIn("another account", why)
            self.assertEqual(pr.collision_owner(8, "conv-unknown"), (True, ""))
        finally:
            pr.PROOF_DB = old

    def test_the_claimed_roles_come_from_the_deciders_latest_row(self):
        path = _decisions_fixture([("r1", "Composer"), ("r1", "Composer,Producer"), ("r2", "")])
        self.assertEqual(pr.load_claimed_roles(["r1", "r2", "r3"], ledger=path),
                         {"r1": ("Composer", "Producer")})
        # A ledger that is not there records no claim: that approves nothing, it does not raise.
        self.assertEqual(pr.load_claimed_roles(["r1"], ledger=os.path.join(path, "nope")), {})
        # A ledger without the table (an older writer) is the same absence.
        self.assertEqual(pr.load_claimed_roles(["r1"], ledger=_ledger_fixture([])), {})

    def test_an_ask_covering_two_accounts_renders_no_verdict(self):
        # Two accounts filing into one conversation: the documents are loaded for the ask as a whole,
        # so account 7's filing would read as on-file for account 8's request and call it sufficient.
        from unittest import mock
        path = _proof_fixture([("a" * 64, 7, "conv1", None), ("b" * 64, 8, "conv1", None)],
                              {}, {}, candidates='["req"]')
        stage2 = {"req": {"Composer": pr.RoleProof(role="Composer", stage2="approve", proof_id="a" * 64,
                                                     stage2_proof_id="a" * 64,
                                                     stage2_at="2026-11-03T00:00:00Z")}}
        with mock.patch.object(pr, "load_stage2", return_value=stage2), \
             mock.patch.object(pr, "load_claimed_roles", return_value={"req": ("Composer",)}), \
             mock.patch.object(pr, "injection_hits", return_value={}):
            ask = pr.build_ask(ask_id="two-accounts", conversation_id="conv1", proof_db=path,
                               lens=lambda ids: {u: _Lens([], []) for u in ids})
        self.assertEqual(ask.user_ids, (7, 8))
        self.assertEqual(len(ask.requests), 1, "the fixture must have a request a verdict could be rendered for")
        rev = pr.review(ask)
        self.assertEqual(rev.verdicts, (), "no verdict may be rendered across two accounts")
        self.assertEqual(rev.counts.get(pr.SUFFICIENT, 0), 0)
        self.assertEqual(rev.campaign, "")
        self.assertEqual(rev.card, "", "a refused ask renders no card: it would pool both accounts' documents")
        self.assertIn("2 accounts", rev.gate_reason)
        self.assertIn("split", rev.gate_reason)
        self.assertIn("approved customer line is on file", rev.gate_reason)
        self.assertIn("sender campaign", rev.gate_reason)
        self.assertIn("nothing is sent", rev.gate_reason)
        sent: list[tuple[str, int, str]] = []
        store = pr.ReviewStore(os.path.join(tempfile.mkdtemp(prefix="proof-review-two-accounts-"), "s.sqlite"))
        self.addCleanup(store.close)
        out = pr.run(ask, store=store, mode="apply", segment="paid",
                     sender=lambda c, u, s: (sent.append((c, u, s)) or ("none", "")))
        self.assertEqual(sent, [], "a two-account ask sends nothing")
        self.assertEqual((out.sent, out.card, out.campaign), ("none", "", ""))
        self.assertEqual([row["state"] for row in store.board()], ["unknown"])

    def test_a_review_of_a_partial_claim_is_unknown_and_stays_open(self):
        # End to end: a request whose Producer role no judge has read, with a document that covers
        # the Composer role only. Nothing is asked and nothing approved, so the ask stays open on
        # the uvn-status campaign (the "evidence not readable" line) instead of closing as answered.
        claim = pr.RequestProof("r", 7, (pr.RoleProof("Composer", stage2="approve", dv="verified",
                                                       proof_id="a" * 64),),
                                dsp_anchor="both", claimed_roles=("Composer", "Producer"))
        rev = pr.review(pr.Ask(ask_id="partial", account_h="a" * 8,
                               documents=(pr.Document("a" * 64),), requests=(claim,)))
        self.assertEqual(rev.verdicts[0].verdict, pr.UNKNOWN)
        self.assertEqual((rev.state, rev.campaign), ("ask", "uvn-status"))
        self.assertEqual(rev.sent, "none")
        self.assertEqual(rev.counts.get(pr.SUFFICIENT, 0), 0)

    def test_a_tainted_stage2_document_still_tells_when_doc_verify_read_another(self):
        # Stage 2 approved document A while the latest doc-verify read is of document B. One merged
        # proof id kept only B, so an injection hit on A was invisible and A's approval read as
        # sufficient. Both ids survive the merge and A's taint stays A's taint.
        from unittest import mock
        path = _proof_fixture([("a" * 64, 7, "conv1", None), ("b" * 64, 7, "conv1", None)], {}, {})
        dv = _dv_fixture([("req", "Composer", "verified")])
        stage2 = {"req": {"Composer": pr.RoleProof(role="Composer", stage2="approve", proof_id="a" * 64,
                                                   stage2_proof_id="a" * 64,
                                                   stage2_at="2026-11-03T00:00:00Z")}}

        def _build(tainted: dict[str, str]) -> pr.Ask:
            with mock.patch.object(pr, "load_stage2", return_value=stage2), \
                 mock.patch.object(pr, "load_claimed_roles", return_value={"req": ("Composer",)}), \
                 mock.patch.object(pr, "injection_hits", return_value=tainted):
                return pr.build_ask(ask_id="merge", user_ids=[7], request_ids=["req"], proof_db=path,
                                    dv_db=dv, lens=lambda ids: {u: _Lens([], []) for u in ids})

        clean = pr.review(_build({}))
        self.assertEqual(clean.verdicts[0].verdict, pr.SUFFICIENT_ON_MERITS, clean.verdicts[0].why)
        tainted = pr.review(_build({"a" * 64: "high"}))
        self.assertEqual(tainted.verdicts[0].verdict, pr.GAP_ASK, tainted.verdicts[0].why)
        self.assertIn("injection", tainted.verdicts[0].why)

    def test_the_dsp_anchor_and_fraud_lens_are_read_per_request_and_account(self):
        # No dsp store on this host: no anchors, never an invented one.
        self.assertEqual(pr.load_dsp_anchor(["r"]), {})
        got = pr.load_fraud_lens([5, 5], lens=lambda ids: {u: _Lens([], []) for u in ids})
        self.assertEqual(got, {5: ((), ())})
        # An account the lens did not answer for is unmeasured, never clean: it is held, and a card
        # built from it holds instead of reading a silent absence as an all-clear.
        partial = pr.load_fraud_lens([5, 6], lens=lambda ids: {5: _Lens([], [])})
        self.assertEqual(partial[5], ((), ()))
        self.assertIn("did not answer", partial[6][0][0])
        held = pr.load_fraud_lens([5], lens=lambda ids: {u: _Lens(["banned"], ["watch"]) for u in ids})
        self.assertEqual(held, {5: (("banned",), ("watch",))})
        # No lens available at all: everyone is held (a review that cannot measure must not act).
        self.assertIn("not measured", pr.load_fraud_lens([5])[5][0][0])
        # ... and a lens that ANSWERS WRONG by failing holds too, never an all-clear.
        def boom(ids):
            raise RuntimeError("trino unreachable")
        held = pr.load_fraud_lens([5], lens=boom)
        self.assertIn("fraud lens unavailable (RuntimeError)", held[5][0][0])
        ask = pr.Ask(ask_id="lens-fail", account_h="f" * 8, documents=(pr.Document("a" * 64),),
                     requests=(pr.RequestProof("r", 5, (pr.RoleProof("Composer", dv="verified"),), dsp_anchor="both"),),
                     fraud_held=held[5][0])
        rev = pr.review(ask)
        self.assertEqual(rev.verdicts[0].verdict, pr.HOLD)
        self.assertEqual(rev.campaign, "")

    def test_documents_choose_nothing(self):
        # A document's own words never name the account, the requests or a verdict: the account
        # comes from the H3 filing and the requests from the filing's candidate list.
        path = _proof_fixture([("a" * 64, 7, "conv1", "c" * 40)],
                              {}, {}, candidates='["REQ-1", "req-2"]')
        self.assertEqual(pr._candidates([7], "conv1", proof_db=path), ["req-1", "req-2"])


class _Lens:
    def __init__(self, held, watch):
        self.held, self.watch, self.single_signal_rows = held, watch, 0


def _injection_ledger(rows: list[tuple[str, str, str]]) -> Path:
    """An injection-watch ledger with these (ts, ref, severity) inbound hits."""
    d = tempfile.mkdtemp(prefix="proof-review-inj-")
    path = Path(d) / "injection.jsonl"
    path.write_text("".join(json.dumps({"kind": "inbound_injection", "ts": ts, "ref": ref,
                                       "severity": sev, "source": "intercom", "hits": []}) + "\n"
                            for ts, ref, sev in rows))
    return path


def _ago(hours: int) -> str:
    """An ISO stamp this many hours before the real clock, which is the clock the ledger cuts on."""
    return (datetime.now(timezone.utc) - timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ")


def _proof_fixture(docs, reuse, kinds, candidates="[]", version=None) -> str:
    """A proof store with these filings and H3 signals (no network, no production store)."""
    import sqlite3
    version = version or pr._forensics_version()
    d = tempfile.mkdtemp(prefix="proof-review-proof-")
    path = os.path.join(d, "proof.sqlite")
    db = sqlite3.connect(path)
    db.executescript(
        "CREATE TABLE proof_intake (intake_id TEXT PRIMARY KEY, user_id INTEGER NOT NULL, subject TEXT NOT NULL,"
        " candidate_request_ids_json TEXT NOT NULL DEFAULT '[]', conversation_id TEXT NOT NULL, source TEXT NOT NULL,"
        " file_sha256 TEXT NOT NULL, file_path TEXT, mime TEXT, bytes INTEGER, received_at TEXT NOT NULL,"
        " filed_by TEXT NOT NULL, matched_by TEXT, contact_h TEXT, detail_json TEXT);"
        "CREATE TABLE forensics (id INTEGER PRIMARY KEY AUTOINCREMENT, proof_id TEXT NOT NULL,"
        " analyzer_version TEXT NOT NULL, check_id TEXT NOT NULL, name TEXT NOT NULL, severity TEXT NOT NULL,"
        " value_json TEXT, reason TEXT, evidence_json TEXT, created_at TEXT NOT NULL,"
        " request_id TEXT NOT NULL DEFAULT '');")
    for i, row in enumerate(docs):
        sha, uid, conv, contact = row[:4]
        received = row[4] if len(row) > 4 else "2026-11-04T00:00:00Z"
        db.execute("INSERT INTO proof_intake (intake_id, user_id, subject, candidate_request_ids_json,"
                   " conversation_id, source, file_sha256, received_at, filed_by, contact_h, detail_json)"
                   " VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                   (f"{uid}:{sha[:16]}:{i}", uid, "credit", candidates, conv, "intercom", sha, received,
                    "test", contact, "{}"))
    for sha, (name, sev) in reuse.items():
        db.execute("INSERT INTO forensics (proof_id, analyzer_version, check_id, name, severity, created_at)"
                   " VALUES (?,?,?,?,?,?)", (sha, version, "F2", name, sev, "2026-11-04T00:00:00Z"))
    for sha, kind in kinds.items():
        db.execute("INSERT INTO forensics (proof_id, analyzer_version, check_id, name, severity, value_json,"
                   " created_at) VALUES (?,?,?,?,?,?,?)",
                   (sha, version, "F5a", "document_kind", "info", json.dumps({"kind": kind}),
                    "2026-11-04T00:00:00Z"))
    db.commit()
    db.close()
    return path


def _forensics_rows(path: str, rows: list[tuple[str, str, str, str, str, dict | None]]) -> None:
    """Append (proof id, analyzer version, check id, name, severity, value) rows to a proof store."""
    import sqlite3
    db = sqlite3.connect(path)
    for sha, version, check, name, sev, value in rows:
        db.execute("INSERT INTO forensics (proof_id, analyzer_version, check_id, name, severity, value_json,"
                   " created_at) VALUES (?,?,?,?,?,?,?)",
                   (sha, version, check, name, sev, json.dumps(value) if value is not None else None,
                    "2026-11-04T00:00:00Z"))
    db.commit()
    db.close()


def _decisions_fixture(rows: list[tuple[str, str]]) -> str:
    """A decider ledger with these (request id, claimed roles) `decisions` rows in insert order."""
    import sqlite3
    path = os.path.join(tempfile.mkdtemp(prefix="proof-review-decisions-"), "ledger.sqlite3")
    db = sqlite3.connect(path)
    db.executescript("CREATE TABLE decisions (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL,"
                     " decided_at TEXT NOT NULL, request_id TEXT NOT NULL, claimed_roles TEXT);")
    for i, (rid, roles) in enumerate(rows):
        db.execute("INSERT INTO decisions (run_id, decided_at, request_id, claimed_roles) VALUES (?,?,?,?)",
                   (f"run{i}", f"2026-11-04T0{i}:00:00Z", rid, roles))
    db.commit()
    db.close()
    return path


def _ledger_fixture(rows: list[tuple[str, str, str]]) -> str:
    """A decider ledger with these (request id, action, outcome) rows in insert order."""
    import sqlite3
    path = os.path.join(tempfile.mkdtemp(prefix="proof-review-ledger-"), "ledger.sqlite3")
    db = sqlite3.connect(path)
    db.executescript("CREATE TABLE decision_outcomes (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL,"
                     " at TEXT NOT NULL, request_id TEXT NOT NULL, action TEXT NOT NULL, outcome TEXT NOT NULL);")
    for i, (rid, action, outcome) in enumerate(rows):
        db.execute("INSERT INTO decision_outcomes (run_id, at, request_id, action, outcome) VALUES (?,?,?,?,?)",
                   (f"run{i}", f"2026-11-04T0{i}:00:00Z", rid, action, outcome))
    db.commit()
    db.close()
    return path


if __name__ == "__main__":
    unittest.main()
