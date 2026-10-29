#!/usr/bin/env python3
"""intercom-backlog send: answer customer-last conversations with FIXED, Fable-approved copy
(docs/intercom-backlog/report-1026.md section 4), through the one write path the fleet uses,
/opt/hydra/scripts/intercom-ops-write.sh reply. DRY-RUN BY DEFAULT.

Safety, in order, re-checked per conversation right before each send:
  1. COPY_APPROVED below must be 1 (flipped only in a PR that records Fable's GO ref).
  2. The row's action must map to a template (captain-*, gate-*, claim-pending, ledger-today
     and ambiguous identities are never sent by this tool: other owners or the captain).
  3. Live Intercom read: the conversation is still open and the customer still spoke last
     (a teammate, Caroline or a campaign who answered since the census wins: skipped).
  4. One message per user per UTC day across lanes, in the SHARED verify ledger
     (credit_review/verify_ledger.py, campaign backlog-reply, request id conv-<id>): the reply is
     claimed atomically BEFORE the post (verify_ledger.claim: daily cap any campaign, one reply
     per conversation ever) and finalized after it, so every campaign sees it the same day.
  5. The body is rendered from fixed text plus server facts only (first name from the core
     replica). Customer text is never copied into a reply.
  6. intercom-ops-write.sh --validate first, then the real post; its POSTED line is the proof.
Bucket mode (--band bucket --bucket NAME; captain 10-29 "is everyone waiting on us being answered?",
docs/intercom-backlog/unanswered-1029.md): one topic bucket from buckets.py --out per run, answered with that
bucket's line A-I between a fixed opener and closer. Each line is locked on its own (BUCKET_APPROVED, empty =
every line locked) until the captain approves it (D2); only the nine self-serve buckets map to a line, so the
money / legal / privacy / credit-owned / thanks / noise / "other" buckets can never be sent from here.
Closing (--close) is a separate, OFF-by-default step, allowed only for the > 30 d tail, only
after this run's own reply POSTED, and only while CLOSE_APPROVED is 1 (decision D4).

Usage (node-8, root):
  set -a; . /etc/openclaw/main.env; set +a
  python3 send.py <triage.jsonl> --band recent|tail [--ids ID,ID] [--max N] [--apply] [--close]
  python3 send.py <buckets-out.jsonl> --band bucket --bucket stats [--max N] [--apply]
"""
import argparse
import csv
import datetime as dt
import hashlib
import io
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
from credit_review import verify_ledger  # noqa: E402  the shared message ledger
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import overrides  # noqa: E402  the ONE captain-overrides loader (lists.py uses it too)

COPY_APPROVED = 0          # HELD: captain 23:30Z "no new customer copy"; flip only for wording approved later
COPY_APPROVAL_REF = ""
CLOSE_APPROVED = 0         # Fable D4
APPROVER = "U7RP6HKUZ"     # the captain; the fleet's standing customer-reply approval
OPS_WRITE = "/opt/hydra/scripts/intercom-ops-write.sh"
LEDGER = "/var/lib/hydra/credit-review/ledger.sqlite3"
API = "https://api.intercom.io"

