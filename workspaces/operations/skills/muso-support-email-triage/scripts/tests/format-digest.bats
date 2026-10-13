#!/usr/bin/env bats
# format-digest.sh — the deterministic Phase 3 join/count/emit step of the
# muso-support-email-triage skill. Hermetic: it only needs python3 + a $WORKDIR
# holding emails.json (fetch, authoritative) and verdicts.json (LLM-authored).
# No openclaw/muso/network, so no PATH stubbing is required.
#
# The contract under test:
#   - 0 threads              -> prints exactly NO_REPLY (cron stays silent).
#   - verdict ∈ {caroline, human, spam}; anything else fails loud.
#   - spam/no-action NEVER counts toward Caroline-can-handle (Nick's complaint:
#     a fuel-card promo must not inflate her win count).
#   - the spam segment is shown in the header only when n_spam > 0.
#   - reconciliation is fail-loud (Rule 13): a bad/missing/unreconcilable verdict
#     exits non-zero rather than shipping a fabricated digest.

bats_require_minimum_version 1.5.0

SCRIPT="${BATS_TEST_DIRNAME}/../format-digest.sh"

# Portable octal file mode (GNU `stat -c` vs BSD/macOS `stat -f`).
_fd_test_stat_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%A' "$1"
}

setup() {
  WORKDIR="$(mktemp -d)"
  export WORKDIR
  # Isolate EVERY test from format-digest.sh's own hardcoded production
  # defaults, whether or not the test calls jev_stub. On node-8, CI runs
  # these bats files as root against the real checkout, where
  # /opt/hydra/scripts/lib/jev.sh genuinely exists and is executable -- so a
  # test with a real thread+verdict but no jev_stub call left JEV_SH unset,
  # format-digest.sh's own `: "${JEV_SH:=/opt/hydra/scripts/lib/jev.sh}"`
  # resolved to the REAL jev.sh, and its unset JEV_SHADOW_DIR resolved to the
  # REAL /var/lib/hydra-jev/shadow -- writing real rows into production's own
  # shadow log on every CI run (confirmed: 175 polluted rows, 2026-09-22
  # 20:29 through 2026-09-23 09:24). Default both to inert paths under
  # $BATS_TEST_TMPDIR for every test; jev_stub()/jev_probe_stub() override
  # them with their own isolated stub+dir for tests that need a Jev call
  # path actually exercised.
  JEV_SH="${BATS_TEST_TMPDIR}/no-jev-sh-for-this-test"
  JEV_SHADOW_DIR="${BATS_TEST_TMPDIR}/shadow"
  export JEV_SH JEV_SHADOW_DIR
}
teardown() {
  # format-digest.sh scrubs $WORKDIR on the success path; clean up the rest.
  [ -n "${WORKDIR:-}" ] && rm -rf "$WORKDIR"
  [ -n "${JEV_SCRATCH:-}" ] && rm -rf "$JEV_SCRATCH"
  unset JEV_SH JEV_SHADOW_DIR JEV_EMAIL_TRIAGE_TIMEOUT_MS JEV_EMAIL_TRIAGE_BUDGET_S \
    JEV_EMAIL_TRIAGE_MAX_THREADS JEV_EMAIL_TRIAGE_QUESTIONS_FILE JEV_CALL_LOG JEV_PROBE_LOG \
    JEV_SHADOW_STORE_STATE
}

emails() { printf '%s' "$1" > "$WORKDIR/emails.json"; }
verdicts() { printf '%s' "$1" > "$WORKDIR/verdicts.json"; }

# --- Phase 2b (format-time Jev shadow) test scaffolding -------------------
#
# format-digest.sh now calls jev.sh itself, per thread, strictly after the
# digest above has already been computed/printed and right before the
# unconditional `rm -rf "$WORKDIR"`, and it is the SOLE writer of the
# email-triage shadow log (jev.sh is always called with --no-shadow, so
# these stubs never need to touch the shadow file themselves -- they only
# reproduce jev.sh's documented stdout/exit-code contract: the answers
# object on stdout iff rc 0, nothing on stdout otherwise). Real network
# calls are never exercised, so the suite stays hermetic.
#
# jev_stub <outcome>: writes a stub at $JEV_SCRATCH/jev.sh, sets JEV_SH to
# it, and arranges for every invocation to be logged (full argv, one line
# per call) to $JEV_CALL_LOG.
jev_stub() {
  local outcome="$1"
  JEV_SCRATCH="$(mktemp -d)"
  export JEV_SCRATCH
  JEV_SH="$JEV_SCRATCH/jev.sh"
  JEV_SHADOW_DIR="$JEV_SCRATCH/shadow"
  JEV_CALL_LOG="$JEV_SCRATCH/calls.log"
  mkdir -p "$JEV_SHADOW_DIR"
  : > "$JEV_CALL_LOG"
  export JEV_SH JEV_SHADOW_DIR JEV_CALL_LOG
  cat > "$JEV_SH" <<STUB
#!/usr/bin/env bash
# Test stub standing in for scripts/lib/jev.sh.
printf '%s\n' "\$*" >> "$JEV_CALL_LOG"
STUB
  case "$outcome" in
    ok)
      cat >> "$JEV_SH" <<'STUB'
# Real jev.sh on success: prints the answers object on stdout, rc 0.
printf '{"owner":{"type":"choice","choice":"caroline","probabilities":{"caroline":0.9,"human":0.05,"spam":0.05}}}\n'
exit 0
STUB
      ;;
    fail)
      cat >> "$JEV_SH" <<'STUB'
# Real jev.sh: a failing call (rc 2) prints nothing on stdout.
echo "jev: stub curl failure" >&2
exit 2
STUB
      ;;
    hang)
      cat >> "$JEV_SH" <<'STUB'
