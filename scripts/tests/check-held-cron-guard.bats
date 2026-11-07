#!/usr/bin/env bats
# scripts/check-held-cron-guard.py - a held cron is armed only by the recorded step.
# Every rule has a mutant that turns the guard RED and a control that stays GREEN; the guard is driven
# through git exactly as pre-commit (--staged) and PR Validation (--base) drive it.
bats_require_minimum_version 1.5.0
HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
GUARD="$HYDRA_REPO/scripts/check-held-cron-guard.py"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  R="$TEST_TMPDIR/repo"
  ETC="$TEST_TMPDIR/etc"
  mkdir -p "$R/policies" "$R/scripts" "$ETC"
  git -C "$R" init -q -b main
  git -C "$R" config user.email t@example.com
  git -C "$R" config user.name t
  cat > "$R/cron-jobs.json" <<'JSON'
{
  "version": 1,
  "jobs": [
    {"id": "f5fc0ebe", "name": "credit-trust-score-approve-15m", "enabled": false,
     "schedule": {"kind": "cron", "expr": "10,25,40,55 * * * *", "tz": "UTC"},
     "payload": {"kind": "agentTurn", "message": "approve"},
     "description": "kill file /etc/hydra/credit-trust-score-approve.disabled"},
    {"id": "a1", "name": "credit-trust-decide-15m", "enabled": true,
     "schedule": {"kind": "cron", "expr": "*/15 * * * *", "tz": "UTC"},
     "payload": {"kind": "agentTurn", "message": "decide"},
     "description": "kill file /etc/hydra/credit-trust-decide.disabled"},
    {"id": "b2", "name": "unrelated-digest", "enabled": false,
     "schedule": {"kind": "cron", "expr": "0 8 * * *", "tz": "UTC"},
     "payload": {"kind": "agentTurn", "message": "digest"},
     "description": "no kill file"},
    {"id": "c3", "name": "host-only-held", "enabled": false,
     "schedule": {"kind": "cron", "expr": "0 9 * * *", "tz": "UTC"},
     "payload": {"kind": "agentTurn", "message": "x"},
     "description": "kill file /etc/hydra/host-only.disabled"}
  ]
}
JSON
  cat > "$R/policies/held-crons.json" <<'JSON'
{
  "held": [
    {"name": "credit-trust-score-approve-15m", "kill_file": "/etc/hydra/credit-trust-score-approve.disabled", "why": "t"},
    {"name": "credit-trust-decide-15m", "kill_file": "/etc/hydra/credit-trust-decide.disabled", "why": "t"}
  ]
}
JSON
  printf '#!/bin/sh\necho hi\n' > "$R/scripts/thing.sh"
  git -C "$R" add -A && git -C "$R" commit -qm base
  git -C "$R" branch -q base
}

teardown() { rm -rf "$TEST_TMPDIR"; }

set_cron() { # name key json-value
  python3 - "$R/cron-jobs.json" "$1" "$2" "$3" <<'PY'
import json, sys
p, name, key, val = sys.argv[1:]
d = json.load(open(p))
for j in d["jobs"]:
    if j["name"] == name:
        j[key] = json.loads(val)
json.dump(d, open(p, "w"), indent=2)
PY
}

drop_cron() {
  python3 - "$R/cron-jobs.json" "$1" <<'PY'
import json, sys
p, name = sys.argv[1:]
d = json.load(open(p)); d["jobs"] = [j for j in d["jobs"] if j["name"] != name]
json.dump(d, open(p, "w"), indent=2)
PY
}

drop_entry() {
  python3 - "$R/policies/held-crons.json" "$1" <<'PY'
import json, sys
p, name = sys.argv[1:]
d = json.load(open(p)); d["held"] = [e for e in d["held"] if e["name"] != name]
json.dump(d, open(p, "w"), indent=2)
PY
}

