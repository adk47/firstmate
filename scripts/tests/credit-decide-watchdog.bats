#!/usr/bin/env bats
# [key=doc-approval-doctrine] The DELIVERY half of the doc-verified T0/T1 class's two alerts.
#
# The python half is pinned by scripts/tests/test_credit_decide_watchdog.py. What can only
# fail here: NO_REPLY posts nothing, a firing alert posts exactly once, a watchdog that
# cannot run says so instead of going silent, and the cron entry runs this wrapper.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    TMP="$(mktemp -d)"
    export SLACK_STUB="$TMP/slack.log"
    : >"$SLACK_STUB"
    # the wrapper, with a stubbed slack-notify next to it (it sources ./lib/slack-notify.sh)
    mkdir -p "$TMP/lib"
    cp "$REPO_ROOT/scripts/credit-decide-watchdog.sh" "$TMP/credit-decide-watchdog.sh"
    cat >"$TMP/lib/slack-notify.sh" <<EOF
slack_notify_critical() { printf '%s\n===\n' "\$1" >>"$SLACK_STUB"; }
EOF
    # the wrapper also sources the maintenance guard; a planned window must stand it down
    cat >"$TMP/lib/maintenance-flag.sh" <<'EOF'
maintenance_active() { [ "${STUB_MAINTENANCE:-0}" = "1" ]; }
maintenance_reason() { printf 'stub window'; }
EOF
    chmod +x "$TMP/credit-decide-watchdog.sh"
    # a stub python that prints exactly what the test asks for, so no store is needed
    cat >"$TMP/python" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${STUB_PYTHON_OUT:-NO_REPLY}"
[ -n "${STUB_PYTHON_ERR:-}" ] && printf '%s\n' "$STUB_PYTHON_ERR" >&2
exit "${STUB_PYTHON_RC:-0}"
EOF
    chmod +x "$TMP/python"
}

teardown() {
    rm -rf "$TMP"
}

@test "NO_REPLY posts nothing (a dormant or healthy class is silent)" {
    STUB_PYTHON_OUT=NO_REPLY PYTHON_BIN="$TMP/python" run bash "$TMP/credit-decide-watchdog.sh"
    [ "$status" -eq 0 ]
    [ ! -s "$SLACK_STUB" ]
}

@test "empty output is treated exactly like NO_REPLY, never as an alert" {
    STUB_PYTHON_OUT= PYTHON_BIN="$TMP/python" run bash "$TMP/credit-decide-watchdog.sh"
    [ "$status" -eq 0 ]
    [ ! -s "$SLACK_STUB" ]
}

posts() { grep -c '^===$' "$SLACK_STUB"; }

@test "a firing alert is posted once, verbatim" {
    STUB_PYTHON_OUT=':rotating_light: doc-verified T0/T1 class: 0 approvals in the last 6h' \
        PYTHON_BIN="$TMP/python" run bash "$TMP/credit-decide-watchdog.sh"
    [ "$status" -eq 0 ]
    [ "$(posts)" = "1" ]
    grep -q '0 approvals in the last 6h' "$SLACK_STUB"
}

@test "two alerts are one post carrying both lines" {
    STUB_PYTHON_OUT=$'alert one\nalert two' PYTHON_BIN="$TMP/python" run bash "$TMP/credit-decide-watchdog.sh"
    [ "$status" -eq 0 ]
    [ "$(posts)" = "1" ]
    grep -q 'alert one' "$SLACK_STUB"
    grep -q 'alert two' "$SLACK_STUB"
}

@test "a watchdog that cannot run PAGES that it is not running" {
    STUB_PYTHON_RC=1 PYTHON_BIN="$TMP/python" run bash "$TMP/credit-decide-watchdog.sh"
    [ "$status" -eq 1 ]
    grep -q 'NOT running' "$SLACK_STUB"
}

@test "python stderr reaches the cron log, and is not posted" {
    STUB_PYTHON_ERR='doc-verify store unreadable: nope' PYTHON_BIN="$TMP/python" \
        run bash "$TMP/credit-decide-watchdog.sh"
    [[ "$output" == *"doc-verify store unreadable"* ]]
    [ ! -s "$SLACK_STUB" ]
}

@test "CREDIT_DECIDE_WATCHDOG_NOTIFY=never prints instead of posting" {
    STUB_PYTHON_OUT='alert text' PYTHON_BIN="$TMP/python" CREDIT_DECIDE_WATCHDOG_NOTIFY=never \
        run bash "$TMP/credit-decide-watchdog.sh"
    [ "$status" -eq 0 ]
    [ ! -s "$SLACK_STUB" ]
    [[ "$output" == *"alert text"* ]]
}

@test "argv reaches the python half (the cron passes none; a human can pass --json)" {
    cat >"$TMP/python" <<'EOF'
#!/usr/bin/env bash
printf 'argv:%s\n' "$*"
EOF
    chmod +x "$TMP/python"
    PYTHON_BIN="$TMP/python" CREDIT_DECIDE_WATCHDOG_NOTIFY=never \
        run bash "$TMP/credit-decide-watchdog.sh" --json --now 2026-11-04T18:00:00Z
    [[ "$output" == *"--json --now 2026-11-04T18:00:00Z"* ]]
}

@test "the shadow report has its own daily cron entry at 07:17Z" {
    run python3 - "$REPO_ROOT/cron-jobs.json" <<'PY2'
import json, sys
jobs = json.load(open(sys.argv[1]))["jobs"]
j = [x for x in jobs if x["name"] == "credit-decide-watchdog-shadow-daily"]
assert len(j) == 1, j
j = j[0]
assert j["schedule"]["expr"] == "17 7 * * *", j["schedule"]
assert j["payload"]["argv"][-1] == "--shadow-report", j["payload"]["argv"]
assert j["enabled"] is True
PY2
    [ "$status" -eq 0 ]
}

@test "the cron entry is a command job that runs this wrapper at :17" {
    run python3 - "$REPO_ROOT/cron-jobs.json" <<'PY'
import json, sys
jobs = json.load(open(sys.argv[1]))["jobs"]
hit = [j for j in jobs if j.get("name") == "credit-decide-watchdog-hourly"]
assert len(hit) == 1, hit
j = hit[0]
assert j["enabled"] is True, j
assert j["payload"]["kind"] == "command", j
assert j["payload"]["argv"] == ["bash", "/opt/hydra/scripts/credit-decide-watchdog.sh"], j
assert j["schedule"]["expr"].split()[0] == "17", j
assert j["delivery"]["mode"] == "none", j
PY
    [ "$status" -eq 0 ]
}

@test "a planned maintenance window stands the watchdog down without paging" {
    # A window stops the scheduled jobs on purpose, so "0 approvals in 6h" is the window talking.
    # The python half is never even started: the stub would print an alert if it were.
    STUB_MAINTENANCE=1 STUB_PYTHON_OUT=":rotating_light: must not post" \
        PYTHON_BIN="$TMP/python" run bash "$TMP/credit-decide-watchdog.sh"
    [ "$status" -eq 0 ]
    [ ! -s "$SLACK_STUB" ]
    [[ "$output" == *"maintenance"* ]]
}

@test "both halves are executable and the shell half parses" {
    [ -x "$REPO_ROOT/scripts/credit-decide-watchdog.sh" ]
    [ -x "$REPO_ROOT/scripts/credit-decide-watchdog.py" ]
    run bash -n "$REPO_ROOT/scripts/credit-decide-watchdog.sh"
    [ "$status" -eq 0 ]
}
