#!/usr/bin/env bash
# fm-roster.sh - one read-only screen of every agent firstmate supervises and
# every unsupervised surface still running on this host.
#
# Two tables and a totals line:
#   1. UNDER FIRSTMATE SUPERVISION - one row per state/<id>.meta in this home:
#      what the task is doing right now (newest status line, mapped to plain
#      words), the harness/model/effort it runs on, how much of its context it
#      has used when that is cheap to read from the pane, the age of its last
#      status report, and a completion estimate whose basis is stated in the
#      cell.
#   2. NOT UNDER SUPERVISION - the pieces the captain still has running that no
#      firstmate task owns: migrated cmux surfaces whose expected loop has no
#      live task, old cmux-app terminals still resumed on this host, and Orca
#      terminals bound to no task. Firstmate's own chair (the process holding
#      state/.lock, and any process or terminal working in the home checkout)
#      and a supervised task's companion panes (any terminal or process working
#      in a live task's recorded worktree) are not listed: they belong to the
#      supervisor or to a supervised task. Each row carries the same
#      doing-now, model, and estimate columns as a supervised row: the expected
#      loop's own description, the resumed session's opening request, or the
#      Orca terminal's agent and last screen line; the estimate cell says the
#      piece is unsupervised. The migrated-surface rows join
#      data/cmux-takeover/expected-loops.json to live task metadata directly, so
#      classifying them needs no Orca call.
#
# WHY IT IS BOUNDED: a firstmate home carries multi-megabyte append-only status
# logs. This script never reads a whole status file: it reads only the last
# FM_ROSTER_TAIL_BYTES (default 128 KiB) to find the newest line, and it gathers
# every task in parallel. The pane read (context percent) uses the Orca
# backend's own bounded tail read when the task runs there, and otherwise falls
# back to bin/fm-peek.sh. It never calls a model.
#
# WHY IT IS READ-ONLY: it prints and exits. It never steers a worker, merges,
# dispatches, tears down, or writes under state/, data/, or projects/. Missing
# files degrade to "-" in that cell; they never abort the report. The script
# itself writes nothing; the one caveat is the bin/fm-peek.sh fallback for a
# pane read (used only when the task is not on Orca or the Orca read fails),
# which runs bin/fm-guard.sh and may refresh that guard's own marker file.
#
# ESTIMATE BASIS: a standing lane (its title names a lane/watch/loop, or its
# newest line is a paused await-* wait) has no end and shows its next tick. A
# ship task shows its pipeline stage; a working ship estimates from its spawn
# time plus the median elapsed time of recent Done ship tasks in
# data/backlog.md (measured from each task's retained data/<id>/ brief mtime to
# its last artifact write, because the Done record itself keeps only a date).
# When too few measurements exist the cell says so and states its default.
# A scout shows whether its report is written. Every non-standing cell names the
# basis it used; none invents an ETA.
#
# Usage:
#   fm-roster.sh            print the two tables and the totals line
#   fm-roster.sh --help     print this usage
#
# HOME: FM_HOME when set. Otherwise the script's own checkout when it holds a
# state/ directory, else the primary checkout behind the script's linked
# worktree (git rev-parse --git-common-dir) when that one holds state/, so a
# run from a task worktree reports the home that owns the fleet rather than an
# empty roster.
#
# Environment (overrides exist for tests and non-default homes):
#   FM_HOME, FM_STATE_OVERRIDE, FM_DATA_OVERRIDE  standard firstmate overrides
#   FM_ROSTER_BACKLOG         backlog path (default $DATA/backlog.md)
#   FM_ROSTER_CMUX_DIR        cmux-takeover dir (default $DATA/cmux-takeover)
#   FM_ROSTER_PEEK_CMD        pane reader called as `<cmd> <task-id> <lines>`;
#                             empty disables the context-percent column
#   FM_ROSTER_ORCA_CMD        Orca CLI (default `orca`); empty disables the
#                             unbound-terminal and direct pane reads
#   FM_ROSTER_PS_CMD          process lister (default `ps -axo pid=,command=`);
#                             empty disables the cmux-app terminal scan
#   FM_ROSTER_CLAUDE_PROJECTS, FM_ROSTER_GROK_SESSIONS  session roots
#   FM_ROSTER_NOW_EPOCH       override "now" for deterministic ages
#   FM_ROSTER_TAIL_BYTES      status tail window (default 131072)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
if [ -z "${FM_HOME:-}" ]; then
  FM_HOME="${FM_ROOT_OVERRIDE:-$FM_ROOT}"
  if [ ! -d "$FM_HOME/state" ] && command -v git >/dev/null 2>&1; then
    common_dir=$(git -C "$FM_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
    case "$common_dir" in
      */.git)
        [ -d "${common_dir%/.git}/state" ] && FM_HOME=${common_dir%/.git}
        ;;
    esac
  fi
