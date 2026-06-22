#!/usr/bin/env bash
# muso-read.sh — a READ-ONLY wrapper around the `muso` CLI for the Scout research
# agent. It is an allowlist (reject-by-default) passthrough: only read commands
# reach the real `muso` binary; writes, merges, non-GET `api` calls, and non-SELECT
# Trino queries are refused before `muso` is ever invoked.
#
# This is the SANCTIONED read path for an internal trusted agent — accident-safe
# and the curated read surface. It is NOT a cryptographic boundary: an agent with
# full exec could call `muso` directly. The hard boundary is a scoped read-only
# credential (Muso backend) — tracked as a follow-up.
#
# Usage:
#   muso-read.sh <read-command> [args...]
#   muso-read.sh query "SELECT ... LIMIT 10"
#   muso-read.sh query - <<'SQL'      # SQL via stdin
#   SELECT 1
#   SQL
#
# Allowed (read) commands:
#   health · agent-docs · auth status · api --list-routes
#   profiles search|get · tracks search|get · albums get · users search
#   teams get · claiming list|get
#   api GET <route> [flags]           # GET-only; POST/PUT/PATCH/DELETE are refused
#   query <SELECT-only SQL> | query - # SELECT/WITH/SHOW/DESCRIBE/EXPLAIN/VALUES only
#   nocodb whoami · nocodb tables list|get · nocodb records list|get|count
#   nocodb raw GET <path>             # GET-only; non-GET raw is refused
#                                     # (B2B-ADS-intelligence base; reads only)
#
# Anything else (writes, merges, status changes, deletes, non-GET api, non-SELECT
# query, nocodb record/table writes or non-GET raw) is refused — route Muso writes
# to @Ops and NocoDB writes to @CMO/@Ops.
#
# Env:
#   MUSO_BIN   the muso binary to call (default: muso on PATH). Auth comes from the
#              gateway env (MUSO_ADMIN_*), same as the muso-cli skill.
#
# Exit codes:
#   0  ok (muso's own exit code on a permitted command)
#   2  usage error (no command)
#   3  refused — not a permitted read-only command

set -euo pipefail

MUSO_BIN="${MUSO_BIN:-muso}"

usage() {
  awk 'NR==1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die() {
  echo "muso-read: $*" >&2
  exit 3
}

# assert_select_only <sql> — refuse anything that is not a single read statement.
assert_select_only() {
  local sql="$1" lc stripped first
  lc="$(printf '%s' "$sql" | tr '[:upper:]' '[:lower:]')"

  # 1. No write/DDL verbs anywhere (whole-word match; underscores keep
  #    created_at / update_date / delete_log as single non-matching words).
  #    Input is already lowercased, so no -i needed. This blanket scan is also
  #    what makes `EXPLAIN ANALYZE <write>` safe (the write verb is caught here).
  if printf '%s' "$lc" \
       | grep -qwE 'insert|update|delete|merge|drop|create|alter|truncate|grant|revoke|call'; then
    die "read-only — query contains a write/DDL keyword; SELECT-only is permitted. Route Muso writes to @Ops."
  fi

  # 2. Single statement only (allow one optional trailing ';').
  stripped="$(printf '%s' "$sql" | sed -e 's/;[[:space:]]*$//')"
  if printf '%s' "$stripped" | grep -q ';'; then
    die "read-only — multiple SQL statements are not permitted."
  fi

  # 3. First keyword must be a read keyword (after stripping simple comments).
  #    awk handles leading whitespace and skips blank lines, so no tr/ltrim needed.
  first="$(printf '%s' "$lc" \
    | sed -e 's|/\*[^*]*\*/||g' -e 's/--[^\n]*//' \
    | awk 'NF { print $1; exit }')"
  case "$first" in
    select|with|show|describe|desc|explain|values) : ;;
    *) die "read-only — query must start with SELECT/WITH/SHOW/DESCRIBE/EXPLAIN/VALUES (got '${first:-empty}')." ;;
  esac
}

[ "$#" -gt 0 ] || { echo "muso-read: no command given. See --help." >&2; exit 2; }

case "$1" in
  -h|--help) usage; exit 0 ;;
esac

cmd="$1"
sub="${2:-}"

