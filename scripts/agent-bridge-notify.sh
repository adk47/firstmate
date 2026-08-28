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

# agent-bridge-notify.sh — the ONLY path an agent uses to put an escalation on the
# real-time bridge lane.
#
# WHY THIS IS A SCRIPT AND NOT A CURL RECIPE
# The first version of this was a documented `curl` in the skill: read the Centrifugo API
# key into the agent's shell, then POST a JSON body the agent composes. Everything about
# that is wrong in the same way the raw `gh` call was wrong for requests.
#
#   - The key is a CLUSTER-WIDE publish credential. It can write to ANY channel, including
#     `ticker:*` — the live customer nowcast bus. A recipe that hands it to an LLM shell
#     and asks it to type the right channel is one edit, one hallucinated field, or one
#     piece of customer-derived text away from publishing to production.
#   - The `from` field is a claim, not an identity: whoever holds the key can forge any
#     sender. So the key is also an impersonation primitive.
#   - Nothing enforced escalation-only, mailbox-first, the payload schema, or the PII
#     ceiling. Those were four prose rules in a skill, and prose is not enforcement.
#
# So: the channel is HARD-CODED (not an argument), the key never appears in the caller's
# environment or in any output, the payload is CONSTRUCTED here rather than accepted, the
# request must already exist on the durable mailbox as an `escalation`, and the same
# secret/PII refusals that guard a request guard this too.
#
# Protocol (canonical): Muso-AI/platform-data-processing docs/AGENT_BRIDGE_PROTOCOL.md
# Runbook (transport):  Muso-AI/H-DevOps docs/runbooks/agent-bridge-centrifugo.md
#
# Usage:
#   agent-bridge-notify.sh --request-id <id> --summary "<one line>"            # publish
#   agent-bridge-notify.sh --request-id <id> --summary "<one line>" --dry-run  # render only
#
# Exit codes: 0 published · 1 refused (fix the input) · 2 usage/environment error
#             3 no matching escalation on the mailbox · 4 publish failed

# ---------------------------------------------------------------- PINNED --
# Everything in this block is a CONSTANT, and that is the security property.
#
# The previous version read each of these from the environment with a default.
# But the caller here IS the agent: anything it can set is caller-controlled, so
# `CURL_BIN=/tmp/capture.sh` turned the "the key never reaches the agent shell"
# guarantee into "the key is handed to a program the agent wrote". Identity had the
# same shape — AGENT_BRIDGE_FROM and AGENT_BRIDGE_REPO meant the sender and the
# mailbox this wrapper claims to pin were both suggestions.
#
# So: channel, mailbox, sender, namespace, service and the two secret-touching
# binaries are literals. Absolute paths, resolved once, so PATH cannot redirect them
# either.
# Build-time literal; the deployed copy is always 0 and the doctrine gate asserts it. The
# test suite runs a DERIVED COPY with this flipped. Previously any caller-set override
# enabled SANDBOX, so an ops invocation could get a fake `PUBLISHED` from a stub while
# agent:pdp received nothing.
# readonly: a later `TESTABLE=$((1))` would otherwise silently re-enable the test backend
# on a DEPLOYED copy — the gate only checked that this line existed, not that it stayed the
# effective value. `readonly` makes the second assignment a runtime error rather than a
# quiet override, so the guarantee lives in the shell rather than in a grep.
readonly TESTABLE=0

# READONLY, not merely literal. The gate used to prove one `CHANNEL="agent:pdp"` line
# existed — so adding `CHANNEL="${AGENT_BRIDGE_CHANNEL:-agent:pdp}"` immediately after it
# left every check green while the deployed notifier accepted an arbitrary channel and
# pointed the cluster-wide publish credential at it, `ticker:*` included. Same defect the
# TESTABLE literal had; same fix. CHANNEL, NS and SVC are never re-derived, so they are
# readonly at declaration and a second assignment is a runtime error rather than an override.
readonly CHANNEL="agent:pdp"
readonly NS="data-processing"
readonly SVC="centrifugo-prod"
REPO="Muso-AI/platform-data-processing"
ISSUE="2405"
FROM="operations"            # the only agent this skill is registered to

