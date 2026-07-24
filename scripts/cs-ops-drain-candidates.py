#!/usr/bin/env python3
"""Deterministic, READ-ONLY candidate lister for the CS ops-drain (Phase 2.1).

See docs/plans/cs-ops-drain-spec.md. The five live sweepers only CLOSE
conversations that are already resolved; Caroline only resolves reactively.
The ops-drain closes the gap: open conversations where the customer asked for
something, went silent, and the resolution is now mechanically available and
server-verifiable. This script is the DETERMINISTIC front half of that
machine — it lists the OPEN Intercom conversations that are still candidates
for the ops-drain (i.e. NOT already owned by any sibling sweeper), masks PII,
and hands them to the cs-ops-drain SKILL for light per-conversation
classification. It does NOT classify the target bucket, does NOT re-verify
resolvability, and does NOT execute any muso-cli write — those are the skill's
job (classification) and a FUTURE, sign-off-gated apply mode's job (writes).

THIS SCRIPT NEVER WRITES TO INTERCOM (no close, snooze, tag, reply) and never
calls muso-cli. Its ONLY optional side effect is appending JSONL records to
the ops-drain shadow log (OPS_DRAIN_SHADOW_LOG), and only when explicitly
asked (`--shadow-log` records the swept candidates; `--append-record` appends
one skill-classified candidate). Both are host-guarded.

De-confliction (THE load-bearing invariant, per the spec §De-confliction):
exclude any conversation whose CONVERSATION ID appears in ANY sibling
sweeper's state/shadow file. De-conflict by CONVERSATION ID, NEVER by contact
email — every sibling source records the conversation id, so id-matching is
sufficient; email-matching against these append-only, never-pruned logs would
permanently exclude a RETURNING customer's brand-new, unrelated conversation
(their email lingers in close-resolved-shadow.jsonl forever after any single
past close), silently hiding their next real issue. Contact email is masked
for display only, never used as a historical-ownership key. Sibling sources:
  - CLOSE_SHADOW_LOG        /var/log/close-resolved-shadow.jsonl   (jsonl; "id")
  - RESOLVE_NOTIFY_STATE    /var/lib/resolve-notify/notified.json  (json; "conv:<id>")
  - RESOLUTION_STATE_PATH   /var/lib/resolution-matcher/state.json (json; "conv:<id>")
  - RESOLUTION_SHADOW_LOG   /var/log/resolution-matcher-shadow.jsonl (jsonl; "conv_id")
  - OVERDUE_NOTIFY_STATE    /var/lib/overdue-verification-notifier/notified.json (json; "conv:<id>")
  - CLOSE_DUP_SHADOW_LOG    /var/log/close-duplicate-shadow.jsonl  (jsonl; "id")
  - CLOSE_DUP_POINTER_STATE /var/lib/close-duplicate/pointer-posted.json
                             (json-bare-keys; top-level conv-id keys — marks
                             conversations close-duplicate has mid-workflow,
                             regardless of pending/posted status)
  - DEDUP_SHADOW_LOG        /var/log/dedup-shadow.jsonl (jsonl; forward-compat
                             no-op — the dedup/close-merged path keys on profile
                             ids, not conversation id today; same known gap as
                             cs-needs-human-digest)
  - OPS_DRAIN_STATE         /var/lib/cs-ops-drain/acted.json       (json; "conv:<id>")
  - OPS_DRAIN_SHADOW_LOG    /var/log/cs-ops-drain-shadow.jsonl (jsonl-ops-drain;
                             own idempotency — survivor/swept records own the
                             conversation permanently, an "excluded" record only
                             until its recheck_after, so a rejected leading row
                             cannot starve later candidates yet a transient
                             EXCLUDE is re-examined later)

Output: ONE JSON object on stdout:
  {"candidates": [{"conversation_id", "masked_email", "created_at",
                   "waiting_since", "excerpt", "link"?}...],
   "excluded_counts": {<source-name>: <n>, ...},
   "scanned": <n>, "candidate_count": <n>, "scan_cap_hit": <bool>}
  ("link" is present only when INTERCOM_WORKSPACE_ID is set.)

Env:
  MUSOAI_INTERCOM_TOKEN         required (read-only Intercom access)
  OPS_DRAIN_SKIP_HOST_GUARD     "1" to run a shadow-log WRITE off ovh-node-8 (tests)
  OPS_DRAIN_HOSTNAME_OVERRIDE   override perceived hostname the host guard checks (tests)
  OPS_DRAIN_SHADOW_LOG          default /var/log/cs-ops-drain-shadow.jsonl
  OPS_DRAIN_STATE               default /var/lib/cs-ops-drain/acted.json
  (+ the CLOSE_SHADOW_LOG / RESOLVE_NOTIFY_STATE / CLOSE_DUP_POINTER_STATE /
  ... sibling overrides above)
  OPS_DRAIN_NOW                 optional epoch override (tests)
  INTERCOM_WORKSPACE_ID         optional — when set, each candidate carries a
                                 workspace-scoped Intercom deeplink ("link")
  CS_OPS_DRAIN_SCAN_CAP         hard safety cap on conversations SCANNED this
                                 run, independent of --limit (default 500)
  CS_OPS_DRAIN_EXCLUDE_RECHECK_DAYS  how long an EXCLUDE adjudication owns its
                                 conversation before it re-surfaces for re-check
                                 (default 14; see --append-record --exclude)

Flags:
  --limit N          cap the number of de-conflicted CANDIDATES this run
                     returns — de-confliction happens INLINE during
                     pagination and the scan stops as soon as this many
                     candidates are found, so a backlog >> limit doesn't
                     make every run re-scan the same already-owned leading
                     window and converge to ~0 candidates. Conversations
                     SCANNED to find them is separately bounded by
                     CS_OPS_DRAIN_SCAN_CAP.
  --shadow-log       append one swept-candidate record per candidate to the
                     ops-drain shadow log (host-guarded write)
  --append-record    append ONE skill-classified candidate record and exit;
                     requires --conversation-id, --verb, --reason (host-guarded)
  --conversation-id / --verb / --reason   payload for --append-record
  --self-test        run the inline self-test and exit

Exit codes: 0 ok; 1 usage/env error; 2 self-test failed; 3 systematic
            Intercom API failure (contact lookup or conversation search:
            401/403, or 429/5xx through exhausted retries); 4 a sibling
            sweeper's de-confliction state file exists but is unreadable/
            corrupt (fails loud rather than silently treating it as owning
            nothing — see SiblingStateUnreadable).
"""
import argparse
import html
import json
import os
import re
import socket
import sys
import time
import urllib.error
import urllib.request

