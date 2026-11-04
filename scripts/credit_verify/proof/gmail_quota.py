"""support@ Gmail quota guard for hydra's Python callers (firstmate 10-31, after the 429 storm).

support@'s per-user Gmail quota is shared by:
- the proof-on-file scan (cs_proof_feed/gmail_scan.sh);
- the hourly document intake (`credit-proof.py file-recent`, cron credit-verify-proof-file);
- doc-verify's blob-backfill.

From 10-30 20:21Z they compounded one another into ~9 h of 429. Every hydra Python call through `guarded()`
gets four things:
1. **The shared lock.** #1558's ONE helper (`gmail_intake._support_gmail_lock`): the same path and the same
   fallback inode as gog_raw and gmail_scan.sh, so the callers queue instead of running at once. gog_raw
   takes that lock itself, so it is wrapped with `lock=False`: flock is per open file description, so taking
   it twice in one process would wait on ourselves.
2. **A host-wide backoff.** The first quota refusal from ANY guarded caller records `until` from Google's
   'Retry after <ISO8601>' (else 'Retry-After: <s>', else 15 min). Every guarded call refuses until then,
   whichever caller it is.
3. **A per-caller hourly budget.** Calls are counted per UTC hour in one host file; a caller over its cap is
   refused until the next hour.
4. **Clean refusals.** A refusal raises `GmailStop`, never a generic error, so loops stop instead of
   retrying the next message.
"""

from __future__ import annotations

import fcntl
import json
import os
import re
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Iterator

# A constant, never an env var (r5 [key=unattended]: state the environment can move is a bypass of the backoff and
# the budget). Tests pass state_dir explicitly.
STATE_DIR = "/var/lib/hydra/gmail-support"
DEFAULT_BACKOFF_S = 900
#: A published window is always FINITE and bounded, the same two clamps `cs_proof_feed/gmail_scan.sh` applies
#: (#1558). Without the ceiling one `Retry-After: 2099` teaches every guarded caller a 73-year silence: every
#: run refuses before spending a request, the stamp is never updated, and every log reads quiet and correct.
#: Without the floor a header already in the past publishes "now", which silences nobody.
RETRY_MIN_S = 60
RETRY_MAX_S = 6 * 3600
QUOTA_RE = re.compile(r"\b429\b|rateLimitExceeded|userRateLimitExceeded|quota|RESOURCE_EXHAUSTED|Too Many Requests",
                      re.I)
RETRY_AT_RE = re.compile(r"retry[- ]after[\"':= ]+(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?",
                         re.I)
RETRY_S_RE = re.compile(r"retry[- ]after[\"':= ]+(\d{1,6})(?![\d-])", re.I)


class GmailStop(RuntimeError):
    """A guarded support@ Gmail call was refused: back off, budget spent, or a fresh quota refusal."""


def _iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def clamp_window(seconds: int, min_s: int = RETRY_MIN_S) -> int:
    """Bound any window we publish: [min_s, RETRY_MAX_S]. One statement, both parse paths.

    `min_s` defaults to the production floor. A caller that has its OWN pacing seam passes its floor
    through instead, so one run has ONE floor: `gmail_scan.sh` already clamps every window it publishes
    into [RETRY_MIN_S, 6 h] and sets ITS RETRY_MIN_S to 0 under the test seam (no test can wait a minute
    per case). Re-applying the 60 s floor here silently overrode that seam - the scan published a 3 s
    window and then read back 63 s, so the wait-path test exited 4 as "saturated" and proved nothing.
    """
    return max(min_s, min(RETRY_MAX_S, seconds))


def retry_after_s(message: str, now: datetime, min_s: int = RETRY_MIN_S) -> int:
    m = RETRY_AT_RE.search(message or "")
    if m:
        tz = m.group(2) or "+00:00"
        tz = "+00:00" if tz == "Z" else (tz if ":" in tz else tz[:3] + ":" + tz[3:])
        try:
            asked = int((datetime.fromisoformat(m.group(1) + tz) - now).total_seconds()) + 1
        except ValueError:
            return DEFAULT_BACKOFF_S
        return clamp_window(asked, min_s)
    m = RETRY_S_RE.search(message or "")
    return clamp_window(int(m.group(1)) if m else DEFAULT_BACKOFF_S, min_s)


