#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# QA Review Reconciler
#
# Detects and repairs a silently-lost QA auto-review. A dispatch mints a
# one-shot openclaw cron job (qa-dispatch-pr-review.sh); a gateway restart
# (deploy, codex-token-refresh, a crash) kills the process running that job
# before it fires; openclaw never re-arms a past-due one-shot; the SAME
# script's own stale-job sweep then deletes the never-fired row with no
# trace, because it cannot tell "queued, never ran" from "ran, still
# running" from an elapsed-time check alone. Confirmed real losses:
# muso-skills#2 (18h undetected) and core-backend#9243 (15 days
# undetected). This script makes the invariant "a review that was expected
# produces a verdict or a page" mechanically true, independent of whether
# the original dispatch (cron, gateway, or the flaky repository_dispatch
# webhook transport, which drops 4-6 events/week) survived.
#
# WHY A SYSTEMD TIMER, NOT AN OPENCLAW CRON, NOT GITHUB ACTIONS:
#   - NOT an openclaw cron: the exact failure mode this script exists to
#     detect is "a gateway restart kills a cron job before it fires" — a
#     cron-based reconciler would die in the very restart it exists to
#     detect, and would additionally compete with the reviews themselves for
#     the same serialized `qa` agent lane.
#   - NOT GitHub Actions: this is a runtime operational loop against live
#     node-8 state (openclaw cron list, node-8-local dispatch), not a CI
#     gate — routing runtime ops through GH Actions has caused two-CD-paths
#     drift before (see CLAUDE.md "Picking the right extension mechanism").
#   - A systemd timer on node-8 (qa-review-reconcile.timer, installed by
#     install-aux-units.sh) survives exactly the restart this script exists
#     to detect, and runs independently of the gateway process.
#
# ── Expectation ──────────────────────────────────────────────────────────
# A review is EXPECTED for an open PR iff: not draft, AND the base ref is
# gated for that repo (hydra: main only; external repos: develop/main/master
# — encoded per-repo in lib/qa-reconcile.sh's qar_repo_gated_base, never
# averaged), AND the author resolves to a Slack UID via
# lib/qa-author-slack-uid.sh (unmapped = normal skip, not a refusal).
# The ack comment (`<!-- hydra-qa-ack owner/repo#N -->`) is NEVER used as a
# decision signal (it is `continue-on-error: true`, always exits 0) — only
# as diagnostic text in a page, if present.
#
# ── Verdict ──────────────────────────────────────────────────────────────
# A verdict exists iff, keyed against the LIVE head sha (re-resolved every
# tick, never cached from a prior tick): a PR review whose .commit_id equals
# the head sha was authored by a LITERAL member of
# policies/qa-approval-policy.json .identity.bot_logins (never a guessed
# default — see lib/qa-reconcile.sh qar_bot_logins), OR a terminal qa-review
# commit status exists on the head sha (success/failure/error; pending is
# NOT a verdict, except see the merge-gate carve-out below).
#
# ── Age scope (storm guard) ────────────────────────────────────────────
# See the block comment in lib/qa-reconcile.sh ("Age scope") for the full
# rationale (a live rehearsal found 59 PRs, 131h-7106h old, that were never
# dispatched because their repos were onboarded to the allowlist long after
# they opened — shipping without a bound would re-dispatch all of them to
# the global cap, every tick, for days). Short version: each repo gets its
# own epoch = the first tick this reconciler ever saw it in scope; a PR is
# only acted on if trigger_time >= max(repo_epoch, now - 14d).
#
# ── Suppressor ────────────────────────────────────────────────────────────
# Before acting on a "candidate" (no verdict) PR, check for a live
# qa-autoreview-pr-<repo-with-slashes-as-dashes>-<pr> openclaw cron job
# (`cron list --all` — bare `cron list` hides disabled rows). running/queued
# suppresses — BUT ONLY WHEN FRESH. Suppression is bounded by the cron row's
# OWN timestamp (runningAtMs/nextRunAtMs), not by mere presence of the row —
# see lib/qa-reconcile.sh's qar_cron_state for the full running vs
# running-stale / queued vs queued-stale contract and the freshness-bound
# rationale.
#
# THIS INTERACTION IS THE MOST IMPORTANT THING IN THIS FILE: this reconciler
# exists because a gateway restart kills a queued one-shot before it fires,
# openclaw never re-arms a past-due one-shot, and the OLD stale sweep in
# qa-dispatch-pr-review.sh used to delete that never-fired row on elapsed
# time alone — silently losing the review. The fix for THAT bug was "never
# delete a never-run row, at any age" (qa-dispatch-pr-review.sh's sweep).
# Taken alone, an UNBOUNDED cron suppressor here ("queued" or "running"
# presence, regardless of age, suppresses) is equally correct in isolation —
# a queued/running job really might still fire. But the two changes COMBINE
# to reintroduce the exact bug this reconciler exists to fix, permanently:
# the never-deleted, never-fired row survives forever with no lastRunAtMs;
# every 15-minute tick reads it as "queued", suppresses, and moves on;
# attempts never increment, exhaustion never pages, the gate is never driven
# red. The silent-loss class goes silent forever instead of for an hour. The
# same applies to a stale runningAtMs left behind by a killed run — it would
# look "running" forever. Bounding suppression by the row's own freshness
# (qar_cron_state's stale-budget arm) is what closes this: a past-due/killed
# row falls through to the normal candidate path below, which re-dispatches
# it and, on exhaustion, pages/drives the gate red — exactly like a row that
# was never created at all.
#
# Re-dispatch on a stale row is SELF-HEALING as a side effect:
# qa-dispatch-pr-review.sh's idempotency block deletes any existing job of
# the same name before adding the new one, so acting on a stale row also
# clears the wedged row, not just the missing verdict.
#
# If the cron list response is paginated (hasMore=true) the durable set is
# unobtainable; do not suppress forever — after 2x the grace window with
# still no verdict, act anyway (a duplicate review is cheaper than a
# permanently-lost one), logging that the cron set was unknown. This is a
# SEPARATE escape from the freshness bound above (a different kind of
# "cannot confirm"), unchanged by it.
#
# ── Actuator + bounds ──────────────────────────────────────────────────────
#   Grace:    no action until >=30 min since the PR's trigger_time (head
#             push, or ready_for_review if later).
#   Cooldown: >=30 min between attempts for the same (repo, pr, head_sha).
#   Unreachable: a dispatch that never reached the gateway (rc 75) is NOT an
#             attempt; see QA_RECONCILE_MAX_ATTEMPTS.
#   Cap:      max 2 attempts per key; on the 2nd exhausted attempt, page
#             once and (merge-gated repos only) drive the qa-review status
#             red via qa-review-status.sh.
#   Global:   at most 3 re-dispatches per tick, across all repos/PRs.
# Re-dispatch calls qa-dispatch-pr-review.sh directly (bypasses the flaky
# repository_dispatch transport).
#
# ── Read-path GitHub identity ───────────────────────────────────────────
# All GitHub reads here use plain `gh` (ambient host auth on node-8), not
# the qa-gh.sh app-identity shim: the shim exists so WRITES can satisfy an
# app-pinned required-check (see qa-review-status.sh's header) — reads have
# no such constraint, and this script's only writes are through the two
# existing actuators (qa-dispatch-pr-review.sh, qa-review-status.sh), which
# own their own identity choices.
#
# ── gh + jq: NEVER gh --jq/-q with template vars ────────────────────────
# `gh api`'s only jq surface is `-q/--jq <string>`; it does NOT support
# `--arg`/`--argjson`. Passing them makes `gh` exit 1 with a usage dump. If
# that failure is swallowed (a bare `|| true`, or an unchecked $()), the
# result is an EMPTY value that reads as "no bot review / no status found" —
# i.e. every healthy PR looks like a lost review, on a script whose entire
# job is re-dispatching QA. This is the single highest-severity failure mode
# in this design (it fails TOWARD mass re-dispatch on a serialized lane), so
# the rule is absolute and structural, not just documented: every gh call
# below fetches RAW JSON with no --jq/-q at all, and is piped into a
# SEPARATE, standalone `jq` invocation (where --arg/--argjson are legal) —
# see lib/qa-reconcile.sh's qar_has_bot_review / qar_qa_review_status_state.
# Every such gh call's exit status is checked explicitly and a failure is
# routed to the read-failure counting path (never silently treated as "no
# verdict found").
#
# ── Flags ──────────────────────────────────────────────────────────────
#   --dry-run  classify and log what would happen; dispatch nothing, page
#              nothing, drive no status, and do NOT persist state. Each
#              would-be action is logged with enough detail to say whether
#              state would have advanced.
#   --once     accepted for explicitness/parity with other watchdogs in this
#              repo. This script always does exactly ONE tick per invocation
#              and exits — recurrence comes entirely from the systemd timer
#              (OnUnitActiveSec=15min), never from an internal loop (a
#              looping Type=oneshot unit would never let the timer's own
#              schedule apply, and would fight the single-run flock guard).
#              --once therefore changes no behavior; it exists so a human or
#              a test invoking this script is never left wondering whether
#              a bare invocation might loop.
#
# ── Env knobs (mainly for tests — defaults target the live node-8 layout) ──
#   QA_RECONCILE_STATE_FILE          durable state (default
#                                     /var/lib/hydra/qa-reconcile/state.json)
#   QA_RECONCILE_LOCKFILE            single-run lock (default
#                                     /var/run/qa-review-reconcile.lock)
#   QA_RECONCILE_POLICY              policies/qa-approval-policy.json
#   QA_RECONCILE_ALLOWLIST_SCRIPT    lib/qa-external-repo-allowlist.sh
#   QA_RECONCILE_AUTHOR_UID_SCRIPT   lib/qa-author-slack-uid.sh
#   QA_RECONCILE_DISPATCH_SCRIPT     qa-dispatch-pr-review.sh
#   QA_RECONCILE_STATUS_SCRIPT       qa-review-status.sh
#   QA_RECONCILE_OPENCLAW            openclaw binary (default: openclaw)
#   QA_RECONCILE_GH                  gh binary (default: gh)
#   QA_RECONCILE_PROFILE             openclaw --profile (default: main)
#   QA_RECONCILE_GRACE_S             grace window seconds (default 1800)
#   QA_RECONCILE_COOLDOWN_S          cooldown seconds (default 1800)
#   QA_RECONCILE_MAX_ATTEMPTS        attempts cap per key (default 2). Bounds
#                                     dispatches that REACHED the gateway; a
#                                     dispatcher exit 75 (gateway unreachable)
#                                     is not an attempt — cooldown, the global
#                                     cap and a page after TICK_FAIL_THRESHOLD
#                                     all-unreachable ticks bound those
#   QA_RECONCILE_GLOBAL_CAP          re-dispatches per tick (default 3)
#   QA_RECONCILE_PAGE_CAP             exhaustion pages + red-status calls per
#                                     tick (default 3) — bounds the actuator
#                                     a systematic false positive walks to N
#                                     Slack pages / N red statuses in one tick
#   QA_RECONCILE_CRON_STALE_S        cron-row staleness budget seconds
#                                     (default 1800) — a running/queued cron
#                                     row older than this by its OWN
#                                     runningAtMs/nextRunAtMs is NOT treated
#                                     as evidence of an in-flight review (see
#                                     the Suppressor section above). Same
#                                     physical fact as the 1800s cutoff
#                                     qa-dispatch-pr-review.sh's stale sweep
#                                     uses (the 1200s job timeout plus
#                                     margin: "a review cannot still be
#                                     legitimately in flight after this
#                                     long") — kept as one number, not
#                                     hardcoded twice, by living here as its
#                                     own env-overridable default rather than
#                                     being derived from the other script.
#   QA_RECONCILE_AGE_CEILING_S       storm-guard ceiling (default 1209600 = 14d)
#   QA_RECONCILE_TICK_FAIL_THRESHOLD consecutive whole-tick (or whole-repo, or
#                                     whole-repo-candidate-reads) read failures
#                                     before paging (default 3)
#   QA_RECONCILE_PRLIST_LIMIT        gh pr list --limit (default 300). If a
#                                     repo's listing returns exactly this many
#                                     PRs, the list is treated as truncated:
#                                     logged loudly, paged every tick it
#                                     persists, and that repo's state keys are
#                                     never pruned while truncated (never wipe
#                                     attempt state for a PR merely invisible
#                                     this tick).
#   QA_RECONCILE_NOW_EPOCH           override "now" (tests)
#   QA_RECONCILE_SLACK_CHANNEL       target channel (default #clio_devops)
# ──────────────────────────────────────────────────────────────

