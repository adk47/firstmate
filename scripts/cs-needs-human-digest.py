#!/usr/bin/env python3
"""Daily READ-ONLY "needs-human" ranked digest of open Intercom conversations.

Phase 0.3 of docs/plans/autonomous-cs-machine.md. Every live sweeper
(close-resolved-conversations, resolve-notify, resolution-matcher,
overdue-verification-notifier, close-merged-tickets) only acts on
conversations it can already tie to a resolved ticket or a shipped fix. The
residue — open conversations nothing has touched — piles up with no single
ranked view for Jan, who otherwise has to pull ClickUp by hand. This script
lists OPEN Intercom conversations, EXCLUDES anything a sibling sweeper's
state already owns (the de-confliction invariant — double-surfacing wastes
Jan's time), buckets what's left, ranks the actionable residue by age, and
posts ONE Block Kit digest to #cs_chats.

THIS SCRIPT IS READ-ONLY ON INTERCOM. It never closes, snoozes, tags,
replies to, or otherwise writes to a conversation. Its only side effect is
one Slack post, gated behind --post (default: dry-run, prints to stdout).

A conversation's `contacts` field is a Contact Reference list
(`{type, id, external_id}` — no email; per the Intercom 2.11 OpenAPI spec's
`contact_reference` schema), so resolving the real customer contact's email
requires a follow-up GET /contacts/{id} (also read-only), cached at module
level by contact id to avoid an N+1 GET per conversation.

Buckets (deterministic, no LLM judgment):
  - needs-human:          customer spoke last (last_contact_reply_at >
                           last_admin_reply_at, or never replied to) — we
                           owe them a reply. Ranked oldest-waiting-first.
  - needs-customer-input: we (admin) spoke last — waiting on the customer.
  - dup-candidate:        the same contact email has >=2 open conversations
                           (checked independent of the two buckets above).

De-confliction is by CONVERSATION ID, never by contact email (read
defensively — a missing/empty/corrupt state file means "no ownership",
NEVER a crash). Every sibling source below records the conversation id, so
id-matching is sufficient; matching email against these append-only,
never-pruned logs would permanently exclude a RETURNING customer's
brand-new, unrelated conversation (their email lingers in
close-resolved-shadow.jsonl forever after any single past close, which
would silently hide their next real issue from Jan). Contact email is used
ONLY for dup-candidate detection among currently-open conversations (a
live, self-bounded signal), never as a historical-ownership key. See
docs/plans/cs-ops-drain-spec.md (commit 2c04734b) for the corrected design
this mirrors.
  - CLOSE_SHADOW_LOG            /var/log/close-resolved-shadow.jsonl
                                 (jsonl; each line has "id")
  - RESOLVE_NOTIFY_STATE        /var/lib/resolve-notify/notified.json
                                 (json; keys include "conv:<id>")
  - RESOLUTION_STATE_PATH       /var/lib/resolution-matcher/state.json
                                 (json; keys include "conv:<id>")
  - RESOLUTION_SHADOW_LOG       /var/log/resolution-matcher-shadow.jsonl
                                 (jsonl; each line has "conv_id")
  - OVERDUE_NOTIFY_STATE        /var/lib/overdue-verification-notifier/notified.json
                                 (json; keys include "conv:<id>")
  - DEDUP_SHADOW_LOG            /var/log/dedup-shadow.jsonl (best-effort: the
                                 close-merged-tickets / dedup path today keys
                                 on ClickUp task + Muso profile ids, not
                                 Intercom conversation id, so this read
                                 is a defensive no-op until that changes —
                                 see the script docstring / PR notes for the
                                 known gap)
  NOTE: close-stale-shadow.jsonl is deliberately NOT a digest source — see
  default_state_paths(); excluding it would permanently hide conversations
  the customer reopened after a silent stale-close.

Env:
  MUSOAI_INTERCOM_TOKEN       required
  DIGEST_SKIP_HOST_GUARD      optional, "1" to run off ovh-node-8 (tests)
  DIGEST_HOSTNAME_OVERRIDE    optional, override the perceived hostname the
                              host guard checks (tests only — lets CI, which
                              itself runs ON ovh-node-8, exercise BOTH guard
                              branches deterministically instead of depending
                              on the runner's real hostname)
  DIGEST_SUMMARY_CHANNEL      optional, default C0ANM0PN9L5 (#cs_chats)
  DIGEST_SLACK_ACCOUNT        optional, default operations
  SLACK_NOTIFY_CONFIG         optional, default /root/.openclaw-main/openclaw.json
  INTERCOM_WORKSPACE_ID       optional, default dwjzhcge (deeplink workspace —
                              see plugins/support-tools/src/tools/ticket-format.ts
                              intercomDeeplink / scripts/intercom-data-complaint-
                              watchdog.py deeplink())
  DIGEST_NOW                  optional, epoch override (tests)
  DIGEST_TOP_N                optional, default 15 (ranked needs-human rows shown)
  CS_DIGEST_STATE              optional, default
                                /var/lib/cs-needs-human-digest/surfaced.json —
                                --delta's own state file:
                                {conv_id: {first_surfaced, aged_flagged}}.
                                Updated ONLY on a successful --post (dry-run
                                never mutates it), and only for rows Jan
                                actually saw this run (a full digest's
                                top_n slice, or --delta's render-capped
                                new+aging list — see build_next_state).
                                Missing = empty (first run); corrupt = FAIL
                                LOUD for --delta (see CorruptDigestState) —
                                never silently reset, which would re-ping Jan
                                with hundreds of items. A corrupt file's
                                blast radius is scoped to --delta only: the
                                pre-existing 13:30 FULL digest (--post or
                                dry-run) degrades instead — it warns to
                                stderr, renders/posts normally, and skips
                                persisting to the known-bad file (never
                                overwrites corruption with a
                                reconstructed-from-empty state).
  CS_DIGEST_AGING_HOURS         optional, default 20 — a needs-human item
                                waiting longer than this gets a distinct
                                "⚠️ aging" line in both full and delta digests.
  CS_DIGEST_ACTIONABLE_DAYS     optional, default 30 — needs-human items whose
                                waiting_since is older than this many days are
                                backlog, not actionable (wired in main() by
                                card B).
  CS_DIGEST_AGING_MENTION_UID   optional — Slack user id (e.g. U038BM16T7W)
                                rendered as <@UID> in the header line, ONLY
                                when at least one aging item is present in
                                this run's digest. A literal @name pings
                                nobody (repo doctrine), so this must be a
                                real Slack UID, never hardcoded in the
                                script. If unset while aging items exist, no
                                mention is rendered and a stderr warning is
                                printed.
  CS_DIGEST_JEV_SAMPLE_SIZE     optional, default 25 — Phase 2a shadow-only
                                Jev sample size (docs/plans/jev-adoption.md
                                #2a; see JEV_SURFACE_NEEDS_HUMAN_DIGEST
                                below). Each run draws a FRESH random sample
                                (never the ranked/rendered head — that order
                                is oldest-waiting-first, so the head is a
                                biased slice) of this size from the full
                                needs_human bucket and fires one shadow Jev
                                judgment per sampled conversation; this can
                                never change what gets rendered or posted.
                                `actual` for this surface is always
                                "needs-human" (the bucket every sampled item
                                is drawn from), which makes it a WEAK label —
                                this surface exists to measure what fraction
                                of Jan's needs-human backlog Jev independently
                                reads as still genuinely needing a human, not
                                to grade this script's own bucketing (which
                                the sample is drawn FROM, not compared
                                against). Those disagreements are meant to be
                                hand-labelled later, not treated as ground
                                truth from this script alone.

Flags:
  --post        actually post the digest to Slack (default: dry-run —
                 print the digest to stdout, post nothing)
  --limit N     cap the number of open conversations scanned this run
  --delta       post ONLY needs-human items never surfaced before, or that
                crossed the aging threshold since last surfaced (see
                CS_DIGEST_STATE). If neither exists this run, prints
                "NO_DELTA — nothing posted" and posts nothing (exit 0).
  --self-test   run the inline detector self-test and exit

Exit codes: 0 ok; 1 usage/env error or undelivered --post; 3 systematic
            contact-lookup failure (401/403, or 429/5xx persisting through
            retries — see ContactLookupFailed); 4 corrupt --delta state file,
            --delta runs ONLY (see CorruptDigestState) — a full-digest
            (non-delta) run, --post or dry-run, never returns 4: it degrades
            instead (see CS_DIGEST_STATE above); 5 the digest WAS delivered but
            the anti-repeat checkpoint failed to persist (disk/permission) —
            the previous valid state is preserved; repair and the next run
            recovers (see save_delta_state).
"""
import argparse
import json
import os
import random
import re
import socket
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lib.jev_shadow import shadow_judge  # noqa: E402

