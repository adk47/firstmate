#!/usr/bin/env bash
# Bound OpenClaw's otherwise-unbounded protected Slack-thread session index.
#
# Upstream maintenance deliberately protects Slack channel thread keys,
# so pruneAfter and maxEntries never remove them. This script selects only
# terminal, inactive Slack thread sessions and deletes them through the running
# gateway's sessions.delete lifecycle API. The API serializes store writes,
# archives transcripts, rejects active work, and compares the session id and
# updatedAt captured by the listing so a thread revived during the sweep wins.
# Channel roots, DMs, synthetic sessions and every :cron: key are outside the
# exact candidate pattern and can never be selected.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/version-compare.sh
source "$SCRIPT_DIR/lib/version-compare.sh"
# shellcheck source=lib/maintenance-flag.sh
source "$SCRIPT_DIR/lib/maintenance-flag.sh"

OPENCLAW_BIN="${OPENCLAW_BIN:-openclaw}"
PROFILE="main"
MODE="dry-run"
RETENTION_DAYS="${SESSION_THREAD_RETENTION_DAYS:-14}"
MAX_DELETES="${SESSION_THREAD_MAX_DELETES:-100}"
NOW_MS="${SESSION_THREAD_NOW_MS:-$(date +%s%3N)}"

usage() {
  cat <<'EOF'
Usage: prune-completed-slack-thread-sessions.sh [--profile main|edge] [--apply]

Default is a read-only dry run. --apply archives and removes eligible session
entries through the selected profile's running gateway.
EOF
}

while (($#)); do
  case "$1" in
    --profile)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      PROFILE="$2"
      shift 2
      ;;
    --apply)
      MODE="apply"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$PROFILE" in main|edge) ;; *) echo "--profile must be main or edge" >&2; exit 2 ;; esac

# Stand down while the gateway is deliberately down (maintenance window) or
# warming up after a deploy restart; this timer pages via OnFailure and would
# otherwise report a non-actionable failure. Fail-safe: absent/expired/malformed
# flags read as "not active".
if maintenance_active; then
  echo "prune: maintenance: $(maintenance_reason) - skipping"
  exit 0
fi
if deploy_window_active; then
  echo "prune: deploy window: $(deploy_window_reason) - skipping"
  exit 0
fi
[[ "$RETENTION_DAYS" =~ ^[1-9][0-9]{0,3}$ ]] || { echo "SESSION_THREAD_RETENTION_DAYS must be 1..3650" >&2; exit 2; }
[[ "$MAX_DELETES" =~ ^[1-9][0-9]{0,3}$ ]] || { echo "SESSION_THREAD_MAX_DELETES must be 1..1000" >&2; exit 2; }
[[ "$NOW_MS" =~ ^[1-9][0-9]{0,15}$ ]] || { echo "SESSION_THREAD_NOW_MS must be a safe positive epoch in milliseconds" >&2; exit 2; }

