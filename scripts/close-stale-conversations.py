#!/usr/bin/env python3
"""Silently close STALE Intercom conversations the customer walked away from.

Drains the backlog the 2026-07 CS digest surfaced (needs-customer-input ~2800,
oldest waiting 115d): conversations where WE replied last and the customer
never came back. close-resolved-conversations.py only closes conversations
tied to a resolved ClickUp ticket, so a conversation whose customer simply
went silent after our answer stays open forever — this closer is the
staleness axis. HUMAN-RUN ONLY: no systemd timer, no cron; each run is a
supervised drain step (dry-run -> review export -> ramped --apply).

SAFETY — a conversation is closed ONLY when ALL of:
  - it is INBOUND (customer-initiated); outbound/admin-initiated threads are
    a different lifecycle and are left alone, AND
  - WE spoke last: last_admin_reply_at > 0 AND strictly >
    last_contact_reply_at. This excludes `customer_last` (customer waiting on
    us) and `never_replied` (a chat that never got an answer — possibly a
    dropped customer). Intercom timestamps are second-granular, so lar == lcr
    is ambiguous, not proven admin-last — excluded too. We never silently
    bury a conversation that still needs a human, AND
  - the customer has been silent for MORE than STALE_DAYS (default 30) since
    OUR last reply. Keyed to last_admin_reply_at on purpose: a fresh admin
    reply on an ancient thread restarts the clock (the customer has only had
    days, not months, to respond), AND
  - no sibling sweeper owns the conversation id (close-resolved,
    resolve-notify, resolution-matcher, overdue-verification-notifier,
    close-duplicate incl. its mid-workflow pointer state, ops-drain, dedup) —
    by CONVERSATION ID ONLY, never email (see docs/plans/cs-ops-drain-spec.md
    §De-confliction: email-matching an append-only log would permanently hide
    a returning customer). Unlike the read-only digest, a CLOSER fails the
    whole run CLOSED (exit 4) on a corrupt/unreadable sibling source — a
    damaged ownership set must never re-surface a mid-workflow conversation
    as closable. Its own shadow log is also a source (idempotency).

Downstream, this closer's shadow log is read as an exclusion source by
cs-ops-drain-candidates.py and close-duplicate-conversations.py (over-
exclusion is their safe direction) but deliberately NOT by the needs-human
digest — a conversation the customer REOPENS after our silent close must
surface there (see the digest's default_state_paths note).

The close is SILENT (no customer-facing message part), so it generates no new
inbound. Immediately before EACH close the whole gate is re-checked LIVE:
the conversation is re-fetched (still_eligible_live — the scan snapshot may
be minutes old by the time a ramped drain reaches a target, and a customer
reply in that window must veto the close, since it would never reopen an
already-closed conversation) AND sibling ownership is re-read from the local
state files (a sweeper can claim the id mid-drain; corrupt state mid-drain
stops the remaining drain, fail closed).

Shadow log contract (one JSON object per line, key "id"): an fsync'd
{"kind":"attempt"} row is written BEFORE the mutation — "can't record" means
"don't close", and an ambiguous outcome always leaves a trace — then a
{"kind":"closed"} (id, timestamp, email — reversible) or {"kind":"close_failed"}
outcome row after. Our own idempotency reader honors only "closed" rows
(attempts/failures re-surface and are safe to retry thanks to the live
re-verify); sibling consumers read the log as plain jsonl and own every row —
over-exclusion, their safe direction. On --apply an unopenable shadow log is a
HARD STOP before any close (close-duplicate precedent — an unrecordable close
is untraceable); the handle itself is opened O_NOFOLLOW/0600 with an
owned-regular-file check (raw-PII surface).

Sanity ceiling: on --apply, MORE than the ceiling (STALE_CEILING 200, or
--ceiling N) of eligible candidates closes NOTHING and exits 2 — a backlog
larger than expected is reviewed, never blind-drained. The ceiling gates
--apply only; dry-run always reports the full picture and writes the masked
review export (CLOSE_STALE_REVIEW_DIR/candidates-<date>.json, 0600 —
mask_email only, never a raw address) for the supervised-drain review.

Env:
  MUSOAI_INTERCOM_TOKEN     required
  INTERCOM_ADMIN_ID         optional, default 5763097 (operations@muso.ai)
  STALE_DAYS                optional, default 30; must be a positive integer
                            (0 would make every we-spoke-last conversation
                            eligible the moment we reply — refused loudly)
  CLOSE_STALE_SHADOW_LOG    optional, default /var/log/close-stale-shadow.jsonl
                            (NO /tmp fallback — carries raw customer emails;
                            unwritable = hard stop before any close)
  CLOSE_STALE_REVIEW_DIR    optional, default /var/lib/close-stale-conversations/
  CLOSE_STALE_SUMMARY_CHANNEL / CLOSE_STALE_SLACK_ACCOUNT / SLACK_NOTIFY_CONFIG
                            optional — see --notify (defaults: #cs_chats,
                            operations bot, /root/.openclaw-main/openclaw.json)
  + every sibling source path env honored by cs-ops-drain-candidates.py
    (CLOSE_SHADOW_LOG, RESOLVE_NOTIFY_STATE, RESOLUTION_STATE_PATH,
    RESOLUTION_SHADOW_LOG, OVERDUE_NOTIFY_STATE, CLOSE_DUP_SHADOW_LOG,
    CLOSE_DUP_POINTER_STATE, DEDUP_SHADOW_LOG, OPS_DRAIN_STATE,
    OPS_DRAIN_SHADOW_LOG)

Flags:
  --apply       actually close (default: dry-run — list + review export only)
  --limit N     cap the number closed this run (ramp: 25 -> 100 -> 500)
  --ceiling N   override STALE_CEILING for this run's --apply hard-stop
                (the supervised full-drain lever; dry-run ignores it)
  --notify      after an --apply run that closed >=1, post a masked summary
                to #cs_chats as the operations Slack bot

Exit codes: 0 ok; 1 usage/env/shadow-log error, or a dry-run whose review
export failed both write attempts (the export IS the review surface); 2
--apply refused (candidates over ceiling — nothing closed); 3 at least one
close failed; 4 a sibling sweeper's de-confliction state is unreadable — at
startup nothing is closed; mid-drain (the per-close ownership refresh) the
REMAINING drain stops, closes already made keep their shadow records.
"""
import argparse
import http.client
import json
import os
import stat
import sys
import time
import urllib.error
import urllib.request

