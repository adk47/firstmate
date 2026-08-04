#!/usr/bin/env bats
# Tests for check-admin-api-gate-parity.sh: the guard that keeps the bulk-destructive
# gate's safety-critical functions identical between the two LIVE copies of
# muso-admin-api.sh (skills-all/ canonical and workspaces/operations/ — a registered
# divergence, so both really ship and both really run).
#
# check-skill-drift.sh only walks `-name SKILL.md`, so before this guard the two scripts
# could drift on gate logic with nothing watching.
#
# Hermetic: builds a throwaway tree holding COPIES of both scripts and points the guard
# at it via REPO_ROOT, so a test never edits the tracked sources.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/check-admin-api-gate-parity.sh"

CANON_REL="skills-all/muso-ops-admin/scripts/muso-admin-api.sh"
WORK_REL="workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  mkdir -p "$TEST_TMPDIR/$(dirname "$CANON_REL")" "$TEST_TMPDIR/$(dirname "$WORK_REL")"
  cp "$HYDRA_REPO/$CANON_REL" "$TEST_TMPDIR/$CANON_REL"
  cp "$HYDRA_REPO/$WORK_REL" "$TEST_TMPDIR/$WORK_REL"
  CANON="$TEST_TMPDIR/$CANON_REL"
  WORK="$TEST_TMPDIR/$WORK_REL"
  export REPO_ROOT="$TEST_TMPDIR"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# drift_gate — flip the threshold comparison in enforce_bulk_destructive_gate (3rd
# function checked) in the workspace copy only.
drift_gate() {
  perl -0pi -e 's/\(\( count >= BULK_DESTRUCTIVE_THRESHOLD \)\)/(( count > BULK_DESTRUCTIVE_THRESHOLD ))/' "$WORK"
}

# drift_approver — inject a statement into is_tier2_approver (5th function checked, i.e.
# strictly AFTER drift_gate) in the workspace copy only.
drift_approver() {
  perl -0pi -e 's/\Qis_tier2_approver() {\E/is_tier2_approver() {\n    local _injected_drift=1/' "$WORK"
}

@test "passes when both copies agree" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: bulk-destructive gate parity holds"* ]]
}

@test "comment-only divergence does NOT fail (the copies word comments differently on purpose)" {
  # Canonical says "Requester identity does NOT bypass"; the workspace copy says
  # "God-mode ... does NOT bypass". If raw text were compared this gate could never land.
  perl -0pi -e 's/# --- Bulk destructive-operation gate helpers/# --- reworded comment header/' "$WORK"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

# The normalizer redacts heredoc BODIES because the two copies word their
# messages differently on purpose. It must NOT redact the opener: replacing the
# whole `cat >&2 <<EOF` line made a redirection change normalize identically, so
# drift that sends the refusal to a file instead of stderr — invisible to the
# agent — passed the gate. Verified slipping through before the fix.

# drift_heredoc_opener — redirect the FIRST refusal heredoc inside
# enforce_bulk_destructive_gate away from stderr, in the workspace copy only.
drift_heredoc_opener() {
  perl -0pi -e 's/(enforce_bulk_destructive_gate\(\) \{.*?)cat >&2 <<EOF/$1cat >\/tmp\/swallowed <<EOF/s' "$WORK"
}

@test "catches heredoc OPENER drift (refusal redirected away from stderr)" {
  drift_heredoc_opener
  grep -q 'cat >/tmp/swallowed <<EOF' "$WORK"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VIOLATION: enforce_bulk_destructive_gate()"* ]]
  [[ "$output" == *"swallowed"* ]]
}

@test "catches a plain \$VAR change inside a heredoc body" {
  # Matching only $(, ${ and backticks silently dropped plain $NAME, $1 and $?,
  # so a copy could change a diagnostic to expand a different (or sensitive)
  # variable and still pass parity.
  perl -0pi -e 's/(enforce_bulk_destructive_gate\(\) \{.*?)\$\{BULK_DESTRUCTIVE_WINDOW_SECS\}/$1\$HOME/s' "$WORK"
  grep -q 'HOME' "$WORK"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"VIOLATION: enforce_bulk_destructive_gate()"* ]]
}

