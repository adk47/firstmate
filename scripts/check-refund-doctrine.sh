#!/usr/bin/env bash
set -euo pipefail

# Mechanical backstop for the @Ops refund honesty + interactive-override doctrine.
#
# In a 2026-06 Slack thread the operations agent, pushed to refund a customer who already
# had prior refunds, INVENTED an escalation ("holding for Aaron approval"). The fix:
#   (1) @Ops surfaces a soft-wall block and ASKS an allowlisted requester to confirm an
#       override, rather than silently denying or fabricating an approval;
#   (2) the override executes only with an attributable token
#       (--override-confirmed-by / --approval-msg-id), and the money gate
#       (muso-stripe-write.sh) enforces the one-time rule + token below the agent.
#
# It ALSO covers a second incident. A 2026-09-09 Stripe audit found 223 customers who
# received BOTH a cash refund AND a customer-balance credit for the same unused period
# ($4,827.65). The cause was doctrine: muso-refund-investigation told the agent the
# credit balance WAS the correct refund amount, and never said to zero it. The fix is
# split across four files, so all four are anchored here.
#
# Prose != enforcement, so this guard fails CI if any load-bearing anchor of that doctrine
# (or the money-gate function) is silently removed. It does NOT stop runtime fabrication —
# that is the money gate's job (deterministic) and the agent's honesty rules.

ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

SOUL="${OPS_SOUL_FILE:-$ROOT/workspaces/operations/SOUL.md}"
SKILL="${REFUND_SKILL_FILE:-$ROOT/skills-all/muso-refund-processor/SKILL.md}"
STRIPE_GATE="${STRIPE_GATE_FILE:-$ROOT/scripts/muso-stripe-write.sh}"
INVESTIGATION="${REFUND_INVESTIGATION_FILE:-$ROOT/skills-all/muso-refund-investigation/SKILL.md}"

for f in "$SOUL" "$SKILL" "$STRIPE_GATE" "$INVESTIGATION"; do
  [ -f "$f" ] || { echo "Missing $f (run from repo root, or set OPS_SOUL_FILE / REFUND_SKILL_FILE / STRIPE_GATE_FILE / REFUND_INVESTIGATION_FILE)." >&2; exit 2; }
done

fail=0

# require <file> <label> <fixed-substring>
# Fails loudly (does not exit) if the substring is absent, so every missing anchor is
# reported in one pass.
# Both matchers compare WHITESPACE-NORMALIZED text: the whole file is flattened
# to a single space-separated line before matching, and so is the pattern.
#
# `grep -qF` matches within one line, but every anchor here is prose in a
# Markdown file. An ordinary re-wrap splits "Correct refund: $106.73 (the credit
# balance)" across two lines and the FORBID stops matching — the banned
# instruction renders exactly as before while CI goes green. That is a gate
# failing OPEN, which is the one direction it must never fail.
#
# require() gets the same treatment so a harmless re-flow cannot turn into a red
# run that someone then "fixes" by deleting the anchor.
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

# forbid <file> <label> <fixed-substring>
# The inverse of require(). Some of this doctrine is defined by what it must NOT say:
# the old worked example ("the credit balance IS the correct refund") reads as perfectly
# sensible advice, which is exactly why it survived for years and cost $4,827.65. A
# require-only guard cannot stop a well-meaning edit from restoring it. Same
# non-exiting behaviour so every violation is reported in one pass.
forbid() {
  local file="$1" label="$2" pat="$3"
  if _normalized "$file" | grep -qF -- "$(_normalize_pat "$pat")" 2>/dev/null; then
    echo "FAIL: ${file#"$ROOT"/}: $label" >&2
    echo "      must NO LONGER contain: \"$pat\"" >&2
    fail=1
  fi
}

# --- operations SOUL.md: honesty + interactive-gate doctrine -----------------
require "$SOUL" "the 'holding for Aaron approval' fabrication ban" \
  "holding for Aaron approval"
require "$SOUL" "the verifiable-escalation rule (escalated only if you posted the mention)" \
  "containing the literal token"
