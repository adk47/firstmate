#!/usr/bin/env python3
"""Unmatched incoming proof documents: identity-link PROPOSALS (standing duty of intercom-backlog-i1,
from Fable verify-program-lead-fable-l1 after intercom-id-reconcile-x2 finished).

The hourly intake (scripts/credit-proof.py, credit_verify.proof.intake.strict_identity) files a
document only when the thread has exactly one Intercom `user` contact whose external_id resolves to
one account with the same email hash. Everything else lands in the unresolved tray
(/var/lib/hydra-credit-verify/intake-unresolved.jsonl). This job reads that tray and PROPOSES, per
conversation, the one account the document belongs to, by VERIFIED EMAIL ONLY, never by name.

READ-ONLY: core is read through Trino, Intercom only through GETs; it files nothing, writes no
Intercom contact, no ledger row, no status, and messages nobody. Its only writes are its own outputs
(0600) and its own small state file (seen conversations, for the daily count line).

"Verified email" (the proposal rule, for l1 to rule on with the first 10):
  - every contact on the thread that carries an email carries the SAME email (after lower/trim);
  - exactly one Muso account has that email (users.email), and that account's email is confirmed
    (users.emailconfirmed);
  - no admin create / email change ever gave that email to another account (core action_log, from
    2026-09-01), and no other account holds it now;
  - the contact is at least 24 h old (younger rows are left to the intake itself, which retries);
  - the contact's external_id, if any, does not name ANOTHER Muso account (users.id, professional id,
    Auth0 subject, or an active presented profile: x2's r5 rule), and no other account has a
    reverted claim on it.
  A thread whose only contact is a `lead` is proposed with the flag `lead-email` (a lead types its own
  email in the Messenger; l1 decides whether that counts as verified).
Anything else is `no-proposal` with the reason. Paid status and account age are reported, never used
to pick an account.

Each proposal names the next step for the coded resolver: file the conversation's documents to the
account, and the Intercom fix class for credit-review.py intercom-reconcile (A1 empty external_id,
A2 orphan external_id, LEAD lead-only thread). Emails never appear in any output (sha256 prefix only).

Usage (node-8, root):
  set -a; . /etc/openclaw/main.env; set +a
  python3 intake_proposals.py [--tray PATH] [--out DIR] [--state PATH] [--first 10]
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request
from typing import Any, Callable

# Run from the repo (scripts/intercom-backlog/) or from stdin with PYTHONPATH=/opt/hydra/scripts.
if "__file__" in globals():
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from credit_review import intercom_reconcile as rec  # noqa: E402
from credit_review import verify_notify  # noqa: E402

TRAY = os.environ.get("CREDIT_DOC_INTAKE_UNRESOLVED", "/var/lib/hydra-credit-verify/intake-unresolved.jsonl")
OUT_DIR = "/var/lib/intercom-backlog-i1/intake-proposals"
STATE = "/var/lib/intercom-backlog-i1/intake-proposals-state.json"
CONTACT_MIN_AGE_S = 24 * 3600
API = "https://api.intercom.io"


def ehash(email: str) -> str:
    return hashlib.sha256((email or "").strip().lower().encode()).hexdigest()


def tray_rows(path: str) -> dict[str, dict[str, Any]]:
    """{conversation_id: newest tray row}. The tray is append-only; a conversation may recur."""
    out: dict[str, dict[str, Any]] = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            r = json.loads(line)
            cid = str(r.get("conversation_id") or "")
            if cid and (cid not in out or str(r.get("at", "")) >= str(out[cid].get("at", ""))):
                out[cid] = r
    return out


def thread_contacts(conv: dict[str, Any], contact_fetch: Callable[[str], dict[str, Any] | None]) -> list[dict[str, Any]] | None:
    refs = ((conv or {}).get("contacts") or {}).get("contacts") or []
    out = []
    for ref in refs:
        c = contact_fetch(str(ref.get("id") or "")) if ref.get("id") else None
        if not c:
            return None  # an unreadable contact could be the other person: nothing is proposed
        out.append(c)
    return out


def propose_one(cid: str, tray: dict[str, Any], contacts: list[dict[str, Any]] | None, *,
                accounts_by_email: dict[str, list[int]], facts: dict[int, rec.Account],
                ext_owner: dict[str, set[str]], now: float,
                reverted: dict[str, set[str]] | None = None,
                presented: dict[str, set[str]] | None = None) -> dict[str, Any]:
    """ext_owner: external_id -> accounts whose users.id / professional id / Auth0 subject OR active
    presented profile (r5, x2's rule) it is. reverted: external_id -> accounts with a reverted claim on
    it (conflict evidence only, never ownership)."""
    reverted = reverted or {}
    presented = presented or {}
    """Pure: one conversation -> a proposal or a no-proposal with its reason."""
    base = {"conversation_id": cid, "tray_why": tray.get("why", ""), "files": len(_files(tray))}
    if contacts is None:
        return dict(base, decision="no-proposal", reason="a contact on the thread is unreadable")
    if not contacts:
        return dict(base, decision="no-proposal", reason="the thread has no contacts")
    emailed = [c for c in contacts if str(c.get("email") or "").strip()]
    emails = {str(c["email"]).strip().lower() for c in emailed}
    if not emails:
        return dict(base, decision="no-proposal", reason="no contact on the thread has an email")
    if len(emails) > 1:
        return dict(base, decision="no-proposal", reason="the thread's contacts carry different emails")
    email = emails.pop()
    if not rec.EMAIL_RE.match(email):
        return dict(base, decision="no-proposal", reason="the contact email is not checkable")
    base["email_sha"] = ehash(email)[:12]
    young = [c for c in emailed if not c.get("created_at") or now - float(c.get("created_at") or 0) < CONTACT_MIN_AGE_S]
    if young:
        return dict(base, decision="wait", reason="the contact is younger than 24 h (the intake retries it)")
    accts = sorted(set(accounts_by_email.get(email, [])))
    if not accts:
        return dict(base, decision="no-proposal", reason="no Muso account has this email")
    if len(accts) > 1:
        return dict(base, decision="no-proposal", reason=f"{len(accts)} Muso accounts have this email")
    a = facts.get(accts[0])
    if a is None:
        return dict(base, decision="no-proposal", reason="the account could not be read")
    blockers = []
    if not a.email_confirmed:
        blockers.append("account email not confirmed")
    if a.other_holders:
        blockers.append("another account holds this email")
    if a.admin_history:
        blockers.append("an admin gave this email to another account")
    exts = {str(c.get("external_id") or "").strip() for c in emailed} - {""}
    other = sorted({o for x in exts for o in ext_owner.get(x, set()) if o != str(a.user_id)})
    if other:
        blockers.append("a contact's external_id names another Muso account (" + ",".join(other) + ")")
    rev = sorted({o for x in exts for o in reverted.get(x, set()) if o != str(a.user_id)})
    if rev:
        blockers.append("another account has a reverted claim on the contact's external_id (" + ",".join(rev) + ")")
    if blockers:
        return dict(base, decision="no-proposal", account_id=a.user_id, reason="; ".join(blockers))
    roles = sorted({str(c.get("role") or "") for c in emailed})
    if exts and all(str(a.user_id) in presented.get(x, set()) for x in exts):
        # x2's r5: the external_id is the account's own PRESENTED profile (the mobile app logs into
        # Intercom with it). Nothing to fix in Intercom; the intake's own lookup does not know r5.
        fix = "R5 (external_id = this account's presented profile; intake lookup lacks r5)"
    elif exts and all(ext_owner.get(x) == {str(a.user_id)} for x in exts):
        fix = "none (the external_id is already this account; re-run the intake)"
    elif roles == ["lead"]:
        fix = "LEAD (lead-only thread)"
    elif not exts:
        fix = "A1 (empty external_id)"
    else:
        fix = "A2 (orphan external_id)"
    flags = ["lead-email"] if "lead" in roles else []
    age_d = None if a.created_at is None else round((dt.datetime.now(dt.timezone.utc) - a.created_at).days)
    return dict(base, decision="propose", account_id=a.user_id, contact_roles=roles, flags=flags,
                paid=a.paid, account_age_days=age_d, intercom_fix=fix,
                next_step=f"file the conversation's documents to account {a.user_id}; intercom-reconcile {fix.split(' ')[0]}")


def _files(tray: dict[str, Any]) -> list[str]:
    f = tray.get("files")
    if isinstance(f, list):
        return f
    if isinstance(f, str) and f.startswith("["):
        return [x.strip(" '\"") for x in f.strip("[]").split(",") if x.strip(" '\"")]
    return [f] if f else []


# -- I/O (node-8) ------------------------------------------------------------------------------

def intercom_get(token: str, path: str) -> dict[str, Any] | None:
    req = urllib.request.Request(f"{API}{path}", headers={
        "Authorization": f"Bearer {token}", "Accept": "application/json", "Intercom-Version": "2.11"})
    for i in range(4):
        try:
            with urllib.request.urlopen(req, timeout=50) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            if e.code in (429, 500, 502, 503, 504) and i < 3:
                time.sleep(2 ** i)
                continue
            return None
        except urllib.error.URLError:
            if i < 3:
                time.sleep(2 ** i)
                continue
            return None
    return None


def accounts_for(emails: list[str], query) -> dict[str, list[int]]:
    out: dict[str, list[int]] = {}
    ok = sorted({e for e in emails if rec.EMAIL_RE.match(e)})
    for i in range(0, len(ok), 200):
        for uid, em in query("SELECT CAST(id AS varchar), lower(trim(email)) FROM postgresql_core.public.users "
                             f"WHERE lower(trim(email)) IN ({rec._q(ok[i:i + 200])})"):
            out.setdefault(str(em), []).append(int(uid))
    return out


def daily_line(results: list[dict[str, Any]], state: dict[str, Any], today: str) -> tuple[str, dict[str, Any]]:
    seen = state.get("seen", {})
    linked = set(state.get("linked", []))
    new = [r["conversation_id"] for r in results if r["conversation_id"] not in seen]
    for cid in new:
        seen[cid] = today
    still = [r for r in results if r["conversation_id"] not in linked]
    props = sum(1 for r in still if r["decision"] == "propose")
    line = (f"intake-unresolved {today}: new {len(new)} / linked {len(linked & {r['conversation_id'] for r in results})} / "
            f"still unresolved {len(still)} (proposals {props}, wait {sum(1 for r in still if r['decision'] == 'wait')}, "
            f"no-proposal {sum(1 for r in still if r['decision'] == 'no-proposal')})")
    return line, {"seen": seen, "linked": sorted(linked)}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tray", default=TRAY)
    ap.add_argument("--out", default=OUT_DIR)
    ap.add_argument("--state", default=STATE)
    ap.add_argument("--first", type=int, default=10, help="proposals marked for l1's rule review")
    ap.add_argument("--quiet", action="store_true", help="print only the daily count line (cron)")
    a = ap.parse_args()
    token = os.environ.get("MUSOAI_INTERCOM_TOKEN")
    if not token:
        sys.exit("MUSOAI_INTERCOM_TOKEN not set (set -a; . /etc/openclaw/main.env; set +a)")
    tray = tray_rows(a.tray)
    convs = {cid: intercom_get(token, f"/conversations/{cid}") for cid in tray}
    contacts = {cid: (thread_contacts(c, lambda i: intercom_get(token, f"/contacts/{i}")) if c else None)
                for cid, c in convs.items()}
    emails = sorted({str(x.get("email") or "").strip().lower() for cs in contacts.values() if cs for x in cs} - {""})
    by_email = accounts_for(emails, verify_notify.trino)
    uids = sorted({u for v in by_email.values() for u in v})
    facts = rec.account_facts(uids, verify_notify.trino) if uids else {}
    exts = sorted({str(x.get("external_id") or "").strip() for cs in contacts.values() if cs for x in cs} - {""})
    owners = rec.ext_owners(exts, verify_notify.trino) if exts else {}
    presented = rec.presented_owners(exts, verify_notify.trino) if exts else {}
    for x, us in presented.items():
        owners.setdefault(x, set()).update(us)
    reverted = rec.reverted_holders(exts, verify_notify.trino) if exts else {}
    now = time.time()
    results = [propose_one(cid, tray[cid], contacts[cid], accounts_by_email=by_email, facts=facts,
                           ext_owner=owners, now=now, reverted=reverted,
                           presented=presented) for cid in sorted(tray)]
    n = 0
    for r in results:
        if r["decision"] == "propose" and n < a.first:
            r["review"] = "l1-rule-review"
            n += 1
    today = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")
    try:
        state = json.load(open(a.state))
    except (OSError, ValueError):
        state = {}
    line, state = daily_line(results, state, today)
    os.makedirs(a.out, mode=0o700, exist_ok=True)
    path = os.path.join(a.out, f"proposals-{dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.json")
    for p, doc in ((path, {"generated_at": today, "line": line, "results": results}), (a.state, state)):
        fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(doc, f, indent=1)
    print(line + f" -> {path}" if a.quiet else json.dumps({"file": path, "line": line, "results": results}, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
