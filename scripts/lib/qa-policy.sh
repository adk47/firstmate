#!/usr/bin/env bash
# qa-policy.sh — sourceable, fail-closed reader for policies/qa-approval-policy.json.
#
# WHY THIS EXISTS (the bug class it closes):
# Every call site used to spell the membership test inline as
#     jq -e '(.some_list // []) | index($r)' "$POLICY"
# which is false in THREE different situations that must not be equivalent:
#   1. the repo is genuinely not in the list      -> proceed
#   2. the key is missing / null / not an array   -> MUST fail closed
#   3. the file is unreadable or malformed JSON   -> MUST fail closed
# `jq -e` returns non-zero for all three, and `// []` actively converts (2) into
# (1). Reviews of PR #748 found this same shape independently in author_deny, in
# qa-review-status.sh's arming guard, and in qa-autoreview.yml's gate detection —
# so it is a class, not an instance, and it is centralised here rather than fixed
# three more times.
#
# Pure functions, no side effects at source time, nothing that trips `set -e` in
# the sourcing script (the edge-restart-gate.sh / epoch.sh doctrine).
#
# Usage:
#   source "$(dirname "$0")/lib/qa-policy.sh"
#   qa_policy_valid "$POLICY"        || die ... # readable + schema-sane
#   qa_policy_has "$POLICY" '.merge_gate_repos' "Muso-AI/hydra"
#     -> 0 member | 1 not a member | 2 UNREADABLE/MALFORMED (caller must refuse)

# qa_policy_valid <file> — 0 if the file parses AND every list-typed key that is
# present is actually an array. Absent keys are allowed here; callers that
# require a specific key assert it themselves (see qa_policy_has's exit 2).
#
# .identity.bot_logins is checked down to its ELEMENTS, unlike its siblings,
# because every wrong shape fails SILENTLY rather than raising: consumers feed
# it to `$bots | index($login)`, where `{}` / `[]` / `[123]` match nothing (so
# no review is ever recognised as the bot's) and a bare STRING degrades to a
# SUBSTRING test (so login "adk4" matches bot "adk47" — misidentification, not
# a no-op). Non-emptiness is deliberately NOT required here: a caller that
# cannot function without entries asserts that itself, and refusing an empty
# list in the shared validator would fail callers that never classify a bot.
qa_policy_valid() {
  local f="$1"
  [ -r "$f" ] || return 1
  jq -e '
    (type == "object")
    and ((has("merge_gate_repos")            | not) or (.merge_gate_repos            | type == "array"))
    and ((has("require_human_codeowner_repos")| not) or (.require_human_codeowner_repos| type == "array"))
    and ((has("author_deny")                 | not) or (.author_deny                 | type == "array"))
    and ((has("identity")                    | not) or (.identity                    | type == "object"))
    and (((.identity // {}) | has("app_repos") | not) or ((.identity.app_repos)       | type == "array"))
    and (((.identity // {}) | has("bot_logins") | not)
         or ((.identity.bot_logins) | type == "array" and all(.[]; type == "string" and length > 0)))
  ' "$f" >/dev/null 2>&1
}

# qa_policy_has <file> <jq-path-to-array> <value>
#   0 = value is in the array
#   1 = value is NOT in the array (array present and well-formed)
#   2 = cannot answer: unreadable file, malformed JSON, or the key is
#       missing/null/not-an-array. Callers MUST treat 2 as refuse, never as 1.
qa_policy_has() {
  local f="$1" path="$2" val="$3" out
  [ -r "$f" ] || return 2
  out="$(jq -r --arg v "$val" "
    ( $path ) as \$a
    | if (\$a | type) != \"array\" then \"__ERR__\"
      else ((\$a | index(\$v)) != null | tostring) end
  " "$f" 2>/dev/null)" || return 2
  case "$out" in
    true)  return 0 ;;
    false) return 1 ;;
    *)     return 2 ;;
  esac
}
