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
# the status-returning variant the stale-page marker must use: 0 only on a CONFIRMED post (QA #1796)
slack_notify_critical_status() { printf '%s\n' "$*" >> "$CALLS.page-confirmed"; return ${STUB_SLACK_CONFIRM_RC:-0}; }
# the real lib's on-call mention IDs (they live there, so the fixture carries them too)
SLACK_UID_NICK="U0AL36NADEY"; SLACK_UID_AARON="U7RP6HKUZ"
# the status-aware poster the reader alarm must use: 0 only on a CONFIRMED post (QA #1758)
slack_notify_payload_file_status() { cat "$1" >> "$CALLS.page-confirmed"; return ${STUB_SLACK_CONFIRM_RC:-0}; }
SH
  export CALLS="$TEST_TMPDIR/calls.log"; : > "$CALLS"
  export CVO_TICK_HARD_S=999999 CVO_CHECK_S_PER_USER=0 CVO_RESERVE_PAD_S=0   # the deadline rails have their own tests
  # spec-deploy-lock-deferral-m1: the retry schedules are constants in production; the arms shrink them to 0 s
  export CVO_APPLY_RETRY_SLEEPS="0 0 0 0 0" CVO_TRANSIENT_RETRY_SLEEPS="0 0 0"
  export CVO_TIMEOUT_BIN="$(command -v timeout)"
  cat > "$TEST_TMPDIR/runner.py" <<'PY'
import json, os, sys
a = sys.argv[1:]
open(os.environ["CALLS"], "a").write(" ".join(a) + "\n")
mode = a[a.index("--mode") + 1]
if os.environ.get("STUB_FAIL_LIST") and "--list" in a and \
        os.path.basename(a[a.index("--list") + 1]).startswith(os.environ["STUB_FAIL_LIST"]):
    print("stub: this list's step fails"); sys.exit(1)          # a family whose step fails, by list name
if os.environ.get("STUB_SLEEP") and mode == os.environ.get("STUB_SLEEP_MODE") and (mode == "apply" or "--check-recipients" in a):
    import time; time.sleep(float(os.environ["STUB_SLEEP"]))
if mode != "apply" and os.environ.get("STUB_CHECK_RC") and (
        not os.environ.get("STUB_CHECK_RC_SUB") or a[0] == os.environ["STUB_CHECK_RC_SUB"]):
    # QA #1799 r14: a check that COSTS time. The retry-fit test needs a step whose own duration is measurable, because
    # the property under test is "the sleep PLUS a repeat of the step fits", not "the sleep fits".
    if os.environ.get("STUB_CHECK_SLEEP"):
        import time; time.sleep(float(os.environ["STUB_CHECK_SLEEP"]))
    # spec-deploy-lock-deferral-m1: the runner's TRANSIENT exit (Trino said "retry in a few minutes") is rc=4
    print("Credit review uvn-status: Trino is transiently unavailable; nothing was sent for this step.")
    sys.exit(int(os.environ["STUB_CHECK_RC"]))
if mode == "apply" and os.environ.get("STUB_APPLY_LOCK_TIMES") and (
        not os.environ.get("STUB_APPLY_LOCK_SUB") or a[0] == os.environ["STUB_APPLY_LOCK_SUB"]):
    # a deploy holds the apply lock EXCLUSIVE: the runner exits 3 with NOTHING attempted - no rows, no outcomes file
    _f = os.environ["CALLS"] + ".lockn"
    _n = int(open(_f).read()) if os.path.exists(_f) else 0
    open(_f, "w").write(str(_n + 1))
    if _n < int(os.environ["STUB_APPLY_LOCK_TIMES"]):
        print("Credit review uvn-status: a deploy holds the apply lock; nothing sent (re-run after it)")
        # QA #1799 r11: the real runner prints this marker on stderr ONLY for a genuinely held/unopenable lock
        print("APPLY_LOCK_HELD: a deploy holds the apply lock", file=sys.stderr)
        sys.exit(3)
if mode == "apply" and os.environ.get("STUB_APPLY_HARD_RC3") and (
        not os.environ.get("STUB_APPLY_LOCK_SUB") or a[0] == os.environ["STUB_APPLY_LOCK_SUB"]):
    # QA #1799 r11: the OTHER rc=3 - a hard refusal (cap-short / signed-set mismatch / HEAD_REFUSED). Nothing was
    # attempted, the ledger is unchanged, and there is NO held-lock marker. It must never be retried or deferred.
    print("Credit review uvn-status: the sent set is not the signed accepted set; nothing sent")
    sys.exit(3)
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
    # [key=note-step-timeout]: a note step whose outcome is UNKNOWN rides the user's own row - never a refusal
    for res in ([("timeout", "the note step timed out; outcome unknown")] * int(os.environ.get("STUB_TIMEOUTS", "0"))
                + [("error", "the gate raised RuntimeError")] * int(os.environ.get("STUB_ERRORS", "0"))
                # [key=post-failed-unknown]: the gate's POST FAILED - attempted, outcome unknown (rc 5 from the gate)
                + [("post_failed", "POST FAILED (curl rc=28)")] * int(os.environ.get("STUB_POST_FAILED", "0"))):
        doc["outcomes"].append({"user": "z" + str(len(doc["outcomes"])), "result": res[0], "reason": res[1]})
    if mode == "apply" and os.environ.get("STUB_REAL_POST_FAILED"):
        # QA #1756 Important 2: drive the REAL classifier (verify_notify._send_loop) with a gate that answers exactly
        # as scripts/intercom-verify-request.sh does after an ATTEMPTED post: rc=4 and "POST FAILED" on stderr. The row
        # this writes is what the tick's spike() must read - no synthetic post_failed row anywhere in this arm.
        sys.path.insert(0, os.environ["STUB_SCRIPTS"])
        from credit_review import verify_notify as vn
        _rep = vn.Report()
        def _gate(argv):
            return type("R", (), {"returncode": 4, "stdout": "",
                                  "stderr": "POST FAILED (curl rc=28); logged at /x and left CLAIMED\n"})()
        vn._send_loop([{"user": {"id": "z1"}, "credits": [{"request_id": "r1"}]}], _rep, mode="apply",
                      pace_seconds=0.0, pre=None, gate=_gate, extra=None, preview_dir=None, reminder=False)
        doc["outcomes"].extend(_rep.outcomes)
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
if mode == "apply" and os.environ.get("STUB_APPLY_LOCK"):
    # the real runner's deploy-lock path: it exits 3 BEFORE the first send, so NO rows and NO outcomes file are written
    print("Credit review uvn-status: a deploy holds the apply lock /var/lib/hydra/credit-review/apply.lock; nothing sent (re-run after it)")
    sys.exit(3)
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
if mode == "apply" and os.environ.get("STUB_APPLY_LOCK_AFTER_ROWS"):
    # rc=3 AND the lock prose AND rows already written: the lock word must not launder a partial send into a deferral
    print("Credit review uvn-status: a deploy holds the apply lock /var/lib/hydra/credit-review/apply.lock; nothing sent (re-run after it)")
    sys.exit(3)
if mode == "apply" and os.environ.get("STUB_APPLY_RC"):
    sys.exit(int(os.environ["STUB_APPLY_RC"]))   # rows were written above; the run then FAILS (a partial send)
if mode == "apply" and os.environ.get("STUB_APPLY_RC3_AFTER_SEND") and (
        not os.environ.get("STUB_APPLY_LOCK_SUB") or a[0] == os.environ["STUB_APPLY_LOCK_SUB"]):
    # QA #1799 r12 (Critical): credit-review.py returns 3 for a signed-set mismatch and for HEAD_REFUSED AFTER
    # args.fn() has already sent. Rows were written above, the ledger MOVED, and there is NO held-lock marker.
    print("Credit review uvn-status: the sent set is not the signed accepted set; nothing sent")
    sys.exit(3)
