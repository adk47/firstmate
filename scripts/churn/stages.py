"""Stage rules for the support-churn signal: pure, no I/O, no network.

The rules are the ones the 60-day measurement used (Fable report 2026-11-03,
firstmate/data/support-churn-winback-fable-c1/report.md section 1.2, code in that
same directory's measure/analyze.py - neither is in this repo), kept verbatim so
`support_state.py --churned-since 60d` reproduces the report's numbers (definition of done) and so the PREVENT signal
uses the SAME definition of "the ball was with us" as the thing it prevents.

Three stage questions, in report order:

  T1  the customer's last message is unanswered >= 24 h, or we promised a
      follow-up and none came, or they filed proof and we sent nothing after it
  T2  the thread was open and we spoke last with a hold (no ask): they were
      told to wait
  T3  no thread, but an open credit/claim request older than 48 h

Everything here is deterministic and unit-tested (scripts/tests/test_churn_risk.py).
The regex tables are deliberately the report's, not a fresh guess: a changed
regex changes the served number, so it changes with a ruling, not a refactor.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Iterable

DAY = 86400.0

# --- report section 1.2 regexes, verbatim -----------------------------------
PROMISE_RE = re.compile(
    r"business days?|follow up|follow-up|hear back|flagged|submitted this to the team|"
    r"pulling in a teammate|12-24 hours|priority look|team will|"
    r"we.ll (look|check|get back|update|let you know)|will (look|check|get back|update|let you know)|"
    r"working on it|in the meantime|as soon as|keep you (posted|updated)",
    re.I,
)
ASK_RE = re.compile(
    r"\b(send|attach|upload|provide|share|reply with|let us know|could you|can you|"
    r"please (send|provide|share|confirm))\b|"
    r"\b(document|documents|proof|screenshot|link to|invoice|which platform|what is your)",
    re.I,
)
COURTESY_RE = re.compile(
    r"^(ok|okay|oki|k|thanks?|thank you|thx|ty|great|perfect|got it|cool|awesome|good|all good|"
    r"it.s all good|goated|cheers|appreciate|no problem|sounds good|will do|done|yes|yep|yeah|sure|"
    r"understood|noted|alright|fine|gracias|merci|danke|grazie|\U0001f44d|\U0001f64f)",
    re.I,
)

# Cause classes, in the report's precedence order (credits > proof > merge/claim
# > analytics > billing > login), matched over the CUSTOMER's own words.
CLASS_RES: tuple[tuple[str, str], ...] = (
    ("analytics_stale_wrong", r"analytic|stats?\b|statistic|stream(s|ing)? (count|number|haven|not|aren|don)|"
                              r"not updat|haven.t updated|hasn.t updated|no update|"
                              r"data (is|are) (wrong|missing|stale|old)|missing data|playlist|"
                              r"wrong (number|data)|inaccurate|not accurate|not refresh"),
    ("billing_confusion", r"refund|charg|bill|invoice|payment|renew|subscription|cancel|price|pricing|"
                          r"annual|yearly|monthly|double|twice|dispute|chargeback|money back|unsubscribe|founding"),
    ("merge_claim_stuck", r"\bmerg|duplicate|claim|ownership|verify (my )?profile|two profiles|same person|split"),
    ("proof_sent_no_update", r"proof|screenshot|attached|attachment|document|evidence|sent (you|the|it)|"
                             r"contract|split sheet|here is|here are"),
    ("credits_not_approved", r"credit|approv|pending|verif|role|producer|songwriter|engineer|mixed|mastered|"
                             r"wrote|add(ed|ing)? (my|the|a) (song|track|credit)|catalog|discograph"),
    ("login_access", r"log ?in|password|access|vpn|locked|can.t (get|sign)|sign in|2fa|two.factor"),
)
CLASS_ORDER = ("credits_not_approved", "proof_sent_no_update", "merge_claim_stuck",
               "analytics_stale_wrong", "billing_confusion", "login_access")

# Issue kinds. Order is the tie-break when a user has several: the first is the
# primary class the alert names and the lane it routes to.
KIND_NO_REPLY = "no_reply"
KIND_PROMISE = "promise_not_kept"
KIND_OPEN_TOLD_WAIT = "open_told_wait"
KIND_PROOF_NO_UPDATE = "proof_sent_no_update"
KIND_PENDING_REQUEST = "pending_request"
KIND_PENDING_CLAIM = "pending_claim"
KIND_PENDING_TASK = "pending_task"      # the ClickUp merge/claim intake, still open

TIER1_KINDS = (KIND_NO_REPLY, KIND_PROMISE, KIND_PROOF_NO_UPDATE)
TIER2_KINDS = (KIND_OPEN_TOLD_WAIT,)
TIER3_KINDS = (KIND_PENDING_REQUEST, KIND_PENDING_CLAIM, KIND_PENDING_TASK)


@dataclass
class Thresholds:
    """The policy's thresholds, in seconds/days, already converted."""

    customer_last_hours: float = 24.0
    request_pending_hours: float = 48.0
    promise_no_followup_hours: float = 48.0
    thread_min_age_days: float = 2.0
    churned_paid_priority_days: float = 30.0
    thread_lookback_days: float = 120.0
    # analyze.py's extra gate on the open-told-wait branch: a thread open at the anchor
    # only counts if it was touched inside this window (an old open thread we forgot
    # about is not the same signal as one we were still holding)
    open_thread_recent_days: float = 45.0

    @classmethod
    def from_policy(cls, policy: dict[str, Any] | None) -> "Thresholds":
        t = (policy or {}).get("thresholds") or {}
        d = cls()
        out = cls()
        for f in ("customer_last_hours", "request_pending_hours", "promise_no_followup_hours",
                  "thread_min_age_days", "churned_paid_priority_days",
                  "thread_lookback_days", "open_thread_recent_days"):
            v = t.get(f, getattr(d, f))
            try:
                setattr(out, f, float(v))
            except (TypeError, ValueError):
                setattr(out, f, getattr(d, f))
        return out


