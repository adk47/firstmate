#!/usr/bin/env bash
# lockfile.sh — acquire/release lockfile for credit verification batch runs.
#
# Usage:
#   lockfile.sh acquire [<caller_pid>]
#       exit 0 on success, 10 if held by live PID, 2 on env error.
#       caller_pid: optional. If provided, written to the lockfile so future
#       acquirers can `kill -0` against the *actual long-running batch process*,
#       not this short-lived helper script (which exits the moment acquire
#       returns). Defaults to $$ (the helper's own PID) for backwards compat,
#       but the SKILL.md Batch Mode B0b should pass `$$` from its caller scope:
#           bash "$SKILL_DIR/scripts/lockfile.sh" acquire $$
#   lockfile.sh release
#       removes lockfile; exit 0 even if absent.
#
# Env:
#   OPS_BATCH_LOCK_PATH   required — absolute path to lockfile
#   OPS_WORKSPACE         optional — "operations" (default: unknown)

set -euo pipefail

STALE_SECONDS=$((3*3600 + 30*60))  # 3h30m — sits inside the 4h cron cadence so a SIGKILL-stuck lock is self-stolen by the next tick

require_env() {
  if [[ -z "${OPS_BATCH_LOCK_PATH:-}" ]]; then
    echo "ERROR: OPS_BATCH_LOCK_PATH is not set" >&2
    exit 2
  fi
}

is_pid_alive() {
  local pid="$1"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

is_stale_by_mtime() {
  local file="$1"
  local now mtime age
  now=$(date +%s)
  # macOS and Linux have different stat flags. Try GNU (`-c`) first: on
  # Linux, `stat -f %m` is parsed as `--file-system` and dumps multi-line
  # filesystem info to stdout before failing — that garbage then leaks
  # into the captured value via the `||` fallback's stdout concatenation
  # and breaks the arithmetic below.
  mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file")
  age=$((now - mtime))
  [[ "$age" -ge "$STALE_SECONDS" ]]
}

cmd_acquire() {
  require_env
  # Caller PID: defaults to this helper's PID ($$). The helper exits as soon as
  # acquire returns, so $$ becomes a dead PID immediately — meaning the next
  # acquirer would always treat the lock as dead and rely entirely on the
  # mtime fallback for liveness. Pass the caller's $$ as $1 to fix this.
  local pid_to_record="${1:-$$}"
  if ! [[ "$pid_to_record" =~ ^[0-9]+$ ]]; then
    echo "ERROR: caller_pid must be numeric, got '$pid_to_record'" >&2
    exit 2
  fi

  mkdir -p "$(dirname "$OPS_BATCH_LOCK_PATH")"

  if [[ -f "$OPS_BATCH_LOCK_PATH" ]]; then
    local existing_pid
    existing_pid=$(cut -d: -f1 "$OPS_BATCH_LOCK_PATH" 2>/dev/null || echo "")
    if [[ -z "$existing_pid" ]]; then
      # Malformed lockfile (no PID parseable) — log and steal.
      echo "WARN: malformed lockfile contents at $OPS_BATCH_LOCK_PATH; stealing" >&2
    elif is_pid_alive "$existing_pid"; then
      if is_stale_by_mtime "$OPS_BATCH_LOCK_PATH"; then
        # Live PID but stale mtime — likely a different process reusing the PID.
        # (The held batch process never bumps mtime during a run, so any run
        # legitimately exceeding 3h30m would be self-stolen. The batch never
        # exceeds ~30min in practice, and the 4h cron cadence would re-collide
        # on the tick after anyway.)
        # Safe to steal.
        :
      else
        # Live lock, recent — honor it.
        exit 10
      fi
    fi
    # Dead PID or stale mtime → steal.
  fi

  local workspace="${OPS_WORKSPACE:-unknown}"
  local hostname
  hostname=$(hostname)
  echo "${pid_to_record}:${hostname}:${workspace}" > "$OPS_BATCH_LOCK_PATH"
}

cmd_release() {
  require_env
  local terminal=0
  for arg in "$@"; do
    case "$arg" in --final) terminal=1 ;; esac
  done
  if [[ "${OPS_BATCH_TERMINAL:-0}" == "1" ]]; then
    terminal=1
  fi

  # Mechanical fallback (issue #152, Gap 3). If the bot skipped SKILL.md B6,
  # the runlog has no run_finished event and any Slack summary posted was
  # agent-fabricated instead of derived from the session log. The trap-
  # driven release WAS the last supervised action of the turn, so the
  # fallback used to fire unconditionally on every release.
  #
  # 2026-04-28 15:35:00 UTC update: that unconditional firing caused a
  # premature run_finished_hollow when gpt-5.5 split B0+B1 and B2+ across
  # two exec calls — exec 1's trap fired release, autofill wrote the
  # hollow event 53s before B2 ran. Now the autofill only runs when the
  # caller opts in via `--final` flag or OPS_BATCH_TERMINAL=1 env. The
  # outermost exec at the end of B6 is the only place that should set
  # this; mid-batch traps release without --final and just remove the
  # lockfile.
  #
  # Belt-and-braces: even with --final, autofill_run_finished_if_needed
  # adds a quiescence check so a tight back-to-back trap (within 120s of
  # run_started_queue) still doesn't autofill. Fail-OPEN throughout — any
  # error is logged and the lockfile is still removed.
  if [[ "$terminal" == "1" ]]; then
    autofill_run_finished_if_needed || true
    # R4-3: forensic event when agent bypassed render-slack-summary.sh. Must
    # come AFTER autofill so the run_finished event is already in place (the
    # renderer check is only meaningful when there's a summary to render).
    # 2026-05-07: gated on --final/terminal (was unconditional). On the
    # 2026-05-06/07 batches the detector raced ahead of post-batch-summary.sh
    # — release at 11:00, canonical post at 11:02 — so the session-log scan
    # found nothing on every healthy run and posted a :rotating_light: alert
    # to #credit-verification. Even on the terminal release, the canonical
    # path now goes through `openclaw CLI` from a bash subshell (not the MCP
    # message tool), so the function also short-circuits when post-batch-
    # summary.sh has written its summary_posted_canonical success event.
    emit_renderer_missing_event_if_needed || true
  fi
  rm -f "$OPS_BATCH_LOCK_PATH"
}