# TEST SEAM, and it is deliberately not a hole. The bats suite must be able to run
# this end to end without a cluster, so overrides exist — but setting ANY of them
# puts the script in SANDBOX mode, and sandbox mode NEVER reads the real key. It uses
# a sentinel. A caller who redirects the binaries therefore captures the string
# "SANDBOX-NOT-A-REAL-KEY" and nothing else, which is the property the Critical
# finding actually asked for: the live credential is only ever passed to the pinned
# absolute-path binary.
SANDBOX=0
if [ "$TESTABLE" != "1" ]; then
  for _v in GH_BIN KUBECTL_BIN CURL_BIN AGENT_BRIDGE_REPO AGENT_BRIDGE_ISSUE AGENT_BRIDGE_FROM \
            AGENT_BRIDGE_TIMEOUT_SECS; do
    eval "_set=\${$_v:-}"
    [ -z "$_set" ] || { echo "ERROR: $_v is not settable on a deployed copy of this script — a caller-selectable backend can print PUBLISHED without publishing." >&2; builtin exit 2; }
  done
else
  [ -n "${GH_BIN:-}${KUBECTL_BIN:-}${CURL_BIN:-}${AGENT_BRIDGE_REPO:-}${AGENT_BRIDGE_ISSUE:-}${AGENT_BRIDGE_FROM:-}" ] && SANDBOX=1
fi
if [ "$SANDBOX" -eq 1 ]; then
  GH_BIN="${GH_BIN:-gh}"
  KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
  CURL_BIN="${CURL_BIN:-curl}"
  REPO="${AGENT_BRIDGE_REPO:-$REPO}"
  ISSUE="${AGENT_BRIDGE_ISSUE:-$ISSUE}"
  FROM="${AGENT_BRIDGE_FROM:-$FROM}"
else
  # ABSOLUTE PATHS, NOT `command -v`. Resolving through PATH left the whole thing
  # caller-controlled by another route: the agent prepends a capture shim to PATH,
  # production mode resolves to the shim, SANDBOX never trips, and the shim gets the
  # real key. PATH is an input like any other. These are the paths on the box this
  # runs on (node-8), verified 2026-08-26, and each is checked to be an executable
  # regular file before use — a missing binary is an environment error, never a
  # silent fall back to whatever PATH offers.
  GH_BIN="/usr/local/bin/gh"
  KUBECTL_BIN="/usr/local/bin/kubectl"
  CURL_BIN="/usr/bin/curl"
fi
# FREEZE EVERY RESOLVED CONSTANT, not only the ones a finding named. A production-only
# reassignment after the test seam — CURL_BIN re-pointed at a capture shim when TESTABLE=0 —
# would leave the derived-copy tests green while the deployed notifier handed the
# cluster-wide publish key to the substituted binary. The test seam picks once; nothing
# re-picks. Paired with an assignment count in the doctrine gate, so it fails at CI too.
readonly REPO ISSUE FROM GH_BIN KUBECTL_BIN CURL_BIN


REQUEST_ID=""
SUMMARY=""
MODE="publish"

die()    { echo "ERROR: $*" >&2; builtin exit 2; }
refuse() { echo "REFUSED: $*" >&2; exit 1; }

# RUNTIME SELF-VERIFICATION. Nine rounds of review found nine different SPELLINGS of an
# override that a source-scanning gate missed: bare, `readonly`, `export`, `declare -x`,
# inside a duplicate seam header, inside the production arm of the real seam. A regex over
# shell syntax cannot enumerate the ways a shell assigns a variable — so this stops trying.
# The script asserts its own resolved VALUES here, after the freeze. Any override, however
# spelled, changed the value, and this catches it at the only place the spelling stops
# mattering: the value itself, at the moment before it is used.
if [ "$TESTABLE" != "1" ]; then
  builtin test "$CHANNEL" = "agent:pdp" || { printf 'ERROR: CHANNEL was altered: %s\n' "$CHANNEL" >&2; builtin exit 2; }
  builtin test "$REPO" = "Muso-AI/platform-data-processing" || { printf 'ERROR: REPO was altered: %s\n' "$REPO" >&2; builtin exit 2; }
  builtin test "$ISSUE" = "2405" || { printf 'ERROR: ISSUE was altered: %s\n' "$ISSUE" >&2; builtin exit 2; }
  builtin test "$FROM" = "operations" || { printf 'ERROR: FROM was altered: %s\n' "$FROM" >&2; builtin exit 2; }
  builtin test "$NS" = "data-processing" || { printf 'ERROR: NS was altered: %s\n' "$NS" >&2; builtin exit 2; }
  builtin test "$SVC" = "centrifugo-prod" || { printf 'ERROR: SVC was altered: %s\n' "$SVC" >&2; builtin exit 2; }
  builtin test "$GH_BIN" = "/usr/local/bin/gh" || { printf 'ERROR: GH_BIN was altered: %s\n' "$GH_BIN" >&2; builtin exit 2; }
  builtin test "$KUBECTL_BIN" = "/usr/local/bin/kubectl" || { printf 'ERROR: KUBECTL_BIN was altered: %s\n' "$KUBECTL_BIN" >&2; builtin exit 2; }
  builtin test "$CURL_BIN" = "/usr/bin/curl" || { printf 'ERROR: CURL_BIN was altered: %s\n' "$CURL_BIN" >&2; builtin exit 2; }
