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
# It also enforces three refund-specific policy walls, each below the agent: the
# one-time-refund policy, the no-paid-access-after-refund rule, and the
# no-double-concession rule (a cash refund on top of a live customer-balance credit —
# see enforce_no_double_concession_gate). The first two are waivable with an
# attributable, allowlisted token, or by a verified --machine-approval record (see
# "Machine approval" below); the double-concession rule is waivable only by a token.
#
# Usage:
#   muso-stripe-write.sh refunds create -d "charge=ch_XXX" -d "reason=requested_by_customer" --confirm
# i.e. exactly the args you would pass to `stripe`, minus the leading `stripe` —
# except the wrapper-only waiver flags, which are consumed here and never forwarded:
#   --override-confirmed-by, --keep-subscription-confirmed-by,
#   --keep-credit-confirmed-by, --approval-msg-id
#   --machine-approval <record.json>   a firstmate decision record, inside the caps
#                                      only (see "Machine approval" below)
#
# Env overrides (mainly for tests):
#   OPENCLAW_GATEWAY_UNIT   systemd unit to scan (default: openclaw-gateway-main)
#   CODEX_HEALTH_WINDOW_MIN journal look-back in minutes (default: 5)
#   STRIPE_BIN              stripe binary (default: stripe)
#   CODEX_HEALTH_LIB        path to codex-health.sh (default: <script-dir>/lib/codex-health.sh)
#   STRIPE_CREDIT_LIB       path to stripe-credit.sh (default: <script-dir>/lib/stripe-credit.sh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_HEALTH_LIB="${CODEX_HEALTH_LIB:-$SCRIPT_DIR/lib/codex-health.sh}"
STRIPE_CREDIT_LIB="${STRIPE_CREDIT_LIB:-$SCRIPT_DIR/lib/stripe-credit.sh}"
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

# A missing credit lib must REFUSE, not silently skip the double-concession gate —
# an unreadable guard is an absent guard, and this is a money path.
# shellcheck source=lib/stripe-credit.sh
if [ ! -r "$STRIPE_CREDIT_LIB" ]; then
  echo "REFUSED (muso-stripe-write): cannot read stripe-credit lib at $STRIPE_CREDIT_LIB" >&2
  exit 3
fi
# shellcheck disable=SC1090
source "$STRIPE_CREDIT_LIB"

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

# --- No-double-concession gate -------------------------------------------------
# A cash refund on top of a LIVE customer-balance credit pays the same concession
# twice: the cash, plus a credit that silently pays the customer's next invoices.
# A finance audit on 2026-09-09 found 223 customers in that state ($4,827.65),
# the exemplar being re_3SacfBLsjTo3Ar3l1nCLgQ5C — $107.50 cash on 2025-12-05
# plus a $117.72 `invoice_too_small` credit that paid nine later invoices. The
# agent doctrine that produced it (skills-all/muso-refund-investigation) called
# the credit balance the CORRECT refund amount and never said to zero it, which
# is why this has to live in bash, below the agent.
#
# SCOPE: EVERY refund, subscription or one-off. This deliberately does NOT copy
# enforce_no_paid_access_gate's one-off exemption, and that difference is the
# whole point.
#
# That exemption is correct for paid access (a one-off charge grants none) and
# it is correct about PRORATION (Stripe cannot prorate a charge with no
# subscription). It is wrong here, because the double concession is not
# fundamentally about proration — it is about paying the same goodwill twice,
# and a hand-entered credit needs no subscription at all. Measured against the
# 2026-09-09 audit: 192 of the 241 flagged pairs (80%) are ONE-OFF charges,
# including all 190 of the 2026-07-13/14 auto-recharge cluster. A gate scoped to
# subscription lineage would have caught 49 of 241 and missed the entire
# majority class. Do not "align" this with the sibling gate's scope.
#
# The false-refusal cost the exemption used to buy is already paid for by the
# type+metadata classification in lib/stripe-credit.sh: our own referral and
# offer credits are `adjustment` rows carrying metadata and are never reported,
# so an unrelated merch refund is not blocked by them.

# Echo the charge's customer id; non-zero exit = could not verify (caller fails
# closed). Deliberately does NOT resolve the invoice/subscription: this gate
# applies to every refund, so the charge -> invoice -> subscription walk in
# charge_subscription_exposure() is not needed here and is not duplicated.
charge_customer_id() {
  local charge="$1" cjson cust
  cjson="$("$STRIPE_BIN" charges retrieve "$charge" 2>/dev/null)" || return 1
  printf '%s' "$cjson" | jq -e 'type == "object" and has("customer")' >/dev/null 2>&1 || return 1
  cust="$(printf '%s' "$cjson" | jq -r '.customer // empty')"
  [ -n "$cust" ] || return 1
  echo "$cust"
}

# Emit the remediation an operator (or agent) must run to zero a credit before
# retrying the refund. One place, so the refusal text and the post-write banner
# can never drift apart into two subtly different instructions.
zero_credit_instructions() {
  local cus="$1" bal="$2" charge="$3" amount
  # Name the CONCESSION amount, not the raw balance. A balance can mix the
  # concession with a referral/offer credit we minted on purpose, and telling an
  # operator to zero the whole balance would have them claw back money the
  # customer was genuinely owed. Fall back to the balance only if the concession
  # cannot be measured, and say so rather than printing a confident wrong number.
  amount="$(customer_live_concession_amount "$cus" 2>/dev/null || echo "")"
  if ! [[ "$amount" =~ ^[0-9]+$ ]] || [ "$amount" -le 0 ]; then
    printf 'Zero the CONCESSION portion first (could not measure it just now — read /v1/customers/%s/balance_transactions and sum only the concession rows; the raw balance is %s, which may include referral/offer credit you must NOT reclaim), then verify.' \
      "$cus" "$bal"
    return 0
  fi
  # Verify the CONCESSION is gone, not the balance. A customer may legitimately
  # retain tagged referral/offer credit, so `.balance == 0` would instruct the
  # operator to claw back money that was never a duplicate — the same mixed-balance
  # error the reclaim arithmetic itself had.
  printf 'Zero it first:  bash /opt/hydra/scripts/muso-stripe-write.sh post "/v1/customers/%s/balance_transactions" -d "amount=%s" -d "currency=usd" -d "description=zeroed before cash refund on %s"   then verify:  bash -c '"'"'source /opt/hydra/scripts/lib/stripe-credit.sh; customer_live_concession_amount %s'"'"'   # must print 0 (the balance may still be NEGATIVE if the customer holds referral/offer credit — that is correct, do NOT zero it)' \
    "$cus" "$amount" "$charge" "$cus"
}

