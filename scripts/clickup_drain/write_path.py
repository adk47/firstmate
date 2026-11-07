"""The one guarded write path for credit edits made on a customer's behalf.

Every drainer that changes a credit uses this module, so the safety rails live in
ONE place and a new drainer cannot ship without them:

  * KILL FILES      — `/etc/hydra/clickup-drain-bulk-credit.disabled` and the
                      correction executor's own `/etc/hydra/clickup-drain-credit-
                      correction.disabled`. Either one stops every drainer; ops
                      reaches for one file, not seven.
  * ONE LOCK        — a single flock over the whole drain surface. Two drainers
                      writing the same profile concurrently is how a compare-and-
                      set becomes a lie.
  * SHARED CAP      — 100 writes per UTC day across ALL drainers, counted in one
                      file. The cap is a property of "we are editing customer
                      credits unattended", not of one queue.
  * LEDGER          — one JSONL row per write with the BEFORE and AFTER role list
                      for that (profile, track). An edit you cannot see the
                      pre-image of is an edit you cannot revert or explain.
  * COMPARE-AND-SET — the pre-image is re-read immediately before the write and
                      the row is refused if it moved. A human editing the same
                      credit at the same moment wins, always.

`--dry-run` is the caller's default; this module never decides to write on its
own. The admin wrapper's own `OPS_DRY_RUN=1` is honoured too, so a caller can
exercise the whole path without a single mutating request leaving the process.

REVERT IS A HUMAN PATH, AND THIS MODULE CANNOT TAKE IT
------------------------------------------------------
An undo of an ADD is a REMOVAL. `muso-admin-api.sh` refuses every credit-removal
DELETE in `enforce_removal_gate` (unless the wrapper is in dry-run mode), so there
is no removal function here at all — `add_role` exists, `remove_role` does not.
`plan_revert()` builds the compensating plan and the caller prints it; a named
human executes it through the approved removal path
(`skills-all/muso-ops-tracks` → Removal Requests). An `--apply`/`--operator` pair
that a fake admin would happily "execute" is exactly the kind of promise this
module must not make.
"""

from __future__ import annotations

import fcntl
import json
import os
import subprocess
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Protocol
from urllib.parse import urlencode

from .manifest import same_role

DEFAULT_ADMIN_SCRIPT = (
    "/opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh"
)
SERVICE_REQUESTER = "clickup-drain@hydra-ops"

DEFAULT_STATE_DIR = "/var/lib/hydra/bulk-credit-change"
SHARED_STATE_DIR = "/var/lib/hydra/clickup-drain"
KILL_FILES = (
    "/etc/hydra/clickup-drain-bulk-credit.disabled",
    "/etc/hydra/clickup-drain-credit-correction.disabled",
)
LOCK_PATH = "/var/lib/hydra/clickup-drain.lock"
LEDGER_PATH = f"{DEFAULT_STATE_DIR}/ledger.jsonl"
# The cap and the lock live OUTSIDE any one queue's state dir: they are shared
# surfaces, and a path inside bulk-credit-change/ would read as "that drainer's
# budget" when it is the whole drain surface's. `--state-dir` moves the ledger
# (a debugging knob), never the cap.
CAP_PATH = f"{SHARED_STATE_DIR}/writes.json"

#: Writes per UTC day across every drainer. Small on purpose: this number is the
#: blast radius of a drainer bug, and 100 is more than a full day of these
#: tickets has ever needed.
MAX_WRITES_PER_DAY = 100

#: How long a read-back is allowed to take to show a write. The admin path is a
#: synchronous edit, so this is a retry window for cache effects, not a queue.
READBACK_ATTEMPTS = 6
READBACK_SLEEP_SEC = 2.0
#: One re-read before a 404 becomes a refusal (see `_get_confirming_404`).
TRACK_404_CONFIRM_SLEEP_SEC = 1.0


