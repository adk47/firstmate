#!/bin/bash
# ──────────────────────────────────────────────────────────────
# clean-my-linux.sh: the node-8 disk cleaner's ORCHESTRATOR.
#
# One unit owns the ordering and the brakes; the focused scripts own the
# policies. This script contains no /tmp pattern logic of its own: R1 is
# scripts/tmp-reaper.sh, whose allow-list, TTLs and open-handle guard are its
# own. /tmp is covered in two layers, neither of them here:
#   * allow-listed scratch, within hours, open-handle guarded: tmp-reaper.sh (R1)
#   * everything else, generic, mtime-keyed, 24h, recursive: the tmpfiles catch-all
#     scripts/aux-units/tmp.conf ("D /tmp 1777 root root mM:24h"), installed by
#     install-aux-units.sh. It replaces the old weekly 14d depth-1 sweep and is
#     stricter (daily, 24h, recursive); /etc/tmpfiles.d/tmp.conf is never touched here.
# (Predecessor: weekly-cleanup.sh; see docs/designs/2026-10-09-clean-my-linux.md.)
#
# Rule table (R6 and R8 are unassigned; the labels follow MUS-6035), run in this order (cheapest-safe first):
#   R1 tmp-reaper       scripts/tmp-reaper.sh           /tmp scratch allow-list
#   R2 clone-sweep      scripts/sweep-workspace-clones.sh  agent + QA clone lanes
#   R3 codex-prune      scripts/codex-home-prune.sh     codex/openclaw home
#                       (a missing script is "skipped", never an error)
#   R4 bak              in-script: *.bak / *.bak.* / *.bak-* / *.orig older
#                       than BAK_AGE_DAYS under BAK_ROOTS. Patterns are
#                       deliberately tight (NOT *.bak*: that eats foo.bakery.md).
#   R5 apt              in-script: apt-get autoremove --purge + autoclean,
#                       at most once per 24h (watermark under STATE_DIR, NOT
#                       /opt/hydra, which the deploy rsync overwrites).
#   R7 runner-work      in-script: /opt/actions-runner/_work job directories
#                       whose whole tree is older than 24h. Candidates are the
#                       direct children of _work that do not start with "_" or
#                       "." (so _tool, _temp, _actions, _update, _PipelineMapping
#                       are never candidates); the runner binaries, .credentials*,
#                       .runner and _diag live OUTSIDE _work and are never reached.
#                       The whole rule is refused while _work/_temp holds anything
#                       (a job is mid-flight) and each dir goes through
#                       safe_delete_path (open-handle + mount guards). A hold runs
#                       AFTER the quarantine rename, when the name is private and
#                       a restore is reversible: _temp got a marker (rule aborts,
#                       status "partial"), or something wrote in the tree inside
#                       the window (that dir is held), or a process holds it open.
#   R9 container-layers in-script, GATED: runs only if used% is still ABOVE
#                       CONTAINER_GATE_PCT (80) after every rule above, so it is
#                       the last rule. Exactly two commands, nothing else:
#                         docker image prune -f      (dangling images only)
#                         crictl rmi --prune
#                       Never `-a`/`--all`, never `docker system prune`, never
#                       `--volumes` (volumes are data): a re-pull storm during
#                       disk pressure is its own incident, so this is the thing
#                       that saves the box, never routine housekeeping.
#                       Dry-run invokes neither tool.
#
# What only this script owns:
#   * df early-stop: used% on DF_PATH is read before each rule; once it is
#     <= TARGET_USED_PCT the run stops and records target-reached-after=<rule>.
#   * per-run caps: MAX_ENTRIES (top-level entries, not files) and MAX_BYTES.
#     They bound R1 (tmp-reaper) and R4 (bak) EXACTLY, and gate whether the NEXT
#     rule starts: R1 is handed the run's remaining budget
#     (TMP_REAPER_MAX_ENTRIES / TMP_REAPER_MAX_KIB) and stops at it; R4 checks
#     per entry. R2 (clone-sweep) and R3 (codex-prune) still run to completion
#     under their own policy, so a run can finish above a cap by at most one R2
#     or one R3 pass. The run then stops and reports cap-hit=<which> with the
#     overshot totals, exit 0.
#   * the apply gate: --apply is explicit; the default is a dry-run, and the
#     mode is propagated to every delegate.
#   * flock, the host guard, the structural root guard, ONE Slack report.
#     The report is posted in dry-run too: that is how a first run is read.
#
# Never touched: anything outside the delegates' own allow-lists, BAK_ROOTS
# patterns and the R7 job-dir rule; k8s/containerd state, journald (capped by install-aux-units.sh),
# /var/lib/hydra-release, /etc/tmpfiles.d/tmp.conf, /opt/hydra/audit.
#
# Rollback: stop the timer (systemctl disable --now hydra-weekly-cleanup.timer);
# the script is stateless apart from the apt watermark file.
#
# Exit contract (never mask real breakage as success):
#   0  normal run, including cap-hit and target-reached. Per-file rm errors
#      are counted + reported, NOT unit failures.
#   1  structural refusal (tmp root missing/symlinked/suspicious), or a
#      delegate exited 1
#   2  usage error / missing dependency, or a delegate exited 2
#   Any other non-zero delegate rc is propagated as is. A delegate failure
#   does not stop the later rules: the summary and Slack post happen first,
#   then the FIRST non-zero child rc surfaces.
#
# Flags:
#   --apply     delete for real
#   --dry-run   the default; walk everything, delete nothing, still post
#
# Env knobs (mainly for tests; defaults target production):
#   CLEAN_MY_LINUX_TARGET_USED_PCT   default 65
#   CLEAN_MY_LINUX_MAX_ENTRIES       default 25000
#   CLEAN_MY_LINUX_MAX_BYTES         default 161061273600 (150 GiB)
#   CLEAN_MY_LINUX_DF_PATH           default /
#   CLEAN_MY_LINUX_TMP_ROOT          default /tmp (passed to tmp-reaper)
#   CLEAN_MY_LINUX_BAK_ROOTS         default "/opt/hydra /root/hydra-hotpatch-backups"
#   CLEAN_MY_LINUX_BAK_AGE_DAYS      default 30
#   CLEAN_MY_LINUX_STATE_DIR         default /var/lib/hydra/clean-my-linux
#   CLEAN_MY_LINUX_SKIP_APT          1 = skip apt-get step
#   CLEAN_MY_LINUX_RUNNER_WORK       default /opt/actions-runner/_work (R7; must be named _work)
#   CLEAN_MY_LINUX_DOCKER_BIN / _CRICTL_BIN   default docker / crictl (R9; tests)
#   CLEAN_MY_LINUX_SKIP_SWEEP        1 = skip R2 (the bats suite MUST stub or set it)
#   CLEAN_MY_LINUX_TMP_REAPER / _SWEEP_SCRIPT / _CODEX_PRUNE   delegate paths (tests)
#   CLEAN_MY_LINUX_SLACK_CHANNEL     default C0ADV2W76G4 (#clio_devops)
#   CLEAN_MY_LINUX_LOCKFILE          single-run lock
#   CLEAN_MY_LINUX_SKIP_HOST_GUARD   1 = skip the ovh-node-8 guard (tests)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

