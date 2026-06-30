#!/usr/bin/env python3
"""Intercom SYSTEMIC data-issue watchdog (Lane B) — AI-clustered.

Aaron only wants to hear about **systemic** data issues — the same problem
reported across MANY users — not a page per individual complaint, and not a
noisy false "systemic" signal from coarse keyword buckets. This script is the
deterministic edge of an AI-clustered pipeline; the semantic clustering is done
by an operations-agent turn in the middle (the report-systemic-data-issues
skill). Two modes:

  --gather   Read every conversation ACTIVE in the last <window> hours (windowed
             on updated_at, so an old thread Caroline tags today is scanned too)
             and emit a JSON array of CANDIDATE conversations — opening message
             (HTML-stripped, length-capped), who, age, state, tags, deeplink. No
             keyword pre-filter: the AI reads them and decides which are real
             data complaints. Read-only against Intercom.

  --report   Consume the agent's clusters.json (which conversations describe the
             SAME underlying issue, with a one-line symptom + the entities the
             customers cite), validate it, drop sub-threshold clusters, apply a
             per-issue cooldown, render an Aaron-ready report (report-to-aaron
             doctrine: symptom not diagnosis, precise nouns, all context up
             front, attribution line), and post it to the priority channel
             mentioning Aaron via the Ops bot. The only writes are the Slack post
             and a tiny per-issue cooldown ledger.

Why the split: the fetch (in) and the render/cooldown/escape/post (out) stay
deterministic and unit-tested — injection-safety and anti-re-page discipline are
not left to the LLM; only the "same issue" judgement is the LLM's.

Caroline's inline `[[PRIORITY]]` no longer pages anyone (plugins/intercom). It
tags the conversation `ai:data-complaint`; --gather surfaces that tag so the AI
can weight it. Individual complaints are handled by the normal support flow;
leadership is paged only on a systemic cluster.

Usage:
  # emit candidate conversations for the last 24h (no Slack, no write):
  python3 scripts/intercom-data-complaint-watchdog.py --gather --window-hours 24

  # render + page from the agent's clusters file (cron):
  python3 scripts/intercom-data-complaint-watchdog.py --report --clusters clusters.json

  # render to stderr only, no Slack, no ledger write:
  python3 scripts/intercom-data-complaint-watchdog.py --report --clusters clusters.json --check

  # gather as-if at a past instant (backtest):
  python3 scripts/intercom-data-complaint-watchdog.py --gather --at 2026-06-23T12:00:00Z

Env:
  MUSOAI_INTERCOM_TOKEN    required for --gather — Intercom Bearer token.
  MUSO_SLACK_BOT_TOKEN_OPERATIONS  the Ops bot token for --report (preferred —
                           same identity the support flow uses). Override the var
                           name with PRIORITY_SLACK_BOT_TOKEN_VAR.
  SLACK_BOT_TOKEN          optional fallback Slack bot token for --report. If
                           neither is set, the devops bot token is read from the
                           openclaw config.
  OPENCLAW_CONFIG          optional — path to openclaw.json for token lookup.
  PRIORITY_SLACK_CHANNEL   optional — channel id; default C0BBTAVP44X.
  PRIORITY_MENTION_IDS     optional — comma-separated Slack user ids to @-tag;
                           default U7RP6HKUZ (Aaron).
  INTERCOM_WORKSPACE_ID    optional — for deeplinks; default dwjzhcge.
  LEDGER_PATH              optional — per-issue cooldown ledger json; default
                           /var/lib/intercom-data-complaint-watchdog/systemic-clusters-seen.json.

Tunables (flags, with env fallbacks):
  --window-hours    N  candidate window, last N hours          (default 24, env WATCHDOG_WINDOW_HOURS)
  --grace-minutes   N  end the window N minutes ago            (default 2,  env WATCHDOG_GRACE_MINUTES)
  --max             N  cap candidates emitted by --gather      (default 300, env WATCHDOG_MAX_CANDIDATES)
  --threshold       N  page when a cluster has >= N distinct users (default 2, env WATCHDOG_SYSTEMIC_THRESHOLD)
  --cooldown-hours  N  don't re-page the same issue within N hours (default 24, env WATCHDOG_COOLDOWN_HOURS)

Exit codes:
  0  ran cleanly (whether nothing found, or found-and-paged)
  1  usage / env / malformed-clusters error
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
# plugins/intercom/src/priority-signal.ts. --gather surfaces it on each candidate
# so the AI can weight a conversation Caroline already flagged.
DATA_COMPLAINT_TAG = "ai:data-complaint"

DEFAULT_SLACK_CHANNEL = "C0BBTAVP44X"
DEFAULT_MENTION_IDS = "U7RP6HKUZ"  # Aaron
DEFAULT_WORKSPACE_ID = "dwjzhcge"
DEFAULT_LEDGER = "/var/lib/intercom-data-complaint-watchdog/systemic-clusters-seen.json"
# Append-only feed of clusters we PAGED, consumed by scripts/resolution-matcher.py
# to close the loop: it backtests each member's cited entity against action_log and,
# when a fix landed, tells the customer + closes the conversation/ticket. We only
# DETECT here; persisting the paged clusters is what lets resolution run later.
DEFAULT_RESOLUTION_FEED = "/var/lib/resolution-matcher/cluster-feed.jsonl"

# Opening-message text handed to the AI is capped — enough to classify the
# complaint without ballooning the gather payload.
SNIPPET_CAP = 600


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


# ── Intercom read (gather) ───────────────────────────────────────────────────
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
    thread is scanned too — in particular an OLD conversation that Caroline tags
    `ai:data-complaint` today, which bumps updated_at into the window."""
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


