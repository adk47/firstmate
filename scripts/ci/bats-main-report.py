#!/usr/bin/env python3
"""bats-main-report.py: what a finished "Bats on main" run means, and who is told.

2026-11-15. A pull request runs only the Bats suites its change concerns
(scripts/ci/bats-scope.py); every suite runs on main in bats-main.yml. So a suite
two steps away from what a pull request changed can break, merge green, and show
ONLY as a red run on main. A red run nobody reads is not a safety net: the break
stays while later pull requests keep merging green past it. This is the reader.

WHO IS TOLD: NO PERSON (firstmate on #2048, 2026-11-15, Aaron's rule: no Slack ping
and no task to any person). A red run is a task for the `ci` lane, and it reaches that
lane as an Alertmanager alert, `BatsOnMainRed` with `owner=ci`. The lights second
mate's dispatcher (H-DevOps scripts/lights/am_dispatch.py) turns every firing alert
with an owner into one task. The same alert reaches #ovh-alerts through Alertmanager's
own receivers, which mention nobody, and the message this script writes for the deploy
channel mentions nobody either. The authors of what merged since the last green run
are LISTED by GitHub login, as information for whoever takes the task, never as a
mention. Every merge in that interval is counted, not only the ones the message has
room to list: the merge that broke it is as likely the first as the last (QA finding
on #2048, 2026-11-15: the first version read only the last eight).

Two earlier versions of this paragraph are history. The first named the authors by
Slack id, plus Nick and Aaron as "the on-call pair" when an author could not be
reached. The second (inbox 031) dropped Aaron and sent the rest to the owning lane
through the firstmate inbox, read from ak47. Inbox 035 dropped Nick too and moved the
whole task to the lights alert path, so neither the Slack-id map nor the ak47 reader
is used any more.

THE ALERT. Every red verdict re-raises it, and every green one resolves it, so it
fires for exactly as long as main is red. Its labels never change between runs (that
is what makes it the same alert, and one task); the commit, the failing suites and the
merges are annotations. It is raised with an end time ALERT_HOURS ahead: every push
and the nightly run re-raise it while main stays red, and a red main that stops being
run still expires, rather than firing forever. A report whose run is older than the
newest finished run on main leaves the alert alone, because that newer run's report
owns it; without this, an old red report that finished late would re-raise an alert
a newer green one had just resolved.

WHAT THE CHANNEL IS TOLD, and when it is only a line:

  green, and the run before was green      nothing is said
  green, and the run before was red        one line: green again
  red, and the run before was not red      the full message
  red, and a suite fails that did not      the full message (a second break that
    fail in the run before                   lands while main is already red is
                                             not folded into the first)
  red, and what failed before or now       the full message (not knowing is
    cannot be compared                       not a reason to stay quiet)
  red, on the nightly run                  the full message: one reminder a
                                             day for as long as main stays red
  red, the same suites as the run before   one line: still red

Repeating the full message on every run of a red main (about one run an hour) is
how a channel learns to ignore it, so the repeat is a line and the reminder is
daily. The alert does not depend on any of this: it is re-raised on every red run.

A RUN THAT WAS CANCELLED BEFORE IT STARTED says nothing. bats-main.yml keeps one
waiting run per group, so a push that arrives while a run waits cancels the one
waiting; that run tested nothing and has no verdict. A run cancelled or timed out
AFTER a shard started is treated as red: main is unproven, and the alert fires.

The verdict is never read from the API. It is handed in (RESULT, the triggering
run's conclusion). Everything read from the API only decides what the message
and the alert can say; when a read fails they say so, and the alert still fires.

--alert is written whenever there is a verdict and this run is the newest: the
Alertmanager v2 body (a list of one alert) that the caller posts. Exit 0: nothing
for the channel. Exit 10: a Slack payload was written to --out as well and must be
posted. Exit 3: a green run whose order against the other runs could not be read,
so nothing was written and the alert is left as it is (the caller fails the job).
Anything else: the report could not be built (the caller raises the alert anyway).
"""
import argparse
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone
import urllib.error
import urllib.request

API = os.environ.get("BATS_MAIN_API", "https://api.github.com").rstrip("/")
WORKFLOW = "bats-main.yml"
SAY = 10
ORDER_UNKNOWN = 3

# How an earlier run counts. A cancelled run is neither: it is skipped when looking
# for "the run before", so a waiting run that a push replaced cannot make a red run
# look like the second red in a row and lose its owners their page.
VERDICT = {"success": "green", "failure": "red", "timed_out": "red", "startup_failure": "red"}