# the executed step's record: what scripts/credit-approve-hold-lift.sh writes and the human's run appends
evidence() { # key kill_file [planned-only|rolled-back|lifted-then-rearmed]
  mkdir -p "$R/data/kill-lift"
  { printf 'approval hold lift plan [key=%s]\nswitch: %s\nstatus: PLANNED, NOT EXECUTED\n' "$1" "$2"
    case "${3:-}" in
      planned-only) ;;
      rolled-back) printf '2026-11-07T00:50:00Z lifting [key=%s] by tester: proof x\n2026-11-07T00:50:01Z ROLLED BACK [key=%s] by tester: could not take %s\n' "$1" "$1" "$2" ;;
      lifted-then-rearmed) printf '2026-11-07T00:50:00Z lifting [key=%s] by tester: proof x\n2026-11-07T00:50:01Z lifted [key=%s] by tester: %s\n2026-11-07T00:50:02Z RE-ARMED DURING THE STEP [key=%s] by tester: z\n' "$1" "$1" "$2" "$1" ;;
      *) printf '2026-11-07T00:50:00Z lifting [key=%s] by tester: proof x\n2026-11-07T00:50:01Z lifted [key=%s] by tester: both proven switches taken and verified; %s\n' "$1" "$1" "$2" ;;
    esac
  } > "$R/data/kill-lift/$1.evidence"
}
set_kill_file() { # name new-kill-file
  python3 - "$R/policies/held-crons.json" "$1" "$2" <<'PYX'
import json, sys
p, name, kf = sys.argv[1:]
d = json.load(open(p))
for e in d["held"]:
    if e["name"] == name: e["kill_file"] = kf
json.dump(d, open(p, "w"), indent=2)
PYX
}

staged() { git -C "$R" add -A; run python3 "$GUARD" --repo "$R" --etc-dir "$ETC" --staged "$@"; }
committed() { git -C "$R" add -A; git -C "$R" commit -q --allow-empty -m "${1:-change}"; run python3 "$GUARD" --repo "$R" --etc-dir "$ETC" --base base; }
restore() { git -C "$R" reset -q --hard HEAD; }

@test "control: no change is GREEN in both modes" {
  staged
  [ "$status" -eq 0 ]
  [[ "$output" == *"held-cron-guard: OK - 2 held cron(s) untouched"* ]]
  committed
  [ "$status" -eq 0 ]
}

@test "control: enabling, rescheduling or deleting an UNRELATED cron stays GREEN" {
  set_cron unrelated-digest enabled true
  set_cron unrelated-digest schedule '{"kind":"cron","expr":"5 8 * * *","tz":"UTC"}'
  staged
  echo "$output"
  [ "$status" -eq 0 ]
  drop_cron unrelated-digest
  committed "drop digest"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "mutant R1: enabled false -> true on the held approver is RED, staged and committed" {
  set_cron credit-trust-score-approve-15m enabled true
  staged
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"R1 credit-trust-score-approve-15m: enabled False -> true while its kill file /etc/hydra/credit-trust-score-approve.disabled is present"* ]]
  committed "no-mistakes(review): Enable the score-approve cron row so the lift restores approvals"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"R1 credit-trust-score-approve-15m"* ]]
}

@test "mutant R2/R3: schedule or payload of a held cron is RED; R4: deleting its row is RED" {
  set_cron credit-trust-decide-15m schedule '{"kind":"cron","expr":"*/5 * * * *","tz":"UTC"}'
  staged
  [ "$status" -eq 1 ]
  [[ "$output" == *"R2 credit-trust-decide-15m: schedule"* ]]
  restore
  set_cron credit-trust-decide-15m payload '{"kind":"agentTurn","message":"decide --apply"}'
  staged
  [ "$status" -eq 1 ]
  [[ "$output" == *"R3 credit-trust-decide-15m: payload"* ]]
  restore
  drop_cron credit-trust-score-approve-15m
  staged
  [ "$status" -eq 1 ]
  [[ "$output" == *"R4 credit-trust-score-approve-15m: held cron"*"deleted from cron-jobs.json"* ]]
}

@test "mutant R5: removing the registry entry without the recorded step's key is RED, with or without the flag flip" {
  drop_entry credit-trust-score-approve-15m
  staged
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"R5 credit-trust-score-approve-15m: entry removed from policies/held-crons.json without the recorded step's key"* ]]
  set_cron credit-trust-score-approve-15m enabled true
  committed "turn it on"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"R5 credit-trust-score-approve-15m"* ]]
  [[ "$output" == *"R1 credit-trust-score-approve-15m"* ]]
}

