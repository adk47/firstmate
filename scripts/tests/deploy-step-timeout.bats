#!/usr/bin/env bats
#
# .github/workflows/deploy.yml — "Rollback on failure" step, executed as the
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

setup() {
  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SANDBOX/scripts/lib"
  LOG="$SANDBOX/calls.log"
  : > "$LOG"

  python3 - "$WF" "$SANDBOX/step.sh" <<'PY'
import re
import sys

wf_path, out_path = sys.argv[1], sys.argv[2]
import yaml

steps = yaml.safe_load(open(wf_path))["jobs"]["deploy"]["steps"]
step = next(s for s in steps if s.get("name") == "Rollback on failure")
body = step["run"]

# Explicit dict — one entry per ${{ ... }} expression the shipped body
# actually uses. Anything the body references that is missing here raises,
# so the test fails loud instead of shipping an unsubstituted expression.
subs = {
    "github.run_id": "999",
    "github.run_attempt": "1",
    "steps.detect.outputs.target": "all",
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
  [ -s "$SANDBOX/step.sh" ]

  # Stub: records that it was invoked, never touches real node-8.
  cat > "$SANDBOX/scripts/rollback.sh" <<'EOF'
#!/usr/bin/env bash
echo "rollback.sh invoked" >> "$CALL_LOG"
EOF
  chmod +x "$SANDBOX/scripts/rollback.sh"

  # Stub: records its mode argument, never posts to real Slack.
  cat > "$SANDBOX/scripts/lib/deploy-notify.sh" <<'EOF'
#!/usr/bin/env bash
echo "deploy-notify.sh $1" >> "$CALL_LOG"
exit 0
EOF
  chmod +x "$SANDBOX/scripts/lib/deploy-notify.sh"
}

run_step() {
  (cd "$SANDBOX" && CALL_LOG="$LOG" bash -e step.sh)
}

@test "marker owned by this run: rollback.sh invoked AND the page fires critical" {
  cat > "$SANDBOX/scripts/lib/deploy-rollback-gate.sh" <<'EOF'
#!/usr/bin/env bash
echo "rollback=true"
exit 0
EOF
  chmod +x "$SANDBOX/scripts/lib/deploy-rollback-gate.sh"

  run run_step
  [ "$status" -eq 0 ]
  grep -qx "rollback.sh invoked" "$LOG"
  grep -qx "deploy-notify.sh critical" "$LOG"
}

@test "gate says rollback=false: rollback.sh NOT invoked, page still fires critical" {
  cat > "$SANDBOX/scripts/lib/deploy-rollback-gate.sh" <<'EOF'
#!/usr/bin/env bash
echo "rollback=false"
exit 0
EOF
  chmod +x "$SANDBOX/scripts/lib/deploy-rollback-gate.sh"

  run run_step
  [ "$status" -eq 0 ]
  if grep -qx "rollback.sh invoked" "$LOG"; then false; fi
  grep -qx "deploy-notify.sh critical" "$LOG"
}

@test "gate crashes (exit 1): rollback.sh NOT invoked, page still fires critical" {
  cat > "$SANDBOX/scripts/lib/deploy-rollback-gate.sh" <<'EOF'
#!/usr/bin/env bash
echo "gate exploded" >&2
exit 1
EOF
  chmod +x "$SANDBOX/scripts/lib/deploy-rollback-gate.sh"

  run run_step
  [ "$status" -eq 0 ]
  if grep -qx "rollback.sh invoked" "$LOG"; then false; fi
  grep -qx "deploy-notify.sh critical" "$LOG"
}
