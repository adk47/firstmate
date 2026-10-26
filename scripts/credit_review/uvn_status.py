"""UVN status + reminder sends (Fable ops-takeover 2026-10-19 section 2 class 2; firstmate 060).

One message per user, ever, to credit requesters whose requests wait on them
(`user_verification_needed`), through Caroline's gate (`intercom-verify-request.sh
--campaign uvn-status`, fixed copy). The list is credit-trust-llm-t01's
`uvn-reminder-list.json` (user ids, paid flag, skip reason, request ids; no emails). Every
send re-checks, right before it goes:

  - the list itself is fresh (generated_at at most LIST_MAX_AGE_H old: re-run build.py the
    morning of each send day), and only rows with skip == null are offered;
  - proof-on-file (the strict shared rule; UNKNOWN = no send): any entry for the user = skip,
    read when the run starts and again right before each send;
  - the user's requests are STILL user_verification_needed on the core replica (Trino, never
    admin paging); the email, first name, title, artist and role come from there too. For
    uvn-status only, a request already on the profile or on the approval path is left out
    (ask_class; no second ask, firstmate 094 narrowed by 102);
  - the gate then checks Intercom (documents attached or tagged = skip; any message from us
    in 7 days = defer), the ledger (one per user ever, 7 days, one message per user per day,
    and the shared one-ask-per-user-per-90-days lock across the ask campaigns: a deferral,
    nothing closed) and posts: in the user's most recently updated open conversation of the last 14 days
    when there is one, otherwise by email.

Pace: paid first, file order; at most `max_users` per run and `DAILY_MAX` per UTC day for
this campaign (the ask cap). Canary = a run with --max-users 3. Users the ledger already
answers for (their listed requests noted or closed, already sent, proof received, messaged
in 7 days, asked by any ask campaign in 90 days) are dropped BEFORE the budget is spent, so repeated runs keep reaching new users;
on a real run the ones that are done for good (and the ones no longer waiting or without an
account email) are closed in the ledger so later runs drop them without a lookup.
Users the gate defers for a recent Intercom message do not use the budget either: the run
keeps going past them, at most MAX_CALLS_PER_USER gate calls per budgeted user.

The no-ask status notes (status-doc-received, status-team-review) treat a gate refusal the
same way: it does not use the budget and counts toward the MAX_CALLS_PER_USER cap. A refusal
holds the USER (whatever requests are listed or still pending) for 7 days: the run skips them
until then and reports "refused, re-check after <date>"; a later send clears it; the third
refusal (21 days) is posted once to #cs_priority for a human (Muso user id, campaign, reason;
no email) and the user is not picked again; a failed post leaves it un-flagged and fails the
run (firstmate 082, 083). The hold follows the Muso user id across an email change.

A pending request with a blank title, artist or role, or a field the gate would refuse (role over
120 characters, title or artist over 200, a malformed profile or track id), is never shown: it is
left out of the note and the rest of the user's note is sent (firstmate 166, 2026-10-23: "hold the bad
row, send the rest"; one bad row used to refuse the whole note). The left-out request stays pending
in core and is reviewed like any other; it is counted in `rows_held` once the note is sent (or, on
a dry run, validated). The note is one per user, ever, so this campaign does not ask about it again:
a later run that still lists the user records it as skipped in the ledger (firstmate 169). A user
whose every request is such a row is held, reported `incomplete`, not closed, and re-checked next
run. Likewise for uvn-status, a user with a request still waiting on them that the list does
not carry (opened after the list was built) is held, reported `unlisted` and not closed, until a
rebuilt list names it. Both holds are applied when the batch is built and again on the fresh
replica read right before each send (`plan`).

Every payload carries user.professional_id, the account's users.neptuneprofessionalid: the id the
web app boots Intercom with, so Intercom's external_id (firstmate 090), plus user.auth_id, the
Auth0 subject, when there is one. A user without a professional id (which should not happen) is
held (reported no_professional_id), never handed to the gate.

uvn-status never asks about a request the approval path can actually admit or that is already on
the profile (verificationData.duplicate_of): the replica re-check leaves them out and reports
approval_path / already_on_profile (Fable via firstmate 094, narrowed by firstmate 102 to Fable's
phase-1 conditions: see approval_path_admits). A low-risk validator-approved request the server
still needs proof for keeps its ask (reported low_risk_asked).

Stage-2 release (Fable 2026-10-26 13:23Z, GO 2; credit_review/stage2_verdicts.py): a user with a
document on file is no longer skipped for the mere existence of that entry when stage 2 has
judged every credit the note would ask about: `no_document` releases it to uvn-status (also a
request still `unverified`, i.e. held with us, which stage 2 found nothing readable for), and
`need_more` releases it to gap-ask (Fable's gap paragraph; the gate reads the verdict itself and
fills <doc summary> from it). An approved proof that names the credit still excludes it, and a
credit stage 2 has not judged (or judged anything else) still excludes the user: when in doubt,
no ask. --from-stage2 builds the population live from the proof store instead of t01's list
(gap-ask always does).

Fraud lens (captain 2026-10-26 ~00:40Z; Fable ruling-intercom-external-id-1026 Ruling B; fraud_lens.py):
the run loads the fraud watchlist (credit_review/watchlist.py, policies/fraud-watchlist.json) and the
messaging holds (policies/fraud-lens-holds.json) when it starts; either missing or malformed = nothing
sent (halted). Every listed user then goes through the lens before anything can close or message them,
in every campaign: a held user (messaging hold, velocity above the band, or >= 10 open big-track
single-signal rows) is reported fraud_held and never messaged or closed; a watchlisted user is messaged
normally (the watchlist holds approvals, never communication: Fable ruling-watchlist-consistency-1026)
and counted as watchlisted; a user with 1-9 such rows is
released ONLY to the uvn-status document ask, never a status note (Copy A / B0, the count-only
note) nor the gap ask, reported ask_only.

Each status note has one approved alternative wording: status-doc-received wording="queued"
(firstmate 092) passes --copy queued, status-team-review wording="no-ask" (Copy B0 without the
proof sentence; firstmate 106, pending-status-1021) passes --copy no-ask to the gate.
"""

