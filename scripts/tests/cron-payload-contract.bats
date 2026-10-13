#!/usr/bin/env bats
# Contract for cron-jobs.json payloads, mirroring the rules the OPENCLAW
# RUNTIME enforces when it persists the store.
#
# WHY THIS SUITE EXISTS (2026-09-17)
# ----------------------------------
# A PR changed `credit-verification-batch-4h` to a `command` payload whose argv
# contained empty strings for the dispatcher's optional positionals:
#
#   ["bash", "…/dispatch-cv-batch.sh", "500", "", "real", "queue", ""]
#
# Every other check passed — shellcheck, the bats suites, and even the CI
# "Deploy pre-flight (rsync --delete dry-run vs /opt/hydra/)" job, which only
# compares FILES. The runtime disagreed at deploy time and only then:
#
#   ✗ cron SQLite import failed for /root/.openclaw-main (rc=1):
#       Error: Cannot persist cron store with 1 invalid job(s)
#       at assertCronStoreCanPersist (…/row-codec-*.js)
#   FATAL: cron SQLite import failed — gateway would load 0 crons after restart
#
# so the deploy aborted at Step 5a and rolled back both gateways. The rule it
# broke is in getInvalidPersistedCronJobReason(): for payload.kind="command",
#   !Array.isArray(argv) || argv.length === 0
#     || argv.some(a => typeof a !== "string" || a.length === 0)
#   → "invalid-payload"
# and a single invalid job makes the WHOLE store unpersistable, i.e. one bad
# argv line can wedge every cron on the fleet.
#
# The runtime is not available in CI, so this suite restates its rule for the
# shapes cron-jobs.json actually uses. It cannot replace the runtime's own
# validation; it exists so the failure lands on the PR instead of on node-8's
# gateway restart.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
CRON_JSON="$HYDRA_REPO/cron-jobs.json"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
}

teardown() { rm -rf "$TEST_TMPDIR"; }

@test "cron-jobs.json parses and every job carries the fields the runtime requires" {
  run jq -e '
    (.jobs | type == "array" and length > 0)
    and ([ .jobs[] | select(
            (type != "object")
            or (.id | type != "string" or length == 0)
            or (.name | type != "string" or length == 0)
            or (.agentId | type != "string" or length == 0)
            or (.payload | type != "object")
            or (.payload.kind | type != "string" or length == 0)
            or (.schedule | type != "object")
          ) ] | length == 0)
  ' "$CRON_JSON"
  [ "$status" -eq 0 ]
}

@test "no command-payload cron has an empty or non-string argv element" {
  # The exact rule that aborted the 2026-09-17 deploy (see the header).
  # One select, no nested pipeline arithmetic: `|` binds more loosely than
  # `+`, so a `len + len | len` shape silently evaluates to nonsense.
  run jq -e '
    [ .jobs[]
      | select(.payload.kind == "command")
      | .payload.argv
      | select(
          (type != "array")
          or (length == 0)
          or ([ .[] | select((type != "string") or (length == 0)) ] | length > 0)
        ) ] | length == 0
  ' "$CRON_JSON"
  [ "$status" -eq 0 ] || {
    echo "offending command cron(s):" >&2
    jq -r '.jobs[] | select(.payload.kind == "command")
           | "  \(.name): \(.payload.argv | tojson)"' "$CRON_JSON" >&2
    false
  }
}

@test "every command-payload cron whose argv points under /opt/hydra names a file that exists in the repo" {
  # Deploy.sh rsyncs the repo tree to /opt/hydra, so a live path should be a
  # repo path. A typo here fails at the run, not at the PR — unless we check it.
  #
  # KNOWN_LIVE_ONLY: three finance report generators exist on node-8 only; they
  # are absent from the repo (measured 2026-09-17, before this suite existed).
  # The deploy's Step 0/4a drift guards auto-exclude never-tracked paths, so
  # they survive a deploy — but a cron pointing at a repo-less script is still
  # drift, it is simply the finance owner's to resolve, not this suite's to
  # fail on. Listed so a NEW missing path still fails here.
  local KNOWN_LIVE_ONLY='workspaces/finance/scripts/stripe-saas-realtime-report.py
workspaces/finance/scripts/stripe-saas-daily-report.py
workspaces/finance/scripts/stripe-saas-weekly-report.py'

  local failures=""
  while IFS= read -r arg; do
    [ -n "$arg" ] || continue
    case "$arg" in
      /opt/hydra/*)
        local rel="${arg#/opt/hydra/}"
        local repo_path="$HYDRA_REPO/$rel"
        if [ ! -e "$repo_path" ]; then
          if printf '%s\n' "$KNOWN_LIVE_ONLY" | grep -qxF "$rel"; then
            echo "  (known live-only, not failing): $rel" >&2
            continue
          fi
          failures="${failures}${arg} (missing: ${repo_path})"$'\n'
        fi
        ;;
    esac
  done < <(jq -r '.jobs[] | select(.payload.kind == "command") | .payload.argv[]' "$CRON_JSON")

  if [ -n "$failures" ]; then
    echo "command-payload argv paths that do not exist in the repo:" >&2
    printf '%s' "$failures" >&2
    false
  fi
}

@test "the credit-verification batch runs the deterministic entrypoint, not an agent turn" {
  # Pins the 2026-09-17 fix. The batch must not go back to an agent turn: a
  # run's status has to come from the batch's own outcome, not from the model
  # finishing (that is how six days of zero-work runs read `ok`).
  # enabled is pinned FALSE since 2026-10-11: the batch's approve rule was
  # inverted and the cron was contained; re-enabling needs the captain's
  # approval in policies/credit-approval-automation.json
  # (scripts/check-credit-approval-automation.sh enforces it).
  run jq -r '
    .jobs[] | select(.name == "credit-verification-batch-4h")
    | "\(.payload.kind) \(.enabled) \(.payload.argv[1] // "")"
  ' "$CRON_JSON"
  [ "$status" -eq 0 ]
  [ "$output" = "command false /opt/hydra/workspaces/operations/skills/muso-ops-credit-verification/scripts/credit-verification-batch-cron.sh" ]

  # ...and that entrypoint must exist, be runnable, and reach the dispatcher.
  local entry="$HYDRA_REPO/workspaces/operations/skills/muso-ops-credit-verification/scripts/credit-verification-batch-cron.sh"
  [ -f "$entry" ]
  [ -x "$entry" ]
  run bash -n "$entry"
  [ "$status" -eq 0 ]
  run grep -n 'dispatch-cv-batch.sh' "$entry"
  [ "$status" -eq 0 ]
}

@test "a command-payload cron that passes the dispatcher positionals uses no empty placeholder" {
  # Regression for the exact shape that broke the deploy: if anyone routes a
  # command payload at dispatch-cv-batch.sh directly, it must not pad argv with
  # "" for thread_ts. Use the named entrypoint instead.
  run jq -r '
    [ .jobs[]
      | select(.payload.kind == "command")
      | select([.payload.argv[]] | any(test("dispatch-cv-batch\\.sh")))
      | select((.payload.argv | length) > 2) ] | length
  ' "$CRON_JSON"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}