INTERCOM_API = "https://api.intercom.io"
INTERCOM_VERSION = "2.11"
SLACK_API = "https://slack.com/api/chat.postMessage"
DEFAULT_SUMMARY_CHANNEL = "C0ANM0PN9L5"  # #cs_chats
DEFAULT_TOP_N = 15
DEFAULT_AGING_HOURS = 20
DEFAULT_ACTIONABLE_DAYS = 30
DEFAULT_DIGEST_STATE = "/var/lib/cs-needs-human-digest/surfaced.json"
DEFAULT_JEV_SAMPLE_SIZE = 25
# Deeplink workspace id — same default + env override as
# scripts/intercom-data-complaint-watchdog.py's deeplink() and
# plugins/support-tools/src/tools/ticket-format.ts's intercomDeeplink().
DEFAULT_WORKSPACE_ID = "dwjzhcge"

# Phase 2a shadow-only Jev surface (docs/plans/jev-adoption.md #2a). Judges,
# for a RANDOM sample of the needs_human bucket, whether the customer's own
# last message genuinely still calls for a human reply — independent of and
# strictly AFTER this script's own deterministic bucket_conversations()
# decision, never influencing it. See CS_DIGEST_JEV_SAMPLE_SIZE above for why
# `actual` is a weak label on this particular surface.
JEV_SURFACE_NEEDS_HUMAN_DIGEST = "needs-human-digest"
NEEDS_HUMAN_DIGEST_QUESTIONS = {
    "needs_human_reply_now": {
        "type": "noul",
        "instructions": (
            "State carries the customer's most recent message in this open "
            "conversation as `customer_message`, and — when one exists — the "
            "admin's message immediately BEFORE it as "
            "`preceding_admin_message`. This script's own bucket already "
            "established the customer spoke last by timestamp; decide "
            "independently whether the customer's own message TEXT genuinely "
            "still calls for a human reply, as opposed to text that reads as "
            "already closed out (a bare thanks, a closing remark) that "
            "merely landed after the admin's last reply."
        ),
        "criteria": {
            "true": "The customer's message reads as still needing an admin reply.",
            "false": "The customer's message reads as already closed out, despite being the last message chronologically.",
        },
    },
}


# --------------------------------------------------------------------------
# Network seam (module-level so tests monkeypatch these, never real HTTP).
# --------------------------------------------------------------------------
def _retry_json(req, attempts=4):
    for a in range(attempts):
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return json.load(resp)
        except urllib.error.URLError:
            if a == attempts - 1:
                raise
            time.sleep(2 * (a + 1))


def intercom_search(token, body):
    req = urllib.request.Request(
        f"{INTERCOM_API}/conversations/search",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                 "Content-Type": "application/json", "Intercom-Version": INTERCOM_VERSION},
        method="POST")
    return _retry_json(req)


# Bounded, single-attempt (no retry/backoff), short timeout — unlike
# _retry_json (used by this script's own correctness-critical GETs, which
# legitimately need generous retries), this fetch feeds ONLY a best-effort
# shadow Jev sample: a failure here just means that one sample is skipped
# this run (see needs_human_shadow_state), so it must be bounded exactly as
# tightly as the jev.sh call itself (jev_shadow.DEFAULT_TIMEOUT_S) rather
# than able to add minutes of latency chasing a single dead sample.
JEV_SHADOW_FETCH_TIMEOUT_S = 5


def get_conversation_for_shadow(conv_id, token):
    """GET /conversations/{id}?display_as=plaintext (read-only), single
    attempt, JEV_SHADOW_FETCH_TIMEOUT_S bound.

    Used ONLY to build state for the Phase 2a needs-human-digest shadow Jev
    sample below — this script's own real buckets never depend on
    conversation body text (fetch_open_convs only reads
    last_admin_reply_at/last_contact_reply_at). Always called from inside
    shadow_judge's build_state boundary (see needs_human_shadow_state), so a
    failure here is caught there and never reaches the digest itself."""
    req = urllib.request.Request(
        f"{INTERCOM_API}/conversations/{conv_id}?display_as=plaintext",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                 "Intercom-Version": INTERCOM_VERSION},
        method="GET")
    with urllib.request.urlopen(req, timeout=JEV_SHADOW_FETCH_TIMEOUT_S) as resp:
        return json.load(resp)


def _text_of(part):
    body = part.get("body") if part else None
    return re.sub(r"<[^>]+>", " ", body).strip() if body else ""


def needs_human_shadow_state(conv_id, token):
    """(state | None) for the needs-human-digest Jev question: the sampled
    conversation's most recent customer message plus the admin message
    immediately before it, if any. Fetches the conversation (network — the
    reason this is a build_state callable, not a plain dict). Returns None
    when the fetched conversation has no customer part to judge."""
    conv = get_conversation_for_shadow(conv_id, token)
    parts = (conv.get("conversation_parts") or {}).get("conversation_parts") or []
    last_customer_idx = None
    for i in range(len(parts) - 1, -1, -1):
        a = (parts[i].get("author") or {})
        if a.get("type") == "user":
            last_customer_idx = i
            break
    if last_customer_idx is None:
        return None
    preceding_admin = None
    for i in range(last_customer_idx - 1, -1, -1):
        a = (parts[i].get("author") or {})
        if a.get("type") in ("admin", "team"):
            preceding_admin = _text_of(parts[i])
            break
    return {
        "customer_message": _text_of(parts[last_customer_idx]),
        "preceding_admin_message": preceding_admin,
    }


def _jev_sample_size():
    raw = os.environ.get("CS_DIGEST_JEV_SAMPLE_SIZE")
    if not raw:
        return DEFAULT_JEV_SAMPLE_SIZE
    try:
        n = int(raw)
    except ValueError:
        return DEFAULT_JEV_SAMPLE_SIZE
    return n if n > 0 else DEFAULT_JEV_SAMPLE_SIZE


# Contact-email lookup cache (module-level, process-lifetime). Many open
# conversations share the same contact, so caching by contact id avoids an
# N+1 GET /contacts/{id} per conversation on every run.
_contact_email_cache = {}


class ContactLookupFailed(Exception):
    """A SYSTEMATIC contact-lookup failure — auth/permissions (401/403) or a
    rate-limit/outage (429/5xx) that persisted through retries. Distinct
    from a benign 404 (a genuinely missing/deleted contact), which is fine
    to treat as "no email" and let the run continue. This must propagate
    all the way to main() and fail the whole run loudly — silently
    swallowing it into an empty/cached email would silently disable
    email-based dup-candidate detection for however many conversations
    share the affected token/contact population, with no signal that it
    happened (same fail-loud principle as the --post delivery check)."""


def get_contact(contact_id, token, attempts=4):
    """GET /contacts/{contact_id} (read-only).

    - 404 (contact missing/deleted) -> None. Benign, expected, per-contact;
      the caller falls back to the validated source.author signal (or "")
      and the run continues normally.
    - 429 / transient 5xx -> retried with backoff; if still failing after
      `attempts`, raises ContactLookupFailed (a persistent capacity/outage
      condition, not a per-contact miss).
    - 401/403 -> raises ContactLookupFailed immediately (a token/permissions
      problem that will not resolve on retry and taints every subsequent
      lookup this run).
    - Any other unexpected HTTP status, or a network failure that persists
      through retries -> also raises ContactLookupFailed rather than
      silently returning None, per the same "don't swallow the systemic
      case" principle.
    """
    req = urllib.request.Request(
        f"{INTERCOM_API}/contacts/{contact_id}",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                 "Intercom-Version": INTERCOM_VERSION},
        method="GET")
    for a in range(attempts):
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            if e.code in (401, 403):
                raise ContactLookupFailed(
                    f"GET /contacts/{contact_id} -> {e.code} "
                    "(auth/permissions — not retryable)") from e
            if e.code == 429 or 500 <= e.code < 600:
                if a == attempts - 1:
                    raise ContactLookupFailed(
                        f"GET /contacts/{contact_id} -> {e.code} persisted "
                        f"through {attempts} attempts") from e
                time.sleep(2 * (a + 1))
                continue
            raise ContactLookupFailed(
                f"GET /contacts/{contact_id} -> {e.code} (unexpected status)") from e
        except (urllib.error.URLError, ValueError, OSError) as e:
            if a == attempts - 1:
                raise ContactLookupFailed(
                    f"GET /contacts/{contact_id} failed after {attempts} "
                    f"attempts: {type(e).__name__}: {e}") from e
            time.sleep(2 * (a + 1))
    return None  # unreachable — the loop always returns or raises


