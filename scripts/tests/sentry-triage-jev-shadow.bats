#!/usr/bin/env bats
# Tests for scripts/sentry-triage-jev-shadow.sh — the Phase 2d Jev shadow
# call (docs/plans/jev-adoption.md) invoked from
# skills-all/sentry-issue-triage/SKILL.md's Step 5, right after the agent
# decides $class. Hermetic: jev.sh is PATH-independent-overridden via
# --jev-sh / SENTRY_TRIAGE_JEV_SH, no network, no real Jev credentials.
#
# This script is SHADOW ONLY: it must always exit 0 and must never write
# anything into the sentry-issue-triage ledger (that stays
# skills-all/sentry-issue-triage/SKILL.md's job, unmodified by this script).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/sentry-triage-jev-shadow.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin"

  # jev.sh stub: records every call (--surface/--item-id/--actual/state
  # contents) to JEV_STUB_CALLS. WD_JEV_RC makes it exit that code (default
  # 0). WD_JEV_HANG=1 makes it sleep 30s, to prove the script's own OS-level
  # `timeout` wrapper — not jev.sh's internal behaviour — bounds a hang.
  export JEV_STUB_CALLS="$TEST_TMPDIR/jev-calls"
  : > "$JEV_STUB_CALLS"
  cat > "$TEST_TMPDIR/bin/jev-stub.sh" <<'STUB'
#!/usr/bin/env bash
surface="" item="" actual="" state_file=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[i]}" in
    --surface) surface="${args[i+1]}" ;;
    --item-id) item="${args[i+1]}" ;;
    --actual) actual="${args[i+1]}" ;;
    --state-file) state_file="${args[i+1]}" ;;
  esac
done
state="$(cat "$state_file" 2>/dev/null)"
printf 'surface=%s item=%s actual=%s state=%s\n' "$surface" "$item" "$actual" "$state" >> "$JEV_STUB_CALLS"
[ "${WD_JEV_HANG:-0}" = "1" ] && sleep 30
exit "${WD_JEV_RC:-0}"
STUB
  chmod +x "$TEST_TMPDIR/bin/jev-stub.sh"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

@test "calls jev.sh with the agent's own class as --actual and the summary as state" {
  run "$SCRIPT" --short-id CORE-BACKEND-115 --class config-or-infra \
    --summary "TUWUNEL_* unset in prod env" \
    --jev-sh "$TEST_TMPDIR/bin/jev-stub.sh"
  [ "$status" -eq 0 ]
  [ -s "$JEV_STUB_CALLS" ]
  grep -q 'surface=sentry-issue-triage' "$JEV_STUB_CALLS"
  grep -q 'item=CORE-BACKEND-115' "$JEV_STUB_CALLS"
  grep -q 'actual=config-or-infra' "$JEV_STUB_CALLS"
  grep -q '"summary": "TUWUNEL_\* unset in prod env"' "$JEV_STUB_CALLS"
}

@test "the questions file offers exactly the SKILL.md five-class rubric" {
  # Read the question straight from the state/questions the stub was handed,
  # by pointing --questions at nothing and letting the script build its own,
  # then re-running with --questions pointed at that same generated file is
  # not possible after the fact (it's a tmpdir the script cleans up) — so
  # instead assert on the stub's recorded argv for the questions-file path
  # and inspect ITS contents before the script's own trap removes it. Easiest
  # hermetic way: pass a fixed --questions path we control and never let the
  # script build its own, then assert the built-in default (no --questions)
  # run still succeeds and calls jev.sh at all (content is asserted via a
  # dedicated unit below by reading the script source's heredoc).
  run "$SCRIPT" --short-id X-1 --class needs-human --summary "s" \
    --jev-sh "$TEST_TMPDIR/bin/jev-stub.sh"
  [ "$status" -eq 0 ]
  [ -s "$JEV_STUB_CALLS" ]
}

