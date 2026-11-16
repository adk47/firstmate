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
#   decline: the ONE decline (captain 2026-10-29 13:2xZ, decline-copy-ruling.md). A request we closed is
#       told, in one sentence, that the supporting information we received was not enough to confirm it and
#       that submitting it again with documents starts a fresh review. NO reason, no document list, no
#       deadline, no fraud wording - the reviewer's code stays on the row and in the audit file, never in the
#       copy, and a fraud deny and an ordinary shortfall read identically to the user by design. One per
#       request id, ever; one message per user per UTC day; none within 7 days of another note. A NOTICE (it
#       asks for nothing). FILE: the usual credits entries (claim shape: one entry keyed claim-<claiming.id>
#       with profile_id). It exists for the window where core's own credits_rejected email is NOT routed to the
#       user (MESSAGING_EMAIL_ROUTES); when core's email goes out, core's is the single decline.
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
#   - the approval is the captain's Slack id (U7RP6HKUZ) OR - for a template class a Fable ruling
#     pre-approved in writing - that ruling's id (fable-ruling-YYYYMMDD-N, e.g. fable-ruling-1103-103).
#     A ruling id is accepted ONLY for the exact campaign+copy pairs policies/fable-rulings.json lists
#     under it; every other send, and every free-form reply, still needs the captain's id. The
#     approval_ref recorded with every send is pinned below, and every send is stamped in the ledger
#     with which kind of approval authorized it and the template identity hash it rendered;
#   - the recipient is resolved from the ACCOUNT email (the credit request's user), through an
#     exact Intercom contact search that must return exactly one user, never from anything a
#     user wrote; a follow-up goes to the contact its note went to;
#   - one message per user per UTC day across campaigns, each credit request id gets a
#     campaign's note at most once, each reminder at most once per note, and each credit at
#     most one decline. All enforced in
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
#   intercom-verify-request.sh send --credits-file FILE --approved-by <SlackUID|fable-ruling-YYYYMMDD-N> \
#       [--campaign verify-live|retro-past|removal-notice|takeback-notice|uvn-status|withdrawal-confirm|status-doc-received|status-team-review|email-changed|email-changed-dup|claim-proof-ask|claim-status|gap-ask|decline|merge-pending|merge-claim-first|credit-hold-status|claim-proof-pending|proof-need-ask|credit-approved-elsewhere|proof-refusal] [--kind initial|reminder-14|reminder-25 \
#        --parent-message-id <id>] [--copy v1|windowed (verify-live preview only) | queued|received (status-doc-received) | no-ask|count (status-team-review)] \
#       [--conversation <id> (uvn-status, withdrawal-confirm, status notes, claim-status, email-changed, gap-ask, merge-pending,
#        credit-hold-status, claim-proof-pending, proof-need-ask)] [--inapp-fallback] [--channel inapp (uvn-status, status notes,
#        claim-status, gap-ask: never email; see In-app delivery)] [--dry-run|--validate|--doc-check|--check-recipient]
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
# merge-claim-first (pr-review-fable-r5 copy fable-copy-1030-r5/e1, 2026-10-31 05:2xZ/05:4xZ; program-lead-fable-p2
# 062 (ii); firstmate 063): the claim-first ask to a requester whose credits sit on an UNCLAIMED second profile that
# carries the DSP id. FILE: ONE credits entry with request_id "mcf-<user.id>" (one ask per user, ever) and
# "merge": {"link_profile_id": "<uuid>"} (the link is built here from the uuid; no URL is ever taken from the file).
# Only the accounts in MERGE_CLAIM_FIRST_USERS (r5's signed set). In-thread only into an on-topic (R9) thread of the
# user, else email with r5's subject. A WAIT line in comm_state (r5/QA); a volume-only R8 hold does not stop it.
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
# proof-need-ask (proof-loop captain card L11c; UNLOCKED on Fable [key=l11c-asks] - readable + counterparty only):
# the per-need ask for ONE credit request whose document the reader could not check on its own. FILE carries
# one credits entry (request_id, role, track_title, artist_name) and "need": {"code": readable_document |
# issuer_email_from_official_domain | distributor_dashboard_with_code | counterparty_signed_or_registered,
# "issuer": the issuer's name (issuer_email only; plain letters/digits/&.,'- only, at most 80 characters),
# "verify_code": the 7-day code we issued (distributor_dashboard only)} from b1's need tray. One ask per
# request, ever; like gap-ask it may follow a status-doc-received note inside 7 days (that note promised this
# message) and never crosses a gap ask on the same request.
# credit-approved-elsewhere (firstmate brief humanless-need-asks-r1; SEND-LOCKED, the line is NOT approved):
# the line for a credit request the conflict rule decided `credit_approved_for_another_user` - the same credit on the
# same track is already verified for another person. FILE carries user.id and one credits entry per decided request
# (request_id, role, track_title, artist_name), where role is the roles the two requests SHARE, never the whole role
# list of the request: a credit with no role is refused, so the line never names a role nobody read. It says the
# credit is verified for another person and what to send if they share it; it names nobody and denies nothing. One
# message per request, ever; never within 7 days of another note from this gate. This gate does not decide who is
# in that state and re-reads nothing about it: the caller's list is the conflict rule's decision.
# Its bytes need the reviewer's APPROVAL in every mode (policies/outbound-copy-enforce.json lists it as enforced).
# proof-refusal (captain 2026-11-15, Fable GO corr=208a8463f735ff45 13:41Z): the ONE note that names why a document
# did not verify a credit. FILE carries user.id and one credits entry per rejected request (request_id, role,
# track_title, artist_name, reason, need), where reason is the proof reviewer's recorded reason and need is the need
# code the reviewer recorded for that request (proof_review_decisions.ask_need). Only three pairs have a body:
# doesnt_name_you or other_track with counterparty_signed_or_registered, and unreadable with readable_document; any
# other pair refuses the whole note (refusal_uncoded), because "what would change this" is never filled from a code
# the reader did not record. Each entry also carries review_family, the family of the verify_proof_reviews row it
# answers; the ledger row keeps (review_family, request_id, reason, need) per request. One sentence set per track, each with that track's own reason, then the closing once.
# No greeting, no sign-off, no added sentence. One message per request, ever; never within 7 days of another note
# from this gate. Its bytes need the reviewer's APPROVAL in every mode (policies/outbound-copy-enforce.json).
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
# --inapp-fallback (fable-copy-1030-r5/h): when the selected route is email and Intercom will not email the
# contact (hard-bounced / unsubscribed / spam), send the same approved body as an Intercom in-app message to a
# user contact the messenger has seen. Off by default: armed by the runner only after the signed first-batch
# dry run (p1 + r5). Without it, or with no in-app route, the note is refused and recorded as no_channel.
#
# --check-recipient (initial notes) runs every check a real send runs up to the claim: input,
# render + leak check, the Intercom recipient (exactly one user with the account email, its
# external_id the account's), the v1 eligibility read, the delivery channel; prints
# RECIPIENT OK <copy> credits=N route=<comment:ID|email|inapp> or refuses. Read only: no ledger write, nothing sent. A dry run that skips this cannot see a
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
#                                will be removed). Its follow-ups (day-14/25 reminders) follow only a
#                                windowed note, so none can be sent either. Kept for --dry-run
#                                previews only; the no-removal-language test fails if any sendable
#                                message carries removal or deadline wording.
#   DECLINE_COPY_APPROVED        the `decline` campaign: the ONE reason-free decline (captain
#                                2026-10-29 13:2xZ, ruling decline-copy-ruling.md). APPROVED in the
#                                same PR that adds the campaign, per items 1 and 3 of the ruling.
readonly DECLINE_COPY_APPROVED=1
# Activation lock (decline-copy-ruling.md 2.2/3.2): core already sends its own `credits_rejected` email on a
# rejection, and after the muso messaging template change that email carries the SAME approved text — so the two
# must never both speak. hydra's campaign is the fallback for the window where core's route is off, and only an
# operator who has MEASURED that (credit_review/decline_close.py reports routed/off/unknown per user) flips this
# to 1. 0 = silent: every real decline send refuses, and --dry-run still renders exactly what would be sent.
DECLINE_CORE_ROUTE_OFF="${INTERCOM_VERIFY_TEST_DECLINE_CORE_ROUTE_OFF:-0}"
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
# Fable [key=lamberto-reply-due] FINAL (firstmate 240; r5 co-sign): a reply_due answer in a thread that carries our
# earlier "Nothing is needed from you right now" line starts with ONE correction sentence, and only above the ASK
# (uvn-status): never above a status-team-review / receipt line, which the earlier note does not contradict.
# Copy APPROVED: fable-copy-1030-r5/c (data/pr-review-fable-r5/copy-approvals-1030.md, under the captain's 2026-10-30
# 13:1xZ delegation "use fable, do not wait for me"; firstmate 286), byte-for-byte.
readonly REPLY_DUE_CORRECTION_TEXT="A correction to our earlier note here: this request does need one thing from you."
# l1 RULING 2026-11-02 (verify-program-lead-fable-l1/ruling-o-retire-1102.md): the /o clause RETIRES. Its
# only value is the promise "we will match it to your request", and that promise is unkeepable while Gmail is dark - the
# premise of the bounded experiment (Gmail back inside the window) is falsified, so renewing would re-open a promise we
# cannot honour. RETIRED, NOT DELETED: the flag, the ref and the text stay greppable so the clause can be audited, and the
# flag is the gate - it refuses whatever the clock says. [key=dated-windows-are-data]: the window and the hold's due date
# now live in the policy file (holds.gmail), which this gate re-reads every run, so a window closes (and an approved one
# reopens) by a reviewed policy value without waiting on a deploy. Reopening ALSO needs this flag back at 1: a retired
# customer promise is a new approval decision, never a config flip alone.
# Fable FINAL [key=gmail-held-fallback] (4), r5 /o, text confirmed by p1 + Fable 10-31 12:1xZ: the ONE clause the held
# stale_source:cs-gmail set may get (last sentence before the sign-off, once per user). [key=gmail-o-forward] (Fable 495,
# p1 497, 10-31 21:0xZ): UNLOCKED for the signed /o batches only, inside a dated window, and only while cs-gmail is still
# stale (the gate re-reads the frozen did-vouch set itself: a user outside it, or a fresh Gmail scan, refuses - the stop
# rule). Rendered only under --gmail-fallback-o on an initial uvn-status ask; a reply to it waits on gmail (comm_state).
readonly GMAIL_FALLBACK_O_APPROVED=0
readonly GMAIL_FALLBACK_O_REF="fable-copy-1030-r5/o"
readonly GMAIL_FALLBACK_O_TEXT="If you have already emailed it to support@muso.ai, just reply here to say so and we will match it to your request."
readonly REPLY_DUE_CORRECTION_APPROVED=1
readonly REPLY_DUE_CORRECTION_REF="fable-copy-1030-r5/c"
# [key=product-dispute-refs] reply-ref: r5's APPROVED REPLY SET fable-copy-1031-r5/q-y, posted ONLY as a reply_due answer
# (one per customer part, one per thread per 48 h, every reply_due rule) to a part the class picker hands off - never
# over a coded answer class (comm_state). /z needs a literal "in Jan's review list" read that is not wired: refused.
# SEND-LOCKED until r5 + p1 read c1's classifier dry run (Sun 02Z) - checks and dry runs only until this flips by PR.
readonly REPLY_REF_APPROVED=0
readonly PICK_MAX_AGE_S=86400   # QA #1601 (2): a reply-ref post follows its classifier pick within a day, else re-picked
readonly REPLY_REF_SERIES="fable-copy-1031-r5"
# A thread assigned to a HUMAN admin: the answer is handed to them first (tag + internal note), and only if no human
# writes within 48 h of that note is the thread reassigned to this gate's admin (+ note) and the answer posted.
readonly HANDOFF_TAG="credit-answer-ready"
readonly REASSIGN_NOTE="handed to the automated verification loop"
RD_PREFIX=0 RD_ACT="" RD_ASG="" RD_PRIOR=""
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
#       UNLOCKED 2026-10-29 by Fable ruling [key=claim-code-ask-release] under the captain's 21:3xZ "proof conversations
#       YES" (captain-1028-213x), 21:4xZ "yes approve all if Fable confirms" and 03:2xZ "move credits and profiles
#       along" / "use fable and i take the recommendation of it just go": a returned code CAN be accepted (core
#       #10762/#10763, the E1 verifier). Text = D38 as approved, paragraph 3 as on p1's captain card (L3, the
#       paperwork paragraph, unchanged). Initial asks pass the go-live guards and comm_state (never to a claimant who
#       replied, sent proof or was decided; one per claim ever; 7-day gate). Release: the train AFTER the E1 deploy is
#       read end to end on a planted code; audience = bound-page person claimants only.
#   Reviewed baseline: deploy overwrites - 2026-10-29 (verify-ask-wiring-h2): this blob sets CLAIM_PROOF_ASK_COPY_APPROVED=1.
readonly CLAIM_PROOF_ASK_COPY_APPROVED=1
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
#   MERGE_CLAIM_FIRST_COPY_APPROVED  merge-claim-first: pr-review-fable-r5 approved copy fable-copy-1030-r5/e1 and the four
#       recipients on 2026-10-31 05:2xZ (amended 05:4xZ for u1406401); program-lead-fable-p2 062 ordered the coded path.
readonly MERGE_CLAIM_FIRST_COPY_APPROVED=1
# r5's signed set (data/profile-merge-ops-m1/claim-first-ask-e1-send-1031.json). Adding an account is a PR.
readonly MERGE_CLAIM_FIRST_USERS="1380289 122029 104450 1406401"
#   r5 fable-copy-1103-r5/mcf-proof-ack (2026-11-03 13:5xZ): e1 with ONE sentence prepended to paragraph 1, rendered
#   ONLY for a recipient who has a document on file for these credits. The fact is read fresh for each recipient in the
#   same pass that renders the body (comm_state.py proof-on-file: our stores + the named request's own creation time),
#   and a fact that is absent or unreadable REFUSES the note (mcf_proof_unreadable) - a rendered blank, or a body that
#   silently drops the sentence, would read as if we never opened what they sent. It says the documents ARE on file:
#   never that we checked them, never an outcome, never a date, never a human.
readonly MERGE_CLAIM_FIRST_PROOF_ACK="We have the documents you sent for these credits on file."
#   CREDIT_HOLD_STATUS_COPY_APPROVED  credit-hold-status (Fable copy-owing-proof-1027 S1, verbatim): LOCKED
#       until the captain's yes on L14a (ws2-captain-lifts-1027) lands in a PR that flips it.
#   CLAIM_PROOF_PENDING_COPY_APPROVED claim-proof-pending (S2, verbatim): LOCKED until the captain's yes on L14b.
readonly CREDIT_HOLD_STATUS_COPY_APPROVED=0
readonly CLAIM_PROOF_PENDING_COPY_APPROVED=0
#   APPROVED_ELSEWHERE_COPY_APPROVED  credit-approved-elsewhere: LOCKED. Nobody has approved this line. It opens only
#       in a PR that records the reviewer's signed approval of the rendered bodies and the captain's yes; until then
#       --dry-run renders it and every real send is refused before the ledger is read.
readonly APPROVED_ELSEWHERE_COPY_APPROVED=0
#   PROOF_REFUSAL_COPY_APPROVED  proof-refusal: the three reason-bearing bodies. OPEN on Fable's GO of the three
#       rendered bodies (corr=208a8463f735ff45, 2026-11-15T13:41Z) with its two conditions, both held in code: the
#       upload instruction is "Reply to this conversation" (refusal_copy_guard refuses a mailbox), and the evidence
#       line is proof_reviewer.ASK_LINES per need code (pinned equal by scripts/tests/test_proof_refusal.py).
readonly PROOF_REFUSAL_COPY_APPROVED=1
# The most words one proof-refusal body may carry (firstmate 2026-11-15: a longer body stops and is reported).
readonly REFUSAL_MAX_WORDS=1500
# The send-time lint of a proof-refusal, asserted on the note's own words with every title, role and artist replaced
# (refusal_copy_guard): no promise in the future tense, no person or queue, no wait wording, no mailbox.
readonly REFUSAL_FORBIDDEN='\b(I|we) +(will|shall|are going to)\b|\b(team|staff|agent|specialist|representative|colleague|someone|human|manager|supervisor)\b|\ba person\b|\bescalat|\bforward|\bhand(ed|ing)? +(off|over)\b|\bpass(ed|ing)? +(this|it|you) +(on|along|to)\b|\bticket\b|\bqueue\b|\breview|\binvestigat|\blook(ing)? +into\b|\bget back to\b|\breach out\b|\bbe in touch\b|\bfollow up\b|\blet you know\b|\bsoon\b|\bshortly\b|\basap\b|\bbusiness days?\b|\bbear with\b|\bbe patient\b|\bplease wait\b|\bunfortunately\b|\bsorry\b|\bapolog|@'
#   PROOF_NEED_ASK_COPY_APPROVED  proof-need-ask (proof-loop captain card L11c, the four per-need lines + common
#       opening + closing, verbatim): LOCKED until the captain's yes lands in a PR that flips it.
#       UNLOCKED 2026-10-29 by Fable ruling [key=l11c-asks] (captain 14:3xZ status-wording delegation + 03:2xZ "use fable
#       and i take the recommendation of it just go"; firstmate shows the captain the text with a veto): readable_document
#       and counterparty_signed_or_registered only. issuer_email waits for verify@ (VERIFY_AT_ENABLED), the distributor
#       code line is captain-approved (DISTRIBUTOR_COPY_APPROVED); issuer_email is HELD at send.
#   Reviewed baseline: deploy overwrites - 2026-10-29 (verify-ask-wiring-h2): this blob sets PROOF_NEED_ASK_COPY_APPROVED=1.
readonly PROOF_NEED_ASK_COPY_APPROVED=1
#   SPLIT_ACCOUNT_COPY_*  the multi-account proof-review note (the refusal fired when one ask's documents cover two
#       accounts): the captain asked firstmate for "We received documents from two different Muso accounts..." and the
#       outbound copy gate rewrote it - the reviewer refused the original wording under rubric rules 1 and 2 (naming
#       two accounts and "so we can match it" hints at a check and at suspicious activity) and APPROVED its own
#       replacement, which is the text below, on 2026-11-14T10:31:53Z: verdict ocv-49139bdc4dfc3e75, reviewer
#       mac-pool/claude-fable-5-1, rubric default 2c505d21f105afe8922204c32c27d1cfc345d09e99ee605b8d3dfa2d022a7cfa.
#       The verdict binds these exact bytes (body_sha256 SPLIT_ACCOUNT_COPY_SHA256, subject sha
#       6601ac4d5167dceb8573189b1de96c6643414094e03720ed56c7c726037c74be); edit one byte and the approval is void,
#       which scripts/tests/test_split_account_copy.py enforces.
#   SPLIT_ACCOUNT_COPY_APPROVED  LOCKED at 0: the COPY is approved, but the sender campaign that renders it does not
#       exist yet (a follow-up lane adds the campaign, its recipient rules and its dry run). The multi-account refusal
#       in scripts/ops_intake/proof_review.py therefore records the split reason and sends nothing; it never claims a
#       send it did not make.
# shellcheck disable=SC2034  # approved copy registered ahead of its sender campaign (follow-up lane)
readonly SPLIT_ACCOUNT_COPY_APPROVED=0
# shellcheck disable=SC2034  # approved copy registered ahead of its sender campaign (follow-up lane)
readonly SPLIT_ACCOUNT_COPY_VERDICT="ocv-49139bdc4dfc3e75"
# shellcheck disable=SC2034  # approved copy registered ahead of its sender campaign (follow-up lane)
readonly SPLIT_ACCOUNT_COPY_SHA256="1da7a62bded59a31aafe4ff475917d769986c7780f19285baf63dc8b52e30b9c"
# shellcheck disable=SC2034  # approved copy registered ahead of its sender campaign (follow-up lane)
readonly SPLIT_ACCOUNT_COPY_SUBJECT='About the documents you sent for your Muso credits'
# shellcheck disable=SC2034  # approved copy registered ahead of its sender campaign (follow-up lane)
readonly SPLIT_ACCOUNT_COPY_BODY='Thanks for sending your documents. To continue, we need your proof sent from the Muso account that made this credit request. Please reply to this message from that account and attach your proof.

Your request is waiting on this. Once we have it, our team will review it and let you know what happens next.'
# shellcheck disable=SC2034  # approved copy registered ahead of its sender campaign (follow-up lane)
readonly SPLIT_ACCOUNT_COPY_SUBJECT_SHA256="6601ac4d5167dceb8573189b1de96c6643414094e03720ed56c7c726037c74be"
#   VERIFY_AT_ENABLED  verify@muso.ai intake (the issuer_email_from_official_domain need line asks the issuer to write
#       to it). OFF until Intercom identity verification (i2) is live (Fable exec-plan captain-1028-213x (c); p1
#       ruling 096): that need is HELD at send (exit 3, nothing claimed); the dry run still renders it.
readonly VERIFY_AT_ENABLED=0
#   DISTRIBUTOR_COPY_APPROVED  the distributor_dashboard_with_code need line (the universal Ctrl+F / Cmd+F form; the 7-day
#       F9 challenge code from credit-doc-verify.py challenge issue, #1476). CAPTAIN-APPROVED: captain 2026-10-29 19:0xZ
#       ("approved if Fable says go"), Fable GO 19:2xZ, proof-loop-lead-fable-p1 208. Empty = HELD at send (exit 3).
readonly DISTRIBUTOR_COPY_APPROVED="captain 2026-10-29 19:0xZ; fable-copy-1030-r5/a (byte-for-byte)"

# PINNED. Caroline (skills-all/muso-intercom/SKILL.md, Reply Identity), same literal and
# same variable name as intercom-ops-write.sh so check-intercom-reply-identity.sh keys on it.
readonly INTERCOM_ADMIN_ID="5763097"
readonly API_BASE="https://api.intercom.io"
readonly API_VERSION="2.11"
# A tick makes 100+ Intercom calls per family, so ONE transient network blip used to stop the whole tick: three of the
# five tick kills between 11-02 and 11-06 were transport failures (a 45s timeout, a connection reset), not logic
# failures. A bounded retry is allowed ONLY where a retry cannot duplicate a side effect:
#   - the call is a READ (GET, or Intercom's POST /conversations/search and /contacts/search, which only read), and
#   - the failure is TRANSPORT-level (the request never reached a decision), never a 4xx/5xx body.
# A write is NEVER retried: the POST may already have been applied, and a duplicate customer note is worse than a
# stopped tick. The caller's existing rc handling is unchanged - a retried read that still fails returns its rc.
# The values are assigned per branch below (a deployed copy pins them; a test copy may shorten the sleeps).
readonly PROD_LOG_DIR="/opt/hydra/workspaces/operations/api-logs"
readonly PROD_LEDGER="/var/lib/hydra/credit-review/ledger.sqlite3"
readonly PROD_LEDGER_HELPER="/opt/hydra/scripts/credit_review/verify_ledger.py"
# THE OUTBOUND COPY GATE (captain 2026-11-12: "check your messages with Fable. Make sure Fable likes the messages that
# you're sending out"). Every body this script POSTs to a customer needs the reviewer's SIGNED verdict on its exact
# bytes; this host can verify one and cannot mint one (docs/credit-verification/outbound-copy-gate.md). Neither path
# is a parameter on a deployed copy: a caller-selectable gate or store is a caller-selectable approval.
readonly PROD_COPY_GATE="/opt/hydra/scripts/outbound_copy/gate.py"
readonly PROD_COPY_STORE="/var/lib/hydra/outbound-copy"
# gap-ask reads the stage-2 verdicts (read-only) from the proof store through this helper.
readonly PROD_STAGE2_HELPER="/opt/hydra/scripts/credit_review/stage2_verdicts.py"
# Who tells a closed request (core's own credits_rejected email or hydra's decline) - the per-user read the
# decline campaign makes before every real send (QA #1718 3).
readonly PROD_DECLINE_CLOSE_HELPER="/opt/hydra/scripts/credit_review/decline_close.py"
# Every real send first asks core whether IT told this user something lately (core_notice.py; Fable sender map
# 2026-10-27 item 2): a core notice within 7 days or a status change today defers the note.
readonly PROD_CORE_NOTICE_HELPER="/opt/hydra/scripts/credit_review/core_notice.py"
# The send-time communication-state check for the go-live cohorts (captain 2026-10-28 18:2xZ): comm_state.py.
readonly PROD_COMM_STATE_HELPER="/opt/hydra/scripts/credit_review/comm_state.py"
# The per-PERSON replica read (gate_facts.py + replica-serve.sh, 2026-11-12; docs/credit-verification/
# gate-replica-read.md): what the two helpers above ask the replica about this user, asked in ONE round trip. The
# helpers then run UNCHANGED with replica-serve.sh as their replica command: it answers a statement whose exact text
# the read holds and runs the real trino-query.sh for any other - and for all of them when the read failed, is
# stale or is absent. It changes no answer; a read that never answers costs replica_batch.BATCH_TIMEOUT_S (8 s) of
# this call before the live reads start, which is why that bound is small. Measured on node-8: 5-6 round trips of
# ~2 s per person were 10.25 s of a 13.47 s gate call, and the calls that crossed the 20 s read timeout tripped the
# unmeasured bar.
readonly PROD_GATE_FACTS_HELPER="/opt/hydra/scripts/credit_review/gate_facts.py"
readonly PROD_REPLICA_SERVE="/opt/hydra/scripts/replica-serve.sh"
# tmpfs, root-only: the read is never on disk and never outlives a reboot
readonly PROD_GATE_FACTS_DIR="/run/hydra/gate-facts"
readonly PROD_PROOF_DB="/var/lib/hydra-credit-verify/proof.sqlite"
# [key=dated-windows-are-data]: the policy file holds the dated windows (holds.gmail: the /o clause and the Gmail hold).
readonly PROD_POLICY="/opt/hydra/policies/credit-verify-outbound.json"
# The Fable ruling ids that may stand in for the captain's Slack id, and the exact template classes each one
# pre-approved. Fail closed: an id this file does not list, for a class it does not list, still needs the captain.
readonly PROD_FABLE_RULINGS="/opt/hydra/policies/fable-rulings.json"
# QA 2026-11-04 finding 1: a refund note is a financial statement, so its facts are READ FROM THE PROCESSOR at send
# time, never taken from the caller's file. The credential comes from the gateway env file (the same file the runtime
# already trusts for MUSOAI_INTERCOM_TOKEN); a refund-confirm that cannot reach Stripe is refused, not rendered.
# QA 2026-11-04 round 3 finding 2: the credential FILE is a seam in a test copy only. A deployed copy reads the
# gateway env file and nothing else; a test copy may point it at an empty fixture so "there is no key" is a fact the
# test controls, not a property of whichever host happens to run it (/etc/openclaw/main.env exists on node-8).
readonly STRIPE_ENV_FILE_PROD="/etc/openclaw/main.env"
readonly STRIPE_KEY_VAR="MUSOAI_STRIPE_API_KEY"
readonly STRIPE_API_BASE_PROD="https://api.stripe.com"
# l1 [key=l11c-email-filed]: the identities that prove an email-filed document is the account's (= receipts.STRONG_MATCH)
readonly EMAIL_FILED_STRONG_MATCH="professional_id authenticated_email session"
readonly PROOF_TAG="credit-proof"
readonly CLAIM_PROOF_TAG="claim-proof"
# The ONLY approver of these campaigns, and where he approved each.
readonly CAPTAIN_UID="U7RP6HKUZ"
readonly MAX_DOC_GROUP=20             # QA #1418: the most documents one per-need ask may name (need_asks.MAX_DOC_GROUP)
readonly APPROVAL_REF_LIVE="captain U7RP6HKUZ 2026-10-15 22:12Z: \"i want AI live now - we have too many credits to approve and to get supporting data for - let users know where there was a credit given and that it needs support (trust yet verify approach)\""
readonly APPROVAL_REF_LIVE_WINDOWED="$APPROVAL_REF_LIVE; 2026-10-15 23:40Z: \"if no valid verification comes it should be removed\" (kept for new provisional approvals at 2026-10-16 00:35Z); copy = Fable copy-review-fable-2026-10-17 pack 1 (GO with edits); enable = Fable decision-verify-notify-enable-2026-10-17 (firstmate 051, 2026-10-17 23:15Z: enable Monday 2026-10-20 under its 7 conditions)"
readonly APPROVAL_REF_LIVE_V1="$APPROVAL_REF_LIVE; paid provisional approvals: Fable credit-backlog-1019 ruling 4 as amended by firstmate 073 (2026-10-19 14:58Z: provisional approve + doc request, NO day-30 auto-removal, no removal language; captain rule 10-15: deletes must confirm removal at Spotify/Tidal or prove a different profile)"
readonly APPROVAL_REF_TAKEBACK="captain via firstmate 012, 2026-10-16: every take-back sends the user a short, polite message saying which credit and role, why (who the public credits name, with the link), and how to dispute it by replying with a document."
readonly APPROVAL_REF_STANDING_ORDER="captain U7RP6HKUZ standing order 2026-10-19 17:24Z: \"are you properly communicating to everybody that's making credit request and also are you figuring out how to do profile merges that are being requested by Caroline as well make sure that you have all of the operation functions that Jan performs under your watch. I still want the guard up, but I want you to do everything based off of the research that you do and also your communications with the actual users.\""
readonly APPROVAL_REF_UVN="$APPROVAL_REF_STANDING_ORDER; copy approved by firstmate under it 2026-10-19 21:07Z (inbox 060, confirmed in 064): copy-uvn-status-reminder-1019 section A with the closing-line edit"
# fable-copy-1030-r5/c2 (byte-for-byte; [key=k-proof-required]): the first sentence of a uvn-status ask that follows a
# status line we sent this user about any of the same requests (/k, the team-review / doc-received lines). No overlap =
# the plain ask. The corrected ask goes by EMAIL (its own message, never into an auto-picked thread: preview == send).
readonly CORRECTION_C2_ONE="A correction to our earlier note: this request does need one thing from you."
readonly CORRECTION_C2_MANY="A correction to our earlier note: these requests do need one thing from you."
readonly CORRECTION_C2_REF="fable-copy-1030-r5/c2"
# fable-copy-1101-r5/n1 (byte-for-byte; uvn-new-rows): the first sentence of the follow-up ask to a TOLD user about owed
# rows no ask named - singular / plural by DISTINCT TRACKS among the new rows (the body's own count decides, /l).
# The class was send-locked until p1 + r5 read and signed its first dry run on the deployed head. That sign-off is
# replaced by the outbound copy gate's signed verdict (firstmate 2026-11-14 22:48Z, ask-never-asked-r1): the first dry
# run on deployed head 96c5a2fb8 rendered six bodies and the reviewer round of 2026-11-14 22:40:50Z approved all six
# (ocv-7e38f2c0b2724b96, ocv-762f8aeafb4fb30a, ocv-9cae0062eb0af9e1, ocv-fb3df8e1dad86c67, ocv-4dd67f16bbbe9db0,
# ocv-bd26ab432dcbc4b6). The lock below is open on that basis and NO body has a standing approval: the campaign is
# `enforce` in policies/outbound-copy-enforce.json and this script holds any answer but a signed `approved` for the
# exact bytes (SIGNED_APPROVE_ONLY below), so every sent row carries its own verdict.
readonly NEW_ROWS_N1_ONE="Since we last wrote about your credit requests, another request of yours needs the same thing."
readonly NEW_ROWS_N1_MANY="Since we last wrote about your credit requests, other requests of yours need the same thing."
readonly NEW_ROWS_N1_REF="fable-copy-1101-r5/n1"
# uvn-reminder-14 (captain 2026-11-13 15:08Z, "fix it scale it now" / "see it through": yes on re-asking verification
# non-responders after 14 days). This copy has NO standing approval: the campaign is `enforce` in
# policies/outbound-copy-enforce.json, and this script additionally refuses any answer but a signed `approved`
# for the exact bytes (an `observed` pass is a hold for this campaign), so every sent row carries its own verdict
# (copy_verdict_id + copy_verdict_sha256 + body_sha256).
readonly APPROVAL_REF_UVN_REMINDER="captain 2026-11-13 15:08Z order (re-ask verification non-responders after 14 days; one reminder per user per ask); copy uvn-reminder-14 v1, sent only on a signed outbound-copy verdict for these exact bytes (see copy_verdict_id on this row)"
readonly UVN_NEW_ROWS_COPY_APPROVED=1
readonly APPROVAL_REF_WITHDRAWAL="$APPROVAL_REF_STANDING_ORDER; withdrawal-confirm copy approved by firstmate under it 2026-10-19 21:21Z (inbox 061, confirmed in 064), sent only for a request the requester withdrew (metadata.withdrawal.by = requester)"
readonly APPROVAL_REF_STATUS="$APPROVAL_REF_STANDING_ORDER; status notes approved by firstmate under it 2026-10-20 (inbox 070: team-review verbatim; 071: doc-received as credit-trust-llm-t01 drafted it). Not asks."
readonly APPROVAL_REF_STATUS_NEUTRAL="$APPROVAL_REF_STATUS Status A neutral (--copy queued-neutral) for an unread, unanswered filing: fable-copy-1030-r5/i (captain 21:3xZ wording)."
readonly APPROVAL_REF_STATUS_RECEIVED="$APPROVAL_REF_STATUS The receipt line R1 (--copy received: the queued line without 'no need to send anything else'), proof-loop-lead-fable-p1 captain card 2026-10-27 22:5xZ, sent only on the captain's yes."
readonly APPROVAL_REF_STATUS_COUNT="$APPROVAL_REF_STANDING_ORDER; count-only status-team-review wording (--copy count) approved by firstmate 2026-10-26 16:58Z (verify-ask-wiring-h2 inbox 005, Fable decides under the captain's 12:40Z order; captain 16:05Z: \"everyone should be communicated or credits and profiles awarded\"), for a user whose requests cannot be listed (unshowable fields or more than 1,000). Not an ask."
readonly APPROVAL_REF_STATUS_NOASK="$APPROVAL_REF_STATUS The no-ask team-review wording B0 (--copy no-ask: Copy B without its optional proof sentence) approved by firstmate 2026-10-21 (credit-trust-llm-t01 key pending-status-1021, relayed in inbox 106)."
readonly APPROVAL_REF_EMAIL_CHANGE="$APPROVAL_REF_STANDING_ORDER; email-changed templates approved by firstmate under it 2026-10-20 00:55Z (inbox 073): a threaded reply into the requester's own conversation, once per ticket, no customer-typed content."
readonly APPROVAL_REF_CLAIM_STATUS="Fable claims-documentation-readiness-1023 ruling 3 (2026-10-23 19:15Z): claim status note APPROVED as drafted, scope narrowed to pending claimants who get no proof ask within 7 days; captain 2026-10-26 16:05Z: everyone with a pending claim is approved or told its status; firstmate claim-lane-resume-c2 005: option A. Body replaced 2026-10-30 under fable-copy-1030-r5/g (p1 STOP: the captain-barred 'Nothing else is needed from you right now' removed; 10-29 03:2xZ, #1432)."
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
readonly APPROVAL_REF_WAIT_APOLOGY="Fable d2 (verify-sla-driver-fable-d2) 2026-11-05 04:1xZ on the captain's 01:4xZ order (\"anyone that hasn't been communicated needs to be - apologize for any excessive waits\"): the wait-apology copy v2 in data/verify-sla-driver-fable-d2/approved-copy/wait-apology-status-v2.md, sha256 78f2b8751c1e1f7c4e6369cf4f1f321b4ba0350db404a245fd18769f3f5cf30e (v1 83b82addc0e041bc; the only change is F4), rendered VERBATIM; one message per user, ever, ledgered as campaign wait-apology so the 7-day status gates see it."
readonly APPROVAL_REF_MERGE_CLAIM_FIRST="pr-review-fable-r5 fable-copy-1030-r5/e1 (2026-10-31 05:2xZ, amended 05:4xZ); r5 fable-copy-1103-r5/mcf-proof-ack (2026-11-03 13:5xZ: the documents-on-file sentence, rendered only off a read fact); program-lead-fable-p2 062 (ii); firstmate 063; captain 13:1xZ delegation (Fable decides)"
readonly APPROVAL_REF_MERGE_PENDING="captain 2026-10-28 12:4xZ: \"go live today and start conversations with users who requested credits, profiles (claims) or merges ASAP\"; copy = program-lead-fable-p2 go-live-today line M1, sent only on the captain's own yes to M1"
readonly APPROVAL_REF_OWING_PROOF="captain U7RP6HKUZ 2026-10-27 20:1xZ: \"are you sure all users that need to be communicated have been already? If not get on it - make this a durable process that does not rely on my computer; do this all on OVH.\"; copy = Fable verify-program-lead-fable-l1 copy-owing-proof-1027 (20:2xZ), sent only on the captain's yes (L14a S1 credit-hold-status / L14b S2 claim-proof-pending)"
readonly APPROVAL_REF_PROOF_NEED_ASK="captain 2026-10-27 21:5xZ: every user who owes proof is told exactly what we need (proof-loop-lead-fable-p1 plan section 1); copy = proof-loop captain card L11c (22:5xZ), verbatim per need code; sent only on the captain's yes"
readonly APPROVAL_REF_APPROVED_ELSEWHERE="firstmate brief humanless-need-asks-r1 2026-11-14: a request blocked by another person's approved credit gets a decision and a message; the line itself is unapproved and send-locked (APPROVED_ELSEWHERE_COPY_APPROVED)"
readonly APPROVAL_REF_PROOF_REFUSAL="captain 2026-11-15: the people whose document the reader rejected are told once, with the reason and what would change it; Fable GO on the three rendered bodies corr=208a8463f735ff45 2026-11-15T13:41Z (reply in this conversation, evidence = proof_reviewer ASK_LINES per need code); firstmate decisions 001 and 002: one sentence set per track, only where the reader recorded the need the body names"
readonly APPROVAL_REF_REMOVAL="firstmate 2026-10-16 15:14Z, captain-driven: owners of credits WE removed must be told which credit and role, why, and how to dispute by replying with a document (support measured 35 owners never told). Fraud removals stay silent by captain order (firstmate 2026-10-16 15:48Z)."
# Ruling refund-confirm-1103 (Fable d2, 2026-11-03 22:0xZ, relayed to this lane as firstmate inbox 109): customers
# whose money ALREADY moved are told so without waiting on a human Slack id. The copy is the ruling's own text; the
# subject is the one customer support staged for d2's read (the ruling names only the body), and every fact is read
# from Stripe/core rather than typed (the ruling: "every placeholder from Stripe/core, never typed by hand").
readonly APPROVAL_REF_REFUND_CONFIRM="Fable d2 ruling refund-confirm-1103 (2026-11-03 22:0xZ, firstmate 109): 'confirming your refund of {amount} issued on {date} to the card ending {last4}. {one factual sentence on what changed} Nothing more is needed from you.' - --approved-by fable-ruling-1103-d2/refund-confirm; no human Slack id needed under firstmate 097"
# The ONE decline (captain 2026-10-29 13:2xZ verbatim: "It feels like we are over-communicating when we deny a credit: we
# could just say supporting information was not provided adequate enough to earn the credit, and if they want to submit
# something they can submit something again to start the process again"). Ruling: decline-copy-ruling.md (ops-humans-off
# -fable-o1, 2026-10-29) items 1 and 3. It replaces the retired after-rejection note (which named ONE of five reasons -
# exactly the lesson a forged document learns from) and it is the SAME sentence for a fraud-deny and for an ordinary
# shortfall, by design: nothing about which check failed ever reaches the user.
# The WORDS changed on 2026-11-12 (captain ~01:00Z, verbatim above decline_note): the 10-29 sentence said the
# supporting information "wasn't enough", which is a reason. The decision that there is ONE decline, with no reason
# and no follow-up, is still the 10-29 one. The exact bytes are no longer approved by this constant at all: every
# rendered body needs the reviewer's signed verdict from the outbound copy gate, recorded on the ledger row.
readonly APPROVAL_REF_DECLINE="captain U7RP6HKUZ 2026-11-12 ~01:00Z (verbatim above decline_note: say the credit is denied for now, the verification didn't prove out, no reason, never fraud, you can resubmit later); one decline, no reason, no follow-up = captain 2026-10-29 13:2xZ, decline-copy-ruling.md item 1; the rendered bytes are approved per body by the outbound copy gate (copy_verdict_id on this row); firstmate brief outbound-copy-fable-gate-v1"
readonly APPROVAL_REF_PAST="captain U7RP6HKUZ 2026-10-15 23:35Z: \"im referring to before when nick made changes and did a trust verify flow and now we have a lotnof credits to verify with documents and give people 30 days to send something in for the ones missing documents\"; 2026-10-16 00:35Z: \"how many credits were approved without documentstion i dont want to lose users unless its obvious fraud feom tbe past\""
# Caroline's outbound sanitizer word list, IDENTICAL to intercom-ops-write.sh's
# SANITIZER_WORDS (which CI compares to plugins/intercom/src/sanitize-tool-leak.ts);
# scripts/tests/intercom-verify-request.bats fails if the two lines ever differ.
# Conversation tags that mean "do not auto-message here" (same set as resolve-notify.py and
# resolution-matcher.py); an in-thread note is never posted into a conversation carrying one.
readonly BLOCKED_CONV_TAGS="abuse-block instagram facebook twitter x whatsapp messenger tiktok sms"
readonly SANITIZER_WORDS="profile_status|profile_lookup|credits_search|create_ticket|subscription_status|remove_credits|dedupe_check|credit_verification_check|profiles_claim_self|credits_verify|profiles_consolidate|order_lookup|order_address_update|founding_status|founding_buyback_link|support_action_router|memory_search|memory_get|profile_analytics_status|profile_credits_status|profile_claim_status|retention_offer_check|retention_offer_apply|cancel_subscription|billing_status|track_analytics_status|analytics_refresh_request|analytics_recheck|subscription_cancel|refund_policy_check|refund_create|catalog_status|track_lookup|metadata_capture_request|artwork_refresh_request|catalog_recheck|user_status|resend_verification|email_delivery_status|login_recovery_packet|profile_change_packet|profile_merge_check|account_merge_preflight|email_change_preflight|profile_removal_preflight|ticket|tool failed|error fetching|unable to look up|the system says|my system|there was an issue with|ClickUp|openclaw|HYDRA|platform-data-processing"
# The decline copy's OWN forbidden list (decline-copy-ruling.md item 1: "no reason, no list of what was missing or
# wrong, no deadline, no removal language, no fraud/forged/doctored/suspicious, no speak-to-support, no threshold, no
# popularity word, no list of accepted document types"). It is asserted on the COPY PARAGRAPHS only, never on the
# track list: "Because", "Within" and "Fraud" are all real song titles and a decline still has to go out about them.
# A match is a build defect: the note is refused before anything is claimed or sent.
# "resubmit" left this list on 2026-11-12: the captain's denial now SAYS it ("You can always resubmit for a credit
# again later"), and the outbound copy gate refuses a denial that does not.
# A claim-shaped decline (the entry's request_id is claim-<claiming.id>) renders the profile-claim sentence instead of
# the credit one. COPY is readonly by the time the payload's shape is known (the file is read later), so the shape rides
# its own flag: COPY stays the copy token the ledger records, DECLINE_CLAIM says which of its two shapes rendered.
DECLINE_CLAIM=0
readonly DECLINE_FORBIDDEN='because|didn.t name|different track|different role|unreadable|couldn.t read|not a document|fraud|forged|doctored|suspicious|support team|business day|within|popular|speak to|we check|we look at|threshold'

