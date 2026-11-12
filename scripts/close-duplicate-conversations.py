#!/usr/bin/env python3
"""Auto-close strictly-safe DUPLICATE Intercom conversations (Phase 1 of
docs/plans/autonomous-cs-machine.md).

Phase 0.3's cs-needs-human-digest.py FLAGS dup-candidate conversations (same
contact email, >=2 open threads) but never closes them — a human (Jan) still
does. This script is the deterministic sweeper that closes the tiers we can
prove are strictly safe, and leaves everything else (active exchange,
both-dangling, cross-customer, ambiguous) for a human, same as before.

THIS IS A ONE-WAY DOOR (it closes customer conversations). SHADOW-MODE ONLY
in this PR: the systemd timer that ships alongside this script runs WITHOUT
--apply. The --apply/--limit flip to production is a SEPARATE, later,
one-line PR gated on >=2 weeks AND >=10 Jan-reviewed candidate pairs with
zero false positives (see docs/plans/autonomous-cs-machine.md and the
oracle-ratified plan this implements).

Reuse by DUPLICATION, not by import (identical signatures, sources cited
per-function below) — see docs/plans/autonomous-cs-machine.md's debt note:
a scripts/lib/intercom_common.py extraction is deferred, post-stabilization,
mechanic-tier work.

The deterministic rule (NO LLM / no message-content reading — structural
only). A duplicate GROUP is >=2 open, inbound (source.delivered_as ==
"customer_initiated") conversations sharing the same non-empty resolved
contact email, resolved via the FAST PATH ONLY (source.author.email when
source.author.type == "user" — see contact_email_of's docstring for why the
slow path is never used to form groups, only to CONFIRM an already-formed
group's members before closing, bounded and N+1-safe).

KEEP = newest by created_at. A tie for newest is ambiguous ordering -> the
whole group is skipped this run (no unique keep can be determined). If the
kept thread is already owned by a sibling sweeper's state
(owned_ids(default_state_paths())), the WHOLE group is skipped this run —
closing older duplicates around a thread another sweeper already claimed
risks orphaning that claim. An older member individually owned by a sibling
sweeper is simply left out of the closable set (left for a human), without
skipping the rest of the group.

Each OLDER group member is closed iff it passes EXACTLY one tier:
  - Tier A (SILENT close): older.lar > 0 and older.lar > older.lcr — the
    proven we-spoke-last gate, verbatim from
    close-resolved-conversations.py:208-213. We answered, the customer
    moved on; no new message posted (double-messaging a customer we
    already answered would be worse than silence).
  - Tier B (pointer-then-close): older.lar == 0 (never engaged) AND
    kept.lar > 0 (we ARE engaged on the kept thread) AND
    kept.created_at - older.created_at <= DUP_TIER_B_WINDOW_DAYS (env,
    default 14) days. Posts a fixed-constant, zero-interpolation pointer
    comment (PENDING AARON SIGN-OFF before the --apply flip — see
    POINTER_TEXT below), THEN closes.
  - NEVER closed (v1): active exchange (older.lar>0 and lcr>=older.lar —
    customer waiting there), both-dangling (older never-engaged AND kept
    never-engaged), empty/mismatched email, cross-customer. These stay in
    the digest for a human.

Safety model:
  - Pre-close re-verify: immediately before each close, a fresh
    GET /conversations/{id} for BOTH the close target and the kept thread
    re-asserts the target is still open, its tier gate still holds against
    FRESH statistics, the kept thread is still open, AND the fast-path
    grouping email is confirmed via the slow-path GET /contacts/{id} lookup
    (bounded to this pair, never the whole backlog) — closes the
    fetch-then-close race and catches a stale/incorrect grouping.
  - Partial-failure dedupe: a Tier B pointer_posted record (keyed by conv
    id) is written to CLOSE_DUP_POINTER_STATE BEFORE the close attempt (but
    AFTER the pointer post itself succeeds) — a later run never re-posts
    the pointer to a customer who already got it; it only retries the
    close.
  - Sanity ceiling: more than DUP_CEILING (20, or --ceiling N) candidate
    closes identified in one run closes NOTHING under --apply and exits
    non-zero with a notify — a dup storm is a grouping bug or an Intercom
    incident, not a queue to drain. --ceiling N is a supervised, auditable,
    self-expiring override of the --apply hard stop for a reviewed backlog
    drain (flag only, never an env var or unit-file edit).
  - Shadow log: every close appends one line to CLOSE_DUP_SHADOW_LOG,
    {"id": <CLOSED conv>, "closed_at": <epoch>, "email", "kept_id": <KEPT
    conv>, "tier", "new_state"}. CRITICAL: the surviving/kept thread is
    "kept_id", NEVER "id"/"conv_id" — cs-needs-human-digest.py's
    owned_ids() keys de-confliction on rec["id"] or rec["conv_id"]; if the
    kept id were written under either of those fields, the live kept
    thread would be silently hidden from Jan's digest forever. Unit-tested
    explicitly (see tests/test_close_duplicate_conversations.py).
  - Host guard: systemd-on-node-8 only, same as close-resolved-conversations
    — there is deliberately NO in-Python host guard here.

Env:
  MUSOAI_INTERCOM_TOKEN       required
  INTERCOM_ADMIN_ID           ignored unless it is 5763097 (Caroline); the posting identity is fixed
  DUP_TIER_B_WINDOW_DAYS      optional, default 14
  CLOSE_DUP_SHADOW_LOG        optional, default /var/log/close-duplicate-shadow.jsonl
  CLOSE_DUP_POINTER_STATE     optional, default /var/lib/close-duplicate/pointer-posted.json
  CLOSE_DUP_SUMMARY_CHANNEL   optional, default C0ANM0PN9L5 (#cs_chats)
  CLOSE_DUP_SLACK_ACCOUNT     optional, default operations
  SLACK_NOTIFY_CONFIG         optional, default /root/.openclaw-main/openclaw.json
  CLOSE_DUP_REVIEW_DIR        optional, default /var/lib/close-duplicate-conversations/
                              (dry-run candidate review export — see
                              write_review_export; each candidate now
                              carries "group_size" so a reviewer can filter
                              stratified by group size despite the masked
                              email)
  CLOSE_DUP_JEV_SAMPLE_SIZE   optional, default 25 — dry-run's dedupe-same-
                              request shadow-Jev sample size (see the
                              JEV_SURFACE_DEDUPE comment above and
                              _dedupe_jev_sample_size()); a FRESH random
                              sample of the full candidate pool is drawn
                              each run, never the head
  # De-confliction inputs (reused verbatim from cs-needs-human-digest.py's
  # default_state_paths() env vars — see that module for detail):
  CLOSE_SHADOW_LOG, RESOLVE_NOTIFY_STATE, RESOLUTION_STATE_PATH,
  RESOLUTION_SHADOW_LOG, OVERDUE_NOTIFY_STATE, DEDUP_SHADOW_LOG,
  CLOSE_STALE_SHADOW_LOG

Flags:
  --apply               actually close (default: dry-run — identify only,
                         no writes). NOT enabled by the shadow-mode timer
                         this PR ships; the flip is a separate PR.
  --limit N             cap the number of INDIVIDUAL closes this run
                         (0 = no cap; used only once --apply is live)
  --notify-candidates   post "would close X -> kept Y (tier A/B)" pairs to
                         #cs_chats EVEN ON DRY-RUN (needed for shadow-phase
                         review — close-resolved's notify gates on
                         apply && ok>0, which is insufficient here since
                         this PR never applies).
  --ceiling N           override DUP_CEILING for this run's --apply hard
                         stop only (N must be > 0). Flag only, never an
                         env var or unit-file edit — a supervised,
                         auditable, self-expiring override for draining a
                         reviewed backlog.

Exit codes: 0 ok; 1 usage/env error; 2 invalid --ceiling, or --apply sanity
            ceiling exceeded (nothing closed — dry-run over the ceiling
            does NOT exit 2, it proceeds with the normal dry-run path and
            exits 0, see write_review_export); 3 at least one close failed.
"""
import argparse
import json
import os
import random
import re
import stat
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lib.intercom_identity import resolve_admin_id  # noqa: E402
from lib import copy_gate  # noqa: E402

