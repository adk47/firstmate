#!/usr/bin/env bats
# scripts/credit-ask-tick.sh and the unit that runs it (scripts/install-aux-units.sh).
#
# The version this replaces was hand-installed on node-8 and had none of what is tested here: no cursor (every run
# walked the same first 200 paid entries and sent 0), a 3600 s timeout on a 30-minute timer (killed and restarted the
# same second, so the credit-group run lock was never free). Its applies now take their own run lock (--own-lock), so
# the hourly outbound tick in flight neither stops this run nor is refused by it.
#
# The sender is a stub that records its argv: what this file holds is the tick's own behaviour (one segment, the
# cursor, the budget, the locks, the record of a run) and that it hands the sender no flag that skips a gate. The
# sender's gates are tested in scripts/tests/test_need_asks.py.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
TICK="$HYDRA_REPO/scripts/credit-ask-tick.sh"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"
DELTA_LIB="$HYDRA_REPO/scripts/lib/delta-sync.sh"

unit_body() {
  awk -v start="$1" -v stop="$2" '
    index($0, start) == 1 { on = 1; next }
    $0 == stop { on = 0 }
    on { print }
  ' "$INSTALLER" | sed "s|\$HYDRA_ROOT|$HYDRA_REPO|g"
}
unit_get() {
  awk -v want="[$2]" -v key="$3" '
    /^\[/ { sec = $0; next }
    sec == want && index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }
  ' "$1"
}
# The constant a `NAME="$(cfg ENV_NAME <n>)"` line of the tick gives outside the harness. Those lines are the
# script's owned config contract (one line per knob), so reading them is reading the interface, not incidental text.
tick_const() { sed -n "s/^$1=\"\$(cfg [A-Z0-9_]* \([0-9]*\))\"\$/\1/p" "$TICK"; }

# The installer's own pager wiring, executed: its table plus wire_unit_failure_paging, which runs LAST in the
# installer against the units it wrote. <out> writes a script that wires AUX_SYSTEMD_UNIT_DIR.
wire_snippet() {
  {
    echo 'set -uo pipefail'
    echo 'log() { printf "%s\n" "$*"; }'
    echo 'AUX_ONFAILURE_UNITS=('
    awk '/^AUX_ONFAILURE_UNITS=\(/ { on = 1; next } on && /^\)/ { on = 0 } on { print $1 }' "$INSTALLER"
    echo ')'
    awk '$0 == "wire_unit_failure_paging() {" { on = 1 } on { print } on && $0 == "}" { exit }' "$INSTALLER"
    echo 'wire_unit_failure_paging'
  } > "$1"
}

