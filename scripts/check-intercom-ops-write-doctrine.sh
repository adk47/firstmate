#!/usr/bin/env bash
set -euo pipefail

# Mechanical backstop for the Intercom ops-write doctrine: the operations agent writes into
# an Intercom conversation ONLY through scripts/intercom-ops-write.sh, internal note by
# default, and a customer-facing reply only with an allowlisted human's explicit approval.
#
# Why it exists (2026-09-01): the ops agent resolved an escalated conversation by composing
# a raw `curl POST /conversations/<id>/reply` from memory. That day it chose message_type
# "note" (internal, correct). On 2026-08-31 the same hand-typed path chose "comment" under a
# human's admin id, self-approved as "god_mode", and customers saw "Nicholas Sollazzo"
# mid-thread. Whether a customer read what the agent wrote was one word in a payload the
# agent typed itself, guarded by prose.
#
# The runtime gate is scripts/intercom-ops-write.sh (allowlisted requester, note-by-default
# with a "Note to <audience>" header, explicit --customer-facing + --approved-by for a
# reply, leak refusal, pinned identity, log-before-write, part_type verified). THIS guard
# protects the surrounding doctrine: the ops SOUL rule that routes writes to the wrapper,
# the skill's own anchors, the wrapper's pins, the skill's registration on the operations
# agent, and the absence of any raw write recipe in the docs an agent copies curl from.
# Prose is not enforcement, so a silent removal of any of them fails CI.
#
# What it does NOT do: it cannot stop an agent composing a raw curl at runtime (the ops
# agent runs as root with exec unrestricted). It stops accident and drift in the tree.

ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

OPS_SOUL="${IOW_OPS_SOUL_FILE:-$ROOT/workspaces/operations/SOUL.md}"
SKILL="${IOW_SKILL_FILE:-$ROOT/skills-all/muso-intercom/SKILL.md}"
WRAPPER="${IOW_WRAPPER_FILE:-$ROOT/scripts/intercom-ops-write.sh}"
MAIN_CFG="${IOW_MAIN_CONFIG_FILE:-$ROOT/openclaw-main.json}"
LESSONS="${IOW_LESSONS_FILE:-$ROOT/docs/lessons/muso-domain.md}"
SANITIZER="${IOW_SANITIZER_FILE:-$ROOT/plugins/intercom/src/sanitize-tool-leak.ts}"
ROSTER="${IOW_ROSTER_FILE:-$ROOT/shared-reference/reference/slack-people.json}"
SCAN_ROOT="${IOW_SCAN_ROOT:-$ROOT}"

for f in "$OPS_SOUL" "$SKILL" "$WRAPPER" "$MAIN_CFG" "$LESSONS" "$SANITIZER" "$ROSTER"; do
  [ -f "$f" ] || {
    echo "Missing $f (run from repo root, or set the IOW_*_FILE overrides)." >&2
    exit 2
  }
done

fail=0

# require <file> <label> <fixed-substring> <why>
require() {
  if ! grep -qF -- "$3" "$1"; then
    echo "FAIL: $2 lost the anchor: \"$3\"" >&2
    echo "      why it is load-bearing: $4" >&2
    fail=1
  fi
}

# --- operations SOUL: the always-injected surface (TOOLS.md is rsync-excluded) ---------
require "$OPS_SOUL" "operations/SOUL.md" \
  "intercom-ops-write.sh" \
  "names the wrapper; without it the agent has a rule and no path, which is how a hand-typed curl comes back"
require "$OPS_SOUL" "operations/SOUL.md" \
  "internal note by default" \
  "the default shape; a resolution asked for in Slack is a note to the team, never a message to the customer"
require "$OPS_SOUL" "operations/SOUL.md" \
  "Note to" \
  "the header convention: an inbox reader must see at once that the part is internal and who asked for it"

# --- the skill: the surface the agent loads when it decides how to write --------------
require "$SKILL" "muso-intercom/SKILL.md" \
  "intercom-ops-write.sh" \
  "the skill must route every write to the wrapper, or the agent reconstructs the POST from memory"
require "$SKILL" "muso-intercom/SKILL.md" \
  "never a raw curl" \
  "the prohibition itself; reads stay raw curl, writes never are"

# --- the wrapper: the pins that make the doctrine mechanical ---------------------------
if ! head -1 "$WRAPPER" | grep -q '^#!/bin/bash -p$'; then
  echo "FAIL: intercom-ops-write.sh does not use an absolute interpreter in privileged mode (#!/bin/bash -p)." >&2
  echo "      why it is load-bearing: env-resolved bash lets a PATH shim own the process before any pinning runs," >&2
  echo "      and without -p bash sources \$BASH_ENV and imports exported functions before line 1." >&2
  fail=1
fi
if ! grep -q '^PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin$' "$WRAPPER"; then
  echo "FAIL: intercom-ops-write.sh does not replace PATH before running anything." >&2
  echo "      why it is load-bearing: a jq shim can rewrite the payload AFTER validation." >&2
  fail=1
