#!/usr/bin/env bash
# Read admin-API GET /admin/profile/:id response (wrapped {body:{data:...}})
# OR a raw .body.data object, emit canonical profile JSON.
set -euo pipefail

src="${1:--}"

jq '
  (.body.data // .data // .) as $d |
  {
    id: ($d.id // $d._id // ""),
    name: ($d.name // ""),
    legal_name: ($d.legalName // $d.legal_name // ""),
    known_as_names: ($d.knownAsNames // $d.known_as_names // []),
    raw_ids: (
      ($d.rawProfiles // []) | map(select(.source != null and .id != null) | (.source + ":" + (.id|tostring)))
    ),
    ipis: (($d.ipis // []) | map(tostring)),
    popularity: ($d.popularity // 0),
    credit_count: (($d.creditCount // $d.credits_count // $d.credit_count // 0) | tonumber),
    country: ($d.country // ""),
    claim: {
      user_id: ($d.claiming.userId // $d.claim.user_id // null),
      status:  (if ($d.isClaimed // false) then "processed" else null end)
    }
  }
' "$src"