@test "mutant: an EDITED entry with a cited key is R5, with or without the executed record" {
  set_kill_file credit-trust-score-approve-15m /etc/hydra/somewhere-else.disabled
  set_cron credit-trust-score-approve-15m enabled true
  committed "credit-trust-score-approve-15m per [key=kill-lift-1107-0042]"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"R5 credit-trust-score-approve-15m: key cited but not backed"* ]]
  [[ "$output" == *"R1 credit-trust-score-approve-15m"* ]]
  evidence kill-lift-1107-0042 /etc/hydra/credit-trust-score-approve.disabled
  committed "commit the executed record"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"an edited entry is not a lift"* ]]
  [[ "$output" == *"R1 credit-trust-score-approve-15m"* ]]
}

@test "the one way through: entry removed AND [key=kill-lift-MMDD-HHMM] cited in a commit message is GREEN for that cron only" {
  drop_entry credit-trust-score-approve-15m
  set_cron credit-trust-score-approve-15m enabled true
  # the key alone, on a line that does not name the cron, binds to nothing
  committed "lift: approvals resume per [key=kill-lift-1107-0042]"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"R5 credit-trust-score-approve-15m"* ]]
  git -C "$R" reset -q --hard base
  # a key with no committed evidence, planned-only evidence, or evidence for another switch is not a lift
  drop_entry credit-trust-score-approve-15m
  set_cron credit-trust-score-approve-15m enabled true
  committed "lift: credit-trust-score-approve-15m resumes per [key=kill-lift-1107-0042]"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"R5 credit-trust-score-approve-15m: key cited but not backed by the executed step's record"* ]]
  [[ "$output" == *"data/kill-lift/kill-lift-1107-0042.evidence"* ]]
  evidence kill-lift-1107-0042 /etc/hydra/credit-trust-score-approve.disabled planned-only
  committed "commit the plan"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no step record (the step was planned, not run)"* ]]
  # a step that RAN but did not complete is not a lift: rolled back, or lifted and then re-armed (lifted is not last)
  evidence kill-lift-1107-0042 /etc/hydra/credit-trust-score-approve.disabled rolled-back
  committed "commit a rolled-back record"
  [ "$status" -eq 1 ]
  [[ "$output" == *"the step ran but did not complete: ROLLED BACK"* ]]
  evidence kill-lift-1107-0042 /etc/hydra/credit-trust-score-approve.disabled lifted-then-rearmed
  committed "commit a lifted-then-re-armed record"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ends in 'RE-ARMED DURING THE STEP', not 'lifted' (the step did not complete)"* ]]
  evidence kill-lift-1107-0042 /etc/hydra/some-other.disabled
  committed "commit another switch's record"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not name /etc/hydra/credit-trust-score-approve.disabled"* ]]
  # the executed step's record, committed in the same range, is the one way through
  evidence kill-lift-1107-0042 /etc/hydra/credit-trust-score-approve.disabled
  committed "commit the executed record"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"recorded step cited (kill-lift-1107-0042); lifted in this diff: credit-trust-score-approve-15m"* ]]
  # ... and off the host it is a CLAIM, said in so many words, never a confirmation
  [[ "$output" == *"NOTE this run cannot see the host, so the committed record is a CLAIM here"* ]]
  [[ "$output" != *"HOST CONFIRMED"* ]]
  # the key does not cover a cron whose entry stays in the registry
  set_cron credit-trust-decide-15m schedule '{"kind":"cron","expr":"*/5 * * * *","tz":"UTC"}'
  committed "also touch credit-trust-decide-15m [key=kill-lift-1107-0042]"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"R2 credit-trust-decide-15m"* ]]
}

