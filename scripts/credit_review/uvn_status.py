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
status-doc-received wording="received" (proof-loop captain card R1: the queued line without "no need to
send anything else", for a user who still owes proof) passes --copy received; it is send-locked in the gate
(STATUS_RECEIVED_COPY_APPROVED), and a real run with it halts before any gate call while the lock is 0.
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from . import comm_state, evidence, fraud_lens, policy, stage2_verdicts, verify_ledger, verify_notify
from .roles import ONE_PERSON_FAMILIES, family_of

# The proof-on-file kinds that mean "we approved a document" (decide.APPROVED_PROOF_KINDS).
APPROVED_PROOF_KINDS = frozenset({"approved_doc", "human_approved_after_doc"})

CAMPAIGN = "uvn-status"
GAP_ASK = verify_ledger.GAP_ASK
# The no-ask status notes (firstmate 070/071) run through this same driver with the
# credit-trust-llm-t01 lists status-A-doc-under-review (status-doc-received) and
# status-B-with-our-team (status-team-review). They are NOT asks: no proof-on-file exclusion
# (these users are the ones with documents or requests with us), no ask cap, never close an ask.
# credit-hold-status (Fable S1, card L14a): the neutral owing-proof line. NOT an ask (it asks for nothing) and not
# "nothing else is needed"; send-locked in the gate (CREDIT_HOLD_STATUS_COPY_APPROVED) until Fable's delegated yes.
CREDIT_HOLD = "credit-hold-status"
CAMPAIGNS = ("uvn-status", "status-doc-received", "status-team-review", GAP_ASK, CREDIT_HOLD)
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
    # credit-hold-status: rows still waiting on the user's proof (UVN, or unverified under a review hold)
    CREDIT_HOLD: ("user_verification_needed", "unverified"),
}
# A campaign the gate send-locks: a real run halts before any gate call while the gate script's own lock reads 0
# (a status-note refusal would hold the user and count toward the three-refusal flag, for nothing they did).
CAMPAIGN_LOCKS = {CREDIT_HOLD: "CREDIT_HOLD_STATUS_COPY_APPROVED", "uvn-status": "UVN_STATUS_COPY_APPROVED"}


