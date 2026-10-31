"""claim-proof-ask (steers-1830 #5, firstmate 125/126): the dated code ask to claimants of pending
profile claims in bands B/C, and its one day-7 reminder, through Caroline's gate
(scripts/intercom-verify-request.sh --campaign claim-proof-ask; send-locked there until Fable's
copy approval and firstmate's GO).

Input: claim-flow-fix-fable-c1's list (ids and server facts only, at most LIST_MAX_AGE_H old):
  {"generated_at": ..., "daily_check": {"owner": "...", "last_run_at": "<iso>"},
   "claims": [{"claim_id", "user_id", "profile_id", "paid", "band", "profile_name", "profile_url", "code",
               "platform", "code_found" (bool)}]}
  profile_id is required (the send log carries it): a claim without a well-formed one is held.
The close day is always the send day + verify_ledger.CLAIM_WINDOW_DAYS; the reminder repeats it.

Send log for the daily code check (claim-flow-fix-fable-c1 reads it): after every apply run the
driver rewrites ASKED_EXPORT (JSON lines, a full snapshot from the ledger, atomic replace): one
{id, profileId, userId, askedAt, dateClose} per claim whose note was sent (askedAt: when the
note was claimed and sent, never moved by later ledger updates).

Rules, all re-checked here at send time:
  - firstmate 126: nothing is sent unless the list names the daily code check (daily_check.owner)
    and it ran in the last DAILY_CHECK_MAX_AGE_H hours; "we check for it every day" must be true.
  - only bands B and C; never a claim whose code was already found;
  - only a platform the daily check can read (READABLE: Spotify artist bio, website, YouTube
    About; c1 2026-10-22): never Instagram, X or TikTok;
  - the claim is still `pending` on the core replica and belongs to the listed user (any other
    state, a deleted claim or another owner: not sent);
  - users who emailed support@ in the last 90 days are held for a human (proof-on-file feed;
    unreadable feed = nothing sent);
  - one claim per user per run (the gate also caps one message per user per UTC day);
  - paid first, then oldest claim id; at most CLAIM_DAILY_MAX messages a day (first notes and
    reminders together).
Reminders (--reminders): every sent note whose day-7 reminder is due; the claim must still be
pending, still in band B/C on today's list and not routed to the status note (audience "status"), its code not found and the claim still on today's list (for the server facts) in
this run's segment, otherwise the reminder is closed in the ledger (never sent). A claimant who
replied to the note is never reminded: the reminder is closed (claimant replied).
A claim whose key already has a note in the ledger (attempted, sent, refused or skipped) is
dropped before the run's budget is spent, so repeated runs keep reaching new claims. The gate applies the same
recipient checks as to the first note, the 7-day human-reply deferral included.

claim-status (run_status; Fable claims-documentation-readiness-1023 ruling 3): the no-ask status note
"it is with our team for review" to every listed pending claim that gets NO proof ask: a row whose
`audience` is "status", or (no audience given) whose band is not B/C or whose platform the daily check
cannot read. Never a band-A claim without an explicit audience (it is on the approval path), never a
claim whose code was found. One note per claim ever (the gate's ledger), never to a claim that has a
proof ask, never within 7 days of another note to the user (verify_ledger.claim_cross_check). The same
replica, support@ and account checks as the ask; paid first, one claim per user per run, at most
CLAIM_STATUS_DAILY_MAX a day. The list must be fresh; the daily code check is not required (the
note promises no code check). A row with audience "status" is never sent the proof ask."""

from __future__ import annotations

import json
import os
import re
import sqlite3
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any

from . import proof_parts, verify_ledger, verify_notify
from .uvn_status import Query, accounts_of, trino

CAMPAIGN = verify_ledger.CLAIM_CAMPAIGN
BANDS = ("B", "C")
LIST_MAX_AGE_H = 30
# Fable p1 [key=claims-scoped-pof] (10-31 07:14Z) + r5 co-sign bound (07:20Z): while ONLY the cs-gmail part is
# unusable, the claim notes run on fresh core + cs-intercom and hold every claimant the stale part could vouch for. The
# LAST GOOD Gmail scan (the cs-gmail part and its support@ contact snapshot) must be <= 24 h old; past that EVERY
# claimant is held as stale_source:cs-gmail (listed in the outcomes), because a list days old is not "fresh".
SCOPED_GMAIL_MAX_AGE_H = 24.0


