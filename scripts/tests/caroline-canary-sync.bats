#!/usr/bin/env bats
# caroline-promptguard-canary-p1: the per-deploy canary token.
# scripts/caroline-canary-sync.sh writes TWO copies (the prompt-readable host file and the
# RAG-readable reference doc) and --check is what the deploy wiring and operators rely on to prove
# they agree. Everything here runs against a throwaway --root, so no real token is touched.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SYNC="$HYDRA_REPO/scripts/caroline-canary-sync.sh"
TOKEN_FILE_REL=".canary-token"
REF_FILE_REL="workspaces/support/reference/canary-token.md"

setup() {
  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/workspaces/support/reference"
}

@test "sync writes both copies at the intended modes" {
  run bash "$SYNC" --root "$ROOT"
  [ "$status" -eq 0 ]
  [ -f "$ROOT/$TOKEN_FILE_REL" ]
  # 0600: a world-writable token file would let any local user pin a value they know and force blocks.
  [ "$(stat -c '%a' "$ROOT/$TOKEN_FILE_REL")" = "600" ]
  [ -f "$ROOT/$REF_FILE_REL" ]
}

@test "the token is 32 lowercase hex" {
  bash "$SYNC" --root "$ROOT" 2>/dev/null
  token="$(cat "$ROOT/$TOKEN_FILE_REL")"
  [ "${#token}" -eq 32 ]
  printf '%s' "$token" | grep -Eq '^[0-9a-f]{32}$'
}

@test "the RAG copy carries the same token as the prompt copy" {
  bash "$SYNC" --root "$ROOT" 2>/dev/null
  token="$(cat "$ROOT/$TOKEN_FILE_REL")"
  # It must land under reference/, the ONE path the fleet's retrieval covers
  # (memory.search.extraPaths == ["reference"], CI-pinned by validate-shared-config.sh).
  grep -qF -- "$token" "$ROOT/$REF_FILE_REL"
}

@test "the log identifies the rotation WITHOUT printing the token" {
  run bash "$SYNC" --root "$ROOT"
  [ "$status" -eq 0 ]
  token="$(cat "$ROOT/$TOKEN_FILE_REL")"
  # A deploy log is a public-ish artifact; a token pasted out of it could be replayed to force a
  # false block on purpose. Only an 8-char digest may appear.
  [[ "$output" != *"$token"* ]]
  [[ "$output" == *"rotated (sha256:"* ]]
}

@test "every run rotates the token" {
  bash "$SYNC" --root "$ROOT" 2>/dev/null
  first="$(cat "$ROOT/$TOKEN_FILE_REL")"
  bash "$SYNC" --root "$ROOT" 2>/dev/null
  second="$(cat "$ROOT/$TOKEN_FILE_REL")"
  [ "$first" != "$second" ]
}

@test "check passes right after a sync" {
  bash "$SYNC" --root "$ROOT" 2>/dev/null
  run bash "$SYNC" --root "$ROOT" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: canary present, both copies agree"* ]]
}

@test "check FAILS when the prompt and RAG copies disagree" {
  bash "$SYNC" --root "$ROOT" 2>/dev/null
  # Simulate a half-landed deploy: one write succeeded, the other did not.
  other="$(printf 'f%.0s' $(seq 32))"
  printf '%s\n' "$other" > "$ROOT/$TOKEN_FILE_REL"
  chmod 600 "$ROOT/$TOKEN_FILE_REL"
  run bash "$SYNC" --root "$ROOT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"disagree"* ]]
}

@test "check FAILS on a world-writable token file" {
  bash "$SYNC" --root "$ROOT" 2>/dev/null
  chmod 666 "$ROOT/$TOKEN_FILE_REL"
  run bash "$SYNC" --root "$ROOT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"mode 666"* ]]
}

@test "check FAILS when nothing has been deployed yet" {
  run bash "$SYNC" --root "$ROOT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"is missing"* ]]
}

@test "a malformed token on disk is treated as absent, never as a usable canary" {
  bash "$SYNC" --root "$ROOT" 2>/dev/null
  # Uppercase: the loader (canary-token.ts CANARY_TOKEN_RE) rejects it, so a silent pass here would
  # mean the fleet runs with no canary while --check says it is fine.
  printf 'ABCDEF0123456789ABCDEF0123456789\n' > "$ROOT/$TOKEN_FILE_REL"
  run bash "$SYNC" --root "$ROOT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a 32-hex token"* ]]
}

@test "--reuse keeps the current token instead of rotating" {
  bash "$SYNC" --root "$ROOT" 2>/dev/null
  first="$(cat "$ROOT/$TOKEN_FILE_REL")"
  run bash "$SYNC" --root "$ROOT" --reuse
  [ "$status" -eq 0 ]
  [[ "$output" == *"reusing the existing token"* ]]
  [ "$(cat "$ROOT/$TOKEN_FILE_REL")" = "$first" ]
}

@test "--reuse mints a token when the one on disk is unusable" {
  printf 'not-a-token\n' > "$ROOT/$TOKEN_FILE_REL"
  run bash "$SYNC" --root "$ROOT" --reuse
  [ "$status" -eq 0 ]
  token="$(cat "$ROOT/$TOKEN_FILE_REL")"
  printf '%s' "$token" | grep -Eq '^[0-9a-f]{32}$'
}

@test "--dry-run writes nothing" {
  run bash "$SYNC" --root "$ROOT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run: would write"* ]]
  [ ! -f "$ROOT/$TOKEN_FILE_REL" ]
  [ ! -f "$ROOT/$REF_FILE_REL" ]
}

@test "--print is the only mode that emits a bare token" {
  run bash "$SYNC" --root "$ROOT" --print
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -Eq '^[0-9a-f]{32}$'
}

@test "the rendered RAG copy passes the reference blocklist gate" {
  bash "$SYNC" --root "$ROOT" 2>/dev/null
  # A file dropped into workspaces/support/reference/ is scanned by
  # scripts/lib/cs-reference-blocklist.sh; a canary doc that tripped it would be stripped from the
  # RAG index, silently removing the retrieval half of the detector.
  run bash -c ". '$HYDRA_REPO/scripts/lib/cs-reference-blocklist.sh'; cs_reference_blocklist_hits '$ROOT/$REF_FILE_REL'"
  [ "$status" -eq 1 ]
  # The doc must name the script that generates it, so an operator reading reference/ knows the file
  # is regenerated every deploy and hand-editing it is pointless.
  run grep -c 'scripts/caroline-canary-sync.sh' "$ROOT/$REF_FILE_REL"
  [ "$output" = "1" ]
}
