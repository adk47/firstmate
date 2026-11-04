#!/usr/bin/env python3
"""H3a — claim-handoff-receiver: the claims side of Caroline's hand-off (build only, SHADOW).

Contract: data/security-arch-fable-s1/handoff-contract.md §2 (intents), §4 (receiver), §9 (H3).
Build order: data/verify-program-lead-fable-l1/handoff-h3-build-1028.md (H3a, owner claim-lane-resume-c2).
Surface: data/proof-loop-lead-fable-p1/receive-py-surface-1028.md (H2's fixed import surface).

Built ON the shared gate, never around it: admission (schema, MAC, intent allowlist, ts/replay/7-day dedupe,
rate limits), identity re-derivation, the account gate and the audit row all happen inside H2's `receive()`;
this module imports `receive`, `finish`, `locate_attachment`, `HandoffLedger` and `OUTCOMES` and re-implements
none of them. `shared_gate()` resolves them at the point of use, because H1/H2 are unmerged; a missing gate is
a hard error, never a local fallback.

WHAT IT DOES, after the gate admitted the envelope and resolved exactly one account:
  * reads that account's OWN pending claims from the core replica (claim_status_list with `user_id`: the
    SELECT is `... WHERE status = 'pending' AND userid = <account>`; a claim of another account is never read);
  * `claim_status` -> the ONE approved claim-status line, only through the gate script's existing campaign
    (claim_proof_ask.run_status -> verify_notify.send_all -> intercom-verify-request.sh --campaign claim-status;
    its one-per-claim-ever, one-per-user-per-day, 7-day core-marker, support-hold and copy locks all apply).
    Only claims the claim-status audience rule lists (holds and organisations with a bindable page, firstmate
    042/044) are offered; B/C persons, no-page claimants and unreadable profiles -> `line_withheld` (their line
    is L14b, a captain word), which routes the row to the human tray (H3c);
  * `claim_proof` -> every attachment, located by sha256 through `locate_attachment` (host allowlist, 25 MB,
    magic-byte sniff), filed into `proof_intake` with `subject: claim`, the account's pending claim ids as the
    candidates and `filed_by: claim-handoff-receiver`. No receipt from here (the R1 path, #1416, owns it).

SHADOW: until `policies/credit-approval-automation.json` lists `claim-handoff-receiver` with `approved: true`
(a captain decision), the status line runs in `dry-run` (nothing reaches a customer; the outcome is
`line_withheld` with reason `shadow`). `proof_intake` is a shadow store and is written. The kill file
`/etc/hydra/handoff-receivers.disabled` stops the receiver before it does anything.

WHAT IT MUST NEVER DO (each pinned by a test):
  * approve, reject, hold or E1-verify a claim, or call anything that does (an AST check of this file is red
    if a call to such a name, or an import of the claim reviewer / verifier, appears);
  * read the envelope's `untrusted` block (customer / model text): no code path here touches it;
  * compose customer text, or send by any path but the claim-status campaign;
  * return an outcome outside the closed OUTCOMES set.
"""
from __future__ import annotations

import json
import os
import re
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Callable, Mapping

RECEIVER = "claim-handoff-receiver"
REGISTRY_KEY = "claim-handoff-receiver"
CLAIM_INTENTS = frozenset({"claim_status", "claim_proof"})
KILL_FILE = os.environ.get("HANDOFF_RECEIVERS_KILL_FILE", "/etc/hydra/handoff-receivers.disabled")
REGISTRY_PATH = os.path.join(os.path.dirname(__file__), "..", "..", "policies", "credit-approval-automation.json")
#: the whole of H2's surface this receiver touches
SURFACE = ("receive", "finish", "locate_attachment", "HandoffLedger", "OUTCOMES")
STATUS_CAMPAIGN = "claim-status"
#: The campaign's LIVE mode, and the only one that sends (QA on #1453 finding 1). `claim_proof_ask.run_status` and
#: `verify_notify.send_all` send ONLY for "apply" - every other value is a dry run that validates, checks the
#: recipient and reports `sent_notes = 0` (scripts/credit-review.py:1212 is the CLI's own choices=["dry-run",
#: "apply"]). This constant read `"send"` once, which validated the line and then recorded `line_withheld` for a
#: claimant who should have been told; the test double hid it by counting `sent_notes` for "send" too.
LIVE_MODE = "apply"
DRY_RUN_MODE = "dry-run"
REFUSAL_CODE = re.compile(r"^refused:[a-z0-9_]+$")


