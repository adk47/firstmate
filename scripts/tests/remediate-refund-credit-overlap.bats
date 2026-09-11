#!/usr/bin/env bats
# Tests for scripts/remediate-refund-credit-overlap.sh — the one-time cleanup that
# zeroes concession credit a cash refund already paid for.
#
# This script moves real money on real customer accounts, so the assertions that
# matter are the ones about NOT moving it: dry-run writes nothing, --apply without an
# allowlisted approver writes nothing, the amount always comes from LIVE Stripe rather
# than the audit CSV, and a second run is a no-op.
bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/remediate-refund-credit-overlap.sh"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  WRITE_LOG="$BATS_TEST_TMPDIR/writes.log"; : >"$WRITE_LOG"; export WRITE_LOG

  cat >"$BIN/stripe" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "refunds retrieve")
    if [ "${STUB_REFUND_MISSING:-0}" -gt 0 ]; then echo '{}'
    elif [ "${STUB_REFUND_PENDING:-0}" -gt 0 ]; then echo '{"id":"re_TEST","status":"pending"}'
    elif [ "${STUB_REFUND_NO_CHARGE:-0}" -gt 0 ]; then echo '{"id":"re_TEST","status":"succeeded"}'
    else echo '{"id":"re_TEST","status":"succeeded","charge":"ch_TEST"}'; fi
    ;;
  "charges retrieve")
    if [ "${STUB_RCHARGE_BROKEN:-0}" -gt 0 ]; then echo ""
    else echo "{\"id\":\"ch_TEST\",\"customer\":\"${STUB_REFUND_OWNER:-cus_TEST}\"}"; fi
    ;;
  "customers retrieve")
    if [ "${STUB_CUSTOMER_BROKEN:-0}" -gt 0 ]; then echo ""
    elif [ -f "$STUB_STATE/applied" ]; then echo '{"id":"cus_TEST","balance":0}'
    else echo "{\"id\":\"cus_TEST\",\"balance\":${STUB_CREDIT_BALANCE:--11772}}"; fi
    ;;
  "get /v1/customers/cus_TEST/balance_transactions")
    if [ "${STUB_CBT_BROKEN:-0}" -gt 0 ]; then echo ""
    elif [ -f "$STUB_STATE/applied" ] && [ "${STUB_MARKER:-1}" -gt 0 ]; then
      echo "{\"object\":\"list\",\"data\":[{\"id\":\"cbtxn_FIX\",\"type\":\"adjustment\",\"amount\":11772,\"ending_balance\":0,\"created\":1,\"metadata\":{\"hydra_remediation\":\"${RUN_TAG}\"}}]}"
    else
      echo '{"object":"list","data":[{"id":"cbtxn_LIVE","type":"invoice_too_small","amount":-11772,"ending_balance":-11772,"created":1,"metadata":{}}]}'
    fi
    ;;
  "post /v1/customers/cus_TEST/balance_transactions")
    # The REAL money gate execs this. There is no stub writer any more: apply
    # mode binds the gate path immutably, so the tests drive the genuine
    # muso-stripe-write.sh and this is where the write lands.
    [ "${STUB_WRITE_SLOW:-0}" -gt 0 ] && sleep 1
    echo "WRITE $*" >> "$WRITE_LOG"
    [ "${STUB_WRITE_FAILS:-0}" -gt 0 ] && exit 3
    case "$*" in *"amount=-"*) : > "$STUB_STATE/compensated" ;; *) : > "$STUB_STATE/applied" ;; esac
    echo '{"object":"customer_balance_transaction"}'
    ;;
  "post /v1/customers/cus_TEST/balance_transactions")
    [ "${STUB_WRITE_SLOW:-0}" -gt 0 ] && sleep 1
    echo "WRITE $*" >> "$WRITE_LOG"
    case "$*" in *"amount=-"*) : > "$STUB_STATE/compensated" ;; *) : > "$STUB_STATE/applied" ;; esac
    echo '{"object":"customer_balance_transaction"}'
    ;;
  *) echo "STRIPE_CALLED $*" ;;
esac
SH
  chmod +x "$BIN/stripe"

  # The real gate refuses to move money while codex is degraded, so give it a
  # healthy journal. This also means the gate itself is now under test on every
  # apply case, rather than being stubbed away.
  cat >"$BIN/journalctl" <<'SH'
#!/usr/bin/env bash
printf '%s' "Sep 11 10:00:00 node-8 openclaw[1]: message processed: outcome=ok"
SH
  chmod +x "$BIN/journalctl"
  export PATH="$BIN:$PATH"

  STUB_STATE="$BATS_TEST_TMPDIR/state"; mkdir -p "$STUB_STATE"
  CSV="$BATS_TEST_TMPDIR/audit.csv"
  printf 'customer_id,refund_id,credit_txn,credit_outstanding\ncus_TEST,re_TEST,cbtxn_LIVE,117.72\n' >"$CSV"

  export STUB_STATE STRIPE_BIN="$BIN/stripe"
  export REFUND_REMEDIATION_LEDGER_DIR="$BATS_TEST_TMPDIR/ledger"
  export RUN_TAG="test-run"
}

writes() { cat "$WRITE_LOG" 2>/dev/null || true; }

@test "dry-run by default: plans the fix and writes NOTHING" {
  run "$SCRIPT" --audit-csv "$CSV"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN"* ]]
  [[ "$output" == *"DRY-RUN"* ]]
  [ -z "$(writes)" ]
}

@test "--apply without --confirmed-by refuses and writes NOTHING" {
  run "$SCRIPT" --audit-csv "$CSV" --apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"needs --confirmed-by"* ]]
  [ -z "$(writes)" ]
}

@test "--apply with a NON-allowlisted approver refuses and writes NOTHING" {
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U0BOGUS --approval-msg-id 123.456
  [ "$status" -eq 2 ]
  [[ "$output" == *"not authorized for --apply"* ]]
  [ -z "$(writes)" ]
}

@test "--apply with an allowlisted approver debits the LIVE amount, not the CSV amount" {
  # The CSV says 117.72 but is only a candidate list; the live balance is the authority.
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  [ "$status" -eq 0 ]
  [[ "$(writes)" == *"amount=11772"* ]]
  [[ "$(writes)" == *"metadata[hydra_remediation]=test-run"* ]]
  [[ "$(writes)" == *"metadata[confirmed_by]=U7RP6HKUZ"* ]]
  [[ "$output" == *"APPLIED"* ]]
  # Success means the CONCESSION is gone, not that the balance is 0 — a customer
  # may legitimately still hold referral/offer credit we must never touch.
  [[ "$output" == *"concession-now-zero"* ]]
}