def contact_email_of(c, token):
    """The real customer contact's email.

    Fast path (the OVERWHELMING common case — one contact per conversation):
    when `source.author.type == "user"` (an Intercom identity-verified
    contact — the same validated gate plugins/intercom/src/filters.ts uses
    for `verifiedEmail`), that author IS the customer contact, so
    `source.author.email` IS the real email — use it directly, no GET. Doing
    a GET /contacts/{id} here anyway would be an N+1 scan across the entire
    open backlog (the cache only helps when conversations share a contact,
    which is rare) that can take minutes and hit Intercom rate limits,
    risking the whole daily digest failing (see get_contact's
    ContactLookupFailed).

    Only when the author is NOT a user (an admin/bot/campaign-started
    conversation — Muso staff or a bot, not the customer) does resolving the
    real customer email require the follow-up GET /contacts/{id} lookup: the
    conversation's `contacts` field is a Contact Reference list
    (`{type, id, external_id}` — verified against the Intercom 2.11 OpenAPI
    spec's `contact_reference` schema: it carries NO email), cached at
    module level (`_contact_email_cache` / `get_contact`).
    """
    src = c.get("source") or {}
    au = src.get("author") or {}
    if au.get("type") == "user":
        return (au.get("email") or "").strip().lower()

    contacts = ((c.get("contacts") or {}).get("contacts") or [])
    for ref in contacts:
        cid = ref.get("id")
        if not cid:
            continue
        if cid in _contact_email_cache:
            email = _contact_email_cache[cid]
        else:
            contact = get_contact(cid, token)
            email = ((contact or {}).get("email") or "").strip().lower()
            _contact_email_cache[cid] = email
        if email:
            return email
    return ""


def intercom_link(conv_id):
    """Stable Intercom ADMIN inbox deeplink built from the trusted conversation
    id — NOT `source.url` (that's where the conversation started, e.g. a
    customer-facing page, and is often blank for non-Messenger sources; never
    an inbox deep link). Same workspace-id deeplink shape as
    scripts/intercom-data-complaint-watchdog.py's deeplink() and
    plugins/support-tools/src/tools/ticket-format.ts's intercomDeeplink()."""
    workspace_id = os.environ.get("INTERCOM_WORKSPACE_ID", DEFAULT_WORKSPACE_ID)
    return f"https://app.intercom.com/a/inbox/{workspace_id}/inbox/conversation/{conv_id}"


CUSTOMER_AUTHOR_TYPES = {"user", "lead", "contact"}


def is_inbound_conv(c):
    """Whether a conversation was CUSTOMER-initiated (inbound) vs
    admin/bot/campaign-initiated (outbound) — needed to disambiguate the
    lar==0/lcr==0 tie in bucket_conversations (see its comment).

    Primary signal: `source.delivered_as` (verified against the Intercom
    2.11 OpenAPI spec's `conversation_source` schema — a REQUIRED field
    whose documented values are `customer_initiated`, `campaigns_initiated`,
    `operator_initiated`, `automated`, and `admin_initiated`; only the first
    is inbound).

    Fallback (only when `delivered_as` is missing/absent, e.g. older data):
    `source.author.type` being a customer role. Author type is NOT only
    "user" — the 2.11 spec's `create_conversation_request`/`create_message_
    request` schemas show a customer-initiated conversation's author can be
    "user" OR "lead" (a Contact's `role` is user or lead; "contact" is also
    accepted as a `from.type` value), so checking only "user" would
    misclassify a lead/contact's unanswered first message as outbound and
    hide it from needs-human — the same failure class fixed for the 0/0 tie
    itself. Admin/bot/campaign authors remain outbound."""
    src = c.get("source") or {}
    delivered_as = src.get("delivered_as")
    if delivered_as:
        return delivered_as == "customer_initiated"
    au = src.get("author") or {}
    return au.get("type") in CUSTOMER_AUTHOR_TYPES


def fetch_open_convs(token, limit=0):
    """List OPEN Intercom conversations (read-only). Mirrors
    close-resolved-conversations.fetch_open_convs; stops early once `limit`
    (0 = no cap) conversations have been collected."""
    convs = []
    after = None
    while True:
        body = {"query": {"field": "state", "operator": "=", "value": "open"},
                "pagination": {"per_page": 150}}
        if after:
            body["pagination"]["starting_after"] = after
        data = intercom_search(token, body)
        for c in data.get("conversations", []):
            stats = c.get("statistics") or {}
            convs.append({
                "id": c.get("id"),
                "email": contact_email_of(c, token),
                "lar": stats.get("last_admin_reply_at") or 0,
                "lcr": stats.get("last_contact_reply_at") or 0,
                "created_at": c.get("created_at") or 0,
                "is_inbound": is_inbound_conv(c),
            })
            if limit and len(convs) >= limit:
                return convs
        nxt = (data.get("pages") or {}).get("next")
        after = nxt.get("starting_after") if isinstance(nxt, dict) else None
        if not nxt or not after:
            break
    return convs


