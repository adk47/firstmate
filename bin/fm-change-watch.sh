#!/usr/bin/env bash
# Post-merge change watch: watch a merged change BY EFFECT, not by content.
#
# A merge that touches a deployable service is normally verified at merge time
# by reading the new content on the live pods. That proves the change ARRIVED; it
# does not prove the service is healthy afterwards. This script registers one
# bounded watch per merged change, samples the affected Deployment's own signals
# against a pre-deploy baseline, and reports the FIRST regression as a wake and a
# steer so a bad change is caught minutes after the rollout, not hours later.
#
# Usage:
#   fm-change-watch.sh register <task-id> <pr-url>
#   fm-change-watch.sh due <watch-id>
#   fm-change-watch.sh drive <watch-id>
#   fm-change-watch.sh sample <watch-id> [<offset-seconds>]
#   fm-change-watch.sh verdict <watch-id>
#   fm-change-watch.sh status [<watch-id>]
#
# register  Derive the affected Kubernetes Deployment(s) from the merged PR's
#           file list, record the pre-deploy baseline, and arm one bounded
#           schedule of samples. For an H-DevOps pull request the targets come
#           from the changed manifests under k8s/prod/<namespace>/ (the
#           Deployment names in the diff). For an application repository the
#           target is the service named in data/projects.md, or the repository
#           itself, resolved to the Deployment that carries it in the local
#           H-DevOps checkout. A PR that touches no deployable service registers
#           nothing and says so. Registration is read-only against the cluster;
#           it writes only under this home's state/ directory.
# due       Condition hook for the armed watch: exit 0 when a scheduled sample
#           is due now, exit 1 otherwise. Pure and cheap; never runs a sample.
# drive     Action hook for the armed watch: take every remaining scheduled
#           sample in order, stopping at the first regression. This is the one
#           long-running child; it is armed through bin/fm-procevent-when.sh and
#           is never run in a conversational turn.
# sample    Read every metric for every target, compare each to its baseline
#           with a stated bar, and append one sample record. Degrades to
#           "unmeasured" per metric rather than failing the whole watch.
# verdict   Print "change-watch clean" or
#           "change-watch regressed at +Nm on <metric> (<value> vs baseline <value>)".
# status    Print one line per registered watch (all of them, or one).
#
# Metrics, bars, and windows:
#   http_5xx_per_min     5xx responses per minute over the window; regressed when
#                        value > 3x baseline AND value > 1/min.
#   restarts             total container restartCount across the Deployment's
#                        pods; regressed when value > baseline + 1.
#   oomkilled            OOMKilled container terminations at or after the
#                        baseline epoch; regressed when value > 0.
#   p95_ms               request p95 latency where the service exposes it;
#                        regressed when value > 3x baseline AND > baseline+100ms.
#   pgbouncer_cl_waiting client waits on the service's pgbouncer pool
#                        (SHOW POOLS); regressed when value > 0 on two
#                        consecutive samples.
#   rss_ratio            highest container RSS as a fraction of its memory
#                        limit; regressed when value > 0.85.
# The baseline window is the 60 minutes before the change's rollout start, read
# as a level for counters (restarts, oomkilled, rss_ratio) and as a rate for the
# others. An unmeasured metric is skipped, never scored as a pass.
#
# Schedule: +5m, +15m, +30m, then hourly to +12h. Samples stop at the first
# regression. On a clean +12h the watch appends one note to the task's status log
# and records one wiki observation.
#
# Reporting: the first regression appends one
#   check: change-watch <task-id> <pr-url> <metric> regressed
# wake to the durable wake queue and steers the owning task through
# bin/fm-send.sh with the numbers. Both are best-effort and never fail a merge.
#
# Read-only against the cluster. No model calls. No new fleet workers: the
# watcher's existing process-event runner drives the registered watch. One
# sample is bounded by a hard budget (default 25s); every metric not read inside
# it is recorded unmeasured.
#
# Test seams (all optional, all inert in production):
#   FM_CW_NOW              fixed current epoch (integer) instead of `date +%s`
#   FM_CW_MERGE_EPOCH      fixed rollout/merge epoch instead of the PR's
#   FM_CW_FORGE_DIR        directory replacing every forge read (files.txt,
#                          merge-epoch, merge-ref, content/<path>)
#   FM_CW_HDEVOPS_K8S_DIR  k8s/prod tree of an H-DevOps checkout, used to resolve
#                          an application service to its Deployment
#   FM_CW_PROJECTS_FILE    projects registry read for an application service name
#                          (default $FM_HOME/data/projects.md)
#   FM_CW_FORGE_TIMEOUT    per-call bound on a forge read (default 12s)
#   FM_CW_SAMPLE_DEADLINE  hard budget for one sample in seconds (default 25)
#   FM_CW_CLUSTER_DIR      directory of metric series replacing cluster reads:
#                          <metric>.<target>.<window>, one value per line, empty
#                          line = unmeasured; the target is ns/deploy with "/"
#                          replaced by "_", or "watch" for watch-level metrics
#   FM_CW_ARM_CMD          command replacing bin/fm-procevent-when.sh for arming
#   FM_CW_SEND_CMD         command replacing bin/fm-send.sh for the lane steer
#   FM_CW_SLEEP_CMD        command replacing `sleep` for the drive loop
#   FM_CW_WIKI_CMD         command replacing `wiki-retro` for the clean note
#   FM_CW_NO_WIKI          set to 1 to skip the wiki note with a printed notice
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

