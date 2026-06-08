#!/usr/bin/env bash
# ensure-codex-refresh-lock-shared.sh — converge every codex gateway process's
# OAuth refresh-lock directory onto ONE physical directory, idempotently, so
# openclaw's own cross-process refresh lock actually excludes ACROSS processes.
#
# ── The bug this closes (2026-06-08 fleet-wide codex outage) ─────────────────
# Hydra runs TWO gateway OS processes that both use codex (ChatGPT OAuth):
#   --profile main  (state dir /root/.openclaw-main)
#   --profile edge  (state dir /root/.openclaw-edge)   ← Caroline/support
# Their auth-profiles.json is ONE canonical store shared via symlink
# (ensure-codex-auth.sh), so both processes refresh the SAME single-use
# rotating refresh token.
#
# openclaw 2026.5.27 already serializes codex refresh with a real cross-process
# file lock acquired via fs.open(path,'wx') (O_EXCL) at
#   <stateDir>/locks/oauth-refresh/sha256-<hash(provider\0profileId)>
# (path-resolve-DsZZvktq.js:49, sidecar-lock-Bv7C32CP.js). The lock filename is
# IDENTICAL across both processes (same provider+profileId). It fails ONLY
# because each process derives <stateDir> from its own --profile, so main's lock
# lands in /root/.openclaw-main/locks/oauth-refresh/ and edge's in
# /root/.openclaw-edge/locks/oauth-refresh/ — two different physical files that
# never mutually exclude. So at the 5-min pre-expiry margin both processes
# refreshed at once, one rotated the single-use token and won the disk write, the
# loser POSTed the now-spent token → 401 refresh_token_reused, and the only
# freshly-minted valid token was clobbered → whole codex fleet dead until
# interactive re-auth. (Upstream openclaw#3611 is this exact cross-state-dir
# case, Closed with no fix; openclaw#26322 / PR #67876 fixed only the
# single-state-dir case.)
#
# ── The fix ─────────────────────────────────────────────────────────────────
# Make BOTH processes' locks/oauth-refresh/ resolve to ONE physical directory by
# symlinking each non-canonical process's dir to main's. withFileLock realpath's
# the dir before fs.open(...,'wx') (sidecar-lock-Bv7C32CP.js:105), so after
# convergence both processes O_EXCL-create the SAME physical lock file: exactly
# one wins, the loser blocks then runs openclaw's double-checked re-read and
# ADOPTS the winner's freshly-minted token instead of POSTing the spent one. The
# single-use token is consumed exactly once → the race is structurally
# impossible while convergence holds. No openclaw patch — only WHERE the lock
# files live.
#
# ── Why an EXPLICIT active list, not a .openclaw-* glob ──────────────────────
# node-8 has retired/backup/test profile dirs (.openclaw-dev.retired-*,
# .openclaw-plugin-backups, .openclaw-removed-backups, .openclaw-test, …). A
# glob would symlink/flag those benign dirs. We enumerate only profiles that
# actually run a codex gateway today (main canonical + edge). Add a profile here
# when a new codex gateway process is introduced.
#
# ── Why rm -rf before ln (load-bearing) ─────────────────────────────────────
# `ln -sfn CANON D` when D is an existing REAL directory does NOT replace it — it
# silently creates D/CANON inside it (and GNU `ln -sfnT` refuses with "cannot
# overwrite directory"). The only correct sequence against an existing real dir
# is: migrate any live *.lock files into canonical, then `rm -rf D && ln -sfn`.
# rm -rf on a symlink removes the link, never the target — safe for re-runs.
#
# ── Modes ───────────────────────────────────────────────────────────────────
#   (default / "ensure"): converge every active dir onto canonical. Best-effort;
#     logs to stderr and ALWAYS exits 0 so it can run from systemd ExecStartPre
#     without ever blocking gateway start. Seeds the canonical dir if absent.
#
#   --check (read-only detector, for the watchdog / CI): exit 1 if ANY active dir
#     is not a symlink whose realpath resolves to canonical (= convergence broke
#     / never applied), printing each offender as "  - <path>". Exit 0 if clean.
#     Exit 2 on error. Matches the repo's guard convention (0 clean/1 viol/2 err).
#
# ── Env overrides (used by scripts/tests/codex-refresh-lock-shared.bats) ─────
#   CODEX_LOCK_ROOT    sandbox root (default /root). CANON_LOCK_DIR and
#                      ACTIVE_LOCK_DIRS default underneath it.
#   CANON_LOCK_DIR     canonical lock dir (the link target; never touched beyond
#                      mkdir -p and receiving migrated *.lock files).
#   ACTIVE_LOCK_DIRS   newline/space-separated list of non-canonical lock dirs to
#                      converge. Defaults to the edge gateway's dir.
#
# set -uo pipefail (NOT -e): ensure mode must never abort before its exit 0.
set -uo pipefail

CODEX_LOCK_ROOT="${CODEX_LOCK_ROOT:-/root}"
CANON_LOCK_DIR="${CANON_LOCK_DIR:-${CODEX_LOCK_ROOT}/.openclaw-main/locks/oauth-refresh}"
# Explicit list of NON-canonical codex gateway lock dirs (NOT a glob — see header).
# shellcheck disable=SC2206  # word-splitting is the intended list parse
ACTIVE_LOCK_DIRS=(${ACTIVE_LOCK_DIRS:-${CODEX_LOCK_ROOT}/.openclaw-edge/locks/oauth-refresh})

