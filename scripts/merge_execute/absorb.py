"""`dup-dsp-absorb`: THE rule for folding an UNCLAIMED duplicate that carries the DSP id INTO the
requester's CLAIMED profile (program-lead-fable-p2 ruling 2026-10-30 23:24Z, [key=l7-switch-on-0-runnable] (B),
ruling id l7-1030). PURE: facts in, verdict out. No I/O, no execution.

Direction: source = the linked copy (holds the Spotify/Tidal contributor id credited under the
claimant's name), survivor = the profile the requester has CLAIMED (the presented profile). The DSP id
and the credits move onto the claimed survivor.

Eligible iff every check below passes; the first failure decides (order = cheapest certain refusal
first). A fact that was not read is None and yields `unavailable`, never `eligible`.
  1  ids readable, source != survivor
  2  account held / watchlisted / deny-listed (R8)                       -> held
  3  survivor is a PROCESSED claim of the requester (own claim or a team
     the requester owns/admins)                                          -> refused NOT_REQUESTERS_CLAIM
  4  source has 0 claims by anyone (any status but rejected / deleted)  -> refused SOURCE_CLAIMED
  5  source is nobody's login and nobody's confirmed primary            -> refused SOURCE_IS_IDENTITY
  6  source is not a compilation_profile / organization; survivor not
     an organization                                                     -> refused SOURCE_TYPE / ORG
  7  neither profile merged / deleted / in an in-flight merge            -> refused MERGED_OR_IN_FLIGHT
  8  same person: same-run CAPTURED Spotify/Tidal readings tie >= 3 of
     the requester's credits (distinct tracks) to a contributor id the
     source holds, under the claimant's exact folded name; label /
     publisher role credits never count                                  -> needs_evidence SAME_PERSON
  9  common name (core dsp-dup-1 isCommonName: one token, any other live
     catalog profile with the name, or collisions unknown) passes only
     with that same >= 3-track id evidence AND no tie of the claimant's
     name to a DIFFERENT contributor id on those tracks                  -> needs_evidence COMMON_NAME
 10  label/publisher: a survivor or source credited as Record Label /
     Publisher on the tying tracks                                       -> refused LABEL_PUBLISHER
"""
from __future__ import annotations

import re
import unicodedata
from typing import Any

RULE_VERSION = "dup-dsp-absorb/1"
RULING_ID = "l7-1030"
MIN_TIES = 3
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
LABEL_ROLES = re.compile(r"(?i)\b(record label|label|publisher|publishing|copyright|phonographic|distributor)\b")
# QA #1556: a source claim blocks unless it is EXPLICITLY terminal. Core's AWAITING_REVIEW includes 'reverted'
# (claim_executor.OPEN_STATUSES), and an unknown or missing status is never assumed dead (fail closed). Deleted
# claims never reach here (the reader filters deletedat IS NULL).
TERMINAL_CLAIM = ("rejected",)
BAD_SOURCE_TYPES = ("compilation_profile", "organization")


def fold(text: Any) -> str:
    t = unicodedata.normalize("NFKD", str(text or ""))
    t = "".join(ch for ch in t if not unicodedata.combining(ch))
    return re.sub(r"\s+", " ", re.sub(r"[^0-9a-zA-Z]+", " ", t).lower()).strip()


def is_common_name(name: Any, collisions: Any) -> tuple[bool, str | None]:
    """core dsp-dup-1 isCommonName, same definition."""
    if collisions is None:
        return True, "name collisions unknown (unknown = common)"
    if int(collisions) > 0:
        return True, f"{int(collisions)} other catalog profiles share the name"
    if len(fold(name).split()) <= 1:
        return True, "one-token name"
    return False, None


def _v(verdict: str, code: str | None, reasons: list[str], **kw: Any) -> dict:
    return {"verdict": verdict, "code": code, "reasons": reasons, "rule_version": RULE_VERSION, **kw}