@test "live balance SMALLER than the CSV figure -> debits only what is live" {
  # The cus_QdFL2zz46PRD19 case: workbook says $60 outstanding, Stripe says less.
  # Writing the workbook figure would invent a debit against the customer.
  export STUB_CREDIT_BALANCE=-4000
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  [ "$status" -eq 0 ]
  [[ "$(writes)" == *"amount=4000"* ]]
  [[ "$(writes)" != *"amount=11772"* ]]
}

@test "customer with NO live credit is skipped, no write" {
  export STUB_CREDIT_BALANCE=0
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-live-credit"* ]]
  [ -z "$(writes)" ]
}

@test "customer in DEBIT (positive balance) is skipped, never debited again" {
  export STUB_CREDIT_BALANCE=20000
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-live-credit"* ]]
  [ -z "$(writes)" ]
}

@test "re-running after a successful apply is a NO-OP (idempotent)" {
  "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456 >/dev/null
  : >"$WRITE_LOG"
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  [ "$status" -eq 0 ]
  [ -z "$(writes)" ]
  [[ "$output" == *"no-live-credit"* || "$output" == *"already-remediated"* ]]
}

@test "unverifiable credit read is skipped, never written blind" {
  export STUB_CBT_BROKEN=1
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  [ "$status" -eq 0 ]
  [[ "$output" == *"credit-unverifiable"* ]]
  [ -z "$(writes)" ]
}

@test "refund that did not succeed is skipped (CSV never authorises a write alone)" {
  export STUB_REFUND_PENDING=1
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  [ "$status" -eq 0 ]
  [[ "$output" == *"refund-not-succeeded"* ]]
  [ -z "$(writes)" ]
}

@test "amount over the per-customer cap is skipped" {
  export STUB_CREDIT_BALANCE=-99999
  export MAX_PER_CUSTOMER_CENTS=5000
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  [ "$status" -eq 0 ]
  [[ "$output" == *"over-per-customer-cap"* ]]
  [ -z "$(writes)" ]
}

@test "run total over the cap ABORTS before the write" {
  export MAX_TOTAL_CENTS=100
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  [ "$status" -eq 4 ]
  [[ "$output" == *"total-cap-exceeded"* ]]
  [ -z "$(writes)" ]
}

@test "a failed gate write is reported as FAILED, never as success" {
  export STUB_WRITE_FAILS=1
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  [ "$status" -eq 5 ]
  [[ "$output" == *"FAILED"* ]]
  [[ "$output" != *"APPLIED"* ]]
}

@test "malformed CSV row is REPORTED and skipped, not silently dropped" {
  printf 'customer_id,refund_id,credit_txn\ncus_TEST,re_TEST,cbtxn_LIVE\n,,\n' >"$CSV"
  run "$SCRIPT" --audit-csv "$CSV"
  [ "$status" -eq 0 ]
  [[ "$output" == *"malformed-row"* ]]
}

@test "CSV without the required headers is rejected outright" {
  printf 'foo,bar\n1,2\n' >"$CSV"
  run "$SCRIPT" --audit-csv "$CSV"
  [ "$status" -eq 2 ]
  [[ "$output" == *"must have 'customer_id', 'refund_id' and 'credit_txn'"* ]]
}

@test "columns are resolved BY NAME, so re-ordering the CSV cannot transpose them" {
  printf 'refund_id,other,customer_id,credit_txn\nre_TEST,x,cus_TEST,cbtxn_LIVE\n' >"$CSV"
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  [ "$status" -eq 0 ]
  [[ "$(writes)" == *"/v1/customers/cus_TEST/balance_transactions"* ]]
  [[ "$(writes)" == *"source_refund]=re_TEST"* ]]
}

@test "--customer restricts the run to one row" {
  printf 'customer_id,refund_id,credit_txn\ncus_OTHER,re_OTHER,cbtxn_LIVE\ncus_TEST,re_TEST,cbtxn_LIVE\n' >"$CSV"
  run "$SCRIPT" --audit-csv "$CSV" --customer cus_TEST
  [ "$status" -eq 0 ]
  [[ "$output" == *"cus_TEST"* ]]
  [[ "$output" != *"cus_OTHER"* ]]
}

# Extract the effective allowlist VALUE from each file without sed backreferences.
# The previous version used `sed 's/.../\1/p'`, and the \1 was mangled into a
# literal U+0001 when the test was generated — so BOTH captures became the same
# control character and the comparison passed no matter what. It was proved
# vacuous by injecting drift and watching it stay green.
_gate_allowlist() {
  local line; line="$(grep -m1 '^REFUND_OVERRIDE_ALLOWLIST=' "$1")" || return 1
  line="${line#*:-}"; printf '%s' "${line%\}\"}"
}
_remediation_allowlist() {
  # Compare the FULL list against the gate. --apply is deliberately narrower
  # (Aaron only) until the new debit surface is authorized, so the parity check
  # targets the list that is meant to match.
  local line; line="$(grep -m1 '^REFUND_OVERRIDE_ALLOWLIST_FULL=' "$1")" || return 1
  line="${line#*=\"}"; printf '%s' "${line%\"}"
}

@test "the approver allowlist VALUE matches the money gate's" {
  local a b
  a="$(_gate_allowlist "$REPO_ROOT/scripts/muso-stripe-write.sh")"
  b="$(_remediation_allowlist "$REPO_ROOT/scripts/remediate-refund-credit-overlap.sh")"
  # Assert CONTENT, not just equality: two failed extractions compare equal, which
  # is how the previous version passed while testing nothing.
  [[ "$a" == *"U7RP6HKUZ"* ]]
  [[ "$b" == *"U7RP6HKUZ"* ]]
  [ "$a" = "$b" ]
}

@test "the allowlist parity check actually FAILS on one-sided drift" {
  # The guard that the previous version lacked: prove the comparison can fail.
  local tmp="$BATS_TEST_TMPDIR/drifted.sh"
  sed 's/^REFUND_OVERRIDE_ALLOWLIST_FULL=.*/REFUND_OVERRIDE_ALLOWLIST_FULL="U0DRIFTED"/' \
    "$REPO_ROOT/scripts/remediate-refund-credit-overlap.sh" > "$tmp"
  local a b
  a="$(_gate_allowlist "$REPO_ROOT/scripts/muso-stripe-write.sh")"
  b="$(_remediation_allowlist "$tmp")"
  [ "$b" = "U0DRIFTED" ]
  [ "$a" != "$b" ]
}

# --- QA blockers 1 + 2 -------------------------------------------------------

