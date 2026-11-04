#!/usr/bin/env bats
# Tests for scripts/qa-handoff-publish.sh — the PRODUCER half of the off-disk
# QA hand-off (T10).
#
# What is actually at stake. Guards 8/9 in qa-pr-approve.sh fail CLOSED when
# they cannot find this head's reports. On node-8 they can still fall back to
# /var/lib/hydra-qa; on a QA gateway pod they cannot, so a silently broken
# publisher does not degrade QA — it stops every approval. That makes the
# publisher's contract (marker, author, payload shape, upsert-by-head, and the
# refusal to publish a report that describes a different head) load-bearing, and
# it is what these tests pin.
#
# Every test PATH-shadows `gh` with a stub: the suite never touches GitHub.

bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/qa-handoff-publish.sh"
LIB="$HYDRA_REPO/scripts/lib/qa-handoff.sh"

HEAD_OID="0123456789abcdef0123456789abcdef01234567"
PRIOR_OID="fedcba9876543210fedcba9876543210fedcba98"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  export STATE="$TEST_TMPDIR/state"
  mkdir -p "$STATE/rebase-integrity" "$STATE/blast-radius"
  export STUB_CALLS="$TEST_TMPDIR/calls"
  export STUB_POSTED="$TEST_TMPDIR/posted-body"
  export STUB_PATCHED="$TEST_TMPDIR/patched-body"
  export STUB_DELETED="$TEST_TMPDIR/deleted"
  : > "$STUB_DELETED"
  : > "$STUB_CALLS"

  STUBBIN="$TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  cat > "$STUBBIN/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "${STUB_CALLS:-/dev/null}"
inp=""; prev=""
for a in "$@"; do [ "$prev" = "--input" ] && inp="$a"; prev="$a"; done
# MODEL REAL gh, INCLUDING WHAT IT REJECTS. `gh api` has no --repo flag
# ("unknown flag: --repo"), and a stub that quietly accepts one let a publisher
# that 100% failed in CI pass this whole suite. Never drop this guard.
if [ "${1:-}" = "--repo" ] && [ "${3:-}" = "api" ]; then
  echo "unknown flag: --repo" >&2; exit 1
fi
[ "${1:-}" = "--repo" ] && shift 2
case "${1:-}" in
  api)
    shift
    case "$*" in
      *"/comments?per_page=100"*)
        [ "${STUB_GET_RC:-0}" = "0" ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
        if [ -n "${STUB_COMMENTS:-}" ]; then
          printf '%s' "$STUB_COMMENTS"
        elif [ -s "${STUB_POSTED:-}" ]; then
          # A POST already landed in this run, so the comment IS on the PR: serve
          # it back. That is exactly what the publisher's post-failure re-read
          # sees when the create response was unreadable (hydra#1681).
          jq -nc --rawfile b "$STUB_POSTED" '
            [{id: 5001, created_at: "2026-11-04T00:00:00Z",
              user: {login: "github-actions[bot]"}, body: ($b | rtrimstr("\n"))}]'
        else
          printf '[]'
        fi ;;
      *"--method POST"*)
        if [ "${STUB_POST_UNREADABLE:-0}" = "1" ]; then
          # The comment IS created — the write landed — but gh cannot read the
          # response, so it exits non-zero. This is hydra#1681 run 41737642763:
          # comment 6617916594 existed with the matching head_sha while the step
          # died claiming the head had no hand-off. Never merge this into
          # STUB_POST_RC: one models "the create failed", the other "the create
          # succeeded and we could not tell".
          jq -r '.body' "$inp" > "$STUB_POSTED"
          echo 'garbage instead of a comment object' >&2; exit 1
        fi
        [ "${STUB_POST_RC:-0}" = "0" ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
        jq -r '.body' "$inp" > "$STUB_POSTED"; echo '{"id": 5001}' ;;
      *"--method PATCH"*) jq -r '.body' "$inp" > "$STUB_PATCHED"; echo '{"id": 5002}' ;;
      *"--method DELETE"*)
        [ "${STUB_DELETE_RC:-0}" = "0" ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
        printf '%s\n' "deleted" >> "$STUB_DELETED" ;;
      *) echo "unexpected api call: $*" >&2; exit 9 ;;
    esac ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$STUBBIN/gh"
  export GH="$STUBBIN/gh"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

