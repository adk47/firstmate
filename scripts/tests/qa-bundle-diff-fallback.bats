#!/usr/bin/env bats
# Tests for scripts/qa-bundle-diff-fallback.sh — the git-level recovery layer
# for files whose patch AND additions/deletions both came back zeroed from
# GitHub's REST files endpoint (Muso-AI/web-credits-next#848: 17 of 327 files
# reported additions=0/deletions=0/patch=null even though they had real
# content changes — GitHub truncating the per-PR patch payload, not a binary
# file). Every test runs against a throwaway ORIGIN + CLONE pair on disk
# (QA_BUNDLE_FALLBACK_SKIP_CLONE=1 points the script at a pre-made clone, so
# no network and no real `gh repo clone` ever runs) — memory: bats must stub
# gh/openclaw and never touch real GitHub.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/qa-bundle-diff-fallback.sh"
SKILL_MD="$HYDRA_REPO/skills-all/muso-github-code-review/SKILL.md"

# skill_candidates_filter — evaluates the ACTUAL fenced ```bash block
# documented in SKILL.md's "build your own candidate list" section, rather
# than a copy retyped into this test file. QA round 1, finding 5: a retyped
# copy stays green even if SKILL.md's own rule is reverted or drifts, which
# is exactly the case this helper exists to close — if the documented
# snippet's shape or the filter it contains ever changes, the fixture tests
# below that call it feel it immediately.
#
# Locates the ```bash ... ``` block that assigns `candidates=`, sources it
# (it only reads $bundle and sets $candidates — no side effects), then
# echoes $candidates. Fails loudly if the block cannot be found at all,
# rather than silently testing nothing.
skill_candidates_filter() { # <bundle-json>  (sets $bundle, sources the block)
  local snippet
  snippet="$(awk '
    /^  ```bash$/ { grab=1; next }
    grab && /^  ```$/ { exit }
    grab && /candidates=/ { in_block=1 }
    in_block { print }
  ' "$SKILL_MD")"
  [ -n "$snippet" ] || { echo "skill_candidates_filter: no candidates= block found in $SKILL_MD" >&2; return 1; }
  local bundle="$1" candidates
  eval "$snippet"
  printf '%s\n' "$candidates"
}

# skill_candidate_args_filter — evaluates the ACTUAL fenced ```bash block
# documented in SKILL.md right after the candidates= one, which reads
# $candidates into an array (`candidate_args`) the newline-safe way before
# ever passing it to the script. QA round 2, finding 1: the previous
# documented call site passed the bare `$candidates` string unquoted, which
# word-splits on spaces and glob-expands bracket paths before the script
# ever sees them — this helper exists so a bats test can prove the
# DOCUMENTED snippet (not a retyped copy) is safe, the same guarantee
# skill_candidates_filter gives the earlier block.
skill_candidate_args_filter() { # <candidates-string>  (sets $candidates, sources the block)
  local snippet
  snippet="$(awk '
    /^  ```bash$/ { n++; if (n==2) { grab=1; next } }
    grab && /^  ```$/ { exit }
    grab && /candidate_args=\(\)/ { in_block=1 }
    in_block && /^  bash \/opt\/hydra/ { exit }
    in_block { print }
  ' "$SKILL_MD")"
  [ -n "$snippet" ] || { echo "skill_candidate_args_filter: no candidate_args= block found in $SKILL_MD" >&2; return 1; }
  local candidates="$1" candidate_args
  eval "$snippet"
  printf '%s\n' "${candidate_args[@]}"
}

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR

  # ORIGIN: a real (non-bare is fine — nothing pushes to it after setup)
  # upstream the CLONE fetches base/head shas from by object id, exactly as
  # the script does against the real GitHub remote.
  ORIGIN="$TEST_TMPDIR/origin"; export ORIGIN
  mkdir -p "$ORIGIN"
  git -C "$ORIGIN" init -q -b main
  git -C "$ORIGIN" config user.email t@t.test
  git -C "$ORIGIN" config user.name tester
  git -C "$ORIGIN" config receive.denyCurrentBranch ignore

  # CLONE: what QA_BUNDLE_FALLBACK_WORKDIR points the script at, standing in
  # for the throwaway `gh repo clone` destination. A real `git clone` off the
  # local ORIGIN path, so `git fetch origin <sha>` inside the script behaves
  # exactly as it would against a real GitHub remote.
  CLONE="$TEST_TMPDIR/clone"; export CLONE
  git clone -q "$ORIGIN" "$CLONE"

  export QA_BUNDLE_FALLBACK_SKIP_CLONE=1
  export QA_BUNDLE_FALLBACK_WORKDIR="$CLONE"

  # No sleeps: the script's fetch retry defaults to 1 retry (2 attempts) —
  # fine for tests since a failing fetch fails fast locally, no backoff to
  # wait out.
}
teardown() { rm -rf "$TEST_TMPDIR"; }

