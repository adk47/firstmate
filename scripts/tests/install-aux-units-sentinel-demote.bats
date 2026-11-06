#!/usr/bin/env bats
# scripts/install-aux-units.sh -> the sentinel-demote / sentinel-propose units.
#
# sentinel-demote-s6: automated demotion is the one thing in this repo that
# NARROWS a capability's rollout state without a human in the loop, so the
# schedule and the invocation are pinned here rather than left to review. These
# tests read the INSTALLER SOURCE (the real script writes to /etc/systemd/system
# and runs systemctl as root); they pin that the units are DECLARED correctly,
# never that they were applied on a host.
#
# The DANGEROUS mutation these catch: wiring the hourly unit to the nightly
# invocation (or vice versa). `--fast` is a SUBSET of the triggers by
# construction; a fast unit without it evaluates the slow counters 24x a day and
# can step a capability twice on one bad week.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"

# Prints the body of one unit heredoc, from its `cat >` line to its closing tag.
unit_body() {
  awk -v unit="$1" '
    index($0, "cat > /etc/systemd/system/" unit " << ") == 1 { tag = $NF; on = 1; next }
    $0 == tag { on = 0 }
    on
  ' "$INSTALLER"
}

@test "nightly demote timer fires at 02:30Z and runs the full join" {
  run unit_body sentinel-demote.timer
  [ "$status" -eq 0 ]
  [ "$(grep '^OnCalendar=' <<<"$output")" = "OnCalendar=*-*-* 02:30:00 UTC" ]
  [ "$(grep '^Unit=' <<<"$output")" = "Unit=sentinel-demote.service" ]
  run unit_body sentinel-demote.service
  grep -q '^ExecStart=.*demote.py run --nightly' <<<"$output"
  # 10 = "tripped and demoted", 2 = "registry has not landed yet", 3 = the global kill
  # switch is on. All three are normal outcomes; a crash is not, and must still fail
  # (and page through hydra-unit-failed@).
  [ "$(grep '^SuccessExitStatus=' <<<"$output")" = "SuccessExitStatus=10 2 3" ]
}

@test "every sentinel unit outlives systemd's 90s default start timeout" {
  # The nightly does a 7-day join, drops a kill file and opens a mirror PR, and a tick
  # that finds the lock held waits up to SENTINEL_LOCK_TIMEOUT (300s) before skipping.
  # DefaultTimeoutStartSec=90s would SIGTERM it mid-tick: survivable (atomic writes,
  # flock released on exit) but it abandons a demotion that already landed on the host.
  for unit in sentinel-demote.service sentinel-demote-fast.service sentinel-propose.service; do
    run unit_body "$unit"
    [ "$status" -eq 0 ]
    [ "$(grep '^TimeoutStartSec=' <<<"$output")" = "TimeoutStartSec=900" ] || {
      echo "$unit must set TimeoutStartSec=900 (got: $(grep -c '^TimeoutStartSec=' <<<"$output") lines)" >&2
      return 1
    }
  done
}

@test "the sentinel units are serialized by one host lock" {
  # Both timers save the WHOLE runtime document; two overlapping ticks lose one
  # demotion. The lock lives in the code, but the units must share one path, so pin that
  # no unit overrides SENTINEL_LOCK_FILE (a per-unit lock would serialize nothing).
  for unit in sentinel-demote.service sentinel-demote-fast.service sentinel-propose.service; do
    run unit_body "$unit"
    [ "$status" -eq 0 ]
    if grep -q 'SENTINEL_LOCK_FILE' <<<"$output"; then
      echo "$unit must not override SENTINEL_LOCK_FILE — one lock for every sentinel unit" >&2
      return 1
    fi
  done
}

@test "hourly demote timer is fast-mode only" {
  run unit_body sentinel-demote-fast.timer
  [ "$status" -eq 0 ]
  grep -q '^OnUnitActiveSec=60min' <<<"$output"
  [ "$(grep '^Unit=' <<<"$output")" = "Unit=sentinel-demote-fast.service" ]
  run unit_body sentinel-demote-fast.service
  grep -q '^ExecStart=.*demote.py run --fast' <<<"$output"
  # The fast unit must never carry --nightly: that would post the digest 24x/day.
  # NOTE: a bare `! grep -q ...` is NOT an assertion in bats — bash exempts `!`-prefixed
  # commands from errexit, so a failing negation is swallowed and the test's verdict is
  # decided by the next command. Proven with bats 1.14: `! grep -q foo <<<foo; true`
  # passes. Every negative check here is therefore an explicit early return.
  if grep -q -- '--nightly' <<<"$output"; then
    echo "sentinel-demote-fast must not run --nightly (that posts the digest hourly)" >&2
    return 1
  fi
  [ "$(grep '^SuccessExitStatus=' <<<"$output")" = "SuccessExitStatus=10 2 3" ]
}

