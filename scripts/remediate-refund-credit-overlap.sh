#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# remediate-refund-credit-overlap.sh — zero the customer-balance credit that a
# cash refund already paid for, one customer at a time, idempotently.
#
# WHY
# A 2026-09-09 finance audit found 223 customers who received BOTH a cash refund
# and a customer-balance concession credit for the same unused period
# ($4,827.65). Of those, 62 still hold unspent credit. This returns that credit.
# It does NOT touch the ~$3,259.88 already consumed — that money reached the
# customer as service, and clawing it back would bill people who did nothing
# wrong.
#
# SAFETY MODEL — read this before --apply
#   * DRY-RUN BY DEFAULT. --apply is explicit and additionally requires
#     --confirmed-by <allowlisted> --approval-msg-id <ts>.
#   * THE AUDIT CSV IS A CANDIDATE LIST, NEVER AN AUTHORITY. Every amount is
#     recomputed from LIVE Stripe and clamped to it. This is not theoretical:
#     between the audit's 2026-09-08 cutoff and 2026-09-10, four customers had
#     already spent part or all of the flagged credit — cus_QdFL2zz46PRD19 shows
#     $60.00 outstanding in the workbook and $0.00 live. Writing the workbook
#     figure there would invent a $60 debit against someone who owes nothing.
#   * It only ever DEBITS a live credit toward zero. It can never mint credit,
#     never push a customer into debit, and never exceed what is live right now.
#   * Writes go through muso-stripe-write.sh so the codex-health gate applies.
#   * Breakers: per-customer cap, whole-run total cap, --limit, --customer.
#
# Idempotency comes from three independent places, not from a Stripe
# idempotency key (whose CLI support is unconfirmed here): the live-balance
# precondition, our own metadata marker on the write, and the post-write
# read-back. A second run reports every row as already-clear.
#
# Usage:
#   remediate-refund-credit-overlap.sh --audit-csv <path> [--dry-run]
#   remediate-refund-credit-overlap.sh --audit-csv <path> --apply \
#       --confirmed-by U7RP6HKUZ --approval-msg-id 1789000000.123456
#
# CSV: header required; must contain columns customer_id and refund_id.
# Extra columns are ignored. The file is customer PII — keep it OUT of the repo.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STRIPE_WRITE_BIN="${STRIPE_WRITE_BIN:-$SCRIPT_DIR/muso-stripe-write.sh}"
# DECISION-INPUT BINDING — before the lib is sourced, and unconditional.
#
# Sanitizing the gate invocation alone was not enough. The reads this script bases
# its decision on are just as dangerous as the write: a caller could point
# STRIPE_CREDIT_LIB at a shim whose customer_live_concession_amount returns 49999,
# or STRIPE_BIN at one that forges refund ownership and balance reads and forwards
# only the final POST to the real CLI. Either way a REAL customer is debited up to
# the caps on entirely invented data, while the allowlist and the writer binding
# both still look satisfied.
#
# So every executable and library on the apply path is bound here, not just the
# writer. STRIPE_BIN resolves through `command -v` so PATH still selects the
# binary in tests and in production, and the resolved absolute path is printed in
# the summary and the ledger — a substitution is then attributable rather than
# silent. (PATH control is not a privilege this script grants: anyone with it
# could run `stripe` directly. What it must never do is let the caller swap the
# decision logic while passing the allowlist check.)
STRIPE_CREDIT_LIB="$SCRIPT_DIR/lib/stripe-credit.sh"
STRIPE_BIN="$(command -v stripe 2>/dev/null || true)"
if [ -z "$STRIPE_BIN" ] || [ ! -x "$STRIPE_BIN" ]; then
  echo "FATAL: no executable \`stripe\` on PATH; refusing to run." >&2
  exit 2
fi
readonly STRIPE_CREDIT_LIB STRIPE_BIN
LEDGER_DIR="${REFUND_REMEDIATION_LEDGER_DIR:-/var/lib/hydra-refund-overlap}"
LOCK_DIR="$LEDGER_DIR/locks"
# Long enough to outlast a slow Stripe round-trip, short enough that a wedged
# run does not stall the batch forever — a busy row is SKIPPED and reported, not
# silently waited on.
LOCK_WAIT_SECONDS="${REFUND_REMEDIATION_LOCK_WAIT:-30}"

