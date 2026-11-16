#!/usr/bin/env bats
# Tests for the machine-approval path of muso-stripe-write.sh: a firstmate decision
# record may stand in for the one-time override and the keep-subscription waiver,
# inside the caps only, and never for the double-concession gate.
#
# The record directory, kill file and audit file are literals in the wrapper, so
# these tests run a scratch copy with only those three literals rewritten. The
# checked-in file is run unmodified for the "not armed" refusal.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  REAL="$REPO_ROOT/scripts/muso-stripe-write.sh"
  BIN="$BATS_TEST_TMPDIR/bin"
  DIR="$BATS_TEST_TMPDIR/approvals"
  KILL="$BATS_TEST_TMPDIR/machine.disabled"
  AUDIT="$BATS_TEST_TMPDIR/audit/audit.jsonl"
  USED="$BATS_TEST_TMPDIR/audit/used"
  mkdir -p "$BIN" "$DIR"
  # The reviewer key lives off-host by design, so the fixture stands in for it: a
  # throwaway ed25519 key whose public half is the allowed-signers list this
  # scratch copy of the wrapper checks against.
  KEY="$BATS_TEST_TMPDIR/reviewer_ed25519"
  SIGNERS="$BATS_TEST_TMPDIR/refund-approval-reviewer.allowed_signers"
  ssh-keygen -q -t ed25519 -N '' -C machine-approval-test -f "$KEY" >/dev/null
  printf 'outbound-copy-reviewer namespaces="muso-refund-approval-v1" %s\n' "$(cat "$KEY.pub")" >"$SIGNERS"
  # The second switch: whether the class may spend at all. Armed in the fixture
  # (with a named approval) so the money-path cases exercise the path itself; the
  # cases at the end of this file take each refusal in turn.
  REGISTRY="$BATS_TEST_TMPDIR/refund-machine-approval-automation.json"
  registry_armed_json() {
    jq -cn --arg by "$1" --arg ref "$2" --argjson en "$3" \
      '{capability:"refund-machine-approval", enabled:$en, approved_by:$by, approval_ref:$ref,
        cap_usd_per_refund:150, cap_usd_per_customer_per_year:300}' >"$REGISTRY"
  }
  registry_armed_json "aaron" "test ruling 2026-11-15" true
  WRAPPER="$BATS_TEST_TMPDIR/muso-stripe-write.sh"
  sed -e "s|^readonly MACHINE_APPROVAL_DIR=.*|readonly MACHINE_APPROVAL_DIR=\"$DIR\"|" \
      -e "s|^readonly MACHINE_APPROVAL_KILL=.*|readonly MACHINE_APPROVAL_KILL=\"$KILL\"|" \
      -e "s|^readonly MACHINE_APPROVAL_AUDIT=.*|readonly MACHINE_APPROVAL_AUDIT=\"$AUDIT\"|" \
      -e "s|^readonly MACHINE_APPROVAL_SIGNERS=.*|readonly MACHINE_APPROVAL_SIGNERS=\"$SIGNERS\"|" \
      -e "s|^readonly MACHINE_APPROVAL_USED_DIR=.*|readonly MACHINE_APPROVAL_USED_DIR=\"$USED\"|" \
      -e "s|^readonly MACHINE_APPROVAL_REGISTRY=.*|readonly MACHINE_APPROVAL_REGISTRY=\"$REGISTRY\"|" \
      "$REAL" >"$WRAPPER"
  chmod +x "$WRAPPER"
  export CODEX_HEALTH_LIB="$REPO_ROOT/scripts/lib/codex-health.sh"
  export STRIPE_CREDIT_LIB="$REPO_ROOT/scripts/lib/stripe-credit.sh"

  cat >"$BIN/stripe" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "charges retrieve")
    [ "${STUB_CHARGE_BROKEN:-0}" -gt 0 ] && { echo ""; exit 0; }
    printf '{"id":"%s","customer":"%s","invoice":"in_TEST","currency":"%s","paid":true,"disputed":%s,"amount":%s,"amount_refunded":%s}\n' \
      "${3:-ch_A}" "${STUB_CHARGE_CUSTOMER:-cus_TEST}" "${STUB_CURRENCY:-usd}" "${STUB_DISPUTED:-false}" \
      "${STUB_AMOUNT:-1250}" "${STUB_CHARGE_REFUNDED:-0}"
    ;;
  "invoices retrieve") echo '{"subscription":"sub_TEST"}' ;;
  "subscriptions list")
    if [ "${STUB_ACTIVE_SUBS:-0}" -gt 0 ]; then
      echo '{"object":"list","data":[{"id":"sub_LIVE","status":"active","cancel_at_period_end":false}]}'
    else
      echo '{"object":"list","data":[{"id":"sub_OLD","status":"canceled"}]}'
    fi
    ;;
  "charges list")
    echo "$*" >>"$STUB_STATE_DIR/list-calls"
    # Something an operator does while a run is reading the customer's charges.
    [ -n "${STUB_ON_LIST_TOUCH:-}" ] && : >"$STUB_ON_LIST_TOUCH"
    [ -n "${STUB_ON_LIST_RMDIR:-}" ] && rm -rf "$STUB_ON_LIST_RMDIR"
    [ -n "${STUB_ON_LIST_EDIT:-}" ] && echo ' ' >>"$STUB_ON_LIST_EDIT"
    after=""; prev=""
    for a in "$@"; do [ "$prev" = "--starting-after" ] && after="$a"; prev="$a"; done
    if [ -n "${STUB_PAGE2_BROKEN:-}" ] && [ -n "$after" ]; then
      exit 1
    elif [ "${STUB_ENDLESS:-0}" -gt 0 ]; then
      # A list that never ends: every page says more follow.
      k="$(wc -l <"$STUB_STATE_DIR/list-calls")"
      printf '{"object":"list","has_more":true,"data":[{"id":"ch_e%d","amount_refunded":0}]}\n' "$k"
    elif [ "${STUB_STUCK_CURSOR:-0}" -gt 0 ]; then
      printf '{"object":"list","has_more":true,"data":[{"id":"ch_same","amount_refunded":0}]}\n'
    elif [ -n "${STUB_ROWS:-}" ]; then
      # STUB_ROWS charges, each refunded STUB_EACH cents, served 100 to a page
      # the way Stripe does: has_more until the last page, cursor = last id.
      start=1
      [ -n "$after" ] && start=$(( ${after#ch_p} + 1 ))
      end=$(( start + 99 )); more=true
      [ "$end" -ge "$STUB_ROWS" ] && { end="$STUB_ROWS"; more=false; }
      printf '{"object":"list","has_more":%s,"data":[' "$more"
      for i in $(seq "$start" "$end"); do
        [ "$i" -gt "$start" ] && printf ','
        printf '{"id":"ch_p%d","amount_refunded":%s}' "$i" "${STUB_EACH:-0}"
      done
      printf ']}\n'
    elif [ "${STUB_INCOMPLETE_ROW:-0}" -gt 0 ]; then
      printf '{"object":"list","has_more":false,"data":[{"id":"ch_A"},{"id":"ch_B","amount_refunded":1250}]}\n'
    else
      done_total="${STUB_ALREADY_REFUNDED:-0}"
      if [ -s "$STUB_STATE_DIR/refunded" ]; then
        done_total=$((done_total + $(paste -sd+ - <"$STUB_STATE_DIR/refunded")))
      fi
      case "${STUB_HAS_MORE:-false}" in
        absent) printf '{"object":"list","data":[{"id":"ch_A","amount_refunded":%s}]}\n' "$done_total" ;;
        *) printf '{"object":"list","has_more":%s,"data":[{"id":"ch_A","amount_refunded":%s}]}\n' "${STUB_HAS_MORE:-false}" "$done_total" ;;
      esac
    fi
    ;;
  "customers retrieve") echo "{\"id\":\"cus_TEST\",\"balance\":${STUB_CREDIT_BALANCE:-0}}" ;;
  "get /v1/customers/cus_TEST/balance_transactions")
    echo '{"object":"list","data":[{"id":"cbtxn_LIVE","type":"invoice_too_small","amount":-11772,"ending_balance":-11772,"created":1,"metadata":{}}]}' ;;
  "refunds create")
    echo "$*" >>"$STUB_STATE_DIR/refund-calls"
    refunded="${STUB_AMOUNT:-1250}"
    for a in "$@"; do case "$a" in amount=*) refunded="${a#amount=}" ;; esac; done
    # The refund shows in the customer's charge list only once it has landed,
    # so a run that reads the list while this one is in flight sees the old total.
    # What did the wrapper's durable state look like at the moment the money moved?
    if [ -n "${STUB_REFUND_PROBE_OUT:-}" ]; then
      jq -r '.state // "none"' "$STUB_REFUND_PROBE_DIR/$STUB_REFUND_PROBE_SHA.json" 2>/dev/null \
        >"$STUB_REFUND_PROBE_OUT" || echo none >"$STUB_REFUND_PROBE_OUT"
    fi
    [ "${STUB_REFUND_SLEEP:-0}" -gt 0 ] && sleep "$STUB_REFUND_SLEEP"
    [ "${STUB_REFUND_FAILS:-0}" -gt 0 ] && { echo '{"error":{"message":"card_declined"}}'; exit 1; }
    echo "$refunded" >>"$STUB_STATE_DIR/refunded"
    echo '{"id":"re_TEST123","status":"succeeded"}'
    ;;
  *) echo "STRIPE_CALLED $*" ;;
