#!/bin/bash -p
# ABSOLUTE INTERPRETER, PRIVILEGED MODE, and PATH replaced before anything runs.
#
# `-p` is not decoration. Bash sources $BASH_ENV and imports exported shell FUNCTIONS from
# the environment BEFORE executing line 1 — so a caller could point BASH_ENV at a file that
# prints POSTED/PUBLISHED and exits 0, or export a hostile `jq` function, and that code runs
# ahead of the PATH reset and every refusal below. Privileged mode makes bash ignore
# BASH_ENV, ENV, SHELLOPTS, BASHOPTS, CDPATH and GLOBIGNORE, and skip inherited functions.
# The startup itself was the last thing still caller-controlled.
#
# `#!/usr/bin/env bash` resolves the SHELL through PATH, so a caller that prepends a
# directory containing a `bash` shim owns this process before a single line of pinning
# executes — every constant below is then decoration. And even with the real shell, the
# helper commands (jq, grep, awk, sed, timeout) were PATH-resolved too: a `jq` shim can
# rewrite the payload after validation, so the pinned kubectl still reads the real
# cluster-wide key and the pinned curl still publishes an attacker-built body.
#
# Pinning individual programs one at a time was losing that race repeatedly. Replacing PATH
# outright fixes the whole class in one line, and it goes FIRST — before any external
# command, including the ones in the guards.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
set -euo pipefail

# agent-bridge-request.sh — the ONLY path an agent uses to file a request with the
# engineering data lane over the agent bridge.
#
# WHY THIS IS A SCRIPT AND NOT PROSE
# The CS/ops agents were attempting data-layer fixes themselves (DAG edits, re-syncs,
# bulk credit rewrites) without lane knowledge. Two triages on 2026-08-26 show the cost:
# a "0 plays" cluster that looked like a capture gap was a frozen serving-cube generation
# (pdp-v4 #222), and a "credits missing" cluster that looked like a bad flag was an
# AUTHORIZED ops deletion 13-19 days older than the flag (IDP #1539) — a "fix" there would
# have silently reversed a deliberate human action. The doctrine is "request, don't fix",
# and prose is not enforcement: this wrapper is the deterministic gate below the LLM. It
# validates the request shape, refuses secrets, typed-away and pattern-detectable PII, and
# pre-baked diagnoses (see the PII-ceiling note below for the three prose fields it cannot
# police), de-duplicates
# on request_id, and posts to the durable mailbox. The agent never hand-rolls the gh call.
#
# Protocol (canonical): Muso-AI/platform-data-processing docs/AGENT_BRIDGE_PROTOCOL.md
# Mailbox: Muso-AI/platform-data-processing issue #2405
#
# Usage:
#   agent-bridge-request.sh --file <request.json>              # validate, de-dupe, post
#   agent-bridge-request.sh --file <request.json> --dry-run     # validate + render only
#   agent-bridge-request.sh --file <request.json> --validate    # validate only
#   agent-bridge-request.sh --file <request.json> --follow-up   # add to an existing thread
#
# Exit codes: 0 ok · 1 validation refusal · 2 usage/environment error
#             3 duplicate request_id · 4 post failed

# PINNED. The mailbox is the point of this wrapper: "#2405 is the system of record" is not
# a claim you can make while the destination is an environment variable. An operations agent
# could set AGENT_BRIDGE_REPO/ISSUE and post a request — customer emails and internal IDs
# included — into any issue in any repo it can write, and GH_BIN could redirect the write
# entirely. Constants, plus an absolute path so PATH cannot redirect it either.
# TESTABLE is a BUILD-TIME literal, and the deployed copy is always 0. The test suite runs a
# DERIVED COPY of this file with the line flipped to 1 (see scripts/tests/*.bats), which is
# what makes the test backend a property of the artefact rather than of the environment.
# Anything selectable by the caller is selectable by the agent: an ops invocation prefixed
# with AGENT_BRIDGE_TEST_DIR would have validated a request, written local files, printed
# `POSTED ...` and exited 0 while the mailbox never received anything — the agent closing
# the loop on a request that does not exist. The doctrine gate asserts this line reads 0.
# readonly: a later `TESTABLE=$((1))` would otherwise silently re-enable the test backend
# on a DEPLOYED copy — the gate only checked that this line existed, not that it stayed the
# effective value. `readonly` makes the second assignment a runtime error rather than a
# quiet override, so the guarantee lives in the shell rather than in a grep.
readonly TESTABLE=0

REPO="Muso-AI/platform-data-processing"
ISSUE="2405"
GH_BIN="/usr/local/bin/gh"

# NOTHING ABOUT THE DESTINATION IS OVERRIDABLE — not the repo, not the issue, and not the
# client. Three attempts converged here, and the last two failed the same way: I kept trying
# to keep a dangerous capability and guard it. First `AGENT_BRIDGE_REPO` had to be paired
# with an explicit stub (a copy of the real `gh` is indistinguishable from a stub); then the
# repo was pinned but the binary was still swappable (an arbitrary shim is arbitrary code,
# so it simply rewrites the arguments before calling the authenticated client).
#
# The capability is therefore removed rather than constrained. In production this script
# invokes exactly one absolute binary with exactly one repo and issue, and there is no
# environment variable that changes any of the three.
#
# TEST MODE (AGENT_BRIDGE_TEST_DIR) is structurally incapable of a live post because it does
# not call `gh` AT ALL: existing comments are read from a file in that directory and a "post"
# is a file written into it. There is no client to substitute, so there is nothing to point
# at GitHub. That is a stronger property than any check on a supplied binary could be.
TEST_DIR=""

VALID_TYPES="systemic_check data_verification fix_request escalation"
# `from` decides who a reply is routed back to, and it was caller-claimed from a list of
# seven — so any invocation could attribute its request to another agent and misdirect the
# answer. The skill is registered to exactly ONE agent (the doctrine gate asserts that), so
# the identity is pinned to match. Onboarding a second agent means registering the skill AND
# widening this deliberately, which is the point: identity should change by review, not by
# argument.
readonly PINNED_FROM="operations"

FILE=""
MODE="post"
FORCE=0

die()    { echo "ERROR: $*" >&2; builtin exit 2; }
refuse() { echo "REFUSED: $*" >&2; exit 1; }


is_ts() { # ISO8601 UTC — SHAPE, then CALENDAR VALIDITY, then ROUND-TRIP.
  # The pattern alone accepted 2026-13-45T99:99:99Z: well-formed, impossible, and posted as
  # if it were a real observation time. A lane correlating events on it would silently place
  # the report outside every window it looked in.
  #
  # `date` alone is not enough either, and the difference is platform-dependent in exactly
  # the way that ships a bug: GNU rejects 2026-02-30, BSD NORMALISES it to Mar 2 and exits 0.
  # So the parsed value is formatted back and compared to the input — a normalisation changes
  # the string, which makes the check identical on both, instead of stricter on the deploy
  # host than on a laptop. (This lane has already produced one bug in each direction from
  # exactly this asymmetry.)
  printf '%s' "$1" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' || return 1
  local rt=""
  rt="$(date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  if [ -z "$rt" ]; then
    rt="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  fi
  if [ -z "$rt" ]; then
    # EMPTY MEANS TWO DIFFERENT THINGS and they must not be conflated: `date` rejected the
    # value, or there is no usable `date` at all. Treating both as "cannot check" let
    # 2026-13-45T99:99:99Z through — a rejection read as an absence. So probe with a value
    # known to be good and let the probe decide which case this is.
    if date -u -d "2026-01-01T00:00:00Z" +%Y >/dev/null 2>&1 \
       || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "2026-01-01T00:00:00Z" +%Y >/dev/null 2>&1; then
      return 1   # a working `date` refused this value: it is not a real instant
    fi
    return 0     # no usable `date`; the shape check stands alone
  fi
  [ "$rt" = "$1" ]
}

