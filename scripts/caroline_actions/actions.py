"""The four verbs: read facts, apply policy, write the ledger, return one JSON object.

The caller (the support-tools plugin) passes the VERIFIED Intercom author email and the conversation
id it derived from the trusted session key; neither comes from the model or the message body.

Sends: none. A verb returns `reply_line` (approved wording, verbatim) for Caroline to use in her reply,
and only while the lines switch is ON (LINES_ENABLED_FILE exists). While the freeze holds the file is
absent: every decision is still computed and ledgered, `reply_line` is null and `lines_locked` is true.
"""

from __future__ import annotations

import hashlib
import os
import re
from datetime import datetime, timezone
from typing import Any, Callable, Optional

from . import facts as facts_mod
from . import ledger, policy

LINES_ENABLED_FILE = os.environ.get("CAROLINE_ACTIONS_LINES_ENABLED_FILE", "/etc/hydra/caroline-actions-lines.enabled")
KILL_SWITCH = os.environ.get("CAROLINE_ACTIONS_KILL_SWITCH", "/etc/hydra/caroline-actions.disabled")
CACHE_ROOT = os.environ.get("CAROLINE_ACTIONS_INTERCOM_CACHE", "/root/.openclaw-edge/media/intercom")
ORIGINAL = re.compile(r"^\d+\.(png|jpe?g|pdf|heic|webp)$", re.I)   # same as credit_verify/proof/intercom.py
CONV_RE = re.compile(r"^\d{6,24}$")
UUID_RE = facts_mod.UUID_RE
MAX_FILES = 30
MAX_BYTES = 25 * 1024 * 1024

FactsLoader = Callable[[str], facts_mod.Facts]


def lines_enabled() -> bool:
    return os.path.exists(LINES_ENABLED_FILE)


def _now(now: Optional[datetime]) -> datetime:
    return now or datetime.now(timezone.utc)


def _finish(db, d: policy.Decision, *, verb: str, conv: Optional[str], email: str, f: facts_mod.Facts,
            now: datetime, extra: Optional[dict] = None) -> dict[str, Any]:
    """Apply the lines switch, ledger the outcome, build the result."""
    out = d.as_dict()
    out.update(extra or {})
    out["lines_locked"] = False
    if d.refusals:
        outcome = "refused"
        out["reply_line"], out["line_id"] = None, None
    elif d.line_id and not lines_enabled():
        outcome = "line_withheld_locked"
        out["lines_locked"] = True
        out["reply_line"] = None
    elif d.line_id:
        # Check-and-record under one write lock: two racing calls can never both be offered a line.
        row = ledger.offer_line(db, user_id=f.user_id, now=now, verb=verb, conv_id=conv, email=email,
                                line_id=d.line_id, refusals=[], request_ids=d.request_ids, claim_ids=d.claim_ids,
                                facts=f.as_dict(), detail=extra)
        if row is not None:
            out.update(outcome="line_offered", ledger_row=row, user_id=f.user_id)
            return out
        d.refusals = ["caroline_line_within_7d"]
        out.update(refusals=list(d.refusals), reply_line=None, line_id=None)
        outcome = "refused"
    else:
        outcome = {"doc-intake": "recorded", "merge-intake": "filed", "handoff": "handed_off"}.get(verb, "recorded")
    out["ledger_row"] = ledger.record(db, verb=verb, outcome=outcome, conv_id=conv, user_id=f.user_id, email=email,
                                      line_id=None if d.refusals else d.line_id, refusals=d.refusals,
                                      request_ids=d.request_ids, claim_ids=d.claim_ids, facts=f.as_dict(),
                                      detail=extra, now=now)
    out["outcome"] = outcome
    out["user_id"] = f.user_id
    return out


def status(db, *, email: str, conv: Optional[str], topic: str, load: FactsLoader,
           now: Optional[datetime] = None) -> dict[str, Any]:
    now = _now(now)
    f = load(email)
    d = policy.decide_status(f, now, topic=topic)
    return _finish(db, d, verb="status", conv=conv, email=email, f=f, now=now, extra={"topic": topic})


def cached_files(conv: str, root: str = CACHE_ROOT) -> list[str]:
    """The customer's cached original attachments for this conversation (never a path outside it)."""
    if not CONV_RE.match(conv or ""):
        return []
    base = os.path.realpath(os.path.join(root, conv))
    if not base.startswith(os.path.realpath(root) + os.sep) or not os.path.isdir(base):
        return []
    out = []
    for dirpath, _dirs, names in os.walk(base):
        for n in sorted(names):
            p = os.path.join(dirpath, n)
            if ORIGINAL.match(n) and os.path.isfile(p) and not os.path.islink(p):
                out.append(p)
    return sorted(out)


