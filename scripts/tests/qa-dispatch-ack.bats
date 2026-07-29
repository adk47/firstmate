#!/usr/bin/env bats
# Behavioral tests for the "Ack on target PR" step in
# .github/workflows/external-pr-review.yml — the #214 delivery-visibility ack.
#
# These do NOT re-read the YAML for keywords; they EXTRACT the step's real
# `run:` body and EXECUTE it against a stubbed `gh`, so they observe what the
# step actually does to the GitHub API.
#
# Two contracts are load-bearing and both have already been broken once:
#   1. UPSERT, not append — the ack must refresh ONE marker comment. A missed
#      lookup silently degrades into a new comment per re-dispatch, which spams
#      exactly the busy PRs (core-backend, H-DevOps) this feature exists for.
#      The marker sits wherever it was first posted, so on a PR with >100
#      comments it is NOT on page 1: the lookup must paginate.
#   2. Never touch a repo outside the allowlist — the ack writes with the
#      runner's adk47 / QA_ACK_PAT credentials on an attacker-influenceable
#      payload, so a refused repo must produce ZERO API calls.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
WORKFLOW="$HYDRA_REPO/.github/workflows/external-pr-review.yml"

setup() {
  ACK_BODY="$BATS_TEST_TMPDIR/ack-body.sh"
  CALL_LOG="$BATS_TEST_TMPDIR/gh-calls.log"
  : > "$CALL_LOG"

  # Extract the ack step's run: block verbatim (awk only — no YAML lib, since
  # the bats CI job is not guaranteed to have PyYAML).
  awk '
    /^      - name: Ack on target PR/ { instep=1 }
    instep && /^        run: \|/      { inrun=1; next }
    inrun && /^      - name: /        { inrun=0; instep=0 }
    inrun                             { sub(/^          /, ""); print }
  ' "$WORKFLOW" > "$ACK_BODY"
  [ -s "$ACK_BODY" ] || { echo "could not extract the ack run: block"; return 1; }

  # Stub gh. Models the real pagination contract: WITHOUT --paginate you get
  # only the first page; WITH it you get every page.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'CALL: %s\n' "$*" | head -1 >> "$GH_CALL_LOG"
paginate=0; verb=GET
for a in "$@"; do
  [ "$a" = "--paginate" ] && paginate=1
  [ "$a" = "PATCH" ] && verb=PATCH
  [ "$a" = "POST" ] && verb=POST
done
case "$verb" in
  PATCH|POST) echo "$verb-OK" >> "$GH_CALL_LOG"; printf '%s' "$*" > "$GH_BODY_FILE"; echo '{}'; exit 0 ;;
esac
# List call. Page 1 = 100 unrelated comments; page 2 holds the marker (id 999).
jq -nc '[range(100) | {id: ., body: "unrelated chatter"}]'
if [ "$paginate" = "1" ] && [ "${STUB_MARKER_ON_PAGE2:-0}" = "1" ]; then
  jq -nc --arg m "$STUB_MARKER" '[{id: 999, body: ($m + "\nolder ack")}]'
elif [ "$paginate" = "0" ] && [ "${STUB_MARKER_ON_PAGE2:-0}" = "1" ]; then
  : # unpaginated caller never sees page 2 — this is the bug being guarded
fi
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

# Run the real ack body. $1=repo $2=pr ; env STUB_MARKER_ON_PAGE2 toggles fixture.
run_ack() {
  export GH_CALL_LOG="$CALL_LOG"
  export GH_BODY_FILE="$BATS_TEST_TMPDIR/posted-body.txt"
  export STUB_MARKER="<!-- hydra-qa-ack ${1}#${2} -->"
  cd "$HYDRA_REPO" || return 1
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
  REPO="$1" PR="$2" HEAD_SHA="deadbee" \
  RUN_URL="https://github.com/Muso-AI/hydra/actions/runs/1" QA_ACK_PAT="" \
    bash "$ACK_BODY"
}

@test "REGRESSION (#755): marker beyond the first 100 comments is still found -> PATCH, not a duplicate POST" {
  # The upsert guarantee on busy PRs. With an unpaginated lookup the marker on
  # page 2 is invisible, cid stays empty, and every re-dispatch POSTs another
  # ack — the exact spam this feature promises not to cause.
  STUB_MARKER_ON_PAGE2=1 run_ack Muso-AI/core-backend 9217
  grep -q '^PATCH-OK$' "$CALL_LOG" || { echo "expected a PATCH (refresh); log:"; cat "$CALL_LOG"; return 1; }
  ! grep -q '^POST-OK$' "$CALL_LOG" || { echo "posted a DUPLICATE ack instead of refreshing; log:"; cat "$CALL_LOG"; return 1; }
}

@test "the comment lookup paginates" {
  STUB_MARKER_ON_PAGE2=1 run_ack Muso-AI/core-backend 9217
  grep -q -- '--paginate' "$CALL_LOG" || { echo "lookup did not use --paginate; log:"; cat "$CALL_LOG"; return 1; }
}

@test "no existing marker -> POST a fresh ack" {
  STUB_MARKER_ON_PAGE2=0 run_ack Muso-AI/core-backend 9217
  grep -q '^POST-OK$' "$CALL_LOG"
  ! grep -q '^PATCH-OK$' "$CALL_LOG"
}

@test "non-allowlisted repo -> ZERO GitHub API calls (credentials never leave the allowlist)" {
  run_ack Muso-AI/hydra 1
  run grep -c '^CALL:' "$CALL_LOG"
  [ "$output" = "0" ]
}

@test "foreign owner -> ZERO GitHub API calls" {
  run_ack evil-org/core-backend 1
  run grep -c '^CALL:' "$CALL_LOG"
  [ "$output" = "0" ]
}

@test "malformed pr_number on an allowed repo -> ZERO GitHub API calls" {
  run_ack Muso-AI/core-backend '1;rm -rf /'
  run grep -c '^CALL:' "$CALL_LOG"
  [ "$output" = "0" ]
}

@test "the ack claims DELIVERY, not that a review started" {
  # The ack runs BEFORE the scope checks (draft / base branch / author
  # Slack-UID mapping), each of which ends the run with no review at all.
  # "QA review started" would therefore be false on exactly those PRs, and
  # this comment is what other teams read on their own PRs. Only claim what
  # is true at this point: the dispatch arrived and this run exists.
  STUB_MARKER_ON_PAGE2=0 run_ack Muso-AI/core-backend 9217
  body="$(cat "$BATS_TEST_TMPDIR/posted-body.txt")"
  [[ "$body" == *"Dispatch received by hydra"* ]] || { echo "no delivery wording; body: $body"; return 1; }
  [[ "$body" != *"review started"* ]] || { echo "claims a review started before the scope checks; body: $body"; return 1; }
  # Coordinates and the run link must survive the rewording — they are what
  # makes a missing/duplicate ack diagnosable.
  [[ "$body" == *"Muso-AI/core-backend#9217"* ]]
  [[ "$body" == *"actions/runs/1"* ]]
}

@test "the ack always exits 0 (never blocks the review)" {
  run env STUB_MARKER_ON_PAGE2=1 bash -c 'true'  # sanity: harness usable
  [ "$status" -eq 0 ]
  run_ack Muso-AI/core-backend 9217
  [ "$?" -eq 0 ]
}
