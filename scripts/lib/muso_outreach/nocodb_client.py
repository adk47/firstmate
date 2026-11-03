"""Read-only NocoDB adapter for the Contacts Intelligence table.

One `records.get` per lookup, through the muso-nocodb wrapper script
(`bash nocodb-api.sh --raw records.get <table> <Id>`). The token comes
from NOCODB_API_TOKEN in the worker's environment. No write verb is ever
issued from this module.

Every failure except a missing record raises. Callers run this before
the send, so a raise is retried safely and never double-sends.
"""
from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Optional

from .config import CONTACTS_NOCODB_TABLE
from .types import NocoContact

_NOT_FOUND = "ERR_RECORD_NOT_FOUND"
_HTTP_ERROR_EXIT = 3


def _script_path() -> str:
    override = os.environ.get("MUSO_NOCODB_API_SH")
    if override:
        return override
    # scripts/lib/muso_outreach/nocodb_client.py -> repo (or /opt/hydra) root
    root = Path(__file__).resolve().parents[3]
    return str(root / "skills-all" / "muso-nocodb" / "scripts" / "nocodb-api.sh")


def get_contact(nocodb_id: int) -> Optional[NocoContact]:
    """Return the contact with this NocoDB `Id`, or None if it does not exist."""
    res = subprocess.run(
        ["bash", _script_path(), "--raw", "records.get",
         CONTACTS_NOCODB_TABLE, str(int(nocodb_id))],
        capture_output=True, text=True, timeout=60,
    )
    if res.returncode == _HTTP_ERROR_EXIT and _NOT_FOUND in res.stdout:
        return None
    if res.returncode != 0:
        raise RuntimeError(
            f"nocodb-api.sh records.get exited {res.returncode}: "
            f"{res.stderr.strip()[:200]}"
        )
    try:
        rec = json.loads(res.stdout)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"nocodb-api.sh returned non-JSON output: {e}") from e
    if not isinstance(rec, dict) or "Id" not in rec:
        raise RuntimeError("nocodb record has no Id field")
    return NocoContact(
        nocodb_id=int(rec["Id"]),
        row_id=str(rec.get("Row ID") or "").strip(),
        valid_professional_email=str(rec.get("Valid Professional Email") or "").strip(),
        status=str(rec.get("Status") or "").strip(),
    )
