#!/usr/bin/env python3
"""The reviewer-host half of the outbound copy gate: fetch the bodies node-8 is holding, review them, write the
signed verdicts back.

node-8 (the sender) cannot reach the reviewer model and does not hold the signing key, on purpose: it can verify a
verdict and it cannot mint one. So the review is PULLED from the host that can do both:

    1. ssh <sender> gate.py export-pending          the held bodies, one JSON line each
    2. gate.py review  (this tree, this host)       reviewer model + rubric -> signed statements
    3. ssh <sender> gate.py import-verdicts         node-8 stores only what the pinned key signed

This script sends nothing and decides nothing about a request. If the reviewer or the link is down, the bodies stay
held on node-8 and the next run picks them up; nothing is ever approved by default.

When Fable is rate-limited the round falls back to Opus (gate.py). That downgrade is an incident and it does not age
the held bodies, so this script is the one place that says it: the first rate-limited round delivers one `PAGE:` line
to the page command and fails the run, later ones stay quiet while a marker under the reviewer's state dir stands, and
the first round in which Fable answers again delivers one `CLEARED:` line and removes the marker. A line that could
not be delivered is never a page: the run fails and no marker is written, so the next round says it again.

    review_pull.py --remote 'ssh -J root@JUMP root@10.0.0.8' --key ~/.config/muso/outbound-copy-reviewer/id_ed25519 \
        --page-cmd '<the ak47 page command, as install-reviewer-host.sh --page-cmd installs it>'

Exit codes: 0 the round completed (including "nothing was waiting"), 1 some bodies are still unreviewed (reviewer
unavailable or unanswered, or a message family whose rubric this host does not have or holds differently from the
sender: `unreviewable` names each one), or this round paged (Fable became rate-limited: the held bodies are being
reviewed by the Opus fallback), 2 the round could not run (link down, the two hosts enforce different default
rubrics, bad key, or a page that could not be delivered). A round is "ok" only when every waiting body was either
ruled or is malformed. Standard library only.
"""
from __future__ import annotations

import argparse
import json
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
GATE = HERE / "gate.py"
REMOTE_GATE = "/opt/hydra/scripts/outbound_copy/gate.py"
STATE_DIR = Path.home() / ".local" / "state" / "muso" / "outbound-copy-review"
FALLBACK_MARKER = "reviewer-fallback.json"
MARKER_MAX_AGE = timedelta(hours=24)
NAME_RE = re.compile(r"^[0-9a-f]{64}\.[0-9a-f]{16}\.json$")
SSH_TIMEOUT_S = 120
PAGE_TIMEOUT_S = 120


class PullError(Exception):
    pass


