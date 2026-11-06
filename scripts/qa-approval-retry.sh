#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# QA Approval Retry
#
# Repairs a race that silently voids the approval half of the QA bot: the
# review runs while CI is still in flight, the approval guard correctly
# refuses on a PENDING check, and NOTHING ever asks again.
#
# The dispatch producer in each external repo fires on
# `pull_request: [opened, synchronize, ...]` — i.e. at PUSH time, in PARALLEL
# with CI, not after it. The review lands minutes later while the slowest
# checks are still running. Guard 8 of qa-pr-approve.sh counts PENDING as
# non-passing (correctly, and fail-closed), so it exits 8. The reviewing
# skill is explicitly told not to retry ("do NOT retry blindly"), and
# qa-review-reconcile.sh only detects a MISSING REVIEW — it has no notion of
# a withheld approval. So the verdict is written, the approval is dropped,
# and the PR sits at REVIEW_REQUIRED forever.
#
# Measured before this script existed: Mariia (azure-kirin) has been a scoped
# approver for Muso-AI/web-credits-next since 2026-08-13, and across her 12
# most recent PRs there the bot recorded COMMENTED twelve times and APPROVED
# zero times. The grant had never once fired. Every one of those reviews said
# GO. web-credits-next#636 is the worked example: review 10:51:41, `quality`
# green at 10:55:20, no approval ever.
#
# ── THIS SCRIPT GRANTS NO AUTHORITY ──────────────────────────────────────
# It only RE-ASKS. Every gate stays exactly where it was: qa-pr-approve.sh
# remains the sole authority on CI-green, the requester allowlist and its
# scope, self-approval, sensitive paths, and the audit log — and it
# independently re-derives the PR's real author and base branch from the API
# rather than trusting anything passed in here. A PR outside a scoped
# approver's grant exits 5 through this path exactly as it does through the
# skill. Deliberately, this script contains NO copy of the CI-green logic:
# a second implementation of Guard 8 could drift from the first, and the
# advisory-check prefix matching is subtle enough that a drifted copy would
# approve something the real guard refuses.
#
# The requester UID passed here is the PR AUTHOR's own UID, resolved through
# scripts/lib/qa-author-slack-uid.sh — identical to what the dispatch lane
# already passes for the review itself. So the authority model is unchanged;
# only the TIMING is repaired.
#
# ── WHY A SYSTEMD TIMER ──────────────────────────────────────────────────
# Same reasoning as qa-review-reconcile.sh: this is a runtime operational
# loop against live GitHub state, not a CI gate. CLAUDE.md's extension
# decision tree routes those to a timer on node-8 — routing runtime ops
# through GH Actions has caused two-CD-paths drift before. It must also not
# be an openclaw cron: it would then compete with the reviews themselves for
# the serialized `qa` agent lane, and would die in the same gateway restart
# that already loses dispatches.
#
# ── WHY STATELESS ────────────────────────────────────────────────────────
# There is no attempts/cooldown state file, on purpose. The terminating
# condition is self-evident from GitHub itself: once the bot's approval
# lands, "no bot APPROVED review on the live head" stops holding and the PR
# is never considered again. A state file would buy nothing and would
# reintroduce a known failure mode — a Type=oneshot unit that persists state
# only at the END of the tick loses all of it to systemd's default 90s
# SIGTERM (see qa-review-reconcile.service's TimeoutStartSec comment, which
# exists for exactly that reason). The cost of statelessness is that a PR
# whose approval is permanently out of scope gets re-asked once per tick;
# that is one cheap API call against a small candidate set, and it is logged
# at DECLINED rather than silently swallowed.
#
# ── QUOTA BOUNDS (MUS-6088) ──────────────────────────────────────────────
# This lane shares the adk47 REST bucket with every other QA script; on 8 Oct
# core went 3296 -> 5000 used between 08:33Z and 08:51Z, and the :46 tick read
# into an empty bucket. Two env knobs bound what one tick can spend. Neither
# sleeps, retries or keeps state (see WHY STATELESS): a stand-down is a
# normal, logged, exit-0 outcome, never a page.
#   QA_APPROVAL_RETRY_RATE_FLOOR  (default 1000) stop the tick when the core
#       bucket's `remaining` is below this. Probed before every repo.
#   QA_APPROVAL_RETRY_MAX_CALLS   (default 600) stop the tick after this many
#       REST calls issued by this script (see qar_spend below).
#
# Exit codes: 0 tick completed (declines are normal) | 2 usage/env |
#             4 a PR was approved but could NOT be marked unsafe (every channel
#               failed) — the most severe outcome, checked before 3 |
#             3 total read blackout — either every repo failed its open-PR list
#               read with nothing evaluated, or every candidate failed its
#               reviews read. Both mean nothing can be repaired this tick.
# A truncated PR list (a repo at the --limit cap) pages but does NOT change the
# exit code: the PRs that WERE returned are still swept, so the tick did real
# work; it is simply not complete, and the page says so.
# ──────────────────────────────────────────────────────────────

_QAR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYDRA_ROOT="${HYDRA_ROOT:-$(cd "$_QAR_DIR/.." && pwd)}"

QA_GH="${QA_GH:-$HYDRA_ROOT/scripts/qa-gh.sh}"
QA_APPROVE="${QA_APPROVE:-$HYDRA_ROOT/scripts/qa-pr-approve.sh}"
QA_AUTHOR_UID="${QA_AUTHOR_UID:-$HYDRA_ROOT/scripts/lib/qa-author-slack-uid.sh}"
QA_REPO_ALLOWLIST="${QA_REPO_ALLOWLIST:-$HYDRA_ROOT/scripts/lib/qa-external-repo-allowlist.sh}"
QA_REVIEW_STATUS="${QA_REVIEW_STATUS:-$HYDRA_ROOT/scripts/qa-review-status.sh}"
QA_SLACK_DM="${QA_SLACK_DM:-$HYDRA_ROOT/scripts/qa-slack-dm.sh}"
POLICY="${QA_APPROVAL_RETRY_POLICY:-$HYDRA_ROOT/policies/qa-approval-policy.json}"
DRY_RUN="${QA_APPROVAL_RETRY_DRY_RUN:-0}"

# The wrapper's own audit-log dir defaults to the RELATIVE `api-logs/github`
# (qa-pr-approve.sh:74) and it refuses to approve unlogged. Every caller until
# now was an agent, which supplied a workspace cwd; this timer is the first
# non-agent caller and a systemd service sets no WorkingDirectory, so an
# unpinned run would silently create and write `/api-logs/github` as root.
# Name the path here so the lane's approvals and its alert comments land in one
# real, stable place.
ALERT_LOG_DIR="${QA_APPROVAL_RETRY_LOG_DIR:-/var/lib/hydra/qa-approval-retry/api-logs/github}"
export QA_PR_APPROVE_LOG_DIR="$ALERT_LOG_DIR"

# Cooldown stamp for the total-blackout page (see the block at the bottom).
BLACKOUT_STAMP="${QA_APPROVAL_RETRY_BLACKOUT_STAMP:-/var/lib/hydra/qa-approval-retry/last-blackout-page}"
TRUNCATION_STAMP="${QA_APPROVAL_RETRY_TRUNCATION_STAMP:-/var/lib/hydra/qa-approval-retry/last-truncation-page}"
# Matches qa-review-reconcile.sh's PRLIST_LIMIT default. Raised 300 -> 1000 on
# 2026-10-20 (Fable QA eval, F2): Muso-AI/H-DevOps reached 330 open PRs and every
# tick was truncated there, so withheld approvals on the repo with the slowest CI
# were never re-asked. `gh pr list` pages internally (GraphQL, 100 per page) up to
# --limit, so a higher cap costs a few GraphQL pages, not REST calls. The cap is
# still DETECTED below, because headroom is not a guarantee.
PRLIST_LIMIT="${QA_APPROVAL_RETRY_PRLIST_LIMIT:-1000}"
BLACKOUT_PAGE_COOLDOWN="${QA_APPROVAL_RETRY_BLACKOUT_COOLDOWN:-3600}"
RATE_FLOOR="${QA_APPROVAL_RETRY_RATE_FLOOR:-1000}"
MAX_CALLS="${QA_APPROVAL_RETRY_MAX_CALLS:-600}"
# Hard cap on pages (100 reviews each) read for ONE PR; bounds a single candidate.
MAX_REVIEW_PAGES=10

# Overridable so the suite can stub it: slack_notify_critical sends a REAL page
# through `muso slack dm`, and an unstubbed test run has fired real alerts here
# before.
QA_SLACK_NOTIFY_LIB="${QA_SLACK_NOTIFY_LIB:-$_QAR_DIR/lib/slack-notify.sh}"
# shellcheck source=lib/slack-notify.sh
source "$QA_SLACK_NOTIFY_LIB"

die() { echo "qa-approval-retry: $2" >&2; exit "$1"; }
log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] qa-approval-retry: $*"; }

# DRY_RUN is a SAFETY flag, and every comparison against it tests for the
# literal 1 — so any other spelling (`true`, `yes`, `TRUE`) falls through to
# LIVE approval writes while the tick-start line cheerfully logs `dry_run=true`.
# A malformed safety setting must never resolve to "do the real thing", so this
# refuses rather than guessing: 0 and 1 are the whole domain.
case "$DRY_RUN" in
  0|1) ;;
  *) die 2 "QA_APPROVAL_RETRY_DRY_RUN must be 0 or 1, got '$DRY_RUN' — refusing the tick. Any other value falls through to LIVE approval writes while the log claims dry_run=$DRY_RUN." ;;
