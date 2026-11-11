#!/usr/bin/env bash
# Behavior tests for fm-instrument-sweep.sh.
#
# The meta-proof is the point: a corpus with one planted defect per class must
# produce a defect finding of that exact class at that exact line, and the same
# corpus with the defects fixed must produce no findings at all. A sweep that
# reports clean on a corpus containing a planted defect has failed here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SWEEP="$ROOT/bin/fm-instrument-sweep.sh"
REGISTER="$ROOT/bin/fm-check-register.sh"
FIXTURES="$ROOT/tests/fixtures/instrument-sweep"
TMP_ROOT=$(fm_test_tmproot fm-instrument-sweep)

# One fixture per defect class; the fixture id is the state/<id>.check.sh name.
FIXTURE_IDS=(vacuous rate identical orphan negative stale failure)
CLASSES=(
  vacuous-comparison
  rate-without-denominator
  identical-output
  orphan-marker
  discarded-negative-assertion
  stale-reading
  failure-path-exit-zero
)

# planted_line reports the line the fixture declares its planted defect on. The
# fixture names the class in a `# planted-defect: <class>` comment and plants the
# defect on the following line, so the test never hardcodes a line number that a
# later fixture edit would silently invalidate.
planted_line() { # fixture-file class -> line number
  awk -v c="$2" '
    index($0, "# planted-defect: " c) == 1 { print FNR + 1; exit }
  ' "$1"
}

# arm_corpus registers every check a test just wrote, so the sweep analyses it.
# A corpus that is not armed is only UNPROVEN, and asserting "no findings" there
# would pass no matter what the detector does.
arm_corpus() { # home-dir check-id...
  local home=$1 id
  shift
  for id in "$@"; do
    FM_HOME="$home" "$REGISTER" "$id" >/dev/null 2>&1 ||
      fail "could not register the test corpus check $id"
  done
}

sweep_tsv() { # state probe-dir [extra args...]
  local state=$1 probe=${2:-}
  if [ -n "$probe" ]; then
    shift 2
  else
    shift 1
  fi
  if [ -n "$probe" ]; then
    "$SWEEP" --state "$state" --probe-dir "$probe" --tsv "$@" 2>&1
  else
    "$SWEEP" --state "$state" --tsv "$@" 2>&1
  fi
}

test_planted_corpus_names_every_class_at_its_line() {
  local corpus out class id file line rows
  corpus="$FIXTURES/planted"
  out=$(sweep_tsv "$corpus" "$corpus") || fail "sweep failed on the planted corpus:"$'\n'"$out"

  rows=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "finding"')
  [ -n "$rows" ] || fail "sweep reported no findings on a corpus of seven planted defects:"$'\n'"$out"

  local i=0
  for class in "${CLASSES[@]}"; do
    id=${FIXTURE_IDS[$i]}
    i=$((i + 1))
    file="$corpus/$id.check.sh"
    line=$(planted_line "$file" "$class")
    [ -n "$line" ] || fail "fixture $file does not declare # planted-defect: $class"
    printf '%s\n' "$rows" | awk -F'\t' -v id="$id" -v c="$class" -v l="$line" '
      $2 == id && $3 == c && $5 == l { found = 1 }
      END { exit !found }
    ' || fail "sweep did not report $class at $file:$line:"$'\n'"$rows"
  done

  printf '%s\n' "$out" | awk -F'\t' -v n="${#CLASSES[@]}" '
    $1 == "verdict" && $3 == "DEFECT" { d++ }
    $1 == "summary" { for (i = 2; i <= NF; i++) if ($i ~ /^defect=/) { split($i, a, "="); if (a[2] != n) bad = 1 } }
    END { exit !(d == n && !bad) }
  ' || fail "planted corpus did not produce one DEFECT verdict per class:"$'\n'"$out"

  pass "seven planted defects are named by class and line"
}