WATCH_ROOT="$STATE/change-watch"
SCHEDULE_OFFSETS="300 900 1800 3600 7200 10800 14400 18000 21600 25200 28800 32400 36000 39600 43200"
BASELINE_WINDOW_SECONDS=3600
SAMPLE_WINDOW_SECONDS=300
KUBECTL_TIMEOUT=4s
FORGE_TIMEOUT=${FM_CW_FORGE_TIMEOUT:-12}
# Hard budget for one sample: once it elapses, every remaining metric is
# recorded unmeasured so a slow or unreachable read can never run a sample past
# its bound.
SAMPLE_DEADLINE_SECONDS=${FM_CW_SAMPLE_DEADLINE:-25}
MAX_MANIFEST_READS=20

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
notice() { printf 'notice: %s\n' "$1" >&2; }
usage() { sed -n '2,93p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

cw_now() {
  if [ -n "${FM_CW_NOW:-}" ]; then
    printf '%s\n' "$FM_CW_NOW"
  else
    date +%s
  fi
}

cw_kubectl() { kubectl --request-timeout="$KUBECTL_TIMEOUT" "$@"; }

# Bound one forge read so a hung CLI can never stall the merge or watcher path.
cw_forge_run() { fm_run_timed "$FORGE_TIMEOUT" "$@" 2>/dev/null; }

# Stable content hash of a string (shasum or sha256sum; empty when neither is
# available, in which case the watch name falls back to a path-safe prefix).
cw_hash() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum 2>/dev/null | awk '{print $1}'
  else
    printf '%s' "$1" | tr -c 'A-Za-z0-9-' '-'
  fi
}

# --- watch records ------------------------------------------------------------

cw_watch_id() { printf '%s-%s\n' "$1" "$2"; }
cw_watch_dir() { printf '%s/%s\n' "$WATCH_ROOT" "$1"; }
cw_meta_path() { printf '%s/watch.meta\n' "$(cw_watch_dir "$1")"; }
cw_targets_path() { printf '%s/targets\n' "$(cw_watch_dir "$1")"; }
cw_baseline_path() { printf '%s/baseline\n' "$(cw_watch_dir "$1")"; }
cw_schedule_path() { printf '%s/schedule\n' "$(cw_watch_dir "$1")"; }
cw_samples_path() { printf '%s/samples.log\n' "$(cw_watch_dir "$1")"; }
cw_verdict_path() { printf '%s/verdict\n' "$(cw_watch_dir "$1")"; }
cw_last_path() { printf '%s/last.%s\n' "$(cw_watch_dir "$1")" "$2"; }

cw_meta_get() {  # <watch-id> <key>
  local file
  file=$(cw_meta_path "$1")
  [ -f "$file" ] || return 1
  grep "^$2=" "$file" | tail -1 | cut -d= -f2- || true
}

cw_watch_exists() {
  local dir
  dir=$(cw_watch_dir "$1")
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -f "$dir/watch.meta" ]
}

# atomic private write from stdin
cw_write() {  # <path>
  local path=$1 tmp
  tmp=$(umask 077; mktemp "$(dirname "$path")/.cw.XXXXXX") || return 1
  cat > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path"
}

# --- forge seam ---------------------------------------------------------------

# LIVE QUERY (forge) - changed paths of the merged PR, one per line. GitHub is
# read through gh; anything else degrades to no file list, so register reports
# that it cannot derive a target rather than guessing one.
cw_forge_files() {  # <url> <provider> <owner> <repo> <number>
  if [ -n "${FM_CW_FORGE_DIR:-}" ]; then
    [ -f "$FM_CW_FORGE_DIR/files.txt" ] || return 1
    cat "$FM_CW_FORGE_DIR/files.txt"
    return 0
  fi
  case "$2" in
    github)
      command -v gh >/dev/null 2>&1 || return 1
      cw_forge_run gh pr view "$1" --json files -q '.files[].path' || return 1
      ;;
    *) return 1 ;;
  esac
}

# LIVE QUERY (forge) - merge/rollout epoch of the merged change.
cw_forge_merge_epoch() {  # <url> <provider>
  if [ -n "${FM_CW_FORGE_DIR:-}" ]; then
    [ -f "$FM_CW_FORGE_DIR/merge-epoch" ] || return 1
    cat "$FM_CW_FORGE_DIR/merge-epoch"
    return 0
  fi
  local iso
  case "$2" in
    github)
      command -v gh >/dev/null 2>&1 || return 1
      iso=$(cw_forge_run gh pr view "$1" --json mergedAt -q .mergedAt) || return 1
      ;;
    *) return 1 ;;
  esac
  cw_iso_to_epoch "$iso"
}

cw_iso_to_epoch() {  # <iso8601>
  local iso=$1 out
  [ -n "$iso" ] || return 1
  if out=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null); then
    printf '%s\n' "$out"; return 0
  fi
  if out=$(date -u -d "$iso" +%s 2>/dev/null); then
    printf '%s\n' "$out"; return 0
  fi
  return 1
}

# LIVE QUERY (forge) - one file's content at the merged commit.
cw_forge_content() {  # <owner> <repo> <path> <ref>
  if [ -n "${FM_CW_FORGE_DIR:-}" ]; then
    [ -f "$FM_CW_FORGE_DIR/content/$3" ] || return 1
    cat "$FM_CW_FORGE_DIR/content/$3"
    return 0
  fi
  command -v gh >/dev/null 2>&1 || return 1
  cw_forge_run gh api "repos/$1/$2/contents/$3?ref=$4" --jq .content \
    | base64 -d 2>/dev/null || return 1
}

