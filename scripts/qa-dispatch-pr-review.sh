#!/usr/bin/env bash
set -euo pipefail

# qa-dispatch-pr-review.sh — fire-and-forget dispatch of a QA-agent auto-review
# of a hydra PR.
# ===========================================================================
# Called by .github/workflows/qa-autoreview.yml on the self-hosted hydra runner
# (which runs steps as root on the same host as the gateway, verified node-8)
# AFTER pr-validate finishes. It registers a one-shot openclaw cron job that
# wakes the `qa` agent to run the `muso-github-code-review` skill in AUTO MODE
# on the given PR. The review/approve happen asynchronously in the gateway.
#
# Why a one-shot `cron add` and not `openclaw agent`: `openclaw agent` is
# synchronous and would hold the single self-hosted runner for the whole review
# (up to its timeout), blocking other PRs' CI. `cron add --at` returns
# immediately and the turn runs async.
#
# Why isolated agentTurn and not `--session main`: on the live 2026.5.27 build
# `--session main` refuses `--message`/`--announce` (main jobs need a
# `--system-event` with no fallback delivery). Every production cron here uses
# isolated agentTurn and retains `exec` — e.g. credit-verification-batch-4h has
# 274 runs — so the historical isolated-tool-loss concern does not apply on this
# build (verified on node-8, not assumed).
#
# Scope: hydra PRs (default repo) AND any other Muso-AI repo passed explicitly —
# e.g. Muso-AI/ads-manager via .github/workflows/external-pr-review.yml.
#
# The requester UID is REQUIRED and has NO default. It is BOTH the qa-pr-approve
# allowlist gate and the Slack DM target, so a baked-in default would hand every
# manually-dispatched review the approval authority of whoever that default names
# — a two-arg `qa-dispatch-pr-review.sh <PR> <SHA>` on somebody else's PR would
# silently confer it AND write a false requester into the audit log, defeating any
# removal from the allowlist. The caller must resolve the PR's real author to a
# UID (scripts/lib/qa-author-slack-uid.sh) and pass it; both workflow callers do.
#
# Usage:
#   qa-dispatch-pr-review.sh <pr-number> <head-sha> [repo] <requester-uid>
#   (requester-uid may come from QA_REVIEW_REQUESTER_UID instead of the 4th arg;
#    absent from BOTH is a hard exit 2, never a default.)
#
# Args / env overrides (positional wins over env; env mainly for tests):
#   repo           ${QA_REVIEW_REPO:-Muso-AI/hydra}   (must be Muso-AI/<name>)
#   requester-uid  $QA_REVIEW_REQUESTER_UID           (Slack UID; approve+DM) REQUIRED
#   OPENCLAW       openclaw binary (default: openclaw)
#   OPENCLAW_GATEWAY_URL         target a REMOTE qa gateway instead of node-8's local
#                                `main` profile (see "Gateway target" below)
#   OPENCLAW_GATEWAY_TOKEN       its token, or OPENCLAW_GATEWAY_TOKEN_FILE = a file
#                                holding it. Required whenever the URL is set.
# (No delivery-target override: the cron uses --no-deliver and the skill owns all
# Slack delivery itself, so there is nothing for the cron to target.)
# Exit codes: 0 dispatched | 2 usage/validation | 75 (EX_TEMPFAIL) the `cron add`
# never reached the gateway (transport failure, see PRE_GATEWAY_SIGNATURES) so NO
# review was queued and the attempt did not happen -- the reconciler must not
# count it. Any other openclaw failure keeps openclaw's own rc (reached the
# gateway and was rejected: a real attempt).
#
# A transport failure is retried IN PLACE before 75 is returned (see
# QA_DISPATCH_TRANSPORT_ATTEMPTS below). 2026-11-06: hydra#1820 @ 086158df, run
# 42282917209 attempt 1 died on one `Opening handshake has timed out`, the
# workflow went red, and the review only happened because a human re-ran the job
# 11 minutes later -- the reconciler that is meant to catch exit 75 was not
# completing its ticks. A handshake timeout on a gateway that is merely busy
# clears in seconds; a few bounded, logged attempts are what that class is for.
#   QA_DISPATCH_TRANSPORT_ATTEMPTS  total `cron add` attempts on a transport
#                                   failure (default 3; 1 = the old behaviour)
#   QA_DISPATCH_RETRY_BACKOFF_S     space-separated sleeps between attempts
#                                   (default "10 30"; the last value repeats)
# ONLY a PROVABLY pre-gateway transport failure is retried (see
# RETRYABLE_SIGNATURES). A `cron add` the gateway rejected reached it and is a
# real attempt (never retried), and nothing here ever re-runs a review that was
# queued: a retry mints the cron only after the previous attempt provably never
# did. An AMBIGUOUS transport failure -- the socket died after the request may
# have been written, so a one-shot may already exist -- is never retried; it
# exits 75 and the reconciler re-dispatches, which sweeps any pending job for
# this PR first.

