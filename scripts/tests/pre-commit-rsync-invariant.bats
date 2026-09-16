#!/usr/bin/env bats
# Tests for .githooks/pre-commit check 2/7 — the deploy.sh rsync-excludes gate.
#
# Why this suite exists: from 2026-06-11 until this fix, the hook exited 1 on
# EVERY commit, for every author, on clean main with nothing staged:
#
#   ✗ deploy.sh has 9 rsync call(s) but 13 reference ${RSYNC_EXCLUDES[@]}
#     (must match exactly)
#
# The stated invariant (hook, "We require: >=1 rsync call AND every rsync call
# references the array") is correct. Its IMPLEMENTATION compared two counts of
# unrelated things:
#
#   rsync_calls         = LINES matching `rsync -`               -> 9
#   rsync_with_excludes = LINES containing "${RSYNC_EXCLUDES[@]}" -> 13
#
# Those can never be equal in deploy.sh, because six rsync invocations carry
# the array on a line-CONTINUATION rather than the `rsync -` line, and five
# more references belong to the exclude-ordering self-validation loop around
# deploy.sh:1255-1291, which is not an rsync call at all.
#
# The "9" was itself wrong: deploy.sh has EIGHT rsync calls. The ninth was
# prose inside deploy.sh:1289's own fail() string ("...and rsync --delete
# could destroy it"), which comment stripping cannot remove because it is
# code. Anchoring on a command position drops the phantom.
#
# The equality test was therefore wrong in BOTH directions:
#   - false POSITIVE: it fired permanently on a correct deploy.sh (the outage);
#   - false NEGATIVE: it passes when one rsync loses the array AND an unrelated
#     reference is added elsewhere, because the two counts still match. Case
#     "counts match but an rsync call is unguarded" below pins that hole shut.
#
# Impact: humans bypassed with --no-verify and never noticed; AGENTS obeyed the
# hook and died. It silently killed 4 of the last 6 caroline-autonomy-improver
# runs, which found real fixes and shipped none of them.
#
# Hermetic: every case builds a synthetic git repo in $BATS_TEST_TMPDIR and runs
# the REAL hook inside it (the hook resolves its own repo root via
# `git rev-parse --show-toplevel`, so no seam has to be added to production code).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
HOOK="$HYDRA_REPO/.githooks/pre-commit"

# Emit the RSYNC_EXCLUDES array declaration every fixture needs, DERIVED from
# the hook's own required_excludes list rather than copied.
#
# An earlier version of this file hardcoded the list and got 30 of the 50
# entries. Every fixture then failed on the MISSING-EXCLUDES path, so four of
# these tests passed for a reason that had nothing to do with the rsync-count
# invariant they claim to pin. Deriving the list means a fixture can only ever
# fail on the behaviour under test, and the suite cannot drift out of lockstep
# with the hook.
emit_excludes_array() {
  echo 'RSYNC_EXCLUDES=('
  awk '/^required_excludes=\(/{f=1;next} f&&/^\)/{f=0;exit} f' "$HOOK" \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -v '^$' | grep -v '^#' \
    | sed "s/^\"\\(.*\\)\"$/  --exclude='\\1'/"
  echo ')'
}

# Build a synthetic repo whose scripts/deploy.sh body is stdin, then run the
# real hook inside it. Sets $output/$status via `run`.
make_repo_and_run() {
  local dir="$BATS_TEST_TMPDIR/repo.$$.$RANDOM"
  mkdir -p "$dir/scripts" "$dir/skills-all/demo" "$dir/.githooks"
  echo "# demo skill" > "$dir/skills-all/demo/SKILL.md"
  cp "$HOOK" "$dir/.githooks/pre-commit"
  { emit_excludes_array; cat; } > "$dir/scripts/deploy.sh"
  git -C "$dir" init -q
  git -C "$dir" config user.email t@t.t
  git -C "$dir" config user.name t
  run bash -c "cd '$dir' && bash .githooks/pre-commit 2>&1"
}

# The specific failure string check 2 emits for the count mismatch.
COUNT_MSG='must match exactly'
# What the corrected check should say when an rsync call is genuinely unguarded.
UNGUARDED_MSG='rsync'

@test "regression: the real repo's deploy.sh passes the rsync-excludes check" {
  # This is the outage. The hook must not fail on the tree as committed.
  run bash -c "cd '$HYDRA_REPO' && bash .githooks/pre-commit 2>&1"
  [[ "$output" != *"$COUNT_MSG"* ]]
  # And the whole hook must exit clean on a clean tree with nothing staged.
  [ "$status" -eq 0 ]
}

@test "continuation-line excludes and non-rsync array refs are accepted" {
  # deploy.sh's real shape: the array arrives on a continuation line, and the
  # exclude-ordering validation loop references the array without being a call.
  make_repo_and_run <<'BODY'
for cfg_rule in "${RSYNC_EXCLUDES[@]}"; do :; done
for cfg_rule in "${RSYNC_EXCLUDES[@]}"; do :; done
printf '%s\n' "${RSYNC_EXCLUDES[@]}" | grep -qFx -- '--include=x/' && :
dry_out=$(rsync -rcn --itemize-changes \
  "${RSYNC_EXCLUDES[@]}" \
  ./ /opt/hydra/)
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ /opt/hydra/
BODY
  [ "$status" -eq 0 ]
}

@test "an rsync call with no excludes array is rejected" {
  # The invariant that actually protects production: rsync --delete without the
  # excludes wipes live agent state on node-8.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ /opt/hydra/
rsync -az --delete ./ /opt/hydra/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"$UNGUARDED_MSG"* ]]
}

@test "counts match but an rsync call is unguarded: still rejected" {
  # The false-negative the old equality check let through: 2 rsync lines and 2
  # array references, so the counts agreed -- while the second rsync had none.
  make_repo_and_run <<'BODY'
for cfg_rule in "${RSYNC_EXCLUDES[@]}"; do :; done
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ /opt/hydra/
rsync -az --delete ./ /opt/hydra/
BODY
  [ "$status" -ne 0 ]
}

@test "a deploy.sh with zero rsync calls is rejected" {
  make_repo_and_run <<'BODY'
echo "no rsync here"
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"zero rsync calls"* ]]
}

