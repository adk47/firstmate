"""H3a claim-handoff-receiver: contract tests (data/security-arch-fable-s1/handoff-contract.md §2/§4,
data/verify-program-lead-fable-l1/handoff-h3-build-1028.md H3a). H2's receive.py is unmerged, so the gate is a
fake that implements ONLY the five names of its fixed surface (receive-py-surface-1028.md)."""
from __future__ import annotations

import ast
import pathlib
import os
import re
import sys
import tempfile
import unittest
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from handoff import claim_handoff_receiver as rx  # noqa: E402

SRC = (ROOT / "scripts" / "handoff" / "claim_handoff_receiver.py").read_text(encoding="utf-8")
NOW = datetime(2026, 10, 28, 14, 0, tzinfo=timezone.utc)
SHA_A, SHA_B, SHA_C = "a" * 64, "b" * 64, "c" * 64


# ---- fake H2 surface (receive / finish / locate_attachment / HandoffLedger / OUTCOMES) -----------------------
@dataclass
class FakeLedger:
    outcomes: list = field(default_factory=list)
    accepted: set = field(default_factory=set)

    def accepted_recently(self, conversation_id, intent, *, days=7):
        return set(self.accepted)

    def outcome_row(self, audit_id, *, outcome, actions, receiver_sha):
        self.outcomes.append({"audit_id": audit_id, "outcome": outcome, "actions": dict(actions)})
        return len(self.outcomes)


class FakeGate:
    OUTCOMES = ("filed", "line_sent", "line_withheld", "tray", "refused:<code>", "noop")
    HandoffLedger = FakeLedger

    def __init__(self, adm, located=None):
        self.adm, self.located, self.calls = adm, located or {}, []

    def receive(self, raw, *, receiver, now=None, ledger=None, **kw):
        self.calls.append(("receive", receiver))
        return self.adm

    def finish(self, adm, *, outcome, actions, ledger):
        return ledger.outcome_row(adm.audit_id, outcome=outcome, actions=actions, receiver_sha="test")

    def locate_attachment(self, sha256, *, conversation_id, **kw):
        self.calls.append(("locate", sha256))
        return self.located.get(sha256)


def adm(intent="claim_status", account_id=7, ok=True, code="", attachments=(), claim_ids=(), untrusted=None):
    env = SimpleNamespace(
        id="env-1", intent=intent,
        conversation=SimpleNamespace(id="conv-9", attachments=[{"sha256": s, "bytes": 10, "declared_mime": "application/pdf"}
                                                                for s in attachments]),
        subject=SimpleNamespace(kind="claim", claim_ids=list(claim_ids)),
        untrusted=untrusted if untrusted is not None else _Booby())
    ident = SimpleNamespace(account_id=account_id, matched_by="professional_id", contact_id_h="ch16")
    return SimpleNamespace(ok=ok, step=7 if ok else 2, code=code, envelope=env if ok else None, identity=ident,
                           gate="allow", audit_id=99)


class _Booby(dict):
    """An `untrusted` block that fails the test if anything reads it."""
    def __getitem__(self, k):
        raise AssertionError("receiver read untrusted[%r]" % (k,))

    def get(self, k, d=None):
        raise AssertionError("receiver read untrusted.get(%r)" % (k,))

    def __iter__(self):
        raise AssertionError("receiver iterated untrusted")


# ---- fake replica + catalog + store + sender ---------------------------------------------------------------
class FakeTrino:
    """Answers claim_status_list's reads; records every SQL string."""
    def __init__(self, pending):
        self.pending, self.sql = pending, []

    def __call__(self, sql):
        self.sql.append(sql)
        if "status = 'pending'" in sql and sql.startswith("SELECT CAST(id AS varchar), CAST(userid"):
            m = re.search(r"userid = (\d+)", sql)
            return [r for r in self.pending if m is None or r[1] == m.group(1)]
        return []


