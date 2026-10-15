#!/usr/bin/env bats
# Tests for scripts/refund-credit-overlap-watchdog.sh — the after-the-fact sweep that
# catches a cash refund landing on top of a live customer-balance credit.
#
# This is the layer that covers the path the money gate cannot see: every one of the
# 223 customers in the 2026-09-09 audit came from the human Stripe dashboard, and the
# 2025-12-05 exemplar had its credit minted 0.96h AFTER the refund. So the assertions
# that matter most here are (a) it finds the overlap, (b) it NEVER moves money, and
# (c) an unverifiable read is retried rather than watermarked as clean.
bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/refund-credit-overlap-watchdog.sh"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"

  cat >"$BIN/stripe" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "refunds list")
    if [ "${STUB_REFUNDS_BROKEN:-0}" -gt 0 ]; then echo ""; exit 1
    elif [ "${STUB_REFUNDS_NOT_LIST:-0}" -gt 0 ]; then echo '{"error":{"message":"bad"}}'
    elif [ "${STUB_REFUNDS_EMPTY:-0}" -gt 0 ]; then echo '{"object":"list","data":[]}'
    elif [ "${STUB_ENDLESS_PAGES:-0}" -gt 0 ]; then
      # Always a full page AND has_more=true: the window genuinely exceeds the
      # ceiling, so the sweep can never see all of it.
      printf '{"object":"list","has_more":true,"data":['
      for i in $(seq 1 100); do [ "$i" -gt 1 ] && printf ','
        printf '{"id":"re_e_%d","charge":"ch_CLEAN","amount":100,"created":1,"status":"succeeded"}' "$i"; done
      printf ']}\n'
    elif [ "${STUB_REFUNDS_TWO_PAGES:-0}" -gt 0 ]; then
      # Page 1 is FULL (100) so the caller must ask for page 2; the real finding
      # sits on page 2 and is invisible to a single --limit 100 read.
      if printf '%s' "$*" | grep -q "starting_after"; then
        echo '{"object":"list","data":[{"id":"re_PAGE2","charge":"ch_TEST","amount":10750,"created":1,"status":"succeeded"}]}'
      else
        printf '{"object":"list","data":['
        for i in $(seq 1 100); do [ "$i" -gt 1 ] && printf ','; printf '{"id":"re_p1_%d","charge":"ch_CLEAN","amount":100,"created":1,"status":"succeeded"}' "$i"; done
        printf ']}\n'
      fi
    elif [ "${STUB_REFUNDS_TWO_MATCHING:-0}" -gt 0 ]; then
      echo '{"object":"list","data":[{"id":"re_TEST_2","charge":"ch_TEST","amount":26039,"created":1789396257,"status":"succeeded"},{"id":"re_TEST","charge":"ch_TEST","amount":26039,"created":1789395957,"status":"succeeded"}]}'
    else
      # Honour created[gte] the way Stripe does: a refund older than the
      # requested window is simply not returned. Without this the stub hands
      # back the refund no matter how short the lookback is, and a window that
      # is too narrow to ever re-check looks identical to one that works.
      gte=0
      for a in "$@"; do case "$a" in created\[gte\]=*) gte="${a#created\[gte\]=}" ;; esac; done
      rc_created="${STUB_REFUND_CREATED:-9999999999}"
      rc_amount="${STUB_REFUND_AMOUNT:-10750}"
      if [ "$rc_created" -ge "$gte" ]; then
        if [ "${STUB_REFUND_NO_CHARGE:-0}" -gt 0 ]; then
          echo "{\"object\":\"list\",\"data\":[{\"id\":\"re_TEST\",\"charge\":\"\",\"amount\":$rc_amount,\"created\":$rc_created,\"status\":\"succeeded\"}]}"
        elif [ "${STUB_UNVERIFIABLE_EXTRA:-0}" -gt 0 ]; then
          echo "{\"object\":\"list\",\"data\":[{\"id\":\"re_TEST\",\"charge\":\"ch_TEST\",\"amount\":$rc_amount,\"created\":$rc_created,\"status\":\"succeeded\"},{\"id\":\"re_BAD\",\"charge\":\"ch_MISSING\",\"amount\":500,\"created\":$rc_created,\"status\":\"succeeded\"}]}"
        else
          if [ "${STUB_REFUND_NO_CREATED:-0}" -gt 0 ]; then
            echo "{\"object\":\"list\",\"data\":[{\"id\":\"re_TEST\",\"charge\":\"ch_TEST\",\"amount\":$rc_amount,\"status\":\"succeeded\"}]}"
            exit 0
          fi
          st="${STUB_REFUND_STATUS:-succeeded}"
          if [ "$st" = "absent" ]; then
            echo "{\"object\":\"list\",\"data\":[{\"id\":\"re_TEST\",\"charge\":\"ch_TEST\",\"amount\":$rc_amount,\"created\":$rc_created}]}"
          else
            echo "{\"object\":\"list\",\"data\":[{\"id\":\"re_TEST\",\"charge\":\"ch_TEST\",\"amount\":$rc_amount,\"created\":$rc_created,\"status\":\"$st\"}]}"
          fi
        fi
      else
        echo '{"object":"list","data":[]}'
      fi
    fi
    ;;
  "charges retrieve")
    if [ "${STUB_CHARGE_BROKEN:-0}" -gt 0 ]; then echo ""
    elif [ "$3" = "ch_MISSING" ]; then echo ""
    elif [ "$3" = "ch_CLEAN" ]; then echo '{"id":"ch_CLEAN","customer":"cus_CLEAN"}'
    else echo '{"id":"ch_TEST","customer":"cus_TEST"}'; fi
    ;;

  "customers retrieve")
    if [ "${STUB_CUSTOMER_BROKEN:-0}" -gt 0 ]; then echo ""
    elif [ "$3" = "cus_CLEAN" ]; then echo '{"id":"cus_CLEAN","balance":0}'
    elif [ "${STUB_CREDIT_ON_PASS2:-0}" -gt 0 ]; then
      # Stripe mints the compensating credit AFTER the refund — the PR's own
      # exemplar had it appear 0.96h later. Pass 1 is clean; pass 2 is not.
      if [ -f "$STUB_STATE_DIR/pass1" ]; then echo '{"id":"cus_TEST","balance":-11772}'
      else : > "$STUB_STATE_DIR/pass1"; echo '{"id":"cus_TEST","balance":0}'; fi
    else echo "{\"id\":\"cus_TEST\",\"balance\":${STUB_CREDIT_BALANCE:-0}}"; fi
    ;;
  "get /v1/customers/cus_TEST/balance_transactions")
    if [ "${STUB_CBT_BROKEN:-0}" -gt 0 ]; then echo ""
    elif [ "${STUB_CBT_TAGGED:-0}" -gt 0 ]; then
      echo '{"object":"list","data":[{"id":"cbtxn_REF","type":"adjustment","amount":-11772,"ending_balance":-11772,"created":1,"metadata":{"referralId":"r1"}}]}'
    elif [ "${STUB_CBT_REFUND_REVERSED:-0}" -gt 0 ]; then
      echo '{"object":"list","data":[{"id":"cbtxn_1UFaoLLsjTo3Ar3lSBLsdKR4","type":"adjustment","amount":26038,"ending_balance":-1261,"created":1789395885,"description":"Reverse accidental annual-to-monthly proration credit before cash refund; preserve $12.61 legitimate credit","metadata":{}},{"id":"cbtxn_1UE8BBLsjTo3Ar3lBeWKXP4O","type":"invoice_too_small","amount":-27299,"ending_balance":-27299,"created":1789047497,"description":null,"metadata":{}},{"id":"cbtxn_1UE7wgLsjTo3Ar3lM8C7B5Xu","type":"applied_to_invoice","amount":1746,"ending_balance":0,"created":1789046596,"description":null,"metadata":{}},{"id":"cbtxn_1UC6ceLsjTo3Ar3lgrrZNYOL","type":"invoice_too_small","amount":-1746,"ending_balance":-1746,"created":1788564856,"description":null,"metadata":{}}]}'
    elif [ "${STUB_CBT_UNLINKED_ADJUSTMENT:-0}" -gt 0 ]; then
      echo '{"object":"list","data":[{"id":"cbtxn_ADJ","type":"adjustment","amount":26038,"ending_balance":-1261,"created":1789395885,"description":"Account correction","metadata":{}},{"id":"cbtxn_CREDIT","type":"invoice_too_small","amount":-27299,"ending_balance":-27299,"created":1789047497,"description":null,"metadata":{}}]}'
    elif [ "${STUB_CBT_LATE_CREDIT:-0}" -gt 0 ]; then
      echo '{"object":"list","data":[{"id":"cbtxn_LATE","type":"invoice_too_small","amount":-100,"ending_balance":-100,"created":1789396057,"description":null,"metadata":{}},{"id":"cbtxn_ADJ","type":"adjustment","amount":100,"ending_balance":0,"created":1789395885,"description":"Reverse account credit before cash refund","metadata":{}},{"id":"cbtxn_OLD","type":"invoice_too_small","amount":-100,"ending_balance":-100,"created":1789395000,"description":null,"metadata":{}}]}'
    elif [ "${STUB_CBT_SAME_SECOND_CREDIT:-0}" -gt 0 ]; then
      echo '{"object":"list","data":[{"id":"cbtxn_SAME_SECOND","type":"invoice_too_small","amount":-100,"ending_balance":-200,"created":1789395885,"description":null,"metadata":{}},{"id":"cbtxn_ADJ","type":"adjustment","amount":100,"ending_balance":-100,"created":1789395885,"description":"Reverse account credit before cash refund","metadata":{}},{"id":"cbtxn_OLD","type":"invoice_too_small","amount":-200,"ending_balance":-200,"created":1789395000,"description":null,"metadata":{}}]}'
    else
      echo '{"object":"list","data":[{"id":"cbtxn_LIVE","type":"invoice_too_small","amount":-11772,"ending_balance":-11772,"created":1,"metadata":{}}]}'
    fi
    ;;
  *) echo "STRIPE_CALLED $*" ;;
