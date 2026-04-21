#!/usr/bin/env bash
# runlog.sh — write JSONL batch run logs.
#
# Usage:
#   runlog.sh init                         # prints run_id, creates file + latest.txt
#   runlog.sh event <run_id> <name> <json> # appends one event line
#
# Env:
#   OPS_RUNLOG_DIR   required — base dir (e.g. api-logs/credit-batch-runs)

set -euo pipefail

require_env() {
  if [[ -z "${OPS_RUNLOG_DIR:-}" ]]; then
    echo "ERROR: OPS_RUNLOG_DIR is not set" >&2
    exit 2
  fi
}

gen_short_uuid() {
  # 6 hex chars — plenty of entropy for per-second disambiguation
  if command -v uuidgen >/dev/null; then
    uuidgen | tr -d '-' | cut -c1-6 | tr '[:upper:]' '[:lower:]'
  else
    head -c 3 /dev/urandom | xxd -p
  fi
}

log_path_for_run() {
  local run_id="$1"
  local day="${run_id:0:8}"   # YYYYMMDD from run_id prefix
  local dir="${OPS_RUNLOG_DIR}/${day:0:4}-${day:4:2}-${day:6:2}"
  mkdir -p "$dir"
  echo "${dir}/${run_id}.jsonl"
}

cmd_init() {
  require_env
  local day ts short run_id log
  day=$(date -u +%Y%m%d)
  ts=$(date -u +%H%M%S)
  short=$(gen_short_uuid)
  run_id="${day}-${ts}-${short}"
  log=$(log_path_for_run "$run_id")
  : > "$log"  # create/truncate
  echo "$log" > "${OPS_RUNLOG_DIR}/latest.txt"
  echo "$run_id"
}

cmd_event() {
  require_env
  local run_id="$1"
  local event_name="$2"
  local payload="$3"

  # Validate payload parses as JSON
  if ! echo "$payload" | jq empty 2>/dev/null; then
    echo "ERROR: payload is not valid JSON: $payload" >&2
    exit 3
  fi

  local log iso
  log=$(log_path_for_run "$run_id")
  iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Freeze-after-preflight-fail gate. SKILL.md B0d mandates that once the
  # browser pre-flight probe fails, the turn exits and no further events are
  # logged for this run. The 2026-04-20 13:19 UTC manual run (2bfea8)
  # bypassed this by writing run_started phase="manual" immediately after
  # preflight_browser_unavailable. Mechanically block any such continuation
  # — the first preflight_browser_unavailable freezes the run. The helper
  # that writes that failure (preflight-verify.sh) runs before the freeze
  # takes effect because the gate checks for EXISTING entries; the helper's
  # own write is the FIRST entry of that type.
  if [[ -f "$log" ]] && jq -e 'select(.event == "preflight_browser_unavailable")' "$log" >/dev/null 2>&1; then
    echo "ERROR: run $run_id is frozen — preflight_browser_unavailable was logged. No further events accepted. SKILL.md B0d requires the turn to exit on pre-flight failure." >&2
    exit 20
  fi

  # Merge the base envelope with the payload
  jq -c --arg ev "$event_name" --arg rid "$run_id" --arg ts "$iso" \
     '. + {event: $ev, run_id: $rid, ts: $ts}' <<< "$payload" >> "$log"
}

case "${1:-}" in
  init) cmd_init ;;
  event) shift; cmd_event "$@" ;;
  *) echo "usage: $0 {init|event <run_id> <name> <json>}" >&2; exit 64 ;;
esac
