#!/usr/bin/env bats
#
# .github/workflows/deploy.yml — structural guards.
#
# REGRESSION THIS EXISTS FOR (2026-08-06): reordering steps moved the Checkout
# step above its own `with:` block, orphaning `fetch-depth: 0` onto the next
# (`run:`) step. That is schema-invalid for Actions AND silently drops the
# checkout to depth 1 — which breaks Step 4a's baseline-aware drift check
# (`git show <.deployed-sha>:<path>`), the "Refuse stale deploys" merge-base
# check, and rollback.sh's ability to materialize the last-known-good commit.
# YAML still parses, so nothing caught it until review.

WF=".github/workflows/deploy.yml"

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  cd "$REPO_ROOT" || return 1
}

@test "deploy.yml is valid YAML" {
  run python3 -c "import yaml,sys; yaml.safe_load(open('$WF'))"
  [ "$status" -eq 0 ]
}

@test "checkout requests full history (fetch-depth: 0)" {
  run python3 - <<PY
import yaml, sys
steps = yaml.safe_load(open("$WF"))["jobs"]["deploy"]["steps"]
co = [s for s in steps if str(s.get("uses", "")).startswith("actions/checkout")]
assert co, "no actions/checkout step found"
for s in co:
    d = (s.get("with") or {}).get("fetch-depth")
    assert str(d) == "0", f"checkout fetch-depth is {d!r}, expected 0"
PY
  [ "$status" -eq 0 ]
}

@test "no run-step carries a stray 'with:' (the orphaned-block bug)" {
  run python3 - <<PY
import yaml
steps = yaml.safe_load(open("$WF"))["jobs"]["deploy"]["steps"]
bad = [s.get("name") for s in steps if "run" in s and "with" in s]
assert not bad, f"run steps must not have 'with': {bad}"
PY
  [ "$status" -eq 0 ]
}

@test "every step is either a 'uses' or a 'run' step" {
  run python3 - <<PY
import yaml
steps = yaml.safe_load(open("$WF"))["jobs"]["deploy"]["steps"]
bad = [s.get("name") for s in steps if "run" not in s and "uses" not in s]
assert not bad, f"steps with neither run nor uses: {bad}"
PY
  [ "$status" -eq 0 ]
}

@test "checkout runs before any step that reads the repo" {
  run python3 - <<PY
import yaml
steps = yaml.safe_load(open("$WF"))["jobs"]["deploy"]["steps"]
idx = next(i for i, s in enumerate(steps) if str(s.get("uses", "")).startswith("actions/checkout"))
# Any earlier step referencing a repo path would read an empty workspace.
for s in steps[:idx]:
    body = s.get("run", "")
    assert "scripts/" not in body, f"step {s.get('name')!r} reads scripts/ before checkout"
PY
  [ "$status" -eq 0 ]
}

@test "workflow_dispatch exposes a one-shot full_sync boolean defaulting to false" {
  run python3 - <<PY
import yaml
wf = yaml.safe_load(open("$WF"))
on = wf.get("on", wf.get(True))  # PyYAML reads the bare key on as boolean True
inp = on["workflow_dispatch"]["inputs"].get("full_sync")
assert inp is not None, "workflow_dispatch has no full_sync input"
assert inp.get("type") == "boolean", f"full_sync type is {inp.get('type')!r}"
assert inp.get("default") is False, f"full_sync default is {inp.get('default')!r}"
PY
  [ "$status" -eq 0 ]
}

@test "Deploy with target sets HYDRA_FULL_SYNC from the input with an explicit '0' fallback" {
  run python3 - <<PY
import yaml
steps = yaml.safe_load(open("$WF"))["jobs"]["deploy"]["steps"]
st = next(s for s in steps if s.get("name") == "Deploy with target")
env = st.get("env") or {}
assert "HYDRA_FULL_SYNC" in env, "Deploy with target does not set HYDRA_FULL_SYNC"
assert env["HYDRA_FULL_SYNC"] == "\${{ github.event.inputs.full_sync == 'true' && '1' || '0' }}", repr(env["HYDRA_FULL_SYNC"])
# The button must restore the mirror with every guard intact.
for bad in ("HYDRA_FORCE", "HYDRA_SKIP_DRIFT_CHECK"):
    assert bad not in env, f"{bad} must not be set by the full_sync button"
PY
  [ "$status" -eq 0 ]
}

