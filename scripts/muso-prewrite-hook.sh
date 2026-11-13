#!/usr/bin/env bash
# muso-prewrite-hook.sh — muso CLI pre-write hook: live model-health gate.
#
# The muso CLI (skills-all/muso-cli) execs this before EVERY admin-API
# write (POST/PUT/PATCH/DELETE; reads never reach the hook) with args:
# <METHOD> <PATH> <ENV>. Wired via /root/.config/muso/config.json
# ("prewrite_hook"), which deploy.sh renders on every deploy.
#   Exit 0   → the write proceeds.
#   Exit !=0 → muso refuses the write (its exit 5) and surfaces this
#              script's stderr as the reason.
#
# It runs the SAME live codex-health probe as scripts/muso-stripe-write.sh
# and skills-all/muso-ops-admin/scripts/muso-admin-api.sh (incident
# 2026-06-08: a silently-degraded fallback model must not perform
# state-changing writes). FAIL-CLOSED like the money path: an unreadable
# lib and an unverifiable journal both refuse; an empty-but-readable
# window is healthy-quiet. Deliberately NO caller-settable bypass — the
# degraded model this guards against must not be able to disable it. That
# is why, unlike muso-stripe-write.sh, the lib path / unit / window are
# HARDCODED rather than env knobs: an env knob would let the caller point
# the probe at a stub lib or a quiet unit and pass while degraded. Tests
# stub `journalctl` on PATH instead — the lib invokes it by name for
# exactly that reason.
set -euo pipefail

# --- Claim-verify pace gate (2026-10-11) -------------------------------------
# A profile claim verify (POST .../claiming/<id>/verify) makes the claimant the
# verified owner of that profile. Forensics 2026-10-11: since 09-01, 2,424 claim
# verifies went through muso-cli at a 0.44 s median gap. That is a script loop,
# not a human reading each claim, and it is how impostor claims (e.g. the
# stillfloo profile, approved 3m55s after filing on an Instagram link) get
# through. muso-cli treats a claim verify as a plain write, and this hook cannot
# see its approval flags, so the hook enforces PACE instead: at most one claim
# verify per CLAIM_VERIFY_MIN_INTERVAL seconds, host-wide, across every muso
# caller. A human reviewing claims one by one never hits it; a loop always does.
# Hardcoded on purpose (no env knob), like the rest of this hook: the caller
# controls its env. The state file is shared with muso-admin-api.sh's gate.
CLAIM_VERIFY_MIN_INTERVAL=20
CLAIM_VERIFY_LAST="/var/lib/hydra/claim-verify.last"

claim_verify_pace_gate() {
  local method="$1" path="${2%%\?*}"
  [ "$method" = "POST" ] || return 0
  [[ "$path" =~ (^|/)claiming/[^/]+/verify/?$ ]] || return 0
  local dir now last
  dir="$(dirname "$CLAIM_VERIFY_LAST")"
  if ! mkdir -p "$dir" 2>/dev/null || ! { exec 7>>"$CLAIM_VERIFY_LAST.lock"; } 2>/dev/null; then
    echo "REFUSED (muso-prewrite-hook): cannot open the claim-verify pace state under $dir; refusing the claim verify (fail closed)." >&2
    return 1
  fi
  # The lock is what makes the gate host-wide: without it two concurrent
  # verifies can read the same old timestamp and both pass. No flock, no verify.
  if ! command -v flock >/dev/null 2>&1; then
    echo "REFUSED (muso-prewrite-hook): flock is unavailable, so the claim-verify pace gate cannot serialize callers; refusing the claim verify (fail closed)." >&2
    return 1
  fi
  if ! flock -w 5 7; then
    echo "REFUSED (muso-prewrite-hook): claim-verify pace lock busy; refusing the claim verify." >&2
    return 1
  fi
  now="$(date +%s)"
  # Absent file = first use. An existing stamp that is empty, truncated or unreadable
  # must not read as "long ago": refuse until a root operator clears it.
  last=0
  if [ -e "$CLAIM_VERIFY_LAST" ]; then
    if ! last="$(cat "$CLAIM_VERIFY_LAST" 2>/dev/null)" || [[ ! "$last" =~ ^(0|[1-9][0-9]{0,14})$ ]]; then
      echo "REFUSED (muso-prewrite-hook): the claim-verify timestamp in $CLAIM_VERIFY_LAST is unreadable or malformed; refusing the claim verify (fail closed). Clear $CLAIM_VERIFY_LAST as root." >&2
      return 1
    fi
  fi
  # A stamp in the future (clock stepped back) is not "long ago": resetting it to 0
  # would let the next verify through inside the budget. Refuse until it elapses.
  if (( last > now )); then
    echo "REFUSED (muso-prewrite-hook): the claim-verify timestamp in $CLAIM_VERIFY_LAST is $((last - now))s in the future (host clock may have stepped backward); refusing the claim verify (fail closed). Check the host clock, then clear $CLAIM_VERIFY_LAST as root." >&2
    return 1
  fi
  if (( now - last < CLAIM_VERIFY_MIN_INTERVAL )); then
    echo "REFUSED (muso-prewrite-hook): claim verifies are limited to one per ${CLAIM_VERIFY_MIN_INTERVAL}s host-wide (last one $((now - last))s ago). Verifying a claim makes someone the owner of a profile: review each claim individually (identity evidence, competing claims, popularity) before verifying it. Do not retry in a loop." >&2
    return 1
  fi
  # The stamp IS the gate for the next caller: if it cannot be written, refuse.
  if ! { printf '%s\n' "$now" > "$CLAIM_VERIFY_LAST"; } 2>/dev/null; then
    echo "REFUSED (muso-prewrite-hook): cannot record the claim-verify timestamp at $CLAIM_VERIFY_LAST; refusing the claim verify (fail closed)." >&2
    return 1
  fi
  return 0
}

