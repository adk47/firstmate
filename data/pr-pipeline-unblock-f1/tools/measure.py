#!/usr/bin/env python3
"""Where hydra PRs wait, and what they wait on. Read-only.

  measure.py collect --out DIR     gh api reads only; writes DIR/*.json
  measure.py table --evidence DIR  offline; prints the numbers report.md quotes

Two samples, both taken at collect time:
  merged   the 50 most recently merged PRs into main
  stalled  the 50 open, non-draft PRs with the newest head among those whose
           head is at least STALL_HOURS old (a head nobody has pushed to for a
           day is not "in review round N", it is waiting on something)

A head's verdict is read the way GitHub reads it: per check NAME, the check run
of the NEWEST WORKFLOW RUN decides (run ids are monotonic). That is why a body
edit can turn a validated head red: its run is newer than the code run.

Stdlib only. Nothing here writes to GitHub.
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO = "Muso-AI/hydra"
SAMPLE = 50
STALL_HOURS = 24
VALIDATION = "PR Validation"
REQUIRED = ("validate", "pr-title")  # ruleset 26901288 `require-ci`
KEPT_CHECKS = ("validate", "validate-code", "pr-title", "credit-approval-guard")
MIRROR = Path(__file__).resolve().parents[3] / "scripts" / "ci" / "validate-mirror.py"

OPEN_QUERY = """query($c:String){repository(owner:"Muso-AI",name:"hydra"){
pullRequests(states:OPEN,first:40,after:$c,orderBy:{field:CREATED_AT,direction:DESC}){
pageInfo{hasNextPage endCursor}
nodes{number isDraft baseRefName headRefName headRefOid mergeable mergeStateStatus
createdAt updatedAt labels(first:20){nodes{name}}
commits(last:1){nodes{commit{committedDate pushedDate}}}}}}}"""


def gh(*args: str) -> str:
    r = subprocess.run(["gh", "api", *args], capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(f"gh api {' '.join(args)[:120]}: {r.stderr.strip()[:300]}")
    return r.stdout


def jlines(text: str) -> list:
    return [json.loads(line) for line in text.splitlines() if line.strip()]


def ts(value: str | None) -> datetime | None:
    if not value:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


# ── collect ──────────────────────────────────────────────────────────────────


def head_evidence(sha: str) -> dict:
    """Every check run, commit status and workflow run GitHub holds for one head."""
    checks = jlines(
        gh(
            "--paginate",
            f"repos/{REPO}/commits/{sha}/check-runs?filter=all&per_page=100",
            "--jq",
            ".check_runs[] | {id, name, status, conclusion, started_at, completed_at, details_url, app: .app.slug}",
        )
    )
    for c in checks:
        m = re.search(r"/actions/runs/(\d+)/", c.pop("details_url") or "")
        c["run"] = int(m.group(1)) if m else None
    # Keep only what `table` and `replay` read: the evidence file is committed.
    checks = [c for c in checks if c["name"] in KEPT_CHECKS or c["name"].startswith("Bats")]
    statuses = jlines(
        gh(
            "--paginate",
            f"repos/{REPO}/commits/{sha}/statuses?per_page=100",
            "--jq",
            ".[] | {context, state, created_at, description}",
        )
    )
    runs = jlines(
        gh(
            "--paginate",
            f"repos/{REPO}/actions/runs?head_sha={sha}&per_page=100",
            "--jq",
            ".workflow_runs[] | {id, name, event, status, conclusion, created_at, run_started_at, updated_at, run_attempt}",
        )
    )
    runs = [r for r in runs if r["event"] == "pull_request"]
    return {"sha": sha, "checks": checks, "statuses": statuses, "runs": runs}


def collect(out: Path) -> int:
    out.mkdir(parents=True, exist_ok=True)
    now = datetime.now(timezone.utc).replace(microsecond=0)

    opened, cursor = [], None
    while True:
        args = ["graphql", "-f", "query=" + OPEN_QUERY]
        if cursor:
            args += ["-f", "c=" + cursor]
        page = json.loads(gh(*args))["data"]["repository"]["pullRequests"]
        opened += page["nodes"]
        if not page["pageInfo"]["hasNextPage"]:
            break
        cursor = page["pageInfo"]["endCursor"]
    open_prs = []
    for n in opened:
        commit = n["commits"]["nodes"][0]["commit"]
        open_prs.append(
            {
                "number": n["number"],  # no title: nothing reads it, and titles are free text
                "draft": n["isDraft"],
                "base": n["baseRefName"],
                "head_ref": n["headRefName"],
                "head_sha": n["headRefOid"],
                "mergeable": n["mergeable"],
                "merge_state": n["mergeStateStatus"],
                "created_at": n["createdAt"],
                "updated_at": n["updatedAt"],
                "head_at": commit.get("pushedDate") or commit["committedDate"],
                "labels": [x["name"] for x in n["labels"]["nodes"]],
            }
        )

    closed = jlines(
        gh(
            "--paginate",
            f"repos/{REPO}/pulls?state=closed&base=main&sort=updated&direction=desc&per_page=100",
            "--jq",
            ".[] | select(.merged_at != null) | {number, created_at, merged_at, head_sha: .head.sha,"
            " head_ref: .head.ref, merge_commit_sha, labels: [.labels[].name]}",
        )
    )
    merged = sorted(closed, key=lambda p: p["merged_at"], reverse=True)[:SAMPLE]

    deploys = jlines(
        gh(
            f"repos/{REPO}/actions/workflows/deploy.yml/runs?branch=main&per_page=100",
            "--jq",
            ".workflow_runs[] | {id, head_sha, event, conclusion, created_at, updated_at}",
        )
    )
    subprocess.run(["git", "fetch", "--quiet", "origin", "main"], check=True)
    good = sorted((d for d in deploys if d["conclusion"] == "success"), key=lambda d: d["updated_at"])
    for p in merged:
        p["deployed_at"] = None
        for d in good:
            if d["updated_at"] < p["merged_at"]:
                continue
            anc = subprocess.run(["git", "merge-base", "--is-ancestor", p["merge_commit_sha"], d["head_sha"]])
            if anc.returncode == 0:
                p["deployed_at"], p["deploy_run"] = d["updated_at"], d["id"]
                break

    def old_enough(p: dict) -> bool:
        return (now - ts(p["head_at"])).total_seconds() >= STALL_HOURS * 3600

    stalled = sorted(
        (p for p in open_prs if not p["draft"] and old_enough(p)), key=lambda p: p["head_at"], reverse=True
    )[:SAMPLE]

    shas = sorted({p["head_sha"] for p in merged} | {p["head_sha"] for p in open_prs})
    with ThreadPoolExecutor(max_workers=6) as pool:
        heads = {h["sha"]: h for h in pool.map(head_evidence, shas)}

    (out / "open.json").write_text(json.dumps(open_prs, indent=1) + "\n")
    (out / "merged.json").write_text(json.dumps(merged, indent=1) + "\n")
    (out / "stalled.json").write_text(json.dumps([p["number"] for p in stalled]) + "\n")
    (out / "deploys.json").write_text(json.dumps(deploys, indent=1) + "\n")
    (out / "heads.json").write_text(json.dumps(heads, separators=(",", ":"), sort_keys=True) + "\n")
    (out / "collected_at").write_text(now.isoformat().replace("+00:00", "Z") + "\n")
    print(f"collected {len(open_prs)} open, {len(merged)} merged, {len(stalled)} stalled, {len(heads)} heads at {now}")
    return 0


# ── read a head the way GitHub does ──────────────────────────────────────────


def actions_checks(head: dict, name: str) -> list[dict]:
    return [c for c in head["checks"] if c["name"] == name and c["app"] == "github-actions"]


def newest(head: dict, name: str) -> dict | None:
    """The check run that decides `name`: newest workflow run, then newest attempt."""
    runs = actions_checks(head, name)
    return max(runs, key=lambda c: (c["run"] or 0, c["id"])) if runs else None


def verdict(check: dict | None) -> str:
    if check is None:
        return "absent"
    return check["conclusion"] or "pending"


def is_meta_run(head: dict, run: int | None) -> bool:
    """A title/body edit run: its `validate-code` was skipped."""
    code = [c for c in actions_checks(head, "validate-code") if c["run"] == run]
    return bool(code) and all(c["conclusion"] == "skipped" for c in code)


def qa_state(head: dict) -> str:
    qa = [s for s in head["statuses"] if s["context"] == "qa-review"]
    return max(qa, key=lambda s: s["created_at"])["state"] if qa else "absent"


def causes(pr: dict, head: dict) -> list[str]:
    """Everything holding an open PR, most fundamental first. [0] is the primary cause."""
    out = []
    if pr["base"] != "main":
        out.append("base_not_main")
    if pr["mergeable"] == "CONFLICTING":
        out.append("conflict")
    val = newest(head, "validate")
    v = verdict(val)
    greens = [c for c in actions_checks(head, "validate") if c["conclusion"] == "success"]
    if v == "absent":
        out.append("validate_never_ran")
    elif v == "pending":
        out.append("validate_running")
    elif v != "success":
        if greens:
            out.append("validate_poisoned_by_metadata_edit")
        elif is_meta_run(head, val["run"]):
            code = [c for c in actions_checks(head, "validate-code") if c["conclusion"] != "skipped"]
            last = max(code, key=lambda c: (c["run"] or 0, c["id"]))["conclusion"] if code else None
            out.append(
                {None: "validate_meta_run_no_code_run", "cancelled": "validate_code_run_cancelled"}.get(
                    last, "validate_code_failed"
                )
            )
        else:
            out.append("validate_code_failed")
    if v == "success":
        # Before #1851 a metadata edit skipped the WHOLE run, which posted no `validate`. That run is
        # newer than the suite's, so GitHub still reads the required check as expected: BLOCKED.
        later = [r for r in head["runs"] if r["name"] == VALIDATION and r["id"] > (val["run"] or 0)]
        if later and not any(c["run"] == max(r["id"] for r in later) for c in actions_checks(head, "validate")):
            out.append("validate_absent_on_newest_run")
    if verdict(newest(head, "pr-title")) not in ("success", "absent", "pending"):
        out.append("pr_title_failed")
    qa = qa_state(head)
    if qa in ("failure", "error"):
        out.append("qa_no_go")
    elif qa == "pending":
        out.append("qa_running")
    elif qa == "absent":
        out.append("qa_never_reviewed")
    if verdict(newest(head, "credit-approval-guard")) == "failure":
        out.append("credit_guard_failed")
    if not out:
        out.append("ready_not_merged")
    return out


# ── merged PRs: stage times ──────────────────────────────────────────────────


def stages(pr: dict, head: dict) -> dict:
    """Hours per stage for one merged PR's final head. None = could not measure."""
    merged = ts(pr["merged_at"])
    pr_runs = [r for r in head["runs"] if r["event"] == "pull_request"]
    code = [c for c in actions_checks(head, "validate-code") if c["conclusion"] != "skipped"]
    starts = [ts(r["created_at"]) for r in pr_runs] or [ts(c["started_at"]) for c in code if c["started_at"]]
    push = min(starts) if starts else None
    validates = actions_checks(head, "validate")
    greens = sorted(ts(c["completed_at"]) for c in validates if c["conclusion"] == "success")
    green = greens[0] if greens else None

    # Poison: a meta run's `validate` failed on this head. The head is unmergeable from that moment
    # until a `validate` of the same or a newer run succeeds.
    fails = [c for c in validates if c["conclusion"] == "failure" and is_meta_run(head, c["run"])]
    poison_h, cleared = 0.0, None
    if fails and green:
        worst = max(fails, key=lambda c: (c["run"] or 0, c["id"]))
        after = sorted(
            ts(c["completed_at"])
            for c in validates
            if c["conclusion"] == "success" and (c["run"] or 0) >= (worst["run"] or 0) and c["id"] > worst["id"]
        )
        cleared = after[0] if after else merged
        poison_h = max(0.0, (cleared - max(green, ts(worst["completed_at"]))).total_seconds() / 3600)

    bats = [c for c in head["checks"] if c["name"].startswith("Bats") and c["conclusion"] not in (None, "skipped")]
    bats_done = max((ts(c["completed_at"]) for c in bats), default=None)
    bats_h = max(((ts(c["completed_at"]) - ts(c["started_at"])).total_seconds() / 3600 for c in bats), default=None)
    qa_go = sorted(ts(s["created_at"]) for s in head["statuses"] if s["context"] == "qa-review" and s["state"] == "success")

    def hours(a, b):
        return None if a is None or b is None else (b - a).total_seconds() / 3600

    guard_fails = sum(1 for c in actions_checks(head, "credit-approval-guard") if c["conclusion"] == "failure")
    return {
        "open_to_merge": hours(ts(pr["created_at"]), merged),
        "push_to_merge": hours(push, merged),
        "push_to_green": hours(push, green),
        "green_to_merge": hours(green, merged),
        "merge_to_deploy": hours(merged, ts(pr.get("deployed_at"))),
        "poison": poison_h,
        "poisoned": bool(fails),
        "green_to_bats_done": hours(green, bats_done),
        "bats_job": bats_h,
        "green_to_qa_go": hours(green, qa_go[0]) if qa_go else None,
        "qa_go_to_merge": hours(max(qa_go[0], green) if green else qa_go[0], merged) if qa_go else None,
        "credit_guard_failures": guard_fails,
        "_push": push,
        "_merged": merged,
        "_holds": [t for t in (bats_done, qa_go[0] if qa_go else None, green) if t is not None],
        "title_failures": sum(1 for c in actions_checks(head, "pr-title") if c["conclusion"] == "failure"),
    }


