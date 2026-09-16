#!/usr/bin/env bats
# scripts/install-aux-units.sh -> wire_unit_failure_paging()
#
# hydra-unit-failed@.service is the generic pager for a failing timer-driven
# oneshot. Until this change exactly ONE unit referenced it, which is why five
# units failed unnoticed for 6-9 days (hydra-release-watch every 5 min since
# 2026-09-07; both retention timers and cs-selfserve-backlog-collect since the
# 2.0 cutover; clickup-sla-digest daily). These tests pin the properties that
# make wiring the rest safe, and they exercise the REAL function extracted from
# the installer -- nothing here can reach systemd or a real unit.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  export AUX_SYSTEMD_UNIT_DIR="$TEST_TMPDIR/units"
  mkdir -p "$AUX_SYSTEMD_UNIT_DIR"
  RELOADS="$TEST_TMPDIR/reloads"; export RELOADS
  : > "$RELOADS"
  # Extract the table + the function; sourcing the installer would try to
  # install the whole fleet.
  SNIPPET="$TEST_TMPDIR/snippet.sh"
  {
    echo 'log() { echo "$*"; }'
    # $STUB_RELOAD_RC makes `daemon-reload` fail, so the propagation path is
    # exercised rather than assumed.
    echo 'systemctl() { echo "$*" >> "$RELOADS"; if [ "$1" = "daemon-reload" ]; then return "${STUB_RELOAD_RC:-0}"; fi; return 0; }'
    # $STUB_MV_FAIL_FOR makes the rename fail for one unit. A chmod-based
    # injection does NOT work here: bats runs as root in CI and root ignores
    # directory permissions, so the rewrite succeeded and the test passed for
    # the wrong reason.
    echo 'mv() { if [ -n "${STUB_MV_FAIL_FOR:-}" ]; then case "$*" in *"$STUB_MV_FAIL_FOR"*) return 1 ;; esac; fi; command mv "$@"; }'
    sed -n '/^AUX_ONFAILURE_UNITS=(/,/^)/p' "$INSTALLER"
    sed -n '/^wire_unit_failure_paging() {/,/^}/p' "$INSTALLER"
  } > "$SNIPPET"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

_mk_unit() {  # _mk_unit <name> [extra-unit-line]
  printf '[Unit]\nDescription=%s\n%s\n[Service]\nType=oneshot\nExecStart=/bin/true\n' \
    "$1" "${2:-}" > "$AUX_SYSTEMD_UNIT_DIR/$1"
}
_run_pass() { run bash -c ". '$SNIPPET'; wire_unit_failure_paging"; }

@test "a table unit with no OnFailure gains exactly one, directly after [Unit]" {
  _mk_unit hydra-release-watch.service
  _run_pass
  [ "$status" -eq 0 ]
  local f="$AUX_SYSTEMD_UNIT_DIR/hydra-release-watch.service"
  [ "$(grep -c '^OnFailure=hydra-unit-failed@%n\.service$' "$f")" -eq 1 ]
  # position matters only in that it must be inside [Unit], not [Service]
  [ "$(sed -n '2p' "$f")" = "OnFailure=hydra-unit-failed@%n.service" ]
}

@test "the pass is IDEMPOTENT: a second run adds nothing" {
  # install-aux-units.sh runs on every deploy, so a non-idempotent insert would
  # accumulate one OnFailure= line per deploy forever.
  _mk_unit hydra-release-watch.service
  _run_pass
  _run_pass
  [ "$status" -eq 0 ]
  [ "$(grep -c '^OnFailure=' "$AUX_SYSTEMD_UNIT_DIR/hydra-release-watch.service")" -eq 1 ]
}

@test "a unit that already declares OnFailure is left byte-identical" {
  _mk_unit codex-canonical-refresh.service 'OnFailure=something-else.service'
  local before; before="$(cat "$AUX_SYSTEMD_UNIT_DIR/codex-canonical-refresh.service")"
  _run_pass
  [ "$(cat "$AUX_SYSTEMD_UNIT_DIR/codex-canonical-refresh.service")" = "$before" ]
}

@test "a unit NOT in the table is never touched" {
  # The table exists precisely so this pass cannot attach our pager to units
  # this installer never wrote (system units, other installers).
  _mk_unit some-foreign.service
  local before; before="$(cat "$AUX_SYSTEMD_UNIT_DIR/some-foreign.service")"
  _run_pass
  [ "$(cat "$AUX_SYSTEMD_UNIT_DIR/some-foreign.service")" = "$before" ]
}

@test "the pager itself is absent from the table (OnFailure on itself loops)" {
  run bash -c ". '$SNIPPET'; printf '%s\n' \"\${AUX_ONFAILURE_UNITS[@]}\""
  [ "$status" -eq 0 ]
  [[ "$output" != *"hydra-unit-failed"* ]]
}

