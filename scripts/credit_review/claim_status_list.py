"""claim-status-daily list builder (claim-lane-resume-c2, firstmate 040/042, captain 2026-10-27 20:1xZ:
"make this a durable process ... do this all on OVH").

Builds, on node-8 and from live reads only, the list `claim_proof_ask.run_status` sends the approved
claim-status note to (Fable claims-documentation-readiness-1023 ruling 3, wording D: "it is with our team
for review. Nothing else is needed from you right now"). WS2 lead (firstmate 042): the note goes ONLY to
claimants for whom that sentence is true:

  - holds:          the claim-review score's hard HOLD rules (core src/services/claiming/claimReviewScore.js):
                      H3  another user has a claim (pending/processed/reverted), an open credit request, or a
                          roster seat on the profile; or another workspace already holds it processed; or a
                          competing claimant's workspace is paying;
                      H9  velocity: > VELOCITY_MAX_CLAIMS_7D other claims by the user in the last 7 days, or
                          > VELOCITY_MAX_UNRELATED_7D distinct other artist/professional profiles in them;
  - organizations:  the claim's profile type, or the catalog profile's subType, is "organization";

and, for both, only when the claimant HAS a bindable page: at least one surface the catalog attributes to
the profile (core claimProofChallenge.surfacesFor, bound=true: the website link's host, the Instagram /
YouTube links, a 22-char Spotify artist raw profile, a YouTube Music raw profile; NOT X / TikTok, which core
#10762 drops because a post can only be read through a claimant-submitted URL). A claimant with
no bindable page needs a step from them ("link an account first"), so the note's sentence would be false.

EXCLUDED (counted, never sent): band B/C persons (they get the proof ask when it opens), every claimant with
no bindable page, A-48h claims and score-only band-D / judge holds (the full score is core's; not derivable
here, so never guessed), deleted / merged profiles, and any claim whose profile could not be read (UNKNOWN
never sends). Paid = the claim's workspace has an active/trial/past_due subscription (the core export's
paid_now). Everything here is a read; the gate decides each send (one note per claim ever, one message per
user per day, the 7-day core-marker deferral, support@ hold, replica re-check)."""
from __future__ import annotations

import json
import re
import subprocess
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Callable

from claim_verify.bound_pages import (  # noqa: F401 - re-exported: callers and tests use csl.<name>
    SPOTIFY_ID, _host_path, _on, bound_surfaces, instagram_handle, registrable_host, tiktok_handle, x_handle,
    youtube_channel_id,
)

from .uvn_status import Query, trino

VELOCITY_MAX_CLAIMS_7D = 3          # core claimReviewScore VELOCITY_MAX_CLAIMS_7D
VELOCITY_MAX_UNRELATED_7D = 1       # core claimReviewScore VELOCITY_MAX_UNRELATED_ARTISTS_7D
PAID_STATUSES = ("active", "trial", "past_due")
COMPETING_PAID_STATUSES = ("active", "trial")
CHUNK = 400
PROFILE_URL = "https://credits.muso.ai/profile/{}"
UUIDISH = re.compile(r"^[A-Za-z0-9-]{1,64}$")
# r3 (hydra #1406 @656d44d5): a catalog outage reads every pending profile as unreadable, build() emitted an
# EMPTY list and the wave exited 0 having told nobody - the durable process silently stopped being durable
# exactly when it mattered. A single unreadable profile stays a per-claim UNKNOWN (never sends); when the
# unreadable share of the pending claims is systemic (all of them, or at least half) the run must FAIL.
UNREADABLE_SYSTEMIC_RATIO = 0.5
# QA on #1406 @4493585c: the guard ran only AFTER the whole loop, so a catalog that stalls (45 s per read) over the
# measured ~1,473 pending profiles would keep the daily job "running" for ~18 h before it could say CATALOG_UNREADABLE.
# Twice per loop this build (a) fails the moment the systemic share is already met - the verdict cannot change any
# more, it can only be delayed - and (b) gives up on a build that has spent CLAIM_BUILD_BUDGET_S. Both are a failed
# run (nothing sent, message printed), never a quiet empty list.
CLAIM_BUILD_BUDGET_S = 1800   # 30 min of 24h; a full healthy build measured ~5 min
CATASTROPHE_CHECK_EVERY = 50

