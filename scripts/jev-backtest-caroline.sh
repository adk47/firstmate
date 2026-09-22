#!/bin/bash
# ──────────────────────────────────────────────────────────────
# jev-backtest-caroline.sh — read-only Jev backtest for the Caroline pre-turn
# router (docs/designs/2026-09-22-jev-caroline-router.md, section C).
#
# Samples real Intercom conversations Caroline already handled into four
# cohorts, replays every customer turn through the exact production wire
# path (scripts/lib/jev.sh --no-shadow), and reports per-question agreement
# against the label each cohort implies plus recommended decision bands.
#
# Never writes to Intercom: /conversations/search and GET /conversations/<id>
# are the only calls made, both read APIs. The Jev API key never appears in
# this script or its output (scripts/lib/jev.sh owns that secret).
#
# Usage:
#   jev-backtest-caroline.sh [--days 14] [--limit 60] [--out DIR] \
#     [--questions PATH] [--dry-run]
#
#   --days N       Intercom/journal window in days (default 14).
#   --limit N      target total sampled conversations, split across the four
#                  cohorts below (default 60).
#   --out DIR      output dir for report.md + rows.jsonl
#                  (default /var/lib/caroline-backtest).
#   --questions P  path to the Jev questions JSON (default
#                  plugins/intercom/src/caroline-questions.json under the
#                  repo root) — the single source shared with the plugin.
#   --dry-run      sample + label conversations, print the plan, and exit
#                  before any Intercom transcript fetch or Jev call.
#
# Cohorts (docs/designs/2026-09-22-jev-caroline-router.md section C.1):
#   a. Caroline called a support tool (plugins/intercom/src/
#      caroline-inventory.json's .tools[].name, minus openclaw built-ins and
#      support_action_router -- see BUILTIN_EXCLUDE) -- label: resolution_
#      path=caroline_tool on the FIRST customer turn (the request that led
#      to the call), first_tool = the first qualifying tool.call event's
#      name, intent = the create_ticket actionType (if any) mapped back
#      through ACTION_TYPE_TO_INTENT. The last turn of a resolved
#      conversation is routinely a bare "thanks"/"ok" close, which Jev
#      correctly answers no_reply -- labeling it caroline_tool measured the
#      wrong turn.
#   b. edge journal ESCALATED source=rule with reason matching
#      dispute/chargeback/legal/deletion/fraud (a "content" reason) --
#      label: resolution_path=human_required on the customer turn
#      immediately BEFORE the ESCALATED journal timestamp (falls back to
#      the last customer turn if the timestamp is unavailable). A bare
#      source=user_request escalation is handled by the keyword layer
#      before Jev ever runs, so it is sampled but labeled resolution_
#      path=null (see label.user_request_turn), informational only.
#   c. Caroline replied, no qualifying tool call, no escalation, and the
#      LAST message in the transcript is a customer closer (workspaces/
#      support/SOUL.md's "acknowledge once, then go quiet" list) -- label:
#      resolution_path=no_reply on that closer turn.
#   d. conversation 215476013943381 (the troll reference, 2026-09-20) --
#      label: off_topic_or_bad_faith=true from its 4th customer message on,
#      false before that.
#
# Every OTHER customer turn in a/b/c conversations, and turns 1-3 of the
# troll conversation, are still replayed (so the report has a real negative
# set for the bad_faith/no_reply/human_required threshold sweep) but their
# resolution_path is left unlabeled -- only the single turn each cohort
# names is known to be caroline_tool/human_required/no_reply. This is a
# documented simplification: the trajectory/journal evidence names which
# CONVERSATION resolved which way, not which turn inside it, beyond the
# single named turn above.
#
# Data sources (read-only, all mirror scripts the daily review already
# uses):
#   - edge journal: `journalctl -u <unit> --since "<days> days ago" -o short-unix`
#     (short-unix gives a parseable per-line epoch prefix, needed to find the
#     customer turn immediately before an ESCALATED line) for
#     `replied conv=`, `ESCALATED conv=... source=... reason=...`, and
#     `[intercom:escalation] ticket created conv=...` lines. Override with
#     CAROLINE_BACKTEST_JOURNAL_FILE (test seam: read that file verbatim
#     instead of invoking journalctl).
#   - edge trajectory (cohort a): the same JSONL-vs-SQLite source resolution
#     as scripts/cs-selfserve-backlog.py, ported and generalized to every
#     tool.call (not just create_ticket) because cohort a needs the FIRST
#     tool called, not just ticket filings. Override with
#     CAROLINE_BACKTEST_TRAJECTORY_SOURCE=jsonl|sqlite (default: auto-detect
#     via `openclaw --version`, same floor as cs-selfserve-backlog.py),
#     CAROLINE_BACKTEST_TRAJECTORY_GLOB, CAROLINE_BACKTEST_TRAJECTORY_DBS
#     (colon-separated).
#   - caroline-inventory.json (cohort a): plugins/intercom/src/
#     caroline-inventory.json's .tools[].name is the allowlist a tool.call
#     event's name must be in to count as cohort a's resolving signal
#     (BUILTIN_EXCLUDE drops openclaw built-ins and support_action_router,
#     which fire on nearly every turn and are not a resolution). Override
#     with CAROLINE_BACKTEST_INVENTORY_FILE; read-only, never written.
#   - Intercom: mirrors
#     workspaces/operations/skills/muso-caroline-weekly-review/scripts/fetch-conversations.sh's
#     two-step retrieve (search for candidate ids, GET each by id with
#     display_as=plaintext) -- POST /conversations/search returns empty
#     conversation_parts, so transcript content only ever comes from the
#     per-id GET. MUSOAI_INTERCOM_TOKEN from the environment, else read from
#     /etc/openclaw/edge.env.
#
# rows.jsonl is redacted with the daily review's
# workspaces/operations/skills/muso-caroline-weekly-review/scripts/lib/redact-core.sed
# before it is written -- the same PII scrub used for the weekly digest,
# applied here so no customer PII lands under --out. Nothing beyond a
# conversation id / cohort / label / probability ever reaches stdout or
# report.md; customer message text is never printed.
#
# Exit codes: 0 ok; 2 bad usage; 3 no candidates found for any cohort;
#   4 the Intercom conversation search failed (auth / other HTTP / transport /
#     unparseable response) -- NEVER downgraded to an empty result set;
#   5 sample coverage too low: fewer conversations were fetched+replayed than
#     CAROLINE_BACKTEST_MIN_FETCH_PCT (default 80) percent of those sampled,
#     so no report.md/rows.jsonl is written.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

USAGE="Usage: jev-backtest-caroline.sh [--days 14] [--limit 60] [--out DIR] [--questions PATH] [--dry-run]"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REDACT_SED="$REPO_ROOT/workspaces/operations/skills/muso-caroline-weekly-review/scripts/lib/redact-core.sed"
TROLL_CONV_ID="215476013943381"