#: A status that may be a blip rather than an answer: the request timeout, too
#: early, rate limit, and every server error. A GET that gets one is UNAVAILABLE
#: (retry later); a POST that gets one is UNCERTAIN (it may have landed). Neither
#: is a refusal, and neither may become a terminal ticket outcome.
TRANSIENT_HTTP_STATUSES = frozenset({408, 425, 429})


def is_transient_status(status: int | None) -> bool:
    """True when a status means "try again later", not "this is the answer".

    `None` (the wrapper printed no http_status) is unclassifiable, and for a
    write that is indistinguishable from a blip — callers that write treat it as
    transient, callers that read treat it as unavailable.
    """
    if not isinstance(status, int):
        return True
    return status in TRANSIENT_HTTP_STATUSES or status >= 500


#: Statuses that mean OUR credentials could not answer, not that the request is
#: wrong: an expired token, a revoked service account, a tier gate that moved.
#: They are an outage of the caller, so they belong with the transient statuses
#: and never with the refusals — a drainer that reads a 401 as "this row is bad"
#: parks a valid ticket behind a terminal tag for good.
UNANSWERABLE_HTTP_STATUSES = frozenset({401, 403})


def is_unanswerable_status(status: int | None) -> bool:
    """True when a status means "we could not get an answer", not "the answer is no".

    ONE predicate for both directions on purpose: the read path and the write
    path must agree on what counts as an outage, or a status that is retryable
    on a GET becomes a terminal verdict on a POST (the round-5 lesson).
    """
    return is_transient_status(status) or status in UNANSWERABLE_HTTP_STATUSES


class DrainBlocked(RuntimeError):
    """The whole run must not start (kill file, another run holds the lock)."""


class DailyCapReached(RuntimeError):
    """100 writes/day is spent; nothing more is written today."""


class AdminError(RuntimeError):
    """The admin wrapper failed in a way we cannot interpret."""


class NotFound(AdminError):
    """HTTP 404. On this API it does not prove absence (the admin track route
    also answers 404 when its own catalog read failed), so it is UNKNOWN."""


class Unavailable(RuntimeError):
    """The admin API could not answer — 5xx, 429, a timeout, a broken wrapper.

    Deliberately NOT an AdminError: a refusal is a fact about the request
    ("this row is wrong"), and this is a fact about the moment ("we could not
    read"). Turning the second into the first is how a transient outage
    permanently parks a customer's ticket behind `customer-outcome:blocked`.
    Callers let it escape, so the run stops and the ticket is retried."""


@dataclass(frozen=True)
class Envelope:
    status: int
    body: Any

    @property
    def ok(self) -> bool:
        return 200 <= self.status < 300