# --- fixture helpers ---------------------------------------------------------

commitf() {  # <file> <content> <msg>  — writes+commits in ORIGIN
  local f="$1" c="$2" m="$3"
  mkdir -p "$ORIGIN/$(dirname "$f")"
  printf '%s' "$c" > "$ORIGIN/$f"
  git -C "$ORIGIN" add -- "$f"
  git -C "$ORIGIN" commit -q -m "$m"
}

commit_binary() {  # <file> <byte-count>  — writes N NUL-containing bytes, commits
  local f="$1" n="$2"
  mkdir -p "$ORIGIN/$(dirname "$f")"
  head -c "$n" /dev/urandom > "$ORIGIN/$f"
  # Ensure a NUL byte is present so git's binary heuristic is unambiguous
  # regardless of what /dev/urandom happened to produce.
  printf '\000' >> "$ORIGIN/$f"
  git -C "$ORIGIN" add -- "$f"
  git -C "$ORIGIN" commit -q -m "binary: $f"
}

tip() { git -C "$ORIGIN" rev-parse HEAD; }

fallback() {  # <base> <head> <path...>
  run "$SCRIPT" "Muso-AI/fake-repo" "$@"
}

# bats' `run` merges stdout+stderr into $output, but the script's own
# diagnostics (written to stderr on failure paths) are prose, not JSON —
# strip any line that isn't part of the JSON object before parsing, so a
# diagnostic line never breaks `jq`.
json() { echo "$output" | grep -v '^qa-bundle-diff-fallback:'; }

# --- happy path: text file recovered as a real unified diff ------------------

@test "recovers a real unified diff for a text file git can see changed" {
  commitf f.txt $'l1\nl2\n' "base"
  base="$(tip)"
  commitf f.txt $'l1\nl2 changed\nl3\n' "pr change"
  head="$(tip)"

  fallback "$base" "$head" f.txt
  [ "$status" -eq 0 ]
  [ "$(json | jq -r .cloneOk)" = "true" ]
  [ "$(json | jq -r '.stillMissing | length')" -eq 0 ]
  [ "$(json | jq -r '.recovered[0].path')" = "f.txt" ]
  [ "$(json | jq -r '.recovered[0].binary')" = "false" ]
  json | jq -r '.recovered[0].diff' | grep -q '^+l2 changed$'
  json | jq -r '.recovered[0].diff' | grep -q '^+l3$'
  json | jq -e 'has("errors") and (.errors | type == "array")' >/dev/null
}

# --- genuine binary: git itself says so, not GitHub's zeroed counters --------

@test "a genuine binary is reported binary:true with an empty diff, not stillMissing" {
  commit_binary img.png 200
  base="$(tip)"
  commit_binary img.png 210
  head="$(tip)"

  fallback "$base" "$head" img.png
  [ "$status" -eq 0 ]
  [ "$(json | jq -r '.stillMissing | length')" -eq 0 ]
  [ "$(json | jq -r '.recovered[0].path')" = "img.png" ]
  [ "$(json | jq -r '.recovered[0].binary')" = "true" ]
  [ "$(json | jq -r '.recovered[0].diff')" = "" ]
}

