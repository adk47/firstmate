"""Built-in verifiers + the registry the runner replays.

Every verifier is a pure ``fn(item) -> Verdict`` over the item's frozen evidence. Three kinds:

* ``*-rules-v1`` — the reference encoding of the Fable deciders' handoffs
  (data/user-decisions-fable-d1|d2|d3/rules-for-code-1028.md). It is the bar a production
  verifier is compared against, not a production verifier itself.
* ``*-recorded`` — replays a verdict some production component already recorded inside the
  evidence (core validator ``is_approved``, the claim-review scorer CRS action).
* ``*-control`` — deliberately unsafe negative controls (approve on a name match). They exist
  to prove the harness catches false approves and protection violations; a control that scores
  clean means the harness is broken.

Out-of-tree verifiers plug in two ways (see runner.load_verifier / runner.load_recorded):
``--verifier package.module:function`` or ``--verdicts file.jsonl`` (a shadow log of
``{"id": ..., "verdict": ..., "approved_roles": [...]}`` rows written by any component —
core endpoints, doc-verify ``dv_outcomes``, the claim writer's ``--shadow`` ledger).
"""

from __future__ import annotations

from typing import Any, Callable

from . import protections as P
from .schema import APPROVE, BIG_POPULARITY, DECLINE, UNKNOWN, WAIT, Verdict

Verifier = Callable[[dict[str, Any]], Verdict]

FREE_MAIL = {"gmail.com", "yahoo.com", "hotmail.com", "outlook.com", "icloud.com", "aol.com", "live.com",
             "msn.com", "me.com", "mail.ru", "yandex.ru", "proton.me", "protonmail.com", "gmx.de", "gmx.net",
             "qq.com", "163.com", "web.de", "ymail.com", "googlemail.com", "privaterelay.appleid.com"}
TEST_DOMAINS = {"cloudtestlabaccounts.com"}


# ── credits ──────────────────────────────────────────────────────────────────────────────

def _role_state(role: str, rev: dict[str, Any] | None) -> str:
    """approvable | declinable | <wait reason class> for one claimed role (d3 §1)."""
    if not rev:
        return "no_capture_for_role"
    srcs = rev.get("sources") or {}
    sp, td = srcs.get("spotify") or {}, srcs.get("tidal") or {}
    if P.id_credited(sp) or P.id_credited(td):
        if P.is_one_person(role, rev) and (P.id_contradicted(sp) or P.id_contradicted(td)):
            return "one_role_conflict_link_check"
        return "approvable"
    contra = [s for s in (sp, td) if P.id_contradicted(s)]
    if contra and P.is_one_person(role, rev) and any((s.get("n_credited") or 0) > 0 for s in contra):
        other_ok = all(s in contra or s.get("state") == "NO_RECORDING" for s in (sp, td))
        if other_ok:
            return "declinable"
    if contra:
        return "others_credited_multi_person" if not P.is_one_person(role, rev) else "nobody_in_role"
    reasons = {s.get("reason") for s in (sp, td) if s}
    for slug in ("name_only_credit_in_role_family", "incomplete_credit_snapshot", "waiting_for_fresh_capture"):
        if slug in reasons:
            return {"name_only_credit_in_role_family": "name_only",
                    "waiting_for_fresh_capture": "WAITING"}.get(slug, slug)
    if any("not_linked" in (r or "") for r in reasons):
        return "person_not_linked"
    return "unknown"


