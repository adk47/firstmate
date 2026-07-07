---
name: cto-prod-alert-triage
description: |
  CTO agent only. When summoned into a #prod-alerts error-alert thread, run a
  read-only root-cause investigation, post a diagnosis in-thread, and offer to
  fix it. On an explicit approval from Nick or Aaron in that thread, implement
  the fix and open a PR through the normal CTO coding rail. Triggers: an automated
  dispatch whose message starts "PROD-ALERT CTO TRIAGE" and carries a Slack
  channel id + alert thread ts, or being @-mentioned by a human in a #prod-alerts
  (C0BA8QMV3ME) alert thread.
compatibility: |
  CTO agent on node-8. Investigation is read-only (cto-debug method). Any code
  change goes ONLY through cto-codex-coding (audit row, push-access check,
  branch + PR, ship, QA handoff, never a merge). This skill adds no new tools
  and changes none of those rails.
metadata:
  version: "0.1"
  source-repo: "Muso-AI/hydra"
allowed-tools:
  - exec
---

# cto-prod-alert-triage

You have been pulled into a production error-alert thread in #prod-alerts. The
DevOps agent already classified it (P0 / P1) and summoned you. Usually you arrive
via an automated dispatch: its message starts "PROD-ALERT CTO TRIAGE" and gives
you the Slack channel id, the alert thread ts, and the severity. Take those from
the message. (A human may also @-mention you into such a thread directly; then
read the channel + thread from that mention.) Your job is the engineering
follow-through: figure out what is actually wrong, tell the thread in plain
terms, and, only if Nick or Aaron approve, fix it and open a PR.

This skill is just the sequencing. The two skills it leans on already exist and
do not change:

- **cto-debug** owns the read-only investigation method (reproduce, trace the
  bad value to its origin, one hypothesis, verify). Its Iron Law holds here: no
  proposed fix without a root cause backed by evidence.
- **cto-codex-coding** owns every code change (it is your ONLY coding entry
  point: audit row first, push-access check, per-repo clone, `cto/<slug>-<ts>`
  branch, ship through ship-kit, QA handoff, babysit to green, never a merge).

## Step 1 - Investigate, read-only

Take the alert text and the failing deployment from the thread root. Run the
**cto-debug** method against the relevant repo. Do not write anything yet: no
branch, no edits, no PR. If you cannot reach a root cause, that is a valid
outcome; say what you found, what is still unknown, and what evidence would
close the gap. Do not bluff a cause you do not have.

## Step 2 - Post the diagnosis in-thread

Reply in the alert thread with the four-part structure, in plain language:

- **Symptom** - what is observably wrong.
- **Root cause** - the origin, WITH the evidence (file:line, command output, or
  diff) that proves it. If unverified, say so and stop at "needs more data".
- **Recommended fix** - the source-level fix, plus any alternative worth a
  one-line tradeoff, led by your recommendation.
- **Next step** - end with this exact offer so the approval gate is unambiguous:
  "Reply here mentioning me with your approval and I will implement this and
  open a PR."

Post it into the alert thread explicitly, using the channel id and thread ts you
were given: `muso slack send --bot cto --channel <CHANNEL_ID> --thread-ts <THREAD_TS>
--text "..." --requester cto-prod-alert-triage@hydra`. (Do not assume you are
already "in" the thread; an automated dispatch wakes you outside it.) Observe
Response Hygiene: do not mention internal architecture, clone paths, or tooling
names; write as an engineer who simply knows.

## Step 3 - Approval gate

Do NOT start coding on your own initiative. Proceed to a fix ONLY when, in this
thread, an approver replies with a clear yes AND re-mentions you (a human mention
DOES reach you, unlike the bot summon, so the channel routes it to you). Because
your diagnosis was posted from a short-lived dispatch turn, read the thread first
to reconstruct context (the alert, your own diagnosis, the approval). "Approver"
means Nick (`U0AL36NADEY`) or Aaron (`U7RP6HKUZ`), identified by the **sender_id**
in the message metadata, never the display name. This is the same god-mode rule
your SOUL already applies; anyone else replying yes does not unlock the fix. If
the reply is ambiguous ("hmm maybe"), ask one clarifying question and keep waiting.

## Step 4 - Fix, ship, report

On a verified approval, hand the concrete change to **cto-codex-coding** exactly
as written there (it targets the repo the root cause lives in, writes the audit
row, cuts the `cto/<slug>-<ts>` branch, ships through ship-kit with `--yolo` to
a green PR, loops in QA, and babysits to green). You do not merge; a human does.

When the PR is open and green (fresh approval + CI passing + mergeable), report
back in the SAME alert thread with the PR URL and one line: it is ready for a
human to merge. If the fix stalls (verification fails, push blocked, QA finds a
real blocker), say so plainly in-thread with the evidence; never claim a PR is
ready when it is not.
