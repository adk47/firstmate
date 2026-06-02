#!/usr/bin/env bash
# codex-delegate.sh — the gated git/PR plumbing that lets the CTO agent offload a
# coding task to Codex and ship the result as a branch + PR (never a merge).
#
# ── What this is, and what it deliberately is NOT ────────────────────────────
# The CTO openclaw agent already RUNS on Codex (openai/gpt-5.5 via the codex
# agentRuntime). So "offload a coding task to Codex" needs no second Codex
# process: the agent itself, with its `exec` (security:full) tool, edits the
# code in a working tree. This script is the deterministic, AUDITED, GATED
# boundary around that — it prepares a clean branch, then (after the agent has
# edited the tree) commits, pushes, and opens the PR. The LLM only writes code;
# git/gh mechanics are this script's job.
#
# THIS SCRIPT NEVER INVOKES `codex`. That is a hard, load-bearing safety
# property, not an accident:
#   Codex (ChatGPT OAuth) auth uses single-use rotating refresh tokens stored in
#   openclaw's auth-profiles.json and bridged to the harness at spawn time. A
#   SECOND, independent codex auth consumer (`codex login` / a bash-invoked
#   `codex exec` that materializes its own ~/.codex/auth.json) would refresh that
#   token out-of-band and mutually-invalidate the WHOLE fleet's codex auth — the
#   2026-05-29 incident that degraded 6 agents to Sonnet fallback for hours.
#   We sidestep it entirely: the only codex auth consumer stays the openclaw
#   harness. This script touches git + gh only. The arg guard below refuses any
#   `codex login`-shaped argument as belt-and-suspenders.
# See CLAUDE.md "Codex / OAuth auth is centralized" and scripts/lib/ensure-codex-auth.sh.
#
# ── Gates (mechanical, not prose — enforced here, at the bash boundary) ──────
#   1. repo allowlist        — v1 ships hydra ONLY (REPO_MAP below).
#   2. requester allowlist   — only Aaron / Nick / Serhii (Slack UIDs) may trigger
#                              a code change; the agent passes the trusted
#                              sender_id as --requester. Unknown => refuse (exit 1).
#   3. auth-health canary    — ensure-codex-auth.sh --check must pass (the fleet's
#                              shared OAuth symlink topology is intact) or we abort:
#                              if auth is broken the agent can't code well anyway,
#                              and we want it surfaced loudly.
#   4. branch + PR only      — base branch is pristine origin/<base>; we never
#                              commit to or force-push the base, and never merge.
#
# ── Subcommands ──────────────────────────────────────────────────────────────
#   prepare  --repo R --requester UID --task "DESC"
#       Validate gates; ensure a clean clone exists; reset hard to origin/<base>;
#       cut a fresh branch codex/cto/<slug>-<UTCstamp>; record a marker. Prints
#       machine-parseable CLONE=, BRANCH=, BASE= lines. The agent then edits code
#       in CLONE.
#   finalize --repo R --requester UID --task "DESC" [--ticket ID]
#       Validate gates + marker + that a diff exists; commit (message authored
#       HERE, not by the LLM); write a FAIL-CLOSED audit entry BEFORE the first
#       remote write (abort if it can't be persisted); push; `gh pr create`.
#       Prints PR_URL=.
#   abort    --repo R
#       Discard the working branch and return the clone to origin/<base>
#       (for when the agent decides not to proceed). Best-effort.
#
# ── Exit codes (repo guard convention) ───────────────────────────────────────
#   0 ok · 1 gate/validation refusal · 2 operational error (git/gh/clone failed)
#
# ── No production knobs. Constants are hardcoded; tests source-and-inject ─────
# This script is a mechanical boundary an exec-capable agent must not route
# around, so it reads NO environment for policy or paths in production: there is
# nothing to forge via env/args/cwd, and copying the script elsewhere changes
# nothing (the constants are literals). The CTO agent and the self-hosted CI
# runner BOTH run as root on node-8, so no host/uid/path signal can safely
# distinguish "CI" from "a copied script run by the agent" — hence we expose no
# unlock at all. Tests instead `source` this file (main is guarded below so it
# does not run on source) and override the plain shell vars in their own shell;
# production NEVER sources, so that injection path is unreachable for the agent.
# (A fully exec-compromised agent could of course call git/gh directly, or source
# this and call the functions — containing that is openclaw's exec layer, not
# this script's. What we refuse is offering a trivial documented bypass knob.)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REQUESTERS="U7RP6HKUZ U0AL36NADEY U03TYGJF1N3"   # Aaron · Nick · Serhii (slack-people.json)
REPOS_ROOT="/opt/hydra/workspaces/repos"
AUDIT_LOG="/opt/hydra/workspaces/cto/api-logs/codex-delegate.jsonl"
AUTH_CHECK_CMD="$SCRIPT_DIR/lib/ensure-codex-auth.sh --check"
# Canonical remote base. The clone's origin must equal "$GITHUB_REMOTE_BASE/$SLUG.git"
# EXACTLY (host + owner/repo), and finalize pushes to that explicit URL — never to
# a (possibly drifted/same-slug-wrong-host) `origin`. Hardcoded; the bats suite
# source-injects a sandbox base (a local bare repo), just like the paths above.
GITHUB_REMOTE_BASE="https://github.com"