: "${CAROLINE_BACKTEST_EDGE_UNIT:=openclaw-gateway-edge}"
: "${CAROLINE_BACKTEST_JEV_SH:=$REPO_ROOT/scripts/lib/jev.sh}"
: "${CAROLINE_BACKTEST_TRAJECTORY_SOURCE:=auto}"
: "${CAROLINE_BACKTEST_TRAJECTORY_GLOB:=/root/.openclaw-edge/agents/support/sessions/*.trajectory.jsonl}"
: "${CAROLINE_BACKTEST_TRAJECTORY_DBS:=/root/.openclaw-edge/agents/support/agent/openclaw-agent.sqlite}"
: "${CAROLINE_BACKTEST_INTERCOM_ENV_FILE:=/etc/openclaw/edge.env}"
: "${CAROLINE_BACKTEST_INVENTORY_FILE:=$REPO_ROOT/plugins/intercom/src/caroline-inventory.json}"
# Minimum percentage of the SAMPLED conversations that must actually be
# fetched and replayed before a report may be written (see the sample-coverage
# gate in section 8b for the reasoning behind the 80 default).
: "${CAROLINE_BACKTEST_MIN_FETCH_PCT:=80}"

_bt_die() {
  echo "jev-backtest-caroline.sh: $2" >&2
  exit "$1"
}

days=14
limit=60
out_dir="/var/lib/caroline-backtest"
questions_file="$REPO_ROOT/plugins/intercom/src/caroline-questions.json"
dry_run=0

while [ $# -gt 0 ]; do
  case "$1" in
    --days) days="$2"; shift 2 ;;
    --limit) limit="$2"; shift 2 ;;
    --out) out_dir="$2"; shift 2 ;;
    --questions) questions_file="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) echo "$USAGE"; exit 0 ;;
    *) echo "$USAGE" >&2; _bt_die 2 "unknown argument: $1" ;;
  esac
done

case "$days" in ''|*[!0-9]*) _bt_die 2 "--days must be a positive integer (got: $days)" ;; esac
case "$limit" in ''|*[!0-9]*|0) _bt_die 2 "--limit must be a positive integer (got: $limit)" ;; esac
case "$CAROLINE_BACKTEST_MIN_FETCH_PCT" in
  ''|*[!0-9]*|0) _bt_die 2 "CAROLINE_BACKTEST_MIN_FETCH_PCT must be an integer 1-100 (got: $CAROLINE_BACKTEST_MIN_FETCH_PCT)" ;;
esac
[ "$CAROLINE_BACKTEST_MIN_FETCH_PCT" -le 100 ] || _bt_die 2 "CAROLINE_BACKTEST_MIN_FETCH_PCT must be an integer 1-100 (got: $CAROLINE_BACKTEST_MIN_FETCH_PCT)"
[ -x "$CAROLINE_BACKTEST_JEV_SH" ] || [ -r "$CAROLINE_BACKTEST_JEV_SH" ] || _bt_die 2 "jev.sh not found/readable: $CAROLINE_BACKTEST_JEV_SH"
[ -r "$REDACT_SED" ] || _bt_die 2 "redact-core.sed not found: $REDACT_SED"
[ -r "$CAROLINE_BACKTEST_INVENTORY_FILE" ] || _bt_die 2 "caroline-inventory.json not found/readable: $CAROLINE_BACKTEST_INVENTORY_FILE"

mkdir -p "$out_dir"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/jev-backtest.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

# The python helper (sample/closer-check/turns/report subcommands) is
# embedded here, not a sibling file: this script is the single unit the
# implementer contract scopes changes to, matching jev-shadow-report.sh's
# "one file, one language-per-concern" embedded-heredoc style.
PY_SCRIPT="$work_dir/lib.py"
cat > "$PY_SCRIPT" <<'PYEOF'
import datetime
import glob
import json
import os
import re
import sqlite3
import subprocess
import sys

CREATE_TICKET_TOOL = "create_ticket"
SESSIONKEY_CONV_PREFIX = "agent:support:intercom:direct:"
SQLITE_TRAJECTORY_MIN_RUNTIME = (2026, 8)

# Vendored twin of the intent -> action_type_on_handoff table in
# plugins/support-tools/src/tools/support-action-router.ts (11 intents).
# billing_cancel_refund's route has NO fixed action_type on its failure
# branches (the agent picks billing-issue vs subscription-refund at
# create_ticket time), so both actionTypes map back to it.
ACTION_TYPE_TO_INTENT = {
    "analytics-followup": "analytics_data_complaint",
    "credit-verify": "credit_verification",
    "profile-claim": "profile_claim",
    "profile-merge": "profile_duplicates",
    "credit-correction": "remove_wrong_credits",
    "order-fulfillment": "order_fulfillment",
    "founding-member": "founding_member",
    "billing-issue": "billing_cancel_refund",
    "subscription-refund": "billing_cancel_refund",
    "catalog-metadata": "catalog_metadata_repair",
    "login-recovery": "login_email_verification",
    "profile-change": "account_profile_change",
}

# workspaces/support/SOUL.md "Acknowledge once, then go quiet" -- the exact
# bare-closer list Caroline's own no-reply signal is built from.
CLOSER_PHRASES = {
    "ok", "k", "thanks", "ty", "got it", "cool", "great", "perfect", "np",
    "no worries", "sounds good", "will do", "👍", "🙏",
}

CUSTOMER_AUTHOR_TYPES = {"user", "lead", "contact"}

# openclaw built-ins (never a support resolution signal) plus the routing
# dispatcher itself -- support_action_router fires on nearly every cohort-a
# candidate turn as a hop, not a resolution, so counting it as "a tool was
# called" swallowed almost every replied conversation into cohort a and
# starved cohort c (production: 146a/37b/0c/14d of 197 rows).
BUILTIN_EXCLUDE = {"read", "memory_search", "memory_get", "support_action_router"}


def load_valid_tool_names(path):
    """Support-tool names Caroline can actually resolve with, from
    caroline-inventory.json's .tools[].name, minus BUILTIN_EXCLUDE. Raises
    OSError/ValueError on an unreadable or malformed inventory file --
    callers must fail loud, never fall back to an unfiltered set. An empty
    result (inventory has no support tools left after the exclusion) is a
    warning, not a hard error."""
    with open(path, "r", encoding="utf-8") as fh:
        inv = json.load(fh)
    names = {t.get("name") for t in (inv.get("tools") or [])
             if isinstance(t, dict) and t.get("name")}
    names -= BUILTIN_EXCLUDE
    if not names:
        print("jev-backtest-caroline.sh: WARN caroline-inventory.json yielded zero valid "
              "support-tool names after excluding built-ins", file=sys.stderr)
    return names


def _norm_closer(text):
    t = (text or "").strip().lower()
    t = re.sub(r"[.!,;:\-\s]+$", "", t)
    t = re.sub(r"^[.!,;:\-\s]+", "", t)
    return t


def is_closer_text(text):
    return _norm_closer(text) in CLOSER_PHRASES


def passes_closer_guard(text):
    """Deterministic guard for the report's closer-restricted no_reply band:
    a bare SOUL.md closer phrase, or (no '?' and <=8 words) -- the same
    shape as the SOUL.md "acknowledge once, then go quiet" heuristic."""
    t = (text or "").strip()
    if is_closer_text(t):
        return True
    return "?" not in t and len(t.split()) <= 8


