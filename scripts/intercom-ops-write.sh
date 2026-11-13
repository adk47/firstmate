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
#   intercom-ops-write.sh reply --conversation <id> --purpose gdpr-erasure \
#       --customer-facing (--body TEXT | --body-file FILE) [--dry-run|--validate]
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
# One write per conversation at a time, across every caller of this script on this host (see CONVERSATION LOCK).
readonly PROD_LOCK_DIR="/run/lock/hydra-intercom-ops-write"
readonly PROD_LOCK_WAIT_S=20
# Caroline's outbound sanitizer word list: every `\b...\b` pattern in
# plugins/intercom/src/sanitize-tool-leak.ts PATTERNS (tool tokens, the bare word "ticket",
# the fixed phrases, and the architecture words), copied verbatim. ONE line, because
# check-intercom-ops-write-doctrine.sh compares it against that TypeScript array as a set:
# a pattern added to either place without the other fails CI. (Prose word bans such as
# "error" / "system" / "API" are Caroline's voice rules in workspaces/support/SOUL.md, not
# sanitizer behaviour, and are NOT refused here — the support SOUL itself says "API" is fine.)
readonly SANITIZER_WORDS="profile_status|profile_lookup|credits_search|create_ticket|subscription_status|remove_credits|dedupe_check|credit_verification_check|profiles_claim_self|credits_verify|profiles_consolidate|order_lookup|order_address_update|founding_status|founding_buyback_link|support_action_router|memory_search|memory_get|profile_analytics_status|profile_credits_status|profile_claim_status|retention_offer_check|retention_offer_apply|cancel_subscription|billing_status|track_analytics_status|analytics_refresh_request|analytics_recheck|subscription_cancel|refund_policy_check|refund_create|catalog_status|track_lookup|metadata_capture_request|artwork_refresh_request|catalog_recheck|user_status|resend_verification|email_delivery_status|login_recovery_packet|profile_change_packet|profile_merge_check|account_merge_preflight|email_change_preflight|profile_removal_preflight|ticket|tool failed|error fetching|unable to look up|the system says|my system|there was an issue with|ClickUp|openclaw|HYDRA|platform-data-processing"
readonly ALLOWLIST_TEXT="Aaron U7RP6HKUZ, Jan U038BM16T7W, Nick U0AL36NADEY"

# ---------------------------------------------------------------------------------------
# PURPOSES: the machine-authorization class, and the ONLY one.
#
# A purpose is not a fourth human and it is not a way around the allowlist. It is the third
# identity class for a write that no human asked for and that the repo has already ruled on:
# a statutory erasure letter is a legal obligation with its own clock, not a Slack request.
# Each purpose names the ONE identity it posts as, the ONE message shape it may use, and the
# register that must OWN the conversation. A purpose not in this table does not exist, and a
# purpose may never be combined with --requested-by/--approved-by: the audit record must say
# what actually happened, and "a human approved this" would be a lie in the trail.
#
# Why not just add the devops seat to the human allowlist (the 2026-11-06 temptation): that
# would let the bot write to ANY conversation - every customer thread, not just the ones the
# erasure register owns - and the log would still claim a human asked. The blast radius is
# the whole inbox, and it would be invisible.
readonly PURPOSE_TABLE="gdpr-erasure"
# The register that owns a gdpr-erasure conversation. The writer reads it READ-ONLY and
# refuses any conversation it does not find: ownership is checked here, below the caller, so
# a bug in the pipeline cannot widen it. Overridable only on a TESTABLE copy.
readonly GDPR_REGISTER_PROD="/var/lib/hydra-gdpr/erasure.sqlite"

# The identity a purpose posts as. Deliberately not a Slack id shape: nothing that looks like
# a human can be mistaken for one in the log, and allowlisted_name() can never resolve it.
readonly PURPOSE_IDENTITY="system:gdpr-pipeline"

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