if mode == "apply" and os.environ.get("STUB_APPLY_LOCK_UNOPENABLE") and (
        not os.environ.get("STUB_APPLY_LOCK_SUB") or a[0] == os.environ["STUB_APPLY_LOCK_SUB"]):
    # QA #1799 r12 (carried): the lock could not be OPENED at all - a permissions/I-O fault, not contention.
    print("Credit review uvn-status: the apply lock /var/lock/x cannot be opened (PermissionError); nothing sent")
    print("APPLY_LOCK_UNOPENABLE: the apply lock /var/lock/x cannot be opened (PermissionError); nothing sent",
          file=sys.stderr)
    sys.exit(3)
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
  # QA #1574: with reply_due_scan.py in the tree the tick runs the REAL scan (Intercom + replica) - the harness default is
  # a scan path that does not exist (the tick's "not deployed" branch); the reply_due tests set their own stub
  export CVO_RD_SCAN="$TEST_TMPDIR/no-reply-due-scan.py"
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
        CVO_CLAIM_CAP=99999 CVO_REFUSAL_SPIKE=1.0 CVO_DOW=9 CVO_NEED_RUNNER="$E/n" CVO_UNSIGNED_ALL=1 CVO_NOW_EPOCH=1 CVO_JUDGE="$E/j" CVO_DEPLOYED_SHA="$E/d" CVO_CHECK_ENTRIES=99999 CVO_TICK_BUDGET_S=999999 CVO_TICK_HARD_S=999999 CVO_CHECK_S_PER_USER=0 CVO_RESERVE_PAD_S=0 CVO_APPLY_S_PER_USER=1 CVO_TICK_ELAPSED0=99 CVO_FULL_CAP_FROM_TEST=uvn-status=2000-01-01T00:00Z CVO_PER_SEGMENT_FROM_TEST=status-doc-received=2000-01-01T00:00Z CVO_PAID_FROM_TEST=proof-need-ask=2000-01-01T00:00Z CVO_TIMEOUT_BIN="$E/t"
        CVO_CLAIM_PROOF_STATE="$E/cpc" CVO_CLAIM_PROOF_LIMIT_H=999 CVO_CLAIM_PROOF_UNREAD_H=999 CVO_CLAIM_PROOF_REPEAT_MIN=999)
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
RD_CHECKS=400
RD_BUDGET=900
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
APPLY_S_PER_USER=40
APPLY_USER_WORST_S=200
TICK_ELAPSED0=0
FULL_CAP_FROM_TEST=
PER_SEGMENT_FROM_TEST=
PAID_FROM_TEST=
TIMEOUT_BIN=/usr/bin/timeout
CLAIM_PROOF_STATE=/var/lib/claim-proof-check
CLAIM_PROOF_LIMIT_H=30
CLAIM_PROOF_UNREAD_H=24
CLAIM_PROOF_REPEAT_MIN=360"
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
  # the budget is the r1 family's own: uvn-status (60 rows from its paid apply) does not charge it, and keeps its own
  # cap - which is now the POLICY's per-family tick_cap (uvn-status/free = 60, 2026-11-04), not FIRST_CAP=100: the free
  # uvn apply was losing its outcomes artefact at ~80 users when its Intercom-note step hit the subprocess timeout, and
  # the cap is the only lever that fits inside the tick until #1756 lands.
  [ "$(grep -- '--segment free .*--campaign uvn-status .*--mode apply' "$CALLS" | grep -o -- '--max-users [0-9]*' | head -1)" = "--max-users 60" ]
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
  # RE-CALIBRATED 2026-11-04 with the per-family tick cap: at CHECK_S_PER_USER=4 the worst case for the capped
  # uvn-status-free segment fell to 2*60*4+300 = 780 s, which FITS in the remaining 1900 s - so the fixture stopped
  # exercising a family that cannot start and started asserting the opposite. The property under test is unchanged;
  # the arithmetic that expresses it is now 2*60*60+300 = 7500 s at 60 s/user, which cannot fit and must not start.
  CVO_TICK_ELAPSED0=5000 CVO_CHECK_S_PER_USER=60 CVO_RESERVE_PAD_S=300 CVO_TICK_HARD_S=6900 run -0 "$SCRIPT"
  if grep -q -- "--check-recipients" "$CALLS"; then false; fi
  grep -q "it does not fit before the 6900s deadline; this family waits for the next tick" "$(newest_tick)"
  # THE FLAKE THIS FIXTURE WAS (b1/c3 2026-11-04: `Bats (1/2)` red three times on three heads of the SAME tree).
  # This half used CVO_TICK_ELAPSED0=6870 against a 6900 s deadline - THIRTY real seconds for the rest of the tick - and
  # asserted the exact `--max-users` that fits. `elapsed()` reads the WALL CLOCK, so the asserted number is a function
  # of how long the shard took: at 6870 it is 2 or 1 or nothing; at 6600 it is 20 or 19 (I measured 19 on the very run
  # that "should" have said 20). Widening the margin does not fix that - it only moves which integer drifts. A fixture
  # that asserts an exact value derived from the wall clock measures the SHARD, not the code (the same class as the
  # absolute-date bomb in tests/test_gdpr_pipeline.py:3183).
  # So this asserts the INVARIANT that actually matters, with no clock in it: the batch never exceeds what fits in the
  # remaining budget (300 s / 15 s a user = 20), it is at least one, and the "apply cut from N to M" line names the
  # SAME M the runner was called with - so a mutant that always cuts to 1, or one that never cuts, both go red.
  : > "$CALLS"; rm -f "$CVO_LEDGER.segments.jsonl"
  CVO_TICK_BUDGET_S=999999 CVO_TICK_ELAPSED0=6600 CVO_CHECK_S_PER_USER=0 CVO_RESERVE_PAD_S=0 CVO_TICK_HARD_S=6900 CVO_APPLY_S_PER_USER=15 run -0 "$SCRIPT"
  cut="$(grep -oE -- "--mode apply --max-users [0-9]+" "$CALLS" | head -1 | grep -oE "[0-9]+$")"
  [ -n "$cut" ]
  [ "$cut" -ge 1 ] && [ "$cut" -le 20 ]                      # never more than 300 s / 15 s can hold
  grep -qE "apply cut from [0-9]+ to ${cut} \(what fits before the 6900s deadline\)" "$(newest_tick)"
  # and not one single apply anywhere in the run may exceed the budget
  ! grep -qE -- "--mode apply --max-users (2[1-9]|[3-9][0-9]|[1-9][0-9][0-9]+) " "$CALLS"
}

@test "outbound tick (QA #1587): every subprocess runs under the deadline - a slow read-only check is stopped there and the tick ends (lock released); a slow APPLY cut at the deadline writes the kill file" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  # 20 s before the deadline, a check that would take 120 s: stopped at ~20 s, the tick ends, nothing applied, no kill
  #
  # THE FLAKE THIS FIXTURE WAS (b1 2026-11-07, PR Validation run 42312173001, `Bats (2/2)` red on a tree whose only
  # change was 12 new tests in this file): this half used CVO_TICK_ELAPSED0=6897 against a 6900 s deadline - THREE real
  # seconds of headroom - and `elapsed()` reads the WALL CLOCK from TICK_T0, which is stamped at the top of the script
  # (credit-verify-outbound.sh:275) BEFORE the ledger migration, the plan build and the audience reads. On the 2-CPU
  # ARC pod that startup took 4 s, so the first family was reached at `6901s into the tick` and every family was
  # skipped as "does not fit before the 6900s deadline" - the tick exited 0 and the `run -1` assertion failed. The
  # code was right; the fixture measured the SHARD's startup time, not the deadline wrapper (the same class as the
  # wall-clock `--max-users` assertion in the test above, and the absolute-date bomb in tests/test_gdpr_pipeline.py).
  # 20 s of headroom is 5x the observed CI startup and still finishes well inside the duration bound below.
  t0=$(date +%s)
  STUB_SLEEP_MODE=dry-run STUB_SLEEP=120 CVO_TICK_BUDGET_S=999999 CVO_TICK_ELAPSED0=6880 CVO_TICK_HARD_S=6900 run -1 "$SCRIPT"
  [ $(( $(date +%s) - t0 )) -lt 45 ]
  grep -q "check hit the 6900s deadline (read-only, stopped); the tick ends" "$(newest_tick)"
  [ "$(applies)" -eq 0 ]; [ ! -e "$CVO_ETC/credit-verify-outbound.disabled" ]
  # the lock is released: the next tick runs at once
  run -0 "$SCRIPT"
  if grep -q "another tick holds" "$(newest_tick)"; then false; fi
  # an apply that runs past the deadline: stopped there, and the kill file is written (a human reads it back)
  : > "$CALLS"; rm -f "$CVO_LEDGER.segments.jsonl"
  STUB_SLEEP_MODE=apply STUB_SLEEP=30 CVO_TICK_BUDGET_S=999999 CVO_TICK_ELAPSED0=6880 CVO_TICK_HARD_S=6900 CVO_APPLY_S_PER_USER=1 CVO_APPLY_USER_WORST_S=1 run -1 "$SCRIPT"
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

@test "outbound tick ([key=post-failed-unknown], Fable driver 02:2xZ): a POST FAILED row stops the family as OUTCOME-UNKNOWN, never as a refusal spike" {
  # intercom-verify-request.sh exits 5 when it ATTEMPTED the post and cannot prove it was not delivered, and the runner
  # records that user's row as post_failed. That row is neither a delivery nor a refusal: counting it as a refusal would
  # blame the users, and ignoring it would let a note that may have reached a customer pass as a clean run. One such row
  # is enough - unknown has no ratio, and the kill names the users it cannot vouch for.
  touch "$CVO_ETC/credit-verify-outbound.live"
  STUB_ROWS=3 STUB_POST_FAILED=2 run -1 "$SCRIPT"
  [ -e "$CVO_ETC/credit-verify-outbound.disabled" ]
  # the label says what happened: never "refusal spike", and it names the count it cannot verify.
  # NOT a bare `! grep`: bats takes the FINAL command's status and `!` is exempt from errexit, so a
  # non-final `! grep` cannot fail the test - a reason carrying BOTH labels would stay green.
  if grep -q "refusal spike" "$CVO_ETC/credit-verify-outbound.disabled"; then false; fi
  grep -q "UNKNOWN outcome" "$CVO_ETC/credit-verify-outbound.disabled"
}

@test "outbound tick (QA #1756 Important 2): the REAL runner classifies the gate's POST FAILED as post_failed, and the tick's spike() reads that row" {
  # The arm above injects the row. This one drives the real classifier: verify_notify._send_loop is handed a gate that
  # answers exactly as scripts/intercom-verify-request.sh does after an attempted POST (rc=4, "POST FAILED" on stderr),
  # and the outcomes file it writes is the one the tick reads. Before the fix the loop recorded that return as a plain
  # `failed`, so the tick's post_failed arm could never fire and one unknown POST was scored as an ordinary failure.
  touch "$CVO_ETC/credit-verify-outbound.live"
  STUB_ROWS=3 STUB_REAL_POST_FAILED=1 STUB_SCRIPTS="$CVO_SCRIPTS" run -1 "$SCRIPT"
  [ -e "$CVO_ETC/credit-verify-outbound.disabled" ]
  # same trap as the arm above: a non-final `! grep` is exempt from errexit and cannot fail the test
  if grep -q "refusal spike" "$CVO_ETC/credit-verify-outbound.disabled"; then false; fi
  grep -q "UNKNOWN outcome" "$CVO_ETC/credit-verify-outbound.disabled"
  grep -q "POST FAILED" "$CVO_ETC/credit-verify-outbound.disabled"
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

@test "outbound tick (2026-11-04 Fable ruling): the per-family per-tick cap LOWERS one segment and leaves every other family alone" {
  # Why this key exists at all: the free uvn-status apply sends until its Intercom-note step hits the subprocess
  # timeout (~55-60 min, ~80 users), dies with rc=1 and never writes its outcomes artefact - twice in one afternoon
  # (39 sends at 15:05Z, 79 at 17:24Z). CVO_CAP is ONE global value, so using it to slow this family would also have
  # slowed r1, claim-status and c2's approved 70-send claim install. This drives the real call site for all three.
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"
  CVO_UNSIGNED_ALL=0 run -0 "$SCRIPT"
  # the capped segment: 60, not FIRST_CAP's 100
  [ "$(grep -- '--segment free .*--campaign uvn-status .*--max-users [0-9]*' "$CALLS" | grep -o -- '--max-users [0-9]*' | head -1)" = "--max-users 60" ]
  grep -q "per-family tick cap: policy tick_cap\[uvn-status\]\[free\] holds this segment at 60" "$(newest_tick)"
  # the sibling segment of the SAME family is untouched (no tick_cap[uvn-status][paid])
  [ "$(grep -- '--segment paid .*--campaign uvn-status .*--max-users [0-9]*' "$CALLS" | grep -o -- '--max-users [0-9]*' | head -1)" != "--max-users 60" ]
  # and another family is untouched: claim-status keeps its own cap
  ! grep -q "policy tick_cap\[claim-status\]" "$(newest_tick)"
}

@test "outbound tick: the per-family tick cap can only LOWER a cap - a policy value above the family's own cap is inert" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  # a tick_cap that tries to RAISE free uvn-status to 9999 must change nothing: 9999 > the cap it was handed
  cp "$CVO_POLICY" "$TEST_TMPDIR/p-raise.json"        # a COPY: the policy file is shared by every case in this file
  python3 - "$TEST_TMPDIR/p-raise.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["tick_cap"]["uvn-status"]["free"] = 9999
json.dump(d, open(p, "w"))
PY
  CVO_POLICY="$TEST_TMPDIR/p-raise.json" CVO_UNSIGNED_ALL=0 run -0 "$SCRIPT"
  ! grep -q "9999" "$(newest_tick)"
  [ "$(grep -- '--segment free .*--campaign uvn-status .*--max-users [0-9]*' "$CALLS" | grep -o -- '--max-users [0-9]*' | head -1)" = "--max-users 100" ]
}

