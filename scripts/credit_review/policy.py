"""Deterministic verdict policy around the model.

The model is advisory. This module decides the final verdict from the
structured evidence plus the model's answer, and enforces the clamps that do
not depend on the model behaving:

* a trusted-source contradiction on a one-person role is CONTRADICTED /
  REJECT-RECOMMENDED without asking the model;
* trusted-source confirmation of every claimed role is CONFIRMED /
  APPROVE-RECOMMENDED without asking the model;
* web evidence counts only when it is a real search citation on an
  independent domain (judge.py drops invented URLs, muso.ai and
  claimant-controlled domains, and counts one site's subdomains once);
* the reviewer never recommends approving a BIG-track credit without
  trusted-source corroboration (Phase 1 rule), never on a stillfloo-pattern
  profile, and a model error is a hold, never a pass.

Nothing here writes anything. Verdicts land in the ledger and in Slack.
"""

from __future__ import annotations

import json
import os
import sqlite3
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .evidence import CONFIRMED, Evidence
from .judge import JudgeResult
from .roles import is_editorial

ROOT = Path(__file__).resolve().parents[2]
AUTOMATION_REGISTRY = Path(os.environ.get("CREDIT_APPROVAL_REGISTRY",
                                          ROOT / "policies" / "credit-approval-automation.json"))
DECIDE_POLICY = Path(os.environ.get("CREDIT_TRUST_DECIDE_POLICY", ROOT / "policies" / "credit-trust-decide.json"))

# Auditor verdicts.
A_CONFIRMED = "CONFIRMED"
A_SUSPECT = "SUSPECT"
A_CONTRADICTED = "CONTRADICTED"
A_UNVERIFIABLE = "UNVERIFIABLE"  # no evidence either way and no red flags

# Reviewer verdicts.
R_APPROVE = "APPROVE-RECOMMENDED"
R_HUMAN = "NEEDS-HUMAN"
R_REJECT = "REJECT-RECOMMENDED"

WEB_CONFIRM_MIN_DOMAINS = 2
WEB_CONFIRM_MIN_CONFIDENCE = 0.85
WEB_CONTRADICT_MIN_CONFIDENCE = 0.80
ESTABLISHED_ARTIST_POPULARITY = 60

# Approver identities that must never approve credit requests, per the
# captain's 2026-10-11 order: an approval by them is alerted.
FORBIDDEN_APPROVERS = frozenset({"agent-hydra-main@muso.ai", "admin_u@muso.ai"})
# Identities expected to approve (humans on the tier-2 list, Caroline's gated
# self-service, the under-30 cron). Anything else is "unknown" and alerted.
KNOWN_APPROVERS = frozenset({
    "jan@muso.ai", "aaron@muso.ai", "nick@muso.ai", "caroline@muso.ai",
    "uvn-popularity-cron@hydra-ops",
})
# Registered automations' own admin accounts (T12, core #10595): an agent
# approval from one of these is accepted only while the automation is
# approved:true in policies/credit-approval-automation.json, and only when it
# breaks none of the automation approval rules (agent_rule_breaks).
KNOWN_AGENT_APPROVERS = {
    "agent-credit-decider@muso.ai": "credit-trust-decide",
    "agent-uvn-cron@muso.ai": "uvn-under30",
}

# Server mirror (core-backend services/credit-requests/agentApprovalGuard.js).
CONFLICT_TRACK_CREDIT = 70
CONFLICT_COLLABORATIONS = 90
HOLD_RULE_PREFIX = "review_"
HOLD_RULE_MIN_SCORE = 30
HOLD_ON_ERROR_KEY = "_hold_on_error"
REJECT_RULE_PREFIX = "reject_"


