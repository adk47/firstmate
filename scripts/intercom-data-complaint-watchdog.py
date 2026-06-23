#!/usr/bin/env python3
"""Intercom SYSTEMIC data-complaint watchdog (Lane B).

Aaron (2026-06-23) only wants to hear about **systemic** data issues — the same
problem reported across MANY users — not a page per individual complaint. So this
watchdog is a CROSS-USER CLUSTER detector, not a per-conversation pager:

  - Each run looks at conversations ACTIVE in the last <window> hours (default
    24) — windowed on updated_at, so an old thread Caroline tags today counts
    too — finds the data complaints (a data noun + a complaint signal in the
    opening message, OR Caroline's `ai:data-complaint` classification tag), and
    groups them by a coarse data CATEGORY (credits / profile / analytics / data).
  - It counts DISTINCT users per category (by email; an anonymous conversation
    counts as its own user).
  - When a category has >= THRESHOLD distinct users (default 3) it pages the
    priority channel ONCE — with the cluster summary + a copy-to-Claude block —
    and won't re-page that category until the per-category cooldown elapses.

Caroline's inline `[[PRIORITY]]` no longer pages anyone (plugins/intercom). It
just tags the conversation `ai:data-complaint`, which this watchdog folds into
the count. Individual complaints are handled by the normal support flow
(tickets); leadership is paged only on a systemic cluster.

Read-only against Intercom. The only side effects are an optional Slack post and
a tiny per-category cooldown ledger.

Usage:
  # print the per-category clusters + who would be paged (no Slack, no write):
  python3 scripts/intercom-data-complaint-watchdog.py --check

  # page the priority channel for any category crossing the threshold (cron):
  python3 scripts/intercom-data-complaint-watchdog.py --alert

  # backtest as-if at a past instant:
  python3 scripts/intercom-data-complaint-watchdog.py --check --at 2026-06-23T12:00:00Z

Env:
  MUSOAI_INTERCOM_TOKEN    required — Intercom Bearer token.
  MUSO_SLACK_BOT_TOKEN_OPERATIONS  the Ops bot token (preferred — same identity
                           the support flow uses). Supplied via the unit's
                           EnvironmentFile. Override the var name with
                           PRIORITY_SLACK_BOT_TOKEN_VAR.
  SLACK_BOT_TOKEN          optional fallback Slack bot token for --alert. If
                           neither is set, the devops bot token is read from the
                           openclaw config. Whichever bot is used must be a
                           member of PRIORITY_SLACK_CHANNEL.
  OPENCLAW_CONFIG          optional — path to openclaw.json for token lookup.
  PRIORITY_SLACK_CHANNEL   optional — channel id; default C0BBTAVP44X.
  PRIORITY_MENTION_IDS     optional — comma-separated Slack user ids to @-tag;
                           default U7RP6HKUZ (Aaron).
  INTERCOM_WORKSPACE_ID    optional — for deeplinks; default dwjzhcge.
  LEDGER_PATH              optional — per-category cooldown ledger json; default
                           /var/lib/intercom-data-complaint-watchdog/seen.json.

Tunables (flags, with env fallbacks):
  --window-hours    N  count distinct users over the last N hours   (default 24, env WATCHDOG_WINDOW_HOURS)
  --grace-minutes   N  end the window N minutes ago, to let Caroline's tag land (default 2, env WATCHDOG_GRACE_MINUTES)
  --threshold       N  page when a category has >= N distinct users  (default 3,  env WATCHDOG_SYSTEMIC_THRESHOLD)
  --cooldown-hours  N  don't re-page the same category within N hours (default 24, env WATCHDOG_COOLDOWN_HOURS)
  --max-examples    N  example conversations listed per category      (default 8,  env WATCHDOG_MAX_EXAMPLES)

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

# Caroline's classification tag — must match DATA_COMPLAINT_TAG in
# plugins/intercom/src/priority-signal.ts. A conversation carrying it is folded
# into the cluster count even if the keyword matcher misses it.
DATA_COMPLAINT_TAG = "ai:data-complaint"

DEFAULT_SLACK_CHANNEL = "C0BBTAVP44X"
DEFAULT_MENTION_IDS = "U7RP6HKUZ"  # Aaron
DEFAULT_WORKSPACE_ID = "dwjzhcge"
DEFAULT_LEDGER = "/var/lib/intercom-data-complaint-watchdog/seen.json"

# A complaint = a DATA NOUN co-occurring with a COMPLAINT SIGNAL. Two coarse
# lists ANDed together keep the count from filling with calm how-do-I questions
# while still catching the obvious "my credits are all wrong" cases. Both lists
# are overridable via env (comma-separated) for live tuning without a redeploy.
# Lowercased at load (matching customer text, which is lowercased before
# comparison).
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

# Collapse the fine-grained matched noun into a coarse category so "streams" /
# "plays" / "analytics" cluster as ONE systemic issue, not three. Anything not
# listed falls back to the generic "data" bucket.
#
# v1 LIMITATION: this is COARSE — three unrelated credit gripes group as one
# "credits" cluster, so a page can be a false-positive "systemic" signal. The
# threshold (default 3) and the example list — which a human reads before acting
# — mitigate it. Revisit with symptom-level clustering (e.g. "ISRC mismatch" vs
# "missing credits") if the pages turn out noisy.
NOUN_TO_CATEGORY = {
    "credit": "credits", "credits": "credits", "royalt": "credits",
    "profile": "profile", "profiles": "profile", "metadata": "profile",
    "catalog": "profile", "catalogue": "profile",
    "stream": "analytics", "streams": "analytics", "play": "analytics",
    "plays": "analytics", "listener": "analytics", "listeners": "analytics",
    "analytic": "analytics", "analytics": "analytics", "stat": "analytics",
    "stats": "analytics", "statistics": "analytics", "numbers": "analytics",
    "data": "data",
}


def categorize(noun):
    return NOUN_TO_CATEGORY.get(noun, "data")


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


def fetch_updated_between(token, start_ts, end_ts):
    """All conversations UPDATED in [start_ts, end_ts), any current state.

    We window on updated_at, not created_at, so a complaint in a long-lived
    thread is scanned too — in particular an OLD conversation (created days ago)
    that Caroline tags `ai:data-complaint` today, which bumps updated_at into the
    window. Without this, the tag fold-in only ever helped brand-new
    conversations. updated_at >= created_at, so this is a superset of the
    created-in-window set (new complaints are still caught)."""
    convs = []
    after = None
    while True:
        body = {
            "query": {
                "operator": "AND",
                "value": [
                    {"field": "updated_at", "operator": ">", "value": int(start_ts)},
                    {"field": "updated_at", "operator": "<", "value": int(end_ts)},
                ],
            },
            "pagination": {"per_page": 150},
        }
        if after:
            body["pagination"]["starting_after"] = after
        data = _intercom_search(token, body)
        for c in data.get("conversations", []):
            updated = c.get("updated_at") or 0
            if start_ts <= updated < end_ts:
                convs.append(c)
        nxt = (data.get("pages") or {}).get("next")
        after = nxt.get("starting_after") if isinstance(nxt, dict) else None
        if not nxt or not after:
            break
    return convs


_TAG_RE = re.compile(r"<[^>]*>")


def _strip_html(text):
    return _TAG_RE.sub("", text or "").strip()


def has_data_complaint_tag(conv):
    """True if Caroline classified this conversation as a data complaint."""
    tags = (conv.get("tags") or {}).get("tags", [])
    return any((t.get("name") or "") == DATA_COMPLAINT_TAG for t in tags)


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
    """First customer message body, HTML-stripped. We match on the opening
    message — most data complaints state the problem up front. A complaint
    buried only in a later part can be missed; that's an accepted limitation."""
    src = conv.get("source") or {}
    return _strip_html(src.get("body") or "")