INTERCOM_API = "https://api.intercom.io"
INTERCOM_VERSION = "2.11"
EXCERPT_MAX = 200
# Only these three muso-cli WRITE verbs are ever in scope for a FUTURE apply
# mode (spec §The target bucket). --append-record refuses any other verb so a
# mis-classified record can never name an out-of-scope action.
ALLOWED_VERBS = ("credits-verify", "profiles-claim-self", "profiles-consolidate")
NODE8_HOST = "ovh-node-8"
# Hard safety cap on conversations SCANNED per run, independent of --limit
# (which now bounds CANDIDATES found, not conversations scanned — see
# fetch_open_convs). Env-overridable; bounds runaway pagination against the
# real-world backlog (~4652 total open conversations).
DEFAULT_SCAN_CAP = 500
# How long an EXCLUDE adjudication owns its conversation before it re-surfaces
# for re-check. Without recording excludes at all, a persistently-rejected
# leading conversation would re-occupy a --limit candidate slot every run and
# starve later qualifying conversations; recording them permanently would drop
# a transient EXCLUDE (e.g. a pending credit not yet catalog-corroborated) that
# later qualifies. A bounded recheck window resolves both. Env-overridable.
DEFAULT_EXCLUDE_RECHECK_DAYS = 14

_EMAIL_RE = re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")
_TAG_RE = re.compile(r"<[^>]+>")
_WS_RE = re.compile(r"\s+")


def intercom_link(conv_id):
    """Workspace-scoped Intercom inbox deeplink for a conversation. Returns
    None (no "link" field) unless INTERCOM_WORKSPACE_ID is set — unlike
    cs-needs-human-digest's intercom_link (which defaults to workspace
    "dwjzhcge"), this lister keeps the field opt-in since it is optional per
    the module docstring."""
    workspace_id = os.environ.get("INTERCOM_WORKSPACE_ID")
    if not workspace_id:
        return None
    return f"https://app.intercom.com/a/inbox/{workspace_id}/inbox/conversation/{conv_id}"


# --------------------------------------------------------------------------
# Network seam (module-level so tests monkeypatch these, never real HTTP).
# --------------------------------------------------------------------------
class IntercomAPIFailed(Exception):
    """Base for a SYSTEMATIC (non-retryable-status, or retry-exhausted)
    Intercom API failure — auth/permissions (401/403) or a persistent
    rate-limit/outage (429/5xx). Distinct from a benign per-item miss (e.g.
    404 contact). Must propagate to main() and fail the run loudly (exit 3)
    rather than silently degrade the candidate list."""


