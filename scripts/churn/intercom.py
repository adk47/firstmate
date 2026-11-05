"""Intercom, read-only: search + GET, and nothing else.

Two hard rules from the brief: never write to Intercom from this build, and stay
inside a request budget. Both are structural here: the module only has GET/POST
to `/conversations/search`, `/contacts/search` and `/conversations/{id}`, and the
sweep is bounded by `--conv-budget` / `--max-seconds`: the facts a GET bought are
persisted per conversation, so an unchanged thread is never re-read and the ones a
budget-bounded night never reached are simply asked again the next night.

Why the enumeration is enough for most of the signal (measured on node-8
2026-11-03/04): a conversation SEARCH row already carries `state`,
`waiting_since`, `statistics.last_contact_reply_at` / `last_admin_reply_at`,
`source.body`, `conversation_rating` and `contacts[].external_id`. So who spoke
last, how long ago, and the customer's opening words cost ONE search row. A
`/conversations/{id}` GET is needed only to read OUR last message (the promise /
ask test) and the customer's LAST message (the cause class).

Paging: `pages.next.starting_after`, per_page 150 (300 pages at per_page 5 is
what made the report's measurement slow).
"""

from __future__ import annotations

import html
import json
import os
import re
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Callable, Iterator

API = "https://api.intercom.io"
PER_PAGE = 150
TAG_RE = re.compile(r"<[^>]+>")


class IntercomError(RuntimeError):
    pass


# The five outcomes of asking Intercom about ONE contact. They are distinct because a
# caller must not confuse "we could not ask" with "they have nothing": only ERROR may
# fall back to walking the window, and it says so in the log.
NO_IDENTITY = "no-identity"      # we hold no external_id and no email to look them up with
NOT_FOUND = "not-found"          # the contact itself is not in Intercom
NONE = "none"                    # contact found, zero conversations
ERROR = "error"                  # the lookups themselves failed (transport, HTTP)
FOUND = "found"
CONTACT_KINDS = (NO_IDENTITY, NOT_FOUND, NONE, ERROR, FOUND)


class ContactThreads:
    """What a per-contact lookup found, with the difference kept."""

    __slots__ = ("kind", "rows", "why")

    def __init__(self, kind: str, rows: list[dict[str, Any]] | None = None, why: str = "") -> None:
        if kind not in CONTACT_KINDS:
            raise ValueError(f"unknown contact kind {kind!r}")
        self.kind = kind
        self.rows = rows or []
        self.why = why

    def __repr__(self) -> str:
        return f"ContactThreads({self.kind!r}, rows={len(self.rows)}, why={self.why!r})"


def _token() -> str:
    for var in ("MUSOAI_INTERCOM_TOKEN", "INTERCOM_TOKEN"):
        v = os.environ.get(var)
        if v:
            return v
    for path in ("/etc/openclaw/main.env",):
        try:
            with open(path, encoding="utf-8") as fh:
                for line in fh:
                    if line.startswith(("MUSOAI_INTERCOM_TOKEN=", "INTERCOM_TOKEN=")):
                        return line.split("=", 1)[1].strip().strip('"')
        except OSError:
            continue
    raise IntercomError("no Intercom token (MUSOAI_INTERCOM_TOKEN, /etc/openclaw/main.env)")


def plain(text: str) -> str:
    """Intercom bodies are HTML: strip tags and unescape, keep the words."""
    if not text:
        return ""
    return html.unescape(TAG_RE.sub(" ", str(text))).replace("\n", " ").strip()


def author_who(node: dict[str, Any]) -> str:
    """contact | us. A bot reply (Caroline) is us: the customer was answered."""
    t = ((node or {}).get("author") or {}).get("type") or (node or {}).get("type") or ""
    return "us" if t in ("admin", "bot", "team") else "contact"