# Set to 1 ONLY when enforce_no_double_concession_gate actually validated an
# allowlisted waiver. The post-write recheck keys on this, never on the presence
# of --keep-credit-confirmed-by: when the pre-write balance is clean the gate
# returns early WITHOUT validating the token, so a bogus value would otherwise
# silence the one check that catches a credit Stripe mints during the refund.
CREDIT_WAIVER_AUTHORIZED=0

enforce_no_double_concession_gate() {
  local charge="$1" keep_credit_by="$2" approval_msg_id="$3" cust credit bal
  if ! cust="$(charge_customer_id "$charge")"; then
    refuse "couldn't identify the customer behind $charge (Stripe read failed). Not moving money — a cash refund on top of a live credit is a double concession."
  fi
  if ! credit="$(customer_live_proration_credit "$cust")"; then
    refuse "couldn't verify the credit balance for $cust (Stripe read failed). Not moving money — a cash refund on top of a live credit is a double concession."
  fi
  [ -n "$credit" ] || return 0
  bal="${credit%% *}"
  if [ -z "$keep_credit_by" ] || [ -z "$approval_msg_id" ]; then
    refuse "customer $cust still holds a live concession credit (balance $credit). A cash refund on top of that is a DOUBLE concession — one unused period, two payouts. $(zero_credit_instructions "$cust" "$bal" "$charge"). To DELIBERATELY give both (rare), an allowlisted requester (Aaron/Jan/Nick) must confirm in-thread, then pass --keep-credit-confirmed-by <slack_id> --approval-msg-id <ts>."
  fi
  if ! is_allowlisted_approver "$keep_credit_by"; then
    refuse "--keep-credit-confirmed-by '$keep_credit_by' is not on the god-mode allowlist (Aaron/Jan/Nick); refusing to pay a second concession."
  fi
  CREDIT_WAIVER_AUTHORIZED=1
  echo "AUTHORIZED-KEEP-CREDIT (muso-stripe-write): refund on $charge leaves live credit $credit in place (DELIBERATE double concession), waived by $keep_credit_by (approval msg $approval_msg_id)" >&2
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

# ── Machine approval: a firstmate decision record, inside the caps only ──────
#
# The waivers above take a named human's Slack id. This adds ONE machine class
# beside them, it does not replace them: a refund decided by firstmate on
# verified facts, at or under the captain's standing caps (ruling 186,
# 2026-10-30: $150 per refund, $300 per customer). Above either cap, and for
# anything recorded as a legal settlement, a formal claim or a legal-action
# threat, the record is refused and the human flags stay the only way through.
# A legal-action threat stays a named human's decision (Aaron), as
# skills-all/muso-refund-processor says; `legal_threat` is required so a record
# cannot leave it out, but only false passes.
#
# A record is a CLAIM, not a fact. Everything that can be re-read is re-read
# from Stripe here (charge, customer, currency, dispute, refundable amount, what
# the customer has already been refunded); the record's evidence fields are
# required and copied to the audit file, they are not what the caps are checked
# against. What a record may waive: the one-time policy, and paid access after
# the refund when it says keep_subscription. It can never waive the
# double-concession gate.
#
# The paths are literals, not env seams (tests rewrite them in a scratch copy).
# NOTHING creates MACHINE_APPROVAL_DIR: until an operator makes it on the host,
# every machine-approved refund is refused. It is not claimed to be
# non-forgeable; any root process on the host can write there. The caps and the
# audit file are what bound it.
readonly MACHINE_APPROVAL_DIR="/etc/hydra/refund-machine-approvals"
readonly MACHINE_APPROVAL_KILL="/etc/hydra/refund-machine-approval.disabled"
readonly MACHINE_APPROVAL_AUDIT="/var/lib/hydra/refund-machine-approvals/audit.jsonl"
# A separate used-marker per record, deliberately NOT the audit file: the audit
# is a log an operator may rotate, and a rotated or truncated audit made a spent
# record look unused (qa-review 2026-11-15T14:25Z). One marker per record sha, a
# different directory, and the Stripe idempotency key below is the backstop that
# a node-8 process cannot delete at all.
readonly MACHINE_APPROVAL_USED_DIR="/var/lib/hydra/refund-machine-approvals/used"
# The signature. A record is only an approval when the reviewer key signs those
# exact bytes, and that key is not on this host: it is the copy-gate reviewer's,
# which signs outbound copy verdicts on the reviewer host. A root process on
# node-8 can write a record but cannot mint this. The path is derived from this
# script's own location, not an env var, so a caller cannot point the check at a
# key it wrote; a `refund-approval-reviewer.allowed_signers` a caller controls is
# not an approval (tests rewrite this literal in a scratch copy).
readonly MACHINE_APPROVAL_SIGNERS="$SCRIPT_DIR/../policies/refund-approval-reviewer.allowed_signers"
readonly MACHINE_APPROVAL_NAMESPACE="muso-refund-approval-v1"
readonly MACHINE_APPROVAL_SIGNER_ID="outbound-copy-reviewer"
# Whether the machine class may spend at all is a reviewed config flip, not a
# directory somebody creates on the host. This path is derived from the script's
# own location (a caller's registry is not an approval; tests rewrite this literal
# in a scratch copy), and the row must say enabled true with a non-empty
# approved_by and approval_ref before a signed record can move money.
readonly MACHINE_APPROVAL_REGISTRY="$SCRIPT_DIR/../policies/refund-machine-approval-automation.json"
readonly MACHINE_APPROVERS="firstmate"
readonly MACHINE_REFUND_CAP_CENTS=15000
readonly MACHINE_CUSTOMER_CAP_CENTS=30000
# Pages of 100 charges read for the customer cap before the gate gives up and
# refuses. 50 pages is 5,000 charges; a monthly subscriber makes 12 a year.
readonly MACHINE_CHARGE_PAGE_LIMIT=50

MACHINE_APPROVED=0
MACHINE_KEEP_SUB=0
MACHINE_RECORD_SHA=""
MACHINE_AMOUNT=""
MACHINE_CUSTOMER=""
MACHINE_APPROVER=""
MACHINE_AUDIT_LOCK=""
MACHINE_APPROVAL_SNAPSHOT=""
MACHINE_APPROVAL_LIVE=""

# machine_audit <phase> <charge> [refund_id] [rc] — one JSON line per phase.
# `intent` is written BEFORE the Stripe call and `executed`/`failed` after it, so
# a run killed between the two leaves an intent with no outcome, which the next
# run refuses instead of retrying a non-idempotent money write blind.
machine_audit() {
  local phase="$1" charge="$2" refund_id="${3:-}" rc="${4:-}"
  mkdir -p "$(dirname "$MACHINE_APPROVAL_AUDIT")" 2>/dev/null || return 1
  jq -cn --arg phase "$phase" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg sha "$MACHINE_RECORD_SHA" --arg approver "$MACHINE_APPROVER" \
    --arg charge "$charge" --arg customer "$MACHINE_CUSTOMER" \
    --argjson amount "${MACHINE_AMOUNT:-0}" --argjson keep "$MACHINE_KEEP_SUB" \
    --arg refund "$refund_id" --arg rc "$rc" --slurpfile rec "${MACHINE_APPROVAL_SNAPSHOT:-$MACHINE_APPROVAL_FILE}" \
    '{phase:$phase, at:$at, record_sha256:$sha, approver:$approver, charge:$charge,
      customer:$customer, amount_cents:$amount, keep_subscription:($keep==1),
      refund_id:$refund, rc:$rc, record:$rec[0]}' >>"$MACHINE_APPROVAL_AUDIT" || return 1
}

