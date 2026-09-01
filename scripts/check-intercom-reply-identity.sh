#!/usr/bin/env bash
set -euo pipefail

# Mechanical backstop for the Intercom reply-identity doctrine.
#
# 2026-08-31: customers saw escalation follow-ups signed "Nicholas Sollazzo" mid-thread
# instead of Caroline. Caroline's own replies were fine (the plugin posts with
# account.botAdminId). The operations agent, resolving an escalated conversation, composed
# a raw admin-API call and picked Nick's admin id (10206197) out of the admin table in
# docs/lessons/muso-domain.md -- a table written for READING conversations, which reads as
# a menu of posting identities if nothing says otherwise.
#
# The rule: an agent-authored, customer-facing reply always posts as Caroline (5763097). A
# human's Slack authorization authorizes the WRITE; it never changes the posting IDENTITY.
#
# Prose != enforcement, so this guard fails CI if (a) any load-bearing anchor of that
# doctrine is silently removed, or (b) an agent-callable script -- or a doc an agent
# copies curl snippets out of -- binds an Intercom identity field to a literal that is
# not Caroline's id.
#
# What it does NOT do, stated up front so nobody reads more assurance into a green run
# than it earns: it cannot stop an agent composing a raw curl at runtime, cannot follow a
# value that reaches the field through a variable, and cannot stop someone overriding
# INTERCOM_ADMIN_ID in the environment of one of our own writers. Those are the doctrine
# anchors' job. This gate stops accident and drift in the tree.

ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# The ONE id an agent may post as. Detection below is an allowlist against this value,
# so there is deliberately no table of forbidden human ids to keep in sync -- a new
# teammate's admin id is refused on the day they are created, without an edit here.
CAROLINE_ADMIN_ID="5763097"

SKILL="${INTERCOM_SKILL_FILE:-$ROOT/skills-all/muso-intercom/SKILL.md}"
OPS_SOUL="${OPS_SOUL_FILE:-$ROOT/workspaces/operations/SOUL.md}"
LESSONS="${MUSO_LESSONS_FILE:-$ROOT/docs/lessons/muso-domain.md}"

for f in "$SKILL" "$OPS_SOUL" "$LESSONS"; do
  [ -f "$f" ] || { echo "Missing $f (run from repo root, or set INTERCOM_SKILL_FILE / OPS_SOUL_FILE / MUSO_LESSONS_FILE)." >&2; exit 2; }
done

fail=0

# require <file> <label> <fixed-substring>
# Reports every missing anchor in one pass rather than exiting on the first.
require() {
  local file="$1" label="$2" pat="$3"
  if ! grep -qF -- "$pat" "$file" 2>/dev/null; then
    echo "FAIL: ${file#"$ROOT"/}: $label" >&2
    echo "      expected to still contain: \"$pat\"" >&2
    fail=1
  fi
}

# --- muso-intercom SKILL.md: the rule itself, on the surface agents load --------
require "$SKILL" "the Reply Identity section heading" \
  "Reply Identity"
require "$SKILL" "Caroline's admin id as the posting identity" \
  "$CAROLINE_ADMIN_ID"
require "$SKILL" "the authorization-is-not-identity distinction" \
  "under a human admin id"

# --- operations SOUL.md: the always-injected bootstrap surface ------------------
# The ops agent is the one that got this wrong, and it got it wrong while composing a
# raw API call -- i.e. without necessarily loading the skill above. SOUL.md is injected
# every turn, so the rule has to be here too, not only in the on-demand skill.
#
# It is anchored on SOUL.md and NOT on TOOLS.md, which is where PR #900 first put it.
# `deploy.sh` rsync-EXCLUDES `workspaces/*/TOOLS.md` (seed-but-runtime-owned, same class
# as MEMORY.md/IDENTITY.md/HEARTBEAT.md), so that edit merged green, deployed green, and
# never reached the agent -- while this gate went green asserting the repo copy. A gate
# anchored on a surface the deploy does not ship proves the anchor exists where nothing
# reads it. Before anchoring on any workspace file, check deploy.sh for an exclude.
require "$OPS_SOUL" "the reply-identity rule on the always-injected ops surface" \
  "$CAROLINE_ADMIN_ID"

