#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Approval-Stamp Audit
#
# The answer to one question, asked of the verify ledger and nothing else:
#   "was every customer note we sent authorized by an approval we can name?"
#
# Captain, 2026-11-03: "users aren't in the dark ... no human reviews is the
# goal". The gate learned two approvers that day — a human's Slack id (the
# original path) and a Fable ruling id for a template class the ruling
# pre-approved (policies/fable-rulings.json) — and stamped every claimed send
# with approver_kind + approval_id + the template identity hash. A stamp nobody
# checks is decoration, so this page is the check: every send from --since on
# must carry a kind we know, an id that kind allows, an id matching
# approved_by, a template hash, and (for a ruling id) a registry entry that
# actually pre-approves that campaign+copy.
#
# What it is NOT: it does not re-read the prose. body_sha256 pins the bytes sent
# and the gate's copy tests pin the templates; this audit answers authorization.
#
# Fail closed: an unreadable ledger, an unreadable registry or a ledger that
# needs a migration all page — "I could not check" is never reported as clean.
#
# One page per offending row (a ledger id is immutable evidence; re-paging it
# daily trains people to ignore the channel). A standing problem keeps the exit
# code red and says so on stdout, so `systemctl --failed` still shows it.
#
# Runs every 15 min from hydra-approval-stamps-audit.timer (installed by
# scripts/install-aux-units.sh on node-8). Reads the ledger read-only.
#
# Flags:
#   --since YYYY-MM-DD   audit sends from this UTC day on (default below)
#   --dry-run            compute + print, never post to Slack AND never advance the watermark: a preview must not
#                        silence the live timer (QA 2026-11-04 round 4 finding 3)
#
# Env knobs (mainly for tests; defaults target the live host):
#   APPROVAL_AUDIT_LEDGER     the verify ledger sqlite file
#   APPROVAL_AUDIT_HELPER     scripts/credit_review/verify_ledger.py
#   APPROVAL_AUDIT_REGISTRY   policies/fable-rulings.json
#   APPROVAL_AUDIT_STATE_FILE per-row-id alert watermarks
#   APPROVAL_AUDIT_SLACK_CHANNEL  target channel (default #clio_devops)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

LOGPREFIX="[audit-approval-stamps $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEDGER="${APPROVAL_AUDIT_LEDGER:-/var/lib/hydra/credit-review/ledger.sqlite3}"
HELPER="${APPROVAL_AUDIT_HELPER:-$_SELF_DIR/credit_review/verify_ledger.py}"
REGISTRY="${APPROVAL_AUDIT_REGISTRY:-$_SELF_DIR/../policies/fable-rulings.json}"
# Day the stamp shipped. Rows from earlier days were written before the stamp existed; they are history, not a
# finding (and re-auditing them would bury a real one).
SINCE="${APPROVAL_AUDIT_SINCE:-2026-11-04}"
STATE_FILE="${APPROVAL_AUDIT_STATE_FILE:-/var/lib/hydra/approval-stamps-audit/seen.json}"
DRY_RUN=0

# slack-notify.sh reads this (target channel). Export before sourcing so its `:=` default doesn't override us.
export SLACK_CHANNEL="${APPROVAL_AUDIT_SLACK_CHANNEL:-C0ADV2W76G4}"  # #clio_devops

log() { echo "$LOGPREFIX $1"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --since) SINCE="${2:-}"; shift 2 ;;
    --since=*) SINCE="${1#--since=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done
printf '%s' "$SINCE" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || { echo "bad --since '$SINCE'" >&2; exit 2; }

# shellcheck source=lib/slack-notify.sh
source "$_SELF_DIR/lib/slack-notify.sh"

page() {   # page <text>  — one #clio_devops post; RETURNS the real delivery status (QA 2026-11-04 finding 3).
  # This script advances a per-row watermark after paging: if a Slack failure were swallowed (|| true), the row would be
  # recorded as paged forever and an unauthorized customer note would never be reported again.
  if [ "$DRY_RUN" -eq 1 ]; then printf '%s\n' "$1"; return 0; fi
  slack_notify_critical_status "$1"
}

