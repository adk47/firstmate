#!/usr/bin/env python3
"""Monthly READ-ONLY report ranking which MISSING customer self-serve feature
would remove the most human-touch support tickets.

Phase 3 of docs/plans/autonomous-cs-machine.md. Every create_ticket call
Caroline (edge/support agent) makes is a case where a customer needed a
HUMAN to file a Catalog/ClickUp ticket for them -- this script sweeps the
edge session trajectory JSONL, classifies each ticket's actionType against a
hand-curated MISSING/POLICY/EXISTS/TRIAGE taxonomy, and ranks build
candidates by unique NEW tickets/month (touches as a secondary column). It
NEVER writes to Intercom/ClickUp/muso -- its only side effects are its own
durable rollup state and one Slack post, gated behind --post.

DATA SOURCE. Edge trajectory JSONL: glob
/root/.openclaw-edge/agents/support/sessions/*.trajectory.jsonl
(env-overridable CS_BACKLOG_TRAJECTORY_GLOB). The reaper only keeps ~5 days
of these files on disk, so history is accumulated into a durable rollup at
/var/lib/cs-selfserve-backlog/monthly.json (env CS_BACKLOG_STATE) rather than
re-derived from scratch each run.

EVENT EXTRACTION. Each trajectory line is a typed event
(session.started/context.compiled/prompt.submitted/tool.call/tool.result/...).
A substring pre-filter on "create_ticket" is speed-only -- every session's
context.compiled event lists create_ticket in the tool catalog (a decoy that
would count ~every session if type were not also checked). Only
type in ("tool.call", "tool.result") with data.name == "create_ticket"
count. Records are keyed by data.toolCallId: a tool.call carries
data.arguments.actionType; the matching tool.result carries
data.success + data.contentItems[].text (a JSON string, e.g.
{"submitted":true,"ticket_id":"869..."} or {"submitted":false,...}) --
see docs lesson reference_edge_trajectory_jsonl_trace.md for the verified
event shape. Status per toolCallId (a result upgrades a bare call):
  new_ticket = result submitted && not updated_existing
  updated    = result submitted && updated_existing
  error      = result not submitted (or unparseable)
  call_only  = a call with no result seen yet
Conversation id comes from sessionKey == "agent:support:intercom:direct:<id>"
ONLY; any other sessionKey shape (e.g. a -topic- session) counts toward an
"unattributed" footer counter instead, never silently dropped.
Month = the UTC month of the event's ts (ISO8601-Z).

PRIMARY METRIC: unique NEW tickets (status == new_ticket) per actionType per
month -- raw call counting overcounts (repeat contacts on the same ticket).
Secondary column: touches = total create_ticket calls for that actionType
(captures repeat-contact effort); comes free from the same sweep.

ROLLUP STATE (atomic tmp+rename; env CS_BACKLOG_STATE):
  {"schema": 1, "months": {"2026-07": {"partial_from": "<ISO date>"?,
                                        "records": {toolCallId: {actionType,
                                                                  conv,
                                                                  status}}}}}
Merge is idempotent on toolCallId: re-scanning the same files reproduces the
same counts, and a later sweep upgrades a call_only record to
new_ticket/updated/error once its result line appears. There is no
byte-offset watermark. On the first --post after a month has closed, that
month's records collapse to counts
({actionType: {new_tickets, touches, updated, error}}) and the ids are
dropped (bounded growth). A corrupt/unparseable EXISTING state file is fail
-closed: exit 4, state left untouched -- same fail-closed lineage as
scripts/close-duplicate-conversations.py's pointer-state handling (commits
e7928c95 / 029f6243).

FEATURE_MAP classifies every plugins/support-tools TIER_MAP actionType
(vendored twin here, parity-tested against ticket-format.ts by
tests/test_cs_selfserve_backlog.py) into:
  MISSING -- a self-serve feature that would deflect these tickets (the
             build-candidate ranking)
  POLICY  -- refund/dispute/deletion/export tickets that legitimately need a
             human for policy reasons; rendered as a lower bound (excludes
             escalation-path tickets this sweep never sees)
  EXISTS  -- profile-claim: self-serve already exists; residual route%
             enrichment only
  TRIAGE  -- no single feature would fix these; informational footer
Anything not in FEATURE_MAP renders under UNMAPPED, never dropped -- a new
actionType added to TIER_MAP without a FEATURE_MAP classification fails the
parity test in CI rather than silently vanishing from the report.

ENRICHMENT (post-time, fail-soft). A per-verb route_to_human% for the
report month, read from /var/log/muso-ops/tier2-audit.jsonl (env
CS_BACKLOG_AUDIT_PATH). The decision-vocabulary constants below are
duplicated (not imported) from scripts/caroline-behavior-digest.py:144-153
-- see that file for the canonical muso-cli capability audit.go source and
the rationale for each bucket. If the file is unreadable, enrichment
renders "not available"; it never blocks --post.

FAIL-LOUD:
  1. Trajectory dir missing/empty, or a collect sweep finds 0 create_ticket
     tool.call events (live baseline ~70-205/day; a zero day means Caroline
     is down or the schema renamed, never "quiet") -> exit 4, no post.
  2. --post with a report-month total of 0 -> exit non-zero, never post
     "nothing to build".
  3. Corrupt rollup -> exit 4, state untouched.
  4. A malformed/torn JSONL line (files are appended live) is skipped, never
     aborts the sweep.
  5. Failed Slack delivery in --post -> non-zero (systemd timer surfaces it).

Env:
  CS_BACKLOG_TRAJECTORY_GLOB  optional, default below
  CS_BACKLOG_STATE            optional, default /var/lib/cs-selfserve-backlog/monthly.json
  CS_BACKLOG_AUDIT_PATH       optional, default /var/log/muso-ops/tier2-audit.jsonl
  CS_BACKLOG_CHANNEL          optional, default C0ANM0PN9L5 (#cs_chats)
  CS_BACKLOG_MENTION          optional, default U0AL36NADEY (Nick)
  SLACK_NOTIFY_CONFIG         optional, default /root/.openclaw-main/openclaw.json
  CS_BACKLOG_SLACK_ACCOUNT    optional, default operations
  CS_BACKLOG_NOW              optional, epoch override (tests)
  CS_BACKLOG_SKIP_HOST_GUARD  optional, "1" to run off ovh-node-8 (tests)
  CS_BACKLOG_HOSTNAME_OVERRIDE  optional, override the perceived hostname
                                (tests)

Flags:
  --collect     sweep + merge into the durable rollup, no Slack (daily timer)
  --post        collect (catches the month-end tail), then render + post the
                PREVIOUS UTC month to Slack (monthly timer)
  --state PATH  override the rollup state path (dry-run only; default is a
                throwaway temp copy of the real state)
  --self-test   run the inline self-test and exit

Default (no mode flag): dry-run -- collect into a temp/--state-override
copy, print the render, write nothing to the real state, post nothing.

Exit codes: 0 ok; 2 self-test failed; 4 fail-loud (see FAIL-LOUD above);
1 failed Slack delivery on --post.
"""
import argparse
import datetime
import glob
import json
import os
import shutil
import socket
import sys
import tempfile
import time
import urllib.error
import urllib.request

