#!/usr/bin/env bats
# Tests for scripts/qa-handoff-read.sh — the consumer CLI for the off-disk QA
# hand-off (T10).
#
# The skill uses this instead of `cat /var/lib/hydra-qa/...json`, and a human
# uses it to see exactly what Guard 8/9 graded. Two properties matter and are
# pinned here: (1) it prints the report for the head ASKED FOR, never whichever
# comment happens to be newest; (2) "no hand-off" is exit 1 with a message a
# reviewer can quote — never an empty success, which would read as "clean".

bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/qa-handoff-read.sh"

HEAD_OID="0123456789abcdef0123456789abcdef01234567"
PRIOR_OID="2222222222222222222222222222222222222222"
DIGEST="$(printf 'd%.0s' {1..64})"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  STUBBIN="$TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  cat >"$STUBBIN/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
# Model real gh, including what it REJECTS: `gh api` has no --repo flag. A stub
# that quietly accepted one hid a publisher that failed on every real run.
if [ "${1:-}" = "--repo" ] && [ "${3:-}" = "api" ]; then
  echo "unknown flag: --repo" >&2; exit 1
fi
case "${1:-}" in
  api)
    shift
    case "$*" in
      *"/comments?per_page=100"*)
        [ "${STUB_GET_RC:-0}" = "0" ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
        printf '%s' "${STUB_COMMENTS:-[]}" ;;
      *) echo "unexpected api: $*" >&2; exit 9 ;;
    esac ;;
  pr)
    # pr view <n> --repo <r> --json headRefOid --jq .headRefOid
    # The stub runs as a subprocess: a literal, not $HEAD_OID (not exported).
    printf '%s' "${STUB_HEAD_OID-0123456789abcdef0123456789abcdef01234567}" ;;
  *) echo "unexpected gh: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$STUBBIN/gh"
  export GH="$STUBBIN/gh"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

ri() {  # <head> <status> [digest] → report object
  jq -nc --arg h "$1" --arg s "$2" --arg d "${3:-}" \
    '{repo: "Muso-AI/hydra", pr: 77, head_sha: $h, status: $s}
     + (if $d == "" then {} else {warn_digest: $d} end)'
}

comment() {  # <reports-json> <head> [login] [id]
  local reports="$1" head="$2" login="${3:-github-actions[bot]}" id="${4:-1}" payload b64
  payload="$(jq -cn --arg head "$head" --argjson reports "$reports" '
    {version: 1, repo: "Muso-AI/hydra", pr: 77, head_sha: $head,
     generated_at: "2026-10-27T00:00:00Z", reports: $reports, missing: []}')"
  b64="$(printf '%s' "$payload" | gzip -9 -n | base64 | tr -d '\n')"
  jq -nc --arg b "<!-- muso-qa-handoff v1 payload=$b64 -->" --arg l "$login" --argjson i "$id" '
    {id: $i, created_at: "2026-10-27T00:00:00Z", user: {login: $l}, body: $b}'
}

@test "prints THIS head's report, not the newest comment's" {
  c1="$(comment "$(jq -cn --argjson r "$(ri "$PRIOR_OID" WARN "$DIGEST")" '{"rebase-integrity": $r}')" "$PRIOR_OID" "" 1)"
  c2="$(comment "$(jq -cn --argjson r "$(ri "$HEAD_OID" CLEAN)" '{"rebase-integrity": $r}')" "$HEAD_OID" "" 2)"
  STUB_COMMENTS="$(jq -cn --argjson a "$c1" --argjson b "$c2" '[$a, $b]')" \
    run "$SCRIPT" Muso-AI/hydra 77 rebase-integrity --head "$PRIOR_OID"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "WARN" ]
  [ "$(printf '%s' "$output" | jq -r .head_sha)" = "$PRIOR_OID" ]
}

@test "defaults the head to the PR's headRefOid" {
  c="$(comment "$(jq -cn --argjson r "$(ri "$HEAD_OID" CLEAN)" '{"rebase-integrity": $r}')" "$HEAD_OID")"
  STUB_COMMENTS="$(jq -cn --argjson a "$c" '[$a]')" \
    run "$SCRIPT" Muso-AI/hydra 77 rebase-integrity
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .status)" = "CLEAN" ]
}

@test "a head with no report exits 1 and says so — never an empty success" {
  c="$(comment "$(jq -cn --argjson r "$(ri "$PRIOR_OID" CLEAN)" '{"rebase-integrity": $r}')" "$PRIOR_OID")"
  STUB_COMMENTS="$(jq -cn --argjson a "$c" '[$a]')" \
    run "$SCRIPT" Muso-AI/hydra 77 rebase-integrity --head "$HEAD_OID"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'no rebase-integrity hand-off'
  [ -z "$(printf '%s' "$output" | grep -v '^qa-handoff-read:')" ]
}

