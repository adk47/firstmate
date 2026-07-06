---
name: cto-codex-coding
description: |
  CTO agent only. Take a concrete coding task in ANY Muso-AI repo, make the
  change, then ship it to a green, reviewed branch + PR (never a merge) through
  ship-kit's `ship` pipeline, and ask QA to review. Use when an authorized
  engineer asks you to actually CHANGE CODE — not just discuss it. Triggers:
  "implement", "fix this bug", "make this change", "write code for", "add a
  feature", "patch", "open a PR that does X", "code this up". For PR *reviews* use
  QA, not this. For architecture discussion, answer directly without this skill.
compatibility: |
  CTO agent on node-8 only. Uses the host `git` + `gh` (PR-write scope) and a
  per-repo working clone under /opt/hydra/workspaces/repos/<repo>. Scope is ANY
  Muso-AI repo you have push access to; the procedure verifies that access and
  the repo's real default branch at runtime, and fails loud if you can't push.
metadata:
  version: "4.1"
  source-repo: "Muso-AI/hydra"
allowed-tools:
  - exec
---

# cto-codex-coding

You ARE Codex (gpt-5.5), so you do the coding directly — read files, make the
change, then **ship it through ship-kit's `ship` pipeline** so it lands as a
clean, verified, code-reviewed **branch + PR** that QA and a human review before
any merge. The safety net is twofold: this skill's own rails (verify push access,
audit log, never-merge / never-push-a-default-branch, QA handoff, response
hygiene) wrap everything, and `ship` owns the commit → PR → green core
(simplify → verify → review → commit → PR → babysit). You ALWAYS take a finished
change to a PR via `ship` — never by hand-running `git commit` / `gh pr create`
yourself.

> **What's this skill vs. what's `ship`.** This skill is the hydra-specific
> *wrapper*: it decides the repo, proves you can push, writes the audit row,
> prepares the clone + branch, and makes the change — then hands off to `ship`
> for everything from commit onward, and reports back with QA looped in. `ship`
> never sees the authorization/audit rails; those are yours and they are not
> optional, god-mode requesters included.

## Hard rules

- **Any Muso-AI repo you have push access to.** Not just hydra. The procedure
  below verifies push access and the repo's real default branch first — if you
  can't push to the target repo, you stop at a diagnosis + ticket and say so;
  you do NOT pretend a PR was opened.
- **Branch + PR only. NEVER merge, NEVER push to a default branch
  (`main`/`master`/`develop`), never force-push.** A human merges after QA
  review. This rail holds for everyone, god-mode requesters included.