fi
# PROVE THE EFFECTIVE VALUE, NOT THE PRESENCE OF A LINE (see check-agent-bridge-doctrine.sh):
# exactly one readonly TESTABLE=0, and no other assignment form anywhere in the file.
if ! grep -q '^readonly TESTABLE=0$' "$WRAPPER"; then
  echo "FAIL: intercom-ops-write.sh does not declare 'readonly TESTABLE=0'." >&2
  echo "      why it is load-bearing: a deployed copy must refuse every test override; a flipped or" >&2
  echo "      non-readonly literal lets a caller select a client that prints POSTED without posting." >&2
  fail=1
fi
_assigns="$(grep -cE '^[[:space:]]*(readonly[[:space:]]+)?TESTABLE=' "$WRAPPER" || true)"
if [ "$_assigns" != "1" ]; then
  echo "FAIL: intercom-ops-write.sh has $_assigns assignments to TESTABLE; exactly one is allowed." >&2
  echo "      why it is load-bearing: any later assignment re-enables the test backend on a deployed copy." >&2
  fail=1
fi
if ! grep -q '^readonly INTERCOM_ADMIN_ID="5763097"$' "$WRAPPER"; then
  echo "FAIL: intercom-ops-write.sh does not pin the posting identity as 'readonly INTERCOM_ADMIN_ID=\"5763097\"' (Caroline)." >&2
  echo "      why it is load-bearing: this is the id every agent-authored note and reply posts under; a" >&2
  echo "      variable here is the 2026-08-31 bug (customers saw a human's name mid-thread)." >&2
  fail=1
fi
if ! grep -q '^readonly API_BASE="https://api.intercom.io"$' "$WRAPPER"; then
  echo "FAIL: intercom-ops-write.sh does not pin 'readonly API_BASE=\"https://api.intercom.io\"'." >&2
  echo "      why it is load-bearing: a caller-selectable endpoint can print POSTED while nothing reaches Intercom." >&2
  fail=1
fi

# --- the leak-word list must match the outbound sanitizer's patterns, as a set ---------
# The wrapper refuses customer-facing bodies carrying what Caroline's outbound sanitizer
# redacts. The sanitizer is CODE: the `\b...\b` entries of PATTERNS in
# plugins/intercom/src/sanitize-tool-leak.ts are the only source of truth, and the wrapper
# carries a copy as SANITIZER_WORDS. Two copies with nothing comparing them drift silently:
# a pattern added to the plugin leaves the wrapper letting it through, a word only in the
# wrapper refuses replies the sanitizer would have sent. (The first draft compared against a
# prose sentence that listed bare "error"/"system"/"API", which the sanitizer never redacted.)
_wrapper_words="$(grep -E '^readonly SANITIZER_WORDS="[^"]+"$' "$WRAPPER" | sed -E 's/^readonly SANITIZER_WORDS="([^"]+)"$/\1/' | tr '|' '\n' | sort -u || true)"
_ts_words="$(grep -oE '^[[:space:]]*/\\b[^/]+\\b/gi?,' "$SANITIZER" | sed -E 's#^[[:space:]]*/\\b(.+)\\b/gi?,#\1#' | sort -u || true)"
if [ -z "$_wrapper_words" ]; then
  echo "FAIL: intercom-ops-write.sh has no single-line 'readonly SANITIZER_WORDS=\"a|b|c\"' constant." >&2
  echo "      why it is load-bearing: the leak refusal is only auditable if its word list is one greppable line." >&2
  fail=1
elif [ -z "$_ts_words" ]; then
  echo "FAIL: ${SANITIZER#"$ROOT"/} has no '/\\b...\\b/g' PATTERNS entries to compare against." >&2
  echo "      why it is load-bearing: that array is the source of the wrapper's leak-word list." >&2
  fail=1
elif [ "$_wrapper_words" != "$_ts_words" ]; then
  echo "FAIL: intercom-ops-write.sh SANITIZER_WORDS differs from the PATTERNS in ${SANITIZER#"$ROOT"/}." >&2
  echo "      only in wrapper: $(comm -23 <(printf '%s\n' "$_wrapper_words") <(printf '%s\n' "$_ts_words") | tr '\n' ' ')" >&2
  echo "      only in plugin:  $(comm -13 <(printf '%s\n' "$_wrapper_words") <(printf '%s\n' "$_ts_words") | tr '\n' ' ')" >&2
  echo "      why it is load-bearing: a pattern in one place and not the other is a leak the wrapper lets through or a reply it wrongly refuses." >&2
  fail=1
fi

# --- jq-backed checks fail CLOSED (check-agent-bridge-doctrine.sh, PR #877) -------------
# A gate that could not run has not passed; "could not check" and "passed" never share exit 0.
if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is not available, so the registration and roster checks could not run." >&2
  echo "      This gate fails CLOSED: an unverifiable registration is not a verified one." >&2
  echo "      Install jq on the runner (it is a declared dependency of this guard)." >&2
  fail=1