LOGPREFIX="[clean-my-linux $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
_CLEANUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_ROOT="${CLEAN_MY_LINUX_TMP_ROOT:-/tmp}"
BAK_ROOTS="${CLEAN_MY_LINUX_BAK_ROOTS:-/opt/hydra /root/hydra-hotpatch-backups}"
BAK_AGE_DAYS="${CLEAN_MY_LINUX_BAK_AGE_DAYS:-30}"
TARGET_USED_PCT="${CLEAN_MY_LINUX_TARGET_USED_PCT:-65}"
MAX_ENTRIES="${CLEAN_MY_LINUX_MAX_ENTRIES:-25000}"
MAX_BYTES="${CLEAN_MY_LINUX_MAX_BYTES:-161061273600}"
DF_PATH="${CLEAN_MY_LINUX_DF_PATH:-/}"
STATE_DIR="${CLEAN_MY_LINUX_STATE_DIR:-/var/lib/hydra/clean-my-linux}"
SKIP_APT="${CLEAN_MY_LINUX_SKIP_APT:-0}"
LOCKFILE="${CLEAN_MY_LINUX_LOCKFILE:-/var/run/hydra-clean-my-linux.lock}"
SKIP_HOST_GUARD="${CLEAN_MY_LINUX_SKIP_HOST_GUARD:-0}"
TMP_REAPER="${CLEAN_MY_LINUX_TMP_REAPER:-$_CLEANUP_DIR/tmp-reaper.sh}"
SWEEP_SCRIPT="${CLEAN_MY_LINUX_SWEEP_SCRIPT:-$_CLEANUP_DIR/sweep-workspace-clones.sh}"
CODEX_PRUNE="${CLEAN_MY_LINUX_CODEX_PRUNE:-$_CLEANUP_DIR/codex-home-prune.sh}"
RUNNER_WORK="${CLEAN_MY_LINUX_RUNNER_WORK:-/opt/actions-runner/_work}"
DOCKER_BIN="${CLEAN_MY_LINUX_DOCKER_BIN:-docker}"
CRICTL_BIN="${CLEAN_MY_LINUX_CRICTL_BIN:-crictl}"
APT_WATERMARK_MIN=1440
RUNNER_JOB_MIN=1440      # R7: a job dir is a candidate only if nothing in it changed for 24h
CONTAINER_GATE_PCT=80    # R9: runs only when used% is strictly above this
CONTAINER_TIMEOUT=900    # R9: a hung prune must not hold the single-run lock forever
APPLY=0