fi

case "${1:-}" in
  -h | --help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
    exit 0
    ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
  printf 'fm-roster: python3 is required but was not found on PATH\n' >&2
  exit 1
fi

# Single-hyphen defaults: an explicitly empty value disables that source,
# which is how a test keeps the report off the live host.
export FM_HOME
export FM_STATE_OVERRIDE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
export FM_DATA_OVERRIDE="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
export FM_ROSTER_PEEK_CMD="${FM_ROSTER_PEEK_CMD-$SCRIPT_DIR/fm-peek.sh}"
export FM_ROSTER_ORCA_CMD="${FM_ROSTER_ORCA_CMD-orca}"
export FM_ROSTER_PS_CMD="${FM_ROSTER_PS_CMD-ps -axo pid=,command=}"
export FM_ROSTER_BACKLOG="${FM_ROSTER_BACKLOG-$FM_DATA_OVERRIDE/backlog.md}"
export FM_ROSTER_CMUX_DIR="${FM_ROSTER_CMUX_DIR-$FM_DATA_OVERRIDE/cmux-takeover}"
export FM_ROSTER_CLAUDE_PROJECTS="${FM_ROSTER_CLAUDE_PROJECTS-$HOME/.claude/projects}"
export FM_ROSTER_GROK_SESSIONS="${FM_ROSTER_GROK_SESSIONS-$HOME/.grok/sessions}"
export FM_ROSTER_NOW_EPOCH="${FM_ROSTER_NOW_EPOCH:-$(date +%s)}"
export FM_ROSTER_TAIL_BYTES="${FM_ROSTER_TAIL_BYTES:-131072}"

exec python3 - <<'PY'
from __future__ import annotations

import glob
import json
import os
import re
import shlex
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

STATE = os.environ.get("FM_STATE_OVERRIDE") or ""
DATA = os.environ.get("FM_DATA_OVERRIDE") or ""
HOME_DIR = os.path.realpath(os.environ.get("FM_HOME") or "")
PEEK_CMD = os.environ.get("FM_ROSTER_PEEK_CMD") or ""
ORCA_CMD = os.environ.get("FM_ROSTER_ORCA_CMD") or ""
PS_CMD = os.environ.get("FM_ROSTER_PS_CMD") or ""
BACKLOG = os.environ.get("FM_ROSTER_BACKLOG") or os.path.join(DATA, "backlog.md")
CMUX = os.environ.get("FM_ROSTER_CMUX_DIR") or os.path.join(DATA, "cmux-takeover")
CLAUDE_PROJECTS = os.environ.get("FM_ROSTER_CLAUDE_PROJECTS") or ""
GROK_SESSIONS = os.environ.get("FM_ROSTER_GROK_SESSIONS") or ""
try:
    NOW = float(os.environ.get("FM_ROSTER_NOW_EPOCH") or time.time())
except ValueError:
    NOW = time.time()
try:
    TAIL_BYTES = max(4096, int(os.environ.get("FM_ROSTER_TAIL_BYTES") or 131072))
except ValueError:
    TAIL_BYTES = 131072

MAX_WORKERS = 8
PANE_TIMEOUT = 15


