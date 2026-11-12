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
import sqlite3
import subprocess
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from . import comm_state, evidence, fraud_lens, policy, stage2_verdicts, verify_ledger, verify_notify
from .decide import ASK_HOLD_MARKERS
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
# fable-copy-1101-r5/n1: the follow-up ask to a told user about owed rows no ask named (owing_proof class uvn_new_rows);
# the uvn ask in every runner rule (statuses, proof_required rows, the fraud lens), send-locked in the gate.
NEW_ROWS = "uvn-new-rows"
# [key=wait-apology] (Fable d2 2026-11-05 01:4xZ, the captain's 01:4xZ order): the apology + one live status fact for
# users who have waited with no message from us. NOT an ask (nothing is requested: F1 does, F2 and F3 do not), so it has
# no document exclusion and no ask cap - the fact sentence is what the live state decides, and a state outside F1/F2/F3
# refuses that user (the gate refuses on a missing fact too).
WAIT_APOLOGY = "wait-apology"
CAMPAIGNS = ("uvn-status", "status-doc-received", "status-team-review", GAP_ASK, CREDIT_HOLD, NEW_ROWS, WAIT_APOLOGY)
# The campaigns that ASK (documents-on-file exclusion, the ask cap, closing asks).
ASKS = ("uvn-status", GAP_ASK, NEW_ROWS)
# The replica re-check per campaign (firstmate 076): uvn-status needs requests still waiting on
# the user; the status notes need requests still pending with us. A status-note user with none
# left is `not_pending`: counted, never closed in the ledger.
PENDING_STATUSES = {
    "uvn-status": ("user_verification_needed",),
    NEW_ROWS: ("user_verification_needed",),
    "status-doc-received": ("user_verification_needed", "unverified", "processing"),
    "status-team-review": ("user_verification_needed", "unverified", "processing"),
    # gap-ask: the decider's held rows; only stage-2 need_more ones are ever kept (run()).
    GAP_ASK: ("unverified", "user_verification_needed"),
    # credit-hold-status: rows still waiting on the user's proof (UVN, or unverified under a review hold)
    CREDIT_HOLD: ("user_verification_needed", "unverified"),
    # wait-apology: the apology is about EVERY request of theirs, decided ones included - F3 is a decided row, and
    # dropping it would refuse exactly the users this campaign exists for
    WAIT_APOLOGY: ("user_verification_needed", "unverified", "processing", "approved", "rejected"),
}
# A campaign the gate send-locks: a real run halts before any gate call while the gate script's own lock reads 0
# (a status-note refusal would hold the user and count toward the three-refusal flag, for nothing they did).
CAMPAIGN_LOCKS = {CREDIT_HOLD: "CREDIT_HOLD_STATUS_COPY_APPROVED", "uvn-status": "UVN_STATUS_COPY_APPROVED",
                  NEW_ROWS: "UVN_NEW_ROWS_COPY_APPROVED"}


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
# The decider's per-role split (captain 2026-11-06): it approved the roles its proof covered and still
# owes an ask for the rest. The request stays `unverified` in core because the per-role write half does
# not exist yet, so the replica re-check alone drops it and the user is never asked for the roles owed.
PARTIAL_DECISION = "approve_partial"
# Reviewed baseline: deploy overwrites - 2026-10-26 (verify-ask-wiring-h2, firstmate inbox 015): node-8's
# paid-wave-runner-p2 hot-patch [key=p2-caps] (DAILY_MAX / STATUS_DAILY_MAX 20000, marked "reverts on next
# deploy") was superseded by env caps, which are now gone too: the policy file below is the ONE source.
CAP_LIMIT = 100000


# [key=uvn-daily-cap-400] (r5 626 + p1, 11-01): ONE daily cap for the credit messages, read IN CODE by the hand runner
# and the outbound tick alike - the policy file's shared_daily_cap.credit (credit-verify-outbound.json, a PR-owned
# constant: a change is a PR). No environment variable moves it ([key=unattended]; CREDIT_UVN_DAILY_MAX /
# CREDIT_STATUS_DAILY_MAX are ignored). An unreadable policy is a cap of 0 (fail closed: nothing is sent).
POLICY_PATH = str(Path(__file__).resolve().parents[2] / "policies" / "credit-verify-outbound.json")


# QA #1617: the credit campaigns the shared cap MUST cover (each has a daily_cap row in the policy and a sender here or
# in need_asks); a policy whose credit group omits one is malformed (refused), never a smaller budget
REQUIRED_CREDIT_GROUP = frozenset({"uvn-status", "status-doc-received", "proof-need-ask"})


def read_policy(path: str = POLICY_PATH) -> tuple[int, tuple[str, ...]] | None:
    """(the shared credit cap, the credit group's campaigns) from the policy file; None = unreadable or malformed."""
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
        v, group = doc["shared_daily_cap"]["credit"], doc["groups"]["credit"]
    except (OSError, ValueError, KeyError, TypeError):
        return None
    if not (isinstance(v, int) and 0 <= v <= CAP_LIMIT and isinstance(group, list)
            and all(isinstance(c, str) for c in group)):
        return None
    if not REQUIRED_CREDIT_GROUP <= set(group):
        return None        # QA #1617: a credit group missing a credit campaign would let it spend outside the shared cap
    return v, tuple(group)


def policy_credit_cap(path: str = POLICY_PATH) -> int:
    p = read_policy(path)
    return p[0] if p else 0


_POLICY = read_policy()


def group_lock_path(ledger: str, campaign: str) -> str:
    """QA #1617: ONE run lock for every credit campaign (one shared budget), whichever module sends it."""
    return f"{ledger}.{'credit-group' if campaign in CREDIT_GROUP else campaign}.run.lock"


def credit_group_left(ledger: str, day: str) -> int:
    """QA #1617: what is left today of the policy's shared credit cap, counted over EVERY credit campaign's sends.

    QA #1370: EMAIL notes only. The caps pace email (captain 2026-10-26 16:05Z: "caps may pace email only; the in-app
    message goes to everyone"), so an in-app note must never spend a credit campaign's email budget - it is bounded on
    its own by INAPP_DAILY_MAX and the segment cap."""
    db = verify_ledger.connect(ledger)
    try:
        return DAILY_MAX - sum(verify_ledger.sent_today(db, campaign=c, day=day, message_type="email")
                               for c in CREDIT_GROUP)
    finally:
        db.close()
POLICY_OK = _POLICY is not None     # QA #1617: an unreadable policy is a REFUSAL, never a silent cap of 0
# QA #1617 (Critical): the shared cap is ONE budget for every credit message - each campaign's run counts the whole
# group's sends today (the policy's credit group, plus every campaign this runner sends), under ONE group run lock
CREDIT_GROUP = tuple(dict.fromkeys((_POLICY[1] if _POLICY else ()) + ("uvn-status", "status-doc-received",
                                                                      "status-team-review", "gap-ask",
                                                                      "credit-hold-status", "uvn-new-rows")))


STATUS_DAILY_MAX = policy_credit_cap()  # the no-ask status notes
# With --inapp-overflow the per-campaign cap (DAILY_MAX / STATUS_DAILY_MAX) paces EMAIL notes only; once it is spent
# the note goes in-app (gate --channel inapp: the user's open conversation, else an Intercom in-app message, never
# email). This is the sanity bound on all of a day's notes - it never lifts the shared credit cap above.
INAPP_DAILY_MAX = 5000
LIST_MAX_AGE_H = 30
# [key=facts-stale-fallback] (firstmate 2026-11-11, Fable ruling): the facts re-read is now scoped to this page's users
# (owing_proof.replica_sql), but a replica that is slow AND the whole page can still push the one read past its timeout.
# Before this, a timeout was terminal for the family: `nothing sent`, and every family behind it too - on 2026-11-11
# that was every tick from 09:2xZ to 21:3xZ. The list's own `replica_facts` header IS the last successful read (the tick
# rebuilds it immediately before the family), so a timeout falls back to it, states its age (`facts stale Nm`), and
# sends only while that age is inside this bar. Past the bar the re-read's whole purpose - "the owed set has not changed
# since the list was built" - is no longer something we can claim, so the family halts exactly as it does today.
FACTS_STALE_MAX_MIN = 90
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
DAILY_MAX = policy_credit_cap()  # the ask
MAX_CALLS_PER_USER = 5
# 14:2xZ eligibility-first paging: one run may examine at most this many raw list entries per candidate it is allowed
# to keep, so a long run of already-told / documented / handled rows can never turn a tick into a no-op
# while still bounding the scan cost (a replica + ledger read per entry, no live call).
SCAN_FACTOR = 20
Query = verify_notify.Query
trino = verify_notify.trino
# The deployed lens factory (fraud_lens.default_lens: watchlist + messaging holds, both required).
# A run without an explicit `lens` builds it; a missing or malformed file halts the run.
DEFAULT_LENS = fraud_lens.default_lens


