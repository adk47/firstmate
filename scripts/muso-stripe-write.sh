#!/usr/bin/env bash
# muso-stripe-write.sh — gate Stripe WRITE commands on codex model health.
#
# WHY THIS EXISTS
# The operations agent can autonomously run `stripe refunds create` (moves money).
# It CANNOT perceive when it has been degraded onto a weak fallback model: openclaw's
# `Model Fallback:` banner is built only on the delivery path and is never injected into
# the agent's prompt (see memory reference_agent_cannot_see_own_fallback_state). On
# 2026-06-08 a codex refresh-token race dropped the fleet to openrouter/openai/gpt-5.4-mini
# and that weak model fabricated a fake refund-approval bureaucracy. Wiring the refund skill
# means a future degraded turn could instead execute a *real* but ill-judged refund.
#
# This wrapper is the mechanical guard the SOUL doctrine alone cannot be: before running a
# Stripe write it scans the live gateway journal for the codex auth_permanent / refresh-race
# signature and REFUSES the write while degraded, telling the agent to defer to a human.
# It is FAIL-CLOSED: if model health cannot be verified, it refuses (this is a money path).
#
# Usage:
#   muso-stripe-write.sh refunds create -d "charge=ch_XXX" -d "reason=requested_by_customer" --confirm
# i.e. exactly the args you would pass to `stripe`, minus the leading `stripe` —
# except the wrapper-only waiver flags, which are consumed here and never forwarded:
#   --override-confirmed-by, --keep-subscription-confirmed-by, --approval-msg-id
#
# Env overrides (mainly for tests):
#   OPENCLAW_GATEWAY_UNIT   systemd unit to scan (default: openclaw-gateway-main)
#   CODEX_HEALTH_WINDOW_MIN journal look-back in minutes (default: 5)
#   STRIPE_BIN              stripe binary (default: stripe)
#   CODEX_HEALTH_LIB        path to codex-health.sh (default: <script-dir>/lib/codex-health.sh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_HEALTH_LIB="${CODEX_HEALTH_LIB:-$SCRIPT_DIR/lib/codex-health.sh}"
GATEWAY_UNIT="${OPENCLAW_GATEWAY_UNIT:-openclaw-gateway-main}"
WINDOW_MIN="${CODEX_HEALTH_WINDOW_MIN:-5}"
STRIPE_BIN="${STRIPE_BIN:-stripe}"

# shellcheck source=lib/codex-health.sh
if [ ! -r "$CODEX_HEALTH_LIB" ]; then
  echo "REFUSED (muso-stripe-write): cannot read codex-health lib at $CODEX_HEALTH_LIB" >&2
  exit 3
fi
# shellcheck disable=SC1090
source "$CODEX_HEALTH_LIB"

refuse() {
  echo "REFUSED (muso-stripe-write): $1" >&2
  echo "Did NOT execute the Stripe write. Defer to a human: @-mention Nick (U0AL36NADEY) so he can run it, or retry once codex model health is confirmed." >&2
  exit 3
}

# --- Refund one-time-policy override gate ------------------------------------
# `refunds create` for a customer who ALREADY has a prior refund is blocked by the
# one-time policy. An allowlisted requester (Aaron/Jan/Nick) may waive it, but ONLY by
# passing an explicit, attributable override token captured from their in-thread "yes"
# (--override-confirmed-by <slack_id> --approval-msg-id <ts>). This is enforced HERE in
# bash, below the agent, so a degraded/confabulating model cannot move money on an
# imagined approval. The override flags are consumed here and never forwarded to `stripe`.
REFUND_OVERRIDE_ALLOWLIST="${REFUND_OVERRIDE_ALLOWLIST:-U7RP6HKUZ U038BM16T7W U0AL36NADEY aaron jan nick aaron@muso.ai jan@muso.ai nick@muso.ai}"

is_allowlisted_approver() {
  local who="$1" a
  local -a allow=()
  read -ra allow <<< "$REFUND_OVERRIDE_ALLOWLIST"
  for a in "${allow[@]}"; do
    [ "$who" = "$a" ] && return 0
  done
  return 1
}

