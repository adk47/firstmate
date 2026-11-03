"""Independent shadow guard: audits every APPROVE a verifier emits against the frozen evidence.

The runner calls :func:`audit_approve` on every APPROVE regardless of the label, so a verifier
that "gets the label right" by approving without the industry protections is still caught.
Each returned string is a protection violation; the board shows the count and it must be 0
before any verifier can be considered for a captain switch.

Protections (captain 28 Oct 01:5xZ brief; d1/d2/d3 rules-for-code-1028):
* UNKNOWN never approves: an APPROVE on missing evidence is a violation.
* account gate ``allow`` (``hold`` / ``unknown`` approve nothing);
* big / common / flagged guard: popularity < 60 for a single-signal approve, not on the fraud
  watchlist (any tier), not on the IDP credit-hold list, no validator fraud rule;
* credits: same-run Spotify AND Tidal read for the track (both lanes resolved, not WAITING /
  error), at least one CREDITED-by-linked-id on EVERY approved role, a name match never counts,
  and no complete snapshot by id contradicting a one-person approved role;
* claims: a bound proof (E1 code on a catalog-bound surface, or E3 strict OAuth) — a pasted URL,
  name match or credit document never verifies a claim;
* merges: every profile a processed claim of the requester in one workspace, no organisation,
  no loser that is another account's login / primary, no popularity >= 60 or survivor with fewer
  credits without a human.
"""

from __future__ import annotations

from typing import Any

from .schema import BIG_POPULARITY

# Captain's cardinality rule (d1 §3 D1, d3 §1): roles one person holds on a recording.
ONE_PERSON_ROLES = {"mixing", "mastering", "remastering", "bass", "drums", "recording engineer",
                    "immersive mixing", "immersive mastering"}

# Validator findings that are fraud rules (d3 §1.4 / §7): risk-score lines are NOT fraud rules.
FRAUD_RULES = {"reject_high_velocity_profile", "reject_high_pop_name_mismatch", "reject_watchlist",
               "reject_deny_list", "reject_denied_user", "reject_denied_profile"}

ID_ANCHOR_REASON = "person_credited_in_role_family"
RESOLVED_STATES = {"CAPTURED", "NO_RECORDING"}


def is_one_person(role: str, role_ev: dict[str, Any] | None = None) -> bool:
    if role_ev and role_ev.get("one_person"):
        return True
    return role.strip().lower() in ONE_PERSON_ROLES


def id_credited(src: dict[str, Any] | None) -> bool:
    return bool(src) and src.get("verdict") == "CREDITED" and src.get("reason") == ID_ANCHOR_REASON


def id_contradicted(src: dict[str, Any] | None) -> bool:
    return (bool(src) and src.get("verdict") == "NOT_CREDITED"
            and src.get("reason") == "person_absent_from_complete_snapshot" and bool(src.get("complete")))


def _common(ev: dict[str, Any]) -> list[str]:
    out = []
    gate = ev.get("gate") or {}
    if gate.get("decision") != "allow":
        out.append(f"gate_not_allow:{gate.get('decision') or 'missing'}")
    flags = ev.get("flags") or {}
    if flags.get("watchlist"):
        out.append(f"watchlist:{flags['watchlist']}")
    if flags.get("idp_hold"):
        out.append("idp_credit_hold")
    if flags.get("fraud_account"):
        out.append("known_fraud_account")
    return out


def _credits(item: dict[str, Any], approved_roles: list[str] | None) -> list[str]:
    ev = item.get("evidence") or {}
    out = _common(ev)
    pop = ev.get("popularity")
    if pop is None:
        out.append("popularity_unknown")
    elif pop >= BIG_POPULARITY:
        out.append(f"big_track_pop_{pop}")
    fired = set((ev.get("validator") or {}).get("fraud_rules") or [])
    if fired & FRAUD_RULES:
        out.append("validator_fraud_rule:" + ",".join(sorted(fired & FRAUD_RULES)))
    claimed = list(ev.get("roles") or [])
    roles = approved_roles if approved_roles is not None else claimed
    if not roles:
        out.append("no_roles")
    extra = [r for r in roles if r not in claimed]
    if extra:
        out.append("approved_unclaimed_roles:" + ",".join(extra))
    dsp = ev.get("dsp")
    if not dsp:
        out.append("no_same_run_capture")
        return out
    for role in roles:
        rev = dsp.get(role)
        if not rev:
            out.append(f"no_capture_for_role:{role}")
            continue
        srcs = rev.get("sources") or {}
        sp, td = srcs.get("spotify"), srcs.get("tidal")
        for name, src in (("spotify", sp), ("tidal", td)):
            if not src or src.get("state") not in RESOLVED_STATES:
                out.append(f"{name}_not_read_same_run:{role}:{(src or {}).get('state')}")
        if not (id_credited(sp) or id_credited(td)):
            out.append(f"no_id_anchor:{role}")
        if is_one_person(role, rev) and (id_contradicted(sp) or id_contradicted(td)):
            out.append(f"one_person_role_contradicted:{role}")
    return out


def _claims(item: dict[str, Any]) -> list[str]:
    ev = item.get("evidence") or {}
    out = _common(ev)
    proof = ev.get("proof") or {}
    if not (proof.get("e1_bound_code_verified") or proof.get("e3_oauth_strict")):
        out.append("no_bound_proof")
    if (ev.get("competing_users") or 0) > 0:
        out.append("contested_claim")
    if (ev.get("popularity") or 0) >= BIG_POPULARITY and not proof.get("second_signal"):
        out.append(f"big_profile_single_signal_pop_{ev.get('popularity')}")
    return out


def _merges(item: dict[str, Any]) -> list[str]:
    ev = item.get("evidence") or {}
    out = []
    flags = ev.get("flags") or {}
    if flags.get("watchlist"):
        out.append(f"watchlist:{flags['watchlist']}")
    checks = {"all_processed_claims_same_workspace": "not_all_claimed_by_requester",
              "no_org_profile": "org_profile",
              "no_login_or_primary_loser": "login_or_primary_loser",
              "requester_named_profiles": "profiles_not_named_by_requester"}
    for key, slug in checks.items():
        v = ev.get(key)
        if v is None:
            out.append(f"unknown:{key}")
        elif not v:
            out.append(slug)
    if (ev.get("max_popularity") or 0) >= BIG_POPULARITY:
        out.append(f"big_profile_pop_{ev.get('max_popularity')}")
    if ev.get("survivor_has_fewer_credits"):
        out.append("survivor_has_fewer_credits")
    if ev.get("ambiguous_same_name"):
        out.append("ambiguous_same_name_profile")
    return out


def audit_approve(item: dict[str, Any], approved_roles: list[str] | None = None) -> list[str]:
    """Protection violations of an APPROVE on this item (empty = the approve is admissible)."""
    if not item.get("evidence"):
        return ["approve_on_missing_evidence"]
    s = item.get("set")
    if s == "credits":
        return _credits(item, approved_roles)
    if s == "claims":
        return _claims(item)
    if s == "merges":
        return _merges(item)
    return [f"unknown_set:{s}"]