def lock_pid() -> str:
    try:
        with open(os.path.join(STATE, ".lock"), encoding="utf-8") as handle:
            value = handle.read().strip()
    except OSError:
        return ""
    return value if value.isdigit() else ""


LOCK_PID = lock_pid()


def owned_by_home_or_task(path: str, meta_worktrees: set) -> bool:
    if not path:
        return False
    real = os.path.realpath(path)
    return real == HOME_DIR or real in meta_worktrees


# --- small helpers ----------------------------------------------------------


def truncate(text: str, width: int) -> str:
    text = text if text is not None else ""
    if len(text) <= width:
        return text
    if width <= 3:
        return text[:width]
    return text[: width - 3] + "..."


def age_str(seconds):
    if seconds is None or seconds < 0:
        return "-"
    minutes = seconds / 60.0
    if minutes < 60:
        return "%dm" % int(minutes)
    hours = minutes / 60.0
    if hours < 24:
        return "%.1fh" % hours if hours < 10 else "%dh" % int(round(hours))
    return "%.1fd" % (hours / 24.0)


def run(cmd, timeout):
    """Run a command list; return stdout text, or '' on any failure."""
    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    if proc.returncode != 0:
        return ""
    return proc.stdout.decode("utf-8", "replace")


def read_meta(path: str) -> dict:
    meta = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                if line.startswith("#") or "=" not in line:
                    continue
                key, value = line.rstrip("\n").split("=", 1)
                meta.setdefault(key.strip(), value.strip())
    except OSError:
        pass
    return meta


def newest_status_line(path: str) -> str:
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as handle:
            if size > TAIL_BYTES:
                handle.seek(size - TAIL_BYTES)
            raw = handle.read()
        text = raw.decode("utf-8", "replace")
    except OSError:
        return ""
    for line in reversed(text.splitlines()):
        if line.strip():
            return line.strip()
    return ""


def short_model(model: str) -> str:
    if not model:
        return "-"
    name = model.rstrip("/").split("/")[-1]
    name = name.replace("deepseek-v4p1-flash", "deepseek-v4.1-flash")
    name = re.sub(r"^claude-", "", name)
    return name or "-"


def parse_gen(value: str):
    match = re.match(r"^[a-z]?(\d{9,})", value or "")
    return int(match.group(1)) if match else None


# --- backlog index ----------------------------------------------------------


def backlog_index(path: str):
    """Return (titles, done_ids, median_hours, median_basis)."""
    titles = {}
    done_ids = set()
    durations = []
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError:
        text = ""
    section = ""
    for line in text.splitlines():
        if line.startswith("## "):
            section = line[3:].strip()
            continue
        match = re.match(r"^-\s*\[[ xX]\]\s+(\S+)\s+[-\u2013]\s+(.*)$", line)
        if not match:
            continue
        task_id, rest = match.group(1), match.group(2)
        if section != "Done":
            title = re.split(r"\s+\((?:repo|kind|priority|since|hold|blocked-by)\b", rest)[0]
            titles[task_id] = title.strip()
            continue
        done_ids.add(task_id)
        if "kind: ship" not in line or len(durations) >= 20:
            continue
        duration = done_ship_duration(task_id)
        if duration is not None and duration > 0:
            durations.append(duration)
    if len(durations) >= 3:
        ordered = sorted(durations)
        mid = len(ordered) // 2
        if len(ordered) % 2:
            median = ordered[mid]
        else:
            median = (ordered[mid - 1] + ordered[mid]) / 2.0
        basis = "median %.0fh of %d done" % (median, len(ordered))
        return titles, done_ids, median, basis
    return titles, done_ids, 6.0, "default 6h, no recent data"


def mtime(path: str):
    try:
        return os.path.getmtime(path)
    except OSError:
        return None


BRIEF_NAMES = ("launch-brief.md", "brief.md")