class Intercom:
    def __init__(self, *, token: str | None = None, workers: int = 6,
                 sleep: Callable[[float], None] = time.sleep,
                 max_seconds: float = 2400.0, conv_budget: int = 8000,
                 open_url: Callable[..., Any] | None = None):
        self._token = token
        self.workers = max(1, int(workers))
        self.sleep = sleep
        self.max_seconds = max_seconds
        self.conv_budget = conv_budget
        self.open_url = open_url or urllib.request.urlopen
        self.started = time.time()
        self.requests = 0
        self.errors: list[str] = []
        self.gets = 0

    # -- transport ---------------------------------------------------------
    def _headers(self) -> dict[str, str]:
        tok = self._token or getattr(self, "_tok_cached", None) or _token()
        self._tok_cached = tok
        return {"Authorization": f"Bearer {tok}", "Accept": "application/json",
                "Content-Type": "application/json", "Intercom-Version": "2.11"}

    def _call(self, path: str, body: dict[str, Any] | None = None) -> dict[str, Any]:
        data = json.dumps(body).encode() if body is not None else None
        method = "POST" if body is not None else "GET"
        last: Exception | None = None
        for attempt in range(5):
            req = urllib.request.Request(API + path, data=data, headers=self._headers(), method=method)
            try:
                self.requests += 1
                with self.open_url(req, timeout=60) as resp:
                    return json.loads(resp.read())
            except urllib.error.HTTPError as exc:
                detail = ""
                try:
                    detail = exc.read()[:300].decode()
                except Exception:  # noqa: BLE001
                    pass
                if exc.code == 429 or exc.code >= 500:
                    wait = 5.0 * (attempt + 1)
                    try:
                        wait = float(exc.headers.get("Retry-After") or wait)
                    except (TypeError, ValueError):
                        pass
                    self.sleep(min(60.0, wait))
                    last = exc
                    continue
                raise IntercomError(f"{path}: HTTP {exc.code} {detail}") from exc
            except (urllib.error.URLError, OSError, ValueError) as exc:
                self.sleep(2.0 * (attempt + 1))
                last = exc
        raise IntercomError(f"{path}: {last}")

    # -- search ------------------------------------------------------------
    def search_conversations(self, updated_since: float, *, state: str | None = None,
                             max_pages: int = 500,
                             progress: dict[str, int] | None = None) -> Iterator[dict[str, Any]]:
        """Every conversation updated since `updated_since` (all states), one row each."""
        clauses = [{"field": "updated_at", "operator": ">", "value": int(updated_since)}]
        if state:
            clauses.append({"field": "state", "operator": "=", "value": state})
        body: dict[str, Any] = {"query": {"operator": "AND", "value": clauses},
                                "pagination": {"per_page": PER_PAGE}}
        seen = 0
        for page in range(max_pages):
            if progress is not None:
                # a row-level counter cannot tell a cap from a busy walk: the caller
                # reports this number (one PER_PAGE row batch at a time)
                progress["pages"] = page + 1
            try:
                doc = self._call("/conversations/search", body)
            except IntercomError as exc:
                self.errors.append(f"conversation search page {page}: {exc}")
                return
            rows = doc.get("conversations") or []
            if not rows:
                return
            for row in rows:
                seen += 1
                yield row
            nxt = ((doc.get("pages") or {}).get("next") or {})
            if not nxt or not nxt.get("starting_after"):
                return
            body["pagination"] = {"per_page": PER_PAGE, "starting_after": nxt["starting_after"]}
        self.errors.append(f"conversation search stopped at {max_pages} pages ({seen} rows)")

    def search_by_contact(self, external_id: str | None = None,
                          email: str | None = None) -> ContactThreads:
        """Conversations attached to one contact, with the outcome kept distinct.

        Returns a ContactThreads whose `kind` says WHICH of the five things happened.
        Collapsing them into [] is what made a canceller who never wrote in pay for a
        fleet-wide walk, so the caller can now fall back only on ERROR.
        """
        field, value = ("external_id", external_id) if external_id else ("email", email)
        if not value:
            return ContactThreads(NO_IDENTITY)
        try:
            doc = self._call("/contacts/search", {"query": {"field": field, "operator": "=", "value": value},
                                                  "pagination": {"per_page": 1}})
            hits = doc.get("data") or []
        except IntercomError as exc:
            why = f"contact search {field}={value}: {exc}"
            self.errors.append(why)
            return ContactThreads(ERROR, why=why)
        contact_id = (hits[0] or {}).get("id") if hits else None
        if not contact_id:
            return ContactThreads(NOT_FOUND)
        out: list[dict[str, Any]] = []
        body: dict[str, Any] = {"query": {"operator": "AND",
                                          "value": [{"field": "contact_ids", "operator": "=", "value": contact_id}]},
                                "pagination": {"per_page": PER_PAGE}}
        for _ in range(20):
            try:
                doc = self._call("/conversations/search", body)
            except IntercomError as exc:
                why = f"conversations of contact {contact_id}: {exc}"
                self.errors.append(why)
                return ContactThreads(ERROR, out, why)
            rows = doc.get("conversations") or []
            if not rows:
                return ContactThreads(FOUND, out) if out else ContactThreads(NONE)
            out.extend(rows)
            nxt = ((doc.get("pages") or {}).get("next") or {})
            if not nxt or not nxt.get("starting_after"):
                return ContactThreads(FOUND, out)
            body["pagination"] = {"per_page": PER_PAGE, "starting_after": nxt["starting_after"]}
        self.errors.append(f"conversations of contact {contact_id} stopped at 20 pages")
        return ContactThreads(FOUND, out) if out else ContactThreads(ERROR, why="page cap")

    # -- one conversation --------------------------------------------------
    def conversation(self, conv_id: str) -> dict[str, Any]:
        """Full conversation (plaintext bodies): events in order."""
        doc = self._call(f"/conversations/{conv_id}?display_as=plaintext")
        self.gets += 1
        events: list[dict[str, Any]] = []
        src = doc.get("source") or {}
        if src:
            events.append({"at": src.get("created_at") or doc.get("created_at") or 0,
                           "who": author_who(src), "body": plain(src.get("body") or "")})
        for part in ((doc.get("conversation_parts") or {}).get("conversation_parts") or []):
            events.append({"at": part.get("created_at") or 0, "who": author_who(part),
                           "body": plain(part.get("body") or "")})
        events = [e for e in events if e["at"]]
        events.sort(key=lambda e: e["at"])
        return {"id": str(doc.get("id") or conv_id), "events": events,
                "state": doc.get("state") or "", "rating": doc.get("conversation_rating")}

    def conversations(self, ids: list[str]) -> dict[str, dict[str, Any]]:
        """Fetch many, bounded by the budget, 6 at a time (429 handled in _call)."""
        out: dict[str, dict[str, Any]] = {}
        todo = list(ids)
        if self.conv_budget and len(todo) > self.conv_budget:
            todo = todo[:self.conv_budget]
            self.errors.append(f"conversation GETs cut to the {self.conv_budget}-budget "
                               f"({len(ids) - len(todo)} left for the next run)")
        if not todo:
            return out
        deadline = self.started + self.max_seconds

        def one(cid: str) -> tuple[str, dict[str, Any] | None]:
            if time.time() > deadline:
                return cid, None
            try:
                return cid, self.conversation(cid)
            except IntercomError as exc:
                self.errors.append(f"conversation {cid}: {exc}")
                return cid, None

        with ThreadPoolExecutor(max_workers=self.workers) as pool:
            for cid, doc in pool.map(one, todo):
                if doc is not None:
                    out[cid] = doc
        if len(out) < len(todo):
            self.errors.append(f"{len(todo) - len(out)} conversations unread this run "
                               f"(budget/deadline): their users keep their previous row")
        return out


