#!/usr/bin/env bash
# check-no-canonical-godmode-allowlist.sh — the god-mode allowlist must exist in
# the operations workspace ONLY, never in the canonical skill.
#
# WHY THIS EXISTS (policy 2026-08-26)
#
# `enforce_bulk_destructive_gate` lets a requester on the god-mode allowlist
# self-approve a bulk-destructive DELETE run with --approval-msg-id alone,
# instead of a second human's --confirmed-by. That branch now ships in BOTH
# copies of muso-admin-api.sh, because check-admin-api-gate-parity.sh requires
# the two copies' safety logic to be identical — a workspace-only branch is
# exactly the drift that gate exists to catch.
#
# So what separates "Aaron/Jan/Nick self-approve on the operations agent" from
# "they self-approve on every agent" is the ABSENCE of
# tier2-godmode-allowlist.txt from the canonical skill's config/ directory.
#
# SCOPE OF THAT CLAIM -- be precise, because an over-claim here is its own bug.
# It holds for the DEPLOYED configuration: the path the script resolves by
# default. It is NOT a sandbox. `TIER2_GODMODE_PATH` is an env override (so are
# TIER2_APPROVERS_PATH, BULK_DESTRUCTIVE_PATH and BULK_DESTRUCTIVE_THRESHOLD),
# so a caller who controls the wrapper's environment can point it at any file.
# That is a property of every control in muso-admin-api.sh and predates this
# gate: on the pre-2026-08-26 script, `BULK_DESTRUCTIVE_THRESHOLD=999999`
# already disabled the bulk gate outright, for every requester, with no
# allowlist involved -- a strictly stronger bypass than pointing this one path
# somewhere else. Closing the env-override class is a separate hardening that
# has to cover all of those knobs at once; it is deliberately not attempted
# here. What this gate owns is the shipped tree, and a self-approve now records
# `godmode_allowlist` in its audit row so a foreign path is visible after the
# fact rather than looking routine.
# deploy.sh rsyncs skills-all/*/config/ to every profile's managed-skills dir,
# so a single stray file there would silently hand god-mode to ceo, cmo, cto
# and caroline.
#
# Before the branch was ported, that protection was implicit: the canonical
# script had no god-mode code, so the file would have been inert. It is not
# inert any more, which is precisely why the invariant needs a gate instead of
# a comment. Prose is not enforcement.
#
# `is_tier2_godmode_requester` fail-closes on a missing file (asserted by
# bulk-destructive.bats "missing god-mode allowlist file collapses jan back to
# the approver path"), so absence is a safe default — this script's job is to
# keep it absent.
#
# Exit: 0 clean / 1 the file exists where it must not / 2 usage or repo error.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CANONICAL_CONFIG_DIR="${ROOT}/skills-all/muso-ops-admin/config"
FORBIDDEN="${CANONICAL_CONFIG_DIR}/tier2-godmode-allowlist.txt"
REQUIRED="${ROOT}/workspaces/operations/skills/muso-ops-admin/config/tier2-godmode-allowlist.txt"

[[ -d "$CANONICAL_CONFIG_DIR" ]] || {
    echo "FATAL: canonical config dir not found: ${CANONICAL_CONFIG_DIR#"$ROOT"/}" >&2
    echo "       This gate cannot prove anything against a missing tree." >&2
    exit 2
}

rc=0

# -e FOLLOWS the link, so a DANGLING symlink here reads as "absent" — and a
# dangling link is not harmless: it becomes live the moment anything creates its
# target (a deploy, a restore, a careless mkdir). Test the link itself too.
if [[ -e "$FORBIDDEN" || -L "$FORBIDDEN" ]]; then
    cat >&2 <<EOF
