#!/usr/bin/env bats
# Tests for scripts/check-rebase-integrity.sh — the advisory rebase-clobber
# analyzer. Every test runs against a throwaway git repo with origin/main set
# via update-ref (RI_SKIP_FETCH=1 → no network) and PATH-shadows `gh` with a
# stub (memory: bats must stub gh/openclaw — never touch real GitHub).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/check-rebase-integrity.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  R="$TEST_TMPDIR/repo"; export R
  STATE="$TEST_TMPDIR/state"; export STATE
  mkdir -p "$R"
  git -C "$R" init -q -b main
  git -C "$R" config user.email t@t.test
  git -C "$R" config user.name tester

  # gh stub: serves STUB_TIMELINE_JSON (default: no force-push events) or
  # fails with STUB_GH_RC — the only gh call the analyzer makes is the
  # HeadRefForcePushedEvent GraphQL query.
  STUBBIN="$TEST_TMPDIR/bin"; mkdir -p "$STUBBIN"
  cat > "$STUBBIN/gh" <<'STUB'
#!/usr/bin/env bash
if [ -n "${STUB_GH_RC:-}" ] && [ "$STUB_GH_RC" != 0 ]; then exit "$STUB_GH_RC"; fi
if [ -n "${STUB_TIMELINE_JSON:-}" ]; then
  printf '%s' "$STUB_TIMELINE_JSON"
else
  printf '%s' '{"data":{"repository":{"pullRequest":{"timelineItems":{"nodes":[]}}}}}'
fi
STUB
  chmod +x "$STUBBIN/gh"
  export PATH="$STUBBIN:$PATH"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

# --- fixture helpers ---------------------------------------------------------

days_ago() {  # GNU (node-8 CI) and BSD (dev laptop) date
  if date -u -d "$1 days ago" +%FT%TZ >/dev/null 2>&1; then
    date -u -d "$1 days ago" +%FT%TZ
  else
    date -u -v-"$1"d +%FT%TZ
  fi
}

commitf() {  # <file> <content> <msg> [days-ago]
  local f="$1" c="$2" m="$3" d="${4:-}"
  mkdir -p "$R/$(dirname "$f")"
  printf '%s' "$c" > "$R/$f"
  git -C "$R" add -- "$f"
  if [ -n "$d" ]; then
    local iso; iso="$(days_ago "$d")"
    GIT_COMMITTER_DATE="$iso" GIT_AUTHOR_DATE="$iso" git -C "$R" commit -q -m "$m"
  else
    git -C "$R" commit -q -m "$m"
  fi
}

rmf() {  # <file> <msg>
  git -C "$R" rm -q -- "$1"
  git -C "$R" commit -q -m "$2"
}

set_origin_main() { git -C "$R" update-ref refs/remotes/origin/main "$1"; }
tip() { git -C "$R" rev-parse HEAD; }
lines() { awk -v n="$1" -v p="$2" 'BEGIN{for(i=1;i<=n;i++) print p " payload line " i}'; }

analyze() {  # [VAR=val ...] — runs the script on $PR_NUM/$HEAD inside $R
  ( cd "$R" && env RI_SKIP_FETCH=1 RI_STATE_DIR="$STATE" "$@" "$SCRIPT" "$PR_NUM" "$HEAD" )
}

state_file() { echo "$STATE/Muso-AI__hydra-pr-${PR_NUM}-${HEAD}.json"; }

PR_NUM=123

# --- clean baseline ----------------------------------------------------------

@test "clean PR (new file only) → exit 0, status CLEAN, no ::warning::" {
  commitf base.txt "$(lines 3 base)" "init" 30
  set_origin_main "$(tip)"
  git -C "$R" checkout -q -b pr
  commitf new.txt "$(lines 3 fresh)" "feat: add new"
  HEAD="$(tip)"

  run analyze
  [ "$status" -eq 0 ]
  [[ "$output" != *"::warning::"* ]]
  [ "$(jq -r .status "$(state_file)")" = "CLEAN" ]
}

# --- S1a stale-blob-regression -------------------------------------------------

@test "stale-blob: PR reverts file to byte-exact older version → warn names the old commit" {
  commitf f.txt "$(lines 4 v1)" "f v1" 30
  v1_short="$(git -C "$R" rev-parse --short HEAD)"
  commitf f.txt "$(lines 4 v2)" "f v2" 30
  set_origin_main "$(tip)"
  git -C "$R" checkout -q -b pr
  commitf f.txt "$(lines 4 v1)" "rework f"   # byte-identical to v1
  HEAD="$(tip)"

  run analyze
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "::warning::REBASE WARNING \[${HEAD:0:7}\] stale-blob-regression"
  echo "$output" | grep -q "$v1_short"
  [ "$(jq -r .status "$(state_file)")" = "WARN" ]
}

@test "stale-blob control: PR writes genuinely new content → silent" {
  commitf f.txt "$(lines 4 v1)" "f v1" 30
  commitf f.txt "$(lines 4 v2)" "f v2" 30
  set_origin_main "$(tip)"
  git -C "$R" checkout -q -b pr
  commitf f.txt "$(lines 4 v3)" "f v3"
  HEAD="$(tip)"

  run analyze
  [ "$status" -eq 0 ]
  [[ "$output" != *"stale-blob-regression"* ]]
  [ "$(jq -r .status "$(state_file)")" = "CLEAN" ]
}