# Fail-OPEN. Always returns 0. Only invokes compute-run-summary.sh when
# OPS_RUNLOG_DIR/latest.txt points at a real runlog with a canonical
# run_id filename AND that runlog lacks any run_finished* event.
autofill_run_finished_if_needed() {
  [[ -n "${OPS_RUNLOG_DIR:-}" ]] || return 0
  local latest_idx="${OPS_RUNLOG_DIR}/latest.txt"
  [[ -f "$latest_idx" ]] || return 0

  local runlog_path run_id
  runlog_path=$(cat "$latest_idx" 2>/dev/null || true)
  [[ -n "$runlog_path" && -f "$runlog_path" ]] || return 0

  run_id=$(basename "$runlog_path" .jsonl)
  [[ "$run_id" =~ ^[0-9]{8}-[0-9]{6}-[a-f0-9]+$ ]] || return 0

  # All runlog lines are jq -c compact, so the exact-substring match is
  # safe. Cheaper than jq -e iteration and robust to unparseable lines.
  if grep -Eq '"event":"run_finished(_hollow|_ungrounded)?"' "$runlog_path"; then
    return 0
  fi

  # Quiescence guard (added 2026-04-28). Even when the caller opts in via
  # --final, decline the autofill if the runlog was just written to. A
  # terminal release with a fresh run_started_queue (≤120s old) is almost
  # certainly NOT a terminal release — the caller likely fired --final
  # erroneously, OR the agent is still mid-batch. Better to skip and let
  # the next compute-run-summary call (with --final) handle it cleanly
  # than to write a stale snapshot.
  local now mtime age
  now=$(date +%s)
  mtime=$(stat -c %Y "$runlog_path" 2>/dev/null || stat -f %m "$runlog_path" 2>/dev/null || echo 0)
  age=$((now - mtime))
  if [[ "$age" -lt 120 ]]; then
    echo "[lockfile] runlog mtime is ${age}s old (<120s quiescence window); skipping autofill for run_id=${run_id}" >&2
    return 0
  fi

  local script_dir compute_script
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  compute_script="${script_dir}/compute-run-summary.sh"
  [[ -f "$compute_script" ]] || return 0

  echo "[lockfile] no run_finished event in ${runlog_path}; invoking compute-run-summary.sh as mechanical fallback (run_id=${run_id})" >&2
  # Pass --final so compute-run-summary's in-flight guard does not refuse
  # the call. We've already established this is the terminal release
  # (caller opted in) and the runlog has been quiescent for ≥120s.
  # PARENT_MSG_TS is empty — compute-run-summary accepts it; the
  # summary_post_message_ts field just ends up empty. The forensic value
  # (derived counters, hollow/ungrounded invariants) lands regardless.
  if ! bash "$compute_script" --final "$run_id" "" >/dev/null; then
    echo "[lockfile] compute-run-summary.sh fallback exited non-zero (non-fatal); run_id=${run_id}" >&2
  fi
}