def done_ship_duration(task_id: str):
    """Hours from a Done ship task's dispatch brief to its last artifact write.

    The Done record keeps only a date, so a precise duration comes from the
    task's retained data/<id>/ directory: the dispatch brief is written at
    launch, and the newest entry other than the briefs is the task's last
    artifact. A directory holding only briefs has no measurable duration.
    """
    task_dir = os.path.join(DATA, task_id)
    try:
        names = os.listdir(task_dir)
    except OSError:
        return None
    starts = [mtime(os.path.join(task_dir, name)) for name in BRIEF_NAMES]
    starts = [value for value in starts if value is not None]
    ends = [mtime(os.path.join(task_dir, name)) for name in names if name not in BRIEF_NAMES]
    ends = [value for value in ends if value is not None]
    if not starts or not ends:
        return None
    start, end = min(starts), max(ends)
    if end <= start:
        return None
    return (end - start) / 3600.0


# --- task rows --------------------------------------------------------------


def parse_status(line: str):
    """Split a status line into (state, key, body).

    Workers write both `state: body` and `state [key=...] body`, so the colon
    is optional whenever a bracketed key is present.
    """
    if not line:
        return "", "", ""
    match = re.match(r"^([a-z][a-z-]*)\s*(?:\[([^\]]*)\])?\s*:\s*(.*)$", line, re.S)
    if match:
        return match.group(1), (match.group(2) or "").strip(), match.group(3).strip()
    legacy = re.match(r"^([a-z][a-z-]*)\s*(?:\[([^\]]*)\])?\s+(.*)$", line, re.S)
    if legacy:
        return legacy.group(1), (legacy.group(2) or "").strip(), legacy.group(3).strip()
    return "", "", line


def doing_now(line: str) -> str:
    state, key, body = parse_status(line)
    if not line:
        return "(no status yet)"
    if state == "paused":
        tick = re.search(r"(?:tick at|until)\s+(\d{2}:\d{2})Z", body)
        if tick:
            return "idle until %sZ" % tick.group(1)
        if body.lower().startswith("idle"):
            return body
        return "paused: " + body
    body = re.sub(
        r"^(?:working|finished|answered|paused|blocked|waiting on firstmate)\s*:\s*",
        "",
        body,
        flags=re.I,
    )
    if state == "working":
        return "working: " + body
    if state in ("needs-decision", "blocked"):
        return "waiting on firstmate: " + body
    if state == "done":
        return "finished: " + body
    if state == "failed":
        return "failed: " + body
    if state == "resolved":
        return "answered: " + body
    if state == "note":
        return "note: " + body
    return body


def is_standing(state: str, key: str, title: str) -> bool:
    if state == "paused" and key.startswith("await-"):
        return True
    if not title:
        return False
    if re.search(r"\b(?:lane|watch)\b", title, re.I):
        return True
    if re.search(r"\bloop\b", title, re.I) and not re.search(r"in[- ]the[- ]loop", title, re.I):
        return True
    return False


def context_percent(meta: dict, task_id: str) -> str:
    out = ""
    terminal = meta.get("terminal", "")
    if ORCA_CMD and meta.get("backend") == "orca" and terminal:
        out = run(
            shlex.split(ORCA_CMD)
            + ["terminal", "read", "--terminal", terminal, "--limit", "4", "--json"],
            PANE_TIMEOUT,
        )
    if not out and PEEK_CMD:
        out = run(shlex.split(PEEK_CMD) + [task_id, "4"], PANE_TIMEOUT + 5)
    matches = re.findall(r"([0-9]+\.[0-9]+)%/[0-9.]+[kM]", out)
    return matches[-1] + "%" if matches else "-"