# --- S1b erased-recent-base-work -----------------------------------------------

@test "erased-recent-base-work: PR deletes lines main gained 2 days ago → warn" {
  commitf g.txt "$(lines 2 old)" "init g" 40
  commitf g.txt "$(printf '%s\n%s' "$(lines 2 old)" "$(lines 5 recent)")" "feat: recent work" 2
  set_origin_main "$(tip)"
  git -C "$R" checkout -q -b pr
  # delete 4 of the 5 recent lines (not all 5: a full revert would also — and
  # correctly — trip stale-blob; this test isolates the line-window signal)
  commitf g.txt "$(printf '%s\n%s' "$(lines 2 old)" "recent payload line 5")" "refactor g"
  HEAD="$(tip)"

  run analyze
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '::warning::.*erased-recent-base-work'
  echo "$output" | grep -q 'feat: recent work'
  [ "$(jq -r .status "$(state_file)")" = "WARN" ]
}

@test "erased-recent-base-work control: deleted lines are older than the window → silent" {
  commitf g.txt "$(lines 2 old)" "init g" 40
  commitf g.txt "$(printf '%s\n%s' "$(lines 2 old)" "$(lines 5 stale)")" "old work" 30
  set_origin_main "$(tip)"
  git -C "$R" checkout -q -b pr
  commitf g.txt "$(printf '%s\n%s' "$(lines 2 old)" "stale payload line 5")" "refactor g"
  HEAD="$(tip)"

  run analyze
  [ "$status" -eq 0 ]
  [[ "$output" != *"erased-recent-base-work"* ]]
  [ "$(jq -r .status "$(state_file)")" = "CLEAN" ]
}

# --- S2 large-deletion ----------------------------------------------------------

@test "large-deletion: 400 deleted vs ~0 added → warn; ratio guard: 400 vs 350 added → silent" {
  commitf big.txt "$(lines 400 bulk)" "init big" 30
  set_origin_main "$(tip)"
  git -C "$R" checkout -q -b pr
  rmf big.txt "gut big"
  HEAD="$(tip)"

  run analyze
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '::warning::.*large-deletion'
  echo "$output" | grep -q 'big.txt'

  # ratio control on a second branch: same deletion, but 350 new lines added
  git -C "$R" checkout -q -b pr2 main
  rmf big.txt "gut big"
  commitf other.txt "$(lines 350 added)" "add other"
  HEAD="$(tip)"
  run analyze
  [ "$status" -eq 0 ]
  [[ "$output" != *"large-deletion"* ]]
}

@test "large-deletion thresholds are env-tunable (RI_DEL_ABS/RI_DEL_RATIO)" {
  commitf small.txt "$(lines 12 tiny)" "init small" 30
  set_origin_main "$(tip)"
  git -C "$R" checkout -q -b pr
  rmf small.txt "drop small"
  HEAD="$(tip)"

  run analyze                       # defaults: 12 < 300 → silent
  [ "$status" -eq 0 ]
  [[ "$output" != *"large-deletion"* ]]

  run analyze RI_DEL_ABS=10 RI_DEL_RATIO=1
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '::warning::.*large-deletion'
}

# --- S4 reintroduced-removed-lines ----------------------------------------------

@test "reintroduced: PR re-adds lines main removed 2 days ago (indentation differs) → warn" {
  commitf h.txt "$(printf '%s\n%s' "$(lines 2 keep)" "$(lines 4 fixed)")" "init h" 40
  commitf h.txt "$(lines 2 keep)" "fix: remove bad lines" 2
  set_origin_main "$(tip)"
  git -C "$R" checkout -q -b pr
  # re-add the removed lines with different leading whitespace — the
  # normalization must still match them
  commitf h.txt "$(printf '%s\n%s' "$(lines 2 keep)" "$(lines 4 fixed | sed 's/^/    /')")" "feat: h work"
  HEAD="$(tip)"

  run analyze
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '::warning::.*reintroduced-removed-lines'
  echo "$output" | grep -q 'fix: remove bad lines'
}

@test "reintroduced control: only 2 matched lines (< RI_INTERSECT_MIN_LINES) → silent" {
  commitf h.txt "$(printf '%s\n%s' "$(lines 2 keep)" "$(lines 2 fixed)")" "init h" 40
  commitf h.txt "$(lines 2 keep)" "fix: remove bad lines" 2
  set_origin_main "$(tip)"
  git -C "$R" checkout -q -b pr
  commitf h.txt "$(printf '%s\n%s\nextra unrelated payload here' "$(lines 2 keep)" "$(lines 2 fixed | sed 's/^/  /')")" "feat: h work"
  HEAD="$(tip)"

  run analyze
  [ "$status" -eq 0 ]
  [[ "$output" != *"reintroduced-removed-lines"* ]]
}

# --- S3 dropped-commits ----------------------------------------------------------

