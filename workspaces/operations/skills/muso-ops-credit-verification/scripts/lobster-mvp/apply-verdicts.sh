#!/usr/bin/env bash
# apply-verdicts.sh — Lobster step: apply both buckets.
#   would_approve → PUT status=approved
#   would_uvn     → PUT status=user_verification_needed
#                   (the fraud subset is PUT with OPS_FLAG_REASON=fraud_multifactor
#                    so the truth-floor results.jsonl records WHY the credit was
#                    routed to UVN — the post-hoc summary/counter and the future
#                    DB fraud-state both key on that flag_reason.)
#
# Stdin:  verdict-engine.sh output {queue_depth, fetch_size, counts,
#                                    would_approve, would_uvn}
# Stdout: input + {apply: {dry_run, attempted, approve: {...}, uvn: {...},
#                          landed, refused, transport_failed, drifted,
#                          landed_ids, refused_ids, transport_failed_ids,
#                          drifted_ids, http_status}}
#
# Behavior gate:
#   dry_run="true"  (default; first positional arg) → no API call, pass-through
#   dry_run="false"                                  → chunked bulk PUTs
#
# Chunking: see CV_APPLY_CHUNK_SIZE (default 50) to stay under
# Cloudflare's ~100s origin timeout for the admin API.

set -euo pipefail

DRY_RUN_APPLY="${1:-${DRY_RUN_APPLY:-true}}"
ADMIN_API_SH="${ADMIN_API_SH:-/opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh}"
LOG_PATH="${OPS_LOBSTER_APPLY_LOG:-/var/log/openclaw/lobster-apply.jsonl}"
RUN_ID="${OPS_RUN_ID:-lobster-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
CHUNK_SIZE="${CV_APPLY_CHUNK_SIZE:-50}"
TRANSPORT_RETRY_DELAY_SECONDS="${CV_APPLY_TRANSPORT_RETRY_DELAY_SECONDS:-2}"

INPUT=$(cat)
WOULD_APPROVE=$(echo "$INPUT" | jq -c '.would_approve // []')
WOULD_UVN=$(echo "$INPUT" | jq -c '.would_uvn // []')
N_APPROVE=$(echo "$WOULD_APPROVE" | jq 'length')
N_UVN=$(echo "$WOULD_UVN" | jq 'length')

mkdir -p "$(dirname "$LOG_PATH")"
log_event() {
  local event="$1" extra="${2:-{\}}"
  jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg run_id "$RUN_ID" \
    --arg event "$event" \
    --argjson extra "$extra" \
    '{ts:$ts, run_id:$run_id, event:$event} + $extra' \
    >> "$LOG_PATH"
}

# ---- DRY RUN: pass through, no API call ------------------------------------
if [[ "$DRY_RUN_APPLY" == "true" ]]; then
  echo "$INPUT" | jq -c \
    --argjson apply '{"dry_run":true,"attempted":0,"approve":{"eligible":0,"landed":0,"refused":0,"transport_failed":0,"landed_ids":[],"refused_ids":[],"transport_failed_ids":[]},"uvn":{"eligible":0,"landed":0,"refused":0,"transport_failed":0,"landed_ids":[],"refused_ids":[],"transport_failed_ids":[]},"eligible":0,"landed":0,"refused":0,"transport_failed":0,"drifted":0,"http_status":null,"landed_ids":[],"refused_ids":[],"transport_failed_ids":[],"drifted_ids":[]}' \
    '. + {apply:$apply}'
  exit 0
fi

# ---- REAL APPLY -----------------------------------------------------------
log_event "apply_started" "$(jq -nc --argjson na "$N_APPROVE" --argjson nu "$N_UVN" '{would_approve_count:$na, would_uvn_count:$nu}')"