@test "commented-out and heredoc rsync text does not count as a call" {
  # The preprocessor strips whole-line comments and heredoc bodies; a fixture
  # whose ONLY rsync mentions are inert must fail the >=1 requirement rather
  # than pass on prose.
  make_repo_and_run <<'BODY'
# rsync -az --delete ./ /opt/hydra/
cat <<'DOC'
rsync -az --delete ./ /opt/hydra/
DOC
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"zero rsync calls"* ]]
}

@test "prose inside a string literal is not counted as an rsync call" {
  # deploy.sh:1289's own fail() message contains "...and rsync --delete could
  # destroy it". Comment stripping cannot remove it (it is code, not a
  # comment), so a whitespace-anchored regex counted it as a 9th call and
  # then reported it as unguarded. Only command positions count.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ /opt/hydra/
fail "ordering is wrong and rsync --delete could destroy it. Restore it."
BODY
  [ "$status" -eq 0 ]
}

@test "keyword-prefixed unguarded rsync is caught (if/then/do/!/command)" {
  # QA finding on PR #869: enumerating command-position PREFIXES can never be
  # exhaustive. `if rsync ...; then` is a valid command position, so a detector
  # anchored on line-start/punctuation alone reports 1 call / 0 unguarded and
  # passes an unguarded --delete straight through.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ /opt/hydra/
if rsync -az --delete ./ /opt/hydra/; then echo ok; fi
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "every wrapper form counts as a call: then/do/!/command/exec/sudo" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ /opt/hydra/
if true; then rsync -az --delete ./ a/; fi
for x in 1; do rsync -az --delete ./ b/; done
! rsync -az --delete ./ c/
command rsync -az --delete ./ d/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"4 of 5 rsync call(s)"* ]]
}

@test "rsync inside a single-quoted string is not a call either" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ /opt/hydra/
echo 'remember that rsync --delete removes files'
BODY
  [ "$status" -eq 0 ]
}

@test "command substitution inside double quotes is code, not prose" {
  # QA finding 2 on PR #869: blank() hid executable $() bodies, so
  # out="$(rsync -az --delete ./ /opt/hydra/)" scored calls=1 unguarded=0.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ /opt/hydra/
out="$(rsync -az --delete ./ /opt/hydra/)"
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a GUARDED call inside a quoted command substitution still passes" {
  make_repo_and_run <<'BODY'
out="$(rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ /opt/hydra/)"
BODY
  [ "$status" -eq 0 ]
}

@test "backtick substitution inside double quotes is code too" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ /opt/hydra/
out="`rsync -az --delete ./ /opt/hydra/`"
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "\$() inside SINGLE quotes is literal, not a call" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ /opt/hydra/
echo 'run $(rsync -az --delete ./ x/) manually'
BODY
  [ "$status" -eq 0 ]
}

@test "two calls on ONE record: the unguarded one is still caught" {
  # QA finding 3 on PR #869: the detector counted at most one call per joined
  # record, and index(rec, guard) let a guard anywhere on that record cover
  # every match -- so a guarded call followed by `;` and an unguarded one
  # scored "1 call, guarded" and exited 0.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ guarded/; rsync -az --delete ./ /opt/hydra/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "same-record bypass via && and || is caught too" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ a/ && rsync -az --delete ./ b/
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ c/ || rsync -az --delete ./ d/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"2 of 4 rsync call(s)"* ]]
}

@test "two GUARDED calls on one record still pass" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ a/; rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ b/
BODY
  [ "$status" -eq 0 ]
}

@test "a ) inside nested quotes does not close the command substitution" {
  # QA finding 4 on PR #869: blank() decremented $() depth for every ')',
  # including one inside a nested shell-quoted string. The literal ')' below
  # dropped depth to 0, so the real second rsync was blanked as outer prose.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ guarded/
out="$(printf '%s' ')' ; rsync -az --delete ./ live/)"
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a ) inside nested DOUBLE quotes does not close it either" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ guarded/
out="$(echo "a)b" ; rsync -az --delete ./ live/)"
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "nested command substitutions track depth correctly" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ guarded/
out="$(echo "$(date)" ; rsync -az --delete ./ live/)"
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "an inline comment cannot supply the guard literal" {
  # QA finding 5a: only WHOLE-LINE comments are stripped, so a trailing
  # comment containing the array literal satisfied index(rec, guard).
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
rsync -az --delete ./ live/ # "${RSYNC_EXCLUDES[@]}"
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "two substitutions in ONE command are counted separately" {
  # QA finding 5b: a guarded first substitution covered an unguarded second,
  # because the whole segment was tested once.
  make_repo_and_run <<'BODY'
a="$(rsync -az "${RSYNC_EXCLUDES[@]}" ./ ok/)" b="$(rsync -az --delete ./ live/)"
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "quoted prose INSIDE a substitution is not a call" {
  # QA finding 5c: substitution bodies were copied verbatim, so nested quoted
  # prose mentioning rsync was matched -- recreating the false-positive that
  # blocked every commit for 11 weeks.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
out="$(echo "beware: rsync --delete removes files")"
BODY
  [ "$status" -eq 0 ]
}

@test "path-qualified invocations are seen" {
  # QA 6a: the boundary class excluded '/', so /usr/bin/rsync was invisible.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
/usr/bin/rsync -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a later command cannot supply the guard" {
  # QA 6b: a call owned all text to the next call, so a following command
  # mentioning the array made an unguarded call look guarded.
  make_repo_and_run <<'BODY'
rsync -az --delete ./ live/; printf "%s" "${RSYNC_EXCLUDES[@]}"
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 1 rsync call(s)"* ]]
}

@test "a comment directly after a separator is still a comment" {
  # QA 6b: comment detection required whitespace before '#', so ';#' slipped.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
rsync -az --delete ./ live/;# "${RSYNC_EXCLUDES[@]}"
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a backslash inside single quotes is literal, not an escape" {
  # QA 6c: treating '\' as an escape everywhere swallowed the closing quote,
  # so everything after it was read as quoted and the real call vanished.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
echo '\'; rsync -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a backtick substitution closes on its second backtick" {
  # QA 6c: backticks only ever opened, so trailing quoted prose was read as
  # code and a safe file was rejected.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
out="`printf ok` literal rsync -az --delete ./ live/"
BODY
  [ "$status" -eq 0 ]
}

@test "rsync as an ARGUMENT to another command is not a call" {
  # QA 7a (false-positive direction): matching `rsync <ws> -` anywhere counted
  # printf's argument as an invocation and blocked a safe commit.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
printf '%s\n' rsync --delete
BODY
  [ "$status" -eq 0 ]
}

@test "flags arriving via variable expansion still count as a call" {
  # QA 7a (false-negative direction): requiring a literal '-' after rsync meant
  # `rsync $opts ./ live/` was invisible.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
opts='-az --delete'; rsync $opts ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a here-string is not argv: the guard must be passed as options" {
  # QA 7b: the array as here-string input is stdin, not exclude options.
  make_repo_and_run <<'BODY'
rsync -az --delete ./ live/ <<<"${RSYNC_EXCLUDES[@]}"
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 1 rsync call(s)"* ]]
}

@test "a leading VAR=val assignment does not hide the command word" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
RSYNC_RSH=ssh rsync -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a subshell group does not hide the command word" {
  # QA 8: scan() treated only ; & | as boundaries, so cmdword() saw '(' and
  # the invocation inside the subshell was never judged.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
( rsync -az --delete ./ live/ )
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a brace group does not hide the command word" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
{ rsync -az --delete ./ live/; }
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a function definition is not mistaken for a call" {
  make_repo_and_run <<'BODY'
sync_stuff() { rsync -az --delete "${RSYNC_EXCLUDES[@]}" "$@"; }
sync_stuff ./ ok/
BODY
  [ "$status" -eq 0 ]
}

@test "a prefix assignment cannot supply the guard" {
  # QA 9a: judge() searched the whole segment, so the array named in a
  # VAR=... prefix counted even though rsync received no exclude flags.
  make_repo_and_run <<'BODY'
RSYNC_NOTE="${RSYNC_EXCLUDES[@]}" rsync -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 1 rsync call(s)"* ]]
}

@test "wrapper options do not become the command word" {
  # QA 9b: cmdword() skipped the wrapper NAME but returned its first option.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
sudo -u nobody rsync -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "env -i and time -p wrapper forms are seen" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
env -i rsync -az --delete ./ a/
time -p rsync -az --delete ./ b/
command -- rsync -az --delete ./ c/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"3 of 4 rsync call(s)"* ]]
}

