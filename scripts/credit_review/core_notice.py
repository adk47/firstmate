#!/usr/bin/env python3
"""Has core itself told this user something lately? (Fable sender map 2026-10-27, item 2: the one
structural fix; firstmate inbox 045.)

Core sends its own notices outside the hydra verify ledger: the "credit approved" notice
(metadata.approvedNotice.noticeSentAt), the proof ask (metadata.proofRequest), the info request
(metadata.infoRequest), claim updates (claiming.updatedAt), and any status change (updatedat). A hydra note
on top of one of those is a second message the ledger cannot see. So every hydra sender asks this module
first and holds the user when, on the core replica:

  - any ISO timestamp inside metadata.approvedNotice / proofRequest / infoRequest of any of the user's
    credit requests is within the last 7 days;
  - any of the user's claims (claiming) was updated within the last 7 days - a claim never touched since it was
    filed (updatedat == createdat) is the user's own filing, not a notice, and does not count (p1 180);
  - any of the user's credit requests changed today (updatedat on the current UTC day).

Reason: core_notice_within_7d. Read-only (Trino SELECTs). Timestamps are read in full, offset included, and
normalized to UTC (a value with no zone is UTC). Fail closed: an unreadable replica is UNKNOWN and the caller
sends nothing; a marker that is present but has no readable timestamp makes THAT user unknown (check: exit 2;
batch: held, counted as held_unknown_marker).

CLI (the gate calls it under python3 -I):
  core_notice.py check --user-id N        -> {"hold": bool, "reasons": [...]}   exit 0 clear / 3 hold / 2 unknown
  core_notice.py check --email E          -> same, for every core account with that email (notes keyed by
                                             email only, e.g. removal notices); no such account = clear
  core_notice.py batch --users-file F --out G   -> G = ids held (one per line); exit 0, 2 unknown
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from typing import Callable, Iterable

TRINO = os.environ.get("CORE_NOTICE_TRINO", "/opt/hydra/scripts/trino-query.sh")
REASON = "core_notice_within_7d"
WINDOW = timedelta(days=7)
CHUNK = 400
# The FULL ISO 8601 value, offset included (QA + Fable on #1397: a prefix-only match read
# 2026-10-20T14:30:00-02:00 as 14:30 UTC, two hours older than it is, and cleared a user inside the window).
# Trino renders timestamptz as "2026-10-27 08:00:00.000 UTC"; core JSON markers as "...T08:34:06.571Z".
# A value with NO zone is read as UTC: a documented assumption (core writes UTC; none seen without a zone).
ISO = re.compile(r"(\d{4}-\d{2}-\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?"
                 r"(?:\s*(Z|UTC|[+-]\d{2}(?::?\d{2})?))?")
UNKNOWN = "unknown: "
Query = Callable[[str], "list[list[str]]"]


class Unreadable(RuntimeError):
    pass


def trino(sql: str) -> list[list[str]]:
    try:
        p = subprocess.run([TRINO], input=sql, capture_output=True, text=True, timeout=600, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        raise Unreadable(f"trino did not run: {type(exc).__name__}") from exc
    if p.returncode != 0:
        raise Unreadable(f"trino rc={p.returncode}: {p.stderr.strip()[-200:]}")
    return list(csv.reader(io.StringIO("\n".join(ln for ln in p.stdout.splitlines() if ln.startswith('"')))))


def _rows(query: Query, sql: str, width: int) -> list[list[str]]:
    rows = query(sql)
    if any(len(r) != width or not str(r[0]).isdigit() for r in rows):
        raise Unreadable(f"unexpected replica row shape (want {width} columns)")
    return rows


class Unparseable(ValueError):
    pass


def _one(value: str) -> datetime:
    """Exactly ONE full ISO 8601 timestamp (the whole value, nothing before or after it), as aware UTC."""
    m = ISO.fullmatch((value or "").strip())
    if not m:
        raise Unparseable(f"not a timestamp: {str(value)[:60]!r}")
    day, hh, mm, ss, frac, zone = m.groups()
    z = "+00:00" if zone in (None, "Z", "UTC") else zone
    if len(z) == 3:
        z += ":00"
    elif ":" not in z:
        z = z[:3] + ":" + z[3:]
    try:
        t = datetime.fromisoformat(f"{day}T{hh}:{mm}:{ss or '00'}.{(frac or '0')[:6].ljust(6, '0')}{z}")
    except ValueError as exc:
        raise Unparseable(f"not a real timestamp: {str(value)[:60]!r}") from exc
    return t.astimezone(timezone.utc)


TS_KEY = re.compile(r"^(?:at|.*At|.*_at)$")


def _ts(text: str) -> list[datetime]:
    """The timestamps of ONE core value, as aware UTC datetimes. '' / 'null' -> [] (no marker).
    A plain value (a column) must be exactly one timestamp. A JSON marker object is read field by field (QA on
    #1397: a substring search let an old valid createdAt mask a broken noticeSentAt): EVERY timestamp-named field
    (at, *At, *_at) at any depth must be null or exactly one timestamp, and the marker must carry at least one.
    Anything else raises Unparseable: the caller reads that user as UNKNOWN, never as old."""
    text = (text or "").strip()
    if text in ("", "null"):
        return []
    if not text.startswith("{"):
        return [_one(text)]
    try:
        obj = json.loads(text)
    except ValueError as exc:
        raise Unparseable(f"marker is not JSON: {text[:60]!r}") from exc
    out: list[datetime] = []

    def walk(node: object) -> None:
        if isinstance(node, dict):
            for k, v in node.items():
                if TS_KEY.match(str(k)) and v is not None:
                    if not isinstance(v, str):
                        raise Unparseable(f"{k} is not a timestamp string")
                    out.append(_one(v))
                else:
                    walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    walk(obj)
    if not out:
        raise Unparseable(f"marker has no timestamp: {text[:60]!r}")
    return out


def reasons_by_user(user_ids: Iterable[int], *, query: Query = trino,
                    now: datetime | None = None, window: timedelta = WINDOW) -> dict[int, list[str]]:
    """{user id: [why...]} for the users core told something lately (empty list = clear). Unreadable raises.
    A marker that is present but carries no readable timestamp is UNKNOWN for that user ("unknown: ..."):
    the caller holds them, never clears them."""
    now = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    since, today = now - window, now.date()
    span = "7d" if window == timedelta(days=7) else f"{int(window.total_seconds() // 3600)}h"   # the reasons name it

    def within(u: int, what: str, value: str, test) -> None:
        try:
            if any(test(t) for t in _ts(value)):
                out[u].append(what)
        except Unparseable as exc:
            out[u].append(f"{UNKNOWN}{what.split(' ')[0]} ({exc})")

    ids = sorted({int(u) for u in user_ids})
    out: dict[int, list[str]] = {u: [] for u in ids}
    for i in range(0, len(ids), CHUNK):
        lst = ",".join(map(str, ids[i:i + CHUNK]))
        for uid, ap, pr, ir, upd in _rows(query, 
                "SELECT CAST(userid AS varchar), "
                "coalesce(json_format(json_extract(metadata, '$.approvedNotice')), ''), "
                "coalesce(json_format(json_extract(metadata, '$.proofRequest')), ''), "
                "coalesce(json_format(json_extract(metadata, '$.infoRequest')), ''), "
                "CAST(updatedat AS varchar) FROM postgresql_core.public.credit_requests "
                f"WHERE deletedat IS NULL AND userid IN ({lst})", 5):
            u = int(uid)
            if u not in out:
                continue
            for name, blob in (("approvedNotice", ap), ("proofRequest", pr), ("infoRequest", ir)):
                within(u, f"{name} within {span}", blob, lambda t: t >= since)
            within(u, "credit request changed today", upd, lambda t: t.date() == today)
        # p1 180: a claim never touched since it was filed (updatedat == createdat) is the user's own filing, not
        # something core told them - it never holds. Any later update (a decision, a code check) still does.
        for uid, upd, created in _rows(query,
                "SELECT CAST(userid AS varchar), CAST(updatedat AS varchar), CAST(createdat AS varchar) "
                f"FROM postgresql_core.public.claiming WHERE userid IN ({lst}) AND updatedat >= current_timestamp - INTERVAL '8' DAY", 3):
            u = int(uid)
            if u in out and not (upd and upd == created):
                within(u, f"claim updated within {span}", upd, lambda t: t >= since)
    return {u: sorted(set(w)) for u, w in out.items()}


EMAIL_RE = re.compile(r"^[^\s'\\@]+@[^\s'\\@]+\.[^\s'\\@]+$")


def user_ids_for_email(email: str, *, query: Query = trino) -> list[int]:
    """Core account ids with this email (case-insensitive). The email is validated, never interpolated raw."""
    if not EMAIL_RE.match(email or ""):
        raise Unreadable("not a checkable email")
    return [int(r[0]) for r in _rows(query, "SELECT CAST(id AS varchar) FROM postgresql_core.public.users "
                                            f"WHERE lower(email) = '{email.lower()}'", 1)]


def _main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="core notices within 7 days (read-only)")
    sub = ap.add_subparsers(dest="op", required=True)
    c = sub.add_parser("check")
    who = c.add_mutually_exclusive_group(required=True)
    who.add_argument("--user-id")
    who.add_argument("--email")
    # firstmate 034a (2026-11-16): the ask's no-recontact window is per campaign; the gate passes 24 for
    # proof-need-ask. The reason code (core_notice_within_7d) keeps its name; the reasons name the window.
    c.add_argument("--window-hours", type=int, default=int(WINDOW.total_seconds() // 3600))
    b = sub.add_parser("batch")
    b.add_argument("--users-file", required=True)
    b.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    if a.op == "check":
        if a.user_id is not None and not str(a.user_id).isdigit():
            print(json.dumps({"hold": None, "reasons": ["no Muso user id"]}))
            return 2
        try:
            ids = [int(a.user_id)] if a.user_id is not None else user_ids_for_email(a.email)
            if not 1 <= a.window_hours <= 24 * 7:
                print(json.dumps({"hold": None, "reasons": [f"--window-hours {a.window_hours} is outside 1..168"]}))
                return 2
            why = sorted({w for ws in reasons_by_user(ids, window=timedelta(hours=a.window_hours)).values()
                          for w in ws}) if ids else []
        except Unreadable as exc:
            print(json.dumps({"hold": None, "reasons": [str(exc)]}))
            return 2
        if any(w.startswith(UNKNOWN) for w in why):
            print(json.dumps({"hold": None, "reasons": why}))
            return 2
        print(json.dumps({"hold": bool(why), "reason": REASON if why else "", "reasons": why}))
        return 3 if why else 0
    ids = [int(x) for x in open(a.users_file).read().split() if x.strip().isdigit()]
    try:
        why = reasons_by_user(ids)
    except Unreadable as exc:
        print(json.dumps({"error": str(exc)}))
        return 2
    held = sorted(u for u, w in why.items() if w)
    with open(a.out, "w") as fh:
        fh.write("".join(f"{u}\n" for u in held))
    unknown = sum(1 for w in why.values() if any(x.startswith(UNKNOWN) for x in w))
    print(json.dumps({"users": len(ids), "held": len(held), "held_unknown_marker": unknown, "reason": REASON}))
    return 0


if __name__ == "__main__":
    sys.exit(_main())
