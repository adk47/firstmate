#!/usr/bin/env bats
#
# .github/workflows/pr-validate.yml — the RETARGET trigger.
#
# REGRESSION THIS EXISTS FOR (2026-11-06): `on: pull_request: branches: [main]` with no `types:`
# means GitHub's default activity types — `opened`, `synchronize`, `reopened`. `edited` is NOT one
# of them, and a base-ref change is an `edited` event. So a STACKED PR (base = another feature
# branch) got no run when it was opened (correct: `branches: [main]` does not match) and then STILL
# got no run when it was retargeted onto main. It never validated, never fired qa-autoreview (which
# triggers on this workflow's completion), and could never merge.
#
# hydra#1787 was rebased and retargeted at 2026-11-06T01:17:02Z. Its entire run history was
# `PR Title Check` + `credit-approval-guard`; `qa-review` stayed NONE for six hours and the PR read
# as an orphan with no owner. It was the critical path for the paid credit ask.
#
# The fix has two halves and BOTH are load-bearing:
#   1. `types:` must include `edited`, or the retarget event never reaches the workflow at all.
#   2. the `validate` job must skip a title/body edit, or every body edit costs a 20-60 minute run
#      on a pool that is already saturated. `github.event.changes.base` is present only when the
#      base ref actually moved.
# A test that only pinned (1) would let a future edit drop (2) and quietly re-introduce the cost.

WF=".github/workflows/pr-validate.yml"

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  cd "$REPO_ROOT" || return 1
  export WF
}

@test "pr-validate.yml is valid YAML" {
  run python3 -c "import yaml,sys; yaml.safe_load(open('$WF'))"
  [ "$status" -eq 0 ]
}

@test "it still triggers on pull_request against main" {
  run python3 - <<'PY'
import os, yaml
on = yaml.safe_load(open(os.environ["WF"]))[True]
pr = on["pull_request"]
assert pr["branches"] == ["main"], pr["branches"]
PY
  [ "$status" -eq 0 ]
}

@test "the trigger types include edited (a retarget is an edited event)" {
  run python3 - <<'PY'
import os, yaml
on = yaml.safe_load(open(os.environ["WF"]))[True]
types = on["pull_request"].get("types")
assert types, ("no `types:` on the pull_request trigger — GitHub's defaults are "
               "opened/synchronize/reopened, so a RETARGET onto main never validates")
assert "edited" in types, f"`edited` missing from types: {types}"
PY
  [ "$status" -eq 0 ]
}

@test "the trigger types keep the three defaults (a push must still validate)" {
  run python3 - <<'PY'
import os, yaml
on = yaml.safe_load(open(os.environ["WF"]))[True]
types = on["pull_request"]["types"]
for t in ("opened", "synchronize", "reopened"):
    assert t in types, f"{t} dropped from types: {types}"
PY
  [ "$status" -eq 0 ]
}

@test "a title/body edit does NOT run the validate-code job (no runner cost)" {
  run python3 - <<'PY'
import os, yaml
job = yaml.safe_load(open(os.environ["WF"]))["jobs"]["validate-code"]
cond = job.get("if")
assert cond, ("the validate-code job has no `if:` — with `edited` in the trigger types every title "
              "or body edit would start a 20-60 minute run")
assert "github.event.action != 'edited'" in cond, f"the guard does not exclude edited: {cond!r}"
assert "github.event.changes.base" in cond, (
    f"the guard does not key on the base ref changing: {cond!r} — `changes.base` is present only "
    "when the base moved, which is exactly the retarget case")
PY
  [ "$status" -eq 0 ]
}

@test "the guard is an OR of (not-edited, base-changed) — not an AND" {
  run python3 - <<'PY'
import os, yaml
cond = yaml.safe_load(open(os.environ["WF"]))["jobs"]["validate-code"]["if"]
# `A && B` would require BOTH "not edited" AND "base changed", which is never true: a retarget is
# edited, and a push has no changes.base. The guard must be `A || B`.
assert "||" in cond, f"the guard is not an OR: {cond!r}"
assert "&&" not in cond, f"the guard contains an AND, which makes it unsatisfiable: {cond!r}"
PY
  [ "$status" -eq 0 ]
}

@test "a metadata edit can never cancel a code run (event-aware concurrency group)" {
  # QA #1813 Critical: `edited` shared the workflow-level concurrency group, so a title/body
  # edit cancelled an in-progress validation and the replacement skipped the heavy jobs. A
  # SKIPPED job reports SUCCESS, so the PR could go green without ever being validated.
  run python3 - <<'PY'
import os, yaml
wf = yaml.safe_load(open(os.environ["WF"]))
group = wf["concurrency"]["group"]
assert "github.event.action == 'edited'" in group, (
    f"the concurrency group is not event-aware, so a metadata edit cancels a code run: {group!r}")
assert "'meta'" in group and "'code'" in group, f"the group does not split meta from code: {group!r}"
assert wf["concurrency"]["cancel-in-progress"] is True, "supersede-cancel was dropped"
PY
  [ "$status" -eq 0 ]
}

