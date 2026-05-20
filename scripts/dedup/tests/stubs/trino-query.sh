#!/usr/bin/env bash
# Stub for trino-query.sh. Pattern-matches on the SQL text.
# Real trino-query.sh runs `trino --execute --output-format CSV` which emits
# data rows only (no header row in CLI mode), single-column results quoted.
set -euo pipefail
q="${1:-}"
if [[ "$q" == *"contains(raw_profile_ids, 'spotify:abc')"* ]]; then
  printf '"bbbb-bbbb"\n'
elif [[ "$q" == *"FROM postgresql_core.public.users WHERE lower(email)"* ]]; then
  printf '"12345"\n'
elif [[ "$q" == *"FROM postgresql_core.public.claiming"* ]]; then
  printf '"aaaa-aaaa"\n'
elif [[ "$q" == *"matvw_catalog_profile"* && "$q" == *"UNION ALL"* ]]; then
  printf '"raw_id","spotify:abc","aaaa-aaaa bbbb-bbbb",2\n'
elif [[ "$q" == *"matvw_catalog_track"* && "$q" == *"contains(transform"* ]]; then
  # shared-track-count.sh probe — stubbed pair has zero shared tracks.
  printf '"0"\n'
elif [[ "$q" == *"lower(name) = 'ali zain'"* ]]; then
  # find-name-matches.sh probe. Order matters: highest-credit anchor first.
  printf '"aaaa-aaaa","Ali Zain","38"\n'
  printf '"bbbb-bbbb","Ali Z.","7"\n'
fi