# Chunked PUT to /admin/credit-requests. Args: <items_array> <status> <bucket_label> [<flag_reason>]
# Echoes a JSON {landed_ids, refused_ids, transport_failed_ids, last_http}.
# Each chunk PUTs requestIds + status. CV_APPROVE_GATE_DISABLED is set
# only when status=approved (the gate exists for approve writes; UVN
# doesn't go through that gate). OPS_DRY_RUN=0 is the intent-explicit
# override applied to both. <flag_reason> (optional, UVN only) is forwarded to
# muso-admin-api.sh via OPS_FLAG_REASON so the truth floor records it; empty ⇒
# null flag_reason (ordinary UVN).
apply_chunked() {
  local items_json="$1"
  local status="$2"
  local bucket="$3"
  local flag_reason="${4:-}"

  local ids_json
  ids_json=$(echo "$items_json" | jq -c 'map(.cr_id)')
  local n_total
  n_total=$(echo "$ids_json" | jq 'length')

  local chunks
  chunks=$(echo "$ids_json" | jq -c "[_nwise(${CHUNK_SIZE})]")
  local num_chunks
  num_chunks=$(echo "$chunks" | jq 'length')

  log_event "chunked_${bucket}_started" "$(jq -nc --argjson n "$n_total" --argjson chunks "$num_chunks" --argjson cs "$CHUNK_SIZE" --arg st "$status" '{eligible_count:$n, num_chunks:$chunks, chunk_size:$cs, status:$st}')"

  local landed_acc='[]'
  local refused_acc='[]'
  local transport_failed_acc='[]'
  local last_http=""

  local evidence
  if [[ "$status" == "approved" ]]; then
    evidence="lobster-signal:approve_owning_track=100;total_risk<80;backtested_99.34pct"
  else
    evidence="lobster-signal:no_signal_approve;routed_to_uvn"
  fi

  local i
  for (( i=0; i<num_chunks; i++ )); do
    local chunk_ids chunk_n chunk_body chunk_resp chunk_json chunk_rc chunk_http chunk_dry
    local chunk_transport_exit chunk_attempts chunk_retry_exits
    chunk_ids=$(echo "$chunks" | jq -c ".[$i]")
    chunk_n=$(echo "$chunk_ids" | jq 'length')
    chunk_body=$(jq -nc --argjson ids "$chunk_ids" --arg st "$status" '{requestIds:$ids, status:$st}')

    log_event "${bucket}_chunk_put_attempt" "$(jq -nc --argjson i "$i" --argjson n "$chunk_n" --argjson ids "$chunk_ids" --arg st "$status" '{chunk_index:$i, chunk_count:$n, status:$st, request_ids:$ids}')"

    set +e
    if [[ "$status" == "approved" ]]; then
      chunk_resp=$(OPS_DRY_RUN=0 CV_APPROVE_GATE_DISABLED=1 EVIDENCE_EXCERPT="$evidence" \
        MUSO_ADMIN_PRECONNECT_RETRIES=1 MUSO_ADMIN_RETRY_DELAY_SECONDS="$TRANSPORT_RETRY_DELAY_SECONDS" \
        bash "$ADMIN_API_SH" --evidence-excerpt "$evidence" \
        call PUT /admin/credit-requests "$chunk_body" 2>&1)
    else
      chunk_resp=$(OPS_DRY_RUN=0 OPS_FLAG_REASON="$flag_reason" \
        MUSO_ADMIN_PRECONNECT_RETRIES=1 MUSO_ADMIN_RETRY_DELAY_SECONDS="$TRANSPORT_RETRY_DELAY_SECONDS" \
        bash "$ADMIN_API_SH" \
        call PUT /admin/credit-requests "$chunk_body" 2>&1)
    fi
    chunk_rc=$?
    set -e

    # The admin wrapper can emit a warning on stderr before its JSON envelope
    # (for example if the truth-floor file itself is unwritable). stderr is
    # intentionally captured for the apply log, so extract the last valid JSON
    # line rather than requiring the entire combined stream to be JSON.
    chunk_json=$(printf '%s\n' "$chunk_resp" | jq -Rrc 'fromjson? // empty' | tail -1)
    chunk_http=$(echo "$chunk_json" | jq -r '.http_status // empty' 2>/dev/null || true)
    chunk_dry=$(echo "$chunk_json" | jq -r '.dryRun // false' 2>/dev/null || echo false)
    chunk_transport_exit=$(echo "$chunk_json" | jq -r '.transport_error.curl_exit // empty' 2>/dev/null || true)
    chunk_attempts=$(echo "$chunk_json" | jq -r '.transport_attempts // .transport_error.attempts // 1' 2>/dev/null || echo 1)
    chunk_retry_exits=$(echo "$chunk_json" | jq -c '.transport_retry_exits // .transport_error.retry_exits // []' 2>/dev/null || echo '[]')
    [[ "$chunk_attempts" =~ ^[1-9][0-9]*$ ]] || chunk_attempts=1
    echo "$chunk_retry_exits" | jq -e 'type == "array"' >/dev/null 2>&1 || chunk_retry_exits='[]'
    last_http="$chunk_http"

    log_event "${bucket}_chunk_put_response" "$(jq -nc --argjson i "$i" --arg rc "$chunk_rc" --arg http "$chunk_http" --arg dr "$chunk_dry" --argjson attempts "$chunk_attempts" --argjson retry_exits "$chunk_retry_exits" --arg resp "$(echo "$chunk_resp" | head -c 300)" '{chunk_index:$i, put_rc:$rc, http_status:$http, dry_run_intercepted:$dr, transport_attempts:$attempts, transport_retry_exits:$retry_exits, response_head:$resp}')"

    if (( chunk_attempts > 1 )); then
      local recovered=false
      [[ "$chunk_rc" -eq 0 && "$chunk_http" == "200" && "$chunk_dry" != "true" ]] && recovered=true
      log_event "${bucket}_chunk_transport_retried" "$(jq -nc --argjson i "$i" --argjson attempts "$chunk_attempts" --argjson retry_exits "$chunk_retry_exits" --argjson recovered "$recovered" '{chunk_index:$i, attempts:$attempts, retry_exits:$retry_exits, recovered:$recovered}')"
    fi

    if [[ "$chunk_rc" -eq 0 && "$chunk_http" == "200" && "$chunk_dry" != "true" ]]; then
      landed_acc=$(printf '%s\n%s\n' "$landed_acc" "$chunk_ids" | jq -sc 'add')
      log_event "${bucket}_chunk_landed" "$(jq -nc --argjson i "$i" --argjson ids "$chunk_ids" '{chunk_index:$i, landed_ids:$ids}')"
    elif [[ -n "$chunk_transport_exit" ]]; then
      local transport_reason="transport_curl_${chunk_transport_exit}"
      local chunk_transport_failed
      chunk_transport_failed=$(echo "$chunk_ids" | jq -c \
        --arg reason "$transport_reason" \
        --argjson curl_exit "$chunk_transport_exit" \
        --argjson attempts "$chunk_attempts" \
        '[.[] | {cr_id: ., reason: $reason, curl_exit: $curl_exit, attempts: $attempts}]')
      transport_failed_acc=$(printf '%s\n%s\n' "$transport_failed_acc" "$chunk_transport_failed" | jq -sc 'add')
      log_event "${bucket}_chunk_transport_failed" "$(jq -nc --argjson i "$i" --argjson curl_exit "$chunk_transport_exit" --argjson attempts "$chunk_attempts" --argjson ids "$chunk_ids" '{chunk_index:$i, curl_exit:$curl_exit, attempts:$attempts, transport_failed_ids:$ids}')"
    else
      local reason="http_$chunk_http"
      [[ "$chunk_dry" == "true" ]] && reason="dry_run_intercepted"
      local chunk_refused
      chunk_refused=$(echo "$chunk_ids" | jq -c --arg reason "$reason" '[.[] | {cr_id: ., reason: $reason}]')
      refused_acc=$(printf '%s\n%s\n' "$refused_acc" "$chunk_refused" | jq -sc 'add')
      log_event "${bucket}_chunk_refused" "$(jq -nc --argjson i "$i" --arg reason "$reason" --arg http "$chunk_http" --argjson ids "$chunk_ids" '{chunk_index:$i, reason:$reason, http_status:$http, refused_ids:$ids}')"
    fi
  done

  jq -nc \
    --argjson landed "$landed_acc" \
    --argjson refused "$refused_acc" \
    --argjson transport_failed "$transport_failed_acc" \
    --arg http "$last_http" \
    '{landed_ids:$landed, refused_ids:$refused, transport_failed_ids:$transport_failed, last_http:$http}'
}

