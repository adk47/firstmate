#!/usr/bin/env python3
"""
Scan all HYDRA agent channels and DMs for unanswered @mentions.
Called by openclaw-watchdog.sh every tick (before its idle exit).
Outputs one line per unanswered message for Slack notification.

A mention counts as unanswered when it is at least GRACE_MIN old, no bot posted
a later top-level message, the scanned bot's own id is not in the parent's
reply_users (agents answer in thread; another bot's reply does not count), and
it has not been reported before (STATE_PATH).

The scan only PRINTS and records the keys it printed in STATE_PATH.pending; it
never advances STATE_PATH itself, because the caller's Slack send can fail
silently and a mention marked paged before delivery is lost for good. The
watchdog runs `scan-unanswered.py --commit` after a confirmed send.

`--no-dedup` lists every currently-unanswered mention (grace and thread-reply
rules still apply) without consulting or writing the page-once state; the
auto-retrigger and the post-restart report use it so that having been paged
does not hide a mention from them.
"""
import json
import os
import urllib.request
import time
import sys

CONFIG_PATH = "/root/.openclaw/openclaw.json"
LOOKBACK_HOURS = 2  # How far back to scan for unanswered messages
GRACE_MIN = 10  # Younger mentions may still be in flight; don't page on them
STATE_PATH = os.environ.get("UNANSWERED_STATE_PATH", "/var/lib/openclaw-watchdog/unanswered-paged.json")


def load_paged(now):
    """Return {"channel:ts": paged_epoch}, pruned to LOOKBACK_HOURS. Corrupt -> {}."""
    try:
        with open(STATE_PATH) as f:
            data = json.load(f)
        if not isinstance(data, dict):
            raise ValueError("state is not an object")
    except FileNotFoundError:
        return {}
    except Exception as e:
        print("unanswered-paged state unreadable (%s): starting empty" % e, file=sys.stderr)
        return {}
    cutoff = now - LOOKBACK_HOURS * 3600
    return {k: v for k, v in data.items() if isinstance(k, str) and ":" in k
            and _ts_of(k) >= cutoff}


def _ts_of(key):
    try:
        return float(key.rsplit(":", 1)[1])
    except ValueError:
        return 0.0


def _write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)


def commit():
    """Mark the keys of the last scan as paged. Call only after the page was delivered."""
    pending_path = STATE_PATH + ".pending"
    try:
        with open(pending_path) as f:
            pending = json.load(f)
    except FileNotFoundError:
        return
    paged = load_paged(time.time())
    paged.update(pending)
    _write_json(STATE_PATH, paged)
    os.remove(pending_path)


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
    now = time.time()
    oldest = str(int(now) - LOOKBACK_HOURS * 3600)
    no_dedup = "--no-dedup" in sys.argv[1:]
    paged = {} if no_dedup else load_paged(now)
    pending = {}
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
                        msg_ts = float(msg.get("ts", 0))
                        if now - msg_ts < GRACE_MIN * 60:
                            continue
                        # Agents reply in thread: THIS bot in reply_users answered it
                        # (another bot replying to a shared mention must not mask it)
                        bot_replied = my_bot_id in msg.get("reply_users", [])
                        for j in range(i + 1, len(msgs_chrono)):
                            later = msgs_chrono[j]
                            if later.get("user") == my_bot_id or later.get("user") in bot_ids:
                                bot_replied = True
                                break
                        if not bot_replied:
                            page_key = ch_id + ":" + str(msg.get("ts", ""))
                            if page_key in paged:
                                continue
                            pending[page_key] = now
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
    if no_dedup:
        return
    # Overwrite every run: the pending set is exactly what this run printed.
    try:
        if pending:
            _write_json(STATE_PATH + ".pending", pending)
        elif os.path.exists(STATE_PATH + ".pending"):
            os.remove(STATE_PATH + ".pending")
    except OSError as e:
        print("cannot write unanswered pending state: %s" % e, file=sys.stderr)


if __name__ == "__main__":
    if "--commit" in sys.argv[1:]:
        commit()
    else:
        main()
