"""The verdict: a pure function of one evidence packet. No I/O, no clock, no model.

``verify(packet) -> Verdict`` is the whole rule set. The runner builds the packet from core, the
fresh capture and the account gate; the eval harness (verifier-eval-v1) builds it from labelled
history and calls the same function, so what is measured is exactly what runs.

Packet (a dict; every field optional unless noted, missing = UNKNOWN):

    request_id*         credit request uuid
    user_id             the submitting account (int)
    profile_id          the claimant's catalog profile
    profile_name        its name; profile_type "person" | "organization"
    track_id, track_title
    roles*              the claimed display roles, e.g. ["Mixing", "Producer"]
    popularity          CATALOG track popularity (never the client-sourced one); None = unknown = big
    artist_popularity   highest catalog popularity of the track's linked artists
    profile_credit_count
    verification_data   core verificationData (rule_risk_percent, is_approved, total_risk_percent)
    label_strings       [{"kind": "release_label" | "release_copyright_p" | ..., "string": "..."}]
    org_claim_processed True when the account holds a processed claim on this org profile
    capture             {"request_id", "requested_at", "read_at",
                         "roles": {role: {"sources": {"spotify": reading, "tidal": reading}}}}
    gate                {"decision": "allow" | "hold" | "unknown", "band", "reasons": [...]}
    flags               {"watchlist", "deny_user", "deny_profile", "idp_hold"}: each must be an
                        explicit bool; a missing key or None is UNKNOWN and blocks approval
    duplicate_of        id of an approved request by the same account for this track and role(s);
                        None = checked, none. Missing key or duplicate_unknown=True = UNKNOWN (blocks)
    artists_known       True when every linked artist's popularity was read (artist_popularity None
                        then means "no linked artist"); otherwise a None artist_popularity blocks
    name_collisions     other live catalog profiles with the same folded name (int); missing / None
                        = UNKNOWN = common (blocks). A one-token name blocks even at 0

A reading is one track x role x source from the IDP fresh capture (helpers.fresh_capture, read by
pod_driver.py):

    {"state": CAPTURED | NO_RECORDING | WAITING | NO_FRESH_CAPTURE | CAPTURE_ERROR | RECORDING_ABSENT,
     "helper_verdict": CREDITED | NOT_CREDITED | UNKNOWN | WAITING, "helper_reason": "...",
     "credited_in_family": [[name, credit, credited_by_id, raw_id, catalog_profile_id], ...] (complete),
     "credited_total": number of distinct contributor ids credited in the family (must match the list),
     "unresolved_in_family": [[name, credit], ...] name-only credits in the family (must be [] to decline),
     "claimant_name_match": bool,
     "complete_snapshot": bool, "captured_at": iso, "capture_ids": [...],
     "countries": {"US": reading, "GB": reading, ...}}     # Tidal per country, when read per country

Sources: data/user-decisions-fable-d1|d3/rules-for-code-1028.md (firstmate), the existing decider
(credit_review/decide.py), doc-verify's live_contradiction (credit_verify/docverify/crosscheck.py).
"""

from __future__ import annotations

import re
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Any

from credit_review.roles import ONE_PERSON_FAMILIES, family_of, fold

from . import VERSION

APPROVE, DECLINE, WAIT, DUPLICATE = "APPROVE", "DECLINE", "WAIT", "DUPLICATE"
SOURCES = ("spotify", "tidal")

# Per-source state of one role after reading the capture.
S_CREDITED = "credited_by_id"         # fresh, the person's own raw id holds a credit in the role family
S_ABSENT = "absent_complete"          # linked by id, absent from a COMPLETE fresh snapshot
S_NAME_ONLY = "name_only"             # the claimant's NAME is credited, never the linked id
S_LINK_MISMATCH = "link_mismatch"     # linked id absent, the claimant's exact name credited under another id
S_NOT_LINKED = "not_linked"           # the profile has no raw id on this DSP: absence proves nothing
S_NO_RECORDING = "no_recording"       # the catalog track has no recording on this DSP (unknown, not absence)
S_PENDING = "pending"                 # capture requested, not back yet
S_CONFLICT = "country_conflict"       # Tidal countries disagree
S_UNKNOWN = "unknown"                 # failed / stale / incomplete / not captured by this run