# Approve bucket
APPROVE_LANDED_IDS='[]'
APPROVE_REFUSED_IDS='[]'
APPROVE_TRANSPORT_FAILED_IDS='[]'
APPROVE_LAST_HTTP=""
if (( N_APPROVE > 0 )); then
  RES=$(apply_chunked "$WOULD_APPROVE" "approved" "approve")
  APPROVE_LANDED_IDS=$(echo "$RES" | jq -c '.landed_ids')
  APPROVE_REFUSED_IDS=$(echo "$RES" | jq -c '.refused_ids')
  APPROVE_TRANSPORT_FAILED_IDS=$(echo "$RES" | jq -c '.transport_failed_ids')
  APPROVE_LAST_HTTP=$(echo "$RES" | jq -r '.last_http')
fi

# UVN bucket. Split into fraud (carries flag_reason=fraud_multifactor) vs
# ordinary (null flag_reason) so the truth floor records why each credit landed
# in UVN. Both PUT the SAME status=user_verification_needed (no fraud DB status
# exists yet); only the recorded flag_reason differs. A fraud credit is one the
# scorer RE-BUCKETED (._signal.bucket=="signal_fraud") — enforce-only by
# construction. Do NOT key on ._fraud.over: shadow annotates over=true on every
# bucket WITHOUT re-bucketing, so an already-UVN credit would get a durable
# fraud_multifactor marker from a mode that is supposed to be observe-only.
UVN_LANDED_IDS='[]'
UVN_REFUSED_IDS='[]'
UVN_TRANSPORT_FAILED_IDS='[]'
UVN_LAST_HTTP=""
if (( N_UVN > 0 )); then
  FRAUD_UVN=$(echo "$WOULD_UVN" | jq -c '[.[] | select(._signal.bucket == "signal_fraud")]')
  PLAIN_UVN=$(echo "$WOULD_UVN" | jq -c '[.[] | select(._signal.bucket != "signal_fraud")]')
  N_FRAUD_UVN=$(echo "$FRAUD_UVN" | jq 'length')
  N_PLAIN_UVN=$(echo "$PLAIN_UVN" | jq 'length')

  if (( N_PLAIN_UVN > 0 )); then
    RES=$(apply_chunked "$PLAIN_UVN" "user_verification_needed" "uvn" "")
    UVN_LANDED_IDS=$(echo "$RES" | jq -c '.landed_ids')
    UVN_REFUSED_IDS=$(echo "$RES" | jq -c '.refused_ids')
    UVN_TRANSPORT_FAILED_IDS=$(echo "$RES" | jq -c '.transport_failed_ids')
    UVN_LAST_HTTP=$(echo "$RES" | jq -r '.last_http')
  fi
  if (( N_FRAUD_UVN > 0 )); then
    RES=$(apply_chunked "$FRAUD_UVN" "user_verification_needed" "uvn_fraud" "fraud_multifactor")
    UVN_LANDED_IDS=$(printf '%s\n%s\n' "$UVN_LANDED_IDS" "$(echo "$RES" | jq -c '.landed_ids')" | jq -sc 'add')
    UVN_REFUSED_IDS=$(printf '%s\n%s\n' "$UVN_REFUSED_IDS" "$(echo "$RES" | jq -c '.refused_ids')" | jq -sc 'add')
    UVN_TRANSPORT_FAILED_IDS=$(printf '%s\n%s\n' "$UVN_TRANSPORT_FAILED_IDS" "$(echo "$RES" | jq -c '.transport_failed_ids')" | jq -sc 'add')
    [[ -z "$UVN_LAST_HTTP" ]] && UVN_LAST_HTTP=$(echo "$RES" | jq -r '.last_http')
  fi