def _num(v: Any) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def validator_conflict(vd: Any) -> dict[str, Any] | None:
    """The validator conflict the server holds an AGENT approval on, or None.
    Mirrors agentApprovalGuard.validatorConflict exactly: only JSON numbers
    count as rule scores."""
    vd = vd if isinstance(vd, dict) else {}
    rules = vd.get("rule_risk_percent") if isinstance(vd.get("rule_risk_percent"), dict) else {}
    tc, col = _num(rules.get("track_credit")), _num(rules.get("collaborations"))
    class_c = tc is not None and col is not None and tc >= CONFLICT_TRACK_CREDIT and col >= CONFLICT_COLLABORATIONS
    holds = sorted(k for k, v in rules.items()
                   if str(k).startswith(HOLD_RULE_PREFIX) and _num(v) is not None and _num(v) >= HOLD_RULE_MIN_SCORE)
    errors = vd.get("rule_errors") if isinstance(vd.get("rule_errors"), dict) else {}
    hold_on_error = HOLD_ON_ERROR_KEY in errors
    if not (class_c or holds or hold_on_error):
        return None
    return {"class_c": class_c, "hold_rules": holds, "hold_on_error": hold_on_error,
            "track_credit": tc, "collaborations": col}


def validator_rejected_rules(vd: Any) -> list[str]:
    """The validator ``reject_*`` rules that fired (a JSON number > 0). No
    automation approves such a row: the decider HOLDS it for a human, and the
    auditor alerts when a registered automation approved one."""
    vd = vd if isinstance(vd, dict) else {}
    rules = vd.get("rule_risk_percent") if isinstance(vd.get("rule_risk_percent"), dict) else {}
    return sorted(k for k, v in rules.items() if str(k).startswith(REJECT_RULE_PREFIX) and (_num(v) or 0) > 0)


def doc_required_ids(db: sqlite3.Connection) -> frozenset[str]:
    """Requests the decider marked documentation-required in APPLY mode (shadow
    runs never mark a row)."""
    return frozenset(str(r[0]).lower() for r in db.execute(
        "SELECT DISTINCT request_id FROM decisions WHERE doc_required = 1 AND mode = 'apply'"))


def decider_proof_ids(db: sqlite3.Connection) -> dict[str, str]:
    """request id -> the proof id the decider relied on when it approved a
    documentation-required row (its own audit record; core-backend's
    metadata.approval carries no proof id)."""
    return {str(r[0]).lower(): str(r[1]) for r in db.execute(
        "SELECT request_id, proof_id FROM decisions WHERE decision = 'approve' AND mode = 'apply'"
        " AND proof_id IS NOT NULL AND proof_id != '' ORDER BY id")}


def approved_automations(path: Path | None = None) -> frozenset[str]:
    """Automations the registry lists approved:true with approved_by and
    approval_ref. Unreadable registry -> none (every agent approval alerts)."""
    try:
        entries = json.loads(Path(path or AUTOMATION_REGISTRY).read_text(encoding="utf-8"))["automations"]
    except (OSError, ValueError, KeyError, TypeError):
        return frozenset()
    return frozenset(name for name, e in (entries.items() if isinstance(entries, dict) else ())
                     if isinstance(e, dict) and e.get("approved") is True
                     and str(e.get("approved_by") or "").strip() and str(e.get("approval_ref") or "").strip())


@dataclass(frozen=True)
class AgentApprovalContext:
    """What the auditor needs to judge a registered automation's approval."""
    approved_automations: frozenset[str] = frozenset()
    editorial_terms: tuple[str, ...] | None = None   # None: the policy was unreadable, the check fails closed
    doc_required_ids: frozenset[str] = frozenset()   # requests the decider marked documentation-required
    proof_ids: dict[str, str] = field(default_factory=dict)  # decider's recorded proof id per approved request


