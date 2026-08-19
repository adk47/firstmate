#!/usr/bin/env bats
# Tests for check-attachment-status-doctrine.sh: the mechanical backstop that keeps the
# [ATTACHMENT_STATUS] honesty doctrine from regressing out of workspaces/support/SOUL.md,
# plugins/intercom/src/channel.ts (the rendered block), skills-all/muso-intercom/SKILL.md,
# and workspaces/operations/skills/muso-clickup-ticket-sweeper/SKILL.md.
#
# The doctrine under guard: the block is a POSITIVE claim about the attachments it LISTS.
# Its ABSENCE proves nothing. Eight rounds of review on PR #843 kept finding another drop
# path that minted no record while the contract promised that a missing block proved every
# attachment arrived — an unbounded promise that made Caroline assert completeness she had
# no evidence for. Withdrawing the promise is what converges; this guard is what keeps it
# withdrawn.
#
# Hermetic: runs the guard against temp COPIES via the SUPPORT_SOUL_FILE /
# INTERCOM_CHANNEL_FILE / INTERCOM_SKILL_FILE / SWEEPER_SKILL_FILE env overrides, so a
# test never edits the tracked sources.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/check-attachment-status-doctrine.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  cp "$HYDRA_REPO/workspaces/support/SOUL.md" "$TEST_TMPDIR/SOUL.md"
  cp "$HYDRA_REPO/plugins/intercom/src/channel.ts" "$TEST_TMPDIR/channel.ts"
  cp "$HYDRA_REPO/skills-all/muso-intercom/SKILL.md" "$TEST_TMPDIR/ic-skill.md"
  cp "$HYDRA_REPO/workspaces/operations/skills/muso-clickup-ticket-sweeper/SKILL.md" \
     "$TEST_TMPDIR/sweeper-skill.md"
  export SUPPORT_SOUL_FILE="$TEST_TMPDIR/SOUL.md"
  export INTERCOM_CHANNEL_FILE="$TEST_TMPDIR/channel.ts"
  export INTERCOM_SKILL_FILE="$TEST_TMPDIR/ic-skill.md"
  export SWEEPER_SKILL_FILE="$TEST_TMPDIR/sweeper-skill.md"
  cp "$HYDRA_REPO/plugins/intercom/src/attachments.ts" "$TEST_TMPDIR/attachments.ts"
  export INTERCOM_ATTACHMENTS_FILE="$TEST_TMPDIR/attachments.ts"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# strip <file> <fixed-substring> — drop every line containing the substring.
strip() {
  grep -vF -- "$2" "$1" > "$1.tmp"
  mv "$1.tmp" "$1"
}

@test "passes on the real (patched) doctrine surface" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK:"* ]]
}

# --- support SOUL.md: what Caroline is actually told ------------------------

@test "fails if SOUL stops scoping the block to the files it lists" {
  strip "$TEST_TMPDIR/SOUL.md" "positive claim about the files it LISTS and about nothing else"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL:"* ]]
}