# Deployed copies reject EVERY override before they can emit the production success
# contract. A caller must not be able to select a backend that prints POSTED without posting.
if [ "$TESTABLE" != "1" ]; then
  for _v in AGENT_BRIDGE_TEST_DIR AGENT_BRIDGE_REPO AGENT_BRIDGE_ISSUE GH_BIN_OVERRIDE \
            AGENT_BRIDGE_GH_TIMEOUT_SECS \
            AGENT_BRIDGE_TEST_READ_DELAY; do
    eval "_set=\${$_v:-}"
    [ -z "$_set" ] || die "$_v is not settable on a deployed copy of this script. The mailbox is $REPO#$ISSUE, and the client is $GH_BIN — neither of them is a parameter, because a caller-selectable backend can print success without delivering anything."
  done
else
  TEST_DIR="${AGENT_BRIDGE_TEST_DIR:-}"
  [ -n "${GH_BIN_OVERRIDE:-}" ] && GH_BIN="$GH_BIN_OVERRIDE"
  REPO="${AGENT_BRIDGE_REPO:-$REPO}"
  ISSUE="${AGENT_BRIDGE_ISSUE:-$ISSUE}"
fi
# FREEZE EVERY RESOLVED PRODUCTION CONSTANT. Not just the ones a finding named: a
# production-only reassignment inserted AFTER the test seam — changing REPO to another issue,
# or GH_BIN to a capture shim, only when TESTABLE=0 — would leave the derived-copy tests green
# and the doctrine gate satisfied, while the deployed wrapper posted customer evidence to the
# wrong mailbox. `readonly` makes that a runtime error; the doctrine gate counts assignments
# so it is a CI error too. Both, because either alone still permits the other half.
readonly REPO ISSUE GH_BIN TEST_DIR

# RUNTIME SELF-VERIFICATION — see the note in agent-bridge-notify.sh. A source-scanning gate
# has to enumerate spellings of an assignment; asserting the VALUE does not.
if [ "$TESTABLE" != "1" ]; then
  builtin test "$REPO" = "Muso-AI/platform-data-processing" || { printf 'ERROR: REPO was altered: %s\n' "$REPO" >&2; builtin exit 2; }
  builtin test "$ISSUE" = "2405" || { printf 'ERROR: ISSUE was altered: %s\n' "$ISSUE" >&2; builtin exit 2; }
  builtin test "$GH_BIN" = "/usr/local/bin/gh" || { printf 'ERROR: GH_BIN was altered: %s\n' "$GH_BIN" >&2; builtin exit 2; }
  builtin test "$PINNED_FROM" = "operations" || { printf 'ERROR: PINNED_FROM was altered: %s\n' "$PINNED_FROM" >&2; builtin exit 2; }
  [ -z "$TEST_DIR" ]                                      || die "TEST_DIR is set on a deployed copy: $TEST_DIR"
fi

# Numeric knobs are validated wherever they come from — a non-numeric staleness or timeout
# would make the arithmetic below silently wrong rather than loudly wrong.
for _n in AGENT_BRIDGE_GH_TIMEOUT_SECS AGENT_BRIDGE_TEST_READ_DELAY; do
  eval "_nv=\${$_n:-}"
  [ -z "$_nv" ] && continue
  printf '%s' "$_nv" | grep -qE '^[0-9]+$' || die "$_n must be a non-negative integer, got '$_nv'"
done

# `shift 2` with no value present made `set -e` kill the script: exit 1, no output — a USAGE
# error wearing the validation-refusal code, with nothing telling the caller what to fix.
# needval() turns "you forgot the value" into the documented exit 2 and says which flag.
needval() { [ "$2" -ge 2 ] || die "$1 requires a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --file)     needval --file "$#"; FILE="$2"; shift 2 ;;
    --dry-run)  MODE="dry-run"; shift ;;
    --validate) MODE="validate"; shift ;;
    --follow-up|--force) FORCE=1; shift ;;
    # Marker-extracted, never line-numbered: a line range silently prints the wrong
    # block the first time anyone edits the header above it.
    -h|--help)  sed -n '/^# Usage:/,/^# Exit codes:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          die "unknown argument: $1" ;;
  esac
done

[ -n "$FILE" ] || die "--file <request.json> is required"
[ -f "$FILE" ] || die "no such file: $FILE"
command -v jq >/dev/null 2>&1 || die "jq is required"

# ------------------------------------------------- READ ONCE, THEN NEVER AGAIN --
# TIME-OF-CHECK / TIME-OF-USE. Every check below used to re-open the caller's path —
# eighteen separate reads — and the render step re-opened it a nineteenth time to build the
# comment it posts. The file is caller-owned and mutable, so a swap between the last check
# and the render posted content that was never validated: credentials, PII, a different
# request entirely. Validation of one version and publication of another is not validation.
#
# So the bytes are snapshotted ONCE into a private copy, and everything after this line —
# every scan, every type check, the rendered body — reads only the copy. The caller can do
# what it likes to the original afterwards; it is no longer part of this transaction.
# The copy lives in a 0700 dir because it holds the request's own contents.
SNAP_ORIG_LABEL="$FILE"
SNAP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-bridge-request.XXXXXX")"
chmod 700 "$SNAP_DIR"
SNAP="$SNAP_DIR/request.json"
trap 'rm -rf "$SNAP_DIR"' EXIT
cat -- "$FILE" > "$SNAP" 2>/dev/null || die "could not read $FILE"
# From here on FILE refers to the immutable snapshot. Deliberately reassigned rather than
# introducing a second variable: a second variable is how three of the eighteen reads would
# have kept pointing at the caller's path.
FILE="$SNAP"

jq empty "$FILE" 2>/dev/null || refuse "not valid JSON: $SNAP_ORIG_LABEL"

j() { jq -r "$1" "$FILE" 2>/dev/null; }

# ------------------------------------------------------------------ envelope --
# TYPE BEFORE COERCE. `jq -r` renders a number as a string, so `request_id: 12345` and
# `symptom: 12345` both validated as well-formed — the envelope accepted values whose type it
# never agreed to. Same defect the array members had, one level up. Each of these is a string
# by contract, so the contract is checked before anything reads the value.
for _e in request_id type from opened_at symptom; do
  _t="$(jq -r --arg k "$_e" '.[$k] | type' "$FILE")"
  [ "$_t" = "string" ] || [ "$_t" = "null" ] \
    || refuse "$_e must be a STRING, got a $_t. The envelope fields are text by contract; a coerced number is not a value this protocol agreed to carry."
done

REQUEST_ID="$(j '.request_id // ""')"
TYPE="$(j '.type // ""')"
FROM="$(j '.from // ""')"
OPENED_AT="$(j '.opened_at // ""')"
SYMPTOM="$(j '.symptom // ""')"

case "$REQUEST_ID" in
  "") refuse "request_id is required (stable kebab-case key; follow-ups re-use it)" ;;
esac
if ! printf '%s' "$REQUEST_ID" | grep -qE '^[a-z0-9][a-z0-9-]{4,80}$'; then
  refuse "request_id must be kebab-case, 5-81 chars, [a-z0-9-]: got '$REQUEST_ID'"
fi

case " $VALID_TYPES " in
  *" $TYPE "*) ;;
  *) refuse "type must be one of: $VALID_TYPES (got '$TYPE')" ;;
esac

[ "$FROM" = "$PINNED_FROM" ] \
  || refuse "from must be '$PINNED_FROM' (got '$FROM'). This wrapper files as one identity, because \`from\` decides where the reply is routed and a claimed identity misdirects it."

if ! is_ts "$OPENED_AT"; then
  refuse "opened_at must be UTC ISO8601 (YYYY-MM-DDTHH:MM:SSZ), got '$OPENED_AT'"
fi

[ -n "$SYMPTOM" ] || refuse "symptom is required — one line describing what the CUSTOMER sees"
case "$SYMPTOM" in *$'\n'*) refuse "symptom must be a SINGLE line — the documented invariant, and a second line is where a forged marker hides" ;; esac
[ "${#SYMPTOM}" -le 400 ] || refuse "symptom is ${#SYMPTOM} chars; keep it to one line (<= 400)"