esac
SH
  chmod +x "$BIN/stripe"

  # Fake slack-notify lib: records calls instead of posting.
  cat >"$BATS_TEST_TMPDIR/slack.sh" <<SH
# Mirrors the real contract: slack_notify SWALLOWS failure (always 0), while
# slack_notify_payload_file_status returns the decoded delivery result. A fake
# where the critical path could fail was how the delivery-failure regression
# went false-green against production code that cannot fail.
# The stub also records the ROUTE (channel + bot), not just the text: these
# alerts name a customer and a dollar amount, so WHERE they land is part of the
# behaviour under test, and a text-only fake cannot fail when the route is wrong.
slack_notify() { echo "SLACK_NOTIFY[bot=\${SLACK_NOTIFY_BOT:-} chan=\${SLACK_CHANNEL:-}]: \$1" >> "$BATS_TEST_TMPDIR/slack.log"; return 0; }
slack_notify_critical() { echo "SLACK_CRITICAL[bot=\${SLACK_NOTIFY_BOT:-} chan=\${SLACK_CHANNEL:-}]: <@\${SLACK_UID_NICK:-}> <@\${SLACK_UID_AARON:-}> \$1" >> "$BATS_TEST_TMPDIR/slack.log"; return 0; }
slack_notify_payload_file_status() {
  if [ "\${STUB_SLACK_FAILS:-0}" -gt 0 ]; then return 1; fi
  echo "SLACK_CRITICAL[bot=\${SLACK_NOTIFY_BOT:-} chan=\$(jq -r .channel "\$1" 2>/dev/null)]: \$(jq -r .text "\$1" 2>/dev/null)" >> "$BATS_TEST_TMPDIR/slack.log"
  return 0
}
# The real lib defines these; the script relies on them for the <@UID> mentions.
SLACK_UID_NICK="U0AL36NADEY"
SLACK_UID_AARON="U7RP6HKUZ"
SH

  export STRIPE_BIN="$BIN/stripe"
  export SLACK_NOTIFY_LIB="$BATS_TEST_TMPDIR/slack.sh"
  export REFUND_OVERLAP_STATE_DIR="$BATS_TEST_TMPDIR/state"
  STUB_STATE_DIR="$BATS_TEST_TMPDIR/stubstate"; mkdir -p "$STUB_STATE_DIR"; export STUB_STATE_DIR
  : >"$BATS_TEST_TMPDIR/slack.log"
}