SLACK_API = "https://slack.com/api/chat.postMessage"
DEFAULT_TRAJECTORY_GLOB = (
    "/root/.openclaw-edge/agents/support/sessions/*.trajectory.jsonl")
DEFAULT_STATE_PATH = "/var/lib/cs-selfserve-backlog/monthly.json"
DEFAULT_AUDIT_PATH = "/var/log/muso-ops/tier2-audit.jsonl"
DEFAULT_CHANNEL = "C0ANM0PN9L5"  # #cs_chats
DEFAULT_MENTION = "U0AL36NADEY"  # Nick
SCHEMA_VERSION = 1

CREATE_TICKET_TOOL = "create_ticket"
SESSIONKEY_CONV_PREFIX = "agent:support:intercom:direct:"


# --------------------------------------------------------------------------
# Vendored twin of plugins/support-tools/src/tools/ticket-format.ts's
# TIER_MAP (17 actionType keys) -- parity-tested against that file by
# tests/test_cs_selfserve_backlog.py in BOTH directions, so a new repo-side
# actionType fails CI until it is classified here, and a stale entry here
# fails CI once it is removed there.
#
# (klass, group_label):
#   MISSING -- group_label is the shared build-candidate line 2+ actionTypes
#              roll up under.
#   POLICY / EXISTS / TRIAGE -- group_label is a per-actionType label.
# --------------------------------------------------------------------------
FEATURE_MAP = {
    "credit-verify": ("MISSING", "self-serve credit submission/verification"),
    "credit-claim": ("MISSING", "self-serve credit submission/verification"),
    "credit-correction": ("MISSING", "self-serve credit submission/verification"),
    "profile-merge": ("MISSING", "self-serve merge/unmerge"),
    "unmerge-request": ("MISSING", "self-serve merge/unmerge"),
    "track-merge": ("MISSING", "self-serve merge/unmerge"),
    "profile-update": ("MISSING", "self-serve profile/credit editing"),
    "bulk-credit-change": ("MISSING", "self-serve profile/credit editing"),
    "subscription-refund": ("POLICY", "refund"),
    "dispute": ("POLICY", "dispute"),
    "data-deletion": ("POLICY", "data deletion"),
    "data-export": ("POLICY", "data export"),
    "profile-claim": ("EXISTS", "profile claim"),
    "support-general": ("TRIAGE", "support-general"),
    "analytics-followup": ("TRIAGE", "analytics-followup"),
    "order-fulfillment": ("TRIAGE", "order-fulfillment"),
    "billing-issue": ("TRIAGE", "billing-issue"),
}

