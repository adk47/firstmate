#!/usr/bin/env python3
"""Cycle time per delivery stage, from recorded evidence. Stdlib only.

Answers one question with timestamps the forge wrote, not ones we remember: where
do the hours between "PR opened" and "running on the host" actually go?

    scripts/cycle-time.py record --repo Muso-AI/hydra --pr 1882 --pr 1883 \
        --out data/fleet-velocity-fable-v1/evidence.json
    scripts/cycle-time.py table --evidence data/fleet-velocity-fable-v1/evidence.json \
        --lanes data/fleet-velocity-fable-v1/lanes.json

`record` is the only part that talks to GitHub (through `gh api`). `table` is a pure
function of the evidence file, so the same file renders the same bytes on any box and
the numbers in a report can be re-derived by a reviewer.

Rules this file keeps (docs/delivery/fleet-velocity.md):

* A stage that has not finished is OPEN, printed as `>=N.N open` against the evidence's
  own `recorded_at`. It is never 0 and never blank: a fix that merged and has not
  deployed is the most expensive row in the table, not a missing one.
* A stage nobody measured is `unmeasured`. It is not folded into a neighbour and it
  does not count toward a total. The first observable effect is not on GitHub, so it
  comes from the lanes file with the evidence it rests on, or it is `unmeasured`.
* "Deployed" means a SUCCESSFUL deploy run whose head contains the merge commit. A run
  that was dispatched, or that failed before mutating the host, deployed nothing.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from datetime import datetime, timezone

QA_VERDICT = re.compile(r"Verdict:\s*(NO-GO|GO)\b")
VALIDATION_WORKFLOW = "PR Validation"
# A superseded push is `cancelled` and a metadata edit is a seconds-long stand-in run;
# neither is a validation anyone waited on (AGENTS.md "Read a red PR Validation from the
# failing JOB"). Only a run that reached a verdict counts as a CI round.
CI_VERDICTS = ("success", "failure")
MIN_REAL_RUN_S = 120

STAGES = (
    ("brief_to_start", "brief -> worker start"),
    ("start_to_commit", "start -> first commit"),
    ("commit_to_open", "first commit -> PR open"),
    ("open_to_first_verdict", "PR open -> first QA verdict"),
    ("review_rounds", "first verdict -> GO on shipped head"),
    ("go_to_merge", "GO -> merge"),
    ("merge_to_deploy", "merge -> deployed"),
    ("deploy_to_effect", "deployed -> first effect"),
)


def parse_ts(value):
    if not value:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def hours(start, end):
    return (end - start).total_seconds() / 3600.0


class Span:
    """One stage: closed (start and end), open (start only), or unmeasured."""

    def __init__(self, start=None, end=None, now=None, measured=True):
        self.start, self.end, self.now, self.measured = start, end, now, measured

    @property
    def state(self):
        if not self.measured or self.start is None:
            return "unmeasured"
        return "closed" if self.end is not None else "open"

    @property
    def hours(self):
        if self.state == "closed":
            return max(0.0, hours(self.start, self.end))
        if self.state == "open":
            return max(0.0, hours(self.start, self.now))
        return None

    def render(self):
        if self.state == "unmeasured":
            return "unmeasured"
        if self.state == "open":
            return ">=%.1f open" % self.hours
        return "%.1f" % self.hours


def qa_verdicts(reviews):
    """[(time, verdict, sha)] for every QA review that states a verdict, oldest first."""
    out = []
    for review in reviews:
        match = QA_VERDICT.search(review.get("body") or "")
        when = parse_ts(review.get("submitted_at"))
        if match and when:
            out.append((when, match.group(1), review.get("commit_id") or ""))
    return sorted(out, key=lambda row: row[0])


def real_ci_runs(runs):
    """Validation runs that reached a verdict: (created, completed, sha, queue_s)."""
    out = []
    for run in runs:
        if run.get("name") != VALIDATION_WORKFLOW or run.get("conclusion") not in CI_VERDICTS:
            continue
        created, done = parse_ts(run.get("created_at")), parse_ts(run.get("updated_at"))
        if not created or not done or (done - created).total_seconds() < MIN_REAL_RUN_S:
            continue
        out.append((created, done, run.get("head_sha") or "", run.get("queue_s")))
    return sorted(out, key=lambda row: row[0])


def deployed_at(merge_sha, merged_at, deploys, main_order):
    """Completion time of the first successful deploy whose head contains the merge.

    `main_order` is main's first-parent history, newest first. A deploy head that is not
    in it cannot be shown to contain anything, so it proves nothing (never a guess).
    """
    if not merge_sha or merge_sha not in main_order or merged_at is None:
        return None
    merge_pos = main_order.index(merge_sha)
    hits = []
    for run in deploys:
        if run.get("conclusion") != "success":
            continue
        head, done = run.get("head_sha"), parse_ts(run.get("updated_at"))
        if head in main_order and main_order.index(head) <= merge_pos and done and done >= merged_at:
            hits.append(done)
    return min(hits) if hits else None


def timeline(pr, evidence, lane=None):
    """Every stage of one PR as a Span, plus the counts a reader needs beside them."""
    lane = lane or {}
    now = parse_ts(evidence["recorded_at"])
    opened, merged = parse_ts(pr["created_at"]), parse_ts(pr.get("merged_at"))
    closed_unmerged = pr.get("state") == "closed" and merged is None
    commits = sorted(c for c in (parse_ts(x) for x in pr.get("commit_times", [])) if c)
    verdicts = qa_verdicts(pr.get("reviews", []))
    head = pr.get("head_sha") or ""
    go_on_head = [when for when, verdict, sha in verdicts if verdict == "GO" and sha == head]
    first_verdict = verdicts[0][0] if verdicts else None
    final_go = go_on_head[0] if go_on_head else None
    deploy = deployed_at(pr.get("merge_commit_sha"), merged, evidence.get("deploys", []),
                         evidence.get("main_order", []))
    # The evidence holds a bounded window of main. A merge outside it cannot be placed before or
    # after any deploy head, so its deploy is unmeasured: "still open" would be a claim.
    placed = bool(merged and pr.get("merge_commit_sha") in evidence.get("main_order", []))
    brief, started = parse_ts(lane.get("brief_at")), parse_ts(lane.get("started_at"))
    effect = parse_ts(lane.get("effect_at"))
    # An abandoned PR stops the clock at its close: nothing is waiting on it any more.
    end_of_line = parse_ts(pr.get("closed_at")) if closed_unmerged else None

    def span(start, end):
        return Span(start, end if end is not None else end_of_line, now)

    spans = {
        "brief_to_start": Span(brief, started, now, measured=bool(brief and started)),
        "start_to_commit": Span(started, commits[0] if commits else None, now,
                                measured=bool(started and commits)),
        "commit_to_open": Span(commits[0] if commits else None, opened, now, measured=bool(commits)),
        "open_to_first_verdict": span(opened, first_verdict),
        "review_rounds": span(first_verdict, final_go) if first_verdict else Span(measured=False),
        "go_to_merge": span(final_go, merged) if final_go else Span(measured=False),
        "merge_to_deploy": Span(merged, deploy, now) if placed else Span(measured=False),
        # Not on the forge. Measured only when the lane recorded what it saw and where.
        "deploy_to_effect": Span(deploy, effect, now, measured=bool(deploy and effect)),
    }
    ci = real_ci_runs(pr.get("runs", []))
    queues = [q for _, _, _, q in ci if q is not None]
    return {
        "number": pr["number"],
        "title": pr.get("title", ""),
        "state": "merged" if merged else pr.get("state", "open"),
        "spans": spans,
        "ci_runs": len(ci),
        "ci_hours": sum(hours(a, b) for a, b, _, _ in ci),
        "ci_queue_max_s": max(queues) if queues else None,
        "no_go": sum(1 for _, verdict, _ in verdicts if verdict == "NO-GO"),
        "heads_reviewed": len({sha for _, _, sha in verdicts}),
        "local_gates": lane.get("local_gates"),
        "effect_note": lane.get("effect_note", ""),
    }


def totals(rows):
    """Hours per stage across rows. Open stages count what has elapsed so far; an
    unmeasured stage adds nothing and is reported by count so a gap cannot hide."""
    out = {}
    for key, _ in STAGES:
        spans = [row["spans"][key] for row in rows]
        out[key] = {
            "hours": sum(s.hours for s in spans if s.hours is not None),
            "open": sum(1 for s in spans if s.state == "open"),
            "unmeasured": sum(1 for s in spans if s.state == "unmeasured"),
        }
    return out


def top_costs(rows, count=3):
    ranked = sorted(totals(rows).items(), key=lambda item: (-item[1]["hours"], item[0]))
    return [(key, value) for key, value in ranked if value["hours"] > 0][:count]


def render(evidence, lanes=None):
    lanes = lanes or {}
    rows = [timeline(pr, evidence, lanes.get(str(pr["number"]))) for pr in evidence["prs"]]
    rows.sort(key=lambda row: row["number"])
    labels = dict(STAGES)
    lines = [
        "Evidence recorded at %s for %s. Hours. `>=N open` = still running at that time."
        % (evidence["recorded_at"], evidence["repo"]),
        "",
        "| PR | state | " + " | ".join(label for _, label in STAGES)
        + " | CI runs (h) | max CI queue | NO-GO | heads reviewed | local gates |",
        "|" + "---|" * (len(STAGES) + 7),
    ]
    for row in rows:
        queue = "unmeasured" if row["ci_queue_max_s"] is None else "%ds" % row["ci_queue_max_s"]
        gates = "unmeasured" if row["local_gates"] is None else str(row["local_gates"])
        lines.append(
            "| #%d | %s | " % (row["number"], row["state"])
            + " | ".join(row["spans"][key].render() for key, _ in STAGES)
            + " | %d (%.1f) | %s | %d | %d | %s |"
            % (row["ci_runs"], row["ci_hours"], queue, row["no_go"], row["heads_reviewed"], gates)
        )
    sums = totals(rows)
    lines.append(
        "| **all** | | "
        + " | ".join(
            "**%.1f**%s" % (sums[key]["hours"],
                            " (%d open)" % sums[key]["open"] if sums[key]["open"] else "")
            for key, _ in STAGES
        )
        + " | %d (%.1f) | | %d | | |"
        % (sum(r["ci_runs"] for r in rows), sum(r["ci_hours"] for r in rows),
           sum(r["no_go"] for r in rows))
    )
    lines += ["", "Top costs (hours across these PRs, open stages still counting):"]
    for rank, (key, value) in enumerate(top_costs(rows), 1):
        extra = ", %d still open" % value["open"] if value["open"] else ""
        lines.append("%d. %s: %.1f h%s" % (rank, labels[key], value["hours"], extra))
    gaps = ["%s (%d of %d)" % (labels[key], sums[key]["unmeasured"], len(rows))
            for key, _ in STAGES if sums[key]["unmeasured"]]
    if gaps:
        lines += ["", "Unmeasured, and so in no total: " + "; ".join(gaps) + "."]
    notes = [(row["number"], row["effect_note"]) for row in rows if row["effect_note"]]
    if notes:
        lines += ["", "First observable effect, as the lane recorded it:"]
        lines += ["- #%d: %s" % note for note in notes]
    return "\n".join(lines) + "\n"


# ---- recording (the only part that touches the network) -------------------------------


def gh(path, paginate=False):
    cmd = ["gh", "api", path] + (["--paginate", "--slurp"] if paginate else [])
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        # A read that failed is not an empty list: an empty review list would print as
        # "no QA rounds", which is a claim about the PR and not about our network.
        raise SystemExit("cycle-time: gh api %s failed: %s" % (path, result.stderr.strip()[:300]))
    data = json.loads(result.stdout)
    if paginate:
        merged = []
        for page in data:
            merged.extend(page.get("workflow_runs", page) if isinstance(page, dict) else page)
        return merged
    return data


def record_pr(repo, number):
    pr = gh("repos/%s/pulls/%d" % (repo, number))
    commits = gh("repos/%s/pulls/%d/commits?per_page=100" % (repo, number), paginate=True)
    # The static gate (scripts/check-review-reads-paginated.sh) cannot see through gh(): paginate=True
    # is `gh api --paginate --slurp`, every page merged here. test_cycle_time.py pins both halves.
    reviews = gh("repos/%s/pulls/%d/reviews?per_page=100" % (repo, number), paginate=True)  # paginated-ok: gh(paginate=True) runs gh api --paginate --slurp and merges every page
    runs = gh("repos/%s/actions/runs?branch=%s&per_page=100" % (repo, pr["head"]["ref"]),
              paginate=True)
    kept = []
    for run in runs:
        if run.get("name") != VALIDATION_WORKFLOW:
            continue
        row = {key: run.get(key) for key in
               ("id", "name", "head_sha", "created_at", "updated_at", "conclusion")}
        if run.get("conclusion") in CI_VERDICTS:
            jobs = gh("repos/%s/actions/runs/%d/jobs?per_page=100" % (repo, run["id"]))["jobs"]
            waits = [(parse_ts(j["started_at"]) - parse_ts(j["created_at"])).total_seconds()
                     for j in jobs if j.get("started_at") and j.get("created_at")]
            row["queue_s"] = int(max(waits)) if waits else None
        kept.append(row)
    return {
        "number": number,
        "title": pr["title"],
        "state": pr["state"],
        "created_at": pr["created_at"],
        "merged_at": pr.get("merged_at"),
        "closed_at": pr.get("closed_at"),
        "head_sha": pr["head"]["sha"],
        "merge_commit_sha": pr.get("merge_commit_sha") if pr.get("merged_at") else None,
        # The author date, not the committer date: a rebase rewrites the second and would
        # move "first commit" to the time of the last rebase.
        "commit_times": [c["commit"]["author"]["date"] for c in commits],
        "reviews": [{"submitted_at": r.get("submitted_at"), "commit_id": r.get("commit_id"),
                     "body": (r.get("body") or "")[:400]} for r in reviews],
        "runs": kept,
    }


def record(repo, numbers, deploy_workflow, now):
    deploys = gh("repos/%s/actions/workflows/%s/runs?per_page=100" % (repo, deploy_workflow))
    main = gh("repos/%s/commits?sha=main&per_page=100" % repo)
    return {
        "repo": repo,
        "recorded_at": now,
        "prs": [record_pr(repo, n) for n in sorted(set(numbers))],
        "deploys": [{key: run.get(key) for key in
                     ("id", "event", "head_sha", "created_at", "updated_at", "conclusion")}
                    for run in deploys["workflow_runs"]],
        "main_order": [c["sha"] for c in main],
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    rec = sub.add_parser("record", help="read the forge once and write the evidence file")
    rec.add_argument("--repo", required=True)
    rec.add_argument("--pr", type=int, action="append", required=True)
    rec.add_argument("--deploy-workflow", default="deploy.yml")
    rec.add_argument("--out", required=True)
    tab = sub.add_parser("table", help="render the table from an evidence file (no network)")
    tab.add_argument("--evidence", required=True)
    tab.add_argument("--lanes", help="JSON: {\"<pr>\": {brief_at, started_at, local_gates, "
                                     "effect_at, effect_note, source}}")
    args = parser.parse_args(argv)
    if args.cmd == "record":
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        evidence = record(args.repo, args.pr, args.deploy_workflow, now)
        with open(args.out, "w", encoding="utf-8") as handle:
            json.dump(evidence, handle, indent=1, sort_keys=True)
            handle.write("\n")
        print("recorded %d PR(s) at %s -> %s" % (len(evidence["prs"]), now, args.out))
        return 0
    with open(args.evidence, encoding="utf-8") as handle:
        evidence = json.load(handle)
    lanes = {}
    if args.lanes:
        with open(args.lanes, encoding="utf-8") as handle:
            lanes = json.load(handle)
    sys.stdout.write(render(evidence, lanes))
    return 0


if __name__ == "__main__":
    sys.exit(main())
