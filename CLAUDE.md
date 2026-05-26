# hydra — Claude operating notes

## Verify before agreeing — neither I nor Clio is automatically right

When Nick or Clio (or any other reviewer) tells me something about the code,
treat it as a hypothesis to verify, not a fact to act on. Both can be wrong.

- **Verify with evidence before acting.** Open the file, run the command,
  read the diff. Cite file:line, command output, or git history when stating
  a finding.
- **Push back when I disagree.** If something a reviewer says doesn't match
  what I see in the code, say so plainly with the evidence — don't silently
  capitulate, and don't pretend to agree just to move things along.
- **"Clio said X" is not a justification.** Neither is "Nick said X." The
  code, the tests, the runtime behavior, and the git log are the
  authorities.
- **If I'm uncertain, say so.** Better to flag a maybe-wrong claim than to
  rubber-stamp it and ship a regression.

This applies in both directions: when reviewers flag bugs that aren't real,
and when I believe my own work is correct but a reviewer thinks otherwise.
Disagreement is information; suppress it and we both lose signal.

## Releases

Hydra cuts daily releases off `main` (mirroring openclaw's pattern — no
release branches, no canary; tag is a labeling event, not a gate).

- **Tag format**: `vYYYY.M.D` with no leading zero on month/day
  (e.g., `v2026.5.26`). Multi-cut days append `.N` (`v2026.5.26.1`).
- **How to cut**: `./scripts/release.sh` — opens generated notes in
  `$EDITOR`, then tags, pushes, creates the GH release, and posts a
  Block Kit announcement to #clio_devops via the devops bot.
- **Dry-run**: `DRY_RUN=1 ./scripts/release.sh` previews the notes
  without tagging or publishing.
- **No CHANGELOG.md**: GitHub releases are the changelog. Don't
  introduce a tracked CHANGELOG file.
- **Cron**: `hydra-release.timer` fires Mon..Fri 08:00 Europe/Rome
  on node-8, invoking `scripts/release-cron.sh`. The wrapper operates
  against a **dedicated git checkout at `/var/lib/hydra-release/repo`**
  — NOT `/opt/hydra/`, which is the rsync target and has no `.git`.
  `install-aux-units.sh` initializes the checkout on first deploy
  (clone via `gh repo clone` + local `user.name`/`user.email` for tag
  identity). Each fire: `git fetch && git reset --hard origin/main`
  then `release.sh --no-edit`. Date-gated to first fire on
  2026-05-28T06:00Z; disable with
  `systemctl disable --now hydra-release.timer` if commit-subject
  hygiene goes bad. Inspect upcoming fires with
  `systemctl list-timers hydra-release.timer`.

## Hot-patching skills on node-8

Before editing any file under `/opt/hydra/skills-all/` directly on node-8
(e.g. previewing a fix on the live server before merging the PR), announce
the imminent write so the next deploy doesn't halt at Step 4a:

```bash
sha=$(sha256sum new-content.md | awk '{print $1}')
ANNOUNCE_SHA="$sha" \
  /opt/hydra/scripts/lib/announce-skill-hot-patch.sh nick \
    /opt/hydra/skills-all/<path>
install -m 644 new-content.md /opt/hydra/skills-all/<path>
```

The next deploy's pre-flight drift check accepts the divergence (rsync still
overwrites server bytes with the PR's HEAD bytes — the announce only
suppresses the halt, never the sync). Without an announcement, Step 4a
halts with the existing `DEPLOY BLOCKED — skills-all/ content drift`
runbook (`scripts/sync-from-server.sh skills --apply` → commit → re-deploy
or `HYDRA_FORCE=1` after verification).

Ack window is 1h by default (`HYDRA_HOTPATCH_ACK_WINDOW`); stale
announcements stop shielding after that. See `scripts/lib/announce-skill-hot-patch.sh`
and `scripts/lib/acknowledge-hot-patch-drift.sh`.

## Picking the right extension mechanism

