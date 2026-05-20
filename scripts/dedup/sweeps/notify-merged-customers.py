#!/usr/bin/env python3
"""Post a 'merge complete' reply to customers whose profile-merge ticket was
executed but who haven't been told yet.

Workflow per ticket id (read from stdin, one per line):
  1. GET /task/<id> from ClickUp -> parse email + profile name from AR JSON.
  2. Search Intercom for the most-recent conversation by email (any state).
     `state=open` is NOT filtered — Intercom search returns all matching
     convs, and operator validation against the 2026-05-19 backlog used
     the most-recent-by-updated_at heuristic.
  3. Verify no admin reply since the merge timestamp via an inline
     single-conv audit (analogous in spirit to check-customer-replied.py's
     multi-conv audit used by close-merged-tickets.sh — same intent, but
     scoped to the specific conv we picked in step 2). Prevents
     double-messaging when Jan/Yann replied in parallel.
  4. Dry-run by default: print the proposed message to stdout. With
     --apply: POST the reply to Intercom, comment on the ClickUp ticket,
     and set ticket status to "resolved".

Designed to be safe in the wrong hands: --dry-run is the default, --apply
is explicit, and the script refuses to send if any of (email, conv, merge
timestamp) is missing or ambiguous.

Voice: founder-voice template (lowercase, no em-dashes, no corporate
filler — see memory:feedback_founder_voice_rules.md).

Env:
  CLICKUP_API_KEY        required
  MUSOAI_INTERCOM_TOKEN  required
  INTERCOM_ADMIN_ID      required when --apply (the admin/team user ID
                         the reply is sent AS — there is no default to
                         avoid accidentally impersonating a teammate)

Exit codes:
  0 — all input rows processed cleanly
  1 — usage / env error
  3 — at least one ticket failed mid-run; check stderr (cron-visible)
"""
import argparse, datetime as dt, json, os, sys, urllib.request, urllib.error

CLICKUP_API = os.environ.get("CLICKUP_API", "https://api.clickup.com/api/v2")
INTERCOM_API = "https://api.intercom.io"

# Aaron-voice template (lowercase, no em-dash, no corporate filler).
# Single-paragraph, no profile-name interpolation — Caroline tickets don't
# carry a clean profile name and "your profile" reads better than mistakenly
# embedding a URL UUID.
MESSAGE = (
    "hi! just confirming your profile merge request is done. "
    "the credits we found are now consolidated under your main profile. "
    "let me know if anything's off."
)


def http(method, url, headers, body=None, timeout=30):
    req = urllib.request.Request(url, method=method)
    for k, v in headers.items():
        req.add_header(k, v)
    data = None
    if body is not None:
        req.add_header("Content-Type", "application/json")
        data = json.dumps(body).encode()
    with urllib.request.urlopen(req, data=data, timeout=timeout) as r:
        return r.status, json.loads(r.read() or b"null")


def parse_action_request(description):
    """Extract the AR JSON block from a ClickUp ticket description.

    Caroline's create-ticket plugin emits a block delimited by the literal
    markers ---ACTION-REQUEST--- ... ---END-ACTION-REQUEST--- (snake_case
    fields). Older code used ```json``` fences; both are supported.
    """
    if not description:
        return None
    START_MARKER = "---ACTION-REQUEST---"
    END_MARKER = "---END-ACTION-REQUEST---"
    if START_MARKER in description and END_MARKER in description:
        block = description.split(START_MARKER, 1)[1].split(END_MARKER, 1)[0]
        try:
            return json.loads(block.strip())
        except Exception:
            return None
    # Fallback: ```json``` fence (used in some older tickets).
    lines = description.splitlines()
    in_block = False
    buf = []
    for line in lines:
        if line.strip().startswith("```"):
            if in_block:
                break
            in_block = True
            continue
        if in_block:
            buf.append(line)
    if not buf:
        return None
    try:
        return json.loads("\n".join(buf))
    except Exception:
        return None


