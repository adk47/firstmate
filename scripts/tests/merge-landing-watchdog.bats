#!/usr/bin/env bats
# Tests for scripts/merge-landing-watchdog.sh — the stuck-merge alerter added
# after the 2026-06-08/09 Jan ↔ Ops threads where two profile merges returned
# HTTP 200 four times over days and never landed in the catalog.
#
# PATH-shadows curl + ssh so a real Slack POST / remote call during a test
# fails loudly instead of paging #clio_devops for real
# (see memory/feedback_bats_must_stub_openclaw.md). The catalog query is
# redirected to a stub via MERGE_LANDING_TRINO_CMD — no real Trino/kubectl.
# Behavioural assertions use --dry-run; the payload-escaping test runs the real
# post path against a stubbed curl that captures the JSON body.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
WD="$HYDRA_REPO/scripts/merge-landing-watchdog.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin"

  # Refuse real network: stub curl + ssh.
  cat > "$TEST_TMPDIR/bin/ssh" <<'STUB'
#!/bin/bash
echo "test stub: ssh refused ($*)" >&2; exit 99
STUB
  # curl stub: capture the --data-binary @<file> payload for inspection and
  # emit Slack's success body so _slack_post_payload's ok:true check passes.
  cat > "$TEST_TMPDIR/bin/curl" <<'STUB'
#!/bin/bash
for a in "$@"; do
  case "$a" in
    @*) cp "${a#@}" "$MERGE_LANDING_TEST_CAPTURE" 2>/dev/null ;;
  esac
done
echo '{"ok":true}'
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/ssh" "$TEST_TMPDIR/bin/curl"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH

  # Catalog stub: pattern-matches the loser id in the IN-list SQL and emits the
  # quoted "_id","merged_to_id","is_deleted" rows trino-query.sh would return
  # (data rows only, no header). STUCK = "<id>","","false". By default L_STUCK
  # is stuck, L_LANDED is merged, SURV is the active survivor.
  cat > "$TEST_TMPDIR/bin/trino-stub.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
q="${1:-}"
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
  [[ "$output" == *"have landed"* ]]
}

@test "fresh merge (younger than MIN_AGE_HOURS) → not yet checked, no alert" {
  # 1h before now → inside the 6h grace window.
  mergeline $((1001000 - 3600)) SURV L_STUCK
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"no merges older than"* ]]
}

@test "dedupe: a stuck pair alerts once, not again on the next tick" {
  mergeline 1000 SURV L_STUCK
  run bash "$WD" --dry-run
  [[ "$output" == *"L_STUCK"* ]]            # first tick alerts
  run bash "$WD" --dry-run
  [[ "$output" == *"have landed"* ]]        # second tick is quiet (state remembers)
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
  [[ "$output" != *"have landed"* ]]
}

@test "catalog query failure (real run) → pages #clio_devops BLIND, exit 1, deduped" {
  mergeline 1000 SURV L_STUCK
  printf '#!/usr/bin/env bash\nexit 7\n' > "$TEST_TMPDIR/bin/trino-fail.sh"
  chmod +x "$TEST_TMPDIR/bin/trino-fail.sh"
  export MERGE_LANDING_TRINO_CMD="$TEST_TMPDIR/bin/trino-fail.sh"
  printf '%s\n' '{"channels":{"slack":{"accounts":{"devops":{"botToken":"xoxb-test"}}}}}' \
    > "$TEST_TMPDIR/slack.json"
  export MERGE_LANDING_SLACK_CONFIG="$TEST_TMPDIR/slack.json"
  export MERGE_LANDING_TEST_CAPTURE="$TEST_TMPDIR/blind-payload.json"

  run bash "$WD"
  [ "$status" -eq 1 ]
  [ -f "$MERGE_LANDING_TEST_CAPTURE" ]            # it actually paged
  run python3 -c "import json; print('BLIND' in json.load(open('$MERGE_LANDING_TEST_CAPTURE'))['text'])"
  [[ "$output" == *"True"* ]]

  # Second tick inside the cooldown must NOT re-page (no new capture), still exit 1.
  rm -f "$MERGE_LANDING_TEST_CAPTURE"
  run bash "$WD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"already paged within"* ]]
  [ ! -f "$MERGE_LANDING_TEST_CAPTURE" ]
}