else
  # --- registration: the skill must still reach the operations agent ------------------
  if ! jq -e '.agents.list[] | select(.id=="operations") | .skills | index("muso-intercom")' "$MAIN_CFG" >/dev/null 2>&1; then
    echo "FAIL: openclaw-main.json no longer registers muso-intercom on the operations agent." >&2
    echo "      why it is load-bearing: the doctrine lives in that skill; an unregistered skill is a rule nobody loads." >&2
    fail=1
  fi

  # --- the write allowlist: wrapper == skill prose, and every entry a current human -----
  # The wrapper's allowlisted_name() case table and the skill's Write Access Control section
  # both name the humans whose Slack ask authorizes a write. Nothing else compares them, and
  # under "the refusal is the answer" a human added to one side only is refused by design.
  # Each arm is also pinned to shared-reference/reference/slack-people.json (kind human,
  # current, and the `short` name the note header prints), the roster gate precedent in
  # scripts/tests/muso-admin-api-slack-resolve.bats.
  _wrapper_arms="$(sed -n '/^allowlisted_name()/,/^}/p' "$WRAPPER" \
    | grep -oE '^[[:space:]]*U[A-Z0-9]+\)[[:space:]]*echo "[^"]+"' \
    | sed -E 's/^[[:space:]]*(U[A-Z0-9]+)\)[[:space:]]*echo "([^"]+)"/\1 \2/' || true)"
  _wrapper_uids="$(printf '%s\n' "$_wrapper_arms" | awk 'NF {print $1}' | sort -u)"
  _skill_uids="$(sed -n '/^## Write Access Control/,/^## /p' "$SKILL" | grep -oE '`U[A-Z0-9]{8,12}`' | tr -d '`' | sort -u || true)"
  if [ -z "$_wrapper_uids" ]; then
    echo "FAIL: intercom-ops-write.sh has no 'UID) echo \"Name\"' arms in allowlisted_name()." >&2
    echo "      why it is load-bearing: the write allowlist must be one greppable case table." >&2
    fail=1
  elif [ "$_wrapper_uids" != "$_skill_uids" ]; then
    echo "FAIL: the write allowlist in intercom-ops-write.sh differs from muso-intercom/SKILL.md 'Write Access Control'." >&2
    echo "      wrapper: $(printf '%s' "$_wrapper_uids" | tr '\n' ' ')" >&2
    echo "      skill:   $(printf '%s' "$_skill_uids" | tr '\n' ' ')" >&2
    echo "      why it is load-bearing: a human the skill authorizes but the wrapper refuses is refused by design; the two must move together." >&2
    fail=1
  fi
  while read -r _uid _name; do
    [ -n "$_uid" ] || continue
    if ! jq -e --arg u "$_uid" --arg n "$_name" '.[$u] | (.kind == "human" and .current == true and .short == $n)' "$ROSTER" >/dev/null 2>&1; then
      echo "FAIL: intercom-ops-write.sh allowlists $_uid as \"$_name\", but ${ROSTER#"$ROOT"/} does not list that id as a current human with short name \"$_name\"." >&2
      echo "      why it is load-bearing: the roster is the authoritative Slack id -> person map; a departed or misnamed person must not authorize Intercom writes." >&2
      fail=1
    fi
  done <<<"$_wrapper_arms"
fi

# --- no agent-copied doc may carry a raw Intercom write recipe -------------------------
# The 2026-08-31 and 2026-09-01 writes were both hand-typed POSTs. The docs an agent lifts
# curl from (skills-all/**/*.md, workspaces/**/*.md) must therefore never show one: no
# `message_type` field and no `/conversations/<id>/reply` endpoint. Reads (GET, search)
# stay documented as raw curl. Code under scripts/ is out of scope here: the Python cron
# writers are not agent-copied surfaces and check-intercom-reply-identity.sh covers them.
while IFS= read -r -d '' f; do
  hit="$(grep -nE 'message_type|conversations/[^ "'"'"']+/reply' "$f" 2>/dev/null | head -3 || true)"
  [ -z "$hit" ] && continue
  echo "FAIL: ${f#"$SCAN_ROOT"/}: documents a raw Intercom write." >&2
  echo "      ${hit//$'\n'/$'\n'      }" >&2
  echo "      Agents copy curl out of these docs. Describe the write in prose, never as a payload: a note or reply goes" >&2
  echo "      through scripts/intercom-ops-write.sh, a close through cs-stale-drain / muso-abuse-block, anything else is a human's inbox action." >&2
  fail=1
done < <(
  # workspaces/repos/ (agent clones) and workspaces/*/memory/ (agent notes) are untracked and
  # rsync-excluded (scripts/deploy.sh); on node-8 they hold docs nobody copies curl from.
  for d in skills-all workspaces; do
    [ -d "$SCAN_ROOT/$d" ] || continue
    find "$SCAN_ROOT/$d" -type f -name '*.md' -not -path '*/node_modules/*' -not -path '*/tests/*' \
      -not -path '*/repos/*' -not -path '*/memory/*' -print0 2>/dev/null
  done
)

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "Intercom ops-write doctrine check FAILED. The wrapper is the only write path; restore the anchor(s) above." >&2
  exit 1
fi

echo "OK: Intercom ops-write doctrine anchors present (ops SOUL, muso-intercom skill, wrapper pins, sanitizer list in sync with the plugin, allowlist in sync with the skill and roster, registration, no raw write recipes in agent docs)."