# The ownership half of a purpose, and the ONLY thing that can say "this purpose owns this
# conversation". Every entry in PURPOSE_TABLE needs an arm here; a purpose added to the table
# without one falls to `*)` and is refused, so the table alone can never widen the blast
# radius.
#
# $1 purpose, $2 conversation, $3 the exact body about to be posted.
# Returns 0 owned, 1 not an open request, 2 register unreadable, 3 sqlite3 missing,
# 4 sha256sum missing, 5 no claimed letter matches these bytes.
purpose_owns_conversation() {
  case "$1" in
    gdpr-erasure)
      [ -r "$GDPR_REGISTER" ] || return 2
      [ -x "$SQLITE_BIN" ] || return 3
      [ -x "$SHA256_BIN" ] || return 4
      # $2 is already validated as ^[0-9]+$ above, so it cannot break out of the literal.
      #
      # OPEN ONLY. A closed (or duplicate) request is finished: its conversation is no longer a
      # thread this purpose has anything to say on, and counting it would let a caller with the
      # writer token post arbitrary customer-facing text to a finished request with no human
      # approval and no live statutory send. The pipeline's own letters all go out while the row
      # is open - `confirmed_at` is what closes it, and that is written AFTER the letter lands.
      owned="$("$SQLITE_BIN" -readonly "$GDPR_REGISTER" \
        "SELECT count(*) FROM erasure_requests WHERE conversation_id = '$2' AND status = 'open';" 2>/dev/null)" || return 2
      case "$owned" in
        ''|*[!0-9]*) return 2 ;;
        0) return 1 ;;
      esac
      # THE LETTER, not just the thread. Ownership alone would make this writer a general-purpose
      # customer-facing poster for anyone who can run it: the human allowlist would be bypassed by
      # a flag, and the only remaining gate would be "is this conversation in the register". So the
      # bytes must match a letter the pipeline has ALREADY CLAIMED. `claim_send` writes a `sending`
      # row carrying the conversation as its target and the sha256 of the exact approved copy
      # BEFORE it invokes this writer, so a matching row proves the pipeline composed this text for
      # this thread under its own copy, standing-ruling and ledger gates. Arbitrary text has no
      # such row and is refused.
      sha="$(printf '%s' "$3" | "$SHA256_BIN" 2>/dev/null)" || return 2
      sha="${sha%% *}"
      case "$sha" in
        [0-9a-f][0-9a-f]*) ;;
        *) return 2 ;;
      esac
      #
      # READ ONLY, ON PURPOSE. This function answers "may this purpose write here at all", and it is
      # called BEFORE the --validate/--dry-run exits. Consuming the claim here would let a no-write
      # mode burn it: validate would succeed without POSTing, the real reply would then be refused,
      # and an owed statutory letter would silently never go out. The single-use consume lives in
      # purpose_consume_claim(), which runs after every no-write exit, every refusal AND the audit-record
      # write, immediately before the POST - see the ordering comment at that call site for why the
      # record must land first.
      claimed="$("$SQLITE_BIN" -readonly "$GDPR_REGISTER" \
        "SELECT count(*) FROM erasure_sends \
          WHERE target = '$2' AND channel = 'intercom' AND body_sha = '$sha' \
            AND state = 'sending' AND consumed_at = '' \
            AND request_id IN (SELECT id FROM erasure_requests WHERE status = 'open');" 2>/dev/null)" || return 2
      case "$claimed" in
        ''|*[!0-9]*) return 2 ;;
        0) return 5 ;;
      esac
      return 0 ;;
    *) return 1 ;;
  esac
}

# Consume the claim, atomically. Returns 0 consumed, 2 register unreadable, 5 nothing left to consume
# (already consumed, or another invocation won the race), 3 sqlite3 missing, 4 sha256sum missing.
#
# A read-only "is there a sending row" check is not a claim: if the POST lands but the pipeline has not
# yet recorded `sent`, or two invocations overlap, the same check passes twice and the customer gets the
# same statutory letter twice. The ledger's UNIQUE(request_id, kind) does not help, because it bounds the
# PIPELINE's rows, not direct invocations of this writer. So the authorization is CONSUMED in one
# conditional UPDATE and exactly one row must change. SQLite serialises writers, so of two concurrent
# calls exactly one sees changes()=1 and the other is refused. `store.claim_send` clears `consumed_at`
# when it legitimately reuses a `failed`/`refused` slot, so a real retry still works.
purpose_consume_claim() {
  case "$1" in
    gdpr-erasure)
      [ -r "$GDPR_REGISTER" ] || return 2
      [ -x "$SQLITE_BIN" ] || return 3
      [ -x "$SHA256_BIN" ] || return 4
      sha="$(printf '%s' "$3" | "$SHA256_BIN" 2>/dev/null)" || return 2
      sha="${sha%% *}"
      case "$sha" in
        [0-9a-f][0-9a-f]*) ;;
        *) return 2 ;;
      esac
      # The busy timeout matters because this statement WRITES: the hourly tick holds the store while it
      # decides, and a bare SQLITE_BUSY would be classified as "register unreadable" and refuse a letter
      # that is fine.
      # EXACTLY ONE CLAIM, and `id = (SELECT ... LIMIT 1)` is what guarantees it. Matching on conversation +
      # bytes alone spent EVERY open claim whose copy is identical, so one POST consumed two claims while
      # posting one reply: the second request was left `sending` with its claim gone and could never be sent
      # (QA #1820). The subquery picks the oldest matching claim and the UPDATE touches only that row, so one
      # invocation can never spend more than the one letter it is about to post. Two requests sharing a
      # conversation and identical copy therefore take two invocations and post two replies - which is right,
      # because each request is owed its own written confirmation.
      consumed="$("$SQLITE_BIN" -cmd ".timeout 5000" "$GDPR_REGISTER" \
        "UPDATE erasure_sends SET consumed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') \
          WHERE id = (SELECT id FROM erasure_sends \
                       WHERE target = '$2' AND channel = 'intercom' AND body_sha = '$sha' \
                         AND state = 'sending' AND consumed_at = '' \
                         AND request_id IN (SELECT id FROM erasure_requests WHERE status = 'open') \
                       ORDER BY id LIMIT 1); \
         SELECT changes();" 2>/dev/null)" || return 2
      case "$consumed" in
        ''|*[!0-9]*) return 2 ;;
        0) return 5 ;;
      esac
      return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------------------
