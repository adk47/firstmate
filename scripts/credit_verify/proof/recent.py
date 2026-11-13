"""`credit-proof.py file-recent`: the hourly document INTAKE (proof-loop lead 068; captain 12:1xZ:
document intake is the verification agents' job, never Caroline's).

Each run files, into proof_intake ONLY (no judgement, no send), every document customers sent since
the last successful run:
  * Intercom: conversations updated since then (ONE read-only `POST /conversations/search`, paged),
    paid accounts first, through intake.run (customer attachments only - the #1417 staff rule -,
    `--max-fetches` per run; a conversation over the budget is CARRIED to the next run, never lost);
  * support@ Gmail: messages with an attachment since then (read-only `gog gmail messages search`),
    through gmail_intake.run (authenticated sender only, confirmed account only).
Dry run unless `--apply`. One run at a time (an exclusive lock on the state file).

A run is BOUNDED and its progress is SAVED AS IT GOES (2026-11-13: the window was saved only at the very
end, so once a 24 h kill-file pause left more conversations than one run could read inside the cron's
3000 s kill, every run was killed with nothing saved and the next one started over on a longer window:
36 of the next 37 runs failed in 41 h, 31 of them at that kill, the cursor frozen at 2026-11-10T17:15Z). Now:
  * both searches run first, and their whole result is written to the state (`carry`, `carry_messages`)
    before any conversation is read, so the window moves as soon as the searches were complete;
  * conversations are filed CHUNK at a time and the state is saved after each chunk: a killed run redoes at
    most one chunk (re-filing is idempotent);
  * past `max_seconds` the run stops filing conversations and carries the rest, never dropped (support@
    messages are still filed: they are capped by count);
  * a chunk with a transient Intercom error is carried whole, and the window is held as before.
"""

from __future__ import annotations

import fcntl
import json
import os
import subprocess
import time
import urllib.request
from typing import Any, Callable

STATE = os.environ.get("CREDIT_PROOF_FILE_STATE", "/var/lib/hydra-credit-verify/proof-file-state.json")
API = "https://api.intercom.io"
OVERLAP_S = 600            # each window starts 10 min before the last run's start (clock skew, slow indexing)
MAX_PAGES = 40             # 40 x 150 conversations per run at most; more is carried, never dropped
CHUNK = 25                 # conversations filed between two saves of the state: what a killed run redoes at most
MAX_SECONDS = 2400.0       # a run stops filing here and carries the rest; the cron's own kill is at 3000 s

Search = Callable[[dict[str, Any]], dict[str, Any]]
GmailSearch = Callable[[str, str], dict[str, Any]]


def intercom_search(token: str) -> Search:
    def post(body: dict[str, Any]) -> dict[str, Any]:
        req = urllib.request.Request(f"{API}/conversations/search", data=json.dumps(body).encode(), method="POST",
                                     headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                                              "Content-Type": "application/json", "Intercom-Version": "2.11"})
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.load(resp)
    return post


def recent_conversations(search: Search, since: float) -> tuple[list[str], bool]:
    """(conversation ids updated after `since`, complete). `complete` is False when MAX_PAGES was hit:
    the caller must then not advance the window."""
    ids: list[str] = []
    after = None
    for _ in range(MAX_PAGES):
        body: dict[str, Any] = {"query": {"field": "updated_at", "operator": ">", "value": int(since)},
                                "pagination": {"per_page": 150}}
        if after:
            body["pagination"]["starting_after"] = after
        page = search(body)
        ids += [str(c["id"]) for c in page.get("conversations") or [] if c.get("id")]
        after = ((page.get("pages") or {}).get("next") or {}).get("starting_after")
        if not after:
            return list(dict.fromkeys(ids)), True
    return list(dict.fromkeys(ids)), False


def gog_search(account: str = "support@muso.ai") -> GmailSearch:
    def run(query: str, page: str) -> dict[str, Any]:
        # The SEARCH is a Gmail request too, and it runs once per page BEFORE any gog_raw call, so it was the
        # one support@ path with no lock: the hourly file-recent intake could page through searches while the
        # proof scan was mid-run, which is the concurrency the lock exists to stop (QA on #1558).
        argv = ["gog", "gmail", "messages", "search", "--account", account, query, "--max", "100", "--json",
                "--no-input"] + (["--page", page] if page else [])
        from .support_intake_lock import hold_support_gmail_lock
        p = hold_support_gmail_lock(lambda: subprocess.run(argv, capture_output=True, text=True, timeout=120,
                                                          check=False))
        if p.returncode != 0:
            raise RuntimeError(f"gog rc={p.returncode}: {p.stderr.strip()[-200:]}")
        return json.loads(p.stdout)
    return run


