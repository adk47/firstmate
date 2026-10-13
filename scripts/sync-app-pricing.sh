#!/usr/bin/env bash
set -euo pipefail

# sync-app-pricing.sh -- keep Caroline current on Muso APP subscription pricing.
# ─────────────────────────────────────────────────────────────────────────────
# WHY THIS EXISTS
# Caroline's Pro/Business figures were hand-copied markdown, and the failure was
# not staleness -- it was CADENCE CONFLATION, which is worse because every number
# was individually traceable to the backend and still produced a wrong quote.
#
# Her Business roster table read "Monthly (Annual)" over
# 24 / 40 / 104 / 176 / 384 / 640, which is the ANNUAL bracket divided by 12. Real
# monthly billing is 30 / 50 / 130 / 220 / 480 / 800
# (core-backend src/services/payment/constants/index.js, WEB_SUBSCRIPTION_PLANS_INFO).
# A customer on monthly billing quoted "$24" was told a price ~25% below what they
# would actually pay. The 501+ row was mixed units inside the same column: raw
# annual ($16/profile) where the six rows above it were annual/12.
#
# So the contract here is stronger than "fetch fresh numbers": MONTHLY AND ANNUAL
# ARE RENDERED AS SEPARATE, EXPLICITLY LABELLED TABLES and are never blended. The
# bats suite pins that, because it is the part that reached a customer.
#
# SOURCE -- public, anonymous, and canonical:
#   https://api.muso.ai/api/w/v3/subscription/public-plans
# It is served by core-backend's getPublicPlans (apis/pricing/getPublicPlans.js),
# reads WEB_SUBSCRIPTION_PLANS_INFO -- the ONE module that owns these numbers --
# and needs no auth or workspace id. There is no second copy in the app:
# web-credits-next only renders whatever this returns.
#
# NOTE ON STRIPE: these are the DISPLAY prices. What a customer is actually charged
# comes from the Stripe Price objects referenced by stripePriceId/stripeProductId.
# The constants file and Stripe are two things that must agree, and nothing in this
# repo verifies that they do. This feed makes Caroline match the app; it does not
# make the app match Stripe.
#
# COUPONS ARE REFUSED. The endpoint applies a coupon when asked. A discounted price
# is not list pricing, and Caroline quoting one as standard would be a promise Muso
# has to honour -- so a payload flagged as coupon-applied is rejected outright.
#
# Same guards as the platform feed (scripts/sync-platform-llms.sh): fail-closed on a
# bad fetch, the shared CI blocklist re-run here because the output is rsync-excluded
# and CI cannot see it, em-dash normalisation, atomic install, Slack notice on change.
#
# Usage:
#   sync-app-pricing.sh              # fetch, validate, install
#   sync-app-pricing.sh --dry-run    # render to stdout, write nothing
#   sync-app-pricing.sh --check      # exit 0 if the installed file is current
#   sync-app-pricing.sh --help
#
# Exit: 0 ok | 1 refused or drifted (file untouched) | 2 usage/config error.

URL="${APP_PRICING_URL:-https://api.muso.ai/api/w/v3/subscription/public-plans}"
OUT="${APP_PRICING_OUT:-/opt/hydra/workspaces/support/reference/app-pricing.md}"
CURL_TIMEOUT="${APP_PRICING_TIMEOUT:-25}"
# Ceiling only, to bound what lands in the RAG index if this route is ever replaced
# by something enormous. There is deliberately NO byte FLOOR: unlike the platform
# feed (a prose page, where a short body is the tell for truncation), this payload is
# JSON and the structural checks below strictly dominate a size check -- a truncated
# body fails `jq -e .`, and anything that parses must still carry all four plan ids
# and both seats brackets. A floor here would be a guard no test could falsify,
# because a sub-floor body satisfying those checks cannot be constructed.
MAX_BYTES="${APP_PRICING_MAX_BYTES:-65536}"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/cs-reference-blocklist.sh
. "$SELF_DIR/lib/cs-reference-blocklist.sh"

