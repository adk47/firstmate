#!/usr/bin/env python3
"""fm-fleet-snapshot.py - the per-task pass of bin/fm-fleet-snapshot.sh in one process.

Usage (internal; bin/fm-fleet-snapshot.sh is the only caller):
  fm-fleet-snapshot.py tasks --task-dir <dir>

Prints the snapshot's tasks[] array (fm-fleet-snapshot.v1 task rows, sorted by
id) on stdout and leaves, in <task-dir>, the same per-task captures the bash
pass leaves (<id>.meta, <id>.status), which later secondmate composition
reads. Inputs come from the caller's environment (FM_ROOT, FM_HOME, STATE,
DATA, CONFIG, PROJECTS, SNAPSHOT_NOW, and the FM_SNAPSHOT_* bounds). Every
output field and bound is the bash pass's contract, owned by
bin/fm-fleet-snapshot.sh's header; this file only makes that pass cheap.
FM_SNAPSHOT_IMPL=bash selects the original bash pass.

Why it exists: the bash pass forked roughly a hundred processes per task (meta
reads, jq per field, one fm-crew-state.sh per task, each paying its own
no-mistakes daemon round trip and terminal read), so a fleet of ~125 tasks
took minutes on a loaded host and the home-summary refresh never finished.

How it stays faithful to the owners it does not restate:
  - Current state. A task is classified here only on the paths where
    bin/fm-crew-state.sh's answer is fully determined by file reads plus one
    fleet-wide endpoint inventory: no no-mistakes run to attribute (not a ship
    task, or a ship worktree at detached HEAD), an endpoint the backend's own
    inventory decides (orca terminal list, tmux list-windows), and a busy
    verdict from a semantic busy record (bin/fm-busy-lib.sh's record path, for
    the record-backed harnesses on non-herdr backends). Every other task - a
    ship task on a branch, which needs a fresh `no-mistakes axi status` read,
    an endpoint the inventory cannot decide, a harness whose busy source is
    not a record - is DELEGATED to fm-crew-state.sh itself, unchanged, under
    the bounds the bash pass used.
    tests/fm-fleet-snapshot-impl.test.sh pins both passes to identical output.
  - The one observational cache: state/snapshot-cache/runs/ holds, per
    repository, the owner's bounded `no-mistakes runs` listing for
    FM_SNAPSHOT_RUNS_CACHE_SECS (default 600; 0 refreshes every snapshot).
    It is shared verbatim with delegated fm-crew-state.sh reads through
    FM_CREW_STATE_RUNS_LIST_DIR (keys match bin/fm-nm-run-lib.sh
    fm_nm_repo_cache_key), which consult it only as their coarse fallback
    after their own fresh `axi status` read.
  - Open decisions. bin/fm-classify-lib.sh's read-only incremental fold runs
    in a few batched bash processes rather than being restated here. Like the
    bash pass, a started fold is never cut short by the observation deadline;
    only a generous safety bound stops a hung batch, and a fold that did not
    finish leaves no result rather than a partial one.
  - Status-line parsing (verb, note, paused) and the busy-record read are
    direct ports of bin/fm-classify-lib.sh and bin/fm-busy-lib.sh; the parity
    test drives both passes over the same fixtures so the ports cannot drift
    silently.
"""

import argparse
import concurrent.futures
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

SEP = " · "
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
FOLD_SAFETY_SECS = 300


def env_int(name, default, minimum=1):
    raw = os.environ.get(name, "")
    if raw.isdigit() and int(raw) >= minimum:
        return int(raw)
    return default


# --- meta ---------------------------------------------------------------------

def read_text(path):
    with open(path, "rb") as fh:
        return fh.read().decode("utf-8", "replace")


def meta_get(meta_text, key):
    """bin/fm-backend.sh fm_meta_get: the last `key=` line wins."""
    value = ""
    prefix = key + "="
    for line in meta_text.split("\n"):
        if line.startswith(prefix):
            value = line[len(prefix):]
    return value


def backend_of(meta_text):
    return meta_get(meta_text, "backend") or "tmux"


def target_of(meta_text):
    if backend_of(meta_text) == "orca":
        terminal = meta_get(meta_text, "terminal")
        if terminal:
            return terminal
    return meta_get(meta_text, "window")


