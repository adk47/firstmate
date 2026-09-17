#!/usr/bin/env bats
# Safety gate for Caroline's platform.muso.ai API feed.
#
# sync-platform-llms.sh fetches the PUBLIC https://platform.muso.ai/llms-full.txt
# and renders it into workspaces/support/reference/platform-api.md, which
# Caroline's RAG index auto-recalls on every customer turn. Unlike the shipped-work
# feed, the input here is FIRST-PARTY published copy, not model output over
# author-controlled PR titles -- so there is no leak gate and no promote flow.
#
# What still has to hold, and what these tests pin:
#   1. FAIL-CLOSED. A failed, truncated, or unrecognisable fetch must leave the
#      previous file exactly as it was. Caroline quoting slightly stale pricing is
#      recoverable; Caroline quoting an empty file, or a 404 body, is not.
#   2. The CI blocklist runs HERE too. The cron path never touches CI, so the
#      "CS agent reference file security scan" cannot protect this file. The gate
#      is shared with CI via scripts/lib/cs-reference-blocklist.sh -- two copies
#      would drift.
#   3. No em-dashes reach Caroline's surface. scripts/lint-no-em-dash.sh greps the
#      workspaces/support DIRECTORY, so it cannot see a file that is generated on
#      the server and rsync-excluded. Honour the rule anyway; do not exploit the
#      blind spot.
#
# Every assertion uses `run` + an explicit status check: a bare `! cmd` in bats is
# a no-op unless it is the final line (set -e ignores negated commands), which
# would make this whole file a false green.
#
# KNOWN COVERAGE GAP, stated rather than implied: curl's `--fail` is NOT pinned by
# any test here. These fixtures use file:// URLs, where a missing file already
# fails without it, so deleting `--fail` leaves the suite green (confirmed by
# mutation). It still earns its place -- without it an HTTP 404 body is saved and
# handed to the validator -- but the checks that actually stop a 404 from
# reaching Caroline are the size floor and the two sanity markers, and those ARE
# pinned below. Covering `--fail` properly needs a local HTTP server, which would
# buy little and cost suite hermeticity.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SYNC="$HYDRA_REPO/scripts/sync-platform-llms.sh"

# A body that looks like the real llms-full.txt: carries both sanity markers and
# enough substance to clear the size floor.
good_body() {
  cat <<'EOF'
# Muso Platform API -- full agent guide

The developer platform for Muso's music-credits + analytics graph.
Console: https://platform.muso.ai - API: https://api.platform.muso.ai/v1

## Authentication
Workspace API key in the `x-api-key` header: `x-api-key: msk_...`.
Every key is live; there is no test mode. Issued in the console at /keys.

## Commercial model (canonical)
One meter only: `api_requests` (every REST, MCP, and CLI call).

### Pay as you go -- no base fee
- Add a card, start with $5 in credits, then pay per call in marginal bands:
  $0.025/call for the first 100K, $0.020 to 300K, $0.015 beyond.
- 300 requests/min - prepaid balance - no subscription, no trial

### Workspace API -- included with Muso Pro/Business
- 10K requests/day hard cap (429), roster-scoped, 60 rpm, no charge

### Enterprise -- custom
- Committed volume, custom rate limits, premium support hours, SLA.

### Program fees (not metered)
- "Login with Muso" SSO: $99/mo per registered app; returns the signed-in
  user's OWN consented data free.

### The guardrail
Money buys usage, never a licence to clone the database. Catalog-scale
extraction is Enterprise-only under the data licence.

## Request semantics
- Base URL: https://api.platform.muso.ai/v1
- Envelope: success is `{ "result": "ok", "code": 200, "data": ... }`.
- Pagination: `limit` (MAX 50) + `offset` on list endpoints. Rows are in
  `data.items`; `data.totalCount` is the full size. There is no cursor.
- Rate limits surface as `RateLimit-Limit`, `RateLimit-Remaining` and
  `RateLimit-Reset` (SECONDS remaining, not a timestamp).
- There is no idempotency support: sending `Idempotency-Key` has no effect.

## OpenAPI summary
- GET  /profile/{id} -- Profile {id, name, country, city, website}
- GET  /profile/{id}/credits -- verified credits for the profile
- GET  /profile/{id}/charts -- chart positions and audience analytics
- GET  /track/{idKey}/{idValue} -- track by identifier
- GET  /album/{idKey}/{idValue}/credits -- credits for the album's tracks
- POST /search -- {keyword, type:[track|profile|album]}
- GET  /roles -- credit-role taxonomy

## Surfaces
- REST (this spec), MCP server (hosted), and the `muso` CLI all share the
  api_requests meter.

## Links
/docs - /pricing - /openapi.yaml - /system-status - /trust
EOF
}

