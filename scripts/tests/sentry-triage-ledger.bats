#!/usr/bin/env bats
# Behavioral tests for sentry-issue-triage Step 1 (the dedupe ledger).
#
# This block has produced three distinct defects, so it is pinned here rather
# than trusted to prose:
#   1. lock released before the row was written  -> concurrent alerts both open a PR
#   2. the row written only in Step 7            -> 4 of 5 classes never deduped
#   3. a lease written by a run that then STOPS  -> the abandoned in-progress row
#      hides the terminal verdict and, once stale, licenses a duplicate PR
# The block is extracted from SKILL.md at run time so these track the documented
# procedure rather than a copy that can drift out of sync with it.

setup() {
  HYDRA_REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SKILL="$HYDRA_REPO/skills-all/sentry-issue-triage/SKILL.md"
  [ -f "$SKILL" ] || skip "skill not found: $SKILL"

  LED_DIR="$BATS_TEST_TMPDIR/led"
  mkdir -p "$LED_DIR"
  LEDGER="$LED_DIR/seen.jsonl"

  BLOCK="$BATS_TEST_TMPDIR/step1.sh"
  python3 - "$SKILL" "$LED_DIR" > "$BLOCK" <<'PY'
import sys
skill, leddir = sys.argv[1], sys.argv[2]
lines = open(skill).read().split('\n')
i = next(k for k, l in enumerate(lines) if l.startswith('mkdir -p /var/lib/hydra-sentry-triage'))
j = next(k for k in range(i, len(lines)) if lines[k].strip() == '```')
body = '\n'.join(lines[i:j]).replace('/var/lib/hydra-sentry-triage', leddir)
# `if`, not `&&`: as the last line under `set -e` the && form would make a
# legitimate "not proceeding" run exit 1 and look like a failure.
print("set -e\n" + body + '\nif [ "$proceed" = "1" ]; then echo "PROCEED"; fi')
PY
  [ -s "$BLOCK" ] || fail "could not extract Step 1 from $SKILL"

  # Step 5's write block, so the failing-producer path is covered as written.
  WRITE="$BATS_TEST_TMPDIR/write.sh"
  python3 - "$SKILL" "$LED_DIR" > "$WRITE" <<'PY2'
import sys
skill, leddir = sys.argv[1], sys.argv[2]
lines = open(skill).read().split('\n')
i = next(k for k, l in enumerate(lines) if l.startswith('# BUILD the row BEFORE taking the lock'))
j = next(k for k in range(i, len(lines)) if lines[k].strip() == '```')
body = '\n'.join(lines[i:j]).replace('/var/lib/hydra-sentry-triage', leddir)
print('ledger="%s/seen.jsonl"; lock="%s/.lock"; : >> "$ledger"' % (leddir, leddir))
print('short_id=X-1; ledger_class=client-noise; summary=s')
print(body)
PY2
  [ -s "$WRITE" ] || fail "could not extract Step 5's write block"
}

# rows are appended with an explicit timestamp so staleness is deterministic
row() { # <id> <class> <iso-ts>
  jq -nc --arg id "$1" --arg c "$2" --arg ts "$3" \
    '{ts:$ts, short_id:$id, class:$c, summary:"s", outcome:null, twin:null}' >> "$LEDGER"
}
old_ts() { echo "2020-01-01T00:00:00Z"; }
now_ts() { python3 -c "import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))"; }

@test "never seen: proceeds and takes a lease" {
  run env SENTRY_SHORT_ID=X-1 bash "$BLOCK"
  [ "$status" -eq 0 ]
  [[ "$output" == *PROCEED* ]]
  [ "$(grep -c in-progress "$LEDGER")" = "1" ]
}

@test "terminal verdict: STOPS and writes NO lease" {
  row X-1 client-noise "$(now_ts)"
  run env SENTRY_SHORT_ID=X-1 bash "$BLOCK"
  [ "$status" -eq 0 ]
  [[ "$output" != *PROCEED* ]]
  [[ "$output" == *"NOT proceeding (terminal)"* ]]
  [ "$(grep -c in-progress "$LEDGER" || true)" = "0" ]
}

