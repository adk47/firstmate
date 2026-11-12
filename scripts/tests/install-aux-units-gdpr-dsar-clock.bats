#!/usr/bin/env bats
# The GDPR statutory clock unit (scripts/install-aux-units.sh, the
# `gdpr-dsar-clock.service` + `.timer` heredocs).
#
# WHY THIS FILE EXISTS. QA finding 1 on hydra#1908: the clock was documented,
# and nothing ran it. A statutory date that passes with no unit reading the
# clock is a missed deadline nobody was told about. This pins that the deploy
# installs a unit that reads it every hour, that the unit can start (the
# heredoc is unquoted, so it must render under `set -u` - the 2026-11-06 deploy
# break), and that its failure pages like every other aux unit.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"
NAME="gdpr-dsar-clock"

_render() {
  local dest="$1/" snippet="$TEST_TMPDIR/render.sh"
  awk -v dir="/etc/systemd/system/" -v name="$NAME." -v dest="$dest" '
    !on && index($0, "cat > " dir name) == 1 && $(NF-1) == "<<" {
      tag = $NF; on = 1
      print "cat > " dest substr($0, length("cat > " dir) + 1); next
    }
    on { print; if ($0 == tag) on = 0 }
  ' "$INSTALLER" > "$snippet"
  [ -s "$snippet" ]
  { echo 'set -euo pipefail'; cat "$snippet"; } > "$snippet.run"
  HYDRA_ROOT="$HYDRA_REPO" bash "$snippet.run"
}

_kv() {
  awk '/^\[[^]]+\]$/ { sec = substr($0, 2, length($0) - 2); next }
       /^[A-Za-z][A-Za-z0-9]*=/ { i = index($0, "="); print sec "." substr($0, 1, i - 1) "=" substr($0, i + 1) }' "$1"
}

_values() { _kv "$1" | awk -v k="$2=" 'index($0, k) == 1 { print substr($0, length(k) + 1) }'; }

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  UNITS="$TEST_TMPDIR/units"; mkdir -p "$UNITS"
  SVC="$UNITS/$NAME.service"; TMR="$UNITS/$NAME.timer"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

@test "the installer renders the clock service and its timer under set -u" {
  run _render "$UNITS"
  [ "$status" -eq 0 ]
  [ -s "$SVC" ]
  [ -s "$TMR" ]
}

@test "the service reads the clock with the deployed tree's own CLI, and nothing else" {
  _render "$UNITS"
  [ "$(_values "$SVC" Service.Type)" = "oneshot" ]
  [ "$(_values "$SVC" Service.ExecStart)" = "/usr/bin/python3 $HYDRA_REPO/scripts/gdpr-pipeline.py dsar clock --watch" ]
  # a literal $HYDRA_ROOT is not expanded by systemd: the unit would never start
  ! grep -q 'HYDRA_ROOT' "$SVC"
  # it must be able to reach Slack for the "nobody is reading the clock" page
  _values "$SVC" Service.EnvironmentFile | grep -qx -- '-/etc/openclaw/shared.env'
}

@test "the command the unit runs exists in the CLI" {
  run python3 "$HYDRA_REPO/scripts/gdpr-pipeline.py" dsar clock --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--watch"* ]]
  [[ "$output" == *"--read-by"* ]]
}

@test "the timer fires every hour, catches up after downtime, and starts this service" {
  _render "$UNITS"
  [ "$(_values "$TMR" Timer.OnCalendar)" = "*:07" ]
  [ "$(_values "$TMR" Timer.Persistent)" = "true" ]
  [ "$(_values "$TMR" Timer.Unit)" = "$NAME.service" ]
  [ "$(_values "$TMR" Install.WantedBy)" = "timers.target" ]
}

@test "the installer enables and starts the timer" {
  awk -v name="$NAME" 'index($0, "ct=" name ".timer") == 1 { on = 1 } on { print } on && /^log / { exit }' \
    "$INSTALLER" > "$TEST_TMPDIR/block"
  grep -q 'systemctl enable "\$ct"' "$TEST_TMPDIR/block"
  grep -q 'systemctl start "\$ct"' "$TEST_TMPDIR/block"
}

@test "a failing clock read pages: the service is in AUX_ONFAILURE_UNITS" {
  awk '/^AUX_ONFAILURE_UNITS=\(/ { on = 1; next } on && /^\)/ { exit } on { print }' "$INSTALLER" \
    | grep -qx "  $NAME.service"
}

@test "the firstmate check reads the same clock the unit does, and says which bytes are reading" {
  grep -q 'gdpr-pipeline.py dsar clock --line --read-by firstmate --reader-sha' \
    "$HYDRA_REPO/scripts/gdpr-dsar-clock-check.sh"
  run python3 "$HYDRA_REPO/scripts/gdpr-pipeline.py" dsar clock --help
  [[ "$output" == *"--reader-sha"* ]]
}

@test "the registration is a script in this repository, and it refuses to guess a firstmate home" {
  [ -x "$HYDRA_REPO/scripts/gdpr-dsar-clock-register.sh" ]
  run env -u FM_HOME bash "$HYDRA_REPO/scripts/gdpr-dsar-clock-register.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no firstmate home"* ]]
}

@test "the registration installs the check under the id that runs first and binds it to its bytes" {
  home="$BATS_TEST_TMPDIR/fm"
  mkdir -p "$home/bin" "$home/state"
  cat > "$home/bin/fm-check-register.sh" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'fm-custom-check-v1\n%s\n' "$(sha256sum "$FM_HOME/state/$1.check.sh" | cut -d' ' -f1)" \
  > "$FM_HOME/state/$1.check-trust"
SH
  printf '#!/usr/bin/env bash\nrm -f "$FM_HOME/state/$1.check.sh" "$FM_HOME/state/$1.check-trust"\n' \
    > "$home/bin/fm-check-unregister.sh"
  chmod +x "$home/bin/"*.sh
  run env FM_HOME="$home" bash "$HYDRA_REPO/scripts/gdpr-dsar-clock-register.sh"
  [ "$status" -eq 0 ]
  cmp "$home/state/a0-gdpr-dsar-clock.check.sh" "$HYDRA_REPO/scripts/gdpr-dsar-clock-check.sh"
  [ "$(stat -c %a "$home/state/a0-gdpr-dsar-clock.check.sh")" = 700 ]
  run env FM_HOME="$home" bash "$HYDRA_REPO/scripts/gdpr-dsar-clock-register.sh" --check
  [ "$status" -eq 0 ]
}
