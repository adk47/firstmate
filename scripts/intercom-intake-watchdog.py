#!/usr/bin/env python3
"""Intercom intake-outage watchdog.

Catches the failure mode that silently stranded ~808 customers in April 2026:
inbound conversations kept arriving, but Caroline (the edge gateway / Intercom
plugin) stopped processing them for ~14 days after a missing-Service outage
(see memory:project_intercom_webhook_outage_2026-04-28). Nobody noticed until
a manual triage 6 weeks later. This watchdog turns "discover it in 6 weeks"
into "alert in a couple of hours".

Signal: over a recent, already-had-time-to-be-handled window, what fraction of
newly-created conversations got *processed* by Caroline? "Processed" = the
conversation has an `ai:*` tag (Caroline's own topic tags), OR an admin reply,
OR is no longer open (closed/snoozed). During the April outage that fraction
was ~0 against a healthy inbound volume — exactly what this flags.

We deliberately look at a window that ENDS `--grace` hours ago, so a normal
just-arrived conversation that simply hasn't been picked up yet does not count
as "unprocessed" and trip a false alarm.

Read-only against Intercom. The only side effect is an optional Slack post.

Usage:
  # assess current intake health, print only (no Slack):
  python3 scripts/intercom-intake-watchdog.py --check

  # assess and post to Slack if unhealthy (for cron):
  python3 scripts/intercom-intake-watchdog.py --alert

  # backtest: evaluate as-if at a past instant (proves it would have fired):
  python3 scripts/intercom-intake-watchdog.py --check --at 2026-04-20T12:00:00Z

Env:
  MUSOAI_INTERCOM_TOKEN   required — Intercom Bearer token.
  SLACK_BOT_TOKEN         optional — Slack bot token for --alert. If unset, the
                          devops bot token is read from the openclaw config
                          (channels.slack.accounts.devops.botToken), same as
                          scripts/outage-notify.py.
  OPENCLAW_CONFIG         optional — path to openclaw.json for token lookup.
                          Defaults try /root/.openclaw-main then /root/.openclaw.
  WATCHDOG_SLACK_CHANNEL  optional — Slack channel id; default C0ADV2W76G4
                          (#clio_devops).

Tunables (flags, with env fallbacks):
  --window-hours  N   length of the analysis window, ending --grace ago     (default 6, env WATCHDOG_WINDOW_HOURS)
  --grace-hours   N   end the window N hours before now (still being handled) (default 1, env WATCHDOG_GRACE_HOURS)
  --min-volume    N   don't judge a window with fewer than N convs        (default 5, env WATCHDOG_MIN_VOLUME)
  --min-processed F   alert if processed fraction < F                      (default 0.4, env WATCHDOG_MIN_PROCESSED)

Exit codes:
  0  ran cleanly (whether healthy, or unhealthy-and-alerted)
  1  usage / env error
  2  Intercom API error
"""
import argparse
import datetime as dt
import json
import os
import subprocess
import sys
import urllib.request
import urllib.error

INTERCOM_API = os.environ.get("INTERCOM_API", "https://api.intercom.io")
INTERCOM_VERSION = "2.11"


def _epoch(value):
    """Parse an --at value: an int epoch, or an ISO8601 string (Z or offset)."""
    if value is None:
        return int(dt.datetime.now(dt.timezone.utc).timestamp())
    try:
        return int(value)
    except (TypeError, ValueError):
        pass
    s = value.strip().replace("Z", "+00:00")
    parsed = dt.datetime.fromisoformat(s)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return int(parsed.timestamp())