# slack-notify.sh reads this (target channel).
# Export before sourcing so its `:=` default doesn't override us.
export SLACK_CHANNEL="${CLEAN_MY_LINUX_SLACK_CHANNEL:-C0ADV2W76G4}"  # #clio_devops

log() { echo "$LOGPREFIX $1"; }

for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --dry-run) APPLY=0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done
MODE="dry-run"; [ "$APPLY" -eq 1 ] && MODE="apply"

for v in TARGET_USED_PCT MAX_ENTRIES MAX_BYTES BAK_AGE_DAYS; do
  case "${!v}" in
    ''|*[!0-9]*) echo "clean-my-linux.sh: CLEAN_MY_LINUX_$v must be a non-negative integer, got '${!v}'" >&2; exit 2 ;;
  esac
  printf -v "$v" '%d' "$((10#${!v}))"  # "08" is invalid octal in $(( ))
done

# shellcheck source=lib/slack-notify.sh
source "$_CLEANUP_DIR/lib/slack-notify.sh"
# shellcheck source=lib/safe-delete.sh
source "$_CLEANUP_DIR/lib/safe-delete.sh"

command -v python3 >/dev/null 2>&1 || { log "ERROR: python3 required but not on PATH"; exit 2; }

RULES=(tmp-reaper clone-sweep codex-prune bak apt runner-work container-layers)
declare -A rule_status=()
for _r in "${RULES[@]}"; do rule_status[$_r]="not-run"; done
entries_total=0; kb_total=0
cap_hit=""; target_reached=""
child_rc=0   # FIRST non-zero delegate exit code; propagated at exit
bak_deleted=0; bak_errors=0
runner_deleted=0; runner_held=0; runner_errors=0

ERRORS_FILE="$(mktemp)"
PAYLOAD_FILE="$(mktemp)"
trap 'rm -f "$ERRORS_FILE" "$PAYLOAD_FILE"' EXIT

# Size in KB, measured BEFORE rm; added to the freed total only if the rm
# succeeds. du-then-rm is at worst slightly stale for a still-growing file.
entry_kb() {
  local kb
  kb="$(du -sk --one-file-system -- "$1" 2>/dev/null | awk '{print $1}' || true)"
  echo "${kb:-0}"
}

# Used% on DF_PATH. An unreadable df fails CLOSED to 100 (keep cleaning; the
# caps still bound the run) rather than reading as "already under target".
used_pct() {
  local u
  u="$(df -P "$DF_PATH" 2>/dev/null | awk 'NR==2 { gsub("%", "", $5); print $5 }' || true)"
  case "$u" in ''|*[!0-9]*) log "WARN: cannot read df for $DF_PATH, assuming 100%" >&2; u=100 ;; esac
  echo "$u"
}

# Sets cap_hit when the run's running totals reach either per-run cap.
check_caps() {
  [ -n "$cap_hit" ] && return 0
  if [ "$entries_total" -ge "$MAX_ENTRIES" ]; then
    cap_hit="entries"
  elif [ $((kb_total * 1024)) -ge "$MAX_BYTES" ]; then
    cap_hit="bytes"
  fi
  return 0
}