# Deployed copies reject EVERY override before anything else can run.
if [ "$TESTABLE" != "1" ]; then
  [ -z "${INTERCOM_OPS_TEST_LOG_DIR:-}" ] || die "INTERCOM_OPS_TEST_LOG_DIR is not settable on a deployed copy of this script. The write log is $PROD_LOG_DIR; a caller-selectable log dir is a write nobody can audit."
  [ -z "${INTERCOM_OPS_TEST_CURL_BIN:-}" ] || die "INTERCOM_OPS_TEST_CURL_BIN is not settable on a deployed copy of this script. A caller-selectable client can print POSTED without posting."
  [ -z "${INTERCOM_OPS_TEST_TIMEOUT_BIN:-}" ] || die "INTERCOM_OPS_TEST_TIMEOUT_BIN is not settable on a deployed copy of this script."
  [ -z "${INTERCOM_OPS_TEST_LOCK_DIR:-}" ] || die "INTERCOM_OPS_TEST_LOCK_DIR is not settable on a deployed copy of this script. A caller-selectable lock dir is a lock nobody else holds."
  [ -z "${INTERCOM_OPS_TEST_LOCK_WAIT_S:-}" ] || die "INTERCOM_OPS_TEST_LOCK_WAIT_S is not settable on a deployed copy of this script."
  LOG_DIR="$PROD_LOG_DIR"
  CURL_BIN="/usr/bin/curl"
  JQ_BIN="/usr/bin/jq"
  TIMEOUT_BIN="/usr/bin/timeout"
  FLOCK_BIN="/usr/bin/flock"
  LOCK_DIR="$PROD_LOCK_DIR"
  LOCK_WAIT_S="$PROD_LOCK_WAIT_S"
  SQLITE_BIN="/usr/bin/sqlite3"
  SHA256_BIN="/usr/bin/sha256sum"
  GDPR_REGISTER="$GDPR_REGISTER_PROD"
else
  LOG_DIR="${INTERCOM_OPS_TEST_LOG_DIR:-$PROD_LOG_DIR}"
  # The suite's curl stub is reachable only through an explicit seam: PATH was replaced
  # above, so a PATH-shadowed stub would never be found. jq and timeout resolve from the
  # replaced PATH so the tests run on a dev box where the binaries live elsewhere.
  CURL_BIN="${INTERCOM_OPS_TEST_CURL_BIN:-$(command -v curl || echo /usr/bin/curl)}"
  JQ_BIN="$(command -v jq || echo /usr/bin/jq)"
  # timeout lives outside the replaced PATH on a Homebrew dev box, so the suite hands it in.
  TIMEOUT_BIN="${INTERCOM_OPS_TEST_TIMEOUT_BIN:-$(command -v timeout || command -v gtimeout || echo /usr/bin/timeout)}"
  FLOCK_BIN="$(command -v flock || echo /usr/bin/flock)"
  LOCK_DIR="${INTERCOM_OPS_TEST_LOCK_DIR:-$PROD_LOCK_DIR}"
  LOCK_WAIT_S="${INTERCOM_OPS_TEST_LOCK_WAIT_S:-$PROD_LOCK_WAIT_S}"
  SQLITE_BIN="${INTERCOM_OPS_TEST_SQLITE_BIN:-$(command -v sqlite3 || echo /usr/bin/sqlite3)}"
  SHA256_BIN="${INTERCOM_OPS_TEST_SHA256_BIN:-$(command -v sha256sum || echo /usr/bin/sha256sum)}"
  GDPR_REGISTER="${INTERCOM_OPS_TEST_GDPR_REGISTER:-$GDPR_REGISTER_PROD}"
fi
readonly LOG_DIR CURL_BIN JQ_BIN TIMEOUT_BIN SQLITE_BIN SHA256_BIN GDPR_REGISTER FLOCK_BIN LOCK_DIR LOCK_WAIT_S

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