def pend(cid, uid, pid, ptype="artist", team="t1"):
    return (str(cid), str(uid), team, pid, ptype, "2026-10-20 00:00:00")


ORG_WITH_SITE = {"id": "p-org", "name": "Label", "subType": "organization", "links": {"website": "https://label.example"}}
PERSON = {"id": "p-person", "name": "Jane", "subType": "artist", "links": {"website": "https://jane.example"}}
ORG_NO_PAGE = {"id": "p-bare", "name": "Bare Org", "subType": "organization", "links": {}}
PROFILES = {"p-org": ORG_WITH_SITE, "p-person": PERSON, "p-bare": ORG_NO_PAGE}


class FakeStore:
    def __init__(self):
        self.rows = []

    def already_filed(self, user_id, sha):
        return any(r["user_id"] == user_id and r["file_sha256"] == sha for r in self.rows)

    def file_document(self, **kw):
        self.rows.append(kw)
        return f"intake-{len(self.rows)}"


class FakeSend:
    """Behaves like the real campaign: `verify_notify.send_all` sends ONLY for mode="apply" - anything else
    validates (or checks the recipient) and reports sent_notes = 0. This double counted "send" as live once,
    which is exactly what hid the receiver passing a mode the campaign never sends for (QA on #1453, finding 1).
    """

    LIVE = "apply"

    def __init__(self, sent=1):
        self.calls, self.sent = [], sent

    def __call__(self, doc, segment, mode):
        self.calls.append({"doc": doc, "segment": segment, "mode": mode})
        return SimpleNamespace(sent_notes=self.sent if mode == self.LIVE else 0, halted="")


def deps(gate, pending, approved=False, ledger=None, store=None, send=None, kill_file="/nonexistent/kill"):
    return rx.Deps(ledger=ledger or FakeLedger(), store=store or FakeStore(), query=FakeTrino(pending),
                   read_profile=PROFILES.get, send_status=send or FakeSend(), gate=gate, kill_file=kill_file,
                   live_switch=lambda: approved, now=NOW)


class AdmissionTests(unittest.TestCase):
    def test_kill_file_stops_before_the_gate(self):
        g = FakeGate(adm())
        with tempfile.NamedTemporaryFile() as kf:
            out = rx.handle(b"{}", deps(g, [], kill_file=kf.name))
        self.assertEqual(out["outcome"], "refused:disabled")
        self.assertEqual(g.calls, [])

    def test_a_refused_admission_is_finished_with_the_gate_code_and_nothing_else_runs(self):
        g = FakeGate(adm(ok=False, code="refused:bad_mac"))
        d = deps(g, [pend(1, 7, "p-org", "organization")])
        out = rx.handle(b"{}", d)
        self.assertEqual(out["outcome"], "refused:bad_mac")
        self.assertEqual(d.query.sql, [])                     # no replica read on a refused envelope
        self.assertEqual(d.ledger.outcomes[0]["outcome"], "refused:bad_mac")

    def test_only_the_two_claim_intents(self):
        for intent in ("credit_status", "document_submitted", "merge_request", "dispute", "approve_claim"):
            d = deps(FakeGate(adm(intent=intent)), [pend(1, 7, "p-org", "organization")])
            self.assertEqual(rx.handle(b"{}", d)["outcome"], "refused:intent", intent)
            self.assertEqual(d.query.sql, [])

    def test_an_unresolved_account_is_refused(self):
        for acct in (None, 0, -3, "7", True):
            out = rx.handle(b"{}", deps(FakeGate(adm(account_id=acct)), []))
            self.assertEqual(out["outcome"], "refused:identity_unresolved", acct)