[ "$(j '.evidence | type')" = "object" ] || refuse "evidence must be an object"

# ------------------------------------------------- symptom, not diagnosis --
# A pre-baked cause anchors the investigation on the wrong lane and burns the first
# hour. A hypothesis is welcome, but it must be labelled as one, so `hypothesis` is
# the ONLY field allowed to carry a theory.
BANNED_KEYS="$(jq -r '[paths | .[] | select(type == "string")] | unique[]' "$FILE" \
  | grep -ixE 'cause|root_cause|rootcause|diagnosis|diagnostic_conclusion|fix|the_fix|remedy|resolution_steps' || true)"
if [ -n "$BANNED_KEYS" ]; then
  refuse "a request states SYMPTOMS, not causes or fixes. Remove: $(echo "$BANNED_KEYS" | tr '\n' ' ')(use 'hypothesis' if you have a theory, clearly labelled)"
fi

# --------------------------------------------------- per-type requirements --
need() { # need <jq-path> <human name> — a NON-EMPTY STRING, not merely "renders to something"
  # `jq -r` renders [] as "[]" and {} as "{}", both non-empty, so a presence check on the
  # rendered text accepted `"claim": []` as a well-formed claim and the data lane received a
  # verification request with nothing to verify. The type is part of the requirement: these
  # are text fields a human reads, so anything that is not a non-blank string is missing.
  local t v
  t="$(j "$1 | type")"
  [ "$t" = "null" ] && refuse "$TYPE requires $2"
  [ "$t" = "string" ] || refuse "$TYPE requires $2 to be a STRING, got a $t"
  v="$(j "$1")"
  printf '%s' "$v" | grep -q '[^[:space:]]' || refuse "$TYPE requires $2 (it is present but blank)"
}
case "$TYPE" in
  systemic_check)
    # "Systemic" MEANS >= 2 distinct users. One loud customer reporting three times is
    # not a class, and routing it as one gives the investigation the wrong shape and
    # the wrong priority. The distinct-user key is the email, so uniqueness is checked
    # on the deduplicated array, not its length. A single-customer report is a
    # data_verification -- that is what the type exists for.
    [ "$(jq -r '.evidence.user_emails | type' "$FILE")" = "array" ] \
      || refuse "systemic_check requires evidence.user_emails to be an ARRAY of distinct customer emails"
    # TYPE BEFORE TRANSFORM. `ascii_downcase` on a number makes jq throw, and the script
    # exited 5 — outside the documented 0-4 contract, so a caller could neither classify the
    # failure nor be told what to fix. A malformed request must be a REFUSAL, not a crash:
    # the contract is part of the interface, and an undocumented exit code is a broken one.
    nonstr="$(jq -r '[.evidence.user_emails[] | select(type != "string")] | length' "$FILE")"
    [ "$nonstr" = "0" ] \
      || refuse "evidence.user_emails contains $nonstr non-string entries. Every entry must be an email string."
    distinct="$(jq -r '[.evidence.user_emails[] | ascii_downcase | gsub("^\\s+|\\s+$"; "")] | unique | length' "$FILE")"
    [ "$distinct" -ge 2 ] || refuse "systemic_check requires >= 2 DISTINCT user emails (found $distinct). One customer is not a class -- file a data_verification instead."
    need '.evidence.first_seen' 'evidence.first_seen'
    # count is a NUMBER, so it is checked by check_num below rather than by need(),
    # which now (correctly) demands a string.
    [ "$(j '.evidence.count | type')" = "null" ] && refuse "systemic_check requires evidence.count"
    # A NON-NEGATIVE INTEGER, checked here rather than left to the loose `^[0-9]+$` guard
    # below. The old shape skipped the lower-bound comparison for anything that did not
    # match that pattern, so `count: -1` and `count: 2.5` sailed past it and reached the
    # lane as an impossible priority signal — a count of reports cannot be negative and
    # cannot be a fraction.
    cnt_raw="$(j '.evidence.count')"
    printf '%s' "$cnt_raw" | grep -qE '^(0|[1-9][0-9]*)$' \
      || refuse "evidence.count must be a non-negative INTEGER (a tally of reports), got '$cnt_raw'"
    # count is reports, which can exceed users, but it can never be fewer than the
    # distinct users it is supposed to be counting.
    cnt="$(j '.evidence.count')"
    if printf '%s' "$cnt" | grep -qE '^[0-9]+$' && [ "$cnt" -lt "$distinct" ]; then
      refuse "evidence.count ($cnt) is lower than the number of distinct users ($distinct) -- one of the two is wrong"
    fi
    ;;
  data_verification)
    need '.evidence.claim'       'evidence.claim (the specific checkable assertion)'
    # A CHECKABLE assertion is about data: a number, a date, a state. Requiring one digit
    # makes the field carry what its name promises, and incidentally makes a bare name an
    # invalid claim rather than an accepted one.
    printf '%s' "$(j '.evidence.claim')" | grep -qE '[0-9]' \
      || refuse "evidence.claim must be CHECKABLE — it needs a number, a date, or a count the lane can verify ('qobuz streams frozen at 12,480 since 2026-08-04'). An assertion with nothing measurable in it cannot be confirmed or refuted."
    need '.evidence.observed_at' 'evidence.observed_at'
    for _l in profile_ids track_ids; do
      _t="$(jq -r --arg k "$_l" '.evidence[$k] | type' "$FILE")"
      [ "$_t" = "null" ] || [ "$_t" = "array" ] \
        || refuse "evidence.$_l must be an ARRAY, got a $_t"
    done
    ids="$(jq -r '((.evidence.profile_ids // []) + (.evidence.track_ids // [])) | length' "$FILE")"
    [ "$ids" -ge 1 ] || refuse "data_verification requires at least one profile_id or track_id"
    ;;
  fix_request)
    need '.evidence.known_issue' 'evidence.known_issue (an issue link/number that already OWNS this defect — if there is none, file a systemic_check instead)'
    [ "$(j '.evidence.customer_impact | type')" = "object" ] \
      || refuse "fix_request requires evidence.customer_impact as an OBJECT: {\"surface\", \"metric\", \"direction\", \"affected_count\"}. It used to be a sentence, and a sentence is where a customer name gets in."
    # TYPE BEFORE COERCE, again: `jq -r` renders 5 as "5", so a numeric `surface` or a
    # string `affected_count` reached the enum/integer checks already stringified and could
    # satisfy them. Same defect as the envelope fields and the array members, third level.
    for _k in surface metric direction; do
      _t="$(jq -r --arg k "$_k" '.evidence.customer_impact[$k] | type' "$FILE")"
      [ "$_t" = "string" ] || refuse "evidence.customer_impact.$_k must be a STRING, got a $_t"
    done
    [ "$(j '.evidence.customer_impact.affected_count | type')" = "number" ] \
      || refuse "evidence.customer_impact.affected_count must be a NUMBER, got a $(j '.evidence.customer_impact.affected_count | type')"
    ci_surface="$(j '.evidence.customer_impact.surface // ""')"
    case "$ci_surface" in
      analytics|credits|profile|verification|billing|search|catalog|other) ;;
      *) refuse "evidence.customer_impact.surface must be one of: analytics credits profile verification billing search catalog other (got '$ci_surface')" ;;
    esac
    ci_direction="$(j '.evidence.customer_impact.direction // ""')"
    case "$ci_direction" in
      missing|frozen|wrong|duplicated|delayed) ;;
      *) refuse "evidence.customer_impact.direction must be one of: missing frozen wrong duplicated delayed (got '$ci_direction')" ;;
    esac
    ci_metric="$(j '.evidence.customer_impact.metric // ""')"
    printf '%s' "$ci_metric" | grep -qE '^[a-z0-9_]{2,40}$' \
      || refuse "evidence.customer_impact.metric must be a short snake_case token naming WHAT is wrong (plays, credits_count, stream_total) — 2-40 chars of [a-z0-9_]. A token cannot carry a sentence, which is the point."
    ci_n="$(j '.evidence.customer_impact.affected_count // ""')"
    printf '%s' "$ci_n" | grep -qE '^[1-9][0-9]*$' \
      || refuse "evidence.customer_impact.affected_count must be an integer >= 1 (got '$ci_n')"
    ci_extra="$(jq -r '.evidence.customer_impact | keys - ["surface","metric","direction","affected_count","paying"] | join(", ")' "$FILE")"
    [ -z "$ci_extra" ] \
      || refuse "evidence.customer_impact has off-schema keys: $ci_extra. Allowed: surface, metric, direction, affected_count, paying."
    ci_paying="$(j '.evidence.customer_impact.paying | type')"
    [ "$ci_paying" = "null" ] || [ "$ci_paying" = "boolean" ] \
      || refuse "evidence.customer_impact.paying must be true or false, got a $ci_paying"
    ;;
  escalation)
    [ "$(j '.evidence.count | type')" = "null" ] && refuse "escalation requires evidence.count"
    cnt_raw="$(j '.evidence.count')"
    printf '%s' "$cnt_raw" | grep -qE '^[1-9][0-9]*$' \
      || refuse "escalation requires evidence.count >= 1 (got '$cnt_raw'). An escalation is 'customer-visible AND spreading'; zero reports is neither, and filing one spends the real-time signal on a non-event — the notifier's mailbox-first check would then accept it."
    # §3.4 enumerates exactly three grounds, so this is an ENUM rather than a sentence about
    # them. An enum cannot carry a name, and it also stops "spreading" being asserted without
    # saying in which of the three senses it is meant.
    why="$(j '.evidence.why_escalating // ""')"
    case "$why" in
      count_climbing|class_wide|money_or_reputation) ;;
      *) refuse "evidence.why_escalating must be exactly one of: count_climbing (the report count is rising within a single day) · class_wide (a customer-visible surface is wrong for a whole class of users) · money_or_reputation (money or public reputation is exposed). Got '$why'." ;;
    esac
    rate="$(j '.evidence.rate // ""')"; first="$(j '.evidence.first_seen // ""')"
    [ -n "$rate" ] || [ -n "$first" ] || refuse "escalation requires evidence.rate or evidence.first_seen (an escalation is a claim about a TREND)"
    ;;
