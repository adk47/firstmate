#!/bin/bash
# ad-screening-brief.sh — compose the <=8-line Slack brief for one newly screened ad
# (MUS-3677). Sourced by ad-screening.sh; posting stays slack_notify's best-effort job.
#
# ad_screening_brief <ad-json> <creative-description> <rec> <confidence> <flags-csv> <reason>
# Advertiser text is attacker-controlled: backslashes, control chars and <> are stripped so it
# cannot ping anyone (<!channel>, <@U..>) or add lines, then every field is length-capped.
# Only the fixed Aaron mention pings. No deep link: the review page reads no ?ad= param.

AD_SCREENING_REVIEW_URL="https://promote.muso.ai/portal/admin/review"

_brief_clean() { # <text> <cap>
  local t="${1//[$'\001'-$'\037\177\\<>']/ }"
  t="$(printf '%s' "$t" | tr -s ' ')"
  [ -n "${t// /}" ] || t="not stated"
  jq -rj --argjson n "$2" '.[0:$n]' <<<"$(jq -Rn --arg t "$t" '$t')"
}

ad_screening_brief() {
  local ad="$1" creative="$2" rec="$3" conf="$4" flags="$5" reason="$6"
  local who head body goal spend pct
  who="$(jq -r '[.advertiserName, .adAccount.name, .company] | map(select(. != null and . != "")) | .[0] // ""' <<<"$ad")"
  head="$(jq -r '.adHeadline // ""' <<<"$ad")"; body="$(jq -r '.adBody // ""' <<<"$ad")"
  goal="$(jq -r '.campaign.objective // ""' <<<"$ad")"
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
  printf '%s\n' \
    "<@${SLACK_UID_AARON:-U7RP6HKUZ}> New ad to screen — advertiser: $(_brief_clean "$who" 80)" \
    "Says: \"$(_brief_clean "$head" 80)\" — $(_brief_clean "$body" 140)" \
    "Shows: $(_brief_clean "$creative" 140)" \
    "Spend: $(_brief_clean "$spend" 80)" \
    "Goal: $(_brief_clean "$goal" 60)" \
    "Jev: $rec ($pct confident), flags: ${flags:-none}" \
    "Why: $(_brief_clean "$reason" 300)" \
    "Decide here: $AD_SCREENING_REVIEW_URL"
}
