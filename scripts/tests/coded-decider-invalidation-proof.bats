#!/usr/bin/env bats
# The coded-decider invalidation PROOF and the print-only kill-lift PLANNER, pinned.
#
# /etc/hydra/credit-trust-score-approve.disabled names its own resume condition: "both switches come off together, in
# one recorded step, only after the coded-decider invalidation path is proved (run twice, second invalidates first, no
# Errno 13)". scripts/prove-coded-decider-invalidation.py is that proof and scripts/credit-approve-hold-lift.sh is the
# recorded step's planner. These tests pin the properties that make either worth trusting:
#   * the proof FAILS (non-zero, naming what it saw) on a tree where the second run does NOT invalidate the first, and
#     refuses on a tree that lacks the mechanism - a proof that cannot fail proves nothing;
#   * the planner runs the proof ITSELF (a handed-in transcript is refused), plans only when BOTH switches are present,
#     never removes a switch, and the step it prints records before it removes and rolls both back on failure.
bats_require_minimum_version 1.5.0
HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
PROVE="$HYDRA_REPO/scripts/prove-coded-decider-invalidation.py"
LIFT="$HYDRA_REPO/scripts/credit-approve-hold-lift.sh"
FIXTURE="$HYDRA_REPO/scripts/credit_review/fixtures/coded-decider-invalidation.json"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# A disposable copy of the tree under proof: scripts/credit_review + scripts/credit_trust + policies.
copy_tree() {
  local dst="$1"
  mkdir -p "$dst/scripts"
  cp -r "$HYDRA_REPO/scripts/credit_review" "$HYDRA_REPO/scripts/credit_trust" "$dst/scripts/"
  cp -r "$HYDRA_REPO/policies" "$dst/"
}

# A tree whose consumer stops checking the recorded bytes (existence read as currency): the proof FAILS on it.
mutated_tree() {
  copy_tree "$1"
  python3 - "$1/scripts/credit_review/decide.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
before = s
s = s.replace('    if actual != row.get("sha256"):\n        return False, "the bytes on disk are not the bytes the run recorded (stale artifact)"\n', '')
s = s.replace('    if doc.get("run_id") != row.get("run_id"):\n        return False, f"the document is run {doc.get(\'run_id\')}, the record is run {row.get(\'run_id\')}"\n', '')
assert s != before, "mutation did not apply; the negative leg would be untested"
open(p, "w").write(s)
PY
}

@test "proof: PASSES on this tree, twice-run, second invalidates first, no Errno 13, host switches untouched" {
  run env TMPDIR="$TEST_TMPDIR" python3 "$PROVE" --tree "$HYDRA_REPO" --fixture "$FIXTURE" \
    --record "$TEST_TMPDIR/proof.txt" --with-failed-refresh
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PROOF: PASS"* ]]
  [[ "$output" != *"[FAIL]"* ]]
  [[ "$output" == *"put back on disk, is REFUSED as NOT CURRENT"* ]]
  [[ "$output" == *"no ('Errno 13', 'Permission denied') in"* ]]
  # the transcript is recorded for a human, and the verdict is its last line
  [ -s "$TEST_TMPDIR/proof.txt" ]
  [[ "$(grep -E '^PROOF: ' "$TEST_TMPDIR/proof.txt" | tail -n 1)" == "PROOF: PASS"* ]]
  # the sandbox was removed: nothing of this run's is left in the TMPDIR it was given
  [ -z "$(ls -d "$TEST_TMPDIR"/coded-invalidation-proof-* 2>/dev/null)" ]
  # without --host-probe the verdict says so, in words a planner can refuse on
  [[ "$output" == *"; host probe NOT run."* ]]
}

@test "proof: the host probe performs the writer's ladder on probe-named files in the live dir and leaves nothing" {
  mkdir -p "$TEST_TMPDIR/live"
  printf '{"run_id":"live","executable":false}\n' > "$TEST_TMPDIR/live/fable-decider.coded-input.json"
  local before; before="$(sha256sum "$TEST_TMPDIR/live/fable-decider.coded-input.json")"
  run env TMPDIR="$TEST_TMPDIR" python3 "$PROVE" --tree "$HYDRA_REPO" --fixture "$FIXTURE" \
    --host-probe "$TEST_TMPDIR/live" --service-user "$(id -un)"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"HOST PROBE: the writer's ladder as uid $(id -u) on probe-named files in $TEST_TMPDIR/live"* ]]
  [[ "$output" == *"[OK  ] host probe: create by tmp + atomic replace"* ]]
  [[ "$output" == *"[OK  ] host probe: refresh by tmp + atomic replace over the existing file"* ]]
  [[ "$output" == *"[OK  ] host probe: invalidate with the tree's own _invalidate_coded_output"* ]]
  [[ "$output" == *"[OK  ] host probe: unlink the probe (rung 3)"* ]]
  [[ "$output" == *"[OK  ] this user may write THROUGH the live document"* ]]
  [[ "$output" == *"[OK  ] no probe file left in the live directory"* ]]
  [[ "$(grep -E '^PROOF: ' <<<"$output" | tail -n 1)" == *"; host probe in $TEST_TMPDIR/live as uid $(id -u): PASS."* ]]
  # the live document was read, never written; nothing else is left beside it
  [ "$(sha256sum "$TEST_TMPDIR/live/fable-decider.coded-input.json")" = "$before" ]
  [ "$(ls -A "$TEST_TMPDIR/live")" = "fable-decider.coded-input.json" ]
  # the live document absent is fine (first run creates it) - creation is what gets probed
  rm "$TEST_TMPDIR/live/fable-decider.coded-input.json"
  run env TMPDIR="$TEST_TMPDIR" python3 "$PROVE" --tree "$HYDRA_REPO" --fixture "$FIXTURE" \
    --host-probe "$TEST_TMPDIR/live" --service-user "$(id -un)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"live document $TEST_TMPDIR/live/fable-decider.coded-input.json: absent"* ]]
}

