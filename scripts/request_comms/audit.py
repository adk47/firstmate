#!/usr/bin/env python3
"""Every status message is an audited action, with an inverse that is a real operation.

The inverse of `message.send` is not "unsend" — it is **stop**: the (request, state) pair is
marked told and no further line for it is ever produced by the driver again. Registering it here
means the ledger stays the single authority even if a human has to intervene after a bad send.

If the repo's ACTION-AUDIT ledger (`scripts/action_audit/`, lane action-audit-ledger-a1) is not
deployed yet, this module does NOT pretend and does NOT drop the row: it appends the exact
`message.send` row to `/var/lib/hydra/request-comms/audit-pending.jsonl` (0600, its own directory)
and reports `pending`, so the rows are importable the moment the ledger lands. Only when BOTH the
ledger and that spool are unwritable is the answer `unavailable`; the driver flags that on the
tick (exit 5) because a message nobody can audit should not have gone out.
"""
from __future__ import annotations

import os
import sys
from dataclasses import dataclass
from typing import Any

ACTION = "message.send"
INVERSE = "request-comms stop --request-ref <ref> --state <state>   (marks the pair told; no further line)"


@dataclass
class AuditRow:
    actor: str
    request_ref: str
    state: str
    channel: str
    user_id: str
    message_ref: str = ""
    body_sha: str = ""

    def as_dict(self) -> dict[str, Any]:
        return {"actor": self.actor, "action_type": ACTION, "target": f"user:{self.user_id}",
                "subject": f"{self.request_ref}@{self.state}", "channel": self.channel,
                "message_ref": self.message_ref, "body_sha256": self.body_sha,
                "inverse": INVERSE, "risk_class": "customer_message"}


PENDING = "/var/lib/hydra/request-comms/audit-pending.jsonl"


def preflight(*, pending_path: str = PENDING) -> tuple[bool, str]:
    """Can this tick record a row AT ALL? Asked before the first send, not after it.

    Without this, an audit surface that breaks mid-batch (the ledger refused, the spool's disk
    filled) only set a flag: the loop went on sending up to `max_per_run` more messages that nobody
    could audit and reported exit 5 at the end. A message nobody can audit should not go out, so the
    question is asked first and the answer stops the batch.
    """
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    why = ""
    try:
        import action_audit  # noqa: F401, PLC0415
    except Exception as exc:  # noqa: BLE001 — not deployed yet; the spool is the record
        why = f"action-audit ledger unavailable ({type(exc).__name__})"
    # The spool is proved writable in BOTH branches, not just when the import failed. An importable
    # ledger can still REFUSE a row (locked, read-only, schema drift), and `record` then falls back
    # to this file — so checking it only on ImportError made the preflight fail OPEN on exactly the
    # case it exists for: the first customer message went out, `record` answered `unavailable`, and
    # exit 5 arrived after the send. Proving the fallback first means `record` has somewhere to go.
    try:
        os.makedirs(os.path.dirname(pending_path), mode=0o700, exist_ok=True)
        with open(pending_path, "a", encoding="utf-8"):
            pass
    except OSError as exc:
        return False, f"{why or 'action-audit ledger importable'}; spool unwritable ({type(exc).__name__}: {exc})"[:200]
    return True, why


def record(row: AuditRow, *, pending_path: str = PENDING, at: str = "") -> tuple[str, str]:
    """('recorded' | 'pending' | 'unavailable', detail). Never raises: a broken audit surface must
    be loud, not fatal in the middle of a send."""
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    why = ""
    try:
        from action_audit import record as record_action  # noqa: PLC0415
    except Exception as exc:  # noqa: BLE001 — ImportError today; anything else is equally not-deployed
        why = f"action-audit ledger unavailable ({type(exc).__name__})"
    else:
        try:
            record_action(**row.as_dict())
            return "recorded", ""
        except Exception as exc:  # noqa: BLE001
            why = f"action-audit record failed ({type(exc).__name__}: {exc})"[:160]
    import json
    try:
        os.makedirs(os.path.dirname(pending_path), mode=0o700, exist_ok=True)
        with open(pending_path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps({**row.as_dict(), "at": at, "why": why}, sort_keys=True) + "\n")
        try:
            os.chmod(pending_path, 0o600)
        except OSError:
            pass
    except OSError as exc:
        return "unavailable", f"{why}; spool unwritable ({type(exc).__name__})"
    return "pending", f"{why}; spooled to {pending_path}"
