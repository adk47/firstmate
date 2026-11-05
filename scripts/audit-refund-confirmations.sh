#!/usr/bin/env bash
# audit-refund-confirmations.sh - "refund issued with no confirmation > 24 h" (captain 2026-11-03 20:04Z building
# rule; Fable d2 ruling refund-confirm-1103, firstmate 109).
#
# A refund is money that already left the account. The customer must be told. Nothing else in this repo pages when a
# refund exists and no note went out, so a refund executed at 22:00Z could sit silent until someone remembers to look -
# which is exactly how two refunded users spent the night in the dark on 2026-11-03.
#
# What it does, and refuses to do:
#   * reads the processor refund facts and the verify ledger, both READ-ONLY. It sends nothing, claims nothing and
#     repairs nothing. Since QA 2026-11-04 (the last open finding on #1728) the feed is DERIVED FROM STRIPE on every
#     run via lib/refund-feed-from-stripe.sh: the audit used to read /var/lib/hydra/credit-review/refund-events.jsonl,
#     which nothing wrote, so after deploy it would have posted one generic "could not check" a day forever and never
#     named a refund. An alert that cannot see its subject is not an alert; the processor is the only authority on
#     which refunds exist, and the gate already reads it with the same credential. REFUND_AUDIT_FEED still overrides
#     the feed for tests and for a future writer, but production depends on nobody.
#   * pages #clio_devops for every refund older than --hours (default 24) with NO refund-confirm note in state 'sent';
#   * pages ONCE per refund id, ever (watermark in a state file): re-paging immutable evidence trains people to mute
#     the channel, and a refund does not become less told by waiting;
#   * pages "could not check" (exit 2) when the feed or the ledger cannot be read - never "clean" for a check it could
#     not run. A missing feed means nobody is measuring, which is its own outage;
#   * exits 1 when a finding stands (even already-paged), so a caller that ignores Slack still sees red. QA 2026-11-04
#     was right that "standing" used to mean nothing: once a paged refund left the seven-day window it vanished from the
#     feed and the run went clean. Untold refunds are now RETAINED by id in the cursor state and re-judged against the
#     ledger on every run until a note is sent;
#   * owns the CURSOR, and advances it only after a comparison it could actually make. The feed writer holds no state,
#     because a writer that advances its own cursor before the ledger is read turns an eight-day ledger outage into
#     permanently unwatched money (QA 2026-11-04, twice).
#
# Env knobs (tests + ops): REFUND_AUDIT_FEED, REFUND_AUDIT_LEDGER, REFUND_AUDIT_HELPER, REFUND_AUDIT_STATE_FILE,
# REFUND_AUDIT_SLACK_CHANNEL, REFUND_AUDIT_HOURS, REFUND_AUDIT_FEED_STATE, REFUND_AUDIT_FEED_DAYS,
# REFUND_AUDIT_MAX_CATCHUP_DAYS, REFUND_AUDIT_FEED_BOOTSTRAP_EPOCH. Flags: --hours N, --dry-run, --now YYYY-MM-DDTHH:MM:SSZ.
set -uo pipefail

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly FEED_WRITER_DEFAULT="$_SELF_DIR/lib/refund-feed-from-stripe.sh"
readonly DEFAULT_LEDGER="/var/lib/hydra/credit-review/ledger.sqlite3"
readonly DEFAULT_STATE="/var/lib/hydra/refund-confirm-audit/seen.json"
readonly DEFAULT_FEED_STATE="/var/lib/hydra/credit-review/refund-feed-state.json"
# The first-run floor, used ONLY when no cursor has ever been recorded: 2026-11-03T00:00:00Z, the day the
# refund-confirm campaign went live. A fixed instant, never "now minus N days" - see the bootstrap comment below.
readonly BOOTSTRAP_EPOCH=1793664000
readonly SLACK_CHANNEL_DEFAULT="C0ADV2W76G4"   # #clio_devops
FEED="${REFUND_AUDIT_FEED:-}"          # empty = derive the feed from Stripe (the production path)
FEED_WRITER="${REFUND_AUDIT_FEED_WRITER:-$FEED_WRITER_DEFAULT}"
LEDGER="${REFUND_AUDIT_LEDGER:-$DEFAULT_LEDGER}"
HELPER="${REFUND_AUDIT_HELPER:-$_SELF_DIR/credit_review/verify_ledger.py}"
STATE_FILE="${REFUND_AUDIT_STATE_FILE:-$DEFAULT_STATE}"
INFRA_STATE="${REFUND_AUDIT_INFRA_STATE:-${STATE_FILE%.json}.infra.json}"
FEED_STATE="${REFUND_AUDIT_FEED_STATE:-${REFUND_FEED_STATE:-$DEFAULT_FEED_STATE}}"
FEED_DAYS="${REFUND_AUDIT_FEED_DAYS:-7}"
MAX_CATCHUP_DAYS="${REFUND_AUDIT_MAX_CATCHUP_DAYS:-60}"
SLACK_CHANNEL="${REFUND_AUDIT_SLACK_CHANNEL:-$SLACK_CHANNEL_DEFAULT}"
HOURS="${REFUND_AUDIT_HOURS:-24}"
DRY_RUN=0
NOW=""

