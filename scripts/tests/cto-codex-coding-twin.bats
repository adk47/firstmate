#!/usr/bin/env bats
# Behavioral test for cto-codex-coding step 9 (the core-backend `master` twin).
#
# Why this exists: the twin block is the ONLY thing that gets a core-backend fix
# to production (`develop` serves dev, `master` serves api.muso.ai, and the two
# are permanently diverged). An earlier revision pushed and PR'd unconditionally
# after a failed cherry-pick, so the hand-port path shipped an unchanged copy of
# origin/master and `gh pr create` died with "No commits between ..." -- no twin
# at all, silently. Prose alone did not prevent that; this suite does.
#
# The block is extracted from SKILL.md at run time, so the test tracks the
# documented procedure rather than a copy of it that can drift.

setup() {
  HYDRA_REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SKILL="$HYDRA_REPO/skills-all/cto-codex-coding/SKILL.md"
  [ -f "$SKILL" ] || skip "skill not found: $SKILL"

  # Extract the fenced block that starts the core-backend twin guard.
  # Step 8's identity capture is extracted too and run BEFORE the twin block, so
  # the suite crosses the real step8 -> step9 boundary. Injecting dev_pr_* as
  # defaults here once hid the fact that nothing in the procedure ever set them.
  CAPTURE="$BATS_TEST_TMPDIR/capture.sh"
  awk '
    /^   dev_pr_url=\$\(gh pr view/ {grab=1}
    grab {line=$0; sub(/^   /,"",line); print line}
    grab && /refusing to continue to the twin/ {exit}
  ' "$SKILL" > "$CAPTURE"
  [ -s "$CAPTURE" ] || fail "could not extract step 8's identity capture"

  BLOCK="$BATS_TEST_TMPDIR/twin.sh"
  # Strip the 3-space markdown indent, then terminate on the block's own `fi`.
  # (Testing the end pattern AFTER sub() is load-bearing -- matching the
  # pre-strip form never fires and the extraction swallows the prose below.)
  awk '
    /^   # This block guards EVERY fallible command itself/ {grab=1}
    grab {line=$0; sub(/^   /,"",line); print line; if (line=="fi") exit}
  ' "$SKILL" > "$BLOCK"
  [ -s "$BLOCK" ] || fail "could not extract the twin block from $SKILL"

  # Stub gh so it RECORDS its argv. Counting commits on the pushed branch only
  # proves the push happened -- with a marker-only stub, deleting `gh pr create`
  # from step 9 leaves every test green while reproducing the exact production
  # gap this suite exists to close: a branch on the remote and no twin PR.
  # So the success paths assert the create call POSITIVELY, args and all.
  GH_CALLS="$BATS_TEST_TMPDIR/gh-calls"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  # The stub mirrors real gh behaviour, because that is what the retry path
  # turns on: `pr create` FAILS once a PR exists for the branch, and `pr list`
  # is how you find it. A stub that always succeeds would make the retry look
  # fine while production dies at "a pull request already exists".
  GH_PR_STATE="$BATS_TEST_TMPDIR/gh-pr-exists"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<GHSTUB
#!/bin/sh
printf '%s\\n' "\$*" >> "$GH_CALLS"
case "\$*" in
  *"pr view"*"--json url"*)   printf 'https://github.com/Muso-AI/core-backend/pull/4242\\n'; exit 0 ;;
  *"pr view"*"--json title"*) printf 'fix(api): real develop title\\n'; exit 0 ;;
  *"pr list"*)
    if [ -f "$GH_PR_STATE" ]; then printf 'https://github.com/x/y/pull/1\\n'; fi
    exit 0 ;;
  *"pr create"*)
    if [ -f "$GH_PR_STATE" ]; then
      echo "a pull request for branch already exists" >&2; exit 1
    fi
    : > "$GH_PR_STATE"
    printf 'https://github.com/x/y/pull/1\\n'; exit 0 ;;
esac
exit 0
GHSTUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  # Mirror core-backend's real topology: origin/master (prod), origin/develop
  # (the PR base), and a cto/ work branch off develop. Collapsing develop and
  # the work branch would hide the multi-commit range this step must port.
  cd "$BATS_TEST_TMPDIR"
  git init -q -b master remote.git --bare
  git clone -q remote.git work
  cd work
  git config user.email t@t; git config user.name t
  echo base > f.txt; git add -A; git commit -qm base; git push -q origin master
  git switch -qc develop; git push -q origin develop
  git switch -qc cto/fix
  WORK=cto/fix
  TWIN=cto/fix-master
}