INTERCOM_API = "https://api.intercom.io"
INTERCOM_VERSION = "2.11"
DEFAULT_STALE_DAYS = 30
STALE_CEILING = 200
DEFAULT_REVIEW_DIR = "/var/lib/close-stale-conversations/"
# Fallback dir when DEFAULT_REVIEW_DIR is unwritable — a private (0700)
# directory, never bare /tmp (the export names conversation ids; emails are
# masked, but the surface stays private like close-duplicate's).
FALLBACK_REVIEW_DIR = "/tmp/close-stale-review"
CUSTOMER_AUTHOR_TYPES = {"user", "lead", "contact"}
SLACK_API = "https://slack.com/api/chat.postMessage"
DEFAULT_SUMMARY_CHANNEL = "C0ANM0PN9L5"  # #cs_chats
SUMMARY_MAX_LINES = 25
DRY_RUN_PREVIEW = 15


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


def is_inbound_conv(c):
    """Customer-initiated? Same rule as cs-needs-human-digest.is_inbound_conv:
    source.delivered_as when present, else the source author type."""
    src = c.get("source") or {}
    delivered_as = src.get("delivered_as")
    if delivered_as:
        return delivered_as == "customer_initiated"
    au = src.get("author") or {}
    return au.get("type") in CUSTOMER_AUTHOR_TYPES


def fetch_open_convs(token):
    """List OPEN Intercom conversations (read-only). Mirrors
    close-resolved-conversations.fetch_open_convs' pagination; the email is
    the source author's (display/shadow-log only — no per-conversation
    contact GET, this closer never gates on email)."""
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
                "email": (au.get("email") or "").lower().strip()
                         if au.get("type") in CUSTOMER_AUTHOR_TYPES else "",
                "lar": stats.get("last_admin_reply_at") or 0,
                "lcr": stats.get("last_contact_reply_at") or 0,
                "created_at": c.get("created_at") or 0,
                "is_inbound": is_inbound_conv(c),
            })
        nxt = (data.get("pages") or {}).get("next")
        after = nxt.get("starting_after") if isinstance(nxt, dict) else None
        if not nxt or not after:
            break
    return convs


