#!/usr/bin/env bash
# ledger.sh — the ONLY sanctioned write path for the Company Seen Ledger and
# for company rows in Company Intelligence.
#
# WHY THIS EXISTS
#   NocoDB Cloud has no enforceable unique constraint, so "Domain is unique"
#   is enforced here: every write normalizes the domain (lib/normalize.jq —
#   the same normalization dedupe-candidates.sh reads with) and prechecks
#   the ledger, Company Intelligence AND Contacts Intelligence for collisions
#   before inserting, failing loudly instead of creating a duplicate. Agents
#   must never call records.create on these tables directly — that is how
#   dirty domains ("https://www.X.com/") and duplicates got in.
#
# SUBCOMMANDS
#   suggest                    stdin: JSON array of post-dedupe post-verify
#                              candidates [{name,domain,vertical?,why?,
#                              evidence?}, ...]. Records each as a ledger row
#                              with Status=suggested. Collision with ANY
#                              existing ledger/Company Intelligence domain
#                              fails the WHOLE batch atomically (nothing
#                              written) — a collision means dedupe was
#                              skipped or raced; re-run the pipeline.
#                              stdout: {recorded:[{domain,name,id}],stats}
#   reject  <domain> <reason>  Flips the ledger row to Status=rejected with
#                              Reject Reason + Decided At.
#   record-rejects             stdin: JSON array of TERMINAL mechanical
#                              rejects [{name,domain,reason,vertical?}, ...]
#                              (DEAD / NO_LINKEDIN / IN_GHL / SUBSIDIARY —
#                              never score-cuts, which must stay
#                              re-surfaceable). Writes Status=rejected rows
#                              directly so dedupe suppresses them on future
#                              runs. Idempotent: domains already anywhere in
#                              the ledger/CRM are SKIPPED (reported), not a
#                              fatal collision — unlike suggest, nothing
#                              human-facing depends on these rows being new.
#   approve <domain> [--industry "<Industry>"]
#                              Creates the Company Intelligence row (normalized
#                              Domain, Status="Needs Enrichment") then flips
#                              the ledger row to approved. Idempotent on
#                              retry: if CI already has the domain and the
#                              ledger row is still suggested, it just flips.
#
# Env overrides (mainly for tests):
#   NOCODB_API_SH      path to nocodb-api.sh (auto-located if unset)
#   COMPANY_TABLE_ID   default mvr6nmzcv7albxt (Company Intelligence)
#   LEDGER_TABLE_ID    Company Seen Ledger — auto-discovered by title at
#                      runtime; set only to skip/override the lookup
#   TODAY              override the date stamp (YYYY-MM-DD)
#   BATCH_SOURCE       default "manual" (cron sets cron:company-finder-daily)
#
# Exit codes: 0 ok, 1 usage/input error, 2 source unavailable,
#             3 collision / row not found / ambiguous, 4 write failed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

TODAY="${TODAY:-$(date -u +%F)}"
BATCH_SOURCE="${BATCH_SOURCE:-manual}"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  awk 'NR > 1 && /^set -euo pipefail/ {exit} NR > 1' "$0"
  exit 0
fi

locate_nocodb_api
resolve_ledger_table_id "LEDGER_SOURCE_UNAVAILABLE"

norm_domain() { jqn -rn --arg d "$1" 'include "normalize"; $d | norm_domain'; }