# machine_audit_unlock — release the used-check/caps/write lock after the outcome
# line is on disk (or the write failed). The intent line is what makes the record
# look used to the next run; the lock is what makes the customer cap hold while
# a write is in flight.
machine_audit_unlock() {
  [ -n "$MACHINE_AUDIT_LOCK" ] || return 0
  flock -u 9 2>/dev/null || true
  exec 9>&-
  MACHINE_AUDIT_LOCK=""
}

# verify_machine_approval <charge> — refuses, or sets MACHINE_APPROVED=1.
# machine_path_still_on — BOTH switches, re-read under the lock immediately
# before the intent line. A run can wait up to a minute on the lock and then
# read pages of charges; a kill file, a disarm, or a registry flip that lands in
# that time must stop it, or "switched off" would not mean off for a run already
# queued.
# The used marker, and why it is not the audit file. The audit is a log: an
# operator rotates it, and a rotation used to re-enable a spent record. The marker
# is one file per record sha under its own directory, and it is written BEFORE the
# Stripe call, so there is no interval in which money has moved and no durable
# trace of it exists (qa-review 2026-11-15T14:32Z: a crash between the refund and
# a later marker write left nothing behind, and once the log and Stripe's
# idempotency-key retention had both lapsed, the same signed record could refund
# again). Created with noclobber so two runs cannot both create it; its absence is
# never read as "unused", and a marker directory that cannot be created or read
# REFUSES the write.
#
# The marker carries one state. `intent` is written before the money moves,
# `executed` after Stripe confirms, `failed` after Stripe refuses. ANY marker
# blocks an automatic retry: an ambiguous outcome is a person's to reconcile by
# reading the charge, not a second write's. That is why there is no "failed means
# try again" branch - the audit already refuses a retry after an intent line, and
# a rule only in the log is the bug this marker exists to fix.
machine_used_marker_path() { printf '%s/%s.json' "$MACHINE_APPROVAL_USED_DIR" "$MACHINE_RECORD_SHA"; }

machine_used_marker_state() {
  local marker state
  marker="$(machine_used_marker_path)"
  [ -e "$marker" ] || { printf 'none'; return 0; }
  state="$(jq -r '.state // empty' "$marker" 2>/dev/null)" || state=""
  printf '%s' "${state:-unreadable}"
}

machine_used_marker_require_absent() {
  local marker marker_state
  marker="$(machine_used_marker_path)"
  mkdir -p "$MACHINE_APPROVAL_USED_DIR" 2>/dev/null \
    || refuse "could not create the used-marker directory $MACHINE_APPROVAL_USED_DIR, so a repeat cannot be ruled out."
  [ -d "$MACHINE_APPROVAL_USED_DIR" ] \
    || refuse "the used-marker path $MACHINE_APPROVAL_USED_DIR is not a directory, so a repeat cannot be ruled out."
  marker_state="$(machine_used_marker_state)"
  [ "$marker_state" = "none" ] \
    || refuse "this approval record has already been started (used marker $marker, state '$marker_state'). Read the charge in Stripe before anything else: if no refund exists, no money moved and a named person may remove that marker to try again; if one does, this record is spent."
  return 0
}