slack_log() { cat "$BATS_TEST_TMPDIR/slack.log" 2>/dev/null || true; }
historical_refund_fixture() { export REFUND_OVERLAP_LOOKBACK_HOURS=1000000; }

@test "refund with a live concession credit -> pages, and moves no money" {
  export STUB_CREDIT_BALANCE=-11772
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(slack_log)" == *"SLACK_CRITICAL"* ]]
  [[ "$(slack_log)" == *"Duplicate concession detected"* ]]
  [[ "$(slack_log)" == *"re_TEST"* ]]
  # DETECT-ONLY: it must never write a balance transaction.
  [[ "$output" != *"STRIPE_CALLED post"* ]]
}

@test "refund preceded by an explicit matching balance reversal does not page on the legitimate residual" {
  # Regression: re_3UE7weLsjTo3Ar3l2TKuWJq9. The immutable source credit is
  # -27299c; a documented +26038c adjustment immediately before the 26039c
  # cash refund removes the overlapping portion and intentionally leaves
  # -1261c. Treating that ending balance as the source transaction amount made
  # the watchdog recommend clawing back legitimate credit.
  export STUB_CREDIT_BALANCE=-1261
  historical_refund_fixture
  export STUB_CBT_REFUND_REVERSED=1
  export STUB_REFUND_AMOUNT=26039
  export STUB_REFUND_CREATED=1789395957
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(slack_log)" ]
  [[ "$output" != *"FINDING"* ]]
}

