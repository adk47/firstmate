#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers
# Tests for lib/api-evidence.sh — additive replacement for lib/browser-evidence.sh
# in the credit-verification approve-gate flow. Counts API-helper invocations
# (musicbrainz / spotify / discogs) + AllMusic browser fallback as evidence
# sources, against a session JSONL fixture.
#
# Test approach:
#   We source the lib in a sub-shell, point CV_SESSION_LOG_OVERRIDE at a
#   hand-crafted JSONL fixture, then call each public function and assert
#   the integer return. No live openclaw calls.
#
# Per feedback_bats_must_stub_openclaw — PATH-shadow openclaw so any
# accidental shell-out doesn't reach prod #credit-verification.

setup() {
  setup_tmp_env
  LIB="$SCRIPTS_DIR/lib/api-evidence.sh"
  [[ -f "$LIB" ]] || { echo "lib/api-evidence.sh missing: $LIB" >&2; return 1; }

  STUB_DIR="$TEST_TMPDIR/stub"
  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/openclaw" <<'OPENCLAW_STUB'
#!/usr/bin/env bash
echo "openclaw stub — api-evidence test should not need this" >&2
exit 1
OPENCLAW_STUB
  chmod +x "$STUB_DIR/openclaw"
  export PATH="$STUB_DIR:$PATH"

  export CV_SESSION_LOG="$TEST_TMPDIR/session.jsonl"
  export CV_SESSION_LOG_OVERRIDE="$CV_SESSION_LOG"
  : > "$CV_SESSION_LOG"
}

teardown() { teardown_tmp_env; }

# Append one JSONL line to the session log. Args: <json>
sl() { printf '%s\n' "$1" >> "$CV_SESSION_LOG"; }

# Call function under test in a sub-shell that sources the lib. Echoes the
# numeric return on stdout. Args: <fn-name> <excerpt> [<pid>]
call_lib() {
  local fn="$1" excerpt="$2" pid="${3:-test-pid}"
  bash -c "
    set -e
    source '$LIB'
    $fn '$excerpt' '$pid'
  "
}

# ---------- api evidence: helper hits with excerpt match -----------------

