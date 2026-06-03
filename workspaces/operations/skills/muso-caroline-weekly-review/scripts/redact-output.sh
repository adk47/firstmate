#!/usr/bin/env bash
# Final-output PII scrub + voice gate. Reads stdin, writes stdout.
# Defends against the LLM reintroducing PII from summaries (bats fixture
# proves this is a real failure mode), and normalizes em/en dashes to hyphens
# so the assembled #cs_chats review cannot violate the skill's no-em-dash voice
# rule even if the LLM ignores the template.
#
# Deviation from plan: the Stripe-id and phone regexes use explicit digit/POSIX
# boundaries instead of \b because BSD sed (macOS) silently ignores \b word
# boundaries. POSIX character classes are portable across BSD and GNU sed.
#
# The phone regex is fenced by (^|[^0-9]) ... ([^0-9]|$) so it only fires when the
# 10-13 digit run is NOT embedded in a longer digit run. Without the fence the
# pattern matched the first ~13 digits of a 15-16 digit numeric Intercom
# conversation id (e.g. 215474545718046 -> <phone>46), destroying the citation IDs
# the weekly report needs as evidence pointers. The boundary chars are captured
# (\1, \4) and restored so surrounding text is preserved.

set -euo pipefail

sed -E \
  -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g' \
  -e 's/(^|[^0-9])((\+?[0-9]{1,3}[ .-]?)?\(?[0-9]{3}\)?[ .-]?[0-9]{3}[ .-]?[0-9]{4})([^0-9]|$)/\1<phone>\4/g' \
  -e 's/(^|[[:space:]]|\()(cus|pi|ch)_[A-Za-z0-9_]+/\1<stripe_id>/g' \
  -e 's/—/-/g' \
  -e 's/–/-/g'
