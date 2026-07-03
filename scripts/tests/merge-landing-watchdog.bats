#!/usr/bin/env bats
# Tests for scripts/merge-landing-watchdog.sh — the stuck-merge alerter added
# after the 2026-06-08/09 Jan ↔ Ops threads where two profile merges returned
# HTTP 200 four times over days and never landed in the catalog.
#
# PATH-shadows muso + ssh so a real Slack send / remote call during a test
# fails loudly instead of paging #clio_devops for real
# (see memory/feedback_bats_must_stub_openclaw.md). The catalog query is
# redirected to a stub via MERGE_LANDING_TRINO_CMD — no real Trino/kubectl.
# Behavioural assertions use --dry-run; the payload-escaping test runs the real
# post path against a stubbed muso that captures the argv + text.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
WD="$HYDRA_REPO/scripts/merge-landing-watchdog.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin"

  # Refuse real network: stub muso + ssh; never read the real main.env.
  unset MUSO_SLACK_BOT_TOKEN_DEVOPS
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/muso-slack.env"  # absent → no token
  export STUB_CALLS="$TEST_TMPDIR/muso-calls"
  : > "$STUB_CALLS"
  cat > "$TEST_TMPDIR/bin/ssh" <<'STUB'
#!/bin/bash
echo "test stub: ssh refused ($*)" >&2; exit 99
STUB
  # muso stub: record argv, capture --text for inspection; exit 0 == Slack
  # confirmed delivery (the CLI decodes ok:false itself).
  cat > "$TEST_TMPDIR/bin/muso" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
prev=""
for a in "$@"; do
  [ "$prev" = "--text" ] && printf '%s' "$a" > "$TEST_TMPDIR/last-text"
  prev="$a"
done
echo '{"channel":"C0TEST","ts":"1717171717.000100"}'
STUB
  # flock shim: macOS has no flock(1); use the real one when present (Linux CI).
  cat > "$TEST_TMPDIR/bin/flock" <<'STUB'
#!/bin/bash
[ -x /usr/bin/flock ] && exec /usr/bin/flock "$@"
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/ssh" "$TEST_TMPDIR/bin/muso" "$TEST_TMPDIR/bin/flock"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH

  # Catalog stub: pattern-matches the loser id in the IN-list SQL and emits the
  # quoted "_id","merged_to_id","is_deleted" rows trino-query.sh would return
  # (data rows only, no header). STUCK = "<id>","","false". By default L_STUCK
  # is stuck, L_LANDED is merged, SURV is the active survivor. It ALSO answers
  # the freshness-watermark query (max(updated_timestamp)) with STUB_WATERMARK_MS
  # (epoch MILLIS) — default is far past the ts=1000 test merges (caught up), so
  # existing tests classify; a test can set it BEFORE the merge to exercise the
  # PENDING hold.
  export STUB_WATERMARK_MS="${STUB_WATERMARK_MS:-1001000000}"  # 1001000s == pinned NOW
  cat > "$TEST_TMPDIR/bin/trino-stub.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
q="${1:-}"
if [[ "$q" == *"max(updated_timestamp)"* ]]; then
  printf '"%s"\n' "${STUB_WATERMARK_MS}"
  exit 0
