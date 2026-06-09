---
name: muso-outreach-reply-responder
description: |
  Triggered after the reply scanner detects a new B2B Ads reply. Decides if the
  reply needs answering, looks up the contact + company on NocoDB (read-only) for
  context, classifies the reply type against the proven playbook, and generates a
  single personalized draft whose ONLY goal is to book a call.

  Output is a SUGGESTION posted in Slack first. Never auto-send. Never auto-create
  a Gmail draft. The Gmail draft is created only after Fede or Aaron explicitly
  approves the suggestion (👍 / reply / explicit "draft it"). Posts the suggestion to
  #sales-alerts (C0ARQ021M40), inside the scanner's existing reply-detection thread
  for that prospect.

  Use when: a new B2B reply is detected, or Fede manually asks "draft a reply to <thread>".

  Triggers: "draft reply", "respond to this thread", "what should I send back",
  invoked by `muso-outreach-reply-scanner` on every new reply event.
depends-on:
  - muso-outreach-reply-scanner
  - muso-outreach-writer
  - muso-slack-formatter
metadata:
  version: "1.0"
  last-updated: "2026-06-04"
  references:
    - references/reply-playbook.md
---

# Muso Outreach Reply Responder

Turn an inbound B2B reply into a single, personalized, call-booking draft.

## Goal

**One outcome: get the prospect on a 15–20 minute call.** Every draft this skill produces should move the conversation toward `calendar.muso.ai` or a concrete proposed slot. No "send me a deck and I'll pass it along" surrender replies. No multi-paragraph educational essays. Move them toward time on the calendar.

## Sources of Truth

- **NocoDB** = sole source of contact + company enrichment. Read-only. Tables: `Contacts Intelligence` (by `Email`), `Company Intelligence` (by `Domain`).
- **`references/reply-playbook.md`** = distilled patterns from 39 real Aaron/Fede outbound replies (2026 YTD). Read this before generating ANY draft.
- **Gmail thread history** = the full back-and-forth on the thread. Pull it; never draft from the inbound message alone.

## Inputs (from scanner)

| Field | Source |
|---|---|
| `account` | a@ / ak@ / f@ — determines sender voice |
| `thread_id` | Gmail thread id |
| `from_email` | inbound sender |
| `from_name` | inbound sender display name |
| `subject` | normalized (strip Re:/Fwd:) |
| `inbound_body` | last inbound message body, decoded |
| `last_outbound_body` | most recent outbound from our side on the thread |
| `thread_age_days` | days since first send |
| `days_since_last_inbound` | freshness |

## Workflow

### Step 1 — Decide: answer or skip

Run the inbound through these gates IN ORDER. First match wins.

**SKIP (no draft, post `verdict: skip` to Slack with reason):**
1. **Pure OOO / auto-reply** — body matches `out of office`, `vacation`, `auto-reply`, `currently away`, `je suis absent`, no question, no actionable text. *Exception:* if it names a colleague to reach (`please contact X@`), that's a `referral`, NOT a skip — go to Step 2 with the new contact.
2. **Bounce / NDR** — `mailer-daemon`, `mail delivery failed`, `address not found`, `does not exist`.
3. **Hard no, no opening** — `not interested, please remove`, `unsubscribe`, `do not contact`, no follow-up question. Mark the NocoDB row for manual `Status = Closed-Lost` (READ-ONLY, so just flag in Slack for Fede to update).
4. **Pure ack with no question** — `thanks`, `got it`, `noted`, end of an already-closed loop. Skip unless it follows a meeting that needs confirmation.
5. **Already-booked confirmation** — `looking forward to <date>`, `see you <day>`, calendar invite accepted. Skip — call is on the books. (Exception: if outbound calendar slot was vague, draft a micro-confirm.)

**ANSWER (proceed to Step 2):**
Everything else, including:
- Scheduling language (`when are you free`, `let's set a time`, `send me a calendar`)
- Pricing questions (`how much`, `what does it cost`, `what's the budget`)
- Product / targeting questions (`how does it work`, `who is on the platform`, `what audience`)
- "Send me more info" / "I'd love to hear more" / "I'm down" / "go on"
- Soft-no with any opening (`not now but maybe Q3`, `circle back in a few months`)
- Referrals (`please contact X`)
- Quasi-objections that aren't hard nos (`we're not sure it's a fit because…`)
- Any inbound that ends with a question mark we haven't answered

### Step 2 — Identify who you're talking to