@dataclass
class Issue:
    """One reason this user is waiting on us, with the evidence a human can check."""

    kind: str
    cause_class: str
    evidence: str
    days: float = 0.0

    def as_dict(self) -> dict[str, Any]:
        return {"kind": self.kind, "class": self.cause_class, "evidence": self.evidence,
                "days": round(self.days, 2)}

    @property
    def label(self) -> str:
        return f"{self.kind}:{self.cause_class}"


@dataclass
class Classification:
    issues: list[Issue] = field(default_factory=list)
    conv_ids: list[str] = field(default_factory=list)
    open_request_ids: list[str] = field(default_factory=list)
    ball_days: float = 0.0

    @property
    def tier(self) -> str | None:
        kinds = {i.kind for i in self.issues}
        if kinds & set(TIER1_KINDS):
            return "T1"
        if kinds & set(TIER2_KINDS):
            return "T2"
        if kinds & set(TIER3_KINDS):
            return "T3"
        return None

    @property
    def primary(self) -> Issue | None:
        """The issue the alert names / the lane it routes to: the first, in stage order."""
        if not self.issues:
            return None
        rank = {k: n for n, k in enumerate(TIER1_KINDS + TIER2_KINDS + TIER3_KINDS)}
        return sorted(self.issues, key=lambda i: rank.get(i.kind, 99))[0]

    @property
    def cause_class(self) -> str | None:
        p = self.primary
        return p.cause_class if p else None


def days_between(later: float, earlier: float) -> float:
    return max(0.0, (later - earlier) / DAY)


def ts_to_iso(ts: float | None) -> str | None:
    if not ts:
        return None
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def iso_to_ts(value: Any) -> float:
    """Epoch seconds from an ISO-ish string or epoch number; 0.0 when unreadable."""
    if value in (None, ""):
        return 0.0
    if isinstance(value, (int, float)):
        return float(value) / (1000.0 if value > 1e11 else 1.0)
    s = str(value).strip().replace(" UTC", "+00:00")
    if re.fullmatch(r"\d+(\.\d+)?", s):
        return float(s) / (1000.0 if len(s) >= 13 else 1.0)
    try:
        d = datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        for fmt in ("%Y-%m-%d %H:%M:%S.%f%z", "%Y-%m-%d %H:%M:%S%z", "%Y-%m-%d %H:%M:%S"):
            try:
                d = datetime.strptime(s, fmt)
                break
            except ValueError:
                continue
        else:
            return 0.0
    if d.tzinfo is None:
        d = d.replace(tzinfo=timezone.utc)
    return d.timestamp()


def classify_text(text: str) -> str:
    """The cause class of a free-text blur (a ClickUp intake task, a survey remark)."""
    body = (text or "").lower()
    for name, pat in CLASS_RES:
        if re.search(pat, body):
            return name
    return "other"


def is_courtesy(text: str) -> bool:
    """The report's courtesy-close filter: short, no question, and starts with a thanks/ok word."""
    body = (text or "").strip().lower()
    return bool(COURTESY_RE.match(body)) and len(body) < 120 and "?" not in body


def is_promise(text: str) -> bool:
    return bool(PROMISE_RE.search(text or ""))


def is_ask(text: str) -> bool:
    """An ask is an ask only when it is not also a promise (report analyze.py: ask = ASK and not promise)."""
    return bool(ASK_RE.search(text or "")) and not is_promise(text)