@test "--digest lists the other heads carrying that warn_digest (carry-forward query)" {
  other="$(printf 'e%.0s' {1..64})"
  c1="$(comment "$(jq -cn --argjson r "$(ri "$PRIOR_OID" WARN "$DIGEST")" '{"rebase-integrity": $r}')" "$PRIOR_OID" "" 1)"
  c2="$(comment "$(jq -cn --argjson r "$(ri "3333333333333333333333333333333333333333" WARN "$other")" '{"rebase-integrity": $r}')" "3333333333333333333333333333333333333333" "" 2)"
  c3="$(comment "$(jq -cn --argjson r "$(ri "$HEAD_OID" WARN "$DIGEST")" '{"rebase-integrity": $r}')" "$HEAD_OID" "" 3)"
  STUB_COMMENTS="$(jq -cn --argjson a "$c1" --argjson b "$c2" --argjson d "$c3" '[$a, $b, $d]')" \
    run "$SCRIPT" Muso-AI/hydra 77 rebase-integrity --digest "$DIGEST"
  [ "$status" -eq 0 ]
  # Without --head every matching head is listed (the old glob's semantics)...
  [ "$output" = "$PRIOR_OID
$HEAD_OID" ]
}

@test "--digest + --head excludes this head (the 'OTHER heads' question Guard 8 asks)" {
  c1="$(comment "$(jq -cn --argjson r "$(ri "$PRIOR_OID" WARN "$DIGEST")" '{"rebase-integrity": $r}')" "$PRIOR_OID" "" 1)"
  c3="$(comment "$(jq -cn --argjson r "$(ri "$HEAD_OID" WARN "$DIGEST")" '{"rebase-integrity": $r}')" "$HEAD_OID" "" 3)"
  STUB_COMMENTS="$(jq -cn --argjson a "$c1" --argjson d "$c3" '[$a, $d]')" \
    run "$SCRIPT" Muso-AI/hydra 77 rebase-integrity --digest "$DIGEST" --head "$HEAD_OID"
  [ "$status" -eq 0 ]
  [ "$output" = "$PRIOR_OID" ]
}

@test "--digest with no match exits 1 (no inherited ack, so Guard 8 would refuse)" {
  c="$(comment "$(jq -cn --argjson r "$(ri "$HEAD_OID" WARN "$DIGEST")" '{"rebase-integrity": $r}')" "$HEAD_OID")"
  STUB_COMMENTS="$(jq -cn --argjson a "$c" '[$a]')" \
    run "$SCRIPT" Muso-AI/hydra 77 rebase-integrity --digest "$(printf 'f%.0s' {1..64})"
  [ "$status" -eq 1 ]
}

@test "an UNTRUSTED author's hand-off is invisible" {
  c="$(comment "$(jq -cn --argjson r "$(ri "$HEAD_OID" CLEAN)" '{"rebase-integrity": $r}')" "$HEAD_OID" "nsollazzo" 9)"
  STUB_COMMENTS="$(jq -cn --argjson a "$c" '[$a]')" \
    run "$SCRIPT" Muso-AI/hydra 77 rebase-integrity --head "$HEAD_OID"
  [ "$status" -eq 1 ]
}

@test "no comments at all exits 1 (nothing published yet)" {
  STUB_COMMENTS='[]' run "$SCRIPT" Muso-AI/hydra 77 blast-radius
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'no QA hand-off comment'
}

@test "an unreadable COMMENT READ exits 3, not 1 — 'unverified' is not 'no hand-off'" {
  # The two states send a reviewer in different directions ("re-run CI" vs "retry
  # with a working token"), and the QA review flagged that the header promised 3
  # while the code returned 1 for both.
  STUB_COMMENTS='[]' STUB_GET_RC=1 run "$SCRIPT" Muso-AI/hydra 77 rebase-integrity
  [ "$status" -eq 3 ]
  echo "$output" | grep -q 'could not read'
  echo "$output" | grep -q 'NOT "no hand-off"'
}

@test "an unreadable head aborts with exit 3 instead of guessing one" {
  STUB_COMMENTS='[]' STUB_HEAD_OID="" run "$SCRIPT" Muso-AI/hydra 77 rebase-integrity
  [ "$status" -eq 3 ]
  echo "$output" | grep -q 'could not read a valid headRefOid'
}

@test "usage: bad kind / bad head / bad digest / bad pr are refused" {
  run "$SCRIPT" Muso-AI/hydra 77 bogus-kind
  [ "$status" -eq 2 ]
  run "$SCRIPT" Muso-AI/hydra 77 rebase-integrity --head deadbeef
  [ "$status" -eq 2 ]
  run "$SCRIPT" Muso-AI/hydra 77 rebase-integrity --digest abc
  [ "$status" -eq 2 ]
  run "$SCRIPT" Muso-AI/hydra x7 rebase-integrity
  [ "$status" -eq 2 ]
}

@test "--pretty formats the report" {
  c="$(comment "$(jq -cn --argjson r "$(ri "$HEAD_OID" CLEAN)" '{"rebase-integrity": $r}')" "$HEAD_OID")"
  STUB_COMMENTS="$(jq -cn --argjson a "$c" '[$a]')" \
    run "$SCRIPT" Muso-AI/hydra 77 rebase-integrity --pretty
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | head -1)" = "{" ]
}
