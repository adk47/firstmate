#!/usr/bin/env bats
# Tests for resolve_slack_to_email() in muso-admin-api.sh — the Slack-UID ->
# muso.ai-email map that every ops-admin call funnels `--requester` through.
#
# Why this suite exists (drift found during #773, fixed in the same PR as this
# file): resolve_slack_to_email fails closed by ECHOING THE INPUT BACK and
# returning 1. That makes a missing person SILENT — the caller gets a raw `U…`
# where an email belongs, `--requester` puts a Slack UID in the backend audit
# trail, and nothing anywhere raises. Canonical had drifted in both directions:
# four current staff (Mariia, Artem, Faith, McLaren) had no arm at all, and
# departed Oleg (U02S7TJ7QHY) still mapped to a live address — the worse half,
# since it attributes a live admin mutation to a former employee.
#
# shared-reference/reference/slack-people.json (#773) is the single source of
# truth for WHO is current. It carries no email addresses, and the map is the
# only place that knows McLaren is `f@muso.ai` (single letter, not `mclaren@`),
# so the two are coupled on UIDs ONLY: the set of UIDs with an arm must equal
# the set of `kind:"human"` + `current:true` UIDs in the roster, both ways.
# That is the whole coupling — emails are asserted here, by hand, per arm.
bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/skills-all/muso-ops-admin/scripts/muso-admin-api.sh"
# The operations agent runs a rank-1 workspace shadow of this script
# (registered in .skill-workspace-divergence.txt for its god-mode allowlist).
# Its map is checked against the roster too — it is the copy that actually
# resolves requesters in production, and it can go stale the same way.
WORKSPACE_SCRIPT="$REPO_ROOT/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh"
ROSTER="$REPO_ROOT/shared-reference/reference/slack-people.json"
# muso-devops-set-env carries a THIRD resolver. It is deliberately a subset —
# it only names people who drive env sets — so it is held to the one-directional
# invariant below (no departed person) rather than full roster equality.
DEVOPS_SCRIPT="$REPO_ROOT/skills-all/muso-devops-set-env/scripts/devops-set-env.sh"

# The resolver as BASH itself parses it, canonically re-rendered.
#
# This suite spent six review rounds losing an argument with shell syntax. Every
# structural guard below rests on knowing which case arms exist, and each round
# found another legal way to write an arm that a hand-rolled scanner could not
# see. Each one was live shell that resolved a departed person, or an unknown
# UID, to a real mailbox while the whole suite stayed green:
#
#   U02S7TJ7QHY) + `echo` on the next line   multiline arm
#   U0OLD|U02S7TJ7QHY)                       alternation
#   U9*)                                     glob matching unenumerated UIDs
#   ... ;; U9*) ...                          second arm hidden on one line
#   ;& then U9*)                             arm after a fallthrough terminator
#   : "#"; ... ;; U9*) ...                   quoted `#` eating the terminator
#   nested `}` at column 0                   truncating the slice
#   heredoc payload containing `}`           truncating the slice
#
# Seven fixes to a text scanner produced an eighth bypass, which is the answer:
# the scanner was the wrong tool. Bash is the only thing that reliably parses
# bash, so it does the parsing. `declare -f` prints the function back through
# the shell's own parser, in a canonical layout — one label per line, every
# terminator on its own line, heredocs/quotes/braces/line-joins already
# resolved. Whatever bash will actually execute is what we read.
#
# Fails closed: if the script cannot be sourced, the output is empty, no arms
# are found, and the vacuity check in "every case arm is a plain literal"
# fails rather than passing on an empty map. A subcommand is passed because
# these scripts `die` on no arguments, which would exit before `declare -f`.
fn_source() {
    bash -c 'source "$1" resolve-email U7RP6HKUZ >/dev/null 2>&1
             declare -f resolve_slack_to_email' _ "$1" 2>/dev/null
}

