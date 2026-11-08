#!/usr/bin/env bash
# Phase 3 format + emit (deterministic). Joins ${WORKDIR}/emails.json (fetch,
# authoritative for counts/subjects/senders/links) with ${WORKDIR}/verdicts.json
# (LLM-authored verdict/description/reason) by threadId, prints a Slack mrkdwn
# digest to stdout, then scrubs $WORKDIR.
#
# Outcomes:
#   - 0 threads             -> prints exactly NO_REPLY (cron stays silent).
#   - >=1 thread            -> prints header + one bullet per thread (cap 25 +
#                              "...and N more" overflow).
#   - reconciliation failure -> exits non-zero with a clear message; NEVER emits
#                              a partial/fabricated digest (Rule 13, fail loud).
#
# Requires $WORKDIR exported by preflight.sh.

set -euo pipefail

: "${WORKDIR:?WORKDIR not set — source preflight.sh first}"
EMAILS="${WORKDIR}/emails.json"
VERDICTS="${WORKDIR}/verdicts.json"
# Written by scripts/gdpr-triage-bridge.py (Phase 2.5). OPTIONAL on purpose: the digest is the
# safety net, so a bridge that did not run must still produce a digest -- it just pages a human
# for every `human` verdict, exactly as before the bridge existed, and says so on stderr.
BRIDGE="${WORKDIR}/bridge.json"

[ -f "$EMAILS" ] || { echo "format-digest: ${EMAILS} missing (fetch did not run)" >&2; exit 1; }
[ -f "$VERDICTS" ] || { echo "format-digest: ${VERDICTS} missing (classify step did not write it)" >&2; exit 1; }

# Emit digest to stdout (or NO_REPLY) and reconcile. Python exits non-zero on any
# malformed/unreconcilable input so the agent re-derives verdicts rather than
# shipping a wrong digest.
# Scrub customer PII only on the success path (the trailing rm below).
# preflight's INT/TERM trap covers interrupt/timeout; on a reconciliation
# failure `set -e` exits here, leaving the fetch data in place for the agent
# to re-derive verdicts and re-run.
python3 - "$EMAILS" "$VERDICTS" "$BRIDGE" <<'PY'
import sys, json, re

emails_path, verdicts_path, bridge_path = sys.argv[1], sys.argv[2], sys.argv[3]
MAX_LINES = 25

def die(msg):
    print("format-digest: " + msg, file=sys.stderr)
    sys.exit(1)

try:
    with open(emails_path) as f:
        emails = json.load(f)
except (OSError, ValueError) as e:
    die("emails.json unreadable/malformed: %s" % e)

if not isinstance(emails, list):
    die("emails.json is not a JSON array")

# 0 threads -> silent.
if len(emails) == 0:
    print("NO_REPLY")
    sys.exit(0)

try:
    with open(verdicts_path) as f:
        verdicts = json.load(f)
except (OSError, ValueError) as e:
    die("verdicts.json unreadable/malformed: %s" % e)

if not isinstance(verdicts, list):
    die("verdicts.json is not a JSON array")

email_by_tid = {}
for e in emails:
    tid = e.get("threadId")
    if not tid:
        die("an emails.json entry is missing threadId")
    email_by_tid[tid] = e

verdict_by_tid = {}
for v in verdicts:
    tid = v.get("threadId")
    if not tid:
        die("a verdicts.json entry is missing threadId")
    if tid not in email_by_tid:
        die("verdicts.json references threadId %r not in emails.json (no fabricated rows)" % tid)
    vd = v.get("verdict")
    if vd not in ("caroline", "human", "spam"):
        die("verdicts.json threadId %r has invalid verdict %r (want caroline|human|spam)" % (tid, vd))
    verdict_by_tid[tid] = v

# Every email thread must have exactly one verdict.
missing = [t for t in email_by_tid if t not in verdict_by_tid]
if missing:
    die("%d thread(s) in emails.json have no verdict: %s" % (len(missing), ", ".join(missing[:5])))

