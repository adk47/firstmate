#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# codex-home-prune.sh — retention for the codex binary's per-agent state under
# ${CODEX_HOME_GLOB:-/root/.openclaw-*/agents/*/agent/codex-home}. Codex writes
# session transcripts and logs_*.sqlite there and exposes no retention knob
# (docs/runbooks/RUNBOOK.md), so nothing ages them out but this.
#
#   sessions/**/rollout-*.jsonl   older than CODEX_SESSION_TTL_DAYS -> deleted
#   logs_*.sqlite                 rows with ts < cutoff -> DELETEd, WAL truncated,
#                                 VACUUM only if the filesystem is < 80% used
#                                 and free bytes >= 2x that DB's size
#
# Default is --dry-run: nothing is changed, per-agent bytes that WOULD be freed
# are printed. --apply does the work. Never run by hand against node-8 without
# the board's go; the timer runs it with --apply.
#
# Hard rules (MUS-5584):
#   * VACUUM needs free space ~ the DB size; on a full disk it deepens the
#     incident it is meant to relieve, so it is gated on `df` and otherwise
#     skipped with a logged reason (freed pages are reused by codex).
#   * These DBs hold a live token in plaintext. Only counts and byte sums are
#     ever selected or printed -- never a row, never feedback_log_body -- and
#     nothing is copied off the box.
#   * A DB codex holds locked is a logged skip, not a failure. This script
#     never touches a gateway process.
#
# Env:
#   CODEX_HOME_GLOB            default /root/.openclaw-*/agents/*/agent/codex-home
#   CODEX_SESSION_TTL_DAYS     default 14; positive integer (files and log rows)
#   CODEX_VACUUM_MAX_USED_PCT  default 80; VACUUM only when the codex-home filesystem is below this
#   CODEX_PRUNE_BUSY_MS        default 5000; sqlite busy timeout
#
# Exit codes: 0 ok (incl. locked skips) | 1 a DB step failed | 2 bad argument
#             5 invalid env
# ──────────────────────────────────────────────────────────────
set -euo pipefail

: "${CODEX_HOME_GLOB:=/root/.openclaw-*/agents/*/agent/codex-home}"
: "${CODEX_SESSION_TTL_DAYS:=14}"
: "${CODEX_VACUUM_MAX_USED_PCT:=80}"
: "${CODEX_PRUNE_BUSY_MS:=5000}"

apply=0
case "${1:-}" in
  ''|--dry-run) ;;
  --apply) apply=1 ;;
  *) echo "codex-home-prune.sh: usage: $0 [--dry-run|--apply]" >&2; exit 2 ;;
esac

for v in CODEX_SESSION_TTL_DAYS CODEX_VACUUM_MAX_USED_PCT CODEX_PRUNE_BUSY_MS; do
  case "${!v}" in ''|*[!0-9]*) echo "codex-home-prune.sh: $v must be a non-negative integer (got: ${!v})" >&2; exit 5 ;; esac
  printf -v "$v" '%d' "$((10#${!v}))"
done
if [ "$CODEX_SESSION_TTL_DAYS" -eq 0 ]; then
  echo "codex-home-prune.sh: CODEX_SESSION_TTL_DAYS must be a positive integer (got a zero value)" >&2
  exit 5
fi
command -v sqlite3 >/dev/null 2>&1 || { echo "codex-home-prune.sh: sqlite3 is required" >&2; exit 5; }

log() { echo "codex-home-prune.sh: $*"; }

cutoff_ts=$(( $(date -u +%s) - CODEX_SESSION_TTL_DAYS * 86400 ))
ttl_min=$(( CODEX_SESSION_TTL_DAYS * 1440 ))
mode=dry-run; [ "$apply" -eq 1 ] && mode=apply

shopt -s nullglob
# shellcheck disable=SC2206
homes=($CODEX_HOME_GLOB)
shopt -u nullglob

if [ "${#homes[@]}" -eq 0 ]; then
  log "no codex-home dirs match $CODEX_HOME_GLOB -- nothing to prune"
  exit 0
fi

used_pct="$(df -P "${homes[0]}" | awk 'NR==2 { gsub("%", "", $5); print $5 }')"
case "$used_pct" in ''|*[!0-9]*) used_pct=100 ;; esac # unreadable -> treat as full, never VACUUM
if [ "$used_pct" -lt "$CODEX_VACUUM_MAX_USED_PCT" ]; then vacuum_ok=1; else vacuum_ok=0; fi

sq() { sqlite3 -cmd ".timeout $CODEX_PRUNE_BUSY_MS" "$@"; }

is_locked() { grep -qiE 'database (table )?is locked|busy'; }

rc=0
grand_total=0
found="$(mktemp)"; trap 'rm -f "$found"' EXIT

log "mode=$mode ttl_days=$CODEX_SESSION_TTL_DAYS fs_used_pct=$used_pct vacuum_allowed=$vacuum_ok"

