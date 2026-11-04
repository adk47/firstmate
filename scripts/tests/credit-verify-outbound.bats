#!/usr/bin/env bats
# credit-verify-outbound.sh: the 2-hourly outbound tick. Stubs stand in for the deployed builders, runner and health
# check; the tests pin the MODES (kill / dry-run / live / paid gate), the per-family steps and the auto-kill.

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export CVO_ETC="$TEST_TMPDIR/etc" CVO_STATE="$TEST_TMPDIR/state" CVO_OUT_ROOT="$TEST_TMPDIR/out"
  export HYDRA_ROOT="$TEST_TMPDIR/hydra" CVO_MAIN_ENV="$TEST_TMPDIR/none.env"
  mkdir -p "$CVO_ETC" "$HYDRA_ROOT/scripts/lib"
  cat > "$HYDRA_ROOT/scripts/lib/slack-notify.sh" <<'SH'
slack_notify_critical() { printf '%s\n' "$*" >> "$CALLS.page"; return ${STUB_SLACK_RC:-0}; }
SH
  export CALLS="$TEST_TMPDIR/calls.log"; : > "$CALLS"
  export CVO_TICK_HARD_S=999999 CVO_CHECK_S_PER_USER=0 CVO_RESERVE_PAD_S=0   # the deadline rails have their own tests
  export CVO_TIMEOUT_BIN="$(command -v timeout)"
  cat > "$TEST_TMPDIR/runner.py" <<'PY'
import json, os, sys
a = sys.argv[1:]
open(os.environ["CALLS"], "a").write(" ".join(a) + "\n")
mode = a[a.index("--mode") + 1]
if os.environ.get("STUB_SLEEP") and mode == os.environ.get("STUB_SLEEP_MODE") and (mode == "apply" or "--check-recipients" in a):
    import time; time.sleep(float(os.environ["STUB_SLEEP"]))
if mode == "apply":
    open(os.environ["CALLS"] + ".env", "a").write(f"{os.environ.get('CREDIT_UVN_DAILY_MAX', '-')} {os.environ.get('CREDIT_STATUS_DAILY_MAX', '-')}\n")
if mode == "apply" and os.environ.get("STUB_RUNNER_CAP_MODEL"):
    # the real runner's own campaign cap: min(max_users, the POLICY file's shared credit cap - uvn-status rows today)
    import datetime, sqlite3
    day = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    used = sqlite3.connect(os.environ["CVO_LEDGER"]).execute(
        "SELECT count(*) FROM verify_messages WHERE campaign='uvn-status' AND day=?", (day,)).fetchone()[0]
    cap = json.load(open(os.environ["CVO_POLICY"]))["shared_daily_cap"]["credit"]
    os.environ["STUB_SENT"] = str(max(0, min(int(a[a.index("--max-users") + 1]), int(cap) - used)))
if "--outcomes-json" in a and mode == "apply" and os.environ.get("STUB_ARTEFACT_JUNK"):
    open(a[a.index("--outcomes-json") + 1], "w").write("{not json")
elif "--outcomes-json" in a and mode == "apply" and os.environ.get("STUB_NO_ARTEFACT"):
    # the 15:05Z shape in production: the apply SENT, then died inside the Intercom note with TimeoutExpired, so it
    # returned rc=1 and NEVER WROTE this file. The ledger still carries the sends.
    pass
elif "--outcomes-json" in a:
    p = a[a.index("--outcomes-json") + 1]
    n = int(os.environ.get("STUB_REFUSED", "0")) if mode == "apply" else 0
    doc = {"mode": mode, "outcomes": [{"user": str(i), "result": "refused", "reason": "G5"} for i in range(n)]}
    if "--start-entry" in a:                                         # the uvn runner's page record (QA #1612)
        st, me = int(a[a.index("--start-entry") + 1]), int(a[a.index("--max-entries") + 1])
        listed = int(os.environ.get("STUB_LISTED", "450"))
        doc["page"] = {"start": st, "end": int((os.environ.get("STUB_APPLY_PAGE_END") if mode == "apply" else "") or os.environ.get("STUB_PAGE_END") or min(listed, st + me)), "listed": listed}
    if mode != "apply" and not os.environ.get("STUB_NO_ACCEPTED"):     # the runner's accepted set (#1600)
        doc["accepted"] = [{"user": u} for u in os.environ.get("STUB_ACCEPTED", "1").split(",") if u]
    json.dump(doc, open(p, "w"))
if "--preview" in a and os.environ.get("STUB_PREVIEW_FAIL"):
    print("preview failed"); sys.exit(1)
if "--list" in a:
    _doc = json.load(open(a[a.index("--list") + 1]))
    ids = [str(u["user_id"]) for u in (_doc.get("users") or _doc.get("claims") or [])]
    open(os.environ["CALLS"] + ".lists", "a").write(os.path.basename(a[a.index("--list") + 1]) + " " + ",".join(ids) + "\n")
if "--preview" in a:
    d = a[a.index("--preview") + 1]
    for u in os.environ.get("STUB_PREVIEW_USERS", "1").split(","):
        open(os.path.join(d, f"{u}.txt"), "w").write('DRY-RUN uvn-status initial email credits=1 copy=uvn\n{"body": "<p>Hi there</p>"}\n')
        json.dump({"class": "ask", "owes_proof": True, "distinct_tracks": 1, "source": "renderer"}, open(os.path.join(d, f"{u}.facts.json"), "w"))
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
if mode == "apply" and os.environ.get("STUB_APPLY_RC"):
    sys.exit(int(os.environ["STUB_APPLY_RC"]))   # rows were written above; the run then FAILS (a partial send)
PY
  cat > "$TEST_TMPDIR/owing.py" <<'PY'
import os as _o, time as _t
if _o.environ.get("STUB_OWING_SLEEP"): _t.sleep(float(_o.environ["STUB_OWING_SLEEP"]))
import json, sys
open(_o.environ["CALLS"] + ".owing", "a").write(" ".join(sys.argv[1:]) + "\n")
users = [{"user_id": "1", "paid": True, "class": "uvn"}, {"user_id": "2", "paid": False, "class": "uvn"},
         {"user_id": "8", "paid": True, "class": "review_hold"}, {"user_id": "9", "paid": False, "class": "account_hold"}]
json.dump({"users": users}, open(sys.argv[sys.argv.index("--out") + 1], "w"))
for i, a in enumerate(sys.argv):                        # the builder writes the one-class list itself (r5 776)
    if a == "--class-out" and not _o.environ.get("STUB_NO_CLASS_OUT"):
        cls, _, path = sys.argv[i + 1].partition("=")
        json.dump({"users": [u for u in users if u["class"] == cls], "split_of": {"class": cls}}, open(path, "w"))
print('{"counts": {}, "classes": {"uvn": 2, "review_hold": 1, "account_hold": 1}}')
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
  export CVO_DEPLOYED_SHA="$TEST_TMPDIR/deployed-sha"
  DEP="$(printf 'd%.0s' $(seq 40))"            # a deployed head (the claim lists below are signed on it)
  export CVO_HEALTH="$TEST_TMPDIR/health.py"
  # proof-need-ask (E): build writes the audience; send is the same stub runner
  cat > "$TEST_TMPDIR/need.py" <<'PY'
import json, os, subprocess, sys
# this stub speaks #1582's CLI: "--check-recipients" / --outcomes-json (the tick checks the deployed runner for it)
a = sys.argv[1:]
if a and a[0] == "build":
    open(os.environ["CALLS"] + ".need", "a").write("need-build\n")
    if os.environ.get("STUB_NEED_BUILD_FAIL"):
        print("need build failed"); sys.exit(1)
    users = [{"user_id": "5", "paid": True, "asks": []}, {"user_id": "7", "paid": True, "asks": []},
             {"user_id": "6", "paid": False, "asks": []}] if os.environ.get("STUB_NEED_USERS") else []
    json.dump({"users": users}, open(a[a.index("--out") + 1], "w"))
    print('{"counts": {}}'); sys.exit(0)
sys.exit(subprocess.run([sys.executable, os.environ["CVO_RUNNER"], *a]).returncode)
PY
  export CVO_NEED_RUNNER="$TEST_TMPDIR/need.py" CVO_UNSIGNED_ALL=1
  export CVO_POLICY="$BATS_TEST_DIRNAME/../../policies/credit-verify-outbound.json"
  export CVO_SCRIPTS="$BATS_TEST_DIRNAME/.."
  export CVO_LEDGER="$TEST_TMPDIR/ledger.sqlite3"
  python3 -c "import sqlite3,sys; d=sqlite3.connect(sys.argv[1]); d.execute('CREATE TABLE verify_messages (id INTEGER PRIMARY KEY AUTOINCREMENT, campaign TEXT, day TEXT, status TEXT, account_id TEXT)'); d.commit()" "$CVO_LEDGER"
  cat > "$TEST_TMPDIR/zero.py" <<'PY'
import os, sys
log = os.environ["CALLS"] + ".zero"
open(log, "a").write(" ".join(sys.argv[1:]) + "\n")
n = len([l for l in open(log).readlines() if l.strip()])          # 1-based call number
rc = os.environ.get("STUB_ZERO_RC", "0")
if os.environ.get("STUB_ZERO_RC_ONCE") and n > 1:
    rc = "0"                                                       # only the FIRST read is unmeasured
if os.environ.get("STUB_ZERO_CRASH"):
    # a READER CRASH: the last line is not a verdict, and the exit code is 1 - which the tick reads as STOP
    print("Traceback (most recent call last):")
    print("subprocess.TimeoutExpired: Command '['trino']' timed out after 900 seconds")
    sys.exit(1)
if rc == "3":
    # the COMBINED verdict (#1747): a confirmed stop AND a source that was never read, in one batch. exit 1.
    print("STOP+UNMEASURED: a credit email in the batch | unmeasured: loki unreadable")
    sys.exit(1)
print({"0": "OK", "1": "STOP: a credit email", "2": "UNMEASURED: loki unreadable"}[rc])
sys.exit(int(rc))
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