# --- docs/lessons/muso-domain.md: the admin table that caused the misread -------
require "$LESSONS" "the 'this table is not a menu of posting identities' qualifier" \
  "not a menu of posting identities"

# --- gateway config: the id EVERY Caroline reply is actually posted with --------
# The plugin posts with `account.botAdminId` (channel.ts, escalation-action.ts), so this
# config value -- not any string in a script -- is what authors every one of Caroline's
# replies. A one-character edit here misattributes the whole channel while every scan
# above stays green, which is the widest version of the 2026-08-31 bug. Checked for every
# configured account, not just `default`.
if [ -n "${INTERCOM_CONFIG_FILES:-}" ]; then
  read -r -a CONFIG_FILES <<< "$INTERCOM_CONFIG_FILES"
else
  CONFIG_FILES=("$ROOT/openclaw-edge.json" "$ROOT/openclaw-main.json")
fi

if command -v jq >/dev/null 2>&1; then
  for cfg in "${CONFIG_FILES[@]}"; do
    [ -f "$cfg" ] || continue
    # `.accounts // {}` so a config with no intercom channel is skipped, not failed.
    while IFS=$'\t' read -r acct id; do
      [ -n "$acct" ] || continue
      if [ "$id" != "$CAROLINE_ADMIN_ID" ]; then
        echo "FAIL: ${cfg#"$ROOT"/}: channels.intercom.accounts.$acct.botAdminId is \"$id\", not Caroline ($CAROLINE_ADMIN_ID)." >&2
        echo "      This is the id the plugin posts EVERY Caroline reply with." >&2
        fail=1
      fi
    done < <(jq -r '(.channels.intercom.accounts // {}) | to_entries[] | select(.value.botAdminId != null) | "\(.key)\t\(.value.botAdminId)"' "$cfg" 2>/dev/null)
  done
else
  echo "WARN: jq not found — skipped the gateway-config botAdminId check." >&2
fi

# --- No agent-callable surface may pair a human admin id with an Intercom write -
# Scans the surfaces an agent invokes OR copies from: shell/python helpers AND the
# markdown skills and workspace docs the agent lifts curl snippets out of (the
# 2026-08-31 bug started as a misread DOC, so .md is in scope, not just code).
#
# SCOPE (per file): mentions Intercom at all. Cheap filter, nothing more.
IN_SCOPE_RE='api\.intercom\.io|INTERCOM_ADMIN_ID|admin_id'
#
# DETECTION IS AN ALLOWLIST, NOT A BLOCKLIST. Where an Intercom identity field is bound
# to a LITERAL, that literal must be Caroline's id. Anything else fails -- the three
# known human ids, a new teammate's id nobody added to a table, a typo, or a value we
# cannot statically read.
#
# Enumerating forbidden ids was the weaker design and lost an arms race twice on PR #900:
# a same-line matcher was bypassed by splitting the payload across lines, and a
# literal-digit matcher is bypassed by any encoding that decodes at runtime
# (`"10..."`). Requiring the RIGHT value ends that class of evasion: an id the
# checker cannot read as Caroline's is refused whatever it is encoded as, so there is no
# escape syntax left to enumerate.
#
# Matching runs on the file with ALL whitespace collapsed to single spaces, so a payload
# split across lines reads the same as one written inline.
#
# The separator class is NON-alphanumeric and bounded, which is what keeps prose green:
# it binds the field to a value across quotes, colons, braces, `=` and spaces, never
# across intervening words. The doctrine text naming the forbidden ids in order to FORBID
# them ("under a human admin id (Nick `10206197` ...)") does not trip it -- prose has
# words in between, and the token there is "admin id", not `admin_id`.
#
# Case-SENSITIVE on purpose: the payload field is `admin_id`, the env knob is
# `INTERCOM_ADMIN_ID`. Matching case-insensitively would also hit read-side names like
# `EXCLUDE_ADMIN_IDS = ["5465657"]` -- the complaint-analysis exclusion that
# docs/lessons/muso-domain.md explicitly asks for, which must stay green.
#
# A digit run must be >= 6 to count as an id literal, so ordinary prose ("admin_id, see
# note 2") is not read as an identity binding.
#
# Known limitation, stated plainly rather than papered over: a value reaching the field
# through a VARIABLE (`X = "10206197"` ... later ... `{"admin_id": X}`) is out of a
# grep's reach. Variables are the overwhelmingly common legitimate form here
# (`os.environ.get`, `$ADMIN`, `BOT_ADMIN_ID`), so they are allowed through and the
# doctrine anchors above are what cover them. This gate stops accident and drift; it is
# not an adversarial control.
LITERAL_RE="(admin_id|INTERCOM_ADMIN_ID)[^A-Za-z0-9]{0,40}[0-9]{6,}"
#
# Escapes are refused FILE-WIDE in an Intercom-writing file, not merely next to an
# identity token. Anchoring on `admin_id` cannot catch an escaped KEY (`"admin_id"`,
# which JavaScript decodes before sending) for the obvious reason that the token is not
# there to anchor on. Chasing spellings is unbounded -- `admin_id`, `admin_id`,
# `"adm" + "in_id"` -- so the rule is instead: in a file that talks to Intercom, an
# identity binding must be written plainly. No in-scope file uses an escape today, so
# this bans a construct we do not use rather than breaking one we rely on, and the
# failure message says how to comply.
ESCAPE_RE='\\+[uUxX][0-9a-fA-F]{1,8}'

