#!/usr/bin/env bash
# check-admin-api-gate-parity.sh — enforce logic parity between the two live
# copies of muso-admin-api.sh's bulk-destructive DELETE gate.
#
# Background: muso-ops-admin is a REGISTERED workspace divergence
# (.skill-workspace-divergence.txt) with TWO live copies of the safety gate:
#   A) skills-all/muso-ops-admin/scripts/muso-admin-api.sh      ("canonical")
#   B) workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh
#      ("workspace")
# check-skill-drift.sh only walks `-name SKILL.md`, so these two shell
# scripts are completely ungated — they could silently diverge on the exact
# safety logic that decides whether a bulk-destructive DELETE run is allowed,
# with nothing in CI to notice. This gate closes that hole for the five
# safety-critical functions without re-litigating whether workspace/canonical
# should differ at all (they legitimately do, in comments and message text).
#
# What counts as "logic" here, and why:
#   - Full-line shell comments (`# ...`) are prose and are stripped before
#     comparison. The two copies intentionally word their comments
#     differently (e.g. canonical: "Requester identity does NOT bypass this
#     gate"; workspace: "God-mode ... does NOT bypass"), and that wording
#     difference carries no behavioral weight.
#   - Heredoc PROSE (the plain English in `cat >&2 <<EOF ... EOF`, the
#     user-facing error messages) is stripped. The two copies word these
#     messages differently for the same reason as the comments (workspace
#     additionally documents its god-mode-does-not-bypass framing inline),
#     and plain prose cannot change what the gate allows or blocks.
#     BUT — and this is the important exception — an unquoted heredoc body
#     is NOT inert. The shell expands it before `cat` runs, and these
#     messages really do contain `$(cat "$TIER2_APPROVERS_PATH" ...)`. So
#     any body line carrying a `$` or a backtick is KEPT and compared: a
#     changed or side-effecting substitution is executable drift, not
#     wording. The heredoc OPENER is kept too (with only the delimiter
#     redacted), so `cat >&2 <<EOF` cannot silently become
#     `cat >/tmp/x <<EOF` — which would hide the refusal from the agent.
#     Removing an entire heredoc block still shows as a diff.
#   - Everything else — variable checks, conditionals, function calls, jq
#     filter expressions, file paths, arg names, return codes — is real
#     logic and is compared byte-for-byte (after whitespace normalization).
#   - Parity is NOT limited to the function bodies. Three further regions are
#     compared: the BULK_DESTRUCTIVE_* / TIER2_APPROVERS_PATH constants, the
#     COMPLETE `if ! ...; then ... fi` around the cmd_call invocation, and the
#     complete approval-evidence parser arms (label through `;;`). Otherwise a
#     copy could raise its threshold, stop calling the gate, swallow a refusal
#     while keeping the call verbatim, or mis-shift its flags, while every
#     tracked function still matched.
#   - Text comparison is LOCATION-BLIND, so two structural invariants are also
#     asserted PER COPY (not just between them): the gate call must sit inside
#     cmd_call and BEFORE the request is dispatched, and the approval-flag arms
#     must precede the catch-all `*) break ;;`. Moving either block without
#     editing it leaves every extraction byte-identical — and if both copies
#     move together, parity by construction can never notice.
#
# Exit codes (mirrors scripts/check-collaborator-doctrine.sh):
#   0 — no drift in any tracked function
#   1 — a tracked function's logic differs between copies
#   2 — cannot verify (missing file/function, tool failure) — fails CLOSED,
#       never passes vacuously

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

CANONICAL="${ADMIN_API_CANONICAL:-$REPO_ROOT/skills-all/muso-ops-admin/scripts/muso-admin-api.sh}"
WORKSPACE_COPY="${ADMIN_API_WORKSPACE:-$REPO_ROOT/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh}"

