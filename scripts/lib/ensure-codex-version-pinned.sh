#!/usr/bin/env bash
# ensure-codex-version-pinned.sh — keep @openclaw/codex pinned to the canonical
# version (scripts/lib/codex-version.sh) on every codex gateway profile, so a
# manual/out-of-band `openclaw plugins install` can't leave codex floated off the
# pin between deploys.
#
# ── The bug this closes (2026-06-19 fleet-wide codex outage) ─────────────────
# codex is DELIBERATELY pinned BELOW the runtime to 2026.5.27 to dodge the #90925
# "OpenAI route unification" regression in @openclaw/codex@2026.6.x (it routes
# openai/gpt-5.5 to the api-key endpoint api.openai.com/v1/responses instead of
# the Codex app-server OAuth route → `invalid_api_key` on this OAuth-only host →
# the whole fleet falls back to openrouter/openai/gpt-5.4-mini). deploy.sh pins +
# verifies codex, but ONLY at deploy time; a manual `plugins install
# @openclaw/codex@2026.6.1 --force` between deploys stays floated until the next
# deploy. On 2026-06-19 exactly that defeated the pin and degraded the fleet for
# hours. See scripts/lib/codex-version.sh and CLAUDE.md "Codex / OAuth auth is
# centralized".
#
# ── The fix ─────────────────────────────────────────────────────────────────
# Re-assert the pin in ExecStartPre of each gateway (via openclaw-pre-start-heal.sh),
# the same self-heal pattern as ensure-codex-auth.sh / ensure-codex-refresh-lock-
# shared.sh / ensure-secret-perms.sh. CHECK-FIRST: when codex already == the pin
# (the normal case) it is a fast no-op (one version read, no npm). Only on drift
# does it run the exact deploy invocation
#   openclaw --profile <p> plugins install @openclaw/codex@<pinned> --force --pin
# while the gateway is DOWN (ExecStartPre), so ExecStart then loads the pinned
# build. Had this existed, the 2026-06-19 restart would have auto-reverted
# 6.1 -> 5.27 with no prolonged outage.
#
# ── Modes ───────────────────────────────────────────────────────────────────
#   (default / "ensure" / "<profile…>"): re-pin the given profiles (default
#     "main edge") to canonical, only where drifted. Best-effort; logs to stderr
#     and ALWAYS exits 0 so it never blocks gateway start (an npm/network failure
#     just warns — the watchdog --check tripwire pages).
#
#   --check [profile…] (read-only detector, for the watchdog / CI): exit 1 if ANY
#     profile's installed codex version != the pin (each printed "  - <profile>:
#     <installed> (want <pin>)"). Exit 0 clean, exit 2 on read error. Matches the
#     repo guard convention (0 clean / 1 viol / 2 err).
#
# ── Env overrides (used by scripts/tests/ensure-codex-version-pinned.bats) ────
#   CODEX_PINNED_VERSION  the target version (default: OPENCLAW_CODEX_VERSION from
#                         codex-version.sh, default 2026.5.27).
#   CODEX_PIN_PROFILES    space-separated profiles to enforce (default "main edge").
#   `openclaw` is resolved from PATH so tests can stub it.
#
# set -uo pipefail (NOT -e): ensure mode must never abort before its exit 0.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=codex-version.sh
[ -r "$SCRIPT_DIR/codex-version.sh" ] && source "$SCRIPT_DIR/codex-version.sh"

PINNED="${CODEX_PINNED_VERSION:-${OPENCLAW_CODEX_VERSION:-2026.5.27}}"
PROFILES="${CODEX_PIN_PROFILES:-main edge}"

LOGPREFIX="[ensure-codex-version-pinned $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
log() { echo "$LOGPREFIX $*" >&2; }