ri_report() {  # <status> [head] [repo] [pr] — write the analyzer's on-disk report
  local head="${2:-$HEAD_OID}" repo="${3:-Muso-AI/hydra}" pr="${4:-77}"
  jq -nc --arg repo "$repo" --argjson pr "$pr" --arg head "$head" --arg s "$1" \
    --arg d "$(printf 'd%.0s' {1..64})" \
    '{version: 1, repo: $repo, pr: $pr, head_sha: $head, status: $s,
      warn_digest: $d, signals: [{id: "erased-recent-base-work", severity: "warn",
      summary: "s", evidence: ["scripts/foo.sh"]}], skipped: []}' \
    >"$STATE/rebase-integrity/${repo//\//__}-pr-${pr}-${head}.json"
}

br_report() {  # <tier> [head]
  local head="${2:-$HEAD_OID}"
  jq -nc --arg head "$head" \
    '{version: 1, repo: "Muso-AI/hydra", pr: 77, head_sha: $head, status: "OK",
      tier: "'"$1"'", signals: [], skipped: [], limitations: []}' \
    >"$STATE/blast-radius/Muso-AI__hydra-pr-77-${head}.json"
}


# ── negative assertions have to be REAL ─────────────────────────────────────
# Bats runs a test body under `set -e`, and bash EXEMPTS a command whose status is
# inverted with `!` from `set -e` (bash(1), -e: "...or if the command's return
# value is being inverted with !"). So a mid-test `! grep -q …` CANNOT fail the
# test — it is decoration, and only a test's LAST command is checked. Measured on
# bats 1.14.0: `! echo hi | grep -q hi` followed by any succeeding command
# reports `ok`, while a bare `[ 1 -eq 2 ]` in the same position reports `not ok`.
# A case whose whole point is "we never POSTed" therefore used to pass whether or
# not it POSTed (QA finding, 2026-11-04). These two helpers are ordinary
# commands, so `set -e` applies and a regression turns the case red.
refute_output() {  # <text> — fail unless <text> is ABSENT from the run's output
  if printf '%s\n' "$output" | grep -qF -- "$1"; then
    printf 'refuted text WAS in the output: %s\n' "$1" >&2
    return 1
  fi
}

refute_calls() {  # <text> — fail if the gh stub recorded a call containing <text>
  if grep -qF -- "$1" "$STUB_CALLS"; then
    printf 'unexpected gh call WAS recorded: %s\n' "$1" >&2
    return 1
  fi
}

# ── the payload round-trips through the reader ─────────────────────────────

@test "publishes BOTH reports in one hidden comment that the reader decodes" {
  ri_report WARN
  br_report HIGH
  run "$SCRIPT" Muso-AI/hydra 77 "$HEAD_OID" --state-dir "$STATE"
  [ "$status" -eq 0 ]
  grep -q -- '--method POST' "$STUB_CALLS"

  body="$(cat "$STUB_POSTED")"
  [[ "$body" == '<!-- muso-qa-handoff v1 payload='*' -->' ]]
  # The body renders as NOTHING on the PR: the whole payload is inside an HTML
  # comment. A visible marker would put a wall of base64 in the timeline.
  [[ "$body" != *$'\n'* ]]

  b64="${body#<!-- muso-qa-handoff v1 payload=}"
  b64="${b64% -->}"
  decoded="$(printf '%s' "$b64" | base64 -d | gzip -dc)"
  [ "$(printf '%s' "$decoded" | jq -r .version)" = "1" ]
  [ "$(printf '%s' "$decoded" | jq -r .head_sha)" = "$HEAD_OID" ]
  [ "$(printf '%s' "$decoded" | jq -r '.reports["rebase-integrity"].status')" = "WARN" ]
  [ "$(printf '%s' "$decoded" | jq -r '.reports["blast-radius"].tier')" = "HIGH" ]
  [ "$(printf '%s' "$decoded" | jq -r '.missing | length')" = "0" ]
}

@test "posts a NEW comment when the PR carries no hand-off for this head" {
  ri_report CLEAN
  STUB_COMMENTS='[]' run "$SCRIPT" Muso-AI/hydra 77 "$HEAD_OID" --state-dir "$STATE"
  [ "$status" -eq 0 ]
  grep -q -- '--method POST' "$STUB_CALLS"
  refute_calls '--method DELETE'
}

