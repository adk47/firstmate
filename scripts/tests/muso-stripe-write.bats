#!/usr/bin/env bats
# Tests for muso-stripe-write.sh — the codex-health gate on Stripe writes, plus the
# refund one-time-policy override gate.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  WRAPPER="$REPO_ROOT/scripts/muso-stripe-write.sh"
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  # Smart `stripe` stub:
  #  - `charges retrieve <ch>`   → JSON with a customer + invoice (empty when STUB_BROKEN=1,
  #                                invoice:null when STUB_NO_INVOICE=1)
  #  - `charges list ...`        → list whose data has a refunded charge iff STUB_PRIOR_REFUNDS>0
  #  - `invoices retrieve <in>`  → JSON with a subscription (null when STUB_ONEOFF_INVOICE=1,
  #                                empty when STUB_INVOICE_BROKEN=1)
  #  - `subscriptions list ...`  → canceled-only by default; active-like iff STUB_ACTIVE_SUBS=1;
  #                                full page of canceled iff STUB_SUBS_FULL_PAGE=1;
  #                                empty when STUB_SUBS_BROKEN=1
  #  - `customers retrieve <cus>`→ balance 0 by default; STUB_CREDIT_BALANCE sets it (cents,
  #                                negative = credit); empty when STUB_CUSTOMER_BROKEN=1;
  #                                balance key absent when STUB_CUSTOMER_NO_BALANCE_KEY=1.
  #                                After a refund has run, STUB_POST_REFUND_CREDIT=1 makes the
  #                                SECOND read return a credit the first read did not show —
  #                                Stripe minting proration during the refund (the 2025-12-05
  #                                chronology the pre-write gate structurally cannot see).
  #  - `get /v1/customers/<cus>/balance_transactions`
  #                              → one live credit of type $STUB_CBT_TYPE (default
  #                                invoice_too_small, untagged); a TAGGED adjustment (i.e. one
  #                                of our own referral writes) iff STUB_CBT_TAGGED=1; a credit
  #                                already spent past an ending_balance:0 boundary iff
  #                                STUB_CBT_SPENT=1; empty when STUB_CBT_BROKEN=1; a full page
  #                                with no zero boundary iff STUB_CBT_FULL_PAGE=1
  #  - anything else (e.g. `refunds create`) → echo STRIPE_CALLED so we can assert pass-through
  cat >"$BIN/stripe" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "charges retrieve")
    if [ "${STUB_POST_CHARGE_BROKEN:-0}" -gt 0 ] && [ -f "$STUB_STATE_DIR/refunded" ]; then echo ""
    elif [ "${STUB_BROKEN:-0}" -gt 0 ]; then echo ""
    elif [ "${STUB_CHARGE_NO_INVOICE_KEY:-0}" -gt 0 ]; then echo '{"customer":"cus_TEST"}'
    elif [ "${STUB_NO_INVOICE:-0}" -gt 0 ]; then echo '{"customer":"cus_TEST","invoice":null}'
    else echo '{"customer":"cus_TEST","invoice":"in_TEST"}'; fi
    ;;
  "invoices retrieve")
    if [ "${STUB_INVOICE_BROKEN:-0}" -gt 0 ]; then echo ""
    elif [ "${STUB_INVOICE_NO_SUB_KEY:-0}" -gt 0 ]; then echo '{"id":"in_TEST"}'
    elif [ "${STUB_ONEOFF_INVOICE:-0}" -gt 0 ]; then echo '{"subscription":null}'
    else echo '{"subscription":"sub_TEST"}'; fi
    ;;
  "subscriptions list")
    if [ "${STUB_SUBS_BROKEN:-0}" -gt 0 ]; then
      echo ""
    elif [ "${STUB_ACTIVE_SUBS:-0}" -gt 0 ]; then
      # One hard-canceled sub plus one active-but-cancel_at_period_end sub: the
      # latter still grants paid access, so the gate must treat it as exposure.
      echo '{"object":"list","data":[{"id":"sub_OLD","status":"canceled","cancel_at_period_end":false},{"id":"sub_LIVE","status":"active","cancel_at_period_end":true}]}'
    elif [ "${STUB_SUBS_FULL_PAGE:-0}" -gt 0 ]; then
      printf '{"object":"list","data":['
      for i in $(seq 1 100); do [ "$i" -gt 1 ] && printf ','; printf '{"id":"sub_%d","status":"canceled"}' "$i"; done
      printf ']}\n'
    else
      echo '{"object":"list","data":[{"id":"sub_OLD","status":"canceled"}]}'
    fi
    ;;
  "charges list")
    if [ "${STUB_PRIOR_REFUNDS:-0}" -gt 0 ]; then
      echo '{"object":"list","data":[{"id":"ch_old","amount_refunded":875}]}'
    elif [ "${STUB_FULL_PAGE:-0}" -gt 0 ]; then
      # A full page (100) of charges, none refunded → the gate must treat this as
      # "cannot rule out an older prior refund" and fail closed.
      printf '{"object":"list","data":['
      for i in $(seq 1 100); do [ "$i" -gt 1 ] && printf ','; printf '{"id":"ch_%d","amount_refunded":0}' "$i"; done
      printf ']}\n'
    else
      echo '{"object":"list","data":[{"id":"ch_X","amount_refunded":0}]}'
    fi
    ;;
  "customers retrieve")
    if [ "${STUB_CUSTOMER_BROKEN:-0}" -gt 0 ]; then echo ""
    elif [ "${STUB_CUSTOMER_NO_BALANCE_KEY:-0}" -gt 0 ]; then echo '{"id":"cus_TEST"}'
    elif [ "${STUB_POST_REFUND_CREDIT:-0}" -gt 0 ] && [ -f "$STUB_STATE_DIR/refunded" ]; then
      # Credit appears only AFTER the refund ran — the auto-mint chronology.
      echo '{"id":"cus_TEST","balance":-11772}'
    else
      echo "{\"id\":\"cus_TEST\",\"balance\":${STUB_CREDIT_BALANCE:-0}}"
    fi
    ;;
  "get /v1/customers/cus_TEST/balance_transactions")
    if [ "${STUB_CBT_MALFORMED:-0}" -gt 0 ]; then
      # Well-formed JSON, well-formed list, but the row is missing `amount`.
      echo '{"object":"list","data":[{"id":"cbtxn_BAD","type":"invoice_too_small","ending_balance":-11772,"created":1,"metadata":{}}]}'
    elif [ "${STUB_CBT_BROKEN:-0}" -gt 0 ]; then
      echo ""
    elif [ "${STUB_CBT_FULL_PAGE:-0}" -gt 0 ]; then
      printf '{"object":"list","data":['
      for i in $(seq 1 100); do [ "$i" -gt 1 ] && printf ','
        printf '{"id":"cbtxn_%d","type":"applied_to_invoice","amount":100,"ending_balance":-11772,"created":1}' "$i"; done
      printf ']}\n'
    elif [ "${STUB_CBT_SPENT:-0}" -gt 0 ]; then
      # The proration credit sits BEHIND a return-to-zero, so it is spent and must
      # not block anything; the live window holds only a tagged referral credit.
      echo '{"object":"list","data":[
        {"id":"cbtxn_REF","type":"adjustment","amount":-2000,"ending_balance":-2000,"created":1,"metadata":{"referralId":"r1"}},
        {"id":"cbtxn_ZERO","type":"applied_to_invoice","amount":11772,"ending_balance":0,"created":1},
        {"id":"cbtxn_OLD","type":"invoice_too_small","amount":-11772,"ending_balance":-11772,"created":1}]}'
    elif [ "${STUB_CBT_TAGGED:-0}" -gt 0 ]; then
      echo '{"object":"list","data":[{"id":"cbtxn_REF","type":"adjustment","amount":-11772,"ending_balance":-11772,"created":1,"metadata":{"referralId":"r1"}}]}'
    else
      echo "{\"object\":\"list\",\"data\":[{\"id\":\"cbtxn_LIVE\",\"type\":\"${STUB_CBT_TYPE:-invoice_too_small}\",\"amount\":-11772,\"ending_balance\":-11772,\"created\":1,\"metadata\":{}}]}"
    fi
    ;;
  *)
    # Mark that a refund actually ran, so the customers-retrieve arm can model a
    # credit that only exists post-write.
    case "$1 $2" in "refunds create") : >"$STUB_STATE_DIR/refunded" ;; esac
    echo "STRIPE_CALLED $*"
    ;;