# --------------------------------------------------------------------------
# De-confliction: read every sibling sweeper's state defensively. A missing,
# empty, or corrupt file means "no ownership" — this must NEVER crash the
# digest, and it must NEVER be treated as "everything is owned" either.
# --------------------------------------------------------------------------
def _read_json_file(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _read_jsonl_file(path):
    try:
        with open(path) as f:
            lines = f.readlines()
    except OSError:
        return []
    out = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except ValueError:
            continue  # a malformed line must not abort the whole read
    return out


def owned_ids(paths):
    """Return set[conv_id] already owned by any sibling sweeper.

    `paths` is a dict of source name -> (path, kind) where kind is "json" (a
    state-dict keyed like {"conv:<id>": ts, ...}) or "jsonl" (a shadow log,
    one JSON object per line carrying "id"/"conv_id").

    De-conflicts by CONVERSATION ID ONLY, never contact email — every sibling
    source below records the conversation id, so id-matching is sufficient
    and correct. Matching email against these append-only, never-pruned logs
    would permanently exclude a RETURNING customer's brand-new, unrelated
    conversation (their email lingers in close-resolved-shadow.jsonl forever
    after any single past close), which would silently hide their next real
    issue from Jan. See docs/plans/cs-ops-drain-spec.md (commit 2c04734b).
    """
    ids = set()
    for _name, (path, kind) in paths.items():
        if kind == "json":
            state = _read_json_file(path) or {}
            if not isinstance(state, dict):
                continue
            for key in state:
                if isinstance(key, str) and key.startswith("conv:"):
                    ids.add(key[len("conv:"):])
        elif kind == "jsonl":
            for rec in _read_jsonl_file(path):
                if not isinstance(rec, dict):
                    continue
                cid = rec.get("id") or rec.get("conv_id")
                if cid:
                    ids.add(str(cid))
    return ids


def default_state_paths():
    return {
        "close-resolved": (
            os.environ.get("CLOSE_SHADOW_LOG", "/var/log/close-resolved-shadow.jsonl"),
            "jsonl"),
        "resolve-notify": (
            os.environ.get("RESOLVE_NOTIFY_STATE", "/var/lib/resolve-notify/notified.json"),
            "json"),
        "resolution-matcher-state": (
            os.environ.get("RESOLUTION_STATE_PATH", "/var/lib/resolution-matcher/state.json"),
            "json"),
        "resolution-matcher-shadow": (
            os.environ.get("RESOLUTION_SHADOW_LOG", "/var/log/resolution-matcher-shadow.jsonl"),
            "jsonl"),
        "overdue-verification-notifier": (
            os.environ.get("OVERDUE_NOTIFY_STATE",
                          "/var/lib/overdue-verification-notifier/notified.json"),
            "json"),
        "close-duplicate": (
            os.environ.get("CLOSE_DUP_SHADOW_LOG", "/var/log/close-duplicate-shadow.jsonl"),
            "jsonl"),
        # Best-effort / known gap — see module docstring: dedup-shadow.jsonl
        # today carries profile ids, not conversation id/email, so this is a
        # forward-compatible no-op read, not an active exclusion source yet.
        "dedup-shadow": (
            os.environ.get("DEDUP_SHADOW_LOG", "/var/log/dedup-shadow.jsonl"),
            "jsonl"),
        # DELIBERATELY ABSENT: close-stale-shadow.jsonl (the human-run
        # stale-backlog closer). A closed conversation never appears in this
        # digest's open-only query, so excluding its append-only shadow here
        # would have exactly one runtime effect: permanently hiding a
        # conversation the customer REOPENED after our silent close — the one
        # cohort that must surface as needs-human (its advertised recovery
        # path is "the customer replies"). The closers/ops-drain DO read it,
        # where over-exclusion is the safe direction.
    }


# --------------------------------------------------------------------------
# Pure bucketing logic (no network — directly unit-testable).
# --------------------------------------------------------------------------
def is_owned(conv, owned_ids):
    """De-conflict by CONVERSATION ID ONLY — never contact email. See
    owned_ids() docstring for why email-matching against sibling logs is
    wrong (permanent exclusion of returning customers)."""
    return conv["id"] in owned_ids


def waiting_since(c):
    """The real moment we started owing this customer a reply: their last
    reply time, or — for a conversation they've never replied to at all
    (last_contact_reply_at == 0, e.g. their unanswered FIRST message, which
    Intercom's statistics do not count as a "reply") — the conversation's
    created_at. NEVER bare last_contact_reply_at (0) for that case: treating
    a brand-new conversation as "waiting since the Unix epoch" corrupts the
    oldest-waiting-first ranking (ties every such row together in API order)
    and the elapsed-time/48h-SLA-flag signal (always flags it, regardless of
    real age)."""
    return c["lcr"] or c.get("created_at") or 0


def bucket_conversations(convs, owned_ids):
    """Return {needs_human, needs_customer_input, dup_candidate}, each a list
    of surviving (not sibling-owned) conversations. A conversation with >=2
    open convs on the same email is ALSO flagged dup-candidate, independent
    of which reply-order bucket it falls into (the two classifications are
    not mutually exclusive: a customer can be waiting on us on their newest
    duplicate thread). Dup-candidate detection uses contact email as a LIVE
    signal among currently-open conversations only — a separate, correct use
    of email distinct from (and never conflated with) de-confliction, which
    is id-only."""
    survivors = [c for c in convs if not is_owned(c, owned_ids)]

    email_counts = {}
    for c in survivors:
        if c["email"]:
            email_counts[c["email"]] = email_counts.get(c["email"], 0) + 1

    needs_human, needs_customer_input, dup_candidate = [], [], []
    for c in survivors:
        # we-owe-them-a-reply: customer spoke last, or never replied to at all
        # (lar==0 means we never engaged — that customer is definitely not
        # "waiting on nothing", so it belongs in needs-human too) — EXCEPT
        # when there are no reply parts on EITHER side (lar==0 and lcr==0):
        # that tie is ambiguous on its own, since this digest now also covers
        # outbound (admin/bot/campaign-initiated) conversations. Disambiguate
        # by the conversation's initiator: inbound (customer started it, e.g.
        # their unanswered first message) -> needs-human; outbound (we/a bot
        # reached out and the customer hasn't replied yet) -> we're waiting
        # on THEM, not the other way around -> needs-customer-input. Default
        # to inbound (True) when the flag is absent (fetch_open_convs always
        # sets it; only test fixtures omit it, and inbound is the historical
        # behavior they assume).
        if c["lar"] == 0 and c["lcr"] == 0:
            if c.get("is_inbound", True):
                needs_human.append(c)
            else:
                needs_customer_input.append(c)
        elif c["lar"] <= c["lcr"]:
            needs_human.append(c)
        else:
            needs_customer_input.append(c)
        if c["email"] and email_counts[c["email"]] >= 2:
            dup_candidate.append(c)

    # Newest-customer-activity-first: rank by waiting_since (see its
    # docstring) — the customer's last reply time, or created_at for a
    # never-replied conversation — newest first. NEVER bare lcr, which is 0
    # (the Unix epoch) for a never-replied conversation regardless of its real
    # age. Oldest-first put the 194-day tail permanently in the rendered
    # [:top_n] slice while the live threads never surfaced; the 20h/48h SLA
    # signal lives in is_aging, SLA_HOURS_FLAG and the --delta crossing ping,
    # not in the sort order.
    needs_human.sort(key=waiting_since, reverse=True)
    return {
        "needs_human": needs_human,
        "needs_customer_input": needs_customer_input,
        "dup_candidate": dup_candidate,
    }


def mask_email(email):
    """`a***@***` masking — never leak a full customer email into a digest."""
    if not email:
        return "no email"
    local = email.split("@", 1)[0]
    return f"{local[0]}***@***" if local else "***@***"


def is_aging(c, now_epoch, aging_hours):
    """Whether a needs-human item's waiting time exceeds the aging
    escalation threshold. Uses waiting_since (never bare lcr — see its
    docstring)."""
    return (now_epoch - waiting_since(c)) / 3600 > aging_hours


def split_actionable(convs, now_epoch, window_days=DEFAULT_ACTIONABLE_DAYS):
    """Split convs into (actionable, backlog) by waiting_since age. Inclusive
    at the boundary; input order is preserved in both lists."""
    cutoff = window_days * 86400
    actionable, backlog = [], []
    for c in convs:
        (actionable if now_epoch - waiting_since(c) <= cutoff else backlog).append(c)
    return actionable, backlog


def actionable_dups(dup_candidate, now_epoch, window_days=DEFAULT_ACTIONABLE_DAYS):
    """Keep every member of an email group with at least one member inside the
    window: a duplicate pair is worth merging when the contact is live even if
    one thread is old. Falsy emails are never dup members. Input order kept."""
    live = {c["email"] for c in split_actionable(dup_candidate, now_epoch, window_days)[0]
            if c["email"]}
    return [c for c in dup_candidate if c["email"] and c["email"] in live]


# --------------------------------------------------------------------------
# --delta state: {conv_id: {"first_surfaced": epoch, "aged_flagged": bool}}.
# Missing file = empty (first run). Corrupt file = FAIL LOUD — never a
# silent reset, which would re-ping Jan with hundreds of items. Updated ONLY
# on a successful --post (dry-run never mutates it) — see main().
# --------------------------------------------------------------------------
class CorruptDigestState(Exception):
    """The --delta state file exists but is not valid JSON, or is not a JSON
    object. Must propagate to main() and fail the run loudly rather than be
    silently treated as an empty/first-run state."""


def load_delta_state(path):
    if not os.path.exists(path):
        return {}
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        raise CorruptDigestState(f"{path}: {type(e).__name__}: {e}") from e
    if not isinstance(data, dict):
        raise CorruptDigestState(
            f"{path}: expected a JSON object, got {type(data).__name__}")
    # Validate EACH entry, not just the top level: a non-object entry (e.g. [])
    # would crash compute_delta_and_next_state's entry.get() calls, and a
    # non-bool aged_flagged (e.g. the string "false", which is truthy) would
    # silently suppress the one-time aging escalation. Fail loud instead — a
    # corrupt entry must not be interpreted as a valid "already flagged" state.
    for cid, entry in data.items():
        if not isinstance(entry, dict):
            raise CorruptDigestState(
                f"{path}: entry {cid!r} is {type(entry).__name__}, expected object")
        fs = entry.get("first_surfaced")
        if fs is not None and (not isinstance(fs, (int, float)) or isinstance(fs, bool)):
            raise CorruptDigestState(
                f"{path}: entry {cid!r} first_surfaced is {type(fs).__name__}, "
                "expected number")
        af = entry.get("aged_flagged")
        if af is not None and not isinstance(af, bool):
            raise CorruptDigestState(
                f"{path}: entry {cid!r} aged_flagged is {type(af).__name__}, "
                "expected bool")
    return data


def save_delta_state(path, state):
    """Persist the --delta checkpoint ATOMICALLY: write a sibling temp file,
    flush + fsync it, then os.replace() it onto the live path. os.replace is
    atomic on POSIX, so a crash or disk-full mid-write can never truncate the
    live file into a corrupt state (which load_delta_state would then fail-loud
    on for EVERY later delta run) — on any failure the previous valid checkpoint
    survives intact. Raises OSError on write/replace failure so the caller can
    fail the run loud rather than silently leave anti-repeat state stale."""
    dirname = os.path.dirname(path)
    if dirname:
        os.makedirs(dirname, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=dirname or ".", prefix=".delta-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(state, f, indent=2, sort_keys=True)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def compute_delta_and_next_state(state, needs_human, now_epoch, aging_hours):
    """Return (new_items, aging_items, next_state).

    new_items:   needs-human items with no prior entry in `state` — never
                 surfaced before.
    aging_items: needs-human items that are currently aging (waiting >
                 aging_hours) and were NOT already aged_flagged in `state` —
                 aging is a ONE-TIME-PER-CROSSING ping, never a re-ping every
                 run for the same item while it stays aged. A brand-new item
                 that is already aging on first surface lands in BOTH lists.
    next_state:  `state` with every needs_human item's entry
                 created/refreshed (first_surfaced kept on re-surface;
                 aged_flagged set to the item's CURRENT aging status — NOT
                 sticky-True-forever. This lets a genuinely-reset wait (e.g.
                 waiting_since moves forward because the customer replied
                 again) drop the flag, so a later re-crossing pings again
                 instead of staying silently suppressed forever).

    NOTE: this function is a pure per-item evaluator over whatever
    `needs_human` list it is given — main() uses its new_items/aging_items
    for accurate totals but does NOT persist this next_state directly; see
    build_next_state(), which additionally prunes departed entries and only
    commits flag updates for items actually rendered to Jan this run.
    """
    next_state = {}
    new_items, aging_items = [], []
    for c in needs_human:
        cid = c["id"]
        entry = state.get(cid)
        aging_now = is_aging(c, now_epoch, aging_hours)
        if entry is None:
            new_items.append(c)
            if aging_now:
                aging_items.append(c)
            next_state[cid] = {"first_surfaced": now_epoch, "aged_flagged": aging_now}
        else:
            already_flagged = bool(entry.get("aged_flagged"))
            if aging_now and not already_flagged:
                aging_items.append(c)
            next_state[cid] = {
                "first_surfaced": entry.get("first_surfaced", now_epoch),
                "aged_flagged": aging_now,
            }
    return new_items, aging_items, next_state


def _dedup_delta_items(new_items, aging_items):
    """new_items + aging_items, in that order, with any item appearing in
    both (a brand-new item that is already aging) kept only once."""
    seen = set()
    out = []
    for c in new_items + aging_items:
        if c["id"] not in seen:
            seen.add(c["id"])
            out.append(c)
    return out


def _cap_delta_items(new_items, aging_items, top_n):
    """The deduped surfaced list, capped at top_n, plus the overflow count.

    Both render_delta_digest and build_delta_digest_blocks call this (never
    each other's own cap logic independently) so the rows actually shown to
    Jan and the rows build_next_state marks as surfaced are IDENTICAL — see
    build_next_state's docstring for why that consistency matters."""
    all_surfaced = _dedup_delta_items(new_items, aging_items)
    rendered = all_surfaced[:top_n]
    return rendered, len(all_surfaced) - len(rendered)


def build_next_state(state, needs_human, rendered_items, now_epoch, aging_hours):
    """The state to actually persist after a run.

    Three load-bearing rules, all for the real ~436-item backlog:

    1. Prune: drop any entry whose conv id is no longer in `needs_human` at all
       (a sibling sweeper closed it, or it left the bucket some other way).
       Without this, a closed-then-reopened conversation keeps its stale entry
       (possibly aged_flagged:true) and becomes invisible to every future delta
       digest the moment it reopens.
    2. First-surface entries are created ONLY for `rendered_items` — the rows
       Jan actually saw this run (the full digest's top_n slice, or --delta's
       render-capped new+aging list). A NEW item that exists in `needs_human`
       but wasn't shown (below top_n / over the render cap) must NOT get
       first_surfaced sight-unseen — that would make it "not new" next run and
       hide it forever.
    3. Refresh the aging status of EXISTING entries every run, even when the row
       was not rendered — otherwise a stale aged_flagged:true survives a
       reset-below-threshold and permanently suppresses the next re-crossing
       escalation (compute_delta_and_next_state's reset is defeated because THIS
       is what actually persists). The refresh direction is deliberately
       asymmetric to stay safe:
         - no longer aging  -> aged_flagged:false (a reset only ENABLES a future
           ping, never suppresses one — safe to apply unrendered).
         - aging AND rendered -> aged_flagged:true (the escalation was delivered).
         - aging but NOT rendered -> KEEP the existing flag (we have not pinged
           yet; flipping it true sight-unseen would suppress the escalation when
           the row is finally shown — the rule-2 concern, in the other direction).
       first_surfaced is always preserved.
    """
    aging_by_id = {c["id"]: is_aging(c, now_epoch, aging_hours) for c in needs_human}
    rendered_ids = {c["id"] for c in rendered_items}
    next_state = {}
    for cid, entry in state.items():
        if cid not in aging_by_id:
            continue  # rule 1: prune departed
        aging_now = aging_by_id[cid]
        if not aging_now:
            aged_flagged = False                      # reset (safe unrendered)
        elif cid in rendered_ids:
            aged_flagged = True                       # aging + shown -> pinged
        else:
            aged_flagged = bool(entry.get("aged_flagged"))  # aging + unseen -> keep
        next_state[cid] = {
            "first_surfaced": entry.get("first_surfaced", now_epoch),
            "aged_flagged": aged_flagged,
        }
    for c in rendered_items:                          # rule 2: first-surface new rows
        cid = c["id"]
        if cid in next_state:
            continue  # existing entry already refreshed above
        next_state[cid] = {
            "first_surfaced": now_epoch,
            "aged_flagged": is_aging(c, now_epoch, aging_hours),
        }
    return next_state


def _threshold_label(hours):
    return f"{hours:g}h"


def _customer_activity_fact(c, now_epoch):
    """Slack-visible facts only; never infer that a customer was unanswered."""
    if c["lcr"] > c["lar"]:
        return ("customer is last recorded replier; last customer reply "
                f"{age_str(c['lcr'], now_epoch)} ago")
    if c["lcr"]:
        return ("customer and team share the latest recorded reply time; "
                f"last customer reply {age_str(c['lcr'], now_epoch)} ago")
    return ("customer-initiated; opened "
            f"{age_str(waiting_since(c), now_epoch)} ago; no recorded reply")


DAILY_TITLE = "CS open-conversation review daily digest"
DELTA_TITLE = "CS open-conversation review delta"
REPLY_ORDER_CAVEAT = (
    "Open status and reply order do not prove that a customer went unanswered."
)
SLACK_SECTION_CHAR_LIMIT = 3000


def _slack_section_blocks(lines):
    """Pack complete lines into Slack section blocks below the 3000-char cap."""
    chunks = []
    current = []
    current_length = 0
    for line in lines:
        added_length = len(line) + (1 if current else 0)
        if current and current_length + added_length > SLACK_SECTION_CHAR_LIMIT:
            chunks.append("\n".join(current))
            current = []
            current_length = 0
            added_length = len(line)
        current.append(line)
        current_length += added_length
    if current:
        chunks.append("\n".join(current))
    return [
        {"type": "section", "text": {"type": "mrkdwn", "text": chunk}}
        for chunk in chunks
    ]


def _delta_body_lines(new_items, aging_items, now_epoch, top_n,
                      aging_hours=DEFAULT_AGING_HOURS):
    """Counts + capped rows + overflow pointer — the digest BODY, with no
    title/mention line (callers own that, exactly once each, so the title
    never appears twice — see render_delta_digest / build_delta_digest_blocks).

    Rows are capped at top_n (the same DIGEST_TOP_N convention the full
    digest uses): with the real ~436-item backlog, rendering every surfaced
    row into one Slack section would blow past Slack's 3000-char section
    text cap (-> invalid_blocks -> post fails -> state never persists ->
    both delta timers wedge forever). The counts line above already carries
    the true new/aging totals, so the cap only affects which rows are
    listed, never what's reported as counted."""
    rendered, overflow = _cap_delta_items(new_items, aging_items, top_n)
    threshold = _threshold_label(aging_hours)
    lines = [
        f"new to this digest: {len(new_items)}  "
        f"older than {threshold} since customer-side activity: {len(aging_items)}"
    ]
    for c in rendered:
        threshold_suffix = (
            f"  ⚠️ older than {threshold} since customer-side activity"
            if c in aging_items else "")
        lines.append(f"  {intercom_link(c['id'])}  {mask_email(c['email'])}  "
                     f"{_customer_activity_fact(c, now_epoch)}{threshold_suffix}")
    if overflow > 0:
        lines.append(f"  …and {overflow} more (see 13:30 full digest)")
    lines.append(REPLY_ORDER_CAVEAT)
    return lines


def render_delta_digest(new_items, aging_items, now_epoch, top_n=DEFAULT_TOP_N,
                         mention_uid=None, mention=None,
                         aging_hours=DEFAULT_AGING_HOURS):
    """Plain-text rendering of a --delta run's surfaced items (new + newly
    aging, deduped, capped at top_n — see _delta_body_lines). Mention
    rendered per the same rule as render_text_digest (see its docstring);
    pass a precomputed `mention` to skip recomputing it (and re-warning on a
    missing UID) when the caller already has one — see main()."""
    if mention is None:
        mention = _mention_prefix(mention_uid, aging_items)
    lines = [mention + DELTA_TITLE]
    lines.extend(_delta_body_lines(
        new_items, aging_items, now_epoch, top_n, aging_hours))
    return "\n".join(lines)


def build_delta_digest_blocks(new_items, aging_items, now_epoch, top_n=DEFAULT_TOP_N,
                               mention_uid=None, mention=None,
                               aging_hours=DEFAULT_AGING_HOURS):
    """Block Kit rendering. Builds the body directly via _delta_body_lines
    rather than calling render_delta_digest (which would recompute the
    mention and re-render the title a second time — the title lives ONLY in
    the header block here, never duplicated into the section text)."""
    if mention is None:
        mention = _mention_prefix(mention_uid, aging_items)
    blocks = [
        {"type": "header", "text": {"type": "plain_text", "text": DELTA_TITLE}},
    ]
    if mention:
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": mention.strip()}})
    blocks.extend(_slack_section_blocks(_delta_body_lines(
        new_items, aging_items, now_epoch, top_n, aging_hours)))
    return blocks


def _mention_prefix(mention_uid, aging_items):
    """<@UID> prefix, ONLY when aging_items is nonempty AND mention_uid is
    set — a literal @name pings nobody (repo doctrine), so this must be a
    real Slack UID passed in via CS_DIGEST_AGING_MENTION_UID, never
    hardcoded here. Prints a stderr warning when aging items exist but no
    UID is configured."""
    if not aging_items:
        return ""
    if mention_uid:
        return f"<@{mention_uid}> "
    print("WARN: aging item(s) present but CS_DIGEST_AGING_MENTION_UID is "
          "unset — no mention rendered", file=sys.stderr)
    return ""


def age_str(epoch_seconds, now_epoch):
    """Human age string ('past-SLA' surfaced by the caller, not invented here
    — this never promises an SLA, only reports elapsed time). Callers MUST
    pass a real timestamp (waiting_since(c)), never a bare last_contact_reply_at
    that may be 0/falsy for a never-replied conversation — that would render
    as "0h" / always-stale regardless of the conversation's actual age."""
    delta = max(0, now_epoch - epoch_seconds) if epoch_seconds else 0
    hours = delta / 3600
    if hours < 48:
        return f"{hours:.0f}h"
    return f"{hours / 24:.0f}d"


# --------------------------------------------------------------------------
# Slack Block Kit rendering.
# --------------------------------------------------------------------------
def _slack_escape(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


SLA_HOURS_FLAG = 48  # surfaced as "past a reasonable SLA", never a promise


def build_digest_blocks(buckets, now_epoch, top_n=DEFAULT_TOP_N,
                         aging_hours=DEFAULT_AGING_HOURS, mention_uid=None, mention=None):
    """`mention`, if given, is used as-is instead of recomputing it from
    mention_uid — pass a precomputed value (see main()) to avoid calling
    _mention_prefix (and its stderr WARN on a missing UID) a second time in
    the same posted run, once here and once in render_text_digest."""
    nh, nci, dup = buckets["needs_human"], buckets["needs_customer_input"], buckets["dup_candidate"]
    aging_items = [c for c in nh if is_aging(c, now_epoch, aging_hours)]
    if mention is None:
        mention = _mention_prefix(mention_uid, aging_items)
    blocks = [
        # plain_text header (no mrkdwn/mention parsing -> never pings anyone,
        # matching the repo convention: reference_slack_blockkit_header_mention_no_ping).
        {"type": "header", "text": {"type": "plain_text", "text": DAILY_TITLE}},
    ]
    if mention:
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": mention}})
    blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": (
        f"*customer-side activity is latest:* {len(nh)}  ·  "
        f"*team-side activity is latest, or team initiated with no recorded customer "
        f"reply:* {len(nci)}  ·  "
        f"*possible duplicate open conversations:* {len(dup)}")}})
    blocks.append({"type": "section", "text": {"type": "mrkdwn",
                   "text": f"_{REPLY_ORDER_CAVEAT}_"}})
    if not nh:
        blocks.append({"type": "section", "text": {"type": "mrkdwn",
                       "text": (":white_check_mark: no open conversations currently "
                                "have customer-side activity as the latest recorded event.")}})
        return blocks

    lines = []
    threshold = _threshold_label(aging_hours)
    for c in nh[:top_n]:
        since = waiting_since(c)
        flag = (" :rotating_light: customer-side activity older than 48h"
                if now_epoch - since > SLA_HOURS_FLAG * 3600 else "")
        threshold_flag = (
            f"  ⚠️ older than {threshold} since customer-side activity"
            if c in aging_items else "")
        lines.append(
            f"• <{intercom_link(c['id'])}|conversation {c['id']}> — "
            f"{_slack_escape(mask_email(c['email']))} — "
            f"{_customer_activity_fact(c, now_epoch)}{flag}{threshold_flag}")
    if len(nh) > top_n:
        lines.append(f"…and {len(nh) - top_n} more")
    blocks.extend(_slack_section_blocks(lines))
    return blocks