def conv_tag_names(conv):
    tags = (conv.get("tags") or {}).get("tags", [])
    return [t.get("name") for t in tags if t.get("name")]


def customer_text(conv):
    """First customer message body, HTML-stripped. We read the opening message —
    most data complaints state the problem up front. A complaint buried only in a
    later part can be missed; that's an accepted limitation."""
    src = conv.get("source") or {}
    return _strip_html(src.get("body") or "")


def conv_state(conv):
    """Coarse current state for the report context line."""
    if conv.get("state"):
        return str(conv["state"])
    return "open" if conv.get("open") else "closed"


def candidate(conv, now_ts):
    """Shape one conversation as an AI candidate, or None if there's nothing to
    classify (no customer text AND not Caroline-tagged)."""
    text = customer_text(conv)
    tagged = has_data_complaint_tag(conv)
    if not text and not tagged:
        return None
    src = conv.get("source") or {}
    author = src.get("author") or {}
    email = (author.get("email") or "").strip().lower()
    conv_id = str(conv.get("id") or "")
    created = int(conv.get("created_at") or 0)
    age_hours = round((now_ts - created) / 3600, 1) if created else None
    return {
        "conv_id": conv_id,
        "who": email or "anonymous",
        "email": email,
        "age_hours": age_hours,
        "state": conv_state(conv),
        "tags": conv_tag_names(conv),
        "deeplink": deeplink(os.environ.get("INTERCOM_WORKSPACE_ID", DEFAULT_WORKSPACE_ID), conv_id),
        "opening_message": text[:SNIPPET_CAP],
    }


def gather_candidates(convs, now_ts, max_n):
    """Newest-first candidate list, capped to max_n. Returns (candidates,
    dropped) so the caller can log a truncation loudly (no silent caps)."""
    cands = [c for c in (candidate(cv, now_ts) for cv in convs) if c]
    # Newest first (smallest age first); unknown-age conversations sort last.
    cands.sort(key=lambda c: c["age_hours"] if c["age_hours"] is not None else 1e9)
    dropped = max(0, len(cands) - max_n)
    return cands[:max_n], dropped