fi
[[ "$q" == *"'L_STUCK'"*  ]] && printf '"L_STUCK","","false"\n'
[[ "$q" == *"'L_LANDED'"* ]] && printf '"L_LANDED","SURV","true"\n'
[[ "$q" == *"'SURV'"*     ]] && printf '"SURV","","false"\n'
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/trino-stub.sh"

  export MERGE_LANDING_MERGES_FILE="$TEST_TMPDIR/recent-merges.jsonl"
  export MERGE_LANDING_STATE_FILE="$TEST_TMPDIR/state.json"
  export MERGE_LANDING_LOCKFILE="$TEST_TMPDIR/wd.lock"
  export MERGE_LANDING_TRINO_CMD="$TEST_TMPDIR/bin/trino-stub.sh"
  export MERGE_LANDING_SKIP_HOST_GUARD=1
  export MERGE_LANDING_MIN_AGE_HOURS=6
  # Pin "now" so age math is deterministic. ts=1000 below is ~277h before this.
  export MERGE_LANDING_NOW_EPOCH=1001000
  # Disable the watermark-staleness guard by default: the pinned NOW sits ~277h
  # after the ts=1000 fixtures, so a watermark near the merge (the PENDING tests)
  # would look wall-clock-stale. The dedicated staleness test re-enables it.
  export MERGE_LANDING_WATERMARK_STALE_HOURS=100000000
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# Helper: write a single merge-log line for a survivor + loser list.
mergeline() { # $1 epoch  $2 survivor  $3..$n losers
  local epoch="$1" survivor="$2"; shift 2
  local ids="" first=1
  for l in "$@"; do
    if [ "$first" = 1 ]; then ids="\"$l\""; first=0; else ids="$ids,\"$l\""; fi
  done
  printf '{"epoch":%s,"method":"POST","path":"/admin/profiles/merge","mergeInto":"%s","profilesIds":[%s],"requester":"jan@muso.ai"}\n' \
    "$epoch" "$survivor" "$ids" >> "$MERGE_LANDING_MERGES_FILE"
}

@test "no merge log → SKIP, exits 0" {
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"merge audit log not found"* ]]
}

@test "aged merge whose loser never landed → alerts with loser + survivor" {
  mergeline 1000 SURV L_STUCK
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"accepted but NOT landed"* ]]
  [[ "$output" == *"L_STUCK"* ]]
  [[ "$output" == *"SURV"* ]]
}

@test "aged merge that DID land (loser merged_to_id set) → no alert" {
  mergeline 1000 SURV L_LANDED
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"no caught-up merge is stuck"* ]]
}

@test "fresh merge (younger than MIN_AGE_HOURS) → not yet checked, no alert" {
  # 1h before now → inside the 6h grace window.
  mergeline $((1001000 - 3600)) SURV L_STUCK
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"no merges older than"* ]]
}

# ──────────────────────────────────────────────────────────────
# Freshness-watermark gate: an aged merge that reads "stuck" in the matview must
# NOT alert while the matview's data watermark is still BEHIND the merge — that's
# just refresh lag, not a drop. This is the exact 2026-07-03 false-positive class
# (survivor 4ffd5e1c: 5 merges paged as "NOT landed" hours before the daily
# matview rebuilt past them). Only once the watermark advances past the merge
# (+ margin) is a persistent "stuck" reading a real drop.
# ──────────────────────────────────────────────────────────────

@test "aged + stuck but matview watermark BEHIND the merge → PENDING, no alert" {
  mergeline 1000 SURV L_STUCK
  # Watermark = 500s (in ms) → BEFORE the merge ts=1000 → not caught up.
  export STUB_WATERMARK_MS=500000
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"no caught-up merge is stuck"* ]]   # reached the quiet path (not BLIND, not alert)
  [[ "$output" != *"NOT landed"* ]]     # held, not escalated
  [[ "$output" != *"L_STUCK"* ]]
}

@test "aged + stuck, watermark ahead of merge but within margin → still PENDING" {
  mergeline 1000 SURV L_STUCK
  # Default margin is 12h (43200s). Watermark 40000s > ts(1000) but < ts+margin
  # (44200) → not yet trustworthy → PENDING.
  export STUB_WATERMARK_MS=40000000
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"no caught-up merge is stuck"* ]]   # reached the quiet path (not escalated)
  [[ "$output" != *"NOT landed"* ]]
}

@test "aged + stuck, watermark caught up PAST merge+margin → real drop, alerts" {
  mergeline 1000 SURV L_STUCK
  # Watermark 500000s ≫ ts(1000)+margin(43200) → caught up → a persistent stuck
  # reading is a genuine drop.
  export STUB_WATERMARK_MS=500000000
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"accepted but NOT landed"* ]]
  [[ "$output" == *"L_STUCK"* ]]
}

