#!/usr/bin/env bash
# dispatch-cv-batch.sh — agent-callable wrapper around the Lobster MVP
# pipeline. Solves a real problem: the `lobster` tool's gateway schema
# advertises `flowId` and `flowExpectedRevision` as optional parameters
# (because the same tool handles both run + resume actions). Schema-driven
# agents fill those fields in, then Lobster's run action handler throws
# "run action does not accept flowId or flowExpectedRevision".
#
# By going through `exec` (which has a stable `command: string` schema)
# instead of the `lobster` tool directly, the agent has no field to
# populate beyond the command itself.
#
# Usage:
#   dispatch-cv-batch.sh [<batch_size>] [<thread_ts>] [<apply_mode>] [<selector_kind>] [<selector_id>]
#
# Args:
#   batch_size       1..500. Missing → safe default 500. Non-integer → exit 2.
#   thread_ts        Slack thread timestamp for the reply; "" if none
#   apply_mode       Missing → safe default "real". Must be in
#                    {real|REAL|dry|DRY|false|FALSE|true|TRUE} or exit 2.
#   selector_kind    "queue" (default) | "profile" | "credit"
#   selector_id      UUID for profile/credit modes; empty for queue
#
# Stdout: the Lobster pipeline's final-step output (the Slack summary text)
# Exit: 0 on success, non-zero on dispatch failure (HTTP/auth/etc.)

set -euo pipefail

# --- args ------------------------------------------------------------------

BATCH_SIZE_RAW="${1:-}"
THREAD_TS="${2:-}"
APPLY_MODE_RAW="${3:-}"
SELECTOR_KIND="${4:-queue}" # "queue" | "profile" | "credit"
SELECTOR_ID="${5:-}"

# Validate batch_size. Empty → safe default 500. Non-numeric → fail loud.
# Previously, garbage like `--help` silently became BATCH_SIZE=500 and
# APPLY_MODE=real, firing a 500-credit real apply on any typo. Verified
# live 2026-05-18 when a diagnostic probe `dispatch-cv-batch.sh --help`
# unintentionally landed 500 admin-API writes (PR #290 post-merge).
if [[ -z "$BATCH_SIZE_RAW" ]]; then
  BATCH_SIZE=500
elif [[ "$BATCH_SIZE_RAW" =~ ^[0-9]+$ ]]; then
  BATCH_SIZE="$BATCH_SIZE_RAW"
else
  echo "ERROR: batch_size must be a non-negative integer (got: '$BATCH_SIZE_RAW')" >&2
  echo "Usage: dispatch-cv-batch.sh [<batch_size>] [<thread_ts>] [<apply_mode>] [<selector_kind>] [<selector_id>]" >&2
  exit 2
fi
if (( BATCH_SIZE < 1 )); then
  BATCH_SIZE=1
elif (( BATCH_SIZE > 500 )); then
  BATCH_SIZE=500
fi

# Validate apply_mode. Empty → safe default real. Anything else must be
# one of the known tokens. Unknown tokens (typos, --help, etc.) MUST
# fail loud — silently routing to "real" or "dry" is a footgun either way.
case "$APPLY_MODE_RAW" in
  ""|real|REAL|false|FALSE) DRY_RUN_STR="false" ;;
  dry|DRY|true|TRUE)        DRY_RUN_STR="true"  ;;
  *)
    echo "ERROR: apply_mode must be 'real' or 'dry' (got: '$APPLY_MODE_RAW')" >&2
    echo "Usage: dispatch-cv-batch.sh [<batch_size>] [<thread_ts>] [<apply_mode>] [<selector_kind>] [<selector_id>]" >&2
    exit 2
    ;;
esac

