#!/usr/bin/env bats
# The SCHEDULER wiring for the churn-risk signal (firstmate churn-risk-signal-prevent-p1).
#
# Why this file exists: scripts/tests/test_churn_risk.py covers the store, the risk
# file, the reader, the cancel alert and the weekly line, and every one of those cases
# passes with the /etc/cron.d block DELETED. A fully tested program that never runs is
# the most complete kind of silent failure this repo can ship, and the green suite is
# exactly what makes nobody look (the same reason install-aux-units-sentry.bats exists).
#
# These tests EXECUTE the writer the installer runs (scripts/churn/install-cron.sh) into
# a temp root and assert what it installed: the parsed schedule entries, the file mode,
# the log targets, and that the command lines carry no env assignments. They never grep
# the installer's source text - a heredoc that is commented out, duplicated, or emitted
# under a condition that never fires satisfies a text match and proves nothing
# (firstmate ruling 2026-11-04, [key=nm-review3-bats-source-text]).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"
CRON_WRITER="$HYDRA_REPO/scripts/churn/install-cron.sh"

setup() {
  TMP="$(mktemp -d)"
  export CRON_DIR="$TMP/cron.d"
  export STATE_DIR="$TMP/var/lib/hydra/churn"
  export HYDRA_ROOT="$TMP/opt/hydra"
  mkdir -p "$CRON_DIR" "$HYDRA_ROOT/scripts/churn"
  CRONFILE="$CRON_DIR/hydra-churn-risk"
}

teardown() {
  # NOT an `EXIT` trap: in bats 1.14 a trap armed inside setup() swallows the failure
  # report of a FAILING test (it printed "Executed 0 instead of expected 1 tests" and
  # exited 0), i.e. the suite went green by losing the case. Reproduced 2026-11-04.
  rm -rf "$TMP"
}

install_cron() {
  run env CRON_DIR="$CRON_DIR" STATE_DIR="$STATE_DIR" HYDRA_ROOT="$HYDRA_ROOT" \
    bash "$CRON_WRITER"
  [ "$status" -eq 0 ]
}

@test "both the installer and the writer ship executable" {
  [ -x "$INSTALLER" ]
  [ -x "$CRON_WRITER" ]
}

@test "the INSTALLER's argv decides which tree the cron lines name" {
  # The seam a temp-root writer test cannot see: install-aux-units.sh takes the
  # deployed tree as argv, and the cron lines must name THAT tree. HYDRA_ROOT is a
  # plain variable inside the installer (never exported), so a child process that is
  # not handed it silently falls back to /opt/hydra and writes cron entries pointing
  # at the wrong checkout for any non-default root (firstmate 2026-11-04,
  # [key=nm-review5-install-cron-scope]). HYDRA_STOP_AFTER=churn-cron makes the real
  # installer runnable unprivileged with only the cron file as a side effect.
  staging="$TMP/srv/hydra-staging"
  mkdir -p "$staging/scripts/churn"
  install -m 755 "$CRON_WRITER" "$staging/scripts/churn/install-cron.sh"
  for f in nightly.sh cancel_with_open_issue.sh weekly_line.sh; do
    install -m 755 "$HYDRA_REPO/scripts/churn/$f" "$staging/scripts/churn/$f"
  done
  # `env -u HYDRA_ROOT` on purpose: the installer must hand the argv root to its
  # children ITSELF. (setup() exports HYDRA_ROOT for the writer tests, and an inherited
  # exported variable keeps its export attribute across an assignment, which would mask
  # exactly the bug this case exists for.)
  # NOT via `run`: a missing child (the very failure this case reproduces on a sandbox
  # with no /opt/hydra) makes bats treat the case as not-executed and quietly pass CI
  rc=0
  env -u HYDRA_ROOT CRON_DIR="$CRON_DIR" STATE_DIR="$STATE_DIR" HYDRA_STOP_AFTER=churn-cron bash "$INSTALLER" "$staging" || rc=$?
  [ "$rc" -eq 0 ]
  [ -f "$CRONFILE" ]
  run grep -q "$staging/scripts/churn/nightly.sh" "$CRONFILE"
  [ "$status" -eq 0 ]
  if grep -q "/opt/hydra/scripts/churn" "$CRONFILE"; then
    echo "the cron lines fell back to /opt/hydra instead of the argv root"
    false
  fi
  # and the state dir it names comes from the environment, not a hardcoded default
  run grep -c "$STATE_DIR" "$CRONFILE"
  [ "$output" = "3" ]   # one log per entry
}