# Allowlisted repos. v1: hydra ONLY. Add a case branch in resolve_repo() to widen.
REPO_ALLOWLIST="hydra"

log()  { printf '[codex-delegate] %s\n' "$*" >&2; }
die()  { log "ERROR: $*"; exit "${2:-2}"; }
refuse(){ log "REFUSED: $*"; exit 1; }

# JSONL audit. _audit_json builds the line; audit() is best-effort (for events
# that precede no external write); audit_strict() is FAIL-CLOSED and MUST be the
# gate before any remote write (push / PR) — if it can't durably record the
# attempt, we refuse the external write rather than write with no audit trail.
_audit_json() { # event repo requester extra -> stdout
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"ts":"%s","agent":"cto","action":"codex-delegate","event":"%s","repo":"%s","requester":"%s"%s}\n' \
    "$ts" "$1" "$2" "$3" "${4:+,$4}"
}
audit() {        # best-effort — never fails the run
  mkdir -p "$(dirname "$AUDIT_LOG")" 2>/dev/null || return 0
  _audit_json "$@" >>"$AUDIT_LOG" 2>/dev/null || true
}
audit_strict() { # fail-closed — abort (exit 2) if the audit can't be persisted
  mkdir -p "$(dirname "$AUDIT_LOG")" \
    || die "cannot create audit dir for $AUDIT_LOG — refusing an external write with no audit trail" 2
  _audit_json "$@" >>"$AUDIT_LOG" \
    || die "cannot append to audit log $AUDIT_LOG — refusing an external write with no audit trail" 2
}

# Refuse any codex-login-shaped token anywhere in argv. We never call codex, but
# this makes "someone wired this to run codex auth" impossible by construction.
guard_no_codex_auth() {
  local a
  for a in "$@"; do
    case "$a" in
      *codex*login*|*--with-api-key*|*--device-auth*|*--with-access-token*)
        refuse "this script must never perform codex auth (arg: '$a') — see header" ;;
    esac
  done
}

slugify() { # task desc -> safe branch slug, max 40 chars
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-40 | sed -E 's/-+$//'
}

resolve_repo() { # sets SLUG, BASE, CLONE, EXPECTED_REMOTE; refuses unknown repo
  local key="$1"
  case "$key" in
    hydra) SLUG="Muso-AI/hydra"; BASE="main";;
    *) refuse "repo '$key' is not in the allowlist ($REPO_ALLOWLIST)";;
  esac
  CLONE="$REPOS_ROOT/$key"
  EXPECTED_REMOTE="$GITHUB_REMOTE_BASE/$SLUG.git"
}

check_requester() {
  local uid="$1"
  [[ -n "$uid" ]] || refuse "missing --requester (the triggering Slack user id)"
  local ok
  for ok in $REQUESTERS; do [[ "$uid" == "$ok" ]] && return 0; done
  refuse "requester '$uid' is not authorized to trigger a code change (Aaron/Nick/Serhii only)"
}

auth_canary() {
  # ensure-codex-auth.sh --check: 0 clean / 1 fan-out violation / 2 error.
  if ! $AUTH_CHECK_CMD; then
    die "codex auth health check failed ($AUTH_CHECK_CMD) — refusing to proceed; the fleet's shared OAuth store may be compromised" 2
  fi
}

# True iff the clone's `origin` is EXACTLY the canonical remote — full URL, so a
# same-slug remote on a different host/path (git@evil:Muso-AI/hydra.git) is NOT
# trusted (comparing owner/repo alone would wrongly accept it).
origin_is_canonical() {
  [[ "$(git -C "$CLONE" remote get-url origin 2>/dev/null || echo "")" == "$EXPECTED_REMOTE" ]]
}

