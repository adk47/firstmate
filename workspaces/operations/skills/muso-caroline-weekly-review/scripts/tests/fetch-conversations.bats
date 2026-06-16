#!/usr/bin/env bats
load helpers

setup() {
  setup_skill_tmp
  install_router
  # Per-part timestamps drive the rolling-window scope in step 3. NOW is safely
  # inside the window; OLD is far outside it (a stale reply from a recently-bumped
  # thread) -- excluded under both the 30h default and a 168h override. Set here so
  # fixtures can interpolate them.
  NOW=$(date +%s)
  OLD=$(( NOW - 30 * 86400 ))
}
teardown() { teardown_skill_tmp; }

# Routing curl stub: POST /conversations/search returns a candidate list
# (search-$N.json by call count, else search.json); GET /conversations/{id}
# returns conv-$id.json. Mirrors the real two-step flow: search gives IDs with
# NO parts, the per-id GET gives the full transcript.
install_router() {
  cat > "$TEST_TMPDIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %q\n' "$*" >> "${TEST_TMPDIR}/curl.calls"
HEADERS_FILE=""; BODY_FILE=""; URL=""
args=("$@")
for i in "${!args[@]}"; do
  case "${args[$i]}" in
    -D) HEADERS_FILE="${args[$((i+1))]}" ;;
    -o) BODY_FILE="${args[$((i+1))]}" ;;
    https://*) URL="${args[$i]}" ;;
  esac
done
write_headers() { [ -n "$HEADERS_FILE" ] && printf "%b" "$1" > "$HEADERS_FILE"; }
emit() { if [ -n "$BODY_FILE" ]; then cat > "$BODY_FILE"; else cat; fi; }

# One-shot connect-level failure (no headers written), if armed — simulates a
# transient DNS/TLS/connect blip: curl exits non-zero and leaves the header file
# empty. The helper must retry, not abort under set -e+pipefail at status=.
if [ -f "${TEST_TMPDIR}/force-connect-fail-once" ]; then
  rm -f "${TEST_TMPDIR}/force-connect-fail-once"
  exit 6
fi

# One-shot 429 WITHOUT a Retry-After header on the first search, if armed —
# exercises the exponential-backoff fallback (the wait= grep no-match must not
# abort under set -e before the [ -z "$wait" ] default).
if [[ "$URL" == *"/conversations/search"* && -f "${TEST_TMPDIR}/force-429-no-ra-search" ]]; then
  rm -f "${TEST_TMPDIR}/force-429-no-ra-search"
  write_headers "HTTP/1.1 429 Too Many Requests\r\n\r\n"
  echo "rate limited" | emit
  exit 0
fi

# One-shot 429 on the first per-id GET, if armed.
if [[ "$URL" == *"/conversations/"* && "$URL" != *"/search"* && -f "${TEST_TMPDIR}/force-429-get" ]]; then
  rm -f "${TEST_TMPDIR}/force-429-get"
  write_headers "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 1\r\n\r\n"
  echo "rate limited" | emit
  exit 22
fi

write_headers "HTTP/1.1 200 OK\r\n"
if [[ "$URL" == *"/conversations/search"* ]]; then
  if [ -f "${TEST_TMPDIR}/force-search-status" ]; then
    write_headers "HTTP/1.1 $(cat "${TEST_TMPDIR}/force-search-status") ERR\r\n"
    echo '{}' | emit
    exit 0
  fi
  N=$(cat "${TEST_TMPDIR}/search.counter" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "${TEST_TMPDIR}/search.counter"
  if [ -f "${TEST_TMPDIR}/search-$N.json" ]; then cat "${TEST_TMPDIR}/search-$N.json" | emit
  else cat "${TEST_TMPDIR}/search.json" 2>/dev/null | emit; fi
elif [[ "$URL" == *"/conversations/"* ]]; then
  id="${URL##*/conversations/}"; id="${id%%\?*}"
  if [ -f "${TEST_TMPDIR}/conv-$id.json" ]; then cat "${TEST_TMPDIR}/conv-$id.json" | emit
  else echo '{}' | emit; fi
fi
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/curl"
}