def shared_gate() -> Any:
    """H2's `scripts/handoff/receive.py`, resolved at the point of use (H1/H2 are unmerged)."""
    try:
        from handoff import receive  # type: ignore[import-not-found]
    except ImportError:
        try:
            from scripts.handoff import receive  # type: ignore[import-not-found,no-redef]
        except ImportError as e:  # pragma: no cover - only when H2 is absent
            raise RuntimeError("H3a requires H2's shared gate scripts/handoff/receive.py; it is not on this branch. "
                               "This receiver must not re-implement admission, identity re-derivation or the account "
                               "gate.") from e
    missing = [n for n in SURFACE if not hasattr(receive, n)]
    if missing:
        raise RuntimeError("H3a was built against receive.py's surface (receive-py-surface-1028.md) and it no longer "
                           "provides: " + ", ".join(missing))
    return receive


def outcome_allowed(outcome: str, outcomes: tuple[str, ...]) -> bool:
    """The closed OUTCOMES set; `refused:<code>` stands for any refusal code."""
    if outcome in outcomes and outcome != "refused:<code>":
        return True
    return "refused:<code>" in outcomes and bool(REFUSAL_CODE.match(outcome))


def approved_in_registry(path: str = REGISTRY_PATH) -> bool:
    """True only when the registry lists this receiver with approved: true (a captain decision). Unreadable = no."""
    try:
        with open(path, encoding="utf-8") as fh:
            entry = (json.load(fh).get("automations") or {}).get(REGISTRY_KEY) or {}
    except (OSError, ValueError):
        return False
    return entry.get("approved") is True and bool(entry.get("approval_ref"))


@dataclass
class Deps:
    """Everything the receiver reads or writes, injected (tests pass fakes)."""
    ledger: Any                                     # H2 HandoffLedger
    store: Any                                      # credit_verify.proof.store.ProofStore (proof_intake)
    query: Callable[[str], list] | None = None      # core replica (Trino, read-only)
    read_profile: Callable[[str], Any] | None = None
    send_status: Callable[..., Any] | None = None   # (doc, segment, mode) -> ClaimReport
    gate: Any = None                                # H2 receive module
    gate_kwargs: Mapping[str, Any] | None = None    # registry / intercom / core / gate fakes for receive()
    kill_file: str = KILL_FILE
    live_switch: Callable[[], bool] = approved_in_registry
    now: datetime | None = None


def _attr(obj: Any, name: str, default: Any = None) -> Any:
    if isinstance(obj, Mapping):
        return obj.get(name, default)
    return getattr(obj, name, default)


def _finish(gate: Any, adm: Any, outcome: str, actions: dict[str, Any], ledger: Any) -> dict[str, Any]:
    if not outcome_allowed(outcome, tuple(gate.OUTCOMES)):
        raise ValueError(f"outcome {outcome!r} is not in the closed OUTCOMES set")
    row = gate.finish(adm, outcome=outcome, actions=actions, ledger=ledger)
    return {"outcome": outcome, "actions": actions, "outcome_row": row}