@test "heredoc BODY prose may still differ between the copies" {
  perl -0pi -e 's/does NOT bypass/COMPLETELY REWORDED does NOT bypass/' "$WORK"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "catches a real logic flip in enforce_bulk_destructive_gate" {
  drift_gate
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VIOLATION: enforce_bulk_destructive_gate()"* ]]
  [[ "$output" == *"count >= BULK_DESTRUCTIVE_THRESHOLD"* ]]
}

# Regression: the diagnostic `diff -u | head | sed` pipeline exits non-zero by design
# whenever it finds the drift. Under `set -euo pipefail` that killed the script on the
# FIRST violation — every later function went unchecked and the aggregate FAIL never
# printed, while the exit code still looked correct. These two tests pin that.

@test "reports EVERY drifted function, not just the first" {
  drift_gate
  drift_approver
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VIOLATION: enforce_bulk_destructive_gate()"* ]]
  [[ "$output" == *"VIOLATION: is_tier2_approver()"* ]]
}

@test "keeps checking functions AFTER the first violation" {
  drift_gate
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  # record_destructive_op and is_tier2_approver are compared after the drifted one.
  [[ "$output" == *"OK: record_destructive_op()"* ]]
  [[ "$output" == *"OK: is_tier2_approver()"* ]]
}

@test "prints the aggregate FAIL count with the real number of drifted functions" {
  drift_gate
  drift_approver
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL: 2 safety-critical function(s)/region(s) drifted"* ]]
}

# --- regions outside the tracked function bodies -----------------------------
# Comparing only function bodies left the rest of the enforcement path
# unguarded: the threshold constants, the cmd_call site that invokes the gate,
# and the parser arms that capture approval evidence all live at other scopes.
# One copy could raise its threshold, stop calling the gate, or stop reading
# --confirmed-by while a function-only comparison still reported parity.

@test "catches a raised BULK_DESTRUCTIVE_THRESHOLD in one copy" {
  perl -0pi -e 's/BULK_DESTRUCTIVE_THRESHOLD="\$\{BULK_DESTRUCTIVE_THRESHOLD:-10\}"/BULK_DESTRUCTIVE_THRESHOLD="${BULK_DESTRUCTIVE_THRESHOLD:-100000}"/' "$WORK"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bulk-gate config constants"* ]]
}

@test "catches the gate invocation being removed from cmd_call" {
  perl -0pi -e 's/if ! enforce_bulk_destructive_gate "\$method" "\$path"; then/if false; then/' "$WORK"
  run "$SCRIPT"
  # Fatal (exit 2): the safety construct is absent from that copy entirely.
  # The structural assertion now catches this first and names the copy plus the
  # anchor it could not locate, which is a better diagnostic than the region
  # comparison's "matched nothing" was.
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot locate the structural anchors"* ]]
  [[ "$output" == *"WORKSPACE"* ]]
}

@test "catches the parser no longer capturing --confirmed-by" {
  perl -0pi -e 's/        --confirmed-by\)\n            CONFIRMED_BY="\$2"/        --confirmed-by)\n            CONFIRMED_BY=""/' "$WORK"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"approval-evidence flag parsing"* ]]
}

# An unquoted heredoc body is not inert prose — the shell expands $(...) before
# cat runs, and these messages really do read $TIER2_APPROVERS_PATH. Redacting
# every body line would let a changed or side-effecting substitution pass.

@test "catches a changed command substitution inside a heredoc body" {
  perl -0pi -e 's/(enforce_bulk_destructive_gate\(\) \{.*?)\$\(cat "\$TIER2_APPROVERS_PATH"/$1\$(cat "\/etc\/passwd"/s' "$WORK"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"passwd"* ]]
}

# The parser region compares COMPLETE case arms (label through `;;`), not just
# the label and assignment. A line-grep omitted each arm's `shift 2` and `;;`,
# so a copy could consume a different argument count — desyncing every later
# flag — or fall through into the next arm, with parity still green.

@test "catches a changed shift count in an approval-flag arm" {
  perl -0pi -e 's/(--confirmed-by\)\n            CONFIRMED_BY="\$2"\n            )shift 2/${1}shift 1/s' "$WORK"
  grep -q 'shift 1' "$WORK"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"approval-evidence flag parsing"* ]]
}