# Count prior succeeded refunds across the charge's customer. Non-zero EXIT = could not
# verify (caller fails closed). A FULL page (>= limit) is reported as 1 ("cannot rule out an
# older prior refund") so the gate stays fail-closed for high-volume customers rather than
# missing a prior refund off the end of the page. NOTE: confirm the `stripe charges list`
# filter syntax live on node-8; the bats pin the LOGIC.
refund_history_count() {
  local charge="$1" cust charges
  cust="$("$STRIPE_BIN" charges retrieve "$charge" 2>/dev/null | jq -r '.customer // empty')" || return 1
  [ -n "$cust" ] || return 1
  charges="$("$STRIPE_BIN" charges list --customer "$cust" --limit 100 2>/dev/null)" || return 1
  printf '%s' "$charges" | jq -e 'type == "object"' >/dev/null 2>&1 || return 1
  printf '%s' "$charges" | jq '
    ([.data[]? | select((.amount_refunded // 0) > 0)] | length) as $r
    | if $r > 0 then $r
      elif (.data | length) >= 100 then 1
      else 0 end'
}

enforce_refund_one_time_gate() {
  local charge="$1" confirmed_by="$2" approval_msg_id="$3" prior
  if [ -z "$charge" ]; then
    refuse "refund command has no parseable charge=ch_... argument; cannot verify refund history."
  fi
  if ! prior="$(refund_history_count "$charge")"; then
    refuse "couldn't verify refund history for $charge (Stripe read failed). Not moving money — retry or defer to a human."
  fi
  [ "${prior:-0}" -gt 0 ] || return 0   # first refund for this customer → allow
  if [ -z "$confirmed_by" ] || [ -z "$approval_msg_id" ]; then
    refuse "this customer already has a prior refund (one-time policy). A repeat refund needs an authorized override: an allowlisted requester (Aaron/Jan/Nick) must confirm in-thread, then pass --override-confirmed-by <slack_id> --approval-msg-id <ts>."
  fi
  if ! is_allowlisted_approver "$confirmed_by"; then
    refuse "--override-confirmed-by '$confirmed_by' is not on the god-mode allowlist (Aaron/Jan/Nick); refusing the override."
  fi
  echo "AUTHORIZED-OVERRIDE (muso-stripe-write): repeat refund on $charge waived by $confirmed_by (approval msg $approval_msg_id)" >&2
}

# --- No-paid-access-after-refund gate ------------------------------------------
# A refund of a SUBSCRIPTION charge must not leave the customer with paid access
# (Aaron, #operations 2026-07-02). Enforced here in bash, below the agent, because
# skill prose alone is not enforcement. Scope: only charges whose invoice belongs
# to a subscription — one-off charges (plaques, merch) are exempt, so unrelated
# active subscriptions never block those refunds. "Active-like" = active/trialing/
# past_due/unpaid; cancel_at_period_end=true still grants access, so it does NOT
# exempt. Intentional goodwill/proration refunds that keep the subscription need
# an attributable allowlisted waiver (--keep-subscription-confirmed-by), same
# shape as the one-time-policy override.

# Echo the charge's subscription exposure: "EXEMPT" (not a subscription charge),
# "" (subscription charge, no active-like subs remain), or the space-joined ids of
# active-like subscriptions. Non-zero EXIT = could not verify (caller fails
# closed). A FULL page (>= limit) with no visible active sub is unverifiable.
# EXEMPT requires the key to be PRESENT and explicitly null: an object missing
# `invoice`/`subscription` entirely is treated as unverifiable, not one-off —
# error-shaped payloads and Stripe API-version drift (2025-03-31.basil moves
# invoice.subscription under .parent) must fail CLOSED, never silently disarm
# the gate. Field paths + `-d` list filters verified live on node-8 2026-07-02
# (current API emits `"invoice": null` / `"subscription": null` explicitly);
# re-verify on a stripe-CLI or account API-version bump. The bats pin the LOGIC.
charge_subscription_exposure() {
  local charge="$1" cjson invoice cust ijson sub subs
  cjson="$("$STRIPE_BIN" charges retrieve "$charge" 2>/dev/null)" || return 1
  printf '%s' "$cjson" | jq -e 'type == "object" and has("invoice")' >/dev/null 2>&1 || return 1
  invoice="$(printf '%s' "$cjson" | jq -r '.invoice // empty')"
  [ -n "$invoice" ] || { echo "EXEMPT"; return 0; }
  ijson="$("$STRIPE_BIN" invoices retrieve "$invoice" 2>/dev/null)" || return 1
  printf '%s' "$ijson" | jq -e 'type == "object" and has("subscription")' >/dev/null 2>&1 || return 1
  sub="$(printf '%s' "$ijson" | jq -r '.subscription // empty')"
  [ -n "$sub" ] || { echo "EXEMPT"; return 0; }
  cust="$(printf '%s' "$cjson" | jq -r '.customer // empty')"
  [ -n "$cust" ] || return 1
  subs="$("$STRIPE_BIN" subscriptions list -d "customer=$cust" -d "status=all" --limit 100 2>/dev/null)" || return 1
  printf '%s' "$subs" | jq -e 'type == "object" and (.data | type == "array")' >/dev/null 2>&1 || return 1
  printf '%s' "$subs" | jq -r '
    [.data[] | select(.status == "active" or .status == "trialing"
                      or .status == "past_due" or .status == "unpaid") | .id] as $live
    | if ($live | length) > 0 then ($live | join(" "))
      elif (.data | length) >= 100 then error("full page")
      else "" end' 2>/dev/null || return 1
}

enforce_no_paid_access_gate() {
  local charge="$1" keep_by="$2" approval_msg_id="$3" exposure
  if ! exposure="$(charge_subscription_exposure "$charge")"; then
    refuse "couldn't verify subscription state for $charge's customer (Stripe read failed). Not moving money — a refund must not leave paid access in place."
  fi
  [ "$exposure" = "EXEMPT" ] && return 0
  [ -n "$exposure" ] || return 0
  if [ -z "$keep_by" ] || [ -z "$approval_msg_id" ]; then
    refuse "customer still has active-like paid subscription(s): $exposure — a completed refund must leave no paid access. Cancel first (bash /opt/hydra/scripts/muso-stripe-write.sh subscriptions cancel <sub_id> --confirm), verify, then retry the refund. To intentionally KEEP the subscription (goodwill/proration refund), an allowlisted requester (Aaron/Jan/Nick) must confirm in-thread, then pass --keep-subscription-confirmed-by <slack_id> --approval-msg-id <ts>."
  fi
  if ! is_allowlisted_approver "$keep_by"; then
    refuse "--keep-subscription-confirmed-by '$keep_by' is not on the god-mode allowlist (Aaron/Jan/Nick); refusing to leave paid access after a refund."
  fi
  echo "AUTHORIZED-KEEP (muso-stripe-write): refund on $charge leaves subscription(s) $exposure active, waived by $keep_by (approval msg $approval_msg_id)" >&2
}

# Recognize a refund-CREATE invocation in any valid Stripe-CLI form, so the gate can't be
# slipped past with a non-canonical shape (`post /v1/refunds`, or a global flag before the
# subcommand like `--color off refunds create`). Fail CLOSED: a refund-shaped write goes
# through the refund gates regardless of arg order.
is_refund_create() {
  local joined=" ${STRIPE_ARGS[*]} " a
  case "$joined" in
    *" refunds create "*) return 0 ;;
  esac
  case "$joined" in
    *" post "*)
      for a in "${STRIPE_ARGS[@]}"; do
        case "$a" in */refunds) return 0 ;; esac
      done
      ;;
  esac
  return 1
}

# Split override flags out of the stripe args (stripe must never see them).
STRIPE_ARGS=()
OVERRIDE_CONFIRMED_BY=""
KEEP_SUB_CONFIRMED_BY=""
APPROVAL_MSG_ID=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --override-confirmed-by)
      [ "$#" -ge 2 ] || { echo "usage: --override-confirmed-by needs a value" >&2; exit 2; }
      OVERRIDE_CONFIRMED_BY="$2"; shift 2 ;;
    --keep-subscription-confirmed-by)
      [ "$#" -ge 2 ] || { echo "usage: --keep-subscription-confirmed-by needs a value" >&2; exit 2; }
      KEEP_SUB_CONFIRMED_BY="$2"; shift 2 ;;
    --approval-msg-id)
      [ "$#" -ge 2 ] || { echo "usage: --approval-msg-id needs a value" >&2; exit 2; }
      APPROVAL_MSG_ID="$2"; shift 2 ;;
    *)                       STRIPE_ARGS+=("$1"); shift ;;
  esac