# Safety-critical functions tracked for parity. Confirmed present in both
# copies as of authoring this gate (grep -c '^<fn>()' on each file); if a
# future edit renames or removes one of these from either copy, that's
# exactly the kind of drift this gate exists to catch, so we fail closed
# below rather than silently shrinking the list.
FUNCTIONS=(
    is_bulk_destructive_op
    count_recent_destructive_ops
    enforce_bulk_destructive_gate
    record_destructive_op
    is_tier2_approver
    # Added 2026-08-05 with the profile-enrich link gate. It ships in BOTH
    # copies because the operations agent executes the workspace one, so a
    # canonical-only edit would leave the live copy ungated — precisely the
    # drift this list exists to catch.
    enforce_profile_enrich_link_gate
    # The gate's path canonicalizer. Tracked for the same reason and because a
    # divergence here silently changes WHICH requests the gate can see: the
    # review found that a literal match let uppercase, dot-segment, fragment and
    # repeated-slash spellings through to the same live route.
    normalize_admin_path
    # Added 2026-08-26 with the god-mode self-approve port. Both were carved out
    # of enforce_bulk_destructive_gate (which IS tracked), so without listing
    # them here the port QUIETLY SHRANK this gate's coverage: the fail-closed
    # audit write and the predicate that decides WHO may self-approve a mass
    # DELETE both became editable in one copy only, with nothing in CI to notice.
    write_bulk_destructive_audit
    is_tier2_godmode_requester
)

[[ -f "$CANONICAL" ]] || {
    echo "FATAL: canonical script not found: $CANONICAL" >&2
    exit 2
}
[[ -f "$WORKSPACE_COPY" ]] || {
    echo "FATAL: workspace script not found: $WORKSPACE_COPY" >&2
    exit 2
}
[[ -r "$CANONICAL" && -r "$WORKSPACE_COPY" ]] || {
    echo "FATAL: cannot read one of the two admin-api script copies." >&2
    exit 2
}

command -v awk >/dev/null 2>&1 || { echo "FATAL: awk not found." >&2; exit 2; }
command -v sed >/dev/null 2>&1 || { echo "FATAL: sed not found." >&2; exit 2; }
command -v diff >/dev/null 2>&1 || { echo "FATAL: diff not found." >&2; exit 2; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/check-admin-api-gate-parity.XXXXXX")" || { echo "FATAL: mktemp -d failed." >&2; exit 2; }
trap 'rm -rf "$WORKDIR"' EXIT

# extract_function FILE FUNCNAME -> prints the function body (from the
# `funcname() {` line through the FIRST following line that is exactly `}`
# at column 0). This repo's shell functions are all written at top level with
# no nested top-level `}` inside a function body (heredocs terminate on a
# bare `EOF`, not `}`), so this is a safe boundary. If the function is never
# found, prints nothing — the caller must treat that as a hard failure, not
# an empty-but-valid function.
extract_function() {
    local file="$1" fn="$2"
    awk -v fn="$fn" '
        $0 ~ ("^" fn "\\(\\)") { found = 1 }
        found { print }
        found && /^}/ { exit }
    ' "$file"
}