@test "the five classes in the embedded questions JSON match SKILL.md's rubric verbatim" {
  for c in code-fixable config-or-infra capacity-or-data client-noise needs-human; do
    grep -q "\"$c\":\"" "$SCRIPT"
  done
  # And nothing else is offered — exactly five keys under "criteria".
  n=$(sed -n '/"class":{"type":"choice","criteria":{/,/},"instructions"/p' "$SCRIPT" \
      | grep -c '^\s*"[a-z-]*":"')
  [ "$n" -eq 5 ]
}

@test "missing --short-id → exits 0, jev.sh never called" {
  run "$SCRIPT" --class needs-human --summary "s" --jev-sh "$TEST_TMPDIR/bin/jev-stub.sh"
  [ "$status" -eq 0 ]
  [ ! -s "$JEV_STUB_CALLS" ]
}

@test "missing --class → exits 0, jev.sh never called" {
  run "$SCRIPT" --short-id X-1 --summary "s" --jev-sh "$TEST_TMPDIR/bin/jev-stub.sh"
  [ "$status" -eq 0 ]
  [ ! -s "$JEV_STUB_CALLS" ]
}

@test "missing --summary → exits 0, jev.sh never called" {
  run "$SCRIPT" --short-id X-1 --class needs-human --jev-sh "$TEST_TMPDIR/bin/jev-stub.sh"
  [ "$status" -eq 0 ]
  [ ! -s "$JEV_STUB_CALLS" ]
}

@test "jev.sh not found/executable → exits 0, no crash" {
  run "$SCRIPT" --short-id X-1 --class needs-human --summary "s" \
    --jev-sh "$TEST_TMPDIR/bin/no-such-jev.sh"
  [ "$status" -eq 0 ]
}

@test "jev.sh exits 2 (transport failure) → this script still exits 0" {
  WD_JEV_RC=2 run "$SCRIPT" --short-id X-1 --class needs-human --summary "s" \
    --jev-sh "$TEST_TMPDIR/bin/jev-stub.sh"
  [ "$status" -eq 0 ]
}

@test "jev.sh exits 6 (kill switch) → this script still exits 0" {
  WD_JEV_RC=6 run "$SCRIPT" --short-id X-1 --class needs-human --summary "s" \
    --jev-sh "$TEST_TMPDIR/bin/jev-stub.sh"
  [ "$status" -eq 0 ]
}

@test "jev.sh hangs → bounded by the OS-level timeout wrapper, not left to hang" {
  start="$(date +%s)"
  WD_JEV_HANG=1 run "$SCRIPT" --short-id X-1 --class needs-human --summary "s" \
    --jev-sh "$TEST_TMPDIR/bin/jev-stub.sh" --timeout-ms 500
  elapsed=$(( $(date +%s) - start ))
  [ "$status" -eq 0 ]
  # default SENTRY_TRIAGE_JEV_OS_TIMEOUT is 5s; the stub sleeps 30s.
  [ "$elapsed" -lt 15 ]
}

@test "no usable \`timeout\` binary -> NO Jev call at all, never an unbounded wait" {
  # QA on #1009: fail closed rather than run jev.sh unwrapped.
  start="$(date +%s)"
  WD_JEV_HANG=1 SENTRY_TRIAGE_JEV_TIMEOUT_BIN=no-such-timeout-binary \
    run "$SCRIPT" --short-id X-1 --class needs-human --summary "s" \
    --jev-sh "$TEST_TMPDIR/bin/jev-stub.sh" --timeout-ms 500
  elapsed=$(( $(date +%s) - start ))
  [ "$status" -eq 0 ]
  if [ -s "$JEV_STUB_CALLS" ]; then
    echo "jev.sh was called with no OS timeout available" >&2
    return 1
  fi
  [ "$elapsed" -lt 10 ]
}

@test "an OS timeout of 0 (GNU: disables the limit) -> NO Jev call" {
  start="$(date +%s)"
  WD_JEV_HANG=1 SENTRY_TRIAGE_JEV_OS_TIMEOUT=0 \
    run "$SCRIPT" --short-id X-1 --class needs-human --summary "s" \
    --jev-sh "$TEST_TMPDIR/bin/jev-stub.sh" --timeout-ms 500
  elapsed=$(( $(date +%s) - start ))
  [ "$status" -eq 0 ]
  if [ -s "$JEV_STUB_CALLS" ]; then
    echo "jev.sh was called with OS timeout 0 (unbounded)" >&2
    return 1
  fi
  [ "$elapsed" -lt 10 ]
}

