#!/usr/bin/env bats
#
# Hermetic tests for fetch-conversation-attachments.sh. `curl` is PATH-stubbed
# to serve a fixture conversation JSON for the GET /conversations/<id> call
# and fixture binary bytes for CDN download URLs, dispatching on the
# requested URL. This lets us pin: structured + inline extraction and
# dedupe, the CDN host allowlist, magic-byte type detection with no `file`
# binary, per-download failure isolation, and the two failure exit paths
# (conversation GET failure, zero-of-N downloads).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  SCRIPT="$REPO_ROOT/skills-all/muso-intercom/scripts/fetch-conversation-attachments.sh"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures"
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/bin"
  OUT_DIR="$TMP/out"
  export CURL_CALLS="$TMP/curl.calls"
  export FIXTURES
  : >"$CURL_CALLS"

  cat >"$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Fake curl: dispatch on the requested URL. Honors -o <file> for output.
url=""
outfile=""
prev=""
for a in "$@"; do
  case "$prev" in
    -o) outfile="$a" ;;
  esac
  case "$a" in http://*|https://*) url="$a" ;; esac
  prev="$a"
done
printf 'call %s\n' "$url" >>"$CURL_CALLS"

case "$url" in
  *api.intercom.io/conversations/multi*)
    cp "$FIXTURES/conversation-multi.json" "$outfile"
    exit 0
    ;;
  *api.intercom.io/conversations/skiphost*)
    cp "$FIXTURES/conversation-skiphost.json" "$outfile"
    exit 0
    ;;
  *api.intercom.io/conversations/types*)
    cp "$FIXTURES/conversation-types.json" "$outfile"
    exit 0
    ;;
  *api.intercom.io/conversations/partial403*)
    cp "$FIXTURES/conversation-partial403.json" "$outfile"
    exit 0
    ;;
  *api.intercom.io/conversations/allfail*)
    cp "$FIXTURES/conversation-allfail.json" "$outfile"
    exit 0
    ;;
  *api.intercom.io/conversations/badresp*)
    printf 'not json' >"$outfile"
    exit 22
    ;;
  *api.intercom.io/conversations/empty*)
    cp "$FIXTURES/conversation-empty.json" "$outfile"
    exit 0
    ;;
  *musoai.intercom-attachments-3.com/a.png*)
    cp "$FIXTURES/sample.png" "$outfile"
    exit 0
    ;;
  *downloads.intercomcdn.com/b.jpg*)
    cp "$FIXTURES/sample.jpg" "$outfile"
    exit 0
    ;;
  *musoai.intercom-attachments-3.com/c.gif*)
    cp "$FIXTURES/sample.gif" "$outfile"
    exit 0
    ;;
  *downloads.intercomcdn.com/forbidden.jpg*)
    printf '403 forbidden' >"$outfile"
    exit 22
    ;;
  *musoai.intercom-attachments-3.com/ok1.png*)
    cp "$FIXTURES/sample.png" "$outfile"
    exit 0
    ;;
  *musoai.intercom-attachments-3.com/ok2.jpg*)
    cp "$FIXTURES/sample.jpg" "$outfile"
    exit 0
    ;;
  *musoai.intercom-attachments-3.com/fail1.png*)
    printf '403 forbidden' >"$outfile"
    exit 22
    ;;
  *musoai.intercom-attachments-3.com/fail2.jpg*)
    printf '403 forbidden' >"$outfile"
    exit 22
    ;;
  *musoai.intercom-attachments-3.com/type-png*)
    cp "$FIXTURES/sample.png" "$outfile"
    exit 0
    ;;
  *musoai.intercom-attachments-3.com/type-jpeg*)
    cp "$FIXTURES/sample.jpg" "$outfile"
    exit 0
    ;;
  *musoai.intercom-attachments-3.com/type-gif*)
    cp "$FIXTURES/sample.gif" "$outfile"
    exit 0
    ;;
  *musoai.intercom-attachments-3.com/type-webp*)
    cp "$FIXTURES/sample.webp" "$outfile"
    exit 0
    ;;
  *musoai.intercom-attachments-3.com/type-pdf*)
    cp "$FIXTURES/sample.pdf" "$outfile"
    exit 0
    ;;
  *musoai.intercom-attachments-3.com/type-unknown*)
    cp "$FIXTURES/sample.unknown" "$outfile"
    exit 0
    ;;
