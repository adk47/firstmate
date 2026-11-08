#!/usr/bin/env bats
#
# .github/workflows/qa-autoreview.yml — structural guards.
#
# REGRESSION THIS EXISTS FOR (2026-11-06): the QA auto-review dispatch is
# fire-and-forget — it registers a one-shot openclaw cron job and returns. If the
# gateway restarts before that job runs, the job is removed and the review is
# aborted (`Operation aborted | Cron job removed by operator.`) and NOTHING
# retries it: the workflow's only trigger was `workflow_run`, and the PR
# Validation run that fired it has already completed, so it never fires again for
# that head. On 2026-11-06 the 05:42Z deploy's gateway reload drained with
# `timeout 0ms` at 05:48:26Z and killed hydra#1799's review 40s after dispatch
# and hydra#1800's 26s in. Both heads then carried NO `qa-review` status at all
# (hydra is not in `merge_gate_repos`, so the `pending` seed is a no-op), so the
# loss was invisible. The only recovery was to re-run PR Validation — 20-60 min
# of CI to re-fire a 10-second hand-off.
#
# The fix is a `workflow_dispatch` trigger that re-fires the hand-off for a named
# (pr, sha) without re-running CI. These tests pin the parts that make that safe:
# the trigger exists, both inputs are required, the job admits the event, the sha
# resolves from the inputs, and the guards that refuse a superseded head are
# present. A workflow that silently reviewed a stale commit would be worse than
# one that reviewed nothing, because a stale GO is indistinguishable from a real
# one and the merge gate reads it.

WF=".github/workflows/qa-autoreview.yml"

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  cd "$REPO_ROOT" || return 1
}

@test "qa-autoreview.yml is valid YAML" {
  run python3 -c "import yaml,sys; yaml.safe_load(open('$WF'))"
  [ "$status" -eq 0 ]
}

@test "it still fires on PR Validation completion (the automatic path)" {
  run python3 - <<PY
import yaml
on = yaml.safe_load(open("$WF"))[True]
wr = on["workflow_run"]
assert wr["workflows"] == ["PR Validation"], wr["workflows"]
assert wr["types"] == ["completed"], wr["types"]
PY
  [ "$status" -eq 0 ]
}

@test "it has a workflow_dispatch trigger (the recovery path)" {
  run python3 - <<PY
import yaml
on = yaml.safe_load(open("$WF"))[True]
assert "workflow_dispatch" in on, f"no workflow_dispatch trigger: {list(on)}"
PY
  [ "$status" -eq 0 ]
}

@test "workflow_dispatch requires BOTH pr and sha" {
  run python3 - <<PY
import yaml
on = yaml.safe_load(open("$WF"))[True]
inputs = on["workflow_dispatch"]["inputs"]
for name in ("pr", "sha"):
    assert name in inputs, f"missing input {name!r}: {list(inputs)}"
    assert inputs[name].get("required") is True, f"{name} must be required"
    assert inputs[name].get("type") == "string", f"{name} must be a string"
PY
  [ "$status" -eq 0 ]
}

@test "the dispatch job admits workflow_dispatch (not only workflow_run)" {
  run python3 - <<PY
import yaml
job = yaml.safe_load(open("$WF"))["jobs"]["dispatch"]
cond = job["if"]
assert "workflow_dispatch" in cond, f"job if does not admit workflow_dispatch: {cond!r}"
assert "workflow_run.event == 'pull_request'" in cond, f"lost the pull_request guard: {cond!r}"
PY
  [ "$status" -eq 0 ]
}

@test "HEAD_SHA resolves from the inputs on a manual dispatch" {
  run python3 - <<PY
import yaml
steps = yaml.safe_load(open("$WF"))["jobs"]["dispatch"]["steps"]
env = None
for s in steps:
    if (s.get("env") or {}).get("HEAD_SHA"):
        env = s["env"]
        break
assert env, "no step sets HEAD_SHA"
expr = env["HEAD_SHA"]
assert "inputs.sha" in expr, f"HEAD_SHA does not read inputs.sha: {expr!r}"
assert "workflow_run.head_sha" in expr, f"HEAD_SHA lost the automatic path: {expr!r}"
PY
  [ "$status" -eq 0 ]
}

@test "the run-name is safe on a manual dispatch (no bare workflow_run deref)" {
  export WF
  run python3 - <<'PY'
import os, yaml
rn = yaml.safe_load(open(os.environ["WF"]))["run-name"]
# On workflow_dispatch there is no workflow_run payload; a bare
# ${{ github.event.workflow_run.head_sha }} would render empty and the
# in-flight dedup in qa-dispatch-pr-review.sh keys off this string.
assert "inputs.sha" in rn, f"run-name does not handle workflow_dispatch: {rn!r}"
assert "inputs.pr" in rn, f"run-name does not handle workflow_dispatch: {rn!r}"
PY
  [ "$status" -eq 0 ]
}

@test "a manual re-dispatch refuses a head that is no longer the PR's head" {
  export WF
  run python3 - <<'PY'
import os, yaml
steps = yaml.safe_load(open(os.environ["WF"]))["jobs"]["dispatch"]["steps"]
script = "\n".join(s.get("run", "") for s in steps)
# The guard must compare the live head to the requested sha and refuse.
assert "head_now" in script, "no live-head lookup in the dispatch step"
assert 'if [ "$head_now" != "$HEAD_SHA" ]' in script, "no head-moved refusal"
assert "superseded commit" in script, "the refusal does not say why"
PY
  [ "$status" -eq 0 ]
}

