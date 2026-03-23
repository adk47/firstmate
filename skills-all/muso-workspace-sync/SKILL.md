---
name: muso-workspace-sync
description: |
  Auto-push workspace changes to GitHub after core file updates.
  Triggers after any edit to: MEMORY.md, TOOLS.md, HEARTBEAT.md, SOUL.md, 
  AGENTS.md, USER.md, IDENTITY.md, memory/*.md, scripts/*, skills created/updated.

  This is NOT a skill you invoke explicitly. It's a behavioral rule:
  after committing changes to core files, always push.
compatibility: |
  OpenClaw-specific behavioral rule. Requires gh CLI auth for pushing.
metadata:
  version: "1.0"
  source-repo: "Muso-AI/muso-skills"
---

# Workspace Sync to GitHub

## Rule (MANDATORY)

After every `git commit` in your agent workspace, run:

```bash
git push origin main
```

That's it. No batching, no scheduling. Commit → push. Every time.

## What Counts as Core Files

Everything in the workspace is core. If you committed it, push it.

## Remote

- Repo: `Muso-AI/clio-workspace` (private)
- Remote: `origin` → `https://github.com/Muso-AI/clio-workspace.git`
- Branch: `main`
- Auth: gh CLI credential helper

## If Push Fails

1. Check `gh auth status`
2. If auth expired: `gh auth refresh`
3. If conflict: `git pull --rebase origin main && git push`
4. If still broken: log to `memory/YYYY-MM-DD.md` and alert Aaron

## Why

- Off-machine backup (Mac Mini crash = no data loss)
- Aaron can browse workspace history from anywhere
- Git history serves as archive for compacted memory files
