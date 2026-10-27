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
  4. One message per user per UTC day across lanes: no verify-ledger row for the account
     today, and no row in this tool's own sent log for the conversation or the account today.
  5. The body is rendered from fixed text plus server facts only (first name from the core
     replica). Customer text is never copied into a reply.
  6. intercom-ops-write.sh --validate first, then the real post; its POSTED line is the proof.
Closing (--close) is a separate, OFF-by-default step, allowed only for the > 30 d tail, only
after this run's own reply POSTED, and only while CLOSE_APPROVED is 1 (decision D4).

Usage (node-8, root):
  set -a; . /etc/openclaw/main.env; set +a
  python3 send.py <triage.jsonl> --band recent|tail [--ids ID,ID] [--max N] [--apply] [--close]
"""
import argparse
import csv
import datetime as dt
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

COPY_APPROVED = 0          # HELD: captain 23:30Z "no new customer copy"; flip only for wording approved later
COPY_APPROVAL_REF = ""
CLOSE_APPROVED = 0         # Fable D4
APPROVER = "U7RP6HKUZ"     # the captain; the fleet's standing customer-reply approval
OPS_WRITE = "/opt/hydra/scripts/intercom-ops-write.sh"
LEDGER = "/var/lib/hydra/credit-review/ledger.sqlite3"
SENT_LOG = "/var/lib/intercom-backlog-i1/sent.jsonl"
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


def render(row, first_name, line_key):
    # core's firstname often carries the full name: greet with the first word only.
    word = (first_name or "").strip().split(" ")[0] if first_name else ""
    name = word if re.fullmatch(r"[^\W\d_][\w'-]{0,30}", word or "") else "there"
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


def eligible(row):
    """The ONE send-eligible test, for both bands: the row's triage action must be on the
    allowlist (ACTION_LINE). Captain-legal/billing, gate-owned (p2's single sender),
    ledger-today, claim-pending and ambiguous-identity rows are never this tool's to answer."""
    return row.get("action") in ACTION_LINE


def select_rows(rows, band, plan, ids=()):
    """Pure selection; raises Refused instead of silently dropping a planned row, so a plan that
    names a forbidden conversation fails the whole run before anything is read or sent."""
    ids = set(ids)
    if band == "recent":
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
    ap.add_argument("--band", choices=("recent", "tail"), required=True)
    ap.add_argument("--ids", default="")
    ap.add_argument("--max", type=int, default=25)
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--close", action="store_true")
    ap.add_argument("--plan", help="recent band: JSON {conversation_id: line_key} from reading each "
                    "conversation. Required for --band recent; only planned ids are sent.")
    a = ap.parse_args()
    plan = json.load(open(a.plan)) if a.plan else {}
    ids = set(filter(None, a.ids.split(",")))
    rows = select_rows([json.loads(l) for l in open(a.triage)], a.band, plan, ids)
    if a.apply and COPY_APPROVED != 1:
        sys.exit("REFUSED: COPY_APPROVED=0. The copy needs Fable's D1 GO, landed in a PR that flips the lock.")
    if a.close and (CLOSE_APPROVED != 1 or a.band != "tail"):
        sys.exit("REFUSED: --close needs CLOSE_APPROVED=1 (Fable D4) and --band tail.")
    token = os.environ.get("MUSOAI_INTERCOM_TOKEN")
    if not token:
        sys.exit("MUSOAI_INTERCOM_TOKEN not set")
    today = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")
    db = sqlite3.connect(f"file:{LEDGER}?mode=ro", uri=True)
    led_today = {str(x) for (x,) in db.execute(
        "select distinct account_id from verify_messages where day=? and status in ('sent','attempted')", (today,)) if x}
    sent_convs, sent_today = set(), set()
    if os.path.exists(SENT_LOG):
        for l in open(SENT_LOG):
            s = json.loads(l)
            sent_convs.add(s["conversation"])
            if s["day"] == today and s.get("user_id"):
                sent_today.add(s["user_id"])
    uids = sorted({r["user_id"] for r in rows if r.get("user_id")})
    names = {}
    for i in range(0, len(uids), 150):
        for uid, fn in trino("select cast(id as varchar), coalesce(firstname,'') from postgresql_core.public.users "
                             f"where id in ({','.join(uids[i:i + 150])})"):
            names[uid] = fn
    stats = {"sent": 0, "closed": 0, "skipped": {}, "dry": 0, "failed": 0}

    def skip(reason):
        stats["skipped"][reason] = stats["skipped"].get(reason, 0) + 1

    done = 0
    for r in rows:
        if done >= a.max:
            break
        uid = r.get("user_id")
        if not eligible(r):  # defence in depth: select_rows already refused these
            raise Refused(f"{r['id']} action {r.get('action')} is not send-eligible")
        if r["id"] in sent_convs:
            skip("already answered by this lane"); continue
        if uid and (uid in led_today or uid in sent_today):
            skip("user messaged today"); continue
        try:
            ok, why = still_owed(get_conv(token, r["id"]))
        except Exception as e:
            skip("intercom read failed"); continue
        if not ok:
            skip(why); continue
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
            print(f"DRY {r['id']} {r['action']} {r['band']} :: {body}")
            os.unlink(bf); continue
        p = subprocess.run(base, capture_output=True, text=True)
        os.unlink(bf)
        if p.returncode or not p.stdout.startswith("POSTED comment"):
            stats["failed"] += 1
            print(f"FAILED {r['id']}: rc={p.returncode} {p.stderr.strip()[:200]}"); continue
        stats["sent"] += 1
        rec = {"conversation": r["id"], "user_id": uid, "day": today, "action": r["action"],
               "band": r["band"], "posted": p.stdout.strip(), "approval_ref": COPY_APPROVAL_REF,
               "at": dt.datetime.now(dt.timezone.utc).isoformat()}
        fd = os.open(SENT_LOG, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "a") as f:
            f.write(json.dumps(rec) + "\n")
        sent_today.add(uid)
        print(p.stdout.strip())
        time.sleep(0.5)
    print(json.dumps(stats))


if __name__ == "__main__":
    main()