# --- the actual bug being fixed: a file GitHub zeroed but which git shows
#     has a real, non-trivial text change (the web-credits-next#848 shape:
#     patch=null, additions=0, deletions=0 for a file that was NOT binary) ---

@test "a large text file recovers its real patch (the #848 zeroed-stats shape)" {
  # Simulate a file GitHub's files API reported as additions=0/deletions=0/
  # patch=null despite carrying a real, sizable text change — the exact
  # failure this script exists to recover from. The script does not care
  # what GitHub reported; it only asks git.
  seq 1 400 > "$TEST_TMPDIR/big_base.txt"
  commitf big.txt "$(cat "$TEST_TMPDIR/big_base.txt")" "base big file"
  base="$(tip)"
  seq 1 400 | sed 's/^200$/two hundred, changed/' > "$TEST_TMPDIR/big_head.txt"
  commitf big.txt "$(cat "$TEST_TMPDIR/big_head.txt")" "pr big file change"
  head="$(tip)"

  fallback "$base" "$head" big.txt
  [ "$status" -eq 0 ]
  [ "$(json | jq -r '.stillMissing | length')" -eq 0 ]
  [ "$(json | jq -r '.recovered[0].binary')" = "false" ]
  json | jq -r '.recovered[0].diff' | grep -q 'two hundred, changed'
}

# --- multiple files in one call, mixed outcomes ------------------------------

@test "handles a mixed batch: text + binary + nonexistent in one call" {
  commitf a.txt $'x\n' "base a"
  commit_binary b.png 100
  base="$(tip)"
  commitf a.txt $'x\ny\n' "pr a"
  commit_binary b.png 110
  head="$(tip)"

  fallback "$base" "$head" a.txt b.png c-never-existed.txt
  [ "$status" -eq 0 ]
  [ "$(json | jq -r '.recovered | length')" -eq 2 ]
  [ "$(json | jq -r '.stillMissing | length')" -eq 1 ]
  [ "$(json | jq -r '.stillMissing[0].path')" = "c-never-existed.txt" ]
  [ "$(json | jq -r '.stillMissing[0].reason')" = "no-change" ]
  paths="$(json | jq -r '.recovered[].path' | sort | tr '\n' ' ')"
  [ "$paths" = "a.txt b.png " ]
}

# --- a pure rename (no content change) still recovers, not silently dropped -

@test "a pure rename recovers a diff, never lands in stillMissing" {
  commitf old.txt $'same\ncontent\n' "base"
  base="$(tip)"
  git -C "$ORIGIN" mv old.txt new.txt
  git -C "$ORIGIN" commit -q -m "rename only"
  head="$(tip)"

  fallback "$base" "$head" new.txt
  [ "$status" -eq 0 ]
  [ "$(json | jq -r '.stillMissing | length')" -eq 0 ]
  [ "$(json | jq -r '.recovered[0].path')" = "new.txt" ]
  json | jq -r '.recovered[0].diff' | grep -q 'same'
}

# --- fallback-fails-too: clone succeeds but the file truly did not change ---

@test "a path git says did not change lands in stillMissing with reason no-change, not fabricated clean" {
  commitf unrelated.txt $'v1\n' "base"
  base="$(tip)"
  commitf other.txt $'unrelated change\n' "touch a different file"  # unrelated.txt itself never changes again
  head="$(tip)"

  fallback "$base" "$head" unrelated.txt
  [ "$status" -eq 0 ]
  [ "$(json | jq -r '.recovered | length')" -eq 0 ]
  [ "$(json | jq -r '.stillMissing[0].path')" = "unrelated.txt" ]
  [ "$(json | jq -r '.stillMissing[0].reason')" = "no-change" ]
}