esac
SH
  chmod +x "$BIN/stripe"
  cat >"$BIN/journalctl" <<'SH'
#!/usr/bin/env bash
echo "model call outcome=ok provider=openai"
SH
  chmod +x "$BIN/journalctl"
  export PATH="$BIN:$PATH"
  export STRIPE_BIN="$BIN/stripe"
  export OPENCLAW_GATEWAY_UNIT="test-unit"
  STUB_STATE_DIR="$BATS_TEST_TMPDIR/stub-state"
  mkdir -p "$STUB_STATE_DIR"
  export STUB_STATE_DIR
}

# record [jq-edit] — write a valid record, optionally edited, to $DIR/rec.json.
record() {
  jq -n '{schema:"refund-machine-approval.v1", approver:"firstmate",
          decision_ref:"firstmate inbox example/001", customer:"cus_TEST", charge:"ch_A",
          amount_cents:1250, currency:"usd", keep_subscription:true,
          legal_settlement:false, formal_claim:false, legal_threat:false,
          evidence:{subscription_state:"sub_TEST active, 12.50/month",
                    prior_refunds:"none on the customer",
                    caps:"12.50 of 150 per refund; 0 of 300 for the customer",
                    service_failure:{from:"2026-04-02", to:"2026-05-07", query:"SELECT 1"}}}' \
    | jq "${1:-.}" >"$DIR/rec.json"
  sign_record
}

# sign_record — sign $DIR/rec.json with the fixture key, in the wrapper's namespace.
# The wrapper re-verifies on every run, so an unsigned or stale record is refused
# before anything else is read.
# The machine path appends its own `-i machine-approval-<sha>` so Stripe dedupes a
# replay; assertions about the forwarded argv drop that pair, and the key itself is
# asserted in its own case.
refund_calls() { sed 's/ -i machine-approval-[0-9a-f]*$//' "$STUB_STATE_DIR/refund-calls"; }

sign_record() {
  rm -f "$DIR/rec.json.sig"
  ssh-keygen -Y sign -f "$KEY" -n muso-refund-approval-v1 "$DIR/rec.json" >/dev/null 2>&1
}

refund() { run "$WRAPPER" refunds create -d charge=ch_A --confirm --machine-approval "$DIR/rec.json" "$@"; }
no_refund() { [ ! -e "$STUB_STATE_DIR/refund-calls" ]; }

