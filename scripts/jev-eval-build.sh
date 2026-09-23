#!/bin/bash
# ──────────────────────────────────────────────────────────────
# jev-eval-build.sh — builds a labelled, replayable Jev eval gold set for the
# Caroline pre-turn router, so question/state changes (plugins/intercom/src/
# jev-router.ts, caroline-questions.json) are measured by scripts/jev-eval-run.sh
# against real conversations, not guessed.
#
# Pulls Intercom conversations Caroline handled in the last --days days,
# enumerates every customer turn, stratifies a ~--size sample across seven
# strata (see STRATA below), asks a tool-less labeller model (OpenRouter
# direct curl, same posture as scripts/dr-ai-healer.sh) to label each
# sampled turn, compares the label to what Caroline actually did next, and
# writes:
#   $JEV_EVAL_DIR/caroline-gold-YYYYMMDD.jsonl   one row per labelled turn
#   $JEV_EVAL_DIR/review-YYYYMMDD.md             disagreements + unlabelled
#                                                  rows, for human review
#
# Usage:
#   jev-eval-build.sh [--days 21] [--size 300] [--max-pages 50] [--include-conv ID ...]
#   jev-eval-build.sh --apply-review <review-file>
#   jev-eval-build.sh --relabel <gold.jsonl>
#
#   --days N            Intercom window in days (default 21).
#   --size N             target sample size (default 300).
#   --max-pages N         safety cap on Intercom conversations/search pages
#                         (150/page, default 50); paginates until pages.next
#                         is absent, or until this cap is hit -- hitting it
#                         prints a loud WARN and marks the build summary
#                         truncated=true rather than silently stopping short.
#   --include-conv ID    force this conversation's customer turns into the
#                         sample regardless of strata quotas (repeatable) --
#                         use to pin a known-miss conversation into every run.
#   --seed N              deterministic ordering seed for within-stratum
#                         sampling (default 20260923). Each stratum's
#                         candidates are ordered by sha256(seed, conv_id,
#                         turn_index), not by conv_id -- a plain (conv_id,
#                         turn_index) sort biases the live gold set toward
#                         whichever conversations happen to sort first,
#                         every single run (QA re-review finding 5). Change
#                         only to deliberately draw a different sample.
#   --apply-review FILE  merge a human-reviewed review-*.md's `verdict:`
#                         lines back into its matching gold file (human
#                         overrides model) and exit; no Intercom/OpenRouter
#                         calls are made in this mode.
#   --relabel FILE        re-run the labeller ONLY on FILE's `label == null`
#                         rows (a prior run's transport failures/truncations/
#                         parse failures), using each row's own stored
#                         thread_so_far/full_thread -- no Intercom calls are
#                         made in this mode. Rewrites FILE in place,
#                         atomically, at 0600, preserving row order; rows
#                         that were already labelled are left byte-identical.
#                         New disagreements/still-unlabelled rows are
#                         appended to that gold file's review-*.md (created
#                         if missing). Each row is retried up to 2 times.
#
# Strata (each turn belongs to exactly one, first match wins, in this order):
#   escalated    the customer turn immediately preceding an edge-journal
#                ESCALATED line or a "[intercom:escalation] ticket created"
#                line for that conversation.
#   tool         the customer turn immediately preceding a tool.call event
#                (trajectory sweep, same source as jev-backtest-caroline.sh)
#                for that conversation.
#   closer       last customer turn in the thread, thanks/ok-shaped (see
#                is_closer_text below) -- production's jev-router.ts
#                isCloserShaped EXACT-phrase predicate, fetched from the
#                plugin itself (jev-state-cli.ts --dump-closer-phrases),
#                never an independently hardcoded phrase list.
#   supplying    the prior Caroline reply (an admin/bot part) asked a
#                question or requested something (contains '?' or a request
#                verb) and this customer turn carries a link, an attachment
#                marker, or a bare yes/ok/done/sure/here.
#   image_only   the turn's body is empty/whitespace after HTML-strip but the
#                raw Intercom part had an attachment (message text lost to a
#                pure-image turn).
#   first        turn_index 0 in the conversation (the opening message).
#   other        every other customer turn (includes the general
#                non-English population -- no separate stratum key, since
#                language is a covariate, not a resolution-shape category).
#
# Labeller: OpenRouter direct curl (JEV_EVAL_LABEL_MODEL, default
# openai/gpt-5.6-sol), tool-less, key from the SAME source
# scripts/dr-ai-healer.sh uses (env OPENROUTER_API_KEY, else
# JEV_EVAL_LABEL_KEY_FILE's .OPENROUTER_API_KEY, default
# /opt/hydra/secrets/llm-provider-keys.json). The bearer token goes to curl
# via a header FILE, never argv (same posture as jev.sh / dr-ai-healer.sh).
# JEV_EVAL_LABEL_MODEL is a reasoning model, so max_tokens has to cover
# reasoning tokens as well as the JSON reply -- JEV_EVAL_LABEL_MAX_TOKENS
# (default 4000, must be a positive integer) is the completion budget, and
# JEV_EVAL_LABEL_REASONING_EFFORT (default empty -- omitted from the
# request), when set to low/medium/high, is passed through as OpenRouter's
# `reasoning: {effort: ...}`.
#
# A row whose label could not be produced (transport failure, non-2xx HTTP,
# a truncated completion, unparseable JSON, or JSON that fails the label
# schema) still gets a gold row with label=null AND a `label_error` object
# recording http_status, curl_rc, finish_reason, the parse/schema problem,
# and the first 300 chars of the raw model output -- so a null label is
# diagnosable without re-running anything, and a counted-by-kind summary is
# printed at the end of every run (build or --relabel).
#
# Fails closed: an Intercom search/transport/auth failure exits non-zero with
# no gold file written -- never "0 rows". An individual conversation GET
# failure, or a single turn's labeller call failing, is non-fatal (WARN +
# skip / unlabelled row) -- see the sample-coverage-style posture in
# jev-backtest-caroline.sh, which this script otherwise mirrors.
#
# Exit codes: 0 ok; 2 bad usage / missing secret; 4 Intercom search failed
#   (auth/HTTP/transport/unparseable -- never downgraded to empty); 5 zero
#   candidate turns found; 6 --apply-review/--relabel file/gold-file problem.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

USAGE="Usage: jev-eval-build.sh [--days 21] [--size 300] [--max-pages 50] [--seed 20260923] [--include-conv ID ...] | --apply-review FILE | --relabel FILE"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REDACT_SED="$REPO_ROOT/workspaces/operations/skills/muso-caroline-weekly-review/scripts/lib/redact-core.sed"

: "${JEV_EVAL_DIR:=/var/lib/hydra-jev/eval}"
: "${JEV_EVAL_LABEL_MODEL:=openai/gpt-5.6-sol}"
: "${JEV_EVAL_LABEL_KEY_FILE:=/opt/hydra/secrets/llm-provider-keys.json}"
: "${JEV_EVAL_OPENROUTER_URL:=https://openrouter.ai/api/v1/chat/completions}"
# openai/gpt-5.6-sol is a reasoning model: max_tokens on OpenRouter's chat
# completions endpoint bounds reasoning tokens AND the visible completion
# together, so a budget sized only for the ~150-char JSON reply gets the
# reasoning spend cut off mid-token -- observed live as a truncated JSON key
# ("":null) and a finish_reason of "length". 4000 gives the model real
# room to think before it has to emit the label.
: "${JEV_EVAL_LABEL_MAX_TOKENS:=4000}"
# Empty (default) omits `reasoning` from the request entirely -- some
# OpenRouter-routed models 400 on an unrecognized field. Set to low/medium/
# high to ask the model to spend less of that budget thinking, per
# OpenRouter's unified reasoning-tokens API (reasoning.effort).
: "${JEV_EVAL_LABEL_REASONING_EFFORT:=}"
: "${JEV_EVAL_SOUL_FILE:=$REPO_ROOT/workspaces/support/SOUL.md}"
: "${JEV_EVAL_INVENTORY_FILE:=$REPO_ROOT/plugins/intercom/src/caroline-inventory.json}"
: "${JEV_EVAL_QUESTIONS_FILE:=$REPO_ROOT/plugins/intercom/src/caroline-questions.json}"
: "${JEV_EVAL_INTERCOM_ENV_FILE:=/etc/openclaw/edge.env}"
: "${JEV_EVAL_EDGE_UNIT:=openclaw-gateway-edge}"
: "${JEV_EVAL_TRAJECTORY_SOURCE:=auto}"
: "${JEV_EVAL_TRAJECTORY_GLOB:=/root/.openclaw-edge/agents/support/sessions/*.trajectory.jsonl}"
: "${JEV_EVAL_TRAJECTORY_DBS:=/root/.openclaw-edge/agents/support/agent/openclaw-agent.sqlite}"
# The LIVE gateway config on the edge host -- the same file config.ts reads
# channels.intercom.accounts.<account>.botAdminId from at boot (production's
# only source for the id the plugin posts every Caroline reply with).
: "${JEV_EVAL_EDGE_CONFIG:=/root/.openclaw-edge/openclaw.json}"
: "${JEV_EVAL_INTERCOM_ACCOUNT:=default}"

_ev_die() {
  echo "jev-eval-build.sh: $2" >&2
  exit "$1"
}

days=21
size=300
max_pages=50
# Fixed default (not random/time-based) so a bare re-run reproduces the same
# sample -- the seed only needs to change when a human deliberately wants a
# different draw (QA re-review finding 5).
seed=20260923
apply_review_file=""
relabel_file=""
declare -a include_convs=()

while [ $# -gt 0 ]; do
  case "$1" in
    --days) days="$2"; shift 2 ;;
    --size) size="$2"; shift 2 ;;
    --max-pages) max_pages="$2"; shift 2 ;;
    --seed) seed="$2"; shift 2 ;;
    --include-conv) include_convs+=("$2"); shift 2 ;;
    --apply-review) apply_review_file="$2"; shift 2 ;;
    --relabel) relabel_file="$2"; shift 2 ;;
    -h|--help) echo "$USAGE"; exit 0 ;;
    *) echo "$USAGE" >&2; _ev_die 2 "unknown argument: $1" ;;
  esac