def _retry_json(req, attempts=4):
    for a in range(attempts):
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as e:
            # 4xx other than 429 is not retryable (a 401/403 will never
            # succeed on retry; retrying just burns 4x the wall-clock before
            # failing the same way) — raise immediately. 429/5xx get the
            # normal retry-then-raise treatment.
            if e.code == 429 or 500 <= e.code < 600:
                if a == attempts - 1:
                    raise IntercomAPIFailed(
                        f"{req.full_url} -> {e.code} persisted through "
                        f"{attempts} attempts") from e
                time.sleep(2 * (a + 1))
                continue
            raise IntercomAPIFailed(
                f"{req.full_url} -> {e.code} (not retryable)") from e
        except urllib.error.URLError as e:
            if a == attempts - 1:
                raise IntercomAPIFailed(
                    f"{req.full_url} failed after {attempts} attempts: {e}") from e
            time.sleep(2 * (a + 1))


def intercom_search(token, body):
    req = urllib.request.Request(
        f"{INTERCOM_API}/conversations/search",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                 "Content-Type": "application/json", "Intercom-Version": INTERCOM_VERSION},
        method="POST")
    return _retry_json(req)


_contact_email_cache = {}


class ContactLookupFailed(IntercomAPIFailed):
    """A SYSTEMATIC contact-lookup failure — auth/permissions (401/403) or a
    rate-limit/outage (429/5xx) that persisted through retries. Distinct from a
    benign 404 (a genuinely missing/deleted contact, treated as "no email").
    Must propagate to main() and fail the run loudly rather than silently
    degrade the candidate list (same fail-loud principle as
    cs-needs-human-digest.get_contact)."""


def get_contact(contact_id, token, attempts=4):
    """GET /contacts/{contact_id} (read-only). 404 -> None (benign);
    401/403 -> raise (not retryable); 429/5xx -> retry then raise; any other
    status or persistent network failure -> raise. Mirrors
    cs-needs-human-digest.get_contact exactly."""
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
    """The real customer contact's email. Fast path: a `user`-type
    source.author IS the identity-verified customer contact, so its email is
    the real email (no GET). Only a non-user author (admin/bot/campaign) needs
    the follow-up GET /contacts/{id} (the `contacts` field is a Contact
    Reference list carrying NO email). Mirrors cs-needs-human-digest."""
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


def fetch_open_convs(token, owned_by_source, limit=0, scan_cap=None):
    """List OPEN Intercom conversations (read-only) and de-conflict them
    INLINE during pagination, stopping as soon as `limit` de-conflicted
    CANDIDATES are found (not once `limit` conversations are scanned — see
    the module docstring's --limit note: with a backlog >> limit, capping the
    raw scan instead of the candidate count would make every run re-fetch the
    same already-owned leading window and converge to ~0 candidates while
    real candidates sit unreachable further back). `scan_cap` is a separate,
    independent hard ceiling on conversations SCANNED, so a backlog with
    very few (or zero) candidates in it can't page forever.

    Returns (candidates, excluded_counts, scanned, scan_cap_hit).

    Captures the fields the candidate schema needs: id, contact email
    (masked downstream; only looked up for NOT-owned conversations — no
    reason to burn a contact GET on a conversation we're about to exclude),
    created_at, last_contact_reply_at (for waiting_since), and the initial
    message body (source.body) for the PII-masked excerpt. Mirrors
    cs-needs-human-digest.fetch_open_convs' pagination shape."""
    candidates = []
    excluded_counts = {name: 0 for name in owned_by_source}
    scanned = 0
    scan_cap_hit = False
    after = None
    while True:
        body = {"query": {"field": "state", "operator": "=", "value": "open"},
                "pagination": {"per_page": 150}}
        if after:
            body["pagination"]["starting_after"] = after
        data = intercom_search(token, body)
        for c in data.get("conversations", []):
            scanned += 1
            cid = c.get("id")
            if not _mark_if_owned(cid, owned_by_source, excluded_counts):
                stats = c.get("statistics") or {}
                src = c.get("source") or {}
                raw = {
                    "id": cid,
                    "email": contact_email_of(c, token),
                    "lcr": stats.get("last_contact_reply_at") or 0,
                    "created_at": c.get("created_at") or 0,
                    "source_body": src.get("body") or "",
                }
                candidates.append(_candidate_from_raw(raw))
            if limit and len(candidates) >= limit:
                return candidates, excluded_counts, scanned, scan_cap_hit
            if scan_cap and scanned >= scan_cap:
                return candidates, excluded_counts, scanned, True
        nxt = (data.get("pages") or {}).get("next")
        after = nxt.get("starting_after") if isinstance(nxt, dict) else None
        if not nxt or not after:
            break
    return candidates, excluded_counts, scanned, scan_cap_hit