@test "valid record, active subscription kept -> refund runs, flag stripped, intent then executed" {
  record
  STUB_ACTIVE_SUBS=1 refund
  [ "$status" -eq 0 ]
  [[ "$output" == *"AUTHORIZED-MACHINE"* ]]
  [[ "$output" == *"re_TEST123"* ]]
  [ "$(refund_calls)" = "refunds create -d charge=ch_A --confirm" ]
  [ "$(jq -r '.phase' "$AUDIT" | paste -sd, -)" = "intent,executed" ]
  [ "$(jq -rs '.[1].refund_id' "$AUDIT")" = "re_TEST123" ]
  [ "$(jq -rs '.[0].record.evidence.service_failure.from' "$AUDIT")" = "2026-04-02" ]
  [ "$(jq -rs '.[0].record_sha256' "$AUDIT")" = "$(sha256sum "$DIR/rec.json" | awk '{print $1}')" ]
}

@test "a record stands in for the repeat-refund override, inside the customer cap" {
  record
  STUB_ALREADY_REFUNDED=1250 refund
  [ "$status" -eq 0 ]
  [[ "$output" == *"1250 cents refunded to cus_TEST before this"* ]]
}

@test "the same record twice -> second run REFUSED, one refund only" {
  record
  refund
  [ "$status" -eq 0 ]
  refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"already been used"* ]]
  [ "$(wc -l <"$STUB_STATE_DIR/refund-calls")" -eq 1 ]
}

@test "a LARGE record that was already used is still REFUSED (no SIGPIPE replay window)" {
  # Each audit line carries the record verbatim, so a record with a big evidence
  # block makes multi-100KB lines. The used-check must consume the whole stream:
  # `grep -q | grep` returns 141 under pipefail when the downstream grep exits
  # first, and the `if` then reads a USED record as unused (qa-review, 2026-11-15).
  mkdir -p "$DIR"
  python3 - "$DIR/rec.json" <<'PYREC'
import json, sys
rec = {
  "schema": "refund-machine-approval.v1",
  "approver": "firstmate",
  "decision_ref": "test decision_ref",
  "charge": "ch_A",
  "customer": "cus_TEST",
  "amount_cents": 1250,
  "currency": "usd",
  "keep_subscription": True,
  "legal_settlement": False, "formal_claim": False, "legal_threat": False,
  "evidence": {
    "subscription_state": "active", "prior_refunds": "none", "caps": "150/300",
    "service_failure": {"from": "2026-04-02", "to": "2026-05-07", "query": "x"*200000},
  },
}
open(sys.argv[1], "w").write(json.dumps(rec))
PYREC
  sign_record
  sha="$(sha256sum "$DIR/rec.json" | awk '{print $1}')"
  mkdir -p "$(dirname "$AUDIT")"
  python3 - "$AUDIT" "$sha" <<'PYAUD'
import json, sys
audit, sha = sys.argv[1], sys.argv[2]
pad = "y" * 200000
with open(audit, "w") as fh:
    for phase in ("intent", "executed"):
        # jq -cn writes the real audit lines compact; match that exactly.
        fh.write(json.dumps({"phase": phase, "record_sha256": sha, "charge": "ch_A", "pad": pad},
                            separators=(",", ":")) + "\n")
PYAUD
  refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"already been used"* ]]
  [ ! -s "$STUB_STATE_DIR/refund-calls" ]
}

@test "a rotated audit cannot re-enable a spent record (used marker, not the log)" {
  # qa-review 2026-11-15T14:25Z: the used-check read the audit log, which an
  # operator may rotate or truncate. Wiping it made a spent record look unused and
  # the same signed record could refund the rest of the charge.
  record
  refund
  [ "$status" -eq 0 ]
  rm -rf "$(dirname "$AUDIT")"          # rotate the log AND the marker dir together
  mkdir -p "$USED" "$(dirname "$AUDIT")" # the marker dir is recreated, empty: still refused?
  sha="$(sha256sum "$DIR/rec.json" | awk '{print $1}')"
  jq -cn '{state:"executed", charge:"ch_A", amount_cents:1250, refund_id:"re_TEST123"}' >"$USED/$sha.json"
  : >"$AUDIT"                            # the rotated log: empty
  refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"already been started"* ]]
  [[ "$output" == *"state 'executed'"* ]]
  [ "$(wc -l <"$STUB_STATE_DIR/refund-calls")" -eq 1 ]
}

@test "the Stripe idempotency key is derived from the record sha" {
  record
  refund
  [ "$status" -eq 0 ]
  sha="$(sha256sum "$DIR/rec.json" | awk '{print $1}')"
  [[ "$(cat "$STUB_STATE_DIR/refund-calls")" == *"-i machine-approval-$sha"* ]]
}

@test "a successful machine refund leaves a used marker" {
  record
  refund
  [ "$status" -eq 0 ]
  sha="$(sha256sum "$DIR/rec.json" | awk '{print $1}')"
  [ -f "$USED/$sha.json" ]
  [ "$(jq -r '.state' "$USED/$sha.json")" = "executed" ]
}

@test "the used marker is written BEFORE the money moves (crash window closed)" {
  # qa-review 2026-11-15T14:32Z: refund at :728, marker at :732. A crash in that
  # interval left no marker, and once the log was rotated and Stripe's
  # idempotency-key retention had lapsed the record could refund again. The marker
  # must exist before the Stripe call, so simulate the crash by making the write
  # the thing that kills the run: STUB_ON_REFUND inspects the marker dir mid-call.
  record
  export STUB_REFUND_PROBE_DIR="$USED"
  export STUB_REFUND_PROBE_SHA="$(sha256sum "$DIR/rec.json" | awk '{print $1}')"
  export STUB_REFUND_PROBE_OUT="$BATS_TEST_TMPDIR/probe"
  refund
  [ "$status" -eq 0 ]
  # the stub recorded what it saw at call time: the marker, in state intent
  [ "$(cat "$STUB_REFUND_PROBE_OUT")" = "intent" ]
  [ "$(jq -r '.state' "$USED/$STUB_REFUND_PROBE_SHA.json")" = "executed" ]
}

@test "a crashed run (marker left as intent) + a rotated audit is REFUSED, not replayed" {
  record
  sha="$(sha256sum "$DIR/rec.json" | awk '{print $1}')"
  mkdir -p "$USED"
  jq -cn '{state:"intent", charge:"ch_A", amount_cents:1250}' >"$USED/$sha.json"
  rm -f "$AUDIT"                 # the log was rotated away; the marker dir is what an operator keeps
  refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"already been started"* ]]
  [[ "$output" == *"state 'intent'"* ]]
  [ ! -s "$STUB_STATE_DIR/refund-calls" ]
}