def slack_escape(s):
    # Per scripts/close-resolved-conversations.py:_slack_escape — escape & < >
    # in that exact order so the & in the entities is not re-escaped.
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def no_emdash(s):
    # No em-dashes in the output (Caroline voice rule). Normalize em/en dash and
    # the horizontal-bar variants to a plain hyphen.
    return re.sub(r"[‒–—―]", "-", str(s))

# The GDPR bridge (scripts/gdpr-triage-bridge.py) resolves a `human` verdict that is really a
# privacy request: `registered` when the erasure register already holds the thread, `filed` when
# it just filed it. Those are NOT human pages -- the pipeline owns them and has its own due
# dates. `refused`, `not_privacy`, `withdrawn` and `escalated` keep the human page, and each carries its own
# words so the page names the reason instead of a generic "needs a human". `withdrawn` exists
# because a customer can cancel a request the register still holds open: the register has no
# cancellation transition, so only a human can stop the next action.
#
# A missing bridge file is not an error: every `human` verdict then stays a human page, which is
# the pre-bridge behaviour and the safe direction. It is reported on stderr so a bridge that
# silently stopped running is visible rather than looking like a quiet hour.
bridge = {}
if bridge_path:
    try:
        with open(bridge_path) as f:
            loaded = json.load(f)
        if isinstance(loaded, dict) and isinstance(loaded.get("threads"), dict):
            bridge = loaded["threads"]
    except (OSError, ValueError):
        bridge = {}

RESOLVED = ("registered", "filed")

def bridge_outcome(tid):
    rec = bridge.get(tid)
    return rec if isinstance(rec, dict) else {}

n = len(emails)
n_caroline = sum(1 for v in verdict_by_tid.values() if v["verdict"] == "caroline")
n_spam = sum(1 for v in verdict_by_tid.values() if v["verdict"] == "spam")
n_resolved = sum(1 for tid, v in verdict_by_tid.items()
                if v["verdict"] == "human" and bridge_outcome(tid).get("outcome") in RESOLVED)
n_human = n - n_caroline - n_spam - n_resolved

# Emitted AFTER the digest, and only after stdout is flushed: callers that capture the two
# streams together (`run bash "$SCRIPT"` in the bats suite) read lines[0] as the header, so a
# warning written first would displace it. The warning is still stderr, never the digest body --
# the digest is what gets posted to Slack and its shape is a contract.
bridge_warning = ""
if n_human and not bridge:
    bridge_warning = ("format-digest: WARN %d human verdict(s) and no bridge.json -- the GDPR "
                      "bridge did not run, so every privacy request is paging a human" % n_human)

# Spam/no-action never counts as a Caroline win; only show its segment when
# there is spam so quiet hours stay glanceable.
header = (":envelope: *support@ triage* · last 1h · %d new · "
          "%d Caroline-can-handle · %d need a human") % (n, n_caroline, n_human)
if n_resolved:
    header += " · %d filed to the erasure register" % n_resolved
if n_spam:
    header += " · %d spam/no-action" % n_spam
lines = [no_emdash(header)]

# Preserve emails.json order (fetch order = newest-first).
ordered_tids = [e["threadId"] for e in emails]
for tid in ordered_tids[:MAX_LINES]:
    e = email_by_tid[tid]
    v = verdict_by_tid[tid]
    url = e.get("url") or ""
    subject = no_emdash(slack_escape(e.get("subject") or "(no subject)"))
    desc = no_emdash(slack_escape(v.get("description") or ""))
    reason = no_emdash(slack_escape(v.get("reason") or ""))
    if v["verdict"] == "caroline":
        tag = ":white_check_mark: Caroline-can-handle"
    elif v["verdict"] == "spam":
        tag = ":wastebasket: spam/no-action"
    else:
        rec = bridge_outcome(tid)
        outcome = rec.get("outcome")
        if outcome in RESOLVED:
            reg = rec.get("register_no") or ""
            tag = ":inbox_tray: erasure register #%s" % reg if reg else ":inbox_tray: erasure register"
            # The register's own next action, not a paraphrase: it is what the pipeline will do
            # and what a human would need to know if they did look.
            action = no_emdash(slack_escape(rec.get("action") or ""))
            if action:
                reason = action
        else:
            tag = ":raising_hand: needs a human"
            # A pipeline refusal names itself; anything else keeps the triage's own reason.
            if outcome in ("refused", "not_privacy", "withdrawn", "escalated") and rec.get("reason"):
                reason = no_emdash(slack_escape(rec["reason"]))
    link = "<%s|%s>" % (url, subject) if url else subject
    lines.append("• %s - %s · %s (%s)" % (link, desc, tag, reason))

