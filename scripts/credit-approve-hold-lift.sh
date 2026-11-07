#!/usr/bin/env bash
# credit-approve-hold-lift.sh - the ONE recorded step that lifts the credit-approval hold. PRINT-ONLY: it never removes.
#
# The hold (/etc/hydra/credit-trust-score-approve.disabled, firstmate 2026-11-06T08:2xZ) names its own resume condition:
#   "both switches come off together, in one recorded step, only after the coded-decider invalidation path is proved
#    (run twice, second invalidates first, no Errno 13)"
#
# The two switches are the ones credit-review.py `score-approve` checks together (cmd_score_approve:
# `score_approve.KILL_SWITCH.exists() or decide.KILL_SWITCH.exists()`):
#   1. /etc/hydra/credit-trust-score-approve.disabled   (score-approve's own kill switch)
#   2. /etc/hydra/credit-trust-decide.disabled           (the decider WRITER's kill switch, which score-approve honours too;
#                                                        auto-written 2026-11-05T02:55Z by a never-lower refusal after an
#                                                        [Errno 13] on a /tmp coded output - the condition the proof retires)
# The pause file score-approve turns itself to shadow on (/var/lib/hydra/credit-review/score-approve.paused) is NOT one
# of them: score_approve.write_audit_sample_failed writes it when the audit sample cannot be filed, its own owner clears
# it (`credit-review.py score-approve --resume`), and the proof above covers the coded-decider output path, not that
# guard. This plan reports it when present and never removes it.
#
# What this script DOES (all of it reversible, none of it a removal):
#   * RUNS the proof itself - scripts/prove-coded-decider-invalidation.py against --tree (default: the tree this script
#     lives in, /opt/hydra on node-8), with --with-failed-refresh AND --host-probe: the sandbox runs prove the mechanism,
#     and the host probe performs the writer's ladder (create, replace, invalidate, unlink) as the decider's service
#     user on probe-named files in the LIVE output directory (/var/lib/hydra/credit-review by default; --live-dir
#     redirects it for tests), because the hold was armed by a permission failure and permissions belong to the real
#     directory and the real user, not to the code. The transcript is recorded under <state-dir>. A plan is produced
#     only when that run exits 0 AND its transcript's verdict line is `PROOF: PASS` AND names the host probe as PASS. A
#     transcript handed in from elsewhere is never accepted: the resume condition is the proof, so the planner must
#     witness it, not be told it;
#   * refuses unless BOTH switches are present (the condition says "both ... together"; one present is an unexpected
#     state a human must look at, not a half-lift);
#   * backs up both switches, byte-for-byte with their mtimes, under <state-dir>/kill-lift-backups/<ts>/;
#   * writes ONE durable evidence entry <state-dir>/kill-lift-<MMDD-HHMM>.evidence in the shape the earlier lifts used
#     (kill-lift-1104-1505.evidence ...): key, timestamp, each file's path/size/mtime/sha256/content, its backup, the proof;
#   * prints the diff each switch would undergo (present -> absent) and the exact one-step command line, which rechecks
#     both planned sha256s immediately before removal (a switch re-armed after the plan is refused, never lifted on the
#     old proof), records `lifting` BEFORE it removes anything and, if either removal fails, restores both switches from
#     the backups and records `ROLLED BACK` with the outcome it actually observed (restored, or RESTORE FAILED) - so
#     there is never a removed switch without a completed record, and never a record claiming a restore that did not
#     happen;
#   * serializes the whole plan on one lock, so two planners in the same minute cannot both pass the existence check and
#     truncate the first durable record;
#   * STOPS. Nothing is removed. There is no --execute: the removal is a separate, human-run step, and the printed line is
#     what that step runs, verbatim, so the recorded plan and the act cannot drift.
#
# Usage:
#   scripts/credit-approve-hold-lift.sh [--tree /opt/hydra] [--etc-dir /etc/hydra] [--state-dir /var/lib/hydra/credit-review]
#                                      [--fixture PATH] [--live-dir DIR] [--service-user root] [--by "name"]
#                                      [--cron-store /root/.openclaw-main/state/openclaw.sqlite]
# --live-dir redirects the proof's host probe (default: the tree's own CODED_DECIDER_OUT directory); --service-user is
# the user the decider cron runs as, whose permissions the probe measures.
# The cron store is read (never written) for the scheduler row's `enabled` flag, the first of the three stops; the plan
# says enabled / DISABLED / unknown and never promises a tick it has not seen enabled.
# Exit: 0 plan printed and recorded; 2 refused (proof did not pass, a switch missing or unreadable, or nothing to lift).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE="$(cd "$HERE/.." && pwd)"
ETC_DIR=/etc/hydra
STATE_DIR=/var/lib/hydra/credit-review
FIXTURE=""
LIVE_DIR=""          # default: the directory the tree's decide.py writes the coded output to
SERVICE_USER=root    # the decider cron runs inside the gateway (openclaw isolated command cron) as root
CRON_STORE=/root/.openclaw-main/state/openclaw.sqlite
CRON_JOB_ID=f5fc0ebe-8dc2-5414-8c75-5913ddedb278   # credit-trust-score-approve-15m
BY="${SUDO_USER:-${USER:-$(id -un)}}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tree) TREE="${2:?}"; shift 2 ;;
    --etc-dir) ETC_DIR="${2:?}"; shift 2 ;;
    --state-dir) STATE_DIR="${2:?}"; shift 2 ;;
    --fixture) FIXTURE="${2:?}"; shift 2 ;;
    --live-dir) LIVE_DIR="${2:?}"; shift 2 ;;
    --service-user) SERVICE_USER="${2:?}"; shift 2 ;;
    --by) BY="${2:?}"; shift 2 ;;
    --cron-store) CRON_STORE="${2:?}"; shift 2 ;;
    --proof)
      echo "REFUSED: --proof is gone. The planner runs the proof itself; a transcript handed in is not evidence that it ran." >&2
      exit 2 ;;
    -h|--help) sed -n '2,53p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