@test "proof: the host probe FAILS the proof on the wrong user, a missing live dir, or a directory this user cannot write" {
  # wrong service user: measuring somebody else's permissions is refused, not reported as PASS
  mkdir -p "$TEST_TMPDIR/live"
  run env TMPDIR="$TEST_TMPDIR" python3 "$PROVE" --tree "$HYDRA_REPO" --fixture "$FIXTURE" \
    --host-probe "$TEST_TMPDIR/live" --service-user nobody-else
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] host probe runs as the decider's service user (nobody-else)"* ]]
  [[ "$output" == *"PROOF: FAIL"* ]]
  # missing live dir
  run env TMPDIR="$TEST_TMPDIR" python3 "$PROVE" --tree "$HYDRA_REPO" --fixture "$FIXTURE" \
    --host-probe "$TEST_TMPDIR/no-such-live" --service-user "$(id -un)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] the live output directory exists"* ]]
  # a directory the user cannot write: the exact 2026-11-05 shape. root ignores mode bits, so the Errno 13 is
  # injected UID-independently on os.replace; a non-root run additionally exercises the real one below.
  run env TMPDIR="$TEST_TMPDIR" python3 -c '
import os, sys, runpy
prove, tree, fixture, live, user = sys.argv[1:6]
sys.argv = [prove, "--tree", tree, "--fixture", fixture, "--host-probe", live, "--service-user", user]
def denied(src, dst, *a, **kw):
    raise PermissionError(13, "Permission denied", str(dst))
os.replace = denied
runpy.run_path(prove, run_name="__main__")
' "$PROVE" "$HYDRA_REPO" "$FIXTURE" "$TEST_TMPDIR/live" "$(id -un)"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] host probe: create by tmp + atomic replace (rung 1, first write)"* ]]
  [[ "$output" == *"PermissionError: [Errno 13] Permission denied"* ]]
  [[ "$output" == *"PROOF: FAIL"* ]]
  [[ "$output" == *"NO switch may be removed on this evidence."* ]]
  if [ "$(id -u)" -ne 0 ]; then
    chmod 555 "$TEST_TMPDIR/live"
    run env TMPDIR="$TEST_TMPDIR" python3 "$PROVE" --tree "$HYDRA_REPO" --fixture "$FIXTURE" \
      --host-probe "$TEST_TMPDIR/live" --service-user "$(id -un)"
    chmod 755 "$TEST_TMPDIR/live"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"[FAIL] this user may create, replace and unlink entries in the live directory"* ]]
    [[ "$output" == *"[Errno 13] Permission denied"* ]]
  fi
}

@test "proof: the default fixture is a deployed path (scripts/credit_review/fixtures), not scripts/tests" {
  # scripts/deploy.sh rsyncs with --exclude='tests/', so a fixture under scripts/tests would not reach /opt/hydra and the
  # planner could not witness the proof on node-8
  [ -f "$FIXTURE" ]
  run env TMPDIR="$TEST_TMPDIR" python3 "$PROVE" --tree "$HYDRA_REPO"
  [ "$status" -eq 0 ]
}

@test "proof: FAILS non-zero, naming the observation, on a tree where the consumer stops checking the recorded bytes" {
  mutated_tree "$TEST_TMPDIR/mut"
  run python3 "$PROVE" --tree "$TEST_TMPDIR/mut" --fixture "$FIXTURE"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PROOF: FAIL"* ]]
  [[ "$output" == *"[FAIL] run 1's document, put back on disk, is REFUSED as NOT CURRENT"* ]]
  [[ "$output" == *"NO switch may be removed on this evidence."* ]]
}

