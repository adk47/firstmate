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

# --- --pr-base: the tree's OWN base, never main's moving tip (al-answer-bank-base-a2, 2026-11-16) -------------
# GitHub checks out refs/pull/N/merge, a merge commit whose first parent is main AS IT WAS when the merge was made;
# a re-run or the re-run sweep checks that same commit out again hours later. Comparing against main's tip then
# failed PRs that touch no bank file the moment main bumped the bank (#2126 vs #2040's bump). Each case builds the
# history for real: main, a PR branch, GitHub's merge commit on the OLD main, then main moving on.

_g() { git -C "$FAKE" -c user.email=t@t -c user.name=t "$@"; }

# main = the real bank; pr = the PR branch off it; HEAD = detached merge commit (pr into the old main);
# then main moves on and bumps the bank. Optional $1: a function run on the PR branch before its commit.
_pr_fixture() {
  git -C "$FAKE" init -q -b main
  _g add -A && _g commit -qm base
  _g checkout -qb pr
  echo "unrelated" > "$FAKE/UNRELATED.md"
  [ -z "${1:-}" ] || "$1"
  _g add -A && _g commit -qm "pr: work"
  _g checkout -q --detach main
  _g merge -q --no-ff -m "Merge pr into main" pr
  MERGE="$(git -C "$FAKE" rev-parse HEAD)"
  _g checkout -q main
  # main bumps the bank after the merge commit was made (a later copy PR such as #2040)
  sed -i.bak -e 's/BANK_VERSION = "\([0-9-]*\)\.\([0-9]*\)"/BANK_VERSION = "\1.9\2"/' \
             -e 's/We never ask for ID\./We never ask for any ID./' "$BANK"
  sed -i.bak 's/We never ask for ID\./We never ask for any ID./' "$FAQ"
  rm -f "$BANK.bak" "$FAQ.bak"
  _g add -A && _g commit -qm "main: bank bump"
  _g checkout -q --detach "$MERGE"
}

@test "--pr-base: a PR that touches no bank file passes after main bumped the bank" {
  _pr_fixture
  run env REPO_ROOT="$FAKE" bash "$GATE" --pr-base main
  [ "$status" -eq 0 ]
  [[ "$output" == *"first parent of the merge commit HEAD"* ]]
  [[ "$output" == *"OK: Caroline answer bank"* ]]
}

@test "CAN FAIL: the same tree against main's tip (the old --base) fails -- the fixture reproduces #2126" {
  _pr_fixture
  run env REPO_ROOT="$FAKE" bash "$GATE" --base main
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not greater than"* ]]
}

@test "MUTATION: a gate whose --pr-base resolves to main's tip turns the untouched PR red" {
  _pr_fixture
  local mutant="$BATS_TEST_TMPDIR/mutant.sh"
  sed 's|BASE="${parents\[1\]}"|BASE="$(git -C "$ROOT" rev-parse "$MAIN_REF")"|' "$GATE" > "$mutant"
  ! cmp -s "$GATE" "$mutant"                # the mutation applied (the resolver line still exists)
  run env REPO_ROOT="$FAKE" bash "$mutant" --pr-base main
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not greater than"* ]]
}

@test "--pr-base: a PR head checked out directly (no merge commit) uses the merge base, and passes" {
  _pr_fixture
  _g checkout -q pr
  run env REPO_ROOT="$FAKE" bash "$GATE" --pr-base main
  [ "$status" -eq 0 ]
  [[ "$output" == *"merge base of HEAD and main"* ]]
}

_pr_edits_line_no_bump() { _edit_copy_and_repin; }

@test "CAN FAIL: --pr-base: a PR that edits a bank line (anchor + pin too) without a bump still fails" {
  _pr_fixture _pr_edits_line_no_bump
  run env REPO_ROOT="$FAKE" bash "$GATE"
  [ "$status" -eq 0 ]                       # the pin alone is satisfied ...
  run env REPO_ROOT="$FAKE" bash "$GATE" --pr-base main
  [ "$status" -eq 1 ]                       # ... the comparison with the PR's own base is not
  [[ "$output" == *"is not greater than"* ]]
}

_pr_lowers_version() {
  sed -i.bak 's/BANK_VERSION = "[^"]*"/BANK_VERSION = "2000-01-01.1"/' "$BANK"; rm -f "$BANK.bak"
  local gate="$BATS_TEST_TMPDIR/gate.sh"
  sed 's/PINNED_VERSION="[^"]*"/PINNED_VERSION="2000-01-01.1"/' "$GATE" > "$gate"
  GATE="$gate"
}

@test "CAN FAIL: --pr-base: a PR whose BANK_VERSION goes backwards still fails" {
  _pr_fixture _pr_lowers_version
  run env REPO_ROOT="$FAKE" bash "$GATE"
  [ "$status" -eq 0 ]
  run env REPO_ROOT="$FAKE" bash "$GATE" --pr-base main
  [ "$status" -eq 1 ]
  [[ "$output" == *"went backwards"* ]]
}

@test "CAN FAIL: --pr-base with a main ref that does not resolve fails, never skips" {
  _pr_fixture
  run env REPO_ROOT="$FAKE" bash "$GATE" --pr-base no-such-ref
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot be skipped"* ]]
}

@test "CAN FAIL: a depth-1 checkout of the merge commit fails until its parents are fetched (the CI steps)" {
  _pr_fixture
  _g update-ref refs/pull/1/merge "$MERGE"
  local ci="$BATS_TEST_TMPDIR/ci"
  git init -q "$ci"
  git -C "$ci" fetch -q --no-tags --depth=1 "file://$FAKE" "+$MERGE:refs/remotes/pull/1/merge"
  git -C "$ci" checkout -q --detach "$MERGE"
  git -C "$ci" fetch -q --no-tags --depth=1 "file://$FAKE" "+refs/heads/main:refs/remotes/origin/answer-bank-base"
  run env REPO_ROOT="$ci" bash "$GATE" --pr-base origin/answer-bank-base
  [ "$status" -eq 2 ]
  [[ "$output" == *"shallow boundary"* ]]
  git -C "$ci" fetch -q --no-tags --depth=2 "file://$FAKE" "$(git -C "$ci" rev-parse HEAD)"
  run env REPO_ROOT="$ci" bash "$GATE" --pr-base origin/answer-bank-base
  [ "$status" -eq 0 ]
  [[ "$output" == *"first parent of the merge commit HEAD"* ]]
}

@test "the CI step passes --pr-base and fetches the merge commit's parents, never --base at main's tip" {
  local wf="$REAL_ROOT/.github/workflows/pr-validate.yml"
  grep -q 'git fetch --no-tags --depth=2 origin "$(git rev-parse HEAD)"' "$wf"
  grep -q 'check-caroline-answer-bank.sh --pr-base origin/answer-bank-base' "$wf"
  ! grep -q 'check-caroline-answer-bank.sh --base' "$wf"
}
