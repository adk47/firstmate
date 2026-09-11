#!/usr/bin/env bats
# Tests for scripts/lib/stripe-credit.sh — the predicate deciding whether a customer
# holds a LIVE concession credit that a cash refund would pay a second time.
#
# credit_live_window_credits is pure (JSON on stdin), so these are fixture tests with no
# `stripe` involved. The wiring into the money gate is covered separately by
# scripts/tests/muso-stripe-write.bats.
#
# The contract under test, in one line: echo the offending credits, echo NOTHING when
# there are none, and EXIT NON-ZERO when the answer cannot be determined. Callers treat
# non-zero as "refuse the refund", so every unverifiable case below is a money-path
# fail-closed assertion, not a cosmetic one.
bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/scripts/lib/stripe-credit.sh"
}

# --- Fires: genuine live concession credit -----------------------------------

@test "live invoice_too_small credit is reported" {
  run --separate-stderr bash -c "source '$REPO_ROOT/scripts/lib/stripe-credit.sh'; \
    echo '{\"data\":[{\"id\":\"cbtxn_A\",\"type\":\"invoice_too_small\",\"amount\":-11772,\"ending_balance\":-11772,\"created\":1}]}' \
    | credit_live_window_credits"
  [ "$status" -eq 0 ]
  [ "$output" = "cbtxn_A invoice_too_small -11772" ]
}

@test "live credit_note is reported" {
  run bash -c "source '$REPO_ROOT/scripts/lib/stripe-credit.sh'; \
    echo '{\"data\":[{\"id\":\"cbtxn_C\",\"type\":\"credit_note\",\"amount\":-5000,\"ending_balance\":-5000,\"created\":1}]}' \
    | credit_live_window_credits"
  [ "$status" -eq 0 ]
  [ "$output" = "cbtxn_C credit_note -5000" ]
}

@test "UNTAGGED adjustment is reported (the 2026-07 manual-credit cluster)" {
  # 189 accounts got a hand-entered \$10 credit on Jul 13 and a \$10 cash refund on
  # Jul 14 — 79% of every dollar the audit flagged. A proration-only predicate misses
  # this entire class, which is why untagged adjustments count.
  run bash -c "source '$REPO_ROOT/scripts/lib/stripe-credit.sh'; \
    echo '{\"data\":[{\"id\":\"cbtxn_J\",\"type\":\"adjustment\",\"amount\":-1000,\"ending_balance\":-1000,\"created\":1,\"metadata\":{}}]}' \
    | credit_live_window_credits"
  [ "$status" -eq 0 ]
  [ "$output" = "cbtxn_J adjustment -1000" ]
}

@test "mixed live window reports only the concession credit, not the tagged one" {
  run bash -c "source '$REPO_ROOT/scripts/lib/stripe-credit.sh'; \
    echo '{\"data\":[{\"id\":\"cbtxn_R\",\"type\":\"adjustment\",\"amount\":-2000,\"ending_balance\":-13772,\"created\":1,\"metadata\":{\"referralId\":\"r1\"}},{\"id\":\"cbtxn_P\",\"type\":\"invoice_too_small\",\"amount\":-11772,\"ending_balance\":-11772,\"created\":1}]}' \
    | credit_live_window_credits"
  [ "$status" -eq 0 ]
  [ "$output" = "cbtxn_P invoice_too_small -11772" ]
}

# --- Does NOT fire: the false-refusal guards ---------------------------------

