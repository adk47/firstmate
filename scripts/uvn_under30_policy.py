#!/usr/bin/env python3
"""Pure policy helpers for the ticket-scoped UVN popularity cron."""

from __future__ import annotations

import gzip
import json
import re
import uuid
from pathlib import Path
from typing import Any, Iterable


UVN = "user_verification_needed"
APPROVED = "approved"
ACTION_START = "---ACTION-REQUEST---"
ACTION_END = "---END-ACTION-REQUEST---"
UPDATE_START = "---ACTION-REQUEST-UPDATE---"
UPDATE_END = "---END-ACTION-REQUEST-UPDATE---"


class PolicyError(ValueError):
    """Input cannot be proven safe enough for an automated decision."""


def _extract_blocks(text: str, start: str, end: str) -> list[dict[str, Any]]:
    if not text:
        return []
    starts = text.count(start)
    ends = text.count(end)
    matches = re.findall(
        re.escape(start) + r"\s*(\{[\s\S]*?\})\s*" + re.escape(end),
        text,
    )
    if starts != ends or len(matches) != starts:
        raise PolicyError(f"malformed {start} block")
    blocks = []
    for raw in matches:
        try:
            value = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise PolicyError(f"invalid JSON in {start} block") from exc
        if not isinstance(value, dict):
            raise PolicyError(f"non-object {start} block")
        blocks.append(value)
    return blocks


def _normalize_uuid(value: Any, label: str) -> str:
    try:
        return str(uuid.UUID(str(value)))
    except (ValueError, TypeError, AttributeError) as exc:
        raise PolicyError(f"structured {label} is not a UUID") from exc


def _request_ids_from_details(details: Any, *, required: bool) -> set[str] | None:
    if not isinstance(details, dict):
        raise PolicyError("structured details are malformed")
    if "pending_credits" not in details and not required:
        return None
    pending = details.get("pending_credits")
    if not isinstance(pending, list) or not pending:
        raise PolicyError("structured pending credits are missing")
    request_ids: set[str] = set()
    for pending_credit in pending:
        cr_id = pending_credit.get("cr_id") if isinstance(pending_credit, dict) else None
        request_ids.add(_normalize_uuid(cr_id, "credit request ID"))
    return request_ids


def _require_automation_recommendation(details: Any, *, required: bool) -> None:
    if not isinstance(details, dict):
        raise PolicyError("structured details are malformed")
    if "recommendation" not in details:
        if required:
            raise PolicyError("structured automation recommendation is missing")
        return
    if details["recommendation"] != "recommend-approve":
        raise PolicyError("ticket recommendation requires human review")


def parse_ticket_scope(task: dict[str, Any], comments: Iterable[dict[str, Any]]) -> tuple[str, set[str]]:
    """Return the one profile and exact UUID request IDs from structured blocks.

    The description owns the initial complete scope. Follow-up comments are
    deltas: evidence-only updates may omit pending_credits, while any update
    that adds request ids must repeat the same profile and carry valid UUIDs.
    """
    tags = {
        str(tag.get("name", "")).strip().lower()
        for tag in task.get("tags", [])
        if isinstance(tag, dict)
    }
    required_tags = {
        "hydra-action-request",
        "action:credit-verify",
        "automation:uvn-under30",
    }
    if not required_tags.issubset(tags):
        raise PolicyError("required ticket tags are missing")
    if str(task.get("status", {}).get("status", "")).strip().lower() != "to do":
        raise PolicyError("ticket is not TO DO")

    blocks = _extract_blocks(
        str(task.get("description") or task.get("text_content") or ""),
        ACTION_START,
        ACTION_END,
    )
    if not blocks:
        raise PolicyError("no structured action request")

    profile_ids: set[str] = set()
    request_ids: set[str] = set()
    for block in blocks:
        if block.get("action_type") != "credit-verify":
            raise PolicyError("structured action type is not credit-verify")
        profile_ids.add(_normalize_uuid(block.get("customer_profile_id"), "profile ID"))
        details = block.get("details")
        _require_automation_recommendation(details, required=True)
        request_ids.update(_request_ids_from_details(details, required=True) or set())
    if len(profile_ids) != 1:
        raise PolicyError("structured blocks disagree on profile ID")
    profile_id = next(iter(profile_ids))

    for comment in comments:
        text = str(comment.get("comment_text") or comment.get("text_content") or "")
        for block in _extract_blocks(text, UPDATE_START, UPDATE_END):
            if block.get("action_type") != "credit-verify":
                raise PolicyError("structured action type is not credit-verify")
            details = block.get("details")
            added_ids = _request_ids_from_details(details, required=False)
            _require_automation_recommendation(details, required=added_ids is not None)
            raw_update_profile = block.get("customer_profile_id")
            update_profile = None
            if raw_update_profile not in (None, ""):
                update_profile = _normalize_uuid(raw_update_profile, "profile ID")
                if update_profile != profile_id:
                    raise PolicyError("structured blocks disagree on profile ID")
            if added_ids is None:
                continue
            if update_profile is None:
                raise PolicyError("structured profile ID is missing")
            request_ids.update(added_ids)

    return profile_id, request_ids