@test "api_evidence: 2 distinct helpers (mb + discogs) match excerpt → returns 2" {
  # bash toolCall: musicbrainz helper
  sl '{"timestamp":"2026-05-06T18:00:00Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"bash /opt/hydra/workspaces/operations/skills/muso-ops-credit-verification/scripts/musicbrainz-isrc-lookup.sh USXX1 --credited-name \"Bram Fidder\" --role Mastering"}}]}}'
  # toolResult with helper JSON containing the excerpt
  sl '{"timestamp":"2026-05-06T18:00:01Z","message":{"role":"toolResult","toolCallId":"c1","content":[{"type":"text","text":"{\"isrc\":\"USXX1\",\"found\":true,\"name_match\":true,\"role_match\":true,\"evidence_excerpt\":\"Bram Fidder – mastering\"}"}]}}'
  # bash toolCall: discogs helper
  sl '{"timestamp":"2026-05-06T18:00:02Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"c2","name":"bash","arguments":{"command":"bash scripts/discogs-isrc-lookup.sh USXX1 --credited-name \"Bram Fidder\""}}]}}'
  sl '{"timestamp":"2026-05-06T18:00:03Z","message":{"role":"toolResult","toolCallId":"c2","content":[{"type":"text","text":"{\"isrc\":\"USXX1\",\"found\":true,\"name_match\":true,\"evidence_excerpt\":\"Bram Fidder – Mastered By (Discogs)\"}"}]}}'

  run call_lib count_profile_api_evidence "Bram Fidder"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

# ---------- api evidence: same helper twice → 1 source -------------------

@test "api_evidence: two musicbrainz hits collapse to 1 source" {
  sl '{"timestamp":"2026-05-06T18:00:00Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"bash musicbrainz-isrc-lookup.sh USXX1"}}]}}'
  sl '{"timestamp":"2026-05-06T18:00:01Z","message":{"role":"toolResult","toolCallId":"c1","content":[{"type":"text","text":"Bram Fidder – mastering"}]}}'
  sl '{"timestamp":"2026-05-06T18:00:02Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"c2","name":"bash","arguments":{"command":"bash musicbrainz-isrc-lookup.sh USYY2"}}]}}'
  sl '{"timestamp":"2026-05-06T18:00:03Z","message":{"role":"toolResult","toolCallId":"c2","content":[{"type":"text","text":"Bram Fidder – mastering on Other Track"}]}}'

  run call_lib count_profile_api_evidence "Bram Fidder"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

# ---------- api evidence: helper hit without excerpt match → 0 ------------

@test "api_evidence: helper toolResult without excerpt → 0" {
  sl '{"timestamp":"2026-05-06T18:00:00Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"bash musicbrainz-isrc-lookup.sh USXX1"}}]}}'
  sl '{"timestamp":"2026-05-06T18:00:01Z","message":{"role":"toolResult","toolCallId":"c1","content":[{"type":"text","text":"{\"isrc\":\"USXX1\",\"found\":false,\"name_match\":false,\"evidence_excerpt\":null}"}]}}'

  run call_lib count_profile_api_evidence "Bram Fidder"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# ---------- api evidence: errored toolResult → 0 -------------------------

@test "api_evidence: helper toolResult with isError=true → 0 even if text contains excerpt" {
  sl '{"timestamp":"2026-05-06T18:00:00Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"bash spotify-track-lookup.sh sp123"}}]}}'
  sl '{"timestamp":"2026-05-06T18:00:01Z","message":{"role":"toolResult","toolCallId":"c1","isError":true,"content":[{"type":"text","text":"Bram Fidder error trace"}]}}'

  run call_lib count_profile_api_evidence "Bram Fidder"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# ---------- api evidence: case-insensitive excerpt match -----------------

@test "api_evidence: excerpt match is case-insensitive" {
  sl '{"timestamp":"2026-05-06T18:00:00Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"bash spotify-track-lookup.sh sp123"}}]}}'
  sl '{"timestamp":"2026-05-06T18:00:01Z","message":{"role":"toolResult","toolCallId":"c1","content":[{"type":"text","text":"{\"name_match\":true,\"evidence_excerpt\":\"BRAM FIDDER – Track Name (Spotify)\"}"}]}}'

  run call_lib count_profile_api_evidence "bram fidder"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

# ---------- api evidence: bash to non-helper script → 0 ------------------

@test "api_evidence: bash toolCall to non-helper script does not count" {
  sl '{"timestamp":"2026-05-06T18:00:00Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"echo Bram Fidder is somewhere"}}]}}'
  sl '{"timestamp":"2026-05-06T18:00:01Z","message":{"role":"toolResult","toolCallId":"c1","content":[{"type":"text","text":"Bram Fidder is somewhere"}]}}'

  run call_lib count_profile_api_evidence "Bram Fidder"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# ---------- allmusic fallback: hit ---------------------------------------

@test "allmusic_fallback: browser load to allmusic.com matching excerpt → 1" {
  sl '{"timestamp":"2026-05-06T18:00:00Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"b1","name":"browser","arguments":{"url":"https://www.allmusic.com/album/example-mw0000123"}}]}}'
  sl '{"timestamp":"2026-05-06T18:00:01Z","message":{"role":"toolResult","toolCallId":"b1","content":[{"type":"text","text":"AllMusic page text mentioning Bram Fidder as engineer"}]}}'

  run call_lib count_profile_allmusic_fallback "Bram Fidder"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

# ---------- allmusic fallback: non-fallback host → 0 ---------------------

@test "allmusic_fallback: musicbrainz browser load (Tier-1 but not allmusic) → 0" {
  sl '{"timestamp":"2026-05-06T18:00:00Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"b1","name":"browser","arguments":{"url":"https://musicbrainz.org/recording/abc"}}]}}'
  sl '{"timestamp":"2026-05-06T18:00:01Z","message":{"role":"toolResult","toolCallId":"b1","content":[{"type":"text","text":"Bram Fidder mastering"}]}}'

  run call_lib count_profile_allmusic_fallback "Bram Fidder"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# ---------- citation_domains stub returns 0 ------------------------------

@test "citation_domains: stub returns 0 (filled in step 4 of remove-browser plan)" {
  run call_lib count_profile_citation_domains "Bram Fidder"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# ---------- evidence_sources: sums all paths -----------------------------

@test "evidence_sources: api(1) + allmusic(1) + citations(0) = 2" {
  sl '{"timestamp":"2026-05-06T18:00:00Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"bash musicbrainz-isrc-lookup.sh USXX1"}}]}}'
  sl '{"timestamp":"2026-05-06T18:00:01Z","message":{"role":"toolResult","toolCallId":"c1","content":[{"type":"text","text":"{\"name_match\":true,\"evidence_excerpt\":\"Bram Fidder – mastering\"}"}]}}'
  sl '{"timestamp":"2026-05-06T18:00:02Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"b1","name":"browser","arguments":{"url":"https://allmusic.com/album/x"}}]}}'
  sl '{"timestamp":"2026-05-06T18:00:03Z","message":{"role":"toolResult","toolCallId":"b1","content":[{"type":"text","text":"AllMusic credits include Bram Fidder"}]}}'

  run call_lib count_profile_evidence_sources "Bram Fidder"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

# ---------- evidence_sources: empty excerpt → 0 --------------------------

@test "evidence_sources: empty excerpt → 0 (fail closed)" {
  run call_lib count_profile_evidence_sources ""
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# ---------- evidence_sources: no session log → 0 -------------------------

@test "evidence_sources: missing session log file → 0" {
  rm -f "$CV_SESSION_LOG"
  run call_lib count_profile_evidence_sources "Anything"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}
