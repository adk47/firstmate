#!/usr/bin/env bash
# runlog.sh — write JSONL batch run logs.
#
# Usage:
#   runlog.sh init                         # prints run_id, creates file + latest.txt
#   runlog.sh event <run_id> <name> <json> # appends one event line
#
# Env:
#   OPS_RUNLOG_DIR   required — base dir (e.g. api-logs/credit-batch-runs)

set -euo pipefail

require_env() {
  if [[ -z "${OPS_RUNLOG_DIR:-}" ]]; then
    echo "ERROR: OPS_RUNLOG_DIR is not set" >&2
    exit 2
  fi
}

gen_short_uuid() {
  # 6 hex chars — plenty of entropy for per-second disambiguation
  if command -v uuidgen >/dev/null; then
    uuidgen | tr -d '-' | cut -c1-6 | tr '[:upper:]' '[:lower:]'
  else
    head -c 3 /dev/urandom | xxd -p
  fi
}

log_path_for_run() {
  local run_id="$1"
  local day="${run_id:0:8}"   # YYYYMMDD from run_id prefix
  local dir="${OPS_RUNLOG_DIR}/${day:0:4}-${day:4:2}-${day:6:2}"
  mkdir -p "$dir"
  echo "${dir}/${run_id}.jsonl"
}

