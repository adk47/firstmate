#!/usr/bin/env bats
#
# .github/workflows/deploy.yml — "Rollback on failure" and "Page on failure" steps, executed as the
# runner would execute it (MUS-1849).
#
# Extracts the step's REAL `run:` body via yaml.safe_load instead of
# retyping it — a hand-typed fixture pins the test author's assumption
# instead of the shipped step, and then the test cannot fail when the step
# changes. Substitutes every `${{ ... }}` expression from an explicit dict
# and fails loud (python raises) if any expression has no substitution or
# survives the substitution — an unsubstituted expression would silently
# ship something other than what actually runs in production. Executes with
# `bash -e` because the Actions runner enforces `set -e` on `run:` bodies by
# default (workflow-syntax.md:963); plain `bash` tests a different shell
# than production.
#
# Asserts on STUB SIDE EFFECTS (a log file the stubs append to), never on
# the step's `::error::` strings — a log-string match can pass on leftover
# text even when the real invocation is gone.
#
# ⚠️ CONTAINMENT: the real step body calls ./scripts/rollback.sh (rsyncs
# over /opt/hydra on node-8) and scripts/lib/deploy-notify.sh (posts to
# production Slack with real bot credentials when run on the self-hosted
# `hydra` runner). Every test here builds a synthetic scripts/ tree under
# $BATS_TEST_TMPDIR and `cd`s into it BEFORE executing the extracted body,
# so the relative paths the step calls resolve to stubs, never the real
# repo-root scripts. Never execute the body from the repo root.

WF_REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
WF="$WF_REPO_ROOT/.github/workflows/deploy.yml"

# Extract a step's REAL `run:` body into $SANDBOX/<out>. $3 is the value
# substituted for steps.rollback.outputs.action (the page step reads it).
extract_step() {
  python3 - "$WF" "$SANDBOX/$2" "$1" "${3-}" <<'PY'
import re
import sys

wf_path, out_path, step_name, rollback_action = sys.argv[1:5]
import yaml

steps = yaml.safe_load(open(wf_path))["jobs"]["deploy"]["steps"]
step = next(s for s in steps if s.get("name") == step_name)
body = step["run"]

# Explicit dict — one entry per ${{ ... }} expression the shipped body
# actually uses. Anything the body references that is missing here raises,
# so the test fails loud instead of shipping an unsubstituted expression.
subs = {
    "github.run_id": "999",
    "github.run_attempt": "1",
    "steps.detect.outputs.target": "all",
    "steps.rollback.outputs.action": rollback_action,
    "github.event.inputs.target || 'all'": "all",
    "github.sha": "deadbeefcafef00dfacade1234567890abcdef0",
    "github.actor": "test-actor",
    "github.server_url": "https://github.com",
    "github.repository": "Muso-AI/hydra",
}

def replace(m):
    key = m.group(1).strip()
    if key not in subs:
        raise SystemExit(f"no substitution registered for expression: {m.group(0)!r}")
    return subs[key]

body = re.sub(r"\$\{\{\s*(.+?)\s*\}\}", replace, body)
assert "${{" not in body, "unsubstituted ${{ expression survived substitution"
open(out_path, "w").write(body)
PY
  [ -s "$SANDBOX/$2" ]
}

setup() {
  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SANDBOX/scripts/lib"
  LOG="$SANDBOX/calls.log"
  GITHUB_OUTPUT="$SANDBOX/github_output"
  : > "$LOG"
  : > "$GITHUB_OUTPUT"

  # Stub: records that it was invoked (and whether the action output was
  # already written at that moment), never touches real node-8.
  cat > "$SANDBOX/scripts/rollback.sh" <<'EOF'
#!/usr/bin/env bash
echo "rollback.sh invoked" >> "$CALL_LOG"
grep -q '^action=' "$GITHUB_OUTPUT" && echo "action written before rollback.sh" >> "$CALL_LOG"
exit 0
EOF
  chmod +x "$SANDBOX/scripts/rollback.sh"

  # Stub: records its mode argument and message, never posts to real Slack.
  cat > "$SANDBOX/scripts/lib/deploy-notify.sh" <<'EOF'
#!/usr/bin/env bash
echo "deploy-notify.sh $1" >> "$CALL_LOG"
echo "$2" >> "$CALL_LOG"
exit 0
EOF
  chmod +x "$SANDBOX/scripts/lib/deploy-notify.sh"
}

