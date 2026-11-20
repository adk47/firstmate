#!/usr/bin/env bash
# fm-overlord.sh - the standing overseer: one number per domain, read from the
# monitors that already exist, and an interjection when a named threshold is
# crossed.
#
# Usage:
#   fm-overlord.sh digest      read every source now and print one line per
#                              domain (numbers, source, age, verdict); changes nothing
#   fm-overlord.sh [check]     the watcher poll: read, compare against the named
#                              thresholds, interject on a crossing; silent otherwise
#   fm-overlord.sh status      print the lines the last check recorded (no reads)
#   fm-overlord.sh adjudicate <name> <value> <window> <source> <value> <window> <source> [...]
#                              apply the disagreement rule to readings of one number
#   fm-overlord.sh arm         write state/overlord.check.sh and bind it
#   fm-overlord.sh disarm      remove the shim, its trust binding, and the record
#   fm-overlord.sh --help      print this help
#
# WHY THIS EXISTS. On 2026-11-11 every failure was caught by the captain looking,
# not by a check: two lanes died unseen, five green pull requests sat unmerged, a
# stale review read nearly reverted three good merges, and a cap of 0 held every
# paid ask for a day. Each had a monitor somewhere; none raised itself. A monitor
# that cannot fire is a report, and one that fires on everything is noise. This
# one fires on a named threshold, says where the number came from, and puts the
# correction in front of the lane that can apply it.
#
# IT MEASURES NOTHING NEW. Every number is read from a source another monitor
# already writes, on every run, from the source itself: no verdict is carried
# over from an earlier run. A source that is absent, unreadable, stale, or cut
# short reads `unmeasured` with its reason, never as zero and never as fine.
#
# THE FIVE DOMAINS, their numbers, and the only thresholds that interject:
#
#   credit   users_told_today  newest `sentinel: pass` line in the sentinel
#                              lane's status log (its `users-told=` field).
#                              WRONG when it has not risen in 4h, measured
#                              between passes of the same UTC day.
#            would_send        summed over the family checks of each completed
#                              tick in the outbound tick log.
#                              WRONG when it is 0 on two consecutive ticks.
#   claims   stuck_over_7d_no_step, reason_loss
#                              fields of the claims backlog file.
#                              WRONG when either rises.
#   support  waiting_on_us, promised_a_person_24h, promises_broken_24h,
#            commitments_overdue
#                              fields of the support backlog file.
#                              WRONG when waiting_on_us rises, or
#                              commitments_overdue is above 0 (a commitment
#                              passed its due time with no sent message).
#   merges   open              open pull requests in the configured scope, with
#                              the busiest repositories.
#            green_unmerged_2h pull requests whose current head is green and
#                              mergeable, that head older than 2h, still open.
#                              WRONG when it rises.
#   meter    tick              the outbound tick against its cadence.
#                              WRONG when the last tick started longer ago than
#                              the cadence plus its slack, or one ran longer
#                              than the cadence.
#            unmeasured        readings above that could not be read, plus the
#                              sentinel's own `unmeasured=` count.
#                              WRONG when a domain is unmeasured on two
#                              consecutive checks.
#            stopped_lanes     workers the fleet watchdog holds on its stall
#                              ladder (state/.watchdog-worker.json). Shown, not
#                              a threshold: the watchdog owns those workers.
#
# "Rises" compares with the previous check's reading, and the first reading
# compares with zero, so a backlog already standing when the overseer is armed
# is interjected once rather than accepted as normal. An unchanged number is
# never a crossing. A rise stays open until the number is back at or below
# where it rose from; while it is open a further rise interjects again, at most
# once per FM_OVERLORD_REMIND_SECS.
#
# AN INTERJECTION IS THREE ACTIONS, IN ORDER, once per crossing:
#   1. one line appended to state/overlord.status naming the domain, the number,
#      its source, and its age, as `blocked [key=overlord-<rule>]: ...`. The
#      watcher turns that append into a firstmate wake.
#   2. one page (FM_OVERLORD_PAGE_CMD), with the crossed threshold.
#   3. one steer to the owning lane (bin/fm-send.sh, fire-and-forget), carrying
#      the specific correction rather than the observation.
# The crossing stays open, silently, until the number is back inside its
# threshold; then one `resolved [key=overlord-<rule>]` line closes it. A later
# crossing interjects again. A steer that could not be delivered is recorded on
# the same key, so firstmate routes the correction by hand.
#
# FABLE HAS TWO JOBS HERE.
#   Review before anything irreversible. The overseer itself only reads, writes
#   its own status line, pages, and steers. A crossing whose correction is an
#   irreversible act (merging pull requests) is steered to the Fable lane for a
#   verdict on the current head, never to the owning lane as an instruction to
#   act; with no Fable lane configured it is not steered at all and says so.
#   Adjudicate a disagreement. When two readings of one number differ, the rule
#   below is applied and the unresolved case goes to the Fable lane.
#
# THE DISAGREEMENT RULE (`adjudicate`, and every two-reading number above).
# Each reading is named with its window and its source. Readings over different
# windows are not the same measurement: the one whose window ends latest is
# authoritative, and the line says so and why. Readings over the same window
# that differ, or any reading whose window is unknown (`-`), cannot be
# established: the answer is `unmeasured`, never an average. A window is
# `<start>-><end>`, each an ISO-8601 UTC time.
#
# A STALE READ IS NOT A READING. The merge count is taken from the check result
# of each pull request's current head commit; a result attached to any other
# commit is not counted, is never taken as merged or unmerged, and is set aside
# and named with its count and pull request numbers, so one stale head cannot
# hide or unbalance the rest of the fleet.
#
# A LOWER BOUND IS NOT A MEASUREMENT EITHER. A forge read cut short before its
# last page, or a pull request whose mergeability is not computed yet, leaves
# the green-unmerged count a lower bound. That reading opens no crossing,
# closes no open one, and does not replace the previous reading; the number
# holds until a complete read says otherwise.
#
# CONFIGURATION. config/overlord.env (gitignored, per-home) holds KEY=value
# lines and is parsed, never sourced. A set environment variable of the same
# name wins. An unset source leaves its numbers `unmeasured (not configured)`.
#   FM_OVERLORD_REMOTE            command prefix that runs `sh -s` where the
#                                 remote files live (for example an ssh hop);
#                                 empty reads them on this host
#   FM_OVERLORD_SENTINEL_LANE     task id whose status log carries the sentinel passes
#   FM_OVERLORD_TICK_LOG          outbound tick log (on the remote)
#   FM_OVERLORD_TICK_CADENCE_SECS (7200)   FM_OVERLORD_TICK_SLACK_SECS (600)
#   FM_OVERLORD_CLAIMS_JSON       claims backlog file (on the remote)
#   FM_OVERLORD_SUPPORT_JSON      support backlog file (on the remote)
#   FM_OVERLORD_PR_SCOPE          pull request search scope, for example org:<login>
#   FM_OVERLORD_PR_PAGES (2)      pages of 100 green pull requests read per check
#   FM_OVERLORD_GREEN_AGE_SECS (7200)
#   FM_OVERLORD_FLAT_SECS (14400) FM_OVERLORD_STALE_SECS (3600)
#   FM_OVERLORD_OWNER_CREDIT FM_OVERLORD_OWNER_CLAIMS FM_OVERLORD_OWNER_SUPPORT
#   FM_OVERLORD_OWNER_MERGES FM_OVERLORD_OWNER_METER    owning lane per domain
#   FM_OVERLORD_FABLE_LANE        the lane that reviews and adjudicates
#   FM_OVERLORD_PAGE_CMD          shell command run with the page text as $1 and stdin
#   FM_OVERLORD_PROBE_SECS (600)  the check reads its sources at most this often
#   FM_OVERLORD_REMIND_SECS (14400)  least time between two interjections of one rise
#
# The backlog files are JSON objects carrying the fields named above and a
# `written_at` ISO-8601 UTC time; a file older than FM_OVERLORD_STALE_SECS is
# stale and its numbers unmeasured.
#
# RECORD. state/.overlord.json holds the previous reading of each number, the
# open crossings, and the last lines, stamped with its schema. It is what makes
# "rises", "two consecutive ticks", and "page once" possible; no verdict is read
# back from it.
#
# BOUNDED. The reads end inside half the watcher's FM_CHECK_TIMEOUT, at most 14
# seconds, and a read killed at that bound is reaped within 2 further seconds; a
# source not read in time is unmeasured for that check. A page is bounded at 5
# seconds and a steer at 6; an interjection that could not finish inside the
# timeout waits for the next poll, which reads again at once.
#
# Test seams: FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, FM_OVERLORD_NOW (frozen
# clock), FM_OVERLORD_GH_BIN (the forge client, default gh), FM_OVERLORD_SEND_BIN
# (the steer command, default bin/fm-send.sh), FM_OVERLORD_STATUS_FILE, and
# FM_OVERLORD_RECORD (the record path).
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
ENV_FILE="$CONFIG_DIR/overlord.env"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

