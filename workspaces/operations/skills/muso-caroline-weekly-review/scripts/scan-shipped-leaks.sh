#!/usr/bin/env bash
# Source 2 (GUARD-MISSED): scan SHIPPED Caroline reply bodies for reasoning-leak
# signatures the outbound guard did NOT catch. A hit = a leak that reached a
# customer = highest-severity finding (a guard gap); the digest quotes the conv +
# matched marker so a new pattern can be added to the guard.
#
# SOURCE OF TRUTH: plugins/intercom/src/sanitize-reasoning-leak.ts (PR #421). The
# patterns below MIRROR its INTERNAL (19) + META_STRONG (6) arrays VERBATIM. We do
# NOT mirror META_WEAK (it only fires in combination in the guard; context-free it
# is too noisy). Apostrophes are written as [\x27\x{2019}] (Oniguruma) so no literal
# quote appears in this single-quoted jq program (see feedback_apostrophe_in_jq_heredoc).
# DRIFT WARNING: re-sync when that TS file's INTERNAL/META_STRONG arrays change.
# The scan-shipped-leaks.bats "drift sentinel" asserts this count matches the file.
# MIRRORED_MARKER_COUNT=25
set -euo pipefail

: "${WORKDIR:?WORKDIR required}"
: "${CAROLINE_BOT_ADMIN_ID:?CAROLINE_BOT_ADMIN_ID required}"

IN="${1:-$WORKDIR/conversations.redacted.jsonl}"
OUT="$WORKDIR/shipped-leaks.jsonl"
: > "$OUT"

[ -f "$IN" ] || { echo "scan-shipped-leaks: no redacted conversations at $IN; empty result"; exit 0; }

# Scan only Caroline-authored (admin + her id) parts -- never the customer .source
# opener (a customer quoting "SKILL.md" must not be a false guard-gap). Input is
# already PII-redacted, so the emitted sample is safe.
jq -c --arg admin "$CAROLINE_BOT_ADMIN_ID" '
  ([
    {n:"skill-md",                re:"\\bSKILL\\.md\\b",                                                                            f:""},
    {n:"do-not-use-words",        re:"\\bdo not use (?:the )?words?\\b",                                                            f:"i"},
    {n:"forbidden-words",         re:"\\bforbidden words?\\b",                                                                      f:"i"},
    {n:"report-back-to-customer", re:"\\breport back to the (?:customer|user)\\b",                                                  f:"i"},
    {n:"customer-facing-reply",   re:"\\bcustomer[- ]facing (?:reply|response|message)\\b",                                        f:"i"},
    {n:"ready-to-output",         re:"\\bready to output\\b",                                                                       f:"i"},
    {n:"write-final-reply",       re:"\\bwrite the final (?:reply|response|message)\\b",                                            f:"i"},
    {n:"the-final-reply",         re:"\\bthe final (?:reply|response)\\b",                                                          f:"i"},
    {n:"tone-calibration",        re:"\\btone calibration\\b",                                                                      f:"i"},
    {n:"structured-json",         re:"\\bstructured (?:json|response)\\b",                                                          f:"i"},
    {n:"json-submitted",          re:"(?:\\bsubmitted:\\s*true\\b|\\{\\s*submitted\\b)",                                            f:"i"},
    {n:"json-ticket-id",          re:"\\bticket_id\\b",                                                                             f:"i"},
    {n:"json-action-type",        re:"\\baction_type\\b",                                                                           f:"i"},
    {n:"sla-placeholder",         re:"<\\s*sla\\s*>",                                                                               f:"i"},
    {n:"lets-check-rules",        re:"\\blet[\\x27\\x{2019}]?s\\s+(?:double[- ]?)?check\\b[^.\\n]{0,40}\\b(?:rules|forbidden|words|if there)\\b", f:"i"},
    {n:"rules-on-how-to",         re:"\\bthe rules?\\s+on how to\\b",                                                               f:"i"},
    {n:"runtime-no-final-summary", re:"\\bno final summary was produced\\b",                                                      f:"i"},
    {n:"runtime-did-not-repeat",  re:"\\bI did not repeat any completed actions\\b",                                              f:"i"},
    {n:"runtime-tool-run-finished", re:"\\bthe tool run finished\\b",                                                             f:"i"},
    {n:"looking-at-history",      re:"\\blooking at the (?:previous|prior|earlier)\\s+(?:history|conversation|context|thread|messages?|exchange)\\b", f:"i"},
    {n:"in-pronoun-artist-name",  re:"\\bin (?:her|his|their)\\s+(?:artist|stage|legal|real|professional)\\s+name\\b",            f:"i"},
    {n:"ill-compose-toned-reply", re:"\\bi(?:[\\x27\\x{2019}]?ll|\\s+will)\\s+(?:send|craft|write|draft|compose|put together)\\s+(?:a|an|the)\\s+(?:(?:warm|friendly|brief|short|polite|professional|reassuring|quick|nice|casual|kind|gentle|personal)[,\\s/]+)+(?:response|reply|message|note|answer)\\b", f:"i"},
    {n:"ill-respond-in-pronoun",  re:"\\bi(?:[\\x27\\x{2019}]?ll|\\s+will)\\s+(?:respond|reply|write|send)\\b[^.!?\\n]*\\bin (?:her|his|their)\\b", f:"i"},
    {n:"since-pronoun-checking",  re:"\\bsince (?:she|he|they)(?:[\\x27\\x{2019}]s|[\\x27\\x{2019}]re| is| are)?\\s+(?:checking back|checking in|following up|reaching out|getting back|asking again)\\b", f:"i"},
    {n:"pronoun-previously-requested", re:"\\b(?:she|he|they)\\s+(?:had|has|have)\\s+(?:previously|earlier|already)\\s+(?:requested|asked|reached out|contacted|submitted|mentioned)\\b", f:"i"}
  ]) as $M
  | . as $c
  | .parts[]?
  | select(.author.type == "admin" and ((.author.id | tostring) == $admin))
  | (.body // "") as $b
  | $M[] as $m
  | select($b | test($m.re; $m.f))
  | {conv: ($c.id | tostring), marker: $m.n, sample: ($b | gsub("\\s+"; " ") | .[0:200])}
' "$IN" >> "$OUT" || true

echo "scan-shipped-leaks: wrote $(wc -l < "$OUT") shipped-leak hits"