# OUT_ROOT is keyed by STAMP="$(date -u +%Y%m%dT%H%MZ)" - MINUTE resolution (credit-verify-outbound.sh:149) - and a
# case may invoke the script more than once, so a minute boundary leaves TWO out dirs. Every read of "the run I just
# made" goes through these helpers: a bare "$CVO_OUT_ROOT"/*/tick.log grep matches ANY run's log, so on a minute
# split it can pass on the PREVIOUS run's output - that is a false green, not a flake (r5 on #1687; the first site,
# the uvn-status-free outcomes glob, produced AssertionError None on #1406's Bats (1/2)).
newest_out() { ls -dt "$CVO_OUT_ROOT"/*/ 2>/dev/null | head -1; }
newest_tick() { printf '%s' "$(newest_out)tick.log"; }
@test "outbound tick (r5 NO-GO @184803d6, [key=unattended]): outside the bats harness NO env var moves a gate input - kill files, state, ledger, policy, lens, spike, caps and gate scripts are constants" {
  E=/tmp/h2-evil
  evil=(HYDRA_ROOT="$E" CVO_ETC="$E/etc" CVO_STATE="$E/state" PY_BIN="$E/py" CVO_RUNNER="$E/r" CVO_OWING="$E/o" CVO_RECEIPTS="$E/rc"
        CVO_HEALTH="$E/h" CVO_ZERO_READ="$E/z" CVO_FRAUD="$E/f" CVO_MAIN_ENV="$E/env" CVO_LEDGER="$E/l.sqlite3" CVO_SCRIPTS="$E/s"
        CVO_RD_SCAN="$E/rd" CVO_RD_CAP=99999 CVO_POLICY="$E/p.json" CVO_CLAIM_LIST="$E/c.json" CVO_CAP=99999 CVO_R1_CAP=99999
        CVO_CLAIM_CAP=99999 CVO_REFUSAL_SPIKE=1.0 CVO_DOW=9 CVO_NEED_RUNNER="$E/n" CVO_UNSIGNED_ALL=1 CVO_NOW_EPOCH=1 CVO_JUDGE="$E/j" CVO_DEPLOYED_SHA="$E/d" CVO_CHECK_ENTRIES=99999 CVO_TICK_BUDGET_S=999999 CVO_TICK_HARD_S=999999 CVO_CHECK_S_PER_USER=0 CVO_RESERVE_PAD_S=0 CVO_APPLY_S_PER_USER=1 CVO_TICK_ELAPSED0=99 CVO_FULL_CAP_FROM_TEST=uvn-status=2000-01-01T00:00Z CVO_PER_SEGMENT_FROM_TEST=status-doc-received=2000-01-01T00:00Z CVO_PAID_FROM_TEST=proof-need-ask=2000-01-01T00:00Z CVO_TIMEOUT_BIN="$E/t")
  run -0 env -u BATS_TEST_TMPDIR "${evil[@]}" "$SCRIPT" --print-config
  [[ "$output" != *"$E"* ]]; [[ "$output" != *99999* ]]
  now_line="$(printf '%s\n' "$output" | grep '^NOW_EPOCH=')"; [ "${now_line#NOW_EPOCH=}" -gt 1700000000 ]   # the real clock, never CVO_NOW_EPOCH=1
  output="$(printf '%s\n' "$output" | grep -v '^NOW_EPOCH=')"
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
REFUSAL_SPIKE=0.20
NEED_RUNNER=/opt/hydra/scripts/credit_review/need_asks.py
FIRST_CAP=100
UNSIGNED_ALL=0
JUDGE=/opt/hydra/scripts/credit-batch-judge.py
DEPLOYED_SHA_FILE=/opt/hydra/.deployed-sha
CHECK_ENTRIES=200
TICK_BUDGET_S=6000
TICK_HARD_S=6900
CHECK_S_PER_USER=4
RESERVE_PAD_S=300
APPLY_S_PER_USER=15
TICK_ELAPSED0=0
FULL_CAP_FROM_TEST=
PER_SEGMENT_FROM_TEST=
PAID_FROM_TEST=
TIMEOUT_BIN=/usr/bin/timeout"
  [ "$output" = "$want" ]
  # a BATS_TEST_TMPDIR that is not a directory is not the harness either
  run -0 env BATS_TEST_TMPDIR=/nonexistent/x "${evil[@]}" "$SCRIPT" --print-config
  output="$(printf '%s\n' "$output" | grep -v '^NOW_EPOCH=')"
  [ "$output" = "$want" ]
  # under the harness (bats sets BATS_TEST_TMPDIR) the test values are the seam
  run -0 "$SCRIPT" --print-config
  [[ "$output" == *"CVO_HARNESS=1"* ]]; [[ "$output" == *"KILL=$CVO_ETC/credit-verify-outbound.disabled"* ]]
  [[ "$output" == *"LEDGER=$CVO_LEDGER"* ]]
}

@test "outbound tick ([key=proof-need-ask-family]): the per-need ask runs as a family - built each tick, checked with --check-recipients, applied as proof-need-ask under the credit group cap" {
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"
  export STUB_NEED_USERS=1 CVO_PAID_FROM_TEST="proof-need-ask=2026-01-01T00:00Z"   # ruling 2: paid runs only from a dated PAID_FROM
  printf '7\n' > "$CVO_ETC/credit-verify-outbound.exclude"     # another lane messages user 7 today
  run -0 "$SCRIPT"
  grep -q "^need-build" "$CALLS.need"
  grep -q "^need-asks.json 5,6$" "$CALLS.lists"                # the need list without the excluded user 7
  grep -q "^send --list .*need-asks.json --segment paid --max-entries [0-9]* --start-entry 0 --mode dry-run --max-users 250 --check-recipients" "$CALLS"
  grep -q "^send --list .*need-asks.json --segment paid --max-entries [0-9]* --start-entry 0 --mode apply" "$CALLS"
  grep -q "^send --list .*need-asks.json --segment free --max-entries [0-9]* --start-entry 0 --mode apply" "$CALLS"
  # r5 639 / p1 638: the need family is PAGED like uvn-status - its own cursor moves to the run's page.end (450 listed)
  [ "$(cat "$CVO_STATE/cursor-proof-need-ask-paid")" = "200" ]
  : > "$CALLS"; rm -rf "$CVO_OUT_ROOT"; run -0 "$SCRIPT"
  grep -q "^send --list .*need-asks.json --segment paid --max-entries [0-9]* --start-entry 200 --mode dry-run" "$CALLS"
  # QA #1587: a deployed runner that predates #1582 (no --check-recipients) is skipped, and the tick goes on
  rm -f "$CVO_ETC/credit-verify-outbound.disabled"; : > "$CALLS"
  grep -v -- '"--check-recipients"' "$CVO_NEED_RUNNER" > "$TEST_TMPDIR/need-old.py"
  CVO_NEED_RUNNER="$TEST_TMPDIR/need-old.py" run -0 "$SCRIPT"
  if grep -q "^send " "$CALLS"; then false; fi
  grep -q "^uvn-status .*--mode apply" "$CALLS"
  grep -q "no --check-recipients (#1582 not deployed); skipped" "$(newest_tick)"
  # a builder that fails stops the tick (like the other builders)
  rm -f "$CVO_ETC/credit-verify-outbound.disabled"; : > "$CALLS"; STUB_NEED_BUILD_FAIL=1 run -1 "$SCRIPT"
  if grep -q -- "--mode apply" "$CALLS"; then false; fi
}

@test "outbound tick (h2/p1 713): a SECONDS-form read-back date is honoured by the same reader that arms the family" {
  # QA #1648 fixed this in the GATE's reached(); the tick had its own minute-only parser, so a date copied from a ledger
  # row ("2026-11-03T12:56:26Z") parsed as ValueError, exited 1, and the family sat silently SIGNED-only with nothing
  # logged. One reader for every form the writers produce - and this is the test that fails if it narrows again.
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"
  sed 's/\[status-doc-received\]="2026-11-03T12:56Z"/[status-doc-received]="2026-11-03T12:56:26Z"/' "$SCRIPT" > "$TEST_TMPDIR/cvo-secs.sh"
  grep -q 'status-doc-received\]="2026-11-03T12:56:26Z"' "$TEST_TMPDIR/cvo-secs.sh"      # the copy really carries the seconds form
  STUB_NEED_USERS=1 CVO_UNSIGNED_ALL=0 run -0 bash "$TEST_TMPDIR/cvo-secs.sh"
  grep -q -- "--segment paid .*--campaign status-doc-received .*--mode apply" "$CALLS"
  # and the same date one minute LATER is not reached yet: the seconds form is READ, not rounded up or ignored
  : > "$CALLS"
  STUB_NEED_USERS=1 CVO_UNSIGNED_ALL=0 \
    CVO_NOW_EPOCH="$(python3 -c 'import datetime as d; print(int(d.datetime(2026,11,3,12,56,20,tzinfo=d.timezone.utc).timestamp()))')" \
    run -0 bash "$TEST_TMPDIR/cvo-secs.sh"
  if grep -q "campaign status-doc-received.*--mode apply" "$CALLS"; then false; fi
}

# r5 19:06Z ruling on #1671 (p1 718): the receipts class's first batch is ONE shared budget of FIRST_CAP=100 per tick
# across paid + free, paid first, charged by the LEDGER's count of each apply's rows - never 100 per segment.
r1_apply_cap() { # <segment>: the --max-users of that segment's r1 apply (empty = no apply)
  grep -- "--segment $1 .*--campaign status-doc-received .*--mode apply" "$CALLS" | grep -o -- "--max-users [0-9]*" | head -1 | awk '{print $2}'
}
r1_check_cap() { # <segment>: the --max-users of that segment's r1 recipient check (empty = not checked)
  grep -- "--segment $1 .*--campaign status-doc-received .*--mode dry-run --max-users [0-9]* --check-recipients" "$CALLS" | grep -o -- "--max-users [0-9]*" | head -1 | awk '{print $2}'
}

@test "outbound tick (r5 19:06Z): the r1 first batch is ONE shared 100 per tick - paid first, free takes only the remainder" {
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"
  # every apply writes 60 ledger rows: r1 paid spends 60 of the shared 100, so r1 free may take at most 40
  STUB_ROWS=60 CVO_UNSIGNED_ALL=0 run -0 "$SCRIPT"
  [ "$(r1_check_cap paid)" = 100 ]
  [ "$(r1_apply_cap paid)" = 100 ]
  [ "$(r1_check_cap free)" = 40 ]
  [ "$(r1_apply_cap free)" = 40 ]
  # paid is served first: its apply line precedes free's
  [ "$(grep -n -- '--campaign status-doc-received .*--mode apply' "$CALLS" | head -1 | grep -c -- '--segment paid')" = 1 ]
  grep -q "r1-free: shared first-batch budget for status-doc-received: 40 of 100 left this tick (60 sent by earlier segments)" "$CVO_OUT_ROOT"/*/tick.log
  # the budget is the r1 family's own: uvn-status (60 rows from its paid apply) does not charge it, and keeps its own cap
  [ "$(grep -- '--segment free .*--campaign uvn-status .*--mode apply' "$CALLS" | grep -o -- '--max-users [0-9]*' | head -1)" = "--max-users 100" ]
}