def month_ts(ts):
    """epoch seconds from an ISO8601-Z ts string, or None if unparseable."""
    if not ts:
        return None
    s = str(ts).strip()
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S.%fZ"):
        try:
            return datetime.datetime.strptime(s, fmt).replace(
                tzinfo=datetime.timezone.utc).timestamp()
        except ValueError:
            continue
    return None


def sessionkey_conv(session_key):
    if session_key and session_key.startswith(SESSIONKEY_CONV_PREFIX):
        return session_key[len(SESSIONKEY_CONV_PREFIX):]
    return None


# --------------------------------------------------------------------------
# Journal parsing
# --------------------------------------------------------------------------
REPLIED_RE = re.compile(r"replied conv=(\d+)")
ESCALATED_RE = re.compile(r"ESCALATED conv=(\d+) source=(rule|user_request) reason=(.+?)\s*$")
TICKET_RE = re.compile(r"\[intercom:escalation\] ticket created conv=(\d+) id=(\S+)")
HUMAN_REASON_RE = re.compile(r"dispute|chargeback|legal|deletion|fraud", re.I)
# journalctl -o short-unix line prefix: "<epoch>.<usec> host proc[pid]: msg".
JOURNAL_TS_RE = re.compile(r"^(\d+)\.\d+\s")


def parse_journal(path):
    """Returns (replied_ids:set, escalations:{conv_id:{source,reason,ts}},
    tickets:{conv_id:ticket_id}). ts is the epoch-seconds float parsed from
    the journalctl -o short-unix line prefix, or None if the line carried no
    parseable prefix (e.g. a test fixture in a different format)."""
    replied = set()
    escalations = {}
    tickets = {}
    try:
        fh = open(path, "r", encoding="utf-8", errors="replace")
    except OSError:
        return replied, escalations, tickets
    with fh:
        for line in fh:
            m = REPLIED_RE.search(line)
            if m:
                replied.add(m.group(1))
                continue
            m = ESCALATED_RE.search(line)
            if m:
                ts_m = JOURNAL_TS_RE.match(line)
                ts = float(ts_m.group(1)) if ts_m else None
                escalations[m.group(1)] = {"source": m.group(2), "reason": m.group(3), "ts": ts}
                continue
            m = TICKET_RE.search(line)
            if m:
                tickets[m.group(1)] = m.group(2)
    return replied, escalations, tickets


# --------------------------------------------------------------------------
# Trajectory sweep -- generalized port of scripts/cs-selfserve-backlog.py's
# JSONL/SQLite source resolution. Unlike that collector (which only counts
# create_ticket), this one needs EVERY tool.call event per conversation to
# find the first tool Caroline actually called.
# --------------------------------------------------------------------------
def ingest_record(rec, per_conv):
    if not isinstance(rec, dict):
        return
    if rec.get("type") != "tool.call":
        return
    data = rec.get("data") or {}
    name = data.get("name")
    if not name:
        return
    conv = sessionkey_conv(rec.get("sessionKey"))
    if not conv:
        return
    ts = month_ts(rec.get("ts"))
    entry = per_conv.setdefault(conv, {"events": []})
    action_type = None
    if name == CREATE_TICKET_TOOL:
        action_type = (data.get("arguments") or {}).get("actionType")
    entry["events"].append({"ts": ts if ts is not None else 0.0, "name": name,
                             "action_type": action_type})


def sweep_files(paths):
    per_conv = {}
    for path in paths:
        try:
            f = open(path, "r", encoding="utf-8", errors="replace")
        except OSError:
            continue
        with f:
            for line in f:
                if '"tool.call"' not in line:
                    continue  # speed-only pre-filter, never a correctness filter
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue  # malformed/torn line -- skip, never abort
                ingest_record(rec, per_conv)
    return per_conv


def sweep_sqlite(db_paths):
    per_conv = {}
    for db_path in db_paths:
        try:
            con = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True)
        except sqlite3.Error:
            continue
        try:
            rows = con.execute(
                "select event_json from trajectory_runtime_events "
                "where instr(event_json, ?) > 0 order by session_id, seq",
                ('"tool.call"',))
            for (event_json,) in rows:
                try:
                    rec = json.loads(event_json)
                except (ValueError, TypeError):
                    continue
                ingest_record(rec, per_conv)
        except sqlite3.Error:
            continue  # unreadable/locked/no such table -- skip this store
        finally:
            con.close()
    return per_conv