retention_days_num=$((10#$RETENTION_DAYS))
max_deletes_num=$((10#$MAX_DELETES))
now_ms_num=$((10#$NOW_MS))
((retention_days_num <= 3650)) || { echo "SESSION_THREAD_RETENTION_DAYS must be 1..3650" >&2; exit 2; }
((max_deletes_num <= 1000)) || { echo "SESSION_THREAD_MAX_DELETES must be 1..1000" >&2; exit 2; }
((now_ms_num <= 9007199254740991)) || { echo "SESSION_THREAD_NOW_MS exceeds JSON's safe integer range" >&2; exit 2; }

cutoff_ms=$((now_ms_num - retention_days_num * 86400000))
((cutoff_ms >= 0 && cutoff_ms < now_ms_num)) || { echo "retention cutoff is outside the safe epoch range" >&2; exit 2; }

run_openclaw() {
  # A caller (including another agent process) may carry main's state-dir env.
  # Those variables outrank --profile, so clear them before selecting a profile;
  # otherwise the edge pass silently operates on main a second time.
  env -u OPENCLAW_STATE_DIR -u OPENCLAW_CONFIG_PATH -u OPENCLAW_PROFILE \
    -u OPENCLAW_GATEWAY_URL -u OPENCLAW_GATEWAY_PORT \
    -u OPENCLAW_GATEWAY_TOKEN -u OPENCLAW_GATEWAY_PASSWORD \
    OPENCLAW_HOME=/root \
    "$OPENCLAW_BIN" --profile "$PROFILE" "$@"
}

# openclaw >= 2026.8's sessions.delete rejects our 7.1-era `requireInactive`
# param outright (INVALID_REQUEST: "unexpected property 'requireInactive'"),
# failing every delete on that runtime (staging-verified 2026-08-31 against a
# live 2026.8.1 gateway — Gate E). It is not needed there either: the delete
# path runs under runExclusiveSessionLifecycleMutation +
# prepareSessionLifecycleDrain and natively refuses to delete a session with
# active work, throwing a retryable "could not safely stop before deletion"
# instead — so the dist patch requireInactive existed to backport is retired
# on 2.0. expectedSessionId/expectedSessionUpdatedAt (the real revival-race
# guard) are unaffected either way and stay in the payload on both runtimes.
# Routed through run_openclaw (not version-compare.sh's own hardcoded
# `openclaw --version`) so this respects OPENCLAW_BIN/--profile exactly like
# every other call this script makes, and so it is stubbable the same way.
RUNTIME_VER="$(run_openclaw --version 2>/dev/null | awk 'NR==1 {print $2}')" || RUNTIME_VER=""
# QA bot finding (PR #897 round 2): emptiness alone is not the full check —
# any NON-empty token (e.g. a mangled "OpenClaw 2026.invalid" whose second
# awk field is "2026.invalid") used to pass through untouched, and
# version_at_least's sort -V comparison on a non-version-shaped token is
# unspecified, silently selecting whichever payload shape sort -V happens to
# order it under. Validate the token looks like a real version first.
if [[ -z "$RUNTIME_VER" || ! "$RUNTIME_VER" =~ ^[0-9]{4}(\.[0-9]+)+$ ]]; then
  echo "could not determine openclaw runtime version (\`openclaw --version\` returned nothing/unparseable: '${RUNTIME_VER}') — refusing to guess which sessions.delete payload shape this gateway expects (a wrong guess fails every delete on >= 2026.8, or is silently rejected as unrecognized below it)" >&2
  exit 2
fi
PRUNE_2026_8_PLUS=0
if version_at_least "2026.8" "$RUNTIME_VER"; then
  PRUNE_2026_8_PLUS=1
fi

rc=0
# Keep stderr OUT of the JSON capture. openclaw >= 2026.8 prints a config-migration
# notice ("Moved agents.list to keyed agents.entries.") to stderr on EVERY CLI call
# while the on-disk config still uses the old shape, so `2>&1` prepended two prose
# lines to the payload and the `.sessions` check below failed on every run — the
# retention sweep has not pruned anything since the 2026.8.2 cutover. stderr is still
# captured, just separately, so a genuine failure keeps its diagnostic.
sessions_err="$(mktemp)"
sessions_json=$(run_openclaw sessions --all-agents --json --limit all 2>"$sessions_err") || rc=$?
sessions_stderr="$(cat "$sessions_err" 2>/dev/null)"
rm -f "$sessions_err"
if ((rc != 0)) || ! jq -e '.sessions | type == "array"' >/dev/null 2>&1 <<<"$sessions_json"; then
  # Bash substring, not `printf | head -c`: under `set -euo pipefail` head closes the
  # pipe at the limit, printf takes SIGPIPE (141), and pipefail made THAT the exit
  # status — so this error path aborted the script with a bare "write error: Broken
  # pipe" and the SESSION_LIST_FAILED diagnostic it exists to emit was never printed.
  detail="${sessions_json:0:500}"
  err_detail="${sessions_stderr:0:500}"
  jq -nc --arg profile "$PROFILE" --arg detail "$detail" --arg stderr "$err_detail" --argjson exit "$rc" \
    '{error:"SESSION_LIST_FAILED",profile:$profile,exit:$exit,detail:$detail,stderr:$stderr}'
  exit 1
fi

eligible_json=$(jq -c --argjson cutoff "$cutoff_ms" '
  [ .sessions[]
    | select((.key // "") | test("^agent:[^:]+:slack:channel:[cg][a-z0-9]+:thread:[0-9]+\\.[0-9]+$"; "i"))
    | select(.status == "done" or .status == "failed" or .status == "killed" or .status == "timeout")
    | select((.updatedAt | type) == "number")
    | select(.updatedAt < $cutoff)
    | select((.agentId | type) == "string" and (.agentId | length) > 0)
    | select((.sessionId | type) == "string" and (.sessionId | length) > 0)
    | {key, agentId, sessionId, updatedAt}
  ] | sort_by(.updatedAt)
' <<<"$sessions_json")

eligible=$(jq 'length' <<<"$eligible_json")
selected_json=$(jq -c --argjson max "$max_deletes_num" '.[:$max]' <<<"$eligible_json")
selected=$(jq 'length' <<<"$selected_json")

if [[ "$MODE" == "dry-run" ]]; then
  jq -nc --arg mode "$MODE" --arg profile "$PROFILE" \
    --argjson retention_days "$retention_days_num" --argjson cutoff_ms "$cutoff_ms" \
    --argjson eligible "$eligible" --argjson selected "$selected" \
    --argjson candidates "$selected_json" \
    '{mode:$mode,profile:$profile,retention_days:$retention_days,cutoff_ms:$cutoff_ms,
      eligible:$eligible,selected:$selected,deleted:0,raced:0,failed:0,candidates:$candidates}'
  exit 0
fi

deleted=0
raced=0
failed=0
errors='[]'

while IFS= read -r candidate; do
  key=$(jq -r '.key' <<<"$candidate")
  agent_id=$(jq -r '.agentId' <<<"$candidate")
  session_id=$(jq -r '.sessionId' <<<"$candidate")
  updated_at=$(jq -r '.updatedAt' <<<"$candidate")
  if ((PRUNE_2026_8_PLUS)); then
    params=$(jq -nc --arg key "$key" --arg agent "$agent_id" --arg session "$session_id" \
      --argjson updated "$updated_at" '
        {key:$key,agentId:$agent,expectedSessionId:$session,
         expectedSessionUpdatedAt:$updated,deleteTranscript:true}
      ')
  else
    params=$(jq -nc --arg key "$key" --arg agent "$agent_id" --arg session "$session_id" \
      --argjson updated "$updated_at" '
        {key:$key,agentId:$agent,expectedSessionId:$session,
         expectedSessionUpdatedAt:$updated,requireInactive:true,deleteTranscript:true}
      ')
  fi

  rc=0
  response=$(run_openclaw gateway call sessions.delete \
    --json --timeout 30000 --params "$params" 2>&1) || rc=$?
  if ((rc == 0)) && jq -e '.ok == true' >/dev/null 2>&1 <<<"$response"; then
    deleted=$((deleted + 1))
  elif grep -qiE 'changed before deletion|still active|could not safely stop before deletion' <<<"$response"; then
    raced=$((raced + 1))
  else
    failed=$((failed + 1))
    detail=$(printf '%s' "$response" | head -c 500)
    errors=$(jq -c --arg key "$key" --arg detail "$detail" --argjson exit "$rc" \
      '. + [{key:$key,exit:$exit,detail:$detail}]' <<<"$errors")
    # A transport or gateway failure is infrastructural, not candidate-specific.
    # Stop instead of spending another 30 seconds on every remaining candidate.
    break
  fi
done < <(jq -c '.[]' <<<"$selected_json")

jq -nc --arg mode "$MODE" --arg profile "$PROFILE" \
  --argjson retention_days "$retention_days_num" --argjson cutoff_ms "$cutoff_ms" \
  --argjson eligible "$eligible" --argjson selected "$selected" \
  --argjson deleted "$deleted" --argjson raced "$raced" --argjson failed "$failed" \
  --argjson errors "$errors" \
  '{mode:$mode,profile:$profile,retention_days:$retention_days,cutoff_ms:$cutoff_ms,
    eligible:$eligible,selected:$selected,deleted:$deleted,raced:$raced,failed:$failed,errors:$errors}'

# ── Exit status: page on a real problem, not on a self-healing one ──────────
#
# `failed` is 0 or 1 by construction -- the loop above BREAKS on the first
# failure -- so a failure RATE is meaningless here. The only question is
# whether that one failure is worth waking someone.
#
# A gateway transport timeout is infrastructural and self-healing: the session
# is left untouched and stays ELIGIBLE, so the next 6h run retries it and
# nothing is lost. Measured 2026-09-17: the gateway saturated during a deploy,
# one delete hit `gateway timeout after 30000ms` AFTER 5 successful deletions,
# and this unit paged `Result=exit-code` with nothing for a human to do --
# while the SAME saturation was already paging loudly through the deploy
# rollback. Two pages, one cause, one of them actionable.
#
# So: page when the run made NO progress, or when the failure is not a
# recognised transient. An unclassifiable failure PAGES (fail closed) -- the
# tolerance is deliberately narrow, because "we could not classify it" must
# never become "we assumed it was fine".
if ((failed == 0)); then
  exit 0
fi
# `length > 0` is DEFENSIVE, not load-bearing today: `failed > 0` guarantees
# `errors` is non-empty (both are set in the same branch above), so no test can
# falsify it -- its mutation stays green and that is expected. It is here
# because jq's `all` returns TRUE for an empty array, so if the loop ever stops
# appending to `errors` this tolerance would silently accept EVERY failure.
# The match requires an actual TIMEOUT, not merely a transport error. An
# earlier cut used an alternation, so a structured
# `{"type":"gateway_transport_error","kind":"protocol"}` (a malformed
# response) also satisfied it and suppressed the page — broader than the
# "deliberately narrow" tolerance this is supposed to be. QA finding on #979.
if ((deleted > 0)) && jq -e '
      length > 0 and all(.[]; (.detail // "") as $d
        | ($d | test("gateway timeout after [0-9]+ms"))
          or (($d | test("\"type\"[[:space:]]*:[[:space:]]*\"gateway_transport_error\""))
              and ($d | test("\"kind\"[[:space:]]*:[[:space:]]*\"timeout\""))))
    ' >/dev/null 2>&1 <<<"$errors"; then
  echo "prune: deleted $deleted, then a TRANSIENT gateway failure ended the run early. The remaining candidates stay eligible and the next run retries them -- not paging." >&2
  exit 0
fi
exit 1