COPY_CAMPAIGN = "duplicate-pointer"
from lib.jev_shadow import shadow_judge  # noqa: E402

INTERCOM_API = "https://api.intercom.io"
INTERCOM_VERSION = "2.11"
SLACK_API = "https://slack.com/api/chat.postMessage"
DEFAULT_SUMMARY_CHANNEL = "C0ANM0PN9L5"  # #cs_chats
DEFAULT_TIER_B_WINDOW_DAYS = 14
DUP_CEILING = 20
SUMMARY_MAX_LINES = 25
DEFAULT_DEDUPE_JEV_SAMPLE_SIZE = 25

# Phase 2a shadow-only Jev surface (docs/plans/jev-adoption.md #2a). Judges
# whether the two threads a candidate close would merge are actually the
# SAME request, using each thread's first customer message (the only text
# reasonably available here — see get_conversation's source_body). This
# script ships SHADOW-MODE ONLY today (no --apply in the prod timer —
# install-aux-units.sh), and the prod timer runs dry-run only, so the fire
# point differs by mode but is always strictly AFTER the script's own
# decision is already final: in --apply, after reverify_still_valid() has
# confirmed the real close; in dry-run (no reverify step there), after the
# finalized `candidates` list itself. See _dedupe_shadow_judge for the
# shared implementation. Either way the answer changes nothing about which
# candidates close, stdout, or the exit code — the two extra read-only GETs
# this call costs per candidate carry no write risk.
#
# --apply judges every targeted candidate (DUP_CEILING already bounds that
# list to <=20, under jev_shadow's own default 25-call budget). Dry-run's
# candidate pool has no such ceiling -- a backlogged run is exactly the
# reviewable case DUP_CEILING deliberately lets through (see the ceiling-
# gates-only---apply comment in main()) -- so `for c in candidates:` there
# would silently judge only the head of the pool, run after run, in the SAME
# order every time (a biased, non-representative sample). Dry-run instead
# draws a FRESH random sample of CLOSE_DUP_JEV_SAMPLE_SIZE (default 25,
# below) candidates each run, mirroring close-resolved-conversations.py's
# own jev_k/_jev_sample_size()/SystemRandom pattern verbatim -- see that
# script's "jev shadow sample" comment for the identical rationale.
JEV_SURFACE_DEDUPE = "dedupe-same-request"
DEDUPE_QUESTIONS = {
    "same_request": {
        "type": "noul",
        "instructions": (
            "State carries `thread_a_first_message` and `thread_b_first_message` "
            "— the first customer message of each of two Intercom threads from "
            "the SAME customer email that a duplicate-close candidate would "
            "merge (thread A is being closed as a duplicate of thread B). "
            "Decide whether they are genuinely the SAME request/issue, as "
            "opposed to two different asks that merely came from the same "
            "customer."
        ),
        "criteria": {
            "true": "Both messages describe the same underlying request or issue.",
            "false": "The messages describe different requests/issues even though they share a customer.",
        },
    },
}


def _strip_html(text):
    return re.sub(r"<[^>]+>", " ", text).strip() if text else ""
DEFAULT_REVIEW_DIR = "/var/lib/close-duplicate-conversations/"
# Fallback dir when DEFAULT_REVIEW_DIR is unwritable — a private (0700)
# subdir, never the bare world-readable /tmp root, since the export
# contains customer email addresses. See _safe_fallback_dir().
FALLBACK_REVIEW_DIR = "/tmp/close-duplicate-review"

# Zero-interpolation, fixed-constant Tier B pointer text — customer-facing.
# PENDING AARON SIGN-OFF before --apply flip (see module docstring / PR).
POINTER_TEXT = (
    "We're consolidating this into your more recent conversation and will "
    "reply there. If anything here wasn't covered, just reply and this "
    "will reopen."
)


# --------------------------------------------------------------------------
# Network seam — copied by DUPLICATION (see module docstring for why not
# imported), not by reference, so each script's behavior can drift safely.
# --------------------------------------------------------------------------
def _backoff(a):
    # Linear retry backoff. CLOSE_DUP_RETRY_BASE_SECS lets the bats suite skip the
    # wait against a dead port (MUS-11315); the default 2 s is production timing.
    time.sleep(float(os.environ.get("CLOSE_DUP_RETRY_BASE_SECS", "2")) * (a + 1))


def _retry_json(req, attempts=4):
    # <- scripts/close-resolved-conversations.py:86-94
    for a in range(attempts):
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return json.load(resp)
        except urllib.error.URLError:
            if a == attempts - 1:
                raise
            _backoff(a)