# Request-level thresholds (the IDP validator's and the decider's boundaries).
BIG_TRACK_POPULARITY = 60
BIG_ARTIST_POPULARITY = 90
BIG_PROFILE_CREDITS = 200             # d1: >= 200-credit profiles need two signals of different kinds
EDITORIAL_MAX_POPULARITY = 30         # decide.py: editorial roles only under pop 30
ROLE_STACK_FLAG = 5                   # d1 N5: flag >= 5 roles on one row

# One-person roles for a CONTRADICTION (captain's cardinality rule, d3 1028 §1: Mixing, Mastering,
# Bass, Drums; Remastering follows Mastering). The decider's one-person families plus bass / drums.
# Recording Engineer (d1 only) is deliberately NOT here: the narrower set can only cost a decline.
_INSTRUMENT_ONE_PERSON = re.compile(r"\b(bass|bass guitar|electric bass|bassist|drums?|drummer|drum kit)\b")
_NOT_BASS = re.compile(r"\b(double bass|contrabass|bass clarinet|bassoon|bass trombone|synth bass|bass vocals?)\b")


def one_person_role(role: str) -> bool:
    if family_of(role) in ONE_PERSON_FAMILIES:
        return True
    r = " ".join(re.sub(r"[^a-z]+", " ", (role or "").lower()).split())
    return bool(_INSTRUMENT_ONE_PERSON.search(r)) and not _NOT_BASS.search(r) and "programm" not in r


# Roles a DSP credit list never carries (d1 N13): only an org/label letter or V5 can settle them.
_NOT_DSP = re.compile(r"\b(video|director|directed|photo\w*|manag\w*|a ?& ?r|legal|lawyer|attorney|"
                      r"administ\w*|design\w*|artwork|marketing|publicist|stylist|choreograph\w*)\b")
_EDITORIAL = re.compile(r"\b(edit\w*|compil\w*|assembl\w*|pro tools)\b")
_ORG = re.compile(r"\b(record label|label|publisher|publishing|copyright|distributor|administrator)\b")


def role_kind(role: str) -> str:
    """person_dsp (a DSP can credit it) | org | not_dsp | editorial."""
    r = (role or "").lower()
    if _ORG.search(r) or family_of(role) == "org":
        return "org"
    if family_of(role) == "anr" or _NOT_DSP.search(r):
        return "not_dsp"
    if _EDITORIAL.search(r) and family_of(role) not in ONE_PERSON_FAMILIES:
        return "editorial"
    return "person_dsp"


# Validator rules. reject_* are findings; score:* / risk_score_at_or_above_threshold are not
# (d3 §7). A SOURCE rule is answered by evidence of that source; a FRAUD rule blocks approval.
SOURCE_RULES = frozenset({"reject_publisher_label_credit", "reject_artist_credit", "reject_individual_org_credit"})


def validator_fraud_rules(vd: Any) -> list[str]:
    vd = vd if isinstance(vd, dict) else {}
    rules = vd.get("rule_risk_percent") if isinstance(vd.get("rule_risk_percent"), dict) else {}
    out = []
    for k, v in rules.items():
        try:
            fired = float(v) > 0
        except (TypeError, ValueError):
            fired = False
        if fired and str(k).startswith("reject_") and k not in SOURCE_RULES:
            out.append(str(k))
    return sorted(out)


def _ts(v: Any) -> datetime | None:
    if not isinstance(v, str) or not v:
        return None
    try:
        t = datetime.fromisoformat(v.replace("Z", "+00:00"))
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)


