#!/usr/bin/env python3
"""bats-job-step.py: print the pull-request Bats step as a script another run can execute.

    python3 scripts/ci/bats-job-step.py <shard> <event> > step.sh && bash step.sh

WHY (2026-11-15). Since that day a pull request runs only the Bats suites
concerned by what it changes (scripts/ci/bats-scope.py), and every suite runs
on main (.github/workflows/bats-main.yml). The run on main must be the SAME
list of suites, the same shard split, the same slot and the same refusal of
skipped cases as the pull-request job, or "it runs on main" stops being true
the first time one of them is edited. So main does not carry a copy: it takes
the step out of .github/workflows/pr-validate.yml and runs it.

The step is written for GitHub, which fills in two expressions before bash sees
it. This fills in the same two and REFUSES (exit 98) if any other expression is
left, if the Bats job or its step cannot be found exactly once, or if <shard>
is not one of the job's shards. A step added later that needs a third
expression therefore fails here loudly instead of running with an empty value.

--shards prints the job's shard list as JSON, for a caller that needs it.
"""
import json
import re
import sys

import yaml

WORKFLOW = ".github/workflows/pr-validate.yml"
JOB = "bats-tests"
MARK = "scripts/bats-slot.sh"
EXPR = re.compile(r"\$\{\{\s*([^}]*?)\s*\}\}")


def die(msg):
    print(f"bats-job-step: {msg}", file=sys.stderr)
    sys.exit(98)


def load(path=WORKFLOW):
    try:
        doc = yaml.safe_load(open(path, encoding="utf-8"))
    except Exception as e:  # noqa: BLE001
        die(f"{path} could not be read: {e}")
    job = ((doc or {}).get("jobs") or {}).get(JOB)
    if not isinstance(job, dict):
        die(f"{path} has no job named {JOB}")
    shards = (((job.get("strategy") or {}).get("matrix") or {}).get("shard"))
    if not isinstance(shards, list) or not shards:
        die(f"job {JOB} has no shard matrix")
    steps = [s for s in job.get("steps") or [] if MARK in (s.get("run") or "")]
    if len(steps) != 1:
        die(f"job {JOB} has {len(steps)} steps that run {MARK}, expected exactly one")
    return shards, steps[0]["run"]


def render(run, shard, event):
    values = {"matrix.shard": str(shard), "github.event_name": event}

    def fill(m):
        name = m.group(1)
        if name not in values:
            die(f"the Bats step uses ${{{{ {name} }}}}, which this does not know how to fill in")
        return values[name]

    out = EXPR.sub(fill, run)
    if "${{" in out:
        die("an expression is left in the Bats step after filling it in")
    return out


def main(argv):
    path = WORKFLOW
    if len(argv) >= 2 and argv[0] == "--workflow":
        path, argv = argv[1], argv[2:]
    if argv == ["--shards"]:
        print(json.dumps(load(path)[0]))
        return 0
    if len(argv) != 2:
        die("usage: bats-job-step.py [--workflow FILE] <shard> <event> | --shards")
    shard, event = argv
    shards, run = load(path)
    if shard not in [str(s) for s in shards]:
        die(f"shard {shard!r} is not one of the job's shards {shards}")
    if not re.fullmatch(r"[a-z_]+", event):
        die(f"{event!r} is not an event name")
    sys.stdout.write(render(run, shard, event))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