from __future__ import annotations

import fcntl
import json
import re
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any

from . import fraud_lens, policy, stage2_verdicts, verify_ledger, verify_notify
from .roles import ONE_PERSON_FAMILIES, family_of

# The proof-on-file kinds that mean "we approved a document" (decide.APPROVED_PROOF_KINDS).
APPROVED_PROOF_KINDS = frozenset({"approved_doc", "human_approved_after_doc"})

CAMPAIGN = "uvn-status"
GAP_ASK = verify_ledger.GAP_ASK
# The no-ask status notes (firstmate 070/071) run through this same driver with the
# credit-trust-llm-t01 lists status-A-doc-under-review (status-doc-received) and
# status-B-with-our-team (status-team-review). They are NOT asks: no proof-on-file exclusion
# (these users are the ones with documents or requests with us), no ask cap, never close an ask.
CAMPAIGNS = ("uvn-status", "status-doc-received", "status-team-review", GAP_ASK)
# The campaigns that ASK (documents-on-file exclusion, the ask cap, closing asks).
ASKS = ("uvn-status", GAP_ASK)
# The replica re-check per campaign (firstmate 076): uvn-status needs requests still waiting on
# the user; the status notes need requests still pending with us. A status-note user with none
# left is `not_pending`: counted, never closed in the ledger.
PENDING_STATUSES = {
    "uvn-status": ("user_verification_needed",),
    "status-doc-received": ("user_verification_needed", "unverified", "processing"),
    "status-team-review": ("user_verification_needed", "unverified", "processing"),
    # gap-ask: the decider's held rows; only stage-2 need_more ones are ever kept (run()).
    GAP_ASK: ("unverified", "user_verification_needed"),
}
# Rows in these statuses join a campaign only when stage 2 released them to it: uvn-status's
# no_document users whose requests are still `unverified` (held with us; firstmate spec item 2).
RELEASED_EXTRA_STATUSES = {"uvn-status": ("unverified",)}
STATUS_DAILY_MAX = 1000  # sanity bound for the no-ask status notes
LIST_MAX_AGE_H = 30
DAILY_MAX = 400
MAX_CALLS_PER_USER = 5
Query = verify_notify.Query
trino = verify_notify.trino
# The deployed lens factory (fraud_lens.default_lens: watchlist + messaging holds, both required).
# A run without an explicit `lens` builds it; a missing or malformed file halts the run.
DEFAULT_LENS = fraud_lens.default_lens


@dataclass
class UvnReport(verify_notify.Report):
    listed: int = 0
    stale_list: str = ""
    no_longer_uvn: int = 0
    not_pending: int = 0
    no_email: int = 0
    over_daily_max: int = 0
    already_handled: int = 0
    refused_recheck: int = 0
    recheck_after: str = ""
    approval_path: int = 0
    already_on_profile: int = 0
    low_risk_asked: int = 0
    outcome_unknown: int = 0
    incomplete: int = 0
    rows_held: int = 0                 # requests left out of a note sent or validated (blank or gate-refused field)
    unlisted: int = 0
    recently_asked: int = 0
    excluded: int = 0                  # --exclude-users (another lane messages them today)
    count_copy: int = 0                # status-team-review users sent the count-only note (not held)
    stage2_released: int = 0           # documented users let through by a stage-2 verdict
    campaign: str = ""
    fraud_held: int = 0
    ask_only: int = 0
    watchlisted: int = 0               # on the approval watchlist; messaged normally (reported, never a hold)
    by_reason: dict[str, int] = field(default_factory=dict)

    def note(self, why: str) -> None:
        self.by_reason[why] = self.by_reason.get(why, 0) + 1


def load_list(path: str, *, now: datetime | None = None) -> tuple[list[dict[str, Any]], str]:
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    from .evidence import parse_ts
    gen = parse_ts(doc.get("generated_at")) if isinstance(doc, dict) else None
    users = doc.get("users") if isinstance(doc, dict) else None
    if gen is None or not isinstance(users, list):
        return [], "the list has no generated_at or users[]"
    age_h = ((now or datetime.now(timezone.utc)) - gen).total_seconds() / 3600
    if age_h > LIST_MAX_AGE_H or age_h < -0.1:
        return [], f"the list is {age_h:.1f}h old (limit {LIST_MAX_AGE_H}h): re-run build.py first"
    return users, ""


def _ids(xs: list[Any]) -> str:
    return ",".join(str(int(x)) for x in xs)