setup() {
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/etc" "$T/state" "$T/outbound"
  export ASK_TICK_ETC="$T/etc" ASK_TICK_STATE="$T/state" ASK_TICK_LOCK="$T/run.lock"
  export ASK_TICK_OUTBOUND_LOCK="$T/outbound/tick.lock"
  export ASK_TICK_RUNNER="$T/runner.py" ASK_TICK_POLICY="$T/policy.json"
  export ASK_TICK_LEDGER="$T/ledger.sqlite3"
  # One batch per run unless a case is about the batches, and the outbound tick's next start far away unless a case
  # is about it: the wall clock's minute must never decide a case.
  export ASK_TICK_MAX_BATCHES=1 ASK_TICK_OUTBOUND_DUE_S=100000
  export ASK_TICK_CHECK_S_PER_USER=1 ASK_TICK_CHECK_SETUP_S=0   # the sizing has its own cases below
  export ASK_TICK_PAGE=20                                         # small batches keep the batch cases readable
  # the safety checks after every apply: stubs that answer clean unless a case says otherwise, and log their reads
  export ASK_TICK_HEALTH="$T/health.py" ASK_TICK_ZERO_READ="$T/zero_read.py" ASK_TICK_FRAUD="$T/fraud.py"
  export ASK_TICK_NOTIFY_LIB="$T/notify.sh"
  cat > "$T/health.py" <<'HP'
import os, sys
open(os.environ["CALLS"] + ".health", "a").write(" ".join(sys.argv[1:]) + "\n")
print(os.environ.get("STUB_HEALTH_MSG", "HEALTH OK"))
sys.exit(int(os.environ.get("STUB_HEALTH_RC", "0")))
HP
  cat > "$T/zero_read.py" <<'ZP'
import os, sys
open(os.environ["CALLS"] + ".zr", "a").write(" ".join(sys.argv[1:]) + "\n")
print(os.environ.get("STUB_ZR", "OK: every source read"))
ZP
  cat > "$T/fraud.py" <<'FP'
import os, sys
open(os.environ["CALLS"] + ".fraud", "a").write(" ".join(sys.argv[2:]) + "\n")
print(os.environ.get("STUB_FRAUD", "ok"))
FP
  cat > "$T/notify.sh" <<'NS'
slack_notify_critical() { printf '%s\n' "$*" >> "$CALLS.pages"; }
NS
  export CALLS="$T/calls"
  : > "$CALLS"
  echo '{"armed_families": {"proof-need-ask": {"live": true, "paid": true}}, "tick_cap": {"proof-need-ask": {"paid": 50, "free": 50}}, "daily_cap": {"proof-need-ask": {"paid": 400, "free": 400}}}' > "$ASK_TICK_POLICY"
  # the pre-policy (legacy) arming shape: a policy rewritten without armed_families still arms from these
  touch "$T/etc/credit-verify-outbound.live" "$T/etc/credit-verify-outbound.paid-enabled"
  python3 - "$ASK_TICK_LEDGER" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("CREATE TABLE verify_messages (id INTEGER PRIMARY KEY AUTOINCREMENT, campaign TEXT, day TEXT, status TEXT, "
           "user_key TEXT)")
db.commit()
PY
  cat > "$ASK_TICK_RUNNER" <<'PY'
import json, os, sys
a = sys.argv[1:]
open(os.environ["CALLS"], "a").write(" ".join(a) + "\n")
for k in os.environ:
    if k == "CV_APPROVE_GATE_DISABLED" or k.startswith("HYDRA_DEPLOY_SKIP") or k.endswith("_COPY_APPROVED") \
            or (k.startswith("CREDIT_") and k.endswith("_DAILY_MAX")):
        open(os.environ["CALLS"] + ".gate-env", "a").write(k + "\n")
arg = lambda name: a[a.index(name) + 1]  # noqa: E731
if a[0] == "build":
    if os.environ.get("STUB_BUILD_RC"):
        print("NEED ASKS: nothing listed or sent: the replica did not answer")
        sys.exit(int(os.environ["STUB_BUILD_RC"]))
    json.dump({"users": []}, open(arg("--out"), "w"))
    print(json.dumps({"generated_at": "x", "counts": {"list_paid": 790, "list_free": 901}}))
    sys.exit(0)
if a[0] == "send" and "--check-recipients" in a:
    import fcntl, subprocess, time
    nth = sum(1 for line in open(os.environ["CALLS"]) if "--check-recipients" in line)
    if os.environ.get("STUB_LOCK_PROBE"):
        # what an outbound tick's apply would meet between two batches: the credit-group run lock, free or held
        fh = open(os.environ["STUB_LOCK_PROBE"], "a+")
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
            state = "free"
        except OSError:
            state = "held"
        open(os.environ["CALLS"] + ".probe", "a").write(state + "\n")
        fh.close()
    if os.environ.get("STUB_GRAB_OUTBOUND_AT") == str(nth):
        # the outbound tick starts while this check runs: it holds its lock for the rest of the case
        holder = subprocess.Popen(["flock", os.environ["ASK_TICK_OUTBOUND_LOCK"], "sleep", "30"],
                                  start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        open(os.environ["CALLS"] + ".holder", "w").write(str(holder.pid))
        for _ in range(100):
            probe = open(os.environ["ASK_TICK_OUTBOUND_LOCK"], "a+")
            try:
                fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(probe, fcntl.LOCK_UN)
                time.sleep(0.05)
            except OSError:
                break
            finally:
                probe.close()
    if os.environ.get("STUB_CHECK_SLEEP"):
        time.sleep(float(os.environ["STUB_CHECK_SLEEP"]))
    start, entries = int(arg("--start-entry")), int(arg("--max-entries"))
    listed = int(os.environ.get("STUB_LISTED", "790"))
    gated, filtered = [], []
    if os.environ.get("STUB_ONE_USER_PER_BATCH"):
        # each batch: one user the gate accepts, one it defers, one filtered before the gate
        users = [f"u{start}"]
        gated = [{"user": f"g{start}", "result": "deferred", "reason": "messaged_7d credits=1 (x)"}]
        filtered = [{"user": f"f{start}", "result": "filtered", "reason": "already_asked"}]
    else:
        users = os.environ.get("STUB_ACCEPTED", "1 2 3").split()
    accepted = [{"user": u, "campaign": "proof-need-ask", "request_ids": [], "gate": "RECIPIENT OK"} for u in users]
    doc = {"mode": "dry-run", "check_recipients": True,
           "outcomes": [{"user": x["user"], "result": "accepted", "reason": "RECIPIENT OK"} for x in accepted] + gated,
           "filtered": filtered, "listed": len(accepted) + len(gated) + len(filtered),
           "max_users": int(arg("--max-users"))}
    if not os.environ.get("STUB_CHECK_NO_ACCEPTED"):
        doc["accepted"] = accepted
    if not os.environ.get("STUB_NO_PAGE"):
        doc["page"] = {"start": start, "end": int(os.environ.get("STUB_CHECK_PAGE_END") or os.environ.get("STUB_PAGE_END") or min(listed, start + entries)),
                       "listed": listed}
    json.dump(doc, open(arg("--outcomes-json"), "w"))
    print(json.dumps({"halted": "", "candidates": len(accepted), "sent": 0, "deferred": 0,
                      "refused": 0, "failed": 0, "refusals": []}))
    if os.environ.get("STUB_CHECK_MSG"):
        print(os.environ["STUB_CHECK_MSG"])
    sys.exit(int(os.environ.get("STUB_CHECK_RC", "0")))
if a[0] == "send" and arg("--mode") == "apply":
    if "--signed-accepted" not in a:
        print("STUB: an apply without --signed-accepted")
        sys.exit(4)
    if os.environ.get("STUB_SLOW_LOCK"):
        import fcntl, signal, time
        fh = open(os.environ["STUB_SLOW_LOCK"], "a+")
        fcntl.flock(fh, fcntl.LOCK_EX)
        if os.environ.get("STUB_IGNORE_TERM"):
            seen = os.environ.get("STUB_TERM_MARK")
            signal.signal(signal.SIGTERM, lambda *_: open(seen, "w").close() if seen else None)
        if os.environ.get("STUB_SLEEP"):
            time.sleep(float(os.environ["STUB_SLEEP"]))
    if os.environ.get("STUB_SEND_MSG"):
        print(os.environ["STUB_SEND_MSG"])
    if os.environ.get("STUB_SEND_RC"):
        sys.exit(int(os.environ["STUB_SEND_RC"]))
    with open(arg("--signed-accepted"), encoding="utf-8") as fh:
        accepted = [x["user"] for x in json.load(fh).get("accepted") or []]
    start, entries = int(arg("--start-entry")), int(arg("--max-entries"))
    listed = int(os.environ.get("STUB_LISTED", "790"))
    outcomes, nsent = [], 0
    for i, u in enumerate(accepted):
        if i == 0:
            # the sender's own order: a claim in the ledger before the post, and no post for a user already claimed
            import datetime, sqlite3, time
            db = sqlite3.connect(os.environ["ASK_TICK_LEDGER"])
            if db.execute("SELECT 1 FROM verify_messages WHERE campaign='proof-need-ask' AND user_key=? "
                          "AND status IN ('attempted','sent')", (u,)).fetchone():
                outcomes.append({"user": u, "result": "filtered", "reason": "already_asked"})
                continue
            day = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
            cur = db.execute("INSERT INTO verify_messages (campaign, day, status, user_key) "
                             "VALUES ('proof-need-ask', ?, 'attempted', ?)", (day, u))
            db.commit()
            open(os.environ["CALLS"] + ".posts", "a").write(u + "\n")
            if os.environ.get("STUB_DIE_AFTER_POST"):
                time.sleep(60)                                   # killed here: posted, never confirmed
            db.execute("UPDATE verify_messages SET status='sent' WHERE id=?", (cur.lastrowid,))
            db.commit()
            nsent += 1
            outcomes.append({"user": u, "result": "sent", "reason": "SENT"})
        elif i == 1:
            outcomes.append({"user": u, "result": "deferred", "reason": "messaged_7d credits=1 (x)"})
        else:
            outcomes.append({"user": u, "result": "deferred", "reason": "HELD comm_state (acknowledged: R6_stale_thread)"})
    outcomes += [{"user": f"r{k}", "result": "refused", "reason": "refused_unledgered G2"}
                 for k in range(int(os.environ.get("STUB_REFUSED", "0")))]
    doc = {"mode": "apply", "outcomes": outcomes}
    if not os.environ.get("STUB_NO_PAGE"):
        doc["page"] = {"start": start, "end": int(os.environ.get("STUB_PAGE_END") or min(listed, start + entries)),
                       "listed": listed}
    if not os.environ.get("STUB_NO_OUTCOMES"):
        json.dump(doc, open(arg("--outcomes-json"), "w"))
    if not os.environ.get("STUB_NO_SUMMARY"):
        print(json.dumps({"halted": "", "candidates": len(accepted), "sent": int(os.environ.get("STUB_SENT", nsent)),
                          "deferred": max(0, len(accepted) - 1), "refused": 0, "failed": 0, "refusals": []}))
    sys.exit(0)
PY
}

# today's proof-need-ask sends, as the tick counts them (both segments, sent and attempted)
ledger_rows() { # <n>
  python3 - "$ASK_TICK_LEDGER" "$1" <<'PY'
import datetime, sqlite3, sys
day = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
db = sqlite3.connect(sys.argv[1])
for _ in range(int(sys.argv[2])):
    db.execute("INSERT INTO verify_messages (campaign, day, status) VALUES ('proof-need-ask', ?, 'sent')", (day,))
db.commit()
PY
}
sends() { grep -c '^send ' "$CALLS" || true; }
applies() { grep -c '^send .*--mode apply' "$CALLS" || true; }
checks() { grep -c '^send .*--check-recipients' "$CALLS" || true; }
builds() { grep -c '^build ' "$CALLS" || true; }
last_run() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d[sys.argv[2]])' "$T/state/last-run.json" "$1"; }

# ── the budget and the unit ──

@test "the run ends inside its hard stop, the hard stop inside the unit's timeout, the timeout inside the hour" {
  run_s="$(tick_const RUN_S)"; hard_s="$(tick_const HARD_S)"; interval="$(tick_const INTERVAL_S)"
  grace="$(tick_const KILL_GRACE_S)"
  [ -n "$run_s" ] && [ -n "$hard_s" ] && [ -n "$interval" ] && [ -n "$grace" ]
  SVC="$T/credit-ask-tick.service"
  unit_body 'cat > /etc/systemd/system/credit-ask-tick.service' CREDITASKSVC > "$SVC"
  unit_timeout="$(unit_get "$SVC" Service TimeoutStartSec)"
  [ "$run_s" -lt "$hard_s" ]
  [ $(( hard_s + grace )) -lt "$unit_timeout" ]
  # a run may outlast the 10-minute timer period (systemd starts no second instance of a running oneshot, and the run
  # lock refuses one); what it must never do is run into the outbound tick's next :00
  [ "$unit_timeout" -le $(( 3600 - $(tick_const OUTBOUND_MARGIN_S) )) ]
  [ "$interval" -ge 60 ]
}