class ScopeTests(unittest.TestCase):
    def test_the_pending_claims_read_is_scoped_to_the_resolved_account(self):
        d = deps(FakeGate(adm()), [pend(1, 7, "p-org", "organization"), pend(2, 8, "p-org", "organization")])
        rx.handle(b"{}", d)
        first = d.query.sql[0]
        self.assertIn("status = 'pending'", first)
        self.assertIn("AND userid = 7", first)
        offered = d.send_status.calls[0]["doc"]["claims"]
        self.assertEqual([c["claim_id"] for c in offered], [1])          # claim 2 belongs to account 8

    def test_a_foreign_row_from_the_replica_refuses(self):
        class Leaky(FakeTrino):
            def __call__(self, sql):
                self.sql.append(sql)
                if "status = 'pending'" in sql and sql.startswith("SELECT CAST(id AS varchar), CAST(userid"):
                    return [pend(1, 7, "p-org", "organization"), pend(2, 8, "p-org", "organization")]
                return []
        d = deps(FakeGate(adm()), [])
        d.query = Leaky([])
        out = rx.handle(b"{}", d)
        self.assertEqual(out["outcome"], "refused:replica_unreadable")
        self.assertEqual(d.send_status.calls, [])

    def test_an_unreadable_replica_is_a_refusal_never_no_claims(self):
        d = deps(FakeGate(adm()), [])
        d.query = lambda sql: (_ for _ in ()).throw(RuntimeError("trino down"))
        self.assertEqual(rx.handle(b"{}", d)["outcome"], "refused:replica_unreadable")


class ClaimStatusTests(unittest.TestCase):
    def test_shadow_runs_the_campaign_in_dry_run_and_withholds_the_line(self):
        d = deps(FakeGate(adm()), [pend(1, 7, "p-org", "organization")], approved=False)
        out = rx.handle(b"{}", d)
        self.assertEqual(out["outcome"], "line_withheld")
        self.assertEqual(out["actions"]["reason"], "shadow")
        self.assertEqual(d.send_status.calls[0]["mode"], rx.DRY_RUN_MODE)
        self.assertEqual(out["actions"]["campaign"], "claim-status")

    def test_approved_sends_one_line_through_the_campaign(self):
        d = deps(FakeGate(adm()), [pend(1, 7, "p-org", "organization"), pend(3, 7, "p-org", "organization")],
                 approved=True)
        out = rx.handle(b"{}", d)
        self.assertEqual(out["outcome"], "line_sent")
        self.assertEqual(len(d.send_status.calls), 1)                    # one call, one line per account
        self.assertEqual(d.send_status.calls[0]["mode"], rx.LIVE_MODE)

    def test_bc_person_and_no_page_claimants_get_no_line_and_go_to_the_tray(self):
        d = deps(FakeGate(adm()), [pend(1, 7, "p-person", "artist"), pend(2, 7, "p-bare", "organization")], approved=True)
        out = rx.handle(b"{}", d)
        self.assertEqual(out["outcome"], "line_withheld")
        self.assertTrue(out["actions"]["tray"])
        self.assertEqual(sorted(w["reason"] for w in out["actions"]["withheld"]), ["bc_person_excluded", "no_bindable_page"])
        self.assertEqual(d.send_status.calls, [])

    def test_no_pending_claim_is_a_noop(self):
        out = rx.handle(b"{}", deps(FakeGate(adm()), []))
        self.assertEqual(out["outcome"], "noop")


