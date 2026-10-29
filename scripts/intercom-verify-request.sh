#!/bin/bash -p
# ABSOLUTE INTERPRETER, PRIVILEGED MODE, and PATH replaced before anything runs. Same
# reasoning as intercom-ops-write.sh: `-p` stops bash sourcing $BASH_ENV and importing
# exported functions before line 1, and replacing PATH outright stops a jq/curl shim from
# rewriting the payload after validation.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
set -euo pipefail

# intercom-verify-request.sh: the ONLY path that asks a user to help verify credits we have
# added to their profile. Its campaigns, each approved in the words recorded below:
#
#   verify-live (default): NEW provisional approvals by the decider. 2026-10-15 22:12Z: "i
#       want AI live now - we have too many credits to approve and to get supporting data for
#       - let users know where there was a credit given and that it needs support (trust yet
#       verify approach)". Two copy versions:
#         windowed  23:40Z: "if no valid verification comes it should be removed", kept for
#                   NEW credits at 00:35Z. 30 days with the date, the removal date (the day
#                   after), reminders at day 14 and day 25. The ONLY copy a new credit is
#                   ever sent; SEND-LOCKED (LIVE_WINDOWED_COPY_APPROVED) until Fable's GO and
#                   the captain's approval of the rendered copy land in a PR.
#         v1        Fable's earlier no-deadline copy: preview only (--dry-run --copy v1),
#                   never sent, so no new credit is notified without a removal date.
#   retro-past: PAST credits from the agent batch (09-01 -> 10-11). 23:35Z asked for
#       documents; 00:35Z: "how many credits were approved without documentstion i dont want
#       to lose users unless its obvious fraud feom tbe past". A friendly ask with NO
#       deadline and NO removal language. 02:00Z: "are you annoying people fornbackup that we
#       shpuldnt be?": at most ONE message per user, ever, no follow-up, and never to a user
#       who already sent proof. The credit stays whatever happens (proven fraud is removed by
#       its own path, never here).
#       SEND-LOCKED (RETRO_COPY_APPROVED) until its copy has the same GO.
#   removal-notice: owners of previously approved credits that WE removed (any non-self actor:
#       admin, ops, review) are told which credit and role, why (one fixed reason sentence plus
#       an optional public evidence link) and how to dispute by replying with a document. Not
#       a documentation ask, so the documents-on-file filters do not apply. Fraud removals are
#       never notified (silent by captain order; the gate refuses reason "fraud"). SEND-LOCKED
#       (REMOVAL_COPY_APPROVED) until Fable's GO; the backfill list goes to firstmate first.
#   takeback-notice: the notice scripts/credit_retro/notice.py sends when a proven take-back
#       executes (#1237/#1242): which credit and role, who the public credits name for it (the
#       names in the row's recorded evidence, with the source and link), and how to dispute by
#       replying with one document. Fixed copy from docs/credit-verification/retro-drafts/
#       takeback-notice.md. Not an ask, no follow-ups, no date. SEND-LOCKED
#       (TAKEBACK_COPY_APPROVED) until Fable's GO; while locked --validate refuses too, so
#       credit-retro never removes a credit whose notice cannot go out. Unlocked, --validate
#       reports the per-day cap (exit 3).
#   uvn-status / withdrawal-confirm: approved under the captain's 2026-10-19 standing order
#       (UVN_STATUS_COPY_APPROVED, WITHDRAWAL_COPY_APPROVED below; in-thread delivery below).
#       docs/credit-verification/verify-request-notes.md owns the details.
#   gap-ask: the stage-2 gap ask (Fable 2026-10-26 13:23Z, GAP_ASK_COPY_APPROVED below): a user
#       whose document on file does not cover a held credit (stage-2 verdict need_more) is told,
#       in Fable's exact paragraph, what the document shows and which track and role it does not
#       cover. No deadline, no removal words, no follow-ups. The gate reads the verdict itself
#       (credit_review/stage2_verdicts.py over the proof store): every credit's latest verdict
#       must be need_more FOR THIS ACCOUNT, and <doc summary> comes from that row, never from the
#       caller. Once per credit; one message per user per day; none within 7 days of another note
#       except a status-doc-received note (the gap ask is the follow-up that note promised).
# --dry-run renders every version, so the copy can be reviewed before it ships.
#
# It is a copy of the deterministic gate in intercom-ops-write.sh, for an admin-initiated
# message (POST /messages) instead of a conversation reply:
#   - the posting identity is Caroline, pinned, whatever the environment says;
#   - the copy is FIXED per campaign, version and kind. The caller supplies only structured
#     fields (first name, role, track title, artist name, and the role families from a fixed
#     set that pick the document lists); every field is HTML-escaped, and the rendered text
#     goes through the same leak check as a customer-facing ops reply. There is no free-text
#     body argument at all;
#   - the approval is the captain's: --approved-by must be his Slack id (U7RP6HKUZ), and the
#     approval_ref recorded with every send is pinned below;
#   - the recipient is resolved from the ACCOUNT email (the credit request's user), through an
#     exact Intercom contact search that must return exactly one user, never from anything a
#     user wrote; a follow-up goes to the contact its note went to;
#   - one message per user per UTC day across campaigns, each credit request id gets a
#     campaign's note at most once, each reminder at most once per note, and each credit at
#     most one after-rejection note. All enforced in
#     the decider ledger (credit_review/verify_ledger.py) with a claim written BEFORE the
#     POST, so a timeout can never produce a second message. Only a note that NAMED a
#     removal date can ever be removal-due (the ledger records it);
#   - the api-log entry is written BEFORE the POST, and the response is checked AFTER it
#     (type admin_message, the requested message_type; in-thread: a Caroline comment part),
#     so "POSTED" can never describe a message that did not land as intended.
#
# tag-proof: when the user replies to a note WITH ATTACHMENTS, the conversation is tagged
# `credit-proof` for the Ops document step (and no further follow-up goes out); ANY reply to a
# claim-proof-ask note (text only too) is tagged `claim-proof` instead, a separate queue for a
# person, never credit proof, and a reminder-7 re-reads the note's conversation first. ANY reply by
# the user (text or attachment) also records a hold on the note's removal for a human
# (REPLY RECORDED), even on an already-tagged thread, which is never re-tagged (ALREADY TAGGED).
# Nothing else happens: no reply, no decision, no credit change. The reply
# text is never read; only the author (must be the contact we wrote to) and the attachment
# count are looked at. A user's words are evidence for a later reviewer, never instructions
# to this script.
#
# Usage:
#   intercom-verify-request.sh send --credits-file FILE --approved-by <SlackUID> \
#       [--campaign verify-live|retro-past|removal-notice|takeback-notice|uvn-status|withdrawal-confirm|status-doc-received|status-team-review|email-changed|email-changed-dup|claim-proof-ask|claim-status|gap-ask|merge-pending|credit-hold-status|claim-proof-pending] [--kind initial|reminder-14|reminder-25|after-rejection \
#        --parent-message-id <id>] [--copy v1|windowed (verify-live preview only) | queued|received (status-doc-received) | no-ask|count (status-team-review)] \
#       [--conversation <id> (uvn-status, withdrawal-confirm, status notes, claim-status, email-changed, gap-ask, merge-pending,
#        credit-hold-status, claim-proof-pending)] [--dry-run|--validate|--doc-check|--check-recipient]
#   intercom-verify-request.sh tag-proof --message-id <id> [--dry-run]
#
# In-thread delivery (firstmate 063): uvn-status and withdrawal-confirm reply IN the user's
# existing conversation when there is one, otherwise they go by email. --conversation <id>
# names it (withdrawal-confirm); uvn-status picks the contact's most recently updated OPEN
# conversation of the last 14 days on its own. The conversation must have exactly one contact,
# the one resolved from the account email, must not be assigned to a human and must carry no
# do-not-message tag (an explicit --conversation that fails is refused and recorded; a picked
# one that fails is dropped and the note goes by email); the note is then a Caroline comment
# (POST /conversations/{id}/reply),
# verified as such, and recorded in the ledger like an email note (message id = the part id).
# email-changed / email-changed-dup take their recipient from the ticket's own conversation
# instead of the account email: exactly one contact, an Intercom user whose external_id is the
# account (its professional id or Auth0 subject, see Recipient). Refusals of the status notes and
# email-changed are re-checkable per user (firstmate 082, 083): the user is held for 7 days (a
# send in that time exits 3 DEFERRED refused-recheck), cleared by a later send, flagged to
# #cs_priority and blocked (SKIPPED refused-flagged) after the third refusal.
#
# claim-proof-ask (steers-1830 #5, firstmate 125/126): a dated ask to the claimant of a pending
# profile claim (bands B/C): add the claim's code to ONE platform bio by the close day; one note
# per claim, ever, by email, plus ONE --kind reminder-7 (day 7, until the day before the close
# day). The close day is always 14 days after the note (verify_ledger.claim_close_day). FILE then
# carries "claim": {"profile_name", "profile_url", "code", "platform"} and ONE credits entry whose
# request_id is the claim key "claim-<claiming.id>" and whose profile_id (required) is the
# claimed profile's id (the other credit fields are not read).
# platform is a key of the fixed list in CLAIM_SURFACES; nothing the claimant typed is shown.
#
# claim-status (Fable claims-documentation-readiness-1023 ruling 3): the no-ask status note to the
# claimant of a pending claim who gets no proof ask (holds, organizations, no readable surface):
# "it is with our team for review". One note per claim, ever, no follow-up; never to a claim that
# has a claim-proof-ask note, never within 7 days of another note from this gate (the ledger's
# claim_cross_check). In-thread when the user has an open conversation, else email. FILE is the
# claim-proof-ask shape without code/platform (only claim.profile_name is rendered).
#
# merge-pending (program-lead-fable-p2 go-live-today section 2 D, line M1; SEND-LOCKED MERGE_PENDING_COPY_APPROVED until
# the captain's yes): a status note to someone who asked us to merge profiles. FILE carries ONE credits entry whose
# request_id is the merge key "merge-<merge request id>" and "merge": {"profiles": ["<catalog name>", ...] (1 to 4)}.
# One note per merge request, ever; never within 7 days of another note from this gate. Not an ask.
# credit-hold-status / claim-proof-pending (Fable copy-owing-proof-1027, S1/S2; captain L14a/L14b PENDING):
# the one neutral sentence for a requester who OWES proof while no ask can go out (asks are off until a
# returned document can be accepted). S1 for credit requests (status-note shape, up to 3 titles), S2 for a
# claim (claim-status shape: one claim key, claim.profile_name). Never "nothing else is needed", never an
# ask, no date: they say the request waits on the user and to wait for our next message before sending
# anything. One per user (S1) / per claim (S2), ever; never within 7 days of another note from this gate;
# S2 never to a claim with a claim-proof-ask note. SEND-LOCKED (CREDIT_HOLD_STATUS_COPY_APPROVED,
# CLAIM_PROOF_PENDING_COPY_APPROVED) until the captain's yes lands in a PR that flips the lock.
#
# FILE is JSON: {"user": {"email": "...", "id": "<muso user id>", "professional_id": "<users.neptuneProfessionalId>",
#                         "auth_id": "<auth0 subject>", "first_name": "..."},
#                "credits": [{"request_id": "...", "role": "...", "track_title": "...",
#                             "artist_name": "...", "role_families": ["producer", ...],
#                             "profile_id": "...", "track_id": "..."}, ...]}
# role_families (retro-past document lists) is a subset of mix_master producer writer
# engineer musician other; profile_id / track_id are optional references stored for the
# follow-ups' re-read. (A file, not argv, so the account email never appears in a process
# listing.)
#
# --doc-check (retro-past initial notes only) resolves the recipient and checks whether they
# already sent documents in Intercom (read only: prints DOCS <why> | NO_DOCS, writes nothing,
# sends nothing) for audits. It never reaches the claim or the POST.
#
# --check-recipient (initial notes) runs every check a real send runs up to the claim: input,
# render + leak check, the Intercom recipient (exactly one user with the account email, its
# external_id the account's), the v1 eligibility read; prints RECIPIENT OK <copy> credits=N
# or refuses. Read only: no ledger write, nothing sent. A dry run that skips this cannot see a
# recipient refusal (2026-10-20 07:00Z: all 21 first notes refused at the external_id check).
#
# user.professional_id / user.auth_id: Intercom's external_id for a Muso user is the account's
# professional id (users.neptuneProfessionalId) or its Auth0 subject (users.auth0userid, with or
# without its "auth0|" prefix), never the numeric user id; the driver passes both.
#
# Exit codes: 0 posted / tagged / nothing new to send · 1 refusal · 2 usage/environment
#             error · 3 deferred (already messaged today; follow-up not due; no proof yet) ·
#             4 post failed or the response did not verify

# TESTABLE is a BUILD-TIME literal and the deployed copy is always 0. The suite runs a
# DERIVED COPY with the line flipped to 1 (scripts/tests/intercom-verify-request.bats).
readonly TESTABLE=0
# SEND LOCKS (T06: "copy pack = captain approval before anything is sent"). Each flips to 1
# only in a PR that carries Fable's copy GO and the captain's approval of the exact rendered
# copy. While 0 the copy renders (--dry-run) but never posts.
#   LIVE_WINDOWED_COPY_APPROVED  verify-live: the windowed copy (a reply-by date and "will be removed").
#                                LOCKED (firstmate 090, 2026-10-19 23:27Z: the captain dropped
#                                auto-removal, Fable ruling 4 as amended: NO message may say a credit
#                                will be removed). Its follow-ups (day-14/25 reminders, after-rejection)
#                                follow only a windowed note, so none can be sent either. Kept for
#                                --dry-run previews only; the no-removal-language test fails if any
#                                sendable message carries removal or deadline wording.
#   RETRO_COPY_APPROVED          the retro-past no-threat ask.
readonly LIVE_WINDOWED_COPY_APPROVED=0
#   LIVE_V1_COPY_APPROVED        verify-live: Fable's no-deadline v1 copy, the ONLY copy a new credit's
#                                note is sent with (firstmate 090): no date, no removal language, no
#                                follow-ups, never removal-due. Only for a note whose every credit is
#                                a server-confirmed decider approval (verify_ledger v1-eligible).
readonly LIVE_V1_COPY_APPROVED=1
readonly RETRO_COPY_APPROVED=0
#   REMOVAL_COPY_APPROVED        the removal notice (and its one-time backfill).
#   TAKEBACK_COPY_APPROVED       the take-back notice (credit-retro apply/notify, #1237/#1242).
readonly REMOVAL_COPY_APPROVED=0
readonly TAKEBACK_COPY_APPROVED=0
#   UVN_STATUS_COPY_APPROVED     the uvn-status reminder (ops takeover section 2 class 2): APPROVED by
#       firstmate 2026-10-19 21:07Z (inbox 060, confirmed in 064) under the captain's standing order
#       2026-10-19 17:24Z (APPROVAL_REF_STANDING_ORDER below, verbatim), copy =
#       copy-uvn-status-reminder-1019 section A with firstmate's closing-line edit.
#       LOCKED 2026-10-28 12:18Z (captain, item 4): "set UVN_STATUS_COPY_APPROVED=0 ... so a proof ask cannot send
#       via that lock. Asks stay off." uvn-status IS the proof ask; until 12:18Z it was kept off only by the
#       captain's 01:0xZ order and paid-status daily.sh running it only with ASKS=1. Now the gate refuses it too.
#   Reviewed baseline: deploy overwrites - 2026-10-28 (verify-ask-wiring-h2, firstmate 072): if node-8 carries an
#       in-place edit of this lock, this blob sets it to 0, which the deploy may overwrite with.
#       UNLOCKED 2026-10-29 03:2xZ, captain U7RP6HKUZ verbatim: "use fable and i take the recommendation of it just go".
#       The recommendation he took (Fable l1 [key=l14a-retire-ask], p1 115): RETIRE the L14a "please wait for that
#       message" note (it holds users back from sending proof now that document review is live); the paid never-told
#       audience gets this ask instead, one message per user listing every open UVN request, through the go-live
#       guards and comm_state at send (only at state none / asked-with-no-reply; never to anyone who replied or sent
#       proof; no two campaigns in 7 days). No ask batch before the intake cron (#1481) is deployed.
#   Reviewed baseline: deploy overwrites - 2026-10-29 (verify-ask-wiring-h2): this blob sets UVN_STATUS_COPY_APPROVED=1.
readonly UVN_STATUS_COPY_APPROVED=1
#   WITHDRAWAL_COPY_APPROVED     withdrawal-confirm: APPROVED by firstmate 2026-10-19 21:21Z (inbox
#       061, confirmed in 064) under the same standing order; fixed text, role + title from the
#       request row only.
readonly WITHDRAWAL_COPY_APPROVED=1
#   STATUS_NOTES_COPY_APPROVED   status-doc-received (firstmate 071) and status-team-review (firstmate
#       070, verbatim): no-ask status notes for requesters whose requests are with us. APPROVED by
#       firstmate under the 2026-10-19 standing order. Never an ask; never close an ask.
readonly STATUS_NOTES_COPY_APPROVED=1
#   STATUS_RECEIVED_COPY_APPROVED  status-doc-received --copy received (proof-loop captain card R1, verbatim: the
#       approved "in our review queue" line without "no need to send anything else", so it is true for a user who
#       still owes proof). LOCKED until the captain's yes on R1 lands in a PR that flips it.
#       UNLOCKED 2026-10-28 on the captain U7RP6HKUZ 2026-10-28 14:3xZ (data/captain.md): "don't wait for me on verification work - you can move forward, i saw the plan and wording - use fable to help guide it more than me" and "use fable to make these decisions - i approve what Fable says is right" (scope: the status-message wording L14a, L14b, R1, M1); Fable ruling YES, data/program-lead-fable-p2/rulings-1028-1430.md section 1.
#   Reviewed baseline: deploy overwrites - 2026-10-28 (verify-ask-wiring-h2): this blob sets STATUS_RECEIVED_COPY_APPROVED=1.
readonly STATUS_RECEIVED_COPY_APPROVED=1
#   EMAIL_CHANGE_COPY_APPROVED   email-changed / email-changed-dup (firstmate 073): a threaded reply
#       into the requester's own conversation, once per ticket. APPROVED under the same order.
readonly EMAIL_CHANGE_COPY_APPROVED=1
#   CLAIM_PROOF_ASK_COPY_APPROVED  claim-proof-ask (steers-1830 #5): the dated code ask + day-7 reminder.
#       LOCKED until Fable approves the copy (copy-claim-proof-dated-ask-1022.md) and firstmate gives
#       the GO; firstmate 126 allowed its close day in the copy (a plain day, no time or zone), and
#       it never sends before claim-flow-fix-fable-c1's daily code check is named and running.
#       UNLOCKED 2026-10-26 ~23:59Z: Fable (flows-verify-fable-v1) ruled SEND AS-IS under the captain's
#       23:30Z proof rule (a paperwork reply goes to document checks + a person, never an auto-approval),
#       relayed in firstmate 022. The daily code check runs on node-8 (/etc/cron.d/claim-proof-check-c2).
#       LOCKED AGAIN 2026-10-27 01:1xZ (captain): "The proof ask stays off. It offers paperwork and nothing
#       can accept a valid ID yet." (01:0xZ: "Do not send a proof ask that offers paperwork until a returned
#       document can be accepted. A file on record is not a read.")
readonly CLAIM_PROOF_ASK_COPY_APPROVED=0
#   CLAIM_STATUS_COPY_APPROVED  claim-status: copy APPROVED by Fable (claims-documentation-readiness-1023
#       ruling 3, verbatim); UNLOCKED on firstmate's GO after the 5-user dry run on node-8 (2026-10-26,
#       claim-lane-resume-c2).
readonly CLAIM_STATUS_COPY_APPROVED=1
#   Reviewed baseline: deploy overwrites - 2026-10-27 (claim-lane-resume-c2, firstmate 029): node-8 carries
#       in-place edits of exactly these three locks ([key=c2-relock] 00:47Z/01:01Z, [key=docask-stop] 00:51Z,
#       captain orders 00:5xZ / 01:0xZ / 01:1xZ); this blob sets the same values (status 1, proof ask 0,
#       gap ask 0), so the deploy replaces the hot-patched file without changing behaviour.
#   GAP_ASK_COPY_APPROVED        gap-ask: Fable's paragraph (last sentence per decision B, inbox 005; APPROVAL_REF_GAP_ASK). GO'd by
#       Fable 2026-10-26 13:23Z under the captain's 12:40Z order ("Fable decides, do not ask him").
#       LOCKED 2026-10-27 01:0xZ (captain): the gap ask asks for a document, and "a file on record is not a
#       read": no ask that offers documents until a returned document can be accepted.
readonly GAP_ASK_COPY_APPROVED=0
#   MERGE_PENDING_COPY_APPROVED  merge-pending (program-lead-fable-p2 go-live-today section 2 D, line M1 verbatim):
#       LOCKED until the captain's own yes on M1 lands in a PR that flips it (copy = captain words).
readonly MERGE_PENDING_COPY_APPROVED=0
#   CREDIT_HOLD_STATUS_COPY_APPROVED  credit-hold-status (Fable copy-owing-proof-1027 S1, verbatim): LOCKED
#       until the captain's yes on L14a (ws2-captain-lifts-1027) lands in a PR that flips it.
#   CLAIM_PROOF_PENDING_COPY_APPROVED claim-proof-pending (S2, verbatim): LOCKED until the captain's yes on L14b.
readonly CREDIT_HOLD_STATUS_COPY_APPROVED=0
readonly CLAIM_PROOF_PENDING_COPY_APPROVED=0