done

case "$days" in ''|*[!0-9]*|0) _ev_die 2 "--days must be a positive integer (got: $days)" ;; esac
case "$size" in ''|*[!0-9]*|0) _ev_die 2 "--size must be a positive integer (got: $size)" ;; esac
case "$max_pages" in ''|*[!0-9]*|0) _ev_die 2 "--max-pages must be a positive integer (got: $max_pages)" ;; esac
case "$seed" in ''|*[!0-9]*) _ev_die 2 "--seed must be a non-negative integer (got: $seed)" ;; esac
case "$JEV_EVAL_LABEL_MAX_TOKENS" in
  ''|*[!0-9]*|0) _ev_die 2 "JEV_EVAL_LABEL_MAX_TOKENS must be a positive integer (got: $JEV_EVAL_LABEL_MAX_TOKENS)" ;;
esac
case "$JEV_EVAL_LABEL_REASONING_EFFORT" in
  ''|low|medium|high) ;;
  *) _ev_die 2 "JEV_EVAL_LABEL_REASONING_EFFORT must be empty, low, medium, or high (got: $JEV_EVAL_LABEL_REASONING_EFFORT)" ;;
esac

mkdir -p "$JEV_EVAL_DIR"
if [ -L "$JEV_EVAL_DIR" ] || [ ! -d "$JEV_EVAL_DIR" ]; then
  _ev_die 2 "JEV_EVAL_DIR ($JEV_EVAL_DIR) is a symlink or not a directory -- refusing to write"
fi
chmod 700 "$JEV_EVAL_DIR" 2>/dev/null || true

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/jev-eval-build.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

# The python helper (turn enumeration/stratification/sampling, label
# validation, gold-row assembly, split-by-conversation, apply-review merge,
# label-error classification, relabel-row assembly) is embedded here, not a
# sibling file -- same "one file, one language per concern" style as
# jev-backtest-caroline.sh / jev-shadow-report.sh.
PY_SCRIPT="$work_dir/lib.py"
cat > "$PY_SCRIPT" <<'PYEOF'
import glob
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys

SESSIONKEY_CONV_PREFIX = "agent:support:intercom:direct:"
SQLITE_TRAJECTORY_MIN_RUNTIME = (2026, 8)
CUSTOMER_AUTHOR_TYPES = {"user", "lead", "contact"}
HUMAN_REASON_RE = re.compile(r"dispute|chargeback|legal|deletion|fraud", re.I)

# Loaded lazily from JEV_EVAL_CLOSER_PHRASES_FILE (a JSON array), which the
# bash wrapper fills in by running jev-state-cli.ts --dump-closer-phrases --
# production's jev-router.ts CLOSER_PHRASES set, never an independent copy
# here (QA re-review finding 4 on PR #1021). Lazy (not module-level) because
# --apply-review's python invocation never calls is_closer_text() and never
# gets this env var set (no Intercom/state-cli call happens in that mode).
_CLOSER_PHRASES_CACHE = None


def _closer_phrases():
    global _CLOSER_PHRASES_CACHE
    if _CLOSER_PHRASES_CACHE is None:
        with open(os.environ["JEV_EVAL_CLOSER_PHRASES_FILE"], "r", encoding="utf-8") as _f:
            _CLOSER_PHRASES_CACHE = set(item.lower() for item in json.load(_f))
    return _CLOSER_PHRASES_CACHE


REQUEST_VERB_RE = re.compile(r"\bcan you\b|\bcould you\b|\bplease (send|share|attach|provide)\b|\?", re.I)
SUPPLY_SIGNAL_RE = re.compile(
    r"https?://|\byes\b|\byep\b|\byup\b|\bok(ay)?\b|\bdone\b|\bsure\b|\bhere\b|\battached\b", re.I)

LABEL_KEYS = {"path", "intent", "first_tool", "needs_reply", "supplying_requested_info",
              "bad_faith", "frustration_level", "rationale"}
LABEL_PATHS = {"caroline_tool", "answer_from_knowledge", "ask_customer", "human_required", "acknowledge", "no_reply"}

_CLOSER_SIGNATURE_LINE_RE = re.compile(r"^(--\s*$|sent from |regards,?$|best,?$|cheers,?$)", re.I)
_CLOSER_STRIP_PUNCT_RE = re.compile(r"[.,!;:()\"'`~*_]")


def is_closer_text(text):
    """Mirrors jev-router.ts's isCloserShaped exactly: strip signature
    lines, reject any '?', strip punctuation (emoji preserved), and match
    the stripped text EXACTLY against CLOSER_PHRASES. Production removed a
    fallback that treated any message of three words or fewer (no '?') as
    a closer after real-data false positives ("urgent", a bare profile
    link both scored as closers) -- the eval harness must not resurrect
    that fallback under a different name (QA re-review finding 4)."""
    lines = [ln.strip() for ln in (text or "").split("\n")]
    lines = [ln for ln in lines if ln and not _CLOSER_SIGNATURE_LINE_RE.match(ln)]
    joined = " ".join(lines).strip()
    if not joined or "?" in joined:
        return False
    stripped = re.sub(r"\s+", " ", _CLOSER_STRIP_PUNCT_RE.sub("", joined)).strip().lower()
    if not stripped:
        return False
    return stripped in _closer_phrases()


def strip_html(body):
    return re.sub(r"<[^>]*>", "", body or "").strip()


def sessionkey_conv(session_key):
    if session_key and session_key.startswith(SESSIONKEY_CONV_PREFIX):
        return session_key[len(SESSIONKEY_CONV_PREFIX):]
    return None


def month_ts(ts):
    import datetime
    if not ts:
        return None
    s = str(ts).strip()
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S.%fZ"):
        try:
            return datetime.datetime.strptime(s, fmt).replace(tzinfo=datetime.timezone.utc).timestamp()
        except ValueError:
            continue
    return None


# --------------------------------------------------------------------------
# journal / trajectory (ported from jev-backtest-caroline.sh, generalized to
# not require a fixed cohort -- every conversation's evidence is looked up
# independently, since eval sampling is stratified per TURN, not per
# conversation cohort).
# --------------------------------------------------------------------------
ESCALATED_RE = re.compile(r"ESCALATED conv=(\d+) source=(rule|user_request) reason=(.+?)\s*$")
TICKET_RE = re.compile(r"\[intercom:escalation\] ticket created conv=(\d+) id=(\S+)")
JOURNAL_TS_RE = re.compile(r"^(\d+)\.\d+\s")


def parse_journal(path):
    escalations = {}
    tickets = {}
    try:
        fh = open(path, "r", encoding="utf-8", errors="replace")
    except OSError:
        return escalations, tickets
    with fh:
        for line in fh:
            m = ESCALATED_RE.search(line)
            if m:
                ts_m = JOURNAL_TS_RE.match(line)
                ts = float(ts_m.group(1)) if ts_m else None
                # A customer explicitly asking for a human (source=user_request)
                # IS the content signal, regardless of reason text -- filtering
                # it out the same way a rule-triggered escalation is filtered
                # dropped every user_request escalation from the escalated
                # stratum. Only rule-sourced escalations still need the reason
                # to match HUMAN_REASON_RE (non-human rule reasons, e.g. a rate
                # limit, aren't a content escalation).
                content = bool(m.group(2) == "user_request" or
                               (m.group(2) == "rule" and HUMAN_REASON_RE.search(m.group(3))))
                escalations.setdefault(m.group(1), []).append(
                    {"source": m.group(2), "reason": m.group(3), "ts": ts, "content": content})
                continue
            m = TICKET_RE.search(line)
            if m:
                tickets[m.group(1)] = m.group(2)
    return escalations, tickets


def ingest_record(rec, per_conv):
    if not isinstance(rec, dict) or rec.get("type") != "tool.call":
        return
    data = rec.get("data") or {}
    name = data.get("name")
    if not name:
        return
    conv = sessionkey_conv(rec.get("sessionKey"))
    if not conv:
        return
    ts = month_ts(rec.get("ts"))
    per_conv.setdefault(conv, []).append({"ts": ts if ts is not None else 0.0, "name": name})


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
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
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
            continue
        finally:
            con.close()
    return per_conv


