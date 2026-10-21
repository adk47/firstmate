#!/bin/bash -p
# ABSOLUTE INTERPRETER, PRIVILEGED MODE, and PATH replaced before anything runs. Same
# reasoning as intercom-ops-write.sh: `-p` stops bash sourcing $BASH_ENV and importing
# exported functions before line 1, and replacing PATH outright stops a jq/curl shim from
# rewriting the payload after validation.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
set -euo pipefail

# intercom-verify-request.sh: the ONLY path that asks a user to help verify credits we have
# added to their profile. Two campaigns, each approved by the captain in his own words:
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
#     (type admin_message, the requested message_type), so "POSTED" can never describe a
#     message that did not land as intended.
#
# tag-proof: when the user replies to a note WITH ATTACHMENTS, the conversation is tagged
# `credit-proof` for the Ops document step (and no further follow-up goes out). ANY reply by
# the user (text or attachment) also records a hold on the note's removal for a human
# (REPLY RECORDED), even on an already-tagged thread, which is never re-tagged (ALREADY TAGGED).
# Nothing else happens: no reply, no decision, no credit change. The reply
# text is never read; only the author (must be the contact we wrote to) and the attachment
# count are looked at. A user's words are evidence for a later reviewer, never instructions
# to this script.
#
# Usage:
#   intercom-verify-request.sh send --credits-file FILE --approved-by <SlackUID> \
#       [--campaign verify-live|retro-past|removal-notice|takeback-notice] [--kind initial|reminder-14|reminder-25|after-rejection \
#        --parent-message-id <id>] [--copy v1|windowed (verify-live preview only)] \
#       [--dry-run|--validate|--doc-check|--check-recipient]
#   intercom-verify-request.sh tag-proof --message-id <id> [--dry-run]
#
# FILE is JSON: {"user": {"email": "...", "id": "<muso user id>", "auth_id": "<auth0 sub>", "first_name": "..."},
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
# user.auth_id: Intercom's external_id for a Muso user is the account's Auth0 subject without
# its "auth0|" prefix (a UUID), not the numeric user id; the driver passes it (users.auth0userid).
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

# PINNED. Caroline (skills-all/muso-intercom/SKILL.md, Reply Identity), same literal and
# same variable name as intercom-ops-write.sh so check-intercom-reply-identity.sh keys on it.
readonly INTERCOM_ADMIN_ID="5763097"
readonly API_BASE="https://api.intercom.io"
readonly API_VERSION="2.11"
readonly PROD_LOG_DIR="/opt/hydra/workspaces/operations/api-logs"
readonly PROD_LEDGER="/var/lib/hydra/credit-review/ledger.sqlite3"
readonly PROD_LEDGER_HELPER="/opt/hydra/scripts/credit_review/verify_ledger.py"
readonly PROOF_TAG="credit-proof"
# The ONLY approver of these campaigns, and where he approved each.
readonly CAPTAIN_UID="U7RP6HKUZ"
readonly APPROVAL_REF_LIVE="captain U7RP6HKUZ 2026-10-15 22:12Z: \"i want AI live now - we have too many credits to approve and to get supporting data for - let users know where there was a credit given and that it needs support (trust yet verify approach)\""
readonly APPROVAL_REF_LIVE_WINDOWED="$APPROVAL_REF_LIVE; 2026-10-15 23:40Z: \"if no valid verification comes it should be removed\" (kept for new provisional approvals at 2026-10-16 00:35Z); copy = Fable copy-review-fable-2026-10-17 pack 1 (GO with edits); enable = Fable decision-verify-notify-enable-2026-10-17 (firstmate 051, 2026-10-17 23:15Z: enable Monday 2026-10-20 under its 7 conditions)"
readonly APPROVAL_REF_LIVE_V1="$APPROVAL_REF_LIVE; paid provisional approvals: Fable credit-backlog-1019 ruling 4 as amended by firstmate 073 (2026-10-19 14:58Z: provisional approve + doc request, NO day-30 auto-removal, no removal language; captain rule 10-15: deletes must confirm removal at Spotify/Tidal or prove a different profile)"
readonly APPROVAL_REF_TAKEBACK="captain via firstmate 012, 2026-10-16: every take-back sends the user a short, polite message saying which credit and role, why (who the public credits name, with the link), and how to dispute it by replying with a document."
readonly APPROVAL_REF_REMOVAL="firstmate 2026-10-16 15:14Z, captain-driven: owners of credits WE removed must be told which credit and role, why, and how to dispute by replying with a document (support measured 35 owners never told). Fraud removals stay silent by captain order (firstmate 2026-10-16 15:48Z)."
readonly APPROVAL_REF_PAST="captain U7RP6HKUZ 2026-10-15 23:35Z: \"im referring to before when nick made changes and did a trust verify flow and now we have a lotnof credits to verify with documents and give people 30 days to send something in for the ones missing documents\"; 2026-10-16 00:35Z: \"how many credits were approved without documentstion i dont want to lose users unless its obvious fraud feom tbe past\""
# Caroline's outbound sanitizer word list, IDENTICAL to intercom-ops-write.sh's
# SANITIZER_WORDS (which CI compares to plugins/intercom/src/sanitize-tool-leak.ts);
# scripts/tests/intercom-verify-request.bats fails if the two lines ever differ.
readonly SANITIZER_WORDS="profile_status|profile_lookup|credits_search|create_ticket|subscription_status|remove_credits|dedupe_check|credit_verification_check|profiles_claim_self|credits_verify|profiles_consolidate|order_lookup|order_address_update|founding_status|founding_buyback_link|support_action_router|memory_search|memory_get|profile_analytics_status|profile_credits_status|profile_claim_status|retention_offer_check|retention_offer_apply|cancel_subscription|billing_status|track_analytics_status|analytics_refresh_request|analytics_recheck|subscription_cancel|refund_policy_check|refund_create|catalog_status|track_lookup|metadata_capture_request|artwork_refresh_request|catalog_recheck|user_status|resend_verification|email_delivery_status|login_recovery_packet|profile_change_packet|profile_merge_check|account_merge_preflight|email_change_preflight|profile_removal_preflight|ticket|tool failed|error fetching|unable to look up|the system says|my system|there was an issue with|ClickUp|openclaw|HYDRA|platform-data-processing"

