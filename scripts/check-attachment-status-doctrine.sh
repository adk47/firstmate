#!/usr/bin/env bash
set -euo pipefail

# Mechanical backstop for the [ATTACHMENT_STATUS] honesty doctrine.
#
# The block tells Caroline which of a customer's attachments did NOT reach her. For
# eight rounds of review on PR #843 the contract ALSO said the opposite thing: that the
# ABSENCE of the block proved every attachment arrived. That is an unbounded promise —
# it holds only if every current AND future drop path mints a record — and rounds 3
# through 7 each found another path that did not. Eight paths were fixed; round 7 still
# found three more. So the promise was withdrawn instead:
#
#   * the block is a POSITIVE claim about the attachments it LISTS, and nothing else;
#   * its absence proves NOTHING, and never licenses "everything came through";
#   * a file the customer references that Caroline cannot see and cannot find in the
#     block is UNACCOUNTED FOR — she asks, and asserts neither delivery nor failure.
#
# Prose != enforcement. This guard fails CI if the honest wording is dropped from any of
# the four surfaces that carry it, or if the old completeness promise comes back in any
# of them. It does NOT verify runtime behaviour — the vitest suite
# (plugins/intercom/tests/attachment-dispatch.test.ts) owns the rendered block.

ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

SOUL="${SUPPORT_SOUL_FILE:-$ROOT/workspaces/support/SOUL.md}"
CHANNEL="${INTERCOM_CHANNEL_FILE:-$ROOT/plugins/intercom/src/channel.ts}"
IC_SKILL="${INTERCOM_SKILL_FILE:-$ROOT/skills-all/muso-intercom/SKILL.md}"
SWEEPER_SKILL="${SWEEPER_SKILL_FILE:-$ROOT/workspaces/operations/skills/muso-clickup-ticket-sweeper/SKILL.md}"

for f in "$SOUL" "$CHANNEL" "$IC_SKILL" "$SWEEPER_SKILL"; do
  [ -f "$f" ] || {
    echo "Missing $f (run from repo root, or set SUPPORT_SOUL_FILE / INTERCOM_CHANNEL_FILE / INTERCOM_SKILL_FILE / SWEEPER_SKILL_FILE)." >&2
    exit 2
  }
done

fail=0

# require <file> <label> <fixed-substring>
# Reports every missing anchor in one pass rather than exiting on the first.
require() {
  local file="$1" label="$2" pat="$3"
  if ! grep -qF -- "$pat" "$file" 2>/dev/null; then
    echo "FAIL: ${file#"$ROOT"/}: missing $label" >&2
    echo "      expected to still contain: \"$pat\"" >&2
    fail=1
  fi
}

# forbid <file> <label> <fixed-substring>
# The completeness promise, in the phrasings it has actually shipped in.
forbid() {
  local file="$1" label="$2" pat="$3"
  if grep -qF -- "$pat" "$file" 2>/dev/null; then
    echo "FAIL: ${file#"$ROOT"/}: the absence-proves-completeness promise is back ($label)" >&2
    echo "      must NOT contain: \"$pat\"" >&2
    fail=1
  fi
}

# --- support SOUL.md: what Caroline is actually told ------------------------
require "$SOUL" "the listed-items-only scoping of the block" \
  "positive claim about the files it LISTS and about nothing else"
require "$SOUL" "the absence-proves-nothing rule" \
  "Its ABSENCE proves nothing"
require "$SOUL" "the ban on declaring the evidence set complete" \
  "never tell a customer their evidence set is complete"
require "$SOUL" "the ask-don't-assert rule for a file she cannot see" \
  "Do NOT assert it arrived, and do NOT assert it failed"

# --- the rendered block itself (trusted region of the prompt) ---------------
require "$CHANNEL" "the listed-items-only scoping in the rendered header" \
  "positive claim about the attachment(s) listed below and nothing else"
require "$CHANNEL" "the not-a-manifest disclaimer in the rendered header" \
  "NOT a manifest of everything the customer sent"

# --- muso-intercom SKILL.md: the helper's per-attachment manifest -----------
require "$IC_SKILL" "the manifest-is-not-proof-of-fetch rule" \
  "is NOT proof that every attachment was fetched"
require "$IC_SKILL" "the never-call-the-set-complete rule" \
  "never call the set complete"

# --- ticket-sweeper SKILL.md: the ops-side reader of the same marker -------
require "$SWEEPER_SKILL" "the both-directions statement of the inference limit" \
  "The inference fails in BOTH directions"
require "$SWEEPER_SKILL" "the marker-absence-is-not-completeness rule" \
  "is NOT evidence that every"
require "$SWEEPER_SKILL" "the absence-is-not-a-completeness-basis rule on the helper reference" \
  "its absence is not a"