done

if [ "${#STRIPE_ARGS[@]}" -eq 0 ]; then
  echo "usage: muso-stripe-write.sh <stripe args...>  (e.g. refunds create -d charge=ch_X --confirm)" >&2
  exit 2
fi

# Live model-health probe via the shared gate (lib/codex-health.sh). It is FAIL-CLOSED:
# both "unverifiable" (journal unreadable) and "degraded" return non-zero and refuse;
# an empty-but-readable window is healthy-quiet. A weak fallback model must never move
# money, so the money path refuses on anything but a clean verdict.
if ! reason="$(codex_health_gate "$GATEWAY_UNIT" "$WINDOW_MIN" 2>&1)"; then
  refuse "$reason"
fi

# Refund-create writes (any form) additionally pass the one-time-policy override
# gate and the no-paid-access-after-refund gate.
if is_refund_create; then
  charge=""
  for a in "${STRIPE_ARGS[@]}"; do
    case "$a" in charge=*) charge="${a#charge=}" ;; esac
  done
  enforce_refund_one_time_gate "$charge" "$OVERRIDE_CONFIRMED_BY" "$APPROVAL_MSG_ID"
  enforce_no_paid_access_gate "$charge" "$KEEP_SUB_CONFIRMED_BY" "$APPROVAL_MSG_ID"
fi

# Healthy + authorized → run the real Stripe write (override flags stripped).
exec "$STRIPE_BIN" "${STRIPE_ARGS[@]}"