def accounts_of(user_ids: list[int], query: Query = trino) -> dict[int, dict[str, str]]:
    """Account email, first name, professional id (users.neptuneprofessionalid: Intercom's
    external_id, firstmate 090; '' when missing) and Auth0 subject ('' when none) by user id,
    from the core replica."""
    accounts: dict[int, dict[str, str]] = {}
    for i in range(0, len(user_ids), 500):
        chunk = user_ids[i:i + 500]
        for uid, email, first, pro, auth in query(
                f"SELECT id, lower(email), firstname, neptuneprofessionalid, auth0userid "
                f"FROM postgresql_core.public.users WHERE id IN ({_ids(chunk)})"):
            accounts[int(uid)] = {"email": (email or "").strip(), "first_name": (first or "").strip(),
                                  "professional_id": verify_notify.professional_id(pro),
                                  "auth_id": verify_notify.auth_subject(auth)}
    return accounts


APPROVAL_PATH_MAX_RISK = 30
NO_ASK = ("already_on_profile", "approval_path")
BAND_HINT_ONLY = ["validator_band_hint"]
POPULARITY_REASONS = ("popularity_unknown", "big_track", "popularity_unattributable")


def _json(raw: Any) -> Any:
    """A replica JSON column (possibly encoded twice): the value, None when null, or ValueError."""
    v: Any = raw
    for _ in range(2):
        if not isinstance(v, str):
            break
        v = json.loads(v)
    return v


def approval_path_admits(row: dict[str, Any]) -> bool:
    """Fable's phase-1 conditions (firstmate 102): the approval path can actually admit this
    request. All must hold: validator-approved; total_risk_percent < 30; popularity 1..59; for a
    one-person role, no trusted source credits it to someone else; and the core agent-approval
    guard (policy.server_proof_reasons) needs no proof beyond a band-hint-only stamp."""
    vd = row.get("verificationData")
    if not isinstance(vd, dict) or vd.get("is_approved") is not True:
        return False
    risk = policy._num(vd.get("total_risk_percent"))
    if risk is None or risk >= APPROVAL_PATH_MAX_RISK:
        return False
    if set(policy.server_big_track_reasons(row)) & set(POPULARITY_REASONS):
        return False
    if any(family_of(r) in ONE_PERSON_FAMILIES for r in row.get("roles") or []):
        rules = vd.get("rule_risk_percent")
        if not isinstance(rules, dict):
            return False
        flag = rules.get("review_role_credited_to_other_at_trusted_source")
        if flag not in (None, 0, False) and not (policy._num(flag) == 0):
            return False
    return policy.server_proof_reasons(row) in ([], BAND_HINT_ONLY)


def ask_class(row: dict[str, Any]) -> str:
    """How uvn-status treats a request (Fable via firstmate 094, 102): already_on_profile
    (verificationData.duplicate_of: firstmate 086) and approval_path (approval_path_admits) are
    never asked about; low_risk_asked (validator-approved, risk < 30, but the approval path cannot
    admit it) and '' keep the normal ask."""
    vd = row.get("verificationData")
    if not isinstance(vd, dict):
        return ""
    if vd.get("duplicate_of"):
        return "already_on_profile"
    if approval_path_admits(row):
        return "approval_path"
    risk = policy._num(vd.get("total_risk_percent"))
    if vd.get("is_approved") is True and risk is not None and risk < APPROVAL_PATH_MAX_RISK:
        return "low_risk_asked"
    return ""


def _row_class(roles: str, pop: Any, vd_raw: Any, meta_raw: Any) -> str:
    try:
        vd, meta = _json(vd_raw), _json(meta_raw)
    except ValueError:
        return ""
    if meta is not None and not isinstance(meta, dict):
        return ""
    p = str(pop or "").strip()
    return ask_class({"verificationData": vd, "metadata": meta or {},
                      "spotifyPopularity": int(p) if p.isdigit() else None,
                      "roles": [r.strip() for r in (roles or "").split(",") if r.strip()]})


ID_RE = re.compile(r"^[A-Za-z0-9-]{1,64}$")


CNTRL_RE = re.compile(r"[\x00-\x1f\x7f-\x9f]")


def _gate_clean(s: str) -> str:
    """The gate's `clean`: control characters become spaces, whitespace runs collapse, ends trimmed."""
    return re.sub(r"\s+", " ", CNTRL_RE.sub(" ", s)).strip(" ")


def _row_incomplete(title: str, artist: str, role: str, pid: str, tid: str) -> bool:
    """True when the gate would refuse this credit (intercom-verify-request.sh shape checks, on the
    values after its `clean`): a blank title, artist or role, role > 120, title or artist > 200
    characters, or a non-empty profile / track id that is not letters, digits and dashes."""
    title, artist, role, pid, tid = (_gate_clean(x) for x in (title, artist, role, pid, tid))
    if not (title and artist and role):
        return True
    if len(role) > 120 or len(title) > 200 or len(artist) > 200:
        return True
    return any(x and not ID_RE.match(x) for x in (pid, tid))