# --- Removal gate (2026-11-04) -----------------------------------------------
# DELETE /admin/profile/<id> is the profile soft-delete: it tombstones the
# profile AND every served credit on it, there is no inverse, and legal hold
# 1350 means the data is never destroyed. The operations bot ran it 21 times in
# 14 days on Jan's word (a workspace skill that was never reviewed as policy),
# which is what this gate stops.
#
# "Hide" is NOT this endpoint. Profile hides are not available to the agent: the
# request goes on the GDPR register (scripts/gdpr-pipeline.py), which decides
# identity per paths A-E and prepares the reversible hide PRs for a named human
# to merge. AGENTS.md: "The pipeline only PREPARES the reversible hide PRs ...
# Never DELETE /api/v3/admin/profile".
#
# Same wording as muso-admin-api.sh's removal refusal (MUSO_REMOVAL_NO_SELF_APPROVE)
# so both wrappers refuse identically. This hook cannot see approval flags or a
# --dry-run marker, so the refusal is unconditional: a dry run of a removal is
# worth less than the write it rehearses. DELETE /admin/profile/<id>/cache is a
# CDN purge, not a removal, and is untouched.
# normalize_removal_path PATH -> canonical, lower-cased path on stdout.
#
# The path is concatenated straight into the request URL, and curl resolves
# dot-segments while Express routes case-insensitively, so /ADMIN/profile/<id>,
# /admin/profile/./<id>, /admin/profile/x/../<id> and /admin/profile/<id>// all
# reach the SAME handler as the canonical spelling. Matching the raw string let
# every one of those past the gate. Normalizing can only make MORE paths match.
normalize_removal_path() {
  local p="$1" out="" seg
  p="${p%%#*}"
  p="${p%%\?*}"
  p="$(printf %s "$p" | tr '[:upper:]' '[:lower:]')"
  local IFS=/
  for seg in $p; do
    case "$seg" in
      ''|.) ;;
      ..) out="${out%/*}" ;;
      *) out="$out/$seg" ;;
    esac
  done
  printf %s "${out:-/}"
}

removal_gate() {
  local method path
  method="$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')"
  path="$(normalize_removal_path "${2:-}")"
  [ "$method" = "DELETE" ] || return 0
  local restore_extglob=0
  shopt -q extglob || { shopt -s extglob; restore_extglob=1; }
  local rc=1 ep
  for ep in "*/admin/track/+([!/])" "*/admin/track/+([!/])/profile/+([!/])/credits" "*/admin/profile/+([!/])"; do
    # shellcheck disable=SC2053  # RHS unquoted so the extglob pattern is active.
    if [[ "$path" == $ep ]]; then rc=0; break; fi
  done
  (( restore_extglob )) && shopt -u extglob
  [ "$rc" -eq 0 ] || return 0
  cat >&2 <<EOM
MUSO_REMOVAL_NO_SELF_APPROVE: ${method} ${path} is a removal (whole-track tombstone, a credit removed from a profile, or the profile soft-delete). God-mode self-approve never covers removals, and core refuses agent removals (credit_removal_agent_refused). Do not retry through another wrapper or identity.
Instead: read the entity back and tell the requester what removal would do (the track + its N credits, or the profile + its N served credits). Ask for the reason if none is recorded (DSP-removal proof or different-profile proof, plus a label check). Profile hides are not available to the agent; the request goes on the GDPR register for identity verification (verified claim or matching ID) and a person-approved takedown. A recorded removal goes to a named human from their own login.
EOM
  return 1
}

if ! removal_gate "${1:-}" "${2:-}"; then
  exit 3
fi

if ! claim_verify_pace_gate "$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')" "${2:-}"; then
  exit 3
fi

# Slack sends are the alerting path, not admin-API writes: the codex-health
# gate below guards state-changing core/stripe writes, and blocking Slack
# during a codex outage would suppress the very page about that outage
# (muso sets MUSO_HOOK_PROVIDER so one hook can branch per backend).
if [ "${MUSO_HOOK_PROVIDER:-}" = "slack" ]; then
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_HEALTH_LIB="$SCRIPT_DIR/lib/codex-health.sh"
GATEWAY_UNIT="openclaw-gateway-main"
WINDOW_MIN="5"

if [ ! -r "$CODEX_HEALTH_LIB" ]; then
  echo "REFUSED (muso-prewrite-hook): cannot read codex-health lib at $CODEX_HEALTH_LIB" >&2
  exit 3
fi
# shellcheck disable=SC1090
source "$CODEX_HEALTH_LIB"

# The <METHOD> <PATH> <ENV> args are informational only: muso already
# exempts reads, and the health verdict does not depend on the endpoint.
if ! reason="$(codex_health_gate "$GATEWAY_UNIT" "$WINDOW_MIN" 2>&1)"; then
  echo "REFUSED (muso-prewrite-hook): ${reason:-codex health gate returned non-zero}" >&2
  echo "Model health is degraded or unverifiable — admin writes are blocked. Retry once codex health is confirmed, or defer to a human." >&2
  exit 3
fi
exit 0
