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
#                          landed, refused, drifted,
#                          landed_ids, refused_ids, drifted_ids, http_status}}
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
    --argjson apply '{"dry_run":true,"attempted":0,"approve":{"eligible":0,"landed":0,"refused":0,"landed_ids":[],"refused_ids":[]},"uvn":{"eligible":0,"landed":0,"refused":0,"landed_ids":[],"refused_ids":[]},"eligible":0,"landed":0,"refused":0,"drifted":0,"http_status":null,"landed_ids":[],"refused_ids":[],"drifted_ids":[]}' \
    '. + {apply:$apply}'
  exit 0
fi

# ---- REAL APPLY -----------------------------------------------------------
log_event "apply_started" "$(jq -nc --argjson na "$N_APPROVE" --argjson nu "$N_UVN" '{would_approve_count:$na, would_uvn_count:$nu}')"

# Chunked PUT to /admin/credit-requests. Args: <items_array> <status> <bucket_label> [<flag_reason>]
# Echoes (on stdout) a JSON {landed_ids: [...], refused_ids: [...], last_http: "..."}
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
  local last_http=""

  local evidence
  if [[ "$status" == "approved" ]]; then
    evidence="lobster-signal:approve_owning_track=100;total_risk<80;backtested_99.34pct"
  else
    evidence="lobster-signal:no_signal_approve;routed_to_uvn"
  fi

  local i
  for (( i=0; i<num_chunks; i++ )); do
    local chunk_ids chunk_n chunk_body chunk_resp chunk_rc chunk_http chunk_dry
    chunk_ids=$(echo "$chunks" | jq -c ".[$i]")
    chunk_n=$(echo "$chunk_ids" | jq 'length')
    chunk_body=$(jq -nc --argjson ids "$chunk_ids" --arg st "$status" '{requestIds:$ids, status:$st}')

    log_event "${bucket}_chunk_put_attempt" "$(jq -nc --argjson i "$i" --argjson n "$chunk_n" --argjson ids "$chunk_ids" --arg st "$status" '{chunk_index:$i, chunk_count:$n, status:$st, request_ids:$ids}')"

    set +e
    if [[ "$status" == "approved" ]]; then
      chunk_resp=$(OPS_DRY_RUN=0 CV_APPROVE_GATE_DISABLED=1 EVIDENCE_EXCERPT="$evidence" \
        bash "$ADMIN_API_SH" --evidence-excerpt "$evidence" \
        call PUT /admin/credit-requests "$chunk_body" 2>&1)
    else
      chunk_resp=$(OPS_DRY_RUN=0 OPS_FLAG_REASON="$flag_reason" \
        bash "$ADMIN_API_SH" \
        call PUT /admin/credit-requests "$chunk_body" 2>&1)
    fi
    chunk_rc=$?
    set -e

    chunk_http=$(echo "$chunk_resp" | jq -r '.http_status // empty' 2>/dev/null || true)
    chunk_dry=$(echo "$chunk_resp" | jq -r '.dryRun // false' 2>/dev/null || echo false)
    last_http="$chunk_http"

    log_event "${bucket}_chunk_put_response" "$(jq -nc --argjson i "$i" --arg rc "$chunk_rc" --arg http "$chunk_http" --arg dr "$chunk_dry" --arg resp "$(echo "$chunk_resp" | head -c 300)" '{chunk_index:$i, put_rc:$rc, http_status:$http, dry_run_intercepted:$dr, response_head:$resp}')"

    # Attribute PER ROW from the response body, never from the HTTP code alone.
    # The chunk-level inference this replaces read only the status: a 200 marked
    # every id in the chunk landed — including rows the backend had explicitly
    # reported in skippedIds — and any non-2xx marked every id refused,
    # including rows that really did persist. That is how the 2026-07-23 sweeps
    # reported rows as applied that had never moved.
    #
    # 200 and 409 both carry the same report. A 409 is the backend's "some rows
    # were refused" answer and is a PARTIAL SUCCESS: its updatedIds are real and
    # must not be re-attempted as failures. A success nests the report under
    # .body.data; the error handler spreads it across .body.
    #
    # Anything else — transport failure, another status, a dry-run intercept, or
    # a body with no usable updatedIds — refuses the WHOLE chunk. Success is
    # never inferred from a missing field.
    # Whether this response is one we should have been able to attribute row by
    # row. Computed ONCE: the parse gate below and the refusal reason after it
    # must never disagree about what "attributable" means.
    local attributable=false
    if [[ "$chunk_rc" -eq 0 && "$chunk_dry" != "true" ]] \
       && [[ "$chunk_http" == "200" || "$chunk_http" == "409" ]]; then
      attributable=true
    fi

    local chunk_report=""
    if [[ "$attributable" == "true" ]]; then
      chunk_report=$(echo "$chunk_resp" | jq -c '
        (if (.body | type) == "object"
           then (if (.body | has("data")) then .body.data else .body end)
           else null end)
        | select(type == "object" and has("updatedIds") and (.updatedIds | type) == "array")
      ' 2>/dev/null || true)
    fi

    if [[ -n "$chunk_report" ]]; then
      local chunk_landed chunk_refused
      # Intersection in $ids order; `-` is safe here because ids are unique.
      chunk_landed=$(jq -nc --argjson ids "$chunk_ids" --argjson r "$chunk_report" \
        '$ids - ($ids - $r.updatedIds)')
      # Everything targeted that did NOT move, each carrying the backend's own
      # reason (illegal_transition / lost_race / not_found / seed_refused) when
      # it named one.
      chunk_refused=$(jq -nc --argjson ids "$chunk_ids" --argjson r "$chunk_report" --arg http "$chunk_http" '
        (if ($r | has("skipped")) and ($r.skipped | type) == "array" then $r.skipped else [] end) as $sk
        | [ ($ids - $r.updatedIds)[]
            | . as $id
            | { cr_id: $id,
                reason: (($sk[] | select(.id == $id) | .reason) // ("http_" + $http)) } ]')
      landed_acc=$(printf '%s\n%s\n' "$landed_acc" "$chunk_landed" | jq -sc 'add')
      refused_acc=$(printf '%s\n%s\n' "$refused_acc" "$chunk_refused" | jq -sc 'add')
      log_event "${bucket}_chunk_attributed" "$(jq -nc --argjson i "$i" --arg http "$chunk_http" --argjson landed "$chunk_landed" --argjson refused "$chunk_refused" '{chunk_index:$i, http_status:$http, landed_count:($landed|length), landed_ids:$landed, refused:$refused}')"
    else
      local reason="http_$chunk_http"
      [[ "$chunk_dry" == "true" ]] && reason="dry_run_intercepted"
      # A response we SHOULD have been able to attribute but could not is the
      # dangerous case: the write may well have landed, but we cannot say for
      # WHICH rows. Name it distinctly so it is never mistaken for a clean
      # transport failure, and refuse the whole chunk rather than assume.
      if [[ "$attributable" == "true" ]]; then
        reason="unattributable_response_http_$chunk_http"
      fi
      local chunk_refused
      chunk_refused=$(echo "$chunk_ids" | jq -c --arg reason "$reason" '[.[] | {cr_id: ., reason: $reason}]')
      refused_acc=$(printf '%s\n%s\n' "$refused_acc" "$chunk_refused" | jq -sc 'add')
      log_event "${bucket}_chunk_refused" "$(jq -nc --argjson i "$i" --arg reason "$reason" --arg http "$chunk_http" --argjson ids "$chunk_ids" '{chunk_index:$i, reason:$reason, http_status:$http, refused_ids:$ids}')"
    fi
  done

  jq -nc \
    --argjson landed "$landed_acc" \
    --argjson refused "$refused_acc" \
    --arg http "$last_http" \
    '{landed_ids:$landed, refused_ids:$refused, last_http:$http}'
}

# Approve bucket
APPROVE_LANDED_IDS='[]'
APPROVE_REFUSED_IDS='[]'
APPROVE_LAST_HTTP=""
if (( N_APPROVE > 0 )); then
  RES=$(apply_chunked "$WOULD_APPROVE" "approved" "approve")
  APPROVE_LANDED_IDS=$(echo "$RES" | jq -c '.landed_ids')
  APPROVE_REFUSED_IDS=$(echo "$RES" | jq -c '.refused_ids')
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
    UVN_LAST_HTTP=$(echo "$RES" | jq -r '.last_http')
  fi
  if (( N_FRAUD_UVN > 0 )); then
    RES=$(apply_chunked "$FRAUD_UVN" "user_verification_needed" "uvn_fraud" "fraud_multifactor")
    UVN_LANDED_IDS=$(printf '%s\n%s\n' "$UVN_LANDED_IDS" "$(echo "$RES" | jq -c '.landed_ids')" | jq -sc 'add')
    UVN_REFUSED_IDS=$(printf '%s\n%s\n' "$UVN_REFUSED_IDS" "$(echo "$RES" | jq -c '.refused_ids')" | jq -sc 'add')
    [[ -z "$UVN_LAST_HTTP" ]] && UVN_LAST_HTTP=$(echo "$RES" | jq -r '.last_http')
  fi
fi

APPROVE_LANDED_N=$(echo "$APPROVE_LANDED_IDS" | jq 'length')
APPROVE_REFUSED_N=$(echo "$APPROVE_REFUSED_IDS" | jq 'length')
UVN_LANDED_N=$(echo "$UVN_LANDED_IDS" | jq 'length')
UVN_REFUSED_N=$(echo "$UVN_REFUSED_IDS" | jq 'length')

TOTAL_LANDED=$(( APPROVE_LANDED_N + UVN_LANDED_N ))
TOTAL_REFUSED=$(( APPROVE_REFUSED_N + UVN_REFUSED_N ))
TOTAL_ELIGIBLE=$(( N_APPROVE + N_UVN ))

# Pick the more informative HTTP status for the legacy top-level field
HTTP_STATUS="$APPROVE_LAST_HTTP"
[[ -z "$HTTP_STATUS" ]] && HTTP_STATUS="$UVN_LAST_HTTP"

# Combined landed_ids / refused_ids for backwards-compat with
# render-dry-run-summary.sh / consumers reading top-level fields.
COMBINED_LANDED_IDS=$(printf '%s\n%s\n' "$APPROVE_LANDED_IDS" "$UVN_LANDED_IDS" | jq -sc 'add')
COMBINED_REFUSED_IDS=$(printf '%s\n%s\n' "$APPROVE_REFUSED_IDS" "$UVN_REFUSED_IDS" | jq -sc 'add')

log_event "apply_finished" "$(jq -nc --argjson al "$APPROVE_LANDED_N" --argjson ar "$APPROVE_REFUSED_N" --argjson ul "$UVN_LANDED_N" --argjson ur "$UVN_REFUSED_N" '{approve_landed:$al, approve_refused:$ar, uvn_landed:$ul, uvn_refused:$ur}')"

APPLY_OBJ=$(jq -nc \
  --argjson attempted "$TOTAL_ELIGIBLE" \
  --argjson eligible "$TOTAL_ELIGIBLE" \
  --argjson landed "$TOTAL_LANDED" \
  --argjson refused "$TOTAL_REFUSED" \
  --argjson approve_eligible "$N_APPROVE" \
  --argjson approve_landed "$APPROVE_LANDED_N" \
  --argjson approve_refused "$APPROVE_REFUSED_N" \
  --argjson approve_landed_ids "$APPROVE_LANDED_IDS" \
  --argjson approve_refused_ids "$APPROVE_REFUSED_IDS" \
  --argjson uvn_eligible "$N_UVN" \
  --argjson uvn_landed "$UVN_LANDED_N" \
  --argjson uvn_refused "$UVN_REFUSED_N" \
  --argjson uvn_landed_ids "$UVN_LANDED_IDS" \
  --argjson uvn_refused_ids "$UVN_REFUSED_IDS" \
  --argjson landed_ids "$COMBINED_LANDED_IDS" \
  --argjson refused_ids "$COMBINED_REFUSED_IDS" \
  --arg http_status "$HTTP_STATUS" \
  '{dry_run:false, attempted:$attempted, eligible:$eligible, landed:$landed, refused:$refused, drifted:0, http_status:$http_status, landed_ids:$landed_ids, refused_ids:$refused_ids, drifted_ids:[],
    approve: {eligible:$approve_eligible, landed:$approve_landed, refused:$approve_refused, landed_ids:$approve_landed_ids, refused_ids:$approve_refused_ids},
    uvn:     {eligible:$uvn_eligible,     landed:$uvn_landed,     refused:$uvn_refused,     landed_ids:$uvn_landed_ids,     refused_ids:$uvn_refused_ids}}')

echo "$INPUT" | jq -c --argjson apply "$APPLY_OBJ" '. + {apply:$apply}'