@test "timeout as a wrapper is recognised" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
timeout 30 rsync -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "repeated wrapper option operands do not hide the call" {
  # QA 10: a single lookahead past one operand missed `-u X -g Y`.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
sudo -u nobody -g nogroup rsync -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a guarded call behind a multi-operand wrapper passes" {
  make_repo_and_run <<'BODY'
timeout 30 rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
BODY
  [ "$status" -eq 0 ]
}

@test "an executable heredoc body is scanned as code" {
  # QA 11: the preprocessor discarded EVERY heredoc body, including
  # deploy.sh's real `bash << 'POSTSYNC'`, so shell that actually runs on the
  # server was never judged.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
bash <<'SCRIPT'
rsync -az --delete ./ live/
SCRIPT
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a literal bash -c script is scanned as code" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
bash -c 'rsync -az --delete ./ live/'
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "an INERT heredoc body is still treated as prose" {
  # deploy.sh's briefing heredocs quote rsync flags in explanatory text; those
  # must not be read as calls or the eleven-week outage returns.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
cat <<'DOC'
rsync --delete is about to remove files from /opt/hydra/
DOC
BODY
  [ "$status" -eq 0 ]
}

@test "an interpreter heredoc with options is executable too" {
  # QA 12: the opener was only recognised when the interpreter was IMMEDIATELY
  # followed by <<, so `bash -s <<SCRIPT` was discarded as inert.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
bash -s <<'SCRIPT'
rsync -az --delete ./ live/
SCRIPT
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "an escaped quote does not truncate a -c script" {
  # QA 12: the extractor stopped at the first matching quote, so the body was
  # cut at \" and the call after it disappeared.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
bash -c "echo \"start\"; rsync -az --delete ./ live/"
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a single-quoted -c script treats backslash literally" {
  # No escape processing inside single quotes, so the closing quote is the
  # first one -- the body must not run past it.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
bash -c 'rsync -az --delete ./ live/'
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a heredoc opener inside a COMMENT does not swallow the file" {
  # QA 13a: heredoc detection ran before comment stripping, so a comment
  # merely MENTIONING a heredoc discarded every following line.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
# example: cat <<DOC
rsync -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a here-STRING is not a heredoc opener" {
  # QA 13a: <<<WORD matched the heredoc regex and swallowed the rest.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
read -r x <<<WORD
rsync -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a <<- heredoc terminates on a tab-indented marker" {
  # QA 13a: <<- strips leading tabs from the terminator; without that the
  # heredoc never closed and the rest of the file vanished.
  printf 'rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/\ncat <<-DOC\n\tinert text\n\tDOC\nrsync -az --delete ./ live/\n' > "$BATS_TEST_TMPDIR/body"
  make_repo_and_run < "$BATS_TEST_TMPDIR/body"
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a nested subshell does not close a command substitution early" {
  # QA 13b: blank() never incremented depth for a plain '(' inside $( ), so
  # the inner ')' restored the outer quote state and hid the real call.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
out="$( (echo hi); rsync -az --delete ./ live/ )"
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "an ANSI-C quoted -c script is executable shell" {
  # QA 13c: only ' and " were recognised as script delimiters, so $'...' was
  # invisible.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
bash -c $'rsync -az --delete ./ live/'
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "heredoc text inside quotes does not open heredoc state" {
  # QA 14: comments are stripped first now, but a quoted STRING containing
  # <<DOC still opened heredoc mode and swallowed the rest of the file.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
printf '%s\n' 'example: cat <<DOC'
rsync -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a real heredoc with a QUOTED marker still opens" {
  # deploy.sh:2372 is `bash << 'POSTSYNC'` -- the marker itself is quoted, so
  # the fix must not blanket-ignore quoted text near <<.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
bash << 'POSTSYNC'
rsync -az --delete ./ live/
POSTSYNC
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "an inert quoted-marker heredoc is still prose" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
cat << 'DOC'
rsync --delete is about to remove files
DOC
BODY
  [ "$status" -eq 0 ]
}

@test "a literal eval script is scanned as code" {
  # QA 15: cmdword() saw `eval` and returned, so the script it executes was
  # never inspected.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
eval 'rsync -az --delete ./ live/'
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a GUARDED literal eval script passes" {
  make_repo_and_run <<'BODY'
eval 'rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/'
BODY
  [ "$status" -eq 0 ]
}

@test "eval with a non-literal argument fails closed" {
  # The gate cannot analyse `eval "$cmd"`, so it refuses rather than passing
  # silently. deploy.sh uses no eval today, so this costs nothing.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
eval "$cmd"
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"indirection"* ]]
}

@test "find -exec rsync is seen as a call" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
find . -name x -exec rsync -az --delete ./ live/ \;
BODY
  [ "$status" -ne 0 ]
}

@test "commands after a literal eval are not discarded" {
  # QA 16: the eval rewrite printed only the eval body and advanced to the
  # next record, throwing away everything after the closing quote.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
eval "echo inspected"; rsync -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "both an eval body and its suffix are judged" {
  make_repo_and_run <<'BODY'
eval 'rsync -az --delete ./ a/'; rsync -az --delete ./ b/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"2 of 2 rsync call(s)"* ]]
}

