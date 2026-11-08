"""Did the fix actually happen? The read-back that is the only path to a message.

R2 in one sentence: **a user becomes message-eligible only when the fix is Seen in the system
of record**. That means a row written by the lane that did the work - not by us, not by the
scheduler, and not by the ticket existing. Per lane:

    lane            Seen means                                                    source
    ---------------------------------------------------------------------------------------------
    credit-review   a credit DECISION for this user AND a verify_messages status  hydra credit
                    row telling them (verified ledger, read-only)                 ledger sqlite
    proof           the same (an approved credit after the documents)             hydra credit
                                                                                  ledger sqlite
    claim           the claim reaches a terminal processed state                  core via Trino
    merge           the ClickUp task is closed with customer-outcome:complete     ClickUp API
    analytics       the same, AND the task records a fresh `as_of` for the metric ClickUp API
    refund          a closed refund task whose Stripe refund OBJECT exists with   Stripe API
                    status `succeeded` and the recorded amount                    (stripe CLI)
    caroline-drain  the thread is closed by an ADMIN reply of >= 40 words that is  Intercom API
                    not a sweep line (the quoted "other" FIX_LINE is that reply)

**Every reader fails closed.** An unreadable store, a 500 from Intercom, a Trino error, a
missing column: the verdict is ``eligible=False`` with the reason recorded on the ticket. The
failure mode this prevents is the one that started the campaign - saying "we fixed it" because
nobody could prove we had not.

A non-eligible reason carries one of four prefixes, and the caller depends on the distinction:

* ``unreadable`` / ``reader error`` - a SOURCE is down (raised, timed out, 500, missing
  credential). A run where every verdict is one of these is an outage, not "no fixes yet", and
  the ticket does NOT spend an attempt from the read-back budget: an outage is no evidence about
  this user.
* ``datagap`` - the source answered and this ticket's own row is permanently incomplete (no
  ``claiming`` row, a ClickUp task somebody deleted, a refund task recording no Stripe refund id
  or no amount, a refund id Stripe does not hold, a conversation whose open/closed state is
  missing). It
  spends an attempt, so a ticket nobody can ever read back exhausts its budget and is escalated
  instead of sitting at the head of every run forever.
* ``undatable`` - the source answered and the candidate itself carries no start of wait (needs a
  ``request_at`` or ``credit_open.oldest``), so no fix can be dated. Also spends an attempt.
* anything else - "nothing yet, read again later".

Within a verdict that stays local; a reader that cannot reach its source AT ALL raises
``SourceUnreadable`` (the one error type the churn CLIs catch to exit 3, "a source outage is
not zero returns"). ``trino_sql`` wraps a missing wrapper, a non-zero exit and a timeout in it.

Readers are injected (``Sources``) so a test can drive every branch with no network and no
prod store; the default readers are the real ones (Trino, Intercom, ClickUp, the Stripe CLI).

Some verdict fields carry text a PERSON wrote to a customer (``STAFF_TEXT_KEYS``). Those bytes
may only live in the 0600 ledger and the 0600 run artifact: ``redact_staff_text`` produces the
copy that goes to stdout, so a captured stdout stream is safe to keep.
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Callable, Mapping

from . import lanes, model

LEDGER_DEFAULT = "/var/lib/hydra/credit-review/ledger.sqlite3"
TRINO_DEFAULT = "/opt/hydra/scripts/trino-query.sh"
INTERCOM = "https://api.intercom.io"
ADMIN_REPLY_MIN_WORDS = 40


class SourceUnreadable(RuntimeError):
    """A source of record could not be read: no proof, and never a pass."""


@dataclass
class Verdict:
    """What the read-back found. ``evidence`` is what the renderer consumes."""

    eligible: bool
    reason: str
    evidence: dict[str, Any] = field(default_factory=dict)
    human_reply: str | None = None

    def as_dict(self) -> dict[str, Any]:
        return {"eligible": self.eligible, "reason": self.reason, **self.evidence}


def not_eligible(reason: str, **evidence: Any) -> Verdict:
    return Verdict(eligible=False, reason=reason, evidence=dict(evidence))


#: Verdict/evidence fields whose value is free text written by a person about a customer's
#: account. A new lane that records human prose MUST add its key here: that is the one list the
#: stdout redaction reads, so a lane cannot leak staff correspondence by omission.
STAFF_TEXT_KEYS = ("human_reply",)


def redact_staff_text(value: Any) -> Any:
    """A copy of a read-back document with every staff-authored field replaced by its length."""
    if isinstance(value, Mapping):
        return {k: (_redacted(v) if k in STAFF_TEXT_KEYS and isinstance(v, str)
                    else redact_staff_text(v))
                for k, v in value.items()}
    if isinstance(value, list):
        return [redact_staff_text(v) for v in value]
    return value


def _redacted(text: str) -> str:
    return f"<redacted, {len(text.split())} words>"


class Sources:
    """Every read the read-back performs, injectable.

    ``ledger`` is a path; ``run_sql`` executes ONE read statement on the core replica and
    returns CSV lines; ``fetch_conversation`` returns the Intercom conversation JSON;
    ``clickup_task`` returns one task JSON (or None); ``stripe_refund`` returns one Stripe
    refund object, or None when Stripe says no such object exists.
    """

    def __init__(self, *, ledger: str | Path = LEDGER_DEFAULT,
                 run_sql: Callable[[str], list[list[str]]] | None = None,
                 fetch_conversation: Callable[[str], Mapping[str, Any] | None] | None = None,
                 clickup_task: Callable[[str], Mapping[str, Any] | None] | None = None,
                 stripe_refund: Callable[[str], Mapping[str, Any] | None] | None = None,
                 now: Callable[[], float] = time.time,
                 min_reply_words: int = ADMIN_REPLY_MIN_WORDS):
        self.ledger = str(ledger)
        self.run_sql = run_sql or trino_sql
        self.fetch_conversation = fetch_conversation or intercom_conversation
        self.clickup_task = clickup_task or clickup_task_live
        self.stripe_refund = stripe_refund or stripe_refund_live
        self.now = now
        #: from policy.guards.human_reply_min_words, so editing the policy file really moves the
        #: gate instead of leaving a constant that reads as enforcement and is not.
        self.min_reply_words = int(min_reply_words or ADMIN_REPLY_MIN_WORDS)


# ── credit lane: the verify ledger (the only record that a fix was TOLD) ──────
_STATUS_TELLING = ("sent",)
#: decisions.decision vocabulary (`scripts/credit_review/decide.py` SCHEMA): a HOLD is a human
#: look, a DEFER is "nothing happened" - neither is a fix, so neither counts as a decision.
_DECISION_PENDING = ("hold", "defer")
#: decision_outcomes.outcome vocabulary: only `approved` moved a credit row.
_OUTCOME_APPROVED = ("approved",)
_OUTCOME_DECLINED = ("unverified", "user_verification_needed")


def _epoch_or_none(raw: Any) -> float | None:
    """An epoch or ISO-8601 instant, or None when the value cannot be read."""
    if raw is None or raw == "":
        return None
    try:
        value = float(raw)
    except (TypeError, ValueError):
        import calendar

        try:
            value = float(calendar.timegm(time.strptime(str(raw).rstrip("Z"), "%Y-%m-%dT%H:%M:%S")))
        except ValueError:
            return None
    return value if value > 0 else None


def proof_start(ticket: Any) -> float | None:
    """When this user's wait began: a fix can only be proof if it is NEWER than this.

    The candidate's OWN start of wait - its request, or an earlier open credit wait - raised to
    the churn window's start (the snapshot watermark minus ``windows.churn_days``, recorded on the
    ticket when it was routed, never the wall clock). A pre-existing approval that predates the
    wait the user complained about therefore proves nothing. Missing inputs return None, and a
    ticket with no date can never be Seen.
    """
    candidate = getattr(ticket, "candidate", None) or {}
    if not isinstance(candidate, Mapping):
        return None
    floor = _epoch_or_none(candidate.get("churn_window_start"))
    if floor is None:
        return None
    waits = [_epoch_or_none(candidate.get("request_at"))]
    credit_open = candidate.get("credit_open")
    if isinstance(credit_open, Mapping):
        waits.append(_epoch_or_none(credit_open.get("oldest")))
    known = [w for w in waits if w is not None]
    if not known:
        return None
    return max(min(known), floor)


def _ticket_request_ids(ticket: Any) -> set[str]:
    """The credit requests this ticket is actually waiting on, when the candidate holds them.

    A decision or a status note for a DIFFERENT request says nothing about the one the user
    complained about, so the read-back binds to these ids when the store carries them.
    """
    candidate = getattr(ticket, "candidate", None) or {}
    if not isinstance(candidate, Mapping):
        return set()
    credit_open = candidate.get("credit_open")
    if not isinstance(credit_open, Mapping):
        return set()
    return {str(i).strip() for i in credit_open.get("request_ids") or () if str(i).strip()}


def _message_request_ids(raw: Any) -> set[str]:
    try:
        ids = json.loads(raw or "[]")
    except (TypeError, ValueError):
        return set()
    if not isinstance(ids, (list, tuple)):
        return set()
    return {str(i).strip() for i in ids if str(i).strip()}


def credit_verdict(ticket: Any, sources: Sources) -> Verdict:
    """Credits decided AND the user told, both dated after the user's own wait began.

    The two halves matter for different reasons: a decision with no status row means we fixed
    it silently (the user is still waiting to hear), and a status row with no decision means
    we told them something that had not happened. Only both, in that order, is a fix Seen.

    The anchor is the candidate's start of wait (``proof_start``), not the routing moment: a fix
    that landed between the audience measurement and the routing run is still a fix, and the
    status row has to follow the decision it reports.

    Counts come from ``decision_outcomes`` per REQUEST (latest outcome wins; the table is
    append-only, so a revert must not read as an approval). `hold`/`defer` rows are recorded
    as the reason rather than as a decision.
    """
    user_id = str(ticket.user_id)
    start = proof_start(ticket)
    if start is None:
        return not_eligible(
            "undatable: no start of wait (request_at / credit_open.oldest) inside the churn window "
            "on this ticket, so no fix can be dated")
    since_iso = _iso(start)
    try:
        db = sqlite3.connect(f"file:{sources.ledger}?mode=ro", uri=True, timeout=20)
    except sqlite3.Error as exc:
        return not_eligible(f"unreadable: credit ledger {sources.ledger}: {exc}")
    try:
        db.row_factory = sqlite3.Row
        have = {r[1] for r in db.execute("PRAGMA table_info(decisions)")}
        if not have:
            return not_eligible("unreadable: the credit ledger has no decisions table")
        if "user_id" not in have:
            return not_eligible("unreadable: decisions has no user_id column to join on")
        try:
            uid = int(user_id)
        except ValueError:
            return not_eligible("the ticket's user id is not numeric; decisions keys on integer user ids")
        decisions = list(
            db.execute(
                "SELECT request_id, decision, decided_at FROM decisions "
                "WHERE user_id = ? AND decided_at >= ? ORDER BY decided_at",
                (uid, since_iso),
            )
        )
        wanted = _ticket_request_ids(ticket)
        if not wanted:
            return not_eligible(
                "no request binding: the ticket does not name the credit request(s) this user is "
                "waiting on, so no decision can be attributed to the thing they complained about")
        decisions = [d for d in decisions if str(d["request_id"]) in wanted]
        if not decisions:
            return not_eligible(
                "no credit decision has been recorded for the requests this user is waiting on "
                "since their wait began")
        requests = [str(d["request_id"]) for d in decisions]
        latest: dict[str, tuple[str, str]] = {}
        outcome_cols = {r[1] for r in db.execute("PRAGMA table_info(decision_outcomes)")}
        if not {"request_id", "outcome", "at"} <= outcome_cols:
            return not_eligible("unreadable: the credit ledger has no decision_outcomes "
                                "(request_id, outcome, at) to read")
        try:
            q = "SELECT request_id, outcome, at FROM decision_outcomes WHERE at >= ? AND request_id IN (%s)" % (
                ",".join("?" * len(requests)),
            )
            for row in db.execute(q, (since_iso, *requests)):
                rid, outcome, at = str(row["request_id"]), str(row["outcome"]), str(row["at"])
                if rid not in latest or at > latest[rid][0]:
                    latest[rid] = (at, outcome)
        except sqlite3.Error as exc:
            return not_eligible(f"unreadable: decision_outcomes: {exc}")
        approved = sum(1 for _at, o in latest.values() if o in _OUTCOME_APPROVED)
        declined = sum(1 for _at, o in latest.values() if o in _OUTCOME_DECLINED)
        pending = sum(1 for d in decisions if str(d["decision"]).lower() in _DECISION_PENDING)
        counts = {"credits_approved": approved, "credits_declined": declined, "decider_pending": pending}
        # Every request the user complained about needs a terminal outcome. One approved request
        # does not settle a ticket that also names a request still waiting: the copy says the
        # thing they waited for is done, and for the open one it is not.
        terminal_ids = {rid for rid, (_at, o) in latest.items()
                        if o in _OUTCOME_APPROVED or o in _OUTCOME_DECLINED}
        unresolved = sorted(wanted - terminal_ids)
        if unresolved:
            return not_eligible(
                "the decider has not reached a terminal outcome for every request this user is "
                "waiting on (still open: %s)" % ", ".join(unresolved), **counts)
        told = None
        try:
            # The row that PROVES the user was told, not whichever row sorts last: a later
            # deferred/refused note for another request is a note, never evidence of not-told.
            # Each note must also follow the outcome it reports, not merely the start of the wait.
            rows = db.execute(
                "SELECT campaign, status, created_at, sent_at, request_ids_json FROM verify_messages "
                "WHERE account_id = ? AND COALESCE(sent_at, created_at) >= ? AND status IN (%s) "
                "ORDER BY COALESCE(sent_at, created_at) DESC, id DESC"
                % ",".join("?" * len(_STATUS_TELLING)),
                (user_id, since_iso, *_STATUS_TELLING),
            ).fetchall()
            # The note must name the requests this ticket is waiting on - a note about somebody
            # else's request is not this fix. Each request needs its OWN notification after its
            # OWN outcome: with A approved then B approved later, a note sent after B does not
            # stand in for the note A needed after A's approval. Ordering the query from the
            # latest approval instead dropped A's note and held a user who had been told.
            rows = [r for r in rows if _message_request_ids(r["request_ids_json"]) & wanted]
            covered: dict[str, float] = {}
            for row in rows:
                at = (_epoch_or_none(row["sent_at"]) or _epoch_or_none(row["created_at"]) or 0.0)
                for rid in _message_request_ids(row["request_ids_json"]) & wanted:
                    covered[rid] = max(covered.get(rid, 0.0), at)
            terminal_at = {rid: (_epoch_or_none(at) or 0.0) for rid, (at, _o) in latest.items()}
            told = rows[0] if rows and all(
                covered.get(rid, 0.0) >= terminal_at.get(rid, 0.0) for rid in wanted) else None
        except sqlite3.Error as exc:
            return not_eligible(f"unreadable: verify_messages: {exc}")
    finally:
        db.close()

    if approved == 0:
        if declined or pending:
            return not_eligible(
                "the decider has not approved a credit for this user yet (no approval to name)", **counts
            )
        return not_eligible("the decision recorded nothing that moved a credit row", **counts)
    if told is None:
        return not_eligible("the credits were decided but no status note was sent: the user does not know yet", **counts)
    status = str(told["status"] or "").lower()
    return Verdict(
        eligible=True,
        reason="credits approved and the status note sent",
        evidence={
            **counts,
            "status_note": {"campaign": told["campaign"], "status": status,
                            "created_at": told["created_at"], "sent_at": told["sent_at"]},
        },
    )


def _iso(epoch: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(float(epoch or 0.0)))


# ── claim lane: core, via the replica ────────────────────────────────────────
def claim_verdict(ticket: Any, sources: Sources) -> Verdict:
    """A pending claim has to reach a terminal processed state in core.

    Deliberately narrow: only ``processed`` counts, because that is the one state the
    claiming model treats as done (skills-all/muso-query-writer/trino-schemas.md, Claimed
    Profiles CTE). A read that fails - wrong column, no replica - is UNKNOWN, never a pass.
    """
    try:
        rows = sources.run_sql(
            "SELECT CAST(id AS varchar), CAST(status AS varchar), CAST(createdat AS varchar), "
            "CAST(updatedat AS varchar), coalesce(CAST(profileid AS varchar), '') "
            "FROM postgresql_core.public.claiming "
            f"WHERE userid = {int(str(ticket.user_id))} ORDER BY createdat"
        )
    except (ValueError, subprocess.SubprocessError) as exc:
        return not_eligible(f"unreadable: claim status for this user: {exc}")
    except Exception as exc:  # noqa: BLE001 - a source we do not control; unknown, never a pass
        return not_eligible(f"unreadable: claim status for this user: {type(exc).__name__}: {exc}")
    records = [{"id": str(r[0] or "") if len(r) > 1 else "",
                "status": str(r[1] if len(r) > 1 else r[0] or "").strip().lower(),
                "created_at": str(r[2] or "") if len(r) > 2 else "",
                "updated_at": str(r[3] or "") if len(r) > 3 else "",
                "profile_id": str(r[4] or "") if len(r) > 4 else ""}
               for r in rows if r]
    if not records:
        return not_eligible("datagap: the claim read returned no rows (cannot tell pending from processed)")
    wanted_ids, wanted_profiles = _claim_targets(ticket)
    if wanted_ids:
        records = [r for r in records if r["id"] in wanted_ids]
        if not records:
            return not_eligible("datagap: the claim this ticket is waiting on is not in the claim read")
    elif wanted_profiles:
        records = [r for r in records if r["profile_id"] in wanted_profiles]
        if not records:
            return not_eligible("datagap: the claim for this ticket's profile is not in the claim read")
    records.sort(key=lambda r: (_epoch_or_none(r["created_at"]) or 0.0,
                                _epoch_or_none(r["updated_at"]) or 0.0))
    newest = records[-1]
    status = newest["status"]
    if status != "processed":
        return not_eligible(f"the claim is still {status or 'unknown'}, not processed")
    start = proof_start(ticket)
    if start is None:
        return not_eligible(
            "undatable: no start of wait (request_at / credit_open.oldest) inside the churn window "
            "on this ticket, so no fix can be dated")
    ended = max((_epoch_or_none(r["updated_at"]) or _epoch_or_none(r["created_at"]) or 0.0)
                for r in records)
    if not ended:
        return not_eligible(
            "datagap: the processed claim records no date, so it cannot be dated against the wait")
    if ended < start:
        return not_eligible("the processed claim predates this user's wait, so it is not this fix")
    return Verdict(eligible=True, reason="the profile claim is processed",
                   evidence={"merge_claim_result": "claim"})


def _claim_targets(ticket: Any) -> tuple[set[str], set[str]]:
    """The claim id(s) / profile id this ticket is about, when the candidate records them."""
    candidate = getattr(ticket, "candidate", None) or {}
    if not isinstance(candidate, Mapping):
        return set(), set()
    ids: set[str] = set()
    profiles: set[str] = set()
    claims = candidate.get("claims")
    rows = [claims] if isinstance(claims, Mapping) else list(claims or ())
    if isinstance(claims, Mapping) and not any(
            key in claims for key in ("claim_id", "id", "claim_ids", "ids", "profile_id")):
        # Some snapshots key the map by claim id instead of spelling it in a field.
        valued = [v for v in claims.values() if isinstance(v, Mapping)]
        if valued:
            rows = valued
        else:
            ids.update(str(k).strip() for k in claims if str(k).strip())
    for row in rows:
        if not isinstance(row, Mapping):
            continue
        for key in ("claim_id", "id"):
            if row.get(key):
                ids.add(str(row[key]).strip())
        for key in ("claim_ids", "ids"):
            ids.update(str(i).strip() for i in row.get(key) or () if str(i).strip())
        if row.get("profile_id"):
            profiles.add(str(row["profile_id"]).strip())
    if candidate.get("profile_id"):
        profiles.add(str(candidate["profile_id"]).strip())
    return ids, profiles


# ── ClickUp lanes: merge / analytics ────────────────────────────────────────
def clickup_verdict(ticket: Any, sources: Sources, *, analytics: bool) -> Verdict:
    """The task must be CLOSED and carry the customer-outcome contract tag.

    ClickUp's own workflow status answers whether internal work stopped, not whether the
    customer-visible result is true (scripts/lib/customer_outcome.py). Both are required, and
    for analytics the task must also record the freshness the copy claims.
    """
    if not ticket.lane_ref or not re.fullmatch(r"[0-9A-Za-z_-]+", ticket.lane_ref):
        return not_eligible("no ClickUp task id on the ticket: nothing to read back")
    try:
        task = sources.clickup_task(ticket.lane_ref)
    except Exception as exc:  # noqa: BLE001 - source we do not control
        return not_eligible(f"unreadable: ClickUp task {ticket.lane_ref}: {type(exc).__name__}: {exc}")
    if not task:
        return not_eligible(f"datagap: ClickUp task {ticket.lane_ref} not found")
    status = (task.get("status") or {})
    closed = bool(status.get("type") == "closed" or status.get("type") == "done")
    tags = {str(t.get("name") or "").lower() for t in task.get("tags") or [] if isinstance(t, dict)}
    complete = "customer-outcome:complete" in tags
    if not closed:
        return not_eligible(f"the task is still open ({status.get('status') or 'unknown'})")
    if not complete:
        return not_eligible("the task is closed but carries no customer-outcome:complete tag")
    evidence: dict[str, Any] = {"clickup_task": ticket.lane_ref}
    if analytics:
        text = f"{task.get('description') or ''}\n{task.get('text_content') or ''}"
        as_of = _fresh_as_of(text, now=sources.now())
        if as_of is None:
            return not_eligible("the analytics task is complete but records no fresh as_of for the metric",
                                clickup_task=ticket.lane_ref)
        platform = _platform_from(text)
        if not platform:
            # Naming a platform the fix did not touch is worse than no message (R2).
            return not_eligible("the analytics task does not name exactly one platform: cannot say what was refreshed",
                                clickup_task=ticket.lane_ref)
        evidence.update({"platform": platform, "as_of": as_of})
    else:
        evidence["merge_claim_result"] = "merge"
    return Verdict(eligible=True, reason="the lane's own outcome row says customer-complete", evidence=evidence)


_AS_OF = re.compile(r"as[_ ]of[:\s]+(\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2})?Z?)?)", re.I)
#: platform family -> the spellings that identify it. Order is irrelevant now: the reader
#: counts FAMILIES, so "apple music" and "amazon music" cannot be shadowed by "apple"/"amazon".
_PLATFORMS = (
    ("Spotify", ("spotify",)),
    ("Apple Music", ("apple music", "itunes", "apple")),
    ("Tidal", ("tidal",)),
    ("YouTube", ("youtube", "youtube music")),
    ("Deezer", ("deezer",)),
    ("Amazon Music", ("amazon music", "amazon")),
    ("SoundCloud", ("soundcloud",)),
)


def _fresh_as_of(text: str, *, max_age_days: int = 7, now: float | None = None) -> str | None:
    """The newest ``as of`` stamp on the task, if it is inside the freshness window."""
    now = now if now is not None else time.time()
    best: float | None = None
    best_raw = None
    for m in _AS_OF.finditer(text):
        raw = m.group(1).replace(" ", "T")
        if raw.endswith("Z"):
            parsed = raw[:-1]
            fmt = "%Y-%m-%dT%H:%M:%S" if parsed.count(":") == 2 else "%Y-%m-%dT%H:%M"
        else:
            fmt = "%Y-%m-%dT%H:%M:%S" if raw.count(":") == 2 else ("%Y-%m-%dT%H:%M" if ":" in raw else "%Y-%m-%d")
        try:
            ts = _epoch(raw, fmt)
        except ValueError:
            continue
        if best is None or ts > best:
            best, best_raw = ts, m.group(1)
    # A stamp in the future is not a fresh measurement: it would make the age negative and
    # pass the window, so a task claiming "as of 2027" could certify a 2026 fix.
    if best is None or not (0 <= now - best <= max_age_days * 86400.0):
        return None
    return best_raw


def _epoch(raw: str, fmt: str) -> float:
    import calendar

    return float(calendar.timegm(time.strptime(raw.rstrip("Z"), fmt)))


def _platform_from(text: str) -> str:
    """The ONE platform family the task text names, or "" when it names none or several.

    The task description embeds evidence written elsewhere ("complained about Apple Music; also
    uses Spotify"), so returning the first match in a fixed list order would put a platform in a
    customer's copy that the fix never touched. Two families is ambiguous: hold, never pick.
    """
    low = text.lower()
    found = [name for name, spellings in _PLATFORMS if any(sp in low for sp in spellings)]
    return found[0] if len(found) == 1 else ""


# ── refund lane: the task a person works, carrying the Stripe object ────────
_STRIPE_REFUND = re.compile(r"\b(re_[0-9A-Za-z]{8,})\b")
_REFUND_AMOUNT = re.compile(r"\bstripe[_ ]refund[_ ]amount[:\s]+\$?([\d,]+(?:\.\d{1,2})?)", re.I)
#: A recorded amount is dollars, optionally grouped (``1,234.00``). Anything else is not a number
#: we can name, and the caller refuses rather than guessing at a truncated value.
_REFUND_AMOUNT_OK = re.compile(r"^(?:\d+|\d{1,3}(?:,\d{3})+)(?:\.\d{1,2})?$")


def refund_verdict(ticket: Any, sources: Sources) -> Verdict:
    """A CLOSED, customer-complete refund task whose Stripe refund object proves the money moved.

    The task is written by a person, so it can be wrong in either direction: a wrong id, or a
    refund that failed after they closed it. What the customer's copy asserts is that Stripe
    refunded them, so the task's figures are only a cross-check against the object Stripe holds:
    it must exist, be `succeeded`, and its amount (in cents) must equal the dollars recorded.
    """
    if not ticket.lane_ref or not re.fullmatch(r"[0-9A-Za-z_-]+", ticket.lane_ref):
        return not_eligible("no ClickUp task id on the ticket: nothing to read back")
    try:
        task = sources.clickup_task(ticket.lane_ref)
    except Exception as exc:  # noqa: BLE001 - source we do not control
        return not_eligible(f"unreadable: ClickUp task {ticket.lane_ref}: {type(exc).__name__}: {exc}")
    if not task:
        return not_eligible(f"datagap: ClickUp task {ticket.lane_ref} not found")
    status = task.get("status") or {}
    if not (status.get("type") in ("closed", "done")):
        return not_eligible(f"the refund task is still open ({status.get('status') or 'unknown'})")
    tags = {str(t.get("name") or "").lower() for t in task.get("tags") or [] if isinstance(t, dict)}
    if "customer-outcome:complete" not in tags:
        return not_eligible("the refund task is closed but carries no customer-outcome:complete tag")
    text = f"{task.get('name') or ''}\n{task.get('description') or ''}\n{task.get('text_content') or ''}"
    stripe = _STRIPE_REFUND.search(text)
    if not stripe:
        return not_eligible("datagap: the refund task records no Stripe refund id")
    amount = _REFUND_AMOUNT.search(text)
    if not amount:
        return not_eligible("datagap: the refund task records no amount: the copy cannot name it")
    amount_text = _amount_text(amount.group(1))
    if not amount_text:
        return not_eligible(
            f"the refund amount {amount.group(1)!r} is not a dollar figure the copy can name")
    refund_id = stripe.group(1)
    try:
        obj = sources.stripe_refund(refund_id)
    except SourceUnreadable as exc:
        return not_eligible(f"unreadable: {exc}", stripe_refund_id=refund_id)
    except Exception as exc:  # noqa: BLE001 - a CLI we do not control
        return not_eligible(f"unreadable: stripe refund {refund_id}: {type(exc).__name__}: {exc}",
                            stripe_refund_id=refund_id)
    if obj is None:
        return not_eligible(f"datagap: Stripe holds no refund object {refund_id}",
                            stripe_refund_id=refund_id)
    status = str(obj.get("status") or "")
    if status != "succeeded":
        return not_eligible(
            f"the Stripe refund {refund_id} is {status or 'of unknown status'}, not succeeded",
            stripe_refund_id=refund_id)
    cents = _cents(obj.get("amount"))
    if cents is None:
        return not_eligible(f"datagap: the Stripe refund {refund_id} records no amount",
                            stripe_refund_id=refund_id)
    recorded = int(Decimal(amount_text) * 100)
    if cents != recorded:
        return not_eligible(
            f"the Stripe refund {refund_id} is {_dollars(cents)} but the task records {amount_text}",
            stripe_refund_id=refund_id)
    candidate = getattr(ticket, "candidate", None) or {}
    expected = (str(candidate.get("customer_id") or "").strip()
                if isinstance(candidate, Mapping) else "")
    if not expected:
        return not_eligible(
            "datagap: the ticket records no Stripe customer id, so the refund cannot be tied to "
            "this customer", stripe_refund_id=refund_id)
    actual = _refund_customer(obj)
    if not actual:
        return not_eligible(
            f"datagap: the Stripe refund {refund_id} does not establish which customer it is for",
            stripe_refund_id=refund_id)
    if actual != expected:
        return not_eligible(
            f"the Stripe refund {refund_id} belongs to another customer ({actual}, not {expected})",
            stripe_refund_id=refund_id)
    return Verdict(
        eligible=True,
        reason="a Stripe refund object that succeeded for the recorded amount",
        evidence={"refund_amount": _dollars(cents), "stripe_refund_id": refund_id,
                  "stripe_status": status},
    )


def _refund_customer(obj: Mapping[str, Any]) -> str:
    """The customer the refund's charge belongs to, from an expanded charge (or the object)."""
    raw: Any = obj.get("customer")
    charge = obj.get("charge")
    if isinstance(charge, Mapping):
        raw = charge.get("customer")
    if isinstance(raw, Mapping):
        raw = raw.get("id")
    return str(raw or "").strip()


def _cents(raw: Any) -> int | None:
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return None
    return value if value >= 0 else None


def _dollars(cents: int) -> str:
    return f"{Decimal(cents) / 100:.2f}"


#: The Stripe CLI, overridable the same way the rest of the fleet overrides it.
STRIPE_BIN = "STRIPE_BIN"
STRIPE_TIMEOUT_SECONDS = 30


def stripe_refund_live(refund_id: str) -> Mapping[str, Any] | None:
    """``GET /v1/refunds/<id>`` through the Stripe CLI. None means Stripe has no such object.

    A CLI we cannot run, a non-zero exit that is not a missing object, or output that is not a
    refund object all raise ``SourceUnreadable``: an outage is UNKNOWN, and UNKNOWN is never
    evidence that a user's money came back.
    """
    cmd = [os.environ.get(STRIPE_BIN) or "stripe", "get", f"/v1/refunds/{refund_id}",
           "-d", "expand[]=charge"]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=STRIPE_TIMEOUT_SECONDS)
    except (OSError, subprocess.SubprocessError) as exc:
        raise SourceUnreadable(f"stripe could not be run: {type(exc).__name__}: {exc}") from exc
    doc = _json_doc(proc.stdout)
    if _resource_missing(doc) or _resource_missing(_json_doc(proc.stderr)):
        return None
    if proc.returncode != 0:
        raise SourceUnreadable(f"stripe get /v1/refunds/{refund_id} failed (rc {proc.returncode})")
    if not isinstance(doc, Mapping):
        raise SourceUnreadable(f"stripe get /v1/refunds/{refund_id} printed no JSON object")
    return doc