@test "stuck alert wording is verify + re-fire, never 'manual merge'" {
  mergeline 1000 SURV L_STUCK
  run bash "$WD" --dry-run           # default watermark is caught up
  [ "$status" -eq 0 ]
  [[ "$output" == *"verify + re-fire"* ]]
  [[ "$output" == *"do NOT blind re-merge"* ]]
  [[ "$output" != *"manual merge"* ]]
}

@test "direction-flip: survivor merged INTO the loser → landed, no alert" {
  # Merge log says FSURV is survivor, FLOSER the loser — but the backend
  # canonicalised the other way: FLOSER stays active, FSURV merged into FLOSER.
  # The pair collapsed → landed → must NOT flag the nominal loser.
  mergeline 1000 FSURV FLOSER
  cat > "$TEST_TMPDIR/bin/trino-flip.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
q="${1:-}"
if [[ "$q" == *"max(updated_timestamp)"* ]]; then printf '"1001000000"\n'; exit 0; fi
[[ "$q" == *"'FLOSER'"* ]] && printf '"FLOSER","","false"\n'   # nominal loser: active
[[ "$q" == *"'FSURV'"*  ]] && printf '"FSURV","FLOSER","true"\n' # nominal survivor merged INTO loser
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/trino-flip.sh"
  export MERGE_LANDING_TRINO_CMD="$TEST_TMPDIR/bin/trino-flip.sh"
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"NOT landed"* ]]
  [[ "$output" != *"FLOSER"* ]]
  [[ "$output" == *"no caught-up merge is stuck"* ]]
}

@test "catalog query returns EMPTY rows (silent failure) → BLIND, exit 1" {
  mergeline 1000 SURV L_STUCK
  # Stub exits 0 but emits nothing for the id query → must be treated as BLIND,
  # never as "everything landed" (which would hide real drops).
  cat > "$TEST_TMPDIR/bin/trino-empty.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/trino-empty.sh"
  export MERGE_LANDING_TRINO_CMD="$TEST_TMPDIR/bin/trino-empty.sh"
  run bash "$WD" --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"no rows"* ]]
  [[ "$output" == *"BLIND"* ]]
  [[ "$output" != *"no caught-up merge is stuck"* ]]
}

@test "matview watermark abnormally stale (rebuild stalled) → BLIND, exit 1" {
  mergeline 1000 SURV L_STUCK
  # Watermark 500s is ~277h behind the pinned NOW (1001000s); with the guard set
  # to 48h that's a stalled rebuild → must page BLIND, not silently under-detect.
  export MERGE_LANDING_WATERMARK_STALE_HOURS=48
  export STUB_WATERMARK_MS=500000
  run bash "$WD" --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"stale"* ]]
  [[ "$output" == *"BLIND"* ]]
  [[ "$output" != *"NOT landed"* ]]
}

@test "sustained matview stall pages ONCE, then deduped within cooldown (real run)" {
  # Guards the cooldown: the catalog id-query succeeds every tick during a stall,
  # so clearing the BLIND marker on catalog-success would re-page every tick.
  mergeline 1000 SURV L_STUCK
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  export MERGE_LANDING_WATERMARK_STALE_HOURS=48
  export STUB_WATERMARK_MS=500000        # ~277h stale vs pinned NOW

  run bash "$WD"                          # tick 1: stale → pages BLIND
  [ "$status" -eq 1 ]
  [ -f "$TEST_TMPDIR/last-text" ]
  grep -q 'stale' "$TEST_TMPDIR/last-text"

  rm -f "$TEST_TMPDIR/last-text"
  run bash "$WD"                          # tick 2: still stale, inside cooldown → no re-page
  [ "$status" -eq 1 ]
  [[ "$output" == *"already paged within"* ]]
  [ ! -f "$TEST_TMPDIR/last-text" ]
}