class AllUsers(frozenset):
    """Every user is held (the last good Gmail scan is too old to vouch for anyone)."""
    def __contains__(self, item: object) -> bool:
        return True
STALE_GMAIL_REASON = "stale_source:cs-gmail"
PROOF_STORE = os.environ.get("COMM_STATE_PROOF_STORE", "/var/lib/hydra-credit-verify/proof.sqlite")
DAILY_CHECK_MAX_AGE_H = 30
CLAIM_DAILY_MAX = 150
CLAIM_STATUS_DAILY_MAX = 400
STATUS_CAMPAIGN = verify_ledger.CLAIM_STATUS_CAMPAIGN
CLAIM_KEY = re.compile(r"^claim-([0-9]{1,19})$")
READABLE = ("spotify", "website", "youtube")
PROFILE_ID = re.compile(r"^[A-Za-z0-9-]{1,64}$")
ASKED_EXPORT = os.environ.get("CLAIM_PROOF_ASKED_EXPORT", "/var/lib/hydra/credit-review/claim-proof-asked.jsonl")


@dataclass
class ClaimReport(verify_notify.Report):
    listed: int = 0
    stale_source_hold: int = 0        # scoped mode: held because cs-gmail is stale and could vouch for this claimant
    not_band: int = 0
    code_found: int = 0
    not_pending: int = 0
    no_email: int = 0
    support_hold: int = 0
    second_claim: int = 0
    already_asked: int = 0
    over_daily_max: int = 0
    closed_reminders: int = 0
    not_in_list: int = 0
    no_readable_surface: int = 0
    no_profile_id: int = 0
    status_audience: int = 0          # ask run: rows the list routes to the status note instead
    ask_audience: int = 0             # status run: rows that get the proof ask instead
    by_reason: dict[str, int] = field(default_factory=dict)


def load_list(path: str, *, now: datetime | None = None, require_daily_check: bool = True) -> tuple[list[dict[str, Any]], str]:
    """(claims, why-not): why-not is non-empty when the list is unusable or the daily code check
    is not named or has not run recently (firstmate 126: then nothing is sent)."""
    from .evidence import parse_ts
    now = now or datetime.now(timezone.utc)
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        return [], f"the claim list {path} is unreadable ({type(exc).__name__})"
    gen = parse_ts(doc.get("generated_at")) if isinstance(doc, dict) else None
    claims = doc.get("claims") if isinstance(doc, dict) else None
    if gen is None or not isinstance(claims, list):
        return [], "the claim list has no generated_at or claims[]"
    age_h = (now - gen).total_seconds() / 3600
    if age_h > LIST_MAX_AGE_H or age_h < -0.1:
        return [], f"the claim list is {age_h:.1f}h old (limit {LIST_MAX_AGE_H}h)"
    if not require_daily_check:
        return claims, ""
    chk = doc.get("daily_check") if isinstance(doc.get("daily_check"), dict) else {}
    ran = parse_ts(chk.get("last_run_at"))
    if not str(chk.get("owner") or "").strip() or ran is None:
        return [], "the list names no daily code check (daily_check.owner + last_run_at): 'we check every day' would be untrue"
    chk_age = (now - ran).total_seconds() / 3600
    if chk_age > DAILY_CHECK_MAX_AGE_H or chk_age < -0.1:
        return [], f"the daily code check last ran {chk_age:.1f}h ago (limit {DAILY_CHECK_MAX_AGE_H}h)"
    return claims, ""


def claim_states(claim_ids: list[int], query: Query = trino) -> dict[int, tuple[str, int]]:
    """claim id -> (status, user id) for live (not deleted) claims, from the core replica."""
    out: dict[int, tuple[str, int]] = {}
    for i in range(0, len(claim_ids), 500):
        chunk = ",".join(str(int(c)) for c in claim_ids[i:i + 500])
        for cid, status, uid in query(
                "SELECT CAST(id AS varchar), status, CAST(userid AS varchar) FROM postgresql_core.public.claiming "
                f"WHERE deletedat IS NULL AND id IN ({chunk})"):
            out[int(cid)] = (str(status or ""), int(uid) if str(uid or "").isdigit() else -1)
    return out


