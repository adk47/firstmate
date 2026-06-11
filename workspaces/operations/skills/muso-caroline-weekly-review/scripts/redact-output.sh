#!/usr/bin/env bash
# Final-output PII scrub + voice gate. Reads stdin, writes stdout.
# Defends against the LLM reintroducing PII from summaries (bats fixture
# proves this is a real failure mode), and normalizes em/en dashes to hyphens
# so the assembled #cs_chats review cannot violate the skill's no-em-dash voice
# rule even if the LLM ignores the template.
#
# The patterns live in lib/redact-core.sed, shared verbatim with
# redact-json.sh (the structured-digest scrub) — see that file for the
# portability + digit-fencing rationale.

set -euo pipefail

exec sed -E -f "$(dirname "$0")/lib/redact-core.sed"