# Written BEFORE the money moves, so a crash afterwards still leaves the record
# marked. noclobber makes the create atomic: exactly one run wins.
machine_used_marker_intent() {
  local marker tmp
  marker="$(machine_used_marker_path)"
  tmp="$marker.tmp.$$"
  jq -cn --arg state "intent" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg charge "$charge" --argjson cents "${MACHINE_AMOUNT:-0}" \
      '{state:$state, at:$at, charge:$charge, amount_cents:$cents}' >"$tmp" 2>/dev/null \
    || { rm -f "$tmp"; refuse "could not write the used marker $marker, so a repeat cannot be ruled out. Not moving money without it."; }
  ( set -o noclobber; cat -- "$tmp" >"$marker" ) 2>/dev/null || {
    rm -f "$tmp"
    refuse "this approval record has already been started (used marker $marker, state '$(machine_used_marker_state)'). Read the charge in Stripe before anything else."
  }
  rm -f "$tmp"
}

# The outcome, for the record and for whoever reconciles it. A failure to write
# this is loud but not fatal: the marker already says intent, and the Stripe
# idempotency key still blocks a duplicate.
machine_used_marker_settle() {
  local state="$1" refund_id="${2:-}" marker tmp
  marker="$(machine_used_marker_path)"
  tmp="$marker.tmp.$$"
  jq -cn --arg state "$state" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg charge "$charge" \
      --arg refund_id "$refund_id" --argjson cents "${MACHINE_AMOUNT:-0}" \
      '{state:$state, at:$at, charge:$charge, amount_cents:$cents, refund_id:$refund_id}' >"$tmp" 2>/dev/null \
    && mv -f -- "$tmp" "$marker" 2>/dev/null \
    || echo "MACHINE-USED-MARKER-UNWRITTEN (muso-stripe-write): the used marker $marker could not record '$state' for $charge (refund '${refund_id:-unknown}'). The record stays marked as started, which still blocks an automatic retry; the Stripe idempotency key machine-approval-$MACHINE_RECORD_SHA still blocks a duplicate." >&2
}

machine_path_still_on() {
  local now sw
  [ ! -e "$MACHINE_APPROVAL_KILL" ] \
    || refuse "machine-approved refunds were switched off while this run was in progress ($MACHINE_APPROVAL_KILL exists)."
  [ -d "$MACHINE_APPROVAL_DIR" ] && [ ! -L "$MACHINE_APPROVAL_DIR" ] \
    || refuse "machine-approved refunds were disarmed while this run was in progress ($MACHINE_APPROVAL_DIR is gone)."
  # The SECOND switch is re-read here for exactly the same reason (qa-review
  # 2026-11-16T10:34Z): the row in policies/ is a reviewed file, so an operator can
  # deploy enabled:false while this run waits up to a minute on the lock and reads
  # pages of charges, and an authorization read before the lock must not outlive the
  # switch that granted it. The full check runs below too, so a row that was
  # re-approved with different caps REFUSES the write instead of applying the caps
  # this process loaded at startup.
  sw="$(jq -r '.enabled // false' "$MACHINE_APPROVAL_REGISTRY" 2>/dev/null)" || sw=""
  [ "$sw" = "true" ] \
    || refuse "machine-approved refunds were switched off while this run was in progress ($MACHINE_APPROVAL_REGISTRY says enabled='$sw')."
  verify_machine_approval_registry
  now="$(sha256sum "${MACHINE_APPROVAL_LIVE:-$MACHINE_APPROVAL_FILE}" 2>/dev/null | awk '{print $1}')" || now=""
  [ -n "$now" ] && [ "$now" = "$MACHINE_RECORD_SHA" ] \
    || refuse "the approval record $MACHINE_APPROVAL_FILE was removed or changed while this run was in progress."
}

verify_machine_approval_signature() {
  local rec="$1" sig="$2"
  [ -r "$MACHINE_APPROVAL_SIGNERS" ] \
    || refuse "the reviewer key that must sign an approval record is not readable ($MACHINE_APPROVAL_SIGNERS), so no record can be verified. Nothing was written."
  [ -f "$sig" ] && [ -r "$sig" ] \
    || refuse "the approval record is not signed ($sig is missing). A record is an approval only when $MACHINE_APPROVAL_SIGNER_ID signs it in namespace $MACHINE_APPROVAL_NAMESPACE, and that key is not on this host. Nothing was written."
  command -v ssh-keygen >/dev/null 2>&1 \
    || refuse "ssh-keygen is not available, so the approval record signature cannot be checked. Nothing was written."
  ssh-keygen -Y verify -f "$MACHINE_APPROVAL_SIGNERS" -I "$MACHINE_APPROVAL_SIGNER_ID" \
      -n "$MACHINE_APPROVAL_NAMESPACE" -s "$sig" <"$rec" >/dev/null 2>&1 \
    || refuse "the approval record's signature is not a valid $MACHINE_APPROVAL_NAMESPACE signature by $MACHINE_APPROVAL_SIGNER_ID over these exact bytes ($rec). A record that was edited after signing, signed for another purpose, or signed by another key is not an approval. Nothing was written."
}

