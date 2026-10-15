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
# Rule table, run in this order (cheapest-safe first):
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
#
# What only this script owns:
#   * df early-stop: used% on DF_PATH is read before each rule; once it is
#     <= TARGET_USED_PCT the run stops and records target-reached-after=<rule>.
#   * per-run caps: MAX_ENTRIES (top-level entries, not files) and MAX_BYTES.
#     Either one reached => stop the run, cap-hit=<which>, exit 0. R4 is
#     checked per entry; a delegate runs to completion and is checked after it
#     (its own policy bounds it), so a cap can be overshot by one delegate.
#   * the apply gate: --apply is explicit; the default is a dry-run, and the
#     mode is propagated to every delegate.
#   * flock, the host guard, the structural root guard, ONE Slack report.
#     The report is posted in dry-run too: that is how a first run is read.
#
# Never touched: anything outside the delegates' own allow-lists and BAK_ROOTS
# patterns; k8s/containerd state, journald (capped by install-aux-units.sh),
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
APT_WATERMARK_MIN=1440
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

command -v python3 >/dev/null 2>&1 || { log "ERROR: python3 required but not on PATH"; exit 2; }

RULES=(tmp-reaper clone-sweep codex-prune bak apt)
declare -A rule_status=()
for _r in "${RULES[@]}"; do rule_status[$_r]="not-run"; done
entries_total=0; kb_total=0
cap_hit=""; target_reached=""
child_rc=0   # FIRST non-zero delegate exit code; propagated at exit
bak_deleted=0; bak_errors=0

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
  if [ -z "$TMP_ROOT" ] || [ "$TMP_ROOT" = "/" ]; then
    log "FATAL: refusing to run with TMP_ROOT='$TMP_ROOT'"; exit 1
  fi
  TMP_ROOT="${TMP_ROOT%/}"
  if [ -L "$TMP_ROOT" ]; then
    log "FATAL: TMP_ROOT is a symlink: $TMP_ROOT"; exit 1
  fi
  if [ ! -d "$TMP_ROOT" ]; then
    log "FATAL: TMP_ROOT is not a directory: $TMP_ROOT"; exit 1
  fi
  local rp
  rp="$(realpath -- "$TMP_ROOT" 2>/dev/null)" || { log "FATAL: realpath failed for $TMP_ROOT"; exit 1; }
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
  TMP_REAPER_ROOT="$TMP_ROOT" run_delegate tmp-reaper "$TMP_REAPER" "$flag"
  entries_total=$((entries_total + $(kv "$delegate_out" reaped)))
  kb_total=$((kb_total + $(kv "$delegate_out" reclaimed_kib)))
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
# Summary: stdout lines + Block Kit payload (one post per run)
# ──────────────────────────────────────────────────────────────
print_summary() {
  local r
  log "mode=$MODE"
  for r in "${RULES[@]}"; do log "rule $r: ${rule_status[$r]}"; done
  log "bak: deleted=$bak_deleted errors=$bak_errors"
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