def openclaw_runtime_version():
    try:
        out = subprocess.run(["openclaw", "--version"], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    m = re.search(r"(\d{4})\.(\d+)", out.stdout or "")
    return (int(m.group(1)), int(m.group(2))) if m else None


def resolve_trajectory(cfg):
    forced = (cfg.get("traj_source") or "auto").strip().lower()
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
        return sweep_sqlite([d for d in (cfg.get("traj_dbs") or "").split(":") if d])
    glob_pattern = cfg.get("traj_glob") or ""
    paths = sorted(glob.glob(glob_pattern)) if glob_pattern else []
    return sweep_files(paths)


# --------------------------------------------------------------------------
# conversation -> normalized parts (thread schema: author user|bot|admin)
# --------------------------------------------------------------------------
def load_conv_parts(conv_json, bot_admin_id):
    parts = []

    def role_of(author):
        t = (author or {}).get("type") or ""
        if t in CUSTOMER_AUTHOR_TYPES:
            return "user"
        if t == "admin":
            return "bot" if bot_admin_id and (author or {}).get("id") == bot_admin_id else "admin"
        return "admin"

    source = conv_json.get("source") or {}
    source_body = source.get("body") or ""
    source_has_attach = bool(source.get("attachments"))
    if source_body.strip() or source_has_attach:
        parts.append({"author": role_of(source.get("author")), "body": source_body,
                       "created_at": source.get("created_at") or 0,
                       "has_attachment": source_has_attach})
    for p in ((conv_json.get("conversation_parts") or {}).get("conversation_parts") or []):
        if not isinstance(p, dict):
            continue
        # Only visible replies -- mirrors handler.ts's part_type == "comment"
        # filter (internal notes/assignments/closes are not turns).
        if p.get("part_type") and p.get("part_type") != "comment":
            continue
        body = p.get("body") or ""
        has_attach = bool(p.get("attachments"))
        if not body.strip() and not has_attach:
            continue
        parts.append({"author": role_of(p.get("author")), "body": body,
                       "created_at": p.get("created_at") or 0, "has_attachment": has_attach})
    return parts


def cmd_normalize(argv):
    """normalize <conv.json> <bot_admin_id> -> thread schema {parts:[...]}
    (author/body only, stripped, dropping the has_attachment/created_at
    scaffolding used internally) printed to stdout."""
    conv_path, bot_admin_id = argv[0], (argv[1] or None)
    with open(conv_path, "r", encoding="utf-8") as fh:
        conv_json = json.load(fh)
    parts = load_conv_parts(conv_json, bot_admin_id)
    out = {"parts": [{"author": p["author"], "body": strip_html(p["body"]),
                       "created_at": p["created_at"], "has_attachment": p["has_attachment"]}
                      for p in parts]}
    print(json.dumps(out))
    return 0


# --------------------------------------------------------------------------
# subcommand: enumerate-turns
# --------------------------------------------------------------------------
def _reply_window(parts, idx):
    """Parts strictly between customer turn idx and the customer's NEXT
    message (exclusive on both ends) -- everything said in response to THIS
    specific turn before the customer spoke again. Not the conversation as a
    whole: an earlier message in a multi-part customer burst has an empty
    window even if a later message in the same burst does get an answer."""
    window = []
    for p in parts[idx + 1:]:
        if p["author"] == "user":
            break
        window.append(p)
    return window


def replied_for_idx(parts, idx):
    """Whether CAROLINE (the bot) replied to THIS specific customer turn. A
    human admin taking the conversation over does NOT count as Caroline
    replying -- see human_replied_for_idx for that. disagrees() must use
    this (Caroline-only) signal, never human_replied_for_idx, so a human
    admin's takeover is never mistaken for a Caroline routing decision."""
    return any(p["author"] == "bot" for p in _reply_window(parts, idx))


def human_replied_for_idx(parts, idx):
    """Whether a HUMAN ADMIN (not Caroline) replied to THIS specific
    customer turn, before the customer spoke again."""
    return any(p["author"] == "admin" for p in _reply_window(parts, idx))


def stratum_for(parts, idx, tool_turn_indices, escalation_turn_index):
    """First-match-wins stratum for customer part at index idx (idx is an
    index into `parts`, the full normalized part list)."""
    if idx == escalation_turn_index:
        return "escalated"
    if idx in tool_turn_indices:
        return "tool"
    # closer: LAST customer part in the thread, closer-shaped.
    last_customer_idx = max((i for i, p in enumerate(parts) if p["author"] == "user"), default=None)
    if idx == last_customer_idx and is_closer_text(parts[idx]["body"]):
        return "closer"
    # supplying: prior Caroline reply asked/requested, this turn supplies a
    # link/attachment/bare-affirmative.
    prior_bot = next((parts[j] for j in range(idx - 1, -1, -1) if parts[j]["author"] in ("bot", "admin")), None)
    if prior_bot and REQUEST_VERB_RE.search(prior_bot["body"] or "") and \
       (SUPPLY_SIGNAL_RE.search(parts[idx]["body"] or "") or parts[idx]["has_attachment"]):
        return "supplying"
    if not (parts[idx]["body"] or "").strip() and parts[idx]["has_attachment"]:
        return "image_only"
    customer_indices = [i for i, p in enumerate(parts) if p["author"] == "user"]
    if customer_indices and customer_indices[0] == idx:
        return "first"
    return "other"


def cmd_enumerate(argv):
    """enumerate <conv_dir> <ids_file> <bot_admin_id> <escalations_json> <tickets_json> <trajectory_json>
    -> one JSON turn record per line on stdout."""
    conv_dir, ids_file, bot_admin_id = argv[0], argv[1], (argv[2] or None)
    with open(argv[3], "r", encoding="utf-8") as fh:
        escalations = json.load(fh)
    with open(argv[5], "r", encoding="utf-8") as fh:
        trajectory = json.load(fh)

    try:
        with open(ids_file, "r", encoding="utf-8") as fh:
            conv_ids = [line.strip() for line in fh if line.strip()]
    except OSError:
        conv_ids = []

    for conv_id in sorted(conv_ids):
        path = os.path.join(conv_dir, f"{conv_id}.json")
        try:
            with open(path, "r", encoding="utf-8") as fh:
                conv_json = json.load(fh)
        except (OSError, ValueError):
            continue
        parts = load_conv_parts(conv_json, bot_admin_id)
        if not any(p["author"] == "user" for p in parts):
            continue

        conv_has_ticket = conv_id in json.load(open(argv[4], "r", encoding="utf-8"))
        customer_indices = [i for i, p in enumerate(parts) if p["author"] == "user"]

        # escalation turn: the customer part immediately BEFORE the earliest
        # content-reason escalation's timestamp (fallback: last customer
        # part, when this conv has any content escalation but no usable ts).
        # A conversation can also carry an intercom ticket with NO matching
        # journal escalation line at all (e.g. the ticket was created by a
        # path the journal sweep doesn't cover) -- without a fallback those
        # conversations never got an escalated turn, so escalation-caused
        # turns silently vanished from the escalated stratum. Fall back to
        # the last customer turn, same as the no-usable-ts case above.
        content_escs = [e for e in escalations.get(conv_id, []) if e.get("content")]
        escalation_turn_index = None
        if content_escs:
            esc_ts = min(e["ts"] for e in content_escs if e.get("ts") is not None) if \
                any(e.get("ts") is not None for e in content_escs) else None
            if esc_ts is not None:
                best = [i for i in customer_indices if (parts[i]["created_at"] or 0) <= esc_ts]
                escalation_turn_index = (best[-1] if best else (customer_indices[-1] if customer_indices else None))
            elif customer_indices:
                escalation_turn_index = customer_indices[-1]
        elif conv_has_ticket and customer_indices:
            escalation_turn_index = customer_indices[-1]

        # first_tool per turn: map EVERY tool event to the customer turn it
        # immediately follows (not just the conversation's first tool event),
        # so a turn's first_tool is the first tool call that happened after
        # THAT turn, before the next one -- not always the conversation's
        # very first tool call regardless of which turn asked for it.
        tool_events = sorted(trajectory.get(conv_id, []), key=lambda e: e["ts"])
        tool_turn_indices = set()
        turn_first_tool = {}
        for ev in tool_events:
            candidates = [i for i in customer_indices if (parts[i]["created_at"] or 0) <= ev["ts"]]
            if not candidates:
                continue
            turn_idx = candidates[-1]
            tool_turn_indices.add(turn_idx)
            if turn_idx not in turn_first_tool:
                turn_first_tool[turn_idx] = ev["name"]

        for idx, p in enumerate(parts):
            if p["author"] != "user":
                continue
            stratum = stratum_for(parts, idx, tool_turn_indices, escalation_turn_index)
            # known_facts (founding/plan/prior_chats) is what production
            # injects via a live Muso-admin-API snapshot lookup + an
            # Intercom prior-conversations call (channel.ts's
            # lookupSnapshot/listPriorConversations, assembled into
            # state.enrichment.{snapshot,priorChats}) -- this harness only
            # ever reads the conversation + trajectory files already fetched
            # to disk (see the module comment above), so it has no faithful,
            # read-only way to reproduce those two live calls offline.
            # known_facts is therefore always omitted here (jev-state-cli.ts
            # treats it as optional -- see its module doc), and every row is
            # marked known_facts_missing so this gap is counted and visible
            # rather than silently read as "customer has no known facts".
            thread_so_far = {"parts": [{"author": parts[i]["author"], "body": strip_html(parts[i]["body"])}
                                        for i in range(idx + 1)], "turn_index": idx,
                              "known_facts_missing": True}
            full_thread = {"parts": [{"author": parts[i]["author"], "body": strip_html(parts[i]["body"])}
                                      for i in range(len(parts))], "turn_index": idx,
                            "known_facts_missing": True}
            caroline_action = {
                "replied": replied_for_idx(parts, idx),
                "human_replied": human_replied_for_idx(parts, idx),
                "escalated": (idx == escalation_turn_index),
                "conv_has_ticket": conv_has_ticket,
                "first_tool": turn_first_tool.get(idx),
            }
            print(json.dumps({
                "conv_id": conv_id, "turn_index": idx, "stratum": stratum,
                "thread_so_far": thread_so_far, "full_thread": full_thread,
                "caroline_action": caroline_action,
            }))


# --------------------------------------------------------------------------
# subcommand: sample -- stratified, --include-conv forced in
# --------------------------------------------------------------------------
STRATA_ORDER = ["escalated", "tool", "closer", "supplying", "image_only", "first", "other"]
# Target share of the sample per stratum (sums to 1.0); "other" absorbs
# whatever's left so the total always lands on --size even when a stratum is
# short.
STRATA_SHARE = {"escalated": 0.12, "tool": 0.22, "closer": 0.15, "supplying": 0.15,
                 "image_only": 0.08, "first": 0.13, "other": 0.15}


def _sample_order_key(seed):
    """Orders candidates within a stratum (or the leftover top-up pool) by
    sha256(seed, conv_id, turn_index) rather than plain (conv_id,
    turn_index) -- a lexicographic sort always favours whichever
    conversations happen to sort first, so every run of the live gold set
    drew the SAME conversations out of a larger candidate pool, biasing it
    (QA re-review finding 5, flagged as highest priority: "this matters
    most; the current live gold set is biased by it"). The hash digest is
    still fully deterministic for a fixed --seed, so a bare re-run
    reproduces the same sample; only changing --seed draws a different one."""
    def key(r):
        digest = hashlib.sha256(f"{seed}:{r['conv_id']}:{r['turn_index']}".encode("utf-8")).hexdigest()
        return digest
    return key


def cmd_sample(argv):
    turns_file, size, include_ids_csv = argv[0], int(argv[1]), argv[2]
    seed = argv[3] if len(argv) > 3 else "20260923"
    order_key = _sample_order_key(seed)
    include_ids = {c for c in include_ids_csv.split(",") if c}
    rows = []
    with open(turns_file, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                rows.append(json.loads(line))

    forced = [r for r in rows if r["conv_id"] in include_ids]
    forced_keys = {(r["conv_id"], r["turn_index"]) for r in forced}
    remaining_pool = [r for r in rows if (r["conv_id"], r["turn_index"]) not in forced_keys]

    remaining_size = max(size - len(forced), 0)
    by_stratum = {s: [] for s in STRATA_ORDER}
    for r in remaining_pool:
        by_stratum.setdefault(r["stratum"], []).append(r)

    sampled = list(forced)
    taken_keys = set(forced_keys)
    for stratum in STRATA_ORDER:
        target = int(round(remaining_size * STRATA_SHARE.get(stratum, 0)))
        pool = sorted(by_stratum.get(stratum, []), key=order_key)
        for r in pool[:target]:
            key = (r["conv_id"], r["turn_index"])
            if key not in taken_keys:
                sampled.append(r)
                taken_keys.add(key)

    # Top up from whatever's left (any stratum) if quotas under-filled versus
    # --size, so a thin stratum never silently shrinks the sample.
    if len(sampled) < size:
        leftover = sorted(
            (r for r in remaining_pool if (r["conv_id"], r["turn_index"]) not in taken_keys),
            key=order_key)
        for r in leftover:
            if len(sampled) >= size:
                break
            sampled.append(r)
            taken_keys.add((r["conv_id"], r["turn_index"]))

    for r in sampled:
        print(json.dumps(r))


# --------------------------------------------------------------------------
# subcommand: build-prompt -- the labeller's user-message text
# --------------------------------------------------------------------------
def cmd_build_prompt(argv):
    """build-prompt <record.json> -- record must carry full_thread
    ({parts:[{author,body}], turn_index}). Works equally on a fresh
    enumerate-turns record and on a stored gold row (which now carries
    full_thread too), so --relabel reuses this unchanged."""
    turn_record_path = argv[0]
    with open(turn_record_path, "r", encoding="utf-8") as fh:
        rec = json.load(fh)
    parts = rec["full_thread"]["parts"]
    target = rec["full_thread"]["turn_index"]
    lines = []
    for i, p in enumerate(parts):
        marker = " <== TARGET TURN (label this one)" if i == target else ""
        lines.append(f"[{i}] {p['author']}: {p['body']}{marker}")
    print("\n".join(lines))
    return 0


# --------------------------------------------------------------------------
# subcommand: validate-label / label-error classification
# --------------------------------------------------------------------------
def _intent_keys_from_questions(questions):
    """Extract the declared `intent` enum from caroline-questions.json --
    production's `intent` question declares its enum as `criteria` (a dict,
    keys are the valid values; or occasionally a list of labels); the eval
    fixture uses `options` (a plain list). Both shapes are handled. None
    means the question file declared nothing usable, so intent enum
    checking is skipped rather than rejecting every label."""
    if not isinstance(questions, dict):
        return None
    q = questions.get("intent")
    if not isinstance(q, dict):
        return None
    for key in ("criteria", "options"):
        v = q.get(key)
        if isinstance(v, dict):
            return set(v.keys())
        if isinstance(v, list):
            return set(v)
    return None


def _tool_names_from_inventory(inventory):
    """Extract the declared tool-name set from caroline-inventory.json's
    `tools` -- production's is a list of dicts each with a `name` key; the
    eval fixture's is a flat list of strings. Both handled. None means
    nothing usable was declared, so first_tool enum checking is skipped."""
    if not isinstance(inventory, dict):
        return None
    tools = inventory.get("tools")
    if not isinstance(tools, list):
        return None
    names = set()
    for t in tools:
        if isinstance(t, dict) and isinstance(t.get("name"), str):
            names.add(t["name"])
        elif isinstance(t, str):
            names.add(t)
    return names or None


def validate_label(obj, valid_intents=None, valid_first_tools=None):
    if not isinstance(obj, dict):
        return None
    if not LABEL_KEYS.issubset(obj.keys()):
        return None
    if obj.get("path") not in LABEL_PATHS:
        return None
    if not isinstance(obj.get("intent"), str) or not obj["intent"]:
        return None
    # "other" is always allowed regardless of the declared enum -- it is the
    # labeller's documented escape hatch for a turn that matches none of the
    # known intents, not itself one of caroline-inventory.json's intents.
    if valid_intents is not None and obj["intent"] != "other" and obj["intent"] not in valid_intents:
        return None
    if not isinstance(obj.get("first_tool"), str) or not obj["first_tool"]:
        return None
    # "none" (no tool used) and "memory_search" (a real Caroline capability
    # that is not itself listed among caroline-inventory.json's `tools`) are
    # always allowed regardless of the declared inventory.
    if valid_first_tools is not None and obj["first_tool"] not in ({"none", "memory_search"} | valid_first_tools):
        return None
    for b in ("needs_reply", "supplying_requested_info", "bad_faith"):
        if not isinstance(obj.get(b), bool):
            return None
    fl = obj.get("frustration_level")
    if not isinstance(fl, int) or isinstance(fl, bool) or not (0 <= fl <= 3):
        return None
    if not isinstance(obj.get("rationale"), str):
        return None
    return {k: obj[k] for k in LABEL_KEYS}


def label_consistency_error(label):
    """Cross-field consistency check (QA re-review finding 2): a label can
    pass validate_label's per-field schema/enum checks and still describe a
    combination no real Caroline turn can produce -- e.g. path=no_reply
    (nothing sent) paired with first_tool=credits_lookup (a tool WAS run).
    Returns a human-readable reason on violation, None if consistent.
    Mirrors the labelled paths themselves (LABEL_PATHS), not a copy."""
    path = label.get("path")
    first_tool = label.get("first_tool")
    needs_reply = label.get("needs_reply")
    if path in ("no_reply", "acknowledge"):
        if first_tool != "none":
            return f"path={path} requires first_tool=none, got {first_tool!r}"
        expected_needs_reply = (path == "acknowledge")
        if needs_reply != expected_needs_reply:
            return f"path={path} requires needs_reply={expected_needs_reply}, got {needs_reply!r}"
    elif path == "answer_from_knowledge":
        if first_tool not in ("memory_search", "none"):
            return f"path=answer_from_knowledge requires first_tool in {{memory_search, none}}, got {first_tool!r}"
    elif path == "caroline_tool":
        if first_tool in ("none", "memory_search"):
            return f"path=caroline_tool requires first_tool not in {{none, memory_search}}, got {first_tool!r}"
    return None


def classify_label_error(meta, parse_error):
    """One coarse `kind` per label_error, cheapest/most-certain cause first:
    a transport failure (curl itself failed) outranks a bad HTTP status,
    which outranks a truncated completion (finish_reason=length -- the
    live-observed cause of a truncated JSON key), which outranks a parse/
    schema problem in an otherwise-complete reply, which outranks a
    cross-field inconsistency in an otherwise schema-valid reply."""
    curl_rc = meta.get("curl_rc")
    http_status = meta.get("http_status")
    finish_reason = meta.get("finish_reason")
    if curl_rc not in (None, 0):
        return "transport"
    if http_status is not None and not str(http_status).startswith("2"):
        return "http_status"
    if finish_reason == "length":
        return "truncated"
    if parse_error and parse_error.startswith("not valid JSON"):
        return "unparseable"
    if parse_error == "JSON did not match the label schema":
        return "schema_invalid"
    if parse_error and parse_error.startswith("cross-field label inconsistency:"):
        return "inconsistent"
    return "unknown"


def build_label_error(meta, parse_error, raw_content):
    return {
        "kind": classify_label_error(meta, parse_error),
        "http_status": meta.get("http_status"),
        "curl_rc": meta.get("curl_rc"),
        "finish_reason": meta.get("finish_reason"),
        "parse_error": parse_error,
        "raw_content": (raw_content or "")[:300],
    }


def _load_json_or_none(path):
    """Best-effort JSON load: a missing/unreadable/malformed file returns
    None rather than raising, so an optional enum source that isn't wired
    up (an older caller, or a test that doesn't pass it) degrades to "skip
    that enum check" instead of crashing the whole finalize step."""
    if not path or not os.path.exists(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except ValueError:
        return None


def _label_and_error_from_files(label_raw_path, meta_path, valid_intents=None, valid_first_tools=None):
    """Shared by finalize-row and finalize-relabel-row: parses+validates
    label_raw_path's content, loads meta_path (http_status/curl_rc/
    finish_reason/raw_content, written by the bash caller from the curl
    response), and returns (label_or_None, label_error_or_None). Never
    raises on a missing/empty/malformed label file -- that IS the failure
    this records. valid_intents/valid_first_tools (when given) enum-check
    the label's intent/first_tool against the questions/inventory files;
    an out-of-enum value is treated the same as any other schema failure
    (label=None, parse_error="JSON did not match the label schema")."""
    meta = {}
    if meta_path and os.path.exists(meta_path):
        with open(meta_path, "r", encoding="utf-8") as fh:
            meta = json.load(fh)

    label = None
    parse_error = None
    raw_content = meta.get("raw_content", "")
    if label_raw_path and os.path.exists(label_raw_path):
        with open(label_raw_path, "r", encoding="utf-8") as fh:
            raw = fh.read()
        try:
            obj = json.loads(raw)
        except ValueError as exc:
            parse_error = f"not valid JSON: {exc}"
        else:
            label = validate_label(obj, valid_intents=valid_intents, valid_first_tools=valid_first_tools)
            if label is None:
                parse_error = "JSON did not match the label schema"
            else:
                reason = label_consistency_error(label)
                if reason is not None:
                    label = None
                    parse_error = f"cross-field label inconsistency: {reason}"

    label_error = None
    if label is None:
        label_error = build_label_error(meta, parse_error, raw_content)
    return label, label_error


def split_for(conv_id):
    h = int(hashlib.sha256(conv_id.encode("utf-8")).hexdigest(), 16)
    return "tune" if (h % 10) < 7 else "holdout"


def disagrees(label, caroline_action):
    """A coarse, documented disagreement heuristic between the label and
    what Caroline's own logs show she actually did on THIS turn -- feeds
    the review queue, never the gold label itself. `replied`/`escalated`
    are per-turn (see replied_for_idx / escalation_turn_index); has_ticket
    is conv-level (a ticket isn't attributable to one turn), so it is named
    `conv_has_ticket` here to keep that distinction visible at the call
    site."""
    if label is None:
        return True
    path = label["path"]
    if path == "human_required" and not caroline_action.get("escalated") and not caroline_action.get("conv_has_ticket"):
        return True
    # no_reply must have needs_reply=false (label_consistency_error), so the
    # check is against what Caroline did: she answered a turn labelled silent.
    if path == "no_reply" and caroline_action.get("replied"):
        return True
    if path == "caroline_tool" and not caroline_action.get("first_tool"):
        return True
    return False


def cmd_finalize_row(argv):
    """finalize-row <turn_record.json> <label_json_or_empty> <meta.json>
    [<questions_file>] [<inventory_file>] -> prints one JSON object
    {gold_row, review_needed, parse_error} to stdout. Never drops a row for
    an unparseable/truncated/transport-failed label -- it comes back with
    label=null, a populated label_error, and review_needed=true.
    questions_file/inventory_file are optional: when given, they enum-check
    intent/first_tool; omitted (or unreadable), that check is skipped."""
    turn_record_path, label_raw_path = argv[0], argv[1]
    meta_path = argv[2] if len(argv) > 2 else None
    questions_path = argv[3] if len(argv) > 3 else None
    inventory_path = argv[4] if len(argv) > 4 else None
    with open(turn_record_path, "r", encoding="utf-8") as fh:
        rec = json.load(fh)

    valid_intents = _intent_keys_from_questions(_load_json_or_none(questions_path))
    valid_first_tools = _tool_names_from_inventory(_load_json_or_none(inventory_path))
    label, label_error = _label_and_error_from_files(
        label_raw_path, meta_path, valid_intents=valid_intents, valid_first_tools=valid_first_tools)

    gold_row = {
        "conv_id": rec["conv_id"],
        "turn_index": rec["turn_index"],
        "stratum": rec["stratum"],
        "thread_so_far": rec["thread_so_far"],
        "full_thread": rec["full_thread"],
        "label": label,
        "label_error": label_error,
        "caroline_action": rec["caroline_action"],
        "split": split_for(rec["conv_id"]),
    }
    review_needed = disagrees(label, rec["caroline_action"])
    print(json.dumps({"gold_row": gold_row, "review_needed": review_needed,
                       "parse_error": (label_error or {}).get("parse_error")}))


def cmd_finalize_relabel_row(argv):
    """finalize-relabel-row <existing_gold_row.json> <label_json_or_empty>
    <meta.json> [<questions_file>] [<inventory_file>] -> prints {row,
    review_needed, parse_error}. Only label/label_error change; every other
    field already on the row (stratum, thread_so_far, full_thread,
    caroline_action, split, ...) passes through unchanged, so re-serializing
    a row that DID get relabelled never drops anything the original build
    recorded. questions_file/inventory_file are optional, same contract as
    finalize-row."""
    row_path, label_raw_path, meta_path = argv[0], argv[1], argv[2]
    questions_path = argv[3] if len(argv) > 3 else None
    inventory_path = argv[4] if len(argv) > 4 else None
    with open(row_path, "r", encoding="utf-8") as fh:
        row = json.load(fh)

    valid_intents = _intent_keys_from_questions(_load_json_or_none(questions_path))
    valid_first_tools = _tool_names_from_inventory(_load_json_or_none(inventory_path))
    label, label_error = _label_and_error_from_files(
        label_raw_path, meta_path, valid_intents=valid_intents, valid_first_tools=valid_first_tools)

    new_row = dict(row)
    new_row["label"] = label
    new_row["label_error"] = label_error

    review_needed = disagrees(label, row.get("caroline_action") or {})
    print(json.dumps({"row": new_row, "review_needed": review_needed,
                       "parse_error": (label_error or {}).get("parse_error")}))


# --------------------------------------------------------------------------
# subcommand: apply-review
# --------------------------------------------------------------------------
VERDICT_HEADER_RE = re.compile(r"^### conv=(\S+) turn=(\d+)\s*$")
VERDICT_LINE_RE = re.compile(r"^verdict:\s*(.*)$")


def cmd_apply_review(argv):
    gold_path, review_path, out_path = argv[0], argv[1], argv[2]
    # A human verdict gets the same enum check as the labeller's output, and
    # refuses to run without the enums rather than merge an unchecked label.
    valid_intents = _intent_keys_from_questions(_load_json_or_none(argv[3] if len(argv) > 3 else None))
    valid_first_tools = _tool_names_from_inventory(_load_json_or_none(argv[4] if len(argv) > 4 else None))
    if not valid_intents or not valid_first_tools:
        print("jev-eval-build.sh: --apply-review needs the questions and inventory files to validate verdicts",
              file=sys.stderr)
        return 6
    rows = []
    with open(gold_path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    by_key = {(r["conv_id"], r["turn_index"]): r for r in rows}

    applied = 0
    with open(review_path, "r", encoding="utf-8") as fh:
        text = fh.read()
    cur_key = None
    for raw_line in text.splitlines():
        m = VERDICT_HEADER_RE.match(raw_line)
        if m:
            cur_key = (m.group(1), int(m.group(2)))
            continue
        m = VERDICT_LINE_RE.match(raw_line)
        if m and cur_key and cur_key in by_key:
            verdict = m.group(1).strip()
            if verdict and verdict.lower() != "agree":
                try:
                    human_label = json.loads(verdict)
                except ValueError:
                    print(f"jev-eval-build.sh: WARN unparseable verdict for {cur_key}, skipped", file=sys.stderr)
                    cur_key = None
                    continue
                validated = validate_label(human_label, valid_intents, valid_first_tools)
                if validated is None:
                    print(f"jev-eval-build.sh: WARN verdict for {cur_key} failed label schema, skipped",
                          file=sys.stderr)
                    cur_key = None
                    continue
                inconsistency = label_consistency_error(validated)
                if inconsistency is not None:
                    print(f"jev-eval-build.sh: WARN verdict for {cur_key} is cross-field inconsistent "
                          f"({inconsistency}), skipped", file=sys.stderr)
                    cur_key = None
                    continue
                by_key[cur_key]["label"] = validated
                by_key[cur_key]["label_source"] = "human"
                applied += 1
            cur_key = None

    with open(out_path, "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r) + "\n")
    print(f"jev-eval-build.sh: applied {applied} human verdict(s) from {review_path}", file=sys.stderr)
    return 0


def main():
    if len(sys.argv) < 2:
        print("usage: lib.py <normalize|enumerate|sample|build-prompt|finalize-row|finalize-relabel-row|apply-review> ...",
              file=sys.stderr)
        return 2
    sub, argv = sys.argv[1], sys.argv[2:]
    fns = {
        "normalize": cmd_normalize,
        "enumerate": cmd_enumerate,
        "sample": cmd_sample,
        "build-prompt": cmd_build_prompt,
        "finalize-row": cmd_finalize_row,
        "finalize-relabel-row": cmd_finalize_relabel_row,
        "apply-review": cmd_apply_review,
    }
    fn = fns.get(sub)
    if not fn:
        print(f"unknown subcommand: {sub}", file=sys.stderr)
        return 2
    return fn(argv)


if __name__ == "__main__":
    sys.exit(main())
PYEOF

# ── --apply-review mode: no Intercom/OpenRouter calls, exit here ──
if [ -n "$apply_review_file" ]; then
  [ -r "$apply_review_file" ] || _ev_die 6 "--apply-review file not readable: $apply_review_file"
  base="$(basename "$apply_review_file")"
  date_part="$(echo "$base" | grep -oE '[0-9]{8}' | head -1 || true)"
  [ -n "$date_part" ] || _ev_die 6 "cannot infer gold-file date from review filename: $base (expected review-YYYYMMDD.md)"
  gold_file="$JEV_EVAL_DIR/caroline-gold-${date_part}.jsonl"
  [ -r "$gold_file" ] || _ev_die 6 "matching gold file not found/readable: $gold_file"
  out_file="$work_dir/gold-merged.jsonl"
  python3 "$PY_SCRIPT" apply-review "$gold_file" "$apply_review_file" "$out_file" \
    "$JEV_EVAL_QUESTIONS_FILE" "$JEV_EVAL_INVENTORY_FILE"
  ( umask 077; cp "$out_file" "$gold_file" )
  chmod 600 "$gold_file"
  echo "jev-eval-build.sh: merged human verdicts into $gold_file" >&2
  exit 0
fi

# ── labeller key + prompt setup (shared by --relabel and the full build;
#    neither Intercom credentials nor a search window are needed here) ──
OR_KEY="${OPENROUTER_API_KEY:-}"
if [ -z "$OR_KEY" ] && [ -r "$JEV_EVAL_LABEL_KEY_FILE" ]; then
  OR_KEY=$(jq -r '.OPENROUTER_API_KEY // empty' "$JEV_EVAL_LABEL_KEY_FILE" 2>/dev/null || true)
fi
[ -n "$OR_KEY" ] || _ev_die 2 "no OpenRouter key (env OPENROUTER_API_KEY empty, $JEV_EVAL_LABEL_KEY_FILE unreadable/missing key)"

or_hdr="$work_dir/or-auth.hdr"
( umask 077; printf 'Authorization: Bearer %s\n' "$OR_KEY" > "$or_hdr" )

[ -r "$JEV_EVAL_SOUL_FILE" ] || _ev_die 2 "SOUL.md not readable: $JEV_EVAL_SOUL_FILE"
[ -r "$JEV_EVAL_INVENTORY_FILE" ] || _ev_die 2 "caroline-inventory.json not readable: $JEV_EVAL_INVENTORY_FILE"
[ -r "$JEV_EVAL_QUESTIONS_FILE" ] || _ev_die 2 "caroline-questions.json not readable: $JEV_EVAL_QUESTIONS_FILE"

read -r -d '' SYSTEM_PROMPT_TEMPLATE <<'PROMPT' || true
You are labelling ONE customer support turn for an offline eval, using Caroline's
own operating doctrine (SOUL) and her real tool inventory below. You are NOT
Caroline and do not reply to the customer -- you judge, in hindsight (you can see
the whole thread, including what happens after the target turn), what the
correct resolution path WAS for the marked target turn.

Respond with ONLY a JSON object, no prose, no markdown fences:
{"path": "caroline_tool|answer_from_knowledge|ask_customer|human_required|acknowledge|no_reply",
 "intent": "<one of the caroline-questions.json intent keys, or \"other\">",
 "first_tool": "<tool name from the inventory, or \"none\">",
 "needs_reply": <bool>, "supplying_requested_info": <bool>, "bad_faith": <bool>,
 "frustration_level": <0-3 integer>, "rationale": "<=200 chars>"}

Field definitions (apply them exactly; they are what the eval scores against):
- path: what the correct NEXT action was for the target turn.
  caroline_tool = a tool in the inventory reads or acts on what the customer
  asked about. answer_from_knowledge = a product/policy/how-to question answered
  from the reference docs (memory_search), no account data needed.
  ask_customer = one specific thing only the customer has is missing (which
  profile, a link, proof, a choice); NOT for finding their own account, which
  the tools do from the verified email. human_required = only a human can act
  (refund, deletion, cross-owner conflict, unverifiable ownership, policy
  exception, and the other handoff cases in the doctrine). acknowledge = a
  short courtesy reply is right and nothing else: no tool, no docs, nothing to
  ask (a first thanks or goodbye, a compliment, "are you a bot?", a bare "hi"
  with no request yet). no_reply = nothing should be sent for this turn (a
  closer after the agent already acknowledged, a message that is part of a
  burst the agent answers after the LAST message of the burst, forwarded or
  automated mail with nothing to act on).
- first_tool: the first tool the correct action calls; "memory_search" for
  answer_from_knowledge; "none" when no tool call is the right first step
  (always "none" for acknowledge and no_reply).
- needs_reply: true when a correct agent would send a message in response to
  this turn (or to the burst this turn completes). A closer like "thanks" after
  the agent already acknowledged is false.
- supplying_requested_info: true ONLY when the most recent agent message before
  the target turn (Caroline or a human agent) asked the customer for something
  (a link, screenshot, choice, confirmation, detail) and the target turn
  provides it, fully or partly. Always false for a conversation's first
  customer message and when the last agent message asked for nothing.
- bad_faith: true only for messages unrelated to the customer's own Muso
  account or support need, or clearly not in good faith (tests, jokes, spam,
  abuse). Greetings, thanks, and "are you a bot?" are false.
- frustration_level: 0 calm, 1 concerned (worried or impatient but polite),
  2 frustrated (complains about delay or repeated failure), 3 angry (hostile,
  threats, insults).

Caroline's SOUL (operating doctrine):
---
SOUL_PLACEHOLDER
---

Caroline's tool inventory (JSON):
---
INVENTORY_PLACEHOLDER
---
PROMPT

soul_content="$(cat "$JEV_EVAL_SOUL_FILE")"
inventory_content="$(cat "$JEV_EVAL_INVENTORY_FILE")"
system_prompt="${SYSTEM_PROMPT_TEMPLATE/SOUL_PLACEHOLDER/$soul_content}"
system_prompt="${system_prompt/INVENTORY_PLACEHOLDER/$inventory_content}"
# The prompt and every request body travel through FILES, never argv: SOUL.md
# plus the inventory is far past Linux MAX_ARG_STRLEN (128 KiB), and an argv
# string that large makes jq/curl die with "Argument list too long".
# printf is a builtin, so writing it here never execs with the big string.
system_prompt_file="$work_dir/system-prompt.txt"
printf '%s' "$system_prompt" > "$system_prompt_file"

# _ev_build_payload <user_prompt_file> <payload_file>: shared by the full
# build loop and --relabel so the request shape (model, max_tokens,
# reasoning.effort) never drifts between the two.
_ev_build_payload() {
  local user_prompt_file="$1" payload_file="$2"
  jq -n --arg model "$JEV_EVAL_LABEL_MODEL" --argjson max_tokens "$JEV_EVAL_LABEL_MAX_TOKENS" \
    --arg reasoning_effort "$JEV_EVAL_LABEL_REASONING_EFFORT" \
    --rawfile sys "$system_prompt_file" --rawfile user "$user_prompt_file" \
    '{model:$model, temperature:0, max_tokens:$max_tokens, response_format:{type:"json_object"},
      messages:[{role:"system",content:$sys},{role:"user",content:$user}]}
     + (if $reasoning_effort != "" then {reasoning:{effort:$reasoning_effort}} else {} end)' \
    > "$payload_file"
}

# _ev_call_labeller <payload_file> <resp_file> <label_file> <meta_file>:
# posts to OpenRouter, writes the (possibly empty, on any failure)
# completion content to label_file, and ALWAYS writes meta_file --
# http_status/curl_rc/finish_reason/raw_content -- so a null label is
# diagnosable however it failed.
_ev_call_labeller() {
  local payload_file="$1" resp_file="$2" label_file="$3" meta_file="$4"
  local http_code curl_rc content finish_reason
  set +e
  http_code=$(curl -sS --max-time 60 --retry 2 -o "$resp_file" -w '%{http_code}' \
    -H @"$or_hdr" -H "Content-Type: application/json" --data-binary @"$payload_file" "$JEV_EVAL_OPENROUTER_URL")
  curl_rc=$?
  set -e
  content=$(jq -r '.choices[0].message.content // empty' "$resp_file" 2>/dev/null || true)
  content=$(printf '%s' "$content" | sed -e 's/^```json//' -e 's/^```//' -e 's/```$//')
  finish_reason=$(jq -r '.choices[0].finish_reason // empty' "$resp_file" 2>/dev/null || true)
  if [ "$curl_rc" -eq 0 ] && [ "${http_code:0:1}" = "2" ]; then
    printf '%s' "$content" > "$label_file"
  else
    : > "$label_file"
  fi
  jq -n --arg http_status "$http_code" --argjson curl_rc "$curl_rc" \
    --arg finish_reason "$finish_reason" --arg raw_content "$content" \
    '{http_status:$http_status, curl_rc:$curl_rc,
      finish_reason:(if $finish_reason=="" then null else $finish_reason end),
      raw_content:$raw_content}' > "$meta_file"
}

# _ev_print_label_error_counts <jsonl_file>: a count-by-kind summary,
# printed at the end of both the full build and --relabel, so "unlabelled=N"
# is never the only signal -- the WHY is one grep away.
_ev_print_label_error_counts() {
  local file="$1" counts
  counts=$(jq -r 'select(.label_error != null) | .label_error.kind' "$file" 2>/dev/null | sort | uniq -c | sort -rn || true)
  if [ -n "$counts" ]; then
    echo "jev-eval-build.sh: label errors by kind:" >&2
    printf '%s\n' "$counts" | while read -r cnt kind; do
      echo "  ${kind}: ${cnt}" >&2
    done
  fi
}

# ── --relabel mode: re-labels only label==null rows in FILE, in place,
#    from each row's own stored thread_so_far/full_thread. No Intercom
#    calls. Exits here. ──
if [ -n "$relabel_file" ]; then
  [ -r "$relabel_file" ] || _ev_die 6 "--relabel file not readable: $relabel_file"
  [ -s "$relabel_file" ] || _ev_die 6 "--relabel file is empty: $relabel_file"
  [ -w "$(dirname "$relabel_file")" ] || _ev_die 6 "--relabel file's directory is not writable: $(dirname "$relabel_file")"

  review_date="$(basename "$relabel_file" | grep -oE '[0-9]{8}' | head -1 || true)"
  [ -n "$review_date" ] || review_date="$(date -u +%Y%m%d)"
  review_file="$JEV_EVAL_DIR/review-${review_date}.md"
  if [ ! -e "$review_file" ]; then
    mkdir -p "$JEV_EVAL_DIR"
    {
      echo "# Jev eval review — ${review_date}"
      echo
      echo "One section per disagreement or unlabelled row. Fill in \`verdict:\` with"
      echo "either \`agree\` or a replacement label JSON object; then run"
      echo "\`jev-eval-build.sh --apply-review <this file>\`."
      echo
    } > "$review_file"
  fi
  chmod 600 "$review_file" 2>/dev/null || true

  out_file="$work_dir/relabel-out.jsonl"
  : > "$out_file"

  n_attempted=0
  n_fixed=0
  n_skipped_no_thread=0
  i=0
  while IFS= read -r line || [ -n "$line" ]; do
    i=$((i + 1))
    if [ -z "$line" ]; then
      continue
    fi

    is_null=$(printf '%s' "$line" | jq -r '.label == null' 2>/dev/null || echo false)
    if [ "$is_null" != "true" ]; then
      # Already labelled -- pass the ORIGINAL line through unmodified
      # (byte-identical), never re-serialized.
      printf '%s\n' "$line" >> "$out_file"
      continue
    fi

    row_file="$work_dir/relabel-row-${i}.json"
    printf '%s' "$line" > "$row_file"
    conv_id=$(jq -r '.conv_id' "$row_file")
    turn_idx=$(jq -r '.turn_index' "$row_file")

    has_full_thread=$(jq -r '(.full_thread.parts // empty) | length > 0' "$row_file" 2>/dev/null || echo false)
    if [ "$has_full_thread" != "true" ]; then
      n_skipped_no_thread=$((n_skipped_no_thread + 1))
      echo "jev-eval-build.sh: WARN conv=${conv_id} turn=${turn_idx} has no full_thread stored (pre-fix gold row) -- cannot relabel, left unlabelled. Rebuild this row's gold set to store full_thread going forward." >&2
      updated=$(jq -c '.label_error = {"kind":"missing_full_thread","http_status":null,"curl_rc":null,"finish_reason":null,"parse_error":"row has no full_thread stored; store it going forward","raw_content":""}' "$row_file")
      printf '%s\n' "$updated" >> "$out_file"
      continue
    fi

    n_attempted=$((n_attempted + 1))
    attempt=0
    fixed=0
    finalized=""
    while [ "$attempt" -lt 3 ] && [ "$fixed" -eq 0 ]; do
      attempt=$((attempt + 1))
      user_prompt_file="$work_dir/relabel-user-prompt-${i}-${attempt}.txt"
      python3 "$PY_SCRIPT" build-prompt "$row_file" > "$user_prompt_file"
      payload_file="$work_dir/relabel-payload-${i}-${attempt}.json"
      _ev_build_payload "$user_prompt_file" "$payload_file"

      resp_file="$work_dir/relabel-resp-${i}-${attempt}.json"
      label_file="$work_dir/relabel-label-${i}-${attempt}.json"
      meta_file="$work_dir/relabel-meta-${i}-${attempt}.json"
      _ev_call_labeller "$payload_file" "$resp_file" "$label_file" "$meta_file"

      finalized=$(python3 "$PY_SCRIPT" finalize-relabel-row "$row_file" "$label_file" "$meta_file" "$JEV_EVAL_QUESTIONS_FILE" "$JEV_EVAL_INVENTORY_FILE")
      new_label=$(printf '%s' "$finalized" | jq -r '.row.label')
      [ "$new_label" != "null" ] && fixed=1
    done

    new_row=$(printf '%s' "$finalized" | jq -c '.row')
    review_needed=$(printf '%s' "$finalized" | jq -r '.review_needed')
    parse_error=$(printf '%s' "$finalized" | jq -r '.parse_error // empty')

    printf '%s\n' "$new_row" >> "$out_file"
    [ "$fixed" -eq 1 ] && n_fixed=$((n_fixed + 1))

    if [ "$review_needed" = "true" ]; then
      {
        echo "### conv=${conv_id} turn=${turn_idx}"
        echo
        [ -n "$parse_error" ] && echo "labeller error: ${parse_error}"
        echo '```json'
        printf '%s' "$new_row" | jq '.'
        echo '```'
        echo
        echo "verdict: "
        echo
      } >> "$review_file"
    fi
  done < "$relabel_file"

  # Atomic overwrite at 0600: temp file in the SAME directory as the
  # target (so the final `mv` is a same-filesystem rename, not a copy),
  # never a partially-written gold file on interruption.
  tmp_out="$(mktemp "$(dirname "$relabel_file")/.jev-relabel.XXXXXX")"
  ( umask 077; cp "$out_file" "$tmp_out" )
  chmod 600 "$tmp_out"
  mv -f "$tmp_out" "$relabel_file"

  echo "jev-eval-build.sh: relabel attempted=${n_attempted} fixed=${n_fixed} still-unlabelled=$((n_attempted - n_fixed)) skipped-no-full_thread=${n_skipped_no_thread}" >&2
  _ev_print_label_error_counts "$relabel_file"
  echo "jev-eval-build.sh: rewrote $relabel_file" >&2
  exit 0
fi

# ── closer-phrase list, from production, not hardcoded ──────────
# is_closer_text() (lib.py) needs jev-router.ts's exact CLOSER_PHRASES set
# for the "closer" stratum -- reused via jev-state-cli.ts's
# --dump-closer-phrases mode (JEV_EVAL_STATE_CLI_CMD overrides the command
# for tests, mirroring jev-eval-run.sh's STATE_CLI_CMD resolution), never
# an independently hardcoded Python copy that can drift from what
# isCloserShaped() actually does (QA re-review finding 4 on PR #1021).
STATE_CLI="$REPO_ROOT/plugins/intercom/dist/jev-state-cli.js"
STATE_CLI_CMD=""
if [ -n "${JEV_EVAL_STATE_CLI_CMD:-}" ]; then
  STATE_CLI_CMD="$JEV_EVAL_STATE_CLI_CMD"
elif [ -f "$STATE_CLI" ]; then
  STATE_CLI_CMD="node $STATE_CLI"
else
  _ev_die 4 "state-parity CLI not built: $STATE_CLI (run 'pnpm --dir plugins/intercom build', or set JEV_EVAL_STATE_CLI_CMD for tests)"
fi
closer_phrases_file="$work_dir/closer-phrases.json"
$STATE_CLI_CMD --dump-closer-phrases > "$closer_phrases_file" </dev/null \
  || _ev_die 4 "failed to fetch the closer-phrase list from $STATE_CLI_CMD --dump-closer-phrases"
[ -s "$closer_phrases_file" ] || _ev_die 4 "closer-phrase list from $STATE_CLI_CMD --dump-closer-phrases was empty"
export JEV_EVAL_CLOSER_PHRASES_FILE="$closer_phrases_file"

# ── Intercom token ────────────────────────────────────────────
if [ -z "${MUSOAI_INTERCOM_TOKEN:-}" ] && [ -r "$JEV_EVAL_INTERCOM_ENV_FILE" ]; then
  MUSOAI_INTERCOM_TOKEN="$(grep -m1 '^MUSOAI_INTERCOM_TOKEN=' "$JEV_EVAL_INTERCOM_ENV_FILE" 2>/dev/null | cut -d= -f2-)"
fi
[ -n "${MUSOAI_INTERCOM_TOKEN:-}" ] || _ev_die 2 "MUSOAI_INTERCOM_TOKEN not set and not found in $JEV_EVAL_INTERCOM_ENV_FILE"
INTERCOM_API="${JEV_EVAL_INTERCOM_API:-https://api.intercom.io}"

# ── Caroline's posting admin id ─────────────────────────────────
# Resolved the SAME way production does: the plugin posts every Caroline
# reply with account.botAdminId (config.ts), loaded from
# channels.intercom.accounts.<account>.botAdminId in the gateway config
# (JEV_EVAL_EDGE_CONFIG, live on the edge host at
# /root/.openclaw-edge/openclaw.json). CAROLINE_BOT_ADMIN_ID overrides this
# resolution entirely (e.g. a non-default account, or a test fixture).
#
# This MUST fail closed: load_conv_parts's role_of() labels every admin
# part "admin" when bot_admin_id is empty, and jev-state-cli's mapAuthor
# DROPS "admin" -- so an unresolved id would silently produce v1 state with
# ZERO Caroline turns in every thread, breaking parity with production
# (handler.ts's buildRecentPartsFromLiveConversation, which keys "bot" off
# the same botAdminId) without any error.
if [ -z "${CAROLINE_BOT_ADMIN_ID:-}" ] && [ -r "$JEV_EVAL_EDGE_CONFIG" ]; then
  CAROLINE_BOT_ADMIN_ID="$(jq -r --arg acct "$JEV_EVAL_INTERCOM_ACCOUNT" \
    '.channels.intercom.accounts[$acct].botAdminId // empty' "$JEV_EVAL_EDGE_CONFIG" 2>/dev/null)"
fi
[ -n "${CAROLINE_BOT_ADMIN_ID:-}" ] || _ev_die 2 \
  "CAROLINE_BOT_ADMIN_ID could not be resolved -- set it directly, or point JEV_EVAL_EDGE_CONFIG at a gateway config with channels.intercom.accounts.${JEV_EVAL_INTERCOM_ACCOUNT}.botAdminId (checked: $JEV_EVAL_EDGE_CONFIG). Refusing to run with an unresolved id: every Caroline turn would be silently mislabelled \"admin\" and dropped from v1 state."

intercom_hdr="$work_dir/intercom-auth.hdr"
( umask 077; printf 'Authorization: Bearer %s\n' "$MUSOAI_INTERCOM_TOKEN" > "$intercom_hdr" )

_ev_intercom_get() {
  local conv_id="$1" out_file="$2" attempt=0 code
  while [ "$attempt" -lt 3 ]; do
    code=$(curl -sS -o "$out_file" -w '%{http_code}' \
      -H @"$intercom_hdr" -H "Intercom-Version: 2.11" -H "Accept: application/json" \
      "$INTERCOM_API/conversations/${conv_id}?display_as=plaintext") || code="000"
    case "$code" in
      2*) return 0 ;;
      429|5*) attempt=$((attempt + 1)); sleep $((1 << attempt)) ;;
      *) return 1 ;;
    esac
  done
  return 1
}

