#!/usr/bin/env python3
"""Approve ticket-scoped UVNs with authoritative live Spotify popularity <30."""

from __future__ import annotations

import fcntl
import json
import os
import subprocess
import sys
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlencode

from uvn_under30_policy import (
    APPROVED,
    PolicyError,
    UVN,
    every_scoped_request_approved,
    load_fraud_ids,
    parse_ticket_scope,
    qualifies_for_approval,
)


LIST_ID = "901000600160"
SERVICE_REQUESTER = "uvn-popularity-cron@hydra-ops"
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


class RunError(RuntimeError):
    pass


class TicketNoLongerEligible(RuntimeError):
    pass


class ApprovalAttemptError(RunError):
    def __init__(self, message: str, confirmed_ids: set[str] | None = None):
        super().__init__(message)
        self.confirmed_ids = confirmed_ids or set()


def run_json(argv: list[str], env: dict[str, str] | None = None) -> dict[str, Any]:
    result = subprocess.run(argv, capture_output=True, text=True, env=env, timeout=120, check=False)
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
    if body is not None:
        argv.extend(["--data", json.dumps(body, separators=(",", ":"), sort_keys=True)])
    argv.append("--json")
    envelope = run_json(argv)
    if "data" not in envelope:
        raise RunError("ClickUp response is missing data")
    return envelope["data"]


def admin_raw(method: str, path: str, body: dict[str, Any] | None = None) -> dict[str, Any]:
    argv = ["bash", ADMIN_SCRIPT, "--requester", SERVICE_REQUESTER, "call", method, path]
    if body is not None:
        argv.append(json.dumps(body, separators=(",", ":"), sort_keys=True))
    env = dict(os.environ)
    env["UVN_POPULARITY_CRON"] = "1"
    return run_json(argv, env=env)


def admin(method: str, path: str, body: dict[str, Any] | None = None) -> dict[str, Any]:
    response = admin_raw(method, path, body)
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
    task = clickup("GET", f"/task/{task_id}")
    if not isinstance(task, dict):
        raise RunError(f"ClickUp task {task_id} returned malformed detail")
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


def load_required_fraud_ids() -> set[str]:
    try:
        return load_fraud_ids(FRAUD_ROOT, FRAUD_ATTEMPT_PATH)
    except PolicyError as exc:
        raise RunError(f"fraud safety data is unavailable: {exc}") from exc


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


def spotify_lookup(track_id: str) -> dict[str, Any]:
    path = "/admin/spotify/web-lookup?" + urlencode({"type": "track", "id": track_id})
    body = admin("GET", path)
    track = body.get("data") if isinstance(body, dict) else None
    if not isinstance(track, dict):
        raise RunError("Spotify admin lookup response is malformed")
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
    expected_ids: set[str],
) -> None:
    task, comments = get_task_and_comments(task_id)
    if not is_automation_ready_task(task):
        raise TicketNoLongerEligible
    profile_id, scoped_ids = parse_ticket_scope(task, comments)
    if profile_id != expected_profile_id or scoped_ids != expected_ids:
        raise PolicyError("ticket scope changed during the run")


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
        assert_ticket_scope(task_id, expected_profile_id, expected_ids)
        rows = list_profile_requests(expected_profile_id)
        assert_rows_match_scope(expected_profile_id, expected_ids, rows)
        if not every_scoped_request_approved(expected_ids, rows):
            audit(run_id, "clickup_resolve_skipped", {"ticket_id": task_id, "reason": "non-approved scoped ID"})
            audit(run_id, "clickup_write_complete", {"ticket_id": task_id, "resolve": False})
            return False
        if expected_ids.intersection(load_unresolved_ids()):
            audit(run_id, "clickup_resolve_skipped", {"ticket_id": task_id, "reason": "unresolved approval attempt"})
            audit(run_id, "clickup_write_complete", {"ticket_id": task_id, "resolve": False})
            return False
        clickup("PUT", f"/task/{task_id}", {"status": "resolved"})
    audit(run_id, "clickup_write_complete", {"ticket_id": task_id, "resolve": resolve})
    return resolve


def remove_automation_tag(run_id: str, task_id: str) -> None:
    audit(run_id, "automation_tag_remove_planned", {"ticket_id": task_id, "tag": AUTOMATION_TAG})
    clickup("DELETE", f"/task/{task_id}/tag/{quote(AUTOMATION_TAG, safe='')}")
    audit(run_id, "automation_tag_remove_complete", {"ticket_id": task_id, "tag": AUTOMATION_TAG})