def classify_thread(events: list[dict[str, Any]], anchor: float, conv_id: str,
                    open_state: bool, created_at: float,
                    t: Thresholds, updated_at: float = 0.0) -> list[Issue]:
    """The report's per-thread rules, at `anchor`: returns the issues, if any.

    `events` are `{"at", "who": contact|us, "body"}` sorted ascending. Only the
    last event at or before the anchor decides (exactly like analyze.py), so a
    thread we answered afterwards is not an issue at that anchor.
    """
    before = [e for e in events if (e.get("at") or 0) <= anchor]
    if not before:
        return []
    last = before[-1]
    us_last = next((e for e in reversed(before) if e.get("who") == "us"), None)
    customer_text = " \n".join(e.get("body") or "" for e in before if e.get("who") == "contact")
    hits = [name for name, pat in CLASS_RES if re.search(pat, customer_text.lower())]
    cause = next((c for c in CLASS_ORDER if c in hits), "other")
    promise = is_promise((us_last or {}).get("body") or "")
    issues: list[Issue] = []

    if last.get("who") == "contact":
        wait = days_between(anchor, last.get("at") or 0)
        threshold = t.customer_last_hours / 24.0
        if wait >= threshold:
            if is_courtesy(last.get("body") or "") and not promise:
                return []          # "thanks" after a resolution: not an issue
            if is_courtesy(last.get("body") or "") and promise:
                issues.append(Issue(KIND_PROMISE, cause,
                                    f"intercom {conv_id}: we promised a follow-up "
                                    f"({(us_last or {}).get('body', '')[:80]!r}), none came in {wait:.0f}d",
                                    wait))
            else:
                issues.append(Issue(KIND_NO_REPLY, cause,
                                    f"intercom {conv_id}: customer spoke last, waited {wait:.1f}d "
                                    f"(state {'open' if open_state else 'closed'})", wait))
    elif (open_state and days_between(anchor, created_at) >= t.thread_min_age_days
          and (not updated_at or updated_at >= anchor - t.open_thread_recent_days * DAY)):
        # analyze.py's freshness gate: the thread must have been touched within
        # open_thread_recent_days of the anchor (0 = unknown, and then we do not drop it)
        # We spoke last on a thread that is still open: a hold unless we asked
        # them something (then the ball was with the customer, not with us).
        if is_ask((us_last or {}).get("body") or ""):
            return []
        wait = days_between(anchor, last.get("at") or 0)
        issues.append(Issue(KIND_OPEN_TOLD_WAIT, cause,
                            f"intercom {conv_id}: open, we spoke last "
                            f"({'promise' if promise else 'hold'}), opened "
                            f"{days_between(anchor, created_at):.0f}d before", wait))
    return issues


def classify_requests(open_requests: list[dict[str, Any]], pending_claims: list[dict[str, Any]],
                      anchor: float, tells: list[float], proof_filed: list[float],
                      t: Thresholds, *, require_no_note: bool = False) -> tuple[list[Issue], list[str]]:
    """Credit/claim/proof stage, at `anchor` (report analyze.py section 5-6).

    `tells` are the timestamps of verify-family notes we sent them; `proof_filed`
    the proof_intake arrivals. Returns (issues, open request ids).
    """
    issues: list[Issue] = []
    ids: list[str] = []
    threshold = t.request_pending_hours / 24.0
    oldest = 0.0
    for r in open_requests:
        ids.append(str(r.get("request_id")))
        created = iso_to_ts(r.get("created_at"))
        if created:
            oldest = created if not oldest else min(oldest, created)
    if ids and oldest and days_between(anchor, oldest) >= threshold:
        age = days_between(anchor, oldest)
        before = [x for x in tells if x and x <= anchor]
        proof_before = [x for x in proof_filed if x and x <= anchor]
        if proof_before and not [x for x in before if x > max(proof_before)]:
            issues.append(Issue(KIND_PROOF_NO_UPDATE, "proof_sent_no_update",
                                f"{len(ids)} open credit requests, proof filed {len(proof_before)}x, "
                                f"nothing sent after the proof; oldest request {age:.0f}d", age))
        elif not (require_no_note and told_since(before, oldest)):
            # the PREVENT signal (risk class b) wants the ones we never told: a user
            # who has already had a status note about this wait is being handled.
            issues.append(Issue(KIND_PENDING_REQUEST, "credits_not_approved",
                                f"{len(ids)} open credit requests, oldest {age:.0f}d; "
                                f"told {len(before)}x", age))
    for c in pending_claims:
        created = iso_to_ts(c.get("created_at"))
        if not created:
            continue
        age = days_between(anchor, created)
        if age >= threshold:
            ids.append(str(c.get("claim_id") or c.get("id") or ""))
            if require_no_note and told_since(tells, created):
                continue          # a status note after the claim was opened: handled
            issues.append(Issue(KIND_PENDING_CLAIM, "merge_claim_stuck",
                                f"pending claim {c.get('claim_id') or c.get('id')}, oldest {age:.0f}d", age))
    return issues, [i for i in ids if i]


