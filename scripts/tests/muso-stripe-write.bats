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
  #  - anything else (e.g. `refunds create`) → echo STRIPE_CALLED so we can assert pass-through
  cat >"$BIN/stripe" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "charges retrieve")
    if [ "${STUB_BROKEN:-0}" -gt 0 ]; then echo ""
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
  *)
    echo "STRIPE_CALLED $*"
    ;;
esac
SH
  chmod +x "$BIN/stripe"
  export STRIPE_BIN="$BIN/stripe"
  export OPENCLAW_GATEWAY_UNIT="test-unit"
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

@test "non-refund stripe write is unaffected by the refund gate" {
  healthy
  run "$WRAPPER" customers retrieve cus_TEST
  [ "$status" -eq 0 ]
  [[ "$output" == *"STRIPE_CALLED customers retrieve cus_TEST"* ]]
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
