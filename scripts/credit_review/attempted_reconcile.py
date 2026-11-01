#!/usr/bin/env python3
"""Reconcile 'attempted' in-thread notes that were in fact delivered (p1 565, t01b's read-back: ledger 6360).

An 'attempted' row is a send whose outcome the gate could not verify; it is never re-sent automatically. When the note
DID land, the row is the double-send shape (anyone re-sending it by hand posts it twice). This step looks, READ-ONLY on
Intercom, for our own part in the logged conversation and, when found, finalizes the row as 'sent' with that part id.
It NEVER posts anything and never changes a row it cannot prove.

Proof = in the row's logged conversation, a part by the logged admin (comment or assignment: replying into an unassigned
thread stores the reply as an assignment part), created at or after the post was logged, whose normalised text sha256
equals the text_sha256 the gate logged with the post. Rows whose api log predates text_sha256 can be reconciled one at a
time by a named human: --row N --part P --confirmed-by WHO (the part must still be ours and after the post).

  attempted_reconcile.py [--apply]                      every attempted in-thread row with a text_sha256 in its log
  attempted_reconcile.py --row 6360 --part 57427459916 --confirmed-by <who> [--apply]
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import re
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from credit_review import comm_state, verify_ledger  # noqa: E402

Intercom = Callable[[str, str, Any], dict]
GATE_ADMIN = "5763097"          # the gate's fixed sender (comm_state.GATE_BOT_ADMINS); older api logs did not record it


# QA #1607: jq's \s set = Python's \s minus the four information separators U+001C..U+001F (built from code points,
# so no escaped literal reaches scripts/check-intercom-reply-identity.sh)
_WS = re.compile("[^\\S" + "".join(chr(c) for c in range(28, 32)) + "]+")


def ntext(body: str) -> str:
    """The gate's NTEXT_JQ: tags out, the renderer's entities decoded, whitespace collapsed."""
    t = re.sub(r"<[^>]+>", " ", body or "")
    t = t.replace("&nbsp;", " ").replace("&quot;", '"').replace("&#39;", "'").replace("&#x27;", "'").replace("&apos;", "'")
    t = t.replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")
    # QA #1607: the SAME class as the gate's jq `\s` (Oniguruma, Unicode: U+00A0, U+2003, U+3000, U+0085, U+2028 ...)
    # - Python's `\s` also matches U+001C-U+001F, which jq's does not, so those four are excluded
    return _WS.sub(" ", t).strip(" ")


def text_sha(body: str) -> str:
    return hashlib.sha256(ntext(body).encode()).hexdigest()


def _ts(s: str) -> int:
    return int(datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp())


def candidates(db: sqlite3.Connection) -> list[dict[str, Any]]:
    rows = db.execute("SELECT id, api_log, message_type, status FROM verify_messages WHERE status = 'attempted' "
                      "AND message_type = 'comment' ORDER BY id").fetchall()
    out = []
    for rid, log, mt, st in rows:
        try:
            d = json.loads(Path(log).read_text(encoding="utf-8")) if log else {}
        except (OSError, ValueError):
            d = {}
        out.append({"row": int(rid), "log": log or "", "conversation": str(d.get("conversation") or ""),
                    "admin": str(d.get("admin_id") or ""), "text_sha256": str(d.get("text_sha256") or ""),
                    "logged_at": str(d.get("timestamp") or "")})
    return out


def find_part(c: dict[str, Any], ic: Intercom, *, part_id: str = "") -> tuple[str, str]:
    """(part id, '') when the row's note is proven in its thread; ('', why not) otherwise."""
    if not c["conversation"].isdigit():
        return "", "no conversation in the api log"
    if not part_id and not re.fullmatch(r"[0-9a-f]{64}", c["text_sha256"]):
        return "", "the api log has no text_sha256 (older post): reconcile by hand with --row/--part/--confirmed-by"
    if part_id and not c["admin"]:
        c = {**c, "admin": GATE_ADMIN}                          # an older log (before admin_id): the gate's one sender
    if not re.fullmatch(r"\d+", c["admin"] or ""):
        return "", "no admin id in the api log"
    try:
        since = _ts(c["logged_at"])
    except ValueError:
        return "", "no post time in the api log"
    conv = ic("GET", f"/conversations/{c['conversation']}", None)
    if str(conv.get("id") or "") != c["conversation"]:
        return "", "conversation unreadable"
    parts = (conv.get("conversation_parts") or {}).get("conversation_parts") or []
    ours = [p for p in parts if (p.get("author") or {}).get("type") == "admin"
            and str((p.get("author") or {}).get("id") or "") == c["admin"]
            and (p.get("part_type") or "") in ("comment", "assignment") and int(p.get("created_at") or 0) >= since]
    if part_id:                                                 # the human-confirmed path: that part, still ours
        hit = [p for p in ours if str(p.get("id")) == part_id]
        if not hit:
            return "", f"part {part_id} is not our admin's comment/assignment after the post"
        # QA #1607: the human path is for HASHLESS (older) logs only - a log that carries text_sha256 still needs the
        # chosen part's text to be the text we sent (else a later, different note of ours could close the row)
        if re.fullmatch(r"[0-9a-f]{64}", c["text_sha256"]) and text_sha(hit[0].get("body") or "") != c["text_sha256"]:
            return "", f"part {part_id} is not the text this row logged (text_sha256 differs)"
        return part_id, ""
    if not re.fullmatch(r"[0-9a-f]{64}", c["text_sha256"]):
        return "", "the api log has no text_sha256 (older post): reconcile by hand with --row/--part/--confirmed-by"
    hit = [p for p in ours if text_sha(p.get("body") or "") == c["text_sha256"]]
    if len(hit) != 1:
        return "", f"{len(hit)} matching parts (need exactly 1)"
    return str(hit[0].get("id")), ""