OPENCLAW="${OPENCLAW:-openclaw}"
PROFILE="main"
AGENT="qa"
TIMEOUT_SECONDS="1200"

# One EXIT trap for every temp file this script creates, installed HERE rather
# than next to the first `mktemp` that needs it. A second `trap ... EXIT` would
# silently REPLACE the first and leak the earlier file, so there is exactly one
# and it is above every branch that can exit. It used to live ~320 lines down,
# after the broker branch had already created and exited with its own temp file,
# so every broker dispatch leaked one. Both names are defaulted because this
# script runs under `set -u` and either branch may never have run.
trap 'rm -f "${add_err:-}" "${broker_err:-}"' EXIT

die() { echo "qa-dispatch-pr-review: $2" >&2; exit "$1"; }

# --- Gateway target (2026-10-28, node8-to-pods T9) ----------------------------
# UNSET (the default, and the revert): node-8's local `main` gateway through
# `--profile main`, tokenless as root. Byte-for-byte what this script always did.
#
# SET: OPENCLAW_GATEWAY_URL names the dedicated QA gateway pods
# (H-DevOps k8s/prod/hydra-qa/, Service qa-review-gateway). The openclaw CLI honours
# that variable natively, and then accepts ENV credentials only
# (openclaw docs/gateway/remote.md: an env URL never falls back to a config token),
# so a URL without a token cannot work. Refuse it here, before any call, instead
# of letting `cron add` reach the pod, get rejected, and be charged as an attempt.
# The token is read from OPENCLAW_GATEWAY_TOKEN_FILE when given (a mounted Secret),
# and only ever travels in the environment: `--token` would put it on argv, where
# `ps` on a shared runner host shows it to every user.
# `--profile main` is dropped in remote mode. The pod runs its own `qa` profile, and
# the local profile would only matter for its config token, which the CLI ignores
# under an env URL anyway; on an ARC runner pod there is no ~/.openclaw-main at all.
# There is deliberately NO fallback to the local gateway when the remote one is
# unreachable: that would hide a broken pod behind node-8 (the thing T9 empties).
# Transport failure exits 75 below, and the reconciler retries it.
OPENCLAW_ARGS=(--profile "$PROFILE")
GATEWAY_TARGET="local profile ${PROFILE}"
if [ -n "${OPENCLAW_GATEWAY_URL:-}" ]; then
  [[ "$OPENCLAW_GATEWAY_URL" =~ ^wss?://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?/?$ ]] \
    || die 2 "OPENCLAW_GATEWAY_URL must be ws(s)://<host>[:port], got '${OPENCLAW_GATEWAY_URL}'."
  if [ -n "${OPENCLAW_GATEWAY_TOKEN_FILE:-}" ]; then
    [ -f "$OPENCLAW_GATEWAY_TOKEN_FILE" ] && [ -r "$OPENCLAW_GATEWAY_TOKEN_FILE" ] \
      || die 2 "OPENCLAW_GATEWAY_TOKEN_FILE '${OPENCLAW_GATEWAY_TOKEN_FILE}' is not a readable file."
    IFS= read -r OPENCLAW_GATEWAY_TOKEN < "$OPENCLAW_GATEWAY_TOKEN_FILE" || true
    OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN%$'\r'}"
  fi
  [ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ] \
    || die 2 "OPENCLAW_GATEWAY_URL is set but no token: set OPENCLAW_GATEWAY_TOKEN or OPENCLAW_GATEWAY_TOKEN_FILE. The CLI ignores config tokens under an env URL, so the dispatch would be rejected by the gateway."
  export OPENCLAW_GATEWAY_URL OPENCLAW_GATEWAY_TOKEN
  # A port/state-dir override in the caller's env would steer the CLI elsewhere.
  unset OPENCLAW_GATEWAY_PORT OPENCLAW_STATE_DIR OPENCLAW_CONFIG_PATH OPENCLAW_PROFILE
  OPENCLAW_ARGS=()
  GATEWAY_TARGET="remote ${OPENCLAW_GATEWAY_URL}"
fi
# (bash 3.2 + set -u: an empty array must expand as ${a[@]+"${a[@]}"}.)

# --- Arg validation: fail loud. A silent no-op dispatcher is worse than none
#     (cf. dispatch-cv-batch.sh --help typo that fired 500 real writes). --------
[ "$#" -ge 2 ] && [ "$#" -le 4 ] \
  || die 2 "usage: qa-dispatch-pr-review.sh <pr-number> <head-sha> [repo] <requester-uid>"
pr="$1"
sha="$2"
# repo falls back to env, then the hydra default. The requester does NOT fall back
# to any person: see the header — an approval-bearing default is a silent grant.
REPO="${3:-${QA_REVIEW_REPO:-Muso-AI/hydra}}"
REQUESTER_UID="${4:-${QA_REVIEW_REQUESTER_UID:-}}"
[ -n "$REQUESTER_UID" ] || die 2 "requester-uid is REQUIRED — pass it as the 4th argument or set QA_REVIEW_REQUESTER_UID. There is deliberately NO default: this UID is both the qa-pr-approve allowlist gate and the DM target, so defaulting it would confer one person's approval authority on any PR dispatched by hand and log them as the requester. Resolve the PR's real author with scripts/lib/qa-author-slack-uid.sh."
[[ "$pr" =~ ^[0-9]+$ ]] || die 2 "pr-number must be numeric, got '$pr'."
[[ "$sha" =~ ^[0-9a-fA-F]{7,40}$ ]] || die 2 "head-sha must be a 7-40 char hex sha, got '$sha'."
# Only Muso-AI repos: matches the owner guard in qa-pr-approve.sh, and keeps a
# forged/typo'd repo from steering the review at a non-Muso target.
[[ "$REPO" =~ ^Muso-AI/[A-Za-z0-9._-]+$ ]] || die 2 "repo must be Muso-AI/<name>, got '$REPO'."
[[ "$REQUESTER_UID" =~ ^U[A-Z0-9]+$ ]] || die 2 "requester-uid must be a Slack UID (U...), got '$REQUESTER_UID'."

# --- Broker mode (QA_DISPATCH_MODE=broker) -----------------------------------
# The default remains "cron": mint a one-shot openclaw job exactly as this script
# always has. In broker mode the dispatch is instead an ENQUEUE on the durable
# queue (scripts/lib/qa_broker.py), and a worker pod claims it. Nothing about the
# key, the dedupe or the review changes — only where "a review is pending" lives.
#
# Why this exists: a cron one-shot dies with the gateway and openclaw never
# re-arms a past-due one-shot (muso-skills#2, core-backend#9243). A queue row
# survives a restart by construction. The reconciler keeps working either way.
#
# Exit codes in broker mode mirror the cron path's contract so no caller needs to
# change: 0 enqueued | 76 duplicate refused (the broker's own EX_DEDUP_REFUSED,
# the same value the cron path already returns for its in-flight refusal) |
# 75 (EX_TEMPFAIL) the broker itself was unreachable — NO review was queued and
# the attempt did not happen, so the reconciler must not charge it.
#
# QA_BROKER_DEDUPE_DONE (default go-only) means a key whose last review was GO is
# refused as a duplicate, while a failing verdict can be re-reviewed (capped) —
# see the broker module's header for the full contract.
QA_DISPATCH_MODE="${QA_DISPATCH_MODE:-cron}"
if [ "$QA_DISPATCH_MODE" = "broker" ]; then
  # The temp file must exist BEFORE the redirect below: this script runs under
  # `set -u`, so expanding an unassigned $broker_err aborts the dispatch and no
  # review is ever queued.
  broker_err="$(mktemp)"
  # The queue lives in the BROKER's database, not in this process's filesystem.
  # The broker is a single-replica pod with its own PVC, so a dispatcher running
  # on node-8 or a CI runner that wrote a local SQLite file would return 0 while
  # the broker's queue stayed empty and no review ever ran. So: POST to the
  # broker when QA_BROKER_URL is an http(s) URL, and only fall back to the local
  # CLI when it is explicitly "cli" (tests, and a single-host deployment).
  BROKER_URL="${QA_BROKER_URL:-http://qa-broker.hydra-qa.svc.cluster.local:8080}"
  BROKER_PY="${QA_BROKER_SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/qa_broker.py}"
  # Is this sha still the PR's head? The broker cannot see GitHub, and arrival
  # order is not commit order: a delayed dispatch for an OLDER head arrives after
  # the current one and would supersede it, leaving the current head with no
  # review and the stale head as the only claimable job. So the producer, which
  # CAN see GitHub, asserts it. A failed lookup asserts nothing: the broker then
  # queues the extra review instead of risking a cancelled one.
  # ${GH:-gh}, not $GH: GH is assigned further down (the cron path's dedupe
  # lookup) and this script runs under `set -u`, so a bare $GH here would abort
  # every broker dispatch with an unbound-variable error.
  #
  # The read also returns the PR's `updated_at`, which the broker uses as a
  # MONOTONIC ordering token. "Is this the current head" is a check-then-act:
  # this dispatch can verify head A, head B can be pushed, another dispatch can
  # verify and enqueue B, and only THEN can this one's POST arrive still
  # claiming current_head. Arrival order cannot break that tie; the verification
  # order can, and `updated_at` is that order (ISO-8601 UTC sorts
  # lexicographically, so the broker compares strings and needs no clock).
  current_head=0
  head_order=""
  if head_info="$("${GH:-gh}" api "repos/${REPO}/pulls/${pr}" \
       --jq '.head.sha + " " + .updated_at' 2>/dev/null)" \
     && [ -n "$head_info" ]; then
    head_now="${head_info%% *}"
    head_order="${head_info#* }"
    [ "$head_order" = "$head_info" ] && head_order=""
    if [ "$head_now" != "$sha" ]; then
      echo "qa-dispatch-pr-review: STALE-HEAD ${REPO}#${pr} @ ${sha} -- the PR head is now ${head_now}; nothing to queue."
      exit 0
    fi
    current_head=1
  else
    echo "qa-dispatch-pr-review: head lookup failed for ${REPO}#${pr}; enqueueing without supersede rights." >&2
  fi
  if [ "$BROKER_URL" = "cli" ]; then
    BROKER_ARGS=(--db "${QA_QUEUE_DB:-/var/lib/hydra-qa/queue.sqlite}" enqueue "$REPO" "$pr" "$sha" "$REQUESTER_UID")
    [ "${QA_BROKER_FORCE:-0}" = "1" ] && BROKER_ARGS+=(--force)
    [ "$current_head" = "1" ] && BROKER_ARGS+=(--current-head)
    [ -n "$head_order" ] && BROKER_ARGS+=(--head-order "$head_order")
    broker_out="$(python3 "$BROKER_PY" "${BROKER_ARGS[@]}" 2>"$broker_err")" && broker_rc=0 || broker_rc=$?
  else
    # The broker answers 200 (queued) / 409 (duplicate) with the CLI rc in the
    # body, so the same case statement below classifies both transports.
    broker_body="$(printf '{"repo":"%s","pr":%s,"head_sha":"%s","requester_uid":"%s","force":%s,"current_head":%s,"head_order":"%s"}' \
      "$REPO" "$pr" "$sha" "$REQUESTER_UID" \
      "$([ "${QA_BROKER_FORCE:-0}" = "1" ] && echo true || echo false)" \
      "$([ "$current_head" = "1" ] && echo true || echo false)" \
      "$head_order")"
    # -w writes the HTTP status on its own line after the body, so a 502 from a
    # proxy is distinguishable from a 200 from the broker. Without it a proxy
    # error page (or a JSON error body with no `rc`) looked like a successful
    # enqueue: curl exits 0, the missing rc defaulted to 0, and the dispatcher
    # reported "enqueued" for a row that does not exist. The reconciler then
    # treats the review as dispatched and the PR never gets a verdict.
    # The broker refuses mutations without its shared token.
    broker_auth=()
    [ -n "${QA_BROKER_TOKEN:-}" ] && broker_auth=(-H "X-QA-Broker-Token: $QA_BROKER_TOKEN")
    broker_out="$(curl -sS --max-time 20 -X POST "${BROKER_URL%/}/enqueue" \
      -H 'Content-Type: application/json' "${broker_auth[@]}" -d "$broker_body" \
      -w '\n%{http_code}' 2>"$broker_err")" && broker_rc=0 || broker_rc=$?
    if [ "$broker_rc" -eq 0 ]; then
      # The verdict is the body's rc (0 queued, 76 duplicate). An EXPLICIT rc
      # in the body is authoritative whatever the HTTP status, because the
      # broker's contract uses the status to carry meaning: a duplicate is
      # 409 + rc 76, and requiring 2xx here turned every repeat dispatch into
      # "broker unavailable" (75), which the reconciler then retried forever.
      # Without an explicit rc, only 2xx counts; anything else is a transport
      # failure and nothing was queued.
      broker_rc="$(printf '%s' "$broker_out" | python3 -c '
import json,sys
raw = sys.stdin.read()
body, _, code = raw.rpartition("\n")
try:
    http = int(code.strip())
except ValueError:
    print(75); raise SystemExit
try:
    d = json.loads(body)
except Exception:
    print(75); raise SystemExit
if isinstance(d, dict) and "rc" in d:
    try:
        print(int(d["rc"]))
    except (TypeError, ValueError):
        print(75)
    raise SystemExit
if not (200 <= http < 300):
    print(75); raise SystemExit
print(75)
' 2>/dev/null || echo 75)"
      # Strip the status line so the echoed body stays valid JSON.
      broker_out="${broker_out%$'\n'*}"
    fi
  fi
  # Re-emit the diagnostic verbatim; a classification must never swallow it.
  [ -s "$broker_err" ] && cat "$broker_err" >&2
  case "$broker_rc" in
    0)
      echo "qa-dispatch-pr-review: enqueued ${REPO}#${pr} (${sha}) on the QA broker."
      echo "$broker_out"
      exit 0
      ;;
    76)
      # Duplicate/superseded: the key is already queued, running or done. This is
      # the same "an equivalent review is already in flight" refusal the cron
      # path's GitHub run-list check produces, so QA_DEDUP_REFUSED_RC callers
      # treat it identically (no attempt charged).
      echo "qa-dispatch-pr-review: DEDUP-REFUSED ${REPO}#${pr} @ ${sha} -- the broker already holds this key; no-op."
      echo "$broker_out"
      exit "${QA_DEDUP_REFUSED_RC:-76}"
      ;;
    *)
      # A broker we cannot reach is a TRANSPORT failure, not a review failure:
      # nothing was queued. Exit 75 so the reconciler retries without burning an
      # attempt, exactly as it does for an unreachable gateway.
      echo "qa-dispatch-pr-review: BROKER-UNAVAILABLE (rc=$broker_rc) -- no review queued; exiting 75 (not an attempt)." >&2
      exit 75
      ;;
  esac