@test "TAGGED adjustment (our own referral credit) is NOT reported" {
  # THE false-refusal guard. Referral rewards and offer credits we minted on purpose
  # carry metadata; they are not this charge's unused time and must not block a refund.
  run bash -c "source '$REPO_ROOT/scripts/lib/stripe-credit.sh'; \
    echo '{\"data\":[{\"id\":\"cbtxn_R\",\"type\":\"adjustment\",\"amount\":-2000,\"ending_balance\":-2000,\"created\":1,\"metadata\":{\"referralId\":\"r1\"}}]}' \
    | credit_live_window_credits"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "credit already spent past an ending_balance:0 boundary is NOT reported" {
  # We do not claw back consumed credit — it reached the customer as service. This is
  # what keeps the gate's scope identical to the remediation's scope.
  run bash -c "source '$REPO_ROOT/scripts/lib/stripe-credit.sh'; \
    echo '{\"data\":[{\"id\":\"cbtxn_N\",\"type\":\"adjustment\",\"amount\":-500,\"ending_balance\":-500,\"created\":1,\"metadata\":{\"x\":\"1\"}},{\"id\":\"cbtxn_Z\",\"type\":\"applied_to_invoice\",\"amount\":11772,\"ending_balance\":0,\"created\":1},{\"id\":\"cbtxn_OLD\",\"type\":\"invoice_too_small\",\"amount\":-11772,\"ending_balance\":-11772,\"created\":1}]}' \
    | credit_live_window_credits"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "POSITIVE amount (a debit, not a credit) is NOT reported" {
  run bash -c "source '$REPO_ROOT/scripts/lib/stripe-credit.sh'; \
    echo '{\"data\":[{\"id\":\"cbtxn_D\",\"type\":\"adjustment\",\"amount\":500,\"ending_balance\":500,\"created\":1,\"metadata\":{}}]}' \
    | credit_live_window_credits"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "empty transaction list is NOT reported (and is not an error)" {
  run bash -c "source '$REPO_ROOT/scripts/lib/stripe-credit.sh'; \
    echo '{\"data\":[]}' | credit_live_window_credits"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- Unverifiable: every one of these must fail CLOSED -----------------------

@test "EMPTY payload exits non-zero (a failed stripe read must never read as 'no credit')" {
  # Regression pin. Without `jq -s`, empty stdin runs the filter zero times, emits
  # nothing and exits 0 — so a broken Stripe read would have ALLOWED the refund. That is
  # a fail-OPEN in the one place that must fail closed.
  run bash -c "source '$REPO_ROOT/scripts/lib/stripe-credit.sh'; \
    printf '' | credit_live_window_credits"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "error-shaped payload exits non-zero" {
  run bash -c "source '$REPO_ROOT/scripts/lib/stripe-credit.sh'; \
    echo '{\"error\":{\"message\":\"no such customer\"}}' | credit_live_window_credits"
  [ "$status" -ne 0 ]
}

@test "payload whose data is not a list exits non-zero" {
  run bash -c "source '$REPO_ROOT/scripts/lib/stripe-credit.sh'; \
    echo '{\"data\":{\"id\":\"cbtxn_A\"}}' | credit_live_window_credits"
  [ "$status" -ne 0 ]
}

@test "non-JSON payload exits non-zero" {
  run bash -c "source '$REPO_ROOT/scripts/lib/stripe-credit.sh'; \
    echo 'STRIPE_CALLED customers retrieve cus_X' | credit_live_window_credits"
  [ "$status" -ne 0 ]
}

@test "FULL page with no zero boundary exits non-zero (cannot see which credits are live)" {
  run bash -c "source '$REPO_ROOT/scripts/lib/stripe-credit.sh'; \
    python3 -c \"import json;print(json.dumps({'data':[{'id':'cbtxn_%d'%i,'type':'applied_to_invoice','amount':100,'ending_balance':-500,'created':i,'metadata':{}} for i in range(100)]}))\" \
    | credit_live_window_credits"
  [ "$status" -ne 0 ]
}

@test "FULL page WITH a zero boundary resolves normally (fullness alone is not a refusal)" {
  # The adjacent case to the one above: refusing on page-fullness per se would refuse
  # every high-volume customer forever. Only an UNRESOLVABLE full page refuses.
  run bash -c "source '$REPO_ROOT/scripts/lib/stripe-credit.sh'; \
    python3 -c \"import json
d=[{'id':'cbtxn_LIVE','type':'invoice_too_small','amount':-11772,'ending_balance':-11772,'created':999,'metadata':{}}]
d+=[{'id':'cbtxn_Z','type':'applied_to_invoice','amount':5,'ending_balance':0,'created':500,'metadata':{}}]
d+=[{'id':'cbtxn_%d'%i,'type':'adjustment','amount':-1,'ending_balance':-1,'created':i,'metadata':{}} for i in range(98)]
print(json.dumps({'data':d}))\" | credit_live_window_credits"
  [ "$status" -eq 0 ]
  [ "$output" = "cbtxn_LIVE invoice_too_small -11772" ]
}

# --- credit_live_window_total: only the concession portion is reclaimable ----
#
# QA finding (Critical): the remediation debited the WHOLE negative balance. A
# balance can mix a concession with a referral/offer credit we minted on purpose,
# so zeroing it claws back money the customer was genuinely owed.

@test "concession total sums only concession credits, excluding a tagged referral" {
  run bash -c "source '$REPO_ROOT/scripts/lib/stripe-credit.sh'; \
    echo '{\"data\":[{\"id\":\"cbtxn_REF\",\"type\":\"adjustment\",\"amount\":-2000,\"ending_balance\":-13772,\"created\":1,\"metadata\":{\"referralId\":\"r1\"}},{\"id\":\"cbtxn_P\",\"type\":\"invoice_too_small\",\"amount\":-11772,\"ending_balance\":-11772,\"created\":1}]}' \
    | credit_live_window_total"
  [ "$status" -eq 0 ]
  # 11772, NOT the 13772 balance — the $20 referral is not ours to reclaim.
  [ "$output" = "11772" ]
}

@test "concession total is 0 when the only live credit is a tagged reward" {
  run bash -c "source '$REPO_ROOT/scripts/lib/stripe-credit.sh'; \
    echo '{\"data\":[{\"id\":\"cbtxn_REF\",\"type\":\"adjustment\",\"amount\":-2000,\"ending_balance\":-2000,\"created\":1,\"metadata\":{\"referralId\":\"r1\"}}]}' \
    | credit_live_window_total"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "concession total sums multiple concession credits" {
  run bash -c "source '$REPO_ROOT/scripts/lib/stripe-credit.sh'; \
    echo '{\"data\":[{\"id\":\"a\",\"type\":\"invoice_too_small\",\"amount\":-1000,\"ending_balance\":-3000,\"created\":1,\"metadata\":{}},{\"id\":\"b\",\"type\":\"credit_note\",\"amount\":-2000,\"ending_balance\":-2000,\"created\":1}]}' \
    | credit_live_window_total"
  [ "$status" -eq 0 ]
  [ "$output" = "3000" ]
}

@test "concession total exits non-zero on an unverifiable payload" {
  run bash -c "source '$REPO_ROOT/scripts/lib/stripe-credit.sh'; printf '' | credit_live_window_total"
  [ "$status" -ne 0 ]
}

# --- QA round 4, Critical: net the ledger, don't look for a zero boundary ----
#
# The live window was bounded ONLY by an exact `ending_balance: 0`. After a
# partial remediation on a mixed balance no such row exists, so the old
# concession credit still counted as live even though our own debit had already
# reclaimed it — and the next run would take the legitimate referral credit.

@test "post-remediation mixed history reports ZERO live concession" {
  run bash -c "source '$REPO_ROOT/scripts/lib/stripe-credit.sh'; echo '{\"data\":[
    {\"id\":\"cbtxn_FIX\",\"type\":\"adjustment\",\"amount\":11772,\"ending_balance\":-2000,\"created\":1,\"metadata\":{\"hydra_remediation\":\"r1\"}},
    {\"id\":\"cbtxn_REF\",\"type\":\"adjustment\",\"amount\":-2000,\"ending_balance\":-13772,\"created\":1,\"metadata\":{\"referralId\":\"r1\"}},
    {\"id\":\"cbtxn_P\",\"type\":\"invoice_too_small\",\"amount\":-11772,\"ending_balance\":-11772,\"created\":1,\"metadata\":{}}]}' \
    | credit_live_window_total"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "post-remediation mixed history lists NO live concession rows" {
  # The list feeds the money gate and the watchdog: if it still names the spent
  # concession, the gate refuses legitimate refunds and the watchdog false-pages.
  run bash -c "source '$REPO_ROOT/scripts/lib/stripe-credit.sh'; echo '{\"data\":[
    {\"id\":\"cbtxn_FIX\",\"type\":\"adjustment\",\"amount\":11772,\"ending_balance\":-2000,\"created\":1,\"metadata\":{\"hydra_remediation\":\"r1\"}},
    {\"id\":\"cbtxn_REF\",\"type\":\"adjustment\",\"amount\":-2000,\"ending_balance\":-13772,\"created\":1,\"metadata\":{\"referralId\":\"r1\"}},
    {\"id\":\"cbtxn_P\",\"type\":\"invoice_too_small\",\"amount\":-11772,\"ending_balance\":-11772,\"created\":1,\"metadata\":{}}]}' \
    | credit_live_window_credits"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an invoice partially consuming the concession nets down, not to zero" {
  # 11772 concession, a 5000 invoice debit since: 6772 remains reclaimable.
  run bash -c "source '$REPO_ROOT/scripts/lib/stripe-credit.sh'; echo '{\"data\":[
    {\"id\":\"cbtxn_INV\",\"type\":\"applied_to_invoice\",\"amount\":5000,\"ending_balance\":-6772,\"created\":1,\"metadata\":{}},
    {\"id\":\"cbtxn_P\",\"type\":\"invoice_too_small\",\"amount\":-11772,\"ending_balance\":-11772,\"created\":1,\"metadata\":{}}]}' \
    | credit_live_window_total"
  [ "$status" -eq 0 ]
  [ "$output" = "6772" ]
}

@test "debits never net BELOW zero into a negative reclaim" {
  run bash -c "source '$REPO_ROOT/scripts/lib/stripe-credit.sh'; echo '{\"data\":[
    {\"id\":\"cbtxn_BIG\",\"type\":\"applied_to_invoice\",\"amount\":99999,\"ending_balance\":88227,\"created\":1,\"metadata\":{}},
    {\"id\":\"cbtxn_P\",\"type\":\"invoice_too_small\",\"amount\":-11772,\"ending_balance\":-11772,\"created\":1,\"metadata\":{}}]}' \
    | credit_live_window_total"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "a tagged referral alone is still never reclaimable, netting or not" {
  run bash -c "source '$REPO_ROOT/scripts/lib/stripe-credit.sh'; echo '{\"data\":[
    {\"id\":\"cbtxn_REF\",\"type\":\"adjustment\",\"amount\":-2000,\"ending_balance\":-2000,\"created\":1,\"metadata\":{\"referralId\":\"r1\"}}]}' \
    | credit_live_window_total"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# --- The history table -------------------------------------------------------
#
# scripts/tests/fixtures/stripe-credit-histories.tsv enumerates realistic Stripe
# histories and their expected net + surviving rows. Review found THREE separate
# holes in this one function, and every one was a missing FIXTURE before it was a
# missing guard — so the shapes live in a table that is cheap to extend, and a new
# shape is one line rather than a new test.
@test "every history in the fixture table nets to its expected value" {
  local table="$REPO_ROOT/scripts/tests/fixtures/stripe-credit-histories.tsv"
  [ -f "$table" ]
  local checked=0 failures=0
  while IFS=$'\t' read -r name want_net want_ids json; do
    case "$name" in \#*|"") continue ;; esac
    checked=$((checked + 1))
    local got_net got_ids
    if ! got_net="$(printf '%s' "$json" | credit_live_window_total)"; then
      echo "ERR  $name: helper exited non-zero"; failures=$((failures + 1)); continue
    fi
    got_ids="$(printf '%s' "$json" | credit_live_window_credits | awk '{printf "%s%s", (NR>1?" ":""), $1}')"
    [ -z "$got_ids" ] && got_ids="-"
    if [ "$got_net" != "$want_net" ] || [ "$got_ids" != "$want_ids" ]; then
      echo "FAIL $name: net=$got_net (want $want_net) ids=[$got_ids] (want [$want_ids])"
      failures=$((failures + 1))
    fi
  done < "$table"
  # A table that silently stopped being read would pass vacuously.
  [ "$checked" -ge 18 ]
  [ "$failures" -eq 0 ]
}

@test "the fixture table is actually loaded (guards against a vacuous pass)" {
  local table="$REPO_ROOT/scripts/tests/fixtures/stripe-credit-histories.tsv"
  local n
  n="$(grep -cvE '^#|^$' "$table")"
  [ "$n" -ge 18 ]
}

# --- QA round 8, Critical: malformed rows must fail CLOSED ------------------
#
# `.amount // 0` and `.type // ""` silently coerce an unparseable row into a
# harmless-looking non-concession. A row marked invoice_too_small but missing
# `amount` reported 0 live concession and exit 0 — so the gate allowed a cash
# refund on top of a credit it could not read. Same class as the empty-stdin
# fail-open: a parser that cannot read its input must refuse, not guess.

@test "a concession row missing 'amount' fails closed" {
  run bash -c "source '$REPO_ROOT/scripts/lib/stripe-credit.sh'; \
    echo '{\"data\":[{\"id\":\"cbtxn_X\",\"type\":\"invoice_too_small\",\"ending_balance\":-11772,\"created\":300,\"metadata\":{}}]}' \
    | credit_live_window_total"
  [ "$status" -ne 0 ]
}

@test "a row with a non-numeric 'amount' fails closed" {
  run bash -c "source '$REPO_ROOT/scripts/lib/stripe-credit.sh'; \
    echo '{\"data\":[{\"id\":\"c\",\"type\":\"invoice_too_small\",\"amount\":\"-11772\",\"ending_balance\":-11772,\"created\":300,\"metadata\":{}}]}' \
    | credit_live_window_total"
  [ "$status" -ne 0 ]
}

@test "a row missing 'created' fails closed (ordering would be undefined)" {
  # NOTE: this fixture must NOT carry `created` — that is the whole point. A
  # bulk edit adding realistic fields to every fixture silently defeated it once.
  run bash -c "source '$REPO_ROOT/scripts/lib/stripe-credit.sh'; \
    echo '{\"data\":[{\"id\":\"c\",\"type\":\"invoice_too_small\",\"amount\":-11772,\"ending_balance\":-11772,\"metadata\":{}}]}' \
    | credit_live_window_total"
  [ "$status" -ne 0 ]
}

@test "a row missing 'ending_balance' fails closed (the window boundary needs it)" {
  run bash -c "source '$REPO_ROOT/scripts/lib/stripe-credit.sh'; \
    echo '{\"data\":[{\"id\":\"c\",\"type\":\"invoice_too_small\",\"amount\":-11772,\"created\":300,\"metadata\":{}}]}' \
    | credit_live_window_total"
  [ "$status" -ne 0 ]
}

@test "a row missing 'type' fails closed rather than becoming a non-concession" {
  run bash -c "source '$REPO_ROOT/scripts/lib/stripe-credit.sh'; \
    echo '{\"data\":[{\"id\":\"c\",\"amount\":-11772,\"ending_balance\":-11772,\"created\":300,\"metadata\":{}}]}' \
    | credit_live_window_total"
  [ "$status" -ne 0 ]
}

@test "an adjustment with NON-object metadata fails closed" {
  run bash -c "source '$REPO_ROOT/scripts/lib/stripe-credit.sh'; \
    echo '{\"data\":[{\"id\":\"c\",\"type\":\"adjustment\",\"amount\":-2000,\"ending_balance\":-2000,\"created\":300,\"metadata\":\"nope\"}]}' \
    | credit_live_window_total"
  [ "$status" -ne 0 ]
}

@test "an adjustment with metadata ABSENT fails closed (tagged vs untagged is undecidable)" {
  # Guessing here is not safe in either direction: counting it risks over-reclaim
  # in the remediation, ignoring it risks a missed concession in the gate.
  run bash -c "source '$REPO_ROOT/scripts/lib/stripe-credit.sh'; \
    echo '{\"data\":[{\"id\":\"c\",\"type\":\"adjustment\",\"amount\":-2000,\"ending_balance\":-2000,\"created\":300}]}' \
    | credit_live_window_total"
  [ "$status" -ne 0 ]
}