def campaign_lock_open(wrapper: str, var: str) -> bool:
    """True only when the gate script itself says `readonly <var>=1` (unreadable = locked)."""
    try:
        with open(wrapper, encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        return False
    return re.search(rf"^readonly {re.escape(var)}=1$", text, re.M) is not None
# Rows in these statuses join a campaign only when stage 2 released them to it: uvn-status's
# no_document users whose requests are still `unverified` (held with us; firstmate spec item 2).
RELEASED_EXTRA_STATUSES = {"uvn-status": ("unverified",)}
# Reviewed baseline: deploy overwrites - 2026-10-26 (verify-ask-wiring-h2, firstmate inbox 015): node-8's
# paid-wave-runner-p2 hot-patch [key=p2-caps] (DAILY_MAX / STATUS_DAILY_MAX 20000, marked "reverts on next
# deploy") is superseded by the reviewed env caps below (CREDIT_STATUS_DAILY_MAX / CREDIT_UVN_DAILY_MAX).
CAP_LIMIT = 100000


def _cap_env(name: str, default: int) -> int:
    """A daily cap from the environment (firstmate 014, [key=p2-caps]: the captain's 2026-10-26 "move fast" order
    raised these for one night by a node-8 hot patch; this makes it a reviewed setting instead). A whole number
    1..CAP_LIMIT overrides the default; anything else (unset, blank, malformed, zero, negative, too large) keeps the
    default, so a typo can never remove the bound."""
    raw = os.environ.get(name, "").strip()
    return int(raw) if re.fullmatch(r"[0-9]{1,6}", raw) and 0 < int(raw) <= CAP_LIMIT else default


STATUS_DAILY_MAX = _cap_env("CREDIT_STATUS_DAILY_MAX", 1000)  # sanity bound for the no-ask status notes
LIST_MAX_AGE_H = 30
# (campaign, wording) pairs the gate takes as --copy; LOCKED_WORDINGS name the gate lock each one waits on.
WORDINGS = (("status-doc-received", "queued"), ("status-doc-received", "received"), ("status-doc-received", "queued-neutral"),
            ("status-team-review", "no-ask"))
LOCKED_WORDINGS = {"received": "STATUS_RECEIVED_COPY_APPROVED"}


def gate_lock_open(wrapper: str, var: str) -> bool:
    """True only when the gate script itself says `readonly <var>=1` (the gate is the single source of truth;
    unreadable = locked)."""
    try:
        text = Path(wrapper).read_text(encoding="utf-8")
    except OSError:
        return False
    return re.search(rf"^readonly {re.escape(var)}=1$", text, re.M) is not None
DAILY_MAX = _cap_env("CREDIT_UVN_DAILY_MAX", 400)  # the ask
MAX_CALLS_PER_USER = 5
Query = verify_notify.Query
trino = verify_notify.trino
# The deployed lens factory (fraud_lens.default_lens: watchlist + messaging holds, both required).
# A run without an explicit `lens` builds it; a missing or malformed file halts the run.
DEFAULT_LENS = fraud_lens.default_lens


@dataclass
class UvnReport(verify_notify.Report):
    # r5 bars (e)/(j) on [key=lamberto-reply-due]: every reply_due row of a run, with the thread facts the gate will act
    # on - {user, part, conversation, prior_note, assignee} (read live; 'unknown: ...' when unreadable)
    reply_due_rows: list = field(default_factory=list)
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
    facts_changed: list = field(default_factory=list)   # QA #1565: listed users whose owed set changed since the build
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


def _enforce_facts(list_path: str, users: list[dict[str, Any]], report: Any, query: Query) -> str:
    """QA #1565: a list built by owing_proof (it carries replica_facts) is checked against the replica BEFORE any send -
    the same owing_proof.verify_facts the signers run, enforced here so no ask goes on a stale list. A list edited
    after its build (or users carrying facts with no header) halts the run; a user whose owed set changed since the
    build is taken OUT (listed in facts_changed, never closed) - their one ask must not omit a newly owed row. An
    unreadable re-read halts (nothing sent). A list without facts (t01's uvn lists) is unchanged: plan() re-reads it."""
    with open(list_path, encoding="utf-8") as fh:
        doc = json.load(fh)
    if not isinstance(doc, dict) or ("replica_facts" not in doc and not any("facts" in u for u in users)):
        return ""
    from credit_review import owing_proof               # lazy: the builder's own rule, one implementation
    try:
        diffs = owing_proof.verify_facts(doc, query)    # the builder's own holds + ledger, as --verify-facts at signing
    except Exception as exc:  # noqa: BLE001 - a re-read that fails sends nothing
        return f"the replica facts re-read failed ({exc}); nothing sent"[:300]
    if any(d.startswith("header:") for d in diffs):
        return next(d for d in diffs if d.startswith("header:")) + "; nothing sent"
    changed = {d.split(":", 1)[0] for d in diffs}
    report.facts_changed = sorted(changed)
    users[:] = [u for u in users if str(u.get("user_id")) not in changed]
    for _ in changed:
        report.note("facts_changed")
    return ""


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
                "json_format(CAST(verificationdata AS json)), json_format(CAST(metadata AS json)), "
                "CAST(createdat AS varchar) "
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
                "_created": str(extra[2]) if len(extra) > 2 and extra[2] else "",
                "_no_ask": _no_ask_of(credits, pop, *(list(extra) + [None, None])[:2]),
                "_proof_required": _proof_required(*(list(extra) + [None, None])[:2])})
    for rows in reqs.values():
        rows.sort(key=lambda r: (-r["_pop"], r["track_title"].casefold()))  # most popular first
        for r in rows:
            r.pop("_pop", None)
    return reqs