fi

# `shift 2` with no value present made `set -e` kill the script: exit 1, no output — a USAGE
# error wearing the validation-refusal code, with nothing telling the caller what to fix.
# needval() turns "you forgot the value" into the documented exit 2 and says which flag.
needval() { [ "$2" -ge 2 ] || die "$1 requires a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --request-id) needval --request-id "$#"; REQUEST_ID="$2"; shift 2 ;;
    --summary)    needval --summary "$#";    SUMMARY="$2";    shift 2 ;;
    --dry-run)    MODE="dry-run";      shift ;;
    -h|--help)    sed -n '/^# Usage:/,/^# Exit codes:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            die "unknown argument: $1" ;;
  esac
done

if [ "$SANDBOX" -eq 0 ]; then
  for _b in "$GH_BIN" "$KUBECTL_BIN" "$CURL_BIN"; do
    [ -f "$_b" ] && [ -x "$_b" ] || die "pinned binary $_b is missing or not executable; refusing to fall back to PATH"
  done
fi

# ------------------------------------------------------------------ DEADLINES --
# Every dependency here is a network call — the mailbox read, the two kubectl lookups, the
# publish — and none of them was bounded. A stalled GitHub, a wedged API server or a hung
# Centrifugo left an ESCALATION hanging indefinitely: the worst request type to lose to a
# silent stall, because the agent is waiting on it to tell someone something is spreading.
# An unbounded call does not fail, and a failure that never arrives cannot be classified,
# retried, or reported. `timeout` is used when present rather than made a hard dependency of
# raising an escalation; when it is missing the calls run unbounded and that is stated.
BRIDGE_TIMEOUT="${AGENT_BRIDGE_TIMEOUT_SECS:-45}"
printf '%s' "$BRIDGE_TIMEOUT" | grep -qE '^[1-9][0-9]*$' \
  || die "AGENT_BRIDGE_TIMEOUT_SECS must be a positive integer, got '$BRIDGE_TIMEOUT'"
# FAIL CLOSED, for the same reason: falling back to an unbounded call meant the deadline
# disappeared precisely when the host was degraded. Pinned absolute, and required.
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
[ -x "$TIMEOUT_BIN" ] || die "$TIMEOUT_BIN is missing or not executable. It is a required dependency: without it the mailbox read, both kubectl lookups and the publish are unbounded, and an escalation that hangs is the worst failure this lane has."
bounded() { "$TIMEOUT_BIN" "$BRIDGE_TIMEOUT" "$@"; }

[ -n "$REQUEST_ID" ] || die "--request-id <id> is required"
[ -n "$SUMMARY" ]    || die "--summary \"<one line>\" is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

printf '%s' "$REQUEST_ID" | grep -qE '^[a-z0-9][a-z0-9-]{4,80}$' \
  || refuse "request_id must be kebab-case, 5-81 chars, [a-z0-9-]: got '$REQUEST_ID'"

# One line. The real-time lane is a NUDGE; the evidence lives on the mailbox, and a long
# body here is either duplicated evidence or leaked detail.
[ "${#SUMMARY}" -le 300 ] || refuse "summary is ${#SUMMARY} chars; the real-time lane carries one line (<= 300). The evidence belongs on $REPO#$ISSUE."
case "$SUMMARY" in *$'\n'*) refuse "summary must be a single line" ;; esac

