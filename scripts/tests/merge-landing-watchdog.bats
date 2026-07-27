#!/usr/bin/env bats
# Tests for scripts/merge-landing-watchdog.sh — the stuck-merge alerter added
# after the 2026-06-08/09 Jan ↔ Ops threads where two profile merges returned
# HTTP 200 four times over days and never landed in the catalog.
#
# PATH-shadows muso + ssh so a real Slack send / remote call during a test
# fails loudly instead of paging #clio_devops for real
# (see memory/feedback_bats_must_stub_openclaw.md). The live catalog API read is
# redirected to a stub via MERGE_LANDING_CATALOG_CMD — no real network call.
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

  # Catalog stub: emits the real admin profile-list response shape. Unknown ids
  # default to active/unmerged; L_LANDED is folded into SURV.
  cat > "$TEST_TMPDIR/bin/catalog-stub" <<'STUB'
#!/usr/bin/env python3
import json, sys
ids = [arg.split("=", 1)[1] for arg in sys.argv[1:] if arg.startswith("ids=")]
items = []
for profile_id in ids:
    if profile_id == "L_LANDED":
        items.append({"id": profile_id, "merged": {"mergedToId": "SURV"}, "deleted": {"date": "2026-01-01"}})
    else:
        items.append({"id": profile_id, "merged": None, "deleted": None})
print(json.dumps({"data": {"totalCount": len(items), "limit": len(items), "offset": 0, "items": items}}))
STUB
  chmod +x "$TEST_TMPDIR/bin/catalog-stub"

  export MERGE_LANDING_MERGES_FILE="$TEST_TMPDIR/recent-merges.jsonl"
  export MERGE_LANDING_STATE_FILE="$TEST_TMPDIR/state.json"
  export MERGE_LANDING_LOCKFILE="$TEST_TMPDIR/wd.lock"
  export MERGE_LANDING_CATALOG_CMD="$TEST_TMPDIR/bin/catalog-stub"
  export MERGE_LANDING_CATALOG_BATCH_SIZE=40
  export MERGE_LANDING_SKIP_HOST_GUARD=1
  export MERGE_LANDING_MIN_AGE_HOURS=6
  # Pin "now" so age math is deterministic. ts=1000 below is ~277h before this.
  export MERGE_LANDING_NOW_EPOCH=1001000

  # Production-shaped ids for the branches where id SHAPE is what is under test.
  # UUID_MISSING: well-formed but absent from the catalog → stuck.
  # UUID_MALFORMED: 7 hex in group 1 (35 chars) — the real 2026-07-27 typo that
  # re-alerted for ~1310h because it can never match a catalog row.
  export UUID_MISSING="11111111-2222-4333-8444-555555555555"
  export UUID_MALFORMED="652996f-d521-48bb-97b0-dec38cdd508a"
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

# The muso CLI records its merges in its own state file, not the wrapper's
# /var/log/muso-ops log (split-brain found 2026-07-24: a CLI-submitted merge was
# invisible to the watchdog). MERGE_LANDING_MERGES_FILE is a colon-separated
# list so both feeds are ingested.

@test "colon-list: merge only in the CLI state file is still detected" {
  export MERGE_LANDING_MERGES_FILE="$TEST_TMPDIR/recent-merges.jsonl:$TEST_TMPDIR/cli-merges.jsonl"
  printf '{"epoch":1000,"method":"POST","path":"/admin/profiles/merge","mergeInto":"SURV","profilesIds":["L_CLI"],"requester":"nick@muso.ai"}\n' \
    > "$TEST_TMPDIR/cli-merges.jsonl"
  # primary wrapper log does not exist at all
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"accepted but NOT landed"* ]]
  [[ "$output" == *"L_CLI"* ]]
}

@test "colon-list: same pair in both feeds dedupes to one candidate" {
  mergeline 2000 SURV L_STUCK   # writes to the primary feed (still the single default path)
  export MERGE_LANDING_MERGES_FILE="$TEST_TMPDIR/recent-merges.jsonl:$TEST_TMPDIR/cli-merges.jsonl"
  printf '{"epoch":1000,"method":"POST","path":"/admin/profiles/merge","mergeInto":"SURV","profilesIds":["L_STUCK"],"requester":"nick@muso.ai"}\n' \
    > "$TEST_TMPDIR/cli-merges.jsonl"
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"accepted but NOT landed"* ]]
  # exactly one bullet for the pair, not two
  [ "$(printf '%s\n' "$output" | grep -c 'L_STUCK')" -eq 1 ]
}