@test "refund belonging to a DIFFERENT customer is skipped, never debited" {
  # QA finding (Critical): a succeeded refund proves a refund happened, not that
  # it happened to this CSV row's customer. One transposed row would otherwise
  # debit someone who was never refunded at all.
  export STUB_REFUND_OWNER=cus_SOMEONE_ELSE
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  [ "$status" -eq 0 ]
  [[ "$output" == *"refund-customer-mismatch"* ]]
  [ -z "$(writes)" ]
}

@test "refund with no charge to resolve ownership from is skipped" {
  export STUB_REFUND_NO_CHARGE=1
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  [ "$status" -eq 0 ]
  [[ "$output" == *"refund-has-no-charge"* ]]
  [ -z "$(writes)" ]
}

@test "unreadable charge on the refund is skipped, never written blind" {
  export STUB_RCHARGE_BROKEN=1
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  [ "$status" -eq 0 ]
  [[ "$output" == *"refund-charge-unreadable"* ]]
  [ -z "$(writes)" ]
}

@test "MIXED balance: debits only the concession, leaving the referral credit alone" {
  # QA finding (Critical). Balance is -13772: an 11772 concession plus a 2000
  # tagged referral reward. Debiting 13772 would claw back money the customer
  # was genuinely owed.
  cat >"$BIN/stripe" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "refunds retrieve") echo '{"id":"re_TEST","status":"succeeded","charge":"ch_TEST"}' ;;
  "charges retrieve") echo '{"id":"ch_TEST","customer":"cus_TEST"}' ;;
  "customers retrieve")
    if [ -f "$STUB_STATE/applied" ]; then echo '{"id":"cus_TEST","balance":-2000}'
    else echo '{"id":"cus_TEST","balance":-13772}'; fi ;;
  "get /v1/customers/cus_TEST/balance_transactions")
    if [ -f "$STUB_STATE/applied" ]; then
      echo '{"object":"list","data":[{"id":"cbtxn_REF","type":"adjustment","amount":-2000,"ending_balance":-2000,"created":1,"metadata":{"referralId":"r1"}}]}'
    else
      echo '{"object":"list","data":[{"id":"cbtxn_REF","type":"adjustment","amount":-2000,"ending_balance":-13772,"created":1,"metadata":{"referralId":"r1"}},{"id":"cbtxn_P","type":"invoice_too_small","amount":-11772,"ending_balance":-11772,"created":1,"metadata":{}}]}'
    fi ;;
  "post /v1/customers/cus_TEST/balance_transactions")
    [ "${STUB_WRITE_SLOW:-0}" -gt 0 ] && sleep 1
    echo "WRITE $*" >> "$WRITE_LOG"
    case "$*" in *"amount=-"*) : > "$STUB_STATE/compensated" ;; *) : > "$STUB_STATE/applied" ;; esac
    echo '{"object":"customer_balance_transaction"}'
    ;;
  *) echo "STRIPE_CALLED $*" ;;
esac
SH
  chmod +x "$BIN/stripe"
  printf 'customer_id,refund_id,credit_txn\ncus_TEST,re_TEST,cbtxn_P\n' >"$CSV"
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  [ "$status" -eq 0 ]
  [[ "$(writes)" == *"amount=11772"* ]]
  [[ "$(writes)" != *"amount=13772"* ]]
  # The $20 referral survives, so "balance is 0" is the WRONG success test.
  [[ "$output" == *"concession-now-zero"* ]]
}

# --- QA round 2, Critical: the plan -> write race --------------------------
#
# `amount` is computed from a read taken well before the debit. If an invoice
# consumes the credit in between, the debit overshoots and pushes the customer
# into a POSITIVE (owed) balance. Worse, customer_live_concession_amount returns
# 0 for any balance >= 0, so the success check reads that over-debit as "the
# concession is gone" and reports APPLIED — the check masks the very failure it
# exists to catch.

@test "credit consumed between planning and the write is NOT reported as APPLIED" {
  cat >"$BIN/stripe" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "refunds retrieve") echo '{"id":"re_TEST","status":"succeeded","charge":"ch_TEST"}' ;;
  "charges retrieve") echo '{"id":"ch_TEST","customer":"cus_TEST"}' ;;
  "customers retrieve")
    # Planned against -11772; an invoice consumed it before our POST, so the
    # 11772 debit lands on a zero balance and leaves the customer OWING 11772.
    if [ -f "$STUB_STATE/applied" ]; then echo '{"id":"cus_TEST","balance":11772}'
    else echo '{"id":"cus_TEST","balance":-11772}'; fi ;;
  "get /v1/customers/cus_TEST/balance_transactions")
    if [ -f "$STUB_STATE/applied" ]; then echo '{"object":"list","data":[]}'
    else echo '{"object":"list","data":[{"id":"cbtxn_LIVE","type":"invoice_too_small","amount":-11772,"ending_balance":-11772,"created":1,"metadata":{}}]}'; fi ;;
  "post /v1/customers/cus_TEST/balance_transactions")
    [ "${STUB_WRITE_SLOW:-0}" -gt 0 ] && sleep 1
    echo "WRITE $*" >> "$WRITE_LOG"
    case "$*" in *"amount=-"*) : > "$STUB_STATE/compensated" ;; *) : > "$STUB_STATE/applied" ;; esac
    echo '{"object":"customer_balance_transaction"}'
    ;;
  *) echo "STRIPE_CALLED $*" ;;
esac
SH
  chmod +x "$BIN/stripe"
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  [[ "$output" != *"APPLIED"* ]]
  [[ "$output" == *"OVER-DEBIT"* ]]
  [ "$status" -ne 0 ]
}

@test "an over-debit is COMPENSATED back, not just reported" {
  cat >"$BIN/stripe" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "refunds retrieve") echo '{"id":"re_TEST","status":"succeeded","charge":"ch_TEST"}' ;;
  "charges retrieve") echo '{"id":"ch_TEST","customer":"cus_TEST"}' ;;
  "customers retrieve")
    if [ -f "$STUB_STATE/compensated" ]; then echo '{"id":"cus_TEST","balance":0}'
    elif [ -f "$STUB_STATE/applied" ]; then echo '{"id":"cus_TEST","balance":11772}'
    else echo '{"id":"cus_TEST","balance":-11772}'; fi ;;
  "get /v1/customers/cus_TEST/balance_transactions")
    if [ -f "$STUB_STATE/applied" ]; then echo '{"object":"list","data":[]}'
    else echo '{"object":"list","data":[{"id":"cbtxn_LIVE","type":"invoice_too_small","amount":-11772,"ending_balance":-11772,"created":1,"metadata":{}}]}'; fi ;;
  "post /v1/customers/cus_TEST/balance_transactions")
    [ "${STUB_WRITE_SLOW:-0}" -gt 0 ] && sleep 1
    echo "WRITE $*" >> "$WRITE_LOG"
    case "$*" in *"amount=-"*) : > "$STUB_STATE/compensated" ;; *) : > "$STUB_STATE/applied" ;; esac
    echo '{"object":"customer_balance_transaction"}'
    ;;
  *) echo "STRIPE_CALLED $*" ;;