ProfileReader = Callable[[str], "dict[str, Any] | None"]


class CatalogUnreadable(RuntimeError):
    """The pending profiles could not be read at a systemic rate: a catalog outage, not a list."""

    def __init__(self, counts: "dict[str, int]"):
        self.counts = dict(counts)
        super().__init__("CATALOG_UNREADABLE: {} of {} pending claims have an unreadable profile "
                         "(limit: fewer than {}%); the run is failed instead of sending nothing quietly".format(
                             self.counts.get("profile_unreadable", 0), self.counts.get("pending", 0),
                             int(UNREADABLE_SYSTEMIC_RATIO * 100)))


def muso_profile(profile_id: str) -> dict[str, Any] | None:
    """The catalog profile as core's admin API serves it (`muso api GET /admin/profile/:id`, the read
    merge-landing-watchdog uses). None = unreadable (never "no page")."""
    if not UUIDISH.match(profile_id or ""):
        return None
    try:
        out = subprocess.run(["muso", "--env", "prod", "--json", "api", "GET", f"/admin/profile/{profile_id}"],
                             capture_output=True, text=True, timeout=45, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    try:
        doc = json.loads(out.stdout)
    except json.JSONDecodeError:
        return None
    doc = doc.get("data", doc) if isinstance(doc, dict) else None
    return doc if isinstance(doc, dict) and doc.get("id") else None


# -- bound-page detection lives in claim_verify.bound_pages (the one Python statement; imported above) ---


# -- live reads (Trino, read-only) ---------------------------------------------------------------------

def _chunks(xs: list[Any], n: int = CHUNK):
    for i in range(0, len(xs), n):
        yield xs[i:i + n]


def _q(vals: list[str]) -> str:
    return ",".join("'" + str(v).replace("'", "''") + "'" for v in vals)


@dataclass
class Facts:
    claims: list[dict[str, Any]] = field(default_factory=list)          # the pending claims
    holds: dict[int, list[str]] = field(default_factory=dict)            # claim id -> hold rules hit
    paid_teams: set[str] = field(default_factory=set)
    at_risk_teams: set[str] = field(default_factory=set)                 # paying, with a live churn signal


def read_facts(query: Query = trino, now: datetime | None = None) -> Facts:
    now = now or datetime.now(timezone.utc)
    since = (now - timedelta(days=7)).strftime("%Y-%m-%d %H:%M:%S")
    f = Facts()
    for cid, uid, tid, pid, ptype, created in query(
            "SELECT CAST(id AS varchar), CAST(userid AS varchar), CAST(teamid AS varchar), profileid, "
            "coalesce(profiletype, ''), CAST(createdat AS varchar) FROM postgresql_core.public.claiming "
            "WHERE deletedat IS NULL AND status = 'pending'"):
        if str(cid).isdigit() and str(uid).isdigit():
            f.claims.append({"id": int(cid), "user_id": int(uid), "team_id": str(tid or ""), "profile_id": str(pid or ""),
                             "profile_type": str(ptype or ""), "created_at": str(created or "")})
    for t, s, auto in query(
            "SELECT DISTINCT CAST(teamid AS varchar), status, coalesce(json_extract_scalar(details, '$.autoRenew'), '') "
            f"FROM postgresql_core.public.subscriptions WHERE status IN ({_q(list(PAID_STATUSES))})"):
        f.paid_teams.add(str(t))
        # Fable [key=pro-at-risk] (pro-at-risk-1028): a live churn signal = Stripe past_due, or a cancel
        # scheduled (autoRenew false), read from core's mirror of Stripe. Only the ORDER changes.
        if str(s) == "past_due" or str(auto).lower() == "false":
            f.at_risk_teams.add(str(t))
    paying_competitors = {str(t) for (t, s) in query(
        "SELECT DISTINCT CAST(teamid AS varchar), status FROM postgresql_core.public.subscriptions "
        f"WHERE status IN ({_q(list(COMPETING_PAID_STATUSES))})")}
    by_profile: dict[str, list[dict[str, Any]]] = {}
    for c in f.claims:
        by_profile.setdefault(c["profile_id"], []).append(c)
    profiles = sorted(p for p in by_profile if UUIDISH.match(p))
    others: dict[str, list[tuple[int, int, str, str]]] = {}
    credit_users: dict[str, set[int]] = {}
    seat_users: dict[str, list[tuple[str, int]]] = {}
    for chunk in _chunks(profiles):
        for oid, ouid, otid, opid, ost in query(
                "SELECT CAST(id AS varchar), CAST(userid AS varchar), CAST(teamid AS varchar), profileid, status "
                "FROM postgresql_core.public.claiming WHERE deletedat IS NULL "
                f"AND status IN ('pending','processed','reverted') AND profileid IN ({_q(chunk)})"):
            if str(oid).isdigit():
                others.setdefault(str(opid), []).append((int(oid), int(ouid) if str(ouid).isdigit() else -1, str(otid or ""), str(ost)))
        for opid, ouid in query(
                "SELECT CAST(profileid AS varchar), CAST(userid AS varchar) FROM postgresql_core.public.credit_requests "
                f"WHERE status <> 'rejected' AND CAST(profileid AS varchar) IN ({_q(chunk)})"):
            if str(ouid).isdigit():
                credit_users.setdefault(str(opid), set()).add(int(ouid))
        for seat, stid, suid in query(
                "SELECT rs.seatid, CAST(rs.teamid AS varchar), CAST(tu.userid AS varchar) "
                "FROM postgresql_core.public.roster_seats rs JOIN postgresql_core.public.team_users tu ON tu.teamid = rs.teamid "
                f"WHERE rs.seatid IN ({_q(chunk)})"):
            if str(suid).isdigit():
                seat_users.setdefault(str(seat), []).append((str(stid), int(suid)))
    users = sorted({c["user_id"] for c in f.claims})
    recent: dict[int, list[tuple[int, str, str]]] = {}
    for chunk in _chunks([str(u) for u in users]):
        for oid, ouid, opid, optype in query(
                "SELECT CAST(id AS varchar), CAST(userid AS varchar), profileid, coalesce(profiletype, '') "
                "FROM postgresql_core.public.claiming WHERE deletedat IS NULL "
                f"AND createdat >= TIMESTAMP '{since} UTC' AND userid IN ({','.join(chunk)})"):
            if str(oid).isdigit() and str(ouid).isdigit():
                recent.setdefault(int(ouid), []).append((int(oid), str(opid), str(optype)))
    for c in f.claims:
        rules: list[str] = []
        mine = [o for o in others.get(c["profile_id"], []) if o[0] != c["id"]]
        foreign_processed = any(o[3] == "processed" and o[2] != c["team_id"] for o in mine)
        competing_users = ({o[1] for o in mine if o[1] != c["user_id"] and o[1] > 0}
                           | {u for u in credit_users.get(c["profile_id"], set()) if u != c["user_id"]}
                           | {u for (t, u) in seat_users.get(c["profile_id"], []) if t != c["team_id"] and u != c["user_id"]})
        competing_paid = any(o[1] != c["user_id"] and o[2] in paying_competitors for o in mine)
        if foreign_processed or competing_users or competing_paid:
            rules.append("H3")
        mine7 = [o for o in recent.get(c["user_id"], []) if o[0] != c["id"]]
        unrelated = {o[1] for o in mine7 if o[1] != c["profile_id"] and o[2] in ("artist", "professional")}
        if len(mine7) > VELOCITY_MAX_CLAIMS_7D or len(unrelated) > VELOCITY_MAX_UNRELATED_7D:
            rules.append("H9")
        if rules:
            f.holds[c["id"]] = rules
    return f


def assert_not_systemic_outage(counts: "dict[str, int]") -> None:
    """Raise `CatalogUnreadable` when the unreadable share of the pending claims is systemic.

    A list whose claims are mostly unreadable is not a short list - it is a catalog outage wearing one, and
    sending nothing from it (or, worse, sending to its handful of survivors and reporting success) is the
    silent stop this guard exists for. An EMPTY list from an unreadable catalog and an empty list from an
    empty queue are not the same run, and only the counts can tell them apart."""
    pending = int(counts.get("pending", 0))
    unreadable = int(counts.get("profile_unreadable", 0))
    if pending and unreadable >= pending * UNREADABLE_SYSTEMIC_RATIO:
        raise CatalogUnreadable(counts)


class BuildTooSlow(Exception):
    """The build outspent CLAIM_BUILD_BUDGET_S (a stalled catalog, not a slow queue): a FAILED run with no list."""

    def __init__(self, counts: "dict[str, int]", seconds: int) -> None:
        self.counts, self.seconds = dict(counts), seconds
        super().__init__(f"build outspent {CLAIM_BUILD_BUDGET_S}s ({seconds}s; {counts.get('profile_unreadable', 0)} of "
                         f"{counts.get('pending', 0)} pending unreadable)")


def build(*, query: Query = trino, read_profile: ProfileReader = muso_profile, now: datetime | None = None) -> dict[str, Any]:
    """The list document run_status reads, plus the counts of every excluded group."""
    now = now or datetime.now(timezone.utc)
    facts = read_facts(query, now)
    counts = {k: 0 for k in ("pending", "hold", "organization", "bc_person_excluded", "no_bindable_page",
                             "profile_unreadable", "profile_gone", "listed", "listed_paid", "listed_at_risk")}
    cache: dict[str, dict[str, Any] | None] = {}
    claims: list[dict[str, Any]] = []
    t0 = time.monotonic()
    pending_total = len(facts.claims)          # known before any catalog read, so the ratio is computable as we go
    for n, c in enumerate(sorted(facts.claims, key=lambda x: x["id"])):
        counts["pending"] += 1
        if time.monotonic() - t0 > CLAIM_BUILD_BUDGET_S:
            raise BuildTooSlow(counts, round(time.monotonic() - t0))   # cheap; a 45 s stall trips it inside ~40 reads
        if n % CATASTROPHE_CHECK_EVERY == 0 and pending_total \
                and counts["profile_unreadable"] >= pending_total * UNREADABLE_SYSTEMIC_RATIO:
            assert_not_systemic_outage(counts)                       # raises: the outage is already systemic
        is_hold = c["id"] in facts.holds
        # Every claim's profile is read, holds or not: an organization is known by the claim's type OR the
        # catalog's subType, and only the catalog says the latter (QA on hydra #1406 @68159ae4).
        pid = c["profile_id"]
        if pid not in cache:
            cache[pid] = read_profile(pid)
        prof = cache[pid]
        if prof is None:
            counts["profile_unreadable"] += 1
            continue
        if prof.get("deleted") or prof.get("merged"):
            counts["profile_gone"] += 1
            continue
        org = c["profile_type"] == "organization" or str(prof.get("subType") or "") == "organization"
        if not is_hold and not org:
            counts["bc_person_excluded"] += 1
            continue
        if not bound_surfaces(prof):
            counts["no_bindable_page"] += 1
            continue
        counts["hold" if is_hold else "organization"] += 1
        paid = c["team_id"] in facts.paid_teams
        at_risk = paid and c["team_id"] in facts.at_risk_teams
        claims.append({"claim_id": c["id"], "user_id": c["user_id"], "profile_id": pid, "paid": paid,
                       "at_risk": at_risk, "priority": 0 if at_risk else (1 if paid else 2),
                       "audience": "status", "reason": ("hold:" + "+".join(facts.holds[c["id"]])) if is_hold else "organization",
                       "profile_name": str(prof.get("name") or "").strip(), "profile_url": PROFILE_URL.format(pid)})
        counts["listed"] += 1
        counts["listed_paid"] += int(paid)
        counts["listed_at_risk"] += int(at_risk)
    assert_not_systemic_outage(counts)
    return {"generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "source": "claim_status_list.build (node-8, live reads)",
            "counts": counts, "claims": claims}