setup() {
  TMP="$BATS_TEST_TMPDIR"
  SRC="$TMP/llms-full.txt"
  OUT="$TMP/platform-api.md"
  good_body >"$SRC"
  # HERMETICITY, and it is not optional here: CI bats run as root ON node-8,
  # where /etc/openclaw/main.env holds the real bot tokens and /usr/local/bin/muso
  # is on PATH -- so an unstubbed suite posts a real message into #cs_chats for
  # every test whose install reports "content CHANGED", which is most of them.
  # Same guard as support-changelog-sync.bats. The routing tests below override
  # it with a recorder.
  export MUSO_BIN=/nonexistent
}

# run_sync <extra args...> -- invoke the script against the temp fixture.
run_sync() {
  run env PLATFORM_LLMS_URL="file://$SRC" PLATFORM_LLMS_OUT="$OUT" \
    bash "$SYNC" "$@"
}

# _stub_slack_recorder -- replace `muso` with a recorder so the notify path can
# be asserted on argv instead of on a real send.
_stub_slack_recorder() {
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/muso-recorder" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/slack-argv.txt"
STUB
  chmod +x "$TMP/bin/muso-recorder"
  export MUSO_BIN="$TMP/bin/muso-recorder"
  # slack_load_env only reaches the send once the per-bot token is present.
  export MUSO_SLACK_BOT_TOKEN_OPERATIONS=test-token
}

@test "the script exists and is executable" {
  [ -x "$SYNC" ]
}

# ─── the happy path ───

@test "writes the feed from a good body" {
  run_sync
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ -s "$OUT" ]
  grep -q "api.platform.muso.ai/v1" "$OUT"
}

@test "the rendered file carries a provenance header naming the source it fetched" {
  run_sync
  [ "$status" -eq 0 ]
  grep -q "^Source: file://$SRC" "$OUT"
  grep -q "GENERATED FILE" "$OUT"
  # It must also point a reader at the hand-authored companion, or a future
  # editor will "correct" the generated file in place and lose it on next sync.
  grep -q "platform.md" "$OUT"
}

@test "the default source is the public platform.muso.ai page" {
  # The fixture tests all inject PLATFORM_LLMS_URL, so nothing else pins the
  # real default. A typo there would sync Caroline from the wrong place.
  grep -q 'PLATFORM_LLMS_URL:-https://platform.muso.ai/llms-full.txt' "$SYNC"
}

@test "the default output path is inside Caroline's RAG directory" {
  # reference/ is the ONLY directory her memory_search reads; a path outside it
  # renders a file that reaches nobody.
  grep -q 'PLATFORM_LLMS_OUT:-/opt/hydra/workspaces/support/reference/' "$SYNC"
}

@test "--dry-run prints the render and writes nothing" {
  run_sync --dry-run
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ ! -e "$OUT" ]
  echo "$output" | grep -q "api.platform.muso.ai/v1"
}