# PINNED. Caroline (skills-all/muso-intercom/SKILL.md, Reply Identity), same literal and
# same variable name as intercom-ops-write.sh so check-intercom-reply-identity.sh keys on it.
readonly INTERCOM_ADMIN_ID="5763097"
readonly API_BASE="https://api.intercom.io"
readonly API_VERSION="2.11"
readonly PROD_LOG_DIR="/opt/hydra/workspaces/operations/api-logs"
readonly PROD_LEDGER="/var/lib/hydra/credit-review/ledger.sqlite3"
readonly PROD_LEDGER_HELPER="/opt/hydra/scripts/credit_review/verify_ledger.py"
# gap-ask reads the stage-2 verdicts (read-only) from the proof store through this helper.
readonly PROD_STAGE2_HELPER="/opt/hydra/scripts/credit_review/stage2_verdicts.py"
# Every real send first asks core whether IT told this user something lately (core_notice.py; Fable sender map
# 2026-10-27 item 2): a core notice within 7 days or a status change today defers the note.
readonly PROD_CORE_NOTICE_HELPER="/opt/hydra/scripts/credit_review/core_notice.py"
# The send-time communication-state check for the go-live cohorts (captain 2026-10-28 18:2xZ): comm_state.py.
readonly PROD_COMM_STATE_HELPER="/opt/hydra/scripts/credit_review/comm_state.py"
readonly PROD_PROOF_DB="/var/lib/hydra-credit-verify/proof.sqlite"
readonly PROOF_TAG="credit-proof"
readonly CLAIM_PROOF_TAG="claim-proof"
# The ONLY approver of these campaigns, and where he approved each.
readonly CAPTAIN_UID="U7RP6HKUZ"
readonly APPROVAL_REF_LIVE="captain U7RP6HKUZ 2026-10-15 22:12Z: \"i want AI live now - we have too many credits to approve and to get supporting data for - let users know where there was a credit given and that it needs support (trust yet verify approach)\""
readonly APPROVAL_REF_LIVE_WINDOWED="$APPROVAL_REF_LIVE; 2026-10-15 23:40Z: \"if no valid verification comes it should be removed\" (kept for new provisional approvals at 2026-10-16 00:35Z); copy = Fable copy-review-fable-2026-10-17 pack 1 (GO with edits); enable = Fable decision-verify-notify-enable-2026-10-17 (firstmate 051, 2026-10-17 23:15Z: enable Monday 2026-10-20 under its 7 conditions)"
readonly APPROVAL_REF_LIVE_V1="$APPROVAL_REF_LIVE; paid provisional approvals: Fable credit-backlog-1019 ruling 4 as amended by firstmate 073 (2026-10-19 14:58Z: provisional approve + doc request, NO day-30 auto-removal, no removal language; captain rule 10-15: deletes must confirm removal at Spotify/Tidal or prove a different profile)"
readonly APPROVAL_REF_TAKEBACK="captain via firstmate 012, 2026-10-16: every take-back sends the user a short, polite message saying which credit and role, why (who the public credits name, with the link), and how to dispute it by replying with a document."
readonly APPROVAL_REF_STANDING_ORDER="captain U7RP6HKUZ standing order 2026-10-19 17:24Z: \"are you properly communicating to everybody that's making credit request and also are you figuring out how to do profile merges that are being requested by Caroline as well make sure that you have all of the operation functions that Jan performs under your watch. I still want the guard up, but I want you to do everything based off of the research that you do and also your communications with the actual users.\""
readonly APPROVAL_REF_UVN="$APPROVAL_REF_STANDING_ORDER; copy approved by firstmate under it 2026-10-19 21:07Z (inbox 060, confirmed in 064): copy-uvn-status-reminder-1019 section A with the closing-line edit"
readonly APPROVAL_REF_WITHDRAWAL="$APPROVAL_REF_STANDING_ORDER; withdrawal-confirm copy approved by firstmate under it 2026-10-19 21:21Z (inbox 061, confirmed in 064), sent only for a request the requester withdrew (metadata.withdrawal.by = requester)"
readonly APPROVAL_REF_STATUS="$APPROVAL_REF_STANDING_ORDER; status notes approved by firstmate under it 2026-10-20 (inbox 070: team-review verbatim; 071: doc-received as credit-trust-llm-t01 drafted it). Not asks."
readonly APPROVAL_REF_STATUS_QUEUED="$APPROVAL_REF_STATUS The 'in our review queue' doc-received wording (--copy queued) approved by firstmate 092."
readonly APPROVAL_REF_STATUS_RECEIVED="$APPROVAL_REF_STATUS The receipt line R1 (--copy received: the queued line without 'no need to send anything else'), proof-loop-lead-fable-p1 captain card 2026-10-27 22:5xZ, sent only on the captain's yes."
readonly APPROVAL_REF_STATUS_COUNT="$APPROVAL_REF_STANDING_ORDER; count-only status-team-review wording (--copy count) approved by firstmate 2026-10-26 16:58Z (verify-ask-wiring-h2 inbox 005, Fable decides under the captain's 12:40Z order; captain 16:05Z: \"everyone should be communicated or credits and profiles awarded\"), for a user whose requests cannot be listed (unshowable fields or more than 1,000). Not an ask."
readonly APPROVAL_REF_STATUS_NOASK="$APPROVAL_REF_STATUS The no-ask team-review wording B0 (--copy no-ask: Copy B without its optional proof sentence) approved by firstmate 2026-10-21 (credit-trust-llm-t01 key pending-status-1021, relayed in inbox 106)."
readonly APPROVAL_REF_EMAIL_CHANGE="$APPROVAL_REF_STANDING_ORDER; email-changed templates approved by firstmate under it 2026-10-20 00:55Z (inbox 073): a threaded reply into the requester's own conversation, once per ticket, no customer-typed content."
readonly APPROVAL_REF_CLAIM_STATUS="Fable claims-documentation-readiness-1023 ruling 3 (2026-10-23 19:15Z): claim status note APPROVED as drafted, scope narrowed to pending claimants who get no proof ask within 7 days; captain 2026-10-26 16:05Z: everyone with a pending claim is approved or told its status; firstmate claim-lane-resume-c2 005: option A."
readonly APPROVAL_REF_CLAIM_ASK="Fable program lead steers-1830 #5 (relayed by firstmate 125, 2026-10-22 19:43Z): dated proof ask for claim bands B/C, copy approved by Fable; firstmate 126 (2026-10-22 20:01Z): the close day is allowed for claim-proof-ask only, as a plain day; no send until claim-flow-fix-fable-c1's daily code check runs."
# claim-proof-ask: the platform keys the binding resolver may name, and the ONLY words the note
# uses for each ("add the code ... to your <surface>"). ONLY surfaces claim-flow-fix-fable-c1's
# daily check can actually read (c1 2026-10-22, measured on the 112 paid claims): the Spotify
# artist bio, a website (/.well-known/muso.txt or a muso-verify meta tag) and the YouTube channel
# About section. Instagram (login wall), X/TikTok (no post-link endpoint yet) and anything else
# are refused: "we check for it every day" must be true for the surface we name.
CLAIM_SURFACES='{"spotify": "Spotify artist bio", "website": "website (as one line in a file at /.well-known/muso.txt, or in a meta tag named muso-verify)", "youtube": "YouTube channel About section"}'
readonly CLAIM_SURFACES
readonly APPROVAL_REF_GAP_ASK="captain U7RP6HKUZ 2026-10-26 12:40Z: Fable decides, do not ask him; ~13:00Z: \"credit and profile verifications nothing is waiting on us right? you are moving these forward and ball should be in users court if required otherwise they are approved? if not get on this\"; Fable ruling 2026-10-26 13:23Z (captain-asks-fable-r4 report section H, GO 2): 460 need_more -> dated gap ask, one per user per day, Fable-approved paragraph, no deadline, no removal words; last sentence swapped to \"Your request stays open while we look.\" (the asked rows are pending, not live) by Fable decision (B) relayed by firstmate 2026-10-26 16:58Z (verify-ask-wiring-h2 inbox 005)"
readonly APPROVAL_REF_MERGE_PENDING="captain 2026-10-28 12:4xZ: \"go live today and start conversations with users who requested credits, profiles (claims) or merges ASAP\"; copy = program-lead-fable-p2 go-live-today line M1, sent only on the captain's own yes to M1"
readonly APPROVAL_REF_OWING_PROOF="captain U7RP6HKUZ 2026-10-27 20:1xZ: \"are you sure all users that need to be communicated have been already? If not get on it - make this a durable process that does not rely on my computer; do this all on OVH.\"; copy = Fable verify-program-lead-fable-l1 copy-owing-proof-1027 (20:2xZ), sent only on the captain's yes (L14a S1 credit-hold-status / L14b S2 claim-proof-pending)"
readonly APPROVAL_REF_REMOVAL="firstmate 2026-10-16 15:14Z, captain-driven: owners of credits WE removed must be told which credit and role, why, and how to dispute by replying with a document (support measured 35 owners never told). Fraud removals stay silent by captain order (firstmate 2026-10-16 15:48Z)."
readonly APPROVAL_REF_PAST="captain U7RP6HKUZ 2026-10-15 23:35Z: \"im referring to before when nick made changes and did a trust verify flow and now we have a lotnof credits to verify with documents and give people 30 days to send something in for the ones missing documents\"; 2026-10-16 00:35Z: \"how many credits were approved without documentstion i dont want to lose users unless its obvious fraud feom tbe past\""
# Caroline's outbound sanitizer word list, IDENTICAL to intercom-ops-write.sh's
# SANITIZER_WORDS (which CI compares to plugins/intercom/src/sanitize-tool-leak.ts);
# scripts/tests/intercom-verify-request.bats fails if the two lines ever differ.
# Conversation tags that mean "do not auto-message here" (same set as resolve-notify.py and
# resolution-matcher.py); an in-thread note is never posted into a conversation carrying one.
readonly BLOCKED_CONV_TAGS="abuse-block instagram facebook twitter x whatsapp messenger tiktok sms"
readonly SANITIZER_WORDS="profile_status|profile_lookup|credits_search|create_ticket|subscription_status|remove_credits|dedupe_check|credit_verification_check|profiles_claim_self|credits_verify|profiles_consolidate|order_lookup|order_address_update|founding_status|founding_buyback_link|support_action_router|memory_search|memory_get|profile_analytics_status|profile_credits_status|profile_claim_status|retention_offer_check|retention_offer_apply|cancel_subscription|billing_status|track_analytics_status|analytics_refresh_request|analytics_recheck|subscription_cancel|refund_policy_check|refund_create|catalog_status|track_lookup|metadata_capture_request|artwork_refresh_request|catalog_recheck|user_status|resend_verification|email_delivery_status|login_recovery_packet|profile_change_packet|profile_merge_check|account_merge_preflight|email_change_preflight|profile_removal_preflight|ticket|tool failed|error fetching|unable to look up|the system says|my system|there was an issue with|ClickUp|openclaw|HYDRA|platform-data-processing"

die()    { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
refuse() { printf 'REFUSED: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------------------
# Deployed copies reject EVERY override before anything else can run.
if [ "$TESTABLE" != "1" ]; then
  for v in INTERCOM_VERIFY_TEST_LOG_DIR INTERCOM_VERIFY_TEST_CURL_BIN INTERCOM_VERIFY_TEST_TIMEOUT_BIN \
           INTERCOM_VERIFY_TEST_LEDGER INTERCOM_VERIFY_TEST_LEDGER_HELPER INTERCOM_VERIFY_TEST_DAY \
           INTERCOM_VERIFY_TEST_PROOF_DB INTERCOM_VERIFY_TEST_STAGE2_HELPER INTERCOM_VERIFY_TEST_CORE_NOTICE_HELPER INTERCOM_VERIFY_TEST_NOW INTERCOM_VERIFY_TEST_DISABLED_DIR INTERCOM_VERIFY_TEST_COMM_STATE_HELPER; do
    [ -z "${!v:-}" ] || die "$v is not settable on a deployed copy of this script. The log, the ledger, the client and the clock are not parameters: a caller-selectable one is a send nobody can audit."
  done
  LOG_DIR="$PROD_LOG_DIR"
  LEDGER="$PROD_LEDGER"
  LEDGER_HELPER="$PROD_LEDGER_HELPER"
  STAGE2_HELPER="$PROD_STAGE2_HELPER"
  DISABLED_DIR="/etc/hydra"
  CORE_NOTICE_HELPER="$PROD_CORE_NOTICE_HELPER"
  COMM_STATE_HELPER="$PROD_COMM_STATE_HELPER"
  PROOF_DB="$PROD_PROOF_DB"
  CURL_BIN="/usr/bin/curl"
  JQ_BIN="/usr/bin/jq"
  TIMEOUT_BIN="/usr/bin/timeout"
  PY_BIN="/usr/bin/python3"
  DAY="$(date -u +%Y-%m-%d)"
else
  LOG_DIR="${INTERCOM_VERIFY_TEST_LOG_DIR:-$PROD_LOG_DIR}"
  LEDGER="${INTERCOM_VERIFY_TEST_LEDGER:-$PROD_LEDGER}"
  LEDGER_HELPER="${INTERCOM_VERIFY_TEST_LEDGER_HELPER:-$PROD_LEDGER_HELPER}"
  STAGE2_HELPER="${INTERCOM_VERIFY_TEST_STAGE2_HELPER:-$PROD_STAGE2_HELPER}"
  DISABLED_DIR="${INTERCOM_VERIFY_TEST_DISABLED_DIR:-/etc/hydra}"
  CORE_NOTICE_HELPER="${INTERCOM_VERIFY_TEST_CORE_NOTICE_HELPER:-$PROD_CORE_NOTICE_HELPER}"
  COMM_STATE_HELPER="${INTERCOM_VERIFY_TEST_COMM_STATE_HELPER:-$PROD_COMM_STATE_HELPER}"
  PROOF_DB="${INTERCOM_VERIFY_TEST_PROOF_DB:-$PROD_PROOF_DB}"
  CURL_BIN="${INTERCOM_VERIFY_TEST_CURL_BIN:-$(command -v curl || echo /usr/bin/curl)}"
  JQ_BIN="$(command -v jq || echo /usr/bin/jq)"
  TIMEOUT_BIN="${INTERCOM_VERIFY_TEST_TIMEOUT_BIN:-$(command -v timeout || command -v gtimeout || echo /usr/bin/timeout)}"
  PY_BIN="$(command -v python3 || echo /usr/bin/python3)"
  DAY="${INTERCOM_VERIFY_TEST_DAY:-$(date -u +%Y-%m-%d)}"
fi
readonly LOG_DIR LEDGER LEDGER_HELPER STAGE2_HELPER CORE_NOTICE_HELPER PROOF_DB CURL_BIN JQ_BIN TIMEOUT_BIN PY_BIN DAY

# ---------------------------------------------------------------------------------------
# Arguments
usage() {
  sed -n '/^# Usage:/,/^# Exit codes/p' "$0" | sed 's/^# \{0,1\}//' >&2
}

[ $# -ge 1 ] || { usage; die "missing subcommand (send | tag-proof)"; }
MODE="$1"; shift
case "$MODE" in
  send|tag-proof) ;;
  -h|--help) usage; exit 0 ;;
  *) usage; die "unknown subcommand '$MODE' (send | tag-proof). This wrapper only sends the fixed verify notes and tags proof replies; it never replies, decides, approves, rejects or removes anything." ;;
esac

# Email through Intercom (POST /messages, message_type email): Intercom delivers it to the
# user's inbox and the reply lands in the same conversation. The one other channel is a
# Caroline comment in the user's own conversation (in-thread delivery, above).
CREDITS_FILE="" APPROVED_BY="" MESSAGE_ID="" ACTION="post" THREAD="" THREAD_AUTO=0
MESSAGE_TYPE="email"
readonly REQ_TYPE="email" EXPECT_TYPE="email"
CAMPAIGN="verify-live" KIND="initial" PARENT_ID="" CAMPAIGN_SET=0 KIND_SET=0 COPY_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --credits-file|--approved-by|--message-id|--campaign|--kind|--parent-message-id|--copy|--conversation)
      [ $# -ge 2 ] || { usage; die "$1 needs a value"; }
      case "$1" in
        --credits-file)      CREDITS_FILE="$2" ;;
        --approved-by)       APPROVED_BY="$2" ;;
        --message-id)        MESSAGE_ID="$2" ;;
        --campaign)          CAMPAIGN="$2"; CAMPAIGN_SET=1 ;;
        --kind)              KIND="$2"; KIND_SET=1 ;;
        --parent-message-id) PARENT_ID="$2" ;;
        --copy)              COPY_ARG="$2" ;;
        --conversation)      THREAD="$2" ;;
      esac
      shift 2 ;;
    --dry-run)  ACTION="dry-run"; shift ;;
    --doc-check) ACTION="doc-check"; shift ;;
    --thread-contact) ACTION="thread-contact"; shift ;;
    --check-recipient) ACTION="check-recipient"; shift ;;
    --validate) ACTION="validate"; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) usage; die "unknown argument '$1'" ;;
  esac
done

# ---------------------------------------------------------------------------------------
# Environment
for b in "$JQ_BIN" "$PY_BIN"; do
  [ -x "$b" ] || die "$b is missing or not executable; it is a required dependency."
done
if [ "$ACTION" = "post" ] || [ "$ACTION" = "doc-check" ] || [ "$ACTION" = "thread-contact" ] || [ "$ACTION" = "check-recipient" ] \
   || [ "$MODE" = "tag-proof" ]; then
  [ -n "${MUSOAI_INTERCOM_TOKEN:-}" ] || die "MUSOAI_INTERCOM_TOKEN is not set. The gateway exports it from /etc/openclaw/main.env; on a shell: set -a; . /etc/openclaw/main.env; set +a"
  for b in "$CURL_BIN" "$TIMEOUT_BIN"; do
    [ -x "$b" ] || die "$b is missing or not executable; it is a required dependency."
  done
  [ -r "$LEDGER_HELPER" ] || die "ledger helper $LEDGER_HELPER is missing; refusing to send without the idempotency ledger."
fi

# ledger <op> [args...]: one JSON line on stdout. -I (isolated) so PYTHON* env cannot
# redirect the helper on a deployed copy.
ledger() { "$PY_BIN" -I "$LEDGER_HELPER" --db "$LEDGER" "$@"; }

# api METHOD PATH [payload-on-stdin]: the response body on stdout, curl rc as the status.
# The payload travels through STDIN, never argv (MAX_ARG_STRLEN; see intercom-ops-write.sh).
api() {
  local method="$1" path="$2"
  if [ "$method" = "GET" ]; then
    "$TIMEOUT_BIN" 45 "$CURL_BIN" -sS -X GET \
      -H "Authorization: Bearer $MUSOAI_INTERCOM_TOKEN" -H "Accept: application/json" \
      -H "Intercom-Version: $API_VERSION" "$API_BASE$path" 2>&1
  else
    "$TIMEOUT_BIN" 45 "$CURL_BIN" -sS -X "$method" \
      -H "Authorization: Bearer $MUSOAI_INTERCOM_TOKEN" -H "Accept: application/json" \
      -H "Content-Type: application/json" -H "Intercom-Version: $API_VERSION" \
      --data @- "$API_BASE$path" 2>&1
  fi
}

new_log_file() { # <kind> <target>
  mkdir -p "$LOG_DIR" || die "cannot create log dir $LOG_DIR; refusing to write unlogged."
  printf '%s/intercom-%s-%s-%s-%s.json' "$LOG_DIR" "$1" "$2" "$(date -u +%Y%m%dT%H%M%SZ)" "$$"
}

# =======================================================================================
# tag-proof
if [ "$MODE" = "tag-proof" ]; then
  [ -z "$CREDITS_FILE$APPROVED_BY$PARENT_ID$COPY_ARG$THREAD" ] && [ "$CAMPAIGN_SET$KIND_SET" = "00" ] \
    || refuse "tag-proof takes only --message-id; it sends nothing to the user."
  [ "$ACTION" != "validate" ] && [ "$ACTION" != "doc-check" ] && [ "$ACTION" != "thread-contact" ] \
    && [ "$ACTION" != "check-recipient" ] \
    || refuse "--validate, --doc-check, --thread-contact and --check-recipient apply to send only."
  printf '%s' "$MESSAGE_ID" | grep -qE '^[0-9]{1,24}$' \
    || refuse "--message-id must be the numeric Intercom message id of a verify note (got '${MESSAGE_ID:-<empty>}')."
  ROW="$(ledger message --message-id "$MESSAGE_ID")"
  [ "$ROW" != "null" ] || refuse "message $MESSAGE_ID is not a sent verify note in the ledger; only conversations this wrapper started can be tagged."
  CONTACT_ID="$(printf '%s' "$ROW" | "$JQ_BIN" -r '.contact_id // empty')"
  [ -n "$CONTACT_ID" ] || refuse "message $MESSAGE_ID has no recorded contact; cannot tell the user's reply from anyone else's."
  TAG="$PROOF_TAG"
  case "$(printf '%s' "$ROW" | "$JQ_BIN" -r '.campaign // empty')" in claim-proof-ask|claim-status|claim-proof-pending) TAG="$CLAIM_PROOF_TAG" ;; esac
  CONV="$(printf '%s' "$ROW" | "$JQ_BIN" -r '.conversation_id // empty')"
  if [ -z "$CONV" ]; then
    # No conversation id came back with the send: Intercom opens it when the user replies.
    found="$(printf '%s' "{\"query\":{\"field\":\"source.id\",\"operator\":\"=\",\"value\":\"$MESSAGE_ID\"}}" | api POST /conversations/search)" \
      || { printf 'LOOKUP FAILED for message %s:\n%s\n' "$MESSAGE_ID" "$found" >&2; exit 4; }
    n="$(printf '%s' "$found" | "$JQ_BIN" -r 'if (.conversations | type) == "array" then (.conversations | length) else "x" end' 2>/dev/null || echo x)"
    case "$n" in
      0) printf 'NO REPLY YET message=%s\n' "$MESSAGE_ID"; exit 3 ;;
      1) CONV="$(printf '%s' "$found" | "$JQ_BIN" -r '.conversations[0].id')" ;;
      *) printf 'LOOKUP NOT VERIFIED for message %s: expected 0 or 1 conversation, got %s\n' "$MESSAGE_ID" "$n" >&2; exit 4 ;;
    esac
    printf '%s' "$CONV" | grep -qE '^[0-9]+$' || { echo "LOOKUP NOT VERIFIED: conversation id '$CONV' is not numeric" >&2; exit 4; }
    ledger set-conversation --message-id "$MESSAGE_ID" --conversation-id "$CONV" >/dev/null
  fi
  convo="$(api GET "/conversations/$CONV?display_as=plaintext")" \
    || { printf 'READ FAILED for conversation %s:\n%s\n' "$CONV" "$convo" >&2; exit 4; }
  # A 2xx that is not a readable conversation (no id, or no conversation_parts list) proves
  # nothing about replies: it must never read as "no reply" (exit 3), which would let a day-7
  # reminder go to a claimant whose reply we could not see (QA on #1330). Fail closed.
  printf '%s' "$convo" | "$JQ_BIN" -e '(type == "object") and ((.id // "") | tostring | length > 0)
      and ((.conversation_parts | type) == "object") and ((.conversation_parts.conversation_parts | type) == "array")' >/dev/null 2>&1 \
    || { printf 'READ NOT VERIFIED for conversation %s: the response has no id or no conversation_parts list:\n%s\n' "$CONV" "$(printf '%s' "$convo" | head -c 300)" >&2; exit 4; }
  # The conversation must be the one our note started, or (in-thread delivery) hold our note
  # as a Caroline part. Only parts AFTER the note count below.
  src="$(printf '%s' "$convo" | "$JQ_BIN" -r '.source.id // empty' 2>/dev/null || true)"
  if [ "$src" = "$MESSAGE_ID" ]; then
    FROM=0
  else
    FROM="$(printf '%s' "$convo" | "$JQ_BIN" -r --arg m "$MESSAGE_ID" --arg a "$INTERCOM_ADMIN_ID" \
      '(.conversation_parts.conversation_parts // []) as $p | ([$p[] | .id | tostring] | index($m)) as $i
       | if $i != null and ($p[$i].author.type // "") == "admin" and (($p[$i].author.id // "") | tostring) == $a then $i + 1 else empty end' 2>/dev/null || true)"
    [ -n "$FROM" ] || refuse "conversation $CONV was not started by verify note $MESSAGE_ID and does not hold it as a Caroline part (source '${src:-<none>}'); not tagging it."
  fi
  convo="$(printf '%s' "$convo" | "$JQ_BIN" -c --argjson from "$FROM" '.conversation_parts.conversation_parts = ((.conversation_parts.conversation_parts // [])[$from:])')"
  # ANY reply authored by the contact we wrote to (text or attachment; only the author is
  # looked at, never the text) holds the note's removal for a human: the user may be asking
  # for more time. The latest reply's own time is recorded per message, so a reply after an
  # after-rejection note is seen too.
  n_replies="$(printf '%s' "$convo" | "$JQ_BIN" -r --arg c "$CONTACT_ID" \
    '[(.conversation_parts.conversation_parts // [])[] | select(.author.type == "user" and (.author.id|tostring) == $c)] | length')"
  REPLIED_AT="$(printf '%s' "$convo" | "$JQ_BIN" -r --arg c "$CONTACT_ID" \
    '[(.conversation_parts.conversation_parts // [])[] | select(.author.type == "user" and (.author.id|tostring) == $c) | .created_at | numbers] | max // empty | floor | todate')"
  if [ "${n_replies:-0}" -gt 0 ] && [ "$ACTION" != "dry-run" ]; then
    held="$(ledger mark-replied --message-id "$MESSAGE_ID" ${REPLIED_AT:+--replied-at "$REPLIED_AT"})" || die "the ledger write failed."
    if [ "$(printf '%s' "$held" | "$JQ_BIN" -r '.result')" = "recorded" ]; then
      if [ "$TAG" = "$CLAIM_PROOF_TAG" ]; then
        printf 'REPLY RECORDED message=%s conversation=%s (no day-7 reminder; with a person)\n' "$MESSAGE_ID" "$CONV"
      else
        printf 'REPLY RECORDED message=%s conversation=%s (removal held for a human)\n' "$MESSAGE_ID" "$CONV"
      fi
    fi
  fi
  if [ -n "$(printf '%s' "$ROW" | "$JQ_BIN" -r '.proof_tagged_at // empty')" ]; then
    printf 'ALREADY TAGGED message=%s\n' "$MESSAGE_ID"; exit 0
  fi
  # Only parts AUTHORED BY the contact we wrote to, carrying attachments, count. The text of
  # the part is never extracted: it is evidence for a reviewer, not input to this script.
  n_att="$(printf '%s' "$convo" | "$JQ_BIN" -r --arg c "$CONTACT_ID" \
    '[(.conversation_parts.conversation_parts // [])[] | select(.author.type == "user" and (.author.id|tostring) == $c) | (.attachments // [] | length)] | add // 0')"
  # After a REJECTED review only attachments beyond the ones already reviewed count. A claim
  # note's reply goes to the claim-proof queue for a person whatever it carries, text included.
  BASELINE="$(printf '%s' "$ROW" | "$JQ_BIN" -r '.proof_attachments // 0')"
  if [ "$TAG" = "$CLAIM_PROOF_TAG" ]; then
    [ "${n_replies:-0}" -gt 0 ] || { printf 'NO PROOF YET message=%s conversation=%s\n' "$MESSAGE_ID" "$CONV"; exit 3; }
  elif [ "${n_att:-0}" -le "${BASELINE:-0}" ]; then
    printf 'NO PROOF YET message=%s conversation=%s\n' "$MESSAGE_ID" "$CONV"; exit 3
  fi
  if [ "$ACTION" = "dry-run" ]; then
    printf 'DRY-RUN tag %s conversation=%s attachments=%s\n' "$TAG" "$CONV" "$n_att"; exit 0
  fi
  tags="$(api GET /tags)" || { printf 'READ FAILED for tags:\n%s\n' "$tags" >&2; exit 4; }
  TAG_ID="$(printf '%s' "$tags" | "$JQ_BIN" -r --arg n "$TAG" '[(.data // [])[] | select(((.name // "")|ascii_downcase) == $n) | .id][0] // empty')"
  LOG_FILE="$(new_log_file tag "$CONV")"
  "$JQ_BIN" -nc --arg target "conversation:$CONV" --arg mid "$MESSAGE_ID" --arg tag "$TAG" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg n "$n_att" \
    '{agent:"operations", action:("intercom_tag_" + ($tag | gsub("-"; "_"))), target:$target, verify_message:$mid, tag:$tag, attachments:($n|tonumber), timestamp:$ts, authorization:"verify-request proof routing: tag only, no reply, no decision"}' > "$LOG_FILE"
  if [ -z "$TAG_ID" ]; then
    created="$(printf '{"name":"%s"}' "$TAG" | api POST /tags)" || { printf 'TAG CREATE FAILED:\n%s\n' "$created" >&2; exit 4; }
    TAG_ID="$(printf '%s' "$created" | "$JQ_BIN" -r 'select(.type == "tag") | .id // empty' 2>/dev/null || true)"
    [ -n "$TAG_ID" ] || { printf 'TAG CREATE NOT VERIFIED:\n%s\n' "$created" >&2; exit 4; }
  fi
  resp="$("$JQ_BIN" -nc --arg id "$TAG_ID" --arg a "$INTERCOM_ADMIN_ID" '{id:$id, admin_id:$a}' | api POST "/conversations/$CONV/tags")" \
    || { printf 'TAG FAILED for conversation %s; logged at %s:\n%s\n' "$CONV" "$LOG_FILE" "$resp" >&2; exit 4; }
  got="$(printf '%s' "$resp" | "$JQ_BIN" -r 'select(.type == "tag") | .name // empty' 2>/dev/null || true)"
  if [ "$(printf '%s' "$got" | tr '[:upper:]' '[:lower:]')" != "$TAG" ]; then
    printf 'TAG NOT VERIFIED for conversation %s; logged at %s. Response:\n%s\n' "$CONV" "$LOG_FILE" "$resp" >&2; exit 4
  fi
  ledger mark-tagged --message-id "$MESSAGE_ID" --conversation-id "$CONV" --attachments "$n_att" >/dev/null
  printf 'TAGGED %s conversation=%s message=%s attachments=%s\n' "$TAG" "$CONV" "$MESSAGE_ID" "$n_att"
  exit 0
fi

# =======================================================================================
# send: validation. Every refusal says how to comply.
[ -z "$MESSAGE_ID" ] || refuse "--message-id applies to tag-proof only."
[ "$ACTION" != "doc-check" ] || [ "$KIND" = "initial" ] || refuse "--doc-check applies to an initial note."
case "$KIND" in
  initial|reminder-14|reminder-25|after-rejection|reminder-7) ;;
  *) refuse "--kind must be initial, reminder-14, reminder-25, after-rejection or reminder-7 (got '$KIND')." ;;