TS="$(date -u +%Y%m%dT%H%M%SZ)"
KEY="kill-lift-$(date -u +%m%d-%H%M)"
SWITCHES=(
  "$ETC_DIR/credit-trust-score-approve.disabled"
  "$ETC_DIR/credit-trust-decide.disabled"
)
PAUSE_FILE="$STATE_DIR/score-approve.paused"
PROVE="$HERE/prove-coded-decider-invalidation.py"

say() { printf '%s\n' "$*"; }
sha() { sha256sum "$1" | awk '{print $1}'; }

# The THIRD stop, read-only: the live cron store's `enabled` flag on credit-trust-score-approve-15m. The two files are
# the second and third locks; the scheduler row is the first. Removing the files restores nothing while it is 0, so the
# plan must say which it is rather than promise approvals on the next tick. Measured 2026-11-07: enabled=0 since
# 2026-10-15T22:30Z, matching `enabled: false` in cron-jobs.json (the deploy imports that file into the store).
cron_enabled() {
  if [[ ! -r "$CRON_STORE" ]] || ! command -v sqlite3 >/dev/null 2>&1; then
    printf 'unknown'; return
  fi
  local v
  v="$(sqlite3 -readonly "$CRON_STORE" "select enabled from cron_jobs where job_id='$CRON_JOB_ID' limit 1" 2>/dev/null || true)"
  case "$v" in 1) printf 'enabled' ;; 0) printf 'DISABLED' ;; *) printf 'unknown' ;; esac
}
CRON_STATE="$(cron_enabled)"
case "$CRON_STATE" in
  enabled) CRON_NOTE="the cron row is enabled=1 in $CRON_STORE, so once both files are gone the next :10/:25/:40/:55 tick runs the approver" ;;
  DISABLED) CRON_NOTE="the cron row credit-trust-score-approve-15m is enabled=0 in $CRON_STORE: removing both files restores NOTHING by itself; the scheduler row is a third stop, switched by a cron-jobs.json PR (deploy imports it), not by this step" ;;
  *) CRON_NOTE="the cron row's enabled flag could not be read from $CRON_STORE (absent or no sqlite3); whether a tick follows the lift is UNKNOWN, not assumed" ;;