# --------------------------------------------------------------------------
# De-confliction: read every sibling sweeper's state. A missing file means
# "no ownership" (legit first run); an EXISTING but unreadable/corrupt file
# fails the run CLOSED — this module CLOSES conversations, so a damaged
# ownership set must never be coalesced to "nothing owned". Mirrors
# cs-ops-drain-candidates.py's fail-closed reader (not the digest's lenient
# one — the digest is read-only, this is not).
# --------------------------------------------------------------------------
class SiblingStateUnreadable(Exception):
    """A sibling sweeper's de-confliction state/shadow file EXISTS but cannot
    be read/parsed. The caller MUST treat this as a hard, loud failure
    (exit 4), never as "no ownership" — see cs-ops-drain-candidates.py."""


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
    # Same torn-tail tolerance as cs-ops-drain-candidates._read_jsonl_file: a
    # single unterminated trailing record is a write interrupted mid-append;
    # any other malformed record means the file is corrupt as a whole.
    ends_unterminated = bool(lines) and not lines[-1].endswith("\n")
    non_empty = [ln.strip() for ln in lines if ln.strip()]
    out = []
    for i, line in enumerate(non_empty):
        try:
            out.append(json.loads(line))
        except ValueError as e:
            if i == len(non_empty) - 1 and ends_unterminated:
                break
            raise SiblingStateUnreadable(
                f"{path}: malformed JSONL record {i + 1}: {e}") from e
    return out


def _ids_from_source(path, kind):
    """Conversation ids owned by ONE sibling source. Kinds as in
    cs-ops-drain-candidates.py, minus its recheck-window variant: ops-drain's
    own shadow log is read as plain "jsonl" here, i.e. even an ops-drain
    EXCLUDED record keeps the conversation off-limits to this closer forever.
    Deliberately conservative — the cost is an over-exclusion (an open
    conversation, never a wrong close), and re-adjudicating ops-drain's
    excludes is ops-drain's job, not the stale-closer's."""
    ids = set()
    if kind == "json":
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
    elif kind == "jsonl-closed-only":
        # Our OWN shadow log: only a "closed" outcome row owns the
        # conversation (a missing kind reads as closed for backward/robust
        # parsing). "attempt"/"close_failed" rows stay retryable — the
        # pre-close live re-verify makes a retry of an ambiguous close safe
        # (an already-closed conversation is skipped, never re-mutated).
        # Sibling consumers read this log as plain "jsonl" and so own even
        # attempt rows — over-exclusion, their safe direction.
        for rec in _read_jsonl_file(path):
            if not isinstance(rec, dict):
                continue
            if rec.get("kind", "closed") != "closed":
                continue
            cid = rec.get("id") or rec.get("conv_id") or rec.get("conversation_id")
            if cid:
                ids.add(str(cid))
    else:
        # Fail CLOSED on an unknown kind: silently returning an empty set
        # would zero that source's ownership (e.g. a future copy-paste of
        # ops-drain's "jsonl-ops-drain" kind) and re-surface mid-workflow
        # conversations as closable.
        raise SiblingStateUnreadable(f"{path}: unknown source kind {kind!r}")
    return ids


def owned_ids_by_source(paths):
    """{source-name: set[conv_id]} owned by each sibling sweeper. De-conflicts
    by CONVERSATION ID ONLY, never contact email. A corrupt/unreadable source
    fails loud, naming the offending source."""
    result = {}
    for name, (path, kind) in paths.items():
        try:
            result[name] = _ids_from_source(path, kind)
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
        # close-duplicate's mid-workflow pointer marker (pointer posted/pending,
        # close not yet attempted) — bare top-level conv-id keys.
        "close-duplicate-pointer": (
            os.environ.get("CLOSE_DUP_POINTER_STATE",
                           "/var/lib/close-duplicate/pointer-posted.json"),
            "json-bare-keys"),
        # Forward-compat no-op — dedup keys on profile ids today.
        "dedup-shadow": (
            os.environ.get("DEDUP_SHADOW_LOG", "/var/log/dedup-shadow.jsonl"),
            "jsonl"),
        "ops-drain-state": (
            os.environ.get("OPS_DRAIN_STATE", "/var/lib/cs-ops-drain/acted.json"),
            "json"),
        "ops-drain-shadow": (
            os.environ.get("OPS_DRAIN_SHADOW_LOG", "/var/log/cs-ops-drain-shadow.jsonl"),
            "jsonl"),
        # Our OWN shadow log — idempotency across re-runs ("closed" rows
        # only; attempts/failures re-surface for a safe retry).
        "close-stale": (
            os.environ.get("CLOSE_STALE_SHADOW_LOG", "/var/log/close-stale-shadow.jsonl"),
            "jsonl-closed-only"),
    }


