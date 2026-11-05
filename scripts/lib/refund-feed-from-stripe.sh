#!/usr/bin/env bash
# refund-feed-from-stripe.sh - the refund feed the 30-minute refund-confirmation audit reads, produced from the
# processor itself (captain 2026-11-03 20:04Z building rule; Fable d2 ruling refund-confirm-1103, firstmate 109).
#
# WHY THIS EXISTS (QA 2026-11-04, the last open finding on #1728): the audit shipped reading
# /var/lib/hydra/credit-review/refund-events.jsonl, and NOTHING writes that file. So after deploy the audit would have
# exited "could not check" forever, posting one generic daily outage and never naming a single refund - an alert that
# cannot see the thing it exists to see. The fix is not a new crew: Stripe is the only authority on which refunds were
# issued, and the gate already reads it with the same credential, so the audit derives its feed from Stripe on every
# run and depends on nobody.
#
# Contract with the audit (`verify_ledger.py refund-unconfirmed`): one JSON object per line, exactly
#   {"refund_id": "re_...", "user_key": "<the payer's billing email>", "issued_at": "YYYY-MM-DDTHH:MM:SSZ"}
# where issued_at is the REFUND's creation time (never the charge's - a refund issued months after payment is the
# normal case for a concession, and dating it from the charge would report a fresh refund as ancient). `user_key` is
# display-only: the ledger matches on the refund id.
#
# What it refuses to do:
#   * FINISH PARTIALLY. Every page must parse and be error-free; a half-read feed would look like "the other refunds
#     were told", which is the one wrong conclusion this check must never reach. Any failure exits non-zero with the
#     reason on stderr and the audit turns that into a "could not check" page.
#   * pass the key in argv. curl reads its config on stdin (-K -), exactly like scripts/intercom-verify-request.sh, so
#     the live secret is in no /proc/<pid>/cmdline and on no disk.
#   * guess a status. Only `succeeded` refunds are money that arrived; `pending`/`failed` are not told to anybody.
#
# Env (ops): STRIPE_ENV_FILE (default /etc/openclaw/main.env - the same file the verify gate reads),
# MUSOAI_STRIPE_API_KEY (if the caller already has it in the environment). REFUND_FEED_DAYS is the rolling lookback.
#
# THE WINDOW IS A PARAMETER, NEVER A STATE (QA 2026-11-04, second finding - twice). A rolling "last 7 days" query is a
# silent hole: after an eight-day audit or Stripe outage a refund from day one is simply absent when the check recovers,
# which reports clean and never names it. The first fix kept a cursor here, in the writer - and QA was right that it was
# still wrong: the writer advances the moment pagination succeeds, which is BEFORE the audit has read the ledger or
# paged anything. A ledger outage of eight days therefore advanced the cursor every night and still lost the refund.
#
# So this script holds NO state. It reads the window it is told to read (`--since <epoch>`, or `--days N` for a manual
# look) and nothing else. The AUDIT owns the cursor, and advances it only after a comparison it could actually make
# (see scripts/audit-refund-confirmations.sh). A feed writer that decides how far back to look is a feed writer that
# can decide a refund never existed.
# Test seams exist ONLY in a copy whose TESTABLE flag has been opened (tests do the same sed the verify gate's suite
# does); a deployed copy refuses them, because a caller-selectable processor is a feed nobody can trust.
set -uo pipefail

readonly TESTABLE=0
readonly STRIPE_ENV_FILE_DEFAULT="/etc/openclaw/main.env"
readonly STRIPE_KEY_VAR="MUSOAI_STRIPE_API_KEY"
readonly STRIPE_API_BASE_PROD="https://api.stripe.com"
readonly MAX_PAGES=50

DAYS="${REFUND_FEED_DAYS:-7}"
SINCE=""
OUT=""

usage() { echo "usage: $0 [--since EPOCH] [--days N] [--out FILE]"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --days) [ $# -ge 2 ] || { usage; exit 2; }; DAYS="$2"; shift 2 ;;
    --out)  [ $# -ge 2 ] || { usage; exit 2; }; OUT="$2"; shift 2 ;;
    --since) [ $# -ge 2 ] || { usage; exit 2; }; SINCE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
case "$DAYS" in ''|*[!0-9]*) echo "REFUND FEED: --days must be a whole number of days (got '$DAYS')" >&2; exit 2 ;; esac
[ "$DAYS" -ge 1 ] || { echo "REFUND FEED: --days must be at least 1" >&2; exit 2; }
case "$SINCE" in ''|*[!0-9]*) [ -z "$SINCE" ] || { echo "REFUND FEED: --since must be an epoch second (got '$SINCE')" >&2; exit 2; } ;; esac

# ─── seams: prod values unless an opened TESTABLE copy says otherwise ───────────────────────────────────────────
if [ "$TESTABLE" = "1" ]; then
  CURL_BIN="${REFUND_FEED_TEST_CURL_BIN:-curl}"
  API_BASE="${REFUND_FEED_TEST_STRIPE_BASE:-$STRIPE_API_BASE_PROD}"
  ENV_FILE="${REFUND_FEED_TEST_ENV_FILE:-$STRIPE_ENV_FILE_DEFAULT}"
