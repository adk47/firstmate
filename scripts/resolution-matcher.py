#!/usr/bin/env python3
"""Close the loop on systemic data issues: match a SHIPPED FIX back to the
customers who reported it, tell them, and close their conversation/ticket.

This is the resolution counterpart to the DETECTION-only systemic-data-issue
report (scripts/intercom-data-complaint-watchdog.py + the report-systemic-data-
issues skill). That report pages Aaron daily with the *symptom* — "N users
report the same data problem" — but nothing then watches for the fix or tells
those users it landed. Aaron's ask (2026-06-29): "nothing is checking to see if
tickets are being closed with what I'm working on ... monitor for fixes and
report back to users status etc and helps close tickets. Resolution matching and
closing."

HOW IT WORKS (one daily run):
  1. Read the open systemic-issue clusters the report paged (a durable feed the
     watchdog appends on every --report — see RESOLUTION_FEED_PATH). Each member
     carries conv_id, email, the entities they CITED (track/credit/profile URLs
     or ids), and when they reported.
  2. AUTONOMOUS DATA-BACKTEST (the "resolution matching"): for each open member,
     extract the entity UUID(s) they cited and ask action_log (the canonical
     admin-op audit log, via the muso CLI / Trino) — did any admin DATA-FIX route
     touch that exact entity, AS THE PATH TARGET, AFTER the customer reported it?
     We require the cited id to appear in the request ROUTE (e.g.
     /api/v3/admin/profile/<id>/credits) — the unambiguous primary target — NOT
     merely somewhere in requestdata, which would also match rows that only
     REFERENCE the entity (a merge where the cited profile is the absorbed loser,
     or a claim DENIAL carrying the id): a UUID is globally unique, so it proves
     REFERENCE, not a favorable FIX. close-merged-tickets.sh matches the merge
     route by its exact body JSON path; we match a reviewed set of credit-edit +
     bare-profile-edit routes by id-in-route (merge stays owned by
     close-merged-tickets.sh — see _FIX_ROUTE_PREDICATES).
  3. NOTIFY (customer-facing outbound): tell each matched customer, in Caroline's
     voice, that we made an update related to their issue and to take a look. The
     message is a FIXED CONSTANT (zero interpolation -> zero leak surface) and is
     deliberately a soft "please verify" — NOT "it's fixed" — because the signal
     is "an admin touched your entity," not a positive source-vs-Muso re-check.
     It invites a reply, so a wrong match self-corrects instead of going quiet.
  4. CLOSE + WAIT: notifying makes us "spoke last", so we close the Intercom
     conversation, but linked ClickUp tickets remain `waiting` with
     `customer-outcome:verification-required`. An entity touch is not proof
     that the customer's exact complaint is fixed. Every close is shadow-logged
     and reversible; a customer reply reopens the conversation.
  5. ROLL UP TO AARON: post "your fixes closed N conversations across M issues",
     attributed to the action_log row (route + the admin who shipped it + when).
     THIS is the part that answers "is anything checking that my work closes
     tickets" — it reports back what each fix actually closed.

SAFETY — this sends customer-facing messages and closes things autonomously, so
it carries the SAME guards every sibling outbound script here has (resolve-
notify.py, overdue-verification-notifier.py, notify-merged-customers.py). "Go
live immediately" (Aaron) means the timer ships enabled + --apply; it does NOT
mean dropping these — they are what makes an unattended --apply safe:
  * host guard (ovh-node-8 only),
  * COLD START: the first --apply run (no state) seeds every current member as
    already-seen and sends NOTHING, returning before the backtest — a one-run
    anti-blast seed so a fresh deploy never messages the existing backlog. It logs
    a seeded COUNT to stdout; it does NOT run the backtest or post a roll-up, so
    it is not a per-match preview. To preview the actual matches before going
    live, run a manual dry-run on node-8 (no --apply).
  * CIRCUIT BREAKER: a large would-act set on a freshly-written state file
    (wipe / feed-shape bug) aborts and pages instead of blasting.
  * per-conversation dedup (state keyed conv:<id> — at most one message ever),
  * email cross-check on a FRESH conversation GET right before sending (the
    wrong-customer guard — fail closed on absent/mismatched email),
  * suppress closed/snoozed/human-assigned/human-replied/social-tagged convs,
  * per-run cap, atomic state writes, reversible shadow log.

Dry-run by default; --apply is the only path that messages/closes/writes state.

Env:
  MUSOAI_INTERCOM_TOKEN     required — Intercom Bearer.
  MUSO_BIN                  muso CLI for the action_log Trino query (default: muso).
  CLICKUP_API_KEY           optional — annotate a linked ticket as waiting for verification.
  INTERCOM_ADMIN_ID         optional, default 5763097 (Caroline) — admin we post AS.
  CLICKUP_LIST_ID           optional, default 901000600160 (User Requests).
  CLICKUP_INTERCOM_LINK_FIELD_ID  optional, default c32dbf6e-... (#417 link field).
  RESOLUTION_FEED_PATH      optional, default /var/lib/resolution-matcher/cluster-feed.jsonl
                            (append-only, written by intercom-data-complaint-watchdog --report).
  RESOLUTION_STATE_PATH     optional, default /var/lib/resolution-matcher/state.json
  RESOLUTION_SHADOW_LOG     optional, default /var/log/resolution-matcher-shadow.jsonl
  RESOLUTION_MATCHER_MAX    optional, default 15 (per-run act cap + breaker trip point).
  RESOLUTION_LOOKBACK_DAYS  optional, default 60 (ignore feed members older than this).
                            (What counts as a "fix" route is a CONSTANT reviewed set
                            in code — _FIX_ROUTE_PREDICATES — not env-configurable.)
  RESOLUTION_SUMMARY_CHANNEL optional, default C0BBTAVP44X (priority — same place the
                            detection report lands, so Aaron sees the closed loop).
  RESOLUTION_SLACK_ACCOUNT  optional, default operations (which Slack bot posts).
  SLACK_NOTIFY_CONFIG       optional, default /root/.openclaw-main/openclaw.json
  RESOLUTION_NOW            optional epoch override (tests).
  RESOLUTION_SKIP_HOST_GUARD optional, "1" to run off ovh-node-8 (tests).

Flags:
  --apply       actually message/close/write state (default: dry-run preview).
  --limit N     override the per-run act cap for this run (does NOT raise the
                circuit-breaker trip point — same discipline as resolve-notify).
  --self-test   run the inline pure-logic self-test and exit.

Exit codes: 0 ok; 1 usage/env error; 2 self-test failed / circuit-breaker
tripped / Intercom unavailable; 3 at least one member failed mid-run.
"""
import argparse
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lib.customer_outcome import outcome_tag, outcome_tags_of  # noqa: E402

