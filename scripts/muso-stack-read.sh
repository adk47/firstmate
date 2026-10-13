#!/usr/bin/env bash
# muso-stack-read.sh: READ-ONLY access to our own analytics / email / notification
# stack, the replacement for agent reads of Amplitude, Klaviyo and Knock
# (stack-swap lane 8; skills muso-analytics and muso-email).
#
#   muso-stack-read.sh coverage
#       What the new stack can answer RIGHT NOW (measured, never assumed): the
#       analytics high-water mark, router shadow events, email history, the
#       preferences / Listmonk / bell stores. Run it before preferring a new source.
#   muso-stack-read.sh router '/api/2/<endpoint>?<query>'
#       GET on the event router's Amplitude-compatible query API (same paths, params
#       and JSON as Amplitude's Dashboard API): users, realtime, events/segmentation,
#       usersearch, useractivity. Basic auth with the hydra query credential.
#   muso-stack-read.sh ch '<SELECT ...>'
#       One read query on the product-analytics ClickHouse (product_events.*,
#       messaging.email_events), session readonly=1, 60 s. More than 100k result
#       rows FAILS (exit 1, never a silently truncated answer): aggregate or LIMIT.
#   muso-stack-read.sh pg <notify|preferences|listmonk> '<SELECT ...>'
#       One read query on the messaging Postgres REPLICA (a hot standby cannot write),
#       with default_transaction_read_only on top. CSV out.
#
# Safety: there is no write path in this file. router = GET + a path allow-list;
# ch = server-enforced readonly=1; pg = standby asserted (pg_is_in_recovery) +
# read-only transaction. A statement guard (one SELECT/WITH/SHOW/DESCRIBE/EXPLAIN,
# no ';' chaining) refuses anything else before a byte leaves this host.
#
# Transport: the admin port and the stores are cluster-internal and fenced by
# NetworkPolicy (k8s/prod/messaging/80-event-router.yaml in H-DevOps), so this
# uses the kubectl that node-8 already has: `port-forward` for the router (enters
# the pod netns, the fence does not apply to it) and `exec` for ClickHouse / psql,
# the same way scripts/trino-query.sh reaches Trino.
#
# Credential (router only): MUSOAI_EVENT_ROUTER_QUERY ("hydra:<secret>") from
# /etc/openclaw/main.env if set, else the k8s Secret hydra/hydra-event-router-query
# key query_hydra (ExternalSecret of Vault secret/k8s/messaging/event-router-admin
# property query_hydra). It is never put on argv (curl reads it from stdin) and
# never printed.
#
# Exit codes: 0 ok · 1 query/HTTP error · 2 usage / refused by a guard ·
# 3 cannot reach the stack (kubectl, pod, credential).
set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"
TIMEOUT_S="${MUSO_STACK_READ_TIMEOUT:-60}"
CH_NS="${MUSO_STACK_CH_NS:-data-processing}"
CH_CHI="${MUSO_STACK_CH_CHI:-product-analytics}"
MSG_NS="${MUSO_STACK_MSG_NS:-messaging}"
ROUTER_SVC="${MUSO_STACK_ROUTER_SVC:-svc/event-router-admin}"
ROUTER_PORT="${MUSO_STACK_ROUTER_PORT:-8081}"
CRED_NS="${MUSO_STACK_CRED_NS:-hydra}"
CRED_SECRET="${MUSO_STACK_CRED_SECRET:-hydra-event-router-query}"

die()  { echo "muso-stack-read: $2" >&2; exit "$1"; }
usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# ── statement guard (shared by ch and pg) ────────────────────────────────────
# Strips leading whitespace and -- / /* */ comments, then requires ONE read
# statement. Server-side read-only enforcement is the real control; this refuses
# obvious mistakes early with a clear message instead of a server error.
guard_sql() {
  local sql="$1" head body
  [ -n "${sql//[[:space:]]/}" ] || die 2 "empty SQL"
  body="$(printf '%s' "$sql" | python3 -c '
import re, sys
s = sys.stdin.read()
while True:
    t = s.lstrip()
    if t.startswith("--"):
        s = t.split("\n", 1)[1] if "\n" in t else ""
    elif t.startswith("/*"):
        s = t.split("*/", 1)[1] if "*/" in t else ""
    else:
        s = t
        break
print(s)
')"
  head="$(printf '%s' "$body" | awk 'NR==1{print toupper($1); exit}')"
  case "$head" in
    SELECT|WITH|SHOW|DESCRIBE|DESC|EXPLAIN|EXISTS|TABLE|VALUES) ;;
    *) die 2 "refused: only one read statement (SELECT/WITH/SHOW/DESCRIBE/EXPLAIN) is allowed, got '${head:-?}'" ;;
  esac
  # A ';' followed by anything but whitespace = a second statement riding along.
  if printf '%s' "$body" | python3 -c '
