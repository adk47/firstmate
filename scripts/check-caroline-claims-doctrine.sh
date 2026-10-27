#!/usr/bin/env bash
set -euo pipefail

# Doctrine eval for Caroline's ten most common claim / credit / merge / channel questions.
#
# Why: the 2026-10-26 merge audit (profile-merge-ops-m1) found 27 of 30 merge asks told
# "within 5 business days" (a date nobody kept: 0 merge tickets closed in 7 days), users
# whose profiles were all claimed told "the claims need to be checked", and on-behalf
# claims told "manual review by our team with no fixed turnaround". Claims, credits and
# merges are decided by the agent lanes under written rules (captain 2026-10-26 21:05Z: no
# human queues), so none of those statements is true. The source was the reference files
# and the create_ticket SLA, not the model, so the fix is doctrine + tool output and this
# gate keeps it fixed:
#   - every question below names the file Caroline retrieves for it, the anchors that must
#     still be there (the correct answer), and the phrases that must never come back;
#   - a global forbid list covers the whole support workspace;
#   - the create_ticket half (sla: null for these kinds) is unit-tested in
#     plugins/support-tools/tests/ticket-format.test.ts and create-ticket.test.ts.
# Prose != enforcement: this cannot stop a runtime fabrication, it stops the knowledge
# base from teaching one. Matching is whitespace-normalized so a re-wrap cannot make a
# forbid fail OPEN (same matcher as check-refund-doctrine.sh).

ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WS="${SUPPORT_WORKSPACE:-$ROOT/workspaces/support}"

SOUL="$WS/SOUL.md"
AGENTS="$WS/AGENTS.md"
TOOLS="$WS/TOOLS.md"
CI="$WS/reference/common-issues.md"
FAQ="$WS/reference/faq.md"
CAP="$WS/reference/credits-and-profiles.md"
PF="$WS/reference/platform-features.md"
AR="$WS/skills/action-request/SKILL.md"
CR="$WS/skills/customer-credit-removal/SKILL.md"
CV="$WS/skills/customer-credit-verification/SKILL.md"
TF_SUPPORT="$ROOT/plugins/support-tools/src/tools/ticket-format.ts"
TF_INTERCOM="$ROOT/plugins/intercom/src/ticket-format.ts"

for f in "$SOUL" "$AGENTS" "$TOOLS" "$CI" "$FAQ" "$CAP" "$PF" "$AR" "$CR" "$CV" "$TF_SUPPORT" "$TF_INTERCOM"; do
  [ -f "$f" ] || { echo "Missing $f (run from repo root, or set REPO_ROOT / SUPPORT_WORKSPACE)." >&2; exit 2; }
done

fail=0
_normalized() { tr '\n' ' ' < "$1" | tr -s '[:space:]' ' '; }
_normalize_pat() { printf '%s' "$1" | tr '\n' ' ' | tr -s '[:space:]' ' '; }

# The text is captured into a variable FIRST and grep reads it from a here-string, never
# from a pipe. With `set -o pipefail`, `producer | grep -q` is false-green on a match in a
# large file: grep exits on the first hit, the producer dies of SIGPIPE (141), pipefail
# reports the pipeline as failed, and `if ...; then FAIL` never fires (QA finding on #1378).
# grep's own status is 0 match / 1 no match / >1 error; an error is a FAIL in both
# directions, never a pass.
_match() {  # _match <i|-> <file> <pattern>  -> 0 match, 1 no match, 2 error
  local text pat rc=0 flags=-qF
  [ "$1" = i ] && flags=-qiF
  text="$(_normalized "$2")" || return 2
  pat="$(_normalize_pat "$3")"
  grep "$flags" -- "$pat" <<<"$text" || rc=$?
  return "$rc"
}

