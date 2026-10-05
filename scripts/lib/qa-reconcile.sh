#!/usr/bin/env bash
# qa-reconcile.sh — pure, sourceable decision functions for
# scripts/qa-review-reconcile.sh (the QA auto-review reconciler).
#
# WHY THIS EXISTS: hydra's QA auto-review lane loses reviews silently. A
# dispatch mints a one-shot openclaw cron; a gateway restart (deploy,
# codex-token-refresh, a crash) kills it before it fires; openclaw never
# re-arms a past-due one-shot; the "sweeps stale qa-autoreview-pr-* one-shots"
# cleanup in qa-dispatch-pr-review.sh then deletes the never-fired row with no
# trace. Confirmed losses: muso-skills#2 (18h undetected), core-backend#9243
# (15 days undetected). This reconciler makes the invariant "a review that was
# expected produces a verdict or a page" mechanically true, independent of
# whether the original dispatch (cron, gateway, or the flaky
# repository_dispatch transport) survived.
#
# Split from scripts/qa-review-reconcile.sh (the timer entrypoint, which does
# all I/O — gh, openclaw, dispatch, Slack) so the decision logic is testable
# without a live gateway or GitHub, mirroring lib/cron-store.sh and
# lib/gateway-restart.sh. No side effects at SOURCE time; several functions
# here (state read/write) DO have side effects when CALLED, exactly like
# cron_store_reimport.
#
# All of this reconciler's OWN bookkeeping (grace, cooldown, last-attempt) uses
# epoch SECONDS, matching the rest of the repo's watchdogs (MERGE_LANDING_*).
# openclaw cron JSON fields (*AtMs) are milliseconds and are converted where
# read — see qar_cron_state.

# ── Repo scope ────────────────────────────────────────────────────────────
# qar_expected_repos <allowlist-list-output>
# Input: the newline-separated stdout of the allowlist script run in
# enumeration mode (QA_EXTERNAL_REPO_ALLOWLIST_ENUMERATE=1, no arguments)
# (owner/repo per line). Echoes that set PLUS Muso-AI/hydra (hydra is not in
# the external allowlist — it is reviewed via a different workflow,
# qa-autoreview.yml — but it IS in the reconciler's scope, and is the intended
# first `merge_gate_repos` entry). Deduplicated, one per line.
qar_expected_repos() {
  printf '%s\n%s\n' "$1" "Muso-AI/hydra" | grep -v '^$' | sort -u
}

# qar_repo_gated_base <repo> <base-ref>
# rc 0 = a review is expected on PRs against this base for this repo.
# hydra: main only (qa-autoreview.yml:135). External repos: develop, main, or
# master (external-pr-review.yml:161). These differ deliberately — encoded
# per-repo, never averaged.
qar_repo_gated_base() {
  local repo="$1" base="$2"
  if [ "$repo" = "Muso-AI/hydra" ]; then
    [ "$base" = "main" ]
  else
    case "$base" in
      develop|main|master) return 0 ;;
      *) return 1 ;;
    esac
  fi
}

# ── Verdict identity (bot logins) ─────────────────────────────────────────
# qar_bot_logins <qa-approval-policy.json>
# Echo the policy's .identity.bot_logins array (JSON) on stdout. rc 1 if the
# file is unreadable/malformed, or the key is missing/null/not-an-array — the
# caller MUST refuse + page on rc 1, never guess a login set (qa-pr-approve.sh
# idiom, reused rather than reimplemented).
qar_bot_logins() {
  local policy="$1" out
  [ -r "$policy" ] || return 1
  out="$(jq -e -c '
    if (has("identity") and (.identity | type) == "object"
        and (.identity | has("bot_logins"))
        and (.identity.bot_logins | type) == "array")
    then .identity.bot_logins
    else error("bot_logins missing/malformed") end
  ' "$policy" 2>/dev/null)" || return 1
  printf '%s' "$out"
}

# qar_has_bot_review <reviews-json> <head-sha> <bot-logins-json>
# reviews-json: `gh api repos/<repo>/pulls/<pr>/reviews` array (objects with
# .commit_id, .user.login). rc 0 iff some review's .commit_id equals head-sha
# AND its author is LITERALLY (exact string equality, via array `index()`) a
# member of bot-logins.
#
# LITERAL EQUALITY ONLY — never test()/match()/contains(). The policy carries
# "muso-qa-bot[bot]"; in jq's regex engine `[bot]` is a character class, so
# `test($login)` matches "muso-qa-bo" + one of b/o/t, not the literal string.
# That is not hypothetical: it broke a live rehearsal (9 healthy PRs
# misclassified as lost because the login test silently matched wrong strings
# some other way). `--argjson bots` + `index($l)` is exact-string membership,
# immune to this class of bug by construction.
qar_has_bot_review() {
  local reviews_json="$1" head_sha="$2" logins_json="$3"
  jq -e --arg sha "$head_sha" --argjson bots "$logins_json" '
    any(.[]?; (.commit_id == $sha) and (.user.login as $l | $bots | index($l)) != null)
  ' <<<"$reviews_json" >/dev/null 2>&1
}