@test "the guard after -- is an operand, not an option" {
  # QA 17: `--` ends option parsing, so the array expands as source paths and
  # excludes nothing -- but the literal was still read as proof of guarding.
  make_repo_and_run <<'BODY'
rsync -az --delete -- ./ live/ "${RSYNC_EXCLUDES[@]}"
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 1 rsync call(s)"* ]]
}

@test "the guard BEFORE -- is a real option and passes" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" -- ./ ok/
BODY
  [ "$status" -eq 0 ]
}

@test "the guard inside a command substitution does not count" {
  # The literal is an argument to the inner command, not an option to rsync.
  make_repo_and_run <<'BODY'
rsync -az --delete "$(echo "${RSYNC_EXCLUDES[@]}")" ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 1 rsync call(s)"* ]]
}

@test "interpreter options with operands do not hide -c" {
  # QA 18: the -c matcher required each preceding token to be -prefixed, so
  # `-O extglob` (an option plus its operand) made it miss -c entirely.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
bash -O extglob -c 'rsync -az --delete ./ live/'
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a guarded script behind interpreter options passes" {
  make_repo_and_run <<'BODY'
bash -O extglob -c 'rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/'
BODY
  [ "$status" -eq 0 ]
}

@test "an executable heredoc behind option operands is still scanned" {
  # QA 19a: keep_body used the same option-only recognizer the -c matcher had.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
bash -O extglob <<'SCRIPT'
rsync -az --delete ./ live/
SCRIPT
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "an interpreter named as DATA is not an execution" {
  # QA 19b: `printf '%s' bash -c '...'` is inert, but the extractor emitted the
  # quoted argument as code and rejected a safe commit -- the outage class.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
printf '%s\n' bash -c 'rsync -az --delete ./ inert/'
BODY
  [ "$status" -eq 0 ]
}

@test "eval named as DATA is not an execution either" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
printf '%s\n' eval 'rsync -az --delete ./ inert/'
BODY
  [ "$status" -eq 0 ]
}

@test "wrapper options do not hide an interpreter heredoc" {
  # QA 20: interp_cmd() returned the first wrapper OPTION as the command word,
  # so `sudo -u root bash <<SCRIPT` was classified inert. Same shape as the
  # round-9 wrapper bug in cmdword(), reintroduced in the preprocessor.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
sudo -u root bash <<'SCRIPT'
rsync -az --delete ./ live/
SCRIPT
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "wrapper options do not hide an interpreter -c script" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
sudo -u root bash -c 'rsync -az --delete ./ live/'
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a wrapped interpreter named as DATA is still inert" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
printf '%s\n' sudo -u root bash -c 'rsync -az --delete ./ inert/'
BODY
  [ "$status" -eq 0 ]
}

@test "a heredoc owned by a LATER command on the line is executable" {
  # QA 21: interp_cmd() looked only at the first command word, so a heredoc
  # attached to a second command on the same line was discarded.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
printf ready; bash <<'SCRIPT'
rsync -az --delete ./ live/
SCRIPT
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a -c script owned by a LATER command on the line is executable" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
printf ready; bash -c 'rsync -az --delete ./ live/'
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a LATER inert command keeps its heredoc inert" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
printf ready; cat <<'DOC'
rsync --delete is about to remove files
DOC
BODY
  [ "$status" -eq 0 ]
}

@test "a keyword-prefixed interpreter heredoc is executable" {
  # QA 22: interp_cmd() bailed on the keyword `if`, which cmdword() skips --
  # the third finding caused by those two scanners drifting apart.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
if bash <<'SCRIPT'
rsync -az --delete ./ live/
SCRIPT
then :; fi
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a keyword-prefixed interpreter -c script is executable" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
if bash -c 'rsync -az --delete ./ live/'; then :; fi
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "keyword and wrapper lists are shared by both scanners" {
  # Pins the anti-drift contract: one definition feeds the preprocessor and
  # the detector, so a wrapper added for one cannot go missing in the other.
  run grep -c 'HOOK_KEYWORDS\|HOOK_WRAPPERS' "$HOOK"
  [ "$status" -eq 0 ]
  [ "$output" -ge 4 ]
}

@test "a heredoc delimiter containing punctuation terminates correctly" {
  # QA 23: the marker regex accepted only [A-Za-z_][A-Za-z0-9_]*, so <<'DOC-END'
  # recorded marker DOC, never matched DOC-END, and swallowed the rest of the
  # file -- the gate silently disabling itself, as in rounds 13a and 14.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
cat <<'DOC-END'
inert prose
DOC-END
rsync -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a dotted heredoc delimiter terminates correctly" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
cat <<EOF.1
inert prose
EOF.1
rsync -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a punctuated delimiter on an EXECUTABLE heredoc is still scanned" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
bash <<'RUN-IT'
rsync -az --delete ./ live/
RUN-IT
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a double-quoted command word is still a call" {
  # QA 24: blank() erased quoted words before command-word detection, but
  # quoting a command NAME is valid shell and executes normally.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
"rsync" -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a single-quoted command word is still a call" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
'rsync' -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a GUARDED quoted command word passes" {
  make_repo_and_run <<'BODY'
"rsync" -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
BODY
  [ "$status" -eq 0 ]
}

@test "a quoted rsync as an ARGUMENT is still not a call" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
echo "rsync" --delete
BODY
  [ "$status" -eq 0 ]
}