- **This skill is your ONLY coding ENTRY POINT → `ship`.** ship-kit's `fix` and
  `triage` skills ARE vendored and visible to you (`fix` triggers on "fix this
  bug" / "debug and fix" — the same requests you answer), and so is `ship` — but
  you must **never start a code change by invoking `fix`, `ship`, or `triage`
  directly**. Entered on its own, `fix` cuts a `fix/…` branch and ships
  **without** your audit row, push-access check, `cto/<slug>-<ts>` branch rail, or
  QA handoff. Always enter through *this* skill, which writes the audit row and
  verifies push access FIRST, then hands the change to `ship`. The audit row is an
  **agent-level** rule (SOUL "Write Activity Logging") that binds no matter which
  skill you are in: if you ever find yourself mid-`fix`/`ship` without having
  written it, STOP — write it and re-verify push access before any `git push` or
  PR. **This is mechanically enforced:** a directory-scoped pre-push hook
  (`scripts/lib/cto-push-audit-guard.sh`, armed out-of-band at deploy time by
  `setup-cto-clone-hooks.sh` for every clone under `/opt/hydra/workspaces/repos/`)
  *refuses* any push that lacks a recent audit row for the repo **or** targets a
  non-`cto/` branch (or a default branch) — so a stray `fix`/`ship` entry (no audit
  row, or a `fix/…` branch) is blocked at the git boundary, not merely discouraged
  here.
  The only ship-kit flag you pass is `--yolo` (below); `triage`'s read-only
  diagnosis is fine as an aid, but your primary debugger is `cto-debug`.
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

> **Run steps 2–6 as ONE continuous shell session** so the variables set in step
> 2 (`repo`, `name`, `clone`, `base`, and later `branch`) persist into the `ship`
> hand-off (step 7). Shell state does NOT survive across separate `exec` calls —
> if you must split the work, re-derive those variables at the top of each block.
> The non-empty guards below make a lost variable fail LOUD: without them a blank
> `$repo` would write a `target:""` audit row (jq still exits 0) and leave `ship`
> with no canonical repo/branch/base to commit and push to.

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
   This clone is **already armed** with the push-audit `pre-push` guard — no
   per-clone install is needed (and none would help; see the rail-guard note).
   The deploy-time `scripts/lib/setup-cto-clone-hooks.sh` sets a directory-scoped
   `core.hooksPath` for everything under `/opt/hydra/workspaces/repos/`, so every
   clone here carries the guard no matter which skill created it.

5. **Branch** off the base — use a unique name so a repeat task or retry can't
   collide with an existing branch on `switch -c`, push, or PR create. Generate
   the name **once**; `ship` pushes this exact branch as-is in step 7 (it must
   **not** rename it):
   `git -C "$clone" switch -c "$branch"`, where `$branch` is
   `cto/<short-task-slug>-<UTC-timestamp>` (e.g. `cto/fix-login-20260615-101500`;
   timestamp from `date -u +%Y%m%d-%H%M%S`).

6. **Make the smallest correct change.** Follow the target repo's own conventions
   (read its CLAUDE.md / AGENTS.md / README first). Do not touch unrelated files or
   reformat. A quick `bash -n` on shell is fine, but you don't need to polish or
   exhaustively test here — `ship`'s simplify / verify / code-review stages (step
   7) do that next on the diff. Leave the change uncommitted in the working tree;
   `ship` commits it.