esac

# ------------------------------------------------------- security scanning --
# Bridge messages are reports and data. They carry emails and internal IDs, and
# nothing else that identifies a person or authenticates anyone — enforced for everything
# that can be detected, and stated as a rule for the three prose fields that cannot be.
#
# The scan surface is deliberately BOTH representations:
#   RAW     — the file bytes as written.
#   DECODED — every key path and scalar value as jq resolves them, one "path=value"
#             line each. This is what actually gets posted (the comment renders
#             `jq -S '.'`), so it is the representation an attacker controls: a key
#             written "api_key" is invisible to a raw-byte grep and arrives in
#             the comment as api_key. Scanning the decoded form closes that.
# Credential detectors see the FULL text including URLs — a token smuggled in a query
# string (?access_token=ghp_...) is still a leaked token. Only the entropy heuristic,
# the one detector with a real false-positive problem, gets the URL exemption, and
# only for the URL's own opaque path segments.
RAW="$(cat "$FILE")"
DECODED="$(jq -r '
  [ paths(scalars) as $p
    | (($p | map(tostring) | join(".")) + "=" + (getpath($p) | tostring)) ]
  | join("\n")' "$FILE")"
SCAN="$RAW
$DECODED"
# Entropy-only surface. The exemption exists because conversation deeplinks carry long
# opaque PATH segments that are not secrets. It used to strip the whole URL, which threw
# the query string away with it — and a query string is exactly where a credential rides
# (`?token=<62 opaque chars>` validated and was rendered into the durable mailbox comment).
# So the exemption now stops at the first `?` or `#`: scheme, host and path are dropped,
# everything after them stays on the entropy surface. Narrow the exemption to the part
# that actually justified it, rather than to "URLs".
ENTROPY_SCAN="$(printf '%s' "$SCAN" | sed -E 's|https?://[^"[:space:]?#]*||g')"

secret_hit()   { printf '%s' "$SCAN" | grep -qE  "$1"; }
secret_hit_i() { printf '%s' "$SCAN" | grep -qiE "$1"; }

# The comment this wrapper appends ends with a machine marker that the real-time notifier
# treats as proof an escalation was filed. So user content may not contain that marker
# text at all: if it cannot be written, it cannot be forged, and the notifier's anchored
# match then has nothing to match against.
secret_hit '<!--[[:space:]]*agent-bridge' \
  && refuse "the agent-bridge marker text may not appear in a request. It is the machine token that proves an escalation was filed, and content that can write it can forge one."
secret_hit 'AKIA[0-9A-Z]{12,}'                        && refuse "an access-key-shaped string is present. Bridge requests carry NO credentials."
secret_hit 'BEGIN [A-Z ]*PRIVATE KEY'                 && refuse "a private key is present. Bridge requests carry NO credentials."
secret_hit '(ghp|gho|ghu|ghs)_[A-Za-z0-9]{20,}'       && refuse "a GitHub token is present. Bridge requests carry NO credentials."
secret_hit 'github_pat_[A-Za-z0-9_]{20,}'             && refuse "a GitHub token is present. Bridge requests carry NO credentials."
secret_hit 'xox[baprs]-[A-Za-z0-9-]{10,}'             && refuse "a Slack token is present. Bridge requests carry NO credentials."
secret_hit '(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}'    && refuse "an API key is present. Bridge requests carry NO credentials."
secret_hit_i '(password|passwd|secret_key|api[_-]?key|authorization: *bearer|access_token|refresh_token)' \
  && refuse "a credential-shaped field is present. Bridge requests carry NO credentials."
secret_hit_i '[0-9]{13,19}([ -][0-9]{4}){0,3}[^0-9]*(card|visa|mastercard|amex)' \
  && refuse "payment-card-shaped data is present. The PII ceiling forbids it: emails and internal IDs only."

# --- payment cards: Luhn, not keywords -------------------------------------------
# The old check needed a nearby word ("card", "visa", …), so a bare 16-digit PAN passed and
# could be written to the durable mailbox or the 72h-retained real-time lane. Length alone
# would catch large counts too, so the discriminator is the checksum every payment card
# carries and an arbitrary number does not: a 13-19 digit run that satisfies Luhn is a card.
looks_like_a_card() { # looks_like_a_card <text>
  # NORMALISE, THEN CHECKSUM — all inside awk, because the sed one-liner that did the
  # normalising used a GNU-only `:label;` form that BSD sed rejects: it failed open on macOS
  # while passing in CI, which is the worst way for a security check to be portable.
  #
  # Why normalise at all: splitting on every non-digit turned the way cards are actually
  # written — `4111 1111 1111 1111` — into four 4-digit candidates, none of which reaches
  # the 13-19 digit window, so the grouped (common) form sailed through while only the bare
  # form was caught. Collapsing a single space or hyphen BETWEEN two digits rejoins a
  # grouped PAN without gluing unrelated numbers: "12,480" keeps its comma, and 2026-08-24
  # collapses to 8 digits, well short of the window.
  printf '%s' "$1" | awk '
    { buf = buf $0 " " }
    END {
      while (match(buf, /[0-9][ -][0-9]/)) {
        buf = substr(buf, 1, RSTART) substr(buf, RSTART + 2)
      }
      n = split(buf, parts, /[^0-9]+/)
      for (k = 1; k <= n; k++) {
        d = parts[k]
        if (length(d) < 13 || length(d) > 19) continue
        sum = 0; alt = 0
        for (i = length(d); i > 0; i--) {
          v = substr(d, i, 1) + 0
          if (alt) { v *= 2; if (v > 9) v -= 9 }
          sum += v; alt = !alt
        }
        if (sum % 10 == 0) { found = 1 }
      }
      exit(found ? 0 : 1)
    }
  '
}
looks_like_a_card "$SCAN" \
  && refuse "a Luhn-valid 13-19 digit number is present — that is a payment card, whatever it is labelled. The PII ceiling forbids it: emails and internal IDs only."
