#!/usr/bin/env bats
# Tests for scripts/lib/restart-recovery.sh — the gate smoke-test.sh runs before
# every post-restart LLM probe of a main-profile agent.
#
# Origin (2026-09-11): a forced gateway restart (SIGUSR1, drain skipped) aborted
# 14 in-flight runs; on boot the gateway replayed the interrupted
# `agent:clio:main` turn under main-session restart recovery, and for the whole
# 16.5-minute replay (journal 14:44:18Z started → 15:00:54Z terminal) EVERY direct
# turn on that key — smoke pings, the mesh probe, operator PONGs — was rejected
# with `Session "agent:clio:main" changed while starting work. Retry.`
# (agent-command-*.js:349, claimMainSessionRecoveryOwner → "invalidated").
# The smoke test rendered that as "did not return PONG within 60s", which reads
# like a broken agent. These tests pin the classifier that tells the two apart:
# a replay is PENDING between the `started interrupted main session: <key>` line
# and the matching `restart recovery terminal: session=<key>` line, and only
# lines for THAT exact key count.

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../lib/restart-recovery.sh"
    [[ -f "$SCRIPT" ]] || { echo "SCRIPT not found: $SCRIPT" >&2; return 1; }
    # shellcheck source=../lib/restart-recovery.sh
    source "$SCRIPT"
    TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
}
teardown() { rm -rf "$TEST_TMPDIR"; }

# Verbatim journal shapes captured on node-8 (openclaw 2026.8.2), 2026-09-11.
P='2026-09-11T14:44:18+00:00 ovh-node-8 node[2936680]: 2026-09-11T14:44:18.193+00:00'
CLIO_STARTED="$P [main-session-restart-recovery] started interrupted main session: agent:clio:main"
CLIO_TERMINAL="$P [main-session-restart-recovery] main-session restart recovery terminal: session=agent:clio:main run=588e79e7-29cf-4614-9ab2-c71134c8ddc9 status=ok reason=completed"
CLIO_TERMINAL_FAILED="$P [main-session-restart-recovery] main-session restart recovery terminal: session=agent:clio:main run=588e79e7-29cf-4614-9ab2-c71134c8ddc9 status=failed reason=aborted"
CLIO_DISPATCHING="$P [main-session-restart-recovery] dispatching restart-safe recovery for agent:clio:main"
CTO_STARTED="$P [main-session-restart-recovery] started interrupted main session: agent:cto:main"
CTO_TERMINAL="$P [main-session-restart-recovery] main-session restart recovery terminal: session=agent:cto:main run=3a776d02-cd3c-4ad5-b5d1-3ad253813359 status=ok reason=completed"
CTO_SLACK_STARTED="$P [main-session-restart-recovery] started interrupted main session: agent:cto:slack:direct:u0al36nadey"
NOISE="$P [heartbeat] started
$P [main-session-restart-recovery] main-session restart recovery startup complete: started=5 settled=0 failed=0 skipped=0"

# ── restart_recovery_state: pure classification ─────────────────────

@test "no recovery lines at all → clear" {
    run restart_recovery_state agent:clio:main "$NOISE"
    [ "$output" = "clear" ]
}

@test "started with no terminal → pending" {
    run restart_recovery_state agent:clio:main "$NOISE
$CLIO_DISPATCHING
$CLIO_STARTED"
    [ "$output" = "pending" ]
}

@test "started then terminal → clear" {
    run restart_recovery_state agent:clio:main "$CLIO_STARTED
$NOISE
$CLIO_TERMINAL"
    [ "$output" = "clear" ]
}

@test "a failed terminal still clears (the cycle ended; a retry logs a new started)" {
    run restart_recovery_state agent:clio:main "$CLIO_STARTED
$CLIO_TERMINAL_FAILED"
    [ "$output" = "clear" ]
}

@test "terminal followed by a LATER started → pending (order matters, not presence)" {
    run restart_recovery_state agent:clio:main "$CLIO_STARTED
$CLIO_TERMINAL
$CLIO_STARTED"
    [ "$output" = "pending" ]
}

@test "another key's terminal does not clear ours" {
    run restart_recovery_state agent:clio:main "$CLIO_STARTED
$CTO_STARTED
$CTO_TERMINAL"
    [ "$output" = "pending" ]
}

@test "another key's started does not mark ours pending" {
    run restart_recovery_state agent:clio:main "$CTO_STARTED
$CTO_SLACK_STARTED"
    [ "$output" = "clear" ]
}

@test "a slack session key of the same agent is not the agent's main key" {
    run restart_recovery_state agent:cto:main "$CTO_SLACK_STARTED"
    [ "$output" = "clear" ]
}