# The second switch. Arming used to mean only "an operator created
# /etc/hydra/refund-machine-approvals", which nobody reviews; qa-review asked for
# disarmament that does not depend on an operator not doing that (2026-11-15
# 14:49Z). So the row in policies/ has to name who approved the class and where,
# and the caps have to agree with both the row and this script's own constants.
verify_machine_approval_registry() {
  local enabled approved_by approval_ref cap_charge cap_customer
  [ -r "$MACHINE_APPROVAL_REGISTRY" ] \
    || refuse "the machine-approval switch file is missing or unreadable ($MACHINE_APPROVAL_REGISTRY), so this class is not armed. Nothing was written."
  enabled="$(jq -r '.enabled // false' "$MACHINE_APPROVAL_REGISTRY" 2>/dev/null)" || enabled=""
  approved_by="$(jq -r '.approved_by // empty' "$MACHINE_APPROVAL_REGISTRY" 2>/dev/null)" || approved_by=""
  approval_ref="$(jq -r '.approval_ref // empty' "$MACHINE_APPROVAL_REGISTRY" 2>/dev/null)" || approval_ref=""
  [ "$enabled" = "true" ] \
    || refuse "machine-approved refunds are not enabled ($MACHINE_APPROVAL_REGISTRY says enabled=$enabled). Turning this class on is a reviewed change that names who approved it, not a host action."
  [ -n "$approved_by" ] && [ -n "$approval_ref" ] \
    || refuse "machine-approved refunds are enabled in $MACHINE_APPROVAL_REGISTRY without approved_by and approval_ref. A class that spends money without a person's Slack id needs a named approval and where it was given. Nothing was written."
  cap_charge="$(jq -r '.cap_usd_per_refund // empty' "$MACHINE_APPROVAL_REGISTRY" 2>/dev/null)" || cap_charge=""
  cap_customer="$(jq -r '.cap_usd_per_customer_per_year // empty' "$MACHINE_APPROVAL_REGISTRY" 2>/dev/null)" || cap_customer=""
  [ "$cap_charge" = "$((MACHINE_REFUND_CAP_CENTS / 100))" ] && [ "$cap_customer" = "$((MACHINE_CUSTOMER_CAP_CENTS / 100))" ] \
    || refuse "the caps in $MACHINE_APPROVAL_REGISTRY ($cap_charge per refund / $cap_customer per customer) disagree with this wrapper ($((MACHINE_REFUND_CAP_CENTS / 100)) / $((MACHINE_CUSTOMER_CAP_CENTS / 100))). Nothing was written."
}

