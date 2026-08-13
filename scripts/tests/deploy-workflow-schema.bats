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

# NOTE on actionlint: deliberately NOT gated here. It is already non-clean on
# origin/main — it flags the custom `hydra` self-hosted runner label (needs an
# actionlint.yaml to declare it) and two pre-existing SC2086 infos in steps this
# change never touched. Turning it on inside this PR would red the build on
# someone else's findings. The five structural assertions above cover the exact
# regression class that motivated this file; adopting actionlint repo-wide is a
# separate change that should land with its config and its own baseline.
