#!/usr/bin/env python3
"""Gmail (support@muso.ai) part of the proof-on-file feed (firstmate 762). READ-ONLY on Gmail and core.

Runs on node-8 from scripts/cs-proof-feed.sh (moved off the captain's Mac 2026-10-26, ops-to-ovh-m1;
originally cs-systemic-issues-lane-c1 scripts/cs-systemic/gmail-proof.py). The only changes from the
Mac version: the scan runs locally instead of over `ssh node-1 -> node-8`, and the sender -> user id
join goes through the Trino postgresql_core passthrough (replica.py) instead of psql on node-1.

The scan (gmail_scan.sh: `gog gmail messages search`, 100 per page, 20 s between pages, backoff on
rate limits) writes result pages to GMAIL_DIR. This script reads them, maps each sender to a core
user id (lower(email) on the read-only replica) and maintains, in OUT:

  gmail-proof.jsonl     one row per inbound message WITH an attachment: {msg, thread, created, user_id}
                        (an attachment from the customer = a document they sent; over-includes, like
                        the Intercom part)
  gmail-contacts.json   {msg_id: {"date": ..., "user_id": ...}} for every inbound message, pruned to 90 days
                        (who emailed support@ recently; consumers treat these users as UNKNOWN while
                        the gmail part is missing or stale)
  gmail-state.json      {"full_done_at": ..., "last_success_at": ..., "late_reg_checked_at": ...}
  gmail-unmapped.json   {msg_id: {"kind": "att"|"c90", "thread", "created", "sender": HMAC}} for messages whose
                        sender had NO Muso account when seen (QA #1391: a customer can mail proof first and
                        sign up later). Each run re-resolves them against accounts created since the last
                        check; a hit moves the message into gmail-proof.jsonl / gmail-contacts.json. The
                        sender is stored only as HMAC-SHA256 under a node-local key (.sender-hmac-key, 0600),
                        never as an address.

Modes:
  --full         ingest the pages of a completed full scan (prefixes att / c90p)
  --incremental  scan back to the last successful run (+1 day, at least 2 days; prefixes atti / c90i) and merge it
Emails are used only in memory for the join; the files hold ids only.
"""
import datetime as dt
import email.utils
import glob
import hashlib
import hmac
import json
import math
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import replica  # noqa: E402

GMAIL_DIR = os.environ.get("CS_PROOF_GMAIL_DIR", "/var/lib/hydra/cs-proof-feed/gmail")
SCAN = os.environ.get("CS_PROOF_GMAIL_SCAN", os.path.join(HERE, "gmail_scan.sh"))
EXCL = "-from:muso.ai -from:intercom.io -from:intercom-mail.com -from:mailer-daemon -from:postmaster -label:spam"
iso = lambda d: d.strftime("%Y-%m-%dT%H:%M:%SZ")  # noqa: E731


def scan(prefix, query, run=subprocess.run):
    return run(["bash", SCAN, prefix, query], capture_output=True, text=True, timeout=1500)


def pull(prefix, gdir=None):
    """Concatenate the pages for a prefix; refuses if that scan did not finish."""
    gdir = gdir or GMAIL_DIR
    log = os.path.join(gdir, f"{prefix}.log")
    try:
        lines = [l for l in open(log).read().splitlines() if l.strip()]
    except OSError:
        lines = []
    if not lines or "DONE" not in lines[-1]:
        raise SystemExit(f"scan '{prefix}' is not complete (or unreadable); nothing ingested")
    msgs = []
    for f in sorted(glob.glob(os.path.join(gdir, f"{prefix}-*.json"))):
        try:
            page = json.load(open(f))
        except (OSError, ValueError):
            page = None
        # Second line of defence behind gmail_scan.sh: every page must be a real result page.
        if not isinstance(page, dict) or not isinstance(page.get("messages"), list):
            raise SystemExit(f"scan '{prefix}' has a page that is not a result page ({os.path.basename(f)}); nothing ingested")
        msgs += page["messages"]
    return msgs