def generation_is_current(captured_text, state_dir, task_id):
    current = os.path.join(state_dir, task_id + ".meta")
    if not os.path.isfile(current):
        return False
    try:
        current_text = read_text(current)
    except OSError:
        return False
    gen = meta_get(captured_text, "spawn_gen")
    if gen:
        return meta_get(current_text, "spawn_gen") == gen
    # Bash compares $(<file) values, which drop trailing newlines.
    return current_text.rstrip("\n") == captured_text.rstrip("\n")


# --- status lines (port of bin/fm-classify-lib.sh) -----------------------------

SPACE = " \t\n\v\f\r"
TAIL_BYTES = 65536
TS_RE = re.compile(
    r"^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?(\.[0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})?"
    r"|[0-9]{2}:[0-9]{2}(:[0-9]{2})?Z)$"
)
CORR_RE = re.compile(r"^corr=[0-9A-Fa-f]{16}$")
SLUG_RE = re.compile(r"^[A-Za-z0-9._-]+$")
WORD_SPLIT_RE = re.compile("[" + re.escape(SPACE) + "]")


def is_blank(line):
    return line.strip(SPACE) == ""


def last_status_line(path):
    """last_status_line: last non-blank line in the final 64 KiB."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            start = size - TAIL_BYTES if size > TAIL_BYTES else 0
            partial = False
            if start > 0:
                fh.seek(start - 1)
                partial = fh.read(1) != b"\n"
            fh.seek(start)
            data = fh.read()
    except OSError:
        return ""
    if partial:
        nl = data.find(b"\n")
        data = data[nl + 1:] if nl >= 0 else b""
    for raw in reversed(data.split(b"\n")):
        line = raw.decode("utf-8", "replace")
        if not is_blank(line):
            return line
    try:
        with open(path, "rb") as fh:
            whole = fh.read()
    except OSError:
        return ""
    found = ""
    for raw in whole.split(b"\n"):
        line = raw.decode("utf-8", "replace")
        if not is_blank(line):
            found = line
    return found


def strip_leading_timestamp(line):
    if not line[:1].isdigit():
        return line
    word = WORD_SPLIT_RE.split(line, maxsplit=1)[0]
    if not TS_RE.match(word):
        return line
    return line[len(word):].lstrip(SPACE)


def status_line_verb(line):
    v = strip_leading_timestamp(line)
    v = v.split(":", 1)[0]
    v = v.split("[", 1)[0]
    v = v.strip(SPACE)
    if "corr=" not in v:
        return v
    words = v.split()
    out = words[0] if words else ""
    for word in words[1:]:
        if CORR_RE.match(word):
            continue
        out += " " + word
    return out


def key_before_colon(line):
    head = strip_leading_timestamp(line).split(":", 1)[0]
    i = head.find("[key=")
    return i >= 0 and head.find("]", i + 5) >= 0


def key_at_note_head(line):
    line = strip_leading_timestamp(line)
    if ":" not in line:
        return None
    rest = line.split(":", 1)[1].lstrip(SPACE)
    if rest.startswith("[key=") and "]" in rest[5:]:
        return rest[5:].split("]", 1)[0]
    return None


def status_line_note(line):
    line = strip_leading_timestamp(line)
    if ":" not in line:
        return line
    n = line.split(":", 1)[1].lstrip(SPACE)
    if not key_before_colon(line):
        k = key_at_note_head(line)
        if k is not None and SLUG_RE.match(k):
            prefix = "[key=" + k + "]"
            if n.startswith(prefix):
                n = n[len(prefix):]
            n = n.lstrip(SPACE)
    return n


def map_log_state(line):
    verb = status_line_verb(line)
    if line and verb == (os.environ.get("FM_CLASSIFY_PAUSED_VERB") or "paused"):
        return "paused"
    return {
        "working": "working",
        "needs-decision": "parked",
        "blocked": "blocked",
        "done": "done",
        "failed": "failed",
    }.get(verb, "unknown")


PR_RE = re.compile(r'https?://[^\s)"]+/pull/[0-9]+')


def first_pr_url(path):
    try:
        with open(path, "rb") as fh:
            for raw in fh:
                m = PR_RE.search(raw.decode("utf-8", "replace"))
                if m:
                    return m.group(0)
    except OSError:
        pass
    return ""


# --- busy record (port of bin/fm-busy-lib.sh record path) ---------------------

TOKEN_RE = re.compile(r"^[A-Za-z0-9._-]+$")
# Harnesses whose busy verdict is not the semantic record alone. These - and
# any herdr task, whose classifier consults native pane state when no record
# exists - are delegated to fm-crew-state.sh.
DELEGATED_HARNESS_PREFIXES = ("kimi", "codex", "cursor", "muse", "grok", "rovo")


def trusted_sources(harness):
    if harness.startswith("claude"):
        adapter = "claude-hook"
    elif harness.startswith("opencode"):
        adapter = "opencode-plugin"
    elif harness.startswith("gemini"):
        adapter = "gemini-hook"
    elif harness in ("pi", "pi-signed"):
        adapter = "pi-ext"
    else:
        return set()
    return {adapter, "fm-spawn", "fm-interrupt", "fm-recovery"}


def read_first_line_strict(path):
    """`IFS= read -r line` success semantics: the line must end in a newline."""
    with open(path, "rb") as fh:
        data = fh.read()
    nl = data.find(b"\n")
    if nl < 0:
        return None, data
    return data[:nl].decode("utf-8", "replace"), data[nl + 1:]


def busy_record_read(state_dir, task_id):
    rec = os.path.join(state_dir, task_id + ".busy-state")
    if not os.path.isfile(rec):
        return None, "missing"
    gen_path = os.path.join(state_dir, task_id + ".busy-gen")
    gen = ""
    if os.path.isfile(gen_path):
        try:
            first, _ = read_first_line_strict(gen_path)
            gen = first or ""
        except OSError:
            gen = ""
    if not TOKEN_RE.match(gen):
        return None, "malformed"
    try:
        line, rest = read_first_line_strict(rec)
    except OSError:
        return None, "malformed"
    if line is None or b"\n" in rest:
        return None, "malformed"
    fields = [f for f in line.split(" ") if f != ""]
    if not fields or fields[0] != "v1":
        return None, "malformed"
    r = {"gen": "", "seq": "", "state": "", "source": "", "event": "", "ts": ""}
    for f in fields[1:]:
        key, eq, value = f.partition("=")
        if not eq or key not in r:
            return None, "malformed"
        r[key] = value
    for key in ("gen", "source", "event"):
        if not TOKEN_RE.match(r[key]):
            return None, "malformed"
    if not r["seq"].isdigit() or not r["ts"].isdigit():
        return None, "malformed"
    if r["state"] not in ("busy", "idle", "unknown"):
        return None, "malformed"
    if r["gen"] != gen:
        return None, "gen-mismatch"
    return (r["state"], r["source"]), None


def busy_verdict(state_dir, task_id, harness):
    rec, why = busy_record_read(state_dir, task_id)
    if rec is not None:
        if rec[1] in trusted_sources(harness):
            return "%s %s" % rec
        return "unknown source-mismatch"
    if why in ("malformed", "gen-mismatch"):
        return "unknown " + why
    return "unknown missing"


# --- git / no-mistakes ------------------------------------------------------------

def _crc_step(crc):
    for _ in range(8):
        crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if crc & 0x80000000 else (crc << 1) & 0xFFFFFFFF
    return crc


def cksum(data):
    """POSIX cksum CRC (the key bin/fm-nm-run-lib.sh fm_nm_repo_cache_key prints)."""
    crc = 0
    for byte in data:
        crc = _crc_step(crc ^ (byte << 24))
    length = len(data)
    while length:
        crc = _crc_step(crc ^ ((length & 0xFF) << 24))
        length >>= 8
    return (~crc) & 0xFFFFFFFF


def git_dir_of(worktree):
    dotgit = os.path.join(worktree, ".git")
    if os.path.isfile(dotgit):
        try:
            text = read_text(dotgit).rstrip("\n")
        except OSError:
            return None, None
        gitdir = text[len("gitdir: "):] if text.startswith("gitdir: ") else text
        common = gitdir.split("/worktrees/", 1)[0]
        if not os.path.isabs(gitdir):
            gitdir = os.path.normpath(os.path.join(worktree, gitdir))
        return gitdir, common
    if os.path.isdir(dotgit):
        return dotgit, dotgit
    return None, None


def repo_cache_key(worktree):
    _, common = git_dir_of(worktree)
    if not common:
        return ""
    return str(cksum(common.encode("utf-8", "surrogateescape")))


def current_branch(worktree):
    """`git symbolic-ref --quiet --short HEAD`, or None when it cannot be read here."""
    gitdir, _ = git_dir_of(worktree)
    if not gitdir:
        return None
    try:
        head = read_text(os.path.join(gitdir, "HEAD")).strip("\n")
    except OSError:
        return None
    if not head.startswith("ref: "):
        return ""
    ref = head[5:].strip()
    if ref.startswith("refs/heads/"):
        return ref[len("refs/heads/"):]
    return None


def run_bounded(cmd, timeout, cwd=None, env=None, stdin_text=None):
    """Run cmd in its own process group; (rc, stdout), rc 124 on timeout."""
    try:
        proc = subprocess.Popen(
            cmd, cwd=cwd, env=env,
            stdin=subprocess.PIPE if stdin_text is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        return 127, ""
    try:
        out, _ = proc.communicate(
            input=stdin_text.encode("utf-8", "surrogateescape") if stdin_text is not None else None,
            timeout=max(timeout, 0.1))
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        proc.communicate()
        return 124, ""
    return proc.returncode, out.decode("utf-8", "replace")


# --- results --------------------------------------------------------------------

def crew(state, source, detail=""):
    raw = "state: %s%ssource: %s" % (state, SEP, source)
    if detail:
        raw += SEP + detail
    return {"state": state, "source": source, "detail": detail, "raw": raw}


def unknown_current(detail):
    return {"state": "unknown", "source": "none", "detail": detail, "raw": ""}


def parse_crew_line(raw):
    """crew_state_json's parse of one fm-crew-state.sh line."""
    state, source, detail = "unknown", "none", ""
    marker = SEP + "source: "
    if raw.startswith("state: ") and marker in raw:
        rest = raw[len("state: "):]
        state, rest = rest.split(marker, 1)
        if SEP in rest:
            source, detail = rest.split(SEP, 1)
        else:
            source = rest
    return {"state": state, "source": source, "detail": detail, "raw": raw}