verify_machine_approval() {
  local charge="$1" real name ok a arg_amount="" arg_charge="" cjson refundable ljson already
  [ ! -e "$MACHINE_APPROVAL_KILL" ] || refuse "machine-approved refunds are switched off ($MACHINE_APPROVAL_KILL exists)."
  [ -d "$MACHINE_APPROVAL_DIR" ] && [ ! -L "$MACHINE_APPROVAL_DIR" ] \
    || refuse "machine-approved refunds are not armed on this host ($MACHINE_APPROVAL_DIR does not exist)."
  real="$(realpath -e -- "$MACHINE_APPROVAL_FILE" 2>/dev/null)" \
    || refuse "the approval record $MACHINE_APPROVAL_FILE cannot be read."
  name="${real##*/}"
  [ "$real" = "$MACHINE_APPROVAL_DIR/$name" ] && [ -f "$real" ] && [ "${name%.json}" != "$name" ] \
    || refuse "the approval record must be a .json file directly inside $MACHINE_APPROVAL_DIR."
  MACHINE_APPROVAL_FILE="$real"
  verify_machine_approval_registry
  [ -n "$charge" ] || refuse "a machine-approved refund must name the charge (-d charge=ch_...)."
  # ONE read, verified, then used. Verifying the path and reading it again later is
  # a TOCTOU: a process that can write the armed directory can swap a signed record
  # for another one after the check and before the jq that decides the amount
  # (qa-review 2026-11-15T12:22Z). The snapshot is what is signed, what is
  # validated, what the audit records, and what the lock-time re-check compares the
  # live file against.
  MACHINE_APPROVAL_SNAPSHOT="$(mktemp)" || refuse "could not make a private copy of the approval record."
  chmod 600 "$MACHINE_APPROVAL_SNAPSHOT" 2>/dev/null || true
  cat -- "$real" >"$MACHINE_APPROVAL_SNAPSHOT" 2>/dev/null \
    || refuse "the approval record $real could not be read into a private copy."
  MACHINE_APPROVAL_LIVE="$real"
  MACHINE_APPROVAL_FILE="$MACHINE_APPROVAL_SNAPSHOT"
  trap 'rm -f "$MACHINE_APPROVAL_SNAPSHOT"' EXIT
  verify_machine_approval_signature "$MACHINE_APPROVAL_SNAPSHOT" "$real.sig"
  # One amount, in one form. `amount=N` is the only spelling the wrapper can
  # compare with the record, so every other way stripe-cli accepts an amount
  # (`--amount 600`, `--amount=600`, `-damount=600`, `--data=amount=600`) is
  # refused rather than forwarded: the args ARE the request, so an amount the
  # wrapper did not check would move money the record did not approve while the
  # audit line still named the record's amount (qa-review 2026-11-15T12:10Z).
  for a in "${STRIPE_ARGS[@]}"; do
    case "$a" in
      charge=*)
        [ -z "$arg_charge" ] || refuse "the charge is given more than once."
        arg_charge="${a#charge=}" ;;
      *charge*)
        refuse "the charge must be passed as -d charge=<id>, and only that form. \"$a\" could select a charge the approval record was never checked against." ;;
      amount=*) 
        [ -z "$arg_amount" ] || refuse "the refund amount is given more than once."
        arg_amount="${a#amount=}" ;;
      *amount*)
        refuse "the refund amount must be passed as you would to a person: -d amount=<cents>, and only that form. \"$a\" cannot be compared with the approval record, so it could move an amount the record did not approve." ;;
      payment_intent=*) refuse "a machine-approved refund is by charge id only." ;;
      -i|--idempotency|--idempotency=*)
        refuse "a machine-approved refund sets its own idempotency key from the approval record; a caller-supplied one would let a second run of the same record create a second refund." ;;
      -i?*|--idempotency?*)
        refuse "a machine-approved refund sets its own idempotency key from the approval record; \"$a\" is not accepted." ;;
    esac
  done
  [ -z "$arg_charge" ] || [ "$arg_charge" = "$charge" ] \
    || refuse "the refund targets $charge but the request names $arg_charge."

  ok="$(jq -r --arg charge "$charge" --arg approvers "$MACHINE_APPROVERS" '
    def str: type == "string" and length > 0;
    if (type == "object")
       and .schema == "refund-machine-approval.v1"
       and (.approver | str) and ((.approver) as $a | ($approvers | split(" ") | index($a)) != null)
       and (.decision_ref | str)
       and .charge == $charge
       and (.customer | str)
       and (.amount_cents | type == "number" and . == floor and . > 0)
       and .currency == "usd"
       and (.keep_subscription | type == "boolean")
       and .legal_settlement == false and .formal_claim == false
       and .legal_threat == false
       and (.evidence | type == "object")
       and (.evidence.subscription_state | str) and (.evidence.prior_refunds | str)
       and (.evidence.caps | str)
       and (.evidence.service_failure | type == "object")
       and (.evidence.service_failure.from | str) and (.evidence.service_failure.to | str)
       and (.evidence.service_failure.query | str)
    then "ok" else "bad" end' "$MACHINE_APPROVAL_FILE" 2>/dev/null)" || ok="bad"
  [ "$ok" = "ok" ] || refuse "the approval record is not a valid refund-machine-approval.v1 for $charge (approver, decision_ref, customer, amount_cents, currency usd, keep_subscription, evidence, and legal_settlement / formal_claim / legal_threat all false are required). A legal settlement, a formal claim or a legal-action threat is a named human's decision."

  MACHINE_APPROVER="$(jq -r '.approver' "$MACHINE_APPROVAL_FILE")"
  MACHINE_AMOUNT="$(jq -r '.amount_cents' "$MACHINE_APPROVAL_FILE")"
  MACHINE_CUSTOMER="$(jq -r '.customer' "$MACHINE_APPROVAL_FILE")"
  [ "$(jq -r '.keep_subscription' "$MACHINE_APPROVAL_FILE")" = "true" ] && MACHINE_KEEP_SUB=1
  MACHINE_RECORD_SHA="$(sha256sum "$MACHINE_APPROVAL_FILE" | awk '{print $1}')"
  [ -n "$MACHINE_RECORD_SHA" ] || refuse "could not hash the approval record."

  [ "$MACHINE_AMOUNT" -le "$MACHINE_REFUND_CAP_CENTS" ] \
    || refuse "$MACHINE_AMOUNT cents is above the machine cap of $MACHINE_REFUND_CAP_CENTS cents per refund. Above the cap a named human decides."

  # One record, one refund. The lock is held from the used-check through the
  # Stripe call and its outcome line, so two concurrent runs (of this record or
  # of another record for the same customer) cannot both pass the caps against
  # a pre-refund view of the customer.
  MACHINE_AUDIT_LOCK="${MACHINE_APPROVAL_AUDIT}.lock"
  mkdir -p "$(dirname "$MACHINE_AUDIT_LOCK")" 2>/dev/null \
    || refuse "could not create the machine-approval audit directory, so a repeat cannot be ruled out."
  exec 9>>"$MACHINE_AUDIT_LOCK" \
    || refuse "could not open the machine-approval lock $MACHINE_AUDIT_LOCK, so a repeat cannot be ruled out."
  flock -x -w 60 9 \
    || refuse "could not take the machine-approval lock $MACHINE_AUDIT_LOCK, so a repeat cannot be ruled out."
  if [ -e "$MACHINE_APPROVAL_AUDIT" ]; then
    [ -r "$MACHINE_APPROVAL_AUDIT" ] || refuse "the machine-approval audit file cannot be read, so a repeat cannot be ruled out."
    # Consume the WHOLE stream. `grep -q` exits at the first match, which sends
    # SIGPIPE to the upstream grep; under `pipefail` the pipeline then returns
    # 141 and this `if` reads a USED record as unused. An audit line carries the
    # record verbatim, so a record with a large evidence block produces
    # multi-100 KB lines and hits that window reliably (qa-review, 2026-11-15).
    used="$(grep -F "\"record_sha256\":\"$MACHINE_RECORD_SHA\"" "$MACHINE_APPROVAL_AUDIT" 2>/dev/null \
            | grep -c '"phase":"\(intent\|executed\)"' 2>/dev/null)" || true
    case "$used" in
      ''|*[!0-9]*)
        refuse "the machine-approval audit could not be counted unambiguously ($MACHINE_APPROVAL_AUDIT), so a repeat cannot be ruled out." ;;
      0) : ;;
      *)
        refuse "this approval record has already been used (see $MACHINE_APPROVAL_AUDIT). If no outcome line follows its intent, the earlier run may have moved the money: read the charge in Stripe before anything else." ;;
    esac
  fi

  # The facts, from Stripe.
  cjson="$("$STRIPE_BIN" charges retrieve "$charge" 2>/dev/null)" \
    || refuse "could not read $charge from Stripe, so the approval record cannot be checked."
  ok="$(printf '%s' "$cjson" | jq -r --arg cus "$MACHINE_CUSTOMER" '
    if (type == "object") and .customer == $cus and .currency == "usd" and .paid == true
       and .disputed == false
       and (.amount | type == "number") and (.amount_refunded | type == "number")
    then "ok" else "bad" end' 2>/dev/null)" || ok="bad"
  [ "$ok" = "ok" ] || refuse "Stripe does not show $charge as a paid, undisputed USD charge of $MACHINE_CUSTOMER (or the read was incomplete). A disputed or non-USD charge is a named human's decision."
  refundable="$(printf '%s' "$cjson" | jq -r '.amount - .amount_refunded')"
  if [ -n "$arg_amount" ]; then
    [ "$arg_amount" = "$MACHINE_AMOUNT" ] || refuse "the refund amount ($arg_amount) is not the amount the record approves ($MACHINE_AMOUNT)."
    [ "$MACHINE_AMOUNT" -le "$refundable" ] || refuse "the record approves $MACHINE_AMOUNT cents but only $refundable remain refundable on $charge."
  else
    [ "$MACHINE_AMOUNT" -eq "$refundable" ] || refuse "no amount= was given, so Stripe would refund the remaining $refundable cents, and the record approves $MACHINE_AMOUNT."
  fi

  # The customer cap is checked against everything Stripe shows refunded to this
  # customer, not just the last year: stricter than the rule. EVERY page is read
  # before the comparison. A total taken from one page fails open on exactly the
  # long-lived customers the cap exists for, so the walk ends only when Stripe
  # says has_more is false: a page that does not say so is not the last page.
  local page pages=0 cursor="" p_sum p_more p_last
  already=0
  while :; do
    pages=$((pages + 1))
    [ "$pages" -le "$MACHINE_CHARGE_PAGE_LIMIT" ] \
      || refuse "$MACHINE_CUSTOMER's charges did not end within $MACHINE_CHARGE_PAGE_LIMIT pages, so the total already refunded cannot be established. A named human decides."
    if [ -n "$cursor" ]; then
      ljson="$("$STRIPE_BIN" charges list --customer "$MACHINE_CUSTOMER" --limit 100 --starting-after "$cursor" 2>/dev/null)" \
        || refuse "could not list $MACHINE_CUSTOMER's charges (page $pages), so the customer cap cannot be checked."
    else
      ljson="$("$STRIPE_BIN" charges list --customer "$MACHINE_CUSTOMER" --limit 100 2>/dev/null)" \
        || refuse "could not list $MACHINE_CUSTOMER's charges, so the customer cap cannot be checked."
    fi
    # A row without a numeric refund total is an incomplete read, not a zero: a
    # missing field must never make an already-refunded customer look untouched.
    page="$(printf '%s' "$ljson" | jq -r '
      if (.data | type) != "array" then "shape"
      elif ([.data[] | ((.amount_refunded | type) == "number") and (.amount_refunded >= 0)
                       and (.amount_refunded == (.amount_refunded | floor))] | all | not) then "rows"
      elif (.has_more | type) != "boolean" then "more"
      elif .has_more and (((.data | length) == 0) or ((.data[-1].id | type) != "string")) then "more"
      else "ok \(.data | length) \([.data[].amount_refunded] | add // 0) \(.has_more) \(.data[-1].id // "-")" end' 2>/dev/null)" || page="shape"
    case "$page" in
      "ok "*) ;;
      rows) refuse "could not read $MACHINE_CUSTOMER's refund totals from Stripe, so the customer cap cannot be checked. A named human decides." ;;
      more) refuse "Stripe did not confirm the end of $MACHINE_CUSTOMER's charge list (page $pages), so the total already refunded cannot be established. A named human decides." ;;
      *) refuse "could not read $MACHINE_CUSTOMER's charges, so the customer cap cannot be checked." ;;
    esac
    read -r _ _ p_sum p_more p_last <<<"$page"
    case "$p_sum" in ''|*[!0-9]*) refuse "could not read $MACHINE_CUSTOMER's refund totals from Stripe, so the customer cap cannot be checked. A named human decides." ;; esac
    already=$((already + p_sum))
    [ "$p_more" = "true" ] || break
    # A cursor that does not move would re-read the same page for ever.
    [ "$p_last" != "$cursor" ] \
      || refuse "Stripe returned the same page of $MACHINE_CUSTOMER's charges twice, so the total already refunded cannot be established. A named human decides."
    cursor="$p_last"
  done
  [ $((already + MACHINE_AMOUNT)) -le "$MACHINE_CUSTOMER_CAP_CENTS" ] \
    || refuse "$MACHINE_CUSTOMER has $already cents refunded already; $MACHINE_AMOUNT more passes the machine cap of $MACHINE_CUSTOMER_CAP_CENTS cents per customer. Above the cap a named human decides."

  MACHINE_APPROVED=1
  echo "AUTHORIZED-MACHINE (muso-stripe-write): $MACHINE_APPROVER record ${MACHINE_RECORD_SHA:0:12} approves $MACHINE_AMOUNT cents on $charge ($already cents refunded to $MACHINE_CUSTOMER before this)." >&2
}