def detect_complaint(conv):
    """Classify a conversation as a data complaint, or return None.

    Fires on a keyword match (data noun + complaint signal) OR Caroline's
    `ai:data-complaint` tag. Returns the event dict the aggregator counts:
    category, the distinct-user key, email, conv id, snippet, created ts."""
    text = customer_text(conv)
    m = complaint_match(text) if text else None
    tagged = has_data_complaint_tag(conv)
    if not m and not tagged:
        return None
    src = conv.get("source") or {}
    author = src.get("author") or {}
    # Email is case-insensitive — normalize so "A@x.com" and "a@x.com" count as
    # ONE user, not two (which could falsely cross the systemic threshold).
    email = (author.get("email") or "").strip().lower()
    conv_id = str(conv.get("id") or "")
    return {
        # A keyword match gives a precise category; a tag-only hit (keywords
        # missed it) lands in the generic "data" bucket.
        "category": categorize(m[0]) if m else "data",
        # Distinct-user key: email when we have it, else the conversation itself
        # (an anonymous complaint is still one user).
        "user": email or f"anon:{conv_id}",
        "email": email,
        "conv_id": conv_id,
        "snippet": (text or "")[:200],
        "ts": int(conv.get("created_at") or 0),
    }


def find_clusters(convs, threshold):
    """Group complaints by category, keeping one (latest) example per user.

    Returns (clusters, groups): `groups` is every category → {user → event};
    `clusters` is the subset with >= threshold distinct users."""
    groups = {}
    for c in convs:
        ev = detect_complaint(c)
        if not ev:
            continue
        users = groups.setdefault(ev["category"], {})
        prev = users.get(ev["user"])
        if prev is None or ev["ts"] >= prev["ts"]:
            users[ev["user"]] = ev
    clusters = {cat: users for cat, users in groups.items() if len(users) >= threshold}
    return clusters, groups