@dataclass
class UvnReport(verify_notify.Report):
    policy_error: bool = False         # QA #1617: the cap policy could not be read (a refusal, CLI exit 2)
    cap_short: bool = False            # [key=uvn-daily-cap-400]: a signed apply refused before its first send
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
    facts_stale_min: int | None = None  # [key=facts-stale-fallback]: the re-read timed out; this page's facts are Nm old
    recently_asked: int = 0
    excluded: int = 0                  # --exclude-users (another lane messages them today)
    count_copy: int = 0                # status-team-review users sent the count-only note (not held)
    stage2_released: int = 0           # documented users let through by a stage-2 verdict
    not_walked: int = 0                # p1 599: list entries outside this run's --max-entries page (other runs')
    page: dict = field(default_factory=dict)   # QA #1612: {start, end, listed} - the list entries this run walked
    campaign: str = ""
    fraud_held: int = 0
    ask_only: int = 0
    watchlisted: int = 0               # on the approval watchlist; messaged normally (reported, never a hold)
    refused_no_fact: int = 0           # [key=apology-fact]: the live state was not F1/F2/F3 - this user is refused
    by_reason: dict[str, int] = field(default_factory=dict)

    def note(self, why: str) -> None:
        self.by_reason[why] = self.by_reason.get(why, 0) + 1


def load_list(path: str, *, now: datetime | None = None) -> tuple[list[dict[str, Any]], str]:
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    verify_notify.bind_list(doc)           # [key=signed-on-sha]: the per-user sha rail reads this header
    from .evidence import parse_ts
    gen = parse_ts(doc.get("generated_at")) if isinstance(doc, dict) else None
    users = doc.get("users") if isinstance(doc, dict) else None
    if gen is None or not isinstance(users, list):
        return [], "the list has no generated_at or users[]"
    age_h = ((now or datetime.now(timezone.utc)) - gen).total_seconds() / 3600
    if age_h > LIST_MAX_AGE_H or age_h < -0.1:
        return [], f"the list is {age_h:.1f}h old (limit {LIST_MAX_AGE_H}h): re-run build.py first"
    return users, ""


def _re_read_timed_out(exc: BaseException) -> bool:
    """True only for the timeout class: `trino()` runs the wrapper under `timeout=900`, so a stalled replica arrives as
    TimeoutExpired. A TrinoTransientError is NOT included on purpose - a semantic "retry in a few minutes" is the tick's
    deferral rail's business (it retries, then defers), not a licence to send on facts we never confirmed."""
    return isinstance(exc, subprocess.TimeoutExpired)


def _enforce_facts(list_path: str, users: list[dict[str, Any]], report: Any, query: Query, *,
                   ledger_path: str | None = None, holds_path: str | None = None) -> str:
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
    ledger = ledger_path or owing_proof.LEDGER
    holds = holds_path or owing_proof.ACCOUNT_HOLDS
    try:
        diffs = owing_proof.verify_facts(doc, query, holds_path=holds, ledger_path=ledger)
    except Exception as exc:  # noqa: BLE001 - a re-read that fails sends nothing
        # [key=facts-stale-fallback] (Fable 2026-11-11): a TIMEOUT is not evidence the facts are wrong, it is evidence the
        # replica did not answer. Fall back to the list's own facts (the last successful read) while they are still young
        # enough for the claim the re-read exists to make, and SAY how old they are. Anything else - a SQL error, a bad
        # row shape - stays terminal: that is the replica telling us something we must not paper over.
        if _re_read_timed_out(exc):
            # The replica did not answer, so the replica-dependent comparison falls back to the list's own facts. The
            # checks that never needed the replica do NOT: a list edited after its build, a released hold or an ask
            # sent since the build still halt/refuse here, exactly as they do on a successful re-read.
            try:
                held = owing_proof.held_accounts(holds, ledger)
                asked = owing_proof.asked_rows(ledger)
                local = owing_proof.local_diffs(doc, held, asked)
            except Exception as local_exc:  # noqa: BLE001 - a local check that cannot run sends nothing
                return f"the replica facts re-read timed out and the local checks failed ({local_exc}); nothing sent"[:300]
            if any(d.startswith("header:") for d in local):
                return next(d for d in local if d.startswith("header:")) + "; nothing sent"
            changed = {d.split(":", 1)[0] for d in local}
            report.facts_changed = sorted(changed)
            users[:] = [u for u in users if str(u.get("user_id")) not in changed]
            for _ in changed:
                report.note("facts_changed")
            from .evidence import parse_ts
            gen = parse_ts(doc.get("generated_at")) if isinstance(doc, dict) else None
            age_min = int((datetime.now(timezone.utc) - gen).total_seconds() // 60) if gen else None
            if age_min is not None and 0 <= age_min <= FACTS_STALE_MAX_MIN:
                report.facts_stale_min = age_min
                return ""
            return ("the replica facts re-read timed out and the list's own facts are "
                    f"{age_min if age_min is not None else '?'}m old (bar {FACTS_STALE_MAX_MIN}m); nothing sent")[:300]
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


def read_gmail_hold(path: str = POLICY_PATH) -> dict[str, Any]:
    """The Gmail hold from the policy file's holds.gmail ([key=dated-windows-are-data], l1 ruling 2026-11-02): the wait
    owner and the due date are DATA - a date literal in a shipped script is a CI red with a countdown on it. {} = the
    file or the key is unreadable; the caller then states the due date as unknown rather than inventing one."""
    try:
        with open(path, encoding="utf-8") as fh:
            hold = json.load(fh)["holds"]["gmail"]
    except (OSError, ValueError, KeyError, TypeError):
        return {}
    return hold if isinstance(hold, dict) else {}


_GMAIL_HOLD = read_gmail_hold()


def gmail_held(uid: Any, paid: bool) -> dict[str, Any]:
    due = _GMAIL_HOLD.get("due_at")
    return {"user": str(uid), "result": "held", "reason": STALE_GMAIL_REASON,
            "waiting_on": _GMAIL_HOLD.get("waiting_on") or GMAIL_HOLD_WAITING_ON,
            "due_at": due if isinstance(due, str) and due else None, "paid": bool(paid)}


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


def partial_pending_roles(ledger_path: str | None = None,
                          request_ids: list[str] | None = None) -> dict[str, list[str]]:
    """Request id -> the roles whose latest decider decision is a per-role split that still owes them
    (`approve_partial` with a non-empty `pending_roles`), request ids lowercased.

    This is the ONE decider-driven exception to the replica re-check: such a request is still
    `unverified` in core (the decision half writes nothing), so without it the user who was
    approved for one role and owes proof for another is never asked about the rest.

    Only an APPLY row names a live ask: `judge` is shadow and must never message a customer.

    A row `filter_support` withheld the ask for is NOT in the population: it keeps its PARTIAL
    decision and its roles, so the hold/defer marker is the only record that the ask must not go
    (never re-ask, a document on file, the 24h window, the caps). A defer is re-askable because the
    decider re-decides the row and writes a fresh reason without the marker."""
    path = ledger_path or verify_ledger.DEFAULT_PATH
    if not os.path.exists(path):
        return {}
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=30)
    try:
        # The decider owns this schema and adds `pending_roles` additively; a ledger written before
        # that migration has no such column and no partial rows either.
        if "pending_roles" not in {r[1] for r in db.execute("PRAGMA table_info(decisions)")}:
            return {}
        sql = ("WITH last AS (SELECT request_id, MAX(id) id FROM decisions WHERE mode = 'apply' "
               "GROUP BY request_id) "
               "SELECT d.request_id, d.reason, d.pending_roles FROM decisions d JOIN last USING(id) "
               "WHERE d.decision = ? AND coalesce(d.pending_roles, '') <> ''")
        args: list[Any] = [PARTIAL_DECISION]
        # The pre-send re-read asks about ONE user's listed requests, so it must not scan the whole
        # ledger for every user in the batch.
        if request_ids is not None:
            wanted = sorted({str(r).strip().lower() for r in request_ids if str(r).strip()})
            if not wanted:
                return {}
            sql += f" AND lower(d.request_id) IN ({','.join('?' * len(wanted))})"
            args.extend(wanted)
        rows = db.execute(sql, args).fetchall()
    finally:
        db.close()
    return {str(r[0]).lower(): [x.strip() for x in str(r[2] or "").split(",") if x.strip()]
            for r in rows if r[0] and not str(r[1] or "").startswith(ASK_HOLD_MARKERS)}


