#!/usr/bin/env bash
# ensure-codex-auth.sh — point EVERY agent's Codex (ChatGPT OAuth) auth store at
# ONE canonical store via symlink, idempotently. Fleet-wide generalization of
# PR #376's edge-only ensure-edge-codex-auth.sh.
#
# ── Why a single central store ──────────────────────────────────────────────
# codex (ChatGPT OAuth) auth uses a SINGLE-USE refresh token: each refresh
# consumes the current token and mints the next one, then atomically rewrites
# auth-profiles.json. If more than one agent holds an independent COPY of that
# OAuth profile, the first agent to refresh invalidates every other copy's
# token; the others then refresh against a now-dead token, clobber each other,
# and the whole fleet's codex auth collapses. A prior incident did exactly this
# by fanning the OAuth profile (incl. its single-use refresh token) into
# per-agent stores that mutually clobbered the token.
#
# Fix: ONE canonical store, every other agent SYMLINKS to it. All agents then
# read and write the same bytes, so a refresh by any agent advances the single
# shared token in place — no divergent copies to clobber.
#
# ── Why canonical = main (NOT clio) ─────────────────────────────────────────
# The canonical store lives under the `main` profile's primary agent:
#   /root/.openclaw-main/agents/main/agent/{auth-profiles.json,auth-state.json}
# `main` is the profile whose interactive `codex login` flow seeds and refreshes
# the OAuth profile, so it is the natural single writer/owner. clio is an agent
# persona, not the auth owner — do not point canonical at it.
#
# ── Why the symlink survives a refresh ──────────────────────────────────────
# openclaw resolves a symlink to its target BEFORE the atomic create-temp +
# rename it uses to persist refreshed auth. The rename lands on the canonical
# target file; the per-agent symlink keeps pointing at canonical and silently
# sees the new bytes. (If openclaw instead rename()'d directly over the link
# path it would replace the link with a regular file — it does not; #376
# validated the resolve-then-write behavior on the live edge store.)
#
# ── Modes ───────────────────────────────────────────────────────────────────
#   (default / "ensure"): for every NON-canonical agent dir discovered via the
#     glob, make auth-profiles.json and auth-state.json symlinks -> the
#     canonical files. Pre-existing REGULAR files are backed up ONCE to
#     <file>.bak-<UTCstamp> before being replaced (an existing CORRECT symlink
#     is a no-op; an existing symlink is never backed up — avoids churn).
#     Best-effort: logs to stderr and ALWAYS exits 0 so it can run from a
#     systemd ExecStartPre without ever blocking gateway start. We link to
#     canonical even if canonical does not exist yet (ln -sfn; a dangling link
#     is acceptable and resolves the moment re-auth populates canonical) — but
#     we log a warning when canonical is missing.
#     ⚠ On an openclaw >= 2026.7 runtime BOTH modes delegate to
#     codex-auth-sync.sh (the runtime no longer reads the JSON this script
#     symlinks) and exit with ITS code — so ensure mode can then exit 1
#     (surfaces failed to converge) or 2 (structural error) instead of the
#     legacy always-0. Both ExecStartPre callers tolerate non-zero.
#
#   --check (read-only detector, for CI / guards): exit 1 if ANY non-canonical
#     store is a REGULAR FILE that contains an `openai-codex:*` profile (= the
#     fan-out reintroduced), printing each offending path as "  - <path>".
#     Exit 0 if clean. Exit 2 on error (jq missing, glob root unreadable).
#     Exit-code convention matches the repo's other guards: 0 clean / 1
#     violation / 2 error.
#
# ── Env overrides ────────────────────────────────────────────────────────────
#   CANON_DIR    canonical agent dir (default below). Its auth-profiles.json /
#                auth-state.json are the link targets and are never touched.
#   AGENTS_GLOB  glob matching every agent dir to manage (default below). Covers
#                main + edge profiles. The canonical dir is skipped if matched.
#   CODEX_AUTH_ROOT  optional sandbox root: when set, CANON_DIR and AGENTS_GLOB
#                default underneath it instead of /root (used by the bats tests
#                so they never touch live node-8 auth files).
#
# set -uo pipefail (NOT -e): ensure mode must never abort before its exit 0.
set -uo pipefail

