#!/usr/bin/env bats
# scripts/check-caroline-answer-bank.sh (caroline-guard-g1): the answer bank and Caroline's workspace never teach
# two different answers, and every copy change is a versioned, pinned event. Every case runs against a COPY of the
# files the gate reads (REPO_ROOT override), so a test can plant a violation without touching the real doctrine.
bats_require_minimum_version 1.5.0

setup() {
  REAL_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  GATE="$REAL_ROOT/scripts/check-caroline-answer-bank.sh"
  FAKE="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$FAKE/workspaces" "$FAKE/plugins/intercom/src"
  cp -R "$REAL_ROOT/workspaces/support" "$FAKE/workspaces/support"
  cp "$REAL_ROOT/plugins/intercom/src/answer-bank.ts" "$FAKE/plugins/intercom/src/"
  FAQ="$FAKE/workspaces/support/reference/faq.md"
  BANK="$FAKE/plugins/intercom/src/answer-bank.ts"
}

run_gate() { run env REPO_ROOT="$FAKE" bash "$GATE"; }

@test "clean copy of the real bank + workspace passes" {
  run_gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: Caroline answer bank"* ]]
}

@test "CAN FAIL: a paraphrased approved line in the workspace is caught" {
  python3 - "$FAQ" <<'PY'
import sys; p = sys.argv[1]; s = open(p).read()
s = s.replace("we check it automatically against public credit sources", "we check it against public sources", 1)
open(p, "w").write(s)
PY
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL: credit_how"* ]]
}

@test "CAN FAIL: a bank line edited without bumping the version + pin is caught" {
  sed -i.bak 's/We never ask for ID\./We never ask for ID!/' "$BANK"
  sed -i.bak 's/We never ask for ID\./We never ask for ID!/' "$FAQ"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"the answer bank changed"* ]]
}

@test "re-wrapping, markdown and curly quotes in the workspace do not fail it" {
  python3 - "$FAQ" <<'PY'
import sys; p = sys.argv[1]; s = open(p).read()
s = s.replace("Merges work like this: claim every profile", "**Merges work like this:**\nclaim every profile", 1)
s = s.replace("so we know they're all you", "so we know they\u2019re all you", 1)
open(p, "w").write(s)
PY
  run_gate
  [ "$status" -eq 0 ]
}

@test "CAN FAIL: a pending entry whose copy is already live must drop its marker" {
  # #1619 landed the GDPR v2 copy and dropped its markers; re-mark one live entry as pending (the marker is not part
  # of the pinned hash, so only the "already live" rule can catch it)
  python3 - "$BANK" <<'PY'
import sys; p = sys.argv[1]; s = open(p).read()
a = '    id: "gdpr_slot_no_link",\n'
assert s.count(a) == 1
s = s.replace(a, a + '    pendingAnchor: "https://github.com/Muso-AI/hydra/pull/1619",\n')
open(p, "w").write(s)
PY
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"gdpr_slot_no_link"*"drop pendingAnchor"* ]]
}

@test "CAN FAIL: an anchor file that does not exist is caught" {
  rm "$FAKE/workspaces/support/skills/verification-handoff/SKILL.md"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not exist"* ]]
}

# --- independent monotonic source: the bank at the PR base (QA on #1628) -----------------------------------

_git_fake() {  # commit the fake repo as the "base"
  git -C "$FAKE" init -q
  git -C "$FAKE" -c user.email=t@t -c user.name=t add -A
  git -C "$FAKE" -c user.email=t@t -c user.name=t commit -qm base
}

# change a bank line AND its anchor AND the pin, but not BANK_VERSION
_edit_copy_and_repin() {
  sed -i.bak 's/We never ask for ID\./We never ask for any ID./' "$BANK" "$FAQ"
  rm -f "$BANK.bak" "$FAQ.bak"
  local gate="$BATS_TEST_TMPDIR/gate.sh" sha
  cp "$GATE" "$gate"
  sha="$(env REPO_ROOT="$FAKE" bash "$gate" 2>&1 | grep -oE 'sha256 [0-9a-f]{64}' | awk '{print $2}')"
  sed -i.bak "s/PINNED_SHA256=\"[0-9a-f]*\"/PINNED_SHA256=\"$sha\"/" "$gate"
  GATE="$gate"
}

@test "CAN FAIL: copy + anchor + pin changed together WITHOUT a version bump fails against the base" {
  _git_fake
  _edit_copy_and_repin
  run env REPO_ROOT="$FAKE" bash "$GATE"
  [ "$status" -eq 0 ]                       # the pin alone is satisfied ...
  run env REPO_ROOT="$FAKE" bash "$GATE" --base HEAD
  [ "$status" -eq 1 ]                       # ... the base comparison is not
  [[ "$output" == *"is not greater than"* ]]
}

@test "the same change WITH a version bump (and its pin) passes against the base" {
  _git_fake
  sed -i.bak 's/BANK_VERSION = "\([0-9-]*\)\.\([0-9]*\)"/BANK_VERSION = "\1.9\2"/' "$BANK"
  _edit_copy_and_repin
  ver="$(grep -oE 'BANK_VERSION = "[^"]+"' "$BANK" | cut -d'"' -f2)"
  sed -i.bak "s/PINNED_VERSION=\"[^\"]*\"/PINNED_VERSION=\"$ver\"/" "$GATE"
  run env REPO_ROOT="$FAKE" bash "$GATE" --base HEAD
  [ "$status" -eq 0 ]
}

@test "CAN FAIL: a --base that does not resolve fails, never skips" {
  _git_fake
  run env REPO_ROOT="$FAKE" bash "$GATE" --base no-such-ref
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot be skipped"* ]]
}