@test "colon-list: SKIP only when every listed feed is missing" {
  export MERGE_LANDING_MERGES_FILE="$TEST_TMPDIR/absent-a.jsonl:$TEST_TMPDIR/absent-b.jsonl"
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

@test "catalog state comes from the live admin profile API, never Trino" {
  mergeline 1000 SURV L_STUCK
  cat > "$TEST_TMPDIR/bin/live-catalog-stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
cat <<'JSON'
{"data":{"totalCount":2,"limit":2,"offset":0,"items":[{"id":"SURV","merged":null,"deleted":null},{"id":"L_STUCK","merged":null,"deleted":null}]}}
JSON
STUB
  chmod +x "$TEST_TMPDIR/bin/live-catalog-stub"
  export MERGE_LANDING_CATALOG_CMD="$TEST_TMPDIR/bin/live-catalog-stub"
  # Prove the obsolete path cannot be used accidentally.
  export MERGE_LANDING_TRINO_CMD="$TEST_TMPDIR/bin/does-not-exist"

  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"accepted but NOT landed"* ]]
  grep -q -- '--env prod --json api GET /admin/profile' "$STUB_CALLS"
  ! grep -q 'matvw_catalog_profile' "$STUB_CALLS"
}

@test "watchdog source contains no V3 table, materialized-view, or watermark fallback" {
  run grep -Ei 'profile_v3|_v3|matvw_catalog_profile|query_watermark|MERGE_LANDING_CATALOG_TABLE' "$WD"
  [ "$status" -eq 1 ]
}

@test "production catalog command uses an absolute cron-safe path" {
  grep -Fq 'CATALOG_CMD="${MERGE_LANDING_CATALOG_CMD:-/usr/local/bin/muso}"' "$WD"
}

@test "large id sets are split into bounded live-catalog requests" {
  mergeline 1000 SURV L_STUCK L_LANDED
  cat > "$TEST_TMPDIR/bin/catalog-recording" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
exec "$TEST_TMPDIR/bin/catalog-stub" "$@"
STUB
  chmod +x "$TEST_TMPDIR/bin/catalog-recording"
  export MERGE_LANDING_CATALOG_CMD="$TEST_TMPDIR/bin/catalog-recording"
  export MERGE_LANDING_CATALOG_BATCH_SIZE=2

  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [ "$(grep -c -- '--env prod --json api GET /admin/profile' "$STUB_CALLS")" -eq 2 ]
  [[ "$output" == *"L_STUCK"* ]]
  [[ "$output" != *"loser \`L_LANDED\`"* ]]
}

@test "aged merge that DID land (loser merged_to_id set) → no alert" {
  mergeline 1000 SURV L_LANDED
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"no aged merge is unresolved"* ]]
}

@test "fresh merge (younger than MIN_AGE_HOURS) → not yet checked, no alert" {
  # 1h before now → inside the 6h grace window.
  mergeline $((1001000 - 3600)) SURV L_STUCK
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"no merges older than"* ]]
}

# ──────────────────────────────────────────────────────────────
# ──────────────────────────────────────────────────────────────

@test "stuck alert wording is verify + re-fire, never 'manual merge'" {
  mergeline 1000 SURV L_STUCK
  run bash "$WD" --dry-run
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
  cat > "$TEST_TMPDIR/bin/catalog-flip" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '{"data":{"items":[{"id":"FLOSER","merged":null,"deleted":null},{"id":"FSURV","merged":{"mergedToId":"FLOSER"},"deleted":{"date":"2026-01-01"}}]}}'
STUB
  chmod +x "$TEST_TMPDIR/bin/catalog-flip"
  export MERGE_LANDING_CATALOG_CMD="$TEST_TMPDIR/bin/catalog-flip"
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"NOT landed"* ]]
  [[ "$output" != *"FLOSER"* ]]
  [[ "$output" == *"no aged merge is unresolved"* ]]
}

# Loser folded somewhere other than the requested survivor, survivor untouched.
# Still unresolved — but reported as PARTIALLY FOLDED rather than the ordinary
# "verify + re-fire" page, because re-firing this state can damage the survivor.
@test "loser merged to a different profile remains unresolved" {
  mergeline 1000 SURV L_WRONG
  cat > "$TEST_TMPDIR/bin/catalog-wrong-target" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"data":{"items":[{"id":"SURV","merged":null,"deleted":null},{"id":"L_WRONG","merged":{"mergedToId":"OTHER"},"deleted":{"date":"2026-01-01"}}]}}'