timeline_json() { # <before-oid>... (one node per force-push event, oldest first)
  local nodes="" oid
  for oid in "$@"; do
    nodes+="${nodes:+,}{\"beforeCommit\":{\"oid\":\"$oid\"}}"
  done
  printf '{"data":{"repository":{"pullRequest":{"timelineItems":{"nodes":[%s]}}}}}' "$nodes"
}

@test "dropped-commits: commit present pre-force-push, absent after, not on main → warn" {
  commitf base.txt "$(lines 3 base)" "init" 30
  set_origin_main "$(tip)"
  git -C "$R" checkout -q -b pr-old
  commitf x.txt "$(lines 3 xwork)" "feat: add X"
  commitf y.txt "$(lines 3 ywork)" "feat: add Y"
  before="$(tip)"
  y_sha="$(tip)"
  git -C "$R" checkout -q -b pr main
  git -C "$R" cherry-pick "$y_sha"        # Y survives the "rebase", X does not
  HEAD="$(tip)"

  STUB_TIMELINE_JSON="$(timeline_json "$before")" run analyze
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '::warning::.*dropped-commits'
  echo "$output" | grep -q 'feat: add X'
  # Y is NOT reported dropped
  dropped="$(jq -r '.signals[] | select(.id=="dropped-commits") | .commits[]' "$(state_file)")"
  [[ "$dropped" != *"feat: add Y"* ]]
  [ "$(jq -r .status "$(state_file)")" = "WARN" ]
}

@test "dropped-commits: the missing commit landed on main instead → not dropped, CLEAN" {
  commitf base.txt "$(lines 3 base)" "init" 30
  M="$(tip)"
  git -C "$R" checkout -q -b pr-old
  commitf x.txt "$(lines 3 xwork)" "feat: add X"
  x_sha="$(tip)"
  commitf y.txt "$(lines 3 ywork)" "feat: add Y"
  before="$(tip)"
  y_sha="$(tip)"
  git -C "$R" checkout -q main
  git -C "$R" cherry-pick "$x_sha"        # X merged to main
  set_origin_main "$(tip)"
  git -C "$R" checkout -q -b pr "$M"
  git -C "$R" cherry-pick "$y_sha"
  HEAD="$(tip)"

  STUB_TIMELINE_JSON="$(timeline_json "$before")" run analyze
  [ "$status" -eq 0 ]
  [[ "$output" != *"dropped-commits"* ]]
  [ "$(jq -r .status "$(state_file)")" = "CLEAN" ]
}

@test "dropped-commits: same subject survives with a different patch → info 'rewritten', CLEAN" {
  commitf base.txt "$(lines 3 base)" "init" 30
  set_origin_main "$(tip)"
  git -C "$R" checkout -q -b pr-old
  commitf x.txt "$(lines 3 xwork)" "feat: add X"
  before="$(tip)"
  git -C "$R" checkout -q -b pr main
  commitf x.txt "$(lines 3 xreworked)" "feat: add X"   # amended during rebase
  HEAD="$(tip)"

  STUB_TIMELINE_JSON="$(timeline_json "$before")" run analyze
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'rewritten-commits'
  [[ "$output" != *"::warning::"* ]]   # rewritten is info-only — no warn at all
  [ "$(jq -r .status "$(state_file)")" = "CLEAN" ]
}

@test "dropped-commits: commit dropped TWO force-pushes ago is still flagged (multi-event union)" {
  # QA #625 finding: with last-event-only analysis, a drop at force-push 1
  # followed by any further push produces a CLEAN report (the latest before/
  # after pair no longer contains the dropped commit). The union across ALL
  # events must keep flagging it.
  commitf base.txt "$(lines 3 base)" "init" 30
  set_origin_main "$(tip)"
  git -C "$R" checkout -q -b pr-v1
  commitf x.txt "$(lines 3 xwork)" "feat: add X"          # dropped at force-push 1
  commitf y.txt "$(lines 3 ywork)" "feat: add Y"
  T1="$(tip)"
  y_sha="$(tip)"
  git -C "$R" checkout -q -b pr-v2 main
  git -C "$R" cherry-pick "$y_sha"                         # v2 head: Y only
  T2="$(tip)"
  git -C "$R" checkout -q -b pr main
  git -C "$R" cherry-pick "$y_sha"
  commitf z.txt "$(lines 3 zwork)" "feat: add Z"           # push 3 = current head
  HEAD="$(tip)"

  STUB_TIMELINE_JSON="$(timeline_json "$T1" "$T2")" run analyze
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '::warning::.*dropped-commits'
  echo "$output" | grep -q 'feat: add X'
  dropped="$(jq -r '.signals[] | select(.id=="dropped-commits") | .commits[]' "$(state_file)")"
  [[ "$dropped" != *"feat: add Y"* ]]
  [[ "$dropped" != *"feat: add Z"* ]]
}