def intercom_search(token, body):
    # <- scripts/close-resolved-conversations.py:97-104
    req = urllib.request.Request(
        f"{INTERCOM_API}/conversations/search",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                 "Content-Type": "application/json", "Intercom-Version": INTERCOM_VERSION},
        method="POST")
    return _retry_json(req)


# Contact-email lookup cache — module-level, process-lifetime (avoid N+1
# GET /contacts/{id} when the same contact appears more than once in one run).
_contact_email_cache = {}


class ContactLookupFailed(Exception):
    """A SYSTEMATIC contact-lookup failure (401/403, or 429/5xx persisting
    through retries) — distinct from a benign 404. See get_contact."""


def get_contact(contact_id, token, attempts=4):
    # <- scripts/cs-needs-human-digest.py:155-203 (get_contact)
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
                _backoff(a)
                continue
            raise ContactLookupFailed(
                f"GET /contacts/{contact_id} -> {e.code} (unexpected status)") from e
        except (urllib.error.URLError, ValueError, OSError) as e:
            if a == attempts - 1:
                raise ContactLookupFailed(
                    f"GET /contacts/{contact_id} failed after {attempts} "
                    f"attempts: {type(e).__name__}: {e}") from e
            _backoff(a)
    return None  # unreachable — the loop always returns or raises


def contact_email_of(c, token):
    # <- scripts/cs-needs-human-digest.py:206-246 (contact_email_of)
    """Fast path: source.author.type == "user" -> source.author.email
    directly (verified customer identity, zero GET). Slow path (GET
    /contacts/{id}, cached) only when the author is not a user. In THIS
    script the slow path is invoked ONLY to CONFIRM an already-formed
    candidate group's members (bounded, small), never to form groups over
    the whole backlog — see module docstring."""
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


def is_inbound_conv(c):
    # <- scripts/cs-needs-human-digest.py:263-288 (is_inbound_conv)
    src = c.get("source") or {}
    delivered_as = src.get("delivered_as")
    if delivered_as:
        return delivered_as == "customer_initiated"
    au = src.get("author") or {}
    return au.get("type") in {"user", "lead", "contact"}


def fetch_open_convs(token, limit=0):
    """List OPEN Intercom conversations (read-only), extended with created_at
    + the raw source object so grouping can derive is_inbound and the
    FAST-PATH-ONLY email (never the slow-path GET /contacts/{id} fallback —
    see module docstring: grouping the whole backlog via the slow path would
    be an N+1 rate-limit risk). <- close-resolved-conversations.py:170-193
    (pagination shape) + cs-needs-human-digest.py:291-319 (created_at /
    is_inbound fields)."""
    convs = []
    after = None
    while True:
        body = {"query": {"field": "state", "operator": "=", "value": "open"},
                "pagination": {"per_page": 150}}
        if after:
            body["pagination"]["starting_after"] = after
        data = intercom_search(token, body)
        for c in data.get("conversations", []):
            src = c.get("source") or {}
            au = src.get("author") or {}
            stats = c.get("statistics") or {}
            convs.append({
                "id": c.get("id"),
                # FAST PATH ONLY for grouping — a fast-path-empty conv simply
                # never joins a group (fails safe, no close).
                "email": (au.get("email") or "").strip().lower() if au.get("type") == "user" else "",
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
# De-confliction reader — copied verbatim in behavior from
# cs-needs-human-digest.py:327-411 (_read_json_file / _read_jsonl_file /
# owned_ids / default_state_paths). De-conflicts by CONVERSATION ID ONLY,
# never contact email — see that module's docstring for the full rationale
# (a returning customer's email lingering in an append-only sibling log must
# never permanently hide their brand-new conversation).
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
            continue
    return out


def owned_ids(paths):
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
        "dedup-shadow": (
            os.environ.get("DEDUP_SHADOW_LOG", "/var/log/dedup-shadow.jsonl"),
            "jsonl"),
        # Stale-backlog closer (scripts/close-stale-conversations.py,
        # human-run) — a conversation it already closed must not be grouped
        # or re-closed here.
        "close-stale": (
            os.environ.get("CLOSE_STALE_SHADOW_LOG", "/var/log/close-stale-shadow.jsonl"),
            "jsonl"),
    }


def is_owned(conv, owned_id_set):
    return conv["id"] in owned_id_set


# --------------------------------------------------------------------------
# Pure logic (no network — directly unit-testable). Grouping, tiering,
# keep-selection, kept_id handling.
# --------------------------------------------------------------------------
def tier_for(older, kept, window_days=DEFAULT_TIER_B_WINDOW_DAYS):
    """Return "A", "B", or None (never closed). See module docstring for
    the full tier definitions — this is the single source of truth for the
    gate, exercised both at grouping time and again at pre-close re-verify
    time against fresh statistics."""
    lar, lcr = older["lar"], older["lcr"]
    if lar > 0 and lar > lcr:
        return "A"
    if lar == 0 and kept["lar"] > 0:
        window_secs = window_days * 86400
        if (kept["created_at"] - older["created_at"]) <= window_secs:
            return "B"
    return None


def group_duplicates(convs, owned_id_set, window_days=DEFAULT_TIER_B_WINDOW_DAYS):
    """Pure grouping + tiering. Returns a list of group dicts:
    {"email": str, "kept": conv, "closable": [{"older", "kept", "tier",
    "email"}, ...]}. A group is only returned if it has >=1 closable member
    (groups with zero closable members carry nothing to act on and are
    silently omitted — the digest still surfaces them as dup-candidate for
    a human).

    Duplicate-group membership requires: inbound + non-empty fast-path
    email (see fetch_open_convs); KEEP = newest by created_at, with a tie
    for newest skipping the WHOLE group (ambiguous ordering, same reasoning
    as close-resolved's lar==lcr skip); the kept thread must not be
    sibling-owned (skip the whole group if it is) — an individually
    sibling-owned OLDER member is simply excluded from the closable set,
    leaving the rest of the group's evaluation intact."""
    candidates = [c for c in convs if c.get("is_inbound") and c.get("email")]
    by_email = {}
    for c in candidates:
        by_email.setdefault(c["email"], []).append(c)

    groups = []
    for email, members in by_email.items():
        if len(members) < 2:
            continue
        max_created = max(m["created_at"] for m in members)
        newest = [m for m in members if m["created_at"] == max_created]
        if len(newest) != 1:
            continue  # ambiguous keep (tie) -> skip whole group
        kept = newest[0]
        if is_owned(kept, owned_id_set):
            continue  # kept sibling-owned -> skip whole group

        closable = []
        for m in members:
            if m["id"] == kept["id"]:
                continue
            if is_owned(m, owned_id_set):
                continue  # leave this one for a human; keep evaluating siblings
            tier = tier_for(m, kept, window_days)
            if tier:
                closable.append({"older": m, "kept": kept, "tier": tier, "email": email})

        if closable:
            # group_size = the TRUE duplicate-thread count for this email
            # (every inbound member, INCLUDING the kept thread and any
            # active/sibling-owned member that isn't itself closable), so
            # the review export reflects how heavily the email was grouped,
            # not just how many closes it produced. See flatten_candidates.
            groups.append({"email": email, "kept": kept, "closable": closable,
                           "group_size": len(members)})
    return groups


def flatten_candidates(groups):
    """All individual (older, kept, tier) closes across every group,
    flattened — --limit counts these individually, per the plan.

    Each flattened candidate also carries "group_size" — the true
    duplicate-thread count for its group (g["group_size"] = len(members)
    from group_duplicates: every inbound thread sharing the email,
    INCLUDING the kept thread and any active/sibling-owned member that
    isn't itself closable). This is consumed by write_review_export's
    _review_export_candidate so a reviewer can pull every candidate from a
    >=3-thread group into the masked-email stratified review — it must
    reflect how heavily the email was grouped, not just how many closes it
    produced."""
    out = []
    for g in groups:
        for c in g["closable"]:
            out.append({**c, "group_size": g["group_size"]})
    return out


# --------------------------------------------------------------------------
# Network writes.
# --------------------------------------------------------------------------
def get_conversation(token, conv_id):
    """GET /conversations/{id} (read-only) — used for the pre-close
    re-verify. Returns a summary dict (id/state/lar/lcr/created_at/
    confirm_email) or None on any failure (the caller treats None as
    "cannot re-verify -> skip this close", never as "still valid").

    confirm_email is resolved via the INDEPENDENT slow path — GET
    /contacts/{id} on this conversation's own contact reference — NEVER via
    contact_email_of's fast path (source.author.email), which is the SAME
    value already used to form the group and so confirms nothing. A missing
    contact id, a 404, or a ContactLookupFailed all yield confirm_email=""
    (empty), which the caller (reverify_still_valid) treats as fail-closed.
    Bounded to exactly one GET /contacts/{id} per conversation per close
    (cached process-lifetime via _contact_email_cache), so no N+1."""
    req = urllib.request.Request(
        f"{INTERCOM_API}/conversations/{conv_id}",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                 "Intercom-Version": INTERCOM_VERSION},
        method="GET")
    try:
        data = _retry_json(req)
    except (urllib.error.URLError, ValueError):
        return None
    stats = data.get("statistics") or {}
    confirm_email = ""
    contacts = ((data.get("contacts") or {}).get("contacts") or [])
    cid = contacts[0].get("id") if contacts and contacts[0].get("id") else None
    if cid:
        try:
            if cid in _contact_email_cache:
                confirm_email = _contact_email_cache[cid]
            else:
                contact = get_contact(cid, token)
                confirm_email = ((contact or {}).get("email") or "").strip().lower()
                _contact_email_cache[cid] = confirm_email
        except ContactLookupFailed:
            confirm_email = ""
    return {
        "id": data.get("id"),
        "state": data.get("state"),
        "lar": stats.get("last_admin_reply_at") or 0,
        "lcr": stats.get("last_contact_reply_at") or 0,
        "created_at": data.get("created_at") or 0,
        "confirm_email": confirm_email,
        # First customer message text, for the shadow-only dedupe-same-request
        # Jev surface (docs/plans/jev-adoption.md #2a) — no closing/dedup logic
        # reads this field, it exists only to feed that shadow judgment.
        "source_body": _strip_html((data.get("source") or {}).get("body")),
    }