# ──────────────────────────────────────────────────────────────
# Structural guard: refuse to run against a tmp root we didn't audit.
# ──────────────────────────────────────────────────────────────
guard_tmp_root() {
  # Strip ALL trailing slashes before the root check, so "//" reads as "/".
  while [ "$TMP_ROOT" != "/" ] && [ "${TMP_ROOT%/}" != "$TMP_ROOT" ]; do
    TMP_ROOT="${TMP_ROOT%/}"
  done
  if [ -z "$TMP_ROOT" ] || [ "$TMP_ROOT" = "/" ]; then
    log "FATAL: refusing to run with TMP_ROOT='$TMP_ROOT'"; exit 1
  fi
  if [ -L "$TMP_ROOT" ]; then
    log "FATAL: TMP_ROOT is a symlink: $TMP_ROOT"; exit 1
  fi
  if [ ! -d "$TMP_ROOT" ]; then
    log "FATAL: TMP_ROOT is not a directory: $TMP_ROOT"; exit 1
  fi
  local rp
  rp="$(realpath -- "$TMP_ROOT" 2>/dev/null)" || { log "FATAL: realpath failed for $TMP_ROOT"; exit 1; }
  if [ "$rp" = "/" ]; then
    log "FATAL: TMP_ROOT resolves to the filesystem root: $TMP_ROOT"; exit 1
  fi
  if [ "$rp" != "$TMP_ROOT" ]; then
    log "FATAL: TMP_ROOT resolves elsewhere ($TMP_ROOT -> $rp)"; exit 1
  fi
}

# Last `key=<digits>` in a blob, 0 if absent.
kv() {
  local v
  v="$(printf '%s\n' "$1" | grep -oE "(^|[^A-Za-z_])$2=[0-9]+" | tail -1 | sed 's/.*=//' || true)"
  echo "${v:-0}"
}

# run_delegate <rule> <script> <flag>
# Runs one delegate in the propagated mode, echoes its output (left in
# $delegate_out for the caller to parse) and records its rc.
delegate_out=""
run_delegate() {
  local rule="$1" script="$2" flag="$3" rc=0
  delegate_out="$("$script" "$flag" 2>&1)" || rc=$?
  printf '%s\n' "$delegate_out"
  if [ "$rc" -ne 0 ]; then
    rule_status[$rule]="failed (exit $rc)"
    echo "$(basename "$script") failed (exit $rc)" >> "$ERRORS_FILE"
    [ "$child_rc" -eq 0 ] && child_rc="$rc"
    return 0
  fi
  rule_status[$rule]="ok"
}

rule_tmp_reaper() {
  local flag="--dry-run"; [ "$APPLY" -eq 1 ] && flag="--apply"
  # Hand over the REMAINING budget (clamped at 0; the pre-rule check_caps means
  # it is never <= 0 here, but never pass a negative).
  local left_entries=$((MAX_ENTRIES - entries_total)) left_kib=$((MAX_BYTES / 1024 - kb_total))
  [ "$left_entries" -lt 0 ] && left_entries=0
  [ "$left_kib" -lt 0 ] && left_kib=0
  TMP_REAPER_ROOT="$TMP_ROOT" TMP_REAPER_MAX_ENTRIES="$left_entries" TMP_REAPER_MAX_KIB="$left_kib" \
    run_delegate tmp-reaper "$TMP_REAPER" "$flag"
  entries_total=$((entries_total + $(kv "$delegate_out" reaped)))
  kb_total=$((kb_total + $(kv "$delegate_out" reclaimed_kib)))
  # A byte-budget stop keeps the next entry, so the totals may sit just under
  # the cap: record it as R4 does.
  # Anchored on the summary line: deleted-path lines can contain '='.
  if grep -qE '^tmp-reaper: done .* budget_hit=bytes$' <<<"$delegate_out" && [ -z "$cap_hit" ]; then cap_hit="bytes"; fi
}

rule_clone_sweep() {
  if [ "${CLEAN_MY_LINUX_SKIP_SWEEP:-0}" = "1" ]; then
    rule_status[clone-sweep]="skipped"; return 0
  fi
  local flag="--dry-run"; [ "$APPLY" -eq 1 ] && flag="--apply"
  run_delegate clone-sweep "$SWEEP_SCRIPT" "$flag"
  entries_total=$((entries_total + $(kv "$delegate_out" swept_clones) + $(kv "$delegate_out" junk)))
  kb_total=$((kb_total + $(kv "$delegate_out" freed_kb)))
}