# Same allowlist string as the money gate. A bats case asserts the two are
# byte-identical, because two copies of an approver list WILL drift apart and
# the drift is invisible until someone unauthorised moves money.
# The money gate's allowlist (Aaron/Jan/Nick) authorizes REFUNDS. This script is a
# different and NEW capability: it debits live customer-balance credit directly.
# Per the documented escalation split, a new money/security surface is Aaron's
# call specifically, not a co-equal one — so --apply is restricted to Aaron until
# he authorizes the wider list in writing on the PR. Narrowing is the reversible
# direction; widening it back to APPLY_ALLOWLIST_FULL needs that recorded approval.
REFUND_OVERRIDE_ALLOWLIST_IMMUTABLE="U7RP6HKUZ aaron aaron@muso.ai"
# The full refund allowlist, kept for parity with the money gate and for the
# widening step once authorization is recorded. Intentionally not referenced at
# runtime: --apply is restricted to Aaron until the new debit surface is
# authorized, and this constant is what the parity test compares against the
# gate (and what the widening step will assign).
# shellcheck disable=SC2034
REFUND_OVERRIDE_ALLOWLIST_FULL="U7RP6HKUZ U038BM16T7W U0AL36NADEY aaron jan nick aaron@muso.ai jan@muso.ai nick@muso.ai"
REFUND_OVERRIDE_ALLOWLIST="${REFUND_OVERRIDE_ALLOWLIST:-$REFUND_OVERRIDE_ALLOWLIST_IMMUTABLE}"

# PRODUCTION BINDING — unconditional, and must stay AFTER every other assignment.
# A caller who controls the environment could otherwise point STRIPE_WRITE_BIN
# straight at the Stripe CLI (skipping the codex-health money gate entirely) and
# set REFUND_OVERRIDE_ALLOWLIST to a value naming itself, then self-authorize
# --apply against real customer balances.
#
# THERE IS NO TEST SEAM HERE, deliberately. A previous revision gated the seam on
# BATS_TEST_TMPDIR and described that as "production-impossible". It is nothing of
# the kind: it is an ordinary environment variable, so anyone able to set
# STRIPE_WRITE_BIN could set it too and restore the entire bypass. An escape hatch
# keyed on the environment cannot defend against an attacker who controls the
# environment — so the money path simply has none, and the tests exercise the real
# gate instead (see scripts/tests/remediate-refund-credit-overlap.bats).
#
# Read-only overrides (STRIPE_BIN, ledger dir) stay adjustable: they inform, they
# do not move money or authorize anything.
STRIPE_WRITE_BIN="$SCRIPT_DIR/muso-stripe-write.sh"
REFUND_OVERRIDE_ALLOWLIST="$REFUND_OVERRIDE_ALLOWLIST_IMMUTABLE"
readonly STRIPE_WRITE_BIN REFUND_OVERRIDE_ALLOWLIST

MAX_PER_CUSTOMER_CENTS="${MAX_PER_CUSTOMER_CENTS:-50000}"
MAX_TOTAL_CENTS="${MAX_TOTAL_CENTS:-250000}"

AUDIT_CSV=""; APPLY=0; CONFIRMED_BY=""; APPROVAL_MSG_ID=""; ONLY_CUSTOMER=""; LIMIT=0
RUN_TAG="${RUN_TAG:-refund-credit-overlap-$(date -u +%Y%m%d)}"

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --audit-csv)       [ "$#" -ge 2 ] || { echo "usage: --audit-csv needs a value" >&2; exit 2; }; AUDIT_CSV="$2"; shift 2 ;;
    --apply)           APPLY=1; shift ;;
    --dry-run)         APPLY=0; shift ;;
    --confirmed-by)    [ "$#" -ge 2 ] || { echo "usage: --confirmed-by needs a value" >&2; exit 2; }; CONFIRMED_BY="$2"; shift 2 ;;
    --approval-msg-id) [ "$#" -ge 2 ] || { echo "usage: --approval-msg-id needs a value" >&2; exit 2; }; APPROVAL_MSG_ID="$2"; shift 2 ;;
    --customer)        [ "$#" -ge 2 ] || { echo "usage: --customer needs a value" >&2; exit 2; }; ONLY_CUSTOMER="$2"; shift 2 ;;
    --limit)           [ "$#" -ge 2 ] || { echo "usage: --limit needs a value" >&2; exit 2; }; LIMIT="$2"; shift 2 ;;
    -h|--help)         usage 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$AUDIT_CSV" ] || { echo "FATAL: --audit-csv is required" >&2; exit 2; }