case "$cmd" in
  health|agent-docs)
    : ;;
  auth)
    [ "$sub" = "status" ] || die "read-only — only 'auth status' is permitted." ;;
  profiles|tracks)
    case "$sub" in
      search|get) : ;;
      *) die "read-only — '$cmd $sub' not permitted (reads: search, get)." ;;
    esac ;;
  albums)
    [ "$sub" = "get" ] || die "read-only — only 'albums get' is permitted." ;;
  users)
    [ "$sub" = "search" ] || die "read-only — only 'users search' is permitted." ;;
  teams)
    [ "$sub" = "get" ] || die "read-only — only 'teams get' is permitted." ;;
  claiming)
    case "$sub" in
      list|get) : ;;
      *) die "read-only — only 'claiming list|get' is permitted." ;;
    esac ;;
  api)
    case "$sub" in
      --list-routes) : ;;
      GET|get) : ;;
      *) die "read-only — 'muso api' is GET-only (got '${sub:-empty}'). Route writes to @Ops." ;;
    esac ;;
  nocodb)
    # READ-ONLY NocoDB (B2B-ADS-intelligence base) via `muso nocodb`. Permit only
    # the read tier — whoami, tables list|get, records list|get|count — plus a
    # GET-only `raw` escape hatch (mirroring `api` above); refuse every record/
    # schema write and non-GET raw. Gate on the verb POSITION only — unlike the
    # SQL `query` path, do NOT keyword-scan flag values (a `--where (Note,like,
    # %delete%)` filter is a read, not a write).
    case "$sub" in
      whoami) : ;;
      tables)
        case "${3:-}" in
          list|get) : ;;
          *) die "read-only — only 'nocodb tables list|get' is permitted. Route NocoDB writes to @CMO/@Ops." ;;
        esac ;;
      records)
        case "${3:-}" in
          list|get|count) : ;;
          *) die "read-only — only 'nocodb records list|get|count' is permitted. Route NocoDB writes to @CMO/@Ops." ;;
        esac ;;
      raw)
        case "${3:-}" in
          GET|get) : ;;
          *) die "read-only — 'nocodb raw' is GET-only (got '${3:-empty}'). Route NocoDB writes to @CMO/@Ops." ;;
        esac ;;
      *) die "read-only — 'nocodb ${sub:-empty}' not permitted (reads: whoami, tables list|get, records list|get|count, raw GET)." ;;
    esac ;;
  query)
    # Parse query's args explicitly: exactly ONE SQL source (a string or '-'),
    # plus an allowlist of safe output-only flags. We must validate the EXACT
    # SQL we forward — forwarding raw "$@" would let a second positional (e.g.
    # `query "SELECT 1" "DELETE FROM t"`) or a flag-first form
    # (`query --format json "<SQL>"`, the documented shape) carry unvalidated
    # SQL to `muso`.
    shift                       # drop 'query'
    sql_src=""; have_src=0; qflags=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --json)      qflags+=("--json"); shift ;;
        --format)    qflags+=("--format" "${2:?--format needs a value}"); shift 2 ;;
        --format=*)  qflags+=("$1"); shift ;;
        -)           [ "$have_src" -eq 0 ] || die "read-only — query takes a single SQL source."
                     sql_src="-"; have_src=1; shift ;;
        -*)          die "read-only — unsupported query flag '$1' (allowed: --json, --format <fmt>)." ;;
        *)           [ "$have_src" -eq 0 ] || die "read-only — query takes a single SQL statement (extra argument '$1')."
                     sql_src="$1"; have_src=1; shift ;;
      esac
    done
    [ "$have_src" -eq 1 ] || die "query needs SQL as an argument (or '-' to read SQL from stdin)."
    if [ "$sql_src" = "-" ]; then
      sql="$(cat)"
      [ -n "$sql" ] || die "query needs SQL on stdin."
      assert_select_only "$sql"
      printf '%s' "$sql" | "$MUSO_BIN" query - ${qflags[@]+"${qflags[@]}"}
      exit "$?"
    fi
    assert_select_only "$sql_src"
    exec "$MUSO_BIN" query "$sql_src" ${qflags[@]+"${qflags[@]}"} ;;
  *)
    die "read-only — '$cmd' is not a permitted read command. Route Muso writes to @Ops." ;;
esac

# Permitted non-query command: hand the original args to the real muso binary.
exec "$MUSO_BIN" "$@"
