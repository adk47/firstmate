#!/usr/bin/env python3
"""Read-only Intercom check: did an admin/teammate reply to <email> AFTER <ts>?

Exit codes:
  0  = customer was told (admin reply found after ts)
  1  = customer was NOT told
  2  = network / auth error (treat as 'unknown'; caller should skip closure)

Env: MUSOAI_INTERCOM_TOKEN required.
Args: <email> <merge_at_iso_or_postgres_ts>
"""
import json, os, sys, urllib.request, urllib.error, datetime as dt

INTERCOM = "https://api.intercom.io"

def parse_ts(s):
    s = s.strip().rstrip("Z")
    # Accept "2026-05-15 16:08:22.167000 UTC" or ISO-ish.
    s = s.replace(" UTC", "").replace("T", " ")
    return int(dt.datetime.strptime(s[:19], "%Y-%m-%d %H:%M:%S").replace(tzinfo=dt.timezone.utc).timestamp())

def api(method, path, body=None, token=None):
    req = urllib.request.Request(f"{INTERCOM}{path}", method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/json")
    data = None
    if body is not None:
        req.add_header("Content-Type", "application/json")
        data = json.dumps(body).encode()
    with urllib.request.urlopen(req, data=data, timeout=30) as r:
        return json.loads(r.read())

def main():
    if len(sys.argv) < 3:
        print("usage: check-customer-replied.py <email> <merge_at>", file=sys.stderr)
        sys.exit(2)
    email, merge_at = sys.argv[1], sys.argv[2]
    token = os.environ.get("MUSOAI_INTERCOM_TOKEN")
    if not token:
        print("MUSOAI_INTERCOM_TOKEN not set", file=sys.stderr)
        sys.exit(2)
    merge_unix = parse_ts(merge_at)

    try:
        convs = api("POST", "/conversations/search", {
            "query": {"field": "source.author.email", "operator": "=", "value": email},
        }, token=token)
    except urllib.error.HTTPError as e:
        print(f"intercom search failed for {email}: HTTP {e.code}", file=sys.stderr)
        sys.exit(2)
    except Exception as e:
        print(f"intercom search failed for {email}: {e}", file=sys.stderr)
        sys.exit(2)

    cand = sorted(convs.get("conversations", []),
                  key=lambda c: c.get("updated_at", 0), reverse=True)[:5]
    for c in cand:
        try:
            d = api("GET", f"/conversations/{c['id']}?display_as=plaintext", token=token)
        except urllib.error.HTTPError as e:
            # 5xx burst on the conv that holds the admin reply would otherwise
            # silently flip the audit to "not told" and stash a duplicate reply
            # in the operator's queue. Escalate as exit 2 (transport error) so
            # the close-merged-tickets caller treats this as audit_error and
            # keeps the ticket open.
            if 500 <= e.code < 600:
                print(f"check-customer-replied: HTTP {e.code} on conv {c['id']}; "
                      f"treating as audit error", file=sys.stderr)
                sys.exit(2)
            # 4xx (e.g., 404 archived) is a normal "skip this conv" — admin
            # reply can't live somewhere we can't read.
            continue
        except urllib.error.URLError as e:
            print(f"check-customer-replied: network error on conv {c['id']}: {e}",
                  file=sys.stderr)
            sys.exit(2)
        for p in d.get("conversation_parts", {}).get("conversation_parts", []):
            who = p.get("author", {}).get("type", "")
            t_at = p.get("created_at", 0)
            if who in ("admin", "team") and t_at > merge_unix:
                # Print a one-line diagnostic to stderr so the sweep can log.
                print(f"customer-replied: {email} got admin reply in conv {c['id']} "
                      f"at {dt.datetime.fromtimestamp(t_at, tz=dt.timezone.utc).isoformat()}",
                      file=sys.stderr)
                sys.exit(0)
    print(f"customer-replied: {email} has NO admin reply after {merge_at}", file=sys.stderr)
    sys.exit(1)

if __name__ == "__main__":
    main()