def asks_proof_on_file(proof_path: str | None, *, now: datetime | None = None,
                       ledger_path: str | None = None) -> verify_notify.ProofOnFile:
    """r5 [key=asks-scoped-pof] (adopted by Fable 08:29Z): the ask/answer classes' proof-on-file read. Every part usable
    = load_proof_on_file, unchanged. When the ONLY unusable part is cs-gmail, the CLAIM notes' predicate decides - one
    implementation, claim_proof_ask.claim_holds, imported, never copied: it admits on fresh core + cs-intercom and names
    every user cs-gmail could vouch for (the support@ snapshot, email proof_intake rows, ledger support@ refs, gmail proof
    entries; a last good scan > 24 h = everyone). Those users are held (documents_block) and listed per run as
    stale_source:cs-gmail. Anything else unusable raises ProofFileError: nothing is asked.
    QA #1573: ONE snapshot - the export is read once into a private copy, and the strict read, claim_holds and the
    entries all come from that copy (an atomic replace between two opens can never pair A's holds with B's entries)."""
    import tempfile  # noqa: PLC0415
    src = proof_path or verify_notify.PROOF_ON_FILE
    try:
        with open(src, "rb") as fh:
            raw = fh.read()
    except OSError as exc:
        raise verify_notify.ProofFileError(f"the proof-on-file list {src} is unreadable ({type(exc).__name__})") from exc
    fd, snap = tempfile.mkstemp(prefix=".pof-", suffix=".json")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(raw)
        try:
            return verify_notify.load_proof_on_file(snap, now=now)
        except verify_notify.ProofFileError:
            from credit_review import claim_proof_ask  # noqa: PLC0415  (lazy: claim_proof_ask imports this module)
            holds = claim_proof_ask.claim_holds(snap, now=now, ledger_path=ledger_path)    # raises: refuse all
            out = verify_notify.proof_from_entries(json.loads(raw), holds.held)  # the frozen did-vouch set
            out.scoped = holds.scoped
            return out
    finally:
        os.unlink(snap)


STALE_GMAIL_REASON = "stale_source:cs-gmail"
# Fable [key=gmail-held-fallback] (10-31 11:5xZ, co-signed p1 + l1): a gmail-vouched user is held until Gmail is read -
# a stage with a named owner and a clock: waiting on the third party (the support@ mailbox; the captain's passkey), due
# the 16:00Z cutoff + 24 h. Listed on every run, counted paid / free (the line the captain card shows).
GMAIL_HOLD_WAITING_ON = "third_party:gmail"
GMAIL_HOLD_DUE_AT = "2026-11-01T16:00:00Z"


def gmail_held(uid: Any, paid: bool) -> dict[str, Any]:
    return {"user": str(uid), "result": "held", "reason": STALE_GMAIL_REASON, "waiting_on": GMAIL_HOLD_WAITING_ON,
            "due_at": GMAIL_HOLD_DUE_AT, "paid": bool(paid)}


def _no_ask_of(roles: str, pop: Any, vd_raw: Any, meta_raw: Any) -> str:
    """The row's no-ask class - except that core's EXPLICIT proof_required verdict (QA #1565) overrides the approval-path
    exclusion: a row core says needs proof is owed and asked, whatever the low-risk shortcut would have said.
    already_on_profile (the credit is already shown) is a different fact and stays."""
    cls = _row_class(roles, pop, vd_raw, meta_raw)
    return "" if cls == "approval_path" and _proof_required(vd_raw, meta_raw) else cls


def _proof_required(vd_json: Any, md_json: Any) -> bool:
    """[key=k-proof-required]: core's validator says this row needs proof (verificationData.proof_required = true) and
    core has not set a review-stage mark on it. Unparseable = False here (the row is simply not added to the ask)."""
    try:
        vd = json.loads(vd_json) if isinstance(vd_json, str) else (vd_json or {})
        md = json.loads(md_json) if isinstance(md_json, str) else (md_json or {})
    except ValueError:
        return False
    return isinstance(vd, dict) and vd.get("proof_required") is True and not (isinstance(md, dict) and md.get("reviewStage"))


