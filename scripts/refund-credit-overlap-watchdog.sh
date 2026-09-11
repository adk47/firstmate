#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# Refund + credit-balance overlap watchdog
#
# Pages #clio_devops when a customer receives BOTH a cash refund and a live
# customer-balance concession credit — the same goodwill paid twice.
#
# WHY THIS EXISTS, AND WHY IT IS THE LOAD-BEARING LAYER
# A 2026-09-09 finance audit found 223 customers in that state ($4,827.65),
# going back to 2022. Two facts from the investigation decide this script's
# design:
#
#   1. NONE of it came from the agent. Cross-referencing the agent's own refund
#      log (workspaces/operations/memory/refund-log/, 138 refunds since
#      2026-04) against the audit's 234 flagged refunds gives ZERO overlap.
#      Every case came from a human in the Stripe dashboard.
#   2. The money gate (muso-stripe-write.sh) therefore could not have caught a
#      single one. It gates the agent and CLI path; the dashboard bypasses it.
#
# So a pre-write gate is structurally incapable of covering the path where all
# the damage actually happened, and this after-the-fact sweep is the only
# mechanical layer that does. It is also the only thing that can see the
# 2025-12-05 chronology, where Stripe minted the proration credit 0.96h AFTER
# the refund — no pre-write check can see a credit that does not exist yet.
#
# The reason this ran undetected for four years is simply that nothing looked.
#
# DETECT-AND-PAGE ONLY. It never moves money. Zeroing a customer's balance is a
# human decision with a customer-facing consequence (see
# scripts/remediate-refund-credit-overlap.sh, which is dry-run by default and
# needs an allowlisted approver). An auto-remediating watchdog here would be
# clawing back credit from real people on a cron.
#
# Scheduled by /etc/cron.d/refund-credit-overlap-watchdog (installed via
# scripts/install-aux-units.sh) — edit there, never on node-8 directly.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STRIPE_BIN="${STRIPE_BIN:-stripe}"
STRIPE_CREDIT_LIB="${STRIPE_CREDIT_LIB:-$SCRIPT_DIR/lib/stripe-credit.sh}"
SLACK_LIB="${SLACK_NOTIFY_LIB:-$SCRIPT_DIR/lib/slack-notify.sh}"
# State lives under /var/lib, NOT /opt/hydra — the deploy rsync overwrites the
# latter, which would reset the watermark and re-page every known pair.
STATE_DIR="${REFUND_OVERLAP_STATE_DIR:-/var/lib/hydra-refund-overlap}"
STATE_FILE="$STATE_DIR/seen-refunds"
# The lookback must outlive the settlement horizon by at least one full cron
# interval, or the horizon is decorative: a refund still unsettled at one sweep
# has aged by a whole interval before the next, and if that puts it outside the
# query window it is never watermarked AND never re-examined. With a 48h horizon
# on a daily cron, a 52h lookback loses every refund aged 28-48h at its sweep.
LOOKBACK_HOURS="${REFUND_OVERLAP_LOOKBACK_HOURS:-80}"
# Must match the cron cadence in scripts/install-aux-units.sh (daily, `17 7 * * *`).
SCHEDULE_INTERVAL_HOURS="${REFUND_OVERLAP_SCHEDULE_INTERVAL_HOURS:-24}"
# Slack for a late/slow/retried run, so a sweep that starts a few hours behind
# schedule does not silently drop the tail of its own window.
WINDOW_MARGIN_HOURS="${REFUND_OVERLAP_WINDOW_MARGIN_HOURS:-8}"
# Stripe can mint the compensating credit AFTER the refund — the 2025-12-05
# exemplar had it appear 0.96h later. A refund that looks clean on the sweep
# right after it lands is therefore NOT yet proven clean, and marking it seen
# then would hide the duplicate forever. Keep re-checking until the refund is
# this old, and only then treat "no credit" as final.
SETTLEMENT_HOURS="${REFUND_OVERLAP_SETTLEMENT_HOURS:-48}"
DRY_RUN="${REFUND_OVERLAP_DRY_RUN:-0}"

for lib in "$STRIPE_CREDIT_LIB" "$SLACK_LIB"; do
  if [ ! -r "$lib" ]; then
    echo "FATAL: cannot read $lib" >&2
    exit 2
  fi
done
# shellcheck disable=SC1090
source "$STRIPE_CREDIT_LIB"
# shellcheck disable=SC1090
source "$SLACK_LIB"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

