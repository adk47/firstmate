#!/bin/bash -p
# ABSOLUTE INTERPRETER, PRIVILEGED MODE, and PATH replaced before anything runs. Same
# reasoning as agent-bridge-request.sh: `-p` stops bash sourcing $BASH_ENV and importing
# exported functions before line 1, and replacing PATH outright stops a jq/curl shim from
# rewriting the payload after validation.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
set -euo pipefail

# intercom-ops-write.sh: the ONLY path the operations agent uses to write into an Intercom
# conversation. Internal note by default; a customer-facing reply only with an allowlisted
# human's explicit approval.
#
# WHY THIS IS A SCRIPT AND NOT PROSE
# The ops agent used to compose `curl POST /conversations/<id>/reply` from memory every
# time it resolved an escalated conversation. On 2026-09-01 it chose message_type "note"
# (internal, correct, and even api-logged first). On 2026-08-31 the SAME hand-typed path
# chose "comment" under a human's admin id, self-approved as "god_mode", and customers saw
# "Nicholas Sollazzo" mid-thread (PR #900/#901/#902). Whether a customer reads what the
# agent wrote was one word in a payload the agent typed itself, guarded by prose. This
# wrapper is the deterministic gate below the LLM:
#   - note is the default shape and carries a "Note to <audience>" header so a teammate
#     reading the inbox sees at once that it is internal and who asked for it;
#   - a customer-facing reply needs BOTH --customer-facing and --approved-by <SlackUID> of
#     one of the three humans who may authorize Intercom writes, and its body is refused
#     if it leaks internal surfaces (issue links, "ticket", "Ops resolution", ...);
#   - the posting identity is Caroline, pinned, whatever the environment says;
#   - the api-log entry is written BEFORE the POST, and the response's part_type is
#     checked AFTER it, so "POSTED note" can never describe a comment.
#
# What it cannot do, stated plainly: the ops agent runs as root with exec unrestricted, so
# a raw curl remains physically possible. This stops accident and drift, the way the
# 2026-08-31 and 2026-09-01 writes actually happened; it is not an adversarial control.
#
# Usage:
#   intercom-ops-write.sh note  --conversation <id> --requested-by <SlackUID> \
#       --audience <team|self|Name> (--body TEXT | --body-file FILE) [--dry-run|--validate]
#   intercom-ops-write.sh reply --conversation <id> --requested-by <SlackUID> \
#       --customer-facing --approved-by <SlackUID> (--body TEXT | --body-file FILE) [--dry-run|--validate]
#
# Exit codes: 0 ok · 1 refusal · 2 usage/environment error · 4 post failed or wrong part_type

# TESTABLE is a BUILD-TIME literal and the deployed copy is always 0. The suite runs a
# DERIVED COPY with the line flipped to 1 (scripts/tests/intercom-ops-write.bats). Anything
# selectable by the caller is selectable by the agent, so on a deployed copy the log dir
# and the curl binary are not parameters. readonly: a later reassignment is a runtime
# error, not a quiet override; the doctrine gate counts assignments so it is a CI error too.
readonly TESTABLE=0