sleep 300
STUB
      ;;
    killswitch)
      cat >> "$JEV_SH" <<'STUB'
# Real jev.sh: rc 6 (kill switch) prints nothing on stdout.
echo "jev: kill switch engaged" >&2
exit 6
STUB
      ;;
    absent)
      # Delete the file but leave JEV_SH pointing at the now-missing path --
      # NOT unset. format-digest.sh's default only applies when JEV_SH is
      # unset/empty (`: "${JEV_SH:=/opt/hydra/scripts/lib/jev.sh}"`); unsetting
      # it here would fall through to that REAL, hardcoded production path
      # (which exists and is executable on node-8) instead of testing "jev.sh
      # missing" -- exactly the isolation bug this file now guards against.
      rm -f "$JEV_SH"
      ;;
    garbage)
      cat >> "$JEV_SH" <<'STUB'
# rc 0, but the response body had no .answers object -- jev.sh itself would
# exit 3 for this (documented rc 3), so this stub name covers the OTHER,
# defensive branch this caller now guards: rc 0 with stdout that is empty
# or not a JSON object (a corrupted/truncated capture). Prints garbage text
# instead of a JSON object.
printf 'not json\n'
exit 0
STUB
      ;;
    slow_ok)
      cat >> "$JEV_SH" <<'STUB'
# Same success payload as "ok", but sleeps briefly first (variable, via
# $RANDOM) so multiple concurrently-running format-digest.sh processes are
# likely to land their shadow-row appends close together in time.
sleep "0.0$(( RANDOM % 9 + 1 ))"
printf '{"owner":{"type":"choice","choice":"caroline","probabilities":{"caroline":0.9,"human":0.05,"spam":0.05}}}\n'
exit 0
STUB
      ;;
    huge_ok)
      cat >> "$JEV_SH" <<'STUB'
# 200 KB answers object: past Linux's 128 KB MAX_ARG_STRLEN for a single
# execve argument, so it can only be recorded if format-digest.sh reads the
# answers from a FILE, never passes them to jq as one argv string.
python3 -c "import json; print(json.dumps({'owner':{'type':'choice','choice':'caroline','probabilities':{'caroline':0.9,'human':0.05,'spam':0.05},'filler':'z'*200000}}))"
exit 0
STUB
      ;;
    big_ok)
      cat >> "$JEV_SH" <<'STUB'
# Same success shape as "ok", but with a large filler field (100KB) inside
# the answers object -- nothing bounds jev.sh's real response size, and
# bash's printf only issues a single write(2) (atomic even without a lock)
# for a SHORT line; past its stdio buffer it splits into several write(2)
# calls, which two processes CAN interleave. This is what isolates whether
# flock is load-bearing rather than defense-in-depth for a short row. 100KB,
# not larger: Linux caps a single execve() argument at MAX_ARG_STRLEN
# (128KB) and this string round-trips through jq --argjson as one argv
# entry in the real code path, so a bigger filler would fail for an
# unrelated reason (argv length) on node-8 before ever reaching the
# flock/no-flock question this test isolates. (That argv ceiling is gone
# since answers are read with --slurpfile; see the huge_ok case.)
python3 -c "import json; print(json.dumps({'owner':{'type':'choice','choice':'caroline','probabilities':{'caroline':0.9,'human':0.05,'spam':0.05},'filler':'y'*100000}}))"
exit 0
STUB
      ;;
  esac
  if [ -f "${JEV_SH:-/nonexistent}" ]; then
    chmod +x "$JEV_SH"
  fi
  return 0
}

# jev_probe_stub: like jev_stub ok, but additionally records, on every call,
# whether $WORKDIR already contains a Jev ANSWERS object -- proving no
# answer-key/sidecar ever exists in $WORKDIR at the moment the agent's
# classification step could see it. This is a CONTENT check, not a
# name-based one: the redesign removed the old answer-key problem at the
# root (Jev only runs in format-digest, strictly after verdicts.json
# already exists), so the invariant that matters now is "no answers object
# anywhere in WORKDIR yet", not "no file happens to be named *jev*" -- a
# name-based check is satisfied by a trivial rename and proves nothing.
# Every regular file under $WORKDIR is inspected: one whose content parses
# as a JSON object carrying the "owner" key (this stub's own answers shape)
# is logged as a violation. state.json (the per-call INPUT, not an answer)
# and answers.out (truncated, still empty at call time) are expected to
# exist and must NOT match.
jev_probe_stub() {
  jev_stub ok
  JEV_PROBE_LOG="$JEV_SCRATCH/probe.log"
  export JEV_PROBE_LOG
  : > "$JEV_PROBE_LOG"
  cat > "$JEV_SH" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$JEV_CALL_LOG"
find "$WORKDIR" -type f -print0 2>/dev/null | while IFS= read -r -d '' f; do
  if jq -e 'type == "object" and has("owner")' "\$f" >/dev/null 2>&1; then
    printf '%s\n' "\$f" >> "$JEV_PROBE_LOG"
  fi
done
printf '{"owner":{"type":"choice","choice":"caroline","probabilities":{"caroline":0.9,"human":0.05,"spam":0.05}}}\n'
exit 0
STUB
  chmod +x "$JEV_SH"
}

# _prod_shadow_stat: mtime:size of the REAL production shadow log, or empty
# if it does not exist. GNU stat first (node-8/CI), BSD stat as the local
# dev-box fallback.
_prod_shadow_stat() {
  local prod_shadow="/var/lib/hydra-jev/shadow/email-triage.jsonl"
  [ -e "$prod_shadow" ] || return 0
  stat -c '%Y:%s' "$prod_shadow" 2>/dev/null || stat -f '%m:%z' "$prod_shadow" 2>/dev/null
}