@test "a quoted interpreter still executes its -c script" {
  # QA 25: interp_cmd() returned inert on any quoted command word -- the mirror
  # of the round-24 hole, in the preprocessor rather than the detector.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
"bash" -c 'rsync -az --delete ./ live/'
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a quoted -c option is still -c" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
bash "-c" 'rsync -az --delete ./ live/'
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a quoted interpreter heredoc is still executable" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
"bash" <<'SCRIPT'
rsync -az --delete ./ live/
SCRIPT
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "an interpreter inside a quoted STRING is still data" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
echo "run bash -c 'rsync -az --delete ./ x/' yourself"
BODY
  [ "$status" -eq 0 ]
}

@test "a leading redirection does not hide the command word" {
  # QA 26a: a redirection may precede the command in shell.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
2>/tmp/rsync.err rsync -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a separated redirection target is skipped too" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
> /tmp/out rsync -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "coproc does not hide the command word" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
coproc rsync -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "an escaped heredoc delimiter terminates correctly" {
  # QA 26b: the shell removes quoting from the delimiter word, so <<\DOC is
  # terminated by DOC. Storing \DOC meant the heredoc never closed and every
  # later command was swallowed -- the fourth instance of that class.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
cat <<\DOC
inert prose
DOC
rsync -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a redirection between argv elements does not hide the guard" {
  # QA 27c: judge() truncated argv at the first < or >, so a guard appearing
  # AFTER a redirection was invisible and a correctly guarded call was
  # REJECTED -- the commit-blocking class this PR exists to fix. My own
  # regression from round 17.
  make_repo_and_run <<'BODY'
rsync -az --delete > /tmp/log "${RSYNC_EXCLUDES[@]}" ./ ok/
BODY
  [ "$status" -eq 0 ]
}

@test "a here-string still cannot supply the guard" {
  # The round-17 invariant must survive the fix above.
  make_repo_and_run <<'BODY'
rsync -az --delete ./ live/ <<<"${RSYNC_EXCLUDES[@]}"
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 1 rsync call(s)"* ]]
}

@test "a composite-quoted command word is still a call" {
  # QA 27b: shell word concatenation -- r"syn"c runs rsync after quote removal.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
r"syn"c -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a backslash-escaped command word is still a call" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
r\sync -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a composite-quoted heredoc delimiter terminates correctly" {
  # QA 27a: <<'DO'C is terminated by DOC after quote removal.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
cat <<'DO'C
inert prose
DOC
rsync -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a non-literal interpreter script fails closed" {
  # QA 28: `bash -c "$cmd"` runs whatever $cmd holds. The preprocessor cannot
  # know that text, so the gate refuses rather than reporting green.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
cmd='rsync -az --delete ./ live/'; bash -c "$cmd"
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"indirection"* ]]
}

@test "a reviewed non-literal interpreter site is allowed by marker" {
  # deploy.sh's run_on_node8() dispatches caller-supplied commands locally or
  # over ssh; the marker records that a human judged the site.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
bash -c "$1"  # hydra-hook: reviewed-indirection (dispatcher)
BODY
  [ "$status" -eq 0 ]
}

@test "the marker does not excuse a literal unguarded call" {
  # The marker allows UNINSPECTABLE argument text; it is not a blanket bypass.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
rsync -az --delete ./ live/  # hydra-hook: reviewed-indirection
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "the reviewed marker only counts in a real comment" {
  # QA 29c: the marker was matched anywhere on the line, so printed DATA
  # containing its text suppressed the refusal. A bypass in the mechanism I
  # added in round 28.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
printf '%s\n' '# hydra-hook: reviewed-indirection'; bash -c "$cmd"
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"indirection"* ]]
}

@test "an interpreter inside a command substitution is scanned" {
  # QA 29b: $( ) executes its body, but the -c path never looked inside one.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
out="$(bash -c 'rsync -az --delete ./ live/')"
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}






@test "rsync continuation arguments are not dynamic command words" {
  # The false-positive class that produced my bad measurement.
  make_repo_and_run <<'BODY'
dry_out=$(rsync -rcn --itemize-changes \
  "${RSYNC_EXCLUDES[@]}" \
  "$HYDRA_ROOT/" "$DEPLOY_PATH/")
BODY
  [ "$status" -eq 0 ]
}

@test "a dynamic command word fails closed" {
  # QA 29a. A command word that is an expansion names its command only at run
  # time. Restricted to TRUE command boundaries (start, ; & |) so argument
  # fragments from grouping splits are not mistaken for commands.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
syncer=rsync; "$syncer" -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"indirection"* ]]
}

@test "a reviewed dynamic command word is allowed by marker" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
"$SCRIPT_DIR/validate.sh"  # hydra-hook: reviewed-indirection (repo script)
BODY
  [ "$status" -eq 0 ]
}

@test "argument fragments are not dynamic command words" {
  # The 6 false positives that made my first implementation over-fire 4x.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
case "$x" in a) echo "$plugin_name";; esac
cp "$HYDRA_ROOT/openclaw-main.json" "$dest"
BODY
  [ "$status" -eq 0 ]
}

@test "the marker in DATA does not excuse a dynamic command word" {
  # QA 30: the detector tested rawrec by substring while the preprocessor used
  # comment_text(). Same rule, two implementations, one of them wrong -- the
  # fifth finding from these scanners drifting apart.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
printf '%s\n' 'hydra-hook: reviewed-indirection'; syncer=rsync; "$syncer" -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"indirection"* ]]
}

@test "a real trailing comment still authorises a dynamic command word" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
"$SCRIPT_DIR/x.sh" arg  # hydra-hook: reviewed-indirection (repo script)
BODY
  [ "$status" -eq 0 ]
}

@test "an fd-dup redirection is not a command boundary" {
  # QA 31b: scan() split at the & in 2>&1, putting the guard in a different
  # segment and REJECTING a correctly guarded call -- the commit-blocking
  # class, from the & boundary added in round 8.
  make_repo_and_run <<'BODY'
rsync -az --delete 2>&1 "${RSYNC_EXCLUDES[@]}" ./ ok/
BODY
  [ "$status" -eq 0 ]
}

