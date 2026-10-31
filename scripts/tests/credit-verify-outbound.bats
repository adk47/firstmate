#!/usr/bin/env bats
# credit-verify-outbound.sh: the 2-hourly outbound tick. Stubs stand in for the deployed builders, runner and health
# check; the tests pin the MODES (kill / dry-run / live / paid gate), the per-family steps and the auto-kill.

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export CVO_ETC="$TEST_TMPDIR/etc" CVO_STATE="$TEST_TMPDIR/state" CVO_OUT_ROOT="$TEST_TMPDIR/out"
  export HYDRA_ROOT="$TEST_TMPDIR/hydra" CVO_MAIN_ENV="$TEST_TMPDIR/none.env"
  mkdir -p "$CVO_ETC" "$HYDRA_ROOT/scripts/lib"
  export CALLS="$TEST_TMPDIR/calls.log"; : > "$CALLS"
  cat > "$TEST_TMPDIR/runner.py" <<'PY'
import json, os, sys
a = sys.argv[1:]
open(os.environ["CALLS"], "a").write(" ".join(a) + "\n")
mode = a[a.index("--mode") + 1]
if mode == "apply":
    open(os.environ["CALLS"] + ".env", "a").write(f"{os.environ.get('CREDIT_UVN_DAILY_MAX', '-')} {os.environ.get('CREDIT_STATUS_DAILY_MAX', '-')}\n")
if mode == "apply" and os.environ.get("STUB_RUNNER_CAP_MODEL"):
    # the real runner's own campaign cap: min(max_users, CREDIT_UVN_DAILY_MAX (default 400) - uvn-status rows today)
    import datetime, sqlite3
    day = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    used = sqlite3.connect(os.environ["CVO_LEDGER"]).execute(
        "SELECT count(*) FROM verify_messages WHERE campaign='uvn-status' AND day=?", (day,)).fetchone()[0]
    os.environ["STUB_SENT"] = str(max(0, min(int(a[a.index("--max-users") + 1]), int(os.environ.get("CREDIT_UVN_DAILY_MAX", "400")) - used)))
if "--outcomes-json" in a:
    p = a[a.index("--outcomes-json") + 1]
    n = int(os.environ.get("STUB_REFUSED", "0")) if mode == "apply" else 0
    json.dump({"mode": mode, "outcomes": [{"user": str(i), "result": "refused", "reason": "G5"} for i in range(n)]}, open(p, "w"))
if "--preview" in a and os.environ.get("STUB_PREVIEW_FAIL"):
    print("preview failed"); sys.exit(1)
if "--list" in a:
    _doc = json.load(open(a[a.index("--list") + 1]))
    ids = [str(u["user_id"]) for u in (_doc.get("users") or _doc.get("claims") or [])]
    open(os.environ["CALLS"] + ".lists", "a").write(os.path.basename(a[a.index("--list") + 1]) + " " + ",".join(ids) + "\n")
if "--preview" in a:
    d = a[a.index("--preview") + 1]
    open(os.path.join(d, "1.txt"), "w").write("DRY-RUN body\n")
    if os.environ.get("STUB_KILL_DURING"):
        open(os.environ["STUB_KILL_DURING"], "w").write("killed by a human mid-tick\n")
if mode == "apply" and os.environ.get("STUB_BREAK_LEDGER"):
    import sqlite3
    d = sqlite3.connect(os.environ["CVO_LEDGER"]); d.execute("DROP TABLE verify_messages"); d.commit()
elif mode == "apply" and os.environ.get("CVO_LEDGER"):
    import sqlite3
    d = sqlite3.connect(os.environ["CVO_LEDGER"])
    camp, day = "stub", "2000-01-01"
    if os.environ.get("STUB_REAL_ROWS"):   # rows of the real campaign today (cap-accounting tests)
        import datetime
        camp = a[a.index("--campaign") + 1] if "--campaign" in a else a[0]
        day = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    d.executemany("INSERT INTO verify_messages (campaign, day, status, account_id) VALUES (?, ?, ?, ?)",
                  [(camp, day, os.environ.get("STUB_ROW_STATUS", "sent"), str(70 + i)) for i in range(int(os.environ.get("STUB_ROWS", "2")))])
    d.commit()
if mode == "apply" and os.environ.get("STUB_CLAIM_PROSE"):
    print(f"CLAIM PROOF ASK (paid): sent {os.environ.get('STUB_SENT', '3')}, refused {os.environ.get('STUB_REFUSED', '0')}.")
else:
    print(f"UVN STATUS: {os.environ.get('STUB_SENT', '3')} sent." if mode == "apply" else "UVN STATUS (dry run): 3 would be messaged.")
PY
  cat > "$TEST_TMPDIR/owing.py" <<'PY'