def _intercom_search(token, body):
    req = urllib.request.Request(
        f"{INTERCOM_API}/conversations/search",
        data=json.dumps(body).encode(),
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "Intercom-Version": INTERCOM_VERSION,
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


def fetch_created_between(token, start_ts, end_ts):
    """All conversations created in [start_ts, end_ts), any current state."""
    convs = []
    after = None
    while True:
        body = {
            "query": {
                "operator": "AND",
                "value": [
                    {"field": "created_at", "operator": ">", "value": int(start_ts)},
                    {"field": "created_at", "operator": "<", "value": int(end_ts)},
                ],
            },
            "pagination": {"per_page": 150},
        }
        if after:
            body["pagination"]["starting_after"] = after
        data = _intercom_search(token, body)
        for c in data.get("conversations", []):
            created = c.get("created_at") or 0
            if start_ts <= created < end_ts:
                convs.append(c)
        nxt = (data.get("pages") or {}).get("next")
        after = nxt.get("starting_after") if isinstance(nxt, dict) else None
        if not nxt or not after:
            break
    return convs


def is_processed(conv):
    """Did Caroline/an admin actually engage this conversation?"""
    if conv.get("state") in ("closed", "snoozed"):
        return True
    stats = conv.get("statistics") or {}
    if (stats.get("last_admin_reply_at") or 0) != 0:
        return True
    tags = (conv.get("tags") or {}).get("tags", [])
    if any((t.get("name") or "").startswith("ai:") for t in tags):
        return True
    return False


def assess(token, at_ts, window_hours, grace_hours):
    # A window_hours-long window that ENDS grace_hours ago. Derive start from
    # the grace-adjusted end (not from at_ts) so the analyzed span is always
    # exactly window_hours regardless of grace. Anchoring start at at_ts would
    # shrink the span to (window_hours - grace_hours), and a grace >= window
    # would empty the window entirely — silently pinning the fraction at 1.0
    # and blinding the only tripwire for the outage class this catches.
    end_ts = at_ts - grace_hours * 3600
    start_ts = end_ts - window_hours * 3600
    convs = fetch_created_between(token, start_ts, end_ts)
    total = len(convs)
    processed = sum(1 for c in convs if is_processed(c))
    unprocessed = total - processed
    fraction = (processed / total) if total else 1.0
    oldest_unproc = None
    for c in convs:
        if not is_processed(c):
            age_h = (at_ts - (c.get("created_at") or at_ts)) / 3600
            oldest_unproc = max(oldest_unproc or 0, age_h)
    return {
        "at": at_ts,
        "window_start": start_ts,
        "window_end": end_ts,
        "total_created": total,
        "processed": processed,
        "unprocessed": unprocessed,
        "processed_fraction": round(fraction, 3),
        "oldest_unprocessed_hours": round(oldest_unproc, 1) if oldest_unproc else None,
    }


DEFAULT_SLACK_CHANNEL = "C0ADV2W76G4"  # #clio_devops (same as outage-notify.py)


def resolve_slack_token():
    """Bot token from $SLACK_BOT_TOKEN, else channels.slack.accounts.devops
    (or clio) botToken in the openclaw config — mirrors outage-notify.py."""
    tok = os.environ.get("SLACK_BOT_TOKEN")
    if tok:
        return tok
    candidates = [os.environ.get("OPENCLAW_CONFIG"),
                  "/root/.openclaw-main/openclaw.json",
                  "/root/.openclaw/openclaw.json"]
    for path in candidates:
        if not path or not os.path.exists(path):
            continue
        try:
            with open(path) as f:
                cfg = json.load(f)
        except (OSError, ValueError):
            continue
        accts = (cfg.get("channels", {}).get("slack", {}).get("accounts", {}))
        tok = (accts.get("devops", {}).get("botToken", "")
               or accts.get("clio", {}).get("botToken", ""))
        if tok:
            return tok
    return None


def slack_post(token, channel, text):
    req = urllib.request.Request(
        "https://slack.com/api/chat.postMessage",
        data=json.dumps({"channel": channel, "text": text}).encode(),
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        body = json.loads(resp.read())
    if not body.get("ok"):
        raise RuntimeError(f"Slack chat.postMessage failed: {body.get('error')}")
    return True


def _maintenance_active():
    """True iff a planned maintenance window is active. Delegates to the sibling
    scripts/hydra-maintenance.sh (which sources lib/maintenance-flag.sh) so the
    fail-safe expiry/malformed logic lives in ONE place instead of being
    re-implemented here. This watchdog pages on Intercom intake stalling, which is
    guaranteed whenever the edge gateway is stopped for a window — so it must
    honor the flag. Any failure to resolve or run the helper returns False: a
    broken guard must NEVER suppress the watchdog.
    """
    helper = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          "hydra-maintenance.sh")
    try:
        # Invoke via `bash <script>` (not the exec bit) so a lost +x on the helper
        # can't silently stop this watchdog honoring the window.
        return subprocess.run(
            ["bash", helper, "is-active"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=10,
        ).returncode == 0
    except Exception:  # noqa: BLE001 — fail-safe: any error => not in maintenance
        return False


def main():
    ap = argparse.ArgumentParser(description="Intercom intake-outage watchdog")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true",
                      help="assess and print only (default; no Slack)")
    mode.add_argument("--alert", action="store_true",
                      help="assess and post to Slack if unhealthy")
    ap.add_argument("--at", default=None,
                    help="evaluate as-if at this instant (epoch or ISO8601); default now")
    ap.add_argument("--window-hours", type=float,
                    default=float(os.environ.get("WATCHDOG_WINDOW_HOURS", "6")))
    ap.add_argument("--grace-hours", type=float,
                    default=float(os.environ.get("WATCHDOG_GRACE_HOURS", "1")))
    ap.add_argument("--min-volume", type=int,
                    default=int(os.environ.get("WATCHDOG_MIN_VOLUME", "5")))
    ap.add_argument("--min-processed", type=float,
                    default=float(os.environ.get("WATCHDOG_MIN_PROCESSED", "0.4")))
    args = ap.parse_args()

    # Stand down during a planned maintenance window: a stopped edge gateway
    # zeroes intake and would false-page this alarm for the whole window.
    if _maintenance_active():
        print("maintenance window active - skipping intake watchdog", file=sys.stderr)
        return 0

    token = os.environ.get("MUSOAI_INTERCOM_TOKEN")
    if not token:
        print("ERROR: MUSOAI_INTERCOM_TOKEN not set", file=sys.stderr)
        return 1

    try:
        at_ts = _epoch(args.at)
    except Exception as e:  # noqa: BLE001 — surface a clean usage error
        print(f"ERROR: bad --at value {args.at!r}: {e}", file=sys.stderr)
        return 1

    try:
        a = assess(token, at_ts, args.window_hours, args.grace_hours)
    except urllib.error.URLError as e:
        print(f"ERROR: Intercom API failed: {e}", file=sys.stderr)
        return 2

    judged = a["total_created"] >= args.min_volume
    unhealthy = judged and a["processed_fraction"] < args.min_processed
    a["judged"] = judged
    a["unhealthy"] = unhealthy

    win_h = round((a["window_end"] - a["window_start"]) / 3600, 1)
    summary = (
        f"intake window {win_h}h (ending {args.grace_hours}h ago): "
        f"{a['total_created']} created, {a['processed']} processed, "
        f"{a['unprocessed']} unprocessed ({int(a['processed_fraction']*100)}% processed)"
    )
    print(json.dumps(a))
    print(summary, file=sys.stderr)

    if unhealthy:
        msg = (
            ":rotating_light: *Intercom intake watchdog* — possible Caroline/edge outage.\n"
            f"In the {summary}. "
            f"Only {int(a['processed_fraction']*100)}% of inbound got an `ai:*` tag or admin reply "
            f"(threshold {int(args.min_processed*100)}%). "
            f"Oldest unhandled: {a['oldest_unprocessed_hours']}h.\n"
            "Check the edge gateway / Intercom webhook (last outage: missing "
            "openclaw-edge-gateway Service, 2026-04)."
        )
        if args.alert:
            token = resolve_slack_token()
            if not token:
                print("ERROR: --alert but no Slack bot token (set SLACK_BOT_TOKEN "
                      "or ensure openclaw config has a devops botToken)", file=sys.stderr)
                return 1
            channel = os.environ.get("WATCHDOG_SLACK_CHANNEL", DEFAULT_SLACK_CHANNEL)
            try:
                slack_post(token, channel, msg)
                print(f"ALERT posted to Slack channel {channel}", file=sys.stderr)
            except (urllib.error.URLError, RuntimeError) as e:
                print(f"ERROR: Slack post failed: {e}", file=sys.stderr)
                return 2
        else:
            print("UNHEALTHY (would alert; --check mode, no Slack sent)", file=sys.stderr)
    else:
        print("healthy" if judged else "below min-volume, not judged", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