# LIVE QUERY (forge) - merge commit sha of the merged pull request.
cw_forge_merge_ref() {  # <url>
  if [ -n "${FM_CW_FORGE_DIR:-}" ]; then
    [ -f "$FM_CW_FORGE_DIR/merge-ref" ] || return 1
    cat "$FM_CW_FORGE_DIR/merge-ref"
    return 0
  fi
  command -v gh >/dev/null 2>&1 || return 1
  cw_forge_run gh pr view "$1" --json mergeCommit -q .mergeCommit.oid || return 1
}

# --- deployment derivation ----------------------------------------------------

# Deployment names declared in a Kubernetes manifest stream (stdin).
cw_manifest_deployments() {
  awk '
    function flush() { if (is_dep && name != "") print name; is_dep = 0; name = "" }
    /^---[[:space:]]*$/ { flush(); next }
    /^kind:[[:space:]]*Deployment[[:space:]]*$/ { is_dep = 1; next }
    is_dep && name == "" && /^[[:space:]]+name:[[:space:]]*/ {
      name = $2; gsub(/["\047]/, "", name)
    }
    END { flush() }
  '
}

# LIVE QUERY (checkout) - the service named in data/projects.md, or the repo
# name itself when the repo is not registered there. Read-only.
cw_service_name() {  # <repo-name>
  local file=${FM_CW_PROJECTS_FILE:-$FM_HOME/data/projects.md}
  local name
  [ -f "$file" ] || { printf '%s\n' "$1"; return 0; }
  name=$(awk -v repo="$1" '$1 == "-" && $2 == repo { print $2; exit }' "$file" 2>/dev/null || true)
  printf '%s\n' "${name:-$1}"
}

# Resolve an application service name to "namespace<TAB>deployment" from a local
# H-DevOps checkout's k8s/prod tree. Read-only; prints nothing when unresolved.
# LIVE QUERY (checkout).
cw_service_targets() {  # <service>
  local root=${FM_CW_HDEVOPS_K8S_DIR:-$FM_HOME/projects/H-DevOps/k8s/prod}
  local service=$1 dir manifest ns name
  [ -d "$root" ] || return 1
  for dir in "$root"/*; do
    [ -d "$dir" ] || continue
    for manifest in "$dir"/*.yaml "$dir"/*.yml; do
      [ -f "$manifest" ] || continue
      while IFS= read -r name; do
        [ "$name" = "$service" ] || continue
        ns=$(basename "$dir")
        printf '%s\t%s\n' "$ns" "$name"
        return 0
      done < <(cw_manifest_deployments < "$manifest")
    done
  done
  return 1
}

# Derive "namespace<TAB>deployment" targets from the merged PR's file list.
# Prints one target per line; prints nothing when no deployable service is
# touched.
cw_derive_targets() {  # <url> <provider> <owner> <repo> <number> <repo-name>
  local url=$1 provider=$2 owner=$3 repo=$4 number=$5 repo_name=$6
  local files ref path ns declared name any=0 reads=0
  files=$(cw_forge_files "$url" "$provider" "$owner" "$repo" "$number") || return 1
  [ -n "$files" ] || return 1
  ref=$(cw_forge_merge_ref "$url" 2>/dev/null || true)

  # H-DevOps shape: manifests under k8s/prod/<namespace>/.
  while IFS= read -r path; do
    case "$path" in
      k8s/prod/*/*.yaml|k8s/prod/*/*.yml) ;;
      *) continue ;;
    esac
    [ -n "$ref" ] || continue
    [ "$reads" -lt "$MAX_MANIFEST_READS" ] || continue
    ns=$(printf '%s' "$path" | cut -d/ -f3)
    [ -n "$ns" ] || continue
    reads=$((reads + 1))
    declared=$(cw_forge_content "$owner" "$repo" "$path" "$ref" 2>/dev/null | cw_manifest_deployments) || true
    [ -n "$declared" ] || continue
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      printf '%s\t%s\n' "$ns" "$name"
      any=1
    done <<TARGETS
$declared
TARGETS
  done <<PATHS
$files
PATHS
  [ "$any" -eq 1 ] && return 0

  # Application-repo shape: the service named in data/projects.md, or the repo
  # name itself, resolved to the Deployment that carries it in H-DevOps.
  cw_service_targets "$(cw_service_name "$repo_name")"
}

# --- live metric reads --------------------------------------------------------
# Each live query below is self-contained and can be run by hand with the same
# arguments, so an operator can reproduce any sample outside this script.

# LIVE QUERY (cluster) - 5xx responses per minute for one Deployment's pods. The
# shape is the one the p1/infra lanes use: the app's own access log over the
# window, kept only when the HTTP/1.1 line count proves the probe executed.
cw_live_http_5xx_per_min() {  # <ns> <deploy> <window-seconds>
  local ns=$1 deploy=$2 secs=$3 errors total
  errors=$(cw_kubectl -n "$ns" logs --tail=2000 --since="${secs}s" --max-log-requests=10 \
    -l "app=$deploy" 2>/dev/null | grep -cE '500 Internal|"\s5[0-9][0-9]\s' || true)
  total=$(cw_kubectl -n "$ns" logs --tail=2000 --since="${secs}s" --max-log-requests=10 \
    -l "app=$deploy" 2>/dev/null | grep -cE 'HTTP/1.1' || true)
  [ "${total:-0}" -gt 0 ] || return 1
  awk -v e="$errors" -v s="$secs" 'BEGIN { printf "%.4f\n", (e * 60) / s }'
}

# LIVE QUERY (cluster) - total container restartCount across the Deployment.
cw_live_restarts() {  # <ns> <deploy> <window-seconds>
  local ns=$1 deploy=$2
  cw_kubectl -n "$ns" get pods -l "app=$deploy" -o json 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
total = 0
for pod in data.get("items", []):
    for cs in pod.get("status", {}).get("containerStatuses", []) or []:
        total += int(cs.get("restartCount", 0) or 0)
print(total)
' 2>/dev/null || return 1
}

# LIVE QUERY (cluster) - OOMKilled terminations at or after the baseline epoch.
# An OOMKilled pod that restarted successfully never shows in the pod's current
# STATUS, so lastState is the only honest signal.
cw_live_oomkilled() {  # <ns> <deploy> <baseline-epoch>
  local ns=$1 deploy=$2 since=${3:-0}
  cw_kubectl -n "$ns" get pods -l "app=$deploy" -o json 2>/dev/null | python3 -c '
import datetime, json, sys
since = int(sys.argv[1] or 0)
data = json.load(sys.stdin)
count = 0
for pod in data.get("items", []):
    for cs in pod.get("status", {}).get("containerStatuses", []) or []:
        for state in (cs.get("lastState", {}) or {}).values():
            if not isinstance(state, dict) or state.get("reason") != "OOMKilled":
                continue
            ts = state.get("finishedAt") or ""
            if not ts:
                count += 1
                continue
            try:
                t = datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")
                if int(t.replace(tzinfo=datetime.timezone.utc).timestamp()) >= since:
                    count += 1
            except ValueError:
                count += 1
print(count)
' "$since" 2>/dev/null || return 1
}

# LIVE QUERY (cluster) - request p95 latency where the service exposes it, from
# the conventional per-service Prometheus histogram. An absent series is
# unmeasured, not a pass.
cw_live_p95_ms() {  # <ns> <deploy> <window-seconds>
  local ns=$1 deploy=$2 secs=$3 value rc
  command -v kubectl >/dev/null 2>&1 || return 1
  command -v curl >/dev/null 2>&1 || return 1
  value=$(
    cw_kubectl -n monitoring port-forward svc/kube-prometheus-kube-prome-prometheus 19090:9090 >/dev/null 2>&1 &
    pf=$!
    sleep 1
    curl -fsS -G 'http://127.0.0.1:19090/api/v1/query' \
      --data-urlencode "query=histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{namespace=\"$ns\",app=\"$deploy\"}[${secs}s])) by (le))" \
      2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    print(float(data["data"]["result"][0]["value"][1]) * 1000)
except Exception:
    sys.exit(1)
' 2>/dev/null
    rc=$?
    kill "$pf" 2>/dev/null || true
    exit "$rc"
  )
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

# LIVE QUERY (cluster) - highest container RSS as a fraction of its memory limit
# across the Deployment's pods. Reads the pod specs for limits and metrics-server
# for the working set, then takes the worst ratio.
cw_live_rss_ratio() {  # <ns> <deploy> <window-seconds>
  local ns=$1 deploy=$2 limits usage
  limits=$(cw_kubectl -n "$ns" get pods -l "app=$deploy" -o json 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
for pod in data.get("items", []):
    p = pod.get("metadata", {}).get("name", "")
    for c in pod.get("spec", {}).get("containers", []) or []:
        raw = str((c.get("resources", {}).get("limits", {}) or {}).get("memory", "") or "")
        factor = 1
        for suffix, mult in (("Ki", 1024), ("Mi", 1024 ** 2), ("Gi", 1024 ** 3),
                             ("K", 1000), ("M", 1000 ** 2), ("G", 1000 ** 3)):
            if raw.endswith(suffix):
                factor = mult
                raw = raw[: -len(suffix)]
                break
        try:
            limit = float(raw) * factor
        except ValueError:
            limit = 0.0
        if limit > 0:
            print("%s\t%s\t%.0f" % (p, c.get("name", ""), limit))
' 2>/dev/null) || return 1
  [ -n "$limits" ] || return 1
  usage=$(cw_kubectl -n "$ns" top pods -l "app=$deploy" --containers --no-headers 2>/dev/null) || return 1
  [ -n "$usage" ] || return 1
  printf '%s\n' "$limits" | awk -F'\t' -v usage="$usage" '
    BEGIN {
      n = split(usage, rows, "\n")
      for (i = 1; i <= n; i++) {
        m = split(rows[i], f, /[ \t]+/)
        if (m < 3) continue
        u = f[3]
        mult = 1
        last = substr(u, length(u), 1)
        if (last == "M" || last == "m") { mult = 1000000; u = substr(u, 1, length(u) - 1) }
        else if (last == "G" || last == "g") { mult = 1000000000; u = substr(u, 1, length(u) - 1) }
        else if (last == "K" || last == "k") { mult = 1000; u = substr(u, 1, length(u) - 1) }
        used[f[1] SUBSEP f[2]] = (u + 0) * mult
      }
      worst = 0
    }
    {
      key = $1 SUBSEP $2
      if (key in used && $3 + 0 > 0) {
        r = used[key] / ($3 + 0)
        if (r > worst) worst = r
      }
    }
    END { if (worst > 0) printf "%.4f\n", worst }
  '
}

# LIVE QUERY (cluster) - client waits on the service's pgbouncer pool (SHOW
# POOLS / cl_waiting), read on the primary pooler host. An unreachable console
# is unmeasured.
cw_live_pgbouncer_cl_waiting() {  # <window-seconds>
  local host=${FM_CW_PGBOUNCER_HOST:-10.0.0.17} out
  command -v ssh >/dev/null 2>&1 || return 1
  out=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$host" \
    "sudo -u postgres psql -h 127.0.0.1 -p 6432 -U pgbouncer pgbouncer -tAc 'SHOW POOLS'" 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | awk -F'|' '{ if ($3+0 > max) max = $3+0 } END { printf "%.0f\n", max }'
}

# Dispatch one metric read through the test seam or its live function.
cw_metric_read() {  # <metric> <target> <window> [<baseline-epoch>]
  local metric=$1 target=$2 window=$3 since=${4:-0}
  local file value sanitized secs ns='' deploy=''
  if [ -n "${FM_CW_CLUSTER_DIR:-}" ]; then
    sanitized=$(printf '%s' "$target" | tr '/' '_')
    file="$FM_CW_CLUSTER_DIR/$metric.$sanitized.$window"
    [ -f "$file" ] || file="$FM_CW_CLUSTER_DIR/$metric.$window"
    [ -f "$file" ] || return 1
    value=$(cw_series_next "$file" "$metric.$sanitized.$window")
    case "$value" in
      '') return 1 ;;
      *) printf '%s\n' "$value"; return 0 ;;
    esac
  fi
  case "$target" in
    watch) ;;
    */*) ns=${target%%/*}; deploy=${target#*/} ;;
    *) return 1 ;;
  esac
  if [ "$window" = baseline ]; then secs=$BASELINE_WINDOW_SECONDS; else secs=$SAMPLE_WINDOW_SECONDS; fi
  case "$metric" in
    http_5xx_per_min) cw_live_http_5xx_per_min "$ns" "$deploy" "$secs" ;;
    restarts) cw_live_restarts "$ns" "$deploy" "$secs" ;;
    oomkilled) cw_live_oomkilled "$ns" "$deploy" "$since" ;;
    p95_ms) cw_live_p95_ms "$ns" "$deploy" "$secs" ;;
    rss_ratio) cw_live_rss_ratio "$ns" "$deploy" "$secs" ;;
    pgbouncer_cl_waiting) cw_live_pgbouncer_cl_waiting "$secs" ;;
    *) return 1 ;;
  esac
}