import json, sys
json.dump({"users": [{"user_id": "1", "paid": True, "class": "uvn"}, {"user_id": "2", "paid": False, "class": "uvn"},
                     {"user_id": "8", "paid": True, "class": "review_hold"}, {"user_id": "9", "paid": False, "class": "account_hold"}]},
          open(sys.argv[sys.argv.index("--out") + 1], "w"))
print('{"counts": {}}')
PY
  cat > "$TEST_TMPDIR/receipts.py" <<'PY'
import json, os, sys
d = sys.argv[sys.argv.index("--out-dir") + 1]; os.makedirs(d, exist_ok=True)
json.dump({"users": [{"user_id": "3", "paid": True}]}, open(os.path.join(d, "receipts-received.json"), "w"))
print('{"counts": {}}')
PY
  cat > "$TEST_TMPDIR/health.py" <<'PY'
import os, sys
print('{"verdict": "%s"}' % ("healthy" if os.environ.get("STUB_HEALTH_RC", "0") == "0" else "unhealthy"))
sys.exit(int(os.environ.get("STUB_HEALTH_RC", "0")))
PY
  export CVO_RUNNER="$TEST_TMPDIR/runner.py" CVO_OWING="$TEST_TMPDIR/owing.py" CVO_RECEIPTS="$TEST_TMPDIR/receipts.py"
  export CVO_HEALTH="$TEST_TMPDIR/health.py"
  export CVO_POLICY="$BATS_TEST_DIRNAME/../../policies/credit-verify-outbound.json"
  export CVO_SCRIPTS="$BATS_TEST_DIRNAME/.."
  export CVO_LEDGER="$TEST_TMPDIR/ledger.sqlite3"
  python3 -c "import sqlite3,sys; d=sqlite3.connect(sys.argv[1]); d.execute('CREATE TABLE verify_messages (id INTEGER PRIMARY KEY AUTOINCREMENT, campaign TEXT, day TEXT, status TEXT, account_id TEXT)'); d.commit()" "$CVO_LEDGER"
  cat > "$TEST_TMPDIR/zero.py" <<'PY'
import os, sys
open(os.environ["CALLS"] + ".zero", "a").write(" ".join(sys.argv[1:]) + "\n")
print({"0": "OK", "1": "STOP: a credit email", "2": "UNMEASURED: loki unreadable"}[os.environ.get("STUB_ZERO_RC", "0")])
sys.exit(int(os.environ.get("STUB_ZERO_RC", "0")))
PY
  export CVO_ZERO_READ="$TEST_TMPDIR/zero.py"
  # the fraud re-check stub: STUB_FRAUD_HELD = comma ids the lens holds among the sent accounts; STUB_FRAUD_DOWN = lens unreadable
  cat > "$TEST_TMPDIR/fraud.py" <<'PY'
import os, sqlite3, sys
ledger, lo, hi = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
open(os.environ["CALLS"] + ".fraud", "a").write(f"{lo}-{hi}\n")
if os.environ.get("STUB_FRAUD_DOWN"):
    print("unreadable RuntimeError trino down"); sys.exit(0)
sent = {a for (a,) in sqlite3.connect(ledger).execute(
    "SELECT account_id FROM verify_messages WHERE id > ? AND id <= ? AND status IN ('sent','attempted')", (lo, hi))}
held = [h for h in os.environ.get("STUB_FRAUD_HELD", "").split(",") if h and h in sent]
print("hit " + ",".join(held) if held else "ok")
PY
  export CVO_FRAUD="$TEST_TMPDIR/fraud.py"
  export CVO_DOW=3   # a weekday unless a test says otherwise
  SCRIPT="$BATS_TEST_DIRNAME/../credit-verify-outbound.sh"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

applies() { grep -c -- "--mode apply" "$CALLS" || true; }