search_one() {  # $1 = id, $2 = updated_at
  cat > "$TEST_TMPDIR/search.json" <<EOF
{"type":"conversation.list","conversations":[{"id":"$1","updated_at":${2:-1000}}],"pages":{"next":null}}
EOF
}

@test "captures a Caroline-authored conversation whose parts are absent from the search response (GET-by-id)" {
  # The real failure mode: search returns the id + source but an EMPTY parts
  # array; the transcript (and Caroline's admin reply) only come from the GET.
  search_one c1 1000
  cat > "$TEST_TMPDIR/conv-c1.json" <<EOF
{"id":"c1","contact_id":"x1","customer":{"email":"a@x","name":"Jane Doe"},
 "source":{"author":{"type":"user","id":"x1","name":"Jane Doe"},"body":"how do I export?"},
 "conversation_parts":{"conversation_parts":[
   {"author":{"type":"admin","id":"caroline-admin-123"},"body":"here is how","created_at":$NOW}
 ]}}
EOF
  run "$SCRIPTS_DIR/fetch-conversations.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/conversations.jsonl")" -eq 1 ]
  [ "$(jq -r '.id' "$WORKDIR/conversations.jsonl")" = "c1" ]
}

@test "excludes a conversation Caroline did not author" {
  search_one c1 1000
  cat > "$TEST_TMPDIR/conv-c1.json" <<'EOF'
{"id":"c1","conversation_parts":{"conversation_parts":[
  {"author":{"type":"admin","id":"jan-human-999"},"body":"human reply"}
]}}
EOF
  run "$SCRIPTS_DIR/fetch-conversations.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/conversations.jsonl" 2>/dev/null || echo 0)" -eq 0 ]
}

@test "captures the customer opener from .source" {
  search_one c1 1000
  cat > "$TEST_TMPDIR/conv-c1.json" <<EOF
{"id":"c1","customer":{"email":"a@x"},
 "source":{"author":{"type":"user","id":"x1"},"body":"How do I export FLAC?"},
 "conversation_parts":{"conversation_parts":[
   {"author":{"type":"admin","id":"caroline-admin-123"},"body":"Here is how","created_at":$NOW}
 ]}}
EOF
  run "$SCRIPTS_DIR/fetch-conversations.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.parts[0].body' "$WORKDIR/conversations.jsonl")" = "How do I export FLAC?" ]
}

@test "derives customer name from .source.author.name when .customer is absent" {
  search_one c1 1000
  cat > "$TEST_TMPDIR/conv-c1.json" <<EOF
{"id":"c1","contact_id":"x1",
 "source":{"author":{"type":"user","id":"x1","name":"Jane Doe"},"body":"help"},
 "conversation_parts":{"conversation_parts":[
   {"author":{"type":"admin","id":"caroline-admin-123"},"body":"sure","created_at":$NOW}
 ]}}
EOF
  run "$SCRIPTS_DIR/fetch-conversations.sh"
  [ "$status" -eq 0 ]
  line=$(cat "$WORKDIR/conversations.jsonl")
  [ "$(printf '%s' "$line" | jq -r '.customer_first_name')" = "Jane" ]
  [ "$(printf '%s' "$line" | jq -r '.customer_last_name')" = "Doe" ]
}