def classify_tasks(tasks: list[dict[str, Any]], anchor: float, tells: list[float],
                   t: Thresholds) -> list[Issue]:
    """The ClickUp merge/claim intake: a task still open past the threshold, with no
    note to the user since it was opened, is the same dropped ball as a pending row.

    `tasks` are `{"id", "status", "created", "updated", "text", "url"}` with
    `created`/`updated` in epoch ms (ClickUp's own unit).
    """
    issues: list[Issue] = []
    threshold = t.request_pending_hours / 24.0
    for task in tasks:
        created = iso_to_ts(task.get("created"))
        if not created:
            continue
        age = days_between(anchor, created)
        if age < threshold:
            continue
        if any(x and x >= created for x in tells):
            continue                      # we told them something after it was opened
        issues.append(Issue(KIND_PENDING_TASK, classify_text(task.get("text") or ""),
                            f"clickup task {task.get('id')} ({task.get('status')}) open {age:.0f}d: "
                            f"{(task.get('text') or '')[:120]}", age))
    return issues


def told_since(tells: list[float], since: float) -> bool:
    """Did we send them anything at or after `since` (the status-note test in risk class b)?"""
    return any(x and x >= since for x in tells)


def classify_user(*, anchor: float, threads: Iterable[dict[str, Any]],
                  open_requests: list[dict[str, Any]] | None = None,
                  pending_claims: list[dict[str, Any]] | None = None,
                  tasks: list[dict[str, Any]] | None = None,
                  tells: list[float] | None = None, proof_filed: list[float] | None = None,
                  t: Thresholds, require_no_note: bool = False) -> Classification:
    """Full stage for one user. `threads` are the pre-read conversations.

    Each thread dict carries: id, created_at, updated_at, state, events (sorted,
    with a `who` of contact|us and a body). Threads opened after the anchor are
    not a cause of it, and threads that were already ancient are skipped, as in
    the report's analyze.py.
    """
    out = Classification()
    for th in threads:
        created = th.get("created_at") or 0
        if created and created > anchor + DAY:
            continue
        if created and created < anchor - 90 * DAY and (th.get("updated_at") or 0) < anchor - 60 * DAY:
            continue
        issues = classify_thread(th.get("events") or [], anchor, str(th.get("id")),
                                 bool(th.get("state") == "open"), created, t,
                                 updated_at=float(th.get("updated_at") or 0))
        if issues:
            out.issues.extend(issues)
            out.conv_ids.append(str(th.get("id")))
    req_issues, ids = classify_requests(open_requests or [], pending_claims or [], anchor,
                                        tells or [], proof_filed or [], t,
                                        require_no_note=require_no_note)
    out.issues.extend(req_issues)
    out.issues.extend(classify_tasks(tasks or [], anchor, tells or [], t))
    out.open_request_ids = ids
    if out.issues:
        out.ball_days = max(i.days for i in out.issues)
    return out


def risk_kinds(c: Classification, t: Thresholds) -> list[str]:
    """The PREVENT signal's three shapes (report section 4 item 1 / firstmate spec item 2).

    (a) a customer-last thread past the 24 h threshold,
    (b) a pending credit/claim request past 48 h with no status note,
    (c) a promise line with no follow-up inside 48 h.
    """
    kinds: list[str] = []
    for i in c.issues:
        if i.kind == KIND_NO_REPLY:
            kinds.append("customer_last")
        elif i.kind == KIND_PROMISE:
            # a promise issue is a customer-last thread whose "thanks" came after our
            # promise: it is risk class (a) from the 24 h mark, and only becomes (c)
            # once the follow-up is 48 h late. Without this a T1 row carried no risk
            # kind for the 24-48 h window, so the cancel page skipped a real user.
            kinds.append("promise_no_followup" if i.days * 24.0 >= t.promise_no_followup_hours
                         else "customer_last")
        elif i.kind == KIND_OPEN_TOLD_WAIT:
            kinds.append("told_to_wait")
        elif i.kind in (KIND_PENDING_REQUEST, KIND_PENDING_CLAIM, KIND_PENDING_TASK):
            kinds.append("request_pending")
        elif i.kind == KIND_PROOF_NO_UPDATE:
            kinds.append("proof_no_update")
    return sorted(set(kinds))
