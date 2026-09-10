#!/usr/bin/env bats
# Tests for scripts/lib/detect-store-only-crons.py — the Step 5a guard that
# refuses to let a deploy silently delete a live-created cron.
#
# The 2026-09-10 8.2 cutover added a second class of store-only cron that the
# original guard could not distinguish from human work: openclaw 2026.8.2
# DECLARES crons from config at boot (heartbeat:<agent>, skill-collection-review:
# <agent>, memory-core:memory-dreaming-promotion). They carry a `declarationKey`,
# their UUIDs are REGENERATED on every boot, and they are therefore impossible to
# commit to cron-jobs.json — so the guard refused every deploy forever
# (observed: "loaded 44, repo declares 33", 11 unexpected, 0 missing).
#
# The discriminator is an ALLOWLIST of the namespaces openclaw itself declares
# (heartbeat:, heartbeat-task:, skill-collection-review:, and the exact key
# memory-core:memory-dreaming-promotion), NOT "carries any declarationKey":
# `openclaw cron add --declaration-key <key>` exists, and the runtime refuses
# only its two system-owned prefixes, so an operator CAN key a durable cron
# `custom:billing`. Exempting that would delete it on the next import — the very
# incident this guard exists for (2026-07-16, Aaron's ChartMogul crons, PR #702).
# These tests pin BOTH directions: the runtime rows are ignored, and every other
# store-only recurring job — custom key or none — is still refused.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
DETECT="$HYDRA_REPO/scripts/lib/detect-store-only-crons.py"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  REPO_JSON="$TEST_TMPDIR/cron-jobs.json"
  STORE_JSON="$TEST_TMPDIR/store.json"
  # The repo declares exactly one job, by id.
  printf '%s\n' '{"jobs":[{"id":"repo-1","name":"declared","schedule":{"kind":"every","everyMs":3600000}}]}' > "$REPO_JSON"
  unset HYDRA_ALLOW_ORPHAN_CRON
}

teardown() { rm -rf "$TEST_TMPDIR"; }

store() { printf '%s\n' "$1" > "$STORE_JSON"; }

@test "a runtime-DECLARED store-only cron is ignored (8.2 heartbeat / skill-review)" {
  store '{"jobs":[
    {"id":"repo-1","name":"declared","schedule":{"kind":"every","everyMs":3600000}},
    {"id":"boot-uuid-a","name":"heartbeat-clio","declarationKey":"heartbeat:clio","payload":{"kind":"heartbeat"},"schedule":{"kind":"every","everyMs":1800000}},
    {"id":"boot-uuid-b","name":"skill-collection-review-ceo","declarationKey":"skill-collection-review:ceo","payload":{"kind":"skillCollectionReview"},"schedule":{"kind":"every","everyMs":86400000}}
  ]}'
  run python3 "$DETECT" "$REPO_JSON" "$STORE_JSON"
  [ "$status" -eq 0 ]
}

@test "a HUMAN-created orphan is STILL refused (the ChartMogul incident)" {
  store '{"jobs":[
    {"id":"repo-1","name":"declared","schedule":{"kind":"every","everyMs":3600000}},
    {"id":"hand-made","name":"chartmogul-mrr","schedule":{"kind":"every","everyMs":3600000}}
  ]}'
  run python3 "$DETECT" "$REPO_JSON" "$STORE_JSON"
  [ "$status" -eq 3 ]
  [[ "$output" == *"chartmogul-mrr"* ]]
}

@test "an EMPTY declarationKey is NOT a runtime declaration — still refused (fail closed)" {
  store '{"jobs":[{"id":"repo-1","schedule":{"kind":"every","everyMs":3600000}},
                  {"id":"ambiguous","name":"blank-key","declarationKey":"","schedule":{"kind":"every","everyMs":3600000}}]}'
  run python3 "$DETECT" "$REPO_JSON" "$STORE_JSON"
  [ "$status" -eq 3 ]
  [[ "$output" == *"blank-key"* ]]
}

