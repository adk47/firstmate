"""Intercom external_id -> Muso account, by the account's PRESENTED identity (r5; Fable ruling
`[key=x2-sample-1027]`, 2026-10-27 23:46Z: "the data is not wrong, the MATCHER is").

Why: core's `/v4/user` publishes the account's presented profile as its `id` (core-backend
src/services/user/getUserProfile.js, B2, 22cf413b23: `presented?.profileId || neptuneProfessionalId`),
and the mobile app logs into Intercom with exactly that id (mobile lib/app.dart setupUserInfo
(userIdentifier: accDetails.id)). The web app boots with users.neptuneProfessionalId. So a claimant on
mobile has an Intercom user whose external_id is a CLAIMED profile id, which every matcher keyed on
neptuneProfessionalId read as "no account". Census (intercom-id-reconcile-x2, 2026-10-27, 143
conversations linked by verified email): 127 carried a profile the same account has a processed claim
on or represents; 110 of the 113 user contacts were mobile-app contacts; 86 of 87 of Ruling A's paid
"A2 orphan" fixes were the account's own presented profile.

The rule, one place, read-only: an external_id resolves to an account when it is, for EXACTLY ONE
account,
  - users.neptuneprofessionalid                                   matched_by = professional_id
  - the account's Auth0 subject (with or without auth0|)          matched_by = auth0_subject
    (the gate has always accepted it; kept so nothing that passes today stops passing)
  - the profile of a PROCESSED, not deleted claim with a user id  matched_by = presented_profile
  - users.representationprofileid                                 matched_by = presented_profile
It does NOT resolve (refused, `account_id` None, `why` says which) when
  - no account owns it (0);
  - two or more accounts own it, by any mix of the sources above (>1);
  - any OTHER account has a reverted claim on that profile: that account's app may have logged in
    with it while it held the claim, so the contact may be theirs (the "refuse reverted claims" rule);
  - it is not id-shaped.
A name is never an input. A pending / rejected / closed claim confers nothing.

Consumers: credit_review.verify_notify (user.presented_ids for Caroline's gate), intercom_reconcile
(an account's own presented profile is never an "orphan"), paid-status/email_route.py (the A3
check), and the proof_intake filer (matched_by = presented_profile).
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Callable, Iterable

Query = Callable[[str], "list[list[str]]"]

EXT_RE = re.compile(r"^[A-Za-z0-9._|-]{1,128}$")
PROFESSIONAL_ID, AUTH0_SUBJECT, PRESENTED_PROFILE = "professional_id", "auth0_subject", "presented_profile"
CHUNK = 150


@dataclass
class Resolution:
    external_id: str
    account_id: int | None = None
    matched_by: str = ""                                    # one of the three, '' when unresolved
    why: str = ""                                           # why it did not resolve ('' when it did)
    owners: dict[int, list[str]] = field(default_factory=dict)   # every account that claims it, and how


def _q(xs: Iterable[str]) -> str:
    return ",".join("'" + x.replace("'", "''") + "'" for x in xs)


def _chunks(xs: list[str], n: int = CHUNK) -> Iterable[list[str]]:
    for i in range(0, len(xs), n):
        yield xs[i:i + n]


def _bare(sub: str) -> str:
    return re.sub(r"^auth0\|", "", str(sub or "").strip())


def facts(exts: Iterable[str], query: Query) -> tuple[dict[str, dict[int, set[str]]], dict[str, set[int]]]:
    """({ext: {account: {how}}}, {ext: accounts with a REVERTED claim on it}) from the core replica."""
    vals = sorted({x.strip() for x in exts if x and EXT_RE.match(x.strip())})
    own: dict[str, dict[int, set[str]]] = {x: {} for x in vals}
    reverted: dict[str, set[int]] = {x: set() for x in vals}

    def add(ext: str, uid: str, how: str) -> None:
        if ext in own and str(uid).isdigit():
            own[ext].setdefault(int(uid), set()).add(how)

    for chunk in _chunks(vals):
        auth = sorted(set(chunk) | {"auth0|" + x for x in chunk if not x.startswith("auth0|")}
                      | {x[6:] for x in chunk if x.startswith("auth0|") and len(x) > 6})
        for uid, pro, sub, rep in query(
                "SELECT CAST(id AS varchar), neptuneprofessionalid, auth0userid, CAST(representationprofileid AS varchar) "
                f"FROM postgresql_core.public.users WHERE neptuneprofessionalid IN ({_q(chunk)}) "
                f"OR auth0userid IN ({_q(auth)}) OR CAST(representationprofileid AS varchar) IN ({_q(chunk)})"):
            sb = _bare(sub)
            for x in chunk:
                if x == str(pro or ""):
                    add(x, uid, PROFESSIONAL_ID)
                if sb and (x == sb or x == "auth0|" + sb or x == str(sub or "")):
                    add(x, uid, AUTH0_SUBJECT)
                if x == str(rep or ""):
                    add(x, uid, PRESENTED_PROFILE)
        for pid, uid, status in query(
                "SELECT CAST(profileid AS varchar), CAST(userid AS varchar), lower(CAST(status AS varchar)) "
                f"FROM postgresql_core.public.claiming WHERE CAST(profileid AS varchar) IN ({_q(chunk)}) "
                "AND userid IS NOT NULL AND deletedat IS NULL"):
            if status == "processed":
                add(str(pid), uid, PRESENTED_PROFILE)
            elif status == "reverted" and str(pid) in reverted and str(uid).isdigit():
                reverted[str(pid)].add(int(uid))
    return own, reverted


def decide(ext: str, owners: dict[int, set[str]], reverted: set[int]) -> Resolution:
    """The rule, pure (unit-tested on the x2 census shape)."""
    r = Resolution(external_id=ext, owners={u: sorted(h) for u, h in sorted(owners.items())})
    if not ext or not EXT_RE.match(ext):
        r.why = "not an id-shaped external_id"
        return r
    if not owners:
        r.why = "no Muso account owns this external_id"
        return r
    if len(owners) > 1:
        r.why = f"{len(owners)} Muso accounts own this external_id (" + ",".join(str(u) for u in sorted(owners)) + ")"
        return r
    uid, how = next(iter(owners.items()))
    other_reverted = sorted(reverted - {uid})
    if other_reverted:
        r.why = ("another account had a claim on this profile that was reverted (" + ",".join(map(str, other_reverted))
                 + "): the contact may be theirs")
        return r
    r.account_id = uid
    r.matched_by = next(m for m in (PROFESSIONAL_ID, AUTH0_SUBJECT, PRESENTED_PROFILE) if m in how)
    return r


def resolve(exts: Iterable[str], query: Query) -> dict[str, Resolution]:
    """{external_id: Resolution} for every external_id given (read-only)."""
    xs = sorted({str(x or "").strip() for x in exts} - {""})
    own, rev = facts(xs, query)
    return {x: decide(x, own.get(x, {}), rev.get(x, set())) for x in xs}


def presented_ids(user_ids: Iterable[int | str], query: Query) -> dict[str, list[str]]:
    """{muso user id: [presented profile ids that resolve to EXACTLY that account]}: its processed claims
    and its representation profile, minus its professional id (already user.professional_id). An id
    another account also owns, or one another account had a reverted claim on, is left out."""
    ids = sorted({int(u) for u in user_ids if str(u).isdigit()})
    cand: dict[int, set[str]] = {u: set() for u in ids}
    pro: dict[int, str] = {}
    for i in range(0, len(ids), 500):
        chunk = ",".join(str(u) for u in ids[i:i + 500])
        for uid, rep, p in query("SELECT CAST(id AS varchar), CAST(representationprofileid AS varchar), neptuneprofessionalid "
                                 f"FROM postgresql_core.public.users WHERE id IN ({chunk})"):
            if str(uid).isdigit():
                pro[int(uid)] = str(p or "")
                if rep and EXT_RE.match(str(rep)):
                    cand[int(uid)].add(str(rep))
        for uid, pid in query("SELECT CAST(userid AS varchar), CAST(profileid AS varchar) FROM postgresql_core.public.claiming "
                              f"WHERE userid IN ({chunk}) AND lower(CAST(status AS varchar)) = 'processed' AND deletedat IS NULL"):
            if str(uid).isdigit() and int(uid) in cand and pid and EXT_RE.match(str(pid)):
                cand[int(uid)].add(str(pid))
    allx = sorted({x for xs in cand.values() for x in xs})
    res = resolve(allx, query) if allx else {}
    return {str(u): sorted(x for x in xs if x != pro.get(u) and res.get(x) and res[x].account_id == u)
            for u, xs in cand.items()}