CODEX_AUTH_ROOT="${CODEX_AUTH_ROOT:-/root}"
CANON_DIR="${CANON_DIR:-${CODEX_AUTH_ROOT}/.openclaw-main/agents/main/agent}"
AGENTS_GLOB="${AGENTS_GLOB:-${CODEX_AUTH_ROOT}/.openclaw-*/agents/*/agent}"

CANON_PROFILES="$CANON_DIR/auth-profiles.json"
CANON_STATE="$CANON_DIR/auth-state.json"

# Files we manage in each agent dir, paired with their canonical target.
AUTH_FILES=("auth-profiles.json" "auth-state.json")

LOGPREFIX="[ensure-codex-auth $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
log() { echo "$LOGPREFIX $*" >&2; }

# Canonicalize a dir path for identity comparison (so a glob-matched canonical
# is reliably skipped even if expressed differently). Falls back to the raw
# string when the path does not yet exist.
canon_path() {
  local p="$1"
  if [ -d "$p" ]; then (cd "$p" 2>/dev/null && pwd -P) || printf '%s' "$p"; else printf '%s' "$p"; fi
}

CANON_DIR_REAL="$(canon_path "$CANON_DIR")"

# target_for <basename> -> canonical absolute path for that auth file.
target_for() {
  case "$1" in
    auth-profiles.json) printf '%s' "$CANON_PROFILES" ;;
    auth-state.json)    printf '%s' "$CANON_STATE" ;;
    *) return 1 ;;
  esac
}

# ── ensure mode helpers ──────────────────────────────────────────────────────

# Symlink one auth file in one agent dir to its canonical target. Best-effort;
# never returns non-zero in a way that would propagate to the script's exit.
ensure_link() {
  local target="$1" link="$2" ts
  # Already the correct symlink -> nothing to do (avoids backup churn).
  if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
    return 0
  fi
  # Pre-existing REGULAR file (not a symlink): back it up ONCE before replacing.
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    if cp -p "$link" "${link}.bak-${ts}" 2>/dev/null; then
      log "backed up pre-existing regular file: ${link} -> ${link}.bak-${ts}"
    else
      log "WARNING: failed to back up ${link} before relinking (continuing)"
    fi
  fi
  # ln -sfn: atomically replace whatever is there (regular file, wrong symlink,
  # or nothing) with a link to canonical. Dangling link is acceptable.
  if ln -sfn "$target" "$link" 2>/dev/null; then
    log "linked: ${link} -> ${target}"
  else
    log "WARNING: failed to link ${link} -> ${target} (continuing)"
  fi
}

run_ensure() {
  if [ ! -e "$CANON_PROFILES" ]; then
    log "WARNING: canonical store missing: ${CANON_PROFILES} (linking anyway; dangling links resolve once re-auth populates canonical)"
  fi

  local matched=0 dir dir_real f target link
  # Iterate the glob. `shopt -s nullglob` so an unmatched glob expands to
  # nothing rather than the literal pattern.
  shopt -s nullglob
  for dir in $AGENTS_GLOB; do
    [ -d "$dir" ] || continue
    dir_real="$(canon_path "$dir")"
    # Skip the canonical dir itself — its files are the link targets.
    if [ "$dir_real" = "$CANON_DIR_REAL" ]; then
      continue
    fi
    matched=$((matched + 1))
    for f in "${AUTH_FILES[@]}"; do
      target="$(target_for "$f")"
      link="$dir/$f"
      ensure_link "$target" "$link"
    done
  done
  shopt -u nullglob

  if [ "$matched" -eq 0 ]; then
    log "no non-canonical agent dirs matched AGENTS_GLOB=${AGENTS_GLOB} (nothing to do)"
  fi
}

# ── --check mode ─────────────────────────────────────────────────────────────

