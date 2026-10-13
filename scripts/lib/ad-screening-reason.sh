#!/bin/bash
# ad-screening-reason.sh — render the advertiser-facing screeningReason from
# Jev's selected classes. Deterministic; no model prose.
#
# The string prefills the reviewer's reject box and is emailed to the
# advertiser (core-backend rejectAd.ts), so it is customer-facing text and
# must never contain: tool lookup error unavailable system API ticket ClickUp
# openclaw HYDRA. Every phrase below is a fixed literal; keep it that way.
#
# Usage:  ad-screening-reason.sh --recommendation approve|reject|needs_human \
#           --brand-fit strong|acceptable|weak|off_brand --flags a,b,c
#   or:   source ad-screening-reason.sh; ad_screening_reason REC FIT FLAGS
# Add --effective-recommendation (4th arg "effective") to print the recommendation
# after contradiction handling instead; callers should store that, not Jev's raw pick.
# Prints one line (<=500 chars). Exit 2, nothing on stdout, on an unknown class.
# Policy sections follow Muso Ad Policy v1 (ads-manager docs/ad-policy.md).

# Vocabulary order is also the render order, so output ignores input order.
_AD_REASON_FLAGS=(prohibited_category misleading_claims artist_impersonation adult gambling crypto_financial_promises other_harm)

_ad_reason_phrase() {
  case "$1" in
    prohibited_category) echo "a prohibited category (§2)" ;;
    misleading_claims) echo "misleading claims (§3)" ;;
    artist_impersonation) echo "artist or rights impersonation (§4)" ;;
    adult) echo "adult content (§2.1)" ;;
    gambling) echo "gambling (§2.2)" ;;
    crypto_financial_promises) echo "crypto or financial promises (§2.3)" ;;
    other_harm) echo "harmful or deceptive content (§2.5, §2.6)" ;;
    *) return 1 ;;
  esac
}

# The nine Jev answers are independent, so they can contradict each other.
# Contradictions fail safe: an approve with any issue, or a reject citing no
# breach, is rendered (and, with a 4th arg of "effective", reported) as needs_human.
ad_screening_reason() {
  local rec="$1" fit="$2" flags="$3" mode="${4:-}" f known issues="" parts=()
  case "$rec" in approve | reject | needs_human) ;; *) echo "unknown recommendation: $rec" >&2; return 2 ;; esac
  case "$fit" in strong | acceptable | weak | off_brand) ;; *) echo "unknown brand-fit: $fit" >&2; return 2 ;; esac

  # read -a splits without pathname expansion, so no shell-state change; -d ''
  # reads past newlines so a multi-line list is refused as an unknown flag.
  IFS=, read -r -d '' -a parts < <(printf '%s' "$flags") || true
  for f in "${parts[@]}"; do
    _ad_reason_phrase "$f" >/dev/null || { echo "unknown flag: $f" >&2; return 2; }
  done
  for known in "${_AD_REASON_FLAGS[@]}"; do
    case ",$flags," in *",$known,"*) issues+="${issues:+; }$(_ad_reason_phrase "$known")" ;; esac
  done
  case "$fit" in
    off_brand) issues+="${issues:+; }not relevant to the Muso audience (§5)" ;;
    weak) issues+="${issues:+; }does not meet our on-brand guidelines (§5)" ;;
  esac

  case "$rec:${issues:+issues}" in approve:issues | reject:) rec=needs_human ;; esac
  if [ "$mode" = effective ]; then echo "$rec"; return 0; fi

  case "$rec" in
    approve)
      echo "Recommended for approval: this ad meets the Muso ad policy." ;;
    reject)
      echo "Declined under the Muso ad policy: $issues. You can edit the ad and submit it again." ;;
    needs_human)
      if [ -z "$issues" ]; then echo "Needs a closer read by a Muso reviewer against the Muso ad policy."
      else echo "Needs a closer read by a Muso reviewer: $issues."; fi ;;
  esac
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  rec="" fit="" flags="" mode=""
  while [ $# -gt 0 ]; do
    case "$1" in --recommendation | --brand-fit | --flags)
      [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 2; } ;;
    esac
    case "$1" in
      --recommendation) rec="${2:-}"; shift 2 ;;
      --brand-fit) fit="${2:-}"; shift 2 ;;
      --flags) flags="${2:-}"; shift 2 ;;
      --effective-recommendation) mode=effective; shift ;;
      *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
  done
  ad_screening_reason "$rec" "$fit" "$flags" "$mode"
fi
