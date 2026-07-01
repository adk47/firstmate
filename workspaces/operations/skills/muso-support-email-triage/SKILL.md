---
name: muso-support-email-triage
description: |
  Hourly TRIAGE of the support@muso.ai Gmail inbox (last ~65 min). Classifies each
  new thread as Caroline-can-handle vs needs-a-human using Caroline's support
  doctrine, and returns a glanceable digest as the final assistant message for the
  cron to deliver to #cs_chats. Read-only — NEVER sends, drafts, labels, or tickets.
allowed-tools: Read, exec
---

# muso-support-email-triage

Once per hour the operations agent reads new mail in the **support@muso.ai** Gmail
inbox (last ~65 min), classifies each thread as *Caroline-can-handle* vs
*needs-a-human* using Caroline's existing support doctrine, and returns a glanceable
digest as its FINAL assistant message. A cron entry delivers that text to `#cs_chats`.

**v1 is TRIAGE ONLY. Nothing is ever sent to a customer.**

## When to use

Invoked exclusively by the support-email-triage cron entry in `cron-jobs.json`.
Slack delivery is routed by the cron entry's `delivery.to` field; the skill itself
never picks a channel. Do not run this skill ad hoc to "answer" a customer — its only
output is an internal triage digest.

## Hard rules

- **TRIAGE ONLY — read-only.** NEVER send an email, create or modify a draft, change
  labels, archive, or call `create_ticket`. The skill only reads the inbox, classifies,
  and returns text. v1 takes zero write actions of any kind.
- **Never post to Slack directly.** Return the digest as the final assistant message;
  the cron runner delivers it to `#cs_chats`. Double-posting is a regression.
- **Counts, subjects, senders, and links are deterministic** — they come only from the
  fetch step (`${WORKDIR}/emails.json`). Only the per-thread `description`, `verdict`,
  and `reason` are LLM-authored. NEVER invent a thread, a count, a subject, a sender, or
  a link. If you cannot map a verdict to a real `threadId` from the fetch, drop it.
- **No em-dashes in the output.** `format-digest.sh` normalizes any em/en-dash to a
  hyphen mechanically; do not rely on yourself to avoid them, but do not add them either.
- **Scrub `$WORKDIR` at the end.** Customer email bodies (PII) are written to disk under
  `$WORKDIR`. `preflight.sh` installs an INT/TERM trap that removes it on interrupt or
  cron timeout; `format-digest.sh` removes it on the normal success path. If the run aborts
  between fetch and format, the agent MUST still `rm -rf "$WORKDIR"`.

## Workflow

Run the entire pipeline (preflight -> fetch -> classify -> format) in a SINGLE shell
session so the exported `WORKDIR` is visible to every later step.

### Phase 0 — Preflight (deterministic)

**First, enter the skill directory** — every `scripts/…` path below is relative to it.
Run this verbatim as the first line of the single shell session; do not improvise the
path. This is a workspace-native skill (it is NOT mirrored into any openclaw
managed-skills tier), so a guessed managed-skills location does not exist on disk, and a
failed `cd` there is the single early tool error that makes openclaw mark the whole run
failed and silently suppress the `#cs_chats` delivery.

```bash
cd /opt/hydra/workspaces/operations/skills/muso-support-email-triage || { echo "preflight failed: skill dir not found"; exit 1; }
```

**Then, source** `scripts/preflight.sh` (do not run it as a subprocess — the `WORKDIR`
export must survive into the rest of the pipeline):

```bash
source scripts/preflight.sh
```

Preflight (a) verifies `support@muso.ai` is authenticated in `gog`, and (b) creates a
`mktemp -d` `WORKDIR` with an INT/TERM cleanup trap. On any preflight failure it prints a
single `preflight failed: ...` line and returns non-zero. **If preflight fails, emit that
exact line as your final assistant message and STOP.** Do not fetch, classify, or
fabricate a digest.

In particular, until the mailbox is provisioned preflight will print:

```
preflight failed: support@muso.ai not authenticated in gog (run: gog auth add support@muso.ai)
```

That is the expected, safe behavior pre-provisioning — surface it and stop.

### Phase 1 — Fetch (deterministic)

```bash
scripts/fetch-support-inbox.sh   # writes ${WORKDIR}/emails.json
```