if n > MAX_LINES:
    lines.append("...and %d more" % (n - MAX_LINES))

print("\n".join(lines))
sys.stdout.flush()
if bridge_warning:
    print(bridge_warning, file=sys.stderr)
    sys.stderr.flush()
PY

# SHADOW-ONLY Jev classification (docs/plans/jev-adoption.md Phase 2b,
# redesigned after coordinator QA review of PR #1008's fetch-time pre-pass).
# Called HERE, strictly after verdicts.json is known and the digest above
# has already printed to stdout -- Jev's judgment doesn't depend on when
# it's made, so there is no reason to compute it before the LLM's own
# verdict exists. That removes the prior design's two real findings by
# construction:
#   - no answer key for these threads exists anywhere, at any path, while
#     the agent is still classifying (nothing to read, root or not);
#   - each call's shadow row is written by jev.sh itself, in the SAME call
#     that produced it -- there is no separate file that can vanish (a full
#     disk, an unwritable dir) between "the call happened" and "the row got
#     recorded".
# --actual is passed as {"owner": <verdict>} (category stays unscored, same
# as the removed pre-pass, since verdicts.json carries no closed category).
#
# ONE WRITER, ONE ROW PER CALL, NO INFERENCE (QA on #1008, two more Important
# findings against the prior before/after-line-count design -- both real,
# so the mechanism was replaced rather than patched again):
#   1. jev.sh can return rc 0 with .answers present but have its OWN shadow
#      append fail regardless (unwritable dir, full disk). A caller-side
#      fallback keyed off "did the file grow" then has no way to see that:
#      it infers success (no fallback fires) and the row is simply never
#      written by anyone -- worse than the original gap, and invisible.
#   2. Two overlapping cron runs share one shadow file. Run B's append can
#      land between run A's before/after snapshots, so A sees the file grow
#      (from B's row, not its own), concludes "nothing to do", and A's own
#      call -- possibly a timeout -- is never recorded at all.
# Both are inherent to inferring a write from a line-count delta on a file
# shared across processes. The fix removes the inference entirely: jev.sh is
# now called WITH --no-shadow (it writes NOTHING to the shadow file itself,
# so there is nothing to race or misattribute), and THIS function is the
# single, sole writer of the email-triage shadow log. It builds exactly one
# row per call, always, in jev.sh's own field set (ts/surface/item_id/
# state_sha256/questions_sha256/model/answers/usage/latency_ms/actual/rc/
# http/provider, plus an extra `reason` field jev-shadow-report.sh's
# row_ok() ignores):
#   - rc 0 and jev.sh's stdout parses as a JSON object -> that object as
#     `answers`, rc 0.
#   - rc 0 but stdout is empty/unparseable -> NOT a success: rc 3 (jev.sh's
#     own code for "no .answers"), answers null, reason unparseable_answers.
#     A call with no usable answer must never look like a measured
#     agreement.
#   - any other rc (2/4/5/6, or 124/137 from the OS timeout backstop below)
#     -> that rc, answers null, reason os_timeout_kill for 124/137 only.
# state_sha256/questions_sha256 are computed here (sha256sum, falling back
# to shasum -a 256, exactly as jev.sh's own _jev_sha256 does) over the same
# files handed to jev.sh, since --no-shadow means jev.sh never computes or
# reports them back. model/usage/http are null: --no-shadow's stdout
# contract is the answers object only, so nothing here can know jev.sh's
# resolved model, token usage, or HTTP status without re-implementing its
# request path. provider mirrors jev.sh's own env-driven default
# (JEV_PROVIDER, else "openrouter") since that much IS known to the caller.
# latency_ms is measured here, the same way jev.sh measures its own (date
# +%s%N before/after the call).
#
# Each append is serialized with `flock -w 5` on a sibling `.lock` file next
# to the shadow file, so two overlapping runs can never interleave a partial
# line into each other's row (finding 2). This IS load-bearing, not
# defense-in-depth: O_APPEND only makes a single write(2) atomic, and bash's
# `printf` only issues a single write(2) for a short line -- past its stdio
# buffer (empirically well under 50KB is enough to split it into several
# write(2) calls, both on macOS and on node-8's Linux), those calls CAN
# interleave with another process's writes to the same fd, corrupting a
# line. jev.sh's answers object is normally small, but nothing bounds its
# size (a judge/model response is not under this script's control), so the
# lock covers the row at any size, not just the common case. Verified by the
# "flock guards a large row against interleaving" test below: with flock
# removed, parallel large-row writes corrupt reliably (measured 2-10 bad
# lines per 30 on both platforms); with it, 0 bad lines across repeated
# runs. flock is util-linux and present on node-8; if it is ever absent
# (e.g. a bare macOS dev box), the code falls back to a plain `>>` append --
# still safe for the common small-row case (one `printf` of a short JSONL
# line, well under any stdio split threshold, through an O_APPEND fd is a
# single atomic write), but not for a row large enough to split. Either way
# this never blocks the digest: a lock or append failure goes through the
# same logger + stderr-summary path as before.
#
# The support-timer (2a), prod-log-alert (2c) and Sentry (2d) shadows call
# jev.sh through this exact same OS-timeout-backstop pattern and so share
# this identical inference gap; they get the same one-writer redesign in a
# follow-up once those PRs merge. Not touched here.
#
# This runs after the digest has already been printed and reconciled, so it
# can only add wall time to the cron, never change stdout or the exit code.
# Bounds match the removed pre-pass: <=25 threads
# (JEV_EMAIL_TRIAGE_MAX_THREADS), 1s/call (JEV_EMAIL_TRIAGE_TIMEOUT_MS), 20s
# total budget (JEV_EMAIL_TRIAGE_BUDGET_S), plus a hard external
# timeout/gtimeout backstop per call so a jev.sh that hangs past its own
# --timeout-ms cannot wedge the cron.
#
# Every statement in this function is best-effort and errexit-safe: nothing
# it does -- a missing jev.sh, a nonzero exit, a hung call, a missing
# timeout binary -- may prevent the PII scrub below (`rm -rf "$WORKDIR"`)
# from running. The whole thing is one function called as `|| true`, and
# nothing inside it can itself trigger `set -e` (every command that can
# fail is already inside an `if`/`||`).
# Mirrors jev.sh's own _jev_sha256 (macOS has no sha256sum by default).
_jev_email_triage_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  fi
}

