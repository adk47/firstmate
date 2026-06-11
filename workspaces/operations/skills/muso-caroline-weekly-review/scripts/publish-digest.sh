#!/usr/bin/env bash
set -euo pipefail

# publish-digest.sh — the ENTIRE Phase-3 pipeline in one deterministic call.
# ===========================================================================
# Usage:
#   publish-digest.sh <digest.json> <conversations.jsonl> [audit.jsonl]
#
# Pipeline:
#   1. validate-digest.sh   contract + anti-hallucination + theme recompute
#   2. redact-json.sh       PII re-scrub of every digest string
#   3. render-digest.py --text | redact-output.sh | linkify-convs.sh |
#      assert-digest-contract.sh        -> the plain-text fallback digest
#   4. render-digest.py --blocks        -> the Block Kit payload
#   5. post-digest.sh                   -> chat.postMessage as the Ops bot
#
# stdout is ALWAYS the final assistant message for the cron announce delivery:
#   - post succeeded -> a one-line confirmation (delivery heartbeat; announce
#     posting it to the channel doubles as proof the cron ran)
#   - post FAILED    -> a loud alert line + the full plain-text fallback, so
#     announce still delivers the digest content (fail-loud, never silent)
#
# Exit codes:
#   0  digest published (or fallback text emitted after a post failure —
#      a Slack hiccup must NOT abort the run; cf. the 2026-06-08 finalLen=0
#      incident where a trailing tool error suppressed the whole delivery)
#   1  validation / redaction / render / contract failure — nothing emitted;
#      fix digest.json and re-run (the documented fix-and-retry loop)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

DIGEST="${1:?usage: publish-digest.sh <digest.json> <conversations.jsonl> [audit.jsonl]}"
CONVS="${2:?usage: publish-digest.sh <digest.json> <conversations.jsonl> [audit.jsonl]}"
AUDIT="${3:-}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

# 1+2. Gate, then scrub. A non-zero exit here propagates (set -e): the digest
# is malformed and the agent must fix digest.json — never publish around it.
"$SCRIPT_DIR/validate-digest.sh" "$DIGEST" "$CONVS" ${AUDIT:+"$AUDIT"} > "$tmp/digest.valid.json"
"$SCRIPT_DIR/redact-json.sh" "$tmp/digest.valid.json" > "$tmp/digest.redacted.json"

# 3. Plain-text fallback through the LEGACY gates (belt and braces: the
# renderer computes the header, assert-digest-contract.sh proves it).
fallback="$("$SCRIPT_DIR/render-digest.py" --text < "$tmp/digest.redacted.json" \
  | "$SCRIPT_DIR/redact-output.sh" \
  | "$SCRIPT_DIR/linkify-convs.sh" \
  | "$SCRIPT_DIR/assert-digest-contract.sh")"

# 4. Block Kit payload (reads CAROLINE_DIGEST_CHANNEL, default #cs_chats).
"$SCRIPT_DIR/render-digest.py" --blocks < "$tmp/digest.redacted.json" > "$tmp/payload.json"

kind="$(jq -r '.kind' "$tmp/digest.valid.json")"
channel="$(jq -r '.channel' "$tmp/payload.json")"

# 5. Post. The failure branch is INSIDE the if so a Slack error can never be
# the run's trailing tool error — the fallback text still goes out via announce.
if ts="$("$SCRIPT_DIR/post-digest.sh" "$tmp/payload.json" 2> "$tmp/post.err")"; then
  printf '✅ Caroline %s digest posted to <#%s> as Block Kit (ts %s).\n' "$kind" "$channel" "$ts"
else
  reason="$(head -c 200 "$tmp/post.err" | tr '\n' ' ')"
  printf '🔴 Block Kit post to <#%s> FAILED (%s). Plain-text fallback:\n\n%s\n' \
    "$channel" "${reason:-unknown}" "$fallback"
fi