# ── one source ─────────────────────────────────────────────────────────────────
@dataclass
class SourceRead:
    source: str
    state: str
    why: str
    others: list[str] = field(default_factory=list)      # folded names credited in the family, not by the id
    # Identity of each OTHER credited contributor: (raw id on this DSP, catalog profile id or None).
    # Spotify and Tidal ids are different namespaces, so "the same person on both" is proven only by
    # one catalog profile holding both raw ids (QA @80c295a): never by the name.
    other_ids: list[tuple[str | None, str | None]] = field(default_factory=list)
    captured_at: str | None = None
    capture_ids: list[str] = field(default_factory=list)
    countries: dict[str, str] | None = None


def _read_one(source: str, rd: Any, requested_at: datetime | None) -> SourceRead:
    if not isinstance(rd, dict):
        return SourceRead(source, S_UNKNOWN, "not read by this run")
    state = str(rd.get("state") or "")
    hv = str(rd.get("helper_verdict") or "")
    reason = str(rd.get("helper_reason") or "")
    credited = [c for c in (rd.get("credited_in_family") or []) if isinstance(c, (list, tuple)) and len(c) >= 3]
    by_id = any(bool(c[2]) for c in credited)
    others = sorted({fold(str(c[0] or "")) for c in credited if not c[2]} - {""})
    oids = sorted({(str(c[3]) if len(c) > 3 and c[3] else None, str(c[4]) if len(c) > 4 and c[4] else None)
                   for c in credited if not c[2]}, key=lambda t: (t[0] or "", t[1] or ""))
    total = rd.get("credited_total")
    listed = {str(c[3]) for c in credited if len(c) > 3 and c[3]}
    unresolved = rd.get("unresolved_in_family")
    if not isinstance(total, int) or isinstance(total, bool) or total != len(listed) \
            or not isinstance(unresolved, list) or unresolved:
        # The list is not provably the complete contributor set (clipped, no ids / no total, or a
        # name-only credit in the role family that resolves to nobody we can identify, QA @8c5a44f):
        # "exactly one other person" is unproven, so it can never carry a contradiction.
        oids = oids + [(None, None)]
    base = dict(captured_at=rd.get("captured_at"), capture_ids=list(rd.get("capture_ids") or [])[:6],
                other_ids=oids)
    name_match = bool(rd.get("claimant_name_match"))
    if state == "NO_RECORDING" or reason == f"no_{source}_recording_on_track":
        return SourceRead(source, S_NO_RECORDING, f"no {source} recording on the catalog track", **base)
    if reason.startswith("person_not_linked_on_") and not name_match:
        # A catalog fact that no capture can change (no raw id on this DSP): never "pending" (junk-b1).
        return SourceRead(source, S_NOT_LINKED, f"profile not linked on {source}", others, **base)
    if state in ("NO_FRESH_CAPTURE", "CAPTURE_ERROR", "RECORDING_ABSENT"):
        # Final: the window closed without a usable receipt (the helper still says WAITING then).
        return SourceRead(source, S_UNKNOWN, f"capture {state.lower()}", **base)
    if state == "WAITING" or hv == "WAITING" or reason == "waiting_for_fresh_capture":
        return SourceRead(source, S_PENDING, "fresh capture requested, not back yet", **base)
    if state != "CAPTURED":
        # Only an explicit CAPTURED reading can anchor or contradict; a failed, absent, missing or
        # unknown state is UNKNOWN (QA @2d6833a).
        return SourceRead(source, S_UNKNOWN, f"capture state {state.lower() or 'missing'}", **base)
    captured = _ts(rd.get("captured_at"))
    fresh = captured is not None and requested_at is not None and captured > requested_at
    if reason.startswith("person_not_linked_on_"):
        # A catalog fact (no raw id on this DSP): it needs no capture. The NAME read does.
        if name_match and fresh:
            return SourceRead(source, S_NAME_ONLY, f"profile not linked on {source}; the claimant's name is "
                              "credited in the role family", others, **base)
        return SourceRead(source, S_NOT_LINKED, f"profile not linked on {source}", others, **base)
    if not fresh:
        # Same run only: a receipt not captured after OUR request never counts, for anything.
        return SourceRead(source, S_UNKNOWN, "capture not newer than this run's request (stale or missing)",
                          **base)
    if hv == "CREDITED" and reason == "person_credited_in_role_family" and by_id:
        return SourceRead(source, S_CREDITED, "credits the claimant's linked id in the role family", others, **base)
    if hv == "CREDITED":
        # The helper says credited but the packet shows no id-credited pair: never trust it.
        return SourceRead(source, S_UNKNOWN, "helper CREDITED without an id-credited pair in the packet", **base)
    if hv == "NOT_CREDITED" and reason == "person_absent_from_complete_snapshot" \
            and rd.get("complete_snapshot") is True:      # missing / null completeness is UNKNOWN (QA @2d6833a)
        if name_match:
            return SourceRead(source, S_LINK_MISMATCH, "linked id absent; the claimant's name is credited under "
                              "another contributor id (fix the link)", others, **base)
        return SourceRead(source, S_ABSENT, "linked id absent from a complete fresh snapshot", others, **base)
    if reason == "name_only_credit_in_role_family" or name_match:
        return SourceRead(source, S_NAME_ONLY, "only the claimant's name is credited, never the linked id",
                          others, **base)
    return SourceRead(source, S_UNKNOWN, reason or hv.lower() or "unreadable", others, **base)