# qar_qa_review_status_state <combined-status-json>
# combined-status-json: `gh api repos/<repo>/commits/<sha>/status` (one row per
# context, already latest-only). rc 0: echoes the qa-review context's .state
# (pending|success|failure|error), or "absent" if no such context exists —
# both are legitimate parses. rc 1 (echoes nothing): jq itself failed
# (compile error rc3, runtime type error rc5 on malformed input) — the
# caller MUST route this to the READ-FAILURE path, never treat it as
# "absent" (a swallowed jq failure reading as "no verdict" is the single
# highest-severity failure mode this script's header calls out for the gh
# layer; the jq layer that interprets gh's body needs the same discipline).
qar_qa_review_status_state() {
  local status_json="$1" out
  out="$(jq -r '
    (.statuses // []) | map(select(.context == "qa-review")) | first | .state // "absent"
  ' <<<"$status_json" 2>/dev/null)" || return 1
  [ -n "$out" ] || out="absent"
  printf '%s' "$out"
}

# qar_qa_review_rollup_state <pr-list-rollup-json>
# Input: the `statusCheckRollup` ARRAY that `gh pr list --json
# statusCheckRollup` already returns per PR. That array is the same fact as
# `gh api repos/<repo>/commits/<sha>/status` for our one context — GitHub's
# rollup keeps the LATEST state per context for the PR's head commit — but it
# arrives on the PR list's GraphQL budget instead of spending the shared REST
# core budget every other gh call in this lane draws on.
# Echoes success|failure|error|pending|absent, lowercased.
# rc 1 (echoes nothing) when jq itself failed: the caller MUST treat that as
# "no answer" and fall back to the per-PR reads, never as "absent" — the same
# discipline qar_qa_review_status_state documents for its own parse.
qar_qa_review_rollup_state() {
  local rollup_json="$1" out
  out="$(jq -r '
    (if type == "array" then . else [] end)
    | map(select((.context // .name // "") == "qa-review"))
    | first
    | (if . == null then "absent"
       else ((.state // .conclusion // "absent") | ascii_downcase) end)
  ' <<<"$rollup_json" 2>/dev/null)" || return 1
  [ -n "$out" ] || out="absent"
  printf '%s' "$out"
}

# qar_classify_verdict <has-bot-review 0|1> <status-state> <repo-is-merge-gated 0|1>
# Echoes one of: verdict | pending-suppress | candidate.
#   verdict           — a terminal state exists (bot review on head, OR
#                        status success/failure/error). No action needed.
#   pending-suppress  — status is "pending" and the repo is NOT merge-gated.
#                        Not a verdict, but also not (yet) a provable loss on a
#                        repo this reconciler does not enforce a merge gate
#                        for — some other process (or a prior reconciler tick)
#                        armed it, so we do not pile a duplicate dispatch on
#                        top. (Design decision — see qa-review-reconcile.sh
#                        header for the reasoning and the test that pins it.)
#   candidate         — nothing found, OR (merge-gated AND status is stale
#                        "pending") — a merge-gated repo must not let a
#                        never-resolving pending silence the reconciler
#                        forever, since THAT repo's merge queue depends on a
#                        real verdict landing.
#
# ON A MERGE-GATED REPO A BOT REVIEW IS NOT SUFFICIENT — the STATUS is the gate.
# The reviewing skill posts its COMMENT review (Step 6) BEFORE it publishes the
# terminal `qa-review` status (Step 6b). If the gateway dies in that window, the
# PR carries a bot review on the head sha while the required check is still
# `pending`. Treating the review as a verdict there would leave the required
# check pending forever with the reconciler believing everything is fine, and
# GitHub never times out a required check that was never reported — so the PR
# becomes permanently unmergeable, silently. That is this whole script's failure
# class, reproduced inside its own classifier. On a gated repo we therefore
# require a TERMINAL STATUS regardless of any review; bot-review + pending is a
# `candidate`, so it is retried and, on exhaustion, driven red.
qar_classify_verdict() {
  local has_bot_review="$1" status_state="$2" gated="$3"
  case "$status_state" in
    success|failure|error) echo "verdict"; return 0 ;;
  esac
  # Ungated repo: no required check exists, so a bot review IS the verdict.
  if [ "$gated" != "1" ] && [ "$has_bot_review" = "1" ]; then
    echo "verdict"; return 0
  fi
  if [ "$status_state" = "pending" ] && [ "$gated" != "1" ]; then
    echo "pending-suppress"; return 0
  fi
  echo "candidate"
}

# ── Cron suppressor ────────────────────────────────────────────────────────
# qar_cron_state <cron-list-json> <job-name> <now-epoch-ms> <stale-budget-s>
# cron-list-json: `openclaw --profile main cron list --all --json` (MUST be
# --all — bare `cron list` hides disabled rows). Echoes one of:
#   running        — .state.runningAtMs present AND fresh (now_ms -
#                    runningAtMs <= budget), OR top-level .status=="running"
#                    (no timestamp to judge staleness on that field — it is
#                    THIS tick's live read, so it is fresh by construction).
#   running-stale  — .state.runningAtMs present but OLDER than the budget: a
#                    killed run whose row never got cleaned up. Distinct from
#                    "running" because a stale runningAtMs is NOT evidence a
#                    review is still in flight (see the freshness-bound note
#                    below) — the caller must NOT suppress on this.
#   queued         — .state has nextRunAtMs only (never run, never running)
#                    AND that nextRunAtMs is in the future or only recently
#                    past (within the budget).
#   queued-stale   — same shape as "queued" but nextRunAtMs is past-due by
#                    MORE than the budget: openclaw never re-armed a past-due
#                    one-shot, so this row will never fire on its own. NOT
#                    evidence of a review in flight — the caller must NOT
#                    suppress on this (this is the exact reintroduction of
#                    the bug this reconciler exists to fix; see the caller's
#                    comment).
#   done           — job exists but already ran (has lastRunAtMs) and is not
#                    running — NOT in flight, does not suppress (a failed
#                    one-shot lingers exactly like this; deleteAfterRun only
#                    fires on outcome=ok).
#   absent         — no job with that name
#   unknown        — .hasMore == true; the set could not be derived (no
#                    pagination flags exist on this openclaw build) — OR the
#                    input is empty/whitespace-only, which is what a failed
#                    `cron list` read produces (e.g. `... || true` on a
#                    gateway that is mid restart — exactly the moment this
#                    reconciler matters most). Empty is NOT evidence of
#                    absence; it means the set could not be read at all, so
#                    it goes in the same bucket as an unparseable/garbage
#                    response — the caller must NOT suppress forever on
#                    "unknown" (see the 2x-grace override, unchanged by the
#                    freshness bound below — it is a separate escape for a
#                    separate kind of "cannot confirm").
#
# WHY A FRESHNESS BOUND: mere PRESENCE of runningAtMs/nextRunAtMs is not
# evidence a review is currently in flight — a killed run leaves a stale
# runningAtMs forever, and a gateway restart before a past-due one-shot fires
# leaves a stale nextRunAtMs forever (openclaw never re-arms it). Both rows
# then survive at their same age on every future tick (the sweep in
# qa-dispatch-pr-review.sh deliberately never deletes a never-run row, for
# the same reason this reconciler exists — deleting it is what silently lost
# reviews in the first place). Treating bare presence as "in flight" would
# suppress on that same wedged row forever, reintroducing the exact silent-
# loss bug this whole reconciler exists to fix, permanently rather than for
# an hour. Freshness, not mere presence, is what licenses suppression.
#
# has()-based presence checks throughout (never jq `//`, which treats false
# as null). Staleness is decided by an explicit numeric type check inside jq
# (never the `| numbers` sort-order guard trick — deliberately avoided here:
# jq sorts strings ABOVE numbers, so a `<`/`<=` comparison against a garbage
# non-numeric timestamp would need that guard to stay safe; a `type ==
# "number"` check sidesteps the whole ordering trap by construction).
qar_cron_state() {
  local cron_json="$1" job_name="$2" now_ms="$3" stale_budget_s="$4" has_more budget_ms
  # Empty/whitespace-only input (a failed read, not a valid "no jobs"
  # response) must land in "unknown", never fall through case matching to a
  # bare "" that neither the caller's suppress-arm nor the "unknown" arm
  # recognizes.
  if [ -z "${cron_json//[[:space:]]/}" ]; then
    echo "unknown"
    return 0
  fi
  has_more="$(jq -r '.hasMore // false' <<<"$cron_json" 2>/dev/null)" || { echo "unknown"; return 0; }
  if [ "$has_more" = "true" ]; then
    echo "unknown"
    return 0
  fi
  [[ "$now_ms" =~ ^[0-9]+$ && "$stale_budget_s" =~ ^[0-9]+$ ]] || { echo "unknown"; return 0; }
  budget_ms=$((stale_budget_s * 1000))
  jq -r --arg n "$job_name" --argjson now_ms "$now_ms" --argjson budget_ms "$budget_ms" '
    def is_fresh(ts): (ts | type) == "number" and (($now_ms - ts) <= $budget_ms);
    ((.jobs // []) | map(select(.name == $n)) | first) as $j
    | if $j == null then "absent"
      elif (($j.state // {}) | has("runningAtMs")) then
        (if is_fresh($j.state.runningAtMs) then "running" else "running-stale" end)
      elif ($j.status == "running") then "running"
      elif (($j.state // {}) | has("lastRunAtMs")) then "done"
      elif (($j.state // {}) | has("nextRunAtMs")) then
        (if is_fresh($j.state.nextRunAtMs) then "queued" else "queued-stale" end)
      else "done"
      end
  ' <<<"$cron_json" 2>/dev/null || echo "unknown"
}

# ── Timing ─────────────────────────────────────────────────────────────────
# qar_grace_ok <now-epoch-s> <ready-epoch-s> <grace-s>  — rc0 iff elapsed >= grace
qar_grace_ok() {
  local now="$1" ready="$2" grace="$3"
  [[ "$now" =~ ^[0-9]+$ && "$ready" =~ ^[0-9]+$ && "$grace" =~ ^[0-9]+$ ]] || return 1
  [ $((now - ready)) -ge "$grace" ]
}

# qar_cooldown_ok <now-epoch-s> <last-attempt-epoch-s-or-empty> <cooldown-s>
# rc0 iff no prior attempt, or elapsed >= cooldown.
qar_cooldown_ok() {
  local now="$1" last="$2" cooldown="$3"
  [ -n "$last" ] && [ "$last" != "null" ] || return 0
  [[ "$now" =~ ^[0-9]+$ && "$last" =~ ^[0-9]+$ && "$cooldown" =~ ^[0-9]+$ ]] || return 1
  [ $((now - last)) -ge "$cooldown" ]
}

# qar_attempts_exhausted <attempts> <max> — rc0 iff attempts >= max
qar_attempts_exhausted() {
  local attempts="$1" max="$2"
  [[ "$attempts" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ ]] || return 1
  [ "$attempts" -ge "$max" ]
}

# ── Age scope (storm guard) ────────────────────────────────────────────────
# WHY THIS EXISTS: design (iii) deliberately ignores the ack comment as a
# signal, so it cannot distinguish "never dispatched because this repo's QA
# lane did not exist yet" from "dispatched and lost". A live rehearsal against
# node-8 found 59 PRs with the expectation predicate true and no verdict, ages
# 131h to 7106h (296 days) — pre-lane PRs from repos onboarded to the
# allowlist long after those PRs opened (muso-skills, platform-ticker:
# 2026-08-12). Shipped without a bound, the first tick would re-dispatch to
# the global cap and keep doing so every 15 min for days, saturating the
# serialized qa lane reviewing 10-month-old PRs.
#
# The bound is PER-REPO, not global: a single global watermark only fixes the
# initial rollout flood. Every future allowlist onboarding would re-flood
# with THAT repo's pre-lane backlog, because those PRs' heads postdate the
# reconciler's global first run but predate the repo's own onboarding. So each
# repo gets its own epoch = the first tick the reconciler ever saw that repo
# in scope (self-installing: no git archaeology, no manual per-onboarding
# step). A 14-day ceiling is a belt against a lost/reset state file re-minting
# every epoch to "now" and (transiently) admitting nothing, or a corrupted
# epoch admitting everything.
#
# Rule: act iff trigger_time >= max(repo_epoch, now - ceiling).
# trigger_time = max(last head push, last ready_for_review transition) — NOT
# head-push alone, because a dispatch lost on a ready_for_review event against
# an older head would otherwise be permanently invisible to this bound.

# qar_max_epoch <a> <b-or-empty> — echo the larger of two epoch-seconds
# values; a bare/missing b is ignored (used to fold in an optional
# ready_for_review timestamp that the caller may not have looked up yet).
qar_max_epoch() {
  local a="$1" b="${2:-}"
  if [ -z "$b" ] || [ "$b" = "null" ]; then
    printf '%s' "$a"
    return 0
  fi
  if [ "$b" -gt "$a" ] 2>/dev/null; then printf '%s' "$b"; else printf '%s' "$a"; fi
}

# qar_trigger_in_scope <trigger-epoch-s> <repo-epoch-s> <now-epoch-s> <ceiling-s>
# rc 0 iff trigger_time >= max(repo_epoch, now - ceiling).
qar_trigger_in_scope() {
  local trigger="$1" repo_epoch="$2" now="$3" ceiling="$4" floor
  [[ "$trigger" =~ ^[0-9]+$ && "$repo_epoch" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ && "$ceiling" =~ ^[0-9]+$ ]] || return 1
  floor=$((now - ceiling))
  [ "$repo_epoch" -ge "$floor" ] && floor="$repo_epoch"
  [ "$trigger" -ge "$floor" ]
}

# qar_state_repo_epoch <state-json> <repo> — echo the repo's epoch-seconds, or
# empty if this repo has never been minted an epoch.
qar_state_repo_epoch() {
  jq -r --arg r "$2" '(.__repo_epochs__[$r] // empty)' <<<"$1" 2>/dev/null
}

# qar_state_ensure_repo_epochs <state-json> <repos-newline-list> <now-epoch-s>
# Echo a NEW state object where every repo in the list that does NOT already
# have an epoch gets one minted = now. Existing epochs are never overwritten
# (an epoch is a one-time "first seen in scope" mark, not a rolling window).
# Called every tick with the full current repo set — this is what makes a
# newly-onboarded repo (and, identically, a first-ever run against a missing
# state file) self-install its epoch with no special-case code.
qar_state_ensure_repo_epochs() {
  local state="$1" repos="$2" now="$3" repos_json
  repos_json="$(printf '%s\n' "$repos" | grep -v '^$' | jq -R -s -c 'split("\n") | map(select(length > 0))' 2>/dev/null)" || repos_json='[]'
  jq -c --argjson repos "$repos_json" --argjson now "$now" '
    .__repo_epochs__ = ((.__repo_epochs__ // {}) as $e
      | reduce $repos[] as $r ($e; if (. | has($r)) then . else .[$r] = $now end))
  ' <<<"$state" 2>/dev/null
}

# ── Ready-for-review cache ─────────────────────────────────────────────────
# The ready_for_review timeline lookup is only needed for non-draft PRs the
# head-push bound would otherwise exclude, and is cached per-PR keyed on the
# PR's own `updatedAt` so a stable PR costs one timeline call ever, not one
# per tick. Reserved key "__ready_cache__" -> {"repo#pr": {"updated_at":...,
# "ready_epoch": N}}.

# qar_ready_cache_get <state-json> <repo> <pr> <updated-at>
# Echo the cached ready-epoch-seconds iff the cache entry's updated_at still
# matches (a changed updatedAt invalidates the cache — the PR moved since we
# looked). Echoes nothing (cache miss) otherwise.
qar_ready_cache_get() {
  local state="$1" key="$2#$3" updated_at="$4"
  jq -r --arg k "$key" --arg u "$updated_at" '
    (.__ready_cache__[$k] // empty) as $c
    | if ($c != "" and $c.updated_at == $u) then $c.ready_epoch else empty end
  ' <<<"$state" 2>/dev/null
}

# qar_ready_cache_put <state-json> <repo> <pr> <updated-at> <ready-epoch-s>
qar_ready_cache_put() {
  local state="$1" key="$2#$3" updated_at="$4" ready_epoch="$5"
  jq -c --arg k "$key" --arg u "$updated_at" --argjson r "$ready_epoch" \
    '.__ready_cache__[$k] = {"updated_at": $u, "ready_epoch": $r}' <<<"$state" 2>/dev/null
}

# ── Durable state ──────────────────────────────────────────────────────────
# Keyed by "repo#pr@head_sha" -> {"attempts":N,"last_attempt_epoch":N,"paged":bool}
# Plus reserved keys "__meta__" (whole-tick-read-failure counter),
# "__repo_epochs__" (per-repo storm-guard epochs) and "__ready_cache__"
# (ready_for_review timeline cache) — none collide with a real per-PR key,
# which always contains both "#" and "@".

# qar_state_read <file>
# Echoes the state object. A MISSING file is normal-first-run: echoes "{}",
# rc 0. An EXISTING-but-unparseable file is a corruption: rc 1, echoes
# nothing. Callers MUST treat rc 1 as "refuse to dispatch this tick + page" —
# a corrupt attempt counter must never silently become an unbounded dispatch
# loop (fail-closed, not fail-open on a read error).
qar_state_read() {
  local f="$1" out
  if [ ! -f "$f" ]; then
    echo '{}'
    return 0
  fi
  out="$(jq -e -c 'if type == "object" then . else error("state root is not an object") end' "$f" 2>/dev/null)" || return 1
  printf '%s' "$out"
}

# qar_state_entry <state-json> <key> — echo the entry object, or "null".
qar_state_entry() {
  jq -c --arg k "$2" '.[$k] // null' <<<"$1" 2>/dev/null
}

# qar_state_put <state-json> <key> <attempts> <last_attempt_epoch> <paged 0|1>
# Echo a NEW state object with that one entry set (does not touch other keys).
qar_state_put() {
  local state="$1" key="$2" attempts="$3" last="$4" paged="$5"
  jq -c --arg k "$key" --argjson a "$attempts" --argjson l "$last" \
    --argjson p "$([ "$paged" = "1" ] && echo true || echo false)" \
    '.[$k] = {"attempts": $a, "last_attempt_epoch": $l, "paged": $p}' <<<"$state" 2>/dev/null
}

# qar_state_put_unreachable <state-json> <key> <attempts> <last_attempt_epoch> <paged 0|1>
# Echo a NEW state with that entry written back for a dispatch that NEVER
# REACHED the gateway (dispatcher rc 75): attempts/paged are the caller's
# UNCHANGED values, last_attempt_epoch is advanced (the cooldown bound stays),
# and the entry's unreachable_attempts counter is incremented. qar_state_put
# replaces the entry wholesale, so a later rc-0 dispatch drops the counter.
qar_state_put_unreachable() {
  local state="$1" key="$2" attempts="$3" last="$4" paged="$5"
  jq -c --arg k "$key" --argjson a "$attempts" --argjson l "$last" \
    --argjson p "$([ "$paged" = "1" ] && echo true || echo false)" \
    '.[$k] = {"attempts": $a, "last_attempt_epoch": $l, "paged": $p,
              "unreachable_attempts": ((.[$k].unreachable_attempts // 0) + 1)}' <<<"$state" 2>/dev/null
}

# qar_state_meta_unreachable_ticks <state-json> — echo
# __meta__.consecutive_unreachable_ticks, default 0.
qar_state_meta_unreachable_ticks() {
  jq -r '(.__meta__.consecutive_unreachable_ticks // 0)' <<<"$1" 2>/dev/null || echo 0
}

# qar_state_set_meta_unreachable_ticks <state-json> <n> — echo new state with it set.
qar_state_set_meta_unreachable_ticks() {
  jq -c --argjson n "$2" '.__meta__.consecutive_unreachable_ticks = $n' <<<"$1" 2>/dev/null
}

# qar_state_meta_unreachable_last_alert <state-json> — epoch of the last
# gateway-unreachable page, 0 if never.
qar_state_meta_unreachable_last_alert() {
  jq -r '(.__meta__.unreachable_last_alert // 0)' <<<"$1" 2>/dev/null || echo 0
}

# qar_state_set_meta_unreachable_last_alert <state-json> <epoch>
qar_state_set_meta_unreachable_last_alert() {
  jq -c --argjson e "$2" '.__meta__.unreachable_last_alert = $e' <<<"$1" 2>/dev/null
}

# qar_state_keep_only <state-json> <keys-newline-list>
# Echo a NEW state object retaining ONLY the given keys (plus __meta__, which
# is never subject to per-PR pruning). This is the prune primitive: a key not
# passed here belongs to a PR that is closed/merged, or a sha that is no
# longer that PR's head — either way it cannot grow the file further.
qar_state_keep_only() {
  local state="$1" keys="$2" keys_json
  keys_json="$(printf '%s\n' "$keys" | grep -v '^$' | jq -R -s -c 'split("\n") | map(select(length > 0))' 2>/dev/null)" || keys_json='[]'
  jq -c --argjson keep "$keys_json" '
    . as $s
    | (reduce $keep[] as $k ({}; if ($s | has($k)) then .[$k] = $s[$k] else . end))
    | if ($s | has("__meta__"))         then .["__meta__"]         = $s["__meta__"]         else . end
    | if ($s | has("__repo_epochs__"))  then .["__repo_epochs__"]  = $s["__repo_epochs__"]  else . end
    | if ($s | has("__ready_cache__"))  then .["__ready_cache__"]  = $s["__ready_cache__"]  else . end
  ' <<<"$state" 2>/dev/null
}

# qar_state_meta_failures <state-json> — echo __meta__.consecutive_tick_failures, default 0.
qar_state_meta_failures() {
  jq -r '(.__meta__.consecutive_tick_failures // 0)' <<<"$1" 2>/dev/null || echo 0
}

# qar_state_set_meta_failures <state-json> <n> — echo new state with
# __meta__.consecutive_tick_failures set (never touches __meta__.repo_failures).
qar_state_set_meta_failures() {
  jq -c --argjson n "$2" '.__meta__.consecutive_tick_failures = $n' <<<"$1" 2>/dev/null
}

# ── Per-repo read-failure tracking (partial-fleet failures) ────────────────
# WHY: a whole-tick counter only pages when EVERY repo fails to list in the
# same tick. If 16/17 repos fail (an org token scope change, a visibility
# flip, a per-repo secondary rate limit) or one repo fails every tick
# forever, the whole-tick condition never fires and the failure is
# invisible past its own log lines. Tracked PER REPO so a single
# persistently-broken repo pages on its own, independent of the other 16.

# qar_state_repo_failure_count <state-json> <repo> — echo the repo's
# consecutive PR-list failure count, default 0.
qar_state_repo_failure_count() {
  jq -r --arg r "$2" '(.__meta__.repo_failures[$r] // 0)' <<<"$1" 2>/dev/null || echo 0
}

# qar_state_set_repo_failure_count <state-json> <repo> <n> — echo new state
# with that repo's consecutive-failure count set. n=0 removes the entry
# (a repo back to healthy needs no lingering row) rather than storing an
# explicit zero, so __meta__.repo_failures only ever lists currently-failing
# repos.
qar_state_set_repo_failure_count() {
  local state="$1" repo="$2" n="$3"
  if [ "$n" -eq 0 ]; then
    jq -c --arg r "$repo" '.__meta__.repo_failures = ((.__meta__.repo_failures // {}) | del(.[$r]))' <<<"$state" 2>/dev/null
  else
    jq -c --arg r "$repo" --argjson n "$n" '.__meta__.repo_failures = ((.__meta__.repo_failures // {}) | .[$r] = $n)' <<<"$state" 2>/dev/null
  fi
}

# ── Per-repo candidate-level (per-PR) read-failure tracking ────────────────
# WHY: qar_state_repo_failure_count above only tracks repo-LISTING failures
# (`gh pr list` itself). A durable failure one level down — every per-PR read
# (commit/timeline/reviews/status fetch) failing while listing keeps
# succeeding (a revoked token scope, a permissions change, a sustained
# secondary rate limit) — fed no counter at all: every affected PR silently
# stayed unclassified forever, with nothing to page on. Tracked PER REPO,
# separately from repo_failures, under its own __meta__ key so the two
# failure classes (can't list vs. can list but can't read) are never
# conflated.

# qar_state_repo_candidate_failure_count <state-json> <repo> — echo the
# repo's consecutive all-candidate-reads-failed tick count, default 0.
qar_state_repo_candidate_failure_count() {
  jq -r --arg r "$2" '(.__meta__.candidate_read_failures[$r] // 0)' <<<"$1" 2>/dev/null || echo 0
}

# qar_state_set_repo_candidate_failure_count <state-json> <repo> <n> — echo
# new state with that repo's consecutive candidate-read-failure count set.
# n=0 removes the entry (mirrors qar_state_set_repo_failure_count) so
# __meta__.candidate_read_failures only ever lists currently-failing repos.
qar_state_set_repo_candidate_failure_count() {
  local state="$1" repo="$2" n="$3"
  if [ "$n" -eq 0 ]; then
    jq -c --arg r "$repo" '.__meta__.candidate_read_failures = ((.__meta__.candidate_read_failures // {}) | del(.[$r]))' <<<"$state" 2>/dev/null
  else
    jq -c --arg r "$repo" --argjson n "$n" '.__meta__.candidate_read_failures = ((.__meta__.candidate_read_failures // {}) | .[$r] = $n)' <<<"$state" 2>/dev/null
  fi
}

# ── Per-repo, per-STAGE read-failure tracking ──────────────────────────────
# WHY: qar_state_repo_candidate_failure_count above only pages when EVERY
# per-PR read attempted this tick failed (repo_reads_failed >=
# repo_reads_attempted, aggregated across all of commit/timeline/reviews/
# status/author_uid). That hides a durable failure confined to ONE stage: if
# e.g. the reviews endpoint alone 5xxs every tick while commit reads keep
# succeeding, the aggregate has failed < attempted every tick, resets to 0,
# and every affected PR silently `continue`s on its reviews read forever with
# nothing to page on — the exact invisible-loss class this whole reconciler
# exists to kill, surviving inside the guard meant to close it. Tracked PER
# REPO PER STAGE (commit, timeline, reviews, status, author_uid) so a single
# persistently-broken stage pages on its own, independent of the other
# stages' health. Stored under __meta__.stage_failures[repo][stage],
# independent of both __meta__.repo_failures (listing) and
# __meta__.candidate_read_failures (the aggregate, kept as-is alongside this).

# qar_state_stage_failure_count <state-json> <repo> <stage> — echo the
# repo+stage's consecutive all-attempts-failed tick count, default 0.
qar_state_stage_failure_count() {
  jq -r --arg r "$2" --arg s "$3" '(.__meta__.stage_failures[$r][$s] // 0)' <<<"$1" 2>/dev/null || echo 0
}

# qar_state_set_stage_failure_count <state-json> <repo> <stage> <n> — echo
# new state with that repo+stage's consecutive-failure count set. n=0 removes
# the stage entry (and the repo entry too, once empty) rather than storing an
# explicit zero, mirroring qar_state_set_repo_failure_count, so
# __meta__.stage_failures only ever lists currently-failing (repo, stage)
# pairs.
qar_state_set_stage_failure_count() {
  local state="$1" repo="$2" stage="$3" n="$4"
  if [ "$n" -eq 0 ]; then
    jq -c --arg r "$repo" --arg s "$stage" '
      .__meta__.stage_failures = ((.__meta__.stage_failures // {})
        | .[$r] = ((.[$r] // {}) | del(.[$s]))
        | if (.[$r] // {}) == {} then del(.[$r]) else . end)
    ' <<<"$state" 2>/dev/null
  else
    jq -c --arg r "$repo" --arg s "$stage" --argjson n "$n" '
      .__meta__.stage_failures = ((.__meta__.stage_failures // {}) | .[$r] = ((.[$r] // {}) | .[$s] = $n))
    ' <<<"$state" 2>/dev/null
  fi
}

# ── Read-failure PAGE dedupe ───────────────────────────────────────────────
# The counters above are the DETECTION record and must keep incrementing every
# tick — but the page built off them must not. Both read-failure watchdogs
# re-page on EVERY tick once their counter is at/over the threshold, and the
# reconciler ticks every 15 minutes, so a sustained upstream failure posts ~2
# messages per affected repo per tick indefinitely. On 2026-08-17 a GitHub
# incident (Issues/PRs/Actions major outage; api.github.com answering 404 then
# 503 on repos/*/commits for private org repos) put 9 repos over the threshold
# at once — ~18 pages every 15 minutes about a single upstream event nobody
# could act on. That is the failure mode cron-health-watchdog.sh already names:
# "an undeduped page would post ~288 times a day and train everyone to ignore
# it" — and an alert people have learned to ignore is indistinguishable from
# the silent loss this reconciler exists to kill.
#
# Stamped per (repo, stage) — the same granularity the page is emitted at, so
# one noisy repo can never suppress a genuinely different repo's first page.
# The aggregate (candidate) watchdog stamps under the reserved pseudo-stage
# "__candidate__", which cannot collide with a real stage name.
#
# The stamp is CLEARED whenever the underlying counter resets to 0 (see
# qar_state_set_stage_failure_count / ..._repo_candidate_failure_count callers
# in qa-review-reconcile.sh): a repo that breaks, recovers, and breaks again an
# hour later must page again immediately. Without that clear, the dedupe would
# convert a real second incident into silence for the rest of the interval.

# qar_state_read_fail_last_alert <state-json> <repo> <stage> — echo the epoch
# at which this (repo, stage) last PAGED for a read failure, 0 if never.
qar_state_read_fail_last_alert() {
  jq -r --arg r "$2" --arg s "$3" '(.__meta__.read_fail_last_alert[$r][$s] // 0)' <<<"$1" 2>/dev/null || echo 0
}

# qar_state_set_read_fail_last_alert <state-json> <repo> <stage> <epoch> — echo
# new state with that stamp set. epoch=0 removes the entry (and the repo entry
# once empty) rather than storing an explicit zero, mirroring
# qar_state_set_stage_failure_count, so the map only ever lists (repo, stage)
# pairs with a live suppression window.
qar_state_set_read_fail_last_alert() {
  local state="$1" repo="$2" stage="$3" epoch="$4"
  if [ "$epoch" -eq 0 ]; then
    jq -c --arg r "$repo" --arg s "$stage" '
      .__meta__.read_fail_last_alert = ((.__meta__.read_fail_last_alert // {})
        | .[$r] = ((.[$r] // {}) | del(.[$s]))
        | if (.[$r] // {}) == {} then del(.[$r]) else . end)
    ' <<<"$state" 2>/dev/null
  else
    jq -c --arg r "$repo" --arg s "$stage" --argjson e "$epoch" '
      .__meta__.read_fail_last_alert = ((.__meta__.read_fail_last_alert // {}) | .[$r] = ((.[$r] // {}) | .[$s] = $e))
    ' <<<"$state" 2>/dev/null
  fi
}

# qar_read_fail_should_page <last-epoch> <now-epoch> <interval-s> — rc 0 when a
# page is due (never paged, or the interval has elapsed), rc 1 to suppress.
#
# EVERY unusual input fails toward PAGING (rc 0), never toward silence.
# Under-alerting is the dangerous direction: this predicate guards the only
# notification for a repo whose reads are broken, so a weird stamp must cost a
# duplicate page, never a missed one. Three such arms, all pinned by tests:
#   - non-numeric/empty stamp (unreadable state)
#   - last <= 0 (never paged; explicit rather than relying on `now` being a
#     large epoch — with a small `now` the subtraction below would otherwise
#     read "never paged" as "inside the window")
#   - last > now (host clock stepped backward, or corrupted state). Without
#     this, `now - last` is NEGATIVE, compares as less than the interval, and
#     suppresses until that future time PLUS the interval — an outage could
#     stay silent far beyond 6h.
qar_read_fail_should_page() {
  local last="$1" now="$2" interval="$3"
  case "$last" in (*[!0-9]*|"") return 0 ;; esac
  case "$now" in (*[!0-9]*|"") return 0 ;; esac
  case "$interval" in (*[!0-9]*|"") return 0 ;; esac
  if [ "$last" -le 0 ]; then return 0; fi
  if [ "$last" -gt "$now" ]; then return 0; fi
  [ $((now - last)) -ge "$interval" ]
}

# qar_state_prune_read_fail_alerts <state-json> <repos-newline-list> — echo new
# state with __meta__.read_fail_last_alert restricted to repos still in scope,
# mirroring qar_state_prune_stage_failures so a de-allowlisted repo cannot
# leave a stamp growing the state file forever.
qar_state_prune_read_fail_alerts() {
  local state="$1" repos="$2" repos_json
  repos_json="$(printf '%s\n' "$repos" | grep -v '^$' | jq -R -s -c 'split("\n") | map(select(length > 0))' 2>/dev/null)" || repos_json='[]'
  jq -c --argjson repos "$repos_json" '
    if (.__meta__.read_fail_last_alert // null) == null then .
    else .__meta__.read_fail_last_alert = ((.__meta__.read_fail_last_alert // {}) | with_entries(select(.key as $k | $repos | index($k) != null)))
    end
  ' <<<"$state" 2>/dev/null
}

# qar_state_prune_stage_failures <state-json> <repos-newline-list> — echo new
# state with __meta__.stage_failures restricted to repos still in scope, so a
# repo dropped from the allowlist cannot leave a stage-failure row growing
# the state file forever.
qar_state_prune_stage_failures() {
  local state="$1" repos="$2" repos_json
  repos_json="$(printf '%s\n' "$repos" | grep -v '^$' | jq -R -s -c 'split("\n") | map(select(length > 0))' 2>/dev/null)" || repos_json='[]'
  jq -c --argjson repos "$repos_json" '
    if (.__meta__.stage_failures // null) == null then .
    else .__meta__.stage_failures = ((.__meta__.stage_failures // {}) | with_entries(select(.key as $k | $repos | index($k) != null)))
    end
  ' <<<"$state" 2>/dev/null
}

# qar_state_write_atomic <file> <json>
# mkdir -p (NOT install -d — that re-chmods an existing dir) + mktemp + mv in
# the SAME dir (atomic rename requires same filesystem).
qar_state_write_atomic() {
  local file="$1" json="$2" dir tmp
  dir="$(dirname "$file")"
  mkdir -p "$dir" || return 1
  tmp="$(mktemp "$dir/.qa-reconcile-state.XXXXXX")" || return 1
  if ! printf '%s' "$json" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$file"
}