# Read the next value from a stub series, consuming it through a durable cursor.
cw_series_next() {  # <file> <cursor-id>
  local file=$1 id=$2 cursor_file total next
  mkdir -p "$WATCH_ROOT" 2>/dev/null || true
  cursor_file="$WATCH_ROOT/.series-cursor.$id"
  total=$(grep -c '' "$file" 2>/dev/null || echo 0)
  next=$(( $(cat "$cursor_file" 2>/dev/null || echo 0) + 1 ))
  printf '%s\n' "$next" > "$cursor_file" 2>/dev/null || true
  [ "$next" -le "$total" ] || return 1
  sed -n "${next}p" "$file"
}

# --- baseline and sample ------------------------------------------------------

cw_metric_keys() {  # <watch-id>
  local target ns deploy metric
  while IFS=$'\t' read -r ns deploy; do
    [ -n "${ns:-}" ] || continue
    target="$ns/$deploy"
    for metric in http_5xx_per_min restarts oomkilled p95_ms rss_ratio; do
      printf '%s@%s\n' "$metric" "$target"
    done
  done < "$(cw_targets_path "$1")"
  printf 'pgbouncer_cl_waiting@watch\n'
}

cw_key_metric() { printf '%s\n' "${1%%@*}"; }
cw_key_target() { printf '%s\n' "${1#*@}"; }