def read_source(source: str, rd: Any, requested_at: datetime | None) -> SourceRead:
    """One source. Read per country (Tidal), every country must agree; UNKNOWN never counts."""
    countries = rd.get("countries") if isinstance(rd, dict) and isinstance(rd.get("countries"), dict) else None
    if not countries:
        return _read_one(source, rd, requested_at)
    per = {cc: _read_one(source, r, requested_at) for cc, r in sorted(countries.items())}
    states = {r.state for r in per.values()}
    first = next(iter(per.values()))
    cmap = {cc: r.state for cc, r in per.items()}
    if len(states) == 1:
        others = sorted({o for r in per.values() for o in r.others})
        oids = sorted({o for r in per.values() for o in r.other_ids}, key=lambda t: (t[0] or "", t[1] or ""))
        return SourceRead(source, first.state, f"every {source} country ({len(per)}): {first.why}", others,
                          oids, first.captured_at, first.capture_ids, cmap)
    if S_CREDITED in states and S_ABSENT in states:
        return SourceRead(source, S_CONFLICT, f"{source} countries disagree", countries=cmap)
    if S_PENDING in states:
        return SourceRead(source, S_PENDING, f"some {source} countries not back yet", countries=cmap)
    return SourceRead(source, S_UNKNOWN, f"{source} countries do not all agree ({sorted(states)})", countries=cmap)


# ── one role ──────────────────────────────────────────────────────────────────
@dataclass
class RoleVerdict:
    role: str
    kind: str
    one_person: bool
    outcome: str                  # anchored | contradicted | wait
    reason: str
    need: str | None
    anchor: str                   # both | single | none
    spotify: dict[str, Any] = field(default_factory=dict)
    tidal: dict[str, Any] = field(default_factory=dict)


def _sd(s: SourceRead) -> dict[str, Any]:
    d: dict[str, Any] = {"state": s.state, "why": s.why}
    if s.others:
        d["others"] = s.others[:8]
    if s.other_ids:
        d["other_ids"] = [list(t) for t in s.other_ids[:8]]
    if s.captured_at:
        d["captured_at"] = s.captured_at
    if s.capture_ids:
        d["capture_ids"] = s.capture_ids
    if s.countries:
        d["countries"] = s.countries
    return d


def same_person(sp: SourceRead, ti: SourceRead) -> str | None:
    """The catalog profile id when each DSP credits exactly ONE other contributor (by raw id) and one
    catalog profile holds both raw ids; None otherwise (identity unproven = no contradiction)."""
    if len(sp.other_ids) != 1 or len(ti.other_ids) != 1:
        return None
    (sid, scat), (tid, tcat) = sp.other_ids[0], ti.other_ids[0]
    if not (sid and tid and scat and tcat) or scat != tcat:
        return None
    return scat