fi

APPROVE_LANDED_N=$(echo "$APPROVE_LANDED_IDS" | jq 'length')
APPROVE_REFUSED_N=$(echo "$APPROVE_REFUSED_IDS" | jq 'length')
APPROVE_TRANSPORT_FAILED_N=$(echo "$APPROVE_TRANSPORT_FAILED_IDS" | jq 'length')
UVN_LANDED_N=$(echo "$UVN_LANDED_IDS" | jq 'length')
UVN_REFUSED_N=$(echo "$UVN_REFUSED_IDS" | jq 'length')
UVN_TRANSPORT_FAILED_N=$(echo "$UVN_TRANSPORT_FAILED_IDS" | jq 'length')

TOTAL_LANDED=$(( APPROVE_LANDED_N + UVN_LANDED_N ))
TOTAL_REFUSED=$(( APPROVE_REFUSED_N + UVN_REFUSED_N ))
TOTAL_TRANSPORT_FAILED=$(( APPROVE_TRANSPORT_FAILED_N + UVN_TRANSPORT_FAILED_N ))
TOTAL_ELIGIBLE=$(( N_APPROVE + N_UVN ))

# Pick the more informative HTTP status for the legacy top-level field
HTTP_STATUS="$APPROVE_LAST_HTTP"
[[ -z "$HTTP_STATUS" ]] && HTTP_STATUS="$UVN_LAST_HTTP"