# v1 / r5 / p1 [key=k-proof-required]: "every other unverified/UVN row is the ASK class" - an open unverified or
# processing row whose validator verdict says proof is required joins the uvn-status ask (it is owed, whatever core's
# status reads); it is never a status line
PROOF_REQUIRED_STATUSES = ("unverified", "processing")


def documents_block(documented: dict[str, Any], uid: str, ask_ids: list[str] | set[str], released: set[str],
                    created: str | None = None) -> bool:
    """True when the proof-on-file export keeps this user from an ask about `ask_ids`. A user with
    no entry is free. A user with entries is let through only when stage 2 released EVERY credit
    asked about (`released`) and no APPROVED proof names one of them; an entry for a credit stage
    2 did not release (or no credit at all) still excludes the user.
    p1 198 / Fable 199: only a document that could be THIS ask's proof counts - one naming a request asked about, or
    one that arrived on/after the oldest asked-about request was created (`created`). A document filed before the
    request existed cannot prove it (Lamberto 298376: March screenshots vs a 10-15 request). Unknown dates count."""
    entries = documented.get(str(uid)) or []
    since = when(created) if created else None
    dated = getattr(documented, "dated", {}).get(str(uid))
    if since is not None and dated is not None:
        ids0 = {str(r).strip().lower() for r in ask_ids if str(r).strip()}
        keep = []
        for rid, kind, proof_at in dated:
            at = when(proof_at) if proof_at else None
            if (rid and rid.lower() in ids0) or at is None or at >= since:
                keep.append((rid, kind))
        entries = keep
    if not entries:
        return False
    ids = {str(r).strip().lower() for r in ask_ids if str(r).strip()}
    if not ids or not ids <= released:
        return True
    return any(rid and rid.lower() in ids and kind in APPROVED_PROOF_KINDS for rid, kind in entries)


def when(value: Any) -> Any:
    """A timestamp from ISO or the replica's 'YYYY-MM-DD HH:MM:SS[.ffffff] UTC' (evidence.parse_ts reads only ISO)."""
    v = str(value or "").strip()
    if v.endswith(" UTC"):
        v = v[:-4].strip().replace(" ", "T", 1) + "Z"
    return evidence.parse_ts(v) if v else None


def oldest_created(rows: list[dict[str, Any]]) -> str | None:
    """The oldest createdat among the rows (None when any is unknown: then every document counts, fail closed)."""
    ts = [r.get("_created") or "" for r in rows]
    if not ts or not all(ts):
        return None
    parsed = [when(t) for t in ts]
    return None if any(p is None for p in parsed) else min(parsed).isoformat()


def created_of(rows: list[dict[str, Any]], live: list[dict[str, Any]]) -> str | None:
    """The oldest createdat of the `live` requests, read from the replica `rows` (plan() strips the '_' fields)."""
    ids = {str(r["request_id"]).lower() for r in live}
    return oldest_created([r for r in rows if str(r["request_id"]).lower() in ids]) if ids else None


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
    if campaign == CAMPAIGN and not with_released:
        for u, rows in uvn_requests(user_ids, query, PROOF_REQUIRED_STATUSES).items():
            have = {r["request_id"].lower() for r in reqs.get(u, [])}
            add = [r for r in rows if r.get("_proof_required") and r["request_id"].lower() not in have]
            if add:
                reqs.setdefault(u, []).extend(add)
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


def with_filing(payload: dict[str, Any], src: dict[str, Any]) -> dict[str, Any]:
    """Carry the list's filing_conversation (receipts.py: the proof_intake row's conversation) into the gate payload:
    the gate's G3 check sends the R1 receipt only to the contact that filed the document."""
    fc = str(src.get("filing_conversation") or "")
    if fc:
        payload["user"]["filing_conversation"] = fc
    return payload