# --- clone failure: CANNOT REVIEW is preserved, never a fabricated bundle ----

@test "clone failure reports cloneOk=false, reason clone-failed, and captures gh's stderr" {
  unset QA_BUNDLE_FALLBACK_SKIP_CLONE
  export QA_BUNDLE_FALLBACK_WORKDIR="$TEST_TMPDIR/never-cloned"
  # GH points at a stub that always fails, so `gh repo clone` never succeeds —
  # proves the script degrades cleanly instead of silently reviewing nothing.
  STUBBIN="$TEST_TMPDIR/bin"; mkdir -p "$STUBBIN"
  cat > "$STUBBIN/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh-stub: simulated clone failure for $*" >&2
exit 1
STUB
  chmod +x "$STUBBIN/gh"
  PATH="$STUBBIN:$PATH" run "$SCRIPT" "Muso-AI/unreachable" \
    "0000000000000000000000000000000000000a" \
    "0000000000000000000000000000000000000b" \
    file1.txt file2.txt

  [ "$status" -eq 0 ]  # always exits 0 — the JSON carries the failure
  [ "$(json | jq -r .cloneOk)" = "false" ]
  [ "$(json | jq -r '.recovered | length')" -eq 0 ]
  [ "$(json | jq -r '.stillMissing | length')" -eq 2 ]
  [ "$(json | jq -r '.stillMissing[0].reason')" = "clone-failed" ]
  [ "$(json | jq -r '.stillMissing[1].reason')" = "clone-failed" ]
  # The clone routes through qa-gh.sh (never bare gh, SKILL.md:98), which
  # execs our stubbed gh, whose stderr must be captured into errors[] rather
  # than discarded — QA round 1, finding 1.
  json | jq -e '.errors | length > 0' >/dev/null
  json | jq -r '.errors[]' | grep -q 'simulated clone failure'
}

# --- unresolvable shas: fetch succeeds, resolve fails ------------------------

@test "an unresolvable head sha reports cloneOk=false, reason sha-unresolved, not a false positive" {
  commitf f.txt $'v1\n' "base"
  base="$(tip)"

  fallback "$base" "1111111111111111111111111111111111111a" f.txt
  [ "$status" -eq 0 ]
  [ "$(json | jq -r .cloneOk)" = "false" ]
  [ "$(json | jq -r '.stillMissing[0].path')" = "f.txt" ]
  [ "$(json | jq -r '.stillMissing[0].reason')" = "sha-unresolved" ]
}

# --- fetch retry: a transient first-attempt failure is absorbed --------------
# Regression test for QA round 1, finding 1: the card's own repro PR
# (web-credits-next#848) failed on the FIRST fetch attempt with "could not
# resolve base/head after fetch" and succeeded on an immediate manual retry.
# Simulate a `git` that fails fetch once then succeeds, and confirm the
# script's built-in retry absorbs it instead of reporting sha-unresolved.

@test "a fetch that fails once then succeeds is retried, not reported as sha-unresolved" {
  commitf f.txt $'v1\n' "base"
  base="$(tip)"
  commitf f.txt $'v2\n' "pr"
  head="$(tip)"

  STUBBIN="$TEST_TMPDIR/bin-flaky"; mkdir -p "$STUBBIN"
  REAL_GIT="$(command -v git)"
  FAIL_MARKER="$TEST_TMPDIR/fetch-failed-once"
  cat > "$STUBBIN/git" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "-C" ] && [ "\$3" = "fetch" ] && [ ! -e "$FAIL_MARKER" ]; then
  touch "$FAIL_MARKER"
  echo "fatal: simulated transient fetch failure" >&2
  exit 128