esac
SH
  chmod +x "$BIN/stripe"
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  # The customer must not be left owing money we invented.
  [[ "$(writes)" == *"amount=-11772"* ]]
  [[ "$output" == *"OVER-DEBIT-COMPENSATED"* ]]
}

@test "balance re-read immediately before the write catches consumption early" {
  # Narrow the race rather than only detecting it afterwards: if the credit is
  # already gone at write time, do not write at all.
  cat >"$BIN/stripe" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "refunds retrieve") echo '{"id":"re_TEST","status":"succeeded","charge":"ch_TEST"}' ;;
  "charges retrieve") echo '{"id":"ch_TEST","customer":"cus_TEST"}' ;;
  "customers retrieve")
    # Count reads: the FIRST (planning) shows the credit, the last-moment
    # re-read shows an invoice consumed it. Only the BALANCE moves — the
    # transaction history still lists the credit, which is exactly the shape
    # that makes the concession look reclaimable when it no longer is.
    # Planning reads the customer twice (once for the credit summary, once for
    # the amount); the THIRD read is the last-moment re-check immediately before
    # the POST. Flipping there models an invoice consuming the credit in exactly
    # the window this guard exists to close. If the script's read pattern ever
    # changes, this test fails loudly rather than silently passing.
    n=$(cat "$STUB_STATE/nreads" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$STUB_STATE/nreads"
    if [ "$n" -ge 3 ]; then echo '{"id":"cus_TEST","balance":0}'
    else echo '{"id":"cus_TEST","balance":-11772}'; fi ;;
  "get /v1/customers/cus_TEST/balance_transactions")
    echo '{"object":"list","data":[{"id":"cbtxn_LIVE","type":"invoice_too_small","amount":-11772,"ending_balance":-11772,"created":1,"metadata":{}}]}' ;;
  "post /v1/customers/cus_TEST/balance_transactions")
    [ "${STUB_WRITE_SLOW:-0}" -gt 0 ] && sleep 1
    echo "WRITE $*" >> "$WRITE_LOG"
    case "$*" in *"amount=-"*) : > "$STUB_STATE/compensated" ;; *) : > "$STUB_STATE/applied" ;; esac
    echo '{"object":"customer_balance_transaction"}'
    ;;
  *) echo "STRIPE_CALLED $*" ;;
esac
SH
  chmod +x "$BIN/stripe"
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  [ -z "$(writes)" ]
  [[ "$output" == *"credit-vanished-before-write"* ]]
}

# --- QA round 3, Critical: apply must not be caller-authorizable ------------

@test "PRODUCTION mode ignores STRIPE_WRITE_BIN and a caller-supplied allowlist" {
  # Outside the test seam, a caller pointing the writer at the raw Stripe CLI and
  # adding itself to the allowlist must NOT be able to move money. Simulated by
  # unsetting the bats marker, which is the only thing that enables the seams.
  run env -u BATS_TEST_TMPDIR \
      STRIPE_WRITE_BIN="$BIN/muso-stripe-write.sh" \
      REFUND_OVERRIDE_ALLOWLIST="U0ATTACKER" \
      STRIPE_BIN="$BIN/stripe" \
      REFUND_REMEDIATION_LEDGER_DIR="$BATS_TEST_TMPDIR/ledger" \
      "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U0ATTACKER --approval-msg-id 123.456
  # The injected allowlist must not authorize anything...
  [ "$status" -eq 2 ]
  [[ "$output" == *"not authorized for --apply"* ]]
  # ...and the injected writer must never have been reached.
  [ -z "$(writes)" ]
}

@test "the writer is ALWAYS the canonical money gate, whatever the caller injects" {
  # Positive form: assert which binary is actually used, rather than the absence
  # of a stub write. The run summary prints the bound writer, so an injected path
  # silently winning would be visible here.
  export STRIPE_WRITE_BIN="$BATS_TEST_TMPDIR/evil-writer.sh"
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  [[ "$output" == *"writer: $REPO_ROOT/scripts/muso-stripe-write.sh"* ]]
  [[ "$output" != *"evil-writer"* ]]
}

# --- QA round 3, Important: overlapping apply runs -------------------------

@test "two concurrent apply runs debit the customer ONCE, not twice" {
  # Without serialization both runs read the same live credit before either
  # writes, and both debit it. The stub writer sleeps to make that window real.
  export STUB_WRITE_SLOW=1
  "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456 >/dev/null 2>&1 &
  p1=$!
  "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456 >/dev/null 2>&1 &
  p2=$!
  wait $p1 || true
  wait $p2 || true
  n="$(grep -c '^WRITE' "$WRITE_LOG" || true)"
  [ "$n" -eq 1 ]
}

@test "the debit carries a deterministic idempotency key" {
  # Belt to the flock's braces: flock is per-host, so a second host (or a
  # resumed run) is still bounded by Stripe rejecting the duplicate key.
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  [[ "$(writes)" == *"--idempotency"* ]]
  [[ "$(writes)" == *"cus_TEST"*"re_TEST"* ]]
}

# --- QA round 4, carried-forward Critical: there is no safe env seam ---------
#
# The previous fix keyed the seam on BATS_TEST_TMPDIR and called that
# "production-impossible". It is not: it is an ordinary environment variable, so
# anyone who could set STRIPE_WRITE_BIN could set it too and restore the whole
# bypass. The only correct answer is that apply mode has no seam at all.

@test "an injected allowlist is rejected even WITH BATS_TEST_TMPDIR set" {
  export REFUND_OVERRIDE_ALLOWLIST="U0ATTACKER"
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U0ATTACKER --approval-msg-id 123.456
  [ "$status" -eq 2 ]
  [[ "$output" == *"not authorized for --apply"* ]]
  [ -z "$(writes)" ]
}

@test "an injected writer is ignored even WITH BATS_TEST_TMPDIR set" {
  # Point the writer at something that would obviously succeed if honoured.
  cat >"$BATS_TEST_TMPDIR/evil-writer.sh" <<SH
#!/usr/bin/env bash
echo "EVIL \$*" >> "$WRITE_LOG"
exit 0
SH
  chmod +x "$BATS_TEST_TMPDIR/evil-writer.sh"
  export STRIPE_WRITE_BIN="$BATS_TEST_TMPDIR/evil-writer.sh"
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  [[ "$(writes)" != *"EVIL"* ]]
}