@test "the real /var/lib/hydra-jev shadow log is never touched by a test that never calls jev_stub" {
  # Regression guard for the 175-row production pollution incident
  # (2026-09-22 20:29 through 2026-09-23 09:24): a test with a real
  # thread+verdict but NO jev_stub call previously left JEV_SH/JEV_SHADOW_DIR
  # to format-digest.sh's own hardcoded defaults, which resolve to the REAL
  # jev.sh and the REAL shadow log on node-8. setup() now overrides both for
  # every test; this proves that holds without depending on any individual
  # test remembering to call jev_stub. Deliberately does NOT call jev_stub.
  local before after
  before="$(_prod_shadow_stat)"

  emails '[{"threadId":"t1","subject":"a","url":"u1"}]'
  verdicts '[{"threadId":"t1","verdict":"caroline","description":"d","reason":"r"}]'
  run --separate-stderr bash "$SCRIPT"
  if [ "$status" -ne 0 ]; then
    echo "format-digest.sh exited $status: $output" >&2
    return 1
  fi

  after="$(_prod_shadow_stat)"
  if [ "$before" != "$after" ]; then
    echo "prod shadow log changed: before=[$before] after=[$after]" >&2
    return 1
  fi
}

@test "empty inbox prints exactly NO_REPLY and exits 0" {
  emails '[]'
  verdicts '[]'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "NO_REPLY" ]
}

@test "three-verdict digest: header counts each bucket and spam is separated out" {
  emails '[
    {"threadId":"t1","subject":"verify my credits","url":"https://mail/t1"},
    {"threadId":"t2","subject":"Save 10p per litre on fuel with POWK","url":"https://mail/t2"},
    {"threadId":"t3","subject":"chain of title","url":"https://mail/t3"}
  ]'
  verdicts '[
    {"threadId":"t1","verdict":"caroline","description":"credits pending","reason":"customer-credit-verification"},
    {"threadId":"t2","verdict":"spam","description":"fuel-card promo","reason":"promotional / not a customer"},
    {"threadId":"t3","verdict":"human","description":"legal inquiry","reason":"legal / rights"}
  ]'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  first_line="${lines[0]}"
  [[ "$first_line" == *"3 new"* ]]
  [[ "$first_line" == *"1 Caroline-can-handle"* ]]
  [[ "$first_line" == *"1 need a human"* ]]
  [[ "$first_line" == *"1 spam/no-action"* ]]
}

@test "spam is NOT counted as Caroline-can-handle (the fuel-card regression)" {
  # Two spam threads, one real Caroline thread. Caroline count MUST be 1, not 3.
  emails '[
    {"threadId":"t1","subject":"real question","url":"u1"},
    {"threadId":"t2","subject":"promo A","url":"u2"},
    {"threadId":"t3","subject":"promo B","url":"u3"}
  ]'
  verdicts '[
    {"threadId":"t1","verdict":"caroline","description":"how do I claim","reason":"KB: faq"},
    {"threadId":"t2","verdict":"spam","description":"promo","reason":"marketing"},
    {"threadId":"t3","verdict":"spam","description":"promo","reason":"marketing"}
  ]'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"1 Caroline-can-handle"* ]]
  [[ "${lines[0]}" == *"2 spam/no-action"* ]]
  # And the spam bullets carry the spam tag, not the Caroline tag.
  [[ "$output" == *":wastebasket: spam/no-action"* ]]
}

@test "no spam segment in the header when nothing is spam" {
  emails '[{"threadId":"t1","subject":"s","url":"u1"}]'
  verdicts '[{"threadId":"t1","verdict":"caroline","description":"d","reason":"KB: faq"}]'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" != *"spam/no-action"* ]]
  [[ "${lines[0]}" == *"1 Caroline-can-handle"* ]]
  [[ "${lines[0]}" == *"0 need a human"* ]]
}

@test "each verdict renders its own tag" {
  emails '[
    {"threadId":"t1","subject":"a","url":"u1"},
    {"threadId":"t2","subject":"b","url":"u2"},
    {"threadId":"t3","subject":"c","url":"u3"}
  ]'
  verdicts '[
    {"threadId":"t1","verdict":"caroline","description":"d","reason":"r"},
    {"threadId":"t2","verdict":"human","description":"d","reason":"r"},
    {"threadId":"t3","verdict":"spam","description":"d","reason":"r"}
  ]'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *":white_check_mark: Caroline-can-handle"* ]]
  [[ "$output" == *":raising_hand: needs a human"* ]]
  [[ "$output" == *":wastebasket: spam/no-action"* ]]
}

@test "an invalid verdict fails loud (does not ship a partial digest)" {
  emails '[{"threadId":"t1","subject":"s","url":"u1"}]'
  verdicts '[{"threadId":"t1","verdict":"junk","description":"d","reason":"r"}]'
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid verdict"* ]]
  [[ "$output" == *"caroline|human|spam"* ]]
}

@test "a verdict for an unknown threadId fails loud (no fabricated rows)" {
  emails '[{"threadId":"t1","subject":"s","url":"u1"}]'
  verdicts '[{"threadId":"t9","verdict":"caroline","description":"d","reason":"r"}]'
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not in emails.json"* ]]
}

@test "a thread with no verdict fails loud" {
  emails '[
    {"threadId":"t1","subject":"a","url":"u1"},
    {"threadId":"t2","subject":"b","url":"u2"}
  ]'
  verdicts '[{"threadId":"t1","verdict":"caroline","description":"d","reason":"r"}]'
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no verdict"* ]]
}

@test "em-dashes in description/reason are normalized to hyphens" {
  emails '[{"threadId":"t1","subject":"sub—ject","url":"u1"}]'
  verdicts '[{"threadId":"t1","verdict":"spam","description":"promo — ignore","reason":"marketing — cold"}]'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"—"* ]]
  [[ "$output" != *"–"* ]]
}