@test "the dispatching line alone is not a started" {
    run restart_recovery_state agent:clio:main "$CLIO_DISPATCHING"
    [ "$output" = "clear" ]
}

# ── restart_recovery_error: the runtime's claim-rejection string ────

@test "the claim-rejection message is recognised regardless of surrounding text" {
    restart_recovery_error 'Session "agent:clio:main" changed while starting work. Retry.'
    restart_recovery_error 'error=Session "agent:clio:main" changed while starting work. Retry. conn=…'
}

# `run` + a status assertion, NOT a bare `! cmd`: in Bats a non-final
# `! command` never fails the test (negated commands are exempt from errexit,
# ShellCheck SC2314), so a matcher regressed to accept PONG would still pass.
# (`run !` needs bats >= 1.5 and node-8's CI bats is 1.10, but the status form
# is unambiguous on every version.)
@test "an ordinary reply or timeout is not a recovery error" {
    run restart_recovery_error 'PONG'
    [ "$status" -ne 0 ]
    run restart_recovery_error 'TIMEOUT'
    [ "$status" -ne 0 ]
    run restart_recovery_error ''
    [ "$status" -ne 0 ]
}

# ── restart_recovery_ping_verdict: the wiring QA round 2 caught ─────
# `openclaw agent` exits NON-ZERO on a claim rejection. The old ping_agent did
# `response=$(…) || response="TIMEOUT"`, so the exact error was replaced before
# any classifier could see it and the probe reported the generic timeout this
# change exists to eliminate. These pin: rc=1 + the error text → recovery.

@test "ping verdict: non-zero rc WITH the claim error text is recovery, not timeout/fail" {
    run restart_recovery_ping_verdict 1 'Session "agent:clio:main" changed while starting work. Retry.'
    [ "$output" = "recovery" ]
}

@test "ping verdict: rc=0 with PONG passes" {
    run restart_recovery_ping_verdict 0 'PONG'
    [ "$output" = "pass" ]
}

@test "ping verdict: rc=124 without PONG is timeout" {
    run restart_recovery_ping_verdict 124 ''
    [ "$output" = "timeout" ]
}

@test "ping verdict: rc=1 without PONG and without the claim error is fail (stderr kept for the log)" {
    run restart_recovery_ping_verdict 1 'Too many arguments for this command.'
    [ "$output" = "fail" ]
}

@test "ping verdict: non-zero rc whose ERROR echoes the prompt (PONG) is NOT a pass (QA round 3)" {
    run restart_recovery_ping_verdict 1 'request "respond with the exact word PONG" failed: authentication unavailable'
    [ "$output" = "fail" ]
}

@test "ping verdict: PONG with rc=124 is timeout, not pass (the deadline hit mid-turn)" {
    run restart_recovery_ping_verdict 124 'PONG'
    [ "$output" = "timeout" ]
}

@test "ping verdict: the claim error wins even if the text also mentions pong" {
    run restart_recovery_ping_verdict 1 'respond with PONG: Session "agent:clio:main" changed while starting work. Retry.'
    [ "$output" = "recovery" ]
}

# ── restart_recovery_wait argument validation (QA round 2) ──────────
# `[ $((now-start)) -ge abc ]` prints "integer expression expected", evaluates
# false every iteration, and the "bounded" wait never ends. Validate BEFORE
# arithmetic. Each case is wrapped in timeout(1): a regression hangs → 124 ≠ 3.

@test "wait rejects a non-integer deadline with rc 3 instead of looping forever" {
    printf '%s\n' "$CLIO_STARTED" > "$TEST_TMPDIR/journal"
    run timeout 5 env RESTART_RECOVERY_JOURNAL_FILE="$TEST_TMPDIR/journal" \
        bash -c 'source "$1"; restart_recovery_wait main agent:clio:main abc 0' _ "$SCRIPT"
    [ "$status" -eq 3 ]
}

@test "wait rejects a negative deadline and a fractional one (an EMPTY one takes the 120s default, like the smoke-test variable)" {
    printf '%s\n' "$CLIO_STARTED" > "$TEST_TMPDIR/journal"
    run timeout 5 env RESTART_RECOVERY_JOURNAL_FILE="$TEST_TMPDIR/journal" \
        bash -c 'source "$1"; restart_recovery_wait main agent:clio:main -5 0' _ "$SCRIPT"
    [ "$status" -eq 3 ]
    run timeout 5 env RESTART_RECOVERY_JOURNAL_FILE="$TEST_TMPDIR/journal" \
        bash -c 'source "$1"; restart_recovery_wait main agent:clio:main 1.5 0' _ "$SCRIPT"
    [ "$status" -eq 3 ]
}