def verify_role(role: str, capture: dict[str, Any] | None, requested_at: datetime | None) -> RoleVerdict:
    kind = role_kind(role)
    one = one_person_role(role)
    srcs = (((capture or {}).get("roles") or {}).get(role) or {}).get("sources") or {}
    sp, ti = (read_source(s, srcs.get(s), requested_at) for s in SOURCES)
    rv = RoleVerdict(role, kind, one, "wait", "", None, "none", _sd(sp), _sd(ti))

    def wait(reason: str, need: str | None, anchor: str = "none") -> RoleVerdict:
        rv.reason, rv.need, rv.anchor = reason, need, anchor
        return rv

    if kind == "not_dsp":
        return wait("not_dsp_verifiable: DSP credits never carry this role", "org_or_label_letter")
    if kind == "org":
        return wait("org_role: decided in the org lane (label / P-line), not by person credits", None)
    if capture is None or requested_at is None:
        return wait("no_fresh_capture: this run requested no Spotify+Tidal capture", "fresh_capture")
    states = {sp.state, ti.state}
    if sp.state == S_CREDITED and ti.state == S_CREDITED:
        rv.outcome, rv.anchor = "anchored", "both"
        rv.reason = "Spotify AND Tidal fresh captures credit the claimant's linked id in this role family"
        return rv
    if S_CREDITED in states:
        other = ti if sp.state == S_CREDITED else sp
        if other.state in (S_ABSENT, S_CONFLICT):
            return wait(f"dsp_conflict: one DSP credits the claimant by id, {other.source} is {other.state}",
                        "link_check", "single")
        if other.state == S_PENDING:
            return wait(f"capture_pending: {other.source} not back yet (the other DSP credits by id)", None,
                        "single")
        return wait(f"single_dsp_anchor: only one DSP credits the claimant by id ({other.source}: "
                    f"{other.state}); an approval needs Spotify AND Tidal", "second_dsp_anchor", "single")
    if S_PENDING in states:
        return wait("capture_pending: fresh capture not back yet", None)
    if S_LINK_MISMATCH in states:
        return wait("link_mismatch: the claimant's name is credited under a different contributor id than the "
                    "one linked", "fix_profile_link")
    if sp.state == S_ABSENT and ti.state == S_ABSENT:
        if one and len(sp.others) == 1 and sp.others == ti.others:
            same = same_person(sp, ti)
            if same:
                rv.outcome, rv.reason = "contradicted", (
                    f"one-person role credited to {sp.others[0]} (catalog profile {same}, the same person on both) "
                    "on complete fresh Spotify AND Tidal snapshots; the claimant's linked id is absent from both")
                return rv
            return wait("one_person_identity_unproven: the same NAME is credited on both DSPs, but no catalog "
                        "profile holds both contributor ids, so it is not proven to be one person",
                        "document_for_this_track")
        if one and (sp.others or ti.others):
            return wait("one_person_conflict: not exactly one and the same other person on both DSPs "
                        f"(spotify {len(sp.others)}, tidal {len(ti.others)})", "document_for_this_track")
        if sp.others or ti.others:
            return wait("others_only: a multi-person role credited to others only (NOT FOUND, never a decline)",
                        "document_for_this_track")
        return wait("nobody_in_role: complete snapshots credit nobody in this role family",
                    "document_for_this_track")
    if S_ABSENT in states:
        absent = sp if sp.state == S_ABSENT else ti
        other = ti if absent is sp else sp
        if one and len(absent.others) == 1 and other.state == S_NO_RECORDING:
            return wait(f"one_source_contradiction: {absent.source} credits {absent.others[0]} only and "
                        f"{other.source} has no recording (a decline needs both DSPs)", "document_for_this_track")
        return wait(f"absent_on_{absent.source}: {other.source} is {other.state}", "document_for_this_track")
    if S_NAME_ONLY in states:
        return wait("needs_profile_link: the claimant's name is credited but the profile has no contributor id "
                    "on that DSP; a name is never an anchor", "link_profile")
    if S_NOT_LINKED in states:
        return wait("person_not_linked: the profile has no Spotify/Tidal contributor id", "link_profile")
    if states == {S_NO_RECORDING}:
        return wait("no_recording: the track has no Spotify or Tidal recording in the catalog",
                    "document_for_this_track")
    bad = sp if sp.state != S_NO_RECORDING else ti
    return wait(f"unknown: {bad.source} {bad.why}", None)


