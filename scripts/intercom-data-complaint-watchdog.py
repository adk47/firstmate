#!/usr/bin/env python3
"""Intercom data-complaint backstop watchdog (Lane B).

Aaron asked for customer DATA complaints to reach the top of the team *fast*
(2026-06-22). The primary path is inline: Caroline emits a `[[PRIORITY]]` token
the moment she reads a data complaint, and the edge gateway pages the priority
channel instantly (Lane A — plugins/intercom/src/priority-signal.ts +
channel.ts). This script is the BACKSTOP: it catches the complaints Caroline
*under-flagged* (judgment miss) or that never paged because her reply path
failed. It is deliberately dumb and deterministic — keyword matching, no LLM —
so it fires even when the gateway is unhealthy.

Signal: over a recent window, find conversations whose customer message reads as
a data complaint (a data noun + a complaint signal) that Caroline did NOT
already page. "Already paged" = the conversation carries the `ai:priority-paged`
tag that Lane A applies after a successful page — that tag is the cross-lane
dedup key (must stay in sync with PRIORITY_PAGED_TAG in priority-signal.ts).

Read-only against Intercom. The only side effect is an optional Slack post +
a local dedup ledger so the same conversation isn't re-paged every run.

Usage:
  # print candidates only, no Slack, no ledger write:
  python3 scripts/intercom-data-complaint-watchdog.py --check

  # page the priority channel for any fresh candidate (for cron):
  python3 scripts/intercom-data-complaint-watchdog.py --alert

  # backtest as-if at a past instant:
  python3 scripts/intercom-data-complaint-watchdog.py --check --at 2026-06-22T12:00:00Z

Env:
  MUSOAI_INTERCOM_TOKEN    required — Intercom Bearer token.
  MUSO_SLACK_BOT_TOKEN_OPERATIONS  the Ops bot token (preferred — unifies the
                           page identity with Lane A). Supplied via the unit's
                           EnvironmentFile (/etc/openclaw/main.env). Override the
                           var name with PRIORITY_SLACK_BOT_TOKEN_VAR.
  SLACK_BOT_TOKEN          optional fallback Slack bot token for --alert. If
                           neither is set, the devops bot token is read from the
                           openclaw config (channels.slack.accounts.devops.botToken),
                           same as intercom-intake-watchdog.py. NOTE: whichever
                           bot is used must be a member of PRIORITY_SLACK_CHANNEL.
  OPENCLAW_CONFIG          optional — path to openclaw.json for token lookup.
  PRIORITY_SLACK_CHANNEL   optional — channel id; default C0BBTAVP44X.
  PRIORITY_MENTION_IDS     optional — comma-separated Slack user ids to @-tag;
                           default U7RP6HKUZ (Aaron).
  INTERCOM_WORKSPACE_ID    optional — for deeplinks; default dwjzhcge.
  LEDGER_PATH              optional — dedup ledger json; default
                           /var/lib/intercom-data-complaint-watchdog/seen.json.

Tunables (flags, with env fallbacks):
  --window-minutes N   look at conversations created in the last N minutes  (default 60, env WATCHDOG_WINDOW_MINUTES)
  --grace-minutes  N   end the window N minutes ago, to let Lane A act first (default 3,  env WATCHDOG_GRACE_MINUTES)
  --cooldown-hours N   don't re-page the same conversation within N hours    (default 24, env WATCHDOG_COOLDOWN_HOURS)
  --max-page       N   cap candidates listed in one Slack page              (default 10, env WATCHDOG_MAX_PAGE)

Exit codes:
  0  ran cleanly (whether nothing found, or found-and-paged)
  1  usage / env error
  2  Intercom or Slack API error
"""
import argparse
import datetime as dt
import json
import os
import re
import sys
import urllib.request
import urllib.error

INTERCOM_API = os.environ.get("INTERCOM_API", "https://api.intercom.io")
INTERCOM_VERSION = "2.11"

# Cross-lane dedup key — must match PRIORITY_PAGED_TAG in
# plugins/intercom/src/priority-signal.ts. Lane A tags a conversation with this
# after a successful page; we skip anything carrying it.
PRIORITY_PAGED_TAG = "ai:priority-paged"

DEFAULT_SLACK_CHANNEL = "C0BBTAVP44X"
DEFAULT_MENTION_IDS = "U7RP6HKUZ"  # Aaron
DEFAULT_WORKSPACE_ID = "dwjzhcge"
DEFAULT_LEDGER = "/var/lib/intercom-data-complaint-watchdog/seen.json"

# A complaint = a DATA NOUN co-occurring with a COMPLAINT SIGNAL. Two coarse
# lists ANDed together keep Aaron's channel from filling with calm how-do-I
# questions while still catching the obvious "my credits are all wrong" cases.
# Both lists are overridable via env (comma-separated) for live tuning without
# a redeploy. Scope per Nick 2026-06-22: data complaints INCLUDING analytics /
# stream-counts (Aaron wants internal visibility on those too; Caroline still
# gives the migration narrative to the customer — see SOUL.md Priority signal).
# Lowercased at load (matching customer text, which is lowercased before
# comparison) so an env override like WATCHDOG_DATA_NOUNS="Credit" still matches.
DATA_NOUNS = [s.strip().lower() for s in os.environ.get(
    "WATCHDOG_DATA_NOUNS",
    "credit,credits,profile,profiles,data,stream,streams,analytic,analytics,"
    "play,plays,listener,listeners,catalog,catalogue,royalt,metadata,numbers,"
    "stat,stats,statistics"
).split(",") if s.strip()]