search_truncated_flag="$work_dir/search-truncated.flag"

_ev_intercom_search_ids() {
  # Paginates until Intercom stops returning a `pages.next` cursor (i.e.
  # every matching conversation has been enumerated), NOT after a fixed
  # page count -- --max-pages is only a safety cap for a pathologically
  # large window, and hitting it is a truncation, reported loudly below,
  # never a silent stop.
  local since="$1" cursor="" page=0 code resp_file="$work_dir/search-resp.json"
  while [ "$page" -lt "$max_pages" ]; do
    local pagination='{"per_page":150}'
    [ -n "$cursor" ] && pagination="{\"per_page\":150,\"starting_after\":\"$cursor\"}"
    local body
    body=$(jq -nc --argjson since "$since" --argjson pagination "$pagination" \
      '{query:{field:"updated_at", operator:">", value:$since}, pagination:$pagination}')
    : > "$resp_file"
    code=$(curl -sS -X POST -o "$resp_file" -w '%{http_code}' \
      -H @"$intercom_hdr" -H "Intercom-Version: 2.11" -H "Content-Type: application/json" \
      -H "Accept: application/json" -d "$body" "$INTERCOM_API/conversations/search") || code="000"
    case "$code" in
      2*) ;;
      000|'') _ev_die 4 "Intercom conversation search: transport failure (page ${page}) -- refusing to sample from an unknown result set" ;;
      401|403) _ev_die 4 "Intercom conversation search: credential rejected (HTTP $code, page ${page})" ;;
      *) _ev_die 4 "Intercom conversation search: HTTP $code (page ${page})" ;;
    esac
    jq -e 'type == "object" and (.conversations | type == "array")' "$resp_file" >/dev/null 2>&1 \
      || _ev_die 4 "Intercom conversation search: unparseable response shape (HTTP $code, page ${page})"
    jq -r '.conversations[] | select(.id != null) | .id | tostring' "$resp_file"
    cursor=$(jq -r '.pages.next.starting_after // empty' "$resp_file")
    [ -z "$cursor" ] && break
    page=$((page + 1))
  done
  if [ "$page" -ge "$max_pages" ] && [ -n "$cursor" ]; then
    echo "jev-eval-build.sh: WARN Intercom conversation search hit --max-pages=${max_pages} (150/conversations per page, so ~$((max_pages * 150)) conversations) with a next-page cursor still set -- results are TRUNCATED, not exhausted. Raise --max-pages to widen the window." >&2
    echo 1 > "$search_truncated_flag"
  fi
}