@test "a same-sized adjustment without an explicit refund-reversal link still pages" {
  # Amount and proximity alone are not enough evidence to suppress a financial
  # alert. Ambiguous adjustments must fail closed for human review.
  export STUB_CREDIT_BALANCE=-1261
  historical_refund_fixture
  export STUB_CBT_UNLINKED_ADJUSTMENT=1
  export STUB_REFUND_AMOUNT=26039
  export STUB_REFUND_CREATED=1789395957
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(slack_log)" == *"Duplicate concession detected"* ]]
  [[ "$(slack_log)" == *"1261c overlap"* ]]
}

@test "an explicitly described reversal outside the one-cent tolerance still pages" {
  historical_refund_fixture
  export STUB_CREDIT_BALANCE=-1261
  export STUB_CBT_REFUND_REVERSED=1
  export STUB_REFUND_AMOUNT=26000
  export STUB_REFUND_CREATED=1789395957
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(slack_log)" == *"Duplicate concession detected"* ]]
  [[ "$(slack_log)" == *"1261c overlap"* ]]
}

@test "a matching reversal never suppresses concession credit minted after it" {
  historical_refund_fixture
  export STUB_CREDIT_BALANCE=-100
  export STUB_CBT_LATE_CREDIT=1
  export STUB_REFUND_AMOUNT=100
  export STUB_REFUND_CREATED=1789395957
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(slack_log)" == *"Duplicate concession detected"* ]]
  [[ "$(slack_log)" == *"100c overlap"* ]]
  [[ "$(slack_log)" == *"cbtxn_LATE"* ]]
}

@test "a same-second live credit is ambiguous and cannot be suppressed" {
  historical_refund_fixture
  export STUB_CREDIT_BALANCE=-200
  export STUB_CBT_SAME_SECOND_CREDIT=1
  export STUB_REFUND_AMOUNT=100
  export STUB_REFUND_CREATED=1789395957
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(slack_log)" == *"Duplicate concession detected"* ]]
  [[ "$(slack_log)" == *"100c overlap"* ]]
  [[ "$(slack_log)" == *"cbtxn_SAME_SECOND"* ]]
}

@test "one balance reversal cannot suppress two matching refunds" {
  historical_refund_fixture
  export STUB_REFUNDS_TWO_MATCHING=1
  export STUB_CREDIT_BALANCE=-1261
  export STUB_CBT_REFUND_REVERSED=1
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(slack_log)" == *"re_TEST"* ]]
  [[ "$(slack_log)" == *"re_TEST_2"* ]]
  [[ "$(slack_log)" == *"1261c overlap"* ]]
}

@test "refund with zero balance -> no page" {
  export STUB_CREDIT_BALANCE=0
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(slack_log)" ]
}

@test "refund whose credit is a TAGGED referral adjustment -> no page" {
  export STUB_CREDIT_BALANCE=-11772
  export STUB_CBT_TAGGED=1
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(slack_log)" ]
}