POLICY_FOOTNOTE = (
    "POLICY tickets are a LOWER BOUND: this sweep only sees create_ticket "
    "calls, never the escalation path a customer can also take straight to "
    "a human, so the real refund/dispute/deletion/export volume is higher.")

# muso-cli capability decision vocabulary (internal/policy/capability/audit.go),
# duplicated (not imported) from scripts/caroline-behavior-digest.py:144-153
# -- see that file for the canonical source and the rationale behind each
# bucket. Only the two buckets this report's route_to_human% needs are
# reproduced here.
SUCCESS = {"applied", "noop"}  # mutation accepted / idempotent already-done
ROUTED = {"refused"}           # route_to_human: capability check bounced pre-mutation
VERBS = ("profiles_claim_self", "credits_verify", "profiles_consolidate")
ENRICHMENT_VERB_FOR_ACTIONTYPE = {"profile-claim": "profiles_claim_self"}


# --------------------------------------------------------------------------
# Time helpers.
# --------------------------------------------------------------------------
def month_of(ts):
    """UTC "YYYY-MM" from an ISO8601-Z ts string; None if unparseable."""
    if not ts:
        return None
    s = str(ts).strip()
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S.%fZ"):
        try:
            return datetime.datetime.strptime(s, fmt).strftime("%Y-%m")
        except ValueError:
            continue
    return None


def previous_utc_month(now_epoch):
    dt = datetime.datetime.fromtimestamp(now_epoch, tz=datetime.timezone.utc)
    last_of_prev = dt.replace(day=1) - datetime.timedelta(days=1)
    return last_of_prev.strftime("%Y-%m")


def prior_month_key(month_key):
    y, m = (int(x) for x in month_key.split("-"))
    m -= 1
    if m == 0:
        y, m = y - 1, 12
    return f"{y:04d}-{m:02d}"


# --------------------------------------------------------------------------
# Trajectory sweep (pure, no network -- directly unit-testable).
# --------------------------------------------------------------------------
def _parse_result_payload(content_items):
    """The tool.result JSON payload lives at data.contentItems[].text (a JSON
    STRING, e.g. '{"submitted":true,"ticket_id":"869..."}'), per the verified
    edge trajectory event shape -- NOT a bare data.result field. Returns the
    first parseable dict payload found, or None."""
    if not isinstance(content_items, list):
        return None
    for item in content_items:
        if not isinstance(item, dict):
            continue
        text = item.get("text")
        if not text:
            continue
        try:
            payload = json.loads(text)
        except ValueError:
            continue
        if isinstance(payload, dict):
            return payload
    return None


def sessionkey_conv(session_key):
    """Conversation id from a sessionKey shaped
    'agent:support:intercom:direct:<conv-id>' ONLY; any other shape (e.g. a
    -topic- session) returns None so the caller can count it as
    unattributed rather than silently mis-mapping it."""
    if session_key and session_key.startswith(SESSIONKEY_CONV_PREFIX):
        return session_key[len(SESSIONKEY_CONV_PREFIX):]
    return None


def sweep_files(paths):
    """Read every trajectory file in `paths` (missing/unreadable files are
    skipped -- the glob can race with the reaper). Returns
    (partial, calls_seen): `partial` is toolCallId -> {"call": {...}|None,
    "result": {...}|None}; `calls_seen` is the raw count of matching
    tool.call events found THIS sweep (used for the zero-day fail-loud
    check)."""
    partial = {}
    calls_seen = 0
    for path in paths:
        try:
            f = open(path)
        except OSError:
            continue
        try:
            for line in f:
                if CREATE_TICKET_TOOL not in line:
                    continue  # speed-only pre-filter
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue  # malformed/torn line -- skip, never abort
                if not isinstance(rec, dict):
                    continue
                typ = rec.get("type")
                if typ not in ("tool.call", "tool.result"):
                    continue  # excludes the context.compiled tool-catalog decoy
                data = rec.get("data") or {}
                if data.get("name") != CREATE_TICKET_TOOL:
                    continue
                tool_call_id = data.get("toolCallId")
                if not tool_call_id:
                    continue
                entry = partial.setdefault(tool_call_id, {"call": None, "result": None})
                if typ == "tool.call":
                    calls_seen += 1
                    entry["call"] = {
                        "ts": rec.get("ts"),
                        "sessionKey": rec.get("sessionKey"),
                        "actionType": (data.get("arguments") or {}).get("actionType"),
                    }
                else:
                    entry["result"] = {
                        "ts": rec.get("ts"),
                        "sessionKey": rec.get("sessionKey"),
                        "payload": _parse_result_payload(data.get("contentItems")),
                    }
        finally:
            f.close()
    return partial, calls_seen