@test "a caller-supplied CODEX_HEALTH_LIB cannot neuter the gate the remediation binds" {
  # Binding the writer PATH is not enough: muso-stripe-write.sh honours its own
  # env hooks, so a caller could point CODEX_HEALTH_LIB at a stub whose
  # codex_health_gate always passes and move money on a degraded fleet through a
  # writer that still looks canonical.
  cat >"$BATS_TEST_TMPDIR/fake-health.sh" <<'SH'
codex_health_gate() { return 0; }
SH
  # Journal reports codex DEGRADED — the real lib must refuse on this.
  cat >"$BIN/journalctl" <<'SH'
#!/usr/bin/env bash
printf '%s' "Sep 11 10:00:00 node-8 openclaw[1]: OpenAI Codex token refresh failed (401): code=refresh_token_reused"
SH
  chmod +x "$BIN/journalctl"
  export CODEX_HEALTH_LIB="$BATS_TEST_TMPDIR/fake-health.sh"
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  # No money may move: the real health lib sees the degraded journal and refuses.
  [ -z "$(writes)" ]
  [[ "$output" == *"FAILED"* ]]
}

@test "a degraded journal blocks the remediation write (the gate is really in the path)" {
  cat >"$BIN/journalctl" <<'SH'
#!/usr/bin/env bash
printf '%s' "Sep 11 10:00:00 node-8 openclaw[1]: OpenAI Codex token refresh failed (401): code=refresh_token_reused"
SH
  chmod +x "$BIN/journalctl"
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  [ -z "$(writes)" ]
}

@test "a fabricating STRIPE_CREDIT_LIB cannot inflate the debit" {
  # Sanitizing the GATE invocation is not enough: the remediation's own decision
  # inputs were still caller-controlled. A shim library can fabricate the live
  # concession and the real POST then debits a real customer on invented data.
  cat >"$BATS_TEST_TMPDIR/fake-credit.sh" <<'SH'
credit_live_window_credits() { echo "cbtxn_FAKE invoice_too_small -49999"; }
credit_live_window_total() { echo 49999; }
customer_live_concession_amount() { echo 49999; }
customer_live_proration_credit() { echo "-49999 via cbtxn_FAKE(invoice_too_small)"; }
customer_raw_balance() { echo -49999; }
SH
  export STRIPE_CREDIT_LIB="$BATS_TEST_TMPDIR/fake-credit.sh"
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  # The fabricated 49999 must never reach a write.
  [[ "$(writes)" != *"amount=49999"* ]]
}

@test "a fabricating STRIPE_BIN cannot supply the reads the decision is made on" {
  # A shim that forges refund ownership and balance reads, then forwards only the
  # final POST, would move real money on invented inputs.
  cat >"$BATS_TEST_TMPDIR/forge.sh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "refunds retrieve") echo '{"id":"re_TEST","status":"succeeded","charge":"ch_TEST"}' ;;
  "charges retrieve") echo '{"id":"ch_TEST","customer":"cus_TEST"}' ;;
  "customers retrieve") echo '{"id":"cus_TEST","balance":-49999}' ;;
  "get /v1/customers/cus_TEST/balance_transactions")
    echo '{"object":"list","data":[{"id":"cbtxn_FORGED","type":"invoice_too_small","amount":-49999,"ending_balance":-49999,"created":1,"metadata":{}}]}' ;;
  *) echo '{}' ;;
esac
SH
  chmod +x "$BATS_TEST_TMPDIR/forge.sh"
  export STRIPE_BIN="$BATS_TEST_TMPDIR/forge.sh"
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  [[ "$(writes)" != *"amount=49999"* ]]
}

@test "the run summary records the resolved stripe binary" {
  # Substitution should at least be attributable in the ledger rather than silent.
  run "$SCRIPT" --audit-csv "$CSV"
  [[ "$output" == *"stripe:"* ]]
}

# --- QA round 9, Critical: bind to the AUDITED credit, not just the customer ---

@test "a REPLACEMENT concession credit is not mistaken for the audited one" {
  # The audited credit was spent; an unrelated new invoice_too_small has since
  # appeared for the same customer. Binding only to (customer, refund) debits the
  # new credit — clawing back a legitimate concession for a different period.
  cat >"$BIN/stripe" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "refunds retrieve") echo '{"id":"re_TEST","status":"succeeded","charge":"ch_TEST"}' ;;
  "charges retrieve") echo '{"id":"ch_TEST","customer":"cus_TEST"}' ;;
  "customers retrieve") echo '{"id":"cus_TEST","balance":-5000}' ;;
  "get /v1/customers/cus_TEST/balance_transactions")
    # cbtxn_AUDITED is gone (spent). cbtxn_NEW is a different period's credit.
    echo '{"object":"list","data":[{"id":"cbtxn_NEW","type":"invoice_too_small","amount":-5000,"ending_balance":-5000,"created":900,"metadata":{}}]}' ;;
  "post /v1/customers/cus_TEST/balance_transactions") echo "WRITE $*" >> "$WRITE_LOG"; echo '{}' ;;
  *) echo "STRIPE_CALLED $*" ;;
esac
SH
  chmod +x "$BIN/stripe"
  printf 'customer_id,refund_id,credit_txn\ncus_TEST,re_TEST,cbtxn_AUDITED\n' >"$CSV"
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  [ -z "$(writes)" ]
  [[ "$output" == *"audited-credit-not-live"* ]]
}

@test "the audited credit still live IS remediated" {
  printf 'customer_id,refund_id,credit_txn\ncus_TEST,re_TEST,cbtxn_LIVE\n' >"$CSV"
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  [ "$status" -eq 0 ]
  [[ "$(writes)" == *"amount=11772"* ]]
}

@test "a CSV without credit_txn is rejected outright" {
  printf 'customer_id,refund_id\ncus_TEST,re_TEST\n' >"$CSV"
  run "$SCRIPT" --audit-csv "$CSV"
  [ "$status" -eq 2 ]
  [[ "$output" == *"credit_txn"* ]]
}

# --- QA round 10, Critical: exact identity, re-checked under the lock --------