COMPLAINT_SIGNALS = [s.strip().lower() for s in os.environ.get(
    "WATCHDOG_COMPLAINT_SIGNALS",
    "wrong,missing,gone,disappear,incorrect,not showing,doesn't show,"
    "doesnt show,isn't,isnt,aren't,arent,not updating,out of date,outdated,"
    "broken,messed up,mistake,error,still not,for weeks,for months,"
    "ridiculous,unacceptable,frustrat,angry,upset,complaint,terrible,"
    "lost,deleted,duplicate,duplicated,can't find,cant find,nothing shows"
).split(",") if s.strip()]


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


_TAG_RE = re.compile(r"<[^>]*>")


def _strip_html(text):
    return _TAG_RE.sub("", text or "").strip()


def already_paged(conv):
    """True if Lane A already paged this conversation (cross-lane dedup)."""
    tags = (conv.get("tags") or {}).get("tags", [])
    return any((t.get("name") or "") == PRIORITY_PAGED_TAG for t in tags)


def complaint_match(text):
    """Return the (noun, signal) that matched, or None. Coarse on purpose."""
    low = text.lower()
    noun = next((n for n in DATA_NOUNS if n and n in low), None)
    if not noun:
        return None
    signal = next((s for s in COMPLAINT_SIGNALS if s and s in low), None)
    if not signal:
        return None
    return (noun, signal)


def customer_text(conv):
    """First customer message body, HTML-stripped. The backstop matches on the
    opening message — most data complaints state the problem up front. A
    complaint buried only in a later part can be missed; that's an accepted
    backstop limitation (Lane A is the real-time catch)."""
    src = conv.get("source") or {}
    return _strip_html(src.get("body") or "")


def find_candidates(token, at_ts, window_minutes, grace_minutes):
    end_ts = at_ts - grace_minutes * 60
    start_ts = end_ts - window_minutes * 60
    convs = fetch_created_between(token, start_ts, end_ts)
    candidates = []
    for c in convs:
        if already_paged(c):
            continue
        text = customer_text(c)
        if not text:
            continue
        m = complaint_match(text)
        if not m:
            continue
        src = c.get("source") or {}
        author = src.get("author") or {}
        candidates.append({
            "id": str(c.get("id") or ""),
            "created_at": c.get("created_at") or 0,
            "email": author.get("email") or "",
            "matched": f"{m[0]}/{m[1]}",
            "snippet": text[:280],
        })
    return {"window_start": start_ts, "window_end": end_ts,
            "total_created": len(convs), "candidates": candidates}