# Split override flags out of the stripe args (stripe must never see them).
STRIPE_ARGS=()
OVERRIDE_CONFIRMED_BY=""
KEEP_SUB_CONFIRMED_BY=""
KEEP_CREDIT_CONFIRMED_BY=""
APPROVAL_MSG_ID=""
MACHINE_APPROVAL_FILE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --machine-approval)
      [ "$#" -ge 2 ] || { echo "usage: --machine-approval needs a record file" >&2; exit 2; }
      MACHINE_APPROVAL_FILE="$2"; shift 2 ;;
    --override-confirmed-by)
      [ "$#" -ge 2 ] || { echo "usage: --override-confirmed-by needs a value" >&2; exit 2; }
      OVERRIDE_CONFIRMED_BY="$2"; shift 2 ;;
    --keep-subscription-confirmed-by)
      [ "$#" -ge 2 ] || { echo "usage: --keep-subscription-confirmed-by needs a value" >&2; exit 2; }
      KEEP_SUB_CONFIRMED_BY="$2"; shift 2 ;;
    --keep-credit-confirmed-by)
      [ "$#" -ge 2 ] || { echo "usage: --keep-credit-confirmed-by needs a value" >&2; exit 2; }
      KEEP_CREDIT_CONFIRMED_BY="$2"; shift 2 ;;
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