class CreditAdmin:
    """Admin API over the existing `muso-admin-api.sh` wrapper.

    The wrapper owns login, the token cache, the tier-2 gate and the service
    credentials; this class never sees or prints a credential. `get` is the only
    method a validator should reach for.
    """

    def __init__(self, script: str | None = None, requester: str = SERVICE_REQUESTER,
                 timeout: int = 120, runner=subprocess.run):
        self.script = script or os.environ.get("CLICKUP_DRAIN_ADMIN_SCRIPT", DEFAULT_ADMIN_SCRIPT)
        self.requester = requester
        self.timeout = timeout
        self._run = runner
        self.calls = 0

    def call(self, method: str, path: str, body: dict | None = None) -> Envelope:
        if not path.startswith("/admin/"):
            raise AdminError(f"refusing non-admin path {path!r}")
        argv = ["bash", self.script, "--requester", self.requester]
        argv += ["call", method.upper(), path]
        if body is not None:
            argv.append(json.dumps(body, separators=(",", ":")))
        self.calls += 1
        try:
            proc = self._run(argv, capture_output=True, text=True,
                             timeout=self.timeout, check=False)
        except subprocess.TimeoutExpired as exc:
            raise Unavailable(f"admin {method} timed out: {path}") from exc
        if proc.returncode != 0:
            # The wrapper fails for transient reasons (login, token cache, a
            # restart) far more often than for a bad request, and a bad request
            # shows up as an HTTP status below. Treat it as retryable.
            raise Unavailable(
                f"admin {method} failed rc={proc.returncode}: {(proc.stderr or '').strip()[:300]}"
            )
        line = (proc.stdout or "").strip().splitlines()
        try:
            envelope = json.loads(line[-1])
        except (json.JSONDecodeError, IndexError) as exc:
            raise Unavailable(f"admin {method} returned non-JSON for {path}") from exc
        status = envelope.get("http_status") if isinstance(envelope, dict) else None
        if not isinstance(status, int):
            raise Unavailable(f"admin {method} {path} returned no http_status")
        payload = envelope.get("body")
        if isinstance(payload, dict) and "data" in payload:
            payload = payload["data"]
        return Envelope(status=status, body=payload)

    def get(self, path: str, params: dict | None = None) -> Envelope:
        if params:
            path = f"{path}?{urlencode(params)}"
        env = self.call("GET", path)
        if env.status == 404:
            raise NotFound(path)
        if is_unanswerable_status(env.status):
            # 408 included: a read that timed out is not a fact about the data,
            # and turning it into a refusal tags a valid ticket for good. 401/403
            # included: our token being rejected says nothing about the row.
            raise Unavailable(f"admin GET {path} returned HTTP {env.status}")
        if not env.ok:
            raise AdminError(f"admin GET {path} returned HTTP {env.status}")
        return env

    def post(self, path: str, body: dict) -> Envelope:
        return self.call("POST", path, body)

    def delete(self, path: str, body: dict) -> Envelope:
        return self.call("DELETE", path, body)


CREDITS_PAGE_LIMIT = 500
CREDITS_MAX_PAGES = 400


def profile_credit_roles(admin: CreditAdmin, profile_id: str) -> dict[str, list[str]]:
    """`{track_id: [role, ...]}` for one profile, paged, strict about shape.

    Page-based on purpose: `/admin/profile/:id/credits` IGNORES `offset` and
    echoes page 1 back, which would silently truncate an edit's pre-image to the
    first page (documented in muso-ops-credit-sync). A surprise shape raises
    rather than returning a short list — a short pre-image reads as "the credit
    is not there" and would make us re-add something that exists.
    """
    out: dict[str, list[str]] = {}
    collected = 0
    total = None
    for page in range(1, CREDITS_MAX_PAGES + 1):
        env = admin.get(
            f"/admin/profile/{profile_id}/credits",
            {"limit": CREDITS_PAGE_LIMIT, "page": page},
        )
        data = env.body
        if not isinstance(data, dict) or not isinstance(data.get("items"), list) \
                or not isinstance(data.get("total"), int):
            raise AdminError(
                f"unexpected credits shape for profile {profile_id} page {page} "
                f"(keys: {sorted(data) if isinstance(data, dict) else type(data).__name__})"
            )
        items = data["items"]
        by_track = {str(item.get("id")): item for item in items if isinstance(item, dict)}
        roles = [it.get("credits") for it in by_track.values()]
        if any(not isinstance(r, list) or not all(isinstance(x, str) and x for x in r) for r in roles):
            raise AdminError(f"profile {profile_id} page {page}: credit roles are not strings")
        for track_id, entry in by_track.items():
            out[track_id] = list(entry["credits"])
        collected += len(items)
        total = data["total"]
        if collected >= total:
            break
        if not items:
            raise AdminError(
                f"profile {profile_id}: credits list truncated at {collected}/{total} "
                "with an empty page — refusing to use a short pre-image"
            )
    else:
        raise AdminError(f"profile {profile_id}: no last page after {CREDITS_MAX_PAGES}")
    if total is not None and collected < total:
        raise AdminError(f"profile {profile_id}: read {collected} of {total} credits")
    return out