esac
SH
  chmod +x "$BIN/stripe"
  export STRIPE_BIN="$BIN/stripe"
  export OPENCLAW_GATEWAY_UNIT="test-unit"
  STUB_STATE_DIR="$BATS_TEST_TMPDIR/stub-state"
  mkdir -p "$STUB_STATE_DIR"
  export STUB_STATE_DIR
}

# Helper: install a fake `journalctl` on PATH that emits $1 and exits $2.
fake_journalctl() {
  local out="$1" code="${2:-0}"
  cat >"$BIN/journalctl" <<SH
#!/usr/bin/env bash
printf '%s' "$out"
exit $code
SH
  chmod +x "$BIN/journalctl"
  export PATH="$BIN:$PATH"
}

healthy() { fake_journalctl "Jun 09 10:00:00 node-8 openclaw[1]: message processed: outcome=ok" 0; }

@test "healthy journal + first refund -> executes the stripe write (pass-through)" {
  healthy
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 0 ]
  [[ "$output" == *"STRIPE_CALLED refunds create -d charge=ch_X --confirm"* ]]
}

@test "degraded journal (refresh_token_reused) -> REFUSES, stripe not called" {
  fake_journalctl "Jun 09 10:00:01 node-8 openclaw[1]: OpenAI Codex token refresh failed (401): code=refresh_token_reused" 0
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"DEGRADED"* ]]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