@test "watermark query failure (catalog OK) → BLIND, fail loud exit 1" {
  mergeline 1000 SURV L_STUCK
  # Stub returns catalog rows normally but FAILS the watermark query.
  cat > "$TEST_TMPDIR/bin/trino-wmfail.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
q="${1:-}"
if [[ "$q" == *"max(updated_timestamp)"* ]]; then exit 7; fi
[[ "$q" == *"'L_STUCK'"* ]] && printf '"L_STUCK","","false"\n'
[[ "$q" == *"'SURV'"*    ]] && printf '"SURV","","false"\n'
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/trino-wmfail.sh"
  export MERGE_LANDING_TRINO_CMD="$TEST_TMPDIR/bin/trino-wmfail.sh"
  run bash "$WD" --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"watermark query failed"* ]]
  [[ "$output" == *"BLIND"* ]]
  [[ "$output" != *"no caught-up merge is stuck"* ]]
}

@test "dedupe: a stuck pair alerts once, not again on the next tick" {
  mergeline 1000 SURV L_STUCK
  run bash "$WD" --dry-run
  [[ "$output" == *"L_STUCK"* ]]            # first tick alerts
  run bash "$WD" --dry-run
  [[ "$output" == *"no caught-up merge is stuck"* ]]        # second tick is quiet (state remembers)
}

@test "mixed batch: only the stuck loser is flagged, the landed one is not" {
  mergeline 1000 SURV L_STUCK L_LANDED
  run bash "$WD" --dry-run
  bullets="$(printf '%s\n' "$output" | grep -c '^• ' || true)"
  [ "$bullets" -eq 1 ]
  [[ "$output" == *"L_STUCK"* ]]
  [[ "$output" != *"• loser \`L_LANDED\`"* ]]
}

@test "catalog query failure (dry-run) → fail loud (BLIND), exit non-zero" {
  mergeline 1000 SURV L_STUCK
  # Trino stub that fails.
  printf '#!/usr/bin/env bash\nexit 7\n' > "$TEST_TMPDIR/bin/trino-fail.sh"
  chmod +x "$TEST_TMPDIR/bin/trino-fail.sh"
  export MERGE_LANDING_TRINO_CMD="$TEST_TMPDIR/bin/trino-fail.sh"
  run bash "$WD" --dry-run
  # A blind tick must NOT masquerade as a healthy "landed" run.
  [ "$status" -eq 1 ]
  [[ "$output" == *"catalog query failed"* ]]
  [[ "$output" == *"BLIND"* ]]
  [[ "$output" != *"no caught-up merge is stuck"* ]]
}

@test "catalog query failure (real run) → pages #clio_devops BLIND, exit 1, deduped" {
  mergeline 1000 SURV L_STUCK
  printf '#!/usr/bin/env bash\nexit 7\n' > "$TEST_TMPDIR/bin/trino-fail.sh"
  chmod +x "$TEST_TMPDIR/bin/trino-fail.sh"
  export MERGE_LANDING_TRINO_CMD="$TEST_TMPDIR/bin/trino-fail.sh"
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"

  run bash "$WD"
  [ "$status" -eq 1 ]
  [ -f "$TEST_TMPDIR/last-text" ]                 # it actually paged
  grep -q 'BLIND' "$TEST_TMPDIR/last-text"

  # Second tick inside the cooldown must NOT re-page (no new send), still exit 1.
  rm -f "$TEST_TMPDIR/last-text"
  run bash "$WD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"already paged within"* ]]
  [ ! -f "$TEST_TMPDIR/last-text" ]
}