ensure_clone() { # idempotent: clone if missing; recreate if origin has DRIFTED
  # A persistent clone whose `origin` was repointed elsewhere would let prepare
  # fetch/reset from the wrong repo. So we never trust an existing clone's remote:
  # if origin is not the canonical URL we discard and re-clone (the clone is pure
  # scratch — prepare hard-resets it anyway — so recreating is safe).
  if [[ -d "$CLONE/.git" ]] && ! origin_is_canonical; then
    log "clone origin != $EXPECTED_REMOTE (drift) — discarding and re-cloning"
    rm -rf "$CLONE"
  fi
  if [[ ! -d "$CLONE/.git" ]]; then
    log "cloning $SLUG into $CLONE"
    mkdir -p "$REPOS_ROOT"
    gh repo clone "$SLUG" "$CLONE" -- --quiet || die "gh repo clone $SLUG failed" 2
    git -C "$CLONE" remote set-url origin "$EXPECTED_REMOTE"   # pin origin to canonical
  fi
}

marker_path() { printf '%s/.git/codex-delegate.json' "$CLONE"; }

cmd_prepare() {
  guard_no_codex_auth "$@"
  local repo="" requester="" task=""
  while [[ $# -gt 0 ]]; do case "$1" in
    --repo) repo="$2"; shift 2;; --requester) requester="$2"; shift 2;;
    --task) task="$2"; shift 2;; *) die "prepare: unknown arg '$1'" 2;; esac; done
  [[ -n "$task" ]] || die "prepare: --task is required" 2
  resolve_repo "$repo"; check_requester "$requester"; auth_canary

  ensure_clone
  log "syncing $CLONE to origin/$BASE"
  git -C "$CLONE" fetch origin --prune --quiet || die "git fetch failed" 2
  git -C "$CLONE" checkout --quiet "$BASE" 2>/dev/null || git -C "$CLONE" checkout --quiet -B "$BASE" "origin/$BASE"
  git -C "$CLONE" reset --hard "origin/$BASE" --quiet || die "git reset failed" 2
  git -C "$CLONE" clean -fd --quiet || true

  local branch; branch="codex/cto/$(slugify "$task")-$(date -u +%Y%m%d-%H%M%S)"
  git -C "$CLONE" switch -C "$branch" --quiet || die "git switch -C $branch failed" 2

  # Marker lives INSIDE .git so it is never committed; finalize validates against it.
  local mp; mp="$(marker_path)"
  printf '{"branch":"%s","base":"%s","repo":"%s","requester":"%s","task":%s}\n' \
    "$branch" "$BASE" "$repo" "$requester" "$(json_str "$task")" >"$mp"
  audit "prepare" "$repo" "$requester" "\"branch\":\"$branch\""

  log "ready — edit code in CLONE, then run: codex-delegate.sh finalize --repo $repo --requester $requester --task ..."
  printf 'CLONE=%s\nBRANCH=%s\nBASE=%s\n' "$CLONE" "$branch" "$BASE"
}

