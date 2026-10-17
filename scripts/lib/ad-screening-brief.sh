#!/bin/bash
# ad-screening-brief.sh — compose the Slack brief (Block Kit card + <=8-line text fallback) for one newly screened ad
# (MUS-3677). Sourced by ad-screening.sh; posting stays slack_notify's best-effort job.
#
# ad_screening_brief_payload <channel> <out-file> <ad-json> <creative-description> <rec> <confidence> <flags-csv> <reason>
# Writes a chat.postMessage payload {channel, text, blocks} to <out-file>, built with jq --arg only.
# Advertiser text is attacker-controlled: it lands only in plain_text objects (mentions and *bold* are
# inert there), and is also stripped of control chars and <> and length-capped. The one mrkdwn
# mention block and the fallback text carry the fixed Aaron mention. No deep link: the review page reads no ?ad= param.

AD_SCREENING_REVIEW_URL="https://promote.muso.ai/portal/admin/review"

_brief_clean() { # <text> <cap>
  local t="${1//[$'\001'-$'\037\177\\<>']/ }"
  t="$(printf '%s' "$t" | tr -s ' ')"
  [ -n "${t// /}" ] || t="not stated"
  jq -rj --argjson n "$2" '.[0:$n]' <<<"$(jq -Rn --arg t "$t" '$t')"
}

ad_screening_brief_payload() {
  local channel="$1" out="$2" ad="$3" creative="$4" rec="$5" conf="$6" flags="$7" reason="$8"
  local who head body goal spend pct acct dest img mention text
  who="$(jq -r '[.advertiserName, .adAccount.name, .company] | map(select(. != null and . != "")) | .[0] // ""' <<<"$ad")"
  head="$(jq -r '.adHeadline // ""' <<<"$ad")"; body="$(jq -r '.adBody // ""' <<<"$ad")"
  goal="$(jq -r '.campaign.objective // ""' <<<"$ad")"
  acct="$(jq -r '.adAccount.name // ""' <<<"$ad")"
  dest="$(jq -r '.destinationUrl // ""' <<<"$ad")"; img="$(jq -r '.primaryMediaUrl // ""' <<<"$ad")"
  spend="$(jq -r '
    def day: (.[0:10] + "T00:00:00Z") | fromdateiso8601;
    .campaign as $c | ($c.budget.amount) as $b | ($c.budget.currency // "") as $cur
    | (try ((($c.schedule.end | day) - ($c.schedule.start | day)) / 86400 + 1) catch null) as $d
    | if ($b | type) != "number" or $b < 0 or $b > 1e12 then "not stated"
      elif $c.budget.type == "lifetime" then "\($cur) \($b) total"
      elif $c.budget.type == "daily" and ($d | type) == "number" and $d >= 1 and $d <= 3650
        then "\($cur) \($b)/day × \($d) days = \($cur) \($b * $d)"
      else "\($cur) \($b) (budget type or term not stated)" end' <<<"$ad")"
  pct="$(awk -v c="$conf" 'BEGIN { printf "%d%%", c * 100 + 0.5 }')"
  mention="<@${SLACK_UID_AARON:-U7RP6HKUZ}>"
  who="$(_brief_clean "$who" 80)"; head="$(_brief_clean "$head" 80)"; body="$(_brief_clean "$body" 140)"
  creative="$(_brief_clean "$creative" 140)"; spend="$(_brief_clean "$spend" 80)"; goal="$(_brief_clean "$goal" 60)"
  acct="$(_brief_clean "$acct" 80)"; reason="$(_brief_clean "$reason" 300)"
  text="$(printf '%s\n' \
    "$mention New ad to screen — advertiser: $who" \
    "Says: \"$head\" — $body" \
    "Shows: $creative" \
    "Spend: $spend" \
    "Goal: $goal" \
    "Jev: $rec ($pct confident), flags: ${flags:-none}" \
    "Why: $reason" \
    "Decide here: $AD_SCREENING_REVIEW_URL")"
  jq -n --arg channel "$channel" --arg text "$text" --arg mention "$mention" --arg who "$who" \
    --arg head "$head" --arg body "$body" --arg creative "$creative" --arg spend "$spend" --arg goal "$goal" \
    --arg acct "$acct" --arg dest "$dest" --arg destplain "$(_brief_clean "$dest" 200)" --arg img "$img" \
    --arg rec "$rec" --arg pct "$pct" --arg flags "${flags:-none}" --arg reason "$reason" --arg url "$AD_SCREENING_REVIEW_URL" '
    def okurl: length <= 500 and test("^https://[^\\s<>|`]+\\z");
    def pt(t): {type: "plain_text", text: t};
    def icon: {approve: "✅", reject: "⛔", needs_human: "👀"}[$rec] // "";
    (if ($img | okurl and test("\\.(png|jpe?g|gif|webp)\\z"; "i")) then $img else null end) as $image
    | {channel: $channel, text: $text, blocks: [
        {type: "header", text: pt("New ad to review: \($who)")},
        ({type: "section", text: pt("\($head)\n\($body)")}
          + (if $image then {accessory: {type: "image", image_url: $image, alt_text: $creative}} else {} end)),
        {type: "section", fields: [
          pt("Spend: \($spend)"), pt("Goal: \($goal)"), pt("Advertiser account: \($acct)"),
          (if ($dest | okurl) then {type: "mrkdwn", text: "*Destination:* <\($dest | gsub("&"; "&amp;"))|Open destination>"}
           else pt("Destination: \($destplain)") end)]},
        {type: "context", elements: [
          {type: "mrkdwn", text: "\(icon) Jev suggests *\($rec)* · \($pct) · flags: \($flags)"}, pt("Why: \($reason)")]},
        {type: "section", text: {type: "mrkdwn", text: "\($mention) new ad waiting for your decision"}},
        # TODO MUS-9894: append ?ad=<id> once the deep link is on prod
        {type: "actions", elements: [{type: "button", action_id: "review_ad", url: $url, text: pt("Review in Ads Manager")}]}]}' >"$out"
}