run_step() {
  (cd "$SANDBOX" && CALL_LOG="$LOG" GITHUB_OUTPUT="$GITHUB_OUTPUT" bash -e "${1:-step.sh}")
}

# Runs python over the parsed workflow; $1 is the assertion body.
wf_py() {
  python3 - "$WF" <<PY
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["deploy"]["steps"]
names = [s.get("name") for s in steps]
by = {s.get("name"): s for s in steps}
$1
PY
}

write_gate() {
  printf '#!/usr/bin/env bash\n%s\n' "$1" > "$SANDBOX/scripts/lib/deploy-rollback-gate.sh"
  chmod +x "$SANDBOX/scripts/lib/deploy-rollback-gate.sh"
}

# Run the rollback step, then feed the action it wrote to the page step the
# way Actions feeds steps.rollback.outputs.action.
run_rollback_then_page() {
  extract_step "Rollback on failure" step.sh
  run run_step
  [ "$status" -eq 0 ]
  extract_step "Page on failure" page.sh "$(sed -n 's/^action=//p' "$GITHUB_OUTPUT")"
  run run_step page.sh
  [ "$status" -eq 0 ]
}

@test "marker owned by this run: rollback.sh invoked, action written first, page fires critical" {
  write_gate 'echo "rollback=true"; exit 0'
  run_rollback_then_page
  grep -qx "rollback.sh invoked" "$LOG"
  grep -qx "action written before rollback.sh" "$LOG"
  grep -qx "action=Rollback initiated" "$GITHUB_OUTPUT"
  grep -qx "deploy-notify.sh critical" "$LOG"
  grep -qF "*Action:* Rollback initiated" "$LOG"
}

@test "gate says rollback=false: rollback.sh NOT invoked, page still fires critical" {
  write_gate 'echo "rollback=false"; exit 0'
  run_rollback_then_page
  if grep -qx "rollback.sh invoked" "$LOG"; then false; fi
  grep -q '^action=No rollback' "$GITHUB_OUTPUT"
  grep -qx "deploy-notify.sh critical" "$LOG"
}

@test "gate crashes (exit 1): rollback.sh NOT invoked, page still fires critical" {
  write_gate 'echo "gate exploded" >&2; exit 1'
  run_rollback_then_page
  if grep -qx "rollback.sh invoked" "$LOG"; then false; fi
  grep -q '^action=No rollback' "$GITHUB_OUTPUT"
  grep -qx "deploy-notify.sh critical" "$LOG"
}

# Finding 2 (bot, 97e914ec): the rollback step's 25m cap can kill it before a
# page at its bottom runs. The page is its own step and the action is written
# BEFORE rollback.sh, so a killed rollback still leaves a truthful record.
@test "rollback step writes action= to GITHUB_OUTPUT before the first rollback.sh call" {
  run wf_py '
body = by["Rollback on failure"]["run"].splitlines()
w = next(i for i, l in enumerate(body) if "action=" in l and "GITHUB_OUTPUT" in l)
r = next(i for i, l in enumerate(body) if "./scripts/rollback.sh" in l)
assert w < r, f"action= written at line {w}, rollback.sh invoked at line {r}"
'
  [ "$status" -eq 0 ]
}

# continue-on-error on the rollback step cannot clear the DEPLOY step's
# failure, so failure() stays true for the page step; it only stops rollback
# from adding failure. Both gate on failure() and the page is a sibling.
@test "Page on failure: sibling after rollback, gates on failure(), integer timeout" {
  run wf_py '
assert "Page on failure" in names, "no Page on failure step"
assert names.index("Page on failure") == names.index("Rollback on failure") + 1
page, rb = by["Page on failure"], by["Rollback on failure"]
assert "failure()" in page["if"] and "failure()" in rb["if"]
assert isinstance(page["timeout-minutes"], int)
assert rb.get("id") == "rollback"
assert rb.get("continue-on-error") is True and page.get("continue-on-error") is True
assert "deploy-notify.sh critical" not in rb["run"], "page must not live in the rollback step"
assert "deploy-notify.sh critical" in page["run"]
'
  [ "$status" -eq 0 ]
}

@test "page body: empty rollback action falls back to UNKNOWN and still pages critical" {
  extract_step "Page on failure" page.sh ""
  run run_step page.sh
  [ "$status" -eq 0 ]
  grep -qx "deploy-notify.sh critical" "$LOG"
  grep -qF "Rollback status UNKNOWN - the rollback handler timed out or was killed before it reported" "$LOG"
}