@test "background & is still a command boundary" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/ & rsync -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a command substitution as the command word fails closed" {
  # QA 31a: the dynamic check only matched $ followed by a name or brace.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
$(printf rsync) -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"indirection"* ]]
}

@test "a leading combined redirection does not hide the command" {
  # QA 32a: cmdword() skipped words starting with < or >, but not &>.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
&>/tmp/rsync.log rsync -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a leading redirection does not hide an interpreter heredoc" {
  # QA 32b: interp_cmd() had no redirection skip at all -- the same rule
  # cmdword() has had since round 26, missing from the other scanner.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
2>/tmp/bash.err bash <<'SCRIPT'
rsync -az --delete ./ live/
SCRIPT
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "redirection token pattern is shared by both scanners" {
  run grep -c 'HOOK_REDIR' "$HOOK"
  [ "$status" -eq 0 ]
  [ "$output" -ge 3 ]
}

@test "a quoted delimiter keeps its backslash" {
  # QA 33b: my round-26b fix stripped backslashes unconditionally, but bash
  # only removes quoting -- inside single quotes a backslash is literal, so
  # <<'DO\C' terminates on DO\C. Recording DOC meant the heredoc never closed.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
cat <<'DO\C'
inert prose
DO\C
rsync -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "an unquoted escaped delimiter still has quoting removed" {
  # The round-26b case must keep working: <<\DOC terminates on DOC.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
cat <<\DOC
inert prose
DOC
rsync -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a heredoc redirect before its interpreter is executable" {
  # QA 33a: the command word may FOLLOW the redirect.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
<<'SCRIPT' bash
rsync -az --delete ./ live/
SCRIPT
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "an ANSI-C script decodes its newline escapes" {
  # QA 33c: $'...\n...' runs two commands; leaving \n literal kept them in one
  # segment and hid the second.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
bash -c $'printf ready\nrsync -az --delete ./ live/'
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "builtin is an execution wrapper" {
  # QA 35a: `builtin` was absent from the shared wrapper grammar.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
builtin command rsync -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "ANSI-C hex escapes are decoded" {
  # QA 35b: bash decodes \xHH too, so \x0a really is a command separator.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
bash -c $'printf ready\x0arsync -az --delete ./ live/'
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "ANSI-C octal escapes are decoded" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
bash -c $'printf ready\012rsync -az --delete ./ live/'
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a literal interpreter here-string is executable code" {
  # QA: `bash <<< 'rsync ...'` runs the string as a script. hdpos() skips <<<
  # so it does not open a heredoc (round 13a), but nothing then scanned it.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
bash <<< 'rsync -az --delete ./ live/'
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a GUARDED interpreter here-string passes" {
  make_repo_and_run <<'BODY'
bash <<< 'rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/'
BODY
  [ "$status" -eq 0 ]
}

@test "a here-string to a NON-interpreter is still data" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
grep -q x <<< 'rsync -az --delete ./ inert/'
BODY
  [ "$status" -eq 0 ]
}

@test "a non-literal interpreter here-string fails closed" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
bash <<< "$script"
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"indirection"* ]]
}

@test "a quoted <<< does not consume the real here-string" {
  # QA: index($0,"<<<") found the token inside quoted DATA and never looked
  # further, so the executable here-string after it went unscanned.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
printf '%s\n' '<<<'; bash <<< 'rsync -az --delete ./ live/'
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a second here-string on a line is inspected" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
grep -q x <<< 'inert'; bash <<< 'rsync -az --delete ./ live/'
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a quoted <<< alone is still just data" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
printf '%s\n' '<<< rsync -az --delete ./ inert/'
BODY
  [ "$status" -eq 0 ]
}

@test "a here-string BEFORE the command word is still executable code" {
  # QA: bash accepts a redirect ahead of its command word, so the interpreter
  # sits AFTER the here-string and a prefix-only probe never saw it.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
<<< 'rsync -az --delete ./ live/' bash
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a here-string before a NON-interpreter command word is data" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
<<< 'rsync -az --delete ./ inert/' grep -q rsync
BODY
  [ "$status" -eq 0 ]
}

@test "a redirect-first here-string on a LATER command is bound to that command" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
true; <<< 'rsync -az --delete ./ live/' bash
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a backtick command word is indirection, like \$()" {
  # QA 35: judge() only treated $-led command-position words as indirection,
  # so a backtick substitution fell through as "not rsync" and the whole
  # segment was skipped in silence.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
`printf rsync` -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
}

@test "a double-quoted backtick command word is indirection" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
"`printf rsync`" -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
}

@test "a REVIEWED backtick command word passes" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
`printf echo` hello  # hydra-hook: reviewed-indirection
BODY
  [ "$status" -eq 0 ]
}

@test "a backtick in an ARGUMENT is not a command word" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ "`date +%F`"/
BODY
  [ "$status" -eq 0 ]
}

@test "an expansion INSIDE a command word is indirection" {
  # QA 36: the check only looked at the first character, but bash expands
  # r${mid}c to rsync just the same.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
mid=syn; r${mid}c -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
}

@test "a suffix expansion in a command word is indirection" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
tail=sync; r${tail} -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
}

@test "an embedded backtick in a command word is indirection" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
r`printf syn`c -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
}

@test "a REVIEWED embedded expansion passes" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
mid=ch; e${mid}o hi  # hydra-hook: reviewed-indirection
BODY
  [ "$status" -eq 0 ]
}

@test "an assignment whose value is a substitution is not a command word" {
  # The walker used to break at the space inside $( ) and read the next
  # fragment as a command word, refusing 30 correct lines of deploy.sh.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
plugin_name=$(basename "$plugin_dir")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BODY
  [ "$status" -eq 0 ]
}

@test "an expansion inside [[ ]] is not a command word" {
  # scan() splits on the || inside a test, but a test operand is not a
  # command position (deploy.sh:220).
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
needs_target() { [[ "$TARGET" == "all" || ",$TARGET," == *",$1,"* ]]; }
BODY
  [ "$status" -eq 0 ]
}

