#!/bin/bash
# ──────────────────────────────────────────────────────────────
# fetch-prod-logs.sh — deterministic, read-only prod log fetcher.
#
# The sanctioned path for pulling Muso production logs from the OVH
# K3s cluster (runs on node-8 where kubectl has read RBAC). Used by:
#   1. the devops agent (skill muso-devops-prod-logs) when an engineer
#      asks for prod logs — replaces ad-hoc improvised kubectl pipelines;
#   2. scripts/prod-log-alert-watchdog.sh on a 5-min system cron.
#
# Structurally read-only: the ONLY kubectl verbs this script ever
# invokes are `logs` and `get`. Multi-replica deployments are handled
# per-pod via the deployment's selector (kubectl logs deploy/X samples
# a single pod and silently misses errors on the others — verified on
# core-backend-api which runs 3 replicas).
#
# Every output path passes through a redaction filter (tokens, JWTs,
# AWS keys, password=/token= values, long hex runs) — log lines get
# posted to Slack downstream.
#
# Usage:
#   fetch-prod-logs.sh -d DEPLOYMENT [-n NAMESPACE] [--since 10m] [--tail 50]
#                      [--pattern REGEX | --no-filter] [--container NAME]
#                      [--previous] [--any-deploy] [--out FILE]
#   fetch-prod-logs.sh --events [-n NAMESPACE]
#   fetch-prod-logs.sh --pods   [-n NAMESPACE] [-d DEPLOYMENT]
#   fetch-prod-logs.sh --list
#
# Exit codes: 0 ok (possibly zero matching lines — empty stdout),
#   2 usage, 3 namespace not allowed, 4 deployment not allow-listed,
#   5 kubectl/cluster failure, 6 config missing (fail-closed).
#
# Env knobs (mainly for tests):
#   KUBECTL_BIN            kubectl binary (default /usr/local/bin/kubectl)
#   PROD_LOGS_CONFIG_DIR   dir holding deployments.txt / error-patterns.txt
#   PROD_LOGS_MAX_BYTES    stdout cap, truncates head-side keeping the most
#                          recent bytes (default 65536)
#   PROD_LOGS_MAX_PODS     max pods sampled per deployment (default 5)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${PROD_LOGS_CONFIG_DIR:-$SCRIPT_DIR/../config}"
KUBECTL_BIN="${KUBECTL_BIN:-/usr/local/bin/kubectl}"
MAX_BYTES="${PROD_LOGS_MAX_BYTES:-65536}"
MAX_PODS="${PROD_LOGS_MAX_PODS:-5}"

ALLOWED_NAMESPACES="muso-prod muso-dev queuing data-processing monitoring"

usage() {
  sed -n '/^# Usage:/,/^# Exit codes/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

NAMESPACE="muso-prod"
DEPLOYMENT=""
SINCE="10m"
TAIL="50"
PATTERN=""
NO_FILTER=0
CONTAINER=""
PREVIOUS=0
ANY_DEPLOY=0
MODE="logs"
OUT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) NAMESPACE="$2"; shift 2 ;;
    -d) DEPLOYMENT="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --tail) TAIL="$2"; shift 2 ;;
    --pattern) PATTERN="$2"; shift 2 ;;
    --no-filter) NO_FILTER=1; shift ;;
    --container) CONTAINER="$2"; shift 2 ;;
    --previous) PREVIOUS=1; shift ;;
    --any-deploy) ANY_DEPLOY=1; shift ;;
    --events) MODE="events"; shift ;;
    --pods) MODE="pods"; shift ;;
    --list) MODE="list"; shift ;;
    --out) OUT_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown flag: $1" >&2; usage >&2; exit 2 ;;
  esac
done

DEPLOYMENTS_FILE="$CONFIG_DIR/deployments.txt"
PATTERNS_FILE="$CONFIG_DIR/error-patterns.txt"

if [[ "$MODE" == "list" ]]; then
  [[ -r "$DEPLOYMENTS_FILE" ]] || { echo "ERROR: missing $DEPLOYMENTS_FILE" >&2; exit 6; }
  grep -Ev '^[[:space:]]*(#|$)' "$DEPLOYMENTS_FILE"
  exit 0
fi

ns_ok=0
for ns in $ALLOWED_NAMESPACES; do
  [[ "$NAMESPACE" == "$ns" ]] && ns_ok=1
done
if [[ "$ns_ok" -ne 1 ]]; then
  echo "ERROR: namespace '$NAMESPACE' not allowed (allowed: $ALLOWED_NAMESPACES)" >&2
  exit 3
fi

# Redaction: always applied — output ends up in Slack. Python (not sed) so the
# case-insensitive key=value rule and JWT shape stay readable and portable.
redact() {
  python3 -c '
import re, sys
rules = [
    (re.compile(r"xox[abprs]-[A-Za-z0-9-]+"), "[REDACTED]"),
    (re.compile(r"Bearer\s+[A-Za-z0-9._~+/=-]+"), "Bearer [REDACTED]"),
    (re.compile(r"AKIA[0-9A-Z]{16}"), "[REDACTED]"),
    (re.compile(r"eyJ[A-Za-z0-9_=-]{8,}\.[A-Za-z0-9_=-]+(\.[A-Za-z0-9_=-]+)?"), "[REDACTED]"),
    (re.compile(r"((?:password|passwd|secret|token|api[_-]?key|authorization)[\"'\'' ]*[=:][\"'\'' ]*)[^\s\"'\''&,;]+", re.I), r"\1[REDACTED]"),
    (re.compile(r"[0-9a-fA-F]{32,}"), "[REDACTED]"),
]
for line in sys.stdin:
    for rx, rep in rules:
        line = rx.sub(rep, line)
    sys.stdout.write(line)
'
}