@test "a caller-supplied idempotency key on the machine path -> REFUSED" {
  # The key is what makes a replay safe on Stripe's side; a caller who chose it
  # could make a second run of the same record into a second refund.
  record
  run "$WRAPPER" refunds create -d charge=ch_A -i something-else --confirm \
    --machine-approval "$DIR/rec.json"
  [ "$status" -eq 3 ]
  [[ "$output" == *"sets its own idempotency key"* ]]
  [ ! -s "$STUB_STATE_DIR/refund-calls" ]
}

@test "two concurrent runs of the same record -> one refund only" {
  record
  STUB_ACTIVE_SUBS=1 STUB_REFUND_SLEEP=1 "$WRAPPER" refunds create -d charge=ch_A --confirm \
    --machine-approval "$DIR/rec.json" >"$BATS_TEST_TMPDIR/run1.out" 2>&1 &
  p1=$!
  STUB_ACTIVE_SUBS=1 STUB_REFUND_SLEEP=1 "$WRAPPER" refunds create -d charge=ch_A --confirm \
    --machine-approval "$DIR/rec.json" >"$BATS_TEST_TMPDIR/run2.out" 2>&1 &
  p2=$!
  s1=0; s2=0
  wait "$p1" || s1=$?
  wait "$p2" || s2=$?
  [ "$s1" -eq 0 ] || [ "$s2" -eq 0 ]
  [ "$s1" -ne 0 ] || [ "$s2" -ne 0 ]
  [ "$(wc -l <"$STUB_STATE_DIR/refund-calls")" -eq 1 ]
  [ "$(jq -r '.phase' "$AUDIT" | paste -sd, -)" = "intent,executed" ]
}

@test "two concurrent records for one customer at the cap boundary -> one refund only" {
  record '.charge = "ch_A" | .amount_cents = 15000'
  cp "$DIR/rec.json" "$DIR/rec1.json"; cp "$DIR/rec.json.sig" "$DIR/rec1.json.sig"
  record '.charge = "ch_B" | .amount_cents = 15000'
  cp "$DIR/rec.json" "$DIR/rec2.json"; cp "$DIR/rec.json.sig" "$DIR/rec2.json.sig"
  STUB_AMOUNT=15000 STUB_ALREADY_REFUNDED=1000 STUB_ACTIVE_SUBS=1 STUB_REFUND_SLEEP=1 \
    "$WRAPPER" refunds create -d charge=ch_A -d amount=15000 --confirm \
    --machine-approval "$DIR/rec1.json" >"$BATS_TEST_TMPDIR/run1.out" 2>&1 &
  p1=$!
  STUB_AMOUNT=15000 STUB_ALREADY_REFUNDED=1000 STUB_ACTIVE_SUBS=1 STUB_REFUND_SLEEP=1 \
    "$WRAPPER" refunds create -d charge=ch_B -d amount=15000 --confirm \
    --machine-approval "$DIR/rec2.json" >"$BATS_TEST_TMPDIR/run2.out" 2>&1 &
  p2=$!
  s1=0; s2=0
  wait "$p1" || s1=$?
  wait "$p2" || s2=$?
  [ "$s1" -eq 0 ] || [ "$s2" -eq 0 ]
  [ "$s1" -eq 3 ] || [ "$s2" -eq 3 ]
  [ "$(wc -l <"$STUB_STATE_DIR/refund-calls")" -eq 1 ]
  [ "$(jq -r '.phase' "$AUDIT" | paste -sd, -)" = "intent,executed" ]
}

@test "a failed Stripe write records failed, and the record is not retried blind" {  record
  STUB_REFUND_FAILS=1 refund
  [ "$status" -eq 1 ]
  [ "$(jq -r '.phase' "$AUDIT" | paste -sd, -)" = "intent,failed" ]
  refund
  [ "$status" -eq 3 ]
  [ "$(wc -l <"$STUB_STATE_DIR/refund-calls")" -eq 1 ]
}

@test "not armed: the committed wrapper refuses, since nothing creates the record dir" {
  [ ! -d /etc/hydra/refund-machine-approvals ] || skip "the host is armed"
  record
  run "$REAL" refunds create -d charge=ch_A --confirm --machine-approval "$DIR/rec.json"
  [ "$status" -eq 3 ]
  [[ "$output" == *"not enabled"* || "$output" == *"switch file is missing"* || "$output" == *"not armed"* ]]
  no_refund
}

@test "kill file present -> REFUSED" {
  record
  : >"$KILL"
  refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"switched off"* ]]
  no_refund
}

@test "kill file created while the run reads the customer's charges -> REFUSED, no intent" {
  record
  STUB_ON_LIST_TOUCH="$KILL" refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"switched off while this run was in progress"* ]]
  no_refund
  [ ! -e "$AUDIT" ]
}

@test "record dir removed while the run reads the customer's charges -> REFUSED" {
  record
  STUB_ON_LIST_RMDIR="$DIR" refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"disarmed while this run was in progress"* ]]
  no_refund
}

@test "record changed while the run reads the customer's charges -> REFUSED" {
  record
  STUB_ON_LIST_EDIT="$DIR/rec.json" refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"removed or changed while this run was in progress"* ]]
  no_refund
}

