#!/usr/bin/env bats
# Tests for scripts/deploy.sh's decide_marker_takeover() — the automatic
# takeover of a leftover .deploy-mutating marker owned by a DEAD GitHub
# Actions run.
#
# Why: on 2026-09-21 a deploy (GHA run 35636138551, owner token
# gha-35636138551-1) failed after mutating node-8, and its rollback died
# before clearing .deploy-mutating. Every later deploy refused within 14s
# (`another deploy holds .deploy-mutating ...`), and nothing took over a
# DEAD GitHub Actions owner automatically — the fleet stayed stranded until
# a human logged into node-8 by hand. decide_marker_takeover is the
# belt-and-braces for a rollback that dies (SIGKILL, ssh drop) before
# clear_mutation_marker: it asks GitHub whether the owning run actually
# finished, and only then exports HYDRA_TAKEOVER_MUTATION_MARKER so the
# existing claim_mutation_marker() compare-and-swap (scripts/lib/deploy-
# mutation-marker.sh) takes the marker over.
#
# SCOPE — this does NOT source deploy.sh itself: deploy.sh runs its work at
# top level (git repo, ssh, node-8 all required), so exercising the real
# WARN block would need a live host (same limitation documented in
# deploy-muso-pin-ordering.bats). decide_marker_takeover is self-contained
# (only depends on `log`, `gh`, `timeout`, and $HYDRA_TAKEOVER_MUTATION_
# MARKER), so it is lifted verbatim out of deploy.sh with sed and exercised
# directly — the same technique support-changelog-sync.bats and
# install-aux-units-timer-guard.bats use for functions that live inline in
# a top-level script rather than an extracted lib.
#
# This intentionally does NOT extend deploy-mutation-marker.bats: that
# file's harness sources scripts/lib/deploy-mutation-marker.sh and exercises
# claim/clear/takeover on a real marker file; decide_marker_takeover lives in
# deploy.sh, has a completely different dependency set (gh, timeout, a repo
# slug, a `log` function), and produces no marker file of its own — bolting
# it onto that setup() would misrepresent what's actually under test.

setup() {
  DEPLOY="${BATS_TEST_DIRNAME}/../deploy.sh"
  FN="$BATS_TEST_TMPDIR/decide_marker_takeover.sh"
  sed -n '/^decide_marker_takeover() {/,/^}/p' "$DEPLOY" > "$FN"
  [ -s "$FN" ]

  STUB="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB"
  GH_CALLED_MARKER="$BATS_TEST_TMPDIR/gh-was-called"
  rm -f "$GH_CALLED_MARKER"
}

# gh_stub <status> — writes a `gh` stub on $STUB that answers
# `gh api repos/<repo>/actions/runs/<id> --jq .status` with <status>, records
# every invocation to $GH_CALLED_MARKER, and asserts the repo/run-id shape
# decide_marker_takeover is supposed to send.
gh_stub() {
  local status="$1"
  cat > "$STUB/gh" <<EOF
#!/bin/sh
echo "\$*" >> "$GH_CALLED_MARKER"
case "\$*" in
  "api repos/Muso-AI/hydra/actions/runs/123 --jq .status")
    echo "$status" ;;
  *)
    exit 1 ;;
esac
EOF
  chmod +x "$STUB/gh"
}

# run_decide <owner> [repo] [extra env...] — sources the extracted function
# with a stub `log` (so assertions can grep its output) and prints the
# post-call value of HYDRA_TAKEOVER_MUTATION_MARKER on its own trailing
# line, so tests can check both the log text and the export in one `run`.
run_decide() {
  local owner="$1" repo="${2:-Muso-AI/hydra}"
  run env PATH="$STUB:$PATH" "${@:3}" bash -c '
    log() { echo "$*"; }
    source "$1"
    decide_marker_takeover "$2" "$3"
    echo "RESULT_TOKEN=${HYDRA_TAKEOVER_MUTATION_MARKER:-<unset>}"
  ' _ "$FN" "$owner" "$repo"
}