@test "a manual re-dispatch resolves the NAMED PR, not the sha->PR lookup" {
  # QA #1812 finding 3: the sha->PR lookup returns empty for a sha that is the head of no OPEN PR
  # (a closed PR, a branch tip, a typo), and the empty branch exits 0 - so a manual re-dispatch of
  # such a sha reported a SUCCESSFUL job while dispatching no review and posting no refusal.
  export WF
  run python3 - <<'PY'
import os, yaml
steps = yaml.safe_load(open(os.environ["WF"]))["jobs"]["dispatch"]["steps"]
script = "\n".join(s.get("run", "") for s in steps)
# The manual branch must fetch the named PR directly.
assert 'repos/${REPO}/pulls/${INPUT_PR}' in script, (
    "the manual path does not resolve INPUT_PR directly, so a sha belonging to no open PR still "
    "exits 0 with no review and no refusal")
assert 'is not an open PR' in script, "no not-open refusal"
# The sha->PR lookup must live AFTER the manual branch, i.e. only on the automatic path.
manual = script.index('if [ "$EVENT_NAME" = "workflow_dispatch" ]')
lookup = script.index('commits/${HEAD_SHA}/pulls')
assert lookup > manual, "the sha->PR lookup still runs before the manual guard"
PY
  [ "$status" -eq 0 ]
}

@test "a manual refusal posts a status even on an UNGATED repo" {
  # QA #1812 finding 2: `say_status` returns immediately when `gated=0`, and hydra is not in
  # `.merge_gate_repos`, so a refusal failed the job and posted NOTHING on the PR. A refusal is not
  # a gate state and must not be suppressed by gate membership.
  export WF
  run python3 - <<'PY'
import os, yaml
steps = yaml.safe_load(open(os.environ["WF"]))["jobs"]["dispatch"]["steps"]
script = "\n".join(s.get("run", "") for s in steps)
assert "refuse_status()" in script, "no ungated refusal poster"
# The refusal poster must NOT carry the `gated` early-return that say_status has.
start = script.index("refuse_status()")
body = script[start:start + 400]
assert 'gated' not in body, f"refuse_status is gated, so it is a no-op on hydra: {body!r}"
# The head-moved refusal has a verified target (the named PR's live head), so it must post
# through refuse_status and not say_status. The not-open refusal has NO safe target and is
# covered by its own test below.
marker = "head moved to"
i = script.index(marker)
line_start = script.rindex("\n", 0, i) + 1
window = script[line_start:line_start + 300]
assert "refuse_status" in window, (
    f"the {marker!r} refusal does not post a status on an ungated repo: {window!r}")
assert "say_status" not in window, (
    f"the {marker!r} refusal still calls say_status, which returns early on an ungated repo")
PY
  [ "$status" -eq 0 ]
}

@test "a not-open refusal posts NO status, so it cannot mark an unrelated PR red" {
  # QA #1812 r3: the not-open branch used to post to the SUPPLIED sha. If an operator enters a
  # closed/nonexistent PR number A and the current head SHA of open PR B, the lookup for A fails
  # and the refusal lands on B's commit - overwriting B's real verdict with a refusal about A.
  # With no verified head there is no safe target, so the refusal belongs in the run log only.
  export WF
  run python3 - <<'PY'
import os, yaml
steps = yaml.safe_load(open(os.environ["WF"]))["jobs"]["dispatch"]["steps"]
script = "\n".join(s.get("run", "") for s in steps)
marker = "is not an open PR"
i = script.index(marker)
line_start = script.rindex("\n", 0, i) + 1
# The whole branch: from the `if` that tests the PR state to its `fi`.
branch_start = script.rindex("if [ -z \"$prjson\" ]", 0, i)
branch_end = script.index("fi", i) + 2
branch = script[branch_start:branch_end]
assert "refuse_status" not in branch, (
    "the not-open refusal posts a status to the supplied sha, which may be another PR's head: "
    f"{branch!r}")
assert "say_status" not in branch, f"the not-open refusal posts a status: {branch!r}"
assert "::error::" in branch, "the not-open refusal is silent in the run log too"
assert "exit 1" in branch, "the not-open refusal does not fail the job"
PY
  [ "$status" -eq 0 ]
}

@test "the dispatch step's shell is syntactically valid" {
  run python3 - <<PY
import subprocess, tempfile, yaml, os
steps = yaml.safe_load(open("$WF"))["jobs"]["dispatch"]["steps"]
script = "\n".join(s.get("run", "") for s in steps)
# `bash -n` only parses; it does not execute. Catches a broken edit to the
# guards above before it reaches a runner.
with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as f:
    f.write(script)
    path = f.name
try:
    r = subprocess.run(["bash", "-n", path], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
finally:
    os.unlink(path)
PY
  [ "$status" -eq 0 ]
}

@test "a head-moved refusal lands on the PR's LIVE head, not the superseded sha" {
  # QA #1812 finding 1: the refusal posted on the sha the operator typed. For a head-moved
  # refusal that is a superseded commit, so the requested PR carried no visible refusal - and
  # if the sha belonged to another PR, that PR's commit got marked instead.
  export WF
  run python3 - <<'PY'
import os, yaml
steps = yaml.safe_load(open(os.environ["WF"]))["jobs"]["dispatch"]["steps"]
script = "\n".join(s.get("run", "") for s in steps)
# refuse_status must accept a target sha.
start = script.index("refuse_status()")
body = script[start:start + 500]
assert 'local sha="${3:-$HEAD_SHA}"' in body, (
    f"refuse_status cannot be pointed at a specific commit: {body!r}")
assert '"$sha"' in body, "refuse_status still posts on HEAD_SHA unconditionally"
# The head-moved refusal must pass the live head.
i = script.index("head moved to")
line_start = script.rindex("\n", 0, i) + 1
line = script[line_start:script.find("\n", i)]
assert '"$head_now"' in line, (
    f"the head-moved refusal still targets the superseded sha: {line!r}")
PY
  [ "$status" -eq 0 ]
}