# --- the same ceiling the request wrapper enforces ------------------------------------
# A shorter list than the request scanner's on purpose: this payload is one sentence the
# agent wrote, not a structured evidence object, so the classes that can realistically
# appear are credentials and direct personal data.
scan() { printf '%s' "$SUMMARY" | grep -qiE "$1"; }
scan '(AKIA[0-9A-Z]{12,}|BEGIN [A-Z ]*PRIVATE KEY|(ghp|gho|ghu|ghs)_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,})' \
  && refuse "a credential-shaped string is present. Bridge messages carry NO credentials."
scan '(password|passwd|secret_key|api[_-]?key|access_token|refresh_token|bearer )' \
  && refuse "a credential-shaped term is present. Bridge messages carry NO credentials."
scan '[A-Za-z0-9+/]{48,}={0,2}' \
  && refuse "a long opaque blob is present. If it is a credential it must never be sent; if it is data, summarise it."
scan '[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+' \
  && refuse "an email address is present. The real-time lane carries POINTERS, not customer data — the emails belong in the mailbox request, which is access-controlled. History here retains 100 messages for 72h and every current and future subscriber sees them."

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
looks_like_a_card "$SUMMARY" \
  && refuse "a Luhn-valid 13-19 digit number is present — that is a payment card, whatever it is labelled. The real-time lane carries pointers, not customer data."
scan '(\+[0-9][0-9 ().-]{9,}[0-9]|\(?[0-9]{3}\)?[ .-][0-9]{3}[ .-][0-9]{4})' \
  && refuse "a phone-number-shaped value is present. The real-time lane carries pointers, not customer data."
# PARITY WITH THE REQUEST WRAPPER. These two classes were refused there and not here, so the
# lane with 72h of retention and arbitrary future subscribers was the LOOSER of the two —
# backwards. A scanner that is strict on the durable surface and lax on the broadcast one has
# the threat model upside down.
scan '(^|[[:space:]])@[A-Za-z0-9._-]{2,}' \
  && refuse "an @handle is present. The real-time lane carries pointers, not customer identity."
# UNAMBIGUOUS TOKENS ONLY -- and on this lane the stakes of getting it wrong run the other
# way, because a false positive here does not refuse a request, it SILENCES AN ESCALATION.
# `way`, `place`, `drive`, `court`, `circle` and `lane` are ordinary English words, and the
# canonical escalation summary is exactly the shape that trips them: "6 customers have no way
# to access analytics" and "13 profiles in the data lane are frozen" both matched. Bounding
# the word run does not save it -- those sentences are short. The gate would have suppressed
# the alarm it exists to protect, and only on the messages that mattered most.
#
# Vocabulary, not bound: unambiguous suffixes plus abbreviated forms only. RESIDUAL, STATED,
# as with the bare name below: "742 Maple Way" passes. Accepted -- this lane carries pointers
# by protocol and by length limit, and the durable surface enforces the real ceiling with a
# field allowlist. KEEP THIS PATTERN IDENTICAL to the request wrapper's;
# check-agent-bridge-doctrine.sh asserts they match, because fixing one copy and not the
# other is exactly how this defect reached this file.
scan '[0-9]+[A-Za-z]? +([A-Za-z]+ +){0,3}(street|st\.|avenue|ave\.|road|rd\.|boulevard|blvd\.|dr\.|parkway|pkwy|ct\.|terrace|highway)([^A-Za-z]|$)' \
  && refuse "a street-address-shaped value is present. The real-time lane carries pointers, not customer data."
# RESIDUAL, STATED: a BARE NAME in the summary still passes. Nothing distinguishes it from
# ordinary prose and no scanner will — it is a protocol violation this gate does not catch,
# exactly as for `symptom`/`claim`/`hypothesis` on the request side. Refer to customers by
# count and by the request_id; the mailbox holds the identifiers.
# A phone number written as bare digits ("2125550123") has no `+` and no separators, so the
# pattern above never saw it. Length alone cannot decide — customers legitimately quote
# stream counts of the same width — so the discriminator is FORMATTING: a real tally is
# written with separators or in prose ("12,480 streams"), while a pasted phone number is a
# naked 10-11 digit run. NANP numbers are 10 digits, or 11 starting with 1.
scan '(^|[^0-9,.])(1?[2-9][0-9]{2}[2-9][0-9]{6})([^0-9,.]|$)' \
  && refuse "a bare 10-11 digit run looks like a phone number. If it is a count, write it with separators (12,480) or in words; the real-time lane carries pointers, not customer data."