if [ -n "$MACHINE_APPROVAL_FILE" ] && { [ -n "$OVERRIDE_CONFIRMED_BY" ] || [ -n "$KEEP_SUB_CONFIRMED_BY" ]; }; then
  echo "usage: --machine-approval cannot be combined with --override-confirmed-by or --keep-subscription-confirmed-by (one approver per refund)" >&2
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
# gate, the no-paid-access-after-refund gate, and the no-double-concession gate.
#
# ORDER IS LOAD-BEARING: the credit gate runs LAST because cancelling a
# subscription is itself what mints proration credit. Run it before the
# paid-access gate and it would read a pre-cancel balance, then the agent's
# cancel would mint the very credit we just cleared. Running it last means each
# retry surfaces the next real blocker rather than a stale one.
if is_refund_create; then
  charge=""
  for a in "${STRIPE_ARGS[@]}"; do
    case "$a" in charge=*) charge="${a#charge=}" ;; esac
  done
  if [ -n "$MACHINE_APPROVAL_FILE" ]; then
    verify_machine_approval "$charge"
  fi
  # A verified machine record stands in for the one-time override, and for the
  # keep-subscription waiver only when it says so. Nothing stands in for the
  # double-concession gate.
  if [ "$MACHINE_APPROVED" -eq 0 ]; then
    enforce_refund_one_time_gate "$charge" "$OVERRIDE_CONFIRMED_BY" "$APPROVAL_MSG_ID"
  fi
  if [ "$MACHINE_APPROVED" -eq 0 ] || [ "$MACHINE_KEEP_SUB" -eq 0 ]; then
    enforce_no_paid_access_gate "$charge" "$KEEP_SUB_CONFIRMED_BY" "$APPROVAL_MSG_ID"
  fi
  enforce_no_double_concession_gate "$charge" "$KEEP_CREDIT_CONFIRMED_BY" "$APPROVAL_MSG_ID"

  # Healthy + authorized → run the refund, then RE-CHECK.
  #
  # A pre-write gate structurally cannot catch the audit's own chronology: on
  # 2025-12-05 the $107.50 refund landed at 06:53:35Z and Stripe minted the
  # $117.72 proration credit 0.96h LATER. There was no credit to see at gate
  # time. So for refunds we give up `exec` and verify after the fact.
  #
  # This EXITS 0 on a live post-refund credit, deliberately. The refund has
  # already succeeded; a non-zero exit here is exactly the shape that invites a
  # blind retry of a non-idempotent money write, which operations/SOUL.md names
  # as a top failure mode. The signal is a greppable stderr token plus explicit
  # do-not-re-run wording. The durable backstop for this class is the recurring
  # detector, not an exit code.
  # `|| rc=$?` and not a bare `rc=$?`: under `set -e` a failing stripe write would
  # abort the script before the assignment ever ran, losing the real exit code.
  rc=0
  if [ "$MACHINE_APPROVED" -eq 1 ]; then
    # Intent, write, outcome. No audit line, no refund. The switch-off is read
    # again here, under the lock, as the last thing before the money path.
    machine_path_still_on
    machine_used_marker_require_absent
    machine_used_marker_intent
    machine_audit intent "$charge" \
      || refuse "could not write the machine-approval audit line to $MACHINE_APPROVAL_AUDIT. Not moving money without a record of who approved it."
    # The key is the record's sha, so a replay is deduplicated by Stripe itself -
    # the one used-marker that no process on this host can delete. `--` not needed:
    # Stripe CLI accepts a global `-i`, and this array is ours, not the caller's.
    out="$("$STRIPE_BIN" "${STRIPE_ARGS[@]}" -i "machine-approval-$MACHINE_RECORD_SHA")" || rc=$?
    printf '%s\n' "$out"
    if [ "$rc" -eq 0 ]; then
      refund_id="$(printf '%s' "$out" | jq -r '.id // empty' 2>/dev/null || true)"
      machine_used_marker_settle executed "$refund_id"
      machine_audit executed "$charge" "$refund_id" "$rc" \
        || echo "MACHINE-AUDIT-UNWRITTEN (muso-stripe-write): the refund on $charge DID happen — do NOT re-run it. Its outcome line could not be written to $MACHINE_APPROVAL_AUDIT; record refund '${refund_id:-unknown}' by hand." >&2
    else
      machine_used_marker_settle failed
      machine_audit failed "$charge" "" "$rc" || true
    fi
    machine_audit_unlock
  else
    "$STRIPE_BIN" "${STRIPE_ARGS[@]}" || rc=$?
  fi
  [ "$rc" -eq 0 ] || exit "$rc"
  if [ "$CREDIT_WAIVER_AUTHORIZED" -eq 0 ]; then
    post_cust=""
    if ! post_cust="$(charge_customer_id "$charge")"; then
      # The money HAS moved. A failed lookup here must not be silent, or an
      # already-paid refund looks clean and nobody ever checks the balance.
      echo "POST-REFUND-CREDIT-UNVERIFIED (muso-stripe-write): the refund on $charge DID happen — do NOT re-run it. Could not resolve the customer afterwards, so a double concession could not be ruled out; check the customer's balance by hand." >&2
    else
      if post_credit="$(customer_live_proration_credit "$post_cust")"; then
        if [ -n "$post_credit" ]; then
          echo "POST-REFUND-CREDIT-LIVE (muso-stripe-write): the refund on $charge DID happen — do NOT re-run it. Customer $post_cust now holds a live concession credit (balance $post_credit), which Stripe may have minted during the refund. That is a double concession until you clear it. $(zero_credit_instructions "$post_cust" "${post_credit%% *}" "$charge")" >&2
        fi
      else
        echo "POST-REFUND-CREDIT-UNVERIFIED (muso-stripe-write): the refund on $charge DID happen — do NOT re-run it. Could not read $post_cust's credit balance afterwards; check it by hand for a double concession." >&2
      fi
    fi
  fi
  exit 0
fi

[ -z "$MACHINE_APPROVAL_FILE" ] || refuse "--machine-approval covers a refund create only."

# Healthy + authorized → run the real Stripe write (waiver flags stripped).
exec "$STRIPE_BIN" "${STRIPE_ARGS[@]}"