# ── Dedup ledger ──────────────────────────────────────────────────────────
def load_ledger(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_ledger(path, ledger):
    # dirname is "" for a bare filename (e.g. LEDGER_PATH=seen.json) — makedirs("")
    # raises, which would silently drop the ledger and cause re-pages. Guard it.
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(ledger, f)
    os.replace(tmp, path)


def prune_ledger(ledger, now, cooldown_seconds):
    # Keep entries only while they could still suppress a re-page (2x cooldown
    # of headroom), so the file can't grow unbounded.
    horizon = now - 2 * cooldown_seconds
    return {k: v for k, v in ledger.items() if isinstance(v, (int, float)) and v >= horizon}


# ── Slack ─────────────────────────────────────────────────────────────────
def resolve_slack_token():
    # Prefer the Ops bot token so Lane B posts as the same identity as Lane A's
    # inline chat.postMessage (both "Ops"). The env var name is overridable; the
    # token is supplied via the unit's EnvironmentFile (/etc/openclaw/main.env).
    bot_var = os.environ.get("PRIORITY_SLACK_BOT_TOKEN_VAR", "MUSO_SLACK_BOT_TOKEN_OPERATIONS")
    tok = os.environ.get(bot_var) or os.environ.get("SLACK_BOT_TOKEN")
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


def slack_escape(text):
    """Escape untrusted customer text for Slack. `&` first so `<`/`>` aren't
    double-escaped — neutralizes <!channel> / <@U...> / fake-link injection."""
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def deeplink(workspace_id, conv_id):
    return f"https://app.intercom.com/a/inbox/{workspace_id}/inbox/conversation/{conv_id}"


def build_message(candidates, mention_ids, workspace_id):
    mention = " ".join(f"<@{m}>" for m in mention_ids if re.fullmatch(r"[A-Za-z0-9]+", m))
    n = len(candidates)
    head = (
        f"{mention + ' ' if mention else ''}:rotating_light: "
        f"*{n} customer data complaint{'s' if n != 1 else ''}* the auto-flag didn't catch "
        f"— flagging so {'they' if n != 1 else 'it'} don't sit unanswered:"
    )
    lines = [head]
    for c in candidates:
        who = slack_escape(c["email"]) if c["email"] else "unknown"
        snip = slack_escape(c["snippet"]) or "_(no message text)_"
        lines.append(
            f"• <{deeplink(workspace_id, c['id'])}|conversation> — {who} "
            f"_(matched {slack_escape(c['matched'])})_\n  > {snip}"
        )
    return "\n".join(lines)


def slack_post(token, channel, text):
    req = urllib.request.Request(
        "https://slack.com/api/chat.postMessage",
        data=json.dumps({"channel": channel, "text": text, "unfurl_links": False}).encode(),
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        body = json.loads(resp.read())
    if not body.get("ok"):
        raise RuntimeError(f"Slack chat.postMessage failed: {body.get('error')}")
    return True


def main():
    ap = argparse.ArgumentParser(description="Intercom data-complaint backstop watchdog")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true",
                      help="print candidates only (default; no Slack, no ledger write)")
    mode.add_argument("--alert", action="store_true",
                      help="page the priority channel for fresh candidates")
    ap.add_argument("--at", default=None,
                    help="evaluate as-if at this instant (epoch or ISO8601); default now")
    ap.add_argument("--window-minutes", type=float,
                    default=float(os.environ.get("WATCHDOG_WINDOW_MINUTES", "60")))
    ap.add_argument("--grace-minutes", type=float,
                    default=float(os.environ.get("WATCHDOG_GRACE_MINUTES", "3")))
    ap.add_argument("--cooldown-hours", type=float,
                    default=float(os.environ.get("WATCHDOG_COOLDOWN_HOURS", "24")))
    ap.add_argument("--max-page", type=int,
                    default=int(os.environ.get("WATCHDOG_MAX_PAGE", "10")))
    args = ap.parse_args()

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
        result = find_candidates(token, at_ts, args.window_minutes, args.grace_minutes)
    except (urllib.error.URLError, ValueError) as e:
        # ValueError covers json.JSONDecodeError on a malformed 200 body —
        # exit with the documented API-error code 2, not an uncaught traceback.
        print(f"ERROR: Intercom API failed: {e}", file=sys.stderr)
        return 2

    ledger_path = os.environ.get("LEDGER_PATH", DEFAULT_LEDGER)
    cooldown_s = int(args.cooldown_hours * 3600)
    ledger = load_ledger(ledger_path)

    # Drop candidates we paged within the cooldown (cross-RUN dedup; the
    # ai:priority-paged tag handles cross-LANE dedup against Lane A).
    fresh = [c for c in result["candidates"]
             if (at_ts - ledger.get(c["id"], 0)) >= cooldown_s]
    result["fresh"] = len(fresh)
    print(json.dumps({k: v for k, v in result.items() if k != "candidates"} | {
        "candidate_ids": [c["id"] for c in result["candidates"]],
        "fresh_ids": [c["id"] for c in fresh],
    }))
    summary = (f"{result['total_created']} created in window, "
               f"{len(result['candidates'])} look like data complaints, "
               f"{len(fresh)} fresh (not paged within {args.cooldown_hours}h)")
    print(summary, file=sys.stderr)

    if not fresh:
        print("nothing fresh to page", file=sys.stderr)
        return 0

    to_page = fresh[: args.max_page]
    if len(fresh) > args.max_page:
        print(f"NOTE: {len(fresh)} fresh but capping page at {args.max_page}", file=sys.stderr)

    mention_ids = [s.strip() for s in
                   os.environ.get("PRIORITY_MENTION_IDS", DEFAULT_MENTION_IDS).split(",") if s.strip()]
    workspace_id = os.environ.get("INTERCOM_WORKSPACE_ID", DEFAULT_WORKSPACE_ID)
    channel = os.environ.get("PRIORITY_SLACK_CHANNEL", DEFAULT_SLACK_CHANNEL)
    msg = build_message(to_page, mention_ids, workspace_id)

    if not args.alert:
        print("--- would page (--check mode, no Slack) ---", file=sys.stderr)
        print(msg, file=sys.stderr)
        return 0

    slack_token = resolve_slack_token()
    if not slack_token:
        print("ERROR: --alert but no Slack bot token (set SLACK_BOT_TOKEN or ensure "
              "openclaw config has a devops botToken)", file=sys.stderr)
        return 1
    try:
        slack_post(slack_token, channel, msg)
        print(f"PAGED {len(to_page)} candidate(s) to {channel}", file=sys.stderr)
    except (urllib.error.URLError, RuntimeError, ValueError) as e:
        # ValueError covers json.JSONDecodeError on a malformed Slack 200 body.
        print(f"ERROR: Slack post failed: {e}", file=sys.stderr)
        return 2

    # Record only what we actually paged, then prune. A page failure above
    # returned already, so the ledger never suppresses an un-sent page.
    for c in to_page:
        ledger[c["id"]] = at_ts
    ledger = prune_ledger(ledger, at_ts, cooldown_s)
    try:
        save_ledger(ledger_path, ledger)
    except OSError as e:
        print(f"WARN: could not write ledger {ledger_path}: {e}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