@test "outbound tick: a MALFORMED tick_cap value holds the capped family at one user - a cap must never grow because a value could not be parsed" {
  # Reachable case: the policy is valid JSON (so the tick's own arming read succeeds) but the tick_cap value is junk.
  # A control that silently falls back to the BIGGER cap when its knob is unreadable is the fail-open form of itself.
  touch "$CVO_ETC/credit-verify-outbound.live"
  cp "$CVO_POLICY" "$TEST_TMPDIR/p-bad.json"
  python3 - "$TEST_TMPDIR/p-bad.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["tick_cap"]["uvn-status"]["free"] = "sixty"
json.dump(d, open(p, "w"))
PY
  CVO_POLICY="$TEST_TMPDIR/p-bad.json" CVO_UNSIGNED_ALL=0 run -0 "$SCRIPT"
  grep -q "policy tick_cap\[uvn-status\]\[free\] is not a non-negative integer" "$(newest_tick)"
  grep -q "per-family tick cap: policy tick_cap\[uvn-status\]\[free\] holds this segment at 1" "$(newest_tick)"
}

@test "outbound tick (QA #1770 finding 1): a PRESENT but non-object top-level tick_cap is MALFORMED, never 'absent' - every family holds at one user" {
  # "tick_cap": "sixty" is valid JSON, so the arming read passes; the old reader treated it exactly like a missing key
  # and free uvn-status ran at 100 instead of the documented floor. Present-and-unreadable is the fail-closed case.
  touch "$CVO_ETC/credit-verify-outbound.live"
  for junk in '"sixty"' 'null' '[60]'; do
    cp "$CVO_POLICY" "$TEST_TMPDIR/p-top.json"
    python3 - "$TEST_TMPDIR/p-top.json" "$junk" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["tick_cap"] = json.loads(sys.argv[2])
json.dump(d, open(p, "w"))
PY
    rm -rf "$CVO_OUT_ROOT"; : > "$CALLS"
    CVO_POLICY="$TEST_TMPDIR/p-top.json" CVO_UNSIGNED_ALL=0 run -0 "$SCRIPT"
    grep -q "top-level tick_cap is present but not an object - holding uvn-status/free at 1 user" "$(newest_tick)"
    [ "$(grep -- '--segment free .*--campaign uvn-status .*--max-users [0-9]*' "$CALLS" | grep -o -- '--max-users [0-9]*' | head -1)" = "--max-users 1" ]
    # and it is EVERY family, not just the one with a row: a key nobody can read holds all of them (r1 has no row)
    grep -q "holding status-doc-received/paid at 1 user" "$(newest_tick)"
    grep -q "r1-free: per-family tick cap: policy tick_cap\[status-doc-received\]\[free\] holds this segment at 1" "$(newest_tick)"
  done
}

@test "outbound tick (QA #1770 finding 2): an integer Bash cannot hold is still ONLY ever a lower bound - the comparison is Python's, not '['" {
  # 9223372036854775808 passes isinstance(int), failed BOTH Bash comparisons (`[` cannot parse it), and the old code
  # then emitted the value itself as the cap: an edited policy could RAISE a bound. Above the cap it must be inert.
  touch "$CVO_ETC/credit-verify-outbound.live"
  cp "$CVO_POLICY" "$TEST_TMPDIR/p-huge.json"
  python3 - "$TEST_TMPDIR/p-huge.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["tick_cap"]["uvn-status"]["free"] = 9223372036854775808
json.dump(d, open(p, "w"))
PY
  CVO_POLICY="$TEST_TMPDIR/p-huge.json" CVO_UNSIGNED_ALL=0 run -0 "$SCRIPT"
  ! grep -q "9223372036854775808" "$CALLS"
  [ "$(grep -- '--segment free .*--campaign uvn-status .*--max-users [0-9]*' "$CALLS" | grep -o -- '--max-users [0-9]*' | head -1)" = "--max-users 100" ]
  # the same value one digit SHORT of the cap-handed-in boundary: 99 < 100 lowers to 99 (the ordinary path still works)
  python3 - "$TEST_TMPDIR/p-huge.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["tick_cap"]["uvn-status"]["free"] = 99
json.dump(d, open(p, "w"))
PY
  rm -rf "$CVO_OUT_ROOT"; : > "$CALLS"
  CVO_POLICY="$TEST_TMPDIR/p-huge.json" CVO_UNSIGNED_ALL=0 run -0 "$SCRIPT"
  [ "$(grep -- '--segment free .*--campaign uvn-status .*--max-users [0-9]*' "$CALLS" | grep -o -- '--max-users [0-9]*' | head -1)" = "--max-users 99" ]
}

@test "outbound tick: a WHOLLY unreadable policy never reaches a family - the arming read kills the tick first (fail closed)" {
  # The deeper fail-closed path already existed and is asserted here so nobody later "simplifies" it away: an
  # unparseable policy at the arming read writes the kill file before any family is considered.
  touch "$CVO_ETC/credit-verify-outbound.live"
  printf '{not json' > "$TEST_TMPDIR/p-junk.json"
  CVO_POLICY="$TEST_TMPDIR/p-junk.json" CVO_UNSIGNED_ALL=0 run -1 "$SCRIPT"
  grep -qi "cap source unreadable" "$CVO_ETC/credit-verify-outbound.disabled"   # the FILE says "auto-kill ...", the LOG says "AUTO-KILL: ..."
  [ "$(applies)" -eq 0 ]
}

@test "outbound tick ([key=note-step-timeout]): a per-user timeout/error outcome is NOT a refusal in the spike ratio" {
  # The Python half of 749/d2: the note step records an unknown outcome on the user's OWN row ("timeout" / "error"),
  # never as a refusal - so a run whose note steps timed out must not read as a refusal spike. The ledger rows it wrote
  # still count as attempts, and the ratio is refused / (sent + refused): 0 refused of 12 attempts is a healthy run.
  # (The MISSING-artefact policy belongs to #1747: kill, naming the artefact. This arm is only about the ratio.)
  touch "$CVO_ETC/credit-verify-outbound.live"
  : > "$CALLS.page"
  STUB_ROWS=12 STUB_TIMEOUTS=5 STUB_ERRORS=2 run -0 "$SCRIPT"
  if grep -q "refusal spike" "$(newest_tick)"; then false; fi
  [ ! -e "$CVO_ETC/credit-verify-outbound.disabled" ]
  # the positive control: the same 12 attempts WITH refusals above the ratio still kills, so this measures the ratio
  STUB_ROWS=12 STUB_REFUSED=9 STUB_TIMEOUTS=2 run -1 "$SCRIPT"
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
  # Bind the outcomes assertion to THIS run's out dir (r6 on #1687 / #1763): OUT_ROOT is keyed by a
  # MINUTE-resolution stamp, so three sequential runs can leave two dirs, and reading "the newest by name"
  # then means reading the PREVIOUS run's file when the run under test wrote none - AssertionError None on a
  # shard that is otherwise green (it flaked red on #1672 while #1763 passed the same shard). The dir this run
  # just wrote is the newest by mtime, so take it here, while it is unambiguous.
  STUB_ZERO_RC=2 STUB_ZERO_RC_ONCE=1 run -0 "$SCRIPT"
  OUT_AFTER="$(newest_out)"
  [ ! -e "$CVO_ETC/credit-verify-outbound.disabled" ]; [ ! -e "$CVO_STATE/credit-verify-outbound.disabled" ]
  grep -q "zero-read UNMEASURED" "$(newest_tick)"
  grep -q "this segment stops here" "$(newest_tick)"
  grep -q "zero-read UNMEASURED" "$CALLS.page"                    # #clio_devops paged the same minute
  if ls "$CVO_STATE"/zero-unmeasured-* >/dev/null 2>&1; then false; fi   # no persistent marker: no indefinite wedge
  python3 - "$OUT_AFTER" <<'PY'
import glob, json, sys
# the batch's outcomes balance per user: each user in the batch's ledger range carries the zero-read verdict on their row
# QA on #1406 / Fable r3 note 2: OUT_ROOT is keyed by a MINUTE-resolution STAMP, and this test runs the script three
# times in sequence - when a minute boundary falls between them there are two out dirs and the lexicographically first
# is the STOP run's, which carries no zero_read verdict (the flake: AssertionError None). Read the NEWEST run's.
# sys.argv[1] is the out dir the UNMEASURED run wrote (newest by mtime, taken above), never a glob across runs.
app = glob.glob(sys.argv[1] + "uvn-status-free-apply.json")
assert app, "the run under test wrote no uvn-status-free apply outcomes in %s" % sys.argv[1]
d = json.load(open(app[0]))
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
  # verify-outbound-migration-race-m1: the pre-lock migration now notices an unopenable ledger FIRST, so the kill file
  # names the migration rather than the later cap read. The contract this test pins is unchanged: a durable kill file,
  # never a silent stall.
  grep -q "ledger" "$CVO_ETC/credit-verify-outbound.disabled"
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

@test "outbound tick (QA #1758 Important 1): two consecutive ticks of ONE reader outage carry the SAME cooldown key - the key is the watchdog's SIGNATURE, not a hash of text whose ages move" {
  # THE DEFECT: claim_proof_check_alarm hashed the watchdog's whole output. That text carries elapsed ages and counts,
  # so a persistent outage produced a NEW digest every two hours and paged every tick despite
  # CLAIM_PROOF_REPEAT_MIN=360 - a cooldown that never applied to the case it exists for.
  # The bats harness never pages by design (CVO_HARNESS=1, CI has no Slack), so this test proves the property the
  # cooldown rests on, end to end through the real watchdog: same outage + different ages => same signature.
  export CVO_CLAIM_PROOF_STATE="$TEST_TMPDIR/cpc" CVO_CLAIM_PROOF_LIMIT_H=30 CVO_CLAIM_PROOF_UNREAD_H=24 CVO_CLAIM_PROOF_REPEAT_MIN=360
  mkdir -p "$CVO_STATE" "$CVO_CLAIM_PROOF_STATE"
  # the shared fixture ledger has only the cap columns; the reader alarm reads request_ids_json/sent_at, and an
  # unreadable ledger would make every tick "cannot measure" (exit 2) and hide the signature this test is about
  export CVO_LEDGER="$TEST_TMPDIR/alarm.sqlite3"
  python3 -c "import sqlite3,sys; d=sqlite3.connect(sys.argv[1]); d.execute('CREATE TABLE verify_messages (id INTEGER PRIMARY KEY AUTOINCREMENT, campaign TEXT, day TEXT, status TEXT, account_id TEXT, request_ids_json TEXT, sent_at TEXT)'); d.commit()" "$CVO_LEDGER"
  rm -f "$CVO_STATE/claim-proof-check-alarm.log"
  touch "$CVO_ETC/credit-verify-outbound.live"
  age_fixture() {   # $1 = hours ago for both artefacts; the alarm CATEGORIES and identities never change
    python3 - "$CVO_CLAIM_PROOF_STATE" "$1" <<'PY'
import datetime, json, os, sys
state, hours = sys.argv[1], float(sys.argv[2])
stamp = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"owner": "claim-lane-resume-c2", "last_run_at": stamp, "asked": 262}, open(os.path.join(state, "last-run.json"), "w"))
json.dump({"batch": "proof-check-2026-11-04", "generatedAt": stamp, "asked": 0, "claims": []},
          open(os.path.join(state, "proof-check-2026-11-04-digest.json"), "w"))
PY
  }
  sig_of() { sed -n 's/.*SIGNATURE \([0-9a-f]\{16\}\).*/\1/p' "$CVO_STATE/claim-proof-check-alarm.log" | tail -1; }
  age_fixture 31
  run -0 "$SCRIPT"
  sig1="$(sig_of)"; [ -n "$sig1" ]
  grep -q 'ALARM stale: the daily code check last ran 31.0h ago' "$CVO_STATE/claim-proof-check-alarm.log"
  age_fixture 32                                                  # one hour older, SAME outage, same alarm set
  run -0 "$SCRIPT"
  sig2="$(sig_of)"
  grep -q 'ALARM stale: the daily code check last ran 32.0h ago' "$CVO_STATE/claim-proof-check-alarm.log"   # the text MOVED
  [ "$sig1" = "$sig2" ]                                           # ... and the key did NOT: this is the cooldown
  # a CHANGED alarm set is a changed key, so a worsening reader still pages at once rather than waiting out the window
  python3 - "$CVO_CLAIM_PROOF_STATE" <<'PY'