def agent_rule_breaks(request: dict[str, Any], ev: Evidence | None, ctx: AgentApprovalContext,
                      automation: str) -> list[str]:
    """The automation approval rules an agent approval broke (empty = clean)."""
    vd = request.get("verificationData") if isinstance(request.get("verificationData"), dict) else {}
    breaks: list[str] = []
    rejected = validator_rejected_rules(vd)
    if rejected:
        breaks.append(f"the validator declined it ({', '.join(rejected)})")
    conflict = validator_conflict(vd)
    if conflict:
        breaks.append("validator conflict (" + ",".join(conflict["hold_rules"] + (["class_c"] if conflict["class_c"] else [])
                                                         + (["hold_on_error"] if conflict["hold_on_error"] else [])) + ")")
    if ev is None:
        breaks.append("evidence unavailable: big-track and editorial rules could not be checked")
        return breaks
    if ev.big_track and not ev.all_confirmed:
        breaks.append("big track approved without trusted-source confirmation")
    if ctx.editorial_terms is None:
        breaks.append("editorial-role rule could not be checked (policy unreadable)")
    else:
        weak = [r.claimed_role for r in ev.roles
                if is_editorial(r.claimed_role, ctx.editorial_terms) and r.status != CONFIRMED]
        if weak:
            breaks.append(f"editorial role without a trusted credit for the claimant ({', '.join(weak)})")
    rid = str(request.get("id") or "").lower()
    proof = ctx.proof_ids.get(rid) if automation == "credit-trust-decide" else None
    if rid in ctx.doc_required_ids and not proof:
        breaks.append("documentation-required row approved without a proof id")
    return breaks


@dataclass
class Decision:
    verdict: str
    confidence: float
    basis: str
    reasons: list[str] = field(default_factory=list)
    needs_model: bool = False

    def as_dict(self) -> dict[str, Any]:
        return {"verdict": self.verdict, "confidence": round(self.confidence, 3),
                "basis": self.basis, "reasons": self.reasons}


@dataclass
class Facts:
    """Everything the policy needs, derivable from live Evidence OR from a
    stored ledger record (so a policy change can be re-scored offline against
    an earlier eval without paying for model calls again)."""
    big_track: bool
    any_contradicted: bool
    all_confirmed: bool
    any_others_only: bool
    stillfloo_pattern: bool
    flags: list[str]
    contradicted_reason: str = ""
    confirmed_sources: list[str] = field(default_factory=list)
    claimant_domains: list[str] | None = None   # None: unknown, so no web confirmation
    claimant_names: list[str] = field(default_factory=list)


def _flags(*, stillfloo: bool, high_velocity: bool, big: bool, big_share: float, muso_only: bool,
           lead_pop: int | None, others_only: bool, validator_approved: Any, status: str,
           risk: Any, errors: bool, velocity_txt: str = "") -> list[str]:
    flags: list[str] = []
    if stillfloo:
        flags.append("stillfloo_pattern")
    # Velocity alone is normal (a producer uploading a back catalog of small
    # releases). It is a red flag only when the burst reaches big tracks.
    if high_velocity and (big or big_share >= 0.20):
        flags.append(f"high_velocity_on_big_tracks({velocity_txt})")
    # A Muso-only identity (no Spotify/Tidal/MLC/Jaxsta profile) claiming a
    # credit on a big track, or on a release by an established artist.
    if muso_only and (big or (lead_pop or 0) >= ESTABLISHED_ARTIST_POPULARITY):
        flags.append("muso_only_identity_on_established_release")
    if others_only and big:
        flags.append("trusted_sources_credit_others_only")
    if validator_approved is False and status == "approved":
        flags.append(f"approved_despite_validator_decline(risk={risk})")
    if errors:
        flags.append("evidence_errors")
    return flags