esac

# A malformed cooldown must not become silence. `[ 5 -ge abc ]` is an integer
# error, and a failing condition in an `elif` falls straight through to the
# suppression branch — so a typo in this override would withhold the ONLY
# out-of-band signal for the entire outage, which is the opposite of what the
# pager is for. Fall back to the default rather than refusing the tick: a
# cooldown typo should not also stop approvals from being repaired.
# 0 is accepted and means "no cooldown". (DRY_RUN above refuses instead, because
# there the unsafe direction is a LIVE WRITE, not a missing page.)
case "$PRLIST_LIMIT" in
  ''|*[!0-9]*|0)
    log "WARN: QA_APPROVAL_RETRY_PRLIST_LIMIT='$PRLIST_LIMIT' is not a positive integer — falling back to 1000. A bad value here would make the truncation comparison an integer error and silently disable the guard."
    PRLIST_LIMIT=1000 ;;
esac

case "$BLACKOUT_PAGE_COOLDOWN" in
  ''|*[!0-9]*)
    log "WARN: QA_APPROVAL_RETRY_BLACKOUT_COOLDOWN='$BLACKOUT_PAGE_COOLDOWN' is not a non-negative integer — falling back to 3600s, because a bad override must never silence the blackout page."
    BLACKOUT_PAGE_COOLDOWN=3600 ;;
esac

case "$RATE_FLOOR" in
  ''|*[!0-9]*)
    log "WARN: QA_APPROVAL_RETRY_RATE_FLOOR='$RATE_FLOOR' is not a non-negative integer — falling back to 1000. A bad value here would make the floor comparison an integer error and silently disable the guard."
    RATE_FLOOR=1000 ;;
esac

case "$MAX_CALLS" in
  ''|*[!0-9]*)
    log "WARN: QA_APPROVAL_RETRY_MAX_CALLS='$MAX_CALLS' is not a non-negative integer — falling back to 600. A bad value here would make the budget comparison an integer error and silently disable the guard."
    MAX_CALLS=600 ;;
esac

# QA_REVIEW_STATUS and QA_SLACK_DM are required even though they only run on the
# alert path: they ARE the alert path's backstop. Discovering one is missing at
# the moment an approved, green PR needs to be marked unsafe is exactly too late,
# so refuse the whole tick instead — this lane cannot honour its alert contract
# without them.
for f in "$QA_GH" "$QA_APPROVE" "$QA_AUTHOR_UID" "$QA_REPO_ALLOWLIST" "$QA_REVIEW_STATUS" "$QA_SLACK_DM"; do
  [ -x "$f" ] || die 2 "required helper missing or not executable: $f"
done
[ -r "$POLICY" ] || die 2 "cannot read policy $POLICY"

# ── Bot identity ─────────────────────────────────────────────────────────
# Read from the policy, never guessed. GitHub reports the same bot identity in
# several spellings, and a guessed set would make "is there already a bot
# approval?" answer "no" forever — which would re-approve on every single tick.
# Fail closed: an unreadable list refuses the whole tick rather than degrading
# to a default that cannot recognise its own prior approval.
bot_logins_json="$(jq -c '.identity.bot_logins' "$POLICY" 2>/dev/null | head -1 || true)"
if [ -z "$bot_logins_json" ] || [ "$bot_logins_json" = "null" ]; then
  die 2 "cannot read .identity.bot_logins from $POLICY — refusing to classify reviews this tick (a guessed bot-login set would re-approve every tick)."
fi
# Presence is not enough — the SHAPE has to be right, because every wrong type
# fails silently rather than loudly:
#   {}  or []  -> `$bots | index($l)` matches nothing, so every candidate is
#                 skipped, read_failures stays 0, and the unattended tick
#                 reports success forever while GO PRs sit at REVIEW_REQUIRED;
#   "adk47"    -> index() on a STRING is a SUBSTRING test, so the unrelated
#                 login "adk4" classifies as the bot — misidentification, not
#                 just a no-op;
#   [123]      -> index() never matches a login, same silence as {}.
# None of those raise, so this is the only place they can be caught.
if ! printf '%s' "$bot_logins_json" \
     | jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and length > 0)' >/dev/null 2>&1; then
  die 2 ".identity.bot_logins in $POLICY is not a non-empty array of non-empty strings (got: $bot_logins_json) — refusing the tick. A wrong type here does not fail loudly: it silently classifies nothing (or, for a string, matches by substring), which would strand every GO PR at REVIEW_REQUIRED with the timer still reporting success."
fi

# ── Verdict extraction ───────────────────────────────────────────────────
# THE SUBSTRING TRAP: "NO-GO" CONTAINS "GO". A `case $body in *GO*)` or a bare
# `grep -q GO` reads a NO-GO verdict as GO and approves a PR the reviewer
# blocked. This repo has been bitten by exactly that shape before (the
# `*"GO"*` matches `"NO-GO"` lesson), and ads-manager#132 is a live example of
# a PR that carried BOTH verdicts on different head shas.
#
# So: pull the token that directly follows "Verdict:" (tolerating markdown
# bold/heading decoration around it) and compare it for EXACT equality. The
# alternation lists NO-GO first and grep is leftmost-longest, so at a position
# where "NO-GO" begins it can never match the trailing "GO".
#
# Anything we cannot parse is NOT a GO. An unrecognised body shape must fall
# through to "no verdict" and be skipped, never be optimistically approved.
#
# Every verdict token in the body is collected, not just the first, and ANY
# NO-GO anywhere wins over any GO. A review body can legitimately restate an
# earlier verdict in its carry-forward section, and "first token wins" would
# then hinge on section ordering someone is free to change. Preferring NO-GO
# is the fail-closed direction: the worst case is that a genuinely-GO PR is
# left for a human, never that a blocked PR is approved.
#
# CANNOT REVIEW (added 2026-08-26) is the THIRD token, and it is not a code
# objection: it means the bot could not see the change at all — an
# infrastructural failure (the diff would not fetch, the file list was
# partial, the thread list was truncated). It used to be posted as a NO-GO,
# which is how web-credits-next#740 read as "the bot objects to this
# release" when the bot had in fact reviewed nothing. It is matched here for
# ONE reason: so a body carrying it can never fall through to a lucky "GO"
# from some other sentence, and so this lane's log says which of the two
# non-approving outcomes it saw. It ranks ABOVE NO-GO in the precedence
# below because it is the more severe statement — NO-GO means "I read it and
# it is wrong", CANNOT REVIEW means "I could not read it". Neither approves.
qar_verdict() {
  local body="$1" toks
  toks="$(printf '%s' "$body" \
    | grep -oiE 'verdict[[:space:]*_#:]*[[:space:]]*(CANNOT[[:space:]_-]+REVIEW|NO-GO|GO)([^A-Za-z-]|$)' \
    | grep -oiE '(CANNOT[[:space:]_-]+REVIEW|NO-GO|GO)' \
    | tr '[:lower:]' '[:upper:]' || true)"
  case "$toks" in
    *CANNOT*REVIEW*) echo "CANNOT-REVIEW" ;;
    *NO-GO*)         echo "NO-GO" ;;
    *GO*)            echo "GO" ;;
    *)               echo "none" ;;
  esac
}

# ── Publishing the wrapper's ⚠️ ALERTs ───────────────────────────────────
# Sensitive paths (workflows, gateway config, most `scripts/qa-*`) used to
# REFUSE the approval; since 2026-08-03 they ALERT and the approval proceeds.
# Only the authority surface still refuses with exit 11. So for everything else
# the alert line is the ONLY signal that something needing eyes was
# auto-approved — the team traded a hard gate for speed on the explicit
# understanding that the alert stays loud.
#
# The wrapper cannot publish its own alerts: it prints them and its CALLER
# relays them (skills-all/muso-github-code-review/SKILL.md, "Relay every ⚠️
# ALERT the wrapper prints"). Every caller until this script was an agent doing
# exactly that. A timer that captures the output into a variable and logs a
# generic "APPROVED" line is the one caller that silently breaks the trade — the
# PR ends up approved, green, and carrying no trace of the alert, which reads as
# reviewed. A green PR whose alert never published is worse than a red one.
#
# So this reimplements the skill's mandated path in bash: audit-log first (no
# log ⇒ no post), post ONE follow-up PR comment where the person merging will
# see it, and if that cannot be done, turn the PR's qa-review status RED so it
# stops looking safe. Alerts are relayed on refusals too — the wrapper replays
# them on every exit path, and a decline is not a reason to drop them.
# Digest helper: node-8 has sha256sum, local dev boxes have shasum. Both read
# stdin, so the callers stay identical.
_qar_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum
  else shasum -a 256
  fi
}

_qar_post_alert_comment() { # <repo> <pr> <json-file>
  "$QA_GH" --repo "$1" api "repos/$1/issues/$2/comments" --method POST --input "$3" >/dev/null 2>&1
}