@test "a PREFIX of a live transaction id does not satisfy the audited-credit check" {
  # `*"$cbt"*` is a substring test: a truncated CSV id matches a different
  # transaction entirely.
  cat >"$BIN/stripe" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "refunds retrieve") echo '{"id":"re_TEST","status":"succeeded","charge":"ch_TEST"}' ;;
  "charges retrieve") echo '{"id":"ch_TEST","customer":"cus_TEST"}' ;;
  "customers retrieve") echo '{"id":"cus_TEST","balance":-11772}' ;;
  "get /v1/customers/cus_TEST/balance_transactions")
    echo '{"object":"list","data":[{"id":"cbtxn_LIVE_OTHER","type":"invoice_too_small","amount":-11772,"ending_balance":-11772,"created":1,"metadata":{}}]}' ;;
  "post /v1/customers/cus_TEST/balance_transactions") echo "WRITE $*" >> "$WRITE_LOG"; echo '{}' ;;
  *) echo "STRIPE_CALLED $*" ;;
esac
SH
  chmod +x "$BIN/stripe"
  printf 'customer_id,refund_id,credit_txn\ncus_TEST,re_TEST,cbtxn_LIVE\n' >"$CSV"
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  [ -z "$(writes)" ]
  [[ "$output" == *"audited-credit-not-live"* ]]
}

@test "the audited credit replaced between the first read and the locked write is NOT debited" {
  # Consumed after the pre-lock check, replaced by an unrelated credit. `fresh`
  # is still positive, so an amount-only re-read debits the replacement.
  cat >"$BIN/stripe" <<'SH'
#!/usr/bin/env bash
n=$(cat "$STUB_STATE/nbt" 2>/dev/null || echo 0)
case "$1 $2" in
  "refunds retrieve") echo '{"id":"re_TEST","status":"succeeded","charge":"ch_TEST"}' ;;
  "charges retrieve") echo '{"id":"ch_TEST","customer":"cus_TEST"}' ;;
  "customers retrieve") echo '{"id":"cus_TEST","balance":-11772}' ;;
  "get /v1/customers/cus_TEST/balance_transactions")
    n=$((n+1)); echo "$n" > "$STUB_STATE/nbt"
    if [ "$n" -le 1 ]; then
      echo '{"object":"list","data":[{"id":"cbtxn_AUDITED","type":"invoice_too_small","amount":-11772,"ending_balance":-11772,"created":1,"metadata":{}}]}'
    else
      echo '{"object":"list","data":[{"id":"cbtxn_REPLACEMENT","type":"invoice_too_small","amount":-11772,"ending_balance":-11772,"created":9,"metadata":{}}]}'
    fi ;;
  "post /v1/customers/cus_TEST/balance_transactions") echo "WRITE $*" >> "$WRITE_LOG"; echo '{}' ;;
  *) echo "STRIPE_CALLED $*" ;;
esac
SH
  chmod +x "$BIN/stripe"
  printf 'customer_id,refund_id,credit_txn\ncus_TEST,re_TEST,cbtxn_AUDITED\n' >"$CSV"
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  [ -z "$(writes)" ]
  [[ "$output" == *"audited-credit-not-live"* ]]
}

# --- QA round 11, Critical: clamp to the AUDITED row's remaining amount ------

@test "a partially-consumed audited credit plus an unrelated one debits only the audited remainder" {
  # cbtxn_AUDITED: 1000 minted, 500 consumed -> 500 remains.
  # cbtxn_NEW: an unrelated 5000 concession for a different period.
  # Membership passes, but the aggregate is 5500 — debiting that takes 5000 that
  # was never a duplicate.
  cat >"$BIN/stripe" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "refunds retrieve") echo '{"id":"re_TEST","status":"succeeded","charge":"ch_TEST"}' ;;
  "charges retrieve") echo '{"id":"ch_TEST","customer":"cus_TEST"}' ;;
  "customers retrieve")
    if [ -f "$STUB_STATE/applied" ]; then echo '{"id":"cus_TEST","balance":-5000}'
    else echo '{"id":"cus_TEST","balance":-5500}'; fi ;;
  "get /v1/customers/cus_TEST/balance_transactions")
    if [ -f "$STUB_STATE/applied" ]; then
      # Post-write: our 500 debit has consumed the rest of the audited row. The
      # unrelated 5000 legitimately remains — which is exactly why the
      # verification must be scoped to the audited row, not the aggregate.
      echo '{"object":"list","data":[
        {"id":"cbtxn_FIX","type":"adjustment","amount":500,"ending_balance":-5000,"created":400,"metadata":{"hydra_remediation":"x"}},
        {"id":"cbtxn_NEW","type":"invoice_too_small","amount":-5000,"ending_balance":-5500,"created":300,"metadata":{}},
        {"id":"cbtxn_INV","type":"applied_to_invoice","amount":500,"ending_balance":-500,"created":200,"metadata":{}},
        {"id":"cbtxn_AUDITED","type":"invoice_too_small","amount":-1000,"ending_balance":-1000,"created":100,"metadata":{}}]}'
    else
      echo '{"object":"list","data":[
        {"id":"cbtxn_NEW","type":"invoice_too_small","amount":-5000,"ending_balance":-5500,"created":300,"metadata":{}},
        {"id":"cbtxn_INV","type":"applied_to_invoice","amount":500,"ending_balance":-500,"created":200,"metadata":{}},
        {"id":"cbtxn_AUDITED","type":"invoice_too_small","amount":-1000,"ending_balance":-1000,"created":100,"metadata":{}}]}'
    fi ;;
  "post /v1/customers/cus_TEST/balance_transactions") echo "WRITE $*" >> "$WRITE_LOG"; : > "$STUB_STATE/applied"; echo '{}' ;;
  *) echo "STRIPE_CALLED $*" ;;
esac
SH
  chmod +x "$BIN/stripe"
  printf 'customer_id,refund_id,credit_txn\ncus_TEST,re_TEST,cbtxn_AUDITED\n' >"$CSV"
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  [[ "$(writes)" == *"amount=500"* ]]
  [[ "$(writes)" != *"amount=5500"* ]]
  [[ "$(writes)" != *"amount=5000"* ]]
  # The write is scoped to the audited row, so the VERIFICATION must be too.
  # Asking whether ALL live concession is zero reports a successful remediation
  # as VERIFY-FAILED and claims $0 applied, because the unrelated 5000 remains.
  [[ "$output" == *"APPLIED"* ]]
  [[ "$output" != *"VERIFY-FAILED"* ]]
  [ "$status" -eq 0 ]
}

# --- QA round 11, Important: the ledger must not be truncated on resume -----