# PINNED. The identity every agent-authored Intercom part posts under is Caroline
# (skills-all/muso-intercom/SKILL.md, Reply Identity). The literal is assigned here and
# frozen, so an INTERCOM_ADMIN_ID exported into the environment is overwritten, not obeyed,
# the same as the Python cron writers. The name is deliberate: it is one of the two tokens
# check-intercom-reply-identity.sh keys on, so a flipped value fails BOTH CI guards.
readonly INTERCOM_ADMIN_ID="5763097"
readonly API_BASE="https://api.intercom.io"
readonly API_VERSION="2.11"
readonly PROD_LOG_DIR="/opt/hydra/workspaces/operations/api-logs"
# Caroline's outbound sanitizer word list: every `\b...\b` pattern in
# plugins/intercom/src/sanitize-tool-leak.ts PATTERNS (tool tokens, the bare word "ticket",
# the fixed phrases, and the architecture words), copied verbatim. ONE line, because
# check-intercom-ops-write-doctrine.sh compares it against that TypeScript array as a set:
# a pattern added to either place without the other fails CI. (Prose word bans such as
# "error" / "system" / "API" are Caroline's voice rules in workspaces/support/SOUL.md, not
# sanitizer behaviour, and are NOT refused here — the support SOUL itself says "API" is fine.)
readonly SANITIZER_WORDS="profile_status|profile_lookup|credits_search|create_ticket|subscription_status|remove_credits|dedupe_check|credit_verification_check|profiles_claim_self|credits_verify|profiles_consolidate|order_lookup|order_address_update|founding_status|founding_buyback_link|support_action_router|memory_search|memory_get|profile_analytics_status|profile_credits_status|profile_claim_status|retention_offer_check|retention_offer_apply|cancel_subscription|billing_status|track_analytics_status|analytics_refresh_request|analytics_recheck|subscription_cancel|refund_policy_check|refund_create|catalog_status|track_lookup|metadata_capture_request|artwork_refresh_request|catalog_recheck|user_status|resend_verification|email_delivery_status|login_recovery_packet|profile_change_packet|profile_merge_check|account_merge_preflight|email_change_preflight|profile_removal_preflight|ticket|tool failed|error fetching|unable to look up|the system says|my system|there was an issue with|ClickUp|openclaw|HYDRA"
readonly ALLOWLIST_TEXT="Aaron U7RP6HKUZ, Jan U038BM16T7W, Nick U0AL36NADEY"

die()    { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
refuse() { printf 'REFUSED: %s\n' "$*" >&2; exit 1; }

# The write allowlist is ONE table: the three humans whose Slack request IS the
# authorization for an Intercom write (muso-intercom skill, Write Access Control), keyed by
# Slack user id because display names are not identity. The name is what the note header
# shows, so a reader of the inbox sees "Requested in Slack by Jan", not a user id.
allowlisted_name() {
  case "$1" in
    U7RP6HKUZ)   echo "Aaron" ;;
    U038BM16T7W) echo "Jan" ;;
    U0AL36NADEY) echo "Nick" ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------------------
# Deployed copies reject EVERY override before anything else can run.
if [ "$TESTABLE" != "1" ]; then
  [ -z "${INTERCOM_OPS_TEST_LOG_DIR:-}" ] || die "INTERCOM_OPS_TEST_LOG_DIR is not settable on a deployed copy of this script. The write log is $PROD_LOG_DIR; a caller-selectable log dir is a write nobody can audit."
  [ -z "${INTERCOM_OPS_TEST_CURL_BIN:-}" ] || die "INTERCOM_OPS_TEST_CURL_BIN is not settable on a deployed copy of this script. A caller-selectable client can print POSTED without posting."
  [ -z "${INTERCOM_OPS_TEST_TIMEOUT_BIN:-}" ] || die "INTERCOM_OPS_TEST_TIMEOUT_BIN is not settable on a deployed copy of this script."
  LOG_DIR="$PROD_LOG_DIR"
  CURL_BIN="/usr/bin/curl"
  JQ_BIN="/usr/bin/jq"
  TIMEOUT_BIN="/usr/bin/timeout"
else
  LOG_DIR="${INTERCOM_OPS_TEST_LOG_DIR:-$PROD_LOG_DIR}"
  # The suite's curl stub is reachable only through an explicit seam: PATH was replaced
  # above, so a PATH-shadowed stub would never be found. jq and timeout resolve from the
  # replaced PATH so the tests run on a dev box where the binaries live elsewhere.
  CURL_BIN="${INTERCOM_OPS_TEST_CURL_BIN:-$(command -v curl || echo /usr/bin/curl)}"
  JQ_BIN="$(command -v jq || echo /usr/bin/jq)"
  # timeout lives outside the replaced PATH on a Homebrew dev box, so the suite hands it in.
  TIMEOUT_BIN="${INTERCOM_OPS_TEST_TIMEOUT_BIN:-$(command -v timeout || command -v gtimeout || echo /usr/bin/timeout)}"
fi
readonly LOG_DIR CURL_BIN JQ_BIN TIMEOUT_BIN

# ---------------------------------------------------------------------------------------
# Arguments
usage() {
  sed -n '/^# Usage:/,/^# Exit codes/p' "$0" | sed 's/^# \{0,1\}//' >&2
}