require "$SOUL" "the interactive soft-wall confirm gate (ask, then await the reply)" \
  "wait for their reply"
require "$SOUL" "the attributable override token convention" \
  "--override-confirmed-by"

# --- muso-refund-processor SKILL.md: DENY handling + override flow -----------
require "$SKILL" "the Refund Denied report template" \
  "Refund Denied"
require "$SKILL" "the override execution path" \
  "If OVERRIDE-confirmed"
require "$SKILL" "the ask-then-await interactive confirm step" \
  "STOP and wait"
require "$SKILL" "the override token on the execution command" \
  "--override-confirmed-by"
require "$SKILL" "the never-on-a-fabricated-confirmation rule" \
  "fabricated confirmation"

# --- muso-stripe-write.sh: the deterministic money-path gate -----------------
require "$STRIPE_GATE" "the one-time-policy override gate function" \
  "enforce_refund_one_time_gate"
require "$STRIPE_GATE" "the override token parsing in the money gate" \
  "--override-confirmed-by"

# --- muso-refund-investigation SKILL.md: the never-both rule -----------------
require "$INVESTIGATION" "the never-both rule" \
  "NEVER both a cash refund and a credit balance"
require "$INVESTIGATION" "the zero-first ordering" \
  "zero the credit balance BEFORE the cash refund"
require "$INVESTIGATION" "the corrected worked example (two-concession row)" \
  "two** concessions"
require "$INVESTIGATION" "the credit-provenance read" \
  "/balance_transactions"
# The line that caused the incident. It must stay gone.
# SINGLE quotes are load-bearing here: in double quotes bash reads `$1` out of
# `$106.73` and the pattern silently degrades to `06.73 (the credit balance)`.
forbid "$INVESTIGATION" "the old dangerous worked example" \
  'Correct refund: $106.73 (the credit balance)'

# --- muso-refund-processor SKILL.md: credit disposition + rail 8 -------------
require "$SKILL" "the credit-balance disposition step" \
  "Credit-balance disposition"
require "$SKILL" "the keep-credit waiver token" \
  "--keep-credit-confirmed-by"
require "$SKILL" "safety rail 8 (no cash on top of a live credit)" \
  "No cash refund on top of a live credit"
require "$SKILL" "the post-write did-happen clause" \
  "POST-REFUND-CREDIT-LIVE"
forbid "$SKILL" "the old 'refund the credit balance' instruction" \
  "refund the credit balance, not the original charge"
# The mixed-balance invariant, as an anchor: every verification in operator-facing
# doctrine must target the CONCESSION. "verify the balance is 0" survived one full
# round of fixes in the POST-REFUND-CREDIT-LIVE paragraph because only the first
# occurrence was corrected.
forbid "$SKILL" "any 'verify the balance is 0' instruction" \
  "verify the balance is 0"
forbid "$INVESTIGATION" "any 'verify the balance is 0' instruction" \
  "verify the balance is 0"
forbid "$SOUL" "any 'verify the balance is 0' instruction" \
  "verify the balance is 0"

# --- operations SOUL.md: the credit wall ------------------------------------
require "$SOUL" "the credit wall" \
  "Credit wall"
require "$SOUL" "the keep-credit waiver token" \
  "--keep-credit-confirmed-by"

# --- muso-stripe-write.sh: the deterministic credit gate --------------------
require "$STRIPE_GATE" "the no-double-concession gate function" \
  "enforce_no_double_concession_gate"
require "$STRIPE_GATE" "the live-credit predicate call" \
  "customer_live_proration_credit"
require "$STRIPE_GATE" "the keep-credit token parsing in the money gate" \
  "--keep-credit-confirmed-by"

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "Refund honesty / interactive-override doctrine has regressed. Restore the missing anchors above." >&2
  echo "Context: scripts/check-refund-doctrine.sh header + the refund-override-gate plan." >&2
  exit 1
fi

echo "OK: refund honesty + interactive-override doctrine intact (SOUL.md + muso-refund-processor + money gate)."
