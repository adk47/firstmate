#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# stripe-credit.sh — sourceable helpers for detecting a LIVE customer-balance
# concession credit before we hand the same customer cash.
#
# Sourced by scripts/muso-stripe-write.sh (the money gate) and
# scripts/remediate-refund-credit-overlap.sh; unit-tested by
# scripts/tests/stripe-credit-lib.bats. The classification function reads
# balance-transaction JSON on STDIN and echoes lines, so it is testable with
# fixtures and never calls `stripe` itself — the same pure-function pattern as
# scripts/lib/codex-health.sh and scripts/lib/drift-check.sh.
#
# WHY THIS EXISTS
# A Stripe customer-balance credit and a cash refund are the SAME concession
# paid twice. When a customer downgrades (e.g. annual → monthly), Stripe cannot
# finalize the resulting negative invoice, so it parks the unused-time money on
# the customer balance as an `invoice_too_small` credit. If support then also
# refunds the original charge to the card, the customer is paid twice and the
# credit silently pays their next invoices until it runs out.
#
# A finance audit on 2026-09-09 (2,341 refunds, 2021-09 → 2026-09) found 223
# customers in exactly that state, $4,827.65 of duplicate concession. The
# exemplar is refund re_3SacfBLsjTo3Ar3l1nCLgQ5C: $107.50 cash on 2025-12-05,
# plus a $117.72 `invoice_too_small` credit minted 0.96h later, which then paid
# nine monthly invoices Jan–Sep 2026 before anyone noticed.
#
# The doctrine that produced it (skills-all/muso-refund-investigation) told the
# agent the credit balance WAS the correct refund amount and never said to zero
# it. Prose is not enforcement — this library is.
# ──────────────────────────────────────────────────────────────

