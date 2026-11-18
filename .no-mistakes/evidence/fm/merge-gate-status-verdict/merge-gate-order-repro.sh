#!/usr/bin/env bash
# End-user reproduction of the merge gate's verdict on one head.
#
# Runs the real gate (bin/fm-merge-gate-lib.sh, the direct audit entry point) in
# check-only mode against a fake `gh` that serves a real-shaped
# `gh pr view --json statusCheckRollup` payload through the real jq. The four
# scenarios are exactly the acceptance criteria for
#   fm/merge-gate-status-verdict
# :
#   1. unit-tests FAILURE@15:56:34 then SUCCESS@15:56:36  -> must authorize
#   2. unit-tests SUCCESS@15:56:34 then FAILURE@15:56:36  -> must refuse
#   3. the same pair split across two workflowNames      -> follows the same order
#   4. a qa-review GO published only as a commit status  -> must authorize
#
# Usage: merge-gate-order-repro.sh <repo-root>
set -u

ROOT=${1:?usage: merge-gate-order-repro.sh <repo-root>}
GATE="$ROOT/bin/fm-merge-gate-lib.sh"
REPO=Muso-AI/core-backend
HEAD=aa99efc21111111111111111111111111111111111
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

JQ_BIN=$(command -v jq) || { echo "jq not found"; exit 2; }

mkdir -p "$WORK/fakebin" "$WORK/fixtures" "$WORK/config"
ln -sf "$JQ_BIN" "$WORK/fakebin/jq"
cat > "$WORK/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view")
    jqprog=
    prev=
    for a in "$@"; do
      if [ "$prev" = --jq ]; then jqprog=$a; fi
      case "$a" in --jq=*) jqprog=${a#--jq=} ;; esac
      prev=$a
    done
    if [ -n "$jqprog" ]; then jq -r "$jqprog" "$GH_FIXTURES/pr-view.json"
    else cat "$GH_FIXTURES/pr-view.json"; fi
    ;;
  "pr list") printf '[]\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$WORK/fakebin/gh"

# write_pr_view <rollup-json-array>
write_pr_view() {
  cat > "$WORK/fixtures/pr-view.json" <<JSON
{
  "headRefOid": "$HEAD",
  "author": {"login": "someone"},
  "baseRefName": "develop",
  "headRefName": "feature/x",
  "state": "OPEN",
  "mergedAt": null,
  "body": "Closes nothing.",
  "statusCheckRollup": $1
}
JSON
}

run_gate() {
  GH_FIXTURES="$WORK/fixtures" \
  FM_CONFIG_OVERRIDE="$WORK/config" \
  PATH="$WORK/fakebin:$PATH" \
    "$GATE" "$REPO" 9 "$HEAD" --check-only
}

scenario() {
  local label=$1 expect=$2 rollup=$3 rc verdict
  write_pr_view "$rollup"
  echo "=================================================================="
  echo "SCENARIO: $label"
  echo "  rollup: $(jq -c '[.statusCheckRollup[] | {kind: .__typename, name: (.name // .context), conclusion: (.conclusion // .state), startedAt, workflowName}]' "$WORK/fixtures/pr-view.json")"
  out=$(run_gate 2>&1); rc=$?
  echo "  gate exit: $rc (expected $expect)"
  printf '%s\n' "$out" | sed 's/^/  | /'
  if [ "$rc" = "$expect" ]; then verdict="MATCH"; else verdict="MISMATCH"; fi
  echo "  RESULT: $verdict"
}

job() { # job <name> <conclusion> <started> <wf>
  printf '{"__typename":"CheckRun","name":"%s","status":"COMPLETED","conclusion":"%s","startedAt":"%s","workflowName":"%s"}' "$1" "$2" "$3" "$4"
}
qa() { printf '{"__typename":"CheckRun","name":"qa-review","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-11-15T15:00:00Z","workflowName":"review"}'; }

scenario "failure then success 2s later, one workflow (adk47/firstmate#105 shape)" 0 \
  "[$(job unit-tests FAILURE 2026-11-15T15:56:34Z ci),$(job unit-tests SUCCESS 2026-11-15T15:56:36Z ci),$(qa)]"

scenario "success then failure 2s later, one workflow" 1 \
  "[$(job unit-tests SUCCESS 2026-11-15T15:56:34Z ci),$(job unit-tests FAILURE 2026-11-15T15:56:36Z ci),$(qa)]"

scenario "newer success from a DIFFERENT workflow supersedes an older failure" 0 \
  "[$(job verify FAILURE 2026-11-15T07:43:00Z wfA),$(job verify SUCCESS 2026-11-15T12:06:00Z wfB),$(qa)]"

scenario "newer failure from a DIFFERENT workflow stays red" 1 \
  "[$(job verify SUCCESS 2026-11-15T07:43:00Z wfA),$(job verify FAILURE 2026-11-15T12:06:00Z wfB),$(qa)]"

scenario "qa-review GO published as a commit status only (no qa-review check-run)" 0 \
  '[{"__typename":"StatusContext","context":"qa-review","state":"SUCCESS"},{"__typename":"StatusContext","context":"qa/verdict","state":"SUCCESS"},{"__typename":"CheckRun","name":"unit-tests","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-11-15T15:00:00Z","workflowName":"ci"}]'
