#!/usr/bin/env python3
"""
Scan all HYDRA agent channels and DMs for unanswered @mentions.
Called by openclaw-watchdog.sh after auto-restart.
Outputs one line per unanswered message for Slack notification.
"""
import json
import urllib.request
import time
import sys

CONFIG_PATH = "/root/.openclaw/openclaw.json"
LOOKBACK_HOURS = 2  # How far back to scan for unanswered messages

def load_config():
    with open(CONFIG_PATH) as f:
        return json.load(f)

def slack_api(token, method, params=""):
    url = "https://slack.com/api/" + method
    if params:
        url += "?" + params
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
    resp = json.loads(urllib.request.urlopen(req, timeout=10).read())
    return resp

def get_bot_user_id(token):
    resp = slack_api(token, "auth.test")
    return resp.get("user_id", "")

def get_user_name(token, uid, cache):
    if uid in cache:
        return cache[uid]
    try:
        resp = slack_api(token, "users.info", "user=" + uid)
        name = resp.get("user", {}).get("real_name", uid)
    except Exception:
        name = uid
    cache[uid] = name
    return name

def main():
    config = load_config()
    accounts = ["clio", "ceo", "cmo", "cto", "qa", "finance", "operations", "devops", "scout"]
    oldest = str(int(time.time()) - LOOKBACK_HOURS * 3600)
    user_cache = {}

    # Collect all bot user IDs
    bot_ids = set()
    tokens = {}
    for acct in accounts:
        from lib.slack_token import resolve_secret
        token = resolve_secret(config.get("channels", {}).get("slack", {}).get("accounts", {}).get(acct, {}).get("botToken", ""))
        if not token:
            continue
        tokens[acct] = token
        try:
            bot_ids.add(get_bot_user_id(token))
        except Exception:
            pass

    unanswered = []
    seen_channels = set()

    for acct in accounts:
        token = tokens.get(acct, "")
        if not token:
            continue

        my_bot_id = ""
        try:
            my_bot_id = get_bot_user_id(token)
        except Exception:
            continue

        # Scan channels, DMs, group DMs
        for conv_type in ["public_channel,private_channel", "im", "mpim"]:
            try:
                resp = slack_api(token, "users.conversations",
                    "types=" + conv_type + "&limit=200&exclude_archived=true")
            except Exception:
                continue

            for ch in resp.get("channels", []):
                ch_id = ch.get("id", "")
                # Dedupe across bot accounts
                dedup_key = acct + ":" + ch_id
                if dedup_key in seen_channels:
                    continue
                seen_channels.add(dedup_key)

                ch_name = ch.get("name", "DM")
                if conv_type == "im":
                    ch_name = "DM"

                try:
                    hist = slack_api(token, "conversations.history",
                        "channel=" + ch_id + "&oldest=" + oldest + "&limit=50")
                except Exception:
                    continue

                msgs = hist.get("messages", [])
                if not msgs:
                    continue

                msgs_chrono = list(reversed(msgs))

                for i, msg in enumerate(msgs_chrono):
                    sender = msg.get("user", "")
                    text = msg.get("text", "")

                    # Skip bot messages
                    if sender in bot_ids or msg.get("bot_id"):
                        continue

                    # Check if this message mentions the bot
                    if my_bot_id and ("<@" + my_bot_id + ">" in text):
                        # Check if bot replied after
                        bot_replied = False
                        for j in range(i + 1, len(msgs_chrono)):
                            later = msgs_chrono[j]
                            if later.get("user") == my_bot_id or later.get("user") in bot_ids:
                                bot_replied = True
                                break
                        if not bot_replied:
                            ts = time.strftime("%H:%M", time.gmtime(float(msg.get("ts", 0))))
                            name = get_user_name(token, sender, user_cache)
                            snippet = text[:80].replace("\n", " ")
                            # Remove @mentions for cleaner output
                            import re
                            snippet = re.sub(r'<@[A-Z0-9]+>', '', snippet).strip()
                            unanswered.append(
                                "\u2022 @" + acct + " in #" + ch_name + " \u2014 " + name + " (" + ts + " UTC): " + snippet
                            )

    # Output for the watchdog to include in Slack message
    for line in unanswered:
        print(line)

if __name__ == "__main__":
    main()