# Scoped to $TEST_TMPDIR, not the global ${TMPDIR:-/tmp}: runners share /tmp
# (a sibling job's work dir flips the count), and on macOS /tmp is a symlink
# that find does not descend, so a global count is always 0 and cannot fail.
@test "work dir is cleaned up even after a hang" {
  before="$(find "$TEST_TMPDIR" -maxdepth 1 -name 'sentry-jev-shadow.*' 2>/dev/null | wc -l)"
  WD_JEV_HANG=1 TMPDIR="$TEST_TMPDIR" run "$SCRIPT" --short-id X-1 --class needs-human --summary "s" \
    --jev-sh "$TEST_TMPDIR/bin/jev-stub.sh" --timeout-ms 500
  after="$(find "$TEST_TMPDIR" -maxdepth 1 -name 'sentry-jev-shadow.*' 2>/dev/null | wc -l)"
  [ "$after" -eq "$before" ]
}

# ---- SKILL.md wiring: the real Step 5 invocation, not just the standalone
# script. Extracted straight from SKILL.md so it tracks the documented
# procedure rather than a copy that can drift out of sync with it (same
# convention as scripts/tests/sentry-triage-ledger.bats).
@test "SKILL.md: the Jev call sits AFTER \$ledger_class is decided and BEFORE the ledger row is built" {
  SKILL="$HYDRA_REPO/skills-all/sentry-issue-triage/SKILL.md"
  [ -f "$SKILL" ] || skip "skill not found: $SKILL"
  ledger_class_line="$(grep -n 'ledger_class=awaiting-approval' "$SKILL" | cut -d: -f1)"
  jev_call_line="$(grep -n 'sentry-triage-jev-shadow.sh --short-id' "$SKILL" | cut -d: -f1)"
  # There are two `row=$(jq -nc ...` builds in SKILL.md (Step 5 and Step 7);
  # take the first, since that's the one this call must precede.
  row_build_line="$(grep -n '^row=\$(jq -nc' "$SKILL" | head -1 | cut -d: -f1)"
  [ -n "$ledger_class_line" ]
  [ -n "$jev_call_line" ]
  [ -n "$row_build_line" ]
  [ "$jev_call_line" -gt "$ledger_class_line" ]
  [ "$jev_call_line" -lt "$row_build_line" ]
}

@test "SKILL.md: the call passes the SAME \$class the ledger row will use, best-effort, and is an absolute /opt/hydra path" {
  SKILL="$HYDRA_REPO/skills-all/sentry-issue-triage/SKILL.md"
  [ -f "$SKILL" ] || skip "skill not found: $SKILL"
  call="$(grep -A1 'sentry-triage-jev-shadow.sh --short-id' "$SKILL")"
  [[ "$call" == *'/opt/hydra/scripts/sentry-triage-jev-shadow.sh'* ]]
  [[ "$call" == *'--short-id "$short_id"'* ]]
  [[ "$call" == *'--class "$class"'* ]]
  [[ "$call" == *'--summary "$summary"'* ]]
  [[ "$call" == *'|| true'* ]]
}

@test "SKILL.md: the call does not write jev_class into the ledger row jq" {
  SKILL="$HYDRA_REPO/skills-all/sentry-issue-triage/SKILL.md"
  [ -f "$SKILL" ] || skip "skill not found: $SKILL"
  row_block="$(awk '/^row=\$\(jq -nc/{f=1} f{print} f&&/\)\)/{exit}' "$SKILL")"
  if [[ "$row_block" == *jev_class* ]]; then
    echo "the ledger row jq must not gain a jev_class field -- that belongs in Jev's own shadow log" >&2
    return 1
  fi
}