import sys
s = sys.stdin.read().rstrip()
s = s[:-1] if s.endswith(";") else s
sys.exit(0 if ";" in s else 1)
'; then
    die 2 "refused: one statement per call (found ';' chaining)"
  fi
}

need_kubectl() { command -v "$KUBECTL" >/dev/null 2>&1 || die 3 "kubectl not found (KUBECTL=$KUBECTL)"; }

# ── ClickHouse ───────────────────────────────────────────────────────────────
ch_pod() {
  local pod
  pod="$("$KUBECTL" -n "$CH_NS" get pods -l "clickhouse.altinity.com/chi=$CH_CHI" \
        --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "$pod" ] || die 3 "no Running ClickHouse pod for chi=$CH_CHI in ns $CH_NS"
  printf '%s' "$pod"
}

ch_run() {  # $1 = SQL (already guarded or internal)
  local pod; pod="$(ch_pod)"
  timeout "$((TIMEOUT_S + 15))" "$KUBECTL" -n "$CH_NS" exec "$pod" -c clickhouse -- \
    clickhouse-client --readonly=1 --max_execution_time="$TIMEOUT_S" \
      --max_result_rows=100000 --result_overflow_mode=throw \
      --format=TSVWithNames -q "$1" </dev/null
}

cmd_ch() {
  [ $# -eq 1 ] || usage
  guard_sql "$1"; need_kubectl
  # Buffer, print only on success: ClickHouse streams rows before an overflow or
  # timeout exception, and a partial TSV must never look like an answer.
  RESP="$(mktemp)"; trap cleanup EXIT
  ch_run "$1" >"$RESP" || die 1 "ClickHouse query failed, nothing printed (a result over 100000 rows fails on purpose: aggregate or add LIMIT)"
  cat "$RESP"
}

# ── messaging Postgres replica ───────────────────────────────────────────────
pg_replica() {
  local pod
  pod="$("$KUBECTL" -n "$MSG_NS" get pods \
        -l postgres-operator.crunchydata.com/cluster=messaging-pg,postgres-operator.crunchydata.com/role=replica \
        --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "$pod" ] || die 3 "no Running messaging-pg replica in ns $MSG_NS (refusing to read the primary)"
  printf '%s' "$pod"
}

pg_run() {  # $1 = db, $2 = SQL
  local pod rec; pod="$(pg_replica)"
  rec="$(timeout 30 "$KUBECTL" -n "$MSG_NS" exec "$pod" -c database -- \
        psql -XAtq -d "$1" -c 'SELECT pg_is_in_recovery()' </dev/null 2>/dev/null || true)"
  [ "$rec" = "t" ] || die 3 "$pod is not a hot standby right now (pg_is_in_recovery=${rec:-?}); refusing"
  timeout "$((TIMEOUT_S + 15))" "$KUBECTL" -n "$MSG_NS" exec "$pod" -c database -- \
    psql -X -q -v ON_ERROR_STOP=1 --csv -d "$1" \
      -c 'SET default_transaction_read_only = on' \
      -c "SET statement_timeout = '${TIMEOUT_S}s'" \
      -c "$2" </dev/null
}

cmd_pg() {
  [ $# -eq 2 ] || usage
  case "$1" in notify|preferences|listmonk) ;; *) die 2 "db must be notify, preferences or listmonk";; esac
  guard_sql "$2"; need_kubectl
  pg_run "$1" "$2" || die 1 "Postgres query failed"
}

# ── event router query API ───────────────────────────────────────────────────
router_cred() {
  local c="${MUSOAI_EVENT_ROUTER_QUERY:-}"
  if [ -z "$c" ]; then
    c="$("$KUBECTL" -n "$CRED_NS" get secret "$CRED_SECRET" -o jsonpath='{.data.query_hydra}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  fi
  case "$c" in
    ?*:?*) printf '%s' "$c" ;;
    *) die 3 "no router query credential: set MUSOAI_EVENT_ROUTER_QUERY or provision Secret $CRED_NS/$CRED_SECRET (key query_hydra)";;
  esac
}

# Path allow-list: the five rebuilt endpoints, and a query string of URL-safe
# characters only (URL-encode JSON such as e={"event_type":...}).
ROUTER_PATH_RE='^/api/2/(users|realtime|events/segmentation|usersearch|useractivity)(\?[A-Za-z0-9_.~%+=&:,@-]*)?$'
guard_router_path() {
  [[ "$1" =~ $ROUTER_PATH_RE ]] \
    || die 2 "refused: path must be /api/2/{users,realtime,events/segmentation,usersearch,useractivity}[?query], URL-encoded (e.g. e=%7B%22event_type%22%3A%22login%22%7D)"
}