def with_reply_due(payload: dict[str, Any], src: dict[str, Any]) -> dict[str, Any]:
    """Fable [key=reply-due]: a list row naming the user's unanswered customer part ({part, conversation}, digits)
    makes the note that thread's ONE answer: the gate gets --conversation + --reply-due and comm_state verifies the
    trigger (customer part, unanswered > 24 h, on-topic thread of exactly this contact). Anything malformed: ignored."""
    rd = src.get("reply_due") if isinstance(src.get("reply_due"), dict) else {}
    part, conv = str(rd.get("part") or ""), str(rd.get("conversation") or "")
    if part.isdigit() and conv.isdigit() and len(part) <= 24 and len(conv) <= 24:
        payload["extra"] = list(payload.get("extra") or []) + ["--conversation", conv, "--reply-due", part]
    return payload


def reply_due_row(uid: Any, src: dict[str, Any], facts: Callable[[str], dict[str, Any]] | None = None,
                  query: Query = trino) -> dict[str, Any]:
    """The dry-run row for one reply_due answer: the thread facts (comm_state.reply_due_thread) the gate acts on."""
    rd = src["reply_due"]
    row: dict[str, Any] = {"user": str(uid), "part": str(rd["part"]), "conversation": str(rd["conversation"])}
    try:
        f = (facts or (lambda conv: comm_state.reply_due_thread(conv, comm_state.intercom, part=row["part"])))(row["conversation"])
        row.update({"prior_note": f.get("prior_note"), "assignee": f.get("assignee")})
        if facts is None:      # r5 B: the classifier's verdict on the part (the class itself: comm_state at the gate)
            # the SAME function the send gate's comm_state.check uses (QA #1517: titles + filed-request evidence)
            keys = [str(c.get("request_id") or "") for c in (src.get("credits") or [])]
            row["trigger_class"] = comm_state.status_trigger(int(uid), keys, row["conversation"], row["part"], query,
                                                             comm_state.intercom)
        else:
            row["trigger_class"] = f.get("trigger_class")
    except Exception as exc:  # noqa: BLE001 - a report column; the gate re-reads and decides at send
        row.update({"prior_note": f"unknown: {exc}"[:120], "assignee": f"unknown: {exc}"[:120]})
    return row


def reply_due_of(payload: dict[str, Any]) -> dict[str, str]:
    """The {part, conversation} a built payload answers (its --reply-due / --conversation gate args), or {}."""
    ex = list(payload.get("extra") or [])
    try:
        return {"part": ex[ex.index("--reply-due") + 1], "conversation": ex[ex.index("--conversation") + 1]}
    except (ValueError, IndexError):
        return {}