_TAG = re.compile(r"<[^<>]{0,200}>")
_HEART = re.compile(r"</?3+")


def display_name(value: Any) -> str:
    """The profile name as interpolated into a note: tags and '<3' / '</3' emoticons removed, any remaining angle
    bracket dropped, whitespace collapsed (firstmate 103: 'lauriam<3' was refused G5 as markup). A link or an address
    in the name is NOT rewritten here: the gate's G5 still refuses it."""
    text = _HEART.sub("", _TAG.sub("", str(value or "")))
    return " ".join(text.replace("<", "").replace(">", "").split())


def _facts(c: dict[str, Any]) -> dict[str, str]:
    out = {k: str(c.get(k) or "").strip() for k in ("profile_url", "code", "platform")}
    out["profile_name"] = display_name(c.get("profile_name"))
    return {k: out[k] for k in ("profile_name", "profile_url", "code", "platform")}


def _profile_id(c: dict[str, Any]) -> str:
    pid = str(c.get("profile_id") or "").strip()
    return pid if PROFILE_ID.match(pid) else ""


def _payload(c: dict[str, Any], acct: dict[str, str], extra: list[str] | None = None) -> dict[str, Any]:
    return {"user": {"email": acct["email"], "id": str(int(c["user_id"])), "first_name": acct["first_name"],
                     "professional_id": acct["professional_id"], "auth_id": acct["auth_id"]},
            "credits": [{"request_id": f"claim-{int(c['claim_id'])}", "profile_id": _profile_id(c)}],
            "claim": _facts(c),
            **({"extra": extra} if extra else {})}


@dataclass(frozen=True)
class ClaimHolds:
    """Who a claim note never goes to. ``scoped`` = the cs-gmail part is stale and every held user is held for
    that reason (``stale_source:cs-gmail``, listed in the outcomes)."""
    held: frozenset[str]
    scoped: bool = False


def _gmail_filers(proof_store: str) -> set[str]:
    """Users with a document filed from support@ (proof_intake source='email'). Unreadable = refuse all."""
    try:
        db = sqlite3.connect(f"file:{proof_store}?mode=ro", uri=True)
        try:
            return {str(int(u)) for (u,) in db.execute("SELECT DISTINCT user_id FROM proof_intake WHERE source='email'")}
        finally:
            db.close()
    except (sqlite3.Error, ValueError, TypeError) as exc:
        raise verify_notify.ProofFileError(f"scoped check: proof_intake {proof_store} unreadable ({exc})") from exc


def _ledger_support_refs(ledger_path: str) -> set[str]:
    """Users with a ledger note whose reason or gate log references a support@ filing. Unreadable = refuse all."""
    try:
        db = sqlite3.connect(f"file:{ledger_path}?mode=ro", uri=True)
        try:
            rows = db.execute("SELECT DISTINCT account_id FROM verify_messages WHERE account_id IS NOT NULL AND "
                              "(lower(coalesce(reason,'')) LIKE '%support@%' OR lower(coalesce(api_log,'')) LIKE '%support@%')")
            return {str(int(u)) for (u,) in rows if str(u).strip().isdigit()}
        finally:
            db.close()
    except (sqlite3.Error, ValueError, TypeError) as exc:
        raise verify_notify.ProofFileError(f"scoped check: ledger {ledger_path} unreadable ({exc})") from exc


def _frozen_contacts(doc: dict[str, Any], *, now: datetime, skew: float) -> set[str] | None:
    """The support@ contact snapshot as last read: its user ids, or None when it is absent, has no readable stamp, is
    dated in the future, or holds a malformed id (then nobody can be admitted: refuse all)."""
    snap = doc.get(proof_parts.SUPPORT_CONTACTS)
    if not isinstance(snap, dict):
        return None
    ts = proof_parts.parse_ts(snap.get("generated_at"))
    ids = snap.get("user_ids")
    if ts is None or (now - ts).total_seconds() / 3600 < -skew or not isinstance(ids, list):
        return None
    out = set()
    for u in ids:
        text = "" if isinstance(u, bool) else str(u).strip()
        if not text.isdigit():
            return None
        out.add(str(int(text)))
    return out