# fetch_mapped <tableId> <label> — full snapshot mapped to
# {id,domain,name,status,nd}. Always a FULL snapshot with client-side
# normalized matching, never a server-side eq lookup: stored domains can be
# dirty (Company Intelligence pre-migration, hand-edited ledger rows), and
# only the normalized comparison finds those — including the duplicate pairs
# the LEDGER_AMBIGUOUS guard exists to surface.
fetch_mapped() {
  local raw
  raw="$(fetch_table "$1" "$2" "Id,Domain,Company Name,Status" "LEDGER_SOURCE_UNAVAILABLE")" || return 2
  jqn -c 'include "normalize";
     map({id: .Id, domain: (.Domain // ""), name: (."Company Name" // ""),
          status: (.Status // ""), nd: (.Domain | norm_domain)})' <<<"$raw"
}

cmd="${1:-}"; shift || true

case "$cmd" in
  # ────────────────────────────────────────────────────────────────────────
  suggest)
    CANDS="$(read_candidates_stdin)"
    if [[ "$(jq 'length' <<<"$CANDS")" -eq 0 ]]; then
      echo '{"recorded":[],"stats":{"recorded":0}}'
      exit 0
    fi

    # Normalize; refuse empty domains and input-internal duplicates (dedupe
    # should have caught these — belt and suspenders).
    NORMED=$(jqn -c 'include "normalize"; map(. + {nd: (.domain | norm_domain)})' <<<"$CANDS")
    empties=$(jq -r 'map(select(.nd == "")) | .[].name' <<<"$NORMED")
    if [[ -n "$empties" ]]; then
      echo "ERROR: candidate(s) with empty/invalid domain: $empties" >&2
      exit 1
    fi
    internal_dupes=$(jq -r 'group_by(.nd) | map(select(length > 1) | .[0].nd) | .[]' <<<"$NORMED")
    if [[ -n "$internal_dupes" ]]; then
      echo "ERROR: input-internal duplicate domain(s): $internal_dupes — run dedupe-candidates.sh first." >&2
      exit 1
    fi

    # Collision precheck against ALL THREE dedupe sources (this is the unique
    # constraint) — Contacts Intelligence included, or a contacts-only domain
    # could be suggested and later approved into a cross-table duplicate.
    LEDGER_ROWS="$(fetch_mapped "$LEDGER_TABLE_ID" "Seen Ledger")" || exit 2
    COMPANY_ROWS="$(fetch_mapped "$COMPANY_TABLE_ID" "Company Intelligence")" || exit 2
    CONTACT_ROWS="$(fetch_mapped "$CONTACTS_TABLE_ID" "Contacts Intelligence")" || exit 2
    collisions=$(jq -rn --argjson cands "$NORMED" --argjson ledger "$LEDGER_ROWS" \
        --argjson company "$COMPANY_ROWS" --argjson contacts "$CONTACT_ROWS" '
      (($ledger   | map({key: .nd, value: "Seen Ledger"})) +
       ($company  | map({key: .nd, value: "Company Intelligence"})) +
       ($contacts | map({key: .nd, value: "Contacts Intelligence"}))
       | map(select(.key != "")) | from_entries) as $seen
      | $cands[] | select($seen[.nd]) | "LEDGER_COLLISION: \(.nd) (in \($seen[.nd]))"')
    if [[ -n "$collisions" ]]; then
      echo "$collisions" >&2
      exit 3
    fi

    # Known-clean set → one bulk insert (atomic from our side; NocoDB bulk
    # partial-failure behavior is undocumented, hence precheck-then-insert).
    rows=$(jq -c --arg today "$TODAY" --arg src "$BATCH_SOURCE" '
      map({"Domain": .nd, "Company Name": (.name // ""), "Status": "suggested",
           "Vertical": (.vertical // ""), "Suggested At": $today,
           "Evidence": (.evidence // ""), "Batch Source": $src})' <<<"$NORMED")
    if ! created=$(run_nocodb records.create "$LEDGER_TABLE_ID" "$rows" 2>&1); then
      echo "LEDGER_WRITE_FAILED: records.create — $created" >&2
      exit 4
    fi
    ids=$(jq -c 'if type == "array" then map(.Id // .id) else [.Id // .id] end' \
      <<<"$created" 2>/dev/null || echo '[]')
    jq -n --argjson cands "$NORMED" --argjson ids "$ids" '
      {recorded: [$cands | to_entries[] |
                  {domain: .value.nd, name: .value.name, id: ($ids[.key] // null)}],
       stats: {recorded: ($cands | length)}}'
    ;;

  # ────────────────────────────────────────────────────────────────────────
  record-rejects)
    CANDS="$(read_candidates_stdin)"
    if [[ "$(jq 'length' <<<"$CANDS")" -eq 0 ]]; then
      echo '{"recorded":[],"skipped_existing":[],"skipped_invalid":[],"stats":{"recorded":0,"skipped_existing":0,"skipped_invalid":0}}'
      exit 0
    fi
    missing_reason=$(jq -r 'map(select((.reason // "") == "")) | .[].name' <<<"$CANDS")
    if [[ -n "$missing_reason" ]]; then
      echo "ERROR: reject(s) without a reason: $missing_reason" >&2
      exit 1
    fi

    NORMED=$(jqn -c 'include "normalize"; map(. + {nd: (.domain | norm_domain)})' <<<"$CANDS")
    LEDGER_ROWS="$(fetch_mapped "$LEDGER_TABLE_ID" "Seen Ledger")" || exit 2
    COMPANY_ROWS="$(fetch_mapped "$COMPANY_TABLE_ID" "Company Intelligence")" || exit 2
    CONTACT_ROWS="$(fetch_mapped "$CONTACTS_TABLE_ID" "Contacts Intelligence")" || exit 2

    # Partition: invalid domain → skipped_invalid; already known anywhere →
    # skipped_existing (idempotent re-run / already suppressed); rest → write.
    PARTS=$(jq -cn --argjson cands "$NORMED" --argjson ledger "$LEDGER_ROWS" \
        --argjson company "$COMPANY_ROWS" --argjson contacts "$CONTACT_ROWS" '
      ([$ledger[], $company[], $contacts[] | .nd] | map(select(. != "")) | unique) as $seen
      | {invalid:  ($cands | map(select(.nd == ""))),
         existing: ($cands | map(select(.nd != "" and (.nd as $d | $seen | index($d))))),
         fresh:    ($cands | map(select(.nd != "" and ((.nd as $d | $seen | index($d)) | not))))}
      | .fresh |= (group_by(.nd) | map(.[0]))')
    fresh=$(jq -c '.fresh' <<<"$PARTS")
    if [[ "$(jq 'length' <<<"$fresh")" -gt 0 ]]; then
      rows=$(jq -c --arg today "$TODAY" --arg src "$BATCH_SOURCE" '
        map({"Domain": .nd, "Company Name": (.name // ""), "Status": "rejected",
             "Reject Reason": .reason, "Vertical": (.vertical // ""),
             "Suggested At": $today, "Decided At": $today, "Batch Source": $src})' <<<"$fresh")
      if ! created=$(run_nocodb records.create "$LEDGER_TABLE_ID" "$rows" 2>&1); then
        echo "LEDGER_WRITE_FAILED: records.create — $created" >&2
        exit 4
      fi
    fi
    jq -n --argjson p "$PARTS" '
      {recorded:         ($p.fresh    | map({domain: .nd, name: .name, reason: .reason})),
       skipped_existing: ($p.existing | map({domain: .nd, name: .name})),
       skipped_invalid:  ($p.invalid  | map({name: .name, domain: .domain})),
       stats: {recorded: ($p.fresh | length), skipped_existing: ($p.existing | length),
               skipped_invalid: ($p.invalid | length)}}'
    ;;

  # ────────────────────────────────────────────────────────────────────────
  reject|approve)
    domain="${1:-}"; shift || true
    if [[ -z "$domain" ]]; then
      echo "Usage: ledger.sh $cmd <domain> $([[ $cmd == reject ]] && echo '"<reason>"' || echo '[--industry "<Industry>"]')" >&2
      exit 1
    fi
    reason=""; industry=""
    if [[ "$cmd" == "reject" ]]; then
      reason="${1:-}"; shift || true
      if [[ -z "$reason" ]]; then
        echo "ERROR: reject requires a reason (e.g. \"dead site\", \"no LinkedIn\")." >&2
        exit 1
      fi
    else
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --industry)
            if [[ $# -lt 2 ]]; then
              echo "ERROR: --industry needs a value." >&2
              exit 1
            fi
            industry="$2"; shift 2 ;;
          *) echo "ERROR: unknown flag $1 for approve" >&2; exit 1 ;;
        esac
      done
    fi

    nd="$(norm_domain "$domain")"
    if [[ -z "$nd" ]]; then
      echo "ERROR: domain \"$domain\" normalizes to empty." >&2
      exit 1
    fi

    LEDGER_ROWS="$(fetch_mapped "$LEDGER_TABLE_ID" "Seen Ledger")" || exit 2
    matches=$(jq -c --arg nd "$nd" 'map(select(.nd == $nd))' <<<"$LEDGER_ROWS")
    nmatch=$(jq 'length' <<<"$matches")
    if [[ "$nmatch" -eq 0 ]]; then
      echo "LEDGER_ROW_NOT_FOUND: $nd" >&2
      exit 3
    elif [[ "$nmatch" -gt 1 ]]; then
      echo "LEDGER_AMBIGUOUS: $nd matches $nmatch ledger rows — merge them first." >&2
      exit 3
    fi
    row_id=$(jq -r '.[0].id' <<<"$matches")
    row_name=$(jq -r '.[0].name' <<<"$matches")
    row_status=$(jq -r '.[0].status' <<<"$matches")

    if [[ "$cmd" == "approve" ]]; then
      # CI insert first, ledger flip second. Idempotent retry: if CI already
      # has the domain AND the ledger row is still suggested, flip-only.
      # Full CI snapshot (not eq lookup): CI domains stay dirty until the
      # migration runs, so only a normalized client-side match is reliable.
      COMPANY_ROWS="$(fetch_mapped "$COMPANY_TABLE_ID" "Company Intelligence")" || exit 2
      ci_hit=$(jq -r --arg nd "$nd" 'map(select(.nd == $nd)) | length' <<<"$COMPANY_ROWS")
      if [[ "$ci_hit" -gt 0 && "$row_status" != "suggested" ]]; then
        echo "LEDGER_COLLISION: $nd (in Company Intelligence)" >&2
        exit 3
      fi
      if [[ "$ci_hit" -eq 0 ]]; then
        # Approval can run days after suggest — re-check Contacts Intelligence
        # at insert time too, or a domain added there in between would be
        # written into Company Intelligence as a cross-table duplicate.
        CONTACT_ROWS="$(fetch_mapped "$CONTACTS_TABLE_ID" "Contacts Intelligence")" || exit 2
        contact_hit=$(jq -r --arg nd "$nd" 'map(select(.nd == $nd)) | length' <<<"$CONTACT_ROWS")
        if [[ "$contact_hit" -gt 0 ]]; then
          echo "LEDGER_COLLISION: $nd (in Contacts Intelligence)" >&2
          exit 3
        fi
        ci_row=$(jq -nc --arg d "$nd" --arg n "$row_name" --arg i "$industry" \
          '{"Domain": $d, "Company Name": $n, "Status": "Needs Enrichment"}
           + (if $i != "" then {"Industry": $i} else {} end)')
        if ! run_nocodb records.create "$COMPANY_TABLE_ID" "$ci_row" >/dev/null 2>&1; then
          echo "LEDGER_WRITE_FAILED: Company Intelligence records.create for $nd" >&2
          exit 4
        fi
      fi
      new_status="approved"
      patch=$(jq -nc --arg id "$row_id" --arg today "$TODAY" \
        '[{"Id": ($id | tonumber? // $id), "Status": "approved", "Decided At": $today}]')
    else
      new_status="rejected"
      patch=$(jq -nc --arg id "$row_id" --arg today "$TODAY" --arg r "$reason" \
        '[{"Id": ($id | tonumber? // $id), "Status": "rejected", "Reject Reason": $r, "Decided At": $today}]')
    fi

    if ! run_nocodb records.update "$LEDGER_TABLE_ID" "$patch" >/dev/null 2>&1; then
      echo "LEDGER_WRITE_FAILED: records.update for $nd" >&2
      exit 4
    fi
    jq -n --arg d "$nd" --arg s "$new_status" '{domain: $d, status: $s}'
    ;;

  *)
    echo "Usage: ledger.sh suggest | record-rejects | reject <domain> \"<reason>\" | approve <domain> [--industry \"<Industry>\"]" >&2
    exit 1
    ;;
esac
