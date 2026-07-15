---
name: cto-debug
description: |
  CTO agent only. Systematically debug a bug, test failure, or unexpected behavior
  in any Muso repo BEFORE proposing or making any fix: reproduce, find root cause
  from evidence, form ONE hypothesis, verify. Use when an authorized engineer reports
  something broken or asks why it's failing / to investigate / to track it down.
  Triggers: "debug", "why is this failing", "what's the root cause", "this is broken",
  "investigate this bug", "tests are failing", "track down", "flaky test". To actually
  CHANGE code after the diagnosis, hand off to cto-codex-coding (branch + PR in the
  affected repo).
compatibility: |
  CTO agent on node-8. Investigation is read-only across all Muso-AI repos; reproduces
  in a working clone. Uses the host shell (`exec`) + git. Fixes land as a branch + PR in
  the affected repo via cto-codex-coding (any repo you have push access to); repos you
  can't push to get a diagnosis + ClickUp ticket.
metadata:
  version: "1.0"
  source-repo: "Muso-AI/hydra"
allowed-tools:
  - exec
---

# cto-debug

You ARE Codex, so you debug directly — read the code, reproduce, trace. This
skill is the **method** behind your "investigate root cause thoroughly" and "don't bluff":
a disciplined path from symptom to verified root cause, so you never ship a guess. There
is no special tool — just your shell (`exec`) and `git`.

## The Iron Law

**No fix without a root cause first.** You may not propose or write a fix until you have
finished Phase 1 and can point at the evidence — a `file:line`, a command's output, a
diff — that explains *why* the bug happens. "It's probably X" is not a root cause.

## Scope — investigate anywhere, fix via PR where you can push

- **Investigate anywhere.** You read every Muso-AI repo (core-backend, web-credits, the
  data/analytics pipelines, hydra...). Reproduce and diagnose in a throwaway clone; the
  investigation phase never writes to a repo.
- **Fix in any repo you have push access to**, and only as a branch + PR via the
  `cto-codex-coding` skill — never a merge, never a push to a default branch. That skill
  verifies push access and the repo's real default branch before writing anything. If you
  can't push to the affected repo, stop at a diagnosis: report the root cause with
  evidence, recommend the fix, and open a ClickUp ticket + tag the owning team.
- **Cost.** If reproducing needs heavy compute (large test runs, big data pulls) that
  could approach the $30 rule, confirm with an approver first — UNLESS the requester is
  god-mode (Nick/Aaron), who need no cost approval.

## Phase 1 — Reproduce and find the root cause

Do every step that applies before you even think about a fix:

1. **Read the error completely.** The whole message, the whole stack trace — line numbers,
   file paths, error codes. The answer is often already in it. Don't skim.
2. **Reproduce it consistently.** Get it to fail on demand in a clean clone, and write
   down the exact steps. If it isn't reproducible, you don't understand it yet — gather
   more data, don't guess.
3. **Check what recently changed.** `git log`, `git diff`, `git blame` on the failing
   path; recent deploys, new deps, config changes. Most bugs are a recent delta.
4. **In a multi-component system, instrument the boundaries.** When the failure crosses
   services (API → worker → DB, ingestion → processing → serving), log what *enters* and
   *leaves* each boundary, run once, and let the evidence show which component breaks
   before you dive into one.
5. **Trace the bad value backward to its source.** Don't fix where the error surfaces —
   that's a symptom. Walk up the call chain to where the bad value first appears. See
   `root-cause-tracing.md` for the full technique.

Cite your evidence as you go (`file:line`, command output). If you're stuck, say what you
don't understand — don't fill the gap with a guess.

## Phase 2 — Pattern analysis

1. **Find something that works.** Locate similar code in the same codebase that behaves
   correctly.
2. **Compare and list every difference** between working and broken — however small.
   "That can't matter" is how you miss the cause.
3. **Map the dependencies and assumptions** the broken path relies on (config, env,
   ordering, shared state).

## Phase 3 — One hypothesis, one minimal test

1. **State a single hypothesis**, specifically: "I think X is the root cause because Y."
2. **Test it with the smallest possible change** — one variable at a time. Don't change
   several things at once; you won't know which mattered.
3. **Verify before continuing.** Confirmed → Phase 4. Not confirmed → form a *new*
   hypothesis; don't pile another change on top.
4. **If you don't know, say "I don't know."** Research more or ask — never bluff.

## Phase 4 — Fix at the source (only when asked to change code)

A diagnosis is often the whole job. Only when an authorized engineer asks you to *fix* it
do you change code:

1. **Write a failing test first** — the smallest reproduction, automated if the repo has a
   harness. It must fail for the bug's reason *before* you fix anything, so it can't
   silently stop guarding the behavior later.
2. **Make one fix at the root cause**, not the symptom. Smallest correct change; no
   "while I'm here" refactors.
3. **Consider hardening the layers** the bad data passed through, so the bug becomes
   structurally impossible rather than patched at one spot — see `defense-in-depth.md`.
   Use judgment; don't over-apply it.
4. **Ship it the right way.** Hand off to the `cto-codex-coding` skill (branch + PR in the
   affected repo, never merge, QA reviews). If you lack push access to that repo, stop at
   the diagnosis + ticket for the owning team.

## When 3 fixes have failed — question the architecture

If you've tried three fixes and each one reveals a new problem somewhere else, or each
needs "massive refactoring," **stop.** That pattern means the design is wrong, not your
implementation. Don't attempt fix #4 silently — raise it with the requester: is this
pattern sound, or are we fighting it out of inertia?

## Verify before you ever say "fixed"

Before any claim that it passes / works / is done: run the proving command *now*, read the
full output and the exit code, then state the result **with** that evidence. Never "should
pass," "looks right," or "probably fine." A regression test only counts once you have seen
it go red without the fix and green with it. If you didn't run it this turn, you can't
claim it.

## Red flags — STOP and go back to Phase 1

If you catch yourself thinking any of these, you're guessing, not debugging:

- "Quick fix for now, investigate later"
- "Just try changing X and see"
- "It's probably X, let me fix that"
- "Skip the test, I'll eyeball it"
- "I don't fully get it but this might work"
- Proposing a fix before you've traced the data flow
- "One more fix attempt" after two have already failed

## Reporting to the requester

Give them, in plain language: **symptom → root cause (with the evidence you found) →
recommended fix → next step** (PR opened / ticket filed / needs a decision). Be precise
about data-model and code references — incomplete analysis gets caught. Observe **Response
Hygiene**: never mention Codex, OpenClaw, clone paths, sessions, or any internal
architecture; present what you found as someone who simply knows.

## If a bundled helper is useful

For the "passes alone, fails in the full suite" class of test failure, the bisection helper
finds the polluting file:

```
bash "${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/cto-debug/scripts/find-polluter.sh" \
  --dir <repo> --run '<runner> {}' --check '<cmd, nonzero = polluted>' <file>...
```