# QA #1603: the gate's number / roles checks count TRACKS with the renderer's own identity (tkey: track_id, else the
# normalised title + artist) - two different tracks both called "Home" are two tracks. Byte-identical to RENDER_JQ's defs.
readonly TRACKS_JQ='def tnorm: tostring | ascii_downcase | gsub("\\s+"; " ") | gsub("^ +| +$"; "");
def tkey: if ((.track_id // "") | length) > 0 then "id:" + .track_id
          else "t:" + ((.track_title // "") | tnorm) + "|" + ((.artist_name // "") | tnorm) end;
def ntracks: [ .credits[]? | tkey ] | unique | length;'
die()    { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
# [key=dated-windows-are-data] (l1 2026-11-02): the /o window lives in the policy file, re-read on every run - a window
# that closes must never need a deploy to close. Prints "<state> <due_at>" where state is open | closed | unreadable;
# unreadable is its own state and the caller refuses on it (fail closed), never "not yet expired".
gmail_o_hold() {
  "$PY_BIN" -I -c 'import json, sys
from datetime import datetime
try:
    h = json.load(open(sys.argv[1], encoding="utf-8"))["holds"]["gmail"]
except (OSError, ValueError, KeyError, TypeError):
    print("unreadable -"); raise SystemExit(0)
if not isinstance(h, dict):
    print("unreadable -"); raise SystemExit(0)
due = h.get("due_at")
# QA #1647 finding 2 (round 2): a due_at is only a window if it is a REAL UTC instant, not merely well shaped. A shape
# check accepted 9999-99-99T99:99:99Z, which compares AFTER every real clock reading and opened the gate forever. So the
# value is PARSED: strptime rejects impossible calendar/time fields, and the round trip rejects anything that parses
# into a different string. malformed stays its own state (the FILE read fine and the VALUE is wrong).
try:
    if not isinstance(due, str) or datetime.strptime(due, "%Y-%m-%dT%H:%M:%SZ").strftime("%Y-%m-%dT%H:%M:%SZ") != due:
        raise ValueError(due)
except (TypeError, ValueError):
    print("malformed -"); raise SystemExit(0)
print("%s %s" % ("open" if h.get("clause_open") is True else "closed", due))' "$POLICY_JSON" 2>/dev/null || echo "unreadable -"
}
refuse() { printf 'REFUSED: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------------------
# Deployed copies reject EVERY override before anything else can run.
if [ "$TESTABLE" != "1" ]; then
  for v in INTERCOM_VERIFY_TEST_LOG_DIR INTERCOM_VERIFY_TEST_CURL_BIN INTERCOM_VERIFY_TEST_TIMEOUT_BIN \
           INTERCOM_VERIFY_TEST_LEDGER INTERCOM_VERIFY_TEST_LEDGER_HELPER INTERCOM_VERIFY_TEST_DAY \
           INTERCOM_VERIFY_TEST_PROOF_DB INTERCOM_VERIFY_TEST_STAGE2_HELPER INTERCOM_VERIFY_TEST_CORE_NOTICE_HELPER INTERCOM_VERIFY_TEST_NOW INTERCOM_VERIFY_TEST_DISABLED_DIR INTERCOM_VERIFY_TEST_COMM_STATE_HELPER INTERCOM_VERIFY_TEST_GATE_FACTS_HELPER INTERCOM_VERIFY_TEST_REPLICA_SERVE INTERCOM_VERIFY_TEST_GMO INTERCOM_VERIFY_TEST_POLICY INTERCOM_VERIFY_TEST_FABLE_RULINGS INTERCOM_VERIFY_TEST_STRIPE_BASE INTERCOM_VERIFY_TEST_JQ_LIB INTERCOM_VERIFY_TEST_STRIPE_ENV_FILE INTERCOM_VERIFY_TEST_API_RETRY_SLEEPS DECLINE_CLOSE_HELPER INTERCOM_VERIFY_TEST_DECLINE_SINCE INTERCOM_VERIFY_TEST_DECLINE_CORE_ROUTE_OFF INTERCOM_VERIFY_TEST_COPY_GATE INTERCOM_VERIFY_TEST_COPY_STORE; do
    [ -z "${!v:-}" ] || die "$v is not settable on a deployed copy of this script. The log, the ledger, the client and the clock are not parameters: a caller-selectable one is a send nobody can audit."
  done
  LOG_DIR="$PROD_LOG_DIR"
  LEDGER="$PROD_LEDGER"
  LEDGER_HELPER="$PROD_LEDGER_HELPER"
  COPY_GATE="$PROD_COPY_GATE"
  COPY_STORE="$PROD_COPY_STORE"
  STAGE2_HELPER="$PROD_STAGE2_HELPER"
  DECLINE_CLOSE_HELPER="$PROD_DECLINE_CLOSE_HELPER"
  # the activation lock is an OPERATOR decision, never a caller's: a deployed copy is silent whatever the
  # environment says (QA #1718 round 6, 2026-11-06 - the test seam above was reachable in production)
  DECLINE_CORE_ROUTE_OFF=0
  DISABLED_DIR="/etc/hydra"
  CORE_NOTICE_HELPER="$PROD_CORE_NOTICE_HELPER"
  COMM_STATE_HELPER="$PROD_COMM_STATE_HELPER"
  GATE_FACTS_HELPER="$PROD_GATE_FACTS_HELPER"
  REPLICA_SERVE="$PROD_REPLICA_SERVE"
  GATE_FACTS_DIR="$PROD_GATE_FACTS_DIR"
  PROOF_DB="$PROD_PROOF_DB"
  POLICY_JSON="$PROD_POLICY"
  FABLE_RULINGS_FILE="$PROD_FABLE_RULINGS"
  STRIPE_ENV_FILE="$STRIPE_ENV_FILE_PROD"
  CURL_BIN="/usr/bin/curl"
  JQ_BIN="/usr/bin/jq"
  # the jq modules that travel WITH the gate (deploy rsyncs scripts/ including scripts/lib/). A deployed copy resolves
  # them from its own directory, never from the environment: a caller-selectable formatter is a caller-selectable
  # number in a customer's refund note.
  JQ_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib"
  TIMEOUT_BIN="/usr/bin/timeout"
  PY_BIN="/usr/bin/python3"
  STRIPE_API_BASE="$STRIPE_API_BASE_PROD"
  API_RETRIES=2
  API_RETRY_SLEEPS="2 5"
  DAY="$(date -u +%Y-%m-%d)"
else
  LOG_DIR="${INTERCOM_VERIFY_TEST_LOG_DIR:-$PROD_LOG_DIR}"
  LEDGER="${INTERCOM_VERIFY_TEST_LEDGER:-$PROD_LEDGER}"
  LEDGER_HELPER="${INTERCOM_VERIFY_TEST_LEDGER_HELPER:-$PROD_LEDGER_HELPER}"
  COPY_GATE="${INTERCOM_VERIFY_TEST_COPY_GATE:-$PROD_COPY_GATE}"
  COPY_STORE="${INTERCOM_VERIFY_TEST_COPY_STORE:-$PROD_COPY_STORE}"
  STAGE2_HELPER="${INTERCOM_VERIFY_TEST_STAGE2_HELPER:-$PROD_STAGE2_HELPER}"
  DECLINE_CLOSE_HELPER="${INTERCOM_VERIFY_TEST_DECLINE_CLOSE_HELPER:-$PROD_DECLINE_CLOSE_HELPER}"
  DISABLED_DIR="${INTERCOM_VERIFY_TEST_DISABLED_DIR:-/etc/hydra}"
  CORE_NOTICE_HELPER="${INTERCOM_VERIFY_TEST_CORE_NOTICE_HELPER:-$PROD_CORE_NOTICE_HELPER}"
  COMM_STATE_HELPER="${INTERCOM_VERIFY_TEST_COMM_STATE_HELPER:-$PROD_COMM_STATE_HELPER}"
  # OFF unless a test names both: a suite that stubs the two helpers must not start a real replica read on a host
  # that has /opt/hydra (node-8)
  GATE_FACTS_HELPER="${INTERCOM_VERIFY_TEST_GATE_FACTS_HELPER:-}"
  REPLICA_SERVE="${INTERCOM_VERIFY_TEST_REPLICA_SERVE:-}"
  GATE_FACTS_DIR="$LOG_DIR/gate-facts"
  PROOF_DB="${INTERCOM_VERIFY_TEST_PROOF_DB:-$PROD_PROOF_DB}"
  POLICY_JSON="${INTERCOM_VERIFY_TEST_POLICY:-$PROD_POLICY}"
  FABLE_RULINGS_FILE="${INTERCOM_VERIFY_TEST_FABLE_RULINGS:-$PROD_FABLE_RULINGS}"
  STRIPE_ENV_FILE="${INTERCOM_VERIFY_TEST_STRIPE_ENV_FILE:-$STRIPE_ENV_FILE_PROD}"
  CURL_BIN="${INTERCOM_VERIFY_TEST_CURL_BIN:-$(command -v curl || echo /usr/bin/curl)}"
  JQ_BIN="$(command -v jq || echo /usr/bin/jq)"
  JQ_LIB_DIR="${INTERCOM_VERIFY_TEST_JQ_LIB:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib}"
  TIMEOUT_BIN="${INTERCOM_VERIFY_TEST_TIMEOUT_BIN:-$(command -v timeout || command -v gtimeout || echo /usr/bin/timeout)}"
  PY_BIN="$(command -v python3 || echo /usr/bin/python3)"
  STRIPE_API_BASE="${INTERCOM_VERIFY_TEST_STRIPE_BASE:-$STRIPE_API_BASE_PROD}"
  # the retry COUNT is never a seam (a caller-selectable retry count is a caller-selectable load on Intercom); only the
  # sleeps are, so a test does not spend 7 real seconds proving a retry happened.
  API_RETRIES=2
  API_RETRY_SLEEPS="${INTERCOM_VERIFY_TEST_API_RETRY_SLEEPS:-2 5}"
  DAY="${INTERCOM_VERIFY_TEST_DAY:-$(date -u +%Y-%m-%d)}"
fi
readonly LOG_DIR LEDGER LEDGER_HELPER COPY_GATE COPY_STORE STAGE2_HELPER CORE_NOTICE_HELPER GATE_FACTS_HELPER REPLICA_SERVE GATE_FACTS_DIR PROOF_DB POLICY_JSON FABLE_RULINGS_FILE \
  CURL_BIN JQ_BIN TIMEOUT_BIN PY_BIN STRIPE_API_BASE DAY STRIPE_ENV_FILE API_RETRIES API_RETRY_SLEEPS

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
CREDITS_FILE="" APPROVED_BY="" MESSAGE_ID="" ACTION="post" THREAD="" THREAD_AUTO=0 REPLY_DUE="" GMO=0 NO_CORRECTION=0
MESSAGE_TYPE="email" CHANNEL="" INAPP_FALLBACK=0 ROUTE_WHY=""
# In-app delivery (captain 2026-10-26 16:05Z: "Caps may pace email only; the in-app message goes to
# everyone", relayed by firstmate inbox 010): with --channel inapp an initial status-like note goes
# in the user's own open conversation when there is one (as always), otherwise as an Intercom
# in-app message (POST /messages message_type in_app), never by email. The driver uses it once
# the day's email budget is spent, so nobody waits for the email cap. Same copy, same ledger.
# NOT readonly: set_inapp() moves them with the channel (the post-send assertion reads them).
REQ_TYPE="email" EXPECT_TYPE="email"
# The in-app payload is built by payload()'s own branch (request message_type "in_app", body only, no subject);
# MESSAGE_TYPE/EXPECT_TYPE stay "inapp", the value Intercom returns and this repo records (QA #1370).
set_inapp() { MESSAGE_TYPE="inapp"; EXPECT_TYPE="inapp"; }
CAMPAIGN="verify-live" KIND="initial" PARENT_ID="" CAMPAIGN_SET=0 KIND_SET=0 COPY_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --credits-file|--approved-by|--message-id|--campaign|--kind|--parent-message-id|--copy|--conversation|--reply-due|--channel)
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
        --reply-due)         REPLY_DUE="$2" ;;
        --channel)           CHANNEL="$2" ;;
      esac
      shift 2 ;;
    --dry-run)  ACTION="dry-run"; shift ;;
    --doc-check) ACTION="doc-check"; shift ;;
    --thread-contact) ACTION="thread-contact"; shift ;;
    --check-recipient) ACTION="check-recipient"; shift ;;
    --gmail-fallback-o) GMO=1; shift ;;   # [key=gmail-o-forward]: the /o clause for the frozen did-vouch set
    # [key=scale-now] (p1 18:42Z): the unattended timer sends uvn-status asks but NOT /c2 corrections until class C has
    # its own clean read-back - an ask that would need the /c2 sentence is deferred, at the check and at the send alike
    --no-correction) NO_CORRECTION=1; shift ;;
    --inapp-fallback) INAPP_FALLBACK=1; shift ;;
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
# QA #1564: the read-only actions open the ledger read-only (mode=ro: never created, never migrated); a ledger that would
# need either refuses the check instead of writing - a dry run or recipient check never changes persistent state
ledger() {
  case "$ACTION" in
    check-recipient|dry-run|validate) "$PY_BIN" -I "$LEDGER_HELPER" --db "$LEDGER" --readonly "$@" ;;
    *) "$PY_BIN" -I "$LEDGER_HELPER" --db "$LEDGER" "$@" ;;
  esac
}

# _api_is_read METHOD PATH: true when the call cannot have been APPLIED, so a retry cannot duplicate a side effect.
# Intercom's searches are POSTs that only read; every other non-GET is a write and is never retried.
_api_is_read() {
  case "$1" in GET|HEAD) return 0 ;; esac
  case "$2" in */search|*/search\?*) return 0 ;; esac
  return 1
}

# _api_transport_rc RC: true when curl failed BEFORE the request reached a decision. A 4xx/5xx body is rc 0 here (curl
# without -f), so an HTTP error is never retried. 124 is `timeout` killing the call.
_api_transport_rc() {
  case "$1" in 6|7|18|28|35|52|55|56|124) return 0 ;; esac
  return 1
}

# _api_backoff ATTEMPT: the sleep before retry ATTEMPT (1-based), from API_RETRY_SLEEPS.
_api_backoff() {
  local n="$1" i=0 s=2
  for s in $API_RETRY_SLEEPS; do
    i=$((i + 1))
    if [ "$i" -ge "$n" ]; then printf '%s' "$s"; return 0; fi
  done
  printf '%s' "$s"
}

# api METHOD PATH [payload-on-stdin]: the response body on stdout, curl rc as the status.
# The payload travels through STDIN, never argv (MAX_ARG_STRLEN; see intercom-ops-write.sh).
# A READ is retried up to API_RETRIES times on a TRANSPORT failure only (see API_RETRIES above). The payload is read
# into a variable first so every attempt sends the same bytes; only the FINAL attempt's body reaches stdout, so a
# retried call never emits two bodies to a caller that parses one.
api() {
  local method="$1" path="$2" payload="" out="" rc=0 attempt=0 max=0
  if [ "$method" != "GET" ]; then payload="$(cat)"; fi
  if _api_is_read "$method" "$path"; then max="$API_RETRIES"; fi
  while :; do
    if [ "$method" = "GET" ]; then
      out="$("$TIMEOUT_BIN" 45 "$CURL_BIN" -sS -X GET \
        -H "Authorization: Bearer $MUSOAI_INTERCOM_TOKEN" -H "Accept: application/json" \
        -H "Intercom-Version: $API_VERSION" "$API_BASE$path" 2>&1)" && rc=0 || rc=$?
    else
      out="$(printf '%s' "$payload" | "$TIMEOUT_BIN" 45 "$CURL_BIN" -sS -X "$method" \
        -H "Authorization: Bearer $MUSOAI_INTERCOM_TOKEN" -H "Accept: application/json" \
        -H "Content-Type: application/json" -H "Intercom-Version: $API_VERSION" \
        --data @- "$API_BASE$path" 2>&1)" && rc=0 || rc=$?
    fi
    if [ "$rc" -eq 0 ] || [ "$attempt" -ge "$max" ] || ! _api_transport_rc "$rc"; then break; fi
    attempt=$((attempt + 1))
    local wait_s; wait_s="$(_api_backoff "$attempt")"
    printf 'api: %s %s transport failure (rc=%s); retry %s/%s in %ss\n' \
      "$method" "$path" "$rc" "$attempt" "$max" "$wait_s" >&2
    sleep "$wait_s"
  done
  printf '%s' "$out"
  return "$rc"
}

# stripe_key / stripe_get / verified_refund_facts --------------------------------------------------------------
# QA 2026-11-04 finding 1: a refund note is a FINANCIAL statement, so its facts are read from the processor at send
# time. Shape checks on a caller-supplied file can describe a real refund id with a wrong amount, card, date or state,
# and the note would then say something untrue about money that actually moved.
# The key is read here and nowhere else - never echoed, never an argv (no ps, no shell history).
stripe_key() {
  if [ -n "${MUSOAI_STRIPE_API_KEY:-}" ]; then printf '%s' "$MUSOAI_STRIPE_API_KEY"; return 0; fi
  [ -r "$STRIPE_ENV_FILE" ] || return 1
  grep -E "^${STRIPE_KEY_VAR}=" "$STRIPE_ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "\"'" | tr -d '\r'
}
stripe_get() { # <path>: the response body on stdout, non-zero when the call itself failed
  # QA r5 2026-11-04 finding 3: the key must NEVER be an argv element - `curl -H "Authorization: Bearer sk_..."`
  # is visible to any local `ps` / /proc/<pid>/cmdline. curl reads its config from stdin (-K -), so the secret
  # travels on a pipe: it appears in no argv and in no file on disk.
  local key
  key="$(stripe_key)" || return 2
  [ -n "$key" ] || return 2
  printf '%s' "$key" | grep -qE '^[A-Za-z0-9_]+$' \
    || { echo "STRIPE KEY CONTAINS UNEXPECTED CHARACTERS; refusing to pass it to curl" >&2; return 2; }
  # QA 2026-11-04 (the "invalid to curl" finding): curl parses [] and {} in a URL as GLOBS, so an expand[] parameter
  # can be rewritten or rejected ("bad range in URL") depending on what is inside the brackets - the charge read below
  # asks for expand[]=invoice.subscription, and a globbed query is a query Stripe never answered. -g (--globoff) turns
  # that off, so the URL reaches Stripe exactly as written.
  printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/json"\nurl = "%s%s"\n' \
      "$key" "$STRIPE_API_BASE" "$1" \
    | "$TIMEOUT_BIN" 45 "$CURL_BIN" -sS -g -K - 2>&1
}
# verified_refund_facts <refund id>: the refund, its charge and its subscription, straight from Stripe, as one JSON
# object. exit 4 = the processor could not be read / did not agree the object exists: never renders, never sends.
verified_refund_facts() {
  local rid="$1" key refund charge
  key="$(stripe_key)" || { echo "STRIPE KEY UNAVAILABLE" >&2; return 4; }
  [ -n "$key" ] || { echo "STRIPE KEY MISSING ($STRIPE_KEY_VAR in $STRIPE_ENV_FILE)" >&2; return 4; }
  refund="$(stripe_get "/v1/refunds/$rid")" || { echo "REFUND READ FAILED: $(printf '%s' "$refund" | head -c 200)" >&2; return 4; }
  printf '%s' "$refund" | "$JQ_BIN" -e '.id != null and .amount != null and .currency != null and .charge != null' >/dev/null 2>&1 \
    || { echo "REFUND NOT VERIFIED: $(printf '%s' "$refund" | head -c 200)" >&2; return 4; }
  charge="$(stripe_get "/v1/charges/$(printf '%s' "$refund" | "$JQ_BIN" -r '.charge')?expand[]=invoice.subscription")" \
    || { echo "CHARGE READ FAILED: $(printf '%s' "$charge" | head -c 200)" >&2; return 4; }
  printf '%s' "$charge" | "$JQ_BIN" -e '.id != null and .amount != null and .created != null' >/dev/null 2>&1 \
    || { echo "CHARGE NOT VERIFIED: $(printf '%s' "$charge" | head -c 200)" >&2; return 4; }
  # The subscription sentence comes from Stripe's object (cancel_at_period_end + current_period_end, or status), never
  # from a caller's opinion of it.
  "$JQ_BIN" -n --argjson r "$refund" --argjson c "$charge" '
    ($c.invoice) as $inv
    | (if ($inv | type) == "object" then $inv.subscription else null end) as $sub
    | { refund_id: $r.id, amount: $r.amount, currency: $r.currency, refund_status: ($r.status // ""),
        refund_created: $r.created, charge_id: $c.id, charge_amount: $c.amount, charge_created: $c.created,
        card_last4: ($c.payment_method_details.card.last4 // ""),
        card_brand: ($c.payment_method_details.card.brand // ""),
        charge_email: ($c.billing_details.email // ""),
        subscription: (if ($sub | type) == "object"
                       then { id: $sub.id, status: ($sub.status // ""),
                              cancel_at_period_end: ($sub.cancel_at_period_end == true),
                              current_period_end: ($sub.current_period_end // 0) }
                       else null end) }'
}

# bind_refund_to_processor <input-json>: prints the input with `.refund` REPLACED by what Stripe says, or refuses.
# QA 2026-11-04 finding 1: validation alone is not binding - the note must render the processor's numbers, so a
# structurally valid file with a real refund id and a wrong amount cannot produce a false confirmation. Every field the
# copy uses is compared first (a disagreement is named, never silently corrected) and then overwritten from Stripe.
bind_refund_to_processor() {
  local input="$1" rid facts why uemail
  rid="$(printf '%s' "$input" | "$JQ_BIN" -r '.refund.refund_id // ""')"
  # r5 2026-11-04 finding 1 (critical): binding the refund to its FACTS is not binding it to its RECIPIENT. A file whose
  # user is one customer and whose refund belongs to another rendered one customer's money to the other (235578/Pancho
  # describing 228568's $210.72, card 2009, 2027-09-06) and exited 0. The charge carries the payer's billing email, so
  # the note can only be built when Stripe's payer is the person this file addresses - and an ABSENT or unreadable
  # (e.g. encrypted) address is a refusal, never a default yes.
  uemail="$(printf '%s' "$input" | "$JQ_BIN" -r '.user.email // "" | ascii_downcase')"
  facts="$(verified_refund_facts "$rid")" || refuse "refund-confirm: the refund facts could not be read from Stripe ($(printf '%s' "$facts" | head -c 200)). Nothing was sent or claimed; a refund note never renders an unverified fact."
  why="$(printf '%s' "$facts" | "$JQ_BIN" -L "$JQ_LIB_DIR" -r --argjson in "$(printf '%s' "$input" | "$JQ_BIN" -c '.refund')" --arg uemail "$uemail" '
    include "refund-money";
    def d2: todate | .[0:10];
    # QA r5 2026-11-04 finding 2: `pending` is money on its way, not money that arrived - a note saying "confirming
    # your refund ... issued on <date>" about a refund that can still fail is premature, so only `succeeded` renders.
    (if (.charge_email | ascii_downcase) == "" then "recipient: Stripe records no billing email for this charge (absent or encrypted), so the refund cannot be tied to \($uemail)" else empty end),
    (if (.charge_email | ascii_downcase) != "" and (.charge_email | ascii_downcase) != $uemail
     then "recipient: the refund on \(.refund_id) belongs to \(.charge_email | ascii_downcase), the file addresses \($uemail)" else empty end),
    (if .refund_status != "succeeded" then "refund status is \(.refund_status), not a completed refund" else empty end),
    (if refund_money(.amount; .currency) != $in.amount then "amount: Stripe says \(refund_money(.amount; .currency)) \(.currency), the file says \($in.amount)" else empty end),
    (if .currency != $in.currency then "currency: Stripe says \(.currency), the file says \($in.currency)" else empty end),
    (if (.refund_created | d2) != $in.issued_on then "issued_on: Stripe says the refund was issued \(.refund_created | d2), the file says \($in.issued_on)" else empty end),
    (if .card_last4 != $in.card_last4 then "card_last4: Stripe says \(.card_last4), the file says \($in.card_last4)" else empty end),
    (if .subscription == null then "the charge has no subscription on it, so no subscription sentence can be true" else empty end),
    (if .subscription != null and (if .subscription.status == "canceled" or .subscription.status == "incomplete_expired"
         then "cancelled"
         elif (.subscription.cancel_at_period_end and (.subscription.status == "active" or .subscription.status == "trialing"))
         then "cancel_at_period_end"
         elif .subscription.status == "active" or .subscription.status == "trialing" then "active"
         else "unknown:" + .subscription.status end) != $in.subscription_state
     then "subscription_state: Stripe says \(if .subscription.status == "canceled" or .subscription.status == "incomplete_expired" then "cancelled" elif (.subscription.cancel_at_period_end and (.subscription.status == "active" or .subscription.status == "trialing")) then "cancel_at_period_end" elif .subscription.status == "active" or .subscription.status == "trialing" then "active" else "unknown:" + .subscription.status end), the file says \($in.subscription_state)" else empty end),
    (if .subscription != null and .subscription.cancel_at_period_end
        and (.subscription.current_period_end | d2) != ($in.active_until // "") and $in.subscription_state == "cancel_at_period_end"
     then "active_until: Stripe says \(.subscription.current_period_end | d2), the file says \($in.active_until // "")" else empty end)
  ' 2>&1)"
  [ -z "$why" ] || refuse "refund-confirm: the file and Stripe disagree, so nothing was sent or claimed. $why"
  printf '%s' "$input" | "$JQ_BIN" -L "$JQ_LIB_DIR" -c --argjson f "$facts" '
    include "refund-money";
    def d2: todate | .[0:10];
    .refund = { refund_id: $f.refund_id, amount: refund_money($f.amount; $f.currency), currency: $f.currency,
                issued_on: ($f.refund_created | d2), card_last4: $f.card_last4,
                subscription_state: (if $f.subscription.status == "canceled" or $f.subscription.status == "incomplete_expired"
                                     then "cancelled"
                                     elif ($f.subscription.cancel_at_period_end and ($f.subscription.status == "active" or $f.subscription.status == "trialing"))
                                     then "cancel_at_period_end"
                                     elif $f.subscription.status == "active" or $f.subscription.status == "trialing" then "active"
                                     else "unknown:" + $f.subscription.status end),
                active_until: (if $f.subscription != null and $f.subscription.cancel_at_period_end
                               then ($f.subscription.current_period_end | d2) else null end) }'
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
    # the lookup is cached for the real tagging only: a dry run writes nothing to the ledger (QA #1564)
    [ "$ACTION" = dry-run ] || ledger set-conversation --message-id "$MESSAGE_ID" --conversation-id "$CONV" >/dev/null
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
  # for more time. The latest reply's own time is recorded per message, so a reply to the
  # decline is seen too.
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
  initial|reminder-14|reminder-25|reminder-7) ;;
  *) refuse "--kind must be initial, reminder-14, reminder-25 or reminder-7 (got '$KIND'). The after-rejection note is retired: a closed request gets the `decline` campaign (captain 2026-10-29 13:2xZ), which states no reason and has no follow-up." ;;
esac
if [ "$CAMPAIGN" = "claim-proof-ask" ]; then
  case "$KIND" in initial|reminder-7) ;; *) refuse "claim-proof-ask has one follow-up, --kind reminder-7." ;; esac
elif [ "$KIND" = "reminder-7" ]; then
  refuse "--kind reminder-7 applies to claim-proof-ask only."
fi
[ "$CAMPAIGN" != "claim-status" ] || [ "$KIND" = "initial" ] || refuse "claim-status has no follow-ups (one note per claim)."
[ "$CAMPAIGN" != "claim-proof-pending" ] || [ "$KIND" = "initial" ] || refuse "claim-proof-pending has no follow-ups (one note per claim)."

# C11: LIVE = a real send OR its read-only recipient check - every send lock and send-time check runs on LIVE, so the
# check reports what the send would do (QA #1516: set before the copy selection, whose locks read it too)
[ "$ACTION" != "check-recipient" ] || [ "$KIND" = "initial" ] \
  || refuse "--check-recipient applies to an initial note only (it must never reach a path that writes)."
LIVE=0
if [ "$ACTION" = "post" ] || [ "$ACTION" = "check-recipient" ]; then LIVE=1; fi

# COPY: which fixed text this message uses.
#   verify-live  windowed (every real send) | v1 (preview only)
#   retro-past   past           (no deadline, no removal language, no follow-up)
case "$CAMPAIGN" in
  verify-live)
    MAX_CREDITS=200; MAX_LISTED=25
    case "$COPY_ARG" in ""|v1|windowed) ;; *) refuse "--copy must be v1 or windowed (got '$COPY_ARG')." ;; esac
    if [ "$LIVE" = "1" ] && [ "$KIND" = "initial" ] && [ "$COPY_ARG" != "windowed" ]; then
      # firstmate 090: every new credit's note is the no-threat v1 note, never removal-due.
      [ "$LIVE_V1_COPY_APPROVED" = "1" ] || refuse "the verify-live v1 copy is not approved for sending (LIVE_V1_COPY_APPROVED=0)."
      COPY="v1"
    elif [ "$LIVE" = "1" ]; then
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
  uvn-reminder-14)
    # The ONE reminder of a sent uvn-status ask, 14 days on, to a user who neither replied nor sent a document.
    # Who may get it is the ledger's rule (verify_ledger.reminder14_user_done), read at the peek and inside the claim;
    # the day the copy states is the ledger's too (ASKED_DAY below), never the payload's.
    MAX_CREDITS=1000; MAX_LISTED=3; COPY="uvnrem14"; APPROVAL_REF="$APPROVAL_REF_UVN_REMINDER"
    [ -z "$COPY_ARG" ] || refuse "--copy applies to verify-live."
    [ "$KIND" = "initial" ] || refuse "uvn-reminder-14 is the one follow-up of an ask and has none of its own."
    [ -z "$REPLY_DUE" ] || refuse "uvn-reminder-14 is an unsolicited reminder, never a reply_due answer."
    [ -z "$CHANNEL" ] || refuse "uvn-reminder-14 goes in the user's open thread or by email; --channel does not apply."
    ;;
  uvn-new-rows)
    # fable-copy-1101-r5/n1: the follow-up ask to a TOLD user (a SENT uvn-status ask) about owed rows NO ask named -
    # the approved uvn ask body over those rows only, the n1 opener first. One message per ROW ever (any ask blocks a
    # row); every uvn-status gate applies (comm_state as the uvn ask, documents, 7-day cooldown, cap, holds).
    MAX_CREDITS=1000; MAX_LISTED=3; COPY="uvn"; APPROVAL_REF="$APPROVAL_REF_UVN; opener $NEW_ROWS_N1_REF"
    [ -z "$COPY_ARG" ] || refuse "--copy applies to verify-live."
    [ "$KIND" = "initial" ] || refuse "uvn-new-rows has no follow-ups."
    [ -z "$REPLY_DUE" ] || refuse "uvn-new-rows is an unsolicited follow-up ask, never a reply_due answer."
    ;;
  withdrawal-confirm)
    # Confirms a credit request the requester asked us to withdraw: one request per message,
    # role + title from the request row. Not an ask; no follow-ups.
    MAX_CREDITS=1; MAX_LISTED=1; COPY="withdrawal"; APPROVAL_REF="$APPROVAL_REF_WITHDRAWAL"
    [ -z "$COPY_ARG" ] || refuse "--copy applies to verify-live."
    [ "$KIND" = "initial" ] || refuse "withdrawal-confirm has no follow-ups."
    ;;
  refund-confirm)
    # Ruling refund-confirm-1103 (Fable d2 2026-11-03 22:0xZ, firstmate 109): confirming refunds that ALREADY happened.
    # One note per REFUND (the Stripe refund id is the request id), never a follow-up: money that moved needs one tell,
    # not a sequence. Facts come from Stripe/core and are validated below; the body is the ruling's copy, byte-exact.
    MAX_CREDITS=1; MAX_LISTED=1; COPY="refundconfirm"; APPROVAL_REF="$APPROVAL_REF_REFUND_CONFIRM"
    [ -z "$COPY_ARG" ] || refuse "--copy applies to verify-live; refund-confirm has one copy, the ruling's."
    [ "$KIND" = "initial" ] || refuse "refund-confirm has no follow-ups: one note per refund, ever."
    ;;
  status-doc-received|status-team-review)
    # No-ask status notes (firstmate 070/071): one per user, ever; up to 3 titles.
    MAX_CREDITS=1000; MAX_LISTED=3; APPROVAL_REF="$APPROVAL_REF_STATUS"
    if [ "$CAMPAIGN" = "status-doc-received" ]; then COPY="docrecv"; else COPY="teamreview"; fi
    # Approved alternative wordings: status-doc-received --copy queued (firstmate 092);
    # status-team-review --copy no-ask = Copy B0 (pending-status-1021, firstmate 106).
    case "$CAMPAIGN:$COPY_ARG" in
      # p1 528 / b1 527 (deployed-copy finding 1): a bare status-doc-received rendered the OLD docrecv line ("Nothing else
      # is needed from you right now", barred) - no --copy is no render: R1 is --copy received, /i is --copy queued-neutral
      status-doc-received:) refuse "status-doc-received needs --copy received (R1) or --copy queued-neutral (/i); the default docrecv line ('Nothing else is needed from you right now') is retired. Nothing was sent or claimed." ;;
      *:) ;;
      # r5 (10-31 21:0xZ, b1's coverage set): docrecvq is RETIRED - "no need to send anything else" is the barred
      # "nothing is needed / no need to resend" family in another form; /i queued-neutral is the only A line
      status-doc-received:queued) refuse "status-doc-received --copy queued is retired (r5 10-31: 'no need to send anything else' is barred); use --copy queued-neutral (/i). Nothing was sent or claimed." ;;
      # Card R1 (proof loop): the receipt for a user who still owes proof; send-locked (STATUS_RECEIVED_COPY_APPROVED).
      status-doc-received:received) COPY="docrecvr"; APPROVAL_REF="$APPROVAL_REF_STATUS_RECEIVED" ;;
      # fable-copy-1030-r5/i: status A NEUTRAL for an UNREAD filing - every R1 thread rule applies (R1LIKE below)
      status-doc-received:queued-neutral) COPY="docrecvn"; APPROVAL_REF="$APPROVAL_REF_STATUS_NEUTRAL" ;;
      status-team-review:no-ask) COPY="teamreviewb0"; APPROVAL_REF="$APPROVAL_REF_STATUS_NOASK" ;;
      # Count-only (firstmate inbox 005): no titles, so any request may be in it; the ledger
      # records the ids given (the driver sends at most 1,000) and user.pending_count is the total.
      status-team-review:count) COPY="teamreviewcount"; APPROVAL_REF="$APPROVAL_REF_STATUS_COUNT"; MAX_CREDITS=1000 ;;
      *) refuse "--copy applies to verify-live (v1|windowed), status-doc-received (received|queued-neutral) and status-team-review (no-ask|count) only." ;;
    esac
    [ "$KIND" = "initial" ] || refuse "$CAMPAIGN has no follow-ups: one message per user, ever."
    if [ "$COPY" = "teamreviewcount" ]; then
      # fable-copy-1030-r5/k has no approved singular count form: one request is never rendered in the count wording
      [ "$("$JQ_BIN" -r '(.user.pending_count // (.credits | length)) >= 2' "$CREDITS_FILE" 2>/dev/null)" = "true" ] \
        || refuse "status-team-review --copy count needs 2 or more requests (the /k count form has no singular); nothing was sent or claimed."
    fi
    ;;
  reply-ref)
    MAX_CREDITS=1; MAX_LISTED=1
    case "$COPY_ARG" in
      q|r|s|t|u|v|w|x|y) COPY="ref$COPY_ARG"; APPROVAL_REF="$REPLY_REF_SERIES/$COPY_ARG" ;;
      z) refuse "reply-ref /z is posted only where the row is literally in Jan's review list; that read is not wired yet - nothing was sent or claimed." ;;
      *) refuse "reply-ref needs --copy q|r|s|t|u|v|w|x|y (fable-copy-1031-r5); got '$COPY_ARG'." ;;
    esac
    [ -n "$REPLY_DUE" ] || refuse "reply-ref is a reply_due answer only: --reply-due <part> --conversation <id>."
    [ "$KIND" = "initial" ] || refuse "reply-ref has no follow-ups."
    # QA #1601 (2): the ref must be the one the classifier picked for THIS part, matched at send time (and in the
    # read-only --check-recipient, so the dry run == the send): the LATEST pick the picker recorded for conversation +
    # part (verify_ledger record-pick, written before it calls the gate) must name exactly this ref, with reason
    # 'mapped', an llm_call_id, and be 0..PICK_MAX_AGE_S old (never future-dated, by any amount). No pick / another ref / stale = refused.
    if [ "$ACTION" = "post" ] || [ "$ACTION" = "check-recipient" ]; then
      [[ "$THREAD" =~ ^[0-9]{1,24}$ ]] && [[ "$REPLY_DUE" =~ ^[0-9]{1,24}$ ]] \
        || refuse "reply_ref:no_pick - the conversation and the answered part must be ids; nothing was sent or claimed."
      PICK_JSON="$(ledger pick-for --conversation "$THREAD" --part "$REPLY_DUE" 2>/dev/null)" \
        || refuse "reply_ref:pick_unreadable - the classifier's recorded pick could not be read; nothing was sent or claimed."
      PICK_WHY="$(printf '%s' "$PICK_JSON" | "$JQ_BIN" -r --arg want "$APPROVAL_REF" --argjson max "$PICK_MAX_AGE_S" '
        if (.ref // "") == "" then "no_pick"
        elif .ref != $want then "pick_mismatch: the classifier picked \(.ref) for this part, not \($want)"
        elif .reason != "mapped" then "pick_not_mapped: \(.reason)"
        elif ((.llm_call_id // "") | length) == 0 then "pick_unaudited: no llm_call_id"
        elif ((now - ((.picked_at // "") | fromdateiso8601? // 0)) as $age | $age > $max or $age < 0) then "pick_stale: picked at \(.picked_at) (outside 0..\($max) s of now)"
        else "ok" end' 2>/dev/null || echo unreadable)"
      [ "$PICK_WHY" = "ok" ] || refuse "reply_ref:$PICK_WHY - nothing was sent or claimed."
      PICK_ID="$(printf '%s' "$PICK_JSON" | "$JQ_BIN" -r '.id // ""')"   # QA #1615 (b1 634): re-read at every later read
    fi
    if [ "$ACTION" = "post" ] && [ "$REPLY_REF_APPROVED" != "1" ]; then
      refuse "reply-ref is send-locked (REPLY_REF_APPROVED=0) until r5 + p1 read the classifier dry run; --dry-run / --check-recipient only. Nothing was sent or claimed."
    fi
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
  merge-claim-first)
    # r5 copy e1: one ask per user, ever; no follow-ups.
    MAX_CREDITS=1; MAX_LISTED=1; COPY="mergeclaimfirst"; APPROVAL_REF="$APPROVAL_REF_MERGE_CLAIM_FIRST"
    [ -z "$COPY_ARG" ] || refuse "--copy applies to verify-live and the status notes; merge-claim-first has one copy, r5's e1."
    [ "$KIND" = "initial" ] || refuse "merge-claim-first has no follow-ups: one ask per user, ever."
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
  proof-need-ask)
    # Card L11c: ONE message per user per need code (Fable [key=l11c-plural]), up to 3 titles + "and N more".
    MAX_CREDITS=1000; MAX_LISTED=3; COPY="proofneed"; APPROVAL_REF="$APPROVAL_REF_PROOF_NEED_ASK"
    [ -z "$COPY_ARG" ] || refuse "--copy applies to verify-live and the status notes; proof-need-ask's line is picked by need.code."
    [ "$KIND" = "initial" ] || refuse "proof-need-ask has no follow-ups: one ask per request, ever."
    # fable-copy-1030-r5/l2 (1) / p1 552: a document older than 180 days is NOT asked about by the automated line - the row
    # waits for a human (wait:stale_filing, need_asks build lists it); refused here too, nothing claimed
    if [ "$("$JQ_BIN" -r --arg day "$DAY" '((.need.doc_received_at // "")[0:10]) as $d
        | if ($d | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) | not then "shape"
          elif (($d + "T00:00:00Z" | fromdateiso8601 | todate)[0:10]) != $d then "shape"   # 2026-02-30 is not a day
          elif (($day + "T00:00:00Z" | fromdateiso8601) - ($d + "T00:00:00Z" | fromdateiso8601)) > 180 * 86400 then "stale"
          else "ok" end' "$CREDITS_FILE" 2>/dev/null || echo shape)" = "stale" ]; then
      # (an unreadable date is the need-shape check's refusal, below)
      refuse "e_stale_filing: the document this per-need ask is about was sent more than 180 days ago; a human picks it up (wait:stale_filing). Nothing was sent or claimed."
    fi
    ;;
  credit-approved-elsewhere)
    # One message per user for the requests the conflict rule decided, up to 3 titles + "and N more".
    MAX_CREDITS=1000; MAX_LISTED=3; COPY="apprelsewhere"; APPROVAL_REF="$APPROVAL_REF_APPROVED_ELSEWHERE"
    [ -z "$COPY_ARG" ] || refuse "--copy applies to verify-live and the status notes; credit-approved-elsewhere has one copy."
    [ "$KIND" = "initial" ] || refuse "credit-approved-elsewhere has no follow-ups: one message per request, ever."
    ;;
  proof-refusal)
    # One message per user for every rejected request that has a body. Every track is written out (MAX_LISTED is
    # not read by this copy: there is no "and N more", because each track carries its own reason).
    MAX_CREDITS=1000; MAX_LISTED=1000; COPY="refusal"; APPROVAL_REF="$APPROVAL_REF_PROOF_REFUSAL"
    [ -z "$COPY_ARG" ] || refuse "--copy applies to verify-live and the status notes; proof-refusal's body is picked by each credit's reason and need."
    [ "$KIND" = "initial" ] || refuse "proof-refusal has no follow-ups: one message per request, ever."
    ;;
  gap-ask)
    # Fable's gap ask for credits whose document on file does not cover them (stage-2
    # need_more). Once per credit; up to 3 track/role pairs, then "and N more".
    MAX_CREDITS=1000; MAX_LISTED=3; COPY="gap"; APPROVAL_REF="$APPROVAL_REF_GAP_ASK"
    [ -z "$COPY_ARG" ] || refuse "--copy applies to verify-live; gap-ask has one copy, Fable's paragraph."
    [ "$KIND" = "initial" ] || refuse "gap-ask has no follow-ups: no deadline, no reminders."
    # r5 (10-31 21:0xZ) / /l on number: the gap paragraph is singular ("this track ... Your request stays open"); two or
    # more distinct tracks need the plural text, which is not coded or approved yet - refuse until it is
    if [ "$("$JQ_BIN" -r "$TRACKS_JQ"' ntracks' "$CREDITS_FILE" 2>/dev/null || echo 99)" -ge 2 ]; then
      refuse "gap_plural_uncoded: this gap ask names 2 or more tracks, and the plural gap text is not approved yet (r5 /l on number). Nothing was sent or claimed."
    fi
    ;;
  decline)
    # The ONE decline (captain 2026-10-29 13:2xZ; decline-copy-ruling.md). A NOTICE, not an ask: it states no reason,
    # asks for nothing, and carries no deadline. One per request id ever, one message per user per UTC day, and none
    # within 7 days of another note (all three in verify_ledger). The copy shape is picked by the FILE, not the caller:
    # a claim-shaped entry (key claim-<claiming.id>) gets the profile-claim wording, a credit-shaped entry the credit one.
    MAX_CREDITS=1000; MAX_LISTED=25; COPY="decline"; APPROVAL_REF="$APPROVAL_REF_DECLINE"
    # the send lock is real, not decorative: flipping DECLINE_COPY_APPROVED to 0 (or the campaign shipping without the
    # ruling) stops every send while --dry-run keeps rendering for review.
    [ "$DECLINE_COPY_APPROVED" = 1 ] || refuse "the decline's copy is send-locked (DECLINE_COPY_APPROVED=0): it goes live only in a PR carrying the captain's approval of the rendered copy."
    [ -z "$COPY_ARG" ] || refuse "--copy applies to verify-live and the status notes; decline has ONE copy (captain 2026-10-29 13:2xZ) and it is pinned."
    [ "$KIND" = "initial" ] || refuse "decline has no follow-ups: one decline per request id, ever. There is no reminder and no second note."
    ;;
  wait-apology)
    # d2's approved copy, rendered VERBATIM (sha256 83b82addc0e041bc): an apology plus exactly ONE fact sentence chosen
    # from the LIVE request state. The fact arrives in .apology.fact (F1|F2|F3) with .apology.paid and
    # .apology.all_approved; ANY other state refuses that user - no message beats a wrong one. No date, no ETA, no
    # promise of approval anywhere in it.
    MAX_CREDITS=1000; MAX_LISTED=3; COPY="waitapol"; APPROVAL_REF="$APPROVAL_REF_WAIT_APOLOGY"
    [ -z "$COPY_ARG" ] || refuse "--copy applies to verify-live; wait-apology has one copy, d2's file verbatim."
    [ "$KIND" = "initial" ] || refuse "wait-apology has no follow-ups: one message per user, ever."
    ;;
  *) refuse "--campaign must be verify-live, retro-past, removal-notice, takeback-notice, uvn-status, withdrawal-confirm, status-doc-received, status-team-review, email-changed, email-changed-dup, claim-proof-ask, claim-status, gap-ask, decline, merge-pending, merge-claim-first, credit-hold-status, claim-proof-pending or proof-need-ask, wait-apology, uvn-new-rows, uvn-reminder-14, credit-approved-elsewhere or proof-refusal (got '$CAMPAIGN'). Each campaign is pinned in this script; there is no other." ;;