def med(values: list) -> str:
    xs = [v for v in values if v is not None]
    if not xs:
        return "unmeasured"
    return f"{statistics.median(xs):.2f} h (n={len(xs)})"


def p90(values: list) -> str:
    xs = sorted(v for v in values if v is not None)
    return "unmeasured" if not xs else f"{xs[min(len(xs) - 1, int(0.9 * len(xs)))]:.2f} h"


def tally(rows: list[list[str]]) -> tuple[dict, dict]:
    primary, anywhere = {}, {}
    for cs in rows:
        primary[cs[0]] = primary.get(cs[0], 0) + 1
        for c in cs:
            anywhere[c] = anywhere.get(c, 0) + 1
    return primary, anywhere


def table(evidence: Path) -> int:
    heads = json.loads((evidence / "heads.json").read_text())
    open_prs = json.loads((evidence / "open.json").read_text())
    merged = json.loads((evidence / "merged.json").read_text())
    stalled_ids = set(json.loads((evidence / "stalled.json").read_text()))
    print(f"collected_at {(evidence / 'collected_at').read_text().strip()}")

    rows = [stages(p, heads[p["head_sha"]]) for p in merged]
    print(f"\n## merged sample: {len(merged)} PRs, #{merged[-1]['number']}..#{merged[0]['number']},"
          f" merged {merged[-1]['merged_at']} .. {merged[0]['merged_at']}")
    for key in ("open_to_merge", "push_to_merge", "push_to_green", "green_to_merge", "merge_to_deploy",
                "green_to_bats_done", "bats_job", "green_to_qa_go", "qa_go_to_merge"):
        print(f"{key:20s} median {med([r[key] for r in rows]):22s} p90 {p90([r[key] for r in rows])}")
    undeployed = sum(1 for p in merged if not p.get("deployed_at"))
    print(f"merge_to_deploy: {undeployed} of {len(merged)} not deployed at collect time (open stage, excluded above)")
    poisoned = [(p, r) for p, r in zip(merged, rows) if r["poisoned"]]
    waits = [r["poison"] for _, r in poisoned]
    print(f"poisoned by a metadata edit: {len(poisoned)} of {len(merged)};"
          f" unmergeable-while-validated median {med(waits)}, total {sum(waits):.1f} h")
    for p, r in sorted(poisoned, key=lambda x: -x[1]["poison"]):
        print(f"  #{p['number']} poison {r['poison']:.2f} h  push_to_merge {r['push_to_merge']:.2f} h")
    clean = [r["push_to_merge"] for r in rows if not r["poisoned"]]
    dirty = [r["push_to_merge"] for r in rows if r["poisoned"]]
    print(f"push_to_merge, not poisoned: {med(clean)}; poisoned: {med(dirty)}")
    # Replay: a PR whose every metadata-edit failure the new mirror would have passed loses its
    # poison interval, but is never assumed to merge before its Bats shards, its QA GO and its own
    # green were in (the merge queue holds on all three).
    vm = load_mirror()
    after, cured = [], 0
    for p, r in zip(merged, rows):
        fixed = r["poisoned"] and all(ok for _, ok, _, _ in replay_head(vm, heads[p["head_sha"]]))
        cured += fixed
        if r["push_to_merge"] is None or not fixed:
            after.append(r["push_to_merge"])
            continue
        earliest = max([r["_merged"] - timedelta(hours=r["poison"]), *r["_holds"]])
        after.append((min(earliest, r["_merged"]) - r["_push"]).total_seconds() / 3600)
    print(f"replay with the new mirror: {cured} of {len(poisoned)} poisoned PRs would not have been poisoned")
    print(f"push_to_merge replayed, all {len(merged)}: median {med(after)}; p90 {p90(after)}")
    print(f"push_to_merge replayed, the {len(poisoned)} poisoned: median"
          f" {med([a for a, r in zip(after, rows) if r['poisoned']])} (was {med(dirty)})")
    print(f"heads with >=1 credit-approval-guard failure: {sum(1 for r in rows if r['credit_guard_failures'])};"
          f" with >=1 pr-title failure: {sum(1 for r in rows if r['title_failures'])}")

    for label, prs in (
        (f"stalled sample: newest {SAMPLE} open non-draft heads older than {STALL_HOURS} h",
         [p for p in open_prs if p["number"] in stalled_ids]),
        ("all open PRs", open_prs),
    ):
        primary, anywhere = tally([causes(p, heads[p["head_sha"]]) for p in prs])
        print(f"\n## {label}: {len(prs)}")
        print(f"{'cause':38s} primary  any")
        for c in sorted(anywhere, key=lambda c: (-primary.get(c, 0), -anywhere[c])):
            print(f"{c:38s} {primary.get(c, 0):7d} {anywhere[c]:4d}")

    print("\n## open PRs whose head is validated but unmergeable (poisoned)")
    for p in open_prs:
        cs = causes(p, heads[p["head_sha"]])
        if "validate_poisoned_by_metadata_edit" in cs:
            bad = newest(heads[p["head_sha"]], "validate")
            print(f"  #{p['number']} {p['merge_state']:9s} run {bad['run']} since {bad['completed_at']}  also: {','.join(c for c in cs if 'poison' not in c) or '-'}")
    return 0