# ── org lane (d3 §3: evidence only; approving on it is a captain call) ────────────
GENERIC_ORG_TOKENS = frozenset(
    "the a an and of records record recordings recording music musique musik publishing publisher publishers "
    "pub label labels entertainment ent group media productions production prod studios studio inc llc ltd "
    "limited gmbh srl sl sa sas bv ab oy co company corp corporation lp llp plc pty division exclusive "
    "license licence licensed to by under from distributed p c".split())


def org_tokens(name: str) -> frozenset[str]:
    return frozenset(t for t in fold(name).split() if t not in GENERIC_ORG_TOKENS and len(t) > 1)


def org_string_match(org_name: str, strings: list[dict[str, Any]] | None) -> tuple[str, list[str]]:
    """(match | no_match | unknown, the strings that matched). Token-set containment of the org's
    DISTINCTIVE tokens (generic words dropped), so word order and "A Division of X" do not matter."""
    toks = org_tokens(org_name)
    if not toks:
        return "unknown", []          # an org name made only of generic words never matches anything
    if not strings:
        return "unknown", []          # a missing string is UNKNOWN, never absence
    hits = [str(s.get("string")) for s in strings
            if isinstance(s, dict) and toks <= set(fold(str(s.get("string") or "")).split())]
    return ("match" if hits else "no_match"), hits[:4]


# ── the request ────────────────────────────────────────────────────────────────
@dataclass
class Verdict:
    request_id: str
    verdict: str
    reason_class: str             # the machine class: approve | decline | duplicate | <wait class>
    reason: str
    need: str | None
    confidence: float
    approve_roles: list[str]
    decline_roles: list[str]
    role_edit_roles: list[str]
    anchor: str                   # both | single | none: the strongest per-role anchor seen
    blockers: list[str]
    signals: list[str]
    roles: list[dict[str, Any]]
    evidence: dict[str, Any]
    version: str = VERSION

    def as_dict(self) -> dict[str, Any]:
        return asdict(self)


# WAIT reason priority: the first that applies names the request (the rest stay on the roles).
_WAIT_ORDER = ("capture_pending", "link_mismatch", "needs_profile_link", "person_not_linked", "dsp_conflict",
               "single_dsp_anchor", "one_source_contradiction", "one_person_identity_unproven", "one_person_conflict", "others_only",
               "nobody_in_role", "absent_on_", "no_recording", "editorial_role", "not_dsp_verifiable", "org_",
               "no_fresh_capture", "unknown")


GUARD_FLAGS = ("watchlist", "deny_user", "deny_profile", "idp_hold")