for home in "${homes[@]}"; do
  # <profile>/<agent> label from .../<profile>/agents/<agent>/agent/codex-home
  agent_dir="${home%/agent/codex-home}"
  label="$(basename "$(dirname "$(dirname "$agent_dir")")")/$(basename "$agent_dir")"

  # ── sessions: rollout-*.jsonl past the TTL ──
  s_files=0; s_bytes=0
  # find runs to a file, not a process substitution, so its exit status is
  # visible: a traversal error (EIO, EACCES) leaves old rollouts behind and
  # must turn the unattended timer red instead of passing as a clean run.
  if [ -d "$home/sessions" ]; then
    fst=0; find "$home/sessions" -type f -name 'rollout-*.jsonl' -mmin +"$ttl_min" -print0 >"$found" 2>/dev/null || fst=$?
    if [ "$fst" -ne 0 ]; then log "WARN $label sessions traversal failed (find exit $fst) -- some old rollouts may remain"; rc=1; fi
  else : >"$found"; fi
  while IFS= read -r -d '' f; do
    sz="$(wc -c < "$f" 2>/dev/null | tr -d '[:space:]')" || sz=0
    if [ "$apply" -eq 1 ]; then
      rm -f -- "$f" || { log "WARN $label rm failed for a rollout file -- skipped"; rc=1; continue; }
    fi
    s_bytes=$(( s_bytes + ${sz:-0} )); s_files=$(( s_files + 1 ))
  done <"$found"

  # ── logs_*.sqlite: rows past the TTL ──
  l_rows=0; l_bytes=0
  for db in "$home"/logs_*.sqlite; do
    [ -f "$db" ] || continue
    name="$(basename "$db")"

    # Apply opens read-write: a WAL DB with no -wal/-shm sidecars (idle codex)
    # cannot be opened -readonly. Dry-run falls back to an immutable open.
    count_sql="SELECT COUNT(*), COALESCE(SUM(estimated_bytes),0) FROM logs WHERE ts < $cutoff_ts;"
    st=0
    if [ "$apply" -eq 1 ]; then out="$(sq "$db" "$count_sql" 2>&1)" || st=$?
    else out="$(sq -readonly "$db" "$count_sql" 2>&1)" || out="$(sq "file:$db?immutable=1" "$count_sql" 2>&1)" || st=$?
    fi
    if [ "$st" -ne 0 ]; then
      if printf '%s' "$out" | is_locked; then log "WARN $label/$name locked -- skipped, will retry next run"
      else log "WARN $label/$name unreadable -- skipped"; rc=1; fi
      continue
    fi
    rows="${out%%|*}"; bytes="${out##*|}"
    case "$rows$bytes" in ''|*[!0-9]*) log "WARN $label/$name unexpected count output -- skipped"; rc=1; continue ;; esac
    l_rows=$(( l_rows + rows )); l_bytes=$(( l_bytes + bytes ))
    [ "$apply" -eq 1 ] || continue

    if [ "$rows" -gt 0 ]; then
      if ! out="$(sq "$db" "DELETE FROM logs WHERE ts < $cutoff_ts;" 2>&1)"; then
        if printf '%s' "$out" | is_locked; then log "WARN $label/$name locked -- skipped, will retry next run"
        else log "WARN $label/$name delete failed -- skipped"; rc=1; fi
        continue
      fi
    fi

    # busy=1 in the first column means codex held the DB and nothing was truncated.
    st=0; out="$(sq "$db" "PRAGMA wal_checkpoint(TRUNCATE);" 2>&1)" || st=$?
    if [ "$st" -ne 0 ] && ! printf '%s' "$out" | is_locked; then
      log "WARN $label/$name checkpoint failed -- continuing"; rc=1
    elif [ "$st" -ne 0 ] || [ "${out%%|*}" != "0" ]; then
      log "WARN $label/$name checkpoint refused (locked by codex) -- skipped, will retry next run"
    fi

    if [ "$rows" -gt 0 ]; then
      # VACUUM rewrites the DB: it needs free bytes ~ this DB's size, so the
      # percent gate alone is not enough (79% of 100 GiB leaves 21 GiB free).
      db_bytes="$(wc -c < "$db" | tr -d '[:space:]')"
      avail_bytes=$(( $(df -Pk "$db" | awk 'NR==2 { print $4 }') * 1024 )) 2>/dev/null || avail_bytes=0
      if [ "$vacuum_ok" -eq 1 ] && [ "$avail_bytes" -lt $(( db_bytes * 2 )) ]; then
        log "$label/$name VACUUM skipped: ${avail_bytes} bytes free < 2x DB size ${db_bytes} (freed pages stay reusable)"
      elif [ "$vacuum_ok" -eq 1 ]; then
        if ! out="$(sq "$db" "VACUUM;" 2>&1)"; then
          log "WARN $label/$name VACUUM failed -- continuing"
          printf '%s' "$out" | is_locked || rc=1
        fi
      else
        log "$label/$name VACUUM skipped: filesystem ${used_pct}% used >= ${CODEX_VACUUM_MAX_USED_PCT}% (freed pages stay reusable)"
      fi
    fi
  done

  total=$(( s_bytes + l_bytes ))
  grand_total=$(( grand_total + total ))
  if [ "$apply" -eq 1 ]; then verb=freed; else verb=would_free; fi
  log "agent=$label sessions_files=$s_files sessions_bytes=$s_bytes log_rows=$l_rows log_bytes_est=$l_bytes ${verb}_bytes=$total"
done

if [ "$apply" -eq 1 ]; then verb=freed; else verb=would_free; fi
log "done. mode=$mode agents=${#homes[@]} total_${verb}_bytes=$grand_total"
exit "$rc"