def partial_pending_ids(ledger_path: str | None = None) -> set[str]:
    """The request-id half of `partial_pending_roles` (the list builder's population)."""
    return set(partial_pending_roles(ledger_path))


def partial_scoped(rows: list[dict[str, Any]], partial_roles: dict[str, list[str]],
                   listed: list[str]) -> list[dict[str, Any]]:
    """A per-role split entry speaks ONLY for the rows on its list and ONLY about the roles it still
    owes. The user's other open requests are neither asked about nor treated as an unlisted hold, and
    the customer is never asked to prove a role the decider already approved."""
    ids = {str(r).strip().lower() for r in listed if str(r).strip()}
    out: list[dict[str, Any]] = []
    for row in rows:
        rid = str(row["request_id"]).lower()
        if rid not in ids:
            continue
        owed = partial_roles.get(rid)
        if owed is None:
            # The list is a SNAPSHOT: it was built when this request was a per-role split. If the
            # latest apply decision no longer owes any role (it became `support`, or the split was
            # otherwise resolved), the row must not be asked about at all. The replica row still
            # carries the ORIGINAL role text, so letting it through would ask the customer to prove
            # a role the decider already approved (QA 2026-11-11, hydra#1851). Drop it; the decider
            # re-decides the row and the list builder rebuilds the population.
            continue
        row = dict(row)
        row["role"] = ", ".join(owed)
        row["_incomplete"] = _row_incomplete(row["track_title"], row["artist_name"], row["role"],
                                            row["profile_id"], row["track_id"])
        out.append(row)
    return out


def pending_rows(user_ids: list[int], campaign: str, released: set[str],
                 query: Query = trino, *, with_released: bool = False,
                 partial_ids: set[str] | frozenset[str] = frozenset()) -> dict[int, list[dict[str, Any]]]:
    """uvn_requests for the campaign, with the stage-2 release applied: gap-ask, and any run whose
    population is stage 2's (`with_released`), keeps ONLY the released requests (an unjudged
    request of the same user is never named: QA on #1364); with `with_released` uvn-status also
    adds the released requests still `unverified`. A list-driven uvn-status run is bounded by
    t01's list instead and never adds them (they would hold the user as unlisted) - except the
    decider's per-role splits (`partial_ids`), which are exactly the rows that owe an ask."""
    reqs = uvn_requests(user_ids, query, PENDING_STATUSES[campaign])
    if campaign == GAP_ASK or with_released:
        reqs = {u: kept for u, rows in reqs.items()
                if (kept := [r for r in rows if r["request_id"].lower() in released])}
    if campaign in (CAMPAIGN, NEW_ROWS) and not with_released:
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
    if extra and partial_ids and not with_released:
        for u, rows in uvn_requests(user_ids, query, extra).items():
            have = {r["request_id"].lower() for r in reqs.get(u, [])}
            add = [r for r in rows if r["request_id"].lower() in partial_ids
                   and r["request_id"].lower() not in have]
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
    # h2: the filing's class as receipts.py stated it from the doc reader (a bool only; absent = unknown -> the gate
    # refuses the R1 with r1_filing_class_unknown, a true -> refused as a Muso screenshot)
    if isinstance(src.get("filing_muso_ui"), bool):
        payload["user"]["filing_muso_ui"] = src["filing_muso_ui"]
    if src.get("filing_unreadable") is True:            # r5 [key=r1-no-readable-text]: the gate refuses that R1
        payload["user"]["filing_unreadable"] = True
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


DECIDED_STATUSES = ("approved", "rejected")
# QA #1788 finding 2 (carried twice): `processing` is TEAM-owned, not user-owed. Grouping it with the user-owed states
# made a request already in our queue tell the user it was "waiting on one thing from you" - false, and the one thing
# the copy must never do. The two groups are counted apart and apology_fact() refuses every combination no single
# sentence is true of.
WAITING_STATUSES = ("user_verification_needed", "unverified")
TEAM_STATUSES = ("processing",)


def apology_states(user_ids: list[int], query: Query = trino) -> dict[int, dict[str, Any]]:
    """[key=apology-fact] the LIVE request state an apology may name, per user (d2's copy: "the fact sentence comes
    from a LIVE read at send time, never from the list"). Returns
    {uid: {"waiting": n, "team": n, "decided": n, "approved": n, "unknown": n}}.
    A user absent from the result has no request at all: no fact, so no message.

    QA #1788 finding 5: an UNRECOGNISED status is counted as `unknown`, never silently dropped. Dropping it made a user
    with one approved row and one status we do not know read as "decided" and get F3 - a sentence that claims a decision
    about a request whose state we could not read. An unknown row makes the whole state UNKNOWN, and apology_fact()
    refuses it."""
    out: dict[int, dict[str, Any]] = {}
    for i in range(0, len(user_ids), 500):
        chunk = user_ids[i:i + 500]
        for row_ in query(
                "SELECT CAST(userid AS varchar), status, CAST(id AS varchar) "
                "FROM postgresql_core.public.credit_requests "
                f"WHERE deletedat IS NULL AND userid IN ({_ids(chunk)})"):
            uid, status = row_[0], row_[1]
            rid = row_[2] if len(row_) > 2 else None      # a caller that selects only (user, status) still works
            if not str(uid).isdigit():
                continue
            row = out.setdefault(int(uid), {"waiting": 0, "team": 0, "decided": 0, "approved": 0, "unknown": 0,
                                            "undecided_ids": []})
            st = str(status or "")
            if st in WAITING_STATUSES:
                row["waiting"] += 1
                if rid is not None:
                    row["undecided_ids"].append(str(rid))
            elif st in TEAM_STATUSES:
                row["team"] += 1
                if rid is not None:
                    row["undecided_ids"].append(str(rid))
            elif st in DECIDED_STATUSES:
                row["decided"] += 1
                if st == "approved":
                    row["approved"] += 1
            else:
                row["unknown"] += 1
    return out


def doc_coverage(entries: Any, undecided_ids: list[str]) -> tuple[int, int]:
    """(covered, uncovered) of a user's LIVE undecided requests by their proof-on-file entries.

    QA #1788 r10 (Important): the send-time check only asked whether the user appears ANYWHERE in the proof export,
    although entries can be request-specific. A user with two waiting requests and a document for only one therefore
    got F2 - "we have what you sent ... nothing more is needed from you" - which is FALSE for the second request. An
    entry with ``request_id is None`` is a whole-user document and covers every request; an entry naming a request
    covers only that one."""
    covered = uncovered = 0
    for rid in undecided_ids or []:
        if any(e[0] is None or str(e[0]) == str(rid) for e in (entries or [])):
            covered += 1
        else:
            uncovered += 1
    return covered, uncovered


