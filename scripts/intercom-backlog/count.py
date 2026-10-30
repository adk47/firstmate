#!/usr/bin/env python3
"""The > 48 h customer-last conversation count, every 2 h, for the `comms:` line (Fable order
[key=unattended], data/verify-program-lead-fable-l1/unattended-1030.md section 3).

READ-ONLY and PII-free. One Intercom search over OPEN conversations (census.py's rule: the customer
spoke last, or their inbound first message was never answered), then, for those waiting more than
--min-hours, the customer's last messages are read in-process (buckets.py) to pick a topic bucket.
Nothing is written to Intercom, core or any ledger; no text is stored. Output:
  /var/lib/intercom-backlog-i1/backlog-count.json          latest (atomic replace)
  /var/lib/intercom-backlog-i1/backlog-count-history.jsonl  one line per run
and one `backlog:` line on stdout.

credit/claim/merge = the first message's topic (census.topic_of) is credit / claim / merge, OR the last
message's bucket is credit-like / merge-like / removal-like (the families verify-program-lead-fable-l1
drains via reply_due; the removal-like are c3's). Everything else is counted by bucket.

Usage (node-8): set -a; . /etc/openclaw/main.env; set +a; python3 count.py [--min-hours 48]
"""
import argparse
import collections
import datetime as dt
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import buckets  # noqa: E402
import census  # noqa: E402

OUT_DIR = os.environ.get("INTERCOM_BACKLOG_OUT", "/var/lib/intercom-backlog-i1")
CREDIT_TOPICS = ("credit", "claim", "merge")
CREDIT_BUCKETS = ("credit-like", "merge-like", "removal-like")


def waiting(c, now):
    """(waiting_since, first-message text) for a customer-last open conversation, else None."""
    st = c.get("statistics") or {}
    lar, lcr = st.get("last_admin_reply_at") or 0, st.get("last_contact_reply_at") or 0
    src = c.get("source") or {}
    inbound = (src.get("delivered_as") == "customer_initiated") if src.get("delivered_as") \
        else ((src.get("author") or {}).get("type") in ("user", "lead", "contact"))
    if lcr > lar:
        ws = lcr
    elif lar == 0 and lcr == 0 and inbound:
        ws = c.get("created_at") or 0
    else:
        return None
    tags = [t.get("name", "") for t in ((c.get("tags") or {}).get("tags") or [])]
    text = census.TAG_RE.sub(" ", (src.get("subject") or "") + " " + (src.get("body") or ""))
    return ws, text + " " + " ".join(t for t in tags if t not in census.NEUTRAL_TAGS)


def classify(first_topic, last_bucket):
    """Pure: the comms family of one conversation."""
    if first_topic in CREDIT_TOPICS or last_bucket in CREDIT_BUCKETS:
        return "credit-claim-merge"
    return last_bucket


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--min-hours", type=float, default=48)
    a = ap.parse_args()
    token = os.environ.get("MUSOAI_INTERCOM_TOKEN")
    if not token:
        sys.exit("MUSOAI_INTERCOM_TOKEN not set (set -a; . /etc/openclaw/main.env; set +a)")
    now = time.time()
    open_n, owed = 0, []
    after = None
    while True:
        body = {"query": {"field": "state", "operator": "=", "value": "open"}, "pagination": {"per_page": 150}}
        if after:
            body["pagination"]["starting_after"] = after
        data = census.search(token, body)
        for c in data.get("conversations", []):
            open_n += 1
            w = waiting(c, now)
            if w and (now - w[0]) / 3600 >= a.min_hours:
                owed.append((c["id"], w[0], census.topic_of(w[1])))
        nxt = (data.get("pages") or {}).get("next")
        after = nxt.get("starting_after") if isinstance(nxt, dict) else None
        if not after:
            break
    todo = [cid for cid, _, t in owed if t not in CREDIT_TOPICS]
    last = {}
    with ThreadPoolExecutor(max_workers=6) as ex:
        for cid, got in zip(todo, ex.map(lambda c: buckets.customer_text(token, c), todo)):
            last[cid] = buckets.bucket_of(got[1], got[0]) if got else "unread"
    fam = collections.Counter(classify(t, last.get(cid)) for cid, _, t in owed)
    ages = sorted((now - ws) / 86400 for _, ws, _ in owed)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    doc = {"at": stamp, "min_hours": a.min_hours, "open": open_n, "owed_gt": len(owed),
           "credit_claim_merge": fam.get("credit-claim-merge", 0),
           "other_topics": len(owed) - fam.get("credit-claim-merge", 0),
           "le30d": sum(1 for x in ages if x <= 30), "oldest_days": round(ages[-1]) if ages else 0,
           "by_bucket": dict(sorted(fam.items(), key=lambda kv: -kv[1]))}
    os.makedirs(OUT_DIR, mode=0o755, exist_ok=True)
    tmp = os.path.join(OUT_DIR, ".backlog-count.json.tmp")
    with open(tmp, "w") as f:
        json.dump(doc, f, indent=1)
    os.replace(tmp, os.path.join(OUT_DIR, "backlog-count.json"))
    with open(os.path.join(OUT_DIR, "backlog-count-history.jsonl"), "a") as f:
        f.write(json.dumps(doc) + "\n")
    print(f"backlog {stamp}: customer-last > {a.min_hours:g} h {doc['owed_gt']} (credit/claim/merge "
          f"{doc['credit_claim_merge']}, other topics {doc['other_topics']}; <= 30 d {doc['le30d']}, "
          f"oldest {doc['oldest_days']} d) of {open_n} open")
    return 0


if __name__ == "__main__":
    sys.exit(main())