now_epoch=$(date +%s)
since_epoch=$((now_epoch - days * 86400))
search_ids_raw="$work_dir/search-ids.raw.txt"
_ev_intercom_search_ids "$since_epoch" > "$search_ids_raw"

conv_dir="$work_dir/convs"
mkdir -p "$conv_dir"
ids_file="$work_dir/ids.txt"
{ sort -u "$search_ids_raw"; printf '%s\n' "${include_convs[@]:-}"; } | grep . | sort -u > "$ids_file" || : > "$ids_file"

while IFS= read -r cid; do
  [ -n "$cid" ] || continue
  _ev_intercom_get "$cid" "$conv_dir/${cid}.json" || echo "jev-eval-build.sh: WARN could not fetch conv=$cid" >&2
done < "$ids_file"

# Keep only conversations Caroline actually touched (an admin reply carrying
# the bot admin id, when known; otherwise any admin reply -- see the module
# doc's note on this fallback).
kept_ids_file="$work_dir/kept-ids.txt"
: > "$kept_ids_file"
while IFS= read -r cid; do
  [ -n "$cid" ] || continue
  [ -s "$conv_dir/${cid}.json" ] || continue
  if [ -n "$CAROLINE_BOT_ADMIN_ID" ]; then
    jq -e --arg id "$CAROLINE_BOT_ADMIN_ID" \
      '[(.source, ((.conversation_parts.conversation_parts // [])[])) | select(.author.type=="admin" and .author.id==$id)] | length > 0' \
      "$conv_dir/${cid}.json" >/dev/null 2>&1 && echo "$cid" >> "$kept_ids_file"
  else
    jq -e '[(.source, ((.conversation_parts.conversation_parts // [])[])) | select(.author.type=="admin")] | length > 0' \
      "$conv_dir/${cid}.json" >/dev/null 2>&1 && echo "$cid" >> "$kept_ids_file"
  fi
