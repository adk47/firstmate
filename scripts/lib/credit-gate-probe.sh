#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# credit-gate-probe.sh — pure/injectable helper for scripts/smoke-test.sh's
# post-deploy check that the credit-request safety gates in muso-admin-api.sh
# are actually LIVE and enforcing on the box (issue #754).
#
# Sourced by smoke-test.sh; unit-tested by scripts/tests/credit-gate-probe.bats.
# Split out of smoke-test.sh for the same reason as lib/websearch-probe.sh:
# smoke-test.sh runs unconditional host-wide checks the instant it is invoked,
# so bats can't source it without a live gateway.
#
# WHY this check exists. CI's bats suites pin the gate functions IN THE REPO,
# which catches the likely regression (someone edits the function) before merge.
# What nothing covered until now is whether the gate landed INTACT ON THE BOX —
# an rsync exclude/keepglob drift, a hot-patch overwrite, or a partial sync can
# leave node-8 running a gate that no longer enforces, with every CI check and
# the deploy itself green. Both gates have already shipped a fail-open bug of
# exactly this class (PR #740 reject, PR #750 approve): the trigger matched the
# request body with a literal-byte grep, so a body that JSON.parse reads as
# status:"rejected"/"approved" via an inter-token newline or a \uXXXX escape
# slipped it. For the approve gate a trigger miss `return 0`s past the ENTIRE
# browser-evidence requirement — an autonomous approve with no grounding.
#
# TWO TRAPS this implementation is built around (both observed 2026-07-27 while
# hand-verifying #750 — each makes a broken probe look like a pass):
#
#   1. muso-admin-api.sh sets `set -euo pipefail` at the top. Sourcing it means
#      the FIRST gate call that returns non-zero — i.e. exactly the refusal we
#      are asserting — aborts the caller, producing ZERO output rather than a
#      failure. We therefore run every probe in an ISOLATED child bash that does
#      `set +e +u +o pipefail` after sourcing. Isolation also keeps ~2000 lines
#      of the API script's globals/`set -e` out of smoke-test.sh itself.
#
#   2. A payload that does not actually decode to the target status proves
#      nothing: a doubled backslash turns "approved" into the LITERAL
#      string, the gate correctly passes it through, and rc=0 reads just like
#      "gate missing". Every evasion payload is therefore SANITY-CHECKED with
#      jq before its gate assertion, and a sanity failure is reported as
#      PROBE-INVALID — never as a gate pass.
#
# Contract: credit_gate_probe <path-to-muso-admin-api.sh>
#   stdout : one line per assertion (ok:/BAD:/INVALID:)
#   return : 0 = every assertion held; 1 = a gate assertion failed;
#            2 = the probe itself is invalid (missing script/jq, bad payload)
# Read-only: asserts REFUSAL paths only — no API traffic, no mutation, and no
# audit row (an audited allow needs --confirmed-by, which we never pass).