[ -r "$AUDIT_CSV" ] || { echo "FATAL: cannot read $AUDIT_CSV" >&2; exit 2; }
[ -r "$STRIPE_CREDIT_LIB" ] || { echo "FATAL: cannot read $STRIPE_CREDIT_LIB" >&2; exit 2; }
# shellcheck disable=SC1090
source "$STRIPE_CREDIT_LIB"

# Invoke the money gate with its OWN override hooks stripped.
#
# Binding STRIPE_WRITE_BIN to the canonical path is necessary but not sufficient:
# muso-stripe-write.sh honours CODEX_HEALTH_LIB, STRIPE_CREDIT_LIB, STRIPE_BIN,
# OPENCLAW_GATEWAY_UNIT and CODEX_HEALTH_WINDOW_MIN from the environment. A caller
# could therefore point CODEX_HEALTH_LIB at a stub whose codex_health_gate always
# returns 0 and move money on a degraded fleet through a writer that still LOOKS
# canonical. Binding the path while inheriting the behaviour is not a binding.
#
# STRIPE_BIN is stripped too; the gate then resolves `stripe` from PATH, which is
# what production wants and what the tests already provide.
gated_write() {
  env -u CODEX_HEALTH_LIB -u STRIPE_CREDIT_LIB -u STRIPE_BIN \
      -u OPENCLAW_GATEWAY_UNIT -u CODEX_HEALTH_WINDOW_MIN \
      "$STRIPE_WRITE_BIN" "$@"
}

# Exact-match the audited transaction against the live concession rows.
# A substring test on the summary string would let a truncated or prefix CSV id
# satisfy the check against a DIFFERENT live transaction, so the ids are compared
# as whole tokens.
audited_credit_is_live() {
  local cus="$1" want="$2" rows id
  rows="$(customer_live_concession_rows "$cus")" || return 2
  while read -r id _rest; do
    if [ "$id" = "$want" ]; then return 0; fi
  done <<< "$rows"
  return 1
}

is_allowlisted_approver() {
  local who="$1" a; local -a allow=()
  read -ra allow <<< "$REFUND_OVERRIDE_ALLOWLIST"
  for a in "${allow[@]}"; do [ "$who" = "$a" ] && return 0; done
  return 1
}

if [ "$APPLY" -eq 1 ]; then
  if [ -z "$CONFIRMED_BY" ] || [ -z "$APPROVAL_MSG_ID" ]; then
    echo "FATAL: --apply needs --confirmed-by <slack_id> --approval-msg-id <ts>. This moves real money on real customer accounts." >&2
    exit 2
  fi
  if ! is_allowlisted_approver "$CONFIRMED_BY"; then
    echo "FATAL: --confirmed-by '$CONFIRMED_BY' is not authorized for --apply. This script debits live customer-balance credit, a NEW money surface, so it is restricted to Aaron (U7RP6HKUZ) until he authorizes the wider Aaron/Jan/Nick list in writing on the PR." >&2
    exit 2
  fi
fi

mkdir -p "$LEDGER_DIR" "$LOCK_DIR"
LEDGER="$LEDGER_DIR/$RUN_TAG.tsv"

