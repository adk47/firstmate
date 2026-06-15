---
name: cto-codex-coding
description: |
  CTO agent only. Take a concrete coding task in ANY Muso-AI repo, make the
  change, and open it as a branch + PR for review (never a merge), then ask QA to
  review. Use when an authorized engineer asks you to actually CHANGE CODE — not
  just discuss it. Triggers: "implement", "fix this bug", "make this change",
  "write code for", "add a feature", "patch", "open a PR that does X", "code this
  up". For PR *reviews* use QA, not this. For architecture discussion, answer
  directly without this skill.
compatibility: |
  CTO agent on node-8 only. Uses the host `git` + `gh` (PR-write scope) and a
  per-repo working clone under /opt/hydra/workspaces/repos/<repo>. Scope is ANY
  Muso-AI repo you have push access to; the procedure verifies that access and
  the repo's real default branch at runtime, and fails loud if you can't push.
metadata:
  version: "3.0"
  source-repo: "Muso-AI/hydra"
allowed-tools:
  - exec
---

# cto-codex-coding

You ARE Codex (gpt-5.5), so you do the coding directly — read files, make the
change, and ship it as a **branch + PR** that QA and a human review before any
merge. There is no special wrapper or tool: just your shell (`exec`), `git`, and
`gh`. The safety net is that everything ends as a reviewed PR you never merge.

## Hard rules

- **Any Muso-AI repo you have push access to.** Not just hydra. The procedure
  below verifies push access and the repo's real default branch first — if you
  can't push to the target repo, you stop at a diagnosis + ticket and say so;
  you do NOT pretend a PR was opened.
- **Branch + PR only. NEVER merge, NEVER push to a default branch
  (`main`/`master`/`develop`), never force-push.** A human merges after QA
  review. This rail holds for everyone, god-mode requesters included.
- **Right repo, right base.** Determine the base branch at runtime from the repo
  itself (`gh repo view ... defaultBranchRef`) — never assume `main`. Muso repos
  differ: core-backend / web-credits use `develop`, customer-api-mcp uses
  `master`, hydra uses `main`.
- **Requesters**: god-mode requesters — Nick (`U0AL36NADEY`) or Aaron
  (`U7RP6HKUZ`) — proceed with no approval. Other authorized engineers (e.g.
  Serhii `U03TYGJF1N3`) follow the normal queue/approval path. Identify by the
  **sender_id** in the message metadata (never the display name). Anyone else →
  do NOT proceed; queue per your escalation rules.
- **Never run `codex login` or any codex auth command.** You already run on Codex;
  a second codex login would invalidate the whole fleet's shared OAuth token (the
  2026-05-29 incident). Plain `git`/`gh` are fine — it is codex *auth* that is
  off-limits.
- **Cost**: if the change looks large (broad refactor, many files), it may exceed
  the $30 compute rule — confirm with an approver first, UNLESS the requester is
  god-mode (Nick/Aaron), who need no cost approval.

## Procedure

> **Run steps 2–7 as ONE continuous shell session** so the variables set in step
> 2 (`repo`, `name`, `clone`, `base`, and later `branch`) persist. Shell state
> does NOT survive across separate `exec` calls — if you must split the work,
> re-derive those variables at the top of each block. The non-empty guards below
> make a lost variable fail LOUD: without them a blank `$repo` would write a
> `target:""` audit row (jq still exits 0) and degrade the push to a malformed
> `https://github.com/.git`.

1. **Confirm** the task in one line and **which repo** it targets. If vague, ask
   one clarifying question — do not guess at intent or at the repo.

2. **Set the target and verify you can push BEFORE touching anything.** Resolve
   the repo to `Muso-AI/<name>`, then fail closed if you lack push access or the
   default branch can't be read:
   ```
   repo="Muso-AI/<name>"            # e.g. Muso-AI/core-backend
   name="${repo#*/}"
   clone="/opt/hydra/workspaces/repos/$name"

   # one API call for both fields
   info=$(gh repo view "$repo" --json viewerPermission,defaultBranchRef) || {
     echo "cannot read $repo via gh — refusing to proceed"; exit 1; }
   perm=$(echo "$info" | jq -r '.viewerPermission')
   base=$(echo "$info" | jq -r '.defaultBranchRef.name')
   case "$perm" in
     ADMIN|MAINTAIN|WRITE) : ;;
     *) echo "No push access to $repo (viewerPermission=$perm). Stopping at diagnosis + ticket — NOT opening a PR."; exit 1 ;;
   esac
   [ -n "$base" ] && [ "$base" != "null" ] || { echo "could not resolve default branch for $repo"; exit 1; }
   ```