# ── replay: what the new mirror would have reported on the recorded heads ───────────────────


def as_of(head: dict, when: datetime, skip: int | None = None) -> list[dict]:
    """The head's `validate-code` and `validate` check runs as GitHub would have listed them at `when`.

    `skip` is the recorded check run being replayed: the mirror job's own `validate`, which the live
    job sees as in progress and which must not be read back as its own verdict.
    """
    view = []
    for c in actions_checks(head, "validate-code") + actions_checks(head, "validate"):
        if not c["started_at"] or ts(c["started_at"]) > when:
            continue
        done = c["completed_at"] and ts(c["completed_at"]) <= when and c["id"] != skip
        view.append(
            {
                "id": c["id"],
                "name": c["name"],
                "app": {"slug": c["app"]},
                "details_url": f"https://github.com/{REPO}/actions/runs/{c['run']}/job/{c['id']}",
                "status": "completed" if done else "in_progress",
                "conclusion": c["conclusion"] if done else None,
            }
        )
    return view


def runs_as_of(head: dict, when: datetime) -> list[dict]:
    """The head's PR Validation runs as the Actions listing would have shown them at `when`.

    A recorded run carries its LAST attempt's status and end time, so a run that was re-run later
    reads as in progress between its attempts. That only matters for a run with no check listed
    yet at `when`, and it errs towards waiting.
    """
    view = []
    for r in head["runs"]:
        if r["name"] != VALIDATION or r["event"] != "pull_request" or ts(r["created_at"]) > when:
            continue
        done = r["status"] == "completed" and r["updated_at"] and ts(r["updated_at"]) <= when
        view.append(
            {
                "id": r["id"],
                "path": ".github/workflows/pr-validate.yml",
                "status": "completed" if done else "in_progress",
                "conclusion": r["conclusion"] if done else None,
            }
        )
    return view