# --- Phase 2b: format-time Jev shadow classification -----------------------

# mk_thread_files <workdir> <n> <prefix>: writes emails.json/verdicts.json
# into <workdir> with <n> threads, ids "<prefix>-0".."<prefix>-(n-1)", each
# reconciled to verdict "caroline" -- used by the concurrency test to give
# each of several parallel format-digest.sh processes its own distinct set
# of thread ids sharing one JEV_SHADOW_DIR.
mk_thread_files() {
  local wd="$1" n="$2" prefix="$3" emails_arr="[" verdicts_arr="[" j=0
  while [ "$j" -lt "$n" ]; do
    [ "$j" -gt 0 ] && emails_arr="$emails_arr," && verdicts_arr="$verdicts_arr,"
    emails_arr="${emails_arr}{\"threadId\":\"${prefix}-${j}\",\"subject\":\"s\",\"url\":\"u\"}"
    verdicts_arr="${verdicts_arr}{\"threadId\":\"${prefix}-${j}\",\"verdict\":\"caroline\",\"description\":\"d\",\"reason\":\"r\"}"
    j=$(( j + 1 ))
  done
  printf '%s' "${emails_arr}]" > "$wd/emails.json"
  printf '%s' "${verdicts_arr}]" > "$wd/verdicts.json"
}

REPO_ROOT_FOR_REPORT() {
  cd "${BATS_TEST_DIRNAME}/../../../../../.." && pwd
}

@test "digest, stdout and exit code are byte-identical whether the Jev call succeeds, fails, hangs, hits the kill switch, returns garbage, or jev.sh is absent" {
  emails '[{"threadId":"t1","subject":"verify my credits","url":"u1"}]'
  verdicts '[{"threadId":"t1","verdict":"caroline","description":"d","reason":"r"}]'

  # Baseline: no JEV_SH at all (mirrors a host that has never deployed jev.sh).
  run --separate-stderr bash "$SCRIPT"
  baseline_status="$status"
  baseline_output="$output"

  for outcome in ok fail hang killswitch garbage absent; do
    WORKDIR="$(mktemp -d)"
    export WORKDIR
    emails '[{"threadId":"t1","subject":"verify my credits","url":"u1"}]'
    verdicts '[{"threadId":"t1","verdict":"caroline","description":"d","reason":"r"}]'
    JEV_EMAIL_TRIAGE_TIMEOUT_MS=200
    export JEV_EMAIL_TRIAGE_TIMEOUT_MS
    jev_stub "$outcome"
    run --separate-stderr bash "$SCRIPT"
    [ "$status" -eq "$baseline_status" ]
    [ "$output" = "$baseline_output" ]
    rm -rf "$WORKDIR"
    [ -n "${JEV_SCRATCH:-}" ] && rm -rf "$JEV_SCRATCH"
  done
}

@test "every thread produces exactly one shadow row, this caller is the writer, and --no-shadow is passed on every call" {
  emails '[
    {"threadId":"t1","subject":"a","url":"u1"},
    {"threadId":"t2","subject":"b","url":"u2"},
    {"threadId":"t3","subject":"c","url":"u3"}
  ]'
  verdicts '[
    {"threadId":"t1","verdict":"caroline","description":"d","reason":"r"},
    {"threadId":"t2","verdict":"human","description":"d","reason":"r"},
    {"threadId":"t3","verdict":"spam","description":"d","reason":"r"}
  ]'
  # A stub that alternates rc 0 / rc 2 per call, printing an answers object
  # only on the rc 0 branch. Writing to the shadow file is not this stub's
  # job any more -- format-digest.sh is the sole writer now that jev.sh is
  # always called with --no-shadow.
  JEV_SCRATCH="$(mktemp -d)"
  export JEV_SCRATCH
  JEV_SH="$JEV_SCRATCH/jev.sh"
  JEV_SHADOW_DIR="$JEV_SCRATCH/shadow"
  JEV_CALL_LOG="$JEV_SCRATCH/calls.log"
  mkdir -p "$JEV_SHADOW_DIR"
  : > "$JEV_CALL_LOG"
  export JEV_SH JEV_SHADOW_DIR JEV_CALL_LOG
  cat > "$JEV_SH" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$JEV_CALL_LOG"
n=\$(wc -l < "$JEV_CALL_LOG")
if [ "\$((n % 2))" -eq 0 ]; then
  exit 2
else
  printf '{"owner":{"type":"choice","choice":"caroline","probabilities":{"caroline":0.9,"human":0.05,"spam":0.05}}}\n'
  exit 0
fi
STUB
  chmod +x "$JEV_SH"

  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 0 ]

  [ "$(wc -l < "$JEV_CALL_LOG")" -eq 3 ]
  [ "$(wc -l < "$JEV_SHADOW_DIR/email-triage.jsonl")" -eq 3 ]

  # --no-shadow must be passed on every single call, not merely somewhere in
  # the log -- otherwise jev.sh could double-write its own row.
  calls_without_flag="$(grep -c -v -- '--no-shadow' "$JEV_CALL_LOG" || true)"
  if [ "$calls_without_flag" -ne 0 ]; then
    echo "$calls_without_flag call(s) missing --no-shadow: $(cat "$JEV_CALL_LOG")" >&2
    return 1
  fi
}

@test "no Jev answers object exists anywhere in WORKDIR at the moment the classify call runs" {
  emails '[{"threadId":"t1","subject":"a","url":"u1"}]'
  verdicts '[{"threadId":"t1","verdict":"caroline","description":"d","reason":"r"}]'
  jev_probe_stub
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$JEV_PROBE_LOG" ]
  [ ! -s "$JEV_PROBE_LOG" ]
}