[ $# -ge 1 ] || { usage; die "missing subcommand (note | reply)"; }
MODE="$1"; shift
case "$MODE" in
  note|reply) ;;
  -h|--help) usage; exit 0 ;;
  *) usage; die "unknown subcommand '$MODE' (note | reply). Closing, assigning, tagging and snoozing are outside this wrapper: bulk stale closes go through the cs-stale-drain skill, abuse tagging/closing through muso-abuse-block; any other close, assignment, tag or snooze is a human's action in the inbox." ;;
esac

CONVERSATION="" REQUESTED_BY="" AUDIENCE="" APPROVED_BY="" BODY="" BODY_FILE="" CUSTOMER_FACING=0 ACTION="post"
while [ $# -gt 0 ]; do
  case "$1" in
    --conversation|--requested-by|--audience|--approved-by|--body|--body-file)
      # A dangling flag must be a usage error with a message: a bare `shift 2` past the end
      # of argv exits 1 under set -e with no output, which reads as a silent refusal.
      [ $# -ge 2 ] || { usage; die "$1 needs a value"; }
      case "$1" in
        --conversation) CONVERSATION="$2" ;;
        --requested-by) REQUESTED_BY="$2" ;;
        --audience)     AUDIENCE="$2" ;;
        --approved-by)  APPROVED_BY="$2" ;;
        --body)         BODY="$2" ;;
        --body-file)    BODY_FILE="$2" ;;
      esac
      shift 2 ;;
    --customer-facing) CUSTOMER_FACING=1; shift ;;
    --dry-run)         ACTION="dry-run"; shift ;;
    --validate)        ACTION="validate"; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) usage; die "unknown argument '$1'" ;;
  esac
done

# ---------------------------------------------------------------------------------------
# Environment
[ -n "${MUSOAI_INTERCOM_TOKEN:-}" ] || die "MUSOAI_INTERCOM_TOKEN is not set. The gateway exports it from /etc/openclaw/main.env; on a shell: set -a; . /etc/openclaw/main.env; set +a"
for b in "$CURL_BIN" "$JQ_BIN" "$TIMEOUT_BIN"; do
  [ -x "$b" ] || die "$b is missing or not executable; it is a required dependency."
done

# ---------------------------------------------------------------------------------------
# Validation. Every refusal says how to comply.
printf '%s' "$CONVERSATION" | grep -qE '^[0-9]+$' \
  || refuse "--conversation must be the numeric Intercom conversation id (got '${CONVERSATION:-<empty>}')."

printf '%s' "$REQUESTED_BY" | grep -qE '^U[A-Z0-9]{8,12}$' \
  || refuse "--requested-by must be the Slack USER ID of the human who asked (from message metadata, never a display name); got '${REQUESTED_BY:-<empty>}'."
REQUESTER_NAME="$(allowlisted_name "$REQUESTED_BY")" \
  || refuse "$REQUESTED_BY is not on the Intercom write allowlist ($ALLOWLIST_TEXT). Intercom writes need one of them to ask; everyone else is read-only. Do not post; say who can authorize it."

if [ -n "$BODY_FILE" ]; then
  [ -z "$BODY" ] || refuse "pass --body OR --body-file, not both."
  [ -r "$BODY_FILE" ] || die "--body-file '$BODY_FILE' is not readable."
  BODY="$(cat "$BODY_FILE")"
fi
# Pure-bash test, no pipe: `printf | grep -q` under pipefail refuses a large multi-line
# body as "empty" once grep exits early and printf takes SIGPIPE (reproduced at ~60 KB).
[[ "$BODY" =~ [^[:space:]] ]] || refuse "the body is empty."

