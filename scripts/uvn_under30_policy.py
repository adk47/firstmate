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


def parse_ticket_scope(task: dict[str, Any], comments: Iterable[dict[str, Any]]) -> tuple[str, set[str]]:
    """Return the one profile and exact UUID request IDs from structured blocks."""
    tags = {
        str(tag.get("name", "")).strip().lower()
        for tag in task.get("tags", [])
        if isinstance(tag, dict)
    }
    if not {"hydra-action-request", "action:credit-verify"}.issubset(tags):
        raise PolicyError("required ticket tags are missing")
    if str(task.get("status", {}).get("status", "")).strip().lower() != "to do":
        raise PolicyError("ticket is not TO DO")

    blocks = _extract_blocks(str(task.get("description") or task.get("text_content") or ""), ACTION_START, ACTION_END)
    for comment in comments:
        text = str(comment.get("comment_text") or comment.get("text_content") or "")
        blocks.extend(_extract_blocks(text, UPDATE_START, UPDATE_END))
    if not blocks:
        raise PolicyError("no structured action request")

    profile_ids: set[str] = set()
    request_ids: set[str] = set()
    for block in blocks:
        if block.get("action_type") != "credit-verify":
            raise PolicyError("structured action type is not credit-verify")
        profile_id = block.get("customer_profile_id")
        if not isinstance(profile_id, str) or not profile_id.strip():
            raise PolicyError("structured profile ID is missing")
        profile_ids.add(profile_id.strip())
        details = block.get("details")
        pending = details.get("pending_credits") if isinstance(details, dict) else None
        if not isinstance(pending, list) or not pending:
            raise PolicyError("structured pending credits are missing")
        for pending_credit in pending:
            cr_id = pending_credit.get("cr_id") if isinstance(pending_credit, dict) else None
            try:
                normalized = str(uuid.UUID(str(cr_id)))
            except (ValueError, TypeError, AttributeError) as exc:
                raise PolicyError("structured credit request ID is not a UUID") from exc
            request_ids.add(normalized)
    if len(profile_ids) != 1:
        raise PolicyError("structured blocks disagree on profile ID")
    return next(iter(profile_ids)), request_ids


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