def apology_fact(state: dict[str, Any] | None, has_doc: bool,
                 coverage: tuple[int, int] | None = None) -> tuple[str, bool]:
    """The ONE fact sentence this note may carry, or ("", False) = refuse this user (d2: "if the live state is not one
    of the four below, the sender REFUSES that user").

    F1 waiting on them   - something is still with the user and no usable document is on file
    F2 in review         - a document is on file and no decision has been made (this is also the ONLY true sentence for a
                           request already in OUR queue: "we have what you sent, and it is in our review queue")
    F3 decided, not told - every request is decided AND at least one row is approved (the copy drops its unverified
                           clause when all approved)
    F4 decided, not told - every request is decided and NOTHING is approved (d2 copy v2, QA #1788 finding 2): F3 states
                           an approval that may not exist, so an all-rejected user must never receive it. F4 is the ONLY
                           fact allowed when zero rows are approved - refusing the state and leaving the user silent is
                           the D gap the copy exists to close.
    """
    if not state:
        return "", False
    waiting, decided = state.get("waiting", 0), state.get("decided", 0)
    approved, unknown = state.get("approved", 0), state.get("unknown", 0)
    team = state.get("team", 0)
    if unknown:
        # QA #1788 finding 5: a status we cannot read is UNKNOWN, never "decided". No sentence is provably true of it.
        return "", False
    if team:
        # QA #1788 finding 2: a request in OUR queue is never "waiting on one thing from you". With a document on file
        # F2 is exactly true ("we have what you sent, and it is in our review queue"); with nothing on file neither F1
        # nor F2 is true, and a mixed team+user-owed or team+decided state has no single true sentence either - refuse.
        if waiting or decided:
            return "", False
        return ("F2", False) if _all_covered(has_doc, coverage) else ("", False)
    if waiting and decided:
        # A MIX: no single sentence is true of every request the note names (one is still waiting on them, another is
        # decided), so this user is refused. The copy says "they are waiting on one thing from you" - it must not be
        # sent to someone whose other request was already decided.
        return "", False
    if waiting:
        # QA #1788 r10: F2 claims nothing more is needed from them, so it needs EVERY live waiting request covered by
        # a document. A document for only one of two requests is a MIX: F2 is false for the other and F1 is false for
        # the covered one, so no single sentence is true and the user is refused rather than told something untrue.
        if coverage is not None:
            covered, uncovered = coverage
            if covered and uncovered:
                return "", False
            return ("F2", False) if covered else ("F1", False)
        return ("F2", False) if has_doc else ("F1", False)
    if decided:
        # QA #1788 finding 2: F3 REQUIRES at least one approved row; zero approved is F4, never F3.
        return ("F3", decided == approved) if approved else ("F4", False)
    return "", False


def _all_covered(has_doc: bool, coverage: tuple[int, int] | None) -> bool:
    """F2's precondition: a document on file, and - when the per-request coverage is known - one that covers EVERY
    live undecided request (QA #1788 r10)."""
    if coverage is None:
        return bool(has_doc)
    covered, uncovered = coverage
    return bool(covered) and not uncovered


def with_apology(payload: dict[str, Any], fact: str, paid: bool, all_approved: bool) -> dict[str, Any]:
    """Carry the ONE live fact sentence, the paid/free variant and (F3) whether every row was approved. The gate refuses
    a payload without a fact, so this is only ever called with one."""
    return {**payload, "apology": {"fact": fact, "paid": bool(paid), "all_approved": bool(all_approved)}}


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


def asked_ids(path: str | None, campaign: str, listed: set[str], pending: list[dict[str, Any]]) -> set[str]:
    """QA #1625 finding 1: the request ids of this user's rows that a PREVIOUS note already asked about.

    The freshness hold below exists because a request opened after the list was built must not be left out of a
    one-ever note. A still-UVN row that a prior SENT ask already named is not that: it was asked, it is unchanged,
    and it is exactly why the n1 class exists ("over new rows only"). Without this set the prior row (absent from the
    new-row list by construction) held the user as `unlisted_request` on every run and the NEW row never reached the
    gate, which is per-row - the follow-up could never be sent to anyone who had been asked before."""
    ids = sorted({r["request_id"] for r in pending} | set(listed))
    if not path or not ids:
        return set()
    # its own short-lived connection: the send loop's `db` handle is closed by the time it re-plans a user, and a
    # closed handle here would take the whole run down (sqlite3.ProgrammingError) instead of holding one user
    db = verify_ledger.connect(path)
    try:
        return verify_ledger.blocked_ids(db, ids, campaign=campaign)
    finally:
        db.close()


def plan(listed: set[str], pending: list[dict[str, Any]], is_ask: bool,
         asked: set[str] | frozenset[str] = frozenset()) -> tuple[str, list[dict[str, Any]]]:
    """What one user's note may say, from their `listed` request ids and their `pending` replica
    rows: ("", the credits to show) or (a hold reason in HOLDS / "nothing_to_ask", []). Applied when
    the batch is built AND again on a fresh replica read right before the send, so a request opened
    in between holds the user instead of being left out of their one-ever note, and a request blanked
    in between is left out of it."""
    rows = [r for r in pending if not listed or r["request_id"] in listed]
    # A request waiting on them that the list does not carry yet (opened after the list was
    # built) holds the user: their one-ever note must not leave it out.
    if is_ask and listed and any(r["request_id"] not in listed and r["request_id"] not in asked
                                 and r["_no_ask"] not in NO_ASK for r in pending):
        return "unlisted_request", []
    if is_ask:
        askable = [r for r in rows if r["_no_ask"] not in NO_ASK]
        if rows and not askable:
            return "nothing_to_ask", []
        rows = askable
    # A blank or gate-refused request is left out (never shown; it stays pending in core and is
    # reviewed like any other); the rest of the note goes (firstmate 166). Only a user with
    # nothing showable is held.
    if rows and all(r["_incomplete"] for r in rows):
        return "incomplete_fields", []
    rows = [r for r in rows if not r["_incomplete"]]
    return "", [{k: v for k, v in r.items() if not k.startswith("_")} for r in rows]


def left_out(listed: set[str], pending: list[dict[str, Any]], is_ask: bool,
             asked: set[str] | frozenset[str] = frozenset()) -> int:
    """How many of the user's listed `pending` rows plan() leaves out as unshowable (for an ask,
    only the rows it would otherwise ask about)."""
    return sum(1 for r in pending if r["_incomplete"] and r["request_id"] not in asked
               and (not listed or r["request_id"] in listed) and not (is_ask and r["_no_ask"] in NO_ASK))