OPEN_RECENT = "Hi {name}, thanks for your patience with this."
OPEN_TAIL = "Hi {name}, I'm sorry we didn't get back to you sooner."
CLOSER = "If you still need help with this, just reply here and it will come straight back to our team."
LINES = {
    "credit-none": "Every credit request on your account has now been reviewed, and you can see each credit's status on your profile.",
    "claim-none": "There is no profile claim waiting on your account right now. If you still want to claim a profile, open it on muso.ai and start a claim from there.",
    "merge": "We can merge profiles once every profile involved is claimed, verified and in your workspace. If that is already the case, reply here with the profile links and we will take it from there.",
    "removal": "We remove a credit once Spotify and Tidal no longer list you on that track. If a credit on your profile still looks wrong, reply here with the track and we will check it again.",
    "generic": "We are going through older messages one by one so that nobody is left without an answer.",
}
# ---- bucket mode (unanswered-1029 section 3; captain D2 approves each line on its own) --------------
BUCKET_OPEN = "Hi {name}, sorry for the slow reply."
BUCKET_CLOSER = "If you still need help, just reply here."
BUCKET_LINES = {
    "A": "What can we help you with? Tell us in a few words, and add the link to your Muso profile if it's about your profile.",
    "B": "Analytics show for profiles on an active Pro or Business plan with a seat assigned to the profile. You can check both in Settings. If they're set and your numbers still look wrong, reply with your profile link and the platform.",
    "C": "You can order a plaque on the Muso website at muso.ai/amp/promote/plaque (signed in), or in the Muso mobile app: open the Analytics tab and tap Plaque. If you already ordered, reply with your order ID and we'll look it up.",
    "D": "You can see and change your plan in Settings in your account. Upgrades take effect right away.",
    "E": "You can cancel in Settings. You keep access until the end of the billing period, and your credits and profile stay.",
    "F": "Most answers are in our help center at help.muso.ai. If yours isn't there, reply with your question.",
    "G": "You're talking with our support team here. Tell us what you still need and we'll pick it up from this thread.",
    "H": "You can edit your profile on app.muso.ai. If the name can't be changed there, reply with your profile link and the name you want.",
    "I": "Use 'Forgot password' on the login page, or sign in the way you signed up (Google or Apple). If that doesn't work, reply with the email you use for Muso.",
}
# buckets.py bucket -> line. Anything absent is never sent by bucket mode.
BUCKET_LINE = {"no-detail": "A", "stats": "B", "plaque-order": "C", "subscription": "D", "billing-cancel": "E",
               "howto": "F", "escalation": "G", "profile-edit": "H", "account-access": "I"}
# line -> approval ref (the captain's words). EMPTY = every line locked; a PR adds one entry per approved line.
BUCKET_APPROVED = {}
NEVER_ACTIONS = ("captain-", overrides.HOLD_READ, "gate-", "claim-", "ledger-today")

# triage action -> status line key. Anything absent here is never sent by this tool.
ACTION_LINE = {
    "draft-credit": "credit-none",
    "draft-claim": "generic",       # a no-pending-claim message is often a dispute: no claim advice
    "draft-merge": "merge",
    "draft-removal": "removal",
    "draft-account": "generic",
    "draft-stats": "generic",
    "draft-other": "generic",
    "no-identity": "generic",
}


def first_word(first_name):
    # core's firstname often carries the full name: greet with the first word only.
    word = (first_name or "").strip().split(" ")[0] if first_name else ""
    return word if re.fullmatch(r"[^\W\d_][\w'-]{0,30}", word or "") else "there"


def render_bucket(row, first_name):
    return f"{BUCKET_OPEN.format(name=first_word(first_name))} {BUCKET_LINES[BUCKET_LINE[row['bucket']]]} {BUCKET_CLOSER}"


def render(row, first_name, line_key):
    name = first_word(first_name)
    opener = (OPEN_TAIL if row["band"] == "gt30d" else OPEN_RECENT).format(name=name)
    return f"{opener} {LINES[line_key]} {CLOSER}"


def trino(sql):
    p = subprocess.run(["/opt/hydra/scripts/trino-query.sh"], input=sql, capture_output=True, text=True, timeout=600)
    if p.returncode:
        raise RuntimeError(p.stderr.strip()[:300])
    return list(csv.reader(io.StringIO("\n".join(l for l in p.stdout.splitlines() if l.startswith('"')))))