def task_row(meta_path: str, titles: dict, done_ids: set, median, basis: str):
    task_id = os.path.basename(meta_path)[: -len(".meta")]
    meta = read_meta(meta_path)
    status_path = os.path.join(STATE, task_id + ".status")
    line = newest_status_line(status_path)
    state, key, body = parse_status(line)
    title = titles.get(task_id, "")
    standing = is_standing(state, key, title)
    kind = meta.get("kind", "task") or "task"
    project = os.path.basename(meta.get("project", "").rstrip("/")) or "-"
    model = " / ".join(
        [meta.get("harness") or "-", short_model(meta.get("model", "")), meta.get("effort") or "-"]
    )
    ctx = context_percent(meta, task_id)
    report_age = age_str(NOW - mtime(status_path)) if mtime(status_path) else "-"
    estimate = estimate_for(
        task_id, kind, state, line, standing, meta, done_ids, median, basis
    )
    return {
        "id": task_id,
        "project": project,
        "kind": kind,
        "doing": truncate(doing_now(line), 88),
        "model": model,
        "ctx": ctx,
        "age": report_age,
        "estimate": truncate(estimate, 46),
    }


def estimate_for(task_id, kind, state, line, standing, meta, done_ids, median, basis):
    if standing:
        tick = re.search(r"(?:tick at|until)\s+(\d{2}:\d{2})Z", line)
        if tick:
            return "standing - no end; next tick %sZ" % tick.group(1)
        return "standing - no end; awaits its next tick"
    if kind == "scout":
        report = os.path.join(DATA, task_id, "report.md")
        return "report written" if os.path.exists(report) else "report due"
    if not line:
        return "setting up"
    if state == "working":
        created = parse_gen(meta.get("spawn_gen", "")) or mtime(
            os.path.join(STATE, task_id + ".meta")
        )
        if not created:
            return "implementing (no start time)"
        remaining = (created + median * 3600.0 - NOW) / 3600.0
        if remaining <= 0:
            return "implementing (past %s)" % basis
        return "implementing (~%.0fh; %s)" % (remaining, basis)
    if state in ("needs-decision", "blocked"):
        return "blocked on firstmate"
    if state == "paused":
        return "paused - external wait"
    if state == "failed":
        return "failed - needs cleanup"
    if state == "resolved":
        return "decision answered"
    if state == "done":
        if task_id in done_ids:
            return "awaiting cleanup"
        if "http" in line or meta.get("pr"):
            return "PR open, awaiting merge"
        return "finished"
    return "-"


# --- unsupervised surfaces --------------------------------------------------


UNSUPERVISED = "unsupervised - no estimate"


def slug_in_task_id(slug: str, task_id: str) -> bool:
    return re.search(r"(?:^|-)" + re.escape(slug) + r"(?:-|$)", task_id) is not None


def expected_loop_rows(meta_ids: set, meta_terms: set):
    """Migrated cmux surfaces with no live firstmate task.

    A surface is supervised when its recorded `firstmate_task` has a meta, when
    its old terminal is still the terminal a live meta records, or when its slug
    is a hyphen-delimited token run of a live task id (a relaunched lane gets a
    new terminal, so the recorded terminal alone would misreport it). Anything
    else is listed with the loop it is expected to be running.
    """
    exp_path = os.path.join(CMUX, "expected-loops.json")
    try:
        with open(exp_path, encoding="utf-8", errors="replace") as handle:
            data = json.load(handle)
        surfaces = data.get("surfaces", {})
    except (OSError, ValueError):
        return []
    rows = []
    for surface in surfaces.values():
        if not isinstance(surface, dict):
            continue
        slug = surface.get("slug") or ""
        linked = surface.get("firstmate_task")
        if linked and linked in meta_ids:
            continue
        if surface.get("term") in meta_terms:
            continue
        if slug and any(slug_in_task_id(slug, task_id) for task_id in meta_ids):
            continue
        heartbeat = None
        if slug:
            heartbeat = mtime(os.path.join(CMUX, "status", slug + ".json"))
        expected = surface.get("expected") or []
        whats = [
            " ".join(str(item.get("what", "")).split())
            for item in expected
            if isinstance(item, dict) and item.get("what")
        ]
        rows.append(
            {
                "source": "migrated",
                "name": surface.get("surface") or slug or "-",
                "doing": "; ".join(whats) or "-",
                "model": "-",
                "last": age_str(NOW - heartbeat) if heartbeat else "-",
                "estimate": UNSUPERVISED + "; relaunch item queued",
            }
        )
    rows.sort(key=lambda row: row["name"].lower())
    return rows