def _json_doc(raw: str | None) -> Any:
    if not raw or not raw.strip():
        return None
    try:
        return json.loads(raw)
    except ValueError:
        return None


def _resource_missing(doc: Any) -> bool:
    error = doc.get("error") if isinstance(doc, Mapping) else None
    return isinstance(error, Mapping) and error.get("code") == "resource_missing"


def _amount_text(raw: Any) -> str:
    """The amount in the unit the task records: DOLLARS (``stripe_refund_amount: 49.00``).

    Normalised to two decimals so the renderer's money rule holds even when the person writes
    ``49``, ``49.5`` or the grouped ``1,234.00``. An amount we cannot read (a grouping typo, a
    word) returns ``""`` so the caller holds the ticket unread instead of handing the renderer a
    value it would have to guess at.
    """
    text = str(raw if raw is not None else "").strip().lstrip("$").strip()
    if not _REFUND_AMOUNT_OK.match(text):
        return ""
    try:
        return f"{Decimal(text.replace(',', '')):.2f}"
    except (InvalidOperation, ValueError):
        return ""


# ── caroline-drain lane: the Intercom thread ───────────────────────────────
def intercom_verdict(ticket: Any, sources: Sources) -> Verdict:
    """A human answered, at length, and every thread carrying this wait was closed.

    This is the one lane whose fix IS the message, so the read-back is the strictest: the last
    admin reply on the thread must be a real answer (>= 40 words) that is not a sweeper's line,
    the conversation must be closed, and the answer must be newer than the start of the wait
    this ticket is about. A ticket can carry several conversations; an old closed one with a
    long answer must not certify a newer complaint that is still open, so every conversation
    with activity at or after the start of wait has to pass. The latest qualifying reply is
    what the ``other`` FIX_LINE quotes.
    """
    convs = [str(c) for c in (ticket.candidate or {}).get("intercom_convs") or [] if str(c).strip()]
    if not convs:
        return not_eligible("no Intercom conversation on this ticket: nothing to verify")
    start = proof_start(ticket)
    if start is None:
        return not_eligible(
            "undatable: no start of wait (request_at / credit_open.oldest) inside the churn window "
            "on this ticket, so no fix can be dated")
    missed: list[tuple[str, str]] = []
    failed: list[str] = []
    answered: list[tuple[float, Verdict]] = []
    for conv_id in convs:
        try:
            conv = sources.fetch_conversation(conv_id)
        except Exception as exc:  # noqa: BLE001 - a source we do not control
            failed.append(f"{conv_id}: {type(exc).__name__}: {exc}")
            continue
        if not isinstance(conv, Mapping):
            failed.append(f"{conv_id}: no conversation returned")
            continue
        last_at = _conversation_last_at(conv)
        if last_at is None:
            missed.append((conv_id, "datagap: the conversation has no readable message timestamps"))
            continue
        if last_at < start:
            # Resolved before this wait began: it is not the complaint this ticket is about.
            continue
        verdict = _human_closed_reply(conv, min_words=sources.min_reply_words, since=start)
        if verdict.eligible:
            answered.append((float(verdict.evidence.get("reply_at") or 0.0), verdict))
        else:
            missed.append((conv_id, verdict.reason))
    if missed:
        # The caller classifies on the FIRST token of the reason, so a per-ticket gap shared by
        # every conversation has to lead the composite instead of hiding behind a conversation id.
        hoisted = "datagap" if all(reason.startswith("datagap") for _, reason in missed) else ""
        detail = "; ".join(
            f"{conv_id}: {reason[len(hoisted):].lstrip(': ') if hoisted else reason}"
            for conv_id, reason in missed[:3])
        return not_eligible(f"{hoisted}: {detail}" if hoisted else detail)
    if failed:
        # A conversation we could not read could be the current complaint, so an eligible read
        # elsewhere cannot certify the ticket.
        return not_eligible(
            f"unreadable: {len(failed)} conversation read(s) failed ({'; '.join(failed[:3])})")
    if not answered:
        return not_eligible(
            "no conversation activity at or after the start of wait: nothing establishes this "
            "ticket's wait")
    return max(answered, key=lambda pair: pair[0])[1]