# A hand-off must never outlive the run that produced it (QA finding on the first
# review of this PR): a same-head re-run whose PATCH failed used to leave the
# previous run's trusted CLEAN comment standing, and Guards 8/9 would approve on
# it. The publisher now deletes every earlier same-head hand-off BEFORE posting.
@test "same-head re-run INVALIDATES the previous hand-off, then posts a fresh one" {
  ri_report CLEAN
  payload="$(jq -nc --arg head "$HEAD_OID" '
    {version: 1, repo: "Muso-AI/hydra", pr: 77, head_sha: $head,
     generated_at: "2026-10-27T00:00:00Z", reports: {}, missing: []}')"
  b64="$(printf '%s' "$payload" | gzip -9 -n | base64 | tr -d '\n')"
  comments="$(jq -nc --arg b "<!-- muso-qa-handoff v1 payload=$b64 -->" '
    [{id: 4242, created_at: "2026-10-27T00:00:00Z",
      user: {login: "github-actions[bot]"}, body: $b}]')"
  STUB_COMMENTS="$comments" run "$SCRIPT" Muso-AI/hydra 77 "$HEAD_OID" --state-dir "$STATE"
  [ "$status" -eq 0 ]
  # DELETE came before POST, and the old id is gone rather than PATCHed.
  [ "$(grep -n -- '--method DELETE repos/Muso-AI/hydra/issues/comments/4242' "$STUB_CALLS" | cut -d: -f1)" \
    -lt "$(grep -n -- '--method POST' "$STUB_CALLS" | cut -d: -f1)" ]
  refute_calls '--method PATCH'
  echo "$output" | grep -q 'replaced 1 previous'
}

@test "re-run whose POST fails leaves NO hand-off for the head (fail closed, red CI)" {
  ri_report ERROR   # the analyzer's fresh verdict is now ERROR
  payload="$(jq -nc --arg head "$HEAD_OID" '
    {version: 1, repo: "Muso-AI/hydra", pr: 77, head_sha: $head,
     generated_at: "2026-10-27T00:00:00Z", reports: {}, missing: []}')"
  b64="$(printf '%s' "$payload" | gzip -9 -n | base64 | tr -d '\n')"
  comments="$(jq -nc --arg b "<!-- muso-qa-handoff v1 payload=$b64 -->" '
    [{id: 4242, created_at: "2026-10-27T00:00:00Z",
      user: {login: "github-actions[bot]"}, body: $b}]')"
  # The stale comment was CLEAN; the run must not be able to leave it usable.
  STUB_COMMENTS="$comments" STUB_POST_RC=1 \
    run "$SCRIPT" Muso-AI/hydra 77 "$HEAD_OID" --state-dir "$STATE"
  [ "$status" -eq 5 ]
  # The re-read finds only the STALE comment (generated_at 2026-10-27, older than
  # this run's payload), so it is not proof of a publish — and the message says
  # what was actually observed, never "NO hand-off".
  echo "$output" | grep -q 'the create call failed and its response could not be read'
  refute_output 'NO hand-off'
  grep -q -- '--method DELETE repos/Muso-AI/hydra/issues/comments/4242' "$STUB_CALLS"
  [ ! -s "$STUB_POSTED" ] || [ -z "$(cat "$STUB_POSTED")" ]
}

# hydra#1681 run 41737642763: the create SUCCEEDED (comment 6617916594 was on the
# PR with the matching head_sha) and the step still died "this head now has NO
# hand-off", because `--jq '.id'` makes the exit status depend on READING the
# response. A false negative there is not cosmetic: it reddens the job AND tells
# the next reader the PR holds nothing for this head.
@test "a POST whose RESPONSE is unreadable is NOT a failure when the comment landed" {
  ri_report CLEAN
  # No STUB_COMMENTS: the stub serves the posted body back on the re-read, i.e.
  # the comment really is on the PR.
  STUB_POST_UNREADABLE=1 \
    run "$SCRIPT" Muso-AI/hydra 77 "$HEAD_OID" --state-dir "$STATE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '::warning::'
  echo "$output" | grep -q 'the hand-off WAS posted'
  echo "$output" | grep -q 'hand-off comment 5001'
  refute_output 'NO hand-off'
  # The write landed, and the READ-BACK is what proved it: the PR was read twice
  # (once to withdraw this head's earlier hand-off, once after the failed POST).
  [ -s "$STUB_POSTED" ]
  [ "$(grep -c -- '/comments?per_page=100' "$STUB_CALLS")" -ge 2 ]
}