@test "dropped-commits: no force-push event (first push) → no note, no signal, exit 0" {
  commitf base.txt "$(lines 3 base)" "init" 30
  set_origin_main "$(tip)"
  git -C "$R" checkout -q -b pr
  commitf new.txt "$(lines 3 fresh)" "feat: new"
  HEAD="$(tip)"

  run analyze     # stub default: empty timeline nodes
  [ "$status" -eq 0 ]
  [[ "$output" != *"dropped-commits"* ]]
  [ "$(jq -r '.skipped | length' "$(state_file)")" -eq 0 ]
  [ "$(jq -r '.signals | length' "$(state_file)")" -eq 0 ]
}

@test "dropped-commits: gh fails → skipped note, still exit 0 with a valid report" {
  commitf base.txt "$(lines 3 base)" "init" 30
  set_origin_main "$(tip)"
  git -C "$R" checkout -q -b pr
  commitf new.txt "$(lines 3 fresh)" "feat: new"
  HEAD="$(tip)"

  STUB_GH_RC=1 run analyze
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'skipped — dropped-commits'
  jq -e '.skipped[] | select(test("gh failed"))' "$(state_file)" >/dev/null
  [ "$(jq -r .status "$(state_file)")" = "CLEAN" ]
}

@test "dropped-commits: beforeCommit unfetchable → skipped note, exit 0" {
  commitf base.txt "$(lines 3 base)" "init" 30
  set_origin_main "$(tip)"
  git -C "$R" checkout -q -b pr
  commitf new.txt "$(lines 3 fresh)" "feat: new"
  HEAD="$(tip)"

  STUB_TIMELINE_JSON="$(timeline_json "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")" run analyze
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'not fetchable'
}

# --- S5 duplicate-patch-id / already-merged --------------------------------------

@test "duplicate-patch-id: identical patch replayed twice on the PR branch → warn" {
  commitf base.txt "$(lines 3 base)" "init" 30
  set_origin_main "$(tip)"
  git -C "$R" checkout -q -b pr
  commitf dup.txt "$(lines 3 dupwork)" "feat: add dup"
  rmf dup.txt "revert dup"
  commitf dup.txt "$(lines 3 dupwork)" "feat: add dup again"   # same patch as commit 1
  HEAD="$(tip)"

  run analyze
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '::warning::.*duplicate-patch-id'
  echo "$output" | grep -q 'feat: add dup'
  [ "$(jq -r .status "$(state_file)")" = "WARN" ]
}

@test "already-merged replay → info only, status stays CLEAN" {
  commitf base.txt "$(lines 3 base)" "init" 30
  M="$(tip)"
  git -C "$R" checkout -q -b pr
  # distinct committer date: a same-second cherry-pick would otherwise create a
  # byte-identical commit object (same sha) and there'd be nothing to compare
  commitf c.txt "$(lines 3 cwork)" "feat: add C" 1
  c_sha="$(tip)"
  git -C "$R" checkout -q main
  git -C "$R" cherry-pick "$c_sha"        # C already landed on main
  set_origin_main "$(tip)"
  git -C "$R" checkout -q pr
  HEAD="$(tip)"

  run analyze
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'already-merged'
  [[ "$output" != *"::warning::"* ]]
  [ "$(jq -r .status "$(state_file)")" = "CLEAN" ]
}

# --- state file / error handling -------------------------------------------------

@test "state file: atomic write under the canonical name; empty RI_STATE_DIR ⇒ no write" {
  commitf base.txt "$(lines 3 base)" "init" 30
  set_origin_main "$(tip)"
  git -C "$R" checkout -q -b pr
  commitf new.txt "$(lines 3 fresh)" "feat: new"
  HEAD="$(tip)"

  run analyze
  [ "$status" -eq 0 ]
  [ -f "$(state_file)" ]
  # no leftover temp files from the atomic write
  [ -z "$(find "$STATE" -maxdepth 1 -name '.ri-tmp.*' 2>/dev/null)" ]

  rm -rf "$STATE"
  run analyze RI_STATE_DIR=
  [ "$status" -eq 0 ]
  [ ! -d "$STATE" ]
}

@test "internal error (unresolvable head sha) → exit 3 AND state file has status=ERROR" {
  commitf base.txt "$(lines 3 base)" "init" 30
  set_origin_main "$(tip)"
  HEAD="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

  run analyze
  [ "$status" -eq 3 ]
  [ "$(jq -r .status "$(state_file)")" = "ERROR" ]
  jq -e '.skipped[] | select(test("internal error"))' "$(state_file)" >/dev/null
}

@test "usage errors exit 2 and write no state" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  run "$SCRIPT" not-a-number abc123
  [ "$status" -eq 2 ]
  run "$SCRIPT" 1 abc123                 # short sha: state key must be 40-hex
  [ "$status" -eq 2 ]
  [ ! -d "$STATE" ]
}

@test "report is injection-safe valid JSON with hostile commit subjects" {
  commitf g.txt "$(lines 2 old)" "init g" 40
  commitf g.txt "$(printf '%s\n%s' "$(lines 2 old)" "$(lines 4 recent)")" "feat: \"quoted\" \$(touch $TEST_TMPDIR/pwned) work" 2
  set_origin_main "$(tip)"
  git -C "$R" checkout -q -b pr
  commitf g.txt "$(printf '%s\n%s' "$(lines 2 old)" "recent payload line 4")" "refactor g"
  HEAD="$(tip)"

  run analyze
  [ "$status" -eq 0 ]
  jq -e . "$(state_file)" >/dev/null                       # parses
  jq -r '.signals[].commits[]' "$(state_file)" | grep -q 'touch'   # subject captured verbatim
  [ ! -f "$TEST_TMPDIR/pwned" ]                            # and never executed
}