```bash
# Lookup contact in NocoDB Contacts Intelligence via the muso-nocodb skill
# (REST API, xc-token — there is NO MCP NocoDB connection). Read-only; never write.
# There is no bare "Email" column; match on "Valid Professional Email", else fall back to Domain.
bash scripts/nocodb-api.sh records.ls m9vsbijhrr9ddeu \
  --where "(Valid Professional Email,eq,<email>)" \
  --fields "First Name,Last Name,Title,Snov.io LinkedIn,Company Name,Domain"
# If not found by email, retry with --where "(Domain,eq,<domain>)".
# Then pull the linked Company Intelligence row (mvr6nmzcv7albxt) by Domain.
```

Pull from NocoDB:
- `Contacts Intelligence`: First Name, Last Name, Title, LinkedIn, Company (FK)
- `Company Intelligence` (join via Company FK or by `Domain`):
  - `Why Muso Ads Matters` (paragraph — the primary angle)
  - `Value Proposition` (what they sell)
  - `Target Customer` (who their buyer is)
  - `Industry` / `ICP`
  - any campaign-type hints (Offer / Brand Awareness / Sponsorship / For You / Email)

**If contact not in NocoDB:**
- Try matching by company domain only.
- If still nothing: flag in Slack notification (`⚠️ not in NocoDB`), degrade to a generic-playbook draft (no company-specific angle), and let Fede decide whether to send.

**If company is an existing customer (NocoDB Status = Customer, or in known-customer list — MWTM, Slate Digital, IK Multimedia, MWTM, Kali Audio):**
- DO NOT pitch. Generate a service / retention reply, not a cold-recovery. Flag with `🟡 EXISTING CUSTOMER` in Slack.

### Step 3 — Classify reply type

Map the inbound against the playbook's 7 types. Use both keyword signals AND intent (LLM judgment for edge cases).

| Type | Strongest signals | Playbook avg length |
|---|---|---|
| `scheduling_or_yes` | calendar links, "what time", "let's book", "Monday works" | 43 words |
| `pricing` | "how much", "cost", "budget", "CPM", "rate card" | 68 words |
| `question` | numbered questions, "how does X work", "who do you have" | 41 words |
| `interested_send_info` | "intrigued", "tell me more", "I'd love to hear more", "go on" | 74 words |
| `soft_no_or_later` | "not right now", "Q3 maybe", "circle back", "we pass" with opening | 45 words |
| `referral` | "adding X", "contact Y", "loop in Z" | 14 words |
| `other` | ultra-short acks, ops messages, confirmations | 20 words |

**Verbatim reference examples for each type** live in `references/reply-playbook.md`. ALWAYS read those before drafting — pattern-match, don't invent.

### Step 4 — Pick voice + sender account

| Account that received the inbound | Voice |
|---|---|
| `a@muso.ai` | Aaron, CEO. Short, declarative, often signs with phone. Numbered answers for numbered questions. |
| `ak@muso.ai` | Aaron, CEO (same voice as a@). |
| `f@muso.ai` | Fede, CMO. Longer, storytelling, threads in targeting specifics + scarcity. "Jumping in on Aaron's behalf" works when the thread started on a@. |

**Reply from the SAME account the inbound landed on** unless the inbound explicitly asks for the other person (e.g. "can Fede explain…").

### Step 5 — Generate the draft

#### Hard rules (every draft)

1. **Call-booking goal.** Every draft ends with one of:
   - `calendar.muso.ai` link close (visible hyperlink, default Gmail blue), OR
   - Two concrete proposed slots (e.g. "Tuesday 1pm ET or Wednesday 11am ET"), OR
   - Ultra-short slot question ("does Wednesday 10am work?")
   If you can't tie the close to a call, you're doing it wrong.
2. **Zero em-dashes, zero en-dashes.** Commas, periods, parens. No "—". No "–".
3. **`Muso.AI` hyperlinked exactly once** on its first mention, ONLY if this is a fresh contact path (referral handoff) or a soft-no recovery. On an active reply thread, drop the linked Muso.AI mention — they already clicked.
4. **Anchor line** `Muso is the daily home of 820,000 verified music pros.` — required ONLY in soft-no recovery and re-engagement drafts. Not in scheduling / pricing / question / interested replies (the playbook shows 0% anchor-line usage in active threads).
5. **Proof block** `Slate Digital, IK Multimedia, Mix With The Masters, and Kali Audio are in. Muso Ads is the invite-only advertiser side, role, credits, genre, geography, career-stage targeting.` — required ONLY on soft-no recovery and 14d+ stalled re-engagement. NOT on warm-active replies (playbook shows proof block at 0% in question/scheduling/interested types).
6. **Length matches type:**
   - scheduling → 5-45 words
   - other / ack → 6-25 words
   - question → 14-90 words (numbered answers match numbered inbound)
   - pricing → 24-140 words (always include concrete anchor: `$1,250/mo for launch partners` or current rate)
   - interested_send_info → 45-95 words
   - soft_no_or_later → 30-60 words
   - referral handoff → 10-30 words