import json, os, sys
p = os.path.join(sys.argv[1], "proof-check-2026-11-04-digest.json")
d = json.load(open(p)); d["claims"] = [{"id": 900001, "status": "not_found"}]; d["asked"] = 1
json.dump(d, open(p, "w"))
PY
  run -0 "$SCRIPT"
  sig3="$(sig_of)"
  [ -n "$sig3" ]; [ "$sig3" != "$sig1" ]
  # and the tick reads that key, not the text: the marker digest comes from the SIGNATURE line
  grep -q 's/^SIGNATURE //p' "$SCRIPT"
}

@test "outbound tick (QA #1758 Important 2): a reader page Slack REFUSED does not start the repeat window - the tick says so and pages again next tick" {
  # THE DEFECT: the alarm keyed its cooldown on `if notify ...`, but notify cannot report a failed page - its last
  # command is the lib's best-effort slack_notify (`|| true`). So a rejected post (or missing credentials) read as
  # DELIVERED: the marker was written and CLAIM_PROOF_REPEAT_MIN silenced the reader outage for six hours.
  export CVO_CLAIM_PROOF_STATE="$TEST_TMPDIR/cpc" CVO_CLAIM_PROOF_LIMIT_H=30 CVO_CLAIM_PROOF_UNREAD_H=24 CVO_CLAIM_PROOF_REPEAT_MIN=360
  export CVO_ALARM_PAGE_IN_HARNESS=1
  mkdir -p "$CVO_STATE" "$CVO_CLAIM_PROOF_STATE"
  export CVO_LEDGER="$TEST_TMPDIR/alarm.sqlite3"
  python3 -c "import sqlite3,sys; d=sqlite3.connect(sys.argv[1]); d.execute('CREATE TABLE verify_messages (id INTEGER PRIMARY KEY AUTOINCREMENT, campaign TEXT, day TEXT, status TEXT, account_id TEXT, request_ids_json TEXT, sent_at TEXT)'); d.commit()" "$CVO_LEDGER"
  python3 - "$CVO_CLAIM_PROOF_STATE" <<'EOF'
import datetime, json, os, sys
state = sys.argv[1]
stamp = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=31)).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"owner": "claim-lane-resume-c2", "last_run_at": stamp, "asked": 262}, open(os.path.join(state, "last-run.json"), "w"))
json.dump({"batch": "proof-check-2026-11-04", "generatedAt": stamp, "asked": 0, "claims": []},
          open(os.path.join(state, "proof-check-2026-11-04-digest.json"), "w"))
EOF
  touch "$CVO_ETC/credit-verify-outbound.live"
  rm -f "$CVO_STATE/claim-proof-check.page" "$CVO_STATE/claim-proof-check-alarm.log" "$CALLS.page-confirmed"
  # (1) Slack refuses the post: stated, and NO marker - the next tick must page again rather than wait out the window
  STUB_SLACK_CONFIRM_RC=1 run -0 "$SCRIPT"
  grep -q "PAGE NOT DELIVERED (reader alarm): Slack rejected the post" "$CVO_STATE/claim-proof-check-alarm.log"
  [ ! -e "$CVO_STATE/claim-proof-check.page" ]
  # (2) the SAME outage, delivered this time: the page carries the on-call mentions and the window starts
  run -0 "$SCRIPT"
  grep -q '<@U0AL36NADEY> <@U7RP6HKUZ>' "$CALLS.page-confirmed"
  [ -s "$CVO_STATE/claim-proof-check.page" ]
  # (3) same signature inside the window: no second page (the cooldown the marker exists for)
  : > "$CALLS.page-confirmed"
  run -0 "$SCRIPT"
  [ ! -s "$CALLS.page-confirmed" ]
  unset CVO_ALARM_PAGE_IN_HARNESS
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

@test "outbound tick (Fable driver 2026-11-05 14:33Z): a stale claim list pages ONCE per (signed_on, deployed) pair, and a fresh list clears the marker" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  printf '%s\n' "$DEP" > "$CVO_DEPLOYED_SHA"
  export CVO_CLAIM_LIST="$CVO_STATE.claims.json"
  rm -f "$CVO_STATE/claim-list-stale-paged" "$CALLS.page-confirmed"
  stale() { printf '{"generated_at": "x", "signed_on": "%s", "claims": [{"claim_id": 1, "user_id": 5}]}' "$1" > "$CVO_CLAIM_LIST"; }
  stale "$(printf 'e%.0s' $(seq 40))"
  run -0 "$SCRIPT"
  [ "$(grep -c 'list_signed_on_stale' "$CALLS.page-confirmed")" -eq 1 ]  # first tick: one confirmed page
  : > "$CALLS.page-confirmed"
  run -0 "$SCRIPT"
  [ ! -s "$CALLS.page-confirmed" ]                                      # same pair: no second page
  grep -q "already paged for this pair" "$(newest_tick)"
  stale "$(printf 'D%.0s' $(seq 40))"
  run -0 "$SCRIPT"
  [ "$(grep -c 'list_signed_on_stale' "$CALLS.page-confirmed")" -eq 1 ]  # a different pair pages again
  stale "$DEP"
  run -0 "$SCRIPT"
  [ ! -e "$CVO_STATE/claim-list-stale-paged" ]                          # fresh list clears the marker
  stale "$(printf 'e%.0s' $(seq 40))"
  : > "$CALLS.page-confirmed"
  run -0 "$SCRIPT"
  [ "$(grep -c 'list_signed_on_stale' "$CALLS.page-confirmed")" -eq 1 ]  # the next stale event pages again
}

@test "outbound tick (QA #1796 Important 1): a stale-list page Slack did NOT confirm writes no marker and is retried next tick" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  printf '%s\n' "$DEP" > "$CVO_DEPLOYED_SHA"
  export CVO_CLAIM_LIST="$CVO_STATE.claims.json"
  rm -f "$CVO_STATE/claim-list-stale-paged" "$CALLS.page-confirmed"
  printf '{"generated_at": "x", "signed_on": "%s", "claims": [{"claim_id": 1, "user_id": 5}]}' "$(printf 'e%.0s' $(seq 40))" > "$CVO_CLAIM_LIST"
  STUB_SLACK_CONFIRM_RC=1 run -0 "$SCRIPT"
  [ ! -e "$CVO_STATE/claim-list-stale-paged" ]                          # a refused post is NOT a page
  grep -q "page NOT DELIVERED" "$(newest_tick)"
  : > "$CALLS.page-confirmed"
  run -0 "$SCRIPT"
  [ "$(grep -c 'list_signed_on_stale' "$CALLS.page-confirmed")" -eq 1 ]  # the next tick pages again
  [ -e "$CVO_STATE/claim-list-stale-paged" ]                            # and only then writes the marker
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