test_fixed_corpus_is_silent() {
  local corpus out
  corpus="$FIXTURES/fixed"
  out=$(sweep_tsv "$corpus" "$corpus") || fail "sweep failed on the fixed corpus:"$'\n'"$out"

  printf '%s\n' "$out" | awk -F'\t' '$1 == "finding" { print; found = 1 } END { exit !found }' >/dev/null &&
    fail "sweep still reports findings after every planted defect was fixed:"$'\n'"$out"

  printf '%s\n' "$out" | awk -F'\t' -v n="${#CLASSES[@]}" '
    $1 == "verdict" && $3 == "PROVEN-DISTINGUISHING" { p++ }
    $1 == "summary" { for (i = 2; i <= NF; i++) if ($i ~ /^proven=/) { split($i, a, "="); if (a[2] != n) bad = 1 } }
    END { exit !(p == n && !bad) }
  ' || fail "fixed corpus was not proven distinguishing by the differential probe:"$'\n'"$out"

  pass "fixing every planted defect silences the sweep and proves each check"
}

list_state() { # dir listing that is comparable before and after a sweep
  if ls --time-style=full-iso -la "$1" >/dev/null 2>&1; then
    ls -la --time-style=full-iso "$1"
  else
    ls -la "$1"
  fi
}

test_registered_corpus_reads_trust_and_writes_nothing() {
  local home corpus probe before after id out
  home="$TMP_ROOT/registered"
  corpus="$home/state"
  probe="$home/probes"
  mkdir -p "$corpus" "$probe"
  cp "$FIXTURES"/planted/*.check.sh "$corpus/"
  cp "$FIXTURES"/planted/*.probe.sh "$probe/"
  cp "$FIXTURES/planted/instrument-sweep.probes" "$probe/"
  chmod 0700 "$corpus"/*.check.sh
  for id in vacuous rate identical orphan negative stale failure; do
    FM_HOME="$home" "$REGISTER" "$id" >/dev/null 2>&1 ||
      fail "could not register fixture check $id"
  done

  before=$(list_state "$corpus")
  out=$(sweep_tsv "$corpus" "$probe") || fail "sweep failed on a registered corpus:"$'\n'"$out"
  after=$(list_state "$corpus")

  [ "$before" = "$after" ] || fail "sweep modified the state directory it read"

  printf '%s\n' "$out" | awk -F'\t' -v n="${#CLASSES[@]}" '
    $1 == "verdict" && $3 == "DEFECT" { d++ }
    END { exit !(d == n) }
  ' || fail "registered corpus did not report one defect per planted class:"$'\n'"$out"

  case $out in
  *"trust=mismatch"*) fail "registered checks were not read as trusted owners" ;;
  esac

  pass "a registered corpus keeps its trust binding and stays untouched"
}

test_untrusted_check_is_unproven_not_proven() {
  local home corpus out reason
  home="$TMP_ROOT/untrusted"
  corpus="$home/state"
  mkdir -p "$corpus"
  cat > "$corpus/plain.check.sh" <<'SH'
#!/usr/bin/env bash
set -u
F="$FM_PROBE_ROOT/report.txt"
if [ -s "$F" ]; then
  echo "reported"
else
  echo "missing"
fi
SH
  chmod 0700 "$corpus/plain.check.sh"

  out=$("$SWEEP" --state "$corpus" --tsv 2>&1) || fail "sweep failed without a trust binding:"$'\n'"$out"
  printf '%s\n' "$out" | awk -F'\t' '$1 == "finding" { print; found = 1 } END { exit !found }' >/dev/null &&
    fail "a check the sweep cannot analyse was reported as a defect:"$'\n'"$out"
  reason=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "verdict" && $3 == "UNPROVEN" { print $4; exit }')
  [ -n "$reason" ] || fail "a check with no differential evidence was not reported UNPROVEN:"$'\n'"$out"
  case $reason in
  *trust*) ;;
  *) fail "UNPROVEN reason did not name the missing trust binding: $reason" ;;
  esac

  pass "absence of evidence is reported as UNPROVEN with a reason"
}

test_probe_dir_without_manifest_is_refused() {
  local corpus probe out status
  corpus="$FIXTURES/planted"
  probe="$TMP_ROOT/undeclared-probes"
  mkdir -p "$probe"
  cp "$FIXTURES"/planted/identical.probe.sh "$probe/"

  status=0
  "$SWEEP" --state "$corpus" --probe-dir "$probe" >"$TMP_ROOT/refuse.out" 2>&1 || status=$?
  expect_code 2 "$status" "sweep with an undeclared probe directory"
  assert_contains "$(cat "$TMP_ROOT/refuse.out")" "instrument-sweep.probes" \
    "probe refusal did not name the missing declaration"
  pass "an undeclared probe directory is refused, so live checks are never executed"
}

test_fail_on_defect_exit_codes() {
  local status corpus
  status=0
  "$SWEEP" --state "$FIXTURES/planted" --probe-dir "$FIXTURES/planted" \
    --fail-on-defect >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "sweep --fail-on-defect on the planted corpus"

  status=0
  "$SWEEP" --state "$FIXTURES/fixed" --probe-dir "$FIXTURES/fixed" \
    --fail-on-defect >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "sweep --fail-on-defect on the fixed corpus"

  pass "--fail-on-defect follows the findings, not the corpus"
}

test_probe_that_cannot_run_is_unproven() {
  local home corpus probe out
  home="$TMP_ROOT/broken-probe"
  corpus="$home/state"
  probe="$home/probes"
  mkdir -p "$corpus" "$probe"
  cat > "$corpus/flaky.check.sh" <<'SH'
#!/usr/bin/env bash
echo "nothing here"
SH
  chmod 0700 "$corpus/flaky.check.sh"
  cat > "$probe/flaky.probe.sh" <<'SH'
#!/usr/bin/env bash
echo "probe cannot set up" >&2
exit 2
SH
  chmod +x "$probe/flaky.probe.sh"
  cp "$FIXTURES/planted/instrument-sweep.probes" "$probe/"

  out=$(sweep_tsv "$corpus" "$probe") || fail "sweep failed when a probe could not run:"$'\n'"$out"
  printf '%s\n' "$out" | awk -F'\t' '$1 == "verdict" { print $3 }' | grep -qx 'UNPROVEN' ||
    fail "a probe that could not set up was not reported UNPROVEN:"$'\n'"$out"
  pass "a probe that cannot set up reports UNPROVEN, never a pass"
}

test_planted_corpus_names_every_class_at_its_line
test_fixed_corpus_is_silent
test_registered_corpus_reads_trust_and_writes_nothing
test_untrusted_check_is_unproven_not_proven
test_probe_dir_without_manifest_is_refused
test_fail_on_defect_exit_codes
test_probe_that_cannot_run_is_unproven

test_probe_evidence_does_not_leak_to_the_next_check() {
  local home corpus probe out
  home="$TMP_ROOT/probe-isolation"
  corpus="$home/state"
  probe="$home/probes"
  mkdir -p "$corpus" "$probe"
  cat > "$corpus/probed.check.sh" <<'EOS'
#!/usr/bin/env bash
set -u
F="$FM_PROBE_ROOT/fact"
if [ -s "$F" ]; then
  echo "fact present"
else
  echo "fact absent"
fi
EOS
  cat > "$probe/probed.probe.sh" <<'EOS'
#!/usr/bin/env bash
set -u
case ${FM_PROBE_VARIANT:-} in
healthy) printf 'present\n' > "$FM_PROBE_ROOT/fact" ;;
broken) rm -f -- "$FM_PROBE_ROOT/fact" ;;
*) exit 2 ;;
esac
EOS
  cat > "$corpus/unprobed.check.sh" <<'EOS'
#!/usr/bin/env bash
set -u
F="$FM_PROBE_ROOT/other-fact"
if [ -s "$F" ]; then
  echo "fact present"
else
  echo "fact absent"
fi
EOS
  chmod 0700 "$corpus"/*.check.sh
  chmod +x "$probe/probed.probe.sh"
  cp "$FIXTURES/planted/instrument-sweep.probes" "$probe/"

  out=$(sweep_tsv "$corpus" "$probe") || fail "sweep failed on a probe-isolation corpus:"$'\n'"$out"
  printf '%s\n' "$out" | awk -F'\t' '
    $1 == "verdict" && $2 == "unprobed" { found = ($3 == "UNPROVEN") }
    END { exit !found }
  ' || fail "an unprobed check inherited the previous check's probe evidence:"$'\n'"$out"

  pass "probe evidence does not leak across checks"
}

test_every_defect_carries_its_exact_source_line() {
  local out kind id class file line rest snippet actual
  out=$(sweep_tsv "$FIXTURES/planted" "$FIXTURES/planted") ||
    fail "sweep failed on the planted corpus:"$'\n'"$out"

  while IFS=$'\t' read -r kind id class file line rest; do
    [ "$kind" = finding ] || continue
    case $rest in
    *" [source: "*']') ;;
    *) fail "$class finding for $id carried no exact source snippet: $rest" ;;
    esac
    snippet=${rest#* \[source: }
    snippet=${snippet%]}
    actual=$(sed -n "${line}p" "$file" | tr '\t' ' ')
    [ "$snippet" = "$actual" ] ||
      fail "$class finding at $file:$line carried '$snippet' instead of '$actual'"
  done < <(printf '%s\n' "$out")

  pass "every defect carries its exact source line"
}

test_zero_guarded_rate_is_not_a_defect() {
  local home corpus out
  home="$TMP_ROOT/guarded-rate"
  corpus="$home/state"
  mkdir -p "$corpus"
  cat > "$corpus/eq-guard.check.sh" <<'EOS'
#!/usr/bin/env bash
set -u
total=$(wc -l < "$FM_PROBE_ROOT/input")
errors=$(grep -c error "$FM_PROBE_ROOT/input" || true)
if [ "$total" -eq 0 ]; then
  echo "no input"
  exit 0
fi
pct=$((errors * 100 / total))
echo "$pct"
EOS
  cat > "$corpus/empty-guard.check.sh" <<'EOS'
#!/usr/bin/env bash
set -u
total=$(wc -l < "$FM_PROBE_ROOT/input")
errors=$(grep -c error "$FM_PROBE_ROOT/input" || true)
if [ -z "$total" ]; then
  echo "no input"
  exit 0
fi
pct=$((errors * 100 / total))
echo "$pct"
EOS
  chmod 0700 "$corpus"/*.check.sh
  arm_corpus "$home" eq-guard empty-guard

  out=$("$SWEEP" --state "$corpus" --tsv 2>&1) || fail "sweep failed on zero-guarded rates:"$'\n'"$out"
  printf '%s\n' "$out" | awk -F'\t' '$1 == "finding" && $3 == "rate-without-denominator" { found = 1 } END { exit found }' ||
    fail "a rate whose denominator is guarded against zero was reported as a defect:"$'\n'"$out"

  pass "a zero-guarded rate is not reported as a denominator defect"
}

test_stderr_only_failure_branch_is_a_defect() {
  local home corpus out
  home="$TMP_ROOT/stderr-branch"
  corpus="$home/state"
  mkdir -p "$corpus"
  # The report goes to stderr and the branch exits 0, so the reader is never
  # woken: the check looks healthy while it is unmeasurable.
  cat > "$corpus/silent-failure.check.sh" <<'EOS'
#!/usr/bin/env bash
set -u
F="$1"
if [ ! -r "$F" ]; then
  echo "ledger is unreadable" >&2
  exit 0
fi
echo ledger-ok
EOS
  # The stdout variant wakes its reader and is not this defect.
  cat > "$corpus/loud-failure.check.sh" <<'EOS'
#!/usr/bin/env bash
set -u
F="$1"
if [ ! -r "$F" ]; then
  echo "ledger is unreadable"
  exit 0
fi
echo ledger-ok
EOS
  chmod 0700 "$corpus"/*.check.sh
  arm_corpus "$home" silent-failure loud-failure

  out=$(sweep_tsv "$corpus") || fail "sweep failed on failure branches:"$'\n'"$out"
  printf '%s\n' "$out" | awk -F'\t' '$1 == "finding" && $3 == "failure-path-exit-zero" && $2 == "silent-failure" { found = 1 } END { exit !found }' ||
    fail "a stderr-only failure branch that exits 0 was not reported:"$'\n'"$out"
  printf '%s\n' "$out" | awk -F'\t' '$1 == "finding" && $3 == "failure-path-exit-zero" && $2 == "loud-failure" { found = 1 } END { exit found }' ||
    fail "a failure branch that prints to stdout was reported as silence:"$'\n'"$out"

  pass "only a stderr-only failure branch that exits 0 counts as silence"
}

test_literal_divisor_is_not_a_rate_defect() {
  local home corpus out
  home="$TMP_ROOT/literal-divisor"
  corpus="$home/state"
  mkdir -p "$corpus"
  # bucket_width=1000 is a bucket, not a denominator that can collapse to zero.
  cat > "$corpus/bucket.check.sh" <<'EOS'
#!/usr/bin/env bash
set -u
BAND=1000
silent=2500
band=$(( silent / BAND ))
echo "band $band"
EOS
  chmod 0700 "$corpus"/*.check.sh
  arm_corpus "$home" bucket

  out=$(sweep_tsv "$corpus") || fail "sweep failed on a literal divisor:"$'\n'"$out"
  printf '%s\n' "$out" | awk -F'\t' '$1 == "finding" && $3 == "rate-without-denominator" { found = 1 } END { exit found }' ||
    fail "a divisor bound to a nonzero literal was reported as a rate defect:"$'\n'"$out"

  pass "a divisor bound to a nonzero literal is not a rate defect"
}

test_identical_output_falls_back_to_the_output_statement() {
  local home corpus probe out line
  home="$TMP_ROOT/emitting-line"
  corpus="$home/state"
  probe="$home/probes"
  mkdir -p "$corpus" "$probe"
  cat > "$corpus/dynamic.check.sh" <<'EOS'
#!/usr/bin/env bash
# The captured output carries no literal, so no echo/printf line can match it.
set -u
F="$FM_PROBE_ROOT/fact"
cat "$F" >/dev/null 2>&1
MESSAGE="queue is clear"
printf '%s\n' "$MESSAGE"
EOS
  cat > "$probe/dynamic.probe.sh" <<'EOS'
#!/usr/bin/env bash
set -u
case ${FM_PROBE_VARIANT:-} in
healthy) printf 'healthy\n' > "$FM_PROBE_ROOT/fact" ;;
broken) printf 'broken\n' > "$FM_PROBE_ROOT/fact" ;;
*) exit 2 ;;
esac
EOS
  chmod 0700 "$corpus/dynamic.check.sh"
  chmod +x "$probe/dynamic.probe.sh"
  cp "$FIXTURES/planted/instrument-sweep.probes" "$probe/"

  out=$(sweep_tsv "$corpus" "$probe") || fail "sweep failed on a dynamic-output check:"$'\n'"$out"
  line=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "finding" && $3 == "identical-output" { print $5; exit }')
  [ -n "$line" ] || fail "dynamic identical output was not reported:"$'\n'"$out"
  [ "$line" != 1 ] || fail "identical-output fell back to the shebang line instead of the output statement:"$'\n'"$out"

  pass "identical-output falls back to the output statement, not line 1"
}

test_probe_evidence_does_not_leak_to_the_next_check
test_every_defect_carries_its_exact_source_line
test_zero_guarded_rate_is_not_a_defect
test_literal_divisor_is_not_a_rate_defect
test_stderr_only_failure_branch_is_a_defect
test_identical_output_falls_back_to_the_output_statement