die()    { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
refuse() { printf 'REFUSED: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------------------
# Deployed copies reject EVERY override before anything else can run.
if [ "$TESTABLE" != "1" ]; then
  for v in INTERCOM_VERIFY_TEST_LOG_DIR INTERCOM_VERIFY_TEST_CURL_BIN INTERCOM_VERIFY_TEST_TIMEOUT_BIN \
           INTERCOM_VERIFY_TEST_LEDGER INTERCOM_VERIFY_TEST_LEDGER_HELPER INTERCOM_VERIFY_TEST_DAY; do
    [ -z "${!v:-}" ] || die "$v is not settable on a deployed copy of this script. The log, the ledger, the client and the clock are not parameters: a caller-selectable one is a send nobody can audit."
  done
  LOG_DIR="$PROD_LOG_DIR"
  LEDGER="$PROD_LEDGER"
  LEDGER_HELPER="$PROD_LEDGER_HELPER"
  CURL_BIN="/usr/bin/curl"
  JQ_BIN="/usr/bin/jq"
  TIMEOUT_BIN="/usr/bin/timeout"
  PY_BIN="/usr/bin/python3"
  DAY="$(date -u +%Y-%m-%d)"
else
  LOG_DIR="${INTERCOM_VERIFY_TEST_LOG_DIR:-$PROD_LOG_DIR}"
  LEDGER="${INTERCOM_VERIFY_TEST_LEDGER:-$PROD_LEDGER}"
  LEDGER_HELPER="${INTERCOM_VERIFY_TEST_LEDGER_HELPER:-$PROD_LEDGER_HELPER}"
  CURL_BIN="${INTERCOM_VERIFY_TEST_CURL_BIN:-$(command -v curl || echo /usr/bin/curl)}"
  JQ_BIN="$(command -v jq || echo /usr/bin/jq)"
  TIMEOUT_BIN="${INTERCOM_VERIFY_TEST_TIMEOUT_BIN:-$(command -v timeout || command -v gtimeout || echo /usr/bin/timeout)}"
  PY_BIN="$(command -v python3 || echo /usr/bin/python3)"
  DAY="${INTERCOM_VERIFY_TEST_DAY:-$(date -u +%Y-%m-%d)}"
fi
readonly LOG_DIR LEDGER LEDGER_HELPER CURL_BIN JQ_BIN TIMEOUT_BIN PY_BIN DAY

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

# Email through Intercom (POST /messages, message_type email) is the only channel: Intercom
# delivers it to the user's inbox and the reply lands in the same conversation.
CREDITS_FILE="" APPROVED_BY="" MESSAGE_ID="" ACTION="post"
readonly MESSAGE_TYPE="email" REQ_TYPE="email" EXPECT_TYPE="email"
CAMPAIGN="verify-live" KIND="initial" PARENT_ID="" CAMPAIGN_SET=0 KIND_SET=0 COPY_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --credits-file|--approved-by|--message-id|--campaign|--kind|--parent-message-id|--copy)
      [ $# -ge 2 ] || { usage; die "$1 needs a value"; }
      case "$1" in
        --credits-file)      CREDITS_FILE="$2" ;;
        --approved-by)       APPROVED_BY="$2" ;;
        --message-id)        MESSAGE_ID="$2" ;;
        --campaign)          CAMPAIGN="$2"; CAMPAIGN_SET=1 ;;
        --kind)              KIND="$2"; KIND_SET=1 ;;
        --parent-message-id) PARENT_ID="$2" ;;
        --copy)              COPY_ARG="$2" ;;
      esac
      shift 2 ;;
    --dry-run)  ACTION="dry-run"; shift ;;
    --doc-check) ACTION="doc-check"; shift ;;
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
if [ "$ACTION" = "post" ] || [ "$ACTION" = "doc-check" ] || [ "$ACTION" = "check-recipient" ] || [ "$MODE" = "tag-proof" ]; then
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
  [ -z "$CREDITS_FILE$APPROVED_BY$PARENT_ID$COPY_ARG" ] && [ "$CAMPAIGN_SET$KIND_SET" = "00" ] \
    || refuse "tag-proof takes only --message-id; it sends nothing to the user."
  [ "$ACTION" != "validate" ] && [ "$ACTION" != "doc-check" ] && [ "$ACTION" != "check-recipient" ] \
    || refuse "--validate, --doc-check and --check-recipient apply to send only."
  printf '%s' "$MESSAGE_ID" | grep -qE '^[0-9]{1,24}$' \
    || refuse "--message-id must be the numeric Intercom message id of a verify note (got '${MESSAGE_ID:-<empty>}')."
  ROW="$(ledger message --message-id "$MESSAGE_ID")"
  [ "$ROW" != "null" ] || refuse "message $MESSAGE_ID is not a sent verify note in the ledger; only conversations this wrapper started can be tagged."
  CONTACT_ID="$(printf '%s' "$ROW" | "$JQ_BIN" -r '.contact_id // empty')"
  [ -n "$CONTACT_ID" ] || refuse "message $MESSAGE_ID has no recorded contact; cannot tell the user's reply from anyone else's."
  CONV="$(printf '%s' "$ROW" | "$JQ_BIN" -r '.conversation_id // empty')"
  if [ -z "$CONV" ]; then
    # No conversation id came back with the send: Intercom opens it when the user replies.
    found="$(printf '%s' "{\"query\":{\"field\":\"source.id\",\"operator\":\"=\",\"value\":\"$MESSAGE_ID\"}}" | api POST /conversations/search)" \
      || { printf 'LOOKUP FAILED for message %s:\n%s\n' "$MESSAGE_ID" "$found" >&2; exit 4; }
    n="$(printf '%s' "$found" | "$JQ_BIN" -r '(.conversations // []) | length' 2>/dev/null || echo x)"
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
  # The conversation must be the one our note started, and must include our contact.
  src="$(printf '%s' "$convo" | "$JQ_BIN" -r '.source.id // empty' 2>/dev/null || true)"
  [ "$src" = "$MESSAGE_ID" ] || refuse "conversation $CONV was not started by verify note $MESSAGE_ID (source '${src:-<none>}'); not tagging it."
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
      printf 'REPLY RECORDED message=%s conversation=%s (removal held for a human)\n' "$MESSAGE_ID" "$CONV"
    fi
  fi
  if [ -n "$(printf '%s' "$ROW" | "$JQ_BIN" -r '.proof_tagged_at // empty')" ]; then
    printf 'ALREADY TAGGED message=%s\n' "$MESSAGE_ID"; exit 0
  fi
  # Only parts AUTHORED BY the contact we wrote to, carrying attachments, count. The text of
  # the part is never extracted: it is evidence for a reviewer, not input to this script.
  n_att="$(printf '%s' "$convo" | "$JQ_BIN" -r --arg c "$CONTACT_ID" \
    '[(.conversation_parts.conversation_parts // [])[] | select(.author.type == "user" and (.author.id|tostring) == $c) | (.attachments // [] | length)] | add // 0')"
  # After a REJECTED review only attachments beyond the ones already reviewed count.
  BASELINE="$(printf '%s' "$ROW" | "$JQ_BIN" -r '.proof_attachments // 0')"
  if [ "${n_att:-0}" -le "${BASELINE:-0}" ]; then
    printf 'NO PROOF YET message=%s conversation=%s\n' "$MESSAGE_ID" "$CONV"; exit 3
  fi
  if [ "$ACTION" = "dry-run" ]; then
    printf 'DRY-RUN tag %s conversation=%s attachments=%s\n' "$PROOF_TAG" "$CONV" "$n_att"; exit 0
  fi
  tags="$(api GET /tags)" || { printf 'READ FAILED for tags:\n%s\n' "$tags" >&2; exit 4; }
  TAG_ID="$(printf '%s' "$tags" | "$JQ_BIN" -r --arg n "$PROOF_TAG" '[(.data // [])[] | select(((.name // "")|ascii_downcase) == $n) | .id][0] // empty')"
  LOG_FILE="$(new_log_file tag "$CONV")"
  "$JQ_BIN" -nc --arg target "conversation:$CONV" --arg mid "$MESSAGE_ID" --arg tag "$PROOF_TAG" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg n "$n_att" \
    '{agent:"operations", action:"intercom_tag_credit_proof", target:$target, verify_message:$mid, tag:$tag, attachments:($n|tonumber), timestamp:$ts, authorization:"verify-request proof routing: tag only, no reply, no decision"}' > "$LOG_FILE"
  if [ -z "$TAG_ID" ]; then
    created="$(printf '{"name":"%s"}' "$PROOF_TAG" | api POST /tags)" || { printf 'TAG CREATE FAILED:\n%s\n' "$created" >&2; exit 4; }
    TAG_ID="$(printf '%s' "$created" | "$JQ_BIN" -r 'select(.type == "tag") | .id // empty' 2>/dev/null || true)"
    [ -n "$TAG_ID" ] || { printf 'TAG CREATE NOT VERIFIED:\n%s\n' "$created" >&2; exit 4; }
  fi
  resp="$("$JQ_BIN" -nc --arg id "$TAG_ID" --arg a "$INTERCOM_ADMIN_ID" '{id:$id, admin_id:$a}' | api POST "/conversations/$CONV/tags")" \
    || { printf 'TAG FAILED for conversation %s; logged at %s:\n%s\n' "$CONV" "$LOG_FILE" "$resp" >&2; exit 4; }
  got="$(printf '%s' "$resp" | "$JQ_BIN" -r 'select(.type == "tag") | .name // empty' 2>/dev/null || true)"
  if [ "$(printf '%s' "$got" | tr '[:upper:]' '[:lower:]')" != "$PROOF_TAG" ]; then
    printf 'TAG NOT VERIFIED for conversation %s; logged at %s. Response:\n%s\n' "$CONV" "$LOG_FILE" "$resp" >&2; exit 4
  fi
  ledger mark-tagged --message-id "$MESSAGE_ID" --conversation-id "$CONV" --attachments "$n_att" >/dev/null
  printf 'TAGGED %s conversation=%s message=%s attachments=%s\n' "$PROOF_TAG" "$CONV" "$MESSAGE_ID" "$n_att"
  exit 0