@test "SIGTERM mid-call leaves the PII scratch nested under WORKDIR, never orphaned under TMPDIR" {
  # QA on #1008 (real PII leak): the scratch dir used to be created under
  # ${TMPDIR:-/tmp} directly, outside $WORKDIR's cleanup contract. If
  # format-digest.sh was SIGTERM'd after state.json was written but before
  # its own end-of-function `rm -rf "$work_dir"` ran, that directory was
  # orphaned forever -- nothing (preflight's trap, SKILL.md's must-rm rule,
  # or this script's own cleanup) knew it existed. Now the scratch dir is
  # nested inside $WORKDIR, so a SIGTERM mid-call leaves it exactly where
  # $WORKDIR's own cleanup contract already covers it -- no second location.
  emails '[{"threadId":"t1","subject":"a","url":"u1"}]'
  verdicts '[{"threadId":"t1","verdict":"caroline","description":"d","reason":"r"}]'
  jev_stub hang
  local_workdir="$WORKDIR"

  bash "$SCRIPT" >/dev/null 2>/dev/null &
  local script_pid=$!

  # Wait until the hung jev.sh call is actually in flight (its stub logs its
  # argv to JEV_CALL_LOG on entry) so SIGTERM always lands mid-call rather
  # than racing format-digest.sh's own startup.
  local waited=0
  while [ ! -s "$JEV_CALL_LOG" ]; do
    sleep 0.05
    waited=$(( waited + 1 ))
    if [ "$waited" -ge 100 ]; then
      kill -9 "$script_pid" 2>/dev/null || true
      wait "$script_pid" 2>/dev/null || true
      echo "jev.sh stub never started" >&2
      return 1
    fi
  done

  kill -TERM "$script_pid"
  wait "$script_pid" 2>/dev/null || true

  # The state.json PII copy must survive, but ONLY nested under $WORKDIR.
  local state_files
  state_files="$(find "$local_workdir" -name 'state.json' 2>/dev/null)"
  [ -n "$state_files" ]

  # Nothing was created directly under ${TMPDIR:-/tmp} for this call: no
  # jev-classify.* directory -- the old, now-removed location, and the ONLY
  # name the reverted code below can ever produce, since its mktemp template
  # is literally "${TMPDIR:-/tmp}/jev-classify.XXXXXX". This also covers "the
  # only surviving copy of the state is under $WORKDIR" by construction:
  # state.json is written ONLY inside this scratch dir, so if no scratch dir
  # exists outside $WORKDIR, no state.json does either. A separate blind
  # recursive search for a generic filename like "state.json" across all of
  # ${TMPDIR:-/tmp} is deliberately avoided: on a real dev/CI box, TMPDIR
  # accumulates plenty of unrelated tools' own "state.json" scratch files
  # (confirmed on this machine), so that search would be both unsafe to
  # assert on and meaningless for this invariant.
  #
  # Deliberately maxdepth 1, and deliberately NOT also matching
  # .shadow-scratch.* here: the current (correct) code can only ever create
  # .shadow-scratch.* nested INSIDE some WORKDIR, never as a direct TMPDIR
  # child, so scanning for it at TMPDIR level catches nothing of ours -- it
  # only picks up OTHER, unrelated, correctly-nested WORKDIRs from concurrent
  # format-digest.sh runs on this same shared, busy production host (real
  # false positives, confirmed on node-8: a from-scratch, unbounded find hit
  # a TOCTOU race and returned nonzero; a maxdepth-2 find matched a concurrent
  # session's own live .shadow-scratch dir). Limiting to jev-classify.* at
  # maxdepth 1 is exactly and only the shape the mutation below reintroduces.
  #
  # `|| true` on the assignment: node-8's /tmp holds 10000+ entries under
  # constant concurrent churn, and GNU find lstats every entry it enumerates
  # even for a plain -name match -- so find itself can still exit nonzero if
  # some OTHER, unrelated entry is deleted mid-readdir (confirmed on node-8,
  # even bounded to maxdepth 1). That race is about entries unrelated to this
  # test: our own mktemp'd target, if the mutated code below created it,
  # persists for the whole test and is unaffected by other entries' churn, so
  # it is still correctly listed in $outside_dirs regardless of find's exit
  # code. Judge purely on content, never on find's own exit status.
  local outside_dirs
  outside_dirs="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'jev-classify.*' -not -path "${local_workdir}" 2>/dev/null)" || true
  [ -z "$outside_dirs" ]

  rm -rf "$local_workdir"
  WORKDIR=""
}

@test "PII cleanup (rm -rf WORKDIR) still happens when the Jev call hangs" {
  emails '[{"threadId":"t1","subject":"a","url":"u1"}]'
  verdicts '[{"threadId":"t1","verdict":"caroline","description":"d","reason":"r"}]'
  JEV_EMAIL_TRIAGE_TIMEOUT_MS=200
  export JEV_EMAIL_TRIAGE_TIMEOUT_MS
  jev_stub hang
  local_workdir="$WORKDIR"
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -d "$local_workdir" ]
  WORKDIR=""
}

@test "no usable timeout binary -> NO Jev call (never unbounded), and PII cleanup still runs" {
  # Fail closed (QA on #1009, same rule here): jev.sh bounds its curl call but
  # nothing else it does, and this runs right before the PII scrub. The stub
  # HANGS, so a regression either stalls ~300 s or logs a call.
  emails '[{"threadId":"t1","subject":"a","url":"u1"}]'
  verdicts '[{"threadId":"t1","verdict":"caroline","description":"d","reason":"r"}]'
  jev_stub hang
  local_workdir="$WORKDIR"
  start="$(date +%s)"
  JEV_EMAIL_TRIAGE_TIMEOUT_BIN=no-such-timeout-binary run --separate-stderr bash "$SCRIPT"
  elapsed=$(( $(date +%s) - start ))
  [ "$status" -eq 0 ]
  if [ -s "$JEV_CALL_LOG" ]; then
    echo "jev.sh was called with no OS timeout available: $(cat "$JEV_CALL_LOG")" >&2
    return 1
  fi
  [ "$elapsed" -lt 10 ]
  [ ! -d "$local_workdir" ]
  WORKDIR=""
}