# --- the pass ---------------------------------------------------------------------

class Snapshot:
    def __init__(self, task_dir):
        self.task_dir = task_dir
        self.root = os.environ.get("FM_ROOT") or os.path.dirname(SCRIPT_DIR)
        self.home = os.environ["FM_HOME"]
        self.state = os.environ["STATE"]
        self.data = os.environ["DATA"]
        self.config = os.environ.get("CONFIG", "")
        self.projects = os.environ.get("PROJECTS", "")
        self.now = os.environ["SNAPSHOT_NOW"]
        self.crew_timeout = env_int("FM_SNAPSHOT_CREW_STATE_TIMEOUT", 4)
        self.concurrency = env_int("FM_SNAPSHOT_LOCAL_READ_CONCURRENCY", 16)
        self.prefetch_timeout = env_int("FM_SNAPSHOT_PREFETCH_TIMEOUT", 45)
        self.runs_ttl = env_int("FM_SNAPSHOT_RUNS_CACHE_SECS", 600, minimum=0)
        self.runs_limit = os.environ.get("FM_CREW_STATE_RUNS_LIMIT", "200")
        self.have_nm = shutil.which("no-mistakes") is not None
        self.runs_dir = None
        self.inventory = {}
        self.deadline = time.time() + self.prefetch_timeout

    # -- inventories -----------------------------------------------------------

    def endpoint_inventory(self, backends):
        """One read per backend of every live endpoint; absent when unreadable."""
        if "orca" in backends and shutil.which("orca"):
            rc, out = run_bounded(["orca", "terminal", "list", "--limit", "100000", "--json"],
                                  self.crew_timeout + 5)
            result = None
            if rc == 0:
                try:
                    result = (json.loads(out) or {}).get("result")
                except (ValueError, AttributeError):
                    result = None
            if isinstance(result, dict) and result.get("truncated") is not True \
                    and isinstance(result.get("terminals"), list):
                self.inventory["orca"] = {t.get("handle") for t in result["terminals"]
                                          if isinstance(t, dict) and t.get("handle")}
        if "tmux" in backends and shutil.which("tmux"):
            rc, out = run_bounded(["tmux", "list-windows", "-a", "-F", "#{session_name}:#{window_name}"],
                                  self.crew_timeout)
            if rc == 0:
                self.inventory["tmux"] = set(line for line in out.split("\n") if line)

    def endpoint_listed(self, backend, target):
        """True/False when the backend's inventory decides presence, else None."""
        inv = self.inventory.get(backend)
        if inv is None:
            return None
        if target in inv:
            return True
        # Only Orca's complete handle list proves absence; a tmux target also
        # resolves by index and pattern, so a tmux miss is left to the owner.
        return False if backend == "orca" else None

    # -- runs ledger ------------------------------------------------------------

    def prepare_runs(self, ship_worktrees):
        """The owner's bounded `no-mistakes runs` listing, once per repository,
        shared verbatim with delegated fm-crew-state.sh reads."""
        if not self.have_nm or not ship_worktrees:
            return
        root = os.path.join(self.state, "snapshot-cache")
        cache = os.path.join(root, "runs")
        if os.path.islink(self.state) or not os.path.isdir(self.state):
            return
        try:
            os.makedirs(cache, mode=0o700, exist_ok=True)
        except OSError:
            return
        if any(os.path.islink(p) or not os.path.isdir(p) for p in (root, cache)):
            return
        self.runs_dir = cache
        keys = {}
        for wt in ship_worktrees:
            key = repo_cache_key(wt)
            if key and key not in keys:
                keys[key] = wt
        now = time.time()
        stale = []
        for key, wt in keys.items():
            path = os.path.join(cache, key)
            try:
                fresh = (not os.path.islink(path)) and os.path.getsize(path) > 0 \
                    and now - os.path.getmtime(path) < self.runs_ttl
            except OSError:
                fresh = False
            if not fresh:
                stale.append((key, wt))

        def refresh(item):
            key, wt = item
            bound = min(self.crew_timeout, max(1, int(self.deadline - time.time())))
            rc, out = run_bounded(["no-mistakes", "runs", "--limit", self.runs_limit], bound, cwd=wt)
            path = os.path.join(cache, key)
            if rc == 0 and out:
                try:
                    fd, tmp = tempfile.mkstemp(prefix="." + key + ".", dir=cache)
                    with os.fdopen(fd, "w", encoding="utf-8", errors="replace") as fh:
                        fh.write(out)
                    os.replace(tmp, path)
                    return
                except OSError:
                    pass
            # A listing that cannot be refreshed is no longer current; leave the
            # delegated owner to its own read rather than a stale cache entry.
            try:
                os.unlink(path)
            except OSError:
                pass

        if stale:
            with concurrent.futures.ThreadPoolExecutor(max_workers=min(8, len(stale))) as pool:
                list(pool.map(refresh, stale))

    # -- owners called through bash -----------------------------------------------

    def bash_env(self):
        env = dict(os.environ)
        env.update({"FM_ROOT_OVERRIDE": self.root, "FM_HOME": self.home, "FM_STATE_OVERRIDE": self.state})
        return env

    def delegated_crew_state(self, task_id, captured_meta, captured_status, bound):
        env = self.bash_env()
        env.update({
            "FM_CREW_STATE_META_OVERRIDE": captured_meta,
            "FM_CREW_STATE_STATUS_OVERRIDE": captured_status,
            "FM_CREW_STATE_NM_TIMEOUT": str(bound),
            "FM_CREW_STATE_RUNS_LIST_DIR": self.runs_dir or "",
            "FM_DATA_OVERRIDE": self.data,
            "FM_PROJECTS_OVERRIDE": self.projects,
            "FM_CONFIG_OVERRIDE": self.config,
        })
        _, out = run_bounded([os.path.join(SCRIPT_DIR, "fm-crew-state.sh"), task_id], bound + 5, env=env)
        return parse_crew_line(out.split("\n", 1)[0] if out else "")

    def bash_endpoint(self, backend, target, label, want_agent):
        script = ('. "$1"; if fm_backend_target_exists "$2" "$3" "$4" >/dev/null 2>&1; then echo true; '
                  'else echo false; fi; if [ "$5" = 1 ]; then fm_backend_agent_alive "$2" "$3" 2>/dev/null '
                  '|| echo unknown; fi')
        _, out = run_bounded(["bash", "-c", script, "fm-snapshot-endpoint",
                              os.path.join(SCRIPT_DIR, "fm-backend.sh"), backend, target, label,
                              "1" if want_agent else "0"],
                             self.crew_timeout + 5, env=self.bash_env())
        lines = out.split("\n")
        exists = "true" if lines and lines[0] == "true" else "false"
        alive = None
        if want_agent:
            alive = lines[1] if len(lines) > 1 and lines[1] else "unknown"
        return exists, alive

    def fold_open_decisions(self, jobs):
        """bin/fm-classify-lib.sh's read-only fold, batched over a few bash processes."""
        if not jobs:
            return
        script = ('. "$1" || exit 1; while IFS=$\'\\t\' read -r log end out; do '
                  'if FM_OPEN_DECISIONS_READONLY=1 FM_OPEN_DECISIONS_SCRATCH_DIR="$2" '
                  'status_open_decisions_incremental "$log" "$end" > "$out.tmp" 2>/dev/null; '
                  'then mv -f "$out.tmp" "$out"; else rm -f "$out.tmp"; fi; done')
        chunks = max(1, min(4, len(jobs) // 8 + 1))
        groups = [jobs[i::chunks] for i in range(chunks)]

        def run(group):
            lines = "".join("%s\t%s\t%s\n" % job for job in group)
            run_bounded(["bash", "-c", script, "fm-snapshot-fold",
                         os.path.join(SCRIPT_DIR, "fm-classify-lib.sh"), self.task_dir],
                        FOLD_SAFETY_SECS, env=self.bash_env(), stdin_text=lines)

        with concurrent.futures.ThreadPoolExecutor(max_workers=len(groups)) as pool:
            list(pool.map(run, groups))
        for _, _, out in jobs:
            if not os.path.exists(out):
                open(out, "w").close()

    # -- per-task current state ----------------------------------------------------

    def native_crew_state(self, t):
        """fm-crew-state.sh's answer when file reads decide it, else None (delegate)."""
        wt, kind, harness = t["worktree"], t["kind"], t["harness"]
        if not wt or not os.path.isdir(wt):
            return crew("unknown", "none", "worktree gone (torn down?)")
        if kind == "ship" and self.have_nm:
            branch = current_branch(wt)
            if branch is None or branch:
                return None
        target, backend = t["target"], t["backend"]
        if not target:
            return crew("unknown", "none", "no backend target recorded")
        listed = self.endpoint_listed(backend, target)
        if listed is None:
            return None
        if listed is False:
            # fm-crew-state.sh reads an unreadable Orca terminal as gone.
            return crew("unknown", "none", "backend target gone: " + target)
        if kind != "secondmate":
            if backend == "herdr" or harness.startswith(DELEGATED_HARNESS_PREFIXES):
                return None
            verdict = busy_verdict(self.state, t["id"], harness)
            state = verdict.split(" ", 1)[0]
            if state == "busy":
                return crew("working", "pane", "harness busy (%s)" % verdict.split(" ", 1)[1])
            if state != "idle":
                return crew("unknown", "pane", "harness state unavailable (%s)" % verdict)
        line = last_status_line(t["status_capture"]) if os.path.isfile(t["status_capture"]) else ""
        if status_line_verb(line):
            log_state = map_log_state(line)
            if log_state != "unknown":
                return crew(log_state, "status-log", status_line_note(line))
        return crew("unknown", "none", "no current-state source available")

    def observe(self, t):
        """prefetch_task_observations for one task, minus the batched fold."""
        tid = t["id"]
        if time.time() >= self.deadline:
            t["degraded"] = "snapshot prefetch deadline reached before this task was read"
            return
        current = generation_is_current(t["meta_text"], self.state, tid)
        t["generation_current_before"] = current
        if current:
            live_status = os.path.join(self.state, tid + ".status")
            if os.path.isfile(live_status):
                try:
                    shutil.copy2(live_status, t["status_capture"])
                except OSError:
                    if os.path.exists(live_status):
                        raise
                    try:
                        os.unlink(t["status_capture"])
                    except OSError:
                        pass
            if os.path.isfile(os.path.join(self.data, tid, "report.md")):
                open(t["report_capture"], "w").close()
        if t["remote_host"]:
            t["current"] = unknown_current("remote endpoint liveness not collected by fleet snapshot")
            t["agent_alive"] = "unknown"
        elif current:
            bound = min(self.crew_timeout, max(1, int(self.deadline - time.time())))
            native = self.native_crew_state(t)
            if native is not None:
                t["current"] = native
            else:
                t["current"] = self.delegated_crew_state(tid, t["meta_path"], t["status_capture"], bound)
            if t["target"]:
                want_agent = t["kind"] == "secondmate"
                listed = self.endpoint_listed(t["backend"], t["target"])
                if listed is not None and not want_agent:
                    t["endpoint_exists"] = "true" if listed else "false"
                else:
                    exists, alive = self.bash_endpoint(t["backend"], t["target"], "fm-" + tid, want_agent)
                    t["endpoint_exists"] = exists
                    if want_agent:
                        t["agent_alive"] = alive
        else:
            t["current"] = unknown_current("task generation changed during snapshot")
            t["agent_alive"] = "unknown"

    def finish(self, t):
        """The post-observation generation re-check, after the folds ran."""
        if "degraded" in t:
            t["current"] = unknown_current(t["degraded"])
            t["endpoint_exists"] = "null"
            t["agent_alive"] = "unknown"
            open(t["opendecisions"], "w").close()
            return
        if not generation_is_current(t["meta_text"], self.state, t["id"]):
            for path in (t["status_capture"], t["report_capture"], t["opendecisions"]):
                try:
                    os.unlink(path)
                except OSError:
                    pass
            t["current"] = unknown_current("task generation changed during snapshot")
            t["endpoint_exists"] = "null"
            t["agent_alive"] = "unknown"

    def run(self):
        tasks = []
        try:
            names = sorted(os.listdir(self.state))
        except OSError:
            names = []
        for name in names:
            if not name.endswith(".meta"):
                continue
            src = os.path.join(self.state, name)
            if not os.path.isfile(src):
                continue
            tid = name[:-len(".meta")]
            dst = os.path.join(self.task_dir, name)
            try:
                shutil.copyfile(src, dst)
            except FileNotFoundError:
                continue
            meta_text = read_text(dst)
            remote_host = meta_get(meta_text, "remote_host")
            if remote_host:
                backend = meta_get(meta_text, "remote_backend") or "unknown"
                target = meta_get(meta_text, "remote_target")
            else:
                backend = backend_of(meta_text)
                target = target_of(meta_text)
            tasks.append({
                "id": tid, "meta_path": dst, "meta_text": meta_text,
                "kind": meta_get(meta_text, "kind") or "ship",
                "harness": meta_get(meta_text, "harness"), "worktree": meta_get(meta_text, "worktree"),
                "remote_host": remote_host, "backend": backend, "target": target,
                "status_capture": os.path.join(self.task_dir, tid + ".status"),
                "report_capture": os.path.join(self.task_dir, tid + ".report"),
                "opendecisions": os.path.join(self.task_dir, tid + ".opendecisions"),
                "endpoint_exists": "null", "agent_alive": "not_checked",
            })
        # The pass deadline starts after the manifest copy, as in the bash pass.
        self.deadline = time.time() + self.prefetch_timeout
        local = [t for t in tasks if not t["remote_host"]]
        self.prepare_runs([t["worktree"] for t in local if t["kind"] == "ship" and t["worktree"]])
        self.endpoint_inventory({t["backend"] for t in local if t["target"]})
        with concurrent.futures.ThreadPoolExecutor(max_workers=self.concurrency) as pool:
            for fut in [pool.submit(self.observe, t) for t in tasks]:
                fut.result()
        folds = []
        for t in tasks:
            if t.get("generation_current_before") and os.path.isfile(t["status_capture"]):
                folds.append((os.path.join(self.state, t["id"] + ".status"),
                              str(os.path.getsize(t["status_capture"])), t["opendecisions"]))
        self.fold_open_decisions(folds)
        for t in tasks:
            self.finish(t)
        rows = [self.task_row(t) for t in tasks]
        rows.sort(key=lambda row: row["id"])
        return rows

    # -- composition (task_json_lines) ---------------------------------------------

    def task_row(self, t):
        tid, meta, kind = t["id"], t["meta_text"], t["kind"]
        pr = meta_get(meta, "pr")
        pr_source = "meta"
        if not pr:
            pr = first_pr_url(t["status_capture"])
            pr_source = "status_event" if pr else "absent"
        current = t["current"]
        present = os.path.isfile(t["status_capture"])
        raw = last_status_line(t["status_capture"]) if present else ""
        event = {"path": os.path.join(self.state, tid + ".status"), "present": present,
                 "kind": "event_history",
                 "last_event": {"state": status_line_verb(raw), "note": status_line_note(raw), "raw": raw}}
        try:
            folded = read_text(t["opendecisions"])
        except OSError:
            folded = ""
        cs, csrc = current["state"], current["source"]
        if kind != "secondmate" and (
                (csrc in ("run-step", "pane") and cs not in ("parked", "blocked"))
                or cs in ("done", "failed")):
            folded = ""
        decisions = []
        for line in folded.split("\n"):
            parts = line.split("\t", 2)
            if line and len(parts) == 3:
                decisions.append({"key": parts[0], "verb": parts[1], "summary": parts[2]})
        report_present = os.path.isfile(t["report_capture"])
        worktree = meta_get(meta, "worktree")
        home = meta_get(meta, "home")
        projects = meta_get(meta, "projects")
        remote_host = t["remote_host"]
        if worktree:
            worktree_json = {"path": worktree, "present": os.path.exists(worktree)}
        else:
            worktree_json = {"path": None, "present": False}
        if home and remote_host:
            home_json = {"path": home, "present": None}
        elif home:
            home_json = {"path": home, "present": os.path.exists(home)}
        else:
            home_json = {"path": None, "present": False}
        exists = {"true": True, "false": False}.get(t["endpoint_exists"])
        alive = t["agent_alive"]
        if exists is False:
            endpoint_status = "absent"
        elif alive in ("alive", "dead"):
            endpoint_status = alive
        else:
            endpoint_status = "unknown"
        if kind == "secondmate":
            actions = {"send": "bin/fm-send.sh fm-%s '<request>'" % tid,
                       "watch": "read status/doc return channel; do not routinely fm-peek a secondmate for answers",
                       "return_channel_note": "Secondmate answers come back through status/doc paths after a marked fm-send request."}
        else:
            actions = {"watch": "bin/fm-peek.sh fm-%s" % tid,
                       "steer": "bin/fm-send.sh fm-%s '<instruction>'" % tid,
                       "return_channel_note": None}
        cur = dict(current)
        cur.update({"observed_at": self.now, "freshness": "fresh"})
        return {
            "id": tid,
            "kind": kind,
            "harness": meta_get(meta, "harness"),
            "mode": meta_get(meta, "mode"),
            "yolo": meta_get(meta, "yolo"),
            "project": meta_get(meta, "project"),
            "spawn_gen": meta_get(meta, "spawn_gen") or None,
            "backend": t["backend"],
            "remote": {"host": remote_host, "root": meta_get(meta, "remote_root")} if remote_host else None,
            "paths": {
                "meta": {"path": os.path.join(self.state, tid + ".meta"), "present": os.path.exists(t["meta_path"])},
                "status_log": event,
                "worktree": worktree_json,
                "home": home_json,
                "report": {"path": os.path.join(self.data, tid, "report.md"), "present": report_present},
            },
            "secondmate_projects": [p.strip(SPACE) for p in projects.split(",") if p.strip(SPACE)],
            "current_state": cur,
            "endpoint": {"target": t["target"] or None, "exists": exists, "agent_alive": alive,
                         "status": endpoint_status, "observed_at": self.now, "freshness": "fresh"},
            "pr": {"url": pr or None, "source": pr_source},
            "hints": {
                "pending_decision": any(d["verb"] == "needs-decision" for d in decisions),
                "blocked_event": any(d["verb"] == "blocked" for d in decisions),
                "open_decisions": decisions,
                "scout_report_present": report_present,
                "last_event_text": raw,
            },
            "actions": actions,
        }


def main():
    parser = argparse.ArgumentParser(description="fm-fleet-snapshot per-task pass")
    sub = parser.add_subparsers(dest="cmd", required=True)
    tasks = sub.add_parser("tasks")
    tasks.add_argument("--task-dir", required=True)
    args = parser.parse_args()
    rows = Snapshot(args.task_dir).run()
    sys.stdout.buffer.write(json.dumps(rows, ensure_ascii=False).encode("utf-8") + b"\n")


if __name__ == "__main__":
    main()
