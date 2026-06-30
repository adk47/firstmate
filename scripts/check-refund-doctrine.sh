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
# Prose != enforcement, so this guard fails CI if any load-bearing anchor of that doctrine
# (or the money-gate function) is silently removed. It does NOT stop runtime fabrication —
# that is the money gate's job (deterministic) and the agent's honesty rules.

ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

SOUL="${OPS_SOUL_FILE:-$ROOT/workspaces/operations/SOUL.md}"
SKILL="${REFUND_SKILL_FILE:-$ROOT/skills-all/muso-refund-processor/SKILL.md}"
STRIPE_GATE="${STRIPE_GATE_FILE:-$ROOT/scripts/muso-stripe-write.sh}"

for f in "$SOUL" "$SKILL" "$STRIPE_GATE"; do
  [ -f "$f" ] || { echo "Missing $f (run from repo root, or set OPS_SOUL_FILE / REFUND_SKILL_FILE / STRIPE_GATE_FILE)." >&2; exit 2; }
done

fail=0

# require <file> <label> <fixed-substring>
# Fails loudly (does not exit) if the substring is absent, so every missing anchor is
# reported in one pass.
require() {
  local file="$1" label="$2" pat="$3"
  if ! grep -qF -- "$pat" "$file" 2>/dev/null; then
    echo "FAIL: ${file#"$ROOT"/}: $label" >&2
    echo "      expected to still contain: \"$pat\"" >&2
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

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "Refund honesty / interactive-override doctrine has regressed. Restore the missing anchors above." >&2
  echo "Context: scripts/check-refund-doctrine.sh header + the refund-override-gate plan." >&2
  exit 1
fi

echo "OK: refund honesty + interactive-override doctrine intact (SOUL.md + muso-refund-processor + money gate)."