7. **NocoDB middle-paragraph rule** (when company-specific angle is warranted, mostly `interested_send_info` and soft-no recovery): name the company explicitly, name a campaign type (For You / Offer / Brand Awareness), cite specific role-counts from NocoDB that match the buyer.
8. **No invented CTAs.** Closes come from the proven set only: `Happy to walk you through it`, `Worth 15 minutes on your calendar?`, `20 minutes to walk you through it: calendar.muso.ai`, `Two open slots: <X> or <Y>. Or grab any time: calendar.muso.ai`, `Let me know if you'd like to hear more.` See `references/reply-playbook.md` for full canonical set.

#### Output format

Slack post to `#sales-alerts` (`C0ARQ021M40`) in the existing scanner thread (or new thread if scanner posted top-level):

```
*Reply responder verdict*

Thread: <gmail-link|Subject>
From: *<Name>* (<Company>, <Title>)
Account: <a@/ak@/f@>
Reply type: *<type>*
NocoDB: ✅ enriched / ⚠️ not found / 🟡 existing customer

*Verdict:* answer / skip
<one-line reason if skip>

*Suggested draft (Aaron / Fede voice):*
> <draft body, exactly as I'd send>
>
> <signature>

*Rationale:* <1-2 lines on which playbook pattern this maps to + NocoDB angle pulled>
```

If `answer`: STOP HERE. Do NOT create the Gmail draft yet. Wait for Fede or Aaron
to approve the suggestion in Slack.