@test "already-reported refund is not paged twice (watermark)" {
  export STUB_CREDIT_BALANCE=-11772
  run "$SCRIPT"
  [[ "$(slack_log)" == *"re_TEST"* ]]
  : >"$BATS_TEST_TMPDIR/slack.log"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(slack_log)" ]
}

@test "unreadable credit balance is NOT watermarked -> retried and found on the next pass" {
  # Recording an unverifiable refund as "seen" would convert a failed read into a
  # permanent all-clear for that refund. It must also PAGE and exit non-zero: a
  # log line is not a signal (slack_notify writes no log trace either way), and a
  # green silent sweep is indistinguishable from a clean one.
  export STUB_CREDIT_BALANCE=-11772
  export STUB_CBT_BROKEN=1
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$(slack_log)" == *"UNVERIFIABLE"* ]]
  [[ "$output" == *"not marking seen"* ]]
  # Read recovers on the next pass; the finding must now surface.
  unset STUB_CBT_BROKEN
  run "$SCRIPT"
  [[ "$(slack_log)" == *"re_TEST"* ]]
}

@test "unresolvable customer is NOT watermarked, and pages" {
  export STUB_CHARGE_BROKEN=1
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not marking seen"* ]]
  [[ "$(slack_log)" == *"UNVERIFIABLE"* ]]
}

@test "Stripe refunds list failure -> exits non-zero and says detection is BLIND" {
  export STUB_REFUNDS_BROKEN=1
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$(slack_log)" == *"BLIND"* ]]
}

@test "non-list refunds payload -> exits non-zero, never reported as all-clear" {
  export STUB_REFUNDS_NOT_LIST=1
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$(slack_log)" == *"BLIND"* ]]
}

@test "no recent refunds -> clean exit, no page" {
  export STUB_REFUNDS_EMPTY=1
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(slack_log)" ]
}

@test "dry-run prints the page instead of sending it" {
  export STUB_CREDIT_BALANCE=-11772
  export REFUND_OVERLAP_DRY_RUN=1
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(slack_log)" ]
  [[ "$output" == *"DRY RUN"* ]]
  [[ "$output" == *"Duplicate concession detected"* ]]
}

# --- QA blockers 3 + 4 -------------------------------------------------------

@test "pages past the first 100 refunds: a finding on page 2 is still caught" {
  # QA finding: a bare --limit 100 silently truncates. A >100-refund burst would
  # leave the oldest rows unscanned forever, because they fall out of the rolling
  # window before the next tick sees them.
  export STUB_REFUNDS_TWO_PAGES=1
  export STUB_CREDIT_BALANCE=-11772
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(slack_log)" == *"re_PAGE2"* ]]
}

@test "a FAILED Slack delivery leaves the finding un-watermarked, so it retries" {
  # QA finding: watermarking at scan time meant one transient Slack failure
  # permanently suppressed that finding — a silent, unrecoverable miss.
  export STUB_CREDIT_BALANCE=-11772
  export STUB_SLACK_FAILS=1
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"left un-watermarked"* ]]
  # Delivery recovers on the next pass; the finding must still surface.
  unset STUB_SLACK_FAILS
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(slack_log)" == *"re_TEST"* ]]
}

@test "a DELIVERED finding is watermarked and never paged twice" {
  export STUB_CREDIT_BALANCE=-11772
  run "$SCRIPT"
  [[ "$(slack_log)" == *"re_TEST"* ]]
  : >"$BATS_TEST_TMPDIR/slack.log"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(slack_log)" ]
}

# --- QA round 2, Critical: the late-minted credit --------------------------
#
# The whole reason this detector exists is that Stripe can mint the compensating
# credit AFTER the refund — the exemplar had it appear 0.96h later. Watermarking
# a CLEAN refund on the first sweep makes that chronology permanently invisible:
# the run sees no credit, marks it seen forever, and the credit that shows up an
# hour later is skipped by every future run.

@test "a refund clean on pass 1 but carrying a credit on pass 2 is STILL caught" {
  export STUB_CREDIT_ON_PASS2=1
  export STUB_REFUND_CREATED="$(date -u +%s)"   # inside the settlement horizon
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(slack_log)" ]          # pass 1: genuinely nothing to report
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(slack_log)" == *"re_TEST"* ]]   # pass 2: the late credit MUST surface
}