@test "an UNREVIEWED expansion after a wrapper fails closed" {
  # QA 37: past an ALWAYS-EXECUTING wrapper an option, an operand and the
  # wrapped command are indistinguishable, so the gate refuses and the
  # reviewed marker records the human judgement.
  #
  # This used `find` until QA 41 showed find is not that kind of tool: its
  # words are paths, not commands. The rule it pins is real, so the test moved
  # to a wrapper that really does execute what follows it rather than being
  # deleted along with the false positive.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
sudo -u root "$some_dir/tool" --go
BODY
  [ "$status" -ne 0 ]
}

@test "a wrapper whose TARGET is an unguarded rsync is still caught" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
sudo rsync -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
}

@test "a wrapped command word with an expansion is indirection" {
  # QA 37: skipping everything past a wrapper to spare `find "$dir"` also
  # let the WRAPPED command be dynamic.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
mid=syn; sudo r${mid}c -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
}

@test "an expansion hidden behind a wrapper OPTION is indirection" {
  # Returning at the first word past the wrapper is not enough: `-u root`
  # sits between sudo and the command it runs.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
mid=syn; sudo -u root r${mid}c -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
}

@test "a dynamic command word behind timeout is indirection" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
mid=syn; timeout 30 r${mid}c -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
}

@test "a REVIEWED wrapper operand with an expansion passes" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
n=$(find "$dir" -maxdepth 1 -type d)  # hydra-hook: reviewed-indirection
BODY
  [ "$status" -eq 0 ]
}

@test "a wrapper with no expansion anywhere still passes" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
timeout 30 gh release download v1.2.3 --dir /tmp/x
BODY
  [ "$status" -eq 0 ]
}

@test "an fd-dup before an interpreter does not hide its script" {
  # QA 38: split_cmds() broke 2>&1 into `2>` and `1 bash -c ...`, so the
  # command word read as "1" and the literal script was never inspected.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
2>&1 bash -c 'rsync -az --delete ./ live/'
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "an fd-dup before an interpreter here-string does not hide it" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
2>&1 bash <<< 'rsync -az --delete ./ live/'
BODY
  [ "$status" -ne 0 ]
}

@test "an fd-dup AFTER the interpreter does not hide its script" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
bash -c 'rsync -az --delete ./ live/' 2>&1
BODY
  [ "$status" -ne 0 ]
}

@test "an &> redirect before an interpreter does not hide its script" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
&>/tmp/log bash -c 'rsync -az --delete ./ live/'
BODY
  [ "$status" -ne 0 ]
}

@test "a real background & is still a command separator" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
sleep 1 & rsync -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a heredoc token in a TRAILING comment does not swallow the file" {
  # QA 39: only whole-line comments were stripped before hdpos(), so a
  # trailing one opened a heredoc that never closes and every later line was
  # discarded as body -- the gate silently switching itself off.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
echo safe # prose mentions <<PHANTOM
rsync -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a here-string token in a trailing comment is inert" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
echo safe # see also: bash <<< 'rsync -az --delete ./ nope/'
BODY
  [ "$status" -eq 0 ]
}

@test "a # inside a string is not a comment" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
echo "a # not a comment <<PHANTOM"
rsync -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 of 2 rsync call(s)"* ]]
}

@test "a REAL heredoc still opens after the comment strip" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
cat <<DOC
rsync -az --delete ./ prose/
DOC
BODY
  [ "$status" -eq 0 ]
}

@test "an interpreter heredoc is still executable after the comment strip" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
bash <<SCRIPT
rsync -az --delete ./ live/
SCRIPT
BODY
  [ "$status" -ne 0 ]
}

@test "a reviewed marker still works as a TRAILING comment" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
`printf echo` hi  # hydra-hook: reviewed-indirection
BODY
  [ "$status" -eq 0 ]
}

@test "ANSI-C unicode escape is a real separator" {
  # QA 40: the decoder listed only \n \t and the hex/octal spellings, so the
  # unicode spelling of the same newline hid the second command.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
bash -c $'printf ready\u000arsync -az --delete ./ live/'
BODY
  [ "$status" -ne 0 ]
}

@test "ANSI-C control-char escape is a real separator" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
bash -c $'printf ready\cJrsync -az --delete ./ live/'
BODY
  [ "$status" -ne 0 ]
}

@test "ANSI-C hex semicolon is a real separator" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
bash -c $'printf ready\x3brsync -az --delete ./ live/'
BODY
  [ "$status" -ne 0 ]
}

@test "ANSI-C octal separator is decoded" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
bash -c $'printf ready\073rsync -az --delete ./ live/'
BODY
  [ "$status" -ne 0 ]
}

@test "ANSI-C 32-bit unicode escape is a real separator" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
bash -c $'printf ready\U0000000arsync -az --delete ./ live/'
BODY
  [ "$status" -ne 0 ]
}

@test "an UNDECODABLE ANSI-C escape fails closed" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
bash -c $'printf ready\zrsync -az --delete ./ live/'
BODY
  [ "$status" -ne 0 ]
}

@test "an ANSI-C body with no separator is still one command" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
bash -c $'printf \x74ready'
BODY
  [ "$status" -eq 0 ]
}

@test "an escaped backslash is not a separator" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
bash -c $'printf a\\\\nb'
BODY
  [ "$status" -eq 0 ]
}

@test "a filename operand named rsync is not a call" {
  # QA 41: find was treated as an always-executing wrapper, so cmdword()
  # scanned past its operands and read `-name rsync` as the command --
  # rejecting a correct commit, the outage class this check exists to fix.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
find /tmp -name rsync -print
BODY
  [ "$status" -eq 0 ]
}

@test "a find PATH operand with an expansion is not indirection" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
skill_count=$(find "$profile_skills_dir" -maxdepth 1 -mindepth 1 -type d)
BODY
  [ "$status" -eq 0 ]
}

@test "find -exec rsync is still a call" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
find . -type d -exec rsync -az --delete ./ live/ {} \;
BODY
  [ "$status" -ne 0 ]
}

@test "find -execdir rsync is still a call" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
find . -type d -execdir rsync -az --delete ./ live/ {} \;
BODY
  [ "$status" -ne 0 ]
}

@test "find -ok rsync is still a call" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
find . -type d -ok rsync -az --delete ./ live/ {} \;
BODY
  [ "$status" -ne 0 ]
}

@test "find -exec bash -c is still executable shell" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
find . -type d -exec bash -c 'rsync -az --delete ./ live/' \;
BODY
  [ "$status" -ne 0 ]
}