INTERCOM_API = "https://api.intercom.io"
INTERCOM_VERSION = "2.11"
CLICKUP_API = os.environ.get("CLICKUP_API", "https://api.clickup.com/api/v2")

CAROLINE_ADMIN_ID = "5763097"
DEFAULT_LIST_ID = "901000600160"
DEFAULT_SUMMARY_CHANNEL = "C0BBTAVP44X"  # priority channel (where the detection report lands)
SLACK_API = "https://slack.com/api/chat.postMessage"

# "Intercom Link" custom field (#417); value is the conversation deeplink
# https://app.intercom.com/a/inbox/<ws>/inbox/conversation/<convId>. Used to map
# a conversation back to its ClickUp ticket so we can request verification.
INTERCOM_LINK_FIELD = os.environ.get(
    "CLICKUP_INTERCOM_LINK_FIELD_ID", "c32dbf6e-f680-4ff1-a532-192bb96245c3")
_CONV_ID_RE = re.compile(r"/conversation/([^/?#\s\"']+)")

# A 8-4-4-4-12 hex UUID — the identifier customers cite for a track / credit /
# profile (e.g. credits.muso.ai/track/78d7dcd3-3b1c-...). Globally unique, so an
# action_log ROUTE-PATH match on it precisely identifies the fix's primary target.
_UUID_RE = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.IGNORECASE)

# What counts as "an admin shipped a data fix" — a CONSTANT, reviewed set of
# action_log route predicates (NOT free-form config: the route set is safety-
# critical and customer-facing, so it lives in code where it is reviewed, never
# fuzzed via env, which also removes any SQL-injection surface from routes). Both
# kinds carry the customer's entity id IN THE PATH, so the matcher additionally
# requires the cited UUID to appear in the route (the unambiguous PRIMARY TARGET),
# never in requestdata — a globally-unique UUID in requestdata proves REFERENCE,
# not a favorable fix (e.g. a merge-loser, or a claim DENIAL carrying the id).
#
# Validated against live action_log on node-8 (2026-06-30, 90d): these two cover
# 2576 writes (2516 credit + 60 profile-edit) and DROP ~2000 noise writes under
# the same prefixes — /cache clears, /capture, /analytics-sources, /encore-assets,
# /playlist/regenerate — that touch the entity without fixing the reported issue.
#   1. credit add/remove — the dominant credit-misattribution fix. Matches both
#      /api/v3/admin/track/{uuid}/profile/{uuid}/credits and /profile/{uuid}/credits.
#   2. bare profile-data edit — PUT/DELETE /api/v3/admin/profile/{uuid} (name,
#      image, profile fields), but NOT its sub-resources (.../cache, .../member…).
# Deliberately EXCLUDED: /api/v3/admin/profiles/merge (id in BODY; merge tickets
# are already closed precisely by close-merged-tickets.sh — no overlap) and
# claiming / identity-resolution (id in body, route can't tell approve from deny —
# messaging a DENIED customer "we made an update" is the adverse touch to avoid).
_FIX_ROUTE_PREDICATES = (
    "route LIKE '%/credits%'",
    "regexp_like(route, '^/api/v3/admin/profile/[0-9a-fA-F-]{36}([?]|$)')",
)

# Conversation tags that mean "do not auto-message here" (mirror resolve-notify).
BLOCKED_CONV_TAGS = {
    "abuse-block", "instagram", "facebook", "twitter", "x",
    "whatsapp", "messenger", "tiktok", "sms",
}

# Suppression reasons that reflect a STABLE decision — safe to record as acted so
# we don't re-GET the conv every run. The others (email-mismatch from momentarily
# stale Intercom author data; not-open for a snoozed/closed conv the customer may
# reopen about the same unresolved issue) are TRANSIENT: don't persist them, so a
# later legitimate "your fix shipped" note is still possible. Mirrors resolve-
# notify's choice not to mark the conv seen on a transient suppression.
DURABLE_SUPPRESSIONS = {"assignee-human", "human-reply", "blocked-tag"}

# Caroline-voice update note. FIXED CONSTANT — no customer/ticket field is ever
# interpolated, so this urllib send (which bypasses the plugin's
# SanitizingIntercomClient) has zero leak surface. Lowercase Caroline tone,
# DASH-FREE (the support surface forbids em-dashes), banned-word-clean, and a
# DISTINCT opening from resolve-notify's "it's all sorted" and the overdue
# notifier so a rare race can't double-send the same words. Deliberately a soft
# "please take a look" — the backtest proves an admin TOUCHED the entity, not
# that the customer's specific complaint is positively resolved — and it invites
# a reply so a wrong match self-corrects instead of going silent.
MESSAGE = (
    "hi! good news, we've just made an update on our side related to the issue "
    "you flagged. could you take a quick look and let me know it's showing "
    "right for you now? if anything still looks off, just reply here and i'll "
    "dig back in."
)


# --------------------------------------------------------------------------
# Network seam (module-level so tests monkeypatch these, never real HTTP/CLI).
# --------------------------------------------------------------------------
def http(method, url, headers, body=None, timeout=30, attempts=4):
    """urllib wrapper with retry on transient URLErrors. 4xx/5xx raise."""
    data = None
    hdrs = dict(headers)
    if body is not None:
        hdrs["Content-Type"] = "application/json"
        data = json.dumps(body).encode()
    for a in range(attempts):
        try:
            req = urllib.request.Request(url, data=data, method=method)
            for k, v in hdrs.items():
                req.add_header(k, v)
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.status, json.loads(r.read() or b"null")
        except urllib.error.HTTPError:
            raise
        except (urllib.error.URLError, socket.timeout) as e:
            if a == attempts - 1:
                raise RuntimeError(f"{method} {url} failed after {attempts}: {e}")
            time.sleep(2 * (a + 1))