@test "kill file created while a second run waits on the lock -> the queued run REFUSES" {
  record '.charge = "ch_A"'
  cp "$DIR/rec.json" "$DIR/rec1.json"; cp "$DIR/rec.json.sig" "$DIR/rec1.json.sig"
  record '.charge = "ch_B"'
  cp "$DIR/rec.json" "$DIR/rec2.json"; cp "$DIR/rec.json.sig" "$DIR/rec2.json.sig"
  STUB_REFUND_SLEEP=3 "$WRAPPER" refunds create -d charge=ch_A --confirm \
    --machine-approval "$DIR/rec1.json" >"$BATS_TEST_TMPDIR/run1.out" 2>&1 &
  p1=$!
  # Wait until the first run is inside its Stripe call, holding the lock.
  for _ in $(seq 1 50); do [ -e "$STUB_STATE_DIR/refund-calls" ] && break; sleep 0.1; done
  [ -e "$STUB_STATE_DIR/refund-calls" ]
  "$WRAPPER" refunds create -d charge=ch_B --confirm \
    --machine-approval "$DIR/rec2.json" >"$BATS_TEST_TMPDIR/run2.out" 2>&1 &
  p2=$!
  sleep 1
  : >"$KILL"
  s1=0; s2=0
  wait "$p1" || s1=$?
  wait "$p2" || s2=$?
  [ "$s1" -eq 0 ]
  [ "$s2" -eq 3 ]
  grep -q "switched off while this run was in progress" "$BATS_TEST_TMPDIR/run2.out"
  [ "$(wc -l <"$STUB_STATE_DIR/refund-calls")" -eq 1 ]
  [ "$(jq -r '.phase' "$AUDIT" | paste -sd, -)" = "intent,executed" ]
}

@test "registry flipped off while a second run waits on the lock -> the queued run REFUSES" {
  record '.charge = "ch_A"'
  cp "$DIR/rec.json" "$DIR/rec1.json"; cp "$DIR/rec.json.sig" "$DIR/rec1.json.sig"
  record '.charge = "ch_B"'
  cp "$DIR/rec.json" "$DIR/rec2.json"; cp "$DIR/rec.json.sig" "$DIR/rec2.json.sig"
  STUB_REFUND_SLEEP=3 "$WRAPPER" refunds create -d charge=ch_A --confirm \
    --machine-approval "$DIR/rec1.json" >"$BATS_TEST_TMPDIR/run1.out" 2>&1 &
  p1=$!
  # Wait until the first run is inside its Stripe call, holding the lock.
  for _ in $(seq 1 50); do [ -e "$STUB_STATE_DIR/refund-calls" ] && break; sleep 0.1; done
  [ -e "$STUB_STATE_DIR/refund-calls" ]
  "$WRAPPER" refunds create -d charge=ch_B --confirm \
    --machine-approval "$DIR/rec2.json" >"$BATS_TEST_TMPDIR/run2.out" 2>&1 &
  p2=$!
  sleep 1
  # The operator disarms the class by a reviewed change, not by touching the host:
  # enabled:false lands in the row the second switch reads.
  registry_armed_json "aaron" "test ruling 2026-11-15" false
  s1=0; s2=0
  wait "$p1" || s1=$?
  wait "$p2" || s2=$?
  [ "$s1" -eq 0 ]
  [ "$s2" -eq 3 ]
  grep -q "switched off while this run was in progress" "$BATS_TEST_TMPDIR/run2.out"
  [ "$(wc -l <"$STUB_STATE_DIR/refund-calls")" -eq 1 ]
  [ "$(jq -r '.phase' "$AUDIT" | paste -sd, -)" = "intent,executed" ]
}

@test "registry re-approved with different caps while the run waits -> REFUSED, not the caps loaded at startup" {
  record '.charge = "ch_A"'
  cp "$DIR/rec.json" "$DIR/rec1.json"; cp "$DIR/rec.json.sig" "$DIR/rec1.json.sig"
  record '.charge = "ch_B"'
  cp "$DIR/rec.json" "$DIR/rec2.json"; cp "$DIR/rec.json.sig" "$DIR/rec2.json.sig"
  STUB_REFUND_SLEEP=3 "$WRAPPER" refunds create -d charge=ch_A --confirm \
    --machine-approval "$DIR/rec1.json" >"$BATS_TEST_TMPDIR/run1.out" 2>&1 &
  p1=$!
  for _ in $(seq 1 50); do [ -e "$STUB_STATE_DIR/refund-calls" ] && break; sleep 0.1; done
  [ -e "$STUB_STATE_DIR/refund-calls" ]
  "$WRAPPER" refunds create -d charge=ch_B --confirm \
    --machine-approval "$DIR/rec2.json" >"$BATS_TEST_TMPDIR/run2.out" 2>&1 &
  p2=$!
  sleep 1
  # Still enabled, but the caps now disagree with this wrapper: the re-read has to
  # catch it under the lock, not apply the numbers the process started with.
  jq -cn '{capability:"refund-machine-approval", enabled:true, approved_by:"aaron",
           approval_ref:"test ruling 2026-11-15", cap_usd_per_refund:500,
           cap_usd_per_customer_per_year:900}' >"$REGISTRY"
  s1=0; s2=0
  wait "$p1" || s1=$?
  wait "$p2" || s2=$?
  [ "$s1" -eq 0 ]
  [ "$s2" -eq 3 ]
  grep -q "disagree with this wrapper" "$BATS_TEST_TMPDIR/run2.out"
  [ "$(wc -l <"$STUB_STATE_DIR/refund-calls")" -eq 1 ]
}

@test "a record outside the pinned dir -> REFUSED" {
  record
  cp "$DIR/rec.json" "$BATS_TEST_TMPDIR/elsewhere.json"
  run "$WRAPPER" refunds create -d charge=ch_A --confirm --machine-approval "$BATS_TEST_TMPDIR/elsewhere.json"
  [ "$status" -eq 3 ]
  [[ "$output" == *"directly inside"* ]]
  no_refund
}

@test "a symlink in the pinned dir to a record elsewhere -> REFUSED" {
  record
  mv "$DIR/rec.json" "$BATS_TEST_TMPDIR/elsewhere.json"
  ln -s "$BATS_TEST_TMPDIR/elsewhere.json" "$DIR/rec.json"
  refund
  [ "$status" -eq 3 ]
  no_refund
}

@test "above the per-refund cap -> REFUSED to a human" {
  record '.amount_cents = 15001'
  STUB_AMOUNT=15001 refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"above the machine cap"* ]]
  no_refund
}

@test "exactly the per-refund cap -> allowed" {
  record '.amount_cents = 15000'
  STUB_AMOUNT=15000 refund
  [ "$status" -eq 0 ]
}