# --- real-apply approval gate (2026-10-11) ---------------------------------
# A REAL run is allowed only when policies/credit-approval-automation.json has
# automations["credit-verification-batch"].approved == true. Otherwise every
# caller (the cron and the @Ops Slack triggers alike) is forced to DRY: score and
# report only, zero admin-API writes. Fails closed: if the registry is missing,
# unreadable or malformed, the run is dry.
#
# Why: until 2026-10-11 this pipeline's approve rule was inverted
# (approve_owning_track == 100 means the validator's owning-track shortcut did
# NOT fire), so real runs approved validator-DECLINED credit requests. The cron
# was disabled, but the Slack trigger defaults to real. Flipping `approved` is a
# captain decision made in a reviewed PR, never a node-8 toggle or an env var, so
# an agent with exec cannot re-arm it by pointing the gate at its own file. The
# same check runs again at the write boundary (apply-verdicts.sh).
# shellcheck source=../lib/real-apply-approval.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/real-apply-approval.sh"
CV_REAL_APPLY_BLOCKED=0
if [[ "$DRY_RUN_STR" == "false" ]]; then
  if ! cv_real_apply_approved; then
    DRY_RUN_STR="true"
    CV_REAL_APPLY_BLOCKED=1
    echo "WARN: real apply is NOT approved for credit-verification-batch (policies/credit-approval-automation.json: approved != true, approved_by/approval_ref empty, or unreadable). Running DRY: score + report only, zero writes." >&2
    echo "CV_REAL_APPLY_BLOCKED registry=policies/credit-approval-automation.json mode=dry writes=0"
  fi
fi

# Validate selector. Profile/credit modes REQUIRE a UUID; queue mode ignores ID.
case "$SELECTOR_KIND" in
  queue)
    SELECTOR_ID=""
    ;;
  profile|credit)
    UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    if [[ ! "$SELECTOR_ID" =~ $UUID_RE ]]; then
      echo "ERROR: selector_kind=$SELECTOR_KIND requires UUID selector_id (got: '$SELECTOR_ID')" >&2
      exit 2
    fi
    ;;
  *)
    echo "ERROR: selector_kind must be queue|profile|credit (got: '$SELECTOR_KIND')" >&2
    exit 2
    ;;
esac

# --- repeat-dispatch guard -------------------------------------------------
# 2026-07-22: a UVN-review ask was mis-routed onto this pipeline and the
# agent dispatched it once per profile — ~30 invocations in ~2 minutes,
# each a guaranteed "Sampled: 0" no-op posting a full Slack block. The
# pipeline is one-dispatch-per-request by contract; this sliding-window
# guard makes a loop impossible instead of merely documented. It sits
# BEFORE the config/pipeline checks so a looping agent is stopped on any
# host. The 4-hourly cron can never trip a 2-per-10-min window.
# State rot fails OPEN (warn + reset + proceed): this is an anti-spam
# guard, not a money gate — blocking the legit cron on a corrupt state
# file is the worse failure.

HISTORY_FILE="${CV_DISPATCH_HISTORY_FILE:-/var/lib/hydra/cv-dispatch-history}"
GUARD_WINDOW="${CV_DISPATCH_GUARD_WINDOW_SECS:-600}"
GUARD_MAX="${CV_DISPATCH_GUARD_MAX:-2}"

# Bash `(( ))` evaluates variable CONTENTS as expressions, so a non-numeric
# override would either abort the dispatch (`abc` → unbound-variable under
# set -u — the opposite of this guard's fail-open contract) or trip the
# guard spuriously (empty GUARD_MAX makes any count pass >=). Validate and
# fall back to defaults instead of trusting the env.
[[ "$GUARD_WINDOW" =~ ^[1-9][0-9]*$ ]] || { echo "WARN: bad CV_DISPATCH_GUARD_WINDOW_SECS='$GUARD_WINDOW' — using 600" >&2; GUARD_WINDOW=600; }
[[ "$GUARD_MAX" =~ ^[1-9][0-9]*$ ]] || { echo "WARN: bad CV_DISPATCH_GUARD_MAX='$GUARD_MAX' — using 2" >&2; GUARD_MAX=2; }