# R4-3: detect when the agent bypassed render-slack-summary.sh.
#
# The 2026-04-23 14:20 UTC dry-run posted 15+ hand-composed messages to the
# main #credit-verification channel instead of the canonical parent+thread
# produced by render-slack-summary.sh — exact regression R2-5 tried to
# prevent with a hard rule. Prose-alone rules don't survive contact with new
# failure modes; this adds mechanical detection at release time.
#
# Scans the current session log for a message(action=send) tool call whose
# text starts with the canonical renderer header ("Credit batch complete —"
# or "[DRY RUN] Credit batch complete —"). If the run had something worth
# summarising (attempts > 0) AND no such send was found, emits a
# `run_finished_renderer_missing` event into the runlog so:
#   * grep of recent runlogs surfaces the regression
#   * future R5 work can wire a real-time Slack alert when a webhook is
#     available (today no webhook is configured, so a runlog event is the
#     strongest signal we can land mechanically)
#   * render-slack-summary.sh can be extended to prepend a warning on the
#     NEXT run if any prior run in the window has this event
#
# Fail-OPEN. Any error is swallowed. Lockfile release never blocks on this.
emit_renderer_missing_event_if_needed() {
  [[ -n "${OPS_RUNLOG_DIR:-}" ]] || return 0
  local latest_idx="${OPS_RUNLOG_DIR}/latest.txt"
  [[ -f "$latest_idx" ]] || return 0

  local runlog_path run_id
  runlog_path=$(cat "$latest_idx" 2>/dev/null || true)
  [[ -n "$runlog_path" && -f "$runlog_path" ]] || return 0
  run_id=$(basename "$runlog_path" .jsonl)
  [[ "$run_id" =~ ^[0-9]{8}-[0-9]{6}-[a-f0-9]+$ ]] || return 0

  # Idempotent: if the event is already present (second release, re-run),
  # don't double-write. Use jq select rather than substring grep so a
  # different event whose payload happens to mention this string can't
  # spoof the check.
  if jq -e -s '[.[] | select(.event == "run_finished_renderer_missing")] | length > 0' \
       "$runlog_path" >/dev/null 2>&1; then
    return 0
  fi

  # Direct evidence beats heuristics. post-batch-summary.sh writes a
  # `summary_posted_canonical` event on a successful parent+thread send;
  # if it's there, the canonical path completed and the session-log
  # heuristic below would only manufacture a false positive (the canonical
  # path goes through `openclaw CLI` from a bash subshell, leaving no MCP
  # `message` toolCall for the scan to find).
  if jq -e -s '[.[] | select(.event == "summary_posted_canonical")] | length > 0' \
       "$runlog_path" >/dev/null 2>&1; then
    return 0
  fi

  # Only meaningful when a run_finished* event is already present (run had
  # work to summarise). Skip when the run aborted at preflight / B0d.5.
  if ! grep -Eq '"event":"run_finished(_hollow|_ungrounded|_silent_failure)?"' "$runlog_path"; then
    return 0
  fi

  # Skip when the run had zero attempts — nothing to summarise, the agent
  # may have legitimately posted only the B5 queue-clear message shape, not
  # the renderer output. We care about the regression where attempts > 0
  # produced hand-composed prose instead of renderer output.
  local fetched approved uvn
  fetched=$(grep -E '"event":"run_finished' "$runlog_path" | head -1 | jq -r '.fetched // 0' 2>/dev/null || echo 0)
  approved=$(grep -E '"event":"run_finished' "$runlog_path" | head -1 | jq -r '.reconciliation.approved_attempted // .approved // 0' 2>/dev/null || echo 0)
  uvn=$(grep -E '"event":"run_finished' "$runlog_path" | head -1 | jq -r '.reconciliation.verification_needed_attempted // .verification_needed // 0' 2>/dev/null || echo 0)
  local total_attempts=$(( approved + uvn ))
  if (( total_attempts == 0 )); then
    return 0
  fi

  # Find the session log — same discovery idiom as the gate.
  local session_log
  if [[ -n "${CV_SESSION_LOG_OVERRIDE:-}" ]]; then
    session_log="$CV_SESSION_LOG_OVERRIDE"
  else
    session_log=$(
      find /root/.openclaw-main/agents \
          -maxdepth 3 -type f -name "*.jsonl" -mmin "-10" 2>/dev/null \
      | while IFS= read -r f; do
          mtime=$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null)
          [[ -n "$mtime" ]] && printf '%s %s\n' "$mtime" "$f"
        done \
      | sort -rn | head -1 | cut -d' ' -f2-
    )
  fi
  [[ -n "$session_log" && -f "$session_log" ]] || return 0

  # Did the agent post a renderer-shaped Slack message? Scan for any
  # message() tool call whose text parameter starts with the canonical
  # renderer parent header. jq-safe across openclaw's minor tool arg shape
  # variations: `text` may be a nested arg or a direct string parameter.
  local found_renderer_post
  found_renderer_post=$(
    jq -s -r '
      [.[]
       | .message?.content[]? // empty
       | select(.type == "toolCall")
       | (.name // "") as $name
       | select($name == "message" or $name == "slack_message" or $name == "send_message")
       | (.arguments.text // .arguments.body // .arguments.markdown // "")
       | select(type == "string")
       | select(. | test("^(\\[DRY RUN\\] )?Credit batch complete "; "m"))
      ] | length
    ' "$session_log" 2>/dev/null || echo 0
  )
  if [[ "${found_renderer_post:-0}" -gt 0 ]]; then
    return 0
  fi

  # No renderer post found — emit the forensic event. Append directly so the
  # runlog.sh freeze-after-preflight gate doesn't interfere (this event is
  # the release's own accounting, not an agent-written event).
  local iso
  iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n -c --arg rid "$run_id" --arg ts "$iso" \
    --argjson fetched "$fetched" \
    --argjson approved "$approved" \
    --argjson uvn "$uvn" \
    '{event:"run_finished_renderer_missing", run_id:$rid, ts:$ts,
      fetched:$fetched, approved_attempted:$approved, verification_needed_attempted:$uvn,
      detail:"Agent bypassed render-slack-summary.sh; Slack posts were hand-composed."}' \
    >> "$runlog_path" 2>/dev/null || {
      echo "[lockfile] failed to emit run_finished_renderer_missing event for run_id=${run_id}" >&2
      return 0
    }
  echo "[lockfile] run_finished_renderer_missing event written for run_id=${run_id} (attempts=${total_attempts}, no renderer-shape Slack post found)" >&2

  # 2026-04-30: post a Slack alert in the same channel/thread so the bypass
  # is visible in real-time, not just buried in the runlog. Belt-and-braces
  # behind the enforcer plugin (block-unsanctioned-batch-message hook):
  # if a future variant slips past the hook, the alert still fires here.
  # Fail-OPEN — alert posting failures are non-fatal.
  emit_renderer_missing_slack_alert "$run_id" "$runlog_path" "$total_attempts"
}