def _ic_headers(token):
    return {"Authorization": f"Bearer {token}", "Accept": "application/json",
            "Intercom-Version": INTERCOM_VERSION}


def get_conversation(conv_id, token):
    s, body = http("GET", f"{INTERCOM_API}/conversations/{conv_id}?display_as=plaintext",
                   _ic_headers(token))
    if s != 200:
        raise RuntimeError(f"intercom get conv {conv_id} -> {s}")
    return body


def post_intercom_reply(conv_id, admin_id, message, token):
    s, body = http("POST", f"{INTERCOM_API}/conversations/{conv_id}/reply",
                   _ic_headers(token),
                   body={"message_type": "comment", "type": "admin",
                         "admin_id": str(admin_id), "body": message})
    if s not in (200, 201):
        raise RuntimeError(f"intercom reply {conv_id} -> {s}: {body}")
    return body


def close_conversation(conv_id, admin_id, token):
    s, body = http("POST", f"{INTERCOM_API}/conversations/{conv_id}/parts",
                   _ic_headers(token),
                   body={"message_type": "close", "type": "admin", "admin_id": str(admin_id)})
    if s not in (200, 201):
        raise RuntimeError(f"intercom close {conv_id} -> {s}: {body}")
    return body


def query_action_log(sql, muso_bin):
    """Run a Trino query via the muso CLI; return parsed NDJSON rows.

    Behind the seam so tests never shell out. EVERY failure mode raises
    RuntimeError so the caller fails CLOSED per-member (skip, leave open) — a
    missing `muso` binary (FileNotFoundError/OSError) or a stalled query
    (TimeoutExpired) must NOT escape as an uncaught exception and crash the whole
    daily run."""
    try:
        proc = subprocess.run([muso_bin, "query", "--format", "json", "-"],
                              input=sql, capture_output=True, text=True, timeout=120)
    except FileNotFoundError as e:
        raise RuntimeError(f"muso binary not found ({muso_bin!r}): {e}")
    except subprocess.TimeoutExpired as e:
        raise RuntimeError(f"muso query timed out after {e.timeout}s")
    except OSError as e:
        raise RuntimeError(f"muso query failed to launch: {e}")
    if proc.returncode != 0:
        raise RuntimeError(f"muso query failed ({proc.returncode}): {proc.stderr.strip()[:300]}")
    rows = []
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            raise RuntimeError(f"action_log returned non-JSON row: {line[:120]!r}")
    return rows


def clickup_get(url, key):
    s, body = http("GET", url, {"Authorization": key})
    if s != 200:
        raise RuntimeError(f"clickup GET {url} -> {s}")
    return body


def clickup_put(url, key, body):
    s, resp = http("PUT", url, {"Authorization": key}, body=body)
    if s != 200:
        raise RuntimeError(f"clickup PUT {url} -> {s}: {resp}")
    return resp


# --------------------------------------------------------------------------
# Pure logic (no network — directly unit-testable).
# --------------------------------------------------------------------------
def extract_entity_ids(cites):
    """All distinct entity UUIDs a member cited, lowercased and de-duped, in a
    stable order. These are the keys we backtest against action_log."""
    ids = []
    seen = set()
    for c in cites or []:
        for m in _UUID_RE.findall(str(c)):
            lc = m.lower()
            if lc not in seen:
                seen.add(lc)
                ids.append(lc)
    return ids


def build_action_log_sql(entity_ids, since_epoch, lookback_days):
    """SQL asking: did any admin FIX route (one of the constant _FIX_ROUTE_PREDICATES)
    touch one of these exact entity UUIDs, AS THE PATH TARGET, after `since_epoch`?

    The entity match is `route LIKE '%uuid%'` ONLY (the cited id must appear in
    the request PATH — the primary target of the write), never a requestdata
    substring (which would match rows that merely reference the entity, e.g. a
    merge-loser or a claim denial). The fix-route predicates are CONSTANT code (no
    free-form route input), and UUIDs are validated by _UUID_RE / ints by int(),
    so nothing untrusted reaches Trino — injection-safe by construction. Attribution
    reads the top-level `email` column (the admin actor); validated on node-8 that
    requestdata.requester is empty on these routes while `email` holds the actor."""
    for e in entity_ids:
        if not _UUID_RE.fullmatch(e):
            raise ValueError(f"unsafe entity id {e!r}")
    since = int(since_epoch)
    lookback = int(lookback_days)
    route_clause = " OR ".join(_FIX_ROUTE_PREDICATES)
    # PRIMARY-TARGET match: the cited id must be in the route path, not merely
    # referenced somewhere in requestdata.
    id_clause = " OR ".join(f"route LIKE '%{e}%'" for e in entity_ids)
    return f"""
  SELECT route AS route,
         requestmethod AS method,
         COALESCE(email, '') AS requester,
         CAST(createdat AS varchar) AS at
  FROM postgresql_core.public.action_log
  WHERE ({route_clause})
    AND requestmethod IN ('POST','PUT','PATCH','DELETE')
    AND createdat > from_unixtime({since})
    AND createdat > current_timestamp - interval '{lookback}' day
    AND ({id_clause})
  ORDER BY createdat ASC
  LIMIT 50
"""


# Cap how far BEFORE the page the report lower bound may reach. age_hours is the
# conversation's age at gather time, but the watchdog DELIBERATELY re-pages OLD
# threads re-tagged ai:data-complaint today — for those, conversation created_at
# can be months before the (resurfaced) complaint, so an uncapped paged_at - age
# would reach back far enough to count an admin action that PREDATES the complaint
# as a "fix after they reported" (a false positive). The cap bounds that reach.
MAX_REPORT_LOOKBACK_HOURS = 14 * 24