# --- MAILBOX FIRST, and it must be an escalation --------------------------------------
# "A real-time message read by nobody is a message that did not happen" cuts both ways: a
# nudge with nothing behind it is worse than no nudge, because it spends the escalation
# signal on something with no evidence attached. And this lane is escalation-only by
# design; letting a routine systemic_check ring the bell is how a bell stops working.
set +e
COMMENTS="$(bounded "$GH_BIN" issue view "$ISSUE" --repo "$REPO" --json comments --jq '.comments[].body' 2>&1)"
read_rc=$?
set -e
if [ "$read_rc" -ne 0 ]; then
  [ "$read_rc" = "124" ] && echo "ERROR: reading $REPO#$ISSUE timed out after ${BRIDGE_TIMEOUT}s." >&2
  echo "ERROR: could not read $REPO#$ISSUE to confirm the request exists (gh exit $read_rc)." >&2
  echo "$COMMENTS" | head -3 >&2
  echo "Refusing to publish: mailbox-first is an invariant and it could not be established." >&2
  exit 2
fi
# MATCH THE WRAPPER'S MARKER AS A WHOLE LINE, not as a substring anywhere in the thread.
# An unanchored search treated any occurrence of the marker text as authoritative, so a
# routine systemic_check could carry `<!-- agent-bridge request_id=x type=escalation ... -->`
# inside an allowlisted free-text field and mint itself an escalation that nobody filed.
# The request wrapper now also refuses to EMIT that text from user content (defence in
# depth: this anchor is the check, that refusal is the reason the check has nothing to
# chew on).
MARKER="^<!-- agent-bridge request_id=$REQUEST_ID type=escalation from=[a-z]* -->$"
if ! printf '%s' "$COMMENTS" | grep -qE "$MARKER"; then
  if printf '%s' "$COMMENTS" | grep -qE "^<!-- agent-bridge request_id=$REQUEST_ID type=[a-z_]* from=[a-z]* -->$"; then
    echo "REFUSED: '$REQUEST_ID' is on $REPO#$ISSUE but is not an \`escalation\`." >&2
    echo "The real-time lane is escalation-only. If it has genuinely escalated, file the escalation first." >&2
  else
    echo "REFUSED: no request '$REQUEST_ID' on $REPO#$ISSUE." >&2
    echo "File it with agent-bridge-request.sh FIRST — the mailbox is the system of record," >&2
    echo "and a nudge with no evidence behind it cannot be acted on." >&2
  fi
  exit 3
fi

# --- payload is CONSTRUCTED here, never accepted --------------------------------------
PAYLOAD="$(jq -nc \
  --arg ch "$CHANNEL" --arg from "$FROM" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg summary "$SUMMARY" --arg ref "$REPO#$ISSUE" --arg rid "$REQUEST_ID" \
  '{channel:$ch, data:{from:$from, kind:"escalation", ts:$ts, request_id:$rid, summary:$summary, refs:[$ref]}}')"

if [ "$MODE" = "dry-run" ]; then
  echo "--- DRY RUN: would publish to $CHANNEL ---"
  printf '%s\n' "$PAYLOAD" | jq -S '.'
  exit 0
fi

command -v "$KUBECTL_BIN" >/dev/null 2>&1 || die "$KUBECTL_BIN not found — cannot reach the publish API"
command -v "$CURL_BIN"    >/dev/null 2>&1 || die "$CURL_BIN not found"

# The API is cluster-internal and there is deliberately no public route to it. node-8 is a
# k3s AGENT with no cluster DNS, so the service NAME does not resolve here even though the
# H-DevOps runbook uses it — the ClusterIP does. Resolved at call time rather than pinned,
# because a ClusterIP survives a redeploy but not a service recreation.
# `|| true` turned a TIMEOUT into empty output, so a wedged API server produced a generic
# exit 2 ("could not resolve") instead of the documented exit 4 that tells the agent the
# escalation IS on the mailbox and only the nudge failed. Losing the distinction loses the
# only sentence the agent needs to say next.
set +e
CF_IP="$(bounded "$KUBECTL_BIN" -n "$NS" get svc "$SVC" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
ip_rc=$?
set -e
if [ "$ip_rc" = "124" ]; then
  echo "FAILED to publish to $CHANNEL — resolving $SVC TIMED OUT after ${BRIDGE_TIMEOUT}s. The escalation is on the mailbox; the real-time nudge did not go out. Say so rather than assuming it did." >&2
  exit 4
