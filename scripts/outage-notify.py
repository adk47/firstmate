#!/usr/bin/env python3
"""
Post outage notice to #clio_devops ONLY.
Called by openclaw-watchdog.sh BEFORE restarting the gateway.

Previously posted to ALL channels with recent human activity.
Restricted to devops only per Aaron directive (2026-03-27).
"""
import json
import urllib.request
import time
import sys
import os

CONFIG_PATH = "/root/.openclaw/openclaw.json"
DEVOPS_CHANNEL = "C0ADV2W76G4"  # #clio_devops — the ONLY channel to notify
OUTAGE_NOTICE_FILE = "/tmp/openclaw-outage-notice-sent"
NOTICE_COOLDOWN_MIN = 30


def load_config():
    with open(CONFIG_PATH) as f:
        return json.load(f)


def slack_post(token, channel, text):
    data = json.dumps({"channel": channel, "text": text}).encode()
    req = urllib.request.Request(
        "https://slack.com/api/chat.postMessage",
        data=data,
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
    try:
        return json.loads(urllib.request.urlopen(req, timeout=10).read()).get("ok", False)
    except Exception:
        return False


def main():
    error_hint = sys.argv[1] if len(sys.argv) > 1 else "unknown error"
    if "overloaded" in error_hint.lower():
        reason = "our AI provider (Anthropic) is experiencing high load"
    elif "internal server error" in error_hint.lower() or "api_error" in error_hint.lower():
        reason = "our AI provider (Anthropic) is experiencing service issues"
    else:
        reason = "a technical issue with our AI service"

    # Cooldown check
    if os.path.exists(OUTAGE_NOTICE_FILE):
        mtime = os.path.getmtime(OUTAGE_NOTICE_FILE)
        if (time.time() - mtime) / 60 < NOTICE_COOLDOWN_MIN:
            print("Outage notice cooldown active - skipping")
            return

    config = load_config()

    # Get devops bot token (preferred) or fall back to clio
    accts = config.get("channels", {}).get("slack", {}).get("accounts", {})
    token = (accts.get("devops", {}).get("botToken", "")
             or accts.get("clio", {}).get("botToken", ""))

    if not token:
        print("No bot token found — skipping notification")
        return

    notice_msg = (
        ":construction: *Heads up* \u2014 Agents are currently experiencing issues due to "
        + reason
        + ". They may not be able to respond right now. "
        "Systems are auto-recovering and should be back shortly."
    )

    if slack_post(token, DEVOPS_CHANNEL, notice_msg):
        print("Outage notice posted to #clio_devops")
    else:
        print("Failed to post outage notice to #clio_devops")

    # Record send time for cooldown
    with open(OUTAGE_NOTICE_FILE, "w") as f:
        f.write(str(int(time.time())))


if __name__ == "__main__":
    main()
