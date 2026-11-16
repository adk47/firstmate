#!/usr/bin/env bash
# sign-refund-approval.sh <record.json> [key] — sign a machine approval record.
#
# THIS RUNS ON THE REVIEWER HOST, never on node-8. The key it needs is the copy
# gate's reviewer key (the one that signs outbound-copy verdicts); node-8
# deliberately has no copy of it, so a root process there can write an approval
# record but cannot make it an approval. sign-refund-approval.sh cannot mint
# trust that `scripts/muso-stripe-write.sh` will not re-check: the wrapper
# verifies the signature itself, against a key list pinned to its own location.
#
#   ./scripts/sign-refund-approval.sh record.json ~/.ssh/outbound_copy_ed25519
#
# writes record.json.sig beside the record and re-verifies it immediately. Exit 0
# only when the wrapper's own check would pass.
set -euo pipefail

usage() { echo "usage: $0 <record.json> [key]" >&2; exit 2; }
[ $# -ge 1 ] && [ $# -le 2 ] || usage
rec="$1"
key="${2:-$HOME/.ssh/outbound_copy_ed25519}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
signers="$root/policies/refund-approval-reviewer.allowed_signers"
namespace="muso-refund-approval-v1"
signer_id="outbound-copy-reviewer"

[ -f "$rec" ] || { echo "no such record: $rec" >&2; exit 1; }
[ -f "$key" ] || { echo "no such key: $key (this must run on the reviewer host; node-8 has no copy)" >&2; exit 1; }
[ -f "$signers" ] || { echo "missing signers file: $signers" >&2; exit 1; }

# A record that says a legal-action threat, a settlement or a formal claim is
# refused by the wrapper whatever the signature says, so signing one only wastes
# a signature. Refuse here rather than let it look approved.
bad="$(jq -r 'select(.legal_settlement != false or .formal_claim != false or .legal_threat != false) | .charge' "$rec" 2>/dev/null || echo PARSE_FAILED)"
[ -z "$bad" ] || { echo "refusing to sign $rec: legal_settlement, formal_claim and legal_threat must all be false (got charge '$bad')" >&2; exit 1; }

rm -f "$rec.sig"
ssh-keygen -Y sign -f "$key" -n "$namespace" "$rec" >/dev/null
[ -f "$rec.sig" ] || { echo "signing produced no $rec.sig" >&2; exit 1; }

ssh-keygen -Y verify -f "$signers" -I "$signer_id" -n "$namespace" -s "$rec.sig" <"$rec" >/dev/null 2>&1 \
  || { echo "the signature does not verify against $signers; not an approval" >&2; exit 1; }

echo "signed $rec (namespace $namespace, signer $signer_id) -> $rec.sig"
echo "the wrapper re-checks this signature on every run; staging the record still requires an operator to arm the path."