case "$MODE" in
  note)
    [ "$CUSTOMER_FACING" -eq 0 ] || refuse "--customer-facing does not apply to a note; a note is internal. Use 'reply' if the customer must read it."
    [ -z "$APPROVED_BY" ] || refuse "--approved-by does not apply to a note; the requester's Slack ask is the authorization. Use 'reply' for a customer-facing message."
    [ -n "$AUDIENCE" ] || refuse "--audience is required for a note: 'team', 'self', or the teammate's first name (e.g. Jan). It becomes the first line, 'Note to <audience>', so the inbox reader sees the note is internal and who it is for."
    case "$AUDIENCE" in
      team|self) ;;
      *) printf '%s' "$AUDIENCE" | grep -qE "^[A-Za-z][A-Za-z .'-]{0,40}$" \
           || refuse "--audience must be 'team', 'self', or a name (letters, spaces, . ' -); got '$AUDIENCE'." ;;
    esac
    MESSAGE_TYPE="note"
    EXPECT_PART="note"
    ;;
  reply)
    [ -z "$AUDIENCE" ] || refuse "--audience applies to notes only; a reply's audience is the customer."
    [ "$CUSTOMER_FACING" -eq 1 ] \
      || refuse "a reply reaches the CUSTOMER. Pass --customer-facing to state that on purpose, and --approved-by <SlackUID> of the human who told you to reply to the customer. If nobody did, post a note instead."
    [ -n "$APPROVED_BY" ] \
      || refuse "--approved-by <SlackUID> is required for a customer-facing reply: the human (Aaron, Jan or Nick) who explicitly asked for the CUSTOMER to be answered. A request to 'resolve' or 'give a summary' is a note, not a reply."
    printf '%s' "$APPROVED_BY" | grep -qE '^U[A-Z0-9]{8,12}$' \
      || refuse "--approved-by must be a human's Slack USER ID; '$APPROVED_BY' is not one. Self-approval, god_mode and agent identities never authorize a customer-facing reply (2026-08-31: a god_mode_self_approve reply reached customers under a human's name)."
    APPROVER_NAME="$(allowlisted_name "$APPROVED_BY")" \
      || refuse "$APPROVED_BY is not a human on the Intercom write allowlist ($ALLOWLIST_TEXT); a customer-facing reply needs one of them."
    # The customer never sees internal surfaces. The word list is Caroline's own redaction
    # set (plugins/intercom/src/sanitize-tool-leak.ts PATTERNS) plus the shapes the ops
    # agent's escalation notes actually carry: issue links, the mailbox number, "Ops
    # resolution", Slack mentions, admin ids. Paraphrase the bridge's customer_safe_summary.
    flat="$(printf '%s' "$BODY" | tr -s '[:space:]' ' ')"
    # Whole-word matching spelled out in portable ERE: BSD grep on a dev box and GNU grep
    # on node-8 do not agree on \b.
    W='(^|[^A-Za-z0-9_])'; E='([^A-Za-z0-9_]|$)'
    leak=""
    printf '%s' "$flat" | grep -qiE 'github\.com/|gitlab\.com/|issue #|#[0-9]{3,}|<@U[A-Z0-9]+>' && leak="an issue link, issue number or Slack mention"
    printf '%s' "$flat" | grep -qiE "${W}(Ops resolution|admin[ _]?id)${E}" && leak="internal wording (Ops resolution / admin id)"
    printf '%s' "$flat" | grep -qiE "${W}(${SANITIZER_WORDS})${E}" \
      && leak="a word Caroline's outbound sanitizer redacts ('$(printf '%s' "$flat" | grep -oiE "(${SANITIZER_WORDS})" | head -1)', see plugins/intercom/src/sanitize-tool-leak.ts)"
    [ -z "$leak" ] || refuse "the customer-facing body contains $leak. Customers never see internal surfaces: rewrite it in Caroline's voice (quote the normal SLA, never an engineering ETA, never a link to our repos), or post it as a note."
    MESSAGE_TYPE="comment"
    EXPECT_PART="comment"
    ;;
esac

# ---------------------------------------------------------------------------------------
# Render
if [ "$MODE" = "note" ]; then
  case "$AUDIENCE" in
    team) header="Note to team" ;;
    self) header="Note to self" ;;
    *)    header="Note to $AUDIENCE" ;;
  esac
  FULL_BODY="$header (internal Ops note, not visible to the customer). Requested in Slack by $REQUESTER_NAME.

$BODY"
else
  FULL_BODY="$BODY"
fi

# The body travels through STDIN, never argv: Linux caps one argv string at 128KB
# (MAX_ARG_STRLEN), so `--arg body "$FULL_BODY"` fails with "Argument list too long" on
# node-8 for a long note while passing on a Mac. Same for the payload handed to curl below.
PAYLOAD="$(printf '%s' "$FULL_BODY" | "$JQ_BIN" -Rsc --arg mt "$MESSAGE_TYPE" --arg admin "$INTERCOM_ADMIN_ID" \
  '{message_type: $mt, type: "admin", admin_id: $admin, body: .}')"