def addr(m):
    return email.utils.parseaddr(m.get("from") or "")[1].strip().lower()


def mdate(m):
    try:
        return dt.datetime.strptime(m["date"], "%Y-%m-%d %H:%M").replace(tzinfo=dt.timezone.utc)
    except Exception:
        return None


def hmac_key(out):
    p = os.path.join(out, ".sender-hmac-key")
    if not os.path.exists(p):
        fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as fh:
            fh.write(os.urandom(32))
    return open(p, "rb").read()


def sender_hmac(key, address):
    return hmac.new(key, address.encode(), hashlib.sha256).hexdigest()


def keep_unmapped(unmapped, msgs, kind, umap, key):
    for m in msgs:
        a = addr(m)
        if a and not umap.get(a) and m.get("id"):
            unmapped.setdefault(m["id"], {"kind": kind, "thread": m.get("threadId"), "created": m.get("date"),
                                          "sender": sender_hmac(key, a)})


def attribute_late(unmapped, new_users, key, proof, contacts):
    """Messages whose sender has since registered -> proof/contacts. Returns the number attributed."""
    by_h = {sender_hmac(key, e): uid for e, uid in new_users.items() if e}
    n = 0
    for mid, u in list(unmapped.items()):
        uid = by_h.get(u.get("sender"))
        if not uid:
            continue
        if u.get("kind") == "att":
            proof.setdefault(mid, {"msg": mid, "thread": u.get("thread"), "created": u.get("created"), "user_id": uid})
        else:
            contacts.setdefault(mid, {"date": u.get("created"), "user_id": uid})
        del unmapped[mid]
        n += 1
    return n


def merge(out, att, c90, umap, now, full, late_users=None):
    proof_p = os.path.join(out, "gmail-proof.jsonl")
    contacts_p = os.path.join(out, "gmail-contacts.json")
    state_p = os.path.join(out, "gmail-state.json")
    proof = {json.loads(l)["msg"]: json.loads(l) for l in open(proof_p)} if os.path.exists(proof_p) else {}
    for m in att:
        uid = umap.get(addr(m))
        if uid and m.get("id") not in proof:
            proof[m["id"]] = {"msg": m["id"], "thread": m.get("threadId"), "created": m.get("date"), "user_id": uid}
    contacts = json.load(open(contacts_p)) if os.path.exists(contacts_p) else {}
    for m in c90:
        uid = umap.get(addr(m))
        if uid:
            contacts[m["id"]] = {"date": m.get("date"), "user_id": uid}
    key = hmac_key(out)
    unmapped_p = os.path.join(out, "gmail-unmapped.json")
    unmapped = json.load(open(unmapped_p)) if os.path.exists(unmapped_p) else {}
    keep_unmapped(unmapped, att, "att", umap, key)
    keep_unmapped(unmapped, c90, "c90", umap, key)
    late = attribute_late(unmapped, late_users or {}, key, proof, contacts)
    cutoff = now - dt.timedelta(days=90)
    contacts = {k: v for k, v in contacts.items() if (mdate(v) or now) >= cutoff}
    # an unmapped c90 contact older than 90 days no longer matters; unmapped proof is kept 400 days
    unmapped = {k: v for k, v in unmapped.items()
                if (mdate({"date": v.get("created")}) or now) >= now - dt.timedelta(days=90 if v.get("kind") == "c90" else 400)}
    json.dump(unmapped, open(unmapped_p + ".tmp", "w"))
    os.replace(unmapped_p + ".tmp", unmapped_p)
    merge.late = late

    with open(proof_p + ".tmp", "w") as fh:
        for v in proof.values():
            fh.write(json.dumps(v) + "\n")
    os.replace(proof_p + ".tmp", proof_p)
    json.dump(contacts, open(contacts_p + ".tmp", "w"))
    os.replace(contacts_p + ".tmp", contacts_p)
    state = json.load(open(state_p)) if os.path.exists(state_p) else {}
    if full:
        state["full_done_at"] = iso(now)
    state["last_success_at"] = iso(now)
    if late_users is not None:
        state["late_reg_checked_at"] = iso(now)
    json.dump(state, open(state_p + ".tmp", "w"))
    os.replace(state_p + ".tmp", state_p)
    return proof, contacts