def uvn_requests(user_ids: list[int], query: Query = trino,
                 statuses: tuple[str, ...] = PENDING_STATUSES[CAMPAIGN]) -> dict[int, list[dict[str, Any]]]:
    """Requests in `statuses` (default: still UVN) by user id, most popular first, from the core replica.
    Each carries `_no_ask` (its ask_class) and `_incomplete` (_row_incomplete): True when the gate would
    refuse the row (a blank title, artist or role, a field over the gate's length caps, or a malformed
    profile or track id). Such a row is left out of the note, never shown; a user with nothing else
    to show is held and re-checked next run."""
    in_statuses = ", ".join(f"'{s}'" for s in statuses)
    reqs: dict[int, list[dict[str, Any]]] = {}
    for i in range(0, len(user_ids), 500):
        chunk = user_ids[i:i + 500]
        for rid, uid, pid, tid, title, artists, raw_credits, pop, *extra in query(
                "SELECT CAST(id AS varchar), userid, CAST(profileid AS varchar), CAST(trackid AS varchar), "
                "spotifytracktitle, json_format(CAST(spotifytrackartists AS json)), "
                "credits, spotifypopularity, "
                "json_format(CAST(verificationdata AS json)), json_format(CAST(metadata AS json)) "
                "FROM postgresql_core.public.credit_requests "
                f"WHERE status IN ({in_statuses}) AND deletedat IS NULL AND userid IN ({_ids(chunk)})"):
            # credits is a Postgres text[] literal in a varchar on the replica (2026-10-22: the
            # former CAST(credits AS array(varchar)) fails on Trino, so every live query broke).
            credits = verify_notify.pg_text_array(raw_credits)
            try:
                artist = next((a.get("name") for a in json.loads(artists or "[]") if isinstance(a, dict) and a.get("name")), "")
            except ValueError:
                artist = ""
            reqs.setdefault(int(uid), []).append({
                "request_id": rid, "profile_id": pid or "", "track_id": tid or "",
                "track_title": (title or "").strip(), "artist_name": (artist or "").strip(),
                "role": (credits or "").strip(),
                "_incomplete": _row_incomplete((title or "").strip(), (artist or "").strip(), (credits or "").strip(),
                                               pid or "", tid or ""),
                "_pop": int(pop) if str(pop).isdigit() else -1,
                "_no_ask": _row_class(credits, pop, *(list(extra) + [None, None])[:2])})
    for rows in reqs.values():
        rows.sort(key=lambda r: (-r["_pop"], r["track_title"].casefold()))  # most popular first
        for r in rows:
            r.pop("_pop", None)
    return reqs


def documents_block(documented: dict[str, Any], uid: str, ask_ids: list[str] | set[str], released: set[str]) -> bool:
    """True when the proof-on-file export keeps this user from an ask about `ask_ids`. A user with
    no entry is free. A user with entries is let through only when stage 2 released EVERY credit
    asked about (`released`) and no APPROVED proof names one of them; an entry for a credit stage
    2 did not release (or no credit at all) still excludes the user."""
    entries = documented.get(str(uid)) or []
    if not entries:
        return False
    ids = {str(r).strip().lower() for r in ask_ids if str(r).strip()}
    if not ids or not ids <= released:
        return True
    return any(rid and rid.lower() in ids and kind in APPROVED_PROOF_KINDS for rid, kind in entries)


def stage2_released(campaign: str, path: str | None = None, *, user_ids: list[int] | None = None) -> set[str]:
    """Request ids stage 2 released to this campaign (empty for one it does not feed).
    Stage2Error propagates: the caller decides whether that halts the run."""
    outcome = stage2_verdicts.RELEASES.get(campaign)
    if not outcome:
        return set()
    return stage2_verdicts.released(stage2_verdicts.load(path, user_ids=user_ids), outcome)


def pending_rows(user_ids: list[int], campaign: str, released: set[str],
                 query: Query = trino, *, with_released: bool = False) -> dict[int, list[dict[str, Any]]]:
    """uvn_requests for the campaign, with the stage-2 release applied: gap-ask, and any run whose
    population is stage 2's (`with_released`), keeps ONLY the released requests (an unjudged
    request of the same user is never named: QA on #1364); with `with_released` uvn-status also
    adds the released requests still `unverified`. A list-driven uvn-status run is bounded by
    t01's list instead and never adds them (they would hold the user as unlisted)."""
    reqs = uvn_requests(user_ids, query, PENDING_STATUSES[campaign])
    if campaign == GAP_ASK or with_released:
        reqs = {u: kept for u, rows in reqs.items()
                if (kept := [r for r in rows if r["request_id"].lower() in released])}
    extra = RELEASED_EXTRA_STATUSES.get(campaign)
    if extra and released and with_released:
        for u, rows in uvn_requests(user_ids, query, extra).items():
            add = [r for r in rows if r["request_id"].lower() in released]
            if add:
                reqs.setdefault(u, []).extend(add)
    return reqs


HOLDS = {"unlisted_request": "unlisted", "incomplete_fields": "incomplete"}

# Count-only status note (firstmate 2026-10-26 16:58Z, verify-ask-wiring-h2 inbox 005; captain
# 16:05Z: "everyone should be communicated"): a status-team-review user whose requests cannot be
# listed (every one blank or unshowable) or are more than the gate takes in one listed note gets
# the count-only wording (gate --copy count) instead of a hold. It names no title, so nothing
# unshowable is shown; N counts every request pending on the replica at send time; the ledger
# records at most COUNT_MAX_IDS of their request ids.
COUNT_COPY_CAMPAIGNS = ("status-team-review",)
GATE_MAX_CREDITS = 1000
COUNT_MAX_IDS = 1000


