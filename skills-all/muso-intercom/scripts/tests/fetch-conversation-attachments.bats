#!/usr/bin/env bats
#
# Hermetic tests for fetch-conversation-attachments.sh. `curl` is PATH-stubbed
# to serve a fixture conversation JSON for the GET /conversations/<id> call
# and fixture binary bytes for CDN download URLs, dispatching on the
# requested URL. This lets us pin: structured + inline extraction and
# dedupe, the CDN host allowlist, magic-byte type detection with no `file`
# binary, per-download failure isolation, and the two failure exit paths
# (conversation GET failure, zero-of-N downloads).
#
# HEIC coverage uses a REAL fixture: fixtures/sample.heic was produced by macOS
# `sips -s format heic` and is a genuine Apple-encoded ISO-BMFF file carrying 5
# items (a `grid` derived image plus its 4 tiles, with an `iref`) -- i.e. the
# multi-image shape that makes libheif's heif-convert write `<base>-1.jpg`
# instead of the output path it was handed. `heif-convert` itself is stubbed via
# INTERCOM_HEIF_CONVERT_BIN so CI never depends on libheif being installed;
# install_heif_stub <mode> picks the behavior.

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
  *api.intercom.io/conversations/heicbad*)
    cp "$FIXTURES/conversation-heic-bad.json" "$outfile"
    exit 0
    ;;
  *api.intercom.io/conversations/heic*)
    cp "$FIXTURES/conversation-heic.json" "$outfile"
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
  *musoai.intercom-attachments-3.com/IMG_0042.heic*)
    cp "$FIXTURES/sample.heic" "$outfile"
    exit 0
    ;;
  *musoai.intercom-attachments-3.com/broken.heic*)
    # First 6 bytes of a real HEIC: enough to look like a file, too short to
    # carry a complete ftyp box -- detects as `unknown`, not `heic`.
    head -c 6 "$FIXTURES/sample.heic" >"$outfile"
    exit 0
    ;;
esac
exit 22
STUB
  chmod +x "$TMP/bin/curl"

  PATH="$TMP/bin:$PATH"
  export PATH
  export MUSOAI_INTERCOM_TOKEN=test-token
  # Default: no transcoder available. Individual tests opt in via
  # install_heif_stub, so the degraded path is what you get unless you ask.
  export INTERCOM_HEIF_CONVERT_BIN="$TMP/bin/definitely-not-heif-convert"
}

# Install a fake heif-convert. The mode is baked into the script rather than
# read from the environment: `VAR=x run ...` is not reliably delivered to a
# PATH stub under bats, and a stub that silently picks the wrong mode would
# make a real failure look like a pass.
#
#   multi  -- ignores the requested <out> and writes <base>-1.jpg + <base>-2.jpg,
#             which is what real libheif does for a multi-image (tiled/auxiliary)
#             Apple HEIC. This is the naming trap the script must survive.
#   single -- writes exactly the requested <out>.jpg
#   fail   -- exits non-zero (corrupt input / unsupported feature)
#   hang   -- sleeps far past the transcode timeout without ever writing output,
#             which is what a crafted or pathological HEIC does to libheif. The
#             script must kill it, not wait.
#   huge   -- exits 0 with a VALID JPEG that is larger than the derived-output
#             cap. The conversion WORKED; the result simply does not fit. This is
#             the decompression-bomb shape: a sub-10MB HEIC that expands, so the
#             download cap upstream never sees it coming.
# The optional second argument tags the bytes this stub writes, so a test that
# runs the script twice can tell WHICH run's image it got back. Comparing
# filenames would not: the whole point of the rerun bug is that the stale file
# and the fresh one can wear the same name.
install_heif_stub() {
  local mode="$1" marker="${2:-}"
  cat >"$TMP/bin/heif-convert" <<STUB
#!/usr/bin/env bash
out=""
for a in "\$@"; do out="\$a"; done
base="\${out%.jpg}"
case "$mode" in
  multi)
    printf 'JPEG-PRIMARY$marker' > "\${base}-1.jpg"
    printf 'JPEG-AUX$marker' > "\${base}-2.jpg"
    ;;
  single) printf 'JPEG-SINGLE$marker' > "\$out" ;;
  fail) echo "heif-convert: unsupported feature" >&2; exit 1 ;;
  hang) sleep 10 ;;
  huge)
    printf 'JPEG-HUGE$marker' > "\$out"
    dd if=/dev/zero bs=1024 count=10241 >> "\$out" 2>/dev/null
    ;;