@test "REGRESSION: terminal -> duplicate alert -> later alert never duplicates" {
  # The exact sequence that produced a duplicate PR: a resolved issue fires
  # again, the re-fire must not leave a lease that later reads as a dead run.
  row X-1 client-noise "$(old_ts)"

  run env SENTRY_SHORT_ID=X-1 bash "$BLOCK"      # duplicate alert
  [[ "$output" != *PROCEED* ]]
  [ "$(grep -c in-progress "$LEDGER" || true)" = "0" ]

  run env SENTRY_SHORT_ID=X-1 bash "$BLOCK"      # later alert, lease would be stale
  [[ "$output" != *PROCEED* ]]
  [[ "$output" == *"NOT proceeding (terminal)"* ]]
  [ "$(grep -c in-progress "$LEDGER" || true)" = "0" ]
}

@test "explicit re-open of a terminal issue: proceeds and leases" {
  row X-1 code-fixable "$(old_ts)"
  run env SENTRY_SHORT_ID=X-1 SENTRY_REOPEN=1 bash "$BLOCK"
  [[ "$output" == *PROCEED* ]]
  [ "$(grep -c in-progress "$LEDGER")" = "1" ]
}

@test "lease held by a live run: STOPS" {
  row X-1 in-progress "$(now_ts)"
  run env SENTRY_SHORT_ID=X-1 bash "$BLOCK"
  [[ "$output" != *PROCEED* ]]
  [[ "$output" == *"NOT proceeding (held)"* ]]
}

@test "stale lease (run died mid-investigation): proceeds" {
  row X-1 in-progress "$(old_ts)"
  run env SENTRY_SHORT_ID=X-1 bash "$BLOCK"
  [[ "$output" == *PROCEED* ]]
}

@test "concurrent alerts on an unseen issue: exactly one proceeds" {
  pids=()
  for _ in 1 2 3 4 5; do
    ( SENTRY_SHORT_ID=X-1 bash "$BLOCK" >/dev/null 2>&1 ) &
    pids+=("$!")
  done
  # Explicit pids, never a bare `wait` (bats' BATS_TEST_TIMEOUT watchdog is a child too).
  wait "${pids[@]}" || true   # asserts on files, not the child's status
  [ "$(grep -c in-progress "$LEDGER")" = "1" ]
  run jq -e . "$LEDGER"
  [ "$status" -eq 0 ]
}

@test "unreadable ledger fails loud as UNKNOWN, never as unseen" {
  echo 'GARBAGE{{{' > "$LEDGER"
  run env SENTRY_SHORT_ID=X-1 bash "$BLOCK"
  [ "$status" -ne 0 ]
  [[ "$output" != *PROCEED* ]]
  [[ "$output" == *"UNKNOWN, not unseen"* ]]
  # jq's own diagnostic must reach the operator: a `2>/dev/null` on the read
  # keeps the exit status intact (so status alone cannot catch it) while making
  # the failure unexplainable in the one place that needs explaining.
  [[ "$output" == *"parse error"* ]]
}

@test "REGRESSION: diagnose -> awaiting-approval -> later approval proceeds exactly once" {
  # The approval lands in a LATER turn than the diagnosis. If the diagnosis row
  # were recorded as its own terminal class, Step 1 would read the issue as
  # finished and the approved fix could never reach Step 7.
  run env SENTRY_SHORT_ID=X-1 bash "$BLOCK"          # turn 1: claim
  [[ "$output" == *PROCEED* ]]
  row X-1 awaiting-approval "$(now_ts)"              # Step 5 for a code-fixable

  # turn 2: no approval yet -> must wait, not proceed, and not re-lease
  run env SENTRY_SHORT_ID=X-1 bash "$BLOCK"
  [[ "$output" != *PROCEED* ]]
  [[ "$output" == *"NOT proceeding (awaiting)"* ]]

  # turn 3: approver said yes -> proceeds and takes the lease
  run env SENTRY_SHORT_ID=X-1 SENTRY_APPROVED=1 bash "$BLOCK"
  [[ "$output" == *PROCEED* ]]

  # exactly once: the lease is now held, so a second approval message cannot
  # start a duplicate run
  run env SENTRY_SHORT_ID=X-1 SENTRY_APPROVED=1 bash "$BLOCK"
  [[ "$output" != *PROCEED* ]]
  [[ "$output" == *"NOT proceeding (held)"* ]]
}

@test "awaiting-approval is not a re-open: SENTRY_REOPEN does not unlock it" {
  row X-1 awaiting-approval "$(now_ts)"
  run env SENTRY_SHORT_ID=X-1 SENTRY_REOPEN=1 bash "$BLOCK"
  [[ "$output" != *PROCEED* ]]
  [[ "$output" == *"NOT proceeding (awaiting)"* ]]
}

