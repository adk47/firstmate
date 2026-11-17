#!/usr/bin/env bats
# policies/outbound-copy-rubric.md "The neutral refusal": the rubric admits ONE message in its own words, the same way
# "The document ask" does. The signed review round can only approve a body the rubric admits, so the rubric must carry
# these bytes exactly, and a message that drifts from them must get nothing from the section.
#
# The bytes are the ones approved by firstmate and given GO by the reviewer 2026-11-16T21:11Z
# (template sha256 493f5255abc66d73c4693e0bd6953dd4a41c6bde578a62e700c7a00e93fa0fcc). A reword needs a new approval,
# so this suite pins the sha as well as the text: changing the copy means changing this file on purpose.
#
# Read-only: it reads the rubric and the gate's own lint, and writes nothing.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
RUBRIC="$HYDRA_REPO/policies/outbound-copy-rubric.md"

NEUTRAL_REFUSAL='Thanks for {document} for your {role} credit on {title} by {artist}. We couldn'"'"'t confirm the credit from what you sent. To verify it, reply with one of these: a split sheet or agreement signed by the artist or label, a PRO registration that lists you in your role, a royalty statement that names the track, an invoice, or a letter from the label. Your request is still open.'
GO_SHA256='493f5255abc66d73c4693e0bd6953dd4a41c6bde578a62e700c7a00e93fa0fcc'

# section <title>: the text of one "## <title>" section of the rubric, up to the next "## " heading
section() {
  awk -v want="## $1" '$0 == want {on = 1; next} on && /^## / {exit} on {print}' "$RUBRIC"
}

# admitted_lines: every message the section admits whole - its indented (code block) lines, indentation removed
admitted_lines() {
  section "The neutral refusal" | sed -n 's/^    \([^ ].*\)$/\1/p'
}

# admits <message>: the section admits this exact message (byte equality with an admitted line; nothing is normalised)
admits() {
  local line
  while IFS= read -r line; do
    [ "$line" = "$1" ] && return 0
  done < <(admitted_lines)
  return 1
}

# rubric_has <text>: the text is in the rubric anywhere, whatever the line wrapping (the document-ask suite's helper)
rubric_has() {
  python3 - "$RUBRIC" "$1" <<'PYEOF'
import pathlib, sys
flat = lambda s: " ".join(s.split())
sys.exit(0 if flat(sys.argv[2]) in flat(pathlib.Path(sys.argv[1]).read_text()) else 1)
PYEOF
}

@test "neutral refusal: the copy under test is the reviewer's GO'd bytes" {
  [ "$(printf '%s' "$NEUTRAL_REFUSAL" | sha256sum | cut -d' ' -f1)" = "$GO_SHA256" ]
}

@test "neutral refusal: the rubric has its own section, after the document ask and before the stages" {
  run -0 grep -n -x -e '## The document ask' -e '## The neutral refusal' -e '## What each stage must do' "$RUBRIC"
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[0]}" == *":## The document ask" ]]
  [[ "${lines[1]}" == *":## The neutral refusal" ]]
  [[ "${lines[2]}" == *":## What each stage must do" ]]
}

@test "neutral refusal: the rubric carries the exact bytes on one line, and the section admits them" {
  run -0 grep -c -x -F "    $NEUTRAL_REFUSAL" "$RUBRIC"
  [ "$output" = "1" ]
  admits "$NEUTRAL_REFUSAL"
}

@test "neutral refusal: the section admits that one message and no other whole message" {
  run -0 admitted_lines
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "$NEUTRAL_REFUSAL" ]
}

@test "neutral refusal: the four parts, in order, are the whole message" {
  s="$(section "The neutral refusal")"
  opening='Thanks for {document} for your {role} credit on {title} by {artist}.'
  statement="We couldn't confirm the credit from what you sent."
  need='To verify it, reply with one of these: a split sheet or agreement signed by the artist or label, a PRO registration that lists you in your role, a royalty statement that names the track, an invoice, or a letter from the label.'
  closing='Your request is still open.'
  [ "$opening $statement $need $closing" = "$NEUTRAL_REFUSAL" ]
  flat="$(printf '%s' "$s" | tr -s ' \n' '  ')"
  [[ "$flat" == *'1. The opening: "'"$opening"'"'* ]]
  [[ "$flat" == *'2. The statement: "'"$statement"'"'* ]]
  [[ "$flat" == *'3. The need line: "'"$need"'"'* ]]
  [[ "$flat" == *'4. The closing: "'"$closing"'"'* ]]
  [[ "$flat" == *"The four parts are the whole message: no greeting, no sign-off and no subject."* ]]
  [[ "$flat" == *"The words in braces are the only slots."* ]]
}

