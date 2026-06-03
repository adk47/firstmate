#!/usr/bin/env bash
# Scrape 7 days of edge-gateway journal for sanitizer leak audit lines
# and (when the tool-ctx prereq is landed) support-tool call records.
#
# Output: $WORKDIR/audit.jsonl
# Each line: {"kind": "leak"|"tool_call", ...fields}

set -euo pipefail

: "${WORKDIR:?WORKDIR required}"
: "${CAROLINE_BOT_ADMIN_ID:?CAROLINE_BOT_ADMIN_ID required}"

OUTPUT="$WORKDIR/audit.jsonl"
: > "$OUTPUT"

journal_tmp="$WORKDIR/journal.tmp"

# Pull 7d of journal into a tmpfile in one shot. Fail loud — silent
# journalctl failures (auth/permissions/no-such-unit) used to leave $OUTPUT
# empty and the LLM had nothing to grade.
if ! journalctl -u openclaw-gateway-edge.service --since "7 days ago" --no-pager > "$journal_tmp"; then
  echo "fetch-audit: journalctl read failed" >&2
  exit 1
fi

# grep "no match" exits 1, which is a valid empty result (no leaks observed
# this week). Anything else from grep is unexpected. Use a function that
# tolerates rc=1 only and propagates real errors (rc>=2). The `|| rc=$?`
# pattern is required so set -e doesn't fire inside the function when
# grep returns 1.
grep_tolerant() {
  local rc=0
  grep "$@" || rc=$?
  [ "$rc" -le 1 ] && return 0
  return "$rc"
}

# 1. Leak audit lines (always). Emit a marker + a PII-scrubbed snippet, NOT the
# raw line: an intercom:email-leak line contains the leaked address, and the LLM
# reads audit.jsonl directly (the pre-LLM redaction only covers
# conversations.jsonl). The grader needs the count + type, not the leaked value.
SCRUB="$(dirname "$0")/redact-output.sh"
grep_tolerant -E 'intercom:tool-leak|intercom:email-leak' "$journal_tmp" \
  | while IFS= read -r line; do
      snippet=$(printf '%s' "$line" | "$SCRUB")
      if printf '%s' "$line" | grep -qF 'email-leak'; then marker="email-leak"; else marker="tool-leak"; fi
      jq -nc --arg snip "$snippet" --arg marker "$marker" \
        '{kind: "leak", marker: $marker, snippet: $snip}'
    done >> "$OUTPUT"

# 2. Support-tool calls (only if prereq landed). Both the grep filter and the
# jq filter assume the gateway emits JSON-shaped log lines containing both
# "tool":"..." and "conversation_id":"...". Pre-prereq, lines without
# conversation_id are skipped silently — the audit is honestly empty.
if [ "${CV_TOOL_CTX_CONVERSATION_ID:-unavailable}" = "available" ]; then
  grep_tolerant -E '"tool":"(profile_status|create_ticket|profile_lookup|credits_search|subscription_status)"' "$journal_tmp" \
    | grep_tolerant -F '"conversation_id"' \
    | while IFS= read -r line; do
        # Strip any leading log prefix (e.g. journald timestamp) so jq sees
        # the embedded JSON object only.
        json_part=$(printf '%s' "$line" | grep -oE '\{.*\}$' || true)
        [ -n "$json_part" ] || continue
        if printf '%s' "$json_part" | jq -e '.tool and .conversation_id' >/dev/null 2>&1; then
          # Allowlist args to safe categorical fields only. Every other arg is
          # free-text or an identifier (profile_lookup.query,
          # profile_status.name/profile_url/profile_id, create_ticket.summary/
          # customerProfileId/details, conversationSummary, ...) that would bypass
          # the transcript redaction path, so drop them all by default. The grader
          # (Dimension B) needs the tool + conversation_id join, plus
          # actionType/tier for ticket tier-checks per TOOLS.md.
          printf '%s' "$json_part" | jq -c '
            {kind: "tool_call", tool, conversation_id,
             args: ((.args // {}) | {actionType, tier} | with_entries(select(.value != null)))}'
        fi
      done >> "$OUTPUT"
fi

rm -f "$journal_tmp"

echo "fetch-audit: wrote $(wc -l < "$OUTPUT") audit records"
