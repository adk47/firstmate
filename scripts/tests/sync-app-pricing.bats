#!/usr/bin/env bats
# Caroline's Muso-app subscription pricing feed.
#
# sync-app-pricing.sh renders workspaces/support/reference/app-pricing.md from the
# PUBLIC, anonymous JSON at api.muso.ai/api/w/v3/subscription/public-plans, which is
# fed straight from core-backend's WEB_SUBSCRIPTION_PLANS_INFO -- the single module
# that owns these numbers.
#
# THE BUG THIS REPLACES was not staleness, it was CADENCE CONFLATION. The hand-written
# table said "Monthly (Annual)" and listed 24/40/104/176/384/640, which is the ANNUAL
# bracket divided by 12. Real monthly billing is 30/50/130/220/480/800, so a customer
# on monthly was quoted ~25% under what they would pay. The 501+ row was worse: raw
# annual ($16/profile) sitting in a column whose other six rows were annual/12.
#
# So the renderer's contract is not just "fresh numbers" -- it is that MONTHLY AND
# ANNUAL ARE NEVER MIXED IN ONE TABLE, and every figure is labelled with its cadence.
# Several tests below pin exactly that, because it is the thing that actually hurt a
# customer.
#
# Every assertion uses `run` + an explicit status check: a bare `! cmd` in bats is a
# no-op unless it is the final line, which would make this file a false green.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SYNC="$HYDRA_REPO/scripts/sync-app-pricing.sh"
FIXTURE="$HYDRA_REPO/scripts/tests/fixtures/app-public-plans.json"

setup() {
  TMP="$BATS_TEST_TMPDIR"
  SRC="$TMP/plans.json"
  OUT="$TMP/app-pricing.md"
  cp "$FIXTURE" "$SRC"
  # CI bats run as ROOT on node-8, where /etc/openclaw/main.env holds real bot tokens
  # and /usr/local/bin/muso is on PATH. Without this, every test whose render differs
  # posts a REAL message to #cs_chats. See feedback_bats_must_stub_openclaw.
  export MUSO_BIN=/nonexistent
}

run_sync() {
  run env APP_PRICING_URL="file://$SRC" APP_PRICING_OUT="$OUT" MUSO_BIN=/nonexistent \
    bash "$SYNC" "$@"
}

@test "the script exists and is executable" {
  [ -x "$SYNC" ]
}

@test "the committed fixture is the real API shape" {
  # Guards the whole suite against drifting onto an invented payload.
  run jq -e '.result == "ok" and (.data.plans | length >= 4)' "$FIXTURE"
  [ "$status" -eq 0 ]
}

# ─── the happy path ───

@test "renders a feed from a good payload" {
  run_sync
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ -s "$OUT" ]
}

@test "the provenance header names the source it actually fetched" {
  # Asserts the URL that was USED, not the production one -- the fixture is injected
  # via APP_PRICING_URL, so hardcoding the real endpoint here would be a test that
  # can only pass by accident. The default endpoint is pinned separately below.
  run_sync
  [ "$status" -eq 0 ]
  grep -q "GENERATED FILE" "$OUT"
  grep -q "^Source: file://$SRC" "$OUT"
}

# ─── the cadence contract: the actual bug ───

@test "monthly and annual Business brackets are BOTH present" {
  run_sync
  [ "$status" -eq 0 ]
  grep -q '30' "$OUT"
  grep -q '288' "$OUT"
}

@test "the real monthly Business bracket is rendered, not annual/12" {
  # 30/50/130/220/480/800 are the monthly numbers. Their annual/12 shadows
  # (24/40/104/176/384/640) are what the hand-written table wrongly showed.
  run_sync
  [ "$status" -eq 0 ]
  for n in 30 50 130 220 480 800; do
    grep -qE "(^|[^0-9.])${n}([^0-9]|\$)" "$OUT" || {
      echo "monthly bracket value $n missing from render" >&2; return 1; }
  done
}

