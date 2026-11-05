"""Event log, fold, projections, and schema (SA-01).

The Engine is the sole writer: :func:`append_event` is the only code path in
``sa/`` that opens ``events.jsonl`` for writing. Everything else reads the log
and folds it.

Projections are a pure fold of the log (design.md §4). Ten tables exist from
day 1, including ``usage`` and ``claims``, which are the scorecard's source.
Unknown event types are recorded in ``events`` and ignored by projections, so
the log stays forward-compatible.

Python 3 stdlib only.
"""

from __future__ import annotations

import fcntl
import json
import os
from pathlib import Path

from sa_paths import canonical, events_path, parse_at, sa_home, utc_now

#: The ten tables, in the order ``sa-store tables`` prints them.
TABLE_ORDER = (
    "events",
    "tickets",
    "mandates",
    "threads",
    "subs",
    "assignments",
    "outbox",
    "rulings",
    "usage",
    "claims",
)

#: Primary key field per table (design.md §4).
TABLE_KEYS = {
    "events": "seq",
    "tickets": "id",
    "mandates": "ticket",
    "threads": "id",
    "subs": "id",
    "assignments": "ticket",
    "outbox": "event_id",
    "rulings": "id",
    "usage": "ticket",
    "claims": "id",
}

#: Field list per table (design.md §4). ``events`` is the envelope itself.
TABLE_FIELDS = {
    "events": ("actor", "at", "id", "payload", "seq", "ticket", "type"),
    "tickets": (
        "id",
        "title",
        "body",
        "requester",
        "state",
        "class",
        "acceptance",
        "owner",
        "created_at",
        "updated_at",
    ),
    "mandates": (
        "ticket",
        "requester",
        "scope_paths",
        "rules_in_force",
        "issued_at",
        "expires_at",
        "revoked",
    ),
    "threads": ("id", "ticket", "opened_at", "messages"),
    "subs": ("id", "ticket", "parent", "role", "state", "created_at"),
    "assignments": ("ticket", "owner", "reason", "assigned_at"),
    "outbox": (
        "event_id",
        "ticket",
        "owner",
        "state",
        "attempts",
        "enqueued_at",
        "delivered_at",
        "last_error",
    ),
    "rulings": ("id", "ticket", "ruling", "rationale", "actor", "at"),
    "usage": ("ticket", "by_tier", "total_tokens"),
    "claims": ("id", "ticket", "claim", "evidence_command", "at"),
}

#: The five legal actors (design.md §3).
ACTORS = ("router", "engine", "code", "worker", "human")

#: Every event type the fold understands (design.md §5).
EVENT_TYPES = (
    "ticket.created",
    "ticket.classified",
    "ticket.assigned",
    "ticket.refused",
    "ticket.dispatched",
    "mandate.issued",
    "mandate.revoked",
    "thread.opened",
    "thread.message",
    "sub.spawned",
    "assignment.created",
    "outbox.enqueued",
    "outbox.delivered",
    "outbox.failed",
    "ruling.recorded",
    "usage.recorded",
    "claim.recorded",
)

#: Sentinel key for a ``usage.recorded`` event that carries no ticket.
UNASSIGNED = "unassigned"


class StoreError(Exception):
    """A caller error the CLI reports and exits non-zero on."""


# --------------------------------------------------------------------------
# event log
# --------------------------------------------------------------------------


def event_id(seq: int) -> str:
    """Return the deterministic event id for ``seq``."""
    return f"ev-{seq:016d}"