def recent_messages(search: GmailSearch, since: float) -> tuple[list[str], bool]:
    from .gmail_quota import GmailStop
    ids: list[str] = []
    page = ""
    for _ in range(MAX_PAGES):
        try:
            out = search(f"has:attachment after:{int(since)}", page)
        except GmailStop:
            # backoff / budget / quota refusal (firstmate 10-31): stop searching; incomplete = the window is held,
            # so the next run searches the same range again
            return list(dict.fromkeys(ids)), False
        ids += [str(m["id"]) for m in out.get("messages") or [] if m.get("id")]
        page = out.get("nextPageToken") or ""
        if not page:
            return list(dict.fromkeys(ids)), True
    return list(dict.fromkeys(ids)), False


def paid_first(convs: list[str], export: dict[str, set[int]], paying: set[int]) -> list[str]:
    return sorted(convs, key=lambda c: (not (export.get(c, set()) & paying), convs.index(c)))


def load_state(path: str) -> dict[str, Any]:
    try:
        with open(path, encoding="utf-8") as fh:
            st = json.load(fh)
        return st if isinstance(st, dict) else {}
    except (OSError, ValueError):
        return {}


def save_state(path: str, st: dict[str, Any]) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(st, fh)
    os.replace(tmp, path)


class Busy(RuntimeError):
    """Another file-recent run holds the lock."""


def _merge(total: dict[str, Any], part: dict[str, Any]) -> dict[str, Any]:
    """Add one chunk's intake stats to the run's: lists are joined, counts are summed, count maps are merged."""
    for k, v in part.items():
        if isinstance(v, list):
            total[k] = list(total.get(k) or []) + v
        elif isinstance(v, dict):
            total[k] = _merge(dict(total.get(k) or {}), v)
        elif isinstance(v, (int, float)) and not isinstance(v, bool):
            total[k] = (total.get(k) or 0) + v
        else:
            total[k] = v
    return total


def _transient(errors: Any) -> list[str]:
    """Intercom failures worth a retry (a conversation GET or an attachment download). A ValueError is permanent
    (over 25 MB, a host that is not Intercom's) and would be retried forever, so it never is (QA #1447)."""
    return [e for e in errors or [] if "ValueError" not in e]