done < "$ids_file"
for cid in "${include_convs[@]:-}"; do
  [ -n "$cid" ] && [ -s "$conv_dir/${cid}.json" ] && echo "$cid" >> "$kept_ids_file"
done
sort -u -o "$kept_ids_file" "$kept_ids_file"

# ── journal / trajectory evidence ──────────────────────────────
journal_file="$work_dir/journal.log"
if [ -n "${JEV_EVAL_JOURNAL_FILE:-}" ]; then
  cat "$JEV_EVAL_JOURNAL_FILE" > "$journal_file"
else
  journalctl -u "$JEV_EVAL_EDGE_UNIT" --since "${days} days ago" --no-pager -o short-unix \
    > "$journal_file" 2>/dev/null || : > "$journal_file"
fi

# Parse the journal via lib.py's parse_journal (loaded in-process, not
# re-embedded here) -- one call for escalations, one for tickets.
python3 - "$PY_SCRIPT" "$journal_file" > "$work_dir/escalations.json" <<'PYEOF'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("lib", sys.argv[1])
lib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lib)
escalations, tickets = lib.parse_journal(sys.argv[2])
json.dump(escalations, sys.stdout)
PYEOF
python3 - "$PY_SCRIPT" "$journal_file" > "$work_dir/tickets.json" <<'PYEOF'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("lib", sys.argv[1])
lib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lib)
_escalations, tickets = lib.parse_journal(sys.argv[2])
json.dump(tickets, sys.stdout)
PYEOF