usage() { echo "usage: $0 [--hours N] [--dry-run] [--now YYYY-MM-DDTHH:MM:SSZ]"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --hours) [ $# -ge 2 ] || { usage; exit 2; }; HOURS="$2"; shift 2 ;;
    --now)   [ $# -ge 2 ] || { usage; exit 2; }; NOW="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
case "$HOURS" in ''|*[!0-9.]*) echo "REFUND AUDIT: --hours must be a number (got '$HOURS')" >&2; exit 2 ;; esac
if [ -n "$NOW" ] && ! printf '%s' "$NOW" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
  echo "REFUND AUDIT: --now must be YYYY-MM-DDTHH:MM:SSZ (got '$NOW')" >&2; exit 2
fi

# QA 2026-11-04 finding 4: ONE scratch dir per run, never a shared literal path - two concurrent runs (the 30 min timer
# and a human) used to write and read the same stderr file, so a run could report the other run's diagnosis. Removed on
# every exit path by the trap below.
SCRATCH_DIR="$(mktemp -d "${PAPERCLIP_RUN_SCRATCH_DIR:-/var/tmp}/refund-audit.XXXXXX")"
trap 'rm -rf "$SCRATCH_DIR"' EXIT INT TERM

notify() { # <text>: page #clio_devops; returns the REAL delivery status. Dry run prints instead (stdout = machine channel).
  if [ "$DRY_RUN" = "1" ]; then printf 'PAGE %s\n' "$1"; return 0; fi
  if [ -r "$_SELF_DIR/lib/slack-notify.sh" ]; then
    # shellcheck source=/dev/null
    source "$_SELF_DIR/lib/slack-notify.sh"
    # QA 2026-11-04 finding 3: the status is RETURNED, because this script dedupes on a watermark. `|| true` here meant a
    # Slack outage looked like a delivered page and the refund id (or the daily cannot-check key) was written off.
    SLACK_CHANNEL="$SLACK_CHANNEL" slack_notify_critical_status "$1"
  else
    echo "REFUND AUDIT: slack helper missing ($_SELF_DIR/lib/slack-notify.sh); nothing paged" >&2
    return 1
  fi
}