if [[ "${CV_DISPATCH_GUARD_DISABLE:-0}" != "1" ]]; then
  # Serialize the read/check/write below against concurrent dispatches
  # (cron + manual can overlap): without a lock, N racers can all read the
  # same prior state, all pass the count, and clobber each other's stamps —
  # letting more than GUARD_MAX pipelines launch. flock on an adjacent lock
  # file; any lock failure (unwritable dir, contention timeout) degrades to
  # the unlocked check with a WARN — fail-open per the guard contract. The
  # fd is closed right after the history write so the lock never spans the
  # (minutes-long) pipeline run itself.
  GUARD_LOCK_FD_OPEN=0
  if mkdir -p "$(dirname "$HISTORY_FILE")" 2>/dev/null \
     && { exec 9>"$HISTORY_FILE.lock"; } 2>/dev/null; then
    GUARD_LOCK_FD_OPEN=1
  fi
  if ! { (( GUARD_LOCK_FD_OPEN )) \
         && flock -w "${CV_DISPATCH_GUARD_LOCK_WAIT_SECS:-5}" 9 2>/dev/null; }; then
    echo "WARN: repeat-dispatch guard lock unavailable at $HISTORY_FILE.lock — unlocked check this run" >&2
  fi

  NOW=$(date +%s)
  RECENT=()
  if [[ -e "$HISTORY_FILE" ]]; then
    if ! GUARD_LINES=$(cat "$HISTORY_FILE" 2>/dev/null); then
      echo "WARN: repeat-dispatch guard state unreadable at $HISTORY_FILE — resetting" >&2
      GUARD_LINES=""
    fi
    CORRUPT=0
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      # Reject leading zeros too: `08` would pass a bare [0-9]+ check and
      # then throw "value too great for base" (octal) inside the window
      # arithmetic — route it into the CORRUPT path instead.
      if [[ "$line" =~ ^(0|[1-9][0-9]*)$ ]]; then
        # A future-dated stamp (clock correction, numeric corruption) makes
        # NOW - line negative — "recent" forever, tripping the guard on
        # every run until that future date. Treat anything beyond a small
        # skew tolerance as state rot → the CORRUPT reset path.
        if (( line > NOW + 60 )); then
          CORRUPT=1
        elif (( NOW - line < GUARD_WINDOW )); then
          RECENT+=("$line")
        fi
      else
        CORRUPT=1
      fi
    done <<< "$GUARD_LINES"
    if (( CORRUPT )); then
      echo "WARN: repeat-dispatch guard state corrupt at $HISTORY_FILE — resetting" >&2
      RECENT=()
    fi
  fi

  if (( ${#RECENT[@]} >= GUARD_MAX )); then
    echo "ERROR: repeat-dispatch guard tripped — ${#RECENT[@]} dispatch(es) in the last ${GUARD_WINDOW}s (max ${GUARD_MAX})." >&2
    echo "This looks like a loop. The batch pipeline is one-dispatch-per-request: it processes its whole selector in ONE run. Do NOT retry and do NOT iterate it over profiles." >&2
    echo "If you were asked about UVN / 'Verification Needed' credits, that is NOT this skill — the batch only fetches status=unverified. Route per SOUL.md ('UVN is NOT credit verification'): muso-ops-credits + muso-credit-investigator / muso-clickup-ticket-sweeper." >&2
    exit 2
  fi

  # Record this dispatch (prune stale entries while we're here). The
  # ${RECENT[@]+…} guard expands to zero words when the array is empty, so
  # printf writes exactly the surviving stamps + $NOW. Any write failure is
  # warn-and-proceed — see fail-open note above.
  if ! { mkdir -p "$(dirname "$HISTORY_FILE")" \
         && printf '%s\n' "${RECENT[@]+"${RECENT[@]}"}" "$NOW" > "$HISTORY_FILE"; } 2>/dev/null; then
    echo "WARN: repeat-dispatch guard state not writable at $HISTORY_FILE — guard inactive this run" >&2
  fi

  # Release the guard lock now — the pipeline run below can take minutes
  # and must not serialize behind it.
  if (( GUARD_LOCK_FD_OPEN )); then exec 9>&-; fi
fi

# --- gateway auth ----------------------------------------------------------

CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-/root/.openclaw-main/openclaw.json}"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
# Env override exists so the regression suite can point at the repo's copy of
# the pipeline instead of skipping every dispatch test on a host without
# /opt/hydra (the suite's own pipeline_deployed() helper used to paper over
# that by skipping — which is how the 2026-09-11 outbound-contract break could
# ship untested). Production never sets it.
PIPELINE_PATH="${CV_PIPELINE_PATH:-/opt/hydra/workspaces/operations/skills/muso-ops-credit-verification/pipelines/verify-credit-batch-mvp.lobster}"

if [[ ! -r "$CONFIG_PATH" ]]; then
  echo "ERROR: openclaw config not readable at $CONFIG_PATH" >&2
  exit 2
fi

TOK=$(jq -r '.gateway.auth.token // empty' "$CONFIG_PATH")
if [[ -z "$TOK" ]]; then
  echo "ERROR: gateway.auth.token missing from $CONFIG_PATH" >&2
  exit 3
fi

if [[ ! -r "$PIPELINE_PATH" ]]; then
  echo "ERROR: pipeline file missing at $PIPELINE_PATH" >&2
  exit 4
fi

# Serialize every real credit-status run with deterministic UVN automation.
# The lock spans the whole synchronous pipeline, not just its final API call,
# so both runners take their fraud snapshot and status decisions from a world
# in which the other runner cannot be writing concurrently. Dry-runs never
# write and therefore do not take this lock.
if [[ "$DRY_RUN_STR" == "false" ]]; then
  CREDIT_WRITE_LOCK_PATH="${CV_CREDIT_WRITE_LOCK_PATH:-/var/lib/hydra/credit-status-writes.lock}"
  CREDIT_WRITE_LOCK_WAIT="${CV_CREDIT_WRITE_LOCK_WAIT_SECS:-900}"
  if [[ ! "$CREDIT_WRITE_LOCK_WAIT" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: CV_CREDIT_WRITE_LOCK_WAIT_SECS must be a positive integer" >&2
    exit 5
  fi
  if ! mkdir -p "$(dirname "$CREDIT_WRITE_LOCK_PATH")" \
     || ! { exec 8>"$CREDIT_WRITE_LOCK_PATH"; }; then
    echo "ERROR: shared credit-write lock is unavailable at $CREDIT_WRITE_LOCK_PATH" >&2
    exit 5
  fi
  if ! flock -w "$CREDIT_WRITE_LOCK_WAIT" 8; then
    echo "ERROR: timed out waiting for shared credit-write lock at $CREDIT_WRITE_LOCK_PATH" >&2
    exit 5
  fi
fi

# --- build payload --------------------------------------------------------

# Per-run unique raw-batch handoff file for the pick→fraud steps. A static
# path is a cross-run race: two overlapping batches (cron + manual @-mention)
# would clobber each other's raw batch and the fraud scorer would silently
# score one run's credits against the other run's profile data (unmatched
# credits fall back to clean _fraud defaults). PID+epoch is unique enough —
# the gateway runs one dispatcher process per invocation on one host.
RAW_BATCH_FILE="/tmp/cv-fraud-raw-batch.$$.$(date +%s).json"

# Per-run id, threaded to every step as OPS_RUN_ID via the pipeline's env
# block. Same shape as apply-verdicts.sh's local fallback — but minted HERE
# so apply's audit log (lobster-apply.jsonl), the truth-floor results file
# (muso-admin-api.sh names it <run_id>.results.jsonl), and the Slack summary
# all carry ONE id. Without it the results writer fell back to the stale
# runlog latest.txt of the retired non-lobster path (2026-05-16) and
# Slack→truth-floor cross-referencing was broken.
RUN_ID="lobster-$(date -u +%Y%m%dT%H%M%SZ)-$$"

# argsJson is a STRING containing JSON (Lobster forwards it into the
# pipeline's args: block). The outer payload is JSON-with-nested-string.
ARGS_JSON=$(jq -nc \
  --argjson bs "$BATCH_SIZE" \
  --arg tts "$THREAD_TS" \
  --arg dry "$DRY_RUN_STR" \
  --arg skind "$SELECTOR_KIND" \
  --arg sid "$SELECTOR_ID" \
  --arg rbf "$RAW_BATCH_FILE" \
  --arg rid "$RUN_ID" \
  '{batch_size:$bs, thread_ts:$tts, dry_run:$dry, selector_kind:$skind, selector_id:$sid, raw_batch_file:$rbf, run_id:$rid}')

# Owner of the /tools/invoke call. A gateway with MORE THAN ONE configured
# agent refuses an unowned session key: the body's sessionKey defaults to
# "main", which belongs to no configured agent, and the call dies with
#   invalid_request: Multiple agents are configured, but session key "main"
#   has no explicit owner. Pass agentId or use an agent-prefixed session key.
# That is exactly how this 4-hourly cron died on 2026-09-11T16:01Z — and
# because the job ran as an agent turn, the scheduler kept reporting success
# for six days while every fire processed nothing. Pass BOTH an explicit
# agentId and an agent-prefixed sessionKey so resolution never depends on
# what the default "main" store happens to be bound to (openclaw picks the
# parsed session-key agent when the key is prefixed, and falls back to the
# explicit agentId otherwise — see resolveRequestedSessionAgentId).
# Env overrides exist so a test can pin the contract, not to retune prod.
CV_INVOKE_AGENT_ID="${CV_INVOKE_AGENT_ID:-operations}"
CV_INVOKE_SESSION_KEY="${CV_INVOKE_SESSION_KEY:-agent:operations:credit-verification-batch}"

PAYLOAD=$(jq -nc \
  --arg agentId "$CV_INVOKE_AGENT_ID" \
  --arg sessionKey "$CV_INVOKE_SESSION_KEY" \
  --arg pipeline "$PIPELINE_PATH" \
  --arg argsJson "$ARGS_JSON" \
  '{agentId:$agentId, sessionKey:$sessionKey,
    tool:"lobster", action:"run",
    args:{pipeline:$pipeline, argsJson:$argsJson, timeoutMs:700000}}')

# --- invoke ----------------------------------------------------------------

# The pipeline runs on this same host; once the (synchronous) invoke returns,
# the per-run raw-batch file is dead weight — clean it up on every exit path.
trap 'rm -f "$RAW_BATCH_FILE"' EXIT

# Trace the id before invoking so a run that dies mid-pipeline is still
# findable in lobster-apply.jsonl / results.jsonl from the transcript.
echo "[dispatch-cv-batch] run_id=$RUN_ID" >&2

RESPONSE=$(curl -sS -X POST "http://127.0.0.1:${GATEWAY_PORT}/tools/invoke" \
  -H "Authorization: Bearer $TOK" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")

OK=$(echo "$RESPONSE" | jq -r '.ok // false')
if [[ "$OK" != "true" ]]; then
  echo "ERROR: lobster invocation failed:" >&2
  echo "$RESPONSE" | jq . >&2
  # If we have a thread_ts, post a graceful failure message so the user
  # isn't left with a silent timeout. Otherwise just exit with the error
  # going to caller's stderr.
  if [[ -n "$THREAD_TS" ]]; then
    ERR_TYPE=$(echo "$RESPONSE" | jq -r '.error.type // "unknown"')
    ERR_MSG=$(echo "$RESPONSE" | jq -r '.error.message // "no error detail"')
    FAIL_TEXT=":x: *Lobster credit-verification failed*
batch_size=$BATCH_SIZE | error.type=\`$ERR_TYPE\`
\`\`\`
${ERR_MSG}
\`\`\`
No credits were processed."
    # Don't read OPENCLAW_CLI as a path — openclaw sets it to "1" as a
    # marker (see openclaw/dist/openclaw-exec-env.js:9-12 +
    # entry.js:117 ensureOpenClawExecMarkerOnProcess), which would resolve
    # OPENCLAW_BIN to literal "1" in any context where the marker leaks
    # (e.g., direct-exec subprocesses of the agent). Use OPENCLAW_BIN as
    # the explicit override and OPENCLAW_CLI_PATH (openclaw's own path env
    # at server.js:9325) as a secondary fallback before plain PATH lookup.
    OPENCLAW_BIN="${OPENCLAW_BIN:-${OPENCLAW_CLI_PATH:-openclaw}}"
    OPENCLAW_PROFILE="${OPENCLAW_PROFILE:-main}"
    TARGET_CHANNEL="${TARGET_CHANNEL:-C0APB2CMM7C}"
    if command -v "$OPENCLAW_BIN" >/dev/null 2>&1; then
      "$OPENCLAW_BIN" --profile "$OPENCLAW_PROFILE" message send \
        --account operations \
        --channel slack \
        --target "$TARGET_CHANNEL" \
        --reply-to "$THREAD_TS" \
        --message "$FAIL_TEXT" >/dev/null 2>&1 || true
    fi
  fi
  exit 5
fi

# Pipeline's last step (summary) emits the Slack-ready text on its stdout.
# Lobster's .result.details.output is an array of per-step stdouts. The
# render-dry-run-summary.sh step already posts to Slack itself when
# thread_ts is non-empty; we surface the text here so the agent can read
# it (e.g. for logging) without re-posting.
SUMMARY=$(echo "$RESPONSE" | jq -r '.result.details.output[-1] // .result.details.output // empty')
printf '%s\n' "$SUMMARY"

# --- zero-work is a FAILURE, not a quiet success ---------------------------
# A successful HTTP invoke is not a successful BATCH. On 2026-09-11..09-17
# this cron processed zero credits on every fire while the scheduler reported
# a healthy run, because a run's status was the agent turn finishing rather
# than what the batch actually did. The transport half of that is fixed above;
# this guard closes the other half. The pipeline publishes one
# `CV_BATCH_SUMMARY key=value` line on the stdout we just printed
# (render-dry-run-summary.sh), so the accounting comes from the pipeline's own
# numbers instead of being re-derived here.
#
# Outcome table — `queue_depth > 0` is the "there was work" predicate:
#   sampled=0 + queue_depth>0   silent_noop   exit 6  (the incident's shape)
#   attempted>0 + landed=0      all_failed    exit 6
#   line absent / malformed     unaccounted   exit 6
#   sampled=0 + queue_depth=0   no_work       exit 0  (nothing to do)
#   sampled>0 + attempted=0     no_eligible   exit 0  (nothing decidable)
#   otherwise                   ok            exit 0
# Dry runs never exit non-zero: they cannot write, so 0 processed is not a
# fault. A partially-failed real run (transport_failed>0, landed>0) stays a
# success here — the summary already pages it with :rotating_light: and the
# instruction is about runs that did nothing at all.
CV_ACCT_LINE=$(printf '%s\n' "$SUMMARY" | grep -oE '^CV_BATCH_SUMMARY .*' | tail -1 || true)
cv_acct() {
  [[ -n "$CV_ACCT_LINE" ]] || return 0
  printf '%s\n' "$CV_ACCT_LINE" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1
}
CV_QUEUE_DEPTH=$(cv_acct queue_depth)
CV_SAMPLED=$(cv_acct sampled)
CV_ATTEMPTED=$(cv_acct attempted)
CV_LANDED=$(cv_acct landed)
CV_REFUSED=$(cv_acct refused)
CV_TRANSPORT_FAILED=$(cv_acct transport_failed)

cv_numeric() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

# Every field the classification below depends on must be PRESENT and NUMERIC.
# A present-but-malformed contract line is not accounting: treating it as one
# recreates exactly the silent success this guard exists to prevent (QA on
# PR #961: `sampled=null` — what the renderer prints when .counts.total is
# absent after an upstream schema change — used to fall through the numeric
# tests to no_eligible and exit 0). Missing keys are named so the run log says
# which upstream field vanished.
CV_ACCT_INVALID=""
cv_required_numeric() {
  local -a bad=()
  local k v
  for k in queue_depth sampled attempted landed refused transport_failed; do
    v=$(cv_acct "$k")
    cv_numeric "$v" || bad+=("$k=${v:-<absent>}")
  done
  if (( ${#bad[@]} > 0 )); then
    CV_ACCT_INVALID=$(printf '%s,' "${bad[@]}")
    CV_ACCT_INVALID=${CV_ACCT_INVALID%,}
    return 1
  fi
  return 0
}

CV_OUTCOME=ok
CV_RC=0
if [[ "$DRY_RUN_STR" == "false" ]]; then
  if [[ -z "$CV_ACCT_LINE" ]]; then
    CV_OUTCOME=unaccounted; CV_RC=6
  elif ! cv_required_numeric; then
    CV_OUTCOME=unaccounted; CV_RC=6
  elif (( CV_SAMPLED == 0 )) && (( CV_QUEUE_DEPTH > 0 )); then
    CV_OUTCOME=silent_noop; CV_RC=6
  elif (( CV_ATTEMPTED > 0 )) && (( CV_LANDED == 0 )); then
    CV_OUTCOME=all_failed; CV_RC=6
  elif (( CV_SAMPLED == 0 )); then
    CV_OUTCOME=no_work
  elif (( CV_ATTEMPTED == 0 )); then
    CV_OUTCOME=no_eligible
  fi
elif (( CV_REAL_APPLY_BLOCKED )); then
  # A real run was requested but not approved, so it ran dry. Named
  # separately so the cron run log shows WHY nothing was written.
  CV_OUTCOME=dry_run_real_apply_not_approved
else
  CV_OUTCOME=dry_run
fi

# Report the control line whenever there is accounting to report, and always
# for a real run (where "no accounting" is itself the finding). A manual dry
# run whose stub/summary carries no contract line stays quiet rather than
# printing a row of `?`.
if [[ -n "$CV_ACCT_LINE" || "$DRY_RUN_STR" == "false" ]] || (( CV_REAL_APPLY_BLOCKED )); then
  printf 'CV_BATCH_RESULT queue_depth=%s sampled=%s attempted=%s landed=%s refused=%s transport_failed=%s outcome=%s\n' \
    "${CV_QUEUE_DEPTH:-?}" "${CV_SAMPLED:-?}" "${CV_ATTEMPTED:-?}" "${CV_LANDED:-?}" \
    "${CV_REFUSED:-?}" "${CV_TRANSPORT_FAILED:-?}" "$CV_OUTCOME"
fi

if (( CV_RC != 0 )); then
  case "$CV_OUTCOME" in
    silent_noop)
      echo "ERROR: credit-verification batch processed 0 credits while the unverified queue holds ${CV_QUEUE_DEPTH} — the pipeline ran but sampled nothing. Either the fetch step is broken or the queue selector no longer matches; this is NOT a quiet day and must not read as one." >&2
      ;;
    all_failed)
      echo "ERROR: credit-verification batch attempted ${CV_ATTEMPTED} credit write(s) and landed 0 (refused=${CV_REFUSED:-?}, transport_failed=${CV_TRANSPORT_FAILED:-?}) — the admin API rejected or never confirmed every write. Reconcile current credit state before retrying." >&2
      ;;
    unaccounted)
      echo "ERROR: the pipeline output carries no usable CV_BATCH_SUMMARY accounting (${CV_ACCT_INVALID:+invalid fields: ${CV_ACCT_INVALID}; }raw tail: ${SUMMARY:0:300}) — the run cannot be credited with any work, so it cannot report success. The summary step (render-dry-run-summary.sh) may have failed, or Lobster's details.output shape changed." >&2
      ;;
  esac
  exit "$CV_RC"
fi