def claim_holds(path: str | None = None, *, now: datetime | None = None, proof_store: str | None = None,
                ledger_path: str | None = None) -> ClaimHolds:
    """The proof-on-file read for the CLAIM notes. Every part usable -> the full check (verify_notify, unchanged).
    Fable [key=claims-scoped-pof]: when the ONLY unusable part is cs-gmail, admit on fresh core + cs-intercom and hold
    every claimant cs-gmail could vouch for: anyone on the last support@ contact snapshot (90 days, a superset of the
    rule's 14), anyone with a proof_intake row filed from email, anyone with a ledger note referencing a support@
    filing, anyone with a gmail-sourced proof entry in the export itself (400-day scan). Anything else unusable (core, cs-intercom, another flagged part, a half-written export, a cs-gmail part or
    snapshot that is absent or malformed) raises ProofFileError: refuse all. [key=gmail-held-fallback] (3): the hold is the
    did-vouch set FROZEN on the last good scan, whatever its age - never every claimant (the old 24 h AllUsers bound)."""
    now = now or datetime.now(timezone.utc)
    try:
        return ClaimHolds(frozenset(str(u) for u in verify_notify.load_proof_on_file(path, now=now).support_contacts))
    except verify_notify.ProofFileError as full:
        first = full
    path = path or verify_notify.PROOF_ON_FILE
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, json.JSONDecodeError):
        raise first from None
    if not isinstance(doc, dict):
        raise first
    lim, skew = verify_notify.PROOF_MAX_AGE_H, verify_notify.PROOF_MAX_SKEW_H
    gen = proof_parts.parse_ts(doc.get("generated_at"))
    if gen is None or not -skew <= (now - gen).total_seconds() / 3600 <= lim:
        raise first
    sources = doc.get("sources") if isinstance(doc.get("sources"), list) else []
    named = [x for x in sources if isinstance(x, dict)]
    for label, match in proof_parts.REQUIRED:
        found = [x for x in named if match(str(x.get("name") or ""))]
        if len(found) != 1:
            raise first
        if label == proof_parts.GMAIL:
            # QA #1568 round 3: scoped mode exists ONLY for an unusable cs-gmail PART. A usable part with some other
            # problem (e.g. its contact snapshot alone is stale) keeps the full check's refusal.
            if proof_parts.part_problem(found[0], label, now=now, max_age_h=lim, max_skew_h=skew) is None:
                raise first
            # the stale part: missing or with no readable stamp = refuse all; too old = hold everyone (below)
            gmail_ts = proof_parts.parse_ts(found[0].get("generated_at"))
            if found[0].get("missing") or gmail_ts is None or (now - gmail_ts).total_seconds() / 3600 < -skew:
                raise verify_notify.ProofFileError("scoped check refused: cs-gmail is missing or has no readable stamp")
        elif proof_parts.part_problem(found[0], label, now=now, max_age_h=lim, max_skew_h=skew):
            raise first                      # core or cs-intercom unusable: refuse all
    if any(not isinstance(x, dict) or (not proof_parts._is_required(str(x.get("name") or ""))  # noqa: SLF001
                                       and (x.get("stale") or x.get("missing"))) for x in sources):
        raise first
    try:
        proof_parts.check_entries(doc)
    except proof_parts.PartsError:
        raise first from None
    # Fable FINAL [key=gmail-held-fallback] (3) (r5 580, 10-31 12:1xZ; supersedes the 24 h AllUsers bound): the did-vouch
    # set is FROZEN on the last good scan - its support@ contact snapshot (whatever its age: a dated, well-formed record
    # of who wrote to support@ in the 90 days before it), email proof_intake rows, ledger support@ refs and gmail export
    # entries. Those users are held; everyone with no support@ trace as of that scan is admitted on fresh core +
    # cs-intercom (the residual - a first-ever support@ email inside the dark window - is the /c2 class we correct).
    contacts = _frozen_contacts(doc, now=now, skew=skew)
    if contacts is None:
        raise verify_notify.ProofFileError("scoped check refused: the support@ contact snapshot is absent or malformed")
    held = {str(u) for u in contacts}
    held |= _gmail_filers(proof_store or PROOF_STORE)
    held |= _ledger_support_refs(ledger_path or verify_ledger.DEFAULT_PATH)
    # QA #1568: the export's OWN gmail-sourced proof entries (a 400-day scan) reach further back than the 90-day
    # contact snapshot and need no proof_intake or ledger row: every such user is held too.
    held |= {str(e["user_id"]).strip() for e in doc["entries"] if "gmail" in str(e.get("source") or "").lower()}
    return ClaimHolds(frozenset(held), scoped=True)