@test "degraded journal (reason=auth_permanent) -> REFUSES" {
  fake_journalctl "Jun 09 10:00:02 node-8 openclaw[1]: [model-fallback/decision] reason=auth_permanent next=openrouter/openai/gpt-5.4-mini" 0
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

@test "degraded journal (auth token invalidated) -> REFUSES" {
  fake_journalctl "Jun 09 10:00:03 node-8 openclaw[1]: authentication token has been invalidated" 0
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"REFUSED"* ]]
}

@test "journald unreadable (non-zero exit) -> FAIL-CLOSED refuse" {
  fake_journalctl "" 1
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"unverifiable"* ]]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

@test "empty-but-readable window + first refund -> healthy-quiet, executes" {
  fake_journalctl "" 0
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 0 ]
  [[ "$output" == *"STRIPE_CALLED refunds create"* ]]
}

@test "no args -> usage error (exit 2), nothing executed" {
  healthy
  run "$WRAPPER"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

@test "missing codex-health lib -> refuse" {
  healthy
  CODEX_HEALTH_LIB="/nonexistent/codex-health.sh" run "$WRAPPER" refunds create -d "charge=ch_X"
  [ "$status" -eq 3 ]
  [[ "$output" == *"codex-health lib"* ]]
}

# --- Refund one-time-policy override gate ------------------------------------

@test "repeat refund WITHOUT override token -> REFUSED, stripe refunds create not called" {
  healthy
  STUB_PRIOR_REFUNDS=1 run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"prior refund"* ]]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

@test "repeat refund WITH valid allowlisted token -> executes, override flags stripped" {
  healthy
  STUB_PRIOR_REFUNDS=1 run "$WRAPPER" refunds create -d "charge=ch_X" --confirm \
    --override-confirmed-by U038BM16T7W --approval-msg-id 1777474838.796239
  [ "$status" -eq 0 ]
  [[ "$output" == *"STRIPE_CALLED refunds create -d charge=ch_X --confirm"* ]]
  # The override flags must NOT be forwarded to stripe.
  [[ "$output" != *"--override-confirmed-by"* ]]
  [[ "$output" != *"--approval-msg-id"* ]]
}