def blockers_of(p: dict[str, Any]) -> list[str]:
    """Request-level guards in front of every APPROVE (none of them can decline)."""
    out: list[str] = []
    gate = p.get("gate") if isinstance(p.get("gate"), dict) else None
    if gate is None:
        out.append("gate_unknown: the account gate was not read")
    elif gate.get("decision") != "allow":
        out.append(f"gate_{gate.get('decision') or 'unknown'}: "
                   + "; ".join(map(str, gate.get("reasons") or []))[:160])
    elif str(gate.get("band") or "").lower() == "red":
        out.append("gate_red_band")
    flags = p.get("flags") if isinstance(p.get("flags"), dict) else {}
    for k in GUARD_FLAGS:
        val = flags.get(k)
        if val is True:
            out.append(f"flagged_{k}")
        elif val is not False:
            # Only an explicit False clears a guard: missing / None / anything else is UNKNOWN.
            out.append(f"flags_unknown: {k} not read")
    vd = p.get("verification_data")
    if not isinstance(vd, dict) or not isinstance(vd.get("rule_risk_percent"), dict):
        # No validator findings read: "no fraud rule fired" is not established (QA @8487d4f).
        out.append("validator_unknown: verificationData / rule_risk_percent missing or malformed")
    fraud = validator_fraud_rules(vd)
    if fraud:
        out.append("validator_fraud_rule: " + ",".join(fraud))
    pop, apop = p.get("popularity"), p.get("artist_popularity")
    if not isinstance(pop, (int, float)) or isinstance(pop, bool):
        out.append("big_track: catalog popularity unknown (unknown = big)")
    elif pop >= BIG_TRACK_POPULARITY:
        out.append(f"big_track: popularity {pop} >= {BIG_TRACK_POPULARITY}")
    if isinstance(apop, (int, float)) and not isinstance(apop, bool):
        if apop >= BIG_ARTIST_POPULARITY:
            out.append(f"big_artist: artist popularity {apop} >= {BIG_ARTIST_POPULARITY}")
    elif p.get("artists_known") is not True:
        # None is fine only when every linked artist was read and there are none (artists_known).
        out.append("big_artist: linked artist popularity unknown (unknown = big)")
    cc = p.get("profile_credit_count")
    if not isinstance(cc, int) or isinstance(cc, bool):
        out.append("big_profile: profile credit count unknown (unknown = big)")
    elif cc >= BIG_PROFILE_CREDITS:
        out.append(f"big_profile: {cc} credits >= {BIG_PROFILE_CREDITS} (two signals of different kinds)")
    if p.get("duplicate_unknown") is True or "duplicate_of" not in p:
        why = p.get("duplicate_unknown_reason")
        out.append("duplicate_unknown: " + (f"{why}: the profile's approved list is past the page bound and was not "
                                            "read to the end" if why == "evidence_unbounded" else
                                            "the approved-request duplicate check could not be read"))
    nc = p.get("name_collisions")
    toks = fold(str(p.get("profile_name") or "")).split()
    if not isinstance(nc, int) or isinstance(nc, bool) or nc < 0:
        out.append("common_name: catalog name collisions unknown (unknown = common)")
    elif nc > 0:
        out.append(f"common_name: {nc} other catalog profiles share the name")
    elif len(toks) <= 1:
        out.append("common_name: one-token profile name")
    return out