def classify_status(entry):
    """new_ticket / updated / error / call_only, per the entry's most recent
    call+result data (see module docstring)."""
    result = entry.get("result")
    if result is not None:
        payload = result.get("payload") or {}
        if payload.get("submitted") is True:
            return "updated" if payload.get("updated_existing") else "new_ticket"
        return "error"
    if entry.get("call") is not None:
        return "call_only"
    return None


def resolve_conv(entry):
    session_key = None
    if entry.get("call"):
        session_key = entry["call"].get("sessionKey")
    if not session_key and entry.get("result"):
        session_key = entry["result"].get("sessionKey")
    return sessionkey_conv(session_key) or "unattributed"


def resolve_month(entry):
    ts = None
    if entry.get("call"):
        ts = entry["call"].get("ts")
    if not ts and entry.get("result"):
        ts = entry["result"].get("ts")
    return month_of(ts)


# --------------------------------------------------------------------------
# Durable rollup state (atomic tmp+rename, fail-closed on corrupt reads --
# mirrors scripts/close-duplicate-conversations.py's pointer-state handling).
# --------------------------------------------------------------------------
class StateUnreadable(Exception):
    """Raised by load_state() when the rollup file EXISTS but cannot be
    read/parsed -- as opposed to a legitimate first run, where the file
    simply does not exist yet. Collapsing both cases to "empty state" would
    silently zero out months of accumulated history on a corrupt read; the
    caller MUST treat this as untrusted state and refuse to proceed."""


def load_state(path):
    if not os.path.exists(path):
        return {"schema": SCHEMA_VERSION, "months": {}}
    try:
        with open(path) as f:
            state = json.load(f)
    except (OSError, ValueError) as e:
        raise StateUnreadable(str(e)) from e
    if not isinstance(state, dict) or not isinstance(state.get("months"), dict):
        raise StateUnreadable("missing or malformed 'months' key")
    return state


def save_state(state, path):
    """Atomically persist the rollup (temp file + os.replace, so a crash
    mid-write never leaves a truncated/corrupt file). Returns True on
    success, False on any OSError."""
    try:
        d = os.path.dirname(path) or "."
        os.makedirs(d, exist_ok=True)
        fd, tmp_path = tempfile.mkstemp(prefix=".monthly-", dir=d)
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
        print(f"ERROR: could not durably persist rollup state to {path}: {e}", file=sys.stderr)
        return False


def merge_into_state(state, partial, today_iso):
    """Idempotently merge this sweep's `partial` (see sweep_files) into
    state["months"]. A toolCallId's month is fixed the first time it is
    resolved (from its call ts, preferred, else its result ts) and never
    moves on a later sweep. A month already collapsed to `counts` (see
    collapse_month) no longer accepts individual-record merges -- by the
    time a month is collapsed (at --post, once it has closed), the daily
    collect timer has moved on to the next month's files."""
    months = state.setdefault("months", {})
    for tool_call_id, entry in partial.items():
        month = resolve_month(entry)
        if month is None:
            continue  # unparseable ts on both call and result -- defensive
        bucket = months.get(month)
        if bucket is None:
            bucket = {"records": {}}
            first_of_month = f"{month}-01"
            if today_iso[:7] == month and today_iso != first_of_month:
                bucket["partial_from"] = today_iso
            months[month] = bucket
        if "records" not in bucket:
            continue  # month already collapsed -- best-effort, see docstring
        records = bucket["records"]
        existing = records.get(tool_call_id, {})
        action_type = None
        if entry.get("call"):
            action_type = entry["call"].get("actionType")
        if not action_type:
            action_type = existing.get("actionType")
        conv = resolve_conv(entry)
        if conv == "unattributed" and existing.get("conv") not in (None, "unattributed"):
            conv = existing["conv"]
        status = classify_status(entry)
        if status is None:
            status = existing.get("status")
        if status is None:
            continue
        records[tool_call_id] = {
            "actionType": action_type or "unknown",
            "conv": conv,
            "status": status,
        }
    return state


def aggregate_month(bucket):
    """(counts, unattributed) for a month bucket, whether it is still
    records-based or already collapsed to counts."""
    if "counts" in bucket:
        return bucket["counts"], bucket.get("unattributed", 0)
    counts = {}
    unattributed = 0
    for rec in bucket.get("records", {}).values():
        action_type = rec.get("actionType") or "unknown"
        c = counts.setdefault(action_type, {"new_tickets": 0, "touches": 0, "updated": 0, "error": 0})
        c["touches"] += 1
        status = rec.get("status")
        if status in ("new_ticket", "updated", "error"):
            c[status if status != "new_ticket" else "new_tickets"] += 1
        if rec.get("conv") == "unattributed":
            unattributed += 1
    return counts, unattributed