def _support_held(report: ClaimReport, uid: int, scoped: bool) -> None:
    if scoped:
        report.stale_source_hold += 1
        report.outcomes.append({"user": str(uid), "result": "held", "reason": STALE_GMAIL_REASON})
    else:
        report.support_hold += 1


def run(*, list_path: str, segment: str, mode: str = "dry-run", max_users: int = 20, reminders: bool = False,
        preview_dir: str | None = None, query: Query = trino, wrapper: str = verify_notify.WRAPPER,
        runner: verify_notify.Runner = verify_notify._run, ledger_path: str | None = None,
        support_contacts: frozenset[str] | None = None, now: datetime | None = None,
        export_path: str | None = None, check_recipients: bool = False) -> ClaimReport:
    if check_recipients and reminders:
        raise ValueError("check_recipients applies to first notes only, not reminders (QA #1516)")
    report = ClaimReport()
    claims, why = load_list(list_path, now=now)
    if why:
        report.halted = why
        return report
    scoped = False
    if support_contacts is None:
        try:
            holds = claim_holds(now=now, ledger_path=ledger_path)
        except verify_notify.ProofFileError as exc:
            report.halted = f"the support-contact feed is unusable ({exc})"[:300]
            return report
        support_contacts, scoped = holds.held, holds.scoped
    want_paid = segment == "paid"
    by_id = {int(c["claim_id"]): c for c in claims if str(c.get("claim_id", "")).isdigit()}
    report.listed = len(by_id)
    db = verify_ledger.connect(ledger_path or verify_ledger.DEFAULT_PATH)
    day = (now or datetime.now(timezone.utc)).strftime("%Y-%m-%d")
    if reminders:
        return _reminders(report, by_id, db=db, day=day, mode=mode, max_users=max_users, query=query,
                          wrapper=wrapper, runner=runner, preview_dir=preview_dir, support_contacts=support_contacts,
                          want_paid=want_paid, scoped=scoped)
    offered = sorted((c for c in by_id.values() if bool(c.get("paid")) is want_paid), key=lambda c: int(c["claim_id"]))
    asked = verify_ledger.blocked_ids(db, [f"claim-{int(c['claim_id'])}" for c in offered], CAMPAIGN)
    keep: list[dict[str, Any]] = []
    for c in offered:
        if f"claim-{int(c['claim_id'])}" in asked:
            report.already_asked += 1        # dropped before the budget, so later runs reach new claims
        elif str(c.get("audience") or "").strip().lower() == "status":
            report.status_audience += 1      # the list routes it to the claim-status note
        elif str(c.get("band") or "").upper() not in BANDS:
            report.not_band += 1
        elif c.get("code_found"):
            report.code_found += 1
        elif str(c.get("platform") or "").strip().lower() not in READABLE:
            report.no_readable_surface += 1
        elif not _profile_id(c) or not display_name(c.get("profile_name")):
            report.no_profile_id += 1
        else:
            keep.append(c)
    states = claim_states([int(c["claim_id"]) for c in keep], query) if keep else {}
    accts = accounts_of(sorted({int(c["user_id"]) for c in keep}), query) if keep else {}
    budget = _budget(db, day, max_users)
    seen: set[int] = set()
    payloads: list[dict[str, Any]] = []
    for c in keep:
        cid, uid = int(c["claim_id"]), int(c["user_id"])
        st = states.get(cid)
        if st is None or st[0] != "pending" or st[1] != uid:
            report.not_pending += 1
            continue
        if str(uid) in support_contacts:
            _support_held(report, uid, scoped)
            continue
        acct = accts.get(uid) or {}
        if not acct.get("email"):
            report.no_email += 1
            continue
        if not acct.get("professional_id"):
            report.no_professional_id += 1   # Intercom identity unverifiable: held, never to the gate
            continue
        if uid in seen:
            report.second_claim += 1
            continue
        if len(payloads) >= budget:
            report.over_daily_max += 1
            continue
        seen.add(uid)
        payloads.append(_payload(c, acct))
    report.users = len(payloads)
    verify_notify.send_all(payloads, report, mode=mode, wrapper=wrapper, runner=runner,
                           extra=["--campaign", CAMPAIGN], preview_dir=preview_dir,
                           check_recipients=check_recipients and mode != "apply")
    if mode == "apply":
        export_asked(db, export_path)
    return report


