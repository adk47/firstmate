#!/usr/bin/env bash
set -euo pipefail

# cto-nightly-driver.sh — deterministic overnight supervisor for the nightly
# CTO issue-fixer's currently-open PR.
# ===========================================================================
# Fired every ~30 min by cto-nightly-driver.timer on node-8. It supervises AT
# MOST one open "nightly PR", tracked in $CTO_NIGHTLY_STATE_DIR/current.json
# ({issue, pr, journey_ts, fix_turns, opened_at}), written by the cto agent's
# OPEN turn. Pure gh/jq/bash — the only LLM involvement is dispatching a
# bounded cto "FIX PASS" one-shot turn when there is actual, mechanically
# detected work (a delta) to act on.
#
# Tick logic (see PR description / spec for the full walkthrough):
#   1. No state file            -> exit 0, quiet (nothing to supervise).
#   2. Unparseable state file   -> log loud, exit 1 (next tick retries).
#   3. PR CLOSED/MERGED         -> threaded wrap-up, clear state, exit 0.
#   4. STOP-STATE met (CI green incl. qa-review, zero unresolved
#      Critical/Important threads, mergeable) -> final "ready for merge" post
#      (mentions Nick), clear state ONLY if the post is confirmed delivered.
#   5. Otherwise compute an ACTIONABLE DELTA (unresolved finding, qa-review
#      NO-GO, a redded CI check, or a dead QA dispatch needing a CI rerun).
#      - delta + fix_turns < MAX -> increment fix_turns atomically, dispatch
#        ONE bounded "FIX PASS" cto turn.
#      - delta + fix_turns >= MAX -> blocked post (no mention), clear state.
#      - no delta -> exit 0, silent. ZERO dispatches without a delta.
#   6. Best-effort: sweep stale cto-nightly-fixpass-* one-shots >6h old
#      (--delete-after-run does not reap FAILED one-shots).
#
# Guards (this repo's known traps — see qa-pr-approve.sh Guards 6/7, which
# this script's CI/thread checks mirror):
#   - Every gh/jq read is captured + checked explicitly; an empty check
#     rollup does NOT read as green (fail closed); unreadable review threads
#     (transport error OR >100 threads) fail closed too.
#   - On ANY gh read failure mid-tick: log to stderr, exit 1. Never remove
#     state on a failed read.
#   - jq `//` is not used to distinguish false from absent; explicit checks.
#
# Env (mainly for tests):
#   CTO_NIGHTLY_STATE_DIR      state dir (default /var/lib/hydra-cto-nightly)
#   CTO_NIGHTLY_MAX_FIX_TURNS  max bounded fix rounds before pausing (default 3)
#   CTO_NIGHTLY_NOW            epoch-seconds override for "now" (tests)
#   GH / OPENCLAW / MUSO_BIN   binary overrides (tests)
#   SLACK_NOTIFY_BOT           defaults to "cto" below (posts as the cto bot)
#
# Exit codes: 0 handled tick (incl. no-op) | 1 unexpected/unreadable state.

REPO="Muso-AI/hydra"
GH="${GH:-gh}"
OPENCLAW="${OPENCLAW:-openclaw}"
PROFILE="main"
AGENT="cto"
FIX_TIMEOUT_SECONDS="1800"
NICK_UID="U0AL36NADEY"

STATE_DIR="${CTO_NIGHTLY_STATE_DIR:-/var/lib/hydra-cto-nightly}"
STATE_FILE="$STATE_DIR/current.json"
MAX_FIX_TURNS="${CTO_NIGHTLY_MAX_FIX_TURNS:-3}"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLACK_NOTIFY_BOT="${SLACK_NOTIFY_BOT:-cto}"
export SLACK_NOTIFY_BOT
# The journey thread lives in #cto-nightly — MUST be set before sourcing
# slack-notify.sh, whose fallback default is #clio_devops (C0ADV2W76G4);
# threading onto journey_ts in the wrong channel is a Slack error.
SLACK_CHANNEL="${SLACK_CHANNEL:-C0BJ5JBH4P3}"
export SLACK_CHANNEL
# shellcheck source=lib/slack-notify.sh
source "$SELF_DIR/lib/slack-notify.sh"