def run(db: sqlite3.Connection, ic: Intercom, *, apply: bool, row: int | None = None, part: str = "",
        confirmed_by: str = "") -> list[dict[str, Any]]:
    out = []
    for c in candidates(db):
        if row is not None and c["row"] != row:
            continue
        try:
            pid, why = find_part(c, ic, part_id=part if row is not None else "")
        except comm_state.Unknown as exc:
            pid, why = "", f"Intercom unreadable: {exc}"
        rec = {"row": c["row"], "conversation": c["conversation"], "part": pid, "why": why, "applied": False}
        if pid and apply:
            reason = f"reconciled: delivered as part {pid}" + (f" (confirmed by {confirmed_by})" if confirmed_by else
                                                               " (text_sha256 match)")
            verify_ledger.finalize(db, message_row=c["row"], status="sent", message_id=pid,
                                   conversation_id=c["conversation"], reason=reason)
            rec["applied"] = True
        out.append(rec)
    return out


def _main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--ledger", default=verify_ledger.DEFAULT_PATH)
    ap.add_argument("--apply", action="store_true", help="write 'sent' for proven rows (default: report only)")
    ap.add_argument("--row", type=int, default=None)
    ap.add_argument("--part", default="")
    ap.add_argument("--confirmed-by", default="")
    a = ap.parse_args(argv)
    if (a.row is None) != (not a.part) or (a.part and not a.confirmed_by.strip()):
        print("--row, --part and --confirmed-by go together (the human-confirmed path)", file=sys.stderr)
        return 2
    db = verify_ledger.connect(a.ledger)
    res = run(db, comm_state.intercom, apply=a.apply, row=a.row, part=a.part, confirmed_by=a.confirmed_by.strip())
    print(json.dumps({"apply": a.apply, "rows": res, "reconciled": sum(r["applied"] for r in res)}))
    return 0


if __name__ == "__main__":
    sys.exit(_main())
