#!/usr/bin/env bash
# profile-audit.sh — Tier-0 per-profile 8-gate bulk-approve audit.
#
# Phase A of the credit-verification redesign (see
# /Users/nick/.claude/plans/ok-explain-to-me-modular-hamster.md §8).
#
# Decision contract:
#   * Every audited profile is scored against an 8-gate stack. All 8 must pass
#     for the profile's unverified batch to be eligible for bulk-approve.
#   * This script ONLY computes the audit + emits the receipt. It does NOT call
#     the admin API to approve. The dispatcher (separate task) consumes the
#     receipt as --evidence-excerpt and runs the actual approve.
#   * Any failure (any gate, low volume, no corpus) emits a structured runlog
#     event and exits 1 to signal "skip — try Tier 1/2/3 instead". Exit 1 is
#     NOT a script failure; it's a per-profile verdict of "Tier-0 not eligible".
#   * Exit 0 only when all 8 gates pass.
#   * Exit 2 when Tier-0 is disabled (OPS_TIER0_ENABLED unset or 0) — the
#     dispatcher can branch on that to know whether to retry without Tier-0.
#
# Usage:
#   profile-audit.sh <profile_id>              # audit one profile
#   profile-audit.sh --batch <queue_file>      # NOT YET IMPLEMENTED — single-
#                                              # profile mode is enough for
#                                              # the spec's Phase A; the
#                                              # dispatcher iterates.
#
# Env (required):
#   OPS_TIER0_ENABLED=1            fail-closed canary flag
#   OPS_RUNLOG_DIR                 runlog directory (consumed by runlog.sh)
#
# Env (optional):
#   OPS_DRY_RUN=0|1                forwarded to the dispatcher; this script
#                                  still runs the audit even in dry-run, the
#                                  intercept happens later when the dispatcher
#                                  tries to PUT.
#   OPS_RUN_ID                     if set, runlog events are stamped with it
#   ADMIN_API_SCRIPT               path to muso-admin-api.sh (defaults to the
#                                  installed location; override in tests)
#   RUNLOG_SH                      path to runlog.sh (override in tests)
#
#   CV_TIER0_MIN_BATCH=20          G0: min unverified count to trigger audit
#   CV_TIER0_MIN_CC=100            G1: profile.creditCount threshold
#   CV_TIER0_MIN_POP=50            G2: profile.popularity threshold
#   CV_TIER0_MIN_INDUSTRY=0.70     G3: fraction with metadata.source=="industry"
#   CV_TIER0_MIN_ONLY_VEL=0.70     G4: fraction with only-velocity flag
#   CV_TIER0_MIN_ARTIST_OVERLAP=0.40   G7
#   CV_TIER0_MIN_LABEL_OVERLAP=0.30    G8
#
# Output:
#   stdout (exit 0 only): a single line — the structured receipt
#     profile_audit:cc=694,pop=68,batch=50,industry=0.96,only_vel=1.00,br_max=1/1,roles_ok=1,art=0.56,lbl=0.46
#   stderr: human-readable trace
#   runlog: tier0_audit_passed | tier0_skipped_low_volume |
#           tier0_skipped_no_corpus | tier0_skipped_gate_fail

set -euo pipefail

SCRIPT_NAME="profile-audit.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Tier-0 enablement gate (fail-closed canary) ---------------------------
case "$(printf %s "${OPS_TIER0_ENABLED:-0}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) ;;
    *)
        echo "Tier-0 disabled (set OPS_TIER0_ENABLED=1 to enable)" >&2
        exit 2
        ;;
esac

# --- Defaults ---------------------------------------------------------------
ADMIN_API_SCRIPT="${ADMIN_API_SCRIPT:-/opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh}"
RUNLOG_SH="${RUNLOG_SH:-$SCRIPT_DIR/runlog.sh}"