# Page #clio_devops and RETURN THE REAL DELIVERY STATUS.
#
# slack_notify_critical() cannot be used for anything we gate on: it delegates to
# slack_notify(), whose contract deliberately swallows failure — `slack_load_env
# ... || return 0` and `muso slack send ... || true`. In production it returns 0
# whether or not Slack ever saw the message. Watermarking a finding behind that
# is a silent, permanent loss: Slack down, finding appended to seen-refunds,
# exit 0, and no later sweep ever looks at that refund again.
#
# slack_notify_payload_file_status() is the one helper that returns the decoded
# delivery result (it also decodes Slack's HTTP-200 {"ok":false} trap).
page_critical_with_status() {
  local msg="$1" payload rc=0
  payload="$(mktemp)" || return 1
  if ! jq -n --arg c "${SLACK_CHANNEL:-}" \
        --arg t "<@${SLACK_UID_NICK:-}> <@${SLACK_UID_AARON:-}> $msg" \
        '{channel: $c, text: $t}' > "$payload" 2>/dev/null; then
    rm -f "$payload"; return 1
  fi
  slack_notify_payload_file_status "$payload" || rc=$?
  rm -f "$payload"
  return "$rc"
}

# mkdir -p, NOT `install -d`: install -d re-chmods an EXISTING directory to 0755
# even without -m, which would silently widen a state dir someone tightened.
mkdir -p "$STATE_DIR"
[ -f "$STATE_FILE" ] || : >"$STATE_FILE"

# A settlement horizon that merely fits inside the lookback is NOT enough, and
# that weaker assertion is what let 48h/52h through: it guarantees one look, not
# a look AFTER settlement. The refund must still be queryable when its re-check
# actually falls due, which is one scheduling interval later.
REQUIRED_LOOKBACK=$(( SETTLEMENT_HOURS + SCHEDULE_INTERVAL_HOURS + WINDOW_MARGIN_HOURS ))
if [ "$LOOKBACK_HOURS" -lt "$REQUIRED_LOOKBACK" ]; then
  log "FATAL: lookback (${LOOKBACK_HOURS}h) must cover the settlement horizon plus one scheduling interval plus margin (${SETTLEMENT_HOURS}+${SCHEDULE_INTERVAL_HOURS}+${WINDOW_MARGIN_HOURS}=${REQUIRED_LOOKBACK}h), or a refund unsettled at one sweep ages out of the window before the next"
  exit 2
fi

now_epoch="$(date -u +%s)"
since_epoch="$(( now_epoch - LOOKBACK_HOURS * 3600 ))"
settled_before="$(( now_epoch - SETTLEMENT_HOURS * 3600 ))"

# Pull recent refunds. `created[gte]` bounds the read; the watermark file
# bounds the PAGING (a refund already reported never pages twice), so the
# lookback can safely overlap the cron cadence.
# Page through the whole window. A bare --limit 100 silently truncates: a burst
# of >100 refunds in the lookback would leave the oldest permanently unscanned,
# because they fall out of the rolling window before the next tick ever sees
# them. A detector that quietly stops at 100 is how this class went unnoticed for
# four years in the first place.
refunds_json='{"object":"list","data":[]}'
starting_after=""
sweep_incomplete=0
PAGE_CEILING="${REFUND_OVERLAP_PAGE_CEILING:-20}"
for _page in $(seq 1 "$PAGE_CEILING"); do
  if [ -n "$starting_after" ]; then
    page="$("$STRIPE_BIN" refunds list -d "created[gte]=$since_epoch" -d "starting_after=$starting_after" --limit 100 2>/dev/null)" || page=""
  else
    page="$("$STRIPE_BIN" refunds list -d "created[gte]=$since_epoch" --limit 100 2>/dev/null)" || page=""
  fi
  if [ -z "$page" ] || ! printf '%s' "$page" | jq -e 'type == "object" and (.data | type == "array")' >/dev/null 2>&1; then
    log "FATAL: could not list refunds from Stripe"
    slack_notify ":warning: refund-credit-overlap watchdog could not read Stripe refunds — duplicate-concession detection is BLIND right now."
    exit 2
  fi
  refunds_json="$(jq -s '{object:"list", data: (.[0].data + .[1].data)}' <(printf '%s' "$refunds_json") <(printf '%s' "$page"))"
  n_page="$(printf '%s' "$page" | jq '.data | length')"
  has_more="$(printf '%s' "$page" | jq -r '.has_more // false')"
  if [ "$n_page" -lt 100 ]; then break; fi
  starting_after="$(printf '%s' "$page" | jq -r '.data[-1].id')"
  # Exhausting the ceiling with Stripe still reporting has_more means the window
  # genuinely exceeds what this sweep can see. Warning and carrying on would
  # report a PARTIAL dataset as a complete one: an overlap in an unscanned row is
  # missed, and if everything scanned is clean the run exits 0 and the refund
  # eventually ages out of the window unexamined. Fail the sweep instead, and
  # watermark nothing — an empty state file is the durable retry signal.
  if [ "$_page" -ge "$PAGE_CEILING" ] && [ "$has_more" = "true" ]; then
    sweep_incomplete=1
    break
  fi