def facts_of(ev: Evidence) -> Facts:
    p = ev.profile
    flags = _flags(
        stillfloo=bool(p and p.stillfloo_pattern), high_velocity=bool(p and p.high_velocity), big=ev.big_track,
        big_share=p.big_share_7d if p else 0.0, muso_only=bool(p and p.muso_only), lead_pop=ev.artist_popularity,
        others_only=ev.any_others_only, validator_approved=ev.validator_approved, status=ev.status,
        risk=ev.validator_risk, errors=bool(ev.errors),
        velocity_txt=f"{p.requests_24h}/24h,{p.requests_7d}/7d,big_share={p.big_share_7d:.2f}" if p else "")
    roles = [r for r in ev.roles if r.status == "CONTRADICTED"]
    others = sorted({o["name"] for r in roles for o in r.trusted_for_others})[:4]
    return Facts(
        big_track=ev.big_track, any_contradicted=ev.any_contradicted, all_confirmed=ev.all_confirmed,
        any_others_only=ev.any_others_only, stillfloo_pattern=bool(p and p.stillfloo_pattern), flags=flags,
        contradicted_reason=(f"trusted source credits {', '.join(others)} for "
                             f"{'/'.join(r.claimed_role for r in roles)} and not this profile") if roles else "",
        confirmed_sources=sorted({t["source"] for r in ev.roles for t in r.trusted_for_profile}),
        claimant_domains=None if ev.claimant_domains is None else list(ev.claimant_domains),
        claimant_names=list(ev.claimant_names))


def facts_from_record(evidence: dict[str, Any], status: str) -> Facts:
    """Rebuild Facts from a ledger row's evidence_json (Evidence.for_model() +
    deterministic + errors)."""
    track = evidence.get("track") or {}
    prof = evidence.get("profile") or {}
    roles = evidence.get("trusted_catalog_credits_by_role") or []
    statuses = [r.get("status") for r in roles]
    rv = evidence.get("rule_validator") or {}
    contradicted = [r for r in roles if r.get("status") == "CONTRADICTED"]
    others = sorted({o.get("name") for r in contradicted for o in r.get("trusted_for_others") or []})[:4]
    big = bool(track.get("big_track"))
    flags = _flags(
        stillfloo=bool(prof.get("stillfloo_like_pattern")), high_velocity=bool(prof.get("high_velocity")), big=big,
        big_share=float(prof.get("share_of_7d_requests_on_big_tracks") or 0), muso_only=bool(prof.get("muso_only_identity")),
        lead_pop=track.get("max_artist_popularity", track.get("lead_artist_popularity")),
        others_only="OTHERS_ONLY" in statuses,
        validator_approved=rv.get("approved"), status=status, risk=rv.get("total_risk_percent"),
        errors=bool(evidence.get("errors")),
        velocity_txt=f"{prof.get('requests_last_24h')}/24h,{prof.get('requests_last_7d')}/7d")
    return Facts(
        big_track=big, any_contradicted=bool(contradicted), all_confirmed=bool(roles) and all(s == "CONFIRMED" for s in statuses),
        any_others_only="OTHERS_ONLY" in statuses, stillfloo_pattern=bool(prof.get("stillfloo_like_pattern")), flags=flags,
        contradicted_reason=(f"trusted source credits {', '.join(others)} and not this profile") if contradicted else "",
        confirmed_sources=sorted({t.get("source") for r in roles for t in r.get("trusted_for_profile") or []}),
        claimant_domains=(None if not isinstance(evidence.get("claimant_domains"), list)
                          else [str(d) for d in evidence["claimant_domains"]]),
        claimant_names=[str(n) for n in evidence.get("claimant_names") or [] if n])


def red_flags(ev: Evidence) -> list[str]:
    return facts_of(ev).flags


def deterministic(ev: Evidence | Facts, mode: str) -> Decision:
    """Verdict from catalog evidence alone; needs_model=True when undecided."""
    f = ev if isinstance(ev, Facts) else facts_of(ev)
    if f.any_contradicted:
        verdict = A_CONTRADICTED if mode == "audit" else R_REJECT
        return Decision(verdict, 0.95, "trusted_source_contradiction", [f.contradicted_reason] + f.flags)
    if f.all_confirmed:
        reason = f"trusted source ({', '.join(f.confirmed_sources)}) credits this profile in every claimed role"
        if mode == "review" and (f.flags or f.stillfloo_pattern):
            # Phase 1 clamp (QA on hydra#1142): a catalog name match never
            # outweighs a red flag (stillfloo pattern, approval despite a
            # validator decline, ...). A human decides.
            return Decision(R_HUMAN, 0.95, "trusted_source_confirmation_with_flags",
                            [reason, "clamp: red flags present, approve needs a human"] + f.flags)
        verdict = A_CONFIRMED if mode == "audit" else R_APPROVE
        return Decision(verdict, 0.95, "trusted_source_confirmation", [reason] + f.flags)
    return Decision(A_UNVERIFIABLE if mode == "audit" else R_HUMAN, 0.0, "undecided", list(f.flags), needs_model=True)