@test "a refund older than the settlement horizon and clean IS watermarked" {
  # The adjacent case: re-checking forever would mean the state file never
  # settles and every sweep re-reads the whole window indefinitely.
  export STUB_CREDIT_BALANCE=0
  # Past the 48h settlement horizon but still inside the lookback window. An
  # "ancient" timestamp cannot exercise this: Stripe would not return it at all.
  export STUB_REFUND_CREATED=$(( $(date -u +%s) - 50*3600 ))
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qxF "re_TEST" "$REFUND_OVERLAP_STATE_DIR/seen-refunds"
}

@test "the settlement horizon must fit inside the lookback window, or refuse" {
  # A horizon longer than the lookback is silently void: the refund falls out of
  # the query window before it is ever re-checked. That must fail loudly.
  export REFUND_OVERLAP_LOOKBACK_HOURS=10
  export REFUND_OVERLAP_SETTLEMENT_HOURS=48
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"settlement horizon"* ]]
}

# --- QA round 3, carried-forward Critical: the window must survive a sweep ---
#
# A settlement horizon only works if the refund is still QUERYABLE when its
# re-check is due. With a 48h horizon, a 52h lookback and a DAILY cron, a refund
# 31h old at one sweep is 55h old at the next — already outside the window. It is
# never watermarked and never re-examined: the horizon looks like protection and
# delivers none.

@test "a refund unsettled at one daily sweep is still in-window at the NEXT sweep" {
  export STUB_CREDIT_ON_PASS2=1
  now=$(date -u +%s)
  # Sweep 1: refund is 31h old — inside the 48h horizon, so still unsettled.
  export STUB_REFUND_CREATED=$(( now - 31*3600 ))
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(slack_log)" ]
  [[ "$output" == *"UNSETTLED"* ]]
  # Sweep 2, one daily interval later: the refund is now 55h old. It MUST still
  # fall inside the query window, or the late-minted credit is lost forever.
  export STUB_REFUND_CREATED=$(( now - 55*3600 ))
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"scanning 0 refund"* ]]
  [[ "$(slack_log)" == *"re_TEST"* ]]
}

@test "lookback must cover settlement + one scheduling interval + margin, or refuse" {
  # The previous assertion (horizon < lookback) was satisfied by 48h/52h, which
  # is exactly the broken configuration above. The real invariant has to include
  # the cron cadence.
  export REFUND_OVERLAP_SETTLEMENT_HOURS=48
  export REFUND_OVERLAP_LOOKBACK_HOURS=52
  export REFUND_OVERLAP_SCHEDULE_INTERVAL_HOURS=24
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"scheduling interval"* ]]
}

# --- QA round 5, Critical: an unverifiable sweep is NOT a clean sweep --------

@test "a sweep where every row is unverifiable PAGES and exits non-zero" {
  # The only detector covering the dashboard path exited 0 in silence when reads
  # failed. Repeat that for 80h and the refund ages out of the window: a real
  # cash-plus-credit overlap is then lost permanently, with nothing ever said.
  export STUB_CREDIT_BALANCE=-11772
  export STUB_CBT_BROKEN=1
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$(slack_log)" == *"UNVERIFIABLE"* ]]
  [[ "$(slack_log)" == *"NOT a clean sweep"* ]]
}

@test "a genuinely clean sweep still exits 0 and stays silent" {
  # The adjacent case: paging on every quiet day would train everyone to ignore
  # this alert, which is its own kind of silence.
  export STUB_CREDIT_BALANCE=0
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(slack_log)" ]
}

@test "findings AND unverifiable rows in the same sweep: both are reported" {
  export STUB_CREDIT_BALANCE=-11772
  export STUB_UNVERIFIABLE_EXTRA=1
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$(slack_log)" == *"Duplicate concession detected"* ]]
  [[ "$(slack_log)" == *"UNVERIFIABLE"* ]]
}

@test "a refund with NO charge is counted unverifiable, not mis-parsed" {
  # IFS=$'\t' collapses consecutive tabs, so an empty charge column used to shift
  # `created` into `charge_id` and blank out `refund_created` — silently
  # mis-attributing the row and making it unable to ever settle.
  export STUB_REFUND_NO_CHARGE=1
  export STUB_CREDIT_BALANCE=0
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$(slack_log)" == *"UNVERIFIABLE"* ]]
  [[ "$output" == *"not marking seen"* ]]
}

