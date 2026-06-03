#!/usr/bin/env bash
# Scrub PII from a conversations.jsonl file before LLM grading: emails, customer
# last names, and (in transcript bodies) phone numbers + Stripe/payment IDs.
# Preserves customer_first_name for tone context. This is the file the LLM reads,
# so it must be clean here — redact-output.sh's phone/Stripe pass runs only on the
# final Slack/PR text, after the model has already seen the input.
#
# Usage: redact.sh <input.jsonl> <output.jsonl>

set -euo pipefail

INPUT="${1:?input.jsonl required}"
OUTPUT="${2:?output.jsonl required}"

EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'

# Escape regex metacharacters in a string for safe interpolation into sed -E.
# Uses chained sed calls to avoid BSD-sed bracket-class bugs with \\ and /.
escape_re() {
  local s="$1"
  s=$(printf '%s' "$s" | sed 's/\\/\\\\/g')
  s=$(printf '%s' "$s" | sed 's/\./\\./g')
  s=$(printf '%s' "$s" | sed 's/+/\\+/g')
  s=$(printf '%s' "$s" | sed 's/\*/\\*/g')
  s=$(printf '%s' "$s" | sed 's/?/\\?/g')
  s=$(printf '%s' "$s" | sed 's/\^/\\^/g')
  s=$(printf '%s' "$s" | sed 's/\$/\\$/g')
  s=$(printf '%s' "$s" | sed 's/{/\\{/g')
  s=$(printf '%s' "$s" | sed 's/}/\\}/g')
  s=$(printf '%s' "$s" | sed 's/(/\\(/g')
  s=$(printf '%s' "$s" | sed 's/)/\\)/g')
  s=$(printf '%s' "$s" | sed 's/|/\\|/g')
  s=$(printf '%s' "$s" | sed 's/\[/\\[/g')
  s=$(printf '%s' "$s" | sed 's/\]/\\]/g')
  printf '%s' "$s"
}

line_no=0
while IFS= read -r line; do
  line_no=$((line_no + 1))

  # Parse fields. If jq fails on a malformed line, DROP the line entirely —
  # passing it through unscrubbed would leak PII (the redaction sed passes
  # only run when jq succeeds). One malformed input line shouldn't ship a
  # customer email into the LLM-graded fixture.
  if ! parsed=$(printf '%s' "$line" | jq -r '[.customer_first_name // "", .customer_last_name // ""] | @tsv' 2>/dev/null); then
    echo "redact: WARN: dropping malformed JSON at line $line_no" >&2
    continue
  fi
  first_name=$(printf '%s' "$parsed" | cut -f1)
  last_name=$(printf '%s' "$parsed" | cut -f2)

  redacted="$line"

  # 1. Strip emails everywhere in the raw line (covers body fields and customer_email)
  redacted=$(printf '%s' "$redacted" | sed -E "s/${EMAIL_RE}/<email>/g")

  # 2. In transcript bodies: "First Last" -> "First L." (portable, no \b needed)
  if [ -n "$first_name" ] && [ -n "$last_name" ]; then
    initial="${last_name:0:1}"
    first_esc=$(escape_re "$first_name")
    last_esc=$(escape_re "$last_name")
    redacted=$(printf '%s' "$redacted" | sed -E "s/${first_esc} ${last_esc}/${first_name} ${initial}./g")
  fi

  # 2b. Scrub bare last-name occurrences in the body that are NOT adjacent to
  # the first name (e.g. a sign-off "regards, Smith"). Step 2 only catches
  # "First Last"; a lone surname would otherwise survive into the LLM and the
  # final #cs_chats review. Word-bounded on both sides so we never clip a
  # longer word ("Smithfield"); guarded on length>=3 to avoid mangling very
  # short surnames. BSD sed has no \b, so use explicit POSIX boundaries.
  if [ -n "$last_name" ] && [ "${#last_name}" -ge 3 ]; then
    initial="${last_name:0:1}"
    last_esc=$(escape_re "$last_name")
    redacted=$(printf '%s' "$redacted" | sed -E "s/(^|[^A-Za-z])${last_esc}([^A-Za-z]|\$)/\1${initial}.\2/g")
  fi

  # 3. Scrub customer_last_name JSON field value via jq (handles bare last-name
  #    occurrences in the structured metadata without sed-regex portability issues).
  if [ -n "$last_name" ]; then
    initial="${last_name:0:1}"
    _before_jq="$redacted"
    if ! redacted=$(printf '%s' "$redacted" | jq -c --arg init "$initial." '.customer_last_name = $init' 2>/dev/null); then
      echo "redact: WARN: customer_last_name scrub failed at line $line_no — passing through un-last-name-scrubbed" >&2
      redacted="$_before_jq"
    fi
  fi

  # 4. Scrub phone numbers and Stripe/payment IDs from transcript bodies. This is
  #    the file the LLM grades, so the input must be clean — the phone/Stripe
  #    regexes in redact-output.sh run only on the FINAL Slack/PR text, AFTER the
  #    model has already read conversations.redacted.jsonl. Scope to .parts[].body
  #    via jq (NOT a line-level sed) so the scrub never touches structural fields
  #    like the numeric id/contact_id. The phone regex is also digit-fenced
  #    ((?<pre>^|[^0-9]) ... (?<post>[^0-9]|$)) so it won't fire inside a longer
  #    digit run (e.g. an order number a customer pasted). Same phone+Stripe
  #    regexes as redact-output.sh; the redact.bats phone/stripe cases are the
  #    guard against the two scrubbers drifting apart again (that divergence is
  #    what leaked these to the LLM).
  _before_pii="$redacted"
  if ! redacted=$(printf '%s' "$redacted" | jq -c '
        def scrub:
          gsub("(?<pre>^|[^0-9])((\\+?[0-9]{1,3}[ .-]?)?\\(?[0-9]{3}\\)?[ .-]?[0-9]{3}[ .-]?[0-9]{4})(?<post>[^0-9]|$)"; "\(.pre)<phone>\(.post)")
          | gsub("(?<b>^|[[:space:]]|\\()(cus|pi|ch)_[A-Za-z0-9_]+"; "\(.b)<stripe_id>");
        .parts = ([.parts[]? | .body = ((.body // "") | scrub)])
      ' 2>/dev/null); then
    echo "redact: WARN: phone/stripe body scrub failed at line $line_no — passing through un-phone/stripe-scrubbed" >&2
    redacted="$_before_pii"
  fi

  printf '%s\n' "$redacted"
done < "$INPUT" > "$OUTPUT"