@test "fails if SOUL drops the absence-proves-nothing rule" {
  strip "$TEST_TMPDIR/SOUL.md" "Its ABSENCE proves nothing"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "fails if SOUL drops the ban on declaring the evidence set complete" {
  strip "$TEST_TMPDIR/SOUL.md" "never tell a customer their evidence set is complete"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "fails if SOUL drops the ask-rather-than-assert rule" {
  strip "$TEST_TMPDIR/SOUL.md" "Do NOT assert it arrived, and do NOT assert it failed"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

# --- the rendered block itself (trusted region of the prompt) ---------------

@test "fails if the rendered header stops scoping itself to the listed items" {
  strip "$TEST_TMPDIR/channel.ts" "positive claim about the attachment(s) listed below and nothing else"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "fails if the rendered header drops the not-a-manifest disclaimer" {
  strip "$TEST_TMPDIR/channel.ts" "NOT a manifest of everything the customer sent"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

# --- muso-intercom SKILL.md: the helper's per-attachment manifest -----------

@test "fails if the helper doc stops saying a clean manifest is not proof of fetch" {
  strip "$TEST_TMPDIR/ic-skill.md" "is NOT proof that every attachment was fetched"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "fails if the helper doc drops the never-call-the-set-complete rule" {
  strip "$TEST_TMPDIR/ic-skill.md" "never call the set complete"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

# --- ticket-sweeper SKILL.md: the ops-side reader of the same marker -------

@test "fails if the sweeper doc drops the both-directions inference limit" {
  strip "$TEST_TMPDIR/sweeper-skill.md" "The inference fails in BOTH directions"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "fails if the sweeper doc drops the marker-absence-is-not-completeness rule" {
  strip "$TEST_TMPDIR/sweeper-skill.md" "is NOT evidence that every"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "fails if the sweeper helper reference drops its absence caveat" {
  strip "$TEST_TMPDIR/sweeper-skill.md" "its absence is not a"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

# --- the promise itself, coming back ---------------------------------------
# The require() anchors above only prove the honest wording is PRESENT. These prove the
# old completeness promise cannot be re-added alongside it — which is how it would
# actually regress: nobody deletes the caveat, someone re-adds the reassurance.

@test "fails if the SOUL phrasing of the completeness promise is reintroduced" {
  printf '\n%s\n' "No block means every attachment the customer sent came through" \
    >> "$TEST_TMPDIR/SOUL.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"absence-proves-completeness promise is back"* ]]
}

@test "fails if the rendered-header phrasing of the promise is reintroduced" {
  printf '\n%s\n' "its absence means every attachment the customer sent came through" \
    >> "$TEST_TMPDIR/channel.ts"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"absence-proves-completeness promise is back"* ]]
}

@test "fails if a code-comment phrasing of the promise is reintroduced" {
  printf '\n%s\n' "// the ABSENCE of the block PROVES every attachment came through" \
    >> "$TEST_TMPDIR/channel.ts"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"absence-proves-completeness promise is back"* ]]
}

@test "catches the promise reappearing in the skill docs, not just SOUL and code" {
  printf '\n%s\n' "PROVES every attachment arrived" >> "$TEST_TMPDIR/ic-skill.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]

  # and independently in the sweeper doc
  cp "$HYDRA_REPO/skills-all/muso-intercom/SKILL.md" "$TEST_TMPDIR/ic-skill.md"
  printf '\n%s\n' "PROVES every attachment arrived" >> "$TEST_TMPDIR/sweeper-skill.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

# --- refuse what it cannot read, never skip it -----------------------------

@test "exits 2 when a guarded file is missing rather than passing vacuously" {
  rm -f "$TEST_TMPDIR/SOUL.md"
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Missing"* ]]
}


# ---- every emitted reason must carry agent-facing guidance ------------------
@test "fails when a new UnreadableReason has no guidance in SOUL.md" {
  # Round 8 was exactly this: the code started emitting `pipeline_failed` and a
  # doc block still said `heic_decode_failed` meant "binary missing", so Ops
  # would have recommended reinstalling a binary that had just run.
  perl -0pi -e 's/\| "host_not_allowed";/| "host_not_allowed"\n  | "totally_new_reason";/' \
    "$TEST_TMPDIR/attachments.ts"
  run bash "$HYDRA_REPO/scripts/check-attachment-status-doctrine.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"totally_new_reason"* ]]
  [[ "$output" == *"SOUL.md"* ]]
}

@test "fails when a reason is documented for the agent but missing from the guidance table" {
  # The other half: present in SOUL.md, absent from channel.ts's
  # UNREADABLE_REASON_TEXT, i.e. the block would render `undefined`.
  perl -0pi -e 's/\| "host_not_allowed";/| "host_not_allowed"\n  | "half_documented";/' \
    "$TEST_TMPDIR/attachments.ts"
  printf '\n- `half_documented` -- explained for the agent here only.\n' >>"$TEST_TMPDIR/SOUL.md"
  run bash "$HYDRA_REPO/scripts/check-attachment-status-doctrine.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"channel.ts"* ]]
  [[ "$output" != *"MISSING in SOUL.md: unreadable reason 'half_documented'"* ]]
}

@test "passes on the real tree (every shipped reason is documented in both places)" {
  run bash "$HYDRA_REPO/scripts/check-attachment-status-doctrine.sh"
  [ "$status" -eq 0 ]
}

@test "exits 2 when the reason source is unreadable rather than passing vacuously" {
  export INTERCOM_ATTACHMENTS_FILE="$TEST_TMPDIR/does-not-exist.ts"
  run bash "$HYDRA_REPO/scripts/check-attachment-status-doctrine.sh"
  [ "$status" -eq 2 ]
}

# ---- the guidance-table check must read KEYS, not substrings -----------------
@test "fails when a mapping is removed but its producer reference remains" {
  # The false-green this gate shipped with: substring-matching channel.ts meant
  # `ref.reason === "host_not_allowed"` elsewhere in the file satisfied the
  # check, so the gate passed while renderAttachmentStatusBlock would index a
  # missing key. Removing ONLY the mapping is the mutation that must fail.
  perl -0pi -e 's/^  host_not_allowed:\n    "[^"]*",\n//m' "$TEST_TMPDIR/channel.ts"
  # The producer reference is still there — that is the whole point.
  grep -q 'host_not_allowed' "$TEST_TMPDIR/channel.ts"
  run bash "$HYDRA_REPO/scripts/check-attachment-status-doctrine.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a KEY of UNREADABLE_REASON_TEXT"* ]]
}

@test "fails on a STALE mapping for a reason that no longer exists" {
  # The reverse drift: a rename leaves dead guidance behind.
  perl -0pi -e 's/^const UNREADABLE_REASON_TEXT[^\n]*\n/$&  ghost_reason:\n    "left over from a rename",\n/m' \
    "$TEST_TMPDIR/channel.ts"
  run bash "$HYDRA_REPO/scripts/check-attachment-status-doctrine.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"STALE"* ]]
  [[ "$output" == *"ghost_reason"* ]]
}

@test "exits 2 when the guidance table cannot be located rather than passing" {
  perl -0pi -e 's/^const UNREADABLE_REASON_TEXT/const RENAMED_AWAY/m' "$TEST_TMPDIR/channel.ts"
  run bash "$HYDRA_REPO/scripts/check-attachment-status-doctrine.sh"
  [ "$status" -eq 2 ]
}