# --------------------------------------------------------------------------
# De-confliction: read every sibling sweeper's state defensively. A missing
# or empty file means "no ownership" — this must NEVER crash the run, and it
# must NEVER be treated as "everything is owned" either. A file that EXISTS
# but is unreadable/corrupt is different — see SiblingStateUnreadable.
# --------------------------------------------------------------------------
class SiblingStateUnreadable(Exception):
    """Raised when a sibling sweeper's de-confliction state/shadow file
    EXISTS but cannot be read/parsed as a whole — as opposed to (a) simply
    not existing yet (a legitimate first run — stays empty), or (b) a single
    torn trailing JSONL line (stays tolerated, per-line skip). Per the
    close-duplicate PointerStateUnreadable precedent: collapsing "corrupt"
    into "empty" would silently reopen every conversation that source
    actually owns as a fresh candidate — risking a double-message to a
    customer a sibling sweeper is mid-workflow with. The caller MUST treat
    this as a hard, loud failure (exit 4), never as "no ownership"."""


def _read_json_file(path):
    if not os.path.exists(path):
        return {}
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        raise SiblingStateUnreadable(f"{path}: {type(e).__name__}: {e}") from e


def _read_jsonl_file(path):
    if not os.path.exists(path):
        return []
    try:
        with open(path) as f:
            lines = f.readlines()
    except OSError as e:
        raise SiblingStateUnreadable(f"{path}: {type(e).__name__}: {e}") from e
    # A trailing record is "demonstrably partial" (a write interrupted
    # mid-append) ONLY when the file does not end in a newline. A
    # newline-terminated final record is a COMPLETE line — if it fails to parse
    # the file is corrupt, not torn, so fail loud like any other malformed
    # record. A malformed record anywhere earlier, more than one malformed
    # record, or a newline-terminated malformed final record all mean the file
    # is corrupt as a whole: the ids of its records would silently drop out of
    # the ownership set and be re-surfaced to ops-drain (duplicate-action risk),
    # so raise exactly like a whole-file parse error (see SiblingStateUnreadable).
    ends_unterminated = bool(lines) and not lines[-1].endswith("\n")
    non_empty = [ln.strip() for ln in lines if ln.strip()]
    out = []
    for i, line in enumerate(non_empty):
        try:
            out.append(json.loads(line))
        except ValueError as e:
            if i == len(non_empty) - 1 and ends_unterminated:
                break  # a single torn (unterminated) trailing record — tolerated
            raise SiblingStateUnreadable(
                f"{path}: malformed JSONL record {i + 1}: {e}") from e
    return out


def _ids_from_source(path, kind, now_epoch=None):
    """Conversation ids owned by ONE sibling source. json = state dict keyed
    {"conv:<id>": ...}; jsonl = shadow log, one object per line carrying the
    conversation id under "id" / "conv_id" / "conversation_id" (ops-drain's
    own log uses conversation_id; close-resolved uses id; resolution-matcher
    uses conv_id — accept all three so id-only de-confliction stays robust);
    json-bare-keys = a state dict where EVERY top-level string key IS a
    conversation id (close-duplicate's pointer-posted.json — it marks a
    conversation owned regardless of its pending/posted status value);
    jsonl-ops-drain = ops-drain's OWN shadow log, where a "swept"/"classified"
    (survivor) record owns the conversation permanently but an "excluded"
    record owns it only until its recheck_after (see append_excluded_record)."""
    ids = set()
    if kind == "json":
        # A missing file reads as {} (legit first run); an existing file that
        # parses to the WRONG shape (a JSON array, null, number, string — e.g. a
        # mispointed or schema-corrupt sibling state) must FAIL CLOSED, not be
        # coalesced to an empty ownership set, or it would re-surface every
        # conversation that source owns (same rationale as SiblingStateUnreadable).
        state = _read_json_file(path)
        if not isinstance(state, dict):
            raise SiblingStateUnreadable(
                f"{path}: expected a JSON object, got {type(state).__name__}")
        for key in state:
            if isinstance(key, str) and key.startswith("conv:"):
                ids.add(key[len("conv:"):])
    elif kind == "json-bare-keys":
        state = _read_json_file(path)
        if not isinstance(state, dict):
            raise SiblingStateUnreadable(
                f"{path}: expected a JSON object, got {type(state).__name__}")
        for key in state:
            if isinstance(key, str):
                ids.add(key)
    elif kind == "jsonl":
        for rec in _read_jsonl_file(path):
            if not isinstance(rec, dict):
                continue
            cid = rec.get("id") or rec.get("conv_id") or rec.get("conversation_id")
            if cid:
                ids.add(str(cid))
    elif kind == "jsonl-ops-drain":
        eff_now = now_epoch if now_epoch is not None else int(time.time())
        for rec in _read_jsonl_file(path):
            if not isinstance(rec, dict):
                continue
            cid = rec.get("id") or rec.get("conv_id") or rec.get("conversation_id")
            if not cid:
                continue
            if rec.get("kind") == "excluded":
                # Owned only until recheck_after — then the conversation
                # re-surfaces for re-adjudication. A malformed/absent
                # recheck_after fails CLOSED (stays owned) rather than
                # re-surfacing an already-adjudicated row every run.
                recheck_after = rec.get("recheck_after")
                if not isinstance(recheck_after, (int, float)) or eff_now < recheck_after:
                    ids.add(str(cid))
            else:
                ids.add(str(cid))  # survivor/swept -> permanent
    return ids