def run(*, list_path: str | None = None, segment: str, mode: str = "dry-run", max_users: int = 50,
        ledger_path: str | None = None, proof_path: str | None = None, query: Query = trino,
        wrapper: str = verify_notify.WRAPPER, runner: verify_notify.Runner = verify_notify._run,
        now: datetime | None = None, preview_dir: str | None = None, pace_seconds: float = 1.0,
        check_recipients: bool = False, campaign: str = CAMPAIGN, post: verify_notify.Poster = verify_notify.post_cs_priority,
        wording: str = "", from_stage2: bool = False, stage2_path: str | None = None,
        exclude_users: set[str] | frozenset[str] = frozenset(), lens: fraud_lens.LensFn | None = None,
        watchlist_path: str | None = None, holds_path: str | None = None,
        segment_daily_cap: int | None = None, gmail_fallback_o: bool = False,
        no_correction: bool = False, max_entries: int | None = None, start_entry: int = 0,
        inapp_overflow: bool = False) -> UvnReport:
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
            why = _enforce_facts(list_path, users, report, query, ledger_path=ledger_path, holds_path=holds_path)
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
    # [key=apology-fact]: the apology is not an ask, but its F1/F2 split is exactly "is a usable document on file" -
    # so the same read runs for it (a stale or unreadable file refuses the family rather than guess a fact)
    if is_ask or campaign == WAIT_APOLOGY:
        try:
            documented = asks_proof_on_file(proof_path, now=now, ledger_path=ledger_path)
        except verify_notify.ProofFileError as exc:
            report.halted = str(exc)
            return report
    if gmail_fallback_o and not (campaign == CAMPAIGN and is_ask and getattr(documented, "scoped", False)):
        # [key=gmail-o-forward] STOP RULE in code: /o exists only while cs-gmail is stale - a fresh Gmail scan means the
        # real scan runs first and these users get the ordinary ask or receipt (never a double ask)
        report.halted = "--gmail-fallback-o runs only for uvn-status while cs-gmail is stale (Gmail reads fresh: the real scan runs first); nothing sent"
        return report
    want_paid = {"paid": True, "free": False}[segment]
    offered = [u for u in users if u.get("skip") is None and bool(u.get("paid")) is want_paid]
    # p1 599 / QA #1612 / 14:2xZ (eligibility-first): a run walks RAW entries from `start_entry` until it holds
    # `max_entries` CANDIDATES - entries the cheap exclusions below do not already rule out. The page is over
    # candidates, not raw rows: at 14Z the paid list's first 200 raw entries were 176 documents-on-file, 9 already
    # handled and 13 gate-deferred, so the tick messaged nobody and the owed users sat behind a prefix we had ALREADY
    # answered for. The cursor stays a RAW index (report.page.end = the first entry this run did not get to), because a
    # candidate index moves under us whenever a 7-day deferral expires: entries before a candidate cursor would then be
    # skipped until the list wrapped - the same defect this change exists to remove.
    n_listed = len(offered)
    start = max(0, min(int(start_entry or 0), n_listed)) if n_listed else 0
    page_max = None if max_entries is None else max(0, int(max_entries))
    scan_cap = None if page_max is None else page_max * SCAN_FACTOR
    report.listed = n_listed
    day = (now or datetime.now(timezone.utc)).strftime("%Y-%m-%d")
    path = ledger_path or verify_ledger.DEFAULT_PATH
    partial_roles = partial_pending_roles(path) if campaign == CAMPAIGN and not from_stage2 else {}
    partial_ids = frozenset(partial_roles)
    cap = DAILY_MAX if is_ask else STATUS_DAILY_MAX
    db = verify_ledger.connect(path)
    cands: list[dict[str, Any]] = []
    end = start
    try:
        for idx in range(start, n_listed):
            if page_max is not None and len(cands) >= page_max:
                break                                   # the page is full of candidates: stop where we are
            if scan_cap is not None and (idx - start) >= scan_cap:
                break                                   # bounded scan: a wall of exclusions never becomes a crawl
            u = offered[idx]
            end = idx + 1                               # this entry HAS been examined
            if str(u.get("user_id")) in exclude_users:
                report.excluded += 1
                report.note("excluded_today")
                continue
            listed = [str(r) for r in (u.get("request_ids") or [])]
            held_o = is_ask and getattr(documented, "scoped", False) and str(u.get("user_id")) in documented.support_contacts
            if gmail_fallback_o and not held_o:
                report.note("not_in_gmail_held_set")                # [key=gmail-o-forward]: an /o run is the held set ONLY
                continue
            if held_o and not gmail_fallback_o:
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
    # [key=apology-fact] (d2's copy: the fact comes from a LIVE read at send time): one replica read of this page's
    # request states. An unreadable replica HALTS the family - a fact-less apology is never sent.
    states: dict[int, dict[str, Any]] = {}
    if campaign == WAIT_APOLOGY and cands:
        try:
            states = apology_states([int(u["user_id"]) for u in cands], query)
        except Exception as exc:            # noqa: BLE001
            report.halted = f"apology_state_unreadable: {exc}"
            return report
    report.page = {"start": start, "end": end, "listed": n_listed}
    report.not_walked = n_listed - (end - start)
    if campaign == "status-team-review":
        # v1 STOP-CLASS / r5 + p1 [key=k-proof-required]: a status line is for owes-nothing users only. Read core's
        # proof_required for EVERY user the run would message (the candidate page - QA #1612 keeps that read on the page,
        # never the whole list): one proof_required=true (or fresh capture pending) row REFUSES the run (the list was
        # built wrong); an unreadable read refuses too (fail closed)
        from credit_review import comm_state              # lazy: the gate-side owes rule, the same read
        bad: list[str] = []
        for u in cands:
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
    pos = 0
    examined: set[str] = set()       # QA #1612: page entries this run actually got to (the cursor's next start)

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

            end = len(cands)                 # the page was cut from the list entries above
            while pos < end and len(batch) < want:
                chunk = cands[pos:min(end, pos + min(500, max(50, want - len(batch))))]
                accounts = accounts_of([int(u["user_id"]) for u in chunk], query)
                # The fraud lens runs FIRST, before any branch that can close a user's requests in the
                # ledger: a held user is never closed, whatever else is true of them (QA @214ea86).
                verdicts = lens([int(u["user_id"]) for u in chunk])
                picked: list[tuple[dict[str, Any], dict[str, str]]] = []
                for u in chunk:
                    if len(batch) + len(picked) >= want:
                        break
                    pos += 1
                    examined.add(str(u.get("user_id")))
                    v = verdicts.get(int(u["user_id"]))
                    if v is None or v.held:
                        # Never messaged, never closed: re-checked on every run.
                        report.fraud_held += 1
                        report.note("fraud_held")
                        continue
                    if v.ask_only and campaign not in (CAMPAIGN, NEW_ROWS):
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
                    elif campaign == NEW_ROWS:
                        # QA #1625: the n1 follow-up is per ROW (one note per row ever: blocked_ids), so an earlier n1
                        # note never closes the user - the gate's own row-scoped rule (no prior ask / proof received
                        # close; a note within 7 d defers), never uvn_user_done's one-per-user 'already_sent'
                        why = verify_ledger.new_rows_user_done(db, acct["email"], now=now, user_id=str(u["user_id"]))
                        if why == "no_prior_ask":
                            # QA #1625: a DEFERRAL, never a close - the user's first uvn-status ask may still be sent,
                            # and then these rows are exactly the class (the gate leaves this reason unclosed too)
                            report.deferred_users += 1
                            report.note(why)
                            continue
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
                                     with_released=from_stage2, partial_ids=partial_ids) if picked else {})
                for u, acct in picked:
                    uid = int(u["user_id"])
                    # A stage-2 population names only the released requests; the note covers every
                    # request the campaign may ask about (the release is checked on each before the send).
                    listed = set() if from_stage2 else {str(r) for r in (u.get("request_ids") or [])}
                    pending = reqs.get(uid, [])
                    if str(u.get("class") or "") == "PARTIAL":
                        pending = partial_scoped(pending, partial_roles, u.get("request_ids") or [])
                    asked = asked_ids(path, campaign, listed, pending)
                    why, live = plan(listed, pending, is_ask, asked)
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
                    if campaign == WAIT_APOLOGY:
                        _st = states.get(int(uid))
                        fact, aa = apology_fact(_st, str(uid) in documented,
                                                doc_coverage(documented.get(str(uid)),
                                                             (_st or {}).get("undecided_ids") or []))
                        if not fact:
                            report.refused_no_fact += 1
                            report.outcomes.append({"user": str(uid), "result": "refused",
                                                    "reason": "apology_fact_missing: the live request state is not F1, F2, F3 or F4"})
                            report.note("apology_fact_missing")
                            continue
                        payload = with_apology(payload, fact, segment == "paid", aa)
                    if mode != "apply" and with_reply_due({}, u).get("extra"):
                        # QA #1517: the row is classified on the PAYLOAD's own request ids - exactly what the gate's
                        # comm_state receives at send (the raw list row has request_ids, not credits)
                        report.reply_due_rows.append(reply_due_row(uid, {**u, "credits": payload.get("credits") or []}, query=query))
                    batch.append((listed, payload, 0 if as_count else left_out(listed, pending, is_ask, asked)))
        finally:
            db.close()
        return batch

    # One apply run per campaign at a time (QA: two concurrent runs each read the same
    # remaining daily slots and could both send past the cap). The lock is held for the whole
    # send loop, and the remaining cap is re-read from the ledger before every send.
    lock_fh = None
    if mode == "apply" and not POLICY_OK:
        report.halted = f"cap_policy_unreadable: {POLICY_PATH} is missing or malformed; the daily cap cannot be read - nothing sent"
        report.policy_error = True
        return report
    if mode == "apply":
        # QA #1617: the credit campaigns share ONE budget, so they share ONE run lock (two campaigns' applies can never
        # both read the same remaining slots)
        lock_fh = open(group_lock_path(path, campaign), "a+")
        try:
            fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            lock_fh.close()
            report.halted = f"another {campaign} apply run is in progress; nothing sent by this one"
            return report

    def ledger_left() -> int:
        # QA #1370: EMAIL notes only - the caps pace email (captain 2026-10-26 16:05Z). Counting the in-app notes here
        # too is what made --inapp-overflow inert in the deployed configuration (cap == the shared policy number).
        db = verify_ledger.connect(path)
        try:
            group = CREDIT_GROUP if campaign in CREDIT_GROUP else (campaign,)
            return cap - sum(verify_ledger.sent_today(db, campaign=c, day=day, message_type="email") for c in group)
        finally:
            db.close()

    def segment_left() -> int:
        if segment_daily_cap is None:
            return 1 << 60
        # QA #1541: the per-SEGMENT daily policy cap, re-read under this run's lock before every send (atomic with
        # the send) and counted from the runner's own segment record (the list's paid flag at send time - the
        # same source that chose the segment), never from a separate paying export
        return segment_daily_cap - segment_used_today(path, campaign, segment, day)

    def remaining_cap() -> int:
        """What is left of today's bound. With --inapp-overflow the caps pace EMAIL only (captain 2026-10-26 16:05Z:
        "caps may pace email only; the in-app message goes to everyone"), so the run's total is bounded by the in-app
        sanity bound and the segment cap, and by the SHARED credit cap counted over EMAIL notes only.

        QA #1370: counting the in-app notes against the shared cap made the overflow inert in the deployed
        configuration, where the per-campaign `cap` and the shared policy cap are the SAME number (both `DAILY_MAX`):
        the 2,501st user was deferred in `email_left()`'s shadow, before `--channel inapp` was ever chosen, and
        INAPP_DAILY_MAX (5,000) was unreachable. Pacing is about how much EMAIL we send a day; the in-app note is the
        channel that exists for the users email could not reach, and it is bounded on its own (INAPP_DAILY_MAX minus
        what this campaign already sent today) plus the segment cap."""
        if not inapp_overflow:
            return min(ledger_left(), segment_left())
        # Overflow: the caps pace EMAIL only (`email_left()` below enforces the per-campaign one; `ledger_left()` the
        # shared one, both over EMAIL notes), so neither may bound this run's total. What bounds it is the in-app sanity
        # bound minus what this campaign already sent today, plus the segment cap.
        db = verify_ledger.connect(path)
        try:
            return min(INAPP_DAILY_MAX - verify_ledger.sent_today(db, campaign=campaign, day=day), segment_left())
        finally:
            db.close()

    def email_left() -> int:
        """EMAIL notes left today: what decides the channel switch (the cap paces email only)."""
        db = verify_ledger.connect(path)
        try:
            return min(cap - verify_ledger.sent_today(db, campaign=campaign, day=day, message_type="email"),
                       ledger_left(), segment_left())
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

    # [key=uvn-daily-cap-400] (C p10: 5 of 53 sent, rc 0): a SIGNED apply goes whole or not at all - when what is left of
    # today's cap cannot take every signed user of this list, it refuses BEFORE the first send (daily_cap_short; the
    # CLI exits 3). The tick pages by design (--page) and is not refused here.
    if mode == "apply" and verify_notify.APPLY_ONLY is not None and not verify_notify.APPLY_PAGE:
        n_signed = sum(1 for u in cands if str(u.get("user_id")) in verify_notify.APPLY_ONLY)
        left_now = remaining_cap()
        if left_now < n_signed:
            report.cap_short = True
            report.halted = (f"daily_cap_short: {left_now} left of today's {campaign} cap, {n_signed} signed users in this "
                             "list - a signed list goes whole or not at all; nothing sent")
            for u in cands:
                if str(u.get("user_id")) in verify_notify.APPLY_ONLY:
                    report.outcomes.append({"user": str(u.get("user_id")), "result": "deferred", "reason": "daily_cap_short"})
            if lock_fh is not None:
                fcntl.flock(lock_fh.fileno(), fcntl.LOCK_UN)
                lock_fh.close()
            return report
    budget_stop = False
    try:
        while (want := room()[0]) > 0 and not budget_stop:
            batch = next_batch(want)
            if not batch:
                break
            if mode != "apply":
                # r5 598 / p1 599: a DRY run (check, preview, validate) sends nothing and re-plans nothing per user, so
                # the batch's gate calls run on #1596's parallel check workers; the results are read per user in LIST
                # order, and the batch is sized to what is left of the run (room), so the accepted set is the list-order
                # prefix the apply would send (next_batch already sized it to room())
                take = batch
                outs: dict[str, str] = {}

                def seen(argv: list[str], _run=runner) -> Any:
                    try:
                        user_ = json.load(open(argv[argv.index("--credits-file") + 1], encoding="utf-8"))["user"]
                    except (OSError, ValueError, KeyError, IndexError, TypeError):
                        user_ = {}
                    uid_ = str((user_ or {}).get("id") or "")
                    try:
                        res = _run(argv)
                    except verify_notify.NoteTimeout as exc:
                        # Defect A (Fable driver 02:55Z, inbox 001): this is where the tick DIED at 22:28Z, 00:19Z and
                        # 02:30Z - one read-only gate call over READ_TIMEOUT_S raised out of `seen`, through send_all's
                        # parallel pre-gate, and the whole batch got nothing. This worker only returns the synthetic
                        # result; _send_loop records the user UNMEASURED (reason gate_timeout) and counts them on the
                        # main thread, so the counter, the outcome file and the bar agree. outs[] gets NO entry (so the
                        # tick never reads them as a pass and never as a refusal), and the batch continues. The run
                        # stops only at verify_notify.unmeasured_stop_after(batch) = max(5, 10% of the batch), which
                        # _send_loop enforces on this synthetic result. READ_TIMEOUT_S is NOT raised.
                        return verify_notify.unmeasured_result(argv, str(exc))
                    if res.returncode == 0 and verify_notify._first_line(res.stdout).startswith(("RECIPIENT OK", "VALID ", "DRY-RUN ")):
                        outs[uid_] = "ok"
                    return res
                verify_notify.send_all([p for _, p, _ in take], report, mode=mode, wrapper=wrapper, runner=seen,
                                       extra=["--campaign", campaign] + (["--copy", wording] if wording else [])
                                       + (["--gmail-fallback-o"] if gmail_fallback_o else [])
                                       + (["--no-correction"] if no_correction else []),
                                       pace_seconds=0, preview_dir=preview_dir,
                                       check_recipients=check_recipients)
                calls += len(take)
                for _, p, dropped in take:
                    if outs.get(str(p["user"].get("id") or "")) == "ok":
                        report.users += 1
                        counted += 1
                        if dropped:
                            report.rows_held += dropped
                            report.note("rows_left_out")
                if report.halted or report.stopped_on_unmeasured:   # Defect A: the bar is a loud stop, not a next batch
                    break
                continue
            for i, (listed, p, dropped) in enumerate(batch):
                if verify_notify.not_signed(mode, p["user"]["id"]):
                    # QA #1611: a signed apply never spends a slot, a re-plan or a gate call on an unsigned user
                    report.outcomes.append({"user": str(p["user"]["id"]), "result": "filtered",
                                            "reason": "not_in_signed_accepted"})
                    continue
                allowed, left = room()
                if allowed <= 0:
                    report.over_daily_max += len(batch) - i
                    # r5 [key=cap-stop-p10] (3): every user a cap stop leaves is an outcome row, so the run balances
                    why = "daily_cap" if left <= 0 else "run_size"
                    report.outcomes += [{"user": str(b[1]["user"]["id"]), "result": "deferred", "reason": why}
                                        for b in batch[i:]]
                    examined.difference_update(str(b[1]["user"]["id"]) for b in batch[i:])   # not got to
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
                        held_o = getattr(documented, "scoped", False) and str(uid) in documented.support_contacts
                        if gmail_fallback_o and not held_o:
                            # [key=gmail-o-forward]: left the held set (or Gmail read fresh) since the batch read - no /o
                            report.note("not_in_gmail_held_set")
                            continue
                        if held_o and not gmail_fallback_o:
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
                    fresh = pending_rows([uid], campaign, mine, query, with_released=from_stage2,
                                         partial_ids=partial_ids).get(uid, [])
                    if str(u.get("class") or "") == "PARTIAL":
                        # Re-read the split for THIS user's listed requests right before the send.
                        # `partial_roles` is a run-start snapshot: a request the decider moved off
                        # `approve_partial` (or whose pending roles changed) while earlier users
                        # were being messaged must not be asked about with the stale role text
                        # (QA 2026-11-11, hydra#1851).
                        owed_now = partial_pending_roles(path, request_ids=u.get("request_ids") or [])
                        fresh = partial_scoped(fresh, owed_now, u.get("request_ids") or [])
                    asked = asked_ids(path, campaign, listed, fresh)
                    why, live = plan(listed, fresh, is_ask, asked)
                    why, live, as_count, total = count_copy_of(campaign, listed, fresh, why, live)
                    if why in HOLDS:
                        held(why)
                        continue
                    dropped = 0 if as_count else left_out(listed, fresh, is_ask, asked)
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
                    # r8 (firstmate 771) (3): a user whose own read failed on a previous tick is HELD - the walk does not
                    # walk into the same unreadable read again until the hold expires (READ_RETRY_H inside the cadence).
                    hold_ukey = str(p["user"].get("email") or "").strip().lower()
                    hold_until = read_hold_until(path, campaign, hold_ukey, now=now) if mode == "apply" else ""
                    if hold_until:
                        report.deferred_users += 1
                        report.outcomes.append({"user": str(uid), "result": "deferred",
                                                "reason": f"read_failed_hold until {hold_until}"})
                        report.deferrals.append(f"user {uid}: read failed on an earlier tick; retry after {hold_until}")
                        continue
                    acct = {k: p["user"].get(k, "") for k in ("email", "professional_id", "auth_id", "first_name")}
                    # rebuilt from a fresh replica read: the answer's gate args (reply_due) carry over (QA #1509)
                    p = with_reply_due(with_filing(note_payload(acct, uid, live, as_count, total, created_of(fresh, live)),
                                                   p["user"]), {"reply_due": reply_due_of(p)})
                    if campaign == WAIT_APOLOGY:
                        # d2's copy: the fact comes from the LIVE read, and a state outside F1/F2/F3/F4 refuses THIS
                        # user (a named deferral, never a default sentence and never a failure of the family).
                        # QA #1788 finding 6: the APPLY re-derives the fact from a FRESH send-time read of this one
                        # user, never from the page-level `states` snapshot taken before the walk. A request that flips
                        # waiting -> approved between the snapshot and this send would otherwise still get F1 ("waiting
                        # on one thing from you") for a credit that was just decided. The read is per user and happens
                        # immediately before the gate call, so the sentence describes the state at send time.
                        try:
                            send_state = apology_states([int(uid)], query).get(int(uid))
                        except Exception as exc:  # noqa: BLE001 - an unreadable read is a refusal for THIS user
                            report.refused_no_fact += 1
                            report.outcomes.append({"user": str(uid), "result": "refused",
                                                    "reason": f"apology_state_unreadable: {str(exc)[:160]}"})
                            report.note("apology_fact_missing")
                            continue
                        # QA #1788 finding 1 (carried three times): the DOCUMENT half of the fact was still the
                        # page-level snapshot taken before the walk, so a document that arrived (or was removed) while
                        # earlier users were being messaged could still produce F1 for a user whose document is now on
                        # file. Re-read it here, beside the state read, so both halves of the sentence describe the
                        # same instant. Unreadable = the family stops, exactly as the batch read does.
                        try:
                            send_docs = asks_proof_on_file(proof_path, now=now, ledger_path=ledger_path)
                        except verify_notify.ProofFileError as exc:
                            report.halted = str(exc)
                            break
                        # QA #1788 r10: coverage is per LIVE waiting request, not "the user appears somewhere in the
                        # export" - a document for one of two requests must never produce F2 for both.
                        fact, aa = apology_fact(send_state, str(uid) in send_docs,
                                                doc_coverage(send_docs.get(str(uid)),
                                                             (send_state or {}).get("undecided_ids") or []))
                        if not fact:
                            report.refused_no_fact += 1
                            report.outcomes.append({"user": str(uid), "result": "refused",
                                                    "reason": "apology_fact_missing: the live request state is not F1, F2, F3 or F4"})
                            report.note("apology_fact_missing")
                            continue
                        p = with_apology(p, fact, segment == "paid", aa)
                    if calls and pace_seconds:
                        time.sleep(pace_seconds)
                before = report.sent_notes if mode == "apply" else report.validated + report.recipient_ok
                before_budget = report.budget_deferred_users
                l0 = ledger_left() if mode == "apply" else 0
                # QA #1780 (Important): the read-failure streak resets on a VERIFIED SUCCESSFUL READ, not only on a
                # send. A user who read fine and was then refused or deferred has not failed to read, so leaving the
                # prior failures in the ledger makes the next failed read page a human for NONCONSECUTIVE failures.
                # The read failed for THIS user iff send_all recorded a per-user read hold for them.
                fh0 = len(report.failed_held)
                verify_notify.send_all([p], report, mode=mode, wrapper=wrapper, runner=runner,
                                       extra=["--campaign", campaign] + (["--copy", wording] if wording else [])
                                       + (["--gmail-fallback-o"] if gmail_fallback_o else [])
                                       + (["--no-correction"] if no_correction else [])
                                       + (["--channel", "inapp"] if inapp_overflow and email_left() <= 0 else []),
                                       pace_seconds=0, preview_dir=preview_dir,
                                       check_recipients=check_recipients and mode != "apply",
                                       # r5 (firstmate 770) (3): the POPULATION this walk covers, so a systemic stop is
                                       # measured against the family it stopped, not against one payload.
                                       walked=len(cands))
                calls += 1
                reached = (report.sent_notes if mode == "apply" else report.validated + report.recipient_ok) - before
                report.users += reached
                counted += reached
                read_failed = any(str(e.get("user")) == str(uid) for e in report.failed_held[fh0:])
                if mode == "apply" and not read_failed:
                    # r8 (firstmate 771) (4): the read worked this time - the consecutive counter starts over.
                    # QA #1780 (Important): APPLY ONLY. A dry run is a read, so it must never open a writable ledger
                    # to DELETE failure history - a preview after two failed ticks used to reset the streak silently.
                    clear_read_hold(path, campaign, hold_ukey)
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
                if report.stopped_on_failures or report.stopped_on_unmeasured:
                    # r5 (firstmate 770) (3): the systemic stop is the ROUND's, and this loop is the round. Without this
                    # the probe walked 8 of 8 after stopping at 3: send_all() returned, the walk carried on, and the stop
                    # only coloured the exit code.
                    break
                if report.budget_deferred_users > before_budget:
                    # [key=note-step-budget] (QA #1756 Important): the run's share ended AT THIS user - the send loop
                    # refuses to START one whose worst case (the whole retry budget) would not fit and records them
                    # `deferred / apply_budget`. This user IS in `examined` (picked before the send), so the page clamp
                    # at the end of this function would step PAST them: they - and every user after them in the batch -
                    # would wait a whole ROTATION of the list instead of the next tick. Mirror the cap stop exactly:
                    # an outcome row each, drop them from `examined` (which is what moves page.end), and stop.
                    report.outcomes += [{"user": str(b[1]["user"]["id"]), "result": "deferred",
                                         "reason": "apply_budget: the tick's apply share ended before this user; "
                                                   "never started, stays owed for the next tick"}
                                        for b in batch[i + 1:]]
                    examined.difference_update(str(b[1]["user"]["id"]) for b in batch[i:])
                    budget_stop = True
                    break
            if report.halted or report.stopped_on_failures or report.stopped_on_unmeasured or budget_stop:
                break
    finally:
        if lock_fh is not None:
            fcntl.flock(lock_fh.fileno(), fcntl.LOCK_UN)
            lock_fh.close()
    report.over_daily_max += len(cands) - pos
    if pos < len(cands) and not report.halted:
        # r5 [key=cap-stop-p10] (3): the users the run never reached because the cap (or the run size) stopped it
        why = "daily_cap" if (mode == "apply" and remaining_cap() <= 0) else "run_size"
        report.outcomes += [{"user": str(u.get("user_id")), "result": "deferred", "reason": why} for u in cands[pos:]]
    # QA #1612: page.end = the first page entry this run did NOT get to (the cap or the room stopped it there), so the
    # next run starts exactly there; page_end = where the page itself ends
    in_cands = {id(u) for u in cands}
    # the window this run scanned (start..end in RAW list coordinates): first_open is an offset WITHIN it
    window = offered[report.page.get("start", 0):report.page.get("end", 0)]
    first_open = next((j for j, u in enumerate(window) if id(u) in in_cands and str(u.get("user_id")) not in examined),
                      None)
    report.page["page_end"] = report.page.get("end", 0)
    if first_open is not None:
        report.page["end"] = report.page["start"] + first_open
    # QA #1662 (finding 1): the candidate page is REBUILT for the apply, so if eligibility drifts between the check and
    # the apply (a document lands, a 24h exclusion starts, a row gets handled) the apply's candidate window grows into
    # raw entries the CHECK never examined. `--signed-accepted` keeps those users out of the send, but the cursor moves
    # from "the first entry this run did not get to" - so without a clamp it would step PAST users who were neither
    # checked nor signed, and they would wait a whole rotation. A paged apply may only claim what the check examined.
    _cap_end = getattr(verify_notify, "APPLY_RAW_END", None)
    if mode == "apply" and isinstance(_cap_end, int) and report.page.get("end", 0) > _cap_end:
        report.page["end"] = _cap_end
        report.not_walked = n_listed - (report.page["end"] - report.page["start"])
    # r5 / firstmate 764, amended by Fable 2026-11-05 00:1xZ (firstmate 769): a user whose own send-time read
    # failed is recorded here, once, at the end of the walk - a hold that expires at the NEXT TICK (2 h), never the
    # 7-day refusal window, because an unreadable read is not the user refusing anything and a week-long suppression
    # over one bad query is the starvation #1780 exists to end. Three consecutive failed reads page a human.
    # APPLY ONLY (Fable 769): a dry run is a read, so it never writes a hold row. Empty unless something failed, so
    # it costs nothing on a clean run. Best effort: hold_failed_users reports a record it could not write
    # (flag_failures) and never loses the report.
    # Fable 2026-11-05 00:1xZ (firstmate 769): recording a failure is a WRITE, so a dry run never does it.
    if mode == "apply" and report.failed_held:
        # A FRESH connection: the walk's ledger handle is closed by the time the walk ends, and a record that
        # silently fails on a closed database is a hold that exists only in the report (found by the 769 test).
        # Fable r5 2026-11-06 00:53Z: ONE implementation (verify_notify.finish_failed_reads) for every runner that
        # calls send_all - this lane, verify-live and retro-past - so the three cannot drift apart again.
        hold_db = verify_ledger.connect(path)
        try:
            verify_notify.finish_failed_reads(hold_db, report, campaign, mode=mode, now=now)
        finally:
            hold_db.close()
    if mode == "apply" and campaign in verify_ledger.RECHECKABLE_REFUSALS:
        verify_notify.flag_refusals(report, ledger_path=path, campaigns=[campaign], post=post, now=now)
    return report