_SWEEP_ADMIN = re.compile(r"sweep|bot|automated|caroline", re.I)


def _conversation_parts(conv: Mapping[str, Any]) -> list[Any]:
    parts: list[Any] = []
    for src in ("conversation_parts", "parts", "source"):
        raw = conv.get(src)
        if isinstance(raw, Mapping):
            parts.extend(raw.get("conversation_parts") or raw.get("parts") or [])
            if raw.get("body") and raw.get("author"):
                parts.append(raw)
        elif isinstance(raw, list):
            parts.extend(raw)
    return parts


def _part_at(part: Mapping[str, Any]) -> float:
    return _epoch_or_none(part.get("created_at") or part.get("createdAt")) or 0.0


def _conversation_last_at(conv: Mapping[str, Any]) -> float | None:
    """The newest timestamp on the conversation, or None when nothing is datable."""
    stamps = [_part_at(p) for p in _conversation_parts(conv) if isinstance(p, Mapping)]
    stamps = [s for s in stamps if s > 0]
    closed_at = _epoch_or_none(conv.get("closed_at") or conv.get("closedAt"))
    if closed_at is not None:
        stamps.append(closed_at)
    return max(stamps) if stamps else None


def _human_closed_reply(conv: Mapping[str, Any], *, min_words: int = ADMIN_REPLY_MIN_WORDS,
                        since: float | None = None) -> Verdict:
    state = str((conv.get("state") or "") or "").lower()
    still_open = conv.get("open")
    if still_open is True:
        return not_eligible("the conversation is still open")
    if still_open is not False and state != "closed":
        return not_eligible("datagap: the conversation's open/closed state is unreadable")
    parts = _conversation_parts(conv)

    def customer_visible(part: Mapping[str, Any]) -> bool:
        # Intercom parts carry EVERYTHING the seat did on the thread, including internal notes
        # that the customer never saw. Only a ``comment`` is a message the customer received, so
        # only a comment can be the answer a closed thread is measured against (and quoted).
        return str(part.get("part_type") or "").lower() == "comment"

    admin_parts = [
        p for p in parts
        if isinstance(p, Mapping)
        and str((p.get("author") or {}).get("type") or "").lower() == "admin"
        and customer_visible(p)
    ]
    if not admin_parts:
        return not_eligible("no customer-visible admin reply on the thread")

    def at(part: Mapping[str, Any]) -> float:
        return _part_at(part)

    last = max(admin_parts, key=at)
    if since is not None and at(last) < since:
        return not_eligible("the last admin reply predates the start of wait, so it does not "
                            "answer this complaint")
    # An answer only closes the issue if nothing came after it: a customer replying "still broken"
    # after a long admin reply means the thread was not resolved by that reply, whatever the
    # close state says. The qualifying answer has to be the latest part in the thread.
    if any(isinstance(p, Mapping) and p is not last and at(p) > at(last)
           and not (str((p.get("author") or {}).get("type") or "").lower() == "admin"
                    and not customer_visible(p))
           for p in parts):
        return not_eligible("a newer message follows the last admin reply, so the thread was not "
                            "closed on that answer")
    closed_at = _epoch_or_none(conv.get("closed_at") or conv.get("closedAt"))
    if closed_at is not None and closed_at < at(last):
        return not_eligible("the thread was closed before the last admin reply, so the close does "
                            "not follow that answer")
    body = str(last.get("body") or "")
    text = re.sub(r"<[^>]+>", " ", body)
    text = " ".join(text.split())
    words = len(text.split())
    if words < min_words:
        return not_eligible(f"the last admin reply is {words} words (< {min_words}): not an answer")
    if lanes.sweep_copy_like(text):
        return not_eligible("the last admin line reads as a sweep/close, not a human answer")
    author = last.get("author") or {}
    if _SWEEP_ADMIN.search(str(author.get("name") or author.get("email") or "")) and words < min_words * 2:
        return not_eligible("the closing admin seat looks automated (sweep), not a person")
    return Verdict(eligible=True, reason="closed by a human answer",
                   evidence={"human_reply": text, "reply_at": at(last)}, human_reply=text)