LOGPREFIX="[qa-review-reconcile $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
log() { echo "$LOGPREFIX $1"; }

_QRR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/qa-reconcile.sh
source "$_QRR_DIR/lib/qa-reconcile.sh"
# shellcheck source=lib/qa-policy.sh
source "$_QRR_DIR/lib/qa-policy.sh"
# shellcheck source=lib/epoch.sh
source "$_QRR_DIR/lib/epoch.sh"
# shellcheck source=lib/slack-notify.sh
export SLACK_CHANNEL="${QA_RECONCILE_SLACK_CHANNEL:-C0ADV2W76G4}" # #clio_devops
source "$_QRR_DIR/lib/slack-notify.sh"

STATE_FILE="${QA_RECONCILE_STATE_FILE:-/var/lib/hydra/qa-reconcile/state.json}"
LOCKFILE="${QA_RECONCILE_LOCKFILE:-/var/run/qa-review-reconcile.lock}"
POLICY="${QA_RECONCILE_POLICY:-$_QRR_DIR/../policies/qa-approval-policy.json}"
ALLOWLIST_SCRIPT="${QA_RECONCILE_ALLOWLIST_SCRIPT:-$_QRR_DIR/lib/qa-external-repo-allowlist.sh}"
AUTHOR_UID_SCRIPT="${QA_RECONCILE_AUTHOR_UID_SCRIPT:-$_QRR_DIR/lib/qa-author-slack-uid.sh}"
DISPATCH_SCRIPT="${QA_RECONCILE_DISPATCH_SCRIPT:-$_QRR_DIR/qa-dispatch-pr-review.sh}"
STATUS_SCRIPT="${QA_RECONCILE_STATUS_SCRIPT:-$_QRR_DIR/qa-review-status.sh}"
OPENCLAW="${QA_RECONCILE_OPENCLAW:-openclaw}"
GH="${QA_RECONCILE_GH:-gh}"
PROFILE="${QA_RECONCILE_PROFILE:-main}"
GRACE_S="${QA_RECONCILE_GRACE_S:-1800}"
COOLDOWN_S="${QA_RECONCILE_COOLDOWN_S:-1800}"
MAX_ATTEMPTS="${QA_RECONCILE_MAX_ATTEMPTS:-2}"
GLOBAL_CAP="${QA_RECONCILE_GLOBAL_CAP:-3}"
PAGE_CAP="${QA_RECONCILE_PAGE_CAP:-3}"
CRON_STALE_S="${QA_RECONCILE_CRON_STALE_S:-1800}"
AGE_CEILING_S="${QA_RECONCILE_AGE_CEILING_S:-1209600}"
TICK_FAIL_THRESHOLD="${QA_RECONCILE_TICK_FAIL_THRESHOLD:-3}"
# One read-failure page per (repo, stage) per this window. 6h matches
# cron-health-watchdog.sh's SESSION_BUDGET_ALERT_INTERVAL — the same
# slow-moving-signal-on-a-fast-tick shape. See the "Read-failure PAGE dedupe"
# block in lib/qa-reconcile.sh for why this is load-bearing rather than taste.
READ_FAIL_ALERT_INTERVAL="${QA_RECONCILE_READ_FAIL_ALERT_INTERVAL:-21600}"
GITHUB_STATUS_URL="${QA_RECONCILE_GITHUB_STATUS_URL:-https://www.githubstatus.com/api/v2/summary.json}"
PRLIST_LIMIT="${QA_RECONCILE_PRLIST_LIMIT:-300}"
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --once) : ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

NOW_EPOCH="${QA_RECONCILE_NOW_EPOCH:-$(date -u +%s)}"

# Portable epoch -> UTC date (GNU date first, then BSD/macOS date). Mirrors
# lib/cto-push-audit-guard.sh's epoch_to_date — not yet extracted to a
# sourceable lib (only the second occurrence; see CLAUDE.md's "wait for the
# third" DRY rule).
epoch_to_date() {
  date -u -d "@$1" +%Y-%m-%d 2>/dev/null || date -u -r "$1" +%Y-%m-%d 2>/dev/null
}
# The rollup enrichment call (see the split below) is scoped to the same
# storm-guard age ceiling as qar_trigger_in_scope, since only in-scope PRs
# ever reach the terminal-status short-circuit that consumes it.
ROLLUP_SEARCH_DATE="$(epoch_to_date "$((NOW_EPOCH - AGE_CEILING_S))")"

page() {
  # Best-effort, but never in dry-run: dry-run must page nothing.
  [ "$DRY_RUN" -eq 1 ] && { log "[dry-run] WOULD PAGE: $1"; return 0; }
  slack_notify_critical "$1" || true
}