def default_send_status(doc: dict[str, Any], segment: str, mode: str) -> Any:
    """The ONE send path: claim_proof_ask.run_status over a one-account list (campaign claim-status)."""
    from credit_review import claim_proof_ask  # noqa: PLC0415 - heavy import, only on the send path
    with tempfile.TemporaryDirectory(prefix="claim-handoff-") as tmp:
        path = os.path.join(tmp, "claim-status-one-account.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(doc, fh)
        return claim_proof_ask.run_status(list_path=path, segment=segment, mode=mode, max_users=1)


def _account_claims(deps: Deps, account_id: int) -> dict[str, Any]:
    from credit_review import claim_status_list as csl  # noqa: PLC0415
    kw: dict[str, Any] = {"user_id": account_id, "now": deps.now}
    if deps.query is not None:
        kw["query"] = deps.query
    if deps.read_profile is not None:
        kw["read_profile"] = deps.read_profile
    doc = csl.build(**kw)
    foreign = [c for c in doc["claims"] + doc["excluded"] if int(c["user_id"]) != account_id]
    if foreign:  # the SELECT is scoped to the account; a foreign row means the read is wrong, so stop
        raise RuntimeError(f"claim read returned {len(foreign)} claim(s) of another account")
    return doc


def handle(raw: bytes, deps: Deps) -> dict[str, Any]:
    """Process one envelope. Returns {outcome, actions, outcome_row}."""
    if os.path.exists(deps.kill_file):
        return {"outcome": "refused:disabled", "actions": {"kill_file": deps.kill_file}, "outcome_row": None}
    gate = deps.gate or shared_gate()
    adm = gate.receive(raw, receiver=RECEIVER, now=deps.now, ledger=deps.ledger, **dict(deps.gate_kwargs or {}))
    if not adm.ok:
        return _finish(gate, adm, adm.code or "refused:admission", {"step": adm.step}, deps.ledger)
    env = adm.envelope
    intent = _attr(env, "intent")
    if intent not in CLAIM_INTENTS:
        return _finish(gate, adm, "refused:intent", {"intent": str(intent)[:40]}, deps.ledger)
    account_id = _attr(adm.identity, "account_id")
    if not isinstance(account_id, int) or isinstance(account_id, bool) or account_id <= 0:
        return _finish(gate, adm, "refused:identity_unresolved", {}, deps.ledger)
    try:
        doc = _account_claims(deps, account_id)
    except Exception as e:  # noqa: BLE001 - an unreadable replica is a refusal, never "no claims"
        return _finish(gate, adm, "refused:replica_unreadable", {"error": str(e)[:200]}, deps.ledger)
    listed, excluded = doc["claims"], doc["excluded"]
    pending_ids = sorted(int(c["claim_id"]) for c in listed + excluded)
    if intent == "claim_status":
        return _claim_status(gate, adm, deps, listed, excluded, pending_ids)
    return _claim_proof(gate, adm, deps, account_id, env, pending_ids)


def _claim_status(gate: Any, adm: Any, deps: Deps, listed: list, excluded: list, pending_ids: list) -> dict[str, Any]:
    withheld = [{"claim_id": c["claim_id"], "reason": c["reason"]} for c in excluded]
    if not pending_ids:
        return _finish(gate, adm, "noop", {"pending_claims": 0}, deps.ledger)
    if not listed:
        # B/C persons, no-page claimants, unreadable profiles: no approved line exists (L14b is a captain word).
        return _finish(gate, adm, "line_withheld", {"pending_claims": pending_ids, "withheld": withheld,
                                                     "tray": True}, deps.ledger)
    segment = "paid" if any(c.get("paid") for c in listed) else "free"
    offer = [c for c in listed if bool(c.get("paid")) is (segment == "paid")]
    live = deps.live_switch()
    mode = LIVE_MODE if live else DRY_RUN_MODE
    doc = {"generated_at": (deps.now or datetime.now(timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "source": RECEIVER, "counts": {"listed": len(offer)}, "claims": offer}
    report = (deps.send_status or default_send_status)(doc, segment, mode)
    sent = int(getattr(report, "sent_notes", 0) or 0)
    actions = {"campaign": STATUS_CAMPAIGN, "mode": mode, "offered": [c["claim_id"] for c in offer],
               "withheld": withheld, "sent_notes": sent, "halted": str(getattr(report, "halted", "") or "")[:200]}
    if live and sent > 0:
        return _finish(gate, adm, "line_sent", actions, deps.ledger)
    actions.update({"reason": "shadow" if not live else "gate_did_not_send", "tray": True})
    return _finish(gate, adm, "line_withheld", actions, deps.ledger)


def _claim_proof(gate: Any, adm: Any, deps: Deps, account_id: int, env: Any, pending_ids: list) -> dict[str, Any]:
    conv = _attr(env, "conversation")
    conv_id = str(_attr(conv, "id") or _attr(env, "conversation_id") or "")
    atts = _attr(conv, "attachments") or _attr(env, "attachments") or []
    if not atts:
        return _finish(gate, adm, "noop", {"attachments": 0}, deps.ledger)
    # Candidates: the account's own pending claims; subject ids narrow them only when they are the account's.
    subject = _attr(env, "subject")
    named = {int(i) for i in (_attr(subject, "claim_ids") or _attr(subject, "ids") or []) if str(i).isdigit()}
    candidates = sorted(named & set(pending_ids)) or pending_ids
    already = set(deps.ledger.accepted_recently(conv_id, "claim_proof"))
    filed, dup, unlocatable = [], [], []
    for a in atts:
        sha = str(_attr(a, "sha256") or "")
        if len(sha) != 64 or sha in already:
            dup.append(sha[:12])
            continue
        path = gate.locate_attachment(sha, conversation_id=conv_id)
        if not path:
            unlocatable.append(sha[:12])
            continue
        if deps.store.already_filed(account_id, sha):
            dup.append(sha[:12])
            continue
        intake = deps.store.file_document(
            file_sha256=sha, user_id=account_id, conversation_id=conv_id, subject="claim",
            candidate_request_ids=[f"claim-{i}" for i in candidates], source="intercom-handoff", file_path=path,
            filed_by=RECEIVER, matched_by=str(_attr(adm.identity, "matched_by") or ""),
            contact_h=str(_attr(adm.identity, "contact_id_h") or ""), mime=_attr(a, "declared_mime") or _attr(a, "mime"),
            nbytes=int(_attr(a, "bytes") or 0), detail={"handoff_audit_id": adm.audit_id})
        (filed if intake else dup).append(sha[:12])
    actions = {"subject": "claim", "candidates": [f"claim-{i}" for i in candidates], "filed": filed,
               "duplicate": dup, "unlocatable": unlocatable,
               "receipt": "not from here (the R1 path, #1416, sends receipts when its lock is 1)"}
    if filed or (dup and not unlocatable):
        return _finish(gate, adm, "filed", actions, deps.ledger)
    actions["tray"] = True
    return _finish(gate, adm, "tray", actions, deps.ledger)