Before writing new code in this repo, walk this decision tree top-down and stop at
the first YES. Picking the wrong mechanism is how this repo accumulated 38 drifted
skills, 5 orphan scripts, and a dead Gmail plugin (rationale + cleanup in issue #329).

1. **External event into the gateway** (Slack / Intercom channel / `/hooks/agent` webhook)? → openclaw plugin in `plugins/<name>/`
2. **External MCP server I don't own**? → wire via `mcp.servers` in
   `openclaw-*.json` (transport: `streamable-http`)
3. **Wall-clock schedule, no human in the loop**? → openclaw cron in
   `cron-jobs.json` (sessionTarget=main)
4. **Deterministic multi-step pipeline, no LLM in the loop**? → Lobster `.lobster`
   file invoked via `exec → bash wrapper.sh` (never agent → lobster direct)
5. **Git push / PR open / CI**? → `.github/workflows/*.yml`
6. **Procedure ≥2 agents need in-context**? → SKILL in `skills-all/<name>/` only.
   Workspace shadows under `workspaces/<agent>/skills/<name>/` are **forbidden**
   by default — `scripts/check-skill-drift.sh` (gated by CI) will block any new
   one. Workspace copies are **rank-1** in openclaw's resolver and **shadow** the
   canonical at agent-bind time, so a shadow either silently duplicates canonical
   (dual-edit burden) or silently freezes stale doctrine for the agent. Either way
   it's a bug, which is why the default is "no shadows."
   The only exception is when a single agent needs genuinely per-agent content
   (e.g. `operations/muso-ops-admin` carries `config/tier2-godmode-allowlist.txt`
   which must NOT propagate to canonical). For those, list the workspace
   `SKILL.md` path in `.skill-workspace-divergence.txt` with a one-line reason,
   and prepend a `<!-- WORKSPACE-DIVERGENCE: ... -->` HTML comment after the
   frontmatter close. The 38 historical drift entries that bit us in PRs #183,
   #187, #213 (and pre-#336) were exactly the absence of this rule.
7. **One shell line**? → just call `exec` directly, no wrapper, no skill
8. **Complex helper, agent + human callable, not Lobster-shaped**? → `scripts/`
   (one language per concern — don't add `foo.ts` next to `foo.sh`)
9. **Claude Code research persona**? → `.claude/agents/<name>.md`

### Anti-patterns that have bitten us

- Skill wrapping a single bash command → inline in SOUL.md or call `exec` directly
- Plugin exposing one tool with no callbacks → that's a script behind JSON-RPC
- Agent → lobster tool direct → schema bleed forces hallucinated `flowId`; use
  `exec → bash wrapper → /tools/invoke`
- Hand-rolled session pruning / log rotation / cron maintenance → grep openclaw
  config for a native key first (`session.maintenance`, `statusReactions`,
  `tools.deny`, `extra_body.plugins`, `/hooks/agent`)
- `before_tool_call` hook as YOLO-mode safety → silent no-op for exec; enforce at
  the bash boundary instead
- Writing to `/root/.openclaw-*/openclaw.json` out of band → must call
  `announce-legit-write.sh` first or the audit watcher fires a Slack false-positive
- GH Actions for runtime ops (as opposed to CI gates) → has caused two-CD-paths
  drift before

### Specialist subagents (in `.claude/agents/`)

When uncertain about *which* mechanism to use, or when authoring a skill or plugin,
route to the right specialist instead of guessing:

- `hydra-extension-picker` — "where does this go?" / "plugin or skill?" questions
- `hydra-skill-author` — creating, editing, or copying a SKILL (enforces dual-tree
  rule, `exec` allowed-tools naming, Lobster wrapper pattern)
- `hydra-plugin-author` — creating or editing an in-tree plugin under `plugins/`
  (enforces openclaw 2026.5.x packaging contract: `dist/index.js`, build script,
  pnpm-lock against deploy SDK)
- `openclaw-expert` — any general OpenClaw infrastructure question (gateway config,
  hooks, cron, /tools/invoke, model fallback, session lifecycle)

### When in doubt

- The decision tree exists because past me kept getting it wrong. Trust the tree.
- If the new work feels like it spans multiple buckets, it probably needs to be
  split.
- The full rationale lives in GitHub issue #329 (the consolidation issue).
