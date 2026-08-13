#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# ensure-mercury-token.sh — is the Finance Mercury Bank API token still live?
#
# PURE DETECTOR. It probes and reports; it never posts, never writes state, and
# never converges anything. Paging + rate limiting live in the caller,
# scripts/mercury-token-watchdog.sh — the same detector/pager split as
# scripts/lib/ensure-session-budget-headroom.sh + scripts/cron-health-watchdog.sh.
#
# ── The gap this closes (2026-08-03) ─────────────────────────────────────────
# The Finance agent's read-only Mercury token is hydra's only view of the bank
# side (the daily CIB report, Liza's cash forecasts). It has been revoked TWICE
# in four months and nothing on the box noticed:
#   - Token A worked 2026-04-28..04-29, dead by 05-01.
#   - Token B worked 2026-05-24..06-10, dead by 07-13.
# The second death went unnoticed for ~8 weeks. Finance itself reported the 401
# on 2026-07-13 and again on 07-27; it only reached a human on 2026-08-03, when
# Liza asked for a forecast and got a wall.
#
# It cannot self-heal: minting a replacement needs a human in the Mercury
# dashboard (Settings -> API tokens). Detect-and-page is the whole job, the same
# deliberate posture as ensure-session-budget-headroom.sh.
#
# ── Exit codes (repo guard convention: 0 clean / 1 violation / 2 unknown) ─────
#   0  token works (Mercury answered 200)
#   1  VIOLATION, a human must act: HTTP 401/403, or no credential on disk
#   2  cannot evaluate: transport failure, curl missing, or an unexpected
#      status (5xx/429/000). NOT an all-clear, and deliberately NOT pageable.
#
# ── Why a missing credential file is 1, not 2 ────────────────────────────────
# "No credential on disk" is a definitive answer to the question this guard
# asks ("can hydra reach Mercury?"), not an inconclusive read. Routing it to 2
# would make `rm mercury.env` a silent no-page hole — exactly the failure shape
# this script exists to remove. 2 is reserved for "I could not determine the
# answer", i.e. transient faults, which must never page.
#
# ── The token is never printed ───────────────────────────────────────────────
# Not in logs, not on any code path. It reaches curl through `-H @-` on stdin,
# so it never lands in the process argument list either — `ps` on this box is
# readable by every agent, and this credential leaking to other agents is
# precisely how it ended up in the cmo/cto/clio transcripts and the hydra-audit
# git repo. (`-H @file` needs curl >= 7.55; node-8 runs 8.5.0, verified to put
# the header on the wire.)
#
# ── Do NOT put this on a boot or DR path ─────────────────────────────────────
# It is a cron-only check on purpose. It makes a -m 30 authenticated call to a
# third-party bank API, so hanging it off openclaw-pre-start-heal.sh's
# ExecStartPre would add up to 30s to every gateway (re)start — and deploys
# restart gateways — for a condition that can neither block start nor be healed
# automatically. Same reasoning for dr-ai-healer.sh's diagnostic capture.
#
# Env knobs (mainly for tests):
#   MERCURY_ENV_FILE   env file holding MERCURY_API_KEY
#                      (default /opt/hydra/secrets/mercury.env)
#   MERCURY_API        API base (default https://api.mercury.com/api/v1)
#   CURL_BIN           curl binary (default curl) — bats stubs this
#
# set -uo pipefail (NOT -e): this guard exits 1 by design, and -e would make
# every internal non-zero a surprise exit before the verdict is reported.
# ──────────────────────────────────────────────────────────────
set -uo pipefail
# Defensive: the RUNBOOK tells operators to run this by hand during a recovery,
# and `bash -x ensure-mercury-token.sh` would trace both the key assignment and
# the full Authorization header onto the terminal (and into whatever log the
# operator is piping to). Nothing here needs tracing.
set +x

MERCURY_ENV_FILE="${MERCURY_ENV_FILE:-/opt/hydra/secrets/mercury.env}"
MERCURY_API="${MERCURY_API:-https://api.mercury.com/api/v1}"
CURL_BIN="${CURL_BIN:-curl}"