def reverify_still_valid(token, older, kept, tier, window_days=DEFAULT_TIER_B_WINDOW_DAYS):
    """Immediately-before-close re-verification (deviation from
    close-resolved, required for a one-way-door action): fresh GETs of
    BOTH conversations re-assert the target is still open, its tier gate
    still holds against FRESH statistics, the kept thread is still open,
    AND an INDEPENDENT slow-path contact lookup (get_conversation's
    confirm_email — GET /contacts/{id}, never the fast-path author email
    already used to form the group) confirms the grouping email for both.

    FAIL CLOSED: an empty/missing confirm_email is NEVER treated as "no
    objection" — it always skips the close, same as an explicit mismatch.
    Only a non-empty confirm_email that equals the grouped email (both
    already lowercased/trimmed) allows the close to proceed."""
    fresh_older = get_conversation(token, older["id"])
    fresh_kept = get_conversation(token, kept["id"])
    if not fresh_older or not fresh_kept:
        return False
    if fresh_older["state"] != "open" or fresh_kept["state"] != "open":
        return False
    if tier_for(fresh_older, fresh_kept, window_days) != tier:
        return False
    if not fresh_older["confirm_email"] or fresh_older["confirm_email"] != older["email"]:
        return False
    if not fresh_kept["confirm_email"] or fresh_kept["confirm_email"] != kept["email"]:
        return False
    return True


def close_conversation(token, admin_id, conv_id):
    # <- scripts/close-resolved-conversations.py:223-231
    req = urllib.request.Request(
        f"{INTERCOM_API}/conversations/{conv_id}/parts",
        data=json.dumps({"message_type": "close", "type": "admin", "admin_id": str(admin_id)}).encode(),
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                 "Content-Type": "application/json", "Intercom-Version": INTERCOM_VERSION},
        method="POST")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def post_pointer_comment(token, admin_id, conv_id, message):
    """POST /conversations/{id}/reply, message_type "comment" — a
    customer-visible admin reply. Same shape as resolve-notify.py's
    post_intercom_reply (scripts/resolve-notify.py:182-188)."""
    # THE OUTBOUND COPY GATE (captain 2026-11-12): the exact body must carry a signed reviewer verdict, or it does
    # not go out. This is the only customer POST in this file, so there is no path around it.
    copy_gate.require(COPY_CAMPAIGN, message)
    req = urllib.request.Request(
        f"{INTERCOM_API}/conversations/{conv_id}/reply",
        data=json.dumps({"message_type": "comment", "type": "admin",
                         "admin_id": str(admin_id), "body": message}).encode(),
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                 "Content-Type": "application/json", "Intercom-Version": INTERCOM_VERSION},
        method="POST")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def open_shadow_log():
    path = os.environ.get("CLOSE_DUP_SHADOW_LOG", "/var/log/close-duplicate-shadow.jsonl")
    try:
        return open(path, "a"), path
    except OSError:
        fallback = "/tmp/close-duplicate-shadow.jsonl"
        try:
            return open(fallback, "a"), fallback
        except OSError:
            return None, None