def count_copy_of(campaign: str, listed: set[str], pending: list[dict[str, Any]], why: str,
                  live: list[dict[str, Any]]) -> tuple[str, list[dict[str, Any]], bool, int]:
    """(why, credits, count copy?, total pending) after plan(): the count-only note replaces the
    `incomplete` hold and the over-cap refusal of a status-team-review note. Its N is EVERY
    request the replica has pending for the user right now (`pending`, re-read before the send),
    not only the ones the (up to 30 h old) list names: the note is one per user, ever, so it must
    not understate (QA + Fable on b2afc8be). The listed requests come first in the ids recorded."""
    if campaign in COUNT_COPY_CAMPAIGNS and (why == "incomplete_fields" or (not why and len(live) > GATE_MAX_CREDITS)):
        ordered = sorted(pending, key=lambda r: bool(listed) and r["request_id"] not in listed)
        rows = [{k: v for k, v in r.items() if not k.startswith("_")} for r in ordered]
        return "", rows[:COUNT_MAX_IDS], True, len(rows)
    return why, live, False, len(live)


def note_payload(acct: dict[str, str], uid: int, credits: list[dict[str, Any]], as_count: bool,
                 total: int) -> dict[str, Any]:
    user = {"email": acct["email"], "id": str(uid), "professional_id": acct["professional_id"],
            "auth_id": acct["auth_id"], "first_name": acct.get("first_name", "")}
    if as_count:
        return {"user": {**user, "pending_count": total}, "credits": credits, "extra": ["--copy", "count"]}
    return {"user": user, "credits": credits}


def plan(listed: set[str], pending: list[dict[str, Any]], is_ask: bool) -> tuple[str, list[dict[str, Any]]]:
    """What one user's note may say, from their `listed` request ids and their `pending` replica
    rows: ("", the credits to show) or (a hold reason in HOLDS / "nothing_to_ask", []). Applied when
    the batch is built AND again on a fresh replica read right before the send, so a request opened
    in between holds the user instead of being left out of their one-ever note, and a request blanked
    in between is left out of it."""
    rows = [r for r in pending if not listed or r["request_id"] in listed]
    # A request waiting on them that the list does not carry yet (opened after the list was
    # built) holds the user: their one-ever note must not leave it out.
    if is_ask and listed and any(r["request_id"] not in listed and r["_no_ask"] not in NO_ASK for r in pending):
        return "unlisted_request", []
    if is_ask:
        asked = [r for r in rows if r["_no_ask"] not in NO_ASK]
        if rows and not asked:
            return "nothing_to_ask", []
        rows = asked
    # A blank or gate-refused request is left out (never shown; it stays pending in core and is
    # reviewed like any other); the rest of the note goes (firstmate 166). Only a user with
    # nothing showable is held.
    if rows and all(r["_incomplete"] for r in rows):
        return "incomplete_fields", []
    rows = [r for r in rows if not r["_incomplete"]]
    return "", [{k: v for k, v in r.items() if not k.startswith("_")} for r in rows]


def left_out(listed: set[str], pending: list[dict[str, Any]], is_ask: bool) -> int:
    """How many of the user's listed `pending` rows plan() leaves out as unshowable (for an ask,
    only the rows it would otherwise ask about)."""
    return sum(1 for r in pending if r["_incomplete"] and (not listed or r["request_id"] in listed)
               and not (is_ask and r["_no_ask"] in NO_ASK))


