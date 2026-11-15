#!/usr/bin/env bash
# Manual end-to-end verification of the merge gate's refusal/authorization rules.
# Drives the real direct entry point bin/fm-merge-gate-lib.sh with a fake forge.
set -u

ROOT=/home/aaron/.no-mistakes/worktrees/72295860b10d/01M7F6WHRF50T5Y646SH4WC1E2
GATE=$ROOT/bin/fm-merge-gate-lib.sh
TMP=$(mktemp -d /tmp/fm-gate-evidence.XXXXXX)
HEAD=1111111111111111111111111111111111111111
OLD=2222222222222222222222222222222222222222
rc=0

setup() {
  CASE=$TMP/$1
  mkdir -p "$CASE/fakebin" "$CASE/fixtures" "$CASE/config"
  cat > "$CASE/fakebin/gh" <<'SH'
#!/usr/bin/env bash
jqprog=
prev=
for a in "$@"; do
  [ "$prev" = --jq ] && jqprog=$a
  case "$a" in --jq=*) jqprog=${a#--jq=} ;; esac
  prev=$a
done
serve() {
  [ -r "$1" ] || { echo "error: Not Found" >&2; exit 1; }
  if [ -n "$jqprog" ]; then jq -r "$jqprog" "$1"; else cat "$1"; fi
}
case "${1:-}" in
  pr) case "${2:-}" in
        view) serve "$CASE_DIR/fixtures/pr-view.json" ;;
        list) serve "$CASE_DIR/fixtures/pr-list.json" ;;
        *) exit 1 ;;
      esac ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$CASE/fakebin/gh"
}

pr_view() {
  local head=$1 base=$2 checks=$3 body=${4:-Closes nothing.}
  local rollup='' pair name conclusion
  local IFS=,
  for pair in $checks; do
    [ -n "$pair" ] || continue
    name=${pair%%:*}
    conclusion=${pair#*:}
    [ -n "$rollup" ] && rollup="$rollup,"
    rollup="$rollup{\"name\":\"$name\",\"status\":\"COMPLETED\",\"conclusion\":\"$conclusion\"}"
  done
  unset IFS
  cat > "$CASE/fixtures/pr-view.json" <<JSON
{"headRefOid":"$head","author":{"login":"someone"},"baseRefName":"$base","headRefName":"feature/x","state":"OPEN","mergedAt":null,"body":"$body","statusCheckRollup":[$rollup]}
JSON
}

run_gate() {
  echo "--- $CASE_LABEL"
  echo "\$ bin/fm-merge-gate-lib.sh $*"
  CASE_DIR=$CASE FM_CONFIG_OVERRIDE="$CASE/config" PATH="$CASE/fakebin:$PATH" \
    "$GATE" "$@" 2>&1
  local status=$?
  echo "exit=$status"
  echo
  [ "$status" -eq 0 ] || rc=0   # refusals are expected; keep the transcript going
}

# 1. QA-covered GitHub pull request with a NO-GO verdict on the current head.
setup qa-no-go
CASE_LABEL="GitHub Muso-AI/core-backend, qa-review=FAILURE on current head"
pr_view "$HEAD" develop 'qa-review:FAILURE,unit-tests:SUCCESS'
run_gate Muso-AI/core-backend 9 "$HEAD" --check-only

# 2. QA-covered GitHub pull request with no verdict at all.
setup qa-absent
CASE_LABEL="GitHub Muso-AI/core-backend, no qa-review check on current head"
pr_view "$HEAD" develop 'unit-tests:SUCCESS'
run_gate Muso-AI/core-backend 9 "$HEAD" --check-only

# 3. QA-covered GitHub pull request with a GO on an older head.
setup qa-stale
CASE_LABEL="GitHub Muso-AI/core-backend, GO recorded on an older head"
pr_view "$HEAD" develop 'qa-review:SUCCESS,unit-tests:SUCCESS'
run_gate Muso-AI/core-backend 9 "$HEAD" --recorded-head "$OLD" --check-only

# 4. Undeclared repository: silence must not mean allow.
setup coverage-unknown
CASE_LABEL="GitHub Acme/undeclared, repository on neither coverage list"
pr_view "$HEAD" develop 'unit-tests:SUCCESS'
run_gate Acme/undeclared 9 "$HEAD" --check-only

# 5. QA-covered repository on GitLab: no verdict source, so refuse.
setup gitlab-qa
CASE_LABEL="GitLab Muso-AI/core-backend, no verdict source on forge"
pr_view "$HEAD" main 'unit-tests:SUCCESS'
run_gate Muso-AI/core-backend 7 "$HEAD" --forge gitlab --check-only

# 6. Declared no-QA repository on GitLab, attestation green, main target: pass
#    with the GitHub-only twin rule noted as skipped.
setup gitlab-noqa
CASE_LABEL="GitLab declared no-QA repo, green attestation, main target"
printf '%s\n' Acme/widgets > "$CASE/config/merge-gate-no-qa-repos"
cat > "$CASE/fakebin/glab" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"/merge_requests/7") cat "$CASE_DIR/fixtures/mr.json" ;;
  *"/statuses"*) cat "$CASE_DIR/fixtures/statuses.json" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$CASE/fakebin/glab"
cat > "$CASE/fixtures/mr.json" <<JSON
{"sha":"$HEAD","author":{"username":"someone"},"target_branch":"main","source_branch":"feature/x","state":"opened","merged_at":null,"description":"Closes nothing."}
JSON
cat > "$CASE/fixtures/statuses.json" <<JSON
[{"name":"PR must be raised via no-mistakes","status":"success"},{"name":"unit-tests","status":"success"}]
JSON
run_gate Acme/widgets 7 "$HEAD" --forge gitlab --check-only

# 7. Declared GitHub twin repo, main target, unmerged develop counterpart.
setup github-twin
CASE_LABEL="GitHub Muso-AI/core-backend, main twin whose develop PR is unmerged"
pr_view "$HEAD" main 'qa-review:SUCCESS,unit-tests:SUCCESS'
cat > "$CASE/fixtures/pr-list.json" <<JSON
[{"number":12,"baseRefName":"develop","state":"OPEN","mergedAt":null}]
JSON
run_gate Muso-AI/core-backend 9 "$HEAD" --check-only

# 8. Green QA-covered GitHub pull request: authorized and reports what it read.
setup green
CASE_LABEL="GitHub Muso-AI/core-backend, qa-review=SUCCESS on current head"
pr_view "$HEAD" develop 'qa-review:SUCCESS,unit-tests:SUCCESS'
run_gate Muso-AI/core-backend 9 "$HEAD" --recorded-head "$HEAD" --check-only

rm -rf "$TMP"
exit "$rc"