secret_hit_i '(ssn|social security|passport number|date of birth|dob:)' \
  && refuse "identity-document PII is present. The PII ceiling forbids it: emails and internal IDs only."

# --- PII ceiling: HALF of it is mechanical, and the half that is not is stated ----
# WHAT THIS ENFORCES: the evidence-field allowlist. Pattern-matching every PII class is a
# game you lose, so the schema — which is small and known — is the gate instead: a
# "customer_phone" or "street_address" field never reaches the mailbox because it is not a
# field this protocol has. Payment cards, phone numbers, credentials and opaque blobs are
# refused by shape wherever they appear.
#
# WHAT IT CANNOT ENFORCE: `symptom`, `claim` and `hypothesis` — the three fields that are
# still sentences, each for a reason: what the customer sees in their words, the checkable
# assertion, and an explicitly-labelled theory. Every other field is now typed —
# customer_impact is an object with an enum/token/integer schema, why_escalating is an enum,
# the generic channel (note, detail, what_they_see) and the three optional prose fields were
# removed — so `symptom`, `claim` and `hypothesis` are the three places a sentence can live.
# `claim` has to be one: a
# data_verification is an assertion a human reads and checks. Nothing distinguishes
# "Jane Doe: my plays are gone" from a legitimate one-line claim, and no scanner will.
# All three are ADVISORY-SCANNED (single line, length-bounded, no emails, no @handles, no
# quoted speech; `claim` additionally must contain something measurable) — and a bare name in
# any of them still passes. Three fields rather than nine is the win; claiming it is fewer
# than three would hand a reviewer a false map of where to look.
# That is a protocol violation this gate does not catch, said in those words here and in
# AGENT_BRIDGE_PROTOCOL.md §6, so no reader believes a guarantee the mechanism cannot give.
#
# So the refusals below say "the PII ceiling FORBIDS x", not "enforces". The distinction is
# load-bearing: a message claiming an absolute guarantee teaches the reader to stop checking,
# and the residual surface is small, real, and where a reviewer should look. This mirrors
# docs/AGENT_BRIDGE_PROTOCOL.md §6, which draws the same split (PDP #2415).
ALLOWED_TOP="request_id type from opened_at symptom evidence hypothesis"
# Keep in lockstep with the "Evidence fields" list in
# skills-all/agent-bridge-request/SKILL.md — check-agent-bridge-doctrine.sh asserts they
# match, because a field the docs recommend and the gate refuses is a request the agent
# cannot file and cannot debug.
# `note`, `detail` and `what_they_see` were REMOVED on 2026-08-26. They were the
# general-purpose prose channel, and prose is the one thing this gate cannot police: a
# customer name and a pasted transcript match no credential pattern, no phone shape and no
# card checksum, so they validated cleanly and reached the durable mailbox — exactly what the
# PII ceiling forbids. Bounding the shape did not close it either ("Jane Doe: my plays are
# gone. Agent: checking now." is 49 characters on one line), so the FIELD is gone rather than
# guarded. The narrative belongs on the linked conversation, which is access-controlled;
# `conversation_links` carries the pointer. The structured identity fields stay, so a request
# still says exactly whose problem it is.
# TYPED, NOT PROSE. Four rounds of pattern-matching "is this a person's name" did not
# converge — each patch was narrower than the last, which is the signature of chasing a
# semantic property with syntax. Typing the field terminates it: a field that cannot hold a
# sentence cannot hold a name. `customer_impact` is an object with a fixed schema,
# `why_escalating` is an enum, and the three optional prose fields
# (new_information, source_of_truth_the_customer_cites, screenshot_described) are GONE —
# they were optional, so nothing needed them, and each was a free-text channel no scanner
# could police. `claim` remains prose and is the ACKNOWLEDGED residual; see below.
ALLOWED_EVIDENCE="user_emails profile_ids track_ids first_seen count conversation_links
claim observed_at customer_stated_numbers known_issue customer_impact
rate why_escalating"

# COMPARE KEYS IN jq, NOT IN THE SHELL. `for k in $(jq -r 'keys[]')` word-splits before it
# compares, so a single off-protocol key containing a space — `"claim observed_at"` — was
# seen as TWO allowed keys and passed, carrying whatever prose it liked to the durable
# mailbox. Pathname expansion was a second route (a key with `*` in it). The allowlist is the
# PII boundary, and a boundary that the shell can re-tokenise is not one.
#
# jq does the set difference itself, so keys are compared whole, whatever they contain. The
# output is newline-delimited and read with `read -r`, never re-split.
BAD_TOP="$(jq -r --arg allow "$ALLOWED_TOP" '
  ($allow | split(" ")) as $ok | keys - $ok | .[]' "$FILE")"
if [ -n "$BAD_TOP" ]; then
  first=""; while IFS= read -r k; do first="$k"; break; done <<EOF
$BAD_TOP
EOF
  refuse "unknown top-level field '$first'. The envelope is: $ALLOWED_TOP"
fi

BAD_EV="$(jq -r --arg allow "$(echo $ALLOWED_EVIDENCE)" '
  ($allow | split(" ")) as $ok | (.evidence | keys) - $ok | .[]' "$FILE")"
if [ -n "$BAD_EV" ]; then
  first=""; while IFS= read -r k; do first="$k"; break; done <<EOF
$BAD_EV
EOF
  refuse "evidence field '$first' is not part of this protocol. The evidence allowlist is the enforced half of the PII ceiling. Allowed: $(echo $ALLOWED_EVIDENCE)"
fi

# The allowlist is a check on NAMES, so it only binds at the depth it inspects. An
# allowed container was still free to carry an off-protocol payload one level down:
# `note: {"customer_phone": "2125550123"}` passed, because `note` is allowed and nothing
# looked inside it. Nesting is not part of this protocol at all — every evidence value is
# a scalar or a flat list of scalars — so the fix is to say that, rather than to extend
# the allowlist recursively and re-open the same hole at depth 3.
# `hypothesis` is a top-level container the allowlist accepts, and the shape/name checks
# below only ever looked inside `.evidence` — so `hypothesis: {"customer_name": "...",
# "home_city": "..."}` validated and rendered off-protocol personal data into the durable
# mailbox. A hypothesis is a sentence, so requiring a sentence closes it without needing a
# recursive policy over arbitrary containers.
if [ "$(j '.hypothesis | type')" != "null" ]; then
  [ "$(j '.hypothesis | type')" = "string" ] \
    || refuse "hypothesis must be a STRING (one sentence, clearly labelled as a theory), got a $(j '.hypothesis | type'). Structured data there bypasses the evidence allowlist and the PII ceiling."
  printf '%s' "$(j '.hypothesis')" | grep -q '[^[:space:]]' \
    || refuse "hypothesis is present but blank — remove the field or say the theory"
fi

BAD_SHAPE="$(jq -r '
  .evidence
  | to_entries
  | map(select(.key != "customer_impact"))
  | map(select(
      (.value | type) as $t
      | ($t == "object")
        or ($t == "array" and ((.value | map(type) | map(. == "object" or . == "array") | any)))
    ))
  | map(.key + " (" + (.value | type) + ")")
  | join(", ")' "$FILE")"
if [ -n "$BAD_SHAPE" ]; then
  refuse "evidence values must be scalars or flat lists of scalars; nested structures are not part of this protocol and their contents are unreviewed. Flatten: $BAD_SHAPE"
fi