else
  # a deployed copy: every test seam is refused LOUDLY rather than silently ignored, so nobody debugs a stub that is
  # not in play. This is the same posture the verify gate takes with INTERCOM_VERIFY_TEST_*.
  for v in REFUND_FEED_TEST_CURL_BIN REFUND_FEED_TEST_STRIPE_BASE REFUND_FEED_TEST_ENV_FILE; do
    if [ -n "$(printenv "$v" 2>/dev/null || true)" ]; then
      echo "REFUND FEED: $v is not settable on a deployed copy. The processor and its credential are not parameters: a caller-selectable one is a feed nobody can trust." >&2
      exit 2
    fi
  done
  CURL_BIN="curl"
  API_BASE="$STRIPE_API_BASE_PROD"
  ENV_FILE="$STRIPE_ENV_FILE_DEFAULT"
fi

# The key never comes from argv and is never echoed. Same precedence as the verify gate: the environment first, then
# the env file the gateway already uses, so the audit needs no new secret and no new file to be deployed.
stripe_key() {
  if [ -n "${MUSOAI_STRIPE_API_KEY:-}" ]; then printf '%s' "$MUSOAI_STRIPE_API_KEY"; return 0; fi
  [ -r "$ENV_FILE" ] || return 1
  grep -E "^${STRIPE_KEY_VAR}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "\"'" | tr -d '\r'
}

stripe_get() { # <path>: response body on stdout; non-zero when the call itself failed
  local key
  key="$(stripe_key)" || return 2
  [ -n "$key" ] || return 2
  printf '%s' "$key" | grep -qE '^[A-Za-z0-9_]+$' \
    || { echo "REFUND FEED: the Stripe key has unexpected characters; refusing to hand it to curl" >&2; return 2; }
  # -g (--globoff): curl reads [] and {} in a URL as GLOBS. `created[gte]=<epoch>` is a non-empty bracket group, which
  # curl rejects outright - "curl: (3) bad range in URL" - so on a deployed copy this query never reached Stripe at all.
  # The test stubs below consume stdin and never parse a URL, which is exactly why this survived a round of tests; the
  # suite now runs one real curl against a real local server and asserts the query arrives byte-for-byte.
  printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/json"\nurl = "%s%s"\n' \
      "$key" "$API_BASE" "$1" \
    | "$CURL_BIN" -sS -g -K - 2>&1
}

TMP_OUT="$(mktemp "${PAPERCLIP_RUN_SCRATCH_DIR:-/var/tmp}/refund-feed.XXXXXX")" || {
  echo "REFUND FEED: could not create a scratch file" >&2; exit 2; }
trap 'rm -f "$TMP_OUT"' EXIT INT TERM

command -v jq >/dev/null 2>&1 || { echo "REFUND FEED: jq is not installed" >&2; exit 2; }
key_probe="$(stripe_key)" || key_probe=""
[ -n "$key_probe" ] || { echo "REFUND FEED: no $STRIPE_KEY_VAR in the environment or in $ENV_FILE" >&2; exit 2; }
unset key_probe

if [ -n "$SINCE" ]; then
  since="$SINCE"
else
  since=$(( $(date -u +%s) - DAYS * 86400 ))
fi
starting_after=""
pages=0

while :; do
  path="/v1/refunds?limit=100&created[gte]=${since}&expand[]=data.charge"
  [ -z "$starting_after" ] || path="${path}&starting_after=${starting_after}"
  if ! body="$(stripe_get "$path")"; then
    echo "REFUND FEED: the Stripe refund list could not be read (GET $path failed)" >&2; exit 2
  fi
  if ! printf '%s' "$body" | jq -e 'type == "object" and (has("error") | not) and (.data | type == "array")' >/dev/null 2>&1; then
    err="$(printf '%s' "$body" | jq -r '.error.message // empty' 2>/dev/null | head -1)"
    echo "REFUND FEED: Stripe did not return a refund list${err:+ ($err)}" >&2; exit 2
  fi
  printf '%s' "$body" | jq -c '
    .data[]
    | select(.status == "succeeded")
    | { refund_id: .id,
        user_key: ((.charge | if type == "object" then (.billing_details.email // "") else "" end)),
        issued_at: (.created | todate) }
  ' >> "$TMP_OUT" || { echo "REFUND FEED: a refund page could not be projected" >&2; exit 2; }

  pages=$(( pages + 1 ))
  # `has_more` is the ONLY thing that says whether this page is the whole answer. Absent or null metadata is not "no more
  # refunds": treating it as complete drops every refund on page two and the audit then reports clean over unwatched
  # money (QA 2026-11-04 round 4 finding 2). Require an explicit boolean.
  resumable="$(printf '%s' "$body" | jq -r 'if (.has_more | type) == "boolean" then (.has_more | tostring) else "UNKNOWN" end' 2>/dev/null || echo UNKNOWN)"
  case "$resumable" in
    false) break ;;
    true) ;;
    *) echo "REFUND FEED: Stripe's page did not say whether more refunds exist (has_more missing, null or not a boolean) - refusing to treat that as a complete feed" >&2; exit 2 ;;
  esac
  [ "$pages" -lt "$MAX_PAGES" ] || { echo "REFUND FEED: more than $MAX_PAGES pages; refusing a partial feed" >&2; exit 2; }
  starting_after="$(printf '%s' "$body" | jq -r '.data[-1].id // empty')"
  [ -n "$starting_after" ] || { echo "REFUND FEED: Stripe said has_more with no last id" >&2; exit 2; }
done

if [ -n "$OUT" ]; then
  mv "$TMP_OUT" "$OUT" || { echo "REFUND FEED: could not write $OUT" >&2; exit 2; }
  trap - EXIT INT TERM
else
  cat "$TMP_OUT"
fi