def is_status_audience(c: dict[str, Any]) -> bool:
    """Does this listed claim get the claim-status note (and never the proof ask)?"""
    aud = str(c.get("audience") or "").strip().lower()
    if aud:
        return aud == "status"
    band = str(c.get("band") or "").upper()
    if band == "A" or not band:
        return False                      # approval path / unknown: neither note without an explicit audience
    return band not in BANDS or str(c.get("platform") or "").strip().lower() not in READABLE


def run_status(*, list_path: str, segment: str, mode: str = "dry-run", max_users: int = 50,
               preview_dir: str | None = None, query: Query = trino, wrapper: str = verify_notify.WRAPPER,
               runner: verify_notify.Runner = verify_notify._run, ledger_path: str | None = None,
               support_contacts: frozenset[str] | None = None, now: datetime | None = None,
               check_recipients: bool = False) -> ClaimReport:
    """The claim-status note run (see the module docstring). check_recipients (dry run only, C11): every send-time
    check runs read-only through the gate's --check-recipient, so the dry run reports what the send would do."""
    report = ClaimReport()
    claims, why = load_list(list_path, now=now, require_daily_check=False)
    if why:
        report.halted = why
        return report
    scoped = False
    if support_contacts is None:
        try:
            holds = claim_holds(now=now, ledger_path=ledger_path)
        except verify_notify.ProofFileError as exc:
            report.halted = f"the support-contact feed is unusable ({exc})"[:300]
            return report
        support_contacts, scoped = holds.held, holds.scoped
    want_paid = segment == "paid"
    by_id = {int(c["claim_id"]): c for c in claims if str(c.get("claim_id", "")).isdigit()}
    report.listed = len(by_id)
    db = verify_ledger.connect(ledger_path or verify_ledger.DEFAULT_PATH)
    day = (now or datetime.now(timezone.utc)).strftime("%Y-%m-%d")
    offered = sorted((c for c in by_id.values() if bool(c.get("paid")) is want_paid), key=lambda c: int(c["claim_id"]))
    keys = [f"claim-{int(c['claim_id'])}" for c in offered]
    done = verify_ledger.blocked_ids(db, keys, STATUS_CAMPAIGN)
    asked = verify_ledger.blocked_ids(db, keys, CAMPAIGN)
    keep: list[dict[str, Any]] = []
    for c in offered:
        k = f"claim-{int(c['claim_id'])}"
        if k in done:
            report.already_asked += 1
        elif k in asked or not is_status_audience(c):
            report.ask_audience += 1         # told through the proof ask (or on the approval path)
        elif c.get("code_found"):
            report.code_found += 1
        elif not _profile_id(c) or not display_name(c.get("profile_name")):
            report.no_profile_id += 1
        else:
            keep.append(c)
    states = claim_states([int(c["claim_id"]) for c in keep], query) if keep else {}
    accts = accounts_of(sorted({int(c["user_id"]) for c in keep}), query) if keep else {}
    budget = max(0, min(max_users, CLAIM_STATUS_DAILY_MAX - verify_ledger.messages_today(db, campaign=STATUS_CAMPAIGN, day=day)))
    seen: set[int] = set()
    payloads: list[dict[str, Any]] = []
    for c in keep:
        cid, uid = int(c["claim_id"]), int(c["user_id"])
        st = states.get(cid)
        if st is None or st[0] != "pending" or st[1] != uid:
            report.not_pending += 1
            continue
        if str(uid) in support_contacts:
            _support_held(report, uid, scoped)
            continue
        acct = accts.get(uid) or {}
        if not acct.get("email"):
            report.no_email += 1
            continue
        if not acct.get("professional_id"):
            report.no_professional_id += 1
            continue
        if uid in seen:
            report.second_claim += 1
            continue
        if len(payloads) >= budget:
            report.over_daily_max += 1
            continue
        seen.add(uid)
        p = _payload(c, acct)
        p["claim"] = {"profile_name": display_name(c.get("profile_name"))}
        payloads.append(p)
    report.users = len(payloads)
    verify_notify.send_all(payloads, report, mode=mode, wrapper=wrapper, runner=runner,
                           extra=["--campaign", STATUS_CAMPAIGN], preview_dir=preview_dir,
                           check_recipients=check_recipients and mode != "apply")
    return report


