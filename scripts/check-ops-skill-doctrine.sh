#!/usr/bin/env bash
set -euo pipefail

# Mechanical backstop for the @Ops skill safety clauses #1047 silently deleted.
#
# PR #1047 deleted 7 safety clauses from two @Ops skills (customer-data-resolution
# and subscription-refund-reconciliation) and every CI gate stayed green. MUS-1796
# (#1050) restored the prose. QA proved by mutation at 77e16dca that restoring the
# text alone fixes nothing: deleting the entire Profile-merge safety rule from
# customer-data-resolution/SKILL.md again leaves all plausible gates green.
#
# SCOPE MAP -- which gates can fail on a diff under workspaces/operations/skills/**,
# verified at origin/main 97817988. This file is the only one with power to fail on
# a missing clause; the rest either don't see these paths or can't detect prose loss.
#   - scripts/check-dead-infra-refs.sh:79 -- `find skills-all workspaces -type f`
#     sees these files, but only flags dead-infra idioms ("Query Athena workgroup"),
#     never a missing safety clause.
#   - scripts/lint-no-em-dash.sh:19 -- `TARGETS=( workspaces/support
#     skills-all/muso-intercom )`. Cannot see workspaces/operations/skills/.
#   - scripts/check-skill-drift.sh:110 -- finds every workspace SKILL.md (including
#     these two), but only fails when a workspace copy DIVERGES from a skills-all/
#     canonical of the same name. Neither skill has a skills-all/ canonical, so it
#     has nothing to diverge from and cannot fail here.
#   - scripts/check-refund-doctrine.sh:26-29 -- anchors
#     workspaces/operations/SOUL.md, skills-all/muso-refund-processor/SKILL.md,
#     skills-all/muso-refund-investigation/SKILL.md, scripts/muso-stripe-write.sh.
#     Not these two files.
#   - scripts/check-soul-bootstrap-size.sh:70 -- BOOTSTRAP_NAMES=(SOUL AGENTS USER
#     TOOLS IDENTITY HEARTBEAT MEMORY). Measures workspace bootstrap file sizes,
#     never skills/*/SKILL.md content.
#
# Prose is not enforcement. Copied verbatim from the structure of
# check-refund-doctrine.sh, written for the same class of incident.

ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

CDR_SKILL="${CDR_SKILL_FILE:-$ROOT/workspaces/operations/skills/customer-data-resolution/SKILL.md}"
CREDIT_CLEANUP="${CREDIT_CLEANUP_FILE:-$ROOT/workspaces/operations/skills/customer-data-resolution/references/credit-cleanup.md}"
CUSTOMER_UPDATES="${CUSTOMER_UPDATES_FILE:-$ROOT/workspaces/operations/skills/customer-data-resolution/references/customer-updates.md}"
INTAKE_CASES="${INTAKE_CASES_FILE:-$ROOT/workspaces/operations/skills/customer-data-resolution/references/intake-cases.md}"
REFUND_SKILL="${REFUND_RECONCILIATION_SKILL_FILE:-$ROOT/workspaces/operations/skills/subscription-refund-reconciliation/SKILL.md}"
CUSTOMER_COMM="${CUSTOMER_COMMUNICATION_FILE:-$ROOT/workspaces/operations/skills/subscription-refund-reconciliation/references/customer-communication.md}"

for f in "$CDR_SKILL" "$CREDIT_CLEANUP" "$CUSTOMER_UPDATES" "$INTAKE_CASES" "$REFUND_SKILL" "$CUSTOMER_COMM"; do
  [ -f "$f" ] || { echo "Missing $f (run from repo root, or set CDR_SKILL_FILE / CREDIT_CLEANUP_FILE / CUSTOMER_UPDATES_FILE / INTAKE_CASES_FILE / REFUND_RECONCILIATION_SKILL_FILE / CUSTOMER_COMMUNICATION_FILE)." >&2; exit 2; }
done

fail=0

# require <file> <label> <fixed-substring>
# Fails loudly (does not exit) if the substring is absent, so every missing anchor is
# reported in one pass.
# Both matchers compare WHITESPACE-NORMALIZED text: the whole file is flattened
# to a single space-separated line before matching, and so is the pattern.
#
# `grep -qF` matches within one line, but every anchor here is prose in a
# Markdown file. An ordinary re-wrap splits a sentence across two lines and a raw
# line-based match stops matching -- the clause is gone from the rendered doctrine
# and CI is still green. That is a gate failing OPEN, which is the one direction
# this gate must never fail.
_normalized() { tr '\n' ' ' < "$1" | tr -s '[:space:]' ' '; }
_normalize_pat() { printf '%s' "$1" | tr '\n' ' ' | tr -s '[:space:]' ' '; }