LOGPREFIX="[ensure-codex-refresh-lock-shared $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
log() { echo "$LOGPREFIX $*" >&2; }

# real_dir <path> — physical path of a dir (follows symlinks), or "" if it does
# not resolve to a directory. Portable across macOS (bats host) and Linux
# (node-8) without `readlink -f`: cd follows the symlink, pwd -P prints physical.
real_dir() {
  local p="$1"
  (cd "$p" 2>/dev/null && pwd -P) || printf ''
}

CANON_REAL=""  # resolved lazily after we ensure canonical exists

# converged <dir> — true iff <dir> is a SYMLINK whose realpath == canonical's.
# A real dir (even if it somehow resolved to canonical) is NOT converged: the
# whole point is that the active process must follow a link into canonical.
converged() {
  local d="$1" dr
  [ -L "$d" ] || return 1
  dr="$(real_dir "$d")"
  [ -n "$dr" ] && [ -n "$CANON_REAL" ] && [ "$dr" = "$CANON_REAL" ]
}

# ── ensure mode ──────────────────────────────────────────────────────────────
run_ensure() {
  # Seed canonical so the link target exists (openclaw also mkdir -p's it, but
  # having it present makes the symlink non-dangling immediately).
  if ! mkdir -p "$CANON_LOCK_DIR" 2>/dev/null; then
    log "WARNING: could not create canonical lock dir ${CANON_LOCK_DIR} (continuing)"
  fi
  CANON_REAL="$(real_dir "$CANON_LOCK_DIR")"

  local d dr
  for d in "${ACTIVE_LOCK_DIRS[@]}"; do
    [ -n "$d" ] || continue

    # Never operate on canonical itself (defensive — it must not be in the list).
    dr="$(real_dir "$d")"
    if [ -n "$dr" ] && [ -n "$CANON_REAL" ] && [ "$dr" = "$CANON_REAL" ] && [ ! -L "$d" ]; then
      log "skip: ${d} IS the canonical dir"
      continue
    fi

    if converged "$d"; then
      continue  # already a symlink to canonical — no churn
    fi

    # Make sure the parent (…/locks) exists so ln can create the link.
    mkdir -p "$(dirname "$d")" 2>/dev/null || true

    # If it's a REAL directory, migrate any live *.lock files into canonical
    # before removing it, so an in-flight (held) lock is not lost. Best-effort.
    if [ -d "$d" ] && [ ! -L "$d" ]; then
      local f base
      shopt -s nullglob
      for f in "$d"/*.lock; do
        base="$(basename "$f")"
        if mv -f "$f" "$CANON_LOCK_DIR/$base" 2>/dev/null; then
          log "migrated in-flight lock: ${f} -> ${CANON_LOCK_DIR}/${base}"
        fi
      done
      shopt -u nullglob
    fi

    # rm -rf removes a real dir (now lock-drained) OR a wrong-target symlink
    # (the link only, never its target). Then link to canonical.
    if rm -rf "$d" 2>/dev/null && ln -sfn "$CANON_LOCK_DIR" "$d" 2>/dev/null; then
      log "converged: ${d} -> ${CANON_LOCK_DIR}"
    else
      log "WARNING: failed to converge ${d} -> ${CANON_LOCK_DIR} (continuing)"
    fi
  done
}

# ── --check mode ─────────────────────────────────────────────────────────────
run_check() {
  if [ ! -d "$CODEX_LOCK_ROOT" ] || [ ! -r "$CODEX_LOCK_ROOT" ]; then
    log "ERROR: lock root unreadable: ${CODEX_LOCK_ROOT}"
    return 2
  fi
  # Resolve canonical for comparison. If it does not exist yet, nothing can be
  # converged to it — every active dir is an offender.
  CANON_REAL="$(real_dir "$CANON_LOCK_DIR")"

  local offenders=() d
  for d in "${ACTIVE_LOCK_DIRS[@]}"; do
    [ -n "$d" ] || continue
    converged "$d" || offenders+=("$d")
  done

  if [ "${#offenders[@]}" -gt 0 ]; then
    log "REFRESH-LOCK NOT CONVERGED: active codex lock dir(s) are not a symlink to canonical:"
    local o
    for o in "${offenders[@]}"; do echo "  - $o"; done
    log "Canonical is ${CANON_LOCK_DIR}; run this script (ensure mode) to converge. Until then the two gateway processes can race a codex token refresh (refresh_token_reused)."
    return 1
  fi

  log "clean: every active codex lock dir is a symlink to ${CANON_LOCK_DIR}"
  return 0
}

# ── dispatch ─────────────────────────────────────────────────────────────────
main() {
  case "${1:-}" in
    --check)
      run_check
      exit $?
      ;;
    ""|--ensure)
      run_ensure
      exit 0  # ensure mode is best-effort and must never block start
      ;;
    -h|--help)
      sed -n '2,75p' "$0"
      exit 0
      ;;
    *)
      log "ERROR: unknown argument: $1 (use --check, --ensure, or no args for ensure)"
      exit 2
      ;;
  esac
}

main "$@"