Fetches the last `${SUPPORT_TRIAGE_WINDOW_MIN:-65}` minutes of inbox mail for
`support@muso.ai` via `gog` (bounded with Gmail's `after:<epoch-seconds>` operator —
`newer_than:` has no minute unit), dedupes by `threadId` (one entry per thread, keeping the most-recent message's
subject/from/date), and writes `${WORKDIR}/emails.json` as an array of
`{threadId, from, subject, date, body_excerpt, url}`. An empty inbox writes `[]`. You do
NOT build the Gmail URL or the body excerpt yourself — the script does, deterministically.

### Phase 2 — Classify (LLM)

1. Read `${WORKDIR}/emails.json`.
2. Read Caroline's support doctrine to ground each verdict (absolute paths — you are
   `cd`'d into the skill dir, so repo-relative paths will not resolve):
   - every `*.md` under `/opt/hydra/workspaces/support/reference/` — list the directory
     and read them all (do not rely on a hardcoded set; new KB files such as
     `api-access.md`, `founding-member.md`, and `orders-and-fulfillment.md` land here), and
   - the **Escalation Ladder** in `/opt/hydra/workspaces/support/SOUL.md` (the four-step ladder:
     answer from reference docs -> self-service guidance -> troubleshooting walkthrough ->
     flag for a human).
3. For each thread decide `verdict ∈ {caroline, human}`:
   - `caroline` — answerable from the reference docs, self-service guidance, or a
     troubleshooting walkthrough (ladder steps 1-3). Analytics/streams are **no longer a
     special carve-out** (the migration storyline was retired): Caroline handles the
     plan/seat basics herself, but genuinely-off data is a data-integrity
     `analytics-followup` ticket — classify those as `human` below.
   - `human` — ladder step 4 only: a human action is genuinely required (refund
     processing, data correction, account recovery, bug investigation, or anything that
     needs a write or a ticket).
4. For each thread produce:
   - `description` — one line: what the sender wants.
   - `reason` — one line. For `caroline`, cite the KB area, e.g. `KB: subscriptions-and-billing`.
     For `human`, cite the action type, e.g. `refund processing`.
5. Write `${WORKDIR}/verdicts.json` as
   `[{threadId, verdict, description, reason}]`. Every `threadId` MUST exactly match an
   entry in `emails.json`. Do not invent rows, and include one row per thread in
   `emails.json` (no more, no fewer).

### Phase 3 — Format + emit (deterministic)

```bash
scripts/format-digest.sh   # joins emails.json + verdicts.json, prints the digest, scrubs $WORKDIR
```

`format-digest.sh` joins the two files by `threadId`, computes the counts, and prints the
Slack mrkdwn digest to stdout. **Emit that stdout verbatim as your final assistant
message.** Two outcomes:

- **No new mail** — the script prints exactly `NO_REPLY` (uppercase, nothing else). Emit
  that and stop; the cron silently completes with no Slack post.
- **Mail present** — the script prints a header plus one bullet per thread (capped at ~25
  with a "...and N more" overflow line), e.g.:

  ```
  :envelope: *support@ triage* · last 1h · 3 new · 2 Caroline-can-handle · 1 need a human
  • <https://mail.google.com/mail/u/?authuser=support@muso.ai#all/THREAD|Subject> - they want X · :white_check_mark: Caroline-can-handle (KB: subscriptions-and-billing)
  • <https://mail.google.com/mail/u/?authuser=support@muso.ai#all/THREAD|Subject> - they want Y · :raising_hand: needs a human (refund processing)
  ```

The script **fails loud** (exits non-zero with a clear message) if `verdicts.json` is
missing or malformed, or if its `threadId`s do not reconcile with `emails.json`. If it
fails, fix Phase 2 (re-derive `verdicts.json` from `emails.json` only) and re-run — never
hand-assemble a digest, because counts and links must come only from the fetch.

On success the script removes `$WORKDIR` itself. If you abort before reaching this step,
run `rm -rf "$WORKDIR"` manually to scrub the customer PII.

## Environment

- `GOG_KEYRING_PASSWORD` — required by `gog`; already present in the gateway service env
  (`/etc/openclaw/main.env`) and inherited by the operations runtime. Do NOT set it in the
  skill (the b2b-reply-scanner and weekly-google-token-refresh crons already rely on the
  inherited value).
- `SUPPORT_TRIAGE_WINDOW_MIN` — fetch window in MINUTES (integer); the fetch script turns
  it into a Gmail `after:<epoch-seconds>` bound. Default `65` (the hourly cron, with a
  5-minute overlap so a thread can't fall between runs — a thread landing inside the
  overlap may appear in two consecutive digests, which is accepted in v1). Override only
  for backfill/testing.
