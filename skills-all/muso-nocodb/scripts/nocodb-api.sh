#!/usr/bin/env bash
# nocodb-api.sh — NocoDB Cloud v2 REST API wrapper for the muso-nocodb skill.
#
# Reads:
#   NOCODB_API_TOKEN     required — Personal Access Token (xc-token, nc_pat_...)
#   NOCODB_API_URL       default https://app.nocodb.com/api/v2
#   NOCODB_BASE_ID       default p11hvpwapu4hv0x (B2B-ADS-intelligence). Override per call with --base.
#   NOCODB_WORKSPACE_ID  default w8fofvl1 (marketing)
#
# Flags (anywhere before the subcommand):
#   --dry-run     print the curl command instead of executing
#   --raw         emit raw API JSON (skip jq pretty-print)
#   --base <id>   override NOCODB_BASE_ID for this invocation
#
# Subcommands  ────────────────────────────────────────────────────────────
#   auth.me
#   workspaces.ls
#   bases.ls
#   bases.get <baseId>
#   bases.swagger <baseId>                     per-base OpenAPI dump (for self-discovery)
#
#   tables.ls [baseId]
#   tables.get <tableId>
#   tables.create <baseId> <jsonBody>
#   tables.update <tableId> <jsonBody>
#   tables.delete <tableId>
#   tables.duplicate <baseId> <tableId>
#
#   columns.add <tableId> <jsonBody>
#   columns.update <columnId> <jsonBody>
#   columns.delete <columnId>
#   columns.bulk <tableId> <jsonBody>
#   columns.set-primary <columnId>
#
#   views.ls <tableId>
#   views.create <tableId> <grid|form|gallery|kanban|map|calendar> <jsonBody>
#   views.update <viewId> <jsonBody>
#   views.delete <viewId>
#   views.show-all <viewId>
#   views.hide-all <viewId>
#
#   filters.ls <viewId>
#   filters.create <viewId> <jsonBody>
#   filters.update <filterId> <jsonBody>
#   filters.delete <filterId>
#
#   sorts.ls <viewId>
#   sorts.create <viewId> <jsonBody>
#   sorts.update <sortId> <jsonBody>
#   sorts.delete <sortId>
#
#   records.ls <tableId> [--where '...' --sort '...' --fields '...' --limit N --offset N --viewId vw...]
#   records.get <tableId> <recordId>
#   records.create <tableId> <jsonBodyOrArray>
#   records.update <tableId> <jsonBodyOrArray>     (array of {id,...fields})
#   records.delete <tableId> <jsonBodyOrArray>     (array of {id})
#   records.count <tableId> [--where '...']
#   records.link <tableId> <linkColId> <recordId> <jsonArrayOfTargetIds>
#   records.unlink <tableId> <linkColId> <recordId> <jsonArrayOfTargetIds>
#
#   attachments.upload <localFile> [storagePath]                multipart, returns assignable array
#   attachments.upload-by-url <url> <fileName>                  by URL
#
#   hooks.ls <tableId>
#   hooks.create <tableId> <jsonBody>
#   hooks.update <hookId> <jsonBody>
#   hooks.delete <hookId>
#   hooks.test <tableId> <jsonBody>
#   hooks.sample-payload <tableId> <event> <operation>
#   hooks.logs <hookId>
#
#   comments.ls <rowId> <tableId>
#   comments.create <jsonBody>
#   comments.update <commentId> <jsonBody>
#   comments.delete <commentId>
#
#   shared.create-view <viewId> [jsonBody]
#   shared.get <viewId>
#   shared.update <viewId> <jsonBody>
#   shared.delete <viewId>
#
#   raw <METHOD> <pathAfterApiV2> [jsonBody]      escape hatch — auth header added for you
#
# Exit codes: 0 success, 1 usage error, 2 missing env, 3 HTTP error
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

: "${NOCODB_API_URL:=https://app.nocodb.com/api/v2}"
: "${NOCODB_BASE_ID:=p11hvpwapu4hv0x}"
: "${NOCODB_WORKSPACE_ID:=w8fofvl1}"

