#!/usr/bin/env bash
# Scrub PII from a conversations.jsonl file before LLM grading: emails, customer
# last names, and (in transcript bodies) phone numbers + Stripe/payment IDs.
# Preserves customer_first_name for tone context. This is the file the LLM reads,
# so it must be clean here — redact-output.sh's phone/Stripe pass runs only on the
# final Slack/PR text, after the model has already seen the input.
#
# ALL scrubbing happens inside one jq program operating on the PARSED object's
# string values, so the output is ALWAYS valid JSON. An earlier sed-on-raw-line
# approach corrupted the JSON when a customer name/body contained a backslash (an
# invalid \-escape was injected); the two downstream jq passes then failed to
# parse the line, redact fell back to emitting the corrupted line, and the
# grader's `jq -s` choked on it and aborted the whole weekly run.
#
# Usage: redact.sh <input.jsonl> <output.jsonl>

set -euo pipefail

INPUT="${1:?input.jsonl required}"
OUTPUT="${2:?output.jsonl required}"

line_no=0
while IFS= read -r line; do
  line_no=$((line_no + 1))
  [ -n "$line" ] || continue   # never emit an empty line

  # One jq program does everything on parsed string fields, so the result is
  # guaranteed valid JSON. If the input line is not valid JSON (or the program
  # errors), DROP it with a warning — emitting it would either leak unscrubbed
  # PII or hand the grader a malformed line.
  if ! redacted=$(printf '%s' "$line" | jq -c '
        # Escape regex metacharacters so a name matches literally.
        def re_escape: gsub("(?<c>[.+*?^$(){}|\\[\\]\\\\])"; "\\\(.c)");
        # PII patterns shared with redact-output.sh (keep in sync; the
        # redact.bats phone/stripe cases guard against drift). Phone is
        # digit-fenced so it never fires inside a longer digit run.
        def scrub_pii:
          gsub("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"; "<email>")
          | gsub("(?<pre>^|[^0-9])((\\+?[0-9]{1,3}[ .-]?)?\\(?[0-9]{3}\\)?[ .-]?[0-9]{3}[ .-]?[0-9]{4})(?<post>[^0-9]|$)"; "\(.pre)<phone>\(.post)")
          | gsub("(?<b>^|[[:space:]]|\\()(cus|pi|ch)_[A-Za-z0-9_]+"; "\(.b)<stripe_id>");
        (.customer_first_name // "") as $first
        | (.customer_last_name // "") as $last
        | ($last[0:1]) as $li
        # Transcript bodies: PII scrub, then "First Last" -> "First L.", then a
        # bare surname (word-bounded, len>=3) -> "L.". Oniguruma \b is reliable
        # (unlike BSD sed), so no boundary-char juggling. .body defaults to "" so
        # a null/absent body can never crash a grader-composed (.body|test(...)).
        | .parts = [ .parts[]?
            | .body = ((.body // "")
                | scrub_pii
                | (if ($first | length) > 0 and ($last | length) > 0
                   then gsub(($first | re_escape) + " " + ($last | re_escape); $first + " " + $li + ".")
                   else . end)
                | (if ($last | length) >= 3
                   then gsub("\\b" + ($last | re_escape) + "\\b"; $li + ".")
                   else . end)) ]
        | (if (.customer_email // null) != null then .customer_email = (.customer_email | scrub_pii) else . end)
        | (if ($last | length) > 0 then .customer_last_name = ($li + ".") else . end)
      ' 2>/dev/null); then
    echo "redact: WARN: dropping line $line_no (malformed JSON or scrub error)" >&2
    continue
  fi
  printf '%s\n' "$redacted"
done < "$INPUT" > "$OUTPUT"