@test "monthly and annual figures never appear in the same table row" {
  # The precise shape of the old bug: one column blending two cadences. Every table
  # row in the render must carry values from a single cadence section.
  run_sync
  [ "$status" -eq 0 ]
  # 24 and 288 are the annual/12 shadow and the annual list price. If a single row
  # ever contains both a monthly bracket value and its annual twin, the conflation is
  # back.
  run grep -nE '\|.*\b30\b.*\b288\b.*\||\|.*\b288\b.*\b30\b.*\|' "$OUT"
  [ "$status" -ne 0 ] || {
    echo "a row mixes monthly and annual values:" >&2; echo "$output" >&2; return 1; }
}

@test "the open-ended roster row is marked PER PROFILE, on both cadences" {
  # The OPEN-ENDED bracket ("500+") is a per-profile rate, not a flat band fee:
  # web-credits-next plan-card.tsx marks exactly that row "/each", under "Add
  # unlimited Pro Seats with a flat fee, determined by your Seats bracket". Caroline's
  # old table said "501+ | $16/profile" too. Detection is by key shape, not position
  # -- see the absent-open-ended-band test below for why.
  #
  # Rendered flat, "500+ | $1.70 / month" tells a 500-profile customer they pay
  # $1.70 instead of ~$850 -- the same under-quoting class this feed exists to kill.
  run_sync
  [ "$status" -eq 0 ]
  grep -qE '^\| 500\+ \| \$1\.70 per profile / month \|' "$OUT"
  grep -qE '^\| 500\+ \| \$16 per profile / year \|' "$OUT"
}

@test "the flat band rows are NOT marked per profile" {
  # Only the open-ended row is per-unit. Marking a bounded band would over-quote by
  # the size of that band, which is the mirror-image error.
  run_sync
  [ "$status" -eq 0 ]
  for band in '1 - 5' '6 - 10' '11 - 50' '51 - 100' '101 - 250' '251 - 500'; do
    run grep -E "^\| $band \|.*per profile" "$OUT"
    [ "$status" -ne 0 ] || {
      echo "flat band '$band' wrongly marked per profile" >&2; return 1; }
  done
}

@test "org-user band figures are NOT quoted, and the file says to route instead" {
  # The app renders no users-bracket table anywhere (pricingBrackets("users") has no
  # consumer), so nothing confirms whether a band price is flat or per user. An
  # unverifiable number in a pricing file is the risk this feed removes, so the
  # bands are deliberately absent rather than guessed.
  run_sync
  [ "$status" -eq 0 ]
  grep -qi "flag it for the team" "$OUT"
  # the known band values must not appear as quotable rows
  run grep -E '^\| (1 - 3|4 - 25|25 - 50|51 - 200|200\+) \|' "$OUT"
  [ "$status" -ne 0 ] || {
    echo "an org-user band was rendered as a quotable row:" >&2; echo "$output" >&2; return 1; }
}

@test "an absent open-ended band is refused, never mislabelled onto a bounded one" {
  # The per-profile marking used to key on POSITION. Drop "500+" and the bounded
  # "251 - 500" band became "$800 per profile / month" -- $400,000/month for a
  # 500-profile roster instead of $800. Position was a coincidence; "has no upper
  # bound" is the property.
  jq '(.data.plans[] | select(.id|test("business")) | .additionalCosts.seats)
      |= with_entries(select(.key != "500+"))' "$FIXTURE" >"$SRC"
  run_sync
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "open-ended"
  [ ! -e "$OUT" ]
}

@test "--check is not blind to the safety copy above the separator" {
  # --check compared only below the '---' separator, so deleting the cadence rule or
  # the never-divide-by-12 line from the installed file still reported "current".
  # Those lines are the whole reason the file is safe to quote from.
  run_sync
  [ "$status" -eq 0 ]
  run_sync --check
  [ "$status" -eq 0 ]
  grep -v "Never divide an annual figure by 12" "$OUT" >"$OUT.t" && mv "$OUT.t" "$OUT"
  run_sync --check
  [ "$status" -ne 0 ] || {
    echo "--check accepted a file with a safety line removed" >&2; return 1; }
}

