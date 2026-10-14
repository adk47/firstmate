#!/usr/bin/env bash
# Find ClickUp profile-merge tickets whose merge already executed (per
# postgresql_core.public.action_log) and close them. Read-only by default;
# pass --apply to actually post + close.
#
# Env:
#   MUSO_BIN           path to the muso CLI (default: muso)
#   CLICKUP_API_KEY    ClickUp personal API token
#   CLICKUP_LIST_ID    ClickUp list id of hydra-action-request board (default: 901000600160)
#   DAYS               look-back window for action_log (default: 90)
#   CLICKUP_API        ClickUp API base (default: https://api.clickup.com/api/v2)
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../lib/clickup-muso.sh
. "$DIR/../../lib/clickup-muso.sh"   # USE_MUSO_CLI=1 routes ClickUp through `muso clickup`

apply=0
days="${DAYS:-90}"
require_customer_replied=1   # default ON: skip tickets where the customer wasn't told
# Comma-separated ClickUp user IDs to add as assignees on every closed ticket.
# Default: Nick (99656609) — give him visibility into automated closures.
# Override with CLOSE_ADD_ASSIGNEES env or --add-assignees flag, or set empty
# to disable the add-assignee step entirely.
add_assignees="${CLOSE_ADD_ASSIGNEES:-99656609}"
while [ $# -gt 0 ]; do
  case "$1" in
    --apply)   apply=1; shift ;;
    --dry-run) apply=0; shift ;;
    --days)    days="$2"; shift 2 ;;
    --skip-customer-reply-check) require_customer_replied=0; shift ;;
    --add-assignees) add_assignees="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
Usage: close-merged-tickets.sh [--dry-run | --apply] [--days N]
       [--skip-customer-reply-check] [--add-assignees ID1,ID2,...]

Default: --dry-run. Prints what would be closed; no side effects.
--apply: posts a comment + sets ClickUp status to "resolved" on each match.
--skip-customer-reply-check: bypass the Intercom audit that skips closure when
  the customer hasn't been told post-merge. Default behavior: keep tickets
  open whose customer has NOT received an admin reply after the merge
  timestamp, and emit them under needs_human_reply so a teammate can message
  the customer before closure on the next sweep run.
--add-assignees: comma-separated ClickUp user IDs to add as assignees on each
  closed ticket (in addition to setting status=resolved). Default value comes
  from \$CLOSE_ADD_ASSIGNEES (default: Nick 99656609); pass an empty string
  to disable.
  Requires MUSOAI_INTERCOM_TOKEN unless --skip-customer-reply-check.
EOF
      exit 0
      ;;
    *) echo "close-merged-tickets: unknown flag: $1" >&2; exit 1 ;;
  esac
done

# Guard SQL interpolation of --days (only place a CLI value reaches Trino raw).
if ! [[ "$days" =~ ^[0-9]+$ ]]; then
  echo "close-merged-tickets: --days must be a non-negative integer, got '$days'" >&2
  exit 1
fi

muso_bin="${MUSO_BIN:-muso}"
clickup_api="${CLICKUP_API:-https://api.clickup.com/api/v2}"
list_id="${CLICKUP_LIST_ID:-901000600160}"
api_key="${CLICKUP_API_KEY:-}"
[ -n "$api_key" ] || { echo "close-merged-tickets: CLICKUP_API_KEY not set" >&2; exit 2; }
# Hard cap on pagination. The ClickUp fetch below is server-side filtered to
# action:profile-merge-tagged tickets (a small set — historically ~26), so this
# should complete in a page or two; hitting the cap means something unusual and
# we should stop, not silently truncate (the board itself holds 4,500+ open
# tasks across all action types). Override with PAGINATION_CAP if you must.
pagination_cap="${PAGINATION_CAP:-20}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/close-merged-tickets.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# Curl wrapper that fails loud on non-2xx — refuses to keep going on 4xx/5xx.
clickup_curl() {
  local method="$1" path="$2" data="${3:-}"
  if [ "${USE_MUSO_CLI:-0}" = 1 ]; then
    clickup_muso "$method" "$path" "$data"   # gated; writes carry --requester + audit
    return
  fi
  local body_file; body_file=$(mktemp)
  local code
  if [ -n "$data" ]; then
    code=$(curl -sS -X "$method" \
      -H "Authorization: $api_key" \
      -H "Content-Type: application/json" \
      --data "$data" \
      -w '%{http_code}' \
      -o "$body_file" \
      "$clickup_api$path")
  else
    code=$(curl -sS -H "Authorization: $api_key" \
      -w '%{http_code}' \
      -o "$body_file" \
      "$clickup_api$path")
  fi
  if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
    echo "close-merged-tickets: ClickUp $method $path returned HTTP $code: $(head -c 500 "$body_file")" >&2
    rm -f "$body_file"
    return 1
  fi
  cat "$body_file"
  rm -f "$body_file"
}