# normalize_logic -> reads a function body on stdin, strips full-line
# comments and heredoc body text (see header comment for rationale),
# collapses blank lines, and trims leading/trailing whitespace per line.
# Heredoc detection is scoped to the `<<EOF` (unquoted, bare-word delimiter,
# end-of-line) form actually used in this file — NOT `<<<` here-strings
# (used elsewhere for jq input), which are left untouched as real logic.
normalize_logic() {
    awk '
        /<<EOF[[:space:]]*$/ {
            # Keep the OPENER (command + redirection), redact only the delimiter
            # and body. Replacing the whole line would make `cat >&2 <<EOF` and
            # `cat >/tmp/x <<EOF` normalize identically — i.e. a change that
            # redirects the refusal message away from stderr, making it invisible
            # to the agent, would pass the parity gate. Verified: that exact drift
            # inside enforce_bulk_destructive_gate slipped through before this.
            opener = $0
            sub(/<<EOF[[:space:]]*$/, "<<HEREDOC_BODY_REDACTED", opener)
            print opener
            in_heredoc = 1
            next
        }
        in_heredoc && /^EOF[[:space:]]*$/ {
            in_heredoc = 0
            next
        }
        in_heredoc {
            # An UNQUOTED heredoc body is NOT inert prose: the shell performs
            # parameter, command and arithmetic expansion before `cat` runs.
            # These messages really do contain $(cat "$TIER2_APPROVERS_PATH" ...),
            # so dropping every body line would let executable drift — a changed
            # or side-effecting substitution in one copy — pass parity.
            #
            # Keep EVERY expansion form, not just the obvious ones. An earlier
            # version matched only $(, ${ and backticks, which silently dropped
            # plain $NAME, $1 and $? — so a copy could change a diagnostic to
            # expand a different (or sensitive) variable and still pass. Any `$`
            # in an unquoted heredoc is an expansion or one edit away from being
            # one, so the test is simply: does the line contain $ or a backtick.
            if ($0 ~ /\$/ || $0 ~ /`/) print
            next
        }
        { print }
    ' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
      | sed -E '/^#/d' \
      | sed -E '/^$/d'
}

# --- structural reachability invariants (per copy, not just parity) ---------
#
# The region extractors compare the TEXT of the call site and the parser arms.
# Text is location-blind: a copy can move the byte-identical
# `if ! enforce_bulk_destructive_gate ...; then return 1; fi` block after the
# curl, or move the four flag arms after `*) break ;;`, and the extracted output
# is unchanged — parity passes while the DELETE runs before the gate, or the
# approval flags are never parsed. Verified: relocating that block past the
# request dispatch passed this gate before these assertions existed.
#
# Parity can never catch this on its own — if BOTH copies move it, they still
# match. So these are per-copy invariants, checked independently of the diff.
#
# assert_structure FILE LABEL -> 0 ok, 1 violation (increments FAIL via caller)
assert_structure() {
    local file="$1" label="$2" rc=0
    local cmd_start gate_line curl_line arm_line break_line

    cmd_start=$(awk '/^cmd_call\(\)/ { print NR; exit }' "$file")
    gate_line=$(awk -v s="$cmd_start" 'NR>=s && /enforce_bulk_destructive_gate[[:space:]]+"/ { print NR; exit }' "$file")
    curl_line=$(awk -v s="$cmd_start" 'NR>=s && /curl[[:space:]]+"\$\{curl_args\[@\]\}"/ { print NR; exit }' "$file")
    arm_line=$(awk '/^[[:space:]]*--confirmed-by\)/ { print NR; exit }' "$file")
    break_line=$(awk '/^[[:space:]]*\*\)[[:space:]]*break[[:space:]]*;;/ { print NR; exit }' "$file")

    if [[ -z "$cmd_start" || -z "$gate_line" || -z "$curl_line" || -z "$arm_line" || -z "$break_line" ]]; then
        echo "FATAL: cannot locate the structural anchors in ${label} (cmd_call=$cmd_start gate=$gate_line curl=$curl_line arm=$arm_line break=$break_line) — refusing to certify parity." >&2
        exit 2
    fi

    if (( gate_line <= cmd_start )); then
        echo "VIOLATION: ${label}: the bulk-destructive gate call is not inside cmd_call()." >&2
        rc=1
    fi
    if (( gate_line >= curl_line )); then
        echo "VIOLATION: ${label}: the bulk-destructive gate is invoked at line ${gate_line}, AFTER the request is dispatched at line ${curl_line} — the DELETE would run before the gate could refuse it." >&2
        rc=1
    fi
    if (( arm_line >= break_line )); then
        echo "VIOLATION: ${label}: the approval-evidence flag arms start at line ${arm_line}, AFTER the catch-all \`*) break ;;\` at line ${break_line} — they are unreachable, so --confirmed-by would never be parsed." >&2
        rc=1
    fi
    return "$rc"
}

FAIL=0

for pair in "CANONICAL:$CANONICAL" "WORKSPACE:$WORKSPACE_COPY"; do
    lbl="${pair%%:*}"; f="${pair#*:}"
    if assert_structure "$f" "$lbl"; then
        echo "OK: ${lbl} structure — gate runs inside cmd_call before the request; flag arms reachable."
    else
        FAIL=$((FAIL + 1))
    fi
done


for fn in "${FUNCTIONS[@]}"; do
    a_raw="$WORKDIR/a_${fn}.raw"
    b_raw="$WORKDIR/b_${fn}.raw"
    extract_function "$CANONICAL" "$fn" > "$a_raw" || {
        echo "FATAL: extraction failed for ${fn} in canonical copy (awk error)." >&2
        exit 2
    }
    extract_function "$WORKSPACE_COPY" "$fn" > "$b_raw" || {
        echo "FATAL: extraction failed for ${fn} in workspace copy (awk error)." >&2
        exit 2
    }

    if [[ ! -s "$a_raw" ]]; then
        echo "FATAL: function '${fn}' not found in canonical copy ($CANONICAL) — cannot verify parity." >&2
        exit 2
    fi
    if [[ ! -s "$b_raw" ]]; then
        echo "FATAL: function '${fn}' not found in workspace copy ($WORKSPACE_COPY) — cannot verify parity." >&2
        exit 2
    fi

    a_norm="$WORKDIR/a_${fn}.norm"
    b_norm="$WORKDIR/b_${fn}.norm"
    normalize_logic < "$a_raw" > "$a_norm" || {
        echo "FATAL: normalization failed for ${fn} (canonical)." >&2
        exit 2
    }
    normalize_logic < "$b_raw" > "$b_norm" || {
        echo "FATAL: normalization failed for ${fn} (workspace)." >&2
        exit 2
    }

    if ! diff -q "$a_norm" "$b_norm" >/dev/null 2>&1; then
        FAIL=$((FAIL + 1))
        echo ""
        echo "VIOLATION: ${fn}() has drifted between the two live copies:"
        echo "  A) ${CANONICAL#"$REPO_ROOT"/}"
        echo "  B) ${WORKSPACE_COPY#"$REPO_ROOT"/}"
        echo "  (comments and heredoc message text are normalized out — this is a real logic diff)"
        # Display-only, and `diff -u` exits 1 whenever it finds the difference we
        # just established exists. Under `set -euo pipefail` that expected status
        # would kill the script right here — before the remaining functions are
        # compared and before the aggregate FAIL below ever prints. The gate would
        # still exit non-zero, so it looks fine, but it silently reports only the
        # FIRST drifted function. `|| true` keeps this line diagnostic. (It also
        # absorbs SIGPIPE when `head` closes the pipe early.)
        diff -u "$a_norm" "$b_norm" 2>&1 | head -30 | sed 's/^/    /' || true
    else
        echo "OK: ${fn}() logic matches between copies."
    fi
done

# --- regions outside the tracked functions ----------------------------------
# Comparing only function BODIES leaves the rest of the enforcement path
# unguarded: the threshold/window constants, the cmd_call site that actually
# invokes the gate, and the parser arms that capture the approval evidence all
# live at other scopes. One copy could raise its threshold, stop calling
# enforce_bulk_destructive_gate entirely, or stop parsing --confirmed-by, and a
# function-only comparison would still report parity. Each region is a grep
# pattern; the matched lines (in file order, whitespace-normalized) must agree.
REGION_NAMES=(
    "bulk-gate config constants"
    "bulk-gate call site in cmd_call"
    "approval-evidence flag parsing"
)
REGION_PATTERNS=(
    '^(BULK_DESTRUCTIVE_[A-Z_]+|TIER2_APPROVERS_PATH)='
    'STRUCTURAL:gate-call-block'
    'STRUCTURAL:parser-arms'
)

# extract_region FILE PATTERN -> matched lines, whitespace-normalized.
# grep exit 1 (no match) is NOT swallowed: an empty region means the safety
# construct vanished from that copy, which the caller treats as fatal.
extract_region() {
    local file="$1" pattern="$2" rc=0
    grep -E -- "$pattern" "$file" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' || rc=$?
    return "$rc"
}

# extract_gate_call_block FILE -> the COMPLETE conditional wrapping the gate
# invocation, `if ! enforce_bulk_destructive_gate ...` through its `fi`.
#
# Comparing only the invocation line is not enough: both copies currently wrap it
# in `if ! ...; then return 1; fi`, and a copy could keep the call verbatim while
# changing or dropping the `return 1`. A refused gate would then fall through to
# the DELETE it just blocked, with this checker still certifying parity. The
# conditional, not the call, is the safety construct.
extract_gate_call_block() {
    local file="$1"
    awk '
        /if[[:space:]]*!?[[:space:]]*enforce_bulk_destructive_gate/ { inblk = 1 }
        inblk { print }
        inblk && /^[[:space:]]*fi[[:space:]]*$/ { inblk = 0 }
    ' "$file" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

# extract_parser_arms FILE -> the COMPLETE case arms for the approval-evidence
# flags, label through `;;`.
#
# A line-grep for the label and the assignment is not enough: it omits each arm's
# `shift 2` and its `;;`, so one copy could consume a different number of
# arguments (desyncing every later flag) or fall through into the next arm while
# the gate still reported parity. The arm is the unit of meaning, so extract it
# structurally.
extract_parser_arms() {
    local file="$1"
    awk '
        /^[[:space:]]*--(confirmed-by|approval-msg-id|approval-author-id|approval-channel)\)/ { inarm = 1 }
        inarm { print }
        inarm && /^[[:space:]]*;;[[:space:]]*$/ { inarm = 0 }
    ' "$file" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

for i in "${!REGION_NAMES[@]}"; do
    name="${REGION_NAMES[$i]}"
    pat="${REGION_PATTERNS[$i]}"
    a_reg="$WORKDIR/a_region_${i}"
    b_reg="$WORKDIR/b_region_${i}"
    if [[ "$pat" == "STRUCTURAL:gate-call-block" ]]; then
        extract_gate_call_block "$CANONICAL" > "$a_reg" || true
        extract_gate_call_block "$WORKSPACE_COPY" > "$b_reg" || true
    elif [[ "$pat" == "STRUCTURAL:parser-arms" ]]; then
        extract_parser_arms "$CANONICAL" > "$a_reg" || true
        extract_parser_arms "$WORKSPACE_COPY" > "$b_reg" || true
    else
        extract_region "$CANONICAL" "$pat" > "$a_reg" || true
        extract_region "$WORKSPACE_COPY" "$pat" > "$b_reg" || true
    fi

    if [[ ! -s "$a_reg" ]]; then
        echo "FATAL: region '${name}' matched nothing in the canonical copy — cannot verify parity." >&2
        exit 2
    fi
    if [[ ! -s "$b_reg" ]]; then
        echo "FATAL: region '${name}' matched nothing in the workspace copy — the safety construct is missing there." >&2
        exit 2
    fi

    if ! diff -q "$a_reg" "$b_reg" >/dev/null 2>&1; then
        FAIL=$((FAIL + 1))
        echo ""
        echo "VIOLATION: region '${name}' has drifted between the two live copies:"
        diff -u "$a_reg" "$b_reg" 2>&1 | head -20 | sed 's/^/    /' || true
    else
        echo "OK: region '${name}' matches between copies."
    fi
done

echo ""
if (( FAIL > 0 )); then
    echo "FAIL: ${FAIL} safety-critical function(s)/region(s) drifted between the canonical and workspace muso-admin-api.sh copies." >&2
    echo "Reconcile the logic (comments/message prose may still differ) or this gate stays red." >&2
    exit 1
fi

echo "OK: bulk-destructive gate parity holds — ${#FUNCTIONS[@]} functions and ${#REGION_NAMES[@]} call-site/config/parser regions match between the canonical and workspace muso-admin-api.sh copies."
exit 0