# Every case label, one per line, in source order:
#   - a literal label prints as itself (`U7RP6HKUZ`, `clio`, `U0OLD|U0NEW`)
#   - the catch-all prints as `*`
#   - ANYTHING ELSE prints as `UNPARSEABLE:<line>`
#
# The last branch is still the point, and still fail-closed: bash preserves a
# label exactly as written, so `"U0X")`, `U[0-9]*)` and `$VAR)` all arrive
# intact and are refused rather than guessed at. What has changed is that a
# label can no longer be INVISIBLE — bash renders every arm it will execute.
case_labels() {
    fn_source "$1" | awk '
        { gsub(/^[[:space:]]+|[[:space:]]+$/, "") }
        $0 == "" { next }
        /^case[[:space:]].*[[:space:]]in$/ { expect = 1; next }
        /^esac;?$/                         { expect = 0; next }
        expect {
            # declare -f renders alternation as `A | B)`; normalize the spacing.
            if (match($0, /^[A-Za-z0-9_|[:space:]-]+\)$/)) {
                lbl = substr($0, 1, RLENGTH - 1)
                gsub(/[[:space:]]/, "", lbl)
                print lbl
            }
            else if ($0 == "*)") print "*"
            else                 print "UNPARSEABLE:" $0
            expect = 0
        }
        /^;;&?$/ || /^;&$/ { expect = 1 }
    '
}

# The identity arms only: catch-all and unparseable lines dropped (the latter
# are the subject of their own test below), `|` alternatives split apart.
map_arms() {
    case_labels "$1" \
        | grep -vE '^(\*|UNPARSEABLE:)' \
        | tr '|' '\n' \
        | grep -v '^$' \
        | sort -u
}

# Just the Slack-UID arms. The workspace copy also carries a `clio)` arm for the
# bot's synthetic identity, which is deliberately not a person and must not be
# compared against the roster.
map_uids() { map_arms "$1" | grep -E '^U[A-Z0-9]+$' | sort; }

# Every UID the roster says is a current human. The `type == "object"` guard
# skips the `_purpose` / `_roster` / `_github` / `_kind` prose keys; the
# `kind == "human"` guard keeps bot accounts (Clio) out — bots carry no
# `current` field on purpose.
roster_current_uids() {
    jq -r 'to_entries[]
           | select(.value | type == "object")
           | select(.value.kind == "human" and .value.current == true)
           | .key' "$ROSTER" | sort
}

# Everyone the roster records as having left. Same guards, inverted predicate:
# `current == false` rather than `not current`, so a bot entry (no `current`
# field at all) is never mistaken for a departed human.
roster_former_uids() {
    jq -r 'to_entries[]
           | select(.value | type == "object")
           | select(.value.kind == "human" and .value.current == false)
           | .key' "$ROSTER" | sort
}

# ── Positive cases: one per arm ──────────────────────────────────────────────

@test "U7RP6HKUZ -> Aaron" {
  run bash "$SCRIPT" resolve-email U7RP6HKUZ
  [ "$status" -eq 0 ]
  [ "$output" = "aaron@muso.ai" ]
}

@test "a departed person's UID resolves to nothing (Serhii, left 2026-08-26)" {
  run bash "$SCRIPT" resolve-email U03TYGJF1N3
  [ "$status" -eq 1 ]
  [ "$output" = "U03TYGJF1N3" ]
}

@test "U038BM16T7W -> Jan (jan@, NOT jay@)" {
  run bash "$SCRIPT" resolve-email U038BM16T7W
  [ "$status" -eq 0 ]
  [ "$output" = "jan@muso.ai" ]
}

@test "U0AL36NADEY -> Nick" {
  run bash "$SCRIPT" resolve-email U0AL36NADEY
  [ "$status" -eq 0 ]
  [ "$output" = "nick@muso.ai" ]
}

@test "U0A8CCTTAAG -> Liza" {
  run bash "$SCRIPT" resolve-email U0A8CCTTAAG
  [ "$status" -eq 0 ]
  [ "$output" = "liza@muso.ai" ]
}

@test "U03LP8YHLPK -> Mariia" {
  run bash "$SCRIPT" resolve-email U03LP8YHLPK
  [ "$status" -eq 0 ]
  [ "$output" = "mariia@muso.ai" ]
}

@test "U02N2NP3H7F -> Artem" {
  run bash "$SCRIPT" resolve-email U02N2NP3H7F
  [ "$status" -eq 0 ]
  [ "$output" = "artem@muso.ai" ]
}

@test "U0AV9C7CFRQ -> Faith" {
  run bash "$SCRIPT" resolve-email U0AV9C7CFRQ
  [ "$status" -eq 0 ]
  [ "$output" = "faith@muso.ai" ]
}