@test "outbound tick (QA #1574): the reply_due scan runs BOUNDED and walks one PAGE of its audience, the cursor carrying over" {
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"
  # a scan that records its own arguments and reports a page: 379 due, this run examined entries 0..250 (mostly HELD)
  cat > "$TEST_TMPDIR/rd_scan.py" <<'PY'
import json, sys
argv = sys.argv[1:]
open(sys.argv[sys.argv.index("--out") + 1] + ".argv", "w").write(" ".join(argv))
import os
end = int(os.environ.get("STUB_RD_SCAN_END") or 250)
json.dump({"generated_at": "x", "page": {"start": int(argv[argv.index("--start-entry") + 1]), "end": end, "listed": 379,
                                         "end_user": None if end >= 379 else 4242},
           "users": [{"user_id": "41", "paid": True, "reply_due": {"part": "9", "conversation": "7"}}]},
          open(sys.argv[sys.argv.index("--out") + 1], "w"))
print('{"rows": 1, "not_checked_after_checks": 129}')
PY
  CVO_RD_SCAN="$TEST_TMPDIR/rd_scan.py" run -0 "$SCRIPT"
  # the tick bounds the scan BEFORE the checks (the accept cap alone never bounded a mostly-held audience)
  argv="$(cat "$CVO_OUT_ROOT"/*/reply-due.json.argv)"
  [[ "$argv" == *"--max-checks 400"* ]]
  [[ "$argv" == *"--budget-seconds 900"* ]]
  [[ "$argv" == *"--cap 100"* ]]
  [[ "$argv" == *"--start-entry 0"* ]]
  # r5 (1574 finding 1): the SCAN is read-only, the PAGE is not - the cursor moves only after BOTH segments' step for
  # it is done. Here the family's step IS done (it ran), so the cursor moves to page.end ...
  [ "$(cat "$CVO_STATE/cursor-reply-due")" = "250" ]
  grep -q "reply-due page: entries from 0 this tick; next tick starts at 250" "$CVO_OUT_ROOT"/*/tick.log
  # ... and the NEXT tick starts the scan there instead of re-walking the held head
  rm -rf "$CVO_OUT_ROOT"; CVO_RD_SCAN="$TEST_TMPDIR/rd_scan.py" run -0 "$SCRIPT"
  [[ "$(cat "$CVO_OUT_ROOT"/*/reply-due.json.argv)" == *"--start-entry 250"* ]]
  # a page that reached the end of the list wraps to 0 (page_next), so the walk is a rotation, not a one-way stop
  rm -rf "$CVO_OUT_ROOT"; STUB_RD_SCAN_END=379 CVO_RD_SCAN="$TEST_TMPDIR/rd_scan.py" run -0 "$SCRIPT"
  [ "$(cat "$CVO_STATE/cursor-reply-due")" = "0" ]
  # a scan that fails (rc 3) stops the tick before any send and leaves the cursor where it was
  echo 250 > "$CVO_STATE/cursor-reply-due"; : > "$CALLS"
  printf 'import sys; sys.exit(3)\n' > "$TEST_TMPDIR/rd_scan.py"
  CVO_RD_SCAN="$TEST_TMPDIR/rd_scan.py" run -1 "$SCRIPT"
  [ "$(cat "$CVO_STATE/cursor-reply-due")" = "250" ]
  [ "$(applies)" -eq 0 ]
}

@test "outbound tick (QA #1574 round 7, Important): the cursor is the IDENTITY of the last examined row, not a position" {
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"
  # A position is not a resume point in a list that is rebuilt every run: the rows this tick sends are answered and
  # vanish from the next search, so every position behind them shifts up. page.end_user is the row, and the next tick
  # resumes after THAT.
  cat > "$TEST_TMPDIR/rd_scan_anchor.py" <<'PY'
# --start-after-user
import json, os, sys
argv = sys.argv[1:]
out = sys.argv[sys.argv.index("--out") + 1]
open(out + ".argv", "w").write(" ".join(argv))
end = int(os.environ.get("STUB_RD_SCAN_END") or 250)
json.dump({"generated_at": "x", "page": {"start": 0, "end": end, "listed": 379,
                                         "end_user": None if end >= 379 else 4242},
           "users": [{"user_id": "41", "paid": True, "reply_due": {"part": "9", "conversation": "7"}}]}, open(out, "w"))
PY
  CVO_RD_SCAN="$TEST_TMPDIR/rd_scan_anchor.py" run -0 "$SCRIPT"
  # a partial page pins the ROW it reached, alongside the position; the first run has no anchor to pass
  [ "$(cat "$CVO_STATE/cursor-reply-due-anchor")" = "4242" ]
  [[ "$(cat "$CVO_OUT_ROOT"/*/reply-due.json.argv)" != *"--start-after-user"* ]]
  # the next tick resumes AFTER that row (and still passes the position, for a runner that predates the flag)
  rm -rf "$CVO_OUT_ROOT"; CVO_RD_SCAN="$TEST_TMPDIR/rd_scan_anchor.py" run -0 "$SCRIPT"
  argv="$(cat "$CVO_OUT_ROOT"/*/reply-due.json.argv)"
  [[ "$argv" == *"--start-after-user 4242"* ]]
  [[ "$argv" == *"--start-entry 250"* ]]
  # a page that reached the end of the list has no row to resume after: the anchor is removed, so the cursor wraps
  rm -rf "$CVO_OUT_ROOT"; STUB_RD_SCAN_END=379 CVO_RD_SCAN="$TEST_TMPDIR/rd_scan_anchor.py" run -0 "$SCRIPT"
  [ ! -e "$CVO_STATE/cursor-reply-due-anchor" ]
  # a scan that does not support the flag gets no flag (never a failed tick), and still writes its own row record
  rm -rf "$CVO_OUT_ROOT"; echo 4242 > "$CVO_STATE/cursor-reply-due-anchor"
  cat > "$TEST_TMPDIR/rd_old.py" <<'PY'
import json, sys
out = sys.argv[sys.argv.index("--out") + 1]
json.dump({"generated_at": "x", "page": {"start": 0, "end": 5, "listed": 9, "end_user": 77}, "users": []}, open(out, "w"))
PY
  CVO_RD_SCAN="$TEST_TMPDIR/rd_old.py" run -0 "$SCRIPT"
  argv="$(cat "$CVO_STATE/cursor-reply-due-anchor")"
  [ "$argv" = "77" ]
}

@test "outbound tick (QA #1574 round 5, finding 1): a DEFERRED reply-due family does not commit the upstream cursor" {
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"
  cat > "$TEST_TMPDIR/rd_scan_up.py" <<'PY'
# --upstream-resume
import json, os, sys
out = sys.argv[sys.argv.index("--out") + 1]
tok = os.environ.get("STUB_UPSTREAM") or ""
json.dump({"generated_at": "x", "page": {"start": 0, "end": 0, "listed": 0},
           "upstream": {"candidates": tok or None, "apology": None},
           "users": [{"user_id": "41", "paid": True, "reply_due": {"part": "9", "conversation": "7"}}]}, open(out, "w"))
print('{"rows": 1}')
PY
  # the family DEFERS because its worst case cannot fit before the hard deadline (its own "does not fit" path), so
  # neither segment writes its .done marker - while the scan itself still runs and reports a token to resume from
  STUB_UPSTREAM="cDlwYWdlMg" CVO_TICK_ELAPSED0=5000 CVO_CHECK_S_PER_USER=40 CVO_RESERVE_PAD_S=300 CVO_TICK_HARD_S=6900     CVO_RD_SCAN="$TEST_TMPDIR/rd_scan_up.py" run -0 "$SCRIPT"
  out="$(ls -d "$CVO_OUT_ROOT"/*)"
  # ... and the upstream state must NOT be committed: the rows this walk collected never reached anybody, so resuming
  # past them next tick would answer nobody about them, ever
  [ ! -e "$CVO_STATE/cursor-reply-due-upstream.json" ]
  grep -q "reply-due: the page is NOT done" "$out/tick.log"
  # the same tick with budget DOES commit it, so this test measures the gate and not the stub
  rm -rf "$CVO_OUT_ROOT"
  STUB_UPSTREAM="cDlwYWdlMg" CVO_RD_SCAN="$TEST_TMPDIR/rd_scan_up.py" run -0 "$SCRIPT"
  [ "$(jq -r .candidates "$CVO_STATE/cursor-reply-due-upstream.json")" = "cDlwYWdlMg" ]
}

@test "outbound tick (r5 1574 finding 3): a STARVED upstream walk is resumed next tick, and a completed one clears the cursor" {
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"
  # a scan that supports --upstream-resume (the flag is IN the file, which is how the tick detects support) and reports
  # where its walk stopped
  cat > "$TEST_TMPDIR/rd_scan_up.py" <<'PY'
# --upstream-resume
import json, os, sys
argv = sys.argv[1:]
out = sys.argv[sys.argv.index("--out") + 1]
open(out + ".argv", "w").write(" ".join(argv))
tok = os.environ.get("STUB_UPSTREAM") or ""
json.dump({"generated_at": "x", "page": {"start": 0, "end": 0, "listed": 0},
           "upstream": {"candidates": tok or None, "apology": None},
           "users": [{"user_id": "41", "paid": True, "reply_due": {"part": "9", "conversation": "7"}}]}, open(out, "w"))
print('{"rows": 1}')
PY
  STUB_UPSTREAM="cDlwYWdlMg" CVO_RD_SCAN="$TEST_TMPDIR/rd_scan_up.py" run -0 "$SCRIPT"
  out="$(ls -d "$CVO_OUT_ROOT"/*)"
  # the tick passes the cursor file, because this runner advertises support for it
  # (the rendered argv is made with printf %q, so compare the flag and the basename rather than the joined string)
  [[ "$(cat "$out/reply-due.json.argv")" == *--upstream-resume*cursor-reply-due-upstream.json* ]]
  # and persists what the walk returned, so the next tick resumes past the pages this one already read
  [ "$(jq -r .candidates "$CVO_STATE/cursor-reply-due-upstream.json")" = "cDlwYWdlMg" ]
  rm -rf "$CVO_OUT_ROOT"; CVO_RD_SCAN="$TEST_TMPDIR/rd_scan_up.py" run -0 "$SCRIPT"
  [[ "$(cat "$CVO_OUT_ROOT"/*/reply-due.json.argv)" == *"--upstream-resume"* ]]   # still resumed, now from the saved file
  # a COMPLETE walk reports nulls: the file is removed, so the rotation wraps instead of pinning a stale token
  rm -rf "$CVO_OUT_ROOT"; STUB_UPSTREAM="" CVO_RD_SCAN="$TEST_TMPDIR/rd_scan_up.py" run -0 "$SCRIPT"
  if [ -e "$CVO_STATE/cursor-reply-due-upstream.json" ]; then false; fi
  # a runner that predates the flag is never passed it (its argv has no --upstream-resume), so an older deployed scan
  # keeps working: it restarts its walk, slower but never wrong
  cat > "$TEST_TMPDIR/rd_scan_old.py" <<'PY'
import json, sys
out = sys.argv[sys.argv.index("--out") + 1]
open(out + ".argv", "w").write(" ".join(sys.argv[1:]))
json.dump({"generated_at": "x", "page": {"start": 0, "end": 0, "listed": 0}, "users": []}, open(out, "w"))
print('{"rows": 0}')
PY
  rm -rf "$CVO_OUT_ROOT"; CVO_RD_SCAN="$TEST_TMPDIR/rd_scan_old.py" run -0 "$SCRIPT"
  if [[ "$(cat "$CVO_OUT_ROOT"/*/reply-due.json.argv)" == *"--upstream-resume"* ]]; then false; fi
}

