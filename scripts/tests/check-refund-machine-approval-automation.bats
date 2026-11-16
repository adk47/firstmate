#!/usr/bin/env bats
# Tests for scripts/check-refund-machine-approval-automation.py: the CI guard that
# stops the machine refund class arming itself. Arming spends money with no
# person's Slack id in the loop, so the flip has to name who approved it and where,
# and the caps have to agree with the wrapper or the number in the file is a lie.
#
# Each case runs the guard against a scratch copy of the repo, so the checked-in
# row is never modified.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/policies" "$T/scripts"
  cp "$REPO_ROOT/scripts/check-refund-machine-approval-automation.py" "$T/scripts/"
  cp "$REPO_ROOT/scripts/muso-stripe-write.sh" "$T/scripts/"
  cp "$REPO_ROOT/policies/refund-machine-approval-automation.json" "$T/policies/"
  GUARD="$T/scripts/check-refund-machine-approval-automation.py"
  ROW="$T/policies/refund-machine-approval-automation.json"
}

setrow() { jq -c "$1" "$ROW" >"$ROW.tmp" && mv "$ROW.tmp" "$ROW"; }

@test "the committed row is unarmed and clean" {
  run python3 "$GUARD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unarmed"* ]]
}

@test "enabled without approved_by -> FAIL" {
  setrow '.enabled = true | .approval_ref = "somewhere"'
  run python3 "$GUARD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"R3: enabled is true but approved_by is empty"* ]]
}

@test "enabled without approval_ref -> FAIL" {
  setrow '.enabled = true | .approved_by = "aaron"'
  run python3 "$GUARD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"R3: enabled is true but approval_ref is empty"* ]]
}

@test "enabled with both named -> PASS" {
  setrow '.enabled = true | .approved_by = "aaron" | .approval_ref = "message 2026-11-15"'
  run python3 "$GUARD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ARMED"* ]]
  [[ "$output" == *"approved_by=aaron"* ]]
}

@test "enabled as a string is not a boolean -> FAIL" {
  setrow '.enabled = "true" | .approved_by = "aaron" | .approval_ref = "x"'
  run python3 "$GUARD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"R2: enabled must be true or false"* ]]
}

@test "an empty-string approval is not an approval -> FAIL" {
  setrow '.enabled = false | .approved_by = "   "'
  run python3 "$GUARD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"R4: approved_by must be null or a non-empty string"* ]]
}

@test "a cap that disagrees with the wrapper -> FAIL" {
  setrow '.cap_usd_per_refund = 500'
  run python3 "$GUARD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"R5: cap_usd_per_refund is 500 but the wrapper enforces 150"* ]]
}

@test "a non-numeric cap -> FAIL" {
  setrow '.cap_usd_per_customer_per_year = "300"'
  run python3 "$GUARD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"R5: cap_usd_per_customer_per_year must be a positive integer"* ]]
}

@test "a missing row -> read error (rc 2), not a pass" {
  rm -f "$ROW"
  run python3 "$GUARD"
  [ "$status" -eq 2 ]
  [[ "$output" == *"is missing"* ]]
}

@test "a row that does not parse -> FAIL" {
  echo '{nope' >"$ROW"
  run python3 "$GUARD"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot read"* ]]
}

@test "R6: flipping enabled in a diff without setting the approval -> FAIL" {
  cd "$T" || return 1
  git init -q . && git add -A >/dev/null 2>&1
  git -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1
  setrow '.enabled = true'
  run python3 "$GUARD" --base HEAD
  [ "$status" -eq 1 ]
  # A bare flip leaves both fields null, so R3 is what catches it (R6 is for the
  # subtler case where one field is inherited - see the next two cases).
  [[ "$output" == *"R3: enabled is true but approved_by is empty"* ]]
}

@test "R6: a flip that names the approval passes" {
  cd "$T" || return 1
  git init -q . && git add -A >/dev/null 2>&1
  git -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1
  setrow '.enabled = true | .approved_by = "aaron" | .approval_ref = "message 2026-11-15"'
  run python3 "$GUARD" --base HEAD
  [ "$status" -eq 0 ]
}

@test "R6: an unresolvable base ref FAILS CLOSED, not open" {
  # qa-review 2026-11-15T15:04Z: a failed `git show` used to read as "new file" and
  # pass, so a one-line flip could bypass the same-change approval rule whenever git
  # could not resolve the ref. An unreadable base is not a new file.
  cd "$T" || return 1
  git init -q . && git add -A >/dev/null 2>&1
  git -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1
  setrow '.enabled = true'
  run python3 "$GUARD" --base no-such-ref-9f3a
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not resolve the base ref"* ]]
  [[ "$output" == *"Failing closed"* ]]
}

@test "R6: a base copy that does not parse is a read error, not a pass" {
  # An unreadable base is not a new file. The realistic shape: the base row exists
  # but is not valid JSON, so R6 cannot tell whether this change armed the class.
  cd "$T" || return 1
  mkdir -p policies && echo '{broken' >"$ROW"
  git init -q . && git add -A >/dev/null 2>&1
  git -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1
  cp "$REPO_ROOT/policies/refund-machine-approval-automation.json" "$ROW"
  setrow '.enabled = true | .approved_by = "aaron" | .approval_ref = "x"'
  run python3 "$GUARD" --base HEAD
  [ "$status" -eq 1 ]
  [[ "$output" == *"base copy of the registry does not parse"* ]]
}

@test "R6: a genuinely absent base file is a new file, and its own row checks govern it" {
  cd "$T" || return 1
  rm -f "$ROW"
  git init -q . && git add -A >/dev/null 2>&1
  git -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1
  cp "$REPO_ROOT/policies/refund-machine-approval-automation.json" "$ROW"
  run python3 "$GUARD" --base HEAD
  [ "$status" -eq 0 ]
  [[ "$output" == *"unarmed"* ]]
}

@test "R6: a flip that inherits an old approval_ref and only changes approved_by -> FAIL" {
  # qa-review 2026-11-15T15:5xZ: `same` compared both fields together, so a base row
  # that already carried an approval_ref let a one-field diff arm the class on the
  # strength of a reference that was never written for this change.
  cd "$T" || return 1
  setrow '.enabled = false | .approved_by = null | .approval_ref = "old ruling 2026-10-30"'
  git init -q . && git add -A >/dev/null 2>&1
  git -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1
  setrow '.enabled = true | .approved_by = "aaron"'
  run python3 "$GUARD" --base HEAD
  [ "$status" -eq 1 ]
  [[ "$output" == *"R6: approval_ref is unchanged from the base row"* ]]
}

@test "R6: a flip that inherits an old approved_by and only changes approval_ref -> FAIL" {
  cd "$T" || return 1
  setrow '.enabled = false | .approved_by = "someone" | .approval_ref = null'
  git init -q . && git add -A >/dev/null 2>&1
  git -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1
  setrow '.enabled = true | .approval_ref = "new ruling 2026-11-15"'
  run python3 "$GUARD" --base HEAD
  [ "$status" -eq 1 ]
  [[ "$output" == *"R6: approved_by is unchanged from the base row"* ]]
}
