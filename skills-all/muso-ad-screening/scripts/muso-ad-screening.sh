#!/usr/bin/env bash
# muso-ad-screening.sh — the ONE sanctioned write path for the ad-screening PUT.
# Reject-by-default, like muso-read.sh, but it permits exactly one method on
# exactly one route shape: PUT /admin/ads/<adId>/screening. The route is built
# here, never taken from the caller; there is no method or path argument.
#
# muso-read.sh stays GET-only. The screener must not shell out to bare
# `muso api PUT` — this wrapper is what stands between a screener bug and an
# arbitrary admin write. Accident-safe, NOT a cryptographic boundary.
#
# Usage:
#   muso-ad-screening.sh put <adId> <payload.json>
#
# Rules:
#   <adId>          must match ^[0-9]+$
#   <payload.json>  must be a JSON object whose top-level keys are a subset of:
#                   screeningKey recommendation confidence brandFit harmFlags
#                   reason creativeDescription modelVersion riskFlags model policyVersion
#
# Env:
#   MUSO_BIN                    muso binary (default: muso, else /usr/local/bin/muso)
#   AD_SCREENING_CALLER         requester prefix (default: screener; [A-Za-z0-9._-]+)
#   AD_SCREENING_DISABLED_FILE  kill switch (default /etc/hydra/ad-screening.disabled)
#   Auth is the ambient MUSO_ADMIN_EMAIL/MUSO_ADMIN_PASSWORD from the gateway env.
#
# Exit codes:
#   0  ok (muso's own exit code on a permitted call)
#   2  usage error
#   3  refused — not the permitted route/method/payload
#   6  disabled via the kill switch (no call made)

set -euo pipefail

MUSO_BIN="${MUSO_BIN:-muso}"
# cron/systemd PATH (/usr/bin:/bin) excludes /usr/local/bin where muso lives.
if [ "$MUSO_BIN" = "muso" ] && ! command -v muso >/dev/null 2>&1 && [ -x /usr/local/bin/muso ]; then
  MUSO_BIN=/usr/local/bin/muso
fi

ALLOWED_KEYS='screeningKey recommendation confidence brandFit harmFlags reason creativeDescription modelVersion riskFlags model policyVersion'

usage() {
  awk 'NR==1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die() {
  echo "muso-ad-screening: $*" >&2
  exit 3
}

disabled_file="${AD_SCREENING_DISABLED_FILE:-/etc/hydra/ad-screening.disabled}"
if [ -e "$disabled_file" ]; then
  echo "muso-ad-screening: disabled via $disabled_file — no call made" >&2
  exit 6
fi

if [ "$#" -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  usage
  exit 2
fi
[ "$1" = "put" ] || die "refused — only 'put' is permitted (got '$1')"
[ "$#" -eq 3 ] || { usage >&2; exit 2; }

ad_id="$2"
payload="$3"

# Bash regex, not grep: grep is line-based and would accept "4242\nfoo".
[[ "$ad_id" =~ ^[0-9]+$ ]] || die "refused — adId must match ^[0-9]+\$"

caller="${AD_SCREENING_CALLER:-screener}"
[[ "$caller" =~ ^[A-Za-z0-9._-]+$ ]] || die "refused — AD_SCREENING_CALLER must match [A-Za-z0-9._-]+"

[ -f "$payload" ] || die "refused — payload file not found: $payload"
command -v python3 >/dev/null 2>&1 || die "refused — python3 required to validate the payload"
# shellcheck disable=SC2086  # ALLOWED_KEYS is a fixed word list
python3 - "$payload" $ALLOWED_KEYS <<'PY' || die "refused — payload must be a JSON object with only the allowed keys"
import json, sys
path, allowed = sys.argv[1], set(sys.argv[2:])
try:
    with open(path) as f:
        doc = json.load(f)
except (ValueError, OSError):
    sys.exit(1)
sys.exit(0 if isinstance(doc, dict) and set(doc) <= allowed else 1)
PY

exec "$MUSO_BIN" api PUT "/admin/ads/${ad_id}/screening" --data "@${payload}" --requester "${caller}@hydra-ad-screening"
