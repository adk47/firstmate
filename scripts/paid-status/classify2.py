#!/usr/bin/env python3
"""DRY RUN ONLY (firstmate 131): ONE batched templated status note per user with old pending
credits and no communication. Nothing is sent from here: the output is reviewed by firstmate,
then sent (if approved) through Caroline's gate behind its send-lock.

Input: any file holding the user ids (cmux-credit-system-lane pending-no-comms list: md/tsv/json;
every `user_id`/`userId`/`uid` number, or a first-column integer, is taken).

Per user (read-only: core replica via Trino, /var/lib/credit-trust/proof-on-file.json):
  SKIP_SUPPORT  emailed support@ in the last 90 days            -> no note (held for a human)
  Captain 2026-10-27 12:55Z (item 5): never "nothing else is needed" to anyone who still owes proof. A user with
  ANY user_verification_needed row owes proof, so A_DOC and B_TEAM (both say no more is needed) are only for
  users with NO such row:
  A_DOC         no UVN row, and a document of theirs awaits review -> Copy A (approved, firstmate 103)
  B_TEAM        no UVN row (pending/processing/unverified = waiting on us) -> Copy B0 = Copy B WITHOUT the
                                                                     optional proof line (no ask)
  HOLD_OWES     UVN rows, and documented / a document pending / asked in 90 days: owes proof but must not be
                asked again now -> no note (counted, not listed)
  UVN_ASK       undocumented, rows user_verification_needed, not
                asked in 90 days                                  -> UVN reminder copy, section A
                                                                     (approved, firstmate 088)
Paid first, then oldest pending first. Up to 3 titles, then "and N more". No dates, no removal
language, no em dashes.

Run on node-8:  python3 build.py --users <list file> [--out-dir DIR]
"""
import argparse
import collections
import csv
import io
import json
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

TRINO = "/opt/hydra/scripts/trino-query.sh"
PROOF = "/var/lib/credit-trust/proof-on-file.json"
PAYING = "/var/lib/credit-trust/paying-users.json"

COPY = {
    "A_DOC": ("Your Muso credit request: we have your document",
              "Hi {first}, a quick update on your credit request(s) for {titles}: we have the document you sent us, "
              "and our team is reviewing it. Nothing else is needed from you right now, and you'll see each credit on "
              "your profile as soon as it's approved.\n\nMuso Support"),
    "B_TEAM": ("Your Muso credit request: with our team",
               "Hi {first}, a quick update on your credit request(s) for {titles}: they're with our team for review. "
               "Nothing else is needed from you right now.\n\nMuso Support"),
    "UVN_ASK": ("Your Muso credit request{s}: one thing we still need",
                "Hi {first}, a quick status update on your credit request{s} for {titles}: {it_s} waiting on one thing "
                "from you, something that shows your {role_phrase}.\n\nAny one of these works (a link, photo or PDF is fine):\n"
                "- A public link where the credit is listed: Tidal, Genius, Discogs, AllMusic, ASCAP or BMI.\n"
                "- Documentation of the work: a project or session file, a message with the artist, a contract or "
                "split sheet, or anything else that shows you worked on it.\n\nJust reply to this message with it. "
                "You will see {each_credit} on your profile as soon as it is approved, and we will let you know here if "
                "anything else is needed.\n\nThank you,\nCaroline\n"
                "Muso Support"),
}


def trino(sql: str) -> list[list[str]]:
    p = subprocess.run([TRINO], input=sql, capture_output=True, text=True, timeout=900)
    if p.returncode != 0:
        sys.exit(f"replica query failed: {p.stderr[-300:]}")
    return list(csv.reader(io.StringIO("\n".join(l for l in p.stdout.splitlines() if l.startswith('"')))))


