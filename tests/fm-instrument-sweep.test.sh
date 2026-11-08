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

sweep_tsv() { # state probe-dir [extra args...]
  local state=$1 probe=$2
  shift 2
  "$SWEEP" --state "$state" --probe-dir "$probe" --tsv "$@" 2>&1
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