class ClaimProofTests(unittest.TestCase):
    def test_attachments_are_filed_by_sha_into_proof_intake_with_subject_claim(self):
        g = FakeGate(adm(intent="claim_proof", attachments=(SHA_A, SHA_B, SHA_C), claim_ids=(1, 555)),
                     located={SHA_A: "/cache/a.pdf", SHA_B: "/cache/b.pdf"})
        ledger = FakeLedger(accepted={SHA_B})
        d = deps(g, [pend(1, 7, "p-person"), pend(4, 7, "p-org", "organization")], ledger=ledger)
        out = rx.handle(b"{}", d)
        self.assertEqual(out["outcome"], "filed")
        self.assertEqual(len(d.store.rows), 1)                            # B already accepted, C unlocatable
        row = d.store.rows[0]
        self.assertEqual((row["file_sha256"], row["user_id"], row["subject"], row["filed_by"]),
                         (SHA_A, 7, "claim", "claim-handoff-receiver"))
        self.assertEqual(row["candidate_request_ids"], ["claim-1"])     # 555 is not the account's: ignored
        self.assertEqual(out["actions"]["unlocatable"], [SHA_C[:12]])
        self.assertNotIn(("locate", SHA_B), g.calls)                     # deduped before any fetch

    def test_a_named_claim_of_another_account_never_becomes_a_candidate(self):
        g = FakeGate(adm(intent="claim_proof", attachments=(SHA_A,), claim_ids=(555,)), located={SHA_A: "/c/a"})
        d = deps(g, [pend(1, 7, "p-person"), pend(4, 7, "p-org", "organization")])
        rx.handle(b"{}", d)
        self.assertEqual(d.store.rows[0]["candidate_request_ids"], ["claim-1", "claim-4"])

    def test_nothing_locatable_goes_to_the_tray(self):
        g = FakeGate(adm(intent="claim_proof", attachments=(SHA_A,)))
        out = rx.handle(b"{}", deps(g, [pend(1, 7, "p-person")]))
        self.assertEqual(out["outcome"], "tray")

    def test_no_attachment_is_a_noop(self):
        out = rx.handle(b"{}", deps(FakeGate(adm(intent="claim_proof")), [pend(1, 7, "p-person")]))
        self.assertEqual(out["outcome"], "noop")


class OutcomeSetTests(unittest.TestCase):
    def test_closed_outcome_set(self):
        o = FakeGate.OUTCOMES
        for ok in ("filed", "line_sent", "line_withheld", "tray", "noop", "refused:intent"):
            self.assertTrue(rx.outcome_allowed(ok, o), ok)
        for bad in ("approved", "refused:", "refused:<code>", "rejected", "line_sent ", ""):
            self.assertFalse(rx.outcome_allowed(bad, o), bad)
        with self.assertRaises(ValueError):
            rx._finish(FakeGate(adm()), adm(), "approved", {}, FakeLedger())


# ---- static capability checks -------------------------------------------------------------------------------
FORBIDDEN_CALL = re.compile(r"(approve|reject|decline|verif|decide|revert|(^|_)hold($|_)|(^|_)e1($|_)|process_?claim|merge)", re.I)
FORBIDDEN_IMPORT = re.compile(r"(claim_e1|claim_review|claim_verify\.(?!bound_pages)|decider|verifier|subprocess|requests|urllib|http)", re.I)


def capability_violations(src: str) -> list[str]:
    """Calls to an approve/reject/verify/hold/merge-shaped name, risky imports, and any read of `untrusted`."""
    out: list[str] = []
    for node in ast.walk(ast.parse(src)):
        if isinstance(node, ast.Call):
            f = node.func
            name = f.attr if isinstance(f, ast.Attribute) else (f.id if isinstance(f, ast.Name) else "")
            if name and FORBIDDEN_CALL.search(name):
                out.append(f"call {name}")
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            base = node.module + "." if isinstance(node, ast.ImportFrom) and node.module else ""
            mods = [base + a.name for a in node.names] + ([node.module] if base else [])
            out += [f"import {m}" for m in mods if FORBIDDEN_CALL.search(m.rsplit(".", 1)[-1])]
            out += [f"import {m}" for m in mods if FORBIDDEN_IMPORT.search(m or "")]
        elif isinstance(node, ast.Attribute) and node.attr == "untrusted":
            out.append("read .untrusted")
        elif isinstance(node, ast.Constant) and node.value in ("untrusted", "customer_text", "model_summary"):
            out.append(f"literal {node.value!r}")
    return out