@test "outbound tick (r5 19:06Z): once paid has spent the shared 100, the free r1 segment is not checked or applied this tick" {
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"
  STUB_ROWS=100 CVO_UNSIGNED_ALL=0 run -0 "$SCRIPT"
  [ "$(r1_apply_cap paid)" = 100 ]
  [ -z "$(r1_check_cap free)" ]
  [ -z "$(r1_apply_cap free)" ]
  grep -q "r1-free: the shared first-batch budget for status-doc-received (100/tick across all segments, r5 19:06Z) was spent by an earlier segment (100 sent)" "$CVO_OUT_ROOT"/*/tick.log
  # a DRY tick sends nothing, so it charges nothing: both segments are checked at the full shared 100
  rm -f "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"; : > "$CALLS"
  STUB_ROWS=100 CVO_UNSIGNED_ALL=0 run -0 "$SCRIPT"
  [ "$(r1_check_cap paid)" = 100 ]
  [ "$(r1_check_cap free)" = 100 ]
}

@test "outbound tick (r5 19:06Z ramp): only a dated PER_SEGMENT_FROM line gives 100 per segment, and only FULL_CAP_FROM gives R1_CAP" {
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"
  # step 2: per-segment date reached -> free gets its own 100 even after paid wrote 100
  STUB_ROWS=100 CVO_UNSIGNED_ALL=0 CVO_PER_SEGMENT_FROM_TEST="status-doc-received=2026-11-03T13:00Z" run -0 "$SCRIPT"
  [ "$(r1_apply_cap paid)" = 100 ]
  [ "$(r1_apply_cap free)" = 100 ]
  # ...but a per-segment date in the FUTURE is not reached: still shared
  : > "$CALLS"
  STUB_ROWS=100 CVO_UNSIGNED_ALL=0 CVO_PER_SEGMENT_FROM_TEST="status-doc-received=2099-01-01T00:00Z" run -0 "$SCRIPT"
  [ -z "$(r1_apply_cap free)" ]
  # step 3: full-cap date reached -> R1_CAP (250) per segment; a full-cap family is never pulled back to a shared 100
  : > "$CALLS"
  STUB_ROWS=100 CVO_UNSIGNED_ALL=0 CVO_FULL_CAP_FROM_TEST="status-doc-received=2026-11-03T13:00Z" run -0 "$SCRIPT"
  [ "$(r1_apply_cap paid)" = 250 ]
  [ "$(r1_apply_cap free)" = 250 ]
}

@test "outbound tick ([key=scale-now]): a family with no read-back date in UNSIGNED_FROM is SIGNED-only - checked and sampled, never applied; before v1's sample date it runs at the first cap of 100" {
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"
  STUB_NEED_USERS=1 CVO_UNSIGNED_ALL=0 run -0 "$SCRIPT"
  # p1 18:42Z: class C (/c2 corrections) has no date - the uvn-status family defers them at the gate, check and apply
  grep -q "^uvn-status .*--campaign uvn-status --no-correction .*--check-recipients" "$CALLS"
  grep -q "^uvn-status .*--campaign uvn-status --no-correction .*--mode apply" "$CALLS"
  # uvn-status has its date (AE-send-3 read-back): applied, at FIRST_CAP (no FULL_CAP_FROM yet)
  grep -q "^uvn-status --list .*owing-uvn.json --segment paid --campaign uvn-status .*--mode apply" "$CALLS"
  # [key=apply-sized-to-list]: the apply sends only this tick's own check's accepted set, paged by the tick
  grep -qE -- "--mode apply .*--signed-accepted [^ ]*/uvn-status-paid-check.json --page" "$CALLS"
  # p1 599 / r5 598: the uvn check, bodies and apply walk ONE page of list entries; the claim runners take no such flag
  [ "$(grep -c -- "^uvn-status .*--max-entries 200 " "$CALLS")" -eq "$(grep -c "^uvn-status " "$CALLS")" ]
  if grep -q -- "^claim-.*--max-entries" "$CALLS"; then false; fi
  grep -q "^uvn-status --list .*owing-uvn.json --segment paid --campaign uvn-status .*--mode dry-run --max-users 100 --check-recipients" "$CALLS"
  # every other family: checked (dry-run --check-recipients) but NO apply
  # (ruling 2: the paid need ask is held; the free one is the checked-never-applied proof)
  grep -q "^send --list .*need-asks.json --segment free --max-entries [0-9]* --start-entry 0 --mode dry-run --max-users 100 --check-recipients" "$CALLS"
  if grep -q "^send .*--mode apply" "$CALLS"; then false; fi
  # h2 (p1 713, r1-readback-1103 §6): status-doc-received NOW has its read-back date - 2 clean sends on the deployed head
  # a1e93182 (ledger 7073-7074, no duplicate user, zero-read OK, +60 health), so the receipts class applies in BOTH
  # segments at FIRST_CAP. That is the 443 free rows becoming sendable at all, not a flood: cap 100 until the sample line.
  grep -q -- "--segment paid .*--campaign status-doc-received .*--mode apply" "$CALLS"
  grep -q -- "--segment free .*--campaign status-doc-received .*--mode apply" "$CALLS"
  [ "$(grep -o -- "--mode apply --max-users [0-9]*" "$CALLS" | grep -c -- "--max-users 100")" -ge 1 ]
  if grep -q "^claim-.*--mode apply" "$CALLS"; then false; fi
  grep -q "SIGNED-only family" "$(newest_tick)"
  # and BEFORE its date the receipts class is signed-only like any other - a date in the future must not arm it
  : > "$CALLS"; STUB_NEED_USERS=1 CVO_UNSIGNED_ALL=0 CVO_NOW_EPOCH="$(python3 -c 'import datetime as d; print(int(d.datetime(2026,11,3,12,55,tzinfo=d.timezone.utc).timestamp()))')" run -0 "$SCRIPT"
  if grep -q "campaign status-doc-received.*--mode apply" "$CALLS"; then false; fi
  # (the family logs its SIGNED-only reason only when it has a non-empty audience; the harness list here is empty, so the
  # assertion above on the rendered argv is the one that can actually fail - and it does, if the date stops mattering)
  # #1687: read the NEWEST run's tick.log via its helper, not a glob - this branch first landed before that helper existed.
  grep -q "SIGNED-only family" "$(newest_tick)"
  # 14:3xZ (found on the 14Z live tick): a SIGNED-only family is DONE with the page it checked, so its cursor must
  # advance to where the check stopped. It used to return before advance_cursor, so it re-walked the same first page
  # every tick for ever (cursor-r1-free stayed 0 while every unsigned family moved to 200) and never saw entry 201.
  grep -q "next tick starts at" "$(newest_tick)"
  # (ruling 2: the paid need-ask is held in code, so the signed-only cursor advance is proven on the FREE segment)
  [ "$(cat "$CVO_STATE/cursor-proof-need-ask-free" 2>/dev/null || echo 0)" -gt 0 ]
  # QA #1587: the dates are TIMES - before uvn-status's date it is signed-only too; at / after it, it applies
  : > "$CALLS"; STUB_NEED_USERS=1 CVO_UNSIGNED_ALL=0 CVO_NOW_EPOCH="$(python3 -c 'import datetime as d; print(int(d.datetime(2026,10,31,18,1,tzinfo=d.timezone.utc).timestamp()))')" run -0 "$SCRIPT"
  if grep -q -- "--mode apply" "$CALLS"; then false; fi
  : > "$CALLS"; STUB_NEED_USERS=1 CVO_UNSIGNED_ALL=0 CVO_NOW_EPOCH="$(python3 -c 'import datetime as d; print(int(d.datetime(2026,10,31,18,2,tzinfo=d.timezone.utc).timestamp()))')" run -0 "$SCRIPT"
  grep -q "^uvn-status .*--mode apply" "$CALLS"
  # outside the harness the seam is a constant 0
  run -0 env -u BATS_TEST_TMPDIR CVO_UNSIGNED_ALL=1 "$SCRIPT" --print-config
  [[ "$output" == *"UNSIGNED_ALL=0"* ]]; [[ "$output" == *"FIRST_CAP=100"* ]]
}

@test "outbound tick ([key=scale-now-openclaw]): every family writes the batch judge's items (body + the renderer's facts object) and the judge runs in SHADOW - a STOP verdict blocks nothing" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  cat > "$TEST_TMPDIR/judge.py" <<'PY'
import json, os, sys
items = [json.loads(l) for l in open(sys.argv[sys.argv.index("--items") + 1])]
ref = sys.argv[sys.argv.index("--copy-ref") + 1]               # the deployed judge requires it (rc=2 without)
assert all(i["copy_ref"] == ref for i in items), (ref, items)
open(os.environ["CALLS"] + ".judge", "a").write(f"{len(items)} {ref} {type(items[0]['facts']).__name__}\n")
print(json.dumps({"verdict": "STOP", "reason_code": "test"}))
PY
  CVO_JUDGE="$TEST_TMPDIR/judge.py" run -0 "$SCRIPT"
  out="$(newest_out)"
  python3 -c "import json,sys; it=[json.loads(l) for l in open(sys.argv[1])]; assert it and it[0]['facts']['class']=='ask' and it[0]['body_html']=='<p>Hi there</p>' and it[0]['copy_ref']=='uvn', it" "$out/uvn-status-free-items.jsonl"
  grep -q "^1 uvn dict$" "$CALLS.judge"
  grep -q "judge SHADOW" "$out/tick.log"
  if grep -q "JUDGE CALL FAILED" "$out/tick.log"; then false; fi
  # r5 596: a judge call that fails (the 10:00Z argv error) is LOUD - logged and paged - and still blocks nothing
  printf 'import sys\nsys.stderr.write("usage: credit-batch-judge.py judge --copy-ref COPY_REF\\n"); sys.exit(2)\n' > "$TEST_TMPDIR/judge-bad.py"
  rm -rf "$CVO_OUT_ROOT"; : > "$CALLS"
  CVO_JUDGE="$TEST_TMPDIR/judge-bad.py" run -0 "$SCRIPT"
  grep -q "JUDGE CALL FAILED (rc=2) copy=uvn" "$(newest_tick)"
  grep -q -- "--mode apply" "$CALLS"
  grep -q -- "--mode apply" "$CALLS"                                 # shadow: the STOP blocked no apply
  # no judge deployed: the items are still written, the tick goes on
  rm -rf "$CVO_OUT_ROOT"; : > "$CALLS"; run -0 "$SCRIPT"
  out="$(newest_out)"
  [ -s "$out/uvn-status-free-items.jsonl" ]; grep -q "judge: not deployed" "$out/tick.log"
}

@test "outbound tick (p1 22:0xZ): a spent tick budget starts no new family - the rest wait for the next tick, nothing fails" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  CVO_TICK_BUDGET_S=0 run -0 "$SCRIPT"
  if grep -q -- "--check-recipients" "$CALLS"; then false; fi
  grep -q "tick budget 0s reached; this family waits for the next tick" "$(newest_tick)"
}

@test "outbound tick (QA #1587, b1 546): ONE cap rule - before the family's full-cap date at most 100, after a REACHED date its whole cap (250); a held lock is measured (holder + age, STALE past the cadence) and never taken over" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  export CVO_UNSIGNED_ALL=0 CVO_NOW_EPOCH="$(python3 -c 'import datetime as d; print(int(d.datetime(2026,11,1,4,0,tzinfo=d.timezone.utc).timestamp()))')"
  run -0 "$SCRIPT"                                                  # uvn-status: no full-cap date -> 100
  grep -q -- "--campaign uvn-status .*--max-users 100 --check-recipients" "$CALLS"
  if grep -q -- "--campaign uvn-status .*--max-users 250 --check-recipients" "$CALLS"; then false; fi
  : > "$CALLS"; rm -f "$CVO_LEDGER.segments.jsonl"
  CVO_FULL_CAP_FROM_TEST="uvn-status=2026-11-01T03:00Z" run -0 "$SCRIPT"   # a REACHED date -> the whole 250
  grep -q -- "--campaign uvn-status .*--max-users 250 --check-recipients" "$CALLS"
  : > "$CALLS"; rm -f "$CVO_LEDGER.segments.jsonl"
  CVO_FULL_CAP_FROM_TEST="uvn-status=2026-11-01T05:00Z" run -0 "$SCRIPT"   # a date not reached yet -> still 100
  grep -q -- "--campaign uvn-status .*--max-users 100 --check-recipients" "$CALLS"
  unset CVO_UNSIGNED_ALL CVO_NOW_EPOCH; : > "$CALLS"; rm -f "$CVO_LEDGER.segments.jsonl"
  run -0 "$SCRIPT"
  # the holder record a later tick measures: a pid and a start epoch from THIS run
  read -r hp hs < "$CVO_STATE/tick.holder"
  [[ "$hp" =~ ^[0-9]+$ ]] && [ "$hs" -gt $(( $(date -u +%s) - 900 )) ]
  # a live holder: the measured reason, then exit 0 without running anything
  : > "$CALLS"
  rm -f "$CVO_STATE/tick.holder"
  ( exec 9>>"$CVO_STATE/tick.lock"; flock 9; printf '4242 %s\n' "$(( $(date -u +%s) - 9000 ))" > "$CVO_STATE/tick.holder"; sleep 6 ) &
  for _ in $(seq 50); do [ -s "$CVO_STATE/tick.holder" ] && break; sleep 0.1; done   # the holder has the lock
  run -0 "$SCRIPT"
  wait
  [ ! -s "$CALLS" ]
  grep -q "STALE: tick pid 4242 has held .*tick.lock for 9[0-9][0-9][0-9]s (> cadence 7200s); this tick exits, nothing taken over" "$(newest_tick)"
}