@test "a WHITESPACE-only declarationKey is NOT a runtime declaration — still refused" {
  store '{"jobs":[{"id":"repo-1","schedule":{"kind":"every","everyMs":3600000}},
                  {"id":"ambiguous","name":"ws-key","declarationKey":"   ","schedule":{"kind":"every","everyMs":3600000}}]}'
  run python3 "$DETECT" "$REPO_JSON" "$STORE_JSON"
  [ "$status" -eq 3 ]
}

@test "a NON-STRING declarationKey is NOT a runtime declaration — still refused" {
  store '{"jobs":[{"id":"repo-1","schedule":{"kind":"every","everyMs":3600000}},
                  {"id":"ambiguous","name":"num-key","declarationKey":7,"schedule":{"kind":"every","everyMs":3600000}}]}'
  run python3 "$DETECT" "$REPO_JSON" "$STORE_JSON"
  [ "$status" -eq 3 ]
}

# QA finding (PR #924): the exemption must be an allowlist of runtime-owned
# namespaces, not "any nonblank string". `openclaw cron add --declaration-key`
# is a real flag and the runtime rejects only heartbeat-task: and
# skill-collection-review:, so a custom key is an OPERATOR cron and must keep
# every bit of its protection.
@test "a CUSTOM declarationKey is operator work, NOT a runtime declaration — still refused" {
  store '{"jobs":[{"id":"repo-1","schedule":{"kind":"every","everyMs":3600000}},
                  {"id":"human","name":"billing-cron","declarationKey":"custom:billing","schedule":{"kind":"every","everyMs":3600000}}]}'
  run python3 "$DETECT" "$REPO_JSON" "$STORE_JSON"
  [ "$status" -eq 3 ]
  [[ "$output" == *"billing-cron"* ]]
}

@test "a key merely CONTAINING a runtime namespace is not exempt (prefix, not substring)" {
  store '{"jobs":[{"id":"repo-1","schedule":{"kind":"every","everyMs":3600000}},
                  {"id":"human","name":"sneaky","declarationKey":"custom:heartbeat:clio","schedule":{"kind":"every","everyMs":3600000}}]}'
  run python3 "$DETECT" "$REPO_JSON" "$STORE_JSON"
  [ "$status" -eq 3 ]
  [[ "$output" == *"sneaky"* ]]
}

@test "the memory-core key is exact — a near-miss in that namespace is still refused" {
  store '{"jobs":[{"id":"repo-1","schedule":{"kind":"every","everyMs":3600000}},
                  {"id":"human","name":"near-miss","declarationKey":"memory-core:something-else","schedule":{"kind":"every","everyMs":3600000}}]}'
  run python3 "$DETECT" "$REPO_JSON" "$STORE_JSON"
  [ "$status" -eq 3 ]
  [[ "$output" == *"near-miss"* ]]
}

# QA finding round 2 (PR #924): `heartbeat:` is NOT one of the runtime's
# system-owned prefixes, so `cron add --declaration-key heartbeat:billing` is a
# legal OPERATOR action. The namespace alone must therefore not exempt it — the
# runtime payload invariant is the non-forgeable half.
@test "a FORGED heartbeat: key with an operator payload is still refused" {
  store '{"jobs":[{"id":"repo-1","schedule":{"kind":"every","everyMs":3600000}},
                  {"id":"human","name":"billing-hb","declarationKey":"heartbeat:billing","payload":{"kind":"agentTurn","message":"run billing"},"schedule":{"kind":"every","everyMs":3600000}}]}'
  run python3 "$DETECT" "$REPO_JSON" "$STORE_JSON"
  [ "$status" -eq 3 ]
  [[ "$output" == *"billing-hb"* ]]
}

@test "a heartbeat: key with NO payload at all is still refused" {
  store '{"jobs":[{"id":"repo-1","schedule":{"kind":"every","everyMs":3600000}},
                  {"id":"human","name":"no-payload","declarationKey":"heartbeat:x","schedule":{"kind":"every","everyMs":3600000}}]}'
  run python3 "$DETECT" "$REPO_JSON" "$STORE_JSON"
  [ "$status" -eq 3 ]
}