def mask_email(email):
    """Mask a customer email for the review export -- "a***@***" style,
    hiding the domain too, not just the local part: a full domain can
    single out a customer on a personal-name domain. Same masking as the
    sibling digest's mask_email (scripts/cs-needs-human-digest.py:525-530),
    adopted here for consistency -- never used for grouping/tiering,
    display only."""
    if not email:
        return ""
    local = email.split("@", 1)[0]
    if not local:
        return "***@***"
    return f"{local[0]}***@***"


def _review_export_candidate(c):
    older, kept, tier, email = c["older"], c["kept"], c["tier"], c["email"]
    return {
        "older_id": older["id"],
        "newer_id": kept["id"],
        "email": mask_email(email),
        "tier": tier,
        "older_created_at": older["created_at"],
        "older_last_admin_reply_at": older["lar"],
        "older_last_contact_reply_at": older["lcr"],
        "kept_created_at": kept["created_at"],
        # group_size = the true duplicate-thread count of this candidate's
        # own group (len(members) in group_duplicates; see
        # flatten_candidates) -- with the email masked, this is the only
        # lever a reviewer has to pull every candidate from a >=3-thread
        # group for stratified review.
        "group_size": c["group_size"],
    }


def _safe_fallback_dir():
    """Prepare FALLBACK_REVIEW_DIR as a private (0700, owned-by-us,
    non-symlink) directory and return its path, or print a loud stderr and
    return None if it can't be made/verified safe. The export contains
    customer email addresses, so the fallback must never be a predictable
    world-readable path (unlike open_shadow_log's bare /tmp fallback)."""
    path = FALLBACK_REVIEW_DIR
    try:
        if os.path.islink(path):
            print(f"ERROR: fallback review dir {path} is a symlink -- "
                  "refusing to write", file=sys.stderr)
            return None
        if os.path.exists(path):
            st = os.lstat(path)
            if not stat.S_ISDIR(st.st_mode) or stat.S_IMODE(st.st_mode) != 0o700 \
                    or st.st_uid != os.getuid():
                print(f"ERROR: fallback review dir {path} exists with unsafe "
                      "ownership/mode -- refusing to write", file=sys.stderr)
                return None
        else:
            os.makedirs(path, mode=0o700, exist_ok=True)
        return path
    except OSError as e:
        print(f"ERROR: cannot prepare fallback review dir {path}: {e}", file=sys.stderr)
        return None


def write_review_export(candidates, when_date):
    """Write the full dry-run candidate list (every run, not just over-
    ceiling ones -- see module docstring's ceiling-gates-only---apply
    change) to CLOSE_DUP_REVIEW_DIR/candidates-<when_date>.json, one JSON
    doc {generated_at, total, tier_a, tier_b}. Mirrors open_shadow_log's
    primary-dir-then-/tmp-fallback pattern with a loud stderr on failure of
    either -- this is the supervised-drain review surface (Jan/Nick), so a
    silently-lost export would be as bad as a silently-lost shadow log. The
    fallback lands in a private FALLBACK_REVIEW_DIR (see _safe_fallback_dir),
    not the bare /tmp root, and both the primary and fallback files are
    chmod 0600 after write -- the export carries customer email addresses.
    Returns the path actually written, or None if both attempts failed."""
    tier_a = [_review_export_candidate(c) for c in candidates if c["tier"] == "A"]
    tier_b = [_review_export_candidate(c) for c in candidates if c["tier"] == "B"]
    doc = {
        "generated_at": int(time.time()),
        "total": len(tier_a) + len(tier_b),
        "tier_a": tier_a,
        "tier_b": tier_b,
    }
    filename = f"candidates-{when_date}.json"
    primary_dir = os.environ.get("CLOSE_DUP_REVIEW_DIR", DEFAULT_REVIEW_DIR)
    primary_path = os.path.join(primary_dir, filename)
    try:
        os.makedirs(primary_dir, exist_ok=True)
        with open(primary_path, "w") as f:
            json.dump(doc, f)
        os.chmod(primary_path, 0o600)
        return primary_path
    except OSError as e:
        print(f"WARN: cannot write review export to {primary_path}: {e} "
              f"-- falling back to {FALLBACK_REVIEW_DIR}", file=sys.stderr)
        fallback_dir = _safe_fallback_dir()
        if fallback_dir is None:
            return None
        fallback_path = os.path.join(fallback_dir, filename)
        try:
            with open(fallback_path, "w") as f:
                json.dump(doc, f)
            os.chmod(fallback_path, 0o600)
            return fallback_path
        except OSError as e2:
            print(f"ERROR: cannot write review export to fallback "
                  f"{fallback_path} either: {e2}", file=sys.stderr)
            return None


def _pointer_state_path():
    return os.environ.get("CLOSE_DUP_POINTER_STATE", "/var/lib/close-duplicate/pointer-posted.json")


class PointerStateUnreadable(Exception):
    """Raised by load_pointer_state() when the state file EXISTS but cannot
    be read/parsed (as opposed to a legitimate first run, where the file
    simply does not exist yet). _read_json_file() collapses both cases to
    None, and `None or {}` would make a corrupt/unreadable file look
    identical to a clean first run — after confirmed posts, every
    conversation would look unseen and the loop would re-persist "pending"
    and RE-POST the customer pointer (breaks exactly-once). The caller MUST
    treat this as untrusted state, not as an empty state."""


def load_pointer_state():
    path = _pointer_state_path()
    if not os.path.exists(path):
        return {}
    state = _read_json_file(path)
    if state is None:
        raise PointerStateUnreadable(path)
    return state


