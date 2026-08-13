#!/usr/bin/env bash
# render-slack-summary.sh — emit authoritative Slack summary text from the
# run's truth floor (.results.jsonl) and runlog (run_finished event).
#
# Why this exists: the 2026-04-23 09:02 UTC dry-run's Slack thread reply
# contained "174 APPROVE-ELIGIBLE credits were NOT processed", "43 profiles",
# "Tom Baker mastering engineer", etc. None of these numbers or names exist
# in the truth floor — the agent composed free-form prose beyond what
# compute-run-summary.sh provided. This script renders the summary from
# data only, so the agent can paste the output verbatim and has no need to
# invent counts or names.
#
# Usage:
#   render-slack-summary.sh <RUN_ID>
#
# Env:
#   OPS_RUNLOG_DIR        required — same as compute-run-summary.sh
#   CV_RESULTS_PATH       optional — override path to .results.jsonl;
#                         defaults to the canonical /var/log location per
#                         the same convention muso-admin-api.sh uses.
#
# Output shape:
#   <parent message text>
#   ===THREAD===
#   <thread reply text>
#
# The SENTINEL is literally "===THREAD===" on its own line. Callers split
# on that line and pass the two halves to message(action=send).

set -euo pipefail

RUN_ID="${1:?Usage: render-slack-summary.sh <RUN_ID>}"

if [[ -z "${OPS_RUNLOG_DIR:-}" ]]; then
    echo "ERROR: OPS_RUNLOG_DIR is not set" >&2
    exit 2
fi

day_short="${RUN_ID:0:8}"
day_iso="${day_short:0:4}-${day_short:4:2}-${day_short:6:2}"
runlog_path="${OPS_RUNLOG_DIR}/${day_iso}/${RUN_ID}.jsonl"
results_path="${CV_RESULTS_PATH:-/var/log/openclaw/credit-batch-runs/${day_iso}/${RUN_ID}.results.jsonl}"

if [[ ! -f "$runlog_path" ]]; then
    echo "ERROR: runlog not found: $runlog_path" >&2
    exit 5
fi

# Pull the canonical run_finished event. This is the authoritative summary
# (written by compute-run-summary.sh); we never compute our own numbers.
finished=$(jq -s -c 'first(.[] | select(.event == "run_finished"))' "$runlog_path" 2>/dev/null || echo "null")
if [[ -z "$finished" || "$finished" == "null" ]]; then
    echo "ERROR: no run_finished event in $runlog_path — run compute-run-summary.sh first" >&2
    exit 6
fi

# Fields we need from run_finished.
fetched=$(jq -r '.fetched // 0' <<<"$finished")
approved=$(jq -r '.approved // 0' <<<"$finished")
verification_needed=$(jq -r '.verification_needed // 0' <<<"$finished")
escalated=$(jq -r '.escalated // 0' <<<"$finished")
fraud_flagged=$(jq -r '.fraud_flagged // 0' <<<"$finished")
skipped_idempotent=$(jq -r '.skipped_idempotent // 0' <<<"$finished")
skipped_cap=$(jq -r '.skipped_cap // 0' <<<"$finished")
skipped=$((skipped_idempotent + skipped_cap))
silent_failure=$(jq -r '.silent_failure_detected // false' <<<"$finished")
hollow=$(jq -r '.hollow // false' <<<"$finished")
ungrounded=$(jq -r '.ungrounded // false' <<<"$finished")
dry_run=$(jq -r '.dryRun // false' <<<"$finished")
rejected_by_gate=$(jq -r '.reconciliation.approved_rejected_by_gate // 0' <<<"$finished")
rejected_pre_flight=$(jq -r '.reconciliation.approved_rejected_pre_flight // 0' <<<"$finished")
http_error_uvn=$(jq -r '.reconciliation.verification_needed_http_error // 0' <<<"$finished")
http_error_approved=$(jq -r '.reconciliation.approved_http_error // 0' <<<"$finished")
transport_error_uvn=$(jq -r '.reconciliation.verification_needed_transport_error // 0' <<<"$finished")
transport_error_approved=$(jq -r '.reconciliation.approved_transport_error // 0' <<<"$finished")

# Dry-run prefix and timestamp derivation.
dry_prefix=""
if [[ "$dry_run" == "true" ]]; then
    dry_prefix="[DRY RUN] "
fi
# UTC yyyy-mm-dd HH:MM from RUN_ID prefix.
ts_human="${day_iso} ${RUN_ID:9:2}:${RUN_ID:11:2} UTC"