def owned_ids_by_source(paths, now_epoch=None):
    """{source-name: set[conv_id]} owned by each sibling sweeper. De-conflicts
    by CONVERSATION ID ONLY, never contact email (see module docstring). A
    corrupt/unreadable source fails loud, naming the offending source (never
    silently treated as "no ownership"). now_epoch drives the recheck-window
    logic for ops-drain's own excluded records."""
    result = {}
    for name, (path, kind) in paths.items():
        try:
            result[name] = _ids_from_source(path, kind, now_epoch)
        except SiblingStateUnreadable as e:
            raise SiblingStateUnreadable(f"{name}: {e}") from e
    return result


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
        # close-duplicate's pointer-marker state — marks a conversation OPEN
        # and mid-workflow (a pointer comment pending or posted, close not
        # yet attempted). Bare top-level conv-id keys; the close-dup shadow
        # log above only ever sees already-CLOSED conversations, so this is
        # the only source that catches the mid-workflow window.
        "close-duplicate-pointer": (
            os.environ.get("CLOSE_DUP_POINTER_STATE",
                           "/var/lib/close-duplicate/pointer-posted.json"),
            "json-bare-keys"),
        # Forward-compat no-op — the dedup/close-merged path keys on profile
        # ids, not conversation id today (same known gap as cs-needs-human).
        "dedup-shadow": (
            os.environ.get("DEDUP_SHADOW_LOG", "/var/log/dedup-shadow.jsonl"),
            "jsonl"),
        # Ops-drain's OWN state + shadow log — idempotency: never re-surface a
        # conversation this machine already acted on / already swept, AND skip
        # a conversation it already ADJUDICATED as EXCLUDE until that exclude's
        # recheck window elapses (jsonl-ops-drain honors recheck_after), so
        # persistently-rejected leading rows can't starve later candidates.
        "ops-drain-state": (
            os.environ.get("OPS_DRAIN_STATE", "/var/lib/cs-ops-drain/acted.json"),
            "json"),
        "ops-drain-shadow": (
            os.environ.get("OPS_DRAIN_SHADOW_LOG", "/var/log/cs-ops-drain-shadow.jsonl"),
            "jsonl-ops-drain"),
    }


# --------------------------------------------------------------------------
# Pure candidate-building logic (no network — directly unit-testable).
# --------------------------------------------------------------------------
def waiting_since(c):
    """The moment we started owing this customer a reply: their last reply
    time, or — for a conversation they've never replied to (lcr == 0, e.g. an
    unanswered first message) — created_at. NEVER bare lcr (0) for that case
    (would misreport a brand-new conversation as waiting since the Unix epoch).
    Same rule as cs-needs-human-digest.waiting_since."""
    return c["lcr"] or c.get("created_at") or 0


def mask_email(email):
    """`a***@***` masking — never leak a full customer email."""
    if not email:
        return "no email"
    local = email.split("@", 1)[0]
    return f"{local[0]}***@***" if local else "***@***"


def clean_excerpt(source_body, max_len=EXCERPT_MAX):
    """First `max_len` chars of the customer's ask, PII-masked. Strips HTML
    tags, unescapes entities, collapses whitespace, then masks any email
    address in the free text (an excerpt can quote the customer's own or a
    third party's email) BEFORE truncating, so a masked token is never sliced
    mid-mask."""
    text = _TAG_RE.sub(" ", source_body or "")
    text = html.unescape(text)
    text = _EMAIL_RE.sub("[email]", text)
    text = _WS_RE.sub(" ", text).strip()
    return text[:max_len]


def _mark_if_owned(cid, owned_by_source, excluded_counts):
    """True iff `cid` is owned by ANY sibling source, incrementing
    excluded_counts under EVERY source that owns it (a conversation owned by
    several sources counts under each — the intent is a diagnostic breakdown
    of WHY things were dropped, not a partition)."""
    owned = False
    for name, ids in owned_by_source.items():
        if cid in ids:
            excluded_counts[name] += 1
            owned = True
    return owned