def openclaw_runtime_version():
    try:
        out = subprocess.run(["openclaw", "--version"], capture_output=True,
                              text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    m = re.search(r"(\d{4})\.(\d+)", out.stdout or "")
    if not m:
        return None
    return (int(m.group(1)), int(m.group(2)))


def resolve_trajectory(cfg):
    """Returns per_conv dict: conv_id -> {"events": [{"ts","name","action_type"}]}."""
    forced = (cfg.get("traj_source") or "auto").strip().lower()
    glob_pattern = cfg.get("traj_glob") or ""
    db_paths = [d for d in (cfg.get("traj_dbs") or "").split(":") if d]

    if forced == "jsonl":
        mode = "jsonl"
    elif forced == "sqlite":
        mode = "sqlite"
    elif forced == "auto":
        ver = openclaw_runtime_version()
        mode = "sqlite" if (ver is not None and ver >= SQLITE_TRAJECTORY_MIN_RUNTIME) else "jsonl"
    else:
        mode = "jsonl"

    if mode == "sqlite":
        return sweep_sqlite(db_paths)
    paths = sorted(glob.glob(glob_pattern)) if glob_pattern else []
    return sweep_files(paths)


# --------------------------------------------------------------------------
# subcommand: sample
# --------------------------------------------------------------------------
def cmd_sample(argv):
    with open(argv[0], "r", encoding="utf-8") as fh:
        cfg = json.load(fh)

    replied, escalations, _tickets = parse_journal(cfg["journal_file"])
    troll_id = cfg["troll_id"]
    days = cfg.get("days", 14)
    cutoff = None
    if days:
        cutoff = datetime.datetime.now(datetime.timezone.utc).timestamp() - float(days) * 86400

    per_conv = resolve_trajectory(cfg)
    try:
        valid_tools = load_valid_tool_names(cfg["inventory_file"])
    except (OSError, ValueError) as exc:
        print(f"jev-backtest-caroline.sh: inventory file unreadable/malformed: "
              f"{cfg.get('inventory_file')}: {exc}", file=sys.stderr)
        return 2

    cohort_b_ids = set()
    cohort_b_info = {}
    for conv_id, info in escalations.items():
        if conv_id == troll_id:
            continue
        source = info.get("source")
        reason = info.get("reason") or ""
        # Only a content reason (legal/dispute/chargeback/deletion/fraud) is a
        # genuine human_required signal -- a bare source=user_request
        # escalation is handled by the keyword layer before Jev ever sees it,
        # so it is sampled for the informational human_required-p
        # distribution but never labeled resolution_path=human_required.
        content = bool(source == "rule" and HUMAN_REASON_RE.search(reason))
        if source == "user_request" or content:
            cohort_b_ids.add(conv_id)
            cohort_b_info[conv_id] = {"reason": reason, "source": source,
                                       "ts": info.get("ts"), "content": content}

    cohort_a = []
    for conv_id, entry in sorted(per_conv.items()):
        if conv_id == troll_id or conv_id in cohort_b_ids:
            continue
        events = [e for e in entry["events"]
                  if (cutoff is None or e["ts"] >= cutoff) and e["name"] in valid_tools]
        if not events:
            continue
        events.sort(key=lambda e: e["ts"])
        first_tool = events[0]["name"]
        intent = None
        for e in events:
            if e["name"] == CREATE_TICKET_TOOL and e.get("action_type"):
                intent = ACTION_TYPE_TO_INTENT.get(e["action_type"])
                break
        cohort_a.append({"conv_id": conv_id, "first_tool": first_tool,
                          "intent": intent, "_ts": events[0]["ts"]})
    cohort_a.sort(key=lambda r: r["_ts"])
    cap_a = int(cfg.get("cap_a", 5))
    cohort_a = cohort_a[:cap_a]
    for r in cohort_a:
        r.pop("_ts", None)

    cohort_a_ids = {r["conv_id"] for r in cohort_a}

    cohort_b = []
    cap_b = int(cfg.get("cap_b", 5))
    for conv_id in sorted(cohort_b_ids)[:cap_b]:
        cohort_b.append({"conv_id": conv_id, **cohort_b_info[conv_id]})

    cohort_b_capped_ids = {r["conv_id"] for r in cohort_b}
    cohort_c_candidates = sorted(
        c for c in replied
        if c != troll_id and c not in cohort_a_ids and c not in cohort_b_capped_ids
    )

    print(json.dumps({
        "cohort_a": cohort_a,
        "cohort_b": cohort_b,
        "cohort_c_candidates": cohort_c_candidates,
        "troll_id": troll_id,
    }))
    return 0


# --------------------------------------------------------------------------
# subcommand: closer-check
# --------------------------------------------------------------------------
def load_conv_parts(conv_json):
    """Ordered list of {role: customer|admin, text, ts} from one Intercom
    conversation payload (display_as=plaintext shape, same as
    fetch-conversations.sh). Empty-body parts are dropped."""
    parts = []

    def role_of(author):
        t = (author or {}).get("type") or ""
        return "customer" if t in CUSTOMER_AUTHOR_TYPES else "admin"

    source = conv_json.get("source") or {}
    if (source.get("body") or "").strip():
        parts.append({"role": role_of(source.get("author")), "text": source.get("body") or "",
                       "ts": source.get("created_at") or 0})
    for p in ((conv_json.get("conversation_parts") or {}).get("conversation_parts") or []):
        if not isinstance(p, dict):
            continue
        if (p.get("body") or "").strip():
            parts.append({"role": role_of(p.get("author")), "text": p.get("body") or "",
                           "ts": p.get("created_at") or 0})
    return parts


def cmd_closer_check(argv):
    conv_dir, fetched_list_path, cap_c = argv[0], argv[1], int(argv[2])
    accepted = []
    try:
        with open(fetched_list_path, "r", encoding="utf-8") as fh:
            candidate_ids = [line.strip() for line in fh if line.strip()]
    except OSError:
        candidate_ids = []
    for conv_id in sorted(candidate_ids):
        if len(accepted) >= cap_c:
            break
        path = os.path.join(conv_dir, f"{conv_id}.json")
        try:
            with open(path, "r", encoding="utf-8") as fh:
                conv_json = json.load(fh)
        except (OSError, ValueError):
            continue
        parts = load_conv_parts(conv_json)
        if not parts:
            continue
        last = parts[-1]
        if last["role"] == "customer" and is_closer_text(last["text"]):
            accepted.append(conv_id)
    for conv_id in accepted:
        print(conv_id)
    return 0


# --------------------------------------------------------------------------
# subcommand: turns
# --------------------------------------------------------------------------
def _trim(text, n=500):
    text = text or ""
    return text if len(text) <= n else text[:n]


def cmd_turns(argv):
    conv_path, cohort, label_json = argv[0], argv[1], argv[2]
    with open(conv_path, "r", encoding="utf-8") as fh:
        conv_json = json.load(fh)
    label_extra = json.loads(label_json) if label_json else {}
    parts = load_conv_parts(conv_json)

    customer_indices = [i for i, p in enumerate(parts) if p["role"] == "customer"]
    n_customer = len(customer_indices)

    # Which customer turn each cohort's evidence actually names:
    #   a: the FIRST customer turn -- the request that led to the tool call.
    #      The LAST turn of a resolved conversation is routinely a bare
    #      "thanks"/"ok" close, which Jev correctly answers no_reply, not
    #      caroline_tool -- labeling it caroline_tool was measuring the
    #      wrong turn.
    #   b: the customer turn immediately BEFORE the ESCALATED journal
    #      timestamp (greatest part created_at <= escalation_ts); falls back
    #      to the last customer turn when no escalation_ts is available or
    #      no part qualifies.
    #   c: the last customer turn -- the closer message itself.
    target_turn = None
    if cohort == "a" and n_customer:
        target_turn = 1
    elif cohort == "b" and n_customer:
        target_turn = n_customer
        escalation_ts = label_extra.get("escalation_ts")
        if escalation_ts is not None:
            best = None
            for turn_no, idx in enumerate(customer_indices, start=1):
                if (parts[idx].get("ts") or 0) <= escalation_ts:
                    best = turn_no
            if best is not None:
                target_turn = best
    elif cohort == "c" and n_customer:
        target_turn = n_customer

    out = []
    for turn_no, idx in enumerate(customer_indices, start=1):
        prior = parts[max(0, idx - 10):idx]
        state = {
            "message": parts[idx]["text"],
            "last_parts": [{"author": p["role"], "text": _trim(p["text"])} for p in prior],
            "turn_count": turn_no,
        }
        label = {"resolution_path": None, "first_tool": None, "intent": None,
                  "bad_faith": False, "no_reply": False, "human_required": False,
                  "user_request_turn": False}
        if cohort == "a" and turn_no == target_turn:
            label["resolution_path"] = "caroline_tool"
            label["first_tool"] = label_extra.get("first_tool")
            label["intent"] = label_extra.get("intent")
        elif cohort == "b" and turn_no == target_turn:
            if label_extra.get("content"):
                label["resolution_path"] = "human_required"
                label["human_required"] = True
            else:
                # source=user_request: the keyword layer, not Jev, handled
                # this -- sampled for the informational distribution only.
                label["user_request_turn"] = True
        elif cohort == "c" and turn_no == target_turn:
            label["resolution_path"] = "no_reply"
            label["no_reply"] = True
        elif cohort == "d":
            label["bad_faith"] = turn_no >= 4
        out.append({"turn": turn_no, "state": state, "label": label})
    print(json.dumps(out))
    return 0


# --------------------------------------------------------------------------
# subcommand: report
# --------------------------------------------------------------------------
THRESHOLDS = [round(0.5 + 0.05 * i, 2) for i in range(10)]  # 0.50 .. 0.95


def _prob_ok(p):
    import math
    return isinstance(p, (int, float)) and not isinstance(p, bool) and math.isfinite(p) and 0.0 <= p <= 1.0


def choice_top(ans):
    if not isinstance(ans, dict) or ans.get("type") != "choice":
        return None, None
    choice = ans.get("choice")
    probs = ans.get("probabilities")
    p = probs.get(choice) if isinstance(probs, dict) else None
    if choice is None or not _prob_ok(p):
        return None, None
    return choice, p


def choice_prob_of(ans, key):
    if not isinstance(ans, dict) or ans.get("type") != "choice":
        return None
    probs = ans.get("probabilities")
    if not isinstance(probs, dict):
        return None
    p = probs.get(key)
    return p if _prob_ok(p) else None


def noul_true_prob(ans):
    if not isinstance(ans, dict) or ans.get("type") != "noul":
        return None
    p = ans.get("noul")
    return p if _prob_ok(p) else None


def band_recommendation(rows_with_label_prob):
    """rows_with_label_prob: list of (label_bool, prob). Returns
    (threshold_or_None, fp_at_best, recall_str)."""
    best = None
    for t in THRESHOLDS:
        fp = sum(1 for label, p in rows_with_label_prob if (not label) and p is not None and p >= t)
        if fp == 0:
            tp = sum(1 for label, p in rows_with_label_prob if label and p is not None and p >= t)
            fn = sum(1 for label, p in rows_with_label_prob if label and p is not None and p < t)
            recall = "n/a" if (tp + fn) == 0 else f"{round(100 * tp / (tp + fn), 1)}%"
            best = (t, 0, recall)
            break
    if best is None:
        t = THRESHOLDS[-1]
        fp = sum(1 for label, p in rows_with_label_prob if (not label) and p is not None and p >= t)
        best = (None, fp, "n/a")
    return best


def cmd_report(argv):
    rows_path, report_out = argv[0], argv[1]
    rows = []
    malformed = 0
    try:
        fh = open(rows_path, "r", encoding="utf-8")
    except OSError:
        fh = None
    if fh:
        with fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except ValueError:
                    malformed += 1
                    continue
                if not isinstance(row, dict):
                    malformed += 1
                    continue
                rows.append(row)

    lines = []
    lines.append("# Jev Caroline backtest report")
    lines.append("")
    lines.append(f"rows: {len(rows)} (malformed skipped: {malformed})")
    lines.append("")

    # -- per-question agreement where a label exists --
    lines.append("## Per-question agreement")
    resolution_agree = {"n": 0, "match": 0}
    tool_agree = {"n": 0, "match": 0}
    intent_agree = {"n": 0, "match": 0}
    bad_faith_agree = {"n": 0, "match": 0}

    cohort_confusion = {}  # cohort -> {expected: {predicted: n}}

    bad_faith_pairs = []
    no_reply_pairs = []
    closer_guard_no_reply_pairs = []
    no_reply_false_positives = []
    human_required_pairs = []
    user_request_hr_probs = []
    troll_rows = []

    for row in rows:
        if row.get("rc"):
            continue
        answers = row.get("answers")
        if not isinstance(answers, dict):
            continue
        label = row.get("label") or {}
        cohort = row.get("cohort")

        rp_choice, _rp_p = choice_top(answers.get("resolution_path") or {})
        expected_rp = label.get("resolution_path")
        if expected_rp:
            resolution_agree["n"] += 1
            if rp_choice == expected_rp:
                resolution_agree["match"] += 1
            bucket = cohort_confusion.setdefault(cohort, {})
            bucket.setdefault(expected_rp, {})
            bucket[expected_rp][rp_choice or "none"] = bucket[expected_rp].get(rp_choice or "none", 0) + 1

        if label.get("first_tool"):
            ft_choice, _ = choice_top(answers.get("first_tool") or {})
            tool_agree["n"] += 1
            if ft_choice == label.get("first_tool"):
                tool_agree["match"] += 1

        if label.get("intent"):
            in_choice, _ = choice_top(answers.get("intent") or {})
            intent_agree["n"] += 1
            if in_choice == label.get("intent"):
                intent_agree["match"] += 1

        bf_p = noul_true_prob(answers.get("off_topic_or_bad_faith") or {})
        bf_label = bool(label.get("bad_faith"))
        if bf_p is not None:
            bad_faith_agree["n"] += 1
            predicted = bf_p >= 0.5
            if predicted == bf_label:
                bad_faith_agree["match"] += 1
            bad_faith_pairs.append((bf_label, bf_p))

        message = row.get("message") or ""

        nr_p = choice_prob_of(answers.get("resolution_path") or {}, "no_reply")
        if nr_p is not None:
            no_reply_pairs.append((bool(label.get("no_reply")), nr_p))
            if nr_p >= 0.6 and ("?" in message or len(message.split()) > 8):
                no_reply_false_positives.append((row.get("conv_id"), row.get("turn"), nr_p, _trim(message, 60)))
            if passes_closer_guard(message):
                closer_guard_no_reply_pairs.append((bool(label.get("no_reply")), nr_p))

        hr_p = choice_prob_of(answers.get("resolution_path") or {}, "human_required")
        if hr_p is not None:
            human_required_pairs.append((bool(label.get("human_required")), hr_p))
            if label.get("user_request_turn"):
                user_request_hr_probs.append(hr_p)

        if cohort == "d":
            troll_rows.append((row.get("turn"), bf_p, bf_label))

    def pct(agree):
        return "n/a" if agree["n"] == 0 else f"{round(100 * agree['match'] / agree['n'], 1)}% (n={agree['n']})"

    lines.append(f"- resolution_path: {pct(resolution_agree)}")
    lines.append(f"- first_tool: {pct(tool_agree)}")
    lines.append(f"- intent: {pct(intent_agree)}")
    lines.append(f"- off_topic_or_bad_faith: {pct(bad_faith_agree)}")
    lines.append("")

    lines.append("## resolution_path confusion per cohort")
    for cohort in sorted(cohort_confusion):
        lines.append(f"- cohort {cohort}:")
        for expected, preds in cohort_confusion[cohort].items():
            pred_str = ", ".join(f"{k}={v}" for k, v in sorted(preds.items()))
            lines.append(f"  - expected={expected}: {pred_str}")
    lines.append("")

    lines.append("## Troll conversation (215476013943381) off_topic_or_bad_faith per message")
    for turn, p, label in sorted(troll_rows, key=lambda r: (r[0] is None, r[0])):
        p_str = "n/a" if p is None else f"{p:.2f}"
        lines.append(f"- turn {turn}: p={p_str} label={label}")
    lines.append("")

    lines.append("## Recommended bands")
    for name, pairs in (("bad_faith", bad_faith_pairs), ("no_reply", no_reply_pairs),
                        ("human_required", human_required_pairs)):
        t, fp, recall = band_recommendation(pairs)
        if t is None:
            lines.append(f"- {name}: no threshold in {THRESHOLDS[0]}-{THRESHOLDS[-1]} achieves zero false "
                          f"positives (best fp={fp} at {THRESHOLDS[-1]}); recommend manual review")
        else:
            lines.append(f"- {name}: {t} (fp=0, recall={recall})")
    t_cg, fp_cg, recall_cg = band_recommendation(closer_guard_no_reply_pairs)
    if t_cg is None:
        lines.append(f"- no_reply (closer-guard restricted): no threshold in {THRESHOLDS[0]}-{THRESHOLDS[-1]} "
                      f"achieves zero false positives (best fp={fp_cg} at {THRESHOLDS[-1]}); recommend manual review")
    else:
        lines.append(f"- no_reply (closer-guard restricted): {t_cg} (fp=0, recall={recall_cg})")
    lines.append("")

    lines.append("## no_reply false positives (p>=0.6, message has '?' or >8 words)")
    if no_reply_false_positives:
        for conv_id, turn, p, snippet in sorted(no_reply_false_positives, key=lambda r: (r[0] is None, r[0], r[1])):
            lines.append(f"- conv={conv_id} turn={turn}: p={p:.2f} \"{snippet}\"")
    else:
        lines.append("- none")
    lines.append("")

    lines.append("## user_request turns: Jev human_required p distribution")
    if user_request_hr_probs:
        srt = sorted(user_request_hr_probs)
        n = len(srt)
        mid = n // 2
        median = srt[mid] if n % 2 == 1 else (srt[mid - 1] + srt[mid]) / 2
        lines.append(f"- n={n} min={srt[0]:.2f} median={median:.2f} max={srt[-1]:.2f}")
    else:
        lines.append("- n=0 (no user_request turns sampled)")
    lines.append("")

    text = "\n".join(lines) + "\n"
    with open(report_out, "w", encoding="utf-8") as fh:
        fh.write(text)
    sys.stdout.write(text)
    return 0


def main():
    if len(sys.argv) < 2:
        print("usage: lib.py <sample|closer-check|turns|report> ...", file=sys.stderr)
        return 2
    sub = sys.argv[1]
    argv = sys.argv[2:]
    if sub == "sample":
        return cmd_sample(argv)
    if sub == "closer-check":
        return cmd_closer_check(argv)
    if sub == "turns":
        return cmd_turns(argv)
    if sub == "report":
        return cmd_report(argv)
    print(f"unknown subcommand: {sub}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())

PYEOF

# Per-cohort caps summing to ~limit: 1 fixed for the troll reference (d),
# then a/b/c split ~40/35/25 of the remainder, floored at 5 each ("at least
# 5 per cohort where available" -- a target ceiling, not a hard minimum when
# fewer candidates exist).
remaining=$((limit > 1 ? limit - 1 : 1))
cap_a=$(( remaining * 40 / 100 )); [ "$cap_a" -ge 5 ] || cap_a=5
cap_b=$(( remaining * 35 / 100 )); [ "$cap_b" -ge 5 ] || cap_b=5
cap_c=$(( remaining - cap_a - cap_b )); [ "$cap_c" -ge 5 ] || cap_c=5

# ── 1. edge journal ──────────────────────────────────────────
journal_file="$work_dir/journal.log"
if [ -n "${CAROLINE_BACKTEST_JOURNAL_FILE:-}" ]; then
  cat "$CAROLINE_BACKTEST_JOURNAL_FILE" > "$journal_file"
else
  journalctl -u "$CAROLINE_BACKTEST_EDGE_UNIT" --since "${days} days ago" --no-pager -o short-unix \
    > "$journal_file" 2>/dev/null || : > "$journal_file"
fi

# ── 2. sample cohorts a/b (pure, no network) + cohort c candidate seed ──
sample_config="$work_dir/sample-config.json"
jq -n \
  --arg journal_file "$journal_file" \
  --arg troll_id "$TROLL_CONV_ID" \
  --argjson days "$days" \
  --argjson cap_a "$cap_a" \
  --argjson cap_b "$cap_b" \
  --argjson cap_c "$cap_c" \
  --arg traj_source "$CAROLINE_BACKTEST_TRAJECTORY_SOURCE" \
  --arg traj_glob "$CAROLINE_BACKTEST_TRAJECTORY_GLOB" \
  --arg traj_dbs "$CAROLINE_BACKTEST_TRAJECTORY_DBS" \
  --arg inventory_file "$CAROLINE_BACKTEST_INVENTORY_FILE" \
  '{journal_file:$journal_file, troll_id:$troll_id, days:$days,
    cap_a:$cap_a, cap_b:$cap_b, cap_c:$cap_c,
    traj_source:$traj_source, traj_glob:$traj_glob, traj_dbs:$traj_dbs,
    inventory_file:$inventory_file}' \
  > "$sample_config"

sample_out="$work_dir/sample.json"
python3 "$PY_SCRIPT" sample "$sample_config" > "$sample_out"

cohort_a_ids=$(jq -r '.cohort_a[].conv_id' "$sample_out")
cohort_b_ids=$(jq -r '.cohort_b[].conv_id' "$sample_out")
cohort_c_candidate_ids=$(jq -r '.cohort_c_candidates[]' "$sample_out")

if [ -z "$cohort_a_ids" ] && [ -z "$cohort_b_ids" ] && [ -z "$cohort_c_candidate_ids" ]; then
  _bt_die 3 "no candidates found in any cohort (journal window: ${days}d) -- nothing to sample"
fi

# ── 3. Intercom token ────────────────────────────────────────
if [ -z "${MUSOAI_INTERCOM_TOKEN:-}" ] && [ -r "$CAROLINE_BACKTEST_INTERCOM_ENV_FILE" ]; then
  MUSOAI_INTERCOM_TOKEN="$(grep -m1 '^MUSOAI_INTERCOM_TOKEN=' "$CAROLINE_BACKTEST_INTERCOM_ENV_FILE" 2>/dev/null | cut -d= -f2-)"
fi
[ -n "${MUSOAI_INTERCOM_TOKEN:-}" ] || _bt_die 2 "MUSOAI_INTERCOM_TOKEN not set and not found in $CAROLINE_BACKTEST_INTERCOM_ENV_FILE"
INTERCOM_API="${CAROLINE_BACKTEST_INTERCOM_API:-https://api.intercom.io}"

# _bt_intercom_get <conv_id> <out_file>: GET one conversation, plaintext,
# with a short 429/5xx backoff (max 3 attempts). Never mutates Intercom.
_bt_intercom_get() {
  local conv_id="$1" out_file="$2" attempt=0 code
  while [ "$attempt" -lt 3 ]; do
    code=$(curl -sS -o "$out_file" -w '%{http_code}' \
      -H "Authorization: Bearer $MUSOAI_INTERCOM_TOKEN" \
      -H "Intercom-Version: 2.11" -H "Accept: application/json" \
      "$INTERCOM_API/conversations/${conv_id}?display_as=plaintext") || code="000"
    case "$code" in
      2*) return 0 ;;
      429|5*) attempt=$((attempt + 1)); sleep $((1 << attempt)) ;;
      *) return 1 ;;
    esac
  done
  return 1
}