def _get_confirming_404(admin: CreditAdmin, path: str, sleep=time.sleep) -> Envelope:
    """GET, re-reading once on 404.

    `/admin/track/:id` answers 404 when its own catalog read failed, so a single
    404 cannot distinguish "this id is not a track" from "the catalog was out for
    a moment". Refusing on the first one is exactly how a blip becomes a
    `customer-outcome:blocked` verdict, so a 404 is corroborated once.
    """
    try:
        return admin.get(path)
    except NotFound:
        sleep(TRACK_404_CONFIRM_SLEEP_SEC)
        return admin.get(path)


def track_exists(admin: CreditAdmin, track_id: str, sleep=time.sleep) -> tuple[bool, str]:
    """(exists, why-not). A CONFIRMED 404 is reported as missing: for a WRITE we
    need a positive read, so an unreadable track is refused, not assumed."""
    try:
        env = _get_confirming_404(admin, f"/admin/track/{track_id}", sleep=sleep)
    except NotFound:
        return False, "track not found on two reads (GET /admin/track -> 404)"
    # An AdminError is a refusal (the request is wrong); Unavailable escapes so
    # the ticket is retried instead of parked.
    except AdminError as exc:
        return False, f"track is not readable as writable ({exc})"
    body = env.body
    if not isinstance(body, dict):
        return False, "track response is not an object"
    if body.get("deleted") is True or body.get("mergedTo"):
        return False, "track is deleted or merged"
    return True, ""


def profile_status(admin: CreditAdmin, profile_id: str, sleep=time.sleep) -> tuple[bool, str]:
    """(usable, why-not). A merged profile is refused: writing a credit onto a
    profile that no longer displays is a write nobody can see."""
    try:
        env = _get_confirming_404(admin, f"/admin/profile/{profile_id}", sleep=sleep)
    except NotFound:
        return False, "profile not found on two reads (GET /admin/profile -> 404)"
    except AdminError as exc:
        # A 401/403, a wrapper failure or a body we cannot read says nothing about
        # the customer's request: it is an unreadable admin state, so the caller
        # must stop and retry rather than write a terminal verdict.
        raise Unavailable(f"profile {profile_id} is not readable: {exc}") from exc
    body = env.body
    if not isinstance(body, dict):
        raise Unavailable(
            f"profile {profile_id}: response is not an object "
            f"({type(body).__name__})"
        )
    merged = body.get("mergedTo") or body.get("merged_to_id") or body.get("mergedToId")
    if merged:
        return False, f"profile was merged into {merged}"
    return True, ""


def add_role(admin: CreditAdmin, track_id: str, profile_id: str, role: str) -> Envelope:
    """The documented, production-proven add: one (track, profile, role)."""
    return admin.post(
        f"/admin/track/{track_id}/profile/{profile_id}/credits", {"role": role}
    )


# There is deliberately NO remove_role() here. `muso-admin-api.sh`'s
# `enforce_removal_gate` refuses every credit-removal DELETE unless the wrapper is
# in dry-run mode, so a removal "capability" in this module could only ever be a
# promise the deployed wrapper breaks. An undo is a removal, so the revert mode
# below is PLAN-ONLY: it prints the exact roles to remove, and a named human
# executes them through the approved removal path
# (skills-all/muso-ops-tracks -> Removal Requests). See
# docs/credit-verification/bulk-credit-change-drainer.md.