def credits_rules_v1(item: dict[str, Any]) -> Verdict:
    ev = item.get("evidence")
    if not ev:
        return Verdict(UNKNOWN, ["no_evidence"])
    dsp = ev.get("dsp")
    roles = list(ev.get("roles") or [])
    if not dsp or not roles:
        return Verdict(UNKNOWN, ["no_per_role_same_run_capture"])
    states = {r: _role_state(r, dsp.get(r)) for r in roles}
    approvable = [r for r, s in states.items() if s == "approvable"]
    declinable = [r for r, s in states.items() if s == "declinable"]
    if declinable and len(declinable) == len(roles):
        return Verdict(DECLINE, ["one_person_role_contradicted:" + ",".join(declinable)])
    if approvable:
        blocked = P.audit_approve(item, approvable)
        if not blocked:
            return Verdict(APPROVE, ["id_anchor:" + ",".join(approvable)], approved_roles=approvable)
        return Verdict(WAIT, ["anchored_but_guarded"] + blocked[:4])
    classes = sorted({s for s in states.values() if s not in ("approvable", "declinable")})
    if declinable:
        classes = ["one_role_contradicted_rest_unknown"] + classes
    gate = (ev.get("gate") or {}).get("decision")
    if gate != "allow":
        classes = [f"gate_{gate or 'missing'}"] + classes
    return Verdict(WAIT, classes)


def credits_validator_recorded(item: dict[str, Any]) -> Verdict:
    ev = item.get("evidence")
    if not ev or not ev.get("validator"):
        return Verdict(UNKNOWN, ["no_validator_record"])
    v = ev["validator"]
    if set(v.get("fraud_rules") or []) & P.FRAUD_RULES:
        return Verdict(DECLINE, ["validator_fraud_rule"])
    if v.get("is_approved") is True:
        return Verdict(APPROVE, ["validator_is_approved"])
    return Verdict(WAIT, ["validator_not_approved"])


def credits_name_match_control(item: dict[str, Any]) -> Verdict:
    """NEGATIVE CONTROL - approves on a name match (forbidden by the captain). Must score dirty."""
    ev = item.get("evidence") or {}
    dsp = ev.get("dsp") or {}
    hit = [r for r, rev in dsp.items()
           if any(s.get("name_match") or s.get("verdict") == "CREDITED" for s in (rev.get("sources") or {}).values())]
    agg = ev.get("dsp_aggregate") or {}
    if hit:
        return Verdict(APPROVE, ["name_match"], approved_roles=hit)
    if agg.get("spotify_name_match") or agg.get("tidal_name_match"):
        return Verdict(APPROVE, ["name_match_aggregate"])
    return Verdict(WAIT, ["no_name_match"])


# ── claims ───────────────────────────────────────────────────────────────────────────────

def _email_class(domain: str | None) -> str:
    d = (domain or "").lower()
    if not d:
        return "unknown"
    if d in TEST_DOMAINS:
        return "test"
    return "free" if d in FREE_MAIL else "corporate"


def claims_rules_v1(item: dict[str, Any]) -> Verdict:
    ev = item.get("evidence")
    if not ev:
        return Verdict(UNKNOWN, ["no_evidence"])
    flags = ev.get("flags") or {}
    pop, credits = ev.get("popularity") or 0, ev.get("credit_count") or 0
    email = ev.get("email_class") or _email_class(ev.get("email_domain"))
    # Decisive declines (d2 §2, §5) — every one reversible, never on velocity/age alone.
    if flags.get("watchlist") == "fraud" or flags.get("fraud_account"):
        return Verdict(DECLINE, ["claim_refused_fraud_account"])
    if email == "test":
        return Verdict(DECLINE, ["test_account"])
    if (ev.get("profile_type") == "organization" and ev.get("company_claim_on_add")
            and email == "free" and not ev.get("created_by_user_org")
            and (pop >= 80 or credits >= 5000 or (ev.get("prior_other_user_rejections") or 0) >= 2)):
        return Verdict(DECLINE, ["org_claim_role_contradiction"])
    if (ev.get("user_big_unrelated_claims_7d") or 0) >= 2 and pop >= 80:
        return Verdict(DECLINE, ["unrelated_big_claims_same_account"])
    gate = (ev.get("gate") or {}).get("decision")
    if gate != "allow":
        return Verdict(WAIT, [f"gate_{gate or 'missing'}"])
    proof = ev.get("proof") or {}
    if proof.get("e1_bound_code_verified") or proof.get("e3_oauth_strict"):
        blocked = P.audit_approve(item)
        if not blocked:
            return Verdict(APPROVE, ["bound_proof"])
        return Verdict(WAIT, ["proof_but_guarded"] + blocked[:3])
    if (ev.get("competing_users") or 0) > 0:
        return Verdict(WAIT, ["contested"])
    return Verdict(WAIT, ["needs_code" if ev.get("bound_surfaces") else "needs_catalog_link_then_code"])