# _bt_intercom_search_ids <since_epoch>: candidate conversation ids updated
# since $1, mirroring fetch-conversations.sh's build_query/pagination
# (broad updated_at query, no assignee filter -- a conversation Caroline
# handled and a human later reassigned must still be visible to cohort c).
#
# FAILS CLOSED (exit 4), never "returns no ids": an expired token, a 5xx, a
# dead connection and a body that is not the documented search shape are all
# indistinguishable from "no conversations matched" if the status is ignored,
# and a report computed from an empty sample still reads as a clean run whose
# band recommendations decide what ships to customers. A response we cannot
# parse is a failure, not an empty result.
_bt_intercom_search_ids() {
  local since="$1" cursor="" page=0 code
  local resp_file="$work_dir/search-resp.json"
  while [ "$page" -lt 3 ]; do
    local pagination='{"per_page":150}'
    [ -n "$cursor" ] && pagination="{\"per_page\":150,\"starting_after\":\"$cursor\"}"
    local body
    body=$(jq -nc --argjson since "$since" --argjson pagination "$pagination" \
      '{query:{field:"updated_at", operator:">", value:$since}, pagination:$pagination}')
    : > "$resp_file"
    code=$(curl -sS -X POST -o "$resp_file" -w '%{http_code}' \
      -H "Authorization: Bearer $MUSOAI_INTERCOM_TOKEN" \
      -H "Intercom-Version: 2.11" -H "Content-Type: application/json" \
      -H "Accept: application/json" -d "$body" "$INTERCOM_API/conversations/search") || code="000"
    case "$code" in
      2*) ;;
      000|'') _bt_die 4 "Intercom conversation search: transport failure (curl could not complete the request, page ${page}) -- refusing to sample from an unknown result set" ;;
      401|403) _bt_die 4 "Intercom conversation search: credential rejected (HTTP $code, page ${page}) -- MUSOAI_INTERCOM_TOKEN is expired or lacks scope; refusing to report on an empty/partial sample" ;;
      *) _bt_die 4 "Intercom conversation search: HTTP $code (page ${page}) -- refusing to report on an empty/partial sample" ;;
    esac
    jq -e 'type == "object" and (.conversations | type == "array")' "$resp_file" >/dev/null 2>&1 \
      || _bt_die 4 "Intercom conversation search: response is not the expected {\"conversations\":[...]} shape (HTTP $code, page ${page}) -- an unparseable response is a failure, not an empty result"
    jq -r '.conversations[] | select(.id != null) | .id | tostring' "$resp_file"
    cursor=$(jq -r '.pages.next.starting_after // empty' "$resp_file")
    [ -z "$cursor" ] && break
    page=$((page + 1))
  done
}