cw_capture_baseline() {  # <watch-id> <baseline-epoch>
  local id=$1 since=$2 key metric target value out
  out=''
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    metric=$(cw_key_metric "$key")
    target=$(cw_key_target "$key")
    value=$(cw_metric_read "$metric" "$target" baseline "$since" 2>/dev/null || true)
    out="$out$key	$value
"
  done < <(cw_metric_keys "$id")
  printf '%s' "$out" | cw_write "$(cw_baseline_path "$id")"
}

cw_baseline_value() {  # <watch-id> <key>
  local file
  file=$(cw_baseline_path "$1")
  [ -f "$file" ] || return 1
  awk -F'\t' -v k="$2" '$1 == k { print $2; found=1 } END { exit(found ? 0 : 1) }' "$file"
}

# State the bar for one metric and report whether the value crosses it.
cw_metric_regressed() {  # <metric> <value> <baseline> <previous>
  local metric=$1 value=$2 baseline=$3 previous=$4
  [ -n "$value" ] || return 1
  case "$metric" in
    http_5xx_per_min) awk -v v="$value" -v b="$baseline" 'BEGIN { exit !((v+0) > 1 && (v+0) > 3*(b+0)) }' ;;
    restarts) awk -v v="$value" -v b="$baseline" 'BEGIN { exit !((v+0) > (b+0) + 1) }' ;;
    oomkilled) awk -v v="$value" 'BEGIN { exit !((v+0) > 0) }' ;;
    p95_ms) awk -v v="$value" -v b="$baseline" 'BEGIN { exit !((v+0) > (b+0) + 100 && (v+0) > 3*(b+0)) }' ;;
    pgbouncer_cl_waiting) awk -v v="$value" -v p="$previous" 'BEGIN { exit !((v+0) > 0 && (p+0) > 0) }' ;;
    rss_ratio) awk -v v="$value" 'BEGIN { exit !((v+0) > 0.85) }' ;;
    *) return 1 ;;
  esac
}

cw_previous_id() { printf '%s' "$1" | tr '/@' '__'; }

cw_previous_value() {  # <watch-id> <key>
  local file
  file=$(cw_last_path "$1" "$(cw_previous_id "$2")")
  [ -f "$file" ] || return 1
  cat "$file"
}