# --- CSV parsing ---------------------------------------------------------
# Resolve columns BY NAME from the header. A positional read would silently
# transpose customer ids and amounts the first time finance re-orders a column.
header="$(head -1 "$AUDIT_CSV")"
col_index() {
  printf '%s' "$header" | tr -d '\r' | awk -F, -v want="$1" '{for(i=1;i<=NF;i++){gsub(/^[ \t"]+|[ \t"]+$/,"",$i); if($i==want){print i; exit}}}'
}
CUS_COL="$(col_index customer_id)"
REF_COL="$(col_index refund_id)"
# The audited BALANCE TRANSACTION is required, not optional. A (customer, refund)
# pair does not identify the credit that made that refund a duplicate: if the
# audited credit has since been spent and the customer has since earned a NEW,
# unrelated concession, remediating on the pair alone debits the new one —
# clawing back a legitimate concession for a different period.
CBT_COL="$(col_index credit_txn)"
if [ -z "$CUS_COL" ] || [ -z "$REF_COL" ] || [ -z "$CBT_COL" ]; then
  echo "FATAL: $AUDIT_CSV must have 'customer_id', 'refund_id' and 'credit_txn' header columns (found: $header)" >&2
  exit 2
fi

# ORDER THE WORK OLDEST-CREDIT-FIRST, PER CUSTOMER.
#
# Our own debits are attributed FIFO by credit_live_window_eval: a positive row
# consumes the OLDEST live concession first. So debiting a customer's NEWER
# audited credit before its older one makes the model charge that debit against
# the older credit, which then reads as spent and is skipped — leaving real
# duplicate concession behind while the run reports success. CSV order is
# arbitrary (it comes from a finance export), so it cannot be trusted to match.
#
# One extra read per customer buys the correct order: credit_live_window_credits
# already returns rows oldest-first, so the index of each audited cbtxn in that
# list IS the order to process them in. Rows whose credit is not live sort last;
# they will be skipped as audited-credit-not-live anyway.
ordered_rows() {
  local line cus cbt idx
  declare -A cust_order=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    cus="$(printf '%s' "$line" | tr -d '\r' | awk -F, -v c="$CUS_COL" '{gsub(/^[ \t"]+|[ \t"]+$/,"",$c); print $c}')"
    cbt="$(printf '%s' "$line" | tr -d '\r' | awk -F, -v c="$CBT_COL" '{gsub(/^[ \t"]+|[ \t"]+$/,"",$c); print $c}')"
    if [ -z "$cus" ] || [ -z "$cbt" ]; then
      printf '%s\t%s\n' "999999" "$line"; continue
    fi
    if [ -z "${cust_order[$cus]:-}" ]; then
      # `|| true`: an unverifiable read here must NOT abort the ordering pass
      # under `set -e`. It only costs us the ordering hint — the row still gets
      # processed and the real per-row guards report credit-unverifiable. Without
      # this the whole work list silently came out EMPTY and nothing ran at all.
      cust_order[$cus]="$(customer_live_concession_rows "$cus" 2>/dev/null | awk '{print NR" "$1}' | tr '\n' ';' || true)"
      [ -n "${cust_order[$cus]}" ] || cust_order[$cus]="-"
    fi
    idx="$(printf '%s' "${cust_order[$cus]}" | tr ';' '\n' | awk -v w="$cbt" '$2==w{print $1; found=1} END{if(!found) print 999998}' | head -1)"
    printf '%s\t%s\n' "$idx" "$line"
  done < <(tail -n +2 "$AUDIT_CSV") | sort -s -k1,1n | cut -f2-
}

# Append, never truncate. `>` erased the earlier entries whenever a run was
# resumed the same UTC day under the default (date-stamped) RUN_TAG — destroying
# the local record of money that had already moved.
if [ ! -s "$LEDGER" ]; then
  printf 'run_tag\tcustomer\trefund\tplanned_cents\taction\treason\n' >"$LEDGER"
fi

planned_total=0; applied_total=0
# Dedupe the AUDITED CREDIT, not the customer. One customer can legitimately have
# several duplicate concessions from different periods, each its own audit row.
# Claiming the customer on the first row meant a row whose credit was already
# spent discarded a later row whose credit was still live — the live duplicate
# was then never remediated. The per-customer flock still serializes the writes.
declare -A seen_credit=()
declare -A type_hist=()
n_rows=0; n_skip=0; n_plan=0; n_applied=0; n_failed=0