def _budget(db: Any, day: str, max_users: int) -> int:
    """Messages this run may send: max_users, within what is left of today's CLAIM_DAILY_MAX
    after every claim-proof-ask message (first note or reminder) already claimed today."""
    return max(0, min(max_users, CLAIM_DAILY_MAX - verify_ledger.messages_today(db, campaign=CAMPAIGN, day=day)))


def export_asked(db: Any, path: str | None = None) -> int:
    """Rewrite the send log the daily code check reads: one JSON line per claim whose first note
    was SENT, {id, profileId, userId, askedAt, dateClose}, from the ledger (a full snapshot, so a
    re-run or a crash never leaves it half-written: temp file + atomic replace). Returns the count."""
    path = path or ASKED_EXPORT
    rows = db.execute("SELECT request_ids_json, refs_json, account_id, created_at, due_day FROM verify_messages "
                      "WHERE campaign=? AND kind='initial' AND status='sent' ORDER BY id", (CAMPAIGN,)).fetchall()
    lines = []
    for ids, refs, uid, at, due in rows:
        m = CLAIM_KEY.match(str((json.loads(ids or "[]") or [""])[0]))
        if not m:
            continue
        prof = next((str(r.get("profile_id") or "") for r in json.loads(refs or "[]") if isinstance(r, dict)), "")
        lines.append(json.dumps({"id": int(m.group(1)), "profileId": prof, "userId": str(uid or ""),
                                 "askedAt": at, "dateClose": due}, sort_keys=True))
    tmp = f"{path}.tmp-{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + ("\n" if lines else ""))
    os.replace(tmp, path)
    return len(lines)


def _reminders(report: ClaimReport, by_id: dict[int, dict[str, Any]], *, db: Any, day: str, mode: str,
               max_users: int, query: Query, wrapper: str, runner: verify_notify.Runner,
               preview_dir: str | None, support_contacts: frozenset[str], want_paid: bool,
               scoped: bool = False) -> ClaimReport:
    due = []
    for d in verify_ledger.claim_reminders_due(db, day=day):
        if d["result"] == "due":
            due.append(d)
            continue
        if mode == "apply":                  # the claimant replied: never reminded, the reply is with a person
            verify_ledger.close_reminder(db, parent_message_id=d["message_id"], kind=verify_ledger.CLAIM_REMINDER,
                                         day=day, reason="claimant replied")
        report.closed_reminders += 1
    cids = [int(m.group(1)) for d in due for m in [CLAIM_KEY.match(str((d["request_ids"] or [""])[0]))] if m]
    states = claim_states(cids, query) if cids else {}
    uids = sorted({int(by_id[c]["user_id"]) for c in cids if c in by_id})
    accts = accounts_of(uids, query) if uids else {}
    budget = _budget(db, day, max_users)
    payloads: list[dict[str, Any]] = []
    for d in due:
        m = CLAIM_KEY.match(str((d["request_ids"] or [""])[0]))
        cid = int(m.group(1)) if m else -1
        c = by_id.get(cid)
        st = states.get(cid)
        reason = ""
        if st is None or st[0] != "pending":
            reason = f"claim {st[0] if st else 'gone'}"
        elif c is None:
            report.not_in_list += 1      # no server facts to render today: wait, nothing closed
            continue
        elif bool(c.get("paid")) is not want_paid:
            continue                     # the other segment's run reminds it
        elif str(c.get("audience") or "").strip().lower() == "status":
            # Today's list routes the claim away from proof requests (e.g. a hold): no second code ask;
            # it gets the claim-status note instead (QA on #1366).
            reason = "routed to the claim-status note"
        elif str(c.get("band") or "").upper() not in BANDS:
            # Reclassified since the first note (e.g. B -> A, now on the approval path, or -> D,
            # held for a person): the code ask no longer applies, so its reminder is closed (QA on #1330).
            reason = f"band {str(c.get('band') or '?').upper()} (not B/C)"
        elif c.get("code_found"):
            reason = "code found"
        elif str(c.get("user_id")) != str(d["account_id"] or "") or st[1] != int(c["user_id"]):
            reason = "claim owner changed"
        if reason:
            if mode == "apply":
                verify_ledger.close_reminder(db, parent_message_id=d["message_id"], kind=verify_ledger.CLAIM_REMINDER,
                                             day=day, reason=reason)
            report.closed_reminders += 1
            continue
        if str(c.get("platform") or "").strip().lower() not in READABLE:
            report.no_readable_surface += 1   # today's list names no readable surface: wait, nothing closed
            continue
        if not _profile_id(c):
            report.no_profile_id += 1         # held, never sent without the profile id
            continue
        if str(c["user_id"]) in support_contacts:
            _support_held(report, int(c["user_id"]), scoped)
            continue
        if len(payloads) >= budget:
            report.over_daily_max += 1
            continue
        acct = accts.get(int(c["user_id"])) or {}
        if not acct.get("email"):
            report.no_email += 1
            continue
        if not acct.get("professional_id"):
            report.no_professional_id += 1
            continue
        payloads.append(_payload(c, acct, ["--kind", verify_ledger.CLAIM_REMINDER, "--parent-message-id", d["message_id"]]))
    report.users = len(payloads)
    verify_notify.send_all(payloads, report, mode=mode, wrapper=wrapper, runner=runner,
                           extra=["--campaign", CAMPAIGN], preview_dir=preview_dir, reminder=True)
    return report