MODE="install"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) MODE="dry-run" ;;
    --check)   MODE="check" ;;
    # Anchored on the header's LAST line, not a line count, so inserting a comment
    # above cannot silently truncate --help.
    -h|--help) sed -n '/^# Exit:/q;p' "${BASH_SOURCE[0]}"; sed -n '/^# Exit:/p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "sync-app-pricing.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done

notify() {
  [ -z "${APP_PRICING_NO_NOTIFY:-}" ] || return 0
  [ -f "$SELF_DIR/lib/slack-notify.sh" ] || return 0
  # shellcheck source=lib/slack-notify.sh
  . "$SELF_DIR/lib/slack-notify.sh" 2>/dev/null || return 0
  command -v slack_notify >/dev/null 2>&1 || return 0
  # #cs_chats as the OPERATIONS bot: the devops bot slack-notify.sh defaults to is
  # not a member and cannot even resolve the ID. Set in a subshell, not as an env
  # prefix -- a prefix on a shell FUNCTION persists in the calling shell in bash.
  (
    export SLACK_CHANNEL="${APP_PRICING_SLACK_CHANNEL:-C0ANM0PN9L5}"
    export SLACK_NOTIFY_BOT="${APP_PRICING_SLACK_BOT:-operations}"
    slack_notify "$1"
  ) >/dev/null 2>&1 || true
}

# A refusal that only writes stderr is a silent freeze on a Type=oneshot timer, and
# the failure it produces -- Caroline quoting last-known prices forever -- is the rot
# this feed replaces. Only the INSTALL path pages; --dry-run/--check have a human.
die() {
  echo "sync-app-pricing.sh: $*" >&2
  [ "$MODE" != "install" ] || notify ":warning: *Caroline's Muso-app pricing feed did not update* on node-8 -- $*. She is still answering from the last good copy of \`$OUT\`, so her plan prices are frozen. Re-run: \`/opt/hydra/scripts/sync-app-pricing.sh --dry-run\`"
  exit 1
}

command -v jq >/dev/null 2>&1 || die "jq not found"

# The comparable content: the whole file EXCEPT the render timestamp, which is the
# only line that legitimately changes between identical renders.
#
# This deliberately does NOT skip to the '---' separator. Doing that made --check
# blind to everything above it, and everything above it is the SAFETY copy: the
# "ask which cadence first" rule, the "never divide an annual figure by 12" line, and
# the disambiguation from the developer-platform rates. Delete any of those on the
# server and --check reported "current". The volatile part is one line, so exclude
# one line.
body() { sed '/^Rendered: /d' "$1"; }

TMPDIR_RUN="$(mktemp -d)"
TMP_INSTALL=""
cleanup() { rm -rf "$TMPDIR_RUN"; [ -z "$TMP_INSTALL" ] || rm -f "$TMP_INSTALL"; }
trap cleanup EXIT
# Separate INT/TERM traps that actually EXIT: bash runs an EXIT handler and then
# resumes, so a TimeoutStartSec SIGTERM would otherwise delete the scratch dir and
# carry on into the install with nothing to install.
trap 'cleanup; exit 1' INT TERM
RAW="$TMPDIR_RUN/plans.json"
RENDER="$TMPDIR_RUN/render.md"

# ── fetch ────────────────────────────────────────────────────────────────────
if ! curl -sSL --fail -m "$CURL_TIMEOUT" "$URL" -o "$RAW" 2>"$TMPDIR_RUN/curl.err"; then
  die "fetch FAILED from $URL ($(tr -d '\n' <"$TMPDIR_RUN/curl.err")); previous file left untouched"
fi

bytes=$(wc -c <"$RAW" | tr -d ' ')
[ "$bytes" -le "$MAX_BYTES" ] || die "body is $bytes bytes, above the $MAX_BYTES ceiling; previous file left untouched"

jq -e . "$RAW" >/dev/null 2>&1 || die "body is not valid JSON; previous file left untouched"
jq -e '.result == "ok"' "$RAW" >/dev/null 2>&1 || die "envelope is not result=ok; previous file left untouched"

# A discounted payload is not list pricing.
jq -e '(.data.couponApplied // false) or (.data.partnerCouponApplied // false)' "$RAW" >/dev/null 2>&1 \
  && die "payload has a coupon applied -- that is not list pricing; previous file left untouched"