cw_set_previous_value() {  # <watch-id> <key> <value>
  printf '%s\n' "$3" > "$(cw_last_path "$1" "$(cw_previous_id "$2")")" 2>/dev/null || true
}

# Take one sample. Prints "metric<TAB>target<TAB>value<TAB>baseline" for the
# first bar crossed, or nothing when every measured metric is inside its bar.
# Appends one record per metric to samples.log.
cw_take_sample() {  # <watch-id> <offset-seconds> <sample-epoch> <baseline-epoch>
  local id=$1 offset=$2 epoch=$3 baseline_epoch=$4
  local key metric target value baseline previous regressed first start
  first=''
  start=$(cw_now)
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    metric=$(cw_key_metric "$key")
    target=$(cw_key_target "$key")
    value=''
    if [ $(( $(cw_now) - start )) -lt "$SAMPLE_DEADLINE_SECONDS" ]; then
      value=$(cw_metric_read "$metric" "$target" sample "$baseline_epoch" 2>/dev/null || true)
    fi
    baseline=$(cw_baseline_value "$id" "$key" 2>/dev/null || true)
    previous=$(cw_previous_value "$id" "$key" 2>/dev/null || true)
    regressed=0
    if cw_metric_regressed "$metric" "$value" "$baseline" "$previous"; then
      regressed=1
      [ -n "$first" ] || first="$metric	$target	$value	$baseline"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$epoch" "$offset" "$key" "$value" "$baseline" "$regressed" \
      >> "$(cw_samples_path "$id")"
    [ -z "$value" ] || cw_set_previous_value "$id" "$key" "$value"
  done < <(cw_metric_keys "$id")
  [ -n "$first" ] && printf '%s\n' "$first"
  return 0
}

# --- verdict ------------------------------------------------------------------

cw_verdict_line() {  # <watch-id>
  local id=$1 file
  file=$(cw_verdict_path "$id")
  if [ -f "$file" ]; then
    cat "$file"
    return 0
  fi
  printf 'change-watch clean so far (%s)\n' "$(cw_progress_label "$id")"
}

cw_progress_label() {  # <watch-id>
  local id=$1 t0 now latest offset
  t0=$(cw_meta_get "$id" t0 || true)
  now=$(cw_now)
  latest=$(awk -F'\t' 'NR == 1 || $1 > max { max = $1 } END { if (max == "") max = 0; print max }' \
    "$(cw_schedule_path "$id")" 2>/dev/null || echo 0)
  [ -n "$t0" ] || { printf 'armed\n'; return 0; }
  offset=$(( now - t0 ))
  [ "$offset" -ge 0 ] || offset=0
  printf '+%dm of +%dm' "$((offset / 60))" "$((latest / 60))"
}

cw_record_regression() {  # <watch-id> <offset-seconds> <metric> <target> <value> <baseline>
  local id=$1 offset=$2 metric=$3 target=$4 value=$5 baseline=$6 tick line
  tick=$((offset / 60))
  line=$(printf 'regressed at +%dm on %s (%s vs baseline %s)' \
    "$tick" "$metric" "${value:-unmeasured}" "${baseline:-unmeasured}")
  printf '%s\n' "$line" | cw_write "$(cw_verdict_path "$id")"
  {
    printf 'metric=%s\n' "$metric"
    printf 'target=%s\n' "$target"
    printf 'value=%s\n' "$value"
    printf 'baseline=%s\n' "$baseline"
    printf 'offset=%s\n' "$offset"
    printf 'tick=%s\n' "$tick"
  } | cw_write "$(cw_watch_dir "$id")/regression"
  printf '%s\n' "$line"
}

# Create a marker exactly once; exit 0 only for the creating call.
cw_mark_once() {  # <path>
  local path=$1
  (umask 077; set -C; : > "$path") 2>/dev/null
}

cw_regression_field() {  # <watch-id> <key>
  grep "^$2=" "$(cw_watch_dir "$1")/regression" 2>/dev/null | cut -d= -f2- || true
}

cw_report_regression() {  # <watch-id>
  local id=$1 task url metric target value baseline tick line rc send_cmd
  cw_watch_exists "$id" || return 0
  [ -f "$(cw_watch_dir "$id")/regression" ] || return 0
  cw_mark_once "$(cw_watch_dir "$id")/reported" || return 0
  task=$(cw_meta_get "$id" task || true)
  url=$(cw_meta_get "$id" pr_url || true)
  metric=$(cw_regression_field "$id" metric)
  target=$(cw_regression_field "$id" target)
  value=$(cw_regression_field "$id" value)
  baseline=$(cw_regression_field "$id" baseline)
  tick=$(cw_regression_field "$id" tick)
  [ -n "$metric" ] || return 0

  line="check: change-watch $task $url $metric regressed"
  fm_wake_append check "change-watch-$id" "$line" 2>/dev/null \
    || notice "change-watch: could not queue the regression wake for $url"

  if [ -n "$task" ]; then
    send_cmd=${FM_CW_SEND_CMD:-$SCRIPT_DIR/fm-send.sh}
    if [ -x "$send_cmd" ] || command -v "$send_cmd" >/dev/null 2>&1; then
      rc=0
      FM_HOME="$FM_HOME" "$send_cmd" "$task" \
        "change-watch $url regressed at +${tick}m on $metric (target $target, measured ${value:-unmeasured}, baseline ${baseline:-unmeasured}); investigate before the next sample" \
        >/dev/null 2>&1 || rc=$?
      [ "$rc" -eq 0 ] || notice "change-watch: could not steer $task (rc=$rc); the wake carries the numbers"
    fi
  fi
}