def load_mirror():
    import importlib.util

    spec = importlib.util.spec_from_file_location("validate_mirror", MIRROR)
    vm = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(vm)
    return vm


def replay_head(vm, head: dict, was: str = "failure") -> list[tuple[dict, bool, float, str]]:
    """(recorded check, would the new mirror pass, seconds it waited, its last line) per recorded
    metadata-edit `validate` that concluded `was`. `failure` = the poisonings; `success` = the ones
    the old job passed, which the new one must pass too."""
    out = []
    fails = [c for c in actions_checks(head, "validate") if c["conclusion"] == was and is_meta_run(head, c["run"])]
    for f in sorted(fails, key=lambda c: c["id"]):
        at = ts(f["started_at"])
        # The shipped polling loop itself, on a clock that only `sleep` advances: each read sees
        # the head as it stood that many seconds after the edit run's `validate` started.
        clock = {"t": 0.0}
        lines: list[str] = []
        rc = vm.mirror(
            lambda: (
                as_of(head, at + timedelta(seconds=clock["t"]), skip=f["id"]),
                runs_as_of(head, at + timedelta(seconds=clock["t"])),
            ),
            own=f["run"],
            wait=vm.WAIT_SECONDS,
            appear=vm.APPEAR_SECONDS,
            poll=vm.POLL_SECONDS,
            clock=lambda: clock["t"],
            sleep=lambda s: clock.__setitem__("t", clock["t"] + s),
            log=lines.append,
        )
        why = next((ln for ln in reversed(lines) if ln.startswith("[")), "")
        out.append((f, rc == 0, clock["t"], why))
    return out