def member_reported_at(member, default_now):
    """Lower bound for 'when the customer reported' — the action_log `createdat >`
    floor, so only fixes AFTER the complaint count. Derived from the feed's
    paged_at minus the member's age_hours at page time, but the reach-back is
    CAPPED (MAX_REPORT_LOOKBACK_HOURS) and age_hours is validated: a missing,
    negative, or absurdly-large value (it is AI-transcribed through clusters.json,
    so not trusted) falls back to paged_at — the moment the issue was confirmed
    systemic. Falling back to paged_at is the SAFE direction: a later floor can
    only DROP a match, never invent one."""
    paged = member.get("paged_at")
    if not isinstance(paged, (int, float)):
        return int(default_now)
    age = member.get("age_hours")
    if isinstance(age, (int, float)) and 0 <= age <= MAX_REPORT_LOOKBACK_HOURS:
        return int(paged - age * 3600)
    return int(paged)


def conversation_suppressed(conv, member_email, bot_admin_id):
    """(reason | None). Non-None means skip — never message this conversation.

    Mirrors resolve-notify.conversation_suppressed: identity must be POSITIVELY
    confirmed (email match) before any outbound, and we never reopen a
    closed/snoozed conv, never speak over a human assignee/last-human-reply, never
    touch a social/abuse-tagged conv. A customer who spoke LAST is NOT suppressed
    — a still-waiting customer is exactly who should hear the update."""
    src = conv.get("source") or {}
    au = src.get("author") or {}
    conv_email = (au.get("email") or "").strip().lower()
    # Fail CLOSED: a falsey member_email or any mismatch suppresses, so outbound
    # never goes without a positive, equal email match. Members with no email
    # (anonymous conversations) are never auto-messaged — they're filtered before
    # this gate, but the empty-email check here is defense-in-depth.
    if not member_email or conv_email != member_email:
        return "email-mismatch"
    if conv.get("state") != "open":
        return "not-open"
    assignee = conv.get("admin_assignee_id")
    if assignee and str(assignee) != str(bot_admin_id):
        return "assignee-human"
    tags = {str(t.get("name", "")).lower()
            for t in (conv.get("tags") or {}).get("tags", [])}
    if tags & BLOCKED_CONV_TAGS:
        return "blocked-tag"
    parts = (conv.get("conversation_parts") or {}).get("conversation_parts") or []
    if parts:
        last = parts[-1]
        a = last.get("author") or {}
        if a.get("type") in ("admin", "team") and str(a.get("id")) != str(bot_admin_id):
            return "human-reply"
    return None


def _conv_id_from_link(value):
    m = _CONV_ID_RE.search(str(value))
    return m.group(1) if m else None


# --------------------------------------------------------------------------
# Feed + state (atomic; seed on absent).
# --------------------------------------------------------------------------
def load_feed(path, now_epoch, lookback_days):
    """Read the append-only cluster feed the watchdog writes. De-dupe to one
    OPEN member per (issue_slug, conv_id), keeping the most-recent paged line.
    Drop members older than the look-back. Returns a list of member dicts:
    {issue_slug, title, symptom, conv_id, email, cites, age_hours, paged_at}."""
    horizon = now_epoch - lookback_days * 86400
    by_key = {}
    try:
        with open(path) as f:
            lines = f.readlines()
    except FileNotFoundError:
        return []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue  # a single bad line must not sink the run
        if not isinstance(row, dict):
            continue  # valid JSON but not an object (scalar/list) — skip, don't crash
        paged_at = row.get("paged_at")
        if not isinstance(paged_at, (int, float)) or paged_at < horizon:
            continue
        slug = row.get("issue_slug") or ""
        for m in row.get("members") or []:
            conv_id = str(m.get("conv_id") or "").strip()
            if not re.fullmatch(r"[0-9]+", conv_id):
                continue
            key = (slug, conv_id)
            prev = by_key.get(key)
            if prev and prev["paged_at"] >= paged_at:
                continue
            by_key[key] = {
                "issue_slug": slug,
                "title": row.get("title") or slug,
                "symptom": row.get("symptom") or "",
                "conv_id": conv_id,
                "email": (m.get("email") or "").strip().lower(),
                "cites": m.get("cites") or [],
                "age_hours": m.get("age_hours"),
                "paged_at": int(paged_at),
            }
    return list(by_key.values())


def compact_feed(path, now_epoch, lookback_days):
    """Atomically rewrite the append-only feed keeping only within-horizon lines,
    bounding its disk growth. Past-horizon lines are already ignored by load_feed,
    so dropping them loses nothing; still-open members within the window are kept
    (the dedup that prevents re-acting lives in state.json, NOT in feed removal).
    Best-effort: a failure just leaves the feed as-is. The watchdog (the only
    appender) runs hours apart from the matcher, so the read-then-replace window
    does not realistically collide with an append."""
    horizon = now_epoch - lookback_days * 86400
    try:
        with open(path) as f:
            lines = f.readlines()
    except FileNotFoundError:
        return
    kept, dropped = [], 0
    for line in lines:
        s = line.strip()
        if not s:
            continue
        try:
            paged_at = json.loads(s).get("paged_at")
        except (json.JSONDecodeError, AttributeError):
            dropped += 1  # torn/garbage line — drop during compaction
            continue
        if isinstance(paged_at, (int, float)) and paged_at >= horizon:
            kept.append(s + "\n")
        else:
            dropped += 1
    if dropped == 0:
        return  # nothing stale — don't churn the file
    tmp = f"{path}.tmp.{os.getpid()}"
    try:
        with open(tmp, "w") as f:
            f.writelines(kept)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except OSError as e:
        print(f"WARN: feed compaction failed: {e}", file=sys.stderr)


def load_state(path):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        # Corrupt/truncated state is NOT treated as seeded — return None so the
        # caller re-seeds (sends nothing) rather than mass-acting.
        return None