# ── dispatch ────────────────────────────────────────────────────────────────
def read(ticket: Any, sources: Sources) -> Verdict:
    """The verdict for one routed ticket. Never raises: a reader bug is UNKNOWN, not a pass."""
    lane = str(getattr(ticket, "lane", ""))
    try:
        if lane in (model.CREDIT_REVIEW, model.PROOF):
            return credit_verdict(ticket, sources)
        if lane == model.CLAIM:
            return claim_verdict(ticket, sources)
        if lane == model.MERGE:
            return clickup_verdict(ticket, sources, analytics=False)
        if lane == model.ANALYTICS:
            return clickup_verdict(ticket, sources, analytics=True)
        if lane == model.REFUND:
            return refund_verdict(ticket, sources)
        if lane == model.CAROLINE:
            return intercom_verdict(ticket, sources)
    except Exception as exc:  # noqa: BLE001 - one row's reader failure must not stop the run
        return not_eligible(f"reader error: {type(exc).__name__}: {exc}")
    return not_eligible(f"no read-back for lane {lane!r}")


# ── live sources ────────────────────────────────────────────────────────────
def trino_sql(sql: str) -> list[list[str]]:
    """One read statement on the core replica through the repo's wrapper (CSV out)."""
    import csv
    import io

    trino = os.environ.get("CHURN_TRINO", TRINO_DEFAULT)
    try:
        proc = subprocess.run([trino, sql], capture_output=True, text=True, timeout=180)  # noqa: S603 - fixed wrapper
    except subprocess.TimeoutExpired as exc:
        raise SourceUnreadable(f"trino did not answer within {exc.timeout:g}s") from exc
    except OSError as exc:
        raise SourceUnreadable(f"trino wrapper unrunnable ({trino}): {exc}") from exc
    if proc.returncode != 0:
        raise SourceUnreadable(f"trino exit {proc.returncode}: {(proc.stderr or '').strip()[:200]}")
    return [row for row in csv.reader(io.StringIO(proc.stdout)) if row]


def intercom_conversation(conv_id: str) -> Mapping[str, Any] | None:
    """GET one conversation, read-only, with the gateway's Intercom token."""
    token = (os.environ.get("MUSOAI_INTERCOM_TOKEN") or "").strip()
    if not token:
        raise RuntimeError("MUSOAI_INTERCOM_TOKEN is not set")
    url = f"{INTERCOM}/conversations/{urllib.parse.quote(str(conv_id))}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}",
                                              "Accept": "application/json",
                                              "Intercom-Version": "2.11"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:  # noqa: S310 - constant https host
            return json.loads(resp.read() or b"null")
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"intercom {exc.code}") from exc


def clickup_task_live(task_id: str) -> Mapping[str, Any] | None:
    """GET one ClickUp task through the shared throttled client."""
    token = lanes.clickup_token()
    if not token:
        raise RuntimeError("CLICKUP_API_KEY / MUSOAI_CLICKUP_API_KEY is not set")
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from lib import clickup_client  # noqa: PLC0415 - optional at import time

    try:
        _status, body = clickup_client.shared(token).request("GET", f"/task/{task_id}")
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        raise
    if not isinstance(body, dict):
        raise SourceUnreadable(f"clickup /task/{task_id} returned no task object")
    return body