@test "outbound tick (r5 NO-GO @184803d6, [key=unattended]): outside the bats harness NO env var moves a gate input - kill files, state, ledger, policy, lens, spike, caps and gate scripts are constants" {
  E=/tmp/h2-evil
  evil=(HYDRA_ROOT="$E" CVO_ETC="$E/etc" CVO_STATE="$E/state" PY_BIN="$E/py" CVO_RUNNER="$E/r" CVO_OWING="$E/o" CVO_RECEIPTS="$E/rc"
        CVO_HEALTH="$E/h" CVO_ZERO_READ="$E/z" CVO_FRAUD="$E/f" CVO_MAIN_ENV="$E/env" CVO_LEDGER="$E/l.sqlite3" CVO_SCRIPTS="$E/s"
        CVO_RD_SCAN="$E/rd" CVO_RD_CAP=99999 CVO_POLICY="$E/p.json" CVO_CLAIM_LIST="$E/c.json" CVO_CAP=99999 CVO_R1_CAP=99999
        CVO_CLAIM_CAP=99999 CVO_REFUSAL_SPIKE=1.0 CVO_DOW=9)
  run -0 env -u BATS_TEST_TMPDIR "${evil[@]}" "$SCRIPT" --print-config
  [[ "$output" != *"$E"* ]]; [[ "$output" != *99999* ]]
  want="CVO_HARNESS=0
HYDRA_ROOT=/opt/hydra
KILL=/etc/hydra/credit-verify-outbound.disabled
KILL2=/var/lib/hydra/credit-verify-outbound/credit-verify-outbound.disabled
LIVE_FLAG=/etc/hydra/credit-verify-outbound.live
PAID_FLAG=/etc/hydra/credit-verify-outbound.paid-enabled
EXCLUDE=/etc/hydra/credit-verify-outbound.exclude
STATE=/var/lib/hydra/credit-verify-outbound
PY=python3
RUNNER=/opt/hydra/scripts/credit-review.py
OWING=/opt/hydra/scripts/credit_review/owing_proof.py
RECEIPTS=/opt/hydra/scripts/credit_review/receipts.py
HEALTH=/opt/hydra/scripts/paid-status/health_check.py
ZERO_READ=/opt/hydra/scripts/credit_verify/zero_read.py
FRAUD=
MAIN_ENV=/etc/openclaw/main.env
LEDGER=/var/lib/hydra/credit-review/ledger.sqlite3
SCRIPTS_DIR=/opt/hydra/scripts
RD_SCAN=/opt/hydra/scripts/credit_review/reply_due_scan.py
RD_CAP=100
POLICY=/opt/hydra/policies/credit-verify-outbound.json
CLAIM_LIST=/var/lib/hydra/credit-verify-outbound/claim-list.json
CAP=250
R1_CAP=250
CLAIM_CAP=250
DOW=$(date -u +%u)
REFUSAL_SPIKE=0.20"
  [ "$output" = "$want" ]
  # a BATS_TEST_TMPDIR that is not a directory is not the harness either
  run -0 env BATS_TEST_TMPDIR=/nonexistent/x "${evil[@]}" "$SCRIPT" --print-config
  [ "$output" = "$want" ]
  # under the harness (bats sets BATS_TEST_TMPDIR) the test values are the seam
  run -0 "$SCRIPT" --print-config
  [[ "$output" == *"CVO_HARNESS=1"* ]]; [[ "$output" == *"KILL=$CVO_ETC/credit-verify-outbound.disabled"* ]]
  [[ "$output" == *"LEDGER=$CVO_LEDGER"* ]]
}

@test "outbound tick: the kill file stops everything - no builder, no runner" {
  touch "$CVO_ETC/credit-verify-outbound.disabled"
  run -0 "$SCRIPT"
  [[ "$output" == *"kill file"*"nothing runs"* ]]
  [ ! -s "$CALLS" ]
}

@test "outbound tick: DRY-RUN by default - every family is checked read-only (C11) with outcomes + 5 bodies, nothing applied" {
  run -0 "$SCRIPT"
  [ "$(applies)" -eq 0 ]
  grep -q -- "--campaign uvn-status .*--mode dry-run --max-users 250 --check-recipients --outcomes-json" "$CALLS"
  grep -q -- "--campaign status-doc-received --wording received .*--check-recipients" "$CALLS"
  grep -q -- "--max-users 5 --preview" "$CALLS"
  out="$(ls -d "$CVO_OUT_ROOT"/*)"
  [ -s "$out/uvn-status-paid-check.json" ] && [ -s "$out/uvn-status-paid-bodies/1.txt" ]
  grep -q "DRY-RUN tick (no send)" "$out/tick.log"
  # the families not deployed on this tree are logged, never silently missing
  grep -q "reply_due: no deployed audience builder" "$out/tick.log"
  if grep -q -- "reply-due" "$CALLS"; then false; fi
}

@test "outbound tick: LIVE applies the FREE segments only; paid needs its own flag (p1: paid after one clean free day)" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  run -0 "$SCRIPT"
  [ "$(grep -c -- "--segment free .*--mode apply" "$CALLS")" -eq 2 ]
  if grep -q -- "--segment paid .*--mode apply" "$CALLS"; then false; fi
  : > "$CALLS"; touch "$CVO_ETC/credit-verify-outbound.paid-enabled"
  run -0 "$SCRIPT"
  [ "$(grep -c -- "--segment paid .*--mode apply" "$CALLS")" -eq 2 ]
  grep -q -- "--campaign uvn-status .*--mode apply --max-users 250" "$CALLS"
  grep -q -- "--campaign status-doc-received --wording received .*--mode apply --max-users 250" "$CALLS"
}