# Cap stdout size keeping the most RECENT bytes — when logs overflow the cap,
# the tail is what matters.
deliver() {
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  if [[ -n "$OUT_FILE" ]]; then
    cp "$tmp" "$OUT_FILE"
    echo "wrote $(wc -l < "$tmp" | tr -d ' ') lines ($(wc -c < "$tmp" | tr -d ' ') bytes) to $OUT_FILE"
  elif [[ "$(wc -c < "$tmp")" -gt "$MAX_BYTES" ]]; then
    echo "[TRUNCATED — output exceeded ${MAX_BYTES} bytes; showing the most recent ${MAX_BYTES}]"
    tail -c "$MAX_BYTES" "$tmp"
  else
    cat "$tmp"
  fi
  rm -f "$tmp"
}

if [[ "$MODE" == "events" ]]; then
  "$KUBECTL_BIN" get events -n "$NAMESPACE" --sort-by=.lastTimestamp 2>&1 | tail -40 | redact | deliver
  exit 0
fi

if [[ "$MODE" == "pods" ]]; then
  if [[ -n "$DEPLOYMENT" ]]; then
    "$KUBECTL_BIN" get pods -n "$NAMESPACE" -o wide 2>&1 | { grep -E "^NAME|$DEPLOYMENT" || true; } | redact | deliver
  else
    "$KUBECTL_BIN" get pods -n "$NAMESPACE" -o wide 2>&1 | redact | deliver
  fi
  exit 0
fi

# ── logs mode ────────────────────────────────────────────────
if [[ -z "$DEPLOYMENT" ]]; then
  echo "ERROR: logs mode requires -d DEPLOYMENT" >&2
  usage >&2
  exit 2
fi

if [[ "$ANY_DEPLOY" -ne 1 ]]; then
  [[ -r "$DEPLOYMENTS_FILE" ]] || { echo "ERROR: missing $DEPLOYMENTS_FILE (fail-closed)" >&2; exit 6; }
  if ! grep -Eq "^${NAMESPACE}[[:space:]]+${DEPLOYMENT}[[:space:]]*$" "$DEPLOYMENTS_FILE"; then
    echo "ERROR: '$NAMESPACE $DEPLOYMENT' not in $(basename "$DEPLOYMENTS_FILE") — pass --any-deploy to fetch it anyway (still read-only)" >&2
    exit 4
  fi
fi

if [[ "$NO_FILTER" -eq 0 && -z "$PATTERN" ]]; then
  [[ -r "$PATTERNS_FILE" ]] || { echo "ERROR: missing $PATTERNS_FILE (fail-closed)" >&2; exit 6; }
  PATTERN="$(grep -Ev '^[[:space:]]*(#|$)' "$PATTERNS_FILE" | paste -sd'|' -)"
  [[ -n "$PATTERN" ]] || { echo "ERROR: $PATTERNS_FILE has no patterns (fail-closed)" >&2; exit 6; }
fi

# Resolve the deployment's pod selector — `kubectl logs deploy/X` samples ONE
# pod; we sample up to MAX_PODS so 3-replica services don't hide errors.
if ! deploy_json="$("$KUBECTL_BIN" get deploy "$DEPLOYMENT" -n "$NAMESPACE" -o json 2>&1)"; then
  echo "ERROR: kubectl get deploy failed: $deploy_json" >&2
  exit 5
fi
selector="$(printf '%s' "$deploy_json" | python3 -c '
import json, sys
ml = json.load(sys.stdin)["spec"]["selector"]["matchLabels"]
print(",".join(f"{k}={v}" for k, v in sorted(ml.items())))
')"

pods="$("$KUBECTL_BIN" get pods -n "$NAMESPACE" -l "$selector" -o name 2>&1 | sed 's|^pod/||' | sort | head -n "$MAX_PODS")"
if [[ -z "$pods" ]]; then
  echo "ERROR: no pods found for deploy/$DEPLOYMENT in $NAMESPACE (selector: $selector)" >&2
  exit 5
fi

filter() {
  if [[ "$NO_FILTER" -eq 1 ]]; then cat; else grep -Ei "$PATTERN" || true; fi
}

# Per-pod failures must NOT be swallowed: a kubectl error merged into the
# stream gets dropped by the pattern filter (the watchdog's strict pattern
# doesn't match "Error from server (Forbidden)"), which would leave the
# watchdog blind while reporting "no new prod log errors". Collect failures
# outside the pipeline and exit 5 so callers raise their fetch-failed path —
# lines from the pods that DID succeed are still delivered first.
RAW_FILE="$(mktemp)"
FAIL_FILE="$(mktemp)"
for pod in $pods; do
  args=(logs -n "$NAMESPACE" "$pod" "--since=$SINCE" "--tail=$TAIL" --timestamps)
  if [[ -n "$CONTAINER" ]]; then args+=(-c "$CONTAINER"); else args+=(--all-containers=true); fi
  [[ "$PREVIOUS" -eq 1 ]] && args+=(--previous)
  if pod_out="$("$KUBECTL_BIN" "${args[@]}" 2>&1)"; then
    [[ -n "$pod_out" ]] && printf '%s\n' "$pod_out" | sed "s|^|[${pod}] |" >> "$RAW_FILE"
  else
    echo "ERROR: kubectl logs failed for pod $pod: $(printf '%s' "$pod_out" | head -1)" >> "$FAIL_FILE"
  fi
done
filter < "$RAW_FILE" | redact | deliver
rm -f "$RAW_FILE"
if [[ -s "$FAIL_FILE" ]]; then
  cat "$FAIL_FILE" >&2
  rm -f "$FAIL_FILE"
  exit 5
fi
rm -f "$FAIL_FILE"