# --- signal digest / warn_digest (cross-head ack carryover key) ----------------
# Guard 8 in qa-pr-approve.sh carries a human's REBASE WARNING ack forward to a
# new head only when warn_digest is byte-identical. These tests pin the two
# properties that makes sound: STABLE when the flagged content is unchanged,
# and DIFFERENT whenever the flagged lines differ — including when the summary
# (which carries only a COUNT) is identical.

@test "warn_digest: empty on CLEAN, 64-hex on WARN, and every signal carries a digest" {
  commitf g.txt "$(lines 2 old)" "init g" 40
  set_origin_main "$(tip)"
  git -C "$R" checkout -q -b pr
  commitf new.txt "$(lines 3 fresh)" "feat: add new"
  HEAD="$(tip)"
  run analyze
  [ "$status" -eq 0 ]
  [ "$(jq -r '.warn_digest' "$(state_file)")" = "" ]

  git -C "$R" checkout -q main
  commitf g.txt "$(printf '%s\n%s' "$(lines 2 old)" "$(lines 5 recent)")" "feat: recent work" 2
  set_origin_main "$(tip)"
  git -C "$R" checkout -q -b pr2
  commitf g.txt "$(printf '%s\n%s' "$(lines 2 old)" "recent payload line 5")" "refactor g"
  HEAD="$(tip)"
  run analyze
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.warn_digest' "$(state_file)")" =~ ^[0-9a-f]{64}$ ]]
  [ "$(jq -r '[.signals[] | select(.digest | test("^[0-9a-f]{64}$"))] | length' "$(state_file)")" \
    = "$(jq -r '.signals | length' "$(state_file)")" ]
}

@test "warn_digest is STABLE across heads when the flagged lines are unchanged" {
  # The PR #774 case: a merge commit from main moves the head; the PR's own
  # deletions are untouched, so the human's ack still applies.
  commitf g.txt "$(lines 2 old)" "init g" 40
  commitf g.txt "$(printf '%s\n%s' "$(lines 2 old)" "$(lines 5 recent)")" "feat: recent work" 2
  set_origin_main "$(tip)"
  git -C "$R" checkout -q -b pr
  commitf g.txt "$(printf '%s\n%s' "$(lines 2 old)" "recent payload line 5")" "refactor g"
  HEAD="$(tip)"
  run analyze
  [ "$status" -eq 0 ]
  first="$(jq -r '.warn_digest' "$(state_file)")"

  # unrelated commit → new head, identical flagged line set
  commitf unrelated.txt "hello there" "chore: unrelated"
  HEAD="$(tip)"
  run analyze
  [ "$status" -eq 0 ]
  [ "$(jq -r '.warn_digest' "$(state_file)")" = "$first" ]
  [[ "$first" =~ ^[0-9a-f]{64}$ ]]   # not vacuously equal on a missing key
}

@test "warn_digest DIFFERS when different lines are erased but the count is identical" {
  # The soundness case: both heads delete exactly 4 recent lines from g.txt, so
  # summary/files/commits are byte-identical. Keying carryover on the summary
  # would inherit an ack across unrelated content; the digest must not.
  commitf g.txt "$(lines 2 old)" "init g" 40
  commitf g.txt "$(printf '%s\n%s' "$(lines 2 old)" "$(lines 8 recent)")" "feat: recent work" 2
  set_origin_main "$(tip)"
  base="$(tip)"

  git -C "$R" checkout -q -b prA
  commitf g.txt "$(printf '%s\n%s' "$(lines 2 old)" "$(lines 8 recent | sed -n '5,8p')")" "refactor g"
  HEAD="$(tip)"
  run analyze
  [ "$status" -eq 0 ]
  a_digest="$(jq -r '.warn_digest' "$(state_file)")"
  a_sum="$(jq -r '[.signals[] | select(.id=="erased-recent-base-work") | .summary] | .[0]' "$(state_file)")"

  git -C "$R" checkout -q "$base"
  git -C "$R" checkout -q -b prB
  commitf g.txt "$(printf '%s\n%s' "$(lines 2 old)" "$(lines 8 recent | sed -n '1,4p')")" "refactor g"
  HEAD="$(tip)"
  run analyze
  [ "$status" -eq 0 ]
  b_digest="$(jq -r '.warn_digest' "$(state_file)")"
  b_sum="$(jq -r '[.signals[] | select(.id=="erased-recent-base-work") | .summary] | .[0]' "$(state_file)")"

  [ "$a_sum" = "$b_sum" ]            # identical summary — the ambiguity being closed
  [ "$a_digest" != "$b_digest" ]     # …but distinct digests
}