command -v python3 >/dev/null 2>&1 || { log "ERROR: python3 not on PATH"; exit 2; }
command -v jq >/dev/null 2>&1 || { log "ERROR: jq not on PATH"; exit 2; }
[ -r "$HELPER" ] || { log "ERROR: ledger helper $HELPER not readable"; exit 2; }
[ -r "$REGISTRY" ] || {
  # An unreadable registry means no ruling id can be verified: every ruled send becomes unverifiable, which is a
  # finding, not a quiet pass.
  page ":warning: *approval-stamp audit cannot run* — registry $REGISTRY is not readable, so no ruling id can be verified. Ruled sends are unverifiable until it is restored." \
    || log "ERROR: that page did NOT reach Slack"
  exit 2
}

set +e
OUT="$(python3 -I "$HELPER" --db "$LEDGER" --readonly audit-stamps --since "$SINCE" --registry "$REGISTRY" 2>&1)"
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
  log "ERROR: ledger audit failed (rc=$RC): $OUT"
  page ":warning: *approval-stamp audit could not run* (rc=$RC) on $LEDGER since $SINCE. This is NOT a clean result — the ledger or its schema is unreadable.
\`\`\`
$(printf '%s' "$OUT" | head -c 400)
\`\`\`" || log "ERROR: that page did NOT reach Slack"
  exit 2
fi

CHECKED="$(printf '%s' "$OUT" | jq -r '.checked // 0')"
COUNT="$(printf '%s' "$OUT" | jq -r '.problems | length')"
if [ "$COUNT" -eq 0 ]; then
  log "clean: $CHECKED send(s) since $SINCE carry a valid approval stamp"
  exit 0
fi

# Which findings are NEW (one page per ledger row, ever).
mkdir -p "$(dirname "$STATE_FILE")"
SEEN='{}'
[ -s "$STATE_FILE" ] && SEEN="$(jq -c '.' "$STATE_FILE" 2>/dev/null || echo '{}')"
NEW_JSON="$(printf '%s' "$OUT" | jq -c --argjson seen "$SEEN" \
  '[.problems[] | select(($seen[(.id|tostring)] // 0) == 0)]')"
NEW_COUNT="$(printf '%s' "$NEW_JSON" | jq -r 'length')"

if [ "$NEW_COUNT" -gt 0 ]; then
  BULLETS="$(printf '%s' "$NEW_JSON" | jq -r \
    '.[] | "• ledger #\(.id) [\(.campaign)/\(.copy_ref // "?")] \(.status) \(.day): \(.why)"')"
  if ! page ":rotating_light: *customer note(s) without a valid approval stamp* — $NEW_COUNT new of $COUNT since $SINCE (of $CHECKED send(s)). Every note must carry an approver we can name; these do not:
$BULLETS
Ledger: $LEDGER · registry: $REGISTRY · audit: scripts/audit-approval-stamps.sh"; then
    log "ERROR: the page did NOT reach Slack; the watermark is NOT advanced, so the next run retries these $NEW_COUNT row(s)"
    exit 2
  fi
  # Advance the watermark for the ids we just paged, and only those (a crash before the page re-pages next tick). A DRY
  # RUN prints instead of posting, so it must not record anything: an operator previewing a new unstamped send would
  # otherwise make the next live timer treat it as already paged (QA 2026-11-04 round 4 finding 3).
  if [ "$DRY_RUN" -eq 1 ]; then
    log "dry run: would page $NEW_COUNT new finding(s) (watermark NOT advanced); $COUNT total"
  else
    NEWSTATE="$(printf '%s' "$NEW_JSON" | jq -c --argjson seen "$SEEN" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      'reduce .[] as $p ($seen; .[($p.id|tostring)] = $now)')"
    TMP="$(mktemp "$STATE_FILE.XXXXXX")"
    printf '%s\n' "$NEWSTATE" > "$TMP" && mv -f "$TMP" "$STATE_FILE"
    log "paged $NEW_COUNT new finding(s); $COUNT total"
  fi
else
  log "standing: $COUNT finding(s) already paged, still present (no repage) — first: ledger #$(printf '%s' "$OUT" | jq -r '.problems[0].id')"
fi
# Non-zero whenever anything is wrong, paged-before or not: a standing unauthorized send stays red until a human
# explains it (the audit never repairs, and never deletes evidence).
exit 1
