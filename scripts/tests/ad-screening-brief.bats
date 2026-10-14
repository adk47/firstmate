#!/usr/bin/env bats
# Tests for the Slack brief ad-screening.sh --run posts per newly screened ad (MUS-3677).
# Hermetic: muso-read, describe, jev and the PUT wrapper are stubbed, and MUSO_BIN is a
# stub that records the composed Slack text — nothing leaves the machine.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/ad-screening.sh"
FLAGS=(prohibited_category misleading_claims artist_impersonation adult gambling crypto_financial_promises other_harm)
BANNED='(tool|lookup|error|unavailable|system|API|ticket|ClickUp|openclaw|HYDRA)s?'

setup() {
  T="$BATS_TEST_TMPDIR"
  export STUB_DIR="$T"
  export AD_SCREENING_MUSO_READ="$T/muso-read" AD_SCREENING_DESCRIBE="$T/describe"
  export AD_SCREENING_JEV="$T/jev" AD_SCREENING_PUT="$T/put"
  export AD_SCREENING_DISABLED_FILE="$T/ad-screening.disabled"
  export STUB_FIXTURE="$T/fixture.json" STUB_ANSWERS="$T/answers.json"
  export MUSO_BIN="$T/muso" MUSO_SLACK_BOT_TOKEN_DEVOPS=x MUSO_SLACK_ENV_FILE="$T/none.env"
  unset SLACK_CHANNEL AD_SCREENING_SLACK_CHANNEL
  cat >"$AD_SCREENING_MUSO_READ" <<'S'
#!/usr/bin/env bash
cat "$STUB_FIXTURE"
S
  cat >"$AD_SCREENING_DESCRIBE" <<'S'
#!/usr/bin/env bash
echo "A purple album cover with a silhouette."
S
  cat >"$AD_SCREENING_JEV" <<'S'
#!/usr/bin/env bash
cat "$STUB_ANSWERS"
S
  cat >"$AD_SCREENING_PUT" <<'S'
#!/usr/bin/env bash
[ "${STUB_PUT_RC:-0}" -eq 0 ] && echo "$2" >>"$STUB_DIR/put.ids"
exit "${STUB_PUT_RC:-0}"
S
  # Slack stub: one file per send holding the --text value, one line per send in slack.argv.
  cat >"$MUSO_BIN" <<'S'
#!/usr/bin/env bash
n=$(( $(cat "$STUB_DIR/slack.n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$STUB_DIR/slack.n"
echo "$*" | head -n1 >>"$STUB_DIR/slack.argv"
while [ $# -gt 0 ]; do [ "$1" = --text ] && printf '%s' "$2" >"$STUB_DIR/slack.$n.txt"; shift; done
exit "${STUB_SLACK_RC:-0}"
S
  chmod +x "$AD_SCREENING_MUSO_READ" "$AD_SCREENING_DESCRIBE" "$AD_SCREENING_JEV" "$AD_SCREENING_PUT" "$MUSO_BIN"
}

ad() {
  jq -n --arg id "$1" '{id:$id, advertiserName:"Acme Records", adHeadline:"Hear it first", adBody:"New single out Friday",
    destinationUrl:"https://acme.example", primaryMediaUrl:"https://cdn.example/a.png",
    updatedAt:"2026-10-05T09:00:00Z", screenedAt:null, adAccount:{name:"Acme"},
    campaign:{objective:"awareness", budget:{amount:500,currency:"USD",type:"daily"}, schedule:{start:"2026-10-20",end:"2026-11-18"}}}'
}
fixture() { jq -s '{items: .}' >"$STUB_FIXTURE"; }

answers() {
  local rec="$1" p="$2" fit="$3" present="$4" f c pp out
  out="$(jq -n --arg rec "$rec" --argjson p "$p" --arg fit "$fit" '{
    recommendation:{type:"choice",choice:$rec,probabilities:({approve:0.05,reject:0.05,needs_human:0.05}|.[$rec]=$p)},
    brand_fit:{type:"choice",choice:$fit,probabilities:{($fit):0.8}}}')"
  for f in "${FLAGS[@]}"; do
    case ",$present," in *",$f,"*) c=present; pp=0.9 ;; *) c=absent; pp=0.95 ;; esac
    out="$(jq --arg k "harm_$f" --arg c "$c" --argjson p "$pp" '.[$k]={type:"choice",choice:$c,probabilities:{($c):$p}}' <<<"$out")"
  done
  echo "$out" >"$STUB_ANSWERS"
}
sends() { cat "$T/slack.n" 2>/dev/null || echo 0; }

@test "one brief per ad, at most 8 lines" {
  ad 101 | fixture; answers reject 0.87 weak adult
  run "$SCRIPT" --run
  [ "$status" -eq 0 ]
  [ "$(sends)" -eq 1 ]
  [ "$(wc -l <"$T/slack.1.txt")" -le 7 ]   # wc counts newlines: 8 lines = 7 newlines
}

@test "a second run with nothing new posts nothing (served ad is screened server-side)" {
  ad 101 | fixture; answers reject 0.87 weak adult
  "$SCRIPT" --run
  ad 101 | jq '.screenedAt="2026-10-05T09:05:00Z"' | fixture
  run "$SCRIPT" --run
  [ "$status" -eq 0 ]
  [ "$(sends)" -eq 1 ]
}