@test "repeat refund WITH non-allowlisted approver -> REFUSED" {
  healthy
  STUB_PRIOR_REFUNDS=1 run "$WRAPPER" refunds create -d "charge=ch_X" --confirm \
    --override-confirmed-by U_RANDOM --approval-msg-id 1777474838.796239
  [ "$status" -eq 3 ]
  [[ "$output" == *"not on the god-mode allowlist"* ]]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

@test "repeat refund WITH token but missing approval-msg-id -> REFUSED" {
  healthy
  STUB_PRIOR_REFUNDS=1 run "$WRAPPER" refunds create -d "charge=ch_X" --confirm \
    --override-confirmed-by U038BM16T7W
  [ "$status" -eq 3 ]
  [[ "$output" == *"prior refund"* ]]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

@test "refund history unverifiable (Stripe read fails) -> FAIL-CLOSED refuse" {
  healthy
  STUB_BROKEN=1 run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"couldn't verify refund history"* ]]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

# NOTE: this used to assert pass-through of `customers retrieve cus_TEST`, which only
# worked because the stub had no arm for it and fell through to the STRIPE_CALLED
# catch-all. The double-concession gate needs a REAL `customers retrieve` arm, so this
# now uses a different non-refund write. `subscriptions cancel` is a better subject
# anyway: it is an actual command from the refund doctrine (cancel-then-refund) and is
# unambiguously a write, so this still pins "only refund-creates get the refund gates".
@test "non-refund stripe write is unaffected by the refund gate" {
  healthy
  run "$WRAPPER" subscriptions cancel sub_TEST --confirm
  [ "$status" -eq 0 ]
  [[ "$output" == *"STRIPE_CALLED subscriptions cancel sub_TEST --confirm"* ]]
}

# --- Hardening: value-less flag, non-canonical refund forms, page-fullness ---

@test "value-less trailing --override-confirmed-by -> usage error (exit 2), not silent" {
  healthy
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm --override-confirmed-by
  [ "$status" -eq 2 ]
  [[ "$output" == *"needs a value"* ]]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

@test "raw API refund form (post /v1/refunds) on a repeat refund is still gated -> REFUSED" {
  healthy
  STUB_PRIOR_REFUNDS=1 run "$WRAPPER" post /v1/refunds -d "charge=ch_X"
  [ "$status" -eq 3 ]
  [[ "$output" == *"prior refund"* ]]
  [[ "$output" != *"STRIPE_CALLED post"* ]]
}

@test "global flag before subcommand (--color off refunds create) repeat is still gated -> REFUSED" {
  healthy
  STUB_PRIOR_REFUNDS=1 run "$WRAPPER" --color off refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"prior refund"* ]]
}

@test "full charge page with no visible refund -> FAIL-CLOSED (cannot rule out prior), REFUSED" {
  healthy
  STUB_FULL_PAGE=1 run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"prior refund"* ]]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

@test "full charge page WITH valid allowlisted override token -> executes" {
  healthy
  STUB_FULL_PAGE=1 run "$WRAPPER" refunds create -d "charge=ch_X" --confirm \
    --override-confirmed-by U0AL36NADEY --approval-msg-id 1777474838.796239
  [ "$status" -eq 0 ]
  [[ "$output" == *"STRIPE_CALLED refunds create -d charge=ch_X --confirm"* ]]
}

# --- No-paid-access-after-refund gate -----------------------------------------
# A refund of a subscription charge must not leave the customer with an
# active-like subscription (active/trialing/past_due/unpaid — including
# cancel_at_period_end=true, which still grants access until period end).

@test "sub charge + active-like sub remains, no keep token -> REFUSED with cancel-first instruction" {
  healthy
  STUB_ACTIVE_SUBS=1 run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"sub_LIVE"* ]]
  [[ "$output" == *"subscriptions cancel"* ]]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