@test "failed Slack delivery does NOT dedupe → next tick re-pages the same stuck pair" {
  mergeline 1000 SURV L_STUCK
  printf '%s\n' '{"channels":{"slack":{"accounts":{"devops":{"botToken":"xoxb-test"}}}}}' \
    > "$TEST_TMPDIR/slack.json"
  export MERGE_LANDING_SLACK_CONFIG="$TEST_TMPDIR/slack.json"
  export MERGE_LANDING_TEST_CAPTURE="$TEST_TMPDIR/cap.json"

  # Tick 1: curl FAILS → delivery not confirmed → state must not advance.
  printf '#!/bin/bash\nexit 1\n' > "$TEST_TMPDIR/bin/curl"
  chmod +x "$TEST_TMPDIR/bin/curl"
  run bash "$WD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NOT advanced"* ]]
  [ ! -f "$MERGE_LANDING_STATE_FILE" ]            # nothing deduped
  [ ! -f "${MERGE_LANDING_STATE_FILE}.pending" ]  # staging cleaned up

  # Tick 2: curl SUCCEEDS (ok:true) + captures → the same pair must alert again.
  cat > "$TEST_TMPDIR/bin/curl" <<'STUB'
#!/bin/bash
for a in "$@"; do case "$a" in @*) cp "${a#@}" "$MERGE_LANDING_TEST_CAPTURE" 2>/dev/null ;; esac; done
echo '{"ok":true}'
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/curl"
  run bash "$WD"
  [ "$status" -eq 0 ]
  [ -f "$MERGE_LANDING_TEST_CAPTURE" ]
  run python3 -c "import json; print('L_STUCK' in json.load(open('$MERGE_LANDING_TEST_CAPTURE'))['text'])"
  [[ "$output" == *"True"* ]]
}

@test "Slack 200 with ok:false → NOT confirmed → dedupe not advanced, exit 1" {
  mergeline 1000 SURV L_STUCK
  printf '%s\n' '{"channels":{"slack":{"accounts":{"devops":{"botToken":"xoxb-test"}}}}}' \
    > "$TEST_TMPDIR/slack.json"
  export MERGE_LANDING_SLACK_CONFIG="$TEST_TMPDIR/slack.json"

  # HTTP 200 but application-level failure: curl -f stays 0, body says ok:false.
  cat > "$TEST_TMPDIR/bin/curl" <<'STUB'
#!/bin/bash
echo '{"ok":false,"error":"not_in_channel"}'
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/curl"
  run bash "$WD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NOT advanced"* ]]
  [ ! -f "$MERGE_LANDING_STATE_FILE" ]            # pair not deduped → retried
  [ ! -f "${MERGE_LANDING_STATE_FILE}.pending" ]  # staging cleaned up
}

@test "successful delivery advances dedupe → next real tick is quiet" {
  mergeline 1000 SURV L_STUCK
  printf '%s\n' '{"channels":{"slack":{"accounts":{"devops":{"botToken":"xoxb-test"}}}}}' \
    > "$TEST_TMPDIR/slack.json"
  export MERGE_LANDING_SLACK_CONFIG="$TEST_TMPDIR/slack.json"
  export MERGE_LANDING_TEST_CAPTURE="$TEST_TMPDIR/cap.json"

  run bash "$WD"                     # tick 1: alerts + delivers (stub curl exits 0)
  [ "$status" -eq 0 ]
  [ -f "$MERGE_LANDING_TEST_CAPTURE" ]

  rm -f "$MERGE_LANDING_TEST_CAPTURE"
  run bash "$WD"                     # tick 2: state remembers → quiet, no second post
  [ "$status" -eq 0 ]
  [[ "$output" == *"have landed"* ]]
  [ ! -f "$MERGE_LANDING_TEST_CAPTURE" ]
}

@test "unknown flag → exit 2" {
  run bash "$WD" --bogus
  [ "$status" -eq 2 ]
}

@test "stuck alert posts a VALID JSON payload (escaping guard)" {
  mergeline 1000 SURV L_STUCK
  printf '%s\n' '{"channels":{"slack":{"accounts":{"devops":{"botToken":"xoxb-test"}}}}}' \
    > "$TEST_TMPDIR/slack.json"
  export MERGE_LANDING_SLACK_CONFIG="$TEST_TMPDIR/slack.json"
  export MERGE_LANDING_TEST_CAPTURE="$TEST_TMPDIR/captured-payload.json"
  run bash "$WD"   # NOT dry-run → exercises slack_notify_payload_file → stubbed curl
  [ "$status" -eq 0 ]
  [ -f "$MERGE_LANDING_TEST_CAPTURE" ]
  run python3 -m json.tool "$MERGE_LANDING_TEST_CAPTURE"
  [ "$status" -eq 0 ]
  run python3 -c "import json; d=json.load(open('$MERGE_LANDING_TEST_CAPTURE')); print(d['channel']); print('L_STUCK' in d['text'])"
  [[ "$output" == *"C0ADV2W76G4"* ]]
  [[ "$output" == *"True"* ]]
}