@test "outbound tick: a failed health read after an apply writes the kill file and stops the tick" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  STUB_HEALTH_RC=3 run -1 "$SCRIPT"
  [ -e "$CVO_ETC/credit-verify-outbound.disabled" ]
  grep -q "health check rc=3" "$CVO_ETC/credit-verify-outbound.disabled"
  [ "$(applies)" -eq 1 ]                                   # the first free apply, then nothing more
  # and the next tick does nothing at all
  : > "$CALLS"; run -0 "$SCRIPT"; [ ! -s "$CALLS" ]
}

@test "outbound tick: a kill file written mid-tick (between the check and the apply) stops before any send" {
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"   # the FIRST family is live
  STUB_KILL_DURING="$CVO_ETC/credit-verify-outbound.disabled" run -1 "$SCRIPT"
  [ "$(applies)" -eq 0 ]
}

@test "outbound tick: a refusal spike (> 20% of attempts refused in one apply) writes the kill file" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  STUB_ROWS=5 STUB_REFUSED=5 run -1 "$SCRIPT"
  grep -q "refusal spike" "$CVO_ETC/credit-verify-outbound.disabled"
  rm -f "$CVO_ETC/credit-verify-outbound.disabled"; : > "$CALLS"
  # below the floor of 10 attempts, or under the ratio: no kill
  STUB_ROWS=20 STUB_REFUSED=2 run -0 "$SCRIPT"
  [ ! -e "$CVO_ETC/credit-verify-outbound.disabled" ]
}

@test "outbound tick (QA #1541): the spike counts the LEDGER's sends, never a runner's prose - a claim-style 'sent N' line with 10 refusals under 20% does not kill" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  # 150 sent (ledger rows) + 10 refused = 6.25%: healthy. The old grep read 0 from 'sent 150' -> 10/10 -> permanent kill.
  STUB_CLAIM_PROSE=1 STUB_SENT=150 STUB_ROWS=150 STUB_REFUSED=10 run -0 "$SCRIPT"
  [ ! -e "$CVO_ETC/credit-verify-outbound.disabled" ]
  # and the prose can say anything: 0 printed, 5 real sends + 5 refused (50%, 10 attempts) still kills
  STUB_CLAIM_PROSE=1 STUB_SENT=0 STUB_ROWS=5 STUB_REFUSED=5 run -1 "$SCRIPT"
  grep -q "refusal spike" "$CVO_ETC/credit-verify-outbound.disabled"
}

@test "outbound tick: the exclude file rides every runner call; one tick at a time" {
  printf '91\n' > "$CVO_ETC/credit-verify-outbound.exclude"
  run -0 "$SCRIPT"
  [ "$(grep -c -- "--exclude-users $CVO_ETC/credit-verify-outbound.exclude" "$CALLS")" -eq "$(wc -l < "$CALLS" | tr -d ' ')" ]
  mkdir -p "$CVO_STATE"; exec 8>"$CVO_STATE/tick.lock"; flock -n 8
  : > "$CALLS"; run -0 "$SCRIPT"
  [[ "$output" == *"another tick holds"* ]]
  [ ! -s "$CALLS" ]
}

@test "outbound tick (r5 #1541): the uvn-status family gets the UVN class only - hold classes are never in its list" {
  run -0 "$SCRIPT"
  grep -q "^owing-uvn.json 1,2$" "$CALLS.lists"
  if grep -qE "^owing(-uvn)?\.json .*\b(8|9)\b" "$CALLS.lists"; then false; fi
  grep -q "owing classes:.*review_hold" "$CVO_OUT_ROOT"/*/tick.log
}

@test "outbound tick (r5 #1541): a failed body sample stops the tick before any apply" {
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"
  STUB_PREVIEW_FAIL=1 run -1 "$SCRIPT"
  [ "$(applies)" -eq 0 ]
  grep -q "body sample failed; no apply" "$CVO_OUT_ROOT"/*/tick.log
}