def cmux_app_rows(meta_worktrees: set):
    """Old cmux-app terminals still resumed on this host.

    Matches a resumed Claude session (`--resume <uuid>`) or a resumed grok
    session (`grok -r <uuid>`), deduplicated by session id. The project
    directory comes from the live process's working directory, because the
    resume command itself carries no cwd; a process working in a live task's
    recorded worktree is that task's own relaunched worker, not a stray, and
    the process holding this home's session lock or working in the home
    checkout is firstmate's own chair.
    """
    if not PS_CMD:
        return []
    out = run(shlex.split(PS_CMD), 10)
    seen = set()
    rows = []
    for line in out.splitlines():
        match = re.match(r"\s*(\d+)\s+(.*)$", line)
        if not match:
            continue
        pid, cmd = match.group(1), match.group(2)
        kind = sid = None
        resume = re.search(r"--resume\s+([0-9a-fA-F-]{36})", cmd)
        if resume and re.search(r"(?:^|/)claude(?:\s|$)", cmd):
            kind, sid = "claude", resume.group(1)
        else:
            grok = re.search(r"(?:^|/)grok\b.*\s-r\s+([0-9a-fA-F-]{36})", cmd)
            if grok:
                kind, sid = "grok", grok.group(1)
        if not kind or not sid or (kind, sid) in seen:
            continue
        seen.add((kind, sid))
        rows.append((kind, sid, pid))
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        resolved = list(pool.map(lambda args: cmux_app_row(*args, meta_worktrees), rows))
    resolved = [row for row in resolved if row]
    resolved.sort(key=lambda row: (row["model"], row["name"]))
    return resolved


def proc_cwd(pid: str) -> str:
    out = run(["lsof", "-p", pid, "-a", "-d", "cwd", "-Fn"], 10)
    for line in out.splitlines():
        if line.startswith("n"):
            return line[1:].strip()
    return ""


TAG_BLOCK = re.compile(r"^\s*<([A-Za-z][\w-]*)>.*?</\1>\s*", re.S)


def plain_request(text: str) -> str:
    """The human request in a session entry, or '' when it is only scaffolding.

    Session logs open with harness blocks such as <local-command-caveat>,
    <command-name>, <system-reminder>, and <user_info>; those are stripped from
    the front, and an entry that is nothing but such blocks yields ''.
    """
    text = text or ""
    while True:
        stripped = TAG_BLOCK.sub("", text, count=1)
        if stripped == text:
            break
        text = stripped
    text = " ".join(text.split())
    if not text or text.startswith("<"):
        return ""
    return text


def first_claude_user_message(session_file: str) -> str:
    try:
        with open(session_file, encoding="utf-8", errors="replace") as handle:
            for index, raw in enumerate(handle):
                if index > 4000:
                    break
                if '"type":"user"' not in raw and '"type": "user"' not in raw:
                    continue
                try:
                    entry = json.loads(raw)
                except ValueError:
                    continue
                if entry.get("isMeta"):
                    continue
                content = (entry.get("message") or {}).get("content")
                if isinstance(content, str):
                    text = content
                elif isinstance(content, list):
                    parts = [
                        item.get("text", "")
                        for item in content
                        if isinstance(item, dict) and item.get("type") == "text"
                    ]
                    if not parts:
                        continue
                    text = " ".join(parts)
                else:
                    continue
                text = plain_request(text)
                if text:
                    return text
    except OSError:
        pass
    return ""