@test "the timer fires every 10 minutes and never at :00, which is the period the script budgets against" {
  if ! command -v systemd-analyze >/dev/null 2>&1; then skip "systemd-analyze is not installed"; fi
  TMR="$T/credit-ask-tick.timer"
  unit_body 'cat > /etc/systemd/system/credit-ask-tick.timer' CREDITASKTMR > "$TMR"
  cal="$(unit_get "$TMR" Timer OnCalendar)"
  [ "$cal" = '*-*-* *:10,20,30,40,50:00' ]
  [ "$(unit_get "$TMR" Timer Unit)" = credit-ask-tick.service ]
  mapfile -t fires < <(TZ=UTC systemd-analyze calendar --iterations=12 "$cal" \
    | sed -n 's/^ *\(Next elapse\|Iteration #[0-9]*\): [A-Za-z]* \(.*\) UTC$/\2/p')
  [ "${#fires[@]}" -eq 12 ]
  min=999999; prev=""
  for f in "${fires[@]}"; do
    t="$(date -u -d "$f" +%s)"
    [ "$(date -u -d "$f" +%M)" != 00 ] || { echo "fires at :00: $f"; return 1; }   # the outbound tick's start
    if [ -n "$prev" ] && [ $(( t - prev )) -lt "$min" ]; then min=$(( t - prev )); fi
    prev="$t"
  done
  [ "$min" -eq "$(tick_const INTERVAL_S)" ]
}

@test "systemd's own parser accepts both units, and the service runs the script with no flags" {
  SVC="$T/credit-ask-tick.service"; TMR="$T/credit-ask-tick.timer"
  unit_body 'cat > /etc/systemd/system/credit-ask-tick.service' CREDITASKSVC > "$SVC"
  unit_body 'cat > /etc/systemd/system/credit-ask-tick.timer' CREDITASKTMR > "$TMR"
  [ "$(unit_get "$SVC" Service Type)" = oneshot ]
  [ "$(unit_get "$SVC" Service ExecStart)" = "/bin/bash $HYDRA_REPO/scripts/credit-ask-tick.sh" ]
  if ! command -v systemd-analyze >/dev/null 2>&1; then skip "systemd-analyze is not installed"; fi
  run systemd-analyze verify "$SVC" "$TMR"
  [ "$status" -eq 0 ]
}

@test "the installer's pager wiring gives this unit OnFailure, and a second run changes nothing" {
  dir="$T/systemd"; mkdir -p "$dir" "$T/bin"
  unit_body 'cat > /etc/systemd/system/credit-ask-tick.service' CREDITASKSVC > "$dir/credit-ask-tick.service"
  [ -z "$(unit_get "$dir/credit-ask-tick.service" Unit OnFailure)" ]
  printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$*" >> "$SYSTEMCTL_CALLS"' > "$T/bin/systemctl"
  chmod +x "$T/bin/systemctl"
  export SYSTEMCTL_CALLS="$T/systemctl.calls"; : > "$SYSTEMCTL_CALLS"
  wire_snippet "$T/wire.sh"

  run env AUX_SYSTEMD_UNIT_DIR="$dir" PATH="$T/bin:$PATH" bash "$T/wire.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(unit_get "$dir/credit-ask-tick.service" Unit OnFailure)" = 'hydra-unit-failed@%n.service' ]
  [ "$(grep -c '^OnFailure=' "$dir/credit-ask-tick.service")" -eq 1 ]
  grep -qx 'daemon-reload' "$SYSTEMCTL_CALLS"

  run env AUX_SYSTEMD_UNIT_DIR="$dir" PATH="$T/bin:$PATH" bash "$T/wire.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(grep -c '^OnFailure=' "$dir/credit-ask-tick.service")" -eq 1 ]
  [ "$(grep -cx 'daemon-reload' "$SYSTEMCTL_CALLS")" -eq 2 ]
}

@test "the run creates its own state directory, private, and keeps its cursor and run record there" {
  export ASK_TICK_STATE="$T/fresh/nested/state"
  run bash "$TICK"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -d "$ASK_TICK_STATE" ]
  [ "$(stat -c %a "$ASK_TICK_STATE")" = 700 ]
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["state"] and d["page"]' "$ASK_TICK_STATE/last-run.json"
  [ -s "$ASK_TICK_STATE/cursor-paid" ]
}

@test "a share that could not fit one user's worst case is never handed to the sender" {
  # the send loop starts no user unless verify_notify.WORST_USER_S still fits its budget
  worst="$(cd "$HYDRA_REPO/scripts" && python3 -c 'from credit_review import verify_notify as v; print(int(v.WORST_USER_S))')"
  [ -n "$worst" ]
  [ "$(tick_const MIN_SHARE_S)" -gt "$worst" ]
}

# The deploy's Step 0/4b, executed: scripts/lib/delta-sync.sh against a scratch repo (HYDRA_ROOT) and a scratch
# server dir, with the harness env deploy.sh provides. <repo> <server> <baseline> <bash snippet>
delta_step() {
  run bash -c '
    set -uo pipefail
    HYDRA_ROOT="$1"; DEPLOY_PATH="$2"; HYDRA_LOCAL=true; SCRIPT_DIR="$4"
    RSYNC_EXCLUDES=(--exclude="workspaces/*/TOOLS.md" --exclude="audit/")
    log() { echo "[t] $*"; }
    source "$3"
    BASE=$5
    eval "$6"
  ' _ "$1" "$2" "$DELTA_LIB" "$HYDRA_REPO/scripts" "$3" "$4"
}

@test "the deploy takes the repository's script over the hand-written one on node-8 only because HEAD carries the marker" {
  W="$BATS_TEST_TMPDIR/deploy"; R="$W/repo"; S="$W/server"
  mkdir -p "$R/scripts" "$S/scripts"
  git -C "$R" init -q
  git -C "$R" config user.email t@t; git -C "$R" config user.name t
  echo base > "$R/README.md"
  git -C "$R" add -A; git -C "$R" commit -qm base
  base="$(git -C "$R" rev-parse HEAD)"
  # the path this change adds is absent at the baseline, exactly as on node-8
  install -m 644 "$TICK" "$R/scripts/credit-ask-tick.sh"
  git -C "$R" add -A; git -C "$R" commit -qm tick
  hand='#!/bin/bash
# installed on node-8 by hand on 2026-11-14, never in git
'
  printf '%s' "$hand" > "$S/scripts/credit-ask-tick.sh"

  delta_step "$R" "$S" "$base" 'delta_compute "$BASE"; delta_gate "$BASE" && delta_apply'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"git-wins: scripts/credit-ask-tick.sh"* ]]
  [ "$(cat "$S/scripts/credit-ask-tick.sh")" = "$(cat "$R/scripts/credit-ask-tick.sh")" ]

  marker="$(bash -c 'source "$1"; printf %s "$DELTA_GIT_WINS_MARKER"' _ "$DELTA_LIB")"
  [ -n "$marker" ]
  awk -v m="$marker" 'index($0, m) == 0' "$R/scripts/credit-ask-tick.sh" > "$R/scripts/tick.unmarked"
  mv "$R/scripts/tick.unmarked" "$R/scripts/credit-ask-tick.sh"
  ! grep -qF -- "$marker" "$R/scripts/credit-ask-tick.sh"
  git -C "$R" add -A; git -C "$R" commit -qm unmarked
  printf '%s' "$hand" > "$S/scripts/credit-ask-tick.sh"

  delta_step "$R" "$S" "$base" 'delta_compute "$BASE"; delta_gate "$BASE" && delta_apply'
  [ "$status" -eq 1 ]
  [[ "$output" == *"DEPLOY BLOCKED"*"scripts/credit-ask-tick.sh"* ]]
  [ "$(cat "$S/scripts/credit-ask-tick.sh")" = "$(printf '%s' "$hand")" ]
}