@test "outbound tick (r5 / QA #1541): the per-UTC-day segment cap from the RUNNER's segment record - at cap 0 applies, below it the remainder, and the runner gets the cap to enforce under its lock" {
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"
  # small caps pin the arithmetic (the shipped policy carries the capacity caps; see the policy test below)
  cat > "$TEST_TMPDIR/policy.json" <<'J'
{"daily_cap": {"uvn-status": {"paid": 100, "free": 250}, "status-doc-received": {"paid": 100, "free": 250},
               "claim-status": {"paid": 500, "free": 500}, "claim-proof-ask": {"paid": 500, "free": 500}},
 "groups": {"credit": ["uvn-status", "status-doc-received"], "claim": ["claim-status", "claim-proof-ask"]},
 "shared_daily_cap": {"credit": 100000, "claim": 500}}
J
  export CVO_POLICY="$TEST_TMPDIR/policy.json"
  today="$(date -u +%F)"
  # the runner's own record (the list's paid flag at send time): free uvn at its 250 cap, 1 paid
  python3 - "$CVO_LEDGER.segments.jsonl" "$today" <<'PY'
import json, sys
with open(sys.argv[1], "w") as f:
    for i in range(250):
        f.write(json.dumps({"day": sys.argv[2], "campaign": "uvn-status", "segment": "free", "user": str(1000 + i), "n": 1}) + "\n")
    f.write(json.dumps({"day": sys.argv[2], "campaign": "uvn-status", "segment": "paid", "user": "500", "n": 1}) + "\n")
    f.write(json.dumps({"day": "2000-01-01", "campaign": "uvn-status", "segment": "paid", "user": "9", "n": 50}) + "\n")   # another day
PY
  run -0 "$SCRIPT"
  if grep -q -- "--segment free --campaign uvn-status .*--mode apply" "$CALLS"; then false; fi      # free uvn at its 250 cap
  grep -q -- "--segment paid --campaign uvn-status .*--mode apply --max-users 99 --segment-daily-cap 100" "$CALLS"   # 100 - 1
  grep -q "daily cap reached for uvn-status/free" "$CVO_OUT_ROOT"/*/tick.log
  # QA #1541: an unreadable policy = no apply anywhere AND a stop + kill file (never a silent "cap reached")
  : > "$CALLS"; CVO_POLICY="$TEST_TMPDIR/missing.json" run -1 "$SCRIPT"
  [ "$(applies)" -eq 0 ]
  grep -q "cap source unreadable" "$CVO_ETC/credit-verify-outbound.disabled"
  if grep -q "daily cap reached .*unreadable" "$CVO_OUT_ROOT"/*/tick.log; then false; fi
}