@test "weekly proposal timer is Sunday 02:00Z and opens its PR" {
  run unit_body sentinel-propose.timer
  [ "$status" -eq 0 ]
  [ "$(grep '^OnCalendar=' <<<"$output")" = "OnCalendar=Sun *-*-* 02:00:00 UTC" ]
  run unit_body sentinel-propose.service
  grep -q '^ExecStart=.*demote.py propose --open-pr' <<<"$output"
}

@test "no sentinel unit fails for a registry that has not landed yet" {
  # dispatch finding (Fable r5): the units were enabled+started unconditionally while
  # policies/sentinel-capabilities.json (S0) does not exist yet, so demote.py exited 2
  # and two units sat permanently failed with ~1 page/day. 2 is in SuccessExitStatus, so
  # the pre-S0 run is a clean skip.
  #
  # QA r11: the units used to ALSO carry ConditionPathExists, which made a missing
  # registry a silent skip in every case — including a registry that had loaded once and
  # was then deleted or failed to deploy, which leaves automatic demotion blind with no
  # page and no failed unit. The condition is gone on purpose: demote.py distinguishes
  # "never landed" (2, clean) from "was here and is gone" (4, page + failed unit), and a
  # condition would stop the unit before it could tell anyone.
  for svc in sentinel-demote.service sentinel-demote-fast.service sentinel-propose.service; do
    run unit_body "$svc"
    if grep -q '^ConditionPathExists=' <<<"$output"; then
      echo "$svc must not gate on the registry: a vanished registry has to page" >&2
      return 1
    fi
    [ "$(grep '^SuccessExitStatus=' <<<"$output")" = "SuccessExitStatus=10 2 3" ]
    # 4 = the registry exists but is unusable, or it vanished after a good load. That must
    # stay a FAILURE so OnFailure pages.
    if grep -q '^SuccessExitStatus=.*4' <<<"$output"; then
      echo "$svc must not list 4 in SuccessExitStatus (a broken registry has to page)" >&2
      return 1
    fi
  done
}

