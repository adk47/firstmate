#!/usr/bin/env python3
"""Read-only Intercom collector for the Caroline monitor: one reduced record per thread.

Two calls only, both reads: `POST /conversations/search` (the window by `created_at`, or the
whole backlog scope: every open conversation plus the window plus what was just touched) and
`GET /conversations/{id}?display_as=plaintext` (the thread). Nothing is ever written to Intercom.

A record keeps what the classifier and the outcome reader need and nothing else: timestamps,
state, assignee ids, tags, and per part the type, the author TYPE (plus the id for admins and
bots, which are staff and automation, never customers), the assignment target and the text with
emails and phone-like strings masked. The contact is kept as a hash and as Intercom's opaque
contact id (no name, no email). The monitor classifies
in-process and persists only counts; text reaches disk only when an operator asks for a corpus
dump (`--out`), which is how the classifier is calibrated by hand.

This file is import-free beyond the stdlib ON PURPOSE: it can be streamed to a host that has the
token (`ssh node-8 'python3 - --days 30' < collect.py > corpus.jsonl`) without installing
anything there, and the monitor imports the same functions, so both read the API identically.

Nothing here decides "no data means zero". A failed search raises; a thread that cannot be
read is returned as an error row and counted by the caller, never dropped.
"""
import argparse
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

INTERCOM_API = os.environ.get("INTERCOM_API", "https://api.intercom.io")
INTERCOM_VERSION = "2.11"
TOKEN_ENV = "MUSOAI_INTERCOM_TOKEN"
TOKEN_ENV_FILES = ("/etc/openclaw/edge.env", "/etc/openclaw/shared.env")
PER_PAGE = 150
WORKERS = 6
BODY_CAP = 4000  # characters kept per part; the classifier reads the head of a message

_EMAIL_RE = re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")
_PHONE_RE = re.compile(r"(?<![\w/=.\-])\+?\d[\d\s().\-]{8,}\d(?![\w/])")
_TAG_RE = re.compile(r"<[^>]*>")
_WS_RE = re.compile(r"[ \t\r\f\v]+")


class CollectError(RuntimeError):
    """The window could not be read. The caller reports 'not measured', never a zero."""


def resolve_token(env=None):
    """The Intercom token from the environment, else from the gateway env files. Never printed."""
    env = os.environ if env is None else env
    token = (env.get(TOKEN_ENV) or "").strip()
    if token:
        return token
    for path in TOKEN_ENV_FILES:
        try:
            with open(path) as f:
                for line in f:
                    if line.startswith(TOKEN_ENV + "="):
                        return line.split("=", 1)[1].strip().strip('"').strip("'")
        except OSError:
            continue
    return ""


def mask(text):
    """Plain text with emails and phone-like strings masked, tags dropped, whitespace folded."""
    if not text:
        return ""
    text = _TAG_RE.sub(" ", str(text))
    text = _EMAIL_RE.sub("[email]", text)
    text = _PHONE_RE.sub("[phone]", text)
    text = _WS_RE.sub(" ", text)
    return re.sub(r"\n\s*\n+", "\n", text).strip()[:BODY_CAP]


def _hash(value):
    return hashlib.sha256(str(value).encode()).hexdigest()[:16] if value else ""


def _request(method, path, token, body=None, attempts=5, opener=None):
    """One Intercom call. Retries 429 and 5xx with backoff; any other failure raises."""
    opener = opener or urllib.request.urlopen
    data = json.dumps(body).encode() if body is not None else None
    last = None
    for attempt in range(attempts):
        req = urllib.request.Request(
            INTERCOM_API + path, data=data, method=method,
            headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                     "Content-Type": "application/json", "Intercom-Version": INTERCOM_VERSION})
        try:
            with opener(req, timeout=60) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as e:
            last = e
            if e.code == 429:
                reset = e.headers.get("X-RateLimit-Reset") if e.headers else None
                wait = max(1.0, min(30.0, float(reset) - time.time())) if reset else 5.0
            elif 500 <= e.code < 600:
                wait = 2.0 * (attempt + 1)
            else:
                raise
        except (urllib.error.URLError, OSError, ValueError) as e:
            last = e
            wait = 2.0 * (attempt + 1)
        time.sleep(wait)
    raise last