def render_summary(
    scanned: int,
    approved_count: int,
    resolved: int,
    remaining: int,
    failures: int,
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
    return "\n".join(lines)


def render_startup_failure(reason: object) -> str:
    detail = str(reason).strip()[:300] or "unknown error"
    return "\n".join([
        "Credit verification automation needs attention.",
        "The automatic check could not start, so no tickets were reviewed or changed.",
        "No credits were approved or rejected.",
        f"Technical details: {detail}",
    ])


def run_locked(run_id: str) -> int:
    scanned = approved_count = resolved = remaining = failures = hard_failures = 0
    changed = False
    try:
        # Validate the landed fraud truth floor before inspecting any ticket;
        # each approval chunk reloads it again at the write boundary.
        load_required_fraud_ids()
        tickets = list_todo_tickets()
    except (PolicyError, RunError, OSError, subprocess.TimeoutExpired) as exc:
        print(render_startup_failure(exc))
        return 1

    for listed_task in tickets:
        task_id = str(listed_task.get("id", ""))
        if not task_id or not is_automation_ready_task(listed_task):
            continue
        ticket_approved: list[str] = []
        failure: str | None = None
        remove_eligibility = False
        manual_handoff_present = False
        try:
            task, comments = get_task_and_comments(task_id)
            if not is_automation_ready_task(task):
                continue
            manual_handoff_present = has_manual_handoff(comments)
            scanned += 1
            profile_id, scoped_ids = parse_ticket_scope(task, comments)
            rows = list_profile_requests(profile_id)
            assert_rows_match_scope(profile_id, scoped_ids, rows)

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

            for index in range(0, len(candidates), 50):
                planned_chunk = candidates[index:index + 50]
                assert_ticket_scope(task_id, profile_id, scoped_ids)
                current_fraud_ids = load_required_fraud_ids()
                current_rows = list_profile_requests(profile_id)
                assert_rows_match_scope(profile_id, scoped_ids, current_rows)
                live_by_track: dict[str, dict[str, Any]] = {}
                for request_id in planned_chunk:
                    row = current_rows[request_id]
                    track_id = row.get("spotifyTrackId")
                    if row.get("status") != UVN or request_id in current_fraud_ids:
                        continue
                    if not isinstance(track_id, str) or not track_id:
                        continue
                    if track_id not in live_by_track:
                        live_by_track[track_id] = spotify_lookup(track_id)

                # Network lookups above can span long enough for a ticket edit,
                # fraud marker, hard-reject signal, or track binding to change.
                # Re-read all mutable policy inputs once more at the write edge.
                assert_ticket_scope(task_id, profile_id, scoped_ids)
                current_fraud_ids = load_required_fraud_ids()
                current_rows = list_profile_requests(profile_id)
                assert_rows_match_scope(profile_id, scoped_ids, current_rows)
                # Refresh the authoritative popularity values after the final
                # ticket/fraud/request read. Only this second lookup is used for
                # the approval decision, keeping popularity at the write edge.
                live_by_track = {}
                for request_id in planned_chunk:
                    row = current_rows[request_id]
                    track_id = row.get("spotifyTrackId")
                    if row.get("status") != UVN or request_id in current_fraud_ids:
                        continue
                    if not isinstance(track_id, str) or not track_id:
                        continue
                    if track_id not in live_by_track:
                        live_by_track[track_id] = spotify_lookup(track_id)
                safe_chunk: list[str] = []
                for request_id in planned_chunk:
                    row = current_rows[request_id]
                    track_id = row.get("spotifyTrackId")
                    if not isinstance(track_id, str) or track_id not in live_by_track:
                        continue
                    if qualifies_for_approval(row, live_by_track[track_id], current_fraud_ids):
                        safe_chunk.append(request_id)

                if not safe_chunk:
                    continue
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

            # Re-read the mutable ticket immediately before deciding resolution.
            assert_ticket_scope(task_id, profile_id, scoped_ids)
            current_rows = list_profile_requests(profile_id)
            assert_rows_match_scope(profile_id, scoped_ids, current_rows)
            should_resolve = (
                every_scoped_request_approved(scoped_ids, current_rows)
                and not scoped_ids.intersection(load_unresolved_ids())
            )
            if ticket_approved or should_resolve:
                request_word = "request" if len(ticket_approved) == 1 else "requests"
                comment = (
                    f"Automated credit check {run_id}: approved {len(ticket_approved)} {request_word} "
                    "because live Spotify popularity was below 30, then confirmed the new status. "
                    f"No credits were rejected. {'All requests on this ticket are approved, so it is being resolved.' if should_resolve else 'The ticket remains open for review.'}"
                )
                actually_resolved = update_ticket(
                    run_id,
                    task_id,
                    comment,
                    should_resolve,
                    profile_id,
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
        if failure:
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

    if not changed and failures == 0:
        print("NO_REPLY")
        return 0
    print(render_summary(scanned, approved_count, resolved, remaining, failures))
    # A policy mismatch is a successful fail-closed handoff: the ticket stays
    # open, gets a plain-English explanation, and the same summary reaches
    # Slack. Runtime and dependency failures still fail the cron for paging.
    return 1 if hard_failures else 0


def main() -> int:
    run_id = f"uvn-under30-{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}-{os.getpid()}"
    os.environ["OPS_RUN_ID"] = run_id
    try:
        with credit_write_lock():
            return run_locked(run_id)
    except (PolicyError, RunError, OSError, subprocess.TimeoutExpired) as exc:
        print(render_startup_failure(exc))
        return 1


if __name__ == "__main__":
    sys.exit(main())