# ── Upstream-attribution for read-failure pages ────────────────────────────
# A read failure has two very different causes with identical local symptoms,
# and the old page text asserted the wrong one. It guessed
# "(permissions/token-scope/rate-limit?)" — all LOCAL causes — but on
# 2026-08-17 the actual cause was a GitHub incident, and the tell was only
# visible off-box: api.github.com answered 404 (not 5xx) on
# repos/<org>/<repo>/commits for PRIVATE org repos while /contents on the same
# repo, and /commits on PUBLIC repos, both stayed 200. That split is
# impossible under any permission model, but it reads exactly like a revoked
# scope, and the page pointed the reader straight at the wrong hypothesis.
#
# So: ask githubstatus.com and report what it actually said. Three outcomes,
# never collapsed to two — "we could not measure it" is its own state, not a
# synonym for healthy (the same rule codex-quota's cq_format_evidence enforces:
# never render a fact the system did not measure).
#
# Probed at most ONCE per tick and cached in _GH_STATUS_NOTE.
#
# This deliberately SETS A GLOBAL and returns nothing, instead of the more
# natural `note="$(github_status_note)"`. Command substitution forks a
# subshell, so a cache flag set inside one never propagates back to the parent
# — the memo would silently never hit and a 9-repo storm would make one probe
# PER PAGE (4 probes for 4 pages, caught by e2e 42) rather than one per tick.
# Callers must read $_GH_STATUS_NOTE directly, never $(...) this.
_GH_STATUS_CHECKED=0
_GH_STATUS_NOTE=""
github_status_probe() {
  [ "$_GH_STATUS_CHECKED" -eq 1 ] && return 0
  _GH_STATUS_CHECKED=1
  local body desc degraded detail
  if ! body="$(curl -sS --max-time 10 "$GITHUB_STATUS_URL" 2>/dev/null)" || [ -z "$body" ]; then
    _GH_STATUS_NOTE="GitHub status could not be read, so upstream-vs-local is UNRESOLVED — check https://www.githubstatus.com before suspecting our token."
  elif ! desc="$(jq -re '.status.description // empty' <<<"$body" 2>/dev/null)"; then
    _GH_STATUS_NOTE="GitHub status returned an unparseable response, so upstream-vs-local is UNRESOLVED — check https://www.githubstatus.com before suspecting our token."
  elif [ "$desc" = "All Systems Operational" ]; then
    _GH_STATUS_NOTE="GitHub status reports \"$desc\", so this is most likely LOCAL — suspect permissions/token-scope/rate-limit."
  else
    # The component breakdown is decorative; parsing it must never be able to
    # kill the tick. A document with a valid top-level .status.description but
    # a non-object component entry (`"components":[5]`) makes
    # `select(.status != ...)` raise "Cannot index number with string" and jq
    # exit 5. Unguarded under `set -euo pipefail` that aborts the reconciler
    # MID-LOOP — before page_confirmed, and before the single end-of-tick
    # state write — so every affected repo would lose both its read-failure
    # page AND its counter advance, on every retry. Two layers: skip
    # non-object entries by construction, and still treat any residual jq
    # failure as "detail unavailable". (e2e 45)
    #
    # NOT downgraded to UNRESOLVED: `.status.description` was parsed
    # successfully above, so "there is an active incident" is a MEASURED fact
    # and keeps its meaning. Only the per-component detail is unknown, and the
    # note says exactly that — consistent with never rendering a fact the
    # system did not measure, in both directions.
    detail=""
    if degraded="$(jq -r '[.components[]? | select(type == "object") | select(.status != "operational") | "\(.name)=\(.status)"] | join(", ")' <<<"$body" 2>/dev/null)"; then
      if [ -n "$degraded" ]; then detail="; $degraded"; fi
    else
      detail="; component detail unavailable (unparseable components)"
    fi
    _GH_STATUS_NOTE="GitHub is reporting an ACTIVE INCIDENT (\"$desc\"$detail) — this is very likely UPSTREAM, not our token. Expect it to clear on its own; the counters reset on the first successful read."
  fi
  return 0
}

# page_read_failure <repo> <stage> <message> — page for a read failure, at most
# once per (repo, stage) per READ_FAIL_ALERT_INTERVAL, appending what
# githubstatus.com actually said. Reads and writes the caller's $state_json in
# place (the repo loop is not a subshell, and state is written once at
# end-of-tick), so a suppressed page leaves the stamp untouched.
page_read_failure() {
  local repo="$1" stage="$2" msg="$3" last
  last="$(qar_state_read_fail_last_alert "$state_json" "$repo" "$stage")"
  if ! qar_read_fail_should_page "$last" "$NOW_EPOCH" "$READ_FAIL_ALERT_INTERVAL"; then
    log "read-failure page suppressed for $repo/$stage (last paged $((NOW_EPOCH - last))s ago, interval ${READ_FAIL_ALERT_INTERVAL}s) — detection counters still advancing."
    return 0
  fi
  github_status_probe
  # page_confirmed, NOT page: the stamp below PERSISTS "already paged", so it
  # may only advance on CONFIRMED delivery. page() swallows Slack failures by
  # design (`|| true`), so stamping off it would let ONE transient Slack error
  # buy a full interval of silence on a repo whose reads are broken — the
  # exact silent-loss invariant this reconciler exists to eliminate,
  # reintroduced inside the guard meant to protect it. This is the same
  # contract the exhaustion page above already follows. (e2e 43)
  if page_confirmed "$msg $_GH_STATUS_NOTE"; then
    # page_confirmed returns 0 WITHOUT sending under --dry-run, so the
    # dry-run guard still stands: a rehearsal must not advance the stamp.
    if [ "$DRY_RUN" -eq 0 ]; then
      state_json="$(qar_state_set_read_fail_last_alert "$state_json" "$repo" "$stage" "$NOW_EPOCH")"
    fi
  else
    log "read-failure page for $repo/$stage was NOT confirmed delivered — suppression stamp deliberately NOT advanced; the next tick retries."
  fi
}

# page_confirmed <message> — like page(), but rc 0 ONLY on CONFIRMED delivery.
#
# slack_notify_critical() routes through slack_notify(), which is deliberately
# fire-and-forget (`|| true`) so that failing to post an alert never aborts a
# script already mid-recovery. That contract is wrong for anything that
# PERSISTS "already paged": a transient Slack/API outage would make the send
# fail, we would record paged=true anyway, and every later tick would skip the
# page forever — leaving a PR with neither a verdict nor an alert, which is the
# exact silent-loss invariant this reconciler exists to eliminate.
#
# slack_notify_payload_file_status() exists for precisely this case (see its
# docstring in lib/slack-notify.sh: "use when the caller must NOT advance
# dedupe / idempotency state for an alert that was never actually delivered").
# We build the same <@UID> mention prefix slack_notify_critical would, because
# a literal @name pings nobody.
page_confirmed() {
  [ "$DRY_RUN" -eq 1 ] && { log "[dry-run] WOULD PAGE: $1"; return 0; }
  local payload rc=0
  payload="$(mktemp)" || return 1
  jq -n --arg c "${SLACK_CHANNEL:-C0ADV2W76G4}" \
        --arg t "<@${SLACK_UID_NICK}> <@${SLACK_UID_AARON}> $1" \
        '{channel: $c, text: $t}' > "$payload" 2>/dev/null || { rm -f "$payload"; return 1; }
  slack_notify_payload_file_status "$payload" || rc=$?
  rm -f "$payload"
  return "$rc"
}

# Single-run lock so overlapping ticks (a slow tick + the next timer fire)
# never race the same state file. Skipped under --dry-run, matching
# merge-landing-watchdog.sh's convention, so a dry-run rehearsal can run
# alongside a live prod tick.
if [ "$DRY_RUN" -eq 0 ]; then
  exec 9>"$LOCKFILE"
  flock -n 9 || { log "SKIP: another qa-review-reconcile run holds $LOCKFILE"; exit 0; }
fi

# ── Load state (fail-closed on corruption, not on absence) ────────────────
STATE_FILE_MISSING=0
[ -f "$STATE_FILE" ] || STATE_FILE_MISSING=1

if ! state_json="$(qar_state_read "$STATE_FILE")"; then
  log "REFUSE: $STATE_FILE exists but is not parseable JSON — refusing to act this tick (a corrupt attempt counter must never silently become an unbounded dispatch loop)."
  page "qa-review-reconcile: state file $STATE_FILE is corrupt/unparseable. Refusing to dispatch or page per-PR until this is fixed by hand (fail-closed)."
  exit 1
fi

# ── Load policy-derived facts (fail-closed, no guessed defaults) ──────────
if ! bot_logins_json="$(qar_bot_logins "$POLICY")"; then
  log "REFUSE: cannot read policies/qa-approval-policy.json .identity.bot_logins from $POLICY — refusing to classify verdicts this tick (never degrade to a guessed bot-login set)."
  page "qa-review-reconcile: $POLICY unreadable or .identity.bot_logins missing/malformed. Refusing to act this tick (fail-closed, no guessed default)."
  exit 1
fi
if ! qa_policy_valid "$POLICY"; then
  log "REFUSE: $POLICY fails qa_policy_valid — refusing to act this tick."
  page "qa-review-reconcile: $POLICY failed schema validation. Refusing to act this tick (fail-closed)."
  exit 1
fi

# ── Resolve repo scope: allowlist enumeration PLUS Muso-AI/hydra ──────────
# Enumeration is env-gated and argument-free ON PURPOSE: an argv flag would be
# indistinguishable from an attacker-supplied client_payload.repo in the two
# workflow callers that pass that payload straight into the same script, and
# they read rc 0 as "allowed". See that script's header.
if ! allowlist_out="$(QA_EXTERNAL_REPO_ALLOWLIST_ENUMERATE=1 "$ALLOWLIST_SCRIPT" 2>/dev/null)"; then
  log "REFUSE: $ALLOWLIST_SCRIPT enumeration failed — cannot determine repo scope this tick."
  page "qa-review-reconcile: $ALLOWLIST_SCRIPT enumeration failed. Refusing to act this tick (cannot determine repo scope)."
  exit 1
fi
mapfile -t REPOS < <(qar_expected_repos "$allowlist_out")
REPOS_NEWLINE="$(printf '%s\n' "${REPOS[@]}")"

# ── Age-scope bookkeeping: mint any missing per-repo epoch, always ─────────
# (missing state file mints ALL of them = now; a newly-onboarded repo mints
# only its own gap on whatever future tick first sees it — same code path).
state_json="$(qar_state_ensure_repo_epochs "$state_json" "$REPOS_NEWLINE" "$NOW_EPOCH")"