@test "a resumed same-tag run PRESERVES the earlier ledger entries" {
  printf 'customer_id,refund_id,credit_txn\ncus_TEST,re_TEST,cbtxn_LIVE\n' >"$CSV"
  "$SCRIPT" --audit-csv "$CSV" >/dev/null 2>&1
  first="$(cat "$REFUND_REMEDIATION_LEDGER_DIR"/*.tsv)"
  [[ "$first" == *"re_TEST"* ]]
  # Resume later the same UTC day with the default RUN_TAG.
  "$SCRIPT" --audit-csv "$CSV" >/dev/null 2>&1
  second="$(cat "$REFUND_REMEDIATION_LEDGER_DIR"/*.tsv)"
  # The first run's record must still be there.
  [ "$(printf '%s\n' "$second" | grep -c 're_TEST')" -ge 2 ]
  # And the header must not be repeated mid-file.
  [ "$(printf '%s\n' "$second" | grep -c '^run_tag')" -eq 1 ]
}

@test "the audited credit SHRINKING between planning and the write is re-clamped" {
  # The case that makes the locked re-read load-bearing. Planning sees 1000 of
  # audited credit; an invoice consumes 700 before the write. An aggregate
  # re-read stays large (an unrelated 5000 credit exists), so it would NOT clamp
  # and the stale 1000 would be written. Only a per-audited-row re-read catches it.
  cat >"$BIN/stripe" <<'SH'
#!/usr/bin/env bash
n=$(cat "$STUB_STATE/nbt" 2>/dev/null || echo 0)
case "$1 $2" in
  "refunds retrieve") echo '{"id":"re_TEST","status":"succeeded","charge":"ch_TEST"}' ;;
  "charges retrieve") echo '{"id":"ch_TEST","customer":"cus_TEST"}' ;;
  "customers retrieve") echo '{"id":"cus_TEST","balance":-5300}' ;;
  "get /v1/customers/cus_TEST/balance_transactions")
    n=$((n+1)); echo "$n" > "$STUB_STATE/nbt"
    # Planning performs FOUR balance-transaction reads before taking the lock
    # (summary, identity, amount, remediation marker); the locked re-reads are
    # #5 and #6. Shrinking from #5 is what isolates the locked path. If that read
    # sequence ever changes this test fails loudly rather than passing vacuously.
    if [ "$n" -le 4 ]; then
      # Planning: audited row fully live at 1000, plus an unrelated 5000.
      echo '{"object":"list","data":[
        {"id":"cbtxn_NEW","type":"invoice_too_small","amount":-5000,"ending_balance":-6000,"created":300,"metadata":{}},
        {"id":"cbtxn_AUDITED","type":"invoice_too_small","amount":-1000,"ending_balance":-1000,"created":100,"metadata":{}}]}'
    else
      # Under the lock: an invoice has since consumed 700 of the audited row.
      echo '{"object":"list","data":[
        {"id":"cbtxn_NEW","type":"invoice_too_small","amount":-5000,"ending_balance":-5300,"created":300,"metadata":{}},
        {"id":"cbtxn_INV","type":"applied_to_invoice","amount":700,"ending_balance":-300,"created":200,"metadata":{}},
        {"id":"cbtxn_AUDITED","type":"invoice_too_small","amount":-1000,"ending_balance":-1000,"created":100,"metadata":{}}]}'
    fi ;;
  "post /v1/customers/cus_TEST/balance_transactions") echo "WRITE $*" >> "$WRITE_LOG"; echo '{}' ;;
  *) echo "STRIPE_CALLED $*" ;;
esac
SH
  chmod +x "$BIN/stripe"
  printf 'customer_id,refund_id,credit_txn\ncus_TEST,re_TEST,cbtxn_AUDITED\n' >"$CSV"
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 123.456
  [[ "$(writes)" == *"amount=300"* ]]
  [[ "$(writes)" != *"amount=1000"* ]]
}

@test "--apply is restricted to Aaron until the new debit surface is authorized" {
  # Jan and Nick are on the refund allowlist, but this script debits live customer
  # balance — a capability that did not exist before it. Narrower until authorized.
  for who in U038BM16T7W U0AL36NADEY; do
    run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by "$who" --approval-msg-id 1.2
    [ "$status" -eq 2 ]
    [[ "$output" == *"restricted to Aaron"* ]]
    [ -z "$(writes)" ]
  done
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 1.2
  [ "$status" -eq 0 ]
}

@test "two audit rows for one customer: a spent first credit does not discard a live second" {
  # Deduping the CUSTOMER before validating the row's audited credit throws away
  # the live duplicate: row 1 (spent) claims the customer, row 2 (live) is
  # discarded as a duplicate row and never remediated.
  cat >"$BIN/stripe" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "refunds retrieve") echo '{"id":"re_TEST","status":"succeeded","charge":"ch_TEST"}' ;;
  "charges retrieve") echo '{"id":"ch_TEST","customer":"cus_TEST"}' ;;
  "customers retrieve")
    if [ -f "$STUB_STATE/applied" ]; then echo '{"id":"cus_TEST","balance":0}'
    else echo '{"id":"cus_TEST","balance":-4000}'; fi ;;
  "get /v1/customers/cus_TEST/balance_transactions")
    if [ -f "$STUB_STATE/applied" ]; then echo '{"object":"list","data":[]}'
    else echo '{"object":"list","data":[{"id":"cbtxn_LIVE2","type":"invoice_too_small","amount":-4000,"ending_balance":-4000,"created":200,"metadata":{}}]}'; fi ;;
  "post /v1/customers/cus_TEST/balance_transactions") echo "WRITE $*" >> "$WRITE_LOG"; : > "$STUB_STATE/applied"; echo '{}' ;;
  *) echo "STRIPE_CALLED $*" ;;
esac
SH
  chmod +x "$BIN/stripe"
  printf 'customer_id,refund_id,credit_txn\ncus_TEST,re_TEST,cbtxn_SPENT\ncus_TEST,re_TEST,cbtxn_LIVE2\n' >"$CSV"
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 1.2
  [[ "$output" != *"duplicate-row-for-customer"* ]]
  [[ "$(writes)" == *"amount=4000"* ]]
}