# --- the promise itself, in every phrasing it has shipped in ---------------
for f in "$SOUL" "$CHANNEL" "$IC_SKILL" "$SWEEPER_SKILL"; do
  forbid "$f" "SOUL.md phrasing"        "No block means every attachment the customer sent came through"
  forbid "$f" "rendered-header phrasing" "its absence means every attachment the customer sent came through"
  forbid "$f" "code-comment phrasing"    "PROVES every attachment came through"
  forbid "$f" "code-comment phrasing"    "PROVES every attachment arrived"
done

# --- every emitted reason must carry agent-facing guidance ------------------
#
# Round 8 of PR #843 was a doc drift, not a code defect: the plugin and helper
# started emitting `pipeline_failed`, one block of the sweeper skill was updated
# and a second was not, so Ops was still told `heic_decode_failed` meant "the
# binary is missing" -- and would have recommended reinstalling a binary that
# had just run. Adding a reason without documenting it everywhere it is read is
# the recurring shape, so it is checked mechanically rather than remembered.
#
# UnreadableReason is the single source of truth. Every value must appear in the
# agent doctrine (SOUL.md) and in the channel's guidance table.
ATTACHMENTS="${INTERCOM_ATTACHMENTS_FILE:-$ROOT/plugins/intercom/src/attachments.ts}"
if [ ! -f "$ATTACHMENTS" ]; then
  echo "MISSING: $ATTACHMENTS" >&2
  exit 2
fi
reasons="$(sed -n '/^export type UnreadableReason/,/;[[:space:]]*$/p' "$ATTACHMENTS" \
  | grep -oE '\| "[a-z_]+"' | grep -oE '"[a-z_]+"' | tr -d '"' | sort -u)"
if [ -z "$reasons" ]; then
  echo "MISSING: could not parse UnreadableReason from $ATTACHMENTS" >&2
  exit 2
fi
# The channel side is checked as a KEY SET, not as substrings.
#
# Substring-matching `channel.ts` was a false-green: delete a reason's mapping
# from UNREADABLE_REASON_TEXT and its PRODUCER elsewhere in the file (e.g.
# `ref.reason === "host_not_allowed"`) still satisfies the grep, so the gate
# passed while the renderer would index a missing key. (tsc catches that exact
# mutation, because the table is typed `Record<UnreadableReason, string>` — but
# a gate whose own check cannot fail is worse than no gate: it advertises a
# guarantee it does not provide.)
#
# So: extract the table's literal block and read its keys, then compare the two
# sets exactly — a missing mapping AND a stale one both fail.
table="$(sed -n '/^const UNREADABLE_REASON_TEXT/,/^};[[:space:]]*$/p' "$CHANNEL")"
if [ -z "$table" ]; then
  echo "MISSING: could not locate UNREADABLE_REASON_TEXT in $CHANNEL" >&2
  exit 2
fi
mapped="$(printf '%s\n' "$table" | grep -oE '^  [a-z_]+:' | tr -d ' :' | sort -u)"
if [ -z "$mapped" ]; then
  echo "MISSING: UNREADABLE_REASON_TEXT in $CHANNEL has no parseable keys" >&2
  exit 2
fi

for reason in $reasons; do
  # SOUL.md is prose, so a substring is the right (and only) check there.
  if ! grep -qF -- "$reason" "$SOUL"; then
    echo "MISSING in $(basename "$SOUL"): unreadable reason '$reason' has no guidance." >&2
    echo "  Every UnreadableReason must tell the agent what it means and whose problem it is." >&2
    fail=1
  fi
  if ! printf '%s\n' "$mapped" | grep -qxF -- "$reason"; then
    echo "MISSING in $(basename "$CHANNEL"): '$reason' is not a KEY of UNREADABLE_REASON_TEXT." >&2
    echo "  renderAttachmentStatusBlock would emit 'undefined' for it." >&2
    fail=1
  fi
done

# And the reverse: a mapping for a reason that no longer exists is dead guidance
# and usually the leftover of a rename.
for key in $mapped; do
  if ! printf '%s\n' "$reasons" | grep -qxF -- "$key"; then
    echo "STALE in $(basename "$CHANNEL"): UNREADABLE_REASON_TEXT maps '$key', which is not an UnreadableReason." >&2
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "[ATTACHMENT_STATUS] honesty doctrine has regressed. Restore the anchors above." >&2
  echo "Context: scripts/check-attachment-status-doctrine.sh header + PR #843 rounds 3-8." >&2
  exit 1
fi

echo "OK: [ATTACHMENT_STATUS] doctrine intact (absence proves nothing; the block claims only what it lists)."