@test "outbound tick (QA #1574 round 6): the search token and the start position are ONE pair - the token moves only when the page wrapped, so a partly-walked slice is rebuilt and continued, never skipped" {
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"
  # a scan that advertises --upstream-resume, reports a page from the env, and reports the token its walk stopped at
  cat > "$TEST_TMPDIR/rd_scan_pair.py" <<'PY'
# --upstream-resume
import json, os, sys
argv = sys.argv[1:]
out = sys.argv[sys.argv.index("--out") + 1]
open(out + ".argv", "w").write(" ".join(argv))
st = int(argv[argv.index("--start-entry") + 1])
end = int(os.environ.get("STUB_PAIR_END") or 0)
listed = int(os.environ.get("STUB_PAIR_LISTED") or 0)
tok = os.environ.get("STUB_PAIR_TOKEN") or ""
json.dump({"generated_at": "x", "page": {"start": st, "end": end, "listed": listed, "unwalked": listed - end},
           "upstream": {"candidates": tok or None, "apology": None},
           "users": [{"user_id": "41", "paid": True, "reply_due": {"part": "9", "conversation": "7"}}]}, open(out, "w"))
print('{"rows": 1}')
PY
  rm -rf "$CVO_OUT_ROOT"
  # --- tick 1: the slice holds 20 rows, this tick walks 0..5. The position (5) is INSIDE the slice the CURRENT token
  # builds, so the token reported by the walk (C1) must NOT be written: resuming the search at C1 next tick would point
  # the position 5 into a different slice - the first five users of that slice, and the whole of it when it holds fewer
  # than five, would never be checked.
  STUB_PAIR_END=5 STUB_PAIR_LISTED=20 STUB_PAIR_TOKEN="C1" CVO_RD_SCAN="$TEST_TMPDIR/rd_scan_pair.py" run -0 "$SCRIPT"
  [ "$(cat "$CVO_STATE/cursor-reply-due")" = "5" ]                       # the position did move: real progress
  if [ -e "$CVO_STATE/cursor-reply-due-upstream.json" ]; then false; fi   # the token was held
  grep -q "the search token is HELD on this slice" "$(newest_tick)"
  # --- tick 2: same token, so the SAME slice is rebuilt and the walk continues at the position it stopped at
  o="$CVO_OUT_ROOT"; rm -rf "$CVO_OUT_ROOT"
  STUB_PAIR_END=20 STUB_PAIR_LISTED=20 STUB_PAIR_TOKEN="C2" CVO_RD_SCAN="$TEST_TMPDIR/rd_scan_pair.py" run -0 "$SCRIPT"
  [[ "$(cat "$CVO_OUT_ROOT"/*/reply-due.json.argv)" == *"--start-entry 5"* ]]
  # --- the slice was walked to its end (end == listed), so the pair wraps together: position 0 AND the new token
  [ "$(cat "$CVO_STATE/cursor-reply-due")" = "0" ]
  [ "$(jq -r .candidates "$CVO_STATE/cursor-reply-due-upstream.json")" = "C2" ]
  # --- a held token is not OVERWRITTEN either: an existing C0 survives a partial page
  printf '{"candidates":"C0"}' > "$CVO_STATE/cursor-reply-due-upstream.json"
  echo 3 > "$CVO_STATE/cursor-reply-due"; rm -rf "$CVO_OUT_ROOT"
  STUB_PAIR_END=9 STUB_PAIR_LISTED=20 STUB_PAIR_TOKEN="C9" CVO_RD_SCAN="$TEST_TMPDIR/rd_scan_pair.py" run -0 "$SCRIPT"
  [ "$(jq -r .candidates "$CVO_STATE/cursor-reply-due-upstream.json")" = "C0" ]
  # and the negative control: a WRAPPED page does commit, so this is the pair rule and not a ban on writing
  rm -rf "$CVO_OUT_ROOT"
  STUB_PAIR_END=20 STUB_PAIR_LISTED=20 STUB_PAIR_TOKEN="C10" CVO_RD_SCAN="$TEST_TMPDIR/rd_scan_pair.py" run -0 "$SCRIPT"
  [ "$(jq -r .candidates "$CVO_STATE/cursor-reply-due-upstream.json")" = "C10" ]
}

@test "outbound tick (r5 1574 finding 1): the reply_due cursor moves only when the family's step for that page is DONE - a starved family leaves it where it was" {
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"
  cat > "$TEST_TMPDIR/rd_scan.py" <<'PY'
import json, sys
argv = sys.argv[1:]
json.dump({"generated_at": "x", "page": {"start": int(argv[argv.index("--start-entry") + 1]), "end": 250, "listed": 379},
           "users": [{"user_id": "41", "paid": True, "reply_due": {"part": "9", "conversation": "7"}}]},
          open(sys.argv[sys.argv.index("--out") + 1], "w"))
print('{"rows": 1}')
PY
  # the family that owns this page FAILS its step (a check or an apply that did not do the page).
  # The cursor used to advance the moment the SCAN returned 0, so a failing tick cost the PAGE - every answerable user
  # on it was skipped by the next tick's start-entry. Scanned is not done.
  [ ! -e "$CVO_STATE/cursor-reply-due" ]
  STUB_FAIL_LIST=reply-due.json CVO_RD_SCAN="$TEST_TMPDIR/rd_scan.py" run -1 "$SCRIPT"
  grep -q "reply-due-paid: check failed; tick stops" "$CVO_OUT_ROOT"/*/tick.log
  [ ! -e "$CVO_STATE/cursor-reply-due" ]                  # never written: the page is still owed
  if grep -q "reply-due page: entries from 0 this tick" "$CVO_OUT_ROOT"/*/tick.log; then false; fi
  # and the negative control: the same scan with a deadline that fits DOES advance, so this is a bound and not a ban
  rm -rf "$CVO_OUT_ROOT"
  CVO_RD_SCAN="$TEST_TMPDIR/rd_scan.py" run -0 "$SCRIPT"
  [ "$(cat "$CVO_STATE/cursor-reply-due")" = "250" ]
}

@test "outbound tick (r5 1574 finding 1, round 2): a DEFERRED reply_due segment does not move the cursor, because a 0 return is not completion" {
  touch "$CVO_ETC/credit-verify-outbound.live" "$CVO_ETC/credit-verify-outbound.paid-enabled"
  cat > "$TEST_TMPDIR/rd_scan2.py" <<'PY'
import json, sys
argv = sys.argv[1:]
json.dump({"generated_at": "x", "page": {"start": int(argv[argv.index("--start-entry") + 1]), "end": 250, "listed": 379},
           "users": [{"user_id": "41", "paid": True, "reply_due": {"part": "9", "conversation": "7"}}]},
          open(sys.argv[sys.argv.index("--out") + 1], "w"))
print('{"rows": 1}')
PY
  [ ! -e "$CVO_STATE/cursor-reply-due" ]
  # SIGNED-only is a DEFERRAL, not completion: family() logs it and returns 0 without touching the page, so the cursor
  # must stay put. Before this, "both families returned 0" read as done and the page was skipped for the next tick.
  CVO_UNSIGNED_ALL=0 CVO_RD_SCAN="$TEST_TMPDIR/rd_scan2.py" run -0 "$SCRIPT"
  grep -q "reply-due-paid: SIGNED-only family" "$CVO_OUT_ROOT"/*/tick.log
  grep -q "reply-due: the page is NOT done" "$CVO_OUT_ROOT"/*/tick.log
  [ ! -e "$CVO_STATE/cursor-reply-due" ]
  # negative control: the same page with the family armed DOES advance, so this is a bound and not a ban
  rm -rf "$CVO_OUT_ROOT"
  CVO_RD_SCAN="$TEST_TMPDIR/rd_scan2.py" run -0 "$SCRIPT"
  [ "$(cat "$CVO_STATE/cursor-reply-due")" = "250" ]
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
  # 60, not 250: TWO caps now bound this apply and the SMALLER wins - the runner's own daily row from the policy file
  # (2500/day, still read in code and never passed through the environment, which is what this test is for) and the
  # per-family per-tick tick_cap introduced 2026-11-04 (uvn-status/free = 60). If the tick cap ever stops being
  # consulted this line goes back to 250 and says so.
  grep -q "uvn-status-free APPLY (rc=0): UVN STATUS: 60 sent" "$(newest_tick)"
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

# ---- spec-deploy-lock-deferral-m1 (Fable 2026-11-05 12:4xZ + addenda 14:3xZ / 14:4xZ) -------------------------
# Three ticks in one day lost the claim families - the only family with a real send queue - because an earlier family's
# failure ended the tick before claim_families() ran. A TRANSIENT condition (a deploy holding the apply lock, Trino
# saying "retry in a few minutes") must cost that family, never the families behind it.

claim_list() {   # a claim list signed on the deployed head, so the claim families actually run
  printf '%s\n' "$DEP" > "$CVO_DEPLOYED_SHA"
  printf '{"generated_at": "x", "signed_on": "%s", "claims": [{"claim_id": 1, "user_id": 5}]}' "$DEP" > "$CVO_STATE.claims.json"
  export CVO_CLAIM_LIST="$CVO_STATE.claims.json"
}

@test "outbound tick (spec-deploy-lock-deferral-m1, the 12:29:37Z shape): an apply that meets a held lock released 90 s later SENDS the family and completes - it does not stop the tick" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  rm -f "$CVO_ETC/credit-verify-outbound.disabled" "$CALLS.lockn"
  # the deploy held the lock for the FIRST attempt only; the retry finds it free. Before the fix the first rc=3 was
  # terminal: "apply failed rc=3; tick stops", 0 sent, and every family behind it starved.
  STUB_APPLY_LOCK_TIMES=1 run -0 "$SCRIPT"
  grep -q "apply lock busy/transient (a deploy holds the apply lock); retry 1/5" "$(newest_tick)"
  grep -q "APPLY (rc=0)" "$(newest_tick)"
  [ ! -e "$CVO_ETC/credit-verify-outbound.disabled" ]
  grep -q "tick done" "$(newest_tick)"
  if grep -q "tick deferred" "$(newest_tick)"; then false; fi
}