fi
exec "$REAL_GIT" "\$@"
STUB
  chmod +x "$STUBBIN/git"

  PATH="$STUBBIN:$PATH" run "$SCRIPT" "Muso-AI/fake-repo" "$base" "$head" f.txt
  [ "$status" -eq 0 ]
  [ "$(json | jq -r .cloneOk)" = "true" ]
  [ "$(json | jq -r '.stillMissing | length')" -eq 0 ]
  [ "$(json | jq -r '.recovered[0].path')" = "f.txt" ]
  # The transient failure's stderr is still surfaced, even though the retry
  # succeeded — a caller can tell a retry happened. QA round 2, finding 2:
  # `|| true` here made this assertion incapable of ever failing; dropped.
  json | jq -r '.errors[]?' | grep -q 'simulated transient fetch failure'
}

# --- per-file git failure is reported, never silently read as "unchanged" ---
# Regression test for QA round 1, finding 2: a failed on-demand blob fetch in
# a --filter=blob:none clone (rc=128, "could not fetch ... from promisor
# remote") must be distinguished from git genuinely saying "no change".

@test "a per-file git-diff failure (nonzero, non-one exit) is reported as git-diff-failed, not no-change" {
  commitf f.txt $'v1\n' "base"
  base="$(tip)"
  commitf f.txt $'v2\n' "pr"
  head="$(tip)"

  STUBBIN="$TEST_TMPDIR/bin-diff-fail"; mkdir -p "$STUBBIN"
  REAL_GIT="$(command -v git)"
  cat > "$STUBBIN/git" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "--numstat" ]; then
    echo "fatal: could not fetch abc123 from promisor remote" >&2
    exit 128
  fi
done
exec "$REAL_GIT" "\$@"
STUB
  chmod +x "$STUBBIN/git"

  PATH="$STUBBIN:$PATH" run "$SCRIPT" "Muso-AI/fake-repo" "$base" "$head" f.txt
  [ "$status" -eq 0 ]
  [ "$(json | jq -r .cloneOk)" = "true" ]
  [ "$(json | jq -r '.recovered | length')" -eq 0 ]
  [ "$(json | jq -r '.stillMissing[0].path')" = "f.txt" ]
  [ "$(json | jq -r '.stillMissing[0].reason')" = "git-diff-failed" ]
  json | jq -r '.stillMissing[0].detail' | grep -q 'promisor remote'
}

# --- glob-pathspec bug: a bracket path must not pull in another file's diff -
# Regression test for QA round 1, finding 3: without --literal-pathspecs,
# `src/app/[id]/page.tsx` is glob-matched and also pulls in
# `src/app/i/page.tsx`'s diff into the same recovered entry.

@test "a path containing glob characters is matched literally, never as a glob" {
  mkdir -p "$ORIGIN/src/app/[id]" "$ORIGIN/src/app/i"
  commitf 'src/app/[id]/page.tsx' $'v1\n' "base bracket"
  commitf 'src/app/i/page.tsx' $'v1\n' "base i"
  base="$(tip)"
  commitf 'src/app/[id]/page.tsx' $'v2 bracket changed\n' "pr bracket"
  commitf 'src/app/i/page.tsx' $'v2 i changed\n' "pr i"
  head="$(tip)"

  fallback "$base" "$head" 'src/app/[id]/page.tsx'
  [ "$status" -eq 0 ]
  [ "$(json | jq -r .cloneOk)" = "true" ]
  [ "$(json | jq -r '.recovered | length')" -eq 1 ]
  [ "$(json | jq -r '.recovered[0].path')" = "src/app/[id]/page.tsx" ]
  diff="$(json | jq -r '.recovered[0].diff')"
  echo "$diff" | grep -q 'bracket changed'
  # The bug: without --literal-pathspecs this diff ALSO contains the
  # unrelated i/page.tsx hunk. Assert it does not. QA round 2, finding 2:
  # a bare `!` before `run`/outside the last statement is a no-op under
  # bats (SC2314) — use `run !` (bats >= 1.5.0, required at the top of this
  # file), which fails the test itself if the wrapped command exits 0; no
  # extra status check needed (and checking `$status -eq 0` afterward would
  # be wrong — $status is still the wrapped grep's own nonzero exit code).
  run ! grep -q 'src/app/i/page.tsx' <<<"$diff"
  run ! grep -q 'i changed' <<<"$diff"
}

