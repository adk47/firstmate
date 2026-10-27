#!/usr/bin/env python3
"""READ-ONLY warm-up health check (firstmate 014): for every Intercom-route note sent since --since (ledger rows with
an Intercom contact), read the contact and count hard bounces, spam complaints and unsubscribes.
Exit 0 = healthy, 3 = STOP (bounce > 2%, any spam complaint, or unsubscribes > --unsub-max-pct), 2 = could not check
(fail closed: the caller stops). Prints one JSON line. Needs MUSOAI_INTERCOM_TOKEN (source /etc/openclaw/main.env)."""
import argparse, json, os, sqlite3, sys, time, urllib.request, urllib.error

ap = argparse.ArgumentParser()
ap.add_argument("--since", required=True, help="UTC ISO, e.g. 2026-10-26T20:50")
ap.add_argument("--bounce-max-pct", type=float, default=2.0)
ap.add_argument("--unsub-max-pct", type=float, default=1.0)
ap.add_argument("--spam-baseline", type=int, default=0, help="complaints already present (firstmate 016: today's 1)")
ap.add_argument("--spam-max-pct", type=float, default=0.1)
a = ap.parse_args()
TOKEN = os.environ.get("MUSOAI_INTERCOM_TOKEN", "")
if not TOKEN:
    print(json.dumps({"error": "no MUSOAI_INTERCOM_TOKEN"})); sys.exit(2)
db = sqlite3.connect("file:/var/lib/hydra/credit-review/ledger.sqlite3?mode=ro", uri=True)
cids = sorted({c for (c,) in db.execute(
    "select contact_id from verify_messages where status='sent' and contact_id is not null and coalesce(sent_at, updated_at) >= ?",
    (a.since,))})


def get(cid):
    for t in range(4):
        req = urllib.request.Request(f"https://api.intercom.io/contacts/{cid}", headers={
            "Authorization": f"Bearer {TOKEN}", "Accept": "application/json", "Intercom-Version": "2.11"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            if e.code == 429 or e.code >= 500:
                time.sleep(5 * (t + 1)); continue
            return None
        except Exception:
            time.sleep(5)
    return None


n = bounced = spam = unsub = unread = 0
for cid in cids:
    c = get(cid)
    if c is None:
        unread += 1; continue
    n += 1
    bounced += bool(c.get("has_hard_bounced"))
    spam += bool(c.get("marked_email_as_spam"))
    unsub += bool(c.get("unsubscribed_from_emails"))
pct = lambda x: round(100.0 * x / n, 2) if n else 0.0
out = {"since": a.since, "sent_contacts": len(cids), "read": n, "unreadable": unread, "hard_bounced": bounced,
       "bounce_pct": pct(bounced), "spam_complaints": spam, "spam_pct": pct(spam), "spam_baseline": a.spam_baseline, "unsubscribed": unsub, "unsub_pct": pct(unsub)}
stop = []
if unread:
    # QA on #1384: the unreadable contact may be the one that complained or bounced; the any-complaint
    # stop is only true when EVERY sent contact was read (exit 2 = could not check, the caller stops).
    out["verdict"] = f"UNMEASURED: {unread} of {len(cids)} contact(s) could not be read"
    print(json.dumps(out))
    sys.exit(2)
if pct(bounced) > a.bounce_max_pct:
    stop.append(f"bounce {pct(bounced)}% > {a.bounce_max_pct}%")
if spam > a.spam_baseline:
    stop.append(f"{spam} spam complaint(s) > baseline {a.spam_baseline}")
if pct(spam) > a.spam_max_pct:
    stop.append(f"complaint rate {pct(spam)}% > {a.spam_max_pct}%")
if pct(unsub) > a.unsub_max_pct:
    stop.append(f"unsubscribes {pct(unsub)}% > {a.unsub_max_pct}%")
out["verdict"] = "STOP: " + "; ".join(stop) if stop else "healthy"
print(json.dumps(out))
sys.exit(3 if stop else 0)