@test "--host: a committed record is confirmed only when THIS host agrees - kill file gone and the step's own record byte-identical" {
  local HS="$TEST_TMPDIR/host-state"; mkdir -p "$HS"
  drop_entry credit-trust-score-approve-15m
  set_cron credit-trust-score-approve-15m enabled true
  evidence kill-lift-1107-0042 /etc/hydra/credit-trust-score-approve.disabled
  git -C "$R" add -A; git -C "$R" commit -q -m "lift: credit-trust-score-approve-15m resumes per [key=kill-lift-1107-0042]"
  host() { run python3 "$GUARD" --repo "$R" --etc-dir "$ETC" --base base --host --host-state-dir "$HS"; }
  # fabricated: the kill file is still on the host -> the hold is ON, the record is a claim -> R5 + R1
  printf 'hold\n' > "$ETC/credit-trust-score-approve.disabled"
  host; echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"R5 credit-trust-score-approve-15m: key cited but not backed by the executed step's record: host "*" still has $ETC/credit-trust-score-approve.disabled: the hold is ON, nothing was lifted"* ]]
  [[ "$output" == *"R1 credit-trust-score-approve-15m"* ]]
  [[ "$output" != *"HOST CONFIRMED"* ]]
  # kill file gone but the host has no record of a step -> the step never ran here
  rm "$ETC/credit-trust-score-approve.disabled"
  host; echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no $HS/kill-lift-1107-0042.evidence: the step never ran here"* ]]
  # the host's record differs from the committed one (an edited copy) -> not byte-identical
  cp "$R/data/kill-lift/kill-lift-1107-0042.evidence" "$HS/kill-lift-1107-0042.evidence"
  printf '2026-11-07T00:50:02Z ROLLED BACK [key=kill-lift-1107-0042] by tester: could not take\n' >> "$HS/kill-lift-1107-0042.evidence"
  host; echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not byte-identical to the host's $HS/kill-lift-1107-0042.evidence"* ]]
  [[ "$output" == *"commit the host's file as it is"* ]]
  # the genuine case: host record == committed record, kill file absent -> CONFIRMED, R1-R4 lifted for that cron
  cp "$R/data/kill-lift/kill-lift-1107-0042.evidence" "$HS/kill-lift-1107-0042.evidence"
  host; echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"HOST CONFIRMED on "*": kill file absent and the step's record under $HS is byte-identical to the committed copy for kill-lift-1107-0042"* ]]
  [[ "$output" != *"NOTE this run cannot see the host"* ]]
  # an unreadable host state dir is 'no record', never a pass
  host_unreadable() { run python3 "$GUARD" --repo "$R" --etc-dir "$ETC" --base base --host --host-state-dir "$TEST_TMPDIR/no-such-state"; }
  host_unreadable; echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"the step never ran here"* ]]
}

@test "mutant: one cron's key does NOT lift a second entry removed in the same diff" {
  evidence kill-lift-1107-0042 /etc/hydra/credit-trust-score-approve.disabled
  drop_entry credit-trust-score-approve-15m
  drop_entry credit-trust-decide-15m
  set_cron credit-trust-score-approve-15m enabled true
  set_cron credit-trust-decide-15m schedule '{"kind":"cron","expr":"*/5 * * * *","tz":"UTC"}'
  committed "lift: credit-trust-score-approve-15m resumes per [key=kill-lift-1107-0042]"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"R5 credit-trust-decide-15m"* ]]
  [[ "$output" == *"R2 credit-trust-decide-15m"* ]]
  [[ "$output" != *"R5 credit-trust-score-approve-15m"* ]]
  # staged: the env value names the crons it covers (back to the base tree first; the mutant is committed above)
  git -C "$R" reset -q --hard base
  evidence kill-lift-1107-0042 /etc/hydra/credit-trust-score-approve.disabled
  drop_entry credit-trust-score-approve-15m
  drop_entry credit-trust-decide-15m
  set_cron credit-trust-decide-15m schedule '{"kind":"cron","expr":"*/5 * * * *","tz":"UTC"}'
  git -C "$R" add -A
  run env HELD_CRON_LIFT_KEY=kill-lift-1107-0042:credit-trust-score-approve-15m python3 "$GUARD" --repo "$R" --etc-dir "$ETC" --staged
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"R5 credit-trust-decide-15m"* ]]
}