# --- value SHAPES, not just presence --------------------------------------------
# Presence checks let a well-formed-looking request through with `first_seen:
# "not-a-time"` and `count: "many"` — the numeric comparison simply skipped, and the data
# lane received a "systemic incident" with no usable timestamp, no numeric count, and
# possibly no valid customer identifier. A required field whose value is unusable is not
# meaningfully present, so the format is part of the requirement.
check_ts() { # check_ts <jq-path> <name>
  local v; v="$(j "$1 // \"\"")"
  [ -z "$v" ] && return 0
  is_ts "$v" || refuse "$2 must be UTC ISO8601 (YYYY-MM-DDTHH:MM:SSZ), got '$v'. Take it from \`date -u +%Y-%m-%dT%H:%M:%SZ\`, never from memory."
}
check_num() { # check_num <jq-path> <name>
  local t; t="$(j "$1 | type")"
  [ "$t" = "null" ] && return 0
  [ "$t" = "number" ] || refuse "$2 must be a NUMBER, got a $t. A count the lane cannot compare is not a count."
}
check_emails() { # check_emails <jq-path> <name>
  local t; t="$(j "$1 | type")"
  [ "$t" = "null" ] && return 0
  [ "$t" = "array" ] || refuse "$2 must be an array of email addresses, got a $t"
  local bad
  bad="$(jq -r "[$1[] | select((type != \"string\") or (test(\"^[^@[:space:]]+@[^@[:space:]]+\\\\.[^@[:space:]]+$\") | not))] | join(\", \")" "$FILE")"
  [ -z "$bad" ] || refuse "$2 contains entries that are not email addresses: $bad. The distinct-USER key is the email; a placeholder there silently breaks the de-duplication the lane relies on."
}
check_id_list() { # check_id_list <jq-path> <name>
  local t; t="$(j "$1 | type")"
  [ "$t" = "null" ] && return 0
  [ "$t" = "array" ] || refuse "$2 must be an array, got a $t"
  local bad
  bad="$(jq -r "[$1[] | select((type != \"string\") or (length == 0))] | length" "$FILE")"
  [ "$bad" = "0" ] || refuse "$2 contains $bad empty or non-string entries — an id the lane cannot look up is worse than an absent one"
}

# --- generic free-text fields are BOUNDED ---------------------------------------
# `note` and `detail` are the two allowlisted catch-alls, and an unbounded string is where
# the PII ceiling quietly stops applying: a customer name and a pasted support transcript
# match no credential pattern, no phone shape and no card checksum, so `--validate` returned
# OK and the durable mailbox received exactly the content the skill says never to post.
# Scanners cannot recognise ordinary prose, so the constraint is SHAPE: one line, short
# enough to be a note rather than a record. A transcript does not fit in 300 characters on
# one line, and the refusal says where it belongs instead.
#
# BE CLEAR ABOUT WHAT THIS IS: a reduction, not a guarantee. A short single-line name still
# passes, and it always will — that case is a protocol violation this gate cannot catch, and
# it is named as such in the skill and in AGENT_BRIDGE_PROTOCOL.md §6 rather than papered
# over here. What the bound buys is that a RECORD cannot ride in: no transcripts, no dumps,
# no multi-line narrative.
# Only `claim` is still prose. It is required for data_verification and has to be a
# human-readable checkable assertion, so it cannot be typed away without making the request
# type useless. It is held to every constraint that CAN be mechanised — single line, 300
# chars, must contain something measurable, no emails, no @handles, no quoted speech — and
# the residual is stated rather than implied: a bare name here still passes, that is a
# protocol violation this gate does not catch, and AGENT_BRIDGE_PROTOCOL.md §6 says so in
# those words.
# ALL THREE residual prose fields, which is the list the docs have named for several
# revisions now. `hypothesis` and `symptom` are TOP-LEVEL, not under evidence, and both sat
# outside this loop while every document said they were scanned — so a symptom could carry an
# email, an @handle or a `Name:` opener straight into the durable mailbox. Naming a residual
# in prose and not wiring it into the loop is how a documented gap becomes an undocumented
# one. `symptom` keeps its own 400-char bound (set at the envelope); the identity checks are
# identical for all three.
for _f in claim hypothesis symptom; do
  case "$_f" in
    hypothesis|symptom) _v="$(jq -r --arg k "$_f" '.[$k] // "" | tostring' "$FILE")" ;;
    *)                  _v="$(jq -r --arg k "$_f" '.evidence[$k] // "" | tostring' "$FILE")" ;;
  esac
  [ -z "$_v" ] && continue
  # DIRECT IDENTITY DOES NOT BELONG IN A PROSE ANSWER. These fields each answer one question
  # and none of those questions requires naming a person: customer_impact is "2 paying
  # customers, both followed up twice", not who they are. An email or handle here is both a
  # ceiling violation and a routing bug — the lane de-duplicates on `user_emails`, so an
  # address buried in prose identifies nobody to the reader and nothing to the tooling.
  # Patternable, therefore enforced. A bare NAME is not patternable and remains the
  # documented residual (AGENT_BRIDGE_PROTOCOL.md §6) rather than a silent one.
  printf '%s' "$_v" | grep -qE '[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+' \
    && refuse "evidence.$_f contains an email address. Identity goes in the STRUCTURED fields — user_emails, profile_ids, track_ids — where the lane can de-duplicate on it; in prose it identifies nobody to the reader and nothing to the tooling."
  printf '%s' "$_v" | grep -qE '(^|[[:space:]])@[A-Za-z0-9._-]{2,}' \
    && refuse "evidence.$_f contains an @handle. Identity goes in the structured fields; a prose answer answers its own question."
  # A NAME-SHAPED OPENER IS A TRANSCRIPT, NOT AN ANSWER. "Jane Doe: my plays are gone" is the
  # case that kept surviving every scanner, because a name is not patternable IN GENERAL —
  # but the SHAPE that carries it here is: a capitalised personal name followed by a colon is
  # someone being quoted, and none of these fields is a place to quote anyone. Refusing the
  # shape does not require recognising the name.
  printf '%s' "$_v" | grep -qE '(^|[[:space:]])[A-Z][a-z]+([[:space:]]+[A-Z][a-z]+)*[[:space:]]*:' \
    && refuse "evidence.$_f looks like quoted speech ('Name: ...'). These fields answer a question; they are not a place to quote a person. Put the conversation in conversation_links and answer the question here."
  case "$_v" in *$'\n'*) refuse "$_f must be a SINGLE line. Multi-line content is a transcript or a record, and neither belongs on the mailbox — link the conversation instead (conversation_links)." ;; esac
  [ "$_f" = "symptom" ] || [ "${#_v}" -le 300 ] || refuse "evidence.$_f is ${#_v} chars; keep it to a note (<= 300). If it needs more, it is a transcript or a dump: link it (conversation_links) and summarise the point."
done

# --- the rest of the schema, typed. ----------------------------------------------
# I typed `customer_impact` and `why_escalating` and left four fields as free scalars, which
# re-created the generic prose channel this PR exists to remove: `conversation_links` would
# take a paragraph, `customer_stated_numbers` a sentence, `known_issue` anything at all.
# Each of these has an obvious shape; not enforcing it was an incomplete sweep, not a
# deliberate exemption. After fixing a class, grep for the class.

# conversation_links: an array of URLs. Deeplinks are the ONLY thing that may live here —
# they are the access-controlled surface the narrative is supposed to move to, so accepting
# prose here would defeat the redirect the whole ceiling depends on.
if [ "$(j '.evidence.conversation_links | type')" != "null" ]; then
  [ "$(j '.evidence.conversation_links | type')" = "array" ] \
    || refuse "evidence.conversation_links must be an ARRAY of URLs"
  bad="$(jq -r '[.evidence.conversation_links[] | select((type != "string") or (test("^https?://[^[:space:]]+$") | not))] | length' "$FILE")"
  [ "$bad" = "0" ] \
    || refuse "evidence.conversation_links contains $bad entries that are not URLs. This field carries LINKS — it is where the narrative goes, and prose here defeats that."
fi

# customer_stated_numbers: the figures the customer said, as values. Not a sentence about
# them: "12,480" and "0" are values; "she said it was 12,480 last week" is prose.
if [ "$(j '.evidence.customer_stated_numbers | type')" != "null" ]; then
  [ "$(j '.evidence.customer_stated_numbers | type')" = "array" ] \
    || refuse "evidence.customer_stated_numbers must be an ARRAY of values"
  bad="$(jq -r '[.evidence.customer_stated_numbers[] | select((type != "number") and ((type != "string") or (tostring | test("^[0-9][0-9,._ ]*[0-9%]?$") | not)))] | length' "$FILE")"
  [ "$bad" = "0" ] \
    || refuse "evidence.customer_stated_numbers contains $bad entries that are not numeric values. Give the FIGURES the customer stated (\"12,480\", 0) — the sentence around them belongs in symptom or on the linked conversation."
fi

# known_issue: an issue reference the lane can resolve, not a description of one.
if [ "$(j '.evidence.known_issue | type')" != "null" ]; then
  ki="$(j '.evidence.known_issue')"
  printf '%s' "$ki" | grep -qE '^([A-Za-z0-9._-]+/[A-Za-z0-9._-]+#[0-9]+|https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/issues/[0-9]+)$' \
    || refuse "evidence.known_issue must be an issue REFERENCE the lane can open — 'Muso-AI/platform-data-processing-v4#222' or its full GitHub URL. Got '$ki'. A description is not a reference; if there is no issue, this is a systemic_check."
fi

# rate: a trend, typed. "1/day -> 6/day" is a rate; "getting much worse" is an opinion, and
# an escalation is a claim about a TREND that the lane has to be able to read.
if [ "$(j '.evidence.rate | type')" != "null" ]; then
  rt="$(j '.evidence.rate')"
  printf '%s' "$rt" | grep -qE '^[0-9]+(\.[0-9]+)?/(hour|day|week) -> [0-9]+(\.[0-9]+)?/(hour|day|week)$' \
    || refuse "evidence.rate must be 'N/period -> M/period' with period in hour|day|week (for example '1/day -> 6/day'). Got '$rt'. An escalation is a claim about a trend, and a trend the lane cannot parse is not evidence of one."
fi

check_emails '.evidence.user_emails' 'evidence.user_emails'
check_id_list '.evidence.profile_ids' 'evidence.profile_ids'
check_id_list '.evidence.track_ids'   'evidence.track_ids'
check_ts  '.evidence.first_seen'  'evidence.first_seen'
check_ts  '.evidence.observed_at' 'evidence.observed_at'
check_num '.evidence.count'       'evidence.count'

# Value-shape backstop for the free-text fields the allowlist still permits.
secret_hit_i '(\+[0-9][0-9 ().-]{9,}[0-9]|\(?[0-9]{3}\)?[ .-][0-9]{3}[ .-][0-9]{4})' \
  && refuse "a phone-number-shaped value is present. The PII ceiling forbids it: emails and internal IDs only."
# Bare-digit phone numbers ("2125550123") carry no `+` and no separators, so the pattern
# above never matched them. Length cannot be the discriminator — a customer-stated stream
# count is the same width — so FORMATTING is: a tally is written with separators or in
# prose, a pasted phone number is a naked 10-11 digit run (NANP: 10 digits, or 11 leading 1).
secret_hit_i '(^|[^0-9,.])(1?[2-9][0-9]{2}[2-9][0-9]{6})([^0-9,.]|$)' \
  && refuse "a bare 10-11 digit run looks like a phone number. If it is a count, write it with separators (12,480) or in words. The PII ceiling forbids it: emails and internal IDs only."
# UNAMBIGUOUS TOKENS ONLY. The bound below is necessary and was never sufficient, and the
# second half of that lesson cost two rounds: `way`, `place`, `drive`, `court`, `circle` and
# `lane` are ordinary English words, so "6 customers have no way to access analytics" and
# "13 profiles in the data lane are frozen" are street addresses to any pattern that accepts
# them as suffixes. Narrowing the word run does not help -- those sentences are SHORT. There
# is no bound at which "a digit, then a few words, then the word `way`" stops being prose.
#
# So the vocabulary changed rather than the bound: only suffixes that are not ordinary
# sentence words in their own right (street, avenue, boulevard, parkway, terrace, highway,
# road) plus the abbreviated forms, which a house number in front of makes unambiguous.
#
# RESIDUAL, STATED, as with the bare name below: "742 Maple Way" now passes this scan. That
# is accepted deliberately. The PII ceiling is enforced by the evidence ALLOWLIST -- a
# `street_address` field is refused by name, which is the control that actually holds -- and
# this scan is defence in depth over the three prose residuals. A scanner that blocks real
# requests and real escalations is strictly worse than one that misses a rare address in
# prose: the first is a data-lane outage, the second is already covered a layer up. Prefer
# making a failure harmless over making it impossible.
secret_hit_i '[0-9]+[A-Za-z]? +([A-Za-z]+ +){0,3}(street|st\.|avenue|ave\.|road|rd\.|boulevard|blvd\.|dr\.|parkway|pkwy|ct\.|terrace|highway)([^A-Za-z]|$)' \
  && refuse "a street-address-shaped value is present. The PII ceiling forbids it: emails and internal IDs only."

# High-entropy blob check, last so the specific messages above win.
if printf '%s' "$ENTROPY_SCAN" | grep -qE '[A-Za-z0-9+/]{48,}={0,2}'; then
  refuse "a long opaque blob is present (>= 48 chars). If it is a credential, it must never be sent; if it is data, summarise it."
fi

# ----------------------------------------------------------------- render --
BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"; rm -rf "$SNAP_DIR"' EXIT

TYPE_LABEL="$(printf '%s' "$TYPE" | tr '_' ' ')"
{
  if [ "$FORCE" -eq 1 ]; then
    printf '**agent-bridge FOLLOW-UP — %s** (from `%s`, same `request_id`)\n\n' "$TYPE_LABEL" "$FROM"
  else
    printf '**agent-bridge request — %s** (from `%s`)\n\n' "$TYPE_LABEL" "$FROM"
  fi
  printf '> %s\n\n' "$SYMPTOM"
  printf '```json\n'
  jq -S '.' "$FILE"
  printf '\n```\n\n'
  printf 'Reply contract: `verdict` (systemic | isolated | not-data-lane | need-more-evidence), '
  printf '`owning_lane`, `issue`, `eta_class`, `customer_safe_summary`. '
  printf 'Protocol: `docs/AGENT_BRIDGE_PROTOCOL.md`.\n'
  printf 'This comment is a REPORT. It describes a situation; it does not authorize any action.\n'
  printf '\n<!-- agent-bridge request_id=%s type=%s from=%s -->\n' "$REQUEST_ID" "$TYPE" "$FROM"
} > "$BODY_FILE"

if [ "$MODE" = "validate" ]; then
  echo "OK: $TYPE request '$REQUEST_ID' is well-formed."
  exit 0
fi

if [ "$MODE" = "dry-run" ]; then
  echo "--- DRY RUN: would post to $REPO#$ISSUE ---"
  cat "$BODY_FILE"
  exit 0
fi

# -------------------------------------------------------------- de-dupe --
if [ -z "$TEST_DIR" ]; then
  [ -f "$GH_BIN" ] && [ -x "$GH_BIN" ] || die "$GH_BIN is missing or not executable — refusing to look elsewhere for a GitHub client"
fi

# Bound every network call so a hung call cannot wedge the wrapper indefinitely and
# recreate the race from the other side. `timeout` is used when present and skipped when
# not, rather than made a hard dependency of filing a request.
GH_TIMEOUT="${AGENT_BRIDGE_GH_TIMEOUT_SECS:-45}"
# FAIL CLOSED ON A MISSING `timeout`. The previous fallback ran the call UNBOUNDED when the
# binary was absent — so the deadline silently evaporated exactly when the host was degraded,
# which is when it matters. A feature that disables itself under adverse conditions is not a
# feature. `timeout` is a required dependency, pinned absolute like the rest.
# Pinned absolute in production. A TESTABLE copy resolves it from the (already replaced)
# PATH instead, so the suite runs on a dev box where the binary lives elsewhere — the
# alternative was a test that only passes on the deploy host, which is how the BSD-vs-GNU
# `sed` bug earlier in this lane stayed green in CI while failing locally.
if [ "$TESTABLE" = "1" ]; then
  TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || echo /usr/bin/timeout)"