@test "neutral refusal: a message that differs from the bytes is not admitted by the section, and is in no other part of the rubric" {
  T="$NEUTRAL_REFUSAL"
  stmt="We couldn't confirm the credit from what you sent. "
  cc="couldn't confirm"
  cv="couldn't verify"
  drifted=(
    "Hi {first name}, $T"                                                       # a greeting
    "$T Thank you, Caroline, Muso Support"                                      # a sign-off
    "${T% Your request is still open.}"                                         # the closing left out
    "${T/"$stmt"/}"                                                             # the statement left out
    "${T/"$cc"/could not confirm}"                                              # one contraction undone
    "${T/"$cc"/"$cv"}"                                                          # one word changed
    "${T/an invoice, or a letter/an invoice or a letter}"                       # one comma removed
    "${T/still open./still open, and nothing is removed.}"                      # the document ask's closing borrowed
    "${T/or a letter from the label./a letter from the label, or a screenshot of your dashboard.}"  # a sixth document
    "${T/"$stmt"/Your credit was denied for now. $stmt}"                        # a denial added
    "${T/still open./still open, and we will check it within 7 days.}"          # a promise
    "${T/Thanks for/thanks for}"                                                # case changed
    "$T "                                                                       # one trailing space
  )
  for d in "${drifted[@]}"; do
    [ "$d" != "$T" ] || { echo "the drift case did not change the message: $d"; false; }
    if admits "$d"; then echo "admitted a drifted message: $d"; false; fi
  done
  # and none of them is quoted anywhere in the rubric, whatever the wrapping (a cut-down message is part of the
  # admitted one and is skipped here; the section admits it only whole, which the loop above holds)
  for d in "${drifted[@]:0:12}"; do
    [[ "$T" == *"$d"* ]] && continue
    if rubric_has "$d"; then echo "the rubric quotes a drifted message: $d"; false; fi
  done
}

@test "neutral refusal: the document ask's words do not stand in for it, and its words do not stand in for the document ask" {
  # the document ask's opening with this message's need line and closing
  mixed="Hi {first name}, thanks for {document} for your {role} credit on {title} by {artist}. We have it on file, but on its own it isn't something we can check against an outside source. ${NEUTRAL_REFUSAL#*from what you sent. }"
  if admits "$mixed"; then false; fi
  run ! rubric_has "$mixed"
  # the neutral refusal's statement is in no section but its own
  run -0 section "The document ask"
  [[ "$output" != *"We couldn't confirm the credit"* ]]
  run -0 section "The two classes"
  [[ "$output" != *"We couldn't confirm the credit"* ]]
  s="$(section "The neutral refusal" | tr -s ' \n' '  ')"
  [[ "$s" == *"They are different messages for different populations, and neither stands in for the other"* ]]
  [[ "$s" == *"is built from neither and gets nothing from either section."* ]]
}

@test "neutral refusal: the section names its population and loosens no rule for any other message" {
  s="$(section "The neutral refusal" | tr -s ' \n' '  ')"
  [[ "$s" == *"This section admits that one message in its own words. It loosens no rule for any other message."* ]]
  [[ "$s" == *"Who it is for: an open request with a document on file that was read and does not confirm the claim."* ]]
  [[ "$s" == *"It is not for a request with no document on file"* ]]
  [[ "$s" == *"and not for a request already decided"* ]]
  [[ "$s" == *"A message that has some of these words and is not built from all four parts gets nothing from this section"* ]]
  # the document ask still carries the same sentence for itself
  d="$(section "The document ask" | tr -s ' \n' '  ')"
  [[ "$d" == *"This section admits that one message in its own words. It loosens no rule for any other message."* ]]
}

@test "neutral refusal: no address, no link and no code in the section" {
  run -0 section "The neutral refusal"
  [[ "$output" != *"@"* ]]
  [[ "$output" != *"http"* ]]
  [[ "$output" != *"{code}"* ]]
}

@test "neutral refusal: a rendered body passes the gate's own lint at the ask stage" {
  body="$NEUTRAL_REFUSAL"
  body="${body/\{document\}/the PDF you sent on October 18}"
  body="${body/\{role\}/Producer}"
  body="${body/\{title\}/\"Midnight Drive\"}"
  body="${body/\{artist\}/Lena Hart}"
  [ "$(printf '%s' "$body" | sha256sum | cut -d' ' -f1)" = "8c0d8eaac07839cabe9cd937bfcb7fc28af3f5502cf062c7ff74f13d51747386" ]
  run -0 python3 - "$HYDRA_REPO/scripts" "$body" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from outbound_copy import gate
print(repr(gate.lint("", sys.argv[2], "ask", ["Producer", '"Midnight Drive"', "Lena Hart"])))
print(repr(gate.lint("", sys.argv[2], "ask")))
PYEOF
  [ "${lines[0]}" = "''" ]
  [ "${lines[1]}" = "''" ]
}
