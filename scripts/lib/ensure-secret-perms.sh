#!/usr/bin/env bash
# ensure-secret-perms.sh — keep openclaw's file-based secret stores owner-only
# (0600) so the gateway's FAIL-CLOSED secret loader can read them.
#
# ── The bug this closes (2026-06-15 fleet-wide outage) ───────────────────────
# openclaw resolves file-based secret providers (secrets.providers.<name> with
# source:"file") at gateway (re)start AND on every config reload, and is
# FAIL-CLOSED: if the file is group/other-accessible it refuses to load it —
# "secrets.providers.<name>.path permissions are too open" — and the gateway
# exits "required secrets are unavailable". On 2026-06-15 the hydra-secrets file
# /opt/hydra/secrets/llm-provider-keys.json drifted from 0600 to 0644. It was
# fine at the prior gateway start, so nothing surfaced until a routine deploy
# triggered a config reload, which re-validated the provider, hit the 0644 file,
# and crash-looped BOTH main and edge gateways into systemd `failed` — a ~10-min
# total fleet outage (CTO + every main agent + Caroline/CS). The gateway only
# checks perms at (re)start/reload, so re-tightening the secret files BEFORE
# ExecStart turns any such drift into a 0-impact self-heal instead of an outage.
#
# ── Modes ────────────────────────────────────────────────────────────────────
#   (default / "ensure"): chmod 0600 every too-open secret file. Best-effort;
#     logs to stderr and ALWAYS exits 0 so it can run from systemd ExecStartPre
#     without ever blocking gateway start.
#
#   --check (read-only detector, for the watchdog / CI): exit 1 if ANY secret
#     file is group/other-accessible, printing each offender as
#     "  - <path> (<mode>)". Exit 0 if clean. Matches the repo guard convention
#     (0 clean / 1 violation), used the same way as
#     ensure-codex-refresh-lock-shared.sh --check.
#
# ── Why *.json ───────────────────────────────────────────────────────────────
# Every file-based secret provider on hydra points at a *.json file in this dir
# (llm-provider-keys.json = hydra-secrets, google-sa-hydra.json, vault-init.json).
# The non-secret .gitkeep is intentionally excluded. Add a non-.json secret
# store here only by widening the glob below — and document why.
#
# ── Env overrides (used by scripts/tests/ensure-secret-perms.bats) ───────────
#   HYDRA_SECRETS_DIR   directory holding the *.json secret stores
#                       (default /opt/hydra/secrets).
#
# set -uo pipefail (NOT -e): ensure mode must never abort before its exit 0.
set -uo pipefail

SECRETS_DIR="${HYDRA_SECRETS_DIR:-/opt/hydra/secrets}"
LOGPREFIX="[ensure-secret-perms $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
log() { echo "$LOGPREFIX $*" >&2; }

# file_mode <path> — octal permission bits, e.g. "644". GNU stat (node-8 / CI)
# uses `-c '%a'`; BSD stat (macOS dev host) uses `-f '%Lp'`. Try GNU, fall back.
file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || printf ''
}

# too_open <mode> — true iff any group/other permission bit is set (mode & 077),
# i.e. the file is group/other-accessible. Mask numerically rather than string-
# slicing the digits: `stat` prints "0" (not "000") for a chmod-000 file, so a
# suffix test would wrongly flag it as too-open even though 000 & 077 == 0.
too_open() {
  local mode="$1"
  [[ "$mode" =~ ^[0-7]+$ ]] || return 1   # unknown/non-octal mode → don't claim too-open
  (( (8#$mode) & 0077 ))
}

# list_secrets — emit each secret file path, one per line. nullglob so an empty
# (or absent-of-json) dir yields nothing rather than a literal "*.json".
list_secrets() {
  shopt -s nullglob
  local f
  for f in "$SECRETS_DIR"/*.json; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
}

# ── --check mode (read-only) ─────────────────────────────────────────────────
if [ "${1:-}" = "--check" ]; then
  # No dir → nothing too-open to report. Not a violation for a detector.
  [ -d "$SECRETS_DIR" ] || exit 0
  rc=0
  while IFS= read -r f; do
    m="$(file_mode "$f")"
    if too_open "$m"; then
      [ "$rc" -eq 0 ] && echo "$LOGPREFIX too-open secret file(s) in ${SECRETS_DIR}:" >&2
      echo "  - $f ($m)" >&2
      rc=1
    fi
  done < <(list_secrets)
  [ "$rc" -eq 0 ] && log "clean: every secret file in ${SECRETS_DIR} is owner-only (0600)"
  exit "$rc"
fi

# ── ensure mode (default) ────────────────────────────────────────────────────
if [ ! -d "$SECRETS_DIR" ]; then
  log "secrets dir ${SECRETS_DIR} absent — nothing to tighten"
  exit 0
fi

tightened=0
while IFS= read -r f; do
  m="$(file_mode "$f")"
  if too_open "$m"; then
    if chmod 600 "$f" 2>/dev/null; then
      log "tightened $(basename "$f") ${m} -> 600 (was group/other-accessible — fail-closed secret guard)"
      tightened=$((tightened + 1))
    else
      log "WARNING: failed to chmod 600 ${f} (continuing)"
    fi
  fi
done < <(list_secrets)

[ "$tightened" -gt 0 ] && log "tightened ${tightened} too-open secret file(s) in ${SECRETS_DIR}"
exit 0