fi

# =======================================================================================
# send: validation. Every refusal says how to comply.
[ -z "$MESSAGE_ID" ] || refuse "--message-id applies to tag-proof only."
[ "$ACTION" != "doc-check" ] || [ "$KIND" = "initial" ] || refuse "--doc-check applies to an initial note."
case "$KIND" in
  initial|reminder-14|reminder-25|after-rejection) ;;
  *) refuse "--kind must be initial, reminder-14, reminder-25 or after-rejection (got '$KIND')." ;;
esac
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
  *) refuse "--campaign must be verify-live, retro-past, removal-notice or takeback-notice (got '$CAMPAIGN'). Each campaign is pinned in this script; there is no other." ;;
esac
[ "$ACTION" != "check-recipient" ] || { [ "$CAMPAIGN" = "verify-live" ] && [ "$KIND" = "initial" ]; } \
  || refuse "--check-recipient applies to a verify-live initial note only (it must never reach a path that writes)."
[ "$ACTION" != "doc-check" ] || [ "$CAMPAIGN" = "retro-past" ] \
  || refuse "--doc-check applies to --campaign retro-past only: a removal notice is not an ask, and a new credit's note is never skipped for an Intercom attachment."
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
            first_name: ((.user.first_name // "") | clean) },
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

EMAIL="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '.user.email')"
USER_ID="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '.user.id')"
AUTH_ID="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '.user.auth_id')"
printf '%s' "$EMAIL" | grep -qE '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$' \
  || refuse "user.email must be the credit request's account email (got an invalid value)."
[ -z "$USER_ID" ] || printf '%s' "$USER_ID" | grep -qE '^[A-Za-z0-9-]{1,64}$' \
  || refuse "user.id must be the Muso user id (letters, digits, dashes)."
[ -z "$AUTH_ID" ] || printf '%s' "$AUTH_ID" | grep -qE '^[A-Za-z0-9._-]{1,128}$' \
  || refuse "user.auth_id must be the account's Auth0 subject (letters, digits, dot, dash, underscore)."
N="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '.credits | length')"
[ "$N" -ge 1 ] || refuse "credits is empty; there is nothing to ask the user to verify."
[ "$N" -le "$MAX_CREDITS" ] || refuse "credits has $N entries; at most $MAX_CREDITS per $CAMPAIGN note."
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
  badsrc="$(printf '%s' "$INPUT" | "$JQ_BIN" -r '[.credits[] | select(.reason == "misattributed" and (.source_label | IN("Spotify credits","Tidal credits","Qobuz credits page","Apple Music credits","Discogs","AllMusic","MusicBrainz","Jaxsta") | not))] | length')"
  [ "$badsrc" -eq 0 ] || refuse "$badsrc misattributed credit(s) lack a source_label from the fixed list (Spotify credits, Tidal credits, Qobuz credits page, Apple Music credits, Discogs, AllMusic, MusicBrainz, Jaxsta)."
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

ids_csv() { printf '%s' "$1" | "$JQ_BIN" -r '[.credits[].request_id] | join(",")'; }
keep_ids() { # <input-json> <ids-json-array>
  printf '%s' "$1" | "$JQ_BIN" -c --argjson ids "$2" '.credits |= [.[] | select(.request_id as $r | $ids | index($r))]'
}
add_days() { "$PY_BIN" -I -c 'import datetime,sys; print((datetime.date.fromisoformat(sys.argv[1]) + datetime.timedelta(days=int(sys.argv[2]))).isoformat())' "$1" "$2"; }
day_label() { "$PY_BIN" -I -c 'import datetime,sys; d=datetime.date.fromisoformat(sys.argv[1]); print(f"{d:%B} {d.day}")' "$1"; }

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
    done_why="$(printf '%s' "$peek" | "$JQ_BIN" -r '.user_done // empty')"
    if [ -n "$done_why" ]; then
      # retro-past: one message per user ever, none after a proof reply. Close the rows so
      # the wave never offers them again.
      ledger skip --campaign "$CAMPAIGN" --request-ids "$(printf '%s' "$pending" | "$JQ_BIN" -r 'join(",")')" >/dev/null \
        || die "the ledger write failed."
      printf 'SKIPPED %s credits=%s\n' "$done_why" "$(printf '%s' "$pending" | "$JQ_BIN" -r 'length')"; exit 0
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
# Windowed copy names ONE date (Fable copy review 2026-10-17): the reply-by date, 30 days
# after the note; replying by the end of that day is in time, and an unverified credit is
# removal-due only from the day after it. A follow-up uses the dates its note recorded; a
# preview uses today's.
if [ "$COPY" = "windowed" ] && [ -z "$DUE_DAY" ]; then
  DUE_DAY="$(add_days "$DAY" 30)"
  REMOVAL_DAY="$(add_days "$DUE_DAY" 1)"
fi
DUE_LABEL=""
if [ -n "$DUE_DAY" ]; then
  DUE_LABEL="$(day_label "$DUE_DAY")"
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
def line: "\(.role) on \"\(.track_title)\" by \(.artist_name)";
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
      | { subject: "We added your \($x.role) credit on \"\($x.track_title)\". Please help us verify it",
          segs: [ {p: "Hi \($fn), good news: your \($x.role) credit on \"\($x.track_title)\" by \($x.artist_name) is now live on your Muso profile. We add credits on trust and then verify them, so please help us confirm this one."},
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
      { subject: "Following up on your \($c[0].role) credit for \"\($c[0].track_title)\"",
        segs: [ {p: "Hi \($fn), a quick follow-up on your \($c[0].role) credit for \"\($c[0].track_title)\" (\($c[0].artist_name)). We haven't received a document yet."} ] }
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
      | { subject: "About the document for your \($x.role) credit on \"\($x.track_title)\"",
          segs: ([ {p: "Hi \($fn), thanks for sending your document. It didn't confirm your \($x.role) credit on \"\($x.track_title)\" by \($x.artist_name) because \($x | rejection_text). \($ask)"} ] + sig) }
    elif $n == 1 then
      $c[0] as $x
      | { subject: "About your \($x.role) credit on \"\($x.track_title)\"",
          segs: ([ {p: "Hi \($fn), thanks for your reply. We still need a document that shows your \($x.role) credit on \"\($x.track_title)\" by \($x.artist_name). \($ask)"} ] + sig) }
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
       { subject: "Quick check on your \($c[0].role) credit for \"\($c[0].track_title)\" (\($c[0].artist_name))",
         segs: [ {p: "Hi \($fn), I'm Caroline from Muso support. We're doing a routine review of credits that were approved automatically, and one of yours came up: your \($c[0].role) credit on \"\($c[0].track_title)\" by \($c[0].artist_name)."},
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
    "The public credit data for \"\(.track_title)\" by \(.artist_name) lists a different person for \(.role) (\(.source_label)\(if .evidence_url != "" then ": \(.evidence_url)" else "" end)), so we've removed the \(.role) credit from your profile."
  elif .reason == "duplicate" then
    "Your \(.role) credit on \"\(.track_title)\" by \(.artist_name) duplicated a credit that is still on your profile, so we've removed the duplicate."
  else
    "Your \(.role) credit on \"\(.track_title)\" by \(.artist_name) did not meet our credit guidelines (\(policy_text)), so we've removed it from your profile."
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
      | { subject: "About your \($x.role) credit on \"\($x.track_title)\"",
          segs: [ {p: "Hi \($fn),"},
                  {p: "I'm Caroline from Muso support. The public credits for \"\($x.track_title)\" by \($x.artist_name) name \($x | tb_names) for \($x.role) (\($x | tb_cite)), so we have removed the \($x.role) credit from your profile."},
                  {p: $dispute}, {p: "Thank you,"}, {p: "Caroline"}, {p: "Muso Support"} ] }
    else
      { subject: "About \($n) of your credits on Muso",
        segs: [ {p: "Hi \($fn),"},
                {p: "I'm Caroline from Muso support. The public credits name someone else for these roles, so we have removed them from your profile:"},
                {ul: ([ $c[0:$maxl][] | "\(.role) on \"\(.track_title)\" by \(.artist_name): \(tb_names) (\(tb_cite))" ]
                      + (if $n > $maxl then ["and \($n - $maxl) more"] else [] end))},
                {p: $dispute}, {p: "Thank you,"}, {p: "Caroline"}, {p: "Muso Support"} ] }
    end;
def removal_notice($fn; $c; $maxl):
  ($c | length) as $n
  | "If you think this is a mistake, reply to this message with a document that names you for the role: a split sheet, a label or distributor statement, a PRO or MLC registration, a studio or session invoice, or liner notes or an official release page (PDF, PNG or JPG). We'll review it and can restore the credit." as $dispute
  | if $n == 1 then
      $c[0] as $x
      | { subject: "An update about your \($x.role) credit on \"\($x.track_title)\"",
          segs: ([ {p: "Hi \($fn), I'm Caroline from Muso support. \($x | removal_sentence)"}, {p: $dispute} ] + sig) }
    else
      { subject: "An update about \($n) credits on your Muso profile",
        segs: ([ {p: "Hi \($fn), I'm Caroline from Muso support. We've reviewed \($n) credits on your Muso profile (list below) and removed them, each for the reason given."},
                 {ul: ([ $c[0:$maxl][] | removal_sentence ] + (if $n > $maxl then ["and \($n - $maxl) more"] else [] end))},
                 {p: $dispute} ] + sig) }
    end;
(.user.first_name | split(" ")[0] // "") as $fn0
| (if ($fn0 | test("^\\p{L}[\\p{L}'.-]{0,39}$")) then $fn0 else "there" end) as $fn
| (if $copy == "takeback" then takeback_notice($fn; .credits; $maxl)
   elif $copy == "removal" then removal_notice($fn; .credits; $maxl)
   elif $copy == "past" then
     past_initial($fn; .credits; $maxl)
   elif $kind == "after-rejection" then after_rejection($fn; .credits; $maxl; $due)
   elif $kind == "initial" then live_initial($fn; .credits; $maxl; $copy == "windowed"; $due)
   else live_followup($fn; .credits; $maxl; $kind; $due) end)
| { subject: .subject,
    text: ([ .segs[] | if has("ul") then (.ul | map("- " + .) | join("\n")) else .p end ] | join("\n\n")),
    html: ([ .segs[] | if has("ul") then "<ul>" + ([.ul[] | "<li>" + esc + "</li>"] | join("")) + "</ul>" else "<p>" + (.p | esc) + "</p>" end ] | join("")) }
JQ
readonly RENDER_JQ
render() { # <input-json> -> {subject, text, html}
  printf '%s' "$1" | "$JQ_BIN" -c --argjson maxl "$MAX_LISTED" --arg copy "$COPY" --arg kind "$KIND" \
    --arg due "$DUE_LABEL" --argjson rt "$REJECTION_TEXT" "$RENDER_JQ"
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
        --message-type "$MESSAGE_TYPE" --approved-by "$APPROVED_BY" --approval-ref "$APPROVAL_REF" --reason "$1" >/dev/null
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
    printf 'DRY-RUN %s %s %s credits=%s%s\n' "$CAMPAIGN" "$KIND" "$MESSAGE_TYPE" "$N" " copy=$COPY"
    payload "$RENDERED" "<resolved from the account email at send time>" | "$JQ_BIN" .
    exit 0 ;;
esac


# ---------------------------------------------------------------------------------------
# Recipient. An initial note goes to exactly one Intercom USER whose email is the account
# email: a lead, zero matches, several matches, or a contact whose external_id names a
# different Muso user is a refusal; we never guess who a note about someone's credits goes
# to. A reminder goes to the contact its note went to (checked against the ledger above).
if [ "$KIND" = "initial" ]; then
  search="$(printf '%s' "$EMAIL" | "$JQ_BIN" -Rc '{query: {field: "email", operator: "=", value: .}}' | api POST /contacts/search)" \
    || { printf 'CONTACT LOOKUP FAILED (curl); nothing was sent or claimed:\n%s\n' "$search" >&2; exit 4; }
  printf '%s' "$search" | "$JQ_BIN" -e '(.data|type) == "array"' >/dev/null 2>&1 \
    || { printf 'CONTACT LOOKUP NOT VERIFIED (no data[]); nothing was sent or claimed:\n%s\n' "$search" >&2; exit 4; }
  users="$(printf '%s' "$search" | "$JQ_BIN" -c --arg e "$EMAIL" '[.data[] | select(.role == "user" and ((.email // "") | ascii_downcase) == $e)]')"
  n_users="$(printf '%s' "$users" | "$JQ_BIN" -r 'length')"
  [ "$n_users" -eq 1 ] || record_refusal "the account email matches $n_users Intercom users (need exactly 1); not sending."
  CONTACT_ID="$(printf '%s' "$users" | "$JQ_BIN" -r '.[0].id')"
  EXT_ID="$(printf '%s' "$users" | "$JQ_BIN" -r '.[0].external_id // empty')"
  # external_id names THIS account only when it is the account's professionalId (Intercom
  # identity; users.neptuneprofessionalid, the UUID every client identifies with) or the Auth0
  # subject, with or without "auth0|" (the same UUID for Auth0 accounts). Never the bare numeric
  # user id (firstmate 118/120): no client identifies with it. A contact with no external_id
  # cannot be matched to any account at all (QA @052f737).
  [ -n "$EXT_ID" ] \
    || record_refusal "the Intercom user for this email has no external_id, so it cannot be matched to this Muso account; not sending."
  # An account-specific note needs the account's Intercom identity (QA @3112769): without
  # user.auth_id nothing can be compared. The one exception is removal-notice, whose recipient
  # is the profile's single CLAIMED WORKSPACE email (credit_review.verify_notify.profile_owner):
  # that campaign has no account identity to compare, by construction.
  if [ -z "$AUTH_ID" ] && [ "$CAMPAIGN" != "removal-notice" ]; then
    record_refusal "the note carries no account Intercom identity (user.auth_id: professionalId or Auth0 subject), so the Intercom contact cannot be verified as its owner; not sending."
  fi
  if [ -n "$AUTH_ID" ] && [ "$EXT_ID" != "$AUTH_ID" ] && [ "$EXT_ID" != "auth0|$AUTH_ID" ]; then
    record_refusal "the Intercom user for this email belongs to a different Muso account (external_id mismatch); not sending."
  fi
fi
printf '%s' "$CONTACT_ID" | grep -qE '^[A-Za-z0-9]{1,40}$' || { echo "CONTACT NOT VERIFIED: contact id is missing or malformed; nothing was sent" >&2; exit 4; }

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
case "$(printf '%s' "$CLAIM" | "$JQ_BIN" -r '.result')" in
  claimed) ;;
  already_notified)
    printf 'SKIPPED already-notified credits=%s\n' "$N"; exit 0 ;;
  user_done)
    printf 'SKIPPED %s credits=%s\n' "$(printf '%s' "$CLAIM" | "$JQ_BIN" -r '.reason')" "$(printf '%s' "$CLAIM" | "$JQ_BIN" -r '.request_ids | length')"; exit 0 ;;
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
"$JQ_BIN" -nc --arg target "user:$CONTACT_ID" --arg mt "$MESSAGE_TYPE" --arg appr "$APPROVED_BY" \
  --arg ref "$APPROVAL_REF" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sha "$BODY_SHA" \
  --arg campaign "$CAMPAIGN" --arg kind "$KIND" --arg parent "$PARENT_ID" --arg due "$DUE_DAY" \
  --arg copy "$COPY" --arg removal "$REMOVAL_DAY" \
  --argjson ids "$(printf '%s' "$CLAIMED_INPUT" | "$JQ_BIN" -c '[.credits[].request_id]')" --arg row "$ROW_ID" \
  '{agent:"operations", action:"intercom_verify_request", campaign:$campaign, kind:$kind,
    parent_message:(if $parent == "" then null else $parent end), due_day:(if $due == "" then null else $due end),
    copy:$copy, removal_day:(if $removal == "" then null else $removal end),
    target:$target, message_type:$mt, request_ids:$ids, ledger_row:($row|tonumber), approved_by:$appr,
    approval_ref:$ref, body_sha256:$sha, timestamp:$ts,
    authorization:"captain approved this verify-request campaign (fixed copy); see approval_ref"}' > "$LOG_FILE"

set +e
RESPONSE="$(printf '%s' "$PAYLOAD" | api POST /messages)"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  ledger finalize --message-row "$ROW_ID" --status attempted --reason "curl rc=$rc; outcome unknown" --api-log "$LOG_FILE" >/dev/null || true
  printf 'POST FAILED (curl rc=%s); logged at %s and left CLAIMED (outcome unknown, so it is never re-sent automatically). Response:\n%s\n' \
    "$rc" "$LOG_FILE" "$RESPONSE" >&2
  exit 4
fi
R_TYPE="$(printf '%s' "$RESPONSE" | "$JQ_BIN" -r '.type // empty' 2>/dev/null || true)"
R_MT="$(printf '%s' "$RESPONSE" | "$JQ_BIN" -r '.message_type // empty' 2>/dev/null || true)"
R_ID="$(printf '%s' "$RESPONSE" | "$JQ_BIN" -r '.id // empty | tostring' 2>/dev/null || true)"
R_CONV="$(printf '%s' "$RESPONSE" | "$JQ_BIN" -r '.conversation_id // empty | tostring' 2>/dev/null || true)"
if [ "$R_TYPE" = "error.list" ]; then
  ledger finalize --message-row "$ROW_ID" --status rejected --reason "intercom error: $(printf '%s' "$RESPONSE" | "$JQ_BIN" -r '[.errors[]?.code] | join(",")' 2>/dev/null)" --api-log "$LOG_FILE" >/dev/null
  printf 'POST REJECTED by Intercom (nothing delivered; retried on a later run). Logged at %s. Response:\n%s\n' "$LOG_FILE" "$RESPONSE" >&2
  exit 4
fi
if [ "$R_TYPE" != "admin_message" ] || [ "$R_MT" != "$EXPECT_TYPE" ] || ! printf '%s' "$R_ID" | grep -qE '^[0-9]+$'; then
  ledger finalize --message-row "$ROW_ID" --status attempted --reason "unverified response type=${R_TYPE:-none} message_type=${R_MT:-none}" --api-log "$LOG_FILE" >/dev/null || true
  printf 'POST NOT VERIFIED: expected an admin_message of type "%s", Intercom answered type "%s" message_type "%s". Logged at %s; left CLAIMED. Response:\n%s\n' \
    "$EXPECT_TYPE" "${R_TYPE:-<none>}" "${R_MT:-<none>}" "$LOG_FILE" "$RESPONSE" >&2
  exit 4
fi
ledger finalize --message-row "$ROW_ID" --status sent --message-id "$R_ID" --conversation-id "$R_CONV" \
  --body-sha256 "$BODY_SHA" --api-log "$LOG_FILE" >/dev/null
if [ "$KIND" = "initial" ]; then
  printf 'POSTED %s message=%s credits=%s\n' "$MESSAGE_TYPE" "$R_ID" "$NC"
else
  printf 'POSTED %s %s message=%s credits=%s\n' "$KIND" "$MESSAGE_TYPE" "$R_ID" "$NC"
fi