# Structural completeness. A payload that parses but has lost the Business brackets
# would render a plausible doc with the roster table silently missing, and a payload
# with only one cadence is how the previous doc came to imply the other.
plan_count=$(jq '.data.plans | length' "$RAW")
[ "$plan_count" -ge 4 ] || die "only $plan_count plans returned, expected at least 4; previous file left untouched"
for want in muso_team_pro_graduated_monthly muso_team_pro_graduated_annual \
            muso_team_business_graduated_monthly muso_team_business_graduated_annual; do
  jq -e --arg id "$want" '.data.plans | map(.id) | index($id)' "$RAW" >/dev/null 2>&1 \
    || die "plan '$want' missing from the payload; previous file left untouched"
done
# EVERY field that gets rendered is validated, not just the ones a past incident
# named. `users` is validated too even though it is no longer rendered: its absence
# means the API returned a degraded payload, which casts doubt on the seats bracket
# that IS rendered. The seats bracket was guarded first and its sibling `users` was not, so a
# payload missing `users` installed a file with an empty org-user table and exited 0
# (found in review). The rule is the class, so enumerate the class: both brackets, on
# both cadences, non-empty and numeric-valued.
# The per-profile marking keys on an open-ended band ("500+"). If the payload ever
# stops carrying one, the shape this renderer assumes is gone -- refuse rather than
# emit a roster table whose last row silently changes meaning.
for want in muso_team_business_graduated_monthly muso_team_business_graduated_annual; do
  jq -e --arg id "$want" \
    '.data.plans[] | select(.id==$id) | .additionalCosts.seats | keys | any(test("\\+$"))' \
    "$RAW" >/dev/null 2>&1 \
    || die "plan '$want' has no open-ended seats band; previous file left untouched"
done

for want in muso_team_business_graduated_monthly muso_team_business_graduated_annual; do
  for bracket in seats users; do
    jq -e --arg id "$want" --arg b "$bracket" \
      '.data.plans[] | select(.id==$id) | .additionalCosts[$b] | (. != null) and (length > 0)' \
      "$RAW" >/dev/null 2>&1 \
      || die "plan '$want' has no '$bracket' bracket; previous file left untouched"
    jq -e --arg id "$want" --arg b "$bracket" \
      '.data.plans[] | select(.id==$id) | .additionalCosts[$b] | all(.[]; type == "number")' \
      "$RAW" >/dev/null 2>&1 \
      || die "plan '$want' has a non-numeric value in its '$bracket' bracket; previous file left untouched"
  done
done

# Scalar prices, same rule. A null here rendered literally as "\$null / month" to a
# customer, because the money formatter stringified whatever it was handed rather
# than refusing.
for want in muso_team_pro_graduated_monthly muso_team_pro_graduated_annual \
            muso_team_business_graduated_monthly muso_team_business_graduated_annual; do
  jq -e --arg id "$want" '.data.plans[] | select(.id==$id) | .price | type == "number"' \
    "$RAW" >/dev/null 2>&1 \
    || die "plan '$want' has a non-numeric price; previous file left untouched"
done
for want in muso_team_pro_graduated_monthly muso_team_pro_graduated_annual; do
  jq -e --arg id "$want" \
    '.data.plans[] | select(.id==$id) | .additionalSeatCost | type == "number"' \
    "$RAW" >/dev/null 2>&1 \
    || die "plan '$want' has a non-numeric additionalSeatCost; previous file left untouched"
done

# ── render ───────────────────────────────────────────────────────────────────
# One helper, called once per cadence. The tables are built SEPARATELY on purpose:
# there is no code path here that can emit a row containing both cadences.
# money -- render a number the way a customer reads a price: whole dollars bare,
# fractions to exactly two places. The API sends JSON numbers, so 12.5 and 1.7 would
# otherwise print as "$12.5" and "$1.7", which look like typos in a quote. A
# non-numeric value falls through unchanged so the blocklist still sees it.
# A non-number is an ERROR, not something to stringify. The previous version fell
# back to tostring, so a null price rendered to a customer as literally "$null".
JQ_MONEY='def money: if (type != "number") then error("non-numeric price: \(.)") else
    (.*100|round) as $c | ($c/100|floor) as $d | ($c%100) as $r |
    if $r == 0 then "\($d)" else "\($d).\(if $r < 10 then "0" else "" end)\($r)" end
  end;'