rule_codex_prune() {
  if [ ! -x "$CODEX_PRUNE" ]; then
    rule_status[codex-prune]="skipped (script missing)"
    log "codex-prune: $CODEX_PRUNE missing or not executable, skipped"
    return 0
  fi
  local flag="--dry-run" bytes files
  [ "$APPLY" -eq 1 ] && flag="--apply"
  run_delegate codex-prune "$CODEX_PRUNE" "$flag"
  bytes=$(( $(kv "$delegate_out" total_freed_bytes) + $(kv "$delegate_out" total_would_free_bytes) ))
  files="$(printf '%s\n' "$delegate_out" | grep -oE 'sessions_files=[0-9]+' | sed 's/.*=//' | paste -sd+ - || true)"
  entries_total=$((entries_total + ${files:-0}))
  kb_total=$((kb_total + bytes / 1024))
}

# ──────────────────────────────────────────────────────────────
# R4: aged hot-patch backups under one root (in-script, tight patterns)
# ──────────────────────────────────────────────────────────────
clean_bak_root() {
  local root="$1" p kb err
  if [ ! -d "$root" ]; then
    log "bak root missing, skipped: $root"
    return 0
  fi
  while IFS= read -r -d '' p; do
    check_caps
    [ -n "$cap_hit" ] && break
    kb="$(entry_kb "$p")"
    if [ $(( (kb_total + kb) * 1024 )) -gt "$MAX_BYTES" ]; then
      cap_hit="bytes"
      break
    fi
    if [ "$APPLY" -eq 0 ]; then
      log "DRY-RUN: would delete $p (${kb} KB)"
    else
      err="$(rm -f -- "$p" 2>&1)" || {
        bak_errors=$((bak_errors + 1))
        echo "rm failed: $p: ${err:0:200}" >> "$ERRORS_FILE"
        continue
      }
    fi
    bak_deleted=$((bak_deleted + 1))
    entries_total=$((entries_total + 1)); kb_total=$((kb_total + kb))
  done < <(find "$root" -xdev -type f \
      \( -name '*.bak' -o -name '*.bak.*' -o -name '*.bak-*' -o -name '*.orig' \) \
      -mtime +"$BAK_AGE_DAYS" -print0 2>/dev/null)
}

rule_bak() {
  local root
  for root in $BAK_ROOTS; do
    clean_bak_root "$root"
    [ -n "$cap_hit" ] && break
  done
  rule_status[bak]="ok"
}

# ──────────────────────────────────────────────────────────────
# R5: apt junk, at most once per 24h
# ──────────────────────────────────────────────────────────────
rule_apt() {
  local mark="$STATE_DIR/apt.last"
  if [ "$SKIP_APT" = "1" ]; then
    rule_status[apt]="skipped"; return 0
  fi
  if [ -e "$mark" ] && [ -n "$(find "$mark" -mmin -"$APT_WATERMARK_MIN" -print -quit 2>/dev/null)" ]; then
    rule_status[apt]="skipped (ran <24h ago)"; return 0
  fi
  if [ "$APPLY" -eq 0 ]; then
    rule_status[apt]="skipped (dry-run)"
    log "DRY-RUN: would run apt-get autoremove --purge + autoclean"
    return 0
  fi
  if apt-get -y autoremove --purge >/dev/null 2>&1 \
     && apt-get -y autoclean >/dev/null 2>&1; then
    rule_status[apt]="ok"
    { mkdir -p "$STATE_DIR" && touch "$mark"; } 2>/dev/null \
      || echo "apt watermark not writable: $mark" >> "$ERRORS_FILE"
  else
    rule_status[apt]="failed"
    echo "apt-get autoremove/autoclean failed" >> "$ERRORS_FILE"
  fi
}

# ──────────────────────────────────────────────────────────────
# R7: actions-runner job directories older than 24h
# ──────────────────────────────────────────────────────────────
# Post-quarantine hold for R7 (installed via SAFE_DELETE_HANDLE_CHECK, scoped to
# rule_runner_work by a `local`). Same seam as sweep-workspace-clones.sh's
# clone audit: the name is private by now so nothing new can enter the tree, and
# the lib restores the original name on a hold. Returns 0 = held. Runs inside
# the $( ) around safe_delete_path, so the reason goes out on stderr.
# shellcheck disable=SC2329  # invoked by lib/safe-delete.sh via SAFE_DELETE_HANDLE_CHECK
r7_post_quarantine_hold() {  # <quarantined-path>
  local q="$1" hit
  if ! hit="$(find "$RUNNER_WORK/_temp" -mindepth 1 -print -quit 2>/dev/null)" || [ -n "$hit" ]; then
    echo "runner-work: HOLD job started mid-sweep (_temp not empty or unreadable)" >&2
    return 0
  fi
  # rename(2) bumps ctime, not mtime, so these are still the pre-rename mtimes
  if ! hit="$(find "$q" -xdev -mmin -"$RUNNER_JOB_MIN" -print -quit 2>/dev/null)" || [ -n "$hit" ]; then
    echo "runner-work: HOLD tree modified inside the window (or unreadable)" >&2
    return 0
  fi
  safe_delete_has_open_handle "$q"
}