@test "a FORGED skill-collection-review: key with an operator payload is still refused" {
  store '{"jobs":[{"id":"repo-1","schedule":{"kind":"every","everyMs":3600000}},
                  {"id":"human","name":"fake-scr","declarationKey":"skill-collection-review:billing","payload":{"kind":"command","command":"echo hi"},"schedule":{"kind":"every","everyMs":3600000}}]}'
  run python3 "$DETECT" "$REPO_JSON" "$STORE_JSON"
  [ "$status" -eq 3 ]
}

@test "the memory-core key with a DIFFERENT message is still refused (sentinel is exact)" {
  store '{"jobs":[{"id":"repo-1","schedule":{"kind":"every","everyMs":3600000}},
                  {"id":"human","name":"fake-dream","declarationKey":"memory-core:memory-dreaming-promotion","payload":{"kind":"agentTurn","message":"not the sentinel"},"schedule":{"kind":"cron","expr":"0 3 * * *"}}]}'
  run python3 "$DETECT" "$REPO_JSON" "$STORE_JSON"
  [ "$status" -eq 3 ]
}

@test "every runtime-owned namespace IS exempt (heartbeat-task: and the exact memory-core key included)" {
  store '{"jobs":[{"id":"repo-1","schedule":{"kind":"every","everyMs":3600000}},
                  {"id":"b1","name":"hb","declarationKey":"heartbeat:clio","payload":{"kind":"heartbeat"},"schedule":{"kind":"every","everyMs":1800000}},
                  {"id":"b2","name":"hbt","declarationKey":"heartbeat-task:clio","payload":{"kind":"heartbeatTask"},"schedule":{"kind":"every","everyMs":1800000}},
                  {"id":"b3","name":"scr","declarationKey":"skill-collection-review:ceo","payload":{"kind":"skillCollectionReview"},"schedule":{"kind":"every","everyMs":86400000}},
                  {"id":"b4","name":"dream","declarationKey":"memory-core:memory-dreaming-promotion","payload":{"kind":"agentTurn","message":"__openclaw_memory_core_short_term_promotion_dream__"},"schedule":{"kind":"cron","expr":"0 3 * * *"}}]}'
  run python3 "$DETECT" "$REPO_JSON" "$STORE_JSON"
  [ "$status" -eq 0 ]
}

@test "mixed: the refusal names ONLY the human orphan, not the declared ones" {
  store '{"jobs":[
    {"id":"repo-1","schedule":{"kind":"every","everyMs":3600000}},
    {"id":"boot-uuid-a","name":"heartbeat-clio","declarationKey":"heartbeat:clio","payload":{"kind":"heartbeat"},"schedule":{"kind":"every","everyMs":1800000}},
    {"id":"hand-made","name":"chartmogul-mrr","schedule":{"kind":"every","everyMs":3600000}}
  ]}'
  run python3 "$DETECT" "$REPO_JSON" "$STORE_JSON"
  [ "$status" -eq 3 ]
  [[ "$output" == *"chartmogul-mrr"* ]]
  [[ "$output" != *"heartbeat-clio"* ]]
}

@test "ephemeral one-shot exclusion still works (unchanged behaviour)" {
  store '{"jobs":[{"id":"repo-1","schedule":{"kind":"every","everyMs":3600000}},
                  {"id":"eph","name":"qa-oneshot","deleteAfterRun":true,"schedule":{"kind":"at"}}]}'
  run python3 "$DETECT" "$REPO_JSON" "$STORE_JSON"
  [ "$status" -eq 0 ]
}

@test "HYDRA_ALLOW_ORPHAN_CRON=1 still drops a human orphan deliberately" {
  store '{"jobs":[{"id":"repo-1","schedule":{"kind":"every","everyMs":3600000}},
                  {"id":"hand-made","name":"chartmogul-mrr","schedule":{"kind":"every","everyMs":3600000}}]}'
  export HYDRA_ALLOW_ORPHAN_CRON=1
  run python3 "$DETECT" "$REPO_JSON" "$STORE_JSON"
  [ "$status" -eq 0 ]
}

@test "malformed store input still fails CLOSED (rc 2), not open" {
  store '{"notjobs":[]}'
  run python3 "$DETECT" "$REPO_JSON" "$STORE_JSON"
  [ "$status" -eq 2 ]
}