cmd_init() {
  require_env

  # R4-2: refuse to init a second run when OPS_RUN_ID is already set in this
  # shell. A subagent inherits env from its parent — two runlog inits for one
  # batch intent produce two parallel run_ids, two .results.jsonl files, two
  # reconciliation windows, and main-vs-subagent recovery confusion on
  # token-limit timeouts (2026-04-23 14:20 UTC). Fail closed here. The agent
  # can always unset OPS_RUN_ID deliberately if it really means to start
  # a fresh run in the same shell (rare; reserved for tests).
  if [[ -n "${OPS_RUN_ID:-}" ]]; then
    cat >&2 <<EOF
ERROR: runlog.sh init refused — OPS_RUN_ID is already set to '${OPS_RUN_ID}'.
This shell is already inside an active batch run. A second runlog init would
create a parallel run with a distinct run_id, splitting the truth floor and
producing a silent failure class.

Common causes:
  * A subagent was spawned mid-batch and inherited OPS_RUN_ID from its parent.
    Per SKILL.md B0 HARD RULE, batch processing (B0-B6) must run in the main
    agent's turn — do not use agent() / subagent-spawn.
  * A nested 'bash runlog.sh init' in the same exec block. Only call init
    once at B0c; subsequent events use 'runlog.sh event <run_id> ...'.

If you truly need a fresh run (rare — usually a test harness): explicitly
\`unset OPS_RUN_ID\` before calling init, acknowledging the parent run is
abandoned.
EOF
    return 4
  fi

  # Mechanical enforcement of the SKILL.md B0a rule: when OPS_DRY_RUN=1, the
  # dry-run channel env MUST be set and non-empty. Prose alone ("abort at
  # B0a if unset") is not enforcement — a misbehaving model can skip it and
  # post [DRY RUN] output straight to the prod channel. runlog.sh init is
  # the mandatory first B0c call, so failing here closes the hole before any
  # Slack post or API call runs. Only enforced when we're actually in
  # dry-run mode; prod runs are unaffected.
  case "$(printf %s "${OPS_DRY_RUN:-0}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on)
      if [[ -z "${OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID:-}" ]]; then
        cat >&2 <<EOF
ERROR: OPS_DRY_RUN=1 but OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID is unset.
Dry-run mode must never silently fall back to the prod channel. Set the env
var to the test channel ID (e.g. OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID=
C0TEST... ) before initializing the run. Aborting.
EOF
        return 5
      fi
      ;;
  esac

  local day ts short run_id log
  day=$(date -u +%Y%m%d)
  ts=$(date -u +%H%M%S)
  short=$(gen_short_uuid)
  run_id="${day}-${ts}-${short}"
  log=$(log_path_for_run "$run_id")
  : > "$log"  # create/truncate
  echo "$log" > "${OPS_RUNLOG_DIR}/latest.txt"

  # Dry-run marker (issue #145). When OPS_DRY_RUN=1, stamp a run_header
  # event at file-top so downstream consumers (compute-run-summary.sh,
  # SKILL.md B6 summary poster) can detect dry-run from the log alone,
  # without re-reading env. Non-dry-run runs stay byte-identical to
  # historical behavior (empty file).
  case "$(printf %s "${OPS_DRY_RUN:-0}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on)
      local iso
      iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      jq -n -c --arg rid "$run_id" --arg ts "$iso" \
        '{event:"run_header", run_id:$rid, ts:$ts, dryRun:true}' >> "$log"
      ;;
  esac

  echo "$run_id"
}

cmd_event() {
  require_env
  local run_id="$1"
  local event_name="$2"
  local payload="$3"

  # Validate payload parses as JSON
  if ! echo "$payload" | jq empty 2>/dev/null; then
    echo "ERROR: payload is not valid JSON: $payload" >&2
    exit 3
  fi

  local log iso
  log=$(log_path_for_run "$run_id")
  iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Browser-preflight gate. The 2026-04-20 incident drove this: a manual run
  # logged preflight_browser_unavailable then continued anyway. Mechanically
  # block continuation when the run depends on browser as primary evidence.
  #
  # 2026-05-06 cutover: under CV_EVIDENCE_MODE=api the run does NOT depend
  # on browser as primary — credits clear via API helpers + AllMusic
  # fallback. Demote to a warning so a transient browser failure (Cloudflare
  # spike, SSL hiccup) doesn't strand a run that could clear via APIs.
  # Browser-mode (legacy rollback) keeps the freeze.
  if [[ -f "$log" ]] && jq -e 'select(.event == "preflight_browser_unavailable")' "$log" >/dev/null 2>&1; then
    case "${CV_EVIDENCE_MODE:-api}" in
      browser)
        echo "ERROR: run $run_id is frozen — preflight_browser_unavailable was logged. No further events accepted. SKILL.md B0d requires the turn to exit on pre-flight failure." >&2
        exit 20
        ;;
      api|both)
        # Soft warning: continue under api-mode. Only emit on the first event
        # after the preflight failure to avoid log spam.
        if ! jq -e 'select(.event == "preflight_browser_warning_acknowledged")' "$log" >/dev/null 2>&1; then
          echo "WARN: run $run_id has preflight_browser_unavailable, but CV_EVIDENCE_MODE=${CV_EVIDENCE_MODE:-api} permits continuation via API helpers + AllMusic fallback." >&2
        fi
        ;;
    esac
  fi

  # Cookie-cutter reason gate. 2026-05-04 (run 20260504-103236-97741c1):
  # the agent investigated 1 of 11 fetched profiles, then wrote 28 verdicts
  # with byte-identical reason text ("tier1_unreachable: ... Rob Christie on
  # Fly Me To The Moon") for credits whose actual track titles were My Way,
  # Mack The Knife, Embraceable You, etc. The existing per-profile gate did
  # NOT fire because the magic string "tier1_unreachable" is its bypass —
  # the agent inadvertently weaponized that bypass to fabricate at scale.
  #
  # Refuse to write a verdict / escalation_posted / action_attempted whose
  # `reason` field is byte-identical to ≥CV_RUNLOG_COOKIE_CUTTER_THRESHOLD-1
  # (default 2) earlier events of the same name in the same run — i.e., the
  # 3rd identical-reason event in a row is rejected. Legitimate shared
  # reasons (rate-limited across 2 credits) still pass.
  #
  # Tests bypass via CV_DISABLE_COOKIE_CUTTER_GATE=1. The gate runs BEFORE
  # the per-profile evidence gate so its rejection takes precedence.
  CV_RUNLOG_COOKIE_CUTTER_THRESHOLD="${CV_RUNLOG_COOKIE_CUTTER_THRESHOLD:-3}"
  case "$event_name" in
    verdict|escalation_posted|action_attempted)
      # Tier-0 evidence_kind exemption: Tier-0 bulk-approves emit
      # action_attempted with evidence_kind=tier0_profile_audit and an
      # evidence_excerpt that is the profile_audit:cc=...,pop=...,... receipt.
      # By design these receipts are structurally similar across profiles
      # (same key set, similar threshold values) — the cookie-cutter detector
      # would fire on every Tier-0 batch of ≥3 profiles and reject the very
      # event the post-batch summary needs. Tier-0 has its own
      # anti-fabrication defense: each receipt is independently re-verified
      # against live admin-api data by _tier0_audit_recompute_gate before
      # the PUT lands, and a tier0_audit_verified event is emitted for the
      # browser-evidence-audit cross-check.
      local _ev_kind
      _ev_kind=$(jq -r '.evidence_kind // empty' <<<"$payload" 2>/dev/null)
      if [[ "$_ev_kind" == "tier0_profile_audit" ]]; then
        :  # exempt — fall through to verdict gate below
      elif [[ "${CV_DISABLE_COOKIE_CUTTER_GATE:-0}" != "1" && -f "$log" ]]; then
        local new_reason prior_count
        new_reason=$(jq -r '.reason // empty' <<<"$payload" 2>/dev/null)
        if [[ -n "$new_reason" ]]; then
          prior_count=$(jq -s -r --arg ev "$event_name" --arg r "$new_reason" \
            '[.[] | select(.event == $ev) | select((.reason // "") == $r)] | length' \
            "$log" 2>/dev/null || echo 0)
          if (( prior_count + 1 >= CV_RUNLOG_COOKIE_CUTTER_THRESHOLD )); then
            cat >&2 <<EOF
ERROR: runlog.sh ${event_name} refused (cookie_cutter_reason) — would be the
$((prior_count + 1))th event of this name with byte-identical reason in run
${run_id}, threshold ${CV_RUNLOG_COOKIE_CUTTER_THRESHOLD}.

This shape was the 2026-05-04 fabrication mode: one real investigation
copy-pasted as the verdict reason for 27 unrelated credits. If the verdicts
are genuinely independent failures (e.g. all rate-limited), each reason
must record its own per-credit detail (track id, ISRC, source URL) so the
cookie-cutter gate can distinguish them.

Refused reason text:
  ${new_reason}
EOF
            exit 12
          fi
        fi
      fi
      ;;
  esac

  # Wrapper-pattern detector (api-mode). Run 20260511-080209-d66d3f shipped
  # 153 verdicts labeled INCONCLUSIVE_TIER1_UNREACHABLE from a single bash
  # wrapper the agent wrote at /tmp/cv-batch-run-*.sh. The wrapper ran the
  # whole batch inside one openclaw `process` PTY: no assistant turn fired
  # between credits, so OpenRouter's native web_search plugin never ran,
  # and 0 Tier-2 citations landed in the parent session. All 152 UVN
  # attempts then failed at batch-verify-profile.sh's flag pre-flight
  # (missing_flag_evidence). The runlog cookie-cutter detector did not
  # fire because each reason carried a distinct track title.
  #
  # Under CV_EVIDENCE_MODE=api the `tier1_unreachable` label is mostly
  # legacy — SKILL.md §B3 directs the agent to use SUSPICIOUS_BORDERLINE
  # (UVN) instead, since "Tier-1 unreachable" only describes browser-mode
  # behavior. A small handful may appear when a real Tier-1 helper is
  # genuinely down with no Tier-2 corroboration; many in a row indicates
  # the wrapper pattern. Threshold 5 catches the wrapper while leaving
  # headroom for genuine one-offs.
  #
  # Bypassable via CV_DISABLE_WRAPPER_DETECT_GATE=1 (its own escape hatch,
  # parallel to CV_DISABLE_COOKIE_CUTTER_GATE — so tests that disable the
  # per-profile evidence gate via CV_DISABLE_VERDICT_GATE=1 can still
  # exercise this detector in isolation). Browser-mode is exempt (its own
  # tier1_unreachable_insufficient_effort gate further down catches
  # browser-mode misuse).
  CV_WRAPPER_DETECT_THRESHOLD="${CV_WRAPPER_DETECT_THRESHOLD:-5}"
  case "$event_name" in
    verdict)
      if [[ "${CV_DISABLE_WRAPPER_DETECT_GATE:-0}" != "1" \
            && "${CV_EVIDENCE_MODE:-api}" != "browser" \
            && -f "$log" ]]; then
        local _reason _prior_count
        _reason=$(jq -r '.reason // empty' <<<"$payload" 2>/dev/null)
        if [[ "$_reason" == *"tier1_unreachable"* ]]; then
          _prior_count=$(jq -s -r \
            '[.[] | select(.event == "verdict")
                  | select(((.reason // "") | contains("tier1_unreachable")))] | length' \
            "$log" 2>/dev/null || echo 0)
          if (( _prior_count + 1 >= CV_WRAPPER_DETECT_THRESHOLD )); then
            cat >&2 <<EOF
ERROR: runlog.sh verdict refused (wrapper_pattern_detected) — this would be
the $((_prior_count + 1))th verdict in run ${run_id} with 'tier1_unreachable'
in the reason, threshold ${CV_WRAPPER_DETECT_THRESHOLD}. Under
CV_EVIDENCE_MODE=api this label is reserved for genuine Tier-1 outages and
should be rare; runs that ship N in a row are the bash-wrapper failure
mode (2026-05-11 run 20260511-080209-d66d3f: 153 stamped, 0 UVNs landed).

Under api-mode each UVN/flag credit needs its own assistant turn so
OpenRouter's native web_search plugin can emit Tier-2 citations into this
session's JSONL. A bash wrapper running through openclaw 'process' cannot
trigger the plugin — its UVN attempts will always fail
batch-verify-profile.sh's flag pre-flight (missing_flag_evidence).

Switch to the per-credit inline B3 loop (SKILL.md §B3 api-mode):
  - One assistant turn per credit
  - Tier-1: bash musicbrainz-isrc-lookup.sh <isrc> --credited-name '<name>' --role '<role>'
  - Tier-2: a natural-language research paragraph in the same turn
  - Then call batch-verify-profile.sh once with the resulting decision

Refused reason text:
  ${_reason}
EOF
            exit 13
          fi
        fi
      fi
      ;;
  esac

  # Per-profile evidence gate. Three incidents drove this:
  #   - 100843-d27818 (PR #235): 10 verdicts + 5 escalation_posted in 1 sec
  #     with 0 per-profile browses. Closed by gating verdict/escalation_posted.
  #   - 135646-ecff37 (PR #236): subagent pool failed (browser unavailable in
  #     children + invalid haiku model id), agent panic-finalized 117
  #     action_attempted events at the same second with fabricated
  #     evidence_excerpt = "<track> <role>" strings. action_attempted was the
  #     remaining open channel — closed.
  #   - 135728-2ca2ff (2026-05-04): the bare muso.ai/profile/<uuid> anchor
  #     returned 404 nginx for 5/5 fetched profiles, every credit escalated.
  #     The anchor was always a structural device with no verification value.
  #     This refactor drops it — the gate now requires Tier-1 evidence
  #     (Apple/MusicBrainz/Discogs/AllMusic) whose response
  #     text contains the credited person's name AND either the track title
  #     or a role token. Same anti-fabrication property, no muso website
  #     dependency. See lib/browser-evidence.sh header for the rule.
  #
  # Any gated event carrying a profile_id must have ≥1 Tier-1 host satisfying
  # the rule in the current run window. Bypass: explicit reason matching
  # tier1_unreachable (network/captcha proof). Tests use CV_DISABLE_VERDICT_GATE=1.
  case "$event_name" in
    verdict|escalation_posted|action_attempted)
      if [[ "${CV_DISABLE_VERDICT_GATE:-0}" != "1" ]]; then
        local pid reason
        pid=$(jq -r '.profile_id // empty' <<<"$payload" 2>/dev/null)
        reason=$(jq -r '.reason // empty' <<<"$payload" 2>/dev/null)
        # Only gate when the event names a profile_id — backwards-compat for
        # legacy events that lacked the field.
        if [[ -n "$pid" ]]; then
          local lib_path mode
          mode="${CV_EVIDENCE_MODE:-api}"
          # api/both: source api-evidence.sh and use count_profile_evidence_sources
          # against the credited name as the binding token. browser (legacy):
          # source browser-evidence.sh and use count_profile_browser_loads.
          if [[ "$mode" == "browser" ]]; then
            # shellcheck source=lib/browser-evidence.sh
            lib_path="$(dirname "$0")/lib/browser-evidence.sh"
          else
            # shellcheck source=lib/api-evidence.sh
            lib_path="$(dirname "$0")/lib/api-evidence.sh"
          fi
          if [[ -f "$lib_path" ]]; then
            # shellcheck disable=SC1090
            source "$lib_path"

            # Resolve claim metadata from the most recent profile_group_fetched
            # event for this profile_id. Tests can pre-export CV_PROFILE_*
            # env vars to bypass the lookup. Without metadata the gate fails
            # closed (count=0) — there's no way to prove the claim against
            # response text.
            if [[ -z "${CV_PROFILE_CREDITED_NAME:-}" && -f "$log" ]]; then
              local meta
              meta=$(jq -s -c -r --arg pid "$pid" \
                  '[.[] | select(.event == "profile_group_fetched" and .profile_id == $pid)] | last
                   | (. // {})
                   | {
                       credited_name: (.credited_name // ""),
                       track_title:   (.track_title   // ""),
                       roles:         (.role          // (.roles // ""))
                     }' "$log" 2>/dev/null || echo '{}')
              CV_PROFILE_CREDITED_NAME=$(jq -r '.credited_name // ""' <<<"$meta")
              CV_PROFILE_TRACK_TITLE=$(jq -r '.track_title // ""'   <<<"$meta")
              CV_PROFILE_ROLES=$(jq -r '.roles // ""'               <<<"$meta")
              export CV_PROFILE_CREDITED_NAME CV_PROFILE_TRACK_TITLE CV_PROFILE_ROLES
            fi

            if [[ "$reason" == *"tier1_unreachable"* && "$mode" == "browser" ]]; then
              # tier1_unreachable bypass — refuse single-host give-up + require
              # search-engine fallback per SKILL.md step 1b. The 2026-05-04 17:44
              # run shipped 5 profiles all stamped tier1_unreachable with thin
              # evidence (1 of 5 had multi-host loads, 0 of 5 ran a search).
              # Browser-mode (legacy rollback) only — under api-mode the
              # tier1_unreachable label is meaningless because Tier-1 ≠ browser.
              local attempts searches
              attempts=$(count_profile_tier1_attempts "$pid")
              searches=$(count_profile_web_searches "$pid")
              if (( attempts < 2 || searches < 1 )); then
                cat >&2 <<EOF
ERROR: runlog.sh ${event_name} refused (tier1_unreachable_insufficient_effort)
  — the bypass requires both:
    (a) ≥2 distinct Tier-1 hosts loaded for this profile (got $attempts)
    (b) ≥1 search-engine browser load (duckduckgo / bing / google) whose
        ?q= mentions credited_name or track_title (got $searches)

Resolved claim for this profile (from profile_group_fetched):
  credited_name: '${CV_PROFILE_CREDITED_NAME:-<missing>}'
  track_title:   '${CV_PROFILE_TRACK_TITLE:-<missing>}'
  roles:         '${CV_PROFILE_ROLES:-<missing>}'

Per SKILL.md B3 step 1b, a search-engine browser load MUST be attempted
before invoking tier1_unreachable. Use the \`browser\` tool to load
\`https://duckduckgo.com/?q=<URL-encoded query>\` (or bing.com / google.com)
with the credited_name and track_title in the query. The web_search tool
itself is plugin-blocked in CV sessions; this browser-load is the
sanctioned equivalent.

Per SKILL.md B3 bypass requirements, ≥2 distinct Tier-1 hosts must also
be loaded — single-host give-up is not "unreachable".

If only 1 Tier-1 host was tried OR no search-engine load ran, use the
SUSPICIOUS_BORDERLINE verdict (UVN) instead so a human can review.
The 'tier1_unreachable' label is reserved for cases where multiple
sources were genuinely unreachable (captcha / 5xx / network /
no-result-for-claim) AND the search-engine load returned no credible
corroboration.
EOF
                exit 7
              fi
            else
              local count
              if [[ "$mode" == "browser" ]]; then
                count=$(count_profile_browser_loads "$pid")
              else
                # api-mode: count distinct evidence sources (API-helper
                # hits + Tier-2 native-search citation hostnames) keyed by
                # the credited name. AllMusic browser fallback was removed
                # 2026-05-07. The api-evidence functions take an excerpt
                # as their first arg; CV_PROFILE_CREDITED_NAME is the
                # natural per-profile binding.
                count=$(count_profile_evidence_sources "${CV_PROFILE_CREDITED_NAME:-}")
              fi
              if (( count < 1 )); then
                local label="verdict_without_evidence"
                [[ "$event_name" == "action_attempted" ]] && label="acted_without_investigation"
                local mode_blurb
                if [[ "$mode" == "browser" ]]; then
                  mode_blurb="Tier-1 browser snapshot (music.apple.com / musicbrainz.org / discogs.com / allmusic.com)"
                else
                  mode_blurb="evidence source (API helper hit OR Tier-2 native-search citation)"
                fi
                cat >&2 <<EOF
ERROR: runlog.sh ${event_name} refused (${label}) — no successful
${mode_blurb} found whose response text proves the claim for profile_id
'${pid}' in the current run window.

Resolved claim for this profile (from profile_group_fetched):
  credited_name: '${CV_PROFILE_CREDITED_NAME:-<missing>}'
  track_title:   '${CV_PROFILE_TRACK_TITLE:-<missing>}'
  roles:         '${CV_PROFILE_ROLES:-<missing>}'

CV_EVIDENCE_MODE=${mode}. Under api-mode every per-profile decision must be
backed by at least one of: a *-isrc-lookup.sh API helper invocation whose
toolResult contains the credited name, OR an assistant message carrying a
native-search citation URL whose surrounding text contains the credited
name. AllMusic / browser fallback is no longer counted (removed 2026-05-07).
Set CV_EVIDENCE_MODE=browser to fall back to the legacy Tier-1 browser
quorum (rollback only).
EOF
                exit 7
              fi
            fi
          fi
        fi
      fi
      ;;
  esac

  # Merge the base envelope with the payload
  jq -c --arg ev "$event_name" --arg rid "$run_id" --arg ts "$iso" \
     '. + {event: $ev, run_id: $rid, ts: $ts}' <<< "$payload" >> "$log"
}

case "${1:-}" in
  init) cmd_init ;;
  event) shift; cmd_event "$@" ;;
  *) echo "usage: $0 {init|event <run_id> <name> <json>}" >&2; exit 64 ;;
esac
