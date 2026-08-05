#!/usr/bin/env bats
# Tests for scripts/lib/mesh-probe.sh — the classifier for smoke-test.sh's
# cross-agent mesh probe (Clio -> CTO via sessions_send).
#
# Regression origin (PR #791, QA finding): the probe used to pass on
# `grep -qi 'cto\|responded\|pong\|acknowledged'`. An agent turn that exits 0
# while REPORTING FAILURE ("I couldn't reach CTO") matched that pattern, so the
# probe could announce PASS at the exact moment cross-agent messaging was
# broken. The whole point of these tests is that no rc=0-plus-plausible-prose
# combination can ever produce `pass` — only the dedicated token can.

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../lib/mesh-probe.sh"
    [[ -f "$SCRIPT" ]] || { echo "SCRIPT not found: $SCRIPT" >&2; return 1; }
    # shellcheck source=../lib/mesh-probe.sh
    source "$SCRIPT"
}

# ── the positive path ────────────────────────────────────────────────

@test "rc=0 with the MESH_OK token passes" {
    run mesh_probe_verdict 0 'MESH_OK'
    [ "$output" = "pass" ]
}

@test "rc=0 with MESH_OK among surrounding output still passes" {
    run mesh_probe_verdict 0 '[support-tools] Missing config keys: adminEmail
MESH_OK'
    [ "$output" = "pass" ]
}

# ── THE REGRESSION QA ASKED FOR ──────────────────────────────────────
# Each of these exits 0 and mentions CTO, and every one of them matched the
# OLD keyword pattern. None may pass.

@test "rc=0 reply that mentions CTO but reports failure does NOT pass" {
    run mesh_probe_verdict 0 "I couldn't reach CTO."
    [ "$output" != "pass" ]
}

@test "rc=0 explicit MESH_FAIL is classified fail, not pass" {
    run mesh_probe_verdict 0 'MESH_FAIL sessions_send returned no reply from cto'
    [ "$output" = "fail" ]
}

@test "rc=0 reply containing the old keyword 'acknowledged' does NOT pass" {
    run mesh_probe_verdict 0 'I acknowledged the request but could not deliver it.'
    [ "$output" != "pass" ]
}

@test "rc=0 reply containing the old keyword 'pong' does NOT pass" {
    run mesh_probe_verdict 0 'No pong came back from cto.'
    [ "$output" != "pass" ]
}

@test "rc=0 reply containing the old keyword 'responded' does NOT pass" {
    run mesh_probe_verdict 0 'cto never responded.'
    [ "$output" != "pass" ]
}

# ── a failure report beats the exit code, and beats a stray OK token ──

@test "MESH_FAIL wins over a co-occurring MESH_OK token" {
    run mesh_probe_verdict 0 'I was asked for MESH_OK but MESH_FAIL: cto unreachable'
    [ "$output" = "fail" ]
}

@test "MESH_FAIL is honoured even when the command exited non-zero" {
    run mesh_probe_verdict 1 'MESH_FAIL cto unreachable'
    [ "$output" = "fail" ]
}

# ── the token must be a whole word ───────────────────────────────────

@test "a token embedded in a larger identifier does not pass" {
    run mesh_probe_verdict 0 'NOT_MESH_OKAY'
    [ "$output" != "pass" ]
}

# ── non-zero exits never pass, and are classified distinctly ─────────

@test "a nonzero rc never passes even if MESH_OK appears" {
    run mesh_probe_verdict 1 'MESH_OK'
    [ "$output" = "inconclusive" ]
}

@test "usage error is reported with its stderr, never as a timeout" {
    # The exact regression this PR fixes: `agent send` exited 1 in ~0s and the
    # old `|| MESH_RESPONSE="TIMEOUT"` rendered it as a timeout for 4 months.
    run mesh_probe_detail 1 inconclusive 'Too many arguments for this command.'
    [[ "$output" == *"rc=1"* ]]
    [[ "$output" == *"Too many arguments"* ]]
    [[ "$output" != *"timed out"* ]]
}

@test "rc=124 is reported as a real timeout" {
    run mesh_probe_detail 124 inconclusive ''
    [[ "$output" == *"timed out after 60s"* ]]
}

@test "rc=0 without the token is reported as ran-but-unconfirmed" {
    run mesh_probe_detail 0 inconclusive "I couldn't reach CTO."
    [[ "$output" == *"no MESH_OK token"* ]]
    [[ "$output" != *"timed out"* ]]
}

@test "a fail verdict names the failure marker" {
    run mesh_probe_detail 0 fail 'MESH_FAIL cto unreachable'
    [[ "$output" == *"MESH_FAIL"* ]]
}

# ── prompt/classifier drift guard ────────────────────────────────────

@test "the prompt asks for exactly the tokens the classifier matches" {
    run mesh_probe_prompt
    [[ "$output" == *"MESH_OK"* ]]
    [[ "$output" == *"MESH_FAIL"* ]]
}

@test "the prompt names sessions_send and the cto agent" {
    run mesh_probe_prompt
    [[ "$output" == *"sessions_send"* ]]
    [[ "$output" == *"cto"* ]]
}