if [[ -z "${NOCODB_API_TOKEN:-}" ]]; then
  echo "ERROR: NOCODB_API_TOKEN env var not set. Skill requires a NocoDB Personal Access Token (nc_pat_...)." >&2
  exit 2
fi

DRY_RUN=0
RAW=0
PAT="$NOCODB_API_TOKEN"

# Parse global flags before the subcommand.
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --raw)     RAW=1; shift ;;
    --base)    NOCODB_BASE_ID="$2"; shift 2 ;;
    --) shift; ARGS+=("$@"); break ;;
    *)  ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]}"

if [[ $# -lt 1 ]]; then
  sed -n '/^# Subcommands/,/^# Exit codes/p' "$0" >&2
  exit 1
fi

CMD="$1"; shift

# emit_body <raw_with_trailing_status> <http_code> <label>
# Prints the response body in the configured shape; exits 3 on HTTP >= 400.
emit_body() {
  local raw="$1" http_code="$2" label="$3"
  local body="${raw%$'\n'*}"
  if [[ "$RAW" == "1" ]] || ! command -v jq >/dev/null 2>&1; then
    echo "$body"
    echo
  else
    if echo "$body" | jq . >/dev/null 2>&1; then
      echo "$body" | jq .
    else
      echo "$body"
    fi
  fi
  if (( http_code >= 400 )); then
    echo "ERROR: HTTP $http_code from $label" >&2
    exit 3
  fi
}

# do_curl <method> <path> [body]
# Auth header added. Path is appended to NOCODB_API_URL.
do_curl() {
  local method="$1" path="$2" body="${3:-}"
  local url="${NOCODB_API_URL}${path}"
  local curl_args=(-sS -w '\n%{http_code}' -X "$method" -H "xc-token: ${PAT}")
  if [[ -n "$body" ]]; then
    curl_args+=(-H "Content-Type: application/json" -d "$body")
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'DRY-RUN: curl %s "%s"\n' "${curl_args[*]/$PAT/<redacted>}" "$url" >&2
    return 0
  fi
  local raw
  raw=$(curl "${curl_args[@]}" "$url")
  emit_body "$raw" "${raw##*$'\n'}" "$method $path"
}

# do_multipart <localFile> [storagePath]
do_multipart() {
  local file="$1" storage_path="${2:-uploads}"
  local url="${NOCODB_API_URL}/storage/upload?path=${storage_path}"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'DRY-RUN: curl -X POST -H "xc-token: <redacted>" -F "file=@%s" "%s"\n' "$file" "$url" >&2
    return 0
  fi
  local raw
  raw=$(curl -sS -w '\n%{http_code}' -X POST -H "xc-token: ${PAT}" -F "file=@${file}" "$url")
  emit_body "$raw" "${raw##*$'\n'}" "POST /storage/upload"
}

case "$CMD" in
  # ── auth / workspaces / bases ─────────────────────────────────────────
  auth.me)
    # /me lives in v1 only; bypass the v2 prefix for this one.
    if [[ "$DRY_RUN" == "1" ]]; then
      printf 'DRY-RUN: curl -H "xc-token: <redacted>" "https://app.nocodb.com/api/v1/auth/user/me"\n' >&2
      exit 0
    fi
    raw=$(curl -sS -w '\n%{http_code}' -H "xc-token: ${PAT}" "https://app.nocodb.com/api/v1/auth/user/me")
    emit_body "$raw" "${raw##*$'\n'}" "GET /api/v1/auth/user/me"
    ;;
  workspaces.ls)         do_curl GET "/meta/workspaces" ;;
  bases.ls)              do_curl GET "/meta/bases/" ;;
  bases.get)             do_curl GET "/meta/bases/${1:?baseId}" ;;
  bases.swagger)         do_curl GET "/meta/bases/${1:?baseId}/swagger.json" ;;

  # ── tables ────────────────────────────────────────────────────────────
  tables.ls)             do_curl GET "/meta/bases/${1:-$NOCODB_BASE_ID}/tables" ;;
  tables.get)            do_curl GET "/meta/tables/${1:?tableId}" ;;
  tables.create)         do_curl POST "/meta/bases/${1:?baseId}/tables" "${2:?jsonBody}" ;;
  tables.update)         do_curl PATCH "/meta/tables/${1:?tableId}" "${2:?jsonBody}" ;;
  tables.delete)         do_curl DELETE "/meta/tables/${1:?tableId}" ;;
  tables.duplicate)      do_curl POST "/meta/duplicate/${1:?baseId}/table/${2:?tableId}" "{}" ;;

  # ── columns ───────────────────────────────────────────────────────────
  columns.add)           do_curl POST "/meta/tables/${1:?tableId}/columns" "${2:?jsonBody}" ;;
  columns.update)        do_curl PATCH "/meta/columns/${1:?columnId}" "${2:?jsonBody}" ;;
  columns.delete)        do_curl DELETE "/meta/columns/${1:?columnId}" ;;
  columns.bulk)          do_curl POST "/meta/tables/${1:?tableId}/columns/bulk" "${2:?jsonBody}" ;;
  columns.set-primary)   do_curl POST "/meta/columns/${1:?columnId}/primary" "{}" ;;

  # ── views ─────────────────────────────────────────────────────────────
  views.ls)              do_curl GET "/meta/tables/${1:?tableId}/views" ;;
  views.create)
    tid="${1:?tableId}"; vtype="${2:?viewType}"; body="${3:?jsonBody}"
    case "$vtype" in
      grid)     subpath="grids" ;;
      form)     subpath="forms" ;;
      gallery)  subpath="galleries" ;;
      kanban)   subpath="kanbans" ;;
      map)      subpath="maps" ;;
      calendar) subpath="calendars" ;;
      *) echo "ERROR: viewType must be one of grid|form|gallery|kanban|map|calendar" >&2; exit 1 ;;
    esac
    do_curl POST "/meta/tables/${tid}/${subpath}" "$body"
    ;;
  views.update)          do_curl PATCH "/meta/views/${1:?viewId}" "${2:?jsonBody}" ;;
  views.delete)          do_curl DELETE "/meta/views/${1:?viewId}" ;;
  views.show-all)        do_curl POST "/meta/views/${1:?viewId}/show-all" "{}" ;;
  views.hide-all)        do_curl POST "/meta/views/${1:?viewId}/hide-all" "{}" ;;

  # ── filters / sorts ───────────────────────────────────────────────────
  filters.ls)            do_curl GET "/meta/views/${1:?viewId}/filters" ;;
  filters.create)        do_curl POST "/meta/views/${1:?viewId}/filters" "${2:?jsonBody}" ;;
  filters.update)        do_curl PATCH "/meta/filters/${1:?filterId}" "${2:?jsonBody}" ;;
  filters.delete)        do_curl DELETE "/meta/filters/${1:?filterId}" ;;
  sorts.ls)              do_curl GET "/meta/views/${1:?viewId}/sorts" ;;
  sorts.create)          do_curl POST "/meta/views/${1:?viewId}/sorts" "${2:?jsonBody}" ;;
  sorts.update)          do_curl PATCH "/meta/sorts/${1:?sortId}" "${2:?jsonBody}" ;;
  sorts.delete)          do_curl DELETE "/meta/sorts/${1:?sortId}" ;;

  # ── records ───────────────────────────────────────────────────────────
  records.ls)
    tid="${1:?tableId}"; shift
    qs=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --where)  qs+="${qs:+&}where=$(jq -rn --arg v "$2" '$v|@uri')"; shift 2 ;;
        --sort)   qs+="${qs:+&}sort=$(jq -rn --arg v "$2" '$v|@uri')"; shift 2 ;;
        --fields) qs+="${qs:+&}fields=$(jq -rn --arg v "$2" '$v|@uri')"; shift 2 ;;
        --limit)  qs+="${qs:+&}limit=$2"; shift 2 ;;
        --offset) qs+="${qs:+&}offset=$2"; shift 2 ;;
        --viewId) qs+="${qs:+&}viewId=$2"; shift 2 ;;
        *) echo "ERROR: unknown flag $1 for records.ls" >&2; exit 1 ;;
      esac
    done
    do_curl GET "/tables/${tid}/records${qs:+?$qs}"
    ;;
  records.get)           do_curl GET "/tables/${1:?tableId}/records/${2:?recordId}" ;;
  records.create)        do_curl POST "/tables/${1:?tableId}/records" "${2:?jsonBody}" ;;
  records.update)        do_curl PATCH "/tables/${1:?tableId}/records" "${2:?jsonArray}" ;;
  records.delete)        do_curl DELETE "/tables/${1:?tableId}/records" "${2:?jsonArray}" ;;
  records.count)
    tid="${1:?tableId}"; shift
    qs=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --where) qs+="${qs:+&}where=$(jq -rn --arg v "$2" '$v|@uri')"; shift 2 ;;
        *) shift ;;
      esac
    done
    do_curl GET "/tables/${tid}/records/count${qs:+?$qs}"
    ;;
  records.link)          do_curl POST   "/tables/${1:?tableId}/links/${2:?linkColId}/records/${3:?recordId}" "${4:?jsonArrayOfTargetIds}" ;;
  records.unlink)        do_curl DELETE "/tables/${1:?tableId}/links/${2:?linkColId}/records/${3:?recordId}" "${4:?jsonArrayOfTargetIds}" ;;

  # ── attachments ───────────────────────────────────────────────────────
  attachments.upload)    do_multipart "${1:?localFile}" "${2:-uploads}" ;;
  attachments.upload-by-url)
    url="${1:?url}"; name="${2:?fileName}"
    body=$(jq -nc --arg u "$url" --arg n "$name" '[{url:$u, fileName:$n}]')
    do_curl POST "/storage/upload-by-url" "$body"
    ;;

  # ── hooks ─────────────────────────────────────────────────────────────
  hooks.ls)              do_curl GET "/meta/tables/${1:?tableId}/hooks" ;;
  hooks.create)          do_curl POST "/meta/tables/${1:?tableId}/hooks" "${2:?jsonBody}" ;;
  hooks.update)          do_curl PATCH "/meta/hooks/${1:?hookId}" "${2:?jsonBody}" ;;
  hooks.delete)          do_curl DELETE "/meta/hooks/${1:?hookId}" ;;
  hooks.test)            do_curl POST "/meta/tables/${1:?tableId}/hooks/test" "${2:?jsonBody}" ;;
  hooks.sample-payload)  do_curl GET "/meta/tables/${1:?tableId}/hooks/samplePayload/${2:?event}/${3:?operation}/v2" ;;
  hooks.logs)            do_curl GET "/meta/hooks/${1:?hookId}/logs" ;;

  # ── comments ──────────────────────────────────────────────────────────
  comments.ls)
    rowId="${1:?rowId}"; tid="${2:?tableId}"
    do_curl GET "/meta/comments?row_id=${rowId}&fk_model_id=${tid}"
    ;;
  comments.create)       do_curl POST "/meta/comments" "${1:?jsonBody}" ;;
  comments.update)       do_curl PATCH "/meta/comment/${1:?commentId}" "${2:?jsonBody}" ;;
  comments.delete)       do_curl DELETE "/meta/comment/${1:?commentId}" ;;

  # ── shared views ──────────────────────────────────────────────────────
  shared.create-view)    do_curl POST "/meta/views/${1:?viewId}/share" "${2:-{}}" ;;
  shared.get)            do_curl GET "/meta/views/${1:?viewId}/share" ;;
  shared.update)         do_curl PATCH "/meta/views/${1:?viewId}/share" "${2:?jsonBody}" ;;
  shared.delete)         do_curl DELETE "/meta/views/${1:?viewId}/share" ;;

  # ── escape hatch ──────────────────────────────────────────────────────
  raw)
    method="${1:?METHOD}"; path="${2:?path}"; body="${3:-}"
    [[ "$path" != /* ]] && path="/$path"
    do_curl "$method" "$path" "$body"
    ;;

  *)
    echo "ERROR: unknown subcommand: $CMD" >&2
    sed -n '/^# Subcommands/,/^# Exit codes/p' "$0" >&2
    exit 1
    ;;
esac
