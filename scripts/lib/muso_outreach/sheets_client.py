"""Gog-CLI adapter for Google Sheets."""
from __future__ import annotations

import json
import subprocess
from typing import Optional

from .config import CONTACTS_SHEET_ID, CONTACTS_TAB, LOGBOOK_SHEET_ID, LOGBOOK_TAB
from .types import ContactRow


def _run_gog(*args: str) -> str:
    res = subprocess.run(
        ("gog", *args),
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
    )
    return res.stdout


def get_contact_by_row_id(row_id: int, account: str = "a@muso.ai") -> Optional[ContactRow]:
    """Read one row from contacts_intelligence by its Row ID column."""
    out = _run_gog("sheets", "get", CONTACTS_SHEET_ID,
                   "--range", f"{CONTACTS_TAB}!A:Z",
                   "--account", account, "--json")
    js = json.loads(out)
    header = js.get("values", [[]])[0]
    try:
        idx_row = header.index("Row ID")
        idx_email = header.index("Valid Professional Email")
    except ValueError:
        return None
    for row in js.get("values", [])[1:]:
        if len(row) <= max(idx_row, idx_email):
            continue
        if str(row[idx_row]).strip() != str(row_id):
            continue
        return ContactRow(row_id=row_id,
                          valid_professional_email=(row[idx_email] or "").strip())
    return None


def count_prior_followups(sheet_row_id: int, account: str = "a@muso.ai") -> int:
    """Scan the logbook for Action='Follow-Up Sent' rows with this
    sheet_row_id embedded in the notes or contact column."""
    out = _run_gog("sheets", "get", LOGBOOK_SHEET_ID,
                   "--range", f"{LOGBOOK_TAB}!A:Z",
                   "--account", account, "--json")
    js = json.loads(out)
    rows = js.get("values", [])
    if not rows:
        return 0
    header = rows[0]
    try:
        idx_action = header.index("Action")
        idx_notes = header.index("Hook / Notes")
    except ValueError:
        return 0
    needle = f"row:{sheet_row_id}"
    count = 0
    for row in rows[1:]:
        if len(row) <= max(idx_action, idx_notes):
            continue
        if row[idx_action].strip() == "Follow-Up Sent" and needle in (row[idx_notes] or ""):
            count += 1
    return count


def append_logbook_row(values: list, account: str = "a@muso.ai") -> None:
    payload = json.dumps([values])
    _run_gog("sheets", "append", LOGBOOK_SHEET_ID,
             "--range", LOGBOOK_TAB,
             "--values", payload,
             "--account", account)