@test "past the per-customer cap with what Stripe shows already refunded -> REFUSED" {
  record
  STUB_ALREADY_REFUNDED=28751 refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"per customer"* ]]
  no_refund
}

list_calls() { wc -l <"$STUB_STATE_DIR/list-calls"; }

@test "more refunds than one page: the cap binds on the total of every page -> REFUSED" {
  # 160 refunded charges of 200 cents. Page one alone is 20000 and would pass
  # the 30000 cap with this 1250; both pages are 32000 and must not.
  record
  STUB_ROWS=160 STUB_EACH=200 refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"32000 cents refunded already"* ]]
  [[ "$output" == *"per customer"* ]]
  [ "$(list_calls)" -eq 2 ]
  no_refund
}

@test "three pages inside the cap -> every page summed, refund runs" {
  record
  STUB_ROWS=250 STUB_EACH=100 refund
  [ "$status" -eq 0 ]
  [[ "$output" == *"25000 cents refunded to cus_TEST before this"* ]]
  [ "$(list_calls)" -eq 3 ]
  [ "$(sed -n 2p "$STUB_STATE_DIR/list-calls")" = "charges list --customer cus_TEST --limit 100 --starting-after ch_p100" ]
  [ "$(sed -n 3p "$STUB_STATE_DIR/list-calls")" = "charges list --customer cus_TEST --limit 100 --starting-after ch_p200" ]
}

@test "a refund that sits only on the last page still binds the cap -> REFUSED" {
  # 201 refunded charges of 149 cents, and a 200-cent refund. Pages one and two
  # are 29800, which with the 200 is exactly the cap and would pass; the one
  # row on page three makes it 29949, and that must refuse.
  record '.amount_cents = 200'
  STUB_AMOUNT=200 STUB_ROWS=201 STUB_EACH=149 refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"29949 cents refunded already"* ]]
  [ "$(list_calls)" -eq 3 ]
  no_refund
}

@test "exactly one full page that Stripe says is the last -> read once, refund runs" {
  record
  STUB_ROWS=100 STUB_EACH=0 refund
  [ "$status" -eq 0 ]
  [ "$(list_calls)" -eq 1 ]
}

@test "a short page that says more follow, and the next page fails -> REFUSED" {
  record
  STUB_ROWS=160 STUB_EACH=0 STUB_PAGE2_BROKEN=1 refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"page 2"* ]]
  no_refund
}

@test "has_more missing from the page -> the end is unconfirmed -> REFUSED" {
  record
  STUB_HAS_MORE=absent refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"did not confirm the end"* ]]
  no_refund
}

@test "has_more is not a boolean -> REFUSED" {
  record
  STUB_HAS_MORE='"no"' refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"did not confirm the end"* ]]
  no_refund
}

@test "a charge list that never ends -> REFUSED at the page limit, not an endless read" {
  record
  STUB_ENDLESS=1 refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"did not end within"* ]]
  [ "$(list_calls)" -eq 50 ]
  no_refund
}

@test "Stripe returns the same page twice -> REFUSED" {
  record
  STUB_STUCK_CURSOR=1 refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"same page"* ]]
  [ "$(list_calls)" -eq 2 ]
  no_refund
}

@test "a charge row with no refund total -> customer cap unverifiable -> REFUSED" {
  record
  STUB_INCOMPLETE_ROW=1 refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"refund totals"* ]]
  no_refund
}

@test "legal_settlement true -> REFUSED to a human" {
  record '.legal_settlement = true'
  refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"named human"* ]]
  no_refund
}

@test "formal_claim true -> REFUSED" {
  record '.formal_claim = true'
  refund
  [ "$status" -eq 3 ]
  no_refund
}

@test "legal_settlement missing -> REFUSED (absent is not false)" {
  record 'del(.legal_settlement)'
  refund
  [ "$status" -eq 3 ]
  no_refund
}

# A legal-action threat is a named human's decision (Aaron), so the machine path
# refuses it however the record is shaped. `legal_threat` is required so a record
# cannot leave the question out.
@test "legal_threat true -> REFUSED to a human" {
  record '.legal_threat = true'
  refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"named human"* ]]
  no_refund
}

@test "legal_threat true with a reference -> still REFUSED to a human" {
  record '.legal_threat = true | .legal_threat_ref = "Intercom 123, customer message 2026-05-17"'
  refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"named human"* ]]
  no_refund
}

@test "legal_threat missing -> REFUSED (a record must say which)" {
  record 'del(.legal_threat)'
  refund
  [ "$status" -eq 3 ]
  no_refund
}

@test "legal_threat that is not true or false -> REFUSED" {
  record '.legal_threat = "no"'
  refund
  [ "$status" -eq 3 ]
  no_refund
}

@test "legal_threat false -> refund runs and the audit line carries the record" {
  record
  STUB_ACTIVE_SUBS=1 refund
  [ "$status" -eq 0 ]
  [ "$(jq -r '.phase' "$AUDIT" | paste -sd, -)" = "intent,executed" ]
  [ "$(jq -r '.record.legal_threat' "$AUDIT" | paste -sd, -)" = "false,false" ]
}

@test "an approver that is not on the machine table -> REFUSED" {
  record '.approver = "caroline"'
  refund
  [ "$status" -eq 3 ]
  no_refund
}

@test "evidence missing the service-failure query -> REFUSED" {
  record 'del(.evidence.service_failure.query)'
  refund
  [ "$status" -eq 3 ]
  no_refund
}

@test "a record for another charge -> REFUSED" {
  record '.charge = "ch_OTHER"'
  refund
  [ "$status" -eq 3 ]
  no_refund
}

@test "Stripe says the charge belongs to another customer -> REFUSED" {
  record
  STUB_CHARGE_CUSTOMER=cus_OTHER refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"Stripe does not show"* ]]
  no_refund
}

@test "a disputed charge -> REFUSED" {
  record
  STUB_DISPUTED=true refund
  [ "$status" -eq 3 ]
  no_refund
}

@test "a non-USD charge -> REFUSED" {
  record
  STUB_CURRENCY=eur refund
  [ "$status" -eq 3 ]
  no_refund
}