# --- documented call-site quoting: the array-read block SKILL.md now
#     documents right after `candidates=` must not word-split/glob-expand a
#     path (QA round 2, finding 1) ------------------------------------------

@test "the documented candidate_args array-read snippet survives a space and a bracket path" {
  # Two real-shaped changed files from the incident PR: one with a space in
  # its name, one with glob metacharacters. Feeding the RAW $candidates
  # newline-joined string to this snippet (not a retyped copy — see
  # skill_candidate_args_filter's own header) must produce exactly two
  # array elements, neither split nor glob-expanded.
  candidates_str=$'public/My Logo.svg\nsrc/app/[id]/page.tsx'

  mapfile_result=()
  while IFS= read -r p; do
    [ -n "$p" ] && mapfile_result+=("$p")
  done < <(skill_candidate_args_filter "$candidates_str")

  [ "${#mapfile_result[@]}" -eq 2 ]
  [ "${mapfile_result[0]}" = "public/My Logo.svg" ]
  [ "${mapfile_result[1]}" = "src/app/[id]/page.tsx" ]
}

@test "end-to-end: the documented candidate_args snippet feeds the script a space+bracket path intact" {
  mkdir -p "$ORIGIN/public" "$ORIGIN/src/app/[id]"
  commitf 'public/My Logo.svg' $'v1\n' "base logo"
  commitf 'src/app/[id]/page.tsx' $'v1\n' "base bracket"
  base="$(tip)"
  commitf 'public/My Logo.svg' $'v2 logo changed\n' "pr logo"
  commitf 'src/app/[id]/page.tsx' $'v2 bracket changed\n' "pr bracket"
  head="$(tip)"

  candidates_str=$'public/My Logo.svg\nsrc/app/[id]/page.tsx'
  candidate_args=()
  while IFS= read -r p; do
    [ -n "$p" ] && candidate_args+=("$p")
  done < <(skill_candidate_args_filter "$candidates_str")
  [ "${#candidate_args[@]}" -eq 2 ]

  run "$SCRIPT" "Muso-AI/fake-repo" "$base" "$head" "${candidate_args[@]}"
  [ "$status" -eq 0 ]
  [ "$(json | jq -r .cloneOk)" = "true" ]
  # QA round 2, finding 1 repro: the OLD (unquoted $candidates) call site
  # split 'public/My Logo.svg' into two bogus paths and glob-expanded the
  # bracket path against the runner's own cwd, so BOTH real files ended up
  # in stillMissing with reason no-change. The fix must recover both real
  # files by their real names, with nothing left missing.
  [ "$(json | jq -r '.stillMissing | length')" -eq 0 ]
  [ "$(json | jq -r '.recovered | length')" -eq 2 ]
  [ "$(json | jq -r '[.recovered[].path] | sort | join(",")')" = "public/My Logo.svg,src/app/[id]/page.tsx" ]
}

# --- usage / validation ------------------------------------------------------

@test "usage error (too few args) reports cloneOk=false with empty stillMissing" {
  run "$SCRIPT" "Muso-AI/x" "abc1234"
  [ "$status" -eq 0 ]
  [ "$(json | jq -r .cloneOk)" = "false" ]
  [ "$(json | jq -r '.stillMissing | length')" -eq 0 ]
}

@test "malformed repo argument reports cloneOk=false and preserves the path list with reason usage-error" {
  run "$SCRIPT" "not a valid repo" "0000000000000000000000000000000000000a" \
    "0000000000000000000000000000000000000b" f.txt
  [ "$status" -eq 0 ]
  [ "$(json | jq -r .cloneOk)" = "false" ]
  [ "$(json | jq -r '.stillMissing[0].path')" = "f.txt" ]
  [ "$(json | jq -r '.stillMissing[0].reason')" = "usage-error" ]
}

