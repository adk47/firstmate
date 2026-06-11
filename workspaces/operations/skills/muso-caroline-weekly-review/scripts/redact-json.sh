#!/usr/bin/env bash
# PII scrub for the structured digest (digest.json). Reads the digest from $1
# (or stdin), applies the shared lib/redact-core.sed patterns to the COMPACT
# JSON serialization, proves the result still parses, and writes it to stdout.
#
# WHY a separate script from redact-output.sh: the digest text is authored from
# already-redacted inputs, but the LLM can reintroduce PII it saw in summaries
# (the documented redact-output.sh failure mode) — and the Block Kit payload is
# built from digest.json, NOT from the plain-text render, so the JSON itself
# must be scrubbed before any renderer touches it.
#
# Safety of sed-over-JSON: jq -c first gives canonical escaping on ONE line;
# none of the redact-core character classes can consume a '"' (emails/phones/
# stripe-ids are quote-free token classes), so a match can never span two JSON
# strings or eat structure. The replacement tokens (<email>, <phone>,
# <stripe_id>, '-') introduce no ", \ or control chars. The jq -e re-parse
# below is the mechanical proof; if it ever fails, fail loud — never emit a
# half-scrubbed digest.

set -euo pipefail

CORE="$(dirname "$0")/lib/redact-core.sed"
INPUT="${1:-/dev/stdin}"

compact=$(jq -ce . "$INPUT") \
  || { echo "redact-json: input is not valid JSON" >&2; exit 1; }

scrubbed=$(printf '%s\n' "$compact" | sed -E -f "$CORE")

printf '%s\n' "$scrubbed" | jq -e . >/dev/null 2>&1 \
  || { echo "redact-json: redaction broke JSON parsing - refusing to emit" >&2; exit 1; }

printf '%s\n' "$scrubbed"