FAIL: ${FORBIDDEN#"$ROOT"/} exists.

This file grants god-mode self-approval on the bulk-destructive DELETE gate.
It must live ONLY in workspaces/operations/skills/muso-ops-admin/config/.

deploy.sh rsyncs skills-all/*/config/ into EVERY agent's managed-skills dir, so
shipping it here hands ceo, cmo, cto and caroline the ability to self-approve
mass deletions with no second human. Delete it; if the operations agent needs a
roster change, edit the workspace copy instead.
EOF
    rc=1
fi

# The workspace copy is what makes the operations agent work. Its ABSENCE is not
# a security problem (the gate fail-closes), but it silently reverts Jan/Aaron/
# Nick to needing --confirmed-by, which looks like a regression rather than a
# deletion. Report it as a distinct, loud failure so it is never mistaken for
# the forbidden-file case above.
if [[ ! -f "$REQUIRED" ]]; then
    cat >&2 <<EOF
FAIL: ${REQUIRED#"$ROOT"/} is missing.

The operations agent needs this file for Aaron/Jan/Nick to self-approve bulk
destructive DELETEs. Without it the gate fail-closes and they are silently back
to needing a second human's --confirmed-by.
EOF
    rc=1
fi

# The checkout is not the deployed tree. deploy.sh deliberately PRESERVES a
# server-only canonical tier2-godmode-allowlist.txt (it exists on node-8 at
# /opt/hydra/skills-all/muso-ops-admin/config/ with aaron/jan/nick in it), so
# "absent from skills-all/ in git" never proved "absent at runtime" -- this gate
# would stay green while the deployed canonical script picked that file up.
#
# The canonical copy therefore defaults TIER2_GODMODE_PATH to a path that cannot
# exist, making its god-mode branch inert by construction. Pin that here: if
# someone re-points the default at ../config/, the server file becomes live for
# every canonical caller (including the support skills that exec this script
# directly) and no amount of checkout-scanning would notice.
CANONICAL_SCRIPT="${ROOT}/skills-all/muso-ops-admin/scripts/muso-admin-api.sh"
if [[ ! -f "$CANONICAL_SCRIPT" ]]; then
    echo "FATAL: canonical script not found: ${CANONICAL_SCRIPT#"$ROOT"/}" >&2
    exit 2
fi
PINNED_GODMODE_PATH='TIER2_GODMODE_PATH="/nonexistent/canonical-copy-has-no-god-mode"'
mapfile -t _godmode_assignments < <(grep -E '^TIER2_GODMODE_PATH=' "$CANONICAL_SCRIPT" || true)
canonical_default="${_godmode_assignments[0]-}"

# More than one assignment is a bypass, not a style problem: the LAST one wins at
# runtime, so a pinned line followed by an overridable one reads as pinned to a
# parser that only inspects the first (or as mixed to one that concatenates).
# Require exactly one, and require it to be the pinned literal.
if (( ${#_godmode_assignments[@]} > 1 )); then
    cat >&2 <<EOF
FAIL: ${CANONICAL_SCRIPT#"$ROOT"/} assigns TIER2_GODMODE_PATH ${#_godmode_assignments[@]} times:
$(printf '    %s\n' "${_godmode_assignments[@]}")

The last assignment is the one that takes effect, so a second line silently
overrides the pin. Keep exactly one.
EOF
    rc=1
elif [[ -z "$canonical_default" ]]; then
    echo "FAIL: ${CANONICAL_SCRIPT#"$ROOT"/} has no TIER2_GODMODE_PATH default to pin." >&2
    echo "      The canonical copy must define one, and it must be an impossible path." >&2
    rc=1
elif [[ "$canonical_default" == *'${TIER2_GODMODE_PATH'* ]]; then
    cat >&2 <<EOF
FAIL: the canonical copy accepts an environment override for TIER2_GODMODE_PATH:
    ${canonical_default}

That lets any caller point this copy at a real allowlist and enter the
self-approve branch -- on the very script the support skills exec directly.
Assign the impossible path outright, with no \${VAR:-default} indirection.
EOF
    rc=1
elif [[ "$canonical_default" == *'/config/'* || "$canonical_default" == *'SCRIPT_DIR'* ]]; then
    cat >&2 <<EOF
FAIL: the canonical copy resolves TIER2_GODMODE_PATH into a real config directory:
    ${canonical_default}

That makes its god-mode self-approve branch live wherever an allowlist happens to
sit next to the deployed script -- and deploy.sh preserves exactly such a
server-only file. Point it at an impossible path instead; the branch must be
inert on this copy by construction, not by the absence of a file this gate
cannot see.
EOF
    rc=1
elif [[ "$canonical_default" != "$PINNED_GODMODE_PATH" ]]; then
    # Catch-all, deliberately last: the checks above give precise diagnostics for
    # the shapes we have actually seen. Anything else that is not byte-identical
    # to the pin is still refused rather than assumed benign.
    cat >&2 <<EOF
FAIL: ${CANONICAL_SCRIPT#"$ROOT"/} does not carry the pinned god-mode path.
    expected: ${PINNED_GODMODE_PATH}
    found:    ${canonical_default}

This copy's self-approve branch must be inert by construction. Anything other
than the impossible path risks resolving onto a real allowlist -- including the
server-only one deploy.sh preserves, which this gate cannot see.
EOF
    rc=1
fi

if (( rc == 0 )); then
    echo "OK: god-mode allowlist is workspace-only (present for operations, absent from the canonical skill)."
fi

exit "$rc"
