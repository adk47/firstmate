#!/usr/bin/env bash
# compute-run-summary.sh — derive `run_finished` counters from the active
# openclaw session JSONL (harness-recorded tool calls) instead of trusting
# shell variables the agent maintains. Prevents confabulated summaries like
# the 2026-04-20 incidents where fallback models (then kimi-k2p5 via Fireworks)
# fabricated run_finished counters and skipped B1–B4 entirely while still
# posting a neat summary table. See issue #124.
#
# Usage:
#   compute-run-summary.sh <RUN_ID> <PARENT_MSG_TS>
#
# Behavior:
#   1. Discovers the current session JSONL (filtered to the active workspace —
#      see Env/OPS_WORKSPACE), falling back to mtime-sort within the workspace.
#   2. Parses toolCall/toolResult pairs. Admin-API calls (via muso-admin-api.sh)
#      are identified by (a) the script name in the flattened args AND (b) a
#      response envelope containing `"http_status":N`. Counters derived:
#        preflight_ok          — ≥1 successful `browser` load of the probe URL
#                                whose returned text contains BOTH "musicbrainz"
#                                AND "drake" (case-insensitive) — mirrors the
#                                B0d success criteria exactly.
#        fetched               — unique credit IDs at $.body.items[].id in
#                                successful GET /admin/credit-requests?status=
#                                unverified… responses. Structured JSON parse,
#                                not regex — safe against nested "id" fields.
#        approved              — unique credit IDs listed in the requestIds of
#                                successful status=approved PUTs (HTTP 200).
#        verification_needed   — same for status=user_verification_needed.
#        errors                — admin-API PUTs that either returned HTTP 4xx
#                                or 5xx, OR whose tool call was marked isError,
#                                OR whose response text lacked http_status
#                                entirely (timeout / tool-layer failure).
#   3. Reads runlog events for:
#        escalated             — count of `escalation_posted` events, deduped
#                                by cr_id. Requires SKILL.md B4 to log them.
#        skipped_idempotent    — count of action_attempted with action=
#                                skip_idempotent (inline in B2).
#        skipped_cap           — same for action=skip_cap.
#   4. Writes the `run_finished` event via runlog.sh with derived counters.
#   5. If preflight_ok AND fetched==0, writes `run_finished_hollow` — the
#      hollow-run invariant (catches sessions that passed preflight then
#      skipped all real work, e.g. the 14:51 incident).
#   6. If NOT preflight_ok AND approved+verification_needed > 0, writes
#      `run_finished_ungrounded` — catches the 13:26 incident class (agent
#      substituted web_fetch for the probe then fake-approved credits).
#   7. Prints the computed summary object to stdout on one line. Fields:
#      `hollow:bool`, `ungrounded:bool`, plus counters — so the caller can
#      gate downstream behavior.
#
# Env:
#   OPS_RUNLOG_DIR             required — same as runlog.sh
#   OPS_WORKSPACE              required — must be "operations"; scopes session-log
#                                 discovery to the operations agent dir, ignoring
#                                 stray non-operations agent logs that could win
#                                 the most-recently-modified contest
#   CV_PROBE_URL               optional — override the preflight probe URL;
#                                 default matches SKILL.md B0d
#   CV_SESSION_LOG_OVERRIDE    optional — absolute path to JSONL; used by tests
#   CV_SESSION_MAX_AGE_MIN     optional — default 10, mirrors session-evidence.sh
#
# Exit codes: 0 on success; 2 on missing env / missing args; 3 on missing
# session log; 5 on missing runlog (B0c init was supposed to create it).

set -euo pipefail

# Parse args: support `--final` flag before or after positional args. The flag
# (or OPS_BATCH_TERMINAL=1 env) opts into writing run_finished when the run
# has the in-flight shape (queue_depth_at_start > 0, action_attempted == 0).
# Without it, we refuse — protecting against the lockfile-trap-on-EXIT race
# that fired premature run_finished_hollow at 2026-04-28 15:35:00 UTC, 53s
# before B2 actually ran.
FINAL_FLAG=0
if [[ "${OPS_BATCH_TERMINAL:-0}" == "1" ]]; then
    FINAL_FLAG=1
fi
_positional=()
for _arg in "$@"; do
    case "$_arg" in
        --final) FINAL_FLAG=1 ;;
        *)       _positional+=("$_arg") ;;
    esac
done
set -- "${_positional[@]:-}"
unset _positional _arg

RUN_ID="${1:-}"
PARENT_MSG_TS="${2:-}"

if [[ -z "${OPS_RUNLOG_DIR:-}" ]]; then
    echo "ERROR: OPS_RUNLOG_DIR is not set" >&2
    exit 2
fi
if [[ -z "${OPS_WORKSPACE:-}" ]]; then
    echo "ERROR: OPS_WORKSPACE is not set (expected 'operations')" >&2
    exit 2
fi
if [[ -z "$RUN_ID" ]]; then
    echo "ERROR: RUN_ID (arg 1) is required" >&2
    exit 2
fi