@test "outbound tick (QA #1587): a started family is bounded in TIME - none starts without its reserve before the deadline, and the apply is cut to what fits" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  # 5000 s in, cap 250 x 2 x 4 s + 300 s = 2300 s worst case > the 6900 s deadline: no family starts
  CVO_TICK_ELAPSED0=5000 CVO_CHECK_S_PER_USER=4 CVO_RESERVE_PAD_S=300 CVO_TICK_HARD_S=6900 run -0 "$SCRIPT"
  if grep -q -- "--check-recipients" "$CALLS"; then false; fi
  grep -q "its worst case is 2300s (cap 250); it does not fit before the 6900s deadline; this family waits for the next tick" "$(newest_tick)"
  # 30 s before the deadline at 15 s a user: a started family applies at most 2
  : > "$CALLS"; rm -f "$CVO_LEDGER.segments.jsonl"
  CVO_TICK_BUDGET_S=999999 CVO_TICK_ELAPSED0=6870 CVO_CHECK_S_PER_USER=0 CVO_RESERVE_PAD_S=0 CVO_TICK_HARD_S=6900 CVO_APPLY_S_PER_USER=15 run -0 "$SCRIPT"
  grep -q -- "--mode apply --max-users [12] " "$CALLS"
  if grep -E -- "--mode apply --max-users ([3-9]|[1-9][0-9]+) " "$CALLS"; then false; fi
  grep -qE "apply cut from [0-9]+ to [12] \(what fits before the 6900s deadline\)" "$CVO_OUT_ROOT"/*/tick.log
}

@test "outbound tick (QA #1587): every subprocess runs under the deadline - a slow read-only check is stopped there and the tick ends (lock released); a slow APPLY cut at the deadline writes the kill file" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  # 3 s before the deadline, a check that would take 30 s: stopped at ~3 s, the tick ends, nothing applied, no kill
  t0=$(date +%s)
  STUB_SLEEP_MODE=dry-run STUB_SLEEP=30 CVO_TICK_BUDGET_S=999999 CVO_TICK_ELAPSED0=6897 CVO_TICK_HARD_S=6900 run -1 "$SCRIPT"
  [ $(( $(date +%s) - t0 )) -lt 25 ]
  grep -q "check hit the 6900s deadline (read-only, stopped); the tick ends" "$(newest_tick)"
  [ "$(applies)" -eq 0 ]; [ ! -e "$CVO_ETC/credit-verify-outbound.disabled" ]
  # the lock is released: the next tick runs at once
  run -0 "$SCRIPT"
  if grep -q "another tick holds" "$(newest_tick)"; then false; fi
  # an apply that runs past the deadline: stopped there, and the kill file is written (a human reads it back)
  : > "$CALLS"; rm -f "$CVO_LEDGER.segments.jsonl"
  STUB_SLEEP_MODE=apply STUB_SLEEP=30 CVO_TICK_BUDGET_S=999999 CVO_TICK_ELAPSED0=6880 CVO_TICK_HARD_S=6900 CVO_APPLY_S_PER_USER=1 run -1 "$SCRIPT"
  grep -q "the apply hit the 6900s deadline mid-run" "$CVO_ETC/credit-verify-outbound.disabled"
}

@test "outbound tick (b1 560): EVERY python subprocess runs under the one deadline wrapper - a slow builder is stopped at the deadline and the tick ends" {
  # no bare "$PY" command left outside the py() wrapper itself
  src="$BATS_TEST_DIRNAME/../credit-verify-outbound.sh"; [ -s "$src" ]
  grep -q '^py() { bounded "\$PY" "\$@"; }' "$src"
  if grep -nE '(^|[[:space:](;|&]|\$\()"\$PY" ' "$src" | grep -v ':py() {'; then false; fi
  touch "$CVO_ETC/credit-verify-outbound.live"
  t0=$(date +%s)
  STUB_OWING_SLEEP=30 CVO_TICK_BUDGET_S=999999 CVO_TICK_ELAPSED0=6897 CVO_TICK_HARD_S=6900 run -1 "$SCRIPT"
  [ $(( $(date +%s) - t0 )) -lt 25 ]
  grep -q "owing builder failed" "$(newest_tick)"
  if grep -q -- "--check-recipients" "$CALLS"; then false; fi
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
  grep -q -- "--max-users 250 --preview" "$CALLS"                 # the whole batch is rendered (the judge's items)
  out="$(newest_out)"
  [ -s "$out/uvn-status-paid-check.json" ] && [ -s "$out/uvn-status-paid-bodies/1.txt" ]
  grep -q "DRY-RUN tick (no send)" "$out/tick.log"
  # the families not deployed on this tree are logged, never silently missing
  grep -q "reply_due: no deployed audience builder" "$out/tick.log"
  if grep -q -- "reply-due" "$CALLS"; then false; fi
}

# FirstMate ruling 2 (3 Nov) + CTO MUS-27638: the missing-document ask runs LAST in every tick, free then paid; paid is held in code
first_line() { grep -n -m1 -- "$1" "$CVO_OUT_ROOT"/*/tick.log | cut -d: -f1; }

@test "outbound tick (ruling 2): proof-need-ask free runs AFTER every uvn-status / r1 / reply-due / claim-* family on a weekday tick and on a weekend tick, and free comes before paid" {
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"
  export STUB_NEED_USERS=1 CVO_PAID_FROM_TEST="proof-need-ask=2020-01-01T00:00Z"
  printf '%s\n' "$DEP" > "$CVO_DEPLOYED_SHA"
  printf '{"generated_at": "x", "signed_on": "%s", "claims": [{"claim_id": 1, "user_id": 5}]}' "$DEP" > "$CVO_STATE.claims.json"
  export CVO_CLAIM_LIST="$CVO_STATE.claims.json"
  for dow in 3 6; do
    : > "$CALLS"; rm -rf "$CVO_OUT_ROOT" "$CVO_STATE.d" "$CVO_LEDGER.segments.jsonl"
    CVO_DOW=$dow run -0 "$SCRIPT"
    log="$(ls "$CVO_OUT_ROOT"/*/tick.log)"
    need="$(first_line 'proof-need-ask-free check (rc=0)')"; [ -n "$need" ]
    seen=0
    for fam in uvn-status r1 reply-due claim-proof-ask claim-status; do
      line="$(grep -n -E -- "(^|[ ])$fam-(paid|free)( |:)" "$log" | tail -1 | cut -d: -f1 || true)"
      if [ -n "$line" ]; then seen=$((seen+1)); [ "$line" -lt "$need" ]; fi
    done
    [ "$seen" -ge 2 ]                                       # the loop is not vacuous: earlier families really ran
    # argv, not only the log: every other family's runner call precedes the need ask, and free precedes paid
    f="$(grep -n -m1 -- "need-asks.json --segment free " "$CALLS" | cut -d: -f1)"
    p="$(grep -n -m1 -- "need-asks.json --segment paid " "$CALLS" | cut -d: -f1)"
    [ -n "$f" ] && [ -n "$p" ] && [ "$f" -lt "$p" ]
    [ "$(grep -n -v -- "need-asks.json" "$CALLS" | tail -1 | cut -d: -f1)" -lt "$f" ]
  done
}

@test "outbound tick (ruling 2): production-equivalent (CVO_UNSIGNED_ALL=0, no UNSIGNED_FROM date) - the free need ask is checked (last) and never applied; no need ask is sent until a separate dated PR" {
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"
  export STUB_NEED_USERS=1 CVO_UNSIGNED_ALL=0
  run -0 "$SCRIPT"
  grep -q -- "need-asks.json --segment free .*--mode dry-run .*--check-recipients" "$CALLS"
  grep -q "proof-need-ask-free check (rc=0)" "$CVO_OUT_ROOT"/*/tick.log
  grep -q "proof-need-ask-free: SIGNED-only family (no read-back date in UNSIGNED_FROM): checked, not applied" "$CVO_OUT_ROOT"/*/tick.log
  if grep -q -- "need-asks.json .*--mode apply" "$CALLS"; then false; fi    # argv: no need-ask apply, free or paid
  if grep -q -- "need-asks.json --segment paid" "$CALLS"; then false; fi
}

