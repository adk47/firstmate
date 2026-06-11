# Shared PII-scrub + dash-normalization expressions (sed -E syntax).
# Single source of truth consumed by BOTH redact-output.sh (plain-text digest
# stream) and redact-json.sh (compact digest.json line) — keep the two paths
# byte-identical so a pattern fix can never land in one and not the other.
#
# Portability: explicit digit/POSIX boundaries instead of \b because BSD sed
# (macOS, where the bats suite runs) silently ignores \b word boundaries.
#
# The phone regex is fenced by (^|[^0-9]) ... ([^0-9]|$) so it only fires when
# the 10-13 digit run is NOT embedded in a longer digit run. Without the fence
# the pattern matched the first ~13 digits of a 15-16 digit numeric Intercom
# conversation id (e.g. 215474545718046 -> <phone>46), destroying the citation
# IDs the digest needs as evidence pointers. The boundary chars are captured
# (\1, \4) and restored so surrounding text is preserved. None of the
# replacement tokens introduce ", \ or control chars, so applying this file to
# a compact JSON line cannot break JSON escaping (redact-json.sh re-parses to
# prove it anyway).
s/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g
s/(^|[^0-9])((\+?[0-9]{1,3}[ .-]?)?\(?[0-9]{3}\)?[ .-]?[0-9]{3}[ .-]?[0-9]{4})([^0-9]|$)/\1<phone>\4/g
s/(^|[[:space:]]|\()(cus|pi|ch)_[A-Za-z0-9_]+/\1<stripe_id>/g
s/—/-/g
s/–/-/g
