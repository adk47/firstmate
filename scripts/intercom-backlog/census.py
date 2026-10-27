#!/usr/bin/env python3
"""intercom-backlog census: READ-ONLY inventory of OPEN Intercom conversations where the
customer spoke last (we owe a reply).

Why: the steward scoreboard counts 1,807 customer-last conversations >24h but nothing lists
them by age band and topic, so nobody can say which ones carry a credit/claim status we can
answer from core + the hydra ledger and which are billing/refund/legal for the captain's list.

Runs on node-8 (MUSOAI_INTERCOM_TOKEN from /etc/openclaw/main.env; never printed).
Writes one JSON row per conversation to $OUT_DIR/census-<UTC>.jsonl (0600; holds the
contact email for the identity gate of later steps, VERIFICATION-ONLY) and prints a
masked summary (counts only) on stdout. Never writes to Intercom.

Usage: set -a; . /etc/openclaw/main.env; set +a; python3 census.py [--limit N]
"""
import argparse
import datetime as dt
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

API = "https://api.intercom.io"
VER = "2.11"
OUT_DIR = os.environ.get("INTERCOM_BACKLOG_OUT", "/var/lib/intercom-backlog-i1")
DAY = 86400

# Topic rules: first match wins, ordered so captain-only topics win over credit words
# ("refund my plan, my credits are wrong" is billing first). Legal before billing.
TOPICS = [
    ("legal", r"\b(lawyer|attorney|legal action|cease and desist|c&d|dmca|lawsuit|sue you|court|copyright infringement|takedown notice)\b"),
    ("billing", r"\b(refund|charge[ds]?|charged|billing|invoice|payment|paid twice|cancel(l?ed|lation)?|subscription|renew(al)?|stripe|money back|chargeback|annual plan|pro plan|plaque order|order)\b"),
    ("claim", r"\b(claim(ed|ing)?|verify my profile|profile verification|ownership)\b"),
    ("merge", r"\b(merge|duplicate profile|two profiles|combine)\b"),
    ("credit", r"\b(credits?|credited|split sheet|producer|songwriter|engineer|mix(ing)?|master(ing)?|role|request(ed)? (a )?credit)\b"),
    ("removal", r"\b(remove|delete|take down|not me|wrong person|hide)\b"),
    ("account", r"\b(log ?in|password|sign ?in|email change|account|locked)\b"),
    ("stats", r"\b(streams?|stats|analytics|spotify|chart|numbers)\b"),
]
TOPIC_RE = [(n, re.compile(p, re.I)) for n, p in TOPICS]
TAG_RE = re.compile(r"<[^>]+>")


def search(token, body, attempts=5):
    req = urllib.request.Request(
        f"{API}/conversations/search", data=json.dumps(body).encode(), method="POST",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                 "Content-Type": "application/json", "Intercom-Version": VER})
    for i in range(attempts):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503, 504) and i < attempts - 1:
                time.sleep(2 ** i)
                continue
            raise
        except urllib.error.URLError:
            if i < attempts - 1:
                time.sleep(2 ** i)
                continue
            raise


def topic_of(text):
    for name, rx in TOPIC_RE:
        if rx.search(text):
            return name
    return "other"


def band(age_days):
    if age_days < 1:
        return "lt1d"
    if age_days <= 30:
        return "1-30d"
    return "gt30d"


def mask(email):
    if not email or "@" not in email:
        return ""
    u, d = email.split("@", 1)
    return (u[:2] + "***@" + d) if u else "***@" + d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--since-hours", type=float, default=0,
                    help="only conversations updated in the last N hours (fast sentinel check)")
    a = ap.parse_args()
    token = os.environ.get("MUSOAI_INTERCOM_TOKEN")
    if not token:
        sys.exit("MUSOAI_INTERCOM_TOKEN not set (set -a; . /etc/openclaw/main.env; set +a)")
    now = int(time.time())
    os.makedirs(OUT_DIR, mode=0o700, exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = os.path.join(OUT_DIR, f"census-{stamp}.jsonl")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    out = os.fdopen(fd, "w")
    scanned = 0
    counts = {}
    after = None
    while True:
        query = {"field": "state", "operator": "=", "value": "open"}
        if a.since_hours:
            query = {"operator": "AND", "value": [query, {
                "field": "updated_at", "operator": ">",
                "value": int(now - a.since_hours * 3600)}]}
        body = {"query": query, "pagination": {"per_page": 150}}
        if after:
            body["pagination"]["starting_after"] = after
        data = search(token, body)
        for c in data.get("conversations", []):
            scanned += 1
            st = c.get("statistics") or {}
            lar = st.get("last_admin_reply_at") or 0
            lcr = st.get("last_contact_reply_at") or 0
            src = c.get("source") or {}
            inbound = (src.get("delivered_as") == "customer_initiated") if src.get("delivered_as") \
                else ((src.get("author") or {}).get("type") in ("user", "lead", "contact"))
            # Customer-last: they replied after us, or their inbound first message was never answered.
            if lcr > lar:
                waiting = lcr
            elif lar == 0 and lcr == 0 and inbound:
                waiting = c.get("created_at") or 0
            else:
                continue
            age = (now - waiting) / DAY
            text = TAG_RE.sub(" ", (src.get("subject") or "") + " " + (src.get("body") or ""))
            tags = [t.get("name", "") for t in ((c.get("tags") or {}).get("tags") or [])]
            contacts = (c.get("contacts") or {}).get("contacts") or []
            author = src.get("author") or {}
            row = {
                "id": c.get("id"),
                "waiting_since": waiting,
                "age_days": round(age, 2),
                "band": band(age),
                "admin_assignee_id": c.get("admin_assignee_id"),
                "team_assignee_id": c.get("team_assignee_id"),
                "topic": topic_of(text + " " + " ".join(tags)),
                "tags": tags,
                "contact_id": contacts[0].get("id") if contacts else None,
                "external_id": contacts[0].get("external_id") if contacts else None,
                "email": author.get("email") or "",
                "subject": (src.get("subject") or "")[:200],
                "excerpt": " ".join(text.split())[:400],
                "lar": lar, "lcr": lcr, "created_at": c.get("created_at"),
                "inbound": inbound,
            }
            out.write(json.dumps(row) + "\n")
            k = (row["band"], row["topic"], "team" if row["team_assignee_id"] else "-",
                 "admin" if row["admin_assignee_id"] else "-")
            counts[k] = counts.get(k, 0) + 1
            if a.limit and sum(counts.values()) >= a.limit:
                after = None
                break
        else:
            nxt = (data.get("pages") or {}).get("next")
            after = nxt.get("starting_after") if isinstance(nxt, dict) else None
        if not after:
            break
    out.close()
    by_band, by_topic = {}, {}
    for (b, t, _, _), n in counts.items():
        by_band[b] = by_band.get(b, 0) + n
        by_topic.setdefault(b, {})[t] = by_topic.setdefault(b, {}).get(t, 0) + n
    print(json.dumps({"file": path, "scanned_open": scanned,
                      "customer_last": sum(counts.values()), "by_band": by_band,
                      "by_band_topic": by_topic}, indent=1, sort_keys=True))


if __name__ == "__main__":
    main()