# r8 (firstmate 771) (3)/(4): the hold's read and clear sides live in verify_notify beside the writer, so every lane
# that calls send_all shares ONE implementation (Fable r5 2026-11-06 00:53Z). Re-exported here for this module's callers.
read_hold_until = verify_notify.read_hold_until
clear_read_hold = verify_notify.clear_read_hold


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
    for label, n in (("list entries outside this run's --max-entries page (other runs')", report.not_walked),
                     ("documents on file (not asked)", report.proof_on_file),
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
                     ("refused: the live request state is not one of the three the approved copy can name "
                      "(F1 waiting on them / F2 in review / F3 decided) - no message beats a wrong one",
                      report.refused_no_fact),
                     ("left for the next run (daily cap / run size)", report.over_daily_max)):
        if n:
            parts.append(f"{n} {label}")
    if report.facts_stale_min is not None:
        # [key=facts-stale-fallback]: the literal the tick's log and the operator look for
        parts.append(f"facts stale {report.facts_stale_min}m (the replica re-read timed out; the list's own facts were "
                     f"used, bar {FACTS_STALE_MAX_MIN}m)")
    if report.deferrals:
        parts.append(f"{len(report.deferrals)} deferred by the gate at send: " + "; ".join(report.deferrals[:20]))
    if report.refused_users:
        parts.append(f"{report.refused_users} refused by the gate: " + "; ".join(report.refusals[:3]))
    if report.refused_recheck:
        parts.append(f"{report.refused_recheck} refused, re-check after {report.recheck_after}")
    if report.flagged:
        parts.append(f"{report.flagged} refused {verify_ledger.MAX_REFUSALS} times, flagged to #cs_priority for a human")
    if report.post_failed:
        # r5 (firstmate 770) (1): a failed POST is an UNKNOWN outcome - the message may already be delivered, so it is
        # left claimed and never re-sent automatically. It is never rendered as a held read.
        parts.append(f"{report.post_failed} send(s) FAILED at the POST (unknown outcome: may already be delivered; left "
                     "claimed and never re-sent automatically): "
                     + "; ".join(f"user {h['user']}: {h['reason'][:120]}" for h in report.post_failures[:3]))
    if report.flag_failures:
        parts.append("FLAG FAILED: " + "; ".join(report.flag_failures[:3]))
    if report.outcome_unknown:
        parts.append(f"{report.outcome_unknown} post(s) not verified (outcome unknown: may have been delivered, "
                     "left claimed and never re-sent automatically; counted toward the run size and daily cap)")
    if report.failed_held:
        # r5 / firstmate 764: the word a replay greps stays FAILED, but the OUTCOME is a hold - the user was not messaged,
        # was not closed, and the rest of the round went on. A systemic stop says so in the same sentence.
        #
        # QA #1780 (Important, 02:12Z): this sentence is keyed off `failed_held`, NOT `failed_users`. `failed_users`
        # also counts an unknown POST, whose note may ALREADY be delivered - rendering that as "held, not messaged"
        # told the operator the opposite of the actual delivery state. The POST case has its own sentence above.
        parts.append(f"FAILED {len(report.failed_held)} (held, not messaged, not retried this run"
                     + (f"; SYSTEMIC at {report.stopped_on_failures}: the run stopped"
                        if report.stopped_on_failures else "")
                     + "): " + "; ".join(report.failures[:3]))
    if report.unmeasured_users:
        # Defect A: the UNMEASURED count and its bar are printed in the summary the tick logs (tick.log), never only in
        # the outcome file - and a stop at the bar says so in the same sentence.
        parts.append(f"UNMEASURED {report.unmeasured_users} (gate_timeout / gate error: outcome unknown, never a refusal, "
                     f"never a pass; stop bar {report.unmeasured_stop_at} = max({verify_notify.UNMEASURED_STOP_MIN}, "
                     f"{int(verify_notify.UNMEASURED_STOP_SHARE * 100)}% of the batch))"
                     + (f"; {report.stopped_on_unmeasured}" if report.stopped_on_unmeasured else ""))
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
        due = gh[0].get("due_at")
        who = gh[0].get("waiting_on") or GMAIL_HOLD_WAITING_ON    # the row's own owner, never a second opinion
        parts.append(f"held by the Gmail outage: {paid} paid / {len(gh) - paid} free (waiting on {who}, "
                     f"due {due or 'unknown (policy holds.gmail unreadable)'}; listed in the outcomes)")
    return ". ".join(parts) + "."