@test "search query is broad updated_at (no admin_assignee_id server-side filter)" {
  search_one c1 1000
  cat > "$TEST_TMPDIR/conv-c1.json" <<EOF
{"id":"c1","conversation_parts":{"conversation_parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"hi","created_at":$NOW}]}}
EOF
  run "$SCRIPTS_DIR/fetch-conversations.sh"
  [ "$status" -eq 0 ]
  ! grep -q "admin_assignee_id" "$TEST_TMPDIR/curl.calls"
}

@test "follows search pagination across pages" {
  cat > "$TEST_TMPDIR/search-1.json" <<'EOF'
{"type":"conversation.list","conversations":[{"id":"c1","updated_at":1000}],"pages":{"next":{"starting_after":"cur2"}}}
EOF
  cat > "$TEST_TMPDIR/search-2.json" <<'EOF'
{"type":"conversation.list","conversations":[{"id":"c2","updated_at":900}],"pages":{"next":null}}
EOF
  for id in c1 c2; do
    cat > "$TEST_TMPDIR/conv-$id.json" <<EOF
{"id":"$id","conversation_parts":{"conversation_parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"hi","created_at":$NOW}]}}
EOF
  done
  run "$SCRIPTS_DIR/fetch-conversations.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/conversations.jsonl")" -eq 2 ]
}

@test "samples CAP candidates evenly across the window (keeps both endpoints, drops the middle) and logs it" {
  # Even-spread sampling, NOT recency truncation. With cap=2 over old/mid/new the
  # spread picks indices 0 and n-1, so the OLDEST (old) is kept alongside the
  # newest — the property that fixes the weekly digest's recency blindness
  # (2026-06-15: 602 candidates, the old "200 most-recent" dropped the oldest 402,
  # so Mon–Wed were invisible). The middle candidate is the one dropped.
  export CAROLINE_FETCH_CAP=2
  cat > "$TEST_TMPDIR/search.json" <<'EOF'
{"type":"conversation.list","conversations":[
  {"id":"old","updated_at":100},{"id":"mid","updated_at":200},{"id":"new","updated_at":300}
],"pages":{"next":null}}
EOF
  for id in old mid new; do
    cat > "$TEST_TMPDIR/conv-$id.json" <<EOF
{"id":"$id","conversation_parts":{"conversation_parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"hi","created_at":$NOW}]}}
EOF
  done
  run "$SCRIPTS_DIR/fetch-conversations.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/conversations.jsonl")" -eq 2 ]
  [[ "$output" == *"WARN"* ]]
  [[ "$output" == *"sampled 2 evenly"* ]]
  grep -q "/conversations/old" "$TEST_TMPDIR/curl.calls"   # oldest endpoint kept (anti-recency-bias)
  grep -q "/conversations/new" "$TEST_TMPDIR/curl.calls"   # newest endpoint kept
  ! grep -q "/conversations/mid" "$TEST_TMPDIR/curl.calls" # middle dropped
}

@test "even-spread sampling spans the full window (5 candidates, cap 3 -> indices 0,2,4)" {
  # Pins the floor(i*(n-1)/(cap-1)) spread: 5 sorted candidates at cap 3 keep the
  # 1st, 3rd, and 5th (full-window coverage), dropping the 2nd and 4th.
  export CAROLINE_FETCH_CAP=3
  cat > "$TEST_TMPDIR/search.json" <<'EOF'
{"type":"conversation.list","conversations":[
  {"id":"t100","updated_at":100},{"id":"t200","updated_at":200},{"id":"t300","updated_at":300},
  {"id":"t400","updated_at":400},{"id":"t500","updated_at":500}
],"pages":{"next":null}}
EOF
  for id in t100 t200 t300 t400 t500; do
    cat > "$TEST_TMPDIR/conv-$id.json" <<EOF
{"id":"$id","conversation_parts":{"conversation_parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"hi","created_at":$NOW}]}}
EOF
  done
  run "$SCRIPTS_DIR/fetch-conversations.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/conversations.jsonl")" -eq 3 ]
  for keep in t100 t300 t500; do grep -q "/conversations/$keep" "$TEST_TMPDIR/curl.calls"; done
  for drop in t200 t400; do ! grep -q "/conversations/$drop" "$TEST_TMPDIR/curl.calls"; done
}

@test "fails loud when search returns a non-2xx status (no silent empty week)" {
  search_one c1 1000
  echo "403" > "$TEST_TMPDIR/force-search-status"
  run "$SCRIPTS_DIR/fetch-conversations.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"HTTP 403"* ]]
}

@test "honors Retry-After on a 429 during a per-id GET" {
  search_one c1 1000
  cat > "$TEST_TMPDIR/conv-c1.json" <<EOF
{"id":"c1","conversation_parts":{"conversation_parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"hi","created_at":$NOW}]}}
EOF
  : > "$TEST_TMPDIR/force-429-get"
  run "$SCRIPTS_DIR/fetch-conversations.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/conversations.jsonl")" -eq 1 ]
}

@test "retries (does not abort) when curl fails at connect with no headers written" {
  # Regression: under set -e+pipefail, an empty header file made the status= grep
  # exit non-zero and abort the helper before the rc!=0 retry branch, turning a
  # transient DNS/TLS/connect blip into a hard single-attempt failure.
  search_one c1 1000
  cat > "$TEST_TMPDIR/conv-c1.json" <<EOF
{"id":"c1","conversation_parts":{"conversation_parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"hi","created_at":$NOW}]}}
EOF
  : > "$TEST_TMPDIR/force-connect-fail-once"   # first request connect-fails, no headers
  run "$SCRIPTS_DIR/fetch-conversations.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/conversations.jsonl")" -eq 1 ]
  # proof it actually retried: more than one search POST was issued
  [ "$(grep -c '/conversations/search' "$TEST_TMPDIR/curl.calls")" -ge 2 ]
}

@test "falls back to backoff on a 429 with no Retry-After header (does not abort)" {
  # Same defect class on the wait= extraction: a 429 may omit the optional
  # Retry-After header, so the grep no-matches; without `|| true` it aborts under
  # set -e before the [ -z "$wait" ] exponential-backoff fallback.
  search_one c1 1000
  cat > "$TEST_TMPDIR/conv-c1.json" <<EOF
{"id":"c1","conversation_parts":{"conversation_parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"hi","created_at":$NOW}]}}
EOF
  : > "$TEST_TMPDIR/force-429-no-ra-search"   # first search 429s with NO Retry-After
  run "$SCRIPTS_DIR/fetch-conversations.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/conversations.jsonl")" -eq 1 ]
}

@test "drops a conversation bumped recently whose only Caroline reply is pre-window" {
  # The thread is a search candidate (updated_at recent) because a customer
  # bumped it recently, but Caroline's only reply predates the window.
  # Grading it would re-grade a stale reply and inflate repeated-question
  # clusters with an old question — so it must be dropped, not graded.
  search_one c1 1000
  cat > "$TEST_TMPDIR/conv-c1.json" <<EOF
{"id":"c1","contact_id":"x1","created_at":$OLD,
 "source":{"author":{"type":"user","id":"x1"},"body":"old question"},
 "conversation_parts":{"conversation_parts":[
   {"author":{"type":"admin","id":"caroline-admin-123"},"body":"stale reply","created_at":$OLD},
   {"author":{"type":"user","id":"x1"},"body":"bumping this thread","created_at":$NOW}
 ]}}
EOF
  run "$SCRIPTS_DIR/fetch-conversations.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/conversations.jsonl" 2>/dev/null || echo 0)" -eq 0 ]
}

@test "keeps an in-window Caroline reply but trims her pre-window parts from the same thread" {
  # Caroline replied in-window (kept) but also replied long ago in the same
  # thread. The stale reply must not reach the grader as in-window voice
  # evidence; the customer's opener stays as the question-context anchor.
  search_one c1 1000
  cat > "$TEST_TMPDIR/conv-c1.json" <<EOF
{"id":"c1","contact_id":"x1","created_at":$OLD,
 "source":{"author":{"type":"user","id":"x1"},"body":"how do I export?"},
 "conversation_parts":{"conversation_parts":[
   {"author":{"type":"admin","id":"caroline-admin-123"},"body":"STALE","created_at":$OLD},
   {"author":{"type":"admin","id":"caroline-admin-123"},"body":"FRESH","created_at":$NOW}
 ]}}
EOF
  run "$SCRIPTS_DIR/fetch-conversations.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/conversations.jsonl")" -eq 1 ]
  line=$(cat "$WORKDIR/conversations.jsonl")
  # source opener kept as context anchor
  [ "$(printf '%s' "$line" | jq -r '.parts[0].body')" = "how do I export?" ]
  # in-window reply present, pre-window reply trimmed
  printf '%s' "$line" | grep -q '"body":"FRESH"'
  ! printf '%s' "$line" | grep -q '"body":"STALE"'
}

@test "normalizes null/absent conversation_part body to empty string (not null)" {
  # Intercom note/system parts can carry a null (or absent) body. If that null
  # reaches the grader, an LLM-composed (.body|test(...)) errors ("null cannot be
  # matched") and aborts the whole run — the 2026-06-03 proof-run failure. Every
  # emitted part body must be a string.
  search_one c1 1000
  cat > "$TEST_TMPDIR/conv-c1.json" <<EOF
{"id":"c1","contact_id":"x1",
 "source":{"author":{"type":"user","id":"x1"},"body":"how do I export?"},
 "conversation_parts":{"conversation_parts":[
   {"author":{"type":"admin","id":"caroline-admin-123"},"body":"sure","created_at":$NOW},
   {"author":{"type":"user","id":"x1"},"body":null,"created_at":$NOW},
   {"author":{"type":"user","id":"x1"},"created_at":$NOW}
 ]}}
EOF
  run "$SCRIPTS_DIR/fetch-conversations.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/conversations.jsonl")" -eq 1 ]
  # every emitted part body is a string (null/absent -> "")
  jq -e '[.parts[].body] | all(type == "string")' "$WORKDIR/conversations.jsonl"
  # the exact grader pattern that crashed in the proof-run now runs without error
  run jq -r 'select(any(.parts[]; (.body|test("—")))) | .id' "$WORKDIR/conversations.jsonl"
  [ "$status" -eq 0 ]
}

@test "default window is 30h: keeps a part at NOW-20h, drops one at NOW-40h" {
  # The daily pulse default. NEW per-part offsets (not the shared $OLD=NOW-720h,
  # which is excluded even at a 168h override and so cannot prove the boundary).
  search_one c1 1000
  cat > "$TEST_TMPDIR/conv-c1.json" <<EOF
{"id":"c1","contact_id":"x1",
 "source":{"author":{"type":"user","id":"x1"},"body":"how do I export?"},
 "conversation_parts":{"conversation_parts":[
   {"author":{"type":"admin","id":"caroline-admin-123"},"body":"INWINDOW","created_at":$(( NOW - 20 * 3600 ))},
   {"author":{"type":"admin","id":"caroline-admin-123"},"body":"PREWINDOW","created_at":$(( NOW - 40 * 3600 ))}
 ]}}
EOF
  run "$SCRIPTS_DIR/fetch-conversations.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/conversations.jsonl")" -eq 1 ]
  line=$(cat "$WORKDIR/conversations.jsonl")
  printf '%s' "$line" | grep -q '"body":"INWINDOW"'
  ! printf '%s' "$line" | grep -q '"body":"PREWINDOW"'
}

@test "30h window boundary pins at 30h: NOW-29h kept, NOW-31h dropped (guards a 24h/7d regression)" {
  search_one c1 1000
  cat > "$TEST_TMPDIR/conv-c1.json" <<EOF
{"id":"c1","contact_id":"x1",
 "source":{"author":{"type":"user","id":"x1"},"body":"q"},
 "conversation_parts":{"conversation_parts":[
   {"author":{"type":"admin","id":"caroline-admin-123"},"body":"KEPT29","created_at":$(( NOW - 29 * 3600 ))},
   {"author":{"type":"admin","id":"caroline-admin-123"},"body":"DROP31","created_at":$(( NOW - 31 * 3600 ))}
 ]}}
EOF
  run "$SCRIPTS_DIR/fetch-conversations.sh"
  [ "$status" -eq 0 ]
  line=$(cat "$WORKDIR/conversations.jsonl")
  printf '%s' "$line" | grep -q '"body":"KEPT29"'
  ! printf '%s' "$line" | grep -q '"body":"DROP31"'
}

@test "CAROLINE_WINDOW_HOURS override widens the window (168h keeps a part at NOW-100h)" {
  # SP2's weekly KB roll-up sets this inline. NOW-100h is excluded under the 30h
  # default but included at 168h, proving the knob is honored.
  export CAROLINE_WINDOW_HOURS=168
  search_one c1 1000
  cat > "$TEST_TMPDIR/conv-c1.json" <<EOF
{"id":"c1","contact_id":"x1",
 "source":{"author":{"type":"user","id":"x1"},"body":"q"},
 "conversation_parts":{"conversation_parts":[
   {"author":{"type":"admin","id":"caroline-admin-123"},"body":"WEEKOLD","created_at":$(( NOW - 100 * 3600 ))}
 ]}}
EOF
  run "$SCRIPTS_DIR/fetch-conversations.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/conversations.jsonl")" -eq 1 ]
  printf '%s' "$(cat "$WORKDIR/conversations.jsonl")" | grep -q '"body":"WEEKOLD"'
}