def save_pointer_state(state):
    """Atomically persist the pointer_posted marker state (temp file +
    os.replace, so a crash mid-write never leaves a truncated/corrupt file).
    Returns True on success, False on ANY OSError — the caller MUST treat
    False as a hard stop for that conversation (no pointer post, no close):
    a lost marker is how the #1 harm (double-messaging a customer) happens,
    so persistence failure is never swallowed into "proceed anyway"."""
    path = _pointer_state_path()
    try:
        d = os.path.dirname(path) or "."
        os.makedirs(d, exist_ok=True)
        fd, tmp_path = tempfile.mkstemp(prefix=".pointer-posted-", dir=d)
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(state, f)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp_path, path)
        except OSError:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            raise
        return True
    except OSError as e:
        print(f"ERROR: could not durably persist pointer state to {path}: {e}", file=sys.stderr)
        return False


# --------------------------------------------------------------------------
# Slack notify trio. <- scripts/close-resolved-conversations.py:246-322
# --------------------------------------------------------------------------
def _slack_escape(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _read_slack_token(config_path, account):
    try:
        with open(config_path) as f:
            cfg = json.load(f)
        from lib.slack_token import resolve_secret
        return resolve_secret(cfg["channels"]["slack"]["accounts"][account]["botToken"])
    except (OSError, KeyError, ValueError, TypeError):
        return None


def post_slack_summary(text, channel, config_path, account):
    """Best-effort post to Slack. NEVER raises. Returns bool."""
    token = _read_slack_token(config_path, account)
    if not token:
        print(f"WARN: no Slack token for account '{account}' in {config_path}; notify skipped", file=sys.stderr)
        return False
    try:
        req = urllib.request.Request(
            SLACK_API,
            data=json.dumps({"channel": channel, "text": text,
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
    except Exception as e:  # noqa: BLE001 — best-effort by contract.
        print(f"WARN: Slack post error: {type(e).__name__}: {str(e)[:140]}", file=sys.stderr)
        return False


def format_candidates_summary(candidates, when, max_lines=SUMMARY_MAX_LINES,
                               review_path=None, tier_a_n=None, tier_b_n=None):
    """Render the "would close X -> kept Y (tier A/B)" pairs for
    --notify-candidates. Posted EVEN ON DRY-RUN — close-resolved's notify
    gates on apply && ok>0, which is insufficient for shadow-phase review.

    review_path/tier_a_n/tier_b_n are all optional; tier_a_n/tier_b_n are
    required together and add a trailing line pointing Jan/Nick at the full
    review export written by write_review_export -- the Slack summary
    itself is capped at max_lines, the export is not. If tier_a_n/tier_b_n
    are set but review_path is None, write_review_export failed both
    attempts -- say so explicitly rather than silently dropping the line."""
    n = len(candidates)
    plural = "" if n == 1 else "s"
    lines = [f":mag: *{n} duplicate-close candidate{plural}* — {when}"]
    for c in candidates[:max_lines]:
        older, kept, tier = c["older"], c["kept"], c["tier"]
        lines.append(
            f"• conversation {older['id']} → kept {kept['id']} "
            f"(tier {tier}, {_slack_escape(c.get('email') or 'no email')})")
    if n > max_lines:
        lines.append(f"…and {n - max_lines} more")
    if review_path is not None:
        lines.append(
            f"_Full review export (Tier A {tier_a_n} / Tier B {tier_b_n}): "
            f"{review_path}_")
    elif tier_a_n is not None or tier_b_n is not None:
        # write_review_export returned None -- both primary and fallback
        # writes failed. Don't let the notify text silently omit that.
        lines.append("_review export FAILED — see stderr_")
    return "\n".join(lines)


def format_closed_summary(closed, when, shadow_path=None, max_lines=SUMMARY_MAX_LINES):
    n = len(closed)
    plural = "" if n == 1 else "s"
    lines = [f":white_check_mark: *Closed {n} duplicate conversation{plural}* — {when}"]
    for c in closed[:max_lines]:
        lines.append(
            f"• conversation {c['id']} → kept {c['kept_id']} "
            f"(tier {c['tier']}, {_slack_escape(c.get('email') or 'no email')})")
    if n > max_lines:
        lines.append(f"…and {n - max_lines} more")
    if shadow_path:
        lines.append(f"_Reversible — full log: {shadow_path}_")
    return "\n".join(lines)


def format_ceiling_alert(n_candidates, when, ceiling=DUP_CEILING):
    return (f":rotating_light: *Duplicate-close sanity ceiling exceeded* — {when}\n"
            f"{n_candidates} candidate closes identified (> {ceiling}). "
            f"Closing NOTHING this run — this is a grouping bug or an Intercom "
            f"incident, not a queue to drain.")


def _slack_env():
    channel = os.environ.get("CLOSE_DUP_SUMMARY_CHANNEL", DEFAULT_SUMMARY_CHANNEL)
    cfg = os.environ.get("SLACK_NOTIFY_CONFIG", "/root/.openclaw-main/openclaw.json")
    account = os.environ.get("CLOSE_DUP_SLACK_ACCOUNT", "operations")
    return channel, cfg, account


def _dedupe_shadow_judge(token, older, kept, tier):
    """Fire the dedupe-same-request shadow judgement for one candidate.
    Shared by both callers so a given candidate is never judged twice:
      - the --apply close loop, strictly AFTER reverify_still_valid() has
        already confirmed this candidate closes -- called once per
        candidate in `targets` (already <=DUP_CEILING, so every targeted
        candidate is judged);
      - the dry-run path, strictly AFTER `candidates` (the script's own
        decision) is already final -- there is no reverify step in
        dry-run, so the finalized candidate list itself is the "already
        decided" point. Called once per candidate in a FRESH random
        sample of that list (see _dedupe_jev_sample_size), never the
        whole (potentially large) pool and never its head.
    Can never change `tier`, a close, stdout, or the exit code. The two
    re-fetches (read-only; this script is SHADOW-MODE ONLY, no --apply in
    the prod timer) that source each thread's first customer message live
    in build_state, run lazily INSIDE shadow_judge's never-raise boundary
    — get_conversation only catches URLError/ValueError, so a
    RemoteDisconnected/socket-timeout OSError here would otherwise raise
    straight through the caller's loop and (in the --apply case) abort a
    legitimate close.
    """
    def _dedupe_build_state(older=older, kept=kept):
        older_detail = get_conversation(token, older["id"])
        kept_detail = get_conversation(token, kept["id"])
        if not older_detail or not kept_detail:
            return None
        return {"thread_a_first_message": older_detail.get("source_body"),
                "thread_b_first_message": kept_detail.get("source_body")}

    shadow_judge(JEV_SURFACE_DEDUPE, older["id"], _dedupe_build_state,
                 DEDUPE_QUESTIONS, actual=tier)


def _dedupe_jev_sample_size():
    """CLOSE_DUP_JEV_SAMPLE_SIZE (env, default DEFAULT_DEDUPE_JEV_SAMPLE_SIZE)
    -- validated identically to close-resolved-conversations.py's own
    _jev_sample_size(): unset/unparseable/<=0 all fall back to the default,
    never zero or negative (a caller passing 0 through would silently
    disable the dry-run sample instead of erroring)."""
    raw = os.environ.get("CLOSE_DUP_JEV_SAMPLE_SIZE")
    if not raw:
        return DEFAULT_DEDUPE_JEV_SAMPLE_SIZE
    try:
        n = int(raw)
    except ValueError:
        return DEFAULT_DEDUPE_JEV_SAMPLE_SIZE
    return n if n > 0 else DEFAULT_DEDUPE_JEV_SAMPLE_SIZE


def main():
    ap = argparse.ArgumentParser(description="Auto-close strictly-safe duplicate Intercom conversations")
    ap.add_argument("--apply", action="store_true",
                    help="actually close (default: dry-run — identify only)")
    ap.add_argument("--limit", type=int, default=0,
                    help="cap individual closes this run (0 = no cap)")
    ap.add_argument("--notify-candidates", action="store_true",
                    help="post would-close candidate pairs to #cs_chats, even on dry-run")
    ap.add_argument("--ceiling", type=int, default=None,
                    help="override DUP_CEILING for this run's --apply hard-stop "
                         "(flag only, never env/config — auditable and "
                         "self-expiring; must be > 0)")
    args = ap.parse_args()

    if args.ceiling is not None and args.ceiling <= 0:
        print(f"ERROR: --ceiling must be > 0 (got {args.ceiling})", file=sys.stderr)
        return 2
    effective_ceiling = args.ceiling if args.ceiling is not None else DUP_CEILING

    token = os.environ.get("MUSOAI_INTERCOM_TOKEN")
    if not token:
        print("ERROR: MUSOAI_INTERCOM_TOKEN is required", file=sys.stderr)
        return 1
    admin_id = resolve_admin_id()
    window_days = int(os.environ.get("DUP_TIER_B_WINDOW_DAYS", str(DEFAULT_TIER_B_WINDOW_DAYS)))

    try:
        convs = fetch_open_convs(token)
    except ContactLookupFailed as e:
        print(f"ERROR: contact lookup failed systematically: {e}", file=sys.stderr)
        return 1

    ids = owned_ids(default_state_paths())
    groups = group_duplicates(convs, ids, window_days)
    candidates = flatten_candidates(groups)

    print(f"open conversations scanned: {len(convs)}")
    print(f"duplicate groups with a closable member: {len(groups)}")
    print(f"candidate closes (individual): {len(candidates)}")

    when = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime())
    # HHMMSS included so same-day reruns don't truncate-overwrite an
    # earlier run's export -- see write_review_export.
    when_date = time.strftime("%Y-%m-%dT%H%M%SZ", time.gmtime())
    channel, cfg, account = _slack_env()
    over_ceiling = len(candidates) > effective_ceiling

    # Ceiling gates ONLY --apply. Exceeding it in dry-run/shadow mode must
    # NOT exit 2 or post the red format_ceiling_alert — a backlogged fire
    # is exactly the reviewable-candidate-list case the shadow export below
    # exists for. With --apply, keep today's behavior byte-for-byte: post
    # the alert and exit 2 BEFORE any close, gated against the effective
    # (possibly --ceiling-overridden) ceiling.
    if over_ceiling:
        if args.apply:
            print(f"ERROR: sanity ceiling exceeded ({len(candidates)} > {effective_ceiling}) — "
                  "closing nothing", file=sys.stderr)
            post_slack_summary(format_ceiling_alert(len(candidates), when, effective_ceiling),
                                channel, cfg, account)
            return 2
        print(f"WARNING: ceiling would block --apply: {len(candidates)} > {effective_ceiling}")

    review_path = None
    tier_a_n = tier_b_n = None
    if not args.apply:
        tier_a_n = sum(1 for c in candidates if c["tier"] == "A")
        tier_b_n = sum(1 for c in candidates if c["tier"] == "B")
        review_path = write_review_export(candidates, when_date)
        print(f"review export: {review_path or 'FAILED (see stderr)'} "
              f"(Tier A {tier_a_n} / Tier B {tier_b_n})")

    if args.notify_candidates:
        text = format_candidates_summary(candidates, when, review_path=review_path,
                                          tier_a_n=tier_a_n, tier_b_n=tier_b_n)
        posted = post_slack_summary(text, channel, cfg, account)
        print(f"candidate notify: {'posted' if posted else 'skipped/failed'} -> {channel}")

    if not args.apply:
        # Shadow-only (Phase 2a #2a): the prod timer runs dry-run only, so
        # this is the ONLY place dedupe-same-request ever fires in prod
        # today (see _dedupe_shadow_judge's docstring). There's no reverify
        # step in dry-run, so `candidates` above -- already final by this
        # point -- is the "already decided" point instead. The pool has no
        # ceiling (unlike --apply's `targets`), so this draws a FRESH
        # random sample each run rather than `candidates[:15]` below or the
        # whole pool -- a head slice would judge the SAME candidates in the
        # SAME order every run, a biased, non-representative sample (verbatim
        # close-resolved-conversations.py pattern; see its "jev shadow
        # sample" comment).
        jev_k = min(_dedupe_jev_sample_size(), len(candidates))
        if jev_k > 0:
            jev_seed = random.SystemRandom().randrange(2 ** 32)
            print(f"jev shadow sample: seed={jev_seed} size={jev_k} "
                  f"(pool={len(candidates)})", file=sys.stderr)
            for c in random.Random(jev_seed).sample(candidates, jev_k):
                _dedupe_shadow_judge(token, c["older"], c["kept"], c["tier"])
        for c in candidates[:15]:
            print(f"  would close conv={c['older']['id']} -> kept={c['kept']['id']} tier={c['tier']}")
        if len(candidates) > 15:
            print(f"  ... and {len(candidates) - 15} more")
        print("DRY-RUN — no conversations closed. Re-run with --apply to close.")
        return 0

    targets = candidates[:args.limit] if args.limit > 0 else candidates
    shadow, shadow_path = open_shadow_log()
    if shadow is None:
        # A one-way-door action cannot silently lose its audit trail — this
        # is intentionally STRICTER than close-resolved-conversations.py,
        # justified by the destructive (customer-facing close) nature of
        # this sweeper: close nothing, exit non-zero, notify.
        print("ERROR: cannot open shadow log (primary and /tmp fallback both "
              "failed) — closing nothing", file=sys.stderr)
        post_slack_summary(
            ":rotating_light: *Duplicate-close audit log unopenable* — "
            f"{when}\nClosing NOTHING this run (no audit trail = no close).",
            channel, cfg, account)
        return 3
    try:
        pointer_state = load_pointer_state()
    except PointerStateUnreadable as e:
        # Fail closed: untrusted pointer state in --apply mode must never be
        # treated as "no conversations seen yet" — that's exactly how a
        # confirmed "posted" marker would get silently forgotten and the
        # customer pointer re-sent. Abort before any Tier-B post/close.
        print(f"ERROR: pointer state file exists but is unreadable/corrupt "
              f"({e}) — refusing to proceed with untrusted state "
              "(closing nothing)", file=sys.stderr)
        post_slack_summary(
            ":rotating_light: *Duplicate-close pointer state unreadable/corrupt* — "
            f"{when}\nClosing NOTHING this run (untrusted state could double-post "
            "the customer pointer).",
            channel, cfg, account)
        return 3
    closed, fail = [], []
    for cand in targets:
        older, kept, tier, email = cand["older"], cand["kept"], cand["tier"], cand["email"]
        if not reverify_still_valid(token, older, kept, tier, window_days):
            print(f"  SKIP conv={older['id']}: pre-close re-verify failed (state/tier/email changed)")
            continue
        # Shadow-only (Phase 2a #2a): fires strictly AFTER reverify_still_valid()
        # already confirmed this candidate closes. See _dedupe_shadow_judge's
        # docstring for the full contract (never changes `tier`, `closed`,
        # `fail`, stdout, or the exit code).
        _dedupe_shadow_judge(token, older, kept, tier)

        if tier == "B":
            # Two-state marker ("pending" -> "posted"), keyed on the older
            # conv id — a bare boolean can't distinguish "we attempted the
            # post" from "the post is CONFIRMED delivered", which is exactly
            # what let a failed POST silently skip straight to closing on
            # the NEXT run (the pointer never sent, the customer never told
            # their duplicate was merged). ANY value other than the exact
            # string "posted" — including "pending" and a legacy boolean
            # True from an older state file — is treated as unconfirmed and
            # HOLDS: no close, no re-post (a re-post risks double-messaging
            # a customer whose original POST may have actually landed).
            status = pointer_state.get(str(older["id"]))
            if status != "posted":
                # The copy gate is asked BEFORE the "pending" marker below: a held pointer must leave no marker,
                # or a later run would treat a comment that was never posted as an unconfirmed delivery.
                try:
                    copy_gate.require(COPY_CAMPAIGN, POINTER_TEXT)
                except copy_gate.CopyHeld as e:
                    fail.append((older["id"], f"pointer held by the copy gate (no post, no close): {str(e)[:140]}"))
                    continue
                if status is None:
                    # First attempt this conversation has ever seen: record
                    # "pending" BEFORE the POST. Persist failure -> skip
                    # entirely (no post, no close), same as before.
                    pending_state = dict(pointer_state)
                    pending_state[str(older["id"])] = "pending"
                    if not save_pointer_state(pending_state):
                        fail.append((older["id"], "pointer marker persist failed — skipped (no post, no close)"))
                        continue
                    pointer_state = pending_state
                    try:
                        post_pointer_comment(token, admin_id, older["id"], POINTER_TEXT)
                    except (urllib.error.URLError, ValueError) as e:
                        fail.append((older["id"], f"pointer post failed: {str(e)[:140]}"))
                        continue
                    posted_state = dict(pointer_state)
                    posted_state[str(older["id"])] = "posted"
                    if not save_pointer_state(posted_state):
                        # POST succeeded but we can't durably record that —
                        # HOLD (don't close) rather than risk a future run
                        # re-posting on a marker still stuck at "pending".
                        fail.append((older["id"], "pointer posted but 'posted' marker persist failed — held"))
                        continue
                    pointer_state = posted_state
                else:
                    # status == "pending" (a prior POST attempt failed or
                    # never confirmed) or any other unrecognized/legacy
                    # value (e.g. an old boolean True) — hold this run.
                    # Never re-post (may have already sent); never close
                    # (the customer may not have been told).
                    fail.append((older["id"], f"pointer status unconfirmed ({status!r}) — held, no re-post, no close"))
                    continue

            # Post-pointer race guard (Tier B only): a customer can reply
            # to the pointer comment during the window between the "posted"
            # marker and the close below. reverify_still_valid() already
            # ran BEFORE this pointer workflow, not after, so it can't see
            # that reply. A generic "we spoke last" check is USELESS here —
            # the pointer POST is itself an admin reply, so last_admin_reply
            # already advances trivially past any customer reply. Detect a
            # CUSTOMER reply specifically: compare the fresh
            # last_contact_reply_at against the value captured at
            # grouping/first-verify (older["lcr"]).
            fresh = get_conversation(token, older["id"])
            if not fresh or fresh["state"] != "open" or fresh["lcr"] > older["lcr"]:
                fail.append((older["id"], "post-pointer re-check: target no longer open or "
                                           "customer replied during the pointer window — held"))
                continue

        try:
            res = close_conversation(token, admin_id, older["id"])
            rec = {"id": older["id"], "closed_at": int(time.time()), "email": email,
                   "kept_id": kept["id"], "tier": tier, "new_state": res.get("state")}
            try:
                shadow.write(json.dumps(rec) + "\n")
                shadow.flush()
            except OSError as e:
                fail.append((older["id"], f"CLOSED but shadow-log write failed (audit gap!): {str(e)[:140]}"))
                continue
            closed.append(rec)
        except (urllib.error.URLError, ValueError) as e:
            fail.append((older["id"], str(e)[:140]))
        time.sleep(0.3)
    shadow.close()

    ok = len(closed)
    print(f"closed_ok={ok} failed={len(fail)} (shadow log: {shadow_path})")
    for f in fail[:15]:
        print(f"  FAIL {f}", file=sys.stderr)

    if ok > 0:
        text = format_closed_summary(closed, when, shadow_path)
        posted = post_slack_summary(text, channel, cfg, account)
        print(f"close notify: {'posted' if posted else 'skipped/failed'} -> {channel}")

    return 3 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