def combine(ev: Evidence | Facts, mode: str, judged: JudgeResult | None) -> Decision:
    """Final verdict: deterministic first, then the model, then the clamps."""
    f = ev if isinstance(ev, Facts) else facts_of(ev)
    base = deterministic(f, mode)
    if not base.needs_model:
        return base
    flags = base.reasons
    big = f.big_track
    pattern = f.stillfloo_pattern

    if judged is None:  # sampled out, or no key configured
        if mode == "audit":
            return Decision(A_SUSPECT if flags else A_UNVERIFIABLE, 0.5 if flags else 0.0,
                            "catalog_only", flags or ["no trusted data for the claimed role; not model-checked"])
        return Decision(R_HUMAN, 0.0, "catalog_only", flags or ["no trusted corroboration"])

    if not judged.ok:
        # Errors hold, never pass (mirrors IDP #1686 "errors -> hold").
        reasons = flags + [f"model_error: {judged.error}"]
        if mode == "audit":
            return Decision(A_SUSPECT if (big or flags) else A_UNVERIFIABLE, 0.3, "model_error", reasons)
        return Decision(R_HUMAN, 0.0, "model_error", reasons)

    v, conf = judged.verdict, judged.confidence
    sup = judged.supporting_domains(f.claimant_domains or (), f.claimant_names)
    con = judged.contradicting_domains(f.claimant_domains or (), f.claimant_names)
    reasons = list(flags)
    if f.claimant_domains is None:
        reasons.append("claimant domains unknown (profile unreadable): web evidence cannot confirm")
    if judged.rationale:
        reasons.append(f"model: {judged.rationale}")
    if judged.identity_consistent is False:
        reasons.append("model: identity inconsistent with this track")

    contradiction = v in ("CONTRADICTED", R_REJECT) and conf >= WEB_CONTRADICT_MIN_CONFIDENCE and len(con) >= 1
    confirmation = (v in ("CONFIRMED", R_APPROVE) and conf >= WEB_CONFIRM_MIN_CONFIDENCE
                    and len(sup) >= WEB_CONFIRM_MIN_DOMAINS and judged.identity_consistent is not False
                    and f.claimant_domains is not None)

    if mode == "audit":
        if contradiction:
            return Decision(A_CONTRADICTED, conf, "web_contradiction", reasons + [f"contradicting sources: {', '.join(sorted(con))}"])
        if confirmation and not pattern:
            return Decision(A_CONFIRMED, conf, "web_confirmation", reasons + [f"supporting sources: {', '.join(sorted(sup))}"])
        # A model "SUSPECT" that only means "found no evidence" is not a flag:
        # absence of web evidence on an obscure release is the normal case. It
        # becomes SUSPECT with a concrete reason: a catalog red flag, an identity
        # mismatch, a contradiction the model asserted without meeting the
        # citation bar, or a big track.
        concrete = bool(flags) or judged.identity_consistent is False or v == "CONTRADICTED" or (v == "SUSPECT" and big)
        if concrete and v != "CONFIRMED":
            return Decision(A_SUSPECT, conf, "model_suspect", reasons)
        if concrete:
            return Decision(A_SUSPECT, 0.5, "model_suspect", reasons)
        return Decision(A_UNVERIFIABLE, conf, "model_no_evidence", reasons)

    # review mode
    if contradiction:
        return Decision(R_REJECT, conf, "web_contradiction", reasons + [f"contradicting sources: {', '.join(sorted(con))}"])
    if confirmation and not pattern and not big and not flags:
        return Decision(R_APPROVE, conf, "web_confirmation", reasons + [f"supporting sources: {', '.join(sorted(sup))}"])
    if confirmation and big:
        reasons.append("clamp: big track needs trusted-source corroboration, web evidence alone is not enough")
    if confirmation and pattern:
        reasons.append("clamp: stillfloo-pattern profile is never approve-recommended")
    if confirmation and flags:
        reasons.append("clamp: red flags present, approve needs a human")
    return Decision(R_HUMAN, conf, "model_needs_human", reasons)