esac
if [ "$CAMPAIGN" = "claim-proof-ask" ]; then
  case "$KIND" in initial|reminder-7) ;; *) refuse "claim-proof-ask has one follow-up, --kind reminder-7." ;; esac
elif [ "$KIND" = "reminder-7" ]; then
  refuse "--kind reminder-7 applies to claim-proof-ask only."
fi
[ "$CAMPAIGN" != "claim-status" ] || [ "$KIND" = "initial" ] || refuse "claim-status has no follow-ups (one note per claim)."
[ "$CAMPAIGN" != "claim-proof-pending" ] || [ "$KIND" = "initial" ] || refuse "claim-proof-pending has no follow-ups (one note per claim)."

# COPY: which fixed text this message uses.
#   verify-live  windowed (every real send) | v1 (preview only)
#   retro-past   past           (no deadline, no removal language, no follow-up)
case "$CAMPAIGN" in
  verify-live)
    MAX_CREDITS=200; MAX_LISTED=25
    case "$COPY_ARG" in ""|v1|windowed) ;; *) refuse "--copy must be v1 or windowed (got '$COPY_ARG')." ;; esac
    if [ "$ACTION" = "post" ] && [ "$KIND" = "initial" ] && [ "$COPY_ARG" != "windowed" ]; then
      # firstmate 090: every new credit's note is the no-threat v1 note, never removal-due.
      [ "$LIVE_V1_COPY_APPROVED" = "1" ] || refuse "the verify-live v1 copy is not approved for sending (LIVE_V1_COPY_APPROVED=0)."
      COPY="v1"
    elif [ "$ACTION" = "post" ]; then
      [ "$LIVE_WINDOWED_COPY_APPROVED" = "1" ] \
        || refuse "no verify-live message may name a deadline or say a credit will be removed (firstmate 090: the captain dropped auto-removal). The windowed note and its follow-ups are send-locked (LIVE_WINDOWED_COPY_APPROVED=0); a new credit's note is the v1 copy."
      [ "$KIND" != "initial" ] || [ "$COPY_ARG" = "windowed" ] || refuse "internal: unexpected copy '$COPY_ARG'."
      COPY="windowed"
    elif [ "$KIND" != "initial" ]; then
      [ "$COPY_ARG" != "v1" ] || refuse "the v1 copy names no date and has no follow-ups; preview follow-ups with --copy windowed."
      COPY="windowed"
    else
      COPY="${COPY_ARG:-v1}"   # a preview shows what is sent: v1 (firstmate 090)
    fi
    if [ "$COPY" = "windowed" ]; then APPROVAL_REF="$APPROVAL_REF_LIVE_WINDOWED"; else APPROVAL_REF="$APPROVAL_REF_LIVE_V1"; fi
    ;;
  retro-past)
    MAX_CREDITS=1000; MAX_LISTED=100; COPY="past"; APPROVAL_REF="$APPROVAL_REF_PAST"
    [ -z "$COPY_ARG" ] || refuse "--copy applies to verify-live; retro-past has one copy, with no deadline and no removal."
    [ "$KIND" = "initial" ] || refuse "retro-past has no follow-ups: a past credit's owner gets at most one message, ever."
    ;;
  removal-notice)
    MAX_CREDITS=1000; MAX_LISTED=20; COPY="removal"; APPROVAL_REF="$APPROVAL_REF_REMOVAL"
    [ -z "$COPY_ARG" ] || refuse "--copy applies to verify-live."
    [ "$KIND" = "initial" ] || refuse "removal-notice has no follow-ups."
    ;;
  takeback-notice)
    MAX_CREDITS=1000; MAX_LISTED=25; COPY="takeback"; APPROVAL_REF="$APPROVAL_REF_TAKEBACK"
    [ "$KIND" = "initial" ] || refuse "takeback-notice has no follow-ups."
    ;;
  uvn-status)
    # A status + reminder for credit requests waiting on the user (user_verification_needed):
    # one message per user, ever; never to a user who sent documents; never within 7 days of
    # another message. Up to 3 titles in the copy, then "and N more".
    MAX_CREDITS=1000; MAX_LISTED=3; COPY="uvn"; APPROVAL_REF="$APPROVAL_REF_UVN"
    [ -z "$COPY_ARG" ] || refuse "--copy applies to verify-live."
    [ "$KIND" = "initial" ] || refuse "uvn-status has no follow-ups: one message per user, ever."
    ;;
  withdrawal-confirm)
    # Confirms a credit request the requester asked us to withdraw: one request per message,
    # role + title from the request row. Not an ask; no follow-ups.
    MAX_CREDITS=1; MAX_LISTED=1; COPY="withdrawal"; APPROVAL_REF="$APPROVAL_REF_WITHDRAWAL"
    [ -z "$COPY_ARG" ] || refuse "--copy applies to verify-live."
    [ "$KIND" = "initial" ] || refuse "withdrawal-confirm has no follow-ups."
    ;;
  status-doc-received|status-team-review)
    # No-ask status notes (firstmate 070/071): one per user, ever; up to 3 titles.
    MAX_CREDITS=1000; MAX_LISTED=3; APPROVAL_REF="$APPROVAL_REF_STATUS"
    if [ "$CAMPAIGN" = "status-doc-received" ]; then COPY="docrecv"; else COPY="teamreview"; fi
    # Approved alternative wordings: status-doc-received --copy queued (firstmate 092);
    # status-team-review --copy no-ask = Copy B0 (pending-status-1021, firstmate 106).
    case "$CAMPAIGN:$COPY_ARG" in
      *:) ;;
      status-doc-received:queued) COPY="docrecvq"; APPROVAL_REF="$APPROVAL_REF_STATUS_QUEUED" ;;
      # Card R1 (proof loop): the receipt for a user who still owes proof; send-locked (STATUS_RECEIVED_COPY_APPROVED).
      status-doc-received:received) COPY="docrecvr"; APPROVAL_REF="$APPROVAL_REF_STATUS_RECEIVED" ;;
      status-team-review:no-ask) COPY="teamreviewb0"; APPROVAL_REF="$APPROVAL_REF_STATUS_NOASK" ;;
      # Count-only (firstmate inbox 005): no titles, so any request may be in it; the ledger
      # records the ids given (the driver sends at most 1,000) and user.pending_count is the total.
      status-team-review:count) COPY="teamreviewcount"; APPROVAL_REF="$APPROVAL_REF_STATUS_COUNT"; MAX_CREDITS=1000 ;;
      *) refuse "--copy applies to verify-live (v1|windowed), status-doc-received (queued|received) and status-team-review (no-ask|count) only." ;;
    esac
    [ "$KIND" = "initial" ] || refuse "$CAMPAIGN has no follow-ups: one message per user, ever."
    ;;
  email-changed|email-changed-dup)
    # A threaded reply that an account's sign-in email change is done (firstmate 073). The one
    # "credit" entry carries only the ticket key (request_id) used for once-per-ticket.
    MAX_CREDITS=1; MAX_LISTED=1; APPROVAL_REF="$APPROVAL_REF_EMAIL_CHANGE"
    if [ "$CAMPAIGN" = "email-changed" ]; then COPY="emailchg"; else COPY="emailchgdup"; fi
    [ -z "$COPY_ARG" ] || refuse "--copy applies to verify-live."
    [ "$KIND" = "initial" ] || refuse "$CAMPAIGN has no follow-ups."
    ;;
  claim-proof-ask)
    # The dated claim ask (firstmate 125/126): one claim per message, by email only.
    MAX_CREDITS=1; MAX_LISTED=1; APPROVAL_REF="$APPROVAL_REF_CLAIM_ASK"
    if [ "$KIND" = "initial" ]; then COPY="claimask"; else COPY="claimask7"; fi
    [ -z "$COPY_ARG" ] || refuse "--copy applies to verify-live and the status notes."
    [ -z "$THREAD" ] || refuse "claim-proof-ask goes by email only (the close day is in the subject line's note)."
    ;;
  claim-status)
    # The claim status note (Fable 1023 ruling 3): one claim per message; in-thread or email.
    MAX_CREDITS=1; MAX_LISTED=1; APPROVAL_REF="$APPROVAL_REF_CLAIM_STATUS"; COPY="claimstatus"
    [ -z "$COPY_ARG" ] || refuse "--copy applies to verify-live and the status notes."
    ;;
  merge-pending)
    # Line M1: one merge request per message; status only.
    MAX_CREDITS=1; MAX_LISTED=1; COPY="mergepending"; APPROVAL_REF="$APPROVAL_REF_MERGE_PENDING"
    [ -z "$COPY_ARG" ] || refuse "--copy applies to verify-live and the status notes; merge-pending has one copy, line M1."
    [ "$KIND" = "initial" ] || refuse "merge-pending has no follow-ups: one note per merge request, ever."
    ;;
  credit-hold-status)
    # Fable S1 (copy-owing-proof-1027): a requester who owes proof, while no ask can go out. One per
    # user, ever; up to 3 titles. Not an ask, never "nothing else is needed".
    MAX_CREDITS=1000; MAX_LISTED=3; COPY="credithold"; APPROVAL_REF="$APPROVAL_REF_OWING_PROOF"
    [ -z "$COPY_ARG" ] || refuse "--copy applies to verify-live and the status notes; credit-hold-status has one copy, Fable's S1."
    [ "$KIND" = "initial" ] || refuse "credit-hold-status has no follow-ups: one message per user, ever."
    ;;
  claim-proof-pending)
    # Fable S2 (copy-owing-proof-1027): a claim that needs proof, while the claim ask is off. One per claim.
    MAX_CREDITS=1; MAX_LISTED=1; COPY="claimpending"; APPROVAL_REF="$APPROVAL_REF_OWING_PROOF"
    [ -z "$COPY_ARG" ] || refuse "--copy applies to verify-live and the status notes; claim-proof-pending has one copy, Fable's S2."
    [ "$KIND" = "initial" ] || refuse "claim-proof-pending has no follow-ups (one note per claim)."
    ;;
  gap-ask)
    # Fable's gap ask for credits whose document on file does not cover them (stage-2
    # need_more). Once per credit; up to 3 track/role pairs, then "and N more".
    MAX_CREDITS=1000; MAX_LISTED=3; COPY="gap"; APPROVAL_REF="$APPROVAL_REF_GAP_ASK"
    [ -z "$COPY_ARG" ] || refuse "--copy applies to verify-live; gap-ask has one copy, Fable's paragraph."
    [ "$KIND" = "initial" ] || refuse "gap-ask has no follow-ups: no deadline, no reminders."
    ;;
  *) refuse "--campaign must be verify-live, retro-past, removal-notice, takeback-notice, uvn-status, withdrawal-confirm, status-doc-received, status-team-review, email-changed, email-changed-dup, claim-proof-ask, claim-status, gap-ask, merge-pending, credit-hold-status or claim-proof-pending (got '$CAMPAIGN'). Each campaign is pinned in this script; there is no other." ;;
esac
[ "$ACTION" != "check-recipient" ] || { [ "$CAMPAIGN" = "verify-live" ] && [ "$KIND" = "initial" ]; } \
  || refuse "--check-recipient applies to a verify-live initial note only (it must never reach a path that writes)."
[ "$ACTION" != "doc-check" ] || [ "$CAMPAIGN" = "retro-past" ] \
  || refuse "--doc-check applies to --campaign retro-past only: a removal notice is not an ask, and a new credit's note is never skipped for an Intercom attachment."
if [ -n "$THREAD" ]; then
  case "$CAMPAIGN" in
    uvn-status|withdrawal-confirm|status-doc-received|status-team-review|email-changed|email-changed-dup|claim-status|gap-ask|merge-pending|credit-hold-status|claim-proof-pending) ;;
    *) refuse "--conversation (in-thread delivery) applies to uvn-status, withdrawal-confirm, the status notes, claim-status, email-changed, gap-ask, merge-pending, credit-hold-status and claim-proof-pending only." ;;
  esac
  printf '%s' "$THREAD" | grep -qE '^[0-9]{1,24}$' \
    || refuse "--conversation must be the numeric Intercom conversation id (got '$THREAD')."
  MESSAGE_TYPE="comment"
fi
if [ "$ACTION" = "thread-contact" ]; then
  case "$CAMPAIGN" in
    withdrawal-confirm|email-changed|email-changed-dup) ;;
    *) refuse "--thread-contact applies to withdrawal-confirm and email-changed only." ;;
  esac
  [ -n "$THREAD" ] || refuse "--thread-contact needs --conversation <id>."
  [ "$KIND" = "initial" ] || refuse "--thread-contact applies to an initial note."
fi
readonly APPROVAL_REF MAX_CREDITS MAX_LISTED COPY
WINDOWED_FLAG=""; [ "$COPY" != "windowed" ] || [ "$KIND" != "initial" ] || WINDOWED_FLAG="--windowed"
if [ "$KIND" = "initial" ]; then
  [ -z "$PARENT_ID" ] || refuse "--parent-message-id applies to follow-ups only."
else
  printf '%s' "$PARENT_ID" | grep -qE '^[0-9]{1,24}$' \
    || refuse "a follow-up needs --parent-message-id, the numeric Intercom id of the note it follows up (got '${PARENT_ID:-<empty>}')."
fi
[ -n "$APPROVED_BY" ] || refuse "--approved-by <SlackUID> is required: the captain approved these campaigns (U7RP6HKUZ)."
printf '%s' "$APPROVED_BY" | grep -qE '^U[A-Z0-9]{8,12}$' \
  || refuse "--approved-by must be a human's Slack USER ID; '$APPROVED_BY' is not one. Agent identities and self-approval never authorize a message to a customer."
[ "$APPROVED_BY" = "$CAPTAIN_UID" ] \
  || refuse "$APPROVED_BY did not approve the verify-request campaigns. Only the captain ($CAPTAIN_UID) did; any other customer message goes through intercom-ops-write.sh."
[ -n "$CREDITS_FILE" ] || refuse "--credits-file FILE is required (see Usage)."
[ -r "$CREDITS_FILE" ] || die "--credits-file '$CREDITS_FILE' is not readable."
"$JQ_BIN" -e 'type == "object" and (.user|type) == "object" and (.credits|type) == "array"' "$CREDITS_FILE" >/dev/null 2>&1 \
  || refuse "--credits-file must be a JSON object {user:{...}, credits:[...]}."