plan_field() {
  jq -r --arg id "$1" --arg f "$2" "$JQ_MONEY"' .data.plans[] | select(.id==$id) | .[$f] | money' "$RAW"
}
# The OPEN-ENDED bracket row ("500+") is a PER-PROFILE rate; every bounded band
# above it is a flat fee.
#
# Keyed on the KEY SHAPE, never on position. An earlier version marked whichever row
# came LAST, which is only the same thing while the open-ended band exists: drop
# "500+" from the payload and it labelled the bounded "251 - 500" band as "$800 per
# profile", quoting $400,000/month for a 500-profile roster instead of $800. Position
# is a coincidence; "has no upper bound" is the actual property. Not a guess: web-credits-next plan-card.tsx renders this exact table and
# appends "/each" to `index === rows.length - 1` only, under the copy "Add unlimited
# Pro Seats with a flat fee, determined by your Seats bracket". Caroline's own old
# table corroborated it, listing "501+ | $16/profile".
#
# Rendering the open-ended row as a flat "$1.70 / month" would tell a customer with a
# 500-profile roster that they pay $1.70 rather than ~$850 -- the same under-quoting
# class this whole feed exists to remove.
bracket_rows() {
  jq -r --arg id "$1" --arg unit "$2" "$JQ_MONEY"' .data.plans[] | select(.id==$id)
     | .additionalCosts.seats | to_entries[]
     | "| \(.key) | $\(.value|money)\(if (.key|test("\\+$")) then " per profile" else "" end)\($unit) |"' "$RAW"
}


# PRECOMPUTED into checked assignments, NOT called inside the heredoc below.
# A $( ) inside a heredoc has its failure swallowed: jq writes an error to stderr,
# substitutes empty, and `cat` still exits 0 -- which is how a payload missing the
# users bracket installed a file with empty tables and reported success. A plain
# assignment carries the substitution's exit status, so `set -e` aborts the run and
# the previous file survives.
#
# THREE LAYERS, measured, because they fail differently:
#   1. The field validation above refuses with a readable reason AND pages #cs_chats
#      (it goes through die()).
#   2. This precompute is the backstop if a field is ever rendered that nobody
#      thought to validate. Verified: with all four field guards neutered, a payload
#      missing `users` exits 5 and writes nothing -- but via `set -e`, which does NOT
#      run die(), so there is no Slack page.
#   3. systemd OnFailure (the AUX_ONFAILURE_UNITS row) is what catches layer 2, which
#      is exactly why this unit is in that table rather than relying on die() alone.
pro_m=$(plan_field muso_team_pro_graduated_monthly price)
pro_m_seat=$(plan_field muso_team_pro_graduated_monthly additionalSeatCost)
pro_a=$(plan_field muso_team_pro_graduated_annual price)
pro_a_seat=$(plan_field muso_team_pro_graduated_annual additionalSeatCost)
biz_m=$(plan_field muso_team_business_graduated_monthly price)
biz_a=$(plan_field muso_team_business_graduated_annual price)
rows_seats_m=$(bracket_rows muso_team_business_graduated_monthly " / month")
rows_seats_a=$(bracket_rows muso_team_business_graduated_annual " / year")