# A failing case, and the suite it is in, as bats prints them at the top level of a
# job log (each line carries GitHub's timestamp). Output that a failing case
# captured from a bats run of its own is printed one comment deeper ("# not ok",
# "# # (in test file") and is not counted.
STAMP = r"(?:\d{4}-\d\d-\d\dT\S+Z )?"
CASE = re.compile(rf"(?m)^{STAMP}not ok \d+ ")
SUITE = re.compile(rf"(?m)^{STAMP}# +\(?in test file ([^\s,)]+\.bats)")
MAX_MERGES, MAX_SUITES = 8, 12   # how many the MESSAGE lists; the count covers all of them
# The alert. Its LABELS are its identity and must not vary between runs; everything
# that does vary is an annotation. owner=ci is the lights lane roster's name for a
# broken pipeline (H-DevOps scripts/lights/owner-defaults.yaml), and a label always
# beats a default there. A red main stays red across runs at least nightly (03:41
# UTC), so 26 hours cannot lapse between two re-raises while it is still being run.
ALERTNAME, OWNER, SEVERITY, ALERT_HOURS = "BatsOnMainRed", "ci", "warning", 26
MAX_ALERT_MERGES = 40
# The compare API pages its commits. Five pages is 500 merges between two runs of
# main; past that the interval is reported as not read to its end.
PER_PAGE, MAX_PAGES = 100, 5


class Unread(Exception):
    pass