# An "I could not check" page is an outage too, but one that tends to last for days (a feed nobody has started writing
# yet). Paging it every 15 min is how a channel gets muted, which would also mute the refund findings - so infra pages
# for the SAME reason repeat at most once a day, while the exit code stays red on every run.
cannot_check() { # <why>: a check we could not run is an outage, never a pass.
  local key last now_s
  key="$(printf '%s' "$1" | sha256sum | awk '{print $1}')"
  now_s="$(date -u +%s)"
  last="$(mkdir -p "$(dirname "$INFRA_STATE")" 2>/dev/null; "${JQ_BIN:-jq}" -r --arg k "$key" '.[$k] // 0' "$INFRA_STATE" 2>/dev/null || echo 0)"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  echo "cannot-check: $1"
  if [ $(( now_s - last )) -ge 86400 ]; then
    if ! notify ":warning: refund-confirmation audit COULD NOT RUN — $1. Until it runs, nobody is measuring whether refunded customers were told."; then
      echo "REFUND AUDIT: the cannot-check page did NOT reach Slack; the 24 h watermark is not advanced (the next tick retries)" >&2
      exit 2
    fi
    if [ "$DRY_RUN" = "0" ]; then
      local tmp
      tmp="$(mktemp "$INFRA_STATE.XXXXXX")" \
        && "${JQ_BIN:-jq}" -c --arg k "$key" --argjson t "$now_s" '.[$k] = $t' "$INFRA_STATE" 2>/dev/null > "$tmp" \
        || printf '{"%s": %s}' "$key" "$now_s" > "$tmp"
      [ -s "$tmp" ] && mv "$tmp" "$INFRA_STATE" || rm -f "$tmp"
    fi
  else
    echo "(the same cannot-check was paged within the last 24 h; not paging again)"
  fi
  exit 2
}