CONVERSATION="" REQUESTED_BY="" AUDIENCE="" APPROVED_BY="" BODY="" BODY_FILE="" CUSTOMER_FACING=0 ACTION="post" PURPOSE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --conversation|--requested-by|--audience|--approved-by|--body|--body-file|--purpose)
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
        --purpose)      PURPOSE="$2" ;;
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

# The body is an INPUT, so it is materialised before anything validates it. A purpose write is
# matched against the pipeline's claimed letter by the sha256 of these exact bytes, so reading
# --body-file after that check would refuse every legitimate --body-file caller.
if [ -n "$BODY_FILE" ]; then
  [ -z "$BODY" ] || refuse "pass --body OR --body-file, not both."
  [ -r "$BODY_FILE" ] || die "--body-file '$BODY_FILE' is not readable."
  BODY="$(cat "$BODY_FILE")"
fi

# A purpose is a MACHINE authorization: no human asked, so there is no requester to check and
# no human to name. It is mutually exclusive with the human flags on purpose - the audit trail
# must say what actually happened, and "a human approved this" would be a lie in the trail.
if [ -n "$PURPOSE" ]; then
  case " $PURPOSE_TABLE " in
    *" $PURPOSE "*) ;;
    *) refuse "--purpose '$PURPOSE' is not a purpose this writer knows ($PURPOSE_TABLE). A purpose is a machine authorization the repo has already ruled on; anything else needs a human's --approved-by." ;;
  esac
  [ "$MODE" = "reply" ] \
    || refuse "--purpose applies to 'reply' only; a note is internal and needs a human requester."
  [ -z "$REQUESTED_BY" ] \
    || refuse "--purpose and --requested-by are mutually exclusive: a purpose write has no human requester, and recording one would be a false audit trail."
  [ -z "$APPROVED_BY" ] \
    || refuse "--purpose and --approved-by are mutually exclusive: a purpose write is authorized by the purpose, not by a human. Recording a human id here is exactly the lie this mode exists to avoid."
  # OWNERSHIP, checked here and not in the caller: a purpose may write ONLY on a thread the
  # register owns, so a bug in the pipeline cannot widen the blast radius to the whole inbox.
  owned_rc=0
  purpose_owns_conversation "$PURPOSE" "$CONVERSATION" "$BODY" || owned_rc=$?
  case "$owned_rc" in
    0) ;;
    1) refuse "conversation $CONVERSATION is not an OPEN request in the erasure register, so the $PURPOSE purpose does not own it. A purpose may write ONLY on a thread the register owns and that is still open; anything else needs a human --approved-by." ;;
    2) refuse "the erasure register ($GDPR_REGISTER) is not readable, or does not answer the ownership query, so this writer cannot prove it owns conversation $CONVERSATION. Refusing rather than posting to a thread nobody can vouch for." ;;
    3) die "$SQLITE_BIN is missing or not executable; it is required to check register ownership." ;;
    4) die "$SHA256_BIN is missing or not executable; it is required to match the letter against the pipeline's claim." ;;
    5) refuse "no letter the erasure pipeline has claimed matches these exact bytes for conversation $CONVERSATION. A purpose write may post ONLY copy the pipeline has already ledgered as 'sending' for this thread; anything else needs a human --approved-by." ;;
    *) refuse "could not establish whether the $PURPOSE purpose owns conversation $CONVERSATION; refusing to post unverified." ;;
  esac
  # The log's `requester` field is the identity that asked. For a purpose write that is the
  # system, and it is set here rather than left empty so the record never reads as "nobody".
  REQUESTED_BY="$PURPOSE_IDENTITY"
  REQUESTER_NAME="$PURPOSE_IDENTITY"
else
printf '%s' "$REQUESTED_BY" | grep -qE '^U[A-Z0-9]{8,12}$' \
  || refuse "--requested-by must be the Slack USER ID of the human who asked (from message metadata, never a display name); got '${REQUESTED_BY:-<empty>}'."
