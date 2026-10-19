#!/usr/bin/env python3
"""Pure policy helpers for the ticket-scoped UVN popularity cron."""

from __future__ import annotations

import gzip
import json
import re
import sqlite3
import uuid
from pathlib import Path
from typing import Any, Iterable

from credit_review.policy import doc_required_ids, server_band_a_refusal
from credit_review.roles import editorial_terms, is_editorial


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


def _request_ids_from_details(details: Any) -> set[str] | None:
    """Exact request ids a structured block names, or None when it names none.

    Caroline's tickets carry the profile UUID but almost never a `cr_id`
    (measured 2026-09-04: 39 of 40), so an entry without one is evidence-only
    and the ticket is profile-scoped. A `cr_id` that IS present must be a UUID;
    anything else is a malformed block and fails closed.
    """
    if not isinstance(details, dict):
        raise PolicyError("structured details are malformed")
    pending = details.get("pending_credits")
    if pending is None:
        return None
    if not isinstance(pending, list):
        raise PolicyError("structured pending credits are malformed")
    request_ids: set[str] = set()
    for pending_credit in pending:
        if not isinstance(pending_credit, dict):
            raise PolicyError("structured pending credit is malformed")
        cr_id = pending_credit.get("cr_id")
        if cr_id in (None, ""):
            continue
        request_ids.add(_normalize_uuid(cr_id, "credit request ID"))
    return request_ids or None


