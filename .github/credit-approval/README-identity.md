# Why the credit-approval guard cannot be a real gate yet

Written 2026-11-06. Read this before changing `guard.py` or the branch protection
on `main`.

## The problem in one sentence

The fleet authors every PR as `adk47`, so any gate that requires `adk47` to
approve cannot be satisfied — and a required check that cannot go green is not a
control, it is a standing instruction to ignore red.

## What we measured

- `credit-approval-guard` was **17 of 17** failures in the last 100 concluded
  hydra runs. Nothing else failed. The check was the entire red signal.
- `enforce_admins: true` on `main`, so admins cannot bypass it either. The
  check's own log told operators to "admin-merge only on Fable GO + QA GO +
  green CI" — an instruction that `enforce_admins` makes impossible.
- The same root cause blocks `PR must be raised via no-mistakes`: the
  attestation is a block of text in the PR body, which the author writes. It
  proves a string is present, not that a pipeline ran on this SHA.

## What changed on 2026-11-06 (short-term)

`guard.py` now distinguishes two failure classes:

| Author | Graded on | Result |
|---|---|---|
| `adk47` (the fleet) | the `## Credit approval impact` section only | pass + `::warning::` |
| anyone else | the section **and** the captain's approval of head | unchanged, hard-gated |

The captain-authored case still requires an admin-merge on Fable GO + QA GO +
green CI with +15/+60 min monitoring. That rule did not change — it is just no
longer encoded as an unsatisfiable CI condition.

**This is a deliberate, temporary weakening.** It trades a fictional gate for a
real one (the impact section, which an agent *can* satisfy and a reviewer *can*
read). Do not read it as "credit changes are now unguarded."

## The real fix

1. **A GitHub App for the fleet** (`fleet-bot[bot]`). Commits, PRs and comments
   come from the App, not from a human account. Then:
   - `adk47` approving a `fleet-bot` PR is a real, GitHub-enforced human step;
   - CODEOWNERS on `credit/`, `auth/`, `payments/`, `.github/` becomes
     enforceable;
   - the audit log can finally distinguish human actions from fleet actions.
2. **Attestations as check-runs, not text.** The no-mistakes pipeline posts a
   `check_run` bound to `head_sha` from an App identity only it holds. Branch
   protection requires that check. An agent cannot forge it because it does not
   have the key. This is a small change and it makes the existing gate real.
3. **Risk-tiered gates.** One human cannot review 255 agents' output. Route
   high-risk paths to humans; let the rest auto-merge on verified checks. Write
   down which is which. The current state — rules that imply human review,
   reality that has none — is the worst of both.

## The trap to watch for

In three months, throughput will stall on a human-approval gate that is now
*actually* enforced, and someone will wire the App (or a second App, or the
orchestrator) to approve PRs or post the attestation check "to unblock the
fleet." At that point the verifier and the author share a key, the gate is
theater again, and it *looks* rigorous.

Signs it is happening:

- an App token in an agent worktree's environment;
- approvals arriving <60s after a PR opens;
- a PR titled something like "allow bot to approve low-risk PRs".

Mitigations to put in on day one, not later:

- **two Apps** — one authors, one verifies;
- private keys live only in the orchestrator's merge service and the
  no-mistakes runner, never in the ~400 worktrees;
- an audit alert on any approval or check-run from an unexpected App ID;
- a written decision on which paths require a human, so the pressure has a
  sanctioned release valve (auto-merge on low-risk) instead of a back door.