# Maintenance-window guard: this driver ACTS on the fleet (openclaw cron add
# dispatches a cto turn), so it stands down during a planned window rather than
# burning a bounded fix round on a gateway that is down on purpose. Same idiom
# as codex-keepalive.sh; see lib/maintenance-flag.sh.
# shellcheck source=lib/maintenance-flag.sh
source "$SELF_DIR/lib/maintenance-flag.sh"
if maintenance_active; then
  echo "cto-nightly-driver: maintenance: $(maintenance_reason) - standing down this tick" >&2
  exit 0
fi

log() { echo "cto-nightly-driver: $*" >&2; }
die() { log "$2"; exit "$1"; }

now_epoch() {
  if [ -n "${CTO_NIGHTLY_NOW:-}" ]; then
    printf '%s\n' "$CTO_NIGHTLY_NOW"
  else
    date -u +%s
  fi
}

# ISO-8601 -> epoch: shared helper (GNU/BSD portable, nonzero if unparseable).
# shellcheck source=lib/epoch.sh
source "$SELF_DIR/lib/epoch.sh"
to_epoch() { iso_to_epoch "$1"; }

# clear_state <pr>: remove the state file ONLY if it still tracks the PR this
# tick decided on — a tick racing the OPEN turn's overwrite (stale previous
# night's state vs the new night's write) must not delete the new night.
clear_state() {
  local expect_pr="$1" cur
  cur="$(jq -r '.pr // empty' "$STATE_FILE" 2>/dev/null || true)"
  if [ "$cur" = "$expect_pr" ]; then
    rm -f "$STATE_FILE"
  else
    log "WARN: state file now tracks PR '${cur:-<gone>}' (expected #$expect_pr) — leaving it."
  fi
}

# write_state <json> <expect_pr>: atomically replace the state file, but ONLY
# if it still tracks <expect_pr> (compare-and-swap against the tick's snapshot
# — the OPEN turn can replace current.json mid-tick with a NEW night's PR, and
# a blind write here would clobber it with the OLD PR's incremented state).
# Returns: 0 written | 1 io error | 2 state was replaced (do not proceed).
write_state() {
  local tmp cur
  cur="$(jq -r '.pr // empty' "$STATE_FILE" 2>/dev/null || true)"
  [ "$cur" = "$2" ] || return 2
  tmp="$(mktemp "${STATE_FILE}.XXXXXX")" || return 1
  printf '%s' "$1" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$STATE_FILE"
}

# post_thread <text>: post a plain-text threaded reply onto journey_ts and
# return REAL delivery status (0 only on a confirmed Slack post).
post_thread() {
  local text="$1" payload rc=0
  payload="$(mktemp)" || return 1
  jq -n --arg channel "$SLACK_CHANNEL" --arg text "$text" --arg ts "$journey_ts" \
    '{channel:$channel, text:$text, thread_ts:$ts}' > "$payload"
  slack_notify_payload_file_status "$payload" || rc=$?
  rm -f "$payload"
  return "$rc"
}