PF_PID=""; PF_LOG=""; RESP=""
cleanup() {
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true
  rm -f ${PF_LOG:+"$PF_LOG"} ${RESP:+"$RESP"} 2>/dev/null || true
}

cmd_router() {
  [ $# -eq 1 ] || usage
  guard_router_path "$1"; need_kubectl
  local cred port="" code
  cred="$(router_cred)"
  PF_LOG="$(mktemp)"; trap cleanup EXIT
  "$KUBECTL" -n "$MSG_NS" port-forward "$ROUTER_SVC" ":$ROUTER_PORT" >"$PF_LOG" 2>&1 &
  PF_PID=$!
  for _ in $(seq 1 50); do
    port="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\).*/\1/p' "$PF_LOG" | head -1)"
    [ -n "$port" ] && break
    kill -0 "$PF_PID" 2>/dev/null || break
    sleep 0.2
  done
  [ -n "$port" ] || die 3 "port-forward to $MSG_NS/$ROUTER_SVC failed: $(head -c 300 "$PF_LOG")"
  RESP="$(mktemp)"
  # Credential on stdin as a curl config line; never on argv.
  code="$(printf 'user = "%s"\n' "$(printf '%s' "$cred" | sed 's/[\\"]/\\&/g')" \
          | curl -sS -K - --max-time "$TIMEOUT_S" -o "$RESP" -w '%{http_code}' \
              "http://127.0.0.1:${port}$1" || echo 000)"
  cat "$RESP"; echo
  case "$code" in
    200) return 0 ;;
    401) die 3 "router said 401: the hydra query credential is wrong or not in QUERY_API_CREDENTIALS" ;;
    *)   die 1 "router HTTP $code" ;;
  esac
}

# ── coverage ─────────────────────────────────────────────────────────────────
cmd_coverage() {
  need_kubectl
  echo "# muso-stack-read coverage ($(date -u +%Y-%m-%dT%H:%MZ)); '-' = store not there yet"
  echo "## analytics (ClickHouse product_events; the router query API reads the events view)"
  ch_run "SELECT
      (SELECT toString(max(event_time)) FROM product_events.events) AS events_view_max_event_time,
      (SELECT if(count() = 0, '- (not cut over: the view serves history only)', toString(max(cutover_at))) FROM product_events.cutover WHERE key = 'events') AS cutover_at,
      (SELECT toString(max(event_time)) FROM product_events.amplitude_events) AS history_max_event_time,
      (SELECT count() FROM product_events.router_events) AS router_events_rows,
      (SELECT toString(max(event_time)) FROM product_events.router_events) AS router_max_event_time" \
    || echo "analytics: UNREACHABLE"
  echo "## email history (ClickHouse messaging.email_events)"
  if [ "$(ch_run "SELECT count() FROM system.tables WHERE database = 'messaging' AND name = 'email_events'" 2>/dev/null | tail -1)" = "1" ]; then
    ch_run "SELECT source, class, count() AS rows, toString(min(event_time)) AS min_event_time, toString(max(event_time)) AS max_event_time FROM messaging.email_events GROUP BY source, class ORDER BY source, class" \
      || echo "email_events: query failed"
  else
    echo "email_events: - (table not created: no history import and no live sends yet; every email read is Klaviyo's)"
  fi
  echo "## messaging Postgres (replica)"
  local db sql
  for db in preferences listmonk notify; do
    case "$db" in
      preferences) sql="SELECT CASE WHEN to_regclass('prefs.contacts') IS NULL THEN '-' ELSE (SELECT count(*)::text FROM prefs.contacts) END AS contacts, CASE WHEN to_regclass('prefs.suppressions') IS NULL THEN '-' ELSE (SELECT count(*)::text FROM prefs.suppressions) END AS suppressions" ;;
      listmonk)    sql="SELECT (SELECT count(*) FROM subscribers) AS subscribers, (SELECT count(*) FROM lists) AS lists, (SELECT count(*) FROM campaigns) AS campaigns" ;;
      notify)      sql="SELECT (SELECT count(*) FROM notify.feed_items) AS feed_items, (SELECT count(DISTINCT user_id) FROM notify.feed_items) AS feed_users, (SELECT count(*) FROM notify.push_tokens) AS push_tokens" ;;
    esac
    echo "# $db"
    pg_run "$db" "$sql" 2>/dev/null || echo "$db: - (unreachable or schema not migrated)"
  done
}

[ $# -ge 1 ] || usage
sub="$1"; shift
case "$sub" in
  coverage) cmd_coverage "$@" ;;
  router)   cmd_router "$@" ;;
  ch)       cmd_ch "$@" ;;
  pg)       cmd_pg "$@" ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
