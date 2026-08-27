---
name: cs-stale-drain
description: |
  Operations-agent stale-backlog drain: silently close OPEN inbound Intercom
  conversations where WE replied last and the customer has been silent more
  than 30 days since our last reply. Wraps the repo closer
  /opt/hydra/scripts/close-stale-conversations.py (dry-run default, ceiling,
  shadow log, sibling de-confliction). ON-DEMAND ONLY — runs solely when Nick
  or Jan explicitly asks. Triggers: "drain stale conversations", "close stale
  conversations", "stale drain", "run cs-stale-drain".
compatibility: |
  Main gateway / operations agent on node-8 ONLY (NOT edge/Caroline). Uses
  /opt/hydra/scripts/close-stale-conversations.py; MUSOAI_INTERCOM_TOKEN comes
  from the gateway's systemd env (/etc/openclaw/main.env) — nothing to source.
metadata:
  version: "0.1"
  source-repo: "Muso-AI/hydra"
allowed-tools:
  - exec
---

# CS Stale Drain (on-demand, Nick/Jan-triggered)

The stale we-spoke-last backlog: conversations we answered whose customer
never came back. close-resolved only closes ticket-linked conversations, so
these accumulate forever (2026-07 backlog: ~1,950). This skill drains them
with the repo closer — silently (no customer-facing message), reversibly
(shadow log), and de-conflicted against every sibling sweeper.

## Requester gate (FIRST — before any exec)

Run ONLY when the triggering message explicitly asks for a stale
drain/close AND the requester is **Nick (`U0AL36NADEY`)** or **Jan
(`U038BM16T7W`)**. Their request IS the authorization — do NOT ask Aaron
(or anyone else) for permission or sign-off; no additional approval step
exists for this skill. For any other requester, or any cron/heartbeat/
proactive turn: do NOT run, reply that stale-drain is triggered by Nick or
Jan only. NEVER run this skill unprompted.

**This holds when they ask for a VARIATION.** A different staleness window
("14 days, not 30"), a narrower scope, a bigger ceiling — still Nick's or
Jan's own authorization, still no sign-off from anyone. If the variation is
something the tooling cannot express, that is a **capability gap, not an
approval gap**: say exactly what the script can and cannot do, offer the
closest supported run, and stop. Never turn "the closer has no flag for that"
into a write-approval page to Aaron — and if Nick or Jan then says "do it",
that is the decision, not a request to go re-check with someone else.
(2026-08-26: Jan asked twice to close 14-day-old conversations in her inbox;
the agent paged Aaron for approval and then refused Nick's explicit "do it"
because Aaron had not replied. Both moves were wrong.)

## Step 1 — ALWAYS dry-run first (read-only on Intercom)

```
exec python3 /opt/hydra/scripts/close-stale-conversations.py
```

**Staleness window — `STALE_DAYS` (default 30).** When the requester names a
different window, pass it; this is supported and needs no approval:

```
exec STALE_DAYS=14 python3 /opt/hydra/scripts/close-stale-conversations.py
```

It must be a positive integer — the script fails loud on 0, negatives and
non-numbers (`STALE_DAYS=0` would make every we-spoke-last conversation
eligible). A shorter window only widens the candidate set; every other safety
rule below is unchanged, so a 14-day run still never touches a
customer-last or never-replied conversation.

**Scoping to one person's inbox is NOT supported.** The closer has no
assignee/team filter — it works over the whole shared open backlog. If the
request is "just my inbox", say so plainly and offer the unscoped dry-run
counts; do not silently run it unscoped, and do not escalate the gap to anyone
as an approval question.

Prints scanned/owned/eligible counts, a 15-row preview (emails masked), and
writes the full masked review export to
`/var/lib/close-stale-conversations/candidates-<date>.json` (0600). Report
the counts + export path to the requester in-thread.

The script owns ALL safety logic — never re-implement or "pre-filter" it:
- closes ONLY inbound + we-spoke-last (`last_admin_reply_at > 0` and
  `> last_contact_reply_at`) + customer silent >30d since OUR last reply;
- customer-last and never-replied conversations are NEVER touched (doctrine:
  a customer still waiting is never closed — docs/plans/autonomous-cs-machine.md);
- de-conflicts by conversation id against every sibling sweeper source and
  fails CLOSED (exit 4) if any sibling state is corrupt.

If eligible is 0: report that and stop.

## Step 2 — apply ONLY on an explicit "close/apply" instruction

Dry-run and apply are separate authorizations: run `--apply` only when the
requester's message explicitly says to close (a bare "run the stale drain"
gets the dry-run + counts, then ask whether to apply). Ramp discipline:

```
exec python3 /opt/hydra/scripts/close-stale-conversations.py --apply --limit 25 --notify
```

- First apply of a drain campaign: `--limit 25`. If the requester confirms
  the closes look right, subsequent runs may use `--limit 100`, then
  `--limit 500`.
- The script HARD-STOPS (exit 2, zero closes) when eligible candidates
  exceed the ceiling (default 200). For a backlog drain, pass an explicit
  `--ceiling <N>` (e.g. `--ceiling 2500`) — only with a limit the requester
  asked for or confirmed.
- Exit 3 = some closes failed (rest succeeded — see stderr); exit 4 =
  sibling state unreadable, nothing closed — report, do not retry blindly.
- `--notify` posts a masked summary to #cs_chats; keep it on for applies.

Every close lands in `/var/log/close-stale-shadow.jsonl` (id, timestamp,
email) — reversible. ops-drain and dup-close read it as an exclusion source;
the needs-human digest deliberately does NOT, so a conversation the customer
reopens after a silent close surfaces there again (that is the recovery path,
not a bug).

## Reporting

Reply in-thread with: eligible count, closed_ok/failed, shadow-log path,
and the review-export path. Emails stay masked in EVERYTHING you output
(the script already masks its own output — do not un-mask from the shadow
log). Do not page anyone; this is a supervised, human-triggered drain.