def run(*, list_path: str | None = None, segment: str, mode: str = "dry-run", max_users: int = 50,
        ledger_path: str | None = None, proof_path: str | None = None, query: Query = trino,
        wrapper: str = verify_notify.WRAPPER, runner: verify_notify.Runner = verify_notify._run,
        now: datetime | None = None, preview_dir: str | None = None, pace_seconds: float = 1.0,
        campaign: str = CAMPAIGN, post: verify_notify.Poster = verify_notify.post_cs_priority,
        wording: str = "", from_stage2: bool = False, stage2_path: str | None = None,
        exclude_users: set[str] | frozenset[str] = frozenset(), lens: fraud_lens.LensFn | None = None,
        watchlist_path: str | None = None, holds_path: str | None = None) -> UvnReport:
    if campaign not in CAMPAIGNS:
        raise ValueError(f"unknown campaign {campaign!r}")
    if wording and (campaign, wording) not in (("status-doc-received", "queued"), ("status-team-review", "no-ask")):
        raise ValueError(f"wording {wording!r}: queued applies to status-doc-received, no-ask to status-team-review")
    if from_stage2 and campaign not in stage2_verdicts.RELEASES:
        raise ValueError(f"--from-stage2 feeds {', '.join(stage2_verdicts.RELEASES)} only")
    if campaign == GAP_ASK and not from_stage2:
        raise ValueError("gap-ask reaches only users stage 2 judged: run it with from_stage2")
    if not from_stage2 and not list_path:
        raise ValueError("a list is required unless the population comes from stage 2")
    is_ask = campaign in ASKS
    report = UvnReport(campaign=campaign)
    # Stage 2's release from the proof-on-file hold. From the list, an unreadable store releases
    # nothing (the old rule stands); a stage-2 population cannot be built without it.
    released: set[str] = set()
    if campaign in stage2_verdicts.RELEASES:
        try:
            released = stage2_released(campaign, stage2_path)
        except stage2_verdicts.Stage2Error as exc:
            if from_stage2:
                report.halted = str(exc)
                return report
            report.note("stage2_unreadable")
    if from_stage2:
        try:
            users = stage2_verdicts.population(stage2_verdicts.RELEASES[campaign], path=stage2_path)
        except stage2_verdicts.Stage2Error as exc:
            report.halted = str(exc)
            return report
        users = [u for u in users if set(u["request_ids"]) <= released]
    else:
        users, why = load_list(list_path, now=now)
        if why:
            report.halted = why
            return report
    if lens is None:
        try:
            lens = DEFAULT_LENS(query, watchlist_path=watchlist_path, holds_path=holds_path)
        except ValueError as exc:
            report.halted = f"fraud lens unavailable ({exc}); nothing sent"
            return report
    documented: dict[str, Any] = {}
    if is_ask:
        try:
            documented = verify_notify.load_proof_on_file(proof_path)
        except verify_notify.ProofFileError as exc:
            report.halted = str(exc)
            return report
    want_paid = {"paid": True, "free": False}[segment]
    offered = [u for u in users if u.get("skip") is None and bool(u.get("paid")) is want_paid]
    report.listed = len(offered)
    day = (now or datetime.now(timezone.utc)).strftime("%Y-%m-%d")
    path = ledger_path or verify_ledger.DEFAULT_PATH
    cap = DAILY_MAX if is_ask else STATUS_DAILY_MAX
    db = verify_ledger.connect(path)
    try:
        cands: list[dict[str, Any]] = []
        for u in offered:
            if str(u.get("user_id")) in exclude_users:
                report.excluded += 1
                report.note("excluded_today")
                continue
            listed = [str(r) for r in (u.get("request_ids") or [])]
            if is_ask and documents_block(documented, str(u.get("user_id")), listed, released):
                report.proof_on_file += 1
                report.note("documents_on_file")
                continue
            if is_ask and documented.get(str(u.get("user_id"))):
                report.stage2_released += 1
            if listed and verify_ledger.blocked_ids(db, listed, campaign) >= set(listed):
                report.already_handled += 1
                report.note("already_handled")
                continue
            cands.append(u)
    finally:
        db.close()
    pos = 0

    def held(why: str) -> None:
        setattr(report, HOLDS[why], getattr(report, HOLDS[why]) + 1)
        report.note(why)

    def next_batch(want: int) -> list[tuple[set[str], dict[str, Any], int]]:
        """Up to `want` (listed request ids, sendable payload, rows left out) triples from the
        candidates after `pos`, dropping (and on a real run closing) the users the ledger or the
        replica already answers for."""
        nonlocal pos
        batch: list[tuple[set[str], dict[str, Any], int]] = []
        db = verify_ledger.connect(path)
        try:
            def close(u: dict[str, Any]) -> None:
                listed = [str(r) for r in (u.get("request_ids") or [])]
                if mode == "apply" and listed:
                    verify_ledger.skip_requests(db, campaign=campaign, request_ids=listed)

            while pos < len(cands) and len(batch) < want:
                chunk = cands[pos:pos + min(500, max(50, want - len(batch)))]
                accounts = accounts_of([int(u["user_id"]) for u in chunk], query)
                # The fraud lens runs FIRST, before any branch that can close a user's requests in the
                # ledger: a held user is never closed, whatever else is true of them (QA @214ea86).
                verdicts = lens([int(u["user_id"]) for u in chunk])
                picked: list[tuple[dict[str, Any], dict[str, str]]] = []
                for u in chunk:
                    if len(batch) + len(picked) >= want:
                        break
                    pos += 1
                    v = verdicts.get(int(u["user_id"]))
                    if v is None or v.held:
                        # Never messaged, never closed: re-checked on every run.
                        report.fraud_held += 1
                        report.note("fraud_held")
                        continue
                    if v.ask_only and campaign != CAMPAIGN:
                        # Fable Ruling B.2: big-track single-signal rows get the document ask only,
                        # never Copy A / B0 (nothing we send may imply approval). Not closed either.
                        report.ask_only += 1
                        report.note("big_track_ask_only")
                        continue
                    if v.watch:
                        report.watchlisted += 1
                        report.note("watchlisted_messageable")
                    acct = accounts.get(int(u["user_id"])) or {}
                    if not acct.get("email"):
                        report.no_email += 1
                        report.note("no_email")
                        close(u)
                        continue
                    hold = verify_ledger.refusal_hold(db, campaign, acct["email"], now, str(u["user_id"]))
                    if hold.get("flagged"):
                        report.already_handled += 1
                        report.note("refused_flagged")
                        continue
                    if hold:
                        report.refused_recheck += 1
                        report.note("refused_recheck")
                        first = hold["until"][:10]
                        report.recheck_after = min(report.recheck_after or first, first)
                        continue
                    if not acct.get("professional_id"):
                        report.no_professional_id += 1
                        report.note("no_professional_id")
                        continue
                    if campaign == GAP_ASK:
                        why = verify_ledger.gap_user_done(db, acct["email"], now=now, user_id=str(u["user_id"]))
                    else:
                        why = verify_ledger.uvn_user_done(db, acct["email"], now=now, campaign=campaign,
                                                          user_id=str(u["user_id"]))
                    if why == "recently_asked":
                        report.recently_asked += 1
                        report.note(why)
                        continue
                    if why in verify_ledger.DEFER_REASONS:
                        report.deferred_users += 1
                        report.note(why)
                        continue
                    if why:
                        report.already_handled += 1
                        report.note(why)
                        close(u)
                        continue
                    picked.append((u, acct))
                reqs = (pending_rows([int(u["user_id"]) for u, _ in picked], campaign, released, query,
                                     with_released=from_stage2) if picked else {})
                for u, acct in picked:
                    uid = int(u["user_id"])
                    # A stage-2 population names only the released requests; the note covers every
                    # request the campaign may ask about (the release is checked on each before the send).
                    listed = set() if from_stage2 else {str(r) for r in (u.get("request_ids") or [])}
                    pending = reqs.get(uid, [])
                    why, live = plan(listed, pending, is_ask)
                    why, live, as_count, total = count_copy_of(campaign, listed, pending, why, live)
                    if why in HOLDS:
                        held(why)
                        continue
                    if is_ask:
                        for r in pending:
                            if r["_no_ask"] and (not listed or r["request_id"] in listed):
                                setattr(report, r["_no_ask"], getattr(report, r["_no_ask"]) + 1)
                    if why:
                        report.note(why)
                        continue
                    if live and is_ask and documents_block(documented, str(uid), [r["request_id"] for r in live], released):
                        report.proof_on_file += 1
                        report.note("documents_on_file")
                        continue
                    if not live and not is_ask:
                        report.not_pending += 1
                        report.note("not_pending")
                        continue
                    if not live:
                        report.no_longer_uvn += 1
                        report.note("no_longer_uvn")
                        close(u)
                        continue
                    if as_count:
                        report.count_copy += 1
                        report.note("count_copy")
                    batch.append((listed, note_payload(acct, uid, live, as_count, total),
                                  0 if as_count else left_out(listed, pending, is_ask)))
        finally:
            db.close()
        return batch

    # One apply run per campaign at a time (QA: two concurrent runs each read the same
    # remaining daily slots and could both send past the cap). The lock is held for the whole
    # send loop, and the remaining cap is re-read from the ledger before every send.
    lock_fh = None
    if mode == "apply":
        lock_fh = open(f"{path}.{campaign}.run.lock", "a+")
        try:
            fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            lock_fh.close()
            report.halted = f"another {campaign} apply run is in progress; nothing sent by this one"
            return report

    def remaining_cap() -> int:
        db = verify_ledger.connect(path)
        try:
            return cap - verify_ledger.sent_today(db, campaign=campaign, day=day)
        finally:
            db.close()

    # Notes sent (or, on a dry run, that the gate would send) use the budget, and so does a gate
    # call that left its claim in the ledger without a verified post (outcome unknown: it may have
    # been delivered). The gate's deferrals, skips, refusals and other failures do not: keep going
    # past them, at most MAX_CALLS_PER_USER gate calls per budgeted user (QA: a canary whose first
    # candidates were skipped must still reach eligible users). On a real run the daily cap is a
    # hard bound: what is left of it is re-read from the ledger before every send.
    counted, calls, max_calls = 0, 0, MAX_CALLS_PER_USER * max_users

    def room() -> tuple[int, int]:
        left = remaining_cap() if mode == "apply" else max_users
        return min(max_users - counted, max_calls - calls, left), left

    try:
        while (want := room()[0]) > 0:
            batch = next_batch(want)
            if not batch:
                break
            for i, (listed, p, dropped) in enumerate(batch):
                allowed, left = room()
                if allowed <= 0:
                    report.over_daily_max += len(batch) - i
                    break
                if mode == "apply":
                    uid = int(p["user"]["id"])
                    # Re-read the strict proof-on-file list right before an ask (QA: proof that
                    # reached support@ or core while earlier users were being messaged is not
                    # in Intercom, so the gate would not see it). Unreadable = nothing more sent.
                    mine = released
                    if is_ask:
                        try:
                            documented = verify_notify.load_proof_on_file(proof_path)
                        except verify_notify.ProofFileError as exc:
                            report.halted = str(exc)
                            break
                        # The stage-2 release, re-read for this user right before the send (a
                        # later run may have judged a credit again). Unreadable = no release.
                        if documented.get(str(uid)) and campaign in stage2_verdicts.RELEASES:
                            try:
                                mine = stage2_released(campaign, stage2_path, user_ids=[uid])
                            except stage2_verdicts.Stage2Error:
                                mine = set()
                        if documented.get(str(uid)) and not mine:
                            report.proof_on_file += 1
                            report.note("documents_on_file")
                            continue
                    # Re-plan on a fresh replica read right before this user's send (QA: a request
                    # approved, withdrawn, opened or blanked while earlier users were being
                    # messaged must neither get a 'waiting on you' note nor be left out of it).
                    fresh = pending_rows([uid], campaign, mine, query, with_released=from_stage2).get(uid, [])
                    why, live = plan(listed, fresh, is_ask)
                    why, live, as_count, total = count_copy_of(campaign, listed, fresh, why, live)
                    if why in HOLDS:
                        held(why)
                        continue
                    dropped = 0 if as_count else left_out(listed, fresh, is_ask)
                    if not live:
                        if is_ask:
                            report.no_longer_uvn += 1
                        else:
                            report.not_pending += 1
                        report.note("changed_before_send")
                        continue
                    if is_ask and documents_block(documented, str(uid), [r["request_id"] for r in live], mine):
                        report.proof_on_file += 1
                        report.note("documents_on_file")
                        continue
                    acct = {k: p["user"].get(k, "") for k in ("email", "professional_id", "auth_id", "first_name")}
                    p = note_payload(acct, uid, live, as_count, total)
                    if calls and pace_seconds:
                        time.sleep(pace_seconds)
                before = report.sent_notes if mode == "apply" else report.validated + report.recipient_ok
                verify_notify.send_all([p], report, mode=mode, wrapper=wrapper, runner=runner,
                                       extra=["--campaign", campaign] + (["--copy", wording] if wording else []),
                                       pace_seconds=0, preview_dir=preview_dir)
                calls += 1
                reached = (report.sent_notes if mode == "apply" else report.validated + report.recipient_ok) - before
                report.users += reached
                counted += reached
                if reached and dropped:
                    report.rows_held += dropped
                    report.note("rows_left_out")
                if mode == "apply":
                    unknown = max(0, left - remaining_cap() - reached)
                    report.outcome_unknown += unknown
                    counted += unknown
                if report.halted:
                    break
            if report.halted:
                break
    finally:
        if lock_fh is not None:
            fcntl.flock(lock_fh.fileno(), fcntl.LOCK_UN)
            lock_fh.close()
    report.over_daily_max += len(cands) - pos
    if mode == "apply" and campaign in verify_ledger.RECHECKABLE_REFUSALS:
        verify_notify.flag_refusals(report, ledger_path=path, campaigns=[campaign], post=post, now=now)
    return report