# Finding 1 (bot, 97e914ec): a step-level timeout made the non-blocking
# success notifier job-fatal. Bound the hang inside the step AND backstop it.
@test "success notifier: continue-on-error AND a shell timeout around deploy-notify.sh" {
  run wf_py '
s = by["Post to Slack — success"]
assert s.get("continue-on-error") is True, "continue-on-error missing"
assert isinstance(s["timeout-minutes"], int)
assert "timeout 240 bash scripts/lib/deploy-notify.sh success" in s["run"], "shell timeout missing"
p = by["Page on failure"]["run"]
assert "timeout 240 bash scripts/lib/deploy-notify.sh critical" in p, "page notifier not bounded"
'
  [ "$status" -eq 0 ]
}

# Bot NO-GO @2142c7293: the optional notification-path probe got a step timeout;
# without continue-on-error a stall there fails the job and skips the stale-check
# and deploy steps, so no rollback or page runs.
@test "notification-path probe: non-blocking (continue-on-error) with an integer timeout" {
  run wf_py '
s = by["Check deploy notification path"]
assert s.get("continue-on-error") is True, "continue-on-error missing"
assert isinstance(s["timeout-minutes"], int)
'
  [ "$status" -eq 0 ]
}

# Bot NO-GO @44c5de33d: a timed-out "Refuse stale deploys" fails before writing
# `proceed`, and Rollback/Page both gate on proceed == 'true', so a scheduled
# deploy dying in the stale check paged nobody. Rollback stays gated on the
# deploy having started; this sibling pages the pre-deploy failure.
@test "pre-deploy failure page: fires on a failed stale check without proceed, pages critical, never rolls back" {
  run wf_py '
n = "Page on pre-deploy failure"
assert n in names, "no pre-deploy page step"
s = by[n]
q = chr(39)
assert s["if"] == "failure() && steps.stale_check.outputs.proceed != " + q + "true" + q, s["if"]
assert s.get("continue-on-error") is True and isinstance(s["timeout-minutes"], int)
assert "timeout 240 bash \"$NOTIFY\" critical" in s["run"] and "scripts/lib/deploy-notify.sh" in s["run"]
assert "rollback.sh" not in s["run"]
assert "proceed" in by["Rollback on failure"]["if"]
'
  [ "$status" -eq 0 ]
}

@test "pre-deploy failure page body: posts critical via the notifier" {
  extract_step "Page on pre-deploy failure" predeploy.sh ""
  run run_step predeploy.sh
  [ "$status" -eq 0 ]
  grep -qx "deploy-notify.sh critical" "$LOG"
}

# A Checkout that stalls to its 10m cap fails before stale_check runs, so
# stale_check.outcome is "skipped" and every page above is skipped too. The
# pre-deploy page therefore also keys on the checkout outcome, and must not
# need the (possibly absent) workspace copy of the notifier.
@test "checkout timeout: step has an id, pre-deploy page keys on its outcome and falls back to the host notifier" {
  run wf_py '
c = by["Checkout"]
assert c.get("id") == "checkout", c
s = by["Page on pre-deploy failure"]
q = chr(39)
assert "proceed != " + q + "true" + q in s["if"], s["if"]
assert "outcome" not in s["if"], "must not key on a single step outcome"
# Checkout timeout: checkout fails, stale_check skipped -> proceed empty -> pages
# and cannot double-page with Page on failure (proceed == 'true').
assert "proceed == " + q + "true" + q in by["Page on failure"]["if"], by["Page on failure"]["if"]
assert "/opt/hydra/scripts/lib/deploy-notify.sh" in s["run"]
'
  [ "$status" -eq 0 ]
}

@test "pre-deploy failure page body: workspace notifier missing (checkout died) -> host copy pages critical" {
  extract_step "Page on pre-deploy failure" predeploy.sh ""
  grep -q "/opt/hydra/scripts/lib/deploy-notify.sh" "$SANDBOX/predeploy.sh"
  sed -i.bak 's#/opt/hydra/scripts/lib/deploy-notify.sh#scripts/lib/host-notify.sh#g' "$SANDBOX/predeploy.sh"
  mv "$SANDBOX/scripts/lib/deploy-notify.sh" "$SANDBOX/scripts/lib/host-notify.sh"
  run run_step predeploy.sh
  [ "$status" -eq 0 ]
  grep -qx "deploy-notify.sh critical" "$LOG"
}