@test "a budget that does not fit the hour runs nothing" {
  ASK_TICK_HARD_S=1790 run bash "$TICK"          # the outbound margin no longer covers the overrun
  [ "$status" -eq 2 ]
  [[ "$output" == *"BAD BUDGET"* ]]
  [ "$(builds)" -eq 0 ]
  ASK_TICK_RUN_S=3400 ASK_TICK_HARD_S=3550 ASK_TICK_OUTBOUND_MARGIN_S=200 run bash "$TICK"   # past the hour
  [ "$status" -eq 2 ]
  [[ "$output" == *"BAD BUDGET"* ]]
  [ "$(builds)" -eq 0 ]
  ASK_TICK_RUN_S=abc run bash "$TICK"
  [ "$status" -eq 2 ]
  [ "$(builds)" -eq 0 ]
}

# ── the stops ──

@test "either stop file stops the run before anything is built" {
  touch "$T/etc/credit-ask-tick.disabled"
  run bash "$TICK"
  [ "$status" -eq 0 ]
  [ "$(builds)" -eq 0 ]
  rm "$T/etc/credit-ask-tick.disabled"; touch "$T/etc/credit-ask-STOP"
  run bash "$TICK"
  [ "$status" -eq 0 ]
  [ "$(builds)" -eq 0 ]
  [ -e "$T/etc/credit-ask-STOP" ]                 # honoured, never removed
}

@test "a second run while one holds the lock builds nothing and sends nothing" {
  exec 8>>"$ASK_TICK_LOCK"; flock -n 8
  run bash "$TICK"
  exec 8>&-
  [ "$status" -eq 0 ]
  [[ "$output" == *"another run holds"* ]]
  [ "$(builds)" -eq 0 ]
}

@test "an outbound tick in flight does not stop the run: its apply takes its own lock, never the credit-group one" {
  # firstmate 031: the outbound tick holds its tick lock and the credit-group run lock 60-95 minutes of every even hour
  mkdir -p "$(dirname "$ASK_TICK_OUTBOUND_LOCK")"
  exec 7>>"$ASK_TICK_OUTBOUND_LOCK"; flock -n 7
  exec 8>>"$T/ledger.sqlite3.credit-group.run.lock"; flock -n 8
  run bash "$TICK"
  exec 7>&- 8>&-
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(builds)" -eq 1 ]
  [ "$(applies)" -eq 1 ]
  grep -q -- '--mode apply .* --page --own-lock ' "$CALLS"
  [ "$(last_run sender_ran)" = True ]
}

@test "an outbound tick lock file nobody holds does not stop the run" {
  : > "$ASK_TICK_OUTBOUND_LOCK"
  run bash "$TICK"
  [ "$status" -eq 0 ]
  [ "$(applies)" -eq 1 ]
}

# ── one segment, one page, a cursor ──

@test "the sender gets one segment, the cursor, the page, its share of the budget, and no other flag" {
  ASK_TICK_PAGE=60 run bash "$TICK"
  [ "$status" -eq 0 ]
  [ "$(applies)" -eq 1 ]
  [ "$(checks)" -eq 1 ]
  line="$(grep '^send .*--mode apply' "$CALLS")"
  share="$(sed -n 's/.*--apply-budget-s \([0-9]*\) .*/\1/p' <<<"$line")"
  [ "$share" -ge "$(tick_const MIN_SHARE_S)" ] && [ "$share" -le "$(tick_const RUN_S)" ]
  [ "$line" = "send --list $T/state/asks.json --segment paid --mode apply --max-users 50 --max-entries 60 --start-entry 0 --apply-budget-s $share --signed-accepted $T/state/check-paid-1.json --page --own-lock --outcomes-json $T/state/outcomes-paid-1.json" ]
  # the check gates every user that fits (the page); the apply sends at most the per-tick cap of what it signed
  grep -q -- "^send --list $T/state/asks.json --segment paid --mode dry-run --max-users 60 --max-entries 60 --start-entry 0 --check-recipients --outcomes-json $T/state/check-paid-1.json\$" "$CALLS"
  [ ! -s "$CALLS.gate-env" ]
}

@test "runs alternate paid and free, and each segment starts where its last run stopped" {
  export ASK_TICK_PAGE=60
  for _ in 1 2 3 4; do run bash "$TICK"; [ "$status" -eq 0 ]; done
  mapfile -t got < <(sed -n 's/^send .*--segment \([a-z]*\) .*--mode apply .*--start-entry \([0-9]*\) .*/\1 \2/p' "$CALLS")
  [ "${got[0]}" = "paid 0" ]
  [ "${got[1]}" = "free 0" ]
  [ "${got[2]}" = "paid 60" ]
  [ "${got[3]}" = "free 60" ]
}

@test "a policy that does not arm the family sends nothing, and a paid segment it does not arm takes free" {
  echo '{"armed_families": {"proof-need-ask": {"live": false, "paid": false}}, "tick_cap": {"proof-need-ask": {"paid": 50, "free": 50}}, "daily_cap": {"proof-need-ask": {"paid": 400, "free": 400}}}' > "$ASK_TICK_POLICY"
  run bash "$TICK"
  [ "$status" -eq 0 ]
  [ "$(sends)" -eq 0 ]
  [ "$(last_run state)" = family_not_armed ]

  echo '{"armed_families": {"proof-need-ask": {"live": true, "paid": false}}, "tick_cap": {"proof-need-ask": {"paid": 50, "free": 50}}, "daily_cap": {"proof-need-ask": {"paid": 400, "free": 400}}}' > "$ASK_TICK_POLICY"
  echo paid > "$T/state/next-segment"
  : > "$CALLS"
  run bash "$TICK"
  [ "$status" -eq 0 ]
  [ "$(applies)" -eq 1 ]
  grep -q -- '^send .*--segment free .*--mode apply ' "$CALLS"
}

@test "an unsigned_from still ahead sends nothing, and its arrival arms the family" {
  echo '{"armed_families": {"proof-need-ask": {"live": true, "paid": true, "unsigned_from": "2099-01-01T00:00Z"}}, "tick_cap": {"proof-need-ask": {"paid": 50, "free": 50}}, "daily_cap": {"proof-need-ask": {"paid": 400, "free": 400}}}' > "$ASK_TICK_POLICY"
  run bash "$TICK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unsigned_from reached=0"* ]]
  [ "$(sends)" -eq 0 ]

  echo '{"armed_families": {"proof-need-ask": {"live": true, "paid": true, "unsigned_from": "2020-01-01T00:00Z"}}, "tick_cap": {"proof-need-ask": {"paid": 50, "free": 50}}, "daily_cap": {"proof-need-ask": {"paid": 400, "free": 400}}}' > "$ASK_TICK_POLICY"
  : > "$CALLS"
  run bash "$TICK"
  [ "$status" -eq 0 ]
  [ "$(applies)" -eq 1 ]
}