@test "warn_digest DIFFERS for equal-volume large-deletion of different content" {
  # Same soundness property as the test above, for the OTHER line-window signal.
  # large-deletion's summary carries only totals and `files` only the top-10 by
  # volume, so two heads deleting different 15-line bodies from the same file
  # render byte-identically; only a content-derived identity separates them.
  # Base is 40d old so erased-recent-base-work (14d window) cannot also fire and
  # supply the difference for us.
  commitf big.txt "$(lines 40 body)" "init big" 40
  set_origin_main "$(tip)"
  base="$(tip)"

  git -C "$R" checkout -q -b prA
  commitf big.txt "$(lines 40 body | sed -n '1,10p;26,40p')" "trim middle"
  HEAD="$(tip)"
  run analyze RI_DEL_ABS=10 RI_DEL_RATIO=2
  [ "$status" -eq 0 ]
  a_digest="$(jq -r '.warn_digest' "$(state_file)")"
  a_sum="$(jq -r '[.signals[] | select(.id=="large-deletion") | .summary] | .[0]' "$(state_file)")"
  a_files="$(jq -rc '[.signals[] | select(.id=="large-deletion") | .files] | .[0]' "$(state_file)")"
  # the signal must remain CARRYABLE — a fix that merely voided it would pass a
  # "digests differ" assertion while silently disabling the feature
  [ "$(jq -r '[.signals[] | select(.id=="large-deletion") | .carryable] | .[0]' "$(state_file)")" = true ]

  git -C "$R" checkout -q "$base"
  git -C "$R" checkout -q -b prB
  commitf big.txt "$(lines 40 body | sed -n '1,20p;36,40p')" "trim middle"
  HEAD="$(tip)"
  run analyze RI_DEL_ABS=10 RI_DEL_RATIO=2
  [ "$status" -eq 0 ]
  b_digest="$(jq -r '.warn_digest' "$(state_file)")"
  b_sum="$(jq -r '[.signals[] | select(.id=="large-deletion") | .summary] | .[0]' "$(state_file)")"
  b_files="$(jq -rc '[.signals[] | select(.id=="large-deletion") | .files] | .[0]' "$(state_file)")"

  [ "$a_sum" = "$b_sum" ]            # identical totals…
  [ "$a_files" = "$b_files" ]        # …and identical file list
  [[ "$a_digest" =~ ^[0-9a-f]{64}$ ]]
  [ "$a_digest" != "$b_digest" ]     # …but distinct digests
}

# dup_blocks <marker-a> <marker-b> [omit] — a file holding the SAME three
# payload lines in two blocks, each with distinct surrounding context. `omit`
# selects which block's payload is left out (a|b|both|none). normalize_lines
# sorts and dedups, so both blocks reduce to one identical 3-line set: only raw
# position and context can tell "deleted block A" from "deleted block B".
# `case` (not `[ ] ||`) so the helper's exit status is 0 on every branch.
dup_blocks() {
  local omit="${3:-none}" payload='shared payload line 1\nshared payload line 2\nshared payload line 3\n'
  printf 'lead filler line one\nlead filler line two\nlead filler line three\n'
  printf '%s\n' "$1"
  case "$omit" in a|both) ;; *) printf "$payload" ;; esac
  printf 'mid filler line one\nmid filler line two\nmid filler line three\n'
  printf 'mid filler line four\nmid filler line five\nmid filler line six\n'
  printf '%s\n' "$2"
  case "$omit" in b|both) ;; *) printf "$payload" ;; esac
  printf 'tail filler line one\ntail filler line two\ntail filler line three'
}

@test "erased digest DIFFERS for identical text deleted at two different locations" {
  # The set-vs-sequence hole: `$WORK/erased` comes from normalize_lines, which
  # sort -u's, so it carries neither multiplicity nor location. Both heads erase
  # the same three normalized lines from the same file — identical count,
  # summary, files and erased set. Only the hunk context separates them.
  commitf d.txt "$(printf 'lead filler line one\nlead filler line two\nlead filler line three')" "init d" 40
  commitf d.txt "$(dup_blocks 'alpha marker aaa' 'gamma marker bbb')" "feat: recent work" 2
  set_origin_main "$(tip)"
  base="$(tip)"

  git -C "$R" checkout -q -b prA
  commitf d.txt "$(dup_blocks 'alpha marker aaa' 'gamma marker bbb' a)" "drop a block"
  HEAD="$(tip)"
  run analyze
  [ "$status" -eq 0 ]
  a_digest="$(jq -r '.warn_digest' "$(state_file)")"
  a_sum="$(jq -r '[.signals[] | select(.id=="erased-recent-base-work") | .summary] | .[0]' "$(state_file)")"

  git -C "$R" checkout -q "$base"
  git -C "$R" checkout -q -b prB
  commitf d.txt "$(dup_blocks 'alpha marker aaa' 'gamma marker bbb' b)" "drop a block"
  HEAD="$(tip)"
  run analyze
  [ "$status" -eq 0 ]
  b_digest="$(jq -r '.warn_digest' "$(state_file)")"
  b_sum="$(jq -r '[.signals[] | select(.id=="erased-recent-base-work") | .summary] | .[0]' "$(state_file)")"

  [ "$a_sum" = "$b_sum" ]            # same count, same file — indistinguishable by summary
  [[ "$a_digest" =~ ^[0-9a-f]{64}$ ]]
  [[ "$b_digest" =~ ^[0-9a-f]{64}$ ]]
  [ "$a_digest" != "$b_digest" ]
}