esac
exit 0
STUB
  chmod +x "$TMP/bin/heif-convert"
  export INTERCOM_HEIF_CONVERT_BIN="$TMP/bin/heif-convert"
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

# ---- path-traversal guard on conversation_id -------------------------------
@test "conversation_id with path separators is rejected before any fetch" {
  run bash "$SCRIPT" "../../etc/evil" --out-dir "$OUT_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Invalid conversation_id"* ]]
  # rejected before the token check and before curl -- nothing was fetched.
  [ ! -s "$CURL_CALLS" ]
}

# ---- HEIC: detected as ISO-BMFF and normalized to JPEG ---------------------
@test "a genuine multi-image Apple HEIC is detected and transcoded to jpeg" {
  # WHY: the ClickUp UVN evidence set was 18 real Apple HEICs. detect_type()
  # only knew png/jpeg/gif/pdf/webp, so every one of them fell through to
  # `unknown`, was saved with a .unknown extension, and never converted --
  # which is how an 18-file evidence set produced empty OCR.
  install_heif_stub multi
  run bash "$SCRIPT" heic --out-dir "$OUT_DIR"
  [ "$status" -eq 0 ]

  echo "$output" | jq -e 'select(.detected_type == "jpeg")' >/dev/null
  echo "$output" | jq -e 'select(.converted_from == "heic")' >/dev/null
  # No `unreadable` marker on a successful transcode.
  run_out="$output"
  [ "$(echo "$run_out" | jq -r '.unreadable // "absent"')" = "absent" ]

  # heif-convert wrote out-1.jpg (multi-image naming) inside the private
  # conversion dir, NOT the out.jpg we asked for -- predicting the name would
  # have yielded "no output" here. The primary is then promoted to the
  # canonical <idx>.jpg, so callers never see libheif's naming.
  path="$(echo "$run_out" | jq -r '.path')"
  [[ "$path" == *"/1.jpg" ]]
  [ -s "$path" ]
  # The auxiliary sibling and the work dir are gone: only the original and the
  # one JPEG we chose remain for a later run to trip over.
  [ "$(ls "$OUT_DIR" | sort | tr '\n' ' ')" = "1.heic 1.jpg " ]

  # The original HEIC is preserved next to it so a human can re-inspect.
  original="$(echo "$run_out" | jq -r '.original_path')"
  [[ "$original" == *.heic ]]
  [ -s "$original" ]
}

@test "a single-image HEIC transcode keeps the exact requested output name" {
  install_heif_stub single
  run bash "$SCRIPT" heic --out-dir "$OUT_DIR"
  [ "$status" -eq 0 ]
  path="$(echo "$output" | jq -r '.path')"
  [[ "$path" == *"/1.jpg" ]]
  [ -s "$path" ]
}