def approver_identity_alert(request: dict[str, Any], ev: Evidence | None = None,
                            ctx: AgentApprovalContext | None = None) -> str | None:
    """Captain 2026-10-11: alert on any approval by agent-hydra-main, admin_u or
    an unknown identity. A registered automation's own account
    (KNOWN_AGENT_APPROVERS) is accepted only while that automation is
    approved:true and its approval breaks none of ``agent_rule_breaks``; the
    alert then names the automation and the rule (it starts "automation ").

    core-backend records the approver on the row since 2026-10-11 (#10306 /
    #10307) as ``metadata.approval = {via, at, account, service, requester,
    isAgent, requestId}``, with via in validator | admin | low_risk_approve.
    Rows approved before that carry no record. For those, an approval the
    validator itself made (is_approved == true) is attributed to the validator,
    and one it declined is alerted as an admin-queue approval with no recorded
    approver.
    """
    if request.get("status") != "approved":
        return None
    meta = request.get("metadata") if isinstance(request.get("metadata"), dict) else {}
    approval = meta.get("approval") if isinstance(meta.get("approval"), dict) else None
    vd = request.get("verificationData") if isinstance(request.get("verificationData"), dict) else {}
    if approval:
        via = str(approval.get("via") or "").lower()
        if via == "validator":
            return None
        who = str(approval.get("account") or approval.get("email") or approval.get("approvedBy") or "").lower()
        if who in FORBIDDEN_APPROVERS:
            return f"approved by forbidden agent identity {who} (via {via or '?'})"
        if who in KNOWN_AGENT_APPROVERS:
            ctx = ctx or AgentApprovalContext()
            automation = KNOWN_AGENT_APPROVERS[who]
            if automation not in ctx.approved_automations:
                return (f"automation {automation} ({who}) approved while it is not approved:true in "
                        "policies/credit-approval-automation.json")
            breaks = agent_rule_breaks(request, ev, ctx, automation)
            if breaks:
                return f"automation {automation} ({who}) approval broke: " + "; ".join(breaks)
            return None
        if approval.get("isAgent") is True:
            return f"approved by an agent token {who or '(no account)'} (via {via or '?'})"
        if not who:
            return f"approval recorded without an approver account (via {via or '?'})"
        if who not in KNOWN_APPROVERS:
            return f"approved by unknown identity {who} (via {via or '?'})"
        return None
    if vd.get("is_approved") is True:
        return None
    return "approved although the validator declined it; approver identity not recorded (admin queue)"

# Mirror of core-backend agentApprovalGuard (T12, src/services/credit-requests/
# agentApprovalGuard.js) on the row as the SERVER stores it, shared by the
# decider (scope NOT_BIG_NO_HOLD) and uvn-under30 (scope BAND_A). The server is the authority; this only stops the decider sending an
# approval the server will refuse (one refused row rejects a whole batch).
SERVER_BAND_A_MIN_POPULARITY = 1
SERVER_BIG_TRACK_MIN_POPULARITY = 60
SERVER_BAND_A_MAX_POPULARITY = 29
SERVER_PROOF_REQUIRED_MIN_RISK = 100
SERVER_PROFILE_RISK_FIELD = "profile_risk_level"
SERVER_PROOF_PROFILE_RISK_LEVELS = ("high", "critical")
SERVER_PROOF_REQUEST_MARKER = "proofRequest"
SERVER_CLIENT_SOURCED = "client"


