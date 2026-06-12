#!/usr/bin/env python3
"""
Post outage notice to #clio_devops ONLY.
Called by openclaw-watchdog.sh BEFORE restarting the gateway.

Previously posted to ALL channels with recent human activity.
Restricted to devops only per Aaron directive (2026-03-27).

Sends via `muso slack send` (the gated CLI, issue #5 PR1) as the devops bot,
falling back to clio — same identity order as the old urllib sender. The CLI
reads MUSO_SLACK_BOT_TOKEN_<BOT> from the environment; the watchdog runs
outside main.env, so the slack vars are pulled from MUSO_SLACK_ENV_FILE
(default /etc/openclaw/main.env) when missing.
"""
import os
import re
import shutil
import subprocess
import sys
import time

MUSO_BIN = os.environ.get("MUSO_BIN", "muso")
# The watchdog runs from /etc/cron.d with cron's default PATH (/usr/bin:/bin),
# which excludes /usr/local/bin where deploy.sh installs muso.
if MUSO_BIN == "muso" and shutil.which("muso") is None \
        and os.access("/usr/local/bin/muso", os.X_OK):
    MUSO_BIN = "/usr/local/bin/muso"
MUSO_SLACK_ENV_FILE = os.environ.get("MUSO_SLACK_ENV_FILE", "/etc/openclaw/main.env")
DEVOPS_CHANNEL = "C0ADV2W76G4"  # #clio_devops — the ONLY channel to notify
OUTAGE_NOTICE_FILE = "/tmp/openclaw-outage-notice-sent"
NOTICE_COOLDOWN_MIN = 30


def load_slack_env():
    """Export MUSO_SLACK_* vars from main.env when the session lacks them.

    No early return on the devops token being present: the clio fallback
    needs MUSO_SLACK_BOT_TOKEN_CLIO too, and setdefault never clobbers
    deliberate overrides from the caller's environment.
    """
    try:
        with open(MUSO_SLACK_ENV_FILE) as f:
            for line in f:
                m = re.match(r"^(MUSO_(?:SLACK_[A-Z_]+|STATE_DIR))=(.*)$",
                             line.rstrip("\n"))
                if not m:
                    continue
                val = m.group(2)
                # The bash twin evals these lines, which strips shell quotes;
                # match that for quoted env-file values.
                if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
                    val = val[1:-1]
                os.environ.setdefault(m.group(1), val)
    except OSError:
        pass  # can't notify without tokens; handled by the send failing


def slack_post(bot, channel, text):
    """One gated send; muso exits 0 only on a Slack-confirmed post.

    Never raises: a missing/hung muso must fall through to the next bot and
    still reach the cooldown write (the old urllib sender returned False on
    any exception, and the watchdog caller swallows our exit code anyway).
    """
    try:
        res = subprocess.run(
            [MUSO_BIN, "slack", "send", "--bot", bot,
             "--channel", channel, "--text", text,
             "--requester", "outage-notify@hydra-ops"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return False
    return res.returncode == 0


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

    load_slack_env()

    notice_msg = (
        ":construction: *Heads up* — Agents are currently experiencing issues due to "
        + reason
        + ". They may not be able to respond right now. "
        "Systems are auto-recovering and should be back shortly."
    )

    # devops preferred, clio fallback — same order as the old token lookup.
    if slack_post("devops", DEVOPS_CHANNEL, notice_msg) or \
            slack_post("clio", DEVOPS_CHANNEL, notice_msg):
        print("Outage notice posted to #clio_devops")
    else:
        print("Failed to post outage notice to #clio_devops")

    # Record send time for cooldown
    with open(OUTAGE_NOTICE_FILE, "w") as f:
        f.write(str(int(time.time())))


if __name__ == "__main__":
    main()