# --- QA on #1008, redesign round 2 (one writer, one row per call) ---------
#
# Two Important findings on the previous (line-count-delta) fix showed
# inferring "did a row land?" from a shared file's line count is unsound at
# the root, not just in its edge cases:
#   1. jev.sh can return rc 0 with answers while its OWN append silently
#      fails -- the old fallback then wrote a SECOND row with rc 0 and
#      answers null, which jev-shadow-report.sh's row_ok() accepts but
#      top_answer() skips (answers is None) and rc_nonzero also skips (rc is
#      0) -- an invisible row that quietly overstates agreement.
#   2. Two overlapping cron runs sharing one shadow file: run B's append can
#      land between run A's before/after snapshots, so A sees the file grow
#      (from B's row, not its own), concludes "nothing to do", and A's own
#      call -- possibly a timeout -- is never recorded at all.
# The fix (see format-digest.sh's header comment) removes the inference
# entirely: jev.sh is always called with --no-shadow, and this function is
# the SOLE writer, building exactly one row per call from jev.sh's own
# stdout/rc contract. These tests exercise that contract end to end,
# including through the real scripts/jev-shadow-report.sh (both QA cases are
# asserted at the report level, not just at the row level).

@test "rc 0 with a valid answers stdout -> exactly one row, and it counts in agreement under the real report" {
  repo_root="$(REPO_ROOT_FOR_REPORT)"

  emails '[{"threadId":"t1","subject":"a","url":"u1"}]'
  verdicts '[{"threadId":"t1","verdict":"caroline","description":"d","reason":"r"}]'
  jev_stub ok

  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 0 ]

  shadow_file="$JEV_SHADOW_DIR/email-triage.jsonl"
  [ -f "$shadow_file" ]
  [ "$(wc -l < "$shadow_file")" -eq 1 ]

  row="$(cat "$shadow_file")"
  [ "$(printf '%s' "$row" | jq -r '.rc')" = "0" ]
  [ "$(printf '%s' "$row" | jq -r '.reason')" = "null" ]
  [ "$(printf '%s' "$row" | jq -r '.answers.owner.choice')" = "caroline" ]
  # The raw state is stored next to state_sha256 by default, so the row is
  # replayable against Jev directly.
  [ "$(printf '%s' "$row" | jq -r '.state.subject')" = "a" ]
  [ "$(printf '%s' "$row" | jq -r '.state_sha256')" != "null" ]

  run bash "$repo_root/scripts/jev-shadow-report.sh" --shadow-dir "$JEV_SHADOW_DIR" --surface email-triage
  [ "$status" -eq 0 ]
  if [[ "$output" != *"question: owner"* ]]; then
    echo "expected the owner question to be reported, got: $output" >&2
    return 1
  fi
  if [[ "$output" != *"100.0%"* ]]; then
    echo "expected the single row to show 100.0% agreement (choice caroline == actual caroline), got: $output" >&2
    return 1
  fi
  if [[ "$output" != *"total=1 rc_nonzero=0"* ]]; then
    echo "expected total=1 rc_nonzero=0, got: $output" >&2
    return 1
  fi
}

@test "JEV_SHADOW_STORE_STATE=0: shadow row keeps state_sha256 but omits raw state" {
  export JEV_SHADOW_STORE_STATE=0
  emails '[{"threadId":"t1","subject":"a","url":"u1"}]'
  verdicts '[{"threadId":"t1","verdict":"caroline","description":"d","reason":"r"}]'
  jev_stub ok

  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 0 ]

  shadow_file="$JEV_SHADOW_DIR/email-triage.jsonl"
  [ -f "$shadow_file" ]
  row="$(cat "$shadow_file")"
  [ "$(printf '%s' "$row" | jq -r '.state')" = "null" ]
  [ "$(printf '%s' "$row" | jq -r '.state_sha256')" != "null" ]
}

@test "rc 0 with empty/garbage stdout counts as a failure, not a measured agreement (QA finding 1)" {
  repo_root="$(REPO_ROOT_FOR_REPORT)"

  emails '[{"threadId":"t1","subject":"a","url":"u1"}]'
  verdicts '[{"threadId":"t1","verdict":"caroline","description":"d","reason":"r"}]'
  jev_stub garbage

  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 0 ]

  shadow_file="$JEV_SHADOW_DIR/email-triage.jsonl"
  [ -f "$shadow_file" ]
  [ "$(wc -l < "$shadow_file")" -eq 1 ]

  row="$(cat "$shadow_file")"
  [ "$(printf '%s' "$row" | jq -r '.rc')" = "3" ]
  [ "$(printf '%s' "$row" | jq -r '.reason')" = "unparseable_answers" ]
  [ "$(printf '%s' "$row" | jq -r '.answers')" = "null" ]

  # QA's report-level assertion: this must be visible and counted, not silently
  # dropped from both agreement AND rc_nonzero the way the old design's
  # second-row backstop could be.
  run bash "$repo_root/scripts/jev-shadow-report.sh" --shadow-dir "$JEV_SHADOW_DIR" --surface email-triage
  [ "$status" -eq 0 ]
  if [[ "$output" != *"malformed_rows=0"* ]]; then
    echo "expected malformed_rows=0 (row_ok tolerates rc 3 / answers null), got: $output" >&2
    return 1
  fi
  if [[ "$output" != *"rc_nonzero=1"* ]]; then
    echo "expected rc_nonzero=1 (the unparseable_answers row must count as a failure), got: $output" >&2
    return 1
  fi
}