CV_SESSION_MAX_AGE_MIN="${CV_SESSION_MAX_AGE_MIN:-10}"
CV_PROBE_URL="${CV_PROBE_URL:-https://musicbrainz.org/artist/9fff2f8a-21e6-47de-a2b8-7f449929d43f}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Idempotency guard (R2-2) ---
# The 2026-04-23 09:02 UTC dry-run produced TWO run_finished events (09:16:21
# and 09:16:34). Root cause: B3 and B6 both explicitly called this script —
# B3 to source Slack counts, B6 to populate invariant-warning variables.
# Each openclaw exec tool call is a fresh shell, so B3's $SUMMARY_JSON isn't
# visible in B6, and the agent re-derives it by re-invoking us.
#
# The fix is mechanical: if a run_finished event already exists for this
# RUN_ID, print the cached summary to stdout and exit 0 without writing any
# new events. This keeps the caller's $SUMMARY_JSON populated for downstream
# invariant checks without duplicating events in the runlog.
#
# Done before the expensive session-log parsing so the cached path is fast.
_guard_day="${RUN_ID:0:8}"
_guard_runlog_path="${OPS_RUNLOG_DIR}/${_guard_day:0:4}-${_guard_day:4:2}-${_guard_day:6:2}/${RUN_ID}.jsonl"
if [[ -f "$_guard_runlog_path" ]]; then
    _cached_summary=$(jq -s -c 'first(.[] | select(.event == "run_finished"))' "$_guard_runlog_path" 2>/dev/null || true)
    if [[ -n "$_cached_summary" && "$_cached_summary" != "null" ]]; then
        echo "compute-run-summary: run_finished already present for $RUN_ID — returning cached summary, no new events written." >&2
        echo "$_cached_summary"
        exit 0
    fi
fi

# --- In-flight guard (Failure 2 from 2026-04-28 15:35:00 UTC) ---
# When the agent splits B0+B1 and B2+ across multiple exec calls, the bash
# trap-on-EXIT in exec 1 fires lockfile.sh release, which historically called
# this script as a crash-recovery fallback. That wrote a premature
# run_finished_hollow + run_finished_silent_failure 53s before B2 actually
# ran (and successfully moved 25 credits to verification_needed via PUT).
#
# Refuse to write run_finished if the run is plausibly still in flight —
# i.e. queue_depth_at_start > 0 and zero action_attempted events have
# landed. The caller can override with --final (or OPS_BATCH_TERMINAL=1)
# when this IS the terminal call (B6 explicit invocation, or a confirmed
# terminal release).
#
# Empty-queue runs (queue_depth_at_start == 0) are unaffected — guard
# returns immediately and the script proceeds to write a normal queue-clear
# run_finished. This guard only triggers on the exact Failure 2 shape.
if [[ "$FINAL_FLAG" -ne 1 && -f "$_guard_runlog_path" ]]; then
    # Avoid the `grep -c PATTERN || echo 0` antipattern — grep -c emits "0"
    # AND exits 1 on no-match, so combining `||` produces multi-line "0\n0"
    # that breaks numeric comparisons. Count via `|| true` instead, which
    # preserves grep's stdout (a single "0\n" on no-match) without
    # appending.
    _attempts=$(grep -c '"event":"action_attempted"' "$_guard_runlog_path" 2>/dev/null || true)
    _attempts="${_attempts:-0}"
    _qdepth=$(jq -s -r 'first(.[] | select(.event=="run_started_queue") | .queue_depth_at_start // 0) // 0' "$_guard_runlog_path" 2>/dev/null || echo 0)
    if [[ "$_attempts" -eq 0 && "$_qdepth" -gt 0 ]]; then
        echo "compute-run-summary: refusing to write run_finished — queue_depth_at_start=$_qdepth but action_attempted=0; run plausibly still in flight. Pass --final or set OPS_BATCH_TERMINAL=1 to override." >&2
        unset _guard_day _guard_runlog_path _cached_summary _attempts _qdepth
        exit 8
    fi
    unset _attempts _qdepth
fi

unset _guard_day _guard_runlog_path _cached_summary

# Session-log discovery — same mtime idiom as session-evidence.sh, but scoped
# to the active workspace (agent dir) to prevent cross-agent races.
if [[ -n "${CV_SESSION_LOG_OVERRIDE:-}" ]]; then
    session_log="$CV_SESSION_LOG_OVERRIDE"
else
    session_log=$(
        find /root/.openclaw-main/agents \
            -maxdepth 4 -type f -name "*.jsonl" \
            -path "*/agents/${OPS_WORKSPACE}/sessions/*" \
            -mmin "-${CV_SESSION_MAX_AGE_MIN}" 2>/dev/null \
        | while IFS= read -r f; do
            mtime=$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null)
            [[ -n "$mtime" ]] && printf '%s %s\n' "$mtime" "$f"
          done \
        | sort -rn | head -1 | cut -d' ' -f2-
    )
fi

if [[ -z "$session_log" ]] || [[ ! -f "$session_log" ]]; then
    echo "ERROR: no active session log found (workspace=${OPS_WORKSPACE}, mtime <${CV_SESSION_MAX_AGE_MIN}m)" >&2
    exit 3
fi