**Approval is authorized ONLY from Fede (`U07NF5A77E2`) or Aaron (`U7RP6HKUZ`).**
`#sales-alerts` is a shared channel — before treating ANY signal below as approval,
verify the Slack user ID of whoever sent it (the reaction author, or the message
sender's `user` id) is `U07NF5A77E2` or `U7RP6HKUZ`. A 👍 or `approved` from anyone
else is **not** approval: ignore it, keep waiting, and post once
`⚠️ Only Fede or Aaron can approve drafts — ignoring approval from <@user>.`

**Approval signals — any one *from Fede or Aaron* triggers draft creation:**
- 👍 reaction on the responder's Slack message
- Reply in thread: `draft it`, `send to drafts`, `looks good`, `approved`, `go`, or any clearly affirmative one-liner
- Explicit edit: Fede / Aaron rewrites the draft in thread — use the rewritten version, then create the draft

**Rejection signals (don't create, ask for direction):**
- 👎 or ❌ reaction
- Reply: `skip`, `no`, `redo`, `try again`, `different angle`, or a specific critique
- Silence > 24h — timeout, no draft created, log as `pending_decay`

**Only after explicit approval**, create the Gmail draft on the matching account (still no send):
```bash
gog gmail draft create \
  --account <a@/ak@/f@>muso.ai \
  --thread-id <thread_id> \
  --body-file <draft.html> \
  --label "B2B - Ads" \
  --label "muso-meta/reply-draft-YYYY-MM-DD"
```

After creating, post a confirmation in the same Slack thread: `✅ Gmail draft created on <account>. Eyeball before sending: <gmail-link>`.

### Step 6 — Never auto-send

- Drafts only. Fede or Aaron sends after eyeballing.
- Single draft per reply, no A/B options. Pick the right move and commit.
- If unsure between two paths (e.g. ultra-short ack vs longer educational), default to the SHORTER one (matches Aaron's voice baseline; longer is the exception).

## Edge Cases

| Case | Move |
|---|---|
| Inbound is on a thread where we already replied <24h ago and they came back fast | Treat as scheduling/yes, ultra-short, push to call. |
| Inbound has a clear scheduling question AND a pricing question | Answer pricing FIRST (1-2 lines, concrete anchor), then propose 2 slots. |
| Inbound is from a known competitor domain | Skip + flag for Fede. Don't auto-draft. |
| Inbound is a thread hijack (different person, same domain, different topic) | Treat as a NEW reply, look up the new contact in NocoDB, draft from scratch. |
| Inbound asks to talk to a specific human (`can I talk to your CEO`) | Reply from the requested account (e.g. switch to a@). If already on a@, just say `That's me, here's a slot: …`. |
| Inbound is from a contact who already booked + attended a call | Skip the scanner classification, this is post-meeting follow-up territory (separate flow, not this skill). |
| NocoDB returns multiple contacts at the same company | Use the inbound email's actual sender for personalization; mention other contacts only if inbound explicitly looped them in. |

## Examples

### Example A — Newfangled Audio "I'm down to hear more"

- Account: `a@`
- Type: `interested_send_info`
- NocoDB: ✅ — plugin maker, Elevate / Generate / Pendulate, buyer = mixing/mastering engineers + producers + session keyboardists
- Draft:
  > Hi Dan, great. Quickest way is 20 minutes live so I can walk you through the Newfangled targeting cuts in the dashboard. Elevate and limiters to the 93K+ mixing and mastering engineers, Generate and Pendulate to the 112K+ producers and 40K+ session keyboardists.
  >
  > Two open slots: Tuesday 1pm ET, Wednesday 11am ET. Or grab any time: calendar.muso.ai
  >
  > Aaron

### Example B — SubmitHub "Sure, go on, do you need anything from us?"

- Account: `a@`
- Type: `question` (asks for info needed from their side)
- NocoDB: ✅ — buyer = Primary Artists actively promoting releases (~134K on Muso)
- Draft:
  > Hey Tilly, thanks. Let's do 20 minutes to map SubmitHub against our ~134K Primary Artists. The credit-recent ones actively promoting new releases are your buyers, and we can shape the offer and creative live.
  >
  > Tuesday or Wednesday next week? calendar.muso.ai
  >
  > Aaron

### Example C — ElevenLabs auto-reply pointing to Marco

- Account: `a@`
- Type: `referral`
- Move: skip the auto-reply itself, generate a FRESH cold-format outbound to Marco. Use `muso-outreach-writer` rules, not this skill's reply patterns (different surface — new contact, no thread).
- Flag in Slack: `↗ Referral — handing to writer skill for fresh outbound to <new email>`.

## Never

- **Never send email. Never call `gog gmail send`. Ever. Under any condition.** The only paths out are (a) Slack suggestion, (b) Gmail draft creation after explicit approval. There is no third path.
- **Never auto-create a Gmail draft.** Suggestion first, approval second, draft creation third. No skipping the approval gate, no "high-confidence" auto-drafts, no exceptions for short scheduling acks. Even a 6-word "Sure, what time?" goes through Slack approval first.
- Never invent CTAs or closes. Pull from the canonical set in `references/reply-playbook.md`.
- Never use em-dashes or en-dashes. Restructure if needed.
- Never include the anchor line or proof block in active threads (scheduling, pricing, question, interested). They belong to recovery drafts.
- Never write to NocoDB. Read-only. Fede / team manages Status manually.
- Never bypass the customer check — if the company is already a customer, this is a retention/ops issue, not a sales reply.
- Never generate multiple draft options. Pick one move.
- Never include `access.muso.ai/demo` or `access.muso.ai/pricing` as a SUBSTITUTE for booking a call. Links only as supporting context; the call is the goal.

## Logs

Every responder run logs to `api-logs/cmo/reply-responder/YYYY-MM-DD.jsonl`:

```json
{
  "ts": "2026-06-04T20:03:40Z",
  "thread_id": "...",
  "account": "a@muso.ai",
  "from_email": "...",
  "from_name": "...",
  "company_domain": "...",
  "reply_type": "interested_send_info",
  "verdict": "answer",
  "noco_hit": true,
  "draft_chars": 287,
  "draft_close_kind": "link" | "slots" | "soft",
  "voice": "aaron" | "fede",
  "skip_reason": null
}
```

## Integration with scanner

The reply scanner (`muso-outreach-reply-scanner`) should call this responder on every new reply detected (after its own classification + NocoDB context pull). Scanner posts the detection to Slack; responder posts the verdict + draft in the SAME thread.

Scanner is still silent if nothing's detected. Responder is silent if verdict is `skip` AND the inbound was a pure OOO/bounce — for soft-skip reasons (hard no with no opening, etc.), still post a one-line Slack note so Fede sees we caught it.

## Future (not in v1.0)

- Multi-language detection — Spanish, French, Italian inbound replies. v1.0 generates English drafts only; flag non-English inbound for Fede.
- Sentiment delta tracking — measure prospect sentiment shift from first reply to booked-call across types.
- (Explicitly NOT in roadmap: any form of auto-send. Drafts only, suggestion-gated, forever.)
