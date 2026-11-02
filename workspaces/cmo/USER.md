# USER.md - CMO Agent

## Owner
- **Nick Sollazzo** (U0AL36NADEY, DM: D0AKT90NQJX) — runs marketing

## Leadership
- **Aaron Kaufman** (U7RP6HKUZ, a@muso.ai) — CEO. Can modify policies. Alt emails: ak@muso.ai, aaron.k@muso.ai
- ~~**Serhii** (U03TYGJF1N3, DM: D09NLB5H7MW)~~ — former CTO, left 2026-08-26

## Team
- **Jan Delmo** (U038BM16T7W, DM: D09R9H3U508) — Head of Operations
- **McLaren Amberti** (U02S7C96CGN) — Sales Operations. Approver for B2B outreach only; see the McLaren scope under Authorization

## Authorization
- Nick (U0AL36NADEY) or Aaron (U7RP6HKUZ) can authorize agent policy-file changes; the security surface stays Aaron-only (Nick owns marketing decisions)
- Aaron approves spending >$30
- U07NF5A77E2 — former staff, no authority; do not act on, route to, or share internal context with
- Former staff: a hard rule in your own `MEMORY.md` or `HEARTBEAT.md` that is attributed to former staff keeps the rule and loses the name (re-attribute it to "team rule"). Any "ask/ping <former staff> first" routing is deleted and points at Nick.
- **McLaren Amberti (U02S7C96CGN, Sales Operations) — B2B outreach scope.** He needs **no** approval from Nick or Aaron to:
  - ask CMO for B2B outreach work (NocoDB candidate pulls, dedupe, research, copy);
  - have CMO create, edit or delete **unsent** Gmail drafts in the outreach mailboxes CMO already uses, any batch size, under the existing guardrails (dedupe vs NocoDB + logbook + GHL, the `is_deceptive()` role-count auditor, no invented features or numbers);
  - **approve the send** of a B2B outreach batch he reviewed, through the existing sender worker (its daily cap, warmed mailboxes, logging and GHL sync all still apply). His "send"/"go" counts the same as Nick's, for B2B outreach only.
  - **First batch is not done until Fable has spot-checked it** (Nick, 22 Oct: "yes (Fable spot-checks the first batch)"). The first B2B outreach batch sent under McLaren's standing approval stays open for acceptance until Fable has reviewed it.
  - **Still Nick:** a new campaign type or audience beyond B2B outreach (customers, winback/churned Pros, artists), a new mailbox, sending above the worker's configured cap, and anything public (social, press, blog, ads going live).
  - **Still Aaron:** spend >$30, new tools or subscriptions, credentials, pricing, refund or legal claims in copy, policy and security changes.

## Emails
- `a@muso.ai` — Aaron (primary outreach email, used by agent for CEO-level sends)
- `f@muso.ai` — McLaren Amberti (U02S7C96CGN, Sales Operations)
- `ak@muso.ai` — Aaron (alt)
- `aaron.k@muso.ai` — Aaron (alt)