@test "proof: refuses (exit 2) on a tree that does not carry the mechanism" {
  copy_tree "$TEST_TMPDIR/old"
  sed -i 's/^def decide_coded_current(/def decide_coded_current_gone(/' "$TEST_TMPDIR/old/scripts/credit_review/decide.py"
  run python3 "$PROVE" --tree "$TEST_TMPDIR/old" --fixture "$FIXTURE"
  echo "$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"does not carry \`def decide_coded_current(\`"* ]]
}

@test "proof: refuses (exit 2) rather than touch a host path, when a sandboxed path leaks outside the sandbox" {
  copy_tree "$TEST_TMPDIR/leak"
  # a tree whose decide.py hard-codes the host kill switch instead of reading the environment
  sed -i 's|^KILL_SWITCH = Path(os.environ.get("CREDIT_TRUST_DECIDE_KILL_SWITCH", "/etc/hydra/credit-trust-decide.disabled"))|KILL_SWITCH = Path("/etc/hydra/credit-trust-decide.disabled")|' \
    "$TEST_TMPDIR/leak/scripts/credit_review/decide.py"
  run python3 "$PROVE" --tree "$TEST_TMPDIR/leak" --fixture "$FIXTURE"
  echo "$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"OUTSIDE THE SANDBOX"* ]]
  [[ "$output" == *"refusing to run: ['KILL_SWITCH'] would touch the host"* ]]
}

lift_fixture() {
  mkdir -p "$TEST_TMPDIR/etc" "$TEST_TMPDIR/state" "$TEST_TMPDIR/live"
  printf 'firstmate 2026-11-06T08:2xZ: re-armed deliberately ... (run twice, second invalidates first, no Errno 13)\n' \
    > "$TEST_TMPDIR/etc/credit-trust-score-approve.disabled"
  printf 'never-lower refusal 2026-11-05T02:55:43Z: ... [Errno 13] Permission denied ...\n' \
    > "$TEST_TMPDIR/etc/credit-trust-decide.disabled"
}

switches_still_present() {
  [ -f "$TEST_TMPDIR/etc/credit-trust-score-approve.disabled" ]
  [ -f "$TEST_TMPDIR/etc/credit-trust-decide.disabled" ]
}

# the planner against a tree (default: this repo); it runs the proof itself, about 2 s
lift() {
  local tree="$HYDRA_REPO"
  if [[ "${1:-}" == "--tree" ]]; then tree="$2"; shift 2; fi
  run env TMPDIR="$TEST_TMPDIR" "$LIFT" --tree "$tree" --fixture "$FIXTURE" \
    --etc-dir "$TEST_TMPDIR/etc" --state-dir "$TEST_TMPDIR/state" \
    --live-dir "$TEST_TMPDIR/live" --service-user "$(id -un)" "$@"
}

@test "lift planner: a handed-in transcript is refused, and a proof that FAILS yields no plan" {
  lift_fixture
  printf 'PROOF: PASS - run twice (R1=a, R2=b); the second invalidates the first; no Errno 13.\n' > "$TEST_TMPDIR/pass.txt"
  run "$LIFT" --etc-dir "$TEST_TMPDIR/etc" --state-dir "$TEST_TMPDIR/state" --proof "$TEST_TMPDIR/pass.txt"
  echo "$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--proof is gone"* ]]
  switches_still_present
  [ -z "$(ls "$TEST_TMPDIR/state" 2>/dev/null)" ]
  # the proof is RUN by the planner: on a tree where it fails there is no plan, whatever files lie around
  mutated_tree "$TEST_TMPDIR/mut"
  lift --tree "$TEST_TMPDIR/mut"
  echo "$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"REFUSED: the coded-decider invalidation proof did not pass (exit 1)"* ]]
  [[ "$output" == *"verdict line: PROOF: FAIL"* ]]
  [[ "$output" == *"- run 1's document, put back on disk, is REFUSED as NOT CURRENT against run 2's record (invalidated) -- observed: rc=0"* ]]
  [[ "$output" == *"NO switch may be removed on this evidence."* ]]
  switches_still_present
  # the failed transcript is kept for a human, with the full observation; no backup, no evidence entry
  local proof
  proof="$(ls "$TEST_TMPDIR"/state/coded-invalidation-proof-*.txt)"
  grep -q "\[FAIL\] run 1's document, put back on disk, is REFUSED as NOT CURRENT" "$proof"
  [ ! -d "$TEST_TMPDIR/state/kill-lift-backups" ]
  [ -z "$(ls "$TEST_TMPDIR"/state/kill-lift-*.evidence 2>/dev/null)" ]
  # the HOST leg is part of the proof the planner runs: a live directory the service user cannot use is no plan,
  # however green the sandbox runs were (the hold was armed by exactly that permission failure)
  rm -f "$TEST_TMPDIR"/state/coded-invalidation-proof-*.txt
  run env TMPDIR="$TEST_TMPDIR" "$LIFT" --tree "$HYDRA_REPO" --fixture "$FIXTURE" \
    --etc-dir "$TEST_TMPDIR/etc" --state-dir "$TEST_TMPDIR/state" --live-dir "$TEST_TMPDIR/no-such-live" \
    --service-user "$(id -un)"
  echo "$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"proof: running python3 "*"--host-probe $TEST_TMPDIR/no-such-live"* ]]
  [[ "$output" == *"REFUSED: the coded-decider invalidation proof did not pass (exit 1)"* ]]
  [[ "$output" == *"[FAIL] the live output directory exists"* ]]
  switches_still_present
  [ ! -d "$TEST_TMPDIR/state/kill-lift-backups" ]
  [ -z "$(ls "$TEST_TMPDIR"/state/kill-lift-*.evidence 2>/dev/null)" ]
  # and a planner must never take the proof's word without the host leg: a transcript whose verdict lacks it is refused
  # (exercised through a python3 shim that strips --host-probe from the proof's argv)
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/python3" <<SH
#!/usr/bin/env bash
args=(); skip=0
for a in "\$@"; do
  if [ "\$skip" = 1 ]; then skip=0; continue; fi
  case "\$a" in --host-probe) skip=1; continue ;; esac
  args+=("\$a")
done
exec "$(command -v python3)" "\${args[@]}"
SH
  chmod +x "$TEST_TMPDIR/bin/python3"
  run env PATH="$TEST_TMPDIR/bin:$PATH" TMPDIR="$TEST_TMPDIR" "$LIFT" --tree "$HYDRA_REPO" --fixture "$FIXTURE" \
    --etc-dir "$TEST_TMPDIR/etc" --state-dir "$TEST_TMPDIR/state" --live-dir "$TEST_TMPDIR/live" \
    --service-user "$(id -un)"
  echo "$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"REFUSED: the proof passed in the sandbox but its verdict line does not carry the host probe"* ]]
  rm -f "$TEST_TMPDIR/bin/python3"
  switches_still_present
  [ ! -d "$TEST_TMPDIR/state/kill-lift-backups" ]
}

@test "lift planner: on a passing proof it backs up, records, prints the diff and the one step - and removes NOTHING" {
  lift_fixture
  lift --by tester
  echo "$output"
  [ "$status" -eq 0 ]
  switches_still_present
  [[ "$output" == *"PRINT-ONLY: this run removes nothing"* ]]
  [[ "$output" == *"verdict: PROOF: PASS"* ]]
  [[ "$output" == *"STOPPED before the step: nothing was removed"* ]]
  [[ "$output" == *"-firstmate 2026-11-06T08:2xZ: re-armed deliberately"* ]]
  [[ "$output" == *"-never-lower refusal 2026-11-05T02:55:43Z"* ]]
  # the step is ONE generated, sha-pinned script beside the evidence: records BEFORE it touches anything, takes each
  # switch aside by rename, verifies the TAKEN bytes against the planned sha256, records `lifted`, rolls back otherwise
  local ss h1 h2
  ss="$(ls "$TEST_TMPDIR"/state/kill-lift-*.lift-step.sh)"
  [[ "$output" == *"the ONE step"*"bash '$ss'"* ]]
  [[ "$output" == *"script sha256 $(sha256sum "$ss" | awk '{print $1}')"* ]]
  h1="$(sha256sum "$TEST_TMPDIR/etc/credit-trust-score-approve.disabled" | awk '{print $1}')"
  h2="$(sha256sum "$TEST_TMPDIR/etc/credit-trust-decide.disabled" | awk '{print $1}')"
  grep -qF "S1='$TEST_TMPDIR/etc/credit-trust-score-approve.disabled'; H1='$h1'" "$ss"
  grep -qF "S2='$TEST_TMPDIR/etc/credit-trust-decide.disabled'; H2='$h2'" "$ss"
  grep -q '^rec lifting ' "$ss"
  grep -q '^if take "\$S1" "\$Q1" "\$H1" && take "\$S2" "\$Q2" "\$H2"; then' "$ss"
  grep -q 'RESTORE FAILED' "$ss"
  grep -q 'rec "ROLLED BACK"' "$ss"
  [ ! -x "$ss" ] || [ "$(stat -c '%a' "$ss")" = 700 ]
  # the transcript the planner itself recorded, its sha in the evidence, backups byte-identical
  local proof b ev
  proof="$(ls "$TEST_TMPDIR"/state/coded-invalidation-proof-*.txt)"
  [[ "$(grep -E '^PROOF: ' "$proof" | tail -n 1)" == "PROOF: PASS"* ]]
  b="$(ls -d "$TEST_TMPDIR"/state/kill-lift-backups/*)"
  cmp "$b/credit-trust-score-approve.disabled" "$TEST_TMPDIR/etc/credit-trust-score-approve.disabled"
  cmp "$b/credit-trust-decide.disabled" "$TEST_TMPDIR/etc/credit-trust-decide.disabled"
  ev="$(ls "$TEST_TMPDIR"/state/kill-lift-*.evidence)"
  grep -q "status: PLANNED, NOT EXECUTED" "$ev"
  grep -q "| firstmate 2026-11-06T08:2xZ: re-armed deliberately" "$ev"
  grep -q "| never-lower refusal 2026-11-05T02:55:43Z" "$ev"
  grep -q "sha256=$(sha256sum "$proof" | awk '{print $1}')" "$ev"
  grep -q "proof: run by this planner" "$ev"
  # the pause file is not one of the two switches the resume condition names, so it is never in the step
  run ! grep -q "score-approve.paused" "$ev"
}

@test "lift planner: the printed step is all-or-nothing - records first, takes then verifies, restores on any failure" {
  lift_fixture
  lift --by tester
  [ "$status" -eq 0 ]
  local ev step s1 s2 b
  ev="$(ls "$TEST_TMPDIR"/state/kill-lift-*.evidence)"
  step="$(grep -A1 '^the one step (verbatim' "$ev" | tail -n 1 | sed 's/^  //')"
  [[ "$step" == bash\ \'*.lift-step.sh\' ]]
  s1="$TEST_TMPDIR/etc/credit-trust-score-approve.disabled"; s2="$TEST_TMPDIR/etc/credit-trust-decide.disabled"
  b="$(ls -d "$TEST_TMPDIR"/state/kill-lift-backups/*)"
  # A write failure that does not depend on the runner's UID (root ignores chmod): the evidence path becomes a
  # symlink into a directory that does not exist, so an append fails with ENOENT for anyone.
  local gone="$TEST_TMPDIR/no-such-dir/evidence"
  # 1. a step that cannot even record `lifting` takes nothing
  mv "$ev" "$ev.real"; ln -s "$gone" "$ev"
  run bash -c "$step"
  echo "$output"
  [ "$status" -ne 0 ]
  switches_still_present
  rm "$ev"; mv "$ev.real" "$ev"
  run ! grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z lifting \[key=kill-lift-' "$ev"
  # 2. the first take succeeds, the second fails: the first comes back, ROLLED BACK is recorded, no `lifted`
  mkdir -p "$TEST_TMPDIR/bin"
  printf '#!/bin/sh\ncase "$3" in *credit-trust-decide.disabled) echo "mv: simulated failure" >&2; exit 1 ;; esac\nexec /bin/mv "$@"\n' \
    > "$TEST_TMPDIR/bin/mv"
  chmod +x "$TEST_TMPDIR/bin/mv"
  run env PATH="$TEST_TMPDIR/bin:$PATH" bash -c "$step"
  echo "$output"
  [ "$status" -eq 1 ]
  switches_still_present
  cmp "$s1" "$b/credit-trust-score-approve.disabled"
  [ -z "$(ls "$TEST_TMPDIR"/etc/*.lifting-* 2>/dev/null)" ]
  grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z lifting \[key=kill-lift-' "$ev"
  grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z ROLLED BACK \[key=kill-lift-.*could not take' "$ev"
  run ! grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z lifted \[key=kill-lift-' "$ev"
  # 3. both takes succeed but the `lifted` record cannot be written (the evidence file goes away between the take
  #    and the record): both switches come back, exit 1 - a lift nobody can read back is not a completed step
  printf '#!/bin/sh\n/bin/mv "$@" || exit $?\ncase "$4" in *credit-trust-decide.disabled.lifting-*) /bin/mv "%s" "%s.real" && ln -s "%s" "%s" ;; esac\n' \
    "$ev" "$ev" "$gone" "$ev" > "$TEST_TMPDIR/bin/mv"
  run env PATH="$TEST_TMPDIR/bin:$PATH" bash -c "$step"
  echo "$output"
  [ "$status" -eq 1 ]
  switches_still_present
  cmp "$s1" "$b/credit-trust-score-approve.disabled"
  cmp "$s2" "$b/credit-trust-decide.disabled"
  rm "$ev"; mv "$ev.real" "$ev"
  run ! grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z lifted \[key=kill-lift-' "$ev"
  # 4. a writer RE-ARMS a switch during the step (right after it was taken): the new file is not the proven switch,
  #    it is never removed, the taken one is not restored over it, and the outcome is ROLLED BACK with that fact
  printf '#!/bin/sh\n/bin/mv "$@" || exit $?\ncase "$4" in *credit-trust-decide.disabled.lifting-*) printf "never-lower refusal: re-armed DURING the step\\n" > "%s" ;; esac\n' \
    "$s2" > "$TEST_TMPDIR/bin/mv"
  run env PATH="$TEST_TMPDIR/bin:$PATH" bash -c "$step"
  echo "$output"
  [ "$status" -eq 1 ]
  switches_still_present
  cmp "$s1" "$b/credit-trust-score-approve.disabled"
  grep -q 're-armed DURING the step' "$s2"
  [ -z "$(ls "$TEST_TMPDIR"/etc/*.lifting-* 2>/dev/null)" ]
  grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z ROLLED BACK \[key=kill-lift-.*re-armed meanwhile, left as found' "$ev"
  run ! grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z lifted \[key=kill-lift-' "$ev"
  cp -p "$b/credit-trust-decide.disabled" "$s2"
  # 5. with nothing in the way the step removes both and records `lifted` - in this sandbox only
  rm "$TEST_TMPDIR/bin/mv"
  run bash -c "$step"
  echo "$output"
  [ "$status" -eq 0 ]
  [ ! -e "$s1" ]
  [ ! -e "$s2" ]
  [ -z "$(ls "$TEST_TMPDIR"/etc/*.lifting-* 2>/dev/null)" ]
  grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z lifted \[key=kill-lift-' "$ev"
  # `lifted` is the LAST record line a completed step writes - the guard reads completion off that fact
  [[ "$(grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z [A-Za-z ]+ \[key=kill-lift-' "$ev" | tail -n 1)" == *" lifted [key=kill-lift-"* ]]
}

@test "lift planner: a failed restore is recorded as RESTORE FAILED, never as a completed rollback" {
  lift_fixture
  lift --by tester
  [ "$status" -eq 0 ]
  local ev step b
  ev="$(ls "$TEST_TMPDIR"/state/kill-lift-*.evidence)"
  step="$(grep -A1 '^the one step (verbatim' "$ev" | tail -n 1 | sed 's/^  //')"
  b="$(ls -d "$TEST_TMPDIR"/state/kill-lift-backups/*)"
  rm -rf "$b"
  mkdir -p "$TEST_TMPDIR/bin"
  # the second take fails, and so does the put-back of the first (its aside copy cannot be renamed back)
  printf '#!/bin/sh\ncase "$3" in *credit-trust-decide.disabled|*.lifting-*) echo "mv: simulated failure" >&2; exit 1 ;; esac\nexec /bin/mv "$@"\n' \
    > "$TEST_TMPDIR/bin/mv"
  chmod +x "$TEST_TMPDIR/bin/mv"
  run env PATH="$TEST_TMPDIR/bin:$PATH" bash -c "$step"
  echo "$output"
  [ "$status" -eq 1 ]
  [ ! -e "$TEST_TMPDIR/etc/credit-trust-score-approve.disabled" ]
  [ -e "$TEST_TMPDIR/etc/credit-trust-decide.disabled" ]
  grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z ROLLED BACK \[key=kill-lift-.*RESTORE FAILED for '"$TEST_TMPDIR"'/etc/credit-trust-score-approve.disabled' "$ev"
  run ! grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z ROLLED BACK \[key=kill-lift-.*every taken switch restored' "$ev"
}

@test "lift planner: one switch present is a refusal, not a half-lift" {
  lift_fixture
  rm "$TEST_TMPDIR/etc/credit-trust-decide.disabled"
  lift
  echo "$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"REFUSED: the resume condition says BOTH switches come off together, and only one is present"* ]]
  [[ "$output" == *"ABSENT  $TEST_TMPDIR/etc/credit-trust-decide.disabled"* ]]
  [[ "$output" != *"proof: running"* ]]
  [ -f "$TEST_TMPDIR/etc/credit-trust-score-approve.disabled" ]
  [ -z "$(ls "$TEST_TMPDIR/state" 2>/dev/null)" ]
}

@test "lift planner: the pause file is reported as out of scope and never removed" {
  lift_fixture
  printf '2026-11-06T00:00:00Z paused for a test\n' > "$TEST_TMPDIR/state/score-approve.paused"
  lift
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OUT OF SCOPE (reported, never removed by this step): $TEST_TMPDIR/state/score-approve.paused"* ]]
  [[ "$output" == *"score-approve --resume"* ]]
  [[ "$output" != *"rm -f -- '$TEST_TMPDIR/state/score-approve.paused'"* ]]
  [ -f "$TEST_TMPDIR/state/score-approve.paused" ]
  switches_still_present
  local ev
  ev="$(ls "$TEST_TMPDIR"/state/kill-lift-*.evidence)"
  grep -q "OUT OF SCOPE (not removed by this step): $TEST_TMPDIR/state/score-approve.paused" "$ev"
  run ! grep -q "rm -f -- '$TEST_TMPDIR/state/score-approve.paused'" "$ev"
}

@test "lift planner: a second plan in the same minute refuses instead of truncating the first evidence entry" {
  lift_fixture
  # a fixed clock, so both plans land in the same minute whatever the wall clock does
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/date" <<'SH'
#!/bin/sh
case "$*" in
  *%Y%m%dT%H%M%SZ*) echo 20261106T214300Z ;;
  *%m%d-%H%M*) echo 1106-2143 ;;
  *) echo 2026-11-06T21:43:00Z ;;
  esac
SH
  chmod +x "$TEST_TMPDIR/bin/date"
  run env PATH="$TEST_TMPDIR/bin:$PATH" TMPDIR="$TEST_TMPDIR" "$LIFT" --tree "$HYDRA_REPO" --fixture "$FIXTURE" \
    --etc-dir "$TEST_TMPDIR/etc" --state-dir "$TEST_TMPDIR/state" --live-dir "$TEST_TMPDIR/live" --service-user "$(id -un)" --by tester
  echo "$output"
  [ "$status" -eq 0 ]
  local ev="$TEST_TMPDIR/state/kill-lift-1106-2143.evidence"
  [ -f "$ev" ]
  printf 'lifted [key=kill-lift-1106-2143] by tester\n' >> "$ev"
  run env PATH="$TEST_TMPDIR/bin:$PATH" TMPDIR="$TEST_TMPDIR" "$LIFT" --tree "$HYDRA_REPO" --fixture "$FIXTURE" \
    --etc-dir "$TEST_TMPDIR/etc" --state-dir "$TEST_TMPDIR/state" --live-dir "$TEST_TMPDIR/live" --service-user "$(id -un)" --by tester
  echo "$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"already exists"* ]]
  grep -q "lifted \[key=kill-lift-1106-2143\] by tester" "$ev"
  switches_still_present
}

@test "lift planner: simultaneous plans cannot truncate the durable evidence" {
  lift_fixture
  # a fixed clock, so both planners target the same evidence key whatever the wall clock does
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/date" <<'SH'
#!/bin/sh
case "$*" in
  *%Y%m%dT%H%M%SZ*) echo 20261106T214300Z ;;
  *%m%d-%H%M*) echo 1106-2143 ;;
  *) echo 2026-11-06T21:43:00Z ;;
esac
SH
  chmod +x "$TEST_TMPDIR/bin/date"
  local r1=0 r2=0
  env PATH="$TEST_TMPDIR/bin:$PATH" TMPDIR="$TEST_TMPDIR" "$LIFT" --tree "$HYDRA_REPO" --fixture "$FIXTURE" \
    --etc-dir "$TEST_TMPDIR/etc" --state-dir "$TEST_TMPDIR/state" --live-dir "$TEST_TMPDIR/live" --service-user "$(id -un)" --by tester > "$TEST_TMPDIR/a.out" 2>&1 &
  local p1=$!
  env PATH="$TEST_TMPDIR/bin:$PATH" TMPDIR="$TEST_TMPDIR" "$LIFT" --tree "$HYDRA_REPO" --fixture "$FIXTURE" \
    --etc-dir "$TEST_TMPDIR/etc" --state-dir "$TEST_TMPDIR/state" --live-dir "$TEST_TMPDIR/live" --service-user "$(id -un)" --by tester > "$TEST_TMPDIR/b.out" 2>&1 &
  local p2=$!
  set +e
  wait "$p1"; r1=$?
  wait "$p2"; r2=$?
  set -e
  echo "planner 1 rc=$r1"; cat "$TEST_TMPDIR/a.out"
  echo "planner 2 rc=$r2"; cat "$TEST_TMPDIR/b.out"
  # exactly one plan and one refusal: the lock serializes them, so the loser sees the winner's record
  [ $(( (r1 == 0) + (r2 == 0) )) -eq 1 ]
  [ $(( (r1 == 2) + (r2 == 2) )) -eq 1 ]
  local ev="$TEST_TMPDIR/state/kill-lift-1106-2143.evidence"
  [ -f "$ev" ]
  grep -q "status: PLANNED, NOT EXECUTED" "$ev"
  grep -q "already exists" "$TEST_TMPDIR/a.out" "$TEST_TMPDIR/b.out"
  switches_still_present
}

@test "lift planner: the printed step refuses to remove a switch re-armed after the plan" {
  lift_fixture
  lift --by tester
  [ "$status" -eq 0 ]
  local ev step s1 s2
  ev="$(ls "$TEST_TMPDIR"/state/kill-lift-*.evidence)"
  step="$(grep -A1 '^the one step (verbatim' "$ev" | tail -n 1 | sed 's/^  //')"
  s1="$TEST_TMPDIR/etc/credit-trust-score-approve.disabled"; s2="$TEST_TMPDIR/etc/credit-trust-decide.disabled"
  # the decider re-arms one switch after the plan: the step must not lift the new hold on the old proof
  printf 're-armed after the plan\n' > "$s2"
  run bash -c "$step"
  echo "$output"
  [ "$status" -eq 1 ]
  [ -f "$s1" ]
  [ -f "$s2" ]
  grep -q 're-armed after the plan' "$s2"
  cmp "$s1" "$(ls -d "$TEST_TMPDIR"/state/kill-lift-backups/*)/credit-trust-score-approve.disabled"
  grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z ROLLED BACK \[key=kill-lift-.*changed after the plan' "$ev"
  run ! grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z lifted \[key=kill-lift-' "$ev"
}

@test "lift planner: --help prints the usage header and no executable lines" {
  run "$LIFT" --help
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" != *"set -euo pipefail"* ]]
  [[ "$output" != *"ETC_DIR="* ]]
}

@test "lift planner: nothing to lift is exit 2, not a plan, and the proof is not even run" {
  mkdir -p "$TEST_TMPDIR/etc" "$TEST_TMPDIR/state"
  lift
  [ "$status" -eq 2 ]
  [[ "$output" == *"NOTHING TO LIFT"* ]]
  [[ "$output" != *"proof: running"* ]]
  [ -z "$(ls "$TEST_TMPDIR/state" 2>/dev/null)" ]
}

@test "lift planner: the scheduler row is the first stop - the plan says enabled / DISABLED / unknown, never assumes a tick" {
  lift_fixture
  local store="$TEST_TMPDIR/openclaw.sqlite" ev
  # unknown: no store at that path
  lift --cron-store "$TEST_TMPDIR/nope.sqlite"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scheduler: unknown - the cron row's enabled flag could not be read"* ]]
  [[ "$output" == *"UNKNOWN, not assumed"* ]]
  rm -rf "$TEST_TMPDIR/state"; mkdir -p "$TEST_TMPDIR/state"
  # DISABLED: the live shape as measured 2026-11-07 (enabled=0)
  sqlite3 "$store" "create table cron_jobs (store_key text not null, job_id text not null, enabled integer not null, updated_at integer); insert into cron_jobs values ('main','f5fc0ebe-8dc2-5414-8c75-5913ddedb278',0,1792103400000);"
  lift --cron-store "$store"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scheduler: DISABLED - the cron row credit-trust-score-approve-15m is enabled=0"* ]]
  [[ "$output" == *"removing both files restores NOTHING by itself"* ]]
  [[ "$output" != *"approvals may resume"* ]]
  ev="$(ls "$TEST_TMPDIR"/state/kill-lift-*.evidence)"
  # the step's own `lifted` line carries the state the plan saw (the generated script, quoted verbatim in the evidence)
  grep -qF "SCHED='scheduler row was DISABLED at plan time'" "$(ls "$TEST_TMPDIR"/state/kill-lift-*.lift-step.sh)"
  grep -qF "SCHED='scheduler row was DISABLED at plan time'" "$ev"
  grep -q "^scheduler at .*: DISABLED - " "$ev"
  grep -q "acceptance after the step: with the scheduler row enabled," "$ev"
  switches_still_present
  # the store is read, never written
  [ "$(sqlite3 "$store" 'select enabled from cron_jobs')" = "0" ]
  rm -rf "$TEST_TMPDIR/state"; mkdir -p "$TEST_TMPDIR/state"
  # enabled
  sqlite3 "$store" "update cron_jobs set enabled=1"
  lift --cron-store "$store"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scheduler: enabled - the cron row is enabled=1"* ]]
  grep -qF "SCHED='scheduler row was enabled at plan time'" "$(ls "$TEST_TMPDIR"/state/kill-lift-*.lift-step.sh)"
  switches_still_present
}

@test "proof: the default fixture is taken from --tree (the deployed copy); a missing fixture is a refusal, not a traceback" {
  copy_tree "$TEST_TMPDIR/t"
  run python3 "$PROVE" --tree "$TEST_TMPDIR/t"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fixture: $TEST_TMPDIR/t/scripts/credit_review/fixtures/coded-decider-invalidation.json"* ]]
  run python3 "$PROVE" --tree "$TEST_TMPDIR/t" --fixture "$TEST_TMPDIR/nope.json" --record "$TEST_TMPDIR/r.txt"
  echo "$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"REFUSED: fixture $TEST_TMPDIR/nope.json does not exist"* ]]
  [[ "$output" != *"Traceback"* ]]
  grep -q "REFUSED: fixture" "$TEST_TMPDIR/r.txt"
}

@test "the score-approve cron row stays enabled: false in the repo until a PR that cites a kill-lift evidence key flips it" {
  # The first of the three stops is the scheduler row. Flipping it is the captain's decision
  # (docs/credit-verification/score-approve-switch-decision-brief.md asks that question), taken in a PR that cites the
  # recorded step's [key=kill-lift-MMDD-HHMM] evidence - never as a side effect of another change. On 2026-11-07 an
  # automated review fix flipped it to true inside a print-only PR; this pin is what stops that recurring. The PR that
  # deliberately enables the row changes this test in the same diff, with the key in its body.
  run jq -r '.jobs[] | select(.name == "credit-trust-score-approve-15m") | .enabled' "$HYDRA_REPO/cron-jobs.json"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}