# 1. Recent merges from action_log → NDJSON rows {merge_into, profiles_ids, at}
#    (aliases lowercase on purpose: Trino lowercases unquoted identifiers, so
#    a camelCase alias would come back folded anyway).
merge_sql="
  SELECT
    json_extract_scalar(requestdata, '\$.body.mergeInto') AS merge_into,
    json_format(json_extract(requestdata, '\$.body.profilesIds')) AS profiles_ids,
    CAST(createdat AS varchar) AS at
  FROM postgresql_core.public.action_log
  WHERE route = '/api/v3/admin/profiles/merge'
    AND requestmethod = 'POST'
    AND createdat > current_timestamp - interval '$days' day
"
"$muso_bin" query --format json - <<<"$merge_sql" 2>"$tmp/merges.err" > "$tmp/merges.raw.jsonl" || {
  echo "close-merged-tickets: trino action_log query failed: $(head -3 "$tmp/merges.err")" >&2
  exit 4
}

python3 - "$tmp/merges.raw.jsonl" "$tmp/merges.jsonl" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
parse_errors = 0
with open(src) as f, open(dst, 'w') as out:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
            survivor, losers_raw, at = row["merge_into"], row["profiles_ids"], row["at"]
        except (json.JSONDecodeError, KeyError, TypeError) as e:
            sys.stderr.write(f"close-merged-tickets: skipping malformed NDJSON row {line!r} ({e})\n")
            parse_errors += 1
            continue
        try:
            losers = json.loads(losers_raw) if losers_raw else []
        except json.JSONDecodeError as e:
            sys.stderr.write(f"close-merged-tickets: skipping malformed profilesIds in row "
                             f"survivor={survivor!r} at={at!r}: {losers_raw!r} ({e})\n")
            parse_errors += 1
            continue
        out.write(json.dumps({"mergeInto": survivor, "profilesIds": losers, "at": at}) + "\n")
if parse_errors:
    # Exit non-zero so the bash wrapper aborts before doing ClickUp writes.
    # A chronic action_log shape drift would otherwise silently shrink each
    # nightly run and leave merged tickets open indefinitely.
    sys.stderr.write(f"close-merged-tickets: {parse_errors} action_log rows had unparseable profilesIds; aborting\n")
    sys.exit(8)
PY

merge_count=$(wc -l < "$tmp/merges.jsonl" | tr -d ' ')
echo "close-merged-tickets: pulled $merge_count merges from last $days days" >&2