@test "a hung jev.sh killed by the OS timeout still yields exactly one row, rc 124, reason os_timeout_kill" {
  emails '[{"threadId":"t1","subject":"a","url":"u1"}]'
  verdicts '[{"threadId":"t1","verdict":"caroline","description":"d","reason":"r"}]'
  JEV_EMAIL_TRIAGE_TIMEOUT_MS=200
  export JEV_EMAIL_TRIAGE_TIMEOUT_MS
  jev_stub hang

  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 0 ]

  shadow_file="$JEV_SHADOW_DIR/email-triage.jsonl"
  [ -f "$shadow_file" ]
  [ "$(wc -l < "$shadow_file")" -eq 1 ]

  row="$(cat "$shadow_file")"
  [ "$(printf '%s' "$row" | jq -r '.rc')" = "124" ]
  [ "$(printf '%s' "$row" | jq -r '.reason')" = "os_timeout_kill" ]
  [ "$(printf '%s' "$row" | jq -r '.item_id')" = "t1" ]
  [ "$(printf '%s' "$row" | jq -r '.surface')" = "email-triage" ]
}

@test "--no-shadow is passed on every jev.sh call" {
  emails '[{"threadId":"t1","subject":"a","url":"u1"}]'
  verdicts '[{"threadId":"t1","verdict":"caroline","description":"d","reason":"r"}]'
  jev_stub ok

  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 0 ]
  if ! grep -q -- '--no-shadow' "$JEV_CALL_LOG"; then
    echo "jev.sh was called without --no-shadow: $(cat "$JEV_CALL_LOG")" >&2
    return 1
  fi
}

@test "two concurrent format-digest.sh runs sharing one shadow file: total rows == total calls, no interleaved lines (QA finding 2)" {
  jev_stub slow_ok
  shared_shadow_dir="$JEV_SHADOW_DIR"
  shared_jev_sh="$JEV_SH"

  n_procs=6
  n_threads_each=4
  declare -a workdirs=()
  declare -a pids=()

  p=0
  while [ "$p" -lt "$n_procs" ]; do
    wd="$(mktemp -d)"
    workdirs+=("$wd")
    mk_thread_files "$wd" "$n_threads_each" "proc${p}"
    (
      WORKDIR="$wd" JEV_SH="$shared_jev_sh" JEV_SHADOW_DIR="$shared_shadow_dir" \
        JEV_CALL_LOG="$JEV_SCRATCH/calls-${p}.log" \
        bash "$SCRIPT" >/dev/null 2>/dev/null
    ) &
    pids+=("$!")
    p=$(( p + 1 ))
  done

  any_failed=0
  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
      any_failed=1
    fi
  done
  [ "$any_failed" -eq 0 ]

  shadow_file="$shared_shadow_dir/email-triage.jsonl"
  [ -f "$shadow_file" ]

  expected_calls=$(( n_procs * n_threads_each ))
  actual_lines="$(wc -l < "$shadow_file")"
  if [ "$actual_lines" -ne "$expected_calls" ]; then
    echo "expected $expected_calls rows (one per call across $n_procs concurrent runs), got $actual_lines" >&2
    return 1
  fi

  # Every line must parse as valid, single-object JSON -- proof no two
  # concurrent appends interleaved bytes within a line.
  bad_lines=0
  while IFS= read -r line; do
    if ! printf '%s' "$line" | jq -e 'type == "object"' >/dev/null 2>&1; then
      bad_lines=$(( bad_lines + 1 ))
    fi
  done < "$shadow_file"
  if [ "$bad_lines" -ne 0 ]; then
    echo "$bad_lines line(s) failed to parse as a single JSON object (interleaved writes)" >&2
    return 1
  fi

  for wd in "${workdirs[@]}"; do
    rm -rf "$wd"
  done
}

@test "flock guards a large row against interleaving (isolates flock as load-bearing, not defense-in-depth)" {
  # A short row's single printf is one write(2), atomic via O_APPEND alone
  # (see the concurrency test above -- that's why it can't falsify flock).
  # A large row (jev.sh's answers object is not size-bounded) makes printf
  # split into several write(2) calls, which two processes CAN interleave
  # without a lock. Several rounds of several parallel writers raise the
  # odds of catching it within one test run, rather than relying on a
  # single roll.
  jev_stub big_ok
  shared_shadow_dir="$JEV_SHADOW_DIR"
  shared_jev_sh="$JEV_SH"

  n_rounds=5
  n_procs=8
  declare -a workdirs=()
  r=0
  while [ "$r" -lt "$n_rounds" ]; do
    declare -a pids=()
    p=0
    while [ "$p" -lt "$n_procs" ]; do
      wd="$(mktemp -d)"
      workdirs+=("$wd")
      mk_thread_files "$wd" 1 "r${r}p${p}"
      (
        WORKDIR="$wd" JEV_SH="$shared_jev_sh" JEV_SHADOW_DIR="$shared_shadow_dir" \
          JEV_CALL_LOG="$JEV_SCRATCH/calls-${r}-${p}.log" \
          bash "$SCRIPT" >/dev/null 2>/dev/null
      ) &
      pids+=("$!")
      p=$(( p + 1 ))
    done
    for pid in "${pids[@]}"; do
      wait "$pid"
    done
    r=$(( r + 1 ))
  done

  shadow_file="$shared_shadow_dir/email-triage.jsonl"
  [ -f "$shadow_file" ]

  expected_calls=$(( n_rounds * n_procs ))
  actual_lines="$(wc -l < "$shadow_file")"
  if [ "$actual_lines" -ne "$expected_calls" ]; then
    echo "expected $expected_calls large rows, got $actual_lines" >&2
    for wd in "${workdirs[@]}"; do rm -rf "$wd"; done
    return 1
  fi

  bad_lines=0
  while IFS= read -r line; do
    if ! printf '%s' "$line" | jq -e 'type == "object" and (.answers.owner.filler | length) == 100000' >/dev/null 2>&1; then
      bad_lines=$(( bad_lines + 1 ))
    fi
  done < "$shadow_file"

  for wd in "${workdirs[@]}"; do
    rm -rf "$wd"
  done

  if [ "$bad_lines" -ne 0 ]; then
    echo "$bad_lines/$expected_calls large row(s) corrupted (interleaved writes) -- flock is load-bearing" >&2
    return 1
  fi
}