@test "a unit with no [Unit] section WARNs, is left untouched, and FAILS the run" {
  # The failure half is load-bearing: a managed unit we cannot wire is a unit
  # that will fail silently forever, so it must not be reported as success.
  # Without the status assertion the `broken` counter for this path is
  # unfalsifiable — removing it changed nothing observable.
  printf '[Service]\nType=oneshot\n' > "$AUX_SYSTEMD_UNIT_DIR/hydra-peer-labels.service"
  local before; before="$(cat "$AUX_SYSTEMD_UNIT_DIR/hydra-peer-labels.service")"
  _run_pass
  [ "$status" -ne 0 ]
  [[ "$output" == *"has no [Unit] section"* ]]
  [[ "$output" == *"FATAL"* ]]
  [ "$(cat "$AUX_SYSTEMD_UNIT_DIR/hydra-peer-labels.service")" = "$before" ]
}

@test "a table unit that is not installed is counted, not an error" {
  # Some units are gated behind a runtime check and legitimately absent.
  _run_pass
  [ "$status" -eq 0 ]
  [[ "$output" == *"not installed"* ]]
}

@test "daemon-reload runs when a managed unit CARRIES the directive, not only when written" {
  # This test previously asserted "reload only when something was actually
  # wired", and that premise is exactly what created the retry latch a QA round
  # caught: a failed first reload leaves the files mutated and systemd stale, so
  # on the next run wired=0, the reload is skipped, and the installer reports
  # success forever. Inverted deliberately rather than deleted, so the record
  # shows the assertion changed and why.
  _run_pass                                  # nothing installed -> nothing to reload
  [ ! -s "$RELOADS" ]
  _mk_unit hydra-daily-audit.service
  _run_pass                                  # newly wired -> reload
  grep -q 'daemon-reload' "$RELOADS"
  : > "$RELOADS"
  _run_pass                                  # already present -> reload AGAIN
  grep -q 'daemon-reload' "$RELOADS"
}

@test "the template unit is wired too (it has two live instances)" {
  # %n expands to the FULL name, e.g. hydra-session-thread-retention@main.service,
  # which is exactly what notify-unit-failed.sh needs as its argument.
  _mk_unit 'hydra-session-thread-retention@.service'
  _run_pass
  [ "$(grep -c '^OnFailure=hydra-unit-failed@%n\.service$' \
        "$AUX_SYSTEMD_UNIT_DIR/hydra-session-thread-retention@.service")" -eq 1 ]
}

@test "no .hydra-tmp files survive a successful pass" {
  _mk_unit hydra-weekly-cleanup.service
  _run_pass
  run bash -c "ls '$AUX_SYSTEMD_UNIT_DIR'/*.hydra-tmp 2>/dev/null | wc -l"
  [ "$output" -eq 0 ]
}

@test "every table entry is a .service, and the table has no duplicates" {
  # A .timer in here would be wired to a pager it can never trigger, and a
  # duplicate row would make the idempotency guarantee depend on ordering.
  run bash -c ". '$SNIPPET'; printf '%s\n' \"\${AUX_ONFAILURE_UNITS[@]}\""
  [ "$status" -eq 0 ]
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    [[ "$u" == *.service ]] || { echo "not a .service: $u" >&2; return 1; }
  done <<< "$output"
  local total uniq
  total="$(printf '%s\n' "$output" | grep -c .)"
  uniq="$(printf '%s\n' "$output" | sort -u | grep -c .)"
  [ "$total" -eq "$uniq" ]
}