done

if [ "${sweep_incomplete:-0}" -eq 1 ]; then
  log "FATAL: refund pagination hit the ${PAGE_CEILING}-page ceiling with has_more=true; this sweep is INCOMPLETE"
  slack_notify ":rotating_light: refund-credit-overlap watchdog sweep is INCOMPLETE — the ${LOOKBACK_HOURS}h window holds more refunds than the ${PAGE_CEILING}-page ceiling can scan, so an overlap may be sitting in a row this run never saw. Nothing was watermarked; raise the ceiling or shorten the window."
  exit 4
fi
total="$(printf '%s' "$refunds_json" | jq '.data | length')"
log "scanning $total refund(s) created in the last ${LOOKBACK_HOURS}h"

findings=()
checked=0
unverifiable=0

while IFS=$'\t' read -r refund_id charge_id refund_created refund_status; do
  [ -n "$refund_id" ] || continue
  grep -qxF "$refund_id" "$STATE_FILE" && continue   # already reported
  checked=$((checked + 1))

  # A refund that never paid out is not a concession. Without this the sweep
  # reported "duplicate concession" for a FAILED refund sitting next to a live
  # credit — and watermarked it, so the real overlap could never be found later.
  # A missing or non-numeric `created` used to be coerced to epoch 0, which reads
  # as "older than any settlement cutoff" — so an unreadable row was watermarked
  # as permanently settled and its late-minted credit never checked. Same
  # coercion class as the balance-transaction schema bug: refuse, do not guess.
  if ! [[ "$refund_created" =~ ^[0-9]+$ ]] || [ "$refund_created" -le 0 ]; then
    unverifiable=$((unverifiable + 1))
    log "WARN: refund $refund_id has missing/invalid created '${refund_created:-<absent>}' — not marking seen, will retry"
    continue
  fi

  case "$refund_status" in
    succeeded)
      : ;;
    failed|canceled)
      # Terminal and no cash left the company: nothing to detect, ever.
      echo "$refund_id" >>"$STATE_FILE"; continue ;;
    pending|requires_action)
      # It may still succeed, so do NOT watermark — just skip this sweep.
      log "refund $refund_id is $refund_status; not yet cash, leaving it for a later sweep"
      continue ;;
    *)
      # Missing or unrecognised status: we cannot tell whether cash moved.
      unverifiable=$((unverifiable + 1))
      log "WARN: refund $refund_id has missing/unknown status '${refund_status:-<absent>}' — not marking seen, will retry"
      continue ;;
  esac

  cust=""
  if [ -n "$charge_id" ] && [ "$charge_id" != "-" ] && [ "$charge_id" != "null" ]; then
    cjson="$("$STRIPE_BIN" charges retrieve "$charge_id" 2>/dev/null || true)"
    cust="$(printf '%s' "$cjson" | jq -r '.customer // empty' 2>/dev/null || true)"
  fi
  if [ -z "$cust" ]; then
    unverifiable=$((unverifiable + 1))
    log "WARN: could not resolve customer for $refund_id (charge=$charge_id) — not marking seen, will retry"
    continue
  fi

  if ! credit="$(customer_live_proration_credit "$cust")"; then
    # Do NOT record this refund as seen: an unverifiable read must be retried,
    # not silently converted into a clean bill of health.
    unverifiable=$((unverifiable + 1))
    log "WARN: could not read credit balance for $cust ($refund_id) — not marking seen, will retry"
    continue
  fi

  if [ -n "$credit" ]; then
    amount="$(printf '%s' "$refunds_json" | jq -r --arg r "$refund_id" '.data[] | select(.id == $r) | .amount')"
    findings+=("$refund_id|$cust|$amount|$credit")
    log "FINDING: $refund_id (customer $cust, refunded ${amount}c) still holds live credit: $credit"
  fi
  # A finding is watermarked only after its alert is DELIVERED (below) —
  # watermarking at scan time means one transient Slack failure permanently
  # suppresses it.
  #
  # A CLEAN refund is watermarked only once it is past the settlement horizon.
  # Before that, "no credit right now" is not the same claim as "no credit will
  # ever appear", and conflating the two is what would let the late-minted
  # credit — the whole reason this detector exists — slip through unseen.
  if [ -z "$credit" ]; then
    if [ -n "$refund_created" ] && [ "$refund_created" -lt "$settled_before" ] 2>/dev/null; then
      echo "$refund_id" >>"$STATE_FILE"
    else
      log "clean but UNSETTLED: $refund_id stays eligible for re-check until ${SETTLEMENT_HOURS}h after the refund"
    fi
  fi
  # A literal "-" for a missing charge, NOT an empty field. `IFS=$'\t'` treats tab
  # as IFS-whitespace, so consecutive tabs COLLAPSE: an empty middle column makes
  # `read` shift `created` into `charge_id` and leave `refund_created` empty. That
  # silently mis-parses every refund with no charge — the settlement-horizon
  # comparison then sees an empty string and the row can never settle.