# credit_live_window_credits — PURE. Balance-transactions JSON on stdin.
#
# CONCESSION-CLASS TYPES (the list is inline in the jq below, single source):
# the Stripe-minted proration/credit-note family — transaction types Stripe
# writes ITSELF when an invoice nets negative or a credit note is issued. Each
# represents unused time or an invoice correction the customer has already been
# compensated for in product form:
#   invoice_too_small      — the negative-proration case (the 223-customer bug)
#   invoice_too_large      — the mirror case
#   unapplied_from_invoice — invoice voided/uncollectible, money back to balance
#   credit_note            — a support-issued credit note
# plus untagged `adjustment` — see the WHY below.
#
# Echoes one line per concession-class credit that composes the customer's
# CURRENT balance: "<cbtxn_id> <type> <amount_cents>". Echoes nothing when the
# live balance contains no such credit. Non-zero EXIT = UNVERIFIABLE; every
# caller must fail closed on that.
#
# "Live window" = transactions created after the most recent transaction whose
# `ending_balance` was 0. Stripe returns balance transactions newest-first, so
# that is the leading slice of `.data`. This is what keeps the gate off a
# customer whose proration credit was fully spent months ago and who now holds
# an unrelated fresh credit — only what is actually still owed can block a
# refund. It is also what makes this predicate's scope identical to the
# remediation's scope, so the gate never strays into clawing back credit the
# customer has already consumed as service.
#
# WHY `adjustment` COUNTS, BUT ONLY UNTAGGED
# `POST /v1/customers/:id/balance_transactions` — every manual credit, whether
# written by our code or typed into the Stripe dashboard — is typed `adjustment`
# by Stripe. Type alone therefore cannot separate "referral reward we minted on
# purpose" from "goodwill credit a human handed out, then also refunded in cash".
# Our own writes carry `metadata` (e.g. awardReferrerReferralCreditForOrder.js
# sets it alongside idempotencyKey `referral_reward_<id>_referrer`); a credit
# typed into the dashboard normally does not. So an `adjustment` with EMPTY
# metadata is treated as an untagged manual concession and counts.
#
# This is a deliberate widening beyond the pure proration bug. On 2026-07-13/14,
# 189 accounts received a manual $10 `adjustment` credit and then a $10 cash
# refund the next day — 79% of all the dollars the audit flagged. A
# proration-only predicate would not have stopped it. 51 of the 62 customers who
# still hold unearned credit today are `adjustment`, not `invoice_too_small`.
#
# KNOWN CONSEQUENCE, and it is intended: core-backend's
# applyCreditBalanceToCustomer() writes offer credits with a description but NO
# metadata, so an unspent offer credit also trips this. Handing cash on top of an
# unspent offer credit is the same double concession, so the refusal is correct;
# it is waivable by an allowlisted approver like every other wall here.
# credit_live_window_eval — PURE, the single computation both public helpers use.
# Balance-transactions JSON on stdin. Emits:
#   line 1  : the NET reclaimable concession, positive cents (0 if none)
#   line 2+ : "<cbtxn_id> <type> <amount>" per concession row, ONLY when net > 0
# Non-zero EXIT = UNVERIFIABLE.
#
# WHY NETTING, AND NOT AN ending_balance:0 BOUNDARY
# The first version bounded the live window solely by an exact `ending_balance: 0`
# row. On a mixed balance that row never appears after a partial remediation:
# reclaiming an 11772 concession from a -13772 balance (concession + a 2000 tagged
# referral) leaves -2000 and a history of [+11772 ours, -2000 referral, -11772
# concession]. No zero boundary exists, so the old concession still counted as
# live — and `min(concession, live credit)` then offered up the 2000 referral for
# a later run to debit. Legitimate money, taken by an automated sweep, because
# the helper could not see that our own debit had already settled the concession.
#
# So: net the ordered ledger instead. Every POSITIVE transaction in the window is
# treated as consuming concession credit FIRST. That is the worst-case-for-us
# attribution — Stripe attributes nothing, so any allocation is a model, and this
# is the one that can only ever UNDER-state what we may reclaim. Same principle as
# decideProrationRefundOffset's debitsSince in core-backend.
#
# The zero boundary is still used, but only as a scan optimisation: everything at
# or before it provably nets to zero, so slicing there is exact and cheaper.
credit_live_window_eval() {
  # -s (slurp) is load-bearing: without it EMPTY stdin — exactly what a failed
  # `stripe` read produces — runs the filter zero times, emits nothing and exits
  # 0, so the caller reads "no credit" and ALLOWS the refund. A fail-OPEN in the
  # one place that must fail closed.
  jq -r -s '
    def is_concession:
      (((.type // "") | IN("invoice_too_small", "invoice_too_large",
                           "unapplied_from_invoice", "credit_note"))
       or ((.type // "") == "adjustment" and ((.metadata // {}) | length) == 0));

    if length != 1 then error("empty or multi-document payload") else .[0] end
    | if type != "object" or (has("data") | not) then error("not a balance-transaction list")
      elif (.data | type) != "array" then error("not a balance-transaction list")
      else . end
    # STRICT PER-ROW SCHEMA, and it fails CLOSED.
    #
    # `.amount // 0` and `.type // ""` used to coerce an unreadable row into a
    # harmless-looking non-concession worth nothing. A row marked
    # invoice_too_small but missing `amount` therefore reported 0 live concession
    # and exited 0, so the money gate allowed a cash refund on top of a credit it
    # could not read. A parser that cannot read its input must refuse, not guess —
    # the same rule as the empty-stdin case above.
    #
    # `metadata` is required on `adjustment` specifically because that is the one
    # type whose concession status DEPENDS on it. Guessing is unsafe in both
    # directions: treating absent as untagged over-reclaims in the remediation,
    # treating it as tagged misses a concession in the gate. Other types never
    # consult it, so it may be absent there.
    | ([ .data[]
         | select(
             ((has("id") and (.id | type == "string"))
              and (has("type") and (.type | type == "string"))
              and (has("amount") and (.amount | type == "number"))
              and (has("ending_balance") and (.ending_balance | type == "number"))
              and (has("created") and (.created | type == "number"))
              and ((has("metadata") | not) or (.metadata | type == "object"))
              and ((.type != "adjustment")
                   or (has("metadata") and (.metadata | type == "object")))
             ) | not) ] | length) as $malformed
    | if $malformed > 0 then
        error("\($malformed) malformed balance-transaction row(s): required id/type strings, numeric amount/ending_balance/created, object metadata on adjustment")
      else . end
    | .data as $t
    | ([$t[] | .ending_balance] | index(0)) as $z
    | (if $z == null then
         (if ($t | length) >= 100 then error("full page, no zero boundary") else $t end)
       else $t[0:$z] end) as $live
    # CHRONOLOGICAL ORDER IS THE WHOLE POINT. Sort by `created`, not by array
    # position: the API returns newest-first, but relying on that alone would
    # mis-net any payload that arrives in another order. `reverse` first so that
    # rows sharing a `created` second keep API order under jq stable sort.
    | ($live | reverse | sort_by(.created // 0)) as $chron
    # Walk oldest -> newest with two pools: concession credit and everything else.
    # A debit can only consume credit that ALREADY EXISTS, which is exactly what
    # the previous version got wrong — it subtracted every positive row from every
    # concession, including debits that predated the concession entirely.
    # Within what exists, a debit eats CONCESSION first: that minimises what we
    # believe is reclaimable, so the error direction is always under-reclaim.
    | (reduce $chron[] as $r ({c: 0, o: 0};
         (($r.amount // 0)) as $a
         | if $a < 0 then
             (if ($r | is_concession) then .c += (-$a) else .o += (-$a) end)
           elif $a > 0 then
             ([.c, $a] | min) as $tc
             | .c -= $tc
             | .o -= ([.o, ($a - $tc)] | min)
           else . end)) as $st
    | $st.c as $net
    # Name the rows still carrying live credit. Consumption is FIFO over the
    # concessions in time order, so the survivors are the tail once the consumed
    # amount has been eaten from the front.
    | [$chron[] | select((.amount // 0) < 0 and is_concession)] as $crows
    | (([$crows[] | -.amount] | add // 0) - $net) as $consumed
    # Consumption is FIFO over the concessions in time order, so the survivors
    # are the tail once `$consumed` has been eaten from the front — and the FIRST
    # survivor may be only PARTLY live. Emit the REMAINING amount of each row,
    # not the original face value: a caller clamping a write to one audited
    # transaction needs what is left of THAT row, and the face value would let it
    # reclaim credit an invoice already consumed.
    # (No apostrophes in here: this comment sits inside a single-quoted jq
    #  program, and one would terminate the string.)
    | (reduce $crows[] as $r ({left: $consumed, keep: []};
         (-($r.amount // 0)) as $amt
         | if .left >= $amt then .left -= $amt
           else .keep += [{id: $r.id, type: $r.type, remaining: ($amt - .left)}] | .left = 0 end)) as $kept
    | "\($net)", (if $net > 0 then ($kept.keep[] | "\(.id) \(.type) \(-.remaining)") else empty end)
  ' 2>/dev/null
}

# credit_live_window_credits — PURE. Balance-transactions JSON on stdin.
#
# CONCESSION-CLASS TYPES (the list is inline in the jq below, single source):
# the Stripe-minted proration/credit-note family — transaction types Stripe
# writes ITSELF when an invoice nets negative or a credit note is issued. Each
# represents unused time or an invoice correction the customer has already been
# compensated for in product form:
#   invoice_too_small      — the negative-proration case (the 223-customer bug)
#   invoice_too_large      — the mirror case
#   unapplied_from_invoice — invoice voided/uncollectible, money back to balance
#   credit_note            — a support-issued credit note
# plus untagged `adjustment` — see the WHY below.
#
# Echoes one line per concession-class credit that composes the customer's
# CURRENT balance: "<cbtxn_id> <type> <amount_cents>". Echoes nothing when the
# live balance contains no such credit. Non-zero EXIT = UNVERIFIABLE; every
# caller must fail closed on that.
#
# "Live window" = transactions created after the most recent transaction whose
# `ending_balance` was 0. Stripe returns balance transactions newest-first, so
# that is the leading slice of `.data`. This is what keeps the gate off a
# customer whose proration credit was fully spent months ago and who now holds
# an unrelated fresh credit — only what is actually still owed can block a
# refund. It is also what makes this predicate's scope identical to the
# remediation's scope, so the gate never strays into clawing back credit the
# customer has already consumed as service.
#
# WHY `adjustment` COUNTS, BUT ONLY UNTAGGED
# `POST /v1/customers/:id/balance_transactions` — every manual credit, whether
# written by our code or typed into the Stripe dashboard — is typed `adjustment`
# by Stripe. Type alone therefore cannot separate "referral reward we minted on
# purpose" from "goodwill credit a human handed out, then also refunded in cash".
# Our own writes carry `metadata` (e.g. awardReferrerReferralCreditForOrder.js
# sets it alongside idempotencyKey `referral_reward_<id>_referrer`); a credit
# typed into the dashboard normally does not. So an `adjustment` with EMPTY
# metadata is treated as an untagged manual concession and counts.
#
# This is a deliberate widening beyond the pure proration bug. On 2026-07-13/14,
# 189 accounts received a manual $10 `adjustment` credit and then a $10 cash
# refund the next day — 79% of all the dollars the audit flagged. A
# proration-only predicate would not have stopped it. 51 of the 62 customers who
# still hold unearned credit today are `adjustment`, not `invoice_too_small`.
#
# KNOWN CONSEQUENCE, and it is intended: core-backend's
# applyCreditBalanceToCustomer() writes offer credits with a description but NO
# metadata, so an unspent offer credit also trips this. Handing cash on top of an
# unspent offer credit is the same double concession, so the refusal is correct;
# it is waivable by an allowlisted approver like every other wall here.

# credit_live_window_credits — PURE. Balance-transactions JSON on stdin.
#
# Echoes one line per concession credit that is still reclaimable:
# "<cbtxn_id> <type> <amount>". Echoes nothing when the netted total is zero.
# Non-zero EXIT = UNVERIFIABLE; every caller must fail closed on that.
#
# CONCESSION-CLASS TYPES (the list lives once, in credit_live_window_eval):
# the Stripe-minted proration/credit-note family — types Stripe writes ITSELF
# when an invoice nets negative or a credit note is issued:
#   invoice_too_small      — the negative-proration case (the 223-customer bug)
#   invoice_too_large      — the mirror case
#   unapplied_from_invoice — invoice voided/uncollectible, money back to balance
#   credit_note            — a support-issued credit note
# plus untagged `adjustment` — see below.
#
# WHY `adjustment` COUNTS, BUT ONLY UNTAGGED
# `POST /v1/customers/:id/balance_transactions` — every manual credit, ours or a
# human's in the dashboard — is typed `adjustment` by Stripe, so type alone cannot
# separate "referral reward we minted on purpose" from "goodwill credit someone
# typed in and then also refunded in cash". Our writes carry `metadata`; a
# dashboard credit normally does not. An `adjustment` with EMPTY metadata is
# therefore treated as an untagged manual concession and counts.
#
# That widening is deliberate: on 2026-07-13/14, 189 accounts got a manual $10
# credit and a $10 cash refund the next day — 79% of every dollar the audit
# flagged. A proration-only predicate misses that entire class.
#
# KNOWN CONSEQUENCE, intended: core-backend's applyCreditBalanceToCustomer()
# writes offer credits with a description but NO metadata, so an unspent offer
# credit also trips this. Cash on top of an unspent offer credit is the same
# double concession, and the refusal is waivable by an allowlisted approver.
credit_live_window_credits() {
  local out
  out="$(credit_live_window_eval)" || return 1
  printf '%s\n' "$out" | tail -n +2 | sed '/^$/d'
}

# credit_live_window_total — PURE. Balance-transactions JSON on stdin.
# Echoes the NET reclaimable concession in positive cents (0 when none).
# Non-zero EXIT = UNVERIFIABLE.
credit_live_window_total() {
  local out
  out="$(credit_live_window_eval)" || return 1
  printf '%s\n' "$out" | head -1
}

# customer_live_concession_rows <customer_id> — IO wrapper echoing one
# "<cbtxn_id> <type> <amount>" line per still-reclaimable concession row.
# Non-zero EXIT = UNVERIFIABLE.
#
# Callers that must identify a SPECIFIC audited transaction need the row ids as
# discrete tokens, not embedded in a human-readable summary string: a substring
# test on that summary lets a truncated or prefix id match a different
# transaction entirely.
customer_live_concession_rows() {
  local cus="$1" btjson
  [ -n "$cus" ] || return 1
  btjson="$("${STRIPE_BIN:-stripe}" get "/v1/customers/$cus/balance_transactions" -d "limit=100" 2>/dev/null)" || return 1
  printf '%s' "$btjson" | credit_live_window_credits
}

# customer_audited_concession_amount <customer_id> <cbtxn_id> — echoes the
# POSITIVE cents that may safely be reclaimed from THAT SPECIFIC transaction:
#   min(remaining on that row, live credit balance)
# Echoes 0 when the row is not live. Non-zero EXIT = UNVERIFIABLE.
#
# Membership alone is not enough. The aggregate across every live concession can
# be far larger than the audited row: audited 1000 with 500 consumed, plus an
# unrelated 5000 for another period, aggregates to 5500 — and debiting that takes
# 5000 that was never a duplicate.
customer_audited_concession_amount() {
  local cus="$1" want="$2" rows live bal id _type amt
  [ -n "$cus" ] && [ -n "$want" ] || return 1
  bal="$(customer_raw_balance "$cus")" || return 1
  [ "$bal" -lt 0 ] || { echo 0; return 0; }
  live="${bal#-}"
  rows="$(customer_live_concession_rows "$cus")" || return 1
  while read -r id _type amt; do
    if [ "$id" = "$want" ]; then
      amt="${amt#-}"
      [[ "$amt" =~ ^[0-9]+$ ]] || return 1
      if [ "$amt" -lt "$live" ]; then echo "$amt"; else echo "$live"; fi
      return 0
    fi
  done <<< "$rows"
  echo 0
}

# customer_raw_balance <customer_id> — echoes Stripe's customer.balance verbatim
# (NEGATIVE = credit we owe them, POSITIVE = they owe us). Non-zero EXIT =
# UNVERIFIABLE.
#
# Every other helper here deliberately collapses a positive balance to "no
# credit", which is right for deciding whether to reclaim anything — but it
# makes an over-debit INVISIBLE, because a customer we accidentally pushed into
# debit reads identically to one with a clean zero balance. Any caller asserting
# "we did not leave this customer owing money" must use the raw figure.
customer_raw_balance() {
  local cus="$1" cjson bal
  [ -n "$cus" ] || return 1
  cjson="$("${STRIPE_BIN:-stripe}" customers retrieve "$cus" 2>/dev/null)" || return 1
  printf '%s' "$cjson" | jq -e 'type == "object" and has("balance")' >/dev/null 2>&1 || return 1
  bal="$(printf '%s' "$cjson" | jq -r '.balance')"
  [[ "$bal" =~ ^-?[0-9]+$ ]] || return 1
  echo "$bal"
}

# customer_live_concession_amount <customer_id> — IO wrapper. Echoes the
# POSITIVE cents that may safely be reclaimed from this customer:
#   min(sum of live concession credits, live credit balance)
# Non-zero EXIT = UNVERIFIABLE (caller must fail closed). Echoes 0 when there is
# nothing to reclaim.
#
# The min() is the safety clamp: the concession sum can never exceed what is
# actually on the balance right now (some of it may already be spent), and the
# balance can never be reclaimed beyond the concession part (the rest may be
# referral/offer credit). Whichever is smaller is the only defensible figure.
customer_live_concession_amount() {
  local cus="$1" cjson bal btjson total live
  [ -n "$cus" ] || return 1
  cjson="$("${STRIPE_BIN:-stripe}" customers retrieve "$cus" 2>/dev/null)" || return 1
  printf '%s' "$cjson" | jq -e 'type == "object" and has("balance")' >/dev/null 2>&1 || return 1
  bal="$(printf '%s' "$cjson" | jq -r '.balance')"
  [[ "$bal" =~ ^-?[0-9]+$ ]] || return 1
  [ "$bal" -lt 0 ] || { echo 0; return 0; }
  live="${bal#-}"
  btjson="$("${STRIPE_BIN:-stripe}" get "/v1/customers/$cus/balance_transactions" -d "limit=100" 2>/dev/null)" || return 1
  total="$(printf '%s' "$btjson" | credit_live_window_total)" || return 1
  [[ "$total" =~ ^[0-9]+$ ]] || return 1
  if [ "$total" -lt "$live" ]; then echo "$total"; else echo "$live"; fi
}

# customer_live_proration_credit <customer_id> — IO wrapper around the above.
#
# Echoes "" when there is nothing live to double-pay, or a human-readable
# summary when there is:
#   "<balance_cents> via cbtxn_XXX(invoice_too_small) cbtxn_YYY(adjustment)"
# Non-zero EXIT = UNVERIFIABLE (caller fails closed).
#
# Reads `.balance`, NOT `.cash_balance` — they are different objects and only
# `.balance` is the invoice-credit ledger this gate is about. Someone will
# eventually try to "fix" that; do not.
#
# Sign convention: Stripe's customer `.balance` is NEGATIVE when the customer
# holds credit and POSITIVE when they owe us money. A positive balance must
# therefore pass the gate — refusing a refund because someone is in debit would
# be nonsense. (core-backend's getCustomerBalance() takes Math.abs() of this and
# is consequently unable to tell the two apart; do not port that mistake here.)
#
# NOTE: confirm the balance-transactions wire form live on node-8; the raw
# `get /v1/...` shape is used because muso-stripe-write.sh already treats raw
# `post /v1/refunds` as a reachable form. The bats pin the LOGIC.
customer_live_proration_credit() {
  local cus="$1" cjson bal btjson credits ids
  [ -n "$cus" ] || return 1
  cjson="$("${STRIPE_BIN:-stripe}" customers retrieve "$cus" 2>/dev/null)" || return 1
  # The key must be PRESENT. An error-shaped payload, or Stripe API drift that
  # renames the field, must fail CLOSED rather than read as "no credit" and
  # silently disarm the gate — same rule as the has("invoice") check on the
  # subscription-lineage walk.
  printf '%s' "$cjson" | jq -e 'type == "object" and has("balance")' >/dev/null 2>&1 || return 1
  bal="$(printf '%s' "$cjson" | jq -r '.balance')"
  [[ "$bal" =~ ^-?[0-9]+$ ]] || return 1
  # >= 0 means no credit (0 = settled, > 0 = customer owes us). Nothing to double-pay.
  [ "$bal" -lt 0 ] || { echo ""; return 0; }

  btjson="$("${STRIPE_BIN:-stripe}" get "/v1/customers/$cus/balance_transactions" -d "limit=100" 2>/dev/null)" || return 1
  credits="$(printf '%s' "$btjson" | credit_live_window_credits)" || return 1
  [ -n "$credits" ] || { echo ""; return 0; }

  ids="$(printf '%s\n' "$credits" | awk '{printf "%s%s(%s)", (NR>1 ? " " : ""), $1, $2}')"
  echo "$bal via $ids"
}
