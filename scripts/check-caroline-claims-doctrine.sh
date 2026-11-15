#!/usr/bin/env bash
set -euo pipefail

# Doctrine eval for Caroline's most common claim / credit / merge / channel questions (Q1-Q14).
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
# Captain 2026-10-28 12:1xZ / 12:3xZ: the six verification/merge skills are gone; the one
# verification-handoff skill replaces them (Caroline answers, files the ticket kind, hands off).
CV="$WS/skills/verification-handoff/SKILL.md"
TF_SUPPORT="$ROOT/plugins/support-tools/src/tools/ticket-format.ts"
TF_INTERCOM="$ROOT/plugins/intercom/src/ticket-format.ts"

for f in "$SOUL" "$AGENTS" "$TOOLS" "$CI" "$FAQ" "$CAP" "$PF" "$AR" "$CV" "$TF_SUPPORT" "$TF_INTERCOM"; do
  [ -f "$f" ] || { echo "Missing $f (run from repo root, or set REPO_ROOT / SUPPORT_WORKSPACE)." >&2; exit 2; }
done

fail=0
# Lines carrying the barred-phrases marker (the one doctrine line that NAMES the phrases
# Caroline must never say) are dropped before matching, so the rule can quote what it bans.
# At most one such line per file is allowed (checked below), so the marker cannot be used
# to smuggle a violation past the forbid list.
BARRED_MARKER='<!-- barred-phrases -->'
# The process-never-judgement list (verification-handoff) has to name the signal words it
# bans; its one line carries this second marker, same one-per-file rule.
REVEAL_MARKER='<!-- never-reveal -->'
_normalized() { grep -vF -e "$BARRED_MARKER" -e "$REVEAL_MARKER" -- "$1" | tr '\n' ' ' | tr -s '[:space:]' ' '; }
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
  _forbid_report "$file" "$label" "$pat" "$rc"
}

# forbid_in <file> <already-normalized text> <label> <pattern>: the global loop normalizes
# each file once and checks every barred phrase against that text (same here-string rule).
forbid_in() {
  local file="$1" text="$2" label="$3" pat rc=0
  pat="$(_normalize_pat "$4")"
  grep -qiF -- "$pat" <<<"$text" || rc=$?
  _forbid_report "$file" "$label" "$4" "$rc"
}