def verify(p: dict[str, Any]) -> Verdict:
    rid = str(p.get("request_id") or "")
    roles = list(dict.fromkeys(str(r) for r in (p.get("roles") or []) if str(r).strip()))
    capture = p.get("capture") if isinstance(p.get("capture"), dict) else None
    requested_at = _ts((capture or {}).get("requested_at"))
    rvs = [verify_role(r, capture, requested_at) for r in roles]
    blockers = blockers_of(p)
    signals: list[str] = []
    if len(roles) >= ROLE_STACK_FLAG:
        signals.append(f"role_stacking: {len(roles)} roles on one row")
    pop = p.get("popularity")
    for r in rvs:
        # Editorial roles: approvable only on a both-DSP id anchor under pop 30 (decide.py).
        if r.kind == "editorial" and r.outcome == "anchored" and not (
                isinstance(pop, (int, float)) and not isinstance(pop, bool) and pop < EDITORIAL_MAX_POPULARITY):
            r.outcome, r.need = "wait", "org_or_label_letter"
            r.reason = f"editorial_role: approved only on a both-DSP id anchor under pop {EDITORIAL_MAX_POPULARITY}"
    org = None
    if any(r.kind == "org" for r in rvs):
        status, hits = org_string_match(str(p.get("profile_name") or ""), p.get("label_strings"))
        org = {"org_string_match": status, "matched": hits, "profile_type": p.get("profile_type"),
               "org_claim_processed": p.get("org_claim_processed")}
        for r in rvs:
            if r.kind != "org":
                continue
            if p.get("profile_type") == "person":
                r.reason, r.need = "org_role_on_person_profile: an organization role claimed on a person", \
                    "org_profile"
            elif status == "match":
                r.reason, r.need = ("org_label_anchor: the org name is on the track's label / P-line string; "
                                    "approving on it is a captain call (declined-org-label-anchor-call)"), None
            elif status == "no_match":
                r.reason, r.need = ("org_not_on_label_strings: the org name is on none of the track's label "
                                    "strings"), "org_or_label_letter"
            else:
                r.reason, r.need = "org_string_missing: no usable label / P-line string (UNKNOWN)", None
    vd = p.get("verification_data") if isinstance(p.get("verification_data"), dict) else {}
    evidence: dict[str, Any] = {
        "capture_request_id": (capture or {}).get("request_id"),
        "capture_requested_at": (capture or {}).get("requested_at"),
        "capture_read_at": (capture or {}).get("read_at"),
        "popularity": pop, "artist_popularity": p.get("artist_popularity"),
        "profile_credit_count": p.get("profile_credit_count"),
        "gate": p.get("gate"), "flags": p.get("flags"),
        "validator_fraud_rules": validator_fraud_rules(vd),
        "validator_total_risk": vd.get("total_risk_percent"),
        "validator_is_approved": vd.get("is_approved")}
    if org:
        evidence["org"] = org
    anchor = ("both" if any(r.anchor == "both" for r in rvs)
              else "single" if any(r.anchor == "single" for r in rvs) else "none")

    def out(verdict: str, reason: str, need: str | None, conf: float, approve=(), decline=(), edit=(),
            cls: str | None = None) -> Verdict:
        return Verdict(rid, verdict, cls or verdict.lower(), reason[:600], need, round(conf, 2), list(approve), list(decline), list(edit),
                       anchor, blockers, signals, [asdict(r) for r in rvs], evidence)

    if not rid or not rvs:
        return out(WAIT, "malformed: no request id or no claimed role", None, 0.0, cls="malformed")
    dup = p.get("duplicate_of")
    if dup:
        return out(DUPLICATE, f"duplicate_noop: the account already holds approved request {dup} for this track "
                   "and role", None, 0.9)
    contradicted = [r.role for r in rvs if r.outcome == "contradicted"]
    if len(contradicted) == len(rvs):
        return out(DECLINE, "every claimed role is contradicted: " + "; ".join(r.reason for r in rvs),
                   None, 0.9, decline=contradicted)
    if contradicted:
        signals.append("partly_contradicted: " + ", ".join(contradicted))
    anchored = [r.role for r in rvs if r.outcome == "anchored"]
    if anchored and not blockers:
        rest = [r.role for r in rvs if r.outcome != "anchored"]
        conf = 0.95 if not rest else 0.85
        if str((p.get("gate") or {}).get("band") or "").lower() == "amber":
            conf -= 0.1
        return out(APPROVE, "Spotify AND Tidal same-run captures credit the claimant's linked id in: "
                   + ", ".join(anchored) + (f"; role edit before approval: {', '.join(rest)}" if rest else ""),
                   None, conf, approve=anchored, decline=contradicted, edit=rest)
    if anchored:
        need = "account_proof" if any(b.startswith(("gate_", "flagged_")) for b in blockers) else "second_signal"
        return out(WAIT, "anchored_but_blocked: " + "; ".join(blockers), need, 0.6, decline=contradicted,
                   cls="anchored_but_blocked")
    waits = [r for r in rvs if r.outcome == "wait"]
    pick = None
    for key in _WAIT_ORDER:
        pick = next((r for r in waits if r.reason.startswith(key)), None)
        if pick:
            break
    pick = pick or waits[0]
    return out(WAIT, f"{pick.role}: {pick.reason}", pick.need, 0.5, decline=contradicted,
               cls=pick.reason.split(":", 1)[0])