def remote(prefix: list[str], remote_gate: str, args: list[str], stdin: str = "") -> str:
    """Run `python3 -I <remote_gate> <args>` on the sender. An empty prefix runs it on this host (tests)."""
    inner = ["/usr/bin/python3", "-I", remote_gate, *args]
    argv = [*prefix, " ".join(shlex.quote(a) for a in inner)] if prefix else [sys.executable, "-I", remote_gate, *args]
    try:
        p = subprocess.run(argv, input=stdin, capture_output=True, text=True, timeout=SSH_TIMEOUT_S, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        raise PullError(f"the sender could not be reached: {exc}") from exc
    if p.returncode != 0:
        raise PullError(f"the sender's gate answered rc={p.returncode}: {(p.stderr or p.stdout).strip()[:300]}")
    return p.stdout


def local(args: list[str]) -> str:
    p = subprocess.run([sys.executable, "-I", str(GATE), *args], capture_output=True, text=True, check=False)
    if p.returncode != 0:
        raise PullError(f"this host's gate answered rc={p.returncode}: {(p.stderr or p.stdout).strip()[:300]}")
    return p.stdout


def reviewer_alert(stats: dict, state_dir: Path, waiting: int) -> tuple[str, str, str]:
    """("page" | "cleared" | "", the line a person must see, what to do with the marker once it has been delivered).

    The bodies keep being reviewed, so nothing else ages and nothing else notices: the operator is told when the
    standing reviewer becomes Opus, told again when Fable answers, and never once per round (a marker is re-paged
    after MARKER_MAX_AGE, so a standing fallback says so daily rather than forever once).

    Only the FALLBACK MODEL is "the fallback answered": a lint refusal is counted in `lint_refuse` and never in
    `by_model`, and a kept `by_model` key that is not the fallback model (should the accounting ever widen) is never a
    reviewed round either."""
    marker = state_dir / FALLBACK_MARKER
    by_model = stats.get("by_model") or {}
    primary = str(stats.get("reviewer_primary") or "")
    fallback = str(stats.get("reviewer_fallback_model") or "")
    answered = {m: n for m, n in by_model.items() if fallback and m == fallback}
    if not stats.get("primary_rate_limited"):
        if not (primary and by_model.get(primary) and marker.is_file()):
            return "", "", ""
        return "cleared", (f"CLEARED: outbound-copy reviewer: Fable ({primary}) answered again "
                           f"({by_model.get(primary)} verdicts, no rate limit); the Opus fallback is over"), "remove"
    attempted = stats.get("queued", 0)
    if not answered:
        return "page", (f"PAGE: outbound-copy reviewer: Fable ({primary}) is rate-limited AND the fallback answered "
                        f"nothing; {waiting} bodies still waiting, {attempted} attempted this round, nothing "
                        f"reviewed"), ""
    answered_text = ", ".join(f"{m} ({n} verdicts)" for m, n in sorted(answered.items()))
    line = (f"PAGE: outbound-copy reviewer: Fable ({primary}) is rate-limited; {answered_text} reviewed "
            f"{sum(answered.values())} of the {waiting} held bodies and its approvals are fallback approves")
    if marker.is_file() and marker_age(marker) < MARKER_MAX_AGE:
        return "", "", ""
    return "page", line, "write"


def deliver(page_cmd: str, line: str) -> tuple[bool, str]:
    """Hand one alert line to the page command on stdin: (delivered, why not).

    A line nobody received is not a page. The caller fails the run and writes no marker, so an incident that could not
    be told is told again next round instead of being silenced by a dedupe record."""
    if not page_cmd.strip():
        return False, ("no page command is configured on this host, so a fallback cannot be told to anyone: "
                       "re-run scripts/outbound_copy/install-reviewer-host.sh with --page-cmd")
    try:
        proc = subprocess.run(shlex.split(page_cmd), input=line + "\n", capture_output=True, text=True,
                              timeout=PAGE_TIMEOUT_S, check=False)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        return False, f"the page command could not run: {exc}"
    if proc.returncode != 0:
        return False, f"the page command exited {proc.returncode}: {(proc.stderr or proc.stdout).strip()[:200]}"
    return True, ""


def keep_marker(action: str, state_dir: Path, stats: dict) -> str:
    """Carry out the marker step a delivered line asks for. "" when it stuck, else why it did not."""
    marker = state_dir / FALLBACK_MARKER
    if action == "remove":
        try:
            marker.unlink()
        except OSError as exc:
            return f"the fallback marker {marker} could not be removed ({exc}); the page repeats until it can"
    elif action == "write":
        try:
            state_dir.mkdir(parents=True, exist_ok=True)
            marker.write_text(json.dumps({"since": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                                          "primary": str(stats.get("reviewer_primary") or ""),
                                          "by_model": stats.get("by_model") or {}}, sort_keys=True), encoding="utf-8")
        except OSError as exc:
            return f"the fallback marker could not be written ({marker}: {exc}); the page repeats until it can"
    return ""


def marker_age(marker: Path) -> timedelta:
    """How long the standing-fallback marker has stood. An unreadable marker is infinitely old: an unmeasured
    state never buys silence."""
    try:
        since = datetime.strptime(json.loads(marker.read_text(encoding="utf-8"))["since"], "%Y-%m-%dT%H:%M:%SZ")
    except (OSError, ValueError, KeyError, TypeError):
        return timedelta.max
    return datetime.now(timezone.utc) - since.replace(tzinfo=timezone.utc)


def rubric_problem(prefix: list[str], remote_gate: str, campaign: str) -> str:
    """Why this host cannot review `campaign`'s bodies, or "" when it can.

    Each message family may have its own rubric file. A host that lacks it (or holds another version) cannot rule
    on that family: a verdict signed under a different rubric is void on the sender. The answer is a reason, never
    an exception, so one family's missing file does not stop the round reviewing every other family.
    """
    try:
        theirs = remote(prefix, remote_gate, ["rubric-sha256", "--campaign", campaign]).strip()
    except PullError as exc:
        return f"the sender cannot read this family's rubric: {exc}"[:300]
    try:
        ours = local(["rubric-sha256", "--campaign", campaign]).strip()
    except PullError as exc:
        return (f"this host cannot read this family's rubric ({exc}); re-run "
                "scripts/outbound_copy/install-reviewer-host.sh from the deployed tree")[:400]
    if theirs != ours:
        return (f"rubric mismatch for this family: the sender enforces {theirs[:16]} and this host {ours[:16]}; "
                "re-run scripts/outbound_copy/install-reviewer-host.sh from the deployed tree")
    return ""


def pull_once(prefix: list[str], remote_gate: str, remote_store: str, key: Path, reviewer_cmd: str = "",
              limit: int = 0, state_dir: Path = STATE_DIR, page_cmd: str = "") -> tuple[int, dict]:
    store_args = ["--store", remote_store] if remote_store else []
    # the two hosts must enforce the same rules, or every verdict signed here is void there and the queue never drains
    theirs, ours = remote(prefix, remote_gate, ["rubric-sha256"]).strip(), local(["rubric-sha256"]).strip()
    if theirs != ours:
        raise PullError(f"rubric mismatch: the sender enforces {theirs[:16]} and this host {ours[:16]}; "
                        "deploy the same policies/outbound-copy-rubric.md to both before reviewing")
    lines = [ln for ln in remote(prefix, remote_gate, ["export-pending", *store_args]).splitlines() if ln.strip()]
    out: dict = {"waiting": len(lines), "skipped_bad_line": 0}
    if not lines:
        return 0, {**out, "review": {}, "import": {"stored": 0, "rejected": 0}}
    work = Path(tempfile.mkdtemp(prefix="ocg-pull-"))
    # campaign -> why its bodies cannot be reviewed here ("" = they can). Asked once per campaign, of BOTH hosts:
    # the default-rubric check above says nothing about a family with its own rubric file.
    family_problem: dict[str, str] = {}
    out["unreviewable"] = {}
    try:
        (work / "pending").mkdir()
        for ln in lines:
            try:
                row = json.loads(ln)
                name, request = row["name"], row["request"]
                if not NAME_RE.match(name) or not isinstance(request, str):
                    raise ValueError(name)
            except (ValueError, KeyError, TypeError):
                out["skipped_bad_line"] += 1
                continue
            try:
                campaign = str(json.loads(request).get("campaign") or "")
            except (ValueError, AttributeError):
                campaign = ""               # unreadable: the review step counts it as a bad request
            if campaign and campaign not in family_problem:
                family_problem[campaign] = rubric_problem(prefix, remote_gate, campaign)
            if campaign and family_problem[campaign]:
                held = out["unreviewable"].setdefault(campaign, {"bodies": 0, "why": family_problem[campaign]})
                held["bodies"] += 1
                continue                    # never reviewed under a rubric the sender would not accept
            (work / "pending" / name).write_text(request, encoding="utf-8")
        args = ["review", "--pending-dir", str(work / "pending"), "--out-dir", str(work / "out"), "--key", str(key)]
        if reviewer_cmd:
            args += ["--reviewer-cmd", reviewer_cmd]
        if limit:
            args += ["--limit", str(limit)]
        out["review"] = json.loads(local(args).strip().splitlines()[-1])
        rows = []
        for f in sorted((work / "out" / "verdicts").glob("*.json")) if (work / "out" / "verdicts").is_dir() else []:
            sig = Path(str(f) + ".sig")
            if sig.is_file():
                rows.append(json.dumps({"statement": f.read_text(encoding="ascii"),
                                        "signature": sig.read_text(encoding="ascii")}))
        out["import"] = {"stored": 0, "rejected": 0}
        if rows:
            out["import"] = json.loads(
                remote(prefix, remote_gate, ["import-verdicts", *store_args], stdin="\n".join(rows) + "\n")
                .strip().splitlines()[-1])
        # the reviewer's raw answers are the evidence behind each verdict's response_sha256: keep them
        if (work / "out" / "responses").is_dir():
            keep = Path.home() / ".local" / "state" / "muso" / "outbound-copy-review" / "responses"
            keep.mkdir(parents=True, exist_ok=True)
            for f in (work / "out" / "responses").glob("*.txt"):
                shutil.copy2(f, keep / f.name)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    rv = out["review"]
    kind, line, marker_action = reviewer_alert(rv, state_dir, out["waiting"])
    alert_rc = 0
    if kind:
        alert = out["reviewer_alert"] = {"kind": kind, "line": line}
        delivered, why = deliver(page_cmd, line)
        alert["delivered"] = delivered
        if not delivered:
            alert["delivery_error"] = why
            alert_rc = 2
        else:
            problem = keep_marker(marker_action, state_dir, rv)
            if problem:
                alert["marker_error"] = problem
    left = (rv.get("reviewer_unavailable", 0) + rv.get("unanswered", 0) + out["import"].get("rejected", 0)
            + rv.get("rubric_unavailable", 0) + sum(h["bodies"] for h in out["unreviewable"].values()))
    return (alert_rc or (1 if left or kind == "page" else 0)), out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--remote", default="", help="the command prefix that reaches the sender, e.g. 'ssh -J root@jump "
                                                 "root@10.0.0.8' (empty: the sender's gate is on this host)")
    ap.add_argument("--remote-gate", default=REMOTE_GATE)
    ap.add_argument("--remote-store", default="", help="default: the sender gate's own default store")
    ap.add_argument("--key", required=True, help="the reviewer's signing key (never copied to the sender)")
    ap.add_argument("--reviewer-cmd", default="", help="tests only: a stand-in reviewer; it can never approve a send")
    ap.add_argument("--limit", type=int, default=0, help="review at most N bodies this round")
    ap.add_argument("--state-dir", default=str(STATE_DIR),
                    help="where the round keeps its fallback marker (default: the reviewer's own state dir)")
    ap.add_argument("--page-cmd", default="",
                    help="the command that receives each fallback page on stdin (the reviewer host's ak47 pager); "
                         "without one a rate-limited round fails and says so")
    a = ap.parse_args(argv)
    try:
        if not Path(a.key).is_file():
            raise PullError(f"signing key not found: {a.key}")
        rc, out = pull_once(shlex.split(a.remote), a.remote_gate, a.remote_store, Path(a.key), a.reviewer_cmd, a.limit,
                            Path(a.state_dir), a.page_cmd)
    except (PullError, ValueError, OSError) as exc:
        print(json.dumps({"result": "error", "reason": str(exc)[:400]}))
        return 2
    if out.get("reviewer_alert"):
        print(out["reviewer_alert"]["line"], file=sys.stderr)
        for key in ("delivery_error", "marker_error"):
            if out["reviewer_alert"].get(key):
                print(out["reviewer_alert"][key], file=sys.stderr)
    print(json.dumps({"result": "ok" if rc == 0 else "incomplete", **out}, sort_keys=True))
    return rc


if __name__ == "__main__":
    sys.exit(main())