cmd_finalize() {
  guard_no_codex_auth "$@"
  local repo="" requester="" task="" ticket=""
  while [[ $# -gt 0 ]]; do case "$1" in
    --repo) repo="$2"; shift 2;; --requester) requester="$2"; shift 2;;
    --task) task="$2"; shift 2;; --ticket) ticket="$2"; shift 2;;
    *) die "finalize: unknown arg '$1'" 2;; esac; done
  [[ -n "$task" ]] || die "finalize: --task is required" 2
  resolve_repo "$repo"; check_requester "$requester"; auth_canary

  [[ -d "$CLONE/.git" ]] || die "no clone at $CLONE — run prepare first" 2
  local mp branch; mp="$(marker_path)"
  [[ -f "$mp" ]] || die "no prepare marker at $mp — run prepare first" 2
  branch="$(sed -E 's/.*"branch":"([^"]+)".*/\1/' "$mp")"
  local cur; cur="$(git -C "$CLONE" rev-parse --abbrev-ref HEAD)"
  [[ "$cur" == "$branch" ]] || die "clone is on '$cur', expected prepared branch '$branch'" 2

  local subject body
  subject="$(printf '%s' "$task" | head -c 72)"
  body="Coding task delegated to the CTO agent (Codex / gpt-5.5).

Requested by: $requester${ticket:+ (ticket: $ticket)}
Task: $task

Opened by codex-delegate.sh as a branch + PR for review. Not merged."

  # Resumable. Commit pending edits if any. If the tree is clean but a prepared
  # commit already exists (HEAD ahead of base), a prior run committed but push/PR
  # failed transiently — resume straight to (re)push + PR. Only a clean tree still
  # AT base is genuinely "no changes".
  local has_commit="no"
  [[ "$(git -C "$CLONE" rev-parse HEAD)" != "$(git -C "$CLONE" rev-parse "$BASE")" ]] && has_commit="yes"
  if [[ -n "$(git -C "$CLONE" status --porcelain)" ]]; then
    git -C "$CLONE" add -A
    git -C "$CLONE" -c user.name="CTO Agent" -c user.email="cto@muso.ai" \
      commit --quiet -m "$subject" -m "$body" || die "git commit failed" 2
    has_commit="yes"
  elif [[ "$has_commit" == "no" ]]; then
    audit "finalize-nochanges" "$repo" "$requester" "\"branch\":\"$branch\""
    refuse "no changes in the working tree — nothing to ship (did the edit step run?)"
  fi

  # FAIL-CLOSED audit BEFORE the first remote write (push). If this can't be
  # durably recorded we abort here — no external write ever happens without an
  # audit trail (cto SOUL.md: log every external write BEFORE execution).
  audit_strict "finalize-push" "$repo" "$requester" "\"branch\":\"$branch\""

  # Push to the EXPLICIT canonical remote, never to `origin` — origin could have
  # drifted to a same-slug wrong host, and we must not write outside Muso-AI/hydra.
  # Idempotent: re-pushing an already-pushed branch is a no-op ("up to date").
  git -C "$CLONE" push "$EXPECTED_REMOTE" "refs/heads/$branch:refs/heads/$branch" --quiet \
    || die "git push failed" 2

  # Resumable PR: reuse an open PR for this branch if a prior run already created
  # one; otherwise create it. Avoids the "PR already exists" failure on retry.
  local pr_url
  pr_url="$(gh pr list --repo "$SLUG" --head "$branch" --state open --json url -q '.[0].url // empty' 2>/dev/null || true)"
  if [[ -z "$pr_url" ]]; then
    pr_url="$(gh pr create --repo "$SLUG" --base "$BASE" --head "$branch" \
              --title "$subject" --body "$body" 2>&1)" \
      || die "gh pr create failed: $pr_url" 2
  fi
  # Post-success enrichment (best-effort): the durable record already exists above.
  audit "finalize" "$repo" "$requester" "\"branch\":\"$branch\",\"pr\":\"$pr_url\""
  rm -f "$mp" 2>/dev/null || true

  log "PR opened: $pr_url"
  printf 'PR_URL=%s\n' "$pr_url"
}

cmd_abort() {
  local repo=""
  while [[ $# -gt 0 ]]; do case "$1" in
    --repo) repo="$2"; shift 2;; *) shift;; esac; done
  resolve_repo "$repo"
  [[ -d "$CLONE/.git" ]] || { log "nothing to abort"; return 0; }
  local branch; branch="$(git -C "$CLONE" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  git -C "$CLONE" checkout --quiet "$BASE" 2>/dev/null || true
  git -C "$CLONE" reset --hard "origin/$BASE" --quiet 2>/dev/null || true
  [[ -n "$branch" && "$branch" != "$BASE" ]] && git -C "$CLONE" branch -D "$branch" --quiet 2>/dev/null || true
  rm -f "$(marker_path)" 2>/dev/null || true
  log "aborted — $CLONE returned to origin/$BASE"
}

# minimal JSON string escaper for the marker file
json_str() { printf '"%s"' "$(printf '%s' "$1" | sed -E 's/\\/\\\\/g; s/"/\\"/g')"; }

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    prepare)  cmd_prepare  "$@";;
    finalize) cmd_finalize "$@";;
    abort)    cmd_abort    "$@";;
    *) cat >&2 <<USAGE
usage: codex-delegate.sh <prepare|finalize|abort> --repo <key> --requester <slack-uid> --task "<desc>" [--ticket <id>]
  v1 repos: ${REPO_ALLOWLIST}
USAGE
       exit 2;;
  esac
}

# Run only when EXECUTED, not when sourced by the bats suite (which calls the
# cmd_* functions directly after overriding the path vars in its own shell).
# Strict mode lives here so it applies to a real invocation but does not leak
# into a sourcing test shell.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  main "$@"
fi