def has_hard_reject_signal(credit_request: dict[str, Any]) -> bool:
    verification = credit_request.get("verificationData")
    rules = verification.get("rule_risk_percent") if isinstance(verification, dict) else None
    if not isinstance(rules, dict):
        return True
    for name, value in rules.items():
        if not str(name).startswith("reject_"):
            continue
        if isinstance(value, bool):
            if value:
                return True
            continue
        try:
            if float(value or 0) > 0:
                return True
        except (TypeError, ValueError):
            return True
    return False


def qualifies_for_approval(
    credit_request: dict[str, Any],
    live_spotify: dict[str, Any],
    fraud_ids: set[str],
) -> bool:
    request_id = str(credit_request.get("id", ""))
    if credit_request.get("status") != UVN or request_id in fraud_ids:
        return False
    if has_hard_reject_signal(credit_request):
        return False
    if not credit_request.get("spotifyTrackId") or live_spotify.get("found") is not True:
        return False
    track = live_spotify.get("track")
    popularity = track.get("popularity") if isinstance(track, dict) else None
    return (
        isinstance(popularity, (int, float))
        and not isinstance(popularity, bool)
        and 0 <= popularity < 30
    )


def every_scoped_request_approved(request_ids: set[str], rows_by_id: dict[str, dict[str, Any]]) -> bool:
    return bool(request_ids) and all(
        request_id in rows_by_id and rows_by_id[request_id].get("status") == APPROVED
        for request_id in request_ids
    )


def _add_fraud_record_ids(record: Any, source: str, fraud_ids: set[str]) -> None:
    if not isinstance(record, dict):
        raise PolicyError(f"non-object fraud record at {source}")
    request_ids = record.get("request_ids")
    if not isinstance(request_ids, list) or not request_ids:
        raise PolicyError(f"malformed fraud request_ids at {source}")
    for value in request_ids:
        try:
            fraud_ids.add(str(uuid.UUID(str(value))))
        except (ValueError, TypeError, AttributeError) as exc:
            raise PolicyError(f"invalid fraud request ID at {source}") from exc


def load_fraud_ids(root: Path, attempt_path: Path | None = None) -> set[str]:
    """Load completed and pre-write fraud markers; malformed truth is fatal."""
    if not root.is_dir():
        raise PolicyError(f"fraud truth-floor root is unavailable: {root}")
    paths = sorted(root.glob("*/*.results.jsonl")) + sorted(root.glob("*/*.results.jsonl.gz"))
    if not paths:
        raise PolicyError("no fraud truth-floor result files found")
    fraud_ids: set[str] = set()
    for path in paths:
        opener = gzip.open if path.suffix == ".gz" else open
        with opener(path, "rt", encoding="utf-8") as handle:
            for line_number, line in enumerate(handle, 1):
                if not line.strip():
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError as exc:
                    raise PolicyError(f"malformed truth-floor JSON at {path}:{line_number}") from exc
                if not isinstance(record, dict):
                    raise PolicyError(f"non-object truth-floor record at {path}:{line_number}")
                if (
                    record.get("flag_reason") == "fraud_multifactor"
                    and record.get("intended_status") == UVN
                    and record.get("outcome") in {"ok", "http_error"}
                ):
                    _add_fraud_record_ids(record, f"{path}:{line_number}", fraud_ids)

    if attempt_path is not None and attempt_path.exists():
        with attempt_path.open("rt", encoding="utf-8") as handle:
            for line_number, line in enumerate(handle, 1):
                if not line.strip():
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError as exc:
                    raise PolicyError(
                        f"malformed fraud-attempt JSON at {attempt_path}:{line_number}"
                    ) from exc
                if (
                    isinstance(record, dict)
                    and record.get("flag_reason") == "fraud_multifactor"
                    and record.get("intended_status") == UVN
                    and record.get("outcome") == "attempt_started"
                ):
                    _add_fraud_record_ids(record, f"{attempt_path}:{line_number}", fraud_ids)
                else:
                    raise PolicyError(f"malformed fraud-attempt record at {attempt_path}:{line_number}")
    return fraud_ids