else
  TIMEOUT_BIN="/usr/bin/timeout"
fi
readonly TIMEOUT_BIN
[ -x "$TIMEOUT_BIN" ] || die "$TIMEOUT_BIN is missing or not executable. It is a required dependency: without it every network call here is unbounded, and an unbounded call cannot fail in a way anyone can act on."
gh_run() { "$TIMEOUT_BIN" "$GH_TIMEOUT" "$GH_BIN" "$@"; }

# ── AT-LEAST-ONCE, BY DESIGN. There is no lock here, and that is the fix. ──────────
#
# This used to hold a filesystem mutex across the read-and-post window, because two callers
# with one request_id could both see "no duplicate" and both post. Every version of that lock
# was correct about the case in front of it and introduced the next one: reaping on age
# reaped a slow-but-alive holder; checking liveness read a malformed pid as death; the
# future-mtime guard stranded dead locks; the reaping itself raced; the reaper mutex could
# orphan; its orphan recovery mishandled clocks. Four rounds of the-fix-is-the-next-bug.
#
# The cost of a guard is that it becomes a thing needing guarding. The corollary is the fix:
# the best guard is a protocol that does not need one. Every request carries a `request_id`,
# and the consumer (the PDP data session) triages by that id — so a duplicate comment is a
# duplicate REPORT of one incident, not two incidents. Nothing downstream auto-acts on a
# mailbox post: the protocol states that posts are reports and never instructions, and there
# is no `issue_comment` automation on the mailbox repo (verified before this change). A
# transient double-post is therefore a cosmetic artefact that the consumer collapses.
#
# So the semantics are AT-LEAST-ONCE, stated rather than approximated:
#   - the duplicate check below is BEST-EFFORT. It catches the ordinary case — someone
#     re-filing an existing request minutes later — and points them at `--follow-up`.
#   - under a genuine race both callers may post, and that is ACCEPTED, not a bug to be
#     designed against.
#   - the read still FAILS CLOSED on an unreadable mailbox, because "I could not check"
#     is different from "there was nothing there" and only one of those is an answer.
#
# What this deletes: the lock, the reaper, the reaper mutex, the orphan recovery, the
# liveness probing, the clock-skew handling, and roughly a hundred and thirty lines with
# their entire future bug surface. An idempotent protocol beats a correct lock.


