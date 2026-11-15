#!/usr/bin/env bash
# End-to-end demonstration of the merge gate's cancelled/superseded handling.
# Drives the real bin/fm-merge-gate-lib.sh through a fake `gh` that serves a
# realistic statusCheckRollup, so the gate's own jq program and decision logic
# run exactly as they do against GitHub.
set -u
REPO_DIR=${1:?repo dir}
GATE="$REPO_DIR/bin/fm-merge-gate-lib.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
HEAD=1111111111111111111111111111111111111111
REPO=Muso-AI/core-backend

mkdir -p "$WORK/fakebin" "$WORK/fixtures" "$WORK/config"
ln -sf "$(command -v jq)" "$WORK/fakebin/jq"
cat > "$WORK/fakebin/gh" <<'MOCK'
#!/usr/bin/env bash
jqprog= prev=
for a in "$@"; do
  [ "$prev" = --jq ] && jqprog=$a
  case "$a" in --jq=*) jqprog=${a#--jq=} ;; esac
  prev=$a
done
case "${1:-} ${2:-}" in
  "pr view") jq -r "$jqprog" "$FIX/pr-view.json" ;;
  "pr list") echo '[]' ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$WORK/fakebin/gh"

# run <label> <expected:pass|refuse> <rollup-json>
run() {
  local label=$1 expect=$2 rollup=$3 rc
  cat > "$WORK/fixtures/pr-view.json" <<JSON
{"headRefOid":"$HEAD","author":{"login":"someone"},"baseRefName":"develop",
 "headRefName":"feature/x","state":"OPEN","mergedAt":null,"body":"Closes #7.",
 "statusCheckRollup":$rollup}
JSON
  echo "=== $label ==="
  echo "rollup: $rollup"
  FIX="$WORK/fixtures" FM_CONFIG_OVERRIDE="$WORK/config" PATH="$WORK/fakebin:$PATH" \
    "$GATE" "$REPO" 9 "$HEAD" --check-only >"$WORK/out" 2>"$WORK/err"
  rc=$?
  cat "$WORK/out" "$WORK/err"
  if { [ "$expect" = pass ] && [ $rc -eq 0 ]; } || { [ "$expect" = refuse ] && [ $rc -eq 1 ]; }; then
    echo "RESULT: PASS (expected $expect, exit $rc)"
  else
    echo "RESULT: FAIL (expected $expect, exit $rc)"
  fi
  echo
}

QA='"name":"qa-review","conclusion":"SUCCESS","workflowName":"qa","startedAt":"2026-11-15T07:00:00Z"'
run "cancelled run beside a SUCCESS run of the same check" pass \
  "[{$QA},{\"name\":\"pr-title\",\"conclusion\":\"CANCELLED\",\"workflowName\":\"title\",\"startedAt\":\"2026-11-15T07:00:00Z\"},{\"name\":\"pr-title\",\"conclusion\":\"SUCCESS\",\"workflowName\":\"title\",\"startedAt\":\"2026-11-15T07:05:00Z\"},{\"name\":\"unit-tests\",\"conclusion\":\"SUCCESS\",\"workflowName\":\"tests\",\"startedAt\":\"2026-11-15T07:00:00Z\"}]"

run "only a CANCELLED run of a check" refuse \
  "[{$QA},{\"name\":\"pr-title\",\"conclusion\":\"CANCELLED\",\"workflowName\":\"title\",\"startedAt\":\"2026-11-15T07:00:00Z\"},{\"name\":\"unit-tests\",\"conclusion\":\"SUCCESS\",\"workflowName\":\"tests\",\"startedAt\":\"2026-11-15T07:00:00Z\"}]"

run "old FAILURE superseded by newer SUCCESS in the same workflow (label re-trigger)" pass \
  "[{$QA},{\"name\":\"verify\",\"conclusion\":\"FAILURE\",\"workflowName\":\"verify\",\"startedAt\":\"2026-11-15T07:43:00Z\"},{\"name\":\"verify\",\"conclusion\":\"SUCCESS\",\"workflowName\":\"verify\",\"startedAt\":\"2026-11-15T12:06:00Z\"},{\"name\":\"unit-tests\",\"conclusion\":\"SUCCESS\",\"workflowName\":\"tests\",\"startedAt\":\"2026-11-15T07:00:00Z\"}]"

run "FAILURE in a different workflow sharing the check name (worst-wins across workflows)" refuse \
  "[{$QA},{\"name\":\"verify\",\"conclusion\":\"FAILURE\",\"workflowName\":\"verify-a\",\"startedAt\":\"2026-11-15T07:43:00Z\"},{\"name\":\"verify\",\"conclusion\":\"SUCCESS\",\"workflowName\":\"verify-b\",\"startedAt\":\"2026-11-15T12:06:00Z\"},{\"name\":\"unit-tests\",\"conclusion\":\"SUCCESS\",\"workflowName\":\"tests\",\"startedAt\":\"2026-11-15T07:00:00Z\"}]"

run "pending qa-review still outranks a SUCCESS of the same check" refuse \
  "[{\"name\":\"qa-review\",\"conclusion\":\"SUCCESS\"},{\"name\":\"qa-review\",\"conclusion\":\"PENDING\"},{\"name\":\"unit-tests\",\"conclusion\":\"SUCCESS\",\"workflowName\":\"tests\",\"startedAt\":\"2026-11-15T07:00:00Z\"}]"

run "cancelled qa-review dropped beside a SUCCESS qa-review" pass \
  "[{\"name\":\"qa-review\",\"conclusion\":\"CANCELLED\",\"workflowName\":\"qa\",\"startedAt\":\"2026-11-15T07:00:00Z\"},{\"name\":\"qa-review\",\"conclusion\":\"SUCCESS\",\"workflowName\":\"qa\",\"startedAt\":\"2026-11-15T07:05:00Z\"},{\"name\":\"unit-tests\",\"conclusion\":\"SUCCESS\",\"workflowName\":\"tests\",\"startedAt\":\"2026-11-15T07:00:00Z\"}]"