def first_grok_user_message(session_file: str) -> str:
    try:
        with open(session_file, encoding="utf-8", errors="replace") as handle:
            for index, raw in enumerate(handle):
                if index > 2000:
                    break
                if '"type":"user"' not in raw and '"type": "user"' not in raw:
                    continue
                try:
                    entry = json.loads(raw)
                except ValueError:
                    continue
                if entry.get("synthetic_reason"):
                    continue
                content = entry.get("content")
                parts = []
                if isinstance(content, str):
                    parts = [content]
                elif isinstance(content, list):
                    parts = [
                        item.get("text", "")
                        for item in content
                        if isinstance(item, dict) and item.get("type") == "text"
                    ]
                text = " ".join(parts)
                query = re.search(r"<user_query>(.*?)</user_query>", text, re.S)
                text = plain_request(query.group(1) if query else text)
                if text:
                    return text
    except OSError:
        pass
    return ""


def cmux_app_row(kind: str, sid: str, pid: str, meta_worktrees: set):
    session_file = ""
    for pattern in (
        os.path.join(CLAUDE_PROJECTS, "*", sid + ".jsonl") if CLAUDE_PROJECTS else "",
        os.path.join(GROK_SESSIONS, "*", sid, "chat_history.jsonl") if GROK_SESSIONS else "",
    ):
        if not pattern:
            continue
        hits = glob.glob(pattern)
        if hits:
            session_file = hits[0]
            break
    if pid == LOCK_PID:
        return None
    cwd = proc_cwd(pid)
    if owned_by_home_or_task(cwd, meta_worktrees):
        return None
    age = "-"
    if session_file:
        stamp = mtime(session_file)
        age = age_str(NOW - stamp) if stamp else "-"
    title = ""
    if session_file:
        title = (
            first_grok_user_message(session_file)
            if session_file.endswith("chat_history.jsonl")
            else first_claude_user_message(session_file)
        )
    name = os.path.basename(cwd.rstrip("/")) or cwd or "-"
    return {
        "source": "cmux app",
        "name": name,
        "doing": title or "-",
        "model": "claude via pool" if kind == "claude" else "grok",
        "last": age,
        "estimate": UNSUPERVISED,
    }


def preview_line(preview) -> str:
    """The last screen line of an Orca terminal preview, without frame glyphs."""
    if not isinstance(preview, str):
        return ""
    for line in reversed(preview.splitlines()):
        text = " ".join(re.sub(r"[\u2500-\u257f\u2800-\u28ff]", " ", line).split())
        if text:
            return text
    return ""


def orca_unbound_rows(meta_terms: set, meta_worktrees: set):
    if not ORCA_CMD:
        return [], ""
    out = run(shlex.split(ORCA_CMD) + ["terminal", "list", "--json"], 5)
    if not out:
        return [], "orca terminal list unavailable or slower than 5s - skipped"
    try:
        data = json.loads(out)
        terminals = data.get("result", {}).get("terminals", [])
    except (ValueError, AttributeError):
        return [], "orca terminal list output was unreadable - skipped"
    rows = []
    for terminal in terminals:
        if not isinstance(terminal, dict):
            continue
        handle = terminal.get("handle", "")
        if handle in meta_terms or owned_by_home_or_task(terminal.get("worktreePath") or "", meta_worktrees):
            continue
        output_at = terminal.get("lastOutputAt")
        age = "-"
        if isinstance(output_at, (int, float)) and output_at > 0:
            age = age_str(NOW - output_at / 1000.0)
        title = terminal.get("title") or ""
        if not title or re.match(r"^term_[0-9a-f-]+$", title):
            title = os.path.basename((terminal.get("worktreePath") or "").rstrip("/")) or handle or "-"
        agent = terminal.get("agentIdentity") or ""
        rows.append(
            {
                "source": "orca term",
                "name": title,
                "doing": ": ".join(part for part in (agent, preview_line(terminal.get("preview"))) if part) or "-",
                "model": agent or "-",
                "last": age,
                "estimate": UNSUPERVISED,
            }
        )
    rows.sort(key=lambda row: row["name"].lower())
    return rows, ""


# --- rendering --------------------------------------------------------------