@test "every normal sentinel exit code is accepted by the units" {
  # The units decide what counts as a failure, so a code the CLI treats as normal but
  # the unit rejects becomes an hourly page: the global kill switch (3) did exactly that.
  # Pinned against demote.py's own constants rather than a copied list.
  run python3 - "$HYDRA_REPO" <<'PYEOF'
import pathlib, re, sys
repo = pathlib.Path(sys.argv[1])
src = (repo / "scripts/sentinel/demote.py").read_text()
vals = {}
tuple_assign = re.search(r"^((?:EXIT_[A-Z_]+\s*,\s*)+EXIT_[A-Z_]+)\s*=\s*((?:\d+\s*,\s*)+\d+)$", src, re.M)
if tuple_assign:
    names = [n.strip() for n in tuple_assign.group(1).split(",")]
    vals.update(zip(names, [int(n) for n in tuple_assign.group(2).split(",")]))
for m in re.finditer(r"^(EXIT_[A-Z_]+)\s*=\s*(\d+)$", src, re.M):
    vals[m.group(1)] = int(m.group(2))
# 0 is systemd's DEFAULT success code, so a unit never has to list it and its absence from
# SuccessExitStatus means nothing. Assert that rather than assuming it, then check only the
# non-zero normal codes, which DO have to be listed or they page.
assert int(vals["EXIT_OK"]) == 0, "EXIT_OK is no longer 0; the default-success reasoning below is void"
normal = {int(vals["EXIT_NO_REGISTRY"]), int(vals["EXIT_KILLED"]), int(vals["EXIT_TRIPPED"])}
must_fail = {int(vals["EXIT_ERROR"]), int(vals["EXIT_BAD_STATE"])}

# ONLY the sentinel units. The installer writes ~40 units and each one's exit codes belong to
# its own program: clickup-drain-data-deletion legitimately whitelists 4 (its kill file is
# present), which is demote.py's EXIT_BAD_STATE. Unioning every SuccessExitStatus in the file
# made that unrelated collision read as "a sentinel defect goes silent" and failed this test on
# main from the moment #1704 landed. Scoping it to the units this file is about is the fix; the
# assertion itself is unchanged.
SENTINEL_UNITS = ("sentinel-demote.service", "sentinel-demote-fast.service", "sentinel-propose.service")
text = (repo / "scripts/install-aux-units.sh").read_text()
bodies, seen, lines, i = {}, {}, text.splitlines(), 0
while i < len(lines):
    m = re.match(r"^cat > /etc/systemd/system/(\S+) << (\S+)$", lines[i])
    if m and m.group(1) in SENTINEL_UNITS:
        unit, tag, start = m.group(1), m.group(2), i + 1
        seen.setdefault(unit, []).append(start)
        body, i = [], i + 1
        while i < len(lines) and lines[i] != tag:
            body.append(lines[i])
            i += 1
        # The LAST heredoc for a unit is the one that ends up on disk, so a test that unions
        # every definition can pass while the installed unit is wrong: a second declaration
        # omitting the kill-switch code 3 still inherits 3 from the first. Reject the duplicate
        # outright rather than silently picking a winner - writing the same unit twice is
        # itself a defect, and the author is the only one who can say which copy is real.
        bodies[unit] = body
    i += 1
dupes = {u: at for u, at in seen.items() if len(at) > 1}
if dupes:
    for unit, at in sorted(dupes.items()):
        print(f"{unit} is declared {len(at)} times in the installer (lines {', '.join(map(str, at))}); "
              f"only the last one is installed, so this test cannot say which exit codes are effective",
              file=sys.stderr)
    sys.exit(1)
# A renamed unit would otherwise make this test vacuous: it would find no SuccessExitStatus at
# all, and `missing` would then fail loudly - but say so directly rather than by accident.
absent = sorted(set(SENTINEL_UNITS) - set(seen))
if absent:
    print(f"sentinel unit(s) {absent} not found in the installer; this test cannot check them", file=sys.stderr)
    sys.exit(1)
# PER UNIT, not unioned. Unioning let one unit's SuccessExitStatus cover another's omission: with
# the union, dropping the kill-switch code 3 from sentinel-demote.service still passed because
# sentinel-demote-fast.service listed it. Each unit is its own pager, so each is checked alone.
bad = []
for unit in SENTINEL_UNITS:
    ok = set()
    for line in bodies[unit]:
        m = re.match(r"^SuccessExitStatus=(.+)$", line)
        if m:
            ok.update(int(tok) for tok in m.group(1).split())
    missing = sorted(normal - ok)
    if missing:
        bad.append(f"{unit}: normal exit code(s) {missing} are in no SuccessExitStatus -> a normal outcome pages")
    leaked = sorted(must_fail & ok)
    if leaked:
        bad.append(f"{unit}: failure exit code(s) {leaked} ARE whitelisted -> a real defect goes silent")
if bad:
    print("\n".join(bad), file=sys.stderr)
    sys.exit(1)
print("normal", sorted(normal), "accepted;", sorted(must_fail), "rejected; per unit:", ", ".join(SENTINEL_UNITS))
PYEOF
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

@test "the intentional stop (exit 3) does not page" {
  run unit_body sentinel-demote.service
  [ "$status" -eq 0 ]
  # 3 = kill switch on. A log-only stop must not mark the unit failed.
  grep -q '^SuccessExitStatus=.*\b3\b' <<<"$output"
}

@test "every sentinel unit carries the OnFailure pager" {
  for u in sentinel-demote.service sentinel-demote-fast.service sentinel-propose.service; do
    awk '/^AUX_ONFAILURE_UNITS=\(/,/^\)/' "$INSTALLER" | grep -qx "  $u" \
      || { echo "$u missing from AUX_ONFAILURE_UNITS"; false; }
  done
}

@test "an existing timer is never silently dropped from the installer by this section" {
  # The enable loop is a fixed list: adding a unit to disk without enabling it
  # leaves a timer that never fires (the failure mode this section exists for).
  for u in sentinel-demote.timer sentinel-demote-fast.timer sentinel-propose.timer; do
    grep -q "for _sd in .*$u" "$INSTALLER" || { echo "$u is never enabled"; false; }
  done
}

@test "the mirror checkout lives in /var/lib, never in the deploy-rsynced /opt/hydra" {
  run bash -c "grep -n 'mirror-repo' '$INSTALLER'"
  grep -q '/var/lib/hydra/sentinel/mirror-repo' <<<"$output"
  if grep -q '/opt/hydra/sentinel/mirror-repo' <<<"$output"; then
    echo "the mirror checkout must never live under /opt/hydra (the deploy rsyncs over it)" >&2
    return 1
  fi
}

@test "a dry run against the fixture registry writes nothing and exits 0" {
  TMP="$(mktemp -d)"
  SENTINEL_KILL_ROOT="$TMP/etc-hydra" run python3 "$HYDRA_REPO/scripts/sentinel/demote.py" run \
    --dry-run --no-page --no-pr \
    --registry "$HYDRA_REPO/tests/fixtures/sentinel/registry.json" \
    --runtime-state "$TMP/rt.json" \
    --paths-json '{"action_ledger_db":"/nonexistent/a.sqlite","evaluations_db":"/nonexistent/e.sqlite"}'
  [ ! -e "$TMP/rt.json" ]
  [ -z "$(ls -A "$TMP/etc-hydra" 2>/dev/null)" ]
  rm -rf "$TMP"
}

@test "no registry means exit 2, never a silent success" {
  TMP="$(mktemp -d)"
  SENTINEL_KILL_ROOT="$TMP/etc-hydra" SENTINEL_LOCK_FILE="$TMP/run.lock" \
    run python3 "$HYDRA_REPO/scripts/sentinel/demote.py" run \
    --no-page --no-pr --registry "$TMP/absent.json" --runtime-state "$TMP/rt.json"
  [ "$status" -eq 2 ]
  [ ! -e "$TMP/rt.json" ]
  rm -rf "$TMP"
}