# ── 4. cohort c: search candidates minus a/b/troll, then GET + closer check ──
now_epoch=$(date +%s)
since_epoch=$((now_epoch - days * 86400))
search_ids_file="$work_dir/search-ids.txt"
# No `|| : > "$search_ids_file"` fallback: that is what turned every search
# failure into a valid-looking empty result. Kept out of a pipeline too --
# _bt_die's exit would then run in a subshell and reach the script only via
# `set -o pipefail`, which is a load-bearing dependency this does not need.
search_ids_raw="$work_dir/search-ids.raw.txt"
_bt_intercom_search_ids "$since_epoch" > "$search_ids_raw"
sort -u "$search_ids_raw" > "$search_ids_file"

conv_dir="$work_dir/convs"
mkdir -p "$conv_dir"

cohort_c_seed_file="$work_dir/cohort-c-seed.txt"
comm -23 \
  "$search_ids_file" \
  <(printf '%s\n%s\n%s\n' "$cohort_a_ids" "$cohort_b_ids" "$TROLL_CONV_ID" | sort -u) \
  > "$cohort_c_seed_file"
# Fold in the sampler's own journal-derived candidates (a conversation the
# journal saw as replied-with-no-escalation is a valid closer candidate even
# if the search window/cursor missed it -- search and journal are two
# independently-lossy views of the same window).
printf '%s\n' "$cohort_c_candidate_ids" >> "$cohort_c_seed_file"
sort -u -o "$cohort_c_seed_file" "$cohort_c_seed_file"

