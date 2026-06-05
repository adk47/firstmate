#!/usr/bin/env bash
# Scrape a rolling window (default 30h) of edge-gateway journal for sanitizer leak
# audit lines and (when the tool-ctx prereq is landed) support-tool call records.
#
# Output: $WORKDIR/audit.jsonl
# Each line: {"kind": "leak"|"tool_call", ...fields}

set -euo pipefail

: "${WORKDIR:?WORKDIR required}"
: "${CAROLINE_BOT_ADMIN_ID:?CAROLINE_BOT_ADMIN_ID required}"

OUTPUT="$WORKDIR/audit.jsonl"
: > "$OUTPUT"

journal_tmp="$WORKDIR/journal.tmp"

# Pull the window of journal into a tmpfile in one shot. Fail loud — silent
# journalctl failures (auth/permissions/no-such-unit) used to leave $OUTPUT
# empty and the LLM had nothing to grade.
#
# The window MUST match fetch-conversations.sh (same CAROLINE_WINDOW_HOURS knob,
# same 30h default): leak markers carry no conversation_id and no timestamp (see
# the {kind,marker,snippet} emit below), so a leak from N days ago has no field to
# dedup on. A fixed 7d journal window would therefore re-surface the same leak as a
# fresh P0 on every daily run for up to a week. Windowing the journal in lockstep
# with the conversation fetch is the only available fix.
# Source is resolved in preflight (CAROLINE_REASONING_LEAK_SOURCE). The journalctl
# branch stays the default and is byte-identical to the prior behavior; syslog/none
# are degraded fallbacks so the run still produces a (possibly empty) audit the
# digest can flag, rather than hard-failing when the journal is unreadable.
case "${CAROLINE_REASONING_LEAK_SOURCE:-journalctl}" in
  syslog)
    # Degraded: syslog has no --since window, so this is best-effort over whatever
    # the file retains (the digest must say "partial window"). Empty = valid empty.
    grep -aE 'openclaw-gateway-edge|intercom:' "${CAROLINE_SYSLOG_PATH:-/var/log/syslog}" > "$journal_tmp" 2>/dev/null || : > "$journal_tmp"
    ;;
  none)
    : > "$journal_tmp"   # no readable source; audit is honestly empty (digest says so)
    ;;
  *)
    if ! journalctl -u openclaw-gateway-edge.service --since "${CAROLINE_WINDOW_HOURS:-30} hours ago" --no-pager > "$journal_tmp"; then
      echo "fetch-audit: journalctl read failed" >&2
      exit 1
    fi
    ;;
esac

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

# 1b. Reasoning-leak guard audit lines (source 1, PR #421). Two shapes from
# channel.ts, both at log.error level:
#   [intercom:reasoning-leak] [<tag>] ESCALATED conv=<id> reason=<r> markers=<json> sample=<json>
#   [intercom:reasoning-leak] [<tag>] conv=<id> action=stripped markers=<json> sample=<json>
# ESCALATED is a bareword (no action= prefix); stripped uses action=stripped. Field
# order is conv, (reason on escalate only), markers, sample; sample is always the
# last field and JSON-stringified. The `|| true` on each field grep is REQUIRED:
# a stripped line has no reason=, so the grep no-matches and (under set -euo
# pipefail) the assignment would otherwise abort the whole run. Scrub the sample
# (it can carry the PII the guard suppressed). Validate the markers JSON before
# --argjson so a malformed token cannot abort the run either.
grep_tolerant -E 'intercom:reasoning-leak' "$journal_tmp" \
  | while IFS= read -r line; do
      conv=$(printf '%s' "$line" | grep -oE 'conv=[0-9]+' | head -1 | cut -d= -f2 || true)
      reason=$(printf '%s' "$line" | grep -oE 'reason=[a-z-]+' | head -1 | cut -d= -f2 || true)
      markers=$(printf '%s' "$line" | grep -oE 'markers=\[[^]]*\]' | head -1 | sed 's/^markers=//' || true)
      printf '%s' "$markers" | jq -e . >/dev/null 2>&1 || markers='[]'
      sample_raw=$(printf '%s' "$line" | sed -n 's/.* sample=\(".*"\)$/\1/p')
      sample=$(printf '%s' "$sample_raw" | jq -r '. // ""' 2>/dev/null | "$SCRUB")
      if printf '%s' "$line" | grep -qE '(^| )ESCALATED( |$)'; then action="escalated"; else action="stripped"; fi
      jq -nc --arg action "$action" --arg conv "$conv" --arg reason "$reason" \
             --argjson markers "$markers" --arg sample "$sample" \
        '{kind: "reasoning_leak", action: $action, conv: $conv, reason: $reason, markers: $markers, sample: $sample}'
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