esac
exit 22
STUB
  chmod +x "$TMP/bin/curl"

  PATH="$TMP/bin:$PATH"
  export PATH
  export MUSOAI_INTERCOM_TOKEN=test-token
}

teardown() { rm -rf "$TMP"; }

calls() { grep -c '^call' "$CURL_CALLS"; }
called_url() { grep -qF "$1" "$CURL_CALLS"; }

# ---- case 1: structured (source + conversation_parts) + inline extraction --
@test "structured attachments (source + conversation_parts) plus inline img are all downloaded" {
  run bash "$SCRIPT" multi --out-dir "$OUT_DIR"
  [ "$status" -eq 0 ]

  # 3 candidates: source.attachments[0] (png), conversation_parts attachments[0] (gif),
  # inline <img> in a conversation_part body (jpg).
  [ "$(echo "$output" | grep -c '"path"')" -eq 3 ]

  called_url "musoai.intercom-attachments-3.com/a.png"
  called_url "downloads.intercomcdn.com/b.jpg"
  called_url "musoai.intercom-attachments-3.com/c.gif"

  echo "$output" | jq -e 'select(.detected_type == "png")' >/dev/null
  echo "$output" | jq -e 'select(.detected_type == "jpeg")' >/dev/null
  echo "$output" | jq -e 'select(.detected_type == "gif")' >/dev/null

  # manifest paths actually exist on disk with the right bytes
  while IFS= read -r line; do
    path="$(jq -r '.path' <<<"$line")"
    bytes="$(jq -r '.bytes' <<<"$line")"
    [ -f "$path" ]
    actual="$(wc -c <"$path" | tr -d ' ')"
    [ "$actual" -eq "$bytes" ]
  done <<<"$output"
}

# ---- case 2: non-allowlisted host is skipped -------------------------------
@test "non-allowlisted host is skipped with stderr note and no download" {
  run bash "$SCRIPT" skiphost --out-dir "$OUT_DIR"
  [ "$status" -eq 0 ]

  [[ "$output" == *"Skipping non-allowlisted attachment host"*"evil.example.com"* ]]
  ! called_url "evil.example.com"

  # the one allowlisted attachment in this fixture still downloads.
  [ "$(echo "$output" | grep -c '"path"')" -eq 1 ]
  called_url "musoai.intercom-attachments-3.com/ok1.png"
}

# ---- case 3: magic-byte detection ------------------------------------------
@test "magic-byte type detection covers png/jpeg/gif/webp/pdf/unknown" {
  run bash "$SCRIPT" types --out-dir "$OUT_DIR"
  [ "$status" -eq 0 ]

  for t in png jpeg gif webp pdf unknown; do
    echo "$output" | jq -e --arg t "$t" 'select(.detected_type == $t)' >/dev/null
  done
}

# ---- case 4: one CDN 403, others still succeed -----------------------------
@test "a CDN 403 on one URL is skipped, others still succeed, exit 0" {
  run bash "$SCRIPT" partial403 --out-dir "$OUT_DIR"
  [ "$status" -eq 0 ]

  [[ "$output" == *"Failed to download attachment"* ]]
  [ "$(echo "$output" | grep -c '"path"')" -eq 1 ]
  called_url "musoai.intercom-attachments-3.com/ok2.jpg"
}

# ---- case 5: all downloads fail --------------------------------------------
@test "all downloads failing exits non-zero" {
  run bash "$SCRIPT" allfail --out-dir "$OUT_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Failed to download any of"* ]]
}

# ---- case 6: missing token --------------------------------------------------
@test "missing MUSOAI_INTERCOM_TOKEN exits non-zero with a helpful message, curl never called" {
  unset MUSOAI_INTERCOM_TOKEN
  run bash "$SCRIPT" multi --out-dir "$OUT_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MUSOAI_INTERCOM_TOKEN"* ]]
  [ ! -s "$CURL_CALLS" ]
}

# ---- case 7: conversation GET failure --------------------------------------
@test "conversation GET non-2xx exits non-zero" {
  run bash "$SCRIPT" badresp --out-dir "$OUT_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Failed to fetch conversation"* ]]
}

# ---- bonus: no attachments in conversation ---------------------------------
@test "conversation with no attachments prints nothing and exits 0" {
  run bash "$SCRIPT" empty --out-dir "$OUT_DIR"
  [ "$status" -eq 0 ]
  [ -z "$(echo "$output" | grep '"path"' || true)" ]
}

# ---- usage / missing conversation_id ---------------------------------------
@test "missing conversation_id exits non-zero with usage" {
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
}
