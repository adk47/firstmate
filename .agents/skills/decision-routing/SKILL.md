---
name: decision-routing
description: >-
  Who answers a decision.
  Class B reaches the captain.
  Fable rules everything else in the same turn and the daily digest is notice plus a revert window.
  Load before any escalation, before opening a hold, and before treating a gate finding as captain-facing.
user-invocable: false
metadata:
  internal: true
---

# Decision routing

This is the only home of who answers.
The other procedures point here and do not restate the list.

Load this before escalating, before `fm-captain-hold.sh hold`, and before a gate finding is called captain-facing.

## Class B, the captain

Reach the captain only when the question is one of these:

- A login or a click only he can do.
- New spend, a new recurring commitment, or giving a third party access or money.
- A legal signature, or his name on an outside commitment beyond copy he already delegated.
- Irreversible destruction of anything that cannot be reconstructed, including customer data, repo history, unlanded work, and backups.
- Auth, secrets, credentials, permissions, or network exposure.
- A change to this delegation itself: this Class B list, the decision rule in `captain.md`, or the Fable model and pool.

Fable may bounce a question to him when it smells like one of these.
Fable does not widen this list.
He adds a line.
The chair does not.

These stay outside any question, so they are not a ruling and not a hold:

- No merge on a red required check.
- No discarding unlanded work.
- No force push.
- No hand-writing a managed project's `AGENTS.md`.
  Firstmate's own `AGENTS.md` is this repo, not a managed project.

A standing `yolo` is not an explicit word that clears one of these.

## Everything else, Fable

A question that is not Class B is a Fable ruling on the token pool.
She rules and the chair acts in the same turn.
The daily digest carries every ruling as notice and a revert window.
It is not consent, and his silence after the digest is not a yes.

When `config/decider-task` exists, deliver the question to that seat and wait for the ruling.
When it is absent, the chair rules on the token pool itself.
Do not stall and do not ask the captain because the seat is missing.

An unanswered question never becomes a yes.
There is no timeout that approves.

Record the ruling with the five elements in ask-user-authority.
Pass `--class fable` to `fm-captain-hold.sh hold` so the body says `Decision class: fable` and the parent channel is not pinged.

## Recording

`fm-captain-hold.sh hold` takes `--class fable` or `--class b`.
The default, and any hold with no class, records `Decision class: b` and stays on his board.
Only an explicit `--class fable` records `Decision class: fable`.
The script records the class the caller already chose.
It does not decide.

## Kill switch

`config/decisions-to-aaron` is a presence file and is not inherited.
While the file exists, every decision reaches the captain again, the way it did before this skill.
`fm-captain-hold.sh hold` then records `Decision class: b` and publishes the parent line even when the caller passed `--class fable`.
Remove the file to return to this routing.
He adds the file and he removes it.
The chair does not.