@test "a policy with no arming row reads the legacy flag files, and no flags sends nothing" {
  echo '{"tick_cap": {"proof-need-ask": {"paid": 50, "free": 50}}, "daily_cap": {"proof-need-ask": {"paid": 400, "free": 400}}}' > "$ASK_TICK_POLICY"
  rm -f "$T/etc/credit-verify-outbound.live" "$T/etc/credit-verify-outbound.paid-enabled"
  run bash "$TICK"
  [ "$status" -eq 0 ]
  [ "$(sends)" -eq 0 ]
  [ "$(last_run state)" = family_not_armed ]

  touch "$T/etc/credit-verify-outbound.live" "$T/etc/credit-verify-outbound.paid-enabled"
  : > "$CALLS"
  run bash "$TICK"
  [ "$status" -eq 0 ]
  [ "$(applies)" -eq 1 ]
}

@test "a recipient check that fails sends nothing and leaves the cursor" {
  echo 40 > "$T/state/cursor-paid"
  STUB_CHECK_RC=2 STUB_CHECK_MSG="NEED ASKS: the recipient gate did not answer" run bash "$TICK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CHECK FAILED (rc=2)"* ]]
  [ "$(applies)" -eq 0 ]
  [ "$(last_run state)" = check_failed ]
  [ "$(cat "$T/state/cursor-paid")" = 40 ]
}

@test "a recipient check that records no accepted set sends nothing" {
  STUB_CHECK_NO_ACCEPTED=1 run bash "$TICK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CHECK UNMEASURED"* ]]
  [ "$(applies)" -eq 0 ]
  [ "$(last_run state)" = check_unmeasured ]
}

@test "a check that accepts nobody finishes the page instead of sending it" {
  STUB_ACCEPTED="" run bash "$TICK"
  [ "$status" -eq 0 ]
  [ "$(applies)" -eq 0 ]
  [ "$(last_run state)" = check_accepted_nobody ]
  [ "$(cat "$T/state/cursor-paid")" = 20 ]
}

@test "the cursor is the sender's own page record, and wraps to 0 at the end of the list" {
  STUB_PAGE_END=17 run bash "$TICK"                # the budget ended the page early
  [ "$status" -eq 0 ]
  [ "$(cat "$T/state/cursor-paid")" = 17 ]
  echo paid > "$T/state/next-segment"
  STUB_LISTED=30 run bash "$TICK"                  # 17 + 20 is past the 30 listed
  [ "$status" -eq 0 ]
  [ "$(cat "$T/state/cursor-paid")" = 0 ]
}

@test "a run with no page record fails and leaves the cursor where it was" {
  echo 120 > "$T/state/cursor-paid"
  STUB_NO_PAGE=1 run bash "$TICK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NO PAGE RECORD"* ]]
  [ "$(cat "$T/state/cursor-paid")" = 120 ]
}

@test "the policy's per-tick cap lowers the attempts, and a cap of 0 sends nothing" {
  echo '{"tick_cap": {"proof-need-ask": {"paid": 5, "free": 0}}, "daily_cap": {"proof-need-ask": {"paid": 400, "free": 400}}}' > "$ASK_TICK_POLICY"
  run bash "$TICK"
  [ "$status" -eq 0 ]
  grep -q -- '--segment paid .*--max-users 5 ' "$CALLS"
  : > "$CALLS"
  run bash "$TICK"                                 # free: cap 0
  [ "$status" -eq 0 ]
  [ "$(sends)" -eq 0 ]
  [ "$(cat "$T/state/next-segment")" = paid ]
}

@test "today's sends count against the policy's daily cap, and a spent cap sends nothing" {
  ledger_rows 400
  echo 60 > "$T/state/cursor-paid"
  run bash "$TICK"
  [ "$status" -eq 0 ]
  [ "$(sends)" -eq 0 ]
  [ "$(last_run state)" = daily_cap_used ]
  [ "$(cat "$T/state/cursor-paid")" = 60 ]
  [ "$(cat "$T/state/next-segment")" = free ]
}

@test "the daily cap clamps the sender's --max-users to what is left of it" {
  ledger_rows 380                                  # 20 of the day's 400 left, under the per-tick 50
  run bash "$TICK"
  [ "$status" -eq 0 ]
  grep -q -- '--segment paid .*--max-users 20 ' "$CALLS"
}

@test "a day with nothing sent gets the per-tick cap, not the daily cap" {
  export ASK_TICK_PAGE=60
  ledger_rows 350                                  # 50 left: the per-tick 50 is the smaller number
  run bash "$TICK"
  [ "$status" -eq 0 ]
  grep -q -- '--segment paid .*--max-users 50 ' "$CALLS"
  : > "$CALLS"
  python3 -c 'import sqlite3,sys; db=sqlite3.connect(sys.argv[1]); db.execute("DELETE FROM verify_messages"); db.commit()' "$ASK_TICK_LEDGER"
  run bash "$TICK"
  [ "$status" -eq 0 ]
  grep -q -- '--segment free .*--max-users 50 ' "$CALLS"
}

@test "another campaign's sends are not this family's cap, and a ledger that cannot answer sends nothing" {
  export ASK_TICK_PAGE=60
  python3 - "$ASK_TICK_LEDGER" <<'PY'
import datetime, sqlite3, sys
day = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
db = sqlite3.connect(sys.argv[1])
for _ in range(400):
    db.execute("INSERT INTO verify_messages (campaign, day, status) VALUES ('uvn-status', ?, 'sent')", (day,))
db.commit()
PY
  run bash "$TICK"
  [ "$status" -eq 0 ]
  grep -q -- '--segment paid .*--max-users 50 ' "$CALLS"

  : > "$CALLS"
  export ASK_TICK_LEDGER="$T/absent/ledger.sqlite3"
  run bash "$TICK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"LEDGER UNREADABLE"* ]]
  [ "$(sends)" -eq 0 ]
  [ "$(last_run state)" = ledger_unreadable ]
}

@test "a policy cap that cannot be read names its whole reason in the line" {
  echo '{"armed_families": {"proof-need-ask": {"live": true, "paid": true}}, "daily_cap": {"proof-need-ask": {"paid": "lots"}}}' > "$ASK_TICK_POLICY"
  run bash "$TICK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"daily_cap.proof-need-ask.paid is not a whole number"* ]]
  [ "$(sends)" -eq 0 ]
}

@test "an unreadable policy sends nothing and fails" {
  echo '{not json' > "$ASK_TICK_POLICY"
  run bash "$TICK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"POLICY UNREADABLE"* ]]
  [ "$(sends)" -eq 0 ]
}

# ── failures are failures, and a number nobody printed is not 0 ──

@test "a build that fails sends nothing and fails the run" {
  STUB_BUILD_RC=2 run bash "$TICK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"BUILD FAILED (rc=2)"* ]]
  [ "$(sends)" -eq 0 ]
  [ "$(last_run state)" = build_failed ]
}

@test "a build that leaves no room for one send does not start one" {
  left=$(( $(tick_const RUN_S) - $(tick_const MIN_SHARE_S) + 1 ))
  # the build itself is bounded to end before this point; the harness clock starts the run already past it
  ASK_TICK_ELAPSED0="$left" run bash "$TICK"
  [ "$status" -eq 1 ]
  [ "$(applies)" -eq 0 ]
}

@test "a failed send fails the run and leaves the cursor" {
  echo 60 > "$T/state/cursor-paid"
  STUB_SEND_RC=1 STUB_SEND_MSG="NEED ASKS: nothing listed or sent: the ledger is not writable" run bash "$TICK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SEND FAILED (rc=1): NEED ASKS: nothing listed or sent: the ledger is not writable"* ]]
  [ "$(cat "$T/state/cursor-paid")" = 60 ]
  [ "$(last_run sent)" = None ]                    # the sender printed no figure: unmeasured, never 0
  [[ "$output" == *"sent unmeasured"* ]]
}