@test "--check exits 0 when the installed file matches the live render" {
  run_sync
  [ "$status" -eq 0 ]
  run_sync --check
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "--check exits nonzero when the installed file has drifted" {
  run_sync
  [ "$status" -eq 0 ]
  echo "drifted" >>"$OUT"
  run_sync --check
  [ "$status" -ne 0 ]
}

@test "--check exits nonzero when the file is missing entirely" {
  run_sync --check
  [ "$status" -ne 0 ]
}

# ─── fail-closed: the previous file must survive every bad fetch ───

@test "a fetch failure leaves the previous file untouched" {
  run_sync
  [ "$status" -eq 0 ]
  cp "$OUT" "$TMP/before.md"

  run env PLATFORM_LLMS_URL="file://$TMP/does-not-exist.txt" \
    PLATFORM_LLMS_OUT="$OUT" bash "$SYNC"
  [ "$status" -ne 0 ]
  run diff -q "$TMP/before.md" "$OUT"
  [ "$status" -eq 0 ] || { echo "fail-closed violated: file was modified" >&2; return 1; }
}

@test "an empty body is refused and leaves the previous file untouched" {
  run_sync
  [ "$status" -eq 0 ]
  cp "$OUT" "$TMP/before.md"

  : >"$SRC"
  run_sync
  [ "$status" -ne 0 ]
  run diff -q "$TMP/before.md" "$OUT"
  [ "$status" -eq 0 ]
}

@test "a truncated body below the size floor is refused" {
  echo "# Muso Platform API" >"$SRC"
  run_sync
  [ "$status" -ne 0 ]
  [ ! -e "$OUT" ]
}

@test "the size floor rejects a short body even when both markers are present" {
  # Isolates the floor. The test above is ALSO caught by the marker checks, so
  # without this one the floor could be deleted and the suite would stay green
  # (verified by mutation). A stub carrying both markers is the realistic shape
  # of a half-rendered or placeholder page.
  printf '# Muso Platform API\nhttps://api.platform.muso.ai/v1 x-api-key\n' >"$SRC"
  run_sync
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "floor"
  [ ! -e "$OUT" ]
}

@test "a body missing only the auth marker is refused" {
  # Isolates MARKER_AUTH. The 404-page test lacks BOTH markers and the test
  # below removes only the host one, so nothing else pins this check.
  good_body | sed 's/x-api-key/x-removed-header/g' >"$SRC"
  run_sync
  [ "$status" -ne 0 ]
  [ ! -e "$OUT" ]
}

@test "an error page that lacks the sanity markers is refused" {
  # A 404/maintenance page is long enough to clear a naive size check.
  { echo "<!DOCTYPE html><html><head><title>404</title></head><body>"
    for _ in $(seq 1 80); do echo "<p>Page not found. Please try again later.</p>"; done
    echo "</body></html>"
  } >"$SRC"
  run_sync
  [ "$status" -ne 0 ]
  [ ! -e "$OUT" ]
}

@test "a body missing only the api host marker is refused" {
  good_body | sed 's#https://api\.platform\.muso\.ai/v1#https://example.invalid/v1#g' >"$SRC"
  run_sync
  [ "$status" -ne 0 ]
}

# ─── the shared CI blocklist runs on this path too ───

@test "refuses a body carrying an internal infrastructure term" {
  { good_body; echo; echo "Served from our Kubernetes cluster."; } >"$SRC"
  run_sync
  [ "$status" -ne 0 ] || { echo "LEAK: blocklist term was published" >&2; return 1; }
  [ ! -e "$OUT" ]
}

@test "a blocklist hit leaves the previous file untouched" {
  run_sync
  [ "$status" -eq 0 ]
  cp "$OUT" "$TMP/before.md"

  { good_body; echo; echo "Runs on Hetzner behind Grafana."; } >"$SRC"
  run_sync
  [ "$status" -ne 0 ]
  run diff -q "$TMP/before.md" "$OUT"
  [ "$status" -eq 0 ]
}

@test "the blocklist is word-boundary matched, not substring" {
  # "weeks" contains "EKS"; "archive" contains "Hive". The CI gate documents
  # these exact false positives -- the shared gate must not regress them.
  { good_body; echo; echo "Invoices archive after a few weeks."; } >"$SRC"
  run_sync
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

# ─── em-dash normalisation ───

@test "em-dashes in the source are normalised out of the rendered file" {
  good_body | sed 's/-- full agent guide/\xe2\x80\x94 full agent guide/' >"$SRC"
  run_sync
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  run grep -c $'\xe2\x80\x94' "$OUT"
  [ "$status" -ne 0 ] || {
    echo "em-dash survived into Caroline's surface:" >&2
    grep -n $'\xe2\x80\x94' "$OUT" >&2
    return 1
  }
}

@test "the real live body would pass the gate once normalised" {
  # Guards the gate against being so strict it refuses production content.
  # Uses the committed fixture rather than the network so the suite stays hermetic.
  FIX="$HYDRA_REPO/scripts/tests/fixtures/platform-llms-full.txt"
  [ -f "$FIX" ] || skip "fixture not present"
  run env PLATFORM_LLMS_URL="file://$FIX" PLATFORM_LLMS_OUT="$OUT" bash "$SYNC"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  grep -q "api.platform.muso.ai/v1" "$OUT"
}

# ─── the Slack notice ───
# Both knobs are asserted because they are NOT independent: the devops bot that
# slack-notify.sh defaults to is not a member of #cs_chats and cannot even
# resolve the ID, so the right channel with the wrong bot is a message nobody
# receives.

@test "a content change is announced to #cs_chats as the operations bot" {
  _stub_slack_recorder
  run_sync
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ -f "$TMP/slack-argv.txt" ] || { echo "no Slack send was attempted" >&2; return 1; }
  grep -q -- '--bot operations' "$TMP/slack-argv.txt" || {
    echo "wrong bot:" >&2; cat "$TMP/slack-argv.txt" >&2; return 1; }
  grep -q -- '--channel C0ANM0PN9L5' "$TMP/slack-argv.txt" || {
    echo "wrong channel:" >&2; cat "$TMP/slack-argv.txt" >&2; return 1; }
  grep -q -- '--channel C0ADV2W76G4' "$TMP/slack-argv.txt" && {
    echo "leaked to the #clio_devops default" >&2; return 1; }
  return 0
}

@test "a refusal PAGES rather than freezing the feed silently" {
  # The whole point of the fail-closed design is that the previous file survives.
  # Surviving silently is the ten-week-rot failure: a Type=oneshot daily timer's
  # stderr is nobody's inbox, so a refusal must say so in Slack.
  _stub_slack_recorder
  good_body | sed 's#https://api\.platform\.muso\.ai/v1#https://example.invalid/v1#g' >"$SRC"
  run_sync
  [ "$status" -ne 0 ]
  [ -f "$TMP/slack-argv.txt" ] || { echo "a refusal went unannounced" >&2; return 1; }
  grep -q -- '--bot operations' "$TMP/slack-argv.txt"
  grep -qi 'did not update' "$TMP/slack-argv.txt"
}

@test "--dry-run and --check never post, however badly they fail" {
  # These are run by a human who is already reading the output; paging on them
  # would train the channel to ignore the alert that matters.
  _stub_slack_recorder
  : >"$SRC"
  run_sync --dry-run
  [ "$status" -ne 0 ]
  run_sync --check
  [ "$status" -ne 0 ]
  [ ! -f "$TMP/slack-argv.txt" ] || {
    echo "an operator-run mode paged:" >&2; cat "$TMP/slack-argv.txt" >&2; return 1; }
}

@test "PLATFORM_LLMS_NO_NOTIFY suppresses the post entirely" {
  _stub_slack_recorder
  run env PLATFORM_LLMS_URL="file://$SRC" PLATFORM_LLMS_OUT="$OUT" \
    PLATFORM_LLMS_NO_NOTIFY=1 bash "$SYNC"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ ! -f "$TMP/slack-argv.txt" ]
}

# ─── crash safety: no scratch file left inside Caroline's reference/ ───

@test "no .tmp staging file survives a refused run" {
  # The staging file lives next to $OUT (rename is only atomic within a
  # filesystem), i.e. inside a directory whose deploy rsync exclude is the EXACT
  # name platform-api.md. A leftover platform-api.md.tmp.<pid> is an untracked
  # would-delete server file that reds the Step 4a pre-flight on every open PR.
  run_sync
  [ "$status" -eq 0 ]
  : >"$SRC"
  run_sync
  [ "$status" -ne 0 ]
  run bash -c "ls '$TMP'/platform-api.md.tmp.* 2>/dev/null"
  [ -z "$output" ] || { echo "leftover staging file: $output" >&2; return 1; }
}

# ─── usage ───

@test "an unknown flag is a usage error, not a silent success" {
  run_sync --not-a-real-flag
  [ "$status" -eq 2 ]
}