def server_big_track_reasons(row: dict[str, Any]) -> list[str]:
    pop = row.get("spotifyPopularity")
    pop = pop if isinstance(pop, int) and not isinstance(pop, bool) and 0 <= pop <= 100 else None
    out: list[str] = []
    if pop is None:
        out.append("popularity_unknown")
    elif pop >= SERVER_BIG_TRACK_MIN_POPULARITY:
        out.append("big_track")
    elif pop < SERVER_BAND_A_MIN_POPULARITY:
        out.append("popularity_unattributable")
    meta = row.get("metadata") if isinstance(row.get("metadata"), dict) else {}
    if meta.get("source") == SERVER_CLIENT_SOURCED:
        out.append("client_sourced_metadata")
    return out


def server_proof_reasons(row: dict[str, Any]) -> list[str]:
    vd = row.get("verificationData") if isinstance(row.get("verificationData"), dict) else {}
    out: list[str] = []
    if validator_conflict(vd):
        out.append("validator_hold")
    risk = _num(vd.get("total_risk_percent"))
    if risk is not None and risk >= SERVER_PROOF_REQUIRED_MIN_RISK:
        out.append("high_risk_score")
    hint = vd.get("band_hint")
    if hint is not None and hint != "A":
        out.append("validator_band_hint")
    if vd.get(SERVER_PROFILE_RISK_FIELD) in SERVER_PROOF_PROFILE_RISK_LEVELS:
        out.append("profile_risk")
    meta = row.get("metadata")
    if isinstance(meta, dict) and SERVER_PROOF_REQUEST_MARKER in meta:
        out.append("proof_requested")
    return out


def server_approval_refusal(row: dict[str, Any]) -> list[str]:
    """Reasons core-backend would refuse this decider approval ([] = allowed)."""
    proof = server_proof_reasons(row)
    if proof:
        return ["proof_required", *proof]
    vd = row.get("verificationData") if isinstance(row.get("verificationData"), dict) else {}
    if vd.get("is_approved") is True:
        return []
    reasons = server_big_track_reasons(row)
    if validator_conflict(vd):
        reasons.append("validator_hold")
    if not isinstance(vd.get("rule_risk_percent"), dict):
        reasons.append("verdict_missing")
    elif validator_rejected_rules(vd):
        reasons.append("reject_rule")
    return reasons


def server_band_a_refusal(row: dict[str, Any]) -> list[str]:
    """Reasons core-backend would refuse a uvn-under30 (scope BAND_A) approval of
    this row ([] = allowed): creditTrustBand must be A, and no claimant proof."""
    proof = server_proof_reasons(row)
    if proof:
        return ["proof_required", *proof]
    vd = row.get("verificationData") if isinstance(row.get("verificationData"), dict) else {}
    if vd.get("is_approved") is True:
        return []
    out: list[str] = []
    pop = row.get("spotifyPopularity")
    pop = pop if isinstance(pop, int) and not isinstance(pop, bool) and 0 <= pop <= 100 else None
    if pop is None:
        out.append("popularity_unknown")
    elif pop >= SERVER_BIG_TRACK_MIN_POPULARITY:
        out.append("big_track")
    elif pop > SERVER_BAND_A_MAX_POPULARITY:
        out.append("tier_t1_needs_evidence")
    elif pop < SERVER_BAND_A_MIN_POPULARITY:
        out.append("popularity_unattributable")
    rules = vd.get("rule_risk_percent")
    if not isinstance(rules, dict):
        out.append("verdict_missing")
    elif any((str(k).startswith("reject_") or str(k).startswith("review_"))
             and not (v == 0 or v is False or v is None) for k, v in rules.items()):
        out.append("reject_or_review_rule")
    meta = row.get("metadata") if isinstance(row.get("metadata"), dict) else {}
    if meta.get("source") == SERVER_CLIENT_SOURCED:
        out.append("client_sourced_metadata")
    if not row.get("spotifyTrackId"):
        out.append("no_spotify_track")
    return out

