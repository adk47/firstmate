#!/usr/bin/env bash
# fm-sentry-watch.sh - the firstmate-owned Sentry watch for the musoai org.
#
# Usage:
#   fm-sentry-watch.sh [poll]     registered slow-poll check; silent unless it should wake
#   fm-sentry-watch.sh status     read-only local status (no network)
#   fm-sentry-watch.sh projects   list every Sentry project the API lists, with its effective state
#   fm-sentry-watch.sh migrate    import the retired per-lane Sentry baselines into the shared one
#   fm-sentry-watch.sh arm        write state/sentry-watch.check.sh and bind its bytes
#   fm-sentry-watch.sh disarm     remove the shim, its trust binding, the beat, and the rail record
#   fm-sentry-watch.sh --help     print this help
#
# This is the one firstmate-owned Sentry watch. It replaces the per-lane scratch
# checks (state/sentry-backend-watch-b1.check.sh, state/sentry-mobile-s1.check.sh)
# with a single registered check that covers EVERY project the Sentry API lists
# for the organization, rather than a hardcoded project tuple.
#
# WHY THIS EXISTS. On 2026-09-22 a fatal onboarding issue (CORE-BACKEND-11N)
# reached ten events with few users and never paged, because the only watch
# covered three projects and its rule paged only NEW issues at users>=3. That
# same watch was silently deleted earlier in the day and polling stopped with no
# alarm. Both failure shapes are addressed here: coverage is discovered from the
# API, sensitive routes page at a single user, and a missing or stalled check
# emits its own DARK wake instead of going quiet.
#
# RULES (per issue, first match wins; "live" means not retired, see signatures):
#   PAGE-NOW    an issue in page_any_delta with any new event (a known-fixed id
#               must page on a single recurrence).
#   REGRESSION  an issue whose substatus transitions into "regressed" (a resolved
#               issue re-firing), or a brand-new issue already marked regressed.
#   CRASH       a crash signature (fatal app hangs, watchdog terminations, native
#               aborts, NoSuchMethodError, NullPointerException) pages a NEW issue
#               once at any user count; after that the seen-issue rules apply.
#   CRITICAL    an infrastructure signature (OOM kills, memory exhaustion, SIGKILL,
#               connection-pool exhaustion) pages a NEW issue at any user count and
#               a seen issue on any new event, throttled to once per surfaced
#               window (surfaced_window_secs): it pages again only when that window
#               has rolled or a new user tier is crossed.
#   P0          a user tier: a NEW issue at users>=users_p0, and a seen issue only
#               when it crosses a new tier (users_p0, twice it, four times it), so
#               a chronic issue pages once per tier rather than every poll. Or a
#               burst: the window rate (delta divided by the hours since the
#               issue was last read) reaches burst_min_events per cadence on a
#               path whose prior rate was below burst_baseline_per_hour, so a
#               long gap never turns a chronic trickle into a burst. An issue
#               with no recorded rate yet (its first read, or a legacy import)
#               earns one from its first two reads before the rule applies. A
#               NEW issue is a burst only when its firstSeen falls inside the
#               window, never on its lifetime count. The window runs from the
#               last poll that actually read the project.
#   P1          level error/fatal on a live path, at users>=users_p1_sensitive when
#               the path matches the sensitive routes (onboarding, signup, auth,
#               login, billing, checkout, payment, claim, credits) and users>=users_p1
#               elsewhere.
# Noise signatures silence an issue entirely. Transport signatures never trigger
# the users-based P0 or P1; they page only through the burst rule, at the raised
# floor burst_min_events_transport, because the 2026-09-22 fleet-wide request
# reset arrived AS "socket hang up". Retired data paths are recorded and never
# wake. Every threshold and every signature lives in config/sentry-watch.json
# (local, gitignored); docs/configuration.md owns that schema.
#
# EVERY FINDING PAGES. Each finding prints on its own line, so a multi-issue
# incident is never cut down to the first few, and an issue is recorded as
# surfaced only because its line was printed.
#
# THREE STATES, NEVER SILENT ON ERROR. A poll either fires, stays silent, or
# reports could-not-determine. A project whose issues cannot be read is reported
# as could-not-determine, and one unreadable project never stops the others. A
# poll that cannot enumerate projects at all reports could-not-determine too.
# A could-not-determine condition (a project, the project list, or a config
# problem) is reported when it appears, reminded hourly while it persists, and
# reported once more as recovered when it clears, so a persistent condition is
# never a wake on every poll. A project that leaves the enumerated set (removed
# from the org or denylisted) is reported once as removed from watch, never as
# recovered.
#
# LIVENESS. A poll that read at least one project writes state/.sentry-watch.beat,
# and the baseline records a last_read time per project, written only when that
# project was actually fetched, so the beat and every burst window derive from
# real reads rather than from the poll having run. A poll emits a DARK wake
# when the recorded beat is older than three times the cadence, when the check
# shim or its trust binding is missing, when the trust binding no longer covers
# the shim's bytes, or when no beat was ever recorded. A never-restored deletion
# cannot be seen by a check that is not running, so
# bin/fm-wake-drain.sh also prints a SENTRY WATCH DARK line when the armed marker
# state/.sentry-watch.armed is present and the shim, trust, or beat is missing or
# stale. That marker is written by `arm` and removed by `disarm`.
#
# RAIL CROSS-CHECK. Every rail.every_polls-th poll (default 6, about half an
# hour) lists the CTO Sentry rail's PRs (branches under the configured prefix,
# plus any PR body naming a fixed Sentry id) and reports an id the rail fixed
# that this watch never surfaced as RAIL-ONLY with the PR URL, so the two systems
# never disagree silently. The rail read has its own 5s budget, reserved out of
# the poll budget before the project loop, so project reads can never starve
# it. The first rail read seeds its known set instead of reporting history; a
# gh outage is reported once on the ok->down transition as RAILCHECK-DARK.
#
# MIGRATION AND PER-PROJECT BASELINE. `poll` imports the retired per-lane
# baselines automatically when the shared baseline is absent, and `migrate` does
# the same explicitly. The baseline is per project: a project already covered by
# imported or recorded issues classifies at once and only its unknown issues
# page, while a project the watch has never read records its estate on its first
# read and wakes nobody, then classifies from its second read. One imported
# legacy file therefore never makes the arming poll announce projects it did
# not cover.
#
# READ-ONLY AND BOUNDED. The watch only reads Sentry and GitHub. It makes no
# model calls, prints no token, and passes no token on any command line: the
# token is read from the vault path by the interpreter only. A whole poll is
# bounded by FM_SENTRY_WATCH_BUDGET_SECS (default 20), shared fairly: each
# project's read gets that budget divided by the project count (at least 2s,
# never more than FM_SENTRY_WATCH_HTTP_TIMEOUT, default 5), and the read order
# rotates round-robin each poll starting after the last project read, so a slow
# host starves no fixed tail and every project is read within a bounded number
# of polls. A project left unread for three consecutive polls is reported as
# could-not-determine. The poll ends inside the watcher's own FM_CHECK_TIMEOUT
# rather than being killed with nothing printed.
#
# Test seams: FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, FM_SENTRY_WATCH_NOW,
# FM_SENTRY_WATCH_FIXTURES (stubbed Sentry and rail responses), FM_SENTRY_WATCH_VAULT,
# FM_SENTRY_WATCH_GH, FM_SENTRY_WATCH_CADENCE, and FM_SENTRY_WATCH_LEGACY.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/sentry-watch.json"
CHECK_ID=sentry-watch
RECORD="$STATE/sentry-watch.baseline.json"
BEAT="$STATE/.sentry-watch.beat"
RAIL_STATE="$STATE/.sentry-watch.rail.json"
ARMED="$STATE/.sentry-watch.armed"
SHIM="$STATE/sentry-watch.check.sh"
TRUST="$STATE/sentry-watch.check-trust"
VAULT="${FM_SENTRY_WATCH_VAULT:-$HOME/.config/muso/sentry-vault.json}"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
MAX_LINE=1000
# The watcher runs a check under its own FM_CHECK_TIMEOUT; the poll budget is a
# few seconds inside that so a slow host still prints its line.
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;; esac

# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-sentry-watch.sh [poll]     run the registered check (silent unless it should wake)
  fm-sentry-watch.sh status     read-only local status; no network call
  fm-sentry-watch.sh projects   list every Sentry project the API lists and its effective state
  fm-sentry-watch.sh migrate    import the retired per-lane baselines into the shared one
  fm-sentry-watch.sh arm        write and register state/sentry-watch.check.sh
  fm-sentry-watch.sh disarm     remove the shim, trust binding, beat, and rail record
  fm-sentry-watch.sh --help     print this help

Rules, thresholds, and signatures are read from config/sentry-watch.json (local,
gitignored). See docs/configuration.md for the schema and
docs/examples/sentry-watch.json for a starting point.
EOF
}

die_usage() {
  printf 'fm-sentry-watch: %s\n' "$1" >&2
  usage >&2
  exit 2
}

# The whole engine runs in one interpreter, so every input crosses as an
# environment variable and nothing the watch needs is ever an argv token.
run_engine() {  # <action>
  local action=$1 registered
  # Only the shell owns the trust-binding check, so the poll's DARK alarm is
  # handed the verdict: it must tell an intact registration from a check file
  # whose bytes no longer match its binding.
  if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
    registered=1
  else
    registered=0
  fi
  FM_SENTRY_WATCH_ACTION="$action" \
  FM_SENTRY_WATCH_STATE="$STATE" \
  FM_SENTRY_WATCH_CONFIG="$CONFIG" \
  FM_SENTRY_WATCH_VAULT="$VAULT" \
  FM_SENTRY_WATCH_BEAT="$BEAT" \
  FM_SENTRY_WATCH_RECORD="$RECORD" \
  FM_SENTRY_WATCH_RAIL_STATE="$RAIL_STATE" \
  FM_SENTRY_WATCH_ARMED="$ARMED" \
  FM_SENTRY_WATCH_SHIM="$SHIM" \
  FM_SENTRY_WATCH_TRUST="$TRUST" \
  FM_SENTRY_WATCH_CADENCE="${FM_SENTRY_WATCH_CADENCE:-}" \
  FM_SENTRY_WATCH_NOW="${FM_SENTRY_WATCH_NOW:-}" \
  FM_SENTRY_WATCH_FIXTURES="${FM_SENTRY_WATCH_FIXTURES:-}" \
  FM_SENTRY_WATCH_GH="${FM_SENTRY_WATCH_GH:-gh}" \
  FM_SENTRY_WATCH_ORG="${FM_SENTRY_WATCH_ORG:-}" \
  FM_SENTRY_WATCH_HOST="${FM_SENTRY_WATCH_HOST:-}" \
  FM_SENTRY_WATCH_BUDGET_SECS="${FM_SENTRY_WATCH_BUDGET_SECS:-20}" \
  FM_SENTRY_WATCH_HTTP_TIMEOUT="${FM_SENTRY_WATCH_HTTP_TIMEOUT:-5}" \
  FM_SENTRY_WATCH_LEGACY="${FM_SENTRY_WATCH_LEGACY:-}" \
  FM_SENTRY_WATCH_REGISTERED="$registered" \
  python3 - <<'PY'
import datetime
import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

SCHEMA = "fm-sentry-watch-v1"
RAIL_SCHEMA = "fm-sentry-watch-rail-v1"


def env(name, default=""):
    value = os.environ.get(name)
    return default if value is None or value == "" else value


def env_int(name, default):
    raw = env(name, "")
    try:
        return int(raw)
    except (TypeError, ValueError):
        return default


def env_float(name, default):
    raw = env(name, "")
    try:
        return float(raw)
    except (TypeError, ValueError):
        return default


ACTION = env("FM_SENTRY_WATCH_ACTION", "poll")
STATE = Path(env("FM_SENTRY_WATCH_STATE"))
CONFIG = Path(env("FM_SENTRY_WATCH_CONFIG"))
VAULT = Path(env("FM_SENTRY_WATCH_VAULT"))
BEAT = Path(env("FM_SENTRY_WATCH_BEAT"))
RECORD = Path(env("FM_SENTRY_WATCH_RECORD"))
RAIL_STATE = Path(env("FM_SENTRY_WATCH_RAIL_STATE"))
ARMED = Path(env("FM_SENTRY_WATCH_ARMED"))
SHIM = Path(env("FM_SENTRY_WATCH_SHIM"))
TRUST = Path(env("FM_SENTRY_WATCH_TRUST"))
FIXTURES = env("FM_SENTRY_WATCH_FIXTURES")
GH = env("FM_SENTRY_WATCH_GH", "gh")
BUDGET_SECS = env_int("FM_SENTRY_WATCH_BUDGET_SECS", 20)
HTTP_TIMEOUT = env_float("FM_SENTRY_WATCH_HTTP_TIMEOUT", 5.0)
CADENCE = env_int("FM_SENTRY_WATCH_CADENCE", 0)
DARK_FACTOR = 3

DEFAULT_SIGNATURES = {
    "sensitive": (
        r"onboard|signup|sign-up|register|auth|login|logout|session|password|token|claim|"
        r"/user|account|member|invite|permission|role|"
        r"billing|checkout|payment|stripe|invoice|subscription|purchase|refund|payout|wallet|credit"
    ),
    "noise": (
        r"Network request failed|NetworkError|Failed to fetch|ECONNABORTED|"
        r"TLS error|handshake|Invalid statusCode:\s*404|NSURLErrorDomain|"
        r"Internet connection appears to be offline|not connected to the internet|"
        r"cannot enqueue|Load failed|net::ERR_|Navigation cancelled|"
        r"UnhandledRejection: Non-Error promise rejection|Non-Error promise rejection|"
        r"wp-admin|wp-login|wp-content|xmlrpc|admin-ajax|phpmyadmin|"
        r"/\.env|/\.git/|/cgi-bin|eval-stdin|/vendor/phpunit|"
        r"StoreKit|N\+1 API Call|Can't assign requested address|"
        r"Software caused connection abort|UNErrorDomain|Notifications are not allowed"
    ),
    "transport": (
        r"socket hang up|ECONNRESET|EPERM|ETIMEDOUT|ENOTFOUND|EAI_AGAIN|"
        r"timeout of \d+ms exceeded|aborted|Client network socket disconnected|"
        r"other side closed|socket closed|HandshakeException|Broken pipe"
    ),
    "retired": (
        r"/api/m/v2|athena|Run_Calculate_Industry|Run_Industry_Orchestrator|"
        r"Run_Scheduled_Calculations|industry_calculations"
    ),
    "crash": (
        r"Fatal App Hang|WatchdogTermination|EXC_|SIGABRT|NoSuchMethodError|"
        r"NullPointerException"
    ),
    "critical": (
        r"OOMKilled|out of memory|ENOMEM|Cannot allocate memory|"
        r"SIGKILL|too many clients|remaining connection slots|pool exhausted|"
        r"SequelizeConnectionError|SequelizeConnectionAcquireTimeoutError|"
        r"PROTOCOL_CONNECTION_LOST|Connection terminated unexpectedly"
    ),
}
RAIL_BUDGET_SECS = 5
DEFAULT_RAIL = {
    "enabled": True,
    "every_polls": 6,
    "repos": ["Muso-AI/core-backend"],
    "branch_prefix": "cto/sentry",
    "id_prefixes": ["CORE-BACKEND"],
}
PROJECT_DEFAULTS = {
    "live": True,
    "sensitive": False,
    "sensitive_routes": "",
    "live_routes": "",
    "users_p1_sensitive": 1,
    "users_p1": 3,
    "users_p0": 25,
    "burst_min_events": 10,
    "burst_min_events_transport": 25,
    "burst_baseline_per_hour": 2,
}
DEFAULTS = {
    "cadence_secs": 300,
    "retention_secs": 7 * 24 * 3600,
    "surfaced_window_secs": 3600,
    "denylist": [],
    "page_any_delta": [],
    "signatures": dict(DEFAULT_SIGNATURES),
    "projects": {},
    "rail": dict(DEFAULT_RAIL),
}


def now_epoch():
    raw = env("FM_SENTRY_WATCH_NOW", "")
    if raw.isdigit():
        return int(raw)
    return int(time.time())


def read_json(path):
    try:
        return json.loads(Path(path).read_text())
    except Exception:
        return None


def write_json_atomic(path, obj):
    path = Path(path)
    tmp = path.with_name(path.name + ".tmp")
    try:
        tmp.write_text(json.dumps(obj, separators=(",", ":")))
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
        return True
    except OSError:
        try:
            tmp.unlink()
        except OSError:
            pass
        return False


def read_int(path):
    try:
        value = Path(path).read_text().strip()
    except OSError:
        return None
    return int(value) if value.isdigit() else None


def compile_re(pattern, label, problems):
    if not pattern:
        return None
    try:
        return re.compile(pattern, re.I)
    except re.error as exc:
        problems.append("%s is not a usable regular expression: %s" % (label, exc))
        return None


def load_config():
    """Return (config, problems). The config is always complete: built-in
    defaults fill anything absent, so a missing or broken local file degrades to
    defaults instead of stopping the watch."""
    config = {
        "cadence_secs": DEFAULTS["cadence_secs"],
        "retention_secs": DEFAULTS["retention_secs"],
        "surfaced_window_secs": DEFAULTS["surfaced_window_secs"],
        "denylist": list(DEFAULTS["denylist"]),
        "page_any_delta": list(DEFAULTS["page_any_delta"]),
        "signatures": dict(DEFAULT_SIGNATURES),
        "projects": {},
        "rail": dict(DEFAULT_RAIL),
        "org": "",
    }
    problems = []
    raw = read_json(CONFIG)
    if not CONFIG.is_file():
        return config, problems
    if not isinstance(raw, dict):
        problems.append("config is not a JSON object: %s" % CONFIG)
        return config, problems
    for key in ("cadence_secs", "retention_secs", "surfaced_window_secs"):
        if key in raw:
            try:
                config[key] = int(raw[key])
            except (TypeError, ValueError):
                problems.append("config %s must be a whole number" % key)
    for key in ("denylist", "page_any_delta"):
        if key in raw:
            value = raw[key]
            if isinstance(value, list) and all(isinstance(v, str) for v in value):
                config[key] = list(value)
            else:
                problems.append("config %s must be an array of strings" % key)
    if isinstance(raw.get("signatures"), dict):
        for key, value in raw["signatures"].items():
            if key not in DEFAULT_SIGNATURES:
                problems.append("config signatures.%s is not a known signature" % key)
                continue
            if isinstance(value, str):
                config["signatures"][key] = value
            else:
                problems.append("config signatures.%s must be a string" % key)
    if isinstance(raw.get("projects"), dict):
        for slug, entry in raw["projects"].items():
            if not isinstance(entry, dict):
                problems.append("config projects.%s must be an object" % slug)
                continue
            merged = dict(PROJECT_DEFAULTS)
            for key, value in entry.items():
                if key not in PROJECT_DEFAULTS:
                    problems.append("config projects.%s.%s is not a known key" % (slug, key))
                    continue
                merged[key] = value
            config["projects"][slug] = merged
    if isinstance(raw.get("rail"), dict):
        rail = dict(DEFAULT_RAIL)
        for key, value in raw["rail"].items():
            if key not in DEFAULT_RAIL:
                problems.append("config rail.%s is not a known key" % key)
                continue
            rail[key] = value
        config["rail"] = rail
    if isinstance(raw.get("org"), str):
        config["org"] = raw["org"]
    # A signature that is not a usable regular expression silently disables the
    # rule it carries, so it is reported rather than left to fail quietly.
    for key, pattern in config["signatures"].items():
        if pattern:
            try:
                re.compile(pattern, re.I)
            except re.error as exc:
                problems.append("config signatures.%s is not a usable regular expression: %s" % (key, exc))
    for slug, entry in config["projects"].items():
        for key in ("live_routes", "sensitive_routes"):
            pattern = entry.get(key) or ""
            if pattern:
                try:
                    re.compile(pattern, re.I)
                except re.error as exc:
                    problems.append("config projects.%s.%s is not a usable regular expression: %s" % (slug, key, exc))
    return config, problems


def project_settings(config, slug):
    settings = dict(PROJECT_DEFAULTS)
    settings.update(config["projects"].get(slug, {}))
    return settings


def resolve_credentials(config, problems):
    org = env("FM_SENTRY_WATCH_ORG", "") or config.get("org") or ""
    host = env("FM_SENTRY_WATCH_HOST", "")
    token = ""
    if not FIXTURES:
        data = read_json(VAULT)
        if not isinstance(data, dict) or not isinstance(data.get("data"), dict):
            problems.append("Sentry vault is unreadable: %s" % VAULT)
        else:
            vault = data["data"]
            org = org or vault.get("org") or "musoai"
            host = host or vault.get("host") or "sentry.io"
            token = vault.get("auth_token") or ""
            if not token:
                problems.append("Sentry vault has no auth_token")
    org = org or "musoai"
    host = host or "sentry.io"
    return org, host, token


# --- fetch layer ------------------------------------------------------------

class FetchError(Exception):
    pass


def http_get(url, token, timeout=None):
    request = urllib.request.Request(url, headers={"Authorization": "Bearer %s" % token})
    try:
        with urllib.request.urlopen(request, timeout=timeout or HTTP_TIMEOUT) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as exc:
        raise FetchError("HTTP %s" % exc.code)
    except urllib.error.URLError as exc:
        raise FetchError("network error: %s" % (exc.reason,))
    except (ValueError, OSError) as exc:
        raise FetchError("unreadable response: %s" % exc)


def fetch_projects(org, host, token):
    if FIXTURES:
        data = read_json(Path(FIXTURES) / "projects.json")
        if data is None:
            raise FetchError("fixture projects.json is missing or unreadable")
        return data
    url = "https://%s/api/0/organizations/%s/projects/?per_page=100" % (host, org)
    data = http_get(url, token)
    if not isinstance(data, list):
        raise FetchError("projects response was not a list")
    return data


def fetch_issues(org, host, token, slug, timeout=None):
    if FIXTURES:
        data = read_json(Path(FIXTURES) / ("issues-%s.json" % slug))
        if data is None:
            raise FetchError("fixture issues-%s.json is missing or unreadable" % slug)
        if isinstance(data, dict):
            time.sleep(float(data.get("sleep") or 0))
            data = data.get("issues", [])
        return data
    query = urllib.parse.urlencode({
        "query": "is:unresolved lastSeen:-2d !environment:development",
        "limit": "50",
        "sort": "date",
    })
    url = "https://%s/api/0/projects/%s/%s/issues/?%s" % (host, org, slug, query)
    data = http_get(url, token, timeout)
    if not isinstance(data, list):
        raise FetchError("issues response was not a list")
    return data


def run_gh(args, timeout):
    try:
        proc = subprocess.run(
            [GH] + args, capture_output=True, text=True, timeout=timeout,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise FetchError("gh unavailable: %s" % exc)
    if proc.returncode != 0:
        detail = (proc.stderr or "").strip().splitlines()
        raise FetchError("gh failed: %s" % (detail[0] if detail else "rc=%s" % proc.returncode))
    try:
        return json.loads(proc.stdout or "null")
    except ValueError:
        raise FetchError("gh returned unreadable JSON")


def fetch_rail(rail_config, deadline):
    """Return (prs, error). prs is a list of {url, headRefName, body}."""
    if FIXTURES:
        data = read_json(Path(FIXTURES) / "rail.json")
        if data is None:
            return [], "rail fixture is missing or unreadable"
        if isinstance(data, dict) and data.get("error"):
            return [], str(data["error"])
        if isinstance(data, dict):
            data = data.get("prs", [])
        if not isinstance(data, list):
            return [], "rail fixture is not a list of pull requests"
        return data, ""
    if not rail_config.get("enabled", True):
        return [], ""
    prs = []
    repos = rail_config.get("repos") or []
    prefix = rail_config.get("branch_prefix") or "cto/sentry"
    for repo in repos:
        if time.time() >= deadline:
            return prs, "time budget ran out before every rail repository was read"
        try:
            found = run_gh([
                "pr", "list", "--repo", repo, "--state", "all",
                "--search", "head:%s" % prefix,
                "--json", "number,url,headRefName,body,state", "--limit", "100",
            ], timeout=min(12.0, max(1.0, deadline - time.time())))
        except FetchError as exc:
            return prs, str(exc)
        if isinstance(found, list):
            prs.extend(found)
    owner = (repos[0].split("/")[0] if repos and "/" in repos[0] else "")
    for id_prefix in rail_config.get("id_prefixes") or []:
        if not owner:
            break
        if time.time() >= deadline:
            return prs, "time budget ran out before every rail fix search ran"
        try:
            found = run_gh([
                "api", "-X", "GET", "search/issues",
                "-f", 'q=org:%s "Fixes %s-" in:body type:pr' % (owner, id_prefix),
                "-f", "per_page=100",
            ], timeout=min(12.0, max(1.0, deadline - time.time())))
        except FetchError as exc:
            return prs, str(exc)
        items = found.get("items", []) if isinstance(found, dict) else []
        for item in items:
            if not isinstance(item, dict):
                continue
            prs.append({
                "url": item.get("html_url") or "",
                "headRefName": "",
                "body": item.get("body") or "",
            })
    return prs, ""


def rail_ids(prs, rail_config):
    """Map Sentry id -> pull-request URL for every id the rail named.

    A branch is matched by locating the configured prefix fragment (core-backend
    for CORE-BACKEND) and reading the short id that follows it, because the
    surrounding words (cto/sentry-core-backend-...) would otherwise swallow the
    first dash and split the id."""
    prefixes = [p.upper() for p in (rail_config.get("id_prefixes") or [])]
    body_re = re.compile(r"\b([A-Z][A-Z0-9]*(?:-[A-Z0-9]+)+)\b")
    result = {}

    def keep(candidate):
        upper = candidate.upper()
        return any(upper.startswith(prefix + "-") for prefix in prefixes)

    def branch_candidates(head):
        found = set()
        low = head.lower()
        for prefix in prefixes:
            pattern = re.escape(prefix.lower()) + r"[-_]([a-z0-9]{2,})"
            for match in re.finditer(pattern, low):
                found.add("%s-%s" % (prefix, match.group(1).upper()))
        return found

    for pr in prs:
        if not isinstance(pr, dict):
            continue
        url = pr.get("url") or ""
        if not url:
            continue
        found = branch_candidates(pr.get("headRefName") or "")
        for candidate in body_re.findall(pr.get("body") or ""):
            if keep(candidate):
                found.add(candidate.upper())
        for candidate in found:
            result.setdefault(candidate, url)
    return result


# --- liveness ---------------------------------------------------------------

def liveness_findings(now, cadence):
    findings = []
    shim_present = SHIM.is_file()
    trust_present = TRUST.is_file()
    if not shim_present:
        findings.append("DARK check file missing: %s" % SHIM)
    if not trust_present:
        findings.append("DARK trust binding missing: %s" % TRUST)
    # A task's own PR poll writes state/<task>.check.sh, so a check named after
    # its task can be overwritten or deleted by that poll. This watch lives at a
    # path no task poll derives, and this is the alarm for the same class
    # reaching it anyway: an in-place overwrite leaves both files present but the
    # trust binding no longer covers the shim's bytes.
    if shim_present and trust_present and env("FM_SENTRY_WATCH_REGISTERED", "") != "1":
        findings.append("DARK the trust binding does not cover the current check bytes")
    if read_int(BEAT) is None:
        findings.append("DARK no beat recorded")
    return findings


# --- rule engine ------------------------------------------------------------

def issue_entry(issue, now):
    return {
        "shortId": issue.get("shortId") or issue.get("id") or "",
        "users": issue.get("userCount") or 0,
        "count": _as_int(issue.get("count")),
        "title": (issue.get("title") or "")[:160],
        "culprit": (issue.get("culprit") or "")[:160],
        "permalink": issue.get("permalink") or "",
        "level": (issue.get("level") or "").lower(),
        "substatus": (issue.get("substatus") or "") or "",
        "first_seen": parse_iso(issue.get("firstSeen")),
        "ts": now,
    }


def _as_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def parse_iso(value):
    """Sentry's firstSeen as epoch seconds, or None when it is unreadable."""
    if not isinstance(value, str) or not value.strip():
        return None
    text = re.sub(r"\.\d+", "", value.strip())
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=datetime.timezone.utc)
    return int(parsed.timestamp())


def user_tier(users, settings):
    """The highest P0 user tier reached: users_p0, twice it, or four times it;
    0 below the first."""
    base = _as_int(settings.get("users_p0")) or 0
    tier = 0
    if base > 0:
        for factor in (1, 2, 4):
            if users >= base * factor:
                tier = base * factor
    return tier


def classify(entry, old, settings, signatures, config, window_start, now, cadence):
    """Return a finding line, or None. `old` is the prior baseline entry."""
    blob = "%s %s" % (entry["title"], entry["culprit"])
    if signatures["retired"] and signatures["retired"].search(blob):
        return None
    if signatures["noise"] and signatures["noise"].search(blob):
        return None
    live = bool(settings.get("live", True))
    if live and settings.get("live_routes"):
        pattern = compile_re(settings["live_routes"], "live_routes", [])
        if pattern is not None and not pattern.search(blob):
            live = False
    level = entry["level"]
    transport = bool(signatures["transport"] and signatures["transport"].search(blob))
    crash = bool(signatures["crash"] and signatures["crash"].search(blob))
    critical = bool(signatures["critical"] and signatures["critical"].search(blob))
    burst_floor = settings["burst_min_events_transport"] if transport else settings["burst_min_events"]
    sensitive = bool(settings.get("sensitive"))
    if not sensitive and signatures["sensitive"] and signatures["sensitive"].search(blob):
        sensitive = True
    if not sensitive and settings.get("sensitive_routes"):
        pattern = compile_re(settings["sensitive_routes"], "sensitive_routes", [])
        if pattern is not None and pattern.search(blob):
            sensitive = True

    sid = entry.get("shortId") or ""
    users = entry["users"]
    count = entry["count"] or 0
    permalink = entry["permalink"]
    culprit = entry["culprit"] or entry["title"]

    page_now = sid in config["page_any_delta"]
    old_count = old.get("count") if isinstance(old, dict) else None
    delta = 0
    if isinstance(old, dict):
        prev = _as_int(old.get("count"))
        if prev is not None:
            delta = max(0, count - prev)
    prev_rate = None
    if isinstance(old, dict) and old.get("rate") is not None:
        try:
            prev_rate = float(old.get("rate"))
        except (TypeError, ValueError):
            prev_rate = None
    window_hours = 0.0
    if isinstance(old, dict) and _as_int(old.get("ts")) is not None:
        window_hours = max(1, now - _as_int(old.get("ts"))) / 3600.0
    window_rate = delta / window_hours if window_hours > 0 else 0.0
    floor_rate = burst_floor * 3600.0 / max(1, cadence)

    def finding(kind, rule, extra=""):
        parts = [
            "%s %s" % (kind, sid),
            "users=%s" % users,
            "count=%s" % count,
        ]
        if isinstance(old, dict):
            parts.append("delta=%s" % delta)
        if extra:
            parts.append(extra)
        parts.append("culprit=%s" % culprit)
        parts.append("permalink=%s" % permalink)
        parts.append("rule=%s" % rule)
        return " ".join(parts)

    if page_now and (old is None or delta >= 1):
        return finding("PAGE-NOW", "page-any-delta")

    if old is None:
        if entry["substatus"] == "regressed":
            return finding("REGRESSION", "regressed")
        if crash:
            return finding("CRASH", "crash-signature")
        if critical:
            return finding("CRITICAL", "critical-signature")
        if users >= settings["users_p0"] and not transport:
            return finding("P0", "users>=%s" % settings["users_p0"])
        first_seen = entry.get("first_seen")
        if first_seen is not None and first_seen >= window_start \
                and count >= burst_floor and level in ("error", "fatal") and live:
            return finding("P0", "burst>=%s" % burst_floor)
        if level in ("error", "fatal") and live and not transport:
            if sensitive and users >= settings["users_p1_sensitive"]:
                return finding("P1", "sensitive users>=%s" % settings["users_p1_sensitive"])
            if users >= settings["users_p1"]:
                return finding("P1", "users>=%s" % settings["users_p1"])
        return None

    old_substatus = old.get("substatus") if isinstance(old, dict) else ""
    if entry["substatus"] == "regressed" and old_substatus != "regressed":
        return finding("REGRESSION", "regressed")
    if prev_rate is not None and window_rate >= floor_rate \
            and prev_rate < settings["burst_baseline_per_hour"] \
            and level in ("error", "fatal") and live:
        return finding("P0", "burst>=%s/window prior<%.0f/h" % (
            burst_floor, settings["burst_baseline_per_hour"]))
    tier = user_tier(users, settings)
    new_tier = bool(tier) and tier > user_tier(_as_int(old.get("users")) or 0, settings)
    if critical and delta >= 1:
        surfaced = _as_int(old.get("surfaced")) or 0
        if not surfaced or now - surfaced >= config["surfaced_window_secs"] or new_tier:
            return finding("CRITICAL", "critical-signature")
    if new_tier and live and not transport:
        return finding("P0", "users>=%s" % tier)
    return None


def project_rate(entry, old, now):
    """The issue's event rate in events/hour as of this poll, or None until a
    prior read exists to measure it against."""
    if not isinstance(old, dict):
        return None
    prev_count = _as_int(old.get("count"))
    if prev_count is None:
        return None
    try:
        elapsed = max(1, now - int(old.get("ts") or now))
    except (TypeError, ValueError):
        elapsed = 1
    delta = max(0, (entry["count"] or 0) - prev_count)
    return delta * 3600.0 / elapsed


# --- baseline ---------------------------------------------------------------

def read_baseline():
    data = read_json(RECORD)
    if not isinstance(data, dict) or data.get("schema") != SCHEMA:
        return {}
    issues = data.get("issues")
    return issues if isinstance(issues, dict) else {}


def legacy_paths():
    raw = env("FM_SENTRY_WATCH_LEGACY", "")
    if raw:
        return [Path(p) for p in raw.split()]
    return [
        STATE / "sentry-backend-watch-b1.last.json",
        STATE / "sentry-mobile-s1.last.json",
    ]


def import_legacy(issues):
    """Merge the retired per-lane baselines into `issues`, never overwriting a
    newer shared entry. Returns (imported, files_read)."""
    imported = 0
    files_read = 0
    for path in legacy_paths():
        data = read_json(path)
        if not isinstance(data, dict):
            continue
        files_read += 1
        for sid, entry in data.items():
            if not isinstance(entry, dict) or sid in issues:
                continue
            entry = dict(entry)
            entry.pop("rate", None)
            issues[sid] = entry
            imported += 1
    return imported, files_read


REMIND_SECS = 3600
UNREAD_POLLS = 3


def project_seen(slug, issues, last_read):
    """Whether the watch already holds a baseline for this project: it has read
    the project before, or an imported legacy baseline carries its issues (a
    Sentry short id is the project slug upper-cased plus a suffix)."""
    if slug in last_read:
        return True
    prefix = slug.upper() + "-"
    for sid, entry in issues.items():
        if not isinstance(entry, dict):
            continue
        if entry.get("project") == slug or str(sid).upper().startswith(prefix):
            return True
    return False


def condition_findings(prior, current, now):
    """Report each condition (a could-not-determine or a DARK beat) when it
    appears, remind hourly while it persists, and report it once more when it
    clears. Returns (lines, conditions-to-record)."""
    lines = []
    kept = {}
    for key, message in current.items():
        record = prior.get(key) if isinstance(prior.get(key), dict) else None
        if record is None:
            lines.append(message)
            kept[key] = {"since": now, "reported": now, "message": message}
            continue
        since = _as_int(record.get("since"))
        reported = _as_int(record.get("reported"))
        since = now if since is None else since
        reported = now if reported is None else reported
        if now - reported >= REMIND_SECS:
            lines.append("%s (persisting %ss)" % (message, now - since))
            reported = now
        kept[key] = {"since": since, "reported": reported, "message": message}
    for key in sorted(set(prior) - set(current)):
        lines.append("recovered %s" % key)
    return lines, kept


def prune_issues(issues, now, retention):
    kept = {}
    for sid, entry in issues.items():
        if not isinstance(entry, dict):
            continue
        try:
            age = now - float(entry.get("ts", now))
        except (TypeError, ValueError):
            age = 0.0
        if age <= retention:
            kept[sid] = entry
    return kept


# --- actions ----------------------------------------------------------------

def action_projects(config, org, host, token, problems):
    try:
        projects = fetch_projects(org, host, token)
    except FetchError as exc:
        print("sentry-watch: could-not-determine projects: %s" % exc)
        return
    deny = set(config["denylist"])
    for project in sorted(projects, key=lambda p: p.get("slug") or ""):
        if not isinstance(project, dict):
            continue
        slug = project.get("slug") or ""
        if not slug:
            continue
        if slug in deny:
            state = "disabled"
            reason = "denylisted"
        else:
            state = "enabled"
            reason = "api"
        print("%s\t%s\t%s" % (slug, state, reason))


def action_status(config, problems):
    now = now_epoch()
    cadence = CADENCE or config["cadence_secs"]
    print("sentry-watch status")
    print("config: %s (%s)" % (CONFIG, "present" if CONFIG.is_file() else "absent, built-in defaults"))
    print("cadence: %ss dark-after: %ss" % (cadence, DARK_FACTOR * cadence))
    beat = read_int(BEAT)
    if beat is None:
        print("beat: missing")
    else:
        print("beat: %ss ago (%s)" % (now - beat, beat))
    print("check shim: %s" % ("present" if SHIM.is_file() else "MISSING"))
    print("trust binding: %s" % ("present" if TRUST.is_file() else "MISSING"))
    print("armed marker: %s" % ("present" if ARMED.is_file() else "absent"))
    issues = read_baseline()
    print("baseline: %s issues" % len(issues))
    stored = read_json(RECORD)
    last_read = stored.get("last_read") if isinstance(stored, dict) else None
    reads = [v for v in (last_read or {}).values() if _as_int(v) is not None] \
        if isinstance(last_read, dict) else []
    if reads:
        print("last read: %s projects, oldest %ss ago" % (len(reads), now - min(int(v) for v in reads)))
    else:
        print("last read: no project read yet")
    rail = read_json(RAIL_STATE)
    if isinstance(rail, dict):
        print("rail: %s known=%s reported=%s" % (
            "ok" if rail.get("ok") else "down",
            len(rail.get("known") or []), len(rail.get("reported") or [])))
    else:
        print("rail: no record")
    if not SHIM.is_file() or not TRUST.is_file() or beat is None:
        print("DARK: the check is not armed, is unbound, or has no beat")
    elif env("FM_SENTRY_WATCH_REGISTERED", "") != "1":
        print("DARK: the trust binding does not cover the current check bytes")
    elif cadence > 0 and now - beat >= DARK_FACTOR * cadence:
        print("DARK: beat is %ss old (>= %ss)" % (now - beat, DARK_FACTOR * cadence))
    else:
        print("live: OK")
    for problem in problems:
        print("config problem: %s" % problem)


def action_migrate():
    issues = read_baseline()
    before = len(issues)
    imported, files_read = import_legacy(issues)
    if files_read == 0:
        print("sentry-watch: no legacy baselines found")
        return
    payload = {
        "schema": SCHEMA,
        "updated": now_epoch(),
        "legacy_imported": imported,
        "issues": issues,
    }
    if not write_json_atomic(RECORD, payload):
        print("sentry-watch: could-not-determine baseline write failed: %s" % RECORD)
        return
    print("sentry-watch: imported %s issues from %s legacy files (baseline %s -> %s)" % (
        imported, files_read, before, len(issues)))


def action_poll(config, org, host, token, problems):
    now = now_epoch()
    cadence = CADENCE or config["cadence_secs"]
    rail_config = config["rail"]
    rail_state = read_json(RAIL_STATE)
    if not isinstance(rail_state, dict) or rail_state.get("schema") != RAIL_SCHEMA:
        rail_state = {"schema": RAIL_SCHEMA, "ok": True, "seeded": False,
                      "known": [], "reported": [], "polls": 0}
    rail_every = max(1, _as_int(rail_config.get("every_polls")) or 1)
    rail_due = bool(rail_config.get("enabled", True)) \
        and (_as_int(rail_state.get("polls")) or 0) % rail_every == 0
    project_budget = max(1, BUDGET_SECS - (RAIL_BUDGET_SECS if rail_due else 0))
    deadline = time.time() + project_budget
    findings = []
    findings.extend(liveness_findings(now, cadence))
    conditions = {}
    for problem in problems:
        conditions["config: %s" % problem] = "could-not-determine config: %s" % problem
    beat = read_int(BEAT)
    if beat is not None and cadence > 0 and now - beat >= DARK_FACTOR * cadence:
        conditions["beat"] = "DARK beat %ss old (>= %ss): no project read since" % (
            now - beat, DARK_FACTOR * cadence)

    # Whether the record is a first poll is decided by the record's presence,
    # never by whether it happens to hold issues: an estate with nothing
    # unresolved still has a baseline, and re-treating an empty record as a first
    # poll would silence the next real finding.
    stored = read_json(RECORD)
    present = isinstance(stored, dict) and stored.get("schema") == SCHEMA
    issues = stored.get("issues") if present and isinstance(stored.get("issues"), dict) else {}
    prior_conditions = (
        stored.get("conditions")
        if present and isinstance(stored.get("conditions"), dict) else {}
    )
    # A project's poll window runs from the last poll that actually read it, so
    # a NEW issue counts as a burst only when it first appeared inside that
    # window, and a poll that skipped the project never shortens it.
    last_read = {}
    if present and isinstance(stored.get("last_read"), dict):
        last_read = {
            slug: _as_int(stamp) for slug, stamp in stored["last_read"].items()
            if _as_int(stamp) is not None
        }
    cursor = stored.get("cursor") if present else None
    unread = {}
    if present and isinstance(stored.get("unread"), dict):
        unread = {slug: _as_int(n) or 0 for slug, n in stored["unread"].items()}
    if not present:
        imported, files_read = import_legacy(issues)
        if files_read:
            write_json_atomic(RECORD, {
                "schema": SCHEMA, "updated": now,
                "legacy_imported": imported, "issues": issues,
            })
    issues = prune_issues(issues, now, config["retention_secs"])

    enumerated = True
    try:
        projects = fetch_projects(org, host, token)
    except FetchError as exc:
        conditions["projects"] = "could-not-determine projects: %s" % exc
        enumerated = False
        projects = []

    deny = set(config["denylist"])
    slugs = []
    for project in projects:
        if not isinstance(project, dict):
            continue
        slug = project.get("slug") or ""
        if not slug or slug in deny:
            continue
        slugs.append(slug)
    if cursor in slugs:
        start = slugs.index(cursor) + 1
        slugs = slugs[start:] + slugs[:start]
    per_project = max(2.0, float(project_budget) / max(1, len(slugs)))

    signatures = {}
    for key in ("sensitive", "noise", "transport", "retired", "crash", "critical"):
        signatures[key] = compile_re(config["signatures"].get(key, ""), "signatures.%s" % key, [])

    updated = {}
    issue_findings = []
    read_any = False
    for slug in slugs:
        settings = project_settings(config, slug)
        remaining = deadline - time.time()
        if remaining < 1.0:
            unread[slug] = unread.get(slug, 0) + 1
            prior = prior_conditions.get(slug)
            if isinstance(prior, dict) and prior.get("message"):
                conditions[slug] = prior["message"]
            elif unread[slug] >= UNREAD_POLLS:
                conditions[slug] = "could-not-determine %s: unread for %s consecutive polls" % (
                    slug, unread[slug])
            continue
        try:
            rows = fetch_issues(org, host, token, slug, min(HTTP_TIMEOUT, per_project, remaining))
        except FetchError as exc:
            unread[slug] = unread.get(slug, 0) + 1
            conditions[slug] = "could-not-determine %s: %s" % (slug, exc)
            continue
        window_start = last_read.get(slug, now - cadence)
        project_baseline = not project_seen(slug, issues, last_read)
        last_read[slug] = now
        unread[slug] = 0
        cursor = slug
        read_any = True
        for issue in rows:
            if not isinstance(issue, dict):
                continue
            sid = issue.get("shortId") or issue.get("id")
            if not sid:
                continue
            entry = issue_entry(issue, now)
            entry["project"] = slug
            old = issues.get(sid)
            entry["rate"] = project_rate(entry, old, now)
            entry["surfaced"] = (old.get("surfaced") or 0) if isinstance(old, dict) else 0
            if not project_baseline:
                finding = classify(entry, old, settings, signatures, config, window_start, now, cadence)
                if finding:
                    # The surfaced marker is what distinguishes an issue this
                    # watch has woken firstmate about from one it only recorded,
                    # so the rail cross-check never calls a surfaced fix a
                    # silent disagreement. Every finding prints, so the marker
                    # is never set on an issue whose line was dropped.
                    entry["surfaced"] = now
                    issue_findings.append(finding)
            updated[sid] = entry

    if not enumerated:
        # A poll that could not list projects learned nothing about any single
        # project's condition, so those carry over neither reported nor cleared.
        for key, record in prior_conditions.items():
            if key in conditions or key in ("projects", "beat") or key.startswith("config: "):
                continue
            if isinstance(record, dict) and record.get("message"):
                conditions[key] = record["message"]
    removed_lines = []
    if enumerated:
        for key in sorted(prior_conditions):
            if key in slugs or key in ("projects", "beat") or key.startswith("config: "):
                continue
            prior_conditions.pop(key)
            removed_lines.append("removed from watch %s" % key)
    condition_lines, conditions = condition_findings(prior_conditions, conditions, now)
    findings.extend(removed_lines)
    findings.extend(condition_lines)
    findings.extend(issue_findings)

    merged = dict(issues)
    merged.update(updated)
    write_json_atomic(RECORD, {
        "schema": SCHEMA,
        "updated": now,
        "issues": merged,
        "conditions": conditions,
        "last_read": last_read,
        "unread": unread,
        "cursor": cursor,
    })
    if read_any:
        try:
            BEAT.write_text("%s\n" % now)
            os.chmod(BEAT, 0o600)
        except OSError:
            pass

    # Rail cross-check: report an id the rail fixed that this watch never saw.
    # It runs on its own cadence with its own reserved budget, so a poll whose
    # project reads consumed theirs still reads the rail.
    rail_findings = []
    previous = rail_state
    if rail_config.get("enabled", True):
        previous["polls"] = (_as_int(previous.get("polls")) or 0) + 1
    if rail_due:
        prs, error = fetch_rail(rail_config, time.time() + RAIL_BUDGET_SECS)
        if error:
            if previous.get("ok", True):
                rail_findings.append("RAILCHECK-DARK %s" % error)
            previous["ok"] = False
        else:
            previous["ok"] = True
            known = set(previous.get("known") or [])
            reported = set(previous.get("reported") or [])
            ids = rail_ids(prs, rail_config)
            # The first successful rail read seeds the known set instead of
            # reporting history: the estate's earlier rail fixes are not news on
            # arming. The seeded flag, not the known set, records that: a first
            # read that found nothing must still not absorb the first real fix.
            surfaced = {
                sid for sid, entry in merged.items()
                if isinstance(entry, dict) and entry.get("surfaced")
            }
            if not previous.get("seeded"):
                known = set(ids)
                previous["seeded"] = True
            else:
                for sid in sorted(set(ids) - known):
                    if sid not in reported and sid not in surfaced:
                        rail_findings.append("RAIL-ONLY %s %s" % (sid, ids[sid]))
                        reported.add(sid)
                known |= set(ids)
            previous["known"] = sorted(known)
            previous["reported"] = sorted(reported)
    if rail_config.get("enabled", True):
        write_json_atomic(RAIL_STATE, rail_state)

    findings.extend(rail_findings)
    for finding in findings:
        print("sentry-watch: " + finding)


def main():
    config, problems = load_config()
    org, host, token = resolve_credentials(config, problems)
    if ACTION == "status":
        action_status(config, problems)
        return
    if ACTION == "projects":
        action_projects(config, org, host, token, problems)
        return
    if ACTION == "migrate":
        action_migrate()
        return
    action_poll(config, org, host, token, problems)


main()
PY
}