# --------------------------------------------------------------------------
# Pure eligibility logic (no network — directly unit-testable).
# --------------------------------------------------------------------------
def is_eligible(conv, owned_id_set, now_epoch, stale_secs):
    """Eligible to close iff inbound AND we spoke last AND the customer has
    been silent STRICTLY longer than stale_secs since our last reply AND no
    sibling sweeper owns the conversation id. See the module docstring for
    the rationale behind each gate."""
    if not conv.get("is_inbound"):
        return False
    lar, lcr = conv["lar"], conv["lcr"]
    # Strictly admin-last; lar == lcr is second-granular ambiguity, lar == 0
    # is never_replied. Same predicate as close-resolved-conversations.py.
    if not (lar > 0 and lar > lcr):
        return False
    # Strictly stale: silence measured from OUR last reply, so a recent admin
    # reply on an old thread restarts the customer's response window.
    if now_epoch - lar <= stale_secs:
        return False
    return conv["id"] not in owned_id_set


def customer_silent_days(conv, now_epoch):
    return (now_epoch - conv["lar"]) // 86400


def mask_email(email):
    """`a***@***` masking — never leak a full customer email. Same rule as
    cs-needs-human-digest / cs-ops-drain-candidates mask_email."""
    if not email:
        return "no email"
    local = email.split("@", 1)[0]
    return f"{local[0]}***@***" if local else "***@***"


# --------------------------------------------------------------------------
# Review export (dry-run surface for the supervised drain) — mirrors
# close-duplicate-conversations.write_review_export, but with emails masked
# in-file (this export lists potentially thousands of rows and only needs to
# support a spot-check, not an identity-level review like dup pairs do).
# --------------------------------------------------------------------------
def _review_export_candidate(c, now_epoch):
    return {
        "conversation_id": c["id"],
        "email": mask_email(c["email"]),
        "created_at": c["created_at"],
        "last_admin_reply_at": c["lar"],
        "last_contact_reply_at": c["lcr"],
        "customer_silent_days": customer_silent_days(c, now_epoch),
    }


def _safe_fallback_dir():
    """Prepare FALLBACK_REVIEW_DIR as a private (0700, owned-by-us,
    non-symlink) directory — same checks as close-duplicate's."""
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


def write_review_export(candidates, when_date, stale_days, now_epoch):
    """Write the full dry-run candidate list to
    CLOSE_STALE_REVIEW_DIR/candidates-<when_date>.json (0600), falling back
    to a private dir with a loud stderr — this is the supervised-drain review
    surface, so a silently-lost export is unacceptable. Returns the path
    written, or None if both attempts failed."""
    doc = {
        "generated_at": now_epoch,
        "stale_days": stale_days,
        "total": len(candidates),
        "candidates": [_review_export_candidate(c, now_epoch) for c in candidates],
    }
    filename = f"candidates-{when_date}.json"
    primary_dir = os.environ.get("CLOSE_STALE_REVIEW_DIR", DEFAULT_REVIEW_DIR)
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


# --------------------------------------------------------------------------
# The close itself + shadow log.
# --------------------------------------------------------------------------
def get_conversation(token, conv_id):
    """Fresh GET of one conversation — the pre-close TOCTOU guard's source."""
    req = urllib.request.Request(
        f"{INTERCOM_API}/conversations/{conv_id}",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                 "Intercom-Version": INTERCOM_VERSION})
    return _retry_json(req)