# ── Head identity around the approval write ──────────────────────────────
# Everything above selects a candidate from a head sha READ AT THE TOP of this
# PR's turn: the verdict is pinned to it, the existing-approval check is pinned
# to it. The write is not — qa-pr-approve.sh takes <repo> <pr> <uid> and
# approves whatever GitHub currently calls the head. So a push landing in the
# gap between the read and the write means approving a commit no review covers.
#
# Guard 8 absorbs most of that by refusing while the new head's checks are
# pending, but not all of it: a force-push back onto an already-green sha
# arrives green, and "mostly refused" is not a property to rely on for an
# approval write.
#
# Guard 14 NARROWS the rest at the wrapper. It does not close it. This lane
# exports QA_PR_APPROVE_EXPECT_HEAD (plus _BASE, _BASE_OID and _QUIET_SINCE),
# and the wrapper refuses with exit 14 when GitHub's live head is not the sha
# this turn's verdict was pinned to. That check sits on the far side of every
# other guard, so it shrinks the exposed window from "this whole turn" down to
# the wrapper's own read-to-write span — but it is still check-then-act, and a
# push landing inside that last span is approved.
#
# It cannot be made atomic, and the obvious fix makes things worse. GitHub's
# reviews API accepts a commit_id but does NOT validate it against the live
# head: POSTing a review pinned to a stale sha returns 200 and records that sha
# verbatim (measured against this very PR on 2026-08-18 — head a92b7295, review
# pinned to 37a163cd, accepted and stored as 37a163cd). So pinning prevents
# nothing. Worse, it would BLIND the readback below, which detects the race
# precisely by comparing the sha the approval landed on against the reviewed
# head — pin the write and that comparison is true by construction, turning a
# race we currently catch into one we never see.
#
# So the caller-side belt is load-bearing, not redundant, and it has to be a
# POST-write readback: re-confirm the head immediately before the write, then
# read the recorded review to learn WHICH sha the approval actually landed on,
# and redden the PR when that is not the reviewed one. That is detection, not
# prevention — the approval cannot be retracted from here — which is the honest
# limit of this design and is why the red status plus the author DM exist.
#
# Guard 14 is also OPT-IN: a caller that exports nothing keeps the old
# behavior, which is what keeps the wrapper backward-compatible for the agent
# lane.