cw_wiki_note() {  # <watch-id> <task> <url>
  local id=$1 task=$2 url=$3 cmd body
  if [ "${FM_CW_NO_WIKI:-0}" = 1 ]; then
    notice "change-watch: wiki note skipped by FM_CW_NO_WIKI for $url"
    return 0
  fi
  cmd=${FM_CW_WIKI_CMD:-wiki-retro}
  if ! command -v "$cmd" >/dev/null 2>&1; then
    notice "change-watch: wiki note skipped (no $cmd on PATH) for $url"
    return 0
  fi
  body="Post-merge change watch for $url (task $task) completed clean at +12h: no 5xx, restart, OOMKilled, latency, pool-wait, or RSS regression against the pre-deploy baseline."
  printf '%s\n' "$body" | "$cmd" "change-watch-clean-$id" "Post-merge change watch clean: $url" \
    >/dev/null 2>&1 || notice "change-watch: wiki note failed for $url"
}

cw_record_clean() {  # <watch-id>
  local id=$1 task url
  task=$(cw_meta_get "$id" task || true)
  url=$(cw_meta_get "$id" pr_url || true)
  printf 'clean\n' | cw_write "$(cw_verdict_path "$id")"
  cw_mark_once "$(cw_watch_dir "$id")/noted" || return 0
  if [ -n "$task" ] && [ -d "$STATE" ] \
    && { [ -f "$STATE/$task.meta" ] || [ -f "$STATE/$task.status" ]; }; then
    printf 'note: change-watch clean for %s\n' "$url" >> "$STATE/$task.status" 2>/dev/null \
      || notice "change-watch: could not append the clean note for $url"
  else
    notice "change-watch: clean note skipped for $url (task $task has no status record)"
  fi
  cw_wiki_note "$id" "$task" "$url"
}

# --- schedule -----------------------------------------------------------------

cw_write_schedule() {  # <watch-id> <t0>
  local id=$1 t0=$2 out='' offset
  for offset in $SCHEDULE_OFFSETS; do
    out="$out$offset	$((t0 + offset))
"
  done
  printf '%s' "$out" | cw_write "$(cw_schedule_path "$id")"
}

cw_sampled_path() { printf '%s/sampled\n' "$(cw_watch_dir "$1")"; }

cw_next_due_offset() {  # <watch-id> <now>
  local id=$1 now=$2 offset epoch
  while IFS=$'\t' read -r offset epoch; do
    [ -n "$offset" ] || continue
    grep -qx "$offset" "$(cw_sampled_path "$id")" 2>/dev/null && continue
    [ "$now" -ge "$epoch" ] || continue
    printf '%s\n' "$offset"
    return 0
  done < "$(cw_schedule_path "$id")"
  return 1
}

cw_mark_sampled() {  # <watch-id> <offset>
  printf '%s\n' "$2" >> "$(cw_sampled_path "$1")" 2>/dev/null || true
}

cw_watch_done() { [ -f "$(cw_verdict_path "$1")" ]; }

# --- commands -----------------------------------------------------------------

cmd_register() {
  local task=$1 url=$2 provider owner repo number repo_name id targets now t0
  fm_pr_task_id_valid "$task" || die "invalid task id: $task"
  fm_pr_url_parse "$url" || die "invalid pr url: $url"
  provider=$FM_PR_PROVIDER
  owner=${FM_PR_OWNER:-}
  repo=${FM_PR_REPO:-}
  number=$FM_PR_NUMBER
  repo_name=${repo:-}
  [ -n "$repo_name" ] || repo_name=$(basename "${FM_PR_PATH:-$url}")

  id=$(cw_watch_id "$task" "$number")
  if cw_watch_exists "$id"; then
    printf 'change-watch: %s already registered for %s\n' "$id" "$url"
    return 0
  fi

  targets=$(cw_derive_targets "$url" "$provider" "$owner" "$repo" "$number" "$repo_name" 2>/dev/null || true)
  if [ -z "$targets" ]; then
    if ! cw_forge_files "$url" "$provider" "$owner" "$repo" "$number" >/dev/null 2>&1; then
      printf 'change-watch: cannot read the merged file list for %s; nothing registered\n' "$url"
    else
      printf 'change-watch: no deployable service touched by %s; nothing registered\n' "$url"
    fi
    return 0
  fi
  targets=$(printf '%s\n' "$targets" | sort -u)

  now=$(cw_now)
  t0=$(cw_forge_merge_epoch "$url" "$provider" 2>/dev/null || true)
  case "$t0" in
    ''|*[!0-9]*) t0=$now ;;
  esac
  if [ -n "${FM_CW_MERGE_EPOCH:-}" ]; then t0=$FM_CW_MERGE_EPOCH; fi
  [ "$t0" -le "$now" ] || t0=$now

  mkdir -p "$(cw_watch_dir "$id")" || die "cannot create watch directory"
  chmod 0700 "$(cw_watch_dir "$id")" 2>/dev/null || true
  printf '%s\n' "$targets" | cw_write "$(cw_targets_path "$id")"
  {
    printf 'version=fm-change-watch-v1\n'
    printf 'task=%s\n' "$task"
    printf 'pr_url=%s\n' "$url"
    printf 'watch_id=%s\n' "$id"
    printf 'provider=%s\n' "$provider"
    printf 'owner=%s\n' "$owner"
    printf 'repo=%s\n' "$repo"
    printf 'number=%s\n' "$number"
    printf 't0=%s\n' "$t0"
    printf 'created=%s\n' "$now"
  } | cw_write "$(cw_meta_path "$id")"
  cw_write_schedule "$id" "$t0"
  cw_capture_baseline "$id" "$t0"

  local when_name arm_cmd
  when_name="cw-$(cw_hash "$id" | cut -c1-40)"
  printf 'when_name=%s\n' "$when_name" >> "$(cw_meta_path "$id")"

  arm_cmd=${FM_CW_ARM_CMD:-$SCRIPT_DIR/fm-procevent-when.sh}
  if [ -x "$arm_cmd" ] || command -v "$arm_cmd" >/dev/null 2>&1; then
    "$arm_cmd" arm "$when_name" \
      --interval 60 --stable 1 --deadline 46800 \
      --condition-timeout 60 --action-timeout 46800 \
      --condition "$SCRIPT_DIR/fm-change-watch.sh" due "$id" \
      --action "$SCRIPT_DIR/fm-change-watch.sh" drive "$id" \
      >/dev/null 2>&1 \
      || notice "change-watch: could not arm the scheduled watch for $url (the watch record is retained)"
  else
    notice "change-watch: arming command unavailable; watch record retained for $url"
  fi

  printf 'change-watch: registered %s for %s (%s target(s))\n' \
    "$id" "$url" "$(grep -c '' "$(cw_targets_path "$id")")"
}