@test "an unreadable POST response with NOTHING on the PR still fails closed (exit 5)" {
  ri_report CLEAN
  # STUB_COMMENTS='[]' => the re-read sees an EMPTY PR, i.e. the write did not
  # land. An unreadable response alone must never be read as success.
  STUB_COMMENTS='[]' STUB_POST_UNREADABLE=1 \
    run "$SCRIPT" Muso-AI/hydra 77 "$HEAD_OID" --state-dir "$STATE"
  [ "$status" -eq 5 ]
  echo "$output" | grep -q 'the create call failed and its response could not be read'
  refute_output 'NO hand-off'
}

@test "the re-read only accepts a same-head hand-off that is NON-OLDER than ours" {
  # An id-only check would pass here and hide a real publish failure: the comment
  # is for this head, but its payload was generated BEFORE this run built its own,
  # so it cannot be the comment this run created. `created_at` cannot tell them
  # apart either (the API stamps it), which is why generated_at is compared.
  ri_report CLEAN
  payload="$(jq -nc --arg head "$HEAD_OID" '
    {version: 1, repo: "Muso-AI/hydra", pr: 77, head_sha: $head,
     generated_at: "2026-10-27T00:00:00Z", reports: {}, missing: []}')"
  b64="$(printf '%s' "$payload" | gzip -9 -n | base64 | tr -d '\n')"
  comments="$(jq -nc --arg b "<!-- muso-qa-handoff v1 payload=$b64 -->" '
    [{id: 4242, created_at: "2026-11-04T00:00:00Z",
      user: {login: "github-actions[bot]"}, body: $b}]')"
  STUB_COMMENTS="$comments" STUB_POST_UNREADABLE=1 \
    run "$SCRIPT" Muso-AI/hydra 77 "$HEAD_OID" --state-dir "$STATE"
  [ "$status" -eq 5 ]
  echo "$output" | grep -q 'the create call failed and its response could not be read'
}

@test "re-run that cannot DELETE the stale hand-off does not post a second one" {
  ri_report CLEAN
  payload="$(jq -nc --arg head "$HEAD_OID" '
    {version: 1, repo: "Muso-AI/hydra", pr: 77, head_sha: $head,
     generated_at: "2026-10-27T00:00:00Z", reports: {}, missing: []}')"
  b64="$(printf '%s' "$payload" | gzip -9 -n | base64 | tr -d '\n')"
  comments="$(jq -nc --arg b "<!-- muso-qa-handoff v1 payload=$b64 -->" '
    [{id: 4242, created_at: "2026-10-27T00:00:00Z",
      user: {login: "github-actions[bot]"}, body: $b}]')"
  STUB_COMMENTS="$comments" STUB_DELETE_RC=1 \
    run "$SCRIPT" Muso-AI/hydra 77 "$HEAD_OID" --state-dir "$STATE"
  [ "$status" -eq 5 ]
  refute_calls '--method POST'   # no newer twin to fool the guard
}

@test "a MALFORMED comment list is fatal too (a 200 with garbage is not 'no hand-offs')" {
  ri_report CLEAN
  # HTTP 200, but the body is not a JSON array: the publisher must not conclude
  # that nothing needs withdrawing.
  STUB_COMMENTS='{"message":"Bad gateway"}' \
    run "$SCRIPT" Muso-AI/hydra 77 "$HEAD_OID" --state-dir "$STATE"
  [ "$status" -eq 5 ]
  echo "$output" | grep -q 'cannot read this PR'
  refute_calls '--method POST'
  refute_calls '--method DELETE'
}

@test "an UNREADABLE comment list is fatal — it cannot prove withdrawal, so it publishes nothing" {
  # QA finding, round 5: with the GET failing, "I could not read the existing
  # hand-offs" silently became "there are none to withdraw", so a rerun whose
  # analyzers produced nothing exited 0 with the previous CLEAN still readable.
  payload="$(jq -nc --arg head "$HEAD_OID" '
    {version: 1, repo: "Muso-AI/hydra", pr: 77, head_sha: $head,
     generated_at: "2026-10-27T00:00:00Z", reports: {}, missing: []}')"
  b64="$(printf '%s' "$payload" | gzip -9 -n | base64 | tr -d '\n')"
  comments="$(jq -nc --arg b "<!-- muso-qa-handoff v1 payload=$b64 -->" '
    [{id: 4242, created_at: "2026-10-27T00:00:00Z",
      user: {login: "github-actions[bot]"}, body: $b}]')"
  # no analyzer reports at all AND the read fails
  STUB_COMMENTS="$comments" STUB_GET_RC=1 \
    run "$SCRIPT" Muso-AI/hydra 77 "$HEAD_OID" --state-dir "$STATE"
  [ "$status" -eq 5 ]
  echo "$output" | grep -q 'cannot read this PR'
  refute_calls '--method POST'
}