# Step 8's capture legitimately calls `gh pr view`, so "gh was never called" is
# no longer the right assertion for a refusal -- what must not happen is a twin
# PR being created or an existing one being adopted.
assert_no_twin_pr() {
  [ -f "$GH_CALLS" ] || return 0
  grep -q 'pr create' "$GH_CALLS" && fail "a twin PR was created: $(cat "$GH_CALLS")"
  grep -q 'pr list'   "$GH_CALLS" && fail "reached the PR step: $(cat "$GH_CALLS")"
  return 0
}

# The twin PR must actually be requested, against master, from the twin branch.
assert_twin_pr_opened() {
  [ -f "$GH_CALLS" ] || fail "gh was never invoked -- no twin PR was created"
  grep -q 'pr create' "$GH_CALLS" || fail "gh ran but never 'pr create': $(cat "$GH_CALLS")"
  grep -q -- '--base master' "$GH_CALLS" || fail "twin PR not based on master: $(cat "$GH_CALLS")"
  grep -q -- '--head cto/fix-master' "$GH_CALLS" || fail "twin PR not from the twin branch: $(cat "$GH_CALLS")"
  # The twin's only link back to the reviewed change: assert the REAL title and
  # source URL reached gh, not the document's placeholders.
  grep -q 'fix(api): real develop title (master twin)' "$GH_CALLS" \
    || fail "twin PR title is not derived from the develop PR: $(cat "$GH_CALLS")"
  grep -q 'pull/4242' "$GH_CALLS" \
    || fail "twin PR body does not link the develop PR: $(cat "$GH_CALLS")"
  grep -q '<same title' "$GH_CALLS" && fail "placeholder title reached gh: $(cat "$GH_CALLS")"
  grep -q '<url>' "$GH_CALLS" && fail "placeholder url reached gh: $(cat "$GH_CALLS")"
  return 0
}

# Build the environment the block expects, then run it.
run_twin() {
  # NO `set -e`: the shipped block runs without it, so the harness must too.
  # Injecting it once made every guard look effective while an unguarded
  # `git push` failure fell straight through to the PR step in production.
  # step 8's capture, then step 9 -- the real boundary, in one shell.
  bash -c 'clone="$1"; repo="$2"; branch="$3"; base="$4"; . "$5"; . "$6"' _ \
    "$PWD" "Muso-AI/core-backend" "$WORK" develop "$CAPTURE" "$BLOCK"
}

@test "clean cherry-pick: twin carries the change and proceeds" {
  echo "develop change" > g.txt; git add -A; git commit -qm "fix on develop"
  run run_twin
  [ "$status" -eq 0 ]
  # the twin branch exists on the remote and carries exactly one commit
  run git rev-list origin/master..origin/cto/fix-master --count
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  assert_twin_pr_opened
}

@test "conflicting cherry-pick with no hand-port: REFUSES, pushes nothing" {
  echo "develop side" > f.txt; git commit -qam "fix on develop"
  git switch -q master; echo "master side" > f.txt; git commit -qam "master drift"
  git push -q origin master; git switch -q "$WORK"

  run run_twin
  [ "$status" -ne 0 ]
  [[ "$output" == *"cherry-pick conflicted"* ]]

  # nothing reached the remote, and no twin PR was created
  run git ls-remote --heads origin cto/fix-master
  [ -z "$output" ]
  assert_no_twin_pr
}

@test "conflict -> hand-port commit -> RERUN of the unmodified block opens the twin" {
  # The real recovery sequence. The block is run VERBATIM both times: a test
  # that rewrites the procedure to make it pass would mask exactly the
  # resumability defect this case exists to catch.
  echo "develop side" > f.txt; git commit -qam "fix on develop"
  git switch -q master; echo "master side" > f.txt; git commit -qam "master drift"
  git push -q origin master; git switch -q "$WORK"

  # run 1: conflicts, refuses, and leaves the twin branch behind
  run run_twin
  [ "$status" -ne 0 ]
  run git rev-parse --verify --quiet refs/heads/cto/fix-master
  [ "$status" -eq 0 ]

  # operator commits the hand-port onto the twin that run 1 left
  git switch -q "$TWIN"
  echo "hand-ported equivalent" > f.txt
  git commit -qam "hand-port of the develop fix"
  git switch -q "$WORK"

  # run 2: the SAME block, unmodified, must resume and open the twin.
  # The hand-port is genuine here, so acknowledge it explicitly (export, not a
  # `VAR=x run` prefix -- that form is not reliably delivered under `run`).
  export TWIN_HANDPORT_VERIFIED=1
  run run_twin
  [ "$status" -eq 0 ]
  run git rev-list origin/master..origin/cto/fix-master --count
  [ "$output" = "1" ]
  assert_twin_pr_opened
}