def parse_ticket_scope(
    task: dict[str, Any], comments: Iterable[dict[str, Any]]
) -> tuple[str, set[str] | None]:
    """Return the one profile and, when the ticket names any, exact request IDs.

    The scope is the PROFILE: the cron resolves that profile's live pending
    rows from the backend itself (resolve_profile_scope). Exact ids in the
    description or in follow-up comments only ever NARROW that scope; they
    never widen it. Evidence-only updates may omit pending_credits, while any
    update that adds request ids must repeat the same profile and carry valid
    UUIDs. Returns None as the second value when no block names an id.
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
    narrowing: set[str] | None = None
    for block in blocks:
        if block.get("action_type") != "credit-verify":
            raise PolicyError("structured action type is not credit-verify")
        profile_ids.add(_normalize_uuid(block.get("customer_profile_id"), "profile ID"))
        if not isinstance(block.get("details"), dict):
            raise PolicyError("structured details are malformed")
        named = _request_ids_from_details(block.get("details"))
        if named:
            narrowing = (narrowing or set()) | named
    if len(profile_ids) != 1:
        raise PolicyError("structured blocks disagree on profile ID")
    profile_id = next(iter(profile_ids))

    for comment in comments:
        text = str(comment.get("comment_text") or comment.get("text_content") or "")
        for block in _extract_blocks(text, UPDATE_START, UPDATE_END):
            if block.get("action_type") != "credit-verify":
                raise PolicyError("structured action type is not credit-verify")
            details = block.get("details")
            added_ids = _request_ids_from_details(details)
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
            narrowing = (narrowing or set()) | added_ids

    return profile_id, narrowing


def resolve_profile_scope(
    profile_id: str,
    narrowing: set[str] | None,
    rows_by_id: dict[str, dict[str, Any]],
    max_rows: int = 100,
) -> set[str]:
    """Turn a ticket's profile (plus optional exact ids) into the request ids in scope.

    Without narrowing the scope is every live user_verification_needed row of
    that profile, read from the backend, never from the ticket, and a profile
    carrying more pending rows than max_rows is refused: a queue that size is
    a bulk submission a human should look at, not a customer asking about
    their pending credits. With narrowing the scope is exactly those ids, each
    of which must exist and belong to the profile; the ticket has already
    bounded the blast radius, so the queue size does not apply.
    """
    if narrowing is None:
        pending = pending_request_ids(profile_id, rows_by_id)
        if len(pending) > max_rows:
            raise PolicyError(f"profile has more than {max_rows} pending requests")
        return pending
    for request_id in narrowing:
        row = rows_by_id.get(request_id)
        if not isinstance(row, dict) or row.get("profileId") != profile_id:
            raise PolicyError("a scoped credit request is missing or belongs to another profile")
    return set(narrowing)


def pending_request_ids(profile_id: str, rows_by_id: dict[str, dict[str, Any]]) -> set[str]:
    """The live user_verification_needed rows of one profile.

    This one predicate decides what the cron may approve, when a ticket may
    resolve, and what the human reviewer is shown as still pending.
    """
    return {
        request_id
        for request_id, row in rows_by_id.items()
        if isinstance(row, dict)
        and row.get("profileId") == profile_id
        and row.get("status") == UVN
    }


def no_pending_rows_remaining(profile_id: str, rows_by_id: dict[str, dict[str, Any]]) -> bool:
    return not pending_request_ids(profile_id, rows_by_id)


def live_popularity(live_spotify: Any) -> int | float | None:
    """The measured popularity in a spotify_lookup result, or None when there is none.

    The approval gate and every human-facing "popularity N" line read the
    number through this one parser, so they cannot disagree about it.
    """
    if not isinstance(live_spotify, dict) or live_spotify.get("found") is not True:
        return None
    track = live_spotify.get("track")
    popularity = track.get("popularity") if isinstance(track, dict) else None
    if isinstance(popularity, bool) or not isinstance(popularity, (int, float)):
        return None
    return popularity


def approved_ids_from_records(records: Iterable[Any], cutoff_iso: str) -> set[str]:
    """Request ids this automation approved AND read back since cutoff_iso.

    Only `approve_verified` counts: `approve_planned` is written before the
    call and an unresolved attempt may never have landed, so counting it would
    invent reversals out of writes that never happened.
    """
    ids: set[str] = set()
    for record in records:
        if not isinstance(record, dict) or record.get("action") != "approve_verified":
            continue
        if str(record.get("ts") or "") < cutoff_iso:
            continue
        for request_id in record.get("request_ids") or []:
            if isinstance(request_id, str) and request_id:
                ids.add(request_id)
    return ids


def reversal_verdict(
    approved_ids: set[str], still_approved: set[str], max_reversals: int
) -> tuple[list[str], bool]:
    """(ids no longer approved, whether that count trips the breaker).

    A person undoing one of our approvals is the only direct evidence that the
    sub-30 rule approved something it should not have. Humans reversed 0 of 127
    of their own approvals in the 45 days before this automation wrote
    anything, so the tolerance is deliberately near zero.
    """
    reversed_ids = sorted(set(approved_ids) - set(still_approved))
    return reversed_ids, len(reversed_ids) > max_reversals


def has_hard_reject_signal(credit_request: dict[str, Any]) -> bool:
    verification = credit_request.get("verificationData")
    rules = verification.get("rule_risk_percent") if isinstance(verification, dict) else None
    if not isinstance(rules, dict):
        return True
    # reject_* = validator auto-reject; review_* = IDP #1686 hold-for-review
    # (e.g. review_role_credited_to_other_at_trusted_source: a trusted source
    # credits this one-person role to someone else). A held row must never be
    # approved by automation, whatever its popularity.
    for name, value in rules.items():
        if not str(name).startswith(("reject_", "review_")):
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


class DenyList:
    """Rows no automation may approve on popularity alone, shared with the
    credit-trust decider:
      * users / profiles on the deny lists of
        policies/credit-trust-decide.json;
      * editorial roles (its editorial_role_terms, matched exactly as the
        decider matches them);
      * request ids the decider recorded ``doc_required`` (a support request
        that needs documents) in its decisions ledger."""

    def __init__(self, user_ids: Iterable[int], profile_ids: Iterable[str],
                 editorial_terms: tuple[str, ...] = (), doc_required_ids: Iterable[str] = ()):
        self.user_ids = frozenset(user_ids)
        self.profile_ids = frozenset(str(p).lower() for p in profile_ids)
        self.editorial_terms = tuple(editorial_terms)
        self.doc_required_ids = frozenset(str(i).lower() for i in doc_required_ids)

    def why(self, credit_request: dict[str, Any]) -> str | None:
        user_id = credit_request.get("userId")
        if isinstance(user_id, int) and not isinstance(user_id, bool) and user_id in self.user_ids:
            return "deny-listed user"
        if str(credit_request.get("profileId") or "").lower() in self.profile_ids:
            return "deny-listed profile"
        roles = [str(r) for r in credit_request.get("credits") or [] if is_editorial(str(r), self.editorial_terms)]
        if roles:
            return f"editorial role ({', '.join(roles)}), documentation required"
        if str(credit_request.get("id") or "").lower() in self.doc_required_ids:
            return "the credit-trust decider requires documentation"
        return None

    def blocks(self, credit_request: dict[str, Any]) -> bool:
        return self.why(credit_request) is not None


def load_doc_required_ids(ledger_path: Path) -> set[str]:
    """Request ids the decider marked doc_required, read-only. An unreadable
    ledger or one without the marker is fatal."""
    try:
        db = sqlite3.connect(Path(ledger_path).resolve().as_uri() + "?mode=ro", uri=True, timeout=30)
        try:
            return set(doc_required_ids(db))
        finally:
            db.close()
    except (sqlite3.Error, OSError, ValueError) as exc:
        raise PolicyError(f"doc_required marker is unavailable: {ledger_path}: {exc}") from exc


def load_deny_list(path: Path, ledger_path: Path) -> DenyList:
    """Load the shared deny lists, editorial terms and doc_required marker; an
    unreadable or malformed source is fatal."""
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise PolicyError(f"deny list is unavailable: {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise PolicyError(f"deny list is not an object: {path}")
    lists = {}
    for key in ("deny_user_ids", "deny_profile_ids"):
        value = data.get(key)
        if not isinstance(value, list):
            raise PolicyError(f"deny list {path} has no {key} list")
        lists[key] = value
    users = lists["deny_user_ids"]
    if not all(isinstance(u, int) and not isinstance(u, bool) for u in users):
        raise PolicyError(f"deny list {path} has a non-integer user id")
    profiles = []
    for value in lists["deny_profile_ids"]:
        profiles.append(_normalize_uuid(value, "deny profile id"))
    try:
        terms = editorial_terms(data.get("editorial_role_terms"))
    except ValueError as exc:
        raise PolicyError(f"deny list {path}: {exc}") from exc
    return DenyList(users, profiles, terms, load_doc_required_ids(ledger_path))


def qualifies_for_approval(
    credit_request: dict[str, Any],
    live_spotify: dict[str, Any],
    fraud_ids: set[str],
    deny: DenyList,
) -> bool:
    request_id = str(credit_request.get("id", ""))
    if credit_request.get("status") != UVN or request_id in fraud_ids:
        return False
    if deny.blocks(credit_request):
        return False
    if has_hard_reject_signal(credit_request):
        return False
    # core-backend's T12 agent guard refuses this automation anything outside band A
    # (stored popularity 1..29, no claimant-proof requirement, ...); one refused row
    # rejects the whole batch, so such rows are never sent (left for the reviewer).
    if server_band_a_refusal(credit_request):
        return False
    if not credit_request.get("spotifyTrackId"):
        return False
    popularity = live_popularity(live_spotify)
    return popularity is not None and 0 <= popularity < 30


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
