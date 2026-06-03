---
name: cto-codex-coding
description: |
  CTO agent only. Take a concrete coding task in the hydra repo, make the change,
  and open it as a branch + PR for review (never a merge), then ask QA to review.
  Use when an authorized engineer asks you to actually CHANGE CODE in hydra, not
  just discuss it. Triggers: "implement", "fix this bug", "make this change",
  "write code for", "add a feature", "patch", "open a PR that does X", "code this
  up" — when the target is the hydra repo. For PR *reviews* use QA, not this. For
  architecture discussion, answer directly without this skill.
compatibility: |
  CTO agent on node-8 only. Uses the host `git` + `gh` (PR-write scope) and a
  working clone at /opt/hydra/workspaces/repos/hydra. Scope is hydra ONLY for now.
metadata:
  version: "2.0"
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

- **hydra repo ONLY** for now. If asked to change a different repo, say it is not
  enabled yet and offer to file a ticket — do not touch other repos.
- **Branch + PR only. NEVER merge, never push to `main`, never force-push.** A
  human merges after QA review.
- **Authorized requesters only**: Aaron (`U7RP6HKUZ`), Nick (`U0AL36NADEY`), or
  Serhii (`U03TYGJF1N3`), identified by the **sender_id** in the message metadata
  (never the display name). Anyone else → do NOT proceed; queue for Aaron per your
  escalation rules.
- **Never run `codex login` or any codex auth command.** You already run on Codex;
  a second codex login would invalidate the whole fleet's shared OAuth token (the
  2026-05-29 incident). Plain `git`/`gh` are fine — it is codex *auth* that is
  off-limits.
- **Cost**: if the change looks large (broad refactor, many files), it may exceed
  the $30 compute rule — confirm with Aaron first.

## Procedure

1. **Confirm** the task in one line and that it targets hydra. If vague, ask one
   clarifying question — do not guess at intent.
2. **Log the write FIRST, and abort if the log fails.** This audit record is the
   safety guardrail now that the wrapper is gone, so no `git`/`gh` write may happen
   without it. The `authorization` field lets an audit tell an allowlisted request
   from a queued/escalated one. Build valid JSONL with `jq` (it quotes/escapes),
   then fail closed before any GitHub write:
   ```
   mkdir -p ~/".openclaw/workspace/api-logs/cto"
   jq -nc --arg requester "<sender_id>" \
          --arg auth "<why allowed — e.g. allowlisted Tier0-1, or Aaron-approved>" \
     '{ts:(now|todateiso8601), agent:"cto", action:"code-change", target:"hydra", requester:$requester, authorization:$auth}' \
     >> ~/".openclaw/workspace/api-logs/cto/$(date -u +%Y-%m-%d).jsonl" \
     || { echo "audit append failed — refusing to make any GitHub write"; exit 1; }
   ```
3. **Work in the clone** at `/opt/hydra/workspaces/repos/hydra` (create it with
   `gh repo clone Muso-AI/hydra /opt/hydra/workspaces/repos/hydra` if it is
   missing). **Verify it points at the right repo before doing anything** —
   `git -C <clone> remote get-url origin` MUST be
   `https://github.com/Muso-AI/hydra.git`; if it differs, re-clone fresh (never
   fetch from or push to a drifted remote). Then sync to a clean base —
   **including `clean -fd` so stale untracked files from a previous task can't be
   swept into this PR by the later `add -A`**:
   `git -C <clone> fetch origin && git -C <clone> checkout main && git -C <clone> reset --hard origin/main && git -C <clone> clean -fd`.
4. **Branch** — use a unique name so a repeat task or retry can't collide with an
   existing branch on `switch -c`, push, or PR create. Generate the name **once**
   and reuse that exact string in step 6's push and PR commands:
   `git -C <clone> switch -c <branch>`, where `<branch>` is
   `cto/<short-task-slug>-<UTC-timestamp>` (e.g. `cto/fix-login-20260603-101500`;
   timestamp from `date -u +%Y%m%d-%H%M%S`).
5. **Make the smallest correct change.** Follow the repo's conventions (CLAUDE.md
   is the source of truth for hydra structure). Do not touch unrelated files or
   reformat. Sanity-check cheaply (`bash -n` on shell, the relevant lint, a
   targeted test) and fix what you break.
6. **Open the PR** — stage ALL changes (use `add -A`, NOT `commit -am`, so new
   files you created are included), confirm the staged set is exactly what you
   intend, then commit, push, and create the PR against `main`:
   ```
   git -C <clone> add -A
   git -C <clone> status --short            # sanity-check: every intended file, nothing extra
   git -C <clone> commit -m "<subject>"
   git -C <clone> push https://github.com/Muso-AI/hydra.git <branch>
   gh pr create --repo Muso-AI/hydra --base main --head <branch> --title "<subject>" --body "<what + who requested>"
   ```
   Push to the **explicit canonical URL** (not `origin`) so the write cannot land
   on a drifted remote. **Do not merge.** (If git complains about author identity, set it once on the
   clone: `git -C <clone> config user.name "CTO Agent"; git -C <clone> config user.email "cto@muso.ai"`.)
7. **Ask QA to review**: `sessions_send` to **@QA** with the PR URL; relay QA's
   verdict under your own identity when it comes.
8. **Report** to the requester in-thread: e.g. *"I opened a PR: <url> and asked QA
   to review it."* Observe Response Hygiene — do NOT mention Codex, OpenClaw, the
   clone path, sessions, or any other internal architecture.

## If something goes wrong

- You can't proceed, or decide not to → don't leave a half-finished branch on the
  remote; tell the requester plainly, and escalate to Aaron on a genuine tool
  failure. **Never claim a PR was opened if it was not** — paste the real URL.