@test "failed Slack delivery does NOT dedupe → next tick re-pages the same stuck pair" {
  mergeline 1000 SURV L_STUCK
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"

  # Tick 1: muso FAILS (Slack rejected / network) → delivery not confirmed →
  # state must not advance.
  printf '#!/bin/bash\nexit 1\n' > "$TEST_TMPDIR/bin/muso"
  chmod +x "$TEST_TMPDIR/bin/muso"
  run bash "$WD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NOT advanced"* ]]
  [ ! -f "$MERGE_LANDING_STATE_FILE" ]            # nothing deduped
  [ ! -f "${MERGE_LANDING_STATE_FILE}.pending" ]  # staging cleaned up

  # Tick 2: muso SUCCEEDS + captures → the same pair must alert again.
  cat > "$TEST_TMPDIR/bin/muso" <<'STUB'
#!/usr/bin/env bash
prev=""
for a in "$@"; do
  [ "$prev" = "--text" ] && printf '%s' "$a" > "$TEST_TMPDIR/last-text"
  prev="$a"
done
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/muso"
  run bash "$WD"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/last-text" ]
  grep -q 'L_STUCK' "$TEST_TMPDIR/last-text"
}

@test "Slack ok:false (muso exits non-zero) → NOT confirmed → dedupe not advanced, exit 1" {
  mergeline 1000 SURV L_STUCK
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"

  # Slack's HTTP-200 {"ok":false} trap is decoded by the CLI itself: muso exits
  # non-zero on e.g. not_in_channel, so the watchdog must treat it as undelivered.
  printf '#!/bin/bash\nexit 1\n' > "$TEST_TMPDIR/bin/muso"
  chmod +x "$TEST_TMPDIR/bin/muso"
  run bash "$WD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NOT advanced"* ]]
  [ ! -f "$MERGE_LANDING_STATE_FILE" ]            # pair not deduped → retried
  [ ! -f "${MERGE_LANDING_STATE_FILE}.pending" ]  # staging cleaned up
}

@test "successful delivery advances dedupe → next real tick is quiet" {
  mergeline 1000 SURV L_STUCK
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"

  run bash "$WD"                     # tick 1: alerts + delivers (stub muso exits 0)
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/last-text" ]

  rm -f "$TEST_TMPDIR/last-text"
  run bash "$WD"                     # tick 2: state remembers → quiet, no second post
  [ "$status" -eq 0 ]
  [[ "$output" == *"no caught-up merge is stuck"* ]]
  [ ! -f "$TEST_TMPDIR/last-text" ]
}

@test "unknown flag → exit 2" {
  run bash "$WD" --bogus
  [ "$status" -eq 2 ]
}

# ──────────────────────────────────────────────────────────────
# All-clear (auto-resolve) behaviour: a previously-alerted pair whose loser
# has since landed must post a ✅ notice and drop out of the alerted state,
# so #clio_devops isn't left pointing humans at a merge that already landed
# (2026-06-10/11: six of Jan's merges landed >6h after request — the 🚨 pages
# were stale within a day and nothing said so).
# ──────────────────────────────────────────────────────────────

@test "previously-alerted pair that has landed → ✅ all-clear, key removed from state (dry-run persists)" {
  mergeline 1000 SURV L_LANDED
  printf '%s\n' '["SURV:L_LANDED"]' > "$MERGE_LANDING_STATE_FILE"
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"have now LANDED"* ]]
  [[ "$output" == *"landed after"* ]]
  [[ "$output" == *"L_LANDED"* ]]
  [[ "$output" != *"NOT landed"* ]]               # no stuck block in this tick
  run python3 -c "import json; print('SURV:L_LANDED' in json.load(open('$MERGE_LANDING_STATE_FILE')))"
  [[ "$output" == *"False"* ]]
}

@test "previously-alerted pair still stuck → quiet: no re-page, no ✅" {
  mergeline 1000 SURV L_STUCK
  printf '%s\n' '["SURV:L_STUCK"]' > "$MERGE_LANDING_STATE_FILE"
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"no caught-up merge is stuck"* ]]              # the existing quiet-tick log line
  [[ "$output" != *"have now LANDED"* ]]
  [[ "$output" != *"NOT landed"* ]]
}