@test "shadow file is created at mode 0600 under a normal 022 umask, not 0644 (QA finding)" {
  # The append is a bare `>>`, which creates a missing file under the
  # AMBIENT umask. A dev/CI shell's default 022 umask would otherwise leave
  # customer text world/group-readable on first write.
  emails '[{"threadId":"t1","subject":"a","url":"u1"}]'
  verdicts '[{"threadId":"t1","verdict":"caroline","description":"d","reason":"r"}]'
  jev_stub ok

  umask 022
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 0 ]

  shadow_file="$JEV_SHADOW_DIR/email-triage.jsonl"
  [ -f "$shadow_file" ]
  mode="$(_fd_test_stat_mode "$shadow_file")"
  [ "$mode" = "600" ]
}

@test "an existing 0644 shadow file is tightened to 0600 on the next append (QA finding)" {
  emails '[{"threadId":"t1","subject":"a","url":"u1"}]'
  verdicts '[{"threadId":"t1","verdict":"caroline","description":"d","reason":"r"}]'
  jev_stub ok

  mkdir -p "$JEV_SHADOW_DIR"
  shadow_file="$JEV_SHADOW_DIR/email-triage.jsonl"
  : > "$shadow_file"
  chmod 0644 "$shadow_file"
  mode_before="$(_fd_test_stat_mode "$shadow_file")"
  [ "$mode_before" = "644" ]

  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 0 ]

  mode_after="$(_fd_test_stat_mode "$shadow_file")"
  [ "$mode_after" = "600" ]
}

@test "an unwritable shadow dir logs via logger, leaves the digest byte-identical, exits 0, and still removes WORKDIR" {
  emails '[{"threadId":"t1","subject":"a","url":"u1"}]'
  verdicts '[{"threadId":"t1","verdict":"caroline","description":"d","reason":"r"}]'

  # Baseline: no JEV_SH at all, for a byte-identical comparison.
  run --separate-stderr bash "$SCRIPT"
  baseline_status="$status"
  baseline_output="$output"

  WORKDIR="$(mktemp -d)"
  export WORKDIR
  emails '[{"threadId":"t1","subject":"a","url":"u1"}]'
  verdicts '[{"threadId":"t1","verdict":"caroline","description":"d","reason":"r"}]'
  jev_stub ok

  # CI/local may run as root, which ignores chmod 500 on a dir. Make the
  # shadow dir's PARENT a plain file instead, so mkdir -p genuinely fails
  # regardless of uid.
  blocker="$JEV_SCRATCH/blocker"
  : > "$blocker"
  JEV_SHADOW_DIR="$blocker/shadow"
  export JEV_SHADOW_DIR

  logger_bin_dir="$JEV_SCRATCH/bin"
  mkdir -p "$logger_bin_dir"
  logger_log="$JEV_SCRATCH/logger.log"
  cat > "$logger_bin_dir/logger" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$logger_log"
STUB
  chmod +x "$logger_bin_dir/logger"
  PATH="$logger_bin_dir:$PATH"
  export PATH

  local_workdir="$WORKDIR"
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq "$baseline_status" ]
  [ "$output" = "$baseline_output" ]
  [ "$status" -eq 0 ]
  [ ! -d "$local_workdir" ]

  [ -s "$logger_log" ]
  if ! grep -q 't1' "$logger_log"; then
    echo "logger was not called with the item id: $(cat "$logger_log")" >&2
    return 1
  fi
  # A successful call (rc 0, valid answers) has no reason -- the row itself
  # simply failed to persist, so the logger fallback reports reason=none.
  if ! grep -q 'rc=0, reason=none' "$logger_log"; then
    echo "logger was not called with the expected rc/reason: $(cat "$logger_log")" >&2
    return 1
  fi
  WORKDIR=""
}

@test "an answers object past the 128 KB argv limit is still recorded, with its answers" {
  # Linux caps ONE execve argument at MAX_ARG_STRLEN (128 KB). Passing the
  # answers to jq as a single argv string made any larger response fail with
  # "Argument list too long" and fall silently into the logger path.
  emails '[{"threadId":"t1","subject":"a","url":"u1"}]'
  verdicts '[{"threadId":"t1","verdict":"caroline","description":"d","reason":"r"}]'
  jev_stub huge_ok

  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 0 ]

  shadow_file="$JEV_SHADOW_DIR/email-triage.jsonl"
  [ -f "$shadow_file" ]
  [ "$(wc -l < "$shadow_file")" -eq 1 ]
  row="$(cat "$shadow_file")"
  [ "$(printf '%s' "$row" | jq -r '.rc')" = "0" ]
  [ "$(printf '%s' "$row" | jq -r '.answers.owner.choice')" = "caroline" ]
  [ "$(printf '%s' "$row" | jq -r '.answers.owner.filler | length')" -eq 200000 ]
}