@test "another credit sender holding the group lock is its turn, not a failure, and the cursor stays" {
  echo 60 > "$T/state/cursor-paid"
  STUB_SEND_RC=1 STUB_SEND_MSG='{"halted": "another credit-group apply run is in progress (one shared budget); nothing sent by this one", "candidates": 0, "sent": 0, "deferred": 0, "refused": 0, "failed": 0}' run bash "$TICK"
  [ "$status" -eq 0 ]
  [ "$(last_run state)" = lock_held_by_another ]
  [ "$(cat "$T/state/cursor-paid")" = 60 ]
}

@test "a deploy holding the apply lock is its turn too" {
  STUB_SEND_RC=3 STUB_SEND_MSG="NEED ASKS: APPLY_LOCK_HELD: a deploy holds the apply lock; nothing sent" run bash "$TICK"
  [ "$status" -eq 0 ]
  [ "$(last_run state)" = lock_held_by_another ]
}

@test "the run's line counts why users were not sent, by class, and names no user" {
  run bash "$TICK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ran: segment paid, 1 batch(es), 1 applied, entries from 0, next run starts at 20; candidates 3, sent 1, deferred 2, refused 0, failed 0"* ]]
  [[ "$output" == *"deferred/messaged_7d x1"* ]]
  [[ "$output" == *"deferred/comm_state x1"* ]]
}

@test "a sender that printed no summary is recorded as unmeasured" {
  STUB_NO_SUMMARY=1 run bash "$TICK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"candidates unmeasured, sent unmeasured"* ]]
  [ "$(last_run sent)" = None ]
}

# ── the hard stop, and the lock the sender holds ──

# A pass is one segment bounded by its hard stop: the sender, which holds the credit-group run lock, is killed at the
# hard stop, so no lock survives a pass. Small harness budgets keep these cases to seconds.
slow_budget() {
  # 5 s for the build and the check before the 1 s share: room on a loaded 2-CPU runner, still a short case
  export ASK_TICK_MIN_SHARE_S=1 ASK_TICK_RUN_S=6 ASK_TICK_HARD_S=7 ASK_TICK_INTERVAL_S=120 ASK_TICK_KILL_GRACE_S=1
  export STUB_SLOW_LOCK="$T/credit-group.lock" STUB_SLEEP=60
}

@test "a sender that overruns the hard stop is killed, the run fails, the cursor stays and the locks are free" {
  slow_budget
  start="$(date +%s)"
  run bash "$TICK"
  took=$(( $(date +%s) - start ))
  [ "$status" -eq 1 ]
  [ "$took" -le 18 ]
  [ "$(last_run state)" = send_killed ]
  [ ! -e "$ASK_TICK_STATE/cursor-paid" ]
  flock -n "$STUB_SLOW_LOCK" true
  flock -n "$ASK_TICK_LOCK" true
}

@test "a sender that ignores SIGTERM is killed after the grace, and the locks are still free" {
  slow_budget
  export STUB_IGNORE_TERM=1 STUB_TERM_MARK="$T/term.seen"
  start="$(date +%s)"
  run bash "$TICK"
  took=$(( $(date +%s) - start ))
  [ "$status" -eq 1 ]
  [ "$took" -le 18 ]
  [ -e "$STUB_TERM_MARK" ]                        # it saw the SIGTERM and lived; only the SIGKILL ended it
  [ "$(last_run state)" = send_killed ]
  [ ! -e "$ASK_TICK_STATE/cursor-paid" ]
  flock -n "$STUB_SLOW_LOCK" true
  flock -n "$ASK_TICK_LOCK" true
}

@test "an ordinary run sends one segment and carries no lock out of it" {
  export STUB_SLOW_LOCK="$T/credit-group.lock"
  run bash "$TICK"
  [ "$status" -eq 0 ]
  [ "$(applies)" -eq 1 ]
  [ -e "$STUB_SLOW_LOCK" ]
  flock -n "$STUB_SLOW_LOCK" true
  flock -n "$ASK_TICK_LOCK" true
}

@test "another run can start as soon as the killed one exits" {
  slow_budget
  run bash "$TICK"
  [ "$status" -eq 1 ]
  run env -u STUB_SLOW_LOCK -u STUB_SLEEP -u ASK_TICK_MIN_SHARE_S -u ASK_TICK_RUN_S -u ASK_TICK_HARD_S \
    -u ASK_TICK_INTERVAL_S -u ASK_TICK_KILL_GRACE_S bash "$TICK"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(last_run state)" = ran ]
}

# ── a run is batches: the cursor after each, no lock between them, and a resume that sends nobody twice ──

posts() { [ -e "$CALLS.posts" ] && wc -l < "$CALLS.posts" || echo 0; }
dupes() { [ -e "$CALLS.posts" ] && sort "$CALLS.posts" | uniq -d | wc -l || echo 0; }

@test "a run walks batch after batch, saving the cursor after each, until the end of the list" {
  export ASK_TICK_MAX_BATCHES=200 STUB_ONE_USER_PER_BATCH=1 STUB_LISTED=100
  run bash "$TICK"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(checks)" -eq 5 ]
  [ "$(applies)" -eq 5 ]
  [ "$(posts)" -eq 5 ]
  [ "$(last_run state)" = pass_complete ]
  [ "$(last_run batches)" = 5 ]
  [ "$(last_run sent)" = 5 ]
  [ "$(cat "$T/state/cursor-paid")" = 0 ]
  mapfile -t got < <(sed -n 's/^send .*--mode apply .*--start-entry \([0-9]*\) .*/\1/p' "$CALLS")
  [ "${got[*]}" = "0 20 40 60 80" ]
}

@test "the run's record names, per gate, why every walked user who was not sent was skipped" {
  export ASK_TICK_MAX_BATCHES=3 STUB_ONE_USER_PER_BATCH=1
  run bash "$TICK"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(last_run walked)" = 9 ]
  python3 - "$T/state/last-run.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["gate_skips"] == {"deferred/messaged_7d": 3}, d["gate_skips"]
assert d["filtered_before_gate"] == {"filtered/already_asked": 3}, d["filtered_before_gate"]
assert d["sent"] == 3 and d["state"] == "ran", d
PY
  [[ "$output" == *"the gate did not accept: deferred/messaged_7d x3"* ]]
  [[ "$output" == *"filtered before the gate: filtered/already_asked x3"* ]]
}

@test "the per-tick cap counts the whole run's ledger rows, not one batch's" {
  export ASK_TICK_MAX_BATCHES=200 STUB_ONE_USER_PER_BATCH=1
  echo '{"tick_cap": {"proof-need-ask": {"paid": 3, "free": 3}}, "daily_cap": {"proof-need-ask": {"paid": 400, "free": 400}}}' > "$ASK_TICK_POLICY"
  run bash "$TICK"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(posts)" -eq 3 ]
  [ "$(last_run state)" = tick_cap_spent ]
  [ "$(cat "$T/state/cursor-paid")" = 60 ]
}

@test "the daily cap reached mid-run ends the run after the batch that reached it" {
  export ASK_TICK_MAX_BATCHES=200 STUB_ONE_USER_PER_BATCH=1
  ledger_rows 398
  run bash "$TICK"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(posts)" -eq 2 ]
  [ "$(last_run state)" = daily_cap_used ]
  [ "$(cat "$T/state/next-segment")" = free ]
}

@test "the run never holds the credit-group lock: an outbound apply could take it before every check" {
  export ASK_TICK_MAX_BATCHES=4 STUB_ONE_USER_PER_BATCH=1
  export STUB_SLOW_LOCK="$T/ledger.sqlite3.proof-need-ask.ask-tick.run.lock" STUB_LOCK_PROBE="$T/ledger.sqlite3.credit-group.run.lock"
  run bash "$TICK"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(applies)" -eq 4 ]
  [ "$(grep -c '^free$' "$CALLS.probe")" -eq 4 ]
  ! grep -q '^held$' "$CALLS.probe"
}