# Combined landed_ids / refused_ids for backwards-compat with
# render-dry-run-summary.sh / consumers reading top-level fields.
COMBINED_LANDED_IDS=$(printf '%s\n%s\n' "$APPROVE_LANDED_IDS" "$UVN_LANDED_IDS" | jq -sc 'add')
COMBINED_REFUSED_IDS=$(printf '%s\n%s\n' "$APPROVE_REFUSED_IDS" "$UVN_REFUSED_IDS" | jq -sc 'add')
COMBINED_TRANSPORT_FAILED_IDS=$(printf '%s\n%s\n' "$APPROVE_TRANSPORT_FAILED_IDS" "$UVN_TRANSPORT_FAILED_IDS" | jq -sc 'add')

log_event "apply_finished" "$(jq -nc --argjson al "$APPROVE_LANDED_N" --argjson ar "$APPROVE_REFUSED_N" --argjson at "$APPROVE_TRANSPORT_FAILED_N" --argjson ul "$UVN_LANDED_N" --argjson ur "$UVN_REFUSED_N" --argjson ut "$UVN_TRANSPORT_FAILED_N" '{approve_landed:$al, approve_refused:$ar, approve_transport_failed:$at, uvn_landed:$ul, uvn_refused:$ur, uvn_transport_failed:$ut}')"

APPLY_OBJ=$(jq -nc \
  --argjson attempted "$TOTAL_ELIGIBLE" \
  --argjson eligible "$TOTAL_ELIGIBLE" \
  --argjson landed "$TOTAL_LANDED" \
  --argjson refused "$TOTAL_REFUSED" \
  --argjson transport_failed "$TOTAL_TRANSPORT_FAILED" \
  --argjson approve_eligible "$N_APPROVE" \
  --argjson approve_landed "$APPROVE_LANDED_N" \
  --argjson approve_refused "$APPROVE_REFUSED_N" \
  --argjson approve_transport_failed "$APPROVE_TRANSPORT_FAILED_N" \
  --argjson approve_landed_ids "$APPROVE_LANDED_IDS" \
  --argjson approve_refused_ids "$APPROVE_REFUSED_IDS" \
  --argjson approve_transport_failed_ids "$APPROVE_TRANSPORT_FAILED_IDS" \
  --argjson uvn_eligible "$N_UVN" \
  --argjson uvn_landed "$UVN_LANDED_N" \
  --argjson uvn_refused "$UVN_REFUSED_N" \
  --argjson uvn_transport_failed "$UVN_TRANSPORT_FAILED_N" \
  --argjson uvn_landed_ids "$UVN_LANDED_IDS" \
  --argjson uvn_refused_ids "$UVN_REFUSED_IDS" \
  --argjson uvn_transport_failed_ids "$UVN_TRANSPORT_FAILED_IDS" \
  --argjson landed_ids "$COMBINED_LANDED_IDS" \
  --argjson refused_ids "$COMBINED_REFUSED_IDS" \
  --argjson transport_failed_ids "$COMBINED_TRANSPORT_FAILED_IDS" \
  --arg http_status "$HTTP_STATUS" \
  '{dry_run:false, attempted:$attempted, eligible:$eligible, landed:$landed, refused:$refused, transport_failed:$transport_failed, drifted:0, http_status:$http_status, landed_ids:$landed_ids, refused_ids:$refused_ids, transport_failed_ids:$transport_failed_ids, drifted_ids:[],
    approve: {eligible:$approve_eligible, landed:$approve_landed, refused:$approve_refused, transport_failed:$approve_transport_failed, landed_ids:$approve_landed_ids, refused_ids:$approve_refused_ids, transport_failed_ids:$approve_transport_failed_ids},
    uvn:     {eligible:$uvn_eligible,     landed:$uvn_landed,     refused:$uvn_refused,     transport_failed:$uvn_transport_failed,     landed_ids:$uvn_landed_ids,     refused_ids:$uvn_refused_ids,     transport_failed_ids:$uvn_transport_failed_ids}}')

echo "$INPUT" | jq -c --argjson apply "$APPLY_OBJ" '. + {apply:$apply}'
