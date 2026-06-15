#!/usr/bin/env python3
"""Add (or remove) a person to the abuse-block list — silence Caroline + stop ticketing for an abusive contact.

Tags an abusive contact's Intercom conversations (and the contact record itself)
with the `abuse-block` tag that the EDGE gateway's intercom plugin filters on.
That tag is listed in openclaw-edge.json `channels.intercom.accounts.default.
blockedChannelTags`; the handler (plugins/intercom/src/handler.ts) checks a
customer message's conversation tags against that list BEFORE dispatch and, on a
match, returns `action: "filtered"` — so Caroline never replies, never escalates,
and never calls create_ticket for that conversation.

Per-conversation by nature: the tag covers the contact's existing AND reopened
threads (the blocked-tag check runs before the implicit-reopen logic). For a
BRAND-NEW conversation the contact starts, pair this with an Intercom Workflow
that auto-applies `abuse-block` to any conversation from a contact already
carrying the `abuse-block` tag — which is why this script also tags the CONTACT.

Dry-run by default. `--apply` is the explicit gate. Every mutation is appended to
a shadow log (reversible). Reverse a block with `--remove`.

API shapes:
  - conversation tag  POST /conversations/{id}/tags {"id","admin_id"}  — verified vs
    Intercom REST API docs (Tags/attachTagToConversation), admin_id required.
  - close conversation POST /conversations/{id}/parts {"message_type":"close",...}
    — proven in-repo (scripts/close-resolved-conversations.py).
  - create/get tag, contact tag, and the DELETE detach shapes are standard
    Intercom v2.x endpoints; smoke-test on node-8 (dry-run, then one --apply on a
    throwaway contact) before relying on them — never validated locally.

Env:
  MUSOAI_INTERCOM_TOKEN  required
  INTERCOM_ADMIN_ID      optional, default 5763097 (Caroline bot admin — same admin
                         that owns the rest of the Intercom thread)
  ABUSE_BLOCK_TAG        optional, default "abuse-block" — MUST match a tag name in
                         openclaw-edge.json blockedChannelTags or blocking is a no-op
  ABUSE_BLOCK_LOG        optional, default /var/log/abuse-block.jsonl (falls back to
                         /tmp if not writable). --apply opens it BEFORE any write
                         and fails closed (exit 1) if neither path is writable —
                         no customer block is applied without a durable audit trail.
                         Writes an "intent" line before the first mutation and an
                         "outcome" line (with counts) after.

Flags:
  --email EMAIL        contact email to block (one of --email / --contact-id required)
  --contact-id ID      Intercom contact id (skips the email lookup)
  --requester WHO      REQUIRED — who authorized this (slack id or email); recorded
                       in the shadow log as the audit trail
  --reason TEXT        optional free-text reason (recorded in the shadow log)
  --close              also close the contact's open conversations (default: tag only)
  --remove             REVERSE a block: detach the tag from the contact + their convs
  --apply              actually write (default: dry-run — print the plan only)

Exit codes: 0 ok (incl. --remove when the tag doesn't exist — nothing to remove);
1 usage/env error; 3 did not fully complete (no such contact, Intercom API error
during resolution, tag could not be resolved/created, or >=1 write failed).
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

INTERCOM_API = "https://api.intercom.io"
INTERCOM_VERSION = "2.11"
DEFAULT_ADMIN_ID = "5763097"  # Caroline bot admin (openclaw-edge.json botAdminId)
DEFAULT_TAG = "abuse-block"


def _req(method, path, token, body=None, admin_header=False):
    url = f"{INTERCOM_API}{path}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
        "Intercom-Version": INTERCOM_VERSION,
    }
    data = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    # Light retry on transient transport errors only (mirrors close-resolved).
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=45) as resp:
                raw = resp.read()
                return resp.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as e:
            # HTTP errors are deterministic — surface the body, do not retry.
            try:
                detail = e.read().decode("utf-8", errors="replace")[:500]
            except Exception:
                detail = ""
            raise RuntimeError(f"{method} {path} -> HTTP {e.code}: {detail}") from None
        except urllib.error.URLError:
            if attempt == 3:
                raise
            time.sleep(2 * (attempt + 1))


def ensure_tag(token, tag_name, apply):
    """Return the id of the tag named `tag_name`, creating it if missing.

    GET /tags is read-only; the create (POST /tags) only happens under --apply.
    In dry-run with a missing tag, returns None — the plan still lists the
    conversations that would be tagged.
    """
    _, body = _req("GET", "/tags", token)
    body = body or {}
    items = body.get("data") or body.get("tags") or []
    for t in items:
        if str(t.get("name", "")).lower() == tag_name.lower():
            return t.get("id")
    if not apply:
        return None
    # Intercom POST /tags is create-or-update by name; returns the tag with its id.
    _, created = _req("POST", "/tags", token, body={"name": tag_name})
    return (created or {}).get("id")


def find_contacts_by_email(token, email):
    _, body = _req("POST", "/contacts/search", token, body={
        "query": {"field": "email", "operator": "=", "value": email},
    })
    return (body or {}).get("data", []) if isinstance(body, dict) else []


def get_contact(token, contact_id):
    _, body = _req("GET", f"/contacts/{contact_id}", token)
    return body or {}


def find_conversations(token, contact_id):
    """All conversations for a contact (any state), paginated."""
    convs, after = [], None
    while True:
        query = {"query": {"field": "contact_ids", "operator": "=", "value": contact_id},
                 "pagination": {"per_page": 150}}
        if after:
            query["pagination"]["starting_after"] = after
        _, body = _req("POST", "/conversations/search", token, body=query)
        for c in (body or {}).get("conversations", []):
            convs.append({"id": c.get("id"), "state": c.get("state")})
        nxt = ((body or {}).get("pages") or {}).get("next")
        after = nxt.get("starting_after") if isinstance(nxt, dict) else None
        if not after:
            break
    return convs


def tag_conversation(token, admin_id, conv_id, tag_id):
    _req("POST", f"/conversations/{conv_id}/tags", token,
         body={"id": str(tag_id), "admin_id": str(admin_id)})


def untag_conversation(token, admin_id, conv_id, tag_id):
    _req("DELETE", f"/conversations/{conv_id}/tags/{tag_id}", token,
         body={"admin_id": str(admin_id)})


def tag_contact(token, contact_id, tag_id):
    _req("POST", f"/contacts/{contact_id}/tags", token, body={"id": str(tag_id)})


def untag_contact(token, contact_id, tag_id):
    _req("DELETE", f"/contacts/{contact_id}/tags/{tag_id}", token)


def close_conversation(token, admin_id, conv_id):
    _req("POST", f"/conversations/{conv_id}/parts", token,
         body={"message_type": "close", "type": "admin", "admin_id": str(admin_id)})


def open_shadow_log():
    path = os.environ.get("ABUSE_BLOCK_LOG", "/var/log/abuse-block.jsonl")
    try:
        return open(path, "a"), path
    except OSError:
        fallback = "/tmp/abuse-block.jsonl"
        try:
            return open(fallback, "a"), fallback
        except OSError:
            return None, None


def audit_abort(shadow, reason):
    """Record an aborted-outcome line and close the (already-open) shadow log.

    Used on the early-return paths after the intent line is written, so the audit
    trail always pairs an intent with an outcome (even when nothing was mutated).
    """
    if shadow:
        shadow.write(json.dumps({"event": "outcome", "ts": int(time.time()), "aborted": reason}) + "\n")
        shadow.flush()
        shadow.close()


def main():
    ap = argparse.ArgumentParser(description="Add/remove a person on the abuse-block list")
    ap.add_argument("--email", help="contact email to block")
    ap.add_argument("--contact-id", help="Intercom contact id to block (skips email lookup)")
    ap.add_argument("--requester", required=True,
                    help="who authorized this (slack id or email) — recorded in the audit log")
    ap.add_argument("--reason", default="", help="free-text reason (recorded in the audit log)")
    ap.add_argument("--close", action="store_true", help="also close the contact's open conversations")
    ap.add_argument("--remove", action="store_true", help="REVERSE: detach the abuse-block tag")
    ap.add_argument("--apply", action="store_true", help="actually write (default: dry-run)")
    args = ap.parse_args()

    token = os.environ.get("MUSOAI_INTERCOM_TOKEN")
    if not token:
        print("ERROR: MUSOAI_INTERCOM_TOKEN is required", file=sys.stderr)
        return 1
    if not args.requester.strip():
        print("ERROR: --requester must be non-empty (it is the audit trail)", file=sys.stderr)
        return 1
    if bool(args.email) == bool(args.contact_id):
        print("ERROR: pass exactly one of --email or --contact-id", file=sys.stderr)
        return 1

    admin_id = os.environ.get("INTERCOM_ADMIN_ID", DEFAULT_ADMIN_ID)
    tag_name = os.environ.get("ABUSE_BLOCK_TAG", DEFAULT_TAG)
    action = "unblock" if args.remove else "block"

    # Resolve target contact(s). An email can match more than one contact; act on
    # all of them but report each so the operator can confirm identity. Refuse to
    # silently no-op when nothing matches. Wrap resolution so a transient Intercom
    # API error surfaces as a clean exit 3, not an uncaught traceback.
    # `creating`: only a real block (--apply, not --remove) may create the tag —
    # --remove must never mint a tag just to detach it.
    creating = args.apply and not args.remove
    try:
        if args.contact_id:
            c = get_contact(token, args.contact_id)
            if not c.get("id"):
                print(f"ERROR: no contact with id {args.contact_id}", file=sys.stderr)
                return 3
            contacts = [c]
        else:
            contacts = find_contacts_by_email(token, args.email)
            if not contacts:
                print(f"ERROR: no Intercom contact for email {args.email} — refusing to no-op",
                      file=sys.stderr)
                return 3
    except RuntimeError as e:
        print(f"ERROR: Intercom API call failed resolving the contact: {e}", file=sys.stderr)
        return 3

    # Audit BEFORE *any* Intercom mutation (QA #522) — including the ensure_tag
    # POST /tags create below. Open the log up front and FAIL CLOSED if we can't,
    # so nothing (not even the tag) is created/applied without a durable record.
    # Intent line first (a crash mid-run still leaves evidence); the outcome line
    # (with counts) is appended after the loop.
    shadow = shadow_path = None
    if args.apply:
        shadow, shadow_path = open_shadow_log()
        if not shadow:
            print("ERROR: cannot open the abuse-block audit log (set ABUSE_BLOCK_LOG to a "
                  "writable path) — refusing to apply without a durable audit trail",
                  file=sys.stderr)
            return 1
        shadow.write(json.dumps({
            "event": "intent", "ts": int(time.time()), "action": action,
            "requester": args.requester, "reason": args.reason, "tag": tag_name,
            "contacts": [c.get("id") for c in contacts],
        }) + "\n")
        shadow.flush()

    # Resolve/create the tag — the POST /tags create (apply-block, tag missing)
    # happens HERE, after the intent line, so it is never an unlogged mutation.
    try:
        tag_id = ensure_tag(token, tag_name, creating)
    except RuntimeError as e:
        print(f"ERROR: Intercom API call failed resolving tag {tag_name!r}: {e}", file=sys.stderr)
        audit_abort(shadow, f"tag-resolve-failed: {str(e)[:200]}")
        return 3

    if args.remove and not tag_id:
        print(f"tag {tag_name!r} not found in Intercom — nothing to remove", file=sys.stderr)
        audit_abort(shadow, "tag-absent: nothing to remove")
        return 0
    if creating and not tag_id:
        # apply-block reached here with no tag id ⇒ ensure_tag couldn't resolve or
        # create the tag. Abort LOUD rather than skip the writes and still report
        # the contact/convs as tagged — that would be a false "blocked" with
        # nothing actually written (the edge filter would never fire).
        print(f"ERROR: could not resolve or create tag {tag_name!r} — aborting with no writes",
              file=sys.stderr)
        audit_abort(shadow, "tag-unresolved")
        return 3

    summary = {
        "action": action,
        "mode": "apply" if args.apply else "dry-run",
        "requester": args.requester,
        "reason": args.reason,
        "tag": tag_name,
        "tag_id": tag_id,
        "email": args.email,
        "contacts": [{"id": c.get("id"), "name": c.get("name"), "email": c.get("email")}
                     for c in contacts],
        "contacts_tagged": [],
        "conversations_tagged": [],
        "conversations_closed": [],
        "failures": [],
    }

    for c in contacts:
        cid = c.get("id")
        print(f"[{action}] contact {cid} name={c.get('name')!r} email={c.get('email')!r}",
              file=sys.stderr)
        # Conversation lookup is inside the failure-recording path (QA #522): an
        # Intercom error here records a failure for this contact and moves on,
        # instead of throwing past the outcome-audit write below.
        try:
            convs = find_conversations(token, cid)
        except RuntimeError as e:
            print(f"  failed to list conversations: {e}", file=sys.stderr)
            summary["failures"].append(
                {"target": f"contact:{cid}", "error": f"list conversations: {str(e)[:280]}"})
            continue
        print(f"  {len(convs)} conversation(s); tag={tag_name!r} close={args.close}",
              file=sys.stderr)

        # Contact-level tag (drives the Intercom Workflow that covers future convs).
        try:
            if args.apply and tag_id:
                if args.remove:
                    untag_contact(token, cid, tag_id)
                else:
                    tag_contact(token, cid, tag_id)
            summary["contacts_tagged"].append(cid)
        except Exception as e:  # noqa: BLE001 — record, keep going to the convs
            summary["failures"].append({"target": f"contact:{cid}", "error": str(e)[:300]})

        for conv in convs:
            conv_id = conv["id"]
            try:
                if args.apply and tag_id:
                    if args.remove:
                        untag_conversation(token, admin_id, conv_id, tag_id)
                    else:
                        tag_conversation(token, admin_id, conv_id, tag_id)
                summary["conversations_tagged"].append(conv_id)
                # Closing only applies to a block, and only to still-open convs.
                if args.close and not args.remove and conv.get("state") != "closed":
                    if args.apply:
                        close_conversation(token, admin_id, conv_id)
                    summary["conversations_closed"].append(conv_id)
            except Exception as e:  # noqa: BLE001 — record per-conversation, continue
                summary["failures"].append({"target": f"conv:{conv_id}", "error": str(e)[:300]})
            if args.apply:
                time.sleep(0.2)  # pace the write calls; no-op in dry-run (no writes)

    print(json.dumps(summary, indent=2))

    if shadow:
        shadow.write(json.dumps({"event": "outcome", "ts": int(time.time()), **summary}) + "\n")
        shadow.flush()
        shadow.close()
        print(f"shadow log: {shadow_path}", file=sys.stderr)
    elif not args.apply:
        print("DRY-RUN — no writes. Re-run with --apply to enact.", file=sys.stderr)

    return 3 if summary["failures"] else 0


if __name__ == "__main__":
    sys.exit(main())