def collapse_month(bucket):
    """Collapse a records-based month bucket to {counts, unattributed},
    dropping the per-toolCallId ids (bounded growth). partial_from carries
    over unchanged. A no-op if already collapsed."""
    if "records" not in bucket:
        return bucket
    counts, unattributed = aggregate_month(bucket)
    new_bucket = {"counts": counts, "unattributed": unattributed}
    if "partial_from" in bucket:
        new_bucket["partial_from"] = bucket["partial_from"]
    return new_bucket


# --------------------------------------------------------------------------
# Enrichment: per-verb route_to_human% for the report month (fail-soft --
# garnish only, never blocks --post).
# --------------------------------------------------------------------------
def route_to_human_pct(audit_path, month):
    try:
        with open(audit_path) as f:
            lines = f.readlines()
    except OSError:
        return None
    counts = {v: {"success": 0, "routed": 0} for v in VERBS}
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if not isinstance(rec, dict):
            continue
        tool = rec.get("tool")
        if tool not in counts:
            continue
        if month_of(rec.get("ts")) != month:
            continue
        decision = str(rec.get("decision") or "")
        if decision in SUCCESS:
            counts[tool]["success"] += 1
        elif decision in ROUTED:
            counts[tool]["routed"] += 1
    out = {}
    for verb, c in counts.items():
        total = c["success"] + c["routed"]
        out[verb] = round(100.0 * c["routed"] / total, 1) if total else None
    return out


# --------------------------------------------------------------------------
# Report assembly (pure -- directly unit-testable).
# --------------------------------------------------------------------------
def _group_new_tickets(counts, target_key):
    total = 0
    for action_type, c in counts.items():
        if FEATURE_MAP.get(action_type, ("UNMAPPED", action_type)) == target_key:
            total += c["new_tickets"]
    return total


def build_report(state, report_month):
    months = state.get("months", {})
    bucket = months.get(report_month)
    if bucket is None:
        counts, unattributed, partial_from = {}, 0, None
    else:
        counts, unattributed = aggregate_month(bucket)
        partial_from = bucket.get("partial_from")

    prior_month = prior_month_key(report_month)
    prior_bucket = months.get(prior_month)
    prior_counts = {}
    if prior_bucket and not prior_bucket.get("partial_from"):
        prior_counts, _ = aggregate_month(prior_bucket)

    groups = {}
    for action_type, c in counts.items():
        key = FEATURE_MAP.get(action_type, ("UNMAPPED", action_type))
        g = groups.setdefault(key, {"types": {}, "total_new": 0, "total_touches": 0})
        g["types"][action_type] = c
        g["total_new"] += c["new_tickets"]
        g["total_touches"] += c["touches"]

    for key, g in groups.items():
        g["prior_new"] = _group_new_tickets(prior_counts, key) if prior_counts else None

    total_touches = sum(c["touches"] for c in counts.values())
    return {
        "report_month": report_month,
        "partial_from": partial_from,
        "unattributed": unattributed,
        "groups": groups,
        "total_touches": total_touches,
    }