@test "xargs rsync is still a call" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
echo x | xargs rsync -az --delete ./ live/
BODY
  [ "$status" -ne 0 ]
}

@test "a marker cannot authorise a SECOND command on the same line" {
  # QA 42: reccomment is computed per RECORD, so a marker anywhere on a line
  # suppressed cw_expands() for every segment on it.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
cmd=rsync; $cmd -az --delete ./ live/; gh release download v1  # hydra-hook: reviewed-indirection
BODY
  [ "$status" -ne 0 ]
}

@test "a marker cannot authorise a deleting dynamic command alone" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
cmd=rsync; $cmd -az --delete ./ live/  # hydra-hook: reviewed-indirection
BODY
  [ "$status" -ne 0 ]
}

@test "a marker cannot authorise the --del alias" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
cmd=rsync; $cmd -az --del ./ live/  # hydra-hook: reviewed-indirection
BODY
  [ "$status" -ne 0 ]
}

@test "a marker cannot authorise --delete-after" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
cmd=rsync; $cmd -az --delete-after ./ live/  # hydra-hook: reviewed-indirection
BODY
  [ "$status" -ne 0 ]
}

@test "a marker still authorises a NON-deleting dynamic command" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
if $HYDRA_LOCAL; then :; fi  # hydra-hook: reviewed-indirection
BODY
  [ "$status" -eq 0 ]
}

@test "a marker still authorises a script invoked by expanded path" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
"$SCRIPT_DIR/validate-shared-config.sh" || fail "drift"  # hydra-hook: reviewed-indirection
BODY
  [ "$status" -eq 0 ]
}

@test "a marker cannot authorise a deleting bash -c script" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
bash -c "$prefix --delete ./ live/"  # hydra-hook: reviewed-indirection
BODY
  [ "$status" -ne 0 ]
}

@test "a marker cannot authorise a dynamically spelled option" {
  # QA 43: only the LITERAL --del... was refused, so the flag itself could be
  # constructed at run time.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
cmd=rsync; suffix=delete; $cmd -az --$suffix ./ live/  # hydra-hook: reviewed-indirection
BODY
  [ "$status" -ne 0 ]
}

@test "a marker cannot authorise a braced dynamic option" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
cmd=rsync; s=delete; $cmd -az --${s} ./ live/  # hydra-hook: reviewed-indirection
BODY
  [ "$status" -ne 0 ]
}

@test "a marker cannot authorise a partially dynamic option" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
cmd=rsync; t=ete; $cmd -az --del$t ./ live/  # hydra-hook: reviewed-indirection
BODY
  [ "$status" -ne 0 ]
}

@test "a marker cannot authorise a dynamic option in a bash -c script" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
bash -c "rsync -az --$suffix ./ live/"  # hydra-hook: reviewed-indirection
BODY
  [ "$status" -ne 0 ]
}

@test "a marker still authorises a literal option with an expanded operand" {
  # deploy.sh really writes `--pattern "$asset"`: the OPTION is literal and
  # only its operand expands, which is not the construction being refused.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
out=$(timeout 120 gh release download "v${VER}" --pattern "$asset" --dir "$tmp")  # hydra-hook: reviewed-indirection reviewed-argv
BODY
  [ "$status" -eq 0 ]
}

@test "a marker still authorises an array operand" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
"$LINT_OPENCLAW_CFG" "${lint_targets[@]}" || fail "drift"  # hydra-hook: reviewed-indirection reviewed-argv
BODY
  [ "$status" -eq 0 ]
}

@test "a marker cannot authorise an expanded word that could be a flag" {
  # QA 43 residual: `$flags` does not begin with - so the dynamic-option rule
  # misses it, yet it expands to --delete.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
cmd=rsync; flags=--delete; $cmd -az "$flags" ./ live/  # hydra-hook: reviewed-indirection
BODY
  [ "$status" -ne 0 ]
}

@test "reviewed-argv is what authorises an expanding argv" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
"$LINT_OPENCLAW_CFG" "${lint_targets[@]}" || fail "drift"  # hydra-hook: reviewed-indirection reviewed-argv
BODY
  [ "$status" -eq 0 ]
}

@test "reviewed-argv alone does not authorise a deleting command" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
cmd=rsync; $cmd -az --delete "$dst"  # hydra-hook: reviewed-indirection reviewed-argv
BODY
  [ "$status" -ne 0 ]
}

@test "reviewed-argv alone does not authorise a dynamic option" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
cmd=rsync; s=delete; $cmd -az --$s "$dst"  # hydra-hook: reviewed-indirection reviewed-argv
BODY
  [ "$status" -ne 0 ]
}

@test "a keyword command word is not argv" {
  # The measurement that made this rule look 3x more expensive dropped the
  # command word BEFORE skipping keywords, counting $HYDRA_LOCAL as argv.
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
if $HYDRA_LOCAL; then :; fi  # hydra-hook: reviewed-indirection
BODY
  [ "$status" -eq 0 ]
}

@test "an assignment prefix is not argv" {
  make_repo_and_run <<'BODY'
rsync -az --delete "${RSYNC_EXCLUDES[@]}" ./ ok/
PROFILE=main AGENT=cmo "$SCRIPT_DIR/validate.sh" || rc=$?  # hydra-hook: reviewed-indirection
BODY
  [ "$status" -eq 0 ]
}

# Live-state protections must be REGISTERED, not just present in deploy.sh:
# the hook's check is one-directional (every required_excludes entry must be
# in RSYNC_EXCLUDES), so an exclude that protects server state but is not
# listed here can be dropped from deploy.sh without failing any commit. The
# agent-bridge request payload has two shapes on node-8 (the dotted state
# file and the un-dotted agent-named payload, 2026-09-15, #943); both must
# stay registered, or a cleanup can silently expose an open escalation to
# rsync --delete.
@test "both agent-bridge request shapes are registered in required_excludes and present in deploy.sh" {
  for pat in 'workspaces/*/.bridge-*.json' 'workspaces/*/bridge-request-*.json'; do
    run awk '/^required_excludes=\(/{f=1;next} f&&/^\)/{f=0;exit} f' "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"\"$pat\""* ]]
    run grep -Fx -- "  --exclude='$pat'" "$HYDRA_REPO/scripts/deploy.sh"
    [ "$status" -eq 0 ]
  done
}