SCAN_ROOT="${INTERCOM_SCAN_ROOT:-$ROOT}"

scan_targets() {
  local d
  for d in scripts skills-all workspaces; do
    [ -d "$SCAN_ROOT/$d" ] || continue
    find "$SCAN_ROOT/$d" \
      -type f \( -name '*.sh' -o -name '*.py' -o -name '*.md' \
                 -o -name '*.js' -o -name '*.mjs' -o -name '*.cjs' -o -name '*.ts' \) \
      -not -path '*/node_modules/*' \
      -not -path '*/tests/*' \
      -not -name 'check-intercom-reply-identity.sh' \
      -print0 2>/dev/null
  done
}

report() {
  echo "FAIL: ${1#"$SCAN_ROOT"/}: $2" >&2
  echo "      ${3//$'\n'/$'\n'      }" >&2
  echo "      An Intercom identity field bound to a literal must be Caroline ($CAROLINE_ADMIN_ID); see skills-all/muso-intercom/SKILL.md." >&2
  fail=1
}

while IFS= read -r -d '' f; do
  grep -qE "$IN_SCOPE_RE" "$f" 2>/dev/null || continue
  flat=$(tr -s '[:space:]' ' ' < "$f" 2>/dev/null)

  # Every literal id bound to an identity field must be Caroline's. The match ends with
  # the digit run, so the trailing digits are the bound value.
  if lits=$(printf '%s' "$flat" | grep -oE "$LITERAL_RE"); then
    bad=$(printf '%s\n' "$lits" | while IFS= read -r m; do
            [ "${m##*[!0-9]}" = "$CAROLINE_ADMIN_ID" ] || printf '%s\n' "$m"
          done)
    [ -n "$bad" ] && report "$f" "binds an Intercom identity field to a literal that is not Caroline." "$bad"
  fi

  # An escape can hide either half of an identity binding -- the value, or the KEY that
  # JavaScript decodes back to `admin_id` before sending -- and neither can be read
  # statically, so neither can be shown to be Caroline's.
  if esc=$(printf '%s' "$flat" | grep -oE "$ESCAPE_RE" | sort -u); then
    report "$f" "contains an escaped literal the checker cannot resolve; write Intercom identity keys and values plainly." "$esc"
  fi
done < <(scan_targets)

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "Intercom reply-identity doctrine check FAILED." >&2
  echo "Agent-authored customer-facing replies post as Caroline ($CAROLINE_ADMIN_ID), never a human admin id." >&2
  exit 1
fi

echo "OK: Intercom reply-identity doctrine anchors present; every literal-bound identity field is Caroline ($CAROLINE_ADMIN_ID)."