def render_text_digest(buckets, now_epoch, top_n=DEFAULT_TOP_N,
                        aging_hours=DEFAULT_AGING_HOURS, mention_uid=None, mention=None):
    """Plain-text rendering for --post's fallback `text` field and dry-run
    stdout. `mention`, if given, is used as-is — see build_digest_blocks."""
    nh, nci, dup = buckets["needs_human"], buckets["needs_customer_input"], buckets["dup_candidate"]
    aging_items = [c for c in nh if is_aging(c, now_epoch, aging_hours)]
    if mention is None:
        mention = _mention_prefix(mention_uid, aging_items)
    lines = [
        mention + DAILY_TITLE,
        f"customer-side activity is latest: {len(nh)}  "
        f"team-side activity is latest, or team initiated with no recorded customer "
        f"reply: {len(nci)}  "
        f"possible duplicate open conversations: {len(dup)}",
        REPLY_ORDER_CAVEAT,
    ]
    threshold = _threshold_label(aging_hours)
    for c in nh[:top_n]:
        threshold_suffix = (
            f"  ⚠️ older than {threshold} since customer-side activity"
            if c in aging_items else "")
        lines.append(f"  {intercom_link(c['id'])}  {mask_email(c['email'])}  "
                     f"{_customer_activity_fact(c, now_epoch)}{threshold_suffix}")
    if len(nh) > top_n:
        lines.append(f"  ...and {len(nh) - top_n} more")
    return "\n".join(lines)