# _parse_codex_version — read `openclaw plugins list --json` on stdin and print
# the installed codex plugin version (empty if codex is absent / unparseable).
# Tolerates leading non-JSON (doctor/migration warnings) by seeking the first
# JSON token. python3 is present on node-8 and the macOS bats host.
_parse_codex_version() {
  python3 -c '
import sys, json
raw = sys.stdin.read()
cands = [p for p in (raw.find("["), raw.find("{")) if p != -1]
if not cands:
    sys.exit(0)
try:
    d = json.loads(raw[min(cands):])
except Exception:
    sys.exit(0)
ps = d if isinstance(d, list) else d.get("plugins", [])
for x in ps if isinstance(ps, list) else []:
    if isinstance(x, dict) and x.get("id") == "codex":
        print(x.get("version") or "")
        break
'
}

# codex_installed_version <profile> — print installed codex version; return 1 if
# the openclaw query itself failed (unreadable), 0 otherwise (empty = absent).
codex_installed_version() {
  local profile="$1" out
  out="$(openclaw --profile "$profile" plugins list --json 2>/dev/null)" || return 1
  printf '%s' "$out" | _parse_codex_version
}

run_check() {
  local offenders=() p installed rc
  for p in $PROFILES; do
    [ -n "$p" ] || continue
    installed="$(codex_installed_version "$p")"; rc=$?
    if [ "$rc" -ne 0 ]; then
      log "ERROR: cannot read codex version for profile '$p' (openclaw query failed)"
      return 2
    fi
    if [ -z "$installed" ]; then
      offenders+=("$p: codex NOT installed (want $PINNED)")
    elif [ "$installed" != "$PINNED" ]; then
      offenders+=("$p: $installed (want $PINNED)")
    fi
  done

  if [ "${#offenders[@]}" -gt 0 ]; then
    log "CODEX VERSION DRIFT (pin=$PINNED):"
    local o; for o in "${offenders[@]}"; do echo "  - $o"; done
    log "codex@2026.6.x reintroduces the #90925 api-key-route 401 (fleet -> gpt-5.4-mini). Re-pin: run this script (ensure mode) or 'openclaw --profile <p> plugins install @openclaw/codex@${PINNED} --force --pin' then restart the gateway."
    return 1
  fi
  log "clean: codex is pinned at $PINNED on: $PROFILES"
  return 0
}

run_ensure() {
  local targets="${1:-$PROFILES}" p installed
  for p in $targets; do
    [ -n "$p" ] || continue
    installed="$(codex_installed_version "$p" 2>/dev/null)"
    if [ "$installed" = "$PINNED" ]; then
      continue  # already pinned — fast no-op, no npm
    fi
    log "codex on '$p' is '${installed:-not installed}' (want $PINNED) — re-pinning"
    if openclaw --profile "$p" plugins install "@openclaw/codex@${PINNED}" --force --pin >/dev/null 2>&1; then
      installed="$(codex_installed_version "$p" 2>/dev/null)"
      if [ "$installed" = "$PINNED" ]; then
        log "re-pinned codex@${PINNED} on '$p' (gateway start loads it)"
      else
        log "WARNING: re-pin ran but '$p' still reports '${installed:-unknown}' (continuing)"
      fi
    else
      log "WARNING: failed to re-pin codex@${PINNED} on '$p' (npm/network?) — continuing; the watchdog --check tripwire will page"
    fi
  done
}

main() {
  case "${1:-}" in
    --check)
      shift
      [ "$#" -gt 0 ] && PROFILES="$*"
      run_check
      exit $?
      ;;
    --ensure)
      shift
      run_ensure "$*"
      exit 0
      ;;
    -h|--help)
      sed -n '2,60p' "$0"
      exit 0
      ;;
    "")
      run_ensure "$PROFILES"
      exit 0
      ;;
    -*)
      log "ERROR: unknown argument: $1 (use --check, --ensure, <profile…>, or no args)"
      exit 2
      ;;
    *)
      run_ensure "$*"   # bare profile name(s) => ensure those (pre-start-heal passes one)
      exit 0
      ;;
  esac
}

main "$@"