@test "sub charge + active sub + valid allowlisted keep token -> executes, keep flags stripped" {
  healthy
  STUB_ACTIVE_SUBS=1 run "$WRAPPER" refunds create -d "charge=ch_X" --confirm \
    --keep-subscription-confirmed-by U038BM16T7W --approval-msg-id 1777474838.796239
  [ "$status" -eq 0 ]
  [[ "$output" == *"AUTHORIZED-KEEP"* ]]
  [[ "$output" == *"STRIPE_CALLED refunds create -d charge=ch_X --confirm"* ]]
  [[ "$output" != *"--keep-subscription-confirmed-by"* ]]
}

@test "sub charge + active sub + NON-allowlisted keep approver -> REFUSED" {
  healthy
  STUB_ACTIVE_SUBS=1 run "$WRAPPER" refunds create -d "charge=ch_X" --confirm \
    --keep-subscription-confirmed-by U_RANDOM --approval-msg-id 1777474838.796239
  [ "$status" -eq 3 ]
  [[ "$output" == *"not on the god-mode allowlist"* ]]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

@test "sub charge + active sub + keep token but missing approval-msg-id -> REFUSED" {
  healthy
  STUB_ACTIVE_SUBS=1 run "$WRAPPER" refunds create -d "charge=ch_X" --confirm \
    --keep-subscription-confirmed-by U038BM16T7W
  [ "$status" -eq 3 ]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

@test "non-subscription charge (no invoice) is exempt even with active subs -> executes" {
  healthy
  STUB_NO_INVOICE=1 STUB_ACTIVE_SUBS=1 run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 0 ]
  [[ "$output" == *"STRIPE_CALLED refunds create -d charge=ch_X --confirm"* ]]
}

@test "one-off invoice charge (no subscription on invoice) is exempt -> executes" {
  healthy
  STUB_ONEOFF_INVOICE=1 STUB_ACTIVE_SUBS=1 run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 0 ]
  [[ "$output" == *"STRIPE_CALLED refunds create -d charge=ch_X --confirm"* ]]
}

@test "charge object MISSING the invoice key (API drift / error shape) -> FAIL-CLOSED refuse, not EXEMPT" {
  healthy
  STUB_CHARGE_NO_INVOICE_KEY=1 run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"subscription state"* ]]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

@test "invoice object MISSING the subscription key (API drift) -> FAIL-CLOSED refuse, not EXEMPT" {
  healthy
  STUB_INVOICE_NO_SUB_KEY=1 run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"subscription state"* ]]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

@test "invoice read broken (empty) -> FAIL-CLOSED refuse, not silently exempt" {
  healthy
  STUB_INVOICE_BROKEN=1 run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"subscription state"* ]]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

@test "subscriptions list broken (empty) -> FAIL-CLOSED refuse" {
  healthy
  STUB_SUBS_BROKEN=1 run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"subscription state"* ]]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

@test "full subscriptions page with none active-like -> FAIL-CLOSED refuse (cannot rule out)" {
  healthy
  STUB_SUBS_FULL_PAGE=1 run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 3 ]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