def _candidate_from_raw(c):
    """Build one candidate record from a raw fetched conversation dict
    (fields: id, email, lcr, created_at, source_body). "link" is included
    only when INTERCOM_WORKSPACE_ID is set (see intercom_link).

    `contact_email` is the REAL verified contact email, VERIFICATION-ONLY: the
    cs-ops-drain SKILL's identity gate (spec §Identity) must compare the
    resolution actor against the conversation's contact email and run
    `muso users search "<email>"` — a masked value can't drive either, so a
    masked-only record would force every candidate to EXCLUDE. It must NEVER
    reach a human-facing surface: the shadow log persists only masked_email,
    the Slack summary is tallies-only, and --append-record rejects a --reason
    carrying an email. Mirrors close-duplicate-conversations.py, which keeps
    the real email internally and masks only at the export/display boundary."""
    cand = {
        "conversation_id": c["id"],
        "contact_email": c["email"],
        "masked_email": mask_email(c["email"]),
        "created_at": c.get("created_at") or 0,
        "waiting_since": waiting_since(c),
        "excerpt": clean_excerpt(c.get("source_body", "")),
    }
    link = intercom_link(c["id"])
    if link:
        cand["link"] = link
    return cand


def build_candidates(convs, owned_by_source):
    """Return (candidates, excluded_counts). A conversation is a candidate iff
    its id is owned by NO sibling source. Pure/no-network — used directly by
    the self-test and unit tests; fetch_open_convs uses the same
    _mark_if_owned/_candidate_from_raw helpers inline, streaming, during
    pagination (see its docstring for why)."""
    excluded_counts = {name: 0 for name in owned_by_source}
    candidates = []
    for c in convs:
        cid = c["id"]
        if _mark_if_owned(cid, owned_by_source, excluded_counts):
            continue
        candidates.append(_candidate_from_raw(c))
    return candidates, excluded_counts


# --------------------------------------------------------------------------
# Shadow-log writes (the ONLY side effect; host-guarded). Matches the
# close-resolved shadow format: one JSON object per line, an epoch-seconds
# timestamp key (`swept_at`), the conversation id, and the masked email.
# --------------------------------------------------------------------------
def _open_shadow_log():
    path = os.environ.get("OPS_DRAIN_SHADOW_LOG", "/var/log/cs-ops-drain-shadow.jsonl")
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    return open(path, "a"), path


def append_sweep_records(candidates, now_epoch):
    """Append one swept-candidate record per candidate (idempotency + audit:
    the ops-drain's own shadow log is itself a de-confliction source on the
    next run). Returns the path written."""
    fh, path = _open_shadow_log()
    try:
        for c in candidates:
            fh.write(json.dumps({"conversation_id": c["conversation_id"],
                                 "swept_at": now_epoch,
                                 "masked_email": c["masked_email"],
                                 "kind": "swept"},
                                separators=(",", ":")) + "\n")
        fh.flush()
    finally:
        fh.close()
    return path


def append_classified_record(conversation_id, verb, reason, now_epoch):
    """Append ONE skill-classified candidate record {conversation_id, verb,
    reason, swept_at, kind:"classified"}. This is the helper the cs-ops-drain
    SKILL calls per survivor in DRY-RUN — it records the intended verb WITHOUT
    executing any write. Returns the path written."""
    fh, path = _open_shadow_log()
    try:
        fh.write(json.dumps({"conversation_id": conversation_id,
                             "verb": verb,
                             "reason": reason,
                             "swept_at": now_epoch,
                             "kind": "classified"},
                            separators=(",", ":")) + "\n")
        fh.flush()
    finally:
        fh.close()
    return path


def append_excluded_record(conversation_id, reason, now_epoch, recheck_days):
    """Append ONE EXCLUDE adjudication {conversation_id, kind:"excluded",
    swept_at, recheck_after, reason}. The SKILL calls this for every candidate
    it classifies as EXCLUDE, so a rejected leading conversation is de-conflicted
    on subsequent runs (owned until recheck_after) instead of re-occupying a
    --limit slot every run and starving later qualifying conversations. Unlike a
    survivor's record (permanent ownership), an exclude is owned only until
    recheck_after, then the conversation re-surfaces for re-adjudication (a
    transient EXCLUDE may qualify later). Returns the path written."""
    fh, path = _open_shadow_log()
    try:
        fh.write(json.dumps({"conversation_id": conversation_id,
                             "kind": "excluded",
                             "swept_at": now_epoch,
                             "recheck_after": now_epoch + recheck_days * 86400,
                             "reason": reason},
                            separators=(",", ":")) + "\n")
        fh.flush()
    finally:
        fh.close()
    return path