# One line per finding: the cap bounds a single line and never drops a finding.
action_poll() {
  local out line
  out=$(run_engine poll) || {
    printf 'sentry-watch: could-not-determine the poll engine failed\n'
    return 0
  }
  [ -n "$out" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    fm_cap_line "$line" "$MAX_LINE"
  done <<EOF
$out
EOF
}

action_status() { run_engine status; }

action_projects() { run_engine projects; }

action_migrate() { run_engine migrate; }

# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory and a relative spelling would send the check to a
# different home, or to none at all.
shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-sentry-watch.sh - Sentry watch poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-sentry-watch.sh") poll"
}

# The armed marker is the external half of liveness: it survives a deleted shim,
# so bin/fm-wake-drain.sh can tell a home that meant to watch Sentry from one
# that never did. The beat is seeded here so the first poll after arming is not
# read as a gap.
write_armed() {
  local cadence=$1 now=$2
  {
    printf 'schema=fm-sentry-watch-armed-v1\n'
    printf 'cadence=%s\n' "$cadence"
    printf 'shim=%s\n' "$SHIM"
    printf 'trust=%s\n' "$TRUST"
    printf 'beat=%s\n' "$BEAT"
  } > "$ARMED" || return 1
  chmod 0600 "$ARMED" 2>/dev/null || true
  printf '%s\n' "$now" > "$BEAT" || return 1
  chmod 0600 "$BEAT" 2>/dev/null || true
}