@test "value-less trailing --keep-subscription-confirmed-by -> usage error (exit 2)" {
  healthy
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm --keep-subscription-confirmed-by
  [ "$status" -eq 2 ]
  [[ "$output" == *"needs a value"* ]]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

@test "repeat refund + active sub with BOTH override and keep tokens -> executes" {
  healthy
  STUB_PRIOR_REFUNDS=1 STUB_ACTIVE_SUBS=1 run "$WRAPPER" refunds create -d "charge=ch_X" --confirm \
    --override-confirmed-by U038BM16T7W --keep-subscription-confirmed-by U038BM16T7W \
    --approval-msg-id 1777474838.796239
  [ "$status" -eq 0 ]
  [[ "$output" == *"AUTHORIZED-OVERRIDE"* ]]
  [[ "$output" == *"AUTHORIZED-KEEP"* ]]
  [[ "$output" == *"STRIPE_CALLED refunds create -d charge=ch_X --confirm"* ]]
}

@test "keep token alone does NOT waive the one-time policy on a repeat refund -> REFUSED" {
  healthy
  STUB_PRIOR_REFUNDS=1 STUB_ACTIVE_SUBS=1 run "$WRAPPER" refunds create -d "charge=ch_X" --confirm \
    --keep-subscription-confirmed-by U038BM16T7W --approval-msg-id 1777474838.796239
  [ "$status" -eq 3 ]
  [[ "$output" == *"prior refund"* ]]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

# --- No-double-concession gate (cash refund on top of a live credit) ----------
#
# NOTE ON STYLE: these cases `export` their STUB_* knobs in the test body rather
# than using the `VAR=x run ...` prefix the older cases use. That prefix is not
# reliably delivered to the stub under a full-suite run, and a flake here would
# flake toward "refund allowed", which is the wrong direction to be lucky in.

@test "sub charge + live proration credit, no keep-credit token -> REFUSED with zeroing instruction" {
  healthy
  export STUB_CREDIT_BALANCE=-11772
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"DOUBLE concession"* ]]
  [[ "$output" == *"balance_transactions"* ]]
  # The verification must target the CONCESSION, not the balance. A customer can
  # legitimately retain tagged referral/offer credit, so "balance must be 0"
  # instructs the operator to claw back money that was never a duplicate.
  [[ "$output" == *"customer_live_concession_amount"* ]]
  [[ "$output" != *"jq .balance   # must be 0"* ]]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

@test "live credit + valid allowlisted keep-credit token -> executes, credit flags stripped" {
  healthy
  export STUB_CREDIT_BALANCE=-11772
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm \
    --keep-credit-confirmed-by U038BM16T7W --approval-msg-id 1777474838.796239
  [ "$status" -eq 0 ]
  [[ "$output" == *"AUTHORIZED-KEEP-CREDIT"* ]]
  [[ "$output" == *"DELIBERATE double concession"* ]]
  [[ "$output" == *"STRIPE_CALLED refunds create -d charge=ch_X --confirm"* ]]
  [[ "$output" != *"--keep-credit-confirmed-by"* ]]
  [[ "$output" != *"--approval-msg-id"* ]]
}

@test "live credit + NON-allowlisted keep-credit approver -> REFUSED" {
  healthy
  export STUB_CREDIT_BALANCE=-11772
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm \
    --keep-credit-confirmed-by U0BOGUS --approval-msg-id 1777474838.796239
  [ "$status" -eq 3 ]
  [[ "$output" == *"not on the god-mode allowlist"* ]]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

@test "live credit + keep-credit token but missing approval-msg-id -> REFUSED" {
  healthy
  export STUB_CREDIT_BALANCE=-11772
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm \
    --keep-credit-confirmed-by U038BM16T7W
  [ "$status" -eq 3 ]
  [[ "$output" == *"DOUBLE concession"* ]]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

@test "value-less trailing --keep-credit-confirmed-by -> usage error (exit 2), not silent" {
  healthy
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm --keep-credit-confirmed-by
  [ "$status" -eq 2 ]
  [[ "$output" == *"needs a value"* ]]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

@test "zero credit balance -> executes (nothing to double-pay)" {
  healthy
  export STUB_CREDIT_BALANCE=0
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 0 ]
  [[ "$output" == *"STRIPE_CALLED refunds create"* ]]
}

@test "POSITIVE balance (customer OWES us) -> executes, never read as credit" {
  # Guards the Math.abs() trap that core-backend's getCustomerBalance() fell into:
  # a debit and a credit are indistinguishable once you take the absolute value.
  healthy
  export STUB_CREDIT_BALANCE=20000
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 0 ]
  [[ "$output" == *"STRIPE_CALLED refunds create"* ]]
}

@test "live balance is a TAGGED adjustment (our referral credit) -> executes" {
  # THE false-refusal guard. Referral/offer credits we minted on purpose carry
  # metadata; they are not a concession for this charge's unused time and must
  # not block an unrelated refund.
  healthy
  export STUB_CREDIT_BALANCE=-11772
  export STUB_CBT_TAGGED=1
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 0 ]
  [[ "$output" == *"STRIPE_CALLED refunds create"* ]]
}

@test "UNTAGGED adjustment credit (the 2026-07 manual-credit shape) -> REFUSED" {
  healthy
  export STUB_CREDIT_BALANCE=-1000
  export STUB_CBT_TYPE=adjustment
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"DOUBLE concession"* ]]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