_forbid_report() {
  local file="$1" label="$2" pat="$3" rc="$4"
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
require "$FAQ" "Q1 claim how-to: the approved claim paragraph (caroline-instructions-1029 §2.3)" "Claims are confirmed by something only the profile's owner can do, so nobody can claim a profile that isn't theirs."
require "$FAQ" "Q1 claim how-to: the only claim timing line" "the claim is approved automatically, usually within a day"
require "$FAQ" "Q1 claim how-to: never ID" "We never ask for ID."
forbid "$FAQ" "Q1 old claim flow is gone" "Add a link or two you control"
require "$CAP" "Q1 claim how-to: no ID step" "There is no ID step."
for f in "$FAQ" "$CAP" "$PF"; do
  forbid "$f" "Q1 there is no ID scan in the claim flow" "ID scan or social media login"
  forbid "$f" "Q1 there is no ID scan in the claim flow" "via ID card scan"
done
forbid "$CAP" "Q1 no admin review step" "3. Admin review"

# Captain 2026-10-28 12:1xZ / 12:3xZ: Caroline only hands off on credits, documents, claims
# and merges. Q2-Q9 and Q11 now assert the HAND-OFF answer: no look-up, the ticket kind + the
# handoff tag, the one approved handoff line, no status / outcome / timeframe.
#
# ai-support-quality-v1 (2026-11-12) changed two things here, both measured on the live inbox
# (data/ai-support-quality-v1/report.md, 417 conversations in 24h):
#   1. The closing line "I'm pulling in a teammate to take this from here." is RETIRED from the
#      doctrine. It was sent to 268 customers in a day; a person was assigned in 63 and replied
#      in none. Caroline cannot assign a conversation (captain 2026-11-11), so the sentence is
#      false whenever she writes it, and plugins/intercom/src/unbacked-handoff.ts removes it at
#      send. The doctrine must not teach a line the code deletes.
#   2. ONE look-up is allowed: the signed-in customer's own request state, and only to decide
#      whether the approved status paragraph (§2.8) is true for them. The output guard already
#      required that fact in code and nothing supplied it, so the paragraph was refused every
#      time (56 conversations in the same 24h). Everything else stays hand-off only.
HANDOFF_LINE="I'm pulling in a teammate to take this from here."
for f in "$CV" "$CI" "$CAP"; do
  forbid "$f" "the retired closing line is not taught (unbacked promise of a person)" "$HANDOFF_LINE"
done
# Captain 2026-11-14 (firstmate inbox 012): no path tells a customer a person is coming. The
# escalation team has no members, so the escalation's own farewell is the honesty line, and the
# retired closing line is not taught anywhere a human reads it. Where a file still said "the handoff
# line", it means the honesty line below.
forbid "$AGENTS" "the retired closing line is not taught" "$HANDOFF_LINE"
require "$AGENTS" "the escalation's words are the honesty line" "I have recorded this and will update you here as soon as there is news."
forbid "$AGENTS" "no instruction to say the retired closing line" "say the handoff line verbatim"
forbid "$CV" "no instruction to say the retired closing line" "Last, always, the handoff line"
require "$AGENTS" "never a closing sentence that promises a person" "Never end a reply with a sentence that says a person is coming"
require "$CV" "never a closing sentence that promises a person" "Never end a reply with a sentence that says a person is coming"
require "$CV" "the one read: own rows only" "read ONLY the signed-in customer's own rows"
require "$CV" "the one read: null is not 'no request'" "the read did not happen. Do not send the status paragraph and never say there is no request"
require "$CV" "the one read: nothing beyond the tool's note" "and nothing else from the result"
require "$AGENTS" "the one read is named in the always-loaded contract" "Apart from the one read of the customer's OWN request state"
# The one read is two tools that fail closed without a signed-in customer. profile_credits_status
# looks up any profile typed in the conversation and scans for duplicates, so it stays off.
require "$CV" "the one read does not include the any-profile diagnosis" '`profile_credits_status`, `dedupe_check`, `remove_credits`'
require "$CV" "the one read returns nothing without a signed-in customer" "without a signed-in customer they return nothing"

# --- Q2 "My claim is pending, how long will it take?" ------------------------------
require "$CI" "Q2 claim: hand off only, the one read is the only look-up" "is the only look-up; say nothing about its state beyond what that skill allows."
require "$CV" "Q2 claim: profile-claim ticket, claim tag" '| their profile claim (status, rejected, stuck, on behalf of an artist) | `profile-claim` | `claim` |'
require "$CV" "Q2 never a claim code or a surface" "no claim code, no surface to put a code on"
forbid "$CI" "Q2 no business-day wait on claims" "within normal review time"
forbid "$CI" "Q2 no business-day wait on claims" "If more than 5 business days"
forbid "$FAQ" "Q2 no business-day wait on claims" "no update after 5 business days"
forbid "$FAQ" "Q2 Caroline does not look up the claim" "Caroline looks up its real state"

# --- Q3 "My claim was rejected" -----------------------------------------------------
require "$CAP" "Q3 declined: the approved decline paragraph (§2.6), no reason" "A request is closed when the supporting information we received wasn't enough to confirm the credit."
forbid "$CAP" "Q3 declined: never a reason" "gives the reason (for example, the document doesn't name"
forbid "$CAP" "Q3 removal: never a reason" "with the reason for each"
# Captain 2026-10-29 13:2xZ (decline-copy-ruling.md item 1): a decline says only that the
# supporting information was not enough. The five internal review codes
# (doesnt_name_you, other_track, other_role, unreadable, not_a_document) never reach the
# knowledge base, and neither does the way they sound to a user: a fraud denial and an
# ordinary shortfall are the same sentence to the customer, on purpose.
#
# ALL FIVE codes, and all five of the ways they sound (QA #1718 round 8, 2026-11-06: the
# first cut of this gate listed four codes and three phrasings, so a doctrine edit saying a
# decline was for an unreadable document passed). The two lists are kept the same length on
# purpose - a code with no matching phrasing is a hole, because the sentence a doctrine
# author actually writes is the phrasing, not the code.
#
# `unreadable` is an ordinary English word, so the bare-word guard is scoped to the two
# decline-doctrine files ($CAP, $CV) and NOT to the whole workspace: workspaces/support/
# SOUL.md uses it legitimately twice, about the attachment block and `unsupported_type`
# ("don't call it corrupt or unreadable"), which is a different subject. Neither $CAP nor
# $CV contains the word today, so the guard starts clean; if one ever needs it for a
# non-decline reason, scope that line rather than dropping the guard.
for pat in doesnt_name_you other_track other_role unreadable not_a_document; do
  forbid "$CAP" "Q3 declined: the internal review codes stay internal" "$pat"
  forbid "$CV" "Q3 declined: the internal review codes stay internal" "$pat"
done
for pat in "didn't name you" "different track" "different role" \
           "unreadable document" "document was unreadable" "couldn't read" \
           "not a document" "wasn't a document"; do
  forbid "$CAP" "Q3 declined: never a reason" "$pat"
  forbid "$CV" "Q3 declined: never a reason" "$pat"
done
for f in "$CI" "$FAQ"; do
  forbid "$f" "Q3 no government-ID ask (no ID upload exists)" "resubmit with a government-issued ID"
  forbid "$f" "Q3 no government-ID ask (no ID upload exists)" "government-issued ID is most reliable"
done

# --- Q4 "I manage this artist / label, can I claim it?" -----------------------------
require "$CI" "Q4 on-behalf: organization path, hand off" "decided by the claim lane on the organization path. Hand off only."
require "$CI" "Q4 never tell them the artist must claim" "NEVER tell the customer the artist must claim the profile themselves."
forbid "$CI" "Q4 on-behalf is not an open-ended human review" "no fixed turnaround"
forbid "$CI" "Q4 on-behalf is not an open-ended human review" "manual review by our team"
forbid "$CI" "Q4 on-behalf is not an open-ended human review" "This kind of access needs a manual review"
forbid "$CAP" "Q4 company claims are not reviewed manually" "profiles are reviewed manually"

# --- Q5 "Can you merge my duplicate profiles?" --------------------------------------
require "$CV" "Q5 merge: profile-merge ticket, merge tag" '| duplicate profiles / merge | `profile-merge` | `merge` |'
require "$CI" "Q5 merge: hand off only, no check" "**Hand off only**: run no check on their profiles."
require "$AGENTS" "Q5 merge: claim-first rule + no date in the always-loaded contract" "Never promise the merge or a date"
forbid "$CI" "Q5 merge date nobody keeps (audit 2026-10-26: 27/30)" "merge typically within 5 business days"
forbid "$FAQ" "Q5 merge is not a manual review" "need manual review before anything changes"
forbid "$CAP" "Q5 merge is not a manual review" "need manual review before"
forbid "$AR" "Q5 merge ticket carries no 5-day promise" '| `profile-merge` | 2 | 5 business days |'
forbid "$AR" "Q5 Tier 2 carries no 5-day promise" 'tell customer "5 business days"'
forbid "$AR" "Q7 bulk credit change carries no 5-day promise" '| `bulk-credit-change` | 2 | 5 business days |'
forbid "$CI" "Q5 self-serve merge is not live" "Profile merges are handled by the operations team via support ticket"

# --- Q6 "Both profiles are already claimed by me, why are they not merged?" ---------
require "$AGENTS" "Q6 never 'claims need review' to claimed users" "never say their claims need review or ask them to claim again"
require "$AGENTS" "Q6 never offer a merge" 'never say "I can merge them"'
require "$CI" "Q6 never say which profiles are claimed" "Never say which of their profiles are claimed"

# --- Q7 "Where is my credit request?" -----------------------------------------------
require "$CV" "Q7 credit status: credit-verify ticket, credit-status tag" '| a pending / stuck credit, "where is my credit request" | `credit-verify` | `credit-status` |'
require "$CI" "Q7 credit: hand off only, the one read is the only look-up" "**Hand off only** for anything about THEIR credit (missing, wrong, pending, stuck). The one read in \`verification-handoff\` is the only look-up."
forbid "$AGENTS" "Q7 no credit-status look-up" '-> `profile_credits_status` first'
forbid "$CI" "Q7 no business-day promise on credit errors" "what the correct credit should be. SLA: 2 business days"

# --- Q8 "What proof do I need for my pending credit?" -------------------------------
require "$CV" "Q8 Caroline never asks for proof" "Never ask for proof and never list proof types"
require "$CI" "Q8 Caroline never asks for proof" "Caroline does not ask for proof and does not list proof types beyond the approved credit"
forbid "$CI" "Q8 no proof-type list from Caroline" "Accepted forms of proof (screenshots are accepted for all of these)"

# --- Q9 "I already sent my documents, any update?" ----------------------------------
require "$CV" "Q9 document: credit-verify ticket, document tag" '| a document, screenshot or link as proof for a credit | `credit-verify` | `document` |'
forbid "$CI" "Q9 no 5-day wait on documented credits" "open more than 5 business days with no update"
forbid "$CI" "Q9 no status look-up" "look up the real state with"

# --- Q10 "Will you call me / email me?" ---------------------------------------------
require "$SOUL" "Q10 never promise a phone call" "NEVER promise a phone call or a separate email"
require "$SOUL" "Q10 replies land in the Intercom conversation" "your reply lands in their Intercom conversation"
require "$AGENTS" "Q10 bell + email notices are separate" "App notices (bell + email) go out separately"
forbid "$CI" "Q4 no conversation-reply promise for claims" "returns no timeframe for claims. The outcome is posted in this conversation"
require "$AGENTS" "Q10 channel rule in the always-loaded contract" "Never promise a phone call or a"

# --- create_ticket gives Caroline no timeframe to quote on these kinds --------------
require "$SOUL" "SLA: null means quote no timeframe" "\`create_ticket\` returns \`sla: null\` for every kind; say only that they will hear in this conversation and by email."
require "$TOOLS" "TOOLS documents sla: null" "\`sla\` null + \`customer_timing\` for credit/claim/merge kinds"
forbid "$SOUL" "no per-category SLA table for claims/credits" "2 business days for profile claims/credits"
forbid "$SOUL" "no hard-coded tier SLA list" "Tier 2: 5 business days"
for f in "$TF_SUPPORT" "$TF_INTERCOM"; do
  require "$f" "AGENT_LANE_ACTIONS covers merges" '"profile-merge", "track-merge", "unmerge-request",'
  require "$f" "AGENT_LANE_ACTIONS covers claims + credits" '"credit-claim", "credit-correction", "credit-removal", "credit-verify", "bulk-credit-change", "profile-claim",'
  require "$f" "profile-claim outcome is an app notification" 'if (actionType === "profile-claim") return "app_notification";'
done

# --- Q11 "I sent my screenshots, did you get them?" (captain 2026-10-27 02:51Z, 2026-10-28) --
# 10-27 paid threads were told "I've passed your screenshots ... to our team" / "added to the
# review already underway" with nothing behind it. Since 2026-10-28 Caroline never says a
# document was received at all: "Thank you", the document ticket, the handoff line.
require "$CV" "Q11 a document gets the approved thank-you paragraph (§2.2)" "Thank you. Everything you send here is recorded against your account and your open requests and goes to the verification team."
# The marker line is excluded from normal matching, so check it raw: exactly one line that
# carries the marker AND names the barred phrases.
if [ "$(grep -F -- "$BARRED_MARKER" "$CV" | grep -cF -- '"nothing else is needed", "no need to resend", "passed to our team"' || true)" != "1" ]; then
  echo "FAIL: ${CV#"$ROOT"/}: Q11 the barred phrases must be named on the one barred-phrases marker line" >&2
  fail=1
fi
forbid "$CAP" "Q11 no 'we'll check it, usually within a few days'" "usually within a few days"
forbid "$CI" "Q11 awaiting review is not 'nothing you need to do'" "nothing you need to do right now"
forbid "$CV" "Q11 no 'received for review'" "may_say_document_passed_on"

# --- Q12 "Did you check / verify / merge it?" (captain 2026-10-28 12:1xZ) -------------
# Caroline never says she checked, filed, verified or merged anything, and never "raised the
# priority" (red-team AP-5, seen live 10-27/28). The verification/merge skills that scripted
# look-ups, previews and merges are deleted; their names must not come back as skills or
# routing targets.
if [ "$(grep -F -- "$BARRED_MARKER" "$CV" | grep -cF -- "\"I've checked\", \"I checked\", \"I've filed\", \"I've logged\", \"I've verified\", \"I verified\", \"I've merged\", \"I merged\", \"I can merge\"" || true)" != "1" ]; then
  echo "FAIL: ${CV#"$ROOT"/}: Q12 the never-say-checked/filed/verified/merged phrases must be on the barred-phrases line" >&2
  fail=1
fi
require "$CV" "Q12 no look-ups for these questions" "No look-ups for these questions"
require "$AGENTS" "Q12 hand-off section in the always-loaded contract" "never check, file a document, verify, approve, claim, merge or remove anything, and you never say you did"
for f in "$TF_SUPPORT" "$TF_INTERCOM"; do
  require "$f" "Q12 the ticket carries the handoff tag" 'return `handoff:${rule.allowed.includes(asked) ? asked : rule.default}`;'
  require "$f" "Q12 credit kinds tag credit-status" '"credit-verify": { default: "credit-status", allowed: ["credit-status", "document"] },'
  require "$f" "Q12 merge kinds tag merge" '"profile-merge": { default: "merge", allowed: ["merge"] },'
done
for gone in customer-credit-verification customer-profile-claim customer-profile-consolidate \
            customer-profile-dedupe customer-track-dedupe customer-credit-removal; do
  if [ -e "$WS/skills/$gone" ]; then
    echo "FAIL: workspaces/support/skills/$gone: removed verification/merge skill is back (captain 2026-10-28)" >&2
    fail=1
  fi
done

# --- Q13 "How do you verify credits?" / process, never judgement (captain 2026-10-29) ---
require "$FAQ" "Q13 the approved credit paragraph (§2.1)" "we check it automatically against public credit sources."
require "$CV" "Q13 the process-never-judgement rule" "Explain the PROCESS (what happens, in what order, where they hear from us, what they can do)."
require "$AGENTS" "Q13 process-never-judgement in the always-loaded contract" "Explain the process, never the judgement"
require "$CV" "Q13 status chasing: the approved queue paragraph (§2.8), only after a measured open request" "ONLY when the one read (Hard lines) returned \`open_request: true\` in this turn"
require "$FAQ" "Q13 merges: the approved merge paragraph (§2.4)" "Merges work like this: claim every profile that is yours first"
require "$CAP" "Q13 removals: the approved removal paragraph (§2.5)" "A credit is only removed from a profile after we've checked it against the streaming platforms' own credits"

# --- every reply template is SLA-free (customerSlaFor is null for every kind; QA on #1451) --
for f in "$SOUL" "$AGENTS" "$AR" "$WS/skills/refund-retention/SKILL.md" "$WS/skills/order-fulfillment/SKILL.md"; do
  forbid "$f" "no reply template quotes an SLA" "within \`<sla>\`"
  forbid "$f" "no reply template quotes an SLA" "within [sla]"
  forbid "$f" "no instruction to quote the SLA" "quote the SLA once"
  forbid "$f" "no instruction to quote the SLA" "quote the returned \`sla\` once"
done
require "$CV" "merge hand-off names customerProfileId without a look-up" "the id in the profile link the customer gave"
require "$CV" "unmerge hand-off maps the other profile or artist" "\`details.suspect_artist_names[]\` = those names"

# The absolute timeframe ban must exempt the two approved sentences, or Caroline may drop the
# required GDPR acknowledgement (QA on #1451).
require "$AGENTS" "timeframe ban exempts the approved GDPR + claim sentences" "the GDPR acknowledgement's \"within one month of today\" and the claim paragraph's \"usually within a day\""
require "$SOUL" "timeframe ban exempts the approved GDPR + claim sentences" "Only exceptions, verbatim: the GDPR ack's \"within one month of today\", the claim paragraph's \"usually within a day\"."

# --- cs-health 2026-11-01 action 5: two answers Caroline was missing (Fable o1 §6) ----
require "$FAQ" "no-profile users get claim/create first, not the credit process" "You need a Muso profile before you can add a credit: claim or create your profile first, then add the credit."
require "$FAQ" "claim-code: the code on one page is enough" "Yes, the code on one page you control is enough."

# --- Q14 "Delete my profile under GDPR" (GDPR acknowledgement v2, ruled 2026-11-01) ----
GDPR="$WS/reference/gdpr-erasure-requests.md"
# The FULL acknowledgement is pinned, not fragments (QA + r5 on #1619: a fragment gate let "All credit records on
# published works are erased immediately." replace the formal-review sentence and still pass). Three layers:
#   1. every sentence of the acknowledgement and each fixed slot, verbatim, under its own label (a mutation of any one
#      sentence names it);
#   2. the whole block from its approval marker to "Fixed slots", verbatim (an inserted or reordered sentence fails);
#   3. the retired wordings are forbidden (v1, the name-match sufficiency promises, the hide day-count).
GDPR_ACK_SENTENCES=(
  "Thank you, we have your request to remove your personal data from Muso, received {date}."
  "Here is how it works."
  "**1. Confirm it's you.** The quickest way: open the page in the Muso app and claim it, that proves it on the spot."
  "Or reply from the email address on your Muso account, if you have one."
  "If neither applies, send the link to the page and your name as it appears on your ID."
  "If you are writing for someone else, send their written authorisation."
  "**2. We hide the page.** As soon as we've confirmed it's you, the page comes out of Muso search and public view."
  "If your request raises a legal matter, we hide it immediately."
  "**3. Written confirmation on this thread**, within one month of today, listing exactly what was done."
  "Any account you hold is closed and taken out of use on request; what has been deleted is stated in that confirmation."
  "Credit records on published works go through a separate formal review, and the written response covers them."
)
GDPR_SLOT_NO_LINK="To get started, reply with the link to the Muso page."
GDPR_SLOT_OWN_NAME="**1. Confirm it's you.** The quickest way: open the page in the Muso app and claim it. Otherwise, reply with your name as it appears on your ID; if the page is unclaimed and carries that name, the team can confirm it from that."
i=0
for sentence in "${GDPR_ACK_SENTENCES[@]}"; do
  i=$((i + 1))
  require "$GDPR" "Q14 ack sentence $i verbatim" "$sentence"
done
require "$GDPR" "Q14 slot no-link verbatim" "$GDPR_SLOT_NO_LINK"
require "$GDPR" "Q14 slot own-name verbatim" "$GDPR_SLOT_OWN_NAME"
GDPR_BLOCK="<!-- approved: gdpr-ack-v2-1101 --> > ${GDPR_ACK_SENTENCES[0]} ${GDPR_ACK_SENTENCES[1]} > > ${GDPR_ACK_SENTENCES[2]} ${GDPR_ACK_SENTENCES[3]} ${GDPR_ACK_SENTENCES[4]} ${GDPR_ACK_SENTENCES[5]} > > ${GDPR_ACK_SENTENCES[6]} ${GDPR_ACK_SENTENCES[7]} > > ${GDPR_ACK_SENTENCES[8]} ${GDPR_ACK_SENTENCES[9]} > > ${GDPR_ACK_SENTENCES[10]} Fixed slots (pick, never edit):"
require "$GDPR" "Q14 the full approved acknowledgement block verbatim" "$GDPR_BLOCK"
require "$GDPR" "Q14 a claim is not required for GDPR" "A claim is NOT required for GDPR."
require "$GDPR" "Q14 legal words carry legal_threat" "put \`legal_threat\` first in the ticket's \`titleGist\` and \`summary\`"
forbid "$GDPR" "Q14 v1 acknowledgement retired" "we confirm that the page is about you"
# r5 NO-GO 2026-11-01 (#1619 @31898473): a name match never promises confirmation (captain: no name-match approvals);
# the hide carries no day count (nothing automates it or staffs it on a clock)
forbid "$GDPR" "Q14 no name-match sufficiency promise" "that is enough"
forbid "$GDPR" "Q14 no name-match sufficiency promise" "we will confirm it from that"
forbid "$GDPR" "Q14 own-name slot carries no inaction promise" "nothing more is needed from you"
forbid "$GDPR" "Q14 the hide carries no day count" "(within a day)"
require "$GDPR" "Q14 hidden pages do not come back" "once a page is hidden it stays"
forbid "$GDPR" "Q14 no tier-3 SLA quote" "quote the returned SLA once"
forbid "$FAQ" "Q14 deletion goes through the acknowledgement" "Create a support ticket with category \"Account – Deletion Request\""

# --- global: no human-review date promise anywhere in the support workspace ---------
while IFS= read -r -d '' f; do
  t="$(_normalized "$f")" || { echo "FAIL: ${f#"$ROOT"/}: unreadable" >&2; fail=1; continue; }
  n="$(grep -cF -- "$BARRED_MARKER" "$f" || true)"
  if [ "${n:-0}" -gt 1 ]; then
    echo "FAIL: ${f#"$ROOT"/}: more than one barred-phrases marker line ($n); only the one rule line may carry it" >&2
    fail=1
  fi
  n="$(grep -cF -- "$REVEAL_MARKER" "$f" || true)"
  if [ "${n:-0}" -gt 1 ]; then
    echo "FAIL: ${f#"$ROOT"/}: more than one never-reveal marker line ($n); only the one list line may carry it" >&2
    fail=1
  fi
  forbid_in "$f" "$t" "captain 02:51Z barred phrase" "nothing else is needed"
  # GDPR ack v2 (2026-11-01): nothing is promised as deleted (legal hold 1350)
  forbid_in "$f" "$t" "GDPR v2: never promise deletion" "is deleted on request"
  forbid_in "$f" "$t" "captain 02:51Z barred phrase" "no need to resend"
  forbid_in "$f" "$t" "captain 02:51Z barred phrase" "passed to our team"
  forbid_in "$f" "$t" "captain 02:51Z barred phrase" "passed it to our team"
  forbid_in "$f" "$t" "captain 02:51Z barred phrase" "passed it to the team"
  forbid_in "$f" "$t" "captain 02:51Z barred phrase" "passed your screenshots"
  forbid_in "$f" "$t" "captain 02:51Z barred phrase" "review underway"
  forbid_in "$f" "$t" "captain 02:51Z barred phrase" "review already underway"
  forbid_in "$f" "$t" "captain 02:51Z barred phrase" "nothing more they need to send"
  # Captain 2026-10-29 03:2xZ: Jaxsta leaves every user-facing line (Fable, h2 #1460).
  forbid_in "$f" "$t" "captain 2026-10-29: Jaxsta is not named to users" "Jaxsta"
  # Captain 2026-10-29 (caroline-instructions-1029 §2.9/§3): no business-day number, no
  # promise of inaction (a user told "nothing is needed from you" waited 10 days), and none of
  # the quotable "secret sauce" strings: sources, signals, vendors, internal names.
  for bad in "5-10 business days" "within 5 business days" "2 business days" "1 business day" \
             "nothing is needed from you" "nothing you need to do" "you don't need to do anything" \
             "risk score" "fraud lens" "MusicBrainz" "Deezer" "DKIM" "copy-move" \
             "Spotify and Tidal" "DeepSeek" "OpenRouter" "Fable"; do
    forbid_in "$f" "$t" "captain 2026-10-29: never said to users" "$bad"
  done
  forbid_in "$f" "$t" "captain 2026-10-28 never claims an action" "raised the priority"
  forbid_in "$f" "$t" "captain 2026-10-28 never claims an action" "marked it at the highest priority"
  forbid_in "$f" "$t" "captain 2026-10-28 never claims an action" "I've checked quite a lot"
  for gone in customer-credit-verification customer-profile-claim customer-profile-consolidate \
              customer-profile-dedupe customer-track-dedupe customer-credit-removal; do
    forbid_in "$f" "$t" "routes to a removed verification/merge skill" "\`$gone\`"
  done
  forbid_in "$f" "$t" "no 5-business-day merge/credit promise" "they'll follow up within 5 business days"
  forbid_in "$f" "$t" "no 5-business-day merge/credit promise" "You'll hear back within 5 business days"
  forbid_in "$f" "$t" "no 'claims need to be checked' to claimed users" "The claims need to be checked before anything can be combined"
done < <(find "$WS" -name '*.md' -print0)

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "Caroline claims/credits/merges doctrine drifted. See scripts/check-caroline-claims-doctrine.sh header." >&2
  exit 1
fi
echo "OK: Caroline claims/credits/merges doctrine (14 questions + timing + hand-off + secret-sauce) intact."