def render(report: UvnReport, mode: str, segment: str) -> str:
    if report.halted:
        if report.sent_notes:
            return f"UVN STATUS ({segment}): STOPPED after {report.sent_notes} sent, nothing more sent: {report.halted}."
        return f"UVN STATUS ({segment}): NOTHING sent: {report.halted}."
    name = "GAP ASK" if report.campaign == GAP_ASK else "UVN STATUS"
    head = f"{name} ({segment}{', dry run' if mode != 'apply' else ''})"
    parts = [f"{head}: {report.listed} on the list for this segment, {report.users} messaged this run"
             if mode == "apply" else f"{head}: {report.listed} on the list, {report.users} would be messaged"]
    if mode == "apply":
        parts.append(f"{report.sent_notes} sent")
    for label, n in (("documents on file (not asked)", report.proof_on_file),
                     ("with documents on file, let through by a stage-2 verdict", report.stage2_released),
                     ("left out: another lane messages them today (--exclude-users)", report.excluded),
                     ("told by the count-only note (requests unshowable or over 1,000, no titles named)",
                      report.count_copy),
                     ("already handled (noted before, or documents received)", report.already_handled),
                     ("no longer waiting on them", report.no_longer_uvn),
                     ("request(s) not asked about: on the approval path (validator-approved, risk < 30, "
                      "popularity 1-59, no proof needed)", report.approval_path),
                     ("request(s) asked although low risk (server needs proof)", report.low_risk_asked),
                     ("request(s) not asked about: already on the profile (duplicate)", report.already_on_profile),
                     ("held by the fraud lens (watchlist, velocity above the band, or 10+ big-track "
                      "single-signal rows; never messaged, not closed)", report.fraud_held),
                     ("held from this status note: big-track single-signal rows, so the uvn-status document "
                      "ask only (not closed)", report.ask_only),
                     ("on the fraud watchlist (approvals held; considered for a message as usual)", report.watchlisted),
                     ("no request still pending (not closed)", report.not_pending),
                     ("no account email", report.no_email),
                     ("held: every pending request has a blank or unshowable title, artist or role "
                      "(re-checked next run, not closed)", report.incomplete),
                     ("request(s) left out of a note (blank or unshowable field; still pending in core and "
                      "reviewed, not asked about again by this campaign)", report.rows_held),
                     ("held: a request waiting on them is not on the list yet (re-run build.py; not closed)",
                      report.unlisted),
                     ("account(s) held: no professional id on the account, so the Intercom recipient cannot "
                      "be matched to it", report.no_professional_id),
                     ("validated (the gate would send)", report.validated if mode != "apply" else 0),
                     ("skipped by the gate (documents in Intercom, already sent)",
                      report.skipped if mode == "apply" else 0),
                     ("deferred (messaged in the last 7 days or today)", report.deferred_users),
                     ("deferred (asked in the last 90 days)", report.recently_asked),
                     ("left for the next run (daily cap / run size)", report.over_daily_max)):
        if n:
            parts.append(f"{n} {label}")
    if report.refused_users:
        parts.append(f"{report.refused_users} refused by the gate: " + "; ".join(report.refusals[:3]))
    if report.refused_recheck:
        parts.append(f"{report.refused_recheck} refused, re-check after {report.recheck_after}")
    if report.flagged:
        parts.append(f"{report.flagged} refused {verify_ledger.MAX_REFUSALS} times, flagged to #cs_priority for a human")
    if report.flag_failures:
        parts.append("FLAG FAILED: " + "; ".join(report.flag_failures[:3]))
    if report.outcome_unknown:
        parts.append(f"{report.outcome_unknown} post(s) not verified (outcome unknown: may have been delivered, "
                     "left claimed and never re-sent automatically; counted toward the run size and daily cap)")
    if report.failed_users:
        parts.append(f"FAILED {report.failed_users}: " + "; ".join(report.failures[:3]))
    return ". ".join(parts) + "."