def note_payload(acct: dict[str, str], uid: int, credits: list[dict[str, Any]], as_count: bool,
                 total: int, since: str | None = None) -> dict[str, Any]:
    user = {"email": acct["email"], "id": str(uid), "professional_id": acct["professional_id"],
            "auth_id": acct["auth_id"], "first_name": acct.get("first_name", "")}
    since = since or oldest_created(credits)
    if since:
        # the gate's document check counts only documents sent on/after this (p1 198 / Fable 199)
        user["requests_since"] = since
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
        check_recipients: bool = False, campaign: str = CAMPAIGN, post: verify_notify.Poster = verify_notify.post_cs_priority,
        wording: str = "", from_stage2: bool = False, stage2_path: str | None = None,
        exclude_users: set[str] | frozenset[str] = frozenset(), lens: fraud_lens.LensFn | None = None,
        watchlist_path: str | None = None, holds_path: str | None = None,
        segment_daily_cap: int | None = None) -> UvnReport:
    if campaign not in CAMPAIGNS:
        raise ValueError(f"unknown campaign {campaign!r}")
    if wording and (campaign, wording) not in WORDINGS:
        raise ValueError(f"wording {wording!r}: queued|received apply to status-doc-received, no-ask to status-team-review")
    if from_stage2 and campaign not in stage2_verdicts.RELEASES:
        raise ValueError(f"--from-stage2 feeds {', '.join(stage2_verdicts.RELEASES)} only")
    if campaign == GAP_ASK and not from_stage2:
        raise ValueError("gap-ask reaches only users stage 2 judged: run it with from_stage2")
    if not from_stage2 and not list_path:
        raise ValueError("a list is required unless the population comes from stage 2")
    is_ask = campaign in ASKS
    report = UvnReport(campaign=campaign)
    # A send-locked wording never reaches the gate on a real run: the gate would refuse every user, and a
    # refusal of a status note holds and COUNTS (three = flagged for a human), for nothing the user did.
    lock = LOCKED_WORDINGS.get(wording)
    if lock and mode == "apply" and not gate_lock_open(wrapper, lock):
        report.halted = f"--wording {wording} is send-locked in the gate ({lock}=0); nothing sent (dry-run renders it)"
        return report
    lock = CAMPAIGN_LOCKS.get(campaign)
    if lock and mode == "apply" and not campaign_lock_open(wrapper, lock):
        report.halted = f"{campaign} is send-locked in the gate ({lock}=0); nothing sent (dry-run renders it)"
        return report
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
        if is_ask:
            why = _enforce_facts(list_path, users, report, query)
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
            documented = asks_proof_on_file(proof_path, now=now, ledger_path=ledger_path)
        except verify_notify.ProofFileError as exc:
            report.halted = str(exc)
            return report
    want_paid = {"paid": True, "free": False}[segment]
    offered = [u for u in users if u.get("skip") is None and bool(u.get("paid")) is want_paid]
    if campaign == "status-team-review":
        # v1 STOP-CLASS / r5 + p1 [key=k-proof-required]: a status line is for owes-nothing users only. Read core's
        # proof_required for EVERY offered user before anything goes: one proof_required=true (or fresh capture pending)
        # row in the list REFUSES the run (the list was built wrong); an unreadable read refuses too (fail closed)
        from credit_review import comm_state              # lazy: the gate-side owes rule, the same read
        bad: list[str] = []
        for u in offered:
            try:
                owed = comm_state.proof_required_owed(int(u["user_id"]), query)
            except Exception as exc:  # noqa: BLE001 - an unreadable read never lets a status line through
                report.halted = f"proof_required read failed for user {u['user_id']} ({exc}); nothing sent"
                return report
            if owed:
                bad.append(f"{u['user_id']}:{'+'.join(owed)}")
        if bad:
            report.halted = (f"{len(bad)} user(s) in this status-team-review list owe proof per core proof_required "
                             f"({', '.join(bad[:10])}); the list must be rebuilt - nothing sent")
            return report
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
            if is_ask and getattr(documented, "scoped", False) and str(u.get("user_id")) in documented.support_contacts:
                report.note(STALE_GMAIL_REASON)                     # held, and LISTED per user (r5 condition 2)
                report.outcomes.append(gmail_held(u.get("user_id"), u.get("paid")))
                continue
            if is_ask and documents_block(documented, str(u.get("user_id")), listed, released, u.get("oldest") or None):
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
                                                          user_id=str(u["user_id"]),
                                                          skip_7d=bool(with_reply_due({}, u).get("extra")),
                                                          request_ids=list(u.get("request_ids") or []))
                    if why == "recently_asked":
                        report.recently_asked += 1
                        report.note(why)
                        continue
                    # [key=reply-due]: the 7-day note cooldown governs unsolicited notes, never the ONE answer to a
                    # user who wrote to us (QA #1509: this filter dropped the reply_due row before the gate saw it);
                    # the 90-day ask lock and one-per-user-ever still apply
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
                    if live and is_ask and documents_block(documented, str(uid), [r["request_id"] for r in live], released,
                                                           created_of(pending, live)):
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
                    payload = with_reply_due(with_filing(note_payload(acct, uid, live, as_count, total, created_of(pending, live)), u), u)
                    if mode != "apply" and with_reply_due({}, u).get("extra"):
                        # QA #1517: the row is classified on the PAYLOAD's own request ids - exactly what the gate's
                        # comm_state receives at send (the raw list row has request_ids, not credits)
                        report.reply_due_rows.append(reply_due_row(uid, {**u, "credits": payload.get("credits") or []}, query=query))
                    batch.append((listed, payload, 0 if as_count else left_out(listed, pending, is_ask)))
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

    def ledger_left() -> int:
        db = verify_ledger.connect(path)
        try:
            return cap - verify_ledger.sent_today(db, campaign=campaign, day=day)
        finally:
            db.close()

    def remaining_cap() -> int:
        left = ledger_left()
        if segment_daily_cap is not None:
            # QA #1541: the per-SEGMENT daily policy cap, re-read under this run's lock before every send (atomic with
            # the send) and counted from the runner's own segment record (the list's paid flag at send time - the
            # same source that chose the segment), never from a separate paying export
            left = min(left, segment_daily_cap - segment_used_today(path, campaign, segment, day))
        return left

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
                            documented = asks_proof_on_file(proof_path, now=now, ledger_path=ledger_path)
                        except verify_notify.ProofFileError as exc:
                            report.halted = str(exc)
                            break
                        if getattr(documented, "scoped", False) and str(uid) in documented.support_contacts:
                            # QA #1573: vouched for by cs-gmail since the batch read - held AND listed, never sent
                            report.note(STALE_GMAIL_REASON)
                            report.outcomes.append(gmail_held(uid, want_paid))
                            continue
                        # The stage-2 release, re-read for this user right before the send (a
                        # later run may have judged a credit again). Unreadable = no release.
                        if documented.get(str(uid)) and campaign in stage2_verdicts.RELEASES:
                            try:
                                mine = stage2_released(campaign, stage2_path, user_ids=[uid])
                            except stage2_verdicts.Stage2Error:
                                mine = set()
                        # a stage-2-populated campaign (gap-ask): the population IS the release - a credit no longer
                        # released is a document on file, date or not. Every other ask: the one date-aware check below
                        # (documents_block with the request date), the same as the dry run (QA #1508).
                        if from_stage2 and documented.get(str(uid)) and not mine:
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
                    if is_ask and documents_block(documented, str(uid), [r["request_id"] for r in live], mine,
                                                  created_of(fresh, live)):
                        report.proof_on_file += 1
                        report.note("documents_on_file")
                        continue
                    acct = {k: p["user"].get(k, "") for k in ("email", "professional_id", "auth_id", "first_name")}
                    # rebuilt from a fresh replica read: the answer's gate args (reply_due) carry over (QA #1509)
                    p = with_reply_due(with_filing(note_payload(acct, uid, live, as_count, total, created_of(fresh, live)),
                                                   p["user"]), {"reply_due": reply_due_of(p)})
                    if calls and pace_seconds:
                        time.sleep(pace_seconds)
                before = report.sent_notes if mode == "apply" else report.validated + report.recipient_ok
                l0 = ledger_left() if mode == "apply" else 0
                verify_notify.send_all([p], report, mode=mode, wrapper=wrapper, runner=runner,
                                       extra=["--campaign", campaign] + (["--copy", wording] if wording else []),
                                       pace_seconds=0, preview_dir=preview_dir,
                                       check_recipients=check_recipients and mode != "apply")
                calls += 1
                reached = (report.sent_notes if mode == "apply" else report.validated + report.recipient_ok) - before
                report.users += reached
                counted += reached
                if reached and dropped:
                    report.rows_held += dropped
                    report.note("rows_left_out")
                if mode == "apply":
                    unknown = max(0, l0 - ledger_left() - reached)
                    report.outcome_unknown += unknown
                    counted += unknown
                    if segment_daily_cap is not None and reached + unknown:
                        # QA #1541: this segment's messages (sent + outcome-unknown), under the run lock
                        record_segment(path, campaign, segment, day, str(uid), reached + unknown)
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