URL="$API_BASE/conversations/$CONVERSATION/reply"

case "$ACTION" in
  validate)
    printf 'VALID %s conversation=%s\n' "$MESSAGE_TYPE" "$CONVERSATION"
    exit 0 ;;
  dry-run)
    printf 'DRY-RUN %s conversation=%s\n' "$MESSAGE_TYPE" "$CONVERSATION"
    printf '%s\n' "$PAYLOAD" | "$JQ_BIN" .
    exit 0 ;;
esac

# ---------------------------------------------------------------------------------------
# Log BEFORE the write (operations/SOUL.md, Write Activity Logging), then POST, then verify.
# The dir is untracked and rsync-excluded (deploy.sh), so create it like every other
# api-log writer does (qa-pr-approve.sh) and die only if that fails.
mkdir -p "$LOG_DIR" || die "cannot create log dir $LOG_DIR; refusing to write unlogged."
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# $$ keeps two same-second writes to one conversation from overwriting each other's record.
LOG_FILE="$LOG_DIR/intercom-$MODE-$CONVERSATION-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
if [ "$MODE" = "note" ]; then
  LOG_ACTION="intercom_internal_note"; LOG_APPROVED=""; LOG_AUDIENCE="$AUDIENCE"
  LOG_AUTH="$REQUESTER_NAME ($REQUESTED_BY) requested it in Slack; internal note, not customer-visible"
else
  LOG_ACTION="intercom_customer_reply"; LOG_APPROVED="$APPROVED_BY"; LOG_AUDIENCE="customer"
  LOG_AUTH="$APPROVER_NAME ($APPROVED_BY) explicitly approved a customer-facing reply in Slack"
fi
"$JQ_BIN" -nc --arg action "$LOG_ACTION" --arg target "conversation:$CONVERSATION" \
  --arg req "$REQUESTED_BY" --arg appr "$LOG_APPROVED" --arg aud "$LOG_AUDIENCE" \
  --arg ts "$NOW" --arg auth "$LOG_AUTH" \
  '{agent:"operations", action:$action, target:$target, requester:$req, approved_by:(if $appr == "" then null else $appr end), audience:$aud, timestamp:$ts, authorization:$auth}' \
  > "$LOG_FILE"

set +e
RESPONSE="$(printf '%s' "$PAYLOAD" | "$TIMEOUT_BIN" 45 "$CURL_BIN" -sS -X POST \
  -H "Authorization: Bearer $MUSOAI_INTERCOM_TOKEN" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -H "Intercom-Version: $API_VERSION" \
  --data @- "$URL" 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  printf 'POST FAILED (curl rc=%s) for %s; the write was logged at %s but may not have landed. Response:\n%s\n' "$rc" "$URL" "$LOG_FILE" "$RESPONSE" >&2
  exit 4
fi

# Verify the mutation landed AS INTENDED. Intercom answers a successful reply with the FULL
# conversation, not the part: its top-level `id` is the conversation id and the part just
# created is the LAST entry of conversation_parts.conversation_parts (the same shape
# plugins/intercom/src/outbound.ts replyToConversationOnce reads). Anything else (error.list,
# no parts, a last part of the other type) means the success line must not be printed.
PART_TYPE="$(printf '%s' "$RESPONSE" | "$JQ_BIN" -r '(.conversation_parts.conversation_parts // [])[-1].part_type // empty' 2>/dev/null || true)"
PART_ID="$(printf '%s' "$RESPONSE" | "$JQ_BIN" -r '(.conversation_parts.conversation_parts // [])[-1].id // empty' 2>/dev/null || true)"
if [ "$PART_TYPE" != "$EXPECT_PART" ]; then
  printf 'POST NOT VERIFIED: expected part_type "%s", Intercom answered part_type "%s". Logged at %s. Response:\n%s\n' \
    "$EXPECT_PART" "${PART_TYPE:-<none>}" "$LOG_FILE" "$RESPONSE" >&2
  exit 4
fi

printf 'POSTED %s conversation=%s part=%s\n' "$MESSAGE_TYPE" "$CONVERSATION" "$PART_ID"
