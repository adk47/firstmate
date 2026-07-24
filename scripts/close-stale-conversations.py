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

The close is SILENT (no customer-facing message part), so it generates no new
inbound. Every close is appended to a shadow log (id, timestamp, email) so it
can be reversed; on --apply an unopenable shadow log is a HARD STOP before
any close (close-duplicate precedent — an unrecordable close is untraceable).

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
                            (falls back to /tmp if that path is not writable)
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

Exit codes: 0 ok; 1 usage/env/shadow-log error; 2 --apply refused (candidates
over ceiling — nothing closed); 3 at least one close failed; 4 a sibling
sweeper's de-confliction state is unreadable (nothing closed).
"""
import argparse
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
        # Our OWN shadow log — idempotency across re-runs.
        "close-stale": (
            os.environ.get("CLOSE_STALE_SHADOW_LOG", "/var/log/close-stale-shadow.jsonl"),
            "jsonl"),
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
    path = os.environ.get("CLOSE_STALE_SHADOW_LOG", "/var/log/close-stale-shadow.jsonl")
    try:
        return open(path, "a"), path
    except OSError:
        fallback = "/tmp/close-stale-shadow.jsonl"
        try:
            return open(fallback, "a"), fallback
        except OSError:
            return None, None


# --------------------------------------------------------------------------
# Optional #cs_chats summary (masked; best-effort, never fails the run).
# --------------------------------------------------------------------------
def format_slack_summary(closed, when, stale_days, shadow_path=None,
                         max_lines=SUMMARY_MAX_LINES):
    n = len(closed)
    plural = "" if n == 1 else "s"
    lines = [f":broom: *Closed {n} stale conversation{plural}* "
             f"(we replied last, customer silent >{stale_days}d) — {when}"]
    for c in closed[:max_lines]:
        lines.append(f"• conversation {c['id']} — {mask_email(c['email'])} — "
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

    print(f"stale threshold: customer silent > {stale_days}d after our last reply")
    print(f"open conversations scanned: {len(convs)}")
    print(f"owned by sibling sweepers: "
          f"{ {name: len(ids) for name, ids in owned_by_source.items()} }")
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
        return 0

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
    closed, fail = [], []
    for c in targets:
        try:
            res = close_conversation(token, admin_id, c["id"])
            shadow.write(json.dumps({
                "id": c["id"], "closed_at": int(time.time()),
                "email": c["email"],
                "silent_days": customer_silent_days(c, now),
                "new_state": res.get("state")}) + "\n")
            shadow.flush()
            closed.append({**c, "silent_days": customer_silent_days(c, now)})
        except (urllib.error.URLError, ValueError) as e:
            fail.append((c["id"], str(e)[:140]))
        time.sleep(0.3)
    shadow.close()
    ok = len(closed)
    print(f"closed_ok={ok} failed={len(fail)} (shadow log: {shadow_path})")
    for f in fail[:15]:
        print(f"  FAIL {f}", file=sys.stderr)

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