def _segments_path(ledger: str) -> str:
    return f"{ledger}.segments.jsonl"


def segment_sent_today(ledger: str, campaign: str, segment: str, day: str) -> int:
    """Messages the runner recorded for campaign+segment on `day` (sent or outcome-unknown). Missing file = 0; an
    unreadable or malformed record raises (the run halts: fail closed)."""
    p = _segments_path(ledger)
    if not os.path.exists(p):
        return 0
    n = 0
    with open(p, encoding="utf-8") as f:
        for ln in f:
            if ln.strip():
                r = json.loads(ln)
                if r["day"] == day and r["campaign"] == campaign and r["segment"] == segment:
                    n += int(r["n"])
    return n


def segment_used_today(ledger: str, campaign: str, segment: str, day: str) -> int:
    """QA #1541: what the segment cap charges - the runner's record for this segment PLUS every message the ledger shows
    for the campaign today that the record does not cover (a hand run without --segment-daily-cap, a crash between the
    ledger claim and the record): unknown segment = charged to BOTH segments (fail closed)."""
    recorded_users: set[str] = set()
    p = _segments_path(ledger)
    if os.path.exists(p):
        with open(p, encoding="utf-8") as f:
            for ln in f:
                if ln.strip():
                    r = json.loads(ln)
                    if r["day"] == day and r["campaign"] == campaign:
                        recorded_users.add(str(r["user"]))
    db = verify_ledger.connect(ledger)
    try:
        rows = db.execute("SELECT account_id FROM verify_messages WHERE campaign=? AND day=? "
                          "AND status IN ('attempted','sent')", (campaign, day)).fetchall()
    finally:
        db.close()
    unrecorded = sum(1 for (a,) in rows if str(a) not in recorded_users)
    return segment_sent_today(ledger, campaign, segment, day) + unrecorded