def table(headers, rows, widths):
    lines = []
    lines.append("  ".join(header.ljust(widths[i]) for i, header in enumerate(headers)).rstrip())
    lines.append("  ".join("-" * widths[i] for i in range(len(headers))))
    for row in rows:
        cells = [truncate(row[i], widths[i]).ljust(widths[i]) for i in range(len(headers))]
        lines.append("  ".join(cells).rstrip())
    return lines


def render(supervised, unsupervised, skipped_note):
    stamp = datetime.fromtimestamp(NOW, timezone.utc).strftime("%Y-%m-%d %H:%MZ")
    out = []
    out.append("FLEET ROSTER - %s" % stamp)
    out.append(
        "CTX% is the agent's used context read from its pane; LAST is the age of its "
        "last report. Every non-standing estimate names its basis."
    )
    out.append("")
    out.append("UNDER FIRSTMATE SUPERVISION (%d)" % len(supervised))
    out.extend(
        table(
            ["ID", "PROJECT", "KIND", "DOING NOW", "MODEL", "CTX%", "LAST", "ESTIMATE"],
            [
                [r["id"], r["project"], r["kind"], r["doing"], r["model"], r["ctx"], r["age"], r["estimate"]]
                for r in supervised
            ],
            [26, 16, 5, 88, 33, 5, 6, 46],
        )
    )
    if not supervised:
        out.append("(no supervised tasks in this home)")
    out.append("")
    out.append("NOT UNDER SUPERVISION (%d)" % len(unsupervised))
    if unsupervised:
        out.extend(
            table(
                ["SOURCE", "NAME", "DOING NOW", "MODEL", "LAST", "ESTIMATE"],
                [
                    [r["source"], r["name"], r["doing"], r["model"], r["last"], r["estimate"]]
                    for r in unsupervised
                ],
                [10, 28, 70, 16, 6, 48],
            )
        )
    else:
        out.append("(nothing outside firstmate's supervision is running)")
    if skipped_note:
        out.append("note: %s" % skipped_note)
    out.append("")
    counts = {"working": 0, "idle": 0, "waiting": 0, "finished": 0, "other": 0}
    for row in supervised:
        text = row["doing"]
        if text.startswith("working"):
            counts["working"] += 1
        elif text.startswith("idle") or text.startswith("paused"):
            counts["idle"] += 1
        elif text.startswith("waiting on firstmate"):
            counts["waiting"] += 1
        elif text.startswith("finished") or text.startswith("answered"):
            counts["finished"] += 1
        else:
            counts["other"] += 1
    out.append(
        "Totals: %d supervised (%d working, %d idle/waiting externally, %d waiting on firstmate, "
        "%d finished or answered, %d other) - %d not supervised."
        % (
            len(supervised),
            counts["working"],
            counts["idle"],
            counts["waiting"],
            counts["finished"],
            counts["other"],
            len(unsupervised),
        )
    )
    return "\n".join(out)


def main():
    if not STATE or not os.path.isdir(STATE):
        print("fm-roster: no state directory at %s" % (STATE or "-"), file=sys.stderr)
        return 1
    titles, done_ids, median, basis = backlog_index(BACKLOG)

    meta_paths = sorted(glob.glob(os.path.join(STATE, "*.meta")))
    meta_ids = {os.path.basename(path)[: -len(".meta")] for path in meta_paths}
    meta_terms = set()
    meta_worktrees = set()
    for path in meta_paths:
        meta = read_meta(path)
        if meta.get("terminal"):
            meta_terms.add(meta["terminal"])
        if meta.get("worktree"):
            meta_worktrees.add(os.path.realpath(meta["worktree"]))

    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        supervised = list(
            pool.map(lambda path: task_row(path, titles, done_ids, median, basis), meta_paths)
        )
    supervised.sort(key=lambda row: row["id"])

    unsupervised = expected_loop_rows(meta_ids, meta_terms)
    unsupervised.extend(cmux_app_rows(meta_worktrees))
    orca_rows, skipped = orca_unbound_rows(meta_terms, meta_worktrees)
    unsupervised.extend(orca_rows)

    print(render(supervised, unsupervised, skipped))
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY