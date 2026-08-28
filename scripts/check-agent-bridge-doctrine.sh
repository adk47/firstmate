#!/usr/bin/env bash
set -euo pipefail

# Mechanical backstop for the agent-bridge doctrine: CS and ops agents REQUEST a data
# investigation, they never attempt the fix themselves.
#
# Why it exists (2026-08-26): the ops/CS agents were attempting data-layer fixes without
# lane knowledge. Two triages the same day showed what that costs. A "0 plays / flat graph"
# cluster looked like a capture gap and was actually a frozen serving generation
# (platform-data-processing-v4#222) -- a capture-side fix would have found nothing and lost
# the day. A "credits missing" cluster looked like a bad flag and was actually an AUTHORIZED
# deletion 13-19 days older than the flag (industry-data-processing#1539) -- "restoring" the
# credits would have silently reversed a deliberate human action and the customer's own
# choices.
#
# The runtime gate is scripts/agent-bridge-request.sh (validates, refuses secrets and
# pre-baked diagnoses, de-dupes, posts). THIS guard protects the surrounding doctrine: the
# ops SOUL rule that sends the agent to the skill instead of the data, Caroline's
# symptom-not-diagnosis rule, the skill's registration on the operations agent, and the
# skill's own load-bearing anchors. Prose is not enforcement, so a silent removal of any of
# them fails CI.

ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

OPS_SOUL="${AB_OPS_SOUL_FILE:-$ROOT/workspaces/operations/SOUL.md}"
SUPPORT_SOUL="${AB_SUPPORT_SOUL_FILE:-$ROOT/workspaces/support/SOUL.md}"
SKILL="${AB_SKILL_FILE:-$ROOT/skills-all/agent-bridge-request/SKILL.md}"
WRAPPER="${AB_WRAPPER_FILE:-$ROOT/scripts/agent-bridge-request.sh}"
NOTIFY="${AB_NOTIFY_FILE:-$ROOT/scripts/agent-bridge-notify.sh}"
MAIN_CFG="${AB_MAIN_CONFIG_FILE:-$ROOT/openclaw-main.json}"

for f in "$OPS_SOUL" "$SUPPORT_SOUL" "$SKILL" "$WRAPPER" "$NOTIFY" "$MAIN_CFG"; do
  [ -f "$f" ] || {
    echo "Missing $f (run from repo root, or set the AB_*_FILE overrides)." >&2
    exit 2
  }
done

fail=0
_tmp_files=""
cleanup_tmp() { for _t in $_tmp_files; do rm -f "$_t"; done; }
trap cleanup_tmp EXIT

# require <file> <label> <fixed-substring> <why>
require() {
  if ! grep -qF -- "$3" "$1"; then
    echo "FAIL: $2 lost the anchor: \"$3\"" >&2
    echo "      why it is load-bearing: $4" >&2
    fail=1
  fi
}

# --- operations SOUL: the request-don't-fix rule and its route to the skill ---------
require "$OPS_SOUL" "operations/SOUL.md" \
  "you REQUEST, you never fix" \
  "the heading is the rule; without it the section is advice, not a boundary"
require "$OPS_SOUL" "operations/SOUL.md" \
  "agent-bridge-request" \
  "names the skill; without it the agent has a prohibition and no path, which is how dead ends become improvised fixes"
require "$OPS_SOUL" "operations/SOUL.md" \
  "Symptom, not diagnosis" \
  "a pre-baked cause routes the investigation to the wrong lane and burns the first hour"
require "$OPS_SOUL" "operations/SOUL.md" \
  "audit trail is the FIRST query" \
  "the industry-data-processing#1539 lesson: an authorized deletion and a pipeline defect are indistinguishable from the customer's chair"
require "$OPS_SOUL" "operations/SOUL.md" \
  "Your own gated actions are unchanged" \
  "without the carve-out the rule over-reads and the agent stops doing its sanctioned gated work"

# --- Caroline: symptom-only, and no assertion that data was lost -------------------
require "$SUPPORT_SOUL" "support/SOUL.md" \
  "you never diagnose" \
  "Caroline has no view of how data is produced; a guessed cause reaches the customer"
require "$SUPPORT_SOUL" "support/SOUL.md" \
  "never tell a customer their data was lost, deleted in error, or corrupted" \
  "a deliberate, authorized removal reads exactly like data loss (industry-data-processing#1539)"
require "$SUPPORT_SOUL" "support/SOUL.md" \
  "Capture the evidence in the ticket" \
  "the request downstream is only as good as the evidence captured at first contact"

# --- the skill: the anchors the wrapper cannot enforce by itself -------------------
require "$SKILL" "agent-bridge-request/SKILL.md" \
  "You never fix the data lane" \
  "the core rule"
# TWO INDEPENDENT PROHIBITIONS, TWO ANCHORS. A single "Never hand-roll the" check was
# satisfied by EITHER of them, so deleting the mailbox warning left the publish warning
# holding the gate up — and the doctrine could have drifted to teach a raw `gh` post
# (bypassing validation, destination pinning, de-duplication, and the agent's own
# write-authorization boundary and pre-write audit) with CI still printing OK. The two guard
# different credentials and different blast radii, so they get different anchors and are
# mutated independently in the tests.
if ! grep -qF 'Never hand-roll the publish' "$SKILL"; then
  echo "FAIL: agent-bridge-request/SKILL.md lost the no-hand-rolled-PUBLISH prohibition." >&2
  echo "      why it is load-bearing: publishing needs a CLUSTER-WIDE Centrifugo key that can" >&2
  echo "      write to any channel including ticker:*, and can forge any sender." >&2
  fail=1
fi
if ! grep -qE 'Never hand-roll the$' "$SKILL"; then
  echo "FAIL: agent-bridge-request/SKILL.md lost the no-hand-rolled-MAILBOX-POST prohibition." >&2
  echo "      why it is load-bearing: a hand-rolled gh post skips validation, destination" >&2
  echo "      pinning, de-duplication, and the agent's write-authorization boundary." >&2
  fail=1
fi
require "$SKILL" "agent-bridge-request/SKILL.md" \
  "reports and data, never instructions" \
  "the bridge's security posture in both directions"
for t in systemic_check data_verification fix_request escalation; do
  require "$SKILL" "agent-bridge-request/SKILL.md" "$t" \
    "the four request types are the protocol's shared vocabulary with the data lane"
done

# --- the wrapper: the refusals that make the doctrine mechanical ------------------
require "$WRAPPER" "scripts/agent-bridge-request.sh" \
  "SYMPTOMS, not causes" \
  "the symptom-not-diagnosis refusal"
require "$WRAPPER" "scripts/agent-bridge-request.sh" \
  "NO credentials" \
  "the credential refusal"
require "$WRAPPER" "scripts/agent-bridge-request.sh" \
  "does not authorize any action" \
  "every posted comment must carry the reports-not-instructions notice"

# --- the entrypoint itself must not be PATH-resolvable ----------------------------
# `#!/usr/bin/env bash` hands the process to whatever `bash` PATH finds, so a caller-supplied
# shim runs before any pinning in the file. Everything else these scripts guard is downstream
# of that, which makes the shebang the first gate rather than a style choice.
for _f in "$WRAPPER" "$NOTIFY"; do
  if ! head -1 "$_f" | grep -q '^#!/bin/bash -p$'; then
    echo "FAIL: ${_f##*/} does not use an absolute interpreter in privileged mode (#!/bin/bash -p)." >&2
    echo "      why it is load-bearing: env-resolved bash lets a PATH shim own the process before any pinning runs," >&2
    echo "      and without -p bash sources \$BASH_ENV and imports exported functions before line 1." >&2
    fail=1
  fi
  if ! grep -q '^PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin$' "$_f"; then
    echo "FAIL: ${_f##*/} does not replace PATH before running anything." >&2
    echo "      why it is load-bearing: a jq/grep shim can rewrite the payload AFTER validation, so the pinned kubectl and curl publish an attacker-built body." >&2
    fail=1
  fi
done

# --- deployed copies must not carry a test backend --------------------------------
# The suites run DERIVED copies with TESTABLE flipped to 1. If a flipped copy were ever
# committed, a caller could select a fake backend that prints the production success
# contract (POSTED / PUBLISHED) while nothing reaches the mailbox or the channel — and the
# agent would close the loop on a request that does not exist.
for _f in "$WRAPPER" "$NOTIFY"; do
  # PROVE THE EFFECTIVE VALUE, NOT THE PRESENCE OF A LINE. The old check asserted that one
  # exact `TESTABLE=0` existed and no exact `TESTABLE=1` did — so appending `TESTABLE=$((1))`
  # after it put a DEPLOYED wrapper into caller-selectable test mode while CI stayed green,
  # and an agent would get POSTED/PUBLISHED without anything reaching the mailbox or channel.
  # Two changes: the wrappers declare it `readonly` so a second assignment is a runtime error,
  # and this gate rejects EVERY additional assignment form rather than one spelling of it.
  if ! grep -q '^readonly TESTABLE=0$' "$_f"; then
    echo "FAIL: ${_f##*/} does not declare 'readonly TESTABLE=0'." >&2
    echo "      why it is load-bearing: the deployed copy must refuse every test/sandbox override," >&2
    echo "      and a non-readonly literal can be re-assigned further down the file." >&2
    fail=1
  fi
  _assigns="$(grep -cE '^[[:space:]]*(readonly[[:space:]]+)?TESTABLE=' "$_f")"
  if [ "$_assigns" != "1" ]; then
    echo "FAIL: ${_f##*/} has $_assigns assignments to TESTABLE; exactly one is allowed." >&2
    echo "      why it is load-bearing: any later assignment re-enables the test backend on a" >&2
    echo "      deployed copy, and the agent then sees success without the mailbox being reached." >&2
    fail=1
  fi
done

# --- the real-time lane: the channel must not be selectable ----------------------
# The publish credential is cluster-wide: it can write to ANY channel, including
# ticker:* (the live customer nowcast bus), and can forge any `from`. The protection is
# that agent-bridge-notify.sh hard-codes the channel as a constant rather than accepting
# it, so a wrong channel is unreachable instead of merely rejected. Turning that constant
# back into an argument is a one-line change with a production blast radius, so it is
# anchored here.
# EXACTLY ONE EFFECTIVE ASSIGNMENT, and readonly. Proving a literal EXISTS is not proving it
# HOLDS: `CHANNEL="${AGENT_BRIDGE_CHANNEL:-agent:pdp}"` added after the literal left every
# check green while the deployed notifier accepted an arbitrary channel and pointed the
# cluster-wide publish credential at it, ticker:* included. Same lesson as the TESTABLE guard.
# EVERY production constant, in BOTH wrappers — and the invariant is stated the way the
# failure actually happens: a reassignment inserted AFTER the freeze, which only takes effect
# on deployed copies because the derived-copy Bats run never reaches that branch. Counting
# assignments file-wide cannot express that (the declaration, the test-seam pick and the
# freeze are all legitimate); "nothing assigns these names after the freeze line" can.
# ONE EFFECTIVE ASSIGNMENT ON THE PRODUCTION PATH. Two earlier attempts at this were both
# proxies rather than the property: counting assignments file-wide fails on correct code
# (declaration + test-seam pick + freeze are three legitimate ones), and scanning only AFTER
# the freeze misses the sharper attack — a production-only override inserted BETWEEN the seam
# and the freeze, e.g. `[ "$TESTABLE" = "0" ] && REPO="Muso-AI/somewhere-else"`. The derived
# test copies never execute that, so no test can see it; it is frozen at runtime as the
# deployed value.
#
# The property, stated directly: on the path a DEPLOYED copy takes, each protected constant is
# assigned exactly once. So the check walks the file, skips the seam block (the branch guarded
# on TESTABLE/SANDBOX, which deployed copies do not enter), counts what is left, and separately
# rejects any assignment line that itself tests TESTABLE or SANDBOX — because that is the
# production-only override written inline rather than in a block.
# <expect> is how many assignments SHOULD appear outside the seam block: 1 for constants
# declared on the production path (REPO, CHANNEL...), 0 for ones resolved only inside the
# seam's if/else (the binaries — their production values live in the else branch, which this
# walk skips wholesale). Getting that distinction wrong is why the binaries were omitted
# rather than mis-counted: one number does not fit both shapes.
check_single_production_assignment() { # <file> <label> <freeze-regex> <expect> <names...>
  local f label freeze expect
  f="$(live_code "$1")"; label="$2"; freeze="$3"; expect="$4"; shift 4
  _tmp_files="$_tmp_files $f"
  local ln c n
  ln="$(grep -nE "$freeze" "$f" 2>/dev/null | head -1 | cut -d: -f1 || true)"
  if [ -z "$ln" ]; then
    echo "FAIL: $label does not freeze its resolved constants ($freeze)." >&2
    echo "      why it is load-bearing: without the freeze, any later assignment silently" >&2
    echo "      re-points the mailbox or the client on DEPLOYED copies." >&2
    fail=1
    return
  fi
  for c in "$@"; do
    # SEAM BOUNDS ARE EXACT, NOT "any branch that mentions TESTABLE". Skipping every
    # TESTABLE/SANDBOX conditional meant a DEPLOYED-ONLY branch —
    # `if [ "$TESTABLE" = "0" ]; then CURL_BIN="/tmp/capture"; fi` — was skipped as though it
    # were the test seam, which is the exact inversion of what the check is for: the branch
    # that only production executes is the one that most needs counting. The two legitimate
    # seam headers are enumerated; every other conditional is production and is walked.
    # ARM-AWARE. Skipping the whole seam block discarded the arm DEPLOYED COPIES RUN — so
    # `CURL_BIN="/tmp/capture"` inserted just before the seam's `else` was thrown away by
    # `seam { next }` while production executed it and then froze it readonly. Only the TEST
    # arm may be skipped, and which arm that is depends on the condition's polarity:
    #   if [ "$TESTABLE" != "1" ]  -> `then` is PRODUCTION, `else` is test
    #   if [ "$SANDBOX"  -eq 1  ]  -> `then` is test,       `else` is PRODUCTION
    n="$(awk -v want="$c" '
      # First occurrence of each seam header opens a tracked block; later duplicates are
      # ordinary production code and fall through to the counters below.
      /^[[:space:]]*if \[ "\$TESTABLE" != "1" \]; then$/ {
        if (!t_seen) { t_seen = 1; inblk = 1; skip = 0; next }
      }
      /^[[:space:]]*if \[ "\$SANDBOX" -eq 1 \]; then$/ {
        if (!s_seen) { s_seen = 1; inblk = 1; skip = 1; next }
      }
      inblk && /^[[:space:]]*else[[:space:]]*$/ { skip = !skip; next }
      inblk && /^[[:space:]]*fi[[:space:]]*$/   { inblk = 0; skip = 0; next }
      inblk && skip { next }
      # Assignment BUILTINS count as assignments. `export CURL_BIN=/tmp/capture` is an
      # assignment in every sense that matters here, and a pattern that only knew bare and
      # `readonly` forms let it through — the gate matching a spelling rather than the act.
      # COUNT OCCURRENCES, NOT LINES. `CURL_BIN="/usr/bin/curl"; CURL_BIN="/tmp/capture"` is
      # two assignments on one physical line; a per-line counter saw one and the second won.
      {
        line = $0
        pat = "(^[[:space:]]*|[;&|][[:space:]]*)((export|declare|typeset|local|readonly)[[:space:]]+)?" want "="
        while (match(line, pat)) { count++; line = substr(line, RSTART + RLENGTH) }
      }
      $0 ~ ("printf[[:space:]]+-v[[:space:]]+" want "\\>") { count++ }
      $0 ~ ("^[[:space:]]*read[[:space:]].*\\<" want "\\>") { count++ }
      $0 ~ ("(TESTABLE|SANDBOX).*" want "=") { count++ }
      END { print count + 0 }
    ' "$f")"
    if [ "$n" != "$expect" ]; then
      echo "FAIL: $label assigns $c $n time(s) on the PRODUCTION path outside the test seam; expected $expect." >&2
      echo "      why it is load-bearing: a second production-path assignment (including one" >&2
      echo "      guarded on TESTABLE=0) is an override no test copy ever executes, so this gate" >&2
      echo "      is the only thing that can see it." >&2
      fail=1
    fi
    local later
    later="$(tail -n "+$((ln + 1))" "$f" | grep -cE "^[[:space:]]*$c=" || true)"
    if [ "$later" != "0" ]; then
      echo "FAIL: $label assigns $c $later time(s) AFTER the freeze at line $ln." >&2
      fail=1
    fi
  done
}

# THE PRIMARY DEFENCE IS NOW RUNTIME, NOT TEXTUAL. Each wrapper asserts its own resolved
# values after the freeze, so an override changes a value and dies regardless of how it was
# spelled. This gate's job shrinks to making sure those assertions still exist — a stable
# check, unlike enumerating shell assignment forms, which took nine rounds and was still
# incomplete. The textual checks below are kept as a second net that fails EARLIER (at CI
# rather than at first run), not as the thing being relied on.
# The gate checks the assertion exists AND what it compares against. Checking only that a
# line mentioning the variable is present would let an attacker edit BOTH the assignment and
# the assertion — `CURL_BIN=/tmp/capture` plus `[ "$CURL_BIN" = "/tmp/capture" ]` — and the
# runtime check would certify the substitution. The expected VALUE is what has to be pinned
# here, so the two halves cannot be moved together.
# LIVE CODE ONLY. Every check below runs against a comment-stripped view, because a
# COMMENTED-OUT assertion satisfied `assert_pins` — so an attacker could disable the runtime
# pin and substitute the binary, and the gate counted the disabled assertion as present.
# That is the fourth time in this file a check has been satisfied by text that is not code
# (the em-dash grep, the escalation-marker literal, the builtin-rejection scan, and now
# this), which is why it is now handled ONCE, centrally, rather than per check.
#
# Note what this does NOT do: add `eval` to a list of assignment spellings. The runtime
# value-assertion already catches `eval 'CURL_BIN=...'` — the value changed — and the only
# reason the combined attack worked is that the assertion could be commented out. Fixing
# that closes the whole combination without resuming the enumeration treadmill.
live_code() { # live_code <file> -> path to a comment-stripped copy
  local f="$1" out
  out="$(mktemp)"
  sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$f" > "$out"
  printf '%s' "$out"
}

assert_pins() { # <file> <label> <VAR=expected> ...
  # MATCH THE WHOLE ASSERTION, not two substrings that happen to share a line. The previous
  # version grepped independently for "a line mentioning $VAR" and "= \"expected\" somewhere
  # on it", so a DECOY satisfied both while the real check was inverted:
  #     [ "$CURL_BIN" = "/tmp/capture" ] || [ "sentinel" = "/usr/bin/curl" ]
  # Both substrings present, assertion bypassed, gate green. Independent substring matching
  # is not structural matching — the same mistake as every other proxy in this file, and the
  # last place it was still hiding.
  #
  # The canonical form is fixed and whitespace-normalised, so there is exactly one string
  # that satisfies this and no room for a second clause.
  local f label
  f="$(live_code "$1")"; label="$2"; shift 2
  _tmp_files="$_tmp_files $f"
  local norm pair v e want
  norm="$(mktemp)"; _tmp_files="$_tmp_files $norm"
  sed -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //' -e 's/ $//' "$f" > "$norm"
  for pair in "$@"; do
    v="${pair%%=*}"; e="${pair#*=}"
    # THE EXIT IS PART OF THE ASSERTION. Delegating to `die` meant the gate proved a
    # comparison existed but not that failing it STOPPED anything: `die() { :; }` turned every
    # pin into a no-op while this check still matched. The refusal is inlined so its
    # semantics are inside the string the gate pins.
    # `builtin test`, NOT `[`. `[` is a builtin that a function CAN shadow, and a selective
    # shadow -- one that returns success only for the substitution's own comparison and
    # delegates everything else to `builtin [` -- makes the pin pass while the rest of the
    # script behaves normally. `builtin` bypasses function lookup, so no definition of
    # `test` or `[` can intercept it, and a redefinition of `builtin` itself is rejected
    # below. THAT is why this enumeration terminates and the assignment-spelling one never
    # did: the set of names the assertion depends on is FINITE AND CLOSED
    # (builtin, test, [, printf, exit, command), while the set of ways to write an
    # assignment is open-ended.
    want="builtin test \"\$$v\" = \"$e\" || { printf 'ERROR: $v was altered: %s\\n' \"\$$v\" >&2; builtin exit 2; }"
    if ! grep -qxF "$want" "$norm"; then
      echo "FAIL: $label does not carry the exact runtime pin for $v." >&2
      echo "      expected (whitespace-normalised): $want" >&2
      echo "      why it is load-bearing: the runtime assertion is what makes an override" >&2
      echo "      detectable regardless of spelling. Matching parts of it independently lets a" >&2
      echo "      decoy clause satisfy the gate while the real comparison is inverted." >&2
      fail=1
    fi
  done
}

# AND THE PRODUCTION ASSIGNMENT ITSELF MUST BE THE EXPECTED LITERAL. Pinning only the
# assertion left the assignment free: substitute the value and the gate still matched the
# (unchanged) assertion text. The runtime check catches that at first run, but the gate
# should fail at CI — earlier is strictly better for a value that reaches a credential.
assert_assigned() { # <file> <label> <VAR=expected> ...
  local f label
  f="$(live_code "$1")"; label="$2"; shift 2
  _tmp_files="$_tmp_files $f"
  local pair v e
  for pair in "$@"; do
    v="${pair%%=*}"; e="${pair#*=}"
    # ANCHORED to end-of-statement, so `VAR="good"; VAR="bad"` cannot pass on its prefix.
    if ! grep -qE "^[[:space:]]*(readonly[[:space:]]+)?$v=\"$(printf '%s' "$e" | sed 's/[].[^$*\/]/\\&/g')\"[[:space:]]*$" "$f"; then
      echo "FAIL: $label does not assign $v = \"$e\" on the production path." >&2
      echo "      why it is load-bearing: pinning only the ASSERTION leaves the assignment free," >&2
      echo "      and a substituted value with an untouched assertion is the combined mutation." >&2
      fail=1
    fi
  done
}
assert_assigned "$NOTIFY" "scripts/agent-bridge-notify.sh" \
  'CHANNEL=agent:pdp' 'NS=data-processing' 'SVC=centrifugo-prod' \
  'GH_BIN=/usr/local/bin/gh' 'KUBECTL_BIN=/usr/local/bin/kubectl' 'CURL_BIN=/usr/bin/curl' \
  'REPO=Muso-AI/platform-data-processing' 'ISSUE=2405' 'FROM=operations'
assert_assigned "$WRAPPER" "scripts/agent-bridge-request.sh" \
  'REPO=Muso-AI/platform-data-processing' 'ISSUE=2405' 'GH_BIN=/usr/local/bin/gh' \
  'PINNED_FROM=operations'

assert_pins "$WRAPPER" "scripts/agent-bridge-request.sh" \
  'REPO=Muso-AI/platform-data-processing' 'ISSUE=2405' 'GH_BIN=/usr/local/bin/gh' \
  'PINNED_FROM=operations'
assert_pins "$NOTIFY" "scripts/agent-bridge-notify.sh" \
  'CHANNEL=agent:pdp' 'REPO=Muso-AI/platform-data-processing' 'ISSUE=2405' 'FROM=operations' \
  'NS=data-processing' 'SVC=centrifugo-prod' 'GH_BIN=/usr/local/bin/gh' \
  'KUBECTL_BIN=/usr/local/bin/kubectl' 'CURL_BIN=/usr/bin/curl'

# SHADOWING A SHELL BUILTIN IS NEVER LEGITIMATE HERE. `exit() { :; }` turned every inlined
# refusal into a no-op; the pins call `builtin exit` now, which a function cannot intercept,
# and a redefinition of these names is rejected outright as well — belt and braces on the
# thing that makes every other pin meaningful.
for _f in "$WRAPPER" "$NOTIFY"; do
  _lf2="$(live_code "$_f")"; _tmp_files="$_tmp_files $_lf2"
  # THE CLOSED SET. Every name the runtime pins depend on, and nothing else -- `[` and
  # `test` were the gap: a selective `[` shadow certified a mapfile substitution on
  # 2026-08-28 while every other conditional in the file behaved normally.
  _sh="$(grep -nE '^[[:space:]]*(exit|printf|kill|command|builtin|test|\[)[[:space:]]*\(\)' "$_lf2" || true)"
  if [ -n "$_sh" ]; then
    echo "FAIL: ${_f##*/} redefines a shell builtin the refusals depend on:" >&2
    printf '%s\n' "$_sh" | sed 's/^/        /' >&2
    fail=1
  fi
done

# ASSIGNMENT BUILTINS ARE REJECTED OUTRIGHT for protected names. Counting them is necessary
# but not sufficient: `export` on one of these has no legitimate use in either wrapper (they
# are never passed to a child process by name), so its presence is by itself evidence of an
# override rather than something to tally. Comments are excluded so the explanation of the
# rule does not trip it — the recurring shape in this file.
_PROT='REPO|ISSUE|FROM|CHANNEL|NS|SVC|GH_BIN|KUBECTL_BIN|CURL_BIN|TEST_DIR|TIMEOUT_BIN|PINNED_FROM|TESTABLE'
for _f in "$WRAPPER" "$NOTIFY"; do
  _lf="$(live_code "$_f")"; _tmp_files="$_tmp_files $_lf"
  _hit="$(grep -nE "^[[:space:]]*(export|declare|typeset|local)([[:space:]]+-[[:alnum:]-]+)*[[:space:]]+($_PROT)=|printf[[:space:]]+-v[[:space:]]+($_PROT)\b|^[[:space:]]*(read|mapfile|readarray)[[:space:]]+[^|]*\b($_PROT)\b|eval[^#]*($_PROT)=" "$_lf" || true)"
  if [ -n "$_hit" ]; then
    echo "FAIL: ${_f##*/} assigns a protected constant through a shell builtin:" >&2
    printf '%s\n' "$_hit" | sed 's/^/        /' >&2
    echo "      why it is load-bearing: export/declare/printf -v/read/mapfile/readarray are
      assignments too, and mapfile was the one this list was missing on 2026-08-28. None" >&2
    echo "      has a legitimate use on these names here, so one is evidence of an override that" >&2
    echo "      production executes and the derived test copies never reach." >&2
    fail=1
  fi
done

# NOTE: there is deliberately no "each seam header occurs exactly once" rule. The notifier
# legitimately has two `if [ "$SANDBOX" -eq 1 ]` blocks — the resolution seam and the sentinel
# key replacement — so counting headers flags correct code. The walk does not need that rule
# anyway: it skips only the FIRST occurrence of each header, so a duplicate block inserted
# later is walked like any other production code and its assignments are counted. That is the
# property; the header count was a proxy for it, and it was wrong in the usual way.

check_single_production_assignment "$WRAPPER" "scripts/agent-bridge-request.sh" \
  '^readonly REPO ISSUE GH_BIN TEST_DIR$' 1 \
  REPO ISSUE GH_BIN PINNED_FROM
check_single_production_assignment "$NOTIFY" "scripts/agent-bridge-notify.sh" \
  '^readonly REPO ISSUE FROM GH_BIN KUBECTL_BIN CURL_BIN$' 1 \
  REPO ISSUE FROM CHANNEL NS SVC
# The three credential-touching binaries ARE assigned once on the production path — in the
# `else` arm of the SANDBOX seam, which the arm-aware walk correctly inspects. So the
# expectation is 1, not 0: exactly one production assignment each, and any second one (a
# substitution before the freeze, inside or outside the seam) makes it 2 and fails.
# The earlier `0` was an artefact of skipping the whole seam block, which is the bug this
# walk fixed — an expectation calibrated against a broken measurement.
check_single_production_assignment "$NOTIFY" "scripts/agent-bridge-notify.sh" \
  '^readonly REPO ISSUE FROM GH_BIN KUBECTL_BIN CURL_BIN$' 1 \
  GH_BIN KUBECTL_BIN CURL_BIN

# NOTE on why there is no blanket "reject any production-polarity guard" rule here: the
# first version of this check had one, and it fired on `readonly TESTABLE=0` (a declaration,
# not a comparison) and on the legitimate `if [ "$SANDBOX" -eq 0 ]` that verifies the pinned
# binaries EXIST — a production-only branch that assigns nothing. The property that matters
# is not "a deployed-only branch exists" but "a deployed-only branch ASSIGNS a protected
# constant", and the walk above already counts exactly that, because it skips only the two
# enumerated seam headers and treats every other conditional as production.

# These two are never re-derived at all, so they are readonly at declaration.
for _f in "$WRAPPER" "$NOTIFY"; do
  if ! grep -qE '^readonly TIMEOUT_BIN$' "$_f"; then
    echo "FAIL: ${_f##*/} does not freeze TIMEOUT_BIN — an unbounded call is how a deadline disappears." >&2
    fail=1
  fi
done
if ! grep -qE '^readonly PINNED_FROM=' "$WRAPPER"; then
  echo "FAIL: scripts/agent-bridge-request.sh does not declare PINNED_FROM readonly — the sender identity decides where a reply is routed." >&2
  fail=1
fi

for _c in CHANNEL NS SVC; do
  if ! grep -qE "^readonly $_c=" "$NOTIFY"; then
    echo "FAIL: scripts/agent-bridge-notify.sh does not declare '$_c' readonly." >&2
    echo "      why it is load-bearing: a later re-assignment silently un-pins it, and CHANNEL" >&2
    echo "      re-pointed at ticker:* aims a cluster-wide publish key at the customer nowcast bus." >&2
    fail=1
  fi
  _n="$(grep -cE "^[[:space:]]*(readonly[[:space:]]+)?$_c=" "$NOTIFY")"
  if [ "$_n" != "1" ]; then
    echo "FAIL: scripts/agent-bridge-notify.sh has $_n assignments to $_c; exactly one is allowed." >&2
    fail=1
  fi
done
require "$NOTIFY" "scripts/agent-bridge-notify.sh" \
  'readonly CHANNEL="agent:pdp"' \
  "the real-time channel is a hard-coded readonly constant, never caller-supplied"
# ANCHOR ON THE CODE, NOT ON A STRING THAT ALSO APPEARS IN PROSE. The literal
# "type=escalation" occurs in this file's own comments and in the notifier's, so an
# unanchored search stayed green even if the runtime MARKER were weakened — the gate would
# have been satisfied by the explanation of the thing it was supposed to be guarding.
if ! grep -qE '^MARKER="\^<!-- agent-bridge request_id=\$REQUEST_ID type=escalation from=' "$NOTIFY"; then
  echo "FAIL: scripts/agent-bridge-notify.sh no longer builds the anchored escalation marker." >&2
  echo "      why it is load-bearing: the marker is the ONLY proof an escalation was actually filed." >&2
  echo "      It must match a whole line of the wrapper's own comment; an unanchored or loosened" >&2
  echo "      form lets a routine mailbox entry satisfy the real-time escalation check." >&2
  fail=1
fi
if grep -qE -- '--channel\)' "$NOTIFY"; then
  echo "FAIL: scripts/agent-bridge-notify.sh accepts a --channel argument." >&2
  echo "      why it is load-bearing: the publish key can write to ticker:*, the live customer" >&2
  echo "      nowcast bus. The channel must be unreachable, not merely validated." >&2
  fail=1
fi

# The skill must not teach a raw curl around that wrapper — the recipe it replaced put a
# cluster-wide publish key in the agent's shell.
if grep -qE 'curl .*(api/publish|X-API-Key)' "$SKILL"; then
  echo "FAIL: agent-bridge-request/SKILL.md documents a raw publish curl." >&2
  echo "      why it is load-bearing: that recipe hands an LLM shell a cluster-wide publish" >&2
  echo "      credential and asks it to type the right channel. Use agent-bridge-notify.sh." >&2
  fail=1
fi

# --- wrapper/notifier lockstep: one PII pattern, two copies, no drift ---------------
# The two scripts scan for the same shapes with the same regexes, deliberately -- the
# broadcast lane must not be laxer than the durable one. But two copies of a pattern is two
# places to fix, and on 2026-08-28 exactly one of them got fixed: the street-address word run
# was bounded in the request wrapper and left unbounded in the notifier, so the notifier went
# on classifying "...6 customers ... has no independent way to verify" as a street address and
# would have REFUSED TO PUBLISH THE ESCALATION -- a gate silencing the alarm it protects.
#
# Compare the pattern TEXT rather than trusting a comment that says "keep these in sync".
# A comment is a request; this is what makes the request unnecessary.
#
# `|| true` on both extractions is load-bearing for the reason documented below on the
# allowlist check: under `set -e` a grep that matches nothing exits 1 and kills the script
# INSIDE the assignment, so the guard would die silently with no message and no failure.
# That is exactly what happened on the first version of this block.
_street_w="$(grep -hoE "'[^']*terrace[^']*'" "$WRAPPER" 2>/dev/null | head -1 || true)"
_street_n="$(grep -hoE "'[^']*terrace[^']*'" "$NOTIFY"  2>/dev/null | head -1 || true)"
if [ -n "$_street_w" ] && [ -n "$_street_n" ] && [ "$_street_w" != "$_street_n" ]; then
  echo "FAIL: the street-address PII pattern has DRIFTED between the two wrappers." >&2
  echo "      request : $_street_w" >&2
  echo "      notifier: $_street_n" >&2
  echo "      They scan the same shapes on purpose, and the broadcast lane must never be the" >&2
  echo "      looser of the two. Fixing one copy and not the other is how the notifier came to" >&2
  echo "      refuse ordinary escalation prose that the request wrapper accepted. Change both." >&2
  fail=1
elif [ -z "$_street_w" ] || [ -z "$_street_n" ]; then
  echo "FAIL: could not extract the street-address pattern from one of the wrappers." >&2
  echo "      request : ${_street_w:-<none found>}" >&2
  echo "      notifier: ${_street_n:-<none found>}" >&2
  echo "      A missing pattern is not a passing check: if the scan was removed or reshaped," >&2
  echo "      this guard must say so rather than quietly comparing nothing to nothing." >&2
  fail=1
fi

# --- doc/gate lockstep: the allowlist the skill teaches must be the one enforced ---
# A field the skill recommends but the wrapper refuses is a request the agent cannot
# file and cannot debug: the refusal names a field the agent just read in its own
# instructions. This bit us immediately -- the protocol doc grew a `screenshot_described`
# field that the allowlist did not have.
# `|| true` is load-bearing: under `set -e` a grep that matches nothing exits 1 and
# kills the script INSIDE the assignment, so the "could not extract" branch below could
# never run and the guard died silently with no message. Its own test caught that.
skill_fields="$(sed -n '/^\*\*Evidence fields:\*\*/,/^$/p' "$SKILL" \
  | grep -oE '`[a-z_]+`' | tr -d '`' | sort -u || true)"
wrapper_fields="$(sed -n '/^ALLOWED_EVIDENCE="/,/"$/p' "$WRAPPER" \
  | sed -e 's/^ALLOWED_EVIDENCE="//' -e 's/"$//' | tr ' ' '\n' | grep -v '^$' | sort -u || true)"
if [ -z "$skill_fields" ] || [ -z "$wrapper_fields" ]; then
  echo "FAIL: could not extract the evidence-field lists (skill: $(echo "$skill_fields" | grep -c .), wrapper: $(echo "$wrapper_fields" | grep -c .))." >&2
  echo "      why it is load-bearing: an unreadable list silently stops comparing, which is worse than a mismatch." >&2
  fail=1
elif [ "$skill_fields" != "$wrapper_fields" ]; then
  echo "FAIL: the skill's Evidence fields and the wrapper's ALLOWED_EVIDENCE disagree:" >&2
  diff <(echo "$skill_fields") <(echo "$wrapper_fields") | sed 's/^/      /' >&2
  echo "      why it is load-bearing: the agent would be refused for using a field its own instructions taught it." >&2
  fail=1
fi

# --- registration: a skill an agent cannot invoke is dead weight ------------------
# jq is a REQUIRED dependency of this gate, not an optional nicety. The former `else WARN`
# branch meant that if the runner image or PATH lost jq on the same run that dropped
# agent-bridge-request from the operations skill list, the gate printed a warning nobody
# reads and exited 0 — certifying a doctrine with no invokable route. A gate that cannot
# perform its check has not passed its check; it has failed to run, and those must not be
# the same exit code.
if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is not available, so the openclaw-main.json registration check could not run." >&2
  echo "      This gate fails CLOSED: an unverifiable registration is not a verified one." >&2
  echo "      Install jq on the runner (it is a declared dependency of this guard)." >&2
  fail=1
elif ! jq -e '.agents.list[] | select(.id == "operations") | .skills | index("agent-bridge-request")' \
     "$MAIN_CFG" >/dev/null 2>&1; then
  echo "FAIL: openclaw-main.json does not list agent-bridge-request in the operations agent's skills." >&2
  echo "      why it is load-bearing: an unregistered skill is absent from the agent's invokable catalog, so the doctrine has no path." >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo >&2
  echo "The agent-bridge doctrine lost an anchor. If a change is intentional, update this" >&2
  echo "guard and docs/AGENT_BRIDGE_PROTOCOL.md (Muso-AI/platform-data-processing) together." >&2
  exit 1
fi

echo "OK: agent-bridge doctrine anchors intact (ops SOUL, Caroline SOUL, skill, wrapper, registration)."