def claims_crs_recorded(item: dict[str, Any]) -> Verdict:
    ev = item.get("evidence") or {}
    crs = ev.get("crs") or {}
    act = crs.get("action")
    if not act:
        return Verdict(UNKNOWN, ["no_crs_record"])
    if act == "approve":
        return Verdict(APPROVE, [f"crs_band_{crs.get('band')}"])
    if act in ("reject", "decline"):
        return Verdict(DECLINE, [f"crs_{act}"])
    return Verdict(WAIT, [f"crs_{act}"])


def claims_name_match_control(item: dict[str, Any]) -> Verdict:
    """NEGATIVE CONTROL - approves when account name folds to the profile name. Must score dirty."""
    ev = item.get("evidence") or {}
    if ev.get("name_fold") == "match" or ev.get("pasted_url_matches_raw"):
        return Verdict(APPROVE, ["name_or_pasted_url_match"])
    return Verdict(WAIT, ["no_match"])


# ── merges ───────────────────────────────────────────────────────────────────────────────

MERGE_FACTS = ("all_processed_claims_same_workspace", "no_org_profile", "no_login_or_primary_loser",
               "requester_named_profiles")


def merges_rules_v1(item: dict[str, Any]) -> Verdict:
    """V5 owner-confirmed merge checks (l1 build-plan §3.1; m1 d1-batch §2)."""
    ev = item.get("evidence")
    if not ev:
        return Verdict(UNKNOWN, ["no_evidence"])
    if ev.get("already_merged"):
        return Verdict(WAIT, ["already_merged_noop"])
    if ev.get("contested_two_workspaces"):
        return Verdict(DECLINE, ["contested_two_workspaces"])
    failed = [k for k in MERGE_FACTS if ev.get(k) is False]
    if failed:  # one known refusal is enough; unknown facts never turn into a yes
        return Verdict(WAIT, ["refused:" + ",".join(failed)])
    missing = [k for k in MERGE_FACTS if ev.get(k) is None]
    if missing:
        return Verdict(UNKNOWN, ["missing:" + ",".join(missing)])
    blocked = P.audit_approve(item)
    if blocked:
        return Verdict(WAIT, ["needs_human"] + blocked[:3])
    return Verdict(APPROVE, ["owner_confirmed_merge_eligible"])


def merges_cli_gate_recorded(item: dict[str, Any]) -> Verdict:
    """Replays muso-cli's owner-confirmed consolidate gate as recorded by m1's shadow log (d1-batch §4)."""
    ev = item.get("evidence") or {}
    g = ev.get("cli_gate")
    if not g:
        return Verdict(UNKNOWN, ["no_cli_gate_record"])
    return Verdict(APPROVE if g == "PASS" else WAIT, [f"cli_gate_{g}"])


REGISTRY: dict[str, dict[str, Any]] = {
    "credits-rules-v1": {"set": "credits", "fn": credits_rules_v1, "kind": "reference"},
    "credits-validator-recorded": {"set": "credits", "fn": credits_validator_recorded, "kind": "recorded"},
    "credits-name-match-control": {"set": "credits", "fn": credits_name_match_control, "kind": "control"},
    "claims-rules-v1": {"set": "claims", "fn": claims_rules_v1, "kind": "reference"},
    "claims-crs-recorded": {"set": "claims", "fn": claims_crs_recorded, "kind": "recorded"},
    "claims-name-match-control": {"set": "claims", "fn": claims_name_match_control, "kind": "control"},
    "merges-rules-v1": {"set": "merges", "fn": merges_rules_v1, "kind": "reference"},
    "merges-cli-gate-recorded": {"set": "merges", "fn": merges_cli_gate_recorded, "kind": "recorded"},
}

__all__ = ["REGISTRY", "Verifier", "BIG_POPULARITY"]