@test "a gha owner whose run is completed is taken over (exports the CAS token)" {
  gh_stub "completed"
  run_decide "gha-123-1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"taking the marker over"* ]]
  [[ "$output" == *"RESULT_TOKEN=gha-123-1"* ]]
  [ -s "$GH_CALLED_MARKER" ]
}

@test "a gha owner whose run is still in_progress is NOT taken over" {
  gh_stub "in_progress"
  run_decide "gha-123-1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not completed"* ]]
  [[ "$output" == *"no automatic takeover"* ]]
  [[ "$output" == *"RESULT_TOKEN=<unset>"* ]]
  [ -s "$GH_CALLED_MARKER" ]
}

@test "a manual owner is NEVER taken over and gh is never even asked" {
  gh_stub "completed"
  run_decide "manual-laptop-4242"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a GitHub Actions run token"* ]]
  [[ "$output" == *"RESULT_TOKEN=<unset>"* ]]
  [ ! -e "$GH_CALLED_MARKER" ]
}

@test "a gha owner with no gh on PATH is NOT taken over" {
  # PATH is JUST the empty stub dir (no gh) — bash itself is invoked by its
  # absolute path (env's own PATH lookup for the command would otherwise
  # need bash's own directory on PATH too, which on this machine also
  # holds gh, defeating the point of the test).
  run env -i PATH="$STUB" "$(command -v bash)" -c '
    log() { echo "$*"; }
    source "$1"
    decide_marker_takeover "$2" "$3"
    echo "RESULT_TOKEN=${HYDRA_TAKEOVER_MUTATION_MARKER:-<unset>}"
  ' _ "$FN" "gha-123-1" "Muso-AI/hydra"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh is not on PATH"* ]]
  [[ "$output" == *"RESULT_TOKEN=<unset>"* ]]
  [ ! -e "$GH_CALLED_MARKER" ]
}

@test "an operator-set HYDRA_TAKEOVER_MUTATION_MARKER is left as is, gh is never asked" {
  gh_stub "completed"
  run env PATH="$STUB:$PATH" HYDRA_TAKEOVER_MUTATION_MARKER=xyz bash -c '
    log() { echo "$*"; }
    source "$1"
    decide_marker_takeover "$2" "$3"
    echo "RESULT_TOKEN=${HYDRA_TAKEOVER_MUTATION_MARKER:-<unset>}"
  ' _ "$FN" "gha-123-1" "Muso-AI/hydra"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already set by the operator"* ]]
  [[ "$output" == *"RESULT_TOKEN=xyz"* ]]
  [ ! -e "$GH_CALLED_MARKER" ]
}

@test "deploy.sh calls decide_marker_takeover from the leftover-marker WARN, before the claim" {
  warn_line=$(grep -n 'already exists (owner: \$marker_owner)' "$DEPLOY" | head -1 | cut -d: -f1)
  decide_call=$(grep -n 'decide_marker_takeover "\$marker_owner"' "$DEPLOY" | head -1 | cut -d: -f1)
  claim_line=$(grep -n 'Claiming the mutation marker' "$DEPLOY" | head -1 | cut -d: -f1)
  [ -n "$warn_line" ] && [ -n "$decide_call" ] && [ -n "$claim_line" ]
  [ "$warn_line" -lt "$decide_call" ]
  [ "$decide_call" -lt "$claim_line" ]
}

@test "Step 6b's cron-store-unreadable failure names the deadline, not a stale attempt count" {
  grep -q 'within \${CRON_STORE_READ_DEADLINE_SECS:-420}s (attempt timeout \${CRON_STORE_READ_ATTEMPT_TIMEOUT_SECS:-60}s)' "$DEPLOY"
  if grep -q 'attempt(s) — refusing to assume the cron store is correct' "$DEPLOY"; then false; fi
}