@test "two LIVE audited credits for one customer are BOTH remediated in one run" {
  # The durable marker was keyed only to RUN_TAG, so the first write made every
  # later row for that customer skip as already-remediated — leaving the second
  # duplicate concession live while the run exited successfully.
  cat >"$BIN/stripe" <<'SH'
#!/usr/bin/env bash
w=$(cat "$STUB_STATE/nw" 2>/dev/null || echo 0)
case "$1 $2" in
  "refunds retrieve") echo '{"id":"re_TEST","status":"succeeded","charge":"ch_TEST"}' ;;
  "charges retrieve") echo '{"id":"ch_TEST","customer":"cus_TEST"}' ;;
  "customers retrieve")
    if [ "$w" -ge 2 ]; then echo '{"id":"cus_TEST","balance":0}'
    elif [ "$w" -eq 1 ]; then echo '{"id":"cus_TEST","balance":-2000}'
    else echo '{"id":"cus_TEST","balance":-3000}'; fi ;;
  "get /v1/customers/cus_TEST/balance_transactions")
    if [ "$w" -ge 2 ]; then
      echo '{"object":"list","data":[]}'
    elif [ "$w" -eq 1 ]; then
      # After the first write: A is settled, B still live.
      echo '{"object":"list","data":[
        {"id":"cbtxn_FIX_A","type":"adjustment","amount":1000,"ending_balance":-2000,"created":400,"metadata":{"hydra_remediation":"test-run","source_credit":"cbtxn_A"}},
        {"id":"cbtxn_B","type":"invoice_too_small","amount":-2000,"ending_balance":-3000,"created":200,"metadata":{}},
        {"id":"cbtxn_A","type":"invoice_too_small","amount":-1000,"ending_balance":-1000,"created":100,"metadata":{}}]}'
    else
      echo '{"object":"list","data":[
        {"id":"cbtxn_B","type":"invoice_too_small","amount":-2000,"ending_balance":-3000,"created":200,"metadata":{}},
        {"id":"cbtxn_A","type":"invoice_too_small","amount":-1000,"ending_balance":-1000,"created":100,"metadata":{}}]}'
    fi ;;
  "post /v1/customers/cus_TEST/balance_transactions")
    # Enforce Stripe idempotency: a key already used with DIFFERENT parameters is
    # rejected. Without this the stub accepts key reuse that production refuses,
    # and the two-credit regression passes against code that cannot work.
    key=""; prev=""
    for a in "$@"; do case "$prev" in --idempotency) key="$a" ;; esac; prev="$a"; done
    if [ -n "$key" ]; then
      body="$(printf '%s\n' "$*" | sed 's/--idempotency [^ ]*//')"
      kf="$STUB_STATE/idem_$(printf '%s' "$key" | tr -c 'A-Za-z0-9_' _)"
      if [ -f "$kf" ] && [ "$(cat "$kf")" != "$body" ]; then
        echo "IDEMPOTENCY_MISMATCH $key" >&2; exit 1
      fi
      printf '%s' "$body" > "$kf"
    fi
    w=$((w+1)); echo "$w" > "$STUB_STATE/nw"; echo "WRITE $*" >> "$WRITE_LOG"; echo '{}' ;;
  *) echo "STRIPE_CALLED $*" ;;
esac
SH
  chmod +x "$BIN/stripe"
  printf 'customer_id,refund_id,credit_txn\ncus_TEST,re_TEST,cbtxn_A\ncus_TEST,re_TEST,cbtxn_B\n' >"$CSV"
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 1.2
  [[ "$output" != *"already-remediated"* ]]
  [ "$(printf '%s\n' "$(writes)" | grep -c '^WRITE')" -eq 2 ]
}

@test "two audited credits remediate fully even when the CSV lists them NEWEST-first" {
  # Our own debits are attributed FIFO (oldest concession first), so debiting the
  # NEWER credit first consumes the older one in the model and strands it. The
  # work must be ordered by the live transaction timestamps, not by CSV order.
  cat >"$BIN/stripe" <<'SH'
#!/usr/bin/env bash
w=$(cat "$STUB_STATE/nw" 2>/dev/null || echo 0)
case "$1 $2" in
  "refunds retrieve") echo '{"id":"re_TEST","status":"succeeded","charge":"ch_TEST"}' ;;
  "charges retrieve") echo '{"id":"ch_TEST","customer":"cus_TEST"}' ;;
  "customers retrieve")
    case "$w" in
      0) echo '{"id":"cus_TEST","balance":-3000}' ;;
      1) echo '{"id":"cus_TEST","balance":-2000}' ;;
      *) echo '{"id":"cus_TEST","balance":0}' ;;
    esac ;;
  "get /v1/customers/cus_TEST/balance_transactions")
    case "$w" in
      0) echo '{"object":"list","data":[
           {"id":"cbtxn_B","type":"invoice_too_small","amount":-2000,"ending_balance":-3000,"created":200,"metadata":{}},
           {"id":"cbtxn_A","type":"invoice_too_small","amount":-1000,"ending_balance":-1000,"created":100,"metadata":{}}]}' ;;
      1) echo '{"object":"list","data":[
           {"id":"cbtxn_FIX_A","type":"adjustment","amount":1000,"ending_balance":-2000,"created":400,"metadata":{"hydra_remediation":"test-run","source_credit":"cbtxn_A"}},
           {"id":"cbtxn_B","type":"invoice_too_small","amount":-2000,"ending_balance":-3000,"created":200,"metadata":{}},
           {"id":"cbtxn_A","type":"invoice_too_small","amount":-1000,"ending_balance":-1000,"created":100,"metadata":{}}]}' ;;
      *) echo '{"object":"list","data":[]}' ;;
    esac ;;
  "post /v1/customers/cus_TEST/balance_transactions")
    key=""; prev=""
    for a in "$@"; do case "$prev" in --idempotency) key="$a" ;; esac; prev="$a"; done
    if [ -n "$key" ]; then
      body="$(printf '%s\n' "$*" | sed 's/--idempotency [^ ]*//')"
      kf="$STUB_STATE/idem_$(printf '%s' "$key" | tr -c 'A-Za-z0-9_' _)"
      if [ -f "$kf" ] && [ "$(cat "$kf")" != "$body" ]; then echo "IDEMPOTENCY_MISMATCH" >&2; exit 1; fi
      printf '%s' "$body" > "$kf"
    fi
    w=$((w+1)); echo "$w" > "$STUB_STATE/nw"; echo "WRITE $*" >> "$WRITE_LOG"; echo '{}' ;;
  *) echo "STRIPE_CALLED $*" ;;
esac
SH
  chmod +x "$BIN/stripe"
  # CSV deliberately lists the NEWER credit first.
  printf 'customer_id,refund_id,credit_txn\ncus_TEST,re_TEST,cbtxn_B\ncus_TEST,re_TEST,cbtxn_A\n' >"$CSV"
  run "$SCRIPT" --audit-csv "$CSV" --apply --confirmed-by U7RP6HKUZ --approval-msg-id 1.2
  # The OLDER credit must be debited first, and both must complete.
  [ "$(printf '%s\n' "$(writes)" | grep -c '^WRITE')" -eq 2 ]
  [[ "$(printf '%s\n' "$(writes)" | head -1)" == *"amount=1000"* ]]
}