# --- Parent message ---
# Lead with discrepancy banner when anything went wrong. The banner is the
# mechanical truth-floor signal; agent prose cannot override it.
banner=""
if [[ "$silent_failure" == "true" ]]; then
    banner=$'\n:warning: DISCREPANCY DETECTED — see reconciliation in runlog.'
    # Prefer the more specific message when we can attribute the cause.
    # Pre-flight refusals (R3) mean the agent never reached the gate — the
    # evidence-gathering step is the fix. Gate rejections (R1/R2) mean the
    # agent attempted but the gate caught insufficient evidence on read.
    if (( rejected_pre_flight > 0 && rejected_by_gate > 0 )); then
        banner=$'\n:warning: DISCREPANCY DETECTED — '"${rejected_pre_flight}"' pre-flight refused, '"${rejected_by_gate}"' rejected by gate. See reconciliation in runlog.'
    elif (( rejected_pre_flight > 0 )); then
        banner=$'\n:warning: DISCREPANCY DETECTED — '"${rejected_pre_flight}"' approve(s) refused at per-profile pre-flight (insufficient browser evidence per profile). See reconciliation in runlog.'
    elif (( rejected_by_gate > 0 )); then
        banner=$'\n:warning: DISCREPANCY DETECTED — '"${rejected_by_gate}"' approve(s) rejected by gate. See reconciliation in runlog.'
    fi
elif [[ "$hollow" == "true" ]]; then
    banner=$'\n:rotating_light: HOLLOW BATCH — preflight passed but no credits processed.'
elif [[ "$ungrounded" == "true" ]]; then
    banner=$'\n:rotating_light: UNGROUNDED BATCH — approves/flags without successful preflight.'
elif (( rejected_by_gate > 0 || rejected_pre_flight > 0 )); then
    # Partial-silent: some approves landed, some blocked. Not a DISCREPANCY
    # banner (that's reserved for 0 landed), but still worth surfacing.
    total_blocked=$((rejected_by_gate + rejected_pre_flight))
    banner=$'\n:warning: '"${total_blocked}"' approve(s) blocked (pre-flight + gate) — see runlog.'
fi

# Optional secondary warning if UVN or approve HTTP errors exist. Transport
# failures are counted separately below.
http_err_total=$((http_error_uvn + http_error_approved))
http_err_line=""
if (( http_err_total > 0 )); then
    http_err_line=$'\n:warning: '"${http_err_total}"' admin-API call(s) errored (see results.jsonl).'
fi

transport_err_total=$((transport_error_uvn + transport_error_approved))
transport_err_line=""
if (( transport_err_total > 0 )); then
    transport_err_line=$'\n:rotating_light: '"${transport_err_total}"' admin-API write(s): no backend refusal was observed; delivery remains unconfirmed after the safe retry policy. Reconcile current credit state before retrying.'
fi

# Fraud token on the one-line counter — only when the multi-factor detector
# actually flagged something (CV_FRAUD_MODE=enforce landed UVN downgrades).
# Omitted at 0 so off/shadow runs read identically to a no-fraud run.
fraud_token=""
if (( fraud_flagged > 0 )); then
    fraud_token=" | :rotating_light: Fraud: ${fraud_flagged}"
fi

parent="${dry_prefix}Credit batch complete — ${ts_human}${banner}${http_err_line}${transport_err_line}
Fetched: ${fetched} | Approved: ${approved} | → verification_needed: ${verification_needed} | Escalated: ${escalated} | Skipped: ${skipped}${fraud_token}
Run ID: ${RUN_ID}"

# --- Thread reply (bullets grouped by outcome, credit-ID based only) ---
#
# We list credit IDs by outcome category. Profile names are NOT rendered
# because .results.jsonl doesn't carry them — the agent's prose historically
# invented profile names here, which is the exact failure mode R2-5 closes.
# If profile grouping is needed later, enhance the wrappers to pass
# profile_id through to the truth floor as an additional field.