emit() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$RUN_TAG" "$1" "$2" "$3" "$4" "$5" | tee -a "$LEDGER"; }

while IFS= read -r line; do
  n_rows=$((n_rows + 1))
  [ -n "$line" ] || continue
  cus="$(printf '%s' "$line" | tr -d '\r' | awk -F, -v c="$CUS_COL" '{gsub(/^[ \t"]+|[ \t"]+$/,"",$c); print $c}')"
  ref="$(printf '%s' "$line" | tr -d '\r' | awk -F, -v c="$REF_COL" '{gsub(/^[ \t"]+|[ \t"]+$/,"",$c); print $c}')"
  cbt="$(printf '%s' "$line" | tr -d '\r' | awk -F, -v c="$CBT_COL" '{gsub(/^[ \t"]+|[ \t"]+$/,"",$c); print $c}')"

  # A malformed row is REPORTED and skipped, never silently dropped: a row this
  # script cannot read is a customer nobody remediates, and silence would hide that.
  if [ -z "$cus" ] || [ -z "$ref" ] || [ -z "$cbt" ]; then
    emit "${cus:-?}" "${ref:-?}" 0 SKIP "malformed-row"; n_skip=$((n_skip + 1)); continue
  fi
  [ -n "$ONLY_CUSTOMER" ] && [ "$cus" != "$ONLY_CUSTOMER" ] && continue
  if [ -n "${seen_credit[$cbt]:-}" ]; then
    emit "$cus" "$ref" 0 SKIP "duplicate-row-for-credit($cbt)"; n_skip=$((n_skip + 1)); continue
  fi
  seen_credit[$cbt]=1
  if [ "$LIMIT" -gt 0 ] && [ "$n_plan" -ge "$LIMIT" ]; then
    emit "$cus" "$ref" 0 SKIP "limit-reached"; n_skip=$((n_skip + 1)); continue
  fi

  # 1. The refund must actually exist, have succeeded, and belong to this customer.
  #    The workbook alone never authorises a write.
  rjson="$("$STRIPE_BIN" refunds retrieve "$ref" 2>/dev/null || true)"
  if ! printf '%s' "$rjson" | jq -e 'type == "object" and .status == "succeeded"' >/dev/null 2>&1; then
    emit "$cus" "$ref" 0 SKIP "refund-not-succeeded-or-unreadable"; n_skip=$((n_skip + 1)); continue
  fi
  # ...and that it is THIS customer's refund. A succeeded refund proves a refund
  # happened, not that it happened to the customer on this CSV row. Without this,
  # one transposed/stale row debits a customer who was never refunded at all —
  # the CSV is a candidate list, and this is the check that stops it being
  # treated as an authority. Resolve customer via the refund's charge; a
  # mismatch or an unreadable charge is a SKIP, never a write.
  rcharge="$(printf '%s' "$rjson" | jq -r '.charge // empty')"
  if [ -z "$rcharge" ]; then
    emit "$cus" "$ref" 0 SKIP "refund-has-no-charge"; n_skip=$((n_skip + 1)); continue
  fi
  rcjson="$("$STRIPE_BIN" charges retrieve "$rcharge" 2>/dev/null || true)"
  if ! printf '%s' "$rcjson" | jq -e 'type == "object" and has("customer")' >/dev/null 2>&1; then
    emit "$cus" "$ref" 0 SKIP "refund-charge-unreadable"; n_skip=$((n_skip + 1)); continue
  fi
  rcust="$(printf '%s' "$rcjson" | jq -r '.customer // empty')"
  if [ "$rcust" != "$cus" ]; then
    emit "$cus" "$ref" 0 SKIP "refund-customer-mismatch(refund belongs to ${rcust:-unknown})"; n_skip=$((n_skip + 1)); continue
  fi

  # 2. Live credit, via the SAME predicate the money gate and watchdog use, so
  #    all three agree on what "a concession credit" means by construction.
  if ! credit="$(customer_live_proration_credit "$cus")"; then
    emit "$cus" "$ref" 0 SKIP "credit-unverifiable"; n_skip=$((n_skip + 1)); continue
  fi
  if [ -z "$credit" ]; then
    emit "$cus" "$ref" 0 SKIP "no-live-credit"; n_skip=$((n_skip + 1)); continue
  fi
  for t in $(printf '%s' "$credit" | grep -oE '\((\w+)\)' | tr -d '()'); do
    type_hist[$t]=$(( ${type_hist[$t]:-0} + 1 ))
  done

  # The amount is the CONCESSION portion, never the raw balance. A balance can
  # mix a concession credit with a referral/offer credit we minted on purpose;
  # debiting the whole balance would claw back money the customer was genuinely
  # owed. customer_live_concession_amount clamps to min(concession, live credit).
  # Name the real cause at planning time. Without this an audited credit that is
  # no longer live just yields amount 0 and is reported as "non-positive-amount",
  # which tells an operator nothing about WHY. The authoritative re-check still
  # happens under the lock immediately before the write.
  rc_plan=0
  audited_credit_is_live "$cus" "$cbt" || rc_plan=$?
  if [ "$rc_plan" -eq 2 ]; then
    emit "$cus" "$ref" 0 SKIP "credit-unverifiable"; n_skip=$((n_skip + 1)); continue
  fi
  if [ "$rc_plan" -ne 0 ]; then
    emit "$cus" "$ref" 0 SKIP "audited-credit-not-live($cbt)"; n_skip=$((n_skip + 1)); continue
  fi
  if ! amount="$(customer_audited_concession_amount "$cus" "$cbt")"; then
    emit "$cus" "$ref" 0 SKIP "concession-amount-unverifiable"; n_skip=$((n_skip + 1)); continue
  fi
  if ! [[ "$amount" =~ ^[0-9]+$ ]] || [ "$amount" -le 0 ]; then
    emit "$cus" "$ref" 0 SKIP "non-positive-amount"; n_skip=$((n_skip + 1)); continue
  fi
  if [ "$amount" -gt "$MAX_PER_CUSTOMER_CENTS" ]; then
    emit "$cus" "$ref" "$amount" SKIP "over-per-customer-cap"; n_skip=$((n_skip + 1)); continue
  fi

  # 3. SERIALIZE the whole read-decide-write-verify sequence for this customer.
  #    Two authorized runs overlapping (an operator re-running while the first is
  #    still going, a resumed batch) would otherwise both observe the same live
  #    credit and both debit it — and the post-write compensation would race too,
  #    so the customer could even end up credited back twice. flock is per-host,
  #    which covers the realistic case (one operator on node-8); the idempotency
  #    key on the POST below is what bounds the cross-host case.
  exec {lockfd}>"$LOCK_DIR/$cus.lock" || { emit "$cus" "$ref" 0 SKIP "cannot-open-lock"; n_skip=$((n_skip + 1)); continue; }
  if ! flock -w "$LOCK_WAIT_SECONDS" "$lockfd"; then
    emit "$cus" "$ref" 0 SKIP "lock-busy(another run holds $cus)"; n_skip=$((n_skip + 1))
    exec {lockfd}>&-; continue
  fi

  # 3a. Already remediated by a previous run? Our own marker is the durable proof.
  btjson="$("$STRIPE_BIN" get "/v1/customers/$cus/balance_transactions" -d "limit=100" 2>/dev/null || true)"
  # Key the durable marker to the AUDITED CREDIT, not just the run. Matching on
  # RUN_TAG alone meant the first successful write for a customer made every
  # later row for that customer skip as already-remediated — so a second live
  # duplicate concession was left in place while the run exited successfully.
  # This mirrors the in-memory dedupe, which is keyed on credit_txn for the same
  # reason: one customer can hold several duplicate concessions.
  if printf '%s' "$btjson" | jq -e --arg tag "$RUN_TAG" --arg cbt "$cbt" \
       '[.data[]? | select(.metadata.hydra_remediation == $tag and .metadata.source_credit == $cbt)] | length > 0' >/dev/null 2>&1; then
    emit "$cus" "$ref" "$amount" SKIP "already-remediated"; n_skip=$((n_skip + 1)); exec {lockfd}>&-; continue
  fi

  planned_total=$((planned_total + amount)); n_plan=$((n_plan + 1))

  if [ "$APPLY" -eq 0 ]; then
    emit "$cus" "$ref" "$amount" PLAN "dry-run"; exec {lockfd}>&-; continue
  fi
  if [ "$planned_total" -gt "$MAX_TOTAL_CENTS" ]; then
    emit "$cus" "$ref" "$amount" ABORT "total-cap-exceeded"
    echo "FATAL: planned total ${planned_total}c exceeds --max-total ${MAX_TOTAL_CENTS}c; stopping before this write." >&2
    exit 4
  fi

  # LAST-MOMENT RE-READ. `amount` was computed several Stripe round-trips ago.
  # If an invoice consumed the credit in between, debiting the planned figure
  # lands on a zero balance and leaves the customer OWING money we invented.
  # Stripe has no conditional balance write, so the race cannot be eliminated —
  # but it can be narrowed to the gap between this read and the POST, and any
  # residue is caught by the raw-balance invariant after the write.
  # IDENTITY, RE-CHECKED UNDER THE LOCK. The pre-lock read proves nothing by the
  # time we write: the audited credit can be consumed and replaced by an
  # unrelated one in between, and an amount-only re-read cannot tell the
  # difference — `fresh` is still positive, so the replacement gets debited.
  rc_live=0
  audited_credit_is_live "$cus" "$cbt" || rc_live=$?
  if [ "$rc_live" -eq 2 ]; then
    emit "$cus" "$ref" "$amount" SKIP "concession-unverifiable-at-write"; n_skip=$((n_skip + 1)); exec {lockfd}>&-; continue
  fi
  if [ "$rc_live" -ne 0 ]; then
    emit "$cus" "$ref" "$amount" SKIP "audited-credit-not-live($cbt)"; n_skip=$((n_skip + 1)); exec {lockfd}>&-; continue
  fi
  if ! fresh="$(customer_audited_concession_amount "$cus" "$cbt")"; then
    emit "$cus" "$ref" "$amount" SKIP "concession-unverifiable-at-write"; n_skip=$((n_skip + 1)); exec {lockfd}>&-; continue
  fi
  if ! [[ "$fresh" =~ ^[0-9]+$ ]] || [ "$fresh" -le 0 ]; then
    emit "$cus" "$ref" "$amount" SKIP "credit-vanished-before-write"; n_skip=$((n_skip + 1)); exec {lockfd}>&-; continue
  fi
  # Re-clamp downward only: never debit more than is live right now.
  [ "$fresh" -lt "$amount" ] && amount="$fresh"

  # Deterministic key: same customer + same source refund + same run tag always
  # produces the same key, so a duplicate POST from a second host or a resumed
  # run is rejected by Stripe rather than double-debiting. (`stripe post -i` /
  # --idempotency verified available on node-8, 2026-09-11.)
  # The audited credit is part of the identity. This run deliberately allows
  # several audited credits for ONE customer/refund pair, so a key without $cbt
  # is reused across them with different amounts and metadata — Stripe rejects
  # that as an idempotency mismatch and the later credits are never remediated.
  idem="hydra-remediation-${RUN_TAG}-${cus}-${ref}-${cbt}"
  if gated_write post "/v1/customers/$cus/balance_transactions" \
      --idempotency "$idem" \
      -d "amount=$amount" -d "currency=usd" \
      -d "description=hydra remediation: zero concession credit duplicated by cash refund $ref" \
      -d "metadata[hydra_remediation]=$RUN_TAG" \
      -d "metadata[source_credit]=$cbt" \
      -d "metadata[source_refund]=$ref" \
      -d "metadata[confirmed_by]=$CONFIRMED_BY" \
      -d "metadata[approval_msg_id]=$APPROVAL_MSG_ID" >/dev/null 2>&1; then
    # 4a. RAW-BALANCE INVARIANT, checked FIRST and deliberately not via
    #     customer_live_concession_amount: that helper reports 0 for any balance
    #     >= 0, so an over-debit that left the customer OWING money is
    #     indistinguishable from a clean zero under it. The check meant to catch
    #     this failure would otherwise report it as success.
    raw="$(customer_raw_balance "$cus" 2>/dev/null || echo unreadable)"
    if [ "$raw" = "unreadable" ]; then
      emit "$cus" "$ref" "$amount" VERIFY-FAILED "post-write balance unreadable — check by hand"
      n_failed=$((n_failed + 1))
    elif [ "$raw" -gt 0 ]; then
      # We pushed the customer into debit. Put it back immediately: leaving a
      # real person owing money this script invented is the worst outcome here,
      # and it is fully reversible by writing the excess back as credit.
      if gated_write post "/v1/customers/$cus/balance_transactions" \
          --idempotency "${idem}-compensate" \
          -d "amount=-$raw" -d "currency=usd" \
          -d "description=hydra remediation: compensating over-debit on $ref" \
          -d "metadata[hydra_remediation]=$RUN_TAG" \
          -d "metadata[over_debit_compensation]=$ref" >/dev/null 2>&1 \
         && [ "$(customer_raw_balance "$cus" 2>/dev/null || echo x)" = "0" ]; then
        emit "$cus" "$ref" "$amount" OVER-DEBIT-COMPENSATED "credit was consumed mid-write; ${raw}c written back"
      else
        emit "$cus" "$ref" "$amount" OVER-DEBIT-COMPENSATION-FAILED "customer LEFT OWING ${raw}c — fix by hand NOW"
      fi
      n_failed=$((n_failed + 1))
    else
      # 4b. Only now assert the CONCESSION is gone. A customer may legitimately
      #     still hold referral/offer credit we must not touch, so a non-zero
      #     NEGATIVE balance afterwards is expected and correct.
      # Scope the VERIFICATION to the audited row, exactly as the write is. Asking
      # whether ALL live concession is zero reports a correct, scoped remediation
      # as VERIFY-FAILED whenever the customer holds any unrelated concession —
      # claiming $0 applied for money that genuinely moved, which is a false
      # entry in the audit trail. The raw-balance over-debit check above is
      # unchanged and still covers the dangerous direction.
      after="$(customer_audited_concession_amount "$cus" "$cbt" 2>/dev/null || echo unreadable)"
      if [ "$after" = "0" ]; then
        emit "$cus" "$ref" "$amount" APPLIED "concession-now-zero"
        applied_total=$((applied_total + amount)); n_applied=$((n_applied + 1))
      else
        emit "$cus" "$ref" "$amount" VERIFY-FAILED "post-write audited concession=$after"
        n_failed=$((n_failed + 1))
      fi
    fi
  else
    emit "$cus" "$ref" "$amount" FAILED "stripe-write-refused-or-errored"
    n_failed=$((n_failed + 1))
  fi
  exec {lockfd}>&-
done < <(ordered_rows)

echo
echo "── summary (${RUN_TAG}) ─────────────────────────────"
printf 'mode:            %s (writer: %s)\n' "$([ "$APPLY" -eq 1 ] && echo APPLY || echo DRY-RUN)" "$STRIPE_WRITE_BIN"
printf 'stripe:          %s\n' "$STRIPE_BIN"
printf 'rows read:       %s\n' "$n_rows"
printf 'planned:         %s customer(s), %s\n' "$n_plan" "$(awk -v c="$planned_total" 'BEGIN{printf "$%.2f", c/100}')"
[ "$APPLY" -eq 1 ] && printf 'applied:         %s customer(s), %s\n' "$n_applied" "$(awk -v c="$applied_total" 'BEGIN{printf "$%.2f", c/100}')"
printf 'skipped:         %s\n' "$n_skip"
printf 'failed:          %s\n' "$n_failed"
# The type histogram is how we learn, BEFORE touching money, whether real-world
# credits fall outside the predicate's expected classes.
printf 'credit types:    '
if [ "${#type_hist[@]}" -eq 0 ]; then echo "(none)"; else
  for t in "${!type_hist[@]}"; do printf '%s=%s ' "$t" "${type_hist[$t]}"; done; echo
fi
printf 'ledger:          %s\n' "$LEDGER"
[ "$n_failed" -gt 0 ] && exit 5
exit 0