@test "outbound tick (p1 / n1 #1545): the zero-read runs over exactly each apply's new ledger rows; STOP or UNMEASURED kills" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  run -0 "$SCRIPT"
  [ "$(wc -l < "$CALLS.zero" | tr -d ' ')" -eq 2 ]                 # the two free applies
  grep -q -- "--ledger-ids 1-2" "$CALLS.zero"; grep -q -- "--ledger-ids 3-4" "$CALLS.zero"
  for rc in 1 2; do
    rm -f "$CVO_ETC/credit-verify-outbound.disabled" "$CALLS.zero"
    STUB_ZERO_RC=$rc run -1 "$SCRIPT"
    grep -q "zero-read $([ $rc = 1 ] && echo STOP || echo UNMEASURED)" "$CVO_ETC/credit-verify-outbound.disabled"
  done
  # QA #1541: an apply whose rows are only ATTEMPTED (delivery unknown) is read too - never skipped
  rm -f "$CVO_ETC/credit-verify-outbound.disabled" "$CALLS.zero"
  STUB_ROW_STATUS=attempted run -0 "$SCRIPT"
  [ -e "$CALLS.zero" ]
  # an apply that wrote only rejected rows has nothing to read: no zero-read, no false kill
  rm -f "$CVO_ETC/credit-verify-outbound.disabled" "$CALLS.zero"
  STUB_ROW_STATUS=rejected run -0 "$SCRIPT"
  [ ! -e "$CALLS.zero" ]; [ ! -e "$CVO_ETC/credit-verify-outbound.disabled" ]
  # QA #1541: the reader not deployed = no live send at all (the tick runs DRY and says so), never a send that kills
  : > "$CALLS"
  CVO_ZERO_READ="$TEST_TMPDIR/missing.py" run -0 "$SCRIPT"
  [ "$(applies)" -eq 0 ]; [ ! -e "$CVO_ETC/credit-verify-outbound.disabled" ]
  grep -q "LIVE REFUSED: the zero-read reader" "$CVO_OUT_ROOT"/*/tick.log
}

@test "outbound tick (QA #1541): a ledger read that fails AFTER an apply kills - never an empty -1 range that skips the zero-read" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  # the stub runner drops the ledger table during its apply: the after-apply read fails
  STUB_BREAK_LEDGER=1 run -1 "$SCRIPT"
  grep -q "ledger unreadable after the apply" "$CVO_ETC/credit-verify-outbound.disabled"
}

@test "outbound tick (QA #1541): a kill file that cannot be written to /etc/hydra lands in the durable fallback, and the next tick honours it; no writable location = the tick never starts" {
  # QA @3b6a8a04: chmod 555 does not stop root, so the unwritable locations here fail for ANY user, root included.
  touch "$CVO_ETC/credit-verify-outbound.live"
  # (1) the primary kill file is a DANGLING symlink into a missing directory: it does not read as a kill file
  #     ([ -e ] is false), and writing it fails even as root (the target's directory does not exist)
  ln -s "$TEST_TMPDIR/no-such-dir/kill" "$CVO_ETC/credit-verify-outbound.disabled"
  STUB_HEALTH_RC=3 run -1 "$SCRIPT"
  [ ! -e "$TEST_TMPDIR/no-such-dir/kill" ]
  grep -q "health check rc=3" "$CVO_STATE/credit-verify-outbound.disabled"
  grep -q "wrote $CVO_STATE/credit-verify-outbound.disabled" "$CVO_OUT_ROOT"/*/tick.log
  : > "$CALLS"
  run -0 "$SCRIPT"
  [[ "$output" == *"nothing runs"* ]]; [ ! -s "$CALLS" ]
  # (2) neither location writable: both sit under a REGULAR FILE, which no user can create a directory or file in
  : > "$TEST_TMPDIR/plainfile"
  CVO_ETC="$TEST_TMPDIR/plainfile/etc" CVO_STATE="$TEST_TMPDIR/plainfile/state" run "$SCRIPT"
  [ "$status" -eq 2 ]; [[ "$output" == *"neither"*"writable for a kill file"* ]]; [ ! -s "$CALLS" ]
  # (3) both kill-file writes failing mid-tick: the tick stops (exit 3) and says a human must stop the timer
  rm -f "$CVO_STATE/credit-verify-outbound.disabled"
  ln -s "$TEST_TMPDIR/no-such-dir/kill2" "$CVO_STATE/credit-verify-outbound.disabled"
  STUB_HEALTH_RC=3 run "$SCRIPT"
  [ "$status" -eq 3 ]
  grep -q "BOTH kill-file writes FAILED" "$CVO_OUT_ROOT"/*/tick.log
}

@test "outbound tick (Fable 10-30): a FRAUD HIT - an account this apply sent to is held by the lens - writes the kill file; an unreadable lens kills too" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  STUB_FRAUD_HELD=71 run -1 "$SCRIPT"
  grep -q "FRAUD hit 71" "$CVO_ETC/credit-verify-outbound.disabled"
  [ "$(applies)" -eq 1 ]; [ ! -e "$CALLS.zero" ]               # stopped before the zero-read and the next family
  rm -f "$CVO_ETC/credit-verify-outbound.disabled"; : > "$CALLS"
  STUB_FRAUD_DOWN=1 run -1 "$SCRIPT"
  grep -q "FRAUD unreadable" "$CVO_ETC/credit-verify-outbound.disabled"
  # a held user the lens refused BEFORE the send never received anything: not a hit, no kill
  rm -f "$CVO_ETC/credit-verify-outbound.disabled"; : > "$CALLS"
  STUB_FRAUD_HELD=999 run -0 "$SCRIPT"
  [ ! -e "$CVO_ETC/credit-verify-outbound.disabled" ]
  [ "$(wc -l < "$CALLS.fraud" | tr -d ' ')" -ge 2 ]
}

@test "outbound tick (Fable 10-30): health is judged at 2 % bounce / unsub / spam, and every send leaves a v1 sample pointer" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  cat > "$TEST_TMPDIR/health.py" <<'PY'
import os, sys
open(os.environ["CALLS"] + ".health", "a").write(" ".join(sys.argv[1:]) + "\n")
print('{"verdict": "healthy"}')
PY
  run -0 "$SCRIPT"
  grep -q -- "--bounce-max-pct 2 --unsub-max-pct 2 --spam-max-pct 2" "$CALLS.health"
  [ "$(wc -l < "$CVO_STATE/samples.jsonl" | tr -d ' ')" -eq 2 ]
  grep -q '"family":"uvn-status-free","ledger_ids":"1-2"' "$CVO_STATE/samples.jsonl"
}

@test "outbound tick (Fable 10-30): the shipped policy carries CAPACITY caps under m2's shared caps (credit 2,500 / claim 500)" {
  python3 - "$BATS_TEST_DIRNAME/../../policies/credit-verify-outbound.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["shared_daily_cap"] == {"credit": 2500, "claim": 500}, p["shared_daily_cap"]
for c, segs in p["daily_cap"].items():
    g = next(g for g, cs in p["groups"].items() if c in cs)
    assert all(v <= p["shared_daily_cap"][g] for v in segs.values()), c
assert min(p["daily_cap"]["uvn-status"].values()) >= 250   # no small fixed cap any more
PY
}

@test "outbound tick (Fable 10-30): the SHARED group cap - credit rows already sent today use up the credit room; claims have their own 500" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  today="$(date -u +%F)"
  cat > "$TEST_TMPDIR/policy.json" <<'J'
{"daily_cap": {"uvn-status": {"paid": 2500, "free": 2500}, "status-doc-received": {"paid": 2500, "free": 2500},
               "claim-status": {"paid": 500, "free": 500}, "claim-proof-ask": {"paid": 500, "free": 500}},
 "groups": {"credit": ["uvn-status", "status-doc-received"], "claim": ["claim-status", "claim-proof-ask"]},
 "shared_daily_cap": {"credit": 10, "claim": 4}}
J
  export CVO_POLICY="$TEST_TMPDIR/policy.json"
  python3 -c "import sqlite3,sys; d=sqlite3.connect(sys.argv[1]); d.executemany(\"INSERT INTO verify_messages (campaign, day, status, account_id) VALUES (?, ?, 'sent', '5')\", [('status-doc-received', sys.argv[2])]*8 + [('claim-status', sys.argv[2])]*3); d.commit()" "$CVO_LEDGER" "$today"
  printf '{"generated_at": "x", "claims": [{"claim_id": 1, "user_id": 5}]}' > "$CVO_STATE.claims.json"
  CVO_CLAIM_LIST="$CVO_STATE.claims.json" run -0 "$SCRIPT"
  grep -q -- "--segment free --campaign uvn-status .*--mode apply --max-users 2 " "$CALLS"   # 10 - 8 credit rows
  grep -q -- "^claim-proof-ask .*--segment free .*--mode apply --max-users 1" "$CALLS"        # 4 - 3 claim rows
}

@test "outbound tick (Fable 10-30): the claim families run from the claim lane's list, FIRST on Sat/Sun, after credit on weekdays; no list = skipped" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  printf '{"generated_at": "x", "claims": [{"claim_id": 1, "user_id": 5}]}' > "$CVO_STATE.claims.json"
  export CVO_CLAIM_LIST="$CVO_STATE.claims.json"
  run -0 "$SCRIPT"
  grep -q -- "^claim-proof-ask --list .*/claims-filtered.json --segment free .*--mode apply --max-users 250" "$CALLS"
  grep -q -- "^claim-status --list .*/claims-filtered.json --segment free .*--mode apply" "$CALLS"
  if grep -q -- "^claim-.*--exclude-users" "$CALLS"; then false; fi
  first="$(grep -m1 -- "--mode apply" "$CALLS" | cut -d' ' -f1)"; [ "$first" = "uvn-status" ]
  : > "$CALLS"; rm -f "$CVO_LEDGER.segments.jsonl"
  CVO_DOW=6 run -0 "$SCRIPT"
  first="$(grep -m1 -- "--mode apply" "$CALLS" | cut -d' ' -f1)"; [ "$first" = "claim-proof-ask" ]
  grep -q "weekend: claim families first" "$CVO_OUT_ROOT"/*/tick.log
  : > "$CALLS"; rm -f "$CVO_CLAIM_LIST"
  run -0 "$SCRIPT"
  if grep -q "^claim-" "$CALLS"; then false; fi
  grep -q "claim families: no claim list" "$CVO_OUT_ROOT"/*/tick.log
}