@test "charge unreadable -> REFUSED" {
  record
  STUB_CHARGE_BROKEN=1 refund
  [ "$status" -eq 3 ]
  no_refund
}

@test "amount= differing from the record -> REFUSED" {
  record
  refund -d amount=1300
  [ "$status" -eq 3 ]
  [[ "$output" == *"not the amount the record approves"* ]]
  no_refund
}

@test "no amount= and the record is not the whole remaining charge -> REFUSED" {
  record '.amount_cents = 600'
  refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"would refund the remaining 1250"* ]]
  no_refund
}

@test "partial refund with a matching amount= -> allowed" {
  record '.amount_cents = 600'
  refund -d amount=600
  [ "$status" -eq 0 ]
}

@test "keep_subscription false with a live subscription -> the paid-access gate still refuses" {
  record '.keep_subscription = false'
  STUB_ACTIVE_SUBS=1 refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"sub_LIVE"* ]]
  no_refund
}

@test "a live concession credit -> the double-concession gate still refuses a machine record" {
  record
  STUB_CREDIT_BALANCE=-11772 refund
  [ "$status" -eq 3 ]
  no_refund
  [ ! -e "$AUDIT" ]
}

@test "audit file unwritable -> REFUSED, no refund without a record of who approved it" {
  record
  mkdir -p "$(dirname "$AUDIT")"
  mkdir "$AUDIT"
  refund
  [ "$status" -eq 3 ]
  no_refund
}

@test "--machine-approval with a human override flag -> usage error" {
  record
  refund --override-confirmed-by U7RP6HKUZ --approval-msg-id 1.2
  [ "$status" -eq 2 ]
  no_refund
}

@test "--machine-approval on a write that is not a refund -> REFUSED" {
  record
  run "$WRAPPER" subscriptions cancel sub_X --machine-approval "$DIR/rec.json"
  [ "$status" -eq 3 ]
  [[ "$output" != *"STRIPE_CALLED"* ]]
}

@test "without --machine-approval the human gates are unchanged" {
  STUB_ACTIVE_SUBS=1 run "$WRAPPER" refunds create -d charge=ch_A --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"keep-subscription-confirmed-by"* ]]
  no_refund
}

# --- the signature: a record is an approval only when the reviewer key signs it ---

@test "unsigned record -> REFUSED before anything is read, nothing written" {
  record
  rm -f "$DIR/rec.json.sig"
  STUB_ACTIVE_SUBS=1 refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"is not signed"* ]]
  [[ "$output" == *"muso-refund-approval-v1"* ]]
  no_refund
  [ ! -e "$AUDIT" ]
}

@test "record edited after signing -> REFUSED (the signature binds the bytes)" {
  record
  jq '.amount_cents = 1500' "$DIR/rec.json" >"$DIR/rec.tmp" && mv "$DIR/rec.tmp" "$DIR/rec.json"
  STUB_ACTIVE_SUBS=1 refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"not a valid muso-refund-approval-v1 signature"* ]]
  no_refund
}

@test "signature made by another key -> REFUSED" {
  record
  ssh-keygen -q -t ed25519 -N '' -C stranger -f "$BATS_TEST_TMPDIR/stranger" >/dev/null
  rm -f "$DIR/rec.json.sig"
  ssh-keygen -Y sign -f "$BATS_TEST_TMPDIR/stranger" -n muso-refund-approval-v1 "$DIR/rec.json" >/dev/null 2>&1
  STUB_ACTIVE_SUBS=1 refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"not a valid muso-refund-approval-v1 signature"* ]]
  no_refund
}

@test "a copy-gate signature replayed as an approval -> REFUSED (different namespace)" {
  record
  rm -f "$DIR/rec.json.sig"
  ssh-keygen -Y sign -f "$KEY" -n muso-outbound-copy-v1 "$DIR/rec.json" >/dev/null 2>&1
  STUB_ACTIVE_SUBS=1 refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"not a valid muso-refund-approval-v1 signature"* ]]
  no_refund
}

@test "a signature from the right key over different bytes -> REFUSED" {
  record
  cp "$DIR/rec.json.sig" "$BATS_TEST_TMPDIR/other.sig"
  record '.amount_cents = 1200'
  cp "$BATS_TEST_TMPDIR/other.sig" "$DIR/rec.json.sig"
  STUB_ACTIVE_SUBS=1 refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"not a valid muso-refund-approval-v1 signature"* ]]
  no_refund
}

@test "allowed-signers list missing -> REFUSED, not skipped" {
  record
  rm -f "$SIGNERS"
  STUB_ACTIVE_SUBS=1 refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"is not readable"* ]]
  no_refund
}

@test "a signed valid record still runs end to end (the signature is a gate, not the whole gate)" {
  record
  STUB_ACTIVE_SUBS=1 refund
  [ "$status" -eq 0 ]
  [[ "$output" == *"AUTHORIZED-MACHINE"* ]]
}

@test "the pinned signers file is the copy-gate reviewer key in its own namespace" {
  local f="$REPO_ROOT/policies/refund-approval-reviewer.allowed_signers"
  [ -f "$f" ]
  grep -Eq '^outbound-copy-reviewer namespaces="muso-refund-approval-v1" ssh-ed25519 AAAA' "$f"
  # the public key is the one the copy gate pins: same key, different namespace, so
  # a verdict signature can never be replayed as a refund approval
  local copy="$REPO_ROOT/policies/outbound-copy-reviewer.allowed_signers"
  [ "$(awk '{print $NF}' "$copy")" = "$(awk '/^outbound-copy-reviewer/{print $NF}' "$f")" ]
}

@test "sign-refund-approval.sh refuses to sign a legal-threat record" {
  local tmp="$BATS_TEST_TMPDIR/signer"
  mkdir -p "$tmp/scripts" "$tmp/policies"
  cp "$REPO_ROOT/scripts/sign-refund-approval.sh" "$tmp/scripts/"
  cp "$SIGNERS" "$tmp/policies/refund-approval-reviewer.allowed_signers"
  record '.legal_threat = true | .legal_threat_ref = "intercom thread"'
  rm -f "$DIR/rec.json.sig"
  run "$tmp/scripts/sign-refund-approval.sh" "$DIR/rec.json" "$KEY"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must all be false"* ]]
  [ ! -e "$DIR/rec.json.sig" ]
}