# McLaren's address really is a single letter. Asserting it explicitly is the
# point of this case: a "helpful" correction to mclaren@muso.ai resolves to a
# mailbox that does not exist, and nothing downstream would notice.
@test "U02S7C96CGN -> McLaren (f@muso.ai, single letter)" {
  run bash "$SCRIPT" resolve-email U02S7C96CGN
  [ "$status" -eq 0 ]
  [ "$output" = "f@muso.ai" ]
}

# ── Fail-closed behavior ─────────────────────────────────────────────────────

# This is the behavior that makes a missing arm invisible, so pin it: callers
# depend on the nonzero status (`|| REQUESTER_EMAIL="$2"` in the workspace copy)
# and on the echoed passthrough. Any change here changes what a stale map does.
@test "unknown UID -> echoes input back, exit 1 (fail-closed but SILENT)" {
  run bash "$SCRIPT" resolve-email U0NOTAPERSON
  [ "$status" -eq 1 ]
  [ "$output" = "U0NOTAPERSON" ]
}

@test "a departed person's UID resolves to nothing (Oleg)" {
  run bash "$SCRIPT" resolve-email U02S7TJ7QHY
  [ "$status" -eq 1 ]
  [ "$output" = "U02S7TJ7QHY" ]
}

@test "an address passes through untouched" {
  run bash "$SCRIPT" resolve-email jan@muso.ai
  [ "$status" -eq 0 ]
  [ "$output" = "jan@muso.ai" ]
}

# ── The parser itself ────────────────────────────────────────────────────────

# Everything below leans on map_arms, so a blind spot in it silently disables
# every guard at once rather than failing. This fixture pins every arm layout
# that beat an earlier version of this suite — each one was live shell that
# resolved an unknown or departed UID while all tests passed.
#
# It is the discrimination half. The stability half is asserted in the same
# test, because a parser that swept the `*)` catch-all in would red the roster
# checks forever and then get "fixed" by loosening them.
@test "map_arms sees a case label wherever it is legally written" {
  local fixture="$BATS_TEST_TMPDIR/arms.sh"
  cat > "$fixture" <<'FIXTURE'
resolve_slack_to_email() {
    local input="$1"
    # U0DECOY) is prose, not an arm -- comments must not invent labels
    case "$input" in U0SAMELINE) echo "same@muso.ai" ;;
        U0OWNLINE)   echo "own@muso.ai" ;;
        U0MULTILINE)
            echo "multi@muso.ai"
            ;;
        U0ALTONE|U0ALTTWO) echo "alt@muso.ai" ;;
        U9*) echo "glob@muso.ai" ;;
        U0PAIRED) echo "paired@muso.ai" ;; U0HIDDEN*) echo "hidden@muso.ai" ;;
        U0QUOTEHASH) : "#"; echo "qh@muso.ai" ;; U0BEHINDHASH*) echo "behind@muso.ai" ;;
        U0BRACEGROUP)
            {
                echo "brace@muso.ai"
}
            ;;
        U0AFTERBRACE*) echo "afterbrace@muso.ai" ;;
        U0HEREDOC)
            cat <<'PAYLOAD' >/dev/null
}
PAYLOAD
            echo "heredoc@muso.ai"
            ;;
        U0AFTERDOC*) echo "afterdoc@muso.ai" ;;
        U0FALLTHRU)
            echo "fall@muso.ai"
            ;&
        U0AFTERFALL*)
            echo "afterfall@muso.ai"
            ;;
        clio)
            echo "clio"
            return 0
            ;;
        *)
            echo "$input"
            return 1
            ;;
    esac
    return 0
}
FIXTURE

  local labels output
  labels="$(case_labels "$fixture")"
  output="$(map_arms "$fixture")"

  # Every literal arm must be SEEN, in each layout that once hid one.
  local lit
  for lit in U0SAMELINE U0OWNLINE U0MULTILINE U0ALTONE U0ALTTWO U0PAIRED \
             U0QUOTEHASH U0BRACEGROUP U0HEREDOC U0FALLTHRU clio; do
    [[ "$output" == *"$lit"* ]] || { echo "literal arm not seen: $lit" >&2; return 1; }
  done
  # Alternation is N identities, split apart — never left glued together.
  [[ "$output" != *"U0ALTONE|U0ALTTWO"* ]]

  # Every pattern arm must be REFUSED, never reported as an identity. Each of
  # these sat behind a literal arm in a layout that once made it invisible:
  # same-line pair, quoted `#`, brace group, heredoc payload, `;&` fallthrough.
  local pat
  for pat in 'U9*)' 'U0HIDDEN*)' 'U0BEHINDHASH*)' 'U0AFTERBRACE*)' \
             'U0AFTERDOC*)' 'U0AFTERFALL*)'; do
    [[ "$labels" == *"UNPARSEABLE:$pat"* ]] || { echo "pattern arm not refused: $pat" >&2; return 1; }
    [[ "$output" != *"${pat%\*)}"* ]] || { echo "pattern arm counted as identity: $pat" >&2; return 1; }
  done

  # Stability: the catch-all is the fail-closed path, not a person; and prose in
  # a comment is not an arm.
  [[ "$output" != *"*"* ]]
  [[ "$output" != *U0DECOY* ]]
}