# GET up to cap_c * 5 seed candidates (bounds API load); the closer check
# below keeps at most cap_c real members.
fetch_budget=$((cap_c * 5))
fetched=0
: > "$work_dir/cohort-c-fetched.txt"
while IFS= read -r cid; do
  [ -n "$cid" ] || continue
  [ "$fetched" -ge "$fetch_budget" ] && break
  if _bt_intercom_get "$cid" "$conv_dir/${cid}.json"; then
    echo "$cid" >> "$work_dir/cohort-c-fetched.txt"
    fetched=$((fetched + 1))
  fi
done < "$cohort_c_seed_file"

cohort_c_final_ids=$(python3 "$PY_SCRIPT" closer-check "$conv_dir" "$work_dir/cohort-c-fetched.txt" "$cap_c")

# ── 5. cap a/b to their limits ───────────────────────────────
cohort_a_ids=$(echo "$cohort_a_ids" | head -n "$cap_a")
cohort_b_ids=$(echo "$cohort_b_ids" | head -n "$cap_b")

# ── 6. print the sample plan ─────────────────────────────────
echo "== jev-backtest-caroline sample plan (days=${days} limit=${limit}) =="
printf '%-18s %-10s %s\n' "conv_id" "cohort" "label"
while IFS= read -r cid; do
  [ -n "$cid" ] || continue
  tool=$(jq -r --arg c "$cid" '.cohort_a[] | select(.conv_id==$c) | .first_tool // "none"' "$sample_out")
  intent=$(jq -r --arg c "$cid" '.cohort_a[] | select(.conv_id==$c) | .intent // "none"' "$sample_out")
  printf '%-18s %-10s resolution_path=caroline_tool first_tool=%s intent=%s\n' "$cid" "a" "$tool" "$intent"
done <<< "$cohort_a_ids"
while IFS= read -r cid; do
  [ -n "$cid" ] || continue
  reason=$(jq -r --arg c "$cid" '.cohort_b[] | select(.conv_id==$c) | .reason // "unknown"' "$sample_out" | cut -c1-40)
  content=$(jq -r --arg c "$cid" '.cohort_b[] | select(.conv_id==$c) | .content' "$sample_out")
  if [ "$content" = "true" ]; then
    printf '%-18s %-10s resolution_path=human_required reason=%s\n' "$cid" "b" "$reason"
  else
    printf '%-18s %-10s resolution_path=null (user_request, keyword-layer handled) reason=%s\n' "$cid" "b" "$reason"
  fi
done <<< "$cohort_b_ids"
while IFS= read -r cid; do
  [ -n "$cid" ] || continue
  printf '%-18s %-10s resolution_path=no_reply (closer)\n' "$cid" "c"