@test "zero paths requested is a clean, boring no-op (not an error)" {
  commitf f.txt $'v1\n' "base"
  base="$(tip)"
  commitf f.txt $'v2\n' "pr"
  head="$(tip)"

  fallback "$base" "$head"
  [ "$status" -eq 0 ]
  [ "$(json | jq -r .cloneOk)" = "true" ]
  [ "$(json | jq -r '.recovered | length')" -eq 0 ]
  [ "$(json | jq -r '.stillMissing | length')" -eq 0 ]
}

# --- output is ALWAYS one valid JSON object, exit 0, on every code path -----

@test "exit code is always 0 regardless of outcome (agent-consumed, never a hard fail)" {
  fallback "1111111111111111111111111111111111111a" \
    "2222222222222222222222222222222222222b" whatever.txt
  [ "$status" -eq 0 ]
  json | jq -e 'has("recovered") and has("stillMissing") and has("cloneOk") and has("errors")' >/dev/null
}

# --- end-to-end: a mock review-bundle with patch=null entries, extracted the
#     way the skill NOW documents (derive candidates from files[] directly,
#     not from diffDegraded.filesWithoutPatch) -------------------------------

@test "bundle fixture reproduces the real detection gap: filesWithoutPatch misses a zeroed-stats file, files[]-derived candidates do not" {
  commitf normal.txt $'n1\n' "base normal"
  commit_binary real.png 150
  commitf zeroed.txt "$(seq 1 300)" "base zeroed"
  base="$(tip)"
  commitf normal.txt $'n1\nn2\n' "pr normal"
  commit_binary real.png 160
  commitf zeroed.txt "$(seq 1 300 | sed 's/^150$/one-fifty CHANGED/')" "pr zeroed"
  head="$(tip)"

  # Mirrors the REAL muso-cli behavior (internal/cli/gh.go diffFallbackFromFiles):
  # a file only lands in diffDegraded.filesWithoutPatch when patch=="" AND
  # (additions!=0 OR deletions!=0). zeroed.txt is the web-credits-next#848
  # shape -- patch=null AND additions=0/deletions=0 -- so muso-cli classifies
  # it "binary, nothing lost" and diffDegraded.filesWithoutPatch comes back
  # EMPTY here, exactly like the real incident ("327/327 files, no
  # degradation"). real.png is genuinely binary and is ALSO absent from
  # filesWithoutPatch for the same (correct, in its case) reason.
  bundle="$(jq -n --arg h "$head" '{
    pr: {headRefOid: $h},
    files: [
      {path:"normal.txt", status:"modified", patch:"@@ ...", additions:1, deletions:0},
      {path:"real.png",   status:"modified", patch:null,     additions:0, deletions:0},
      {path:"zeroed.txt", status:"modified", patch:null,     additions:0, deletions:0},
      {path:"gone.txt",   status:"removed",  patch:null,     additions:0, deletions:5}
    ],
    diffDegraded: {filesWithoutPatch: []}
  }')"

  # Prove the gap first: the OLD approach (trusting filesWithoutPatch alone)
  # would derive zero candidates here -- the fallback would never even run,
  # and zeroed.txt's real content would stay invisible.
  old_approach_candidates="$(echo "$bundle" | jq -r '.diffDegraded.filesWithoutPatch[]')"
  [ -z "$old_approach_candidates" ]

  # The fix: derive candidates using the EXACT snippet SKILL.md documents
  # (skill_candidates_filter reads it live from the fenced ```bash block, not
  # a copy retyped here — QA round 1, finding 5: a retyped copy would stay
  # green even if SKILL.md's own rule were reverted or drifted).
  candidates_raw="$(skill_candidates_filter "$bundle")"
  candidates=()
  while IFS= read -r p; do
    [ -n "$p" ] && candidates+=("$p")
  done <<< "$candidates_raw"
  # Confirms the candidate-derivation logic itself catches what
  # filesWithoutPatch missed, AND that a removed file with patch:null is
  # excluded (QA round 2, finding 3: without this fixture entry, deleting
  # ` and .status != "removed"` from the SKILL.md filter left every existing
  # test green — gone.txt has no content left to git-diff, and including it
  # as a candidate would be a spurious stillMissing/CANNOT REVIEW).
  [ "${#candidates[@]}" -eq 2 ]
  printf '%s\n' "${candidates[@]}" | grep -qx 'gone.txt' && \
    { echo "gone.txt (status=removed) must not be a candidate" >&2; false; }

  run "$SCRIPT" "Muso-AI/fake-repo" "$base" "$head" "${candidates[@]}"
  [ "$status" -eq 0 ]
  [ "$(json | jq -r .cloneOk)" = "true" ]
  # zeroed.txt recovers a real, non-empty text diff -- this is the file the
  # bug silently dropped; real.png independently confirms binary via git.
  zeroed_diff="$(json | jq -r '.recovered[] | select(.path=="zeroed.txt") | .diff')"
  [ -n "$zeroed_diff" ]
  echo "$zeroed_diff" | grep -q 'one-fifty CHANGED'
  [ "$(json | jq -r '.recovered[] | select(.path=="real.png") | .binary')" = "true" ]
  # Nothing left unaccounted for -> the SKILL.md rule "stillMissing empty ⇒
  # no CANNOT REVIEW from this signal" applies.
  [ "$(json | jq -r '.stillMissing | length')" -eq 0 ]
}

