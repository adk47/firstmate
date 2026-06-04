#!/usr/bin/env python3
"""Silently close Intercom conversations whose ClickUp ticket(s) are all resolved.

Closes the regrowth axis where a customer's request was handled (the ClickUp
ticket is resolved) but the Intercom conversation was never closed — the
decoupling that let the open-conversation pile grow unbounded. Root cause +
triage: docs/2026-06-02-queue-triage-report.md.

SAFETY — a conversation is closed ONLY when BOTH of:
  - WE spoke last: last_admin_reply_at > last_contact_reply_at. This excludes
    `customer_last` (customer waiting on us) and `never_replied` (a chat that
    never got an answer — possibly a dropped customer). We never silently bury
    a conversation that still needs a human, AND
  - the conversation is tied to a resolved ticket. How that tie is established
    depends on the mode:
      * default (what the unattended daily timer runs): PRECISE linkage only.
        The conversation id appears in a ClickUp ticket's "Intercom Link" field
        (added in #417) and EVERY ticket linked to THIS conversation is
        resolved/closed. A conversation with no linked ticket — or with any
        open linked ticket — is left alone. So a new/unrelated conversation
        for a customer who merely had older resolved tickets is NOT closed.
      * --backfill (explicit, human-run, one-time): for conversations with no
        #417 link, fall back to loose email matching — the customer's email
        matches >=1 ticket and EVERY email-matched ticket is resolved. This
        drains the pre-#417 backlog under supervision; the timer never uses it.
The close is SILENT (no customer-facing message), so it generates no new
inbound — safe to run while CS has no bandwidth.

Dry-run by default. `--apply` is the explicit gate. Every close is appended to
a shadow log (id, timestamp, email) so it can be reversed.

Env:
  MUSOAI_INTERCOM_TOKEN          required
  CLICKUP_API_KEY                required
  INTERCOM_ADMIN_ID             optional, default 5763097 (Caroline)
  CLICKUP_LIST_ID               optional, default 901000600160 (User Requests)
  CLICKUP_INTERCOM_LINK_FIELD_ID optional, default c32dbf6e-... (#417 link field)
  CLOSE_SHADOW_LOG              optional, default /var/log/close-resolved-shadow.jsonl
                                (falls back to /tmp if that path is not writable)

Flags:
  --apply       actually close (default: dry-run — list only, no writes)
  --backfill    ALSO close pre-#417 conversations matched loosely by customer
                email (no #417 link). Off by default so the unattended timer
                only closes conversations precisely linked to a resolved ticket.
  --limit N     cap the number closed this run (ramp safely)

Exit codes: 0 ok; 1 usage/env error; 3 at least one close failed.
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

INTERCOM_API = "https://api.intercom.io"
INTERCOM_VERSION = "2.11"
CLICKUP_API = "https://api.clickup.com/api/v2"
USER_EMAIL_FIELD = "e8618c74-d065-4b75-9a5a-86d658392409"  # "User Email" custom field
# "Intercom Link" custom field added in #417 (default mirrors support-tools'
# plugins/support-tools/src/index.ts). Its value is the conversation deeplink
# https://app.intercom.com/a/inbox/<ws>/inbox/conversation/<convId>, from which
# we recover the conversation id for precise (non-email) matching.
INTERCOM_LINK_FIELD = os.environ.get(
    "CLICKUP_INTERCOM_LINK_FIELD_ID", "c32dbf6e-f680-4ff1-a532-192bb96245c3")
_CONV_ID_RE = re.compile(r"/conversation/([^/?#\s]+)")
DEFAULT_LIST_ID = "901000600160"


def _retry_json(req, attempts=4):
    for a in range(attempts):
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return json.load(resp)
        except urllib.error.URLError:
            if a == attempts - 1:
                raise
            time.sleep(2 * (a + 1))


def intercom_search(token, body):
    req = urllib.request.Request(
        f"{INTERCOM_API}/conversations/search",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                 "Content-Type": "application/json", "Intercom-Version": INTERCOM_VERSION},
        method="POST")
    return _retry_json(req)


def clickup_get(url, key):
    return _retry_json(urllib.request.Request(url, headers={"Authorization": key}))


def _ticket_resolved(t):
    """True if a ClickUp task counts as resolved/closed (handled)."""
    st = t.get("status") or {}
    return (st.get("type") in ("closed", "done")) or (st.get("status") in ("resolved", "impossible"))


def _conv_id_from_link(value):
    """Recover the Intercom conversation id from an "Intercom Link" field value."""
    m = _CONV_ID_RE.search(str(value))
    return m.group(1) if m else None


def build_ticket_index(key, list_id):
    """Scan the ClickUp list once and return (email_states, conv_states).

    email_states: email(lower) -> set[bool]  — loose, by "User Email" field.
                  Used only by --backfill for the pre-#417 backlog.
    conv_states:  intercom_conv_id -> set[bool]  — precise, by the #417
                  "Intercom Link" field. The default matching path.
    Each bool is True iff that ticket is resolved/closed.
    """
    email_states, conv_states = {}, {}
    page = 0
    while page < 200:
        q = urllib.parse.urlencode({"include_closed": "true", "subtasks": "false", "page": str(page)})
        data = clickup_get(f"{CLICKUP_API}/list/{list_id}/task?{q}", key)
        tasks = data.get("tasks", [])
        if not tasks:
            break
        for t in tasks:
            done = _ticket_resolved(t)
            for cf in t.get("custom_fields", []):
                cid, val = cf.get("id"), cf.get("value")
                if not val:
                    continue
                if cid == USER_EMAIL_FIELD:
                    email_states.setdefault(str(val).lower().strip(), set()).add(done)
                elif cid == INTERCOM_LINK_FIELD:
                    conv_id = _conv_id_from_link(val)
                    if conv_id:
                        conv_states.setdefault(conv_id, set()).add(done)
        page += 1
        if data.get("last_page"):
            break
    return email_states, conv_states


def fetch_open_convs(token):
    convs = []
    after = None
    while True:
        body = {"query": {"field": "state", "operator": "=", "value": "open"},
                "pagination": {"per_page": 150}}
        if after:
            body["pagination"]["starting_after"] = after
        data = intercom_search(token, body)
        for c in data.get("conversations", []):
            src = c.get("source") or {}
            au = src.get("author") or {}
            stats = c.get("statistics") or {}
            convs.append({
                "id": c.get("id"),
                "email": (au.get("email") or "").lower().strip() if au.get("type") == "user" else "",
                "lar": stats.get("last_admin_reply_at") or 0,
                "lcr": stats.get("last_contact_reply_at") or 0,
            })
        nxt = (data.get("pages") or {}).get("next")
        after = nxt.get("starting_after") if isinstance(nxt, dict) else None
        if not nxt or not after:
            break
    return convs


def is_eligible(conv, email_states, conv_states, backfill=False):
    """Eligible to close iff we spoke last AND it is tied to a resolved ticket.

    We-spoke-last is required first (excludes never_replied + customer_last).
    The tie to a resolved ticket is then established, most-precise-first:
      1. PRECISE (#417 link): if this conversation id is linked to any ticket,
         that linkage is authoritative — close iff EVERY linked ticket is
         resolved. An open linked ticket blocks the close even under backfill.
      2. EMAIL fallback (--backfill only): for conversations with no link, the
         pre-#417 path — close iff the customer's email matches >=1 ticket and
         EVERY email-matched ticket is resolved.
    """
    lar, lcr = conv["lar"], conv["lcr"]
    # Strictly admin-last. Intercom timestamps are second-granular, so lar == lcr
    # is an ambiguous ordering, not proven admin-last — for an unattended silent
    # close we require lar > lcr. lar > 0 also excludes never_replied.
    if not (lar > 0 and lar > lcr):
        return False
    cid = conv["id"]
    if cid in conv_states:  # precise linkage is authoritative
        return all(conv_states[cid])
    if not backfill:  # steady-state: precise links only, never loose email
        return False
    em = conv["email"]
    return bool(em) and em in email_states and all(email_states[em])


def close_conversation(token, admin_id, conv_id):
    req = urllib.request.Request(
        f"{INTERCOM_API}/conversations/{conv_id}/parts",
        data=json.dumps({"message_type": "close", "type": "admin", "admin_id": str(admin_id)}).encode(),
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                 "Content-Type": "application/json", "Intercom-Version": INTERCOM_VERSION},
        method="POST")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def open_shadow_log():
    path = os.environ.get("CLOSE_SHADOW_LOG", "/var/log/close-resolved-shadow.jsonl")
    try:
        return open(path, "a"), path
    except OSError:
        fallback = "/tmp/close-resolved-shadow.jsonl"
        try:
            return open(fallback, "a"), fallback
        except OSError:
            return None, None


def main():
    ap = argparse.ArgumentParser(description="Silently close conversations whose ClickUp ticket is resolved")
    ap.add_argument("--apply", action="store_true", help="actually close (default: dry-run)")
    ap.add_argument("--backfill", action="store_true",
                    help="also close pre-#417 conversations matched loosely by email")
    ap.add_argument("--limit", type=int, default=0, help="cap closes this run (0 = no cap)")
    args = ap.parse_args()

    token = os.environ.get("MUSOAI_INTERCOM_TOKEN")
    key = os.environ.get("CLICKUP_API_KEY")
    if not token or not key:
        print("ERROR: MUSOAI_INTERCOM_TOKEN and CLICKUP_API_KEY are required", file=sys.stderr)
        return 1
    admin_id = os.environ.get("INTERCOM_ADMIN_ID", "5763097")
    list_id = os.environ.get("CLICKUP_LIST_ID", DEFAULT_LIST_ID)

    email_states, conv_states = build_ticket_index(key, list_id)
    convs = fetch_open_convs(token)
    eligible = [c for c in convs if is_eligible(c, email_states, conv_states, args.backfill)]

    mode = "precise #417 link + email backfill" if args.backfill else "precise #417 link only"
    print(f"matching mode: {mode}")
    print(f"resolved-ticket conversation links: {len(conv_states)}")
    print(f"open conversations scanned: {len(convs)}")
    print(f"eligible (linked ticket resolved AND we replied last): {len(eligible)}")

    if not args.apply:
        for c in eligible[:15]:
            print(f"  would close conv={c['id']} email={c['email']}")
        if len(eligible) > 15:
            print(f"  ... and {len(eligible) - 15} more")
        print("DRY-RUN — no conversations closed. Re-run with --apply to close.")
        return 0

    targets = eligible[:args.limit] if args.limit > 0 else eligible
    shadow, shadow_path = open_shadow_log()
    ok, fail = 0, []
    for c in targets:
        try:
            res = close_conversation(token, admin_id, c["id"])
            if shadow:
                shadow.write(json.dumps({"id": c["id"], "closed_at": int(time.time()),
                                         "email": c["email"], "new_state": res.get("state")}) + "\n")
                shadow.flush()
            ok += 1
        except (urllib.error.URLError, ValueError) as e:
            fail.append((c["id"], str(e)[:140]))
        time.sleep(0.3)
    if shadow:
        shadow.close()
    print(f"closed_ok={ok} failed={len(fail)} (shadow log: {shadow_path})")
    for f in fail[:15]:
        print(f"  FAIL {f}", file=sys.stderr)
    return 3 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