SEED_DIR = os.environ.get("CS_PROOF_GMAIL_SEED_DIR", "/root/fmc1-gmail")


def seed(prefix):
    """The full scan's pages for a prefix, or [] when that scan is absent or incomplete."""
    try:
        return pull(prefix, SEED_DIR)
    except SystemExit:
        return []


def late_since(state, now, overlap=dt.timedelta(days=1), first=dt.timedelta(days=400)):
    """Accounts created since the last late-registration check (minus a day of overlap); the first
    check covers the unmapped store's whole 400-day span."""
    try:
        last = dt.datetime.strptime(state["late_reg_checked_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
        return iso(last - overlap)
    except (KeyError, TypeError, ValueError):
        return iso(now - first)


def resume_days(state, now, min_days=2, max_days=400):
    """newer_than:<N>d for the incremental: at least min_days, and always back to the last SUCCESSFUL
    run plus one day of overlap (QA #1391: a fixed 2-day query lost the mail of a longer outage while
    the recovered run marked cs-gmail fresh). No readable stamp -> the 400-day cap (the full scan's span)."""
    stamp = state.get("last_success_at") or state.get("full_done_at")
    try:
        last = dt.datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    except (TypeError, ValueError):
        return max_days
    gap = max(0.0, (now - last).total_seconds() / 86400)
    return int(min(max_days, max(min_days, math.ceil(gap) + 1)))


def main(argv):
    out = argv[1]
    mode = "--full" if "--full" in argv else "--incremental"
    now = dt.datetime.now(dt.timezone.utc)
    if mode == "--incremental":
        state_p = os.path.join(out, "gmail-state.json")
        state = json.load(open(state_p)) if os.path.exists(state_p) else {}
        if not state.get("full_done_at"):
            raise SystemExit("no full Gmail scan ingested yet; incremental skipped")
        days = resume_days(state, now)
        for p, q in (("atti", f"has:attachment newer_than:{days}d {EXCL}"), ("c90i", f"newer_than:{days}d {EXCL}")):
            if scan(p, q).returncode != 0:
                raise SystemExit(f"incremental scan {p} failed; gmail part not refreshed")
        att, c90 = pull("atti"), pull("c90i")
    else:
        att, c90 = pull("att"), pull("c90p")
    state_p = os.path.join(out, "gmail-state.json")
    state = json.load(open(state_p)) if os.path.exists(state_p) else {}
    if not os.path.exists(os.path.join(out, "gmail-unmapped.json")):
        # First run with the late-registration store: seed it from the completed full scan's pages
        # (senders with no account then), so mail from before this change is not left out.
        att, c90 = att + seed("att"), c90 + seed("c90p")
    since = late_since(state, now)
    try:
        umap = replica.users_by_email({addr(m) for m in att + c90})
        late_users = replica.users_created_since(since)
    except RuntimeError as e:
        raise SystemExit(f"{e}; nothing ingested")
    proof, contacts = merge(out, att, c90, umap, now, mode == "--full", late_users=late_users)
    print(f"{iso(now)} gmail {mode[2:]}: attachments {len(att)} msgs -> proof rows {len(proof)} "
          f"(users {len({v['user_id'] for v in proof.values()})}); contacts 90d users "
          f"{len({v['user_id'] for v in contacts.values()})}; late registrations attributed {merge.late} "
          f"(accounts since {since})")


if __name__ == "__main__":
    main(sys.argv)