def _host_guard_ok():
    """Writes only happen on node-8 (the shadow log lives under /var/log there).
    Test override via OPS_DRAIN_SKIP_HOST_GUARD=1 / OPS_DRAIN_HOSTNAME_OVERRIDE."""
    if os.environ.get("OPS_DRAIN_SKIP_HOST_GUARD") == "1":
        return True
    hostname = os.environ.get("OPS_DRAIN_HOSTNAME_OVERRIDE") or socket.gethostname()
    return hostname == NODE8_HOST


# --------------------------------------------------------------------------
# Inline self-test: fail the run if the deterministic core is broken.
# --------------------------------------------------------------------------
def _self_test():
    # de-confliction: an owned id (from ANY source, by conversation id) is excluded.
    convs = [
        {"id": "C1", "email": "a@b.com", "lcr": 200, "created_at": 100, "source_body": "<p>hi</p>"},
        {"id": "C2", "email": "c@d.com", "lcr": 0, "created_at": 50, "source_body": ""},
        {"id": "C3", "email": "", "lcr": 0, "created_at": 0, "source_body": ""},
    ]
    owned = {"close-resolved": {"C1"}, "resolve-notify": set(), "ops-drain-shadow": set()}
    cands, excl = build_candidates(convs, owned)
    ids = [c["conversation_id"] for c in cands]
    assert ids == ["C2", "C3"], ids
    assert excl["close-resolved"] == 1, excl
    # candidate carries the REAL contact email (verification-only) alongside
    # the masked display value.
    assert cands[0]["contact_email"] == "c@d.com", cands
    assert cands[0]["masked_email"] == "c***@***", cands

    # KEY regression (spec §De-confliction): a conversation whose EMAIL matches
    # a sibling log but whose ID is NOT owned MUST still surface — de-conflict
    # is by conversation id only, never email.
    owned2 = {"close-resolved": set()}
    cands2, _ = build_candidates(convs, owned2)
    assert {c["conversation_id"] for c in cands2} == {"C1", "C2", "C3"}, cands2

    # waiting_since: never-replied (lcr==0) falls back to created_at, not 0.
    assert waiting_since({"id": "x", "lcr": 0, "created_at": 777}) == 777
    assert waiting_since({"id": "x", "lcr": 555, "created_at": 777}) == 555

    # a conversation owned by MULTIPLE sources counts under each in the diag.
    owned3 = {"close-resolved": {"C1"}, "resolve-notify": {"C1"}}
    _, excl3 = build_candidates(convs, owned3)
    assert excl3["close-resolved"] == 1 and excl3["resolve-notify"] == 1, excl3

    # excerpt: HTML stripped, entities unescaped, whitespace collapsed, email
    # MASKED, truncated to EXCERPT_MAX.
    ex = clean_excerpt("<div>Please merge <b>me@x.com</b>&nbsp;&amp; my  dup</div>")
    assert "me@x.com" not in ex and "[email]" in ex, ex
    assert "<" not in ex and "&amp;" not in ex, ex
    assert "&" in ex and "  " not in ex, ex
    assert len(clean_excerpt("z" * 500)) == EXCERPT_MAX

    # PII masking of the display email.
    assert mask_email("joe@example.com") == "j***@***"
    assert mask_email("") == "no email"

    # de-confliction reader: robust to id / conv_id / conversation_id keys and
    # never crashes on missing/corrupt files.
    assert _ids_from_source("/no/such/file.jsonl", "jsonl") == set()
    assert _ids_from_source("/no/such/file.json", "json") == set()

    # contact_email_of fast path (user-type author) — no network.
    assert contact_email_of(
        {"source": {"author": {"type": "user", "email": "U@X.com"}},
         "contacts": {"contacts": []}}, "tok") == "u@x.com"

    return True


# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="CS ops-drain candidate lister (read-only)")
    ap.add_argument("--limit", type=int, default=0,
                    help="cap the number of de-conflicted candidates returned "
                         "(de-confliction runs inline during pagination; "
                         "CS_OPS_DRAIN_SCAN_CAP separately bounds conversations scanned)")
    ap.add_argument("--shadow-log", action="store_true",
                    help="append one swept-candidate record per candidate (host-guarded)")
    ap.add_argument("--append-record", action="store_true",
                    help="append ONE skill-classified candidate record and exit (host-guarded)")
    ap.add_argument("--exclude", action="store_true",
                    help="with --append-record: record an EXCLUDE adjudication "
                         "(owned until recheck, then re-surfaces) instead of a verb")
    ap.add_argument("--conversation-id", default="")
    ap.add_argument("--verb", default="")
    ap.add_argument("--reason", default="")
    ap.add_argument("--self-test", action="store_true",
                    help="run the inline self-test and exit")
    args = ap.parse_args()

    try:
        _self_test()
    except AssertionError as e:
        print(f"cs-ops-drain-candidates: SELF-TEST FAILED: {e}", file=sys.stderr)
        return 2
    if args.self_test:
        print("self-test ok")
        return 0

    now_epoch = int(os.environ.get("OPS_DRAIN_NOW") or time.time())

    # --append-record: the per-candidate helper the SKILL calls in DRY-RUN. For
    # a SURVIVOR it records the classified verb; with --exclude it records an
    # EXCLUDE adjudication (so rejected rows don't re-surface until recheck).
    # Either way it writes ONLY the shadow log — no Intercom / muso-cli write.
    if args.append_record:
        if not args.conversation_id or not args.reason:
            print("cs-ops-drain-candidates: --append-record needs "
                  "--conversation-id and --reason", file=sys.stderr)
            return 1
        if not args.exclude and args.verb not in ALLOWED_VERBS:
            print(f"cs-ops-drain-candidates: --verb must be one of "
                  f"{', '.join(ALLOWED_VERBS)} (got '{args.verb}') — or pass "
                  "--exclude to record an EXCLUDE adjudication", file=sys.stderr)
            return 1
        if _EMAIL_RE.search(args.reason):
            print("cs-ops-drain-candidates: --reason must not contain a raw email "
                  "address (PII in a persisted log/summary source) — reference the "
                  "conversation by id; contact_email is verification-only", file=sys.stderr)
            return 1
        if not _host_guard_ok():
            print(f"cs-ops-drain-candidates: not on {NODE8_HOST} — refusing shadow-log "
                  "write (set OPS_DRAIN_SKIP_HOST_GUARD=1 to override)", file=sys.stderr)
            return 1
        if args.exclude:
            try:
                recheck_days = int(os.environ.get("CS_OPS_DRAIN_EXCLUDE_RECHECK_DAYS")
                                   or DEFAULT_EXCLUDE_RECHECK_DAYS)
            except ValueError:
                print("cs-ops-drain-candidates: CS_OPS_DRAIN_EXCLUDE_RECHECK_DAYS "
                      "must be an integer", file=sys.stderr)
                return 1
            path = append_excluded_record(args.conversation_id, args.reason, now_epoch,
                                          recheck_days)
            print(json.dumps({"appended": True, "conversation_id": args.conversation_id,
                              "kind": "excluded",
                              "recheck_after": now_epoch + recheck_days * 86400,
                              "shadow_log": path}))
            return 0
        path = append_classified_record(args.conversation_id, args.verb, args.reason, now_epoch)
        print(json.dumps({"appended": True, "conversation_id": args.conversation_id,
                          "verb": args.verb, "shadow_log": path}))
        return 0

    token = os.environ.get("MUSOAI_INTERCOM_TOKEN")
    if not token:
        print("cs-ops-drain-candidates: MUSOAI_INTERCOM_TOKEN is required", file=sys.stderr)
        return 1

    try:
        scan_cap = int(os.environ.get("CS_OPS_DRAIN_SCAN_CAP") or DEFAULT_SCAN_CAP)
    except ValueError:
        print("cs-ops-drain-candidates: CS_OPS_DRAIN_SCAN_CAP must be an integer",
              file=sys.stderr)
        return 1

    try:
        owned_by_source = owned_ids_by_source(default_state_paths(), now_epoch)
    except SiblingStateUnreadable as e:
        print(f"cs-ops-drain-candidates: sibling sweeper de-confliction state "
              f"unreadable/corrupt — refusing to run: {e}", file=sys.stderr)
        return 4

    try:
        candidates, excluded_counts, scanned, scan_cap_hit = fetch_open_convs(
            token, owned_by_source, args.limit, scan_cap)
    except IntercomAPIFailed as e:
        print(f"cs-ops-drain-candidates: Intercom API failed systematically: {e}",
              file=sys.stderr)
        return 3

    if args.shadow_log:
        if not _host_guard_ok():
            print(f"cs-ops-drain-candidates: not on {NODE8_HOST} — refusing shadow-log "
                  "write (set OPS_DRAIN_SKIP_HOST_GUARD=1 to override)", file=sys.stderr)
            return 1
        append_sweep_records(candidates, now_epoch)

    print(json.dumps({
        "candidates": candidates,
        "excluded_counts": excluded_counts,
        "scanned": scanned,
        "candidate_count": len(candidates),
        "scan_cap_hit": scan_cap_hit,
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