def replay(evidence: Path) -> int:
    """Run the shipped mirror over every recorded metadata-edit failure.

    A dry run on recorded production check runs, not a measurement of the deployed change: it
    assumes the same pushes and edits at the same times, and it cannot see a check run GitHub no
    longer lists.
    """
    vm = load_mirror()

    heads = json.loads((evidence / "heads.json").read_text())
    merged = {p["head_sha"]: p for p in json.loads((evidence / "merged.json").read_text())}
    opened = {p["head_sha"]: p for p in json.loads((evidence / "open.json").read_text())}
    counts: dict[str, int] = {}
    regressions = passed_before = 0
    print("pr      set     old      new   waited  edit-run validate started   then")
    for sha, head in sorted(heads.items(), key=lambda kv: (merged.get(kv[0]) or opened[kv[0]])["number"]):
        pr = merged.get(sha) or opened[sha]
        which = "merged" if sha in merged else "open"
        for f, passes, waited, why in replay_head(vm, head):
            new = "success" if passes else "failure"
            counts[new] = counts.get(new, 0) + 1
            print(f"#{pr['number']:<6d} {which:7s} failure  {new:7s} {waited:5.0f}s  {f['started_at']}  {why}")
        # The other direction: every edit run the old job passed must still pass.
        for f, passes, waited, why in replay_head(vm, head, was="success"):
            passed_before += 1
            if not passes:
                regressions += 1
                print(f"#{pr['number']:<6d} {which:7s} success  FAILURE {waited:5.0f}s  {f['started_at']}  {why}")
    print(f"\nrecorded metadata-edit `validate` failures: {sum(counts.values())}; "
          f"under the new mirror: {counts.get('success', 0)} success, {counts.get('failure', 0)} still failure")
    print(f"recorded metadata-edit `validate` successes: {passed_before}; under the new mirror: {regressions} would fail")
    return 1 if regressions else 0


def slim(evidence: Path) -> int:
    """Drop check runs nothing reads from an already-collected heads.json."""
    path = evidence / "heads.json"
    heads = json.loads(path.read_text())
    for h in heads.values():
        h["checks"] = [c for c in h["checks"] if c["name"] in KEPT_CHECKS or c["name"].startswith("Bats")]
        h["runs"] = [r for r in h["runs"] if r["event"] == "pull_request"]
    path.write_text(json.dumps(heads, separators=(",", ":"), sort_keys=True) + "\n")
    print(f"{path}: {path.stat().st_size} bytes")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("collect")
    c.add_argument("--out", type=Path, required=True)
    for name in ("table", "replay", "slim"):
        sub.add_parser(name).add_argument("--evidence", type=Path, required=True)
    args = ap.parse_args()
    if args.cmd == "collect":
        return collect(args.out)
    return {"table": table, "replay": replay, "slim": slim}[args.cmd](args.evidence)


if __name__ == "__main__":
    sys.exit(main())