@test "catches an approval-flag arm losing its ;; (falls through)" {
  perl -0pi -e 's/(--approval-msg-id\)\n            APPROVAL_MSG_ID="\$2"\n            shift 2\n            );;/${1}: fallthrough/s' "$WORK"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"approval-evidence flag parsing"* ]]
}

# The call-site region compares the COMPLETE conditional, not just the
# invocation line. Both copies wrap the call in `if ! ...; then return 1; fi`;
# comparing only the call would let a copy keep it verbatim while neutering the
# `return 1`, so a REFUSED gate falls through to the DELETE it just blocked.

@test "catches neutered failure handling with the invocation left intact" {
  perl -0pi -e 's/(if ! enforce_bulk_destructive_gate "\$method" "\$path"; then\n        )return 1/${1}:  # swallow the refusal/s' "$WORK"
  # The call line itself is untouched — that is the point of this test.
  grep -q 'if ! enforce_bulk_destructive_gate "$method" "$path"; then' "$WORK"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bulk-gate call site"* ]]
}

@test "catches the conditional being replaced by a bare non-blocking call" {
  perl -0pi -e 's/if ! enforce_bulk_destructive_gate "\$method" "\$path"; then\n        return 1\n    fi/enforce_bulk_destructive_gate "\$method" "\$path" || true/s' "$WORK"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

# --- structural reachability (per copy, not parity) --------------------------
# The region extractors compare TEXT, which is location-blind: the
# byte-identical gate block can be moved after the request dispatch, or the
# flag arms moved after `*) break ;;`, and the extracted output is unchanged.
# These invariants are asserted per COPY — parity alone can never catch a
# relocation applied to both copies, since they still match each other.

# move_gate_past_curl <file> — relocate the unchanged gate conditional to just
# after the curl invocation. Contents identical; only position changes.
move_gate_past_curl() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
L = open(p).read().split("\n")
blk = ['    if ! enforce_bulk_destructive_gate "$method" "$path"; then',
       '        return 1',
       '    fi']
i = next(k for k, l in enumerate(L) if l == blk[0])
assert L[i:i+3] == blk, L[i:i+3]
del L[i:i+3]
c = next(k for k, l in enumerate(L) if 'curl "${curl_args[@]}"' in l)
L[c+1:c+1] = blk
open(p, "w").write("\n".join(L))
PY
}

# move_arms_after_break <file> — relocate the unchanged flag arms past the
# catch-all, making them unreachable. Contents identical.
move_arms_after_break() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
L = open(p).read().split("\n")
st = next(i for i, l in enumerate(L) if l.strip() == "--confirmed-by)")
en = next(i for i, l in enumerate(L) if i > st and l.strip() == "*) break ;;")
arms = L[st:en]
del L[st:en]
br = next(i for i, l in enumerate(L) if l.strip() == "*) break ;;")
L[br+1:br+1] = arms
open(p, "w").write("\n".join(L))
PY
}

@test "catches the gate block RELOCATED after the request dispatch" {
  move_gate_past_curl "$WORK"
  # The block itself is untouched — that is the point.
  grep -q 'if ! enforce_bulk_destructive_gate "$method" "$path"; then' "$WORK"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"AFTER the request is dispatched"* ]]
}

@test "catches the relocation even when BOTH copies move together (parity is blind to it)" {
  move_gate_past_curl "$CANON"
  move_gate_past_curl "$WORK"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CANONICAL"* ]]
  [[ "$output" == *"WORKSPACE"* ]]
}

@test "catches flag arms moved after the catch-all (unreachable)" {
  move_arms_after_break "$WORK"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unreachable"* ]]
}

@test "fails closed when a structural anchor cannot be located" {
  perl -0pi -e 's/^cmd_call\(\) \{/cmd_call_RENAMED() {/m' "$WORK"
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}

# --- fail-closed behaviour ---------------------------------------------------

@test "refuses to pass vacuously when the canonical copy is missing" {
  rm -f "$CANON"
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "refuses to pass vacuously when the workspace copy is missing" {
  rm -f "$WORK"
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "refuses to pass vacuously when a tracked function is absent from a copy" {
  perl -0pi -e 's/\Qis_tier2_approver() {\E/is_tier2_approver_RENAMED() {/' "$WORK"
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot verify parity"* ]]
}
