#!/usr/bin/env bash
# qa-worker.sh — one QA review lane. Claims jobs from the broker and runs them.
# =============================================================================
# A worker pod runs THIS script as its main process. It loops forever:
#
#   claim a job  ->  run the review  ->  record the verdict  ->  repeat
#
# Scaling is therefore just "how many copies of this script are running": four
# pods = four concurrent reviews. The pod owns a local openclaw gateway
# (pods/qa-review-gateway/entrypoint.sh) with only the `qa` agent, so the review
# runs in-process with no network hop to node-8.
#
# Why a loop and not one job per pod
# ----------------------------------
# A review takes p50 ~130 s. A pod that exited after one review would pay a
# gateway boot (~20-40 s: config validate, doctor, codex import) per review, and
# KEDA would be starting pods constantly. A long-lived loop keeps the expensive
# warm state and makes queue depth the only scaling signal. Pod shutdown is a
# SIGTERM mid-loop: the in-flight review is left to its lease, which the broker's
# reaper returns to the queue — no review is lost when a pod is scaled down.
#
# What "the verdict" means here
# -----------------------------
# The review skill posts its own `qa-review` commit status on the head sha (that
# is the merge gate). The worker does not re-post it — it READS it after the
# turn, because the broker needs to know the outcome to decide dedupe:
#   success                     -> go            (terminal: never review twice)
#   failure, "CANNOT REVIEW: *" -> cannot_review (retryable, capped)
#   failure (anything else)     -> no_go         (retryable, capped)
#   nothing posted              -> unknown       (retryable, capped)
# Reading the real status rather than parsing the agent's stdout keeps the two
# paths honest: whatever the skill published is what the broker records, so a
# re-review decision can never be based on a guessed verdict.
#
# Exit codes: the loop itself runs until killed. A single job's failure is
# recorded on the broker (never fatal to the pod) unless it is fatal
# configuration, which exits 1 so the pod CrashLoops visibly:
#   0  pod was asked to stop (SIGTERM handled between jobs)
#   1  fatal misconfiguration (no broker, no openclaw, bad env)
#
# Env:
#   QA_BROKER_URL            default http://qa-broker.hydra-qa.svc.cluster.local:8080
#                            set to "cli" to call scripts/lib/qa_broker.py directly
#                            against a mounted QA_QUEUE_DB (single-replica deployments)
#   QA_WORKER_ID             default <hostname>-<pid>; the lease owner name
#   QA_WORKER_MODEL          optional model override for the review turn
#   QA_REVIEW_TIMEOUT_S      default 1200 (the skill's own turn timeout)
#   QA_WORKER_POLL_S         default 5 — idle sleep between empty claims
#   QA_WORKER_LEASE_S        default 1500 — lease length, above the turn timeout
#   QA_WORKER_HEARTBEAT_S    default 120 — lease renewal while a review runs
#   QA_WORKER_MAX_JOBS       default 0 (unlimited) — stop after N jobs, for tests
#   QA_WORKER_ONCE           1 = claim at most one job then exit (tests/drills)
#   QA_WORKER_GH_BUDGET      1 (default) = refuse to claim when the shared GitHub
#                            REST budget is below QA_GH_BUDGET_FLOOR or unknown
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[qa-worker $(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&2; }
die() { log "FATAL: $*"; exit 1; }

QA_BROKER_URL="${QA_BROKER_URL:-http://qa-broker.hydra-qa.svc.cluster.local:8080}"
# The default ID must never be reused by a LATER process. `<hostname>-<pid>` can
# be: a container restarted in the same pod comes back with the same hostname,
# and PIDs are recycled. A reused ID is not cosmetic — an unscoped heartbeat
# renews every running row owned by that ID, so the replacement would keep the
# ABANDONED row's lease alive forever and the reaper would never requeue it.
# The random suffix makes reuse implausible; the per-job heartbeat below makes
# it harmless even if it happens.
QA_WORKER_ID="${QA_WORKER_ID:-$(hostname 2>/dev/null || echo pod)-$$-$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || echo 0)}"
QA_REVIEW_TIMEOUT_S="${QA_REVIEW_TIMEOUT_S:-1200}"
QA_WORKER_POLL_S="${QA_WORKER_POLL_S:-5}"
QA_WORKER_LEASE_S="${QA_WORKER_LEASE_S:-1500}"
QA_WORKER_HEARTBEAT_S="${QA_WORKER_HEARTBEAT_S:-120}"
QA_WORKER_MAX_JOBS="${QA_WORKER_MAX_JOBS:-0}"
# Seconds to wait between re-reads of the qa-review status when a turn exits 0
# without publishing one. The status is posted by the skill, so a turn can
# return a moment before the API reflects it; 3 x 5s is enough to tell a race
# from a turn that genuinely published nothing.
QA_WORKER_VERDICT_GRACE_S="${QA_WORKER_VERDICT_GRACE_S:-5}"
QA_WORKER_ONCE="${QA_WORKER_ONCE:-0}"
QA_WORKER_GH_BUDGET="${QA_WORKER_GH_BUDGET:-1}"
OPENCLAW="${OPENCLAW:-openclaw}"
QA_GH="${QA_GH:-$HERE/qa-gh.sh}"
BROKER_PY="${QA_BROKER_SCRIPT:-$HERE/lib/qa_broker.py}"

# The worker sends the same instruction text the cron path sends. The library is
# shared so a future edit cannot make the two paths review differently.
# shellcheck source=lib/qa-review-prompt.sh
source "$HERE/lib/qa-review-prompt.sh"

# ── broker client ───────────────────────────────────────────────────────────
# Two transports, one contract. "http" talks to the broker Service; "cli" runs
# the same python module against a mounted database. Both return the broker's
# JSON on stdout and its logical rc (0 ok, 1 empty, 2 usage, 75 unreachable,
# 76 duplicate).
#
# The rc travels through a FILE, not a shell variable: every caller invokes
# broker_call inside `$(...)`, which is a subshell, so a variable assigned in
# there is discarded on return. That bug made an empty claim look like rc 0 and
# spun the worker forever on "claim returned rc 0 but no job id".
BROKER_RC_FILE="$(mktemp)"
broker_rc() { cat "$BROKER_RC_FILE" 2>/dev/null || echo 2; }
# json_to_cli_args <endpoint> <json>
# The python module's CLI is the single implementation; the HTTP service is a
# wrapper around the same calls. Mapping the worker's JSON body onto the CLI's
# argv means "cli" mode exercises exactly the code path the dispatcher uses.
json_to_cli_args() {  # <endpoint> <json>
  python3 -c '
import json, sys
endpoint, raw = sys.argv[1], sys.argv[2]
try: d = json.loads(raw) if raw else {}
except Exception: d = {}
if not isinstance(d, dict): d = {}
def g(k, default=None):
    v = d.get(k, default)
    return "" if v is None else v
if endpoint == "claim":
    print("claim"); print(g("worker")); print("--lease"); print(g("lease"))
elif endpoint == "heartbeat":
    # --job-id is not optional: an unscoped renewal also revives an abandoned
    # row owned by a reused worker id, so the reaper would never requeue it.
    print("heartbeat"); print(g("worker")); print("--lease"); print(g("lease"))
    if d.get("job_id") is not None:
        print("--job-id"); print(g("job_id"))
elif endpoint == "finish":
    print("finish"); print(g("id")); print(g("worker")); print(g("verdict"))
elif endpoint == "abandon":
    print("abandon"); print(g("id")); print(g("worker")); print(g("reason"))
elif endpoint == "fail":
    print("fail"); print(g("id")); print(g("worker")); print(g("rc")); print(g("class")); print(g("message"))
elif endpoint == "reap":
    print("reap"); print("--grace"); print(g("grace"))
elif endpoint == "stats":
    print("stats")
else:
    print(endpoint)
' "$1" "$2"
}

broker_call() {  # <endpoint> [json-body]
  local what="$1" body="${2:-}"
  local rcfile="${BROKER_RC_FILE:-/dev/null}"
  local out rc=0
  if [ "$QA_BROKER_URL" = "cli" ]; then
    # Build argv from the JSON body so both transports hit the same logic.
    local -a argv
    mapfile -t argv < <(json_to_cli_args "$what" "$body")
    out="$(python3 "$BROKER_PY" --db "${QA_QUEUE_DB:-/var/lib/hydra-qa/queue.sqlite}" \
      "${argv[@]}" 2>/dev/null)" || rc=$?
    printf '%s' "$rc" >"$rcfile"
    printf '%s' "$out"
    return 0
  fi
  local url="${QA_BROKER_URL%/}/$what"
  # -w writes the HTTP status on its own line after the body. Without it a
  # proxy's bodyless 502 makes curl exit 0 and the empty body reads as "nothing
  # to claim" (rc 1): every reviewer then treats an unavailable broker as an
  # idle queue while accepted jobs wait. A JSON 502 without `rc` was worse — it
  # defaulted to rc 0 and the worker looped on a missing job id.
  # The broker refuses mutations without its shared token (an unauthenticated
  # /finish could record a `go` for a PR nobody reviewed). Sent on every call;
  # harmless on the read-only endpoints.
  local -a auth=()
  [ -n "${QA_BROKER_TOKEN:-}" ] && auth=(-H "X-QA-Broker-Token: $QA_BROKER_TOKEN")
  if [ -n "$body" ]; then
    out="$(curl -sS --max-time 20 -X POST "$url" \
      -H 'Content-Type: application/json' "${auth[@]}" -d "$body" -w '\n%{http_code}' 2>/dev/null)" || rc=$?
  else
    out="$(curl -sS --max-time 20 "$url" "${auth[@]}" -w '\n%{http_code}' 2>/dev/null)" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    # curl failed: the broker is unreachable. Report a transport failure so the
    # caller does not mistake "no answer" for "queue empty".
    printf '%s' 75 >"$rcfile"
    return 0
  fi
  # The broker answers 409 for a duplicate, 200+rc:1 for an empty claim, and
  # 500+rc:3 for "up but broken". An explicit integer `rc` in the body is
  # therefore authoritative whatever the HTTP status, because the broker's own
  # contract uses the status to carry meaning. What must NOT be honoured is a
  # response with no rc: a proxy's 502 (bodyless or a JSON error page) is a
  # TRANSPORT failure (75), never "nothing to claim" and never a claim.
  #
  # An EMPTY body on a 2xx /claim is still "nothing to claim" (rc 1): a broker
  # that answers 204, or a proxy that strips the body, must not turn an idle
  # worker into a permanent error loop.
  printf '%s' "$(printf '%s' "$out" | python3 -c '
import json,sys
raw = sys.stdin.read()
body, _, code = raw.rpartition("\n")
try:
    http = int(code.strip())
except ValueError:
    print(75); raise SystemExit
d = None
if body.strip():
    try: d = json.loads(body)
    except Exception: d = None
if isinstance(d, dict) and "rc" in d:
    try: print(int(d["rc"]))
    except (TypeError, ValueError): print(2)
    raise SystemExit
if not (200 <= http < 300):
    print(75); raise SystemExit
if not body.strip():
    print(1 if sys.argv[1] == "claim" else 2); raise SystemExit
print(2)
' "$what" 2>/dev/null || echo 75)" >"$rcfile"
  # Strip the status line so callers still see a valid JSON body.
  printf '%s' "${out%$'\n'*}"
}

json_get() {  # <json> <key> — print a top-level scalar, empty if absent
  printf '%s' "$1" | python3 -c '
import json,sys
key=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
v=d.get(key) if isinstance(d, dict) else None
print("" if v is None else v)
' "$2" 2>/dev/null || true
}

# ── verdict from the real commit status ─────────────────────────────────────
# The skill posts `qa-review` on the head sha. Read the newest row for that
# context and map it. A read failure is "unknown", never "go": guessing a GO
# would mark an unreviewed commit as reviewed and let it merge.
#
# `after` is the newest qa-review created_at observed BEFORE this turn started.
# A forced re-review reopens the SAME key, so the previous verdict is still on
# the commit: without this filter a turn that exits 0 without publishing
# anything reads the OLD status, records it as this run's verdict, and consumes
# the re-review slot while the PR still has no fresh verdict. Comparing
# timestamps from GitHub against each other (not against our clock) keeps it
# immune to pod clock skew.
#
# The status must also come from the QA identity. `qa-review` is a public
# context: any actor with write access can post it, and a status posted by
# someone else after the baseline would be recorded as this turn's verdict,
# consuming the re-review slot with a verdict this reviewer never produced. The
# allowed logins are the same ones the approval policy already trusts.
QA_STATUS_IDENTITIES="${QA_STATUS_IDENTITIES:-muso-qa-bot,muso-qa-bot[bot],adk47}"

read_verdict() {  # <repo> <sha> [after_created_at]
  local repo="$1" sha="$2" after="${3:-}" json
  # --repo so the identity decision is made for THIS repo, exactly as the
  # review's own writes are. Unscoped, qa-gh.sh falls back to the host account
  # and the read measures a different identity than the review spends.
  json="$("$QA_GH" --repo "$repo" api "repos/${repo}/commits/${sha}/statuses?per_page=100" 2>/dev/null)" || {
    echo "unknown"; return 0
  }
  printf '%s' "$json" | python3 -c '
import json,sys
after = sys.argv[1] if len(sys.argv) > 1 else ""
try: rows=json.load(sys.stdin)
except Exception: print("unknown"); raise SystemExit
rows=[r for r in rows if isinstance(r,dict) and r.get("context")=="qa-review"]
allowed = [x for x in (sys.argv[2] if len(sys.argv) > 2 else "").split(",") if x]
if allowed:
    rows=[r for r in rows
          if ((r.get("creator") or {}).get("login") or "") in allowed]
if after:
    rows=[r for r in rows if (r.get("created_at") or "") > after]
if not rows: print("unknown"); raise SystemExit
# newest first by created_at; GitHub already orders newest first, but be explicit.
rows.sort(key=lambda r: r.get("created_at") or "", reverse=True)
r=rows[0]
state=(r.get("state") or "").lower()
desc=(r.get("description") or "")
if state=="success": print("go")
elif state=="failure":
    print("cannot_review" if desc.startswith("CANNOT REVIEW") else "no_go")
else: print("unknown")
' "$after" "$QA_STATUS_IDENTITIES" 2>/dev/null || echo "unknown"
}

# The newest qa-review created_at on the commit, or empty. Taken BEFORE a turn
# so read_verdict can tell "this turn published a status" from "an older status
# is still sitting there".
# The pre-turn baseline. An EMPTY baseline is a legitimate answer (the commit
# has no qa-review status yet), but a FAILED READ is not: `read_verdict` skips
# its `after` filter when the baseline is empty, so a transient GET failure
# would let a forced re-review that published nothing read the previous NO-GO
# and finish, consuming the re-review slot. The two cases are therefore
# distinguished by exit status, and the caller refuses to run a turn it cannot
# attribute rather than guessing.
newest_status_at() {  # <repo> <sha> — prints the newest created_at, rc 1 on read failure
  local repo="$1" sha="$2" json
  json="$("$QA_GH" --repo "$repo" api "repos/${repo}/commits/${sha}/statuses?per_page=100" 2>/dev/null)" || return 1
  printf '%s' "$json" | python3 -c '
import json,sys
try: rows=json.load(sys.stdin)
except Exception: raise SystemExit(1)
if not isinstance(rows, list): raise SystemExit(1)
rows=[r for r in rows if isinstance(r,dict) and r.get("context")=="qa-review"]
print(max((r.get("created_at") or "" for r in rows), default=""))
' 2>/dev/null
}

# The PR's current head, or empty when it cannot be read. Used to tell "this
# turn published nothing" from "this turn reviewed a DIFFERENT head".
current_head() {  # <repo> <pr>
  local repo="$1" pr="$2"
  "$QA_GH" --repo "$repo" api "repos/${repo}/pulls/${pr}" --jq .head.sha 2>/dev/null \
    | tr -d '[:space:]'
}

# ── one review turn ─────────────────────────────────────────────────────────
# Runs the agent synchronously against the pod's own gateway. --no-deliver: the
# skill owns all Slack delivery (same reason as the cron path's --no-deliver).
run_review() {  # <repo> <pr> <sha> <uid>
  local repo="$1" pr="$2" sha="$3" uid="$4" prompt rc=0
  prompt="$(qa_review_prompt "$repo" "$pr" "$sha" "$uid")"
  # `--session-id`, NOT `--session`: the installed CLI has no `--session` option
  # and rejects the whole invocation ("OpenClaw does not recognize option
  # \"--session\""), so every claimed job died before the agent started and was
  # dead-lettered with no verdict. A fresh id per job is what gives the review
  # its own isolated session; the same form is used by
  # scripts/lib/websearch-probe.sh, which is the live-verified reference.
  local session_id
  session_id="qa-review-${repo//\//-}-${pr}-${sha:0:7}-$(date +%s)-$$"
  local args=(agent --agent qa --session-id "$session_id"
              --timeout "$QA_REVIEW_TIMEOUT_S" --json --message "$prompt")
  [ -n "${QA_WORKER_MODEL:-}" ] && args+=(--model "$QA_WORKER_MODEL")
  # A local gateway in the same pod needs no --profile: the pod's state dir IS
  # the qa profile (entrypoint.sh installs openclaw-qa.json and unsets overrides).
  timeout $((QA_REVIEW_TIMEOUT_S + 60)) "$OPENCLAW" "${args[@]}" >/dev/null 2>"$WORKER_ERR" || rc=$?
  RUN_RC="$rc"
}

classify_failure() {  # <rc> <stderr-file>
  local rc="$1" err="$2"
  # The transport signatures the dispatcher already uses; one list, same meaning.
  local sigs=("Opening handshake has timed out" "ECONNREFUSED" "ECONNRESET"
              "connect ETIMEDOUT" "socket hang up" "fetch failed"
              "ENOTFOUND" "EHOSTUNREACH" "ENETUNREACH" "EAI_AGAIN")
  local s
  for s in "${sigs[@]}"; do
    grep -Fqi -- "$s" "$err" 2>/dev/null && { echo "transport"; return 0; }
  done
  # Quota: 429s and explicit cap messages. These must not count as review
  # failures — the review did not happen because we were rate limited.
  grep -Fqi -e "429" -e "rate limit" -e "quota" -e "usage cap" "$err" 2>/dev/null \
    && { echo "quota"; return 0; }
  # A timeout from the outer `timeout` command means the turn hung.
  [ "$rc" -eq 124 ] && { echo "transport"; return 0; }
  echo "review"
}

# ── heartbeat ───────────────────────────────────────────────────────────────
# While a review runs, renew the lease so the reaper does not requeue a healthy
# review. Runs in the background; stopped when the turn ends.
#
# Two details that are load-bearing:
#  * The wait is a 1s tick against HB_STOP, NOT one long `sleep $INTERVAL`. A
#    `kill` of the subshell does not kill a `sleep` it is blocked in, so the
#    orphaned sleep would (a) keep the caller's stdout/stderr open — which hangs
#    any `$(...)`/bats capture for the whole interval — and (b) let one more
#    heartbeat fire AFTER the job finished, renewing a lease the worker no
#    longer owns.
#  * Its own fds go to /dev/null so the loop can never hold a caller's pipe.
HB_STOP=0
HB_RC_FILE="$(mktemp)"
# Renews the lease for ONE job. The job id is not optional: an unscoped renewal
# covers every running row owned by this worker id, so a restarted process that
# reused the id would keep an abandoned row alive and the reaper would never
# requeue that PR.
heartbeat_loop() {
  local waited=0
  BROKER_RC_FILE="$HB_RC_FILE"
  while [ "$HB_STOP" -eq 0 ]; do
    sleep 1
    waited=$((waited + 1))
    [ "$waited" -ge "$QA_WORKER_HEARTBEAT_S" ] || continue
    waited=0
    [ "$HB_STOP" -eq 0 ] || break
    broker_call heartbeat "{\"worker\":\"$QA_WORKER_ID\",\"lease\":$QA_WORKER_LEASE_S,\"job_id\":${HB_JOB_ID:-0}}" >/dev/null 2>&1
  done
}

# ── the loop ────────────────────────────────────────────────────────────────
WORKER_ERR="$(mktemp)"
trap 'rm -f "$WORKER_ERR" "$BROKER_RC_FILE" "$HB_RC_FILE"' EXIT
STOP=0
trap 'STOP=1; log "SIGTERM received — finishing the current job, then exiting"' TERM INT

command -v python3 >/dev/null 2>&1 || die "python3 not found"
command -v "$OPENCLAW" >/dev/null 2>&1 || die "openclaw not found on PATH"
if [ "$QA_BROKER_URL" != "cli" ]; then
  command -v curl >/dev/null 2>&1 || die "curl not found on PATH (needed for the broker HTTP API)"
fi

log "worker $QA_WORKER_ID starting; broker=$QA_BROKER_URL lease=${QA_WORKER_LEASE_S}s timeout=${QA_REVIEW_TIMEOUT_S}s"

jobs_done=0
while [ "$STOP" -eq 0 ]; do
  # GitHub REST budget gate. Every review spends calls under ONE App
  # installation, so N workers share one budget; claiming a job we cannot
  # finish would burn a review slot and end in a false CANNOT REVIEW. Below the
  # floor we idle (the job stays queued for a worker that can serve it) and
  # never claim. A probe failure is "unknown", not "fine".
  if [ "$QA_WORKER_GH_BUDGET" = "1" ]; then
    budget_state="$("$HERE/lib/qa-gh-budget.sh" check 2>/dev/null)"
    case "$budget_state" in
      ok:*) : ;;
      low:*)
        log "github REST budget ${budget_state#low:} below floor — not claiming; sleeping ${QA_WORKER_POLL_S}s"
        # A one-shot worker has nothing to wait for: exit rather than spin.
        [ "$QA_WORKER_ONCE" = "1" ] && break
        sleep "$QA_WORKER_POLL_S"
        continue
        ;;
      *)
        log "github REST budget unknown — not claiming; sleeping ${QA_WORKER_POLL_S}s"
        [ "$QA_WORKER_ONCE" = "1" ] && break
        sleep "$QA_WORKER_POLL_S"
        continue
        ;;
    esac
  fi

  # Claim. An empty claim (rc 1) is the normal idle case; a transport failure
  # (rc 75) means the broker is down, which we retry with backoff rather than
  # exiting — a broker restart must not kill every worker.
  claim_json="$(broker_call claim "{\"worker\":\"$QA_WORKER_ID\",\"lease\":$QA_WORKER_LEASE_S}")"
  BROKER_RC="$(broker_rc)"
  case "$BROKER_RC" in
    0)
      # Claimed. Parse the job; a malformed payload is a broker bug, not ours.
      job_id="$(json_get "$claim_json" id)"
      [ -n "$job_id" ] || { log "claim returned rc 0 but no job id: $claim_json"; sleep "$QA_WORKER_POLL_S"; continue; }
      repo="$(json_get "$claim_json" repo)"
      pr="$(json_get "$claim_json" pr)"
      sha="$(json_get "$claim_json" head_sha)"
      uid="$(json_get "$claim_json" requester_uid)"
      log "claimed job $job_id ${repo}#${pr}@${sha:0:7} (attempt $(json_get "$claim_json" attempts))"

      # Heartbeat in the background for the duration of the turn, scoped to
      # THIS job so a reused worker id cannot revive an abandoned row.
      HB_STOP=0
      HB_JOB_ID="$job_id"
      heartbeat_loop >/dev/null 2>&1 &
      hb_pid=$!

      # Baseline BEFORE the turn: the newest qa-review status already on the
      # commit. A forced re-review reopens the same key, so the previous verdict
      # is still there and must not be mistaken for this run's.
      if ! status_baseline="$(newest_status_at "$repo" "$sha")"; then
        # Without a baseline this turn's verdict cannot be attributed, and an
        # unattributable verdict is how a forced re-review silently finishes on
        # the previous NO-GO. Requeue instead: the review has not run yet, so
        # nothing is lost and the retry is cheap.
        log "job $job_id cannot read the qa-review baseline for ${repo}#${pr}@${sha:0:7}; requeueing"
        # Stop the heartbeat before leaving: it was started above, and a
        # `continue` that skipped this cleanup left an orphaned loop holding the
        # output pipe (which hangs a one-shot worker and its test harness).
        HB_STOP=1
        kill "$hb_pid" 2>/dev/null || true
        wait "$hb_pid" 2>/dev/null || true
        res="$(broker_call fail "{\"id\":$job_id,\"worker\":\"$QA_WORKER_ID\",\"rc\":0,\"class\":\"transport\",\"message\":\"could not read the pre-turn qa-review status baseline\"}")"
        BROKER_RC="$(broker_rc)"
        log "job $job_id baseline-unreadable -> $(json_get "$res" status) (rc=$BROKER_RC)"
        continue
      fi

      RUN_RC=0
      run_review "$repo" "$pr" "$sha" "$uid"

      HB_STOP=1
      kill "$hb_pid" 2>/dev/null || true
      wait "$hb_pid" 2>/dev/null || true

      if [ "$RUN_RC" -eq 0 ]; then
        verdict="$(read_verdict "$repo" "$sha" "$status_baseline")"
        # A turn that exits 0 but published NO qa-review status is not a review.
        # Recording it as `done` would make the row terminal with no verdict on
        # the PR: the repos read the status, not the broker, so the PR would sit
        # unreviewed forever and nothing would retry it. That is exactly the
        # silent drop this queue exists to prevent, so it is a FAILURE.
        #
        # Re-read first: the status is posted by the skill, and a turn can return
        # a moment before the API reflects it. Only after the grace window is a
        # missing status real.
        if [ "$verdict" = "unknown" ]; then
          for _ in 1 2 3; do
            sleep "$QA_WORKER_VERDICT_GRACE_S"
            verdict="$(read_verdict "$repo" "$sha" "$status_baseline")"
            [ "$verdict" = "unknown" ] || break
          done
        fi
        if [ "$verdict" = "unknown" ]; then
          # Before calling this a failure, check whether the head MOVED while we
          # were reviewing. The skill resolves the PR's head itself, so a turn
          # that started on A and finished after B was pushed reviewed B and
          # published its status on B. This job only ever looks at A, so the
          # successful turn reads as `unknown`; retrying would re-review B,
          # spend a review attempt, and eventually dead-letter a PR that is in
          # fact being reviewed. A dispatch for B is already on its way, so the
          # honest outcome is to retire this job as superseded.
          head_now="$(current_head "$repo" "$pr")"
          if [ -n "$head_now" ] && [ "$head_now" != "$sha" ]; then
            log "job $job_id head moved ${sha:0:7} -> ${head_now:0:7} during the review; retiring as superseded (the turn reviewed the newer head)"
            res="$(broker_call abandon "{\"id\":$job_id,\"worker\":\"$QA_WORKER_ID\",\"reason\":\"head moved to ${head_now:0:7} during the review\"}")"
            BROKER_RC="$(broker_rc)"
            log "job $job_id head-moved -> $(json_get "$res" status) (rc=$BROKER_RC)"
            continue
          fi
          log "job $job_id turn exited 0 but published no qa-review status for ${repo}#${pr}@${sha:0:7}; requeueing"
          res="$(broker_call fail "{\"id\":$job_id,\"worker\":\"$QA_WORKER_ID\",\"rc\":0,\"class\":\"review\",\"message\":\"review turn completed but published no qa-review status\"}")"
          BROKER_RC="$(broker_rc)"
          log "job $job_id no-verdict -> $(json_get "$res" status) (rc=$BROKER_RC)"
        else
          # The review turn completed and published a status. Record it. A GO is
          # terminal; anything else stays retryable under the broker's cap.
          res="$(broker_call finish "{\"id\":$job_id,\"worker\":\"$QA_WORKER_ID\",\"verdict\":\"$verdict\"}")"
          BROKER_RC="$(broker_rc)"
          if [ "$BROKER_RC" -eq 0 ]; then
            log "job $job_id finished verdict=$verdict"
          else
            # Could not record the verdict: the lease will expire and the reaper
            # will requeue. That re-reviews a completed PR once, which is wasteful
            # but never loses the review — the safe direction.
            log "job $job_id completed verdict=$verdict but the broker refused the record (rc=$BROKER_RC): $res"
          fi
        fi
      else
        cls="$(classify_failure "$RUN_RC" "$WORKER_ERR")"
        # Truncate the message: the broker stores it and a runaway stderr would
        # bloat the row. Keep the tail, where the actual error usually is.
        msg="$(tail -c 500 "$WORKER_ERR" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')"
        res="$(broker_call fail "{\"id\":$job_id,\"worker\":\"$QA_WORKER_ID\",\"rc\":$RUN_RC,\"class\":\"$cls\",\"message\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$msg")}")"
        BROKER_RC="$(broker_rc)"
        log "job $job_id failed rc=$RUN_RC class=$cls -> $(json_get "$res" status)"
        # A transport/quota failure means the review did not run: the broker
        # requeues it with the matching backoff. A review failure is also
        # requeued, capped, then dead-lettered for a human.
        [ "$BROKER_RC" -eq 0 ] || log "job $job_id failure not recorded (rc=$BROKER_RC): $res"
      fi

      jobs_done=$((jobs_done + 1))
      [ "$QA_WORKER_ONCE" = "1" ] && { log "QA_WORKER_ONCE=1 — exiting after one job"; break; }
      [ "$QA_WORKER_MAX_JOBS" -gt 0 ] && [ "$jobs_done" -ge "$QA_WORKER_MAX_JOBS" ] && {
        log "QA_WORKER_MAX_JOBS=$QA_WORKER_MAX_JOBS reached — exiting"; break; }
      # Loop immediately: if the queue has depth, do not sleep.
      continue
      ;;
    1)
      # Empty queue: nothing to do. Sleep a little and ask again — unless this
      # worker was asked to run at most one job (tests/drills), in which case an
      # empty queue is a clean stop, not a reason to spin forever.
      [ "$QA_WORKER_ONCE" = "1" ] && { log "QA_WORKER_ONCE=1 — queue empty, exiting"; break; }
      sleep "$QA_WORKER_POLL_S"
      ;;
    75)
      # Broker unreachable. Back off so a broker restart does not spin. A
      # one-shot worker has nothing to wait for, so it exits instead of sleeping
      # forever (a test or a drill would otherwise hang for the whole backoff).
      log "broker unreachable — backing off 30s"
      [ "$QA_WORKER_ONCE" = "1" ] && { log "QA_WORKER_ONCE=1 — exiting on broker transport failure"; break; }
      sleep 30
      ;;
    3)
      # The broker answered but could not do its job (HTTP 500 / internal). This
      # is NOT an empty queue: accepted PRs are waiting and nobody is reviewing
      # them, so it must be loud and it must back off rather than hot-loop.
      log "broker INTERNAL ERROR (rc=3) — not an empty queue: $claim_json"
      [ "$QA_WORKER_ONCE" = "1" ] && { log "QA_WORKER_ONCE=1 — exiting on broker error"; break; }
      sleep 30
      ;;
    *)
      log "broker claim error (rc=$BROKER_RC): $claim_json"
      sleep "$QA_WORKER_POLL_S"
      ;;
  esac
done

log "worker $QA_WORKER_ID stopping after $jobs_done job(s)"
exit 0