@test "brief carries all seven items and the real Aaron mention" {
  ad 101 | fixture; answers reject 0.87 weak adult
  "$SCRIPT" --run
  out="$(cat "$T/slack.1.txt")"
  for s in "<@U7RP6HKUZ>" "Acme Records" "Hear it first" "New single out Friday" "purple album cover" \
    'USD 500/day × 30 days = USD 15000' "awareness" "reject" "87%" "adult" "https://promote.muso.ai/portal/admin/review"; do
    [[ "$out" == *"$s"* ]] || { echo "missing: $s"; echo "$out"; return 1; }
  done
  [[ "$out" != *"@aaron"* ]]
  [[ "$out" != *"?ad="* ]]
  # reason line is the advertiser-facing text stored by the PUT: the brief repeats it
  [[ "$out" == *"adult content"* ]]
}

@test "no banned customer-facing word in the brief's own wording" {
  ad 101 | fixture; answers reject 0.87 weak adult
  "$SCRIPT" --run
  if grep -qiwE "$BANNED" "$T/slack.1.txt"; then cat "$T/slack.1.txt"; return 1; fi
}

@test "channel defaults, and AD_SCREENING_SLACK_CHANNEL overrides it" {
  ad 101 | fixture; answers approve 0.9 strong ""
  "$SCRIPT" --run
  grep -q -- "--channel C0ADV2W76G4" "$T/slack.argv"
  AD_SCREENING_SLACK_CHANNEL=C123TEST "$SCRIPT" --run
  grep -q -- "--channel C123TEST" "$T/slack.argv"
}

@test "Slack failure does not stop the write or the rest of the batch" {
  { ad 101; ad 102; } | fixture; answers reject 0.87 weak adult
  STUB_SLACK_RC=1 run "$SCRIPT" --run
  [ "$status" -eq 0 ]
  [ "$(sends)" -eq 2 ]
  [ "$(wc -l <"$T/put.ids")" -eq 2 ]
}

@test "no brief when the suggestion was not written" {
  ad 101 | fixture; answers reject 0.87 weak adult
  STUB_PUT_RC=1 run "$SCRIPT" --run
  [ "$status" -eq 0 ]
  [ "$(sends)" -eq 0 ]
}

@test "advertiser text cannot ping anyone or add lines" {
  ad 101 | jq '.adHeadline="<!channel> hi <@U1> x\\ny" | .adBody="a\nb\nc\nd\ne\nf\ng"' | fixture
  answers approve 0.9 strong ""
  "$SCRIPT" --run
  out="$(cat "$T/slack.1.txt")"
  [[ "$out" != *"<!channel>"* ]]
  [[ "$out" != *"<@U1>"* ]]
  [ "$(wc -l <"$T/slack.1.txt")" -le 7 ]
}

@test "missing budget says not stated instead of inventing a total" {
  ad 101 | jq 'del(.campaign.budget, .campaign.schedule)' | fixture; answers approve 0.9 strong ""
  "$SCRIPT" --run
  grep -q "not stated" "$T/slack.1.txt"
}

@test "cron-jobs.json: one Ad screening entry, every 5 min, runs --run (bare script refuses)" {
  run jq -e '[.jobs[] | select(.name == "Ad screening")] | length == 1 and
    (.[0].schedule.expr == "*/5 * * * *") and (.[0].payload.kind == "command") and
    (.[0].payload.argv == ["bash", "/opt/hydra/scripts/ad-screening.sh", "--run"])' "$HYDRA_REPO/cron-jobs.json"
  [ "$status" -eq 0 ]
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "spend: lifetime budget is shown as the total, never multiplied by the term" {
  ad 101 | jq '.campaign.budget.type="lifetime"' | fixture; answers reject 0.87 weak adult
  "$SCRIPT" --run
  grep -q 'Spend: USD 500 total' "$T/slack.1.txt"
}

@test "spend: unknown budget type or an absurd term shows the amount and never multiplies" {
  ad 101 | jq 'del(.campaign.budget.type)' | fixture; answers reject 0.87 weak adult
  "$SCRIPT" --run
  grep -q 'Spend: USD 500 (budget type or term not stated)' "$T/slack.1.txt"
  ad 102 | jq '.campaign.schedule={start:"2026-10-20",end:"2026-10-01"}' | fixture
  "$SCRIPT" --run
  grep -q 'Spend: USD 500/day' "$T/slack.2.txt" && return 1
  grep -q 'Spend: USD 500 (budget type or term not stated)' "$T/slack.2.txt"
}

@test "accented advertiser text is capped on characters, not bytes" {
  ad 101 | jq --arg n "$(printf 'é%.0s' $(seq 1 300))" '.advertiserName=$n' | fixture; answers reject 0.87 weak adult
  "$SCRIPT" --run
  ! grep -q $'\xef\xbf\xbd' "$T/slack.1.txt"
  [ "$(head -n1 "$T/slack.1.txt" | grep -o 'é' | wc -l)" -eq 80 ]
}