@test "an outbound tick that starts mid-run does not stop the next apply" {
  export ASK_TICK_MAX_BATCHES=4 STUB_ONE_USER_PER_BATCH=1 STUB_GRAB_OUTBOUND_AT=3
  run bash "$TICK"
  kill "$(cat "$CALLS.holder")" 2>/dev/null || true
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(applies)" -eq 4 ]
  [ "$(last_run state)" = ran ]
  [ "$(cat "$T/state/cursor-paid")" = 80 ]
}

@test "the deadline stops the run between batches with the cursor at the first batch not done" {
  export ASK_TICK_MAX_BATCHES=200 STUB_ONE_USER_PER_BATCH=1 STUB_CHECK_SLEEP=1
  # RUN_S leaves room for the build plus a first batch on a loaded 2-CPU runner: at RUN_S=3 a 2 s build left the
  # first check 0 s and the run ended check_killed before any batch (PR Validation, 2026-11-16 02:46Z).
  export ASK_TICK_MIN_SHARE_S=1 ASK_TICK_BATCH_APPLY_S=1 ASK_TICK_RUN_S=7 ASK_TICK_HARD_S=8 ASK_TICK_INTERVAL_S=120
  start="$(date +%s)"
  run bash "$TICK"
  took=$(( $(date +%s) - start ))
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$took" -le 16 ]
  [ "$(last_run state)" = budget_spent ]
  cur="$(cat "$T/state/cursor-paid")"
  [ "$cur" -ge 20 ] && [ "$cur" -lt 790 ]
  [ "$cur" -eq $(( $(applies) * 20 )) ]
}

@test "a run killed after a post resumes at the unfinished batch and sends nobody twice" {
  export ASK_TICK_MAX_BATCHES=200 STUB_ONE_USER_PER_BATCH=1
  export ASK_TICK_MIN_SHARE_S=1 ASK_TICK_BATCH_APPLY_S=1 ASK_TICK_RUN_S=6 ASK_TICK_HARD_S=7 ASK_TICK_INTERVAL_S=120
  export ASK_TICK_KILL_GRACE_S=1 STUB_DIE_AFTER_POST=1
  run bash "$TICK"                                  # batch 1 posts u0, then hangs and is killed
  [ "$status" -eq 1 ]
  [ "$(last_run state)" = send_killed ] || { echo "$output"; cat "$T/state/last-run.json"; return 1; }
  [ "$(posts)" -eq 1 ]
  [ ! -e "$T/state/cursor-paid" ]                   # the unfinished batch is not passed over
  echo paid > "$T/state/next-segment"
  unset STUB_DIE_AFTER_POST
  export ASK_TICK_RUN_S=1500 ASK_TICK_HARD_S=1680 ASK_TICK_INTERVAL_S=1800 ASK_TICK_MIN_SHARE_S=230
  export ASK_TICK_BATCH_APPLY_S=300 ASK_TICK_KILL_GRACE_S=30 STUB_LISTED=60
  run bash "$TICK"                                  # resumes at entry 0: u0's claim blocks a second post
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(last_run state)" = pass_complete ]
  [ "$(dupes)" -eq 0 ]
  [ "$(posts)" -eq 3 ]                              # u0 once, then u20 and u40
  grep -qx u0 "$CALLS.posts"
  [ "$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("SELECT count(*) FROM verify_messages WHERE user_key=?", ("u0",)).fetchone()[0])' "$ASK_TICK_LEDGER")" -eq 1 ]
}

@test "a run ends before the outbound tick's start, and one that would not fit a send before it yields" {
  export ASK_TICK_MAX_BATCHES=1
  ASK_TICK_OUTBOUND_DUE_S=400 run bash "$TICK"      # 400 s to :00, 240 s of margin: 160 s left, under one send
  [ "$status" -eq 0 ]
  [ "$(last_run state)" = outbound_tick_due ]
  [ "$(builds)" -eq 0 ]
  ASK_TICK_OUTBOUND_DUE_S=600 run bash "$TICK"      # 360 s left: one send, its share inside the margin
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  share="$(sed -n 's/.*--mode apply .*--apply-budget-s \([0-9]*\) .*/\1/p' "$CALLS")"
  [ "$share" -ge 230 ] && [ "$share" -le 300 ]
}

@test "the outbound margin covers the hard stop's overrun, or nothing runs" {
  ASK_TICK_OUTBOUND_MARGIN_S=100 run bash "$TICK"
  [ "$status" -eq 2 ]
  [[ "$output" == *"BAD BUDGET"* ]]
  [ "$(builds)" -eq 0 ]
}

# ── the outbound tick's safety checks run after every apply of this one ──

@test "every apply is read back: health, fraud, zero-read over exactly its ledger rows, and a sample pointer" {
  export ASK_TICK_MAX_BATCHES=3 STUB_ONE_USER_PER_BATCH=1
  run bash "$TICK"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(wc -l < "$CALLS.health")" -eq 3 ]
  grep -q -- "--since 20" "$CALLS.health"
  mapfile -t zr < "$CALLS.zr"
  [ "${zr[*]}" = "--ledger-ids 1-1 --ledger-ids 2-2 --ledger-ids 3-3" ]
  [ "$(wc -l < "$CALLS.fraud")" -eq 3 ]
  [ "$(wc -l < "$T/state/samples.jsonl")" -eq 3 ]
  [ ! -e "$ASK_TICK_ETC/credit-ask-tick.disabled" ]
}

@test "a zero-read reader or health read that is not deployed refuses the run before anything is built" {
  rm "$T/zero_read.py"
  run bash "$TICK"
  [ "$status" -eq 1 ]
  [ "$(last_run state)" = rails_missing ]
  [ "$(builds)" -eq 0 ] && [ "$(applies)" -eq 0 ]
  [[ "$output" == *"LIVE REFUSED"* ]]
}

@test "a health check that fails writes the kill file, pages, and the next run sends nothing" {
  export ASK_TICK_MAX_BATCHES=5 STUB_ONE_USER_PER_BATCH=1 STUB_HEALTH_RC=1 STUB_HEALTH_MSG="bounce 4.1% > 2%"
  run bash "$TICK"
  [ "$status" -eq 1 ]
  [ "$(last_run state)" = auto_killed ]
  [ "$(applies)" -eq 1 ]
  grep -q "bounce 4.1%" "$ASK_TICK_ETC/credit-ask-tick.disabled"
  grep -q "AUTO-KILL" "$CALLS.pages"
  [ "$(cat "$T/state/cursor-paid")" = 20 ]          # what was sent is done: the batch is never re-walked
  run bash "$TICK"
  [ "$status" -eq 0 ]
  [ "$(applies)" -eq 1 ]
}

@test "a fraud hit on a sent account, and a fraud lens that cannot be read, each stop the family" {
  export ASK_TICK_MAX_BATCHES=5 STUB_ONE_USER_PER_BATCH=1 STUB_FRAUD="hit 123"
  run bash "$TICK"
  [ "$status" -eq 1 ]
  [ "$(last_run state)" = auto_killed ]
  grep -q "FRAUD hit 123" "$ASK_TICK_ETC/credit-ask-tick.disabled"
  rm "$ASK_TICK_ETC/credit-ask-tick.disabled"
  STUB_FRAUD="unreadable TrinoError x" run bash "$TICK"
  [ "$status" -eq 1 ]
  grep -q "FRAUD unreadable" "$ASK_TICK_ETC/credit-ask-tick.disabled"
}