fi
[ -n "$CF_IP" ] || die "could not resolve $SVC ClusterIP in namespace $NS"

# The key is read into a local, used once, and never printed. It is not exported, so it
# does not leak into any child process the agent starts afterwards.
# In sandbox mode the real secret is NEVER read. This is the line the Critical
# finding turns on: a redirected CURL_BIN can only ever receive the sentinel.
# NO EXTERNAL DECODER. This used to pipe through `base64 -d`, which PATH resolves — so a
# `PATH=/tmp/shim:$PATH` gave an agent-written `base64` the encoded live credential on stdin,
# without tripping SANDBOX (changing PATH sets no override variable). The decode now happens
# INSIDE kubectl via a go-template, so no second process ever observes the secret in any form.
# The fix is removing the process, not pinning one more path: every additional program in the
# pipeline is another thing to pin, and the list is only as good as the last audit of it.
#
# The read runs in BOTH modes so the timeout branch below is on the same code path the suite
# exercises — an untested error branch is how the sibling kubectl call shipped unclassified.
# In sandbox the binary is a stub (production pins an absolute path), so the real secret is
# unreachable here by construction; the sentinel then replaces whatever the stub returned, so
# a redirected CURL_BIN still receives only "SANDBOX-NOT-A-REAL-KEY".
set +e
CF_KEY="$(bounded "$KUBECTL_BIN" -n "$NS" get secret centrifugo-api-key \
  -o go-template='{{ index .data "api_key" | base64decode }}' 2>/dev/null)"
key_rc=$?
set -e
if [ "$key_rc" = "124" ]; then
  echo "FAILED to publish to $CHANNEL — reading the publish key TIMED OUT after ${BRIDGE_TIMEOUT}s. The escalation is on the mailbox; the real-time nudge did not go out." >&2
  exit 4
fi
if [ "$SANDBOX" -eq 1 ]; then
  CF_KEY="SANDBOX-NOT-A-REAL-KEY"
fi
[ -n "$CF_KEY" ] || die "could not read the centrifugo publish key (secret centrifugo-api-key in $NS)"

# THE KEY DOES NOT GO IN ARGV. `-H "X-API-Key: $CF_KEY"` put it in the process table,
# where any concurrent process of the same user can read it out of /proc — a shorter
# window than a leaked file, but the same disclosure. `-K -` makes curl read its config
# (here, just the header) from STDIN, so the key exists only in this process's memory and
# the pipe: never in argv, never on disk. The BODY still comes from a file via `-d @`,
# which is what leaves stdin free for the config.
PAYLOAD_FILE="$(mktemp)"
trap 'rm -f "$PAYLOAD_FILE"' EXIT
printf '%s' "$PAYLOAD" > "$PAYLOAD_FILE"

set +e
RESP="$(printf 'header = "X-API-Key: %s"\n' "$CF_KEY" | bounded "$CURL_BIN" -sS -K - \
  --connect-timeout 10 --max-time "$BRIDGE_TIMEOUT" \
  -X POST "http://$CF_IP:8000/api/publish" \
  -H 'Content-Type: application/json' \
  -d "@$PAYLOAD_FILE" 2>&1)"
curl_rc=$?
set -e
CF_KEY=""

if [ "$curl_rc" -ne 0 ]; then
  if [ "$curl_rc" = "124" ] || [ "$curl_rc" = "28" ]; then
    echo "FAILED to publish to $CHANNEL — TIMED OUT after ${BRIDGE_TIMEOUT}s. The escalation is on the mailbox; the real-time nudge did not go out. Say so rather than assuming it did." >&2
  else
    echo "FAILED to publish to $CHANNEL (curl exit $curl_rc)" >&2
  fi
  exit 4
fi
# A 2xx is not proof on this API — it answers errors in the body. Assert the SUCCESS shape
# rather than the absence of one failure shape.
if ! printf '%s' "$RESP" | jq -e 'has("result")' >/dev/null 2>&1; then
  echo "FAILED to publish to $CHANNEL — unexpected response: $RESP" >&2
  exit 4
fi

echo "PUBLISHED escalation '$REQUEST_ID' -> $CHANNEL (mailbox: $REPO#$ISSUE)"