def doc_intake(db, *, email: str, conv: Optional[str], subject: str, load: FactsLoader, root: str = CACHE_ROOT,
               now: Optional[datetime] = None) -> dict[str, Any]:
    """File every cached customer attachment of this conversation into the document reader's intake,
    with the user id and the candidate credit-request (or claim) ids. The document is filed even when
    the user owes proof; only the reply line can be withheld."""
    now = _now(now)
    f = load(email)
    pre = []
    if subject not in ("credit", "claim"):
        pre.append("unsupported_subject")
    if not conv or not CONV_RE.match(conv):
        pre.append("no_conversation")
    if f.identity != "resolved":
        pre.append("identity_unverified")
    files = cached_files(conv or "", root) if not pre else []
    if not pre and not files:
        pre.append("no_cached_attachment")
    if pre:
        d = policy.Decision("doc-intake", refusals=pre)
        return _finish(db, d, verb="doc-intake", conv=conv, email=email, f=f, now=now,
                       extra={"subject": subject, "filed": 0, "already_filed": 0})
    request_ids = [r.id for r in f.requests if r.open] if subject == "credit" else []
    claim_ids = [c.id for c in f.claims if c.status == "pending"] if subject == "claim" else []
    filed = already = skipped = 0
    for p in files[:MAX_FILES]:
        try:
            size = os.path.getsize(p)
            if size <= 0 or size > MAX_BYTES:
                skipped += 1
                continue
            with open(p, "rb") as fh:
                digest = hashlib.sha256(fh.read()).hexdigest()
        except OSError:
            skipped += 1
            continue
        if ledger.queue_doc(db, conv_id=conv, path=p, sha256=digest, size=size, subject=subject, user_id=f.user_id,
                            email=email, request_ids=request_ids, claim_ids=claim_ids, now=now):
            filed += 1
        else:
            already += 1
    d = policy.decide_doc_reply(f, now, subject=subject)
    d.request_ids, d.claim_ids = request_ids, claim_ids
    if filed + already == 0:
        d.refusals = ["no_cached_attachment"]
        d.line_id = d.reply_line = None
    return _finish(db, d, verb="doc-intake", conv=conv, email=email, f=f, now=now,
                   extra={"subject": subject, "filed": filed, "already_filed": already, "skipped": skipped,
                          "files_over_cap": max(0, len(files) - MAX_FILES)})


def merge_intake(db, *, email: str, conv: Optional[str], kind: str, keep: str, others: list[str],
                 load: FactsLoader, now: Optional[datetime] = None) -> dict[str, Any]:
    """Check a merge request and open a to_file row. The plugin then files the ClickUp merge ticket
    (create_ticket, which stamps merge_intake) and calls merge_record with its id. Never executes."""
    now = _now(now)
    f = load(email)
    keep = (keep or "").strip().lower()
    others = [o.strip().lower() for o in others if o and o.strip()]
    bad = [x for x in [keep, *others] if x and not UUID_RE.match(x)]
    d = policy.decide_merge_intake(f, now, kind=kind, keep=keep, others=others, filed_within_7d=None)
    if bad:
        d.refusals.append("not_profile_ids")
    extra: dict[str, Any] = {"kind": kind, "keep": keep, "others": others}
    if not d.refusals:
        # Dedupe check and the to_file row in ONE write transaction (no check-then-insert race).
        row, existing = ledger.merge_claim(db, conv_id=conv, user_id=f.user_id, kind=kind, keep=keep, others=others,
                                           now=now)
        if row is not None:
            extra["merge_row"] = row
            extra["next"] = "file_ticket"
        elif existing == "in_flight":
            d.refusals.append("merge_in_flight")
        else:
            d.refusals.append("already_filed_within_7d")
            extra["ticket_id"] = existing
    return _finish(db, d, verb="merge-intake", conv=conv, email=email, f=f, now=now, extra=extra)


def merge_record(db, *, email: str, conv: Optional[str], row: int, ticket_id: Optional[str], ok: bool,
                 now: Optional[datetime] = None) -> dict[str, Any]:
    now = _now(now)
    closed = ledger.merge_close(db, row, ticket_id=ticket_id, ok=ok, now=now)
    rid = ledger.record(db, verb="merge-record", outcome="recorded" if closed else "refused", conv_id=conv,
                        user_id=None, email=email, refusals=[] if closed else ["unknown_or_closed_row"],
                        detail={"merge_row": row, "ticket_id": ticket_id, "ok": ok}, now=now)
    return {"action": "merge-record", "recorded": closed, "ledger_row": rid,
            "refusals": [] if closed else ["unknown_or_closed_row"], "reply_line": None}


def handoff(db, *, email: str, conv: Optional[str], reason: str, summary: str, load: FactsLoader,
            now: Optional[datetime] = None) -> dict[str, Any]:
    """Hand a case Caroline cannot decide to the credit-trust board queue (idempotent per conversation
    and reason for 7 days). A handoff works even when the identity is unresolved: a person looks."""
    now = _now(now)
    f = load(email)
    conv = conv or ""
    d = policy.decide_handoff(f, reason=reason, already=False)
    if not conv:
        d.refusals.append("no_conversation")
    extra: dict[str, Any] = {"reason": reason}
    if not d.refusals:
        clean = re.sub(r"\s+", " ", re.sub(r"\S+@\S+", "<email>", summary or ""))[:500]
        # Dedupe check and insert in ONE write transaction.
        hid = ledger.handoff_claim(db, conv_id=conv, user_id=f.user_id, reason=reason, request_ids=d.request_ids,
                                   claim_ids=d.claim_ids, summary=clean, now=now)
        if hid is None:
            d.refusals.append("already_handed_off_within_7d")
        else:
            extra["handoff_id"] = hid
    return _finish(db, d, verb="handoff", conv=conv, email=email, f=f, now=now, extra=extra)


def default_loader(db) -> FactsLoader:
    """The production facts loader (Trino, verify ledger, proof-on-file, account gate, IDP list, admin)."""
    def profile_name(pid: str) -> Optional[str]:
        from credit_review import admin as admin_api
        p = admin_api.profile(admin_api.AdminClient(), pid)
        name = p.get("name") or (p.get("profile") or {}).get("name")
        return str(name).strip() if name else None

    def load(email: str) -> facts_mod.Facts:
        return facts_mod.load(email, caroline_last_line=lambda uid: ledger.last_line_at(db, uid),
                              profile_name=profile_name)
    return load