# Post a :rotating_light: Slack alert when the renderer-missing event fires.
# Routes to dry-run channel if the run was dry-run, else prod CV channel.
# Fail-OPEN: any failure (no openclaw CLI, no env, send error) is swallowed.
emit_renderer_missing_slack_alert() {
  local run_id="$1" runlog_path="$2" attempts="$3"

  # Test-environment short-circuit. Belt-and-braces with the openclaw
  # PATH-shadow that helpers.bash::setup_tmp_env installs: even if a
  # future test path bypasses the helper, BATS_TEST_NAME or a /tmp/
  # runlog path is enough to prove we're under bats and must NOT post
  # a real Slack message. Same failure mode as PR #245 (2026-05-06)
  # and 2026-05-07 16:47-16:52 UTC.
  if [[ -n "${BATS_TEST_NAME:-}" ]] || [[ "$runlog_path" == /tmp/* ]]; then
    return 0
  fi

  command -v openclaw >/dev/null 2>&1 || return 0

  local dry_run_flag target_channel profile account
  dry_run_flag=$(jq -s -r 'first(.[] | select(.event | test("^run_finished")) | .dryRun // false) // false' \
                 "$runlog_path" 2>/dev/null || echo false)
  if [[ "$dry_run_flag" == "true" ]]; then
    target_channel="${OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID:-}"
    [[ -z "$target_channel" ]] && return 0
  else
    target_channel="${OPS_CREDIT_VERIFICATION_CHANNEL_ID:-C0APB2CMM7C}"
  fi
  profile="${OPS_OPENCLAW_PROFILE:-main}"
  # --account is REQUIRED for slack sends; without it openclaw can't
  # resolve which account binding owns the channel id and returns
  # channel_not_found. Same issue post-batch-summary.sh hit prior to
  # 2026-04-30. Default matches the operations agent binding.
  account="${OPS_OPENCLAW_ACCOUNT:-operations}"

  local body
  body=":rotating_light: Batch summary did NOT come from the canonical renderer for run \`${run_id}\` (attempts=${attempts}).
The agent posted a hand-composed message instead of using \`render-slack-summary.sh\` via \`post-batch-summary.sh\`.
The numbers in any prior \`[HEARTBEAT-BATCH]\` post in this thread may not match \`.results.jsonl\`.
See runlog: \`${runlog_path}\` (event: \`run_finished_renderer_missing\`)."

  openclaw --profile "$profile" message send \
    --account "$account" \
    --channel slack \
    --target "$target_channel" \
    --message "$body" >/dev/null 2>&1 || {
      echo "[lockfile] renderer-missing Slack alert failed (target=${target_channel} profile=${profile} account=${account}); event still in runlog for grep" >&2
    }
}

case "${1:-}" in
  acquire) shift; cmd_acquire "$@" ;;
  release) shift; cmd_release "$@" ;;
  *) echo "usage: $0 {acquire [<caller_pid>]|release}" >&2; exit 64 ;;
esac