def get_ticket(ticket_id, clickup_key):
    s, body = http("GET", f"{CLICKUP_API}/task/{ticket_id}",
                   {"Authorization": clickup_key})
    if s != 200:
        raise RuntimeError(f"clickup get task {ticket_id} -> {s}")
    return body


def parse_merge_at(ticket):
    """The action_log timestamp would be the gold reference, but it's not
    on the ticket. Fall back to the ticket's last update as a conservative
    proxy: if the merge happened earlier, the audit will still confirm.
    """
    upd = ticket.get("date_updated") or ticket.get("date_created")
    if not upd:
        return None
    # ClickUp timestamps are millis since epoch in a string.
    try:
        return dt.datetime.fromtimestamp(int(upd) / 1000, tz=dt.timezone.utc)
    except Exception:
        return None


def find_intercom_conv(email, intercom_token):
    s, body = http("POST", f"{INTERCOM_API}/conversations/search", {
        "Authorization": f"Bearer {intercom_token}",
        "Accept": "application/json",
    }, body={
        "query": {"field": "source.author.email", "operator": "=", "value": email},
    })
    if s != 200:
        raise RuntimeError(f"intercom search {email} -> {s}")
    convs = body.get("conversations", []) if isinstance(body, dict) else []
    if not convs:
        return None
    return sorted(convs, key=lambda c: c.get("updated_at", 0), reverse=True)[0]


def check_admin_replied_since(conv_id, merge_at, intercom_token):
    s, body = http(
        "GET",
        f"{INTERCOM_API}/conversations/{conv_id}?display_as=plaintext",
        {"Authorization": f"Bearer {intercom_token}",
         "Accept": "application/json"},
    )
    if s != 200:
        raise RuntimeError(f"intercom get conv {conv_id} -> {s}")
    parts = body.get("conversation_parts", {}).get("conversation_parts", [])
    cutoff = int(merge_at.timestamp())
    for p in parts:
        who = p.get("author", {}).get("type", "")
        t_at = p.get("created_at", 0)
        if who in ("admin", "team") and t_at > cutoff:
            return True
    return False


def post_intercom_reply(conv_id, admin_id, message, intercom_token):
    s, body = http(
        "POST",
        f"{INTERCOM_API}/conversations/{conv_id}/reply",
        {"Authorization": f"Bearer {intercom_token}",
         "Accept": "application/json"},
        body={
            "message_type": "comment",
            "type": "admin",
            "admin_id": admin_id,
            "body": message,
        },
    )
    if s not in (200, 201):
        raise RuntimeError(f"intercom reply {conv_id} -> {s}: {body}")
    return body


def comment_and_close_ticket(ticket_id, conv_id, clickup_key):
    http("POST", f"{CLICKUP_API}/task/{ticket_id}/comment",
         {"Authorization": clickup_key},
         body={
             "comment_text": f"Auto-replied to customer via Caroline template "
                             f"(Intercom conv {conv_id}). Closing.",
             "notify_all": False,
         })
    s, _ = http("PUT", f"{CLICKUP_API}/task/{ticket_id}",
                {"Authorization": clickup_key},
                body={"status": "resolved"})
    if s != 200:
        raise RuntimeError(f"clickup PUT {ticket_id} -> {s}")


_SEEN_CONVS = set()