@test "outbound tick (spec-deploy-lock-deferral-m1): a lock held past the window DEFERS cleanly - exit 2, no kill file, no refusal, no cursor move, and the claim families still run" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  claim_list
  rm -f "$CVO_ETC/credit-verify-outbound.disabled" "$CALLS.lockn" "$CVO_STATE"/cursor-*
  # every attempt meets the deploy's exclusive hold: the family defers, the tick continues to the claims and exits 2
  STUB_APPLY_LOCK_TIMES=99 STUB_APPLY_LOCK_SUB=uvn-status run -2 "$SCRIPT"
  grep -q "apply deferred - a deploy holds the apply lock" "$(newest_tick)"
  grep -q "credit families: deferred (transient); continuing to the next family group" "$(newest_tick)"
  grep -q "tick deferred: a transient condition" "$(newest_tick)"
  [ ! -e "$CVO_ETC/credit-verify-outbound.disabled" ]          # a deferral is never a kill
  [ ! -e "$CVO_STATE/credit-verify-outbound.disabled" ]
  if grep -q "refusal spike" "$(newest_tick)"; then false; fi   # and never a refusal-ratio operand
  [ ! -e "$CVO_STATE/cursor-uvn-status-free" ]                  # the DEFERRED family's page is not done: no cursor move
  grep -q -- "^claim-proof-ask .*--mode apply" "$CALLS"         # the families behind it still ran
  grep -q -- "^claim-status .*--mode apply" "$CALLS"
}

@test "outbound tick (QA #1799 r11): an unchanged-ledger rc=3 WITHOUT the held-lock marker is a HARD REFUSAL - no retry, no deferral, the tick stops" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  claim_list
  rm -f "$CVO_ETC/credit-verify-outbound.disabled" "$CALLS.lockn"
  # cap-short / signed-set mismatch / HEAD_REFUSED: rc=3, nothing attempted, ledger unchanged, no marker. Before the
  # fix this was retried as "a deploy holds the apply lock", then deferred, and the tick went on to later groups and
  # exited 2 - a hard refusal laundered into a transient one.
  STUB_APPLY_HARD_RC3=1 STUB_APPLY_LOCK_SUB=uvn-status run -1 "$SCRIPT"
  grep -q "apply rc=3 WITHOUT the held-lock marker" "$(newest_tick)"
  grep -q "apply failed rc=3; tick stops" "$(newest_tick)"
  if grep -q "apply lock busy/transient" "$(newest_tick)"; then false; fi   # never retried
  if grep -q "apply deferred" "$(newest_tick)"; then false; fi              # never deferred
  if grep -q "tick deferred" "$(newest_tick)"; then false; fi
  if grep -q -- "^claim-" "$CALLS"; then false; fi                          # the hard stop is preserved
  [ ! -e "$CVO_ETC/credit-verify-outbound.disabled" ]
}

@test "outbound tick (QA #1799 r12 Critical): rc=3 without the marker but a CHANGED ledger is a PARTIAL SEND - the post-send rails run" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  claim_list
  rm -f "$CVO_ETC/credit-verify-outbound.disabled" "$CALLS.lockn" "$CALLS.health"
  cat > "$TEST_TMPDIR/health.py" <<'PY'
import os, sys
open(os.environ["CALLS"] + ".health", "a").write(" ".join(sys.argv[1:]) + "\n")
print('{"verdict": "healthy"}')
PY
  # signed-set mismatch / HEAD_REFUSED fire AFTER the sends, so the ledger moved and no marker was printed. An early
  # return here skipped the partial-send detection and every rail below it - the rails that exist to catch exactly this.
  STUB_APPLY_RC3_AFTER_SEND=1 STUB_APPLY_LOCK_SUB=uvn-status run -1 "$SCRIPT"
  grep -q "apply rc=3 WITHOUT the held-lock marker AND a CHANGED ledger" "$(newest_tick)"
  grep -q "a partial send; the post-send rails own it" "$(newest_tick)"
  [ -s "$CALLS.health" ] || false          # the health rail RAN: the early return is gone
  if grep -q -- "^claim-" "$CALLS"; then false; fi
}

@test "outbound tick (QA #1799 r12 carried): an UNOPENABLE apply lock is a hard stop - never retried, never deferred" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  claim_list
  rm -f "$CVO_ETC/credit-verify-outbound.disabled" "$CALLS.lockn"
  # ApplyLockError covered BOTH contention and a lock that could not be opened, so a permissions/I-O fault was
  # reported as "a deploy holds the lock", retried, deferred, and the tick went on into later groups.
  STUB_APPLY_LOCK_UNOPENABLE=1 STUB_APPLY_LOCK_SUB=uvn-status run -1 "$SCRIPT"
  grep -q "the apply lock could not be OPENED" "$(newest_tick)"
  grep -q "apply failed rc=3; tick stops" "$(newest_tick)"
  if grep -q "apply lock busy/transient" "$(newest_tick)"; then false; fi
  if grep -q "apply deferred" "$(newest_tick)"; then false; fi
  if grep -q "tick deferred" "$(newest_tick)"; then false; fi
  if grep -q -- "^claim-" "$CALLS"; then false; fi
  [ ! -e "$CVO_ETC/credit-verify-outbound.disabled" ]
}

@test "outbound tick (QA #1799 r12): the unopenable-lock marker is the runner's too" {
  local tick_marker runner_marker
  tick_marker="$(grep -m1 '^APPLY_LOCK_UNOPENABLE_MARKER=' "$SCRIPT" | cut -d'"' -f2)"
  runner_marker="$(grep -m1 '^APPLY_LOCK_UNOPENABLE_MARKER = ' "$BATS_TEST_DIRNAME/../credit_review/verify_notify.py" | cut -d'"' -f2)"
  [ -n "$tick_marker" ]
  [ "$tick_marker" = "$runner_marker" ]
}

@test "outbound tick (QA #1799 r11): the tick's marker constant is the runner's - a rename on one side cannot silently disable the retry" {
  # the tick greps for APPLY_LOCK_MARKER; the runner prints verify_notify.APPLY_LOCK_MARKER. If they drift, every held
  # lock becomes a hard stop (loud, but a lost family) - so pin them equal here rather than discovering it in prod.
  local tick_marker runner_marker
  tick_marker="$(grep -m1 '^APPLY_LOCK_MARKER=' "$SCRIPT" | cut -d'"' -f2)"
  runner_marker="$(grep -m1 '^APPLY_LOCK_MARKER = ' "$BATS_TEST_DIRNAME/../credit_review/verify_notify.py" | cut -d'"' -f2)"
  [ -n "$tick_marker" ]
  [ "$tick_marker" = "$runner_marker" ]
}

@test "outbound tick (spec-deploy-lock-deferral-m1): a REAL failed apply (rc!=0 with a CHANGED ledger) still stops the tick before the claims" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  claim_list
  rm -f "$CVO_ETC/credit-verify-outbound.disabled" "$CALLS.lockn"
  # the runner wrote rows and THEN failed: the ledger moved, so this is a partial send, not a deferral
  STUB_APPLY_RC=1 run -1 "$SCRIPT"
  grep -q "apply failed rc=1; tick stops" "$(newest_tick)"
  if grep -q -- "^claim-" "$CALLS"; then false; fi
  if grep -q "tick deferred" "$(newest_tick)"; then false; fi
}

@test "outbound tick (spec-deploy-lock-deferral-m1): the wait is BOUNDED - the retry cap stops the loop, it never runs past it" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  rm -f "$CVO_ETC/credit-verify-outbound.disabled" "$CALLS.lockn"
  # a 0 s cap: the first rc=3 is already past it, so exactly ONE apply attempt is made and the family defers
  CVO_APPLY_RETRY_CAP_S=0 STUB_APPLY_LOCK_TIMES=99 STUB_APPLY_LOCK_SUB=uvn-status run -2 "$SCRIPT"
  [ "$(grep -c -- "^uvn-status .*--mode apply" "$CALLS")" = 1 ]
  grep -q "apply deferred" "$(newest_tick)"
}

@test "outbound tick (spec-deploy-lock-deferral-m1 addendum, the 14:25:53Z shape): a Trino transient in uvn-status-free still lets the claim families run and send" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  claim_list
  rm -f "$CVO_ETC/credit-verify-outbound.disabled" "$CALLS.lockn"
  # Trino answers "retry in a few minutes" (rc=4) for the uvn-status family's check, every attempt
  STUB_CHECK_RC=4 STUB_CHECK_RC_SUB=uvn-status run -2 "$SCRIPT"
  grep -q "check deferred - Trino is transiently unavailable" "$(newest_tick)"
  grep -q "credit families: deferred (transient); continuing to the next family group" "$(newest_tick)"
  grep -q -- "^claim-proof-ask .*--mode apply" "$CALLS"          # the claims ran and sent
  grep -q -- "^claim-status .*--mode apply" "$CALLS"
  [ ! -e "$CVO_ETC/credit-verify-outbound.disabled" ]
  if grep -q "refusal spike" "$(newest_tick)"; then false; fi
}

@test "outbound tick (QA #1799 r13): a transient retry that does not FIT the tick budget defers at once - it never sleeps past the budget and starves the families behind it" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  claim_list
  rm -f "$CVO_ETC/credit-verify-outbound.disabled" "$CALLS.lockn"
  # The retry is LONGER THAN THE WHOLE BUDGET, so it cannot fit no matter how much of the budget is left. Clipping the
  # sleep to TICK_HARD_S (the old behaviour) let it sleep past TICK_BUDGET_S, and every later family then skipped on its
  # own budget check - the exact starvation this PR exists to prevent. A retry that does not fit is not a retry: defer
  # now, and the claims still run.
  # The budget is left WHOLE (ELAPSED0=0) on purpose: an earlier version spent all but 5s of it, which made the claim
  # assertions below depend on the runner reaching them within 5 real seconds. That is a wall-clock race, not the
  # property under test - on a slow CI box every family logged "tick budget 300s reached" and the test went red.
  STUB_CHECK_RC=4 STUB_CHECK_RC_SUB=uvn-status CVO_TRANSIENT_RETRY_SLEEPS="400 600 1200" \
    CVO_TICK_BUDGET_S=300 CVO_TICK_ELAPSED0=0 CVO_TICK_HARD_S=6900 run -2 "$SCRIPT"
  grep -q "a 400s retry does not fit in the" "$(newest_tick)"
  grep -q "left of the 300s budget" "$(newest_tick)"
  if grep -q "Trino transient (rc=4); retry 1/3" "$(newest_tick)"; then false; fi   # never slept
  grep -q -- "^claim-proof-ask .*--mode apply" "$CALLS"          # the claims still ran
  grep -q -- "^claim-status .*--mode apply" "$CALLS"
  [ ! -e "$CVO_ETC/credit-verify-outbound.disabled" ]
}

