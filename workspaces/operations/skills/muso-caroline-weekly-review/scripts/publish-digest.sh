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
#   4. render-digest.py --blocks-main   -> the lean glance payload
#      render-digest.py --blocks-thread -> the detail payload
#   5. post-digest.sh main              -> chat.postMessage as the Ops bot
#      post-digest.sh thread <main ts>  -> detail posted as a THREAD reply
#      (skipped when the thread has no content beyond its lead line; a
#      thread-post failure is appended LOUDLY to the heartbeat but does NOT
#      trigger the plain-text fallback — the glance was delivered)
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

# 4. Block Kit payloads (read CAROLINE_DIGEST_CHANNEL, default #cs_chats).
"$SCRIPT_DIR/render-digest.py" --blocks-main < "$tmp/digest.redacted.json" > "$tmp/main.json"
"$SCRIPT_DIR/render-digest.py" --blocks-thread < "$tmp/digest.redacted.json" > "$tmp/thread.json"

kind="$(jq -r '.kind' "$tmp/digest.valid.json")"
channel="$(jq -r '.channel' "$tmp/main.json")"

# 5. Post main, then the detail thread under it. Failure branches are INSIDE
# the ifs so a Slack error can never be the run's trailing tool error — the
# fallback text still goes out via announce when the MAIN post fails.
if ts="$("$SCRIPT_DIR/post-digest.sh" "$tmp/main.json" 2> "$tmp/post.err")"; then
  msg="$(printf '✅ Caroline %s digest posted to <#%s> as Block Kit (ts %s).' "$kind" "$channel" "$ts")"
  # Thread only when it carries content beyond its lead context line.
  if jq -e '.blocks | length > 1' "$tmp/thread.json" >/dev/null; then
    if "$SCRIPT_DIR/post-digest.sh" "$tmp/thread.json" "$ts" > /dev/null 2> "$tmp/thread.err"; then
      msg="$msg Detail thread attached."
    else
      msg="$msg ⚠️ detail thread post FAILED ($(head -c 160 "$tmp/thread.err" | tr '\n' ' ')) - main glance delivered, details only in this fallback channel."
    fi
  fi
  printf '%s\n' "$msg"
else
  reason="$(head -c 200 "$tmp/post.err" | tr '\n' ' ')"
  printf '🔴 Block Kit post to <#%s> FAILED (%s). Plain-text fallback:\n\n%s\n' \
    "$channel" "${reason:-unknown}" "$fallback"
fi
