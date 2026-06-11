# normalize.jq — single source of truth for company domain/name normalization.
#
# Imported (jq -L <this dir>; include "normalize";) by every company-finder
# script: dedupe-candidates.sh, ledger.sh, verify-candidates.sh and
# migrate-normalize-domains.sh. Keeping one copy is what guarantees the
# dedup read-side and the ledger/CRM write-side can never drift apart —
# the 44-66% duplicate leak of 2026-06-08/09 was exactly a read/write
# normalization mismatch (stored "https://www.X.com/" vs candidate "x.com").

# Each split is guarded with // "" : an empty string splits to [], whose [0]
# is null and would crash the next split (latent bug inherited from the
# original inline copy — empty Domain rows do occur in live tables).
#
# Non-string inputs (LLM-produced candidate JSON can carry a number/object
# domain) normalize to "" instead of crashing jq mid-pipeline.
#
# The final charset gate maps anything that isn't a plausible hostname
# ([a-z0-9.-] only) to "" — downstream consumers treat "" as
# invalid-and-loud (ledger.sh suggest rejects it, verify-candidates.sh
# classifies it dead). Without the gate, characters like , ( ) ' " survive
# into NocoDB where-clause grammar (which has no value escaping) and into
# the xargs fan-out (which applies quote parsing), breaking both.
def norm_domain:
  (if type == "string" then . else "" end) | ascii_downcase
  | gsub("^\\s+|\\s+$"; "")
  | gsub("^[a-z]+://"; "")      # scheme
  | gsub("^www\\."; "")         # leading www.
  | (split(" ")[0] // "")      # drop trailing annotations, e.g. "x.com (updated)"
  | (split("/")[0] // "")      # path
  | (split("?")[0] // "")      # query
  | (split(":")[0] // "")      # port
  | gsub("\\.$"; "")           # trailing dot
  | (if test("^[a-z0-9.-]+$") then . else "" end);

def norm_name:
  (if type == "string" then . else "" end) | ascii_downcase
  | gsub("[^a-z0-9]+"; " ")    # punctuation -> space
  | gsub("^\\s+|\\s+$"; "")
  | gsub("\\s+"; " ");