@test "installing writes exactly one cron file, mode 644" {
  install_cron
  [ -f "$CRONFILE" ]
  run stat -c '%a' "$CRONFILE"
  [ "$output" = "644" ]
  run grep -c 'MANAGED BY scripts/install-aux-units.sh' "$CRONFILE"
  [ "$output" = "1" ]
}

@test "the installed schedule is the three documented entries, in order" {
  install_cron
  run grep -E '^[0-9*]' "$CRONFILE"
  # 04:15Z daily: the store is the input for everything else, and a per-hour sweep
  # would spend the Intercom/Trino budget for no new fact.
  # :20 hourly: a cancel is the last moment a fix lands before the charge, and :20
  # never queues behind the on-the-hour outbound families.
  # Monday 08:00Z: the weekly churned-with-open-issue line.
  expected="15 4 * * * root $HYDRA_ROOT/scripts/churn/nightly.sh >> $STATE_DIR/nightly.log 2>&1
20 * * * * root $HYDRA_ROOT/scripts/churn/cancel_with_open_issue.sh >> $STATE_DIR/alert.log 2>&1
0 8 * * 1 root $HYDRA_ROOT/scripts/churn/weekly_line.sh >> $STATE_DIR/weekly.log 2>&1"
  [ "$output" = "$expected" ]
}

@test "every installed command names a script that exists and is executable" {
  install_cron
  run grep -oE 'scripts/churn/[a-z_]+\.sh' "$CRONFILE"
  [ -n "$output" ]
  while read -r rel; do
    [ -x "$HYDRA_REPO/$rel" ] || { echo "missing or not executable: $rel"; false; }
  done <<< "$output"
}

@test "the installed command lines carry NO env assignments - the levers are flag FILES" {
  # /etc/cron.d/hydra-churn-risk is regenerated wholesale on every deploy, so a knob set
  # here disappears the moment a fix-forward ships. The kill switch is a flag file and
  # the thresholds are policy DATA, both read at run time. The PATH line is the one
  # permitted assignment, and it is not a churn knob.
  install_cron
  run grep -E '^[0-9*]' "$CRONFILE"
  [ -n "$output" ]
  [[ "$output" != *"CHURN_"* ]]
  [[ "$output" != *"="* ]]
}

@test "the state dir is created 0700 before any cron run, outside the rsync'd tree" {
  install_cron
  [ -d "$STATE_DIR" ]
  run stat -c '%a' "$STATE_DIR"
  [ "$output" = "700" ]
  # /var/lib, never /opt/hydra: the deploy rsync overwrites /opt/hydra nightly, and the
  # store is history that must outlive a bad deploy.
  [[ "$STATE_DIR" != *"/opt/hydra/"* ]]
}

@test "installing twice converges (one managed block, same bytes)" {
  install_cron
  first="$(cat "$CRONFILE")"
  install_cron
  [ "$(cat "$CRONFILE")" = "$first" ]
  run grep -c 'MANAGED BY' "$CRONFILE"
  [ "$output" = "1" ]
}

@test "a missing cron dir fails loud instead of silently installing nothing" {
  CRON_DIR="$TMP/nope" run env CRON_DIR="$TMP/nope" STATE_DIR="$STATE_DIR" \
    HYDRA_ROOT="$HYDRA_ROOT" bash "$CRON_WRITER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FATAL cron dir missing"* ]]
}

@test "the reader ships executable, and the churn signal stays a ONE-WAY input" {
  # The reader is the one shared entrypoint the consumer one-liners will call by absolute
  # path, so it ships executable; a rename would silently turn the sort override off
  # everywhere (fail-open, so nothing would page).
  [ -x "$HYDRA_REPO/scripts/churn/risk_reader.py" ]
  # The ruling of 2026-11-04 17:16Z was a SCOPE LOCK on the churn PR: wiring the churn
  # signal into credit-verify-outbound.sh or credit_review/decide.py needed its own PR
  # (d2 + Fable). That PR is #1774 and it merged, so the lock has done its job - and as a
  # permanent repo invariant it was a landmine: it asserted that NO PR may ever touch
  # decide.py, so every later credit PR went red on a file it was supposed to change
  # (hydra #1782, 2026-11-05: the decider support-only arm touches decide.py by design).
  # What survives is the invariant the lock was protecting: the dependency is ONE-WAY.
  # The credit path may shell out to this reader; the reader may never import the credit
  # path, so the churn signal cannot grow a write into the credit send by accident.
  ! grep -qE '^[[:space:]]*(from|import)[[:space:]]+credit_review' "$HYDRA_REPO/scripts/churn/risk_reader.py"
  ! grep -qE 'credit_review' "$HYDRA_REPO/scripts/churn/risk_reader.py"
}