def user_ids(path: str) -> list[int]:
    text = Path(path).read_text(encoding="utf-8")
    ids = [int(m) for m in re.findall(r'(?:user_?id|userId|uid)["\'\s:=|]+(\d{1,9})', text, re.I)]
    if not ids:
        for line in text.splitlines():
            m = re.match(r"\s*\|?\s*(\d{1,9})\b", line)
            if m:
                ids.append(int(m.group(1)))
    return list(dict.fromkeys(ids))


def titles_of(rows: list[dict]) -> str:
    t = list(dict.fromkeys(f'"{r["title"]}"' for r in rows if r["title"]))
    if len(t) <= 1:
        return t[0] if t else "your credits"
    head = t[:3]
    more = len(t) - len(head)
    s = ", ".join(head[:-1]) + f" and {head[-1]}" if not more else ", ".join(head)
    return s + (f" (and {more} more)" if more else "")


def classify(rs: list[dict], *, documented: bool, pending_doc: bool, cutoff: str) -> str:
    """The note class for a user's pending rows `rs` (module doc). A user with any user_verification_needed
    row owes proof: never A_DOC / B_TEAM (they say nothing more is needed; captain 2026-10-27 12:55Z)."""
    asked_90d = any(r["asked"] and r["asked"] >= cutoff for r in rs)
    uvn = [r for r in rs if r["status"] == "user_verification_needed"]
    if uvn:
        return "HOLD_OWES" if (documented or pending_doc or asked_90d) else "UVN_ASK"
    return "A_DOC" if pending_doc else "B_TEAM"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--users", required=True)
    ap.add_argument("--out-dir", default=str(Path(__file__).resolve().parent))
    a = ap.parse_args()
    ids = user_ids(a.users)
    if not ids:
        sys.exit("no user ids found in the list")
    now = datetime.now(timezone.utc)
    proof = json.load(open(PROOF))
    pof_users = {e["user_id"] for e in proof["entries"]}
    pending_doc_users = {e["user_id"] for e in proof["entries"] if e.get("kind") == "pending_doc"}
    pof_requests = {str(e["request_id"]).lower() for e in proof["entries"] if e.get("request_id")}
    support = {int(x) for x in open(__import__("os").environ["PWR_DIR"] + "/support-held-17.txt").read().split()}  # p2: only support@ threads a human answered in 7 days (firstmate 004)
    paying = set(json.load(open(PAYING)).get("ids") or [])
    rows: dict[int, list[dict]] = collections.defaultdict(list)
    users: dict[int, dict] = {}
    for i in range(0, len(ids), 500):
        chunk = ",".join(map(str, ids[i:i + 500]))
        for rid, uid, status, title, created, asked, artist, roles in trino(
                "SELECT CAST(c.id AS varchar), CAST(c.userid AS varchar), c.status, coalesce(c.spotifytracktitle, ''), "
                "CAST(c.createdat AS varchar), coalesce(json_extract_scalar(c.metadata, '$.proofRequest.noticeSentAt'), ''), "
                "coalesce(json_extract_scalar(CAST(c.spotifytrackartists AS json), '$[0].name'), ''), "
                "coalesce(CAST(c.credits AS varchar), '') "
                "FROM postgresql_core.public.credit_requests c WHERE c.deletedat IS NULL "
                f"AND c.status IN ('pending', 'processing', 'unverified', 'user_verification_needed') AND c.userid IN ({chunk})"):
            # Postgres text[] literal: {Mixing,"Background Vocals"}
            inner = roles.strip()[1:-1] if roles.strip().startswith("{") else roles
            role = [r.strip() for r in next(csv.reader([inner]), []) if r.strip()] if inner else []
            rows[int(uid)].append({"id": rid, "status": status, "title": title, "created": created, "asked": asked,
                                   "artist": artist,
                                   "role": (role[0] if len(role) == 1 else ", ".join(role[:-1]) + " and " + role[-1]) if role else ""})
        for uid, first, email_ok in trino(
                "SELECT CAST(id AS varchar), coalesce(split_part(trim(fullname), ' ', 1), ''), "
                "CAST(email IS NOT NULL AS varchar) FROM postgresql_core.public.users "
                f"WHERE id IN ({chunk})"):
            users[int(uid)] = {"first": first, "email": email_ok == "true"}
    cutoff = (now - timedelta(days=90)).isoformat()
    out, counts = [], collections.Counter()
    for uid in ids:
        rs = sorted(rows.get(uid, []), key=lambda r: r["created"])
        u = users.get(uid, {})
        if not rs:
            counts["skip: nothing pending now"] += 1
            continue
        if not u.get("email"):
            counts["skip: no account email"] += 1
            continue
        if uid in support:
            counts["skip: emailed support in 90 days (human)"] += 1
            continue
        cls = classify(rs, documented=uid in pof_users or any(r["id"].lower() in pof_requests for r in rs),
                       pending_doc=uid in pending_doc_users or any(r["id"].lower() in pof_requests for r in rs),
                       cutoff=cutoff)
        if cls == "HOLD_OWES":
            counts["hold: owes proof (UVN rows), documented or asked in 90 days: no note"] += 1
            continue
        target = [r for r in rs if r["status"] == "user_verification_needed"] if cls == "UVN_ASK" else rs
        many = len({r["title"] for r in target}) > 1
        subj, body = COPY[cls]
        first = (u.get("first") or "").strip() or "there"
        titles = titles_of(target)
        role_phrase = "role on each"
        if cls == "UVN_ASK" and not many:
            # The approved single-credit wording (firstmate 088): "{title}" by {artist} ... your {role} credit.
            r0 = target[0]
            titles = f'"{r0["title"]}"' + (f' by {r0["artist"]}' if r0["artist"] else "")
            role_phrase = f'{r0["role"]} credit' if r0["role"] else "credit"
        fmt = {"first": first, "titles": titles, "s": "s" if many else "",
               "it_s": "they're" if many else "it's", "decided": "they're decided" if many else "it's decided",
               "each_credit": "each credit" if many else "the credit",
               "role_phrase": role_phrase}
        out.append({"user_id": uid, "paid": uid in paying, "class": cls, "oldest_pending": rs[0]["created"][:10],
                    "n_pending": len(rs), "n_in_note": len(target), "request_ids": [r["id"] for r in target],
                    "subject": subj.format(**fmt), "body": body.format(**fmt)})
        counts[f"note: {cls}"] += 1
    out.sort(key=lambda o: (not o["paid"], o["oldest_pending"]))
    od = Path(a.out_dir)
    stamp = now.strftime("%Y%m%dT%H%MZ")
    (od / f"dry-run-{stamp}.json").write_text(json.dumps(out, indent=1))
    by = collections.Counter((o["class"], o["paid"]) for o in out)
    summary = {"generated_at": now.isoformat(timespec="seconds"), "input": a.users, "users_in_list": len(ids),
               "counts": dict(counts), "notes_by_class_paid": {f"{k[0]}|{'paid' if k[1] else 'free'}": v for k, v in by.items()}}
    (od / f"summary-{stamp}.json").write_text(json.dumps(summary, indent=1))
    lines = [f"# Sample notes ({stamp}, DRY RUN, nothing sent)\n"]
    for cls in ("A_DOC", "B_TEAM", "UVN_ASK"):
        for o in [x for x in out if x["class"] == cls][:3]:
            # Samples leave node-8: the first name is shown as a placeholder (ids only off-host).
            body = o["body"].replace(f"Hi {users.get(o['user_id'], {}).get('first') or 'there'},", "Hi <first name>,", 1)
            lines += [f"## {cls} | user {o['user_id']} | {'paid' if o['paid'] else 'free'} | oldest {o['oldest_pending']}",
                      f"**Subject:** {o['subject']}", "", body, ""]
    (od / f"samples-{stamp}.md").write_text("\n".join(lines))
    print(json.dumps(summary, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