STUB
  chmod +x "$TEST_TMPDIR/bin/catalog-wrong-target"
  export MERGE_LANDING_CATALOG_CMD="$TEST_TMPDIR/bin/catalog-wrong-target"

  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"PARTIALLY FOLDED"* ]]
  [[ "$output" == *"Do NOT re-fire"* ]]
  [[ "$output" == *"L_WRONG"* ]]
  [[ "$output" != *"no aged merge is unresolved"* ]]
}

# A well-formed id that is simply absent from the catalog is STUCK. The id must
# be UUID-shaped: a malformed id is a different verdict (see the malformed-id
# test below), so using a synthetic short id here would silently test the wrong
# branch.
@test "missing loser is unresolved, never silently treated as landed" {
  mergeline 1000 SURV "$UUID_MISSING"
  cat > "$TEST_TMPDIR/bin/catalog-missing-loser" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"data":{"items":[{"id":"SURV","merged":null,"deleted":null}]}}'
STUB
  chmod +x "$TEST_TMPDIR/bin/catalog-missing-loser"
  export MERGE_LANDING_CATALOG_CMD="$TEST_TMPDIR/bin/catalog-missing-loser"

  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"accepted but NOT landed"* ]]
  [[ "$output" == *"$UUID_MISSING"* ]]
}

@test "valid empty catalog result leaves both missing profiles unresolved" {
  mergeline 1000 SURV "$UUID_MISSING"
  cat > "$TEST_TMPDIR/bin/catalog-empty-list" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"data":{"items":[]}}'
STUB
  chmod +x "$TEST_TMPDIR/bin/catalog-empty-list"
  export MERGE_LANDING_CATALOG_CMD="$TEST_TMPDIR/bin/catalog-empty-list"

  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"accepted but NOT landed"* ]]
  [[ "$output" == *"$UUID_MISSING"* ]]
}

# ── verdict classes beyond stuck/landed (added 2026-07-27) ──────────────────
# The classifier used to return a bare boolean, so "never processed",
# "half folded" and "malformed id" all rendered as the same red page — and the
# latter two re-alerted forever because they can never resolve. Each now has
# its own verdict and its own operator instruction.

@test "malformed loser id → MALFORMED block, not the generic stuck page" {
  mergeline 1000 SURV "$UUID_MALFORMED"
  # Real API behaviour: an id that cannot exist is simply absent from items.
  cat > "$TEST_TMPDIR/bin/catalog-omits-unknown" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"data":{"items":[{"id":"SURV","merged":null,"deleted":null}]}}'
STUB
  chmod +x "$TEST_TMPDIR/bin/catalog-omits-unknown"
  export MERGE_LANDING_CATALOG_CMD="$TEST_TMPDIR/bin/catalog-omits-unknown"

  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"MALFORMED id"* ]]
  [[ "$output" == *"$UUID_MALFORMED"* ]]
  [[ "$output" != *"accepted but NOT landed"* ]]
}

@test "loser AND survivor collapsed onto a third canonical → landed, not stuck" {
  mergeline 1000 SURV L_COLLAPSED
  # Superseding merge: both sides folded into THIRD 16 min later. Dedup intent
  # satisfied — this must never page. (Live: 210ebd26/4c2ad26b + c1f6b21d →
  # 4e675b56, which alerted every tick for 326h under the old classifier.)
  cat > "$TEST_TMPDIR/bin/catalog-collapsed" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"data":{"items":[
  {"id":"L_COLLAPSED","merged":{"mergedToId":"THIRD"},"deleted":{"date":"2026-01-01"}},
  {"id":"SURV","merged":{"mergedToId":"THIRD"},"deleted":{"date":"2026-01-01"}}]}}'
STUB
  chmod +x "$TEST_TMPDIR/bin/catalog-collapsed"
  export MERGE_LANDING_CATALOG_CMD="$TEST_TMPDIR/bin/catalog-collapsed"

  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"L_COLLAPSED"* ]]
  [[ "$output" != *"accepted but NOT landed"* ]]
}