class _Stay(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


def get(path, token, raw=False):
    url = path if path.startswith("http") else API + path
    head = {"Accept": "application/vnd.github+json", "User-Agent": "hydra-bats-main-report"}
    if token:
        head["Authorization"] = f"Bearer {token}"
    try:
        try:
            with urllib.request.build_opener(_Stay).open(urllib.request.Request(url, headers=head), timeout=30) as r:
                body = r.read()
        except urllib.error.HTTPError as e:
            where = e.headers.get("Location") if e.code in (301, 302, 303, 307, 308) else None
            if not where:
                raise Unread(f"{path}: HTTP {e.code}")
            # A job log lives on another host, which refuses a request that carries
            # our token. Follow the redirect by hand, without it.
            plain = urllib.request.Request(where, headers={"User-Agent": head["User-Agent"]})
            with urllib.request.urlopen(plain, timeout=60) as r:
                body = r.read()
    except Unread:
        raise
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise Unread(f"{path}: {e}")
    if raw:
        return body.decode("utf-8", "replace")
    try:
        return json.loads(body)
    except ValueError as e:
        raise Unread(f"{path}: not JSON ({e})")


def failing(repo, run_id, attempt, token):
    """What failed in a run: (suites, cases, shards that failed without a failing
    case, whether any shard got a runner). Raises Unread."""
    listing = get(f"/repos/{repo}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100", token)
    suites, cases, bare, started = set(), 0, [], False
    for job in listing["jobs"]:
        if job.get("runner_name") or job.get("steps"):
            started = True
        if job.get("conclusion") in ("success", "skipped"):
            continue
        if not (job.get("runner_name") or job.get("steps")):
            continue  # never got a runner: nothing ran, so nothing failed
        log = get(f"/repos/{repo}/actions/jobs/{job['id']}/logs", token, raw=True)
        found = set(SUITE.findall(log))
        n = len(CASE.findall(log))
        if not found or not n:
            bare.append(job.get("name") or str(job["id"]))
        suites |= found
        cases += n
    return suites, cases, bare, started


def earlier(repo, run_number, token):
    """(the runs of this workflow on main that finished with a verdict before this
    one, newest first; whether one finished with a verdict AFTER it). Raises Unread."""
    listing = get(f"/repos/{repo}/actions/workflows/{WORKFLOW}/runs?branch=main&status=completed&per_page=50", token)
    runs = [r for r in listing["workflow_runs"] if r.get("conclusion") in VERDICT]
    older = [r for r in runs if int(r["run_number"]) < run_number]
    newer = any(int(r["run_number"]) > run_number for r in runs)
    return sorted(older, key=lambda r: int(r["run_number"]), reverse=True), newer


def merges(repo, base, head, token):
    """Everything that merged after `base` up to `head`, oldest first:
    ([(sha, title, login, branch, pull request url)], whole). `whole` is False when
    the interval was not read to its end, and the message then says so. A merge
    whose author could not be read has login ''. Raises Unread when nothing could
    be read at all."""
    if base == head:
        return [], True
    commits, total, whole = [], None, True
    for page in range(1, MAX_PAGES + 1):
        try:
            got = get(f"/repos/{repo}/compare/{base}...{head}?per_page={PER_PAGE}&page={page}", token)
        except Unread:
            if page == 1:
                raise
            whole = False
            break
        if page == 1:
            total = got.get("total_commits")
        batch = got.get("commits") or []
        commits += batch
        if not batch or not isinstance(total, int) or len(commits) >= total:
            break
    if not isinstance(total, int) or len(commits) != total:
        whole = False
    out = []
    for c in commits:
        title = (c.get("commit", {}).get("message") or "").split("\n")[0]
        login = (c.get("author") or {}).get("login") or ""
        branch = pr = ""
        try:  # the pull request names the author and the branch; the commit alone often names neither
            pulls = get(f"/repos/{repo}/commits/{c['sha']}/pulls", token)
            if pulls:
                login = (pulls[0].get("user") or {}).get("login") or login
                branch = (pulls[0].get("head") or {}).get("ref") or ""
                pr = pulls[0].get("html_url") or ""
        except Unread:
            pass
        out.append((c["sha"], title, login, branch, pr))
    return out, whole


def alert(repo, url, sha, firing, summary, description, failing_suites, landed):
    """The Alertmanager v2 body: one alert, firing for ALERT_HOURS or resolved now."""
    now = datetime.now(timezone.utc)
    end = now + timedelta(hours=ALERT_HOURS) if firing else now
    stamp = lambda t: t.strftime("%Y-%m-%dT%H:%M:%S.000Z")
    ann = {"summary": summary[:500], "description": description[:4000], "run_url": url, "head": sha}
    if failing_suites:
        ann["failing"] = " ".join(sorted(failing_suites))[:2000]
    if landed:
        ann["merges"] = "\n".join(f"{m[0][:7]} {m[1][:120]}" + (f" ({m[4]})" if m[4] else "")
                                  + (f", {m[2]}" if m[2] else "") + (f", branch {m[3]}" if m[3] else "")
                                  for m in landed[-MAX_ALERT_MERGES:])[:4000]
    # A title or a branch is anyone's text, and Alertmanager's Slack receivers post
    # annotations as written: escaped like the channel message, so none can mention.
    ann = {k: clean(v) for k, v in ann.items()}
    return [{"labels": {"alertname": ALERTNAME, "owner": OWNER, "severity": SEVERITY,
                        "namespace": "ci", "repo": repo},
             # no startsAt: Alertmanager sets it, and keeps the first one while the
             # alert is still active, so "since" is when main went red, not this run
             "annotations": ann, "endsAt": stamp(end), "generatorURL": url}]


def decide(result, before, suites, suites_before, event):
    """'none' | 'green-again' | 'page' | 'line'. `before` is 'green', 'red' or None
    (not known); the suite sets are None when they cannot be compared."""
    if result == "success":
        return "green-again" if before == "red" else "none"
    if before != "red":
        return "page"
    if event == "schedule":
        return "page"
    if suites is None or suites_before is None:
        return "page"
    if not suites <= suites_before:
        return "page"
    return "line"


def clean(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--alert", required=True)
    args = ap.parse_args()
    env = os.environ
    repo, run_id, sha = env["REPO"], env["RUN_ID"], env["HEAD_SHA"]
    result, event = env.get("RESULT", ""), env.get("EVENT", "")
    attempt, token = env.get("RUN_ATTEMPT") or "1", env.get("GH_TOKEN", "")
    run_number = int(env["RUN_NUMBER"])
    channel = env["SLACK_CHANNEL"]
    url = f"{env.get('SERVER_URL', 'https://github.com')}/{repo}/actions/runs/{run_id}"
    short = sha[:7]
    unread = []

    try:
        older, newer = earlier(repo, run_number, token)
    except (Unread, KeyError, TypeError, ValueError) as e:
        # None, not False: whether a newer run has finished is UNKNOWN, and a green
        # report that took it as "no" would resolve a newer red run's alert (QA on
        # #2048 at e2b6d2f). A red report still raises: an alert too many is cleared
        # by the next green run, an alert too few is a red main nobody owns.
        older, newer = None, None
        unread.append(f"the earlier runs ({e})")
    if result == "success" and newer is None:
        print(f"Bats on main: green at {short}, but the earlier runs could not be read "
              f"({'; '.join(unread)}), so it is unknown whether a newer red run has raised "
              f"{ALERTNAME}. Not resolved; a later green run resolves it.")
        return ORDER_UNKNOWN
    prev = older[0] if older else None
    before = VERDICT[prev["conclusion"]] if prev else None
    green = next((r for r in older or [] if r["conclusion"] == "success"), None)

    def raise_alert(firing, summary, description, failing_suites=(), landed=()):
        if newer is True:
            print(f"Bats on main: a newer run of main has finished, so its report owns {ALERTNAME}; left alone.")
            return
        with open(args.alert, "w") as f:
            json.dump(alert(repo, url, sha, firing, summary, description, failing_suites, landed), f)

    suites = cases = bare = None
    found = set()
    if result != "success":
        try:
            found, cases, bare, started = failing(repo, run_id, attempt, token)
            if result == "cancelled" and not started:
                print("Bats on main: this run was cancelled before any shard started; it has no verdict.")
                return 0
            suites = None if bare else found
        except (Unread, KeyError, TypeError) as e:
            found, cases, bare = set(), 0, []
            unread.append(f"what failed ({e})")
    suites_before = None
    if result != "success" and before == "red" and suites is not None:
        try:
            was, _, bare_before, _ = failing(repo, prev["id"], prev.get("run_attempt") or 1, token)
            suites_before = None if bare_before else was
        except (Unread, KeyError, TypeError) as e:
            unread.append(f"what failed in the run before ({e})")

    kind = decide(result, before, suites, suites_before, event)
    if result == "success":
        # resolved on EVERY green run, not only the first: that also heals an
        # alert whose earlier resolve did not reach Alertmanager
        raise_alert(False, f"Bats on main in {repo} is green at {short}.", f"Run: {url}")
    if kind == "none":
        print(f"Bats on main: green at {short}, and it was not red before. Nothing for the channel.")
        return 0
    if kind == "green-again":
        text = f":large_green_circle: *Bats on main is green again* at `{short}`. Run: {url}"
    else:
        what = "did not finish" if result in ("cancelled", "timed_out") else "is red"
        lines = []
        if found:
            shown = sorted(found)[:MAX_SUITES]
            more = f" and {len(found) - len(shown)} more" if len(found) > len(shown) else ""
            lines.append(f"*Failing:* {cases} case(s) in {len(found)} suite(s): " + ", ".join(f"`{s}`" for s in shown) + more)
        if bare:
            lines.append("*Failed without a failing case* (a timeout, a skipped case, or the step itself): " + ", ".join(clean(b) for b in bare))
        if not found and not bare:
            lines.append("*Failing:* not read; open the run.")
        owner = (f"It is a task for the `{OWNER}` lane (alert `{ALERTNAME}`, owner={OWNER}, "
                 "dispatched by lights); nobody is mentioned.")
        # The merges are read on every red run, the repeat included: the alert is
        # re-raised each time, and Alertmanager keeps only the latest annotations.
        landed, whole, why = [], True, ""
        if green is None:
            why = "no green run was found to count from"
        else:
            try:
                landed, whole = merges(repo, green["head_sha"], sha, token)
                if not landed and whole:
                    why = (f"nothing merged since the last green run, which was this same commit `{short}` "
                           "(a suite that depends on the clock, the network or run order)")
                if not whole:
                    unread.append("every merge since the last green run (the list was not read to its end)")
            except (Unread, KeyError, TypeError) as e:
                why = "what merged since the last green run could not be read"
                unread.append(f"the merges ({e})")
        if kind == "line":
            text = (f":red_circle: *Bats on main is still red* at `{short}`: the same suites as the run before, "
                    f"nothing new. {owner}\n" + "\n".join(lines) + f"\n*Run:* {url}")
        else:
            text = (f":red_circle: *Bats on main {what}* at `{short}`. {owner} Fix it forward or revert."
                    + (f" ({why})" if why else "") + "\n" + "\n".join(lines))
            if landed:
                text += f"\n*Merged since the last green run* (`{green['head_sha'][:7]}`), {len(landed)} in all:"
                extra = max(0, len(landed) - MAX_MERGES)
                for csha, title, login, branch, _ in landed[-MAX_MERGES:]:
                    text += (f"\n• `{csha[:7]}` {clean(title)}" + (f", {clean(login)}" if login else "")
                             + (f", branch `{clean(branch)}`" if branch else ""))
                if extra:
                    text += f"\n• and {extra} earlier merge(s) not listed here"
            if before == "red":
                text += "\n*Main was already red in the run before this one.*"
            text += ("\n*Why no pull request caught it:* a pull request runs only the suites its change concerns "
                     f"(scripts/ci/bats-scope.py); every suite runs here.\n*Run:* {url}")
        summary = (f"Bats on main in {repo} {what} at {short}"
                   + (f": {cases} case(s) in {len(found)} suite(s)" if found else "")
                   + (f"; {len(landed)} merge(s) since the last green run" if landed else "")
                   + ("" if not why else f" ({why})"))
        description = ("A suite broke on main that no pull request ran (scripts/ci/bats-scope.py). "
                       "Fix it forward or revert. " + ("Failing: " + ", ".join(sorted(found)[:MAX_SUITES]) + ". " if found else "")
                       + ("Failed without a failing case: " + ", ".join(bare) + ". " if bare else "")
                       + ("Could not read: " + "; ".join(unread) + ". " if unread else "") + f"Run: {url}")
        raise_alert(True, summary, description, found, landed)
    if unread:
        text += "\n_Could not read: " + "; ".join(clean(u) for u in unread) + "._"
    if "<@" in text:   # belt and braces: a title or a branch can carry one
        text = text.replace("<@", "&lt;@")
    with open(args.out, "w") as f:
        json.dump({"channel": channel, "text": text}, f)
    print(text)
    return SAY


if __name__ == "__main__":
    sys.exit(main())