def wait_for_role(admin: CreditAdmin, profile_id: str, track_id: str, role: str,
                  *, attempts: int = READBACK_ATTEMPTS,
                  sleep=time.sleep) -> list[str] | None:
    """Read back until the role shows. Returns the role list, or None if the
    role was definitively ABSENT.

    Raises `Unavailable` when no read succeeded: "we could not look" is not "it
    is not there", and the caller must not tag a ticket on the strength of a
    read that never happened.
    """
    # `read_once` records whether ANY read succeeded: a failed read must never
    # erase a successful one, or a flaky window would be reported as "the role is
    # not there" — a verdict we never observed.
    seen: list[str] | None = None
    read_once = False
    last_read_ok = False
    for attempt in range(attempts):
        try:
            seen = profile_credit_roles(admin, profile_id).get(track_id, [])
            read_once = True
            last_read_ok = True
        except (AdminError, Unavailable):
            last_read_ok = False
        if seen and any(same_role(r, role) for r in seen):
            return seen
        if attempt + 1 < attempts:
            sleep(READBACK_SLEEP_SEC)
    # Only a read that SUCCEEDED can say "the role is not there". If the window
    # ended with a failure, the final state was never observed: that is not an
    # absence, and tagging on it would report a verdict we never had.
    if not read_once or not last_read_ok:
        raise Unavailable(
            f"could not read back profile {profile_id} track {track_id} in "
            f"{attempts} attempt(s) — the write may or may not have landed"
        )
    return seen


class Clock(Protocol):
    def __call__(self) -> float: ...


def _utc_today(now: float | None = None) -> str:
    return datetime.fromtimestamp(time.time() if now is None else now, timezone.utc).strftime("%Y-%m-%d")