@test "outbound tick (ruling 2): with PAID_FROM[proof-need-ask] unset the PAID need ask is never invoked - even with .paid-enabled present; the hold is logged and free still applies" {
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"
  export STUB_NEED_USERS=1
  unset CVO_PAID_FROM_TEST
  run -0 "$SCRIPT"
  if grep -q -- "need-asks.json --segment paid" "$CALLS"; then false; fi     # the runner argv is the proof
  grep -q -- "need-asks.json --segment free .*--mode apply" "$CALLS"
  grep -q "proof-need-ask paid: held until PAID_FROM\[proof-need-ask\] is set (ruling 2: free first); skipped" "$CVO_OUT_ROOT"/*/tick.log
  # the other paid families are unchanged by the hold
  grep -q -- "--segment paid .*--mode apply" "$CALLS"
}

@test "outbound tick (ruling 2): a REACHED PAID_FROM date runs paid need ask after free; a FUTURE date holds it" {
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"
  export STUB_NEED_USERS=1
  CVO_PAID_FROM_TEST="proof-need-ask=2020-01-01T00:00Z" run -0 "$SCRIPT"
  f="$(grep -n -m1 -- "need-asks.json --segment free .*--mode apply" "$CALLS" | cut -d: -f1)"
  p="$(grep -n -m1 -- "need-asks.json --segment paid .*--mode apply" "$CALLS" | cut -d: -f1)"
  [ -n "$f" ] && [ -n "$p" ] && [ "$f" -lt "$p" ]
  if grep -q "proof-need-ask paid: held" "$CVO_OUT_ROOT"/*/tick.log; then false; fi
  : > "$CALLS"; rm -rf "$CVO_OUT_ROOT"; rm -f "$CVO_LEDGER.segments.jsonl"
  CVO_PAID_FROM_TEST="proof-need-ask=2099-01-01T00:00Z" run -0 "$SCRIPT"
  if grep -q -- "need-asks.json --segment paid" "$CALLS"; then false; fi
  grep -q "proof-need-ask paid: held until PAID_FROM" "$CVO_OUT_ROOT"/*/tick.log
}

@test "outbound tick (ruling 2): a spent budget stops every family, the last-running need ask included - it logs waits-for-the-next-tick and its runner is never invoked" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  export STUB_NEED_USERS=1
  CVO_TICK_ELAPSED0=100 CVO_TICK_BUDGET_S=50 run -0 "$SCRIPT"
  grep -q "proof-need-ask-free: tick budget 50s reached; this family waits for the next tick" "$CVO_OUT_ROOT"/*/tick.log
  grep -q "uvn-status-paid: tick budget 50s reached; this family waits for the next tick" "$CVO_OUT_ROOT"/*/tick.log
  if grep -q -- "--mode" "$CALLS"; then false; fi
}

@test "[key=arm-per-family] a family is armed by its OWN policy row: uvn-status applies while a family with no row (or live:false) checks and never applies - and the two GLOBAL files cannot arm it" {
  # l1 ruling 2026-11-02 (ruling-never-a-bottleneck-1102.md): the defect was that two GLOBAL files made arming one
  # decision for six families, so moving a proven class along needed everything else armed too.
  jq '.armed_families = {"uvn-status": {"live": true, "paid": false}}' \
    "$BATS_TEST_DIRNAME/../../policies/credit-verify-outbound.json" > "$TEST_TMPDIR/p.json"
  export CVO_POLICY="$TEST_TMPDIR/p.json"
  run -0 "$SCRIPT"
  out="$(ls -d "$CVO_OUT_ROOT"/*)"
  grep -q "arming=policy armed: uvn-status=live/dry" "$out/tick.log"
  grep -q -- "--segment free .*--campaign uvn-status .*--mode apply" "$CALLS"   # its own row arms it
  if grep -q -- "--campaign status-doc-received .*--mode apply" "$CALLS"; then false; fi   # no row = not armed
  grep -q "r1-paid: DRY-RUN tick (no send): arming=policy r1=not armed" "$out/tick.log"
  # THE POINT: writing the two legacy files changes nothing once armed_families exists
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"
  : > "$CALLS"; run -0 "$SCRIPT"
  if grep -q -- "--campaign status-doc-received .*--mode apply" "$CALLS"; then false; fi
  if grep -q -- "--segment paid .*--mode apply" "$CALLS"; then false; fi            # paid:false is paid:false
}

@test "[key=arm-per-family] live and paid are per family, and the unsigned date rides the same row - a future date keeps that family SIGNED-only while a reached one applies" {
  jq '.armed_families = {"uvn-status": {"live": true, "paid": true, "unsigned_from": "2099-01-01T00:00Z"},
                         "r1": {"live": true, "paid": true}}' \
    "$BATS_TEST_DIRNAME/../../policies/credit-verify-outbound.json" > "$TEST_TMPDIR/p.json"
  export CVO_POLICY="$TEST_TMPDIR/p.json" CVO_UNSIGNED_ALL=0      # let the dates decide, as production does
  run -0 "$SCRIPT"
  out="$(ls -d "$CVO_OUT_ROOT"/*)"
  grep -q "uvn-status=live/paid from 2099-01-01T00:00Z" "$out/tick.log"
  # uvn-status: armed but its date has not passed -> checked, never applied
  if grep -q -- "--campaign uvn-status .*--mode apply" "$CALLS"; then false; fi
  grep -q "uvn-status-paid: SIGNED-only family (no read-back date in UNSIGNED_FROM): checked, not applied" "$out/tick.log"
  # r1: armed by its row and the row carries its own date... which it does not, so it too is SIGNED-only - a live row
  # with no date is never an apply
  if grep -q -- "--campaign status-doc-received .*--mode apply" "$CALLS"; then false; fi
}

@test "[key=arm-per-family] (QA #1648 CRITICAL) the zero-read guard is measured from the READER, so an armed policy row cannot apply when the reader is not deployed - the legacy flag file's absence must not disarm the safety check" {
  # the guard exists because a send with no zero-read reader can only auto-kill. It was gated on LIVE, which under policy
  # arming can be 0 with no legacy flag file at all - so an armed row applied with the guard never evaluated.
  jq '.armed_families = {"uvn-status": {"live": true, "paid": false, "unsigned_from": "2020-01-01T00:00Z"}}' \
    "$BATS_TEST_DIRNAME/../../policies/credit-verify-outbound.json" > "$TEST_TMPDIR/p.json"
  export CVO_POLICY="$TEST_TMPDIR/p.json" CVO_UNSIGNED_ALL=0
  [ ! -e "$CVO_ETC/credit-verify-outbound.live" ]     # policy mode: the legacy flag file need not exist
  CVO_ZERO_READ="$TEST_TMPDIR/not-deployed.py" run -0 "$SCRIPT"
  out="$(ls -d "$CVO_OUT_ROOT"/*)"
  grep -q "LIVE REFUSED: the zero-read reader" "$out/tick.log"
  grep -q "uvn-status-paid: DRY-RUN tick (no send): arming=policy uvn-status=not armed" "$out/tick.log"
  if grep -q -- "--mode apply" "$CALLS"; then false; fi
  # the same row WITH the reader deployed applies: the guard is the only difference
  : > "$CALLS"; rm -rf "$CVO_OUT_ROOT"
  run -0 "$SCRIPT"
  grep -q -- "--campaign uvn-status .*--mode apply" "$CALLS"
}

@test "[key=arm-per-family] (QA #1648 finding 2) the r1 receipt is armed by EITHER spelling - the tick's family name or its campaign name - because each reader asks for a different key" {
  # family_armed is asked for "r1"; UNSIGNED_FROM is read as "status-doc-received". A row using one spelling armed
  # nothing and dated nothing: a silent miss with no log line to blame.
  jq '.armed_families = {"status-doc-received": {"live": true, "paid": true, "unsigned_from": "2020-01-01T00:00Z"}}' \
    "$BATS_TEST_DIRNAME/../../policies/credit-verify-outbound.json" > "$TEST_TMPDIR/p.json"
  export CVO_POLICY="$TEST_TMPDIR/p.json" CVO_UNSIGNED_ALL=0
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"
  run -0 "$SCRIPT"
  out="$(ls -d "$CVO_OUT_ROOT"/*)"
  grep -q "r1=live/paid from 2020-01-01T00:00Z" "$out/tick.log"
  grep -q -- "--campaign status-doc-received .*--mode apply" "$CALLS"
  # and the same row spelled with the tick's own name behaves identically
  : > "$CALLS"; rm -rf "$CVO_OUT_ROOT"
  jq '.armed_families = {"r1": {"live": true, "paid": true, "unsigned_from": "2020-01-01T00:00Z"}}' \
    "$BATS_TEST_DIRNAME/../../policies/credit-verify-outbound.json" > "$TEST_TMPDIR/p.json"
  run -0 "$SCRIPT"
  grep -q -- "--campaign status-doc-received .*--mode apply" "$CALLS"
}

@test "[key=arm-per-family] (QA #1648 findings 1+2) a row with NO unsigned_from CLEARS the code's built-in date instead of inheriting it, and a misspelled family key is MALFORMED - nothing armed, paged" {
  # "live:true and no date" must mean SIGNED-only: inheriting the code date would apply on a date the reviewer never saw
  # in the row they signed - the opposite of what the row says.
  jq '.armed_families = {"uvn-status": {"live": true, "paid": true}}' \
    "$BATS_TEST_DIRNAME/../../policies/credit-verify-outbound.json" > "$TEST_TMPDIR/p.json"
  export CVO_POLICY="$TEST_TMPDIR/p.json" CVO_UNSIGNED_ALL=0      # production: the dates decide
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"
  run -0 "$SCRIPT"
  out="$(ls -d "$CVO_OUT_ROOT"/*)"
  # uvn-status HAS a built-in code date in the past; the row clears it
  grep -q "uvn-status=live/paid (SIGNED-only: the row sets no unsigned_from)" "$out/tick.log"
  grep -q "uvn-status-paid: SIGNED-only family (no read-back date in UNSIGNED_FROM): checked, not applied" "$out/tick.log"
  if grep -q -- "--campaign uvn-status .*--mode apply" "$CALLS"; then false; fi
  # a misspelled family key is a SEMANTIC error (QA #1648 finding 1), so it is malformed in its own right - not
  # "policy mode, that row ignored" while the family the operator meant stays dry for ever
  rm -rf "$CVO_OUT_ROOT"; : > "$CALLS"
  jq '.armed_families = {"uvn-status": {"live": true, "paid": true}, "uvn_status": {"live": true, "paid": true}}' \
    "$BATS_TEST_DIRNAME/../../policies/credit-verify-outbound.json" > "$TEST_TMPDIR/p.json"
  run -0 "$SCRIPT"
  out="$(ls -d "$CVO_OUT_ROOT"/*)"
  grep -q "arming=malformed" "$out/tick.log"
  grep -q "ARMING MALFORMED: .*armed_families (or a row of it) is malformed; NOTHING is armed this tick" "$out/tick.log"
}

@test "[key=arm-per-family] (QA #1648 finding 1) a date the calendar cannot produce is MALFORMED and pages, not a silent SIGNED-only stall - the same for a value that is not a date at all" {
  # "tomorrow" is a string, so the type check passed; reached() then failed, the family stayed dry for ever, and the
  # malformed page the operator was promised never fired. A typo must be loud on an unattended tick.
  jq '.armed_families = {"r1": {"live": true, "paid": true, "unsigned_from": "tomorrow"}}' \
    "$BATS_TEST_DIRNAME/../../policies/credit-verify-outbound.json" > "$TEST_TMPDIR/p.json"
  export CVO_POLICY="$TEST_TMPDIR/p.json"
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"
  run -0 "$SCRIPT"
  out="$(ls -d "$CVO_OUT_ROOT"/*)"
  grep -q "arming=malformed" "$out/tick.log"
  grep -q "ARMING MALFORMED" "$out/tick.log"
  [ "$(applies)" -eq 0 ]
  # an impossible calendar date (Feb 30) and a bad hour are the same failure, not "a date in the future"
  for bad in "2026-02-30T00:00Z" "2026-11-03T25:00Z" "2026-13-01T00:00Z"; do
    rm -rf "$CVO_OUT_ROOT"; : > "$CALLS"
    jq --arg d "$bad" '.armed_families = {"r1": {"live": true, "paid": true, "unsigned_from": $d}}' \
      "$BATS_TEST_DIRNAME/../../policies/credit-verify-outbound.json" > "$TEST_TMPDIR/p.json"
    run -0 "$SCRIPT"
    out="$(ls -d "$CVO_OUT_ROOT"/*)"
    grep -q "arming=malformed" "$out/tick.log"
    [ "$(applies)" -eq 0 ]
  done
  # and a well-formed instant still arms: the check rejects typos, not dates
  rm -rf "$CVO_OUT_ROOT"; : > "$CALLS"
  jq '.armed_families = {"r1": {"live": true, "paid": true, "unsigned_from": "2020-01-01T00:00Z"}}' \
    "$BATS_TEST_DIRNAME/../../policies/credit-verify-outbound.json" > "$TEST_TMPDIR/p.json"
  run -0 "$SCRIPT"
  grep -q -- "--campaign status-doc-received .*--mode apply" "$CALLS"
}

@test "[key=arm-per-family] a malformed armed_families block arms NOTHING (fail closed, paged, tick continues) while an unreadable policy FILE stops and kills" {
  jq '.armed_families = {"uvn-status": {"live": true}}' \
    "$BATS_TEST_DIRNAME/../../policies/credit-verify-outbound.json" > "$TEST_TMPDIR/p.json"   # no "paid"
  export CVO_POLICY="$TEST_TMPDIR/p.json"
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"  # must not matter
  run -0 "$SCRIPT"
  out="$(ls -d "$CVO_OUT_ROOT"/*)"
  grep -q "arming=malformed" "$out/tick.log"
  grep -q "ARMING MALFORMED: .*armed_families (or a row of it) is malformed; NOTHING is armed this tick" "$out/tick.log"
  [ "$(applies)" -eq 0 ]
  # an UNREADABLE policy file is not the same state: a policy we cannot read is an operational failure, so the tick
  # stops and kills (QA #1541's rule for the cap read), never a silent dry run
  rm -f "$CVO_ETC/credit-verify-outbound.disabled"; : > "$TEST_TMPDIR/p.json"; : > "$CALLS"
  rm -rf "$CVO_OUT_ROOT"; run -1 "$SCRIPT"
  [ "$(applies)" -eq 0 ]
  grep -q "cap source unreadable" "$CVO_ETC/credit-verify-outbound.disabled"
}

@test "[key=arm-per-family] a SECONDS-form unsigned_from is read by the same parser that validated it - the family applies once the date passes" {
  # QA #1648 finding 3: read_arming() accepted "%Y-%m-%dT%H:%M:%SZ" AND "%Y-%m-%dT%H:%MZ", but reached() parsed only the
  # minute form. So a seconds-dated row validated, logged "armed ... from 2020-01-01T00:00:30Z", and then never applied -
  # a silent SIGNED-only with no malformed page, which is the exact failure the semantic checks were added to prevent.
  jq '.armed_families = {"uvn-status": {"live": true, "paid": true, "unsigned_from": "2020-01-01T00:00:30Z"}}' \
    "$BATS_TEST_DIRNAME/../../policies/credit-verify-outbound.json" > "$TEST_TMPDIR/p-sec.json"
  export CVO_POLICY="$TEST_TMPDIR/p-sec.json" CVO_UNSIGNED_ALL=0   # the harness default forces unsigned; the DATE is the question here
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"
  run -0 "$SCRIPT"
  out="$(ls -d "$CVO_OUT_ROOT"/*)"
  grep -q "arming=policy" "$out/tick.log"
  grep -q -- "--mode apply" "$CALLS"        # a date in 2020 is past: the row must APPLY, not sit dry forever
  # and the minute form still works - the fix is a wider reader, not a different one
  jq '.armed_families = {"uvn-status": {"live": true, "paid": true, "unsigned_from": "2020-01-01T00:00Z"}}' \
    "$BATS_TEST_DIRNAME/../../policies/credit-verify-outbound.json" > "$TEST_TMPDIR/p-min.json"
  rm -f "$CVO_ETC/credit-verify-outbound.disabled"; : > "$CALLS"; rm -rf "$CVO_OUT_ROOT"
  export CVO_POLICY="$TEST_TMPDIR/p-min.json"
  run -0 "$SCRIPT"
  grep -q -- "--mode apply" "$CALLS"
  # a FUTURE seconds-form date is still SIGNED-only: the widening must not turn every date into "reached"
  jq '.armed_families = {"uvn-status": {"live": true, "paid": true, "unsigned_from": "2099-01-01T00:00:30Z"}}' \
    "$BATS_TEST_DIRNAME/../../policies/credit-verify-outbound.json" > "$TEST_TMPDIR/p-fut.json"
  rm -f "$CVO_ETC/credit-verify-outbound.disabled"; : > "$CALLS"; rm -rf "$CVO_OUT_ROOT"
  export CVO_POLICY="$TEST_TMPDIR/p-fut.json"
  run -0 "$SCRIPT"
  # SIGNED-only, not silent: the row still applies, but only under the two-seat signature. Before the fix this looked
  # identical to the past date, because `reached()` could never answer yes at all.
  grep -q "uvn-status-paid: SIGNED-only family (no read-back date in UNSIGNED_FROM): checked, not applied" \
    "$CVO_OUT_ROOT"/*/tick.log
}

