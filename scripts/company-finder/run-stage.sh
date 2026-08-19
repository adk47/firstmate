#!/usr/bin/env bash
# Host-side bridge for the company-finder gateway tools. GNU timeout owns the
# subprocess group so timeout/cancellation cannot leave ledger, curl, or Slack
# descendants running after the tool returns.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="${1:-}"
INPUT_FILE="${2:-}"
SOURCE="${3:-manual}"

if [[ ! -f "$INPUT_FILE" || ! -r "$INPUT_FILE" ]]; then
  echo "ERROR: readable input file required" >&2
  exit 1
fi

case "$STAGE" in
  prep)
    TARGET="${COMPANY_FINDER_PREP_SCRIPT:-$SCRIPT_DIR/prep-batch.sh}"
    # Forty candidates verify in five waves of eight. At the 62s worst-case
    # retry budget per wave plus a cold ~50s dedupe snapshot, 420s leaves a
    # safe margin while staying inside the cron's 900s turn budget.
    DURATION="${COMPANY_FINDER_PREP_TIMEOUT:-420s}"
    ;;
  finalize)
    TARGET="${COMPANY_FINDER_FINALIZE_SCRIPT:-$SCRIPT_DIR/finalize-batch.sh}"
    DURATION="${COMPANY_FINDER_FINALIZE_TIMEOUT:-300s}"
    case "$SOURCE" in
      manual|cron:company-finder-daily) export BATCH_SOURCE="$SOURCE" ;;
      *) echo "ERROR: invalid batch source" >&2; exit 1 ;;
    esac
    ;;
  *)
    echo "ERROR: stage must be prep or finalize" >&2
    exit 1
    ;;
esac

if [[ "$STAGE" == "finalize" ]]; then
  if ! jq -L "$SCRIPT_DIR/lib" -e '
    include "normalize";
    (.batch | map(.domain | norm_domain)) as $batch
    | ((.rejects // []) | map(.domain | norm_domain)) as $rejects
    | ($batch | all(length > 0))
      and ($rejects | all(length > 0))
      and (($batch | length) == ($batch | unique | length))
      and (($rejects | length) == ($rejects | unique | length))
      and (([$batch[] as $domain | select($rejects | index($domain))] | length) == 0)
  ' "$INPUT_FILE" >/dev/null 2>&1; then
    printf '%s\n' '{"error":"INVALID_FINAL_INPUT","exit":1,"detail":"batch/reject domains must be valid, unique, and disjoint"}'
    exit 1
  fi
fi

exec timeout --signal=TERM --kill-after=10s "$DURATION" bash "$TARGET" < "$INPUT_FILE"