esac

say "KILL LIFT PLAN - [key=$KEY]  (PRINT-ONLY: this run removes nothing)"
say "at=$TS by=$BY host=$(hostname) tree=$TREE etc-dir=$ETC_DIR state-dir=$STATE_DIR"
say ""

# ── 0. inventory first: a plan needs both switches, so do not run the proof for a state that cannot be planned ──
missing=()
for f in "${SWITCHES[@]}"; do
  if [[ -e "$f" && ! -r "$f" ]]; then
    say "REFUSED: $f exists but cannot be read; a switch whose label is unknown is not lifted on a plan."
    exit 2
  fi
  [[ -e "$f" ]] || missing+=("$f")
done
if [[ ${#missing[@]} -eq ${#SWITCHES[@]} ]]; then
  say "NOTHING TO LIFT: none of the switches exist:"
  for f in "${SWITCHES[@]}"; do say "  absent  $f"; done
  say "No proof run, no evidence entry written (there is no state to record), nothing removed."
  exit 2
fi
if [[ ${#missing[@]} -gt 0 ]]; then
  say "REFUSED: the resume condition says BOTH switches come off together, and only one is present:"
  for f in "${SWITCHES[@]}"; do
    if [[ -e "$f" ]]; then say "  PRESENT $f"; else say "  ABSENT  $f"; fi
  done
  say "A switch missing before the lift is an unexpected state (someone or something already removed it, or the hold was"
  say "re-armed on one side only). A human looks at that first. No proof run, nothing backed up, recorded or removed."
  exit 2
fi

mkdir -p "$STATE_DIR"
# Serialize the whole plan on one lock. The existence check below and the final `>` are not atomic, so two planners
# started in the same minute could both pass the check and the second would truncate the first durable record (or a
# `lifted` line a human had already appended to it). The lock is held until this process exits.
exec 9>"$STATE_DIR/.kill-lift.lock"
flock 9
EVIDENCE="$STATE_DIR/$KEY.evidence"
if [[ -e "$EVIDENCE" ]]; then
  say "REFUSED: $EVIDENCE already exists. A second plan in the same minute would truncate the first durable record,"
  say "  including any \`lifted [...]\` line a human appended to it. Nothing was backed up, recorded or removed."
  exit 2
fi

# ── 1. the proof the resume condition names - RUN here, not read from a file ───────────────────────────────
if [[ ! -f "$PROVE" ]]; then
  say "REFUSED: $PROVE is not here; the planner cannot witness the proof. Nothing was backed up, recorded or removed."
  exit 2
fi
if [[ ! -f "$TREE/scripts/credit_review/decide.py" ]]; then
  say "REFUSED: $TREE/scripts/credit_review/decide.py does not exist; --tree must be the tree under proof."
  exit 2
fi
PROOF="$STATE_DIR/coded-invalidation-proof-$TS.txt"
prove_args=(--tree "$TREE" --record "$PROOF" --with-failed-refresh --service-user "$SERVICE_USER")
if [[ -n "$LIVE_DIR" ]]; then prove_args+=(--host-probe "$LIVE_DIR"); else prove_args+=(--host-probe); fi
[[ -n "$FIXTURE" ]] && prove_args+=(--fixture "$FIXTURE")
say "proof: running python3 $PROVE ${prove_args[*]}"
set +e
PROOF_OUT="$(python3 "$PROVE" "${prove_args[@]}" 2>&1)"
PROOF_RC=$?
set -e
VERDICT="$(printf '%s\n' "$PROOF_OUT" | grep -E '^PROOF: (PASS|FAIL)' | tail -n 1 || true)"
if [[ "$PROOF_RC" -ne 0 || "$VERDICT" != "PROOF: PASS"* || ! -s "$PROOF" ]]; then
  say "REFUSED: the coded-decider invalidation proof did not pass (exit $PROOF_RC)."
  say "  verdict line: ${VERDICT:-<none>}"
  say "  transcript: $PROOF$( [[ -s "$PROOF" ]] || printf ' (not written)')"
  say "  last lines of the run:"
  printf '%s\n' "$PROOF_OUT" | tail -n 25 | sed 's/^/    /'
  say "Nothing was backed up, recorded or removed. A proof that did not pass is the finding, not a formality."
  exit 2
fi
if [[ "$(grep -E '^PROOF: (PASS|FAIL)' "$PROOF" | tail -n 1)" != "PROOF: PASS"* ]]; then
  say "REFUSED: the run said PASS but the recorded transcript $PROOF does not; nothing was backed up, recorded or removed."
  exit 2
fi
if ! grep -E '^PROOF: PASS' "$PROOF" | tail -n 1 | grep -qE '; host probe in \S+ as uid [0-9]+: PASS\.'; then
  say "REFUSED: the proof passed in the sandbox but its verdict line does not carry the host probe (the live directory's permissions for the service user); nothing was backed up, recorded or removed."
  exit 2
fi
PROOF_SHA="$(sha "$PROOF")"
say "  exit=$PROOF_RC"
say "  verdict: $VERDICT"
say "  transcript: $PROOF ($(stat -c '%s' "$PROOF") b, sha256 $PROOF_SHA)"
say ""

# ── 2. the switches, and what they say ──────────────────────────────────────────────────────────────────────
say "switches:"
for f in "${SWITCHES[@]}"; do
  say "  PRESENT $f  ($(stat -c '%s b, mtime %y' "$f"), sha256 $(sha "$f"))"
done
if [[ -e "$PAUSE_FILE" ]]; then
  say "  OUT OF SCOPE (reported, never removed by this step): $PAUSE_FILE"
  say "    $(head -c 200 "$PAUSE_FILE" 2>/dev/null || true)"
  say "    the audit-sample guard's own pause; its owner clears it with \`credit-review.py score-approve --resume\`."
  say "    The proof above covers the coded-decider output path, not this guard, so this plan leaves it alone."
fi
say "  scheduler: $CRON_STATE - $CRON_NOTE"
say ""

# ── 3. back up both switches, byte-for-byte, mtime kept ──────────────────────────────────────────────────────
BACKUP_DIR="$STATE_DIR/kill-lift-backups/$TS"
mkdir -p "$BACKUP_DIR"
say "backups -> $BACKUP_DIR"
for f in "${SWITCHES[@]}"; do
  cp -p "$f" "$BACKUP_DIR/$(basename "$f")"
  if [[ "$(sha "$f")" != "$(sha "$BACKUP_DIR/$(basename "$f")")" ]]; then
    say "REFUSED: backup of $f does not match the original; nothing removed."
    exit 2
  fi
  say "  $(basename "$f")  sha256 $(sha "$BACKUP_DIR/$(basename "$f")")  (verified equal to the original)"
done
say ""

# ── 4. the diff each switch would undergo (present -> absent) ──────────────────────────────────────────────
EMPTY="$(mktemp)"
trap 'rm -f "$EMPTY"' EXIT
say "diff (what the one step would change; - lines are the bytes that would stop existing):"
for f in "${SWITCHES[@]}"; do
  diff -u --label "$f (present)" --label "$f (absent after the step)" "$f" "$EMPTY" || true
done
say ""

# ── 5. the one recorded step: a generated, sha-pinned script, NOT run ─────────────────────────────────────
# Shape: record `lifting` (a failed append removes nothing) -> TAKE each switch aside with one same-directory rename
# -> verify the TAKEN bytes against the plan -> record `lifted` -> discard the taken copies. Take-then-verify closes
# the check-then-remove window: a writer (decide.py rearm_kill_switch, which does not always hold the credit write
# lock) that re-arms a switch after the rename creates a NEW file at the switch path, and this step never removes a
# file it has not verified - a switch that appears during the step is left in place and reported. Any failure before
# the `lifted` record puts every taken switch back and records ROLLED BACK; a switch that was re-armed meanwhile keeps
# its new reason (the old bytes are in the backups, not restored over it).
S1="${SWITCHES[0]}"; S2="${SWITCHES[1]}"
H1="$(sha "$S1")"; H2="$(sha "$S2")"
STEP_SCRIPT="$STATE_DIR/$KEY.lift-step.sh"
q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }   # single-quoted literal for the generated script
{
  printf '#!/usr/bin/env bash\n'
  printf '# kill-lift step [key=%s] - generated by scripts/credit-approve-hold-lift.sh at %s; a human runs it ONCE.\n' "$KEY" "$TS"
  printf '# It lifts exactly the two switches the proof covered (sha256 pinned below) and nothing else.\n'
  printf 'set -u\n'
  printf 'EV=%s; KEY=%s; BY=%s; BACKUPS=%s\n' "$(q "$EVIDENCE")" "$(q "$KEY")" "$(q "$BY")" "$(q "$BACKUP_DIR")"
  printf 'S1=%s; H1=%s\n' "$(q "$S1")" "$(q "$H1")"
  printf 'S2=%s; H2=%s\n' "$(q "$S2")" "$(q "$H2")"
  printf 'PROOF_LINE=%s\n' "$(q "proof $PROOF sha256 $PROOF_SHA")"
  printf 'SCHED=%s\n' "$(q "scheduler row was $CRON_STATE at plan time")"
  cat <<'STEP'
Q1="$S1.lifting-$KEY"; Q2="$S2.lifting-$KEY"
rec() { printf '%s %s [key=%s] by %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$KEY" "$BY" "$2" >> "$EV"; }
sha() { sha256sum -- "$1" | cut -d' ' -f1; }
take() { # take <switch> <aside> <sha>: one same-directory rename, then verify the bytes we now hold
  mv -n -- "$1" "$2" 2>/dev/null; [ -e "$2" ] && [ ! -e "$1" ] || { WHY="could not take $1"; return 1; }
  [ "$(sha "$2")" = "$3" ] || { WHY="$1 changed after the plan (expected $3, taken $(sha "$2"))"; return 1; }
}
put_back() { # put_back <switch> <aside>: restore only if the switch path is still empty; a re-armed switch keeps its new reason
  [ -e "$2" ] || return 0
  if [ -e "$1" ]; then rm -f -- "$2"; KEPT="$KEPT $1(re-armed meanwhile, left as found)"; else mv -n -- "$2" "$1" || RESTORE_FAILED="$RESTORE_FAILED $1"; fi
}
WHY=""; KEPT=""; RESTORE_FAILED=""
# 1. recorded first: a failed append removes nothing
rec lifting "$PROOF_LINE" || exit 1
# 2. take, then verify, both
if take "$S1" "$Q1" "$H1" && take "$S2" "$Q2" "$H2"; then
  # 3. a switch that reappeared while we held both aside copies is a NEW hold with its own reason: nothing is
  #    lifted, the other switch goes back, and the step is rolled back WITH the copies still in hand
  if [ -e "$S1" ] || [ -e "$S2" ]; then
    WHY="a new switch appeared while lifting ($( [ -e "$S1" ] && printf '%s ' "$S1"; [ -e "$S2" ] && printf '%s' "$S2")); it is NOT the proven switch: the hold is ON again with its own reason"
  # 4. the completed record is the LAST line this step writes, and it is written while the taken copies still
  #    exist: a lift nobody can read back is not a completed step, and nothing follows `lifted`
  elif rec lifted "both proven switches taken and verified; $SCHED"; then
    rm -f -- "$Q1" "$Q2"
    exit 0
  else
    WHY="the lifted record could not be appended"
  fi
fi
# 5. anything else: every taken switch goes back (unless re-armed meanwhile), and the outcome is recorded as observed
put_back "$S1" "$Q1"; put_back "$S2" "$Q2"
if [ -n "$RESTORE_FAILED" ]; then
  rec "ROLLED BACK" "$WHY; the RESTORE FAILED for$RESTORE_FAILED, switches may be absent; backups are $BACKUPS"
else
  rec "ROLLED BACK" "$WHY; every taken switch restored from its aside copy${KEPT:+;$KEPT}; backups are $BACKUPS"
fi
exit 1
STEP
} > "$STEP_SCRIPT"
chmod 0700 "$STEP_SCRIPT"
STEP_SHA="$(sha "$STEP_SCRIPT")"
STEP="bash '$STEP_SCRIPT'"
say "the ONE step (both switches, recorded first, take-then-verify, rolled back together on failure; this run does NOT execute it):"
say "  $STEP"
say "  (script sha256 $STEP_SHA; its full text is in the evidence entry)"
say ""

# ── 6. the durable evidence entry ───────────────────────────────────────────────────────────────────────────
{
  say "KILL LIFT EVIDENCE - [key=$KEY]   (PLAN RECORDED $TS; the step below was NOT executed by the planner)"
  say "planner: scripts/credit-approve-hold-lift.sh (print-only by design) by=$BY host=$(hostname) tree=$TREE"
  say "resume condition (verbatim from credit-trust-score-approve.disabled): \"both switches come off together, in one"
  say "  recorded step, only after the coded-decider invalidation path is proved (run twice, second invalidates first,"
  say "  no Errno 13)\""
  say "proof: run by this planner at $TS: python3 $PROVE ${prove_args[*]}"
  say "  exit=$PROOF_RC"
  say "  verdict: $VERDICT"
  say "  transcript: $PROOF"
  say "  sha256=$PROOF_SHA"
  say "switches at $TS:"
  for f in "${SWITCHES[@]}"; do
    say "  PRESENT $f"
    say "    size=$(stat -c '%s' "$f") mtime=$(stat -c '%y' "$f") sha256=$(sha "$f")"
    say "    backup=$BACKUP_DIR/$(basename "$f")"
    say "    content (verbatim, indented):"
    sed 's/^/      | /' "$f"
  done
  if [[ -e "$PAUSE_FILE" ]]; then
    say "  OUT OF SCOPE (not removed by this step): $PAUSE_FILE"
    say "    $(head -c 200 "$PAUSE_FILE" 2>/dev/null || true)"
    say "    the audit-sample guard's own pause; its owner clears it with \`credit-review.py score-approve --resume\`."
  fi
  say "the one step (verbatim; a human runs it, nothing else does; it appends its own lifting/lifted/ROLLED BACK lines below):"
  say "  $STEP"
  say "the step script (sha256 $STEP_SHA; verbatim, indented):"
  sed 's/^/      | /' "$STEP_SCRIPT"
  say "restore (if the lift must be undone later): cp -p $BACKUP_DIR/<name> $ETC_DIR/"
  say "the pause file, if present, is untouched by this plan and needs no restore."
  say "scheduler at $TS: $CRON_STATE - $CRON_NOTE"
  say "acceptance after the step: with the scheduler row enabled, credit-trust-score-approve-15m fires (:10/:25/:40/:55)"
  say "  and the next run reports approve > 0; a previously held ledger row moves to approved; every other guard"
  say "  (never-lower, validator-reject, registry approved_by/approval_ref, risk < 30, <= 100 per run) is untouched by this plan."
  say "status: PLANNED, NOT EXECUTED"
} > "$EVIDENCE"
say "durable log entry written: $EVIDENCE ($(stat -c '%s' "$EVIDENCE") b)"
command -v logger >/dev/null 2>&1 && logger -t hydra-kill-lift "[key=$KEY] plan recorded at $EVIDENCE (print-only; nothing removed)" || true
say ""
say "STOPPED before the step: nothing was removed. The switches above are still present, their backups are at"
say "$BACKUP_DIR, and the plan is at $EVIDENCE."
exit 0