traj_config="$work_dir/traj-config.json"
jq -n \
  --arg traj_source "$JEV_EVAL_TRAJECTORY_SOURCE" \
  --arg traj_glob "$JEV_EVAL_TRAJECTORY_GLOB" \
  --arg traj_dbs "$JEV_EVAL_TRAJECTORY_DBS" \
  '{traj_source:$traj_source, traj_glob:$traj_glob, traj_dbs:$traj_dbs}' > "$traj_config"
python3 - "$PY_SCRIPT" "$traj_config" > "$work_dir/trajectory.json" <<'PYEOF'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("lib", sys.argv[1])
lib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lib)
with open(sys.argv[2]) as fh:
    cfg = json.load(fh)
per_conv = lib.resolve_trajectory(cfg)
json.dump({conv: events for conv, events in per_conv.items()}, sys.stdout)
PYEOF

# ── enumerate turns, stratify, sample ──────────────────────────
turns_file="$work_dir/turns.jsonl"
python3 "$PY_SCRIPT" enumerate "$conv_dir" "$kept_ids_file" "$CAROLINE_BOT_ADMIN_ID" \
  "$work_dir/escalations.json" "$work_dir/tickets.json" "$work_dir/trajectory.json" > "$turns_file"

n_turns=$(grep -c . "$turns_file" || true)
[ "$n_turns" -gt 0 ] || _ev_die 5 "zero candidate customer turns found across $(grep -c . "$kept_ids_file" || echo 0) conversation(s) in the last ${days}d"