@test "proration credit already spent past a zero boundary -> executes" {
  healthy
  export STUB_CREDIT_BALANCE=-2000
  export STUB_CBT_SPENT=1
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 0 ]
  [[ "$output" == *"STRIPE_CALLED refunds create"* ]]
}

@test "ONE-OFF charge with a live credit is still gated -> REFUSED (80% of the audit)" {
  # The scope decision that matters most. 192 of the 241 flagged pairs are one-off
  # charges, including all 190 of the 2026-07 auto-recharge cluster. Copying the
  # paid-access gate's one-off exemption here would have missed the majority class.
  healthy
  export STUB_NO_INVOICE=1
  export STUB_CREDIT_BALANCE=-11772
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"DOUBLE concession"* ]]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

@test "ONE-OFF charge + TAGGED referral credit -> executes (merch refund not blocked)" {
  # The false-refusal guard for the widened scope: dropping the one-off exemption is
  # only safe because our own referral/offer credits are excluded by metadata.
  healthy
  export STUB_NO_INVOICE=1
  export STUB_CREDIT_BALANCE=-11772
  export STUB_CBT_TAGGED=1
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 0 ]
  [[ "$output" == *"STRIPE_CALLED refunds create"* ]]
}

@test "customer read broken -> FAIL-CLOSED refuse, not allowed through" {
  healthy
  export STUB_CUSTOMER_BROKEN=1
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"credit balance"* ]]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

@test "customer object MISSING the balance key (API drift) -> FAIL-CLOSED refuse" {
  healthy
  export STUB_CUSTOMER_NO_BALANCE_KEY=1
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"credit balance"* ]]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

@test "balance-transactions read broken (empty) -> FAIL-CLOSED refuse" {
  healthy
  export STUB_CREDIT_BALANCE=-11772
  export STUB_CBT_BROKEN=1
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"credit balance"* ]]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

@test "full balance-transactions page with no zero boundary -> FAIL-CLOSED refuse" {
  healthy
  export STUB_CREDIT_BALANCE=-11772
  export STUB_CBT_FULL_PAGE=1
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"credit balance"* ]]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

@test "raw API refund form (post /v1/refunds) with a live credit is still gated -> REFUSED" {
  healthy
  export STUB_CREDIT_BALANCE=-11772
  run "$WRAPPER" post /v1/refunds -d "charge=ch_X"
  [ "$status" -eq 3 ]
  [[ "$output" == *"DOUBLE concession"* ]]
  [[ "$output" != *"STRIPE_CALLED post /v1/refunds"* ]]
}

@test "keep-SUBSCRIPTION token does NOT waive the credit wall -> REFUSED" {
  healthy
  export STUB_CREDIT_BALANCE=-11772
  export STUB_ACTIVE_SUBS=1
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm \
    --keep-subscription-confirmed-by U038BM16T7W --approval-msg-id 1777474838.796239
  [ "$status" -eq 3 ]
  [[ "$output" == *"DOUBLE concession"* ]]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

@test "keep-CREDIT token does NOT waive the one-time policy -> REFUSED on prior refund" {
  healthy
  export STUB_CREDIT_BALANCE=-11772
  export STUB_PRIOR_REFUNDS=1
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm \
    --keep-credit-confirmed-by U038BM16T7W --approval-msg-id 1777474838.796239
  [ "$status" -eq 3 ]
  [[ "$output" == *"prior refund"* ]]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}

@test "all three waivers together -> executes with all three AUTHORIZED lines" {
  healthy
  export STUB_CREDIT_BALANCE=-11772
  export STUB_PRIOR_REFUNDS=1
  export STUB_ACTIVE_SUBS=1
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm \
    --override-confirmed-by U038BM16T7W \
    --keep-subscription-confirmed-by U038BM16T7W \
    --keep-credit-confirmed-by U038BM16T7W \
    --approval-msg-id 1777474838.796239
  [ "$status" -eq 0 ]
  [[ "$output" == *"AUTHORIZED-OVERRIDE"* ]]
  [[ "$output" == *"AUTHORIZED-KEEP ("* ]]
  [[ "$output" == *"AUTHORIZED-KEEP-CREDIT"* ]]
  [[ "$output" == *"STRIPE_CALLED refunds create"* ]]
}

# --- Post-write re-check (credit Stripe mints DURING the refund) --------------

@test "credit minted AFTER the refund -> refund still succeeds, exit 0, loud banner" {
  # The 2025-12-05 chronology: refund at 06:53:35Z, proration credit 0.96h later.
  # A pre-write gate cannot see a credit that does not exist yet, so the only
  # honest answer is to run the refund and then say so.
  healthy
  export STUB_POST_REFUND_CREDIT=1
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 0 ]
  [[ "$output" == *"STRIPE_CALLED refunds create"* ]]
  [[ "$output" == *"POST-REFUND-CREDIT-LIVE"* ]]
  [[ "$output" == *"do NOT re-run it"* ]]
  [[ "$output" == *"balance_transactions"* ]]
}