# ---- single-extension naming (the `.heic.heic` question) -------------------
@test "downloaded files carry exactly one extension, never .heic.heic" {
  # The `.heic.heic` names Ops saw came from uncommitted scratch scripts, NOT
  # from this helper: naming here has always been `<idx>.<detected_type>`.
  # Pinned so it stays that way.
  install_heif_stub multi
  run bash "$SCRIPT" heic --out-dir "$OUT_DIR"
  [ "$status" -eq 0 ]
  for f in "$OUT_DIR"/*; do
    base="$(basename "$f")"
    # exactly one dot in every produced filename
    [ "$(echo "$base" | tr -cd '.' | wc -c | tr -d ' ')" -eq 1 ]
    [[ "$base" != *.heic.heic ]]
  done
}

# ---- HEIC degraded: transcoder missing -------------------------------------
@test "missing heif-convert keeps the original HEIC and emits an unreadable marker" {
  # WHY: silence is the bug. Without an explicit marker the sweeper cannot tell
  # "no attachment" from "we could not decode this attachment", and Ops ends up
  # reporting "corrupt evidence" on evidence that was never decoded.
  # INTERCOM_HEIF_CONVERT_BIN already points at a nonexistent path in setup().
  run bash "$SCRIPT" heic --out-dir "$OUT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"heif-convert not found"* ]]

  line="$(echo "$output" | grep '"path"')"
  [ "$(echo "$line" | jq -r '.detected_type')" = heic ]
  [ "$(echo "$line" | jq -r '.unreadable')" = true ]
  # NOT heic_decode_failed: nothing ever opened the payload, so this says
  # nothing about the customer's file. It is a node-8 provisioning fault.
  [ "$(echo "$line" | jq -r '.unreadable_reason')" = pipeline_failed ]
  path="$(echo "$line" | jq -r '.path')"
  [[ "$path" == *.heic ]]
  [ -s "$path" ]
}

@test "a failing heif-convert keeps the original HEIC and emits an unreadable marker" {
  install_heif_stub fail
  run bash "$SCRIPT" heic --out-dir "$OUT_DIR"
  [ "$status" -eq 0 ]
  line="$(echo "$output" | grep '"path"')"
  [ "$(echo "$line" | jq -r '.unreadable_reason')" = heic_decode_failed ]
}

# ---- unrecognized bytes also get an explicit marker ------------------------
@test "truncated/unrecognized bytes are reported unreadable, not silently saved" {
  install_heif_stub multi
  run bash "$SCRIPT" heicbad --out-dir "$OUT_DIR"
  [ "$status" -eq 0 ]
  line="$(echo "$output" | grep '"path"')"
  [ "$(echo "$line" | jq -r '.detected_type')" = unknown ]
  [ "$(echo "$line" | jq -r '.unreadable')" = true ]
  [ "$(echo "$line" | jq -r '.unreadable_reason')" = corrupt_or_unrecognized ]
}

# ---- readable types carry NO unreadable marker -----------------------------
@test "png/jpeg/gif/webp/pdf lines carry no unreadable marker" {
  # The marker must mean something: if everything carried it, the doctrine that
  # keys on it would be worthless.
  run bash "$SCRIPT" types --out-dir "$OUT_DIR"
  [ "$status" -eq 0 ]
  while IFS= read -r line; do
    t="$(jq -r '.detected_type' <<<"$line")"
    [ "$t" = unknown ] && continue
    [ "$(jq -r '.unreadable // "absent"' <<<"$line")" = absent ]
  done < <(echo "$output" | grep '"path"')
}

# ---- rerun isolation: a second run must never return the first run's bytes --
#
# The default (and typical) --out-dir is REUSED for a conversation and the
# attachment index restarts at 1 every run, so run 2 writes into names run 1
# already used. heif-convert's output naming depends on the container: a
# single-image HEIC writes the exact path asked for, a multi-image one writes
# `<base>-1.jpg` instead. Scanning the shared out-dir afterwards therefore lets
# run 1's leftover `1.jpg` win over run 2's `1-1.jpg` -- handing back a
# PREVIOUS customer's photo as this customer's evidence.
#
# These assert on CONTENT (the stub's marker), never on filenames: the stale
# file and the fresh one can legitimately share a name, so a filename check
# would pass while serving the wrong bytes.

@test "rerun single-then-multi returns the SECOND run's image, not the first's" {
  install_heif_stub single RUN1
  run bash "$SCRIPT" heic --out-dir "$OUT_DIR"
  [ "$status" -eq 0 ]
  first_path="$(echo "$output" | jq -r '.path')"
  first_sum="$(md5sum <"$first_path" 2>/dev/null || md5 -q "$first_path")"

  install_heif_stub multi RUN2
  run bash "$SCRIPT" heic --out-dir "$OUT_DIR"
  [ "$status" -eq 0 ]
  second_path="$(echo "$output" | jq -r '.path')"
  second_sum="$(md5sum <"$second_path" 2>/dev/null || md5 -q "$second_path")"

  [ "$first_sum" != "$second_sum" ]
  grep -q 'RUN2' "$second_path"
  run grep -q 'RUN1' "$second_path"
  [ "$status" -ne 0 ]
}

@test "rerun multi-then-single returns the SECOND run's image, not the first's" {
  install_heif_stub multi RUN1
  run bash "$SCRIPT" heic --out-dir "$OUT_DIR"
  [ "$status" -eq 0 ]
  first_path="$(echo "$output" | jq -r '.path')"
  first_sum="$(md5sum <"$first_path" 2>/dev/null || md5 -q "$first_path")"

  install_heif_stub single RUN2
  run bash "$SCRIPT" heic --out-dir "$OUT_DIR"
  [ "$status" -eq 0 ]
  second_path="$(echo "$output" | jq -r '.path')"
  second_sum="$(md5sum <"$second_path" 2>/dev/null || md5 -q "$second_path")"

  [ "$first_sum" != "$second_sum" ]
  grep -q 'RUN2' "$second_path"
  run grep -q 'RUN1' "$second_path"
  [ "$status" -ne 0 ]
}

@test "a failing rerun leaves no earlier JPEG at the name the transcoder owns" {
  # Otherwise run 2 honestly reports heic_decode_failed while run 1's JPEG is
  # still sitting at 1.jpg for anything that globs the directory.
  install_heif_stub single RUN1
  run bash "$SCRIPT" heic --out-dir "$OUT_DIR"
  [ "$status" -eq 0 ]

  install_heif_stub fail RUN2
  run bash "$SCRIPT" heic --out-dir "$OUT_DIR"
  [ "$status" -eq 0 ]
  # The failing stub also writes to stderr, which `run` folds into $output.
  line="$(echo "$output" | grep '"path"')"
  [ "$(echo "$line" | jq -r '.unreadable')" = true ]
  [ "$(echo "$line" | jq -r '.unreadable_reason')" = heic_decode_failed ]
  [ ! -e "$OUT_DIR/1.jpg" ]
  [ -s "$OUT_DIR/1.heic" ]
}

@test "no conversion work directory survives a run" {
  install_heif_stub multi RUN1
  run bash "$SCRIPT" heic --out-dir "$OUT_DIR"
  [ "$status" -eq 0 ]
  [ -z "$(find "$OUT_DIR" -maxdepth 1 -name '*.convert.*' -print -quit)" ]
}

# ---- the transcode is BOUNDED: timeout and derived-output size --------------
#
# WHY: this path ran heif-convert with neither a timeout nor a cap on what it
# produced, while the plugin path (plugins/intercom/src/attachments.ts) bounded
# both. The download cap upstream is on the INPUT: a sub-10MB crafted or very
# high-resolution HEIC is admitted, and libheif can then either never return
# (hanging an unattended sweep with no upper limit) or decompress into a JPEG
# far larger than the input and fill the disk. Neither of these is a corrupt
# file, so both must be reported as themselves.

@test "a hanging heif-convert is killed and reported, not waited on forever" {
  # The stub sleeps 10s and never writes output. With no timeout the script
  # would block for all 10 -- and on a real pathological file, indefinitely.
  # The override is exported in the test body on purpose: `VAR=x run ...` is not
  # reliably delivered under bats, and a silently-unset bound would make this
  # test pass by waiting rather than by killing.
  export INTERCOM_HEIF_CONVERT_TIMEOUT_SECS=1
  install_heif_stub hang
  start="$(date +%s)"
  run bash "$SCRIPT" heic --out-dir "$OUT_DIR"
  elapsed=$(( $(date +%s) - start ))
  [ "$status" -eq 0 ]
  # Killed near the bound, nowhere near the stub's 10s sleep.
  [ "$elapsed" -lt 8 ]
  [[ "$output" == *"heif-convert timed out after 1s"* ]]

  line="$(echo "$output" | grep '"path"')"
  [ "$(echo "$line" | jq -r '.unreadable')" = true ]
  # We hit OUR OWN time budget, so nothing was concluded about the payload.
  [ "$(echo "$line" | jq -r '.unreadable_reason')" = pipeline_failed ]
  # The original HEIC is kept; no half-written JPEG is promoted.
  [[ "$(echo "$line" | jq -r '.path')" == *.heic ]]
  [ ! -e "$OUT_DIR/1.jpg" ]
}

@test "an oversized derived JPEG is refused as oversize, not passed off as decoded" {
  # The conversion SUCCEEDED. Calling this heic_decode_failed would tell Ops the
  # decoder broke on a file it decoded perfectly -- the same false claim the
  # unreadable markers exist to prevent, in the other direction.
  install_heif_stub huge
  run bash "$SCRIPT" heic --out-dir "$OUT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"over the 10485760-byte cap"* ]]

  line="$(echo "$output" | grep '"path"')"
  [ "$(echo "$line" | jq -r '.unreadable')" = true ]
  [ "$(echo "$line" | jq -r '.unreadable_reason')" = oversize ]
  # Refused means refused: the oversized JPEG never reaches the canonical name,
  # or a later glob hands it to a caller as this attachment's evidence.
  [ ! -e "$OUT_DIR/1.jpg" ]
  [ -z "$(find "$OUT_DIR" -maxdepth 1 -name '*.convert.*' -print -quit)" ]
  [[ "$(echo "$line" | jq -r '.path')" == *.heic ]]
}

@test "an under-cap transcode is still promoted (the cap is not a blanket refusal)" {
  # Counter-test: a bound that refused everything would pass the test above
  # while breaking every real HEIC.
  install_heif_stub single
  run bash "$SCRIPT" heic --out-dir "$OUT_DIR"
  [ "$status" -eq 0 ]
  line="$(echo "$output" | grep '"path"')"
  [ "$(echo "$line" | jq -r '.unreadable // "absent"')" = absent ]
  [ "$(echo "$line" | jq -r '.detected_type')" = jpeg ]
}

@test "the transcode bounds mirror the plugin path's, by value" {
  # These are MIRRORED limits, not independent ones -- the two attachment paths
  # must agree on what is too slow and too big, or a file the plugin refuses is
  # accepted here (or vice versa) and Ops gets contradictory evidence for the
  # same customer upload. Pinned by value so a future change to one side is a
  # visible failure here rather than a silent divergence.
  local plugin="$REPO_ROOT/plugins/intercom/src/attachments.ts"
  grep -q 'ATTACHMENT_FETCH_TIMEOUT_MS = 12_000' "$plugin"
  grep -q 'ATTACHMENT_MAX_BYTES = 10 \* 1024 \* 1024' "$plugin"
  grep -q 'HEIF_CONVERT_TIMEOUT_SECS="\${INTERCOM_HEIF_CONVERT_TIMEOUT_SECS:-12}"' "$SCRIPT"
  grep -q 'HEIF_CONVERT_MAX_BYTES="\${INTERCOM_HEIF_CONVERT_MAX_BYTES:-10485760}"' "$SCRIPT"
}

# ---- a bound the script cannot parse must REFUSE, never wave the file through -
#
# WHY: `[ "$primary_size" -gt "$HEIF_CONVERT_MAX_BYTES" ]` with a non-numeric
# bound makes `test` exit 2. That test is an `if` CONDITION, so `set -e` does
# NOT fire: bash reads the error status as "false", skips the refusal, and falls
# through to the `mv`. A typo'd override would therefore silently disable the
# very cap it was meant to tune -- the guard passing exactly what it exists to
# reject. Validated up front instead, and fatally.

@test "a non-numeric derived-size override is refused before any work happens" {
  export INTERCOM_HEIF_CONVERT_MAX_BYTES=bogus
  install_heif_stub huge
  run bash "$SCRIPT" heic --out-dir "$OUT_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Invalid HEIF_CONVERT_MAX_BYTES"* ]]
  # Refused BEFORE the conversation fetch: nothing was downloaded, and the
  # oversized JPEG the stub would have produced never reached the canonical name.
  [ ! -s "$CURL_CALLS" ]
  [ ! -e "$OUT_DIR/1.jpg" ]
}

@test "a non-numeric timeout override is refused too" {
  export INTERCOM_HEIF_CONVERT_TIMEOUT_SECS="12; rm -rf /"
  run bash "$SCRIPT" heic --out-dir "$OUT_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Invalid HEIF_CONVERT_TIMEOUT_SECS"* ]]
  [ ! -s "$CURL_CALLS" ]
}

@test "zero and negative bounds are refused (a cap of 0 is not a cap)" {
  for bad in 0 -1 01 " 5" "1e9"; do
    export INTERCOM_HEIF_CONVERT_MAX_BYTES="$bad"
    run bash "$SCRIPT" heic --out-dir "$OUT_DIR"
    [ "$status" -eq 2 ]
  done
}

@test "a valid override is honoured, not merely tolerated" {
  # Counter-test: validation that rejected everything would pass the tests above
  # while making the override useless. 1 byte is below the stub's JPEG, so the
  # cap must fire and report oversize.
  export INTERCOM_HEIF_CONVERT_MAX_BYTES=1
  install_heif_stub single
  run bash "$SCRIPT" heic --out-dir "$OUT_DIR"
  [ "$status" -eq 0 ]
  line="$(echo "$output" | grep '"path"')"
  [ "$(echo "$line" | jq -r '.unreadable_reason')" = oversize ]
  [ ! -e "$OUT_DIR/1.jpg" ]
}

# ---- numeric overrides must be range-checked, not just digit-checked --------
@test "an over-wide numeric override is refused (digits alone are not enough)" {
  # `test -gt` parses 64-bit; a 30-digit operand makes it exit 2, and as an `if`
  # CONDITION bash reads that as false -- promoting the very file the cap exists
  # to refuse. A digit-only regex accepts this value, so the range check is what
  # actually closes the fail-open.
  export INTERCOM_HEIF_CONVERT_MAX_BYTES=999999999999999999999999999999
  install_heif_stub single RUN1
  run bash "$SCRIPT" heic --out-dir "$OUT_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"must be between 1 and"* ]]
  [ ! -e "$OUT_DIR/1.jpg" ]
}

@test "an over-wide timeout override is refused too" {
  export INTERCOM_HEIF_CONVERT_TIMEOUT_SECS=99999999999999999999
  install_heif_stub single RUN1
  run bash "$SCRIPT" heic --out-dir "$OUT_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"must be between 1 and"* ]]
}

@test "a large-but-sane override is still accepted (the ceiling is not a blanket refusal)" {
  export INTERCOM_HEIF_CONVERT_MAX_BYTES=1073741824
  export INTERCOM_HEIF_CONVERT_TIMEOUT_SECS=3600
  install_heif_stub single RUN1
  run bash "$SCRIPT" heic --out-dir "$OUT_DIR"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.detected_type')" = jpeg ]
}

# ---- ftyp compatible brands past the header --------------------------------
@test "a HEIF brand in the FIFTH compatible slot is still detected" {
  # Generic major brand `isom` with `heic` only at byte 32. Reading 32 bytes
  # classified this `unknown` and reported it to Ops as corrupt_or_unrecognized
  # -- a false claim about a perfectly good file. The TypeScript detector scans
  # the declared ftyp box; this path now does too.
  #
  # Box: [size=0x2C][ftyp][isom][minor][mp41][mp42][avc1][iso2][heic]
  printf '\x00\x00\x00\x2Cftypisom\x00\x00\x02\x00mp41mp42avc1iso2heic' \
    >"$TMP/late-brand.heic"
  # Sanity: the brand really is past byte 32, or the test proves nothing.
  [ "$(head -c 32 "$TMP/late-brand.heic" | grep -c heic || true)" -eq 0 ]

  cat >"$TMP/bin/curl" <<STUB
#!/usr/bin/env bash
url=""; outfile=""; prev=""
for a in "\$@"; do
  case "\$prev" in -o) outfile="\$a" ;; esac
  case "\$a" in http://*|https://*) url="\$a" ;; esac
  prev="\$a"
done
case "\$url" in
  *api.intercom.io/conversations/heic*) cp "$FIXTURES/conversation-heic.json" "\$outfile"; exit 0 ;;
  *IMG_0042.heic*) cp "$TMP/late-brand.heic" "\$outfile"; exit 0 ;;
esac
exit 22
STUB
  chmod +x "$TMP/bin/curl"

  install_heif_stub single RUN1
  run bash "$SCRIPT" heic --out-dir "$OUT_DIR"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.converted_from')" = heic ]
  [ "$(echo "$output" | jq -r '.detected_type')" = jpeg ]
  [ "$(echo "$output" | jq -r '.unreadable // "absent"')" = absent ]
}


@test "a decoder REJECTION is heic_decode_failed, not pipeline_failed" {
  # The counter-test for the provisioning split: when libheif actually looks at
  # the payload and refuses it, we cannot tell a damaged upload from a variant
  # we cannot decode -- but it is emphatically NOT "we never tried".
  install_heif_stub fail RUN1
  run bash "$SCRIPT" heic --out-dir "$OUT_DIR"
  [ "$status" -eq 0 ]
  line="$(echo "$output" | grep '"path"')"
  [ "$(echo "$line" | jq -r '.unreadable_reason')" = heic_decode_failed ]
}

# ---- valid-but-unsupported is NOT damaged ----------------------------------
@test "unidentified bytes stay one neutral state and carry the UNVERIFIED declared type" {
  # Round 11 split this by declared content_type; round 18 showed the split
  # asserted things the code cannot know in BOTH directions (truncated garbage
  # labelled image/tiff read as "the file is FINE"; a valid inline TIFF with no
  # declared MIME read as "damaged"). The declared type is a hint from the
  # uploading client -- the reason we sniff at all is that clients lie -- so it
  # now rides along as `declared_type` WITHOUT becoming a verdict.
  cat >"$TMP/conv-tiff.json" <<'JSON'
{"type":"conversation","id":"tiffconv",
 "source":{"body":"<p>scan attached</p>","attachments":[
   {"url":"https://musoai.intercom-attachments-3.com/scan.tiff","content_type":"image/tiff","name":"scan.tiff"}]},
 "conversation_parts":{"conversation_parts":[]}}
JSON
  cat >"$TMP/bin/curl" <<STUB
#!/usr/bin/env bash
url=""; outfile=""; prev=""
for a in "\$@"; do
  case "\$prev" in -o) outfile="\$a" ;; esac
  case "\$a" in http://*|https://*) url="\$a" ;; esac
  prev="\$a"
done
case "\$url" in
  *api.intercom.io/conversations/tiffconv*) cp "$TMP/conv-tiff.json" "\$outfile"; exit 0 ;;
  *scan.tiff*) printf 'II*\\x00REALTIFFBYTES' >"\$outfile"; exit 0 ;;
esac
exit 22
STUB
  chmod +x "$TMP/bin/curl"

  run bash "$SCRIPT" tiffconv --out-dir "$OUT_DIR"
  [ "$status" -eq 0 ]
  line="$(echo "$output" | grep '"path"')"
  [ "$(echo "$line" | jq -r '.unreadable')" = true ]
  [ "$(echo "$line" | jq -r '.unreadable_reason')" = corrupt_or_unrecognized ]
  # The claim the client made is reported, not believed.
  [ "$(echo "$line" | jq -r '.declared_type')" = "image/tiff" ]
  [ "$(echo "$line" | jq -r '.detected_type')" = unknown ]
}

@test "the same neutral state applies with NO declared type (no asymmetry)" {
  # The other half of the false split: an inline <img> with no declared MIME
  # used to be called damaged while the TIFF above was called fine. Same bytes
  # situation, same verdict.
  cat >"$TMP/conv-nomime.json" <<'JSON'
{"type":"conversation","id":"nomimeconv",
 "source":{"body":"<p>see this</p>","attachments":[
   {"url":"https://musoai.intercom-attachments-3.com/mystery.bin"}]},
 "conversation_parts":{"conversation_parts":[]}}
JSON
  cat >"$TMP/bin/curl" <<STUB
#!/usr/bin/env bash
url=""; outfile=""; prev=""
for a in "\$@"; do
  case "\$prev" in -o) outfile="\$a" ;; esac
  case "\$a" in http://*|https://*) url="\$a" ;; esac
  prev="\$a"
done
case "\$url" in
  *api.intercom.io/conversations/nomimeconv*) cp "$TMP/conv-nomime.json" "\$outfile"; exit 0 ;;
  *mystery.bin*) printf 'II*\\x00REALTIFFBYTES' >"\$outfile"; exit 0 ;;
esac
exit 22
STUB
  chmod +x "$TMP/bin/curl"

  run bash "$SCRIPT" nomimeconv --out-dir "$OUT_DIR"
  [ "$status" -eq 0 ]
  line="$(echo "$output" | grep '"path"')"
  [ "$(echo "$line" | jq -r '.unreadable_reason')" = corrupt_or_unrecognized ]
  [ "$(echo "$line" | jq -r '.declared_type')" = "" ]
}

@test "bytes declared as a format we DO handle but not matching it stay corrupt_or_unrecognized" {
  # The counter-test: the split must not turn every unknown blob into
  # "unsupported". A declared PNG whose bytes are not a PNG really is damaged.
  cat >"$TMP/conv-badpng.json" <<'JSON'
{"type":"conversation","id":"badpngconv",
 "source":{"body":"<p>screenshot</p>","attachments":[
   {"url":"https://musoai.intercom-attachments-3.com/shot.png","content_type":"image/png","name":"shot.png"}]},
 "conversation_parts":{"conversation_parts":[]}}
JSON
  cat >"$TMP/bin/curl" <<STUB
#!/usr/bin/env bash
url=""; outfile=""; prev=""
for a in "\$@"; do
  case "\$prev" in -o) outfile="\$a" ;; esac
  case "\$a" in http://*|https://*) url="\$a" ;; esac
  prev="\$a"
done
case "\$url" in
  *api.intercom.io/conversations/badpngconv*) cp "$TMP/conv-badpng.json" "\$outfile"; exit 0 ;;
  *shot.png*) printf 'TRUNCATED-GARBAGE' >"\$outfile"; exit 0 ;;
esac
exit 22
STUB
  chmod +x "$TMP/bin/curl"

  run bash "$SCRIPT" badpngconv --out-dir "$OUT_DIR"
  [ "$status" -eq 0 ]
  line="$(echo "$output" | grep '"path"')"
  [ "$(echo "$line" | jq -r '.unreadable_reason')" = corrupt_or_unrecognized ]
}