3. **Log the write FIRST, and abort if the log fails.** This audit record is the
   safety guardrail now that the wrapper is gone, so no `git`/`gh` write may happen
   without it — this is true even for god-mode requesters (god-mode removes the
   approval gate, not the audit trail). The `authorization` field lets an audit
   tell an allowlisted/god-mode request from a queued/escalated one. Build valid
   JSONL with `jq` (it quotes/escapes), then fail closed before any GitHub write:
   ```
   [ -n "$repo" ] || { echo "no target repo resolved — refusing to write audit or push"; exit 1; }
   mkdir -p ~/".openclaw/workspace/api-logs/cto"
   jq -nc --arg requester "<sender_id>" \
          --arg target "$repo" \
          --arg auth "<why allowed — e.g. god-mode Nick, or Aaron-approved>" \
     '{ts:(now|todateiso8601), agent:"cto", action:"code-change", target:$target, requester:$requester, authorization:$auth}' \
     >> ~/".openclaw/workspace/api-logs/cto/$(date -u +%Y-%m-%d).jsonl" \
     || { echo "audit append failed — refusing to make any GitHub write"; exit 1; }
   ```

4. **Work in the per-repo clone** at `$clone` (create it with
   `gh repo clone "$repo" "$clone"` if it is missing). **Verify it points at the
   right repo before doing anything** — `git -C "$clone" remote get-url origin`
   MUST be `https://github.com/$repo.git`; if it differs, re-clone fresh (never
   fetch from or push to a drifted remote). Then sync to a clean base —
   **including `clean -fd` so stale untracked files from a previous task can't be
   swept into this PR by the later `add -A`**:
   ```
   url=$(git -C "$clone" remote get-url origin 2>/dev/null)
   [ "$url" = "https://github.com/$repo.git" ] || { rm -rf "$clone"; gh repo clone "$repo" "$clone"; }
   git -C "$clone" fetch origin
   git -C "$clone" checkout "$base"
   git -C "$clone" reset --hard "origin/$base"
   git -C "$clone" clean -fd
   ```

5. **Branch** off the base — use a unique name so a repeat task or retry can't
   collide with an existing branch on `switch -c`, push, or PR create. Generate
   the name **once** and reuse that exact string in step 7's push and PR commands:
   `git -C "$clone" switch -c "$branch"`, where `$branch` is
   `cto/<short-task-slug>-<UTC-timestamp>` (e.g. `cto/fix-login-20260615-101500`;
   timestamp from `date -u +%Y%m%d-%H%M%S`).

6. **Make the smallest correct change.** Follow the target repo's own conventions
   (read its CLAUDE.md / AGENTS.md / README first). Do not touch unrelated files or
   reformat. Sanity-check cheaply (`bash -n` on shell, the relevant lint, a
   targeted test) and fix what you break.

7. **Open the PR** — stage ALL changes (use `add -A`, NOT `commit -am`, so new
   files you created are included), confirm the staged set is exactly what you
   intend, then commit, push, and create the PR against the **runtime base**:
   ```
   [ -n "$repo" ] && [ -n "$base" ] && [ -n "$clone" ] && [ -n "$branch" ] || { echo "missing repo/base/clone/branch — refusing to push or open PR"; exit 1; }
   # Fail closed on the "never push to a default branch" rail: $branch must be a
   # fresh cto/ branch, never the base or any default branch — even if shell state
   # got corrupted into branch="$base"/main/master/develop.
   case "$branch" in
     "$base"|main|master|develop) echo "refusing: '$branch' is a default branch — never push a fix to a default branch"; exit 1 ;;
     cto/*) : ;;
     *) echo "refusing: branch '$branch' must be a fresh cto/<slug> branch"; exit 1 ;;
   esac
   git -C "$clone" add -A
   git -C "$clone" status --short            # sanity-check: every intended file, nothing extra
   git -C "$clone" commit -m "<subject>"
   git -C "$clone" push "https://github.com/$repo.git" "$branch"
   gh pr create --repo "$repo" --base "$base" --head "$branch" --title "<subject>" --body "<what + who requested>"
   ```
   Push to the **explicit canonical URL** (not `origin`) so the write cannot land
   on a drifted remote. PR base is `$base` (the repo's real default branch), NOT a
   hardcoded `main`. **Do not merge.** (If git complains about author identity, set
   it once on the clone: `git -C "$clone" config user.name "CTO Agent"; git -C "$clone" config user.email "cto@muso.ai"`.)

8. **Ask QA to review**: `sessions_send` to **@QA** with the PR URL; relay QA's
   verdict under your own identity when it comes.

9. **Report** to the requester in-thread: e.g. *"I opened a PR: <url> and asked QA
   to review it."* Observe Response Hygiene — do NOT mention Codex, OpenClaw, the
   clone path, sessions, or any other internal architecture.

## If something goes wrong

- You can't proceed, or decide not to → don't leave a half-finished branch on the
  remote; tell the requester plainly, and escalate on a genuine tool failure
  (god-mode requesters: report the failure to them, not to Aaron). **Never claim a
  PR was opened if it was not** — paste the real URL. If the only blocker is push
  access (step 2), say so and fall back to a diagnosis + ClickUp ticket for the
  owning team.