def _read_slack_token(config_path, account):
    try:
        with open(config_path) as f:
            cfg = json.load(f)
        return cfg["channels"]["slack"]["accounts"][account]["botToken"]
    except (OSError, KeyError, ValueError, TypeError):
        return None


def post_slack_digest(blocks, text, channel, config_path, account):
    """Best-effort post. NEVER raises — the digest is informational only, so a
    Slack failure must not turn into a script failure. Returns bool."""
    token = _read_slack_token(config_path, account)
    if not token:
        print(f"WARN: no Slack token for account '{account}' in {config_path}; post skipped",
              file=sys.stderr)
        return False
    try:
        req = urllib.request.Request(
            SLACK_API,
            data=json.dumps({"channel": channel, "text": text, "blocks": blocks,
                             "unfurl_links": False, "unfurl_media": False}).encode(),
            headers={"Authorization": f"Bearer {token}",
                     "Content-Type": "application/json; charset=utf-8"},
            method="POST")
        with urllib.request.urlopen(req, timeout=20) as resp:
            body = json.load(resp)
        if not body.get("ok"):
            print(f"WARN: Slack post failed: {body.get('error')}", file=sys.stderr)
            return False
        return True
    except Exception as e:  # noqa: BLE001 — best-effort by contract, mirrors
        # close-resolved-conversations.post_slack_summary.
        print(f"WARN: Slack post error: {type(e).__name__}: {str(e)[:140]}", file=sys.stderr)
        return False