@test "outbound tick (QA #1541): an unreadable LEDGER for the cap read stops the tick with the kill file, not a silent stall" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  # a ledger path that cannot be opened at all (a directory): verify_ledger.connect would re-create a dropped table
  mkdir -p "$TEST_TMPDIR/ledger-is-a-dir"
  CVO_LEDGER="$TEST_TMPDIR/ledger-is-a-dir" run -1 "$SCRIPT"
  [ "$(applies)" -eq 0 ]
  grep -q "cap source unreadable" "$CVO_ETC/credit-verify-outbound.disabled"
}

@test "outbound tick (QA #1541): a v1 sample pointer that cannot be written after a send kills the tick before the next family" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  mkdir -p "$CVO_STATE/samples.jsonl"          # a DIRECTORY where the file goes: the append fails for any user, root too
  run -1 "$SCRIPT"
  [ "$(applies)" -eq 1 ]
  grep -q "sample pointer for ledger 1-2 could not be written" "$CVO_ETC/credit-verify-outbound.disabled"
}

@test "outbound tick (QA #1541): the exclude file holds claimants out of the claim families too; an unreadable claim list kills" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  printf '5\n' > "$CVO_ETC/credit-verify-outbound.exclude"
  printf '{"generated_at": "x", "claims": [{"claim_id": 1, "user_id": 5}, {"claim_id": 2, "user_id": 6}]}' > "$CVO_STATE.claims.json"
  CVO_CLAIM_LIST="$CVO_STATE.claims.json" run -0 "$SCRIPT"
  grep -q "^claims-filtered.json 6$" "$CALLS.lists"
  if grep -qE "^claims(-filtered)?\.json .*\b5\b" "$CALLS.lists"; then false; fi
  if grep -q -- "--list $CVO_STATE.claims.json" "$CALLS"; then false; fi      # the raw list never reaches a runner
  grep -q "1 held out by the exclude file" "$CVO_OUT_ROOT"/*/tick.log
  rm -f "$CVO_ETC/credit-verify-outbound.disabled"; : > "$CALLS"
  printf 'not json' > "$CVO_STATE.claims.json"
  CVO_CLAIM_LIST="$CVO_STATE.claims.json" run -1 "$SCRIPT"
  grep -q "claim list or the exclude file is unreadable" "$CVO_ETC/credit-verify-outbound.disabled"
  if grep -q "^claim-" "$CALLS"; then false; fi
}

@test "outbound tick (h2 / firstmate 031): the reply_due family runs FIRST from the deployed scan, on the uvn-status runner, paid then free" {
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"
  cat > "$TEST_TMPDIR/rd_scan.py" <<'PY'
import json, sys
json.dump({"generated_at": "x", "users": [{"user_id": "41", "paid": True, "reply_due": {"part": "9", "conversation": "7"}}]},
          open(sys.argv[sys.argv.index("--out") + 1], "w"))
print('{"rows": 1}')
PY
  CVO_RD_SCAN="$TEST_TMPDIR/rd_scan.py" run -0 "$SCRIPT"
  first="$(grep -m1 -- "--mode apply" "$CALLS")"
  [[ "$first" == *"reply-due.json --segment paid --campaign uvn-status"*"--max-users 100"* ]]
  grep -q -- "reply-due.json --segment free --campaign uvn-status .*--mode apply" "$CALLS"
  grep -q "audiences: reply_due" "$CVO_OUT_ROOT"/*/tick.log
  grep -q "^reply-due.json 41$" "$CALLS.lists"
  # a deployed scan that fails stops the tick before any send
  : > "$CALLS"; printf 'import sys; sys.exit(3)\n' > "$TEST_TMPDIR/rd_scan.py"
  CVO_RD_SCAN="$TEST_TMPDIR/rd_scan.py" run -1 "$SCRIPT"
  [ "$(applies)" -eq 0 ]
  grep -q "reply_due builder failed" "$CVO_OUT_ROOT"/*/tick.log
}

@test "outbound tick (firstmate 031 cap accounting): reply_due answers charge the SAME uvn-status daily row and the shared credit cap" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  cat > "$TEST_TMPDIR/policy.json" <<'J'
{"daily_cap": {"uvn-status": {"paid": 2500, "free": 3}, "status-doc-received": {"paid": 2500, "free": 2500},
               "claim-status": {"paid": 500, "free": 500}, "claim-proof-ask": {"paid": 500, "free": 500}},
 "groups": {"credit": ["uvn-status", "status-doc-received"], "claim": ["claim-status", "claim-proof-ask"]},
 "shared_daily_cap": {"credit": 2500, "claim": 500}}
J
  export CVO_POLICY="$TEST_TMPDIR/policy.json"
  cat > "$TEST_TMPDIR/rd_scan.py" <<'PY'
import json, sys
json.dump({"generated_at": "x", "users": [{"user_id": "41", "paid": False}]}, open(sys.argv[sys.argv.index("--out") + 1], "w"))
PY
  # the reply-due free apply writes 2 uvn-status rows today: the uvn-status free family then has 3 - 2 = 1 left
  CVO_RD_SCAN="$TEST_TMPDIR/rd_scan.py" STUB_REAL_ROWS=1 run -0 "$SCRIPT"
  grep -q -- "reply-due.json --segment free --campaign uvn-status .*--mode apply --max-users 3 " "$CALLS"
  grep -q -- "owing-uvn.json --segment free --campaign uvn-status .*--mode apply --max-users 1 " "$CALLS"
}

@test "outbound tick (QA #1541 uvn_status.py:869): the runner's own campaign cap follows the policy - no multi-tick stall at 400" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  today="$(date -u +%F)"
  # 400 uvn-status sends already today (earlier ticks): the runner's DEFAULT cap would be exhausted
  python3 -c "import sqlite3,sys; d=sqlite3.connect(sys.argv[1]); d.executemany(\"INSERT INTO verify_messages (campaign, day, status, account_id) VALUES ('uvn-status', ?, 'sent', '5')\", [(sys.argv[2],)]*400); d.commit()" "$CVO_LEDGER" "$today"
  STUB_RUNNER_CAP_MODEL=1 run -0 "$SCRIPT"
  # every apply hands the runner the policy's shared credit cap (2,500), so the 401st message of the day still goes
  [ "$(sort -u "$CALLS.env")" = "2500 2500" ]
  grep -q "uvn-status-free APPLY (rc=0): UVN STATUS: 250 sent" "$CVO_OUT_ROOT"/*/tick.log
}