# ── Cooldown ledger (per CATEGORY, not per conversation) ────────────────────
def load_ledger(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_ledger(path, ledger):
    # dirname is "" for a bare filename — makedirs("") raises, which would
    # silently drop the ledger and cause re-pages. Guard it.
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(ledger, f)
    os.replace(tmp, path)


def prune_ledger(ledger, now, cooldown_seconds):
    # Keep a category's last-paged timestamp only while it could still suppress a
    # re-page (2x cooldown of headroom), so the file can't grow unbounded.
    horizon = now - 2 * cooldown_seconds
    return {k: v for k, v in ledger.items() if isinstance(v, (int, float)) and v >= horizon}


# ── Slack ───────────────────────────────────────────────────────────────────
def resolve_slack_token():
    # Prefer the Ops bot token so this posts as the same identity the support
    # flow uses. The env var name is overridable; the token is supplied via the
    # unit's EnvironmentFile.
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
    """Escape untrusted customer text for a Slack mrkdwn sink. `&` first so
    `<`/`>` aren't double-escaped — neutralizes <!channel> / <@U...> / fake-link
    injection."""
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _strip_backticks(text):
    # Inside a Slack ``` code fence mrkdwn is inert; the only injection risk is a
    # customer closing the fence early with ```. Neutralize every backtick.
    return text.replace("`", "'")


def deeplink(workspace_id, conv_id):
    return f"https://app.intercom.com/a/inbox/{workspace_id}/inbox/conversation/{conv_id}"


def _ordered(clusters):
    # Biggest cluster first.
    return sorted(clusters, key=lambda c: -len(clusters[c]))


def _examples(users, max_examples):
    return sorted(users.values(), key=lambda e: -e["ts"])[:max_examples]


def build_copy_block(clusters, workspace_id, window_hours, max_examples):
    """Fenced, paste-into-Claude plain-text summary of the cluster(s)."""
    out = ["Systemic data-complaint cluster(s) — Muso priority watchdog",
           f"(distinct users reporting the same data category in the last {window_hours}h)", ""]
    for cat in _ordered(clusters):
        users = clusters[cat]
        out.append(f"Category: {cat} — {len(users)} distinct users")
        for ev in _examples(users, max_examples):
            who = _strip_backticks(ev["email"]) if ev["email"] else "anonymous"
            out.append(f"  - {who}: \"{_strip_backticks(ev['snippet'])}\" — {deeplink(workspace_id, ev['conv_id'])}")
        out.append("")
    return "```\n" + "\n".join(out).strip() + "\n```"


def build_systemic_message(clusters, mention_ids, workspace_id, window_hours, max_examples):
    mention = " ".join(f"<@{m}>" for m in mention_ids if re.fullmatch(r"[A-Za-z0-9]+", m))
    lines = [
        f"{mention + ' ' if mention else ''}:rotating_light: "
        f"*Systemic data issue* — the same problem is hitting multiple users:"
    ]
    for cat in _ordered(clusters):
        users = clusters[cat]
        n = len(users)
        lines.append("")
        lines.append(f"*{n} users reporting {slack_escape(cat)} problems* (last {window_hours}h)")
        examples = _examples(users, max_examples)
        for ev in examples:
            who = slack_escape(ev["email"]) if ev["email"] else "anonymous"
            snip = slack_escape(ev["snippet"]) or "_(no message text)_"
            lines.append(f"• {who} — \"{snip}\" — <{deeplink(workspace_id, ev['conv_id'])}|conversation>")
        if n > len(examples):
            lines.append(f"  …and {n - len(examples)} more")
    lines.append("")
    lines.append(build_copy_block(clusters, workspace_id, window_hours, max_examples))
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
    ap = argparse.ArgumentParser(description="Intercom systemic data-complaint watchdog")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true",
                      help="print clusters + would-page (default; no Slack, no ledger write)")
    mode.add_argument("--alert", action="store_true",
                      help="page the priority channel for any category crossing the threshold")
    ap.add_argument("--at", default=None,
                    help="evaluate as-if at this instant (epoch or ISO8601); default now")
    ap.add_argument("--window-hours", type=float,
                    default=float(os.environ.get("WATCHDOG_WINDOW_HOURS", "24")))
    ap.add_argument("--grace-minutes", type=float,
                    default=float(os.environ.get("WATCHDOG_GRACE_MINUTES", "2")))
    ap.add_argument("--threshold", type=int,
                    default=int(os.environ.get("WATCHDOG_SYSTEMIC_THRESHOLD", "3")))
    ap.add_argument("--cooldown-hours", type=float,
                    default=float(os.environ.get("WATCHDOG_COOLDOWN_HOURS", "24")))
    ap.add_argument("--max-examples", type=int,
                    default=int(os.environ.get("WATCHDOG_MAX_EXAMPLES", "8")))
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

    # Integer epoch bounds so the API query (which int()s these) and the local
    # re-filter in fetch_updated_between compare on the same value — no
    # fractional-second boundary skew when grace/window are non-integer.
    end_ts = int(at_ts - args.grace_minutes * 60)
    start_ts = int(end_ts - args.window_hours * 3600)
    try:
        convs = fetch_updated_between(token, start_ts, end_ts)
    except (urllib.error.URLError, ValueError) as e:
        # ValueError covers json.JSONDecodeError on a malformed 200 body.
        print(f"ERROR: Intercom API failed: {e}", file=sys.stderr)
        return 2

    clusters, groups = find_clusters(convs, args.threshold)

    ledger_path = os.environ.get("LEDGER_PATH", DEFAULT_LEDGER)
    cooldown_s = int(args.cooldown_hours * 3600)
    ledger = load_ledger(ledger_path)

    def _last_paged(cat):
        # Defensive: tolerate a stale/corrupted ledger value (e.g. a pre-rewrite
        # {conv_id: ts} file, or a hand-edit) without crashing the cron.
        v = ledger.get(cat, 0)
        return v if isinstance(v, (int, float)) else 0

    # A category is eligible to page only if it's not in cooldown.
    to_page = {cat: users for cat, users in clusters.items()
               if (at_ts - _last_paged(cat)) >= cooldown_s}

    print(json.dumps({
        "window_hours": args.window_hours,
        "threshold": args.threshold,
        "total_in_window": len(convs),
        "category_user_counts": {cat: len(u) for cat, u in groups.items()},
        "clusters": {cat: len(u) for cat, u in clusters.items()},
        "to_page": sorted(to_page),
    }))
    summary = (f"{len(convs)} convs in window, "
               f"{len(clusters)} categor{'y' if len(clusters) == 1 else 'ies'} "
               f"over the threshold of {args.threshold}, "
               f"{len(to_page)} not in cooldown")
    print(summary, file=sys.stderr)

    if not to_page:
        print("nothing fresh to page", file=sys.stderr)
        return 0

    mention_ids = [s.strip() for s in
                   os.environ.get("PRIORITY_MENTION_IDS", DEFAULT_MENTION_IDS).split(",") if s.strip()]
    workspace_id = os.environ.get("INTERCOM_WORKSPACE_ID", DEFAULT_WORKSPACE_ID)
    channel = os.environ.get("PRIORITY_SLACK_CHANNEL", DEFAULT_SLACK_CHANNEL)
    # Show "24h" not "24.0h" when the window is a whole number of hours.
    win = int(args.window_hours) if float(args.window_hours).is_integer() else args.window_hours
    msg = build_systemic_message(to_page, mention_ids, workspace_id, win, args.max_examples)

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
        print(f"PAGED {len(to_page)} categor{'y' if len(to_page) == 1 else 'ies'} to {channel}", file=sys.stderr)
    except (urllib.error.URLError, RuntimeError, ValueError) as e:
        print(f"ERROR: Slack post failed: {e}", file=sys.stderr)
        return 2

    # Record only what we actually paged, then prune. A page failure above
    # returned already, so the ledger never suppresses an un-sent page.
    for cat in to_page:
        ledger[cat] = at_ts
    ledger = prune_ledger(ledger, at_ts, cooldown_s)
    try:
        save_ledger(ledger_path, ledger)
    except OSError as e:
        print(f"WARN: could not write ledger {ledger_path}: {e}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
