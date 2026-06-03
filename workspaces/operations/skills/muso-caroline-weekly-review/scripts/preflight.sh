#!/usr/bin/env bash
# Preflight checks. Sourceable so successful exports are visible to caller.
# Exports on success:
#   CAROLINE_BOT_ADMIN_ID  — Caroline's Intercom admin id
#   WORKDIR                 — mktemp -d with chmod 700, cleanup trap installed
#   CV_TOOL_CTX_CONVERSATION_ID — "available" | "unavailable" (Dimension B gate)

set -euo pipefail

fail() { echo "preflight: $*" >&2; return 1; }

# 1. Required env
[ -n "${MUSOAI_INTERCOM_TOKEN:-}" ] || fail "MUSOAI_INTERCOM_TOKEN must be set"

# 2. Required tools
for tool in jq gh git curl journalctl realpath; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing required tool: $tool"
done

# 3. gh auth
gh auth status >/dev/null 2>&1 || fail "gh auth status failed"

# 4. Clean worktree (skip if not in a git repo — e.g. unit-test contexts)
if git rev-parse --git-dir >/dev/null 2>&1; then
  git diff --quiet || fail "worktree not clean (unstaged changes)"
  git diff --cached --quiet || fail "worktree not clean (staged changes)"
  if [ -n "$(git ls-files --others --exclude-standard)" ]; then
    fail "worktree not clean (untracked files present)"
  fi
fi

# 5. botAdminId from the edge gateway config. The intercom channel config is
# embedded in openclaw.json (channels.intercom.accounts.default), NOT a
# standalone plugins/intercom/config.json — that path does not exist on the
# server (confirmed on node-8 2026-06-01).
INTERCOM_CONFIG_JSON="${INTERCOM_CONFIG_JSON:-/root/.openclaw-edge/openclaw.json}"
[ -f "$INTERCOM_CONFIG_JSON" ] || fail "intercom config not found at $INTERCOM_CONFIG_JSON"
BOT_ADMIN_ID=$(jq -r '.channels.intercom.accounts.default.botAdminId // empty' "$INTERCOM_CONFIG_JSON")
[ -n "$BOT_ADMIN_ID" ] || fail "intercom config missing botAdminId"
export CAROLINE_BOT_ADMIN_ID="$BOT_ADMIN_ID"

# 6. Confirm admin exists via /admins
ADMINS=$(curl -sS \
  -H "Authorization: Bearer $MUSOAI_INTERCOM_TOKEN" \
  -H "Intercom-Version: 2.11" \
  -H "Accept: application/json" \
  "https://api.intercom.io/admins")
echo "$ADMINS" | jq -e ".admins[] | select(.id == \"$BOT_ADMIN_ID\")" >/dev/null \
  || fail "admin $BOT_ADMIN_ID not present in /admins"

# 7. Conversation-search reachability check. Probe the broad updated_at query
# (the exact shape fetch-conversations.sh uses) so a broken/forbidden search
# endpoint fails preflight instead of yielding an empty grading set. There is
# no longer an admin_assignee_id "assignee mode": that server-side filter
# silently dropped conversations Caroline handled but that were later
# reassigned to a human. fetch always does a broad fetch + author post-filter.
PROBE=$(curl -sS -w "\n%{http_code}" \
  -X POST \
  -H "Authorization: Bearer $MUSOAI_INTERCOM_TOKEN" \
  -H "Intercom-Version: 2.11" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d '{"query":{"field":"updated_at","operator":">","value":0},"pagination":{"per_page":1}}' \
  "https://api.intercom.io/conversations/search")
HTTP_CODE=$(printf '%s' "$PROBE" | tail -n1)
[ "$HTTP_CODE" = "200" ] || fail "conversations/search probe returned HTTP $HTTP_CODE"

# 8. Tool-ctx prereq probe
SUPPORT_TOOLS_INDEX="${SUPPORT_TOOLS_INDEX:-/opt/hydra/plugins/support-tools/src/index.ts}"
if [ -f "$SUPPORT_TOOLS_INDEX" ] && grep -q "ctx\.conversationId\|ctx\[.conversationId.\]" "$SUPPORT_TOOLS_INDEX"; then
  export CV_TOOL_CTX_CONVERSATION_ID="available"
else
  export CV_TOOL_CTX_CONVERSATION_ID="unavailable"
fi

# 9. WORKDIR — caller owns lifetime when sourced
umask 077
WORKDIR=$(mktemp -d -t "caroline-review-XXXXXX")
chmod 700 "$WORKDIR"
export WORKDIR
# Mechanical cleanup of WORKDIR (raw transcripts) on interrupt / kill / cron
# timeout. An INT/TERM trap set while SOURCED lives in the caller's shell and
# fires on signal — NOT on preflight's normal return — so downstream pipeline
# steps still see $WORKDIR, but a run cut off by its 1500s timeout or a SIGTERM
# no longer leaves PII in /tmp. When run as a subprocess we also clean on EXIT.
# Success-path teardown stays the caller's final `rm -rf "$WORKDIR"` because the
# LLM grading + Phase-3 validation run between fetch and teardown and need the
# data; a plain EXIT trap here would delete it mid-pipeline.
trap 'rm -rf "$WORKDIR"' INT TERM
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  trap 'rm -rf "$WORKDIR"' EXIT INT TERM
fi

# 10. Branch absent (only relevant when in repo)
if git rev-parse --git-dir >/dev/null 2>&1; then
  TODAY=$(date -u +%Y-%m-%d)
  BRANCH="auto/caroline-kb-review-$TODAY"
  if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    fail "branch $BRANCH already exists; aborting to avoid clobber"
  fi
fi

echo "preflight: ok (tool_ctx=$CV_TOOL_CTX_CONVERSATION_ID)"
