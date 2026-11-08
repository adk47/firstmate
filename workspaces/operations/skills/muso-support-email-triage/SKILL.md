---
name: muso-support-email-triage
description: |
  Hourly TRIAGE of the support@muso.ai Gmail inbox (last ~65 min). Classifies each
  new thread as Caroline-can-handle vs needs-a-human vs spam/no-action using Caroline's
  support skills + doctrine (Caroline-can-handle = she owns first contact, including
  filing the ticket her skill is designed to file), and returns a glanceable digest as
  the final assistant message for the cron to deliver to #cs_chats. Read-only — NEVER
  sends, drafts, labels, or tickets.
allowed-tools: Read, exec
---

# muso-support-email-triage

Once per hour the operations agent reads new mail in the **support@muso.ai** Gmail
inbox (last ~65 min), classifies each thread as *Caroline-can-handle* vs
*needs-a-human* vs *spam/no-action* using Caroline's existing support skills and
doctrine, and returns a glanceable digest as its FINAL assistant message. A cron entry
delivers that text to `#cs_chats`. The classifier scores who owns **first contact**:
filing a ticket or running a gated self-service write is Caroline handling the thread,
not a human handoff — so almost every genuine customer request is *Caroline-can-handle*,
and only threads she structurally cannot start (legal, security, sales, vendor/B2B) are
*needs-a-human*.

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

Preflight first stops when `/etc/hydra/gmail-readers.disabled` exists (the kill file shared by every support@
Gmail reader, so a deploy that re-enables the cron cannot restart Gmail reads). It then (a) verifies `support@muso.ai` is authenticated in `gog`, and (b) creates a
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
   - the **skills Caroline actually runs** — list `/opt/hydra/workspaces/support/skills/`
     and read each `SKILL.md` frontmatter (`description` + `triggers`). This is the
     authoritative map of what Caroline handles at first contact: credit verification,
     credit removal, profile claim/consolidate/dedupe, track dedupe, order/plaque
     fulfillment, refund retention, and the generic `action-request` ticket filer. Do not
     rely on memory — new skills land here.
   - every `*.md` under `/opt/hydra/workspaces/support/reference/` — list the directory
     and read them all (do not rely on a hardcoded set; new KB files such as
     `api-access.md`, `founding-member.md`, and `orders-and-fulfillment.md` land here), and
   - the **Escalation Ladder** and **Resolution lifecycle** in
     `/opt/hydra/workspaces/support/SOUL.md`.