@test "an existing hand-off for a DIFFERENT head is not touched" {
  ri_report CLEAN
  payload="$(jq -nc --arg head "$PRIOR_OID" '
    {version: 1, repo: "Muso-AI/hydra", pr: 77, head_sha: $head,
     generated_at: "2026-10-27T00:00:00Z", reports: {}, missing: []}')"
  b64="$(printf '%s' "$payload" | gzip -9 -n | base64 | tr -d '\n')"
  comments="$(jq -nc --arg b "<!-- muso-qa-handoff v1 payload=$b64 -->" '
    [{id: 4242, created_at: "2026-10-27T00:00:00Z",
      user: {login: "github-actions[bot]"}, body: $b}]')"
  STUB_COMMENTS="$comments" run "$SCRIPT" Muso-AI/hydra 77 "$HEAD_OID" --state-dir "$STATE"
  [ "$status" -eq 0 ]
  grep -q -- '--method POST' "$STUB_CALLS"
  refute_calls 'issues/comments/4242'
}

@test "an UNTRUSTED look-alike comment is never DELETEd (its author does not own the channel)" {
  ri_report CLEAN
  payload="$(jq -nc --arg head "$HEAD_OID" '
    {version: 1, repo: "Muso-AI/hydra", pr: 77, head_sha: $head,
     generated_at: "2026-10-27T00:00:00Z", reports: {}, missing: []}')"
  b64="$(printf '%s' "$payload" | gzip -9 -n | base64 | tr -d '\n')"
  comments="$(jq -nc --arg b "<!-- muso-qa-handoff v1 payload=$b64 -->" '
    [{id: 666, created_at: "2026-10-27T00:00:00Z",
      user: {login: "nsollazzo"}, body: $b}]')"
  STUB_COMMENTS="$comments" run "$SCRIPT" Muso-AI/hydra 77 "$HEAD_OID" --state-dir "$STATE"
  [ "$status" -eq 0 ]
  grep -q -- '--method POST' "$STUB_CALLS"
  refute_calls 'issues/comments/666'
}

# ── refusals ───────────────────────────────────────────────────────────────

@test "a report describing ANOTHER head is not published, and the run says so" {
  ri_report CLEAN
  br_report LOW
  # Rewrite the rebase-integrity report's interior key to a different head: the
  # file name says this head, its contents do not. Publishing it would let the
  # guards validate another commit's evidence for THIS approval.
  jq --arg h "$PRIOR_OID" '.head_sha = $h' \
    "$STATE/rebase-integrity/Muso-AI__hydra-pr-77-${HEAD_OID}.json" >"$TEST_TMPDIR/tmp" \
    && mv "$TEST_TMPDIR/tmp" "$STATE/rebase-integrity/Muso-AI__hydra-pr-77-${HEAD_OID}.json"
  run "$SCRIPT" Muso-AI/hydra 77 "$HEAD_OID" --state-dir "$STATE"
  [ "$status" -eq 3 ]
  echo "$output" | grep -q 'NOT publishing it'
  echo "$output" | grep -q 'does not describe Muso-AI/hydra#77'
  # the good kind still went out, and the missing one is named in the payload
  body="$(cat "$STUB_POSTED")"
  b64="${body#<!-- muso-qa-handoff v1 payload=}"; b64="${b64% -->}"
  decoded="$(printf '%s' "$b64" | base64 -d | gzip -dc)"
  [ "$(printf '%s' "$decoded" | jq -r '.reports["blast-radius"].tier')" = "LOW" ]
  [ "$(printf '%s' "$decoded" | jq -r '.reports["rebase-integrity"] // "absent"')" = "absent" ]
  [ "$(printf '%s' "$decoded" | jq -r '.missing[0]')" = "rebase-integrity" ]
}

@test "malformed JSON on disk is not published either" {
  printf '%s' '{"repo": "Muso-AI/hydra", oops' \
    >"$STATE/rebase-integrity/Muso-AI__hydra-pr-77-${HEAD_OID}.json"
  br_report LOW
  run "$SCRIPT" Muso-AI/hydra 77 "$HEAD_OID" --state-dir "$STATE"
  [ "$status" -eq 3 ]
  echo "$output" | grep -q 'not valid JSON'
}