esac
# C11 (p1 223): --check-recipient is the dry run that equals the send. It runs every send-time check a real send runs
# up to the claim (the ledger peek, core_notice, the go-live guards, comm_state, the status-note Intercom reads, the
# thread check) READ-ONLY: each write on that path is guarded by ACTION=post (LIVE below), so it still never writes.
# Initial notes only (a reminder's claim path is different).
[ "$ACTION" != "doc-check" ] || [ "$CAMPAIGN" = "retro-past" ] \
  || refuse "--doc-check applies to --campaign retro-past only: a removal notice is not an ask, and a new credit's note is never skipped for an Intercom attachment."
# Fable [key=reply-due] (l1 219, p1 200): answering a user who wrote to us and got no answer for > 24 h. EXACTLY ONE
# in-thread answer per triggering customer part (ledger), one per thread per 48 h. The 7-day cooldowns (core notice,
# any-thread admin part, the gate's own 7-day note rule) do not apply to it; comm_state verifies the trigger (the
# customer's part, unanswered, > 24 h old, in an on-topic thread of exactly this contact) and every other rule applies.
if [ -n "$REPLY_DUE" ]; then
  printf '%s' "$REPLY_DUE" | grep -qE '^[0-9]{1,24}$' || refuse "--reply-due needs the customer part id (digits)."
  [ -n "$THREAD" ] || refuse "--reply-due answers in the user's own thread: --conversation <id> is required."
  # [key=reply-due-classes]: the coded answer classes; comm_state holds any campaign that is not the ONE class it picks
  case "$CAMPAIGN" in uvn-status|status-doc-received|status-team-review|reply-ref) ;;
    *) refuse "--reply-due applies to uvn-status, status-doc-received, status-team-review (the coded answer classes) and reply-ref (the approved reply set)." ;; esac
fi
if [ "$GMO" = 1 ]; then
  [ "$CAMPAIGN" = "uvn-status" ] && [ "$KIND" = "initial" ] && [ -z "$REPLY_DUE" ] \
    || refuse "--gmail-fallback-o (/o) applies to an initial uvn-status ask only, never a reply_due answer or a follow-up."
  # l1 o-retire-1102: the flag is the gate, whatever the clock says (a future window does not reopen a retired clause),
  # and it gates a DRY RUN too - a retired clause must not even render, or a reviewer sees a promise we cannot keep.
  [ "$GMAIL_FALLBACK_O_APPROVED" = "1" ] || refuse "/o is retired (GMAIL_FALLBACK_O_APPROVED=0, fable-copy-1030-r5/o: the promise needs a readable Gmail; l1 ruling 2026-11-02). Nothing was sent or claimed."
  # QA #1647 finding 1: the policy window gates EVERY path, not only a real send. A dry run that renders a promise the
  # send would refuse is a reviewer reading a message no user can receive - so preview and post decide together.
  o_hold="$(gmail_o_hold)"; o_state="${o_hold%% *}"; o_due="${o_hold#* }"
  [ "$o_state" != "unreadable" ] \
    || refuse "/o: the policy file ($POLICY_JSON) holds.gmail could not be read, so the clause's window is unknown. Nothing was sent or claimed."
  [ "$o_state" != "malformed" ] \
    || refuse "/o: holds.gmail.due_at is not a canonical UTC timestamp (YYYY-MM-DDTHH:MM:SSZ) in $POLICY_JSON, so the window cannot be read. Nothing was sent or claimed."
  [ "$o_state" = "open" ] || refuse "/o is retired in the policy (holds.gmail.clause_open=false, $GMAIL_FALLBACK_O_REF). Nothing was sent or claimed."
  [ "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \< "$o_due" ] \
    || refuse "/o's window closed at $o_due (holds.gmail.due_at, dated unlock). Nothing was sent or claimed."
fi
if [ -n "$THREAD" ]; then
  case "$CAMPAIGN" in
    uvn-status|uvn-new-rows|uvn-reminder-14|withdrawal-confirm|status-doc-received|status-team-review|email-changed|email-changed-dup|claim-status|gap-ask|merge-pending|merge-claim-first|credit-hold-status|claim-proof-pending|proof-need-ask|reply-ref) ;;
    *) refuse "--conversation (in-thread delivery) applies to uvn-status, withdrawal-confirm, the status notes, claim-status, email-changed, gap-ask, merge-pending, merge-claim-first, credit-hold-status, claim-proof-pending and proof-need-ask only." ;;
  esac
  printf '%s' "$THREAD" | grep -qE '^[0-9]{1,24}$' \
    || refuse "--conversation must be the numeric Intercom conversation id (got '$THREAD')."
  MESSAGE_TYPE="comment"
fi
case "$CHANNEL" in
  "") ;;
  inapp)
    case "$CAMPAIGN" in
      uvn-status|status-doc-received|status-team-review|claim-status|gap-ask) ;;
      *) refuse "--channel inapp applies to uvn-status, the status notes, claim-status and gap-ask only." ;;
    esac
    [ "$KIND" = "initial" ] || refuse "--channel inapp applies to an initial note."
    if [ -z "$THREAD" ]; then set_inapp; fi ;;
  *) refuse "--channel must be inapp (got '$CHANNEL'); without it the note goes in-thread or by email." ;;
esac
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
[ -n "$APPROVED_BY" ] || refuse "--approved-by is required: the captain's Slack id (U7RP6HKUZ), or a Fable ruling id (fable-ruling-YYYYMMDD-N) for a template class that ruling pre-approved."
# ---------------------------------------------------------------------------------------------
# WHO authorized this send (captain 2026-11-03: "users aren't in the dark ... no human reviews is the
# goal"). Two legal answers, and nothing else:
#   captain-slack  a human's Slack id, still only the captain's, for every campaign;
#   fable-ruling   a ruling id from policies/fable-rulings.json, accepted ONLY for the exact campaign+copy
#                  pair that ruling lists. The registry is data, so widening a class is a reviewed edit; and
#                  an unreadable registry refuses rather than opens.
# Free-form replies (intercom-ops-write.sh) are untouched: they still need a human Slack id.
APPROVER_KIND=""; APPROVAL_ID=""; TEMPLATE_SHA=""
if printf '%s' "$APPROVED_BY" | grep -qE '^U[A-Z0-9]{8,12}$'; then
  [ "$APPROVED_BY" = "$CAPTAIN_UID" ] \
    || refuse "$APPROVED_BY did not approve the verify-request campaigns. Only the captain ($CAPTAIN_UID) did, or a Fable ruling id for a class it pre-approved; any other customer message goes through intercom-ops-write.sh."
  APPROVER_KIND="captain-slack"; APPROVAL_ID="$APPROVED_BY"
