#!/usr/bin/env bats
#
# The USE_MUSO_CLI seam (common.sh) dark-launches the company-finder NocoDB
# path off the nc_pat_-token nocodb-api.sh wrapper and onto the gated, audited
# `muso nocodb` provider. These tests pin the contract that makes the cutover
# safe to flip:
#   1. the 5 verbs company-finder uses translate to the right `muso nocodb`
#      command (incl. --requester attribution on writes),
#   2. muso's {data:…} envelope is peeled so read/write SHAPES are byte-
#      identical to the wrapper — which means the clamp/pagination guarantee
#      from fetch-table.bats must hold UNCHANGED on the muso path,
#   3. an unmapped verb fails loud (no silent mis-route), and
#   4. with USE_MUSO_CLI unset the wrapper path is untouched (default-off).
# The muso stub delegates to the SAME nocodb-api.sh stub + fixtures, so test 2
# is a true parity proof against the wrapper-path suite, not a re-mock.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  COMMON="$REPO_ROOT/scripts/company-finder/lib/common.sh"
  export NOCODB_STUB_FIXTURES="$BATS_TEST_DIRNAME/fixtures"
  export MUSO_BIN="$BATS_TEST_DIRNAME/stubs/muso"
  export NOCODB_API_SH="$BATS_TEST_DIRNAME/stubs/nocodb-api.sh"
  MUSO_STUB_LOG="$BATS_TEST_TMPDIR/muso.log"; export MUSO_STUB_LOG
  NOCODB_STUB_LOG="$BATS_TEST_TMPDIR/nocodb.log"; export NOCODB_STUB_LOG
}

@test "records.ls maps to 'nocodb records list' and the {data:…} envelope is peeled" {
  run env USE_MUSO_CLI=1 NOCODB_STUB_TOTAL_ROWS=3 bash -c '
    set -euo pipefail; source "$0"
    run_nocodb records.ls sometable --fields Id --limit 100 --offset 0
  ' "$COMMON"
  [ "$status" -eq 0 ]
  # Output is the raw NocoDB body ({list,pageInfo}), NOT muso's {data:…} wrapper.
  [ "$(jq '.list | length' <<<"$output")" = "3" ]
  [ "$(jq -r '.pageInfo.isLastPage' <<<"$output")" = "true" ]
  [ "$(jq 'has("data")' <<<"$output")" = "false" ]
  grep -q 'nocodb records list --table sometable --fields Id --limit 100 --offset 0 --json' "$MUSO_STUB_LOG"
}

@test "fetch_table returns the FULL clamped table on the muso path (parity with the wrapper)" {
  # Same scenario as fetch-table.bats' CMO-bug test, but routed through muso:
  # a server clamp below PAGE_LIMIT must never truncate the 250-row snapshot.
  run env USE_MUSO_CLI=1 NOCODB_STUB_TOTAL_ROWS=250 NOCODB_STUB_CLAMP=100 \
          PAGE_LIMIT=1000 NOCODB_PAGE_SLEEP=0 bash -c '
    set -euo pipefail; source "$0"
    fetch_table sometable "Some Table" "Id" SRC_UNAVAILABLE
  ' "$COMMON"
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<<"$output")" = "250" ]
  [ "$(jq 'map(.Id) | unique | length' <<<"$output")" = "250" ]
}

@test "records.create routes through muso with explicit --requester attribution" {
  run env USE_MUSO_CLI=1 bash -c '
    set -euo pipefail; source "$0"
    run_nocodb records.create ledger123 "[{\"Domain\":\"x.com\"}]"
  ' "$COMMON"
  [ "$status" -eq 0 ]
  grep -q 'nocodb records create --table ledger123 --data' "$MUSO_STUB_LOG"
  grep -q -- '--requester company-finder@hydra-ops' "$MUSO_STUB_LOG"
  # …and the body actually reached the underlying NocoDB write.
  grep -q 'records.create ledger123' "$NOCODB_STUB_LOG"
}

@test "records.update routes through muso with --requester" {
  run env USE_MUSO_CLI=1 bash -c '
    set -euo pipefail; source "$0"
    run_nocodb records.update t1 "[{\"Id\":5,\"Domain\":\"y.com\"}]" >/dev/null
  ' "$COMMON"
  [ "$status" -eq 0 ]
  grep -q 'nocodb records update --table t1 --data' "$MUSO_STUB_LOG"
  grep -q -- '--requester company-finder@hydra-ops' "$MUSO_STUB_LOG"
}

@test "tables.create routes through muso with --base, --data, and --requester" {
  run env USE_MUSO_CLI=1 bash -c '
    set -euo pipefail; source "$0"
    run_nocodb tables.create p11base "{\"table_name\":\"t\"}" >/dev/null
  ' "$COMMON"
  [ "$status" -eq 0 ]
  grep -q 'nocodb tables create --base p11base --data' "$MUSO_STUB_LOG"
  grep -q -- '--requester company-finder@hydra-ops' "$MUSO_STUB_LOG"
}

@test "tables.ls maps to 'nocodb tables list --base'" {
  run env USE_MUSO_CLI=1 bash -c '
    set -euo pipefail; source "$0"
    run_nocodb tables.ls p11hvpwapu4hv0x
  ' "$COMMON"
  [ "$status" -eq 0 ]
  [ "$(jq 'has("list")' <<<"$output")" = "true" ]
  grep -q 'nocodb tables list --base p11hvpwapu4hv0x --json' "$MUSO_STUB_LOG"
}

@test "an unmapped verb fails loud rather than silently mis-routing" {
  run env USE_MUSO_CLI=1 bash -c '
    set -euo pipefail; source "$0"
    run_nocodb bases.swagger somebase
  ' "$COMMON"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported verb 'bases.swagger'"* ]]
  [ ! -s "$NOCODB_STUB_LOG" ]
}

@test "default (USE_MUSO_CLI unset) still routes through the nocodb-api.sh wrapper" {
  run env NOCODB_STUB_TOTAL_ROWS=2 bash -c '
    set -euo pipefail; source "$0"
    run_nocodb records.ls sometable --limit 100 --offset 0
  ' "$COMMON"
  [ "$status" -eq 0 ]
  [ "$(jq '.list | length' <<<"$output")" = "2" ]
  # the muso binary was never invoked
  [ ! -s "$MUSO_STUB_LOG" ]
}