LOGPREFIX="[ensure-mercury-token $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
log() { echo "$LOGPREFIX $*" >&2; }

case "${1:-}" in
  --check|"") ;;
  *) log "unknown arg: $1 (expected --check or no args)"; exit 2 ;;
esac

url="${MERCURY_API}/accounts"

if ! command -v "$CURL_BIN" >/dev/null 2>&1; then
  log "WARN: cannot evaluate: curl not found (CURL_BIN=$CURL_BIN)"
  exit 2
fi

if [ ! -r "$MERCURY_ENV_FILE" ]; then
  log "VIOLATION: no credential: ${MERCURY_ENV_FILE} is missing or unreadable"
  exit 1
fi

# Read the key WITHOUT sourcing the file — a secret store is data, not trusted
# shell (the repo's older `eval "$(grep ... | sed 's/^/export /')"` idiom
# executes whatever is in the file and does not strip quotes/CR).
# tr strips CR first, so a CRLF file cannot leave `"tok"<CR>` and defeat the
# quote strip below; doing that in one pass removes an ordering hazard rather
# than documenting it.
# A trailing ` # comment` is stripped because bash strips it too when the real
# consumer does `set -a; . mercury.env` — the detector must read the file the
# same way the thing it is vouching for does, or it can pass a credential the
# consumer can't use (and vice versa).
keys="$(tr -d '\r' < "$MERCURY_ENV_FILE" \
  | sed -nE 's/[[:space:]]+(#.*)?$//; s/^[[:space:]]*(export[[:space:]]+)?MERCURY_API_KEY[[:space:]]*=[[:space:]]*//p')"

# REFUSE on more than one assignment rather than picking a winner. Shell
# `source`, systemd EnvironmentFile and docker --env-file are all LAST-wins;
# a naive `head -n1` here would be FIRST-wins, so appending a rotated token —
# the natural gesture during a rotation — would leave the detector probing the
# dead one forever (a daily false page nobody can clear by fixing the
# credential), and the mirror case would report a false CLEAN on a token the
# consumer never uses. Guessing either way hides the ambiguity; a human fixes
# this in five seconds once told.
key_count=0
[ -n "$keys" ] && key_count="$(printf '%s\n' "$keys" | wc -l | tr -d ' ')"

if [ "$key_count" -gt 1 ]; then
  log "VIOLATION: ${MERCURY_ENV_FILE} has ${key_count} MERCURY_API_KEY assignments — ambiguous (shell sourcing is last-wins); remove the stale one"
  exit 1
fi

key="$(printf '%s' "$keys" | sed -E 's/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/')"

if [ -z "$key" ]; then
  log "VIOLATION: no credential: ${MERCURY_ENV_FILE} has no MERCURY_API_KEY value"
  exit 1
fi

# --proto '=https' and --noproxy '*' make "the bearer only ever crosses TLS,
# straight to Mercury" structural rather than incidental: MERCURY_API is
# env-overridable, and curl otherwise honours http_proxy, so either could route
# a live bank credential through plaintext or a third party. No -L either — a
# redirect must never forward the Authorization header to another host.
code="$(printf 'Authorization: Bearer %s' "$key" \
  | "$CURL_BIN" -sS -o /dev/null -m 30 -w '%{http_code}' \
      --proto '=https' --noproxy '*' -H @- "$url" 2>/dev/null)"

case "$code" in
  200)
    log "clean: token works (HTTP 200 from ${url})"
    exit 0
    ;;
  401|403)
    log "VIOLATION: token REJECTED by Mercury (HTTP ${code} from ${url}) — revoked or deleted at Mercury; a human must mint a new read-only token"
    exit 1
    ;;
  *)
    log "WARN: cannot evaluate: unexpected HTTP '${code:-<none>}' from ${url} (transport failure or Mercury-side error)"
    exit 2
    ;;
esac
