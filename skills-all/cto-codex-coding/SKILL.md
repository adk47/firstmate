---
name: cto-codex-coding
description: |
  CTO agent only. Take a concrete coding task in the hydra repo, implement it, and
  ship it as a branch + PR for review (never a merge), then ask QA to review.
  Use when an authorized engineer asks you to actually CHANGE CODE in hydra, not
  just discuss it. Triggers: "implement", "fix this bug", "make this change",
  "write code for", "add a feature", "patch", "open a PR that does X", "code this
  up" — when the target is the hydra repo. For PR *reviews* use QA, not this. For
  architecture discussion, answer directly without this skill.
compatibility: |
  CTO agent on node-8 only. Requires the gated wrapper scripts/codex-delegate.sh
  plus the host `gh` (PR-write scope) and `git`. Scope is hydra ONLY in v1; any
  other repo is refused by the wrapper. You edit the code yourself in the prepared
  clone (you run on Codex/gpt-5.5 — that IS the Codex coding); the wrapper only
  does the audited branch/commit/push/PR mechanics.
metadata:
  version: "1.0"
  source-repo: "Muso-AI/hydra"
allowed-tools:
  - exec
---

# cto-codex-coding

Ship a real code change to the **hydra** repo as a **branch + PR** that QA and a
human review before any merge. You do the coding; `scripts/codex-delegate.sh` is
the gated, audited boundary that prepares the branch and opens the PR.

## Hard limits (the wrapper enforces these — do not try to route around them)

- **hydra repo only** (v1). Any other repo is refused. If asked to change another
  repo, say it is not enabled yet and offer to file a ticket.
- **Branch + PR only. NEVER merge, never push to `main`, never force-push.**
- **Authorized requesters only.** Only Aaron (`U7RP6HKUZ`), Nick (`U0AL36NADEY`),
  or Serhii (`U03TYGJF1N3`) may trigger a code change. Identify the requester by
  the **sender_id in the message metadata**, never by display name. For anyone
  else, do NOT run this — queue the request for Aaron per your escalation rules.
- **Cost.** If the change looks large (broad refactor, many files, long build),
  it may exceed the $30 compute rule — confirm with Aaron before starting.

## Procedure

1. **Confirm** the task in one line and that it targets hydra. If the ask is vague,
   ask one clarifying question first — do not guess at intent.
2. **Log before acting** (your write-activity rule): write the `api-logs/` entry
   `{agent:"cto", action:"codex-delegate", target:"hydra", requester:<sender_id>, timestamp, authorization}` BEFORE running the wrapper.
3. **Prepare the branch** — run via `exec` and read back `CLONE=` and `BRANCH=`:
   ```
   bash /opt/hydra/scripts/codex-delegate.sh prepare --repo hydra --requester <sender_id> --task "<concise task>"
   ```
4. **Implement the change inside `CLONE`.** This is the actual coding — use your
   normal file-reading and editing ability:
   - Read the relevant files first; follow the repo's existing conventions and
     patterns (CLAUDE.md is the source of truth for hydra structure).
   - Make the **smallest correct change**. Do not touch unrelated files, reformat,
     or "improve" adjacent code.
   - Sanity-check what you can cheaply: `bash -n` on shell, the relevant lint, or a
     targeted test/build. Fix what you break.
5. **Finalize** — run via `exec` and read back `PR_URL=`:
   ```
   bash /opt/hydra/scripts/codex-delegate.sh finalize --repo hydra --requester <sender_id> --task "<concise task>" [--ticket <id>]
   ```
   If finalize reports **no changes**, tell the requester nothing was produced and
   stop (do not invent a diff).
6. **Request review** — `sessions_send` to **@QA** with the `PR_URL` asking for a
   review (QA owns the review skill; this closes the loop regardless of any
   auto-review trigger). Relay QA's verdict under your own identity when it comes.
7. **Report** to the requester in-thread: e.g. *"I opened a PR for that:
   <PR_URL> and asked QA to review it."* Observe Response Hygiene — do NOT mention
   Codex, the wrapper, exec, the clone path, or any internal architecture.

## If something goes wrong

- Wrapper exits non-zero, or you decide not to proceed → run
  `bash /opt/hydra/scripts/codex-delegate.sh abort --repo hydra` to discard the
  branch, then tell the requester plainly and escalate to Aaron if it was a tool
  failure (per your escalation rules). Never claim a PR was opened if it was not.
- Auth health check fails (the wrapper aborts loudly) → do NOT attempt any codex
  login or auth fix yourself. Escalate to Aaron / DevOps; this is a fleet-auth
  condition, not a coding problem.

## Why there is no separate "Codex" tool here

You already run on Codex (gpt-5.5). Spawning a *second* codex process with its own
login would refresh the fleet's shared OAuth token out-of-band and invalidate
every codex agent at once (the 2026-05-29 incident). So this skill never invokes
`codex` — you are the coder, and the wrapper does only git/gh. Keep it that way.