def _search(token, query, keep, request=_request, passes=3):
    """(list rows, total_count) for one search query, sorted by `created_at`.

    `total_count` is Intercom's own figure for the same query; the caller compares it with what
    it actually read, so a short read is visible instead of silently becoming the denominator.

    The search is sorted by `created_at`, which never changes. Intercom's default order is by
    last activity, and a thread that gets a reply while we page moves to the front and is never
    seen: a 30-page read of a live inbox lost 13 of 4,485 that way. If a pass still comes up
    short of Intercom's count it is repeated and the passes are merged.
    """
    rows, seen, total = [], set(), None
    for _ in range(max(1, passes)):
        after = None
        while True:
            body = {"query": query, "sort": {"field": "created_at", "order": "ascending"},
                    "pagination": {"per_page": PER_PAGE}}
            if after:
                body["pagination"]["starting_after"] = after
            data = request("POST", "/conversations/search", token, body)
            if not after and data.get("total_count") is not None:
                total = data.get("total_count")
            for c in data.get("conversations") or []:
                cid = str(c.get("id"))
                row = {"id": cid, "created_at": int(c.get("created_at") or 0),
                       "updated_at": int(c.get("updated_at") or 0), "open": bool(c.get("open"))}
                if cid in seen or not keep(row):
                    continue
                seen.add(cid)
                rows.append(row)
            nxt = (data.get("pages") or {}).get("next")
            after = nxt.get("starting_after") if isinstance(nxt, dict) else None
            if not after:
                break
        if total is None or len(rows) >= total:
            break
    return rows, total


def search_created_between(token, start_ts, end_ts, request=_request, passes=3):
    """Conversations CREATED in [start_ts, end_ts): the cohort the weekly numbers are counted on."""
    query = {"operator": "AND", "value": [
        {"field": "created_at", "operator": ">", "value": int(start_ts) - 1},
        {"field": "created_at", "operator": "<", "value": int(end_ts)}]}
    return _search(token, query, lambda r: start_ts <= r["created_at"] < end_ts, request, passes)


def search_backlog(token, start_ts, since_ts, request=_request, passes=3):
    """Everything the support instrument has to see, in one query: every OPEN conversation
    whatever its age, everything created since `start_ts`, and everything touched since
    `since_ts`.

    The created-window alone is not the inbox. On 2026-11-11 it held 4,485 threads while 9,080
    conversations were open, 4,848 of them older than the window, and 1,045 of the 2,162
    conversations touched that day were older than the window too. A backlog number counted
    on the window would have been half of the truth and said nothing about the oldest wait.
    """
    query = {"operator": "OR", "value": [
        {"field": "open", "operator": "=", "value": True},
        {"field": "created_at", "operator": ">", "value": int(start_ts) - 1},
        {"field": "updated_at", "operator": ">", "value": int(since_ts) - 1}]}
    return _search(token, query, lambda r: True, request, passes)


def _author(part):
    a = part.get("author") or {}
    kind = a.get("type") or ""
    # Only staff and automation ids are kept; a customer id never leaves the API response.
    return kind, (str(a.get("id")) if kind in ("admin", "bot", "team") and a.get("id") else "")


def reduce_thread(detail):
    """The reduced, masked record for one conversation detail."""
    src = detail.get("source") or {}
    listing = detail.get("conversation_parts") or {}
    raw_parts = listing.get("conversation_parts") or []
    parts = []
    for p in raw_parts:
        kind, aid = _author(p)
        asg = p.get("assigned_to")
        parts.append({
            "t": p.get("part_type") or "",
            "at": kind,
            "aid": aid,
            "ts": int(p.get("created_at") or 0),
            "body": mask(p.get("body")),
            "att": len(p.get("attachments") or []),
            "asg": ({"type": asg.get("type") or "", "id": str(asg.get("id") or "")}
                    if isinstance(asg, dict) else None),
        })
    skind, said = _author(src)
    contacts = ((detail.get("contacts") or {}).get("contacts")) or []
    stats = detail.get("statistics") or {}
    return {
        "id": str(detail.get("id")),
        "created_at": int(detail.get("created_at") or 0),
        "updated_at": int(detail.get("updated_at") or 0),
        "state": detail.get("state") or "",
        "open": bool(detail.get("open")),
        "admin_assignee_id": str(detail.get("admin_assignee_id") or ""),
        "team_assignee_id": str(detail.get("team_assignee_id") or ""),
        "tags": sorted(str(t.get("name") or "") for t in ((detail.get("tags") or {}).get("tags") or [])),
        "tag_at": {str(t.get("name") or ""): int(t.get("applied_at") or 0)
                   for t in ((detail.get("tags") or {}).get("tags") or [])},
        "source": {
            "type": src.get("type") or "",
            "delivered_as": src.get("delivered_as") or "",
            "at": skind,
            "aid": said,
            "subject": mask(src.get("subject")),
            "body": mask(src.get("body")),
            "att": len(src.get("attachments") or []),
        },
        "parts": parts,
        "parts_total": int(listing.get("total_count") or len(raw_parts)),
        "contact": _hash(contacts[0].get("id")) if contacts else "",
        # Intercom's own opaque id for the contact, never an email. The promise ledger keeps it
        # so that a status line can be routed onto the thread where this contact is waiting.
        "contact_id": str(contacts[0].get("id") or "") if contacts else "",
        "first_admin_reply_at": int(stats.get("first_admin_reply_at") or 0),
    }


