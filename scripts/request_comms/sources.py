#!/usr/bin/env python3
"""Where the open requests ARE: one reader per owning store, one normalised state vocabulary.

The driver never invents a request and never guesses a state. Each source is read from the
store that already owns it:

  credit   postgresql_core.public.credit_requests      (replica, read-only)
  claim    postgresql_core.public.claiming             (replica, read-only)
  merge    ClickUp tickets tagged action:profile-merge / action:track-merge (support list)
  erasure  /var/lib/hydra-gdpr/erasure.sqlite  erasure_requests   (the GDPR pipeline's register)
  refund   ClickUp tickets carrying the tags in the policy (`refund.tags`); unconfigured today

Two rules, both fail-closed:

  * **A source that cannot be read is UNKNOWN, never empty.** It is reported as `unreadable`
    (or `unconfigured` when the store we expect is not there), the run exits non-zero, and NO
    message is sent for that type — a silent empty read would tell a user "nothing is happening"
    while we are blind to their request.
  * **A lane with no reader yet is `disabled`, not a failure.** `merge` and `refund` have no
    ticket->account identity resolver, so they are off on every tick by design. They stay visible
    in the summary but do not fail the run: a permanently red hourly unit makes a real outage in
    an enabled source indistinguishable from the expected gap.
  * **A state we do not recognise is `unknown`** and is never messaged: the copy only exists for
    the states in policies/request-status-lines.json.

`waiting_on` is `user` when the request is waiting for the customer, `us` otherwise. When the
S0 sentinel evaluation store exists it may refine that per request_ref (its `waiting_on`), and
when it is missing, stale or unreadable the owning table's answer stands — the sentinel is an
enrichment, never a dependency.
"""
from __future__ import annotations

import csv
import io
import json
import os
import re
import sqlite3
import subprocess
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Callable, Iterable

Query = Callable[[str], "list[list[str]]"]

TRINO = "/opt/hydra/scripts/trino-query.sh"
GDPR_STORE = "/var/lib/hydra-gdpr/erasure.sqlite"
# The register's classes whose request IS "remove my personal data", i.e. the only ones the approved
# acknowledgement (gdpr-ack-v2-1101) may be sent to. It opens "we have your request to remove your personal
# data from Muso", so a `privacy_access` row (Art. 15: they asked for a COPY, and the pipeline answers it
# captain/counsel with no hide) or a `dmca_takedown` row (a rights-holder's copyright notice) would be told
# they asked for something they never asked for. This is the SAME tuple as
# `gdpr_pipeline.copy.ASK_APPROVED_CLASSES`, not the wider `run.ERASURE_FAMILY`: a `legal_threat` row is in the
# erasure FAMILY (it gets the erasure pipeline's handling) but it is not a request to remove personal data, so the
# erasure ack's words are not true of it either. Adding a class releases customer-facing copy, so it is added in the
# PR that carries that class's ruling, never in advance and never by widening this tuple during a bug fix.
ERASURE_ACK_CLASSES = ("privacy_erasure",)
SENTINEL_STORE = "/var/lib/hydra/sentinel/evaluations.sqlite"
CLICKUP_LIST_ID = "901000600160"          # the support-tools ticket list (same default as merge-outcome-notify.py)
MERGE_TAGS = ("action:profile-merge", "action:track-merge")
OPEN_STATUSES = ("open", "in progress", "in review", "waiting", "to do", "pending")

# raw owning-table status -> (our state, waiting_on, terminal?)
CREDIT_STATES = {
    "processing": ("verifying", "us", False),
    "unverified": ("verifying", "us", False),
    "user_verification_needed": ("need_you", "user", False),
    "approved": ("decided", "", True),
    "rejected": ("decided", "", True),
    "withdrawn": ("decided", "", True),
}
CREDIT_DECIDED = ("approved", "rejected", "withdrawn")
CLAIM_DECIDED = ("processed", "rejected", "reverted", "closed")
CLAIM_STATES = {
    "pending": ("received", "us", False),
    "processed": ("decided", "", True),
    "reverted": ("decided", "", True),
    "closed": ("decided", "", True),
    "processing": ("verifying", "us", False),
    "in_review": ("verifying", "us", False),
    "approved": ("decided", "", True),
    "rejected": ("decided", "", True),
    "cancelled": ("decided", "", True),
}
# The ClickUp workflow status of a merge ticket. The OUTCOME tag is not read here: the outcome
# message belongs to merge-outcome-notify (S5 in the sender map), never to this driver.
MERGE_TICKET_STATES = {
    "to do": ("received", "us", False),
    "open": ("received", "us", False),
    "in progress": ("verifying", "us", False),
    "in review": ("verifying", "us", False),
    "waiting": ("verifying", "us", False),
    "complete": ("decided", "", True),
    "closed": ("decided", "", True),
    "done": ("decided", "", True),
}
STATES = ("received", "verifying", "need_you", "decided", "unknown")