class LiveModeContractTests(unittest.TestCase):
    """QA on #1453 finding 1: the live mode is the campaign's, not a word of the receiver's own."""

    def test_the_live_mode_is_a_mode_the_campaign_cli_accepts(self):
        # Bound to the REAL contract by reading the campaign CLI's own argparse choices, so renaming the live
        # mode there fails here instead of silently turning the live path into a validating no-op.
        src = pathlib.Path(__file__).resolve().parents[1].joinpath("credit-review.py").read_text()
        live = [n for n in ast.walk(ast.parse(src))
                if isinstance(n, ast.Call) and getattr(n.func, "attr", "") == "add_argument"
                and any(getattr(a, "value", None) == "--mode" for a in n.args)]
        choices = {c.value for n in live for kw in n.keywords if kw.arg == "choices"
                   for c in ast.walk(kw.value) if isinstance(c, ast.Constant)}
        self.assertIn(rx.LIVE_MODE, choices)
        self.assertNotIn("send", choices)          # the value this receiver used to pass

    def test_an_approved_hand_off_actually_reports_the_line_sent(self):
        d = deps(FakeGate(adm()), [pend(1, 7, "p-org", "organization")], approved=True)
        out = rx.handle(b"{}", d)
        self.assertEqual(out["outcome"], "line_sent")          # only reachable if the mode really sends
        self.assertGreater(out["actions"]["sent_notes"], 0)


class CapabilityTests(unittest.TestCase):
    def test_the_receiver_has_no_approve_verify_send_or_untrusted_capability(self):
        self.assertEqual(capability_violations(SRC), [])

    def test_mutants_are_red(self):
        mutants = {
            "verify call": "\ndef _m(c):\n    return verify_claim(c)\n",
            "E1 verifier import": "\nfrom claim_verify import e1\n",
            "approve call": "\ndef _m(s, c):\n    return s.approve(c)\n",
            "subprocess": "\nimport subprocess\n",
            "untrusted read": "\ndef _m(env):\n    return env.untrusted\n",
            "customer text": "\ndef _m(env):\n    return dict(env)['customer_text']\n",
        }
        for name, extra in mutants.items():
            self.assertNotEqual(capability_violations(SRC + extra), [], name)

    def test_the_untrusted_block_is_never_touched_at_runtime(self):
        for intent, atts in (("claim_status", ()), ("claim_proof", (SHA_A,))):
            g = FakeGate(adm(intent=intent, attachments=atts), located={SHA_A: "/c/a"})
            rx.handle(b"{}", deps(g, [pend(1, 7, "p-org", "organization")]))   # _Booby raises if read

    def test_the_only_send_path_is_the_claim_status_campaign(self):
        self.assertIn("claim_proof_ask.run_status", SRC)
        self.assertEqual(SRC.count("run_status("), 1)
        self.assertEqual(rx.STATUS_CAMPAIGN, "claim-status")


class RegistryTests(unittest.TestCase):
    def test_registered_shadow_entry(self):
        self.assertFalse(rx.approved_in_registry())
        import json
        reg = json.loads((ROOT / "policies" / "credit-approval-automation.json").read_text())
        e = reg["automations"]["claim-handoff-receiver"]
        self.assertIs(e["approved"], False)
        self.assertIsNone(e["approval_ref"])

    def test_approval_needs_both_approved_and_a_ref(self):
        with tempfile.TemporaryDirectory() as t:
            p = os.path.join(t, "r.json")
            for entry, want in (({"approved": True, "approval_ref": "captain 2026-11-01"}, True),
                                ({"approved": True, "approval_ref": None}, False),
                                ({"approved": "true", "approval_ref": "x"}, False)):
                Path(p).write_text(__import__("json").dumps({"automations": {"claim-handoff-receiver": entry}}))
                self.assertEqual(rx.approved_in_registry(p), want, entry)
            self.assertFalse(rx.approved_in_registry(os.path.join(t, "missing.json")))


if __name__ == "__main__":
    unittest.main()