action_arm() {
  local want home cadence now
  mkdir -p "$STATE" || return 1
  # A task's own PR poll writes state/<id>.check.sh, so this id must never also
  # be a live task id. Refusing when a task record exists keeps the watch's path
  # out of that namespace instead of letting the two share it.
  if [ -e "$STATE/$CHECK_ID.meta" ] || [ -L "$STATE/$CHECK_ID.meta" ]; then
    printf 'fm-sentry-watch: refusing to arm: %s is a task id\n' "$STATE/$CHECK_ID.meta" >&2
    return 1
  fi
  home=$(fm_custom_check_resolve_home "$FM_HOME") || {
    printf 'fm-sentry-watch: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
    return 1
  }
  want=$(shim_content "$home")
  fm_custom_check_arm "$STATE" "$CHECK_ID" .fm-sentry-watch-check \
    fm-sentry-watch "$REGISTER_BIN" "$home" "$want" || return 1
  cadence=${FM_SENTRY_WATCH_CADENCE:-}
  case "$cadence" in ''|*[!0-9]*|0) cadence=300 ;; esac
  now=$(date +%s)
  if ! write_armed "$cadence" "$now"; then
    printf 'fm-sentry-watch: could not write the armed marker %s\n' "$ARMED" >&2
    return 1
  fi
  return 0
}

action_disarm() {
  # The shared baseline is deliberately kept: the sentry-mobile scout reads it,
  # and losing the seen-set would re-announce the whole estate on a re-arm.
  fm_custom_check_disarm "$STATE" "$CHECK_ID" "$BEAT" "$ARMED" "$RAIL_STATE"
}

case "${1:-poll}" in
  poll) action_poll ;;
  status) action_status ;;
  projects) action_projects ;;
  migrate) action_migrate ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  --help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