cmd_due() {
  local id=$1 now
  cw_watch_exists "$id" || return 1
  cw_watch_done "$id" && return 1
  now=$(cw_now)
  cw_next_due_offset "$id" "$now" >/dev/null
}

cmd_sample() {
  local id=$1 offset=${2:-} now t0 first metric target value baseline
  cw_watch_exists "$id" || die "unknown watch: $id"
  now=$(cw_now)
  t0=$(cw_meta_get "$id" t0 || true)
  [ -n "$t0" ] || die "watch $id has no rollout epoch"
  if [ -z "$offset" ]; then
    offset=$(cw_next_due_offset "$id" "$now" || true)
    if [ -z "$offset" ]; then
      offset=$(awk -F'\t' -v now="$now" '$2 <= now { o=$1 } END { if (o != "") print o }' \
        "$(cw_schedule_path "$id")" 2>/dev/null || true)
    fi
    [ -n "$offset" ] || offset=$(awk -F'\t' 'NR == 1 { print $1 }' "$(cw_schedule_path "$id")")
  fi
  first=$(cw_take_sample "$id" "$offset" "$now" "$t0" || true)
  cw_mark_sampled "$id" "$offset"
  [ -z "$first" ] && return 0
  metric=$(printf '%s' "$first" | cut -f1)
  target=$(printf '%s' "$first" | cut -f2)
  value=$(printf '%s' "$first" | cut -f3)
  baseline=$(printf '%s' "$first" | cut -f4)
  cw_record_regression "$id" "$offset" "$metric" "$target" "$value" "$baseline"
  cw_report_regression "$id"
}

cmd_drive() {
  local id=$1 sleep_cmd offset epoch now remaining
  cw_watch_exists "$id" || die "unknown watch: $id"
  sleep_cmd=${FM_CW_SLEEP_CMD:-sleep}
  cw_meta_get "$id" t0 >/dev/null || die "watch $id has no rollout epoch"

  while IFS=$'\t' read -r offset epoch; do
    [ -n "$offset" ] || continue
    grep -qx "$offset" "$(cw_sampled_path "$id")" 2>/dev/null && continue
    while :; do
      now=$(cw_now)
      [ "$now" -ge "$epoch" ] && break
      remaining=$(( epoch - now ))
      [ "$remaining" -gt 60 ] && remaining=60
      "$sleep_cmd" "$remaining" 2>/dev/null || true
    done
    cmd_sample "$id" "$offset" >/dev/null || true
    if cw_watch_done "$id"; then
      cw_report_regression "$id"
      return 0
    fi
  done < "$(cw_schedule_path "$id")"

  cw_record_clean "$id"
  return 0
}

cmd_verdict() {
  local id=$1 line
  cw_watch_exists "$id" || die "unknown watch: $id"
  if [ -f "$(cw_verdict_path "$id")" ]; then
    line=$(cat "$(cw_verdict_path "$id")")
    case "$line" in
      clean) printf 'change-watch clean\n' ;;
      *) printf 'change-watch %s\n' "$line" ;;
    esac
    return 0
  fi
  cw_verdict_line "$id"
}

cmd_status() {
  local id=${1:-} meta count=0
  [ -d "$WATCH_ROOT" ] || { printf 'change-watch: no watches registered\n'; return 0; }
  if [ -n "$id" ]; then
    cw_watch_exists "$id" || die "unknown watch: $id"
    printf '%s\t%s\n' "$id" "$(cw_verdict_line "$id")"
    return 0
  fi
  for meta in "$WATCH_ROOT"/*/watch.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$(dirname "$meta")")
    printf '%s\t%s\n' "$id" "$(cw_verdict_line "$id")"
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] || printf 'change-watch: no watches registered\n'
}

# --- entry --------------------------------------------------------------------

case "${1:-}" in
  register) [ "$#" -eq 3 ] || usage; shift; cmd_register "$@" ;;
  due) [ "$#" -eq 2 ] || usage; shift; cmd_due "$@" ;;
  drive) [ "$#" -eq 2 ] || usage; shift; cmd_drive "$@" ;;
  sample) if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then usage; fi; shift; cmd_sample "$@" ;;
  verdict) [ "$#" -eq 2 ] || usage; shift; cmd_verdict "$@" ;;
  status) [ "$#" -le 2 ] || usage; shift; cmd_status "$@" ;;
  ""|-h|--help|help) usage ;;
  *) usage ;;
esac