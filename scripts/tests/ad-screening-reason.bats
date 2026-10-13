#!/usr/bin/env bats
# Tests for scripts/lib/ad-screening-reason.sh and scripts/ad-screening-questions.json.
# The reason string prefills the reviewer's reject box and is emailed to the
# advertiser (core-backend rejectAd.ts), so it is customer-facing text: it must
# be deterministic, <=500 chars, and free of the house-rule banned words.
# Hermetic: no network, no stubs needed.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
REASON="$HYDRA_REPO/scripts/lib/ad-screening-reason.sh"
QUESTIONS="$HYDRA_REPO/scripts/ad-screening-questions.json"

BANNED='(tool|lookup|error|unavailable|system|API|ticket|ClickUp|openclaw|HYDRA)s?'
FLAGS=(prohibited_category misleading_claims artist_impersonation adult gambling crypto_financial_promises other_harm)

@test "three flags: one line citing each policy section" {
  run "$REASON" --recommendation reject --brand-fit acceptable \
    --flags adult,gambling,misleading_claims
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *"§2.1"* ]]
  [[ "$output" == *"§2.2"* ]]
  [[ "$output" == *"§3"* ]]
  [[ "$output" == "Declined under the Muso ad policy:"* ]]
}

@test "banned words never appear, for every recommendation x brand-fit x flag subset" {
  # shellcheck source=/dev/null
  source "$REASON"
  local rec fit mask i flags out count=0
  for rec in approve reject needs_human; do
    for fit in strong acceptable weak off_brand; do
      for ((mask = 0; mask < 128; mask++)); do
        flags=""
        for i in "${!FLAGS[@]}"; do
          if ((mask & (1 << i))); then flags+="${flags:+,}${FLAGS[$i]}"; fi
        done
        out="$(ad_screening_reason "$rec" "$fit" "$flags")"
        [ -n "$out" ] || { echo "empty: $rec $fit [$flags]"; return 1; }
        if grep -qiwE "$BANNED" <<<"$out"; then
          echo "banned word: $rec $fit [$flags] -> $out"; return 1
        fi
        [ "${#out}" -le 500 ] || { echo "too long (${#out}): $rec $fit [$flags]"; return 1; }
        [[ "$out" != *$'\n'* ]] || { echo "multi-line: $rec $fit [$flags]"; return 1; }
        count=$((count + 1))
      done
    done
  done
  [ "$count" -eq 1536 ]
}

@test "clean approve renders a single approval line with no section cited as a problem" {
  run "$REASON" --recommendation approve --brand-fit strong --flags ""
  [ "$status" -eq 0 ]
  [ "$output" = "Recommended for approval: this ad meets the Muso ad policy." ]
}

@test "one flag: reject cites that section only" {
  run "$REASON" --recommendation reject --brand-fit acceptable --flags crypto_financial_promises
  [ "$status" -eq 0 ]
  [ "$output" = "Declined under the Muso ad policy: crypto or financial promises (§2.3). You can edit the ad and submit it again." ]
}

@test "off-brand with no flag cites section 5" {
  run "$REASON" --recommendation reject --brand-fit off_brand --flags ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"§5"* ]]
  [[ "$output" != *"§2"* ]]
}

@test "needs_human asks for a closer read and never guesses a verdict" {
  run "$REASON" --recommendation needs_human --brand-fit acceptable --flags ""
  [ "$status" -eq 0 ]
  [ "$output" = "Needs a closer read by a Muso reviewer against the Muso ad policy." ]
}

@test "other_harm cites both 2.5 and 2.6" {
  run "$REASON" --recommendation reject --brand-fit strong --flags other_harm
  [[ "$output" == *"§2.5, §2.6"* ]]
}

@test "output is deterministic regardless of flag order" {
  a="$("$REASON" --recommendation reject --brand-fit weak --flags gambling,adult)"
  b="$("$REASON" --recommendation reject --brand-fit weak --flags adult,gambling)"
  [ "$a" = "$b" ]
}

@test "unknown recommendation, brand-fit or flag is refused with no stdout" {
  run --separate-stderr "$REASON" --recommendation maybe --brand-fit strong --flags ""
  [ "$status" -eq 2 ]; [ -z "$output" ]
  run --separate-stderr "$REASON" --recommendation reject --brand-fit great --flags ""
  [ "$status" -eq 2 ]; [ -z "$output" ]
  run --separate-stderr "$REASON" --recommendation reject --brand-fit strong --flags bogus
  [ "$status" -eq 2 ]; [ -z "$output" ]
}

