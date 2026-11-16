#!/usr/bin/env python3
"""Read-only measurements behind data/status-doc-received-drop-r1/report.md.

Run on node-8 without leaving a file there:

    ssh root@<node-8> 'python3 - gates'   < data/status-doc-received-drop-r1/tools/measure.py
    ssh root@<node-8> 'python3 - ledger'  < data/status-doc-received-drop-r1/tools/measure.py
    ssh root@<node-8> 'python3 - threads' < data/status-doc-received-drop-r1/tools/measure.py

It reads the tick's own `r1-*-check.json`, the receipts list, the proof store and the verify ledger
(all opened read-only), and `threads` makes one Intercom GET per held user. It writes nothing, sends
nothing, and prints ids, counts and classes only: never a message body, a name or a credential.
"""
from __future__ import annotations

import collections
import datetime
import glob
import json
import re
import sqlite3
import sys
import time
import urllib.request

SCHED = "/root/h2-runs/sched"
PROOF = "/var/lib/hydra-credit-verify/proof.sqlite"
LEDGER = "/var/lib/hydra/credit-review/ledger.sqlite3"
ENV = "/etc/openclaw/main.env"
CAROLINE = "5763097"
# the answer bank's `document_thanks` lead (plugins/intercom/src/answer-bank.ts)
THANKS = "Everything you send here is recorded"
# a document noun in our first comment; `file` is word-bounded so "profile" and "filing" do not count
NOUN = re.compile(r"document|attach|screenshot|invoice|\bfiles?\b", re.I)
STRONG = {"professional_id", "authenticated_email", "session", "professional_id+email", "external_id+email"}
HELD = re.compile(r"r1_receipted_in_thread.*?last_admin_comment_at=(\d+) \(conversation (\d+)")
BUCKETS = ("r1_receipted_in_thread", "core_notice_within_7d", "r1_filing_class_unknown", "r1_unreadable_filing",
           "screenshot of Muso", "comm_state", "no_channel", "gate_timeout", "G2", "G3", "G5")


def latest_list() -> tuple[str, dict[str, dict]]:
    tick = sorted(glob.glob(f"{SCHED}/*/receipts/receipts-received.json"))[-1]
    with open(tick, encoding="utf-8") as fh:
        return tick, {str(r["user_id"]): r for r in json.load(fh)["users"]}


def checks(days: int = 2) -> list[str]:
    since = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)).strftime("%Y%m%dT%H%MZ")
    return [f for f in sorted(glob.glob(f"{SCHED}/*/r1-*-check.json")) if f.split("/")[-2] >= since]


def last_outcomes() -> dict[str, tuple[str, str]]:
    last: dict[str, tuple[str, str]] = {}
    for path in checks():
        with open(path, encoding="utf-8") as fh:
            for o in json.load(fh).get("outcomes", []):
                last[str(o.get("user"))] = (str(o.get("result")), str(o.get("reason") or ""))
    return last


def bucket(result: str, reason: str) -> str:
    for key in BUCKETS:
        if key in reason:
            return key
    return f"{result}:other"


def cohort(row: dict) -> str:
    month = row["first_received"][:7]
    return month if month >= "2026-10" else "before 2026-10"


def gates() -> None:
    tick, listed = latest_list()
    files = checks()
    accepted = sum(len(json.load(open(f, encoding="utf-8")).get("accepted") or []) for f in files)
    last = last_outcomes()
    print(f"list: {tick} ({len(listed)} users); checks read: {len(files)}; accepted in them: {accepted}")
    table: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    for user, row in listed.items():
        table[cohort(row)][bucket(*last[user]) if user in last else "no gate call (runner hold)"] += 1
    for name in sorted(table):
        print(name, sum(table[name].values()), dict(table[name].most_common()))


def ledger() -> None:
    db = sqlite3.connect(f"file:{LEDGER}?mode=ro", uri=True)
    args = ("status-doc-received",)
    print("rows by status:", db.execute(
        "SELECT status, count(*) FROM verify_messages WHERE campaign=? GROUP BY 1", args).fetchall())
    print("sent by day:", db.execute(
        "SELECT substr(coalesce(sent_at, created_at), 1, 10), count(*) FROM verify_messages "
        "WHERE campaign=? AND status='sent' GROUP BY 1 ORDER BY 1", args).fetchall())
    per_day: collections.Counter = collections.Counter()
    for path in sorted(glob.glob(f"{SCHED}/*/r1-*-check.json")):
        try:
            with open(path, encoding="utf-8") as fh:
                per_day[path.split("/")[-2][:8]] += len(json.load(fh).get("accepted") or [])
        except (OSError, ValueError):
            continue
    print("accepted by the check, per day:", sorted(per_day.items()))