@test "reintroduced digest DIFFERS for identical text re-added at two locations" {
  # Symmetric hole on the + side: re-adding the same text somewhere else is a
  # different finding, and the deduped set cannot express that.
  commitf d.txt "$(dup_blocks 'alpha marker aaa' 'gamma marker bbb')" "init d" 40
  commitf d.txt "$(dup_blocks 'alpha marker aaa' 'gamma marker bbb' both)" "chore: strip both blocks" 2
  set_origin_main "$(tip)"
  base="$(tip)"

  git -C "$R" checkout -q -b prA
  commitf d.txt "$(dup_blocks 'alpha marker aaa' 'gamma marker bbb' b)" "restore a block"
  HEAD="$(tip)"
  run analyze
  [ "$status" -eq 0 ]
  a_digest="$(jq -r '.warn_digest' "$(state_file)")"
  a_sum="$(jq -r '[.signals[] | select(.id=="reintroduced-removed-lines") | .summary] | .[0]' "$(state_file)")"

  git -C "$R" checkout -q "$base"
  git -C "$R" checkout -q -b prB
  commitf d.txt "$(dup_blocks 'alpha marker aaa' 'gamma marker bbb' a)" "restore a block"
  HEAD="$(tip)"
  run analyze
  [ "$status" -eq 0 ]
  b_digest="$(jq -r '.warn_digest' "$(state_file)")"
  b_sum="$(jq -r '[.signals[] | select(.id=="reintroduced-removed-lines") | .summary] | .[0]' "$(state_file)")"

  [ "$a_sum" = "$b_sum" ]
  [[ "$a_digest" =~ ^[0-9a-f]{64}$ ]]
  [ "$a_digest" != "$b_digest" ]
}

# twin_blocks [omit] — two payload blocks whose surrounding context is BYTE-
# IDENTICAL on both sides, so a -U3 hunk for either one renders the same text.
# Context cannot separate these; only the occurrence ordinal can.
twin_blocks() {
  local omit="${1:-none}"
  local ctx_before='ctx alpha line here\nctx beta line here\nctx gamma line here\n'
  local ctx_after='ctx delta line here\nctx epsilon line here\nctx zeta line here\n'
  local payload='shared payload line 1\nshared payload line 2\nshared payload line 3\n'
  printf 'pad line number one\n'
  printf "$ctx_before"; case "$omit" in a) ;; *) printf "$payload" ;; esac; printf "$ctx_after"
  printf 'pad line number two\n'
  printf "$ctx_before"; case "$omit" in b) ;; *) printf "$payload" ;; esac; printf "$ctx_after"
  printf 'pad line number three'
}

@test "erased digest DIFFERS for duplicate blocks with IDENTICAL context" {
  # Stripping @@ numbers made context the only locator, and context is not enough:
  # two byte-identical blocks with byte-identical surroundings emit the same hunk
  # body. The occurrence ordinal (how many identical slices precede this one in
  # the merge-base image) is what separates them.
  commitf t.txt "$(printf 'pad line number one\npad line number two\npad line number three')" "init t" 40
  commitf t.txt "$(twin_blocks)" "feat: recent work" 2
  set_origin_main "$(tip)"
  base="$(tip)"

  git -C "$R" checkout -q -b prA
  commitf t.txt "$(twin_blocks a)" "drop one block"
  HEAD="$(tip)"
  run analyze
  [ "$status" -eq 0 ]
  a_digest="$(jq -r '.warn_digest' "$(state_file)")"
  a_sum="$(jq -r '[.signals[] | select(.id=="erased-recent-base-work") | .summary] | .[0]' "$(state_file)")"

  git -C "$R" checkout -q "$base"
  git -C "$R" checkout -q -b prB
  commitf t.txt "$(twin_blocks b)" "drop one block"
  HEAD="$(tip)"
  run analyze
  [ "$status" -eq 0 ]
  b_digest="$(jq -r '.warn_digest' "$(state_file)")"
  b_sum="$(jq -r '[.signals[] | select(.id=="erased-recent-base-work") | .summary] | .[0]' "$(state_file)")"

  [ "$a_sum" = "$b_sum" ]            # identical summary…
  [[ "$a_digest" =~ ^[0-9a-f]{64}$ ]]
  [[ "$b_digest" =~ ^[0-9a-f]{64}$ ]]
  [ "$a_digest" != "$b_digest" ]     # …and now identical context too, still distinct
}

