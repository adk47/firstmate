#!/usr/bin/env python3
"""Approve ticket-scoped UVNs with authoritative live Spotify popularity <30."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import socket
import subprocess
import sys
import time
from contextlib import contextmanager, nullcontext
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlencode

sys.path.insert(0, str(Path(__file__).resolve().parent))
from credit_review import account_gate  # noqa: E402
from lib.customer_outcome import (  # noqa: E402
    OUTCOME_COMPLETE,
    customer_outcome_of,
    outcome_tag,
    outcome_tags_of,
)

from uvn_under30_policy import (
    APPROVED,
    DenyList,
    PolicyError,
    UVN,
    approved_ids_from_records,
    reversal_verdict,
    every_scoped_request_approved,
    has_hard_reject_signal,
    live_popularity,
    load_deny_list,
    load_fraud_ids,
    no_pending_rows_remaining,
    parse_ticket_scope,
    pending_request_ids,
    qualifies_for_approval,
    resolve_profile_scope,
)


LIST_ID = "901000600160"
SERVICE_REQUESTER = "uvn-popularity-cron@hydra-ops"
# muso-admin-api.sh MUSO_ADMIN_IDENTITY: this automation's own admin login.
ADMIN_IDENTITY = "uvn-cron"
CONDITIONAL_PATH = "/admin/credit-requests/conditional-status"
MUSO_BIN = os.environ.get("MUSO_BIN", "/usr/local/bin/muso")
ADMIN_SCRIPT = os.environ.get(
    "UVN_ADMIN_SCRIPT",
    "/opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh",
)
STATUS_VERIFY = os.environ.get(
    "UVN_STATUS_VERIFY",
    "/opt/hydra/workspaces/operations/skills/muso-ops-credit-verification/scripts/verify-credit-request-status.sh",
)
FRAUD_ROOT = Path(os.environ.get("UVN_FRAUD_ROOT", "/var/log/openclaw/credit-batch-runs"))
# The proof-required / deny lists and editorial role terms the credit-trust
# decider also reads, and the decider's ledger, whose doc_required marker
# names the support requests that need documents: none of those rows is ever
# approved here.
DENY_POLICY_PATH = Path(os.environ.get(
    "CREDIT_TRUST_DECIDE_POLICY",
    Path(__file__).resolve().parents[1] / "policies" / "credit-trust-decide.json",
))
DECIDE_LEDGER_PATH = Path(os.environ.get("CREDIT_REVIEW_LEDGER", "/var/lib/hydra/credit-review/ledger.sqlite3"))
FRAUD_ATTEMPT_PATH = Path(os.environ.get(
    "CV_FRAUD_ATTEMPT_PATH",
    "/var/log/muso-ops/fraud-uvn-attempts.jsonl",
))
AUDIT_ROOT = Path(os.environ.get(
    "UVN_AUDIT_ROOT",
    "/opt/hydra/workspaces/operations/api-logs/uvn-under30-cron",
))
WRITE_LOCK_PATH = Path(os.environ.get("CV_CREDIT_WRITE_LOCK_PATH", "/var/lib/hydra/credit-status-writes.lock"))
UNRESOLVED_PATH = Path(os.environ.get("UVN_UNRESOLVED_PATH", "/var/lib/hydra/uvn-under30-unresolved.json"))
AUTOMATION_TAG = "automation:uvn-under30"
MANUAL_HANDOFF_MARKER = "Manual review handoff recorded by the under-30 credit check."
# Shadow mode records what apply mode WOULD approve and writes nothing else.
SHADOW_LOG_PATH = Path(os.environ.get("UVN_SHADOW_LOG_PATH", "/var/log/muso-ops/uvn-under30-shadow.jsonl"))
# A present file silences the cron without a deploy (same pattern as
# /etc/hydra/dr-ai-healer.disabled). Deliberate human act, so it is quiet.
KILL_SWITCH_PATH = Path(os.environ.get("UVN_KILL_SWITCH_PATH", "/etc/hydra/uvn-under30-cron.disabled"))
EXPECTED_HOST = os.environ.get("UVN_EXPECTED_HOST", "ovh-node-8")
# A profile carrying more pending rows than this is a bulk submission for a
# human, not a customer asking about their pending credits.
MAX_PROFILE_ROWS = 100
# A human undoing our approvals is the one signal that the sub-30 rule approved
# something it should not have. Humans reversed 0 of 127 of their own approvals
# in the 45 days before this automation wrote anything, so the tolerance is
# near zero and the lane stops writing rather than repeat a mistake hourly.
# Read and validated at USE time, like CV_CREDIT_WRITE_LOCK_WAIT_SECS: a guard
# that silently disables itself on a typo'd env var is worse than no guard, and
# int() at import would only produce a traceback with no summary.
DEFAULT_REVERSAL_WINDOW_DAYS = "14"
DEFAULT_MAX_REVERSALS = "1"
MAX_REVERSAL_WINDOW_DAYS = 365
# Stated to human reviewers on the ticket, so it must match the schedule in
# cron-jobs.json. The contract test pins the two together: a cadence change that
# leaves this behind tells a reviewer to wait four times longer than it takes.
RUN_CADENCE_TEXT = "every hour"
# The cron runner kills the process at timeoutSeconds (1200 in cron-jobs.json)
# with no summary. A slow-but-alive route never trips the per-call timeout, so
# the run itself stops at this budget and still announces what it did.
RUN_BUDGET_SECS = int(os.environ.get("UVN_RUN_BUDGET_SECS", "900"))


class RunError(RuntimeError):
    pass


class TicketNoLongerEligible(RuntimeError):
    pass


class StopRun(RunError):
    """The run must stop before the next ticket, but still announce itself."""

    headline = "The run stopped early and no further tickets were assessed."


class LookupUnavailable(StopRun):
    """The live popularity source is down. Approval is defined over a live
    reading, so the run stops rather than waiting out every track."""

    headline = "Live Spotify popularity is unavailable, so the run stopped early and no further tickets were assessed."


class RunBudgetExhausted(StopRun):
    """The run reached its time budget before the cron runner could kill it."""

    headline = "The run reached its time budget, so it stopped early and no further tickets were assessed."


class ReversalCircuitOpen(RunError):
    """Humans have been undoing our approvals; stop writing until reviewed."""


class ReversalCheckUnavailable(RunError):
    """The reversal history could not be read, so writes cannot be justified."""


class ApprovalAttemptError(RunError):
    def __init__(self, message: str, confirmed_ids: set[str] | None = None):
        super().__init__(message)
        self.confirmed_ids = confirmed_ids or set()


# A healthy admin call answers in seconds; Cloudflare gives up on the origin
# at ~100s, so a lookup still running at 45s is a dead route, not a slow one.
LOOKUP_TIMEOUT_SECS = 45


def run_json(
    argv: list[str], env: dict[str, str] | None = None, timeout: int = 120
) -> dict[str, Any]:
    result = subprocess.run(argv, capture_output=True, text=True, env=env, timeout=timeout, check=False)
    if result.returncode != 0:
        raise RunError(f"command failed rc={result.returncode}: {result.stderr.strip()[:500]}")
    try:
        parsed = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RunError("command returned non-JSON output") from exc
    if not isinstance(parsed, dict):
        raise RunError("command returned non-object JSON")
    return parsed


def clickup(method: str, path: str, body: dict[str, Any] | None = None, query: list[str] | None = None) -> Any:
    argv = [MUSO_BIN, "clickup", "raw", method, path]
    for value in query or []:
        argv.extend(["--query", value])
    if method != "GET":
        argv.extend(["--requester", SERVICE_REQUESTER])
    if method == "DELETE":
        argv.append("--yes")
    if body is not None:
        argv.extend(["--data", json.dumps(body, separators=(",", ":"), sort_keys=True)])
    argv.append("--json")
    envelope = run_json(argv)
    if "data" not in envelope:
        raise RunError("ClickUp response is missing data")
    return envelope["data"]


def admin_raw(
    method: str, path: str, body: dict[str, Any] | None = None, timeout: int = 120
) -> dict[str, Any]:
    argv = ["bash", ADMIN_SCRIPT, "--requester", SERVICE_REQUESTER, "call", method, path]
    if body is not None:
        argv.append(json.dumps(body, separators=(",", ":"), sort_keys=True))
    env = dict(os.environ)
    env["UVN_POPULARITY_CRON"] = "1"
    return run_json(argv, env=env, timeout=timeout)


def admin(
    method: str, path: str, body: dict[str, Any] | None = None, timeout: int = 120
) -> dict[str, Any]:
    response = admin_raw(method, path, body, timeout=timeout)
    status = response.get("http_status")
    if not isinstance(status, int) or status < 200 or status >= 300:
        raise RunError(f"admin API returned HTTP {status}")
    return response.get("body", {})


def list_todo_tickets() -> list[dict[str, Any]]:
    tickets: list[dict[str, Any]] = []
    for page in range(100):
        payload = clickup(
            "GET",
            f"/list/{LIST_ID}/task",
            query=["archived=false", "include_closed=false", "statuses[]=to do", f"page={page}"],
        )
        page_tasks = payload.get("tasks") if isinstance(payload, dict) else None
        if not isinstance(page_tasks, list):
            raise RunError("ClickUp task page is malformed")
        tickets.extend(page_tasks)
        if not page_tasks or payload.get("last_page") is True:
            return tickets
    raise RunError("ClickUp pagination exceeded 100 pages")


def is_automation_ready_task(task: dict[str, Any]) -> bool:
    tags = {
        str(tag.get("name", "")).strip().lower()
        for tag in task.get("tags", [])
        if isinstance(tag, dict)
    }
    required_tags = {"hydra-action-request", "action:credit-verify", AUTOMATION_TAG}
    status = str(task.get("status", {}).get("status", "")).strip().lower()
    return status == "to do" and required_tags.issubset(tags)


def has_manual_handoff(comments: list[dict[str, Any]]) -> bool:
    return any(
        MANUAL_HANDOFF_MARKER
        in str(comment.get("comment_text") or comment.get("text_content") or "")
        for comment in comments
    )


def get_task_and_comments(task_id: str) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    task = get_task(task_id)

    comments: list[dict[str, Any]] = []
    query: list[str] = []
    seen_cursors: set[tuple[str, str]] = set()
    for _ in range(100):
        comment_payload = clickup("GET", f"/task/{task_id}/comment", query=query)
        page_comments = comment_payload.get("comments") if isinstance(comment_payload, dict) else None
        if not isinstance(page_comments, list) or any(not isinstance(value, dict) for value in page_comments):
            raise RunError(f"ClickUp comments for {task_id} are malformed")
        comments.extend(page_comments)
        if len(page_comments) < 25:
            return task, comments
        last = page_comments[-1]
        start = str(last.get("date", ""))
        start_id = str(last.get("id", ""))
        cursor = (start, start_id)
        if not start or not start_id or cursor in seen_cursors:
            raise RunError(f"ClickUp comment pagination stalled for {task_id}")
        seen_cursors.add(cursor)
        query = [f"start={start}", f"start_id={start_id}"]
    raise RunError(f"ClickUp comment pagination exceeded 100 pages for {task_id}")


def get_task(task_id: str) -> dict[str, Any]:
    task = clickup("GET", f"/task/{task_id}")
    if not isinstance(task, dict):
        raise RunError(f"ClickUp task {task_id} returned malformed detail")
    return task


def reversal_settings() -> tuple[int, int]:
    """(window days, tolerated reversals), or refuse.

    Both bound a write gate, so an unusable value must stop the run rather than
    quietly widen it: a window of 0 filters every record out and the breaker
    would pass on an empty history it never actually read.
    """
    def bounded(raw: str, name: str, low: int, high: int) -> int:
        text = str(raw).strip()
        if not text.lstrip("-").isdigit():
            raise ReversalCheckUnavailable(f"{name} must be an integer, got {raw!r}")
        value = int(text)
        if value < low or value > high:
            raise ReversalCheckUnavailable(f"{name} must be between {low} and {high}, got {value}")
        return value

    window = bounded(
        os.environ.get("UVN_REVERSAL_WINDOW_DAYS", DEFAULT_REVERSAL_WINDOW_DAYS),
        "UVN_REVERSAL_WINDOW_DAYS", 1, MAX_REVERSAL_WINDOW_DAYS,
    )
    tolerance = bounded(
        os.environ.get("UVN_MAX_REVERSALS", DEFAULT_MAX_REVERSALS),
        "UVN_MAX_REVERSALS", 0, 1000,
    )
    return window, tolerance


def load_recent_approvals(days: int) -> set[str]:
    """Request ids this automation approved and read back within the window.

    A history we cannot read is not a history with nothing in it. The audit root
    is where this cron writes its own approvals, so an absent or unreadable one
    means we cannot prove earlier writes held — refuse, exactly as
    load_fraud_ids does for the fraud truth floor.
    """
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    cutoff_iso = cutoff.isoformat()
    records: list[Any] = []
    try:
        if not AUDIT_ROOT.is_dir():
            raise ReversalCheckUnavailable(f"approval audit root is unavailable: {AUDIT_ROOT}")
        paths = sorted(AUDIT_ROOT.glob("*.jsonl"))
    except OSError as exc:
        raise ReversalCheckUnavailable(f"approval audit root could not be read: {AUDIT_ROOT}") from exc
    for path in paths:
        try:
            if datetime.strptime(path.stem, "%Y-%m-%d").replace(tzinfo=timezone.utc) < cutoff.replace(
                hour=0, minute=0, second=0, microsecond=0
            ):
                continue
        except ValueError:
            pass
        try:
            with path.open("r", encoding="utf-8") as handle:
                for line in handle:
                    if not line.strip():
                        continue
                    try:
                        records.append(json.loads(line))
                    except json.JSONDecodeError as exc:
                        raise ReversalCheckUnavailable(
                            f"approval audit record is unreadable at {path}"
                        ) from exc
        except OSError as exc:
            raise ReversalCheckUnavailable(f"approval audit file could not be read: {path}") from exc
    return approved_ids_from_records(records, cutoff_iso)


def assert_no_reversal_streak(run_id: str) -> None:
    """Refuse to approve when humans have been undoing our approvals.

    Fails closed: if the readback cannot run we cannot prove our past writes
    held, which is not the same as proving they did.
    """
    window_days, tolerance = reversal_settings()
    approved = load_recent_approvals(window_days)
    if not approved:
        return
    ids = sorted(approved)
    try:
        still_approved = verify_status(ids)
    except (RunError, subprocess.TimeoutExpired) as exc:
        raise ReversalCheckUnavailable(
            f"earlier approvals could not be checked for reversals: {str(exc)[:200]}"
        ) from exc
    reversed_ids, tripped = reversal_verdict(approved, still_approved, tolerance)
    if reversed_ids:
        audit(run_id, "reversal_observed", {
            "request_ids": reversed_ids,
            "checked": len(ids),
            "window_days": window_days,
            "tripped": tripped,
        })
    if tripped:
        raise ReversalCircuitOpen(
            f"{len(reversed_ids)} of {len(ids)} previously approved requests are no longer approved: "
            + ", ".join(reversed_ids[:10])
        )


def load_required_fraud_ids() -> set[str]:
    try:
        return load_fraud_ids(FRAUD_ROOT, FRAUD_ATTEMPT_PATH)
    except PolicyError as exc:
        raise RunError(f"fraud safety data is unavailable: {exc}") from exc


def load_required_deny_list():
    try:
        return load_deny_list(DENY_POLICY_PATH, DECIDE_LEDGER_PATH)
    except PolicyError as exc:
        raise RunError(f"deny-list safety data is unavailable: {exc}") from exc


def list_profile_requests(profile_id: str) -> dict[str, dict[str, Any]]:
    rows: dict[str, dict[str, Any]] = {}
    for page in range(1, 101):
        path = "/admin/credit-requests?" + urlencode({"profilesIds": profile_id, "limit": 1000, "page": page})
        body = admin("GET", path)
        items = body.get("data", {}).get("items") if isinstance(body, dict) else None
        if not isinstance(items, list):
            raise RunError("credit-request list response is malformed")
        for item in items:
            if isinstance(item, dict) and item.get("id"):
                rows[str(item["id"])] = item
        if len(items) < 1000:
            return rows
    raise RunError(f"credit-request pagination exceeded 100 pages for profile {profile_id}")


def lookup_timeout(remaining_secs: float) -> int:
    """Per-call timeout, never longer than the time the run has left."""
    return max(1, min(LOOKUP_TIMEOUT_SECS, int(remaining_secs)))


def spotify_lookup(track_id: str, timeout: int | None = None) -> dict[str, Any]:
    """{"found": True, "track": {...popularity...}} or {"found": False}.

    The admin route answers {result, code, data} with `data` being the track
    itself (core-backend src/apis/_admin/spotify/webLookup.js: res.response(
    await getTrack(id)); getTrack puts `popularity` at the top level).

    Exactly ONE answer is a verdict about the track: 404, which webLookup.js
    raises only for `e.response?.status === 404` ("not found on Spotify").
    Everything else is an outage and stops the run:

    - 400 is BadRequest for a malformed type/id — our own call is broken, so
      reading it as "no such track" would disqualify every row on a bug.
    - a 2xx whose popularity is absent or non-numeric is the spclient path
      degrading: getTrack seeds `popularity: null` and swallows the spclient
      error, so accepting it would silently disqualify every row fleet-wide —
      the exact silent failure this cron exists to make loud.
    """
    path = "/admin/spotify/web-lookup?" + urlencode({"type": "track", "id": track_id})
    try:
        response = admin_raw("GET", path, timeout=timeout or LOOKUP_TIMEOUT_SECS)
    except (RunError, subprocess.TimeoutExpired) as exc:
        raise LookupUnavailable(
            f"live Spotify popularity lookup failed for track {track_id}: {str(exc)[:200]}"
        ) from exc
    status = response.get("http_status")
    if status == 404:
        return {"found": False}
    if not isinstance(status, int) or status < 200 or status >= 300:
        raise LookupUnavailable(f"live Spotify popularity lookup answered HTTP {status} for track {track_id}")
    body = response.get("body")
    track = body.get("data") if isinstance(body, dict) else None
    if not isinstance(track, dict):
        raise LookupUnavailable(f"live Spotify popularity lookup returned no data for track {track_id}")
    popularity = track.get("popularity")
    if isinstance(popularity, bool) or not isinstance(popularity, (int, float)):
        raise LookupUnavailable(
            f"live Spotify popularity lookup returned no usable popularity for track {track_id}"
        )
    return {"found": True, "track": track}


def audit(run_id: str, action: str, payload: dict[str, Any]) -> None:
    AUDIT_ROOT.mkdir(parents=True, exist_ok=True)
    record = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "agent": "operations",
        "run_id": run_id,
        "requester": SERVICE_REQUESTER,
        "target": payload.get("ticket_id") or payload.get("request_ids") or "uvn-under30-cron",
        "authorization": "Jan Slack 1786377507.873799; Nick scheduler request 1786383126.525759",
        "action": action,
        **payload,
    }
    path = AUDIT_ROOT / f"{datetime.now(timezone.utc):%Y-%m-%d}.jsonl"
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, separators=(",", ":"), sort_keys=True) + "\n")
        handle.flush()
        os.fsync(handle.fileno())


def verify_status(ids: list[str]) -> set[str]:
    result = subprocess.run(
        ["bash", STATUS_VERIFY, "--expected", APPROVED, "--ids", ",".join(ids)],
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    if result.returncode not in (0, 1):
        raise RunError(f"approval readback failed rc={result.returncode}: {result.stderr.strip()[:500]}")
    try:
        report = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RunError("approval readback returned non-JSON output") from exc
    mismatched = report.get("mismatched") if isinstance(report, dict) else None
    matched = report.get("matched") if isinstance(report, dict) else None
    if (
        not isinstance(mismatched, list)
        or not isinstance(matched, int)
        or isinstance(matched, bool)
        or report.get("expected") != APPROVED
    ):
        raise RunError("approval readback returned a malformed report")
    requested = set(ids)
    mismatch_ids: set[str] = set()
    for value in mismatched:
        if (
            not isinstance(value, dict)
            or not isinstance(value.get("id"), str)
            or value["id"] not in requested
            or not isinstance(value.get("actual"), str)
        ):
            raise RunError("approval readback returned a malformed mismatch")
        mismatch_ids.add(value["id"])
    confirmed = requested - mismatch_ids
    if len(mismatch_ids) != len(mismatched) or matched != len(confirmed):
        raise RunError("approval readback counts do not cover the exact requested IDs")
    return confirmed


def load_unresolved_ids() -> set[str]:
    if not UNRESOLVED_PATH.exists():
        return set()
    try:
        value = json.loads(UNRESOLVED_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RunError("unresolved approval state is unreadable") from exc
    ids = value.get("request_ids") if isinstance(value, dict) else None
    if not isinstance(ids, list) or any(not isinstance(item, str) for item in ids):
        raise RunError("unresolved approval state is malformed")
    return set(ids)


def write_unresolved_ids(run_id: str, request_ids: set[str], reason: str) -> None:
    audit(run_id, "unresolved_state_write_planned", {"request_ids": sorted(request_ids), "reason": reason})
    UNRESOLVED_PATH.parent.mkdir(parents=True, exist_ok=True)
    temp_path = UNRESOLVED_PATH.with_name(f"{UNRESOLVED_PATH.name}.tmp.{os.getpid()}")
    payload = {
        "updated_at": datetime.now(timezone.utc).isoformat(),
        "request_ids": sorted(request_ids),
        "reason": reason,
    }
    with temp_path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, separators=(",", ":"), sort_keys=True)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temp_path, UNRESOLVED_PATH)
    # Atomic rename alone does not make the directory entry durable across a
    # host/power crash. The pre-write marker is the safety boundary, so refuse
    # the admin call unless both file data and rename metadata are on disk.
    directory_fd = os.open(UNRESOLVED_PATH.parent, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def mark_unresolved(run_id: str, ids: list[str], reason: str) -> None:
    write_unresolved_ids(run_id, load_unresolved_ids() | set(ids), reason)


def clear_unresolved(run_id: str, ids: list[str]) -> None:
    current = load_unresolved_ids()
    if current.intersection(ids):
        write_unresolved_ids(run_id, current - set(ids), "cleared_after_exact_2xx_and_readback")


def account_gate_filter(
    request_ids: list[str],
    rows: dict[str, dict[str, Any]],
    gate: Any,
) -> tuple[list[str], dict[str, str]]:
    """(the ids whose account the gate ALLOWS, {held id: why}). Fail closed: no user id, hold,
    unknown or a failed check is held. ``gate`` is account_gate.Cached (one call per account)."""
    keep: list[str] = []
    held: dict[str, str] = {}
    for request_id in request_ids:
        result = gate(rows.get(request_id, {}).get("userId"))
        if result.allowed:
            keep.append(request_id)
        else:
            held[request_id] = result.why()
    return keep, held


def approve_chunk(run_id: str, task_id: str, ids: list[str]) -> set[str]:
    body = {"requestIds": ids, "status": APPROVED, "expectedStatus": UVN}
    audit(run_id, "approve_planned", {"ticket_id": task_id, "request_ids": ids, "body": body})
    # Write the durable blocker before the network call. A SIGKILL after the
    # backend commits cannot otherwise leave any local evidence, and a later
    # run could see only APPROVED rows and resolve the ticket. Exact 2xx plus
    # exact readback below is the only path that clears this state.
    mark_unresolved(run_id, ids, "approval attempt started; exact outcome not yet confirmed")
    response: dict[str, Any] | None = None
    api_error: str | None = None
    try:
        response = admin_raw("PUT", CONDITIONAL_PATH, body)
    except (RunError, subprocess.TimeoutExpired) as exc:
        api_error = str(exc)
    try:
        confirmed = verify_status(ids)
    except (RunError, subprocess.TimeoutExpired) as exc:
        mark_unresolved(run_id, ids, f"readback unavailable after write attempt: {exc}")
        raise ApprovalAttemptError(str(exc)) from exc
    status = response.get("http_status") if isinstance(response, dict) else None
    response_body = response.get("body") if isinstance(response, dict) else None
    if (status == 400 and not confirmed and isinstance(response_body, dict)
            and response_body.get("errorCode") == "agent_cannot_approve_declined"):
        # The server wrote NOTHING and said so: the attempt is resolved (not
        # approved). Clear the blocker, record why, and leave the rows held.
        audit(run_id, "approve_refused_by_server", {
            "ticket_id": task_id, "request_ids": ids,
            "refused": response_body.get("refused"), "refused_request_ids": response_body.get("refusedRequestIds")})
        clear_unresolved(run_id, ids)
        return set()
    data = response_body.get("data") if isinstance(response_body, dict) else None
    updated = data.get("updatedIds") if isinstance(data, dict) else None
    exact_success = (
        api_error is None
        and isinstance(status, int)
        and 200 <= status < 300
        and isinstance(updated, list)
        and set(updated) == set(ids)
        and confirmed == set(ids)
    )
    if not exact_success:
        reason = api_error or f"HTTP {status}; updated={updated}; confirmed={sorted(confirmed)}"
        mark_unresolved(run_id, ids, reason)
        audit(run_id, "approve_unresolved", {
            "ticket_id": task_id,
            "request_ids": ids,
            "confirmed_ids": sorted(confirmed),
            "reason": reason,
        })
        raise ApprovalAttemptError(f"conditional approval unresolved: {reason}", confirmed)
    clear_unresolved(run_id, ids)
    audit(run_id, "approve_verified", {"ticket_id": task_id, "request_ids": ids})
    return confirmed


@contextmanager
def credit_write_lock():
    wait_raw = os.environ.get("CV_CREDIT_WRITE_LOCK_WAIT_SECS", "600")
    if not wait_raw.isascii() or not wait_raw.isdigit() or int(wait_raw) <= 0:
        raise RunError("CV_CREDIT_WRITE_LOCK_WAIT_SECS must be a positive integer")
    wait_seconds = int(wait_raw)
    WRITE_LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
    with WRITE_LOCK_PATH.open("a+", encoding="utf-8") as handle:
        deadline = time.monotonic() + wait_seconds
        while True:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise RunError("timed out waiting for the shared credit-write lock")
                time.sleep(min(1, remaining))
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def assert_ticket_scope(
    task_id: str,
    expected_profile_id: str,
    expected_narrowing: set[str] | None,
) -> dict[str, Any]:
    task, comments = get_task_and_comments(task_id)
    if not is_automation_ready_task(task):
        raise TicketNoLongerEligible
    profile_id, narrowing = parse_ticket_scope(task, comments)
    if profile_id != expected_profile_id or narrowing != expected_narrowing:
        raise PolicyError("ticket scope changed during the run")
    return task


def shadow_record(
    run_id: str,
    ticket_id: str,
    profile_id: str,
    request_ids: list[str],
    popularity: dict[str, Any],
) -> None:
    SHADOW_LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    record = {
        "acted_at": int(time.time()),
        "run_id": run_id,
        "mode": "shadow",
        "ticket_id": ticket_id,
        "profile_id": profile_id,
        "request_ids": request_ids,
        "popularity": popularity,
    }
    with SHADOW_LOG_PATH.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, separators=(",", ":"), sort_keys=True) + "\n")
    audit(run_id, "shadow_would_approve", {"ticket_id": ticket_id, "request_ids": request_ids})


PENDING_LINES_SHOWN = 20


def render_pending_lines(
    profile_id: str,
    rows: dict[str, dict[str, Any]],
    fraud_ids: set[str],
    live_by_track: dict[str, dict[str, Any]],
    deny: DenyList,
) -> list[str]:
    """Header plus one line per row still in verification, for the human reviewer.

    Every line states only what this run measured: a popularity it read, a
    track Spotify no longer serves, or the fact that the row was never checked
    (approval cap, or an earlier stop). Empty when nothing is pending.
    """
    pending = sorted(pending_request_ids(profile_id, rows))
    if not pending:
        return []
    lines = [f"Still in verification on this profile ({len(pending)} rows):"]
    for request_id in pending[:PENDING_LINES_SHOWN]:
        row = rows[request_id]
        title = str(row.get("spotifyTrackTitle") or "untitled track")
        roles = ", ".join(str(role) for role in row.get("credits") or []) or "no role recorded"
        track_id = row.get("spotifyTrackId")
        if request_id in fraud_ids:
            why = "excluded: fraud marker"
        elif deny.blocks(row):
            why = f"excluded: {deny.why(row)}"
        elif has_hard_reject_signal(row):
            why = "excluded: backend reject or hold signal"
        elif not isinstance(track_id, str) or not track_id:
            why = "excluded: no Spotify track"
        elif track_id not in live_by_track:
            why = "not checked this run"
        elif live_by_track[track_id].get("found") is not True:
            why = "excluded: track not found on Spotify"
        else:
            popularity = live_popularity(live_by_track[track_id])
            why = f"popularity {popularity}" if popularity is not None else "popularity unavailable"
        lines.append(f'- "{title}" ({roles}) — {why} — {request_id}')
    if len(pending) > PENDING_LINES_SHOWN:
        lines.append(f"- and {len(pending) - PENDING_LINES_SHOWN} more")
    return lines


def replace_customer_outcome_tag(
    run_id: str,
    task_id: str,
    task: dict[str, Any],
    outcome: str,
) -> None:
    desired = outcome_tag(outcome)
    existing = outcome_tags_of(task)
    audit(run_id, "customer_outcome_write_planned", {
        "ticket_id": task_id,
        "outcome": outcome,
        "replaces": sorted(existing - {desired}),
    })
    for tag in sorted(existing - {desired}):
        clickup("DELETE", f"/task/{task_id}/tag/{quote(tag, safe='')}")
    if desired not in existing:
        clickup("POST", f"/task/{task_id}/tag/{quote(desired, safe='')}")
    if customer_outcome_of(get_task(task_id)) != outcome:
        raise RunError(f"customer outcome readback failed for ClickUp task {task_id}")
    audit(run_id, "customer_outcome_write_complete", {
        "ticket_id": task_id,
        "outcome": outcome,
    })


def assert_rows_match_scope(
    profile_id: str,
    scoped_ids: set[str],
    rows: dict[str, dict[str, Any]],
) -> None:
    if any(
        request_id not in rows or rows[request_id].get("profileId") != profile_id
        for request_id in scoped_ids
    ):
        raise PolicyError("a scoped credit request is missing or belongs to another profile")


def update_ticket(
    run_id: str,
    task_id: str,
    comment: str,
    resolve: bool,
    expected_profile_id: str | None = None,
    expected_narrowing: set[str] | None = None,
    expected_ids: set[str] | None = None,
) -> bool:
    audit(run_id, "clickup_write_planned", {"ticket_id": task_id, "resolve": resolve, "comment": comment})
    clickup("POST", f"/task/{task_id}/comment", {"comment_text": comment, "notify_all": False})
    if resolve:
        if expected_profile_id is None or expected_ids is None:
            raise RunError("safe ticket resolution requires the complete structured scope")
        # The comment write above is itself mutable ticket state. Re-read every
        # field and every comment after it, then check the exact request set and
        # durable unresolved-write state immediately before the status PUT.
        current_task = assert_ticket_scope(task_id, expected_profile_id, expected_narrowing)
        rows = list_profile_requests(expected_profile_id)
        assert_rows_match_scope(expected_profile_id, expected_ids, rows)
        if not every_scoped_request_approved(expected_ids, rows):
            audit(run_id, "clickup_resolve_skipped", {"ticket_id": task_id, "reason": "non-approved scoped ID"})
            audit(run_id, "clickup_write_complete", {"ticket_id": task_id, "resolve": False})
            return False
        if not no_pending_rows_remaining(expected_profile_id, rows):
            audit(run_id, "clickup_resolve_skipped", {"ticket_id": task_id, "reason": "profile still has pending rows"})
            audit(run_id, "clickup_write_complete", {"ticket_id": task_id, "resolve": False})
            return False
        if expected_ids.intersection(load_unresolved_ids()):
            audit(run_id, "clickup_resolve_skipped", {"ticket_id": task_id, "reason": "unresolved approval attempt"})
            audit(run_id, "clickup_write_complete", {"ticket_id": task_id, "resolve": False})
            return False
        replace_customer_outcome_tag(
            run_id, task_id, current_task, OUTCOME_COMPLETE)
        clickup("PUT", f"/task/{task_id}", {"status": "resolved"})
    audit(run_id, "clickup_write_complete", {"ticket_id": task_id, "resolve": resolve})
    return resolve


def remove_automation_tag(run_id: str, task_id: str) -> None:
    audit(run_id, "automation_tag_remove_planned", {"ticket_id": task_id, "tag": AUTOMATION_TAG})
    clickup("DELETE", f"/task/{task_id}/tag/{quote(AUTOMATION_TAG, safe='')}")
    audit(run_id, "automation_tag_remove_complete", {"ticket_id": task_id, "tag": AUTOMATION_TAG})


def render_shadow_summary(
    scanned: int, would_approve: int, failures: int, failed_tickets: list[str] | None = None
) -> str:
    lines = ["Credit verification check complete (shadow mode)."]
    if failures:
        ticket_word = "ticket" if failures == 1 else "tickets"
        lines.append(f"{failures} {ticket_word} could not be assessed safely and would stay open for manual review.")
        if failed_tickets:
            lines.append(f"Tickets that could not be assessed: {', '.join(failed_tickets)}")
    lines.extend([
        f"• Tickets ready for automatic review: {scanned}",
        f"• Requests that would have been approved (live Spotify popularity below 30): {would_approve}",
        "No changes were made. No credits were approved or rejected.",
    ])
    return "\n".join(lines)


def render_summary(
    scanned: int,
    approved_count: int,
    resolved: int,
    remaining: int,
    failures: int,
    limit_reached: bool = False,
) -> str:
    lines = [
        (
            "Credit verification automation needs attention."
            if failures
            else "Credit verification check complete."
        )
    ]
    if failures:
        ticket_word = "ticket" if failures == 1 else "tickets"
        verb = "is" if failures == 1 else "are"
        lines.append(
            f"{failures} {ticket_word} could not be processed safely and {verb} still open "
            "for manual review."
        )
    lines.extend([
        f"• Tickets ready for automatic review: {scanned}",
        f"• Requests approved after confirming live Spotify popularity below 30: {approved_count}",
        f"• Tickets resolved: {resolved}",
        f"• Tickets still open: {remaining}",
        "No credits were rejected.",
    ])
    if limit_reached:
        lines.append("The approval cap for this run was reached; the remaining requests are reviewed next run.")
    return "\n".join(lines)


def render_reversal_halt(reason: object) -> str:
    """Someone undid our approvals. Name that cause and only that cause."""
    return "\n".join([
        "Credit verification automation is paused and needs a human decision.",
        "It stopped before reviewing any ticket because approvals it made earlier are "
        "no longer approved, which usually means someone disagreed with them.",
        "No credits were approved or rejected in this run.",
        f"Details: {str(reason).strip()[:400]}",
        "Someone should look at those requests before this runs in apply mode again; "
        "set the argv back to --mode shadow to keep collecting evidence meanwhile.",
    ])


def render_reversal_unavailable(reason: object) -> str:
    """We could not CHECK for reversals, which is not the same as finding one."""
    return "\n".join([
        "Credit verification automation stopped before reviewing any ticket.",
        "Its record of earlier approvals could not be checked, so it cannot show that "
        "those approvals still stand. Nothing is known to be wrong with them.",
        "No credits were approved or rejected in this run.",
        f"Details: {str(reason).strip()[:400]}",
        "Fix the setting or the audit record and re-run; --mode shadow keeps collecting "
        "evidence meanwhile.",
    ])


def render_startup_failure(reason: object) -> str:
    detail = str(reason).strip()[:300] or "unknown error"
    return "\n".join([
        "Credit verification automation needs attention.",
        "The automatic check could not start, so no tickets were reviewed or changed.",
        "No credits were approved or rejected.",
        f"Technical details: {detail}",
    ])


def read_write_edge(
    task_id: str, profile_id: str, narrowing: set[str] | None
) -> tuple[set[str], dict[str, dict[str, Any]], set[str]]:
    """Re-read every mutable policy input (ticket scope, fraud floor, rows, scope).

    Called immediately before each decision so no write rests on a stale read.
    """
    assert_ticket_scope(task_id, profile_id, narrowing)
    fraud_ids = load_required_fraud_ids()
    rows = list_profile_requests(profile_id)
    scope = resolve_profile_scope(profile_id, narrowing, rows, MAX_PROFILE_ROWS)
    return fraud_ids, rows, scope


def lookup_candidates(
    planned_chunk: list[str],
    scope: set[str],
    rows: dict[str, dict[str, Any]],
    fraud_ids: set[str],
) -> list[tuple[str, str]]:
    """(request_id, spotify_track_id) pairs still eligible for a live popularity read."""
    pairs: list[tuple[str, str]] = []
    for request_id in planned_chunk:
        if request_id not in scope:
            continue
        row = rows[request_id]
        track_id = row.get("spotifyTrackId")
        if row.get("status") != UVN or request_id in fraud_ids:
            continue
        if not isinstance(track_id, str) or not track_id:
            continue
        pairs.append((request_id, track_id))
    return pairs


def run_locked(run_id: str, *, mode: str, limit: int) -> int:
    scanned = approved_count = resolved = remaining = failures = hard_failures = 0
    would_approve = 0
    changed = limit_reached = False
    failed_tickets: list[str] = []
    deadline = time.monotonic() + RUN_BUDGET_SECS
    gate_cache = account_gate.Cached()  # one account-gate call per user per run

    def check_budget() -> None:
        if time.monotonic() > deadline:
            raise RunBudgetExhausted(f"run budget of {RUN_BUDGET_SECS}s exhausted")

    def measure_tracks(pairs: list[tuple[str, str]]) -> dict[str, dict[str, Any]]:
        """Live popularity per distinct track, budget-checked BETWEEN lookups.

        One chunk can hold 50 distinct tracks and the run does two passes over
        them, so a per-chunk check alone lets a slow-but-alive route overrun the
        external runner timeout and die without a summary. Each call is also
        capped by the time the run has left.
        """
        measured: dict[str, dict[str, Any]] = {}
        for _, track_id in pairs:
            if track_id in measured:
                continue
            check_budget()
            measured[track_id] = spotify_lookup(track_id, timeout=lookup_timeout(deadline - time.monotonic()))
        return measured

    try:
        # Validate the landed fraud truth floor before inspecting any ticket;
        # each approval chunk reloads it again at the write boundary.
        load_required_fraud_ids()
        load_required_deny_list()
        # Shadow writes nothing, so the breaker must never blind the very data
        # a human needs in order to judge the reversals it reports.
        if mode == "apply":
            assert_no_reversal_streak(run_id)
        tickets = list_todo_tickets()
    except ReversalCircuitOpen as exc:
        print(render_reversal_halt(exc))
        return 1
    except ReversalCheckUnavailable as exc:
        print(render_reversal_unavailable(exc))
        return 1
    except (PolicyError, RunError, OSError, subprocess.TimeoutExpired) as exc:
        print(render_startup_failure(exc))
        return 1

    for listed_task in tickets:
        task_id = str(listed_task.get("id", ""))
        if not task_id or not is_automation_ready_task(listed_task):
            continue
        if mode == "apply" and approved_count >= limit:
            limit_reached = True
            break
        ticket_approved: list[str] = []
        failure: str | None = None
        remove_eligibility = False
        manual_handoff_present = False
        try:
            check_budget()
            task, comments = get_task_and_comments(task_id)
            if not is_automation_ready_task(task):
                continue
            manual_handoff_present = has_manual_handoff(comments)
            scanned += 1
            # The ticket names the PROFILE (and, rarely, exact ids that narrow
            # it). The exact request ids come from the backend, never from
            # the ticket text.
            profile_id, narrowing = parse_ticket_scope(task, comments)
            rows = list_profile_requests(profile_id)
            scoped_ids = resolve_profile_scope(profile_id, narrowing, rows, MAX_PROFILE_ROWS)
            if not scoped_ids:
                # Nothing is pending on this profile: the ticket is about
                # something else, so it stays with the humans, untouched.
                audit(run_id, "no_pending_rows", {"ticket_id": task_id, "profile_id": profile_id})
                remaining += 1
                continue

            # This is only a chunking plan. Every mutable boundary (ticket
            # scope, fraud state, request status and Spotify popularity) is
            # fetched again immediately before each write below.
            candidates = [
                request_id
                for request_id in sorted(scoped_ids)
                if rows[request_id].get("status") == UVN
                and isinstance(rows[request_id].get("spotifyTrackId"), str)
                and rows[request_id].get("spotifyTrackId")
            ]
            current_fraud_ids: set[str] = set()
            # Every write-edge lookup this ticket made, so the reviewer sees
            # exactly what was measured and nothing that was not.
            measured_by_track: dict[str, dict[str, Any]] = {}

            for index in range(0, len(candidates), 50):
                if mode == "apply" and approved_count >= limit:
                    limit_reached = True
                    break
                check_budget()
                planned_chunk = candidates[index:index + 50]
                current_fraud_ids, current_rows, current_scope = read_write_edge(task_id, profile_id, narrowing)
                measure_tracks(lookup_candidates(planned_chunk, current_scope, current_rows, current_fraud_ids))

                # Network lookups above can span long enough for a ticket edit,
                # fraud marker, hard-reject signal, or track binding to change.
                # Re-read all mutable policy inputs once more at the write edge,
                # then refresh popularity after that read: only this second
                # lookup feeds the approval decision.
                current_fraud_ids, current_rows, current_scope = read_write_edge(task_id, profile_id, narrowing)
                eligible = lookup_candidates(planned_chunk, current_scope, current_rows, current_fraud_ids)
                live_by_track = measure_tracks(eligible)
                measured_by_track.update(live_by_track)
                current_deny = load_required_deny_list()
                safe_chunk = [
                    request_id
                    for request_id, track_id in eligible
                    if qualifies_for_approval(
                        current_rows[request_id], live_by_track[track_id], current_fraud_ids, current_deny
                    )
                ]

                # Captain 2026-10-26 23:30-23:40Z / steward 019: the shared account gate decides before any
                # approval. Only an explicit allow passes; hold / unknown / any failure = skip (row stays held).
                safe_chunk, gate_held = account_gate_filter(safe_chunk, current_rows, gate_cache)
                if gate_held:
                    audit(run_id, "account_gate_held", {"ticket_id": task_id, "held": gate_held})
                if not safe_chunk:
                    continue
                if mode == "shadow":
                    shadow_record(
                        run_id,
                        task_id,
                        profile_id,
                        request_ids=safe_chunk,
                        popularity={
                            request_id: live_popularity(live_by_track.get(current_rows[request_id].get("spotifyTrackId")))
                            for request_id in safe_chunk
                        },
                    )
                    would_approve += len(safe_chunk)
                    continue
                room = limit - approved_count
                if len(safe_chunk) > room:
                    safe_chunk = safe_chunk[:room]
                    limit_reached = True
                try:
                    confirmed = approve_chunk(run_id, task_id, safe_chunk)
                except ApprovalAttemptError as exc:
                    ticket_approved.extend(sorted(exc.confirmed_ids))
                    approved_count += len(exc.confirmed_ids)
                    changed = changed or bool(exc.confirmed_ids)
                    raise
                ticket_approved.extend(sorted(confirmed))
                approved_count += len(confirmed)
                changed = changed or bool(confirmed)

            if mode == "shadow":
                remaining += 1
                continue

            # Re-read the mutable ticket immediately before deciding resolution.
            current_fraud_ids, current_rows, _ = read_write_edge(task_id, profile_id, narrowing)
            current_deny = load_required_deny_list()
            should_resolve = (
                every_scoped_request_approved(scoped_ids, current_rows)
                and no_pending_rows_remaining(profile_id, current_rows)
                and not scoped_ids.intersection(load_unresolved_ids())
            )
            if ticket_approved or should_resolve:
                request_word = "request" if len(ticket_approved) == 1 else "requests"
                lines = [
                    f"Automated credit check {run_id}: approved {len(ticket_approved)} {request_word} "
                    "because live Spotify popularity was below 30, then confirmed the new status. "
                    "No credits were rejected. "
                    + (
                        "Nothing is left in verification on this profile, so the ticket is being resolved."
                        if should_resolve
                        else "The ticket remains open for review."
                    )
                ]
                if not should_resolve:
                    pending_lines = render_pending_lines(
                        profile_id, current_rows, current_fraud_ids, measured_by_track, current_deny
                    )
                    if pending_lines:
                        lines.extend(pending_lines)
                        lines.append(
                            "The approval cap for this run was reached; rows below popularity 30 are reviewed next run."
                            if limit_reached
                            else f"This check re-runs {RUN_CADENCE_TEXT}; rows at or above popularity 30 need a human."
                        )
                actually_resolved = update_ticket(
                    run_id,
                    task_id,
                    "\n".join(lines),
                    should_resolve,
                    profile_id,
                    narrowing,
                    scoped_ids,
                )
                changed = True
            else:
                actually_resolved = False
            if actually_resolved:
                resolved += 1
            else:
                remaining += 1
        except TicketNoLongerEligible:
            continue
        except StopRun as exc:
            # A dead popularity route or an exhausted budget: stop now, before
            # the cron runner kills the process with no summary at all.
            audit(run_id, "run_stopped_early", {"ticket_id": task_id, "reason": str(exc)[:300]})
            if ticket_approved:
                # Approvals already committed for this ticket must reach the
                # reviewer even though the run cannot finish the ticket.
                request_word = "request" if len(ticket_approved) == 1 else "requests"
                try:
                    update_ticket(
                        run_id,
                        task_id,
                        f"Automated credit check {run_id}: approved {len(ticket_approved)} {request_word} "
                        "because live Spotify popularity was below 30, then confirmed the new status. "
                        "No credits were rejected. The check then stopped early "
                        f"({str(exc)[:200]}), so the rest of this profile is reviewed next run. "
                        "The ticket remains open for review.",
                        False,
                    )
                except (RunError, OSError, subprocess.TimeoutExpired):
                    hard_failures += 1
            if mode == "shadow":
                print(render_shadow_summary(scanned, would_approve, failures + 1, [*failed_tickets, task_id]))
            else:
                print(render_summary(scanned, approved_count, resolved, remaining + 1, failures + 1, limit_reached))
            print(f"{exc.headline} No credits were rejected. Technical details: {str(exc)[:300]}")
            return 1
        except PolicyError as exc:
            failures += 1
            remaining += 1
            failure = str(exc)
            remove_eligibility = True
        except (RunError, OSError, subprocess.TimeoutExpired) as exc:
            failures += 1
            hard_failures += 1
            remaining += 1
            failure = str(exc)
        if failure and mode == "shadow":
            # Shadow writes nothing, not even the handoff comment; the
            # failure is named in the Slack summary instead.
            failed_tickets.append(task_id)
            print(f"shadow: ticket {task_id} could not be assessed: {failure[:300]}", file=sys.stderr)
            audit(run_id, "shadow_failure", {"ticket_id": task_id, "reason": failure[:300]})
        elif failure:
            comment_written = remove_eligibility and manual_handoff_present
            if not comment_written:
                marker = f" {MANUAL_HANDOFF_MARKER}" if remove_eligibility else ""
                try:
                    update_ticket(
                        run_id,
                        task_id,
                        f"Automated credit check {run_id}: this ticket could not be processed safely, "
                        "so it remains open for manual review. No credits were rejected. "
                        f"Reason: {failure[:300]}{marker}",
                        False,
                    )
                    changed = True
                    comment_written = True
                except (RunError, OSError, subprocess.TimeoutExpired):
                    hard_failures += 1
            if remove_eligibility and comment_written:
                try:
                    remove_automation_tag(run_id, task_id)
                    changed = True
                except (RunError, OSError, subprocess.TimeoutExpired):
                    hard_failures += 1

    if mode == "shadow":
        # Shadow announces when there is something for the reviewers to
        # compare against the humans' decisions, or a ticket it could not
        # assess: NO_REPLY means nothing happened, never "something failed".
        if would_approve == 0 and failures == 0:
            print("NO_REPLY")
            return 0
        print(render_shadow_summary(scanned, would_approve, failures, failed_tickets))
        return 1 if hard_failures else 0
    if not changed and failures == 0 and not limit_reached:
        print("NO_REPLY")
        return 0
    print(render_summary(scanned, approved_count, resolved, remaining, failures, limit_reached))
    # A policy mismatch is a successful fail-closed handoff: the ticket stays
    # open, gets a plain-English explanation, and the same summary reaches
    # Slack. Runtime and dependency failures still fail the cron for paging.
    return 1 if hard_failures else 0


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--mode",
        choices=("shadow", "apply"),
        default="shadow",
        help="shadow (default) records would-approve rows and writes nothing; apply approves",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=25,
        help="maximum number of requests approved per run in apply mode",
    )
    args = parser.parse_args(argv)
    if args.limit <= 0:
        parser.error("--limit must be a positive integer")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    run_id = f"uvn-under30-{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}-{os.getpid()}"
    os.environ["OPS_RUN_ID"] = run_id
    os.environ["MUSO_ADMIN_IDENTITY"] = ADMIN_IDENTITY
    # Host guard first: the write surfaces below exist only on node-8, and a
    # stray run elsewhere must refuse before it touches anything.
    hostname = socket.gethostname()
    if os.environ.get("UVN_SKIP_HOST_GUARD") != "1" and hostname != EXPECTED_HOST:
        print(render_startup_failure(
            f"refusing to run on host {hostname}; expected {EXPECTED_HOST} "
            "(set UVN_SKIP_HOST_GUARD=1 only for tests)"
        ))
        return 1
    if KILL_SWITCH_PATH.exists():
        print(f"kill switch present at {KILL_SWITCH_PATH}; no tickets reviewed", file=sys.stderr)
        print("NO_REPLY")
        return 0
    # Shadow never writes credit status, so it does not take the shared
    # credit-write lock (the same rule dispatch-cv-batch.sh applies to its
    # dry runs): a no-op must not block a real writer for a whole run.
    lock = credit_write_lock() if args.mode == "apply" else nullcontext()
    try:
        with lock:
            return run_locked(run_id, mode=args.mode, limit=args.limit)
    except (PolicyError, RunError, OSError, subprocess.TimeoutExpired) as exc:
        print(render_startup_failure(exc))
        return 1


if __name__ == "__main__":
    sys.exit(main())