REQUESTER_NAME="$(allowlisted_name "$REQUESTED_BY")" \
  || refuse "$REQUESTED_BY is not on the Intercom write allowlist ($ALLOWLIST_TEXT). Intercom writes need one of them to ask; everyone else is read-only. Do not post; say who can authorize it."
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
    if [ -n "$PURPOSE" ]; then
      # The purpose IS the authorization; there is no human to name and none is invented.
      APPROVER_NAME="$PURPOSE_IDENTITY"
    else
    [ -n "$APPROVED_BY" ] \
      || refuse "--approved-by <SlackUID> is required for a customer-facing reply: the human (Aaron, Jan or Nick) who explicitly asked for the CUSTOMER to be answered. A request to 'resolve' or 'give a summary' is a note, not a reply."
    printf '%s' "$APPROVED_BY" | grep -qE '^U[A-Z0-9]{8,12}$' \
      || refuse "--approved-by must be a human's Slack USER ID; '$APPROVED_BY' is not one. Self-approval, god_mode and agent identities never authorize a customer-facing reply (2026-08-31: a god_mode_self_approve reply reached customers under a human's name)."
    APPROVER_NAME="$(allowlisted_name "$APPROVED_BY")" \
      || refuse "$APPROVED_BY is not a human on the Intercom write allowlist ($ALLOWLIST_TEXT); a customer-facing reply needs one of them."
    fi
    # The customer never sees internal surfaces. The word list is Caroline's own redaction
    # set (plugins/intercom/src/sanitize-tool-leak.ts PATTERNS) plus the shapes the ops
    # agent's escalation notes actually carry: issue links, the mailbox number, "Ops
    # resolution", Slack mentions, admin ids. Paraphrase the bridge's customer_safe_summary.
    flat="$(printf '%s' "$BODY" | tr -s '[:space:]' ' ')"
    # Whole-word matching spelled out in portable ERE: BSD grep on a dev box and GNU grep
    # on node-8 do not agree on \b.
    W='(^|[^A-Za-z0-9_])'; E='([^A-Za-z0-9_]|$)'
    leak=""
    printf '%s' "$flat" | grep -qiE 'github\.com/|gitlab\.com/|issues? +(#|[0-9]{3,})|#[0-9]{3,}|<@U[A-Z0-9]+>' && leak="an issue link, issue number or Slack mention"
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
# CONVERSATION LOCK: one write per conversation at a time, for every caller of this script on this host
# (QA review of #1929, fourth round). The read-back below ties a part to this call by its text, and text cannot
# tell two callers apart when both send the same words: the GDPR pipeline, the backlog sender and an agent's
# reply all go through this file under one admin id, and a canned letter is the same bytes every time. Without
# the lock, call A's part could verify call B's POST that created nothing. With it, B does not read, log, claim
# or post until A has finished its read-back, so A's part is on file at B's pre-read and can never verify B.
# What the lock does NOT cover: a writer that does not go through this script. Caroline's plugin posts under
# the same admin id from the gateway process; if it posts the SAME words inside this call's window and this
# call's POST creates nothing, the read-back still accepts that part. The conversation then holds those words
# once, written in the window; the part id printed is the other writer's.
# It is taken BEFORE the pre-read. A lock that cannot be taken is a provably pre-send stop (exit 2): nothing
# was read, logged, claimed or posted, and the caller retries.
LOCK_FILE="$LOCK_DIR/conversation-$CONVERSATION.lock"
if [ -L "$LOCK_DIR" ] || ! { mkdir -p "$LOCK_DIR" && chmod 700 "$LOCK_DIR"; } 2>/dev/null; then
  die "the write lock directory $LOCK_DIR cannot be used, so two writes to conversation $CONVERSATION could not be kept apart. Nothing was logged, claimed or posted."
fi
if ! { exec 9>>"$LOCK_FILE"; } 2>/dev/null; then
  die "the write lock $LOCK_FILE cannot be opened, so two writes to conversation $CONVERSATION could not be kept apart. Nothing was logged, claimed or posted."
fi
if ! "$FLOCK_BIN" -w "$LOCK_WAIT_S" 9 2>/dev/null; then
  die "another write to conversation $CONVERSATION is in flight through this script (waited ${LOCK_WAIT_S}s for $LOCK_FILE). Nothing was logged, claimed or posted by this call; run it again."
fi

# ---------------------------------------------------------------------------------------
# PRE-READ: which parts the conversation ALREADY holds (QA review of the read-back, 2026-11-13). The read-back
# below accepts a part of ours created up to 10 s before the POST, to allow for clock difference with Intercom.
# On its own that let a part this bot wrote seconds earlier (Caroline answers live under the same admin id)
# stand in for a POST that created nothing: an error body or a part-less 2xx arrives with curl rc 0, the re-read
# finds the earlier part, and `POSTED` is printed for a letter nobody received. So the ids on file BEFORE the
# write are recorded here and can never verify it, whatever their time or body.
# It runs before the audit record and before the claim is consumed: a conversation that cannot be read is a
# provably pre-send stop (exit 2, nothing logged, nothing spent, nothing posted), and the caller retries.
set +e
PRE_READ="$("$TIMEOUT_BIN" 30 "$CURL_BIN" -sS -H "Authorization: Bearer $MUSOAI_INTERCOM_TOKEN" \
  -H "Accept: application/json" -H "Intercom-Version: $API_VERSION" \
  "$API_BASE/conversations/$CONVERSATION" 2>/dev/null)"