def get_conv(token, cid):
    req = urllib.request.Request(f"{API}/conversations/{cid}", headers={
        "Authorization": f"Bearer {token}", "Accept": "application/json", "Intercom-Version": "2.11"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def still_owed(c):
    if c.get("state") != "open":
        return False, "not open"
    st = c.get("statistics") or {}
    lar, lcr = st.get("last_admin_reply_at") or 0, st.get("last_contact_reply_at") or 0
    if lar >= lcr and not (lar == 0 and lcr == 0):
        return False, "answered since census"
    return True, ""


class Refused(Exception):
    pass


CAMPAIGN = verify_ledger.BACKLOG_REPLY


def conv_key(conversation_id):
    """The ledger 'request id' of a backlog reply: one reply per conversation, ever."""
    return f"conv-{conversation_id}"


def user_key_of(row, account_email):
    """The ledger's user_key: the account email (what every campaign keys on), else the
    conversation contact's email; lower-cased. '' = cannot be ledgered = never sent."""
    return (account_email or row.get("email") or "").strip().lower()


def ledger_ro(path):
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    return db


def ledger_precheck(db, conversation_id, user_key, user_id, day):
    """Read-only pre-check (dry runs and a cheap skip before the Intercom read). The claim
    below is the authority; this only mirrors it. '' = may send."""
    if verify_ledger.blocked_ids(db, [conv_key(conversation_id)], CAMPAIGN):
        return "already answered (ledger)"
    if verify_ledger.capped(db, user_key=user_key, day=day, user_id=user_id):
        return "user messaged today (ledger)"
    return ""


def ledger_claim(db, conversation_id, user_key, user_id, day, contact_id="", approval_ref=""):
    return verify_ledger.claim(
        db, user_key=user_key, day=day, request_ids=[conv_key(conversation_id)],
        message_type="comment", approved_by=APPROVER,
        approval_ref=approval_ref or COPY_APPROVAL_REF or "unapproved",
        contact_id=contact_id, campaign=CAMPAIGN, user_id=user_id)


def ledger_finalize(db, message_row, conversation_id, rc, stdout, stderr, body):
    """POSTED comment -> sent (with the part id). rc 4 means the post MAY have landed
    (intercom-ops-write.sh: logged, response unverified): it stays 'attempted', which still
    holds the user's day, so nothing re-sends. Any other failure -> rejected (frees the day)."""
    m = re.match(r"POSTED comment conversation=\d+ part=(\S+)", stdout or "")
    sha = hashlib.sha256(body.encode()).hexdigest()
    if rc == 0 and m:
        verify_ledger.finalize(db, message_row=message_row, status="sent", message_id=m.group(1),
                               conversation_id=str(conversation_id), body_sha256=sha)
    elif rc == 4:
        verify_ledger.finalize(db, message_row=message_row, status="attempted",
                               conversation_id=str(conversation_id), body_sha256=sha,
                               reason=f"post unverified: {(stderr or '').strip()[:300]}")
    else:
        verify_ledger.finalize(db, message_row=message_row, status="rejected",
                               conversation_id=str(conversation_id), body_sha256=sha,
                               reason=f"rc={rc}: {(stderr or '').strip()[:300]}")


def eligible(row):
    """The ONE send-eligible test, for both bands: the row's action, AFTER the captain
    overrides are applied (overrides.apply), must be on the allowlist (ACTION_LINE).
    Captain-legal/billing/privacy (keyword or hand-read), hold-read (a hand-read misfire a
    person must read), gate-owned (p2's single sender), ledger-today, claim-pending and
    ambiguous-identity rows are never this tool's to answer."""
    return row.get("action") in ACTION_LINE


def bucket_eligible(row):
    """Bucket mode's send-eligible test, after the captain overrides: the bucket maps to a line, and the
    triage action is not the captain's, a hand-read hold, gate- or claim-owned, or already messaged today."""
    act = str(row.get("action") or "")
    return row.get("bucket") in BUCKET_LINE and not act.startswith(NEVER_ACTIONS)


def row_ok(row, band):
    return bucket_eligible(row) if band == "bucket" else eligible(row)


def select_rows(rows, band, plan, ov, ids=(), bucket=None):
    """Pure selection; raises Refused instead of silently dropping a planned row, so a plan that
    names a forbidden conversation fails the whole run before anything is read or sent. The
    captain overrides (ov, from overrides.load) are applied HERE, so no caller can select rows
    without them."""
    rows = overrides.apply(rows, ov)
    ids = set(ids)
    if band == "bucket":
        if plan:
            raise Refused("--plan applies to the recent band only.")
        if bucket not in BUCKET_LINE:
            raise Refused(f"bucket {bucket!r} has no line; bucket mode sends only {sorted(BUCKET_LINE)}.")
        out = [r for r in rows if r.get("bucket") == bucket and bucket_eligible(r)]
    elif band == "recent":
        if not plan:
            raise Refused("the recent band is answered from a per-conversation --plan (read each), "
                          "never from the keyword topic.")
        bad = {k: v for k, v in plan.items() if v not in LINES}
        if bad:
            raise Refused(f"plan names lines that do not exist: {bad}")
        by_id = {r["id"]: r for r in rows}
        missing = sorted(k for k in plan if k not in by_id)
        if missing:
            raise Refused(f"plan names conversations absent from the triage file: {missing}")
        forbidden = sorted(f"{k}={by_id[k].get('action')}" for k in plan if not eligible(by_id[k]))
        if forbidden:
            raise Refused(f"plan names conversations whose action is not send-eligible: {forbidden}")
        tail = sorted(k for k in plan if by_id[k].get("band") == "gt30d")
        if tail:
            raise Refused(f"plan names > 30 d conversations; use --band tail: {tail}")
        out = [by_id[k] for k in plan]
    else:
        if plan:
            raise Refused("--plan applies to the recent band only.")
        out = [r for r in rows if eligible(r) and r.get("band") == "gt30d"]
    out = [r for r in out if not ids or r["id"] in ids]
    out.sort(key=lambda r: (not r.get("paid"), r["waiting_since"]))
    return out


def main():
    try:
        _main()
    except Refused as e:
        sys.exit(f"REFUSED: {e}")


def _main():
    ap = argparse.ArgumentParser()
    ap.add_argument("triage")
    ap.add_argument("--band", choices=("recent", "tail", "bucket"), required=True)
    ap.add_argument("--bucket", help="bucket mode: the one buckets.py bucket this run answers")
    ap.add_argument("--ids", default="")
    ap.add_argument("--max", type=int, default=25)
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--close", action="store_true")
    ap.add_argument("--overrides", default=overrides.DEFAULT_PATH)
    ap.add_argument("--plan", help="recent band: JSON {conversation_id: line_key} from reading each "
                    "conversation. Required for --band recent; only planned ids are sent.")
    a = ap.parse_args()
    plan = json.load(open(a.plan)) if a.plan else {}
    ids = set(filter(None, a.ids.split(",")))
    try:
        ov = overrides.load(a.overrides)
    except overrides.OverridesError as e:
        raise Refused(str(e))
    rows = select_rows([json.loads(l) for l in open(a.triage)], a.band, plan, ov, ids, bucket=a.bucket)
    approval_ref = ""
    if a.band == "bucket":
        line = BUCKET_LINE[a.bucket]
        approval_ref = BUCKET_APPROVED.get(line, "")
        if a.apply and not approval_ref:
            sys.exit(f"REFUSED: line {line} ({a.bucket}) is not approved (BUCKET_APPROVED has no entry). "
                     "It needs the captain's yes, landed in a PR that adds the line's approval ref.")
        if a.close:
            sys.exit("REFUSED: bucket mode never closes.")
    elif a.apply and COPY_APPROVED != 1:
        sys.exit("REFUSED: COPY_APPROVED=0. The copy needs Fable's D1 GO, landed in a PR that flips the lock.")
    if a.close and (CLOSE_APPROVED != 1 or a.band != "tail"):
        sys.exit("REFUSED: --close needs CLOSE_APPROVED=1 (Fable D4) and --band tail.")
    token = os.environ.get("MUSOAI_INTERCOM_TOKEN")
    if not token:
        sys.exit("MUSOAI_INTERCOM_TOKEN not set")
    today = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")
    uids = sorted({r["user_id"] for r in rows if r.get("user_id")})
    names, emails = {}, {}
    for i in range(0, len(uids), 150):
        for uid, fn, em in trino("select cast(id as varchar), coalesce(firstname,''), coalesce(email,'') "
                                 f"from postgresql_core.public.users where id in ({','.join(uids[i:i + 150])})"):
            names[uid], emails[uid] = fn, em
    # Dry runs only READ the shared ledger; apply opens it read-write (claim + finalize).
    db = verify_ledger.connect(LEDGER) if a.apply else ledger_ro(LEDGER)
    stats = {"sent": 0, "closed": 0, "skipped": {}, "dry": 0, "failed": 0}

    def skip(reason):
        stats["skipped"][reason] = stats["skipped"].get(reason, 0) + 1

    done = 0
    for r in rows:
        if done >= a.max:
            break
        uid = r.get("user_id")
        if not row_ok(r, a.band):  # defence in depth: select_rows already refused these
            raise Refused(f"{r['id']} action {r.get('action')} is not send-eligible")
        key = user_key_of(r, emails.get(uid or "", ""))
        if not key:
            skip("no email to key the shared ledger on"); continue
        pre = ledger_precheck(db, r["id"], key, uid or "", today)
        if pre:
            skip(pre); continue
        try:
            ok, why = still_owed(get_conv(token, r["id"]))
        except Exception:
            skip("intercom read failed"); continue
        if not ok:
            skip(why); continue
        if a.band == "bucket":
            body = render_bucket(r, names.get(uid or "", ""))
        else:
            body = render(r, names.get(uid or "", ""), plan.get(r["id"]) or ACTION_LINE[r["action"]])
        with tempfile.NamedTemporaryFile("w", delete=False, suffix=".txt") as f:
            f.write(body)
            bf = f.name
        base = [OPS_WRITE, "reply", "--conversation", r["id"], "--requested-by", APPROVER,
                "--customer-facing", "--approved-by", APPROVER, "--body-file", bf]
        v = subprocess.run(base + ["--validate"], capture_output=True, text=True)
        if v.returncode:
            os.unlink(bf); stats["failed"] += 1
            print(f"REFUSED {r['id']}: {v.stderr.strip()[:200]}"); continue
        done += 1
        if not a.apply:
            stats["dry"] += 1
            print(f"DRY {r['id']} {r.get('bucket') or r['action']} {r['band']} :: {body}")
            os.unlink(bf); continue
        # Claim BEFORE the post, atomically: the shared one-message-per-user-per-UTC-day cap and
        # one reply per conversation are decided by verify_ledger.claim, the same code every
        # campaign uses, so two lanes can never both message this user today.
        c = ledger_claim(db, r["id"], key, uid or "", today, r.get("contact_id") or "", approval_ref)
        if c["result"] != "claimed":
            os.unlink(bf); skip(f"ledger: {c['result']}"); continue
        p = subprocess.run(base, capture_output=True, text=True)
        os.unlink(bf)
        posted = p.returncode == 0 and p.stdout.startswith("POSTED comment")
        ledger_finalize(db, c["message_row"], r["id"], p.returncode, p.stdout, p.stderr, body)
        if not posted:
            stats["failed"] += 1
            print(f"FAILED {r['id']}: rc={p.returncode} {p.stderr.strip()[:200]}"); continue
        stats["sent"] += 1
        print(p.stdout.strip())
        time.sleep(0.5)
    print(json.dumps(stats))


if __name__ == "__main__":
    main()