trap 'rm -f "$BODY_FILE"; rm -rf "$SNAP_DIR"' EXIT

# FAIL CLOSED. `|| true` here would turn a 403, a timeout, or a GitHub outage into an
# empty comment list, and the script would post as though no duplicate existed --
# silently fragmenting one incident across several comments precisely when the mailbox
# is degraded. An empty list is a legitimate answer; a failed READ is not an answer at
# all, and the two are distinguished by exit status, never by emptiness.
set +e
if [ -n "$TEST_DIR" ]; then
  [ -n "${AGENT_BRIDGE_TEST_READ_DELAY:-}" ] && sleep "$AGENT_BRIDGE_TEST_READ_DELAY"
  EXISTING="$(cat "$TEST_DIR/comments.txt" 2>&1)"
else
  EXISTING="$(gh_run issue view "$ISSUE" --repo "$REPO" --json comments --jq '.comments[].body' 2>&1)"
fi
read_rc=$?
set -e
if [ "$read_rc" -ne 0 ]; then
  echo "ERROR: could not read $REPO#$ISSUE to check for a duplicate (gh exit $read_rc)." >&2
  echo "$EXISTING" | head -3 >&2
  echo "Refusing to post: de-duplication is a core invariant and it could not be established." >&2
  exit 2
fi
# MATCH THE CANONICAL MARKER LINE, not a substring anywhere in the thread. An unanchored
# `request_id=<id>` search treats any occurrence as proof the request exists — including one
# quoted inside another comment's rendered JSON — so de-duplication could refuse a genuinely
# new request, and `--follow-up` could believe a thread exists that never did. Same defect
# the notifier's escalation check had, and fixed the same way: the marker the wrapper itself
# stamps, matched as a whole line.
# Do not use grep -q here. With pipefail enabled, grep exits as soon as it finds
# a marker and printf can receive SIGPIPE on a large mailbox, making the
# successful match look false. Drain the input and discard matched output.
if [ -n "$EXISTING" ] && printf '%s' "$EXISTING" | grep -E "^<!-- agent-bridge request_id=$REQUEST_ID type=[a-z_]+ from=[a-z]+ -->$" >/dev/null; then
  if [ "$FORCE" -eq 0 ]; then
    echo "DUPLICATE: request_id '$REQUEST_ID' is already on $REPO#$ISSUE." >&2
    echo "If you have NEW information — or the request has had no reply and you are chasing" >&2
    echo "it — re-run with --follow-up. That posts onto the SAME request_id, which is how a" >&2
    echo "chase stays on one thread instead of fragmenting into a second request." >&2
    exit 3
  fi
  echo "NOTE: posting a FOLLOW-UP on existing request_id '$REQUEST_ID'." >&2
elif [ "$FORCE" -eq 1 ]; then
  # A follow-up to nothing is a first report wearing the wrong label: the thread it claims
  # to continue does not exist, so it reads as a reply nobody can find the question for —
  # the same fragmentation this mode exists to prevent, arrived at from the other side.
  echo "NO SUCH THREAD: --follow-up was given, but request_id '$REQUEST_ID' is not on $REPO#$ISSUE." >&2
  echo "File it as a first request (drop --follow-up), or fix the request_id — a follow-up needs something to follow." >&2
  exit 3
fi

# ----------------------------------------------------------------- post --
if [ -n "$TEST_DIR" ]; then
  # No client is invoked. The rendered body and the arguments production WOULD have used are
  # recorded so tests can assert them, and the comment is appended to the fake thread so
  # de-duplication behaves as it does in production.
  mkdir -p "$TEST_DIR/posts"
  # NOT `cp`: at-least-once means two callers can archive the SAME request_id
  # concurrently, and GNU cp opens a destination it believes is new with
  # O_CREAT|O_EXCL -- the loser gets EEXIST, cp exits 1, and `set -e` turns
  # that into a THIRD outcome the at-least-once contract does not name (it
  # promises only 0 "posted" or 3 "duplicate"). Measured on node-8, GNU
  # coreutils 9.4: 67/400 with a fresh destination and 4 racers, 0/400 with
  # this redirect. A shell redirect is O_CREAT|O_TRUNC and never fails on an
  # existing file. `cp -f` does NOT fix it (58/400) -- it only retries after
  # an open failure on a destination it already knew existed.
  cat "$BODY_FILE" > "$TEST_DIR/posts/$REQUEST_ID.md"
  printf 'issue comment %s --repo %s --body-file <rendered>\n' "$ISSUE" "$REPO" >> "$TEST_DIR/calls.log"
  cat "$BODY_FILE" >> "$TEST_DIR/comments.txt"
  URL="https://github.com/$REPO/issues/$ISSUE#issuecomment-test"
elif ! URL="$(gh_run issue comment "$ISSUE" --repo "$REPO" --body-file "$BODY_FILE" 2>&1)"; then
  echo "FAILED to post to $REPO#$ISSUE: $URL" >&2
  exit 4
fi

echo "POSTED $TYPE '$REQUEST_ID' -> $URL"