CV_TIER0_MIN_BATCH="${CV_TIER0_MIN_BATCH:-20}"
CV_TIER0_MIN_CC="${CV_TIER0_MIN_CC:-100}"
CV_TIER0_MIN_POP="${CV_TIER0_MIN_POP:-50}"
CV_TIER0_MIN_INDUSTRY="${CV_TIER0_MIN_INDUSTRY:-0.70}"
CV_TIER0_MIN_ONLY_VEL="${CV_TIER0_MIN_ONLY_VEL:-0.70}"
CV_TIER0_MIN_ARTIST_OVERLAP="${CV_TIER0_MIN_ARTIST_OVERLAP:-0.40}"
CV_TIER0_MIN_LABEL_OVERLAP="${CV_TIER0_MIN_LABEL_OVERLAP:-0.30}"

# --- Argument parsing -------------------------------------------------------
if [[ $# -lt 1 ]]; then
    echo "ERROR: usage: $SCRIPT_NAME <profile_id>" >&2
    exit 2
fi

case "${1:-}" in
    --batch)
        # Spec mentions --batch as a future affordance. Phase A keeps this
        # script single-profile so the dispatcher controls iteration (and
        # parallelism caps; see feedback_credit_subagent_cap.md). Reject
        # explicitly so callers don't silently get the wrong behavior.
        echo "ERROR: --batch is not implemented in Phase A. Iterate per profile from the dispatcher." >&2
        exit 2
        ;;
    -h|--help)
        sed -n '2,/^set -/p' "$0" | sed 's/^# \{0,1\}//' >&2
        exit 0
        ;;
esac

PROFILE_ID="$1"
if [[ -z "$PROFILE_ID" ]]; then
    echo "ERROR: <profile_id> is required" >&2
    exit 2
fi

# --- Helpers ----------------------------------------------------------------

# Emit a runlog event if OPS_RUNLOG_DIR + OPS_RUN_ID are set. Best-effort —
# don't fail the audit just because logging fails (the audit verdict is the
# load-bearing thing here; the runlog event is observability).
emit_event() {
    local name="$1" payload="$2"
    if [[ -z "${OPS_RUNLOG_DIR:-}" || -z "${OPS_RUN_ID:-}" ]]; then
        return 0
    fi
    if [[ ! -x "$RUNLOG_SH" && ! -f "$RUNLOG_SH" ]]; then
        return 0
    fi
    # Run runlog.sh in a subshell with CV_DISABLE_VERDICT_GATE=1 so the
    # browser-evidence gate doesn't refuse our tier0_* events (those events
    # have nothing to do with browser quorum — Tier 0 is upstream of the
    # browser path entirely). Same for the cookie-cutter gate; tier0
    # receipts are intentionally similar across passes.
    CV_DISABLE_VERDICT_GATE=1 CV_DISABLE_COOKIE_CUTTER_GATE=1 \
        bash "$RUNLOG_SH" event "$OPS_RUN_ID" "$name" "$payload" \
        >/dev/null 2>&1 || true
}

api_get() {
    local path="$1"
    bash "$ADMIN_API_SCRIPT" call GET "$path"
}

# --- Step 1: fetch unverified queue for this profile ------------------------
echo "[$SCRIPT_NAME] auditing profile $PROFILE_ID" >&2

UNVERIFIED_RESP=$(api_get "/admin/credit-requests?profilesIds=$PROFILE_ID&status=unverified&limit=1000") || {
    echo "ERROR: admin API call (unverified) failed" >&2
    exit 1
}

UNVERIFIED_HTTP=$(printf '%s' "$UNVERIFIED_RESP" | jq -r '.http_status // "unknown"' 2>/dev/null || echo unknown)
if [[ "$UNVERIFIED_HTTP" != "200" ]]; then
    echo "ERROR: unverified fetch returned HTTP $UNVERIFIED_HTTP" >&2
    printf '%s\n' "$UNVERIFIED_RESP" >&2
    exit 1
fi

UNVERIFIED_ITEMS=$(printf '%s' "$UNVERIFIED_RESP" | jq -c '.body.data.items // []')
UNVERIFIED_COUNT=$(printf '%s' "$UNVERIFIED_ITEMS" | jq 'length')

