"""Gog-CLI adapter for Google Sheets.

gog surface (v0.12.0, verified 2026-04-14):
- `sheets get <spreadsheetId> <range>` — range is positional, not a flag.
  Returns `{"range": ..., "values": [[...], ...]}`.
- `sheets append <spreadsheetId> <range> --values-json '[[...]]'` — range
  positional; `--values-json` not `--values`.
"""
from __future__ import annotations

import json
import re
from typing import Optional

from ._gog import run_gog
from .config import CONTACTS_SHEET_ID, CONTACTS_TAB, LOGBOOK_SHEET_ID, LOGBOOK_TAB
from .types import ContactRow


def _run_gog(*args: str) -> str:
    return run_gog(*args)


def get_contact_by_row_id(row_id: int, account: str = "a@muso.ai") -> Optional[ContactRow]:
    """Read one row from contacts_intelligence by its Row ID column."""
    out = _run_gog("sheets", "get", CONTACTS_SHEET_ID,
                   f"{CONTACTS_TAB}!A:Z",
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
        return ContactRow(row_id=str(row_id),
                          valid_professional_email=(row[idx_email] or "").strip())
    return None


def count_prior_followups(sheet_row_id: int, account: str = "a@muso.ai") -> int:
    """Legacy key: count follow-ups logged with the token `row:<id>`."""
    return count_prior_followups_by_token(f"row:{sheet_row_id}", account)


def count_prior_followups_by_token(token: str, account: str = "a@muso.ai") -> int:
    """Scan the logbook for Action='Follow-Up Sent' rows whose notes carry
    `token` as a whole whitespace-delimited token (`nocodb:1` must not
    count `nocodb:12`)."""
    out = _run_gog("sheets", "get", LOGBOOK_SHEET_ID,
                   f"{LOGBOOK_TAB}!A:Z",
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
    needle = re.compile(rf"(^|\s){re.escape(token)}(\s|$)")
    count = 0
    for row in rows[1:]:
        if len(row) <= max(idx_action, idx_notes):
            continue
        if row[idx_action].strip() == "Follow-Up Sent" and needle.search(row[idx_notes] or ""):
            count += 1
    return count


def append_logbook_row(values: list, account: str = "a@muso.ai") -> None:
    payload = json.dumps([values])
    _run_gog("sheets", "append", LOGBOOK_SHEET_ID,
             f"{LOGBOOK_TAB}!A:Z",
             "--values-json", payload,
             "--account", account)