# A store "fans out" codex if it is a REGULAR FILE (not a symlink, not absent)
# whose JSON has any profile key starting with "openai-codex:". Symlinks to
# canonical are fine; a codex-less regular file is fine; missing is fine.
file_has_codex_profile() {
  local file="$1"
  # any/2 (generator; condition) so the result is order-independent across keys;
  # `jq -e 'keys[] | startswith(..)'` would set exit status from the LAST key only.
  jq -e 'any((.profiles // {}) | keys[]; startswith("openai-codex:"))' "$file" >/dev/null 2>&1
}

run_check() {
  if ! command -v jq >/dev/null 2>&1; then
    log "ERROR: jq required for --check but not on PATH"
    return 2
  fi

  # The glob root (parent of /root/.openclaw-*) must be readable to discover
  # stores; an unreadable root is an error, not a clean result.
  local glob_root="${CODEX_AUTH_ROOT}"
  if [ ! -d "$glob_root" ] || [ ! -r "$glob_root" ]; then
    log "ERROR: glob root unreadable: ${glob_root}"
    return 2
  fi

  local offenders=() dir dir_real f link
  shopt -s nullglob
  for dir in $AGENTS_GLOB; do
    [ -d "$dir" ] || continue
    dir_real="$(canon_path "$dir")"
    # Canonical is the legitimate single home for the codex profile — skip it.
    if [ "$dir_real" = "$CANON_DIR_REAL" ]; then
      continue
    fi
    for f in "${AUTH_FILES[@]}"; do
      link="$dir/$f"
      # Only a REGULAR file is a fan-out; a symlink (even to canonical) is fine.
      if [ -f "$link" ] && [ ! -L "$link" ]; then
        if file_has_codex_profile "$link"; then
          offenders+=("$link")
        fi
      fi
    done
  done
  shopt -u nullglob

  if [ "${#offenders[@]}" -gt 0 ]; then
    log "FAN-OUT DETECTED: non-canonical store(s) hold an openai-codex:* profile as a regular file:"
    local o
    for o in "${offenders[@]}"; do
      echo "  - $o"
    done
    log "Canonical store is ${CANON_PROFILES}; every other agent must symlink to it. Run this script (ensure mode) to relink."
    return 1
  fi

  log "clean: no non-canonical store fans out an openai-codex:* profile"
  return 0
}

# ── dispatch ─────────────────────────────────────────────────────────────────

# openclaw >= 2026.7: the runtime no longer reads auth-profiles.json — the
# symlink fabric this script maintains is INERT there. The 7.x-aware successor
# (codex-auth-sync.sh: main-agent sqlite row + per-agent codex-home/auth.json,
# access-token-only fan-out) takes over BOTH modes so every existing caller
# (ExecStartPre heal, watchdog --check, CI) keeps its single entry point.
# When the runtime is absent or pre-2026.7, legacy symlink behavior runs
# unchanged (and the sync script itself no-ops below 2026.7, so double
# invocation is safe).
# QA bot finding (PR #897 round 4): runtime_ver is resolved EXACTLY ONCE in
# main() and passed in here as $1 — this must NOT re-probe
# `openclaw --version` itself. A re-probe can transiently disagree with
# main()'s already-resolved value (flaky command, momentary unavailability),
# which silently steers this call onto a different runtime-era path than the
# rest of the same invocation used.
maybe_delegate_to_sync() {
  local runtime_ver="$1"
  shift
  local lib_dir sync_script
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  sync_script="$lib_dir/codex-auth-sync.sh"
  [ -x "$sync_script" ] || return 1
  [ -n "$runtime_ver" ] || return 1
  if version_at_least "2026.7" "$runtime_ver"; then
    log "runtime $runtime_ver >= 2026.7 — delegating to codex-auth-sync.sh"
    "$sync_script" "$@"
    exit $?
  fi
  return 1
}