def locked(path: str):
    os.makedirs(os.path.dirname(path) or ".", mode=0o700, exist_ok=True)
    fd = os.open(path + ".lock", os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        raise Busy("another credit-proof.py file-recent run is in flight") from None
    return fd


def with_unresolved_tray(file_conversations: Callable[[list[str]], dict[str, Any]], path: str, apply: bool,
                         source: str = "intercom") -> Callable[[list[str]], dict[str, Any]]:
    """Wrap intake.run so its unresolved conversations are appended to the tray file INSIDE the pass - under
    the lock and before the window is saved (QA #1481). A failed append raises out of `run`, so the cursor
    does not advance and the next run sees the same conversations again (re-filing is idempotent)."""
    def call(ids: list[str]) -> dict[str, Any]:
        stats = file_conversations(ids)
        items = list(stats.get("unresolved") or [])
        if apply and items:
            at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
            fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            with os.fdopen(fd, "a", encoding="utf-8") as fh:
                for u in items:
                    fh.write(json.dumps({"at": at, "source": source, **u}, default=str) + "\n")
                fh.flush()
                os.fsync(fh.fileno())
        return stats
    return call


def run(*, state_path: str, hours: float, apply: bool, now: float | None = None,
        conv_search: Search | None, gmail_search: GmailSearch | None,
        file_conversations: Callable[[list[str]], dict[str, Any]],
        file_messages: Callable[[list[str]], dict[str, Any]],
        order: Callable[[list[str]], list[str]] = lambda c: c,
        max_messages: int | None = None,
        max_seconds: float | None = None, chunk: int = CHUNK,
        clock: Callable[[], float] = time.monotonic,
        log: Callable[[str], None] = lambda m: None) -> dict[str, Any]:
    """One intake pass. `file_conversations(ids)` / `file_messages(ids)` are intake.run / gmail_intake.run
    already bound to the store, apply flag and fetch budget; they return their stats. At most `max_messages`
    support@ messages are fetched per run; the rest ride in `carry_messages` to the next run, never dropped.
    `file_conversations` is called once per `chunk` conversations and the state is saved after each call;
    past `max_seconds` (None = no limit) no more conversations are filed and the rest is carried."""
    now = time.time() if now is None else now
    fd = locked(state_path)
    try:
        st = load_state(state_path)
        start = float(st.get("since") or (now - hours * 3600))   # the window's lower bound (before overlap)
        since = start - OVERLAP_S
        since = max(since, now - 7 * 86400)               # never look back more than a week in one run
        out: dict[str, Any] = {"since": since, "apply": apply}
        deadline = None if max_seconds is None else clock() + max(0.0, float(max_seconds))
        carried = [str(c) for c in st.get("carry") or []]
        convs, c_ok = recent_conversations(conv_search, since) if conv_search else ([], True)
        todo = list(dict.fromkeys(carried + order(convs)))
        carried_msgs = [str(m) for m in st.get("carry_messages") or []]
        found, m_ok = recent_messages(gmail_search, since) if gmail_search else ([], True)
        pending = list(dict.fromkeys(carried_msgs + found))

        def checkpoint(unfiled: list[str]) -> None:
            # What a KILLED run leaves behind: every conversation and message not filed yet, by id. The window
            # may move here because nothing it found can be lost: it is all in `carry` / `carry_messages`.
            if apply:
                save_state(state_path, {"since": now if (c_ok and m_ok) else start, "carry": unfiled,
                                        "carry_messages": pending, "last_run": st.get("last_run"),
                                        "checkpoint": now})

        if todo:
            checkpoint(todo)
        cstats: dict[str, Any] = {"deferred_conversations": []}
        carry: list[str] = []
        left = list(todo)
        size = max(1, int(chunk))
        while left and (deadline is None or clock() < deadline):
            part, left = left[:size], left[size:]
            got = file_conversations(part)
            _merge(cstats, got)
            carry += [str(c) for c in got.get("deferred_conversations") or []]
            if _transient(got.get("errors")):
                carry += part                             # the error names no conversation: the chunk is retried whole
            carry = list(dict.fromkeys(carry))
            checkpoint(list(dict.fromkeys(carry + left)))
        out_of_time = len(left)
        carry = list(dict.fromkeys(carry + left))
        # support@ disabled (--no-gmail = Intercom only, QA #1488): nothing is fetched or filed, and the queued
        # ids are kept untouched for a later run with support@ enabled. A run that ran out of time on Intercom
        # still files its support@ messages: they are capped by count, and a backlog of conversations that takes
        # many runs to read must not hold every emailed document behind it (2026-11-13: 2,888 conversations
        # carried, 118 messages waiting). The time for them is the gap between `max_seconds` and the cron's kill.
        cap = 0 if gmail_search is None else (
            len(pending) if max_messages is None else max(0, int(max_messages)))
        msgs, carry_msgs = pending[:cap], pending[cap:]
        mstats = file_messages(msgs) if msgs else {}
        retry_msgs = [e.split(":", 1)[0] for e in mstats.get("fetch_errors") or []]
        # Transient Intercom failures (a conversation GET or an attachment download) hold the window, so the
        # next run searches the same range again (QA #1447). A ValueError is permanent (over 25 MB, a host
        # that is not Intercom's) and would hold the window forever, so it never does.
        transient = _transient(cstats.get("errors"))
        out.update(conversations=len(todo), carried_in=len(carried), carried_out=len(carry),
                   out_of_time=out_of_time,
                   messages=len(msgs), messages_carried_in=len(carried_msgs), messages_carried_out=len(carry_msgs),
                   retry_messages=retry_msgs, intercom_transient_errors=transient[:5],
                   complete=c_ok and m_ok,
                   intercom={k: (len(v) if isinstance(v, list) else v) for k, v in cstats.items()},
                   # the strict intake's unresolved conversations, kept whole for the tray (not just a count)
                   unresolved=list(cstats.get("unresolved") or []),
                   gmail={k: (len(v) if isinstance(v, list) else v) for k, v in mstats.items()})
        if apply:
            # The window moves only when this run saw everything (no page cap hit) and no message
            # failed to fetch; deferred, retried and out-of-time conversations ride along in `carry` either way.
            # A held window keeps the lower bound this run ATTEMPTED - on a first run too - so a later run
            # never jumps to a fresh `now - hours` and skips what this one could not finish (QA #1447).
            nxt = {"since": now if (c_ok and m_ok and not retry_msgs and not transient) else start,
                   # a message whose raw fetch failed is carried too, ahead of new work (QA #1488): a carried id
                   # older than the 7-day search clamp is never found by the search again, so dropping it here
                   # would lose it
                   "carry": carry, "carry_messages": list(dict.fromkeys(
                       [m for m in retry_msgs if m in set(msgs)] + carry_msgs)), "last_run": now}
            save_state(state_path, nxt)
            out["window_advanced"] = nxt["since"] == now
        # the log line carries COUNTS: the unresolved conversations are in the tray file, and listing them here
        # pushed the support@ stats past the line's cut (2026-11-13: a 60-message run's result could not be read)
        log("file-recent " + json.dumps({**out, "unresolved": len(out["unresolved"])}, default=str)[:2000])
        return out
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)