CHECK_ID='overlord'
RECORD="${FM_OVERLORD_RECORD:-$STATE/.overlord.json}"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
CHECK_TIMEOUT_SECS=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT_SECS" in ''|*[!0-9]*) CHECK_TIMEOUT_SECS=30 ;; esac

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

now_epoch() {
  case "${FM_OVERLORD_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_OVERLORD_NOW" ;;
  esac
}

# conf <KEY> <default>: the environment wins, then the last KEY= line of
# config/overlord.env (parsed, never sourced), then the default.
conf() {
  local key=$1 default=$2 line value='' found=0
  eval "value=\${$key:-}"
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
    return 0
  fi
  if [ -f "$ENV_FILE" ] && [ ! -L "$ENV_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "$key="*)
          value=${line#*=}
          case "$value" in
            \"*\") value=${value#\"}; value=${value%\"} ;;
            \'*\') value=${value#\'}; value=${value%\'} ;;
          esac
          found=1
          ;;
      esac
    done < "$ENV_FILE"
  fi
  if [ "$found" = 1 ] && [ -n "$value" ]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$default"
  fi
}

conf_int() {  # <KEY> <default>
  local value
  value=$(conf "$1" "$2")
  case "$value" in ''|*[!0-9]*) value=$2 ;; esac
  printf '%s\n' "$value"
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-overlord.sh - overseer poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-overlord.sh") check"
}

action_arm() {
  local want home
  mkdir -p "$STATE" || return 1
  home=$(fm_custom_check_resolve_home "$FM_HOME") || {
    printf 'fm-overlord: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
    return 1
  }
  want=$(shim_content "$home")
  fm_custom_check_arm "$STATE" "$CHECK_ID" .fm-overlord fm-overlord \
    "$REGISTER_BIN" "$home" "$want"
}

action_disarm() {
  fm_custom_check_disarm "$STATE" "$CHECK_ID" "$RECORD"
}

# run_engine <action> [args...]: hand the resolved configuration to the engine.
run_engine() {
  local action=$1
  shift
  OV_ACTION=$action \
  OV_NOW=$(now_epoch) \
  OV_HOME=$FM_HOME \
  OV_STATE=$STATE \
  OV_RECORD=$RECORD \
  OV_CHECK_TIMEOUT=$CHECK_TIMEOUT_SECS \
  OV_STATUS_FILE=$(conf FM_OVERLORD_STATUS_FILE "$STATE/overlord.status") \
  OV_REMOTE=$(conf FM_OVERLORD_REMOTE '') \
  OV_SENTINEL_LANE=$(conf FM_OVERLORD_SENTINEL_LANE '') \
  OV_TICK_LOG=$(conf FM_OVERLORD_TICK_LOG '') \
  OV_TICK_CADENCE=$(conf_int FM_OVERLORD_TICK_CADENCE_SECS 7200) \
  OV_TICK_SLACK=$(conf_int FM_OVERLORD_TICK_SLACK_SECS 600) \
  OV_CLAIMS_JSON=$(conf FM_OVERLORD_CLAIMS_JSON '') \
  OV_SUPPORT_JSON=$(conf FM_OVERLORD_SUPPORT_JSON '') \
  OV_PR_SCOPE=$(conf FM_OVERLORD_PR_SCOPE '') \
  OV_PR_PAGES=$(conf_int FM_OVERLORD_PR_PAGES 2) \
  OV_GREEN_AGE=$(conf_int FM_OVERLORD_GREEN_AGE_SECS 7200) \
  OV_FLAT=$(conf_int FM_OVERLORD_FLAT_SECS 14400) \
  OV_STALE=$(conf_int FM_OVERLORD_STALE_SECS 3600) \
  OV_PROBE=$(conf_int FM_OVERLORD_PROBE_SECS 600) \
  OV_REMIND=$(conf_int FM_OVERLORD_REMIND_SECS 14400) \
  OV_OWNER_CREDIT=$(conf FM_OVERLORD_OWNER_CREDIT '') \
  OV_OWNER_CLAIMS=$(conf FM_OVERLORD_OWNER_CLAIMS '') \
  OV_OWNER_SUPPORT=$(conf FM_OVERLORD_OWNER_SUPPORT '') \
  OV_OWNER_MERGES=$(conf FM_OVERLORD_OWNER_MERGES '') \
  OV_OWNER_METER=$(conf FM_OVERLORD_OWNER_METER '') \
  OV_FABLE_LANE=$(conf FM_OVERLORD_FABLE_LANE '') \
  OV_PAGE_CMD=$(conf FM_OVERLORD_PAGE_CMD '') \
  OV_GH_BIN=$(conf FM_OVERLORD_GH_BIN gh) \
  OV_SEND_BIN=$(conf FM_OVERLORD_SEND_BIN "$SCRIPT_DIR/fm-send.sh") \
  python3 - "$@" <<'PY'
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time

E = os.environ
ACTION = E["OV_ACTION"]
NOW = int(E["OV_NOW"])
STARTED = time.monotonic()
STATE = E["OV_STATE"]
RECORD = E["OV_RECORD"]
STATUS_FILE = E["OV_STATUS_FILE"]
CHECK_TIMEOUT = int(E["OV_CHECK_TIMEOUT"])
READ_BUDGET = max(3, min(14, CHECK_TIMEOUT // 2))
SCHEMA = 1
MAX_LINE = 1500
DOMAINS = ("credit", "claims", "support", "merges", "meter")
PATH_RE = re.compile(r"^/[A-Za-z0-9._/@+-]+$")
LANE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$")


def cfg(key, default=""):
    return E.get("OV_" + key, default)


def cfg_int(key, default):
    try:
        return int(cfg(key, str(default)))
    except ValueError:
        return default


def left():
    return READ_BUDGET - (time.monotonic() - STARTED)


def iso(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%MZ")


def hhmm(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%H:%MZ")


def parse_iso(text):
    text = (text or "").strip()
    if not text:
        return None
    if re.fullmatch(r"\d{9,11}", text):
        return int(text)
    try:
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        when = datetime.datetime.fromisoformat(text)
    except ValueError:
        return None
    if when.tzinfo is None:
        when = when.replace(tzinfo=datetime.timezone.utc)
    return int(when.timestamp())


def age(seconds):
    if seconds is None:
        return "unknown"
    seconds = max(0, int(seconds))
    if seconds < 3600:
        return "%dm" % (seconds // 60)
    if seconds < 86400:
        return "%dh%02dm" % (seconds // 3600, seconds % 3600 // 60)
    return "%dd%02dh" % (seconds // 86400, seconds % 86400 // 3600)


def one_line(text):
    text = re.sub(r"\s+", " ", text).strip()
    return text if len(text) <= MAX_LINE else text[: MAX_LINE - 3] + "..."


class Reading:
    """One number: its value, where it came from, and when. value None = unmeasured."""

    def __init__(self, name, value=None, source="", at=None, note="", why="", partial=False):
        self.name = name
        self.value = value
        self.source = source
        self.at = at
        self.note = note
        self.why = why
        self.partial = partial

    def text(self):
        if self.value is None:
            return "%s=unmeasured (%s)" % (self.name, self.why or "no reading")
        bits = [b for b in (self.note, "source " + self.source if self.source else "",
                            "age " + age(NOW - self.at) if self.at is not None else "") if b]
        return "%s=%s [%s]" % (self.name, self.value, "; ".join(bits))


# --- the disagreement rule ---------------------------------------------------

def adjudicate(name, observations):
    """observations: dicts of value, window (text or ''), end (epoch or None), source.

    Returns (value or None, explanation or ''). No explanation means they agree.
    """
    if len({str(o["value"]) for o in observations}) <= 1:
        return observations[0]["value"], ""
    named = "; ".join(
        "%s [window %s, source %s]" % (o["value"], o["window"] or "unknown", o["source"])
        for o in observations
    )
    if any(not o["window"] or o["end"] is None for o in observations):
        return None, "%s disagrees: %s - a reading has no known window, so neither can be established" % (name, named)
    if len({o["window"] for o in observations}) == 1:
        return None, "%s disagrees over one window: %s - neither can be established" % (name, named)
    latest = max(o["end"] for o in observations)
    winners = [o for o in observations if o["end"] == latest]
    if len({str(o["value"]) for o in winners}) > 1:
        return None, "%s disagrees: %s - the latest windows end together and differ, so neither can be established" % (name, named)
    win = winners[0]
    return win["value"], "%s: %s - authoritative is %s [window %s, source %s] because its window ends latest; the others describe earlier windows" % (
        name, named, win["value"], win["window"], win["source"])


def window_end(window):
    if not window or window == "-" or "->" not in window:
        return None
    return parse_iso(window.split("->", 1)[1])


if ACTION == "adjudicate":
    args = sys.argv[1:]
    if len(args) < 7 or (len(args) - 1) % 3 != 0:
        sys.stderr.write("fm-overlord: adjudicate <name> then <value> <window> <source> for each reading (two or more)\n")
        sys.exit(2)
    obs = []
    for i in range(1, len(args), 3):
        window = "" if args[i + 1] == "-" else args[i + 1]
        obs.append({"value": args[i], "window": window, "end": window_end(window), "source": args[i + 2]})
    value, why = adjudicate(args[0], obs)
    if not why:
        print("%s=%s (the readings agree)" % (args[0], value))
    elif value is None:
        print("%s=unmeasured: %s" % (args[0], why))
        sys.exit(1)
    else:
        print("%s=%s: %s" % (args[0], value, why))
    sys.exit(0)


# --- the record --------------------------------------------------------------

def load_record():
    try:
        with open(RECORD) as handle:
            record = json.load(handle)
    except (OSError, ValueError):
        return {}
    if not isinstance(record, dict) or record.get("schema") != SCHEMA:
        return {}
    return record


def save_record(record):
    record["schema"] = SCHEMA
    os.makedirs(os.path.dirname(RECORD), exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".overlord.", dir=os.path.dirname(RECORD))
    with os.fdopen(fd, "w") as handle:
        json.dump(record, handle, sort_keys=True)
    os.replace(tmp, RECORD)


record = load_record()

if ACTION == "status":
    lines = record.get("lines") or []
    if not lines:
        print("fm-overlord: no check has recorded a reading yet")
        sys.exit(0)
    print("recorded %s (%s ago)" % (iso(record.get("probed_at", 0)), age(NOW - record.get("probed_at", NOW))))
    for line in lines:
        print(line)
    for key in sorted(record.get("episodes") or {}):
        print("open: %s since %s" % (key, iso(record["episodes"][key].get("opened_at", 0))))
    sys.exit(0)

if ACTION == "check":
    # A check runs on every watcher poll; the sources are read at most this often.
    if NOW - int(record.get("probed_at", 0) or 0) < cfg_int("PROBE", 600) and not record.get("deferred"):
        sys.exit(0)


# --- reads -------------------------------------------------------------------

REMOTE_SCRIPT = r"""
emit() {
  if [ -r "$2" ]; then
    m=$(stat -c %Y "$2" 2>/dev/null || stat -f %m "$2" 2>/dev/null || echo 0)
    printf '@@file %s present %s\n' "$1" "$m"
    if [ "$3" = log ]; then
      tail -c 600000 "$2" | grep -E 'tick start|tick done|would_send|another tick holds|check \(rc=' || :
    else
      head -c 200000 "$2"; printf '\n'
    fi
  else
    printf '@@file %s absent 0\n' "$1"
  fi
}
printf '@@now %s\n' "$(date +%s)"
"""


def start_remote():
    wanted = []
    for name, key, kind in (("ticklog", "TICK_LOG", "log"), ("claims", "CLAIMS_JSON", "json"), ("support", "SUPPORT_JSON", "json")):
        path = cfg(key)
        if path and PATH_RE.match(path):
            wanted.append("emit %s '%s' %s\n" % (name, path, kind))
    if not wanted:
        return None
    script = REMOTE_SCRIPT + "".join(wanted) + "printf '@@end\\n'\n"
    prefix = cfg("REMOTE").split()
    try:
        proc = subprocess.Popen(prefix + ["sh", "-s"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL)
    except OSError:
        return None
    proc._script = script.encode()
    return proc


def finish_remote(proc):
    """Returns ({name: (present, mtime, text)}, complete, remote_now)."""
    files, complete, remote_now = {}, False, None
    if proc is None:
        return files, complete, remote_now
    out = b""
    try:
        out, _ = proc.communicate(input=proc._script, timeout=max(0.5, left()))
    except subprocess.TimeoutExpired as error:
        out = error.output or b""
        proc.kill()
        try:
            proc.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            pass
    except OSError:
        proc.kill()
    current, body = None, []
    for line in out.decode("utf-8", "replace").splitlines():
        if line.startswith("@@now "):
            remote_now = parse_iso(line[6:])
        elif line.startswith("@@file ") or line == "@@end":
            if current:
                files[current[0]] = (current[1], current[2], "\n".join(body))
            current, body = None, []
            if line == "@@end":
                complete = True
            else:
                parts = line.split()
                if len(parts) == 4:
                    current = (parts[1], parts[2] == "present", int(parts[3]) if parts[3].isdigit() else 0)
        elif current:
            body.append(line)
    return files, complete, remote_now


GH_QUERY = """query($q:String!,$g:String!,$after:String){
 total: search(query:$q,type:ISSUE,first:1){issueCount}
 green: search(query:$g,type:ISSUE,first:100,after:$after){issueCount pageInfo{hasNextPage endCursor}
  nodes{... on PullRequest{number url mergeable headRefOid repository{nameWithOwner}
   commits(last:1){nodes{commit{oid committedDate statusCheckRollup{state}}}}}}}
}"""
GH_REPOS = """query($org:String!){organization(login:$org){repositories(first:100,orderBy:{field:PUSHED_AT,direction:DESC}){
 nodes{name pullRequests(states:OPEN){totalCount}}}}}"""


def gh(query, fields):
    budget = left()
    if budget < 1:
        return None
    argv = [cfg("GH_BIN", "gh"), "api", "graphql", "-f", "query=" + query]
    for key, value in fields.items():
        if value is not None:
            argv += ["-f", "%s=%s" % (key, value)]
    try:
        done = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=min(8, budget))
        data = json.loads(done.stdout.decode("utf-8", "replace"))
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None
    if done.returncode != 0 or not isinstance(data, dict) or data.get("errors") or not isinstance(data.get("data"), dict):
        return None
    return data["data"]


def read_merges():
    scope = cfg("PR_SCOPE")
    src = "forge search %s" % scope
    if not scope:
        return [Reading("open", why="not configured"), Reading("green_unmerged_2h", why="not configured")], []
    if scope.startswith("org:") and not scope[4:].strip():
        why = "FM_OVERLORD_PR_SCOPE names an org with no login"
        return [Reading("open", why=why), Reading("green_unmerged_2h", why=why)], []
    green_age = cfg_int("GREEN_AGE", 7200)
    total, counted, stale_heads, stale_numbers, unknown, urls, after, more = None, 0, 0, [], 0, [], None, False
    pages = 0
    for _ in range(max(1, cfg_int("PR_PAGES", 2))):
        data = gh(GH_QUERY, {"q": "%s is:pr is:open" % scope,
                             "g": "%s is:pr is:open draft:false status:success" % scope, "after": after})
        if data is None:
            more = pages > 0
            break
        pages += 1
        total = (data.get("total") or {}).get("issueCount")
        green = data.get("green") or {}
        for node in green.get("nodes") or []:
            commits = ((node.get("commits") or {}).get("nodes") or [])
            commit = (commits[0].get("commit") if commits else None) or {}
            # A result attached to anything but the current head is not a reading.
            if not commit or commit.get("oid") != node.get("headRefOid"):
                stale_heads += 1
                stale_numbers.append(str(node.get("number")))
                continue
            if node.get("mergeable") == "UNKNOWN":
                unknown += 1
                continue
            pushed = parse_iso(commit.get("committedDate"))
            state = (commit.get("statusCheckRollup") or {}).get("state")
            if node.get("mergeable") == "MERGEABLE" and state == "SUCCESS" and pushed and NOW - pushed > green_age:
                counted += 1
                urls.append((pushed, node.get("url") or ""))
        page_info = green.get("pageInfo") or {}
        more = bool(page_info.get("hasNextPage"))
        after = page_info.get("endCursor")
        if not more:
            break
    if pages == 0:
        why = "the forge did not answer inside the read budget"
        return [Reading("open", why=why), Reading("green_unmerged_2h", why=why)], []
    if total is None:
        why = "the forge answer carried no open count"
        return [Reading("open", why=why), Reading("green_unmerged_2h", why=why)], []
    note = ""
    if scope.startswith("org:") and left() > 2:
        login = scope[4:].split()[0] if scope[4:].split() else ""
        repos = gh(GH_REPOS, {"org": login}) if login else None
        org = (repos or {}).get("organization") or {}
        nodes = ((org.get("repositories") or {}).get("nodes") or [])
        if nodes:
            rows = sorted(((r.get("pullRequests", {}).get("totalCount", 0), r.get("name", "")) for r in nodes), reverse=True)
            note = "busiest " + ", ".join("%s %d" % (name, count) for count, name in rows[:4] if count)
    bits = ["green and mergeable on the current head, head older than %s" % age(green_age)]
    if more:
        bits.append("a lower bound: first %d green pull requests read" % (pages * 100))
    if unknown:
        bits.append("%d with mergeability not yet computed left out" % unknown)
    if stale_heads:
        bits.append("%d stale head(s) set aside: %s" % (stale_heads, ", ".join(stale_numbers)))
    # Newest first: a head that just passed the window is the one a lane is waiting on.
    urls.sort(reverse=True)
    return [Reading("open", total, src, NOW, note),
            Reading("green_unmerged_2h", counted, src, NOW, "; ".join(bits),
                    partial=bool(more or unknown))], [u for _, u in urls[:5]]


PASS_RE = re.compile(r"sentinel: pass (\d+) (\S+)->(\S+) on \S+: (.*)")


def read_sentinel():
    """Returns (passes oldest first, source label, why-unreadable)."""
    lane = cfg("SENTINEL_LANE")
    if not lane or not LANE_RE.match(lane):
        return [], "", "not configured"
    path = os.path.join(STATE, lane + ".status")
    src = "state/%s.status" % lane
    try:
        with open(path, "rb") as handle:
            handle.seek(0, 2)
            size = handle.tell()
            handle.seek(max(0, size - 1500000))
            text = handle.read().decode("utf-8", "replace")
    except OSError:
        return [], src, "%s is not readable" % src
    passes = []
    for line in text.splitlines():
        found = PASS_RE.search(line)
        if not found:
            continue
        end = parse_iso(found.group(3))
        if end is None:
            continue
        fields = dict(re.findall(r"([a-z0-9-]+)=(\S+)", found.group(4).split(" | ")[0]))
        passes.append({"n": int(found.group(1)), "window": "%s->%s" % (found.group(2), found.group(3)),
                       "end": end, "fields": fields})
    if not passes:
        return [], src, "%s has no sentinel pass line" % src
    passes.sort(key=lambda p: (p["end"], p["n"]))
    return passes, src, ""


def field_int(fields, name):
    value = fields.get(name, "")
    return int(value) if re.fullmatch(r"\d+", value) else None


TS_RE = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) (.*)$")


def parse_ticks(text):
    ticks, current = [], None
    for line in text.splitlines():
        found = TS_RE.match(line)
        if not found:
            continue
        when, rest = parse_iso(found.group(1)), found.group(2)
        if rest.startswith("tick start"):
            cap = re.search(r"\bcap=(\S+)", rest)
            current = {"start": when, "done": None, "would_send": 0, "families": 0, "failed_reads": 0,
                       "failed": False, "cap": cap.group(1) if cap else ""}
            ticks.append(current)
        elif current is None or current["done"] is not None:
            continue
        elif rest.startswith("tick done"):
            current["done"] = when
            current["failed"] = "FAILED" in rest
        else:
            check = re.search(r"check \(rc=(\d+)\): (.*)$", rest)
            if not check:
                continue
            body = check.group(2)
            count = re.search(r'"would_send": (\d+)', body)
            if count:
                current["would_send"] += int(count.group(1))
                current["families"] += 1
            elif check.group(1) != "0":
                current["failed_reads"] += 1
    return ticks


def backlog_fields(files, complete, name, key, fields):
    """Read named integer fields from a remote JSON backlog file."""
    path = cfg(key)
    if not path:
        return [Reading(f, why="not configured") for f in fields]
    src = "%s%s" % ("remote:" if cfg("REMOTE") else "", path)
    if not PATH_RE.match(path):
        return [Reading(f, why="%s is not a plain absolute path" % key) for f in fields]
    if name not in files:
        why = "%s was not read inside the budget" % src if not complete else "%s was not read" % src
        return [Reading(f, why=why) for f in fields]
    present, mtime, text = files[name]
    if not present:
        return [Reading(f, why="%s does not exist: no monitor writes it yet" % src) for f in fields]
    try:
        data = json.loads(text)
    except ValueError:
        data = None
    if not isinstance(data, dict):
        return [Reading(f, why="%s is not a JSON object" % src) for f in fields]
    written = parse_iso(str(data.get("written_at", ""))) or mtime or None
    if written is None or NOW - written > cfg_int("STALE", 3600):
        return [Reading(f, why="%s is stale: written %s ago" % (src, age(NOW - written) if written else "at an unknown time"))
                for f in fields]
    out = []
    for field in fields:
        value = data.get(field)
        if isinstance(value, bool) or not isinstance(value, int):
            out.append(Reading(field, why="%s has no integer %s" % (src, field)))
        else:
            out.append(Reading(field, value, src, written))
    return out


# --- collect -----------------------------------------------------------------

remote = start_remote()
merge_readings, merge_urls = read_merges()
files, remote_complete, _remote_now = finish_remote(remote)
passes, sentinel_src, sentinel_why = read_sentinel()

readings = {d: [] for d in DOMAINS}
crossings = []  # dicts: key domain threshold number source at owner correction fable
notes = {d: [] for d in DOMAINS}
previous = record.get("readings") or {}
new_values = {}


episodes = record.get("episodes") or {}


def rises(key, domain, reading):
    """(crossing, baseline): above the previous reading opens a rise (zero at first);
    an open rise holds until the number is back at or below where it rose from."""
    name = "%s.%s" % (domain, reading.name)
    before = previous.get(name)
    episode = episodes.get("overlord-" + key)
    if reading.value is None:
        # Unmeasured is not evidence either way: keep the last reading and any open rise.
        if before is not None:
            new_values[name] = before
        return False, before or 0
    if reading.partial:
        if before is not None:
            new_values[name] = before
        return False, before or 0
    new_values[name] = reading.value
    if episode is not None:
        baseline = episode.get("baseline") or 0
        return reading.value > baseline, baseline
    return reading.value > (before or 0), (before or 0)


def cross(key, domain, threshold, reading, correction, fable=False, baseline=None, value=None):
    if value is None and baseline is not None:
        value = reading.value
    crossings.append({"key": key, "domain": domain, "threshold": threshold, "number": "%s=%s" % (reading.name, reading.value),
                      "source": reading.source, "at": reading.at, "correction": correction, "fable": fable,
                      "owner": cfg("OWNER_" + domain.upper()), "baseline": baseline,
                      "value": value, "reads": ["%s.%s" % (domain, reading.name)]})


# credit: users_told_today
told = Reading("users_told_today", why=sentinel_why or "no sentinel pass")
sentinel_unmeasured = None
sentinel_unmeasured_twice = False
if passes:
    newest = passes[-1]
    same = [p for p in passes if p["n"] == newest["n"]]
    observed = [{"value": p["fields"].get("users-told", ""), "window": p["window"], "end": p["end"], "source": sentinel_src}
                for p in same]
    value, why = adjudicate("users_told_today", observed)
    number = field_int({"v": str(value or "")}, "v")
    if NOW - newest["end"] > cfg_int("STALE", 3600):
        told.why = "%s is stale: newest pass %d ended %s ago" % (sentinel_src, newest["n"], age(NOW - newest["end"]))
    elif value is None:
        told.why = why
        crossings.append({"key": "disagree-users-told", "domain": "credit", "threshold": "two readings of one number disagree",
                          "number": "users_told_today=unmeasured", "source": sentinel_src, "at": newest["end"],
                          "owner": cfg("OWNER_CREDIT"), "fable": True, "adjudicate": True,
                          "reads": ["credit.users_told_today"],
                          "correction": "Adjudicate: %s. Name the authoritative reading and why, or confirm it is unmeasured." % why})
    elif number is None:
        told.why = "pass %d carries no users-told count" % newest["n"]
    else:
        told = Reading("users_told_today", number, sentinel_src, newest["end"],
                       "pass %d window %s" % (newest["n"], newest["window"]))
        day = iso(newest["end"])[:10]
        earlier = [p for p in passes if p["end"] <= newest["end"] - cfg_int("FLAT", 14400) and iso(p["end"])[:10] == day]
        ref = earlier[-1] if earlier else None
        ref_value = field_int(ref["fields"], "users-told") if ref else None
        if ref_value is not None and number <= ref_value:
            told.note += "; flat since at least %s" % hhmm(ref["end"])
            cross("credit-users-told", "credit", "users_told_today has not risen in %s" % age(cfg_int("FLAT", 14400)), told,
                  "users_told_today has stood at %d since at least %s. Find which send family stopped telling users, "
                  "and either restore it and report the tick line showing sent above 0, or report the measured reason "
                  "nobody is owed a message." % (number, iso(ref["end"])), baseline=0)
    sentinel_unmeasured = field_int(newest["fields"], "unmeasured")
    earlier_pass = [p for p in passes if p["n"] != newest["n"]]
    if sentinel_unmeasured and earlier_pass and (field_int(earlier_pass[-1]["fields"], "unmeasured") or 0) > 0:
        sentinel_unmeasured_twice = True
readings["credit"].append(told)

# credit: would_send, and the tick the meter watches
tick_log = cfg("TICK_LOG")
tick_src = "%s%s" % ("remote:" if cfg("REMOTE") else "", tick_log)
would = Reading("would_send", why="not configured")
tick = Reading("tick", why="not configured")
if tick_log:
    if "ticklog" not in files:
        would.why = tick.why = ("%s was not read inside the budget" % tick_src if not remote_complete
                                else "%s was not read" % tick_src)
    elif not remote_complete:
        would.why = tick.why = "%s was cut short before the read finished" % tick_src
    elif not files["ticklog"][0]:
        would.why = tick.why = "%s does not exist" % tick_src
    else:
        ticks = parse_ticks(files["ticklog"][2])
        done = [t for t in ticks if t["done"] is not None]
        cadence, slack = cfg_int("TICK_CADENCE", 7200), cfg_int("TICK_SLACK", 600)
        if len(done) < 2:
            would.why = "%s holds fewer than two completed ticks" % tick_src
        else:
            a, b = done[-2], done[-1]
            failed_reads = a["failed_reads"] + b["failed_reads"]
            note = "last two completed ticks, done %s and %s; cap=%s" % (hhmm(a["done"]), hhmm(b["done"]), b["cap"] or "?")
            if failed_reads:
                note += "; %d family reads failed in them" % failed_reads
            would = Reading("would_send", "%d,%d" % (a["would_send"], b["would_send"]), tick_src, b["done"], note)
            if a["would_send"] == 0 and b["would_send"] == 0:
                cross("credit-would-send", "credit", "would_send=0 on two consecutive ticks", would,
                      "would_send was 0 on the ticks done %s and %s (cap=%s, %d family reads failed, %d families read). "
                      "Find what removed every candidate - the failed family reads first, then the gate that filtered the rest - "
                      "fix that read path, and prove it with one tick line showing would_send above 0 and sent above 0."
                      % (iso(a["done"]), iso(b["done"]), b["cap"] or "?", failed_reads, a["families"] + b["families"]))
        if not ticks:
            tick.why = "%s holds no tick start line" % tick_src
        else:
            last = ticks[-1]
            since = NOW - last["start"]
            ran = (last["done"] or NOW) - last["start"]
            state = "ran %s" % age(ran) if last["done"] else "still running after %s" % age(ran)
            tick = Reading("tick", "started %s ago" % age(since), tick_src, last["start"],
                           "%s; cadence %s" % (state, age(cadence)))
            if since > cadence + slack:
                cross("meter-tick", "meter", "the tick exceeds its cadence", tick,
                      "The outbound tick last started %s (%s ago) against a cadence of %s. Find why the scheduled tick did not "
                      "start - the schedule entry, a held lock, a failed unit - restore one on-cadence tick, and report its "
                      "start and done lines." % (iso(last["start"]), age(since), age(cadence)), baseline=0, value=since)
            elif ran > cadence:
                cross("meter-tick", "meter", "the tick exceeds its cadence", tick,
                      "The outbound tick that started %s has run %s against a cadence of %s. Find what it is waiting on, "
                      "and report the done line of a tick that finishes inside the cadence." % (iso(last["start"]), age(ran), age(cadence)),
                      baseline=0, value=ran)
readings["credit"].append(would)

# claims
for reading, key, text in zip(
        backlog_fields(files, remote_complete, "claims", "CLAIMS_JSON", ("stuck_over_7d_no_step", "reason_loss")),
        ("claims-stuck", "claims-reason-loss"),
        ("claims stuck over 7 days with no verification step delivered rose from %d to %d. Deliver the missing "
         "verification step to each claim newly past 7 days and report the count back at or below %d.",
         "rejections that lost their reason rose from %d to %d. Carry the supplied rejection reason through on the "
         "path that drops it, and report the count back at or below %d.")):
    readings["claims"].append(reading)
    rose, before = rises(key, "claims", reading)
    if rose:
        cross(key, "claims", "%s rises" % reading.name, reading, text % (before, reading.value, before), baseline=before)

# support
support = backlog_fields(files, remote_complete, "support", "SUPPORT_JSON",
                         ("waiting_on_us", "promised_a_person_24h", "promises_broken_24h", "commitments_overdue"))
readings["support"] = support
rose, before = rises("support-waiting", "support", support[0])
if rose:
    cross("support-waiting", "support", "waiting_on_us rises", support[0],
          "waiting_on_us rose from %d to %d. Answer the longest-waiting threads first until it is back at or below %d, "
          "and report the count." % (before, support[0].value, before), baseline=before)
if support[3].value:
    cross("support-overdue", "support", "a commitment passed its due time with no sent message", support[3],
          "%d commitments are past their due time with no sent message. For each, send the promised message or tell the "
          "customer the new time, then report commitments_overdue=0." % support[3].value, baseline=0)

# merges
readings["merges"] = merge_readings
rose, before = rises("merges-green-unmerged", "merges", merge_readings[1])
if rose:
    owner = cfg("OWNER_MERGES") or "the merge owner"
    cross("merges-green-unmerged", "merges", "green_unmerged_2h rises", merge_readings[1],
          "%d pull requests are green and mergeable on their current head, that head older than %s, and nobody merged "
          "them (was %d). Most recent: %s. Review each on its current head and send a GO or NO-GO naming that head to %s; "
          "only a GO on the head that is still current may be merged, through the guarded merge path."
          % (merge_readings[1].value, age(cfg_int("GREEN_AGE", 7200)), before, " ".join(merge_urls) or "none listed", owner),
          fable=True, baseline=before)

# meter
readings["meter"].append(tick)
unmeasured = {}
for domain in DOMAINS:
    for reading in readings[domain]:
        if reading.value is None and reading.why != "not configured":
            unmeasured.setdefault(domain, []).append("%s (%s)" % (reading.name, reading.why))
if sentinel_unmeasured:
    unmeasured.setdefault("credit", []).append("the sentinel's own unmeasured=%d" % sentinel_unmeasured)
count = sum(len(v) for v in unmeasured.values())
readings["meter"].append(Reading("unmeasured", count, "this check's own reads" + (" + " + sentinel_src if sentinel_src else ""), NOW))
before_unmeasured = record.get("unmeasured") or {}
for domain, items in sorted(unmeasured.items()):
    twice = domain in before_unmeasured or (domain == "credit" and sentinel_unmeasured_twice)
    if twice:
        holder = Reading("unmeasured", len(items), "this check's own reads", NOW)
        crossings.append({"key": "meter-unmeasured-%s" % domain, "domain": "meter",
                          "threshold": "%s unmeasured on two consecutive checks" % domain,
                          "number": "unmeasured=%d" % len(items), "source": holder.source, "at": NOW, "fable": False,
                          "owner": cfg("OWNER_" + domain.upper()) or cfg("OWNER_METER"),
                          "reads": ["%s.%s" % (domain, r.name) for r in readings[domain]
                                    if r.value is None and r.why != "not configured"],
                          "correction": "These %s numbers have been unmeasured for two checks: %s. Make each one readable - write "
                                        "the missing source, fix the failing read - or report that it cannot be measured and why."
                                        % (domain, "; ".join(items))})
try:
    with open(os.path.join(STATE, ".watchdog-worker.json")) as handle:
        watchdog = json.load(handle)
    stopped = sum(1 for t in (watchdog.get("tasks") or {}).values() if isinstance(t, dict) and (t.get("stage") or 0) > 0)
    readings["meter"].append(Reading("stopped_lanes", stopped, "state/.watchdog-worker.json",
                                     int(os.path.getmtime(os.path.join(STATE, ".watchdog-worker.json")))))
except (OSError, ValueError):
    readings["meter"].append(Reading("stopped_lanes", why="not configured"))

# --- one line per domain -----------------------------------------------------

lines = []
for domain in DOMAINS:
    wrong = [c["threshold"] for c in crossings if c["domain"] == domain]
    missing = [r.name for r in readings[domain] if r.value is None and r.why != "not configured" and r.name != "stopped_lanes"]
    unconfigured = [r.name for r in readings[domain] if r.value is None and r.why == "not configured" and r.name != "stopped_lanes"]
    if wrong:
        verdict = "WRONG: " + "; ".join(wrong)
    elif missing:
        verdict = "unmeasured: " + ", ".join(missing)
    elif unconfigured:
        verdict = "unmeasured (not configured): " + ", ".join(unconfigured)
    else:
        verdict = "inside thresholds"
    # Numbers that are unmeasured for one shared reason are named together, once.
    shown, grouped = [], {}
    for r in readings[domain]:
        if r.value is None:
            if r.why not in grouped:
                grouped[r.why] = []
                shown.append(grouped[r.why])
            grouped[r.why].append(r.name)
        else:
            shown.append(r.text())
    why_of = {id(names): why for why, names in grouped.items()}
    body = " ".join(s if isinstance(s, str) else "%s=unmeasured (%s)" % (",".join(s), why_of[id(s)] or "no reading") for s in shown)
    lines.append(one_line("%s | %s | %s" % (domain, body, verdict)))

if ACTION == "digest":
    for line in lines:
        print(line)
    sys.exit(0)


# --- interject ---------------------------------------------------------------

def append_status(line):
    try:
        os.makedirs(os.path.dirname(STATUS_FILE), exist_ok=True)
        with open(STATUS_FILE, "a") as handle:
            handle.write(one_line(line) + "\n")
        return True
    except OSError:
        print(one_line(line))
        return False


def page(text):
    command = cfg("PAGE_CMD")
    if not command:
        return
    try:
        subprocess.run(["sh", "-c", command, "fm-overlord", text], input=(text + "\n").encode(), timeout=5,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        pass


def steer(target, key, text):
    if not target:
        return "no lane configured"
    if not LANE_RE.match(target):
        return "lane name %r is not a task id" % target
    delivery = hashlib.sha256(("%s %s %s" % (key, target, iso(NOW)[:10])).encode()).hexdigest()[:16]
    env = dict(E, FM_HOME=E["OV_HOME"])
    try:
        done = subprocess.run([cfg("SEND_BIN"), target, "--fire-and-forget", delivery, one_line(text)],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=6, env=env)
    except (OSError, subprocess.TimeoutExpired) as error:
        return "the steer did not complete (%s)" % type(error).__name__
    if done.returncode != 0:
        tail = done.stdout.decode("utf-8", "replace").strip().splitlines()
        return "the steer was refused (%s)" % (tail[-1][:200] if tail else "exit %d" % done.returncode)
    return ""


deferred = False
remind = cfg_int("REMIND", 14400)
# Worst case for one interjection is a 5s page and a 6s steer; one always goes out.
last_start = CHECK_TIMEOUT - 4 - 11
interjected = 0
open_now = set()
for c in crossings:
    key = "overlord-" + c["key"]
    open_now.add(key)
    episode = episodes.get(key)
    if episode is not None:
        rose_again = (c.get("value") is not None and c["value"] > (episode.get("high") or 0)
                      and NOW - int(episode.get("last_at") or 0) >= remind)
        if not rose_again:
            continue
    if interjected and time.monotonic() - STARTED > last_start:
        deferred = True
        if episode is None:
            open_now.discard(key)
            for name in c.get("reads") or []:
                if previous.get(name) is None:
                    new_values.pop(name, None)
                else:
                    new_values[name] = previous[name]
        continue
    interjected += 1
    finding = "OVERLORD %s: %s; %s; source %s; age %s" % (
        c["domain"], c["threshold"], c["number"], c["source"] or "unknown", age(NOW - c["at"]) if c["at"] is not None else "unknown")
    owner = c["owner"] or "none configured"
    append_status("blocked [key=%s]: %s; owner %s; correction: %s" % (key, finding, owner, c["correction"]))
    page(finding)
    if c["fable"]:
        target = cfg("FABLE_LANE")
        ask = "an adjudication" if c.get("adjudicate") else "a review before anyone acts, because the correction is irreversible"
        failure = steer(target, key, "%s. This needs %s (owning lane: %s). %s" % (finding, ask, owner, c["correction"]))
        if failure and not target:
            failure = "no Fable lane is configured, so nothing was steered and the owning lane was not told to act"
    else:
        failure = steer(c["owner"], key, "%s. %s Anything destructive or irreversible this leads to needs a Fable review "
                                         "on the current head first." % (finding, c["correction"]))
    if failure:
        append_status("blocked [key=%s]: the correction was not delivered to a lane: %s. Route it by hand." % (key, failure))
    episodes[key] = {"opened_at": (episode or {}).get("opened_at", NOW), "last_at": NOW, "number": c["number"],
                     "threshold": c["threshold"], "baseline": c.get("baseline"), "high": c.get("value"),
                     "reads": c.get("reads") or []}
    record["episodes"] = episodes
    save_record(record)

measured = {"%s.%s" % (d, r.name): r.value for d in DOMAINS for r in readings[d]}
partial = {"%s.%s" % (d, r.name) for d in DOMAINS for r in readings[d] if r.partial}
for key in sorted(set(episodes) - open_now):
    reads = episodes[key].get("reads") or []
    if any(measured.get(name) is None or name in partial for name in reads):
        continue
    append_status("resolved [key=%s]: %s no longer holds at %s (interjected at %s)" % (
        key, episodes[key].get("threshold", "the threshold"), iso(NOW), episodes[key].get("number", "?")))
    del episodes[key]

record.update({"episodes": episodes, "readings": new_values, "unmeasured": {d: len(v) for d, v in unmeasured.items()},
               "lines": lines, "probed_at": NOW, "deferred": deferred})
save_record(record)
PY
}

case "${1:-check}" in
  check) run_engine check ;;
  digest) run_engine digest ;;
  status) run_engine status ;;
  adjudicate) shift; run_engine adjudicate "$@" ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help|help) usage ;;
  *) printf 'fm-overlord: unknown action %s (try --help)\n' "$1" >&2; exit 2 ;;
esac