pre_rc=$?
PRE_IDS="$(printf '%s' "$PRE_READ" | "$JQ_BIN" -c \
  'if .type == "conversation" then [(.conversation_parts.conversation_parts // [])[] | (.id // "" | tostring)]
   else error("not a conversation") end' 2>/dev/null)"
pre_jq=$?
set -e
if [ "$pre_rc" -ne 0 ] || [ "$pre_jq" -ne 0 ] || [ -z "$PRE_IDS" ]; then
  die "conversation $CONVERSATION could not be read before the write (curl rc=$pre_rc), so a delivery could not be told from a part already on file. Nothing was logged, claimed or posted."
fi

# ---------------------------------------------------------------------------------------
# Log BEFORE the write (operations/SOUL.md, Write Activity Logging), then consume, then POST, then
# verify.
#
# ORDER IS LOAD-BEARING, and it is not the intuitive one (QA #1820): every way this block can fail -
# an unwritable log dir, a jq that cannot build the record, a full disk - exits 1 through `set -e`
# ABOVE the POST. So the record must be BUILT AND WRITTEN FIRST, and the single-use claim consumed
# only after it, immediately before the curl. Consuming first meant a failed audit write left a
# letter marked spent that nobody had received: `_intercom_send` saw a bare 1, could not tell it from
# a dropped connection, recorded `unknown`, and the never-retried state stranded the letter forever.
# With this order, a failed audit write leaves the claim INTACT, so the next tick re-claims the slot
# and retries - which is correct, because no customer received anything.
# The dir is untracked and rsync-excluded (deploy.sh), so create it like every other
# api-log writer does (qa-pr-approve.sh) and die only if that fails.
mkdir -p "$LOG_DIR" || die "cannot create log dir $LOG_DIR; refusing to write unlogged."
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# $$ keeps two same-second writes to one conversation from overwriting each other's record.
LOG_FILE="$LOG_DIR/intercom-$MODE-$CONVERSATION-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
if [ "$MODE" = "note" ]; then
  LOG_ACTION="intercom_internal_note"; LOG_APPROVED=""; LOG_AUDIENCE="$AUDIENCE"
  LOG_AUTH="$REQUESTER_NAME ($REQUESTED_BY) requested it in Slack; internal note, not customer-visible"
elif [ -n "$PURPOSE" ]; then
  # The record says what actually happened: a machine authorization, naming the purpose and the
  # ownership check that bounded it. It never claims a human asked.
  LOG_ACTION="intercom_customer_reply"; LOG_APPROVED="$PURPOSE_IDENTITY"; LOG_AUDIENCE="customer"
  LOG_AUTH="purpose $PURPOSE: the erasure register owns conversation $CONVERSATION; no human asked for this letter - it is a statutory obligation with its own clock"
else
  LOG_ACTION="intercom_customer_reply"; LOG_APPROVED="$APPROVED_BY"; LOG_AUDIENCE="customer"
  LOG_AUTH="$APPROVER_NAME ($APPROVED_BY) explicitly approved a customer-facing reply in Slack"
fi
"$JQ_BIN" -nc --arg action "$LOG_ACTION" --arg target "conversation:$CONVERSATION" \
  --arg req "$REQUESTED_BY" --arg appr "$LOG_APPROVED" --arg aud "$LOG_AUDIENCE" \
  --arg ts "$NOW" --arg auth "$LOG_AUTH" --arg purpose "$PURPOSE" \
  '{agent:"operations", action:$action, target:$target, requester:$req, approved_by:(if $appr == "" then null else $appr end), audience:$aud, timestamp:$ts, authorization:$auth} + (if $purpose == "" then {} else {purpose:$purpose} end)' \
  > "$LOG_FILE" \
  || die "cannot write the audit record $LOG_FILE; refusing to write unlogged. Nothing was posted."
# The `|| die` is not decoration: without it a redirection failure here is a BARE exit 1 through `set -e`, and a
# bare 1 is indistinguishable from a dropped connection after a POST. `_intercom_send` would call it Ambiguous,
# `deliver` would record `unknown`, and `unknown` is the never-retried state - so a letter nobody received would be
# stranded forever even though the claim is left intact. `die` exits 2 with an `ERROR:` prefix, which
# `send.WRITER_PREFLIGHT_RC` reads as PROVABLY pre-send, so `deliver` records `failed` and the next tick retries
# (QA #1820 finding 1).

