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

from dataclasses import dataclass, field
from typing import Any

from .evidence import Evidence
from .judge import JudgeResult

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


def approver_identity_alert(request: dict[str, Any]) -> str | None:
    """Captain 2026-10-11: alert on any approval by agent-hydra-main, admin_u or
    an unknown identity.

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