@test "sign-refund-approval.sh signs a clean record and the signature verifies" {
  local tmp="$BATS_TEST_TMPDIR/signer2"
  mkdir -p "$tmp/scripts" "$tmp/policies"
  cp "$REPO_ROOT/scripts/sign-refund-approval.sh" "$tmp/scripts/"
  cp "$SIGNERS" "$tmp/policies/refund-approval-reviewer.allowed_signers"
  record
  rm -f "$DIR/rec.json.sig"
  run "$tmp/scripts/sign-refund-approval.sh" "$DIR/rec.json" "$KEY"
  [ "$status" -eq 0 ]
  [ -f "$DIR/rec.json.sig" ]
  STUB_ACTIVE_SUBS=1 refund
  [ "$status" -eq 0 ]
}

# --- one amount, in one form: the args ARE the request, so the wrapper must be able to check them ---

@test "--amount 600 against a record approving 1250 -> REFUSED (stripe-cli's other amount spelling)" {
  record
  run "$WRAPPER" refunds create -d charge=ch_A --confirm --amount 600 --machine-approval "$DIR/rec.json"
  [ "$status" -eq 3 ]
  [[ "$output" == *"cannot be compared with the approval record"* ]]
  no_refund
}

@test "--amount=600 -> REFUSED" {
  record
  run "$WRAPPER" refunds create -d charge=ch_A --confirm --amount=600 --machine-approval "$DIR/rec.json"
  [ "$status" -eq 3 ]
  [[ "$output" == *"cannot be compared with the approval record"* ]]
  no_refund
}

@test "-damount=600 (glued) -> REFUSED" {
  record
  run "$WRAPPER" refunds create -d charge=ch_A --confirm -damount=600 --machine-approval "$DIR/rec.json"
  [ "$status" -eq 3 ]
  [[ "$output" == *"cannot be compared with the approval record"* ]]
  no_refund
}

@test "--data=amount=600 -> REFUSED" {
  record
  run "$WRAPPER" refunds create -d charge=ch_A --confirm --data=amount=600 --machine-approval "$DIR/rec.json"
  [ "$status" -eq 3 ]
  [[ "$output" == *"cannot be compared with the approval record"* ]]
  no_refund
}

@test "the amount given twice -> REFUSED, not the last one wins" {
  record
  STUB_ACTIVE_SUBS=1 run "$WRAPPER" refunds create -d charge=ch_A -d amount=1250 -d amount=600 --confirm --machine-approval "$DIR/rec.json"
  [ "$status" -eq 3 ]
  [[ "$output" == *"given more than once"* ]]
  no_refund
}

@test "amount=600 against a record approving 1250 -> REFUSED (the plain form is still checked)" {
  record
  STUB_ACTIVE_SUBS=1 run "$WRAPPER" refunds create -d charge=ch_A -d amount=600 --confirm --machine-approval "$DIR/rec.json"
  [ "$status" -eq 3 ]
  [[ "$output" == *"is not the amount the record approves"* ]]
  no_refund
}

# --- one charge, in one form; and the record is read once, as bytes that were verified ---

@test "--charge ch_B beside -d charge=ch_A -> REFUSED (a second selector the record was never checked against)" {
  record
  run "$WRAPPER" refunds create -d charge=ch_A --confirm --charge ch_B --machine-approval "$DIR/rec.json"
  [ "$status" -eq 3 ]
  [[ "$output" == *"could select a charge the approval record was never checked against"* ]]
  no_refund
}

@test "the charge given twice -> REFUSED" {
  record
  run "$WRAPPER" refunds create -d charge=ch_A -d charge=ch_B --confirm --machine-approval "$DIR/rec.json"
  [ "$status" -eq 3 ]
  [[ "$output" == *"the charge is given more than once"* ]]
  no_refund
}

@test "the record swapped while the run is in flight -> REFUSED at the lock, nothing written" {
  record
  STUB_ACTIVE_SUBS=1 STUB_ON_LIST_EDIT="$DIR/rec.json" refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"was removed or changed while this run was in progress"* ]]
  no_refund
}

@test "the audit records the bytes that were verified, not whatever is at the path later" {
  record
  STUB_ACTIVE_SUBS=1 refund
  [ "$status" -eq 0 ]
  # the audit's copy of the record is the signed snapshot, and its hash is that copy
  [ "$(jq -rs '.[0].record.charge' "$AUDIT")" = "ch_A" ]
  [ "$(jq -rs '.[0].record_sha256' "$AUDIT")" = "$(sha256sum "$DIR/rec.json" | awk '{print $1}')" ]
}

# ---------------------------------------------------------------- the second switch
# qa-review 2026-11-15T14:49Z: "make disarmament enforceable rather than dependent on
# an operator not creating the directory". One directory is not a reviewed decision,
# so the class also has to be enabled in a repo file that names who approved it.

@test "registry disabled -> REFUSED even with an armed dir and a signed record" {
  record
  registry_armed_json "aaron" "test ruling" false
  refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"not enabled"* ]]
  no_refund
}

@test "registry enabled without approved_by/approval_ref -> REFUSED" {
  record
  registry_armed_json "" "" true
  refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"without approved_by and approval_ref"* ]]
  no_refund
}

@test "registry caps that disagree with the wrapper -> REFUSED" {
  record
  jq '.cap_usd_per_refund = 500' "$REGISTRY" >"$REGISTRY.tmp" && mv "$REGISTRY.tmp" "$REGISTRY"
  refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"disagree with this wrapper"* ]]
  no_refund
}

@test "registry missing -> REFUSED (an absent switch is not an approval)" {
  record
  rm -f "$REGISTRY"
  refund
  [ "$status" -eq 3 ]
  [[ "$output" == *"switch file is missing or unreadable"* ]]
  no_refund
}

@test "the committed registry is unarmed, and the guard says so" {
  run python3 "$REPO_ROOT/scripts/check-refund-machine-approval-automation.py"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unarmed"* ]]
}