# ---------------------------------------------------------------------------------------
# CONSUME THE CLAIM, and only now - the record above is written, so nothing left to fail sits between
# the consume and the POST. Every no-write exit and every refusal above has already returned, so
# --validate, --dry-run, a preflight refusal and a failed audit write all leave the claim intact and
# the real send still works. From here on the claim is spent, which is what makes a replay or a
# concurrent invocation unable to post the same statutory letter twice.
if [ -n "$PURPOSE" ]; then
  consume_rc=0
  purpose_consume_claim "$PURPOSE" "$CONVERSATION" "$BODY" || consume_rc=$?
  case "$consume_rc" in
    0) ;;
    5) refuse "the letter the erasure pipeline claimed for conversation $CONVERSATION has already been consumed by another invocation, so this one will not post it again. If the earlier attempt did not reach the customer, the pipeline must re-claim the slot before retrying." ;;
    3) die "$SQLITE_BIN is missing or not executable; it is required to consume the send claim." ;;
    4) die "$SHA256_BIN is missing or not executable; it is required to match the letter against the pipeline's claim." ;;
    *) refuse "the erasure register ($GDPR_REGISTER) could not be updated to consume the claim for conversation $CONVERSATION, so this writer cannot prove it is the only sender. Refusing rather than risking a duplicate statutory letter." ;;
  esac
fi

set +e
# Anchor for the delivery read-back: a part created BEFORE this cannot evidence this POST.
PRE_TS="$(date +%s)"
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
#   Reviewed baseline: deploy overwrites - 2026-11-13 (verif-scale-driver-f1, firstmate 007): node-8 has run this
#   read-back by hand since 2026-11-09T14:22Z (sha256 11d6f879f69b9406..., backup beside it as
#   intercom-ops-write.sh.pre-parttype-20261109T142229Z). This blob is those bytes plus this note, minus one
#   assignment nothing read (PART_TYPE, shellcheck SC2034), plus the pre-read above and its one predicate line
#   (QA review: a part on file before the write must not verify it). The deploy may replace the hand edit with it.
# Delivery read-back. The old check read [-1].part_type and demanded exactly "$EXPECT_PART", which failed a
# delivered letter whenever the conversation was CLOSED: Intercom answers a reply to a closed conversation with a
# part of type "open" (the reopen), carrying our body, so the letter landed and was recorded `unknown` with rc 4.
# Measured 2026-11-08: 31 of 31 such rows resolve to exactly one admin part of type "open", non-empty body,
# inside the attempt window. The predicate below is the discriminator, not the part type alone:
#   - author is OUR admin id (a customer's own part can never verify a send)
#   - part_type is the expected one, or "open" (= a reopen; only meaningful for a comment)
#   - its id was NOT on file at the pre-read (a part that existed before the write is never evidence of it)
#   - created_at in [PRE_TS-10, PRE_TS+120] (the 10 s is clock difference with Intercom, not licence for an
#     earlier part: the pre-read is what excludes those)
#   - the body is non-empty after tags are stripped (the bare reopen Intercom emits has an empty body)
#   - EXACTLY ONE such part. Two candidates means a duplicate delivery or a double reopen: a human must see it,
#     because picking one would hide the duplicate.
#   - the part's text is the text THIS call sent (below), in the POST's own response and in the re-read alike.
#
# Neither read is a receipt for this request. The re-read shows whatever the conversation holds, and so does
# the POST's own response: Intercom answers a reply with the FULL conversation, not with the part it made.
# Caroline and every other caller of this script write under the same admin id, so a part another writer added
# after the pre-read is new, ours by author and inside the window; without a tie to this request it would
# verify a POST that created nothing (QA review of #1929: second round for the re-read, fourth round for a 2xx
# response that holds only the other writer's part). So a part counts, wherever it was read, only when its
# stored text equals the text this call sent. That also settles the case that used to end "2 qualifying
# part(s)": this call's part and another writer's in one response are now told apart by their text.
# Intercom stores HTML: it wraps the text in tags,
# escapes & < > and turns a line that starts "1. " into a list item, dropping the number. Both sides are
# therefore compared with entities decoded and every run of white space made ONE space (ends trimmed), and
# the sent text is tried in two forms: as written, and with a leading "N. " removed from each line. In the
# stored HTML a tag that ends a block (p, br, li, ...) counts as white space and any other tag (a link, bold)
# as nothing. Word boundaries are KEPT: with all white space removed, "now here" and another writer's
# "no where" were the same text, and that other part verified a POST that created nothing (QA review of
# #1929, third round).
# Measured 2026-11-13 09:19Z, read-only, with these same jq definitions: the 92 GDPR letters whose sent
# text is on file (41 delivered as "comment", 51 as "open") against the part Intercom stores for each -
# 92 of 92 equal (83 as written, 9 in the list form). Internal notes and staff replies are NOT measured
# for equality: no copy of their sent text is kept. What was measured for them, 2026-11-13 09:59Z, is the
# shape Intercom stores: 150 notes and 148 replies this script wrote (matched to its audit log by time) carry
# only the tags p, a, br, ol and li, all of which the definitions below read; and, 10:18Z, the line this
# script puts at the head of a note came back as sent in 150 of 150 notes. A delivered write whose stored
# text differs in some way not seen here ends "POST NOT VERIFIED" (exit 4) - fail closed, as any unverified
# write does: the caller records it as unknown, never as sent, and a person reads the conversation.
readonly NORM_JQ='
def unent:
  gsub("&#(?<n>[0-9]+);"; [(.n | tonumber)] | implode)
  | gsub("&#[xX](?<h>[0-9a-fA-F]+);";
      [(.h | ascii_downcase | explode
        | reduce .[] as $c (0; . * 16 + (if $c >= 97 then $c - 87 else $c - 48 end)))] | implode)
  | gsub("&nbsp;"; " ") | gsub("&quot;"; "\"") | gsub("&apos;"; [39] | implode)
  | gsub("&lt;"; "<") | gsub("&gt;"; ">") | gsub("&amp;"; "&");
