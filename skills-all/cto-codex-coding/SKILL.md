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

You ARE Codex, so you do the coding directly — read files, make the
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
- **core-backend is split-path: a `develop` PR does NOT reach production.**
  `develop` serves the dev environment; `master` serves `api.muso.ai`. The two
  branches are permanently diverged (measured 2026-08-17: `ahead_by=289,
  behind_by=58`), so **NEVER merge `develop` into `master`** — that would drag
  hundreds of unrelated commits into prod. Production is reached by a per-change
  **twin PR**: cherry-pick the same change onto its own
  `cto/<slug>-<ts>-master` branch based on `master`, and open it as a second
  PR in the same run — **step 9 of the procedure below is where you actually do
  it**; this bullet only states the rule. Open the twin at fix time — a twin
  that is left for later is historically the one that never gets opened. Reuse
  step 5's `<ts>` (a date alone collides on a same-day retry, which is exactly
  what step 5's unique-name rail exists to prevent). If the cherry-pick does NOT
  apply cleanly and you hand-port instead, **verify the ported logic, not the
  tests**: a twin pair has passed byte-identical test diffs while the two
  branches' predicates behaved differently (one silently denied access). State
  the resulting rule in one sentence per branch and confirm they match. Say
  plainly in your report that prod is not covered until the twin merges, and
  never merge it yourself:
  merging `master` IS an unattended production release (`deploy-to-ovh.yaml`,
  no CI on core-backend PRs, no second confirmation after merge).
- **Requesters**: god-mode requesters — Nick (`U0AL36NADEY`) or Aaron
  (`U7RP6HKUZ`) — proceed with no approval. Any other requester follows the normal queue/approval path. Identify by the
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
> hand-off (step 7) and the twin step (step 9). Shell state does NOT survive across separate `exec` calls —
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
   commit → PR → green pipeline. (The single exception is the core-backend
   `master` twin in step 9, which `ship` cannot open because it ships one branch
   → one PR.) First re-assert the rails as a fail-closed
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

   **Capture the PR's identity here — step 9 refuses to run without it.** Read
   it from the branch rather than retyping it, so the twin is provably linked to
   the PR that was actually opened:

   ```
   dev_pr_url=$(gh pr view "$branch" --repo "$repo" --json url   -q .url)   || {
     echo "cannot read the develop PR url for $branch" >&2; exit 1; }
   dev_pr_title=$(gh pr view "$branch" --repo "$repo" --json title -q .title) || {
     echo "cannot read the develop PR title for $branch" >&2; exit 1; }
   [ -n "$dev_pr_url" ] && [ -n "$dev_pr_title" ] || {
     echo "develop PR identity is empty - refusing to continue to the twin" >&2; exit 1; }
   ```

   Skipping this leaves step 9's `${dev_pr_url:?}` guard to abort the run, which
   means no twin, which means the fix stays dev-only - the exact production gap
   step 9 exists to close.