@test "the REAL installer invokes wire_unit_failure_paging at top level" {
  # QA finding on this PR: every other test here extracts the function and calls
  # it, so they all stay green if a later edit drops the installer's own call
  # and deploys silently stop wiring OnFailure=. This asserts the call site
  # itself -- unindented, so a call left inside a dead `if false` block or an
  # unreachable function does not satisfy it.
  run grep -cE '^wire_unit_failure_paging$' "$INSTALLER"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "the invocation comes AFTER the function and the table are defined" {
  # Bash resolves a function at call time, so a call placed above the
  # definition would fail at runtime while still matching the grep above.
  local def tbl call
  def="$(grep -nE '^wire_unit_failure_paging\(\) \{' "$INSTALLER" | cut -d: -f1)"
  tbl="$(grep -nE '^AUX_ONFAILURE_UNITS=\(' "$INSTALLER" | cut -d: -f1)"
  call="$(grep -nE '^wire_unit_failure_paging$' "$INSTALLER" | cut -d: -f1)"
  [ -n "$def" ] && [ -n "$tbl" ] && [ -n "$call" ]
  [ "$call" -gt "$def" ]
  [ "$call" -gt "$tbl" ]
}

@test "the generated codex-keepalive cron line covers BOTH profiles" {
  # The other half of this PR, pinned here because it is the same installer and
  # the same class of silent regression: edge is the profile that cannot
  # self-refresh, so dropping it from the cron line leaves it unwatched with no
  # test failing.
  run grep -E '^\*/15 .* root .*codex-keepalive\.sh' "$INSTALLER"
  [ "$status" -eq 0 ]
  [[ "$output" == *'CODEX_KEEPALIVE_PROFILES="main edge"'* ]]
}

@test "a FAILING daemon-reload fails the function, it is not discarded" {
  # QA finding on this PR: daemon-reload is what makes the rewritten files live.
  # Swallowing its failure leaves OnFailure= on disk while systemd keeps the old
  # definitions -- every unit this change covers would carry a pager that does
  # not exist. This function is the installer's last command and the script has
  # no `set -e`, so a non-zero return becomes the installer's exit status, which
  # deploy.sh:3034 turns into `fail`.
  _mk_unit hydra-release-watch.service
  run bash -c "STUB_RELOAD_RC=1; export STUB_RELOAD_RC; . '$SNIPPET'; wire_unit_failure_paging"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FATAL"* ]]
  [[ "$output" == *"STILL RUNNING THE OLD DEFINITIONS"* ]]
  # the reload WAS attempted, and the files were already rewritten
  grep -q 'daemon-reload' "$RELOADS"
  [ "$(grep -c '^OnFailure=' "$AUX_SYSTEMD_UNIT_DIR/hydra-release-watch.service")" -eq 1 ]
}

@test "a failing daemon-reload is irrelevant when nothing needed wiring" {
  # No files changed means no reload is attempted, so a broken reload must not
  # manufacture a failure out of a no-op run.
  run bash -c "STUB_RELOAD_RC=1; export STUB_RELOAD_RC; . '$SNIPPET'; wire_unit_failure_paging"
  [ "$status" -eq 0 ]
  [ ! -s "$RELOADS" ]
}

@test "a retry after a FAILED reload still reloads (no silent-success latch)" {
  # The QA finding in full: first invocation rewrites the files and the reload
  # fails; the second finds every file already carrying OnFailure=, so a
  # wired-only gate would skip the reload and return success while systemd kept
  # the old definitions -- pagerless units, forever, confirmed healthy by every
  # later deploy.
  _mk_unit hydra-release-watch.service
  run bash -c "STUB_RELOAD_RC=1; export STUB_RELOAD_RC; . '$SNIPPET'; wire_unit_failure_paging"
  [ "$status" -ne 0 ]
  [ "$(grep -c '^OnFailure=' "$AUX_SYSTEMD_UNIT_DIR/hydra-release-watch.service")" -eq 1 ]

  # retry: nothing left to write, but the reload MUST be attempted again
  : > "$RELOADS"
  run bash -c "STUB_RELOAD_RC=1; export STUB_RELOAD_RC; . '$SNIPPET'; wire_unit_failure_paging"
  [ "$status" -ne 0 ]                        # still failing -> still non-zero
  grep -q 'daemon-reload' "$RELOADS"
  [[ "$output" == *"already carrying OnFailure paging"* ]]

  # and once the reload succeeds, the run is clean
  : > "$RELOADS"
  run bash -c ". '$SNIPPET'; wire_unit_failure_paging"
  [ "$status" -eq 0 ]
  grep -q 'daemon-reload' "$RELOADS"
}

@test "a foreign OnFailure does not make a unit count as pager-carrying" {
  # present_ours must match OUR directive specifically: a unit with someone
  # else's OnFailure is not evidence that systemd is holding our pager, and
  # counting it would force a reload on every run for unrelated reasons.
  _mk_unit codex-canonical-refresh.service 'OnFailure=something-else.service'
  _run_pass
  [ "$status" -eq 0 ]
  [ ! -s "$RELOADS" ]
}

@test "a FAILED per-unit rewrite fails the function, after the safe writes land" {
  # QA finding on this PR: logging WARN and returning 0 means one read-only path
  # or I/O error leaves that unit permanently pagerless while every later deploy
  # reports success — the silent-gap shape this change exists to remove,
  # reintroduced one level up.
  _mk_unit hydra-release-watch.service
  _mk_unit hydra-daily-audit.service
  # Fail the rename for ONE unit only, so the other must still be written and
  # reloaded before the function reports failure.
  run bash -c "STUB_MV_FAIL_FOR=hydra-release-watch.service; export STUB_MV_FAIL_FOR; . '$SNIPPET'; wire_unit_failure_paging"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FATAL"* ]]
  [[ "$output" == *"could not be given OnFailure paging"* ]]
  # the SAFE write landed and was reloaded despite the sibling failure
  [ "$(grep -c '^OnFailure=' "$AUX_SYSTEMD_UNIT_DIR/hydra-daily-audit.service")" -eq 1 ]
  [ "$(grep -c '^OnFailure=' "$AUX_SYSTEMD_UNIT_DIR/hydra-release-watch.service")" -eq 0 ]
  grep -q 'daemon-reload' "$RELOADS"
}

@test "a unit that is merely NOT INSTALLED does not fail the function" {
  # The discriminator: absent is legitimate (some units are runtime-gated), so
  # it must be counted separately from broken.
  _mk_unit hydra-daily-audit.service
  run bash -c ". '$SNIPPET'; wire_unit_failure_paging"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not installed"* ]]
  [[ "$output" != *"FATAL"* ]]
}