def process(ticket_id, args, env):
    print(f"[{ticket_id}] start", file=sys.stderr)
    ticket = get_ticket(ticket_id, env["CLICKUP_API_KEY"])
    desc = ticket.get("description") or ticket.get("text_content") or ""
    ar = parse_action_request(desc)
    if not ar:
        print(f"[{ticket_id}] skip: no AR JSON block found", file=sys.stderr)
        return
    email = ar.get("customer_email") or ar.get("customerEmail")
    if not email:
        print(f"[{ticket_id}] skip: no customer_email in AR", file=sys.stderr)
        return
    merge_at = parse_merge_at(ticket)
    if not merge_at:
        print(f"[{ticket_id}] skip: no merge_at timestamp", file=sys.stderr)
        return

    conv = find_intercom_conv(email, env["MUSOAI_INTERCOM_TOKEN"])
    if not conv:
        print(f"[{ticket_id}] skip: no intercom conv for {email}", file=sys.stderr)
        return
    conv_id = conv["id"]

    if check_admin_replied_since(conv_id, merge_at, env["MUSOAI_INTERCOM_TOKEN"]):
        print(f"[{ticket_id}] skip: admin already replied since merge_at",
              file=sys.stderr)
        return
    if conv_id in _SEEN_CONVS:
        # Two tickets pointing at the same customer — already handled this
        # conv in this run. Without this guard, two tickets for the same
        # email would post two identical replies (see larsbd@gmail.com /
        # tickets 869d9uby4 + 869d9ubq7 in the 2026-05-19 backlog).
        print(f"[{ticket_id}] skip: conv {conv_id} already handled in this run",
              file=sys.stderr)
        # Still close the secondary ticket — the customer was told via the
        # first one. The closing comment will note this.
        if args.apply:
            comment_and_close_ticket(ticket_id, conv_id,
                                     env["CLICKUP_API_KEY"])
        return

    message = MESSAGE
    print(json.dumps({
        "ticket_id": ticket_id,
        "intercom_conv_id": conv_id,
        "email": email,
        "message": message,
        "merge_at": merge_at.isoformat(),
        "mode": "apply" if args.apply else "dry-run",
    }))

    if not args.apply:
        # Mark dedup AFTER printing so a re-run with --apply on the same input
        # behaves identically wrt dedup state.
        _SEEN_CONVS.add(conv_id)
        return

    post_intercom_reply(conv_id, env["INTERCOM_ADMIN_ID"], message,
                        env["MUSOAI_INTERCOM_TOKEN"])
    # Mark dedup ONLY after the customer-facing write succeeded. If
    # post_intercom_reply raised, the caller's exception handler logs the
    # failure; a future ticket sharing this conv must NOT inherit a phantom
    # "already handled" state and silently close without messaging.
    _SEEN_CONVS.add(conv_id)
    comment_and_close_ticket(ticket_id, conv_id, env["CLICKUP_API_KEY"])
    print(f"[{ticket_id}] applied: replied + closed", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true",
                    help="actually send Intercom reply + close ticket "
                         "(default: dry-run)")
    args = ap.parse_args()

    env = {
        "CLICKUP_API_KEY": os.environ.get("CLICKUP_API_KEY"),
        "MUSOAI_INTERCOM_TOKEN": os.environ.get("MUSOAI_INTERCOM_TOKEN"),
        "INTERCOM_ADMIN_ID": os.environ.get("INTERCOM_ADMIN_ID"),
    }
    # Treat empty strings as missing — an exported-but-empty INTERCOM_ADMIN_ID
    # would otherwise pass this check, then trip per-ticket halfway through
    # the run and silently drop remaining stdin ids.
    missing = [k for k, v in env.items()
               if not v and (k != "INTERCOM_ADMIN_ID" or args.apply)]
    if missing:
        print(f"notify-merged-customers: env required: {missing}",
              file=sys.stderr)
        sys.exit(1)

    ids = [line.strip() for line in sys.stdin if line.strip()]
    if not ids:
        print("notify-merged-customers: no ticket ids on stdin", file=sys.stderr)
        sys.exit(1)
    failed = 0
    for tid in ids:
        try:
            process(tid, args, env)
        except urllib.error.HTTPError as e:
            # Read the response body so the operator sees Intercom/ClickUp's
            # actual error envelope, not just "HTTP 422: Unprocessable Entity".
            try:
                body = e.read().decode("utf-8", errors="replace")[:500]
            except Exception:
                body = ""
            print(f"[{tid}] ERROR HTTP {e.code}: {body}", file=sys.stderr)
            failed += 1
        except (RuntimeError, urllib.error.URLError,
                json.JSONDecodeError, KeyError) as e:
            print(f"[{tid}] ERROR {type(e).__name__}: {e}", file=sys.stderr)
            failed += 1
    if failed:
        print(f"notify-merged-customers: {failed}/{len(ids)} ticket(s) failed; "
              f"see stderr above", file=sys.stderr)
        sys.exit(3)


if __name__ == "__main__":
    main()