done <<< "$cohort_c_final_ids"
printf '%-18s %-10s off_topic_or_bad_faith=true from customer message 4\n' "$TROLL_CONV_ID" "d"
echo

if [ "$dry_run" -eq 1 ]; then
  echo "jev-backtest-caroline.sh: --dry-run, no Intercom transcript fetch or Jev call made" >&2
  exit 0
fi

[ -r "$questions_file" ] || _bt_die 2 "questions file not readable: $questions_file"

# ── 7. fetch remaining conversation content ──────────────────
while IFS= read -r cid; do
  [ -n "$cid" ] || continue
  [ -f "$conv_dir/${cid}.json" ] && continue
  _bt_intercom_get "$cid" "$conv_dir/${cid}.json" || echo "jev-backtest-caroline.sh: WARN could not fetch conv=$cid" >&2
done <<< "$(printf '%s\n%s\n%s\n' "$cohort_a_ids" "$cohort_b_ids" "$TROLL_CONV_ID")"

# ── 8. replay every customer turn through jev.sh ─────────────
rows_raw="$work_dir/rows.raw.jsonl"
: > "$rows_raw"

_bt_replay_conv() {
  local cid="$1" cohort="$2" label_json="$3"
  [ -f "$conv_dir/${cid}.json" ] || { echo "jev-backtest-caroline.sh: WARN no transcript for conv=$cid, skipping" >&2; return 0; }
  local turns_file="$work_dir/turns-${cid}.json"
  python3 "$PY_SCRIPT" turns "$conv_dir/${cid}.json" "$cohort" "$label_json" > "$turns_file" \
    || { echo "jev-backtest-caroline.sh: WARN could not build turns for conv=$cid" >&2; return 0; }
  local n
  n=$(jq 'length' "$turns_file")
  local i=0
  while [ "$i" -lt "$n" ]; do
    local state_file="$work_dir/state-${cid}-${i}.json"
    jq -c ".[$i].state" "$turns_file" > "$state_file"
    local turn_label answers rc
    turn_label=$(jq -c ".[$i].label" "$turns_file")
    set +e
    answers=$("$CAROLINE_BACKTEST_JEV_SH" --surface backtest --item-id "${cid}-$((i + 1))" \
      --state-file "$state_file" --questions-file "$questions_file" --no-shadow 2>/dev/null)
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      jq -nc --arg conv "$cid" --arg cohort "$cohort" --argjson turn "$((i + 1))" \
        --argjson label "$turn_label" --argjson rc "$rc" \
        '{conv_id:$conv, cohort:$cohort, turn:$turn, label:$label, answers:null, rc:$rc}' >> "$rows_raw"
    else
      jq -nc --arg conv "$cid" --arg cohort "$cohort" --argjson turn "$((i + 1))" \
        --argjson label "$turn_label" --argjson answers "$answers" \
        --slurpfile state "$state_file" \
        '{conv_id:$conv, cohort:$cohort, turn:$turn, label:$label, answers:$answers,
          rc:0, message:$state[0].message}' >> "$rows_raw"
    fi
    i=$((i + 1))
  done
}

while IFS= read -r cid; do
  [ -n "$cid" ] || continue
  tool=$(jq -r --arg c "$cid" '.cohort_a[] | select(.conv_id==$c) | .first_tool // "none"' "$sample_out")
  intent=$(jq -r --arg c "$cid" '.cohort_a[] | select(.conv_id==$c) | .intent' "$sample_out")
  label=$(jq -nc --arg tool "$tool" --arg intent "$intent" \
    '{first_tool:$tool, intent:(if $intent=="null" or $intent=="" then null else $intent end)}')
  _bt_replay_conv "$cid" a "$label"
done <<< "$cohort_a_ids"

while IFS= read -r cid; do
  [ -n "$cid" ] || continue
  b_label=$(jq -c --arg c "$cid" \
    '.cohort_b[] | select(.conv_id==$c) | {escalation_ts: .ts, content: .content}' "$sample_out")
  [ -n "$b_label" ] || b_label='{}'
  _bt_replay_conv "$cid" b "$b_label"
done <<< "$cohort_b_ids"

while IFS= read -r cid; do
  [ -n "$cid" ] || continue
  _bt_replay_conv "$cid" c '{}'
done <<< "$cohort_c_final_ids"

_bt_replay_conv "$TROLL_CONV_ID" d '{}'

# ── 8b. sample-coverage gate ─────────────────────────────────
# Every transcript failure downstream of sampling is non-fatal on its own: a
# GET that 404s only WARNs, and _bt_replay_conv skips a conversation with no
# transcript. Without this gate those warnings add up to a report.md computed
# from a handful of rows -- or none -- that still reads like a clean run and
# still prints band recommendations, which are what decides what ships to
# customers. So the counts are asserted here, before anything is written.
#
# Threshold: 80% (CAROLINE_BACKTEST_MIN_FETCH_PCT). The per-id GET already
# retries 429/5xx with backoff, so the only loss we expect to be legitimate is
# a conversation deleted between the search and the GET -- rare and unrelated
# across ids. Losing more than one in five sampled conversations is therefore
# a systemic fault (token, outage, wrong workspace), not attrition. Zero is
# always fatal: ceil() of any percentage of a non-empty sample is >= 1.
sampled_ids_file="$work_dir/sampled-ids.txt"
printf '%s\n%s\n%s\n%s\n' \
  "$cohort_a_ids" "$cohort_b_ids" "$cohort_c_final_ids" "$TROLL_CONV_ID" \
  | grep . | sort -u > "$sampled_ids_file" || : > "$sampled_ids_file"

sampled_convs=$(grep -c . "$sampled_ids_file" || true)
fetched_convs=0
while IFS= read -r cid; do
  if [ -s "$conv_dir/${cid}.json" ]; then fetched_convs=$((fetched_convs + 1)); fi
done < "$sampled_ids_file"
replayed_convs=$(jq -r '.conv_id' "$rows_raw" | grep . | sort -u | grep -c . || true)

# ceil(sampled * pct / 100)
min_convs=$(( (sampled_convs * CAROLINE_BACKTEST_MIN_FETCH_PCT + 99) / 100 ))
if [ "$replayed_convs" -eq 0 ]; then
  _bt_die 5 "no conversation was replayed: sampled=${sampled_convs} fetched=${fetched_convs} replayed=0 -- refusing to write a report from an empty sample"
fi
if [ "$replayed_convs" -lt "$min_convs" ]; then
  _bt_die 5 "sample coverage too low: sampled=${sampled_convs} fetched=${fetched_convs} replayed=${replayed_convs} (need >=${min_convs}, CAROLINE_BACKTEST_MIN_FETCH_PCT=${CAROLINE_BACKTEST_MIN_FETCH_PCT}) -- refusing to write a report from a partial sample"
fi

# ── 9. redact + write rows.jsonl ─────────────────────────────
sed -E -f "$REDACT_SED" "$rows_raw" > "$out_dir/rows.jsonl"

# ── 10. report ────────────────────────────────────────────────
python3 "$PY_SCRIPT" report "$out_dir/rows.jsonl" "$out_dir/report.md"
