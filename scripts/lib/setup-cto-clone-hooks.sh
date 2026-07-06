#!/usr/bin/env bash
# setup-cto-clone-hooks.sh — arm the CTO push-audit guard for ALL of CTO's repo
# clones, out-of-band and independent of the `cto-codex-coding` skill ever having
# run. Idempotent. Invoked at deploy time from install-aux-units.sh, as the user
# the gateway runs as (root, HOME=/root on node-8).
#
# WHY out-of-band: a per-clone hook install (inside cto-codex-coding) can't close
# the bypass it's meant to — the standalone `fix`/`ship` skills are what might run
# *instead of* cto-codex-coding, so a fresh/unarmed clone would have no hook (QA
# raised exactly this on PR #582). Arming here, at deploy time, covers every clone
# before any skill runs.
#
# MECHANISM: a directory-scoped git hooksPath. We add an `includeIf "gitdir:DIR/"`
# stanza to the user's gitconfig that points any repo whose .git lives under
# /opt/hydra/workspaces/repos/ at a shared hooks dir holding the pre-push guard.
# git re-reads config on every operation, so EVERY clone in that dir — however and
# whenever created, whichever skill (`fix`/`ship`/`cto-codex-coding`/hand) runs the
# push — is covered, with no per-clone step. Repos outside that dir are untouched.
set -euo pipefail

REPOS_DIR="${CTO_REPOS_DIR:-/opt/hydra/workspaces/repos}"
HOOKS_DIR="${CTO_HOOKS_DIR:-/opt/hydra/scripts/lib/cto-git-hooks}"
GUARD_SRC="${CTO_GUARD_SRC:-/opt/hydra/scripts/lib/cto-push-audit-guard.sh}"
GITCONFIG="${CTO_GITCONFIG:-${HOME}/.gitconfig}"
HOOKS_GITCONFIG="${CTO_HOOKS_GITCONFIG:-/opt/hydra/.cto-clone-hooks.gitconfig}"

[ -f "$GUARD_SRC" ] || { echo "setup-cto-clone-hooks: guard not found at $GUARD_SRC" >&2; exit 1; }

# 1. Shared hooks dir: pre-push -> the guard.
mkdir -p "$HOOKS_DIR"
install -m 755 "$GUARD_SRC" "$HOOKS_DIR/pre-push"

# 2. The included config that points clones at that hooks dir (kept in its own
#    file so the includeIf stanza in the user gitconfig stays a tidy 2-liner).
cat > "$HOOKS_GITCONFIG" <<EOF
# Managed by scripts/lib/setup-cto-clone-hooks.sh — do not edit by hand.
[core]
	hooksPath = $HOOKS_DIR
EOF

# 3. includeIf stanza in the user gitconfig (idempotent — keyed on the gitdir
#    line). The trailing slash makes git match the directory's whole subtree.
mkdir -p "$(dirname "$GITCONFIG")"
touch "$GITCONFIG"
if ! grep -qF "gitdir:$REPOS_DIR/" "$GITCONFIG"; then
  cat >> "$GITCONFIG" <<EOF

[includeIf "gitdir:$REPOS_DIR/"]
	path = $HOOKS_GITCONFIG
EOF
fi

echo "✓ CTO clone push-audit guard armed: gitdir:$REPOS_DIR/ -> hooksPath $HOOKS_DIR"