# Normalise: control characters become spaces, runs of whitespace collapse, ends are trimmed.
INPUT="$("$JQ_BIN" -c '
  def clean: tostring | gsub("[[:cntrl:]]"; " ") | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
  { user: { email: ((.user.email // "") | clean | ascii_downcase),
            id: ((.user.id // "") | clean),
            auth_id: ((.user.auth_id // "") | clean | sub("^auth0\\|"; "")),
            professional_id: ((.user.professional_id // "") | clean),
            ext_other_account: (.user.ext_other_account | if type == "boolean" then . else null end),
            thread_external_id: ((.user.thread_external_id // "") | clean),
            pending_count: (.user.pending_count | if type == "number" and . == floor and . >= 0 and . <= 1000000 then . else null end),
            first_name: ((.user.first_name // "") | clean) },
    claim: ((.claim // {}) | { profile_name: ((.profile_name // "") | clean), profile_url: ((.profile_url // "") | clean),
                               code: ((.code // "") | clean), platform: ((.platform // "") | clean | ascii_downcase) }),
    merge: ((.merge // {}) | { profiles: [ (.profiles // [])[] | clean ] }),
    credits: [ .credits[] | { request_id: ((.request_id // "") | clean), role: ((.role // "") | clean),
                              track_title: ((.track_title // "") | clean), artist_name: ((.artist_name // "") | clean),
                              role_families: ([(.role_families // [])[] | clean] | if length == 0 then ["other"] else . end),
                              reason: ((.reason // "") | clean | ascii_downcase), evidence_url: ((.evidence_url // "") | clean),
                              source_label: ((.source_label // "") | clean), policy_reason: ((.policy_reason // "") | clean | ascii_downcase),
                              received: ((.received // "") | clean | ascii_downcase),
                              other_names: [(.other_names // [])[] | clean | select(length > 0)],
                              evidence_source: ((.evidence_source // "") | clean),
                              corroboration_url: ((.corroboration_url // "") | clean),
                              profile_id: ((.profile_id // "") | clean), track_id: ((.track_id // "") | clean) } ] }' "$CREDITS_FILE")"

INPUT_FILING_CONV="$("$JQ_BIN" -r '(.user.filing_conversation // "") | tostring' "$CREDITS_FILE" 2>/dev/null || true)"
# R1 is delivered INTO the filing conversation (p1's batch-1 signature: the thread comm_state's R5-R7 and G3 judged),
# never into whichever conversation the 14-day auto-pick would choose and never by email instead. The dry run
# renders it in-thread too. A filing thread that cannot carry it is a hold (below), not a fallback.
R1_THREAD=0
# QA #1460: an explicit --conversation for R1 must BE the filing conversation (the one G3 and comm_state judge).
if [ "$COPY" = "docrecvr" ] && [ -n "$THREAD" ] && [ "$THREAD" != "$INPUT_FILING_CONV" ]; then
  refuse "R1 goes only into the filing conversation ($INPUT_FILING_CONV); --conversation $THREAD is another thread. Nothing was sent or claimed."
fi
if [ "$COPY" = "docrecvr" ] && [ -z "$THREAD" ] && printf '%s' "$INPUT_FILING_CONV" | grep -qE '^[0-9]{1,24}$'; then
  THREAD="$INPUT_FILING_CONV"; MESSAGE_TYPE="comment"; R1_THREAD=1
fi
# G1's "older than the request": the oldest credits[].created_at the caller passed (epoch, or ISO with Z, a +hh:mm /
# +hhmm offset, or none = UTC), as epoch. A supplied value that does not parse is BAD (QA #1456): G1 then refuses,
# it never reads as "no request time given".
INPUT_RAW_CREATED="$("$JQ_BIN" -r '
  def ep: if type == "number" then (if . == floor and . > 0 and . < 1000000000000 then . else error("not epoch seconds") end)
    else (tostring | sub("\\.[0-9]+"; "") | sub(" UTC$"; "Z") | sub(" "; "T")
          | capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?<z>Z|(?<sg>[+-])(?<hh>[0-9]{2}):?(?<mm>[0-9]{2}))?$") // error("bad time")) as $c
         | (if $c.sg != null and (($c.hh | tonumber) > 14 or ($c.mm | tonumber) > 59) then error("impossible offset") else . end)
         | ($c.d + "Z" | fromdateiso8601) as $u
         | (if ($u | todate) == ($c.d + "Z") then $u else error("impossible date") end)
           - (if $c.sg == null then 0 else (($c.hh | tonumber) * 3600 + ($c.mm | tonumber) * 60) * (if $c.sg == "+" then 1 else -1 end) end)
    end;
  [.credits[]? | .created_at // empty | (try ep catch "BAD")] as $t
  | if any($t[]; . == "BAD") then "BAD" else ($t | min // "") end' "$CREDITS_FILE" 2>/dev/null || echo BAD)"
EMAIL="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '.user.email')"
USER_ID="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '.user.id')"
AUTH_ID="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '.user.auth_id')"
printf '%s' "$EMAIL" | grep -qE '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$' \
  || refuse "user.email must be the credit request's account email (got an invalid value)."
[ -z "$USER_ID" ] || printf '%s' "$USER_ID" | grep -qE '^[A-Za-z0-9-]{1,64}$' \
  || refuse "user.id must be the Muso user id (letters, digits, dashes)."
AUTH_ID="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '.user.auth_id')"
[ -z "$AUTH_ID" ] || printf '%s' "$AUTH_ID" | grep -qE '^[A-Za-z0-9._-]{1,128}$' \
  || refuse "user.auth_id must be the account's Auth0 subject (letters, digits, dot, underscore, dash)."
PRO_ID="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '.user.professional_id')"
[ -z "$PRO_ID" ] || printf '%s' "$PRO_ID" | grep -qE '^[A-Za-z0-9._|-]{1,128}$' \
  || refuse "user.professional_id must be the account's users.neptuneProfessionalId (letters, digits, dot, underscore, dash, |)."
EXT_OTHER="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '.user.ext_other_account | if . == null then "" else tostring end')"
THREAD_EXT="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '.user.thread_external_id')"
# An Intercom contact's external_id names THIS account when it is the account's
# professional id (users.neptuneProfessionalId, what the web app boots Intercom with;
# firstmate 090) or its Auth0 subject (with or without its auth0| prefix). Anything else,
# including the bare numeric user id, is another account.
ext_is_account() {
  [ -n "$1" ] || return 1
  { [ -n "$PRO_ID" ] && [ "$1" = "$PRO_ID" ]; } \
    || { [ -n "$AUTH_ID" ] && { [ "$1" = "$AUTH_ID" ] || [ "$1" = "auth0|$AUTH_ID" ]; }; }
}
readonly NO_EXT_ID_WHY="the Intercom user for this email has no external_id, so it cannot be matched to this Muso account; not sending."
N="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '.credits | length')"
[ "$N" -ge 1 ] || refuse "credits is empty; there is nothing to ask the user to verify."
[ "$N" -le "$MAX_CREDITS" ] || refuse "credits has $N entries; at most $MAX_CREDITS per $CAMPAIGN note."
case "$CAMPAIGN" in
  email-changed|email-changed-dup)
    [ -n "$THREAD" ] || refuse "$CAMPAIGN is a threaded reply only: --conversation <id> (the requester's own conversation) is required."
    printf '%s' "$INPUT" | "$JQ_BIN" -e '.credits[0].request_id | test("^[A-Za-z0-9-]{1,64}$")' >/dev/null \
      || refuse "$CAMPAIGN needs one entry whose request_id is the ticket key (letters, digits, dashes)."
    printf '%s' "$INPUT" | "$JQ_BIN" -e '.user.id | test("^[0-9]{1,12}$")' >/dev/null \
      || refuse "$CAMPAIGN needs user.id, the Muso account id the conversation must belong to."
    # Placeholders so the shared shape checks below pass; the copy never reads them.
    INPUT="$(printf '%s' "$INPUT" | "$JQ_BIN" -c '.credits[0] += {role: "-", track_title: "-", artist_name: "-"}')" ;;
  merge-pending)
    printf '%s' "$INPUT" | "$JQ_BIN" -e '.credits[0].request_id | test("^merge-[A-Za-z0-9-]{1,58}$")' >/dev/null \
      || refuse "merge-pending needs one entry whose request_id is the merge key merge-<merge request id>."
    printf '%s' "$INPUT" | "$JQ_BIN" -e '.user.id | test("^[0-9]{1,12}$")' >/dev/null \
      || refuse "merge-pending needs user.id, the requester's Muso account id."
    printf '%s' "$INPUT" | "$JQ_BIN" -e '.merge.profiles | length >= 1 and length <= 4 and all(.[]; length > 0 and length <= 120)' >/dev/null \
      || refuse "merge.profiles must be 1 to 4 catalog profile names (1 to 120 characters each)."
    INPUT="$(printf '%s' "$INPUT" | "$JQ_BIN" -c '.credits[0] += {role: "-", track_title: "-", artist_name: "-"}')" ;;
  claim-status|claim-proof-pending)
    printf '%s' "$INPUT" | "$JQ_BIN" -e '.credits[0].request_id | test("^claim-[0-9]{1,19}$")' >/dev/null \
      || refuse "$CAMPAIGN needs one entry whose request_id is the claim key claim-<claiming.id>."
    printf '%s' "$INPUT" | "$JQ_BIN" -e '.credits[0].profile_id | length > 0' >/dev/null \
      || refuse "$CAMPAIGN needs the entry's profile_id, the claimed profile's id."
    printf '%s' "$INPUT" | "$JQ_BIN" -e '.user.id | test("^[0-9]{1,12}$")' >/dev/null \
      || refuse "$CAMPAIGN needs user.id, the claimant's Muso account id."
    printf '%s' "$INPUT" | "$JQ_BIN" -e '.claim.profile_name | length > 0 and length <= 120' >/dev/null \
      || refuse "claim.profile_name must be the claimed profile's catalog name (1 to 120 characters)."
    INPUT="$(printf '%s' "$INPUT" | "$JQ_BIN" -c '.credits[0] += {role: "-", track_title: "-", artist_name: "-"}')" ;;
  claim-proof-ask)
    printf '%s' "$INPUT" | "$JQ_BIN" -e '.credits[0].request_id | test("^claim-[0-9]{1,19}$")' >/dev/null \
      || refuse "claim-proof-ask needs one entry whose request_id is the claim key claim-<claiming.id>."
    printf '%s' "$INPUT" | "$JQ_BIN" -e '.credits[0].profile_id | length > 0' >/dev/null \
      || refuse "claim-proof-ask needs the entry's profile_id, the claimed profile's id (the daily code check's send log carries it)."
    printf '%s' "$INPUT" | "$JQ_BIN" -e '.user.id | test("^[0-9]{1,12}$")' >/dev/null \
      || refuse "claim-proof-ask needs user.id, the claimant's Muso account id."
    printf '%s' "$INPUT" | "$JQ_BIN" -e '.claim.profile_name | length > 0 and length <= 120' >/dev/null \
      || refuse "claim.profile_name must be the claimed profile's catalog name (1 to 120 characters)."
    printf '%s' "$INPUT" | "$JQ_BIN" -e '.claim.profile_url | test("^https://(credits\\.)?muso\\.ai/[A-Za-z0-9/_.~%-]{1,200}$")' >/dev/null \
      || refuse "claim.profile_url must be the profile's public https://muso.ai/ or https://credits.muso.ai/ link."
    printf '%s' "$INPUT" | "$JQ_BIN" -e '.claim.code | test("^[A-Za-z0-9-]{4,32}$")' >/dev/null \
      || refuse "claim.code must be the claim's bound-proof code (4 to 32 letters, digits or dashes)."
    CLAIM_SURFACE="$(printf '%s' "$INPUT" | "$JQ_BIN" -r --argjson m "$CLAIM_SURFACES" '$m[.claim.platform] // empty')"
    [ -n "$CLAIM_SURFACE" ] \
      || refuse "claim.platform must be one of $(printf '%s' "$CLAIM_SURFACES" | "$JQ_BIN" -r 'keys_unsorted | join(", ")'): a surface the daily code check can read (never Instagram, X or TikTok)."
    INPUT="$(printf '%s' "$INPUT" | "$JQ_BIN" -c --arg s "$CLAIM_SURFACE" '.claim.surface = $s | .credits[0] += {role: "-", track_title: "-", artist_name: "-"}')" ;;
esac
if [ "$COPY" = "teamreviewcount" ]; then
  # The count-only note shows no title, artist or role (they may be blank or unshowable: that is
  # why it is sent): placeholders for the shape checks; a malformed profile/track ref is dropped.
  INPUT="$(printf '%s' "$INPUT" | "$JQ_BIN" -c '.credits |= map(. + {role: "-", track_title: "-", artist_name: "-"}
    | (if (.profile_id | test("^[A-Za-z0-9-]{0,64}$")) then . else .profile_id = "" end)
    | (if (.track_id | test("^[A-Za-z0-9-]{0,64}$")) then . else .track_id = "" end))
    | .user.pending_count = ([(.user.pending_count // 0), (.credits | length)] | max)')"
fi
bad="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '[.credits[] | select((.request_id | test("^[A-Za-z0-9-]{1,64}$") | not)
  or (.role|length) == 0 or (.role|length) > 120 or (.track_title|length) == 0 or (.track_title|length) > 200
  or (.artist_name|length) == 0 or (.artist_name|length) > 200
  or ((.profile_id|length) > 0 and (.profile_id | test("^[A-Za-z0-9-]{1,64}$") | not))
  or ((.track_id|length) > 0 and (.track_id | test("^[A-Za-z0-9-]{1,64}$") | not)))] | length')"
[ "$bad" -eq 0 ] || refuse "$bad credit(s) are missing a request_id, role, track_title or artist_name, exceed the length caps (role 120, title/artist 200), or carry a malformed profile_id/track_id."
badfam="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '[.credits[].role_families[] | select(IN("mix_master","producer","writer","engineer","musician","studio_org","anr","other") | not)] | unique | join(",")')"
[ -z "$badfam" ] || refuse "unknown role_families '$badfam'; use mix_master, producer, writer, engineer, musician, studio_org, anr or other."
if [ "$CAMPAIGN" = "removal-notice" ]; then
  # Fraud removals are silent by captain order: a notice that says or implies it is refused.
  nfraud="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '[.credits[] | select(.reason == "fraud")] | length')"
  [ "$nfraud" -eq 0 ] || refuse "$nfraud credit(s) carry reason 'fraud'. Fraud removals are not notified (captain order); leave them out of the removal-notice list."
  # Fable copy review 2026-10-17: "verification" and a policy removal without a named
  # sub-reason are manual_only (a named human sends them from the board, never this gate).
  nman="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '[.credits[] | select(.reason == "verification" or (.reason == "policy" and (.policy_reason | IN("artist_by_non_artist","org_on_person","label_role_without_release","duplicate_profile") | not)))] | length')"
  [ "$nman" -eq 0 ] || refuse "$nman credit(s) are manual_only (reason 'verification', or 'policy' without a policy_reason of artist_by_non_artist, org_on_person, label_role_without_release or duplicate_profile): a named human sends those from the board, not this automatic notice."
  badr="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '[.credits[].reason | select(IN("misattributed","duplicate","policy") | not)] | unique | join(",")')"
  [ -z "$badr" ] || refuse "unknown removal reason '$badr'; use misattributed, duplicate or policy (verification is manual_only)."
  # A misattribution names the real source it is based on (never "public credits page" for a DSP row).
  badsrc="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '[.credits[] | select(.reason == "misattributed" and (.source_label | IN("Spotify credits","Tidal credits","Qobuz credits page","Apple Music credits","Discogs","AllMusic","MusicBrainz") | not))] | length')"
  [ "$badsrc" -eq 0 ] || refuse "$badsrc misattributed credit(s) lack a source_label from the fixed list (Spotify credits, Tidal credits, Qobuz credits page, Apple Music credits, Discogs, AllMusic, MusicBrainz)."
  badu="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '[.credits[].evidence_url | select(. != "" and ((test("^https://[A-Za-z0-9.-]+(/[^[:space:]]*)?$") | not) or (length > 300)))] | length')"
  [ "$badu" -eq 0 ] || refuse "$badu evidence_url value(s) are not a plain https URL of at most 300 characters."
  internal="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '[.credits[].evidence_url | select(test("^https://([A-Za-z0-9-]+\\.)*(muso\\.ai|ak\\.muso\\.ai|clickup\\.com|slack\\.com|intercom\\.io|github\\.com|gitlab\\.com)(/|$)"))] | length')"
  [ "$internal" -eq 0 ] || refuse "$internal evidence_url value(s) point at an internal or Muso surface; the evidence link must be the public source (a release page, a registry entry)."
fi
if [ "$CAMPAIGN" = "takeback-notice" ]; then
  # Only names quoted in the row's recorded evidence, a fixed source label, a public https link.
  badn="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '[.credits[] | select((.other_names | length) == 0 or (.other_names | length) > 10 or any(.other_names[]; length > 120))] | length')"
  [ "$badn" -eq 0 ] || refuse "$badn credit(s) lack other_names (1 to 10 names of at most 120 characters, the names in the recorded evidence)."
  bads="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '[.credits[] | select(.evidence_source | IN("public credits page","Spotify credits","Tidal credits","Spotify and Tidal credits") | not)] | length')"
  [ "$bads" -eq 0 ] || refuse "$bads credit(s) carry an evidence_source outside the fixed list (public credits page, Spotify credits, Tidal credits, Spotify and Tidal credits)."
  badu="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '[.credits[].evidence_url | select((test("^https://[A-Za-z0-9.-]+(/[^[:space:]]*)?$") | not) or (length > 300) or test("^https://([A-Za-z0-9-]+\\.)*(muso\\.ai|clickup\\.com|slack\\.com|intercom\\.io|github\\.com|gitlab\\.com)(/|$)"))] | length')"
  [ "$badu" -eq 0 ] || refuse "$badu credit(s) need an evidence_url: a public https link of at most 300 characters, never an internal or Muso surface."
  badc="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '[.credits[] | select(.corroboration_url != "" and ((.corroboration_url | test("^https://[A-Za-z0-9.-]+(/[^[:space:]]*)?$") | not) or (.corroboration_url | length) > 300 or .corroboration_url == .evidence_url or (.corroboration_url | test("^https://([A-Za-z0-9-]+\\.)*(muso\\.ai|clickup\\.com|slack\\.com|intercom\\.io|github\\.com|gitlab\\.com)(/|$)"; "i"))))] | length')"
  [ "$badc" -eq 0 ] || refuse "$badc credit(s) carry a corroboration_url that is not a public https link of at most 300 characters distinct from the evidence_url."
fi
dups="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '[.credits[].request_id] | length - (unique | length)')"
[ "$dups" -eq 0 ] || refuse "credits repeats a request_id; each credit request appears once."
if [ "$CAMPAIGN" = "gap-ask" ]; then
  # The verdict is read HERE, from the proof store, never taken from the caller: every credit's
  # latest stage-2 verdict (every claimed role) must be need_more for THIS account, the account
  # must not be held, and <doc summary> is built from that verdict's best document (its kind and
  # the catalog titles it lists; never text from the document).
  printf '%s' "$USER_ID" | grep -qE '^[0-9]{1,12}$' \
    || refuse "gap-ask needs user.id, the Muso account id the stage-2 verdicts must belong to."
  [ -r "$STAGE2_HELPER" ] || die "stage-2 helper $STAGE2_HELPER is missing; refusing to send a gap ask without the verdict."
  S2="$("$PY_BIN" -I "$STAGE2_HELPER" --db "$PROOF_DB" gap-credits --request-ids "$(printf '%s' "$INPUT" | "$JQ_BIN" -r '[.credits[].request_id] | join(",")')" --user-id "$USER_ID")" \
    || die "the stage-2 verdict read failed; refusing to send a gap ask without it."
  [ "$(printf '%s' "$S2" | "$JQ_BIN" -r '.eligible')" = "true" ] \
    || refuse "gap-ask: $(printf '%s' "$S2" | "$JQ_BIN" -r '.reason'). The gap ask goes only to credits whose document on file stage 2 judged need_more."
  # Every role the caller names must be one stage 2 judged for that credit.
  badrole="$(printf '%s' "$INPUT" | "$JQ_BIN" -r --argjson s "$S2" '[.credits[] | . as $c | ($c.request_id | ascii_downcase) as $k
    | ($s.credits[$k].roles // [] | map(ascii_downcase)) as $judged
    | [$c.role | split(",")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0) | ascii_downcase] as $named
    | select(($named | length) == 0 or ($named - $judged | length) > 0) | .request_id] | join(",")')"
  [ -z "$badrole" ] || refuse "gap-ask: the role on $badrole is not one stage 2 judged for that credit; not sending."
  INPUT="$(printf '%s' "$INPUT" | "$JQ_BIN" -c --argjson s "$S2" '
    def clean: tostring | gsub("[[:cntrl:]]"; " ") | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
    .credits |= map((.request_id | ascii_downcase) as $k | $s.credits[$k] as $v
      | . + {doc_kind: ($v.doc_kind // ""), doc_proof: ($v.proof_id // ""),
             doc_lists: [($v.lists // [])[] | clean | select(length > 0 and length <= 200)]})')"
fi

ids_csv() { printf '%s' "$1" | "$JQ_BIN" -r '[.credits[].request_id] | join(",")'; }
keep_ids() { # <input-json> <ids-json-array>
  printf '%s' "$1" | "$JQ_BIN" -c --argjson ids "$2" '.credits |= [.[] | select(.request_id as $r | $ids | index($r))]'
}
add_days() { "$PY_BIN" -I -c 'import datetime,sys; print((datetime.date.fromisoformat(sys.argv[1]) + datetime.timedelta(days=int(sys.argv[2]))).isoformat())' "$1" "$2"; }
day_label() { "$PY_BIN" -I -c 'import datetime,sys; d=datetime.date.fromisoformat(sys.argv[1]); print(f"{d:%B} {d.day}")' "$1"; }
# claim-proof-ask only (Fable D38): the plain weekday and day, "Friday, November 7".
claim_day_label() { "$PY_BIN" -I -c 'import datetime,sys; d=datetime.date.fromisoformat(sys.argv[1]); print(f"{d:%A}, {d:%B} {d.day}")' "$1"; }

# ---------------------------------------------------------------------------------------
# Send locks, checked before anything else on a real send so a locked campaign never even
# reads the ledger. (A windowed verify-live follow-up is allowed: its note already promised it.)
# verify-live: a NEW provisional approval is only ever sent the windowed copy (30 days +
# the removal date; firstmate decision 2026-10-16 on review finding v1-copy-never-removal-due):
# the v1 "nothing changes while we check" copy is preview-only, so a note that promised no
# date can never reach a new credit.
if { [ "$ACTION" = "post" ] || [ "$ACTION" = "validate" ]; } && [ "$CAMPAIGN" = "takeback-notice" ] && [ "$TAKEBACK_COPY_APPROVED" != "1" ]; then
  refuse "the takeback-notice copy is not approved for sending yet (TAKEBACK_COPY_APPROVED=0). It needs Fable's copy GO and the captain's approval, landed in a PR that flips the lock; --dry-run renders it."
fi
if [ "$ACTION" = "post" ] && [ "$CAMPAIGN" = "removal-notice" ] && [ "$REMOVAL_COPY_APPROVED" != "1" ]; then
  refuse "the removal-notice copy is not approved for sending yet (REMOVAL_COPY_APPROVED=0). It needs Fable's copy GO, landed in a PR that flips the lock, and firstmate's approval of the backfill list; --dry-run renders exactly what would be sent."
fi
if [ "$ACTION" = "post" ] && [ "$CAMPAIGN" = "withdrawal-confirm" ] && [ "$WITHDRAWAL_COPY_APPROVED" != "1" ]; then
  refuse "the withdrawal-confirm copy is not approved for sending (WITHDRAWAL_COPY_APPROVED=0)."
fi
if [ "$ACTION" = "post" ] && { [ "$CAMPAIGN" = "status-doc-received" ] || [ "$CAMPAIGN" = "status-team-review" ]; } && [ "$STATUS_NOTES_COPY_APPROVED" != "1" ]; then
  refuse "the status-note copy is not approved for sending (STATUS_NOTES_COPY_APPROVED=0)."
fi
if [ "$ACTION" = "post" ] && [ "$COPY" = "docrecvr" ] && [ "$STATUS_RECEIVED_COPY_APPROVED" != "1" ]; then
  refuse "the receipt line R1 (status-doc-received --copy received) is not approved for sending yet (STATUS_RECEIVED_COPY_APPROVED=0). It waits for the captain's yes, landed in a PR that flips the lock; --dry-run renders exactly what would be sent."
fi
if [ "$ACTION" = "post" ] && { [ "$CAMPAIGN" = "email-changed" ] || [ "$CAMPAIGN" = "email-changed-dup" ]; } && [ "$EMAIL_CHANGE_COPY_APPROVED" != "1" ]; then
  refuse "the email-changed copy is not approved for sending (EMAIL_CHANGE_COPY_APPROVED=0)."
fi
if [ "$ACTION" = "post" ] && [ "$CAMPAIGN" = "claim-proof-ask" ] && [ "$CLAIM_PROOF_ASK_COPY_APPROVED" != "1" ]; then
  refuse "the claim-proof-ask copy is not approved for sending yet (CLAIM_PROOF_ASK_COPY_APPROVED=0). It needs Fable's copy approval and firstmate's GO, landed in a PR that flips the lock; --dry-run renders exactly what would be sent."
fi
if [ "$ACTION" = "post" ] && [ "$CAMPAIGN" = "claim-status" ] && [ "$CLAIM_STATUS_COPY_APPROVED" != "1" ]; then
  refuse "the claim-status copy is not approved for sending yet (CLAIM_STATUS_COPY_APPROVED=0). Fable approved the text; it waits for firstmate's GO after the 5-user dry run, landed in a PR that flips the lock; --dry-run renders exactly what would be sent."
fi
if [ "$ACTION" = "post" ] && [ "$CAMPAIGN" = "uvn-status" ] && [ "$UVN_STATUS_COPY_APPROVED" != "1" ]; then
  refuse "the uvn-status copy is not approved for sending (UVN_STATUS_COPY_APPROVED=0)."
fi
if [ "$ACTION" = "post" ] && [ "$CAMPAIGN" = "gap-ask" ] && [ "$GAP_ASK_COPY_APPROVED" != "1" ]; then
  refuse "the gap-ask copy is not approved for sending (GAP_ASK_COPY_APPROVED=0)."
fi
# Per-campaign kill switch (rulings-1028-1430 section 2.4): `touch /etc/hydra/<campaign>.disabled` stops every real
# send of that campaign at once, before any claim or Intercom call; the dry run still renders. Removing the file
# resumes it. Exit 3: nothing is claimed, refused or closed.
if [ "$ACTION" = "post" ] && [ -e "$DISABLED_DIR/$CAMPAIGN.disabled" ]; then
  printf 'STOPPED %s is disabled (%s present); nothing was sent or claimed\n' "$CAMPAIGN" "$DISABLED_DIR/$CAMPAIGN.disabled"; exit 3
fi
if [ "$ACTION" = "post" ] && [ "$CAMPAIGN" = "merge-pending" ] && [ "$MERGE_PENDING_COPY_APPROVED" != "1" ]; then
  refuse "the merge-pending copy is not approved for sending yet (MERGE_PENDING_COPY_APPROVED=0). It waits for the captain's own yes on line M1, landed in a PR that flips the lock; --dry-run renders exactly what would be sent."
fi
if [ "$ACTION" = "post" ] && [ "$CAMPAIGN" = "credit-hold-status" ] && [ "$CREDIT_HOLD_STATUS_COPY_APPROVED" != "1" ]; then
  refuse "the credit-hold-status copy is not approved for sending yet (CREDIT_HOLD_STATUS_COPY_APPROVED=0). It waits for the captain's yes on L14a, landed in a PR that flips the lock; --dry-run renders exactly what would be sent."
fi
if [ "$ACTION" = "post" ] && [ "$CAMPAIGN" = "claim-proof-pending" ] && [ "$CLAIM_PROOF_PENDING_COPY_APPROVED" != "1" ]; then
  refuse "the claim-proof-pending copy is not approved for sending yet (CLAIM_PROOF_PENDING_COPY_APPROVED=0). It waits for the captain's yes on L14b, landed in a PR that flips the lock; --dry-run renders exactly what would be sent."
fi
if [ "$ACTION" = "post" ] && [ "$CAMPAIGN" = "retro-past" ] && [ "$RETRO_COPY_APPROVED" != "1" ]; then
  refuse "the retro-past copy is not approved for sending yet (RETRO_COPY_APPROVED=0). It needs Fable's copy GO and the captain's approval of the rendered notes, landed in a PR that flips the lock; --dry-run renders exactly what would be sent."
fi

# On a real send, look at the ledger first so a re-run is a quiet no-op before any Intercom
# call. The atomic claims below re-check all of this inside their transactions.
CONTACT_ID="" DUE_DAY="" REMOVAL_DAY=""
if [ "$ACTION" = "post" ]; then
  if [ "$KIND" = "initial" ]; then
    peek="$(ledger pending --campaign "$CAMPAIGN" --user-key "$EMAIL" --user-id "$USER_ID" --day "$DAY" --request-ids "$(ids_csv "$INPUT")")" \
      || die "the ledger read failed; refusing to send without the idempotency record."
    pending="$(printf '%s' "$peek" | "$JQ_BIN" -c '.request_ids')"
    if [ "$pending" = "[]" ]; then
      printf 'SKIPPED already-notified credits=%s\n' "$N"; exit 0
    fi
    if [ "$(printf '%s' "$peek" | "$JQ_BIN" -r '.hold.flagged // false')" = "true" ]; then
      printf 'SKIPPED refused-flagged credits=%s (refused %s times; with a human)\n' "$N" "3"; exit 0
    fi
    held_until="$(printf '%s' "$peek" | "$JQ_BIN" -r '.hold.until // empty')"
    if [ -n "$held_until" ]; then
      printf 'DEFERRED refused-recheck credits=%s (refused before; re-check after %s)\n' "$N" "${held_until%%T*}"; exit 3
    fi
    done_why="$(printf '%s' "$peek" | "$JQ_BIN" -r '.user_done // empty')"
    if [ -n "$done_why" ]; then
      # retro-past: one message per user ever, none after a proof reply. Close the rows so
      # the wave never offers them again.
      ledger skip --campaign "$CAMPAIGN" --request-ids "$(printf '%s' "$pending" | "$JQ_BIN" -r 'join(",")')" >/dev/null \
        || die "the ledger write failed."
      printf 'SKIPPED %s credits=%s\n' "$done_why" "$(printf '%s' "$pending" | "$JQ_BIN" -r 'length')"; exit 0
    fi
    if [ "$(printf '%s' "$peek" | "$JQ_BIN" -r '.recent // false')" = "true" ]; then
      if [ "$(printf '%s' "$peek" | "$JQ_BIN" -r '.recent_why // empty')" = "recently_asked" ]; then
        printf 'DEFERRED recently-asked credits=%s (this user got an ask in the last 90 days; the credits wait)\n' \
          "$(printf '%s' "$pending" | "$JQ_BIN" -r 'length')"; exit 3
      fi
      printf 'DEFERRED messaged_7d credits=%s (a note from this gate in the last 7 days)\n' "$(printf '%s' "$pending" | "$JQ_BIN" -r 'length')"; exit 3
    fi
    if [ "$(printf '%s' "$peek" | "$JQ_BIN" -r '.daily_cap')" = "true" ]; then
      printf 'DEFERRED daily-cap credits=%s (this user already had a verify message on %s UTC; they go in the next one)\n' \
        "$(printf '%s' "$pending" | "$JQ_BIN" -r 'length')" "$DAY"; exit 3
    fi
    INPUT="$(keep_ids "$INPUT" "$pending")"
  else
    st="$(ledger reminder-state --parent-message-id "$PARENT_ID" --kind "$KIND" --day "$DAY")" \
      || die "the ledger read failed; refusing to send without the idempotency record."
    case "$(printf '%s' "$st" | "$JQ_BIN" -r '.result')" in
      due) ;;
      no_parent) refuse "message $PARENT_ID is not a sent note in the ledger; a follow-up follows up a note this wrapper sent." ;;
      not_applicable) refuse "note $PARENT_ID has no $KIND: only a windowed note (one that named a removal date) gets follow-ups." ;;
      not_due) printf 'NOT DUE %s message=%s\n' "$KIND" "$PARENT_ID"; exit 3 ;;
      proof_received) printf 'SKIPPED proof-received message=%s\n' "$PARENT_ID"; exit 0 ;;
      done) printf 'SKIPPED %s-done message=%s\n' "$KIND" "$PARENT_ID"; exit 0 ;;
      *) die "unexpected ledger answer: $st" ;;
    esac
    [ "$(printf '%s' "$st" | "$JQ_BIN" -r '.campaign')" = "$CAMPAIGN" ] || refuse "message $PARENT_ID belongs to another campaign."
    [ "$(printf '%s' "$st" | "$JQ_BIN" -r '.user_key')" = "$EMAIL" ] \
      || refuse "message $PARENT_ID went to a different account; a follow-up goes only to the user of its note."
    INPUT="$(keep_ids "$INPUT" "$(printf '%s' "$st" | "$JQ_BIN" -c '.request_ids')")"
    [ "$(printf '%s' "$INPUT" | "$JQ_BIN" -r '.credits | length')" -ge 1 ] \
      || refuse "none of these credits were in note $PARENT_ID; a follow-up lists only that note's credits."
    if [ "$KIND" = "after-rejection" ]; then
      # The reason is the reviewer's, recorded with the rejection; never the caller's.
      INPUT="$(printf '%s' "$INPUT" | "$JQ_BIN" -c --argjson r "$(printf '%s' "$st" | "$JQ_BIN" -c '.reasons // {}')" \
        --argjson v "$(printf '%s' "$st" | "$JQ_BIN" -c '.received // {}')" \
        '.credits |= map(.reason = ($r[.request_id] // "") | .received = ($v[.request_id] // ""))')"
    fi
    CONTACT_ID="$(printf '%s' "$st" | "$JQ_BIN" -r '.contact_id // empty')"
    DUE_DAY="$(printf '%s' "$st" | "$JQ_BIN" -r '.due_day // empty')"
    REMOVAL_DAY="$(printf '%s' "$st" | "$JQ_BIN" -r '.removal_day // empty')"
  fi
fi
# Core's own notices (Fable sender map 2026-10-27 item 2, firstmate inbox 045): core told this user something
# outside this ledger (approvedNotice / proofRequest / infoRequest within 7 days, a claim update within 7 days,
# or a credit request changed today) -> no note now, from any campaign. A deferral (exit 3), logged in
# verify_messages as status 'deferred': nothing is claimed, refused or closed, so the note is offered again
# once the window passes. Unreadable, or nothing to check
# (no user id and no valid email) -> nothing sent (exit 4), never "clear".
if [ "$ACTION" = "post" ]; then
  # By Muso user id; a note keyed only by email (removal notices) is checked for every account with that email.
  if printf '%s' "$USER_ID" | grep -qE '^[0-9]{1,12}$'; then cn_who=(--user-id "$USER_ID"); else cn_who=(--email "$EMAIL"); fi
  [ -r "$CORE_NOTICE_HELPER" ] || { echo "CORE NOTICE CHECK NOT POSSIBLE: $CORE_NOTICE_HELPER is missing; nothing was sent or claimed" >&2; exit 4; }
  set +e
  CN="$("$PY_BIN" -I "$CORE_NOTICE_HELPER" check "${cn_who[@]}" 2>/dev/null)"; cn_rc=$?
  set -e
  case "$cn_rc" in
    0) ;;
    3) cn_why="$(printf '%s' "$CN" | "$JQ_BIN" -r '(.reasons // []) | join("; ")' 2>/dev/null)"
       # Logged in verify_messages as status 'deferred' (a log, never a lock: the note is offered again next run).
       # A failed log changes nothing about the deferral (nothing was sent); it is reported, not swallowed.
       ledger log-deferral --campaign "$CAMPAIGN" --user-key "$EMAIL" --user-id "$USER_ID" --day "$DAY" \
         --request-ids "$(ids_csv "$INPUT")" --message-type "$MESSAGE_TYPE" --approved-by "$APPROVED_BY" \
         --approval-ref "$APPROVAL_REF" --reason core_notice_within_7d --detail "$cn_why" >/dev/null \
         || echo "WARNING: the core_notice_within_7d deferral was not logged in the ledger" >&2
       printf 'DEFERRED core_notice_within_7d credits=%s (%s)\n' "$N" "$cn_why"; exit 3 ;;
    *) printf 'CORE NOTICE CHECK FAILED (rc=%s); nothing was sent or claimed: %s\n' "$cn_rc" "${CN:0:300}" >&2; exit 4 ;;
  esac
fi
# Windowed copy names ONE date (Fable copy review 2026-10-17): the reply-by date, 30 days
# after the note; replying by the end of that day is in time, and an unverified credit is
# removal-due only from the day after it. A follow-up uses the dates its note recorded; a
# preview uses today's.
if [ "$COPY" = "windowed" ] && [ -z "$DUE_DAY" ]; then
  DUE_DAY="$(add_days "$DAY" 30)"
  REMOVAL_DAY="$(add_days "$DUE_DAY" 1)"
fi
# claim-proof-ask: the note names its close day, 14 days after it (a real send names the day
# the ledger claim records); the reminder repeats the one its note recorded. A reminder preview
# reads it from the ledger; with no sent note there it shows a day marked as a preview.
CLAIM_PREVIEW_DAY=0
if [ "$CAMPAIGN" = "claim-proof-ask" ] && [ -z "$DUE_DAY" ]; then
  if [ "$KIND" = "initial" ]; then
    DUE_DAY="$(add_days "$DAY" 14)"
  elif [ -r "$LEDGER_HELPER" ] && [ -f "$LEDGER" ]; then
    DUE_DAY="$(ledger message --message-id "$PARENT_ID" 2>/dev/null \
      | "$JQ_BIN" -r 'select(type == "object" and .campaign == "claim-proof-ask") | .due_day // empty' 2>/dev/null || true)"
  fi
  [ -n "$DUE_DAY" ] || { DUE_DAY="$(add_days "$DAY" 7)"; CLAIM_PREVIEW_DAY=1; }
fi
due_label() { # <day>
  if [ "$CAMPAIGN" != "claim-proof-ask" ]; then day_label "$1"
  elif [ "$CLAIM_PREVIEW_DAY" = "1" ]; then printf '%s (preview date)\n' "$(claim_day_label "$1")"
  else claim_day_label "$1"; fi
}
DUE_LABEL=""
if [ -n "$DUE_DAY" ]; then
  DUE_LABEL="$(due_label "$DUE_DAY")"
fi
# The reviewer's rejection reasons and the ONLY words an after-rejection note uses for them.
REJECTION_TEXT=""
IFS= read -r -d '' REJECTION_TEXT <<'JSON' || true
{"doesnt_name_you": "it doesn't name you", "other_track": "it is for a different track",
 "other_role": "it shows a different role", "unreadable": "we couldn't read it",
 "not_a_document": "it isn't one of the documents we can accept"}
JSON
readonly REJECTION_TEXT
if [ "$KIND" = "after-rejection" ]; then
  badrej="$(printf '%s' "$INPUT" | "$JQ_BIN" -r --argjson t "$REJECTION_TEXT" '[.credits[] | select(
    (.received == "document" and (.reason as $r | $t | has($r) | not)) or (.received == "reply" and .reason != "")
    or (.received | IN("document","reply") | not))] | length')"
  [ "$badrej" -eq 0 ] || refuse "$badrej credit(s) do not say what was received (document | reply), lack a rejection reason from the fixed list ($(printf '%s' "$REJECTION_TEXT" | "$JQ_BIN" -r 'keys_unsorted | join(", ")')) for a document, or carry a reason for a reply with no document; an after-rejection note only ever names the reviewer's recorded reason."
fi
ALL_IDS="$(ids_csv "$INPUT")"

# ---------------------------------------------------------------------------------------
# Render. Output: {subject, segs:[{p:TEXT}|{ul:[TEXT]}]} -> {subject, text, html}.
#   v1        Fable's final copy (2026-10-15; no em dashes).
#   windowed  v1 for a new provisional approval with the 30-day date and the removal date
#             in place of "nothing changes while we check"; reminders at day 14 and day 25.
#   past      Fable's GO'd role drafts (2026-10-15 21:45Z) for past credits: one grouped
#             note, no deadline, no removal language, no follow-up.
# windowed and past are SEND-LOCKED until their own GO. The first name is the account's
# own, used only when it is a plain name; otherwise the greeting is "Hi there".
# A plain heredoc, NOT one inside $(...): bash 3.2 (macOS /bin/bash) mis-parses the copy's
# apostrophes inside a command substitution and fails the whole script with a syntax error.
RENDER_JQ=""
IFS= read -r -d '' RENDER_JQ <<'JQ' || true
def esc: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;") | gsub("\""; "&quot;") | gsub("'"; "&#39;");
def andjoin: if length <= 1 then (.[0] // "") else (.[0:-1] | join(", ")) + " and " + .[-1] end;
# A title that already carries its own quote marks at both ends is shown as it is.
def qt: if test("^[\"“”„«»'‘’‚].*[\"“”„«»'‘’‚]$") then . else "\"" + . + "\"" end;
# "Mixing, Mastering" -> "Mixing and Mastering credits"; one role stays "Mixing credit".
def role_credits: [ split(",")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0) ] as $r
  | if ($r | length) > 1 then "\($r | andjoin) credits" else "\(.) credit" end;
def line: "\(.role) on \(.track_title | qt) by \(.artist_name)";
def listed($c; $maxl): [ $c[0:$maxl][] | line ] + (if ($c|length) > $maxl then ["and \(($c|length) - $maxl) more"] else [] end);
def sig: [ {p: "Thank you,"}, {p: "Caroline, Muso Support"} ];
def docs: {
  mix_master: {label: "mixing and mastering",
    items: ["the mix/master invoice or a payment record for this track (you can black out amounts);",
            "the page of your contract or work order that names the track and the role;",
            "a screenshot of the delivered session or bounce (DAW project, file list with the track title and dates, or the mastering DDP/report);",
            "a label, distributor or artist-management email that confirms you mixed/mastered it;",
            "a link to liner notes or an official release page that names you for this role."],
    note: "If your credit is for a different version (a remix, radio edit, Dolby Atmos or a remaster), just tell me which one and the document can be for that version."},
  producer: {label: "production",
    items: ["the producer agreement page or the producer declaration/letter of direction that names the track;",
            "your royalty or advance statement (label, distributor, or a manager's statement) listing this track (amounts can be blacked out);",
            "the split sheet for the song if you also have a writing share;",
            "a screenshot of your DAW project or the delivered stems/files with the track title and dates;",
            "an email from the artist, label or management confirming you as producer."],
    note: "If your credit is for a remix or an alternate version, tell me which one."},
  writer: {label: "songwriting",
    items: ["the split sheet for the song (signed by the writers, with the percentages);",
            "your PRO work registration (ASCAP, BMI, SESAC, PRS, SOCAN, GEMA, SACEM, etc.) or the MLC / Songview entry that shows you as a writer;",
            "the page of your publishing or co-writing agreement that names the song;",
            "an email from the artist, label or publisher confirming you as a writer."],
    note: "If you're registered under a different legal or writer name, tell me which name to look for."},
  engineer: {label: "engineering",
    items: ["a studio booking, session sheet or recording log that names the track or the artist and the date;",
            "an invoice or payment record to the studio, label or artist for this session (amounts can be blacked out);",
            "a screenshot of the session files (DAW project, file list with dates);",
            "liner notes, a release page, or an email from the engineer in charge, the studio or the label that names you."],
    note: null},
  musician: {label: "performance",
    items: ["a union session contract or session report (AFM B-form, SAG-AFTRA, MU) naming the track;",
            "liner notes or an official release page that lists you;",
            "an invoice or payment record for the session (amounts can be blacked out);",
            "an email from the artist, producer, studio or label confirming you played on it;",
            "a screenshot of the session files with the track title and dates."],
    note: null},
  studio_org: {label: "studio and organization",
    items: ["a studio booking confirmation, session sheet or recording log that names the release or the artist and the dates;",
            "an invoice or payment record between the studio and the label, artist or producer for this session (amounts can be blacked out);",
            "a label or distributor statement or release metadata sheet that names the studio for this recording;",
            "the studio's own website, Discogs or AllMusic page listing this release, or liner notes or an official release page that names the studio;",
            "an email from the studio's own domain (not a free-mail address) confirming the session, sent by a named person with their role."],
    note: "A screenshot of the studio's social media, a self-made list of sessions or a generic studio brochure that does not name the recording does not count on its own."},
  anr: {label: "A&R",
    items: ["a label or distributor statement or contract page that names you as A&R on this release;",
            "an email from the label or the artist's management confirming it;",
            "liner notes or an official release page that names you."],
    note: null},
  other: {label: "other",
    items: ["a split sheet;", "a label or distributor statement;", "a PRO or MLC registration;",
            "a studio or session invoice;", "liner notes or an official release page that names you."],
    note: null}
};
def it1($n; $one; $many): if $n == 1 then $one else $many end;
def live_initial($fn; $c; $maxl; $windowed; $due):
  ($c | length) as $n
  | "any one of these: a split sheet, a label or distributor statement, a PRO or MLC registration, a studio or session invoice, or liner notes or an official release page that names you (PDF, PNG or JPG). A document that names several \(it1($n; ""; "of these ")) tracks counts for each track it names." as $docs
  | (if $windowed then "Reply to this message by \($due) (30 days from today) with \($docs)"
     else "Reply to this message with \($docs)" end) as $p2
  | (if $windowed then
       "If we can't verify \(it1($n; "this credit"; "a credit")) by \($due), \(it1($n; "it"; "that credit")) will be removed from your profile that day. If you send a valid document after that, we'll review it and can restore the credit."
     else
       "Nothing changes while we check. If public sources later disagree with \(it1($n; "the credit"; "a credit")), we'll review it with you before anything changes."
     end) as $p3
  | if $n == 1 then
      $c[0] as $x
      | { subject: "We added your \($x.role) credit on \($x.track_title | qt). Please help us verify it",
          segs: [ {p: "Hi \($fn), good news: your \($x.role) credit on \($x.track_title | qt) by \($x.artist_name) is now live on your Muso profile. We add credits on trust and then verify them, so please help us confirm this one."},
                  {p: $p2}, {p: $p3},
                  {p: "Thanks for helping us keep credits accurate."}, {p: "Caroline, Muso Support"} ] }
    else
      { subject: "We added \($n) new credits to your Muso profile. Please help us verify them",
        segs: [ {p: "Hi \($fn), good news: your \($n) new credits (list below) are now live on your Muso profile. We add credits on trust and then verify them, so please help us confirm these."},
                {ul: listed($c; $maxl)},
                {p: $p2}, {p: $p3},
                {p: "Thanks for helping us keep credits accurate."}, {p: "Caroline, Muso Support"} ] }
    end;
def follow_intro($fn; $c; $maxl):
  ($c | length) as $n
  | if $n == 1 then
      { subject: "Following up on your \($c[0].role) credit for \($c[0].track_title | qt)",
        segs: [ {p: "Hi \($fn), a quick follow-up on your \($c[0].role) credit for \($c[0].track_title | qt) (\($c[0].artist_name)). We haven't received a document yet."} ] }
    else
      { subject: "Following up on \($n) of your credits on Muso",
        segs: [ {p: "Hi \($fn), a quick follow-up on the \($n) credits from my earlier note (list below). We haven't received a document yet."},
                {ul: listed($c; $maxl)} ] }
    end;
def live_followup($fn; $c; $maxl; $kind; $due):
  ($c | length) as $n
  | follow_intro($fn; $c; $maxl)
  | .segs += [ {p: "Nothing has been removed yet: \(it1($n; "the credit stays"; "the credits stay")) on your profile. If we can't verify \(it1($n; "it"; "a credit")) by \($due), \(it1($n; "it"; "that credit")) will be removed from your profile that day. Reply to this message with any one of the documents from my earlier note and we'll pick it up right away."} ]
  | .segs += (if $kind == "reminder-25" then [ {p: "This is my last reminder about this review. If you need more time, tell us which credit and why, and we will keep the request open."} ] else [] end)
  | .segs += sig;
def rejection_text: $rt[.reason];
def after_rejection($fn; $c; $maxl; $due):
  ($c | length) as $n
  | [ $c[] | select(.received == "document") ] as $d
  | [ $c[] | select(.received != "document") ] as $r
  | (if ($d|length) > 0 then "If you have something else, such as a split sheet, a label or publisher statement or a session invoice, reply to this message with it by \($due)."
     else "If you have one, such as a split sheet, a label or publisher statement or a session invoice, reply to this message with it by \($due)." end) as $ask
  | if $n == 1 and ($d|length) == 1 then
      $c[0] as $x
      | { subject: "About the document for your \($x.role) credit on \($x.track_title | qt)",
          segs: ([ {p: "Hi \($fn), thanks for sending your document. It didn't confirm your \($x.role) credit on \($x.track_title | qt) by \($x.artist_name) because \($x | rejection_text). \($ask)"} ] + sig) }
    elif $n == 1 then
      $c[0] as $x
      | { subject: "About your \($x.role) credit on \($x.track_title | qt)",
          segs: ([ {p: "Hi \($fn), thanks for your reply. We still need a document that shows your \($x.role) credit on \($x.track_title | qt) by \($x.artist_name). \($ask)"} ] + sig) }
    elif ($r|length) == 0 then
      { subject: "About the documents for \($n) of your credits on Muso",
        segs: ([ {p: "Hi \($fn), thanks for sending your documents. They didn't confirm these \($n) credits:"},
                 {ul: ([ $c[0:$maxl][] | "\(line): \(rejection_text)" ] + (if $n > $maxl then ["and \($n - $maxl) more"] else [] end))},
                 {p: $ask} ] + sig) }
    elif ($d|length) == 0 then
      { subject: "About \($n) of your credits on Muso",
        segs: ([ {p: "Hi \($fn), thanks for your reply. We still need a document that shows each of these \($n) credits:"},
                 {ul: listed($c; $maxl)},
                 {p: $ask} ] + sig) }
    else
      { subject: "About the documents for \($n) of your credits on Muso",
        segs: ([ {p: "Hi \($fn), thanks for sending your documents. They didn't confirm these credits:"},
                 {ul: ([ $d[0:$maxl][] | "\(line): \(rejection_text)" ] + (if ($d|length) > $maxl then ["and \(($d|length) - $maxl) more"] else [] end))},
                 {p: "We also still need a document that shows each of these credits:"},
                 {ul: listed($r; $maxl)},
                 {p: $ask} ] + sig) }
    end;
def past_initial($fn; $c; $maxl):
  ($c | length) as $n
  | (["mix_master","producer","writer","engineer","musician","studio_org","anr","other"] - (["mix_master","producer","writer","engineer","musician","studio_org","anr","other"] - [$c[].role_families[]])) as $fams
  | docs as $D
  | (if $n == 1 then
       { subject: "Quick check on your \($c[0].role) credit for \($c[0].track_title | qt) (\($c[0].artist_name))",
         segs: [ {p: "Hi \($fn), I'm Caroline from Muso support. We're doing a routine review of credits that were approved automatically, and one of yours came up: your \($c[0].role) credit on \($c[0].track_title | qt) by \($c[0].artist_name)."},
                 {p: "Nothing has changed on your profile; the credit is still visible. We'd just like one document that shows your role on this recording."} ] }
     else
       { subject: "Quick check on \($n) of your credits on Muso",
         segs: [ {p: "Hi \($fn), I'm Caroline from Muso support. We're doing a routine review of credits that were approved automatically, and \($n) of yours came up (list below)."},
                 {ul: listed($c; $maxl)},
                 {p: "Nothing has changed on your profile; these credits are still visible. We'd just like one document for each credit that shows your role on that recording. A document that names several of these tracks counts for each track it names."} ] }
     end)
  | .segs += [ $fams[] as $f
               | {p: (if ($fams|length) == 1 then "Any one of these is enough:" else "For your \($D[$f].label) credits, any one of these is enough:" end)},
                 {ul: $D[$f].items},
                 ($D[$f].note | select(. != null) | {p: .}) ]
  | .segs += [ {p: "Reply to this message with the file (PDF, PNG or JPG) whenever you can. We check every document and aim to get back to you within 14 days of receiving it. If we don't hear back, nothing is removed: \(it1($n; "the credit stays"; "the credits stay")) on your profile, so you can send a document whenever you're ready."} ]
  | .segs += sig;
def policy_text: {
  artist_by_non_artist: "an artist credit claimed by someone who is not the artist",
  org_on_person: "an organization credit on a person's profile",
  label_role_without_release: "a label or publisher role without a release",
  duplicate_profile: "a duplicate profile"
}[.policy_reason];
# Reason first, then the action (Fable copy review 2026-10-17): leading with "We've removed
# your..." reads as a verdict on the person.
def removal_sentence:
  if .reason == "misattributed" then
    "The public credit data for \(.track_title | qt) by \(.artist_name) lists a different person for \(.role) (\(.source_label)\(if .evidence_url != "" then ": \(.evidence_url)" else "" end)), so we've removed the \(.role) credit from your profile."
  elif .reason == "duplicate" then
    "Your \(.role) credit on \(.track_title | qt) by \(.artist_name) duplicated a credit that is still on your profile, so we've removed the duplicate."
  else
    "Your \(.role) credit on \(.track_title | qt) by \(.artist_name) did not meet our credit guidelines (\(policy_text)), so we've removed it from your profile."
  end;
# Take-back notice, verbatim from docs/credit-verification/retro-drafts/takeback-notice.md.
def tb_names: .other_names | if length <= 1 then (.[0] // "another person") else (.[0:-1] | join(", ")) + " and " + .[-1] end;
def tb_cite: "\(.evidence_source): \(.evidence_url)" + (if (.corroboration_url // "") != "" then "; also named in \(.corroboration_url)" else "" end);
def takeback_notice($fn; $c0; $maxl):
  (reduce $c0[] as $x ([]; if any(.[]; (.track_title | ascii_downcase) == ($x.track_title | ascii_downcase)
       and (.artist_name | ascii_downcase) == ($x.artist_name | ascii_downcase) and (.role | ascii_downcase) == ($x.role | ascii_downcase))
     then . else . + [$x] end)) as $c
  | ($c | length) as $n
  | "If you did this work, reply to this message with one document that shows it, for example an invoice, a work order, or an email from the artist, label or studio that names the track and your role. If the document checks out, we will put the credit back. Your other credits are not affected." as $dispute
  | if $n == 1 then
      $c[0] as $x
      | { subject: "About your \($x.role) credit on \($x.track_title | qt)",
          segs: [ {p: "Hi \($fn),"},
                  {p: "I'm Caroline from Muso support. The public credits for \($x.track_title | qt) by \($x.artist_name) name \($x | tb_names) for \($x.role) (\($x | tb_cite)), so we have removed the \($x.role) credit from your profile."},
                  {p: $dispute}, {p: "Thank you,"}, {p: "Caroline"}, {p: "Muso Support"} ] }
    else
      { subject: "About \($n) of your credits on Muso",
        segs: [ {p: "Hi \($fn),"},
                {p: "I'm Caroline from Muso support. The public credits name someone else for these roles, so we have removed them from your profile:"},
                {ul: ([ $c[0:$maxl][] | "\(.role) on \(.track_title | qt) by \(.artist_name): \(tb_names) (\(tb_cite))" ]
                      + (if $n > $maxl then ["and \($n - $maxl) more"] else [] end))},
                {p: $dispute}, {p: "Thank you,"}, {p: "Caroline"}, {p: "Muso Support"} ] }
    end;
# uvn-status (copy-uvn-status-reminder-1019 section A, firstmate 060 closing-line edit).
# The list sentence is Caroline's Step 2 ask marker, word for word, so her ask-once guard
# sees this note as an ask.
def uvn_list: [ "A public link where the credit is listed: Tidal, Genius, Discogs, AllMusic, ASCAP or BMI.",
                "Documentation of the work: a project or session file, a message with the artist, a contract or split sheet, or anything else that shows you worked on it." ];
def uvn_status($fn; $c; $maxl):
  ($c | length) as $n
  | if $n == 1 then
      $c[0] as $x
      | { subject: "Your Muso credit request: one thing we still need",
          segs: ([ {p: "Hi \($fn), a quick status update on your credit request for \($x.track_title | qt) by \($x.artist_name): it's waiting on one thing from you, something that shows your \($x.role | role_credits)."},
                  {p: "Any one of these works (a link, photo or PDF is fine):"}, {ul: uvn_list},
                  {p: "Just reply to this message with it. You will see the credit on your profile as soon as it is approved, and we will let you know here if anything else is needed."} ] + sig) }
    else
      ([ $c[0:$maxl][] | "\(.track_title | qt)" ]) as $t
      | { subject: "Your Muso credit requests: one thing we still need",
          segs: ([ {p: "Hi \($fn), a quick status update on your credit requests for \($t | andjoin)\(if $n > $maxl then " (and \($n - $maxl) more)" else "" end): they're waiting on one thing from you, something that shows your role on each."},
                  {p: "Any one of these works (a link, photo or PDF is fine):"}, {ul: uvn_list},
                  {p: "Just reply to this message with it. You will see each credit on your profile as soon as it is approved, and we will let you know here if anything else is needed."} ] + sig) }
    end;
# withdrawal-confirm (firstmate 061, verbatim; subject added for the email channel).
def withdrawal_confirm($c):
  $c[0] as $x
  | { subject: "Your Muso credit request for \($x.track_title | qt)",
      segs: [ {p: "Hi! We've withdrawn your credit request for \($x.role) on \($x.track_title | qt), as you asked. Nothing else changes on your profile. If you need anything else, just reply here."} ] };
# Status notes (firstmate 070 verbatim; 071 as credit-trust-llm-t01 drafted). Not asks.
def req_s($n): if $n == 1 then "request" else "requests" end;
def titles($c; $maxl): ([ $c[0:$maxl][] | "\(.track_title | qt)" ] | andjoin) + (if ($c|length) > $maxl then " and \(($c|length) - $maxl) more" else "" end);
def status_doc_received($fn; $c; $maxl):
  { subject: "Your Muso credit \(req_s($c|length)): an update",
    segs: [ {p: "Hi \($fn), a quick update on your credit \(req_s($c|length)) for \(titles($c; $maxl)): we have the document you sent us, and our team is reviewing it. Nothing else is needed from you right now, and you'll see each credit on your profile as soon as it's approved."} ] };
def status_doc_queued($fn; $c; $maxl):
  { subject: "Your Muso credit \(req_s($c|length)): an update",
    segs: [ {p: "Hi \($fn), a quick update on your credit \(req_s($c|length)) for \(titles($c; $maxl)): we have the document you sent, and it's in our review queue. We'll message you here as soon as it's checked - no need to send anything else."} ] };
def status_team_review($fn; $c; $maxl):
  { subject: "Your Muso credit \(req_s($c|length)): an update",
    segs: [ {p: "Hi \($fn), a quick update on your credit \(req_s($c|length)) for \(titles($c; $maxl)): they're with our team for review. Nothing else is needed from you right now. If you have something that shows your role on these specific tracks (for example a credit listing link or a split sheet), you can reply with it and it helps us confirm them faster."} ] };
# Count-only (firstmate inbox 005, verbatim; one request reads in the singular).
def status_team_review_count($fn; $n):
  { subject: "Your Muso credit \(req_s($n)): an update",
    segs: [ {p: (if $n == 1 then "Hi \($fn), a quick update on your pending credit request: it is with our team for review. Nothing else is needed from you right now."
                 else "Hi \($fn), a quick update on your \($n) pending credit requests: they are with our team for review. Nothing else is needed from you right now." end)} ] };
# Card R1 (proof loop, verbatim): the queued line without "no need to send anything else".
def status_doc_received_r1($fn; $c; $maxl):
  { subject: "Your Muso credit \(req_s($c|length)): an update",
    segs: [ {p: "Hi \($fn), a quick update on your credit \(req_s($c|length)) for \(titles($c; $maxl)): we have the document you sent, and it's in our review queue. We'll message you here as soon as it's checked."},
            # L13 (rulings-1028-1430 section 1: "R1 + L13 as a second paragraph", captain 14:3xZ via Fable)
            {p: "A screenshot of Muso itself doesn't show where the credit is published, so it can't be used as proof; a page or document from outside Muso that names you on the track is what we can check."} ] };
def status_team_review_noask($fn; $c; $maxl):
  { subject: "Your Muso credit \(req_s($c|length)): an update",
    segs: [ {p: "Hi \($fn), a quick update on your credit \(req_s($c|length)) for \(titles($c; $maxl)): they're with our team for review. Nothing else is needed from you right now."} ] };
# claim-proof-ask (steers-1830 #5; Fable-approved D38 + paragraph 3 as amended in
# claims-documentation-readiness-1023 ruling 1; send-locked until firstmate's GO): the dated code ask and its
# day-7 reminder. Server facts only: catalog profile name and link, the claim's code, one fixed
# surface phrase, the close day ($due, a plain day).
def claim_ask($fn; $c):
  { subject: "Confirming your claim on \($c.profile_name)",
    segs: ([ {p: "Hi \($fn),"},
             {p: "I'm Caroline from Muso support. You asked to claim \($c.profile_name) on Muso (\($c.profile_url)). To confirm it's you, please add the code \($c.code) to your \($c.surface) by \($due).\(if $c.platform == "spotify" then " Open Spotify for Artists, then Profile, then About, and put the code in your artist bio." else "" end) We check for it every day, and you can remove it once your claim is confirmed."},
             {p: "If the code isn't there by \($due), the claim closes. You can reopen it any time from the profile."},
             {p: "If adding the code isn't possible for you, reply to this message with paperwork that shows your name on one of \($c.profile_name)'s releases: a split sheet, a producer or mixing agreement, an invoice, a royalty or distributor statement, or a PRO registration. Attach it here; we never ask for ID to claim a profile."} ] + sig) };
# claim-status (Fable claims-documentation-readiness-1023 ruling 3, verbatim): no ask, no promise of an outcome.
def claim_status_note($fn; $c):
  { subject: "Your claim on \($c.profile_name)",
    segs: [ {p: "Hi \($fn), a quick update on your claim on \($c.profile_name): it is with our team for review. Nothing else is needed from you right now, and we will message you here as soon as it has been checked."} ] };
# merge-pending (go-live-today line M1, verbatim): status only, names the profiles, no date, no instruction.
def merge_pending($fn; $m):
  { subject: "Your Muso merge request",
    segs: [ {p: "Hi \($fn), a quick update on your request to merge \([ $m.profiles[] ] | andjoin): it's in our review queue, nothing has been changed yet, and we will message you here when it has been checked."} ] };
# credit-hold-status / claim-proof-pending (Fable copy-owing-proof-1027 S1 / S2, verbatim): one sentence each,
# no ask, no date, never "nothing else is needed". S1 for ONE request says "it can't be ... and is waiting"
# (grammar, not new copy: p1 ruling 097 under captain-1028-214x); plural verbatim.
def credit_hold_status($fn; $c; $maxl):
  { subject: "Your Muso credit \(req_s($c|length)): an update",
    segs: [ {p: "Hi \($fn), a quick update on your credit \(req_s($c|length)) for \(titles($c; $maxl)): \(if ($c|length) == 1 then "it can't be approved from the submission alone and is" else "they can't be approved from the submission alone and are" end) waiting on evidence from you, and we will message you here with exactly what we can check as soon as our document review opens, so please wait for that message before sending anything."} ] };
def claim_proof_pending($fn; $c):
  { subject: "Your claim on \($c.profile_name)",
    segs: [ {p: "Hi \($fn), a quick update on your claim on \($c.profile_name): it needs proof that this profile is yours before it can be approved, and we will message you here with the exact step as soon as we can accept it, so please wait for that message before sending anything."} ] };
def claim_ask_reminder($fn; $c):
  { subject: "Your claim on \($c.profile_name)",
    segs: ([ {p: "Hi \($fn),"},
             {p: "A quick reminder about your claim on \($c.profile_name): we haven't found the code \($c.code) in your \($c.surface) yet. Add it by \($due) and our daily check will pick it up."},
             {p: "After \($due) the claim closes, and you can reopen it any time."} ] + sig) };
# email-changed (firstmate 073, verbatim). A threaded reply; the subject is never shown.
def email_changed($dup):
  { subject: "Your Muso sign-in email",
    segs: [ {p: ("Done - your sign-in email has been updated to the new address you gave us. Please sign in again with it."
                 + (if $dup then " The extra account created with that address has been set aside, so you can keep using your original account." else "" end))} ] };
def removal_notice($fn; $c; $maxl):
  ($c | length) as $n
  | "If you think this is a mistake, reply to this message with a document that names you for the role: a split sheet, a label or distributor statement, a PRO or MLC registration, a studio or session invoice, or liner notes or an official release page (PDF, PNG or JPG). We'll review it and can restore the credit." as $dispute
  | if $n == 1 then
      $c[0] as $x
      | { subject: "An update about your \($x.role) credit on \($x.track_title | qt)",
          segs: ([ {p: "Hi \($fn), I'm Caroline from Muso support. \($x | removal_sentence)"}, {p: $dispute} ] + sig) }
    else
      { subject: "An update about \($n) credits on your Muso profile",
        segs: ([ {p: "Hi \($fn), I'm Caroline from Muso support. We've reviewed \($n) credits on your Muso profile (list below) and removed them, each for the reason given."},
                 {ul: ([ $c[0:$maxl][] | removal_sentence ] + (if $n > $maxl then ["and \($n - $maxl) more"] else [] end))},
                 {p: $dispute} ] + sig) }
    end;
# gap-ask (Fable 2026-10-26 13:23Z), the paragraph verbatim but for its last sentence (decision B,
# firstmate inbox 005: "Your request stays open while we look.", accurate for a pending request);
# <doc summary>, <track> and <role> are its only slots. <doc summary> is the stage-2 verdict's best document: its kind (a fixed label, a
# plain "document" when stage 2 could not tell) and up to two OTHER held titles it names (catalog
# titles, never document text). Several credits: up to 3 "<track> as <role>" pairs, then "and N more".
def gap_label: {split_sheet: "split sheet", contract: "contract", invoice: "invoice",
  letter_of_direction: "letter of direction", pro_portal: "PRO registration",
  distributor_portal: "distributor screenshot", dsp_for_artists: "streaming-dashboard screenshot",
  daw_session: "session screenshot", catalog_page: "credits page"}[.];
def gap_plural: {split_sheet: "split sheets", contract: "contracts", invoice: "invoices",
  letter_of_direction: "letters of direction", pro_portal: "PRO registrations",
  distributor_portal: "distributor screenshots", dsp_for_artists: "streaming-dashboard screenshots",
  daw_session: "session screenshots", catalog_page: "credits pages"}[.];
def a_an: if test("^[aeiou]") then "an " + . else "a " + . end;
def orjoin: if length <= 1 then (.[0] // "") else (.[0:-1] | join(", ")) + " or " + .[-1] end;
def roles_as: [ split(",")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0) ] | andjoin;
def gap_summary($c):
  ([ $c[].track_title | ascii_downcase ]) as $asked
  | ([ $c[].doc_lists[] ] | unique | map(select(ascii_downcase as $t | ($asked | any(. == $t)) | not)) | .[0:2]) as $cov
  | (if ($cov | length) > 0 then " for " + ($cov | map(qt) | andjoin) else "" end) as $for
  | ([ $c[].doc_proof ] | unique) as $p | ([ $c[].doc_kind ] | unique) as $k
  | if ($p | length) == 1 then ((($k[0] | gap_label) // "document") | a_an) + $for
    elif ($k | length) == 1 and ($k[0] | gap_plural) != null then ($k[0] | gap_plural) + $for
    else "documents" + $for end;
def gap_ask($fn; $c; $maxl):
  ($c | length) as $n
  | ([ $c[0:$maxl][] | "\(.track_title | qt) as \(.role | roles_as)" ] | orjoin) as $pairs
  | (if $n > $maxl then " (and \($n - $maxl) more of your credits)" else "" end) as $more
  | { subject: (if $n == 1 then "About the document for your \($c[0].role) credit on \($c[0].track_title | qt)"
               else "About the documents for \($n) of your credits on Muso" end),
      segs: ([ {p: "Hi \($fn),"},
               {p: "Thanks for sending your document - we have it on file. It shows \(gap_summary($c)) but does not cover \($pairs)\($more). If you have a tracklist, split sheet, contract, or a DSP/label page that names you on this track, reply with it and we will finish the check. Your request stays open while we look."} ]
             + sig) };
(.user.first_name | split(" ")[0] // "") as $fn0
| (if ($fn0 | test("^\\p{L}[\\p{L}'.-]{0,39}$")) then $fn0 else "there" end) as $fn
| (if $copy == "docrecv" then status_doc_received($fn; .credits; $maxl)
   elif $copy == "docrecvq" then status_doc_queued($fn; .credits; $maxl)
   elif $copy == "docrecvr" then status_doc_received_r1($fn; .credits; $maxl)
   elif $copy == "teamreview" then status_team_review($fn; .credits; $maxl)
   elif $copy == "teamreviewb0" then status_team_review_noask($fn; .credits; $maxl)
   elif $copy == "claimask" then claim_ask($fn; .claim)
   elif $copy == "claimask7" then claim_ask_reminder($fn; .claim)
   elif $copy == "claimstatus" then claim_status_note($fn; .claim)
   elif $copy == "mergepending" then merge_pending($fn; .merge)
   elif $copy == "claimpending" then claim_proof_pending($fn; .claim)
   elif $copy == "credithold" then credit_hold_status($fn; .credits; $maxl)
   elif $copy == "teamreviewcount" then status_team_review_count($fn; (.user.pending_count // (.credits | length)))
   elif $copy == "emailchg" then email_changed(false)
   elif $copy == "emailchgdup" then email_changed(true)
   elif $copy == "withdrawal" then withdrawal_confirm(.credits)
   elif $copy == "uvn" then uvn_status($fn; .credits; $maxl)
   elif $copy == "gap" then gap_ask($fn; .credits; $maxl)
   elif $copy == "takeback" then takeback_notice($fn; .credits; $maxl)
   elif $copy == "removal" then removal_notice($fn; .credits; $maxl)
   elif $copy == "past" then
     past_initial($fn; .credits; $maxl)
   elif $kind == "after-rejection" then after_rejection($fn; .credits; $maxl; $due)
   elif $kind == "initial" then live_initial($fn; .credits; $maxl; $copy == "windowed"; $due)
   else live_followup($fn; .credits; $maxl; $kind; $due) end)
# Status notes carry the approved "Muso Support" sign-off on email only (the handoff copy, firstmate
# 092/103/106); an in-thread reply sits under Caroline's own name in the conversation and stays unsigned.
| (if ($copy | IN("docrecv", "docrecvq", "docrecvr", "teamreview", "teamreviewb0", "teamreviewcount", "credithold")) and $mtype == "email"
   then .segs += [ {p: "Muso Support"} ] else . end)
| (if ($copy | IN("claimstatus", "mergepending", "claimpending")) and $mtype == "email" then .segs += sig else . end)
| { subject: .subject,
    text: ([ .segs[] | if has("ul") then (.ul | map("- " + .) | join("\n")) else .p end ] | join("\n\n")),
    html: ([ .segs[] | if has("ul") then "<ul>" + ([.ul[] | "<li>" + esc + "</li>"] | join("")) + "</ul>" else "<p>" + (.p | esc) + "</p>" end ] | join("")) }
JQ
readonly RENDER_JQ
render() { # <input-json> -> {subject, text, html}
  printf '%s' "$1" | "$JQ_BIN" -c --argjson maxl "$MAX_LISTED" --arg copy "$COPY" --arg kind "$KIND" \
    --arg due "$DUE_LABEL" --argjson rt "$REJECTION_TEXT" --arg mtype "$MESSAGE_TYPE" "$RENDER_JQ"
}

# leak_reason <rendered-json>: empty when clean. Same patterns as a customer-facing
# intercom-ops-write.sh reply, over the subject and the text the user reads.
leak_reason() {
  local flat W E
  flat="$(printf '%s' "$1" | "$JQ_BIN" -r '.subject + " " + .text' | tr -s '[:space:]' ' ')"
  W='(^|[^A-Za-z0-9_])'; E='([^A-Za-z0-9_]|$)'
  if printf '%s' "$flat" | grep -qiE 'github\.com/|gitlab\.com/|issues? +(#|[0-9]{3,})|#[0-9]{3,}|<@U[A-Z0-9]+>'; then
    echo "an issue link, issue number or Slack mention"; return
  fi
  if printf '%s' "$flat" | grep -qiE "${W}(Ops resolution|admin[ _]?id)${E}"; then
    echo "internal wording (Ops resolution / admin id)"; return
  fi
  if printf '%s' "$flat" | grep -qiE "${W}(${SANITIZER_WORDS})${E}"; then
    echo "a word Caroline's outbound sanitizer redacts ('$(printf '%s' "$flat" | grep -oiE "(${SANITIZER_WORDS})" | head -1)')"; return
  fi
  # U+2014 by code point: an escaped byte literal here would trip check-intercom-reply-identity.sh.
  if printf '%s' "$1" | "$JQ_BIN" -e '(.subject + " " + .text) | explode | index([8212]) != null' >/dev/null; then
    echo "an em dash (Caroline's voice never uses one)"; return
  fi
}

# record_refusal <reason>: terminal ledger record (initial notes per request id; a reminder
# by claiming and closing that reminder), then refuse. Only on a real send.
record_refusal() {
  if [ "$ACTION" = "post" ]; then
    if [ "$KIND" = "initial" ]; then
      ledger refuse --campaign "$CAMPAIGN" --user-key "$EMAIL" --day "$DAY" --request-ids "$ALL_IDS" \
        --message-type "$MESSAGE_TYPE" --approved-by "$APPROVED_BY" --approval-ref "$APPROVAL_REF" --reason "$1" \
        --user-id "$USER_ID" >/dev/null
    else
      c="$(ledger claim-reminder --parent-message-id "$PARENT_ID" --kind "$KIND" --user-key "$EMAIL" --day "$DAY" \
        --request-ids "$ALL_IDS" --approved-by "$APPROVED_BY" --approval-ref "$APPROVAL_REF")"
      if [ "$(printf '%s' "$c" | "$JQ_BIN" -r '.result')" = "claimed" ]; then
        ledger finalize --message-row "$(printf '%s' "$c" | "$JQ_BIN" -r '.message_row')" --status refused --reason "$1" >/dev/null
      fi
    fi
  fi
  refuse "$1"
}

RENDERED="$(render "$INPUT")"
leak="$(leak_reason "$RENDERED")"
[ -z "$leak" ] || record_refusal "the rendered note contains $leak (from a track title, artist or role). Customers never see internal surfaces; this note is not sent and the credits are recorded as refused for a human to look at."

payload() { # <rendered-json> <contact-id>
  if [ -n "$THREAD" ]; then
    printf '%s' "$1" | "$JQ_BIN" -c --arg admin "$INTERCOM_ADMIN_ID" \
      '{message_type: "comment", type: "admin", admin_id: $admin, body: .html}'
    return
  fi
  printf '%s' "$1" | "$JQ_BIN" -c --arg mt "$REQ_TYPE" --arg admin "$INTERCOM_ADMIN_ID" --arg to "$2" \
    '{message_type: $mt, template: "personal", from: {type: "admin", id: $admin}, to: {type: "user", id: $to}, body: .html}
     + {subject: .subject}'
}

case "$ACTION" in
  validate)
    # takeback-notice: credit-retro validates every notice BEFORE it executes the removal, so
    # --validate says whether today's send would be deferred by the one-message-per-day cap.
    if [ "$CAMPAIGN" = "takeback-notice" ] && [ -r "$LEDGER_HELPER" ] && [ -f "$LEDGER" ]; then
      vpeek="$(ledger pending --campaign "$CAMPAIGN" --user-key "$EMAIL" --user-id "$USER_ID" --day "$DAY" --request-ids "$ALL_IDS")" \
        || die "the ledger read failed."
      if [ "$(printf '%s' "$vpeek" | "$JQ_BIN" -r '.daily_cap')" = "true" ]; then
        printf 'DEFERRED daily-cap credits=%s (this user already had a message on %s UTC)\n' "$N" "$DAY"; exit 3
      fi
    fi
    printf 'VALID %s %s %s credits=%s%s\n' "$CAMPAIGN" "$KIND" "$MESSAGE_TYPE" "$N" " copy=$COPY"; exit 0 ;;
  dry-run)
    printf 'DRY-RUN %s %s %s credits=%s%s%s\n' "$CAMPAIGN" "$KIND" "$MESSAGE_TYPE" "$N" " copy=$COPY" "${THREAD:+ conversation=$THREAD}"
    payload "$RENDERED" "<resolved from the account email at send time>" | "$JQ_BIN" .
    exit 0 ;;
esac


# ---------------------------------------------------------------------------------------
# Recipient. An initial note goes to exactly one Intercom USER whose email is the account
# email and whose external_id is this account (ext_is_account: its professional id, firstmate
# 090). When several users share the email, the one whose external_id is this account is it
# (firstmate 091). A lead, zero matches, several (with none or several of them this account),
# a contact with no external_id, or one whose external_id names a different Muso user is a
# refusal; we never guess who a note about someone's credits goes
# to. A reminder goes to the contact its note went to (checked against the ledger above).
# email-changed / email-changed-dup are the exception (firstmate 076): no email search; the
# recipient is the ticket conversation's single contact, an Intercom user whose external_id is
# this account (ext_is_account). Their account email only keys the ledger.
# In-thread legacy-id match (firstmate 089; withdrawal-confirm and email-changed in-thread
# replies ONLY): a legacy account (no Auth0 subject, or an external_id we cannot map) is still
# answered in its own conversation when that conversation's one user contact has the account
# email, the email is not a shared or role inbox, and the driver checked on the replica that the
# contact's external_id is not another Muso account (user.ext_other_account=false for
# user.thread_external_id). Recorded with reason in-thread-legacy-id.
readonly ROLE_INBOXES="info support help admin contact hello office team booking bookings management mgmt music label records publishing accounts billing sales marketing press media studio noreply no-reply mail enquiries inquiries"
LEGACY_MATCH=""
legacy_why() { # <contact-json> <external_id> -> prints why the legacy match does not hold ('' when it does)
  local cemail lp
  cemail="$(printf '%s' "$1" | "$JQ_BIN" -r '(.email // "") | ascii_downcase | gsub("^\\s+|\\s+$"; "")')"
  if [ -z "$cemail" ] || [ "$cemail" != "$EMAIL" ]; then echo "the contact's email is not the Muso account email"; return 0; fi
  lp="${EMAIL%%@*}"; lp="${lp%%+*}"
  case " $ROLE_INBOXES " in *" $lp "*) echo "the account email is a shared or role inbox ($lp@)"; return 0 ;; esac
  if [ -z "$EXT_OTHER" ] || [ "$THREAD_EXT" != "$2" ]; then
    echo "the contact's external_id was not checked against the Muso accounts (user.ext_other_account missing, or for another external_id)"; return 0
  fi
  [ "$EXT_OTHER" = "false" ] || echo "the contact's external_id belongs to a different Muso account"
}
# read_thread_contact: THREAD_CONTACTS (JSON array of the conversation's contact ids) and
# THREAD_CONTACT_JSON (that contact, when there is exactly one). A failed read exits 4.
read_thread_contact() {
  local tconv cid
  tconv="$(api GET "/conversations/$THREAD?display_as=plaintext")" \
    || { printf 'CONVERSATION READ FAILED (curl); nothing was sent or claimed:\n%s\n' "$tconv" >&2; exit 4; }
  printf '%s' "$tconv" | "$JQ_BIN" -e --arg t "$THREAD" '(.type // "") == "conversation" and ((.id // "") | tostring) == $t' >/dev/null 2>&1 \
    || { printf 'CONVERSATION NOT VERIFIED; nothing was sent or claimed:\n%s\n' "${tconv:0:300}" >&2; exit 4; }
  THREAD_CONTACTS="$(printf '%s' "$tconv" | "$JQ_BIN" -c '[(.contacts.contacts // [])[] | (.id // "") | tostring]')"
  THREAD_CONTACT_JSON=""
  [ "$(printf '%s' "$THREAD_CONTACTS" | "$JQ_BIN" -r 'length')" -eq 1 ] || return 0
  cid="$(printf '%s' "$THREAD_CONTACTS" | "$JQ_BIN" -r '.[0]')"
  printf '%s' "$cid" | grep -qE '^[A-Za-z0-9]{1,40}$' || { echo "CONTACT NOT VERIFIED: contact id is missing or malformed; nothing was sent" >&2; exit 4; }
  THREAD_CONTACT_JSON="$(api GET "/contacts/$cid")" \
    || { printf 'CONTACT READ FAILED (curl); nothing was sent or claimed:\n%s\n' "$THREAD_CONTACT_JSON" >&2; exit 4; }
  printf '%s' "$THREAD_CONTACT_JSON" | "$JQ_BIN" -e --arg c "$cid" '(.type // "") == "contact" and ((.id // "") | tostring) == $c' >/dev/null 2>&1 \
    || { printf 'CONTACT NOT VERIFIED; nothing was sent or claimed:\n%s\n' "${THREAD_CONTACT_JSON:0:300}" >&2; exit 4; }
}
if [ "$ACTION" = "thread-contact" ]; then
  # Read only: what the driver needs to check the thread contact's external_id on the replica.
  read_thread_contact
  printf 'THREAD_CONTACT %s\n' "$("$JQ_BIN" -nc --argjson ids "$THREAD_CONTACTS" --arg c "$THREAD_CONTACT_JSON" '
    ($c | if . == "" then {} else fromjson end) as $x
    | {contacts: ($ids | length), role: ($x.role // ""), external_id: (($x.external_id // "") | tostring)}')"
  exit 0
fi
if [ "$KIND" = "initial" ] && { [ "$CAMPAIGN" = "email-changed" ] || [ "$CAMPAIGN" = "email-changed-dup" ]; }; then
  # The ticket's own conversation names the recipient: they may not have signed in with the
  # new address yet, and on a dup the new address's contact is the extra account's.
  read_thread_contact
  n_tc="$(printf '%s' "$THREAD_CONTACTS" | "$JQ_BIN" -r 'length')"
  [ "$n_tc" -eq 1 ] || record_refusal "conversation $THREAD has $n_tc contacts (need exactly 1, the account's own Intercom user); not sending."
  CONTACT_ID="$(printf '%s' "$THREAD_CONTACTS" | "$JQ_BIN" -r '.[0]')"
  tc="$THREAD_CONTACT_JSON"
  [ "$(printf '%s' "$tc" | "$JQ_BIN" -r '.role // ""')" = "user" ] \
    || record_refusal "conversation $THREAD's contact is not an Intercom user (a lead or visitor); not sending."
  t_ext="$(printf '%s' "$tc" | "$JQ_BIN" -r '(.external_id // "") | tostring')"
  [ -n "$t_ext" ] || record_refusal "$NO_EXT_ID_WHY"
  if ! ext_is_account "$t_ext"; then
    why="$(legacy_why "$tc" "$t_ext")"
    [ -z "$why" ] || record_refusal "conversation $THREAD's contact is not linked to this Muso account (external_id is not the account's professional id or Auth0 subject), and the in-thread legacy-id match does not hold: $why; not sending."
    LEGACY_MATCH="contact=$CONTACT_ID external_id=$t_ext"
  fi
elif [ "$KIND" = "initial" ]; then
  search="$(printf '%s' "$EMAIL" | "$JQ_BIN" -Rc '{query: {field: "email", operator: "=", value: .}}' | api POST /contacts/search)" \
    || { printf 'CONTACT LOOKUP FAILED (curl); nothing was sent or claimed:\n%s\n' "$search" >&2; exit 4; }
  printf '%s' "$search" | "$JQ_BIN" -e '(.data|type) == "array"' >/dev/null 2>&1 \
    || { printf 'CONTACT LOOKUP NOT VERIFIED (no data[]); nothing was sent or claimed:\n%s\n' "$search" >&2; exit 4; }
  users="$(printf '%s' "$search" | "$JQ_BIN" -c --arg e "$EMAIL" '[.data[] | select(.role == "user" and ((.email // "") | ascii_downcase) == $e)]')"
  n_users="$(printf '%s' "$users" | "$JQ_BIN" -r 'length')"
  if [ "$n_users" -ge 2 ] && { [ -n "$PRO_ID" ] || [ -n "$AUTH_ID" ]; }; then
    # Several Intercom users share the email (firstmate 091): the ONE whose external_id is this
    # account is the recipient; none or more than one is a refusal.
    users="$(printf '%s' "$users" | "$JQ_BIN" -c --arg p "$PRO_ID" --arg a "$AUTH_ID" '
      [.[] | ((.external_id // "") | tostring) as $x
       | select($x != "" and (($p != "" and $x == $p) or ($a != "" and ($x == $a or $x == ("auth0|" + $a)))))]')"
    [ "$(printf '%s' "$users" | "$JQ_BIN" -r 'length')" -eq 1 ] \
      || record_refusal "the account email matches $n_users Intercom users (need exactly 1, or exactly one whose external_id is this account); not sending."
  else
    [ "$n_users" -eq 1 ] || record_refusal "the account email matches $n_users Intercom users (need exactly 1); not sending."
  fi
  CONTACT_ID="$(printf '%s' "$users" | "$JQ_BIN" -r '.[0].id')"
  EXT_ID="$(printf '%s' "$users" | "$JQ_BIN" -r '.[0].external_id // empty')"
  [ -n "$EXT_ID" ] || record_refusal "$NO_EXT_ID_WHY"
  # An account-specific note needs the account named (QA @3112769): with no
  # user.professional_id or user.auth_id, any external_id would pass. The one exception is
  # removal-notice, whose recipient is the profile's single CLAIMED WORKSPACE email
  # (credit_review.verify_notify.profile_owner): that campaign has no Muso user id to compare.
  # #1298 (firstmate 120): the account's Intercom IDENTITY is required, a bare numeric user.id
  # is not enough (no client identifies with it).
  if [ -z "$PRO_ID" ] && [ -z "$AUTH_ID" ] && [ "$CAMPAIGN" != "removal-notice" ]; then
    record_refusal "the note carries no account Intercom identity (user.professional_id or user.auth_id: professionalId or Auth0 subject), so the Intercom contact cannot be verified as its owner; not sending."
  fi
  if [ "$CAMPAIGN" = "withdrawal-confirm" ] && [ -n "$THREAD" ] && ! ext_is_account "$EXT_ID"; then
    why="$(legacy_why "$(printf '%s' "$users" | "$JQ_BIN" -c '.[0]')" "$EXT_ID")"
    [ -z "$why" ] || record_refusal "the Intercom user for this email is not linked to this Muso account by its professional id or Auth0 subject, and the in-thread legacy-id match does not hold: $why; not sending."
    LEGACY_MATCH="contact=$CONTACT_ID external_id=$EXT_ID"
  elif { [ -n "$USER_ID" ] || [ -n "$PRO_ID" ] || [ -n "$AUTH_ID" ]; } && ! ext_is_account "$EXT_ID"; then
    record_refusal "the Intercom user for this email belongs to a different Muso account (external_id mismatch); not sending."
  fi
fi
printf '%s' "$CONTACT_ID" | grep -qE '^[A-Za-z0-9]{1,40}$' || { echo "CONTACT NOT VERIFIED: contact id is missing or malformed; nothing was sent" >&2; exit 4; }

# Go-live recipient guards (security-arch-fable-s1 section 9.2, BINDING per program-lead-fable-p2 inbox 075) for the
# first-message cohorts: credit-hold-status, claim-proof-pending, merge-pending and the R1 receipt (docrecvr). Real
# sends only. A guard that fails sends nothing and claims nothing: G1 defers (exit 3; retried once the contact is
# old enough), the others refuse (exit 1) for a person to look at. Never a ledger refusal row: a guard failure is
# about our side's certainty, not the user.
# The clock G1 reads; the test copy pins it (INTERCOM_VERIFY_TEST_NOW, epoch) so the 24h rule is testable.
g1_now() { if [ "$TESTABLE" = "1" ] && [ -n "${INTERCOM_VERIFY_TEST_NOW:-}" ]; then printf '%s' "$INTERCOM_VERIFY_TEST_NOW"; else date -u +%s; fi; }
GOLIVE=0
case "$CAMPAIGN:$COPY" in merge-pending:*|credit-hold-status:*|claim-proof-pending:*|status-doc-received:docrecvr|uvn-status:*) GOLIVE=1 ;; esac
if [ "$GOLIVE" = "1" ] && [ "$ACTION" = "post" ]; then
  # G4: the recipient is the ACCOUNT behind the request, never a staff address.
  case "$EMAIL" in *@muso.ai|*.muso.ai) refuse "G4: the recipient email is a Muso staff address; nothing was sent or claimed." ;; esac
  # G5: no link, address or markup in any interpolated field (names and titles are third-party text).
  # Checked TWICE (QA #1456):
  #  - on the RAW credits file: INPUT's clean() has already turned control characters into spaces, which would hide
  #    a newline; and any field that is not a string (an object, array, number or boolean that clean()'s tostring
  #    would render, e.g. merge.profiles=[{"label":"https://..."}]) is a violation by itself;
  #  - on the NORMALIZED INPUT, the exact text that renders.
  g5def='def g5f: [ .user.first_name, (.credits[]? | .track_title, .artist_name, .role),
      ((.merge.profiles // [])[]?), (.claim.profile_name // null), ((.need // {}).issuer // null) ];
    def bad: test("https?:|www\\.|@|<|>|[[:cntrl:]]"; "i");'
  g5raw="$("$JQ_BIN" -r "$g5def"' g5f | map(select(. != null and (type != "string" or (. != "-" and bad)))) | length' "$CREDITS_FILE" 2>/dev/null || echo unreadable)"
  g5norm="$(printf '%s' "$INPUT" | "$JQ_BIN" -r "$g5def"' g5f | map(select(type == "string" and . != "-" and bad)) | length' 2>/dev/null || echo unreadable)"
  g5="$g5raw"; [ "$g5raw" = "0" ] && g5="$g5norm"
  [ "$g5" = "0" ] || refuse "G5: $g5 interpolated field(s) carry a link, an address or markup; nothing was sent or claimed."
  # The recipient contact: the thread's single contact in-thread, else the contact the email lookup picked.
  if [ -n "$THREAD" ]; then
    # G2: the thread must be opened by the customer, carry exactly one contact, an Intercom USER, and that
    # contact must be the account's own (the one the identity checks chose).
    [ -n "${THREAD_CONTACTS:-}" ] || read_thread_contact
    [ "$(printf '%s' "$THREAD_CONTACTS" | "$JQ_BIN" -r 'length')" = "1" ] \
      || refuse "G2: conversation $THREAD has $(printf '%s' "$THREAD_CONTACTS" | "$JQ_BIN" -r 'length') contacts (need exactly 1); nothing was sent or claimed."
    [ "$(printf '%s' "$THREAD_CONTACTS" | "$JQ_BIN" -r '.[0]')" = "$CONTACT_ID" ] \
      || refuse "G2: conversation $THREAD's contact is not the account's Intercom user; nothing was sent or claimed."
    g2conv="$(api GET "/conversations/$THREAD?display_as=plaintext")" \
      || { printf 'CONVERSATION READ FAILED (curl); nothing was sent or claimed\n' >&2; exit 4; }
    printf '%s' "$g2conv" | "$JQ_BIN" -e '((.source.author.type // "") | IN("user", "lead", "contact"))' >/dev/null 2>&1 \
      || refuse "G2: conversation $THREAD was opened by us (an admin or bot), not the customer; nothing was sent or claimed."
    G_CONTACT="$THREAD_CONTACT_JSON"
  else
    G_CONTACT="$(api GET "/contacts/$CONTACT_ID")" \
      || { printf 'CONTACT READ FAILED (curl); nothing was sent or claimed\n' >&2; exit 4; }
  fi
  [ "$(printf '%s' "$G_CONTACT" | "$JQ_BIN" -r '.role // ""')" = "user" ] \
    || refuse "G4: the recipient contact is not an Intercom user (a lead or visitor); nothing was sent or claimed."
  # G3 (R1 only): the receipt goes to the contact that FILED the document. The caller passes the proof_intake row's
  # conversation as user.filing_conversation; its single contact must be this account's contact.
  if [ "$COPY" = "docrecvr" ]; then
    fconv="$(printf '%s' "$INPUT_FILING_CONV" | grep -E '^[0-9]{1,24}$' || true)"
    [ -n "$fconv" ] || refuse "G3: the receipt names no filing conversation (user.filing_conversation); nothing was sent or claimed."
    g3="$(api GET "/conversations/$fconv?display_as=plaintext")" \
      || { printf 'CONVERSATION READ FAILED (curl); nothing was sent or claimed\n' >&2; exit 4; }
    [ "$(printf '%s' "$g3" | "$JQ_BIN" -r '[(.contacts.contacts // [])[] | (.id // "") | tostring] | join(",")')" = "$CONTACT_ID" ] \
      || refuse "G3: the contact that filed the document (conversation $fconv) is not this receipt's recipient; nothing was sent or claimed (tray)."
  fi
  # G1: the contact existed for more than 24 hours, and before the oldest request this note names (when given).
  { [ "${INPUT_RAW_CREATED:-}" != "BAD" ] && { [ -z "${INPUT_RAW_CREATED:-}" ] || printf '%s' "$INPUT_RAW_CREATED" | grep -qE '^[0-9]{1,12}$'; }; } \
    || refuse "G1: a request creation time the caller supplied does not parse; nothing was sent or claimed."
  printf '%s' "${INPUT_RAW_CREATED:-}" | grep -qE '^[0-9]{1,12}$' || INPUT_RAW_CREATED="null"
  g1="$(printf '%s' "$G_CONTACT" | "$JQ_BIN" -r --argjson now "$(g1_now)" --argjson oldest "$INPUT_RAW_CREATED" '
      (.created_at // 0) as $c
      | if ($c | type) != "number" or $c <= 0 then "unknown"
        elif $c > $now - 86400 then "fresh"
        elif $oldest != null and $c >= $oldest then "newer_than_request"
        else "ok" end')"
  case "$g1" in
    ok) ;;
    fresh|newer_than_request) printf 'DEFERRED g1_contact_%s credits=%s\n' "$g1" "$N"; exit 3 ;;
    *) refuse "G1: the recipient contact's creation time is unreadable; nothing was sent or claimed." ;;
  esac
fi
# The "nothing else is needed" family (message-book-1029 A2/A3/C3/C4/D3: status-doc-received default/queued,
# status-team-review, claim-status) only ever goes to a user who owes NOTHING (Fable [key=message-book-1029], captain
# 'just go'): comm_state reads it at send (UVN row, review hold, account hold, open ask -> held).
NIE=0
case "$CAMPAIGN:$COPY" in status-team-review:*|claim-status:*|status-doc-received:docrecv|status-doc-received:docrecvq) NIE=1 ;; esac
if { [ "$GOLIVE" = "1" ] || [ "$NIE" = "1" ]; } && [ "$ACTION" = "post" ]; then
  # The user's communication state, read from the live stores RIGHT NOW (captain 18:2xZ; comm_state.py): the
  # "wait for our message" lines never go to anyone with a document or reply on file (they get R1 or nothing), R1
  # never after a decision was told, nothing within 7 days of another note. A hold is logged in verify_messages
  # as 'deferred' (never a lock); an unreadable state sends nothing.
  [ -r "$COMM_STATE_HELPER" ] || { echo "COMM STATE CHECK NOT POSSIBLE: $COMM_STATE_HELPER is missing; nothing was sent or claimed" >&2; exit 4; }
  set +e
  CS="$("$PY_BIN" -I "$COMM_STATE_HELPER" check --campaign "$CAMPAIGN" --copy "$COPY" --user-id "$USER_ID" \
        --request-ids "$ALL_IDS" --contact-id "$CONTACT_ID" \
        --conversation "$(if [ "$COPY" = "docrecvr" ]; then printf '%s' "${fconv:-}"; else printf '%s' "${THREAD:-}"; fi)" 2>/dev/null)"; cs_rc=$?
  set -e
  case "$cs_rc" in
    0) ;;
    3) cs_why="$(printf '%s' "$CS" | "$JQ_BIN" -r '(.state // "") + ": " + ((.reasons // []) | join("; "))' 2>/dev/null)"
       ledger log-deferral --campaign "$CAMPAIGN" --user-key "$EMAIL" --user-id "$USER_ID" --day "$DAY" \
         --request-ids "$ALL_IDS" --message-type "$MESSAGE_TYPE" --approved-by "$APPROVED_BY" \
         --approval-ref "$APPROVAL_REF" --reason comm_state --detail "$cs_why" >/dev/null \
         || echo "WARNING: the comm_state hold was not logged in the ledger" >&2
       printf 'HELD comm_state credits=%s (%s)\n' "$N" "$cs_why"; exit 3 ;;
    *) printf 'COMM STATE CHECK FAILED (rc=%s); nothing was sent or claimed: %s\n' "$cs_rc" "${CS:0:300}" >&2; exit 4 ;;
  esac
fi

# ---------------------------------------------------------------------------------------
# Never ask someone who already sent documents (captain standing order, verbatim: "make sure
# you arent asking for things from users that already submitted documents and we approved.
# dont piss anyoen off"). retro-past only: a NEW credit (verify-live) is never skipped for a
# generic attachment; its documents rule is per credit, in the driver. Any Intercom conversation of this contact that carries a document
# the USER attached (a user-authored part or opening message with attachments), or that we
# tagged credit-proof, means they already sent something: the note is skipped and its credits
# closed. Email replies land in Intercom too, so this covers both channels. When in doubt we
# do not send: a contact with more conversations than we can check counts as "sent".
# The text of the conversations is never extracted; only authors, attachment counts and tags.
DOC_SCAN_MAX=150
docs_submitted() { # <contact-id> -> prints the reason when documents exist; exit 4 on a failed read
  local contact="$1" after="" body ids n total=0 cid convo
  while :; do
    body="$(printf '%s' "$contact" | "$JQ_BIN" -Rc --arg after "$after" \
      '{query: {field: "contact_ids", operator: "=", value: .}, pagination: ({per_page: 50} + (if $after == "" then {} else {starting_after: $after} end))}' \
      | api POST /conversations/search)" || { printf 'DOCUMENT CHECK FAILED (curl); nothing was sent or claimed:\n%s\n' "$body" >&2; exit 4; }
    printf '%s' "$body" | "$JQ_BIN" -e '(.conversations|type) == "array"' >/dev/null 2>&1 \
      || { printf 'DOCUMENT CHECK NOT VERIFIED (no conversations[]); nothing was sent or claimed:\n%s\n' "$body" >&2; exit 4; }
    if printf '%s' "$body" | "$JQ_BIN" -e --arg tag "$PROOF_TAG" '[.conversations[] | ((.tags.tags // [])[] | (.name // "") | ascii_downcase) | select(. == $tag)] | length > 0' >/dev/null; then
      echo "a conversation is tagged $PROOF_TAG"; return 0
    fi
    if printf '%s' "$body" | "$JQ_BIN" -e '[.conversations[] | select((.source.author.type // "") == "user" and ((.source.attachments // []) | length) > 0)] | length > 0' >/dev/null; then
      echo "the user opened a conversation with an attachment"; return 0
    fi
    ids="$(printf '%s' "$body" | "$JQ_BIN" -r '.conversations[].id | tostring')"
    n="$(printf '%s' "$body" | "$JQ_BIN" -r '.conversations | length')"
    total=$((total + n))
    [ "$total" -le "$DOC_SCAN_MAX" ] || { echo "more than $DOC_SCAN_MAX conversations to check (counted as sent)"; return 0; }
    for cid in $ids; do
      printf '%s' "$cid" | grep -qE '^[0-9]{1,24}$' || { echo "DOCUMENT CHECK NOT VERIFIED: conversation id '$cid' is not numeric" >&2; exit 4; }
      convo="$(api GET "/conversations/$cid?display_as=plaintext")" \
        || { printf 'DOCUMENT CHECK FAILED (curl) on conversation %s; nothing was sent or claimed:\n%s\n' "$cid" "$convo" >&2; exit 4; }
      printf '%s' "$convo" | "$JQ_BIN" -e '(.type // "") == "conversation"' >/dev/null 2>&1 \
        || { printf 'DOCUMENT CHECK NOT VERIFIED on conversation %s; nothing was sent or claimed:\n%s\n' "$cid" "$convo" >&2; exit 4; }
      if printf '%s' "$convo" | "$JQ_BIN" -e '[(.conversation_parts.conversation_parts // [])[] | select((.author.type // "") == "user" and ((.attachments // []) | length) > 0)] | length > 0' >/dev/null; then
        echo "the user attached a document in a conversation"; return 0
      fi
    done
    after="$(printf '%s' "$body" | "$JQ_BIN" -r '.pages.next.starting_after // empty')"
    [ -n "$after" ] || return 0
  done
}
# uvn-status: never within 7 days of any message from us. The ledger covers this gate; this
# covers everything else in Intercom (Caroline, an admin, an outbound message): any of the
# contact's conversations updated in the last 7 days whose opening message (sent in those 7
# days) or any part in those 7 days was written by an admin or bot. A failed read sends
# nothing; a truncated one counts as "messaged". gap-ask leaves out exactly the messages in
# FOLLOWED_IDS (the user's status-doc-received notes of those 7 days, from the ledger: the gap
# ask is the follow-up they promised); every other message from us still defers it.
FOLLOWED_IDS="[]"
recently_messaged() { # <contact-id> -> prints the reason when we wrote to them in 7 days; exit 4 on a failed read
  local contact="$1" since body ids n cid convo ex="$FOLLOWED_IDS"
  since=$(( $(date -u +%s) - 7*86400 ))
  body="$(printf '%s' "$contact" | "$JQ_BIN" -Rc --argjson since "$since" \
    '{query: {operator: "AND", value: [{field: "contact_ids", operator: "=", value: .}, {field: "updated_at", operator: ">", value: $since}]}, pagination: {per_page: 50}}' \
    | api POST /conversations/search)" || { printf 'RECENT-CONTACT CHECK FAILED (curl); nothing was sent or claimed:\n%s\n' "$body" >&2; exit 4; }
  printf '%s' "$body" | "$JQ_BIN" -e '(.conversations|type) == "array" and ((.total_count // 0) | type) == "number"' >/dev/null 2>&1 \
    || { printf 'RECENT-CONTACT CHECK NOT VERIFIED; nothing was sent or claimed:\n%s\n' "$body" >&2; exit 4; }
  n="$(printf '%s' "$body" | "$JQ_BIN" -r '.total_count // (.conversations | length)')"
  [ "$n" -le 50 ] || { echo "more than 50 conversations in 7 days (counted as messaged)"; return 0; }
  if printf '%s' "$body" | "$JQ_BIN" -e --argjson since "$since" --argjson ex "$ex" '[.conversations[] | select(((.source.author.type // "") | IN("admin","bot","team")) and ((.created_at // 0) > $since)
       and (((.source.id // "") | tostring) as $s | $ex | any(. == $s) | not))] | length > 0' >/dev/null; then
    echo "we started a conversation with them in the last 7 days"; return 0
  fi
  ids="$(printf '%s' "$body" | "$JQ_BIN" -r '.conversations[].id | tostring')"
  for cid in $ids; do
    printf '%s' "$cid" | grep -qE '^[0-9]{1,24}$' || { echo "RECENT-CONTACT CHECK NOT VERIFIED: conversation id '$cid' is not numeric" >&2; exit 4; }
    convo="$(api GET "/conversations/$cid?display_as=plaintext")" \
      || { printf 'RECENT-CONTACT CHECK FAILED (curl) on conversation %s; nothing was sent or claimed\n' "$cid" >&2; exit 4; }
    printf '%s' "$convo" | "$JQ_BIN" -e '(.type // "") == "conversation"' >/dev/null 2>&1 \
      || { printf 'RECENT-CONTACT CHECK NOT VERIFIED on conversation %s; nothing was sent or claimed\n' "$cid" >&2; exit 4; }
    if printf '%s' "$convo" | "$JQ_BIN" -e --argjson since "$since" --argjson ex "$ex" '[(.conversation_parts.conversation_parts // [])[] | select(((.author.type // "") | IN("admin","bot","team")) and (.part_type // "") != "note" and ((.created_at // 0) > $since) and ((.body // "") != "")
       and (((.id // "") | tostring) as $p | $ex | any(. == $p) | not))] | length > 0' >/dev/null; then
      echo "we replied to them in the last 7 days"; return 0
    fi
  done
  return 0
}
case "$CAMPAIGN" in uvn-status|status-doc-received|status-team-review|claim-status|gap-ask|merge-pending|credit-hold-status|claim-proof-pending) STATUSLIKE=1 ;; *) STATUSLIKE=0 ;; esac
# A claim ask never crosses a person: any admin or Caroline reply to this user in the last 7
# days defers the note AND its reminder (nothing closed; the next run looks again; a reminder
# deferred past the day before the close day is never sent).
[ "$CAMPAIGN" != "claim-proof-ask" ] || STATUSLIKE=1
if [ "$STATUSLIKE" = "1" ] && [ "$ACTION" = "post" ]; then
  # gap-ask is never skipped for documents in Intercom: a document on file is why it is sent.
  if [ "$CAMPAIGN" = "gap-ask" ]; then
    FOLLOWED_IDS="$(ledger followed-notes --user-key "$EMAIL" --user-id "$USER_ID" | "$JQ_BIN" -c '.message_ids')" \
      || die "the ledger read failed; refusing to send without the idempotency record."
  fi
  # uvn-status asks for something, so a user who already sent documents is skipped; the
  # status notes are exactly for users with documents or requests with us, so they are not.
  # Stage-2 no_document (Fable 2026-10-26 13:23Z GO 2): when the proof store says every credit
  # of this note was judged and NOTHING readable is on file for it, for THIS account, the
  # Intercom attachment scan is what stage 2 already read; the approved uvn-status copy goes.
  # The verdict is read here, never taken from the caller; anything else keeps the scan.
  S2_NODOC=0
  if [ "$CAMPAIGN" = "uvn-status" ] && [ -r "$STAGE2_HELPER" ] && printf '%s' "$USER_ID" | grep -qE '^[0-9]{1,12}$'; then
    s2n="$("$PY_BIN" -I "$STAGE2_HELPER" --db "$PROOF_DB" gap-credits --outcome no_document --request-ids "$ALL_IDS" --user-id "$USER_ID" 2>/dev/null || true)"
    [ "$(printf '%s' "$s2n" | "$JQ_BIN" -r '.eligible // false' 2>/dev/null || echo false)" != "true" ] || S2_NODOC=1
  fi
  if [ "$CAMPAIGN" = "uvn-status" ] && [ "$S2_NODOC" != "1" ]; then
    DOCS_WHY="$(docs_submitted "$CONTACT_ID")"
    if [ -n "$DOCS_WHY" ]; then
      ledger skip --campaign "$CAMPAIGN" --request-ids "$ALL_IDS" >/dev/null || die "the ledger write failed."
      printf 'SKIPPED docs_submitted credits=%s (%s)\n' "$N" "$DOCS_WHY"; exit 0
    fi
  fi
  RECENT_WHY="$(recently_messaged "$CONTACT_ID")"
  if [ -n "$RECENT_WHY" ]; then
    # Not closed: the user may get this note once the 7 days have passed.
    printf 'DEFERRED messaged_7d credits=%s (%s)\n' "$N" "$RECENT_WHY"; exit 3
  fi
  # In-thread when the user has a conversation going: their most recently updated OPEN
  # conversation of the last 14 days. None: email. A failed lookup sends nothing.
  # claim-proof-ask always goes by email.
  if [ -z "$THREAD" ] && [ "$CAMPAIGN" != "claim-proof-ask" ]; then
    since14=$(( $(date -u +%s) - 14*86400 ))
    open="$(printf '%s' "$CONTACT_ID" | "$JQ_BIN" -Rc --argjson since "$since14" \
      '{query: {operator: "AND", value: [{field: "contact_ids", operator: "=", value: .}, {field: "state", operator: "=", value: "open"}, {field: "updated_at", operator: ">", value: $since}]}, pagination: {per_page: 50}}' \
      | api POST /conversations/search)" || { printf 'OPEN-CONVERSATION LOOKUP FAILED (curl); nothing was sent or claimed:\n%s\n' "$open" >&2; exit 4; }
    printf '%s' "$open" | "$JQ_BIN" -e '(.conversations|type) == "array"' >/dev/null 2>&1 \
      || { printf 'OPEN-CONVERSATION LOOKUP NOT VERIFIED; nothing was sent or claimed:\n%s\n' "$open" >&2; exit 4; }
    THREAD="$(printf '%s' "$open" | "$JQ_BIN" -r --argjson since "$since14" \
      '[.conversations[] | select((.state // "") == "open" and ((.updated_at // 0) > $since))] | max_by(.updated_at) | .id // empty | tostring')"
    if [ -n "$THREAD" ]; then
      printf '%s' "$THREAD" | grep -qE '^[0-9]{1,24}$' || { echo "OPEN-CONVERSATION LOOKUP NOT VERIFIED: conversation id '$THREAD' is not numeric" >&2; exit 4; }
      THREAD_AUTO=1; MESSAGE_TYPE="comment"
    fi
  fi
fi
# In-thread delivery: only into this user's own conversation, never one a person is handling
# or one tagged do-not-message. An explicit --conversation that fails is a recorded refusal
# (nothing sent); a conversation the gate picked itself that fails is dropped and the note
# goes by email, so the ask stays open and is delivered.
thread_check() { # sets THREAD_WHY (empty when $THREAD can carry the note) and THREAD_UNREAD
  local tconv assignee btag
  THREAD_WHY="" THREAD_UNREAD=0
  if ! tconv="$(api GET "/conversations/$THREAD?display_as=plaintext")" \
     || ! printf '%s' "$tconv" | "$JQ_BIN" -e --arg t "$THREAD" '(.type // "") == "conversation" and ((.id // "") | tostring) == $t' >/dev/null 2>&1; then
    THREAD_UNREAD=1; THREAD_WHY="conversation $THREAD could not be read: ${tconv:0:300}"; return 0
  fi
  if [ "$(printf '%s' "$tconv" | "$JQ_BIN" -r '[(.contacts.contacts // [])[] | (.id // "") | tostring] | join(",")')" != "$CONTACT_ID" ]; then
    THREAD_WHY="conversation $THREAD is not this user's own conversation (its contacts are not exactly the Intercom user of the account email); not sending."; return 0
  fi
  assignee="$(printf '%s' "$tconv" | "$JQ_BIN" -r '.admin_assignee_id // empty | tostring')"
  if [ -n "$assignee" ] && [ "$assignee" != "0" ] && [ "$assignee" != "$INTERCOM_ADMIN_ID" ]; then
    THREAD_WHY="conversation $THREAD is assigned to a human (admin $assignee), who is handling this user; not sending."; return 0
  fi
  if [ "${GOLIVE:-0}" = "1" ] && ! printf '%s' "$tconv" | "$JQ_BIN" -e '((.source.author.type // "") | IN("user", "lead", "contact"))' >/dev/null 2>&1; then
    THREAD_WHY="G2: conversation $THREAD was opened by us (an admin or bot), not the customer; not sending in it."; return 0
  fi
  btag="$(printf '%s' "$tconv" | "$JQ_BIN" -r --arg b "$BLOCKED_CONV_TAGS" '($b | split(" ")) as $bl | [(.tags.tags // [])[] | (.name // "") | ascii_downcase | select(IN($bl[]))] | .[0] // empty')"
  [ -z "$btag" ] || THREAD_WHY="conversation $THREAD carries the '$btag' tag (do not auto-message); not sending."
}
if [ -n "$THREAD" ] && [ "$ACTION" = "post" ]; then
  thread_check
  if [ -n "$THREAD_WHY" ]; then
    if [ "$R1_THREAD" = "1" ]; then
      printf 'HELD r1_filing_thread credits=%s (%s); nothing was sent or claimed\n' "$N" "${THREAD_WHY:0:300}"; exit 3
    elif [ "$THREAD_AUTO" = "1" ]; then
      THREAD=""; MESSAGE_TYPE="email"
    elif [ "$THREAD_UNREAD" = "1" ]; then
      printf 'THREAD CHECK NOT VERIFIED; nothing was sent or claimed: %s\n' "$THREAD_WHY" >&2; exit 4
    else
      record_refusal "$THREAD_WHY"
    fi
  fi
fi
if [ "$CAMPAIGN" = "retro-past" ]; then
  DOCS_WHY="$(docs_submitted "$CONTACT_ID")"
  if [ "$ACTION" = "doc-check" ]; then
    if [ -n "$DOCS_WHY" ]; then printf 'DOCS %s\n' "$DOCS_WHY"; else printf 'NO_DOCS\n'; fi
    exit 0
  fi
  if [ -n "$DOCS_WHY" ]; then
    ledger skip --campaign "$CAMPAIGN" --request-ids "$ALL_IDS" >/dev/null || die "the ledger write failed."
    printf 'SKIPPED docs_submitted credits=%s (%s)\n' "$N" "$DOCS_WHY"; exit 0
  fi
fi

# ---------------------------------------------------------------------------------------
# Claim in the ledger (idempotency + per-day cap), BEFORE the api-log and the POST.
{ [ "$ACTION" = "post" ] || [ "$ACTION" = "check-recipient" ]; } \
  || die "action '$ACTION' reached the send path; only a real send claims or posts. Nothing was claimed or sent."
if [ "$KIND" = "initial" ] && [ "$COPY" = "v1" ]; then
  # The no-deadline v1 copy only for a note the decider ledger proves is a paid provisional
  # approval's (QA review of hydra#1257 @53428d0): every credit a server-confirmed decider
  # approval, at least one of them provisional_paid. Checked HERE, so no caller can choose it.
  V1="$(ledger v1-eligible --request-ids "$ALL_IDS")" || die "the ledger read failed; refusing to send without proof the v1 copy applies."
  [ "$(printf '%s' "$V1" | "$JQ_BIN" -r '.eligible')" = "true" ] \
    || refuse "a verify-live note goes only to credits the decider approved and the server confirmed: $(printf '%s' "$V1" | "$JQ_BIN" -r '.reason')."
fi
if [ "$ACTION" = "check-recipient" ]; then
  printf 'RECIPIENT OK %s %s copy=%s credits=%s\n' "$CAMPAIGN" "$KIND" "$COPY" "$N"; exit 0
fi
[ "$ACTION" = "post" ] || die "internal: '$ACTION' past the recipient check."
if [ "$KIND" = "reminder-7" ]; then
  # The proof sweep may not have looked at the claim note lately: read its conversation now.
  # Any reply from the claimant is recorded and tagged claim-proof, and the reminder is withheld.
  set +e
  REPLY_CHECK="$("${BASH_SOURCE[0]}" tag-proof --message-id "$PARENT_ID" 2>&1)"
  rc=$?
  set -e
  case "$rc" in
    0) printf 'SKIPPED claimant-replied message=%s (tagged %s; with a person)\n' "$PARENT_ID" "$CLAIM_PROOF_TAG"; exit 0 ;;
    3) ;;
    *) printf 'REPLY CHECK FAILED for message %s (rc=%s); nothing was sent or claimed:\n%s\n' "$PARENT_ID" "$rc" "$REPLY_CHECK" >&2; exit 4 ;;
  esac
fi
if [ "$KIND" = "initial" ]; then
  REFS_FILE="$(mktemp)"
  trap 'rm -f "$REFS_FILE"' EXIT
  printf '%s' "$INPUT" | "$JQ_BIN" -c '[.credits[] | {request_id, profile_id, track_id}]' > "$REFS_FILE"
  CLAIM="$(ledger claim --campaign "$CAMPAIGN" --user-key "$EMAIL" --user-id "$USER_ID" --day "$DAY" --request-ids "$ALL_IDS" \
    --message-type "$MESSAGE_TYPE" --approved-by "$APPROVED_BY" --approval-ref "$APPROVAL_REF" \
    --contact-id "$CONTACT_ID" --refs-file "$REFS_FILE" ${WINDOWED_FLAG:+"$WINDOWED_FLAG"})" \
    || die "the ledger claim failed; refusing to send without the idempotency record."
else
  CLAIM="$(ledger claim-reminder --parent-message-id "$PARENT_ID" --kind "$KIND" --user-key "$EMAIL" --day "$DAY" \
    --request-ids "$ALL_IDS" --approved-by "$APPROVED_BY" --approval-ref "$APPROVAL_REF")" \
    || die "the ledger claim failed; refusing to send without the idempotency record."
fi
case "$(printf '%s' "$CLAIM" | "$JQ_BIN" -r 'if .result == "recent" and .reason == "recently_asked" then .reason else .result end')" in
  claimed) ;;
  already_notified)
    printf 'SKIPPED already-notified credits=%s\n' "$N"; exit 0 ;;
  user_done)
    printf 'SKIPPED %s credits=%s\n' "$(printf '%s' "$CLAIM" | "$JQ_BIN" -r '.reason')" "$(printf '%s' "$CLAIM" | "$JQ_BIN" -r '.request_ids | length')"; exit 0 ;;
  recent)
    printf 'DEFERRED messaged_7d credits=%s (a note from this gate in the last 7 days)\n' "$(printf '%s' "$CLAIM" | "$JQ_BIN" -r '.request_ids | length')"; exit 3 ;;
  refusal_hold)
    printf 'DEFERRED refused-recheck credits=%s (refused before; held for a re-check or a human)\n' "$(printf '%s' "$CLAIM" | "$JQ_BIN" -r '.request_ids | length')"; exit 3 ;;
  daily_cap)
    printf 'DEFERRED daily-cap credits=%s (this user already had a verify message on %s UTC; they go in the next one)\n' \
      "$(printf '%s' "$CLAIM" | "$JQ_BIN" -r '.request_ids | length')" "$DAY"; exit 3 ;;
  recently_asked)
    printf 'DEFERRED recently-asked credits=%s (this user got an ask in the last 90 days; the credits wait)\n' \
      "$(printf '%s' "$CLAIM" | "$JQ_BIN" -r '.request_ids | length')"; exit 3 ;;
  proof_received|done)
    printf 'SKIPPED %s message=%s\n' "$(printf '%s' "$CLAIM" | "$JQ_BIN" -r '.result')" "$PARENT_ID"; exit 0 ;;
  not_due|not_applicable)
    printf 'NOT DUE %s message=%s\n' "$KIND" "$PARENT_ID"; exit 3 ;;
  *) die "unexpected ledger answer: $CLAIM" ;;
esac
ROW_ID="$(printf '%s' "$CLAIM" | "$JQ_BIN" -r '.message_row')"
if [ "$CAMPAIGN" = "claim-proof-ask" ] && [ "$KIND" = "initial" ]; then
  DUE_DAY="$(printf '%s' "$CLAIM" | "$JQ_BIN" -r '.due_day // empty')"
  DUE_LABEL="$(due_label "$DUE_DAY")"
fi
# Render again from exactly the claimed credits.
CLAIMED_INPUT="$(keep_ids "$INPUT" "$(printf '%s' "$CLAIM" | "$JQ_BIN" -c '.request_ids')")"
RENDERED="$(render "$CLAIMED_INPUT")"
NC="$(printf '%s' "$CLAIMED_INPUT" | "$JQ_BIN" -r '.credits | length')"
leak="$(leak_reason "$RENDERED")"
if [ -n "$leak" ]; then
  ledger finalize --message-row "$ROW_ID" --status refused --reason "leak check: $leak" >/dev/null
  refuse "the rendered note contains $leak; not sent."
fi
PAYLOAD="$(payload "$RENDERED" "$CONTACT_ID")"
BODY_SHA="$(printf '%s' "$PAYLOAD" | "$JQ_BIN" -r '.body' | "$PY_BIN" -I -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"

# ---------------------------------------------------------------------------------------
# Log BEFORE the write, then POST, then verify.
LOG_FILE="$(new_log_file verify-request "$CONTACT_ID")"
"$JQ_BIN" -nc --arg target "user:$CONTACT_ID" --arg mt "$MESSAGE_TYPE" --arg appr "$APPROVED_BY" --arg thread "$THREAD" \
  --arg ref "$APPROVAL_REF" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sha "$BODY_SHA" \
  --arg campaign "$CAMPAIGN" --arg kind "$KIND" --arg parent "$PARENT_ID" --arg due "$DUE_DAY" \
  --arg copy "$COPY" --arg removal "$REMOVAL_DAY" --arg legacy "$LEGACY_MATCH" \
  --argjson ids "$(printf '%s' "$CLAIMED_INPUT" | "$JQ_BIN" -c '[.credits[].request_id]')" --arg row "$ROW_ID" \
  '{agent:"operations", action:"intercom_verify_request", campaign:$campaign, kind:$kind,
    parent_message:(if $parent == "" then null else $parent end), due_day:(if $due == "" then null else $due end),
    copy:$copy, removal_day:(if $removal == "" then null else $removal end),
    target:$target, conversation:(if $thread == "" then null else $thread end),
    message_type:$mt, request_ids:$ids, ledger_row:($row|tonumber), approved_by:$appr,
    approval_ref:$ref, body_sha256:$sha, timestamp:$ts,
    recipient_match:(if $legacy == "" then "id" else "in-thread-legacy-id " + $legacy end),
    authorization:"captain approved this verify-request campaign (fixed copy); see approval_ref"}' > "$LOG_FILE"

if [ -n "$THREAD" ]; then POST_PATH="/conversations/$THREAD/reply"; else POST_PATH="/messages"; fi
set +e
RESPONSE="$(printf '%s' "$PAYLOAD" | api POST "$POST_PATH")"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  ledger finalize --message-row "$ROW_ID" --status attempted --reason "curl rc=$rc; outcome unknown" --api-log "$LOG_FILE" >/dev/null || true
  printf 'POST FAILED (curl rc=%s); logged at %s and left CLAIMED (outcome unknown, so it is never re-sent automatically). Response:\n%s\n' \
    "$rc" "$LOG_FILE" "$RESPONSE" >&2
  exit 4
fi
R_TYPE="$(printf '%s' "$RESPONSE" | "$JQ_BIN" -r '.type // empty' 2>/dev/null || true)"
if [ -n "$THREAD" ]; then
  # Intercom answers a reply with the whole conversation; the part just created is the last one.
  R_CONV="$(printf '%s' "$RESPONSE" | "$JQ_BIN" -r '.id // empty | tostring' 2>/dev/null || true)"
  R_ID="$(printf '%s' "$RESPONSE" | "$JQ_BIN" -r '(.conversation_parts.conversation_parts // [])[-1].id // empty | tostring' 2>/dev/null || true)"
  R_PART="$(printf '%s' "$RESPONSE" | "$JQ_BIN" -r '(.conversation_parts.conversation_parts // [])[-1] | "\(.part_type // "")/\(.author.type // "")/\(.author.id // "")"' 2>/dev/null || true)"
else
  R_MT="$(printf '%s' "$RESPONSE" | "$JQ_BIN" -r '.message_type // empty' 2>/dev/null || true)"
  R_ID="$(printf '%s' "$RESPONSE" | "$JQ_BIN" -r '.id // empty | tostring' 2>/dev/null || true)"
  R_CONV="$(printf '%s' "$RESPONSE" | "$JQ_BIN" -r '.conversation_id // empty | tostring' 2>/dev/null || true)"
fi
if [ "$R_TYPE" = "error.list" ]; then
  ledger finalize --message-row "$ROW_ID" --status rejected --reason "intercom error: $(printf '%s' "$RESPONSE" | "$JQ_BIN" -r '[.errors[]?.code] | join(",")' 2>/dev/null)" --api-log "$LOG_FILE" >/dev/null
  printf 'POST REJECTED by Intercom (nothing delivered; retried on a later run). Logged at %s. Response:\n%s\n' "$LOG_FILE" "$RESPONSE" >&2
  exit 4
fi
if [ -n "$THREAD" ]; then
  if [ "$R_TYPE" != "conversation" ] || [ "$R_CONV" != "$THREAD" ] || [ "$R_PART" != "comment/admin/$INTERCOM_ADMIN_ID" ] \
     || ! printf '%s' "$R_ID" | grep -qE '^[0-9]+$'; then
    ledger finalize --message-row "$ROW_ID" --status attempted --reason "unverified reply type=${R_TYPE:-none} part=${R_PART:-none}" --api-log "$LOG_FILE" >/dev/null || true
    printf 'POST NOT VERIFIED: expected a Caroline comment in conversation %s, Intercom answered type "%s" last part "%s". Logged at %s; left CLAIMED. Response:\n%s\n' \
      "$THREAD" "${R_TYPE:-<none>}" "${R_PART:-<none>}" "$LOG_FILE" "$RESPONSE" >&2
    exit 4
  fi
elif [ "$R_TYPE" != "admin_message" ] || [ "$R_MT" != "$EXPECT_TYPE" ] || ! printf '%s' "$R_ID" | grep -qE '^[0-9]+$'; then
  ledger finalize --message-row "$ROW_ID" --status attempted --reason "unverified response type=${R_TYPE:-none} message_type=${R_MT:-none}" --api-log "$LOG_FILE" >/dev/null || true
  printf 'POST NOT VERIFIED: expected an admin_message of type "%s", Intercom answered type "%s" message_type "%s". Logged at %s; left CLAIMED. Response:\n%s\n' \
    "$EXPECT_TYPE" "${R_TYPE:-<none>}" "${R_MT:-<none>}" "$LOG_FILE" "$RESPONSE" >&2
  exit 4
fi
ledger finalize --message-row "$ROW_ID" --status sent --message-id "$R_ID" --conversation-id "$R_CONV" \
  --body-sha256 "$BODY_SHA" --api-log "$LOG_FILE" ${LEGACY_MATCH:+--reason "in-thread-legacy-id $LEGACY_MATCH"} >/dev/null
if [ -n "$THREAD" ]; then
  printf 'POSTED %s conversation=%s message=%s credits=%s\n' "$MESSAGE_TYPE" "$THREAD" "$R_ID" "$NC"
elif [ "$KIND" = "initial" ]; then
  printf 'POSTED %s message=%s credits=%s\n' "$MESSAGE_TYPE" "$R_ID" "$NC"
else
  printf 'POSTED %s %s message=%s credits=%s\n' "$KIND" "$MESSAGE_TYPE" "$R_ID" "$NC"
fi
