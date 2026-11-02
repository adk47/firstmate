#!/usr/bin/env python3
"""
Win-Back Reply Scanner
Checks Gmail for replies to win-back emails, posts to Slack, updates GHL.
Run 3x daily via cron.
"""

import json
import os
import subprocess
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

GHL_KEY = os.environ.get("GHL_WINBACK_API_KEY", "")  # was hardcoded; env var since MUS-20329
GHL_LOCATION = "fmK5Vl9sJv49WTYA0QyP"
GHL_PIPELINE = "AZa8jK5S7UyQ0fqfxzyB"
GHL_STAGES = {
    "replied": "73b66a22-98cb-47a5-b4fd-3b558394cc7b",
    "resubscribed": "e51bd206-edec-4bb5-b344-39b2d96cd39e",
}
GMAIL_ACCOUNT = "a@muso.ai"
GMAIL_LABEL = "Win-Back Pro"
STATE_FILE = Path.home() / ".openclaw/workspace/memory/winback-reply-state.json"
LOG_DIR = Path.home() / ".openclaw/workspace/api-logs/gmail"


def gog_cmd(args, timeout=15):
    cmd = ["gog"] + args + ["--account", GMAIL_ACCOUNT]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return result.stdout, result.stderr, result.returncode


def ghl_api(method, endpoint, data=None):
    import urllib.request
    url = f"https://services.leadconnectorhq.com{endpoint}"
    if "?" in url:
        url += f"&locationId={GHL_LOCATION}"
    else:
        url += f"?locationId={GHL_LOCATION}"

    headers = {
        "Authorization": f"Bearer {GHL_KEY}",
        "Version": "2021-07-28",
        "User-Agent": "muso-hydra-ghl/1.0 (+ops@muso.ai)",  # urllib's default UA gets Cloudflare 403 1010 (MUS-20329)
        "Accept": "application/json",
    }
    if data:
        headers["Content-Type"] = "application/json"
        body = json.dumps(data).encode()
    else:
        body = None

    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read())
    except Exception as e:
        print(f"GHL error: {e}")
        return None


def load_state():
    if STATE_FILE.exists():
        with open(STATE_FILE) as f:
            return json.load(f)
    return {"last_scan": None, "known_reply_ids": []}


def save_state(state):
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(STATE_FILE, "w") as f:
        json.dump(state, f, indent=2)


def scan_replies():
    """Scan Gmail for replies to win-back emails."""
    state = load_state()

    # Search for replies in Win-Back threads
    # Look for emails TO a@muso.ai that are replies in Win-Back labeled threads
    out, err, rc = gog_cmd([
        "gmail", "list",
        "--query", f"label:{GMAIL_LABEL} is:inbox -from:a@muso.ai newer_than:1d",
        "-j"
    ], timeout=15)

    if rc != 0:
        # Try alternative search
        out, err, rc = gog_cmd([
            "gmail", "list",
            "--query", "to:a@muso.ai subject:(Muso OR credits OR profile) newer_than:1d -from:a@muso.ai",
            "-j"
        ], timeout=15)

    if rc != 0:
        print(f"Gmail search error: {err}")
        return []

    try:
        messages = json.loads(out)
    except:
        print("No messages found or parse error")
        return []

    known_ids = set(state.get("known_reply_ids", []))
    new_replies = []

    for msg in messages.get("messages", []):
        msg_id = msg.get("id", "")
        if msg_id in known_ids:
            continue

        # Get message details
        out2, _, rc2 = gog_cmd(["gmail", "get", msg_id, "-j"], timeout=10)
        if rc2 != 0:
            continue

        try:
            detail = json.loads(out2)
        except:
            continue

        sender = detail.get("from", "")
        subject = detail.get("subject", "")
        snippet = detail.get("snippet", "")[:200]
        date = detail.get("date", "")

        new_replies.append({
            "id": msg_id,
            "from": sender,
            "subject": subject,
            "snippet": snippet,
            "date": date,
        })
        known_ids.add(msg_id)

    # Update state
    state["last_scan"] = datetime.now(timezone.utc).isoformat()
    state["known_reply_ids"] = list(known_ids)[-500:]  # Keep last 500
    save_state(state)

    return new_replies


def update_ghl_on_reply(sender_email):
    """Move GHL opportunity to Replied stage."""
    # Search for contact by email
    result = ghl_api("GET", f"/contacts/lookup?email={sender_email}")
    if not result or not result.get("contacts"):
        return False

    contact_id = result["contacts"][0]["id"]

    # Search for opportunity
    result = ghl_api("GET", f"/opportunities/search?contact_id={contact_id}&pipeline_id={GHL_PIPELINE}")
    if not result or not result.get("opportunities"):
        return False

    opp = result["opportunities"][0]
    opp_id = opp["id"]

    # Move to Replied
    ghl_api("PUT", f"/opportunities/{opp_id}", {
        "pipelineStageId": GHL_STAGES["replied"],
    })

    return True


def require_ghl_key():
    """Fail closed before any side effect when the GHL key is not in the environment (MUS-20382)."""
    if not GHL_KEY:
        sys.exit("GHL_WINBACK_API_KEY is not set; refusing to run (no email, sheet or GHL call made).")


def main():
    require_ghl_key()
    print(f"Win-Back Reply Scanner - {datetime.now().strftime('%Y-%m-%d %H:%M')}")
    replies = scan_replies()

    if not replies:
        print("No new replies found.")
        # Stay silent per Fede's rule
        return

    print(f"Found {len(replies)} new replies!")

    for reply in replies:
        print(f"  From: {reply['from']}")
        print(f"  Subject: {reply['subject']}")
        print(f"  Snippet: {reply['snippet'][:100]}")

        # Extract email from "from" field
        sender_email = reply["from"]
        if "<" in sender_email:
            sender_email = sender_email.split("<")[1].rstrip(">")

        # Update GHL
        ghl_updated = update_ghl_on_reply(sender_email)

        # Log
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        today = datetime.now().strftime("%Y-%m-%d")
        with open(LOG_DIR / f"{today}.jsonl", "a") as f:
            f.write(json.dumps({
                "action": "winback_reply_detected",
                "from": reply["from"],
                "subject": reply["subject"],
                "ghl_updated": ghl_updated,
                "timestamp": datetime.now(timezone.utc).isoformat(),
            }) + "\n")

    # Output for Slack notification (picked up by cron)
    summary = {
        "replies": replies,
        "count": len(replies),
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }
    with open("/tmp/winback_replies.json", "w") as f:
        json.dump(summary, f, indent=2)

    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