# openclaw >= 2026.8: shared codex auth moves again, out from under BOTH the
# symlink fabric (this script's legacy mode) AND codex-auth-sync.sh's
# sqlite-row-plus-codex-home fan-out — the runtime now serves every agent
# straight from the shared authProfiles.store row (config_machine_state) with
# per-agent auth_profile_store rows expected EMPTY (read-through inheritance).
# There is nothing left for this script to converge: no files to symlink, no
# access token to fan out. codex-auth-invariants.sh is the >= 2026.8 read-only
# checker for that shape. --check mode propagates its exit code (the repo's
# 0/1/2 convention carries straight through); default/--ensure mode is
# report-only here too — codex-auth-invariants.sh has no write mode to run,
# so "ensure" always exits 0 (ExecStartPre must never block start on a report).
# QA bot finding (PR #897 round 4): runtime_ver is resolved EXACTLY ONCE in
# main() and passed in here as $2 — this must NOT re-probe
# `openclaw --version` itself (see maybe_delegate_to_sync above for why).
maybe_delegate_to_invariants() {
  local mode="$1" runtime_ver="$2" lib_dir inv_script
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  inv_script="$lib_dir/codex-auth-invariants.sh"
  [ -n "$runtime_ver" ] || return 1
  version_at_least "2026.8" "$runtime_ver" || return 1
  # From here the runtime IS >= 2026.8, so this auth surface belongs SOLELY
  # to codex-auth-invariants.sh. QA bot finding (PR #897 round 3): a missing
  # or unexecutable checker used to fall through (return 1) into the legacy
  # < 2026.7 symlink-fabric / codex-auth-sync.sh checks below — those cannot
  # evaluate a 2.0 store at all, so a missing checker must refuse loud
  # (--check) or skip (ensure), never silently run the wrong-era checks.
  if [ ! -x "$inv_script" ]; then
    if [ "$mode" = "check" ]; then
      log "ERROR: runtime $runtime_ver >= 2026.8 but codex-auth-invariants.sh is missing or not executable at $inv_script — refusing to fall through to the legacy pre-2026.7 checks, which cannot evaluate this auth surface"
      exit 2
    fi
    log "WARNING: runtime $runtime_ver >= 2026.8 but codex-auth-invariants.sh is missing or not executable at $inv_script — skipping (best-effort; never running the legacy pre-2026.7 convergence on a 2.0 store)"
    exit 0
  fi
  log "runtime $runtime_ver >= 2026.8 — delegating to codex-auth-invariants.sh (report-only; nothing left here to symlink or fan out)"
  if [ "$mode" = "check" ]; then
    "$inv_script" --check
    exit $?
  fi
  "$inv_script" --check || true
  exit 0
}

main() {
  # An unparseable runtime version must not silently fall through to the
  # legacy 7.1 symlink-fabric checks below — those files are INERT on
  # >= 2026.7/2026.8, so guessing "pre-2026.7" on an actual 2.0+ box whose
  # version we simply could not read would run_check a fan-out signal that
  # cannot exist there anymore (false clean) or run_ensure symlinks nobody
  # reads. Resolve once, here, and never guess.
  local lib_dir runtime_ver
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=version-compare.sh
  source "$lib_dir/version-compare.sh"
  runtime_ver="$(openclaw_runtime_version)"

  case "${1:-}" in
    --check)
      if [ -z "$runtime_ver" ]; then
        log "ERROR: could not determine openclaw runtime version (\`openclaw --version\` returned nothing/unparseable) — refusing to guess whether the 2026.8+ invariants checker, the 2026.7+ sync checker, or the legacy symlink-fabric check applies"
        exit 2
      fi
      maybe_delegate_to_invariants check "$runtime_ver"
      maybe_delegate_to_sync "$runtime_ver" --check || true
      run_check
      exit $?
      ;;
    ""|--ensure)
      if [ -z "$runtime_ver" ]; then
        log "ERROR: could not determine openclaw runtime version (\`openclaw --version\` returned nothing/unparseable) — refusing to guess which auth surface to converge; skipping without writing anything (best-effort, must never block start)"
        exit 0
      fi
      maybe_delegate_to_invariants ensure "$runtime_ver"
      maybe_delegate_to_sync "$runtime_ver" || true
      run_ensure
      # Ensure mode is best-effort and must never block start.
      exit 0
      ;;
    -h|--help)
      sed -n '2,60p' "$0"
      exit 0
      ;;
    *)
      log "ERROR: unknown argument: $1 (use --check, --ensure, or no args for ensure)"
      exit 2
      ;;
  esac
}

main "$@"