@test "occurrence ordinal survives an unrelated edit above the finding" {
  # The reason the ordinal is used instead of the raw @@ line number: prepending
  # unrelated lines shifts every absolute position but must NOT change the digest,
  # or the ack never carries and the whole feature is inert.
  commitf t.txt "$(printf 'pad line number one\npad line number two\npad line number three')" "init t" 40
  commitf t.txt "$(twin_blocks)" "feat: recent work" 2
  set_origin_main "$(tip)"
  base="$(tip)"

  git -C "$R" checkout -q -b prA
  commitf t.txt "$(twin_blocks b)" "drop one block"
  HEAD="$(tip)"
  run analyze
  [ "$status" -eq 0 ]
  plain="$(jq -r '.warn_digest' "$(state_file)")"

  # same erasure, but main has since prepended unrelated lines to the same file
  git -C "$R" checkout -q main
  commitf t.txt "$(printf 'brand new header line\nanother header line\n%s' "$(twin_blocks)")" "feat: header" 1
  set_origin_main "$(tip)"
  git -C "$R" checkout -q -b prC
  commitf t.txt "$(printf 'brand new header line\nanother header line\n%s' "$(twin_blocks b)")" "drop one block"
  HEAD="$(tip)"
  run analyze
  [ "$status" -eq 0 ]
  shifted="$(jq -r '.warn_digest' "$(state_file)")"

  [[ "$plain" =~ ^[0-9a-f]{64}$ ]]
  [ "$plain" = "$shifted" ]          # absolute lines moved; the finding did not
}

# twin_bulk [omit] — two BYTE-IDENTICAL 12-line blocks (identical context too),
# large enough to trip large-deletion on its own. Same collision shape as
# twin_blocks, sized for the volume signal rather than the line-window ones.
twin_bulk() {
  local omit="${1:-none}" ctx_b='ctx alpha line here\nctx beta line here\nctx gamma line here\n'
  local ctx_a='ctx delta line here\nctx epsilon line here\nctx zeta line here\n'
  printf 'pad line number one\n'
  printf "$ctx_b"; case "$omit" in a|both) ;; *) lines 12 bulk ;; esac; printf "$ctx_a"
  printf 'pad line number two\n'
  printf "$ctx_b"; case "$omit" in b|both) ;; *) lines 12 bulk ;; esac; printf "$ctx_a"
  printf 'pad line number three'
}

@test "large-deletion digest DIFFERS for identical duplicate blocks at two locations" {
  # large-deletion's identity was a flat projection of deleted lines, so deleting
  # either of two byte-identical blocks (with identical context) from one file
  # produced the same digest. Routing it through hunks_containing --all gives each
  # hunk the occurrence ordinal, which is what separates them. Base is 40d old so
  # erased-recent-base-work cannot fire and supply the difference instead.
  commitf b.txt "$(twin_bulk)" "init b" 40
  set_origin_main "$(tip)"
  base="$(tip)"

  git -C "$R" checkout -q -b prA
  commitf b.txt "$(twin_bulk a)" "drop a bulk block"
  HEAD="$(tip)"
  run analyze RI_DEL_ABS=10 RI_DEL_RATIO=2
  [ "$status" -eq 0 ]
  a_digest="$(jq -r '.warn_digest' "$(state_file)")"
  a_sum="$(jq -r '[.signals[] | select(.id=="large-deletion") | .summary] | .[0]' "$(state_file)")"
  [ "$(jq -r '[.signals[] | select(.id=="large-deletion") | .carryable] | .[0]' "$(state_file)")" = true ]

  git -C "$R" checkout -q "$base"
  git -C "$R" checkout -q -b prB
  commitf b.txt "$(twin_bulk b)" "drop a bulk block"
  HEAD="$(tip)"
  run analyze RI_DEL_ABS=10 RI_DEL_RATIO=2
  [ "$status" -eq 0 ]
  b_digest="$(jq -r '.warn_digest' "$(state_file)")"
  b_sum="$(jq -r '[.signals[] | select(.id=="large-deletion") | .summary] | .[0]' "$(state_file)")"

  [ "$a_sum" = "$b_sum" ]            # identical totals and file — summary cannot separate
  [[ "$a_digest" =~ ^[0-9a-f]{64}$ ]]
  [ "$a_digest" != "$b_digest" ]
}

@test "a warn signal with no content identity is non-carryable and voids warn_digest" {
  # Fail-closed default. stale-blob-regression passes no identity, so its
  # id+files+commits+summary fallback is not provably content-sensitive; rather
  # than hash it into the rollup, the whole report becomes non-carryable and
  # Guard 8's 64-hex test rejects the empty value. This is what stops a FUTURE
  # signal author from silently reintroducing the large-deletion hole.
  commitf f.txt "$(lines 4 v1)" "f v1" 30
  commitf f.txt "$(lines 4 v2)" "f v2" 30
  set_origin_main "$(tip)"
  git -C "$R" checkout -q -b pr
  commitf f.txt "$(lines 4 v1)" "rework f"   # byte-identical to v1
  HEAD="$(tip)"

  run analyze
  [ "$status" -eq 0 ]
  [ "$(jq -r .status "$(state_file)")" = "WARN" ]                    # it still reports…
  [ "$(jq -r '[.signals[] | select(.id=="stale-blob-regression") | .carryable] | .[0]' \
      "$(state_file)")" = false ]
  [ "$(jq -r '.warn_digest' "$(state_file)")" = "" ]                 # …but cannot carry an ack
}