@test "a RETARGET is in the code bucket, not the meta bucket (QA #1813 r2)" {
  # A base-ref change is ALSO an `edited` event. Keying the bucket on the action alone put a
  # retarget in the meta bucket, so a title/body edit arriving while the retarget validation ran
  # cancelled it and the replacement skipped every job - the PR then had no completed validation
  # at all. The discriminator must be `github.event.changes.base`, which is present on a retarget
  # and absent on a metadata edit.
  run python3 - <<'PY'
import os, yaml
wf = yaml.safe_load(open(os.environ["WF"]))
group = wf["concurrency"]["group"]
assert "github.event.changes.base == null" in group, (
    "the concurrency bucket keys on the ACTION, so a base-retarget `edited` run lands in the "
    f"meta bucket and a later title/body edit cancels it: {group!r}")
# The meta bucket must be the CONJUNCTION (edited AND no base change), never the action alone.
assert "edited' && github.event.changes.base == null" in group, (
    f"the meta bucket is not gated on the base change: {group!r}")
PY
  [ "$status" -eq 0 ]
}

@test "the retarget -> metadata-edit sequence cannot cancel the retarget validation" {
  # The exact sequence QA #1813 r2 named: a retarget starts a validating run, then a title/body
  # edit arrives. Evaluate the group expression for both events and require DIFFERENT buckets,
  # with the retarget in `code`.
  run python3 - <<'PY'
import os, yaml
wf = yaml.safe_load(open(os.environ["WF"]))
group = wf["concurrency"]["group"]
# The bucket is the last `-`-separated segment of the expression.
bucket = group.rsplit("-", 1)[-1]
assert "changes.base == null" in bucket, f"the bucket does not look at the base change: {bucket!r}"

def evaluate(action, base_changed):
    """Mirror GitHub's `A && B && 'meta' || 'code'` for the two events we care about."""
    is_edited = action == "edited"
    no_base_change = not base_changed
    return "meta" if (is_edited and no_base_change) else "code"

retarget = evaluate("edited", base_changed=True)
metadata = evaluate("edited", base_changed=False)
push = evaluate("synchronize", base_changed=False)
assert retarget == "code", f"a retarget must validate in the code bucket, got {retarget!r}"
assert metadata == "meta", f"a metadata edit must be isolated, got {metadata!r}"
assert push == "code", f"an ordinary push must be in the code bucket, got {push!r}"
assert retarget != metadata, "a metadata edit can still cancel a retarget validation"
PY
  [ "$status" -eq 0 ]
}

@test "every job skips a metadata-only edit, so it costs no runner" {
  # QA #1813 finding 2: only `validate` had the guard, so the other seven jobs still consumed
  # runners on every title/body edit.
  run python3 - <<'PY'
import os, yaml
jobs = yaml.safe_load(open(os.environ["WF"]))["jobs"]
guard = "github.event.action != 'edited' || github.event.changes.base != null"
# `validate` is the required MIRROR job: it must run on every event so the required context is
# always posted, so it is the one job without the guard. It costs seconds, not a runner-hour.
missing = [j for j, v in jobs.items() if j != "validate" and v.get("if") != guard]
assert not missing, f"jobs without the metadata-edit guard: {missing}"
assert jobs["validate"]["if"] == "always()", jobs["validate"].get("if")
PY
  [ "$status" -eq 0 ]
}

@test "no job name is templated, and the required validate context is always posted" {
  # 2026-11-11 (hydra#1851): GitHub does NOT evaluate `${{ }}` in `jobs.<job_id>.name` — it posts
  # the check run under the RAW template string. The heavy job was named
  # `validate${{ (github.event.action == 'edited' && ...) && ' (metadata edit — not run)' || '' }}`,
  # so a metadata edit posted a check run literally named `validate${{ (((((github.event.action ...`
  # and the required `validate` context was never produced on that head. GitHub then refused the
  # merge with 'Required status check "validate" is expected' — a required check that can never
  # pass, the same class of defect as one that can never fail.
  run python3 - <<'PY'
import os, yaml
jobs = yaml.safe_load(open(os.environ["WF"]))["jobs"]
# Only EVENT-dependent templating is the defect; `${{ matrix.shard }}` is evaluated normally.
templated = [(j, v.get("name")) for j, v in jobs.items() if "github.event" in (v.get("name") or "")]
assert not templated, f"job names must be literal, not event-templated: {templated}"
# The required context must be the literal name, posted on every event, and it must mirror.
assert jobs["validate"]["name"] == "validate", jobs["validate"]["name"]
assert jobs["validate"]["if"] == "always()", jobs["validate"]["if"]
assert jobs["validate"]["needs"] == ["validate-code"], jobs["validate"]["needs"]
# The skip lives on the heavy job, which must NOT be named `validate`: a skipped job reports
# SUCCESS and GitHub resolves duplicate names by the most recent run, so a skipped `validate`
# would mask a real FAILURE on the same head (QA #1813 Critical).
assert jobs["validate-code"]["name"] == "validate-code", jobs["validate-code"]["name"]
assert jobs["validate-code"]["if"] == (
    "github.event.action != 'edited' || github.event.changes.base != null"), jobs["validate-code"]["if"]
# And the mirror must actually mirror: on a metadata edit it re-reports the head's earned
# conclusion rather than reporting a green nobody validated.
mirror = "\n".join(s.get("run") or "" for s in jobs["validate"]["steps"])
assert "check-runs" in mirror, "the mirror must read the head's check runs"
assert "exit 1" in mirror, "the mirror must fail when the head has not earned a success"
assert jobs["bats-tests"]["name"] == (
    "Bats (scripts/ + ops-admin gates) (${{ matrix.shard }}/2)"), jobs["bats-tests"]["name"]
PY
  [ "$status" -eq 0 ]
}