# -- row -> the thread shape stages.classify_user wants -----------------------
def thread_from_row(row: dict[str, Any], *, full: dict[str, Any] | None = None) -> dict[str, Any]:
    """One search row (+ its GET when we have it) as the stage's thread dict.

    Without the GET we still know who spoke last and when (statistics), so the
    thread is classified with a SYNTHETIC last event: the customer's last message
    is unknown to us, so its body is empty (no courtesy filter, no promise claim
    we did not read) and the cause class comes from the opening message.
    """
    stats = row.get("statistics") or {}
    src = row.get("source") or {}
    contacts = ((row.get("contacts") or {}).get("contacts") or [])
    ids = [c.get("external_id") for c in contacts if c.get("external_id")]
    last_contact = float(stats.get("last_contact_reply_at") or 0)
    last_admin = float(stats.get("last_admin_reply_at") or 0)
    waiting = float(row.get("waiting_since") or 0)
    if full:
        events = list(full.get("events") or [])
        if not events:
            events = [{"at": row.get("updated_at") or 0, "who": "contact", "body": ""}]
    else:
        events = [{"at": src.get("created_at") or row.get("created_at") or 0,
                   "who": author_who(src), "body": plain(src.get("body") or "")}]
        if waiting and waiting >= last_admin:
            who, at = "contact", waiting
        elif last_contact >= last_admin and last_contact:
            who, at = "contact", last_contact
        else:
            who, at = "us", last_admin or row.get("updated_at") or 0
        events.append({"at": at, "who": who, "body": ""})
    # the stage reads the LAST event at or before its anchor, so the list must be ordered
    events.sort(key=lambda e: e.get("at") or 0)
    last = events[-1]
    return {
        "id": str(row.get("id")),
        "created_at": float(row.get("created_at") or 0),
        "updated_at": float(row.get("updated_at") or 0),
        "state": row.get("state") or "",
        "events": events,
        "external_ids": ids,
        "rating": row.get("conversation_rating") or (full or {}).get("rating"),
        "last_who": last.get("who"),
        "last_at": float(last.get("at") or 0),
        "stats": {"last_contact_reply_at": last_contact, "last_admin_reply_at": last_admin},
        "subject": plain(src.get("subject") or ""),
    }