fi

# In-flight dedup (MUS-7955): refuse when GitHub already holds an equivalent review.
# Saves the downstream cost (an openclaw cron + a QA agent run), not runner time.
# Reads external-pr-review.yml's run-name `qa <repo>#<pr> @ <sha> (<action>)` and
# matches ONLY queued/in_progress runs GitHub actually created, within a tight
# window: a dropped repository_dispatch creates no run, so a re-send of it still
# dispatches. FAIL OPEN: any lookup problem dispatches anyway (a missed review is
# worse than a duplicate one). Our own run (GITHUB_RUN_ID) never counts against us;
# of two twins only the higher run id refuses, so one of them always proceeds.
# Lives here, not in the workflow, so the reconciler hits the same guard.
GH="${GH:-gh}"
DEDUP_WINDOW_SECONDS="${QA_DEDUP_WINDOW_SECONDS:-14400}"
# A malformed override must not reach the arithmetic below: under set -u it would
# abort the dispatch before the fail-open branch. Fall back to the default.
# 10# forces decimal: bash reads 08 as an invalid octal literal inside $(( )).
[[ "$DEDUP_WINDOW_SECONDS" =~ ^[0-9]+$ ]] && DEDUP_WINDOW_SECONDS=$((10#$DEDUP_WINDOW_SECONDS)) || DEDUP_WINDOW_SECONDS=14400
own_id="${GITHUB_RUN_ID:-0}"
[[ "$own_id" =~ ^[0-9]+$ ]] || own_id=0
if runs_json="$("$GH" run list -R Muso-AI/hydra --limit 200 --json databaseId,name,status,createdAt 2>/dev/null)" \
   && verdict="$(echo "$runs_json" | jq -r --arg r "$REPO" --arg p "$pr" --arg s "$(echo "$sha" | tr A-F a-f)" \
        --argjson own "$own_id" --argjson cut "$(( $(date -u +%s) - DEDUP_WINDOW_SECONDS ))" '
      [ .[] | select(.status == "queued" or .status == "in_progress")
            | select((.createdAt | fromdateiso8601) >= $cut)
            | select(.databaseId != $own)
            | (.name | capture("^qa (?<repo>[^#]+)#(?<pr>[0-9]+) @ (?<sha>[0-9a-fA-F]+) ") // empty) as $m
            | select($m.repo == $r and $m.pr == $p)
            | {id: .databaseId, same: (($m.sha | ascii_downcase) as $x | ($x | startswith($s)) or ($s | startswith($x)))} ] as $m
      | if   any($m[]; .same and ($own == 0 or .id < $own)) then "duplicate"
        elif $own > 0 and any($m[]; (.same | not) and .id > $own) then "superseded"
        else "ok" end' 2>/dev/null)"; then
  case "$verdict" in
    duplicate|superseded)
      echo "qa-dispatch-pr-review: DEDUP-REFUSED ${verdict} ${REPO}#${pr} @ ${sha} -- an equivalent review is already queued/in_progress; no cron minted (no-op)." >&2
      # Exit 0 for the workflows; the reconciler sets QA_DEDUP_REFUSED_RC=76 so a
      # refusal is not charged to it as an attempt (it would exhaust and page "lost").
      exit "${QA_DEDUP_REFUSED_RC:-0}" ;;
  esac
else
  echo "qa-dispatch-pr-review: DEDUP-SKIPPED ${REPO}#${pr} @ ${sha} -- in-flight lookup failed; dispatching anyway (fail open)." >&2
fi

# Namespace the one-shot job by repo so hydra#123 and ads-manager#123 never
# collide in the cron list (idempotency cleanup keys on the full name below).
# Keep the literal "qa-autoreview-pr-" prefix: the pr-validate orphan-check and
# the stale-sweep below both match on it, so neither needs to change.
job_name="qa-autoreview-pr-${REPO//\//-}-${pr}"

# Build the dispatch instruction. The unquoted heredoc expands ${...}; `read -d
# ''` slurps it into one var (avoids the bash 3.2 command-substitution+heredoc
# quote-parsing bug, so the script stays portable). The text is deliberately
# apostrophe/backtick-free for the same reason. The PR URL makes the qa agent
# run the skill (its MUST-RUN trigger); "AUTO-REVIEW" selects the skill Auto
# mode section.
# The instruction text lives in one place (scripts/lib/qa-review-prompt.sh) so
# the broker/worker path sends byte-identical text. See that file's header.
# shellcheck source=lib/qa-review-prompt.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/qa-review-prompt.sh"
message="$(qa_review_prompt "$REPO" "$pr" "$sha" "$REQUESTER_UID")"

# Idempotency: a re-push reruns CI and re-dispatches. Drop any still-pending job
# for this PR so we review the latest SHA, not a stale one. Best-effort — never
# fail the dispatch over cleanup.
# --all: bare `cron list` HIDES disabled rows (scripts/lib/cron-store.sh:54-64),
# so an idempotency check without it can miss a disabled leftover job.
# Remote mode: the Service round-robins, so this list (and the sweep's) sees ONE
# replica's store. A pending job for this PR on another replica is not removed; it
# fires within +5s anyway, and qa-pr-approve.sh pins the head sha it approves.
old_ids="$("$OPENCLAW" ${OPENCLAW_ARGS[@]+"${OPENCLAW_ARGS[@]}"} cron list --all --json 2>/dev/null \
  | jq -r --arg n "$job_name" '.jobs[]? | select(.name==$n) | .id' 2>/dev/null || true)"
while IFS= read -r id; do
  [ -n "$id" ] || continue
  "$OPENCLAW" ${OPENCLAW_ARGS[@]+"${OPENCLAW_ARGS[@]}"} cron rm "$id" >/dev/null 2>&1 || true
done <<< "$old_ids"

# Sweep stale qa-autoreview-pr-* one-shots left behind by earlier runs. A failed run is
# NOT reaped by --delete-after-run (deletion is gated on outcome=ok), so dead jobs pile up
# in the cron list.
#
# Premise: run EVIDENCE, not elapsed time. The sweep used to delete any job whose
# createdAtMs was >1h in the past, on the theory that a review always finishes well
# inside the 1200s timeout. That is an elapsed-time test, not a completion test: a
# job that only QUEUED (and never ran) is created up front, so an hour-old queued
# job was being deleted before it ever fired -- silently losing the review
# (muso-skills#2, core-backend#9243). Jobs are created --delete-after-run, which
# self-deletes only on a successful run, so anything the sweep still sees was, by
# construction, NOT a successful completion.
#
# Verified live field shape (node-8, `cron list --all --json`): run evidence is
# nested under `.state`, not a top-level `lastRunAtMs` (that key does not exist):
#   queued, never run   -> .state has nextRunAtMs only
#   currently running   -> .state.runningAtMs present, top-level .status=="running"
#   completed >=1 run   -> .state.lastRunAtMs/.lastStatus/.lastRunStatus present
#
# Rule: "has run" and "is not running" are two SEPARATE conditions, and this
# file must agree with qar_cron_state (scripts/lib/qa-reconcile.sh) on what
# "running" means -- that reconciler checks .state.runningAtMs / top-level
# .status=="running" FIRST and treats a job carrying both runningAtMs and
# lastRunAtMs as authoritatively running (e.g. a re-run of a job that already
# completed once). A predicate that only looked at lastRunAtMs would delete
# that same in-flight job out from under the reconciler -- reaping a live
# review whenever the qa lane is wedged past the 1200s timeout.
#
# Delete a qa-autoreview-pr-* job iff ALL of:
#   - .state.lastRunAtMs is present (it has run at least once), AND
#   - .state.runningAtMs is NOT present, AND top-level .status != "running"
#     (it is not currently running), AND
#   - .state.lastRunAtMs is older than 1800s (the 1200s job timeout plus
#     margin -- encodes "cannot still be running" as a second, independent
#     check; unlike a createdAt cutoff this can never reap a job that queued
#     for an hour and only just started).
# A job with no .state.lastRunAtMs (never run), or one that is currently
# running, is NEVER deleted here, regardless of age -- it is logged instead
# so a stuck job is visible without being silently reaped.
#
# --all: bare `cron list` hides disabled rows. If the response is paginated
# (hasMore==true) the durable set is unobtainable -- no pagination flags exist on
# this build -- so the sweep is skipped entirely rather than acting on a partial
# list. Best-effort throughout -- never fail dispatch over cleanup.
stale_cutoff_ms=$(( ($(date -u +%s) - 1800) * 1000 ))
cron_json="$("$OPENCLAW" ${OPENCLAW_ARGS[@]+"${OPENCLAW_ARGS[@]}"} cron list --all --json 2>/dev/null || true)"

if echo "$cron_json" | jq -e '.hasMore == true' >/dev/null 2>&1; then
  echo "qa-dispatch-pr-review: stale sweep skipped -- cron list is paginated (hasMore=true), durable set unobtainable" >&2
else
  # jq traps: has("lastRunAtMs") for presence (the `//` operator treats a `false`
  # value as null and would misclassify); `| numbers` guards the comparison (jq
  # sorts strings ABOVE numbers, so a non-numeric field would compare > cutoff as
  # true). A compile error exits with rc>0 with no -e flag in play, so a nonzero
  # jq_rc here means jq broke, not "no matches" (an empty match set is rc 0).
  if stale_ids="$(echo "$cron_json" | jq -r --argjson c "$stale_cutoff_ms" '
        .jobs[]? | select((.name // "") | startswith("qa-autoreview-pr-"))
                 | select((.state // {}) | has("lastRunAtMs"))
                 | select((.state // {}) | has("runningAtMs") | not)
                 | select(.status != "running")
                 | select((.state.lastRunAtMs | numbers) < $c)
                 | .id' 2>/dev/null)"; then
    jq_rc=0
  else
    jq_rc=$?
  fi

  if [ "$jq_rc" -ne 0 ]; then
    echo "qa-dispatch-pr-review: stale sweep skipped -- jq failed parsing cron list (rc=$jq_rc)" >&2
  else
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      "$OPENCLAW" ${OPENCLAW_ARGS[@]+"${OPENCLAW_ARGS[@]}"} cron rm "$id" >/dev/null 2>&1 || true
    done <<< "$stale_ids"

    if never_run_names="$(echo "$cron_json" | jq -r '
          .jobs[]? | select((.name // "") | startswith("qa-autoreview-pr-"))
                   | select(((.state // {}) | has("lastRunAtMs") | not))
                   | .name' 2>/dev/null)"; then
      while IFS= read -r name; do
        [ -n "$name" ] || continue
        echo "qa-dispatch-pr-review: leaving never-completed qa-autoreview job in place (no .state.lastRunAtMs): $name" >&2
      done <<< "$never_run_names"
    fi
  fi
fi

# Fire-and-forget one-shot. --delete-after-run cleans up on success.
#
# --no-deliver: the skill owns ALL Slack delivery (opening + threaded result DM to
# the author via qa-slack-dm.sh, posted with explicit targets mid-turn), so the cron
# must NOT also deliver its final assistant text. Omitting --announce is NOT enough:
# the runner's fallback delivery is on by default and tries to deliver to chat "last",
# which an isolated cron has no concept of -> the turn ends in
# `outcome=error error="Delivering to Slack requires target ..."` ~26-30x/day and the
# failed one-shot is never --delete-after-run'd. --no-deliver disables that fallback
# (the CLI equivalent of a `"mode": "none"` job). Verified: openclaw 2026.5.27.
# Transport-failure signatures that mean the request never reached the gateway.
# The ONE list; matched fixed-string + case-insensitive against openclaw's stderr.
# ECONNRESET / socket hang up / fetch failed are in it because they are transport
# failures, but they are NOT proof the request was never received: the socket can
# die after the request was written and the one-shot created. They are therefore
# classified here (exit 75) and deliberately absent from RETRYABLE_SIGNATURES.
PRE_GATEWAY_SIGNATURES=(
  "Opening handshake has timed out"
  "ECONNREFUSED"
  "ECONNRESET"
  "connect ETIMEDOUT"
  "socket hang up"
  "fetch failed"
  # 2026-10-28 (T9): a remote gateway adds DNS and routing failures to the class.
  "ENOTFOUND"
  "EHOSTUNREACH"
  "ENETUNREACH"
  "EAI_AGAIN"
)

# The subset that PROVES the connection was never established, so no one-shot
# can exist and a retry cannot duplicate one. Every entry is a connect/handshake
# failure; nothing here can be produced after a request was accepted.
RETRYABLE_SIGNATURES=(
  "Opening handshake has timed out"
  "ECONNREFUSED"
  "connect ETIMEDOUT"
  "ENOTFOUND"
  "EHOSTUNREACH"
  "ENETUNREACH"
  "EAI_AGAIN"
)

# transport_signature <stderr-file> [retryable] -- echoes the first matching
# signature, rc 1 if none. With "retryable", only the provably pre-gateway
# subset is considered.
transport_signature() {
  local sig list
  if [ "${2:-}" = "retryable" ]; then
    list=("${RETRYABLE_SIGNATURES[@]}")
  else
    list=("${PRE_GATEWAY_SIGNATURES[@]}")
  fi
  for sig in "${list[@]}"; do
    if grep -Fqi -- "$sig" "$1"; then printf '%s' "$sig"; return 0; fi
  done
  return 1
}

# Bounded in-place retry on a transport failure (header: "A transport failure is
# retried IN PLACE"). Malformed overrides fall back to the defaults rather than
# aborting under set -u/-e before the dispatch.
max_attempts="${QA_DISPATCH_TRANSPORT_ATTEMPTS:-3}"
[[ "$max_attempts" =~ ^[1-9][0-9]*$ ]] || max_attempts=3
read -r -a backoffs <<<"${QA_DISPATCH_RETRY_BACKOFF_S:-10 30}"
[ "${#backoffs[@]}" -gt 0 ] || backoffs=(10 30)
for b in "${backoffs[@]}"; do [[ "$b" =~ ^[0-9]+$ ]] || { backoffs=(10 30); break; }; done

add_err="$(mktemp)"
# The EXIT trap that removes this file is installed at the top of the script,
# above every branch that can exit. Do not add a second one here.
attempt=0
last_sig=""
while :; do
  attempt=$((attempt + 1))
  add_rc=0
  : >"$add_err"
  "$OPENCLAW" ${OPENCLAW_ARGS[@]+"${OPENCLAW_ARGS[@]}"} cron add \
    --name "$job_name" \
    --at "+5s" \
    --agent "$AGENT" \
    --session isolated \
    --message "$message" \
    --timeout-seconds "$TIMEOUT_SECONDS" \
    --no-deliver \
    --delete-after-run \
    --json 2>"$add_err" || add_rc=$?
  # Re-emit verbatim: classification must never swallow the diagnostic.
  cat "$add_err" >&2
  [ "$add_rc" -ne 0 ] || break
  # Not a transport failure: the gateway answered and rejected it. A real
  # attempt -- openclaw's own rc, no retry.
  last_sig="$(transport_signature "$add_err")" || exit "$add_rc"
  # Ambiguous: the request may have been received before the socket died, so a
  # retry could mint a SECOND one-shot for this PR (two concurrent reviews, two
  # DMs, a second qa-review status). Not retried; the reconciler re-dispatches.
  if ! transport_signature "$add_err" retryable >/dev/null; then
    echo "qa-dispatch-pr-review: gateway transport failure ('$last_sig') is ambiguous -- the request may have been received, so it is NOT retried; exiting 75 (not an attempt)." >&2
    exit 75
  fi
  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "qa-dispatch-pr-review: gateway unreachable ('$last_sig') after ${attempt}/${max_attempts} attempts -- no review queued; exiting 75 (not an attempt)." >&2
    exit 75
  fi
  idx=$((attempt - 1)); [ "$idx" -lt "${#backoffs[@]}" ] || idx=$(( ${#backoffs[@]} - 1 ))
  delay="${backoffs[$idx]}"
  echo "qa-dispatch-pr-review: gateway unreachable ('$last_sig') on attempt ${attempt}/${max_attempts} -- no review queued yet; retrying in ${delay}s." >&2
  sleep "$delay"
done

if [ "$attempt" -gt 1 ]; then
  echo "qa-dispatch-pr-review: dispatched auto-review of ${REPO}#${pr} (${sha}) -> agent ${AGENT} (${GATEWAY_TARGET}) on attempt ${attempt}/${max_attempts} (earlier attempts: gateway unreachable '${last_sig}')."
else
  echo "qa-dispatch-pr-review: dispatched auto-review of ${REPO}#${pr} (${sha}) -> agent ${AGENT} (${GATEWAY_TARGET})."
fi
