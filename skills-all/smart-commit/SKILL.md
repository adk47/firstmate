---
name: smart-commit
description: |
  Automatically cluster and commit git changes into logical groups with conventional commit
  messages. Use when: committing multiple unrelated changes, cleaning up work before PR,
  organizing messy commits, or when asked to "commit my changes", "smart commit", "organize
  commits", or "cluster commits".
license: MIT
metadata:
  version: "2.1.0"
---

# Smart Commit

Cluster uncommitted changes into logical groups and commit each with a clear conventional commit message.

> **Sub-agents.** Committing is **sequential by design** — every commit shares one git index,
> so parallel sub-agents staging into it would corrupt each other. Do the clustering and
> commits in one agent. (For a very large diff you may use a sub-agent to *propose* the
> clustering, but the `git add` / `git commit` steps stay in the main agent.)

## Workflow

1. Run `git status` and `git diff` to inspect all uncommitted changes
2. Check for pre-staged changes with `git diff --cached`. If anything is already
   staged, don't fold it into clusters silently — commit it as its own commit
   (it was likely staged deliberately) or ask the user what to do with it
3. Analyze changes and cluster into logical groups by:
   - Feature or functionality
   - Bug fix
   - Related files (e.g., component + its test + its styles)
   - Type (docs, config, refactor, etc.)
   - If a single file contains changes belonging to different clusters, assign
     it to the most related cluster and mention the extra change in the commit
     body (interactive `git add -p` is not available)
4. For each logical group:
   - Stage relevant files: `git add <files>`
   - Generate conventional commit message (see format below)
   - Commit: `git commit -m "<message>"`
5. Repeat until all changes are committed
6. Update `CHANGELOG.md` unreleased section (see below), then commit: `docs: update changelog`

## Commit Message Format

Use conventional commits: `<type>(<scope>): <description>`

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`, `perf`, `ci`, `build`

Examples:
- `feat(auth): add password reset flow`
- `fix(api): handle null response from users endpoint`
- `refactor(utils): extract date formatting helpers`
- `docs: update README installation steps`

## Changelog Update (Step 6)

After all commits are made, update the `## [Unreleased]` section of `CHANGELOG.md`:

1. Review all commits just created (use `git log` to see them)
2. Write concise changelog entries grouped under Keep a Changelog sections:
   - `### Added` — new features or capabilities
   - `### Changed` — changes to existing functionality
   - `### Fixed` — bug fixes
   - `### Improved` — enhancements to existing features
   - `### Removed` — removed features
3. Classify each entry as **public** or **internal**:
   - **Public**: User-facing features, behavior changes, critical bug fixes
   - **Internal**: Refactors, test changes, lint fixes, DX improvements, infra plumbing
4. Format internal entries under an `#### Internal` heading with `<!-- internal -->`:
   ```markdown
   ### Added
   - **Feature name**: User-facing description

   #### Internal
   <!-- internal -->
   - Implementation detail that users don't need to see
   ```
5. Stage and commit: `git add CHANGELOG.md && git commit -m "docs: update changelog"`

If `CHANGELOG.md` doesn't exist or has no `## [Unreleased]` section, skip this step.

## After Committing

If this session involved tricky bugs, new integrations, or non-obvious patterns, suggest
running the `reflect` skill to capture lessons learned.

## Rules

- Keep commit messages under 72 characters
- Use imperative mood ("add" not "added")
- One logical change per commit