require() {
  local file="$1" label="$2" pat="$3" rc=0
  _match - "$file" "$pat" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: ${file#"$ROOT"/}: $label" >&2
    echo "      expected to still contain: \"$pat\"" >&2
    [ "$rc" -eq 1 ] || echo "      (matcher error rc=$rc)" >&2
    fail=1
  fi
}

forbid() {
  local file="$1" label="$2" pat="$3" rc=0
  _match i "$file" "$pat" || rc=$?
  if [ "$rc" -ne 1 ]; then
    echo "FAIL: ${file#"$ROOT"/}: $label" >&2
    echo "      must NO LONGER contain: \"$pat\"" >&2
    [ "$rc" -eq 0 ] || echo "      (matcher error rc=$rc)" >&2
    fail=1
  fi
}

# --- Q1 "How do I claim my profile?" ----------------------------------------------
# The real form (claim-flow-fix-fable-c1, seen 2026-10-21): "add a link or two you control";
# there is no ID scan and no admin step the user waits on.
require "$FAQ" "Q1 claim how-to: links the claimant controls" "Add a link or two you control"
require "$CAP" "Q1 claim how-to: no ID scan, no human queue" "no ID scan, no human queue"
for f in "$FAQ" "$CAP" "$PF"; do
  forbid "$f" "Q1 there is no ID scan in the claim flow" "ID scan or social media login"
  forbid "$f" "Q1 there is no ID scan in the claim flow" "via ID card scan"
done
forbid "$CAP" "Q1 no admin review step" "3. Admin review"

# --- Q2 "My claim is pending, how long will it take?" ------------------------------
require "$CI" "Q2 pending claim: the app's own pending wording" \
  "We are verifying your claim and will notify you when it has been processed"
require "$CI" "Q2 pending claim: no timeframe" "Quote no timeframe and never say a person will review it"
require "$CI" "Q2 never invent a code or surface" "never invent a code, a surface, or a check of your own"
forbid "$CI" "Q2 no business-day wait on claims" "within normal review time"
forbid "$CI" "Q2 no business-day wait on claims" "If more than 5 business days"
forbid "$FAQ" "Q2 no business-day wait on claims" "no update after 5 business days"

# --- Q3 "My claim was rejected" -----------------------------------------------------
require "$CI" "Q3 rejected: resubmit with a link they control" "claiming again with such a link is the resubmission path"
for f in "$CI" "$FAQ"; do
  forbid "$f" "Q3 no government-ID ask (no ID upload exists)" "resubmit with a government-issued ID"
  forbid "$f" "Q3 no government-ID ask (no ID upload exists)" "government-issued ID is most reliable"
done

# --- Q4 "I manage this artist / label, can I claim it?" -----------------------------
require "$CI" "Q4 on-behalf: organization path on an official-domain email" "official domain of the label, management company or publisher"
forbid "$CI" "Q4 on-behalf is not an open-ended human review" "no fixed turnaround"
forbid "$CI" "Q4 on-behalf is not an open-ended human review" "manual review by our team"
forbid "$CI" "Q4 on-behalf is not an open-ended human review" "This kind of access needs a manual review"
forbid "$CAP" "Q4 company claims are not reviewed manually" "profiles are reviewed manually"

# --- Q5 "Can you merge my duplicate profiles?" --------------------------------------
require "$CI" "Q5 merge: claim-first" "a merge happens only when EVERY profile involved has a processed claim by this customer"
require "$CI" "Q5 merge: no date" "Promise no date"
require "$AGENTS" "Q5 merge: claim-first rule + no date in the always-loaded contract" "Never promise the merge or a date"
forbid "$CI" "Q5 merge date nobody keeps (audit 2026-10-26: 27/30)" "merge typically within 5 business days"
forbid "$FAQ" "Q5 merge is not a manual review" "need manual review before anything changes"
forbid "$CAP" "Q5 merge is not a manual review" "need manual review before"
forbid "$AR" "Q5 merge ticket carries no 5-day promise" '| `profile-merge` | 2 | 5 business days |'
forbid "$AR" "Q5 Tier 2 carries no 5-day promise" 'tell customer "5 business days"'
forbid "$AR" "Q7 bulk credit change carries no 5-day promise" '| `bulk-credit-change` | 2 | 5 business days |'
forbid "$CI" "Q5 self-serve merge is not live" "Profile merges are handled by the operations team via support ticket"

# --- Q6 "Both profiles are already claimed by me, why are they not merged?" ---------
require "$CI" "Q6 all claimed by them: never 'claims need review'" "Never tell them their claims need review or ask them to claim again"
require "$AGENTS" "Q6 all claimed by them: never 'claims need review'" "never say their claims need review or ask them to claim again"
require "$AGENTS" "Q6 never offer a merge the tool did not preview" 'never say "I can merge them" or ask them to'

# --- Q7 "Where is my credit request?" -----------------------------------------------
require "$AGENTS" "Q7 credit status: ground in profile_credits_status" '"My credit is missing / wrong / did it sync" -> `profile_credits_status` first'
require "$CI" "Q7 credit error ticket: no timeframe" "returns no timeframe for credit requests; quote none"
forbid "$CI" "Q7 no business-day promise on credit errors" "what the correct credit should be. SLA: 2 business days"

# --- Q8 "What proof do I need for my pending credit?" -------------------------------
require "$CI" "Q8 proof goes in the in-app support chat" "Proof goes here in the in-app"
require "$CV" "Q8 awaiting-review credits need nothing and no date" "do **not** promise a date"

# --- Q9 "I already sent my documents, any update?" ----------------------------------
require "$CI" "Q9 status first, never re-ask" "Never ask again for proof they already sent"
forbid "$CI" "Q9 no 5-day wait on documented credits" "open more than 5 business days with no update"

# --- Q10 "Will you call me / email me?" ---------------------------------------------
require "$SOUL" "Q10 never promise a phone call" "NEVER promise a phone call or a separate email"
require "$SOUL" "Q10 replies land in the Intercom conversation" "your reply lands in their Intercom conversation"
require "$AGENTS" "Q10 bell + email notices are separate" "App notices (bell + email) go out separately"
require "$CI" "Q4/Q10 claim decision is an app notification, not a chat reply" "the claim decision reaches them as an app notification and email"
forbid "$CI" "Q4 no conversation-reply promise for claims" "returns no timeframe for claims. The outcome is posted in this conversation"
require "$AGENTS" "Q10 channel rule in the always-loaded contract" "Never promise a phone call or a"

# --- create_ticket gives Caroline no timeframe to quote on these kinds --------------
require "$SOUL" "SLA: null means quote no timeframe" "If it returned \`sla: null\`, quote no timeframe at all"
require "$TOOLS" "TOOLS documents sla: null" "\`sla\` null + \`customer_timing\` for credit/claim/merge kinds"
forbid "$SOUL" "no per-category SLA table for claims/credits" "2 business days for profile claims/credits"
forbid "$SOUL" "no hard-coded tier SLA list" "Tier 2: 5 business days"
for f in "$TF_SUPPORT" "$TF_INTERCOM"; do
  require "$f" "AGENT_LANE_ACTIONS covers merges" '"profile-merge", "track-merge", "unmerge-request",'
  require "$f" "AGENT_LANE_ACTIONS covers claims + credits" '"credit-claim", "credit-correction", "credit-verify", "bulk-credit-change", "profile-claim",'
  require "$f" "profile-claim outcome is an app notification" 'if (actionType === "profile-claim") return "app_notification";'
done

# --- global: no human-review date promise anywhere in the support workspace ---------
while IFS= read -r -d '' f; do
  forbid "$f" "no 5-business-day merge/credit promise" "they'll follow up within 5 business days"
  forbid "$f" "no 5-business-day merge/credit promise" "You'll hear back within 5 business days"
  forbid "$f" "no 'claims need to be checked' to claimed users" "The claims need to be checked before anything can be combined"
done < <(find "$WS" -name '*.md' -print0)

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "Caroline claims/credits/merges doctrine drifted. See scripts/check-caroline-claims-doctrine.sh header." >&2
  exit 1
fi
echo "OK: Caroline claims/credits/merges doctrine (10 questions + create_ticket timing) intact."