def token() -> str:
    with open(ENV, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("MUSOAI_INTERCOM_TOKEN="):
                return line.split("=", 1)[1].strip().strip("\"'")
    raise SystemExit("no Intercom token in the gateway env")


def conversation(tok: str, conv: str) -> dict:
    req = urllib.request.Request(
        f"https://api.intercom.io/conversations/{conv}?display_as=plaintext",
        headers={"Authorization": f"Bearer {tok}", "Accept": "application/json", "Intercom-Version": "2.11"})
    with urllib.request.urlopen(req, timeout=45) as resp:
        return json.load(resp)


def ours_after_filing(conv: dict) -> list[dict]:
    """The gate's RECEIPTED_JQ in Python: our worded comments after the customer's latest attachment part."""
    parts = (conv.get("conversation_parts") or {}).get("conversation_parts") or []
    customer = ("user", "lead", "contact")
    filed = max((p.get("created_at") or 0 for p in parts
                 if (p.get("author") or {}).get("type") in customer and (p.get("attachments") or [])), default=0)
    after = [p for p in parts
             if p.get("part_type") == "comment" and (p.get("author") or {}).get("type") in ("admin", "bot")
             and re.sub(r"\s", "", p.get("body") or "") and (p.get("created_at") or 0) > filed]
    return sorted(after, key=lambda p: p.get("created_at") or 0)


def classify(after: list[dict]) -> tuple[str, str]:
    if not after:
        return "no worded comment of ours after the filing", "-"
    first = after[0]
    author = first.get("author") or {}
    who = "caroline" if str(author.get("id")) == CAROLINE else str(author.get("type"))
    if any(THANKS in (p.get("body") or "") for p in after):
        return "answer-bank document_thanks", who
    if NOUN.search(first.get("body") or ""):
        return "first comment carries a document noun", who
    return "first comment carries no document noun", who


def threads() -> None:
    _, listed = latest_list()
    held: dict[str, str] = {}
    for path in checks():
        with open(path, encoding="utf-8") as fh:
            for o in json.load(fh).get("outcomes", []):
                m = HELD.search(str(o.get("reason") or ""))
                if m and str(o.get("user")) in listed:
                    held[str(o.get("user"))] = m.group(2)
    db = sqlite3.connect(f"file:{PROOF}?mode=ro", uri=True)
    filings: dict[str, list[tuple[str, str, set[str]]]] = collections.defaultdict(list)
    for uid, received, label, conv, cands in db.execute(
            "SELECT user_id, received_at, matched_by, conversation_id, candidate_request_ids_json "
            "FROM proof_intake WHERE subject='credit' ORDER BY received_at"):
        ids = set(json.loads(cands or "[]"))
        if label in STRONG and ids and conv:
            filings[str(uid)].append((str(received), str(conv), ids))
    tok = token()
    by_class: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    by_author: collections.Counter = collections.Counter()
    other_thread: collections.Counter = collections.Counter()
    failed = 0
    for user, conv in sorted(held.items()):
        try:
            cls, who = classify(ours_after_filing(conversation(tok, conv)))
        except Exception:  # noqa: BLE001 - a read that fails is counted, never classified
            failed += 1
            continue
        by_class[cohort(listed[user])][cls] += 1
        by_author[who] += 1
        owed = set(listed[user]["request_ids"])
        later = [c for _, c, ids in filings.get(user, []) if ids & owed]
        if later and later[-1] != conv:
            try:
                acknowledged = bool(ours_after_filing(conversation(tok, later[-1])))
            except Exception:  # noqa: BLE001
                other_thread["not read"] += 1
            else:
                other_thread["also acknowledged" if acknowledged else "NO reply of ours"] += 1
        time.sleep(0.2)
    print(f"held r1_receipted_in_thread, on the list: {len(held)}; conversation not read: {failed}")
    for name in sorted(by_class):
        print(name, sum(by_class[name].values()), dict(by_class[name].most_common()))
    print("author of the first comment after the filing:", dict(by_author))
    print("latest filing for a still-owed request sits in another conversation:", sum(other_thread.values()),
          dict(other_thread))


if __name__ == "__main__":
    {"gates": gates, "ledger": ledger, "threads": threads}[sys.argv[1] if len(sys.argv) > 1 else "gates"]()