@test "rerun never resets a committed hand-port" {
  # `switch -C` would be the tempting one-liner for resumability and would
  # silently destroy the operator's hand-port. Pin the commit across a rerun.
  echo "develop side" > f.txt; git commit -qam "fix on develop"
  git switch -q master; echo "master side" > f.txt; git commit -qam "master drift"
  git push -q origin master; git switch -q "$WORK"

  run run_twin
  [ "$status" -ne 0 ]
  git switch -q "$TWIN"
  echo "hand-ported equivalent" > f.txt; git commit -qam "hand-port"
  want=$(git rev-parse cto/fix-master)
  git switch -q "$WORK"

  export TWIN_HANDPORT_VERIFIED=1
  run run_twin
  [ "$status" -eq 0 ]
  got=$(git rev-parse cto/fix-master)
  [ "$want" = "$got" ]
}

@test "an UNRELATED commit on the twin is refused as an unverified hand-port" {
  # "the branch has commits" is not "the fix is ported". Pushing here would
  # open a production twin that looks like coverage and does not contain the
  # change -- worse than no twin, because it reads as done.
  echo "develop side" > f.txt; git commit -qam "fix on develop"
  git switch -q master; echo "master side" > f.txt; git commit -qam "master drift"
  git push -q origin master; git switch -q "$WORK"

  run run_twin                       # conflicts, refuses, leaves the twin branch
  [ "$status" -ne 0 ]

  git switch -q "$TWIN"
  echo "note" > NOTES.md; git add -A; git commit -qm "unrelated note, NOT the port"
  git switch -q develop

  run run_twin
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNVERIFIED"* ]]
  run git ls-remote --heads origin cto/fix-master
  [ -z "$output" ]                   # nothing pushed
  assert_no_twin_pr
}

@test "a verified hand-port proceeds when explicitly acknowledged" {
  echo "develop side" > f.txt; git commit -qam "fix on develop"
  git switch -q master; echo "master side" > f.txt; git commit -qam "master drift"
  git push -q origin master; git switch -q "$WORK"

  run run_twin
  [ "$status" -ne 0 ]
  git switch -q "$TWIN"
  echo "hand-ported equivalent" > f.txt; git commit -qam "hand-port of the develop fix"
  git switch -q "$WORK"

  export TWIN_HANDPORT_VERIFIED=1
  run run_twin
  [ "$status" -eq 0 ]
  assert_twin_pr_opened
}

@test "RETRY after the twin PR already exists still reaches the QA handoff" {
  # The run dies after `gh pr create` succeeds. On rerun, creating again would
  # fail non-zero ("a pull request already exists") and, under the block's own guards
  # shell, kill the run BEFORE the QA hand-off -- leaving the production twin
  # permanently outside the review path.
  echo "develop change" > g.txt; git add -A; git commit -qm "fix on develop"

  run run_twin                       # first run: creates the PR
  [ "$status" -eq 0 ]
  assert_twin_pr_opened

  : > "$GH_CALLS"                    # forget the first run's calls
  run run_twin                       # rerun, PR already exists
  [ "$status" -eq 0 ]
  grep -q 'pr list' "$GH_CALLS" || fail "rerun never looked for an existing PR"
  grep -q 'twin PR: https://github.com/x/y/pull/1' <<<"$output" \
    || fail "rerun did not surface the existing twin URL: $output"
}

@test "RETRY after a CLEAN cherry-pick does not demand a hand-port ack" {
  # A resumed clean cherry-pick is not a hand-port. Requiring the
  # acknowledgement here would block a retry that never involved one.
  echo "develop change" > g.txt; git add -A; git commit -qm "fix on develop"
  run run_twin
  [ "$status" -eq 0 ]

  # rerun with the twin branch present and TWIN_HANDPORT_VERIFIED unset
  unset TWIN_HANDPORT_VERIFIED
  run run_twin
  [ "$status" -eq 0 ]
  [[ "$output" != *UNVERIFIED* ]]
  [[ "$output" == *"ported=clean"* ]]
}

@test "MULTI-COMMIT: a two-commit fix ports BOTH commits to the twin" {
  # ship Stage 4 runs smart-commit, which clusters a change into as many
  # logical commits as it needs. Porting only the tip would ship half the fix
  # to production while still reporting ported=clean.
  echo "part one" > a.txt; git add -A; git commit -qm "fix: part one"
  echo "part two" > b.txt; git add -A; git commit -qm "test: part two"

  run run_twin
  [ "$status" -eq 0 ]
  [[ "$output" == *"ported=clean"* ]]

  run git rev-list origin/master..origin/cto/fix-master --count
  [ "$output" = "2" ]

  # both files must exist on the twin -- the real assertion, since a count
  # could be satisfied by the wrong commits
  run git show origin/cto/fix-master:a.txt
  [ "$status" -eq 0 ]
  run git show origin/cto/fix-master:b.txt
  [ "$status" -eq 0 ]
  assert_twin_pr_opened
}