@test "wait rejects a non-integer poll interval with rc 3" {
    printf '%s\n' "$CLIO_STARTED" > "$TEST_TMPDIR/journal"
    run timeout 5 env RESTART_RECOVERY_JOURNAL_FILE="$TEST_TMPDIR/journal" \
        bash -c 'source "$1"; restart_recovery_wait main agent:clio:main 0 x' _ "$SCRIPT"
    [ "$status" -eq 3 ]
}

# ── restart_recovery_pending_key: a probe spanning several sessions ──

@test "asymmetric window: clio clear while cto still replaying — per-key states" {
    J="$CLIO_STARTED
$CTO_STARTED
$CLIO_TERMINAL"
    run restart_recovery_state agent:clio:main "$J"
    [ "$output" = "clear" ]
    run restart_recovery_state agent:cto:main "$J"
    [ "$output" = "pending" ]
}

@test "pending_key names the downstream key when only it is pending (the mesh CTO leg)" {
    run restart_recovery_pending_key agent:clio:main,agent:cto:main "$CLIO_STARTED
$CTO_STARTED
$CLIO_TERMINAL"
    [ "$output" = "agent:cto:main" ]
}

@test "pending_key is empty when every listed key is clear" {
    run restart_recovery_pending_key agent:clio:main,agent:cto:main "$CLIO_STARTED
$CTO_STARTED
$CLIO_TERMINAL
$CTO_TERMINAL"
    [ -z "$output" ]
}

@test "pending_key over a single key behaves like state" {
    run restart_recovery_pending_key agent:clio:main "$CLIO_STARTED"
    [ "$output" = "agent:clio:main" ]
}

# ── restart_recovery_wait: bounded poll over the journal seam ───────

@test "wait returns 0 immediately when the journal is already clear" {
    printf '%s\n' "$CLIO_STARTED" "$CLIO_TERMINAL" > "$TEST_TMPDIR/journal"
    RESTART_RECOVERY_JOURNAL_FILE="$TEST_TMPDIR/journal" \
        restart_recovery_wait main agent:clio:main 0 0
}

@test "wait returns 1 when still pending at the deadline" {
    printf '%s\n' "$CLIO_STARTED" > "$TEST_TMPDIR/journal"
    run timeout 5 env RESTART_RECOVERY_JOURNAL_FILE="$TEST_TMPDIR/journal" \
        bash -c 'source "$1"; restart_recovery_wait main agent:clio:main 0 0' _ "$SCRIPT"
    [ "$status" -eq 1 ]
}

@test "wait returns 2 when the journal cannot be read" {
    run env RESTART_RECOVERY_JOURNAL_FILE="$TEST_TMPDIR/absent" \
        bash -c 'source "$1"; restart_recovery_wait main agent:clio:main 0 0' _ "$SCRIPT"
    [ "$status" -eq 2 ]
}

@test "wait over two keys returns 1 and names the one still pending" {
    printf '%s\n' "$CLIO_STARTED" "$CTO_STARTED" "$CLIO_TERMINAL" > "$TEST_TMPDIR/journal"
    run timeout 5 env RESTART_RECOVERY_JOURNAL_FILE="$TEST_TMPDIR/journal" \
        bash -c 'source "$1"; restart_recovery_wait main agent:clio:main,agent:cto:main 0 0; rc=$?; echo "$RESTART_RECOVERY_PENDING_KEY"; exit $rc' _ "$SCRIPT"
    [ "$status" -eq 1 ]
    [ "$output" = "agent:cto:main" ]
}

@test "wait polls until the terminal line lands, then returns 0" {
    printf '%s\n' "$CLIO_STARTED" > "$TEST_TMPDIR/journal"
    # Stub sleep: each poll interval appends the terminal line, so the second
    # read must observe clear. Counting calls proves the loop actually polled
    # rather than returning on the first (pending) read.
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/sleep" <<STUB
#!/usr/bin/env bash
echo x >> "$TEST_TMPDIR/sleeps"
printf '%s\n' '$CLIO_TERMINAL' >> "$TEST_TMPDIR/journal"
STUB
    chmod +x "$TEST_TMPDIR/bin/sleep"
    run env PATH="$TEST_TMPDIR/bin:$PATH" RESTART_RECOVERY_JOURNAL_FILE="$TEST_TMPDIR/journal" \
        bash -c 'source "$1"; restart_recovery_wait main agent:clio:main 600 1' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$TEST_TMPDIR/sleeps" | tr -d ' ')" -eq 1 ]
}
