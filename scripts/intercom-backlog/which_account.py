#!/usr/bin/env python3
"""The "which account?" ask for unmatched proof documents (Fable order [key=unattended] 2026-10-30;
copy fable-copy-1030-r5/b, data/pr-review-fable-r5/copy-approvals-1030.md). DRY-RUN BY DEFAULT.

A customer sent a document, the hourly intake could not match the sender to a Muso account, and the
document sits in the unresolved tray (/var/lib/hydra-credit-verify/intake-unresolved.jsonl). This
asks THAT sender, in THAT thread, which account it belongs to. It never names or hints at any other
account, never asks for ID, and never states a reason or a date.

Who gets it (every check re-run right before each send):
  - the conversation is in the tray, its source is Intercom, and it has exactly ONE contact (the
    reply reaches that address only);
  - no account can be found for it: intake_proposals' verified-email rule finds none ("no Muso
    account has this email", "no contact on the thread has an email"). A thread the rule or the
    presented-profile key CAN resolve is never asked: the intake files it. Young contacts (< 24 h,
    the intake retries), ambiguous emails, multi-contact threads and any thread naming another
    account are skipped;
  - nobody on our side has replied in the thread since the document arrived;
  - shared verify ledger (campaign which-account, request id doc-<sha256>): one ask per document,
    ever, claimed BEFORE the post, plus the one-message-per-user-per-UTC-day cap across campaigns.
    Several documents in one thread are asked about in ONE message;
  - the kill file /etc/hydra/which-account-ask.disabled is absent.
Sent through /opt/hydra/scripts/intercom-ops-write.sh reply (validate first, then post; POSTED is the
proof). Caroline's identity is pinned by the wrapper.

Usage (node-8, root):
  set -a; . /etc/openclaw/main.env; set +a
  python3 which_account.py [--max 25] [--apply]
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from typing import Any

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import intake_proposals as ip  # noqa: E402
from credit_review import verify_ledger, verify_notify  # noqa: E402
from credit_review import intercom_reconcile as rec  # noqa: E402

# Byte-for-byte, fable-copy-1030-r5/b. No edits without a new ref.
COPY_REF = "fable-copy-1030-r5/b"
COPY = ("Hi {first}, thanks for the document you sent. We couldn't match it to a Muso account yet. "
        "Reply here with the email address on your Muso account, or the link to your Muso profile, "
        "and we'll attach it to the right request.")
CAMPAIGN = verify_ledger.WHICH_ACCOUNT
APPROVER = "U7RP6HKUZ"
OPS_WRITE = "/opt/hydra/scripts/intercom-ops-write.sh"
LEDGER = "/var/lib/hydra/credit-review/ledger.sqlite3"
KILL = "/etc/hydra/which-account-ask.disabled"
NO_ACCOUNT = ("no Muso account has this email", "no contact on the thread has an email")
ISO = re.compile(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ")


def first_name(contact: dict[str, Any]) -> str:
    word = str((contact or {}).get("name") or "").strip().split(" ")[0]
    return word if re.fullmatch(r"[^\W\d_][\w'-]{0,30}", word or "") else "there"


def render(contact: dict[str, Any]) -> str:
    return COPY.format(first=first_name(contact))


def doc_keys(tray: dict[str, Any]) -> list[str]:
    return [f"doc-{f}" for f in ip._files(tray) if re.fullmatch(r"[0-9a-f]{16,64}", f)]


def received_epoch(tray: dict[str, Any]) -> float:
    stamps = ISO.findall(str(tray.get("received_at") or "")) or ISO.findall(str(tray.get("at") or ""))
    if not stamps:
        return 0.0
    return max(dt.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc).timestamp()
               for s in stamps)


def user_key(contact: dict[str, Any]) -> str:
    em = str(contact.get("email") or "").strip().lower()
    return em if em else f"intercom-contact:{contact.get('id')}"


def eligible(tray: dict[str, Any], conv: dict[str, Any] | None, contacts: list[dict[str, Any]] | None,
             proposal: dict[str, Any]) -> str:
    """Pure: '' when the ask may go, else the skip reason."""
    if str(tray.get("source") or "") != "intercom":
        return "not an Intercom document"
    if conv is None or contacts is None:
        return "conversation or contact unreadable"
    if len(contacts) != 1:
        return f"the thread has {len(contacts)} contacts (exactly one required)"
    if proposal.get("decision") != "no-proposal" or proposal.get("reason") not in NO_ACCOUNT:
        return f"not an unmatched sender ({proposal.get('decision')}: {proposal.get('reason', '')})"
    if not doc_keys(tray):
        return "no document hash in the tray row"
    got = received_epoch(tray)
    lar = ((conv.get("statistics") or {}).get("last_admin_reply_at") or 0)
    if not got:
        return "no document time in the tray row"
    if lar and lar >= got:
        return "we already replied after the document"
    return ""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tray", default=ip.TRAY)
    ap.add_argument("--max", type=int, default=25)
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args()
    if a.apply and os.path.exists(KILL):
        sys.exit(f"REFUSED: kill file {KILL} is present.")
    token = os.environ.get("MUSOAI_INTERCOM_TOKEN")
    if not token:
        sys.exit("MUSOAI_INTERCOM_TOKEN not set")
    tray = ip.tray_rows(a.tray)
    convs = {cid: ip.intercom_get(token, f"/conversations/{cid}") for cid in tray}
    contacts = {cid: (ip.thread_contacts(c, lambda i: ip.intercom_get(token, f"/contacts/{i}")) if c else None)
                for cid, c in convs.items()}
    emails = sorted({str(x.get("email") or "").strip().lower() for cs in contacts.values() if cs for x in cs} - {""})
    by_email = ip.accounts_for(emails, verify_notify.trino)
    uids = sorted({u for v in by_email.values() for u in v})
    facts = rec.account_facts(uids, verify_notify.trino) if uids else {}
    exts = sorted({str(x.get("external_id") or "").strip() for cs in contacts.values() if cs for x in cs} - {""})
    owners = rec.ext_owners(exts, verify_notify.trino) if exts else {}
    presented = rec.presented_owners(exts, verify_notify.trino) if exts else {}
    for x, us in presented.items():
        owners.setdefault(x, set()).update(us)
    reverted = rec.reverted_holders(exts, verify_notify.trino) if exts else {}
    # An external_id that names ANY account means the intake can (or will, with the presented key)
    # resolve it, or it names someone else: never ask.
    named = {x for x, us in owners.items() if us}
    now = time.time()
    today = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")
    db = verify_ledger.connect(LEDGER) if a.apply else ip_ledger_ro(LEDGER)
    stats = {"sent": 0, "dry": 0, "failed": 0, "skipped": {}}

    def skip(why):
        stats["skipped"][why] = stats["skipped"].get(why, 0) + 1

    done = 0
    for cid in sorted(tray, key=lambda c: received_epoch(tray[c])):
        if done >= a.max:
            break
        cs = contacts.get(cid)
        if cs and any(str(c.get("external_id") or "").strip() in named for c in cs):
            skip("the external_id names a Muso account (the intake resolves it)")
            continue
        prop = ip.propose_one(cid, tray[cid], cs, accounts_by_email=by_email, facts=facts, ext_owner=owners,
                              now=now, reverted=reverted, presented=presented)
        why = eligible(tray[cid], convs.get(cid), cs, prop)
        if why:
            skip(why)
            continue
        contact = cs[0]
        key = user_key(contact)
        keys = doc_keys(tray[cid])
        fresh = [k for k in keys if k not in verify_ledger.blocked_ids(db, keys, CAMPAIGN)]
        if not fresh:
            skip("already asked for every document (ledger)")
            continue
        if verify_ledger.capped(db, user_key=key, day=today):
            skip("messaged today (ledger)")
            continue
        body = render(contact)
        with tempfile.NamedTemporaryFile("w", delete=False, suffix=".txt") as f:
            f.write(body)
            bf = f.name
        base = [OPS_WRITE, "reply", "--conversation", cid, "--requested-by", APPROVER,
                "--customer-facing", "--approved-by", APPROVER, "--body-file", bf]
        try:
            v = subprocess.run(base + ["--validate"], capture_output=True, text=True, timeout=60)
            if v.returncode:
                stats["failed"] += 1
                print(f"REFUSED {cid}: {v.stderr.strip()[:200]}")
                continue
            done += 1
            if not a.apply:
                stats["dry"] += 1
                print(f"DRY {cid} docs={len(fresh)} :: {body}")
                continue
            c = verify_ledger.claim(db, user_key=key, day=today, request_ids=fresh, message_type="comment",
                                    approved_by=APPROVER, approval_ref=COPY_REF, contact_id=str(contact.get("id") or ""),
                                    campaign=CAMPAIGN)
            if c["result"] != "claimed":
                skip(f"ledger: {c['result']}")
                continue
            p = subprocess.run(base, capture_output=True, text=True, timeout=90)
            m = re.match(r"POSTED comment conversation=\d+ part=(\S+)", p.stdout or "")
            sha = hashlib.sha256(body.encode()).hexdigest()
            if p.returncode == 0 and m:
                verify_ledger.finalize(db, message_row=c["message_row"], status="sent", message_id=m.group(1),
                                       conversation_id=cid, body_sha256=sha)
                stats["sent"] += 1
                print(p.stdout.strip())
            else:
                verify_ledger.finalize(db, message_row=c["message_row"],
                                       status="attempted" if p.returncode == 4 else "rejected",
                                       conversation_id=cid, body_sha256=sha,
                                       reason=f"rc={p.returncode}: {(p.stderr or '').strip()[:300]}")
                stats["failed"] += 1
                print(f"FAILED {cid}: rc={p.returncode}")
            time.sleep(0.5)
        finally:
            os.unlink(bf)
    print(json.dumps(stats))
    return 0


def ip_ledger_ro(path):
    import sqlite3
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    return db


if __name__ == "__main__":
    sys.exit(main())