# The scanner reads the resolver through bash. If bash cannot parse the file at
# all, that must yield NO arms rather than a partial reading of a file the shell
# would reject — the empty result is what the vacuity check below converts into
# a red, instead of an empty map quietly satisfying every set comparison.
@test "a file bash cannot parse yields no arms (fail closed)" {
  local broken="$BATS_TEST_TMPDIR/broken.sh"
  cat > "$broken" <<'BROKEN'
resolve_slack_to_email() {
    case "$1" in
        U0OK) echo "ok@muso.ai" ;;
        U0BROKEN) echo "unterminated@muso.ai ;;
    esac
}
BROKEN
  run bash -n "$broken"
  [ "$status" -ne 0 ]

  run map_arms "$broken"
  [ -z "$output" ]
}

# ── Fail closed on syntax this suite cannot reason about ─────────────────────

# Every other structural check answers "which identities are mapped?" by reading
# labels. That question is only meaningful if every arm IS a plain identity. A
# pattern arm answers for identities nobody enumerated: `U9*)` matches an
# unbounded set, so it cannot be checked against the roster at all — and because
# no roster UID starts with U9, neither the set checks nor the behavioral loop
# could see it. It resolved every unknown U9 UID to Aaron with 0 of 19 tests red.
#
# So unsupported arm syntax is rejected outright rather than parsed harder.
# Globs, quoting and continuations are all refused the same way, without this
# file needing to understand them. If a future arm legitimately needs one,
# that is a deliberate decision and this test is where it gets made.
@test "every case arm is a plain literal or the catch-all (no pattern arms)" {
  local copy bad
  for copy in "$SCRIPT" "$WORKSPACE_SCRIPT" "$DEVOPS_SCRIPT"; do
    bad="$(case_labels "$copy" | grep '^UNPARSEABLE:' || true)"
    [ -z "$bad" ] || {
      echo "$copy has case arm(s) this suite cannot verify against the roster:" >&2
      echo "$bad" >&2
      echo "A pattern arm maps identities nobody enumerated — make it a literal." >&2
      return 1
    }
    # A resolver with no literal arms at all would pass the check above
    # vacuously; it must actually have found some.
    [ -n "$(map_arms "$copy")" ]
  done
}

# ── Behavioral backstop ──────────────────────────────────────────────────────

# The structural checks below read the source; this one reads nothing. It RUNS
# each resolver against every person the roster records as departed and asserts
# none of them produces an address, so no case-label layout can pass it while
# misbehaving — the shell itself does the resolving.
#
# Its coverage is exactly the roster's former humans, and no wider. It cannot
# speak for a UID nobody has enumerated, which is why the pattern-arm rejection
# above is a separate test rather than something this one subsumes: together
# they cover "every arm is a literal" and "every known departed literal fails
# closed", and neither alone is sufficient.
#
# Asserted on OUTPUT rather than exit code because the three copies legitimately
# differ there: the ops-admin copies return 1, while devops-set-env resolves via
# `$(resolve_slack_to_email ... || true)` and always exits 0. Passthrough of the
# raw UID is the fail-closed signal common to all three, and it is the one that
# matters — it means no live mailbox was emitted.
@test "every departed person in the roster fails closed in all three resolvers" {
  local former uid copy out
  former="$(roster_former_uids)"
  [ -n "$former" ]
  for copy in "$SCRIPT" "$WORKSPACE_SCRIPT" "$DEVOPS_SCRIPT"; do
    for uid in $former; do
      out="$(bash "$copy" resolve-email "$uid" 2>/dev/null || true)"
      [ "$out" = "$uid" ] || {
        echo "$copy resolved DEPARTED $uid to '$out' — expected the raw UID back" >&2
        return 1
      }
    done
  done
}