def render(report: ClaimReport, mode: str, segment: str, reminders: bool = False, status: bool = False) -> str:
    what = "CLAIM STATUS NOTE" if status else ("CLAIM PROOF REMINDERS" if reminders else "CLAIM PROOF ASK")
    if report.halted:
        return f"{what} ({segment}): NOTHING sent: {report.halted}."
    # QA #1534: a --check-recipients dry run counts an accepted recipient in recipient_ok (the real gate's read-only
    # check), not in validated, so the would-send figure is their sum, labelled by what was checked.
    checked = getattr(report, "recipient_ok", 0)
    verb = "sent" if mode == "apply" else ("would send (recipient checked)" if checked else "would send (validated)")
    n = ((report.reminders_sent if reminders else report.sent_notes) if mode == "apply"
         else report.validated + checked)
    parts = [f"{what} ({segment}, {mode}): {report.listed} claims on the list; {verb} {n}"]
    for label, v in (("not band B/C", report.not_band), ("code already found", report.code_found),
                     ("no surface the daily check can read (waits for the documents path)", report.no_readable_surface),
                     ("claim no longer pending or another owner", report.not_pending),
                     ("held: emailed support@ in 90 days", report.support_hold),
                     (f"held: {STALE_GMAIL_REASON} (cs-gmail could vouch for them)", report.stale_source_hold),
                     ("no account email", report.no_email),
                     ("second claim of the same user (next run)", report.second_claim),
                     ("over today's cap (next run)", report.over_daily_max),
                     ("already asked (earlier run)", report.already_asked),
                     ("routed to the claim-status note", report.status_audience),
                     ("told through the proof ask or on the approval path", report.ask_audience),
                     ("reminders closed (claim decided, code found, claimant replied)", report.closed_reminders),
                     ("reminder waits: claim not on today's list", report.not_in_list),
                     ("no professional id (held)", report.no_professional_id),
                     ("no well-formed profile_id on the list (held)", report.no_profile_id), ("skipped by the gate", report.skipped),
                     ("deferred by the gate", report.deferred_users), ("refused by the gate", report.refused_users),
                     ("FAILED", report.failed_users)):
        if v:
            parts.append(f"{label} {v}")
    # C11: every deferral is shown with its user and the gate's reason (never a bare count)
    detail = report.deferrals[:20] + (report.refusals + report.failures)[:5]
    return "; ".join(parts) + "." + (" " + "; ".join(detail) if detail else "")