@test "future-dated lease fails loud, never silently holds forever" {
  # A negative age can never exceed the staleness window, so treating it as
  # `held` would suppress triage for this issue until that timestamp passes --
  # an invisible outage. Clock skew and corrupt rows both produce this.
  future=$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  row X-1 in-progress "$future"
  run env SENTRY_SHORT_ID=X-1 bash "$BLOCK"
  [ "$status" -ne 0 ]
  [[ "$output" != *PROCEED* ]]
  [[ "$output" == *"future-dated lease"* ]]
}

@test "missing or malformed SENTRY_SHORT_ID is refused" {
  run env -u SENTRY_SHORT_ID bash "$BLOCK"
  [ "$status" -ne 0 ]
  run env SENTRY_SHORT_ID="core backend k9" bash "$BLOCK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed Sentry short id"* ]]
}

@test "REGRESSION: a failing jq must NOT look like a successful ledger write" {
  # `jq ... | flock tee` returns TEE's status: a failing jq closes the pipe, tee
  # reads EOF and exits 0, so the WARNING branch never fires and the ledger stays
  # empty -- losing the lease, so a retry duplicates the work once it ages out.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "jq: simulated failure" >&2\nexit 5\n' > "$BATS_TEST_TMPDIR/bin/jq"
  chmod +x "$BATS_TEST_TMPDIR/bin/jq"

  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash "$WRITE"
  # the failure must be REPORTED, not swallowed
  [[ "$output" == *"could not build the ledger row"* ]]
  # and nothing may be appended
  [ ! -s "$LEDGER" ]
}

@test "a healthy jq still appends exactly one row" {
  run bash "$WRITE"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$LEDGER" | tr -d " ")" = "1" ]
  run jq -r '.short_id' "$LEDGER"
  [ "$output" = "X-1" ]
}

# ---- stale-lease recovery: project -> repo mapping + guarded query ---------
# This block decides WHICH repo to search for a dead run's PRs. A typo mapping
# MUSO-AUTH-* back to core-backend, or dropping the `||` so an auth/transport
# error reads as "no PRs", both produce the same silent duplicate PR this
# recovery exists to prevent -- with CI green either way.

setup_recovery() {
  REC="$BATS_TEST_TMPDIR/recovery.sh"
  awk '/^  # Derive the repo from the id.s PROJECT via the Step 4 map/ {grab=1}
       grab {line=$0; sub(/^  /,"",line); print line; if (line=="fi") exit}' \
    "$SKILL" > "$REC"
  [ -s "$REC" ] || fail "could not extract the stale-recovery block"
  # the block reads $short_id from the caller
  sed -i.bak '1i\
short_id="$1"
' "$REC"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
}

stub_gh_ok()   { printf '#!/bin/sh\nexit 0\n'  > "$BATS_TEST_TMPDIR/bin/gh"; chmod +x "$BATS_TEST_TMPDIR/bin/gh"; }
stub_gh_fail() { printf '#!/bin/sh\nexit 1\n'  > "$BATS_TEST_TMPDIR/bin/gh"; chmod +x "$BATS_TEST_TMPDIR/bin/gh"; }

@test "recovery: CORE-BACKEND-* searches core-backend" {
  setup_recovery; stub_gh_ok
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c '. "$1" CORE-BACKEND-K9; echo "repo=$repo"' _ "$REC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"repo=Muso-AI/core-backend"* ]]
}

@test "recovery: MUSO-AUTH-* searches auth, NOT core-backend" {
  setup_recovery; stub_gh_ok
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c '. "$1" MUSO-AUTH-42; echo "repo=$repo"' _ "$REC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"repo=Muso-AI/auth"* ]]
  [[ "$output" != *"core-backend"* ]]
}

@test "recovery: CREDITS-WEB-NEXT-* searches web-credits-next" {
  setup_recovery; stub_gh_ok
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c '. "$1" CREDITS-WEB-NEXT-7; echo "repo=$repo"' _ "$REC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"repo=Muso-AI/web-credits-next"* ]]
}

@test "recovery: an unmapped id REFUSES rather than guessing a repo" {
  setup_recovery; stub_gh_ok
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c '. "$1" FLUTTER-19H' _ "$REC"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no repo mapping"* ]]
}

@test "recovery: a FAILED gh query is UNKNOWN, never 'no prior PRs'" {
  setup_recovery; stub_gh_fail
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c '. "$1" CORE-BACKEND-K9' _ "$REC"
  [ "$status" -ne 0 ]
  [[ "$output" == *"treat as UNKNOWN"* ]]
  [[ "$output" != *"RESUME"* ]]
}