# The workspace copy is the rank-1 shadow the operations agent actually runs, so
# its VALUES are what reach production — but only its UID set was gated, and a
# workspace-only typo (McLaren as `mclaren@muso.ai`) would keep every set check
# and every canonical positive case green while the live agent sent the wrong
# Requester identity. Canonical's addresses are pinned by the nine positive
# cases above, so asserting the two copies agree transitively pins the
# workspace's too, without duplicating nine addresses in a second place to drift.
@test "the workspace copy resolves every current human identically to canonical" {
  local uid canon ws
  for uid in $(roster_current_uids); do
    canon="$(bash "$SCRIPT" resolve-email "$uid")"
    ws="$(bash "$WORKSPACE_SCRIPT" resolve-email "$uid")"
    [ "$canon" = "$ws" ] || {
      echo "$uid: canonical='$canon' but workspace='$ws' — the workspace copy is what production runs" >&2
      return 1
    }
  done
}

# ── Roster coupling: the map is exactly the current humans ───────────────────

# The direction that bit us. A non-current UID mapping to a live address means
# an admin mutation gets attributed to someone who has left.
@test "no non-current person has a mapping (canonical + workspace)" {
  local roster stale copy
  roster="$(roster_current_uids)"
  [ -n "$roster" ]
  for copy in "$SCRIPT" "$WORKSPACE_SCRIPT"; do
    stale="$(comm -23 <(map_uids "$copy") <(printf '%s\n' "$roster"))"
    [ -z "$stale" ] || {
      echo "$copy maps UID(s) that slack-people.json does not list as a current human:" >&2
      echo "$stale" >&2
      return 1
    }
  done
}

# Same invariant, applied to the devops-set-env resolver. Only this direction:
# that map is allowed to be a subset (authority lives in its requesters files),
# but it must never resolve someone who has left, which would put a departed
# person's live address in the /var/log/muso-devops audit trail.
@test "no non-current person has a mapping (muso-devops-set-env)" {
  local roster stale
  roster="$(roster_current_uids)"
  [ -n "$roster" ]
  stale="$(comm -23 <(map_uids "$DEVOPS_SCRIPT") <(printf '%s\n' "$roster"))"
  [ -z "$stale" ] || {
    echo "$DEVOPS_SCRIPT maps UID(s) that slack-people.json does not list as a current human:" >&2
    echo "$stale" >&2
    return 1
  }
}

# The other direction, and the reason this is a test rather than a comment:
# a current employee with no arm is not an error at runtime, just a raw UID in
# the audit trail. Only a red test surfaces it.
@test "every current human has a mapping (canonical + workspace)" {
  local roster missing copy
  roster="$(roster_current_uids)"
  [ -n "$roster" ]
  for copy in "$SCRIPT" "$WORKSPACE_SCRIPT"; do
    missing="$(comm -13 <(map_uids "$copy") <(printf '%s\n' "$roster"))"
    [ -z "$missing" ] || {
      echo "$copy has no arm for current human UID(s) — --requester would send a raw UID:" >&2
      echo "$missing" >&2
      return 1
    }
  done
}

# ── Coverage guard (modelled on scripts/tests/qa-author-slack-uid.bats) ──────

# The roster tests above prove the map holds the right UIDs; they cannot prove
# any arm actually resolves, or resolves to the right address. An arm with a
# typo'd email passes both. So assert every arm also has a positive case above,
# by name — otherwise the next mapping added inherits exactly the silence this
# whole suite exists to remove.
@test "every mapping in the canonical script has a positive test case" {
  local arms tested a missing=""
  arms="$(map_arms "$SCRIPT")"
  [ -n "$arms" ]
  tested="$(grep -oE '^[[:space:]]*run bash "\$SCRIPT" resolve-email [A-Za-z0-9_-]+' "$BATS_TEST_FILENAME" \
            | awk '{print $NF}' | sort -u)"
  for a in $arms; do
    printf '%s\n' "$tested" | grep -qx -- "$a" || missing="$missing $a"
  done
  [ -z "$missing" ] || { echo "mapping(s) with no positive test:$missing" >&2; return 1; }
}