# A refused restore leaves a .safe-delete-quarantine.* tree inside _work that
# R7's own `! -name '.*'` filter can never reclaim: surface it, never leak it.
# shellcheck disable=SC2329  # optional hook called by lib/safe-delete.sh
safe_delete_on_restore_blocked() {  # <quarantined-path>
  runner_errors=$((runner_errors + 1))
  echo "runner-work: quarantine restore blocked (name retaken): LEFT QUARANTINED at $1, needs human review" >> "$ERRORS_FILE"
}

rule_runner_work() {
  local root="$RUNNER_WORK" rp marker p kb freed recent err_file msg cand ferr rc=0 status="ok"
  # Post-quarantine re-check (see r7_post_quarantine_hold); sweep-workspace-clones.sh has the other copy.
  # shellcheck disable=SC2034  # read by lib/safe-delete.sh at call time
  local SAFE_DELETE_HANDLE_CHECK=r7_post_quarantine_hold
  if [ -L "$root" ] || [ ! -d "$root" ]; then
    rule_status[runner-work]="skipped (runner work dir missing or a symlink)"
    log "runner-work: $root missing or a symlink, skipped"
    return 0
  fi
  rp="$(realpath -- "$root" 2>/dev/null)" || rp=""
  if [ "$rp" != "${root%/}" ] || [ "$(basename -- "$rp")" != "_work" ]; then
    rule_status[runner-work]="skipped (not a resolved _work dir)"
    log "runner-work: $root is not a resolved path named _work, skipped"
    return 0
  fi
  # _temp is empty while the runner is idle and holds step scripts / file
  # commands during a job. Missing or unreadable means this is not the layout
  # we audited: refuse rather than guess.
  if [ ! -d "$root/_temp" ] || ! marker="$(find "$root/_temp" -mindepth 1 -print -quit 2>/dev/null)"; then
    rule_status[runner-work]="skipped (cannot read _temp)"
    log "runner-work: $root/_temp missing or unreadable, skipped"
    return 0
  fi
  if [ -n "$marker" ]; then
    rule_status[runner-work]="skipped (active job marker in _temp)"
    log "runner-work: active job marker $marker, skipped"
    return 0
  fi
  err_file="$(mktemp)"; cand="$(mktemp)"; ferr="$(mktemp)"
  # Enumerate to a file so a find failure is seen (a process substitution hides it).
  find "$root" -mindepth 1 -maxdepth 1 -xdev -type d ! -name '_*' ! -name '.*' \
      -mmin +"$RUNNER_JOB_MIN" -print0 > "$cand" 2>"$ferr" || rc=$?
  if [ "$rc" -ne 0 ]; then
    runner_errors=$((runner_errors + 1))
    echo "runner-work: candidate scan failed (exit $rc): $(head -c 300 "$ferr")" >> "$ERRORS_FILE"
    status="error (candidate scan failed)"
  fi
  while IFS= read -r -d '' p; do
    check_caps
    [ -n "$cap_hit" ] && break
    # The dir's own mtime does not move when a file deep inside changes, so
    # ask for ANY entry (itself included) modified inside the window. A find
    # error is not "old": keep it and count it.
    if ! recent="$(find "$p" -xdev -mmin -"$RUNNER_JOB_MIN" -print -quit 2>/dev/null)"; then
      runner_errors=$((runner_errors + 1))
      echo "runner-work: cannot read $p, kept" >> "$ERRORS_FILE"
      continue
    fi
    [ -n "$recent" ] && continue
    kb="$(entry_kb "$p")"
    if [ $(( (kb_total + kb) * 1024 )) -gt "$MAX_BYTES" ]; then
      cap_hit="bytes"
      break
    fi
    if [ "$APPLY" -eq 0 ]; then
      if safe_delete_has_open_handle "$p"; then runner_held=$((runner_held + 1)); continue; fi
      log "DRY-RUN: would delete $p (${kb} KB)"
    else
      if freed="$(safe_delete_path "$p" 2>"$err_file")"; then
        kb="${freed:-$kb}"
      else
        msg="$(head -c 300 "$err_file")"
        if [[ "$msg" == *"HOLD job started mid-sweep"* ]]; then
          runner_held=$((runner_held + 1))
          status="partial (job started mid-sweep, stopped after $runner_deleted)"
          log "runner-work: ${msg:0:200}"
          break
        elif [[ "$msg" == *"HOLD tree modified"* ]]; then
          runner_held=$((runner_held + 1))
        elif [[ "$msg" == *"open handle"* || "$msg" == *"holds the tree open"* ]]; then
          runner_held=$((runner_held + 1))
        else
          runner_errors=$((runner_errors + 1))
          echo "runner-work: ${msg:0:200}" >> "$ERRORS_FILE"
        fi
        continue
      fi
    fi
    runner_deleted=$((runner_deleted + 1))
    entries_total=$((entries_total + 1)); kb_total=$((kb_total + kb))
  done < "$cand"
  /bin/rm -f "$err_file" "$cand" "$ferr"
  rule_status[runner-work]="$status"
}