# 2. Open profile-merge tickets from ClickUp. Server-side filter to the
#    action:profile-merge tag so ClickUp returns only merge tickets, not the
#    whole board — the same filter create_ticket's dedupe lookup uses
#    (plugins/support-tools/src/tools/create-ticket.ts). The tag is set
#    unconditionally by buildTicketTags (ticket-format.ts) on the SAME create
#    path that writes the ---ACTION-REQUEST--- block the client-side select
#    below requires, so this is match-set-equivalent to the old full-board scan.
: > "$tmp/tickets.jsonl"
page=0
while :; do
  if ! resp=$(clickup_curl GET "/list/$list_id/task?archived=false&include_closed=false&page=$page&order_by=created&tags%5B%5D=action%3Aprofile-merge"); then
    exit 5
  fi
  n=$(echo "$resp" | jq '.tasks | length')
  [ "$n" -eq 0 ] && break
  echo "$resp" | jq -c '
    .tasks[]
    | select((.description // "") | test("\"action_type\":\\s*\"profile-merge\""))
    | (.description // "") as $desc
    | ($desc | capture("---ACTION-REQUEST---\\s*(?<j>\\{[\\s\\S]*?\\})\\s*---END-ACTION-REQUEST---").j // "{}") as $jstr
    | ($jstr | fromjson? // {}) as $ar
    | {
        task_id: .id,
        url: .url,
        status: .status.status,
        customer_profile_id: $ar.customer_profile_id,
        customer_email: $ar.customer_email
      }
    | select(.customer_profile_id != null and .customer_profile_id != "")
  ' >> "$tmp/tickets.jsonl"
  page=$((page+1))
  if [ "$page" -ge "$pagination_cap" ]; then
    echo "close-merged-tickets: PAGINATION_CAP=$pagination_cap pages reached (~$((pagination_cap*100)) tasks)." >&2
    echo "close-merged-tickets: backlog is larger than expected. Bumping the cap silently risks DoS-ing ClickUp." >&2
    echo "close-merged-tickets: re-run with PAGINATION_CAP=<N> if this is intended." >&2
    exit 6
  fi
done

ticket_count=$(wc -l < "$tmp/tickets.jsonl" | tr -d ' ')
echo "close-merged-tickets: pulled $ticket_count open profile-merge tickets" >&2

# 3. Pure matching
bash "$DIR/match-stale-tickets.sh" "$tmp/merges.jsonl" "$tmp/tickets.jsonl" > "$tmp/matches.jsonl"
match_count=$(wc -l < "$tmp/matches.jsonl" | tr -d ' ')
echo "close-merged-tickets: $match_count tickets match an executed merge" >&2

# 3b. Per-match Intercom audit. Skip closure for any ticket where the customer
# hasn't received an admin reply after the merge timestamp — closing those
# silently would leave the customer in the dark while we mark our internal
# task done. Default ON; bypass with --skip-customer-reply-check.
: > "$tmp/to_close.jsonl"
: > "$tmp/needs_human_reply.jsonl"
if [ "$require_customer_replied" -eq 1 ]; then
  [ -n "${MUSOAI_INTERCOM_TOKEN:-}" ] || { echo "close-merged-tickets: MUSOAI_INTERCOM_TOKEN not set — pass --skip-customer-reply-check to bypass" >&2; exit 2; }
  while IFS= read -r match; do
    [ -z "$match" ] && continue
    task_id=$(echo "$match" | jq -r '.task_id')
    merge_at=$(echo "$match" | jq -r '.merge_at')
    # Look up email from the parsed tickets list
    email=$(jq -r --arg t "$task_id" 'select(.task_id == $t) | .customer_email' "$tmp/tickets.jsonl" | head -1)
    if [ -z "$email" ] || [ "$email" = "null" ]; then
      # No email on file → can't audit. Surface as needs-human-reply by default.
      echo "$match" | jq -c '. + {needs_human_reply_reason: "no_customer_email"}' >> "$tmp/needs_human_reply.jsonl"
      continue
    fi
    audit_bin="${CHECK_CUSTOMER_REPLIED_BIN:-$DIR/check-customer-replied.py}"
    if python3 "$audit_bin" "$email" "$merge_at" 2>>"$tmp/audit.log"; then
      echo "$match" | jq -c --arg e "$email" '. + {customer_email: $e}' >> "$tmp/to_close.jsonl"
    else
      ec=$?
      # Only exit 1 (script ran, customer NOT told) routes to the
      # no-admin-reply bucket. Anything else (2=transport error,
      # 127=python missing, 137=oom-kill, etc.) is an audit_error so the
      # operator sees there's something to fix instead of treating it as
      # "customer wasn't told."
      if [ "$ec" -eq 1 ]; then
        echo "$match" | jq -c --arg e "$email" '. + {customer_email: $e, needs_human_reply_reason: "no_admin_reply_after_merge"}' >> "$tmp/needs_human_reply.jsonl"
      else
        echo "close-merged-tickets: customer-reply audit error (exit $ec) for $task_id ($email) — leaving open" >&2
        echo "$match" | jq -c --arg e "$email" '. + {customer_email: $e, needs_human_reply_reason: "audit_error"}' >> "$tmp/needs_human_reply.jsonl"
      fi
    fi
  done < "$tmp/matches.jsonl"
  # Surface the audit script's stderr before the EXIT trap wipes tmp.
  # Without this, a transport burst that routed every ticket to audit_error
  # would leave the operator with no diagnostic to triage from.
  if [ -s "$tmp/audit.log" ]; then
    echo "close-merged-tickets: --- audit script stderr (first 30 lines) ---" >&2
    head -30 "$tmp/audit.log" >&2
    echo "close-merged-tickets: --- end audit script stderr ---" >&2
  fi
else
  cp "$tmp/matches.jsonl" "$tmp/to_close.jsonl"
fi

close_count=$(wc -l < "$tmp/to_close.jsonl" | tr -d ' ')
need_count=$(wc -l < "$tmp/needs_human_reply.jsonl" | tr -d ' ')
echo "close-merged-tickets: $close_count safe to close; $need_count need human reply first" >&2

# 4. Print or apply
if [ "$apply" -eq 0 ]; then
  echo "=== DRY RUN — would close these tickets ===" >&2
  cat "$tmp/to_close.jsonl"
  echo "=== DRY RUN — NEEDS HUMAN REPLY (NOT closing) ===" >&2
  cat "$tmp/needs_human_reply.jsonl"
  exit 0
fi

# When applying: only iterate to_close.jsonl
mv "$tmp/to_close.jsonl" "$tmp/matches.jsonl"

# 5. Apply: stamp the machine-readable customer outcome before status=resolved.
#    If either outcome write fails, leave the ticket open. Consumers require
#    both signals, so an interrupted run can never produce a false "all sorted"
#    message or silent close.
closed=0
failed=0
while IFS= read -r match; do
  task_id=$(echo "$match" | jq -r '.task_id')
  merge_at=$(echo "$match" | jq -r '.merge_at')
  matched_by=$(echo "$match" | jq -r '.matched_by')
  pid=$(echo "$match" | jq -r '.customer_profile_id')

  # Replace any stale outcome before marking the customer-visible merge done.
  if ! current_task=$(clickup_curl GET "/task/$task_id"); then
    echo "close-merged-tickets: task read failed for $task_id; refusing to resolve" >&2
    failed=$((failed+1))
    continue
  fi
  while IFS= read -r old_tag; do
    [ -z "$old_tag" ] && continue
    [ "$old_tag" = "customer-outcome:complete" ] && continue
    encoded_tag=$(jq -rn --arg tag "$old_tag" '$tag | @uri')
    if ! clickup_curl DELETE "/task/$task_id/tag/$encoded_tag" '{}' >/dev/null; then
      echo "close-merged-tickets: stale outcome removal failed for $task_id; refusing to resolve" >&2
      failed=$((failed+1))
      continue 2
    fi
  done < <(echo "$current_task" | jq -r '.tags[]?.name | select(startswith("customer-outcome:"))')
  if ! echo "$current_task" | jq -e '[.tags[]?.name] | index("customer-outcome:complete") != null' >/dev/null; then
    if ! clickup_curl POST "/task/$task_id/tag/customer-outcome%3Acomplete" '{}' >/dev/null; then
      echo "close-merged-tickets: customer outcome write failed for $task_id; refusing to resolve" >&2
      failed=$((failed+1))
      continue
    fi
  fi

  # Build the PUT body — resolve status, optionally add assignees.
  if [ -n "$add_assignees" ]; then
    # ClickUp accepts {assignees: {add: [int_id, ...]}}.
    add_body=$(echo "$add_assignees" | tr ',' '\n' | grep -v '^$' \
      | jq -Rcs 'split("\n") | map(select(length > 0)) | map(tonumber)')
    put_body=$(jq -nc --argjson a "$add_body" '{status: "resolved", assignees: {add: $a}}')
  else
    put_body='{"status":"resolved"}'
  fi
  if ! status_resp=$(clickup_curl PUT "/task/$task_id" "$put_body"); then
    echo "close-merged-tickets: status update failed for $task_id; SKIPPING comment to avoid spam" >&2
    failed=$((failed+1))
    continue
  fi

  body="Automated closure by close-merged-tickets.sh — merge for profile \`$pid\` was executed at $merge_at (matched as $matched_by). action_log entry confirms the operation. Closing ticket."
  if ! comment_resp=$(clickup_curl POST "/task/$task_id/comment" \
        "$(jq -n --arg t "$body" '{comment_text: $t, notify_all: false}')"); then
    echo "close-merged-tickets: comment failed for $task_id (status already set to resolved)" >&2
    comment_resp='{}'
  fi

  echo "$match" | jq -c --argjson c "$comment_resp" --argjson s "$status_resp" '. + {comment_resp: $c, status_resp: $s}'
  closed=$((closed+1))
done < "$tmp/matches.jsonl"

echo "close-merged-tickets: closed $closed tickets" >&2
if [ "$failed" -gt 0 ]; then
  echo "close-merged-tickets: $failed tickets failed to update — see stderr above" >&2
  exit 7
fi