done < <(printf '%s' "$refunds_json" | jq -r '.data[] | [.id, (if (.charge // "") == "" then "-" else .charge end), (if ((.created | type) == "number" and .created > 0) then .created else "-" end), (if (.status // "") == "" then "-" else .status end)] | @tsv')

log "checked=$checked findings=${#findings[@]} unverifiable=$unverifiable"

# An unverifiable row is NOT a clean row, and this is the only detector that sees
# the human dashboard path. If reads keep failing for the same refund on every
# daily sweep, it ages out of the 80h window still unexamined and a real
# cash-plus-credit overlap is lost permanently — with nothing ever said, because
# the previous version logged a line and exited 0. A log line is not a signal
# here: slack_notify discards both streams, so nobody is reading this log.
#
# So: page AND exit non-zero whenever anything could not be verified. The exit
# code is what makes a wedged cron visible to the runner as well as to Slack.
if [ "$unverifiable" -gt 0 ]; then
  unverified_msg=":warning: refund-credit-overlap watchdog left ${unverifiable} refund(s) UNVERIFIABLE this sweep — this is NOT a clean sweep. Those refunds are deliberately left un-watermarked so the next run retries them, but if the reads keep failing they will age out of the ${LOOKBACK_HOURS}h window unexamined and any duplicate concession on them is lost silently. Check Stripe API health."
  slack_notify "$unverified_msg" || true
  log "PAGED: ${unverifiable} unverifiable refund(s) this sweep"
fi

if [ "${#findings[@]}" -eq 0 ]; then
  if [ "$unverifiable" -gt 0 ]; then exit 3; fi
  exit 0
fi

lines=""
for f in "${findings[@]}"; do
  IFS='|' read -r rid cus amt cred <<<"$f"
  lines+="\n• \`$rid\` — customer \`$cus\`, refunded \$$(awk -v c="$amt" 'BEGIN{printf "%.2f", c/100}'), still holds credit: $cred"
done

msg=":rotating_light: *Duplicate concession detected* — cash refund AND a live customer-balance credit for the same customer.${lines}\n\nOne unused period should produce ONE concession. Zero the credit, or confirm it was deliberate. Runbook: \`scripts/remediate-refund-credit-overlap.sh --help\` (dry-run by default)."

if [ "$DRY_RUN" = "1" ]; then
  log "DRY RUN — would have paged (nothing watermarked):"
  printf '%b\n' "$msg"
  exit 0
fi
if page_critical_with_status "$msg"; then
  # Delivered: only now are these findings recorded as seen.
  for f in "${findings[@]}"; do echo "${f%%|*}" >>"$STATE_FILE"; done
  log "paged #clio_devops with ${#findings[@]} finding(s); watermarked after delivery"
  # Findings delivered, but the sweep was still incomplete.
  if [ "$unverifiable" -gt 0 ]; then exit 3; fi
else
  log "ERROR: Slack delivery FAILED — findings left un-watermarked so the next run retries them"
  exit 3
fi
