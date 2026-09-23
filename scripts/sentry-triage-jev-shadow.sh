#!/bin/bash
# ──────────────────────────────────────────────────────────────
# sentry-triage-jev-shadow.sh — Phase 2d Jev shadow call
# (docs/plans/jev-adoption.md) for skills-all/sentry-issue-triage/SKILL.md.
#
# SHADOW ONLY. Judges the same five-class rubric the sentry-issue-triage
# skill's Step 3 already assigned (`$class`), over the one-line evidence
# summary the skill already requires the agent to write before the ledger
# row (Step 5's `$summary` -- "a real one-line description you have already
# written"), purely to measure agreement. Never returns non-zero, never
# prints anything the skill's ledger write depends on, and is safe to
# delete from SKILL.md with zero effect on classification, the PR/archive
# path, or the ledger row -- it does NOT write jev_class into the ledger;
# jev-shadow-report.sh reads Jev's own shadow log
# (${JEV_SHADOW_DIR:-/var/lib/hydra-jev/shadow}/sentry-issue-triage.jsonl)
# for that, keyed by --item-id (the Sentry short id), same as every other
# Phase 2 surface.
#
# WHO writes `class`: the sentry-issue-triage skill's agent turn, in the
# embedded bash at Step 3-5 (verified: scripts/sentry-issue-watchdog.sh only
# READS the ledger for dedupe/qa-merge, never writes `class` -- grep
# '"class"' across both files). This script is called from that same
# embedded bash, right after `$class` is decided, as one more best-effort
# `exec` step -- not folded into the ledger-row jq (see the plan's "adding a
# field to ledger rows" question: a sidecar log is used instead, so no
# schema change reaches scripts/sentry-issue-watchdog.sh's readers or the
# existing bats-covered row shape in scripts/tests/sentry-triage-ledger.bats
# at all).
#
# Low volume (1-2 Sentry issues/week per the plan) -- a generous timeout is
# affordable and the call happens once per triage turn, never on a tight
# cron cadence.
#
# Usage:
#   sentry-triage-jev-shadow.sh --short-id CORE-BACKEND-115 \
#     --class config-or-infra --summary "TUWUNEL_* unset in prod env" \
#     [--jev-sh PATH] [--questions PATH] [--timeout-ms 3000]
#
# Always exits 0. Failure (missing jev.sh, the kill switch at
# /etc/hydra/jev.disabled giving rc=6, a timeout, bad args) is a WARN on
# stderr, never a non-zero exit -- the calling skill step must never be able
# to fail because of this.
# ──────────────────────────────────────────────────────────────
set -uo pipefail

_WD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_warn() { echo "sentry-triage-jev-shadow.sh: WARN $1" >&2; }

short_id="" class="" summary=""
jev_sh="${SENTRY_TRIAGE_JEV_SH:-$_WD_DIR/lib/jev.sh}"
questions_file="${SENTRY_TRIAGE_JEV_QUESTIONS:-}"
timeout_ms="${SENTRY_TRIAGE_JEV_TIMEOUT_MS:-3000}"
os_timeout="${SENTRY_TRIAGE_JEV_OS_TIMEOUT:-5}"

while [ $# -gt 0 ]; do
  case "$1" in
    --short-id) short_id="$2"; shift 2 ;;
    --class) class="$2"; shift 2 ;;
    --summary) summary="$2"; shift 2 ;;
    --jev-sh) jev_sh="$2"; shift 2 ;;
    --questions) questions_file="$2"; shift 2 ;;
    --timeout-ms) timeout_ms="$2"; shift 2 ;;
    *) _warn "unknown argument: $1 -- ignored"; shift ;;
  esac
done

# Every one of these is a reason to skip, never to fail: shadow calls must
# never make the triage turn's own step fail.
[ -n "$short_id" ] || { _warn "--short-id required -- skipping"; exit 0; }
[ -n "$class" ] || { _warn "--class required -- skipping"; exit 0; }
[ -n "$summary" ] || { _warn "--summary required -- skipping"; exit 0; }
[ -x "$jev_sh" ] || [ -r "$jev_sh" ] || { _warn "jev.sh not found/readable: $jev_sh -- skipping"; exit 0; }

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/sentry-jev-shadow.XXXXXX" 2>/dev/null)" \
  || { _warn "could not create a work dir -- skipping"; exit 0; }
trap 'rm -rf "$work_dir"' EXIT

if [ -z "$questions_file" ]; then
  questions_file="$work_dir/questions.json"
  cat > "$questions_file" <<'QEOF' 2>/dev/null || { _warn "could not write questions file -- skipping"; exit 0; }
{"class":{"type":"choice","criteria":{
  "code-fixable":"A specific first-party code path is wrong, and a small correct change fixes it.",
  "config-or-infra":"Code is right; an env var, secret, manifest, or deploy setting is wrong or missing.",
  "capacity-or-data":"A pool, quota, rate limit, or a specific bad data row is exhausted or malformed.",
  "client-noise":"Transient client network, browser-extension, or platform conditions the server cannot fix.",
  "needs-human":"Root cause not established, or the fix is a broad refactor."
},"instructions":"You are triaging ONE Sentry production issue for Muso's hydra CTO agent, after its investigation is complete. Assign exactly one class from the evidence summary given. code-fixable means a small, correct, first-party code change fixes it -- if the honest fix is a broad refactor or many-file rewrite, or the root cause was never actually established, that is needs-human, not code-fixable."}}
QEOF
fi

state_file="$work_dir/state.json"
jq -n --arg summary "$summary" '{summary: $summary}' > "$state_file" 2>/dev/null \
  || { _warn "could not build state file -- skipping"; exit 0; }

case "$timeout_ms" in ''|*[!0-9]*) timeout_ms=3000 ;; esac
# FAIL CLOSED on the OS-level bound: a bad duration is not silently replaced
# with a default, and 0 is refused because GNU `timeout 0` DISABLES the limit.
case "$os_timeout" in ''|*[!0-9]*|0) exit 0 ;; esac

timeout_bin=""
# SENTRY_TRIAGE_JEV_TIMEOUT_BIN is a test seam (default `timeout`).
command -v "${SENTRY_TRIAGE_JEV_TIMEOUT_BIN:-timeout}" >/dev/null 2>&1 \
  && timeout_bin="${SENTRY_TRIAGE_JEV_TIMEOUT_BIN:-timeout}"

# No usable `timeout` -> no Jev call: never an unbounded wait inside the skill.
[ -n "$timeout_bin" ] || exit 0
"$timeout_bin" "$os_timeout" \
  "$jev_sh" --surface sentry-issue-triage --item-id "$short_id" \
  --state-file "$state_file" --questions-file "$questions_file" \
  --actual "$class" --timeout-ms "$timeout_ms" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] || _warn "jev.sh exited $rc for $short_id -- shadow row (if any) already logged by jev.sh itself"
exit 0