# qar_unresolved_threads_since <repo> <pr> <iso-timestamp> — how many unresolved
# review threads have had activity after <iso-timestamp>. Prints ERR when it
# cannot tell, which callers must treat as a refusal, never as zero.
#
# `>=`, not `>`: GitHub timestamps are second-granular, so an objection filed in
# the SAME second as the verdict would slip past a strict comparison.
#
# The bot-author exclusion is what makes `>=` safe. The GO review files its own
# finding threads at its own submitted_at — measured on this very PR, an
# unresolved adk47 thread at 22:40:57Z against a review submitted 22:40:57Z — so
# a bare `>=` would read the review's own thread as an objection to itself and
# strand the PR forever, which is the exact failure this timer exists to repair.
# Human objections are the signal; the reviewer's own threads are Guard 7's job.
#
# The filter asks whether ANY comment at/after the GO is non-bot, NOT whether
# the LAST one is: a human "do not merge" followed by a routine bot reply would
# otherwise be erased by the reply. If a thread has more comments than the
# window AND its oldest fetched comment is already at/after the GO, an older
# human comment could be hiding past the edge — that is ERR, not zero.
#
# `comments(last:N)`, NOT first:1. The question is "has anyone objected since
# the GO?", and a thread OPENED before the verdict can carry a "hold, this is
# broken" reply added after it. Reading the first comment measures when the
# thread started, which is not the question and silently misses that case.
# (Guard 7 uses first:1 correctly — it reads the 🔴/🟡 TAG, which lives on the
# opening comment. Different question, different comment.)
#
# Fails closed on a second page for the same reason the wrapper's Guard 7 does:
# a blocker living past the first 100 threads is invisible, and "invisible"
# must not read as "absent".
qar_unresolved_threads_since() { # <repo> <pr> <since>
  local repo="$1" pr="$2" since="$3" gql out
  gql='query($owner:String!,$repo:String!,$pr:Int!){
    repository(owner:$owner,name:$repo){ pullRequest(number:$pr){
      reviewThreads(first:100){
        pageInfo{ hasNextPage }
        nodes{ isResolved comments(last:100){
          pageInfo{ hasPreviousPage }
          nodes{ createdAt author{ login } } } }
      } } } }'
  # Starts from the ROOT and proves the path exists. GitHub can answer HTTP 200
  # with `pullRequest: null` plus an `errors` array (transient resource or
  # permission failure); a filter rooted at .reviewThreads lets that null flow
  # through as "no threads" and emit 0, so the caller would read "nobody
  # objected" from a response that established nothing.
  #
  # The timestamp is passed to LOCAL jq via --arg rather than interpolated into
  # a `gh --jq` filter: `gh api` has no --arg (that is a documented trap in this
  # repo), and interpolating a value into a jq program is how a crafted value
  # rewrites the program.
  out="$("$QA_GH" --repo "$repo" api graphql -f query="$gql" \
        -f owner="${repo%%/*}" -f repo="${repo#*/}" -F pr="$pr" 2>/dev/null \
        | jq -r --arg since "$since" --argjson bots "$bot_logins_json" \
            'if (.errors // [] | length) > 0
               or ((.data.repository.pullRequest.reviewThreads // null) | type) != "object"
             then "ERR"
             else .data.repository.pullRequest.reviewThreads
             | if .pageInfo.hasNextPage then "ERR"
               else ([.nodes[]? | select(.isResolved == false)]) as $t
                 | if any($t[]; (.comments.pageInfo.hasPreviousPage // false)
                                and ((.comments.nodes[0].createdAt // "") >= $since))
                   then "ERR"
                   else ([$t[] | select(any(.comments.nodes[]?;
                            ((.createdAt // "") >= $since)
                            and ((.author.login // "") as $l | ($bots | index($l)) == null)))]
                         | length | tostring)
                   end
               end
             end' 2>/dev/null || echo "ERR")"
  [ -n "$out" ] || out="ERR"
  printf '%s' "$out"
}

# qar_staleness <repo> <pr> <go-timestamp> — prints OK, ERR, or STALE:<reason>.
#
# Answers "does that GO verdict still describe this pull request?" from two
# angles the head sha cannot see: a base-ref mutation (retarget or force-push
# keeps the head and its green checks while changing the comparison) and a human
# objection raised since the verdict (Guard 7 only blocks 🔴/🟡-tagged threads).
#
# Runs on BOTH sides of the approval write. Before, to refuse; after, to detect —
# the reads cannot be atomic with the wrapper's write from out here, so the
# residual window is closed by noticing rather than by preventing, exactly as the
# landing-sha readback does.
qar_staleness() { # <repo> <pr> <go-timestamp>
  local repo="$1" pr="$2" go_at="$3" tl retargets threads
  tl="$("$QA_GH" --repo "$repo" api "repos/$repo/issues/$pr/timeline?per_page=100" --paginate 2>/dev/null || echo "__ERR__")"
  if [ "$tl" = "__ERR__" ] || ! printf '%s' "$tl" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf 'ERR'; return 0
  fi
  # `>=` for the same second-granularity reason as the thread check. No
  # exclusion is needed here: a base-ref event is never authored by the review.
  # startswith("base_ref_"), not an equality test on base_ref_changed. A base
  # FORCE-PUSH keeps the head sha and its green checks while changing what the
  # PR actually compares against, and GitHub reports it as the separate event
  # base_ref_force_pushed. Matching the family is fail-closed: any future
  # base-ref event counts as staleness until someone decides otherwise.
  retargets="$(printf '%s' "$tl" | jq -r --arg t "$go_at" \
    '[.[] | select((.event // "") | startswith("base_ref_")) | select((.created_at // "") >= $t)] | length' 2>/dev/null || echo "ERR")"
  [ "$retargets" = "ERR" ] && { printf 'ERR'; return 0; }
  [ "$retargets" != "0" ] && { printf 'STALE:its base ref changed (retarget or force-push) at or after the GO review'; return 0; }
  threads="$(qar_unresolved_threads_since "$repo" "$pr" "$go_at")"
  [ "$threads" = "ERR" ] && { printf 'ERR'; return 0; }
  [ "$threads" != "0" ] && { printf 'STALE:%s unresolved review thread(s) from a human at or after the GO review' "$threads"; return 0; }
  printf 'OK'
}

# qar_send_page <message> — page #clio_devops and RETURN DELIVERY STATUS.
#
# NOT slack_notify_critical: that wraps slack_notify, which is best-effort by
# documented contract (`slack_load_env ... || return 0`, `... || true`) and
# returns 0 even when the send failed. A cooldown that advances on an
# undelivered page is exactly the case lib/slack-notify.sh warns about in
# slack_notify_payload_file_status' own docstring — "the caller must NOT advance
# dedupe / idempotency state for an alert that was never actually delivered".
# Same shape as qa-review-reconcile.sh's page_confirmed.
qar_send_page() {
  local payload rc=0
  payload="$(mktemp)" || return 1
  jq -n --arg c "${SLACK_CHANNEL:-C0ADV2W76G4}" \
        --arg t "<@${SLACK_UID_NICK:-U0AL36NADEY}> <@${SLACK_UID_AARON:-U7RP6HKUZ}> $1" \
        '{channel: $c, text: $t}' > "$payload" 2>/dev/null || { rm -f "$payload"; return 1; }
  slack_notify_payload_file_status "$payload" || rc=$?
  rm -f "$payload"
  return "$rc"
}

# qar_approved_since <repo> <pr> <iso-timestamp> — the sha of the newest bot
# APPROVED review submitted at/after <iso-timestamp>; empty if none; ERR if the
# read failed, which callers must not read as "none".
#
# Exists to resolve the wrapper's ambiguous exit 7 by evidence: an approval
# recorded since the attempt began is one this tick caused.
qar_approved_since() { # <repo> <pr> <since>
  local rv out
  rv="$("$QA_GH" --repo "$1" api "repos/$1/pulls/$2/reviews" --paginate 2>/dev/null || echo "__ERR__")"
  if [ "$rv" = "__ERR__" ] || [ -z "$rv" ] || ! printf '%s' "$rv" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf 'ERR'; return 0
  fi
  out="$(printf '%s' "$rv" | jq -r --argjson bots "$bot_logins_json" --arg since "$3" \
    '[.[] | select(.state == "APPROVED") | select(.user.login as $l | $bots | index($l))
          | select((.submitted_at // "") >= $since)]
     | sort_by(.submitted_at) | last | .commit_id // ""' 2>/dev/null || echo "ERR")"
  [ -n "$out" ] || out=""
  printf '%s' "$out"
}

# qar_page_cooled <stamp-file> <label> <message> — page #clio_devops at most
# once per BLACKOUT_PAGE_COOLDOWN per stamp.
#
# Shared by both pagers on purpose. The sibling reconciler's watchdogs page
# undeduped and produced hours of 15-minute repeats during the 2026-08-17
# outage; on a 10-minute timer that would be worse. Each caller owns its own
# stamp so one signal cannot mask the other, and the stamp is written BEFORE
# the send (and at the moment it is decided, never at end-of-tick where a
# SIGTERM would lose it).
qar_page_cooled() {
  local stamp="$1" label="$2" msg="$3" now last
  log "$msg"
  now="$(date -u +%s)"
  last=0
  [ -r "$stamp" ] && last="$(cat "$stamp" 2>/dev/null || echo 0)"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  # A stamp dated in the FUTURE (clock skew, a hand-edited file, a restored
  # backup) makes now-last negative, which reads as "still inside the cooldown"
  # for as long as the skew lasts — silence during exactly the event the page
  # exists to report. Treat it as invalid rather than as a cooldown.
  if [ "$last" -gt "$now" ]; then
    log "WARN: $label stamp $stamp is dated in the future ($last > $now) — treating it as invalid and paging anyway."
    last=0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] WOULD PAGE: $label"
  elif [ "$(( now - last ))" -ge "$BLACKOUT_PAGE_COOLDOWN" ]; then
    # Stamp FIRST so a slow or crashing send cannot produce a page storm — but
    # roll it back if the send actually failed, or one transient Slack error
    # would buy an hour of silence while nothing is being repaired.
    mkdir -p "$(dirname "$stamp")" 2>/dev/null || true
    printf '%s' "$now" > "$stamp" 2>/dev/null || true
    if ! qar_send_page "$msg"; then
      rm -f "$stamp" 2>/dev/null || true
      log "WARN: could not page for $label — cooldown stamp cleared so the next tick retries."
    fi
  else
    log "$label page suppressed — last one was $(( now - last ))s ago (cooldown ${BLACKOUT_PAGE_COOLDOWN}s)."
  fi
}

# Prints the sha the newest bot APPROVED review is attached to; empty if it
# cannot be determined (which is never reported as a clean approval).
qar_approved_head() { # <repo> <pr>
  local rv
  rv="$("$QA_GH" --repo "$1" api "repos/$1/pulls/$2/reviews" --paginate 2>/dev/null || echo "")"
  [ -n "$rv" ] || return 0
  printf '%s' "$rv" | jq -r --argjson bots "$bot_logins_json" \
    '[.[] | select(.state == "APPROVED") | select(.user.login as $l | $bots | index($l))]
     | sort_by(.submitted_at) | last | .commit_id // ""' 2>/dev/null || true
}

# go_red exists to cancel ONE specific hazard: a PR that is approved and green
# while the alert that should have accompanied it never published, so it reads
# as reviewed. That hazard only exists when the approval actually LANDED. On a
# decline nothing was approved, so reddening the PR would instead leave a stale
# failure status the lane can never clear — once the approval does land, the
# has_approval check skips the PR forever and no later tick revisits the status.
# So: red on rc 0, loud log on a decline.
qar_alert_publish_failed() { # <repo> <pr> <head-sha> <uid> <rc> <why>
  if [ "$5" = "0" ]; then
    qar_go_red "$1" "$2" "$3" "$4" "$6" || unsafe_unflagged=$((unsafe_unflagged + 1))
    return 0
  fi
  log "ALERT-PUBLISH FAILURE on a DECLINE: $1#$2 — alerts not published. The approval did not land, so the qa-review status is deliberately left alone (a red set here could never be cleared)."
}

# The PR is already approved by the time this runs, so every failure path has to
# end somewhere explicit and visible. Retry once, then say it as loudly as a
# script can: a go_red that fails quietly is the worst case in this flow.
qar_go_red() { # <repo> <pr> <head-sha> <uid> <why>
  local repo="$1" pr="$2" sha="$3" uid="$4" why="$5"
  local url="https://github.com/$repo/pull/$pr/files"
  "$QA_REVIEW_STATUS" "$repo" "$sha" failure "$why" "$url" >/dev/null 2>&1 && return 0
  sleep 3
  "$QA_REVIEW_STATUS" "$repo" "$sha" failure "$why" "$url" >/dev/null 2>&1 && return 0
  log "CRITICAL: could not publish qa-review=failure for $repo#$pr — the PR is APPROVED and GREEN with an unpublished ⚠️ ALERT. It MUST NOT be merged until a human sets the status manually."
  # The DM is the last channel, and qa-slack-dm.sh DOES report status (0 ok,
  # 1 slack/api failure), so its answer is meaningful: a delivered DM means a
  # human was actually warned, which is a worse-but-handled outcome. Only when
  # this fails too is the PR approved, green, and warned about NOWHERE — that is
  # what the caller escalates on, so return 0 here if the DM landed.
  if "$QA_SLACK_DM" "$uid" \
      "⛔ <https://github.com/$repo/pull/$pr|$repo#$pr> — auto-approved by the QA approval retry, but its ⚠️ ALERT could not be published AND the red QA status could not be set. DO NOT MERGE until a human checks it." \
      >/dev/null 2>&1; then
    log "WARN: $repo#$pr could not be reddened, but the author WAS DM'd — a human has been warned."
    return 0
  fi
  return 1
}

# Returns 0 when there was nothing to publish or the publish succeeded, 1 when
# alerts existed and could not be published (caller counts it).
qar_publish_alerts() { # <repo> <pr> <head-sha> <uid> <rc> <wrapper-output>
  local repo="$1" pr="$2" sha="$3" uid="$4" rc="$5" out="$6"
  local alerts heading md json day outcome marker existing digest

  # The wrapper prints each alert TWICE on purpose — inline on stderr for
  # ordering context, then again in the authoritative replay block on stdout —
  # and this capture merges both streams. Identical lines, so dedupe by exact
  # match while preserving order; never collapse two DIFFERENT alerts.
  alerts="$(printf '%s\n' "$out" | grep -F '⚠️ ALERT — ' | awk '!seen[$0]++' || true)"
  [ -n "$alerts" ] || return 0

  # The heading must follow the OUTCOME: the wrapper replays alerts on refusals
  # too, and "Auto-approved" on a decline would be a straight lie.
  if [ "$rc" = "0" ]; then
    outcome="approved"; heading="## ⚠️ Auto-approved with alerts"
  else
    outcome="declined"; heading="## ⚠️ Alerts (NOT approved — qa-pr-approve exit $rc)"
  fi

  # ── Idempotency, without a state file ──────────────────────────────────
  # This sweep is stateless and re-considers every unapproved PR each tick, so a
  # PR that keeps declining would otherwise get a fresh alert comment and a
  # fresh DM every 10 minutes — forever for a permanently-declining one (an
  # out-of-scope approver exits 5 on every tick by design, see the header). That
  # is precisely how a signal gets tuned out, and the alert is the only backstop
  # the sensitive-path gate has left.
  #
  # GitHub is the state, exactly as it is for "already approved?": stamp an
  # invisible marker into the body and skip if it is already on the PR. Keyed by
  # head sha, outcome AND a digest of the alert set:
  #   - outcome, so a decline's alerts and a later approval's alerts each
  #     publish once — suppressing the approval comment because a "NOT approved"
  #     one already exists would leave the PR's only alert comment
  #     contradicting its actual state;
  #   - digest, so an alert set that GROWS on a later tick (an advisory check
  #     turns red and the wrapper adds a line) is published instead of being
  #     swallowed by the marker for the older, smaller set.
  #
  # The digest does NOT reopen the repost loop it was added to close: a marker
  # is per distinct alert set, so a stable set posts exactly once and a set that
  # flips between two shapes posts twice, total — bounded either way. Only an
  # alert whose TEXT changed every tick could be unbounded, and none carry a
  # timestamp or a per-run counter.
  #
  # A read failure here deliberately falls through to POSTING: a duplicate
  # comment is noise, an unpublished alert is the failure this whole path exists
  # to prevent.
  digest="$(printf '%s' "$alerts" | _qar_sha256 | cut -c1-16)"
  marker="<!-- qa-approval-retry:alerts:$sha:$outcome:$digest -->"
  existing="$("$QA_GH" --repo "$repo" api "repos/$repo/issues/$pr/comments" --paginate 2>/dev/null || echo "__ERR__")"
  if [ "$existing" != "__ERR__" ] \
     && printf '%s' "$existing" | jq -e --arg m "$marker" 'any(.[]; (.body // "") | contains($m))' >/dev/null 2>&1; then
    log "ALERTS ALREADY PUBLISHED: $repo#$pr (head ${sha:0:7}, $outcome) — not reposting."
    return 0
  fi

  # Audit FIRST. No log ⇒ no post — and do NOT just return, because that leaves
  # an approved, green PR with the alert unpublished and nothing saying so.
  day="$(date -u +%F)"
  if ! mkdir -p "$ALERT_LOG_DIR" 2>/dev/null \
     || ! printf '{"agent":"qa-approval-retry","action":"github_pr_alert_comment","target":"%s#%s","requester":"%s","timestamp":"%s","authorization":"qa-approval-retry-timer"}\n' \
          "$repo" "$pr" "$uid" "$(date -u +%FT%TZ)" >> "$ALERT_LOG_DIR/$day.jsonl" 2>/dev/null; then
    log "ALERT-PUBLISH FAILURE: could not audit-log the alert comment for $repo#$pr — not posting it."
    qar_alert_publish_failed "$repo" "$pr" "$sha" "$uid" "$rc" \
      "alert comment could not be audit-logged, so it was not posted — NOT safe to merge"
    return 1
  fi

  md="$(mktemp)"; json="$(mktemp)"
  {
    printf '%s\n\n' "$heading"
    printf '%s\n' "$alerts"
    printf '\nPosted by the qa-approval-retry timer, which re-asks for approvals withheld while CI was still running. A human still performs the merge.\n'
    printf '\n%s\n' "$marker"
  } > "$md"
  # `--input` sends the file as the WHOLE request body, so it must already BE
  # {"body": "..."} — raw markdown posts invalid JSON, and any -f/-F alongside
  # --input lands in the query string instead of the payload. `jq -Rs` slurps
  # stdin into one JSON-escaped string so backticks and quotes survive verbatim.
  if ! jq -Rs '{body: .}' < "$md" > "$json" 2>/dev/null; then
    rm -f "$md" "$json"
    log "ALERT-PUBLISH FAILURE: could not encode the alert comment for $repo#$pr."
    qar_alert_publish_failed "$repo" "$pr" "$sha" "$uid" "$rc" \
      "auto-approved with ALERTS that could not be published — NOT safe to merge"
    return 1
  fi

  local published=0
  if _qar_post_alert_comment "$repo" "$pr" "$json"; then
    published=1
  else
    sleep 3
    _qar_post_alert_comment "$repo" "$pr" "$json" && published=1
  fi
  rm -f "$md" "$json"

  if [ "$published" != "1" ]; then
    log "ALERT-PUBLISH FAILURE: could not post the alert comment on $repo#$pr."
    qar_alert_publish_failed "$repo" "$pr" "$sha" "$uid" "$rc" \
      "auto-approved with ALERTS that could not be published — NOT safe to merge"
    return 1
  fi

  # Second channel: the author. Best-effort by design — a Slack hiccup must
  # never sink the tick, and the PR comment above already reached the merger.
  "$QA_SLACK_DM" "$uid" \
    "⚠️ <https://github.com/$repo/pull/$pr|$repo#$pr> — the QA approval retry ran and the wrapper raised alerts. They are posted on the PR; read them before merging." \
    >/dev/null 2>&1 || true

  log "ALERTS PUBLISHED: $repo#$pr — $(printf '%s\n' "$alerts" | wc -l | tr -d ' ') alert line(s) posted as a PR comment."
  return 0
}

# ── Quota bounds ─────────────────────────────────────────────────────────
# qar_rate_core <repo> — prints "<remaining> <reset-epoch>" or ERR.
#
# `gh api rate_limit` does NOT consume quota (verified 9 Oct: the response
# itself reported used:0), so probing before EVERY repo is free. Do not drop
# the per-repo probe to "save a call" — the bucket is shared with other
# scripts and can empty mid-tick.
#
# This guard FAILS OPEN, deliberately the inverse of the fail-closed reads
# elsewhere in this file (CTO ruling R4, MUS-6075). Those reads gate a WRITE,
# where doubt must mean "do nothing". This one gates a SPEND: the real daily
# work of this lane is a handful of PRs, and silencing the repair lane because
# a free probe hiccuped costs far more than the reads it would have saved. An
# unreadable answer therefore logs a WARN and the tick proceeds. Do not
# "fix" this to fail closed.
qar_rate_core() { # <repo>
  local core remaining reset
  core="$("$QA_GH" --repo "$1" api rate_limit --jq '.resources.core' 2>/dev/null)" || { printf 'ERR'; return 0; }
  remaining="$(printf '%s' "$core" | jq -r '.remaining' 2>/dev/null)" || { printf 'ERR'; return 0; }
  reset="$(printf '%s' "$core" | jq -r '.reset' 2>/dev/null)" || { printf 'ERR'; return 0; }
  case "$remaining" in ''|*[!0-9]*) printf 'ERR'; return 0 ;; esac
  case "$reset" in ''|*[!0-9]*) printf 'ERR'; return 0 ;; esac
  printf '%s %s' "$remaining" "$reset"
}

# REST calls issued by THIS script, counted at the call site (a count kept
# inside a $(...) helper would be lost with its subshell). The reviews read is
# charged per page; the other `--paginate` reads count as ONE call however many
# pages they fetch, and the post-approval readbacks are not counted, so this is a FLOOR on real spend, not exact
# accounting. It is checked once per candidate, so a PR in flight may overshoot
# by its handful of calls. Sized (600) to bite on a pathological repo, not on
# normal volume.
rest_calls=0
qar_spend() { rest_calls=$(( rest_calls + $1 )); }

# If invoked as a library (tests source this file), stop here — everything above
# only DEFINES things, so sourcing stays side-effect free; everything below
# performs live API calls.
[ "${QA_APPROVAL_RETRY_LIB:-0}" = "1" ] && return 0

# ── Repo set ─────────────────────────────────────────────────────────────
# NOT `mapfile`/`readarray`: those are bash 4+ builtins and these scripts also
# run under macOS /usr/bin/bash 3.2 locally (the same constraint that shaped
# qa-pr-approve.sh's `${ARR[@]+...}` expansions). On 3.2 `mapfile` is a
# "command not found", which under `set -e` aborts the tick with no message.
REPOS=()
while IFS= read -r _r; do
  [ -n "$_r" ] && REPOS+=("$_r")
done < <(QA_EXTERNAL_REPO_ALLOWLIST_ENUMERATE=1 "$QA_REPO_ALLOWLIST")
[ "${#REPOS[@]}" -gt 0 ] || die 2 "external repo allowlist enumerated empty — refusing."

# Acting identity, resolved once per tick. Self-approval is permanently refused
# by GitHub (qa-pr-approve.sh exit 4), so a PR authored by this identity is
# skipped before any read is spent on it. Mirrors qa-pr-approve.sh:262-263,
# including the `|| true`: an App token 403s on `gh api user`, so fall back to
# the policy's first bot login.
# mirrors qa-pr-approve.sh:273 — do not diverge
norm_login() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's,^app/,,' -e 's,\[bot\]$,,'; }
me="$("$QA_GH" --repo "${REPOS[0]}" api user --jq .login 2>/dev/null || true)"
[ -n "$me" ] || me="$(printf '%s' "$bot_logins_json" | jq -r '.[0] // "muso-qa-bot"' 2>/dev/null || echo "muso-qa-bot")"
me_norm="$(norm_login "$me")"

log "tick start — ${#REPOS[@]} repo(s) in scope${DRY_RUN:+, dry_run=$DRY_RUN}"
considered=0; approved=0; declined=0; skipped=0; read_fail=0; alerts_unpublished=0; raced=0; repo_fail=0; reviews_fail=0; truncated=0; safety_considered=0; safety_fail=0; unsafe_unflagged=0; self_authored=0; declined_permanent=0

budget_hit=0; floor_hit=0; floor_at=""; floor_rem=""; rate_warned=0; repo_idx=0; budget_at=""
for repo in "${REPOS[@]}"; do
  # Floor probe, before every repo (this also covers tick start: repo 1). Free
  # call, see qar_rate_core. Below the floor the whole tick stops — `continue`
  # would just spend the same shared bucket on the next repo.
  rate="$(qar_rate_core "$repo")"
  if [ "$rate" = "ERR" ]; then
    if [ "$rate_warned" -eq 0 ]; then
      log "WARN: could not read rate_limit — proceeding WITHOUT the quota floor (fail-open by design: a dead probe must not silence the repair lane)."
      rate_warned=1
    fi
  else
    rate_remaining="${rate%% *}"; rate_reset="${rate##* }"
    if [ "$rate_remaining" -lt "$RATE_FLOOR" ]; then
      log "RATE FLOOR: core remaining=$rate_remaining is below floor=$RATE_FLOOR (resets $(jq -rn --argjson t "$rate_reset" '$t | todate')) — standing down; $(( ${#REPOS[@]} - repo_idx )) of ${#REPOS[@]} repo(s) not swept. Expected steady state, not a failure."
      break
    fi
  fi
  repo_idx=$((repo_idx + 1))
  prs_json="$("$QA_GH" --repo "$repo" pr list --repo "$repo" --state open \
                --json number,headRefOid,author,isDraft --limit "$PRLIST_LIMIT" 2>/dev/null || echo "__ERR__")"
  if [ "$prs_json" = "__ERR__" ] || [ -z "$prs_json" ]; then
    log "READ-FAILURE: could not list open PRs for $repo — skipped, NOT treated as 'nothing to do'."
    read_fail=$((read_fail + 1)); repo_fail=$((repo_fail + 1)); continue
  fi
  # Shape-check BEFORE the loop. The candidate loop is fed by a process
  # substitution, and a process substitution's exit status is invisible to the
  # parent — neither `set -e` nor `pipefail` sees it. So a shim that returns a
  # truncated or non-array body with exit 0 makes jq fail, the loop run zero
  # times, and the tick report "nothing to do" with read_failures=0. A silent
  # empty sweep is exactly the shape this script exists to avoid, so validate
  # here where the failure is still visible.
  if ! printf '%s' "$prs_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    log "READ-FAILURE: the open-PR list for $repo was not a JSON array — counted as a read failure, never as 'no open PRs'."
    read_fail=$((read_fail + 1)); repo_fail=$((repo_fail + 1)); continue
  fi

  # ── Truncation guard ────────────────────────────────────────────────────
  # `gh pr list --limit N` silently returns the first N. A repo with more open
  # PRs than the cap drops the overflow from this sweep entirely, so a PR with a
  # live-head GO and a withheld approval — exactly what this timer exists to
  # repair — would sit at REVIEW_REQUIRED forever while every tick reported
  # success. A count landing exactly on the cap is the only truncation signal
  # `gh pr list` gives, so treat it as truncated rather than as "there happen to
  # be exactly this many". Same guard, and the same reasoning, as
  # qa-review-reconcile.sh's.
  pr_count="$(printf '%s' "$prs_json" | jq -r 'length' 2>/dev/null || echo 0)"
  if [ "$pr_count" -ge "$PRLIST_LIMIT" ]; then
    truncated=$((truncated + 1))
    qar_page_cooled "$TRUNCATION_STAMP" "truncation" \
      "qa-approval-retry: TRUNCATED PR LIST — $repo returned exactly $PRLIST_LIMIT open PRs (the --limit cap), so the overflow is invisible to this sweep. Any withheld approval on those PRs is NOT being repaired. Raise QA_APPROVAL_RETRY_PRLIST_LIMIT."
  fi

  repo_self=0
  while IFS=$'\t' read -r pr head_sha author is_draft; do
    [ -n "${pr:-}" ] || continue
    [ "$is_draft" = "true" ] && continue
    # Before the reviews read: this PR can never be approved by us, and every
    # call below it (reviews, timeline, threads, head re-read) is wasted quota.
    if [ "$(norm_login "$author")" = "$me_norm" ]; then
      self_authored=$((self_authored + 1)); repo_self=$((repo_self + 1)); continue
    fi
    # Per-tick REST budget, checked per candidate before it spends anything.
    if [ "$rest_calls" -ge "$MAX_CALLS" ]; then
      budget_hit=1; budget_at="$repo#$pr"; break
    fi
    # The budget above counts calls, not pages, so it can sit under its ceiling
    # while the shared bucket empties (hydra#1119 review). The ceiling that
    # holds is the REAL remaining quota, re-read before every candidate: free
    # call, same fail-open as the per-repo probe (an unreadable answer proceeds).
    rate="$(qar_rate_core "$repo")"
    if [ "$rate" = "ERR" ]; then
      # Fail open exactly as the per-repo probe does — and as LOUDLY. Falling
      # through silently spends the rest of the repo with no floor in force and
      # leaves nothing in the tick log to say the guard was off, which is the
      # invisible drain this script exists to remove (hydra#1119 review).
      # Shares rate_warned with the per-repo probe on purpose: one WARN per
      # tick, not one per candidate.
      if [ "$rate_warned" -eq 0 ]; then
        log "WARN: could not read rate_limit — proceeding WITHOUT the quota floor (fail-open by design: a dead probe must not silence the repair lane)."
        rate_warned=1
      fi
    elif [ "${rate%% *}" -lt "$RATE_FLOOR" ]; then
      floor_hit=1; floor_at="$repo#$pr"; floor_rem="${rate%% *}"; break
    fi
    considered=$((considered + 1))

    # Reviews: paging is load-bearing. GitHub returns reviews OLDEST-first, so on
    # a long history the current head's verdict is on a late page and a one-page
    # read sees only stale ones. Paged by hand rather than with --paginate so
    # every HTTP request is charged to rest_calls and the spend is bounded:
    # --paginate is one call to the counter however many pages it fetches
    # (hydra#1119 review). Past MAX_REVIEW_PAGES the history is unreadable, which
    # is a read failure, never "no verdict".
    reviews="[]"; page=1
    while :; do
      qar_spend 1
      # Hand-paged on purpose so every request is charged to rest_calls
      # (--paginate counts once however many pages it fetches, hydra#1119).
      # The loop is complete or loud: it stops only on a short page, and a
      # page-cap or read failure sets __ERR__, never a silent "no verdict".
      pg="$("$QA_GH" --repo "$repo" api "repos/$repo/pulls/$pr/reviews?per_page=100&page=$page" 2>/dev/null)" || { reviews="__ERR__"; break; }  # paginated-ok: complete-or-loud hand-paged loop (rest_calls accounting, hydra#1119)
      # The same shape-check the PR list gets: a truncated or non-array body
      # arrives with exit 0, so only this catches it (and must count as a failure).
      if ! printf '%s' "$pg" | jq -e 'type == "array"' >/dev/null 2>&1; then
        log "READ-FAILURE: the reviews body for $repo#$pr was not a JSON array — counted, never treated as 'no verdict'."
        reviews="__ERR__"; break
      fi
      # Combined on stdin, never argv: a page can exceed the 128 KiB per-argument
      # cap on Linux, and under set -e the exec failure would kill the whole tick.
      reviews="$(printf '%s\n%s' "$reviews" "$pg" | jq -cs 'add')"
      [ "$(printf '%s' "$pg" | jq 'length')" -lt 100 ] && break
      page=$((page + 1))
      if [ "$page" -gt "$MAX_REVIEW_PAGES" ]; then
        log "READ-FAILURE: $repo#$pr has more than $((MAX_REVIEW_PAGES * 100)) reviews (page cap $MAX_REVIEW_PAGES) — not read, skipped."
        reviews="__ERR__"; break
      fi
    done
    if [ "$reviews" = "__ERR__" ] || [ -z "$reviews" ]; then
      log "READ-FAILURE: could not read reviews for $repo#$pr — skipped."
      read_fail=$((read_fail + 1)); reviews_fail=$((reviews_fail + 1)); continue
    fi
    # Already approved by the bot on THIS head? Then there is nothing to repair.
    # Scoped to the live head sha: dismiss_stale_reviews drops an approval when a
    # new commit lands, so an approval on an older sha is not a current approval.
    has_approval="$(printf '%s' "$reviews" | jq -r --argjson bots "$bot_logins_json" --arg sha "$head_sha" \
      '[.[] | select(.state == "APPROVED") | select(.user.login as $l | $bots | index($l)) | select(.commit_id == $sha)] | length' 2>/dev/null || echo "ERR")"
    if [ "$has_approval" = "ERR" ]; then
      # Shape is already checked above, so reaching here means the classification
      # itself failed — still a failure to read this candidate's reviews, and it
      # must count as one or a fleet-wide version of it would not page.
      log "READ-FAILURE: could not evaluate existing approvals for $repo#$pr — skipped."
      read_fail=$((read_fail + 1)); reviews_fail=$((reviews_fail + 1)); continue
    fi
    if [ "$has_approval" != "0" ]; then skipped=$((skipped + 1)); continue; fi

    # Latest bot review body ON THE LIVE HEAD SHA. Pinning to the head is what
    # keeps a superseded NO-GO (or a superseded GO) from deciding anything:
    # ads-manager#132 carried NO-GO on d2222eb and GO on 8495457.
    go_review="$(printf '%s' "$reviews" | jq -c --argjson bots "$bot_logins_json" --arg sha "$head_sha" \
      '[.[] | select(.user.login as $l | $bots | index($l)) | select(.commit_id == $sha) | select((.body // "") != "")]
       | sort_by(.submitted_at) | last // {}' 2>/dev/null || echo "{}")"
    body="$(printf '%s' "$go_review" | jq -r '.body // ""' 2>/dev/null || echo "")"
    [ -n "$body" ] || { skipped=$((skipped + 1)); continue; }

    verdict="$(qar_verdict "$body")"
    if [ "$verdict" != "GO" ]; then
      # NO-GO is the reviewer doing its job; "none" is an unparseable body.
      # Neither is a candidate, and neither is an error.
      #
      # CANNOT-REVIEW is neither of those and is worth a line: the bot could
      # not SEE the change (diff unfetchable, partial file list, truncated
      # threads). Retrying cannot help — nothing about this lane re-fetches
      # a diff — so it is skipped like the rest, but silently skipping it
      # would leave a PR sitting unreviewed with nothing in the log saying
      # a human has to look. Logged, never retried, never approved.
      if [ "$verdict" = "CANNOT-REVIEW" ]; then
        log "SKIP: $repo#$pr — the review verdict is CANNOT REVIEW (the bot could not see the change; this is a tool failure, not a code objection). A human must review it; this lane cannot repair it."
      fi
      skipped=$((skipped + 1)); continue
    fi

    # ── Is that GO still about THIS pull request? ─────────────────────────
    # The head sha pins the DIFF's right-hand side and nothing else. Two changes
    # keep the sha (and the green checks) while making the verdict stale:
    #
    #   * a base retarget — a PR reviewed against `develop` and retargeted to
    #     `main` is a different diff entirely, and unscoped requesters are not
    #     base-restricted in the wrapper;
    #   * a review thread opened AFTER the GO — the wrapper's Guard 7 only
    #     counts threads tagged 🔴/🟡 (qa-pr-approve.sh:598), so a plain human
    #     "hold on, this is wrong" never blocks it.
    #
    # Neither matters in the dispatch lane, where the approval follows the
    # review by seconds. This lane exists to approve LATER, which is exactly
    # what opens the window — so it has to close it itself. Both checks are
    # anchored to the GO's own timestamp and fail closed on an unreadable answer.
    # From here on the candidate is a real GO awaiting the staleness/safety
    # reads. Count it, so that "every one of them failed" is detectable — the
    # same shape as the reviews-endpoint blackout, applied to the reads added
    # for the staleness checks.
    safety_considered=$((safety_considered + 1))
    go_at="$(printf '%s' "$go_review" | jq -r '.submitted_at // ""' 2>/dev/null || echo "")"
    if [ -z "$go_at" ]; then
      log "SKIP: $repo#$pr — the GO review has no submitted_at, so 'did anything change since it?' cannot be answered. Not approving."
      skipped=$((skipped + 1)); continue
    fi

    qar_spend 1
    stale="$(qar_staleness "$repo" "$pr" "$go_at")"
    case "$stale" in
      ERR)
        log "READ-FAILURE: could not establish whether $repo#$pr changed since its GO review — skipped rather than approving on an unverified verdict."
        read_fail=$((read_fail + 1)); safety_fail=$((safety_fail + 1)); continue ;;
      STALE:*)
        log "SKIP: $repo#$pr — ${stale#STALE:}. The GO verdict no longer describes this pull request; a fresh review must supply the verdict."
        skipped=$((skipped + 1)); continue ;;
    esac

    # Author -> Slack UID. Unmapped authors fail closed (exit 1) and are skipped,
    # matching the dispatch lane: an unknown author gets reviewed, never approved.
    uid="$("$QA_AUTHOR_UID" "$author" 2>/dev/null || true)"
    if [ -z "$uid" ]; then
      log "SKIP: $repo#$pr — author '$author' is not mapped to a Slack UID (review-only, fail-closed)."
      skipped=$((skipped + 1)); continue
    fi

    if [ "$DRY_RUN" = "1" ]; then
      log "DRY-RUN: would ask approval for $repo#$pr (head ${head_sha:0:7}, author $author, uid $uid, verdict GO)"
      continue
    fi

    # Re-confirm the head immediately before the write. This does not make the
    # write atomic — nothing caller-side can — but it collapses the window from
    # "the whole turn" (reviews read, verdict parse, UID lookup) to one API
    # call, and it is fail-closed: a head we cannot name is never approved.
    # ONE read, three facts: the head we are about to approve, and the base the
    # verdict was formed against (name + tip). All three are handed to the
    # wrapper below so it can re-verify them under the same read that performs
    # the write — the window this side genuinely cannot close.
    qar_spend 1
    pr_state="$("$QA_GH" --repo "$repo" api "repos/$repo/pulls/$pr" \
      --jq '[(.head.sha // ""), (.base.ref // ""), (.base.sha // "")] | @tsv' 2>/dev/null || echo "")"
    live_head="$(printf '%s' "$pr_state" | cut -f1)"
    live_base_ref="$(printf '%s' "$pr_state" | cut -f2)"
    live_base_sha="$(printf '%s' "$pr_state" | cut -f3)"
    # ALL THREE or nothing. Approving with only some expectations handed over
    # would silently disable the rest of the wrapper's Guard 14 — a retarget or
    # base rewrite would sail through while the log still read like a normal
    # approval. Unverifiable means refuse, exactly as everywhere else here.
    if [ -z "$live_head" ] || [ -z "$live_base_ref" ] || [ -z "$live_base_sha" ]; then
      log "READ-FAILURE: could not read head+base for $repo#$pr immediately before approving (head='${live_head:-?}' base='${live_base_ref:-?}'@'${live_base_sha:-?}') — skipped rather than approving with part of the wrapper contract silently disabled."
      read_fail=$((read_fail + 1)); safety_fail=$((safety_fail + 1)); continue
    fi
    if [ "$live_head" != "$head_sha" ]; then
      log "SKIP: $repo#$pr moved ${head_sha:0:7} -> ${live_head:0:7} after its verdict was read — not approving a commit no review covers. The next tick re-evaluates the new head."
      skipped=$((skipped + 1)); continue
    fi

    # Ask. Every guard re-runs inside the wrapper; a refusal is a NORMAL outcome.
    # `|| rc=$?` keeps a decline from aborting the tick under `set -e`.
    # Stamped BEFORE the write so the wrapper's ambiguous exit 7 can be resolved
    # by evidence rather than by guessing from the exit code.
    attempt_at="$(date -u +%FT%TZ)"
    rc=0
    # Hand the wrapper what this tick believes, so IT can re-check under the same
    # read that writes. Without these the wrapper's Guard 14 is inert and the
    # gap between the checks above and the approval is only ever noticed after
    # the fact, by the readback — which cannot retract an approval.
    # Unconditional: the read above already refused if any of them was missing,
    # so there is no partial hand-off to reason about. An earlier version omitted
    # empty values, which FAILED OPEN — it silently disabled the base half of
    # Guard 14 while still approving.
    # Exported inside a SUBSHELL, not as an env-assignment prefix. A prefix built
    # by expansion (`${x:+VAR=val}`) is NOT treated as an assignment by bash — it
    # becomes a positional ARGUMENT to the command, which silently corrupts the
    # wrapper's argv. The subshell also keeps these out of the rest of the tick.
    qar_spend 2   # the wrapper spends `gh api user` + `gh pr view`
    out="$(
      export QA_PR_APPROVE_EXPECT_HEAD="$head_sha"
      export QA_PR_APPROVE_EXPECT_QUIET_SINCE="$go_at"
      export QA_PR_APPROVE_EXPECT_BASE="$live_base_ref"
      export QA_PR_APPROVE_EXPECT_BASE_OID="$live_base_sha"
      "$QA_APPROVE" "$repo" "$pr" "$uid" \
        "🤖 Approved by Muso QA Bot (automated review): CI is green and there are no blocking findings. A human still performs the merge." 2>&1
    )" || rc=$?

    # exit 7 covers two very different things: a pre-write read failure (it never
    # got as far as approving) and `gh pr review --approve` returning non-zero,
    # which can happen AFTER GitHub recorded the approval
    # (qa-pr-approve.sh:880 — the audit log at :876 is already written by then).
    # Treating it as a plain decline would skip every backstop on an approval
    # that really exists, and the next tick would skip the PR entirely because
    # an approval is present. Decide it on evidence: the loop already
    # established there was no approval on this head before the write, so a bot
    # approval recorded since this attempt began is ours.
    if [ "$rc" = "7" ]; then
      landed7="$(qar_approved_since "$repo" "$pr" "$attempt_at")"
      case "$landed7" in
        ERR)
          log "CRITICAL: $repo#$pr returned the ambiguous exit 7 and the approval state could not be read back — an approval may exist and is unverified. Marking it unsafe; a human must check it."
          qar_go_red "$repo" "$pr" "$head_sha" "$uid" \
            "approval state unverifiable after an ambiguous wrapper failure — NOT safe to merge until a human confirms" \
            || unsafe_unflagged=$((unsafe_unflagged + 1))
          raced=$((raced + 1))
          rc=handled ;;
        "")
          # Nothing was recorded, so this was the pre-write half of exit 7: the
          # wrapper never approved. A genuine decline — say which half it was,
          # because "exit 7" alone does not tell an operator that.
          log "DECLINED (exit 7, no approval recorded): $repo#$pr — $(printf '%s' "$out" | tail -1)"
          declined=$((declined + 1))
          rc=handled ;;
        *)
          log "WARN: $repo#$pr — the wrapper exited 7 but GitHub DID record the approval (${landed7:0:7}); running the post-write backstops as if it had succeeded."
          rc=0 ;;
      esac
    fi

    if [ "$rc" = "handled" ]; then :
    elif [ "$rc" = "0" ]; then
      # WHICH sha did the approval actually land on? Read it back from the
      # recorded review rather than assuming. An approval on anything other than
      # the reviewed head is an unreviewed commit carrying the bot's approval —
      # it cannot be undone from here, so make it loudly unsafe instead.
      landed="$(qar_approved_head "$repo" "$pr")"
      if [ "$landed" = "$head_sha" ]; then
        # The pre-write staleness read cannot be atomic with the wrapper's
        # write, so re-ask now: a retarget or objection that landed inside that
        # window has already been approved and can only be surfaced, not undone.
        qar_spend 1
        post_stale="$(qar_staleness "$repo" "$pr" "$go_at")"
        if [ "$post_stale" = "OK" ]; then
          log "APPROVED: $repo#$pr (head ${head_sha:0:7}, author $author) — verdict GO, CI green."
          approved=$((approved + 1))
        else
          log "CRITICAL: approved $repo#$pr, but the PR changed during the approval write (${post_stale#STALE:}${post_stale/STALE:*/}) — the approval covers context the GO verdict did not. Marking it unsafe; a human must check it."
          qar_go_red "$repo" "$pr" "$head_sha" "$uid" \
            "approved, then found to have changed during the write — NOT safe to merge until a human confirms" \
            || unsafe_unflagged=$((unsafe_unflagged + 1))
          raced=$((raced + 1))
        fi
      else
        # The status MUST target the commit that may be carrying the approval.
        # Defaulting to the reviewed head would redden a commit that is not the
        # one at risk, while the head that actually holds the approval keeps its
        # green status — a backstop that reports success without doing anything.
        target="$landed"
        if [ -z "$target" ]; then
          target="$("$QA_GH" --repo "$repo" api "repos/$repo/pulls/$pr" --jq '.head.sha' 2>/dev/null || echo "")"
        fi
        if [ -z "$target" ]; then
          # Neither the readback nor the head re-read could name the commit.
          # Do NOT redden the reviewed head and call the PR handled — say
          # plainly that nothing was marked and escalate to a human.
          log "CRITICAL: approved $repo#$pr but could NOT establish which commit carries the approval (reviews readback and head re-read both failed). NO status was set — the PR may be approved and green on an unreviewed commit. A human must check it now."
          "$QA_SLACK_DM" "$uid" \
            "⛔ <https://github.com/$repo/pull/$pr|$repo#$pr> — auto-approved by the QA approval retry, but which commit carries the approval could not be established and NO red status was set. DO NOT MERGE until a human checks it." \
            >/dev/null 2>&1 || true
        else
          log "CRITICAL: approved $repo#$pr but the approval is on '${landed:-unknown}' (status targeting ${target:0:7}), not the reviewed head ${head_sha:0:7} — an unreviewed commit now carries the bot's approval. Marking it unsafe; a human must check it."
          qar_go_red "$repo" "$pr" "$target" "$uid" \
            "approved on a head the QA review does not cover — NOT safe to merge until a human confirms" \
            || unsafe_unflagged=$((unsafe_unflagged + 1))
        fi
        raced=$((raced + 1))
      fi
    else
      # exit 8 while CI is still running is the EXPECTED steady state between
      # the review landing and CI going green — that is the whole race this
      # script exists to ride out. It is logged, not paged.
      # Exits 3/4/5/11/12 (repo not muso, self-approval, requester not
      # authorized, sensitive path, policy malformed) never clear on retry.
      # Everything else — 8 above all — is transient. No state file: see
      # WHY STATELESS above.
      case "$rc" in
        3|4|5|11|12)
          log "DECLINED-PERMANENT (exit $rc): $repo#$pr — $(printf '%s' "$out" | tail -1)"
          declined_permanent=$((declined_permanent + 1)) ;;
        *)
          log "DECLINED (exit $rc): $repo#$pr — $(printf '%s' "$out" | tail -1)"
          declined=$((declined + 1)) ;;
      esac
    fi

    # Relay the wrapper's alerts on BOTH branches. GO is exactly when they
    # matter, and the wrapper replays them on refusals too.
    qar_publish_alerts "$repo" "$pr" "$head_sha" "$uid" "$rc" "$out" \
      || alerts_unpublished=$((alerts_unpublished + 1))
  done < <(printf '%s' "$prs_json" | jq -r '.[] | [.number, .headRefOid, .author.login, .isDraft] | @tsv')
  if [ "$repo_self" -gt 0 ]; then
    log "SKIP: $repo — $repo_self PR(s) authored by the acting QA identity ($me); self-approval is permanently blocked by GitHub, so they cost 0 reads"
  fi
  if [ "$budget_hit" -eq 1 ] || [ "$floor_hit" -eq 1 ]; then break; fi
done

if [ "$floor_hit" -eq 1 ]; then
  log "RATE FLOOR: core remaining=$floor_rem is below floor=$RATE_FLOOR at $floor_at — standing down mid-repo; $(( ${#REPOS[@]} - repo_idx )) repo(s) after it not swept. Expected steady state, not a failure."
fi

if [ "$budget_hit" -eq 1 ]; then
  log "CALL BUDGET: $rest_calls REST call(s) reached the per-tick budget of $MAX_CALLS — standing down at $budget_at; $(( ${#REPOS[@]} - repo_idx )) repo(s) after it not swept. Counts calls (reviews per page, other reads once), so real spend can be higher. Expected steady state, not a failure."
fi

log "tick done — considered=$considered approved=$approved declined=$declined declined_permanent=$declined_permanent self_authored=$self_authored skipped=$skipped read_failures=$read_fail alerts_unpublished=$alerts_unpublished raced=$raced repo_read_failures=$repo_fail/${#REPOS[@]} reviews_read_failures=$reviews_fail/$considered truncated_repos=$truncated safety_read_failures=$safety_fail/$safety_considered unsafe_unflagged=$unsafe_unflagged"

# ── Total blackout ───────────────────────────────────────────────────────
# Per-repo read failures are counted above, but counters in a log nobody reads
# are not a signal: if the token loses access or every read starts 403ing, the
# lane silently repairs nothing while systemd stays green and affected PRs sit
# at REVIEW_REQUIRED indefinitely. So when EVERY repo in scope failed its list
# read and not one PR was even looked at, say so out of band and exit non-zero.
#
# Requiring all repos (16 of them) plus considered=0 is what keeps this from
# firing on a blip — one flaky repo is a counter, a fleet-wide blackout is a
# page.
#
# Deduped on purpose. The sibling reconciler's two read-failure watchdogs have
# no cooldown, and during the 2026-08-17 GitHub outage they paged #clio_devops
# every 15 minutes for hours. A 10-minute timer with an undeduped pager would
# reproduce that exactly, so the stamp is written BEFORE the page (and at the
# moment it is decided, never at end-of-tick where a SIGTERM would lose it).
# ── Terminal backstop failure ────────────────────────────────────────────
# qar_go_red is the last line of defence: a PR is already approved and green,
# its required alert never published, and the red status could not be set. When
# even that fails — comment POST, both status attempts, AND the author DM all
# gone — the PR is sitting there looking reviewed with nothing anywhere saying
# otherwise. That must not be a tick that exits 0.
#
# One more delivery channel is tried here, through the CONFIRMED-delivery pager
# rather than the best-effort one, and the tick exits 4 regardless. Uncooled on
# purpose: once approved the PR is skipped by has_approval on later ticks, so
# this cannot repeat for the same PR and a cooldown could only lose it.
if [ "$unsafe_unflagged" -gt 0 ]; then
  unsafe_msg="qa-approval-retry: UNSAFE AND UNFLAGGED — $unsafe_unflagged PR(s) were approved by this lane but could not be marked unsafe: the alert comment, BOTH qa-review status attempts, and the author DM all failed. They are approved and GREEN with no warning anywhere. Find them in /var/lib/hydra/qa-approval-retry and check them by hand NOW."
  log "$unsafe_msg"
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] WOULD PAGE: unsafe-and-unflagged"
  elif ! qar_send_page "$unsafe_msg"; then
    log "CRITICAL: could not deliver the unsafe-and-unflagged page either — every notification channel this lane has is down. Exit 4 is the only remaining signal."
  fi
  exit 4
fi

# TWO endpoints can black out independently, and covering only the first was a
# real gap: on 2026-08-17 `pr list` kept working while `pulls/<n>/reviews`
# returned errors for hours, which is precisely the shape where repo_fail stays
# 0, considered is non-zero, and nothing pages.
blackout_why=""
if [ "${#REPOS[@]}" -gt 0 ] && [ "$repo_fail" -eq "${#REPOS[@]}" ] && [ "$considered" -eq 0 ]; then
  blackout_why="all ${#REPOS[@]} repo(s) failed their open-PR list read and no PR was evaluated this tick"
elif [ "$considered" -gt 0 ] && [ "$reviews_fail" -eq "$considered" ]; then
  blackout_why="every one of the $considered candidate PR(s) failed its reviews read, so no verdict could be classified"
elif [ "$safety_considered" -gt 0 ] && [ "$safety_fail" -eq "$safety_considered" ]; then
  blackout_why="every one of the $safety_considered GO candidate(s) failed a staleness/safety read (timeline, review threads, or the pre-write head re-confirmation)"
fi
if [ -n "$blackout_why" ]; then
  qar_page_cooled "$BLACKOUT_STAMP" "blackout" \
    "qa-approval-retry: TOTAL READ BLACKOUT — $blackout_why. Withheld approvals are NOT being repaired; PRs stay at REVIEW_REQUIRED until this clears. Check the qa-gh token and GitHub availability."
  exit 3
fi
exit 0