command -v python3 >/dev/null 2>&1 || cannot_check "python3 is not installed"
[ -r "$HELPER" ] || cannot_check "the ledger helper is missing ($HELPER)"
# The feed: an explicit file when one is named (tests, or a future writer), otherwise the processor's own answer. A
# live audit MUST NOT be able to skip this and read a stale file that happens to exist.
CURSOR_ACTIVE=0
RUN_STARTED=""
if [ -z "$FEED" ]; then
  FEED="$SCRATCH_DIR/refund-events.jsonl"
  [ -r "$FEED_WRITER" ] || cannot_check "the refund feed writer is missing ($FEED_WRITER) - no refund is being measured"
  CURSOR_ACTIVE=1
  RUN_STARTED="$(date -u +%s)"
  # the window: the rolling lookback, or further back when the last run that could actually COMPARE was longer ago than
  # that. `covered_through` is written at the very bottom of this script, only after the ledger answered.
  case "$FEED_DAYS" in ''|*[!0-9]*) FEED_DAYS=7 ;; esac
  case "$MAX_CATCHUP_DAYS" in ''|*[!0-9]*) MAX_CATCHUP_DAYS=60 ;; esac
  since=$(( RUN_STARTED - FEED_DAYS * 86400 ))
  covered=""
  if [ -e "$FEED_STATE" ]; then
    # Validate the COMPLETE shape, not just the cursor: `outstanding` is where the ids of already-paged but still-untold
    # refunds live, so a state file with a good covered_through and a malformed outstanding would read as "nothing
    # retained" and let those refunds age out of the alert (QA 2026-11-04 round 4 finding 1). One verdict, three facts.
    # The field must EXIST: this writer always emits it, so an absent one is a truncated or foreign file, and "no list"
    # is not the same fact as "an empty list" - the first cannot be told apart from "the retained ids were lost"
    # (QA 2026-11-05 round 5 finding 4).
    state_verdict="$("${JQ_BIN:-jq}" -r '
      if type != "object" then "not a JSON object"
      elif (.covered_through | type) != "number" then "covered_through is \(.covered_through | type)"
      elif (has("outstanding") | not) then "outstanding is missing"
      elif (.outstanding | type) != "array" then "outstanding is \(.outstanding | type)"
      elif any(.outstanding[]; ((type != "object")
              or (((.refund_id // "") | type) != "string")
              or ((.refund_id // "") == "")))
        then "an outstanding row is not an object with a non-empty string refund_id"
      else "ok" end' "$FEED_STATE" 2>/dev/null || echo "unparseable")"
    if [ "$state_verdict" != "ok" ]; then
      # State that cannot be read is NOT a licence to shrink the window: doing so would silently cover only the last
      # week and drop the outstanding refund ids the file was holding. Fail closed and name the file; repairing or
      # removing it is a deliberate human act, not a quiet fallback.
      cannot_check "the refund feed cursor ($FEED_STATE) exists but its state is unusable ($state_verdict) - refusing to fall back to a $FEED_DAYS-day window and drop the refunds it is holding. Repair or remove the file deliberately."
    fi
    covered="$("${JQ_BIN:-jq}" -r '.covered_through' "$FEED_STATE")"
  else
    # FIRST RUN: no comparison has ever been recorded here. Bootstrap from a FIXED known start, never from the rolling
    # window: a refund issued before the window but after the campaign began would never be measured, and the first run
    # would call it clean.
    since="${REFUND_AUDIT_FEED_BOOTSTRAP_EPOCH:-$BOOTSTRAP_EPOCH}"
    case "$since" in ''|*[!0-9]*) cannot_check "the configured refund-feed bootstrap instant (REFUND_AUDIT_FEED_BOOTSTRAP_EPOCH='$since') is not an epoch" ;; esac
  fi
  if [ -n "$covered" ] && [ "$covered" -lt "$since" ]; then since="$covered"; fi
  # The bound applies to whatever start we chose - a recorded cursor OR the first-run bootstrap. A gap this audit cannot
  # cover in one read is PAGED, never papered over with a narrower window.
  gap_days=$(( (RUN_STARTED - since + 86399) / 86400 ))
  if [ "$gap_days" -gt "$MAX_CATCHUP_DAYS" ]; then
    cannot_check "the refund feed could not cover back to $(date -u -d "@$since" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "epoch $since") ($gap_days days), beyond the $MAX_CATCHUP_DAYS-day bound - refunds issued in that gap were never measured"
  fi
  feed_err="$(bash "$FEED_WRITER" --since "$since" --out "$FEED" 2>&1)"; feed_rc=$?
  if [ "$feed_rc" -ne 0 ]; then
    cannot_check "the processor refund list could not be read from Stripe - $(printf '%s' "$feed_err" | tail -2 | tr '\n' ' ')"
  fi
  # RETAIN the ids that are already paged and still untold. The feed is a window; an untold refund is not allowed to age
  # out of the alert because it got older. Each retained row is re-judged against the ledger with the same helper, so a
  # note that went out in the meantime drops it for good.
  "${JQ_BIN:-jq}" -c '(.outstanding // []) | .[] | select(type == "object" and ((.refund_id // "") | type == "string"))' \
      "$FEED_STATE" 2>/dev/null \
    | while IFS= read -r row; do
        [ -n "$row" ] || continue
        rid="$(printf '%s' "$row" | "${JQ_BIN:-jq}" -r '.refund_id')"
        "${JQ_BIN:-jq}" -r '.refund_id' "$FEED" 2>/dev/null | grep -qxF "$rid" && continue
        printf '%s\n' "$row" >> "$FEED"
      done
fi
[ -r "$FEED" ] || cannot_check "the processor refund feed is unreadable ($FEED)"
[ -r "$LEDGER" ] || cannot_check "the verify ledger is missing ($LEDGER)"

ERR_FILE="$SCRATCH_DIR/helper.err"
OUT="$(python3 -I "$HELPER" --db "$LEDGER" --readonly refund-unconfirmed --feed "$FEED" --hours "$HOURS" \
        ${NOW:+--now "$NOW"} 2>"$ERR_FILE")"
rc=$?
if [ "$rc" -ne 0 ]; then
  why="$(head -3 "$ERR_FILE" 2>/dev/null | tr '\n' ' ')"
  case "$why" in
    *"no such table"*) cannot_check "the verify ledger has no verify_messages table yet (migrate it) - $why" ;;
    *) cannot_check "the ledger or the refund feed could not be read - ${why:-exit $rc}" ;;
  esac
fi

# Findings, oldest first, with the refund id and the age: a page a human can act on without opening anything.
new_count=0; new_lines=""; standing=0
mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
seen="$(cat "$STATE_FILE" 2>/dev/null || echo '[]')"
printf '%s' "$seen" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null || seen='[]'
while IFS= read -r row; do
  [ -n "$row" ] || continue
  id="$(printf '%s' "$row" | python3 -c 'import json,sys; print(json.load(sys.stdin)["refund_id"])')"
  user="$(printf '%s' "$row" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("user_key",""))')"
  issued="$(printf '%s' "$row" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("issued_at",""))')"
  why="$(printf '%s' "$row" | python3 -c 'import json,sys; print(json.load(sys.stdin)["why"])')"
  if printf '%s' "$seen" | python3 -c 'import json,sys; sys.exit(0 if sys.argv[1] in json.load(sys.stdin) else 1)' "$id"; then
    standing=$((standing + 1)); continue
  fi
  new_count=$((new_count + 1))
  new_lines="${new_lines}- \`$id\` ${user:+($user) }issued ${issued}: $why"$'\n'
  seen="$(python3 -c 'import json,sys; s=json.loads(sys.argv[1]); s.append(sys.argv[2]); print(json.dumps(sorted(set(s))))' "$seen" "$id")"
done < <(printf '%s' "$OUT" | python3 -c '
import json, sys
out = json.load(sys.stdin)
for row in out["unconfirmed"]:
    print(json.dumps(row))')

if [ "$new_count" -gt 0 ]; then
  if ! notify ":rotating_light: *refund issued and not told* — $new_count refund(s) past ${HOURS} h with no confirmation note (verify ledger, campaign \`refund-confirm\`).
$new_lines
Each one is money that already moved and a customer who has not heard. Send the ruling-approved template (\`--campaign refund-confirm\`, \`--approved-by fable-ruling-1103-d2/refund-confirm\`) or say why not."; then
    # QA 2026-11-04 finding 3: a page that did not reach Slack must not write the refund id off as told. The next tick
    # retries it, and the run is red for a different reason: nothing was reported.
    echo "REFUND AUDIT: the page did NOT reach Slack; these $new_count refund(s) are NOT recorded as paged, so the next tick retries them" >&2
    printf '%s' "$new_lines" >&2
    exit 2
  fi
  if [ "$DRY_RUN" = "0" ]; then
    tmp="$(mktemp "${STATE_FILE}.XXXXXX")" && printf '%s' "$seen" > "$tmp" && mv "$tmp" "$STATE_FILE"
  fi
fi

# The cursor advances ONLY HERE: the processor answered, the ledger answered, and any page that had to land did. A run
# that could not compare leaves it where it was, so the next run reads the gap again instead of skipping it.
if [ "$CURSOR_ACTIVE" = "1" ] && [ "$DRY_RUN" = "0" ]; then
  mkdir -p "$(dirname "$FEED_STATE")" 2>/dev/null || true
  state_tmp="$(mktemp "${FEED_STATE}.XXXXXX" 2>/dev/null || true)"
  if [ -n "$state_tmp" ] && printf '%s' "$OUT" | "${JQ_BIN:-jq}" -c --argjson c "$RUN_STARTED" '
        { covered_through: $c,
          outstanding: [ .unconfirmed[] | { refund_id, user_key: (.user_key // ""), issued_at: (.issued_at // "") } ] }' \
       > "$state_tmp" 2>/dev/null && [ -s "$state_tmp" ]; then
    mv "$state_tmp" "$FEED_STATE" || { rm -f "$state_tmp"; echo "REFUND AUDIT: could not write the feed cursor ($FEED_STATE); the next run re-covers this window" >&2; }
  else
    [ -n "$state_tmp" ] && rm -f "$state_tmp"
    echo "REFUND AUDIT: could not write the feed cursor ($FEED_STATE); the next run re-covers this window" >&2
  fi
fi

if [ "$standing" -gt 0 ]; then
  echo "standing: $standing refund(s) already paged and still unconfirmed (not re-paged; exit stays red until a note is sent)"
  exit 1
fi
if [ "$new_count" -gt 0 ]; then
  echo "findings: $new_count"
  exit 1
fi
echo "clean: every refund in the feed older than ${HOURS} h has a sent confirmation"
exit 0