@test "outbound tick (QA #1799 r14): a retry that only just fits the SLEEP but not the retry itself defers - the step's own cost is part of the fit" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  claim_list
  rm -f "$CVO_ETC/credit-verify-outbound.disabled" "$CALLS.lockn"
  # The exact boundary QA asked for. The step costs 10s and the next retry sleep is 30s, with ~35s of budget left: the
  # SLEEP alone fits (30 < 35), so the old `wait > left` check retried - and the retry then finished at 30+10 = 40s,
  # past the budget, so every family behind it skipped. The whole retry (sleep + a repeat of the step) does not fit.
  STUB_CHECK_RC=4 STUB_CHECK_RC_SUB=uvn-status STUB_CHECK_SLEEP=10 CVO_TRANSIENT_RETRY_SLEEPS="30 60 120" \
    CVO_TICK_BUDGET_S=300 CVO_TICK_ELAPSED0=253 CVO_TICK_HARD_S=6900 run -2 "$SCRIPT"
  grep -q "a 30s retry does not fit in the" "$(newest_tick)"
  grep -q "the step itself just took 10s" "$(newest_tick)"
  if grep -q "Trino transient (rc=4); retry 1/3" "$(newest_tick)"; then false; fi   # never slept, never retried
  grep -q -- "^claim-proof-ask .*--mode apply" "$CALLS"          # the claims still ran
  grep -q -- "^claim-status .*--mode apply" "$CALLS"
  [ ! -e "$CVO_ETC/credit-verify-outbound.disabled" ]
}

@test "outbound tick (QA #1799 r13): an apply retry that does not FIT the tick budget defers at once too" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  claim_list
  rm -f "$CVO_ETC/credit-verify-outbound.disabled" "$CALLS.lockn"
  # the same clip on the apply loop, and the same reason for leaving the budget whole: a retry longer than the whole
  # budget cannot fit whatever is left of it, so the deferral is deterministic and nothing depends on runner speed.
  STUB_APPLY_LOCK_TIMES=5 STUB_APPLY_LOCK_SUB=uvn-status CVO_APPLY_RETRY_SLEEPS="400 600 1200" \
    CVO_TICK_BUDGET_S=300 CVO_TICK_ELAPSED0=0 CVO_TICK_HARD_S=6900 run -2 "$SCRIPT"
  grep -q "a 400s retry does not fit in the" "$(newest_tick)"
  grep -q "apply deferred - a deploy holds the apply lock and no retry fits the tick budget" "$CALLS.page"
  if grep -q "apply lock busy/transient" "$(newest_tick)"; then false; fi   # never slept
  [ ! -e "$CVO_ETC/credit-verify-outbound.disabled" ]
}

@test "outbound tick (QA #1799 r14): the apply loop counts the attempt's own cost in the fit too" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  claim_list
  rm -f "$CVO_ETC/credit-verify-outbound.disabled" "$CALLS.lockn"
  # Same boundary on the apply loop: the attempt costs 10s and the next retry sleep is 15s with ~20s of budget left, so
  # the SLEEP alone fits (15 < 20) and the old check retried - finishing at 15+10 = 25s, past the budget.
  STUB_SLEEP_MODE=apply STUB_SLEEP=10 STUB_APPLY_LOCK_TIMES=5 STUB_APPLY_LOCK_SUB=uvn-status \
    CVO_APPLY_RETRY_SLEEPS="15 30 60 60 120" CVO_TICK_BUDGET_S=300 CVO_TICK_ELAPSED0=268 CVO_TICK_HARD_S=6900 \
    run -2 "$SCRIPT"
  grep -q "a 15s retry does not fit in the" "$(newest_tick)"
  grep -q "the attempt itself just took 10s" "$(newest_tick)"
  if grep -q "apply lock busy/transient" "$(newest_tick)"; then false; fi   # never slept, never retried
  [ ! -e "$CVO_ETC/credit-verify-outbound.disabled" ]
}

@test "outbound tick (spec-deploy-lock-deferral-m1 addendum 2): the weekday/weekend ORDER is unchanged - a deferral never reorders the groups" {
  touch "$CVO_ETC/credit-verify-outbound.live"
  claim_list
  rm -f "$CVO_ETC/credit-verify-outbound.disabled" "$CALLS.lockn"
  STUB_CHECK_RC=4 STUB_CHECK_RC_SUB=uvn-status run -2 "$SCRIPT"
  first="$(grep -m1 -- "--mode apply" "$CALLS" | cut -d' ' -f1)"; [ "$first" = "claim-proof-ask" ]   # credit deferred, claims next
  : > "$CALLS"; rm -rf "$CVO_OUT_ROOT"
  CVO_DOW=6 STUB_CHECK_RC=4 STUB_CHECK_RC_SUB=claim-proof-ask run -2 "$SCRIPT"
  grep -q "weekend: claim families first" "$(newest_tick)"
  first="$(grep -m1 -- "--mode apply" "$CALLS" | cut -d' ' -f1)"; [ "$first" = "uvn-status" ]        # claims deferred, credit next
}

@test "outbound tick (verify-outbound-migration-race-m1): the ledger is migrated ONCE, BEFORE the tick lock - a reader can never race a migration a family started mid-tick" {
  # the ordering is the fix: a migration inside the tick (after flock) is exactly the 11:49:02Z race
  mig="$(grep -n 'verify_ledger.connect(sys.argv\[2\]).close()' "$SCRIPT" | head -1 | cut -d: -f1)"
  lock="$(grep -n 'exec 9>>"\$STATE/tick.lock"' "$SCRIPT" | head -1 | cut -d: -f1)"
  [ -n "$mig" ] && [ -n "$lock" ] && [ "$mig" -lt "$lock" ]
  grep -q "ledger migration failed" "$SCRIPT"
}

# -- the wait-apology family (fable d2 / firstmate 772 + 774) -----------------------------------------

apology_stub() {
  # a stand-in for scripts/credit_review/wait_apology_audience.py: it speaks the CLI (--plan-dir/--segment/--out/--cap)
  # and does what the real one does on its three outcomes (a list, INERT rc=2, a failure rc=1).
  cat > "$TEST_TMPDIR/apology.py" <<'PY'
import json, os, sys
a = sys.argv[1:]
open(os.environ["CALLS"] + ".apology", "a").write(" ".join(a) + "\n")
rc = int(os.environ.get("STUB_APOLOGY_RC", "0"))
if rc:
    print("INERT: the approval-hold scan is unreadable" if rc == 2 else "builder boom")
    sys.exit(rc)
json.dump({"generated_at": "2026-11-05T03:00:00Z", "campaign": "wait-apology",
           "users": [{"user_id": 41, "paid": True, "skip": None, "request_ids": ["r1"]}]},
          open(a[a.index("--out") + 1], "w"))
print('{"users": 1, "excluded": {}}')
PY
  export CVO_APOLOGY_BUILDER="$TEST_TMPDIR/apology.py"
  export CVO_APOLOGY_PLAN_ROOT="$TEST_TMPDIR/paid-status"
  mkdir -p "$CVO_APOLOGY_PLAN_ROOT/$(date -u +%F)/paid" "$CVO_APOLOGY_PLAN_ROOT/$(date -u +%F)/free"
}

@test "outbound tick (wait-apology): an INERT audience builder sends NOTHING and pages - a missing exclusion source is never an unfiltered list" {
  apology_stub
  : > "$CALLS.apology"
  STUB_APOLOGY_RC=2 run -0 "$SCRIPT"
  # the builder WAS asked, and refused: no runner call carries --campaign wait-apology at all.
  # QA #1788 finding 3: `! grep` is a NEGATED command and bash exempts those from `set -e`, so an unreadable or
  # missing $CALLS would pass this line GREEN. The explicit form fails on a match AND on a read error.
  grep -q -- "--segment paid" "$CALLS.apology"
  if grep -q -- "--campaign wait-apology" "$CALLS"; then false; fi
  grep -q "builder INERT" "$(newest_tick)"
  grep -q "wait-apology" "$CALLS.page"
}

@test "outbound tick (wait-apology): a builder FAILURE (anything but INERT) autokills - an unknown audience is never a skipped one" {
  apology_stub
  STUB_APOLOGY_RC=1 run -1 "$SCRIPT"
  [ -e "$CVO_ETC/credit-verify-outbound.disabled" ]
  grep -q "audience builder failed" "$CVO_ETC/credit-verify-outbound.disabled"
}

@test "outbound tick (wait-apology): a built audience reaches the ONE sender with the campaign and the segment, paid first" {
  apology_stub
  export CVO_UNSIGNED_ALL=1
  run -0 "$SCRIPT"
  # paid is built and sent before free (d2: paid first), and both go through the uvn-status runner as wait-apology
  local paid_at free_at
  paid_at="$(grep -n "check --segment paid.*campaign wait-apology\|--segment paid" "$CALLS" | head -1 | cut -d: -f1)"
  cat "$(newest_tick)" >> "$BATS_TEST_DIRNAME/dbg-apology.log" 2>/dev/null || true
  cat "$CALLS" >> "$BATS_TEST_DIRNAME/dbg-apology-calls.log" 2>/dev/null || true
  grep -q -- "--campaign wait-apology" "$CALLS"
  [ "$(grep -c 'segment=paid' "$CALLS" || true)" -ge 0 ]
  # the campaign and the segment are both on the sender's command line (the runner's own args are logged verbatim)
  awk '{for(i=1;i<=NF;i++){if($i=="--campaign"&&$(i+1)=="wait-apology")c++; if($i=="--segment"&&$(i+1)=="paid")p++}} END{exit !(c>0 && p>0)}' "$CALLS"
}