3. For each thread decide `verdict ∈ {caroline, human, spam}`. The question is **who owns
   FIRST CONTACT**, not whether a human ever touches the request downstream. Filing a
   ticket and running a gated self-service write are Caroline's DESIGNED terminal actions
   (SOUL Escalation Ladder step 4 and the Resolution lifecycle) — they are Caroline
   handling the thread, NOT a human handoff.
   - `caroline` — any thread whose first contact is a Caroline skill: a KB answer (ladder
     steps 1-3), a gated self-service write (`credits_verify`, `remove_credits`,
     `profiles_claim_self`, `profiles_consolidate`, `order_address_update`,
     `founding_buyback_link`), OR filing the recommend-approve / needs-human / intake
     ticket her skill is designed to file. This is the **default for any genuine customer
     request**. It explicitly includes: **credit verification** (proof intake +
     recommend-approve ticket — she never rejects), credit removal, profile
     claim/consolidate/dedupe, track dedupe, refund/cancellation (the `refund-retention`
     3-gate flow), **analytics/streams genuinely off** (she files the `analytics-followup`
     data-integrity ticket herself and emits `[[PRIORITY]]` — that IS her handling; it is
     no longer a human carve-out), profile data correction, order/plaque fulfillment,
     founding-member Q&A + paid buy-back, account-email-change and account/profile deletion
     or removal intake for the customer's own Muso account/profile, and general how-to/FAQ.
     When she files a **needs-human** ticket (e.g. a credit-theft
     contradiction she discovered, or a cross-owner merge), she still OWNED first contact —
     that is `caroline`, because a human never had to read the raw email first.
   - `human` — ONLY threads Caroline structurally cannot even START, where a human must
     read the raw email first: legal / rights / IP demands (DMCA, subpoena,
     cease-and-desist, licensing or chain-of-title disputes, official legal/visa
     documentation); security / account-compromise / fraud / law-enforcement (including a
     security event on the support mailbox itself); pure sales or commercial negotiation
     (enterprise / full-catalog-API deals, Business-tier quotes — NOT a founding-member
     self-serve question); vendor / B2B business development (partnership, data-licensing,
     press, recruiting, AP invoices — NOT the Prodigi fulfillment lane, which is
     `caroline`); Google de-indexing; formal legal/privacy-rights deletion demands; and a
     disputed cross-account claim reversal (removing SOMEONE ELSE'S claim). **"Needs a
     write or a ticket" is NOT a human trigger.**

     **Still classify privacy requests `human` — do not try to route them yourself.** Phase 2.5
     hands every `human` thread to the GDPR erasure register, which files the ones it owns and
     pages a human only for a refusal it raises itself. Your job is the classification; the
     routing is code.
   - `spam` — not a support request at all, and no human action either: cold marketing /
     promotions (a fuel-card promo), SEO/link-building pitches, unsolicited app / TestFlight
     invites, newsletters; and system-noise (mailer-daemon / delivery-failure bounces,
     auto-replies, out-of-office, read receipts, list confirmations, automated
     request-received receipts, internal test mail, Intercom/tooling setup notices). Spam
     is excluded from BOTH work queues and NEVER counts as a Caroline win.

   Historical wording intentionally superseded by the active rules above; do not classify
   from this block:

   ```
     founding-member Q&A + paid buy-back, account-email-change and account-deletion intake,
     and general how-to/FAQ. When she files a **needs-human** ticket (e.g. a credit-theft
     `caroline`); an irreversible account/profile deletion or Google de-indexing; and a
   ```

   Worked examples (the two that were being classified wrong):
   - "Fwd: verification of my songs..." / any "Additional Information Required for Credit
     Submission" reply → `caroline` (`customer-credit-verification`): she verifies
     ownership, reviews the proof, and approves the corroborated case or files a
     recommend-approve ticket. NOT `human`.
   - "Save up to 10p per litre on fuel with POWK" → `spam` (cold promo). NOT `caroline`,
     NOT `human`.
4. For each thread produce:
   - `description` — one line: what the sender wants.
   - `reason` — one line. For `caroline`, cite the skill or KB area, e.g.
     `customer-credit-verification` or `KB: subscriptions-and-billing`. For `human`, cite
     the residue type, e.g. `legal / rights` or `vendor / B2B`. For `spam`, cite the noise
     type, e.g. `cold marketing` or `delivery-failure bounce`.
5. Write `${WORKDIR}/verdicts.json` as
   `[{threadId, verdict, description, reason}]` with `verdict ∈ {caroline, human, spam}`.
   Every `threadId` MUST exactly match an entry in `emails.json`. Do not invent rows, and
   include one row per thread in `emails.json` (no more, no fewer).

### Phase 2.5 — Route privacy requests to the erasure register (deterministic)

```bash
/opt/hydra/scripts/gdpr-triage-bridge.py \
  --emails "$WORKDIR/emails.json" --verdicts "$WORKDIR/verdicts.json" \
  --out "$WORKDIR/bridge.json"
```

**Why this step exists.** The `human` class above covers "formal legal/privacy-rights deletion
demands" and "Google de-indexing" — requests the GDPR erasure pipeline already owns, files,
decides and answers with a statutory letter. Before this step every one of them paged a human,
including the ones the register already held and was working: on 2026-11-07 the digest paged a
human for the Jani López Torregrosa Art.17 request, which had been register #399 since
2026-11-06T20:13Z and had already had two of its four pages hidden.

The bridge asks the register first, then the pipeline's own classifier, and records exactly one
outcome per `human` thread:

| outcome | what happened | what the digest shows |
|---|---|---|
| `registered` | the register already holds this thread | the register number and the register's own next action — **no human page** |
| `filed` | it did not, and the classifier says the register can act | the register number and the register's own next action — **no human page** |
| `refused` | the pipeline was asked and refused | **a human page naming the pipeline's own refusal, verbatim** |
| `not_privacy` | the classifier says this is not a privacy request | the triage's own `human` verdict and reason stand |

It decides nothing itself: the class comes from `gdpr_pipeline.intake.classify` (the ONE copy of
the rules, read from `scripts/legal-intake.py` by AST), the date from the support ledger's
`first_seen` (or the triage's own UTC date when the ledger has not caught up), and the identity
from the pipeline's own decide step. It never sends anything and never invents copy — the
statutory letter text has standing approval and is sent by `gdpr-pipeline-tick`.

**A read failure is never a verdict.** An unreadable register, an unreadable classifier or an
undatable request is a `refused` that names itself, never a silent "not registered" (which would
file a duplicate) and never a silent pass. The bridge exits 2 when any `human` thread could not
be routed; the digest still renders and those threads page a human with the reason.

If the bridge did not run at all, `format-digest.sh` still pages every `human` verdict and says
so on stderr — the digest is the safety net, not the bridge.

### Phase 3 — Format + emit (deterministic)

```bash
scripts/format-digest.sh   # joins emails.json + verdicts.json + bridge.json, prints the digest, scrubs $WORKDIR
```

`format-digest.sh` joins the two files by `threadId`, computes the counts, and prints the
Slack mrkdwn digest to stdout. **Emit that stdout verbatim as your final assistant
message.** Two outcomes:

- **No new mail** — the script prints exactly `NO_REPLY` (uppercase, nothing else). Emit
  that and stop; the cron silently completes with no Slack post.
- **Mail present** — the script prints a header plus one bullet per thread (capped at ~25
  with a "...and N more" overflow line), e.g.:

  ```
  :envelope: *support@ triage* · last 1h · 3 new · 1 Caroline-can-handle · 1 need a human · 1 spam/no-action
  • <https://mail.google.com/mail/u/?authuser=support@muso.ai#all/THREAD|Subject> - they want X · :white_check_mark: Caroline-can-handle (customer-credit-verification)
  • <https://mail.google.com/mail/u/?authuser=support@muso.ai#all/THREAD|Subject> - they want Y · :raising_hand: needs a human (legal / rights)
  • <https://mail.google.com/mail/u/?authuser=support@muso.ai#all/THREAD|Subject> - they want Z · :wastebasket: spam/no-action (cold marketing)
  ```

  The `· %d spam/no-action` header segment appears only when at least one thread is spam.

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
