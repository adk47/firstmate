#!/usr/bin/env python3
"""
After an outage recovery, re-trigger unanswered @mentions so the
live agents actually process and respond to them.

Called by openclaw-watchdog.sh after successful restart.

BINDING RULE: Uses the OpenClaw chat completions API to invoke
each agent directly — no cross-bot Slack posting. Each agent runs
as itself and posts to the correct channel using its own token.
This prevents binding confusion.
"""
import json
import urllib.request
import time
import sys
import re

CONFIG_PATH = "/root/.openclaw/openclaw.json"
LOOKBACK_HOURS = 4
GW_URL = "http://localhost:18789/v1/chat/completions"

def load_config():
    with open(CONFIG_PATH) as f:
        return json.load(f)

def slack_api(token, method, params=""):
    url = "https://slack.com/api/" + method
    if params:
        url += "?" + params
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
    return json.loads(urllib.request.urlopen(req, timeout=10).read())

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

def invoke_agent(agent_id, prompt, gw_token):
    """Invoke an agent via the OpenClaw chat completions API."""
    payload = {
        "model": "openclaw/" + agent_id,
        "messages": [{"role": "user", "content": prompt}]
    }
    data = json.dumps(payload).encode()
    req = urllib.request.Request(GW_URL, data=data,
        headers={
            "Authorization": "Bearer " + gw_token,
            "Content-Type": "application/json"
        })
    try:
        resp = urllib.request.urlopen(req, timeout=300)
        result = json.loads(resp.read())
        content = result.get("choices", [{}])[0].get("message", {}).get("content", "")
        return True, content[:200]
    except Exception as e:
        return False, str(e)[:200]

def main():
    error_reason = sys.argv[1] if len(sys.argv) > 1 else "a technical issue"
    if "overloaded" in error_reason.lower():
        reason_text = "our AI provider was experiencing high load"
    elif "internal server error" in error_reason.lower():
        reason_text = "our AI provider had a service disruption"
    else:
        reason_text = "a technical issue with our AI service"

    config = load_config()
    gw_token = config.get("gateway", {}).get("auth", {}).get("token", "")
    accounts = ["clio", "ceo", "cmo", "cto", "qa", "finance", "operations", "devops", "design", "support"]
    oldest = str(int(time.time()) - LOOKBACK_HOURS * 3600)
    user_cache = {}

    # Build bot mapping
    bot_ids = set()
    tokens = {}
    bot_to_acct = {}
    acct_to_bot = {}
    for acct in accounts:
        token = config.get("channels", {}).get("slack", {}).get("accounts", {}).get(acct, {}).get("botToken", "")
        if not token:
            continue
        tokens[acct] = token
        try:
            bid = slack_api(token, "auth.test").get("user_id", "")
            bot_ids.add(bid)
            bot_to_acct[bid] = acct
            acct_to_bot[acct] = bid
        except Exception:
            pass

    seen = set()
    retriggered = 0

    for acct in accounts:
        token = tokens.get(acct, "")
        if not token:
            continue

        my_bot_id = acct_to_bot.get(acct, "")
        if not my_bot_id:
            continue

        for conv_type in ["public_channel,private_channel", "im", "mpim"]:
            try:
                resp = slack_api(token, "users.conversations",
                    "types=" + conv_type + "&limit=200&exclude_archived=true")
            except Exception:
                continue

            for ch in resp.get("channels", []):
                ch_id = ch.get("id", "")
                dedup_key = acct + ":" + ch_id
                if dedup_key in seen:
                    continue
                seen.add(dedup_key)

                ch_name = ch.get("name", "DM")

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

                    if sender in bot_ids or msg.get("bot_id"):
                        continue

                    if my_bot_id and ("<@" + my_bot_id + ">" in text):
                        bot_replied = False
                        for j in range(i + 1, len(msgs_chrono)):
                            later = msgs_chrono[j]
                            if later.get("user") == my_bot_id:
                                bot_replied = True
                                break
                        if not bot_replied:
                            name = get_user_name(token, sender, user_cache)
                            snippet = re.sub(r'<@[A-Z0-9]+>', '', text).strip()[:150]

                            # Use chat completions API to invoke the correct agent
                            prompt = (
                                "You were offline due to " + reason_text + " and missed this message. "
                                "Please respond now.\n\n"
                                "From: " + name + " in #" + ch_name + " (channel " + ch_id + ")\n"
                                "Message: " + snippet + "\n\n"
                                "Respond to " + name + " in #" + ch_name + ". "
                                "Briefly acknowledge the delay, then answer their request."
                            )

                            ok, result = invoke_agent(acct, prompt, gw_token)
                            status = "OK" if ok else "FAILED"
                            print(status + " @" + acct + " for " + name + " in #" + ch_name)
                            if ok:
                                retriggered += 1

    print("Retriggered " + str(retriggered) + " unanswered requests")

if __name__ == "__main__":
    main()