@test "partially-folded pair does not auto-resolve on a later tick" {
  # It is not landed, so the ✅ all-clear must never fire for it — otherwise the
  # channel would tell humans a damaged-state merge was fine.
  printf '%s\n' '["SURV:L_PARTIAL"]' > "$MERGE_LANDING_STATE_FILE"
  mergeline 1000 SURV L_PARTIAL
  cat > "$TEST_TMPDIR/bin/catalog-partial2" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"data":{"items":[
  {"id":"L_PARTIAL","merged":{"mergedToId":"OTHER"},"deleted":{"date":"2026-01-01"}},
  {"id":"SURV","merged":null,"deleted":null}]}}'
STUB
  chmod +x "$TEST_TMPDIR/bin/catalog-partial2"
  export MERGE_LANDING_CATALOG_CMD="$TEST_TMPDIR/bin/catalog-partial2"

  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"landed after"* ]]
  [[ "$output" != *"have now LANDED"* ]]
}

# ── queue attribution (added 2026-07-27) ────────────────────────────────────
# A never-landed merge is either still queued (wait) or was deleted by topic
# retention (it will NEVER land — rebuild from the audit trail). Telling an
# operator to wait for a message that no longer exists is the exact wrong call,
# so the bullet must say which. The probe is best-effort and MUST fail open.

# Fake kubectl: `get pods` names a broker, `rpk group describe` emits the real
# table shape, `rpk topic consume -f %d` emits the oldest retained timestamp in
# ms. $QUEUE_STUB_TS_MS controls the retention frontier.
_queue_stub() { # $1 oldest-retained-ms
  cat > "$TEST_TMPDIR/bin/kubectl-stub" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    consume) echo "$1"; exit 0 ;;
    describe) printf '%s\n' "TOTAL-LAG                4242" \\
                "industry-proc-catalog-admin-prod  0  161717  86085  182534  20817"; exit 0 ;;
  esac
done
case "\$1" in get) echo "pod/redpanda-v2-0"; exit 0 ;; esac
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/kubectl-stub"
  export MERGE_LANDING_QUEUE_PROBE_CMD="$TEST_TMPDIR/bin/kubectl-stub"
}

@test "queue probe: request older than the retention frontier → msg GONE" {
  mergeline 1000 SURV L_STUCK          # request ts=1000
  _queue_stub 2000000                  # frontier = 2000s > 1000 → deleted
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"accepted but NOT landed"* ]]
  [[ "$output" == *"msg GONE (past retention"* ]]
  [[ "$output" != *"presence UNCONFIRMED"* ]]
}

@test "queue probe: request newer than the frontier → in-window, presence UNCONFIRMED" {
  mergeline 1000 SURV L_STUCK          # request ts=1000
  _queue_stub 500000                   # frontier = 500s < 1000 → still retained
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"in retention window, presence UNCONFIRMED (lane 4242 behind)"* ]]
  [[ "$output" != *"msg GONE"* ]]
}

@test "queue probe failure degrades to a plain stuck page, never suppresses it" {
  mergeline 1000 SURV L_STUCK
  cat > "$TEST_TMPDIR/bin/kubectl-broken" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$TEST_TMPDIR/bin/kubectl-broken"
  export MERGE_LANDING_QUEUE_PROBE_CMD="$TEST_TMPDIR/bin/kubectl-broken"

  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"accepted but NOT landed"* ]]
  [[ "$output" == *"L_STUCK"* ]]
  [[ "$output" == *"queue probe unavailable"* ]]
  [[ "$output" != *"msg GONE"* ]]
  [[ "$output" != *"presence UNCONFIRMED"* ]]
}

@test "queue probe is skipped entirely when disabled" {
  mergeline 1000 SURV L_STUCK
  export MERGE_LANDING_QUEUE_PROBE=0
  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"accepted but NOT landed"* ]]
  [[ "$output" != *"queue probe"* ]]
}

@test "queue attribution never appears on partial or malformed verdicts" {
  # Those are not queue questions — a half-folded merge already ran.
  mergeline 1000 SURV L_WRONG2
  _queue_stub 2000000
  cat > "$TEST_TMPDIR/bin/catalog-partial3" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"data":{"items":[
  {"id":"L_WRONG2","merged":{"mergedToId":"OTHER"},"deleted":{"date":"2026-01-01"}},
  {"id":"SURV","merged":null,"deleted":null}]}}'