@dataclass
class Request:
    type: str
    id: str
    user_id: str
    state: str
    waiting_on: str
    created_at: str = ""
    updated_at: str = ""
    terminal: bool = False
    email: str = ""
    detail: dict[str, Any] = field(default_factory=dict)

    @property
    def ref(self) -> str:
        return f"{self.type}:{self.id}"

    @property
    def cap_key(self) -> str:
        """The identity the one-message-per-day promise is made to.

        Account ids are numeric; an erasure request arrives keyed by its requester's email or a
        contact id, so a raw comparison let the same person receive an erasure ack AND a credit
        status on one day (`sent_today` saw two "users"). Email-shaped keys are normalised to
        `email:<lowered>`; the driver resolves them to the account id when the replica can.
        """
        uid = str(self.user_id or "").strip()
        return f"email:{uid.lower()}" if "@" in uid else uid


class LaneDisabled(Exception):
    """This lane has no reader yet, by design. NOT a failure: see the module docstring."""


@dataclass
class SourceReport:
    name: str
    status: str                      # ok | unreadable | unconfigured | disabled
    count: int = 0
    error: str = ""
    stale_open: int = -1             # open rows OUTSIDE the scope window (-1 = not measured)


def _ts(v: Any) -> str:
    """Any owning-table timestamp -> 'YYYY-MM-DDTHH:MM:SSZ' ('' when unreadable)."""
    s = str(v or "").strip().replace(" UTC", "Z").replace(" ", "T")
    if not s:
        return ""
    s = s[:19]
    return s + "Z" if len(s) == 19 and not s.endswith("Z") else s