# Prune per-stage failure counters for repos no longer in scope (see
# lib/qa-reconcile.sh's qar_state_prune_stage_failures) so a repo dropped
# from the allowlist cannot leave a stale row growing the state file.
state_json="$(qar_state_prune_stage_failures "$state_json" "$REPOS_NEWLINE")"
state_json="$(qar_state_prune_read_fail_alerts "$state_json" "$REPOS_NEWLINE")"

if [ "$STATE_FILE_MISSING" -eq 1 ]; then
  log "FIRST RUN: $STATE_FILE did not exist. Minted repo epochs = now for ${#REPOS[@]} repos; attempt history is empty. Dispatching nothing this tick (a rebuilt storm guard with no history must not immediately act on an unknown backlog)."
  page "qa-review-reconcile: state file $STATE_FILE was missing (first run, or state was lost). Per-repo storm-guard epochs re-minted to now for ${#REPOS[@]} repos. Attempt history was lost — dispatching nothing this tick while the guard repopulates."
  SKIP_DISPATCH_THIS_TICK=1
else
  SKIP_DISPATCH_THIS_TICK=0
fi

# ── Fetch the live cron set once for the whole tick (suppressor) ──────────
# A failed read (e.g. the gateway is mid-restart — exactly when this
# reconciler matters most) must NOT read as "no suppressor" (job absent):
# qar_cron_state maps empty input to "unknown", the same bucket as a
# paginated hasMore=true set, so it is still bound by the 2x-grace escape
# below rather than acted on immediately. cron_read_failed is tracked
# separately only so the per-candidate log line can tell an operator "the
# cron list command itself failed" apart from "the set was paginated".
if cron_json="$("$OPENCLAW" --profile "$PROFILE" cron list --all --json 2>/dev/null)"; then
  cron_read_failed=0
else
  cron_json=""
  cron_read_failed=1
  log "READ-FAILURE: openclaw cron list --all --json failed — cron suppressor set unknown this tick (bound by the same 2x-grace escape as a paginated hasMore set, not treated as 'no suppressor')."
fi