thread=""
if [[ -f "$results_path" ]]; then
    # Landed UVN
    uvn_landed=$(jq -s -r '
        [.[]
         | select(.intended_status == "user_verification_needed" and (.outcome == "ok" or .outcome == "dry_run_intercept"))
         | .request_ids[]?]
        | unique | .[]
    ' "$results_path" 2>/dev/null || true)
    uvn_landed_count=$(printf '%s' "$uvn_landed" | grep -c . 2>/dev/null || true)
    uvn_landed_count=${uvn_landed_count:-0}

    # Rejected-by-gate approves (never landed due to gate)
    approve_rejected=$(jq -s -r '
        [.[]
         | select(.intended_status == "approved" and .outcome == "rejected_by_gate")
         | .request_ids[]?]
        | unique | .[]
    ' "$results_path" 2>/dev/null || true)

    # Pre-flight refused approves (R3): batch-verify-profile.sh refused before
    # muso-admin-api.sh ever ran. Evidence-gathering step was insufficient.
    approve_preflight=$(jq -s -r '
        [.[]
         | select(.intended_status == "approved" and .outcome == "rejected_pre_flight")
         | .request_ids[]?]
        | unique | .[]
    ' "$results_path" 2>/dev/null || true)

    # HTTP-error UVN (intended UVN but didn't land — network/404 issues)
    uvn_errored=$(jq -s -r '
        [.[]
         | select(.intended_status == "user_verification_needed" and .outcome == "http_error")
         | .request_ids[]?]
        | unique | .[]
    ' "$results_path" 2>/dev/null || true)

    # Transport failures are distinct from HTTP errors: no backend response
    # was received. Include both approve and UVN intentions in one section.
    transport_errored=$(jq -s -r '
        [.[]
         | select(.outcome == "transport_error")
         | .request_ids[]?]
        | unique | .[]
    ' "$results_path" 2>/dev/null || true)

    # Config-mismatch (R2-1): writes refused for safety. Surface separately.
    config_mismatch=$(jq -s -r '
        [.[]
         | select(.outcome == "dry_run_config_mismatch")
         | .request_ids[]?]
        | unique | .[]
    ' "$results_path" 2>/dev/null || true)

    # Suspected-fraud UVN (multi-factor batch detector, fraud-detection-spec.md).
    # A landed UVN write carrying flag_reason="fraud_multifactor" is a credit the
    # backend would have approved but the fraud scorer downgraded to UVN
    # (CV_FRAUD_MODE=enforce). Emit `id\treason` TAB-separated per line so the
    # human factor string (`fraud:role_inflation+...=score`) rides along; the
    # truth floor carries it on the row's `reason` field. dedupe by id.
    fraud_uvn=$(jq -s -r '
        [.[]
         | select(.intended_status == "user_verification_needed"
                  and .flag_reason == "fraud_multifactor"
                  and (.outcome == "ok" or .outcome == "dry_run_intercept"))
         | (.reason // "") as $r
         | .request_ids[]? | {id: ., reason: $r}]
        | unique_by(.id)
        | .[] | [.id, .reason] | @tsv
    ' "$results_path" 2>/dev/null || true)
    fraud_uvn_count=$(printf '%s' "$fraud_uvn" | grep -c . 2>/dev/null || true)
    fraud_uvn_count=${fraud_uvn_count:-0}

    # --- SUSPECTED FRAUD section (most urgent — render first) ---------------
    # Distinct from the generic UVN list: these credits would have been
    # auto-approved by the backend but the multi-factor detector downgraded
    # them. We surface the triggering factors (parsed from the row `reason`)
    # so a reviewer sees WHY without opening the runlog. Note: these IDs are a
    # subset of the verification_needed-landed set above — they're broken out,
    # not double-counted, since the parent counter already includes them in
    # verification_needed. Same first-25-then-overflow pattern.
    if (( fraud_uvn_count > 0 )); then
        thread+=":rotating_light: *🚨 SUSPECTED FRAUD — ${fraud_uvn_count} credit(s) flagged, routed to user_verification_needed:*"$'\n'
        printed=0
        while IFS=$'\t' read -r id reason; do
            [[ -z "$id" ]] && continue
            if (( printed >= 25 )); then
                thread+="  … +$((fraud_uvn_count - 25)) more (see results.jsonl)"$'\n'
                break
            fi
            # `reason` is the human factor string "fraud:f1+f2+...=score". Strip
            # the "fraud:" prefix and trailing "=score" to show just the
            # triggering factors; fall back to the raw reason if it doesn't
            # match the expected shape.
            factors="$reason"
            if [[ "$reason" == fraud:* ]]; then
                factors="${reason#fraud:}"
                factors="${factors%=*}"
                factors="${factors//+/, }"
            fi
            if [[ -n "$factors" ]]; then
                thread+="  • \`${id}\` — ${factors}"$'\n'
            else
                thread+="  • \`${id}\`"$'\n'
            fi
            printed=$((printed + 1))
        done <<< "$fraud_uvn"
        thread+="  Detector: multi-factor batch fraud scorer (CV_FRAUD_MODE=enforce). See fraud-detection-spec.md + runlog for per-factor detail."$'\n'$'\n'
    fi

    if (( uvn_landed_count > 0 )); then
        thread+=":red_circle: *→ verification_needed (${uvn_landed_count} credits):*"$'\n'
        # Show up to 25 credit IDs inline; beyond that, summarize.
        printed=0
        while IFS= read -r id; do
            [[ -z "$id" ]] && continue
            if (( printed >= 25 )); then
                thread+="  … +$((uvn_landed_count - 25)) more (see results.jsonl)"$'\n'
                break
            fi
            thread+="  • \`${id}\`"$'\n'
            printed=$((printed + 1))
        done <<< "$uvn_landed"
        thread+=$'\n'
    fi

    if [[ -n "$approve_rejected" ]]; then
        count=$(printf '%s' "$approve_rejected" | grep -c .)
        thread+=":warning: *Rejected by gate — ${count} approve(s) blocked:*"$'\n'
        printed=0
        while IFS= read -r id; do
            [[ -z "$id" ]] && continue
            if (( printed >= 25 )); then
                thread+="  … +$((count - 25)) more (see results.jsonl)"$'\n'
                break
            fi
            thread+="  • \`${id}\`"$'\n'
            printed=$((printed + 1))
        done <<< "$approve_rejected"
        thread+="  Reason: insufficient grounded evidence or Tier-1 web_fetch in session. See runlog for detail."$'\n'$'\n'
    fi

    if [[ -n "$approve_preflight" ]]; then
        count=$(printf '%s' "$approve_preflight" | grep -c .)
        thread+=":warning: *Pre-flight refused — ${count} approve(s) blocked (per-profile evidence missing):*"$'\n'
        printed=0
        while IFS= read -r id; do
            [[ -z "$id" ]] && continue
            if (( printed >= 25 )); then
                thread+="  … +$((count - 25)) more (see results.jsonl)"$'\n'
                break
            fi
            thread+="  • \`${id}\`"$'\n'
            printed=$((printed + 1))
        done <<< "$approve_preflight"
        thread+="  Reason: batch-verify-profile.sh pre-flight refused — evidence for the profile wasn't loaded via browser before the attempt. Distinct from gate rejections: the admin API was never called."$'\n'$'\n'
    fi

    if [[ -n "$uvn_errored" ]]; then
        count=$(printf '%s' "$uvn_errored" | grep -c .)
        thread+=":x: *UVN flag HTTP errors — ${count} credit(s) did NOT land:*"$'\n'
        printed=0
        while IFS= read -r id; do
            [[ -z "$id" ]] && continue
            if (( printed >= 25 )); then
                thread+="  … +$((count - 25)) more (see results.jsonl)"$'\n'
                break
            fi
            thread+="  • \`${id}\`"$'\n'
            printed=$((printed + 1))
        done <<< "$uvn_errored"
        thread+=$'\n'
    fi

    if [[ -n "$transport_errored" ]]; then
        count=$(printf '%s' "$transport_errored" | grep -c .)
        thread+=":rotating_light: *Transport failures — delivery unconfirmed for ${count} credit(s):*"$'\n'
        printed=0
        while IFS= read -r id; do
            [[ -z "$id" ]] && continue
            if (( printed >= 25 )); then
                thread+="  … +$((count - 25)) more (see results.jsonl)"$'\n'
                break
            fi
            thread+="  • \`${id}\`"$'\n'
            printed=$((printed + 1))
        done <<< "$transport_errored"
        thread+="  Reason: no HTTP response after the safe retry policy. Reconcile current credit state before retrying; see transport_error in results.jsonl."$'\n'$'\n'
    fi

    if [[ -n "$config_mismatch" ]]; then
        count=$(printf '%s' "$config_mismatch" | grep -c .)
        thread+=":no_entry: *Config-mismatch refusals — ${count} write(s) blocked by R2-1 guard:*"$'\n'
        thread+="  OPS_DRY_RUN was unset in the exec shell during a dry-run run. See R2-1 guard in muso-admin-api.sh."$'\n'
        printed=0
        while IFS= read -r id; do
            [[ -z "$id" ]] && continue
            if (( printed >= 10 )); then
                thread+="  … +$((count - 10)) more (see results.jsonl)"$'\n'
                break
            fi
            thread+="  • \`${id}\`"$'\n'
            printed=$((printed + 1))
        done <<< "$config_mismatch"
        thread+=$'\n'
    fi

    # Trim trailing newlines.
    thread="${thread%$'\n'}"
else
    thread="_(No results.jsonl file — run had no tracked admin-API calls.)_"
fi

# Thread must never be empty; downstream posts `message(threadId=...)`
# expect a non-empty body. If nothing happened worth listing, give a plain
# placeholder.
if [[ -z "$thread" ]]; then
    thread="_No outcomes to list — fetched=0 or nothing attempted this run._"
fi

printf '%s\n===THREAD===\n%s\n' "$parent" "$thread"