def read_events(home: Path | None = None) -> list[dict]:
    """Read the event log as a list of envelopes (empty when absent)."""
    path = events_path(home)
    if not path.exists():
        return []
    events = []
    with path.open("r", encoding="utf-8") as handle:
        for lineno, line in enumerate(handle, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError as exc:
                raise StoreError(f"{path}:{lineno}: corrupt event line: {exc}") from exc
    return events


def append_event(
    type: str,
    actor: str,
    ticket: str | None = None,
    at: str | None = None,
    payload: dict | None = None,
    home: Path | None = None,
) -> dict:
    """Append one event to the log and return the stored envelope.

    This is the Engine's only write path. ``seq`` is assigned here, so replay is
    byte-stable; ``id`` is derived from ``seq``.
    """
    if not isinstance(type, str) or not type.strip():
        raise StoreError("type must be a non-empty string")
    if actor not in ACTORS:
        raise StoreError(f"actor must be one of {', '.join(ACTORS)}: got {actor!r}")
    if payload is None:
        payload = {}
    if not isinstance(payload, dict):
        raise StoreError("payload must be a JSON object")
    stamp = parse_at(at) if at is not None else utc_now()

    root = home or sa_home()
    root.mkdir(parents=True, exist_ok=True)
    path = events_path(root)
    lock_path = root / ".events.lock"

    with lock_path.open("a", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            existing = read_events(root)
            seq = (existing[-1]["seq"] + 1) if existing else 1
            event = {
                "actor": actor,
                "at": stamp,
                "id": event_id(seq),
                "payload": payload,
                "seq": seq,
                "ticket": ticket,
                "type": type,
            }
            with path.open("a", encoding="utf-8") as handle:
                handle.write(canonical(event) + "\n")
                handle.flush()
                os.fsync(handle.fileno())
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
    return event


# --------------------------------------------------------------------------
# fold
# --------------------------------------------------------------------------


def _payload(event: dict) -> dict:
    payload = event.get("payload")
    return payload if isinstance(payload, dict) else {}


def ticket_id_for(seq: int) -> str:
    """Return the ticket id a ``ticket.created`` event at ``seq`` creates."""
    return f"T-{seq:04d}"


def _ticket_row(state: dict, tid: str, event: dict) -> dict:
    """Return the ticket row for ``tid``, creating a stub when absent."""
    row = state["tickets"].get(tid)
    if row is None:
        row = {
            "id": tid,
            "title": None,
            "body": None,
            "requester": None,
            "state": "new",
            "class": None,
            "acceptance": None,
            "owner": None,
            "created_at": event["at"],
            "updated_at": event["at"],
        }
        state["tickets"][tid] = row
    return row


def _ensure_ticket(state: dict, event: dict) -> dict | None:
    """Return the ticket row for ``event``, creating a stub when absent."""
    tid = event.get("ticket")
    if tid is None:
        return None
    return _ticket_row(state, tid, event)


def _on_ticket_created(state: dict, event: dict) -> None:
    payload = _payload(event)
    # The Engine owns ``seq``, so it owns the ticket id derived from it. A
    # creator that cannot know the seq yet omits the envelope ticket and the
    # fold names the ticket here, under the same lock that assigned the seq.
    tid = event.get("ticket") or ticket_id_for(event["seq"])
    row = _ticket_row(state, tid, event)
    row["title"] = payload.get("title")
    row["body"] = payload.get("body")
    row["requester"] = payload.get("requester")
    row["acceptance"] = payload.get("acceptance")
    row["state"] = "new"
    row["created_at"] = event["at"]
    row["updated_at"] = event["at"]


def _on_ticket_classified(state: dict, event: dict) -> None:
    row = _ensure_ticket(state, event)
    if row is None:
        return
    row["class"] = _payload(event).get("class")
    row["updated_at"] = event["at"]


def _on_ticket_assigned(state: dict, event: dict) -> None:
    row = _ensure_ticket(state, event)
    if row is None:
        return
    row["owner"] = _payload(event).get("owner")
    row["state"] = "assigned"
    row["updated_at"] = event["at"]


def _on_ticket_refused(state: dict, event: dict) -> None:
    row = _ensure_ticket(state, event)
    if row is None:
        return
    row["state"] = "refused"
    row["updated_at"] = event["at"]


def _on_ticket_dispatched(state: dict, event: dict) -> None:
    payload = _payload(event)
    row = _ensure_ticket(state, event)
    if row is None:
        return
    row["state"] = "dispatched"
    if payload.get("worker") is not None:
        row["owner"] = payload.get("worker")
    row["updated_at"] = event["at"]


def _on_mandate_issued(state: dict, event: dict) -> None:
    payload = _payload(event)
    tid = event.get("ticket")
    if tid is None:
        return
    state["mandates"][tid] = {
        "ticket": tid,
        "requester": payload.get("requester"),
        "scope_paths": list(payload.get("scope_paths") or []),
        "rules_in_force": list(payload.get("rules_in_force") or []),
        "issued_at": event["at"],
        "expires_at": payload.get("expires_at"),
        "revoked": False,
    }


def _on_mandate_revoked(state: dict, event: dict) -> None:
    tid = event.get("ticket")
    if tid is None:
        return
    row = state["mandates"].get(tid)
    if row is None:
        row = {
            "ticket": tid,
            "requester": None,
            "scope_paths": [],
            "rules_in_force": [],
            "issued_at": event["at"],
            "expires_at": None,
            "revoked": False,
        }
        state["mandates"][tid] = row
    row["revoked"] = True


def _on_thread_opened(state: dict, event: dict) -> None:
    thread = _payload(event).get("thread")
    if thread is None:
        return
    state["threads"][thread] = {
        "id": thread,
        "ticket": event.get("ticket"),
        "opened_at": event["at"],
        "messages": [],
    }


def _on_thread_message(state: dict, event: dict) -> None:
    payload = _payload(event)
    thread = payload.get("thread")
    if thread is None:
        return
    row = state["threads"].get(thread)
    if row is None:
        row = {
            "id": thread,
            "ticket": event.get("ticket"),
            "opened_at": event["at"],
            "messages": [],
        }
        state["threads"][thread] = row
    row["messages"].append(
        {
            "actor": payload.get("actor") or event.get("actor"),
            "at": event["at"],
            "text": payload.get("text"),
        }
    )


def _on_sub_spawned(state: dict, event: dict) -> None:
    payload = _payload(event)
    sub = payload.get("sub")
    if sub is None:
        return
    state["subs"][sub] = {
        "id": sub,
        "ticket": event.get("ticket"),
        "parent": payload.get("parent"),
        "role": payload.get("role"),
        "state": "spawned",
        "created_at": event["at"],
    }


def _on_assignment_created(state: dict, event: dict) -> None:
    payload = _payload(event)
    tid = event.get("ticket")
    if tid is None:
        return
    state["assignments"][tid] = {
        "ticket": tid,
        "owner": payload.get("owner"),
        "reason": payload.get("reason"),
        "assigned_at": event["at"],
    }


def _on_outbox_enqueued(state: dict, event: dict) -> None:
    payload = _payload(event)
    eid = payload.get("event_id")
    if eid is None:
        return
    state["outbox"][eid] = {
        "event_id": eid,
        "ticket": event.get("ticket"),
        "owner": payload.get("owner"),
        "state": "pending",
        "attempts": 0,
        "enqueued_at": event["at"],
        "delivered_at": None,
        "last_error": None,
    }


def _outbox_row(state: dict, event: dict) -> dict | None:
    payload = _payload(event)
    eid = payload.get("event_id")
    if eid is None:
        return None
    row = state["outbox"].get(eid)
    if row is None:
        row = {
            "event_id": eid,
            "ticket": event.get("ticket"),
            "owner": payload.get("owner"),
            "state": "pending",
            "attempts": 0,
            "enqueued_at": event["at"],
            "delivered_at": None,
            "last_error": None,
        }
        state["outbox"][eid] = row
    return row


def _on_outbox_delivered(state: dict, event: dict) -> None:
    payload = _payload(event)
    row = _outbox_row(state, event)
    if row is None:
        return
    receipt = payload.get("receipt")
    delivered_at = event["at"]
    if isinstance(receipt, dict) and receipt.get("at"):
        delivered_at = receipt["at"]
    row["state"] = "delivered"
    row["attempts"] = row["attempts"] + 1
    row["delivered_at"] = delivered_at
    row["last_error"] = None
    if payload.get("owner") is not None:
        row["owner"] = payload.get("owner")


def _on_outbox_failed(state: dict, event: dict) -> None:
    payload = _payload(event)
    row = _outbox_row(state, event)
    if row is None:
        return
    attempt = payload.get("attempt")
    row["state"] = "failed"
    row["attempts"] = attempt if isinstance(attempt, int) else row["attempts"] + 1
    row["last_error"] = payload.get("error")
    if payload.get("owner") is not None:
        row["owner"] = payload.get("owner")


def _on_ruling_recorded(state: dict, event: dict) -> None:
    payload = _payload(event)
    rid = payload.get("id") or f"rul-{event['seq']:016d}"
    state["rulings"][rid] = {
        "id": rid,
        "ticket": event.get("ticket"),
        "ruling": payload.get("ruling"),
        "rationale": payload.get("rationale"),
        "actor": event.get("actor"),
        "at": event["at"],
    }


def _on_usage_recorded(state: dict, event: dict) -> None:
    payload = _payload(event)
    tier = payload.get("tier")
    if tier is None:
        return
    tid = event.get("ticket")
    key = tid if tid is not None else UNASSIGNED
    row = state["usage"].get(key)
    if row is None:
        row = {"ticket": key, "by_tier": {}, "total_tokens": 0}
        state["usage"][key] = row
    bucket = row["by_tier"].get(tier)
    if bucket is None:
        bucket = {"tokens": 0, "calls": 0}
        row["by_tier"][tier] = bucket
    tokens = payload.get("tokens") or 0
    calls = payload.get("calls") or 0
    bucket["tokens"] = bucket["tokens"] + tokens
    bucket["calls"] = bucket["calls"] + calls
    row["total_tokens"] = row["total_tokens"] + tokens


def _on_claim_recorded(state: dict, event: dict) -> None:
    payload = _payload(event)
    cid = payload.get("id") or f"clm-{event['seq']:016d}"
    state["claims"][cid] = {
        "id": cid,
        "ticket": event.get("ticket"),
        "claim": payload.get("claim"),
        "evidence_command": payload.get("evidence_command"),
        "at": event["at"],
    }


_HANDLERS = {
    "ticket.created": _on_ticket_created,
    "ticket.classified": _on_ticket_classified,
    "ticket.assigned": _on_ticket_assigned,
    "ticket.refused": _on_ticket_refused,
    "ticket.dispatched": _on_ticket_dispatched,
    "mandate.issued": _on_mandate_issued,
    "mandate.revoked": _on_mandate_revoked,
    "thread.opened": _on_thread_opened,
    "thread.message": _on_thread_message,
    "sub.spawned": _on_sub_spawned,
    "assignment.created": _on_assignment_created,
    "outbox.enqueued": _on_outbox_enqueued,
    "outbox.delivered": _on_outbox_delivered,
    "outbox.failed": _on_outbox_failed,
    "ruling.recorded": _on_ruling_recorded,
    "usage.recorded": _on_usage_recorded,
    "claim.recorded": _on_claim_recorded,
}


def fold(events: list[dict]) -> dict:
    """Fold ``events`` into the ten-table snapshot.

    Pure: the same log always produces the same snapshot, byte for byte.
    Unknown event types land in ``events`` and change nothing else.
    """
    state = {name: {} for name in TABLE_ORDER}
    for event in events:
        state["events"][str(event["seq"])] = event
        handler = _HANDLERS.get(event.get("type"))
        if handler is not None:
            handler(state, event)
    return state


def snapshot(home: Path | None = None) -> dict:
    """Read the log and return the folded snapshot."""
    return fold(read_events(home))


def table(state: dict, name: str) -> dict:
    """Return one table from a snapshot, validating the name."""
    if name not in TABLE_KEYS:
        raise StoreError(f"unknown table: {name} (known: {', '.join(TABLE_ORDER)})")
    return state[name]


def query(state: dict, name: str, where: list[str] | None = None) -> list[dict]:
    """Return the rows of ``name`` matching every ``k=v`` filter, key-ordered."""
    rows = table(state, name)
    filters = []
    for clause in where or []:
        if "=" not in clause:
            raise StoreError(f"--where expects k=v: got {clause!r}")
        key, value = clause.split("=", 1)
        filters.append((key, value))
    selected = []
    for key in sorted(rows):
        row = rows[key]
        if all(str(row.get(k)) == v for k, v in filters):
            selected.append(row)
    return selected