# ──────────────────────────────────────────────────────────────
# R9: container layers, ONLY when the disk is still above the gate
# ──────────────────────────────────────────────────────────────
# One tool, one fixed argv. The argv is spelled out at each call site on purpose:
# no variable, no flag list, so a future "-a" or "--volumes" is a visible diff
# and fails the argv assertion in clean-my-linux.bats.
rule_container_layers() {
  local pct out rc parts=() failed=0 usable=0
  pct="$(used_pct)"
  if [ "$pct" -le "$CONTAINER_GATE_PCT" ]; then
    rule_status[container-layers]="skipped (used ${pct}% <= ${CONTAINER_GATE_PCT}% gate)"
    return 0
  fi
  if [ "$APPLY" -eq 0 ]; then
    rule_status[container-layers]="skipped (dry-run)"
    log "DRY-RUN: would run docker image prune -f and crictl rmi --prune (used ${pct}% > ${CONTAINER_GATE_PCT}%)"
    return 0
  fi
  log "container-layers: used ${pct}% > ${CONTAINER_GATE_PCT}%, pruning dangling images"
  if command -v "$DOCKER_BIN" >/dev/null 2>&1; then
    usable=1; rc=0
    out="$(timeout "$CONTAINER_TIMEOUT" "$DOCKER_BIN" image prune -f 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ]; then parts+=("docker ok"); else
      failed=1; parts+=("docker exit $rc")
      echo "docker image prune -f failed (exit $rc): ${out: -200}" >> "$ERRORS_FILE"
    fi
  else
    parts+=("docker unavailable")
  fi
  if command -v "$CRICTL_BIN" >/dev/null 2>&1; then
    usable=1; rc=0
    out="$(timeout "$CONTAINER_TIMEOUT" "$CRICTL_BIN" rmi --prune 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ]; then parts+=("crictl ok"); else
      failed=1; parts+=("crictl exit $rc")
      echo "crictl rmi --prune failed (exit $rc): ${out: -200}" >> "$ERRORS_FILE"
    fi
  else
    parts+=("crictl unavailable")
  fi
  local IFS=,
  if [ "$usable" -eq 0 ]; then rule_status[container-layers]="unavailable (${parts[*]})"
  elif [ "$failed" -eq 1 ]; then rule_status[container-layers]="failed (${parts[*]})"
  else rule_status[container-layers]="ok (${parts[*]})"; fi
}

# ──────────────────────────────────────────────────────────────
# Summary: stdout lines + Block Kit payload (one post per run)
# ──────────────────────────────────────────────────────────────
print_summary() {
  local r
  log "mode=$MODE"
  for r in "${RULES[@]}"; do log "rule $r: ${rule_status[$r]}"; done
  log "bak: deleted=$bak_deleted errors=$bak_errors"
  log "runner-work: deleted=$runner_deleted held=$runner_held errors=$runner_errors"
  [ -n "$target_reached" ] && log "target-reached-after=$target_reached (<= ${TARGET_USED_PCT}%)"
  [ -n "$cap_hit" ] && log "cap-hit=$cap_hit (entries=$entries_total kb=$kb_total)"
  log "TOTAL entries=$entries_total freed_kb=$kb_total"
}