# NOTE on actionlint: deliberately NOT gated here. It is already non-clean on
# origin/main — it flags the custom `hydra` self-hosted runner label (needs an
# actionlint.yaml to declare it) and two pre-existing SC2086 infos in steps this
# change never touched. Turning it on inside this PR would red the build on
# someone else's findings. The five structural assertions above cover the exact
# regression class that motivated this file; adopting actionlint repo-wide is a
# separate change that should land with its config and its own baseline.

# REGRESSION THIS EXISTS FOR (MUS-1849, PR #1048 NO-GO on e28c3e5e): a
# job-level `timeout-minutes` makes GitHub CANCEL the whole job, which is not
# a step failure, so `failure()` never goes true and `Rollback on failure`
# never runs — and the cancel releases the `deploy-hydra` concurrency group
# over a half-synced /opt/hydra. Step-scoped timeouts instead kill the single
# step's process, which the step reports as a failure, so `failure()` fires
# and the existing cleanup runs. See the CTO ruling on MUS-1801 for the full
# argument and the measured per-step caps below.

@test "deploy job carries no job-level timeout-minutes" {
  run python3 - <<PY
import yaml
job = yaml.safe_load(open("$WF"))["jobs"]["deploy"]
assert "timeout-minutes" not in job, "job-level timeout-minutes cancels the job and skips failure()-gated rollback"
PY
  [ "$status" -eq 0 ]
}

@test "every step carries an integer timeout-minutes" {
  run python3 - <<PY
import yaml
steps = yaml.safe_load(open("$WF"))["jobs"]["deploy"]["steps"]
bad = [s.get("name") for s in steps if not isinstance(s.get("timeout-minutes"), int)]
assert not bad, f"steps missing an integer timeout-minutes: {bad}"
PY
  [ "$status" -eq 0 ]
}

@test "sum of step timeout-minutes caps stays under the 360m job default" {
  run python3 - <<PY
import yaml
steps = yaml.safe_load(open("$WF"))["jobs"]["deploy"]["steps"]
total = sum(s["timeout-minutes"] for s in steps)
assert total < 360, f"sum of step caps is {total}, expected < 360"
PY
  [ "$status" -eq 0 ]
}

@test "Deploy with target and Rollback on failure floors hold the measured worst case" {
  run python3 - <<PY
import yaml
steps = {s.get("name"): s for s in yaml.safe_load(open("$WF"))["jobs"]["deploy"]["steps"]}
deploy_cap = steps["Deploy with target"]["timeout-minutes"]
rollback_cap = steps["Rollback on failure"]["timeout-minutes"]
assert deploy_cap >= 30, f"Deploy with target cap is {deploy_cap}, floor is 30 (observed max 24m42s)"
assert rollback_cap >= 20, f"Rollback on failure cap is {rollback_cap}, floor is 20 (observed max 14m08s)"
PY
  [ "$status" -eq 0 ]
}

@test "Rollback on failure step still gates on failure()" {
  run python3 - <<PY
import yaml
steps = {s.get("name"): s for s in yaml.safe_load(open("$WF"))["jobs"]["deploy"]["steps"]}
cond = steps["Rollback on failure"].get("if", "")
assert "failure()" in cond, f"Rollback on failure if: is {cond!r}, expected to contain failure()"
PY
  [ "$status" -eq 0 ]
}

@test "concurrency.cancel-in-progress is still false" {
  run python3 - <<PY
import yaml
wf = yaml.safe_load(open("$WF"))
val = wf["concurrency"]["cancel-in-progress"]
assert val is False, f"concurrency.cancel-in-progress is {val!r}, expected False"
PY
  [ "$status" -eq 0 ]
}

@test "pre-deploy page condition is the literal 'nothing was deployed' predicate" {
  run python3 - <<PY
import yaml
wf = yaml.safe_load(open("$WF"))
steps = {s.get("name"): s for s in wf["jobs"][next(iter(wf["jobs"]))]["steps"]}
cond = steps["Page on pre-deploy failure"]["if"]
want = "failure() && steps.stale_check.outputs.proceed != 'true'"
assert cond == want, f"pre-deploy page if: is {cond!r}, expected {want!r}"
PY
  [ "$status" -eq 0 ]
}