@test "the one way through, staged: HELD_CRON_LIFT_KEY stands in for the commit message pre-commit has not got yet" {
  evidence kill-lift-1107-0042 /etc/hydra/credit-trust-score-approve.disabled
  drop_entry credit-trust-score-approve-15m
  set_cron credit-trust-score-approve-15m enabled true
  staged
  [ "$status" -eq 1 ]
  git -C "$R" add -A
  run env HELD_CRON_LIFT_KEY=kill-lift-1107-0042:credit-trust-score-approve-15m python3 "$GUARD" --repo "$R" --etc-dir "$ETC" --staged
  echo "$output"
  [ "$status" -eq 0 ]
  # a malformed key, or a key that names no cron, is no key
  run env HELD_CRON_LIFT_KEY=yes python3 "$GUARD" --repo "$R" --etc-dir "$ETC" --staged
  [ "$status" -eq 1 ]
  run env HELD_CRON_LIFT_KEY=kill-lift-1107-0042 python3 "$GUARD" --repo "$R" --etc-dir "$ETC" --staged
  [ "$status" -eq 1 ]
}

@test "mutant R6: an added code line that deletes a .disabled sentinel is RED; tests, docs and an explicit opt-out are not" {
  printf 'rm -f /etc/hydra/credit-trust-score-approve.disabled\n' >> "$R/scripts/thing.sh"
  staged
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"R6 scripts/thing.sh: added line deletes a .disabled sentinel: rm -f /etc/hydra/credit-trust-score-approve.disabled"* ]]
  restore
  printf 'KILL.unlink(missing_ok=True)  # the .disabled file\n' >> "$R/scripts/thing.sh"
  staged
  [ "$status" -eq 1 ]
  [[ "$output" == *"R6 scripts/thing.sh"* ]]
  restore
  # control: the same line in a bats file, a doc, and with the opt-out comment
  mkdir -p "$R/scripts/tests" "$R/docs"
  printf 'rm -f "$T/x.disabled"\n' > "$R/scripts/tests/t.bats"
  printf 'run `rm /etc/hydra/x.disabled`\n' > "$R/docs/x.md"
  printf 'rm -f -- "$f"  # held-cron-guard: the kill-lift step, printed not run\n' >> "$R/scripts/thing.sh"
  staged
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "host kill files define held crons too: a present /etc/hydra file makes an unregistered cron held (WARNING), and arming it is RED" {
  touch "$ETC/host-only.disabled"
  staged
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING host-only-held: kill file /etc/hydra/host-only.disabled is present on this host but the cron is not in policies/held-crons.json"* ]]
  set_cron host-only-held enabled true
  staged
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"R1 host-only-held: enabled False -> true while its kill file /etc/hydra/host-only.disabled is present"* ]]
}

@test "unreadable inputs are exit 2, never a pass" {
  printf 'not json' > "$R/policies/held-crons.json"
  git -C "$R" add -A
  run python3 "$GUARD" --repo "$R" --etc-dir "$ETC" --staged
  [ "$status" -eq 2 ]
  [[ "$output" == *"exit 2 is not a pass"* ]]
  run python3 "$GUARD" --repo "$R" --etc-dir "$ETC" --base no-such-ref
  [ "$status" -eq 2 ]
}

@test "this repo: policies/held-crons.json names real crons, every one enabled:false except the decider, and the guard is GREEN on HEAD" {
  python3 - "$HYDRA_REPO" <<'PY'
import json, sys
root = sys.argv[1]
jobs = {j["name"]: j for j in json.load(open(f"{root}/cron-jobs.json"))["jobs"]}
held = json.load(open(f"{root}/policies/held-crons.json"))["held"]
names = [e["name"] for e in held]
assert "credit-trust-score-approve-15m" in names and "credit-trust-decide-15m" in names, names
for e in held:
    assert e["name"] in jobs, f"{e['name']} is not a cron"
    assert e["kill_file"].startswith("/etc/hydra/") and e["kill_file"].endswith(".disabled"), e
    assert e["kill_file"] in jobs[e["name"]].get("description", ""), f"{e['name']}: description does not name {e['kill_file']}"
assert jobs["credit-trust-score-approve-15m"]["enabled"] is False
PY
  run python3 "$GUARD" --repo "$HYDRA_REPO" --etc-dir "$TEST_TMPDIR/no-etc" --base HEAD
  echo "$output"
  [ "$status" -eq 0 ]
}
