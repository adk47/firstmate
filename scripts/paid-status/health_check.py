#!/usr/bin/env python3
"""READ-ONLY warm-up health check (firstmate 014): for every Intercom-route note sent since --since (ledger rows with
an Intercom contact), read the contact and count hard bounces, spam complaints and unsubscribes.
Exit 0 = healthy, 3 = STOP (bounce > 2%, any spam complaint, or unsubscribes > --unsub-max-pct), 2 = could not check
(fail closed: the caller stops). Prints one JSON line. Needs MUSOAI_INTERCOM_TOKEN (source /etc/openclaw/main.env).

THE BOUNCE RATE NEEDS A FLOOR, AND THE FLOOR IS TWO BOUNCES (2026-11-06). The denominator here is the contacts THIS
run sent to and could read back, and the caller passes a per-tick --since window, so n is small by construction: the
14:00Z tick sent 9 and read 9. One hard bounce in that sample is 1/9 = 11.11 %, which is over the 2 % threshold, so
the gate stopped the run and wrote the kill file - and the whole outbound pipeline was dead until a human lifted it.
The arithmetic was right and the conclusion was wrong: a 2 % threshold on a denominator of 9 has no resolution, since
the smallest non-zero rate it can express is 11.11 % and the smallest rate it can call healthy is 0 %. A RATE is a
statement about a population, and one bounce is never a rate.

So the rate is evaluated only once --bounce-min-bounces contacts have bounced (default 2). Below that the bounce is
still COUNTED and REPORTED (out["bounce_held"]) - it is never hidden - but it does not stop the run. The threshold
itself is unchanged at 2 %: the missing thing was the floor, not the number.

Why a bounce count and not a denominator floor (n >= 50 before the rate is evaluated): a denominator floor needs the
caller to carry the un-evaluated bounces into the next run's window, which is cross-tick state this read-only script
does not have and cannot verify. A bounce count needs no state and says the thing we mean. The cost is the slow-bleed
case - a list that bounces exactly one address per small tick never trips this gate - and the answer to that is a
cumulative --since window at the caller, not a lower floor here.

THE FLOOR IS NOT DERIVED FROM THE 2 % BAR, AND THAT IS DELIBERATE (firstmate 035). A denominator floor WOULD be
derived: for a rate bar of p, the smallest sample that can express a rate below p is n >= 1/p, so 2 % implies n >= 50
and 5 % would imply n >= 20 - change the bar and the floor silently desynchronises from it. A count floor is a
statement about the numerator instead ("one bounce is never a rate") and is invariant under any bar: at 2 % it holds
one bounce back, at 5 % it still holds one bounce back, and the bar keeps doing the only job it should. The two are
not independent, though, and the relationship is worth stating so a future change is reasoned about rather than
copied: with a floor of k bounces the gate can first fire at n = k, i.e. at a rate of 100 %, and it fires at the bar
for any n >= k/p. So raising the bar never makes the floor wrong; it only moves the sample size at which the bar
starts to bind. If the bar is ever lowered far enough that a single bounce should stop a run, the floor is the thing
to revisit - not the bar.

THE UNSUBSCRIBE RATE HAD THE IDENTICAL DEFECT and gets the identical floor (--unsub-min-unsubs, default 2): 1 %
against a denominator of 9 means one unsubscribe (11.11 %) killed the pipeline. It is safe to hold one because the
user is already unsubscribed in Intercom - the run continuing costs them nothing - and because a single unsubscribe
is a fact about one person, not a rate. The SPAM gate is deliberately NOT given a floor: it is a COUNT rule
(spam > --spam-baseline, default 0), so one complaint above baseline stops the run by design, and a count needs no
population. The refusal-spike gate in credit-verify-outbound.sh already had this floor (n >= 10); the bounce and
unsubscribe gates were the two that did not."""
import argparse, json, os, sqlite3, sys, time, urllib.request, urllib.error

ap = argparse.ArgumentParser()
ap.add_argument("--since", required=True, help="UTC ISO, e.g. 2026-10-26T20:50")
ap.add_argument("--bounce-max-pct", type=float, default=2.0)
ap.add_argument("--bounce-min-bounces", type=int, default=2,
                help="evaluate the bounce RATE only once this many contacts have bounced (default 2): one bounce in "
                     "any sample is not a rate. Below it the bounce is counted and reported, never hidden")
ap.add_argument("--unsub-max-pct", type=float, default=1.0)
ap.add_argument("--unsub-min-unsubs", type=int, default=2,
                help="evaluate the unsubscribe RATE only once this many contacts have unsubscribed (default 2): the "
                     "same floor as the bounce gate, for the same reason. Below it the unsubscribe is counted and "
                     "reported, never hidden")
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
if bounced >= a.bounce_min_bounces and pct(bounced) > a.bounce_max_pct:
    # the sample size rides in the message: the next person to read the kill file must be able to see at a glance
    # whether the gate fired on a population or on a handful (2026-11-06: it fired on 1 of 9)
    stop.append(f"bounce {pct(bounced)}% > {a.bounce_max_pct}% ({bounced} of {n} read)")
elif bounced and pct(bounced) > a.bounce_max_pct:
    # over the threshold but under the floor: counted, reported, not a stop
    out["bounce_held"] = (f"{bounced} of {n} read = {pct(bounced)}% > {a.bounce_max_pct}%, held: "
                          f"a rate needs {a.bounce_min_bounces} bounces")
if spam > a.spam_baseline:
    stop.append(f"{spam} spam complaint(s) > baseline {a.spam_baseline}")
if pct(spam) > a.spam_max_pct:
    stop.append(f"complaint rate {pct(spam)}% > {a.spam_max_pct}%")
if unsub >= a.unsub_min_unsubs and pct(unsub) > a.unsub_max_pct:
    stop.append(f"unsubscribes {pct(unsub)}% > {a.unsub_max_pct}% ({unsub} of {n} read)")
elif unsub and pct(unsub) > a.unsub_max_pct:
    # Same floor, same reason as the bounce gate: 1 unsubscribe in 9 is 11.11 % against a 1 % threshold, and the
    # user is already unsubscribed in Intercom, so the pipeline continuing costs them nothing. Counted, reported.
    out["unsub_held"] = (f"{unsub} of {n} read = {pct(unsub)}% > {a.unsub_max_pct}%, held: "
                         f"a rate needs {a.unsub_min_unsubs} unsubscribes")
out["verdict"] = "STOP: " + "; ".join(stop) if stop else "healthy"
print(json.dumps(out))
sys.exit(3 if stop else 0)