STUB
  chmod +x "$TEST_TMPDIR/bin/catalog-partial3"
  export MERGE_LANDING_CATALOG_CMD="$TEST_TMPDIR/bin/catalog-partial3"

  run bash "$WD" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"PARTIALLY FOLDED"* ]]
  [[ "$output" != *"msg GONE"* ]]
  [[ "$output" != *"presence UNCONFIRMED"* ]]
}

@test "catalog query returns EMPTY rows (silent failure) → BLIND, exit 1" {
  mergeline 1000 SURV L_STUCK
  # Stub exits 0 but emits nothing for the id query → must be treated as BLIND,
  # never as "everything landed" (which would hide real drops).
  cat > "$TEST_TMPDIR/bin/catalog-empty" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/catalog-empty"
  export MERGE_LANDING_CATALOG_CMD="$TEST_TMPDIR/bin/catalog-empty"
  run bash "$WD" --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"live catalog API query failed"* ]]
  [[ "$output" == *"BLIND"* ]]
  [[ "$output" != *"no aged merge is unresolved"* ]]
}

@test "unexpected live-catalog shape fails loud instead of reporting healthy" {
  mergeline 1000 SURV L_BAD
  cat > "$TEST_TMPDIR/bin/catalog-bad-shape" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"data":{"items":[{"id":"SURV","merged":null,"deleted":null},{"id":"L_BAD","merged":"not-an-object","deleted":null}]}}'
STUB
  chmod +x "$TEST_TMPDIR/bin/catalog-bad-shape"
  export MERGE_LANDING_CATALOG_CMD="$TEST_TMPDIR/bin/catalog-bad-shape"

  run bash "$WD" --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"detector classification failed"* ]]
  [[ "$output" == *"BLIND"* ]]
  [[ "$output" != *"no aged merge is unresolved"* ]]
}

@test "classification failure BLIND page is deduped across real ticks" {
  mergeline 1000 SURV L_BAD
  cat > "$TEST_TMPDIR/bin/catalog-bad-shape" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"data":{"items":[{"id":"SURV","merged":null,"deleted":null},{"id":"L_BAD","merged":"not-an-object","deleted":null}]}}'
STUB
  chmod +x "$TEST_TMPDIR/bin/catalog-bad-shape"
  export MERGE_LANDING_CATALOG_CMD="$TEST_TMPDIR/bin/catalog-bad-shape"
  echo 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test' > "$MUSO_SLACK_ENV_FILE"

  run bash "$WD"
  [ "$status" -eq 1 ]
  [ "$(grep -c -- 'slack send' "$STUB_CALLS")" -eq 1 ]

  run bash "$WD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"already paged within"* ]]
  [ "$(grep -c -- 'slack send' "$STUB_CALLS")" -eq 1 ]
}

@test "dedupe: a stuck pair alerts once, not again on the next tick" {
  mergeline 1000 SURV L_STUCK
  run bash "$WD" --dry-run
  [[ "$output" == *"L_STUCK"* ]]            # first tick alerts
  run bash "$WD" --dry-run
  [[ "$output" == *"no aged merge is unresolved"* ]]        # second tick is quiet (state remembers)
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
  # Live catalog API stub that fails.
  printf '#!/usr/bin/env bash\nexit 7\n' > "$TEST_TMPDIR/bin/catalog-fail"
  chmod +x "$TEST_TMPDIR/bin/catalog-fail"
  export MERGE_LANDING_CATALOG_CMD="$TEST_TMPDIR/bin/catalog-fail"
  run bash "$WD" --dry-run
  # A blind tick must NOT masquerade as a healthy "landed" run.
  [ "$status" -eq 1 ]
  [[ "$output" == *"live catalog API query failed"* ]]
  [[ "$output" == *"BLIND"* ]]
  [[ "$output" != *"no aged merge is unresolved"* ]]
}

@test "catalog query failure (real run) → pages #clio_devops BLIND, exit 1, deduped" {
  mergeline 1000 SURV L_STUCK
  printf '#!/usr/bin/env bash\nexit 7\n' > "$TEST_TMPDIR/bin/catalog-fail"
  chmod +x "$TEST_TMPDIR/bin/catalog-fail"
  export MERGE_LANDING_CATALOG_CMD="$TEST_TMPDIR/bin/catalog-fail"
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
  [[ "$output" == *"no aged merge is unresolved"* ]]
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
  [[ "$output" == *"no aged merge is unresolved"* ]]              # the existing quiet-tick log line
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