# ── Cooldown ledger (per ISSUE slug) ─────────────────────────────────────────
def load_ledger(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_ledger(path, ledger):
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(ledger, f)
    os.replace(tmp, path)


def prune_ledger(ledger, now, cooldown_seconds):
    horizon = now - 2 * cooldown_seconds
    return {k: v for k, v in ledger.items() if isinstance(v, (int, float)) and v >= horizon}


def append_resolution_feed(path, clusters, paged_at):
    """Append the just-paged clusters to the resolution feed (one JSON line per
    cluster) so resolution-matcher.py can later close the loop. Best-effort: a
    feed write must NEVER fail the report (the page already went out). Each line
    carries only what the matcher needs — issue identity + per-member conv_id,
    email, cites, age_hours — never the full transcript."""
    try:
        d = os.path.dirname(path)
        if d:
            os.makedirs(d, exist_ok=True)
        with open(path, "a") as f:
            for c in clusters:
                f.write(json.dumps({
                    "paged_at": int(paged_at),
                    "issue_slug": c["issue_slug"],
                    "title": c.get("title", c["issue_slug"]),
                    "symptom": c.get("symptom", ""),
                    "members": [{
                        "conv_id": u["conv_id"],
                        "email": u.get("email", ""),
                        "cites": u.get("cites", []),
                        "age_hours": u.get("age_hours"),
                    } for u in c["users"]],
                }) + "\n")
            f.flush()  # shrink the torn-line window for the matcher's reader
    except OSError as e:
        print(f"WARN: could not append resolution feed {path}: {e}", file=sys.stderr)


# ── Slack ────────────────────────────────────────────────────────────────────
def resolve_slack_token():
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
        # Prefer the `operations` (Ops) identity — this report posts AS Ops to the
        # priority channel, and only the Ops bot is guaranteed a member there
        # (mirrors close-resolved-conversations.py). devops/clio are last-ditch
        # fallbacks so a page still goes out rather than silently dropping.
        tok = (accts.get("operations", {}).get("botToken", "")
               or accts.get("devops", {}).get("botToken", "")
               or accts.get("clio", {}).get("botToken", ""))
        if tok:
            return tok
    return None


def slack_escape(text):
    """Escape untrusted customer/agent text for a Slack mrkdwn sink. `&` first so
    `<`/`>` aren't double-escaped — neutralizes <!channel> / <@U...> / fake-link
    injection."""
    return (text or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def deeplink(workspace_id, conv_id):
    return f"https://app.intercom.com/a/inbox/{workspace_id}/inbox/conversation/{conv_id}"


# ── clusters.json validation + render (report) ───────────────────────────────
class ClustersError(ValueError):
    """Raised when the agent's clusters.json doesn't meet the contract. Surfaced
    as a clean exit 1 — never a silent skip (the agent must fix and re-run)."""


def _req_str(obj, key, where):
    v = obj.get(key)
    if not isinstance(v, str) or not v.strip():
        raise ClustersError(f"{where}: missing/empty string field {key!r}")
    return v


def validate_clusters(obj):
    """Validate + normalize the agent's clusters.json. Fail loud on anything
    malformed (Rule 13). Returns (clusters, excluded, window_hours)."""
    if not isinstance(obj, dict):
        raise ClustersError("top level must be a JSON object")
    raw = obj.get("clusters")
    if not isinstance(raw, list):
        raise ClustersError("'clusters' must be a list")
    clusters = []
    for i, c in enumerate(raw):
        where = f"clusters[{i}]"
        if not isinstance(c, dict):
            raise ClustersError(f"{where}: must be an object")
        slug = _req_str(c, "issue_slug", where)
        title = _req_str(c, "title", where)
        symptom = _req_str(c, "symptom", where)
        users = c.get("users")
        if not isinstance(users, list) or not users:
            raise ClustersError(f"{where}: 'users' must be a non-empty list")
        norm_users = []
        for j, u in enumerate(users):
            uw = f"{where}.users[{j}]"
            if not isinstance(u, dict):
                raise ClustersError(f"{uw}: must be an object")
            who = _req_str(u, "who", uw)
            conv_id = u.get("conv_id")
            if not isinstance(conv_id, str) or not conv_id.strip():
                raise ClustersError(f"{uw}: missing/empty string field 'conv_id'")
            conv_id = conv_id.strip()
            # SECURITY: conv_id is interpolated raw into the trusted
            # `<https://…/{conv_id}|conversation>` Slack link in render_user_line, so a
            # value containing `|`/`<`/`>` would break out and inject a live
            # <!channel> / <@U…> ping or a phishing link. Intercom conversation
            # ids are digit strings — whitelist that and reject anything else.
            if not re.fullmatch(r"[0-9]+", conv_id):
                raise ClustersError(f"{uw}: 'conv_id' must be a numeric Intercom id, got {conv_id!r}")
            cites = u.get("cites") or []
            if not isinstance(cites, list) or not all(isinstance(x, str) for x in cites):
                raise ClustersError(f"{uw}: 'cites' must be a list of strings")
            # `email` is the distinct-user KEY (see distinct_users), separate from
            # the display `who`. Optional — anonymous users have none; then the
            # conv_id keys them so each anonymous conversation is its own user.
            email = u.get("email")
            norm_users.append({
                "who": who,
                "conv_id": conv_id,
                "email": email.strip().lower() if isinstance(email, str) else "",
                "detail": u.get("detail") if isinstance(u.get("detail"), str) else "",
                "cites": cites,
                "age_hours": u.get("age_hours"),
                "state": u.get("state") if isinstance(u.get("state"), str) else "",
            })
        clusters.append({
            "issue_slug": slug.strip(),
            "title": title,
            "symptom": symptom,
            "noun": c.get("noun") if isinstance(c.get("noun"), str) else "",
            "users": norm_users,
        })
    # `excluded` is Aaron-facing content (the "judged non-systemic" footnote), so
    # validate it the same fail-loud way as clusters — never silently drop a
    # garbled entry. The agent self-heals: a malformed file exits 1 and it re-runs.
    excluded = []
    for i, e in enumerate(obj.get("excluded") or []):
        ew = f"excluded[{i}]"
        if not isinstance(e, dict):
            raise ClustersError(f"{ew}: must be an object")
        excluded.append({"who": _req_str(e, "who", ew), "reason": _req_str(e, "reason", ew)})
    window_hours = obj.get("window_hours")
    return clusters, excluded, window_hours


def distinct_users(cluster):
    """Distinct-user count for a cluster — the safety-critical input to the
    >=threshold page gate. Key by EMAIL when present (so one customer across
    several conversations counts once), else by conv_id (each anonymous
    conversation is its own user). This mirrors the old watchdog's
    email-or-`anon:<conv_id>` key. Keying on the free-text `who` LABEL would
    collapse every no-email "anonymous" into one user, so two anonymous customers
    reporting the same issue would fall below the threshold and never page."""
    keys = set()
    for u in cluster["users"]:
        email = (u.get("email") or "").strip().lower()
        keys.add(email if email else f"anon:{u['conv_id']}")
    return len(keys)


def _age_state(u):
    bits = []
    age = u.get("age_hours")
    if isinstance(age, (int, float)):
        bits.append(f"reported {age:g}h ago")
    if u.get("state"):
        bits.append(slack_escape(u["state"]))
    return " · ".join(bits)


# ── Block Kit rendering ───────────────────────────────────────────────────────
# Slack limits (docs.slack.dev): ≤50 blocks/message, section mrkdwn text ≤3000
# chars, header is plain_text only (a mention there does NOT ping — the live ping
# must be in an mrkdwn section). The caps below keep one daily report well inside
# those limits AND keep it scannable for Aaron; every cap drops LOUDLY ("+N more").
MAX_USERS_PER_CLUSTER = 5      # 5 over-establishes "systemic" (threshold is 2)
MAX_CLUSTERS = 20             # worst case 47 blocks ≤ the hard 50
SECTION_CHAR_BUDGET = 2800    # stop adding user lines before the 3000 hard limit
SECTION_HARD_LIMIT = 3000     # Slack's section mrkdwn ceiling
CONTEXT_CHAR_BUDGET = 1800    # the single trailing "judged non-systemic" line
MAX_DETAIL = 240             # cap one user's free-text detail so a line stays bounded

# Cite URLs are turned into compact <url|label> links ONLY for these hosts. An
# allow-listed, syntactically-clean URL is the only LLM/customer string we place
# inside a live Slack link; everything else is escaped to inert text.
_CITE_URL_RE = re.compile(r"^https?://[^\s<>|]+$")
_CITE_LINK_HOSTS = ("muso.ai", "open.spotify.com")


def _truncate(text, n):
    text = text or ""
    return text if len(text) <= n else text[: max(0, n - 1)].rstrip() + "…"


def _host_allowed(url):
    m = re.match(r"^https?://([^/\s<>|]+)", url)
    host = m.group(1).lower() if m else ""
    return any(host == h or host.endswith("." + h) for h in _CITE_LINK_HOSTS)


def _cite_label(url):
    """A short human label for a cite URL: the last one/two path segments, with a
    uuid-ish / long segment shortened to its first 8 chars
    (…/track/78d7dcd3-3b1c → "track 78d7dcd3")."""
    m = re.match(r"^https?://([^/\s<>|]+)(/[^\s<>|]*)?$", url)
    if not m:
        return url[:40]
    host, path = m.group(1).lower(), (m.group(2) or "")
    segs = [s for s in path.split("/") if s]
    if not segs:
        return host
    parts = [(s[:8] if len(s) > 10 or re.search(r"[0-9a-f]{8}", s) else s) for s in segs[-2:]]
    return " ".join(parts)[:40]


def compact_cite(cite):
    """Render one cite for an mrkdwn section. An allow-listed, clean URL becomes a
    compact <url|label> link; anything else (non-URL, or a URL carrying
    `|`/`<`/`>`/whitespace, or a non-allow-listed host) is escaped to inert text so
    it can neither disguise a phishing link nor break out into a <!channel>/<@U…>
    ping."""
    c = (cite or "").strip()
    if _CITE_URL_RE.fullmatch(c) and _host_allowed(c):
        return f"<{c}|{slack_escape(_cite_label(c))}>"
    return slack_escape(c)


def render_user_line(u, workspace_id):
    """One compact mrkdwn bullet for a user: who — detail · cites · age/state ·
    conversation link. The link is rebuilt from the numeric conv_id (never an
    agent-supplied URL → no link injection)."""
    who = slack_escape(u.get("who", ""))
    detail = slack_escape(_truncate(u.get("detail", ""), MAX_DETAIL))
    head = f"• *{who}*" + (f" — {detail}" if detail else "")
    sub = [compact_cite(c) for c in (u.get("cites") or [])]
    meta = _age_state(u)
    if meta:
        sub.append(meta)
    sub.append(f"<{deeplink(workspace_id, u['conv_id'])}|conversation>")
    return head + "  ·  " + "  ·  ".join(sub)


def build_cluster_section_text(index, cluster, workspace_id):
    """The mrkdwn for one cluster's section: a bold numbered title with the
    distinct-user count, the one-line symptom, then up to MAX_USERS_PER_CLUSTER
    user lines (bounded by SECTION_CHAR_BUDGET). Any users beyond the cap are
    surfaced LOUDLY as a trailing "+N more" line — never silently dropped."""
    nu = distinct_users(cluster)
    head = f"*{index}. {slack_escape(cluster['title'])}*  ·  *{nu} users*"
    sym = f"_{slack_escape(cluster['symptom'])}_"
    lines = [head, sym]
    running = len(head) + len(sym) + 2
    shown = 0
    users = cluster["users"]
    for u in users:
        if shown >= MAX_USERS_PER_CLUSTER:
            break
        line = render_user_line(u, workspace_id)
        # Always show the first user; after that, respect the char budget.
        if shown > 0 and running + len(line) + 1 > SECTION_CHAR_BUDGET:
            break
        lines.append(line)
        running += len(line) + 1
        shown += 1
    remaining = len(users) - shown
    if remaining > 0:
        lines.append(f"_+{remaining} more conversation(s) — see Intercom_")
    text = "\n".join(lines)
    # Last-resort clamp so a pathological line can never exceed Slack's hard limit.
    return text if len(text) <= SECTION_HARD_LIMIT else text[: SECTION_HARD_LIMIT - 1] + "…"


def build_excluded_text(excluded):
    prefix = "Judged non-systemic: "
    parts, used, shown = [], 0, 0
    for e in excluded:
        # Bound each piece (who + reason) so one adversarial entry can't blow the
        # context element past Slack's text limit and make the whole post fail.
        piece = f"{slack_escape(_truncate(e['who'], 120))} ({slack_escape(_truncate(e['reason'], MAX_DETAIL))})"
        if shown > 0 and used + len(piece) + 2 > CONTEXT_CHAR_BUDGET:
            break
        parts.append(piece)
        used += len(piece) + 2
        shown += 1
    text = prefix + "; ".join(parts)
    rem = len(excluded) - shown
    text += f"; +{rem} more" if rem > 0 else ""
    # Last-resort clamp (matches build_cluster_section_text) — never emit a context
    # element over the hard limit, even if the first piece alone is pathological.
    return text if len(text) <= SECTION_HARD_LIMIT else text[: SECTION_HARD_LIMIT - 1] + "…"


def build_report_blocks(clusters, excluded, mention_ids, workspace_id, window_label):
    """The Aaron-ready report as (fallback_text, blocks). Applies the
    report-to-aaron doctrine: a scannable header, the @-mention + count up front,
    an honest attribution line, then one section per cluster (symptom not
    diagnosis, precise nouns, the entities the customer cited, conversation link).
    The mention lives in an mrkdwn section so it actually pings; the header is
    plain_text and therefore mention-free by design."""
    mention = " ".join(f"<@{m}>" for m in mention_ids if re.fullmatch(r"[A-Za-z0-9]+", m))
    n = len(clusters)
    plural = "" if n == 1 else "s"
    shown_clusters = clusters[:MAX_CLUSTERS]
    extra_clusters = n - len(shown_clusters)

    blocks = [
        {"type": "header", "text": {
            "type": "plain_text",
            "text": _truncate(f"🚨 {n} systemic data issue{plural} · {window_label}", 150),
            "emoji": True}},
        {"type": "section", "text": {
            "type": "mrkdwn",
            "text": (f"{mention + '  ' if mention else ''}*{n}* cluster{plural} where "
                     "multiple users independently reported the same issue.")}},
        {"type": "context", "elements": [{
            "type": "mrkdwn",
            "text": ("Automated Ops watchdog. Symptoms are what customers report — "
                     "not a live source-vs-Muso check. Click through to verify the numbers.")}]},
        {"type": "divider"},
    ]
    for i, c in enumerate(shown_clusters, 1):
        if i > 1:
            blocks.append({"type": "divider"})
        blocks.append({"type": "section", "text": {
            "type": "mrkdwn", "text": build_cluster_section_text(i, c, workspace_id)}})
    if extra_clusters > 0:
        blocks.append({"type": "divider"})
        blocks.append({"type": "section", "text": {
            "type": "mrkdwn",
            "text": f"_+{extra_clusters} more cluster(s) not shown — see Intercom_"}})
    if excluded:
        blocks.append({"type": "divider"})
        blocks.append({"type": "context", "elements": [
            {"type": "mrkdwn", "text": build_excluded_text(excluded)}]})

    titles = ", ".join(slack_escape(c["title"]) for c in shown_clusters[:3])
    text = f"🚨 {n} systemic data issue{plural} ({window_label})" + (f": {titles}" if titles else "")
    return text, blocks


def slack_post(token, channel, text, blocks=None):
    payload = {"channel": channel, "text": text, "unfurl_links": False}
    if blocks is not None:
        payload["blocks"] = blocks
    req = urllib.request.Request(
        "https://slack.com/api/chat.postMessage",
        data=json.dumps(payload).encode(),
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        body = json.loads(resp.read())
    if not body.get("ok"):
        raise RuntimeError(f"Slack chat.postMessage failed: {body.get('error')}")
    return True


# ── modes ────────────────────────────────────────────────────────────────────
def run_gather(args):
    token = os.environ.get("MUSOAI_INTERCOM_TOKEN")
    if not token:
        print("ERROR: MUSOAI_INTERCOM_TOKEN not set", file=sys.stderr)
        return 1
    try:
        at_ts = _epoch(args.at)
    except Exception as e:  # noqa: BLE001 — surface a clean usage error
        print(f"ERROR: bad --at value {args.at!r}: {e}", file=sys.stderr)
        return 1
    end_ts = int(at_ts - args.grace_minutes * 60)
    start_ts = int(end_ts - args.window_hours * 3600)
    try:
        convs = fetch_updated_between(token, start_ts, end_ts)
    except (urllib.error.URLError, ValueError) as e:
        print(f"ERROR: Intercom API failed: {e}", file=sys.stderr)
        return 2
    cands, dropped = gather_candidates(convs, end_ts, args.max)
    if dropped:
        print(f"WARN: gathered {len(convs)} convs → {len(cands) + dropped} candidates, "
              f"capped to {args.max} (--max); DROPPED {dropped} oldest", file=sys.stderr)
    win = int(args.window_hours) if float(args.window_hours).is_integer() else args.window_hours
    print(json.dumps({
        "generated_for_ts": end_ts,
        "window_hours": win,
        "total_convs_in_window": len(convs),
        "count": len(cands),
        "truncated": dropped > 0,
        "candidates": cands,
    }, indent=2))
    print(f"{len(convs)} convs in window → {len(cands)} candidates "
          f"({'truncated' if dropped else 'complete'})", file=sys.stderr)
    return 0


def run_report(args):
    try:
        with open(args.clusters) as f:
            obj = json.load(f)
    except OSError as e:
        print(f"ERROR: cannot read --clusters {args.clusters!r}: {e}", file=sys.stderr)
        return 1
    except ValueError as e:
        print(f"ERROR: --clusters {args.clusters!r} is not valid JSON: {e}", file=sys.stderr)
        return 1
    try:
        clusters, excluded, _window_from_file = validate_clusters(obj)
    except ClustersError as e:
        print(f"ERROR: malformed clusters.json: {e}", file=sys.stderr)
        return 1

    # The "last Nh" label is derived from THIS run's --window-hours (the
    # deterministic edge the cron controls), never from the agent's clusters.json.
    # An agent-transcribed window value can't make the header lie ("last [99]h").
    win = int(args.window_hours) if float(args.window_hours).is_integer() else args.window_hours
    window_label = f"last {win}h"

    # Keep only clusters that clear the distinct-user threshold.
    systemic = [c for c in clusters if distinct_users(c) >= args.threshold]
    below = [c for c in clusters if distinct_users(c) < args.threshold]

    at_ts = _epoch(None)
    ledger_path = os.environ.get("LEDGER_PATH", DEFAULT_LEDGER)
    cooldown_s = int(args.cooldown_hours * 3600)
    ledger = load_ledger(ledger_path)

    def _last_paged(slug):
        v = ledger.get(slug, 0)
        return v if isinstance(v, (int, float)) else 0

    to_page = [c for c in systemic if (at_ts - _last_paged(c["issue_slug"])) >= cooldown_s]
    paged_slugs = {c["issue_slug"] for c in to_page}
    in_cooldown = [c for c in systemic if c["issue_slug"] not in paged_slugs]

    print(json.dumps({
        "clusters_total": len(clusters),
        "systemic": [c["issue_slug"] for c in systemic],
        "below_threshold": [c["issue_slug"] for c in below],
        "in_cooldown": [c["issue_slug"] for c in in_cooldown],
        "to_page": [c["issue_slug"] for c in to_page],
    }))
    print(f"{len(clusters)} clusters, {len(systemic)} systemic (>= {args.threshold} users), "
          f"{len(to_page)} not in cooldown", file=sys.stderr)

    if not to_page:
        print("nothing fresh to page", file=sys.stderr)
        print(f"systemic-data-issue report: nothing to page ({len(systemic)} systemic, "
              f"{len(below)} below threshold, {len(in_cooldown)} in cooldown)")
        return 0

    mention_ids = [s.strip() for s in
                   os.environ.get("PRIORITY_MENTION_IDS", DEFAULT_MENTION_IDS).split(",") if s.strip()]
    workspace_id = os.environ.get("INTERCOM_WORKSPACE_ID", DEFAULT_WORKSPACE_ID)
    channel = os.environ.get("PRIORITY_SLACK_CHANNEL", DEFAULT_SLACK_CHANNEL)
    text, blocks = build_report_blocks(to_page, excluded, mention_ids, workspace_id, window_label)

    if args.check:
        print("--- would page (--check mode, no Slack) ---", file=sys.stderr)
        print(json.dumps(blocks, indent=2, ensure_ascii=False), file=sys.stderr)
        print(f"(fallback text: {text})", file=sys.stderr)
        print(f"systemic-data-issue report: --check, would page {len(to_page)} cluster(s) (no Slack post)")
        return 0

    slack_token = resolve_slack_token()
    if not slack_token:
        print("ERROR: --report but no Slack bot token (set MUSO_SLACK_BOT_TOKEN_OPERATIONS "
              "or SLACK_BOT_TOKEN, or ensure the openclaw config has an operations/devops botToken)",
              file=sys.stderr)
        return 1
    try:
        slack_post(slack_token, channel, text, blocks)
        print(f"PAGED {len(to_page)} cluster(s) to {channel}", file=sys.stderr)
    except (urllib.error.URLError, RuntimeError, ValueError) as e:
        print(f"ERROR: Slack post failed: {e}", file=sys.stderr)
        return 2

    for c in to_page:
        ledger[c["issue_slug"]] = at_ts
    ledger = prune_ledger(ledger, at_ts, cooldown_s)
    try:
        save_ledger(ledger_path, ledger)
    except OSError as e:
        print(f"WARN: could not write ledger {ledger_path}: {e}", file=sys.stderr)
    # Persist the paged clusters for resolution-matcher.py to close the loop later.
    append_resolution_feed(
        os.environ.get("RESOLUTION_FEED_PATH", DEFAULT_RESOLUTION_FEED), to_page, at_ts)
    print(f"systemic-data-issue report: paged {len(to_page)} cluster(s) to {channel}")
    return 0


def main():
    ap = argparse.ArgumentParser(description="Intercom systemic data-issue watchdog (AI-clustered)")
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--gather", action="store_true",
                      help="emit candidate conversations for the window as JSON (read-only)")
    mode.add_argument("--report", action="store_true",
                      help="render + page from the agent's --clusters file")
    ap.add_argument("--clusters", default=None,
                    help="path to the agent's clusters.json (required for --report)")
    ap.add_argument("--check", action="store_true",
                    help="with --report: print the message, no Slack, no ledger write")
    ap.add_argument("--at", default=None,
                    help="with --gather: evaluate as-if at this instant (epoch or ISO8601)")
    ap.add_argument("--window-hours", type=float,
                    default=float(os.environ.get("WATCHDOG_WINDOW_HOURS", "24")))
    ap.add_argument("--grace-minutes", type=float,
                    default=float(os.environ.get("WATCHDOG_GRACE_MINUTES", "2")))
    ap.add_argument("--max", type=int,
                    default=int(os.environ.get("WATCHDOG_MAX_CANDIDATES", "300")))
    ap.add_argument("--threshold", type=int,
                    default=int(os.environ.get("WATCHDOG_SYSTEMIC_THRESHOLD", "2")))
    ap.add_argument("--cooldown-hours", type=float,
                    default=float(os.environ.get("WATCHDOG_COOLDOWN_HOURS", "24")))
    args = ap.parse_args()

    if args.report and not args.clusters:
        print("ERROR: --report requires --clusters <file>", file=sys.stderr)
        return 1

    return run_gather(args) if args.gather else run_report(args)


if __name__ == "__main__":
    sys.exit(main())