dispatched_this_tick=0
# Dispatches this tick that exited 75 (never reached the gateway) / exited 0.
unreachable_this_tick=0
reached_this_tick=0
# PRs whose head commit already carried a terminal qa-review status in the PR
# list, so no per-PR REST read was needed (the read-amplification cut).
terminal_skipped=0
paged_this_tick=0
page_cap_deferred=0
pre_epoch_ignored_total=0
declare -A pre_epoch_ignored_by_repo=()
failed_repo_count=0
total_repo_count=${#REPOS[@]}
# Repos whose rollup-enrichment call (best-effort) failed or was malformed
# this tick — NOT a READ-FAILURE (the authoritative listing still succeeded),
# never touches the repo failure counter, never pages. Just disables the
# terminal-status short-circuit for that repo this tick.
rollup_degraded_count=0
# Every key seen this tick that must survive pruning even though its repo's
# listing may have failed later in the loop for a DIFFERENT repo; and every
# (repo,pr,head_sha) confirmed still-open, for the prune pass below.
declare -A repo_listed_ok=()
# Repos whose PR listing came back exactly at PRLIST_LIMIT this tick: the
# list is presumed truncated, and this repo's state keys must NOT be pruned
# below (an overflow PR that is merely invisible this tick must not have its
# attempt counters wiped as if it were closed/merged).
declare -A repo_truncated=()
# ── per-PR gh reads: capture stderr, classify rate-limit ────────────────
# gh_read <outvar> <gh args...> — runs "$GH" with stdout captured into
# <outvar> and stderr sent to a FILE, never merged into stdout (gh writes
# routine notices to stderr; folding them in would corrupt a good JSON body —
# same pattern as release-watch.sh's gh_run_list_retry). Returns gh's rc.
# On failure sets GH_ERR_DETAIL (first 300 bytes of stderr, one line) and
# GH_ERR_RATE_LIMITED (1 when stderr carries a 403/429 AND rate-limit text; a
# bare 403 is also how a scope problem reads, so the text decides).
GH_ERR_DETAIL=""
GH_ERR_RATE_LIMITED=0
# Assigned via printf -v in gh_read; declared so shellcheck sees the assignment.
commit_json="" timeline_json="" reviews_json="" status_json=""
gh_read() {
  local __outvar="$1" __body
  shift
  : > "$gh_err_file"
  GH_ERR_DETAIL=""
  GH_ERR_RATE_LIMITED=0
  if __body="$("$GH" "$@" 2>"$gh_err_file")"; then
    printf -v "$__outvar" '%s' "$__body"
    return 0
  fi
  # `head` MUST read straight from the file and run before `tr`: with
  # pipefail, `tr < file | head -c 300` SIGPIPEs `tr` on a large stderr and the
  # 141 trips `set -e`, killing the tick (see release-watch.sh).
  GH_ERR_DETAIL="$(head -c 300 "$gh_err_file" | tr -d '\0' | tr '\n' ' ')"
  if grep -qE '\b(403|429)\b' "$gh_err_file" && grep -qiE 'rate limit' "$gh_err_file"; then
    GH_ERR_RATE_LIMITED=1
  fi
  return 1
}

rate_limit_failed_reads=0
rate_limit_probe=""
# report_gh_read_failure <message> — call after a failed gh_read. A rate-limit
# cause is tallied (and probed once) for the single tick-level TOKEN EXHAUSTED
# line; any other cause logs the per-PR READ-FAILURE line with gh's own text.
report_gh_read_failure() {
  local msg="$1" core remaining limit reset reset_iso
  if [ "$GH_ERR_RATE_LIMITED" -eq 1 ]; then
    rate_limit_failed_reads=$((rate_limit_failed_reads + 1))
    if [ -z "$rate_limit_probe" ]; then
      # `gh api rate_limit` is not counted against the bucket.
      rate_limit_probe="unknown"
      if core="$("$GH" api rate_limit 2>/dev/null | jq -re '.resources.core | "\(.remaining) \(.limit) \(.reset)"' 2>/dev/null)"; then
        read -r remaining limit reset <<<"$core"
        if [[ "$remaining" =~ ^[0-9]+$ && "$limit" =~ ^[0-9]+$ && "$reset" =~ ^[0-9]+$ ]]; then
          reset_iso="$(date -u -d "@$reset" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$reset" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || reset_iso="unknown"
          rate_limit_probe="core remaining $remaining/$limit, reset at $reset_iso"
        fi
      fi
    fi
    return 0
  fi
  log "$msg${GH_ERR_DETAIL:+ gh: $GH_ERR_DETAIL}"
}

open_pr_keys_file="$(mktemp)"
# One reused stderr capture file for every per-PR gh read this tick (see
# gh_read below); the single trap covers every exit path.
gh_err_file="$(mktemp)"
trap 'rm -f "$open_pr_keys_file" "$open_pr_keys_file".* "$gh_err_file"' EXIT

for repo in "${REPOS[@]}"; do
  # Per-repo candidate-level (per-PR) read-failure tracking for this tick —
  # counts individual gh api attempts (commit/timeline/reviews/status), not
  # PRs. See the __meta__.candidate_read_failures block after this repo's PR
  # loop below.
  repo_reads_attempted=0
  repo_reads_failed=0
  repo_failed_classes=""
  # PRs skipped because the list already showed a terminal qa-review status on
  # their head commit (the read-amplification cut; see the loop body).
  repo_terminal_skipped=0
  # Per-STAGE attempted/failed counts for this repo, this tick — see
  # lib/qa-reconcile.sh's "Per-repo, per-STAGE read-failure tracking" block.
  # Pre-initialize every stage key: under `set -u`, referencing an
  # unset associative-array key is a hard error, and the end-of-repo
  # watchdog below must be able to distinguish "stage not exercised this
  # tick" (attempted=0, skip) from "stage exercised and failed".
  declare -A stage_attempted=( [commit]=0 [timeline]=0 [reviews]=0 [status]=0 [author_uid]=0 )
  declare -A stage_failed=( [commit]=0 [timeline]=0 [reviews]=0 [status]=0 [author_uid]=0 )

  # LISTING (authoritative): drives everything below — trigger scope, the
  # truncation guard, and the prune keep-set. Its failure is a real
  # READ-FAILURE. See "why statusCheckRollup is NOT requested here" below.
  if ! prs_json="$("$GH" pr list --repo "$repo" --state open \
        --json number,headRefOid,baseRefName,isDraft,author,updatedAt,createdAt,url \
        --limit "$PRLIST_LIMIT" 2>/dev/null)" || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$prs_json"; then
    log "READ-FAILURE: could not list open PRs for $repo — counted, not treated as 'no verdict'."
    failed_repo_count=$((failed_repo_count + 1))
    # Per-repo consecutive-failure tracking: a partial-fleet failure (e.g.
    # 16/17 repos failing, or one repo broken every tick forever) must page
    # on its own — the whole-tick counter below only fires when EVERY repo
    # fails in the SAME tick.
    repo_fail_n=$(( $(qar_state_repo_failure_count "$state_json" "$repo") + 1 ))
    state_json="$(qar_state_set_repo_failure_count "$state_json" "$repo" "$repo_fail_n")"
    if [ "$repo_fail_n" -ge "$TICK_FAIL_THRESHOLD" ]; then
      log "REPO FAILURE: $repo has failed to list open PRs for $repo_fail_n consecutive ticks."
      page "qa-review-reconcile: $repo has failed to list open PRs for $repo_fail_n consecutive ticks. This is a per-repo failure, not necessarily a whole-fleet outage."
    fi
    continue
  fi
  repo_listed_ok["$repo"]=1
  state_json="$(qar_state_set_repo_failure_count "$state_json" "$repo" 0)"
  repo_file_key="${repo//\//-}"

  # ── Rollup enrichment (best-effort, 2026-09-18) ────────────────────────
  # `gh pr list --json ...,statusCheckRollup` for ALL open PRs 504s
  # deterministically on Muso-AI/H-DevOps (133 open PRs, 30-50 check
  # contexts each — measured live). The listing above no longer requests
  # statusCheckRollup at all, so it stays cheap and reliable; the rollup is
  # fetched separately, scoped to the same AGE_CEILING_S storm-guard window
  # the terminal short-circuit's consumers (in-scope PRs only) ever reach —
  # `--search "updated:>=<date>"` measured 49 rows / 1860 contexts on
  # H-DevOps over 14d, vs a 504 for all 133. A failure or malformed result
  # here is NOT a READ-FAILURE (the authoritative listing already
  # succeeded): it just disables the short-circuit for this repo this tick,
  # so every in-scope PR falls through to the existing per-PR reads —
  # exactly the fail-safe direction the short-circuit's own comment above
  # already documents for a rollup shape change.
  rollup_call_ok=1
  if ! rollup_json="$("$GH" pr list --repo "$repo" --state open \
        --search "updated:>=$ROLLUP_SEARCH_DATE" \
        --json number,statusCheckRollup \
        --limit "$PRLIST_LIMIT" 2>/dev/null)" || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$rollup_json"; then
    rollup_call_ok=0
  fi
  if [ "$rollup_call_ok" -eq 1 ] && merged_prs_json="$(jq -c --argjson rollups "$rollup_json" '
        ( [ $rollups[] | { (.number|tostring): (.statusCheckRollup // []) } ] | add // {} ) as $by_number
        | map(.statusCheckRollup = ($by_number[(.number|tostring)] // []))
      ' <<<"$prs_json" 2>/dev/null)"; then
    prs_json="$merged_prs_json"
  else
    rollup_degraded_count=$((rollup_degraded_count + 1))
    log "ROLLUP-DEGRADED: statusCheckRollup unavailable for $repo this tick — terminal-status short-circuit disabled, every in-scope PR falls through to the per-PR reads (costs reads, never a missed recovery)."
    prs_json="$(jq -c 'map(.statusCheckRollup = [])' <<<"$prs_json" 2>/dev/null || printf '%s' "$prs_json")"
  fi

  # ── Truncation guard ──────────────────────────────────────────────────
  # A repo with more open PRs than PRLIST_LIMIT would otherwise silently
  # drop the overflow from both reconciliation and the prune keep-set (the
  # latter wiping those PRs' attempt counters every tick). A count exactly
  # equal to the limit is the only cheap truncation signal `gh pr list`
  # gives us; treat it as truncated, never as "there happen to be exactly
  # this many open PRs" (silent truncation reads as 'covered everything',
  # which this repo's doctrine forbids).
  pr_count="$(jq -r 'length' <<<"$prs_json" 2>/dev/null || echo 0)"
  if [ "$pr_count" -ge "$PRLIST_LIMIT" ]; then
    repo_truncated["$repo"]=1
    log "TRUNCATION: $repo's open-PR list returned exactly $PRLIST_LIMIT (the --limit cap) — presumed truncated. Skipping prune of this repo's state keys this tick."
    page "qa-review-reconcile: $repo's open-PR list returned exactly $PRLIST_LIMIT (the --limit cap) — presumed truncated. Some open PRs may be invisible to this tick's reconciliation. Pruning of this repo's attempt state is skipped while truncated (never wipe state for a PR that was merely invisible)."
  fi

  while IFS= read -r pr_json; do
    [ -n "$pr_json" ] || continue
    pr="$(jq -r '.number' <<<"$pr_json")"
    head_sha="$(jq -r '.headRefOid' <<<"$pr_json")"
    base="$(jq -r '.baseRefName' <<<"$pr_json")"
    is_draft="$(jq -r '.isDraft' <<<"$pr_json")"
    author_login="$(jq -r '.author.login // ""' <<<"$pr_json")"
    updated_at="$(jq -r '.updatedAt' <<<"$pr_json")"
    created_at="$(jq -r '.createdAt' <<<"$pr_json")"
    pr_url="$(jq -r '.url' <<<"$pr_json")"

    printf '%s\t%s\n' "$pr" "$head_sha" >> "$open_pr_keys_file.$repo_file_key"

    [ "$is_draft" = "true" ] && continue
    qar_repo_gated_base "$repo" "$base" || continue
    # rc1 from qa-author-slack-uid.sh is a legitimate "unknown login" skip.
    # rc>=2 (its own usage-error path) OR a shell-level 126/127 (the script
    # is missing or not executable, e.g. a deploy that lands it mode 644)
    # is a DIFFERENT failure: every PR across every repo would silently
    # "skip" that way with nothing distinguishing it from normal quiet —
    # route it to the read-failure path instead so it is counted, not lost.
    if author_uid="$("$AUTHOR_UID_SCRIPT" "$author_login" 2>/dev/null)"; then
      author_uid_rc=0
    else
      author_uid_rc=$?
    fi
    stage_attempted[author_uid]=$((stage_attempted[author_uid] + 1))
    if [ "$author_uid_rc" -ne 0 ]; then
      if [ "$author_uid_rc" -eq 1 ]; then
        # rc1 is a legitimate "unknown login" skip, NOT a stage failure — it
        # must never count toward, or ever trip, the author_uid stage
        # watchdog (a fleet-wide false page on ordinary unmapped authors).
        continue
      fi
      stage_failed[author_uid]=$((stage_failed[author_uid] + 1))
      log "READ-FAILURE: $AUTHOR_UID_SCRIPT exited $author_uid_rc (>=2, not the normal 'unknown login' rc1) for '$author_login' — counted, not treated as 'unmapped author'."
      continue
    fi
    [ -n "$author_uid" ] || continue

    # ── Terminal-status short-circuit: do not re-read a settled PR ───────
    # The PR list already carries each context's LATEST state for the head
    # commit (`statusCheckRollup`), so a PR whose head holds a terminal
    # qa-review status is classified `verdict` by qar_classify_verdict's very
    # first case — the same answer the four per-PR REST reads below would
    # produce, at zero REST cost. Without this, every tick re-read the commit,
    # timeline, reviews and combined status of EVERY open PR on EVERY repo to
    # re-derive a verdict it had already recorded: that is the per-tick read
    # amplification measured on 2026-09-17 (352 CANDIDATE/STAGE READ FAILURE
    # events in a day, all on the REST core budget the rest of the lane shares,
    # while the GraphQL budget sat unused at 5,000/5,000).
    # Fail-safe direction: anything other than a terminal state — including a
    # jq failure (empty) or `absent` — falls through to the existing reads, so
    # a rollup shape change can only cost reads, never a missed recovery.
    #
    # 2026-09-18: `statusCheckRollup` is no longer part of the LISTING call
    # above (it now arrives via a separate best-effort enrichment call,
    # merged into `.statusCheckRollup` by PR number before this loop) —
    # `gh pr list --json ...,statusCheckRollup` for ALL open PRs 504s
    # deterministically on Muso-AI/H-DevOps at 133 open PRs / 30-50 check
    # contexts each. The enrichment call is scoped to AGE_CEILING_S (see
    # ROLLUP_SEARCH_DATE) rather than "all open", because only an in-scope
    # PR (this loop already `continue`s past out-of-scope ones below) ever
    # reaches this short-circuit — scoping the rollup read to the same
    # window costs nothing a wider read would have bought. An enrichment
    # failure degrades to `.statusCheckRollup == []` for every row in that
    # repo this tick (see ROLLUP-DEGRADED below), which lands in this same
    # fail-safe fall-through, never a missed recovery.
    rollup_state="$(qar_qa_review_rollup_state "$(jq -c '.statusCheckRollup // []' <<<"$pr_json" 2>/dev/null)")" || rollup_state=""
    # The rollup carries no status DESCRIPTION, so a red it reports may be our
    # own "no review happened" write (qar_status_is_infra), which is not a
    # verdict. Only `success` is settled from the rollup alone; failure/error
    # costs one REST status read to read the description, and falls through to
    # the full reads if that read fails or the red is infrastructure.
    case "$rollup_state" in
      success)
        terminal_skipped=$((terminal_skipped + 1))
        repo_terminal_skipped=$((repo_terminal_skipped + 1))
        continue
        ;;
      failure|error)
        if rollup_status_json="$("$GH" api "repos/$repo/commits/$head_sha/status?per_page=100" 2>/dev/null)" \
           && rollup_desc="$(qar_qa_review_status_field "$rollup_status_json" description)" \
           && ! qar_status_is_infra "$rollup_desc"; then
          terminal_skipped=$((terminal_skipped + 1))
          repo_terminal_skipped=$((repo_terminal_skipped + 1))
          continue
        fi
        ;;
    esac

    # ── head-push trigger time ───────────────────────────────────────────
    repo_reads_attempted=$((repo_reads_attempted + 1))
    stage_attempted[commit]=$((stage_attempted[commit] + 1))
    if ! gh_read commit_json api "repos/$repo/commits/$head_sha"; then
      report_gh_read_failure "READ-FAILURE: could not fetch commit $repo@${head_sha:0:7} — counted, not treated as 'no verdict'."
      repo_reads_failed=$((repo_reads_failed + 1))
      repo_failed_classes="${repo_failed_classes:+$repo_failed_classes,}commit"
      stage_failed[commit]=$((stage_failed[commit] + 1))
      continue
    fi
    committer_date="$(jq -r '.commit.committer.date // empty' <<<"$commit_json")"
    if [ -z "$committer_date" ]; then
      log "READ-FAILURE: commit $repo@${head_sha:0:7} has no committer date — skipping."
      repo_reads_failed=$((repo_reads_failed + 1))
      repo_failed_classes="${repo_failed_classes:+$repo_failed_classes,}commit"
      stage_failed[commit]=$((stage_failed[commit] + 1))
      continue
    fi
    if ! head_pushed_epoch="$(iso_to_epoch "$committer_date")"; then
      log "READ-FAILURE: could not parse committer date '$committer_date' for $repo@${head_sha:0:7}."
      repo_reads_failed=$((repo_reads_failed + 1))
      repo_failed_classes="${repo_failed_classes:+$repo_failed_classes,}commit"
      stage_failed[commit]=$((stage_failed[commit] + 1))
      continue
    fi

    # trigger_time = max(head-push[only if <= now], PR createdAt[, ready_for_review
    # below]). createdAt alone (not committer.date alone) closes a
    # long-lived-branch gap: a non-draft PR opened today whose last commit is
    # 20+ days old has no ready_for_review event (it was never a draft) and
    # would otherwise sit in pre_epoch_ignored for its entire life on
    # committer.date alone. gh pr list --json already returns createdAt, so
    # this costs zero extra API calls.
    #
    # committer.date is author-controlled (GIT_COMMITTER_DATE). A
    # future-dated commit must be treated as UNUSABLE, not clamped to "now":
    # clamping re-clamps every tick (since "now" keeps moving too), which
    # restarts qar_grace_ok's window on every tick and never lets it elapse —
    # permanently un-reconciling that PR. Discard the head-push timestamp
    # entirely when it postdates "now" and fall back to createdAt, which
    # GitHub (not the author) controls.
    created_epoch="$(iso_to_epoch "$created_at")" || created_epoch=""
    if [ "$head_pushed_epoch" -gt "$NOW_EPOCH" ] 2>/dev/null; then
      log "WARN: commit $repo@${head_sha:0:7} has a future committer date ($committer_date) — discarding it as untrusted (author-controlled clock), falling back to PR createdAt."
      trigger_time="$created_epoch"
    else
      trigger_time="$(qar_max_epoch "$head_pushed_epoch" "$created_epoch")"
    fi

    repo_epoch="$(qar_state_repo_epoch "$state_json" "$repo")"

    if ! qar_trigger_in_scope "$trigger_time" "$repo_epoch" "$NOW_EPOCH" "$AGE_CEILING_S"; then
      # Lazy ready_for_review lookup — only for what the head-push bound
      # would otherwise exclude, cached per-PR keyed on updatedAt.
      ready_epoch="$(qar_ready_cache_get "$state_json" "$repo" "$pr" "$updated_at")"
      if [ -z "$ready_epoch" ]; then
        # --paginate: a busy PR's timeline can exceed 100 events, and events
        # are returned oldest-first, so the LATEST ready_for_review transition
        # (the one that matters) could otherwise sit past page 1 and be
        # missed entirely, permanently excluding a genuinely lost review from
        # the age-scope bound. --paginate concatenates every page's array
        # into one continuous array (gh's documented behavior for
        # array-typed responses), so downstream jq is unaffected.
        repo_reads_attempted=$((repo_reads_attempted + 1))
        stage_attempted[timeline]=$((stage_attempted[timeline] + 1))
        if gh_read timeline_json api --paginate "repos/$repo/issues/$pr/timeline?per_page=100"; then
          ready_iso="$(jq -r '[.[] | select(.event == "ready_for_review")] | last | .created_at // empty' <<<"$timeline_json")"
          if [ -n "$ready_iso" ] && ready_epoch="$(iso_to_epoch "$ready_iso")"; then
            state_json="$(qar_ready_cache_put "$state_json" "$repo" "$pr" "$updated_at" "$ready_epoch")"
          else
            ready_epoch=""
          fi
        else
          report_gh_read_failure "READ-FAILURE: could not fetch timeline for $repo#$pr — treating as no ready_for_review signal this tick (safe direction: exclusion, never inclusion, under a read failure here)."
          repo_reads_failed=$((repo_reads_failed + 1))
          repo_failed_classes="${repo_failed_classes:+$repo_failed_classes,}timeline"
          stage_failed[timeline]=$((stage_failed[timeline] + 1))
          ready_epoch=""
        fi
      fi
      trigger_time="$(qar_max_epoch "$trigger_time" "$ready_epoch")"
      if ! qar_trigger_in_scope "$trigger_time" "$repo_epoch" "$NOW_EPOCH" "$AGE_CEILING_S"; then
        pre_epoch_ignored_total=$((pre_epoch_ignored_total + 1))
        pre_epoch_ignored_by_repo["$repo"]=$(( ${pre_epoch_ignored_by_repo["$repo"]:-0} + 1 ))
        continue
      fi
    fi

    [ "$SKIP_DISPATCH_THIS_TICK" -eq 1 ] && continue

    # ── Verdict ─────────────────────────────────────────────────────────
    # --paginate: the live API returns reviews OLDEST-first, so a PR with
    # >100 reviews (hydra#821 already has 25) would otherwise hide the
    # newest review — the one whose .commit_id matches the CURRENT head —
    # on page 2, reading as "no verdict" forever. --paginate concatenates
    # every page's array into one continuous array (gh's documented
    # behavior for array-typed responses), so downstream jq is unaffected.
    repo_reads_attempted=$((repo_reads_attempted + 1))
    stage_attempted[reviews]=$((stage_attempted[reviews] + 1))
    if ! gh_read reviews_json api --paginate "repos/$repo/pulls/$pr/reviews?per_page=100"; then
      report_gh_read_failure "READ-FAILURE: could not fetch reviews for $repo#$pr — counted, not treated as 'no verdict'."
      repo_reads_failed=$((repo_reads_failed + 1))
      repo_failed_classes="${repo_failed_classes:+$repo_failed_classes,}reviews"
      stage_failed[reviews]=$((stage_failed[reviews] + 1))
      continue
    fi
    has_bot_review=0
    qar_has_bot_review "$reviews_json" "$head_sha" "$bot_logins_json" && has_bot_review=1

    repo_reads_attempted=$((repo_reads_attempted + 1))
    stage_attempted[status]=$((stage_attempted[status] + 1))
    if ! gh_read status_json api "repos/$repo/commits/$head_sha/status?per_page=100"; then
      report_gh_read_failure "READ-FAILURE: could not fetch combined status for $repo@${head_sha:0:7} — counted, not treated as 'no verdict'."
      repo_reads_failed=$((repo_reads_failed + 1))
      repo_failed_classes="${repo_failed_classes:+$repo_failed_classes,}status"
      stage_failed[status]=$((stage_failed[status] + 1))
      continue
    fi
    if ! status_state="$(qar_qa_review_status_state "$status_json")"; then
      log "READ-FAILURE: could not parse combined status JSON for $repo@${head_sha:0:7} (jq failed) — counted, not treated as 'no verdict'."
      repo_reads_failed=$((repo_reads_failed + 1))
      repo_failed_classes="${repo_failed_classes:+$repo_failed_classes,}status"
      stage_failed[status]=$((stage_failed[status] + 1))
      continue
    fi

    gate_rc=0
    qa_policy_has "$POLICY" '.merge_gate_repos' "$repo" || gate_rc=$?
    if [ "$gate_rc" -eq 2 ]; then
      log "READ-FAILURE: cannot evaluate .merge_gate_repos for $repo in $POLICY — counted, not treated as 'no verdict'."
      continue
    fi
    gated=0; [ "$gate_rc" -eq 0 ] && gated=1

    status_desc="$(qar_qa_review_status_field "$status_json" description)" || status_desc=""
    # pending age from the status's own updated_at; unparseable/absent = treat as
    # stale (a bounded extra dispatch beats suppressing forever).
    pending_age_s=""
    if [ "$status_state" = "pending" ]; then
      status_updated="$(qar_qa_review_status_field "$status_json" updated_at)" || status_updated=""
      if status_updated_epoch="$(iso_to_epoch "$status_updated" 2>/dev/null)" && [ -n "$status_updated_epoch" ]; then
        pending_age_s=$((NOW_EPOCH - status_updated_epoch))
      else
        pending_age_s=$((CRON_STALE_S + 1))
      fi
    fi
    verdict="$(qar_classify_verdict "$has_bot_review" "$status_state" "$gated" "$status_desc" "$pending_age_s" "$CRON_STALE_S")"
    [ "$verdict" = "candidate" ] || continue

    key="${repo}#${pr}@${head_sha}"
    entry="$(qar_state_entry "$state_json" "$key")"
    attempts=0; last_attempt=""; paged=0
    if [ "$entry" != "null" ] && [ -n "$entry" ]; then
      attempts="$(jq -r '.attempts // 0' <<<"$entry")"
      last_attempt="$(jq -r '.last_attempt_epoch // empty' <<<"$entry")"
      paged_bool="$(jq -r '.paged // false' <<<"$entry")"
      [ "$paged_bool" = "true" ] && paged=1
    fi

    qar_grace_ok "$NOW_EPOCH" "$trigger_time" "$GRACE_S" || continue

    # ORDER IS LOAD-BEARING: cooldown and the freshness suppressor BOTH gate the
    # exhaustion check below. Evaluating exhaustion first would declare the FINAL
    # attempt lost while it is still legitimately in flight: attempt 2 dispatches,
    # the serialized qa lane holds its one-shot queued for 15 minutes, and the next
    # tick sees attempts == MAX_ATTEMPTS and pages -- driving a merge-gated PR red
    # over a review that was about to run. Cooldown proves the last attempt has had
    # its chance; the suppressor proves nothing is running right now.
    qar_cooldown_ok "$NOW_EPOCH" "$last_attempt" "$COOLDOWN_S" || continue

    # ── Suppressor ──────────────────────────────────────────────────────
    job_name="qa-autoreview-pr-${repo//\//-}-${pr}"
    cron_state="$(qar_cron_state "$cron_json" "$job_name" "$((NOW_EPOCH * 1000))" "$CRON_STALE_S")"
    case "$cron_state" in
      running|queued) continue ;;
      running-stale|queued-stale)
        # Stale is NOT in-flight evidence — fall through to the normal
        # candidate path (grace/cooldown/attempts/global-cap below) so this
        # gets re-dispatched and, on exhaustion, paged/driven red, instead of
        # suppressing on a row that will never fire or complete on its own.
        # Re-dispatch also self-clears the wedged row (qa-dispatch-pr-review.sh's
        # idempotency block removes any existing job of this name first).
        log "STALE cron state ($cron_state) for $job_name — not treated as in-flight (older than the ${CRON_STALE_S}s freshness budget); proceeding to the candidate path."
        ;;
      unknown)
        # Cannot confirm absence. Do not suppress forever: only proceed once
        # we are past 2x the normal grace window since trigger_time.
        qar_grace_ok "$NOW_EPOCH" "$trigger_time" "$((GRACE_S * 2))" || continue
        if [ "$cron_read_failed" -eq 1 ]; then
          log "UNKNOWN cron set for $job_name (cron list read FAILED) past 2x grace — acting on GitHub state anyway."
        else
          log "UNKNOWN cron set for $job_name (hasMore=true) past 2x grace — acting on GitHub state anyway."
        fi
        ;;
    esac

    if qar_attempts_exhausted "$attempts" "$MAX_ATTEMPTS"; then
      if [ "$paged" -eq 0 ]; then
        # A per-tick cap on the page + red-status actuator, mirroring
        # GLOBAL_CAP's deferred style: a systematic false positive (e.g. a
        # broken dispatcher) can walk N keys to exhaustion in one tick, and
        # without this cap that fires N Slack pages and N red statuses
        # unbounded. paged stays 0 for a deferred key, so a later tick
        # retries it (never silently dropped, exactly like GLOBAL_CAP).
        if [ "$paged_this_tick" -lt "$PAGE_CAP" ]; then
          log "EXHAUSTED: $key — $attempts attempts, no verdict. Paging."
          # Drive the gate red FIRST and unconditionally: it is the merge-blocking
          # truth and is idempotent, so it must not depend on Slack being up.
          if [ "$gated" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
            "$STATUS_SCRIPT" "$repo" "$head_sha" failure "QA review lost — reconciler exhausted $attempts attempts" >/dev/null 2>&1 || \
              log "WARN: $STATUS_SCRIPT failed to drive $repo@${head_sha:0:7} red."
          fi
          # Persist paged=true ONLY on confirmed delivery. An undelivered alert
          # must leave paged=false so a later tick retries it, or a transient
          # Slack outage silently converts "lost review" into "never mentioned".
          if page_confirmed "qa-review-reconcile: QA review lost for ${repo}#${pr} (head ${head_sha:0:7}). $attempts re-dispatch attempts made, still no verdict. PR: $pr_url"; then
            state_json="$(qar_state_put "$state_json" "$key" "$attempts" "${last_attempt:-$NOW_EPOCH}" 1)"
          else
            log "WARN: exhaustion page for $key was NOT delivered — leaving paged=false so a later tick retries it."
          fi
          paged_this_tick=$((paged_this_tick + 1))
        else
          page_cap_deferred=$((page_cap_deferred + 1))
        fi
      fi
      continue
    fi


    [ "$dispatched_this_tick" -lt "$GLOBAL_CAP" ] || { log "CAP: global per-tick dispatch cap ($GLOBAL_CAP) reached — leaving $key for a later tick."; continue; }

    if [ "$DRY_RUN" -eq 1 ]; then
      log "[dry-run] WOULD DISPATCH $key (attempt $((attempts + 1))/$MAX_ATTEMPTS) — state would advance (attempts, last_attempt_epoch)."
      dispatched_this_tick=$((dispatched_this_tick + 1))
      continue
    fi

    log "DISPATCH: $key (attempt $((attempts + 1))/$MAX_ATTEMPTS)"
    dispatch_rc=0
    "$DISPATCH_SCRIPT" "$pr" "$head_sha" "$repo" "$author_uid" || dispatch_rc=$?
    # Invariant: `attempts` bounds dispatches that REACHED the gateway. rc 75
    # (EX_TEMPFAIL) means the dispatcher never got to it, so it is not an
    # attempt; cooldown (last_attempt_epoch still advances) + GLOBAL_CAP + the
    # consecutive-unreachable-ticks page bound those. Every other non-zero rc
    # stays counted — a systematically broken dispatcher must still hit the
    # attempts cap, not retry forever.
    if [ "$dispatch_rc" -eq 75 ]; then
      log "WARN: $DISPATCH_SCRIPT exited 75 for $key (gateway unreachable — NOT counted as an attempt; cooldown still applies)."
      state_json="$(qar_state_put_unreachable "$state_json" "$key" "$attempts" "$NOW_EPOCH" "$paged")"
      unreachable_this_tick=$((unreachable_this_tick + 1))
    else
      [ "$dispatch_rc" -eq 0 ] || log "WARN: $DISPATCH_SCRIPT exited $dispatch_rc for $key (counted as an attempt regardless — a systematically broken dispatcher must still hit the attempts cap, not retry forever)."
      state_json="$(qar_state_put "$state_json" "$key" "$((attempts + 1))" "$NOW_EPOCH" 0)"
      [ "$dispatch_rc" -ne 0 ] || reached_this_tick=$((reached_this_tick + 1))
    fi
    dispatched_this_tick=$((dispatched_this_tick + 1))
  done < <(jq -c '.[]' <<<"$prs_json")

  # PRs whose head already showed a terminal qa-review status this tick —
  # they consumed zero per-PR reads (see the loop's short-circuit). Reported
  # per repo so a reader can compare read volume against the PR count.
  if [ "$repo_terminal_skipped" -gt 0 ]; then
    log "TERMINAL SKIP: $repo — $repo_terminal_skipped PR(s) already carried a terminal qa-review status on their head commit; no per-PR read issued for them this tick."
  fi

  # ── Candidate-level (per-PR) read-failure watchdog ─────────────────────
  # A durable failure that leaves `gh pr list` working but every per-PR read
  # failing (a revoked token scope, a permissions change, a sustained
  # secondary rate limit) must page on its own — the repo-listing counter
  # above never sees it (listing itself keeps succeeding), and unpaged it
  # silently suppresses every review for this repo forever. "Every read
  # failed" is call-level (commit/timeline/reviews/status attempts), not
  # PR-level, so a single successful read anywhere this tick resets it — a
  # partial degradation is not this failure's signature.
  if [ "$repo_reads_attempted" -gt 0 ] && [ "$repo_reads_failed" -ge "$repo_reads_attempted" ]; then
    cand_fail_n=$(( $(qar_state_repo_candidate_failure_count "$state_json" "$repo") + 1 ))
    state_json="$(qar_state_set_repo_candidate_failure_count "$state_json" "$repo" "$cand_fail_n")"
    log "CANDIDATE READ FAILURE: $repo — all $repo_reads_attempted per-PR read(s) failed this tick (classes: $repo_failed_classes); consecutive count now $cand_fail_n."
    if [ "$cand_fail_n" -ge "$TICK_FAIL_THRESHOLD" ]; then
      page_read_failure "$repo" "__candidate__" \
        "qa-review-reconcile: $repo — every per-PR read (classes: $repo_failed_classes) has failed for $cand_fail_n consecutive ticks. Reviews for this repo may be silently unclassifiable — this is the invisible-loss class this reconciler exists to kill."
    fi
  else
    state_json="$(qar_state_set_repo_candidate_failure_count "$state_json" "$repo" 0)"
    # Recovery clears the suppression window too: a repo that breaks, recovers,
    # then breaks again inside the interval must page again, not inherit the
    # previous incident's silence.
    state_json="$(qar_state_set_read_fail_last_alert "$state_json" "$repo" "__candidate__" 0)"
  fi

  # ── Per-repo, per-STAGE read-failure watchdog ──────────────────────────
  # Unlike the aggregate above (which only pages when EVERY attempted read
  # failed), this pages when a SINGLE stage (commit/timeline/reviews/status/
  # author_uid) has failed every attempt of ITSELF this tick, independent of
  # whether other stages stayed healthy — closing the hole where e.g. the
  # reviews endpoint alone fails every tick while commit reads keep
  # succeeding: the aggregate never fires (failed < attempted overall), but
  # every affected PR is silently unclassifiable on its reviews read forever.
  for stage in commit timeline reviews status author_uid; do
    st_attempted="${stage_attempted[$stage]}"
    st_failed="${stage_failed[$stage]}"
    if [ "$st_attempted" -eq 0 ]; then
      # Stage not exercised this tick (e.g. no PR reached it) — no evidence
      # either way, leave the durable counter untouched.
      continue
    fi
    if [ "$st_failed" -lt "$st_attempted" ]; then
      # At least one success this tick for this stage — reset. Clearing the
      # page stamp alongside the counter keeps the dedupe from carrying one
      # incident's silence into the next (see the candidate branch above).
      state_json="$(qar_state_set_stage_failure_count "$state_json" "$repo" "$stage" 0)"
      state_json="$(qar_state_set_read_fail_last_alert "$state_json" "$repo" "$stage" 0)"
      continue
    fi
    # Every attempt of this stage failed this tick (and at least one was
    # attempted): increment the durable per-repo-per-stage counter.
    stage_fail_n=$(( $(qar_state_stage_failure_count "$state_json" "$repo" "$stage") + 1 ))
    state_json="$(qar_state_set_stage_failure_count "$state_json" "$repo" "$stage" "$stage_fail_n")"
    log "STAGE READ FAILURE: $repo/$stage — all $st_attempted attempt(s) of this stage failed this tick; consecutive count now $stage_fail_n."
    if [ "$stage_fail_n" -ge "$TICK_FAIL_THRESHOLD" ]; then
      page_read_failure "$repo" "$stage" \
        "qa-review-reconcile: $repo — the '$stage' read stage has failed every attempt for $stage_fail_n consecutive ticks. PRs in this repo may be silently unclassifiable on this stage alone (other stages may be healthy) — this is the invisible-loss class this reconciler exists to kill."
    fi
  done
done

# One tick-level line for the whole rate-limit cause (never one per PR/repo).
if [ "$rate_limit_failed_reads" -gt 0 ]; then
  log "TOKEN EXHAUSTED — ${rate_limit_probe:-core remaining unknown}; $rate_limit_failed_reads per-PR read(s) failed on this cause. This is the shared adk47 bucket, not a permissions problem."
fi

if [ "$page_cap_deferred" -gt 0 ]; then
  log "PAGE CAP: paged $paged_this_tick exhausted key(s) this tick (cap $PAGE_CAP), and $page_cap_deferred more...deferred to a later tick."
fi

if [ "$pre_epoch_ignored_total" -gt 0 ]; then
  by_repo=""
  for r in "${!pre_epoch_ignored_by_repo[@]}"; do
    by_repo="${by_repo}${by_repo:+, }${r}=${pre_epoch_ignored_by_repo[$r]}"
  done
  log "pre-epoch ignored: $pre_epoch_ignored_total PRs across ${#pre_epoch_ignored_by_repo[@]} repos ($by_repo)"
fi

# ── Gateway-unreachable watchdog ───────────────────────────────────────────
# rc-75 dispatches are not attempts, so this replaces the bound the attempts
# cap used to give: a tick with >=1 unreachable and 0 successful dispatches
# advances the counter; any rc-0 dispatch resets it; a tick with neither leaves
# it alone. At TICK_FAIL_THRESHOLD, page once per READ_FAIL_ALERT_INTERVAL.
if [ "$DRY_RUN" -eq 0 ]; then
  if [ "$reached_this_tick" -gt 0 ]; then
    state_json="$(qar_state_set_meta_unreachable_ticks "$state_json" 0)"
  elif [ "$unreachable_this_tick" -gt 0 ]; then
    unreach_n=$(( $(qar_state_meta_unreachable_ticks "$state_json") + 1 ))
    state_json="$(qar_state_set_meta_unreachable_ticks "$state_json" "$unreach_n")"
    log "GATEWAY UNREACHABLE: $unreachable_this_tick dispatch(es) never reached the gateway this tick; consecutive count now $unreach_n."
    if [ "$unreach_n" -ge "$TICK_FAIL_THRESHOLD" ]; then
      unreach_last="$(qar_state_meta_unreachable_last_alert "$state_json")"
      if qar_read_fail_should_page "$unreach_last" "$NOW_EPOCH" "$READ_FAIL_ALERT_INTERVAL"; then
        waiting_heads="$(jq '[to_entries[] | select(.key != "__meta__" and .key != "__repo_epochs__" and .key != "__ready_cache__") | select((.value.unreachable_attempts // 0) > 0)] | length' <<<"$state_json")"
        if page_confirmed "qa-review-reconcile: the openclaw gateway has been unreachable for $unreach_n consecutive ticks; $waiting_heads PR head(s) are waiting for a review that could not be dispatched (not counted as attempts)."; then
          state_json="$(qar_state_set_meta_unreachable_last_alert "$state_json" "$NOW_EPOCH")"
        else
          log "WARN: gateway-unreachable page was NOT confirmed delivered — suppression stamp NOT advanced; the next tick retries."
        fi
      fi
    fi
  fi
fi

# ── Whole-tick read-failure watchdog ───────────────────────────────────────
meta_failures="$(qar_state_meta_failures "$state_json")"
if [ "$total_repo_count" -gt 0 ] && [ "$failed_repo_count" -eq "$total_repo_count" ]; then
  meta_failures=$((meta_failures + 1))
  log "WHOLE-TICK FAILURE: all $total_repo_count repos failed to list — consecutive count now $meta_failures."
  if [ "$meta_failures" -ge "$TICK_FAIL_THRESHOLD" ]; then
    page "qa-review-reconcile: $meta_failures consecutive ticks failed to read ANY repo's PR list. The reconciler itself may be broken (GitHub auth/network on node-8?)."
  fi
else
  meta_failures=0
fi
state_json="$(qar_state_set_meta_failures "$state_json" "$meta_failures")"

# ── Prune: drop entries for closed/merged PRs or superseded head shas ─────
# Conservative: a repo whose listing failed THIS tick, or whose listing came
# back truncated (exactly PRLIST_LIMIT rows, see the truncation guard above),
# is left untouched (we cannot tell open-vs-closed for every PR of that repo
# right now), never pruned on stale/partial info.
# A jq failure enumerating keys must NOT fall through to an empty key list
# (that would make qar_state_keep_only wipe every per-PR attempts/cooldown
# counter this tick) — skip pruning entirely and page instead, fail-closed
# like every other state-touching failure in this script.
if ! existing_keys="$(jq -r 'keys[] | select(. != "__meta__" and . != "__repo_epochs__" and . != "__ready_cache__")' <<<"$state_json" 2>/dev/null)"; then
  log "READ-FAILURE: could not enumerate $STATE_FILE keys for pruning (jq failed) — skipping prune this tick (never let a jq failure silently wipe every attempt counter)."
  page "qa-review-reconcile: could not enumerate state.json keys for pruning this tick (jq failed). Prune skipped; existing attempt counters left untouched (fail-closed)."
  rm -f "$open_pr_keys_file".*
else
  keep_keys=""
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    k_repo="${k%%#*}"
    rest="${k#*#}"
    k_pr="${rest%%@*}"
    k_sha="${rest#*@}"
    if [ -z "${repo_listed_ok[$k_repo]:-}" ] || [ -n "${repo_truncated[$k_repo]:-}" ]; then
      keep_keys="${keep_keys}${k}
"
      continue
    fi
    k_repo_file_key="${k_repo//\//-}"
    if [ -f "$open_pr_keys_file.$k_repo_file_key" ] && grep -qF "$(printf '%s\t%s' "$k_pr" "$k_sha")" "$open_pr_keys_file.$k_repo_file_key"; then
      keep_keys="${keep_keys}${k}
"
    fi
  done <<<"$existing_keys"
  rm -f "$open_pr_keys_file".*
  state_json="$(qar_state_keep_only "$state_json" "$keep_keys")"
fi

# ── Persist ─────────────────────────────────────────────────────────────
if [ "$DRY_RUN" -eq 1 ]; then
  log "[dry-run] state NOT persisted (dry-run rehearses classification only)."
else
  if qar_state_write_atomic "$STATE_FILE" "$state_json"; then
    log "state written to $STATE_FILE (dispatched $dispatched_this_tick this tick)."
  else
    log "ERROR: failed to write state to $STATE_FILE."
    page "qa-review-reconcile: failed to write state file $STATE_FILE — attempt bookkeeping for this tick may be lost."
    exit 1
  fi
fi

log "tick complete: repos=$total_repo_count failed_repo_listings=$failed_repo_count dispatched=$dispatched_this_tick pre_epoch_ignored=$pre_epoch_ignored_total terminal_skipped=$terminal_skipped rollup_degraded=$rollup_degraded_count"