def still_eligible_live(fresh, owned_id_set, now_epoch, stale_secs):
    """Pre-close re-verify on a FRESH GET /conversations/{id} payload. The
    scan snapshot can be minutes old by the time a ramped drain reaches a
    target; a customer reply in that window (before the close) would never
    reopen the conversation, so closing on the stale snapshot would bury a
    now-waiting customer. Re-checks open + the full is_eligible gate on
    live statistics; any doubt = skip (the next run re-evaluates)."""
    if fresh.get("state") != "open":
        return False
    stats = fresh.get("statistics") or {}
    return is_eligible({
        "id": fresh.get("id"),
        "lar": stats.get("last_admin_reply_at") or 0,
        "lcr": stats.get("last_contact_reply_at") or 0,
        "created_at": fresh.get("created_at") or 0,
        "is_inbound": is_inbound_conv(fresh),
    }, owned_id_set, now_epoch, stale_secs)


def close_conversation(token, admin_id, conv_id):
    req = urllib.request.Request(
        f"{INTERCOM_API}/conversations/{conv_id}/parts",
        data=json.dumps({"message_type": "close", "type": "admin",
                         "admin_id": str(admin_id)}).encode(),
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                 "Content-Type": "application/json", "Intercom-Version": INTERCOM_VERSION},
        method="POST")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def open_shadow_log():
    """Hardened append handle for the raw-PII shadow log; (None, None) on any
    doubt — main() hard-stops before any close.

    NO /tmp fallback, unlike close-resolved's: the log carries RAW customer
    emails and runs as root, so appending through a predictable world-writable
    /tmp path is a symlink-follow + PII-exposure hazard (close-duplicate
    already flags that fallback as a known weakness). This closer is HUMAN-RUN
    — the supervisor fixes /var/log perms and re-runs.

    A bare open(path, "a") would create the file umask-permissive (0644 as
    root), leave an existing permissive file permissive, and follow a
    pre-planted symlink — so: O_NOFOLLOW + 0600 create mode, then fstat
    re-verify (regular file, owned by us) and fchmod any pre-existing
    permissive file down to 0600."""
    path = os.environ.get("CLOSE_STALE_SHADOW_LOG", "/var/log/close-stale-shadow.jsonl")
    try:
        fd = os.open(path,
                     os.O_WRONLY | os.O_APPEND | os.O_CREAT
                     | getattr(os, "O_NOFOLLOW", 0), 0o600)
    except OSError:
        return None, None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():
            os.close(fd)
            print(f"ERROR: shadow log {path} is not a regular file owned by "
                  "us — refusing", file=sys.stderr)
            return None, None
        if stat.S_IMODE(st.st_mode) != 0o600:
            os.fchmod(fd, 0o600)
        return os.fdopen(fd, "a"), path
    except OSError:
        os.close(fd)
        return None, None


# --------------------------------------------------------------------------
# Optional #cs_chats summary (masked; best-effort, never fails the run).
# --------------------------------------------------------------------------
def _slack_escape(s):
    """Escape for Slack mrkdwn — & < > in that order (same as close-resolved's).
    A masked email carries one customer-controlled char (the local part's
    first), which must never render as a raw entity/tag opener."""
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def format_slack_summary(closed, when, stale_days, shadow_path=None,
                         max_lines=SUMMARY_MAX_LINES):
    n = len(closed)
    plural = "" if n == 1 else "s"
    lines = [f":broom: *Closed {n} stale conversation{plural}* "
             f"(we replied last, customer silent >{stale_days}d) — {when}"]
    for c in closed[:max_lines]:
        lines.append(f"• conversation {c['id']} — {_slack_escape(mask_email(c['email']))} — "
                     f"silent {c['silent_days']}d")
    if n > max_lines:
        lines.append(f"…and {n - max_lines} more")
    if shadow_path:
        lines.append(f"_Reversible — full log: {shadow_path}_")
    return "\n".join(lines)


def _read_slack_token(config_path, account):
    try:
        with open(config_path) as f:
            cfg = json.load(f)
        return cfg["channels"]["slack"]["accounts"][account]["botToken"]
    except (OSError, KeyError, ValueError, TypeError):
        return None


def post_slack_summary(text, channel, config_path, account):
    """Best-effort post to Slack. NEVER raises — the closes already happened
    and are shadow-logged, so a Slack failure must not fail the run."""
    token = _read_slack_token(config_path, account)
    if not token:
        print(f"WARN: no Slack token for account '{account}' in {config_path}; "
              "notify skipped", file=sys.stderr)
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
    except Exception as e:  # noqa: BLE001 — best-effort by contract
        print(f"WARN: Slack post error: {type(e).__name__}: {str(e)[:140]}",
              file=sys.stderr)
        return False