require() {
  local file="$1" label="$2" pat="$3"
  if ! _normalized "$file" | grep -qF -- "$(_normalize_pat "$pat")" 2>/dev/null; then
    echo "FAIL: ${file#"$ROOT"/}: $label" >&2
    echo "      expected to still contain: \"$pat\"" >&2
    fail=1
  fi
}

# --- customer-data-resolution/SKILL.md: Safety rules --------------------------
require "$CDR_SKILL" "the removal/unlink/merge/delete separation rule" \
  "Keep removal, raw unlinking, merge, and deletion separate"
require "$CDR_SKILL" "profile-merge entity/label separation" \
  "separate entity types and labels"
require "$CDR_SKILL" "the merge inventory exclusion" \
  "excluding unrelated, group, or mixed-credit profiles"
require "$CDR_SKILL" "the merge-scope pointer to credit-cleanup.md" \
  "Merge-scope anchor: \`references/credit-cleanup.md\`"
require "$CDR_SKILL" "the album-role manifest detail (roles + addedBy)" \
  "compare roles and \`addedBy\`"
require "$CDR_SKILL" "the step-7 customer-update pointer (invoice PDFs, streaming-unavailable)" \
  "invoice PDFs, streaming-unavailable questions"
require "$CDR_SKILL" "the login identity pointer" \
  "identity rule: \`references/intake-cases.md\`"

# Step 7 also ends with: "No case exists yet for lingering previews; do not
# invent guidance." That line is deliberately NOT anchored here. It's an
# absence claim -- true only until the first such case lands. Anchoring it
# would force whoever writes that case's guidance to either violate this gate
# or hand-edit the gate in the same PR as the first real fix, which is exactly
# the kind of friction that invites deleting the anchor instead of the claim.
# Do not "complete the set" by adding it back.

# --- customer-data-resolution/references/credit-cleanup.md --------------------
require "$CREDIT_CLEANUP" "the merge-scope narrowing (customer-confirmed duplicate only)" \
  "merge only the customer-confirmed duplicate and remove only the exact misassigned rows"
require "$CREDIT_CLEANUP" "the broaden-into-a-merge prohibition" \
  "Do not broaden the resolution into a merge"

# --- customer-data-resolution/references/customer-updates.md ------------------
require "$CUSTOMER_UPDATES" "the invoice-PDF proof bar (HTTP 200 + %PDF- signature)" \
  "require HTTP 200 plus a \`%PDF-\` signature"
require "$CUSTOMER_UPDATES" "the no-reuse-expired-URL rule" \
  "never reuse the expired URL"
require "$CUSTOMER_UPDATES" "the streaming-unavailable misattribution check" \
  "first ask whether the credits are actually misattributed"

# --- customer-data-resolution/references/intake-cases.md ----------------------
require "$INTAKE_CASES" "the stated-email-is-a-clue-only rule" \
  "treat a stated email as a lookup clue only"
require "$INTAKE_CASES" "the zero-credits-is-not-proof-of-loss rule" \
  "zero credits is not proof of loss"

# --- subscription-refund-reconciliation/SKILL.md -------------------------------
require "$REFUND_SKILL" "the customer-facing pointer to customer-communication.md" \
  "Customer-facing bar: \`references/customer-communication.md\`"

# --- subscription-refund-reconciliation/references/customer-communication.md --
require "$CUSTOMER_COMM" "the no-change-claim bar (only when no write succeeded)" \
  "only when no write succeeded"
require "$CUSTOMER_COMM" "the don't-tell-customer-nothing-changed rule" \
  "do not tell the customer nothing changed"

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "@Ops skill safety-clause doctrine has regressed (the #1047 regression class). Restore the missing anchors above." >&2
  echo "Context: scripts/check-ops-skill-doctrine.sh header + MUS-1796 (#1050) + MUS-1815." >&2
  exit 1
fi

echo "OK: @Ops skill safety-clause doctrine intact (customer-data-resolution + subscription-refund-reconciliation)."