# --------------------------------------------------------------------------
# Inline self-test: fail the run if the bucketing detector is broken, so a
# silently-misfiring digest pages via cron-health rather than rotting.
# --------------------------------------------------------------------------
def _self_test():
    now = 1781784000  # fixed "now" for age math

    def conv(cid, email, lar, lcr, created_at=0, is_inbound=True):
        return {"id": cid, "email": email, "lar": lar, "lcr": lcr,
                "created_at": created_at, "is_inbound": is_inbound, "url": ""}

    # customer-last -> needs-human.
    c1 = conv("C1", "a@b.com", 100, 200)
    # admin-last -> needs-customer-input.
    c2 = conv("C2", "c@d.com", 300, 100)
    # never replied (lar==0) -> needs-human.
    c3 = conv("C3", "e@f.com", 0, 50)
    buckets = bucket_conversations([c1, c2, c3], set())
    assert [c["id"] for c in buckets["needs_human"]] == ["C1", "C3"], buckets["needs_human"]
    assert [c["id"] for c in buckets["needs_customer_input"]] == ["C2"], buckets["needs_customer_input"]
    assert buckets["dup_candidate"] == [], buckets["dup_candidate"]

    # de-confliction: an owned conv id must not surface at all.
    ids_owned = {"C1"}
    buckets2 = bucket_conversations([c1, c2, c3], ids_owned)
    assert "C1" not in [c["id"] for c in buckets2["needs_human"]], buckets2

    # KEY regression (QA #691 finding, cs-ops-drain-spec.md commit 2c04734b):
    # a conversation whose EMAIL matches something in a sibling's (append-
    # only, never-pruned) log, but whose ID is NOT owned, MUST still be
    # surfaced — de-confliction is by conversation id only. Email-matching
    # here would permanently hide a returning customer's brand-new,
    # unrelated conversation just because that email appeared in some past
    # closed conversation.
    buckets3 = bucket_conversations([c1, c2, c3], set())
    assert "C1" in [c["id"] for c in buckets3["needs_human"]], buckets3

    # dup detection: same email, two open convs — this is a LIVE signal
    # among currently-open conversations, computed independent of owned_ids
    # (never sourced from a sibling's historical log).
    d1 = conv("D1", "dup@x.com", 100, 200)
    d2 = conv("D2", "dup@x.com", 100, 200)
    buckets4 = bucket_conversations([d1, d2], set())
    assert {c["id"] for c in buckets4["dup_candidate"]} == {"D1", "D2"}, buckets4

    # KEY regression (waiting-timestamp finding): two never-replied
    # conversations (lcr==0) must rank by created_at, NOT tie at the Unix
    # epoch. n1 is older (created earlier) than n2, so n2 must sort first (newest-first).
    n1 = conv("N1", "n1@x.com", 0, 0, created_at=now - (72 * 3600))  # 72h old
    n2 = conv("N2", "n2@x.com", 0, 0, created_at=now - (10 * 3600))  # 10h old
    buckets5 = bucket_conversations([n1, n2], set())
    assert [c["id"] for c in buckets5["needs_human"]] == ["N2", "N1"], buckets5["needs_human"]
    assert waiting_since(n1) != 0 and waiting_since(n2) != 0, (n1, n2)

    # KEY regression (inbound-vs-outbound 0/0 finding): the lar==0/lcr==0 tie
    # is ambiguous on its own now that this digest also covers outbound
    # (admin/bot/campaign-initiated) conversations. An outbound one with no
    # reply parts means WE are waiting on the customer -> needs-customer-
    # input, never needs-human. An inbound one (the customer's unanswered
    # first message) stays needs-human.
    outbound = conv("OUT", "out@x.com", 0, 0, is_inbound=False)
    inbound = conv("IN", "in@x.com", 0, 0, is_inbound=True)
    buckets6 = bucket_conversations([outbound, inbound], set())
    assert [c["id"] for c in buckets6["needs_human"]] == ["IN"], buckets6["needs_human"]
    assert [c["id"] for c in buckets6["needs_customer_input"]] == ["OUT"], \
        buckets6["needs_customer_input"]

    # PII masking.
    assert mask_email("joe@example.com") == "j***@***", mask_email("joe@example.com")
    assert mask_email("") == "no email"

    # contact_email_of: the conversation `contacts` field is a Contact
    # Reference ({type, id, external_id} — NO email; verified against the
    # Intercom 2.11 OpenAPI contact_reference schema), so a bot/admin-
    # initiated conversation must still resolve the real customer's email
    # via the cached GET /contacts/{id} lookup, not by reading an (absent)
    # email straight off the reference. Seed the cache directly to exercise
    # the cache-hit path here without a real network call.
    _contact_email_cache["contact-abc"] = "real.customer@example.com"
    bot_initiated = {"source": {"author": {"type": "bot", "email": "bot@intercom.io"}},
                      "contacts": {"contacts": [{"type": "contact", "id": "contact-abc",
                                                  "external_id": "70"}]}}
    assert contact_email_of(bot_initiated, "tok") == "real.customer@example.com", \
        contact_email_of(bot_initiated, "tok")
    # a verified user-type source.author is still a valid fallback when there
    # is no contact reference at all (or it resolves to no email).
    user_initiated = {"source": {"author": {"type": "user", "email": "u@x.com"}},
                       "contacts": {"contacts": []}}
    assert contact_email_of(user_initiated, "tok") == "u@x.com", contact_email_of(user_initiated, "tok")
    # admin-initiated with no contacts entries and no user-type author -> ""
    # (no crash, no false identity), same fail-open-to-empty as before.
    admin_only = {"source": {"author": {"type": "admin", "email": "staff@muso.ai"}},
                  "contacts": {"contacts": []}}
    assert contact_email_of(admin_only, "tok") == "", contact_email_of(admin_only, "tok")

    # intercom_link: stable admin deeplink built from conv id, workspace-id
    # env-overridable, independent of any source.url.
    assert intercom_link("999") == \
        "https://app.intercom.com/a/inbox/dwjzhcge/inbox/conversation/999", intercom_link("999")

    # is_inbound_conv: delivered_as is the authoritative signal; author.type
    # being "user" is NOT the only customer-initiated case (a lead/contact's
    # unanswered first message must also count as inbound, per the 2.11 spec).
    assert is_inbound_conv({"source": {"delivered_as": "customer_initiated",
                                        "author": {"type": "lead"}}}) is True
    assert is_inbound_conv({"source": {"delivered_as": "admin_initiated",
                                        "author": {"type": "admin"}}}) is False
    assert is_inbound_conv({"source": {"delivered_as": "campaigns_initiated",
                                        "author": {"type": "bot"}}}) is False
    # delivered_as absent -> fall back to author.type customer-role check.
    assert is_inbound_conv({"source": {"author": {"type": "lead"}}}) is True
    assert is_inbound_conv({"source": {"author": {"type": "contact"}}}) is True
    assert is_inbound_conv({"source": {"author": {"type": "admin"}}}) is False

    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--post", action="store_true",
                    help="actually post the digest to Slack (default: dry-run)")
    ap.add_argument("--limit", type=int, default=0,
                    help="cap the number of open conversations scanned")
    ap.add_argument("--delta", action="store_true",
                    help="post only needs-human items never surfaced before, "
                         "or newly crossing the aging threshold")
    ap.add_argument("--self-test", action="store_true",
                    help="run the inline detector self-test and exit")
    args = ap.parse_args()

    try:
        _self_test()
    except AssertionError as e:
        print(f"cs-needs-human-digest: SELF-TEST FAILED: {e}", file=sys.stderr)
        return 2
    if args.self_test:
        print("self-test ok")
        return 0

    hostname = os.environ.get("DIGEST_HOSTNAME_OVERRIDE") or socket.gethostname()
    if os.environ.get("DIGEST_SKIP_HOST_GUARD") != "1" \
            and hostname != "ovh-node-8":
        print("cs-needs-human-digest: not on ovh-node-8 — refusing "
              "(set DIGEST_SKIP_HOST_GUARD=1 to override)", file=sys.stderr)
        return 0

    token = os.environ.get("MUSOAI_INTERCOM_TOKEN")
    if not token:
        print("cs-needs-human-digest: MUSOAI_INTERCOM_TOKEN is required", file=sys.stderr)
        return 1

    now_epoch = int(os.environ.get("DIGEST_NOW") or time.time())
    top_n = int(os.environ.get("DIGEST_TOP_N", str(DEFAULT_TOP_N)))
    aging_hours = int(os.environ.get("CS_DIGEST_AGING_HOURS", str(DEFAULT_AGING_HOURS)))
    mention_uid = os.environ.get("CS_DIGEST_AGING_MENTION_UID") or None
    state_path = os.environ.get("CS_DIGEST_STATE", DEFAULT_DIGEST_STATE)

    # A corrupt --delta state file must fail LOUD for --delta itself (never
    # silently reset — that would re-ping Jan with hundreds of items, every
    # needs-human item looking "new" again). It must NOT, however, block the
    # pre-existing 13:30 FULL digest (or its dry-runs): the full digest's own
    # job (Jan's daily ranked view) doesn't depend on this file being valid.
    # Full mode instead degrades — warn loudly, render/post normally, and
    # skip persisting to a file we know is corrupt (so we never paper over
    # the corruption with a freshly-reconstructed-from-empty state).
    state_corrupt = False
    try:
        state = load_delta_state(state_path)
    except CorruptDigestState as e:
        if args.delta:
            print(f"cs-needs-human-digest: --delta state file corrupt: {e}", file=sys.stderr)
            return 4
        print(f"cs-needs-human-digest: WARN --delta state file corrupt ({e}); "
              f"full digest continues normally, --delta state persistence "
              f"skipped this run", file=sys.stderr)
        state = {}
        state_corrupt = True

    try:
        convs = fetch_open_convs(token, args.limit)
    except ContactLookupFailed as e:
        # Systematic (401/403, or 429/5xx persisting through retries) — do
        # NOT silently treat this run as healthy; a silent empty-email
        # fallback here would silently disable email-based dup-candidate
        # detection with no signal it happened.
        print(f"cs-needs-human-digest: contact lookup failed systematically: {e}",
              file=sys.stderr)
        return 3
    ids = owned_ids(default_state_paths())
    buckets = bucket_conversations(convs, ids)

    print(f"open conversations scanned: {len(convs)}")
    print(f"already owned by a sibling sweeper: {len(convs) - len(buckets['needs_human']) - len(buckets['needs_customer_input'])}")
    print(f"needs-human: {len(buckets['needs_human'])}  "
          f"needs-customer-input: {len(buckets['needs_customer_input'])}  "
          f"dup-candidate: {len(buckets['dup_candidate'])}")

    # Shadow-only (Phase 2a #2a): fires strictly AFTER bucket_conversations()
    # above, on a RANDOM sample (never the ranked/rendered head — needs_human
    # is sorted oldest-waiting-first, so the head is a biased slice) of the
    # needs_human bucket, and can never change buckets, rendered rows, stdout,
    # or the exit code. A fresh, non-fixed seed each run is logged to stderr
    # so a run can be reproduced. See docs/plans/jev-adoption.md #2a and
    # CS_DIGEST_JEV_SAMPLE_SIZE above for the `actual`-is-a-weak-label caveat.
    jev_pool = buckets["needs_human"]
    jev_k = min(_jev_sample_size(), len(jev_pool))
    if jev_k > 0:
        jev_seed = random.SystemRandom().randrange(2 ** 32)
        print(f"jev shadow sample: seed={jev_seed} size={jev_k} "
              f"(pool={len(jev_pool)})", file=sys.stderr)
        for c in random.Random(jev_seed).sample(jev_pool, jev_k):
            shadow_judge(JEV_SURFACE_NEEDS_HUMAN_DIGEST, c["id"],
                         lambda cid=c["id"]: needs_human_shadow_state(cid, token),
                         NEEDS_HUMAN_DIGEST_QUESTIONS, actual="needs-human")

    def _persist_next_state(rendered_items):
        """Returns True if the anti-repeat checkpoint is durable after this call
        (persisted, nothing changed, or intentionally skipped because the loaded
        state was corrupt), False if an atomic persist was ATTEMPTED and FAILED
        (disk/permission). On False the caller fails the run loud so the
        cron-health watchdog surfaces it — a green timer hiding stale anti-repeat
        state would silently re-page Jan on the next delta run."""
        # Skip persistence entirely when the loaded state was corrupt (full
        # mode's degrade path) — never overwrite a known-bad file with a
        # reconstruction built from an empty state.
        if state_corrupt:
            print(f"cs-needs-human-digest: WARN skipping --delta state "
                  f"persistence — {state_path} was corrupt this run",
                  file=sys.stderr)
            return True
        next_state = build_next_state(state, buckets["needs_human"], rendered_items,
                                       now_epoch, aging_hours)
        if next_state == state:
            return True
        try:
            save_delta_state(state_path, next_state)
        except OSError as e:
            print(f"cs-needs-human-digest: ERROR could not persist --delta "
                  f"checkpoint to {state_path}: {e} — the digest WAS delivered, "
                  f"but the anti-repeat state is now stale (the previous valid "
                  f"checkpoint is preserved intact); repair disk/permissions",
                  file=sys.stderr)
            return False
        return True

    channel = os.environ.get("DIGEST_SUMMARY_CHANNEL", DEFAULT_SUMMARY_CHANNEL)
    cfg = os.environ.get("SLACK_NOTIFY_CONFIG", "/root/.openclaw-main/openclaw.json")
    account = os.environ.get("DIGEST_SLACK_ACCOUNT", "operations")

    if args.delta:
        new_items, aging_items, _ = compute_delta_and_next_state(
            state, buckets["needs_human"], now_epoch, aging_hours)

        if not new_items and not aging_items:
            print("NO_DELTA — nothing posted")
            if args.post:
                # Pure pruning — nothing was surfaced, so no entry is
                # created/refreshed; this only drops entries for conv ids
                # that left needs_human (finding: a closed-then-reopened
                # conv must not stay invisible). _persist_next_state is a
                # no-op write when there's nothing to prune.
                if not _persist_next_state([]):
                    return 5
            return 0

        mention = _mention_prefix(mention_uid, aging_items)
        text = render_delta_digest(
            new_items, aging_items, now_epoch, top_n,
            mention=mention, aging_hours=aging_hours)
        print(text)
        if not args.post:
            print("DRY-RUN — nothing posted. Re-run with --post to post to Slack.")
            return 0
        blocks = build_delta_digest_blocks(
            new_items, aging_items, now_epoch, top_n,
            mention=mention, aging_hours=aging_hours)
        posted = post_slack_digest(blocks, text, channel, cfg, account)
        print(f"slack post: {'posted' if posted else 'skipped/failed'} -> {channel}")
        if posted:
            # State updates ONLY on a successful --post — dry-run never
            # mutates state (checked above by the early return). Only the
            # rows actually rendered (render-capped) get marked surfaced.
            rendered_items, _overflow = _cap_delta_items(new_items, aging_items, top_n)
            if not _persist_next_state(rendered_items):
                return 5   # posted, but the anti-repeat checkpoint failed to persist
        return 0 if posted else 1

    aging_items_full = [c for c in buckets["needs_human"]
                         if is_aging(c, now_epoch, aging_hours)]
    mention = _mention_prefix(mention_uid, aging_items_full)
    text = render_text_digest(buckets, now_epoch, top_n, aging_hours, mention=mention)
    print(text)

    if not args.post:
        print("DRY-RUN — nothing posted. Re-run with --post to post to Slack.")
        return 0

    blocks = build_digest_blocks(buckets, now_epoch, top_n, aging_hours, mention=mention)
    posted = post_slack_digest(blocks, text, channel, cfg, account)
    print(f"slack post: {'posted' if posted else 'skipped/failed'} -> {channel}")
    persisted_ok = True
    if posted:
        # Only the rendered top_n slice is marked surfaced — a rank-16+ item
        # nobody saw must not get first_surfaced/aged_flagged sight-unseen.
        persisted_ok = _persist_next_state(buckets["needs_human"][:top_n])
    # --post's whole job is delivering Jan's daily view; an undelivered digest
    # must fail loud (non-zero) so the systemd timer + cron-health watchdog
    # surface it, instead of silently marking a no-delivery run "healthy" (a
    # bad/expired Slack token would otherwise suppress the digest forever with
    # no alarm). Dry-run never posts, so it is unaffected and stays exit 0. A
    # delivered digest whose anti-repeat checkpoint failed to persist also fails
    # loud (exit 5) so monitoring repairs the disk before the next delta run.
    if not posted:
        return 1
    return 0 if persisted_ok else 5


if __name__ == "__main__":
    sys.exit(main())
