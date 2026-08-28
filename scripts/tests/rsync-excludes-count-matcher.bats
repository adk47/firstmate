#!/usr/bin/env bats
# pr-validate's deploy pre-flight sanity-checks that it extracted RSYNC_EXCLUDES
# correctly, comparing eval'd entries against the number DECLARED in deploy.sh's
# array block. The intent -- "did the sed range or the array format change?" --
# is a real and useful guard.
#
# Its matcher was UNANCHORED, so it counted any line MENTIONING a flag, comments
# included. A comment that named the flag it was explaining therefore inflated
# `declared` by one and failed the gate with "the sed range or array format
# likely changed" -- pointing at the format when the format was fine. That cost
# a CI round on PR #881, and the message sends the next person to the wrong place.
#
# Deliberately NOT extracting-and-eval'ing the workflow's expression: a fragile
# parser here would be its own false-green. These are textual assertions about
# the workflow plus arithmetic on fixtures.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
WORKFLOW="$HYDRA_REPO/.github/workflows/pr-validate.yml"
DEPLOY="$HYDRA_REPO/scripts/deploy.sh"

ANCHORED='^[[:space:]]*--(exclude|include)='
UNANCHORED='--(exclude|include)='

# A block shaped exactly like the one that broke #881: an explanatory comment
# inside the array that names the flag it describes.
mk_block() {
  cat > "$1" <<'EOF'
RSYNC_EXCLUDES=(
  # this pair must come before the unanchored --exclude='config/' below
  --include='a/config/'
  --include='a/config/**'
  --exclude='config/'
)
EOF
}

@test "the workflow's declared= counter is ANCHORED to line starts" {
  line="$(grep -E '^ *declared=.*grep -cE' "$WORKFLOW")"
  [ -n "$line" ]
  [[ "$line" == *'^[[:space:]]*--'* ]]
}

@test "anchored counts only real entries in a block with a flag-naming comment" {
  b="$BATS_TEST_TMPDIR/b.sh"; mk_block "$b"
  n="$(sed -n '/^RSYNC_EXCLUDES=(/,/^)$/p' "$b" | grep -cE "$ANCHORED")"
  [ "$n" -eq 3 ]
}

@test "unanchored miscounts that same block — the bug, pinned" {
  # Non-vacuity: proves the fixture actually exercises the difference.
  b="$BATS_TEST_TMPDIR/b.sh"; mk_block "$b"
  n="$(sed -n '/^RSYNC_EXCLUDES=(/,/^)$/p' "$b" | grep -cE -- "$UNANCHORED")"
  [ "$n" -eq 4 ]
}

@test "anchoring does not UNDER-count the live deploy.sh array" {
  # The guard must keep doing its job. Compare against a structurally
  # independent count: non-comment lines carrying a flag.
  a="$(sed -n '/^RSYNC_EXCLUDES=(/,/^)$/p' "$DEPLOY" | grep -cE "$ANCHORED")"
  b="$(sed -n '/^RSYNC_EXCLUDES=(/,/^)$/p' "$DEPLOY" | grep -vE '^[[:space:]]*#' | grep -cE -- "$UNANCHORED")"
  [ "$a" -eq "$b" ]
  [ "$a" -ge 15 ]
}