{
  cat <<EOF
# Muso app plans and pricing (Lite / Pro / Business) -- live reference

**This is the Muso APP SUBSCRIPTION -- what a customer pays for Pro or Business
seats in the Muso app.** It is NOT platform.muso.ai, the developer platform, whose
per-call API rates live in \`platform-api.md\`. The two compete in search because both
are "Muso pricing", so check which product the customer means: a plan, seats or a
roster is THIS file; an API key, per-call rates or the catalog is \`platform-api.md\`.

GENERATED FILE. Do not edit by hand; edits are overwritten on the next sync.
Source: $URL (public, no auth) -- served from the one backend module that owns
these numbers.
Rendered: $(date -u '+%Y-%m-%d %H:%M UTC')

## Read this before quoting any figure

**Ask which billing cadence the customer is on, then quote from THAT table only.**
Monthly and annual are different prices, not the same price shown two ways, and
blending them is exactly how this file's hand-written predecessor under-quoted
customers: it showed annual prices divided by 12 under a heading that looked
monthly, so a customer paying monthly was told a number about 25% too low.

Never divide an annual figure by 12 to "get the monthly price". The monthly plan
has its own rate card, and it is higher. If you do not know the cadence, ask.

These are list prices. A customer on a coupon, a partner deal or a legacy plan may
pay something else -- read their actual subscription rather than quoting this file.
For anything custom or negotiated, route it to the team.

---

## Pro

| Billed monthly | Billed annually |
|---|---|
| \$$pro_m / month | \$$pro_a / year |

Additional Pro seats: **\$$pro_m_seat / month** when billed monthly,
**\$$pro_a_seat / year** when billed annually.

## Business

Business starts at **\$$biz_m / month** when billed monthly, or
**\$$biz_a / year** when billed annually, and scales with roster size.

### Business roster -- BILLED MONTHLY

| Profiles | Price |
|---|---|
$rows_seats_m

### Business roster -- BILLED ANNUALLY

| Profiles | Price |
|---|---|
$rows_seats_a

### Additional org users

Business includes a number of org users, and more are charged in bands. **Those
band figures are NOT reproduced here on purpose.** The app does not render them
anywhere a customer can see, so unlike the roster brackets above there is no
surface confirming whether a band price is a flat fee or per user -- and quoting
the wrong one is the same mistake this file exists to prevent.

If a customer asks what extra org users cost, flag it for the team rather than
quoting a figure.

## Lite

Free forever. It has no priced row in the backend at all -- "free" is its absence
from the plan list, not a \$0 entry.
EOF
} | sed -e $'s/\xe2\x80\x94/ -- /g' -e 's/  *--  */ -- /g' >"$RENDER"

# Scanned over the rendered BODY, not the whole file. The provenance header above is
# ours and embeds $URL, which on a developer checkout is a local path that can itself
# contain a blocklisted word (".../hydra/..."). Scanning the whole render made the
# gate fire on our own header -- a false positive that says nothing about what the
# API returned. Everything below the separator is built from the payload, which is
# the untrusted part.
body "$RENDER" >"$TMPDIR_RUN/body.md"
if hits=$(cs_reference_blocklist_hits "$TMPDIR_RUN/body.md"); then
  echo "sync-app-pricing.sh: REFUSED -- internal terms in the rendered feed:" >&2
  echo "$hits" >&2
  die "previous file left untouched"
fi
grep -q $'\xe2\x80\x94' "$RENDER" && die "em-dash survived normalisation; refusing to publish"

# ── act ──────────────────────────────────────────────────────────────────────
# Only dry-run and check have arms, and both exit inside them; MODE=install matches
# nothing and falls through past `esac`.
case "$MODE" in
  dry-run) cat "$RENDER"; exit 0 ;;
  check)
    [ -f "$OUT" ] || die "no installed file at $OUT"
    if diff -q <(body "$OUT") <(body "$RENDER") >/dev/null; then
      echo "OK: $OUT is current with $URL"; exit 0
    fi
    echo "DRIFT: $OUT differs from $URL" >&2
    diff <(body "$OUT") <(body "$RENDER") >&2 || true
    exit 1
    ;;
esac

changed=1
if [ -f "$OUT" ] && diff -q <(body "$OUT") <(body "$RENDER") >/dev/null; then changed=0; fi

mkdir -p "$(dirname "$OUT")"
TMP_INSTALL="$OUT.tmp.$$"
install -m 644 "$RENDER" "$TMP_INSTALL"
mv -f "$TMP_INSTALL" "$OUT"
TMP_INSTALL=""

if [ "$changed" -eq 0 ]; then
  echo "OK: $OUT refreshed, content unchanged"; exit 0
fi
echo "OK: $OUT updated from $URL (content CHANGED)"
notify ":arrows_counterclockwise: Caroline's Muso-app plan pricing just changed, straight from the public plans API with no human in the loop. Worth a skim: \`$OUT\` on node-8, or \`/opt/hydra/scripts/sync-app-pricing.sh --dry-run\`."
exit 0