@test "an option with no value fails fast instead of hanging" {
  for args in "--recommendation" "--recommendation reject --brand-fit" "--recommendation reject --brand-fit strong --flags"; do
    # shellcheck disable=SC2086
    run --separate-stderr timeout 5 "$REASON" $args
    [ "$status" -eq 2 ]
    [ -z "$output" ]
  done
}

@test "weak brand-fit is not described as irrelevant to the audience" {
  run "$REASON" --recommendation reject --brand-fit weak --flags ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"on-brand guidelines (§5)"* ]]
  [[ "$output" != *"not relevant"* ]]
}

@test "sourced function leaves the caller's globbing mode untouched, on success and on refusal" {
  # shellcheck source=/dev/null
  source "$REASON"
  local before="$-"
  ad_screening_reason reject weak adult >/dev/null
  [ "$-" = "$before" ]
  ad_screening_reason reject weak bogus 2>/dev/null || true
  [ "$-" = "$before" ]
  set -f
  ad_screening_reason reject weak adult >/dev/null
  [[ "$-" == *f* ]]
  set +f
  ad_screening_reason reject weak '*' 2>/dev/null || true
  [[ "$-" != *f* ]]
}

@test "a newline-separated flag list is refused, never silently dropped" {
  for rec in approve reject needs_human; do
    run --separate-stderr "$REASON" --recommendation "$rec" --brand-fit strong --flags $'adult\ngambling'
    [ "$status" -eq 2 ]
    [ -z "$output" ]
  done
}

@test "approve contradicted by a flag or a weak fit is downgraded to a reviewer read, never an approval" {
  for args in "--brand-fit strong --flags adult" "--brand-fit weak --flags ''" "--brand-fit off_brand --flags gambling,misleading_claims"; do
    run eval "'$REASON' --recommendation approve $args"
    [ "$status" -eq 0 ]
    [[ "$output" == "Needs a closer read by a Muso reviewer:"* ]]
    [[ "$output" != *"Recommended for approval"* ]]
    run eval "'$REASON' --recommendation approve $args --effective-recommendation"
    [ "$output" = "needs_human" ]
  done
}

@test "reject that cites no breach is downgraded to a reviewer read, never a bare decline" {
  run "$REASON" --recommendation reject --brand-fit acceptable --flags ""
  [ "$output" = "Needs a closer read by a Muso reviewer against the Muso ad policy." ]
  run "$REASON" --recommendation reject --brand-fit strong --flags "" --effective-recommendation
  [ "$output" = "needs_human" ]
}

@test "consistent recommendations keep their own effective value" {
  run "$REASON" --recommendation approve --brand-fit strong --flags "" --effective-recommendation
  [ "$output" = "approve" ]
  run "$REASON" --recommendation reject --brand-fit weak --flags adult --effective-recommendation
  [ "$output" = "reject" ]
  run "$REASON" --recommendation needs_human --brand-fit strong --flags "" --effective-recommendation
  [ "$output" = "needs_human" ]
}

@test "questions file: nine ids, exact classes, jev.sh shape" {
  jq -e 'keys | length == 9' "$QUESTIONS"
  jq -e '.recommendation.criteria | keys == ["approve","needs_human","reject"]' "$QUESTIONS"
  jq -e '.brand_fit.criteria | keys == ["acceptable","off_brand","strong","weak"]' "$QUESTIONS"
  for f in "${FLAGS[@]}"; do
    jq -e --arg k "harm_$f" '.[$k].criteria | keys == ["absent","present"]' "$QUESTIONS"
  done
  jq -e 'all(.[]; .type == "choice" and (.instructions | type == "string" and length > 0)
        and (.criteria | all(.[]; type == "string" and length > 0)))' "$QUESTIONS"
}

@test "questions file: each question frames ONE ad application against the Muso ad policy" {
  jq -e 'all(.[]; .instructions | test("ONE ad application") and test("Muso ad policy"))' "$QUESTIONS"
  jq -e '.recommendation.criteria.needs_human | test("uncertain"; "i") and test("escalat"; "i")' "$QUESTIONS"
}