def record_segment(ledger: str, campaign: str, segment: str, day: str, user: str, n: int) -> None:
    with open(_segments_path(ledger), "a", encoding="utf-8") as f:
        f.write(json.dumps({"day": day, "campaign": campaign, "segment": segment, "user": user, "n": int(n)}) + "\n")
        f.flush(); os.fsync(f.fileno())


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
                     ("held: their owed requests changed since the list was built (rebuild the list; not closed)",
                      len(report.facts_changed)),
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
    if report.deferrals:
        parts.append(f"{len(report.deferrals)} deferred by the gate at send: " + "; ".join(report.deferrals[:20]))
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
    for r in report.reply_due_rows:                                   # every row (QA #1517): the reviewer reads them all
        pn, a = r.get("prior_note"), r.get("assignee")
        parts.append(f"reply_due user {r['user']} part {r['part']} conversation {r['conversation']}: prior_note "
                     + (f"{pn['part']} ({pn['campaign']})" if isinstance(pn, dict) else str(pn or "none"))
                     + "; assignee " + (f"{a['id']} {a.get('name') or ''} action={a['action']}".replace("  ", " ")
                                        if isinstance(a, dict) else str(a or "none"))
                     + (f"; trigger_class {tc['class']} ({tc['why']}, {tc['part_age_d']} d)"
                        if isinstance((tc := r.get("trigger_class")), dict) else ""))
    gh = [o for o in report.outcomes if o.get("reason") == STALE_GMAIL_REASON]
    if gh:
        paid = sum(1 for o in gh if o.get("paid"))
        parts.append(f"held by the Gmail outage: {paid} paid / {len(gh) - paid} free (waiting on {GMAIL_HOLD_WAITING_ON}, "
                     f"due {GMAIL_HOLD_DUE_AT}; listed in the outcomes)")
    return ". ".join(parts) + "."