@contextmanager
def _state_lock(state_dir: str) -> Iterator[None]:
    os.makedirs(state_dir, mode=0o700, exist_ok=True)
    fd = os.open(os.path.join(state_dir, ".state.lock"), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


class GmailStateUnreadable(GmailStop):
    """A state file exists but cannot be read or parsed. NOT the same as absence.

    QA #1567 round 2, finding 1: `_read()` used to answer `{}` for a malformed or unreadable file, which
    fails OPEN in both directions that matter - an unreadable `backoff.json` reads as "no window", so the
    next support@ request goes out inside a 429 pause we ourselves published, and a malformed `budget.json`
    reads as "no calls this hour", so the hourly cap of 60 resets and the fleet can exceed it. A guard that
    cannot learn the state it exists to enforce must refuse.

    Absence is a real signal - the first run of every consumer has no files - so `FileNotFoundError` stays
    `{}`, and it is the ONLY thing that does. An existing file that is unreadable, empty, truncated, or not a
    JSON object is a STOP: nothing is requested, and the caller carries everything untried.
    """


def _read(path: str) -> dict[str, Any]:
    try:
        with open(path) as fh:
            raw = fh.read()
    except FileNotFoundError:
        return {}                      # expected first run: no state yet
    except OSError as exc:             # exists but unreadable (perms, I/O, a directory where a file belongs)
        raise GmailStateUnreadable(f"cannot read {path}: {exc}") from exc
    try:
        d = json.loads(raw)
    except ValueError as exc:
        # An EXISTING file that is empty or whitespace-only lands here too, and that is deliberate (QA
        # #1567 round 3): absence is `FileNotFoundError` and nothing else. This module never writes an empty
        # file (`_write` goes through a tmp file and `os.replace`, and the shell's fallback `json.dump`s a
        # window), so an empty `backoff.json` or `budget.json` is a torn write - and reading it as "no state"
        # is exactly the fail-open this guard exists to prevent: no window means a request inside a pause we
        # published, and a reset count means the hourly cap silently disappears. Only "no file yet" is a
        # first run.
        raise GmailStateUnreadable(f"cannot parse {path}: {exc}") from exc
    if not isinstance(d, dict):
        raise GmailStateUnreadable(f"{path} is not a JSON object")
    return d


def _read_if_exists(path: str) -> dict[str, Any] | None:
    """`None` only when the file does not exist. `{}` is a file that exists and holds `{}` - invalid state.

    QA #1567 round 4, part 2: falsiness cannot stand in for existence. A `backoff.json` containing `{}` (or
    any object without `until`) parses, is empty as a dict, and was therefore treated as an absent file -
    "no window" - which is the same fail-open a fourth time. Existence is asked of the filesystem.
    """
    if not os.path.exists(path):
        return None
    return _read(path)


def _require_iso_until(path: str, d: dict[str, Any]) -> str | None:
    """A `backoff.json` that EXISTS must carry a usable `until`.

    QA #1567 round 4: `_read()` rejecting unreadable/invalid JSON was not enough. `{"until": null}` parses
    fine and `backoff_until()` then read it as "no window", so a GET went out inside an active 429 pause we
    had published ourselves - the same fail-open one layer in. `_write()` always emits `until` as an ISO
    string, so a parseable file without one is invalid state, not an absent window.
    """
    if "until" not in d:
        raise GmailStateUnreadable(f"{path} has no 'until' field")
    v = d["until"]
    if not isinstance(v, str) or not v.strip():
        raise GmailStateUnreadable(f"{path} has a non-string 'until': {v!r}")
    try:
        datetime.strptime(v, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError as exc:
        raise GmailStateUnreadable(f"{path} has an unparseable 'until' {v!r}: {exc}") from exc
    return v


def _require_budget_fields(path: str, d: dict[str, Any]) -> dict[str, int]:
    """A `budget.json` that EXISTS must carry a usable `hour` and a per-caller `calls` map.

    QA #1567 round 4: a same-hour object with a missing or malformed `calls` read as "no calls yet", which
    silently resets the hourly cap. `_write()` always emits both fields, so their absence is invalid state.
    """
    hour = d.get("hour")
    if not isinstance(hour, str) or len(hour) != 13:
        raise GmailStateUnreadable(f"{path} has a malformed 'hour': {hour!r}")
    # QA #1567 round 5: length is not a shape. `2026-11-04Txx` is 13 characters, passes the check above and then
    # compares UNEQUAL to the real hour, so `take_budget` reads it as "a new hour" and resets the ledger to zero -
    # every 59-call file with one corrupted character bought a full 60/h again. Parse it, and require the canonical
    # form `take_budget` writes (strptime alone accepts `2026-11-4T9`), because the hour is compared as a STRING.
    try:
        canonical = datetime.strptime(hour, "%Y-%m-%dT%H").strftime("%Y-%m-%dT%H")
    except ValueError as exc:
        raise GmailStateUnreadable(f"{path} has an unparseable 'hour' {hour!r}: {exc}") from exc
    if canonical != hour:
        raise GmailStateUnreadable(f"{path} has a non-canonical 'hour' {hour!r} (want {canonical!r})")
    if "calls" not in d:
        # QA #1567 round 4: `_write()` always emits `calls`. A same-hour object without it read as "no calls
        # yet", which reset the hourly cap - so the key is required, not defaulted.
        raise GmailStateUnreadable(f"{path} has no 'calls' field")
    calls = d["calls"]
    if calls is None:
        raise GmailStateUnreadable(f"{path} has a null 'calls'")
    if not isinstance(calls, dict):
        raise GmailStateUnreadable(f"{path} has a non-object 'calls'")
    out: dict[str, int] = {}
    for caller, n in calls.items():
        if not isinstance(caller, str) or not isinstance(n, int) or isinstance(n, bool) or n < 0:
            raise GmailStateUnreadable(f"{path} has an invalid count for {caller!r}: {n!r}")
        out[caller] = n
    return out


def _write(path: str, d: dict[str, Any]) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(d, fh)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def backoff_until(now: datetime, state_dir: str = STATE_DIR) -> str | None:
    p = os.path.join(state_dir, "backoff.json")
    d = _read_if_exists(p)
    if d is None:                               # absent file: first run, no window
        return None
    v = _require_iso_until(p, d)
    return v if v > _iso(now) else None


def note_refusal(message: str, caller: str, now: datetime, state_dir: str = STATE_DIR,
                 min_s: int = RETRY_MIN_S) -> str:
    until = _iso(now + timedelta(seconds=retry_after_s(message, now, min_s)))
    with _state_lock(state_dir):
        p = os.path.join(state_dir, "backoff.json")
        d_cur = _read_if_exists(p)
        cur = _require_iso_until(p, d_cur) if d_cur is not None else None
        if not (isinstance(cur, str) and cur >= until):       # never shorten a standing backoff
            _write(p, {"until": until, "by": caller, "reason": (message or "")[:200], "at": _iso(now)})
            return until
        return cur


def take_budget(caller: str, cap: int, now: datetime, state_dir: str = STATE_DIR) -> bool:
    """Count one call for `caller` in this UTC hour; False (nothing counted) when the cap is already spent."""
    hour = now.astimezone(timezone.utc).strftime("%Y-%m-%dT%H")
    with _state_lock(state_dir):
        p = os.path.join(state_dir, "budget.json")
        d = _read_if_exists(p)
        if d is None:                            # absent file: first run this process can see
            d = {"hour": hour, "calls": {}}
        else:
            calls = _require_budget_fields(p, d)   # an existing file must be usable, whatever its hour
            if d.get("hour") > hour:
                # QA #1567 round 5: a FUTURE hour is not a new hour, it is a clock we cannot reconcile (rollback, a
                # restored host, two boxes sharing a state dir). Resetting on it is the same fail-open as an
                # unparseable one: spend to the cap, correct the clock, spend the whole cap again. Refuse instead.
                raise GmailStateUnreadable(f"{p} is stamped in the future: {d.get('hour')!r} > {hour!r}")
            if d.get("hour") != hour:
                d = {"hour": hour, "calls": {}}
            else:
                d = {"hour": hour, "calls": calls}
        n = int((d.get("calls") or {}).get(caller) or 0)
        if n >= cap:
            return False
        d.setdefault("calls", {})[caller] = n + 1
        _write(p, d)
        return True


@contextmanager
def support_lock(wait_s: float = 60.0) -> Iterator[None]:
    """THE shared support@ Gmail lock: #1558's ONE helper (gmail_intake._support_gmail_lock), so the path AND the
    fallback inode are exactly the ones gmail_scan.sh and gog_raw use (r5 #1567). A held lock past the bounded wait,
    or no lock file that can be opened at all, is a GmailStop: this guard fails closed."""
    from . import gmail_intake
    try:
        fh = gmail_intake._support_gmail_lock(wait_s)
    except gmail_intake.GmailLockBusy as exc:
        raise GmailStop(str(exc)) from None
    if fh is None:
        raise GmailStop("no support@ Gmail lock could be opened")
    try:
        yield
    finally:
        fh.close()


# The per-caller hourly budget is a CONSTANT, keyed by caller (r5): an argv flag let any caller raise its own cap,
# so the budget was a suggestion. A caller that is not listed gets no Gmail budget at all - it must be added here
# deliberately, in a reviewed diff, with the number beside it.
HOURLY_CAP = {
    "file-recent": 60,      # hourly intake: search pages + message gets together
    "blob-backfill": 360,   # paced 6/min in budgets of 30 (doc-verify), so the scan can interleave
}


def guarded(caller: str, fn: Callable[..., Any], *, lock: bool = True,
            now: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
            state_dir: str = STATE_DIR) -> Callable[..., Any]:
    """`fn` behind the host-wide backoff, this caller's hourly budget, the shared lock (unless `fn` takes it
    itself) and quota-refusal detection. A refusal of any kind raises GmailStop."""
    def call(*a: Any, **kw: Any) -> Any:
        t = now()
        standing = backoff_until(t, state_dir)
        if standing:
            raise GmailStop(f"support@ Gmail backoff until {standing}")
        cap = HOURLY_CAP.get(caller)
        if cap is None:
            raise GmailStop(f"{caller}: no support@ Gmail budget is defined for this caller")
        if not take_budget(caller, cap, t, state_dir):
            raise GmailStop(f"{caller}: support@ Gmail budget of {cap}/h spent")

        def recheck_under_lock() -> None:
            """[key=check-the-backoff-again-under-the-lock] (QA #1567 finding 1): the standing window is read
            BEFORE the lock wait, so a caller that queued behind a slow consumer can start its request after
            ANOTHER caller has since recorded a 429 - inside a window it never saw. Waiting for the lock is exactly
            where that happens, so the window is re-read once the lock is ours (both here and, for a callable that
            takes the lock itself, through AFTER_LOCK inside support_intake_lock)."""
            again = backoff_until(now(), state_dir)
            if again:
                raise GmailStop(f"support@ Gmail backoff until {again}")

        try:
            if lock:
                with support_lock():
                    recheck_under_lock()
                    return fn(*a, **kw)
            # `fn` takes the shared lock itself, so the recheck has to happen INSIDE that lock - and the wait for it
            # (up to the helper's 60 s) is exactly the window in which another caller records a 429 (QA #1567
            # finding 1). The check below is only a fast fail before the callable starts; the authoritative one is
            # handed to the lock holder through AFTER_LOCK, which runs it once the lock is ours.
            from .support_intake_lock import AFTER_LOCK
            recheck_under_lock()
            token = AFTER_LOCK.set(recheck_under_lock)
            try:
                return fn(*a, **kw)
            finally:
                AFTER_LOCK.reset(token)
        except GmailStop:
            raise
        except Exception as exc:
            msg = f"{type(exc).__name__}: {exc}"
            # [key=a-denied-lock-is-a-stop] (QA #1567 finding 2): with lock=False the callable takes the ONE shared
            # lock, and a denial used to escape as a RuntimeError - the search aborted, the fetch went on message by
            # message, and the run neither stopped nor carried the window. It is a stop: nothing more is read and
            # the caller carries everything untried. (Imported here: this module is also loaded by path, outside
            # its package, by the state-dir test.)
            from .gmail_intake import GmailLockBusy
            if isinstance(exc, GmailLockBusy):
                raise GmailStop(f"support@ Gmail lock unavailable: {exc}") from None
            if QUOTA_RE.search(msg):
                until = note_refusal(msg, caller, now(), state_dir)
                raise GmailStop(f"support@ Gmail quota refusal; backoff until {until}") from exc
            raise
    return call