def fetch_thread(token, cid, request=_request):
    """(record, error). A deleted conversation (404) is (None, 'gone')."""
    try:
        return reduce_thread(request("GET", f"/conversations/{cid}?display_as=plaintext", token)), None
    except urllib.error.HTTPError as e:
        return None, ("gone" if e.code == 404 else f"http {e.code}")
    except (urllib.error.URLError, OSError, ValueError) as e:
        return None, type(e).__name__


def collect(token, start_ts, end_ts, skip=None, workers=WORKERS, request=_request, since_ts=None):
    """Read the window (or, with `since_ts`, the whole backlog scope: see `search_backlog`).
    Returns a dict:

      listed      rows the search returned (id, created_at, updated_at)
      total_count Intercom's own count for the query (None when it did not say)
      threads     reduced records for every listed id not in `skip`
      skipped     ids the caller already holds at the same `updated_at`
      gone        ids deleted between the search and the read
      errors      {id: reason} for threads that could not be read

    `skip` is {id: updated_at}: a thread whose `updated_at` has not moved is not fetched again.
    Raises CollectError when the search itself fails, so the caller cannot mistake it for an
    empty window.
    """
    if not token:
        raise CollectError(f"{TOKEN_ENV} not set")
    try:
        if since_ts is None:
            listed, total = search_created_between(token, start_ts, end_ts, request=request)
        else:
            listed, total = search_backlog(token, start_ts, since_ts, request=request)
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise CollectError(f"Intercom search failed: {type(e).__name__}: {e}") from e
    skip = skip or {}
    todo = [r["id"] for r in listed if skip.get(r["id"]) != r["updated_at"]]
    skipped = [r["id"] for r in listed if skip.get(r["id"]) == r["updated_at"]]
    threads, gone, errors = [], [], {}
    with ThreadPoolExecutor(max_workers=max(1, workers)) as pool:
        for cid, (rec, err) in zip(todo, pool.map(lambda c: fetch_thread(token, c, request=request), todo)):
            if rec is not None:
                threads.append(rec)
            elif err == "gone":
                gone.append(cid)
            else:
                errors[cid] = err
    return {"listed": listed, "total_count": total, "threads": threads, "skipped": skipped,
            "gone": gone, "errors": errors}


def main(argv=None):
    p = argparse.ArgumentParser(description="Dump the reduced, masked thread corpus as JSONL (read-only).")
    p.add_argument("--days", type=float, default=30.0, help="window length ending at --until")
    p.add_argument("--until", type=int, default=None, help="window end, epoch seconds (default: now)")
    p.add_argument("--out", default="-", help="output path, or - for stdout")
    p.add_argument("--list-only", action="store_true", help="count the window and stop: no thread is read")
    p.add_argument("--backlog", action="store_true",
                   help="also read every open conversation and everything touched in the last 26 hours")
    args = p.parse_args(argv)
    end = int(args.until or time.time())
    start = end - int(args.days * 86400)
    since = end - 26 * 3600 if args.backlog else None
    if args.list_only:
        try:
            rows, total = (search_backlog(resolve_token(), start, since) if args.backlog
                           else search_created_between(resolve_token(), start, end))
        except (CollectError, urllib.error.URLError, OSError, ValueError) as e:
            print(f"ERROR: {e}", file=sys.stderr)
            return 2
        print(f"window {start}..{end}: listed {len(rows)} (Intercom says {total})")
        return 0
    try:
        got = collect(resolve_token(), start, end, since_ts=since)
    except CollectError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2
    out = sys.stdout if args.out == "-" else open(args.out, "w")
    try:
        out.write(json.dumps({"_meta": {"start": start, "end": end, "backlog": bool(args.backlog),
                                        "listed": len(got["listed"]),
                                        "total_count": got["total_count"], "gone": len(got["gone"]),
                                        "errors": len(got["errors"])}}) + "\n")
        for rec in got["threads"]:
            out.write(json.dumps(rec, separators=(",", ":")) + "\n")
    finally:
        if out is not sys.stdout:
            out.close()
    print(f"window {start}..{end}: listed {len(got['listed'])} (Intercom says {got['total_count']}), "
          f"read {len(got['threads'])}, gone {len(got['gone'])}, errors {len(got['errors'])}", file=sys.stderr)
    return 1 if got["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