# --- QA round 9, Important: a refund that never paid out is not a concession --

@test "a FAILED refund with a live credit is not reported as a duplicate" {
  export STUB_REFUND_STATUS=failed
  export STUB_CREDIT_BALANCE=-11772
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(slack_log)" ]
}

@test "a PENDING refund is skipped WITHOUT watermarking (it may still succeed)" {
  export STUB_REFUND_STATUS=pending
  export STUB_CREDIT_BALANCE=-11772
  run "$SCRIPT"
  [ -z "$(slack_log)" ]
  ! grep -qxF "re_TEST" "$REFUND_OVERLAP_STATE_DIR/seen-refunds" 2>/dev/null
}

@test "a refund with a MISSING status fails closed (pages, non-zero)" {
  export STUB_REFUND_STATUS=absent
  export STUB_CREDIT_BALANCE=-11772
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$(slack_log)" == *"UNVERIFIABLE"* ]]
}

@test "a SUCCEEDED refund with a live credit is still reported" {
  export STUB_REFUND_STATUS=succeeded
  export STUB_CREDIT_BALANCE=-11772
  run "$SCRIPT"
  [[ "$(slack_log)" == *"re_TEST"* ]]
}

@test "a refund with a MISSING created fails closed, and is not watermarked as settled" {
  # `.created // 0` turns an unreadable row into an ancient, settled one: it is
  # older than any cutoff, so it gets watermarked permanently and a late-minted
  # credit is never checked. Same `// 0` coercion class as the balance-transaction
  # schema bug.
  export STUB_REFUND_NO_CREATED=1
  export STUB_CREDIT_BALANCE=0
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$(slack_log)" == *"UNVERIFIABLE"* ]]
  ! grep -qxF "re_TEST" "$REFUND_OVERLAP_STATE_DIR/seen-refunds" 2>/dev/null
}

@test "hitting the pagination ceiling with has_more FAILS the sweep, it does not continue" {
  # Warning and carrying on reports an incomplete dataset as a complete one: an
  # overlap in an unscanned row is missed, and if everything scanned is clean the
  # run still exits 0 and the refund eventually ages out.
  export STUB_ENDLESS_PAGES=1
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$(slack_log)" == *"INCOMPLETE"* ]]
  # Nothing from a partial dataset may be watermarked.
  [ ! -s "$REFUND_OVERLAP_STATE_DIR/seen-refunds" ]
}

# ── alert routing: #hydra-finance as the finance bot, tagging Nick and Aaron ──
# These alerts carry a customer id and a dollar figure and are actioned by Nick
# and Aaron, not by whoever is on devops rota, so the route is part of the
# contract rather than a cosmetic default.

@test "a finding pages #hydra-finance as the finance bot, tagging Nick and Aaron" {
  export STUB_CREDIT_BALANCE=-11772
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(slack_log)" == *"chan=C0C2LT1HKDJ"* ]]
  [[ "$(slack_log)" == *"bot=finance"* ]]
  [[ "$(slack_log)" == *"<@U0AL36NADEY>"* ]]
  [[ "$(slack_log)" == *"<@U7RP6HKUZ>"* ]]
}

@test "a caller may still override the channel and bot" {
  # Route is a default, not a hardcode: an operator rehearsing against a scratch
  # channel must not have to edit the script.
  export STUB_CREDIT_BALANCE=-11772
  export SLACK_CHANNEL=C0SCRATCH
  export SLACK_NOTIFY_BOT=devops
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(slack_log)" == *"chan=C0SCRATCH"* ]]
  [[ "$(slack_log)" == *"bot=devops"* ]]
  [[ "$(slack_log)" != *"chan=C0C2LT1HKDJ"* ]]
}

@test "a BLIND read failure also reaches finance and tags both approvers" {
  # The degradation alerts matter MORE than a finding, not less: a blind
  # watchdog means new duplicates are accruing with nobody watching. Previously
  # these went out untagged, so they landed in a channel with no owner.
  export STUB_REFUNDS_BROKEN=1
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$(slack_log)" == *"BLIND"* ]]
  [[ "$(slack_log)" == *"bot=finance"* ]]
  [[ "$(slack_log)" == *"<@U0AL36NADEY>"* ]]
  [[ "$(slack_log)" == *"<@U7RP6HKUZ>"* ]]
}