@test "--check still tolerates only the render timestamp changing" {
  # The counterpart: excluding one volatile line must not become excluding nothing,
  # or every run reports drift.
  run_sync
  [ "$status" -eq 0 ]
  sed -i.bak 's/^Rendered: .*/Rendered: 1999-01-01 00:00 UTC/' "$OUT"
  run_sync --check
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "every pricing table is explicitly labelled with its billing cadence" {
  run_sync
  [ "$status" -eq 0 ]
  grep -qi "billed monthly" "$OUT"
  grep -qi "billed annually" "$OUT"
}

@test "the render warns that the two cadences must not be blended" {
  # The doc has to tell Caroline WHY this matters, or the next human edit reintroduces
  # the blend.
  run_sync
  [ "$status" -eq 0 ]
  grep -qi "cadence\|do not mix\|never mix\|which cadence" "$OUT"
}

# ─── fail-closed ───

@test "a fetch failure leaves the previous file untouched" {
  run_sync
  [ "$status" -eq 0 ]
  cp "$OUT" "$TMP/before.md"
  run env APP_PRICING_URL="file://$TMP/missing.json" APP_PRICING_OUT="$OUT" \
    MUSO_BIN=/nonexistent bash "$SYNC"
  [ "$status" -ne 0 ]
  run diff -q "$TMP/before.md" "$OUT"
  [ "$status" -eq 0 ] || { echo "fail-closed violated" >&2; return 1; }
}

@test "an oversized payload is refused" {
  # Structurally valid but enormous: the ceiling is what stops a replaced route from
  # dumping something huge into the RAG index. Constructible, unlike a byte FLOOR,
  # which is why the floor was removed rather than left untestable.
  jq --arg pad "$(head -c 70000 /dev/zero | tr '\0' 'x')" '.data.padding = $pad' \
    "$FIXTURE" >"$SRC"
  run_sync
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "ceiling"
  [ ! -e "$OUT" ]
}

@test "malformed JSON is refused" {
  echo '{"result":"ok","data":{"plans":[' >"$SRC"
  run_sync
  [ "$status" -ne 0 ]
  [ ! -e "$OUT" ]
}

@test "a non-ok result envelope is refused" {
  jq '.result = "error" | .code = 500' "$FIXTURE" >"$SRC"
  run_sync
  [ "$status" -ne 0 ]
  [ ! -e "$OUT" ]
}

@test "an empty plans array is refused" {
  jq '.data.plans = []' "$FIXTURE" >"$SRC"
  run_sync
  [ "$status" -ne 0 ]
  [ ! -e "$OUT" ]
}

@test "a payload missing the Business seats bracket is refused" {
  # A degraded payload that still parses is the dangerous one: it would render a
  # plausible doc with the roster table silently absent.
  jq '(.data.plans[] | select(.additionalCosts != null) | .additionalCosts) = null' \
    "$FIXTURE" >"$SRC"
  run_sync
  [ "$status" -ne 0 ]
  [ ! -e "$OUT" ]
}

@test "a payload missing the org-users bracket is refused" {
  # The sibling of the seats case. Found in review: `seats` was guarded and `users`
  # was not, so this payload installed a file with EMPTY org-user tables and exited
  # 0, because a failing $( ) inside a heredoc is swallowed and `cat` still succeeds.
  jq '(.data.plans[] | select(.additionalCosts != null) | .additionalCosts.users) = null' \
    "$FIXTURE" >"$SRC"
  run_sync
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "users"
  [ ! -e "$OUT" ]
}

@test "a null price is refused, never rendered as \$null" {
  # It really did render "$null / month": the money formatter stringified whatever
  # it was handed instead of refusing.
  jq '(.data.plans[] | select(.id=="muso_team_pro_graduated_monthly") | .price) = null' \
    "$FIXTURE" >"$SRC"
  run_sync
  [ "$status" -ne 0 ]
  [ ! -e "$OUT" ]
}

@test "a non-numeric value inside a bracket is refused" {
  jq '(.data.plans[] | select(.id=="muso_team_business_graduated_monthly")
       | .additionalCosts.seats["1 - 5"]) = "free"' "$FIXTURE" >"$SRC"
  run_sync
  [ "$status" -ne 0 ]
  [ ! -e "$OUT" ]
}