@test "no reports at all → nothing posted, exit 0 (an empty hand-off is timeline noise)" {
  STUB_COMMENTS='[]' run "$SCRIPT" Muso-AI/hydra 77 "$HEAD_OID" --state-dir "$STATE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'nothing to publish'
  # It reads to find earlier hand-offs (none here) and writes nothing.
  refute_calls '--method POST'
  refute_calls '--method DELETE'
}

@test "no reports at all STILL withdraws this head's earlier hand-off (no stale evidence)" {
  # The residual the round-1 fix left open: a re-run where the analyzers produced
  # no report must not leave the previous run's verdict standing for this head.
  payload="$(jq -nc --arg head "$HEAD_OID" '
    {version: 1, repo: "Muso-AI/hydra", pr: 77, head_sha: $head,
     generated_at: "2026-10-27T00:00:00Z", reports: {}, missing: []}')"
  b64="$(printf '%s' "$payload" | gzip -9 -n | base64 | tr -d '\n')"
  comments="$(jq -nc --arg b "<!-- muso-qa-handoff v1 payload=$b64 -->" '
    [{id: 4242, created_at: "2026-10-27T00:00:00Z",
      user: {login: "github-actions[bot]"}, body: $b}]')"
  STUB_COMMENTS="$comments" run "$SCRIPT" Muso-AI/hydra 77 "$HEAD_OID" --state-dir "$STATE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'withdrew the earlier hand-off'
  grep -q -- '--method DELETE repos/Muso-AI/hydra/issues/comments/4242' "$STUB_CALLS"
  refute_calls '--method POST'
}

@test "an oversized payload refuses rather than posting a truncated one" {
  # Incompressible evidence: base64 of random bytes, so gzip cannot save us.
  big="$(head -c 60000 /dev/urandom | base64 | tr -d '\n')"
  jq -nc --arg head "$HEAD_OID" --arg big "$big" '
    {version: 1, repo: "Muso-AI/hydra", pr: 77, head_sha: $head,
     status: "WARN", signals: [{id: "big", severity: "warn", summary: $big, evidence: [$big]}],
     skipped: []}' >"$STATE/rebase-integrity/Muso-AI__hydra-pr-77-${HEAD_OID}.json"
  run "$SCRIPT" Muso-AI/hydra 77 "$HEAD_OID" --state-dir "$STATE"
  [ "$status" -eq 4 ]
  echo "$output" | grep -q 'cannot carry it'
  echo "$output" | grep -q 'earlier hand-off for this head was withdrawn'
  # A read to look for earlier hand-offs is fine; a WRITE is not.
  refute_calls '--method POST'
  refute_calls '--method DELETE'
}

@test "usage: a short sha / non-numeric pr / malformed repo are refused before any API call" {
  for args in "Muso-AI/hydra 77 deadbeef" "Muso-AI/hydra pr77 $HEAD_OID" "hydra 77 $HEAD_OID"; do
    # shellcheck disable=SC2086
    run "$SCRIPT" $args --state-dir "$STATE"
    [ "$status" -eq 2 ]
  done
  [ ! -s "$STUB_CALLS" ]
}

@test "dry-run prints the body and posts NOTHING" {
  ri_report CLEAN
  run "$SCRIPT" Muso-AI/hydra 77 "$HEAD_OID" --state-dir "$STATE" --dry-run
  [ "$status" -eq 0 ]
  # stdout is the machine channel (the body); the analyzer-absent notice is
  # stderr and bats merges the two, so match the body line rather than equality.
  echo "$output" | grep -qE '^<!-- muso-qa-handoff v1 payload=[A-Za-z0-9+/=]+ -->$'
  [ ! -s "$STUB_CALLS" ]
}

# ── the encoder/decoder pair the reader shares ─────────────────────────────

@test "encode/decode round-trips unicode and newlines without mangling" {
  # shellcheck source=scripts/lib/qa-handoff.sh
  . "$LIB"
  json='{"repo":"Muso-AI/hydra","note":"héllo — ünïcode\nsecond line","n":1}'
  b64="$(printf '%s' "$json" | gzip -9 -n | base64 | tr -d '\n')"
  [ "$(qa_handoff_decode "$b64")" = "$json" ]
  # A mangled payload is "no hand-off", never a crash or a partial parse.
  run qa_handoff_decode 'not-base64!!'
  [ "$status" -ne 0 ]
}