@test "MULTI-COMMIT retry: a twin missing one commit is NOT treated as clean" {
  echo "part one" > a.txt; git add -A; git commit -qm "fix: part one"
  echo "part two" > b.txt; git add -A; git commit -qm "test: part two"
  tip=$(git rev-parse HEAD)

  # a twin carrying only the LAST commit -- the partial-fix shape
  git switch -q -c "$TWIN" origin/master
  git cherry-pick "$tip" >/dev/null
  git switch -q "$WORK"

  run run_twin
  [ "$status" -ne 0 ]
  [[ "$output" == *UNVERIFIED* ]]
  assert_no_twin_pr
}

@test "EXTRAS: all wanted commits PLUS an unrelated one must be refused" {
  # A subset check would call this clean and push the stray commit into the
  # production PR with no hand-port acknowledgement.
  echo "part one" > a.txt; git add -A; git commit -qm "fix: part one"
  tip=$(git rev-parse HEAD)

  git switch -q -c "$TWIN" origin/master
  git cherry-pick "$tip" >/dev/null
  echo stray > stray.txt; git add -A; git commit -qm "unrelated manual commit"
  git switch -q "$WORK"

  run run_twin
  [ "$status" -ne 0 ]
  [[ "$output" == *UNVERIFIED* ]]
  [[ "$output" == *"extra commits"* ]]
  assert_no_twin_pr
}

@test "a FAILED push must abort, never report a twin the remote lacks" {
  # Nothing upstream sets `set -e`, so before the explicit guards an unguarded
  # push failure fell through into the PR step: it reused a stale PR and
  # reported "twin PR: ... (ported=clean)" for a branch the remote never
  # received. Verified against the real block with a broken remote.
  echo "part one" > a.txt; git add -A; git commit -qm "fix: part one"
  # push-only breakage: fetch must still succeed so the run reaches the push.
  git remote set-url --push origin /nonexistent/repo.git

  run run_twin
  [ "$status" -ne 0 ]
  [[ "$output" == *"push of cto/fix-master failed"* ]]
  [[ "$output" != *"twin PR:"* ]]
  assert_no_twin_pr
}

@test "a FAILED fetch aborts before touching any branch" {
  echo "part one" > a.txt; git add -A; git commit -qm "fix: part one"
  git remote set-url origin /nonexistent/repo.git

  run run_twin
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot fetch origin/master"* ]]
  run git rev-parse --verify --quiet refs/heads/cto/fix-master
  [ "$status" -ne 0 ]      # twin branch never created
}

@test "missing develop PR identity fails closed, no placeholder PR is created" {
  echo "part one" > a.txt; git add -A; git commit -qm "fix: part one"
  # break the real source of the identity, not an injected variable
  printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  run run_twin
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot read the develop PR url"* ]]
  run git ls-remote --heads origin cto/fix-master
  [ -z "$output" ]
}

@test "ABORT FAILURE on a multi-commit conflict never pushes a partial twin" {
  # commit 1 applies, commit 2 conflicts. If `cherry-pick --abort` then fails
  # (locked index in the shared clone), the old code fell through with commit 1
  # still on the twin -- and the empty-twin guard only catches an EMPTY twin, so
  # it pushed a PARTIAL fix to production as ported=hand with no hand-port
  # acknowledgement. Force the abort to fail and assert we stop.
  echo one > a.txt; git add -A; git commit -qm "fix: part one"
  echo "develop side" > f.txt; git commit -qam "fix: part two"
  git switch -q master; echo "master side" > f.txt; git commit -qam "master drift"
  git push -q origin master; git switch -q "$WORK"

  # a git shim that fails ONLY `cherry-pick --abort`
  cat > "$BATS_TEST_TMPDIR/bin/git" <<'GITSHIM'
#!/bin/sh
for a in "$@"; do
  if [ "$a" = "--abort" ]; then echo "fatal: index locked" >&2; exit 1; fi
done
exec /usr/bin/git "$@"
GITSHIM
  chmod +x "$BATS_TEST_TMPDIR/bin/git"

  run run_twin
  [ "$status" -ne 0 ]
  [[ "$output" == *"abort FAILED"* ]] || [[ "$output" == *"unknown state"* ]]
  run /usr/bin/git ls-remote --heads origin cto/fix-master
  [ -z "$output" ]          # no partial twin on the remote
  assert_no_twin_pr
}