7. **Ship the change through ship-kit (`ship`).** Do NOT hand-run
   `git add`/`commit`/`push` or `gh pr create` yourself — `ship` owns the entire
   commit → PR → green pipeline. First re-assert the rails as a fail-closed
   pre-flight (a corrupted `$branch` must never reach a push), then hand off:
   ```
   [ -n "$repo" ] && [ -n "$base" ] && [ -n "$clone" ] && [ -n "$branch" ] || { echo "missing repo/base/clone/branch — refusing to ship"; exit 1; }
   # "Never push to a default branch" rail — enforce BEFORE ship pushes $branch.
   # $branch must be a fresh cto/ branch, never the base or any default branch,
   # even if shell state got corrupted into branch="$base"/main/master/develop.
   case "$branch" in
     "$base"|main|master|develop) echo "refusing: '$branch' is a default branch — never push a fix to a default branch"; exit 1 ;;
     cto/*) : ;;
     *) echo "refusing: branch '$branch' must be a fresh cto/<slug> branch"; exit 1 ;;
   esac
   git -C "$clone" status --short    # sanity-check: the change is exactly what you intend, nothing stray
   ```
   Then hand the finished working-tree change in `$clone` to the **`ship`** skill,
   which chains simplify → verify → code-review → smart-commit → PR → babysit.
   Invoke it the portable way: if your harness exposes a skill-invocation tool,
   call the `ship` skill; otherwise load `skills-all/ship/SKILL.md` and follow its
   procedure — running it **inside `$clone`** so it operates on this change. Apply
   these hydra overrides (`ship`'s "project conventions override the recipe"
   clause authorizes them — they are how the wrapper's rails survive the hand-off):

   - **Authorization / checkpoint (ship Stage 6) — invoke `ship --yolo`:** your
     steps 2–3 (push-access check + audit row) ARE the authorization, so pass
     ship-kit's `--yolo` flag. It auto-confirms ship's Stage-6 push + PR checkpoint
     (and auto-resumes Stage 0, and lets Stage 10 `reflect` surface without
     blocking) instead of stopping at "staged and waiting" — this is the autonomous
     PR the requester asked for. `--yolo` does **not** authorize merge (see the next
     bullet): it stops at green. So the invocation is `ship --yolo`, never
     `ship --yolo --merge`.
   - **NEVER merge:** do **not** pass `ship --merge`, and never merge yourself.
     `--merge` is `ship`'s standing authorization to squash-merge — it would break
     your one inviolable rail. Stop at *PR open + green*; a human merges.
   - **Branch (ship Stage 5):** the branch is already `cto/<slug>-<ts>` and is
     correct — tell `ship` it already conforms; it must **not** rename it.
     Renaming to `<type>/<slug>` strips the `cto/` marker the rail above keys on.
   - **Push (ship Stage 7):** `ship` pushes `git push -u origin <branch>`. That is
     safe here only because step 4 verified `$clone`'s `origin` is exactly
     `https://github.com/$repo.git` — never skip step 4's remote check. The PR
     base is `$base` (the runtime default branch), never a hardcoded `main`.
   - **Verify (ship Stage 2b):** run the target repo's own cheap test/lint recipe
     where node-8 has the toolchain; where it does NOT (most repos' full suites
     aren't installed on node-8), pass `ship --no-verify` and SAY SO — the PR's CI
     is the real gate. **Never claim a change was verified if verification was
     skipped.** (`ship`'s Stage 2a rebase check still runs either way.)
   - **Review (ship Stage 3):** let the bundled `code-review --fix` review the diff
     and apply fixes before commit.
   - **QA handoff BETWEEN ship Stage 7 and Stage 8 — do NOT defer it to after the
     hand-off:** the reviewer is **@QA**, not an automated bot (cto-authored PRs
     don't trigger the nsollazzo auto-review), and `ship`'s babysit stage (Stage
     8) only reaches green once a *fresh non-self approval* exists. So the instant
     `ship` finishes Stage 7 (PR open) and BEFORE it begins Stage 8, pause the
     pipeline and do the **step 8** QA handoff — otherwise babysit waits forever on
     a review nobody requested (deadlock). `--yolo` does **not** waive this pause:
     it auto-confirms ship's *own* checkpoints, but this QA handoff is your
     orchestration between stages, not a ship checkpoint. Only then let `ship`'s
     babysit loop run, driving the PR to fresh APPROVED + CI green + mergeable
     against QA's findings.
   - **Reflect (ship Stage 10):** safe to let run — it self-gates and never writes
     unattended.

   If `ship` halts a stage (verify fails, rebase conflict on overlapping files,
   etc.) it fails LOUD with evidence — relay that and stop; do not pretend a PR
   was opened. If git complains about author identity, set it once on the clone:
   `git -C "$clone" config user.name "CTO Agent"; git -C "$clone" config user.email "cto@muso.ai"`.

8. **Ask QA to review — at the Stage 7 → Stage 8 boundary of the `ship` hand-off,
   not after it returns.** The moment `ship` opens the PR (end of Stage 7),
   `sessions_send` to **@QA** with the PR URL so a review is actually performed;
   this is what `ship`'s babysit stage then loops against to reach green. Relay
   QA's verdict under your own identity when it comes.

9. **Report** to the requester in-thread: e.g. *"I opened a PR: <url>, ran it
   through our ship pipeline, and asked QA to review it."* Observe Response
   Hygiene — `ship` / babysit / reflect name internals freely in their own output,
   but YOUR message must NOT mention Codex, OpenClaw, ship-kit, the clone path,
   sessions, or any other internal architecture.

## If something goes wrong

- You can't proceed, or decide not to → don't leave a half-finished branch on the
  remote; tell the requester plainly, and escalate on a genuine tool failure
  (god-mode requesters: report the failure to them, not to Aaron). **Never claim a
  PR was opened if it was not** — paste the real URL. If the only blocker is push
  access (step 2), say so and fall back to a diagnosis + ClickUp ticket for the
  owning team.