# Derive counts from session JSONL. Single jq pipeline: parses JSONL, pairs
# toolCalls with toolResults by toolCallId, then filters per tool/response
# shape. Admin-API call *classification* uses the flattened args (tool-agnostic
# with respect to the exec-tool argument schema), but response HTTP status is
# read structurally from the response envelope where available.
session_counts=$(jq -R -n \
    --arg probe "$CV_PROBE_URL" \
    --arg session_log "$session_log" '

    # Named helpers (top-level defs must precede any data pipeline).
    # Extract distinct credit IDs from the `"requestIds":[...]` array in an
    # args chunk. Returns an empty stream if IDs cannot be captured (e.g. the
    # chunk uses bash-variable interpolation like literal [dollar]CR_ID —
    # common in real agent bash). Callers should fall back to per-invocation
    # counting when extraction yields nothing.
    def extract_request_ids:
        scan("\"requestIds\"\\s*:\\s*\\[([^\\]]+)\\]")
        | .[0]
        | scan("\"(cr_[A-Za-z0-9_-]+|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\"")
        | .[0];

    def extract_item_ids:
        # muso-admin-api.sh emits each response envelope as a single compact
        # JSON line starting with `{"http_status":`. So find the first such
        # line in the chunk and parse it. Real admin API nests items at
        # body.data.items; fixtures sometimes use body.items directly.
        . as $chunk
        | ($chunk | split("\n") | map(select(test("^\\s*\\{\"http_status\"")))| .[0] // "") as $line
        | ($line | fromjson? // null) as $j
        | (($j.body?.data?.items?) // ($j.body?.items?) // null) as $items
        | if $items then
              ($items | map(.id // empty) | map(select(. != "")) | .[])
          else
              empty
          end;

    # Parse JSONL, counting parse errors so they are visible forensically.
    [inputs] as $raw_lines
    |
    ([ $raw_lines[] | fromjson? // empty ]) as $lines
    |
    ($raw_lines | length) as $total_lines
    |
    ($lines | length) as $parsed_lines
    |
    ($total_lines - $parsed_lines) as $parse_errors
    |
    # Pair toolCalls with toolResults by walking the JSONL in order.
    # openclaw reuses toolCallId values across agent turns (e.g. `functions.exec:0`
    # recurs on every turn), so a naive id→call map would mispair earlier
    # results with the last-seen call of the same id. Instead, walk line-by-
    # line and record each toolResult against the MOST RECENT preceding
    # toolCall with the same id — that is the call it actually responded to.
    (reduce ($lines[]) as $line
        ({calls: {}, pairs: []};
         ($line.message?.content // []) as $contents
         | (reduce ($contents[] | select(.type == "toolCall")) as $tc
              (.; .calls[$tc.id] = {
                  name: $tc.name,
                  args: $tc.arguments,
                  args_repr: ([$tc.arguments? | .. | strings] | join(" "))
              }))
         | if ($line.message?.role == "toolResult") then
               (.calls[$line.message.toolCallId] // null) as $call
               | if $call != null then
                     .pairs += [{
                         name: $call.name,
                         args: $call.args,
                         args_repr: $call.args_repr,
                         is_error: ($line.message.isError // false),
                         text: (($line.message.content // []) | map(.text // "") | join("\n"))
                     }]
                 else . end
           else . end
        )
    ).pairs as $pairs
    |
    # Preflight: B0d requires an open-probe of the Drake Tier 1 URL and a
    # page-content read that contains BOTH "musicbrainz" AND "drake" (case-
    # insensitive). Two acceptable evidence shapes:
    #
    #   A. Direct browser-tool probe (legacy path). One or more successful
    #      browser opens targeting the probe URL AND one or more browser
    #      toolResults whose text has both markers. Used when the model
    #      tool-schema permits non-broken snapshot args.
    #
    #   B. preflight-verify.sh@cli probe (2026-04-28+). One or more successful
    #      exec calls whose command contains "preflight-verify.sh" AND whose
    #      stdout has both markers. The script runs the openclaw CLI probe
    #      mechanically, bypassing tool-schema defaults like mode=efficient
    #      and depth=0 that produced 0-char snapshots in the 14:24, 14:28,
    #      and 14:51 UTC dry-runs. Markers come from the snapshot stdout the
    #      script prints; a faking agent would still need a real exec result
    #      containing them, which the CLI probe attests.
    #
    # Either path satisfies preflight; the runlog event is written by
    # preflight-verify.sh in both cases.
    (
        # Path A: browser tool with probe URL
        ([ $pairs[]
           | select(.name == "browser")
           | select((.args?.url // "") == $probe
                    or (.args?.url // "") == ($probe + "/")
                    or ((.args?.url // "") | startswith($probe + "?")))
           | select(.is_error | not)
         ] | length > 0)
        or
        # Path B: exec call to preflight-verify.sh that completed without error
        ([ $pairs[]
           | select(.name == "exec")
           | select(.args_repr | test("preflight-verify\\.sh"))
           | select(.is_error | not)
         ] | length > 0)
    ) as $probe_opened
    |
    (
        # Path A: browser tool result with markers
        ([ $pairs[]
           | select(.name == "browser")
           | select(.is_error | not)
           | select((.text | ascii_downcase) | (contains("musicbrainz") and contains("drake")))
         ] | length > 0)
        or
        # Path B: exec call to preflight-verify.sh whose stdout has markers
        ([ $pairs[]
           | select(.name == "exec")
           | select(.args_repr | test("preflight-verify\\.sh"))
           | select(.is_error | not)
           | select((.text | ascii_downcase) | (contains("musicbrainz") and contains("drake")))
         ] | length > 0)
    ) as $probe_rendered
    |
    ($probe_opened and $probe_rendered) as $preflight_ok
    |
    # Admin-API call identification.
    #
    # Agents often bundle multiple admin-api calls (e.g. approve one credit,
    # move another to VN) inside a SINGLE exec bash script. Each invocation
    # writes its own `{"http_status":N,"body":{...}}` envelope to the combined
    # exec output. To classify each invocation individually, we split
    # both the args and the response text on `muso-admin-api.sh` / `"http_status"`
    # boundaries respectively, then pair them positionally. This assumes
    # sequential execution order within the bash block — matches how SKILL.md
    # B2 prescribes the batch loop.
    [
        $pairs[]
        | select(.args_repr | test("muso-admin-api\\.sh"))
        | . as $p
        | ($p.args_repr | split("muso-admin-api\\.sh"; "")[1:] | map("muso-admin-api.sh" + .)) as $arg_chunks
        | ($p.text | split("(?=\\{\"http_status\")"; "")[1:]) as $resp_chunks
        | range(0; $arg_chunks | length) as $i
        | $arg_chunks[$i] as $chunk
        | ($resp_chunks[$i] // "") as $resp_chunk
        | ([$resp_chunk | scan("\"http_status\"\\s*:\\s*([0-9]+)") | .[0] | tonumber] | .[0] // null) as $status
        | {
            status: $status,
            is_tool_error: ($p.is_error and $status == null),
            resp_chunk: $resp_chunk,
            chunk: $chunk,
            is_list_fetch: (($chunk | test("call +GET"))
                and ($chunk | test("status=unverified"))),
            is_put_approved: (($chunk | test("call +PUT"))
                and ($chunk | test("credit-requests"))
                and ($chunk | test("\"status\"\\s*:\\s*\"approved\""))),
            is_put_vn: (($chunk | test("call +PUT"))
                and ($chunk | test("credit-requests"))
                and ($chunk | test("\"status\"\\s*:\\s*\"user_verification_needed\""))),
            is_put_any_cr: (($chunk | test("call +PUT"))
                and ($chunk | test("credit-requests")))
          }
    ] as $api
    |
    # fetched — unique credit IDs across all successful list fetches.
    # Uses per-invocation resp_chunk so nested "id" fields in non-list
    # responses (e.g. track.id, user.id) do not get mis-captured.
    (
        [
            $api[]
            | select(.is_list_fetch and .status == 200)
            | .resp_chunk | extract_item_ids
        ] | unique | length
    ) as $fetched
    |
    # approved / verification_needed — prefer de-dup by extracted credit IDs
    # (literal quoted IDs in the args); fall back to per-invocation count
    # when the agent used bash-variable interpolation (literal [dollar]CR_ID)
    # and no literal IDs can be captured. Either way, the count reflects the
    # number of successful PUTs of the matching status.
    (
        ([$api[] | select(.is_put_approved and .status == 200)]) as $approved_invs
        | ([$approved_invs[] | .chunk | extract_request_ids] | unique) as $ids
        | if ($ids | length) > 0 then ($ids | length)
          else ($approved_invs | length)
          end
    ) as $approved
    |
    (
        ([$api[] | select(.is_put_vn and .status == 200)]) as $vn_invs
        | ([$vn_invs[] | .chunk | extract_request_ids] | unique) as $ids
        | if ($ids | length) > 0 then ($ids | length)
          else ($vn_invs | length)
          end
    ) as $vn
    |
    # errors — broad: any admin-API invocation that (a) returned HTTP 4xx/5xx,
    # (b) was flagged isError by the tool layer, or (c) has no http_status
    # at all (timeout / tool crash / malformed response).
    (
        [
            $api[]
            | select(.is_put_any_cr or .is_list_fetch)
            | select(.is_tool_error
                or (.status == null)
                or (.status != null and .status >= 400))
        ] | length
    ) as $errors
    |
    # Closed-vocabulary tool inventory for forensic events.
    (
        reduce ($pairs[] | .name) as $n
            ({"browser":0, "exec":0, "web_fetch":0, "web_search":0, "message":0, "other":0};
             if has($n) then .[$n] += 1 else .other += 1 end)
    ) as $inventory
    |
    {
        preflight_ok: $preflight_ok,
        fetched: $fetched,
        approved: $approved,
        verification_needed: $vn,
        errors: $errors,
        tool_inventory: $inventory,
        session_log: $session_log,
        parse_errors: $parse_errors,
        lines_parsed: $parsed_lines
    }
' "$session_log")

# Structural sanity check — every expected field must be present and of the
# right type. Catches a broken pipeline that silently emits null.
echo "$session_counts" | jq -e '
    (.preflight_ok | type == "boolean") and
    (.fetched | type == "number") and
    (.approved | type == "number") and
    (.verification_needed | type == "number") and
    (.errors | type == "number") and
    (.parse_errors | type == "number")
' >/dev/null || { echo "ERROR: session_counts pipeline produced malformed output: $session_counts" >&2; exit 6; }

# Pull derived fields out of the jq result.
PREFLIGHT_OK=$(echo "$session_counts" | jq -r '.preflight_ok')
FETCHED=$(echo "$session_counts" | jq -r '.fetched')
APPROVED=$(echo "$session_counts" | jq -r '.approved')
VN=$(echo "$session_counts" | jq -r '.verification_needed')
ERRORS=$(echo "$session_counts" | jq -r '.errors')

# escalated / skipped_idempotent / skipped_cap come from the runlog. These
# are emitted inline by SKILL.md B2 (skipped_*) and B4 (escalation_posted),
# which means they land before the agent could fabricate run_finished.
day="${RUN_ID:0:8}"
runlog_path="${OPS_RUNLOG_DIR}/${day:0:4}-${day:4:2}-${day:6:2}/${RUN_ID}.jsonl"

if [[ ! -f "$runlog_path" ]]; then
    echo "ERROR: runlog $runlog_path does not exist — B0c (runlog.sh init) must precede B6" >&2
    exit 5
fi

# One pass over the runlog for all three counters, deduping escalations by
# cr_id. Fail loud on corrupt lines — swallowing jq parse errors here would
# silently re-introduce the failure class this helper exists to prevent.
runlog_counts=$(jq -s '
    {
        escalated: ([.[] | select(.event == "escalation_posted") | .cr_id] | unique | length),
        skipped_idempotent: ([.[] | select(.event == "action_attempted" and .action == "skip_idempotent")] | length),
        skipped_cap: ([.[] | select(.event == "action_attempted" and .action == "skip_cap")] | length),
        run_started_fetch_size: (first(.[] | select(.event == "run_started") | .fetch_size) // null),
        run_started_queue_depth: (first(.[] | select(.event == "run_started_queue") | .queue_depth_at_start) // null),
        profile_group_fetched_count: ([.[] | select(.event == "profile_group_fetched") | (.count // 0)] | add // 0),
        cli_preflight_ok: (any(.[]; .event == "preflight_ok" and .source == "preflight-verify.sh@cli"))
    }
' "$runlog_path")

ESCALATED=$(echo "$runlog_counts" | jq -r '.escalated')
SKIPPED_IDEMPOTENT=$(echo "$runlog_counts" | jq -r '.skipped_idempotent')
SKIPPED_CAP=$(echo "$runlog_counts" | jq -r '.skipped_cap')

# The CLI preflight helper writes an authoritative runlog event. Prefer that
# event when present; the corresponding stdout can appear in an openclaw
# `process` poll result rather than the original `exec` result when the
# command runs long enough to be backgrounded.
if [[ "$(echo "$runlog_counts" | jq -r '.cli_preflight_ok')" == "true" ]]; then
    PREFLIGHT_OK="true"
fi

# Capture the original session-derived fetched count BEFORE the R2-6
# fallback can overwrite it. The read-side silent-zero check below uses
# this raw signal — the truncation fallback (designed for the 2026-04-23
# 09:02 UTC class) would mask the 2026-04-27 silent-zero class by inferring
# a non-zero fetched from queue_depth, hiding the read-side failure.
SESSION_DERIVED_FETCHED="$FETCHED"

# Fetched-count fallback (R2-6). The 2026-04-23 09:02 UTC dry-run showed
# fetched:0 in the summary even though the agent processed 500 credits.
# Root cause: the list-fetch response is a ~500KB JSON blob and openclaw's
# exec tool truncates to the last 16KB, so the {"http_status":200,"body":
# {"data":{"items":[...]}}} envelope gets sliced off. session_counts.fetched
# then finds no items to count.
#
# Fallback source of truth: run_started.fetch_size (what B0 intended to
# fetch) capped by run_started_queue.queue_depth_at_start (what was
# actually available). That's the "effective fetched" without needing the
# session envelope. Session-derived takes precedence when it's > 0 (real
# IDs observed); fallback fires only when session-derived is 0 AND the
# runlog gives us a usable bound.
if (( FETCHED == 0 )); then
    _fallback_fetch_size=$(echo "$runlog_counts" | jq -r '.run_started_fetch_size // ""')
    _fallback_queue_depth=$(echo "$runlog_counts" | jq -r '.run_started_queue_depth // ""')
    if [[ -n "$_fallback_fetch_size" && "$_fallback_fetch_size" != "null" ]]; then
        if [[ -n "$_fallback_queue_depth" && "$_fallback_queue_depth" != "null" ]] && (( _fallback_queue_depth < _fallback_fetch_size )); then
            FETCHED="$_fallback_queue_depth"
        else
            FETCHED="$_fallback_fetch_size"
        fi
    fi
    unset _fallback_fetch_size _fallback_queue_depth
fi

# Compute the two invariants. `hollow` catches preflight-passed-then-skipped
# runs (14:51 incident class) — defined as preflight OK but ZERO admin-API
# activity whatsoever: no approvals, no VN moves, no errors, no escalations,
# no skip events. A run where the agent attempted actions but they failed
# (errors>0) or where the list response was truncated (fetched=0 but vn>0) is
# NOT hollow — the agent demonstrably did work. `ungrounded` catches
# preflight-failed-then-approved runs (13:26 incident class).
hollow="false"
if [[ "$PREFLIGHT_OK" == "true" ]] \
   && (( APPROVED + VN + ERRORS + ESCALATED + SKIPPED_IDEMPOTENT + SKIPPED_CAP == 0 )); then
    hollow="true"
fi

ungrounded="false"
if [[ "$PREFLIGHT_OK" != "true" ]] && (( APPROVED + VN > 0 )); then
    ungrounded="true"
fi

# Dry-run tag (issue #145). Source of truth is the `run_header` event written
# by runlog.sh init — the log captures the mode the run WAS initialized in,
# independent of whether env got reset between B0c and B6 (cron race, shell
# reset, agent env drift). Only fall back to OPS_DRY_RUN env if the header
# is absent (historical runs from before this PR). The Slack-side poster
# computes any "[DRY RUN]" prefix from this bool — no redundant label field.
DRY_RUN_FLAG=$(jq -s 'first(.[] | select(.event == "run_header") | .dryRun // false) // null' "$runlog_path" 2>/dev/null)
if [[ -z "$DRY_RUN_FLAG" || "$DRY_RUN_FLAG" == "null" ]]; then
    case "$(printf %s "${OPS_DRY_RUN:-0}" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on) DRY_RUN_FLAG=true ;;
        *)             DRY_RUN_FLAG=false ;;
    esac
fi

# --- Results.jsonl reconciliation (PR 2 of 2026-04-22 silent-failure fix) ---
#
# muso-admin-api.sh now writes one JSONL line per /admin/credit-requests
# write (PR #158's truth floor) at four outcome points: rejected_by_gate,
# dry_run_intercept, ok, http_error. This file is authoritative because it
# is written inside the admin script itself — a caller that wraps us in
# `> /dev/null 2>&1` cannot hide the outcome.
#
# The previous session-JSONL derivation has a blind spot: when the agent
# redirects ALL output inside its exec (`approve_cr $id > /dev/null`), the
# session log only captures the outer echo statements (e.g. "T L A
# (VERIFIED): 124 approved"). The session-derived $APPROVED correctly
# reports 0 in that case — but the agent's Slack prose still claims 124.
# We need a signal that the agent ATTEMPTED many approves but none LANDED.
# That signal lives in results.jsonl.
#
# Resolve the results path with the same precedence chain as the truth-
# floor writer: CV_RESULTS_PATH env override first, then the default
# convention under /var/log/openclaw/credit-batch-runs.
day_short="${RUN_ID:0:8}"
day_iso="${day_short:0:4}-${day_short:4:2}-${day_short:6:2}"
results_path="${CV_RESULTS_PATH:-/var/log/openclaw/credit-batch-runs/${day_iso}/${RUN_ID}.results.jsonl}"

# Default reconciled counters. When the file is absent we fall back to
# session-only counts and mark reconciliation_source=session_jsonl_fallback
# so downstream can treat the run with lower confidence.
APPROVED_ATTEMPTED=0
APPROVED_LANDED=0
APPROVED_REJECTED_BY_GATE=0
APPROVED_REJECTED_PRE_FLIGHT=0
APPROVED_HTTP_ERROR=0
UVN_ATTEMPTED=0
UVN_LANDED=0
UVN_HTTP_ERROR=0
RECONCILIATION_SOURCE="session_jsonl_fallback"

if [[ -f "$results_path" ]]; then
    RECONCILIATION_SOURCE="results_jsonl"
    # Single jq pass over the JSONL file: classify every line by
    # intended_status + outcome, then sum request_ids.length (so a batch
    # PUT with 124 ids counts as 124 landed). Uses `jq -s` to slurp and
    # `[inputs | fromjson? // empty]` to skip malformed lines without
    # aborting — same resilience pattern session_counts uses above.
    #
    # R3-final: `rejected_pre_flight` is a distinct category written by
    # batch-verify-profile.sh when its pre-flight refuses to call the
    # admin API. Agent's evidence-gathering step was insufficient — these
    # are NOT the same failure class as gate rejections. Surface both so
    # Slack readers can tell whether the agent tried and the gate refused
    # (rejected_by_gate) vs the agent never even got to try (pre_flight).
    reconciled=$(jq -s -R -c '
        def landed: (.outcome == "ok" or .outcome == "dry_run_intercept");

        [ split("\n")[] | select(length > 0) | fromjson? // empty ] as $rows
        |
        {
            approved_attempted: ([ $rows[] | select(.intended_status == "approved") | (.request_ids | length) ] | add // 0),
            approved_landed:    ([ $rows[] | select(.intended_status == "approved" and landed) | (.request_ids | length) ] | add // 0),
            approved_rejected_by_gate:
                                ([ $rows[] | select(.intended_status == "approved" and .outcome == "rejected_by_gate") | (.request_ids | length) ] | add // 0),
            approved_rejected_pre_flight:
                                ([ $rows[] | select(.intended_status == "approved" and .outcome == "rejected_pre_flight") | (.request_ids | length) ] | add // 0),
            approved_http_error:
                                ([ $rows[] | select(.intended_status == "approved" and .outcome == "http_error") | (.request_ids | length) ] | add // 0),
            uvn_attempted:      ([ $rows[] | select(.intended_status == "user_verification_needed") | (.request_ids | length) ] | add // 0),
            uvn_landed:         ([ $rows[] | select(.intended_status == "user_verification_needed" and landed) | (.request_ids | length) ] | add // 0),
            uvn_http_error:     ([ $rows[] | select(.intended_status == "user_verification_needed" and .outcome == "http_error") | (.request_ids | length) ] | add // 0)
        }
    ' "$results_path" 2>/dev/null || true)

    if [[ -n "$reconciled" ]] && echo "$reconciled" | jq -e . >/dev/null 2>&1; then
        APPROVED_ATTEMPTED=$(echo "$reconciled" | jq -r '.approved_attempted')
        APPROVED_LANDED=$(echo "$reconciled" | jq -r '.approved_landed')
        APPROVED_REJECTED_BY_GATE=$(echo "$reconciled" | jq -r '.approved_rejected_by_gate')
        APPROVED_REJECTED_PRE_FLIGHT=$(echo "$reconciled" | jq -r '.approved_rejected_pre_flight')
        APPROVED_HTTP_ERROR=$(echo "$reconciled" | jq -r '.approved_http_error')
        UVN_ATTEMPTED=$(echo "$reconciled" | jq -r '.uvn_attempted')
        UVN_LANDED=$(echo "$reconciled" | jq -r '.uvn_landed')
        UVN_HTTP_ERROR=$(echo "$reconciled" | jq -r '.uvn_http_error')
    else
        echo "WARN: results.jsonl at $results_path parsed to malformed reconciliation; falling back to session-only counts" >&2
        RECONCILIATION_SOURCE="session_jsonl_fallback"
    fi
fi

# 2026-05-07: when results.jsonl is the reconciliation source, FETCHED
# must equal sum_buckets so the audit's reconciliation invariant holds.
# The 13:32 UTC run hit this: the R2-6 fallback at lines 501-512 set
# FETCHED=500 from run_started.fetch_size (the cap, not the actual
# fetch) because the 200-credit list response exceeded openclaw's 16KB
# truncation window — but results.jsonl said 250 attempts (82 approved +
# 168 UVN). browser-evidence-audit.sh's reconciliation check is
# `fetched - sum_buckets`; with FETCHED=500 and sum_buckets=250 it
# returned mismatch=250, post-batch-summary.sh exited 11, and the
# canonical Slack summary never posted. results.jsonl is the truth
# floor for write counts (PR #158), so derive FETCHED from it when it's
# the source. ESCALATED / SKIPPED_* / ERRORS are runlog-derived and
# already set above (lines 441, 469-471).
if [[ "$RECONCILIATION_SOURCE" == "results_jsonl" ]]; then
    _rj_sum=$((APPROVED_ATTEMPTED + UVN_ATTEMPTED + ESCALATED + SKIPPED_IDEMPOTENT + SKIPPED_CAP + ERRORS))
    if (( _rj_sum > 0 )); then
        FETCHED="$_rj_sum"
    fi
    unset _rj_sum
fi

# Silent-failure invariant: the 2026-04-22 19:15 scenario is exactly
# "attempted >> 0 AND landed == 0" for at least one verb. Either half
# (approve or UVN) triggering is sufficient — we want to catch any silent
# surface, not just the approve path. The 2026-04-27 read-side silent-zero
# class extends this to the fetch path: queue_depth > 0 logged but zero
# items observed in the session.
silent_failure_detected="false"
silent_reason=""
if [[ "$RECONCILIATION_SOURCE" == "results_jsonl" ]]; then
    if (( APPROVED_ATTEMPTED > 0 && APPROVED_LANDED == 0 )); then
        silent_failure_detected="true"
        silent_reason="admin-api attempts >0 but 0 landed (approves or UVN) — agent's Slack prose likely lied about totals"
    elif (( UVN_ATTEMPTED > 0 && UVN_LANDED == 0 )); then
        silent_failure_detected="true"
        silent_reason="admin-api attempts >0 but 0 landed (approves or UVN) — agent's Slack prose likely lied about totals"
    fi
fi

# Read-side silent-zero (2026-04-27 incident class). Fires when B1's
# runlog says there ARE unverified credits but the session shows zero
# items fetched. Independent of RECONCILIATION_SOURCE — it's the FETCH
# that lied, not the writes. Uses SESSION_DERIVED_FETCHED captured before
# the R2-6 truncation fallback so the fallback's queue_depth-based fill
# doesn't mask this case.
#
# Note this is a backstop. The primary defense is fetch-queue.sh's exit
# 11 (unverified_count_items_mismatch), which prevents the bad summary
# from ever getting computed. This branch catches future B1 code paths
# that bypass the script.
if [[ "$silent_failure_detected" != "true" ]]; then
    _q_depth=$(echo "$runlog_counts" | jq -r '.run_started_queue_depth // 0')
    _profile_group_count=$(echo "$runlog_counts" | jq -r '.profile_group_fetched_count // 0')
    if [[ "$_q_depth" =~ ^[0-9]+$ ]] \
       && [[ "$_profile_group_count" =~ ^[0-9]+$ ]] \
       && (( _q_depth > 0 )) \
       && (( _profile_group_count == 0 )) \
       && (( SESSION_DERIVED_FETCHED == 0 )); then
        silent_failure_detected="true"
        silent_reason="read_side_silent_zero: queue_depth_at_start=${_q_depth} but session-derived fetched=0 — B1 fetch silently returned no items despite a non-empty queue"
    fi
    unset _q_depth _profile_group_count
fi

# When results.jsonl is available it takes precedence over session-derived
# counts for the Slack-facing totals. That is the whole point of the truth
# floor: Slack reports what actually HIT the API (or would have, in dry-run),
# not what the agent's prose says. Session-derived counters remain in the
# summary under derived_from so post-mortems can spot when they disagree.
if [[ "$RECONCILIATION_SOURCE" == "results_jsonl" ]]; then
    APPROVED_FOR_SUMMARY="$APPROVED_LANDED"
    VN_FOR_SUMMARY="$UVN_LANDED"
else
    APPROVED_FOR_SUMMARY="$APPROVED"
    VN_FOR_SUMMARY="$VN"
fi

# Re-evaluate invariants after reconciliation. The results.jsonl truth floor
# is authoritative for write counts; otherwise long-running / redirected execs
# can leave session-derived approved/VN at 0 and falsely mark a live run as
# hollow or ungrounded.
hollow="false"
if [[ "$PREFLIGHT_OK" == "true" ]] \
   && (( APPROVED_FOR_SUMMARY + VN_FOR_SUMMARY + ERRORS + ESCALATED + SKIPPED_IDEMPOTENT + SKIPPED_CAP == 0 )); then
    hollow="true"
fi

ungrounded="false"
if [[ "$PREFLIGHT_OK" != "true" ]] && (( APPROVED_FOR_SUMMARY + VN_FOR_SUMMARY > 0 )); then
    ungrounded="true"
fi

# `derived_from` honestly lists the per-field provenance map.
summary=$(jq -n \
    --argjson f "$FETCHED" \
    --argjson a "$APPROVED_FOR_SUMMARY" \
    --argjson v "$VN_FOR_SUMMARY" \
    --argjson a_session "$APPROVED" \
    --argjson v_session "$VN" \
    --argjson a_attempted "$APPROVED_ATTEMPTED" \
    --argjson a_rejected "$APPROVED_REJECTED_BY_GATE" \
    --argjson a_preflight "$APPROVED_REJECTED_PRE_FLIGHT" \
    --argjson a_http_err "$APPROVED_HTTP_ERROR" \
    --argjson v_attempted "$UVN_ATTEMPTED" \
    --argjson v_http_err "$UVN_HTTP_ERROR" \
    --argjson e "$ESCALATED" \
    --argjson si "$SKIPPED_IDEMPOTENT" \
    --argjson sc "$SKIPPED_CAP" \
    --argjson errs "$ERRORS" \
    --argjson preflight "$PREFLIGHT_OK" \
    --argjson hollow "$hollow" \
    --argjson ungrounded "$ungrounded" \
    --argjson silent "$silent_failure_detected" \
    --argjson parse_errors "$(echo "$session_counts" | jq -r '.parse_errors')" \
    --arg ts "$PARENT_MSG_TS" \
    --arg recon_source "$RECONCILIATION_SOURCE" \
    --arg results_path "$results_path" \
    --argjson dry "$DRY_RUN_FLAG" \
    '{
        fetched:$f, approved:$a, verification_needed:$v, escalated:$e,
        skipped_idempotent:$si, skipped_cap:$sc, errors:$errs,
        summary_post_message_ts:$ts, preflight_ok:$preflight,
        hollow:$hollow, ungrounded:$ungrounded,
        silent_failure_detected:$silent,
        reconciliation:{
            source:$recon_source,
            results_path:$results_path,
            approved_attempted:$a_attempted,
            approved_landed:$a,
            approved_rejected_by_gate:$a_rejected,
            approved_rejected_pre_flight:$a_preflight,
            approved_http_error:$a_http_err,
            verification_needed_attempted:$v_attempted,
            verification_needed_landed:$v,
            verification_needed_http_error:$v_http_err,
            session_derived_approved:$a_session,
            session_derived_verification_needed:$v_session
        },
        session_parse_errors:$parse_errors,
        dryRun:$dry,
        derived_from:{
            session_jsonl:["preflight_ok","fetched","errors","session_derived_*"],
            results_jsonl:["approved","verification_needed","approved_attempted","approved_rejected_by_gate","approved_rejected_pre_flight","approved_http_error","silent_failure_detected"],
            runlog:["escalated","skipped_idempotent","skipped_cap"]
        }
    }')

# Write the authoritative run_finished event.
bash "$SCRIPT_DIR/runlog.sh" event "$RUN_ID" run_finished "$summary"

# Write the invariant events when they fire. Both are authoritative forensic
# records — they land regardless of whether the agent executes any Slack
# warning afterwards.
inventory=$(echo "$session_counts" | jq -c '.tool_inventory')

if [[ "$hollow" == "true" ]]; then
    hollow_payload=$(jq -n \
        --argjson summary "$summary" \
        --arg reason "preflight_ok logged but zero fetched items observed in session" \
        --arg log "$session_log" \
        --argjson inv "$inventory" \
        '$summary + {reason:$reason, session_log:$log, tool_inventory:$inv}')
    bash "$SCRIPT_DIR/runlog.sh" event "$RUN_ID" run_finished_hollow "$hollow_payload"
fi

if [[ "$ungrounded" == "true" ]]; then
    ungrounded_payload=$(jq -n \
        --argjson summary "$summary" \
        --arg reason "approve/vn actions logged without successful B0d preflight — likely fabricated evidence" \
        --arg log "$session_log" \
        --argjson inv "$inventory" \
        '$summary + {reason:$reason, session_log:$log, tool_inventory:$inv}')
    bash "$SCRIPT_DIR/runlog.sh" event "$RUN_ID" run_finished_ungrounded "$ungrounded_payload"
fi

# Silent-failure invariant (2026-04-22 incident class). Fires when the
# agent attempted writes but NONE landed — the exact lie shape of the
# 19:15 dry-run that prompted this fix. Payload includes both attempted
# and landed counts so the post-mortem is self-contained.
if [[ "$silent_failure_detected" == "true" ]]; then
    silent_payload=$(jq -n \
        --argjson summary "$summary" \
        --arg reason "$silent_reason" \
        --arg log "$session_log" \
        --argjson inv "$inventory" \
        '$summary + {reason:$reason, session_log:$log, tool_inventory:$inv}')
    bash "$SCRIPT_DIR/runlog.sh" event "$RUN_ID" run_finished_silent_failure "$silent_payload"
fi

# Print the computed summary to stdout so the caller can inspect .hollow /
# .ungrounded / .silent_failure_detected and post appropriate Slack warnings.
echo "$summary"