@test "[key=arm-per-family] two rows that name ONE family by different spellings are MALFORMED - a disarm cannot be overruled by string order" {
  # QA #1648 finding 2 (the alias collision): `r1` and `status-doc-received` are the same family. Both parse, and sorted
  # iteration mapped both to ARMED_LIVE[r1] - so `r1: {live:false}` followed by `status-doc-received: {live:true}`
  # re-armed a family a human had explicitly disarmed, decided by STRING ORDER of two names for one thing.
  jq '.armed_families = {"r1": {"live": false, "paid": false},
                         "status-doc-received": {"live": true, "paid": true, "unsigned_from": "2020-01-01T00:00Z"}}' \
    "$BATS_TEST_DIRNAME/../../policies/credit-verify-outbound.json" > "$TEST_TMPDIR/p-dupe.json"
  export CVO_POLICY="$TEST_TMPDIR/p-dupe.json"
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"
  run -0 "$SCRIPT"
  out="$(ls -d "$CVO_OUT_ROOT"/*)"
  grep -q "arming=malformed" "$out/tick.log"                                  # fail closed, nothing armed
  grep -q "r1 and status-doc-received both arm the r1 family" "$out/tick.log"  # and the operator is told WHICH pair
  [ "$(applies)" -eq 0 ]
  # order-independence: the other way round is the SAME policy with the same outcome, so the test cannot encode one order
  jq '.armed_families = {"status-doc-received": {"live": true, "paid": true, "unsigned_from": "2020-01-01T00:00Z"},
                         "r1": {"live": false, "paid": false}}' \
    "$BATS_TEST_DIRNAME/../../policies/credit-verify-outbound.json" > "$TEST_TMPDIR/p-dupe2.json"
  rm -f "$CVO_ETC/credit-verify-outbound.disabled"; : > "$CALLS"; rm -rf "$CVO_OUT_ROOT"
  export CVO_POLICY="$TEST_TMPDIR/p-dupe2.json"
  run -0 "$SCRIPT"
  out="$(ls -d "$CVO_OUT_ROOT"/*)"
  grep -q "arming=malformed" "$out/tick.log"
  [ "$(applies)" -eq 0 ]
  # a policy naming each family ONCE still arms: this is a rejection of ambiguity, not of the alias
  jq '.armed_families = {"status-doc-received": {"live": true, "paid": true, "unsigned_from": "2020-01-01T00:00Z"},
                         "uvn-status": {"live": true, "paid": true, "unsigned_from": "2020-01-01T00:00Z"}}' \
    "$BATS_TEST_DIRNAME/../../policies/credit-verify-outbound.json" > "$TEST_TMPDIR/p-one.json"
  rm -f "$CVO_ETC/credit-verify-outbound.disabled"; : > "$CALLS"; rm -rf "$CVO_OUT_ROOT"
  export CVO_POLICY="$TEST_TMPDIR/p-one.json"
  run -0 "$SCRIPT"
  out="$(ls -d "$CVO_OUT_ROOT"/*)"
  grep -q "arming=policy" "$out/tick.log"
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

@test "outbound tick (production 15:05Z): an ABSENT outcomes artefact after real sends is UNMEASURED, never a 'refusal spike'" {
  # On 2026-11-04 the free family sent 39 emails, died inside the Intercom note (TimeoutExpired), returned rc=1 and
  # never wrote its outcomes artefact. spike() answered "unreadable", the caller accepted only "ok", and the kill file
  # read "refusal spike (> 0.20 of attempts refused)" - a statement about the world with nothing to count. The stop was
  # right; the LABEL was false, and the label is the only part of an incident a human still reads the next morning.
  # Absence has no ratio: it is its own verdict, it names the path it could not read, and it never says "spike".
  touch "$CVO_ETC/credit-verify-outbound.live"
  STUB_NO_ARTEFACT=1 STUB_ROWS=3 STUB_REFUSED=0 run -1 "$SCRIPT"
  [ -e "$CVO_ETC/credit-verify-outbound.disabled" ]
  grep -q "OUTCOMES UNMEASURED after 3 send(s)" "$CVO_ETC/credit-verify-outbound.disabled"
  grep -q "uvn-status-free-apply.json was never written" "$CVO_ETC/credit-verify-outbound.disabled"
  grep -q "no ratio can be computed" "$CVO_ETC/credit-verify-outbound.disabled"
  ! grep -q "refusal spike" "$CVO_ETC/credit-verify-outbound.disabled"   # and it must never WEAR the spike label
}

@test "outbound tick: an UNPARSEABLE outcomes artefact is also UNMEASURED and names the parse failure" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  STUB_ARTEFACT_JUNK=1 STUB_ROWS=2 run -1 "$SCRIPT"
  grep -q "OUTCOMES UNMEASURED" "$CVO_ETC/credit-verify-outbound.disabled"
  grep -q "unreadable" "$CVO_ETC/credit-verify-outbound.disabled"
  ! grep -q "refusal spike" "$CVO_ETC/credit-verify-outbound.disabled"
}

@test "outbound tick (qa Critical, d2 17:1xZ): a COMBINED 'STOP+UNMEASURED:' verdict still KILLS - a STOP of any form wins over UNMEASURED" {
  # zero_read.py emits STOP+UNMEASURED (exit 1) when a confirmed stop and an unread source exist in the same batch.
  # The verdict case listed only OK*/STOP*/UNMEASURED*, so the combined WORD matched nothing, was rewritten to
  # "UNMEASURED: ... no verdict" and forced rc=2 - which BYPASSED the stop arm at the exact moment a stop existed.
  # That is the same defect this branch fixes, one layer up: a status word carrying two meanings, gated by a pattern
  # that could only see one of them. This test drives the REAL call site; a grep for the word proves nothing.
  touch "$CVO_ETC/credit-verify-outbound.live"
  STUB_ZERO_RC=3 CVO_UNSIGNED_ALL=0 run -1 "$SCRIPT"
  [ -e "$CVO_ETC/credit-verify-outbound.disabled" ]
  grep -q "zero-read STOP+UNMEASURED" "$CVO_ETC/credit-verify-outbound.disabled"
  grep -q "do NOT account for every source" "$CVO_ETC/credit-verify-outbound.disabled"
  # and it must never wear the "printed no verdict" rewriting, which is what happened before the fix
  ! grep -q "printed no verdict" "$CVO_ETC/credit-verify-outbound.disabled"
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
  grep -q "owing classes:.*review_hold" "$(newest_tick)"
}