# Build the exact Slack payload in Python: error strings contain quotes
# and backticks that would shatter a naive bash JSON interpolation.
build_payload() {
  local r rules=""
  for r in "${RULES[@]}"; do rules+="$r|${rule_status[$r]}"$'\n'; done
  MODE="$MODE" RULES_STATUS="$rules" ENTRIES="$entries_total" TOTAL_KB="$kb_total" \
  CAP_HIT="$cap_hit" TARGET_REACHED="$target_reached" TARGET_PCT="$TARGET_USED_PCT" \
  ERRORS_FILE="$ERRORS_FILE" \
  PAYLOAD_OUT="$PAYLOAD_FILE" SLACK_CHANNEL="$SLACK_CHANNEL" python3 - <<'PYEOF'
import json, os

e = os.environ
total_kb = int(e["TOTAL_KB"])

def human(kb):
    if kb >= 1024 * 1024:
        return f"{kb / 1024 / 1024:.1f} GB"
    if kb >= 1024:
        return f"{kb / 1024:.1f} MB"
    return f"{kb} KB"

rules = [l.split("|", 1) for l in e["RULES_STATUS"].splitlines() if "|" in l]
lines = []
try:
    with open(e["ERRORS_FILE"]) as f:
        lines = [l.rstrip() for l in f if l.strip()]
except Exception:
    pass
errors = len(lines)
tag = "DRY-RUN" if e["MODE"] == "dry-run" else "apply"
verb = "would free" if e["MODE"] == "dry-run" else "freed"
stop = ""
if e["CAP_HIT"]:
    stop = f" | cap-hit={e['CAP_HIT']}"
elif e["TARGET_REACHED"]:
    stop = f" | target-reached-after={e['TARGET_REACHED']}"

text = (f":broom: clean-my-linux node-8 [{tag}] — {verb} {human(total_kb)} | "
        f"entries={e['ENTRIES']}{stop} | errors={errors}")

blocks = [
    {"type": "header", "text": {"type": "plain_text", "text": f"clean-my-linux — node-8 ({tag})"}},
    {"type": "section", "fields": (
        [{"type": "mrkdwn", "text": f"*{verb.capitalize()}:*\n{human(total_kb)} · {e['ENTRIES']} entries"}]
        + [{"type": "mrkdwn", "text": f"*{n}:*\n{s}"} for n, s in rules]
    )},
]
if stop:
    blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": f"*stop:*{stop[2:]}"}})
if errors:
    detail = "\n".join(f"• {l}" for l in lines[:10])
    blocks.append({"type": "section", "text": {
        "type": "mrkdwn", "text": f":warning: {errors} error(s):\n{detail}"}})

with open(e["PAYLOAD_OUT"], "w") as f:
    json.dump({"channel": e["SLACK_CHANNEL"], "text": text, "blocks": blocks}, f)
PYEOF
}

# ──────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────

# Host guard: wrong node → no-op (prevents an orphaned timer from
# firing after a host migration). Skippable for tests.
if [ "$SKIP_HOST_GUARD" != "1" ] && ! hostname | grep -q '^ovh-node-8$'; then
  log "SKIP: hostname is not ovh-node-8 ($(hostname)) — script is node-8-specific"
  exit 0
fi

guard_tmp_root

# Single-run lock so overlapping invocations never double-delete/post.
exec 9>"$LOCKFILE"
flock -n 9 || { log "SKIP: another clean-my-linux run holds $LOCKFILE"; exit 0; }

prev=""
# A zero cap means a zero budget: check before the first rule can delete.
check_caps
for rule in "${RULES[@]}"; do
  [ -n "$cap_hit" ] && break
  if [ "$(used_pct)" -le "$TARGET_USED_PCT" ]; then
    target_reached="${prev:-none}"
    break
  fi
  case "$rule" in
    tmp-reaper) rule_tmp_reaper ;;
    clone-sweep) rule_clone_sweep ;;
    codex-prune) rule_codex_prune ;;
    bak) rule_bak ;;
    apt) rule_apt ;;
    runner-work) rule_runner_work ;;
    container-layers) rule_container_layers ;;
  esac
  check_caps
  prev="$rule"
done

print_summary
build_payload
log "Posting summary to ${SLACK_CHANNEL}."
slack_notify_payload_file "$PAYLOAD_FILE"

# Summary and Slack post happen FIRST, then the failure surfaces: a masked
# delegate failure would leave systemd reporting a healthy run for a
# category that never ran.
exit "$child_rc"