def _stale_days_from_env():
    """Positive-int STALE_DAYS or None (caller fails loud). 0/negative is
    refused: STALE_DAYS=0 would make every we-spoke-last conversation
    eligible the moment we reply."""
    raw = os.environ.get("STALE_DAYS", str(DEFAULT_STALE_DAYS))
    try:
        days = int(raw, 10)
    except ValueError:
        return None
    return days if days > 0 else None


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Silently close stale we-spoke-last conversations (human-run drain)")
    ap.add_argument("--apply", action="store_true",
                    help="actually close (default: dry-run + review export)")
    ap.add_argument("--limit", type=int, default=0,
                    help="cap closes this run (0 = no cap; ramp 25 -> 100 -> 500)")
    ap.add_argument("--ceiling", type=int, default=STALE_CEILING,
                    help="override the --apply hard-stop on the candidate count "
                         f"(default {STALE_CEILING})")
    ap.add_argument("--notify", action="store_true",
                    help="post a masked #cs_chats summary after an --apply run "
                         "that closed >=1")
    args = ap.parse_args(argv)
    if args.limit < 0:
        # Fail loud: eligible[:negative] would silently mean "close everything
        # but the tail" — a ramp typo like --limit -25 must never widen a run.
        print(f"ERROR: --limit must be >= 0, got {args.limit}", file=sys.stderr)
        return 1

    token = os.environ.get("MUSOAI_INTERCOM_TOKEN")
    if not token:
        print("ERROR: MUSOAI_INTERCOM_TOKEN is required", file=sys.stderr)
        return 1
    stale_days = _stale_days_from_env()
    if stale_days is None:
        print(f"ERROR: STALE_DAYS must be a positive integer, got "
              f"{os.environ.get('STALE_DAYS')!r}", file=sys.stderr)
        return 1
    admin_id = os.environ.get("INTERCOM_ADMIN_ID", "5763097")
    stale_secs = stale_days * 86400
    now = int(time.time())

    try:
        owned_by_source = owned_ids_by_source(default_state_paths())
    except SiblingStateUnreadable as e:
        print(f"ERROR: sibling sweeper state unreadable — refusing to close "
              f"anything: {e}", file=sys.stderr)
        return 4
    owned = set().union(*owned_by_source.values()) if owned_by_source else set()

    convs = fetch_open_convs(token)
    eligible = [c for c in convs if is_eligible(c, owned, now, stale_secs)]
    eligible.sort(key=lambda c: c["lar"])  # oldest silence first

    owned_counts = {name: len(ids) for name, ids in owned_by_source.items()}
    print(f"stale threshold: customer silent > {stale_days}d after our last reply")
    print(f"open conversations scanned: {len(convs)}")
    print(f"owned by sibling sweepers: {owned_counts}")
    print(f"eligible (inbound, we spoke last, stale, unowned): {len(eligible)}")

    if not args.apply:
        for c in eligible[:DRY_RUN_PREVIEW]:
            print(f"  would close conv={c['id']} email={mask_email(c['email'])} "
                  f"silent={customer_silent_days(c, now)}d")
        if len(eligible) > DRY_RUN_PREVIEW:
            print(f"  ... and {len(eligible) - DRY_RUN_PREVIEW} more")
        review_path = write_review_export(
            eligible, time.strftime("%Y-%m-%d", time.gmtime(now)), stale_days, now)
        print(f"review export: {review_path or 'FAILED (see stderr)'}")
        print("DRY-RUN — no conversations closed. Re-run with --apply to close.")
        # A lost export is a failed dry-run: it is the supervised-drain review
        # surface, and exit 0 would let a wrapper proceed to --apply without it.
        return 0 if review_path or not eligible else 1

    if len(eligible) > args.ceiling:
        print(f"REFUSING --apply: {len(eligible)} candidates exceed the ceiling "
              f"({args.ceiling}). Review the dry-run export, then re-run with "
              f"an explicit --ceiling for a supervised drain.", file=sys.stderr)
        return 2

    targets = eligible[:args.limit] if args.limit > 0 else eligible
    shadow, shadow_path = open_shadow_log()
    if shadow is None:
        print("ERROR: cannot open the shadow log anywhere — refusing to close "
              "(a close without a shadow record is untraceable)", file=sys.stderr)
        return 1
    # Transport catch below: urllib wraps h.request() errors in URLError but
    # lets getresponse()/body-read failures (RemoteDisconnected ⊂
    # ConnectionResetError ⊂ OSError, socket timeouts, IncompleteRead ⊂
    # http.client.HTTPException) escape raw — one mid-drain blip must land in
    # `fail`, not crash the run (URLError ⊂ OSError).
    transport_errors = (OSError, ValueError, http.client.HTTPException)
    closed, fail = [], []
    skipped_recheck = 0
    abort_reason = None
    for c in targets:
        silent_days = customer_silent_days(c, now)
        # TOCTOU guard: re-fetch and re-verify LIVE immediately before the
        # mutation — the scan snapshot may be minutes old and a customer
        # reply in that window must veto the close (see still_eligible_live).
        try:
            fresh = get_conversation(token, c["id"])
        except transport_errors as e:
            fail.append((c["id"], f"recheck: {type(e).__name__}: {str(e)[:140]}"))
            time.sleep(0.3)
            continue
        # Sibling OWNERSHIP is part of the live gate too: a sibling sweeper
        # (close-resolved's 6h timer, resolve-notify, ...) can claim this id
        # after our scan, so re-read the local state files before every
        # mutation. Corrupt sibling state mid-drain stops the REMAINING
        # drain (fail closed) — the closes already made keep their records.
        try:
            live_owned = set().union(
                *owned_ids_by_source(default_state_paths()).values())
        except SiblingStateUnreadable as e:
            abort_reason = str(e)
            break
        if not still_eligible_live(fresh, live_owned, now, stale_secs):
            skipped_recheck += 1
            time.sleep(0.3)
            continue
        # Intent record BEFORE the mutation, fsync'd: "can't record" must
        # mean "don't close" (a write failure here crashes with zero closes
        # outstanding), and an ambiguous close outcome (applied remotely but
        # the response read failed) always leaves at least the attempt row.
        shadow.write(json.dumps({
            "id": c["id"], "kind": "attempt",
            "attempted_at": int(time.time())}) + "\n")
        shadow.flush()
        os.fsync(shadow.fileno())
        try:
            res = close_conversation(token, admin_id, c["id"])
        except transport_errors as e:
            fail.append((c["id"], f"{type(e).__name__}: {str(e)[:140]}"))
            # Outcome row for the failure too; if THIS write fails the run
            # crashes loudly — the attempt row above already preserves the
            # audit trail. Non-"closed" rows are retryable by our own
            # idempotency reader (the live re-verify makes retrying an
            # ambiguous close safe: an already-closed conversation is
            # skipped, never re-mutated).
            shadow.write(json.dumps({
                "id": c["id"], "kind": "close_failed",
                "failed_at": int(time.time()),
                "error": f"{type(e).__name__}: {str(e)[:140]}"}) + "\n")
            shadow.flush()
            time.sleep(0.3)
            continue
        shadow.write(json.dumps({
            "id": c["id"], "kind": "closed", "closed_at": int(time.time()),
            "email": c["email"],
            "silent_days": silent_days,
            "new_state": res.get("state")}) + "\n")
        shadow.flush()
        closed.append({**c, "silent_days": silent_days})
        time.sleep(0.3)
    shadow.close()
    ok = len(closed)
    print(f"closed_ok={ok} failed={len(fail)} "
          f"skipped_live_recheck={skipped_recheck} (shadow log: {shadow_path})")
    for f in fail[:15]:
        print(f"  FAIL {f}", file=sys.stderr)
    if abort_reason:
        print(f"ERROR: sibling sweeper state unreadable mid-drain — stopped "
              f"the remaining drain: {abort_reason}", file=sys.stderr)
        return 4

    if args.notify and ok > 0:
        when = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime())
        text = format_slack_summary(closed, when, stale_days, shadow_path)
        channel = os.environ.get("CLOSE_STALE_SUMMARY_CHANNEL", DEFAULT_SUMMARY_CHANNEL)
        cfg = os.environ.get("SLACK_NOTIFY_CONFIG", "/root/.openclaw-main/openclaw.json")
        account = os.environ.get("CLOSE_STALE_SLACK_ACCOUNT", "operations")
        posted = post_slack_summary(text, channel, cfg, account)
        print(f"slack notify: {'posted' if posted else 'skipped/failed'} -> {channel}")

    return 3 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