# Sweep stale cto-nightly-fixpass-* one-shots left behind by a run that FAILED
# (--delete-after-run only reaps a succeeded outcome). Mirrors
# scripts/qa-dispatch-pr-review.sh's sweep. Best-effort: never fail the tick.
# Side effect: sets fixpass_in_flight=1 when a FRESH (non-stale) fixpass job is
# still listed — a pending/running turn (a succeeded one self-deletes). The
# dispatch path skips on that: FIX_TIMEOUT_SECONDS (1800s) equals the timer
# period, so without this guard a full-budget turn overlaps the next tick's
# dispatch and two concurrent turns race the same standing clone.
fixpass_in_flight=0
sweep_stale_fixpass_jobs() {
  local cutoff_ms listing ids id fresh
  cutoff_ms=$(( ($(now_epoch) - 6 * 3600) * 1000 ))
  if ! listing="$("$OPENCLAW" --profile "$PROFILE" cron list --json 2>/dev/null)"; then
    # Unreadable cron list = UNKNOWN in-flight state. Fail SAFE for the
    # dispatch decision: assume in flight (skip dispatch this tick) rather
    # than risk racing a turn we cannot see. Sweep is skipped too (harmless).
    log "WARN: openclaw cron list failed — treating fix-pass state as in-flight (no dispatch this tick)."
    fixpass_in_flight=1
    return 0
  fi
  # A zero exit with malformed/incompatible JSON is the same UNKNOWN state —
  # a bare jq failure downstream would default fresh to 0 and silently disarm
  # the clone-race guard.
  if ! jq -e '.jobs | type == "array"' >/dev/null 2>&1 <<< "$listing"; then
    log "WARN: openclaw cron list returned an unexpected shape — treating fix-pass state as in-flight (no dispatch this tick)."
    fixpass_in_flight=1
    return 0
  fi
  ids="$(jq -r --argjson c "$cutoff_ms" \
        '.jobs[]? | select((.name // "") | startswith("cto-nightly-fixpass-"))
                  | select((.createdAtMs // 9999999999999) < $c) | .id' \
        <<< "$listing" 2>/dev/null || true)"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    "$OPENCLAW" --profile "$PROFILE" cron rm "$id" >/dev/null 2>&1 || true
  done <<< "$ids"
  # In-flight = fresh AND not terminally failed. state.lastStatus semantics
  # (verified on the live cron store): null = scheduled/still running, "ok" =
  # succeeded (then --delete-after-run reaps it), "error" = failed and left
  # behind. Counting failed jobs here would block every further dispatch for
  # the rest of the night on the first failed fix pass.
  fresh="$(jq -r --argjson c "$cutoff_ms" \
        '[.jobs[]? | select((.name // "") | startswith("cto-nightly-fixpass-"))
                   | select((.createdAtMs // 0) >= $c)
                   | select((.state.lastStatus // null) == null)] | length' \
        <<< "$listing" 2>/dev/null || echo 0)"
  [[ "$fresh" =~ ^[0-9]+$ ]] && [ "$fresh" -gt 0 ] && fixpass_in_flight=1
  return 0
}

# --- Serialize all state operations against the OPEN turn. ------------------
# The whole tick holds an exclusive flock on the state dir (released on exit):
# the opener's state write takes the same lock, so read-decide-write can never
# interleave with a new night's replacement. flock is util-linux — always
# present on node-8 + the CI runner; on a flock-less dev box (macOS) this
# degrades to the write_state CAS + clear_state PR-match guards alone.
if command -v flock >/dev/null 2>&1; then
  exec 8>"$STATE_DIR/.lock"
  flock -w 30 8 || die 1 "could not acquire the state lock within 30s — another state operation is stuck; next tick retries."
fi

# --- Step 1: no state file -> exit 0, quiet. -------------------------------
[ -f "$STATE_FILE" ] || exit 0

# --- Step 2: state must parse. ---------------------------------------------
state_json="$(cat "$STATE_FILE" 2>/dev/null || true)"
jq -e 'type == "object"
       and (.issue | type == "number")
       and (.pr | type == "number")
       and (.journey_ts | type == "string")
       and (.fix_turns | type == "number")
       and (.opened_at | type == "string")' >/dev/null 2>&1 <<< "$state_json" \
  || die 1 "unparseable state file $STATE_FILE — refusing to guess; next tick retries."

issue="$(jq -r '.issue' <<< "$state_json")"
pr="$(jq -r '.pr' <<< "$state_json")"
journey_ts="$(jq -r '.journey_ts' <<< "$state_json")"
fix_turns="$(jq -r '.fix_turns' <<< "$state_json")"
opened_at="$(jq -r '.opened_at' <<< "$state_json")"
# journey_ts is spliced into the FIX-PASS dispatch message and used as a Slack
# thread_ts — pin it to the Slack ts shape so a tampered state file can't ride
# free text into the agent turn.
[[ "$journey_ts" =~ ^[0-9]+\.[0-9]+$ ]] \
  || die 1 "state file journey_ts '$journey_ts' is not a Slack ts — refusing (tampered or corrupt state)."
# GNU `date -d ''` resolves to today-midnight, so an empty/garbage opened_at
# would silently parse — pin the shape here instead.
[[ "$opened_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] \
  || die 1 "state file opened_at '$opened_at' is not ISO-8601 — refusing (tampered or corrupt state)."

sweep_stale_fixpass_jobs

# --- gh pr view: state, mergeable, headRefOid, statusCheckRollup. ----------
pr_json="$("$GH" pr view "$pr" --repo "$REPO" \
  --json state,mergeable,headRefOid,statusCheckRollup 2>&1)" \
  || die 1 "gh pr view failed for $REPO#$pr: $pr_json"
jq -e 'type == "object"' >/dev/null 2>&1 <<< "$pr_json" \
  || die 1 "unparseable gh pr view output for $REPO#$pr: $pr_json"

pr_state="$(jq -r '.state' <<< "$pr_json")"
mergeable="$(jq -r '.mergeable' <<< "$pr_json")"

# --- Step 3: PR closed/merged -> wrap-up, clear state, done. ---------------
if [ "$pr_state" = "CLOSED" ] || [ "$pr_state" = "MERGED" ]; then
  verb="closed"; [ "$pr_state" = "MERGED" ] && verb="merged"
  post_thread "PR #${pr} was ${verb} — clearing the overnight loop." || true
  clear_state "$pr"
  exit 0
fi

# --- Unresolved Critical/Important review threads (mirrors qa-pr-approve.sh
#     Guard 7's GraphQL query + gojq-safe filter, including the >100-threads
#     fail-closed branch). --------------------------------------------------
read -r -d '' gql <<'GQL' || true
query($owner:String!,$repo:String!,$pr:Int!){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$pr){
      reviewThreads(first:100){
        pageInfo{ hasNextPage }
        nodes{ isResolved comments(first:1){ nodes{ body author{ login } } } }
      }
    }
  }
}
GQL
threads_out="$("$GH" api graphql -f query="$gql" -f owner="Muso-AI" -f repo="hydra" -F pr="$pr" 2>&1)" \
  || die 1 "gh api graphql (reviewThreads) failed for $REPO#$pr: $threads_out"
unresolved_blockers="$(printf '%s' "$threads_out" \
  | jq -r '.data.repository.pullRequest.reviewThreads
           | if .pageInfo.hasNextPage then "MORE"
             else ([.nodes[]? | select(.isResolved == false)
                    | (.comments.nodes[0].body // "")
                    | select(test("🔴|🟡"))] | length | tostring)
             end' 2>/dev/null || echo "ERR")"
[[ "$unresolved_blockers" =~ ^[0-9]+$ ]] \
  || die 1 "cannot verify review threads for $REPO#$pr (unreadable or >100 threads: $unresolved_blockers) — fail closed, next tick retries."

# --- CI status: classify every non-qa-review rollup row ONCE, by its real
#     shape (CheckRun rows carry status/conclusion; StatusContext rows carry
#     state — verified against live gh output), fail closed. A CheckRun is
#     PENDING until status == COMPLETED (gh serializes an in-progress
#     conclusion as "" — matching neither a red nor a green whitelist, which
#     is why RED is the COMPLEMENT of green, per qa-pr-approve.sh Guard 6's
#     fail-closed doctrine: ACTION_REQUIRED / STARTUP_FAILURE / STALE are red,
#     not invisible. qa-review is excluded here and required separately (it is
#     the QA bot's GO status). ---------------------------------------------
ci_class="$(jq -r '
  [(.statusCheckRollup // [])[] | select((.context // .name) != "qa-review")] as $rows
  | if ($rows | length) == 0 then "NO-CHECKS 0 0"
    else
      ([$rows[]
        | if (has("status") and .status != null) then
            (if .status != "COMPLETED" then "PENDING"
             else ((.conclusion // "") | ascii_upcase
                   | if . == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED"
                     then "GREEN" else "RED" end)
             end)
          else
            ((.state // "") | ascii_upcase
             | if . == "SUCCESS" then "GREEN"
               elif . == "PENDING" or . == "EXPECTED" then "PENDING"
               else "RED" end)
          end]) as $c
      | "OK \([$c[] | select(. == "RED")] | length) \([$c[] | select(. == "PENDING")] | length)"
    end' <<< "$pr_json" 2>/dev/null || echo "ERR")"
read -r ci_tag ci_reds ci_pending <<< "$ci_class"
[[ "$ci_tag" = "OK" || "$ci_tag" = "NO-CHECKS" ]] \
  || die 1 "cannot classify CI rollup for $REPO#$pr ($ci_class) — fail closed, next tick retries."

qa_review_state="$(jq -r '[(.statusCheckRollup // [])[] | select((.context // .name) == "qa-review")]
                    | if length == 0 then "ABSENT"
                      else (((.[0].conclusion // .[0].state) // "PENDING") | ascii_upcase)
                      end' <<< "$pr_json")"

# STOP-STATE's "CI green" requires the qa-review context to itself be present
# and passing (it is the QA bot's GO status) -- an absent qa-review means CI
# is not actually settled, even if every OTHER check is green (that's exactly
# the dead-QA-dispatch case the recovery delta below exists to catch).
# NO-CHECKS is never green (an empty rollup is not proof CI ran — QA #398).
ci_green=0
if [ "$ci_tag" = "OK" ] && [ "$ci_reds" = "0" ] && [ "$ci_pending" = "0" ] \
   && { [ "$qa_review_state" = "SUCCESS" ] || [ "$qa_review_state" = "NEUTRAL" ] || [ "$qa_review_state" = "SKIPPED" ]; }; then
  ci_green=1
fi

mergeable_ok=0
[ "$mergeable" = "MERGEABLE" ] && mergeable_ok=1

# --- Step 4: STOP-STATE MET -------------------------------------------------
if [ "$ci_green" = 1 ] && [ "$unresolved_blockers" = "0" ] && [ "$mergeable_ok" = 1 ]; then
  final_msg="✅ PR #${pr} is green: CI passing, automated review complete, all findings addressed, mergeable. Ready for your Approve + Merge, <@${NICK_UID}>."
  if post_thread "$final_msg"; then
    clear_state "$pr"
  else
    log "WARN: final ready-for-merge post did not confirm delivery for $REPO#$pr — leaving state for retry."
  fi
  exit 0
fi

# --- Delta detection (ci_reds / ci_pending come from the classifier above). -
# Recover timing is measured from the NEWEST check's completedAt, NOT from
# opened_at: the qa-review status is only posted at the END of the QA agent's
# review turn, which is dispatched when PR Validation completes — so a PR that
# is >30 min old but whose CI finished 5 min ago is mid-review, not a dead
# dispatch. A spurious rerun here re-fires qa-autoreview via workflow_run and
# double-reviews the PR. Fail-safe: no completedAt anywhere -> no recover.
delta=0
delta_kind=""
if [ "$unresolved_blockers" != "0" ]; then
  delta=1; delta_kind="findings"
elif [ "$qa_review_state" = "FAILURE" ] || [ "$qa_review_state" = "ERROR" ]; then
  delta=1; delta_kind="qa-no-go"
elif [ "$ci_reds" -gt 0 ]; then
  delta=1; delta_kind="ci-red"
elif [ "$ci_tag" = "OK" ] && [ "$ci_pending" = 0 ] && [ "$qa_review_state" = "ABSENT" ]; then
  last_completed="$(jq -r '[(.statusCheckRollup // [])[]
                            | select((.context // .name) != "qa-review")
                            | (.completedAt // empty)] | max // empty' <<< "$pr_json")"
  if [ -n "$last_completed" ]; then
    completed_epoch="$(to_epoch "$last_completed" || true)"
    now="$(now_epoch)"
    if [ -n "$completed_epoch" ] && [ "$((now - completed_epoch))" -gt 1800 ]; then
      delta=1; delta_kind="recover"
    fi
  fi
fi

# --- No delta: nothing to act on, quiet. ------------------------------------
if [ "$delta" = 0 ]; then
  exit 0
fi

# --- Dead QA dispatch: recover by rerunning the PR Validation run for the
#     head sha. Handled WITHOUT dispatching the agent. ----------------------
if [ "$delta_kind" = "recover" ]; then
  head_oid="$(jq -r '.headRefOid' <<< "$pr_json")"
  run_list="$("$GH" run list --repo "$REPO" --commit "$head_oid" --workflow "PR Validation" \
    --json databaseId,status,conclusion 2>&1)" \
    || { log "WARN: gh run list failed while recovering a dead QA dispatch for $REPO#$pr: $run_list"; exit 0; }
  run_id="$(jq -r '.[0].databaseId // empty' <<< "$run_list" 2>/dev/null || true)"
  if [ -n "$run_id" ]; then
    if "$GH" run rerun "$run_id" --repo "$REPO" >/dev/null 2>&1; then
      log "Recovered a dead QA dispatch for $REPO#$pr: reran PR Validation run $run_id."
    else
      log "WARN: gh run rerun $run_id failed for $REPO#$pr."
    fi
  else
    log "WARN: no PR Validation run found for $REPO#$pr head ${head_oid} to rerun."
  fi
  exit 0
fi

# --- Delta present: fix_turns >= MAX -> pause the loop, blocked post. -------
if [ "$fix_turns" -ge "$MAX_FIX_TURNS" ]; then
  summary="${unresolved_blockers} unresolved finding(s); CI: ${ci_reds} failing check(s), qa-review=${qa_review_state}"
  post_thread "🛑 Pausing the overnight loop after ${MAX_FIX_TURNS} fix rounds. Outstanding: ${summary}. PR #${pr} stays open for morning triage." || true
  clear_state "$pr"
  exit 0
fi

# --- Delta present: fix_turns < MAX -> increment atomically, THEN dispatch. -
# In-flight guard first: a fresh fixpass one-shot still listed means a turn is
# pending/running (a succeeded one self-deletes) — dispatching another would
# race the same standing clone. Skip; next tick re-evaluates.
if [ "$fixpass_in_flight" = 1 ]; then
  log "a fix-pass turn is still in flight for $REPO#$pr — skipping dispatch this tick."
  exit 0
fi
new_fix_turns=$(( fix_turns + 1 ))
new_state="$(jq --argjson n "$new_fix_turns" '.fix_turns = $n' <<< "$state_json")"
cas_rc=0
write_state "$new_state" "$pr" || cas_rc=$?
if [ "$cas_rc" -eq 2 ]; then
  log "state file was replaced mid-tick (a new night started) — dropping this tick's decision for PR #$pr; the new night's ticks own the file now."
  exit 0
elif [ "$cas_rc" -ne 0 ]; then
  die 1 "could not atomically write $STATE_FILE — refusing to dispatch without recording the round."
fi

read -r -d '' message <<EOF || true
FIX PASS on PR #${pr} (round ${new_fix_turns} of ${MAX_FIX_TURNS}), journey ts=${journey_ts}: run the cto-nightly-issue-fixer skill FIX-PASS mode - one babysit pass: verify each finding against the code, fix real ones or push back with evidence, answer every thread, write your audit row before any push, thread one progress line, then END.
EOF

if "$OPENCLAW" --profile "$PROFILE" cron add \
    --name "cto-nightly-fixpass-$(date -u +%s)" \
    --at "+5s" \
    --agent "$AGENT" \
    --session isolated \
    --message "$message" \
    --timeout-seconds "$FIX_TIMEOUT_SECONDS" \
    --no-deliver \
    --delete-after-run \
    --json >/dev/null 2>&1; then
  log "Dispatched FIX PASS round ${new_fix_turns}/${MAX_FIX_TURNS} for $REPO#$pr (issue #$issue)."
else
  log "WARN: FIX PASS dispatch failed for $REPO#$pr (round ${new_fix_turns}) — gateway down? Accepting the lost round rather than risking a double-dispatch."
  post_thread "⚠️ Could not dispatch a FIX PASS for PR #${pr} this tick (gateway issue?). Will retry next cycle." || true
fi

exit 0