@test "✅ all-clear with FAILED Slack delivery → state unchanged, retried next tick" {
  mergeline 1000 SURV L_LANDED
  printf '%s\n' '["SURV:L_LANDED"]' > "$MERGE_LANDING_STATE_FILE"
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"

  printf '#!/bin/bash\nexit 1\n' > "$TEST_TMPDIR/bin/muso"
  chmod +x "$TEST_TMPDIR/bin/muso"
  run bash "$WD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NOT advanced"* ]]
  run python3 -c "import json; print('SURV:L_LANDED' in json.load(open('$MERGE_LANDING_STATE_FILE')))"
  [[ "$output" == *"True"* ]]                     # key kept → ✅ retries next tick
  [ ! -f "${MERGE_LANDING_STATE_FILE}.pending" ]
}

@test "mixed tick: one new stuck + one resolved → single message with both blocks" {
  mergeline 1000 SURV L_STUCK L_LANDED
  printf '%s\n' '["SURV:L_LANDED"]' > "$MERGE_LANDING_STATE_FILE"
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"

  run bash "$WD"
  [ "$status" -eq 0 ]
  # The stubbed muso captures the delivered --text; both blocks must be in it.
  [ -f "$TEST_TMPDIR/last-text" ]
  t="$(cat "$TEST_TMPDIR/last-text")"
  [[ "$t" == *"NOT landed"* && "$t" == *"L_STUCK"* ]]           # stuck block
  [[ "$t" == *"have now LANDED"* && "$t" == *"landed after"* ]] # all-clear block
  # delivered → state now holds the stuck pair, not the resolved one
  run python3 -c "
import json
s = set(json.load(open('$MERGE_LANDING_STATE_FILE')))
print('SURV:L_STUCK' in s)
print('SURV:L_LANDED' in s)
"
  [[ "${lines[0]}" == "True" ]]
  [[ "${lines[1]}" == "False" ]]
}

@test "alerted pair whose audit-log line is GONE (log rotated) still ✅-resolves once landed" {
  : > "$MERGE_LANDING_MERGES_FILE"                 # log rotated: no candidate lines at all
  printf '%s\n' '["SURV:L_LANDED"]' > "$MERGE_LANDING_STATE_FILE"
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"have now LANDED"* ]]
  [[ "$output" == *"L_LANDED"* ]]
  [[ "$output" == *"landed after ?"* ]]            # request ts unknown without the log line
  run python3 -c "import json; print('SURV:L_LANDED' in json.load(open('$MERGE_LANDING_STATE_FILE')))"
  [[ "$output" == *"False"* ]]
}

@test "alerted pair gone from audit log but loser STILL stuck → kept in state, no ✅, no re-page" {
  : > "$MERGE_LANDING_MERGES_FILE"
  printf '%s\n' '["SURV:L_STUCK"]' > "$MERGE_LANDING_STATE_FILE"
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"have now LANDED"* ]]
  [[ "$output" != *"NOT landed"* ]]
  run python3 -c "import json; print('SURV:L_STUCK' in json.load(open('$MERGE_LANDING_STATE_FILE')))"
  [[ "$output" == *"True"* ]]
}

@test "stuck alert goes to #clio_devops as devops bot with the stuck pair in the text" {
  mergeline 1000 SURV L_STUCK
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"
  run bash "$WD"   # NOT dry-run → exercises slack_notify_payload_file_status → stubbed muso
  [ "$status" -eq 0 ]
  grep -q -- '--bot devops' "$STUB_CALLS"
  grep -q -- '--channel C0ADV2W76G4' "$STUB_CALLS"
  grep -q -- '--requester' "$STUB_CALLS"
  [ -f "$TEST_TMPDIR/last-text" ]
  grep -q 'L_STUCK' "$TEST_TMPDIR/last-text"
}