@test "outbound tick (r5 776, the 08:00Z dry tick): the split list verifies - the BUILDER writes owing-uvn.json, the tick never edits a built list" {
  run -0 "$SCRIPT"
  grep -q -- "--out .*/owing.json --class-out uvn=.*/owing-uvn.json" "$CALLS.owing"
  jq -e '.split_of.class == "uvn"' "$CVO_OUT_ROOT"/*/owing-uvn.json >/dev/null      # the builder's file, not a rewrite
  # a builder that writes no class list stops the tick before any family
  rm -rf "$CVO_OUT_ROOT"; : > "$CALLS"
  STUB_NO_CLASS_OUT=1 run -1 "$SCRIPT"
  grep -q "owing builder wrote no uvn-class list; tick stops" "$(newest_tick)"
  if grep -q "^uvn-status " "$CALLS"; then false; fi
}

@test "outbound tick (r5 #1541): a failed body sample stops the tick before any apply" {
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"
  STUB_PREVIEW_FAIL=1 run -1 "$SCRIPT"
  [ "$(applies)" -eq 0 ]
  grep -q "body sample failed; no apply" "$(newest_tick)"
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
  grep -q "daily cap reached for uvn-status/free" "$(newest_tick)"
  # QA #1541: an unreadable policy = no apply anywhere AND a stop + kill file (never a silent "cap reached")
  : > "$CALLS"; CVO_POLICY="$TEST_TMPDIR/missing.json" run -1 "$SCRIPT"
  [ "$(applies)" -eq 0 ]
  grep -q "cap source unreadable" "$CVO_ETC/credit-verify-outbound.disabled"
  if grep -q "daily cap reached .*unreadable" "$(newest_tick)"; then false; fi
}

@test "outbound tick (QA #1545 finding 3): a PARTIAL apply (rows written, nonzero exit) is never rescued by an UNMEASURED zero-read - the tick stops" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  rm -f "$CVO_ETC/credit-verify-outbound.disabled" "$CALLS.zero" "$CALLS.page"
  # the runner wrote `sent` rows and THEN exited 1; Loki is unreadable, so the zero-read is UNMEASURED. Before the fix
  # the UNMEASURED branch returned 0 and skipped the rc guard, reporting a partially-sent family as successful.
  STUB_APPLY_RC=1 STUB_ZERO_RC=2 STUB_ZERO_RC_ONCE=1 run -1 "$SCRIPT"
  [ -e "$CALLS.zero" ]                                    # rows existed, so the read ran over them
  grep -q "zero-read UNMEASURED" "$CALLS.page"            # ruling B still pages the same minute
  grep -q "apply FAILED (rc=1) AND the zero-read was UNMEASURED" "$(newest_tick)"
  [ ! -e "$CVO_ETC/credit-verify-outbound.disabled" ]      # a failed apply stops the tick; it is not a zero-read STOP
}

@test "UNMEASURED with an UNDELIVERABLE page (QA #1545 finding 2): the tick fails closed and PERSISTS the page; the next tick delivers it before any family and clears the marker" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  rm -f "$CVO_ETC/credit-verify-outbound.disabled" "$CALLS.zero" "$CALLS.page" "$CVO_STATE"/zero-unmeasured-*
  # Slack is down while the zero-read is UNMEASURED: page() would have swallowed it (it always returned 0), leaving
  # the outage in local logs only while the unattended tick kept running.
  STUB_ZERO_RC=2 STUB_ZERO_RC_ONCE=1 STUB_SLACK_RC=1 run -1 "$SCRIPT"
  grep -q "the PAGE FAILED" "$(newest_tick)"
  if ! ls "$CVO_STATE"/zero-unmeasured-undelivered-* >/dev/null 2>&1; then false; fi   # durable, not just a log line
  grep -q "zero-read UNMEASURED (undelivered page)" "$CVO_STATE"/zero-unmeasured-undelivered-*
  # Slack is back: the next tick RETRIES the persisted text at the top, clears the marker, then runs its families
  : > "$CALLS.page"
  run -0 "$SCRIPT"
  grep -q "RETRY (page previously undelivered)" "$CALLS.page"
  grep -q "retried the undelivered zero-read page" "$(newest_tick)"
  if ls "$CVO_STATE"/zero-unmeasured-undelivered-* >/dev/null 2>&1; then false; fi   # cleared only once Slack accepted
  # and a marker that STILL cannot be delivered fails the tick closed before any family runs
  printf 'zero-read UNMEASURED (undelivered page) x ledger 1-2: y\n' > "$CVO_STATE/zero-unmeasured-undelivered-uvn-status-free"
  : > "$CALLS"
  STUB_SLACK_RC=1 run -1 "$SCRIPT"
  [ "$(applies)" -eq 0 ]
  if ! ls "$CVO_STATE"/zero-unmeasured-undelivered-* >/dev/null 2>&1; then false; fi
  grep -q "still cannot be delivered" "$(newest_tick)"
  rm -f "$CVO_STATE"/zero-unmeasured-undelivered-*
}

@test "outbound tick (p1 / n1 #1545 + ruling B): the zero-read runs over exactly each apply's new ledger rows; STOP kills the whole run, UNMEASURED stops only its own family's segment" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  run -0 "$SCRIPT"
  [ "$(wc -l < "$CALLS.zero" | tr -d ' ')" -eq 2 ]                 # the two free applies
  grep -q -- "--ledger-ids 1-2" "$CALLS.zero"; grep -q -- "--ledger-ids 3-4" "$CALLS.zero"
  # STOP (rc=1): an unexplained credit-class message - the auto-kill for the WHOLE run (unchanged)
  rm -f "$CVO_ETC/credit-verify-outbound.disabled" "$CALLS.zero"
  STUB_ZERO_RC=1 run -1 "$SCRIPT"
  grep -q "zero-read STOP" "$CVO_ETC/credit-verify-outbound.disabled"
  # UNMEASURED (rc=2), ruling B: NOT the whole tick. The family's users carry the verdict on their own outcome rows,
  # #clio_devops is paged, this batch's segment stops, and the tick continues (rc 0) to the next family - the global
  # kill file is NOT written and NO persistent marker wedges the family across ticks.
  rm -f "$CVO_ETC/credit-verify-outbound.disabled" "$CALLS.zero" "$CALLS.page" "$CVO_STATE"/zero-unmeasured-*
  STUB_ZERO_RC=2 STUB_ZERO_RC_ONCE=1 run -0 "$SCRIPT"
  [ ! -e "$CVO_ETC/credit-verify-outbound.disabled" ]; [ ! -e "$CVO_STATE/credit-verify-outbound.disabled" ]
  grep -q "zero-read UNMEASURED" "$(newest_tick)"
  grep -q "this segment stops here" "$(newest_tick)"
  grep -q "zero-read UNMEASURED" "$CALLS.page"                    # #clio_devops paged the same minute
  if ls "$CVO_STATE"/zero-unmeasured-* >/dev/null 2>&1; then false; fi   # no persistent marker: no indefinite wedge
  python3 - "$CVO_OUT_ROOT" <<'PY'
import glob, json, sys
# the batch's outcomes balance per user: each user in the batch's ledger range carries the zero-read verdict on their row
# QA on #1406 / Fable r3 note 2: OUT_ROOT is keyed by a MINUTE-resolution STAMP, and this test runs the script three
# times in sequence - when a minute boundary falls between them there are two out dirs and the lexicographically first
# is the STOP run's, which carries no zero_read verdict (the flake: AssertionError None). Read the NEWEST run's.
app = sorted(glob.glob(sys.argv[1] + "/*/uvn-status-free-apply.json"))
assert app, "no uvn-status-free apply outcomes"
d = json.load(open(app[-1]))
rows = d.get("outcomes") or []
assert d.get("zero_read", {}).get("verdict") == "UNMEASURED", d.get("zero_read")
assert rows, "no outcome rows"
for r in rows:
    if not r.get("user"):
        continue
    # the user's OWN row carries the verdict: annotated where the row existed, appended where it did not
    assert r.get("zero_read") == "unmeasured" or r.get("result") == "zero_read_unmeasured", r
print("outcomes balance: %d row(s), verdict %s" % (len(rows), d["zero_read"]["verdict"]))
PY
  # the NEXT tick runs the family again (ruling B stops a batch segment, never the family)
  # ruling B stops THIS batch's segment, not the family forever: the next tick runs the family again
  : > "$CALLS"; STUB_ZERO_RC=0 run -0 "$SCRIPT"
  grep -q -- "--segment free --campaign uvn-status " "$CALLS"
  grep -q -- "--segment free --campaign status-doc-received" "$CALLS"
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
  grep -q "LIVE REFUSED: the zero-read reader" "$(newest_tick)"
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
  grep -q "wrote $CVO_STATE/credit-verify-outbound.disabled" "$(newest_tick)"
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
  grep -q "BOTH kill-file writes FAILED" "$(newest_tick)"
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
  printf '%s\n' "$DEP" > "$CVO_DEPLOYED_SHA"
  printf '{"generated_at": "x", "signed_on": "%s", "claims": [{"claim_id": 1, "user_id": 5}]}' "$DEP" > "$CVO_STATE.claims.json"
  CVO_CLAIM_LIST="$CVO_STATE.claims.json" run -0 "$SCRIPT"
  grep -q -- "--segment free --campaign uvn-status .*--mode apply --max-users 2 " "$CALLS"   # 10 - 8 credit rows
  grep -q -- "^claim-proof-ask .*--segment free .*--mode apply --max-users 1" "$CALLS"        # 4 - 3 claim rows
}

@test "outbound tick (Fable 10-30): the claim families run from the claim lane's list, FIRST on Sat/Sun, after credit on weekdays; no list = skipped" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  printf '%s\n' "$DEP" > "$CVO_DEPLOYED_SHA"
  printf '{"generated_at": "x", "signed_on": "%s", "claims": [{"claim_id": 1, "user_id": 5}]}' "$DEP" > "$CVO_STATE.claims.json"
  export CVO_CLAIM_LIST="$CVO_STATE.claims.json"
  run -0 "$SCRIPT"
  grep -q -- "^claim-proof-ask --list .*/claims-filtered.json --segment free .*--mode apply --max-users 250" "$CALLS"
  grep -q -- "^claim-status --list .*/claims-filtered.json --segment free .*--mode apply" "$CALLS"
  if grep -q -- "^claim-.*--exclude-users" "$CALLS"; then false; fi
  first="$(grep -m1 -- "--mode apply" "$CALLS" | cut -d' ' -f1)"; [ "$first" = "uvn-status" ]
  : > "$CALLS"; rm -f "$CVO_LEDGER.segments.jsonl"
  CVO_DOW=6 run -0 "$SCRIPT"
  first="$(grep -m1 -- "--mode apply" "$CALLS" | cut -d' ' -f1)"; [ "$first" = "claim-proof-ask" ]
  grep -q "weekend: claim families first" "$(newest_tick)"
  : > "$CALLS"; rm -f "$CVO_CLAIM_LIST"
  run -0 "$SCRIPT"
  if grep -q "^claim-" "$CALLS"; then false; fi
  grep -q "claim families: no claim list" "$(newest_tick)"
}

@test "outbound tick (QA #1545 round 9): an UNMEASURED continuation still ADVANCES the paged family's cursor - a persistent unreadable source cannot starve every entry behind the same page" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  # the pre-fix shape: the continuation returned 0 without moving the cursor, so every later tick re-walked the SAME
  # page and a source that stayed unreadable for hours starved the rest of the family while the tick looked clean.
  [ ! -e "$CVO_STATE/cursor-uvn-status-free" ]
  STUB_ZERO_RC=2 run -0 "$SCRIPT"
  grep -q "uvn-status-free zero-read UNMEASURED" "$(newest_tick)"
  grep -q "uvn-status-free page: entries from 0 this tick; next tick starts at 200" "$(newest_tick)"
  [ ! -e "$CVO_ETC/credit-verify-outbound.disabled" ]
  # the cursor moved to the end of the page this apply walked (200 = the harness's page size), as a clean apply moves it
  [ -r "$CVO_STATE/cursor-uvn-status-free" ]
  [ "$(cat "$CVO_STATE/cursor-uvn-status-free")" = "200" ]
  # and the NEXT tick therefore walks the NEXT page, not the same one again
  rm -rf "$CVO_OUT_ROOT"; : > "$CALLS"
  STUB_ZERO_RC=2 run -0 "$SCRIPT"
  grep -q "uvn-status-free page: entries from 200 this tick" "$(newest_tick)"
}

@test "outbound tick (QA #1545 round 8): a zero-read CRASH (exit 1, no verdict line) is UNMEASURED, not a STOP - a transient timeout must never write the global kill file" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  # under `set -o pipefail` a reader traceback exits 1, and 1 means CONFIRMED STOP to the tick, whose answer is the
  # global kill file. The reader prints exactly one verdict line; no verdict = we could not look.
  STUB_ZERO_CRASH=1 run -0 "$SCRIPT"
  [ ! -e "$CVO_ETC/credit-verify-outbound.disabled" ]
  [ ! -e "$CVO_STATE/credit-verify-outbound.disabled" ]
  grep -q "zero-read UNMEASURED" "$(newest_tick)"
  grep -q "printed no verdict (a crash is not a STOP)" "$(newest_tick)"
  # the negative control stays exactly as it was: a real STOP verdict still kills the run
  rm -f "$CALLS.zero" "$CALLS.page" "$CVO_STATE"/zero-unmeasured-*
  STUB_ZERO_RC=1 run -1 "$SCRIPT"
  grep -q "zero-read STOP" "$CVO_ETC/credit-verify-outbound.disabled"
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