# ── wiring: the workflow actually calls the publisher ──────────────────────

@test "pr-validate.yml runs both analyzers into the hand-off dir and publishes it" {
  command -v python3 >/dev/null || skip "python3 unavailable"
  python3 - "$HYDRA_REPO" <<'PYEOF'
import sys, yaml
root = sys.argv[1]
wf = yaml.safe_load(open(f"{root}/.github/workflows/pr-validate.yml"))
jobs = wf["jobs"]

def step_named(job, frag):
    return [(s.get("name", ""), s) for s in job["steps"] if frag in (s.get("run") or "")]

# The invariant is LAYOUT-INDEPENDENT on purpose: PR Validation's job split moves
# (node-8 vs the in-cluster ARC fleet, 2026-10-27), but the hand-off contract does
# not — both analyzers and the publisher must run on the SAME runner, because the
# publisher reads the reports the analyzers just wrote.
holders = {}
for name, job in jobs.items():
    ri = step_named(job, "check-rebase-integrity.sh")
    br = step_named(job, "check-blast-radius.sh")
    pub = step_named(job, "qa-handoff-publish.sh")
    if ri or br or pub:
        holders[name] = (job, ri, br, pub)
assert len(holders) == 1, f"analyzers/publisher must share exactly one job, found {sorted(holders)}"
job_name, (job, ri, br, pub) = next(iter(holders.items()))
assert len(ri) == 1 and len(br) == 1 and len(pub) == 1, (
    f"{job_name}: expected one of each step, got ri={len(ri)} br={len(br)} pub={len(pub)}")

# 1. Each analyzer is pointed at a WRITABLE hand-off dir. Without this the final
#    write fails on a runner whose /var/lib/hydra-qa is root-owned, the analyzer
#    exits 3, and NO report is ever published — the guard then refuses every
#    approval with no clue why.
ri_body = ri[0][1]["run"]
assert "qa_handoff_root" in ri_body, "analyzer must resolve the writable hand-off dir"
assert 'RI_STATE_DIR="$root/rebase-integrity"' in ri_body
br_body = br[0][1]["run"]
assert "qa_handoff_root" in br_body, "analyzer must resolve the writable hand-off dir"
assert 'BR_STATE_DIR="$root/blast-radius"' in br_body

# 2. The publisher runs AFTER them, and its failure goes RED. Only the reports'
#    CONTENT is advisory; the hand-off itself is the evidence pipeline, so a
#    publish that cannot be proved is a failed job (the guards, not CI, are the
#    fail-closed consumers of what the reports SAY).
names = [s.get("name") for s in job["steps"]]
assert names.index(pub[0][0]) > names.index(ri[0][0]), "publish must follow the analyzers"
assert names.index(pub[0][0]) > names.index(br[0][0]), "publish must follow the analyzers"
pub_body = pub[0][1]["run"]
# It must NOT pass a hardcoded host path: the publisher resolves the same dir the
# analyzers wrote to (QA_HANDOFF_ROOT, else qa_handoff_root()), and a literal
# /var/lib/hydra-qa here would silently point a pod run at a path that does not
# exist — "nothing to publish", then every approval refuses with no clue.
assert "/var/lib/hydra-qa" not in pub_body, "publish step must not hardcode the CI-host path"
# A publish failure must go RED now: leaving CI green after a hand-off that could
# not be invalidated would let Guard 6 vouch for a previous run's evidence for
# this same head (QA finding, round 1). Check the CODE, not the comment that
# explains the rule — the explanation mentions `|| echo` by name.
pub_code = "\n".join(l for l in pub_body.splitlines() if not l.lstrip().startswith("#"))
assert "|| echo" not in pub_code, "a publish failure must fail the job, not warn"
assert "always()" in str(pub[0][1].get("if", "")), "publish must run even when an analyzer warned"
assert "cancelled()" in str(pub[0][1].get("if", "")), "a cancelled run has no verdict to hand over"

# 3. That job's token can comment. Without pull-requests: write the publish step
#    403s on every PR and only the on-disk fallback keeps the guards alive.
perms = job.get("permissions") or {}
assert perms.get("pull-requests") == "write", f"{job_name} needs pull-requests: write, got {perms}"
PYEOF
}