@test "a non-numeric additionalSeatCost is refused" {
  jq '(.data.plans[] | select(.id=="muso_team_pro_graduated_monthly")
       | .additionalSeatCost) = "ask sales"' "$FIXTURE" >"$SRC"
  run_sync
  [ "$status" -ne 0 ]
  [ ! -e "$OUT" ]
}

@test "row blocks are precomputed, not substituted inside the heredoc" {
  # The structural half of the fix, pinned so it cannot regress into the swallowing
  # form. A $( ) inside the heredoc loses its exit status; a plain assignment keeps
  # it and set -e aborts the run.
  run grep -nE '^\$\(|\$\((bracket_rows|user_rows|plan_field)' "$SYNC"
  [ "$status" -eq 0 ]
  run grep -cE '^\s*(rows_|pro_|biz_)[a-z_]*=\$\((bracket_rows|user_rows|plan_field)' "$SYNC"
  [ "$status" -eq 0 ]
  # and none of those helpers may be called from within the heredoc body
  run bash -c "sed -n '/<<EOF/,/^EOF\$/p' '$SYNC' | grep -E '\\\$\\((bracket_rows|user_rows|plan_field)'"
  [ "$status" -ne 0 ] || {
    echo "a row helper is still called inside the heredoc:" >&2; echo "$output" >&2; return 1; }
}

@test "a payload missing the ANNUAL business plan is refused" {
  # Rendering only one cadence is exactly how the old doc came to imply the other.
  jq '.data.plans = [.data.plans[] | select(.id | test("annual") | not)]' "$FIXTURE" >"$SRC"
  run_sync
  [ "$status" -ne 0 ]
  [ ! -e "$OUT" ]
}

@test "a coupon-discounted payload is refused as non-canonical" {
  # public-plans applies coupons when asked. A discounted price is NOT list pricing
  # and must never become Caroline's quoted figure.
  jq '.data.couponApplied = true' "$FIXTURE" >"$SRC"
  run_sync
  [ "$status" -ne 0 ]
  [ ! -e "$OUT" ]
}

# ─── shared guards, same as the platform feed ───

@test "refuses an internal term in a bracket KEY (a field that reaches the render)" {
  # The bracket keys are API-controlled strings that ARE interpolated into the
  # tables, so they are a real leak path and the gate must cover them.
  jq '(.data.plans[] | select(.id=="muso_team_business_graduated_monthly")
       | .additionalCosts.seats) |= with_entries(
         if .key == "1 - 5" then .key = "1 - 5 (Kubernetes)" else . end)' \
    "$FIXTURE" >"$SRC"
  run_sync
  [ "$status" -ne 0 ] || { echo "LEAK: blocklist term published" >&2; return 1; }
  [ ! -e "$OUT" ]
}

@test "refuses an internal term in a price VALUE" {
  # jq -r emits a string price verbatim, so values are a leak path too.
  jq '(.data.plans[] | select(.id=="muso_team_pro_graduated_monthly") | .price)
      = "12.5 Hetzner"' "$FIXTURE" >"$SRC"
  run_sync
  [ "$status" -ne 0 ] || { echo "LEAK: blocklist term published" >&2; return 1; }
  [ ! -e "$OUT" ]
}