elif printf '%s' "$APPROVED_BY" | grep -qE '^fable-ruling-[0-9]{4}-[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)?$'; then
  [ -r "$FABLE_RULINGS_FILE" ] \
    || refuse "--approved-by '$APPROVED_BY' is a ruling id and the registry '$FABLE_RULINGS_FILE' is not readable; refusing rather than guessing what a ruling covers."
  RULING_VERDICT="$("$JQ_BIN" -r --arg id "$APPROVED_BY" --arg camp "$CAMPAIGN" --arg copy "$COPY" '
    if (.rulings | type) != "object" then "malformed"
    elif (.rulings[$id] // null) == null then "unknown"
    else
      ((.rulings[$id].classes // {}) | if type != "object" then "malformed" else . end) as $c
      | if ($c | type) != "object" then "malformed"
        # r5 2026-11-04 finding 2: a class value must be an ARRAY of copy tokens. An OBJECT value used to be ACCEPTED
        # (`.[]` iterated its values, so {"why":"x","c":"refundconfirm"} approved refundconfirm) while a STRING value
        # was refused only by accident (`.[]` errored into the `|| malformed` fallback). Both are now explicit.
        elif ($c[$camp]? // [] | type) != "array" then "malformed"
        else
          ([$c[$camp] // [] | .[] | select(. == $copy)] | length) as $hit
          | if $hit > 0 then "approved" else "class: " + (($c | keys) | join(", ")) end
        end
    end' "$FABLE_RULINGS_FILE" 2>/dev/null || printf 'malformed')"
  case "$RULING_VERDICT" in
    approved) APPROVER_KIND="fable-ruling"; APPROVAL_ID="$APPROVED_BY" ;;
    unknown) refuse "--approved-by '$APPROVED_BY' is not in $FABLE_RULINGS_FILE. A ruling id is accepted only once a reviewed registry row names it AND the template classes it pre-approves; until then the captain's Slack id is the only approver." ;;
    malformed) refuse "$FABLE_RULINGS_FILE is malformed; refusing rather than treating an unreadable registry as approval." ;;
    class:*) refuse "--approved-by '$APPROVED_BY' pre-approves template classes ${RULING_VERDICT#class: }, not '$COPY' of campaign '$CAMPAIGN'. Every other send, and every free-form reply, still needs the captain's Slack id ($CAPTAIN_UID)." ;;
    *) refuse "$FABLE_RULINGS_FILE could not be read for '$APPROVED_BY'; refusing rather than guessing." ;;
  esac
else
  refuse "--approved-by must be a human's Slack USER ID or a Fable ruling id (fable-ruling-YYYYMMDD-N); '$APPROVED_BY' is neither. Agent identities and self-approval never authorize a message to a customer."
fi
readonly APPROVER_KIND APPROVAL_ID
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
            presented_ids: ((.user.presented_ids // []) | if type == "array" then . else [] end
                            | [.[] | select(type == "string") | clean | select(test("^[A-Za-z0-9._|-]{1,128}$"))] | unique),
            ext_other_account: (.user.ext_other_account | if type == "boolean" then . else null end),
            thread_external_id: ((.user.thread_external_id // "") | clean),
            pending_count: (.user.pending_count | if type == "number" and . == floor and . >= 0 and . <= 1000000 then . else null end),
            first_name: ((.user.first_name // "") | clean),
            filing_muso_ui: (.user.filing_muso_ui == true) },   # r5 19:2xZ: a Muso-UI filing (SYS-001) gets no R1
    # [key=apology-fact]: the ONE fact sentence this note may carry, and which variant (paid/free) it is - read from the
    # live request state by the runner, never from the list. Booleans stay booleans: a string "yes" is refused.
    apology: { fact: ((.apology.fact // "") | clean), paid: (.apology.paid | if type == "boolean" then . else null end),
               all_approved: (.apology.all_approved | if type == "boolean" then . else null end) },
    claim: ((.claim // {}) | { profile_name: ((.profile_name // "") | clean), profile_url: ((.profile_url // "") | clean),
                               code: ((.code // "") | clean), platform: ((.platform // "") | clean | ascii_downcase) }),
    merge: ((.merge // {}) | { profiles: [ (.profiles // [])[] | clean ], link_profile_id: ((.link_profile_id // "") | clean | ascii_downcase) }),
    need: ((.need // {}) | { code: ((.code // "") | clean), issuer: ((.issuer // "") | clean),
                             verify_code: ((.verify_code // "") | clean),
                             distributor: ((.distributor // "") | clean | .[0:40]), doc_sha: ((.doc_sha // "") | clean | ascii_downcase),
                             doc_received_at: ((.doc_received_at // "") | clean), doc_kind: ((.doc_kind // "") | clean),
                             doc_count: (.doc_count // 1 | if type == "number" and . >= 1 and . <= 99 and . == floor then . else 1 end),
                             doc_shas: ([(.doc_shas // [])[]? | strings | select(test("^[0-9a-f]{64}$"))] | unique | .[0:20]),
                             doc_map: ((.doc_map // {}) | if type == "object" then with_entries(select((.key | test("^[A-Za-z0-9-]{1,64}$")) and ((.value | type) == "string") and (.value | test("^[0-9a-f]{64}$")))) else {} end),
                             doc_intakes: ((.doc_intakes // {}) | if type == "object" then with_entries(select((.key | test("^[0-9a-f]{64}$")) and ((.value | type) == "string") and (.value | test("^[A-Za-z0-9:._-]{1,80}$")))) else {} end) }),
    refund: ((.refund // {}) | { refund_id: ((.refund_id // "") | clean), amount: ((.amount // "") | clean),
                               currency: ((.currency // "") | clean | ascii_downcase), issued_on: ((.issued_on // "") | clean),
                               card_last4: ((.card_last4 // "") | clean),
                               subscription_state: ((.subscription_state // "") | clean | ascii_downcase),
                               # d2 2026-11-04: the cancel-at-period-end sentence needs the date access runs to, and it
                               # is a Stripe fact (current_period_end), never a typed date.
                               active_until: ((.active_until // "") | clean) }),
    credits: [ .credits[] | { request_id: ((.request_id // "") | clean), role: ((.role // "") | clean),
                              track_title: ((.track_title // "") | clean), artist_name: ((.artist_name // "") | clean),
                              role_families: ([(.role_families // [])[] | clean] | if length == 0 then ["other"] else . end),
                              reason: ((.reason // "") | clean | ascii_downcase), evidence_url: ((.evidence_url // "") | clean),
                              source_label: ((.source_label // "") | clean), policy_reason: ((.policy_reason // "") | clean | ascii_downcase),
                              received: ((.received // "") | clean | ascii_downcase),
                              other_names: [(.other_names // [])[] | clean | select(length > 0)],
                              evidence_source: ((.evidence_source // "") | clean),
                              corroboration_url: ((.corroboration_url // "") | clean),
                              profile_id: ((.profile_id // "") | clean), track_id: ((.track_id // "") | clean),
                              ask_class: ((.ask_class // "") | clean | ascii_downcase | .[0:32]),
                              is_approved: ((.is_approved // "") | clean | ascii_downcase | .[0:8]),
                              need: ((.need // "") | clean | ascii_downcase | .[0:48]),
                              review_family: ((.review_family // "") | tostring | if test("^[0-9]{1,12}$") then . else "" end) } ] }' "$CREDITS_FILE")"

INPUT_FILING_CONV="$("$JQ_BIN" -r '(.user.filing_conversation // "") | tostring' "$CREDITS_FILE" 2>/dev/null || true)"
# R1 is delivered INTO the filing conversation (p1's batch-1 signature: the thread comm_state's R5-R7 and G3 judged),
# never into whichever conversation the 14-day auto-pick would choose and never by email instead. The dry run
# renders it in-thread too. A filing thread that cannot carry it is a hold (below), not a fallback.
# R9 (proof-loop p1 165, Fable 166): a thread we deliver INTO must be about credits / claims / merges - by its ticket
# type, title/subject, the customer's opening message, or one of its last 3 human parts. A refund, billing or analytics
# thread is never used for a credit note: the note goes by email instead (a reply opens a conversation the intake
# files). "credit card" / "credit note" are billing words, not credit words. Reads a conversation JSON on stdin.
TOPIC_STRONG='\\b(song|track) ?credits?\\b|\\bcredit (request|verification|review|claim)s?\\b|split ?sheets?|\\bmerg(e|es|ed|ing)( (my|the|these|those|our|two|both|duplicate|muso|artist))* (profiles?|accounts?|pages?|duplicates?)\\b|\\b(profiles?|accounts?|pages?) (merged|merging|merge)\\b|\\bduplicate (profiles?|accounts?|artist pages?)\\b|\\b(profile|artist|page) claims?\\b|\\bclaim(s|ed|ing)? (my |the |this |a |an |our )?(muso )?(profile|artist|page)s?\\b|\\bproof of (my |the |our |this )?(credits?|role|work|contribution|authorship|ownership)\\b'
TOPIC_BILLING='\\b(refund\\w*|charge[sd]?|chargeback|invoice\\w*|billing|billed|payment\\w*|subscription\\w*|paypal|card)\\b'
thread_on_topic() {
  "$JQ_BIN" -e '
    def human: ((.author.type // "") | IN("user", "lead", "contact", "admin")) and ((.part_type // "comment") != "note");
    def words: ascii_downcase | gsub("credit[ -]?cards?|credit notes?|store credit"; " ");
    # QA #1418: the ticket type in any shape (an object with a name, a bare string, or nothing), like comm_state
    # ticket_type_name - a string must never make this filter throw (no quotes in this comment: jq program)
    def ttype: (.ticket | if type == "object" then (.ticket_type | if type == "object" then (.name // "")
                elif type == "string" then . else "" end) else "" end);
    ([ ttype, (.title // ""), (.source.subject // ""), (.source.body // "") ]
     + ([ (.conversation_parts.conversation_parts // [])[] | select(human) | select(((.body // "") | length) > 0) ]
        | .[-3:] | map(.body)))
    | map(tostring | words) | join(" \n ")
    # QA #1418: the same STRONG / weak / billing patterns and rule as comm_state.on_topic (test-pinned): billing vetoes all
    | (test("'"$TOPIC_BILLING"'") | not) and (test("'"$TOPIC_STRONG"'") or test("\\bcredits?\\b"))' \
    >/dev/null 2>&1
}
R9_EXEMPT=0
case "$CAMPAIGN" in email-changed|email-changed-dup|withdrawal-confirm) R9_EXEMPT=1 ;; esac
# r5 (R1 only): when the filing thread fails R9, the receipt goes into the user's OTHER open credit/claim/merge
# conversation (exactly this contact, on topic, updated in the last 30 days, newest first), judged by the same
# thread_check / comm_state as the filing thread; only when there is none does it go by email. Prints the id or
# nothing; exit 1 = the lookup could not be verified (nothing sent).
credit_thread_of() { # <contact_id> <exclude_conversation>
  local since res ids id c
  since=$(( $(g1_now) - 30*86400 ))
  res="$(printf '%s' "$1" | "$JQ_BIN" -Rc --argjson since "$since" \
    '{query: {operator: "AND", value: [{field: "contact_ids", operator: "=", value: .}, {field: "state", operator: "=", value: "open"}, {field: "updated_at", operator: ">", value: $since}]}, pagination: {per_page: 20}}' \
    | api POST /conversations/search)" || return 1
  printf '%s' "$res" | "$JQ_BIN" -e '(.conversations|type) == "array"' >/dev/null 2>&1 || return 1
  ids="$(printf '%s' "$res" | "$JQ_BIN" -r --arg x "$2" --argjson since "$since" \
    '[.conversations[] | select((.state // "") == "open" and ((.updated_at // 0) > $since) and ((.id // "") | tostring) != $x)]
     | sort_by(.updated_at) | reverse | .[0:10][] | (.id | tostring)')"
  for id in $ids; do
    printf '%s' "$id" | grep -qE '^[0-9]{1,24}$' || return 1
    c="$(api GET "/conversations/$id?display_as=plaintext")" || return 1
    printf '%s' "$c" | "$JQ_BIN" -e --arg t "$id" --arg me "$1" '(.type // "") == "conversation" and ((.id // "") | tostring) == $t
        and ([(.contacts.contacts // [])[] | (.id // "") | tostring] == [$me])' >/dev/null 2>&1 || continue
    printf '%s' "$c" | thread_on_topic || continue
    printf '%s' "$id"; return 0
  done
  return 0
}
R1_THREAD=0
R1LIKE=0; case "$COPY" in docrecvr|docrecvn) R1LIKE=1 ;; esac   # /i takes R1's thread rules (r5 10-30 §i)
# r5 HOLD 10-30 19:0xZ (3 paid R1), two thread rules on the conversation as read (plaintext):
# WAITING_JQ -> the created_at of our last admin/bot COMMENT when it asks the customer a question ("?") and no customer
#   comment came after it: the thread is waiting on the customer, and no automated line of any class goes into it (a
#   human/Caroline follow-up (any class, reminders included: r5 "no automated line of any class goes there").
# RECEIPTED_JQ -> the created_at of the latest admin/bot comment AFTER the customer's latest filing part (a customer part
#   with an attachment; else the opener): we already acknowledged the document in free text (the un-ledgered #1510
#   class), so the R1 receipt would repeat it - skip until the backfill ledgers those lines.
# shellcheck disable=SC2016
THREAD_JQ_DEFS='def cust: (.author.type // "") | IN("user", "lead", "contact");
  def ours: (.author.type // "") | IN("admin", "bot");
  def said: (.part_type // "") == "comment" and ((.body // "") | gsub("\\s"; "") | length) > 0;
  def spoke: (.part_type // "comment") != "note" and ((((.body // "") | gsub("\\s"; "") | length) > 0)
             or (((.attachments // []) | length) > 0));
  def parts: [ (.conversation_parts.conversation_parts // [])[] ];'
# shellcheck disable=SC2016
WAITING_JQ="$THREAD_JQ_DEFS"'
  [ parts[] | select((ours and said) or (cust and spoke)) ] | sort_by(.created_at // 0) | last
  | if . != null and ours and ((.body // "") | test("\\?|\\b(could|can) you\\b|\\bplease (send|share)\\b"; "i"))
    then (.created_at // 0 | tostring) else empty end'
# shellcheck disable=SC2016
RECEIPTED_JQ="$THREAD_JQ_DEFS"'
  ([ (.source // {}) | select(cust and ((.attachments // []) | length) > 0) | 0 ]
   + [ parts[] | select(cust and ((.attachments // []) | length) > 0) | (.created_at // 0) ] | max) as $f
  | ($f // 0) as $f
  | [ parts[] | select(said and ours) | select((.created_at // 0) > $f) | (.created_at // 0) ] | max // empty | tostring'
# [key=r1-filing-thread] (r5 10-30 13:3xZ, firstmate 283): the R1 receipt goes INTO the filing thread even when WE
# opened it - a NARROW exemption from G2's opener rule only, never an email detour. All required: the R1 filing-thread
# path (status-doc-received, --conversation == user.filing_conversation); EVERY named request has a proof_intake row
# of this user filed IN this conversation (never any other thread we opened); the customer's filing part, with its
# attachment, is in the thread. G2's single-contact / account-user checks, R1 once-ever and the ledger claim are
# unchanged. $1 = the conversation JSON. 0 = exempt.
r1_filing_thread_ok() {
  [ "$CAMPAIGN" = "status-doc-received" ] && [ "$R1_THREAD" = "1" ] && [ -n "$THREAD" ] && [ "$THREAD" = "$INPUT_FILING_CONV" ] || return 1
  printf '%s' "$1" | "$JQ_BIN" -e '[.source, ((.conversation_parts.conversation_parts // [])[])]
      | any(.[]; ((.author.type // "") | IN("user", "lead", "contact")) and (((.attachments // []) | length) > 0))' >/dev/null 2>&1 || return 1
  "$PY_BIN" -I - "$PROOF_DB" "$USER_ID" "$THREAD" "$ALL_IDS" <<'PY' >/dev/null 2>&1
import json, re, sqlite3, sys
db_path, uid, conv, ids = sys.argv[1], sys.argv[2], sys.argv[3], [i.strip().lower() for i in sys.argv[4].split(",") if i.strip()]
if not re.fullmatch(r"[0-9]{1,12}", uid) or not ids:
    sys.exit(1)
db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
filed = set()
for (cj,) in db.execute("SELECT coalesce(candidate_request_ids_json, '[]') FROM proof_intake WHERE user_id=? AND conversation_id=?",
                        (int(uid), conv)):
    try:
        filed |= {str(x).strip().lower() for x in json.loads(cj or "[]")}
    except ValueError:
        continue
sys.exit(0 if all(i in filed for i in ids) else 1)
PY
}

# QA #1460: an explicit --conversation for R1 must BE the filing conversation (the one G3 and comm_state judge).
# r5 10-30 19:2xZ: an R1 receipts a document of record only - a filing read as a screenshot of Muso itself (doc-verify
# SYS-001) is never receipted (L13 is retired from R1; that user's next message is the ask, not a receipt)
if [ "$R1LIKE" = "1" ] && [ "$("$JQ_BIN" -r '.user.filing_muso_ui == true' "$CREDITS_FILE" 2>/dev/null)" != "false" ]; then
  refuse "R1: the filing was read as a screenshot of Muso itself (user.filing_muso_ui); a receipt goes only for a document of record. Nothing was sent or claimed."
fi
# r5 [key=r1-no-readable-text] (doc-verify 774): a filing the reader deterministically found NO readable text in (cover
# art, a bare PNG, a WAV) is not a document of record - no R1 (it is the readable-document ask class, copy unapproved).
# Its own first-hit reason, before r1_filing_class_unknown, so the facts tell the two apart.
if [ "$R1LIKE" = "1" ] && [ "$("$JQ_BIN" -r '.user.filing_unreadable == true' "$CREDITS_FILE" 2>/dev/null)" != "false" ]; then
  refuse "r1_unreadable_filing: the filing has no readable text (the doc reader found none); an R1 receipt goes only for a document of record. Nothing was sent or claimed."
fi
# r5 / QA #1554: the R1 receipt itself needs the filing's class STATED - user.filing_muso_ui explicitly false. A payload
# without it (no producer sets it yet) is r1_filing_class_unknown: refused, never a receipt by default.
# fable-copy-1101-r5/r1-roles retires r1_number_uncoded: the R1 renderer numbers by distinct (track, role) pairs itself.
if [ "$COPY" = "docrecvr" ] && [ "$("$JQ_BIN" -r '.user | has("filing_muso_ui") and .filing_muso_ui == false' "$CREDITS_FILE" 2>/dev/null)" != "true" ]; then
  refuse "r1_filing_class_unknown: the R1 payload does not state the filing's class (user.filing_muso_ui must be false); nothing was sent or claimed."
fi
if { [ "$R1LIKE" = "1" ] || [ "$COPY" = "proofneed" ]; } && [ -n "$THREAD" ] && [ "$THREAD" != "$INPUT_FILING_CONV" ]; then
  refuse "R1 / the per-need ask goes only into the filing conversation ($INPUT_FILING_CONV); --conversation $THREAD is another thread. Nothing was sent or claimed."
fi
if { [ "$R1LIKE" = "1" ] || [ "$COPY" = "proofneed" ]; } && printf '%s' "$INPUT_FILING_CONV" | grep -qE '^[0-9]{1,24}$' \
   && { [ -z "$THREAD" ] || [ "$THREAD" = "$INPUT_FILING_CONV" ]; }; then
  # QA #1532: an explicit --conversation that IS the filing conversation (e.g. a reply_due answer) is the same path
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
if [ "$GMO" = 1 ]; then
  # [key=gmail-o-forward] the gate's OWN read of the frozen did-vouch set (claim_holds, the #1579 predicate): /o goes only
  # to a member, and only while cs-gmail is stale - a fresh Gmail scan retires /o (the stop rule); unreadable = refuse
  if [ "$TESTABLE" = "1" ] && [ -n "${INTERCOM_VERIFY_TEST_GMO:-}" ]; then
    gmo="$INTERCOM_VERIFY_TEST_GMO"
  else
    gmo="$("$PY_BIN" -I -c 'import sys; sys.path.insert(0, sys.argv[1])
from credit_review import claim_proof_ask
h = claim_proof_ask.claim_holds()
print("fresh" if not h.scoped else ("held" if sys.argv[2] in h.held else "not_held"))' "$(dirname "$(dirname "$COMM_STATE_HELPER")")" "$USER_ID" 2>/dev/null || echo unreadable)"
  fi
  case "$gmo" in
    held) APPROVAL_REF_SUFFIX_O="; gmail-fallback $GMAIL_FALLBACK_O_REF" ;;
    fresh) refuse "/o is retired: cs-gmail reads fresh again, so the real Gmail scan runs first (the stop rule). Nothing was sent or claimed." ;;
    not_held) refuse "/o goes only to the frozen did-vouch set; user $USER_ID is not in it. Nothing was sent or claimed." ;;
    *) refuse "/o: the did-vouch set could not be read ($gmo); nothing was sent or claimed." ;;
  esac
fi
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
# r5 (Fable [key=x2-sample-1027]): the account's PRESENTED profile ids (its processed claims and
# representation profile, each owned by exactly this account; credit_review.identity_resolver). The
# mobile app logs into Intercom with the presented profile (core /v4/user B2), the web app with the
# professional id, so one account can have two Intercom users. Only ever widens THIS account's own
# contacts; the driver computes it on the replica, the gate never guesses it.
PRESENTED_JSON="$(printf '%s' "$INPUT" | "$JQ_BIN" -c '.user.presented_ids')"
# No silent truncation (QA @4e23bc6b): every id the driver resolved is honoured. An implausible count is a
# loud refusal for a person, never a quiet partial match (the replica gives an account a handful at most).
readonly MAX_PRESENTED_IDS=500
[ "$(printf '%s' "$PRESENTED_JSON" | "$JQ_BIN" -r 'length')" -le "$MAX_PRESENTED_IDS" ] \
  || refuse "user.presented_ids has more than $MAX_PRESENTED_IDS ids; refusing rather than matching a subset."
EXT_OTHER="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '.user.ext_other_account | if . == null then "" else tostring end')"
THREAD_EXT="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '.user.thread_external_id')"
# An Intercom contact's external_id names THIS account when it is the account's
# professional id (users.neptuneProfessionalId, what the web app boots Intercom with;
# firstmate 090), its Auth0 subject (with or without its auth0| prefix), or one of its
# presented profile ids (r5: what the mobile app logs in with). Anything else, including the
# bare numeric user id, is another account.
ext_is_canonical() {
  [ -n "$1" ] || return 1
  { [ -n "$PRO_ID" ] && [ "$1" = "$PRO_ID" ]; } \
    || { [ -n "$AUTH_ID" ] && { [ "$1" = "$AUTH_ID" ] || [ "$1" = "auth0|$AUTH_ID" ]; }; }
}
ext_is_account() {
  [ -n "$1" ] || return 1
  ext_is_canonical "$1" && return 0
  [ -n "$PRO_ID$AUTH_ID" ] || return 1   # presented ids only ever widen an account that is named
  printf '%s' "$PRESENTED_JSON" | "$JQ_BIN" -e --arg x "$1" 'any(.[]; . == $x)' >/dev/null 2>&1
}
readonly NO_EXT_ID_WHY="the Intercom user for this email has no external_id, so it cannot be matched to this Muso account; not sending."
N="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '.credits | length')"
[ "$N" -ge 1 ] || refuse "credits is empty; there is nothing to ask the user to verify."
[ "$N" -le "$MAX_CREDITS" ] || refuse "credits has $N entries; at most $MAX_CREDITS per $CAMPAIGN note."
case "$CAMPAIGN" in
  reply-ref)
    # the ONE entry is the reply's key: the decided request for /y (comm_state reads it), else any key for this part
    printf '%s' "$INPUT" | "$JQ_BIN" -e '.credits[0].request_id | test("^[A-Za-z0-9-]{1,64}$")' >/dev/null \
      || refuse "reply-ref needs one entry whose request_id is the reply's key (the decided request for /y)."
    INPUT="$(printf '%s' "$INPUT" | "$JQ_BIN" -c '.credits[0] += {role: "-", track_title: "-", artist_name: "-"}')" ;;
  refund-confirm)
    # The facts ARE the message (firstmate 109: "every placeholder from Stripe/core, never typed by hand"), so a refund
    # note exists only when Stripe's own refund object is present and self-consistent. jq -e fails closed on a missing key.
    # The entry's request id IS the Stripe refund id (re_...): one note per REFUND, ever, and the ledger only ever treats
    # it as an opaque key (which is why the shared shape check below admits the underscore Stripe puts in every id).
    printf '%s' "$INPUT" | "$JQ_BIN" -e '
      (.credits[0].request_id | test("^re_[A-Za-z0-9]{8,64}$"))
      and (.refund.refund_id == .credits[0].request_id)
      # the amount is stated in MAJOR units, in the currency of the refund: 12.50 usd, 500 jpy, 1.234 kwd. The shape
      # accepts 0-3 decimals and the processor binding then refuses anything that is not the canonical form for that
      # currency (refund-money.jq), so a "5.00" for a 500 JPY refund can never reach a customer.
      and (.refund.amount | test("^[0-9]{1,9}(\\.[0-9]{1,3})?$"))
      and (.refund.currency | test("^[a-z]{3}$"))
      and (.refund.issued_on | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
      and (.refund.card_last4 | test("^[0-9]{4}$"))
      and (.refund.subscription_state | IN("cancelled", "active", "cancel_at_period_end"))
      and (if .refund.subscription_state == "cancel_at_period_end"
           then (.refund.active_until | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) else true end)' >/dev/null \
      || refuse "refund-confirm needs the refund facts in the credits file: refund_id (equal to the entry's request_id), amount as a decimal (12.50), currency, issued_on (YYYY-MM-DD), card_last4 (four digits) and subscription_state (cancelled, active, or cancel_at_period_end with active_until). Nothing was sent or claimed."
    # QA 2026-11-04 finding 1: the shape is only the SHAPE. Every fact is then read from the processor and compared; a
    # file that disagrees with Stripe is refused by name, and the render uses Stripe's values, never the file's.
    # every path that can render or send binds to the processor; only --validate (shape only) does not
    case "$ACTION" in
      validate) ;;
      *) INPUT="$(bind_refund_to_processor "$INPUT")" ;;
    esac
    INPUT="$(printf '%s' "$INPUT" | "$JQ_BIN" -c '.credits[0] += {role: "-", track_title: "-", artist_name: "-"}') "
    INPUT="${INPUT% }" ;;
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
  merge-claim-first)
    printf '%s' "$INPUT" | "$JQ_BIN" -e '.user.id | test("^[0-9]{1,12}$")' >/dev/null \
      || refuse "merge-claim-first needs user.id, the requester's Muso account id."
    printf '%s' "$INPUT" | "$JQ_BIN" -e '.credits[0].request_id == ("mcf-" + .user.id)' >/dev/null \
      || refuse "merge-claim-first needs one entry whose request_id is mcf-<user.id> (one ask per user, ever)."
    printf '%s' "$INPUT" | "$JQ_BIN" -e '.merge.link_profile_id | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")' >/dev/null \
      || refuse "merge.link_profile_id must be the linked profile's catalog uuid."
    case " $MERGE_CLAIM_FIRST_USERS " in
      *" $(printf '%s' "$INPUT" | "$JQ_BIN" -r '.user.id') "*) ;;
      *) refuse "merge-claim-first goes only to r5's signed set (MERGE_CLAIM_FIRST_USERS); adding an account is a PR." ;;
    esac
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
if [ "$CAMPAIGN" = "decline" ]; then
  # The decline follows the FILE's shape, never the caller's word: a claim-shaped entry (claim-<claiming.id>, the same
  # key the claim lane already uses) gets the profile-claim sentence, a credit-shaped entry (a real request id) gets the
  # credit sentence with its list. One message is one shape.
  nclaim="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '[.credits[] | select(.request_id | test("^claim-[0-9]{1,19}$"))] | length')"
  nreal="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '[.credits[] | select((.request_id | test("^claim-[0-9]{1,19}$")) | not)] | length')"
  [ "$nclaim" -eq 0 ] || [ "$nreal" -eq 0 ] \
    || refuse "the decline's credits mix claim keys (claim-<id>) and request ids; one message is one shape. Split them."
  # A reason is INTERNAL (captain 2026-10-29 13:2xZ; decline-copy-ruling.md item 1: no reason, no list of what was
  # missing or wrong). It rides on the decider's row and the audit file; a payload that carries one toward the copy is
  # refused here, so "the template receives only {n} and {profile}" is enforced, not promised.
  wreason="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '[.credits[] | select((((.reason // "") | length) > 0) or (((.received // "") | length) > 0) or (((.rejected_reason // "") | length) > 0))] | length')"
  [ "$wreason" -eq 0 ] || refuse "$wreason credit(s) carry a reason/received field. A decline never states a reason: the reviewer's code stays on the decider's row and in the audit file, never in a payload that renders copy. Remove it."
  if [ "$nclaim" -gt 0 ]; then
    [ "$N" -eq 1 ] || refuse "a profile-claim decline is one claim per message (got $N)."
    printf '%s' "$INPUT" | "$JQ_BIN" -e '.credits[0].profile_id | length > 0' >/dev/null \
      || refuse "the claim decline needs the entry's profile_id, the declined claim's profile id."
    DECLINE_CLAIM=1
    INPUT="$(printf '%s' "$INPUT" | "$JQ_BIN" -c '.credits[0] += {role: "-", track_title: "-", artist_name: "-"}')"
  fi
fi
if [ "$COPY" = "teamreviewcount" ]; then
  # The count-only note shows no title, artist or role (they may be blank or unshowable: that is
  # why it is sent): placeholders for the shape checks; a malformed profile/track ref is dropped.
  INPUT="$(printf '%s' "$INPUT" | "$JQ_BIN" -c '.credits |= map(. + {role: "-", track_title: "-", artist_name: "-"}
    | (if (.profile_id | test("^[A-Za-z0-9-]{0,64}$")) then . else .profile_id = "" end)
    | (if (.track_id | test("^[A-Za-z0-9-]{0,64}$")) then . else .track_id = "" end))
    | .user.pending_count = ([(.user.pending_count // 0), (.credits | length)] | max)')"
fi
bad="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '[.credits[] | select((.request_id | test("^[A-Za-z0-9_-]{1,64}$") | not)
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
if [ "$CAMPAIGN" = "proof-need-ask" ]; then
  # The need comes from b1's tray (the reader's need code); the issuer is a document-derived NAME, so it is held
  # to a plain-name shape (no links, no addresses, no markup): anything else refuses the note, never renders it.
  printf '%s' "$USER_ID" | grep -qE '^[0-9]{1,12}$' || refuse "proof-need-ask needs user.id, the Muso account id."
  NEED_CODE="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '.need.code')"
  case "$NEED_CODE" in
    readable_document|counterparty_signed_or_registered) ;;
    issuer_email_from_official_domain)
      printf '%s' "$INPUT" | "$JQ_BIN" -e ".need.issuer | test(\"^[A-Za-z0-9][A-Za-z0-9 &.,'-]{0,79}\$\") and (test(\"[.][A-Za-z]{2,}(\$| )\") | not)" >/dev/null \
        || refuse "proof-need-ask issuer_email_from_official_domain needs need.issuer: the issuer's plain name (letters, digits, space, & . , ' -; at most 80 characters; never a domain or address)." ;;
    distributor_dashboard_with_code)
      printf '%s' "$INPUT" | "$JQ_BIN" -e '.need.verify_code | test("^[A-Z0-9][A-Z0-9-]{3,31}$")' >/dev/null \
        || refuse "proof-need-ask distributor_dashboard_with_code needs need.verify_code: the 7-day code we issued (4 to 32 capital letters, digits or dashes)." ;;
    *) refuse "proof-need-ask needs need.code: readable_document, issuer_email_from_official_domain, distributor_dashboard_with_code or counterparty_signed_or_registered (got '$NEED_CODE')." ;;
  esac
  # The document the reader checked (p1 ruling 096): its sha, when it arrived, and its kind, so the ask names it and
  # comm_state can tell whether anything newer came in after it.
  printf '%s' "$INPUT" | "$JQ_BIN" -e '.need.doc_sha | test("^[0-9a-f]{64}$")' >/dev/null \
    || refuse "proof-need-ask needs need.doc_sha: the sha256 of the document the reader checked (dv_outcomes.proof_id)."
  printf '%s' "$INPUT" | "$JQ_BIN" -e '.need.doc_received_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and ((. | fromdateiso8601 | todate) == .)' >/dev/null \
    || refuse "proof-need-ask needs need.doc_received_at: when the document arrived (proof_intake.received_at, YYYY-MM-DDTHH:MM:SSZ)."
  printf '%s' "$INPUT" | "$JQ_BIN" -e '.need.doc_kind | IN("image", "PDF", "document")' >/dev/null \
    || refuse "proof-need-ask needs need.doc_kind: image, PDF or document (from proof_intake.mime)."
  # QA #1418 (08:36Z): the group the copy names must be EXACTLY the documents the send checks and locks - the RAW
  # payload's doc_shas are need.doc_count distinct sha256s, at most MAX_DOC_GROUP of them; never silently truncated
  # (a group of 21 would name 21 and check 20) and never a count clamped to 1 ("the file" for many)
  "$JQ_BIN" -e --argjson max "$MAX_DOC_GROUP" '.need as $n | ($n.doc_shas | type == "array") and ($n.doc_count | type == "number")
      and ([$n.doc_shas[] | select(type == "string" and test("^[0-9a-f]{64}$"))] | unique | length) as $k
      | $k == ($n.doc_shas | length) and $k == $n.doc_count and $k >= 1 and $k <= $max' "$CREDITS_FILE" >/dev/null \
    || refuse "need_doc_group_mismatch: need.doc_shas must be exactly need.doc_count distinct sha256s (1 to $MAX_DOC_GROUP); the ask would name documents it does not check. Nothing was sent or claimed."
fi
if [ "$CAMPAIGN" = "credit-approved-elsewhere" ]; then
  printf '%s' "$USER_ID" | grep -qE '^[0-9]{1,12}$' || refuse "credit-approved-elsewhere needs user.id, the Muso account id."
  # The role is the overlap the conflict rule read. An unread overlap is null upstream and must stay silent here:
  # a credit that names no role is refused, never rendered with a blank or with the request's own role list.
  norole="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '[.credits[] | select([(.role // "") | split(",")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0)] | length == 0)] | length')"
  [ "$norole" -eq 0 ] || refuse "credit-approved-elsewhere: $norole credit(s) name no role. The line names only the roles the conflict rule read as shared; an unread role is never guessed. Nothing was sent or claimed."
  notreq="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '[.credits[] | select(.request_id | test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$") | not)] | length')"
  [ "$notreq" -eq 0 ] || refuse "credit-approved-elsewhere: $notreq credit(s) carry an id that is not a credit request id. Nothing was sent or claimed."
fi
if [ "$CAMPAIGN" = "proof-refusal" ]; then
  printf '%s' "$USER_ID" | grep -qE '^[0-9]{1,12}$' || refuse "proof-refusal needs user.id, the Muso account id."
  notreq="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '[.credits[] | select(.request_id | test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$") | not)] | length')"
  [ "$notreq" -eq 0 ] || refuse "proof-refusal: $notreq credit(s) carry an id that is not a credit request id. Nothing was sent or claimed."
  # Only the three approved pairs render. The need is the one the reader recorded for the request, never one a table
  # assigns to the reason: a pair with no body refuses the WHOLE note, so no track is ever told the wrong evidence.
  uncoded="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '[.credits[] | select(
      ((.reason == "doesnt_name_you" or .reason == "other_track") and .need == "counterparty_signed_or_registered")
      or (.reason == "unreadable" and .need == "readable_document") | not)] | length')"
  [ "$uncoded" -eq 0 ] || refuse "refusal_uncoded: $uncoded credit(s) carry a reason and need with no approved body (the bodies are doesnt_name_you or other_track with counterparty_signed_or_registered, and unreadable with readable_document). Nothing was sent or claimed."
  noreview="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '[.credits[] | select(.review_family == "")] | length')"
  [ "$noreview" -eq 0 ] || refuse "proof-refusal: $noreview credit(s) name no review row (review_family, the family of the verify_proof_reviews row this note answers). Nothing was sent or claimed."
  norole="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '[.credits[] | select(.reason == "doesnt_name_you") | select([(.role // "") | split(",")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0)] | length == 0)] | length')"
  [ "$norole" -eq 0 ] || refuse "proof-refusal: $norole credit(s) name no role, and that body names the role the document did not show. Nothing was sent or claimed."
fi
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
if { [ "$LIVE" = "1" ] || [ "$ACTION" = "validate" ]; } && [ "$CAMPAIGN" = "takeback-notice" ] && [ "$TAKEBACK_COPY_APPROVED" != "1" ]; then
  refuse "the takeback-notice copy is not approved for sending yet (TAKEBACK_COPY_APPROVED=0). It needs Fable's copy GO and the captain's approval, landed in a PR that flips the lock; --dry-run renders it."
fi
if [ "$LIVE" = "1" ] && [ "$CAMPAIGN" = "removal-notice" ] && [ "$REMOVAL_COPY_APPROVED" != "1" ]; then
  refuse "the removal-notice copy is not approved for sending yet (REMOVAL_COPY_APPROVED=0). It needs Fable's copy GO, landed in a PR that flips the lock, and firstmate's approval of the backfill list; --dry-run renders exactly what would be sent."
fi
if [ "$LIVE" = "1" ] && [ "$CAMPAIGN" = "withdrawal-confirm" ] && [ "$WITHDRAWAL_COPY_APPROVED" != "1" ]; then
  refuse "the withdrawal-confirm copy is not approved for sending (WITHDRAWAL_COPY_APPROVED=0)."
fi
if [ "$LIVE" = "1" ] && { [ "$CAMPAIGN" = "status-doc-received" ] || [ "$CAMPAIGN" = "status-team-review" ]; } && [ "$STATUS_NOTES_COPY_APPROVED" != "1" ]; then
  refuse "the status-note copy is not approved for sending (STATUS_NOTES_COPY_APPROVED=0)."
fi
if [ "$LIVE" = "1" ] && [ "$COPY" = "docrecvr" ] && [ "$STATUS_RECEIVED_COPY_APPROVED" != "1" ]; then
  refuse "the receipt line R1 (status-doc-received --copy received) is not approved for sending yet (STATUS_RECEIVED_COPY_APPROVED=0). It waits for the captain's yes, landed in a PR that flips the lock; --dry-run renders exactly what would be sent."
fi
if [ "$LIVE" = "1" ] && { [ "$CAMPAIGN" = "email-changed" ] || [ "$CAMPAIGN" = "email-changed-dup" ]; } && [ "$EMAIL_CHANGE_COPY_APPROVED" != "1" ]; then
  refuse "the email-changed copy is not approved for sending (EMAIL_CHANGE_COPY_APPROVED=0)."
fi
if [ "$LIVE" = "1" ] && [ "$CAMPAIGN" = "claim-proof-ask" ] && [ "$CLAIM_PROOF_ASK_COPY_APPROVED" != "1" ]; then
  refuse "the claim-proof-ask copy is not approved for sending yet (CLAIM_PROOF_ASK_COPY_APPROVED=0). It needs Fable's copy approval and firstmate's GO, landed in a PR that flips the lock; --dry-run renders exactly what would be sent."
fi
if [ "$LIVE" = "1" ] && [ "$CAMPAIGN" = "claim-status" ] && [ "$CLAIM_STATUS_COPY_APPROVED" != "1" ]; then
  refuse "the claim-status copy is not approved for sending yet (CLAIM_STATUS_COPY_APPROVED=0). Fable approved the text; it waits for firstmate's GO after the 5-user dry run, landed in a PR that flips the lock; --dry-run renders exactly what would be sent."
fi
if [ "$LIVE" = "1" ] && [ "$ACTION" = "post" ] && [ "$CAMPAIGN" = "uvn-new-rows" ] && [ "$UVN_NEW_ROWS_COPY_APPROVED" != "1" ]; then
  refuse "uvn-new-rows is send-locked (UVN_NEW_ROWS_COPY_APPROVED=0); --dry-run / --check-recipient only. Nothing was sent or claimed."
fi
if [ "$LIVE" = "1" ] && [ "$CAMPAIGN" = "uvn-status" ] && [ "$UVN_STATUS_COPY_APPROVED" != "1" ]; then
  refuse "the uvn-status copy is not approved for sending (UVN_STATUS_COPY_APPROVED=0)."
fi
if [ "$LIVE" = "1" ] && [ "$CAMPAIGN" = "gap-ask" ] && [ "$GAP_ASK_COPY_APPROVED" != "1" ]; then
  refuse "the gap-ask copy is not approved for sending (GAP_ASK_COPY_APPROVED=0)."
fi
if [ "$LIVE" = "1" ] && [ "$CAMPAIGN" = "decline" ] && [ "$DECLINE_CORE_ROUTE_OFF" != "1" ]; then
  refuse "hydra's decline is silent on purpose: core's own credits_rejected email is the decline and carries the same approved text, and only one of the two may speak. This campaign activates only for a user whose core route is measured OFF (credit_review/decline_close.py). Nothing was sent or claimed; --dry-run renders exactly what would be sent."
fi
# Per-campaign kill switch (rulings-1028-1430 section 2.4): `touch /etc/hydra/<campaign>.disabled` stops every real
# send of that campaign at once, before any claim or Intercom call; the dry run still renders. Removing the file
# resumes it. Exit 3: nothing is claimed, refused or closed.
if [ "$LIVE" = "1" ] && [ -e "$DISABLED_DIR/$CAMPAIGN.disabled" ]; then
  printf 'STOPPED %s is disabled (%s present); nothing was sent or claimed\n' "$CAMPAIGN" "$DISABLED_DIR/$CAMPAIGN.disabled"; exit 3
fi
if [ "$LIVE" = "1" ] && [ "$CAMPAIGN" = "merge-pending" ] && [ "$MERGE_PENDING_COPY_APPROVED" != "1" ]; then
  refuse "the merge-pending copy is not approved for sending yet (MERGE_PENDING_COPY_APPROVED=0). It waits for the captain's own yes on line M1, landed in a PR that flips the lock; --dry-run renders exactly what would be sent."
fi
if [ "$LIVE" = "1" ] && [ "$CAMPAIGN" = "merge-claim-first" ] && [ "$MERGE_CLAIM_FIRST_COPY_APPROVED" != "1" ]; then
  refuse "the merge-claim-first copy is not approved for sending (MERGE_CLAIM_FIRST_COPY_APPROVED=0)."
fi
if [ "$LIVE" = "1" ] && [ "$CAMPAIGN" = "credit-hold-status" ] && [ "$CREDIT_HOLD_STATUS_COPY_APPROVED" != "1" ]; then
  refuse "the credit-hold-status copy is not approved for sending yet (CREDIT_HOLD_STATUS_COPY_APPROVED=0). It waits for the captain's yes on L14a, landed in a PR that flips the lock; --dry-run renders exactly what would be sent."
fi
if [ "$LIVE" = "1" ] && [ "$CAMPAIGN" = "claim-proof-pending" ] && [ "$CLAIM_PROOF_PENDING_COPY_APPROVED" != "1" ]; then
  refuse "the claim-proof-pending copy is not approved for sending yet (CLAIM_PROOF_PENDING_COPY_APPROVED=0). It waits for the captain's yes on L14b, landed in a PR that flips the lock; --dry-run renders exactly what would be sent."
fi
if [ "$LIVE" = "1" ] && [ "$CAMPAIGN" = "proof-need-ask" ] && [ "$PROOF_NEED_ASK_COPY_APPROVED" != "1" ]; then
  refuse "the proof-need-ask copy is not approved for sending yet (PROOF_NEED_ASK_COPY_APPROVED=0). It waits for the captain's yes on card L11c, landed in a PR that flips the lock; --dry-run renders exactly what would be sent."
fi
if [ "$LIVE" = "1" ] && [ "$CAMPAIGN" = "proof-need-ask" ] && [ "$NEED_CODE" = "distributor_dashboard_with_code" ] && [ -z "$DISTRIBUTOR_COPY_APPROVED" ]; then
  printf 'HELD distributor_copy_unapproved credits=%s; nothing was sent or claimed\n' "$N"; exit 3
fi
if [ "$LIVE" = "1" ] && [ "$CAMPAIGN" = "proof-refusal" ] && [ "$PROOF_REFUSAL_COPY_APPROVED" != "1" ]; then
  refuse "the proof-refusal copy is not approved for sending (PROOF_REFUSAL_COPY_APPROVED=0); --dry-run renders exactly what would be sent."
fi
if [ "$LIVE" = "1" ] && [ "$CAMPAIGN" = "credit-approved-elsewhere" ] && [ "$APPROVED_ELSEWHERE_COPY_APPROVED" != "1" ]; then
  refuse "the credit-approved-elsewhere copy is not approved for sending (APPROVED_ELSEWHERE_COPY_APPROVED=0). Nobody has approved this line yet; --dry-run renders exactly what would be sent."
fi
# an F9 challenge code verifies exactly ONE request: a distributor ask names exactly one credit
if [ "$CAMPAIGN" = "proof-need-ask" ] && [ "$NEED_CODE" = "distributor_dashboard_with_code" ] && [ "$N" -ne 1 ]; then
  refuse "a distributor_dashboard_with_code ask names exactly one credit (one challenge code per request); got $N."
fi
if [ "$LIVE" = "1" ] && [ "$CAMPAIGN" = "proof-need-ask" ] && [ "$NEED_CODE" = "issuer_email_from_official_domain" ] && [ "$VERIFY_AT_ENABLED" != "1" ]; then
  printf 'HELD verify_at_off credits=%s (the issuer-email line points at verify@muso.ai, which stays off until Intercom identity verification is live); nothing was sent or claimed\n' "$N"; exit 3
fi
if [ "$LIVE" = "1" ] && [ "$CAMPAIGN" = "retro-past" ] && [ "$RETRO_COPY_APPROVED" != "1" ]; then
  refuse "the retro-past copy is not approved for sending yet (RETRO_COPY_APPROVED=0). It needs Fable's copy GO and the captain's approval of the rendered notes, landed in a PR that flips the lock; --dry-run renders exactly what would be sent."
fi

# On a real send, look at the ledger first so a re-run is a quiet no-op before any Intercom
# call. The atomic claims below re-check all of this inside their transactions.
CONTACT_ID="" DUE_DAY="" REMOVAL_DAY=""
if [ "$LIVE" = "1" ]; then
  if [ "$KIND" = "initial" ]; then
    peek="$(ledger pending --campaign "$CAMPAIGN" --user-key "$EMAIL" --user-id "$USER_ID" --day "$DAY" --request-ids "$(ids_csv "$INPUT")")" \
      || die "the ledger read failed; refusing to send without the idempotency record."
    pending="$(printf '%s' "$peek" | "$JQ_BIN" -c '.request_ids')"
    if [ "$pending" = "[]" ]; then
      printf 'SKIPPED already-notified credits=%s\n' "$N"; exit 0
    fi
    nc_why="$(printf '%s' "$peek" | "$JQ_BIN" -r '.no_channel // empty')"
    if [ -n "$nc_why" ]; then
      # r5 / p1 [no-channel]: the last message to this user was refused by Intercom (action_forbidden) - no campaign
      # re-attempts until a person clears it (verify_ledger clear-no-channel); listed, never sent or claimed
      printf 'HELD no_channel credits=%s (%s); nothing was sent or claimed\n' "$N" "${nc_why#no_channel: }"; exit 3
    fi
    if [ "$CAMPAIGN" = "uvn-new-rows" ] && [ "$(printf '%s' "$peek" | "$JQ_BIN" -r '.prior_uvn_ask // false')" != "true" ]; then
      refuse "n1_no_prior_ask: uvn-new-rows follows a SENT uvn-status ask, and this user has none (the opener would be false); nothing was sent or claimed."
    fi
    if [ "$CAMPAIGN" = "uvn-reminder-14" ] && [ "$(printf '%s' "$peek" | "$JQ_BIN" -r '.prior_uvn_ask // false')" != "true" ]; then
      refuse "r14_no_prior_ask: uvn-reminder-14 follows a SENT uvn-status ask that is this user's last ask, and the ledger has none (the reminder would be false); nothing was sent or claimed."
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
      [ "$ACTION" != "post" ] || ledger skip --campaign "$CAMPAIGN" --request-ids "$(printf '%s' "$pending" | "$JQ_BIN" -r 'join(",")')" >/dev/null \
        || die "the ledger write failed."
      printf 'SKIPPED %s credits=%s\n' "$done_why" "$(printf '%s' "$pending" | "$JQ_BIN" -r 'length')"; exit 0
    fi
    if [ "$(printf '%s' "$peek" | "$JQ_BIN" -r '.recent // false')" = "true" ] \
       && { [ -z "$REPLY_DUE" ] || [ "$(printf '%s' "$peek" | "$JQ_BIN" -r '.recent_why // empty')" = "recently_asked" ]; }; then
      if [ "$(printf '%s' "$peek" | "$JQ_BIN" -r '.recent_why // empty')" = "recently_asked" ]; then
        printf 'DEFERRED recently-asked credits=%s (this user got an ask in the last 90 days; the credits wait)\n' \
          "$(printf '%s' "$pending" | "$JQ_BIN" -r 'length')"; exit 3
      fi
      if [ "$(printf '%s' "$peek" | "$JQ_BIN" -r '.recent_why // empty')" = "not_due" ]; then
        printf 'DEFERRED not_due credits=%s (the ask this reminder follows is under 14 days old)\n' \
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
      due)
        # QA #1588: a follow-up of a user Intercom refused (action_forbidden) waits for a person's clear, like any note
        if [ -n "$(printf '%s' "$st" | "$JQ_BIN" -r '.no_channel // ""')" ]; then
          printf 'HELD no_channel credits=%s (%s); nothing was sent\n' "$(printf '%s' "$st" | "$JQ_BIN" -r '.request_ids | length')" \
            "$(printf '%s' "$st" | "$JQ_BIN" -r '.no_channel | sub("^no_channel: "; "")')"; exit 3
        fi ;;
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
    # A follow-up never takes a reason from the caller and never names one: the reviewer's
    # recorded reason is evidence for a human, not input to a message (Aaron 2026-10-29:
    # a decline never states a reason, and no copy teaches what we check).
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
#
# EXIT CODES (r8 771 (2)): 0 = sent/verified, 3 = deferred by a gate, 4 = NOTHING WAS SENT (any pre-send check failed,
# or Intercom rejected the post before delivering), 5 = SENT AND ATTEMPTED BUT UNKNOWN (the request was claimed and
# posted, and either the transport failed or the answer could not be verified - the row is left CLAIMED and is never
# re-sent automatically). Callers that decide what to retry must key on 5, never on prose.
# ONE replica read for this person (gate_facts.py), taken here - immediately before the first check that needs the
# replica. It is an accelerator, never a fact source of its own: core_notice and comm_state run unchanged and ask
# every statement they always asked; with a read on file their replica command is replica-serve.sh, which answers
# the statements the read holds (exact text, at most replica_batch.MAX_AGE_S old) and runs trino-query.sh for the
# rest. A failed or empty read leaves GATE_FACTS_FILE empty and both helpers run exactly as before.
# Nothing a caller passes selects any of it: the three paths are pinned above. The file lives in a root-only tmpfs
# directory, is removed when this process exits, and one a SIGKILL left behind (the runner's 20 s read timeout) is
# swept by the next call.
GATE_FACTS_FILE=""
if [ "$LIVE" = "1" ] && [ -n "$GATE_FACTS_HELPER" ] && [ -r "$GATE_FACTS_HELPER" ] \
   && [ -n "$REPLICA_SERVE" ] && [ -x "$REPLICA_SERVE" ] \
   && printf '%s' "$USER_ID" | grep -qE '^[0-9]{1,12}$' \
   && mkdir -p "$GATE_FACTS_DIR" 2>/dev/null && chmod 700 "$GATE_FACTS_DIR" 2>/dev/null; then
  find "$GATE_FACTS_DIR" -maxdepth 1 -type f -name 'facts.*' -mmin +2 -delete 2>/dev/null || true
  if GATE_FACTS_FILE="$(mktemp "$GATE_FACTS_DIR/facts.XXXXXXXXXX" 2>/dev/null)"; then
    trap 'rm -f "$GATE_FACTS_FILE"' EXIT
    "$PY_BIN" -I "$GATE_FACTS_HELPER" read \
        --campaign "$(if [ "$CAMPAIGN" = "uvn-new-rows" ] || [ "$CAMPAIGN" = "uvn-reminder-14" ]; then echo uvn-status; else printf '%s' "$CAMPAIGN"; fi)" \
        --copy "$COPY" --user-id "$USER_ID" --request-ids "$(ids_csv "$INPUT")" --reply-due "${REPLY_DUE:-}" \
        >"$GATE_FACTS_FILE" 2>/dev/null \
      || : >"$GATE_FACTS_FILE"
    if [ ! -s "$GATE_FACTS_FILE" ]; then rm -f "$GATE_FACTS_FILE"; GATE_FACTS_FILE=""; fi
  else
    GATE_FACTS_FILE=""
  fi
fi
# run a replica-reading helper: through replica-serve.sh when there is a read on file, untouched when there is not
with_gate_facts() {
  if [ -n "$GATE_FACTS_FILE" ]; then
    CORE_NOTICE_TRINO="$REPLICA_SERVE" COMM_STATE_TRINO="$REPLICA_SERVE" REPLICA_BATCH_FACTS="$GATE_FACTS_FILE" "$@"
  else
    "$@"
  fi
}
if [ "$LIVE" = "1" ] && [ -n "$REPLY_DUE" ]; then
  # [key=reply-due]: the core-notice cooldown governs our UNSOLICITED notes, never answering the user (comm_state
  # verifies the trigger before anything is claimed or sent)
  printf 'reply_due %s: core-notice cooldown not applied to this answer\n' "$REPLY_DUE" >&2
elif [ "$LIVE" = "1" ]; then
  # By Muso user id; a note keyed only by email (removal notices) is checked for every account with that email.
  if printf '%s' "$USER_ID" | grep -qE '^[0-9]{1,12}$'; then cn_who=(--user-id "$USER_ID"); else cn_who=(--email "$EMAIL"); fi
  [ -r "$CORE_NOTICE_HELPER" ] || { echo "CORE NOTICE CHECK NOT POSSIBLE: $CORE_NOTICE_HELPER is missing; nothing was sent or claimed" >&2; exit 4; }
  set +e
  cn_win=(); [ "$CAMPAIGN" != "proof-need-ask" ] || cn_win=(--window-hours 24)   # firstmate 034a: the ask waits 24 h
  CN="$(with_gate_facts "$PY_BIN" -I "$CORE_NOTICE_HELPER" check "${cn_who[@]}" "${cn_win[@]}" 2>/dev/null)"; cn_rc=$?
  set -e
  case "$cn_rc" in
    0) ;;
    3) cn_why="$(printf '%s' "$CN" | "$JQ_BIN" -r '(.reasons // []) | join("; ")' 2>/dev/null)"
       # Logged in verify_messages as status 'deferred' (a log, never a lock: the note is offered again next run).
       # A failed log changes nothing about the deferral (nothing was sent); it is reported, not swallowed.
       [ "$ACTION" != "post" ] || ledger log-deferral --campaign "$CAMPAIGN" --user-key "$EMAIL" --user-id "$USER_ID" --day "$DAY" \
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
# uvn-reminder-14 states the day we asked ("On October 24 we asked ..."). That day is the LEDGER's: the day of the
# sent uvn-status ask this reminder follows (verify_ledger.reminder14_ask), read here on every path that renders - a
# preview included - and never taken from the payload or the caller. No ask on the ledger: nothing is rendered.
ASKED_DAY="" ASKED_LABEL=""
if [ "$CAMPAIGN" = "uvn-reminder-14" ]; then
  [ -f "$LEDGER" ] || refuse "r14_no_ledger: uvn-reminder-14 states the day of the ask, which only the ledger ($LEDGER) knows; nothing was rendered, sent or claimed."
  r14="$(ledger pending --campaign "$CAMPAIGN" --user-key "$EMAIL" --user-id "$USER_ID" --day "$DAY" --request-ids "$(ids_csv "$INPUT")")" \
    || die "the ledger read failed; refusing to render a reminder without the day of its ask."
  ASKED_DAY="$(printf '%s' "$r14" | "$JQ_BIN" -r '.asked_day // empty')"
  printf '%s' "$ASKED_DAY" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
    || refuse "r14_no_prior_ask: uvn-reminder-14 follows a SENT uvn-status ask that is this user's last ask, and the ledger has none (the reminder would be false); nothing was rendered, sent or claimed."
  ASKED_LABEL="$(day_label "$ASKED_DAY")" || die "the ask day '$ASKED_DAY' could not be rendered."
  [ -n "$ASKED_LABEL" ] || die "the ask day '$ASKED_DAY' could not be rendered."
fi
readonly ASKED_DAY ASKED_LABEL
# NO after-rejection note exists any more (Fable ruling 79 denial, 2026-11-04; dispatch
# decline-copy.md; Aaron 2026-10-29 wording rule). The deleted copy named ONE of five reasons
# ("it doesn't name you", "it is for a different track", "it is for a different role", "we
# couldn't read it", "it isn't one of the documents we can accept") - a specification of which
# check failed, which is the lesson a forged document learns from, and over-communication on a
# decline. A decline is now the `decline` campaign's single approved sentence, in PR 2 of this
# pair (intercom-verify-request.sh `decline`), and no decline may name a reason again: the
# reason stays in the decider ledger and the audit file for humans. The one place a reviewer's
# reason selects a sentence is the proof-refusal campaign (captain 2026-11-15: a statement about
# a document the person sent, with what would change it; refusal_note), never a decline.
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
# One track can carry several requests (two roles): every title list names each TRACK once, in order (r5 on the free
# dry run: 23 notes read '"Me Dominas", "Me Dominas"'). Normalised by case and whitespace.
def tnorm: tostring | ascii_downcase | gsub("\\s+"; " ") | gsub("^ +| +$"; "");
# r5 on #1504: the identity is the TRACK (track_id), not the title - two different tracks called "Home" are both named.
# Without a track_id: title + artist (normalised); the same title by the same artist is the same track.
def tkey: if ((.track_id // "") | length) > 0 then "id:" + .track_id
          else "t:" + ((.track_title // "") | tnorm) + "|" + ((.artist_name // "") | tnorm) end;
def utitles($c): reduce $c[] as $x ([]; ($x | tkey) as $k | if any(.[]; .k == $k) then . else . + [{k: $k, t: $x.track_title}] end)
  | map(.t);
# A title that already carries its own quote marks at both ends is shown as it is.
def qt: if test("^[\"“”„«»'‘’‚].*[\"“”„«»'‘’‚]$") then . else "\"" + . + "\"" end;
# "Mixing, Mastering" -> "Mixing and Mastering credits"; one role stays "Mixing credit".
def role_credits: [ split(",")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0) ] as $r
  | if ($r | length) > 1 then "\($r | andjoin) credits" else "\(.) credit" end;
def line: "\(.role) on \(.track_title | qt) by \(.artist_name)";
def listed($c; $maxl): [ $c[0:$maxl][] | line ] + (if ($c|length) > $maxl then ["and \(($c|length) - $maxl) more"] else [] end);
def sig: [ {p: "Thank you,"}, {p: "Caroline, Muso Support"} ];
# fable-copy-1031-r5/q-y [key=product-dispute-refs]: the APPROVED REPLY SET, byte-exact (r5 18:5xZ); greeting + sig shared
def reply_ref($fn; $k):
  ({q: "thanks for checking in. There's no open credit request on your account right now. If there's a credit you'd like added, open the track and use Add Credits on the web (top right of your profile's Summary panel) or Add Missing Credits in the app, and choose the role you held.", r: "streaming numbers come from each platform on its own schedule, so Muso can lag what you see on the platform itself, and the two can differ because each platform attributes and reports in its own way. Analytics also need an active Pro or Business plan with a seat assigned to your profile: both are under Settings, so please check the plan shows Pro or Business and that your profile has a seat.", s: "to put the right role on a track, open the track and add the credit with the role you held: Add Credits on the web (top right of your profile's Summary panel) or Add Missing Credits in the app. It's checked the same way as any credit request, and the outcome shows on your request page.", t: "a credit appears on your profile once it's confirmed; until then it stays on your request page. If the credit isn't there at all, open the track and add it with Add Credits on the web or Add Missing Credits in the app, choosing the role you held.", u: "plaques are ordered in the Muso mobile app (iOS or Android): open the Analytics tab and tap Plaque, or go to Flex and choose Make it Official or one of your milestone cards, then customise the title there before checkout. Plaque ordering isn't available on the website right now, and it needs an active subscription.", v: "to add a credit: on the web, open your profile and click Add Credits at the top right of the Summary panel, then search for the track or paste its Spotify link; in the app, open the track or album and tap Add Missing Credits. Choose the role you held and submit. We check it against public credit sources; if we can confirm it, it goes live on your profile, and if we can't confirm it on our own, we message you here and by email with exactly what would settle it.", w: "merges work like this: claim every profile that is yours first (so we know they're all you), then tell me which one should be the main profile. The merge runs as a job and you get a message in this conversation when it's complete; credits from the duplicates move onto the main profile. Profiles claimed by someone else, and company or label profiles, are handled differently: I'll tell you here what can and cannot be done with them.", x: "your plan is under Settings: you can see which plan is active, assign the seat to your profile, and cancel there if you need to. After cancelling you keep access until the end of the billing period, and your credits and profile data are never deleted.", y: "the outcome of a credit request, and the reason, is shown on your request page. If you have something from outside Muso that shows your role on the track, a distributor or label statement, a split sheet, a contract, an invoice or a PRO registration, add the credit again and attach it, and it will be checked against that."}[$k]) as $body
  | { subject: "About your message", segs: ([ {p: "Hi \($fn), \($body)"} ] + sig) };
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
# THE DECLINE (captain 2026-11-12 ~01:00Z, verbatim: "let them know if something was denied. You don't have to tell
# them why. Say credit was denied. verification didn't prove out. If there's fraud, you don't tell them there's fraud.
# You just say for now the credit's denied. You can always resubmit for a credit again later." It replaces the
# 2026-10-29 wording, whose "supporting information ... wasn't enough" was itself a reason.)
# It says the credit is denied for now and that the verification didn't prove out, and nothing else: no reason, no
# list of what was wrong, no date, no accusation, no person to contact - the SAME words for a fraud deny and for an
# ordinary shortfall, because a decline must not teach anyone which check failed. Then the resubmit line.
# The sign-off is "Muso.AI" alone, not Caroline's "Thank you, Caroline, Muso Support" (a denial is not a support
# conversation).
def decline_note($fn; $c; $maxl; $claim):
  ($c | length) as $n
  | if $claim then
      { subject: "Your profile claim on Muso",
        segs: [ {p: "Hi \($fn),"},
                {p: "We finished checking your claim on this profile. For now the claim is denied: the verification didn't prove out."},
                {p: "You can resubmit the claim later from the profile page."},
                {p: "Muso.AI"} ] }
    elif $n == 1 then
      { subject: "Your credit request on Muso",
        segs: [ {p: "Hi \($fn),"},
                {p: "We finished checking your credit request. For now the credit is denied: the verification didn't prove out."},
                {p: "You can resubmit for the credit again later."},
                {p: "Muso.AI"} ] }
    else
      { subject: "Your credit request on Muso",
        segs: [ {p: "Hi \($fn),"},
                {p: "We finished checking your \($n) credit requests. For now these credits are denied: the verification didn't prove out."},
                {ul: listed($c; $maxl)},
                {p: "You can resubmit for them again later."},
                {p: "Muso.AI"} ] }
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
  # fable-copy-1030-r5/l: singular/plural keys on DISTINCT TRACKS (after #1504's dedupe), never on request rows - one
  # track with several roles is the singular body naming every role ("your Producer and Mixing credits")
  (utitles($c) | length) as $n
  | if $n == 1 then
      ($c[0] + {role: ([ $c[].role | split(",")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0) ] | reduce .[] as $r ([]; if index([$r]) then . else . + [$r] end) | join(", "))}) as $x
      | { subject: "Your Muso credit request: one thing we still need",
          segs: ([ {p: "Hi \($fn), a quick status update on your credit request for \($x.track_title | qt) by \($x.artist_name): it's waiting on one thing from you, something that shows your \($x.role | role_credits)."},
                  {p: "Any one of these works (a link, photo or PDF is fine):"}, {ul: uvn_list},
                  {p: "Just reply to this message with it. You will see the credit on your profile as soon as it is approved, and we will let you know here if anything else is needed."} ] + sig) }
    else
      utitles($c) as $u
      | ([ $u[0:$maxl][] | qt ]) as $t
      | { subject: "Your Muso credit requests: one thing we still need",
          segs: ([ {p: "Hi \($fn), a quick status update on your credit requests for \($t | andjoin)\(if ($u | length) > $maxl then " (and \(($u | length) - $maxl) more)" else "" end): they're waiting on one thing from you, something that shows your role on each."},
                  {p: "Any one of these works (a link, photo or PDF is fine):"}, {ul: uvn_list},
                  {p: "Just reply to this message with it. You will see each credit on your profile as soon as it is approved, and we will let you know here if anything else is needed."} ] + sig) }
    end;
# uvn-reminder-14 v1 (captain 2026-11-13 15:08Z): the one reminder of a sent uvn-status ask. It says when we asked
# ($asked, the ledger's day), that we have not received it, and repeats the ask's own list and closing word for word
# (uvn_list, so Caroline's ask-once guard reads it as the ask). No deadline, no consequence, nothing promised.
# Singular/plural keys on DISTINCT TRACKS, as uvn_status does.
def uvn_reminder14($fn; $c; $maxl; $asked):
  (utitles($c) | length) as $n
  | if $n == 1 then
      ($c[0] + {role: ([ $c[].role | split(",")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0) ] | reduce .[] as $r ([]; if index([$r]) then . else . + [$r] end) | join(", "))}) as $x
      | { subject: "Reminder: your Muso credit request still needs one thing",
          segs: ([ {p: "Hi \($fn), on \($asked) we asked for something that shows your \($x.role | role_credits) on \($x.track_title | qt) by \($x.artist_name). We haven't received it yet, so your credit request is still waiting."},
                  {p: "Any one of these works (a link, photo or PDF is fine):"}, {ul: uvn_list},
                  {p: "Just reply to this message with it. You will see the credit on your profile as soon as it is approved, and we will let you know here if anything else is needed."} ] + sig) }
    else
      utitles($c) as $u
      | ([ $u[0:$maxl][] | qt ]) as $t
      | { subject: "Reminder: your Muso credit requests still need one thing",
          segs: ([ {p: "Hi \($fn), on \($asked) we asked for something that shows your role on your credit requests for \($t | andjoin)\(if ($u | length) > $maxl then " (and \(($u | length) - $maxl) more)" else "" end). We haven't received it yet, so they are still waiting."},
                  {p: "Any one of these works (a link, photo or PDF is fine):"}, {ul: uvn_list},
                  {p: "Just reply to this message with it. You will see each credit on your profile as soon as it is approved, and we will let you know here if anything else is needed."} ] + sig) }
    end;
# withdrawal-confirm (firstmate 061, verbatim; subject added for the email channel).
def withdrawal_confirm($c):
  $c[0] as $x
  | { subject: "Your Muso credit request for \($x.track_title | qt)",
      segs: [ {p: "Hi! We've withdrawn your credit request for \($x.role) on \($x.track_title | qt), as you asked. Nothing else changes on your profile. If you need anything else, just reply here."} ] };
# fable-copy-1103-d2/refund-confirm (Fable d2 2026-11-03 22:0xZ, firstmate 109) - BYTE-EXACT, one sentence, no ask, no
# offer, no promise about future work. Only the placeholders change, and every one of them is a fact read from
# Stripe/core and validated before this runs: the amount (with its currency, never a bare number), the day the refund
# was issued, the card's last four digits, and which of the TWO ruled subscription sentences is true. The day is rendered
# the way this gate renders every other customer-facing day (3 November 2026), because the ruling names a date
# placeholder and a raw ISO string is not customer copy.
#   The closing "Nothing more is needed from you" is the ruling's own wording to a customer whose money already moved,
# and it is safe there BECAUSE nothing is owed. It is never available to someone who still owes us proof: the
# owes-nothing body guard below (NIE_BODY) holds any note carrying that promise for a user comm_state shows owes
# proof, so this sentence cannot ride out over an open ask.
def refund_confirm($fn; $r):
  ([ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" ]) as $months
  | ($r.issued_on | split("-") | map(tonumber)) as $d
  | ([ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" ][$d[1] - 1]) as $mon
  | ($r.active_until // "" | split("-") | map(tonumber)) as $u
  | ({cancelled: "Your subscription is now cancelled and will not renew.",
      active: "Your subscription stays active.",
      cancel_at_period_end: (if ($u | length) == 3 then
        "Your subscription stays active until \($u[2]) \($months[$u[1] - 1]) \($u[0]) and will not renew."
        else "" end)}[$r.subscription_state]) as $what
  | (if $r.currency == "usd" then "$" + $r.amount else $r.amount + " " + ($r.currency | ascii_upcase) end) as $amt
  # d2 2026-11-04 04:1xZ: a customer with no personal first name on file is greeted "Hi there," - never a typed name,
  # never a business name in a person's slot ("Hi PT," for the account 'PT Houston' was rendered but not sent).
  | (if ($fn // "") == "" then "Hi there," else "Hi \($fn)," end) as $hello
  | { subject: "Your refund is on its way (Muso)",
      segs: [ {p: "\($hello) confirming your refund of \($amt) issued on \($d[2]) \($mon) \($d[0]) to the card ending \($r.card_last4). \($what) Nothing more is needed from you."} ] };
# Status notes (firstmate 070 verbatim; 071 as credit-trust-llm-t01 drafted). Not asks.
def req_s($n): if $n == 1 then "request" else "requests" end;
def titles($c; $maxl):
  utitles($c) as $u
  | ([ $u[0:$maxl][] | qt ] | andjoin) + (if ($u|length) > $maxl then " and \(($u|length) - $maxl) more" else "" end);
def status_doc_received($fn; $c; $maxl):
  { subject: "Your Muso credit \(req_s($c|length)): an update",
    segs: [ {p: "Hi \($fn), a quick update on your credit \(req_s($c|length)) for \(titles($c; $maxl)): we have the document you sent us, and our team is reviewing it. Nothing else is needed from you right now, and you'll see each credit on your profile as soon as it's approved."} ] };
def status_doc_queued($fn; $c; $maxl):
  { subject: "Your Muso credit \(req_s($c|length)): an update",
    segs: [ {p: "Hi \($fn), a quick update on your credit \(req_s($c|length)) for \(titles($c; $maxl)): we have the document you sent, and it's in our review queue. We'll message you here as soon as it's checked - no need to send anything else."} ] };
# fable-copy-1030-r5/k (byte-for-byte): the team-review status line WITHOUT the retired "Nothing else is needed" sentence
# and without the soft ask ("If you have something that shows your role...": a status line never asks). Singular /
# plural key on DISTINCT TRACKS (#1504, r5 /l); more than 3 tracks = the count form. Replaces teamreview AND its no-ask
# B0 variant (both now the same approved line) and the count variant.
def team_review_k($fn; $c; $maxl):
  utitles($c) as $u
  | if ($u | length) == 1 then
      { subject: "Your Muso credit request: an update",
        segs: [ {p: "Hi \($fn), a quick update on your credit request for \($u[0] | qt): it's with our team for review, and we'll message you here as soon as it's been checked."} ] }
    elif ($u | length) <= 3 then
      { subject: "Your Muso credit requests: an update",
        segs: [ {p: "Hi \($fn), a quick update on your credit requests for \([ $u[] | qt ] | andjoin): they're with our team for review, and we'll message you here as soon as they've been checked."} ] }
    else
      { subject: "Your Muso credit requests: an update",
        segs: [ {p: "Hi \($fn), a quick update on your \($c | length) credit requests: they're with our team for review, and we'll message you here as soon as they've been checked."} ] }
    end;
# fable-copy-1030-r5/i (byte-for-byte): status A NEUTRAL for an UNREAD filing - never "document", "proof" or "review
# queue" (that is R1, reserved for record/f9 filings by #1526); singular/plural on distinct tracks.
def status_neutral($fn; $c; $maxl):
  utitles($c) as $u
  | if ($u | length) == 1 then
      { subject: "Your Muso credit request: an update",
        segs: [ {p: "Hi \($fn), a quick update on your credit request for \($u[0] | qt): we've received what you sent, and it's with our team. We'll message you here as soon as it's been checked."} ] }
    else
      { subject: "Your Muso credit requests: an update",
        segs: [ {p: "Hi \($fn), a quick update on your credit requests for \([ $u[0:$maxl][] | qt ] | andjoin)\(if ($u | length) > $maxl then " and \(($u | length) - $maxl) more" else "" end): we've received what you sent, and it's with our team. We'll message you here as soon as they've been checked."} ] }
    end;
def status_team_review($fn; $c; $maxl): team_review_k($fn; $c; $maxl);
def status_team_review_count($fn; $n):
  if $n >= 2 then
    { subject: "Your Muso credit requests: an update",
      segs: [ {p: "Hi \($fn), a quick update on your \($n) credit requests: they're with our team for review, and we'll message you here as soon as they've been checked."} ] }
  else error("teamreviewcount: the /k count form is for 2 or more requests") end;
# fable-copy-1030-r5/l2 (2): the roles on ONE track follow /l - joined "and", plural "credits" ("Mixing credit" for one)
def track_roles($c): reduce ($c[].role // "" | split(",")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0)) as $r
  ([]; if any(.[]; ascii_downcase == ($r | ascii_downcase)) then . else . + [$r] end);   # in order, each role once
# R1. fable-copy-1101-r5/r1-roles: number by distinct (track, role) pairs - ONE track carrying 2+ distinct roles (in
# 2+ request rows, or one row whose role is comma-combined: QA #1626) names the roles ("your Mixing and Mastering credit requests for ..."); one track whose rows collapse to
# ONE role is the single-request line; 2+ distinct tracks keep the plural line over titles (extra roles on a track need
# no words: the titles explain the plural). "the document you sent" as deployed (R1 facts carry no document count).
def status_doc_received_r1($fn; $c; $maxl):
  (utitles($c) | length) as $nt | track_roles($c) as $roles
  | (if $nt == 1 and ($roles | length) >= 2 then "roles" elif $nt == 1 then "one" else "many" end) as $shape
  | { subject: "Your Muso credit \(if $shape == "one" then "request" else "requests" end): an update",
    segs: [ {p: (if $shape == "roles"
                 then "Hi \($fn), a quick update on your \($roles | andjoin) credit requests for \(titles($c; $maxl)): we have the document you sent, and it's in our review queue. We'll message you here as soon as it's checked."
                 else "Hi \($fn), a quick update on your credit \(if $shape == "one" then "request" else "requests" end) for \(titles($c; $maxl)): we have the document you sent, and it's in our review queue. We'll message you here as soon as it's checked." end)}
            # L13 (rulings-1028-1430: "R1 + L13 as a second paragraph") is RETIRED from R1 - r5 10-30 19:2xZ: with #1526
            # an R1 only ever receipts a document of record (record / f9), never a screenshot of Muso itself, so the L13
            # sentence never renders on an R1 (a Muso-UI filing is refused below, never receipted)
          ] };
def status_team_review_noask($fn; $c; $maxl): team_review_k($fn; $c; $maxl);
def claim_ask($fn; $c):
  { subject: "Confirming your claim on \($c.profile_name)",
    segs: ([ {p: "Hi \($fn),"},
             {p: "I'm Caroline from Muso support. You asked to claim \($c.profile_name) on Muso (\($c.profile_url)). To confirm it's you, please add the code \($c.code) to your \($c.surface) by \($due).\(if $c.platform == "spotify" then " Open Spotify for Artists, then Profile, then About, and put the code in your artist bio." else "" end) We check for it every day, and you can remove it once your claim is confirmed."},
             {p: "If the code isn't there by \($due), the claim closes. You can reopen it any time from the profile."},
             {p: "If adding the code isn't possible for you, reply to this message with paperwork that shows your name on one of \($c.profile_name)'s releases: a split sheet, a producer or mixing agreement, an invoice, a royalty or distributor statement, or a PRO registration. Attach it here; we never ask for ID to claim a profile."} ] + sig) };
# claim-status (Fable claims-documentation-readiness-1023 ruling 3, verbatim): no ask, no promise of an outcome.
def claim_status_note($fn; $c):
  { subject: "Your claim on \($c.profile_name)",
    segs: [ {p: "Hi \($fn), a quick update on your claim on \($c.profile_name): it is with our team for review, and we will message you here as soon as it has been checked."} ] };
# merge-pending (go-live-today line M1, verbatim): status only, names the profiles, no date, no instruction.
def merge_pending($fn; $m):
  { subject: "Your Muso merge request",
    segs: [ {p: "Hi \($fn), a quick update on your request to merge \([ $m.profiles[] ] | andjoin): it's in our review queue, nothing has been changed yet, and we will message you here when it has been checked."} ] };
# merge-claim-first (r5 fable-copy-1030-r5/e1, verbatim): the ask, the approved §2.4 merge paragraph (the faq's own
# "Merges work like this:" paragraph, verbatim; the tests pin the two equal by that opening line, never by a line
# number, because an inserted FAQ answer moved it once and reded tests whose copy had not changed) and r5's one-line
# sign-off, in BOTH delivery modes.
# r5 fable-copy-1103-r5/mcf-proof-ack quotes the amended paragraph as the acknowledgement sentence followed directly by
# "The credits you asked about are listed ...": the greeting is REPLACED by the acknowledgement, not kept behind it. So the
# paragraph is written once, and only its opening varies - that keeps one copy of the copy, so the two renderings cannot
# drift apart, and the no-proof rendering stays e1 verbatim.
def mcf_first_paragraph($fn; $m; $proof):
  "\(if $proof == true then $ack + " " else "Hi \($fn), " end)\(if $proof == true then "The" else "the" end) credits you asked about are listed on another Muso profile with your name, the one linked to the Spotify artist page for these tracks: https://credits.muso.ai/profile/\($m.link_profile_id). If that profile is also you, claim it first and tell me which one should be the main profile.";

def merge_claim_first($fn; $m; $proof):
  { subject: "Your Muso credit request: a second profile with your name",
    segs: [ {p: mcf_first_paragraph($fn; $m; $proof)},
            {p: "Merges work like this: claim every profile that is yours first (so we know they're all you), then tell me which one should be the main profile. The merge runs as a job and you get a message in this conversation when it's complete; credits from the duplicates move onto the main profile. Profiles claimed by someone else, and company or label profiles, are handled differently: I'll tell you here what can and cannot be done with them."},
            {p: "Thank you, Caroline, Muso Support"} ] };
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
# proof-need-ask (proof-loop captain card L11c, verbatim): common opening, the line for the reader's need code,
# (the PLURAL counterparty line ends "Reply here with it and we'll check it.": p1 ruling 098 under
# captain-1028-213x (c); the one-track counterparty line is proof_request_ask below),
# common closing (its "Thank you, Caroline, Muso Support" is the shared sign-off). One character differs from the
# card: the issuer line's em dash is " - " (the gate refuses an em dash in any note: Caroline's voice; the approved
# queued line uses the same " - "), flagged to proof-loop-lead-fable-p1 for the captain's yes.
#
# The one-track ask for a document of record (captain 2026-11-15T19:27Z; <item> and <role> are its only slots).
# Measured that day on 9,147 extracted documents: 8,167 were credits pages, dashboards or screenshots and 0 of them
# verified, so the ask names the documents that can. Its list is proof_reviewer.ASK_LINES' counterparty documents
# word for word, then the invoice and the label's letter (a bats case holds the two together). The dashboard
# sentence is true of both routes and must stay so: a dashboard screenshot alone is not checked, one that shows the
# code of the distributor_dashboard_with_code line below is.
# It is the approved text with ONE ruled change (firstmate 2026-11-15T20:30Z): the approved words were "the code we
# sent you", and the person this line reaches was sent NO code (a code is issued only with that other line, and a
# request is asked once). So it reads "a code we sent you" and then says what to send where there is none. The
# payload of this need carries no code, so the line cannot branch on one: the sentence is true with a code or without.
# Not the plural line: the text names one track and one role, so several tracks keep the ruled plural text.
# These sentences are quoted in policies/outbound-copy-rubric.md ("The document ask"): the reviewer admits them in
# these words only, so a change here is a change there too (a bats case holds the two together).
def proof_request_ask($item; $role):
  "To verify your credit on \($item) as \($role), send one of these: a split sheet or agreement signed by the artist or label, a PRO registration that lists you in your role, a royalty statement that names the track, an invoice, or a letter from the label. A screenshot of a dashboard or a credits page on its own cannot be checked, because it does not show who holds the right - but a dashboard screenshot that shows a code we sent you can be checked, because the code ties the release to your account. If we have not sent you a code, send one of the documents above. Reply to this conversation with it and the check runs again automatically.";
def proof_need_line($n; $x):
  if $n.code == "readable_document" then
    "The file is hard to read on our side. Reply to this message with the same document as a PDF or a clear photo of the whole page, and we'll check it."
  elif $n.code == "issuer_email_from_official_domain" then
    "It's a message from \($n.issuer). Please ask \($n.issuer) to send one line to verify@muso.ai from their own address confirming you were \($x.role) on \($x.track_title | qt) - or forward us their original email with its headers."
  elif $n.code == "distributor_dashboard_with_code" then
    "Open your \(if ($n.distributor // "") != "" then $n.distributor + " dashboard" else "distributor dashboard" end) in a web browser with your release \($x.track_title | qt) visible, press Ctrl+F (or Cmd+F on a Mac), type this code in the find box: \($n.verify_code), and take one screenshot that shows both. On a phone, open the dashboard website and use Share → Find on page. Reply here with the screenshot; the code works for 7 days."
  else
    proof_request_ask($x.track_title | qt; $x.role)
  end;
# the plural lines (Fable [key=l11c-plural]); only readable + counterparty can send (the other two are held at send)
def proof_need_line_plural($n; $x):
  if $n.code == "counterparty_signed_or_registered" then
    "We need the other side of it: a split sheet or agreement signed by the artist or label, a PRO registration (ASCAP, BMI, SOCAN or similar) that lists you in your role on each track, or a royalty statement that names the tracks. Reply here with it and we'll check it."
  else proof_need_line($n; $x) end;
# the document is named as the user knows it: its kind and the day they sent it (l1 176 = final, via p1 168: l1's text
# with that one insertion; kind image / PDF / file from the mime, server facts only; several documents sent on the
# newest date -> "the documents you sent on {date}")
def doc_many($n): (($n.doc_count // 1) | tonumber? // 1) > 1;
# fable-copy-1030-r5/l2 (1): a document not from the current year carries its year ("January 26, 2022")
def doc_named($n):
  ["January","February","March","April","May","June","July","August","September","October","November","December"] as $m
  | (if doc_many($n) then "the documents" else "the \(if $n.doc_kind == "document" then "file" else $n.doc_kind end)" end)
    + " you sent on \($m[($n.doc_received_at[5:7] | tonumber) - 1]) \($n.doc_received_at[8:10] | tonumber)"
    + (if $n.doc_received_at[0:4] != $day[0:4] then ", \($n.doc_received_at[0:4])" else "" end);
def doc_it($n): if doc_many($n) then "them" else "it" end;
def proof_need_ask($fn; $c; $n; $maxl):
  ($c[0] + {role: (track_roles($c) | andjoin)}) as $x
  | if (utitles($c) | length) == 1 then
      { subject: "About the document for your Muso credit request\(if ($c | length) > 1 then "s" else "" end)",
        segs: ([ {p: "Hi \($fn), thanks for \(doc_named($n)) for your \(track_roles($c) | join(", ") | role_credits) on \($x.track_title | qt) by \($x.artist_name). We have \(doc_it($n)) on file, but on \(if doc_many($n) then "their own they aren't" else "its own it isn't" end) something we can check against an outside source."},
                 {p: proof_need_line($n; $x)},
                 {p: "Your request\(if ($c | length) > 1 then "s stay" else " stays" end) open while we look, and nothing is removed."} ] + sig) }
    else
      { subject: "About the document for your Muso credit requests",
        segs: ([ {p: "Hi \($fn), thanks for \(doc_named($n)) for your credit requests for \(titles($c; $maxl)). We have \(doc_it($n)) on file, but on \(if doc_many($n) then "their own they aren't" else "its own it isn't" end) something we can check against an outside source."},
                 {p: proof_need_line_plural($n; $x)},
                 {p: "Your requests stay open while we look, and nothing is removed."} ] + sig) }
    end;
# credit-approved-elsewhere (UNAPPROVED, send-locked): the credit is verified for another person, and what to send
# if they share it. It names nobody, gives no date and denies nothing. The roles are the ones the two requests share.
def approved_elsewhere($fn; $c; $maxl):
  def shared: [ (.role // "") | split(",")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0) ];
  def uniq: reduce .[] as $y ([]; if any(.[]; ascii_downcase == ($y | ascii_downcase)) then . else . + [$y] end);
  def named_line: "the \(.r | andjoin) \(if (.r | length) > 1 then "credits" else "credit" end) on \(.t | qt)";
  def per_track: reduce (.[] | select((shared | length) > 0)) as $x ([];
                   ($x | tkey) as $k
                   | if any(.[]; .k == $k) then map(if .k == $k then . + {r: (.r + [($x | shared[])])} else . end)
                     else . + [{k: $k, t: $x.track_title, r: ($x | shared)}] end);
  "a split sheet, a label or distributor statement, a PRO or MLC registration, a studio or session invoice, or liner notes or an official release page (PDF, PNG or JPG). We'll check it." as $docs
  | if (utitles($c) | length) == 1 then
      $c[0] as $x | (track_roles($c)) as $r | (($r | length) > 1) as $many
      | { subject: "About your Muso credit request\(if ($c | length) > 1 then "s" else "" end)",
          segs: ([ {p: "Hi \($fn), a quick update on your request for the \($r | join(", ") | role_credits) on \($x.track_title | qt) by \($x.artist_name): \(if $many then "those credits are" else "that credit is" end) already verified for another person, so we can't add \(if $many then "them" else "it" end) to your profile from the request alone."},
                   {p: "If you share \(if $many then "those credits" else "that credit" end), reply to this message with a document that names you for \(if $many then "each role" else "the role" end): \($docs)"} ] + sig) }
    else
      ($c | per_track | map(.r |= uniq)) as $tracks
      | if ($tracks | length) == 0 then error("approved_elsewhere_no_shared_role") else . end
      | ($tracks[:$maxl] | map(named_line)) as $lines
      | (($tracks | length) - ($lines | length)) as $rest
      | { subject: "About your Muso credit requests",
          segs: ([ {p: "Hi \($fn), a quick update on your credit requests: \($lines | andjoin)\(if $rest > 0 then " and \($rest) more" else "" end) are already verified for another person, so we can't add them to your profile from the requests alone."},
                   {p: "If you share those credits, reply to this message with a document that names you for each role: \($docs)"} ] + sig) }
    end;
# proof-refusal (captain 2026-11-15; Fable GO corr=208a8463f735ff45 on the three rendered bodies). The ONLY copy in
# this script that names why a document did not verify a credit; the decline below still names none. One sentence
# set per track, each with that track's own reason and the evidence line of the need the reader recorded, then the
# closing sentence once. One track is ONE paragraph: byte for byte an approved body. No greeting and no sign-off.
# refusal_evidence is proof_reviewer.ASK_LINES per need code, word for word (pinned by test_proof_refusal.py).
def refusal_evidence: {
  counterparty_signed_or_registered: "a split sheet or agreement signed by the artist or label, a PRO registration that lists you in your role, a royalty statement that names the track, an invoice, or a letter from the label",
  readable_document: "the same document as a PDF or a clear photo of the whole page"}[.];
def refusal_note($c):
  def roles: [ (.role // "") | split(",")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0) ];
  def uniq: reduce .[] as $y ([]; if any(.[]; ascii_downcase == ($y | ascii_downcase)) then . else . + [$y] end);
  def reason_line:
    if .reason == "doesnt_name_you" and .need == "counterparty_signed_or_registered" then
      (if (.r | length) == 0 then error("refusal_no_role") else . end)
      | "the document you sent does not name you as \(.r | join(", ")) on \(.t)"
    elif .reason == "other_track" and .need == "counterparty_signed_or_registered" then
      "the document you sent credits you on other tracks, not on \(.t)"
    elif .reason == "unreadable" and .need == "readable_document" then "we could not read the document you sent"
    else error("refusal_uncoded") end;
  def track_line: "\(.t) was not verified. Reason: \(reason_line). What would change this: \((.need | refusal_evidence) // error("refusal_uncoded")).";
  "Reply to this conversation with it and the check runs again automatically. Without it, the result stands." as $close
  # one set per (track, reason, need): two requests on one track for one reason are one set naming both roles
  | (reduce $c[] as $x ([]; ($x | tkey) as $k
       | if any(.[]; .k == $k and .reason == $x.reason and .need == $x.need)
         then map(if .k == $k and .reason == $x.reason and .need == $x.need then .r = ((.r + ($x | roles)) | uniq) else . end)
         else . + [{k: $k, t: $x.track_title, reason: $x.reason, need: $x.need, r: ($x | roles)}] end)) as $tracks
  | (if ($tracks | length) == 0 then error("refusal_no_track") else . end)
  | { subject: "About the document for your Muso credit request\(if ($c | length) > 1 then "s" else "" end)",
      segs: (if ($tracks | length) == 1 then [ {p: (($tracks[0] | track_line) + " " + $close)} ]
             else [ $tracks[] | {p: track_line} ] + [ {p: $close} ] end) };
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
# d2's wait-apology copy v2 (sha256 78f2b8751c1e1f7c4e6369cf4f1f321b4ba0350db404a245fd18769f3f5cf30e; v1 was
# 83b82addc0e041bc, and the ONLY change is F4), VERBATIM except the
# TYPOGRAPHY of its dashes: the approved prose is written with em dashes and this gate refuses an em dash in any customer
# note ("Caroline's voice never uses one"), so each one is rendered as " - ", exactly as every other approved copy in this
# script does (the gap ask, the email-changed ack, the status notes). Words, order and sentences are unchanged; d2 sees
# the three rendered bodies in the read-back and confirms on sight. The fact
# sentence is chosen LIVE (F1 waiting on them / F2 in review / F3 decided with at least one approval / F4 decided with
# NOTHING approved); any other value refuses the user.
def ap_fact($n; $f; $aa):
  if $f == "F1" then
    "Right now \(if $n == 1 then "it is" else "they are" end) waiting on one thing from you - something that shows your role, like a link to the credit on a streaming platform, a photo of the liner notes, or a note from the label or distributor. Reply here with it and it goes straight into review."
  elif $f == "F2" then
    "We have what you sent, and \(if $n == 1 then "it is" else "they are" end) in our review queue. Nothing more is needed from you; we will tell you here when \(if $n == 1 then "it has" else "they have" end) been checked."
  elif $f == "F3" then
    "\(if $n == 1 then "It has" else "They have" end) been decided - the approved credits are on your profile now\(if $aa then "" else ", and anything we could not verify is listed with the reason on the same page" end)."
  elif $f == "F4" then
    # QA #1788 finding 2 (d2 copy v2, sha256 78f2b8751c1e1f7c4e6369cf4f1f321b4ba0350db404a245fd18769f3f5cf30e): F3 states
    # an approval that may not exist. F3 REQUIRES at least one approved row; an all-rejected user gets F4, the ONLY fact
    # allowed when zero rows are approved. Refusing the state and leaving the user silent is the D gap this closes.
    "\(if $n == 1 then "It has" else "They have" end) been reviewed, and we could not verify \(if $n == 1 then "it" else "them" end) from the evidence we have. The reason is listed on each request on your profile. If you can send something that shows your role - a link to the credit on a streaming platform, a photo of the liner notes, or a note from the label or distributor - reply here and we will look again."
  else error("apology_fact_unknown") end;
def wait_apology($fn; $c; $maxl; $ap):
  ($c | length) as $n
  | ($ap.fact // "") as $f
  | ($ap.all_approved // false) as $aa
  | (if ($ap.paid | type) == "boolean" then $ap.paid else error("apology_paid_unknown") end) as $paid
  | (if $n < 1 then error("apology_no_credits") else . end)
  | ([ $c[0:$maxl][] | .track_title ] | utitles($c)) as $ts
  | ([ $ts[] | qt ] | (if length <= 1 then (.[0] // "") else (.[0:-1] | join(", ")) + " and " + .[-1] end)) as $titles
  | (if ($ts | length) >= 1 and ($ts | length) <= $maxl then "for " + $titles else "for that many tracks" end) as $which
  | { subject: (if $n == 1 then "Your Muso credit request: an update, and an apology"
                else "Your Muso credit requests: an update, and an apology" end),
      segs: ([ {p: "Hi \($fn),"},
               {p: (if $paid
                    then "We owe you an apology. You have \($n) credit request\(if $n == 1 then "" else "s" end) with us \($which) and you have not heard from us about \(if $n == 1 then "it" else "them" end) - that wait is too long, and it is on us, not you."
                    else "Sorry for the silence. You have \($n) credit request\(if $n == 1 then "" else "s" end) with us \($which) and we have not told you where \(if $n == 1 then "it" else "they" end) stand\(if $n == 1 then "s" else "" end) - that is our miss, not yours." end)},
               {p: ap_fact($n; $f; $aa)} ]
             + (if $paid then [ {p: "As a paying member your requests are at the front of our queue as we work through them. If anything about \(if $n == 1 then "it" else "them" end) is unclear, reply here and a person will answer."} ]
                else [ {p: "If anything about \(if $n == 1 then "it" else "them" end) is unclear, reply here and a person will answer."} ] end)
             + [ {p: "- The Muso team"} ]) };
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
   elif $copy == "docrecvn" then status_neutral($fn; .credits; $maxl)
   elif $copy == "teamreview" then status_team_review($fn; .credits; $maxl)
   elif $copy == "teamreviewb0" then status_team_review_noask($fn; .credits; $maxl)
   elif $copy == "claimask" then claim_ask($fn; .claim)
   elif $copy == "claimask7" then claim_ask_reminder($fn; .claim)
   elif $copy == "claimstatus" then claim_status_note($fn; .claim)
   elif $copy == "mergepending" then merge_pending($fn; .merge)
   # r5 fable-copy-1103-r5/mcf-proof-ack: the ack sentence is rendered from a required fact; no boolean fact = no note.
   elif $copy == "mergeclaimfirst" then
     (if ($mcfproof | type) != "boolean" then error("mcf_proof_unreadable") else merge_claim_first($fn; .merge; $mcfproof) end)
   elif $copy == "claimpending" then claim_proof_pending($fn; .claim)
   elif $copy == "credithold" then credit_hold_status($fn; .credits; $maxl)
   elif $copy == "teamreviewcount" then status_team_review_count($fn; (.user.pending_count // (.credits | length)))
   elif ($copy | test("^ref[a-y]$")) then reply_ref($fn; $copy[3:])
   elif $copy == "emailchg" then email_changed(false)
   elif $copy == "emailchgdup" then email_changed(true)
   elif $copy == "withdrawal" then withdrawal_confirm(.credits)
   elif $copy == "refundconfirm" then refund_confirm($fn; .refund)
   elif $copy == "uvn" then uvn_status($fn; .credits; $maxl)
   elif $copy == "uvnrem14" then uvn_reminder14($fn; .credits; $maxl; $asked)
   elif $copy == "gap" then gap_ask($fn; .credits; $maxl)
   elif $copy == "waitapol" then wait_apology($fn; .credits; $maxl; (.apology // {}))
   elif $copy == "proofneed" then proof_need_ask($fn; .credits; .need; $maxl)
   elif $copy == "apprelsewhere" then approved_elsewhere($fn; .credits; $maxl)
   elif $copy == "refusal" then refusal_note(.credits)
   elif $copy == "takeback" then takeback_notice($fn; .credits; $maxl)
   elif $copy == "removal" then removal_notice($fn; .credits; $maxl)
   elif $copy == "past" then
     past_initial($fn; .credits; $maxl)
   elif $copy == "decline" then decline_note($fn; .credits; $maxl; $decline_claim == 1)
   elif $kind == "initial" then live_initial($fn; .credits; $maxl; $copy == "windowed"; $due)
   else live_followup($fn; .credits; $maxl; $kind; $due) end)
# Status notes carry the approved "Muso Support" sign-off on email only (the handoff copy, firstmate
# 092/103/106); an in-thread reply sits under Caroline's own name in the conversation and stays unsigned.
| (if ($copy | IN("docrecv", "docrecvq", "docrecvr", "credithold")) and $mtype == "email"
   then .segs += [ {p: "Muso Support"} ] else . end)
| (if ($copy | IN("claimstatus", "mergepending", "claimpending", "docrecvn", "teamreview", "teamreviewb0", "teamreviewcount")) and $mtype == "email" then .segs += sig else . end)
| { subject: .subject,
    text: ([ .segs[] | if has("ul") then (.ul | map("- " + .) | join("\n")) else .p end ] | join("\n\n")),
    html: ([ .segs[] | if has("ul") then "<ul>" + ([.ul[] | "<li>" + esc + "</li>"] | join("")) + "</ul>" else "<p>" + (.p | esc) + "</p>" end ] | join("")) }
JQ
readonly RENDER_JQ
render() { # <input-json> -> {subject, text, html}
  printf '%s' "$1" | "$JQ_BIN" -c --argjson maxl "$MAX_LISTED" --arg copy "$COPY" --arg kind "$KIND" \
    --argjson decline_claim "$DECLINE_CLAIM" \
    --arg ack "$MERGE_CLAIM_FIRST_PROOF_ACK" --argjson mcfproof "${MCF_PROOF:-null}" \
    --arg due "$DUE_LABEL" --arg mtype "$MESSAGE_TYPE" --arg day "$DAY" --arg asked "${ASKED_LABEL:-}" "$RENDER_JQ"
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

# decline_copy_guard <rendered-json>: the decline's own rules, asserted on the copy PARAGRAPHS before anything is
# claimed or sent (never on the track list: "Because", "Within" and "Fraud" are all real song titles and a decline
# still has to go out about them). A hit is a build defect, not a data problem: it refuses, and nothing is written.
decline_copy_guard() {
  [ "$COPY" = "decline" ] || return 0
  local ps hit
  # The rendered note is {subject,text,html}; a list line is a track title, never copy, so it is dropped before the
  # assertion ("Because", "Within" and "Fraud" really are song titles).
  ps="$(printf '%s' "$1" | "$JQ_BIN" -r '[ .text | split("\n\n")[] | select((startswith("- ")) | not) ] | join("\n\n")')"
  hit="$(printf '%s' "$ps" | grep -oiE "$DECLINE_FORBIDDEN" | head -1 || true)"
  [ -z "$hit" ] || refuse "decline_copy_reason_word: the rendered decline says '$hit'. A decline never states a reason and no copy teaches what we check (captain 2026-10-29 13:2xZ; decline-copy-ruling.md item 1). Nothing was sent or claimed."
  printf '%s' "$ps" | grep -qiE 'remov|deadline|by [0-9]|within [0-9]|days?\b' \
    && refuse "decline_copy_deadline: the rendered decline carries removal, deadline or day-count wording (the decline promises no date and threatens nothing). Nothing was sent or claimed."
  return 0
}

# refusal_copy_guard <input-json>: the proof-refusal's send-time lint. The note is rendered a second time with every
# title, role and artist replaced by a neutral token, so the assertion reads the note's own words and never the
# customer's ("Dream Team", "Soon" and "Review" are song titles and the note still goes out about them). It refuses a
# banned word, a missing or altered sentence of the approved body, and a body over REFUSAL_MAX_WORDS. A hit is a
# build defect or a length nobody approved, never the customer's doing: it refuses and writes nothing.
refusal_copy_guard() {
  [ "$COPY" = "refusal" ] || return 0
  local frame hit words
  frame="$(render "$(printf '%s' "$1" | "$JQ_BIN" -c '.credits |= map(.track_title = "T" | .artist_name = "A" | .role = "R")')" \
    | "$JQ_BIN" -r '.subject + "\n" + .text')" \
    || refuse "refusal_copy_unrendered: the proof-refusal could not be rendered for its lint. Nothing was sent or claimed."
  hit="$(printf '%s' "$frame" | grep -oiE "$REFUSAL_FORBIDDEN" | head -1 || true)"
  [ -z "$hit" ] || refuse "refusal_copy_banned_word: the rendered proof-refusal says '$hit' outside a title or role. Nothing was sent or claimed."
  printf '%s' "$frame" | grep -qF 'Reply to this conversation with it and the check runs again automatically. Without it, the result stands.' \
    || refuse "refusal_copy_closing: the rendered proof-refusal does not end with the approved closing sentences. Nothing was sent or claimed."
  [ "$(printf '%s' "$frame" | grep -c ' was not verified\. Reason: .*\. What would change this: ')" -ge 1 ] \
    || refuse "refusal_copy_shape: the rendered proof-refusal is not the approved sentence set. Nothing was sent or claimed."
  words="$(render "$1" | "$JQ_BIN" -r '.text' | wc -w | tr -d ' ')"
  [ "$words" -le "$REFUSAL_MAX_WORDS" ] \
    || refuse "refusal_too_long: the rendered proof-refusal is $words words (the most is $REFUSAL_MAX_WORDS). Nothing was sent or claimed."
  return 0
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

# [key=lamberto-reply-due] helpers. Each Intercom write is verified; a failure exits before any customer post.
with_prefix() { # <rendered-json> -> the same note with the correction sentence first (the approved body unchanged after it)
  printf '%s' "$1" | "$JQ_BIN" -c --arg p "$REPLY_DUE_CORRECTION_TEXT" \
    '.html = "<p>" + $p + "</p>" + .html | .text = $p + "\n\n" + .text'
}
post_note() { # <conversation> <html> -> prints the internal note's part id
  local resp
  resp="$("$JQ_BIN" -nc --arg a "$INTERCOM_ADMIN_ID" --arg b "$2" '{message_type: "note", type: "admin", admin_id: $a, body: $b}' \
    | api POST "/conversations/$1/reply")" || { printf 'NOTE FAILED on conversation %s; nothing was sent to the customer:\n%s\n' "$1" "${resp:0:300}" >&2; return 4; }
  printf '%s' "$resp" | "$JQ_BIN" -r '[(.conversation_parts.conversation_parts // [])[] | select((.part_type // "") == "note")] | last | .id // empty | tostring' \
    | grep -E '^[0-9]{1,24}$' || { printf 'NOTE NOT VERIFIED on conversation %s:\n%s\n' "$1" "${resp:0:300}" >&2; return 4; }
}
assign_to_gate() { # <conversation> <note-html> -> prints the assignment part id. ONE call: the reassignment carries its
  # internal note, so a failure leaves neither (never a "handed to the loop" note on a thread that was not handed over)
  local resp
  resp="$("$JQ_BIN" -nc --arg a "$INTERCOM_ADMIN_ID" --arg b "$2" '{message_type: "assignment", type: "admin", admin_id: $a, assignee_id: $a, body: $b}' \
    | api POST "/conversations/$1/parts")" || { printf 'REASSIGN FAILED on conversation %s:\n%s\n' "$1" "${resp:0:300}" >&2; return 4; }
  [ "$(printf '%s' "$resp" | "$JQ_BIN" -r '.admin_assignee_id // empty | tostring')" = "$INTERCOM_ADMIN_ID" ] \
    || { printf 'REASSIGN NOT VERIFIED on conversation %s:\n%s\n' "$1" "${resp:0:300}" >&2; return 4; }
  printf '%s' "$resp" | "$JQ_BIN" -r '[(.conversation_parts.conversation_parts // [])[] | select((.part_type // "") == "assignment")] | last | .id // empty | tostring' \
    | grep -E '^[0-9]{1,24}$' || { printf 'REASSIGN PART NOT VERIFIED on conversation %s:\n%s\n' "$1" "${resp:0:300}" >&2; return 4; }
}
add_conv_tag() { # <conversation> <tag>: tags are only ever ADDED (r5 i)
  local tags tid created resp
  tags="$(api GET /tags)" || return 4
  tid="$(printf '%s' "$tags" | "$JQ_BIN" -r --arg n "$2" '[(.data // [])[] | select(((.name // "")|ascii_downcase) == $n) | .id][0] // empty')"
  if [ -z "$tid" ]; then
    created="$(printf '{"name":"%s"}' "$2" | api POST /tags)" || return 4
    tid="$(printf '%s' "$created" | "$JQ_BIN" -r 'select(.type == "tag") | .id // empty' 2>/dev/null || true)"
    [ -n "$tid" ] || return 4
  fi
  resp="$("$JQ_BIN" -nc --arg id "$tid" --arg a "$INTERCOM_ADMIN_ID" '{id:$id, admin_id:$a}' | api POST "/conversations/$1/tags")" || return 4
  [ "$(printf '%s' "$resp" | "$JQ_BIN" -r 'select(.type == "tag") | .name // empty' | tr '[:upper:]' '[:lower:]')" = "$2" ] || return 4
}

# r5 / p1 [key=k-proof-required] (/c2): did we send this user a status line about any of these requests? Then this
# ask corrects it: the correction sentence first, by email, and our own 7-day cooldown (the line being corrected) does
# not defer it. Read from the verify ledger (no ledger yet = no earlier line); an unreadable ledger sends nothing.
C2="" C2_SUFFIX="" C2_EX="[]"
# A reply_due ANSWER is never /c2: it goes in-thread, where #1517's locked correction covers an earlier nothing-needed
# line in that thread (/c2 is the unsolicited ask's correction, by email).
if [ "$CAMPAIGN" = "uvn-new-rows" ] && [ -f "$LEDGER" ]; then
  # an n1 follow-up over rows a status line of ours named would need BOTH the /c2 and the n1 openers - that pair is not
  # approved copy, so it refuses (a person reads it) rather than guess an order
  nn="$(ledger nothing-needed-overlap --user-id "$USER_ID" --request-ids "$ALL_IDS")" \
    || { printf 'LEDGER READ FAILED (earlier status line); nothing was sent or claimed\n' >&2; exit 4; }
  [ "$(printf '%s' "$nn" | "$JQ_BIN" -r '(.overlap // []) | length' 2>/dev/null)" = "0" ] \
    || refuse "n1_c2_uncoded: a status line of ours named some of these rows, so this follow-up would need the /c2 correction AND the n1 opener; that pair is not approved copy. Nothing was sent or claimed."
fi
if [ "$CAMPAIGN" = "uvn-status" ] && [ "$KIND" = "initial" ] && [ -z "$REPLY_DUE" ] && [ -f "$LEDGER" ]; then
  nn="$(ledger nothing-needed-overlap --user-id "$USER_ID" --request-ids "$ALL_IDS")" \
    || { printf 'LEDGER READ FAILED (earlier status line); nothing was sent or claimed\n' >&2; exit 4; }
  if [ "$(printf '%s' "$nn" | "$JQ_BIN" -r '(.overlap // []) | length' 2>/dev/null)" != "0" ]; then
    C2=1; C2_SUFFIX="; correction $CORRECTION_C2_REF (follows a status line on $(printf '%s' "$nn" | "$JQ_BIN" -r '.overlap | join(",")' | cut -c1-200))"
    # QA #1565: ONLY the status line(s) being corrected are exempt from the 7-day recent-contact check (by message id)
    C2_EX="$(printf '%s' "$nn" | "$JQ_BIN" -c '[.message_ids[]? | tostring]')" || C2_EX="[]"
    [ -z "$THREAD" ] || refuse "a corrected ask (/c2) goes by email, its own message; --conversation does not apply. Nothing was sent or claimed."
    if [ "$NO_CORRECTION" = 1 ]; then
      printf 'DEFERRED c2_signed_only credits=%s (this ask would correct an earlier status line - class C stays signed-only on the timer); nothing was sent or claimed\n' "$N"
      exit 3
    fi
  fi
fi
with_o() { # <rendered-json> -> /o as the LAST sentence before the sign-off ("Thank you," starts it), byte-exact
  printf '%s' "$1" | "$JQ_BIN" -c --arg o "$GMAIL_FALLBACK_O_TEXT" '
    if (.html | test("<p>Thank you,</p>")) and (.text | test("\nThank you,")) then
      .html |= sub("<p>Thank you,</p>"; "<p>" + $o + "</p><p>Thank you,</p>")
      | .text |= sub("\nThank you,"; "\n" + $o + "\nThank you,")
    else error("no sign-off to place /o before") end'
}
with_n1() { # <rendered-json> -> the n1 opener first (uvn-new-rows); singular/plural as the body renders (/l)
  printf '%s' "$1" | "$JQ_BIN" -c --arg one "$NEW_ROWS_N1_ONE" --arg many "$NEW_ROWS_N1_MANY" '
    (if (.text | test("your credit requests ")) then $many else $one end) as $p
    | .html = "<p>" + $p + "</p>" + .html | .text = $p + "\n\n" + .text'
}
with_c2() { # <rendered-json> -> the same note with the /c2 sentence first; singular/plural as the body renders (/l)
  printf '%s' "$1" | "$JQ_BIN" -c --arg one "$CORRECTION_C2_ONE" --arg many "$CORRECTION_C2_MANY" '
    (if (.text | test("your credit requests ")) then $many else $one end) as $p
    | .html = "<p>" + $p + "</p>" + .html | .text = $p + "\n\n" + .text'
}
# r5 fable-copy-1103-r5/mcf-proof-ack pin (a): merge-claim-first's body cannot be built without the recipient's
# documents-on-file fact, read HERE - one read per recipient, in this pass, from our own stores against the named
# request's own creation time. Absent or unreadable = refusal, never a blank and never a body without the sentence.
# mcf_proof_read <contact-id|"">: prints true|false. An empty contact reads the ledger's newest-note contact (the
# render pass runs before the recipient is resolved); anything else reads THAT contact. Every failure is a named
# refusal by the caller, never a blank.
mcf_proof_read() {
  [ -r "$COMM_STATE_HELPER" ] || return 90
  local -a args=(proof-on-file --user-id "$USER_ID" --request-ids "$ALL_IDS")
  [ -z "${1:-}" ] || args+=(--contact-id "$1")
  local pf rc
  set +e
  pf="$("$PY_BIN" -I "$COMM_STATE_HELPER" "${args[@]}" 2>/dev/null)"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || return "$rc"
  # jq failure is a REFUSAL with a named reason by the caller, not this script's exit status
  printf '%s' "$pf" | "$JQ_BIN" -r 'if (.proof_on_file | type) == "boolean" then .proof_on_file else empty end' 2>/dev/null || true
}
mfcfail() { # <rc> <contact>: one refusal reason, whatever the read said
  if [ "$1" = "90" ]; then
    refuse "mcf_proof_unreadable: the documents-on-file fact cannot be read ($COMM_STATE_HELPER is missing). Nothing was sent or claimed."
  fi
  refuse "mcf_proof_unreadable: the documents-on-file fact could not be read (rc=$1, contact=${2:-ledger}). Nothing was sent or claimed."
}
MCF_PROOF="" MCF_SET=0 MCF_CONTACT=""
if [ "$CAMPAIGN" = "merge-claim-first" ]; then
  set +e
  MCF_PROOF="$(mcf_proof_read "")"
  pf_rc=$?
  set -e
  [ "$pf_rc" -eq 0 ] || mfcfail "$pf_rc" ""
  case "$MCF_PROOF" in
    true|false) MCF_SET=1 ;;
    *) refuse "mcf_proof_unreadable: the documents-on-file fact is missing or not a boolean; the acknowledgement cannot be rendered honestly. Nothing was sent or claimed." ;;
  esac
fi
if [ "$CAMPAIGN" = "wait-apology" ]; then
  # [key=apology-fact] (d2's copy, "the fact sentence comes from a LIVE read ... if the live state is not one of the three
  # below, the sender REFUSES that user"): the payload must carry one of exactly four facts (F1-F4), a boolean paid flag and a
  # boolean all_approved flag. Anything else is this user's refusal - never a default fact and never a blank.
  af="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '
      if (.credits | type) == "array" and (.credits | length) >= 1
         and ((.apology.fact // "") | IN("F1", "F2", "F3", "F4"))
         and ((.apology.paid | type) == "boolean")
         and ((.apology.all_approved | type) == "boolean")
      then "ok" else ((.apology.fact // "") + "|" + ((.apology.paid | type) // "none")) end' 2>/dev/null || echo "unreadable")"
  case "$af" in
    ok) ;;
    "F1|boolean"|"F2|boolean"|"F3|boolean"|"F4|boolean") refuse "apology_no_credits: the note names no credit request, so it cannot be rendered honestly. Nothing was sent or claimed." ;;
    "|boolean") refuse "apology_fact_missing: the live request state was not one of F1/F2/F3/F4, so this user is refused (no message beats a wrong one). Nothing was sent or claimed." ;;
    *) refuse "apology_fact_invalid: the apology fact ($af) is not one of F1/F2/F3/F4 with a boolean paid flag; the note cannot be rendered honestly. Nothing was sent or claimed." ;;
  esac
fi
RENDERED="$(render "$INPUT")"
[ "$CAMPAIGN" != "uvn-new-rows" ] || RENDERED="$(with_n1 "$RENDERED")"
[ -z "$C2" ] || RENDERED="$(with_c2 "$RENDERED")"
[ "$GMO" != 1 ] || RENDERED="$(with_o "$RENDERED")"
leak="$(leak_reason "$RENDERED")"
[ -z "$leak" ] || record_refusal "the rendered note contains $leak (from a track title, artist or role). Customers never see internal surfaces; this note is not sent and the credits are recorded as refused for a human to look at."
decline_copy_guard "$RENDERED"
refusal_copy_guard "$INPUT"

payload() { # <rendered-json> <contact-id>
  if [ -n "$THREAD" ]; then
    printf '%s' "$1" | "$JQ_BIN" -c --arg admin "$INTERCOM_ADMIN_ID" \
      '{message_type: "comment", type: "admin", admin_id: $admin, body: .html}'
    return
  fi
  if [ "$MESSAGE_TYPE" = "inapp" ]; then
    # fable-copy-1030-r5/h: the SAME approved body, byte-identical, as an Intercom in-app message
    # (no subject or email template: in-app messages carry the body only).
    # QA #1370: the REQUEST enum is "in_app" - the value Intercom 2.11 documents for create-a-message (and the one
    # its own example uses); "inapp" is the RESPONSE/spelling every reader in this repo records. A stub that echoed
    # the request back could not tell these apart, which is how "inapp" survived in the POST body.
    printf '%s' "$1" | "$JQ_BIN" -c --arg admin "$INTERCOM_ADMIN_ID" --arg to "$2" \
      '{message_type: "in_app", from: {type: "admin", id: $admin}, to: {type: "user", id: $to}, body: .html}'
    return
  fi
  printf '%s' "$1" | "$JQ_BIN" -c --arg mt "$REQ_TYPE" --arg admin "$INTERCOM_ADMIN_ID" --arg to "$2" \
    '{message_type: $mt, template: "personal", from: {type: "admin", id: $admin}, to: {type: "user", id: $to}, body: .html}
     + (if $mt == "email" then {subject: .subject} else {} end)'
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
    # Several Intercom users share the email (firstmate 091): the ones whose external_id is this
    # account are its contacts (r5: the web user carries the professional id, the mobile user a
    # presented profile id). Exactly one is the recipient; two or more (web + mobile) send to the
    # one with the professional id / Auth0 subject (an in-thread reply below goes to the thread's
    # own contact when it is one of them). None, or several with no single canonical one, refuses.
    users="$(printf '%s' "$users" | "$JQ_BIN" -c --arg p "$PRO_ID" --arg a "$AUTH_ID" --argjson pr "$PRESENTED_JSON" '
      [.[] | ((.external_id // "") | tostring) as $x
       | select($x != "" and (($p != "" and $x == $p) or ($a != "" and ($x == $a or $x == ("auth0|" + $a))) or any($pr[]; . == $x)))
       | . + {canonical: (($p != "" and $x == $p) or ($a != "" and ($x == $a or $x == ("auth0|" + $a))))}]')"
    n_acct="$(printf '%s' "$users" | "$JQ_BIN" -r 'length')"
    ACCOUNT_CONTACTS="$(printf '%s' "$users" | "$JQ_BIN" -c '[.[].id | tostring]')"
    if [ "$n_acct" -ge 2 ]; then
      users="$(printf '%s' "$users" | "$JQ_BIN" -c '[.[] | select(.canonical)]')"
      [ "$(printf '%s' "$users" | "$JQ_BIN" -r 'length')" -eq 1 ] \
        || record_refusal "the account email matches $n_users Intercom users, $n_acct of them this account's, and not exactly one carries its professional id or Auth0 subject; not sending."
    fi
    [ "$n_acct" -ge 1 ] \
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
# r5: every Intercom user of THIS account (web + mobile). The document scan, the 7-day check and
# the open-conversation lookup read all of them, so a document or a message on the mobile user is
# never missed. One contact unless the dual-contact branch above found more.
[ -n "${ACCOUNT_CONTACTS:-}" ] || ACCOUNT_CONTACTS="$("$JQ_BIN" -nc --arg c "$CONTACT_ID" '[$c]')"
printf '%s' "$ACCOUNT_CONTACTS" | "$JQ_BIN" -e 'type == "array" and length >= 1 and length <= 10 and all(.[]; test("^[A-Za-z0-9]{1,40}$"))' >/dev/null 2>&1 \
  || { echo "CONTACT NOT VERIFIED: the account's Intercom contacts are malformed; nothing was sent" >&2; exit 4; }
for_each_account_contact() { # <fn>: the first non-empty answer of <fn> over this account's contacts
  # A failed read inside <fn> exits 4; errexit is not inherited by a command substitution, so the
  # status is carried out explicitly (a failed read on ANY contact sends nothing).
  local c w rc
  for c in $(printf '%s' "$ACCOUNT_CONTACTS" | "$JQ_BIN" -r '.[]'); do
    rc=0; w="$("$1" "$c")" || rc=$?
    [ "$rc" -eq 0 ] || exit "$rc"
    [ -z "$w" ] || { printf '%s\n' "$w"; return 0; }
  done
}

# Go-live recipient guards (security-arch-fable-s1 section 9.2, BINDING per program-lead-fable-p2 inbox 075) for the
# first-message cohorts: credit-hold-status, claim-proof-pending, merge-pending and the R1 receipt (docrecvr). Real
# sends only. A guard that fails sends nothing and claims nothing: G1 defers (exit 3; retried once the contact is
# old enough), the others refuse (exit 1) for a person to look at. Never a ledger refusal row: a guard failure is
# about our side's certainty, not the user.
# The clock G1 reads; the test copy pins it (INTERCOM_VERIFY_TEST_NOW, epoch) so the 24h rule is testable.
g1_now() { if [ "$TESTABLE" = "1" ] && [ -n "${INTERCOM_VERIFY_TEST_NOW:-}" ]; then printf '%s' "$INTERCOM_VERIFY_TEST_NOW"; else date -u +%s; fi; }
GOLIVE=0
case "$CAMPAIGN:$COPY" in merge-pending:*|merge-claim-first:*|credit-hold-status:*|claim-proof-pending:*|status-doc-received:docrecvr|status-doc-received:docrecvn|uvn-status:*|uvn-new-rows:*|uvn-reminder-14:*|proof-need-ask:*|credit-approved-elsewhere:*|proof-refusal:*) GOLIVE=1 ;; esac
# QA #1517: every reply_due answer, whatever its class, passes the go-live recipient gates (G1-G5; G2's opener rule is
# replaced by the verified trigger for reply_due only)
[ -z "$REPLY_DUE" ] || GOLIVE=1
# the claim code ask's FIRST message too ([key=claim-code-ask-release]); its day-7 reminder keeps its own rules
[ "$CAMPAIGN:$KIND" = "claim-proof-ask:initial" ] && GOLIVE=1
if [ "$GOLIVE" = "1" ] && [ "$LIVE" = "1" ]; then
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
  # firstmate 034c (2026-11-16): a per-need ask whose filing conversation WE opened (an admin or bot; e.g. our own
  # note the customer attached the document to) is no longer refused by G2's opener rule: it goes as our own message
  # by email, the path a closed or off-topic filing thread already takes. G3 below still requires the filing
  # conversation's contact to be this recipient; G2's single-contact and account-user rules still apply to any thread.
  if [ "$COPY" = "proofneed" ] && [ "$R1_THREAD" = "1" ] && [ -n "$THREAD" ] && [ -z "$REPLY_DUE" ]; then
    pn_conv="$(api GET "/conversations/$THREAD?display_as=plaintext")" \
      || { printf 'CONVERSATION READ FAILED (curl); nothing was sent or claimed\n' >&2; exit 4; }
    printf '%s' "$pn_conv" | "$JQ_BIN" -e '(.type // "") == "conversation"' >/dev/null 2>&1 \
      || { printf 'CONVERSATION READ NOT VERIFIED (conversation %s); nothing was sent or claimed\n' "$THREAD" >&2; exit 4; }
    if ! printf '%s' "$pn_conv" | "$JQ_BIN" -e '((.source.author.type // "") | IN("user", "lead", "contact"))' >/dev/null 2>&1; then
      printf 'G2 filing conversation %s was opened by us; the per-need ask goes by email instead\n' "$THREAD" >&2
      THREAD=""; MESSAGE_TYPE="email"; R1_THREAD=0
    fi
  fi
  # The recipient contact: the thread's single contact in-thread, else the contact the email lookup picked.
  if [ -n "$THREAD" ]; then
    # G2: the thread must be opened by the customer, carry exactly one contact, an Intercom USER, and that
    # contact must be the account's own (the one the identity checks chose).
    [ -n "${THREAD_CONTACTS:-}" ] || read_thread_contact
    [ "$(printf '%s' "$THREAD_CONTACTS" | "$JQ_BIN" -r 'length')" = "1" ] \
      || refuse "G2: conversation $THREAD has $(printf '%s' "$THREAD_CONTACTS" | "$JQ_BIN" -r 'length') contacts (need exactly 1); nothing was sent or claimed."
    # r5 (QA @4e23bc6b): the thread's contact must be ONE of this account's Intercom users (web or mobile,
    # ACCOUNT_CONTACTS); the note then goes to that contact, so G3 and the ledger name it. Anything else refuses.
    g2c="$(printf '%s' "$THREAD_CONTACTS" | "$JQ_BIN" -r '.[0]')"
    printf '%s' "$ACCOUNT_CONTACTS" | "$JQ_BIN" -e --arg c "$g2c" 'any(.[]; . == $c)' >/dev/null 2>&1 \
      || refuse "G2: conversation $THREAD's contact is not the account's Intercom user; nothing was sent or claimed."
    CONTACT_ID="$g2c"
    g2conv="$(api GET "/conversations/$THREAD?display_as=plaintext")" \
      || { printf 'CONVERSATION READ FAILED (curl); nothing was sent or claimed\n' >&2; exit 4; }
    # [key=reply-due-g2] (Fable 244, r5 245, p1 246): for a --reply-due answer ONLY, the opener rule is replaced by the
    # verified trigger - comm_state (before any claim) proves the customer's latest part in THIS thread is unanswered
    # > 24 h, the thread is open and on topic (R9), and its single contact is this account's user; a human-assigned
    # thread goes the handoff path. Every other G1-G5 rule stays. [key=r1-filing-thread]: R1 into the filing thread.
    if [ -z "$REPLY_DUE" ]; then
      printf '%s' "$g2conv" | "$JQ_BIN" -e '((.source.author.type // "") | IN("user", "lead", "contact"))' >/dev/null 2>&1 \
        || r1_filing_thread_ok "$g2conv" \
        || refuse "G2: conversation $THREAD was opened by us (an admin or bot), not the customer; nothing was sent or claimed."
    fi
    G_CONTACT="$THREAD_CONTACT_JSON"
  else
    G_CONTACT="$(api GET "/contacts/$CONTACT_ID")" \
      || { printf 'CONTACT READ FAILED (curl); nothing was sent or claimed\n' >&2; exit 4; }
  fi
  [ "$(printf '%s' "$G_CONTACT" | "$JQ_BIN" -r '.role // ""')" = "user" ] \
    || refuse "G4: the recipient contact is not an Intercom user (a lead or visitor); nothing was sent or claimed."
  # G3 (R1 only): the receipt goes to the contact that FILED the document. The caller passes the proof_intake row's
  # conversation as user.filing_conversation; its single contact must be this account's contact.
  # An EMAIL-filed document (support@, no Intercom filing conversation; user.filing_conversation = "email") gets the
  # per-need ask by Intercom email to the account's verified Intercom user - a reply threads into that user's own
  # conversation, which the intake files (proof-loop-lead-fable-p1 152). R1 never takes this path.
  if [ "$COPY" = "proofneed" ] && [ "$INPUT_FILING_CONV" = "email" ]; then
    [ -z "$THREAD" ] || refuse "an email-filed document's ask goes by email; --conversation does not apply. Nothing was sent or claimed."
    # QA #1418: never on the caller's word - the proof store must show each named document was FILED by email (its
    # earliest intake, the one read, has no Intercom conversation) and matched to this account by a strong identity
    # (l1 [key=l11c-email-filed]; the set is receipts.STRONG_MATCH, pinned by a test). Anything else refuses.
    ef_why="$("$PY_BIN" -I - "$PROOF_DB" "$USER_ID" "$EMAIL_FILED_STRONG_MATCH" \
      "$(printf '%s' "$INPUT" | "$JQ_BIN" -r '([.need.doc_sha // empty] + (.need.doc_shas // [])) | unique | join(",")')" \
      "$(printf '%s' "$INPUT" | "$JQ_BIN" -c '.need.doc_intakes // {}')" <<'PY' 2>&1 || true
import json, re, sqlite3, sys
db_path, uid, strong, shas = sys.argv[1], sys.argv[2], set(sys.argv[3].split()), [s for s in sys.argv[4].split(",") if s]
try:
    named = {str(k).lower(): str(v) for k, v in json.loads(sys.argv[5] or "{}").items() if re.fullmatch(r"[A-Za-z0-9:._-]{1,80}", str(v))}
except ValueError:
    named = {}
try:
    if not re.fullmatch(r"[0-9]{1,12}", uid) or not shas:
        raise ValueError("no user id or no named document")
    db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    for sha in shas:
        # QA #1418: the intake the reader READ (need.doc_intakes, from dv_outcomes.intake_id) when named; else the
        # earliest arrival of the file (the one read before intake ids existed)
        if sha.lower() in named:
            row = db.execute("SELECT coalesce(conversation_id, ''), coalesce(matched_by, '') FROM proof_intake WHERE user_id=? "
                             "AND lower(file_sha256)=lower(?) AND intake_id=?", (int(uid), sha, named[sha.lower()])).fetchone()
        else:
            row = db.execute("SELECT coalesce(conversation_id, ''), coalesce(matched_by, '') FROM proof_intake WHERE user_id=? "
                             "AND lower(file_sha256)=lower(?) ORDER BY received_at ASC LIMIT 1", (int(uid), sha)).fetchone()
        if row is None:
            print(f"no intake row of document {sha[:12]} for this user"); sys.exit(0)
        if str(row[0]).strip().isdigit():
            print(f"document {sha[:12]} was filed in Intercom conversation {row[0]}, not by email"); sys.exit(0)
        if row[1] not in strong:
            print(f"document {sha[:12]} was matched to this account by a weak identity ({row[1] or 'none'})"); sys.exit(0)
except Exception as exc:  # unreadable store: refuse (fail closed)
    print(f"the proof store could not be read ({exc})"); sys.exit(0)
PY
)"
    [ -z "$ef_why" ] || refuse "email-filed per-need ask: $ef_why; nothing was sent or claimed."
    MESSAGE_TYPE="email"; R1_THREAD=0
  elif [ "$R1LIKE" = "1" ] || [ "$COPY" = "proofneed" ]; then
    fconv="$(printf '%s' "$INPUT_FILING_CONV" | grep -E '^[0-9]{1,24}$' || true)"
    FILING_SRC="$fconv"   # the document's filing conversation, kept for comm_state even when delivery moves (R9)
    [ -n "$fconv" ] || refuse "G3: the receipt names no filing conversation (user.filing_conversation); nothing was sent or claimed."
    g3="$(api GET "/conversations/$fconv?display_as=plaintext")" \
      || { printf 'CONVERSATION READ FAILED (curl); nothing was sent or claimed\n' >&2; exit 4; }
    [ "$(printf '%s' "$g3" | "$JQ_BIN" -r '[(.contacts.contacts // [])[] | (.id // "") | tostring] | join(",")')" = "$CONTACT_ID" ] \
      || refuse "G3: the contact that filed the document (conversation $fconv) is not this receipt's recipient; nothing was sent or claimed (tray)."
    # r5 19:0xZ: the filing thread already carries our free-text acknowledgement after the filing part -> no R1 / /i
    # (receipts only: the per-need ask is not a receipt)
    if [ "$R1LIKE" = "1" ]; then
      rcpt="$(printf '%s' "$g3" | "$JQ_BIN" -r "$RECEIPTED_JQ" 2>/dev/null)" \
        || { printf 'FILING THREAD NOT READABLE for the receipted check (conversation %s); nothing was sent or claimed\n' "$fconv" >&2; exit 4; }
      if [ -n "$rcpt" ]; then
        printf 'HELD r1_receipted_in_thread credits=%s last_admin_comment_at=%s (conversation %s: we already acknowledged the document there); nothing was sent or claimed\n' "$N" "$rcpt" "$fconv"; exit 3
      fi
    fi
    # The per-need ask goes INTO the filing thread; if that thread is CLOSED it goes by email instead, so the
    # reply opens a new Intercom conversation of the same contact (l1 [key=l11c-asks]). R1 never does this.
    if [ "$COPY" = "proofneed" ] && printf '%s' "$g3" | "$JQ_BIN" -e '((.state // "") | ascii_downcase) == "closed" or .open == false' >/dev/null 2>&1; then
      THREAD=""; MESSAGE_TYPE="email"; R1_THREAD=0
    fi
    # [key=circular-gate] (firstmate 040): so does a STALE filing thread - no customer message in comm_state's
    # STALE_THREAD_DAYS (30) - which comm_state no longer holds for the per-need ask (R6). The opening part's time falls
    # back to the conversation's own date (QA #1508); with neither it is 0, reads as stale and the ask goes by email,
    # never into a thread whose age is unknown.
    if [ "$COPY" = "proofneed" ] && [ -n "$THREAD" ] && printf '%s' "$g3" | "$JQ_BIN" -e --argjson now "$(g1_now)" \
         '. as $c | ([(.source // {}) | .created_at //= ($c.created_at // 0)] + (.conversation_parts.conversation_parts // [])
           | map(select((.author.type // "") as $t | ["user","lead","contact"] | index($t)) | (.created_at // 0))
           | max // 0) < ($now - 30 * 86400)' >/dev/null 2>&1; then
      printf 'filing conversation %s has no customer message in 30 days; the per-need ask goes by email\n' "$fconv" >&2
      THREAD=""; MESSAGE_TYPE="email"; R1_THREAD=0
    fi
    # R9: a filing thread that is not about credits (e.g. a refund thread where a receipt was attached) is never the
    # delivery thread; the note goes by email and comm_state's thread rules are not judged on that unrelated thread
    if ! printf '%s' "$g3" | thread_on_topic; then
      if [ "$COPY" = "docrecvr" ]; then
        r9alt="$(credit_thread_of "$CONTACT_ID" "$fconv")" \
          || { printf 'R9 OTHER-THREAD LOOKUP NOT VERIFIED; nothing was sent or claimed\n' >&2; exit 4; }
        if [ -n "$r9alt" ]; then
          printf 'R9 filing conversation %s is not about credits; delivering into the user'"'"'s credit conversation %s\n' "$fconv" "$r9alt" >&2
          THREAD="$r9alt"; fconv="$r9alt"; MESSAGE_TYPE="comment"
        else
          printf 'R9 filing conversation %s is not about credits and the user has no other open credit conversation; delivering by email\n' "$fconv" >&2
          THREAD=""; MESSAGE_TYPE="email"; R1_THREAD=0; fconv=""
        fi
      else
        printf 'R9 filing conversation %s is not about credits, claims or merges; delivering by email\n' "$fconv" >&2
        THREAD=""; MESSAGE_TYPE="email"; R1_THREAD=0; fconv=""
      fi
    fi
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
# p1 / r5 rule gap (10-30 18:4xZ): the owes-nothing rule follows the RENDERED body, never the campaign name - any note
# whose text says nothing (else) is needed / no need to send anything is held for a user who still owes proof
NIE_BODY=0
NIE_PHRASE="$(printf '%s' "$RENDERED" | "$JQ_BIN" -r '(.subject // "") + " " + (.text // "") + " " + (.html // "")' 2>/dev/null \
     | grep -oiE 'nothing( else)? is needed|nothing more is needed|no need to (send|resend)' | head -1 || true)"
if [ -n "$NIE_PHRASE" ]; then
  NIE=1; NIE_BODY=1
fi
# QA #1660 (important): the note must be rendered from the fact of the contact it is actually going to, and that
# contact is only resolved above. Until now the render read fell back to the ledger's newest-note contact, so a FIRST
# CONTACT recipient whose only proof is an Intercom attachment rendered WITHOUT the sentence this PR exists to add
# (render=false, state=true). Re-read on the resolved contact and re-render on it; the guard below then compares one
# fact read twice instead of two different ones.
if [ "$MCF_SET" = "1" ] && [ -n "${CONTACT_ID:-}" ] && [ "$CONTACT_ID" != "$MCF_CONTACT" ]; then
  MCF_CONTACT="$CONTACT_ID"
  set +e
  MCF_PROOF2="$(mcf_proof_read "$CONTACT_ID")"
  pf2_rc=$?
  set -e
  [ "$pf2_rc" -eq 0 ] || mfcfail "$pf2_rc" "$CONTACT_ID"
  case "$MCF_PROOF2" in
    true|false) ;;
    *) refuse "mcf_proof_unreadable: the documents-on-file fact for contact $CONTACT_ID is missing or not a boolean. Nothing was sent or claimed." ;;
  esac
  if [ "$MCF_PROOF2" != "$MCF_PROOF" ]; then
    MCF_PROOF="$MCF_PROOF2"
    RENDERED="$(render "$INPUT")"
    [ -z "$C2" ] || RENDERED="$(with_c2 "$RENDERED")"
    [ "$GMO" != 1 ] || RENDERED="$(with_o "$RENDERED")"
    leak="$(leak_reason "$RENDERED")"
    [ -z "$leak" ] || record_refusal "the rendered note contains $leak (from a track title, artist or role). Customers never see internal surfaces; this note is not sent and the credits are recorded as refused for a human to look at."
    printf 'NOTE proofs=rerendered contact=%s proof_on_file=%s (the render fact was re-read on the resolved recipient)\n' "$CONTACT_ID" "$MCF_PROOF" >&2
  fi
fi
NIE_ARGS=(); [ "$NIE_BODY" = "1" ] && NIE_ARGS=(--nothing-needed-body)
C2_ARGS=(); [ -n "${C2:-}" ] && C2_ARGS=(--correction)
# uvn-reminder-14: for comm_state it IS the uvn ask (every wait-line hold applies), plus --reminder: ANY customer
# message after the ask, a text reply included, holds it (never re-ask someone who replied)
R14_ARGS=(); [ "$CAMPAIGN" = "uvn-reminder-14" ] && R14_ARGS=(--reminder)
if { [ "$GOLIVE" = "1" ] || [ "$NIE" = "1" ]; } && [ "$LIVE" = "1" ]; then
  # The user's communication state, read from the live stores RIGHT NOW (captain 18:2xZ; comm_state.py): the
  # "wait for our message" lines never go to anyone with a document or reply on file (they get R1 or nothing), R1
  # never after a decision was told, nothing within 7 days of another note. A hold is logged in verify_messages
  # as 'deferred' (never a lock); an unreadable state sends nothing.
  [ -r "$COMM_STATE_HELPER" ] || { echo "COMM STATE CHECK NOT POSSIBLE: $COMM_STATE_HELPER is missing; nothing was sent or claimed" >&2; exit 4; }
  set +e
  # uvn-new-rows IS the uvn ask for comm_state (the same owes / documents / decision rules)
  CS="$(with_gate_facts "$PY_BIN" -I "$COMM_STATE_HELPER" check --campaign "$(if [ "$CAMPAIGN" = "uvn-new-rows" ] || [ "$CAMPAIGN" = "uvn-reminder-14" ]; then echo uvn-status; else printf '%s' "$CAMPAIGN"; fi)" --copy "$COPY" --user-id "$USER_ID" \
        --request-ids "$ALL_IDS" --contact-id "$CONTACT_ID" \
        --conversation "$(if [ "$R1LIKE" = "1" ] || [ "$COPY" = "proofneed" ]; then printf '%s' "${fconv:-}"; else printf '%s' "${THREAD:-}"; fi)" \
        --reply-due "${REPLY_DUE:-}" ${NIE_ARGS[@]+"${NIE_ARGS[@]}"} ${C2_ARGS[@]+"${C2_ARGS[@]}"} ${R14_ARGS[@]+"${R14_ARGS[@]}"} \
        --doc-sha "$(printf '%s' "$INPUT" | "$JQ_BIN" -r '([.need.doc_sha // empty] + (.need.doc_shas // [])) | unique | join(",")')" \
        --doc-at "$(printf '%s' "$INPUT" | "$JQ_BIN" -r '.need.doc_received_at // ""')" \
        --need "$(printf '%s' "$INPUT" | "$JQ_BIN" -r '.need.code // ""')" \
        --filing-conversation "${FILING_SRC:-}" \
        --doc-map "$(printf '%s' "$INPUT" | "$JQ_BIN" -r '(.need.doc_map // {}) | to_entries | map("\(.key)=\(.value)") | join(",")')" \
        --doc-intakes "$(printf '%s' "$INPUT" | "$JQ_BIN" -r '(.need.doc_intakes // {}) | to_entries | map("\(.key)=\(.value)") | join(",")')" 2>/dev/null)"; cs_rc=$?
  set -e
  case "$cs_rc" in
    0) ;;
    3) cs_why="$(printf '%s' "$CS" | "$JQ_BIN" -r '(.state // "") + ": " + ((.reasons // []) | join("; "))' 2>/dev/null)"
       [ "$ACTION" != "post" ] || ledger log-deferral --campaign "$CAMPAIGN" --user-key "$EMAIL" --user-id "$USER_ID" --day "$DAY" \
         --request-ids "$ALL_IDS" --message-type "$MESSAGE_TYPE" --approved-by "$APPROVED_BY" \
         --approval-ref "$APPROVAL_REF" --reason comm_state --detail "$cs_why" >/dev/null \
         || echo "WARNING: the comm_state hold was not logged in the ledger" >&2
       # p1: a hold of the owes-nothing check by BODY names the phrase it found
       printf 'HELD comm_state credits=%s (%s)%s\n' "$N" "$cs_why" \
         "$([ "$NIE_BODY" = "1" ] && printf ' [owes-nothing check by body: the rendered note says "%s"]' "$NIE_PHRASE")"; exit 3 ;;
    *) printf 'COMM STATE CHECK FAILED (rc=%s); nothing was sent or claimed: %s\n' "$cs_rc" "${CS:0:300}" >&2; exit 4 ;;
  esac
  # r5 fable-copy-1103-r5/mcf-proof-ack: the state check reads the same stores; two reads that disagree about a
  # document on file mean the fact is not trustworthy, so the body (which may already say it) is not sent.
  if [ "$CAMPAIGN" = "merge-claim-first" ]; then
    cs_proof="$(printf '%s' "$CS" | "$JQ_BIN" -r 'if (.proof_on_file | type) == "boolean" then .proof_on_file else empty end' 2>/dev/null)"
    case "$cs_proof" in
      true|false)
        # QA #1660 (important): both reads now use the SAME Intercom contact (the render fact is re-read on the resolved
        # recipient above), so a disagreement is a contradiction about one contact - the fact is not trustworthy and
        # neither body is sent. A body asserting documents we cannot confirm is the dangerous direction; a body
        # WITHOUT the sentence when the documents ARE on file is the copy defect this PR fixes. Both are refusals.
        if [ "$MCF_PROOF" != "$cs_proof" ]; then
          refuse "mcf_proof_disagrees: the documents-on-file fact is not stable across the render and state reads of contact ${CONTACT_ID:-?} (render=$MCF_PROOF, state=$cs_proof). Nothing was sent or claimed."
        fi ;;
      *) refuse "mcf_proof_unreadable: the state check did not return the documents-on-file fact; the acknowledgement cannot be verified. Nothing was sent or claimed." ;;
    esac
    # QA #1660 b: the fact counts the files the customer sent us in Intercom, but nothing is filed in intake yet. The
    # note goes out WITH the acknowledgement (it is true: they sent us the documents), and a human is told that the
    # only evidence is Intercom so the intake work is not silently skipped.
    case ",$(printf '%s' "$CS" | "$JQ_BIN" -r '(.proof_note // []) | join(",")' 2>/dev/null || true)," in
      *,intercom_only_proof,*) printf 'NOTE proofs=intercom_only (the documents the customer sent us are on file in Intercom only, not in intake yet)\n' >&2 ;;
    esac
  fi
  if [ -n "$REPLY_DUE" ]; then
    RD_PRIOR="$(printf '%s' "$CS" | "$JQ_BIN" -r '.reply_due.prior_note.part // empty' 2>/dev/null)"
    RD_ACT="$(printf '%s' "$CS" | "$JQ_BIN" -r '.reply_due.assignee.action // empty' 2>/dev/null)"
    RD_ASG="$(printf '%s' "$CS" | "$JQ_BIN" -r '.reply_due.assignee.id // empty' 2>/dev/null)"
    if [ -n "$RD_PRIOR" ] && [ "$CAMPAIGN" = "uvn-status" ]; then
      [ "$REPLY_DUE_CORRECTION_APPROVED" = "1" ] || {
        printf 'DEFERRED reply_due_correction_locked credits=%s (our earlier nothing-is-needed note in this thread: part %s; the correction sentence awaits the captain)\n' "$N" "$RD_PRIOR"; exit 3; }
      RD_PREFIX=1
    fi
  fi
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
# p1 198 / Fable 199 (rule): a document sent BEFORE the oldest named request was created cannot be its proof. The
# runner passes user.requests_since (ISO UTC); attachments older than it do not count. Absent = every document counts.
REQUESTS_SINCE="$(printf '%s' "$(cat "$CREDITS_FILE" 2>/dev/null)" | "$JQ_BIN" -r '(.user.requests_since // "") | tostring
  | if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|\\+00:00)$") then (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601) else 0 end' 2>/dev/null || echo 0)"
printf '%s' "$REQUESTS_SINCE" | grep -qE '^[0-9]{1,12}$' || REQUESTS_SINCE=0
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
    if printf '%s' "$body" | "$JQ_BIN" -e --argjson since "$REQUESTS_SINCE" '[.conversations[] | select((.source.author.type // "") == "user" and ((.source.attachments // []) | length) > 0 and ((.created_at // null) == null or .created_at >= $since))] | length > 0' >/dev/null; then
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
      if printf '%s' "$convo" | "$JQ_BIN" -e --argjson since "$REQUESTS_SINCE" '[(.conversation_parts.conversation_parts // [])[] | select((.author.type // "") == "user" and ((.attachments // []) | length) > 0 and ((.created_at // null) == null or .created_at >= $since))] | length > 0' >/dev/null; then
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
# firstmate 034a (2026-11-16, Aaron's rule "one message per person per day"): the ask proof-need-ask waits 24 hours
# after any message from us, not 7 days. Same window as verify_ledger.RECONTACT_HOURS and core_notice --window-hours
# (pinned equal by scripts/tests/test_verify_ledger_proof_need.py). Every other campaign keeps 7 days.
case "$CAMPAIGN" in proof-need-ask) RECONTACT_S=86400; RECONTACT_LABEL="24 hours" ;; *) RECONTACT_S=$(( 7*86400 )); RECONTACT_LABEL="7 days" ;; esac
recently_messaged() { # <contact-id> -> prints the reason when we wrote to them in the window; exit 4 on a failed read
  local contact="$1" since body ids n cid convo ex
  ex="$("$JQ_BIN" -nc --argjson a "$FOLLOWED_IDS" --argjson b "${C2_EX:-[]}" '$a + $b')" || ex="$FOLLOWED_IDS"
  since=$(( $(date -u +%s) - RECONTACT_S ))
  body="$(printf '%s' "$contact" | "$JQ_BIN" -Rc --argjson since "$since" \
    '{query: {operator: "AND", value: [{field: "contact_ids", operator: "=", value: .}, {field: "updated_at", operator: ">", value: $since}]}, pagination: {per_page: 50}}' \
    | api POST /conversations/search)" || { printf 'RECENT-CONTACT CHECK FAILED (curl); nothing was sent or claimed:\n%s\n' "$body" >&2; exit 4; }
  printf '%s' "$body" | "$JQ_BIN" -e '(.conversations|type) == "array" and ((.total_count // 0) | type) == "number"' >/dev/null 2>&1 \
    || { printf 'RECENT-CONTACT CHECK NOT VERIFIED; nothing was sent or claimed:\n%s\n' "$body" >&2; exit 4; }
  n="$(printf '%s' "$body" | "$JQ_BIN" -r '.total_count // (.conversations | length)')"
  [ "$n" -le 50 ] || { echo "more than 50 conversations in $RECONTACT_LABEL (counted as messaged)"; return 0; }
  if printf '%s' "$body" | "$JQ_BIN" -e --argjson since "$since" --argjson ex "$ex" '[.conversations[] | select(((.source.author.type // "") | IN("admin","bot","team")) and ((.created_at // 0) > $since)
       and (((.source.id // "") | tostring) as $s | $ex | any(. == $s) | not))] | length > 0' >/dev/null; then
    echo "we started a conversation with them in the last $RECONTACT_LABEL"; return 0
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
      echo "we replied to them in the last $RECONTACT_LABEL"; return 0
    fi
  done
  return 0
}
case "$CAMPAIGN" in uvn-status|uvn-new-rows|uvn-reminder-14|status-doc-received|status-team-review|claim-status|gap-ask|merge-pending|merge-claim-first|credit-hold-status|claim-proof-pending|proof-need-ask|credit-approved-elsewhere|proof-refusal) STATUSLIKE=1 ;; *) STATUSLIKE=0 ;; esac
# A claim ask never crosses a person: any admin or Caroline reply to this user in the last 7
# days defers the note AND its reminder (nothing closed; the next run looks again; a reminder
# deferred past the day before the close day is never sent).
[ "$CAMPAIGN" != "claim-proof-ask" ] || STATUSLIKE=1
if [ "$STATUSLIKE" = "1" ] && [ "$LIVE" = "1" ]; then
  # gap-ask / proof-need-ask are never skipped for documents in Intercom: a document on file is why they are sent.
  if [ "$CAMPAIGN" = "gap-ask" ] || [ "$CAMPAIGN" = "proof-need-ask" ]; then
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
  if { [ "$CAMPAIGN" = "uvn-status" ] || [ "$CAMPAIGN" = "uvn-new-rows" ]; } && [ -r "$STAGE2_HELPER" ] && printf '%s' "$USER_ID" | grep -qE '^[0-9]{1,12}$'; then
    s2n="$("$PY_BIN" -I "$STAGE2_HELPER" --db "$PROOF_DB" gap-credits --outcome no_document --request-ids "$ALL_IDS" --user-id "$USER_ID" 2>/dev/null || true)"
    [ "$(printf '%s' "$s2n" | "$JQ_BIN" -r '.eligible // false' 2>/dev/null || echo false)" != "true" ] || S2_NODOC=1
  fi
  # uvn-reminder-14 ALWAYS takes the attachment scan: "never re-ask someone who sent documents" has no stage-2
  # shortcut - an attachment we judged unreadable is still a person who answered, and a person reads that thread
  if { { [ "$CAMPAIGN" = "uvn-status" ] || [ "$CAMPAIGN" = "uvn-new-rows" ]; } && [ "$S2_NODOC" != "1" ]; } || [ "$CAMPAIGN" = "uvn-reminder-14" ]; then
    DOCS_WHY="$(for_each_account_contact docs_submitted)"
    if [ -n "$DOCS_WHY" ]; then
      [ "$ACTION" != "post" ] || ledger skip --campaign "$CAMPAIGN" --request-ids "$ALL_IDS" >/dev/null || die "the ledger write failed."
      printf 'SKIPPED docs_submitted credits=%s (%s)\n' "$N" "$DOCS_WHY"; exit 0
    fi
  fi
  RECENT_WHY=""
  # (a /c2 correction is not deferred by our own recent note - it corrects that note)
  [ -n "$REPLY_DUE" ] || RECENT_WHY="$(for_each_account_contact recently_messaged)"
  if [ -n "$RECENT_WHY" ]; then
    # Not closed: the user may get this note once the 7 days have passed.
    printf 'DEFERRED messaged_7d credits=%s (%s)\n' "$N" "$RECENT_WHY"; exit 3
  fi
  # In-thread when the user has a conversation going: their most recently updated OPEN
  # conversation of the last 14 days. None: email. A failed lookup sends nothing.
  # claim-proof-ask always goes by email.
  if [ -z "$THREAD" ] && [ "$CAMPAIGN" != "claim-proof-ask" ] && [ -z "$C2" ]; then
    since14=$(( $(date -u +%s) - 14*86400 ))
    # r5: across every Intercom user of this account (a mobile conversation is theirs too).
    open_all="[]"
    for oc in $(printf '%s' "$ACCOUNT_CONTACTS" | "$JQ_BIN" -r '.[]'); do
      open="$(printf '%s' "$oc" | "$JQ_BIN" -Rc --argjson since "$since14" \
        '{query: {operator: "AND", value: [{field: "contact_ids", operator: "=", value: .}, {field: "state", operator: "=", value: "open"}, {field: "updated_at", operator: ">", value: $since}]}, pagination: {per_page: 50}}' \
        | api POST /conversations/search)" || { printf 'OPEN-CONVERSATION LOOKUP FAILED (curl); nothing was sent or claimed:\n%s\n' "$open" >&2; exit 4; }
      printf '%s' "$open" | "$JQ_BIN" -e '(.conversations|type) == "array"' >/dev/null 2>&1 \
        || { printf 'OPEN-CONVERSATION LOOKUP NOT VERIFIED; nothing was sent or claimed:\n%s\n' "$open" >&2; exit 4; }
      open_all="$(printf '%s' "$open" | "$JQ_BIN" -c --argjson acc "$open_all" '$acc + .conversations')"
    done
    THREAD="$(printf '%s' "$open_all" | "$JQ_BIN" -r --argjson since "$since14" \
      '[.[] | select((.state // "") == "open" and ((.updated_at // 0) > $since))] | max_by(.updated_at) | .id // empty | tostring')"
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
thread_check() { # sets THREAD_WHY (empty when $THREAD can carry the note), THREAD_UNREAD and THREAD_OFFTOPIC
  local tconv assignee btag
  THREAD_WHY="" THREAD_UNREAD=0 THREAD_WAIT="" THREAD_OFFTOPIC=0
  if ! tconv="$(api GET "/conversations/$THREAD?display_as=plaintext")" \
     || ! printf '%s' "$tconv" | "$JQ_BIN" -e --arg t "$THREAD" '(.type // "") == "conversation" and ((.id // "") | tostring) == $t' >/dev/null 2>&1; then
    THREAD_UNREAD=1; THREAD_WHY="conversation $THREAD could not be read: ${tconv:0:300}"; return 0
  fi
  # r5: the thread's single contact must be ONE of this account's Intercom users (web or mobile);
  # the note then goes to that contact (CONTACT_ID follows it, so the ledger names who got it).
  tc_one="$(printf '%s' "$tconv" | "$JQ_BIN" -r --argjson acc "$ACCOUNT_CONTACTS" '
    [(.contacts.contacts // [])[] | (.id // "") | tostring] as $c
    | if ($c | length) == 1 and ($acc | index($c[0])) != null then $c[0] else "" end')"
  if [ -z "$tc_one" ]; then
    THREAD_WHY="conversation $THREAD is not this user's own conversation (its contacts are not exactly one Intercom user of this account); not sending."; return 0
  fi
  THREAD_CONTACT_PICK="$tc_one"
  wait_at="$(printf '%s' "$tconv" | "$JQ_BIN" -r "$WAITING_JQ" 2>/dev/null)" \
    || { THREAD_UNREAD=1; THREAD_WHY="conversation $THREAD: the last-comment read failed"; return 0; }
  if [ -n "$wait_at" ]; then
    THREAD_WAIT="$wait_at"; THREAD_WHY="conversation $THREAD is waiting on the customer (our last comment, at $wait_at, asks them a question)"; return 0
  fi
  assignee="$(printf '%s' "$tconv" | "$JQ_BIN" -r '.admin_assignee_id // empty | tostring')"
  # (a reply_due answer whose comm_state verdict is reassign+answer reassigns the thread before it posts)
  # (a reply_due answer whose comm_state verdict is reassign+answer may take over ONLY the very human it was handed to:
  # if the thread moved to someone else since that verdict, QA #1517, the answer holds)
  if [ -n "$assignee" ] && [ "$assignee" != "0" ] && [ "$assignee" != "$INTERCOM_ADMIN_ID" ] \
     && ! { [ -n "$RD_ACT" ] && [ "$assignee" = "$RD_ASG" ]; }; then   # every assignee action is decided below (QA #1517)
    THREAD_WHY="conversation $THREAD is assigned to a human (admin $assignee), who is handling this user; not sending."; return 0
  fi
  if [ "${GOLIVE:-0}" = "1" ] && [ -z "$REPLY_DUE" ] && ! printf '%s' "$tconv" | "$JQ_BIN" -e '((.source.author.type // "") | IN("user", "lead", "contact"))' >/dev/null 2>&1 \
     && ! r1_filing_thread_ok "$tconv"; then
    THREAD_WHY="G2: conversation $THREAD was opened by us (an admin or bot), not the customer; not sending in it."; return 0
  fi
  btag="$(printf '%s' "$tconv" | "$JQ_BIN" -r --arg b "$BLOCKED_CONV_TAGS" '($b | split(" ")) as $bl | [(.tags.tags // [])[] | (.name // "") | ascii_downcase | select(IN($bl[]))] | .[0] // empty')"
  [ -z "$btag" ] || { THREAD_WHY="conversation $THREAD carries the '$btag' tag (do not auto-message); not sending."; return 0; }
  if [ "$R9_EXEMPT" = "0" ] && ! printf '%s' "$tconv" | thread_on_topic; then
    THREAD_OFFTOPIC=1; THREAD_WHY="R9: conversation $THREAD is not about credits, claims or merges"
  fi
}
THREAD_CONTACT_PICK=""
# QA #1511: the recipient the identity checks chose (G4 read it into G_CONTACT). An auto-picked thread may belong to
# another of the account's contacts; if that thread then fails its check, the email goes to THIS contact again.
CANON_CONTACT_ID="$CONTACT_ID"
if [ -n "$THREAD" ] && [ "$LIVE" = "1" ]; then
  thread_check
  if [ -z "$THREAD_WHY" ] && [ -n "$THREAD_CONTACT_PICK" ]; then
    CONTACT_ID="$THREAD_CONTACT_PICK"
  fi
  if [ -n "$THREAD_WHY" ]; then
    if [ -n "${THREAD_WAIT:-}" ]; then
      # r5 19:0xZ: a thread waiting on the customer gets no automated line, by thread or as an email beside it
      printf 'HELD waiting_on_customer credits=%s last_admin_question_at=%s (%s); nothing was sent or claimed\n' "$N" "$THREAD_WAIT" "${THREAD_WHY:0:200}"; exit 3
    elif [ "$THREAD_OFFTOPIC" = "1" ]; then
      # R9: never into an unrelated thread; by email instead (every campaign, R1 included - p1 165 / Fable 166) -
      # unless --channel inapp was asked for, in which case the note still never goes by email (QA #1370: the
      # auto-selected-thread branch above restored the channel and this one silently spent the email budget)
      THREAD=""; R1_THREAD=0
      if [ "$CHANNEL" = "inapp" ]; then
        printf 'R9 %s; delivering in-app (the requested channel)\n' "$THREAD_WHY" >&2
        set_inapp
      else
        printf 'R9 %s; delivering by email\n' "$THREAD_WHY" >&2
        MESSAGE_TYPE="email"
      fi
    elif [ "$R1_THREAD" = "1" ]; then
      printf 'HELD r1_filing_thread credits=%s (%s); nothing was sent or claimed\n' "$N" "${THREAD_WHY:0:300}"; exit 3
    elif [ "$THREAD_AUTO" = "1" ]; then
      THREAD=""; MESSAGE_TYPE="email"; CONTACT_ID="$CANON_CONTACT_ID"
      # --channel inapp: the auto thread is unusable, but the note still never goes by email
      [ "$CHANNEL" != "inapp" ] || set_inapp
    elif [ "$THREAD_UNREAD" = "1" ]; then
      printf 'THREAD CHECK NOT VERIFIED; nothing was sent or claimed: %s\n' "$THREAD_WHY" >&2; exit 4
    else
      record_refusal "$THREAD_WHY"
    fi
  fi
fi
# Delivery channel (p1 191; r5 #1511, fable-copy-1030-r5/h, firstmate 022). The ROUTE is selected first (above:
# the user's own open conversation, else a note by email); reachability is checked only for the route that
# was selected, and an unreachable route moves to the NEXT channel in this fixed order:
#   1. in-thread Caroline comment (an open conversation) - already chosen above; email reachability is moot;
#   2. email (POST /messages, message_type email) - only when Intercom will email this contact;
#   3. Intercom in-app (POST /messages, request message_type in_app, the same approved body) - only with
#      --inapp-fallback or an explicit --channel inapp, and only for a USER contact the messenger has seen
#      (web, iOS or Android last_seen_at);
#   4. push, 5. bell - hydra has no sender for either yet (core #11075 dark), so they are named in the reason only;
#   none left: refused and RECORDED as no_channel (terminal, never a send row; the next run skips the user and the
#   outbound tick's no-channel tray carries it). Only a readable contact object for THIS contact proves anything.
# QA #1370 (Important, round 2): in-app ELIGIBILITY is a property of the contact, not of the email route. It used to be
# evaluated only inside the email-unreachable branch, so an explicit --channel inapp on an email-REACHABLE contact posted
# an in_app note to a lead, a never-seen contact, or account 15 - Intercom accepts it and the ledger records `sent`, so
# the user receives nothing and is never retried. One predicate, used wherever the selected route is in-app.
inapp_ineligible() { # <contact json>: the reason this contact cannot receive an in-app note, or empty
  local c="$1"
  if [ "$USER_ID" = "15" ]; then
    printf 'account 15 never gets an in-app message (fable-copy-1030-r5/h)'; return 0
  fi
  if [ "$(printf '%s' "$c" | "$JQ_BIN" -r '.role // ""' 2>/dev/null)" != "user" ]; then
    printf 'in-app goes to Intercom users only (this contact is not a user)'; return 0
  fi
  if ! printf '%s' "$c" | "$JQ_BIN" -e '[.last_seen_at, .ios_last_seen_at, .android_last_seen_at]
      | map(select(type == "number" and . > 0)) | length > 0' >/dev/null 2>&1; then
    printf 'in-app not deliverable (the messenger has never seen this contact)'; return 0
  fi
  return 0
}

if [ -z "$THREAD" ] && [ "$LIVE" = "1" ]; then
  # QA #1511: reachability is read for the FINAL recipient; the cached G4 contact is reused only when it IS that contact.
  reach="${G_CONTACT:-}"
  if [ -z "$reach" ] || ! printf '%s' "$reach" | "$JQ_BIN" -e --arg c "$CONTACT_ID" '((.id // "") | tostring) == $c' >/dev/null 2>&1; then
    reach="$(api GET "/contacts/$CONTACT_ID")" \
      || { printf 'CONTACT READ FAILED (curl) before choosing the channel; nothing was sent or claimed\n' >&2; exit 4; }
  fi
  printf '%s' "$reach" | "$JQ_BIN" -e --arg c "$CONTACT_ID" 'type == "object" and (.type // "") == "contact"
      and ((.id // "") | tostring) == $c' >/dev/null 2>&1 \
    || { printf 'CONTACT READ NOT VERIFIED before choosing the channel (not this contact object); nothing was sent or claimed\n' >&2; exit 4; }
  unreach="$(printf '%s' "$reach" | "$JQ_BIN" -r 'if .has_hard_bounced == true then "hard_bounced"
    elif .unsubscribed_from_emails == true then "unsubscribed" elif .marked_email_as_spam == true then "marked_spam"
    else "" end' 2>/dev/null)" || unreach="unreadable"
  inapp_why=""
  # the selected route is in-app (an explicit --channel inapp, or the email-unreachable fallback below): eligibility is
  # checked for BOTH, never only for the fallback
  if [ "$MESSAGE_TYPE" = "inapp" ] || [ -n "$unreach" ]; then inapp_why="$(inapp_ineligible "$reach")"; fi
  if [ -n "$unreach" ]; then
    if [ -z "$inapp_why" ] && [ "$INAPP_FALLBACK" != "1" ] && [ "$CHANNEL" != "inapp" ]; then
      # QA #1511: an in-app route EXISTS but is not armed yet (armed only after the signed first-batch dry run).
      # Not a terminal refusal: nothing is recorded, so the first run with --inapp-fallback still reaches this user.
      # QA #1370: --channel inapp is itself the arming - the caller asked for in-app and nothing else, so a contact
      # Intercom will not email is exactly the contact this route exists for. The email-initiated fallback keeps
      # needing --inapp-fallback; only the explicit request skips it. The eligibility checks above still stand.
      printf 'DEFERRED inapp_not_armed credits=%s (email_unreachable:%s; an in-app route exists, --inapp-fallback not set); nothing was sent or claimed\n' "$N" "$unreach"
      exit 3
    fi
    if [ -z "$inapp_why" ]; then
      MESSAGE_TYPE="inapp"; ROUTE_WHY="email_unreachable:$unreach"
    else
      record_refusal "no_channel: email_unreachable:$unreach (Intercom will not email this contact); $inapp_why; push and bell have no hydra sender yet; nothing was sent"
    fi
  elif [ -n "$inapp_why" ]; then
    # the caller asked for in-app and this contact cannot receive it, but Intercom WILL email them: DEFER, never post an
    # undeliverable note (a `sent` row would suppress the retry) and never record a terminal no_channel refusal for a
    # user who has a working channel - the next run, or the next day's email budget, reaches them.
    printf 'DEFERRED inapp_ineligible credits=%s (%s; the email route is open, so this is retried, not refused); nothing was sent or claimed\n' "$N" "$inapp_why"
    exit 3
  fi
fi
if [ "$CAMPAIGN" = "retro-past" ]; then
  DOCS_WHY="$(for_each_account_contact docs_submitted)"
  if [ "$ACTION" = "doc-check" ]; then
    if [ -n "$DOCS_WHY" ]; then printf 'DOCS %s\n' "$DOCS_WHY"; else printf 'NO_DOCS\n'; fi
    exit 0
  fi
  if [ -n "$DOCS_WHY" ]; then
    [ "$ACTION" != "post" ] || ledger skip --campaign "$CAMPAIGN" --request-ids "$ALL_IDS" >/dev/null || die "the ledger write failed."
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
# r5 (QA #1517): the FINAL read before any reply_due post - the part being answered must still be the customer's LATEST
# part (comm_state classified exactly that part). A newer customer part means they wrote again: hold, and the newer
# part becomes its own reply_due trigger (classified on the next run). Unreadable = nothing sent.
# QA #1517 (b1 00:36Z): ONE set of thread checks for BOTH reply_due reads - the final read (before the claim, the
# handoff note or the answer) and the post-claim takeover read (before assign_to_gate). <conv-json> -> 0 = the answer
# may go; 1 = hold (RD_HOLD = "<code> <reason>"); 2 = unverifiable (RD_HOLD = the reason). The thread must be OPEN, its
# contact exactly CONTACT_ID, the checked part still the customer's LATEST, NO support comment (admin / bot / team,
# text or attachment) since that part, and the assignee the one comm_state's decision was about.
# QA #1615 (b1 634): the reply-ref's pick is re-read at the same points as the thread facts (the final read before the
# claim, the takeover read) and immediately before the POST - a NEWER pick for this conversation + part since the first
# check (the classifier re-decided) means this run's ref may be stale: held, nothing posted
pick_unchanged() {
  [ "$CAMPAIGN" = "reply-ref" ] || return 0
  local now_id
  now_id="$(ledger pick-for --conversation "$THREAD" --part "$REPLY_DUE" 2>/dev/null | "$JQ_BIN" -r '.id // ""' 2>/dev/null)" \
    || { RD_HOLD="the pick re-read failed"; return 2; }
  [ -n "$now_id" ] || { RD_HOLD="the pick re-read failed"; return 2; }
  if [ "$now_id" != "${PICK_ID:-}" ]; then
    RD_HOLD="reply_ref_pick_changed (a newer classifier pick $now_id was recorded for part $REPLY_DUE in $THREAD since this run checked pick ${PICK_ID:-?})"
    return 1
  fi
  return 0
}
rd_thread_checks() {
  local c="$1" latest ans now act
  RD_HOLD=""
  pick_unchanged || return $?
  latest="$(printf '%s' "$c" | "$JQ_BIN" -r '[.source, ((.conversation_parts.conversation_parts // [])[])]
      | map(select(((.author.type // "") | IN("user", "lead", "contact")) and ((.part_type // "comment") != "note")
                   and ((((.body // "") | length) > 0) or (((.attachments // []) | length) > 0))))
      | last | (.id // "") | tostring' 2>/dev/null)" || { RD_HOLD="the latest-part read failed"; return 2; }
  if [ "$latest" != "$REPLY_DUE" ]; then
    RD_HOLD="reply_due_newer_part (the customer wrote again in $THREAD: part ${latest:-?} after $REPLY_DUE; it is answered on its own)"; return 1
  fi
  ans="$(printf '%s' "$c" | "$JQ_BIN" -r --arg p "$REPLY_DUE" '[.source, ((.conversation_parts.conversation_parts // [])[])] as $all
      | ([ $all[] | select(((.id // "") | tostring) == $p) | (.created_at // 0) ] | first) as $at
      | if $at == null then "unknown" else
          ([ $all[] | select(((.author.type // "") | IN("admin", "bot", "team")) and ((.part_type // "comment") == "comment")
                             and (((.body // "") | length) > 0 or ((.attachments // []) | length) > 0)
                             and ((.created_at // 0) >= $at) and (((.id // "") | tostring) != $p)) | (.id // "" | tostring) ] | first // "")
        end' 2>/dev/null)" || { RD_HOLD="the answered-check read failed"; return 2; }
  [ "$ans" != "unknown" ] || { RD_HOLD="part $REPLY_DUE is not in the thread"; return 2; }
  if [ -n "$ans" ]; then
    RD_HOLD="reply_due_answered (part $REPLY_DUE in $THREAD was answered by support part $ans since it was checked)"; return 1
  fi
  # QA #1517 (01:30Z): a human's internal NOTE since the part is activity under the 48 h rule (a person is working the
  # thread) - any admin/team note by someone other than this gate (the gate's own handoff note never counts)
  # QA #1517 (03:1xZ): bounded like comm_state's assignee_state - for a takeover, notes since the handoff note; else
  # notes within the last 48 h (an old note must never block the handoff / answer forever)
  local nsince
  if [ "$RD_ACT" = "reassign+answer" ]; then
    nsince="$(printf '%s' "${CS:-}" | "$JQ_BIN" -r '(.reply_due.assignee.handoff_at // 0) | floor' 2>/dev/null)" || nsince=""
    printf '%s' "$nsince" | grep -qE '^[0-9]+$' || { RD_HOLD="the handoff time is unreadable"; return 2; }
  else
    nsince=$(( $(g1_now) - 172800 ))
  fi
  act="$(printf '%s' "$c" | "$JQ_BIN" -r --arg p "$REPLY_DUE" --arg bot "$INTERCOM_ADMIN_ID" --argjson since "$nsince" '
      [.source, ((.conversation_parts.conversation_parts // [])[])] as $all
      | ([ $all[] | select(((.id // "") | tostring) == $p) | (.created_at // 0) ] | first) as $at
      | [ $all[] | select((.part_type // "") == "note" and ((.author.type // "") | IN("admin", "team"))
                          and (((.author.id // "") | tostring) != $bot) and ((.created_at // 0) >= ($at // 0))
                          and ((.created_at // 0) >= $since)
                          and (((.body // "") | length) > 0 or ((.attachments // []) | length) > 0)) | (.id // "" | tostring) ] | first // ""' 2>/dev/null)" \
    || { RD_HOLD="the human-activity read failed"; return 2; }
  if [ -n "$act" ]; then
    RD_HOLD="reply_due_human_active (a person left note $act in $THREAD since part $REPLY_DUE; they are working it)"; return 1
  fi
  if [ "$(printf '%s' "$c" | "$JQ_BIN" -r '.state // ""')" != "open" ]; then
    RD_HOLD="reply_due_not_open (conversation $THREAD is no longer open)"; return 1
  fi
  now="$(printf '%s' "$c" | "$JQ_BIN" -r '.admin_assignee_id // 0 | tostring')"
  if [ -z "$RD_ACT" ]; then
    case "$now" in 0|""|null|"$INTERCOM_ADMIN_ID") ;;
      *) RD_HOLD="reply_due_assigned (conversation $THREAD is now assigned to admin $now)"; return 1 ;;
    esac
  elif [ "$now" != "$RD_ASG" ]; then
    RD_HOLD="reply_due_assigned (conversation $THREAD is now assigned to $now, not $RD_ASG)"; return 1
  fi
  if [ "$(printf '%s' "$c" | "$JQ_BIN" -r '[(.contacts.contacts // [])[] | (.id // "") | tostring] | join(",")')" != "$CONTACT_ID" ]; then
    RD_HOLD="reply_due_contact_changed (conversation $THREAD no longer has exactly contact $CONTACT_ID)"; return 1
  fi
  return 0
}
rd_final_read() {  # QA #1517: before the claim, a handoff note or the answer - a human is never handed a stale answer
  local rc
  rdf="$(api GET "/conversations/$THREAD?display_as=plaintext")" \
    || { printf 'FINAL THREAD READ FAILED for %s; nothing was sent or claimed\n' "$THREAD" >&2; exit 4; }
  rc=0; rd_thread_checks "$rdf" || rc=$?
  case "$rc" in
    0) ;;
    1) printf 'HELD %s credits=%s; nothing was sent or claimed\n' "${RD_HOLD%% *}" "$N"; printf '  %s\n' "${RD_HOLD#* }"; exit 3 ;;
    *) printf 'FINAL THREAD READ NOT VERIFIED for %s: %s; nothing was sent or claimed\n' "$THREAD" "$RD_HOLD" >&2; exit 4 ;;
  esac
}
# QA #1517 (b1 16:00Z): the reply_due handoff / wait branches run only HERE - after the ledger peek, comm_state,
# thread_check (open, single contact = the account's, tags, the assignee is exactly the human comm_state named) and the
# recipient checks: a human is never handed an answer the gate itself would refuse to send.
if [ -n "$REPLY_DUE" ]; then
  case "$RD_ACT" in
    ""|"reassign+answer") ;;
    handoff)
      printf '%s' "$RD_ASG" | grep -qE '^[0-9]{1,24}$' || refuse "reply_due handoff: the assignee id is unreadable; nothing was sent."
      HANDED="$RENDERED"; [ "$RD_PREFIX" != "1" ] || HANDED="$(with_prefix "$RENDERED")"
      if [ "$ACTION" != "post" ]; then
        printf 'HANDOFF-READY conversation=%s to=%s credits=%s (the answer would be handed to the assigned human)\n' "$THREAD" "$RD_ASG" "$N"; exit 0
      fi
      HNOTE="$("$JQ_BIN" -nr --arg ids "$ALL_IDS" --arg body "$(printf '%s' "$HANDED" | "$JQ_BIN" -r '.html')" \
        '"<p><b>credit-answer-ready</b>: the automated verification loop has this answer ready for the customer (request \($ids)). Please send it, or answer in your own words. If no one replies here within 48 hours, the loop reassigns this conversation and sends it.</p><hr>" + $body')"
      LOG_FILE="$(new_log_file reply-due-handoff "$THREAD")"
      "$JQ_BIN" -nc --arg c "$THREAD" --arg to "$RD_ASG" --arg p "$REPLY_DUE" --arg ids "$ALL_IDS" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{agent:"operations", action:"intercom_reply_due_handoff", target:("conversation:" + $c), assignee:$to, reply_due_part:$p, request_ids:$ids, timestamp:$ts, authorization:"Fable [key=lamberto-reply-due]: internal note + tag only, no customer message"}' > "$LOG_FILE"
      rd_final_read   # the customer may have written again since comm_state read the thread: never a stale handoff
      NOTE_ID="$(post_note "$THREAD" "$HNOTE")" || exit 4
      ledger thread-event --kind handoff --conversation "$THREAD" --from-admin "$RD_ASG" --to-admin "$RD_ASG" --note-part "$NOTE_ID" \
        --reply-due "$REPLY_DUE" --request-ids "$ALL_IDS" --user-id "$USER_ID" --approved-by "$APPROVED_BY" --approval-ref "$APPROVAL_REF" >/dev/null \
        || die "the handoff note $NOTE_ID was posted but the ledger write failed; nothing was sent to the customer."
      add_conv_tag "$THREAD" "$HANDOFF_TAG" || { printf 'HANDOFF TAG FAILED on conversation %s (note %s is ledgered)\n' "$THREAD" "$NOTE_ID" >&2; exit 4; }
      printf 'HANDOFF conversation=%s note=%s to=%s credits=%s\n' "$THREAD" "$NOTE_ID" "$RD_ASG" "$N"; exit 0 ;;
    wait)
      # the human has 48 h from the note. QA #1517: the handoff's tag is re-applied (idempotent) on every run, so a
      # tag that failed once is recovered instead of the human silently missing it
      [ "$ACTION" != "post" ] || add_conv_tag "$THREAD" "$HANDOFF_TAG" \
        || { printf 'HANDOFF TAG RETRY FAILED on conversation %s; nothing was sent\n' "$THREAD" >&2; exit 4; }
      printf 'HELD reply_due_assignee credits=%s (wait: handed to admin %s, 48 h from the note)\n' "$N" "$RD_ASG"; exit 3 ;;
    *) printf 'HELD reply_due_assignee credits=%s (%s, admin %s)\n' "$N" "$RD_ACT" "$RD_ASG"; exit 3 ;;
  esac
fi
if [ "$ACTION" = "check-recipient" ]; then
  printf 'RECIPIENT OK %s %s copy=%s credits=%s route=%s%s\n' "$CAMPAIGN" "$KIND" "$COPY" "$N" \
    "$(if [ -n "$THREAD" ]; then echo "comment:$THREAD"; else echo "$MESSAGE_TYPE"; fi)" "${ROUTE_WHY:+ ($ROUTE_WHY)}"; exit 0
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
if [ -n "$REPLY_DUE" ] && [ "$ACTION" = "post" ]; then rd_final_read; fi
# QA #1718 3: the activation lock is ONE switch for the campaign; the decision about a user is not. Ask who tells
# THIS user before claiming anything: core's own credits_rejected email (its route is on, or the send ledger already
# shows one for them) or hydra. Only `hydra_decline` proceeds - `core_email` and `hold` both stop here, UNCLAIMED, so
# an enabled fallback can never send a second decline and never sends blind while the route is unread.
if [ "$LIVE" = "1" ] && [ "$CAMPAIGN" = "decline" ]; then
  # the window is the CLOSE of these credits, never "any email to this user lately" (QA #1718 B): a core note from
  # before the close belongs to an earlier request, and a fixed window either misses it (a second decline) or lets
  # it suppress a request that was never told. No close time = nothing to attribute the read to = hold.
  DC_SINCE="${INTERCOM_VERIFY_TEST_DECLINE_SINCE:-}"
  rc=0
  if [ -z "$DC_SINCE" ]; then   # the test seam only exists while TESTABLE=1: the sanitizer clears it in production
    set +e
    DC_SINCE="$(ledger close-since --request-ids "$ALL_IDS" 2>/dev/null | "$JQ_BIN" -r '.since // ""' 2>/dev/null)"
    rc=$?
    set -e
  fi
  if [ "$rc" != 0 ] || [ -z "$DC_SINCE" ]; then
    printf 'HELD decline_hold credits=%s (no close time for these credits: %s); nothing was sent or claimed\n' "$N" \
      "${DC_SINCE:-the ledger did not report when they were closed}"
    exit 3
  fi
  # WHICH TEMPLATE (QA #1718, 2026-11-06): a profile claim is declined by core's `profile_claim_rejected` email, not
  # by `credits_rejected`, and the two have their own routes. Asking about the credit template for a claim would read
  # "core emails credits" as "core told this claimant" and the claimant would never get the decline the copy promises.
  DC_TEMPLATE="credits_rejected"
  if [ "$DECLINE_CLAIM" = "1" ]; then DC_TEMPLATE="profile_claim_rejected"; fi
  set +e
  DC="$("$PY_BIN" -I "$DECLINE_CLOSE_HELPER" --user-id "$USER_ID" --since "$DC_SINCE" \
    --template "$DC_TEMPLATE" 2>&1)"
  rc=$?
  set -e
  # fail closed toward SILENCE: rc 0 alone is not an answer - the decision word must be hydra_decline, so a helper
  # that printed nothing readable (or died) holds instead of sending
  dc="$(printf '%s' "$DC" | "$JQ_BIN" -r '.decision // ""' 2>/dev/null || true)"
  if [ "$rc" != 0 ] || [ "$dc" != "hydra_decline" ]; then
    why="$(printf '%s' "$DC" | "$JQ_BIN" -r '.why // ""' 2>/dev/null || true)"
    printf 'HELD decline_%s credits=%s (%s); nothing was sent or claimed\n' "${dc:-hold}" "$N" \
      "${why:-the per-user decline decision could not be read: ${DC:0:160}}"
    exit 3
  fi
fi
# p1 615: the copy this note renders and its openers/prefixes go on the ledger row (audits read the ledger)
NOTE_VARIANT="$( { [ "${C2:-0}" = "1" ] && echo c2; [ "${RD_PREFIX:-0}" = "1" ] && echo reply_due_correction; [ -n "${APPROVAL_REF_SUFFIX_O:-}" ] && echo o; true; } | paste -sd, -)"
# The template identity this send renders, hashed: campaign|kind|copy|variant. Stamped on the ledger row with the
# approval kind and id, so an audit can tell which approved template a note used without reading a log (the exact
# bytes are separately pinned by body_sha256 at finalize).
TEMPLATE_SHA="$(printf '%s' "$CAMPAIGN|$KIND|$COPY|$NOTE_VARIANT" | sha256sum | awk '{print $1}')"
if [ "$KIND" = "initial" ]; then
  REFS_FILE="$(mktemp)"
  trap 'rm -f "$REFS_FILE" "${GATE_FACTS_FILE:-}"' EXIT
  # ask_class (p1 178: core_proof_request is an audit class) + is_approved per request ride into refs_json (QA #1418)
  printf '%s' "$INPUT" | "$JQ_BIN" -c '[.credits[] | {request_id, profile_id, track_id} + (if .ask_class != "" then {ask_class} else {} end) + (if .is_approved != "" then {is_approved} else {} end) + (if .review_family != "" then {review_family: (.review_family | tonumber), review_reason: .reason, review_need: .need} else {} end)]' > "$REFS_FILE"
  CLAIM="$(ledger claim --campaign "$CAMPAIGN" --user-key "$EMAIL" --user-id "$USER_ID" --day "$DAY" --request-ids "$ALL_IDS" \
    --message-type "$MESSAGE_TYPE" --approved-by "$APPROVED_BY" \
    --approval-ref "$APPROVAL_REF$(if [ "$RD_PREFIX" = "1" ]; then printf '; correction %s' "$REPLY_DUE_CORRECTION_REF"; fi)${C2_SUFFIX:-}${APPROVAL_REF_SUFFIX_O:-}" \
    --contact-id "$CONTACT_ID" --refs-file "$REFS_FILE" ${WINDOWED_FLAG:+"$WINDOWED_FLAG"} \
    ${REPLY_DUE:+--reply-due "$REPLY_DUE" --conversation "$THREAD"} --copy-ref "$COPY" --variant "$NOTE_VARIANT" \
    --approver-kind "$APPROVER_KIND" --approval-id "$APPROVAL_ID" --template-sha256 "$TEMPLATE_SHA" \
    ${PICK_ID:+--pick-id "$PICK_ID"})" \
    || die "the ledger claim failed; refusing to send without the idempotency record."
else
  CLAIM="$(ledger claim-reminder --parent-message-id "$PARENT_ID" --kind "$KIND" --user-key "$EMAIL" --day "$DAY" \
    --request-ids "$ALL_IDS" --approved-by "$APPROVED_BY" --approval-ref "$APPROVAL_REF${C2_SUFFIX:-}" \
    --copy-ref "$COPY" --variant "$NOTE_VARIANT" \
    --approver-kind "$APPROVER_KIND" --approval-id "$APPROVAL_ID" --template-sha256 "$TEMPLATE_SHA")" \
    || die "the ledger claim failed; refusing to send without the idempotency record."
fi
case "$(printf '%s' "$CLAIM" | "$JQ_BIN" -r 'if .result == "recent" and .reason == "recently_asked" then .reason else .result end')" in
  claimed) ;;
  already_notified)
    printf 'SKIPPED already-notified credits=%s\n' "$N"; exit 0 ;;
  pick_changed)
    printf 'HELD reply_ref_pick_changed credits=%s; nothing was sent or claimed\n' "$N"
    printf '  (at the claim: %s)\n' "$(printf '%s' "$CLAIM" | "$JQ_BIN" -r '.reason // ""')"; exit 3 ;;
  no_prior_ask)
    [ "$CAMPAIGN" != "uvn-reminder-14" ] \
      || refuse "r14_no_prior_ask: uvn-reminder-14 follows a SENT uvn-status ask that is this user's last ask, and the ledger has none; nothing was sent or claimed."
    refuse "n1_no_prior_ask: uvn-new-rows follows a SENT uvn-status ask, and this user has none; nothing was sent or claimed." ;;
  user_done)
    printf 'SKIPPED %s credits=%s\n' "$(printf '%s' "$CLAIM" | "$JQ_BIN" -r '.reason')" "$(printf '%s' "$CLAIM" | "$JQ_BIN" -r '.request_ids | length')"; exit 0 ;;
  recent)
    if [ "$(printf '%s' "$CLAIM" | "$JQ_BIN" -r '.reason // ""')" = "not_due" ]; then
      printf 'DEFERRED not_due credits=%s (the ask this reminder follows is under 14 days old)\n' "$(printf '%s' "$CLAIM" | "$JQ_BIN" -r '.request_ids | length')"; exit 3
    fi
    printf 'DEFERRED messaged_7d credits=%s (a note from this gate in the last 7 days)\n' "$(printf '%s' "$CLAIM" | "$JQ_BIN" -r '.request_ids | length')"; exit 3 ;;
  no_channel)
    printf 'HELD no_channel credits=%s (%s); nothing was sent\n' "$(printf '%s' "$CLAIM" | "$JQ_BIN" -r '.request_ids | length')" \
      "$(printf '%s' "$CLAIM" | "$JQ_BIN" -r '.reason | sub("^no_channel: "; "")')"; exit 3 ;;
  refusal_hold)
    printf 'DEFERRED refused-recheck credits=%s (refused before; held for a re-check or a human)\n' "$(printf '%s' "$CLAIM" | "$JQ_BIN" -r '.request_ids | length')"; exit 3 ;;
  daily_cap)
    printf 'DEFERRED daily-cap credits=%s (this user already had a verify message on %s UTC; they go in the next one)\n' \
      "$(printf '%s' "$CLAIM" | "$JQ_BIN" -r '.request_ids | length')" "$DAY"; exit 3 ;;
  family_cap)
    printf 'DEFERRED family-cap credits=%s (today'"'"'s %s daily cap is spent; this user goes on a later day)\n' \
      "$(printf '%s' "$CLAIM" | "$JQ_BIN" -r '.request_ids | length')" "$CAMPAIGN"; exit 3 ;;
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
[ "$CAMPAIGN" != "uvn-new-rows" ] || RENDERED="$(with_n1 "$RENDERED")"
[ "$RD_PREFIX" != "1" ] || RENDERED="$(with_prefix "$RENDERED")"
[ -z "$C2" ] || RENDERED="$(with_c2 "$RENDERED")"
[ "$GMO" != 1 ] || RENDERED="$(with_o "$RENDERED")"
NC="$(printf '%s' "$CLAIMED_INPUT" | "$JQ_BIN" -r '.credits | length')"
leak="$(leak_reason "$RENDERED")"
if [ -n "$leak" ]; then
  ledger finalize --message-row "$ROW_ID" --status refused --reason "leak check: $leak" >/dev/null
  refuse "the rendered note contains $leak; not sent."
fi
# The decline's own rules, on the CLAIMED credits' render (the copy never varies with the payload, so a hit here is a
# copy defect): the claim is closed refused, and nothing reaches the customer.
if ! dg="$(decline_copy_guard "$RENDERED" 2>&1)"; then
  ledger finalize --message-row "$ROW_ID" --status refused --reason "${dg:0:200}" >/dev/null
  refuse "$dg"
fi
# The proof-refusal's lint again, on the CLAIMED credits (the render the customer would get).
if ! rg="$(refusal_copy_guard "$CLAIMED_INPUT" 2>&1)"; then
  ledger finalize --message-row "$ROW_ID" --status refused --reason "${rg:0:200}" >/dev/null
  refuse "$rg"
fi
PAYLOAD="$(payload "$RENDERED" "$CONTACT_ID")"
# ---------------------------------------------------------------------------------------
# THE OUTBOUND COPY GATE. The exact bytes about to be POSTed (.body, and the subject when there is one) go to the gate,
# which answers "approved" only when the reviewer's SIGNED verdict on this body's sha256 is on file, under today's
# rubric, for this campaign. Everything else - no verdict yet (the body is queued for review), a rewrite or refuse
# verdict, a hard-rule hit, a bad signature, a gate that cannot run - gives the claim back (a `deferred` log row with
# the reason and the hash) and sends NOTHING. There is no flag, variable or campaign that skips this, and it runs
# before the reassign below, so an unreviewed note has no side effect at all.
#
# OBSERVE MODE is the gate's answer, never this script's choice: for a campaign policies/outbound-copy-enforce.json
# does not enforce yet, the gate exits 4 with result "observed" about these bytes. The note is then sent and the
# ledger row says `observed:<what the review said>` instead of `approved`. A code-lint hit, a signed refusal and a
# retired frame are exit 1 in either mode, so they are held here like any other non-approval.
COPY_SHA_LOCAL="$(printf '%s' "$PAYLOAD" | "$JQ_BIN" -j '.body' | "$PY_BIN" -I -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
set +e
# `data` declares the request's own values (the first name, each credit's role, title and artist) so a song called
# "Fraud" is not read as our accusation. It excuses those values only; every sentence, in a list item or not, is copy.
CG="$(printf '%s\n%s\n' "$PAYLOAD" "$CLAIMED_INPUT" | "$JQ_BIN" -c -s '
      {subject: (.[0].subject // ""), body: .[0].body,
       data: ([(.[1].user.first_name? // empty), (.[1].credits[]? | (.role?, .track_title?, .artist_name?))]
              | map(select(type == "string" and length > 0)))}' \
  | "$PY_BIN" -I "$COPY_GATE" check --campaign "$CAMPAIGN" --copy "$COPY" --kind "$KIND" --message-type "$MESSAGE_TYPE" \
      --store "$COPY_STORE" 2>/dev/null)"
cg_rc=$?
set -e
CG_RESULT="$(printf '%s' "$CG" | "$JQ_BIN" -r '.result // ""' 2>/dev/null || true)"
COPY_VERDICT_ID="$(printf '%s' "$CG" | "$JQ_BIN" -r '.verdict_id // ""' 2>/dev/null || true)"
COPY_VERDICT_SHA="$(printf '%s' "$CG" | "$JQ_BIN" -r '.verdict_sha256 // ""' 2>/dev/null || true)"
CG_BODY="$(printf '%s' "$CG" | "$JQ_BIN" -r '.body_sha256 // ""' 2>/dev/null || true)"
CG_MODE="$(printf '%s' "$CG" | "$JQ_BIN" -r '.mode // ""' 2>/dev/null || true)"
CG_REVIEW="$(printf '%s' "$CG" | "$JQ_BIN" -r '.review // ""' 2>/dev/null || true)"
COPY_REVIEW=""
if [ "$cg_rc" = 0 ] && [ "$CG_RESULT" = "approved" ] && [ "$CG_BODY" = "$COPY_SHA_LOCAL" ] \
   && [[ "$COPY_VERDICT_ID" =~ ^ocv-[0-9a-f]{16}$ ]] && [[ "$COPY_VERDICT_SHA" =~ ^[0-9a-f]{64}$ ]]; then
  COPY_REVIEW="approved"
elif [ "$cg_rc" = 4 ] && [ "$CG_RESULT" = "observed" ] && [ "$CG_MODE" = "observe" ] && [ "$CG_BODY" = "$COPY_SHA_LOCAL" ] \
   && [[ "$CG_REVIEW" =~ ^[a-z_]{1,40}$ ]]; then
  # the verdict on file, when there is one (a rewrite), still goes on the row; a malformed one is dropped, not trusted
  [[ "$COPY_VERDICT_ID" =~ ^ocv-[0-9a-f]{16}$ ]] && [[ "$COPY_VERDICT_SHA" =~ ^[0-9a-f]{64}$ ]] || { COPY_VERDICT_ID=""; COPY_VERDICT_SHA=""; }
  COPY_REVIEW="observed:$CG_REVIEW"
fi
# uvn-reminder-14, uvn-new-rows and proof-refusal have no standing copy approval, so only a SIGNED approve of these
# bytes sends them. The policy lists all three under `enforce`; this is the belt for the day that file is edited or
# replaced: an `observed` pass is a hold here.
SIGNED_ONLY_OBSERVED=0
if { [ "$CAMPAIGN" = "uvn-reminder-14" ] || [ "$CAMPAIGN" = "uvn-new-rows" ] || [ "$CAMPAIGN" = "proof-refusal" ]; } && [ "$COPY_REVIEW" != "approved" ]; then
  [ -z "$COPY_REVIEW" ] || SIGNED_ONLY_OBSERVED=1
  COPY_REVIEW=""
fi
if [ -z "$COPY_REVIEW" ]; then
  cg_why="$(printf '%s' "$CG" | "$JQ_BIN" -r '.reason // ""' 2>/dev/null || true)"
  [ -n "$cg_why" ] || cg_why="copy_gate_error:the gate gave no readable answer (rc=$cg_rc)"
  if { [ "$cg_rc" = 0 ] && [ "$CG_RESULT" = "approved" ]; } || [ "$cg_rc" = 4 ]; then cg_why="copy_gate_error:the gate's answer does not name this body or a verdict"; fi
  [ "$SIGNED_ONLY_OBSERVED" != "1" ] || cg_why="copy_review_required:$CAMPAIGN sends only on a signed approve, and the gate answered in observe mode"
  ledger hold-copy-review --message-row "$ROW_ID" --reason "copy_review_hold: ${cg_why:0:300}" --body-sha256 "$COPY_SHA_LOCAL" >/dev/null \
    || die "the copy gate did not approve this message and the hold could not be ledgered; nothing was sent (row $ROW_ID stays claimed for a human)."
  printf 'DEFERRED %s credits=%s (the outbound copy gate has not approved this exact message; nothing was sent)\n' "${cg_why%%:*}" "$NC"
  exit 3
fi
readonly COPY_SHA_LOCAL COPY_VERDICT_ID COPY_VERDICT_SHA COPY_REVIEW
# [key=lamberto-reply-due]: the handed answer went unsent for 48 h - reassign to this gate (+ note), ledger row FIRST,
# then the answer. Any failure: the claim is closed refused and nothing is posted to the customer.
if [ "$RD_ACT" = "reassign+answer" ]; then
  # QA #1517: re-read the thread IMMEDIATELY before taking it over - a human comment since the handoff note (the human
  # answered after comm_state's read) means the answer is theirs: hold, nothing reassigned or posted
  hnow="$(api GET "/conversations/$THREAD?display_as=plaintext")" \
    || { ledger finalize --message-row "$ROW_ID" --status refused --reason "pre-reassign read failed" >/dev/null; refuse "the pre-reassign read of $THREAD failed; nothing was sent."; }
  # QA #1517 (b1 00:36Z): the SAME checks as the final read, on this post-claim snapshot (the claim closes refused)
  rc=0; rd_thread_checks "$hnow" || rc=$?
  if [ "$rc" != 0 ]; then
    ledger finalize --message-row "$ROW_ID" --status refused --reason "takeover read: ${RD_HOLD:0:200}" >/dev/null
    if [ "$rc" = 1 ]; then
      printf 'HELD %s credits=%s; nothing reassigned\n' "${RD_HOLD%% *}" "$N"; printf '  %s\n' "${RD_HOLD#* }"; exit 3
    fi
    refuse "the takeover read of $THREAD could not be verified ($RD_HOLD); nothing was sent."
  fi
  RNOTE="$(assign_to_gate "$THREAD" "<p>$REASSIGN_NOTE</p>")" \
    || { ledger finalize --message-row "$ROW_ID" --status refused --reason "reassign failed" >/dev/null; refuse "reassign failed on conversation $THREAD; nothing was sent."; }
  ledger thread-event --kind reassign --conversation "$THREAD" --from-admin "$RD_ASG" --to-admin "$INTERCOM_ADMIN_ID" --note-part "$RNOTE" \
    --reply-due "$REPLY_DUE" --request-ids "$ALL_IDS" --user-id "$USER_ID" --approved-by "$APPROVED_BY" --approval-ref "$APPROVAL_REF" >/dev/null \
    || { ledger finalize --message-row "$ROW_ID" --status refused --reason "reassign ledger write failed" >/dev/null; refuse "the reassign of $THREAD could not be ledgered; nothing was sent."; }
fi
BODY_SHA="$(printf '%s' "$PAYLOAD" | "$JQ_BIN" -r '.body' | "$PY_BIN" -I -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
# p1 565 (t01b's read-back, ledger 6360): Intercom re-formats the HTML it stores (newlines, entities), so the post-check
# and the reconcile compare the body's NORMALISED TEXT (tags out, the entities the renderer emits decoded, whitespace
# collapsed) - sha256 of it is logged with the post (text_sha256)
readonly NTEXT_JQ='def ntext: gsub("<[^>]+>"; " ") | gsub("&nbsp;"; " ") | gsub("&quot;"; "\"") | gsub("&#39;|&#x27;|&apos;"; "'"'"'")
  | gsub("&lt;"; "<") | gsub("&gt;"; ">") | gsub("&amp;"; "&") | gsub("\\s+"; " ") | gsub("^ | $"; "");'
TEXT_SHA="$(printf '%s' "$PAYLOAD" | "$JQ_BIN" -r "$NTEXT_JQ"' .body | ntext' | "$PY_BIN" -I -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read().rstrip(b"\n")).hexdigest())')"

# QA #1615 (b1 634): the pick, re-read IMMEDIATELY before the POST (the claim is closed refused if it moved)
if [ "$CAMPAIGN" = "reply-ref" ] && [ "$ACTION" = "post" ]; then
  rc=0; pick_unchanged || rc=$?
  if [ "$rc" != 0 ]; then
    ledger finalize --message-row "$ROW_ID" --status refused --reason "pre-post pick read: ${RD_HOLD:0:200}" >/dev/null
    if [ "$rc" = 1 ]; then printf 'HELD %s credits=%s; nothing was sent\n' "${RD_HOLD%% *}" "$N"; printf '  %s\n' "${RD_HOLD#* }"; exit 3; fi
    refuse "the pre-post pick read could not be verified ($RD_HOLD); nothing was sent."
  fi
fi
# ---------------------------------------------------------------------------------------
# Log BEFORE the write, then POST, then verify.
LOG_FILE="$(new_log_file verify-request "$CONTACT_ID")"
"$JQ_BIN" -nc --arg target "user:$CONTACT_ID" --arg mt "$MESSAGE_TYPE" --arg appr "$APPROVED_BY" --arg thread "$THREAD" \
  --arg ref "$APPROVAL_REF" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sha "$BODY_SHA" --arg tsha "$TEXT_SHA" \
  --arg campaign "$CAMPAIGN" --arg kind "$KIND" --arg parent "$PARENT_ID" --arg due "$DUE_DAY" \
  --arg copy "$COPY" --arg removal "$REMOVAL_DAY" --arg legacy "$LEGACY_MATCH" \
  --argjson ids "$(printf '%s' "$CLAIMED_INPUT" | "$JQ_BIN" -c '[.credits[].request_id]')" --arg row "$ROW_ID" \
  --arg cvid "$COPY_VERDICT_ID" --arg cvsha "$COPY_VERDICT_SHA" --arg csha "$COPY_SHA_LOCAL" --arg crev "$COPY_REVIEW" \
  '{agent:"operations", action:"intercom_verify_request", campaign:$campaign, kind:$kind,
    copy_verdict_id:$cvid, copy_verdict_sha256:$cvsha, copy_body_sha256:$csha, copy_review:$crev,
    parent_message:(if $parent == "" then null else $parent end), due_day:(if $due == "" then null else $due end),
    copy:$copy, removal_day:(if $removal == "" then null else $removal end),
    target:$target, conversation:(if $thread == "" then null else $thread end),
    message_type:$mt, request_ids:$ids, ledger_row:($row|tonumber), approved_by:$appr,
    approval_ref:$ref, body_sha256:$sha, text_sha256:$tsha, admin_id:"'"$INTERCOM_ADMIN_ID"'", timestamp:$ts,
    recipient_match:(if $legacy == "" then "id" else "in-thread-legacy-id " + $legacy end),
    authorization:"captain approved this verify-request campaign (fixed copy); see approval_ref"}' > "$LOG_FILE"

if [ -n "$THREAD" ]; then POST_PATH="/conversations/$THREAD/reply"; else POST_PATH="/messages"; fi
# the copy gate ruled on COPY_SHA_LOCAL: the bytes leaving now must still be those bytes
if [ "$(printf '%s' "$PAYLOAD" | "$JQ_BIN" -j '.body' | "$PY_BIN" -I -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')" != "$COPY_SHA_LOCAL" ]; then
  ledger finalize --message-row "$ROW_ID" --status refused --reason "copy gate: the body changed after its verdict" >/dev/null
  refuse "the body changed after the copy gate ruled on it; nothing was sent."
fi
set +e
RESPONSE="$(printf '%s' "$PAYLOAD" | api POST "$POST_PATH")"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  # r8 (firstmate 771) (2): a SEND that may have landed must not share an exit code with a PRE-SEND check failure.
  # rc 4 has always meant "nothing was sent" (every check above it fails before claiming); a POST that failed or that we
  # cannot verify is a DIFFERENT fact - the body may already be in the customer's inbox - so it exits 5. A caller that
  # merely tests "non-zero" still stops; a caller that decides what to retry can now tell the two apart without reading
  # prose.
  ledger finalize --message-row "$ROW_ID" --status attempted --reason "curl rc=$rc; outcome unknown" --api-log "$LOG_FILE" --copy-verdict-id "$COPY_VERDICT_ID" --copy-verdict-sha256 "$COPY_VERDICT_SHA" --copy-review "$COPY_REVIEW" >/dev/null || true
  printf 'POST FAILED (curl rc=%s); logged at %s and left CLAIMED (outcome unknown, so it is never re-sent automatically). Response:\n%s\n' \
    "$rc" "$LOG_FILE" "$RESPONSE" >&2
  exit 5
fi
R_TYPE="$(printf '%s' "$RESPONSE" | "$JQ_BIN" -r '.type // empty' 2>/dev/null || true)"
if [ -n "$THREAD" ]; then
  # Intercom answers a reply with the whole conversation; the part just created is the last one.
  R_CONV="$(printf '%s' "$RESPONSE" | "$JQ_BIN" -r '.id // empty | tostring' 2>/dev/null || true)"
  R_ID="$(printf '%s' "$RESPONSE" | "$JQ_BIN" -r '(.conversation_parts.conversation_parts // [])[-1].id // empty | tostring' 2>/dev/null || true)"
  R_PART="$(printf '%s' "$RESPONSE" | "$JQ_BIN" -r '(.conversation_parts.conversation_parts // [])[-1] | "\(.part_type // "")/\(.author.type // "")/\(.author.id // "")"' 2>/dev/null || true)"
  # p1 565: replying into an UNASSIGNED thread, Intercom stores our reply as an ASSIGNMENT part (it assigns the thread to
  # us) carrying the body. That is POSTED when it is ours AND its normalised text is exactly what we sent.
  if [ "$R_PART" = "assignment/admin/$INTERCOM_ADMIN_ID" ]; then
    R_TEXT_SHA="$(printf '%s' "$RESPONSE" | "$JQ_BIN" -r "$NTEXT_JQ"' (.conversation_parts.conversation_parts // [])[-1].body // "" | ntext' 2>/dev/null \
      | "$PY_BIN" -I -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read().rstrip(b"\n")).hexdigest())' 2>/dev/null || true)"
    [ "$R_TEXT_SHA" != "$TEXT_SHA" ] || R_PART="comment/admin/$INTERCOM_ADMIN_ID"
  fi
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
    ledger finalize --message-row "$ROW_ID" --status attempted --reason "unverified reply type=${R_TYPE:-none} part=${R_PART:-none}" --api-log "$LOG_FILE" --copy-verdict-id "$COPY_VERDICT_ID" --copy-verdict-sha256 "$COPY_VERDICT_SHA" --copy-review "$COPY_REVIEW" >/dev/null || true
    printf 'POST NOT VERIFIED: expected a Caroline comment in conversation %s, Intercom answered type "%s" last part "%s". Logged at %s; left CLAIMED. Response:\n%s\n' \
      "$THREAD" "${R_TYPE:-<none>}" "${R_PART:-<none>}" "$LOG_FILE" "$RESPONSE" >&2
    exit 5     # rc 5: attempted, outcome unknown (rc 4 = nothing was sent)
  fi
elif [ "$R_TYPE" != "admin_message" ] || [ "$R_MT" != "$(if [ "$MESSAGE_TYPE" = "inapp" ]; then echo inapp; else echo "$EXPECT_TYPE"; fi)" ] \
     || ! printf '%s' "$R_ID" | grep -qE '^[0-9]+$'; then
  ledger finalize --message-row "$ROW_ID" --status attempted --reason "unverified response type=${R_TYPE:-none} message_type=${R_MT:-none}" --api-log "$LOG_FILE" --copy-verdict-id "$COPY_VERDICT_ID" --copy-verdict-sha256 "$COPY_VERDICT_SHA" --copy-review "$COPY_REVIEW" >/dev/null || true
  printf 'POST NOT VERIFIED: expected an admin_message of type "%s", Intercom answered type "%s" message_type "%s". Logged at %s; left CLAIMED. Response:\n%s\n' \
    "$(if [ "$MESSAGE_TYPE" = "inapp" ]; then echo inapp; else echo "$EXPECT_TYPE"; fi)" "${R_TYPE:-<none>}" "${R_MT:-<none>}" "$LOG_FILE" "$RESPONSE" >&2
  exit 5     # rc 5: attempted, outcome unknown (rc 4 = nothing was sent)
fi
ledger finalize --message-row "$ROW_ID" --status sent --message-id "$R_ID" --conversation-id "$R_CONV" \
  --body-sha256 "$BODY_SHA" --api-log "$LOG_FILE" ${LEGACY_MATCH:+--reason "in-thread-legacy-id $LEGACY_MATCH"} \
  --copy-verdict-id "$COPY_VERDICT_ID" --copy-verdict-sha256 "$COPY_VERDICT_SHA" --copy-review "$COPY_REVIEW" >/dev/null
if [ -n "$THREAD" ]; then
  printf 'POSTED %s conversation=%s message=%s credits=%s\n' "$MESSAGE_TYPE" "$THREAD" "$R_ID" "$NC"
elif [ "$KIND" = "initial" ]; then
  printf 'POSTED %s message=%s credits=%s\n' "$MESSAGE_TYPE" "$R_ID" "$NC"
else
  printf 'POSTED %s %s message=%s credits=%s\n' "$KIND" "$MESSAGE_TYPE" "$R_ID" "$NC"
fi