@test "bundle fixture where the git fallback also fails: CANNOT REVIEW is preserved" {
  # Same shape as above, but the fallback is pointed at an unreachable clone
  # target (gh stub always fails) — simulating base/head no longer being
  # fetchable (force-pushed away, repo access revoked mid-review, etc).
  # The SKILL.md rule: cloneOk:false -> CANNOT REVIEW, name the files, stop.
  unset QA_BUNDLE_FALLBACK_SKIP_CLONE
  export QA_BUNDLE_FALLBACK_WORKDIR="$TEST_TMPDIR/never-cloned-2"
  STUBBIN="$TEST_TMPDIR/bin2"; mkdir -p "$STUBBIN"
  cat > "$STUBBIN/gh" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$STUBBIN/gh"

  bundle="$(jq -n '{
    files: [
      {path:"real.png",   status:"modified", patch:null, additions:0, deletions:0},
      {path:"zeroed.txt", status:"modified", patch:null, additions:0, deletions:0}
    ],
    diffDegraded: {filesWithoutPatch: []}
  }')"
  candidates_raw="$(skill_candidates_filter "$bundle")"
  candidates=()
  while IFS= read -r p; do
    [ -n "$p" ] && candidates+=("$p")
  done <<< "$candidates_raw"

  PATH="$STUBBIN:$PATH" run "$SCRIPT" "Muso-AI/fake-repo" \
    "0000000000000000000000000000000000000a" \
    "0000000000000000000000000000000000000b" \
    "${candidates[@]}"

  [ "$status" -eq 0 ]
  [ "$(json | jq -r .cloneOk)" = "false" ]
  [ "$(json | jq -r '.recovered | length')" -eq 0 ]
  # Both originally-degraded files are still unaccounted for -> caller must
  # post CANNOT REVIEW naming exactly these two, per the SKILL.md contract.
  missing="$(json | jq -r '.stillMissing[].path' | sort | tr '\n' ' ')"
  [ "$missing" = "real.png zeroed.txt " ]
  json | jq -e '[.stillMissing[].reason] | all(. == "clone-failed")' >/dev/null
}