@test "an internal term in an UNPUBLISHED field does not refuse the feed" {
  # Deliberate scope choice, pinned so it is a decision rather than an accident:
  # the gate scans the RENDER, not the raw payload, because the renderer only ever
  # interpolates numbers and bracket keys -- plan `name` is never emitted. Scanning
  # the raw body instead would freeze Caroline's pricing over a term that could not
  # reach a customer. If the renderer ever starts emitting free text from the API,
  # this test should start failing and the gate must widen.
  jq '.data.plans[0].name = "Muso Pro (Kubernetes tier)"' "$FIXTURE" >"$SRC"
  run_sync
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  run grep -ci "kubernetes" "$OUT"
  [ "$status" -ne 0 ] || { echo "unpublished field leaked into the render" >&2; return 1; }
}

@test "the render disambiguates itself from the developer-platform pricing" {
  # Measured on node-8 2026-09-17: a query for "how much does the Business plan cost
  # per month" returned platform-api.md TWICE -- developer-API per-call rates ranking
  # on an app-subscription question. Both files are "Muso pricing", so the header has
  # to tell Caroline which product this one is before she quotes from it.
  run_sync
  [ "$status" -eq 0 ]
  grep -qi "not platform.muso.ai" "$OUT"
  grep -q "platform-api.md" "$OUT"
}

@test "prices render as money, not raw JSON numbers" {
  # The API sends 12.5 / 7.5 / 1.7. Printed bare they read as typos in a customer
  # quote, and "$1.7" in a roster table is genuinely ambiguous.
  run_sync
  [ "$status" -eq 0 ]
  grep -q '\$12\.50' "$OUT"
  grep -q '\$7\.50' "$OUT"
  grep -q '\$1\.70' "$OUT"
  # Whole dollars stay bare rather than gaining a pointless .00
  grep -q '\$120 ' "$OUT"
  run grep -E '\$[0-9]+\.[0-9]($|[^0-9])' "$OUT"
  [ "$status" -ne 0 ] || {
    echo "a price rendered with a single decimal place:" >&2; echo "$output" >&2; return 1; }
}

@test "a non-numeric price is still visible to the blocklist" {
  # money must not swallow a string value and hide it from the gate.
  jq '(.data.plans[] | select(.id=="muso_team_pro_graduated_monthly") | .price)
      = "12.5 Grafana"' "$FIXTURE" >"$SRC"
  run_sync
  [ "$status" -ne 0 ]
}

@test "no em-dash reaches Caroline's surface" {
  run_sync
  [ "$status" -eq 0 ]
  run grep -c $'\xe2\x80\x94' "$OUT"
  [ "$status" -ne 0 ] || { echo "em-dash in render" >&2; return 1; }
}

@test "no .tmp staging file survives a refused run" {
  jq '.result = "error"' "$FIXTURE" >"$SRC"
  run_sync
  [ "$status" -ne 0 ]
  run bash -c "ls '$TMP'/app-pricing.md.tmp.* 2>/dev/null"
  [ "$status" -ne 0 ]
}

# ─── operator modes ───

@test "--dry-run prints the render and writes nothing" {
  run_sync --dry-run
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ ! -e "$OUT" ]
  echo "$output" | grep -qi "billed monthly"
}

@test "--check exits 0 when current, nonzero when drifted" {
  run_sync
  [ "$status" -eq 0 ]
  run_sync --check
  [ "$status" -eq 0 ]
  echo "drift" >>"$OUT"
  run_sync --check
  [ "$status" -ne 0 ]
}

@test "the default source is the public anonymous endpoint" {
  grep -q 'APP_PRICING_URL:-https://api.muso.ai/api/w/v3/subscription/public-plans' "$SYNC"
}

@test "the default output path is inside Caroline's RAG directory" {
  grep -q 'APP_PRICING_OUT:-/opt/hydra/workspaces/support/reference/' "$SYNC"
}

@test "an unknown flag is a usage error, not a silent success" {
  run_sync --nope
  [ "$status" -eq 2 ]
}