# --- G0: minimum batch size ------------------------------------------------
if (( UNVERIFIED_COUNT < CV_TIER0_MIN_BATCH )); then
    echo "[$SCRIPT_NAME] skip: unverified=$UNVERIFIED_COUNT < min_batch=$CV_TIER0_MIN_BATCH" >&2
    emit_event tier0_skipped_low_volume \
        "$(jq -n -c --arg pid "$PROFILE_ID" --argjson n "$UNVERIFIED_COUNT" --argjson min "$CV_TIER0_MIN_BATCH" \
            '{profile_id:$pid, unverified_count:$n, min_batch:$min, reason:"low_volume"}')"
    exit 1
fi

# --- Pull profile.creditCount + popularity from the first credit -----------
# These fields are populated on every credit row (see SKILL.md:1180-1183 +
# verified live shape 2026-05-06). If both are null we treat as fail-closed.
PROFILE_CC=$(printf '%s' "$UNVERIFIED_ITEMS" | jq -r '.[0].profile.creditCount // 0')
PROFILE_POP=$(printf '%s' "$UNVERIFIED_ITEMS" | jq -r '.[0].profile.popularity // 0')
PROFILE_CC=${PROFILE_CC:-0}
PROFILE_POP=${PROFILE_POP:-0}

# Compose a structured "facts" object once for receipt + runlog payloads.
# We compute G3 / G4 / G5 / G6 / G7 / G8 inputs in one jq pass to avoid
# repeated parsing of the items array.
facts_unverified=$(printf '%s' "$UNVERIFIED_ITEMS" | jq -c '
    def only_velocity:
        # reject_high_velocity_profile > 0 AND no other reject_* signal > 0
        (.verificationData.rule_risk_percent // {}) as $r
        | (($r.reject_high_velocity_profile // 0) > 0)
          and
          ([
              $r | to_entries[]
              | select(.key | startswith("reject_"))
              | select(.key != "reject_high_velocity_profile")
              | select((.value // 0) > 0)
          ] | length == 0);

    def role_set: (.credits // []) | map(ascii_downcase | gsub("^\\s+|\\s+$"; ""));

    {
        count: length,
        industry_count: ([.[] | select((.metadata.source // "") == "industry")] | length),
        only_velocity_count: ([.[] | select(only_velocity)] | length),
        max_breadth: ([.[] | (.credits // []) | length] | max // 0),
        roles_set: ([.[] | role_set[]] | unique),
        labels: ([.[] | .metadata.label // empty] | map(ascii_downcase) | unique),
        labels_per_credit: [.[] | (.metadata.label // "" | ascii_downcase | gsub("^\\s+|\\s+$"; ""))],
        artists_per_credit: [.[] | (.spotifyTrackArtists // []) | map(.name // "" | ascii_downcase | gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))]
    }')

industry_frac=$(printf '%s' "$facts_unverified" | jq -r '
    if .count == 0 then 0 else (.industry_count / .count) end')
only_vel_frac=$(printf '%s' "$facts_unverified" | jq -r '
    if .count == 0 then 0 else (.only_velocity_count / .count) end')
unv_max_breadth=$(printf '%s' "$facts_unverified" | jq -r '.max_breadth')

# --- Helper to format a fraction to 2 decimals (printf is portable) -------
fmt2() { printf '%.2f' "$1"; }

# --- Helper to compare two floats with awk (bash arithmetic is integer-only)
#  args: lhs op rhs   ; op in <, <=, >=, >, ==
fcmp() {
    awk -v l="$1" -v r="$3" -v op="$2" 'BEGIN{
        if (op=="<")  exit (l <  r) ? 0 : 1;
        if (op=="<=") exit (l <= r) ? 0 : 1;
        if (op==">=") exit (l >= r) ? 0 : 1;
        if (op==">")  exit (l >  r) ? 0 : 1;
        if (op=="==") exit (l == r) ? 0 : 1;
        exit 2;
    }'
}

emit_gate_fail() {
    local gate="$1" actual="$2" threshold="$3"
    local extra_json="${4:-}"
    [[ -z "$extra_json" ]] && extra_json='{}'
    echo "[$SCRIPT_NAME] FAIL $gate: actual=$actual threshold=$threshold" >&2
    emit_event tier0_skipped_gate_fail \
        "$(jq -n -c \
            --arg pid "$PROFILE_ID" \
            --arg gate "$gate" \
            --arg actual "$actual" \
            --arg threshold "$threshold" \
            --argjson extra "$extra_json" \
            '{profile_id:$pid, failed_gate:$gate, actual_value:$actual, threshold:$threshold} + $extra')"
}

# --- G1: profile.creditCount >= CV_TIER0_MIN_CC ----------------------------
if (( PROFILE_CC < CV_TIER0_MIN_CC )); then
    emit_gate_fail "g1_creditCount" "$PROFILE_CC" "$CV_TIER0_MIN_CC"
    exit 1
fi

# --- G2: profile.popularity >= CV_TIER0_MIN_POP ----------------------------
if (( PROFILE_POP < CV_TIER0_MIN_POP )); then
    emit_gate_fail "g2_popularity" "$PROFILE_POP" "$CV_TIER0_MIN_POP"
    exit 1
fi

# --- G3: industry-source fraction ------------------------------------------
if ! fcmp "$industry_frac" ">=" "$CV_TIER0_MIN_INDUSTRY"; then
    emit_gate_fail "g3_industry_fraction" "$(fmt2 "$industry_frac")" "$CV_TIER0_MIN_INDUSTRY"
    exit 1
fi

# --- G4: only-velocity-flag fraction ---------------------------------------
if ! fcmp "$only_vel_frac" ">=" "$CV_TIER0_MIN_ONLY_VEL"; then
    emit_gate_fail "g4_only_velocity_fraction" "$(fmt2 "$only_vel_frac")" "$CV_TIER0_MIN_ONLY_VEL"
    exit 1
fi

# --- Fetch approved corpus for G5-G8 ---------------------------------------
APPROVED_RESP=$(api_get "/admin/credit-requests?profilesIds=$PROFILE_ID&status=approved&limit=1000") || {
    echo "ERROR: admin API call (approved corpus) failed" >&2
    exit 1
}
APPROVED_HTTP=$(printf '%s' "$APPROVED_RESP" | jq -r '.http_status // "unknown"' 2>/dev/null || echo unknown)
if [[ "$APPROVED_HTTP" != "200" ]]; then
    echo "ERROR: approved fetch returned HTTP $APPROVED_HTTP" >&2
    exit 1
fi

APPROVED_ITEMS=$(printf '%s' "$APPROVED_RESP" | jq -c '.body.data.items // []')
APPROVED_COUNT=$(printf '%s' "$APPROVED_ITEMS" | jq 'length')

if (( APPROVED_COUNT == 0 )); then
    echo "[$SCRIPT_NAME] skip: no approved corpus for profile $PROFILE_ID" >&2
    emit_event tier0_skipped_no_corpus \
        "$(jq -n -c --arg pid "$PROFILE_ID" --argjson n "$UNVERIFIED_COUNT" \
            '{profile_id:$pid, unverified_count:$n, reason:"no_corpus"}')"
    exit 1
fi

facts_approved=$(printf '%s' "$APPROVED_ITEMS" | jq -c '
    def role_set: (.credits // []) | map(ascii_downcase | gsub("^\\s+|\\s+$"; ""));
    {
        count: length,
        max_breadth: ([.[] | (.credits // []) | length] | max // 0),
        roles_set: ([.[] | role_set[]] | unique),
        labels: ([.[] | .metadata.label // empty] | map(ascii_downcase) | unique),
        artist_names: ([.[] | (.spotifyTrackArtists // [])[] | .name // "" | ascii_downcase | gsub("^\\s+|\\s+$"; "")] | map(select(. != "")) | unique)
    }')

ap_max_breadth=$(printf '%s' "$facts_approved" | jq -r '.max_breadth')

# --- G5: profile-relative breadth -----------------------------------------
# unv_max_breadth must be <= ap_max_breadth + 1.
allow_breadth=$(( ap_max_breadth + 1 ))
if (( unv_max_breadth > allow_breadth )); then
    emit_gate_fail "g5_breadth" \
        "${unv_max_breadth}/${ap_max_breadth}" \
        "${ap_max_breadth}+1=${allow_breadth}"
    exit 1
fi

# --- G6: roles ⊆ approved roles -------------------------------------------
roles_subset=$(jq -n -c \
    --argjson unv "$facts_unverified" \
    --argjson ap "$facts_approved" '
    ($unv.roles_set - $ap.roles_set) as $extra
    | {ok: ($extra | length == 0), extra: $extra}')
if [[ "$(printf '%s' "$roles_subset" | jq -r '.ok')" != "true" ]]; then
    extras=$(printf '%s' "$roles_subset" | jq -c '.extra')
    emit_gate_fail "g6_role_subset" "extra_roles=$extras" "must_be_subset" \
        "$(jq -n -c --argjson e "$extras" '{extra_roles:$e}')"
    exit 1
fi

# --- G7: artist overlap ---------------------------------------------------
# fraction of unverified credits where >=1 spotifyTrackArtists[].name appears
# in the approved-corpus artist set.
artist_overlap=$(jq -n -r \
    --argjson unv "$facts_unverified" \
    --argjson ap "$facts_approved" '
    ($ap.artist_names) as $set
    | ($unv.artists_per_credit) as $per
    | if ($per | length) == 0 then 0
      else
          ([$per[] | select(any(.[]; . as $n | $set | index($n) != null))] | length) / ($per | length)
      end')

if ! fcmp "$artist_overlap" ">=" "$CV_TIER0_MIN_ARTIST_OVERLAP"; then
    emit_gate_fail "g7_artist_overlap" "$(fmt2 "$artist_overlap")" "$CV_TIER0_MIN_ARTIST_OVERLAP"
    exit 1
fi

# --- G8: label overlap ----------------------------------------------------
# fraction of unverified credits whose metadata.label appears in the approved
# corpus label set.
label_overlap=$(jq -n -r \
    --argjson unv "$facts_unverified" \
    --argjson ap "$facts_approved" '
    ($ap.labels | map(select(. != null and . != ""))) as $labelset
    | ($unv.labels_per_credit) as $per
    | if ($per | length) == 0 then 0
      else
          ([$per[] | . as $cur | select($cur != "" and ($labelset | index($cur) != null))] | length) / ($per | length)
      end')

if ! fcmp "$label_overlap" ">=" "$CV_TIER0_MIN_LABEL_OVERLAP"; then
    emit_gate_fail "g8_label_overlap" "$(fmt2 "$label_overlap")" "$CV_TIER0_MIN_LABEL_OVERLAP"
    exit 1
fi

# --- All 8 gates passed: emit receipt + runlog event ----------------------
RECEIPT="profile_audit:cc=${PROFILE_CC},pop=${PROFILE_POP},batch=${UNVERIFIED_COUNT},industry=$(fmt2 "$industry_frac"),only_vel=$(fmt2 "$only_vel_frac"),br_max=${unv_max_breadth}/${ap_max_breadth},roles_ok=1,art=$(fmt2 "$artist_overlap"),lbl=$(fmt2 "$label_overlap")"

emit_event tier0_audit_passed \
    "$(jq -n -c \
        --arg pid "$PROFILE_ID" \
        --arg receipt "$RECEIPT" \
        --argjson cc "$PROFILE_CC" \
        --argjson pop "$PROFILE_POP" \
        --argjson batch "$UNVERIFIED_COUNT" \
        --arg industry "$(fmt2 "$industry_frac")" \
        --arg only_vel "$(fmt2 "$only_vel_frac")" \
        --argjson unv_breadth "$unv_max_breadth" \
        --argjson ap_breadth "$ap_max_breadth" \
        --arg art "$(fmt2 "$artist_overlap")" \
        --arg lbl "$(fmt2 "$label_overlap")" \
        '{profile_id:$pid, receipt:$receipt, creditCount:$cc, popularity:$pop, batch:$batch,
          industry:$industry, only_velocity:$only_vel,
          unverified_max_breadth:$unv_breadth, approved_max_breadth:$ap_breadth,
          artist_overlap:$art, label_overlap:$lbl}')"

echo "[$SCRIPT_NAME] PASS: $PROFILE_ID — $RECEIPT" >&2
printf '%s\n' "$RECEIPT"
exit 0