def decide(f: dict) -> dict:
    """f = {
      user_id, survivor, source,                       # ids (str)
      holds: [str] | None,                             # R8 facts (empty = clear)
      survivor_claims: [{status, user_id, team_id}] | None, requester_teams: [str] | None,
      source_claims: [{status}] | None, source_identity: [user ids] | None,
      survivor_profile: {sub_type, merged_to, deleted, credits} | None, source_profile: {...} | None,
      in_flight: bool | None,
      person_name: str, name_collisions: int | None,
      readings: [{track, captured: bool, same_run: bool, credited: [[name, credit, raw_id, holder]]}] | None,
      source_raw_ids: [str] | None }                   # contributor ids the source holds
    """
    sv, so = str(f.get("survivor") or "").lower(), str(f.get("source") or "").lower()
    if not (UUID.match(sv) and UUID.match(so)) or sv == so:
        return _v("refused", "BAD_INPUT", ["unreadable or identical profile ids"])
    need = ("holds", "survivor_claims", "requester_teams", "source_claims", "source_identity", "survivor_profile",
            "source_profile", "in_flight", "readings", "source_raw_ids")
    missing = [k for k in need if f.get(k) is None]
    if missing:
        return _v("unavailable", "UNREAD", [f"not read: {', '.join(missing)}"])
    if f["holds"]:
        return _v("held", "ACCOUNT_HOLD", list(f["holds"]))
    uid, teams = str(f.get("user_id")), {str(t) for t in f["requester_teams"]}
    if not any(c.get("status") == "processed" and (str(c.get("user_id")) == uid or str(c.get("team_id")) in teams)
               for c in f["survivor_claims"]):
        return _v("refused", "NOT_REQUESTERS_CLAIM", ["the survivor is not a processed claim of the requester"])
    live = [str(c.get("status")) for c in f["source_claims"] if c.get("status") not in TERMINAL_CLAIM]
    if live:
        return _v("refused", "SOURCE_CLAIMED", [f"the source profile has a non-terminal claim ({', '.join(sorted(set(live)))})"])
    if f["source_identity"]:
        return _v("refused", "SOURCE_IS_IDENTITY", ["the source is an account's login or confirmed primary"])
    sp, vp = f["source_profile"], f["survivor_profile"]
    if str(sp.get("sub_type") or "").lower() in BAD_SOURCE_TYPES:
        return _v("refused", "SOURCE_TYPE", [f"source is a {sp.get('sub_type')}"])
    if str(vp.get("sub_type") or "").lower() == "organization":
        return _v("refused", "ORG", ["survivor is an organization"])
    if sp.get("merged_to") or sp.get("deleted") or vp.get("merged_to") or vp.get("deleted") or f["in_flight"]:
        return _v("refused", "MERGED_OR_IN_FLIGHT", ["a profile is merged, deleted or in an in-flight merge"])
    person = fold(f.get("person_name"))
    held_ids = {str(x).lower() for x in f["source_raw_ids"]}
    ties, other_ids, label_hit = set(), set(), False
    for r in f["readings"]:
        if not (r.get("captured") and r.get("same_run")):
            continue
        for name, credit, raw, holder in r.get("credited") or []:
            # gate 10 first, independent of the displayed name (QA #1556): ANY label/publisher credit under an id the
            # source holds blocks, whatever name the DSP shows for it
            if raw and str(raw).lower() in held_ids and LABEL_ROLES.search(str(credit or "")):
                label_hit = True
                continue
            if fold(name) != person or not raw or LABEL_ROLES.search(str(credit or "")):
                continue
            if str(raw).lower() in held_ids:
                ties.add(str(r.get("track")))
            else:
                other_ids.add(str(raw).lower())
    common, why = is_common_name(f.get("person_name"), f.get("name_collisions"))
    extra = {"ties": sorted(ties), "n_ties": len(ties), "common_name": common, "common_why": why,
             "other_ids_same_name": sorted(other_ids)}
    if len(ties) < MIN_TIES:
        return _v("needs_evidence", "SAME_PERSON", [f"{len(ties)} same-run DSP ties (< {MIN_TIES})"], **extra)
    if common and other_ids:
        return _v("needs_evidence", "COMMON_NAME", [f"common name ({why}) and the name is also credited under "
                                                   f"{len(other_ids)} other contributor id(s)"], **extra)
    if label_hit:
        return _v("refused", "LABEL_PUBLISHER", ["the source's id is credited in a label/publisher role"], **extra)
    return _v("eligible", None, [f"{len(ties)} same-run DSP ties" + (f"; common name passes ({why})" if common else "")],
              into=sv, source=so, **extra)