def trino_query(sql: str, cmd: str = TRINO) -> list[list[str]]:
    """One read-only replica query through the deployed wrapper; unreadable RAISES (never [])."""
    try:
        p = subprocess.run([cmd], input=sql, capture_output=True, text=True, timeout=300, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        raise RuntimeError(f"replica read did not run: {type(exc).__name__}") from exc
    if p.returncode:
        raise RuntimeError(f"replica read failed: {(p.stderr or '').strip()[-160:]}")
    return [row for row in csv.reader(io.StringIO("\n".join(
        ln for ln in (p.stdout or "").splitlines() if ln.startswith('"'))))]


def _pick(row: list[str], idx: int, default: str = "") -> str:
    return row[idx] if len(row) > idx else default


_UUID_RE = re.compile(r"[0-9a-fA-F][0-9a-fA-F-]{7,63}")


def _is_id(x: str) -> bool:
    """A row id — digits (bigint) or a uuid (credit_requests.id IS a uuid).

    Also how the CSV HEADER row is skipped: `--output-format CSV` emits the column names as the
    first quoted line, so 'id' would otherwise read as a (very odd) request. Digit-only was WRONG
    here and would have skipped every credit request; the readers below are what caught it.
    """
    x = str(x or "").strip()
    return x.isdigit() or bool(_UUID_RE.fullmatch(x))


def _is_uid(x: str) -> bool:
    """A user id is a core bigint, always digits."""
    return str(x or "").strip().isdigit()


def _long_date(ts: str) -> str:
    """'2026-11-03' -> '3 November 2026' (the ack's `{date}` slot, from the request's own arrival)."""
    try:
        d = datetime.strptime(str(ts)[:10], "%Y-%m-%d")
    except ValueError:
        return ""
    return f"{d.day} {d.strftime('%B %Y')}"


def _scope_sql(open_statuses: tuple[str, ...], *, open_days: int, decided_days: int) -> str:
    """The rows a STATUS feed is responsible for.

    An OPEN request is in scope while its owning row moved in `open_days`; a decided one is in
    scope for `decided_days`. The universe is much larger than that — 100,938 credit requests are
    open today, 62,268 of them untouched for 91-365 days — and messaging a year-old abandoned
    request is a product decision, not a driver default. Rows outside the window are COUNTED
    (`Sources.stale_open`) so the number is never hidden, and widening it is one policy key.
    """
    marks = ", ".join(f"'{x}'" for x in open_statuses)
    return (f"(status NOT IN ({marks}) AND coalesce(updatedat, createdat) >= "
            f"current_timestamp - interval '{int(open_days)}' day) "
            f"OR (status IN ({marks}) AND coalesce(updatedat, createdat) >= "
            f"current_timestamp - interval '{int(decided_days)}' day)")


def _id_sql(ids: tuple[str, ...]) -> str:
    """`CAST(id AS varchar) IN (...)`; ids are uuids/digits that came from our own ledger."""
    marks = ",".join("'" + str(i).replace("'", "''") + "'" for i in ids)
    return f"CAST(id AS varchar) IN ({marks})"


def credit_requests(query: Query, *, days: int = 180, open_days: int = 30,
                    decided_days: int = 14, ids: tuple[str, ...] = ()) -> list[Request]:
    """Open + recently decided credit requests (the replica). Status is the ONLY state input."""
    rows = query(
        "SELECT CAST(id AS varchar), CAST(userid AS varchar), status, "
        "coalesce(CAST(createdat AS varchar), ''), coalesce(CAST(updatedat AS varchar), ''), "
        "coalesce(json_extract_scalar(metadata, '$.approvedNotice.noticeSentAt'), ''), "
        "coalesce(json_extract_scalar(spotifytrackartists, '$[0].name'), ''), "
        "coalesce(spotifytracktitle, ''), cast(profileid as varchar) "
        f"FROM postgresql_core.public.credit_requests WHERE deletedat IS NULL "
        # No creation-age bound: an OPEN request created long ago but touched today is exactly the
        # one that just changed state, and a `createdat >= 180 days` guard dropped it before the
        # scope window could consider it — invisible to the driver AND to `stale_open_rows`, which
        # counts by update time. `_scope_sql` is the only window, and it is the tighter one.
        f"AND ({_id_sql(ids) if ids else _scope_sql(CREDIT_DECIDED, open_days=open_days, decided_days=decided_days)})")
    out: list[Request] = []
    for r in rows:
        if len(r) < 5:
            raise RuntimeError("unexpected replica row shape (credit_requests)")
        rid, uid, status = _pick(r, 0), _pick(r, 1), _pick(r, 2)
        if not _is_id(rid) or not _is_uid(uid):
            continue
        state, waiting, terminal = CREDIT_STATES.get(status.lower(), ("unknown", "", False))
        out.append(Request("credit", rid, uid, state, waiting, _ts(_pick(r, 3)), _ts(_pick(r, 4)),
                           terminal, detail={"source": "credit_requests", "raw_status": status,
                                             "notice_sent_at": str(_pick(r, 5) or ""),
                                             "artist_name": str(_pick(r, 6) or ""),
                                             "track_title": str(_pick(r, 7) or ""),
                                             "profile_id": str(_pick(r, 8) or "")}))
    return out


def claim_requests(query: Query, *, days: int = 180, open_days: int = 30,
                   decided_days: int = 14, ids: tuple[str, ...] = ()) -> list[Request]:
    rows = query(
        "SELECT CAST(id AS varchar), CAST(userid AS varchar), status, "
        "coalesce(CAST(createdat AS varchar), ''), coalesce(CAST(updatedat AS varchar), ''), "
        "coalesce(cast(profileid as varchar), '') "
        f"FROM postgresql_core.public.claiming WHERE deletedat IS NULL "
        f"AND ({_id_sql(ids) if ids else _scope_sql(CLAIM_DECIDED, open_days=open_days, decided_days=decided_days)})")
    out: list[Request] = []
    for r in rows:
        if len(r) < 5:
            raise RuntimeError("unexpected replica row shape (claiming)")
        rid, uid, status = _pick(r, 0), _pick(r, 1), _pick(r, 2)
        if not _is_id(rid) or not _is_uid(uid):
            continue
        state, waiting, terminal = CLAIM_STATES.get(status.lower(), ("unknown", "", False))
        out.append(Request("claim", rid, uid, state, waiting, _ts(_pick(r, 3)), _ts(_pick(r, 4)),
                           terminal, detail={"source": "claiming", "raw_status": status,
                                             "profile_id": str(_pick(r, 5) or "")}))
    return out


def account_by_email(emails: Iterable[str], query: Query) -> dict[str, str]:
    """lower(email) -> account id, for the identities an erasure register carries INSTEAD of a user
    id. Only used to unify the daily cap, so it is best-effort and always on a bounded list."""
    want = sorted({str(e).strip().lower() for e in emails if "@" in str(e)})
    out: dict[str, str] = {}
    for i in range(0, len(want), 200):
        chunk = want[i:i + 200]
        marks = ",".join("'" + e.replace("'", "''") + "'" for e in chunk)   # already lowercased
        rows = query("SELECT CAST(id AS varchar), lower(coalesce(email, '')) "
                     f"FROM postgresql_core.public.users WHERE lower(email) IN ({marks}) "
                     "ORDER BY emailconfirmed DESC, id")
        for r in rows:
            if len(r) < 2:
                raise RuntimeError("unexpected replica row shape (users by email)")
            uid, email = _pick(r, 0), _pick(r, 1)
            if _is_uid(uid) and email:
                out.setdefault(email, uid)
    return out


def account_emails(user_ids: Iterable[str], query: Query) -> dict[str, str]:
    """user id -> confirmed core email ('' when none). Only a CONFIRMED address is ever a route."""
    ids = sorted({str(u) for u in user_ids if str(u).isdigit()})
    out: dict[str, str] = {}
    for i in range(0, len(ids), 400):
        chunk = ids[i:i + 400]
        rows = query("SELECT CAST(id AS varchar), lower(coalesce(email, '')), "
                     "coalesce(CAST(emailconfirmed AS varchar), 'false') "
                     f"FROM postgresql_core.public.users WHERE id IN ({','.join(chunk)})")
        for r in rows:
            if len(r) < 3:
                raise RuntimeError("unexpected replica row shape (users)")
            uid, email, confirmed = _pick(r, 0), _pick(r, 1), _pick(r, 2)
            if not _is_uid(uid):
                continue
            out[uid] = email if str(confirmed).lower() in ("true", "1", "t") else ""
    return out


def erasure_requests(store_path: str = GDPR_STORE) -> list[Request]:
    """The GDPR pipeline's register (scripts/gdpr_pipeline/store.py). Missing store = unconfigured."""
    if not os.path.exists(store_path):
        raise FileNotFoundError(store_path)
    db = sqlite3.connect(f"file:{store_path}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    try:
        out: list[Request] = []
        have = {row[1] for row in db.execute("PRAGMA table_info(erasure_requests)")}
        wanted = ["id", "status", "class", "received_at", "due_at", "confirmed_at", "ask_sent_at",
                  "hidden_at", "requester_email", "contact_id", "conversation_id", "updated_at", "pages"]
        cols = [c for c in wanted if c in have]
        if not {"id", "received_at"} <= set(cols):
            raise RuntimeError("erasure_requests has no id/received_at column")
        for r in db.execute(f"SELECT {', '.join(cols)} FROM erasure_requests ORDER BY id"):
            def g(name: str) -> str:
                return str(r[name] or "") if name in cols else ""

            # The ack is ours until it has gone; the written confirmation is the legal class and
            # stays a human hand-off (never this driver's message).
            if g("confirmed_at"):
                state, waiting, terminal = "decided", "", True
            elif not g("ask_sent_at"):
                state, waiting, terminal = "received", "us", False
            else:
                state, waiting, terminal = "verifying", "us", False
            # A class the ack was NOT written for is `unknown`, which the planner holds: never messaged, never
            # guessed at. `not_erasure` is the obvious case; `privacy_access` and `dmca_takedown` are the ones that
            # used to slip through and be told they had asked us to delete their data.
            if g("class") not in ERASURE_ACK_CLASSES:
                state, waiting, terminal = "unknown", "", False
            pages: list[Any] = []
            if "pages" in cols:
                try:
                    pages = list(json.loads(r["pages"] or "[]"))
                except (ValueError, TypeError):
                    pages = []
            received = _ts(g("received_at"))
            out.append(Request("erasure", str(r["id"]), (g("requester_email") or g("contact_id")).strip(),
                               state, waiting, received, _ts(g("updated_at")),
                               terminal, email=g("requester_email"),
                               detail={"source": "erasure_requests", "row_key": str(r["id"]),
                                       "contact_id": g("contact_id"), "conversation_id": g("conversation_id"),
                                       "class": g("class"), "status": g("status"), "raw_status": g("status"),
                                       "due_at": _ts(g("due_at")), "ask_sent_at": _ts(g("ask_sent_at")),
                                       # The ack's fixed slots: no page in their message -> the
                                       # approved "reply with the link" slot applies. A page in the
                                       # message needs the page's name AND the sender's name, which
                                       # the register does not carry: no slot, no ack (held).
                                       "slot": "no_page_link" if not pages else "",
                                       "date": _long_date(received)}))
        return out
    finally:
        db.close()


def ticket_requests(tickets: list[dict[str, Any]], *, typ: str, tag_map: dict[str, tuple[str, str, bool]],
                    state_by_status: dict[str, tuple[str, str, bool]]) -> list[Request]:
    """Normalise ClickUp tasks into requests. `tag_map` wins over the workflow status: a ticket that
    carries a state tag says exactly where it is (status words are ClickUp workflow, not ours)."""
    out: list[Request] = []
    for t in tickets:
        tags = {str(x.get("name") or "").lower() for x in (t.get("tags") or [])}
        status = str((t.get("status") or {}).get("status") or "").lower()
        state, waiting, terminal = state_by_status.get(status, ("unknown", "", False))
        for tag, mapped in tag_map.items():
            if tag.lower() in tags:
                state, waiting, terminal = mapped
                break
        created = t.get("date_created")
        updated = t.get("date_updated")
        created_at = (_ts(datetime.fromtimestamp(int(created) / 1000, timezone.utc).isoformat())
                      if str(created or "").isdigit() else "")
        updated_at = (_ts(datetime.fromtimestamp(int(updated) / 1000, timezone.utc).isoformat())
                      if str(updated or "").isdigit() else "")
        out.append(Request(typ, str(t.get("id") or ""), str(t.get("_user_id") or ""), state, waiting,
                           created_at, updated_at, terminal,
                           detail={"source": "clickup", "ticket": str(t.get("id") or ""),
                                   "raw_status": status, "tags": sorted(tags)}))
    return out


# Columns an S0 evaluation row might stamp itself with. A row we cannot date is a row we cannot
# prove is current, so it is ignored rather than trusted.
_SENTINEL_TS_COLS = ("evaluated_at", "at", "updated_at", "observed_at", "created_at", "ts")


def _epoch(v: Any) -> float | None:
    """A sentinel timestamp -> epoch seconds, or None when it cannot be read."""
    s = str(v or "").strip()
    if not s:
        return None
    try:
        n = float(s)
    except ValueError:
        n = 0.0
    if n > 0:
        return n / 1000.0 if n > 1e11 else n          # milliseconds vs seconds
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def sentinel_waiting(path: str = SENTINEL_STORE, *, max_age_h: float = 6.0,
                     now: float | None = None) -> dict[str, str]:
    """request_ref -> waiting_on, from the S0 evaluation store when it exists and is fresh.

    Absent / unreadable / stale / unexpected schema = `{}` (the owning table's answer stands).
    This is an ENRICHMENT: the driver's floor never depends on it.

    Freshness is decided PER ROW, not by the file's mtime. A recent write for one request keeps
    the whole database's mtime fresh, so an mtime check alone let an October evaluation of
    `credit:old` (waiting_on=user) overwrite the owning table's current answer (waiting_on=us) and
    suppress that request's 48 h reminder. A row with no readable timestamp cannot be proven
    current, so it is ignored: the owning table's answer is the one we can date.
    """
    now = now or time.time()
    try:
        if not os.path.exists(path):
            return {}
        if now - os.path.getmtime(path) > max_age_h * 3600:
            return {}
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        try:
            cols: dict[str, set[str]] = {}
            for name, in db.execute("SELECT name FROM sqlite_master WHERE type='table'"):
                cols[name] = {r[1] for r in db.execute(f"PRAGMA table_info({name})")}
            best: dict[str, str] = {}
            for table, have in cols.items():
                if not {"request_ref", "waiting_on"} <= have:
                    continue
                ts_col = next((c for c in _SENTINEL_TS_COLS if c in have), "")
                if not ts_col:
                    # No way to date a row: we cannot tell a current evaluation from a stale one,
                    # so this table contributes nothing and the owning table's answer stands.
                    continue
                order = "id" if "id" in have else "rowid"
                for r in db.execute(f"SELECT request_ref, waiting_on, {ts_col} FROM {table} "
                                    f"ORDER BY {order}"):
                    if not r[0]:
                        continue
                    at = _epoch(r[2])
                    if at is None or (now - at) > max_age_h * 3600:
                        continue          # undated or stale: not evidence about today
                    best[str(r[0])] = str(r[1] or "")
            return best
        finally:
            db.close()
    except (OSError, sqlite3.Error):
        return {}


class Sources:
    """Collect every source once per tick, with a per-source status (never a silent empty read)."""

    def __init__(self, *, query: Query = trino_query, gdpr_store: str = GDPR_STORE,
                 tickets: Callable[[str, tuple[str, ...]], list[dict[str, Any]]] | None = None,
                 ticket_identity: Callable[[dict[str, Any]], str] | None = None,
                 refund_tags: tuple[str, ...] = (), clickup_list: str = CLICKUP_LIST_ID,
                 sentinel_path: str = SENTINEL_STORE, days: int = 180,
                 open_days: int = 30, decided_days: int = 14) -> None:
        self.query = query
        self.gdpr_store = gdpr_store
        self.tickets = tickets
        self.ticket_identity = ticket_identity
        self.refund_tags = refund_tags
        self.clickup_list = clickup_list
        self.sentinel_path = sentinel_path
        self.days = days
        self.open_days = open_days
        self.decided_days = decided_days
        self.stale_open = 0

    def stale_open_rows(self) -> dict[str, int]:
        """Open rows this tick is NOT responsible for, per source table — counted, never hidden.

        A driver that silently narrows its scope is lying by omission. This is the number that
        makes the window a policy choice rather than an invisible cap.
        """
        out: dict[str, int] = {}
        for name, table, decided in (("credit", "postgresql_core.public.credit_requests", CREDIT_DECIDED),
                                     ("claim", "postgresql_core.public.claiming", CLAIM_DECIDED)):
            marks = ", ".join(f"'{x}'" for x in decided)
            try:
                rows = self.query(
                    f"SELECT count(*) FROM {table} WHERE deletedat IS NULL AND status NOT IN ({marks}) "
                    f"AND coalesce(updatedat, createdat) < current_timestamp - "
                    f"interval '{int(self.open_days)}' day")
            except (RuntimeError, sqlite3.DatabaseError):
                out[name] = -1            # unmeasured, and it says so
                continue
            try:
                out[name] = int(str(rows[0][0]).strip().strip('"') or 0)
            except (IndexError, ValueError):
                out[name] = -1
        return out

    def already_told(self, refs: Iterable[str]) -> tuple[list[Request], list[str]]:
        """The open requests we HAVE messaged that the update window no longer covers.

        The window keeps year-old abandoned requests out of a feed nobody asked for, but it must not
        end the 48 h promise for someone we are already talking to: a request last touched 31 days
        ago (still open) would otherwise go quiet forever, and the floor would be met only by not
        being measured. This reads exactly the refs our ledger holds, in bounded chunks.

        Returns `(rows, failed_refs)`. A read that fails is NOT an empty read: a request whose id
        query timed out would otherwise disappear from reminders while the tick still reported the
        source `ok`, so the caller must surface `failed_refs` as an unmeasured scope.
        """
        want: dict[str, list[str]] = {"credit": [], "claim": []}
        for ref in refs:
            typ, _, rid = str(ref).partition(":")
            if typ in want and rid:
                want[typ].append(rid)
        out: list[Request] = []
        failed: list[str] = []
        for typ, fn in (("credit", credit_requests), ("claim", claim_requests)):
            ids = want[typ]
            for i in range(0, len(ids), 300):
                chunk = tuple(ids[i:i + 300])
                try:
                    got = fn(self.query, ids=chunk)
                except (RuntimeError, sqlite3.DatabaseError):
                    failed.extend(f"{typ}:{rid}" for rid in chunk)
                    continue
                out.extend(r for r in got if not r.terminal)
        return out, failed

    def collect(self, *, now: float | None = None) -> tuple[list[Request], list[SourceReport]]:
        requests: list[Request] = []
        reports: list[SourceReport] = []
        for name, fn, needs_tickets in (("credit", self._credit, False), ("claim", self._claim, False),
                                        ("merge", self._merge, True), ("erasure", self._erasure, False),
                                        ("refund", self._refund, True)):
            try:
                got = fn()
            except RuntimeError as exc:
                reports.append(SourceReport(name, "unreadable", 0, str(exc)[:200]))
                continue
            except sqlite3.DatabaseError as exc:
                # A corrupt or non-SQLite file at a source's path is that source being UNREADABLE,
                # not the whole tick dying: the other types still get their messages, and the tick
                # says which reader it could not read (exit 3). It must never look like "no open
                # erasure requests" — that is the silent-empty-read failure this module exists for.
                reports.append(SourceReport(name, "unreadable", 0, f"{type(exc).__name__}: {exc}"[:200]))
                continue
            except LaneDisabled as exc:
                # Off by design, not broken: visible in the summary, never a failed tick.
                reports.append(SourceReport(name, "disabled", 0, str(exc)[:200]))
                continue
            except FileNotFoundError:
                # The store we EXPECT is gone. That is a real outage, not a lane that was never on.
                reports.append(SourceReport(name, "unconfigured", 0, "owning store not present"))
                continue
            requests.extend(got)
            reports.append(SourceReport(name, "ok", len(got)))
        stale = self.stale_open_rows()
        self.stale_open = sum(v for v in stale.values() if v > 0)
        for rep in reports:
            if rep.name in stale:
                rep.stale_open = stale[rep.name]
        overlay = sentinel_waiting(self.sentinel_path, now=now)
        for req in requests:
            if overlay.get(req.ref):
                req.waiting_on = overlay[req.ref]
                req.detail["waiting_on_source"] = "sentinel"
        return requests, reports

    # ------ individual readers ------
    def _credit(self) -> list[Request]:
        return credit_requests(self.query, days=self.days, open_days=self.open_days,
                               decided_days=self.decided_days)

    def _claim(self) -> list[Request]:
        return claim_requests(self.query, days=self.days, open_days=self.open_days,
                              decided_days=self.decided_days)

    def _erasure(self) -> list[Request]:
        return erasure_requests(self.gdpr_store)

    def _ticket_source(self, tags: tuple[str, ...]) -> list[dict[str, Any]]:
        if self.tickets is None or self.ticket_identity is None:
            # A ticket carries no Muso user id of its own: without the identity resolver the
            # contact cannot be reached by the r5 rules, so this lane is DISABLED — never an
            # empty read that looks like "no open requests", and never a failed tick either.
            raise LaneDisabled("no ticket reader / ticket identity resolver configured")
        tasks = self.tickets(self.clickup_list, tags)
        for t in tasks:
            if not t.get("_user_id"):
                t["_user_id"] = self.ticket_identity(t)
        return tasks

    def _merge(self) -> list[Request]:
        got = ticket_requests(self._ticket_source(MERGE_TAGS), typ="merge", tag_map={},
                              state_by_status=MERGE_TICKET_STATES)
        return [r for r in got if r.user_id]

    def _refund(self) -> list[Request]:
        if not self.refund_tags:
            raise LaneDisabled("no refund tags configured (policies/request-status-lines.json sources.refund.tags)")
        state_by_status = {"to do": ("received", "us", False), "open": ("received", "us", False),
                           "in progress": ("verifying", "us", False), "in review": ("verifying", "us", False),
                           "complete": ("decided", "", True), "closed": ("decided", "", True),
                           "done": ("decided", "", True)}
        got = ticket_requests(self._ticket_source(self.refund_tags), typ="refund", tag_map={},
                              state_by_status=state_by_status)
        return [r for r in got if r.user_id]


def clickup_reader(api_key: str = "", *, base: str | None = None) -> Callable[[str, tuple[str, ...]], list[dict[str, Any]]]:
    """A `tickets(list_id, tags)` reader over the shared ClickUp client (429-aware, throttled)."""
    import sys
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lib"))
    from clickup_client import ClickUp  # noqa: PLC0415

    client = ClickUp(api_key or os.environ.get("CLICKUP_API_KEY", ""))
    if base:
        client.base = base

    def read(list_id: str, tags: tuple[str, ...]) -> list[dict[str, Any]]:
        params = [("archived", "false"), ("include_closed", "true"), ("subtasks", "false")]
        params += [("tags[]", t) for t in tags]
        return list(client.list_tasks(list_id, params, max_pages=10))

    return read


def load_policy_sources(policy: dict[str, Any]) -> tuple[tuple[str, ...], str]:
    """(refund tags, clickup list id) from the copy policy's `sources` block."""
    src = (policy.get("sources") or {}) if isinstance(policy, dict) else {}
    tags = tuple(str(t) for t in ((src.get("refund") or {}).get("tags") or ()))
    lst = str((src.get("clickup") or {}).get("list_id") or CLICKUP_LIST_ID)
    return tags, lst