_jev_email_triage_classify_shadow() {
  : "${JEV_EMAIL_TRIAGE_MAX_THREADS:=25}"
  : "${JEV_EMAIL_TRIAGE_TIMEOUT_MS:=1000}"
  : "${JEV_EMAIL_TRIAGE_BUDGET_S:=20}"
  : "${JEV_SHADOW_STORE_STATE:=1}"
  case "$JEV_EMAIL_TRIAGE_MAX_THREADS" in ''|*[!0-9]*) JEV_EMAIL_TRIAGE_MAX_THREADS=25 ;; esac
  case "$JEV_EMAIL_TRIAGE_TIMEOUT_MS" in ''|*[!0-9]*) JEV_EMAIL_TRIAGE_TIMEOUT_MS=1000 ;; esac
  case "$JEV_EMAIL_TRIAGE_BUDGET_S" in ''|*[!0-9]*) JEV_EMAIL_TRIAGE_BUDGET_S=20 ;; esac

  local script_dir questions_file shadow_file lock_file provider
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || return 0
  : "${JEV_SH:=/opt/hydra/scripts/lib/jev.sh}"
  questions_file="${JEV_EMAIL_TRIAGE_QUESTIONS_FILE:-$script_dir/jev-email-triage-questions.json}"
  # This function is now the ONLY writer of this file (jev.sh is called with
  # --no-shadow), so this is simply where its one row per call lands.
  shadow_file="${JEV_SHADOW_DIR:-/var/lib/hydra-jev/shadow}/email-triage.jsonl"
  lock_file="${shadow_file}.lock"
  provider="${JEV_PROVIDER:-openrouter}"
  local classify_warn=0

  [ -r "$EMAILS" ] || return 0
  [ -r "$VERDICTS" ] || return 0
  [ -x "$JEV_SH" ] || return 0
  [ -r "$questions_file" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local questions_sha
  questions_sha="$(_jev_email_triage_sha256 "$questions_file")"

  local n_threads
  n_threads=$(jq 'if type == "array" then length else empty end' "$EMAILS" 2>/dev/null)
  case "$n_threads" in ''|*[!0-9]*) n_threads=0 ;; esac
  [ "$n_threads" -gt 0 ] || return 0

  # FAIL CLOSED on the OS-level bound (same rule as the prod-log and sentry
  # shadows, QA on #1009): jev.sh bounds its curl call, but nothing else it
  # does has a limit, and this runs just before the PII scrub. No usable
  # timeout binary -> no Jev call at all. JEV_EMAIL_TRIAGE_TIMEOUT_BIN is a
  # test seam.
  local hard_timeout_cmd=""
  if [ -n "${JEV_EMAIL_TRIAGE_TIMEOUT_BIN:-}" ]; then
    command -v "$JEV_EMAIL_TRIAGE_TIMEOUT_BIN" >/dev/null 2>&1 && hard_timeout_cmd="$JEV_EMAIL_TRIAGE_TIMEOUT_BIN"
  elif command -v timeout >/dev/null 2>&1; then
    hard_timeout_cmd="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    hard_timeout_cmd="gtimeout"
  fi
  if [ -z "$hard_timeout_cmd" ]; then
    echo "format-digest: WARN no usable timeout binary -- skipping the Jev shadow (never an unbounded call)" >&2
    return 0
  fi
  local hard_timeout_s=$(( (JEV_EMAIL_TRIAGE_TIMEOUT_MS + 999) / 1000 + 1 ))

  local work_dir
  work_dir="$(mktemp -d "$WORKDIR/.shadow-scratch.XXXXXX")" || return 0
  # This work_dir is scratch state only (per-call state.json/answers.json) --
  # never the sidecar/answer-key pattern the coordinator flagged, since
  # nothing here is ever read back into the digest or the LLM's context.
  # Deliberately created INSIDE $WORKDIR, not under ${TMPDIR:-/tmp}: $WORKDIR
  # already holds the SAME customer PII (emails.json) and is covered by the
  # skill's existing cleanup contract -- preflight's INT/TERM trap, the
  # SKILL.md must-rm rule, and this file's own trailing `rm -rf "$WORKDIR"`.
  # A scratch dir under ${TMPDIR:-/tmp} would be a SECOND place PII can leak:
  # if format-digest.sh is SIGTERM'd (systemd, a timeout) after state.json is
  # written but before the explicit `rm -rf "$work_dir"` below runs, that
  # second directory is orphaned forever -- none of preflight's trap, the
  # SKILL.md rule, or this function's own cleanup path can reach it, because
  # none of them know it exists. Nesting it in $WORKDIR means the copy lives
  # and dies with the original: any cleanup that removes $WORKDIR removes it
  # too, so a SIGTERM mid-call leaves at most the SAME PII footprint that
  # already existed (emails.json), not a new orphan (QA on #1008, real PII
  # leak finding). The explicit end-of-function `rm -rf "$work_dir"` stays as
  # well, for the common case where format-digest.sh runs to completion.
  # No `trap ... RETURN` here on purpose: in bash a RETURN trap set inside a
  # function is NOT function-scoped (no functrace), stays armed, and fires on
  # the next function return anywhere with $work_dir out of scope -- under
  # `set -u` that aborts, right before the PII scrub (the same bug was caught
  # in prod-log-alert-watchdog.sh, #1009). This function has one exit path
  # after mktemp, so it cleans up explicitly at the end instead.

  local limit=$JEV_EMAIL_TRIAGE_MAX_THREADS
  local n_considered=$(( n_threads < limit ? n_threads : limit ))

  local SECONDS=0
  local i=0 thread_id verdict state_file actual_json
  while [ "$i" -lt "$n_considered" ]; do
    if [ "$SECONDS" -ge "$JEV_EMAIL_TRIAGE_BUDGET_S" ]; then
      break
    fi

    thread_id=$(jq -r --argjson idx "$i" '.[$idx].threadId // empty' "$EMAILS" 2>/dev/null)
    if [ -z "$thread_id" ]; then
      i=$(( i + 1 ))
      continue
    fi

    state_file="$work_dir/state.json"
    if ! jq --argjson idx "$i" \
        '.[$idx] | {from: (.from // ""), subject: (.subject // ""), body_excerpt: (.body_excerpt // "")}' \
        "$EMAILS" > "$state_file" 2>/dev/null; then
      i=$(( i + 1 ))
      continue
    fi

    verdict=$(jq -r --arg tid "$thread_id" \
      'map(select(.threadId == $tid)) | .[0].verdict // empty' "$VERDICTS" 2>/dev/null)
    actual_json=""
    if [ -n "$verdict" ]; then
      actual_json=$(jq -nc --arg o "$verdict" '{owner: $o}' 2>/dev/null || true)
    fi

    local -a jev_args=(--surface email-triage --item-id "$thread_id"
      --state-file "$state_file" --questions-file "$questions_file"
      --timeout-ms "$JEV_EMAIL_TRIAGE_TIMEOUT_MS" --no-shadow)
    if [ -n "$actual_json" ]; then jev_args+=(--actual "$actual_json"); fi

    local state_sha state_json stdout_file call_rc start_ms end_ms latency_ms
    state_sha="$(_jev_email_triage_sha256 "$state_file")"
    state_json="null"
    if [ "$JEV_SHADOW_STORE_STATE" != "0" ]; then
      state_json="$(jq -c . "$state_file" 2>/dev/null || echo null)"
    fi
    stdout_file="$work_dir/answers.out"
    : > "$stdout_file"

    start_ms=$(($(date +%s%N) / 1000000))
    "$hard_timeout_cmd" "${hard_timeout_s}s" "$JEV_SH" "${jev_args[@]}" \
      >"$stdout_file" 2>/dev/null
    call_rc=$?
    end_ms=$(($(date +%s%N) / 1000000))
    latency_ms=$(( end_ms - start_ms ))

    # No inference: jev.sh wrote nothing (--no-shadow), so this function is
    # the only place a row is ever decided or written.
    # answers_file, not an argv string: Linux caps ONE execve argument at
    # MAX_ARG_STRLEN (128 KB), so `--argjson answers "$big"` fails with
    # "Argument list too long" and the row drops into the logger path.
    # --slurpfile reads the file instead, with no size ceiling.
    local eff_rc="$call_rc" reason="" answers_file="$work_dir/answers.null" stdout_content
    printf 'null' > "$answers_file"
    if [ "$call_rc" -eq 0 ]; then
      stdout_content="$(cat "$stdout_file" 2>/dev/null)"
      if [ -n "$stdout_content" ] && printf '%s' "$stdout_content" | jq -e 'type == "object"' >/dev/null 2>&1; then
        answers_file="$stdout_file"
        eff_rc=0
      else
        # rc 0 with no usable answer must never look like a measured
        # agreement (QA finding 1): count it as the failure it is, in
        # jev.sh's own code for "no .answers object".
        eff_rc=3
        reason="unparseable_answers"
      fi
    else
      case "$call_rc" in
        124|137) reason="os_timeout_kill" ;;
      esac
    fi

    local row_actual="$actual_json"
    [ -n "$row_actual" ] || row_actual="null"
    local row
    row=$(jq -nc \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg surface "email-triage" \
      --arg item_id "$thread_id" \
      --arg state_sha256 "$state_sha" \
      --arg questions_sha256 "$questions_sha" \
      --slurpfile answers_arr "$answers_file" \
      --argjson latency_ms "$latency_ms" \
      --argjson actual "$row_actual" \
      --argjson rc "$eff_rc" \
      --arg provider "$provider" \
      --arg reason "$reason" \
      --argjson state "$state_json" \
      '{ts:$ts, surface:$surface, item_id:$item_id,
        state_sha256:(if $state_sha256 == "" then null else $state_sha256 end),
        questions_sha256:(if $questions_sha256 == "" then null else $questions_sha256 end),
        state:$state,
        model:null, answers:$answers_arr[0], usage:null, latency_ms:$latency_ms,
        actual:$actual, rc:$rc, http:null, provider:$provider,
        reason:(if $reason == "" then null else $reason end)}' 2>/dev/null)

    local recorded=1
    if [ -z "$row" ]; then
      recorded=0
    elif ! mkdir -p "$(dirname "$shadow_file")" 2>/dev/null; then
      recorded=0
    elif command -v flock >/dev/null 2>&1; then
      # Serializes the append against every other concurrent run sharing
      # this shadow file (QA finding 2): each writer locks the SAME sibling
      # .lock file before appending its own already-fully-built line, so two
      # overlapping runs can interleave calls but never interleave bytes
      # within a line. Create-at-0600/tighten happens INSIDE the lock too
      # (QA finding): doing it outside would let two writers race the
      # existence check, and the O_TRUNC create clobber whatever the other
      # had already written.
      if ! ( flock -w 5 9 || exit 1
             if [ ! -e "$shadow_file" ]; then
               ( umask 077; : > "$shadow_file" ) 2>/dev/null || true
             fi
             chmod 0600 "$shadow_file" 2>/dev/null || true
             printf '%s\n' "$row" >> "$shadow_file"
           ) 9>>"$lock_file" 2>/dev/null; then
        recorded=0
      fi
    else
      # flock (util-linux) is expected on node-8; this fallback exists for a
      # bare dev box that lacks it. It is still safe on its own: bash's >>
      # opens with O_APPEND, and one printf of a single JSONL line (well
      # under PIPE_BUF) through an O_APPEND fd is already an atomic write --
      # concurrent writers still cannot interleave a partial line into each
      # other's, they just are not lock-ordered or wait-bounded. Same
      # create-at-0600/tighten as above; no lock is available here to hold
      # it under, so it's still best-effort ordered like everything else in
      # this fallback.
      if [ ! -e "$shadow_file" ]; then
        ( umask 077; : > "$shadow_file" ) 2>/dev/null || true
      fi
      chmod 0600 "$shadow_file" 2>/dev/null || true
      if ! printf '%s\n' "$row" >> "$shadow_file" 2>/dev/null; then
        recorded=0
      fi
    fi

    if [ "$recorded" -eq 0 ]; then
      classify_warn=1
      if command -v logger >/dev/null 2>&1; then
        logger -t jev-shadow \
          "email-triage: shadow row not recorded for $thread_id (rc=$eff_rc, reason=${reason:-none})" \
          2>/dev/null || true
      fi
    fi

    i=$(( i + 1 ))
  done
  rm -rf "$work_dir"
  if [ "$classify_warn" -eq 1 ]; then
    echo "format-digest: WARN one or more Jev shadow rows for email-triage could not be recorded anywhere (shadow dir unwritable/full) -- see the jev-shadow syslog tag" >&2
  fi
  return 0
}
_jev_email_triage_classify_shadow || true

rm -rf "$WORKDIR"