def squeeze: gsub("[[:space:]]+"; " ") | sub("^ "; "") | sub(" $"; "");
def stored_text:
  (. // "")
  | gsub("</?(?i:p|div|br|li|ul|ol|h[1-6]|blockquote|pre|table|tr|td|th)(?:[[:space:]/][^>]*)?>"; " ")
  | gsub("<[^>]*>"; "") | unent | squeeze;
def sent_forms: [squeeze, (gsub("(^|\n)[ \t]*[0-9]+\\.[ \t]+"; "\n") | squeeze)] | unique;
'
SENT_FORMS="$(printf '%s' "$FULL_BODY" | "$JQ_BIN" -Rsc "$NORM_JQ"' sent_forms' 2>/dev/null || printf '[]')"
# $1 = a conversation (JSON text): the POST's own response, or the re-read.
_part_filter() {
  printf '%s' "$1" | "$JQ_BIN" -c --arg admin "$INTERCOM_ADMIN_ID" --arg exp "$EXPECT_PART" \
    --argjson lo "$((PRE_TS - 10))" --argjson hi "$((PRE_TS + 120))" --argjson pre "$PRE_IDS" \
    --slurpfile sent <(printf '%s' "$SENT_FORMS") \
    "$NORM_JQ"'
     [(.conversation_parts.conversation_parts // [])[]
      | select(((.id // "") | tostring) as $i | ($pre | index($i)) == null)
      | select((.author.id // "" | tostring) == $admin)
      | select(.part_type == $exp or ($exp == "comment" and .part_type == "open"))
      | select((.created_at // 0) >= $lo and (.created_at // 0) <= $hi)
      | (.body | stored_text) as $text
      | select(($text | length) > 0)
      | select((($sent[0] // []) | index($text)) != null)
      | {id: .id, part_type: .part_type}]' 2>/dev/null || printf '[]'
}
MATCHES="$(_part_filter "$RESPONSE")"
MATCH_N="$(printf '%s' "$MATCHES" | "$JQ_BIN" -r 'length' 2>/dev/null || printf 0)"
if [ "$MATCH_N" = "0" ]; then
  # No qualifying part in the response body: ask Intercom what the conversation now holds, and apply
  # the SAME predicate (same pre-read ids, same lower bound, same text - the fallback must not pick up a prior
  # part or somebody else's write either).
  REFETCH="$("$TIMEOUT_BIN" 30 "$CURL_BIN" -sS -H "Authorization: Bearer $MUSOAI_INTERCOM_TOKEN" \
    -H "Accept: application/json" -H "Intercom-Version: $API_VERSION" \
    "https://api.intercom.io/conversations/$CONVERSATION" 2>/dev/null || true)"
  MATCHES="$(_part_filter "$REFETCH")"
  MATCH_N="$(printf '%s' "$MATCHES" | "$JQ_BIN" -r 'length' 2>/dev/null || printf 0)"
fi
if [ "$MATCH_N" != "1" ]; then
  printf 'POST NOT VERIFIED: %s qualifying part(s) for admin %s in [%s-10,%s+120] (expected 1). Logged at %s. Response:\n%s\n' \
    "$MATCH_N" "$INTERCOM_ADMIN_ID" "$PRE_TS" "$PRE_TS" "$LOG_FILE" "$RESPONSE" >&2
  exit 4
fi
PART_ID="$(printf '%s' "$MATCHES" | "$JQ_BIN" -r '.[0].id')"

printf 'POSTED %s conversation=%s part=%s\n' "$MESSAGE_TYPE" "$CONVERSATION" "$PART_ID"