def write_state(path, state):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w") as f:
        json.dump(state, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


SEED_SENTINEL = "__seeded_at__"


def member_state_key(member):
    return f"conv:{member['conv_id']}"


def already_acted(state, member):
    return member_state_key(member) in state


def prune_state(state, now_epoch, keep_days=120):
    cutoff = now_epoch - keep_days * 86400
    return {k: v for k, v in state.items()
            if k == SEED_SENTINEL or (isinstance(v, (int, float)) and v >= cutoff)}


# --------------------------------------------------------------------------
# ClickUp reverse index (conv_id -> open task ids), built once per run.
# --------------------------------------------------------------------------
def build_conv_to_tasks(key, list_id):
    """conv_id -> [task_id] for OPEN tasks carrying the #417 Intercom Link field.
    Best-effort; returns {} on any error so a ClickUp hiccup never blocks the
    customer-facing notify/close (the conversation is the source of truth here)."""
    index = {}
    try:
        page = 0
        while page < 30:
            import urllib.parse
            q = urllib.parse.urlencode({"include_closed": "false", "subtasks": "false",
                                        "page": str(page)})
            data = clickup_get(f"{CLICKUP_API}/list/{list_id}/task?{q}", key)
            tasks = data.get("tasks", [])
            if not tasks:
                break
            for t in tasks:
                for cf in t.get("custom_fields", []):
                    if cf.get("id") == INTERCOM_LINK_FIELD and cf.get("value"):
                        cid = _conv_id_from_link(cf["value"])
                        if cid:
                            index.setdefault(cid, []).append(t.get("id"))
            if data.get("last_page"):
                break
            page += 1
    except (RuntimeError, urllib.error.URLError, ValueError, KeyError) as e:
        print(f"WARN: ClickUp index build failed ({type(e).__name__}: {e}); "
              f"will notify/close conversations without flipping tickets", file=sys.stderr)
        return {}
    return index


def mark_ticket_verification_required(task_id, key, route, at):
    """Keep the ticket waiting because an entity touch is not proof of success."""
    body = (f"Automated closure by resolution-matcher — a data fix "
            f"({route}) touching this customer's cited entity executed at {at}; "
            f"customer was notified to verify. Keeping the ticket waiting until "
            f"the customer-visible result is confirmed.")
    s, resp = http("POST", f"{CLICKUP_API}/task/{task_id}/comment",
                   {"Authorization": key},
                   body={"comment_text": body, "notify_all": False})
    if s not in (200, 201):
        raise RuntimeError(f"clickup comment {task_id} -> {s}: {resp}")

    task = clickup_get(f"{CLICKUP_API}/task/{task_id}", key)
    desired = outcome_tag("verification-required")
    for tag in sorted(outcome_tags_of(task) - {desired}):
        s, resp = http(
            "DELETE",
            f"{CLICKUP_API}/task/{task_id}/tag/{urllib.parse.quote(tag, safe='')}",
            {"Authorization": key},
        )
        if s not in (200, 204):
            raise RuntimeError(f"clickup remove outcome tag {task_id} -> {s}: {resp}")
    if desired not in outcome_tags_of(task):
        s, resp = http(
            "POST",
            f"{CLICKUP_API}/task/{task_id}/tag/{urllib.parse.quote(desired, safe='')}",
            {"Authorization": key},
        )
        if s not in (200, 201):
            raise RuntimeError(f"clickup add outcome tag {task_id} -> {s}: {resp}")
    clickup_put(f"{CLICKUP_API}/task/{task_id}", key, {"status": "waiting"})


# --------------------------------------------------------------------------
# Slack roll-up (best-effort; never fails the run).
# --------------------------------------------------------------------------
def _read_slack_token(config_path, account):
    try:
        with open(config_path) as f:
            cfg = json.load(f)
        return cfg["channels"]["slack"]["accounts"][account]["botToken"]
    except (OSError, KeyError, ValueError, TypeError):
        return None


def _slack_escape(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def build_rollup_text(closed):
    """mrkdwn roll-up: 'your fixes closed N convs across M issues', attributed to
    the action_log row (route + admin who shipped it + when). This is the part
    that reports back to Aaron what his work actually closed. Only ever built on a
    real (--apply) run — the roll-up post is --apply-gated — so the verb is
    unconditionally 'closed'."""
    n = len(closed)
    by_issue = {}
    for c in closed:
        by_issue.setdefault(c["issue_slug"], []).append(c)
    m = len(by_issue)
    head = (f":white_check_mark: *resolution-matcher: closed {n} conversation"
            f"{'' if n == 1 else 's'} across {m} systemic issue{'' if m == 1 else 's'}* "
            f"— matched to fixes already shipped")
    lines = [head]
    for slug, members in list(by_issue.items())[:15]:
        title = _slack_escape(members[0].get("title") or slug)
        fix = members[0].get("fix") or {}
        who = fix.get("requester") or "an admin"
        route = _slack_escape(fix.get("route") or "?")
        at = _slack_escape(fix.get("at") or "?")
        lines.append(f"• *{title}* — {len(members)} customer(s) "
                     f"· fix: `{route}` by {_slack_escape(who)} at {at}")
    if len(by_issue) > 15:
        lines.append(f"_…and {len(by_issue) - 15} more issue(s)_")
    return "\n".join(lines)


def post_slack(text, channel, config_path, account):
    token = _read_slack_token(config_path, account)
    if not token:
        print(f"WARN: no Slack token for '{account}' in {config_path}; roll-up skipped",
              file=sys.stderr)
        return False
    try:
        s, body = http("POST", SLACK_API, {"Authorization": f"Bearer {token}"},
                       body={"channel": channel, "text": text,
                             "unfurl_links": False, "unfurl_media": False}, attempts=1)
        if not (isinstance(body, dict) and body.get("ok")):
            print(f"WARN: Slack post failed: {body}", file=sys.stderr)
            return False
        return True
    except Exception as e:  # noqa: BLE001 — best-effort by contract
        print(f"WARN: Slack post error: {type(e).__name__}: {str(e)[:140]}", file=sys.stderr)
        return False


# --------------------------------------------------------------------------
# Fix detection (network seam + pure predicate).
# --------------------------------------------------------------------------
def detect_fix(member, now_epoch, muso_bin, lookback_days, _query=None):
    """Return the EARLIEST qualifying action_log fix row for this member, or None.

    A 'fix' = an admin DATA-FIX route (the constant _FIX_ROUTE_PREDICATES) that
    touched one of the exact entity UUIDs the customer cited, AFTER they reported.
    None when the member cited no entity UUID (un-backtestable -> stays open,
    reported honestly in the roll-up) or no qualifying row exists. Raises
    RuntimeError on a query failure (fail closed).

    `_query` is the action_log query function; defaulting to None and resolving
    query_action_log at call time keeps main()'s path patchable in tests (a
    default-arg capture would freeze the real network function)."""
    query = _query or query_action_log
    entity_ids = extract_entity_ids(member.get("cites"))
    if not entity_ids:
        return None
    since = member_reported_at(member, now_epoch)
    sql = build_action_log_sql(entity_ids, since, lookback_days)
    rows = query(sql, muso_bin)
    if not rows:
        return None
    row = rows[0]
    return {"route": row.get("route", ""), "method": row.get("method", ""),
            "requester": row.get("requester", ""), "at": row.get("at", ""),
            "matched_entity": entity_ids[0]}


# --------------------------------------------------------------------------
# Shadow log (reversibility).
# --------------------------------------------------------------------------
def shadow_append(path, record):
    try:
        with open(path, "a") as f:
            f.write(json.dumps(record) + "\n")
            f.flush()
    except OSError:
        sys.stderr.write("SHADOW " + json.dumps(record) + "\n")


# --------------------------------------------------------------------------
# Inline self-test (a broken detector pages via cron-health, never runs blind).
# --------------------------------------------------------------------------
def _self_test():
    # entity extraction
    assert extract_entity_ids(
        ["https://credits.muso.ai/track/78d7dcd3-3b1c-4aaa-bbbb-0123456789ab",
         "78d7dcd3-3b1c-4aaa-bbbb-0123456789ab", "no id here"]
    ) == ["78d7dcd3-3b1c-4aaa-bbbb-0123456789ab"], "entity extract/dedupe"
    assert extract_entity_ids([]) == [], "no cites -> no ids"

    # SQL is built only from validated values; a bad uuid is rejected
    try:
        build_action_log_sql(["not-a-uuid"], 0, 60)
        assert False, "unsafe uuid accepted"
    except ValueError:
        pass
    sql = build_action_log_sql(["78d7dcd3-3b1c-4aaa-bbbb-0123456789ab"], 1000, 60)
    # The cited id is matched in the ROUTE (primary target), NOT anywhere in
    # requestdata — that is the fix for the merge-loser / claim-denial false match.
    assert "route LIKE '%78d7dcd3-3b1c-4aaa-bbbb-0123456789ab%'" in sql, "id matched on route"
    assert "requestdata" not in sql.split("WHERE", 1)[1], "WHERE must not touch requestdata"
    assert "from_unixtime(1000)" in sql and "';" not in sql, "sql shape"
    # Fix-route predicates: credit edits + bare profile edit; attribution via email.
    assert "route LIKE '%/credits%'" in sql, "credits predicate present"
    assert "regexp_like(route, '^/api/v3/admin/profile/" in sql, "bare-profile predicate present"
    assert "COALESCE(email, '') AS requester" in sql, "attribution via email column"
    # merge / claiming are not credit routes and not the bare-profile route -> excluded.
    for noise in ("/api/v3/admin/profiles/merge", "/api/v3/admin/profile/abc/cache"):
        assert "LIKE '" + noise not in sql, "no hardcoded noise route in predicates"

    # reported_at: paged_at - age, capped, age validated
    assert member_reported_at({"paged_at": 10000, "age_hours": 1}, 0) == 10000 - 3600, "reported_at age"
    assert member_reported_at({"paged_at": 10000}, 0) == 10000, "reported_at fallback paged"
    assert member_reported_at({}, 777) == 777, "reported_at fallback now"
    big = MAX_REPORT_LOOKBACK_HOURS + 1000
    assert member_reported_at({"paged_at": 10**9, "age_hours": big}, 0) == 10**9, "age over cap -> paged_at"
    assert member_reported_at({"paged_at": 10**9, "age_hours": -5}, 0) == 10**9, "negative age -> paged_at"

    # suppression gates
    base_conv = {"source": {"author": {"type": "user", "email": "a@b.com"}},
                 "state": "open", "conversation_parts": {"conversation_parts": []}}
    assert conversation_suppressed(base_conv, "a@b.com", CAROLINE_ADMIN_ID) is None, "clean conv ok"
    assert conversation_suppressed(base_conv, "other@x.com", CAROLINE_ADMIN_ID) == "email-mismatch", "wrong customer"
    assert conversation_suppressed(base_conv, "", CAROLINE_ADMIN_ID) == "email-mismatch", "empty member email fail-closed"
    closed_conv = dict(base_conv, state="closed")
    assert conversation_suppressed(closed_conv, "a@b.com", CAROLINE_ADMIN_ID) == "not-open", "never reopen closed"
    human = dict(base_conv, conversation_parts={"conversation_parts": [
        {"author": {"type": "admin", "id": "999"}}]})
    assert conversation_suppressed(human, "a@b.com", CAROLINE_ADMIN_ID) == "human-reply", "human spoke last"
    cust = dict(base_conv, conversation_parts={"conversation_parts": [
        {"author": {"type": "user", "id": "u1"}}]})
    assert conversation_suppressed(cust, "a@b.com", CAROLINE_ADMIN_ID) is None, "customer-last allowed"
    assigned = dict(base_conv, admin_assignee_id="42")
    assert conversation_suppressed(assigned, "a@b.com", CAROLINE_ADMIN_ID) == "assignee-human", "human assignee"
    tagged = dict(base_conv, tags={"tags": [{"name": "instagram"}]})
    assert conversation_suppressed(tagged, "a@b.com", CAROLINE_ADMIN_ID) == "blocked-tag", "social tag"

    # detect_fix: cited entity touched after report -> match; un-cited -> None
    def fake_query(sql, _bin):
        return [{"route": "/api/v3/admin/profile/abc/credits", "method": "PUT",
                 "requester": "aaron@muso.ai", "at": "2026-06-29 10:00:00 UTC"}]
    m = {"cites": ["track/78d7dcd3-3b1c-4aaa-bbbb-0123456789ab"], "paged_at": 1000}
    fix = detect_fix(m, 2000, "muso", 60, _query=fake_query)
    assert fix and fix["requester"] == "aaron@muso.ai", "detect_fix match"
    none_m = {"cites": ["no uuid"], "paged_at": 1000}
    assert detect_fix(none_m, 2000, "muso", 60, _query=fake_query) is None, "no cite -> no match"

    def empty_query(sql, _bin):
        return []
    assert detect_fix(m, 2000, "muso", 60, _query=empty_query) is None, "no row -> no match"

    return True


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
def _now():
    return int(os.environ.get("RESOLUTION_NOW") or time.time())


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--apply", action="store_true",
                    help="actually message/close/write state (default: dry-run)")
    ap.add_argument("--limit", type=int, default=0, help="override the per-run act cap")
    ap.add_argument("--self-test", action="store_true",
                    help="run the inline pure-logic self-test and exit")
    args = ap.parse_args(argv)

    # Self-test first — a broken detector must page, never run.
    try:
        _self_test()
    except AssertionError as e:
        print(f"resolution-matcher: SELF-TEST FAILED: {e}", file=sys.stderr)
        return 2
    if args.self_test:
        print("self-test ok")
        return 0

    if os.environ.get("RESOLUTION_SKIP_HOST_GUARD") != "1" \
            and socket.gethostname() != "ovh-node-8":
        print("resolution-matcher: not on ovh-node-8 — refusing "
              "(set RESOLUTION_SKIP_HOST_GUARD=1 to override)", file=sys.stderr)
        return 0

    token = os.environ.get("MUSOAI_INTERCOM_TOKEN")
    if not token:
        print("resolution-matcher: MUSOAI_INTERCOM_TOKEN is required", file=sys.stderr)
        return 1
    muso_bin = os.environ.get("MUSO_BIN", "muso")
    clickup_key = os.environ.get("CLICKUP_API_KEY")
    admin_id = os.environ.get("INTERCOM_ADMIN_ID") or CAROLINE_ADMIN_ID
    list_id = os.environ.get("CLICKUP_LIST_ID", DEFAULT_LIST_ID)
    feed_path = os.environ.get("RESOLUTION_FEED_PATH",
                               "/var/lib/resolution-matcher/cluster-feed.jsonl")
    state_path = os.environ.get("RESOLUTION_STATE_PATH",
                                "/var/lib/resolution-matcher/state.json")
    shadow_path = os.environ.get("RESOLUTION_SHADOW_LOG",
                                 "/var/log/resolution-matcher-shadow.jsonl")
    default_max = int(os.environ.get("RESOLUTION_MATCHER_MAX", "15"))
    lookback_days = int(os.environ.get("RESOLUTION_LOOKBACK_DAYS", "60"))
    cap = args.limit if args.limit > 0 else default_max

    now_epoch = _now()
    members = load_feed(feed_path, now_epoch, lookback_days)
    # Anonymous (no-email) members can never pass the email cross-check, so they
    # are never auto-messaged; drop them up front and report the count.
    anon = [m for m in members if not m.get("email")]
    members = [m for m in members if m.get("email")]

    state = load_state(state_path)

    # ---- Cold start: first run / wiped / corrupt state seeds everything and
    # sends nothing, so a fresh deploy previews counts before run #2 acts.
    if not state:
        seed = {SEED_SENTINEL: now_epoch}
        for m in members:
            seed[member_state_key(m)] = now_epoch
        if args.apply:
            write_state(state_path, seed)
        print(f"resolution-matcher: SEEDED {len(members)} open member(s); acted 0 "
              f"(cold start{'' if args.apply else ', dry-run — state NOT written'})")
        return 0

    fresh = [m for m in members if not already_acted(state, m)]

    # ---- Detect fixes (the autonomous data-backtest). A query failure on one
    # member fails THAT member closed (skip), not the whole run.
    matched, query_errors, no_cite, no_fix = [], 0, 0, 0
    for m in fresh:
        if not extract_entity_ids(m.get("cites")):
            no_cite += 1
            continue
        try:
            fix = detect_fix(m, now_epoch, muso_bin, lookback_days)
        except RuntimeError as e:
            print(f"resolution-matcher: action_log query failed for conv "
                  f"{m['conv_id']} ({e}); leaving open", file=sys.stderr)
            query_errors += 1
            continue
        if fix:
            m = dict(m, fix=fix)
            matched.append(m)
        else:
            no_fix += 1

    matched.sort(key=lambda x: x["conv_id"])  # deterministic order

    # ---- Circuit breaker: a large matched set on a freshly-written state file
    # signals a wipe/feed-shape bug, not normal flow. Page, don't act. Keys on the
    # DEFAULT max so --limit can't disarm it.
    try:
        state_age = now_epoch - int(os.path.getmtime(state_path))
    except OSError:
        state_age = 10 ** 9
    if len(matched) > default_max and state_age < 12 * 3600:
        text = (f":rotating_light: resolution-matcher ABORTED: {len(matched)} "
                f"matched fixes on a state file written {state_age // 60}min ago "
                f"— looks like wiped/mangled state or a feed bug. Acted on nothing. "
                f"Investigate before re-enabling.")
        print(text, file=sys.stderr)
        _post_rollup_anomaly(text)
        return 2

    print(f"resolution-matcher: feed_members={len(members)} (anon_dropped={len(anon)}) "
          f"fresh={len(fresh)} matched={len(matched)} no_cite={no_cite} "
          f"no_fix={no_fix} query_errors={query_errors}", file=sys.stderr)

    # ---- Build the ClickUp reverse index once (best-effort; {} if unavailable).
    conv_to_tasks = build_conv_to_tasks(clickup_key, list_id) if clickup_key else {}

    to_act = matched[:cap]
    acted, failed, suppressed = [], 0, {}
    seen_convs = set()
    dirty = False
    # Pre-flight: prove the state file is writable BEFORE sending anything. The
    # send is recorded by a write_state right after each reply; if that write
    # failed (read-only / full fs) the message would have gone out UNRECORDED and
    # the next run would re-message. Failing closed here turns that into a
    # send-nothing abort instead of a customer-facing double-message.
    if args.apply and to_act:
        try:
            write_state(state_path, state)
        except OSError as e:
            print(f"resolution-matcher: state path {state_path} not writable "
                  f"({e}); refusing to act (un-recorded sends would re-message)",
                  file=sys.stderr)
            return 2
    for m in to_act:
        cid = m["conv_id"]
        try:
            if cid in seen_convs:
                continue
            conv = get_conversation(cid, token)
            reason = conversation_suppressed(conv, m["email"], admin_id)
            if reason:
                suppressed[reason] = suppressed.get(reason, 0) + 1
                if args.apply and reason in DURABLE_SUPPRESSIONS:
                    # Record acted ONLY for stable suppression reasons, so we don't
                    # re-GET them every run. Transient reasons (email-mismatch,
                    # not-open) are left unrecorded so a later legitimate notify is
                    # still possible — the conv was never messaged.
                    state[member_state_key(m)] = now_epoch
                    dirty = True
                continue
            print(json.dumps({"conv_id": cid, "issue_slug": m["issue_slug"],
                              "fix_route": m["fix"]["route"], "fix_at": m["fix"]["at"],
                              "mode": "apply" if args.apply else "dry-run"}))
            if args.apply:
                # 1) The customer-facing write FIRST.
                post_intercom_reply(cid, admin_id, MESSAGE, token)
                # 2) Persist the send IMMEDIATELY — before the close/flip below.
                #    Our reply is now the last message, and the bot's own reply is
                #    NOT a "human-reply" suppression, so if a later step failed and
                #    we had NOT recorded the send, the next run would re-match this
                #    still-open conv and re-send. Recording here makes the send
                #    exactly-once even if close/flip throw.
                seen_convs.add(cid)
                state[member_state_key(m)] = now_epoch
                write_state(state_path, state)
                dirty = True
                # 3) Close the conv + mark linked tickets verification-required —
                #    BEST-EFFORT. If the direct close fails, leaving the conversation
                #    open is safe; the waiting ticket deliberately does not qualify
                #    for the customer-complete closer.
                updated_tickets = []
                try:
                    close_conversation(cid, admin_id, token)
                except (RuntimeError, urllib.error.URLError, ValueError) as e:
                    print(f"resolution-matcher: conv close failed for {cid} "
                          f"(message sent; leaving conversation open): {e}", file=sys.stderr)
                for tid in conv_to_tasks.get(cid, []):
                    try:
                        mark_ticket_verification_required(
                            tid, clickup_key, m["fix"]["route"], m["fix"]["at"])
                        updated_tickets.append(tid)
                    except (RuntimeError, urllib.error.URLError, ValueError) as e:
                        print(f"resolution-matcher: ticket outcome update failed for {tid}: {e}",
                              file=sys.stderr)
                shadow_append(shadow_path, {
                    "conv_id": cid, "issue_slug": m["issue_slug"], "email_acted": True,
                    "verification_required_tickets": updated_tickets, "fix": m["fix"],
                    "at": now_epoch})
            else:
                seen_convs.add(cid)
            acted.append(m)
        except urllib.error.HTTPError as e:
            try:
                detail = e.read().decode("utf-8", "replace")[:200]
            except Exception:
                detail = ""
            print(f"[{cid}] ERROR HTTP {e.code}: {detail}", file=sys.stderr)
            failed += 1
        except (RuntimeError, urllib.error.URLError, OSError, ValueError, KeyError) as e:
            # OSError covers a per-act write_state failure after the message went
            # out: contain it to THIS member (failed++, loop continues + roll-up +
            # compaction still run) instead of crashing the whole daily run. The
            # pre-flight above makes this path very unlikely.
            print(f"[{cid}] ERROR {type(e).__name__}: {e}", file=sys.stderr)
            failed += 1

    if args.apply and dirty:
        write_state(state_path, prune_state(state, now_epoch))

    backlog = len(matched) > cap
    print(f"resolution-matcher: {'acted' if args.apply else 'would-act'}={len(acted)} "
          f"failed={failed} capped={backlog} "
          f"suppressed={json.dumps(suppressed, sort_keys=True)}")

    # ---- Roll up to Aaron: what the fixes closed. Post only on a real (--apply)
    # run so the priority channel carries ACTUAL closures, never a manual
    # dry-run preview (dry-run still prints the would-act lines to stdout). The
    # circuit-breaker alert above is the one exception — it pages regardless.
    if args.apply and (acted or backlog or query_errors):
        channel = os.environ.get("RESOLUTION_SUMMARY_CHANNEL", DEFAULT_SUMMARY_CHANNEL)
        cfg = os.environ.get("SLACK_NOTIFY_CONFIG", "/root/.openclaw-main/openclaw.json")
        account = os.environ.get("RESOLUTION_SLACK_ACCOUNT", "operations")
        text = build_rollup_text(acted)
        if backlog:
            text += f"\n_capped at {cap} this run; {len(matched) - cap} more queued for next run_"
        if query_errors:
            text += f"\n_{query_errors} member(s) skipped on action_log query error_"
        posted = post_slack(text, channel, cfg, account)
        print(f"resolution-matcher: roll-up {'posted' if posted else 'skipped/failed'} -> {channel}",
              file=sys.stderr)

    # Bound the append-only feed's disk growth (drops only past-horizon lines that
    # load_feed already ignores). --apply only — a dry-run mutates nothing.
    if args.apply:
        compact_feed(feed_path, now_epoch, lookback_days)

    return 3 if failed else 0


def _post_rollup_anomaly(text):
    channel = os.environ.get("RESOLUTION_SUMMARY_CHANNEL", DEFAULT_SUMMARY_CHANNEL)
    cfg = os.environ.get("SLACK_NOTIFY_CONFIG", "/root/.openclaw-main/openclaw.json")
    account = os.environ.get("RESOLUTION_SLACK_ACCOUNT", "operations")
    post_slack(text, channel, cfg, account)


if __name__ == "__main__":
    sys.exit(main())
