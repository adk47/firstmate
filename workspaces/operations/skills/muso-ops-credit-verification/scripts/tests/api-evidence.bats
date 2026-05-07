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

# [removed 2026-05-07] allmusic_fallback test cases — count_profile_allmusic_fallback
# was removed from lib/api-evidence.sh when AllMusic went offline ("being
# updated") during the cutover test and we pivoted to native web_search
# exclusively. Browser is no longer a sanctioned source under api-mode.

# ---------- citation_domains: empty session → 0 --------------------------

@test "citation_domains: no assistant messages → 0" {
  run call_lib count_profile_citation_domains "Bram Fidder"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# ---------- citation_domains: inline URLs (gpt-5/gemini shape) -----------

@test "citation_domains: 2 distinct inline URLs in assistant text matching excerpt → 2" {
  # Assistant message with bare URLs in the text body — the typical
  # OpenRouter native-search output for gpt-5 / gemini models.
  sl '{"timestamp":"2026-05-07T10:00:00Z","message":{"role":"assistant","content":[{"type":"text","text":"According to https://example.com/credits/bram-fidder Bram Fidder is credited as mastering engineer; corroborated at https://other-source.org/index.html which lists Bram Fidder mastering on the same release."}]}}'

  run call_lib count_profile_citation_domains "Bram Fidder"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

# ---------- citation_domains: collapse www and dupes --------------------

@test "citation_domains: www.host and host count as 1; same host twice = 1" {
  sl '{"timestamp":"2026-05-07T10:00:00Z","message":{"role":"assistant","content":[{"type":"text","text":"Bram Fidder mastering credit found at https://www.example.com/a and confirmed at https://example.com/b plus https://example.com/c"}]}}'

  run call_lib count_profile_citation_domains "Bram Fidder"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

# ---------- citation_domains: structured citations field (claude shape) ---

@test "citation_domains: structured citations[] on text content block → counted" {
  # OpenRouter passes claude-style citations as a per-block array.
  sl '{"timestamp":"2026-05-07T10:00:00Z","message":{"role":"assistant","content":[{"type":"text","text":"Confirmed: Bram Fidder mastering credit on the release.","citations":[{"url":"https://citelib1.com/page","title":"Credit listing"},{"url":"https://citelib2.org/page","title":"Confirmation"}]}]}}'

  run call_lib count_profile_citation_domains "Bram Fidder"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

# ---------- citation_domains: top-level message.citations[] --------------

@test "citation_domains: top-level message.citations[] (alt shape) → counted" {
  # Some OpenRouter routes put citations at message-level instead of per-block.
  sl '{"timestamp":"2026-05-07T10:00:00Z","message":{"role":"assistant","content":[{"type":"text","text":"Bram Fidder mastering confirmed."}],"citations":[{"url":"https://topcite1.com/p"},{"url":"https://topcite2.net/p"}]}}'

  run call_lib count_profile_citation_domains "Bram Fidder"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

# ---------- citation_domains: excerpt not present → 0 (fail closed) ------

@test "citation_domains: URLs present but excerpt missing → 0" {
  # The model talked about something else entirely with citations. Must
  # not count those as evidence for OUR excerpt.
  sl '{"timestamp":"2026-05-07T10:00:00Z","message":{"role":"assistant","content":[{"type":"text","text":"Some unrelated topic at https://a.com and https://b.com"}]}}'

  run call_lib count_profile_citation_domains "Bram Fidder"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# ---------- citation_domains: trailing punctuation stripped --------------

@test "citation_domains: URL trailing comma/period/paren stripped from host" {
  sl '{"timestamp":"2026-05-07T10:00:00Z","message":{"role":"assistant","content":[{"type":"text","text":"Bram Fidder mastering credit (see https://citehost.com/x), and https://citehost.com/y."}]}}'

  run call_lib count_profile_citation_domains "Bram Fidder"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

# ---------- evidence_sources: citation_domains feeds the sum -------------

@test "evidence_sources: api(1) + citations(2) = 3 (citation path now active)" {
  sl '{"timestamp":"2026-05-07T10:00:00Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"exec","arguments":{"command":"bash musicbrainz-isrc-lookup.sh USXX1"}}]}}'
  sl '{"timestamp":"2026-05-07T10:00:01Z","message":{"role":"toolResult","toolCallId":"c1","content":[{"type":"text","text":"{\"name_match\":true,\"evidence_excerpt\":\"Bram Fidder – mastering\"}"}]}}'
  sl '{"timestamp":"2026-05-07T10:00:02Z","message":{"role":"assistant","content":[{"type":"text","text":"After MB miss I checked the web. Bram Fidder mastering corroborated at https://citelib1.com/p and https://citelib2.org/p"}]}}'

  run call_lib count_profile_evidence_sources "Bram Fidder"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

# ---------- evidence_sources: sums api + citations (allmusic removed) ----

@test "evidence_sources: api(1) + citations(1) = 2 (the canonical 2-source quorum)" {
  # The canonical Tier-1+Tier-2 approval pattern: 1 MB API hit + 1 web
  # citation domain. AllMusic browser fallback was removed 2026-05-07.
  sl '{"timestamp":"2026-05-07T10:00:00Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"exec","arguments":{"command":"bash musicbrainz-isrc-lookup.sh USXX1"}}]}}'
  sl '{"timestamp":"2026-05-07T10:00:01Z","message":{"role":"toolResult","toolCallId":"c1","content":[{"type":"text","text":"{\"name_match\":true,\"evidence_excerpt\":\"Bram Fidder mastering\"}"}]}}'
  sl '{"timestamp":"2026-05-07T10:00:02Z","message":{"role":"assistant","content":[{"type":"text","text":"Bram Fidder mastering corroborated at https://vuproductions.gr/about-us"}]}}'

  run call_lib count_profile_evidence_sources "Bram Fidder mastering"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "evidence_sources: AllMusic browser load no longer counts (post-removal)" {
  # Defensive regression test: even if the agent loads AllMusic, that
  # browser load is no longer a sanctioned evidence source under api-mode.
  # Without an MB API hit or web citation, the count is 0.
  sl '{"timestamp":"2026-05-07T10:00:00Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"b1","name":"browser","arguments":{"url":"https://www.allmusic.com/x"}}]}}'
  sl '{"timestamp":"2026-05-07T10:00:01Z","message":{"role":"toolResult","toolCallId":"b1","content":[{"type":"text","text":"AllMusic credits include Bram Fidder mastering"}]}}'

  run call_lib count_profile_evidence_sources "Bram Fidder mastering"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
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

# ---------- regression: openclaw's live tool name is "exec" --------------

@test "api_evidence: tool name 'exec' (openclaw live) is recognized as a helper invocation" {
  # 2026-05-07: production session JSONLs from openclaw 2026.5.5 stamp the
  # shell tool as "exec", not "bash". The first deployed batch
  # 20260506-202031-675159 had the agent call helpers via "exec", and the
  # api-evidence library counted 0 sources because it filtered on "bash"
  # only. Both are accepted now to keep test fixtures portable, with
  # "exec" being the production-truth name.
  sl '{"timestamp":"2026-05-07T08:00:00Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"e1","name":"exec","arguments":{"command":"bash /opt/hydra/workspaces/operations/skills/muso-ops-credit-verification/scripts/musicbrainz-isrc-lookup.sh USXX1 --credited-name \"Bram Fidder\""}}]}}'
  sl '{"timestamp":"2026-05-07T08:00:01Z","message":{"role":"toolResult","toolCallId":"e1","content":[{"type":"text","text":"{\"name_match\":true,\"evidence_excerpt\":\"Bram Fidder – mastering\"}"}]}}'

  run call_lib count_profile_api_evidence "Bram Fidder"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}