# _credit_gate_probe_body — emits the child-process probe script on stdout.
# Kept as a quoted heredoc so nothing here is expanded by the parent shell.
_credit_gate_probe_body() {
    cat <<'PROBE'
SCRIPT="$1"
# The gate functions are what we want; the CLI dispatcher is not. muso-admin-api.sh
# guards it with a BASH_SOURCE test, so sourcing defines the functions and returns.
source "$SCRIPT" >/dev/null 2>&1
# TRAP 1: neutralise the sourced script's `set -euo pipefail` — without this the
# first refusal (return 1) kills this probe before it can report anything.
set +e +u +o pipefail

# Nothing here may inherit an identity/evidence/approval that would legitimately
# bypass a gate and mask a broken one.
unset REQUESTER_EMAIL CV_APPROVE_GATE_DISABLED EVIDENCE_EXCERPT \
      CONFIRMED_BY APPROVAL_MSG_ID
# Belt-and-braces: refusal paths never write an audit row, but keep any write
# that somehow happens off the real ops log.
export CREDIT_REJECT_AUDIT_PATH="${TMPDIR:-/tmp}/credit-gate-probe-audit.jsonl"

bs='\'
rc=0

# assert_gated <label> <fn> <method> <path> <body> <expected-status> <expected-marker>
# Verb/path are parameters, not constants: `case "$method_uc" in PUT|PATCH)` is a
# single droppable branch, so a PUT-only probe stays green if the PATCH arm
# regresses on the box — and PATCH /admin/credit-requests/<id> is precisely the
# route the 2026-04-22 incident found the bot using for individual approves.
assert_gated() {
    local label="$1" fn="$2" method="$3" path="$4" body="$5" want="$6" marker="$7" got out grc
    # TRAP 2: the payload must actually decode to the status under test,
    # otherwise a pass-through is meaningless and would read as a gate failure.
    got="$(printf '%s' "$body" | jq -r '.status // empty' 2>/dev/null)"
    if [[ "$got" != "$want" ]]; then
        echo "INVALID: $label — payload decodes to '${got:-<none>}', expected '$want' (probe bug, NOT a gate verdict)"
        rc=2; return
    fi
    if ! declare -F "$fn" >/dev/null 2>&1; then
        echo "BAD: $label — $fn is not defined (gate absent)"
        (( rc == 2 )) || rc=1; return
    fi
    out="$("$fn" "$method" "$path" "$body" 2>&1)"; grc=$?
    if (( grc == 0 )); then
        echo "BAD: $label — gate ALLOWED it (rc=0); expected refusal"
        (( rc == 2 )) || rc=1; return
    fi
    if [[ "$out" != *"$marker"* ]]; then
        echo "BAD: $label — refused (rc=$grc) but without '$marker'"
        (( rc == 2 )) || rc=1; return
    fi
    echo "ok: $label"
}

REJ_MARK="MUSO_CREDIT_REJECT_APPROVAL_REQUIRED"
APP_MARK="--evidence-excerpt is required"

# A gate function that is ABSENT is the worst deploy regression there is (the
# file landed truncated/replaced/not at all), and it must be reported as such —
# calling it into a subshell yields rc=127, which would otherwise be misread as
# "refused with the wrong message".
for _fn in enforce_credit_reject_gate enforce_credit_approve_gate; do
    if ! declare -F "$_fn" >/dev/null 2>&1; then
        echo "BAD: $_fn is NOT DEFINED by $SCRIPT — the gate is absent, not merely misbehaving"
        rc=1
    fi
done

COLL=/admin/credit-requests          # bulk/collection endpoint
SINGLE=/admin/credit-requests/probe  # single-credit route (the 2026-04-22 shape)

assert_gated "reject plain"       enforce_credit_reject_gate  PUT   "$COLL"   '{"requestIds":["probe"],"status":"rejected"}'  rejected "$REJ_MARK"
assert_gated "reject newline"     enforce_credit_reject_gate  PUT   "$COLL"   "$(printf '{"requestIds":["probe"],\n"status":\n"rejected"}')" rejected "$REJ_MARK"
assert_gated "reject uescape"     enforce_credit_reject_gate  PUT   "$COLL"   '{"requestIds":["probe"],"status":"'"${bs}"'u0072ejected"}' rejected "$REJ_MARK"
assert_gated "reject PATCH"       enforce_credit_reject_gate  PATCH "$SINGLE" '{"status":"rejected"}' rejected "$REJ_MARK"
assert_gated "approve plain"      enforce_credit_approve_gate PUT   "$COLL"   '{"requestIds":["probe"],"status":"approved"}'  approved "$APP_MARK"
assert_gated "approve newline"    enforce_credit_approve_gate PUT   "$COLL"   "$(printf '{"requestIds":["probe"],\n"status":\n"approved"}')" approved "$APP_MARK"
assert_gated "approve uescape"    enforce_credit_approve_gate PUT   "$COLL"   '{"requestIds":["probe"],"status":"'"${bs}"'u0061pproved"}' approved "$APP_MARK"
assert_gated "approve PATCH"      enforce_credit_approve_gate PATCH "$SINGLE" '{"status":"approved"}' approved "$APP_MARK"

# Deny-all control, run against BOTH gates. A status neither gate owns must pass
# straight through. Without this per-gate, a gate that refused EVERYTHING would
# satisfy all of its own refusal assertions above and still look green — the
# exact false green this control exists to prevent. (A reject-only control does
# not cover a deny-all approve gate, and vice versa.)
assert_passthrough() {
    local label="$1" fn="$2" out grc
    if ! declare -F "$fn" >/dev/null 2>&1; then
        # absence already reported above; don't double-count as a behavior fail
        echo "ok: $label (skipped — $fn absent, already reported)"
        return
    fi
    out="$("$fn" PUT /admin/credit-requests '{"requestIds":["probe"],"status":"user_verification_needed"}' 2>&1)"; grc=$?
    if (( grc == 0 )); then
        echo "ok: $label"
    else
        echo "BAD: $label — $fn refused a status it does not own (rc=$grc); gate may be denying everything"
        (( rc == 2 )) || rc=1
    fi
}
assert_passthrough "uvn passthrough (reject gate)"  enforce_credit_reject_gate
assert_passthrough "uvn passthrough (approve gate)" enforce_credit_approve_gate

rm -f "$CREDIT_REJECT_AUDIT_PATH" 2>/dev/null
exit $rc
PROBE
}

# credit_gate_probe <path-to-muso-admin-api.sh>
credit_gate_probe() {
    local script="$1" tmp probe_rc

    if [[ ! -f "$script" ]]; then
        echo "INVALID: script not found: $script"
        return 2
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "INVALID: jq unavailable — cannot sanity-check probe payloads"
        return 2
    fi

    tmp="$(mktemp "${TMPDIR:-/tmp}/credit-gate-probe.XXXXXX")" || {
        echo "INVALID: could not create temp probe file"
        return 2
    }
    # The emitter's success AND its output must both be checked. `bash` on an
    # EMPTY file exits 0, so a write that failed part-way (exhausted filesystem,
    # read-only TMPDIR) would run nothing and report success — probe invalidity
    # laundered into the exact false green this helper exists to prevent. Caller
    # errexit does not save us: credit_gate_probe is invoked in an `if`.
    if ! _credit_gate_probe_body > "$tmp" 2>/dev/null || [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        echo "INVALID: could not write the probe body (empty or failed write) — refusing to report a verdict"
        return 2
    fi
    # Isolated child: the sourced API script's `set -e` and globals stay in here.
    bash "$tmp" "$script"
    probe_rc=$?
    rm -f "$tmp"
    return "$probe_rc"
}