9. **core-backend ONLY — open the `master` twin now, in this same run.** A
   `develop` PR does not reach production (split-path rule above), and `ship`
   owns exactly one branch → one PR, so the twin is the one place you DO hand-run
   `git`/`gh` yourself. Every other repo skips this step entirely.
   ```
   # This block guards EVERY fallible command itself. Nothing upstream sets
   # `set -e`, so an unguarded failure just falls through: a failed `git push`
   # would continue into the PR step, reuse a stale PR, and hand QA a
   # "ported=clean" production twin whose remote branch never received the
   # commits. Verified by running the block with a broken remote.
   die() { echo "twin step: $*" >&2; exit 1; }

   # The twin's ONLY link back to the reviewed change is its title and body, so
   # they are real values, not placeholders. Fail closed rather than let GitHub
   # create a production PR literally titled "<same title, master twin>" whose
   # body links to "<url>" - untraceable to its develop PR, which is the
   # procedure's safety invariant.
   dev_pr_url="${dev_pr_url:?set dev_pr_url to the develop PR ship just opened}"
   dev_pr_title="${dev_pr_title:?set dev_pr_title to the title of that PR}"

   if [ "$repo" = "Muso-AI/core-backend" ]; then
     # EVERY commit this run put on $branch, oldest first. `ship` Stage 4 runs
     # smart-commit, which clusters the change into as many logical commits as
     # it needs, so taking only the tip would cherry-pick HALF a fix onto
     # master and still report ported=clean -- a partial fix shipped to
     # production, silently. Word-splitting $shas below is intentional.
     shas=$(git -C "$clone" rev-list --reverse "origin/$base".."$branch")
     [ -n "$shas" ] || { echo "no commits on $branch over origin/$base" >&2; exit 1; }
     twin="${branch}-master"     # reuses step 5's UTC timestamp → retry-safe, still cto/*
     git -C "$clone" fetch origin master || die "cannot fetch origin/master"
     # RESUMABLE: a conflicted first run exits below with $twin already created,
     # so `switch -c` would die "branch already exists" on the rerun and the
     # guard above would abort the run. Reuse
     # the branch instead -- and never `switch -C`, which would reset it and
     # silently destroy a hand-port that was just committed.
     if git -C "$clone" show-ref --verify --quiet "refs/heads/$twin"; then
       git -C "$clone" switch "$twin" || die "cannot switch to existing $twin"
     else
       git -C "$clone" switch -c "$twin" origin/master || die "cannot create $twin"
     fi
     if [ -n "$(git -C "$clone" rev-list origin/master.."$twin")" ]; then
       # A resumed run. Distinguish a RESUMED CLEAN cherry-pick from a
       # hand-port: comparing patch-ids answers it exactly (this is a real
       # cherry-pick, not a squash, so patch-id is reliable here). Without
       # this, retrying after a successful clean cherry-pick would demand a
       # hand-port acknowledgement that never applied.
       # EVERY commit must be present, not just one: a twin carrying only the
       # last of a two-commit fix would otherwise pass as a resumed clean
       # cherry-pick.
       want_pids=$(for c in $shas; do
                     git -C "$clone" show "$c" | git patch-id --stable | awk '{print $1}'
                   done | sort -u)
       have_pids=$(git -C "$clone" rev-list origin/master.."$twin" | while read -r c; do
                     git -C "$clone" show "$c" | git patch-id --stable | awk '{print $1}'
                   done | sort -u)
       missing=$(comm -23 <(printf '%s\n' "$want_pids") <(printf '%s\n' "$have_pids"))
       # EXTRAS matter as much as missing ones. A subset check passes a twin
       # that carries every wanted commit PLUS an unrelated manual commit, and
       # would then push that stray change into the production PR under
       # ported=clean, with no hand-port acknowledgement. Require exact
       # equivalence in both directions.
       extra=$(comm -13 <(printf '%s\n' "$want_pids") <(printf '%s\n' "$have_pids"))
       if [ -z "$missing" ] && [ -z "$extra" ]; then
         ported=clean       # resumed after a successful cherry-pick of EXACTLY the range
       else
         # "The branch has commits" is NOT "the fix is ported": an unrelated or
         # partial commit would otherwise push a twin PR that looks like
         # production coverage and does not contain the change -- worse than no
         # twin, because it reads as done. Completion is never inferred.
         if [ "${TWIN_HANDPORT_VERIFIED:-0}" != "1" ]; then
           echo "twin $twin does not match the develop range: UNVERIFIED." >&2
           [ -n "$missing" ] && echo "  missing patch-ids: $(echo $missing | tr '\n' ' ')" >&2
           [ -n "$extra" ]   && echo "  unexpected extra commits on the twin" >&2
           echo "Diff it against the develop fix, state the resulting rule in one" >&2
           echo "sentence per branch, and only then re-run with" >&2
           echo "TWIN_HANDPORT_VERIFIED=1 to push and open the twin." >&2
           exit 1
         fi
         ported=hand
       fi
     elif git -C "$clone" cherry-pick $shas; then
       ported=clean
     else
       # Guard the abort, and stop MECHANICALLY rather than by prose. A
       # multi-commit fix can apply commit 1 and conflict on commit 2; if the
       # abort then fails (a locked index in the shared clone, say), the old
       # code fell through with commit 1 still on the twin -- and the
       # empty-twin guard below only catches an EMPTY twin, so it pushed a
       # PARTIAL fix to production as ported=hand with no acknowledgement
       # (TWIN_HANDPORT_VERIFIED is only checked on the resumed path).
       git -C "$clone" cherry-pick --abort \
         || die "cherry-pick --abort FAILED - $twin is in an unknown state; resolve it by hand before retrying"
       die "cherry-pick conflicted - hand-port the change onto $twin, COMMIT it, then re-run with TWIN_HANDPORT_VERIFIED=1"
     fi
     # Fail-closed: never push or PR a twin that carries no commits. Without this
     # the hand-port path pushes an unchanged copy of origin/master and
     # `gh pr create` dies with "No commits between ..." -- leaving NO twin at
     # all, which is the exact failure this step exists to prevent.
     if [ -z "$(git -C "$clone" rev-list origin/master.."$twin")" ]; then
       echo "twin $twin has no commits over origin/master (ported=$ported):" >&2
       echo "the hand-port was never committed -- refusing to push an empty twin" >&2
       exit 1
     fi
     # A failed push is fatal: everything below reports a twin that the remote
     # does not actually carry.
     git -C "$clone" push -u origin "$twin" || die "push of $twin failed - the remote does NOT carry this change"
     # IDEMPOTENT: a run that died after `gh pr create` succeeded must still be
     # able to reach the QA hand-off below. Creating again returns "a pull
     # request already exists" non-zero, and the guard above would then abort
     # the run BEFORE QA is ever contacted -- leaving the production
     # twin permanently outside the review path. So reuse an open PR if one
     # exists, and only create when there is none.
     twin_url=$(gh pr list --repo "$repo" --head "$twin" --base master \
                  --state open --json url --jq '.[0].url // empty') \
       || die "could not query existing PRs for $twin"
     if [ -z "$twin_url" ]; then
       twin_url=$(gh pr create --repo "$repo" --base master --head "$twin" \
         --title "$dev_pr_title (master twin)" \
         --body "Production twin of the develop PR $dev_pr_url. ported=$ported") \
         || die "gh pr create failed for $twin"
     fi
     [ -n "$twin_url" ] || die "no twin PR url - refusing to report a twin that may not exist"
     echo "twin PR: $twin_url (ported=$ported)"
   fi
   ```
   If `ported=hand`, **verify the ported logic, not the tests** (see the
   split-path rule): state the resulting rule in one sentence per branch and
   confirm they match.

   **Then put the twin through QA and WAIT for its verdict, exactly as step 8
   waits for the `develop` PR.** `sessions_send` to **@QA** with the twin URL,
   saying plainly that it is a core-backend *production* twin, that
   core-backend runs **no CI on pull requests** so review is the entire gate,
   and — when `ported=hand` — that it is a hand-port rather than a clean
   cherry-pick, so the predicate needs comparing and copied tests prove
   nothing. Do not report completion until that verdict is in.

   Getting this order wrong is how the wrong behavior reaches production: the
   twin is created after step 8's wait, so without its own wait the
   already-green `develop` PR looks like the reviewed artifact while the twin —
   the one that actually reaches `api.muso.ai`, and the only one carrying
   hand-port risk — is the one nobody read. **Never merge either one.**

10. **Report** to the requester in-thread, and for core-backend state **both**
    verdicts explicitly — the `develop` PR's and the `master` twin's — plus the
    fact that production is not covered until the twin merges. A report naming
    only one verdict reads as "reviewed" for a change that was not.
    e.g. *"I opened a PR: <url>, ran it
    through our ship pipeline, and asked QA to review it."* Observe Response
    Hygiene — `ship` / babysit / reflect name internals freely in their own output,
    but YOUR message must NOT mention Codex, OpenClaw, ship-kit, the clone path,
    sessions, or any other internal architecture. For core-backend, say plainly
    that production is not covered until the `master` twin merges.

## If something goes wrong

- You can't proceed, or decide not to → don't leave a half-finished branch on the
  remote; tell the requester plainly, and escalate on a genuine tool failure
  (god-mode requesters: report the failure to them, not to Aaron). **Never claim a
  PR was opened if it was not** — paste the real URL. If the only blocker is push
  access (step 2), say so and fall back to a diagnosis + ClickUp ticket for the
  owning team.