# --------------------------------------------------------------------------
# Rendering.
# --------------------------------------------------------------------------
def _slack_escape(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _trend_str(g):
    if g["prior_new"] is None:
        return ""
    delta = g["total_new"] - g["prior_new"]
    sign = "+" if delta >= 0 else ""
    return f" ({sign}{delta} vs prior month)"


def render_text(report, enrichment=None):
    lines = [f"CS self-serve backlog -- {report['report_month']}"]
    if report["partial_from"]:
        lines.append(f"data from {report['partial_from']} (month not fully covered)")

    def rows_for(klass):
        return [(key, g) for key, g in report["groups"].items() if key[0] == klass]

    missing = sorted(rows_for("MISSING"), key=lambda kg: -kg[1]["total_new"])
    if missing:
        lines.append("")
        lines.append("MISSING -- build candidates (ranked by unique new tickets/mo):")
        for (klass, group_label), g in missing:
            lines.append(f"  {group_label}: {g['total_new']} new tickets, "
                         f"{g['total_touches']} touches{_trend_str(g)}")
            for action_type, c in sorted(g["types"].items(), key=lambda kv: -kv[1]["new_tickets"]):
                lines.append(f"    - {action_type}: {c['new_tickets']} new / {c['touches']} touches")

    policy = rows_for("POLICY")
    if policy:
        lines.append("")
        lines.append("POLICY (lower bound -- excludes escalation-path tickets):")
        for (klass, group_label), g in policy:
            for action_type, c in g["types"].items():
                lines.append(f"  {action_type}: {c['new_tickets']} new / "
                             f"{c['touches']} touches (lower bound)")

    exists = rows_for("EXISTS")
    if exists:
        lines.append("")
        lines.append("EXISTS (self-serve already shipped -- residual only):")
        for (klass, group_label), g in exists:
            for action_type, c in g["types"].items():
                verb = ENRICHMENT_VERB_FOR_ACTIONTYPE.get(action_type)
                pct = (enrichment or {}).get(verb) if verb else None
                pct_s = f"{pct}% still routed to a human" if pct is not None else "route% not available"
                lines.append(f"  {action_type}: {c['new_tickets']} new / "
                             f"{c['touches']} touches ({pct_s})")

    triage = rows_for("TRIAGE") + [k for k in report["groups"].items() if k[0][0] == "UNMAPPED"]
    if triage:
        lines.append("")
        lines.append("TRIAGE / UNMAPPED (informational -- no single feature fixes these):")
        for (klass, group_label), g in triage:
            for action_type, c in g["types"].items():
                tag = " [UNMAPPED]" if klass == "UNMAPPED" else ""
                lines.append(f"  {action_type}: {c['new_tickets']} new / {c['touches']} touches{tag}")

    if report["unattributed"]:
        lines.append("")
        lines.append(f"unattributed (non-Intercom sessionKey): {report['unattributed']}")

    lines.append("")
    lines.append(POLICY_FOOTNOTE)
    return "\n".join(lines)


def build_blocks(report, enrichment, mention):
    text = render_text(report, enrichment)
    return [
        {"type": "header", "text": {"type": "plain_text",
         "text": f"CS self-serve backlog -- {report['report_month']}"}},
        {"type": "section", "text": {"type": "mrkdwn", "text": _slack_escape(text)}},
        {"type": "section", "text": {"type": "mrkdwn",
         "text": f"<@{mention}> ranked by unique new tickets/month; touches = "
                 "total create_ticket calls (repeat-contact effort)."}},
    ]


# --------------------------------------------------------------------------
# Slack (best-effort post -- duplicated from scripts/cs-needs-human-digest.py).
# --------------------------------------------------------------------------
def _read_slack_token(config_path, account):
    try:
        with open(config_path) as f:
            cfg = json.load(f)
        return cfg["channels"]["slack"]["accounts"][account]["botToken"]
    except (OSError, KeyError, ValueError, TypeError):
        return None


def post_slack_digest(blocks, text, channel, config_path, account):
    """Best-effort post. NEVER raises. Returns bool."""
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
    except Exception as e:  # noqa: BLE001 -- best-effort by contract
        print(f"WARN: Slack post error: {type(e).__name__}: {str(e)[:140]}", file=sys.stderr)
        return False


# --------------------------------------------------------------------------
# Collect: sweep the glob + merge into a rollup at `state_path`.
# --------------------------------------------------------------------------
def do_collect(glob_pattern, state_path, today_iso):
    """Returns (state, exit_code). exit_code != 0 -> caller must not write
    anything and must propagate it (see FAIL-LOUD in the module docstring)."""
    paths = sorted(glob.glob(glob_pattern))
    partial, calls_seen = sweep_files(paths)
    if calls_seen == 0:
        print(f"ERROR: 0 create_ticket tool.call events found (matched {len(paths)} "
              f"trajectory file(s) via {glob_pattern!r}) this sweep -- live baseline "
              "is ~70-205/day; a zero day means Caroline is down or the event schema "
              "changed, never treat this as \"quiet\"", file=sys.stderr)
        return None, 4
    try:
        state = load_state(state_path)
    except StateUnreadable as e:
        print(f"ERROR: rollup state at {state_path} is unreadable/corrupt ({e}) -- "
              "refusing to overwrite (state left untouched)", file=sys.stderr)
        return None, 4
    state = merge_into_state(state, partial, today_iso)
    return state, 0


# --------------------------------------------------------------------------
# Inline self-test: fail the run if any correctness invariant above breaks,
# so a silently-misfiring collect/report rots quietly instead of paging.
# --------------------------------------------------------------------------
def _self_test():
    call = lambda tcid, at, sk, ts: {"type": "tool.call", "ts": ts, "sessionKey": sk,
                                      "data": {"name": "create_ticket", "toolCallId": tcid,
                                               "arguments": {"actionType": at}}}
    result = lambda tcid, payload, sk, ts: {
        "type": "tool.result", "ts": ts, "sessionKey": sk,
        "data": {"name": "create_ticket", "toolCallId": tcid,
                 "contentItems": [{"type": "text", "text": json.dumps(payload)}]}}
    decoy = {"type": "context.compiled", "ts": "2026-07-01T00:00:00Z",
             "data": {"tools": [{"name": "create_ticket"}]}}

    lines = [
        json.dumps(decoy),
        json.dumps(call("t1", "credit-verify", "agent:support:intercom:direct:C1",
                         "2026-07-01T00:00:00Z")),
        json.dumps(result("t1", {"submitted": True, "ticket_id": "1"},
                           "agent:support:intercom:direct:C1", "2026-07-01T00:00:05Z")),
        json.dumps(call("t2", "credit-verify", "agent:support:intercom:direct:C2",
                         "2026-07-02T00:00:00Z")),
        json.dumps(result("t2", {"submitted": True, "updated_existing": True, "ticket_id": "1"},
                           "agent:support:intercom:direct:C2", "2026-07-02T00:00:05Z")),
        json.dumps(call("t3", "profile-merge", "agent:support:topic-xyz",
                         "2026-07-03T00:00:00Z")),
    ]
    partial, calls_seen = _sweep_lines(lines)
    assert calls_seen == 3, calls_seen
    assert set(partial) == {"t1", "t2", "t3"}, partial

    state = {"schema": SCHEMA_VERSION, "months": {}}
    state = merge_into_state(state, partial, "2026-07-01")
    recs = state["months"]["2026-07"]["records"]
    assert recs["t1"]["status"] == "new_ticket", recs["t1"]
    assert recs["t2"]["status"] == "updated", recs["t2"]
    assert recs["t3"]["status"] == "call_only", recs["t3"]
    assert recs["t3"]["conv"] == "unattributed", recs["t3"]

    # idempotency: re-merging the identical sweep must not change counts.
    state2 = merge_into_state(json.loads(json.dumps(state)), partial, "2026-07-01")
    assert state2["months"]["2026-07"]["records"] == recs, state2

    # orphan-call upgrade: a later sweep's result upgrades call_only.
    result_only_partial = {"t3": {"call": None, "result": {
        "ts": "2026-07-04T00:00:00Z", "sessionKey": None,
        "payload": {"submitted": True, "ticket_id": "9"}}}}
    state = merge_into_state(state, result_only_partial, "2026-07-01")
    assert state["months"]["2026-07"]["records"]["t3"]["status"] == "new_ticket", \
        state["months"]["2026-07"]["records"]["t3"]
    assert state["months"]["2026-07"]["records"]["t3"]["actionType"] == "profile-merge"

    counts, unattributed = aggregate_month(state["months"]["2026-07"])
    assert counts["credit-verify"] == {"new_tickets": 1, "touches": 2, "updated": 1, "error": 0}, counts
    # t3's sessionKey never matched the intercom:direct: prefix (a -topic-
    # session), so it counts toward unattributed the whole time.
    assert unattributed == 1, unattributed

    collapsed = collapse_month(state["months"]["2026-07"])
    assert "records" not in collapsed and "counts" in collapsed, collapsed
    assert collapsed["counts"] == counts, collapsed

    # corrupt state -> StateUnreadable, never silently treated as empty.
    with tempfile.TemporaryDirectory() as td:
        bad = os.path.join(td, "monthly.json")
        with open(bad, "w") as f:
            f.write("{not json")
        try:
            load_state(bad)
            raise AssertionError("expected StateUnreadable")
        except StateUnreadable:
            pass

    # TIER_MAP parity is exercised by tests/test_cs_selfserve_backlog.py
    # (needs the repo root to locate ticket-format.ts, which this inline
    # self-test does not assume).
    return True


def _sweep_lines(lines):
    """Test seam: sweep_files() reads real files; this exercises the same
    inner parsing loop over in-memory lines for the self-test."""
    partial = {}
    calls_seen = 0
    for line in lines:
        if CREATE_TICKET_TOOL not in line:
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if not isinstance(rec, dict):
            continue
        typ = rec.get("type")
        if typ not in ("tool.call", "tool.result"):
            continue
        data = rec.get("data") or {}
        if data.get("name") != CREATE_TICKET_TOOL:
            continue
        tool_call_id = data.get("toolCallId")
        if not tool_call_id:
            continue
        entry = partial.setdefault(tool_call_id, {"call": None, "result": None})
        if typ == "tool.call":
            calls_seen += 1
            entry["call"] = {"ts": rec.get("ts"), "sessionKey": rec.get("sessionKey"),
                              "actionType": (data.get("arguments") or {}).get("actionType")}
        else:
            entry["result"] = {"ts": rec.get("ts"), "sessionKey": rec.get("sessionKey"),
                                "payload": _parse_result_payload(data.get("contentItems"))}
    return partial, calls_seen


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--collect", action="store_true",
                    help="sweep + merge into the durable rollup, no Slack (daily)")
    ap.add_argument("--post", action="store_true",
                    help="collect, then render+post the previous UTC month (monthly)")
    ap.add_argument("--state",
                    help="override the rollup state path (dry-run only)")
    ap.add_argument("--self-test", action="store_true",
                    help="run the inline self-test and exit")
    args = ap.parse_args()

    # Fail loud on invalid flag combinations rather than silently ignoring one.
    # --state is consulted ONLY in the dry-run branch below; letting it ride
    # alongside --collect/--post would post to the REAL channel and collapse the
    # REAL month state while the operator believed they were sandboxed.
    if args.collect and args.post:
        print("cs-selfserve-backlog: --collect and --post are mutually exclusive",
              file=sys.stderr)
        return 2
    if args.state and (args.collect or args.post):
        print("cs-selfserve-backlog: --state is honored only in dry-run mode; "
              "--collect/--post use the CS_BACKLOG_STATE env var. Refusing to run "
              "with a --state that would be silently ignored.", file=sys.stderr)
        return 2

    try:
        _self_test()
    except AssertionError as e:
        print(f"cs-selfserve-backlog: SELF-TEST FAILED: {e}", file=sys.stderr)
        return 2
    if args.self_test:
        print("self-test ok")
        return 0

    hostname = os.environ.get("CS_BACKLOG_HOSTNAME_OVERRIDE") or socket.gethostname()
    if os.environ.get("CS_BACKLOG_SKIP_HOST_GUARD") != "1" and hostname != "ovh-node-8":
        print("cs-selfserve-backlog: not on ovh-node-8 -- refusing "
              "(set CS_BACKLOG_SKIP_HOST_GUARD=1 to override)", file=sys.stderr)
        return 0

    glob_pattern = os.environ.get("CS_BACKLOG_TRAJECTORY_GLOB", DEFAULT_TRAJECTORY_GLOB)
    now_epoch = int(os.environ.get("CS_BACKLOG_NOW") or time.time())
    today_iso = datetime.datetime.fromtimestamp(now_epoch, tz=datetime.timezone.utc).strftime("%Y-%m-%d")

    if args.collect:
        state_path = os.environ.get("CS_BACKLOG_STATE", DEFAULT_STATE_PATH)
        state, rc = do_collect(glob_pattern, state_path, today_iso)
        if rc != 0:
            return rc
        if not save_state(state, state_path):
            return 4
        print(f"collect ok -- state written to {state_path}")
        return 0

    if args.post:
        state_path = os.environ.get("CS_BACKLOG_STATE", DEFAULT_STATE_PATH)
        state, rc = do_collect(glob_pattern, state_path, today_iso)
        if rc != 0:
            return rc
        report_month = previous_utc_month(now_epoch)
        report = build_report(state, report_month)
        if report["total_touches"] == 0:
            print(f"ERROR: report month {report_month} has 0 create_ticket touches in "
                  "the rollup -- refusing to post \"nothing to build\"", file=sys.stderr)
            return 4
        bucket = state["months"].get(report_month)
        if bucket and "records" in bucket:
            state["months"][report_month] = collapse_month(bucket)
        if not save_state(state, state_path):
            return 4

        audit_path = os.environ.get("CS_BACKLOG_AUDIT_PATH", DEFAULT_AUDIT_PATH)
        enrichment = route_to_human_pct(audit_path, report_month)
        text = render_text(report, enrichment)
        print(text)

        mention = os.environ.get("CS_BACKLOG_MENTION", DEFAULT_MENTION)
        blocks = build_blocks(report, enrichment, mention)
        channel = os.environ.get("CS_BACKLOG_CHANNEL", DEFAULT_CHANNEL)
        cfg = os.environ.get("SLACK_NOTIFY_CONFIG", "/root/.openclaw-main/openclaw.json")
        account = os.environ.get("CS_BACKLOG_SLACK_ACCOUNT", "operations")
        posted = post_slack_digest(blocks, text, channel, cfg, account)
        print(f"slack post: {'posted' if posted else 'skipped/failed'} -> {channel}")
        return 0 if posted else 1

    # default: dry-run -- collect into a temp/--state-override copy, print,
    # write nothing to the real state, post nothing.
    if args.state:
        state, rc = do_collect(glob_pattern, args.state, today_iso)
        if rc != 0:
            return rc
        save_state(state, args.state)
    else:
        real_state_path = os.environ.get("CS_BACKLOG_STATE", DEFAULT_STATE_PATH)
        with tempfile.TemporaryDirectory(prefix="cs-selfserve-backlog-dryrun-") as td:
            tmp_state_path = os.path.join(td, "monthly.json")
            if os.path.exists(real_state_path):
                try:
                    shutil.copyfile(real_state_path, tmp_state_path)
                except OSError:
                    pass
            state, rc = do_collect(glob_pattern, tmp_state_path, today_iso)
            if rc != 0:
                return rc

    report_month = previous_utc_month(now_epoch)
    report = build_report(state, report_month)
    audit_path = os.environ.get("CS_BACKLOG_AUDIT_PATH", DEFAULT_AUDIT_PATH)
    enrichment = route_to_human_pct(audit_path, report_month)
    print(render_text(report, enrichment))
    print("DRY-RUN -- nothing written to real state, nothing posted.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