class WritePath:
    """Kill files + one lock + shared daily cap + ledger. One per run."""

    def __init__(self, *, dry_run: bool, kill_files: Iterable[str] = KILL_FILES,
                 lock_path: str = LOCK_PATH, ledger_path: str = LEDGER_PATH,
                 cap_path: str = CAP_PATH, max_writes_per_day: int = MAX_WRITES_PER_DAY,
                 clock: Clock | None = None):
        self.dry_run = dry_run
        self.kill_files = tuple(kill_files)
        self.lock_path = lock_path
        self.ledger_path = ledger_path
        self.cap_path = cap_path
        self.max_writes_per_day = max_writes_per_day
        self._clock = clock or time.time
        self._lock_fd: int | None = None
        self.writes_this_run = 0

    # -- kill files -------------------------------------------------------
    def kill_reason(self) -> str | None:
        for path in self.kill_files:
            if os.path.exists(path):
                return f"kill file present: {path}"
        return None

    def assert_not_killed(self) -> None:
        reason = self.kill_reason()
        if reason:
            raise DrainBlocked(reason)

    # -- one lock ---------------------------------------------------------
    def acquire(self) -> None:
        path = Path(self.lock_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            raise DrainBlocked(f"another drain run holds {self.lock_path}") from None
        os.write(fd, f"{os.getpid()}\n".encode())
        os.lseek(fd, 0, os.SEEK_SET)
        self._lock_fd = fd

    def release(self) -> None:
        if self._lock_fd is not None:
            try:
                fcntl.flock(self._lock_fd, fcntl.LOCK_UN)
            finally:
                os.close(self._lock_fd)
                self._lock_fd = None

    def __enter__(self) -> "WritePath":
        self.assert_not_killed()
        self.acquire()
        self.assert_not_killed()  # kill file may have landed while we waited
        return self

    def __exit__(self, *exc_info) -> None:
        self.release()

    # -- shared daily cap -------------------------------------------------
    def _read_cap(self) -> dict:
        """Today's spend. ABSENT means zero (nobody has written yet); a file that
        exists and cannot be parsed is a HARD STOP.

        The distinction is the whole point: reading a corrupt budget as "zero
        writes today" hands out another full day out of a fleet-wide limit, and
        a budget nobody can read is exactly when we must not write. A human
        removes the file deliberately, or the day rolls over.
        """
        try:
            with open(self.cap_path, encoding="utf-8") as fh:
                raw = fh.read()
        except FileNotFoundError:
            return {}
        except OSError as exc:
            raise DrainBlocked(f"cannot read the write budget {self.cap_path}: {exc}") from None
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise DrainBlocked(
                f"write budget {self.cap_path} is not valid JSON ({exc}) — refusing to "
                "write against a budget that cannot be read"
            ) from None
        if not isinstance(data, dict):
            raise DrainBlocked(f"write budget {self.cap_path} is not a JSON object")
        today = _utc_today(self._clock())
        stored = data.get("date")
        # A budget with no readable date is a budget we cannot age, and "cannot
        # age" must not read as "zero spent today". The format check also makes
        # the lexicographic comparison below sound.
        try:
            datetime.strptime(stored, "%Y-%m-%d")
        except (TypeError, ValueError):
            raise DrainBlocked(
                f"write budget {self.cap_path} has an invalid `date` value "
                f"({stored!r}) — refusing to write against a budget that cannot "
                "be dated"
            ) from None
        if stored != today:
            # A PAST date is yesterday's budget: the day rolled over, so today
            # starts at zero. A FUTURE date is not a rollover — it means the
            # clock moved backwards under a budget that already recorded spend,
            # and reading it as zero would hand out another full day on top of
            # writes that really happened. Refuse instead of guessing.
            if stored > today:
                raise DrainBlocked(
                    f"write budget {self.cap_path} is dated {stored}, which is in "
                    f"the future (today is {today}) — refusing to write against a "
                    "budget whose clock disagrees with ours"
                )
            return {}
        used = data.get("used")
        if not isinstance(used, int) or isinstance(used, bool) or used < 0:
            raise DrainBlocked(
                f"write budget {self.cap_path} has an invalid `used` value ({used!r})"
            )
        return data

    def writes_used_today(self) -> int:
        return self._read_cap().get("used", 0)

    def writes_remaining_today(self) -> int:
        return max(self.max_writes_per_day - self.writes_used_today(), 0)

    def reserve_write(self) -> None:
        """Spend one of today's writes, or refuse. Called BEFORE the request so a
        crash cannot spend the budget twice.

        The kill files are re-checked HERE, at the per-row write boundary, not
        only in `__enter__`. A kill file is an emergency stop: ops creates it
        while a run is already holding the lock, and a check that only ran at
        acquisition would let an armed run POST the rest of its batch (up to 3
        tickets x 25 rows) after the stop was requested. The check is cheap and
        it is the last moment before the request leaves the process.
        """
        self.assert_not_killed()
        if self.dry_run:
            self.writes_this_run += 1
            return
        today = _utc_today(self._clock())
        used = self._read_cap().get("used", 0)
        if used >= self.max_writes_per_day:
            raise DailyCapReached(
                f"{self.max_writes_per_day} credit writes already made on {today}"
            )
        Path(self.cap_path).parent.mkdir(parents=True, exist_ok=True)
        tmp = f"{self.cap_path}.tmp.{os.getpid()}"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump({"date": today, "used": used + 1}, fh)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, self.cap_path)
        self.writes_this_run += 1

    # -- ledger -----------------------------------------------------------
    def record(self, row: dict) -> dict:
        entry = {"ts": datetime.fromtimestamp(self._clock(), timezone.utc).isoformat(),
                 "dry_run": self.dry_run, **row}
        if self.dry_run:
            return entry
        Path(self.ledger_path).parent.mkdir(parents=True, exist_ok=True)
        with open(self.ledger_path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry, sort_keys=True) + "\n")
            fh.flush()
            os.fsync(fh.fileno())
        return entry


def plan_revert(ledger_path: str) -> list[dict]:
    """Rows that would have to be undone, newest last (so caller reverses).

    Only rows that actually LANDED a role are undoable; `already` rows wrote
    nothing and `failed` rows changed nothing.
    """
    rows: list[dict] = []
    try:
        fh = open(ledger_path, encoding="utf-8")
    except FileNotFoundError:
        return rows
    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(entry, dict):
                continue
            if entry.get("action") != "add" or entry.get("outcome") != "verified":
                continue
            if entry.get("reverted"):
                continue
            rows.append(entry)
    return rows