@test "a zero-read STOP of any form kills; UNMEASURED or a crash stops the run, pages, and writes no kill file" {
  export ASK_TICK_MAX_BATCHES=5 STUB_ONE_USER_PER_BATCH=1
  STUB_ZR="STOP+UNMEASURED: credit-class message 9" run bash "$TICK"
  [ "$status" -eq 1 ]
  [ "$(last_run state)" = auto_killed ]
  grep -q "STOP+UNMEASURED" "$ASK_TICK_ETC/credit-ask-tick.disabled"
  rm "$ASK_TICK_ETC/credit-ask-tick.disabled"; : > "$CALLS.pages"
  STUB_ZR="Traceback (most recent call last)" run bash "$TICK"
  [ "$status" -eq 1 ]
  [ "$(last_run state)" = zero_read_unmeasured ]
  [ ! -e "$ASK_TICK_ETC/credit-ask-tick.disabled" ]
  grep -q "zero-read UNMEASURED" "$CALLS.pages"
  # batch 1 (u0) was already claimed by the paid run, so nothing went and nothing was read; batch 2 sent and read
  # UNMEASURED: its cursor is saved, the run stops there, and the next run reads again from entry 40
  [ "$(cat "$T/state/cursor-free")" = 40 ]
  [ "$(wc -l < "$CALLS.zr")" -eq 2 ]
}

@test "outcomes the apply never wrote are not a clean read: the family stops, labelled unmeasured, not a spike" {
  export STUB_NO_OUTCOMES=1
  run bash "$TICK"
  [ "$status" -eq 1 ]
  [ "$(last_run state)" = auto_killed ]
  grep -q "OUTCOMES UNMEASURED" "$ASK_TICK_ETC/credit-ask-tick.disabled"
  [ "$(cat "$T/state/cursor-paid" 2>/dev/null || echo none)" = none ]   # where it stopped is unknown: not moved
}

@test "a refusal spike in the apply's own outcomes stops the family" {
  export STUB_REFUSED=10
  run bash "$TICK"
  [ "$status" -eq 1 ]
  [ "$(last_run state)" = auto_killed ]
  grep -q "refusal spike" "$ASK_TICK_ETC/credit-ask-tick.disabled"
}

# The first live pass (2026-11-16 05:50Z) ran at :50: the run ends 240 s before :00 and keeps 230 s for the send, so the
# check had until 130 s and was killed there with 20 entries asked of it, nothing walked. The check is now sized to
# the time it has at the measured per-user cost.
@test "a :50 run hands its check only the users that fit before the check's deadline, and walks them" {
  unset ASK_TICK_CHECK_S_PER_USER ASK_TICK_CHECK_SETUP_S        # the production cost: 4 s a user, 20 s to start
  export ASK_TICK_OUTBOUND_DUE_S=540                            # nine minutes to the outbound tick
  run bash "$TICK"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  m="$(grep -- '--check-recipients' "$CALLS" | sed -E 's/.*--max-users ([0-9]+) .*/\1/')"
  # (540 - 240 - 230 - 20) / 4 = 12 with no time spent, 11 or 10 once the stub build and a slow runner have taken
  # up to 10 s: fewer than the page of 20, so the sizing, not the page, set it
  [ "$m" -ge 10 ] && [ "$m" -le 12 ] || { echo "max-users $m"; return 1; }
  # the apply sends at most the per-tick cap of what the check signed, over exactly the entries the check examined
  grep -q -- "--mode apply --max-users 50 --max-entries 20 --start-entry 0 " "$CALLS"
  [ "$(last_run state)" != check_killed ]
  [ "$(cat "$T/state/cursor-paid")" -gt 0 ]                 # the batch was walked and the cursor moved
  grep -q "check of up to $m user(s) from entry 0 took" <<<"$output"
}

@test "at the production cost a run's check gates every user that fits its time, not a page of 20" {
  unset ASK_TICK_CHECK_S_PER_USER ASK_TICK_CHECK_SETUP_S ASK_TICK_PAGE
  export ASK_TICK_OUTBOUND_DUE_S=600                            # :50: (600 - 240 - 230 - 20) / 4 = 27
  run bash "$TICK"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  m="$(grep -- '--check-recipients' "$CALLS" | sed -E 's/.*--max-users ([0-9]+) .*/\1/')"
  [ "$m" -ge 24 ] && [ "$m" -le 27 ] || { cat "$CALLS"; return 1; }
  grep -q -- "--max-users $m --max-entries 400 .*--check-recipients" "$CALLS" || { cat "$CALLS"; return 1; }
  : > "$CALLS"; rm -f "$T/state/cursor-"*
  export ASK_TICK_OUTBOUND_DUE_S=3000                           # :10: RUN_END 1500, (1500 - 230 - 20) / 4 = 312
  run bash "$TICK"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  m="$(grep -- '--check-recipients' "$CALLS" | head -1 | sed -E 's/.*--max-users ([0-9]+) .*/\1/')"
  [ "$m" -ge 300 ] && [ "$m" -le 312 ] || { cat "$CALLS"; return 1; }
}

@test "the apply walks only the entries its check examined, so the cursor never passes a user no check gated" {
  export STUB_CHECK_PAGE_END=7          # the check stopped at entry 7 (its users ran out at --max-users)
  export STUB_PAGE_END=7
  run bash "$TICK"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q -- "--mode apply --max-users 50 --max-entries 7 --start-entry 0 " "$CALLS" || { cat "$CALLS"; return 1; }
  [ "$(cat "$T/state/cursor-paid")" = 7 ]
  echo 3 > "$T/state/cursor-free"; echo free > "$T/state/next-segment"
  export STUB_CHECK_PAGE_END=3          # a check that examined nothing past its start is unmeasured: nothing sent
  run bash "$TICK"
  [ "$status" -eq 1 ]
  [ "$(last_run state)" = page_unmeasured ]
  [ "$(cat "$T/state/cursor-free")" = 3 ]
  [ "$(grep -c -- '--segment free --mode apply' "$CALLS")" -eq 0 ]
}

@test "a run with no room for one gated user starts no check, keeps its cursor and is not a failure" {
  export ASK_TICK_CHECK_S_PER_USER=16 ASK_TICK_CHECK_SETUP_S=20
  export ASK_TICK_OUTBOUND_DUE_S=500                            # 500 - 240 - 230 = 30 s: under 20 + 16
  echo 40 > "$T/state/cursor-paid" 2>/dev/null || { mkdir -p "$T/state"; echo 40 > "$T/state/cursor-paid"; }
  run bash "$TICK"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(last_run state)" = check_not_reached ]
  # bats ignores a failed `! cmd` that is not the last line, so a forbidden call fails the case explicitly
  if grep -q -- '--check-recipients' "$CALLS"; then echo "a check was started"; false; fi
  if grep -q -- '--mode apply' "$CALLS"; then echo "an apply was started"; false; fi
  [ "$(cat "$T/state/cursor-paid")" = 40 ]
  grep -q "CHECK NOT REACHED" <<<"$output"
}

@test "a later batch with no room for a check ends the run with the cursor after the last batch done" {
  export ASK_TICK_MAX_BATCHES=200 ASK_TICK_CHECK_S_PER_USER=1 ASK_TICK_CHECK_SETUP_S=3
  export ASK_TICK_MIN_SHARE_S=1 ASK_TICK_BATCH_APPLY_S=1 ASK_TICK_RUN_S=8 ASK_TICK_HARD_S=9 ASK_TICK_INTERVAL_S=120
  export STUB_CHECK_SLEEP=1
  run bash "$TICK"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(last_run state)" = budget_spent ] || { echo "$output"; return 1; }
  [ "$(last_run batches)" -ge 1 ]
  [ "$(cat "$T/state/cursor-paid")" -eq $(( $(last_run batches) * 20 )) ]
}