@test "outbound tick (QA #1587, p1 488): production mode with a claim list - claim-status applies only from its read-back date (17:55Z); claim-proof-ask is SIGNED-only, checked and never applied" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  printf '%s\n' "$DEP" > "$CVO_DEPLOYED_SHA"
  printf '{"generated_at": "x", "signed_on": "%s", "claims": [{"claim_id": 1, "user_id": 5}]}' "$DEP" > "$CVO_STATE.claims.json"
  export CVO_CLAIM_LIST="$CVO_STATE.claims.json" CVO_UNSIGNED_ALL=0
  at() { python3 -c 'import datetime as d,sys; print(int(d.datetime(2026,10,31,int(sys.argv[1]),int(sys.argv[2]),tzinfo=d.timezone.utc).timestamp()))' "$1" "$2"; }
  CVO_NOW_EPOCH="$(at 17 54)" run -0 "$SCRIPT"                      # before the read-back: nothing claim-side applies
  if grep -q -- "^claim-.*--mode apply" "$CALLS"; then false; fi
  grep -q -- "^claim-status --list .*--mode dry-run .*--check-recipients" "$CALLS"
  : > "$CALLS"; rm -f "$CVO_LEDGER.segments.jsonl"
  CVO_NOW_EPOCH="$(at 17 56)" run -0 "$SCRIPT"                      # after it: claim-status applies, claim-proof-ask never
  grep -q -- "^claim-status --list .*/claims-filtered.json --segment free .*--mode apply" "$CALLS"
  if grep -q -- "^claim-proof-ask .*--mode apply" "$CALLS"; then false; fi
  grep -q -- "^claim-proof-ask --list .*--mode dry-run .*--check-recipients" "$CALLS"
  grep -q "claim-proof-ask-free: SIGNED-only" "$(newest_tick)"
}

@test "outbound tick (p1 638 / r5 639): a claim list not signed on EXACTLY the deployed head is never checked - list_signed_on_stale, loud; the credit families still run" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  printf '%s\n' "$DEP" > "$CVO_DEPLOYED_SHA"
  export CVO_CLAIM_LIST="$CVO_STATE.claims.json"
  for signed in "$(printf 'e%.0s' $(seq 40))" "${DEP:0:12}" "" "$(printf 'D%.0s' $(seq 40))"; do
    : > "$CALLS"; rm -rf "$CVO_OUT_ROOT"
    printf '{"generated_at": "x", "signed_on": "%s", "claims": [{"claim_id": 1, "user_id": 5}]}' "$signed" > "$CVO_CLAIM_LIST"
    run -0 "$SCRIPT"
    if grep -q "^claim-" "$CALLS"; then false; fi                     # no check, no preview, no apply
    grep -q "claim families: list_signed_on_stale" "$(newest_tick)"
    grep -q "^uvn-status .*--mode apply" "$CALLS"                     # the credit families still ran
  done
  # an unreadable deployed sha refuses too, whatever the list says
  : > "$CALLS"; rm -rf "$CVO_OUT_ROOT"; rm -f "$CVO_DEPLOYED_SHA"
  printf '{"signed_on": "%s", "claims": [{"claim_id": 1, "user_id": 5}]}' "$DEP" > "$CVO_CLAIM_LIST"
  run -0 "$SCRIPT"
  if grep -q "^claim-" "$CALLS"; then false; fi
  # the exact head: checked
  printf '%s\n' "$DEP" > "$CVO_DEPLOYED_SHA"; : > "$CALLS"; rm -rf "$CVO_OUT_ROOT"
  run -0 "$SCRIPT"
  grep -q "^claim-status .*--check-recipients" "$CALLS"
}

@test "outbound tick (QA #1541): the exclude file holds claimants out of the claim families too; an unreadable claim list kills" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  printf '5\n' > "$CVO_ETC/credit-verify-outbound.exclude"
  printf '%s\n' "$DEP" > "$CVO_DEPLOYED_SHA"
  printf '{"generated_at": "x", "signed_on": "%s", "claims": [{"claim_id": 1, "user_id": 5}, {"claim_id": 2, "user_id": 6}]}' "$DEP" > "$CVO_STATE.claims.json"
  CVO_CLAIM_LIST="$CVO_STATE.claims.json" run -0 "$SCRIPT"
  grep -q "^claims-filtered.json 6$" "$CALLS.lists"
  if grep -qE "^claims(-filtered)?\.json .*\b5\b" "$CALLS.lists"; then false; fi
  if grep -q -- "--list $CVO_STATE.claims.json" "$CALLS"; then false; fi      # the raw list never reaches a runner
  grep -q "1 held out by the exclude file" "$(newest_tick)"
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
  grep -q "audiences: reply_due" "$(newest_tick)"
  grep -q "^reply-due.json 41$" "$CALLS.lists"
  # a deployed scan that fails stops the tick before any send
  : > "$CALLS"; printf 'import sys; sys.exit(3)\n' > "$TEST_TMPDIR/rd_scan.py"
  CVO_RD_SCAN="$TEST_TMPDIR/rd_scan.py" run -1 "$SCRIPT"
  [ "$(applies)" -eq 0 ]
  grep -q "reply_due builder failed" "$(newest_tick)"
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

@test "outbound tick (QA #1541, [key=uvn-daily-cap-400]): the runner's own campaign cap IS the policy file's (read in code) - the tick passes no cap through the environment; no multi-tick stall at 400" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  today="$(date -u +%F)"
  # 400 uvn-status sends already today (earlier ticks): the runner's DEFAULT cap would be exhausted
  python3 -c "import sqlite3,sys; d=sqlite3.connect(sys.argv[1]); d.executemany(\"INSERT INTO verify_messages (campaign, day, status, account_id) VALUES ('uvn-status', ?, 'sent', '5')\", [(sys.argv[2],)]*400); d.commit()" "$CVO_LEDGER" "$today"
  STUB_RUNNER_CAP_MODEL=1 run -0 "$SCRIPT"
  # r5 626: no env-moved cap - the runner reads the policy file itself, so the 401st message of the day still goes
  [ "$(sort -u "$CALLS.env")" = "- -" ]
  grep -q "uvn-status-free APPLY (rc=0): UVN STATUS: 250 sent" "$(newest_tick)"
}

@test "outbound tick (p1 579): the bodies and the judge's items are the check's ACCEPTED set, never the rendered cap; every artefact names the deploy head" {
  printf '%s\n' "$(printf 'a%.0s' $(seq 40))" > "$CVO_DEPLOYED_SHA"
  STUB_PREVIEW_USERS=1,2,3 STUB_ACCEPTED=1,3 run -0 "$SCRIPT"
  o=$(newest_out)
  [ "$(cd "$o/uvn-status-paid-bodies" && ls *.txt | tr '\n' ' ')" = "1.txt 3.txt " ]
  [ -e "$o/uvn-status-paid-bodies-not-accepted/2.txt" ] && [ -e "$o/uvn-status-paid-bodies-not-accepted/2.facts.json" ]
  [ "$(jq -r .user_id "$o/uvn-status-paid-items.jsonl" | tr '\n' ' ')" = "1 3 " ]
  [ "$(jq -r .deployed "$o/uvn-status-paid-items.jsonl" | sort -u)" = "$(cat "$CVO_DEPLOYED_SHA")" ]
  grep -q "tick start: .* deployed=$(cat "$CVO_DEPLOYED_SHA")" "$o/tick.log"
  grep -q "bodies == accepted: 2 kept, 1 rendered but not accepted moved aside, 0 accepted without a body" "$o/tick.log"
  # t01b 584: the body render is told the check's accepted set (it renders those, walking the whole list)
  grep -qE -- "--preview [^ ]*/uvn-status-paid-bodies --preview-accepted [^ ]*/uvn-status-paid-check.json" "$CALLS"
  # an accepted user with no rendered body, or a check file with no accepted set: no apply, the tick stops
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"
  # QA #1610: a check that accepted NOBODY (live flags on) is a no-apply family outcome, never an apply over the list
  rm -rf "$CVO_OUT_ROOT"; : > "$CALLS"
  STUB_ACCEPTED="" run -0 env STUB_ACCEPTED= "$SCRIPT"
  grep -q "uvn-status-paid: the check accepted nobody; no apply this tick" "$(newest_tick)"
  if grep -q -- "--segment paid --campaign uvn-status .*--mode apply" "$CALLS"; then false; fi
  for e in "STUB_ACCEPTED=1,4" "STUB_NO_ACCEPTED=1"; do
    rm -rf "$CVO_OUT_ROOT"; : > "$CALLS"
    run -1 env "$e" "$SCRIPT"
    grep -q "the rendered bodies are not the check's accepted set" "$(newest_tick)"
    [ "$(applies)" = 0 ]
  done
}

@test "outbound tick (QA #1612): the uvn page ROTATES across ticks by a per-family cursor; one tick's check, bodies and apply walk the same page" {
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"
  run -0 "$SCRIPT"
  # QA #1612: the page rotates - tick 1 walks from 0, the cursor moves to 200, then 400, then wraps to 0 (450 listed)
  [ "$(cat "$CVO_STATE/cursor-uvn-status-paid")" = "200" ]
  grep -q -- "^uvn-status .*--segment paid --campaign uvn-status .*--start-entry 0 " "$CALLS"
  for want in 400 0; do
    rm -rf "$CVO_OUT_ROOT"; run -0 "$SCRIPT"; [ "$(cat "$CVO_STATE/cursor-uvn-status-paid")" = "$want" ]
  done
  : > "$CALLS"; rm -rf "$CVO_OUT_ROOT"; echo 200 > "$CVO_STATE/cursor-uvn-status-paid"; run -0 "$SCRIPT"
  [ "$(grep -c -- "^uvn-status .*--segment paid --campaign uvn-status .*--start-entry 200 " "$CALLS")" -ge 2 ]   # check + bodies (+ apply): one page
  if grep -q -- "^uvn-status .*--segment paid --campaign uvn-status .*--start-entry [^2]" "$CALLS"; then false; fi
  # QA #1612 round 2: the run reached its cap at entry 260 (page.end) - the next tick starts THERE, not at 400
  echo 200 > "$CVO_STATE/cursor-uvn-status-paid"; rm -rf "$CVO_OUT_ROOT"
  STUB_PAGE_END=260 run -0 "$SCRIPT"; [ "$(cat "$CVO_STATE/cursor-uvn-status-paid")" = "260" ]
  # ... and a live apply that stopped earlier than its check (time / daily cap) moves it only to where the APPLY stopped
  echo 200 > "$CVO_STATE/cursor-uvn-status-paid"; rm -rf "$CVO_OUT_ROOT"
  STUB_PAGE_END=300 STUB_APPLY_PAGE_END=240 run -0 "$SCRIPT"; [ "$(cat "$CVO_STATE/cursor-uvn-status-paid")" = "240" ]
  # a step failing after the check (the body sample) leaves the page un-done: the cursor does not move
  echo 200 > "$CVO_STATE/cursor-uvn-status-paid"; rm -rf "$CVO_OUT_ROOT"
  STUB_PREVIEW_FAIL=1 run "$SCRIPT"; [ "$(cat "$CVO_STATE/cursor-uvn-status-paid")" = "200" ]
}