@test "post-refund credit UNVERIFIABLE -> refund still exit 0, never converted to a failure" {
  # A failed read AFTER the money moved must not look like a failed refund; that
  # is what invites a blind retry of a non-idempotent write.
  healthy
  export STUB_CUSTOMER_BROKEN=0
  export STUB_CBT_BROKEN=1
  export STUB_CREDIT_BALANCE=0
  export STUB_POST_REFUND_CREDIT=1
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 0 ]
  [[ "$output" == *"STRIPE_CALLED refunds create"* ]]
  [[ "$output" == *"POST-REFUND-CREDIT-UNVERIFIED"* ]]
  [[ "$output" == *"do NOT re-run it"* ]]
}

@test "post-refund CUSTOMER lookup failure still warns (money already moved)" {
  # QA finding: a failed post-refund charge lookup emitted no token at all, so an
  # already-paid refund looked clean and nobody would ever check the balance.
  healthy
  export STUB_POST_CHARGE_BROKEN=1
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 0 ]
  [[ "$output" == *"STRIPE_CALLED refunds create"* ]]
  [[ "$output" == *"POST-REFUND-CREDIT-UNVERIFIED"* ]]
  [[ "$output" == *"do NOT re-run it"* ]]
}

@test "an INVALID keep-credit token cannot suppress the post-refund recheck" {
  # The gate returns early when the pre-write balance is clean, so a bogus token
  # is never validated — yet its mere PRESENCE silenced the post-write check.
  # Pass garbage, start clean, and have Stripe mint the credit during the refund.
  healthy
  export STUB_POST_REFUND_CREDIT=1
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm \
    --keep-credit-confirmed-by U0BOGUS --approval-msg-id 1.2
  [ "$status" -eq 0 ]
  [[ "$output" == *"STRIPE_CALLED refunds create"* ]]
  [[ "$output" == *"POST-REFUND-CREDIT-LIVE"* ]]
}

@test "an AUTHORIZED keep-credit waiver does suppress the post-refund recheck" {
  # The adjacent case: a real, allowlisted waiver means the double concession was
  # deliberate, so re-reporting it every time would be noise.
  healthy
  export STUB_CREDIT_BALANCE=-11772
  export STUB_POST_REFUND_CREDIT=1
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm \
    --keep-credit-confirmed-by U038BM16T7W --approval-msg-id 1.2
  [ "$status" -eq 0 ]
  [[ "$output" == *"AUTHORIZED-KEEP-CREDIT"* ]]
  [[ "$output" != *"POST-REFUND-CREDIT-LIVE"* ]]
}

@test "a malformed balance-transaction row REFUSES the refund at the real gate" {
  # The end-to-end half: a concession row the parser cannot read must not become
  # "no credit" and let cash out the door.
  healthy
  export STUB_CREDIT_BALANCE=-11772
  export STUB_CBT_MALFORMED=1
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"credit balance"* ]]
  [[ "$output" != *"STRIPE_CALLED refunds create"* ]]
}