include_csv=""
for cid in "${include_convs[@]:-}"; do
  [ -n "$cid" ] && include_csv="${include_csv}${cid},"
done
sampled_file="$work_dir/sampled.jsonl"
python3 "$PY_SCRIPT" sample "$turns_file" "$size" "$include_csv" "$seed" > "$sampled_file"

review_date="$(date -u +%Y%m%d)"
gold_file_raw="$work_dir/gold-raw.jsonl"
: > "$gold_file_raw"
review_file="$work_dir/review-${review_date}.md"
{
  echo "# Jev eval review — ${review_date}"
  echo
  echo "One section per disagreement or unlabelled row. Fill in \`verdict:\` with"
  echo "either \`agree\` or a replacement label JSON object; then run"
  echo "\`jev-eval-build.sh --apply-review <this file>\`."
  echo
} > "$review_file"

n_sampled=$(grep -c . "$sampled_file" || true)
n_known_facts_missing=0
n_labelled=0
n_unlabelled=0
i=0
while IFS= read -r turn_json; do
  [ -n "$turn_json" ] || continue
  i=$((i + 1))
  turn_record="$work_dir/turn-${i}.json"
  printf '%s' "$turn_json" > "$turn_record"

  user_prompt_file="$work_dir/user-prompt-${i}.txt"
  python3 "$PY_SCRIPT" build-prompt "$turn_record" > "$user_prompt_file"
  payload_file="$work_dir/payload-${i}.json"
  _ev_build_payload "$user_prompt_file" "$payload_file"

  resp_file="$work_dir/resp-${i}.json"
  label_file="$work_dir/label-${i}.json"
  meta_file="$work_dir/meta-${i}.json"
  _ev_call_labeller "$payload_file" "$resp_file" "$label_file" "$meta_file"

  finalized=$(python3 "$PY_SCRIPT" finalize-row "$turn_record" "$label_file" "$meta_file" "$JEV_EVAL_QUESTIONS_FILE" "$JEV_EVAL_INVENTORY_FILE")
  gold_row=$(printf '%s' "$finalized" | jq -c '.gold_row')
  review_needed=$(printf '%s' "$finalized" | jq -r '.review_needed')
  parse_error=$(printf '%s' "$finalized" | jq -r '.parse_error // empty')

  printf '%s\n' "$gold_row" >> "$gold_file_raw"
  if [ "$(printf '%s' "$gold_row" | jq -r '.label')" = "null" ]; then
    n_unlabelled=$((n_unlabelled + 1))
  else
    n_labelled=$((n_labelled + 1))
  fi
  if [ "$(printf '%s' "$gold_row" | jq -r '.thread_so_far.known_facts_missing == true')" = "true" ]; then
    n_known_facts_missing=$((n_known_facts_missing + 1))
  fi

  if [ "$review_needed" = "true" ]; then
    conv_id=$(printf '%s' "$gold_row" | jq -r '.conv_id')
    turn_idx=$(printf '%s' "$gold_row" | jq -r '.turn_index')
    {
      echo "### conv=${conv_id} turn=${turn_idx}"
      echo
      [ -n "$parse_error" ] && echo "labeller error: ${parse_error}"
      echo '```json'
      printf '%s' "$gold_row" | jq '.'
      echo '```'
      echo
      echo "verdict: "
      echo
    } >> "$review_file"
  fi
done < "$sampled_file"

truncated=false
[ -s "$search_truncated_flag" ] && truncated=true
echo "jev-eval-build.sh: sampled=${n_sampled} labelled=${n_labelled} unlabelled=${n_unlabelled} known_facts_missing=${n_known_facts_missing} truncated=${truncated}" >&2
if [ "$n_known_facts_missing" -gt 0 ]; then
  echo "jev-eval-build.sh: WARN known_facts_missing=${n_known_facts_missing}/${n_sampled} rows built with no known_facts (founding/plan/prior_chats) -- this harness has no read-only way to reproduce production's live Muso-admin-API snapshot lookup + Intercom prior-conversations call, so it never fabricates them; see jev-eval-build.sh's enumerate comment." >&2
fi
_ev_print_label_error_counts "$gold_file_raw"

# ── redact + write outputs (0700 dir, 0600 files, established above) ──
out_gold="$JEV_EVAL_DIR/caroline-gold-${review_date}.jsonl"
if [ -r "$REDACT_SED" ]; then
  sed -E -f "$REDACT_SED" "$gold_file_raw" > "$out_gold"
else
  cp "$gold_file_raw" "$out_gold"
fi
chmod 600 "$out_gold"

out_review="$JEV_EVAL_DIR/review-${review_date}.md"
if [ -r "$REDACT_SED" ]; then
  sed -E -f "$REDACT_SED" "$review_file" > "$out_review"
else
  cp "$review_file" "$out_review"
fi
chmod 600 "$out_review"

echo "jev-eval-build.sh: wrote $out_gold and $out_review" >&2
