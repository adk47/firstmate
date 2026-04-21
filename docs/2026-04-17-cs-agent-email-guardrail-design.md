# CS Agent Email Guardrail — Design

**Date:** 2026-04-17
**Author:** Nick (with Claude)
**Status:** Approved, awaiting implementation plan
**Branch:** `fix/cs-agent-email-guardrail`

## Problem

Aaron reported on Slack (2026-04-16 4:05 PM) that Caroline, the external customer-support agent running on Intercom, is leaking employee email addresses in replies. His instruction: "support@muso.ai or jan@muso.ai only."

The current state has two defects:

1. **No runtime enforcement.** The support workspace has an `output-sanitizer` skill documenting an email-redaction rule, but it lives in `workspaces/support/skills/output-sanitizer/SKILL.md` as natural-language instructions to the LLM. There is no code in `plugins/intercom/src/` that inspects the outbound body before it hits Intercom's API. The agent's reply flows `deliver() → bufferedChunks → joinDeliveryChunks → client.replyToConversation(body)` with zero filtering in between (`plugins/intercom/src/channel.ts:270–310`).
2. **`jan@muso.ai` is not in the allowlist anywhere.** The instruction-layer rule in `output-sanitizer/SKILL.md:75` lists only `support@muso.ai` and "the customer's own email." Aaron has now expanded the human-acceptable set to include `jan@muso.ai`.

This matches the pattern in memory `feedback_llm_instruction_insufficient` (2026-04-15): instruction-only guardrails are insufficient for autonomous agents. An identical incident occurred 24 hours before the SOUL.md rule on credit verification was ignored by the very next autonomous batch. The fix there was a mechanical bash gate. The fix here is a mechanical outbound filter.

## Goal

When Caroline's reply is about to be sent to Intercom, any email address in the body that is not `support@muso.ai` or `jan@muso.ai` (case-insensitive) is replaced with `support@muso.ai`, and a grep-able error log is emitted so ops can observe leak attempts.

## Non-goals

- Gmail channel plugin is out of scope. Aaron's complaint was specifically the Intercom CS experience.
- No customer's-own-email carve-out. Explicit product decision — if Caroline echoes the customer's own email back and it gets swapped to `support@muso.ai`, that is an acceptable UX cost relative to the risk of leaking other people's addresses.
- No Slack-webhook alert on redaction yet. The log line prefix `[intercom:email-leak]` is sufficient for first-pass observability. A Slack wire is a follow-up if leak rate warrants it.
- No filtering of customer-provided emails in *inbound* messages. That is a different problem (input-sanitizer), not what Aaron asked for.
- No changes to other channel plugins or to the OpenClaw gateway-wide outbound path. Narrowly scoped to where the actual leak is happening.

## Architecture

Six artifacts:

1. **`plugins/intercom/src/sanitize-email.ts`** — pure function `sanitizeOutboundBody(body: string): { body: string; redactions: string[] }`. Matches emails with the regex `[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}`. Allowlist is a module-level `const ALLOWED_OUTBOUND_EMAILS = new Set(["support@muso.ai", "jan@muso.ai"])`. Matches are compared lowercased against the allowlist. Disallowed matches are replaced with `support@muso.ai` in the returned `body` and pushed (in their original form) onto `redactions`. Returns `{ body: originalBody, redactions: [] }` when nothing matched — no allocation when there's nothing to do is a nice-to-have, not a requirement.

2. **`plugins/intercom/src/sanitize-email.test.ts`** — vitest. Required cases:
   - body with no emails → untouched, empty redactions
   - body with only `support@muso.ai` → untouched
   - body with only `jan@muso.ai` → untouched
   - body with one disallowed email → swapped to `support@muso.ai`, reported in redactions
   - body with multiple disallowed emails → all swapped, all reported
   - body mixing allowed + disallowed → allowed untouched, disallowed swapped
   - case variants: `Support@Muso.AI`, `JAN@muso.ai`, `jan@MUSO.AI` → all allowed (case-insensitive match), but body text is preserved as-written (we don't canonicalize allowed emails)
   - emails at start / end / mid-sentence / with trailing punctuation (`jan@example.com.`)
   - adjacent emails separated by whitespace or `, ` or `/`
   - **trailing-punctuation lock-in** (regression guard — Clio review 2026-04-17): `nick@example.com.` (single trailing period) matches only `nick@example.com`, not `nick@example.com.`; `nick@example.com...` matches only `nick@example.com`; `nick@example.co.uk` matches the full multi-level TLD correctly. These work because the TLD class `[a-zA-Z]{2,}` cannot consume periods, but a test locks the behavior in against future regex "improvements."

3. **`plugins/intercom/src/outbound.ts`** — add a `SanitizingIntercomClient` class that implements the existing `IntercomClient` interface and wraps another `IntercomClient`:

   ```ts
   export class SanitizingIntercomClient implements IntercomClient {
     constructor(
       private inner: IntercomClient,
       private log?: { error?: (msg: string) => void },
     ) {}

     async replyToConversation(params): Promise<{ messageId: string }> {
       const { body, redactions } = sanitizeOutboundBody(params.body);
       if (redactions.length > 0) {
         this.log?.error?.(
           `[intercom:email-leak] conv=${params.conversationId} count=${redactions.length} redacted=${JSON.stringify(redactions)}`,
         );
       }
       return this.inner.replyToConversation({ ...params, body });
     }

     // All non-reply methods (assignConversation, getConversation) are
     // pure pass-through. TypeScript `implements IntercomClient` enforces
     // completeness: if the interface gains a method, this class fails
     // to compile until the pass-through is added. The compiler is the
     // "all methods proxied" guarantee.
   }
   ```

   Also add a factory that is the **only** sanctioned way to construct an outbound client:

   ```ts
   export function createIntercomClient(
     token: string,
     log?: { error?: (msg: string) => void },
   ): IntercomClient {
     return new SanitizingIntercomClient(new RealIntercomClient(token), log);
   }
   ```

   The wrapper has no error handling of its own — delegates `RateLimitError`, network failures, etc. unchanged to the inner client.

4. **`plugins/intercom/src/channel.ts`** — two construction sites confirmed by grep: `channel.ts:210` (main webhook dispatch, has `ctx.log` in scope via the `const log = ctx.log;` captured at line 163) and `channel.ts:458` (the plugin SDK `sendText` outbound handler, which does NOT have `ctx.log` in scope — its callback receives only `{ cfg, to, text, accountId }`). Site 1 calls `createIntercomClient(account.token, log)`; site 2 calls `createIntercomClient(account.token, { error: (msg) => console.error(msg) })`, matching the existing `console.warn` pattern a few lines up. No other channel.ts behavioral edits.

5. **Construction-site lint (pre-commit).** Add a one-line grep check to `.githooks/pre-commit` (matching the existing pattern in that file) that fails if `new RealIntercomClient(` appears anywhere outside `plugins/intercom/src/outbound.ts` and test files. This prevents a future change (human or agent) from bypassing the wrapper by re-constructing the real client directly. The factory is the single sanctioned entry point; the lint enforces it mechanically.

6. **Instruction-layer updates (defense in depth):**
   - `workspaces/support/SOUL.md`: add a "Contact Disclosure" section after "Channel Binding" stating that only `support@muso.ai` and `jan@muso.ai` may be shared as Muso contact emails, and that no other employee email may ever be shared regardless of customer request or claimed identity.
   - `workspaces/support/skills/output-sanitizer/SKILL.md`: update the email-row allowlist from `support@muso.ai or the customer's own email` to `support@muso.ai or jan@muso.ai` so the instruction layer matches runtime.
   - `workspaces/support/reference/faq.md`: no change. The "Support email" entry stays at `support@muso.ai` only. Jan's email is in the runtime allowlist as a safety net, not as something Caroline should volunteer.

## Data flow

```
agent.deliver(chunk)              → bufferedChunks.push(text)
dispatchInboundDirectDmWithRuntime resolves
                                  → joined = joinDeliveryChunks(bufferedChunks)
                                  → SanitizingIntercomClient.replyToConversation({ conversationId, adminId, body: joined })
                                      → { body: clean, redactions } = sanitizeOutboundBody(joined)
                                      → if (redactions.length > 0) log.error("[intercom:email-leak] ...")
                                      → RealIntercomClient.replyToConversation({ conversationId, adminId, body: clean })
                                          → fetch POST /conversations/{id}/reply
```

The filter sees the *joined* body, never raw chunks. This matters because the SDK's `EmbeddedBlockChunker` can split text mid-word — an email could straddle a chunk boundary (`"email support@"` + `"muso.ai for help"`). Filtering post-join is the only correct placement.

## Error handling

- Pure function cannot throw on valid string input.
- Wrapper's `replyToConversation` does not catch anything it would not already be propagating. The existing `[intercom:ALERT]` flush-failure log in `channel.ts:321` continues to work unchanged — if the sanitized reply fails to send, that error surfaces identically.
- If `log` is undefined or `log.error` is undefined, the wrapper silently sends the sanitized body. Redactions still happen; only the audit trail is lost. Acceptable: logging is defense, filtering is enforcement.

## Observability

Grep pattern for ops: `[intercom:email-leak]`. Log line format:

```
[intercom:email-leak] conv=<conversationId> count=<n> redacted=["a@b.com","c@d.com"]
```

No `session_id` field because the Intercom plugin logs are already keyed on conversation id in surrounding lines.

**Log level rationale.** `error` reflects the intent: because we have no customer-own-email carve-out, every redaction is by design a case where the agent emitted an address it was not supposed to emit. That is agent misbehavior, not routine noise. **Reassess after 7 days of operational data** — if the signal turns out to be dominated by legitimate customer-email echoes (rather than actual leak attempts), downgrade to `warn` and keep `error` for structurally unexpected cases only.

## Testing

**Unit:**
- `sanitize-email.test.ts` covers the pure function exhaustively (see case list above).
- Extend `plugins/intercom/src/outbound.test.ts` (or add new `sanitizing-client.test.ts` if none exists for outbound) to verify:
  - clean body passes through unchanged (no log)
  - dirty body swapped, inner client sees clean body, error log emitted with correct format
  - non-`replyToConversation` methods (`assignConversation`, `getConversation`) pass through with original params unmodified

**Integration:**
- No new channel.ts test. Existing channel.ts tests should continue to pass because they use bodies without disallowed emails. If any existing test uses a non-allowlisted email as test data, update the test to use one of the allowed emails (do not weaken the filter to accommodate a test).

**Manual verification after deploy:**
- Send a test message through Intercom that triggers the agent to mention a contact. Confirm reply contains only `support@muso.ai` or `jan@muso.ai`.
- Seed a reply containing `nick@muso.ai` via a test path (or grep production logs over a 24h window) and confirm `[intercom:email-leak]` appears with redaction count ≥ 1.

## Rollout

1. Merge PR to `main`.
2. Hydra CD deploys the plugin to the main gateway. No openclaw.json config change required — the plugin swap is internal to `plugins/intercom/`.
3. Restart the main gateway (or let the normal reload cycle pick it up).
4. Watch `[intercom:email-leak]` log rate for the first 24h. If it fires on legitimate customer-own-email echoes at a high rate, revisit the carve-out decision in a follow-up.

## Risks

- **False positives on customer's own email.** If Caroline says "I see your account is registered to `customer@example.com`," the filter will swap it to `support@muso.ai`. UX impact is small (customer already knows their own email) and the log will tell us if this is common. Accepted per product decision.
- **Agent resists the SOUL.md rule.** Per the same feedback memory, this is expected — the mechanical filter is what actually enforces. SOUL.md is paired defense; the runtime layer is the guarantee.
- **New code paths bypass the wrapper.** Mitigated by (a) a single `createIntercomClient` factory — the only sanctioned construction path, (b) a pre-commit grep lint that fails if `new RealIntercomClient(` appears outside `outbound.ts` and test files, and (c) TypeScript `implements IntercomClient` on the wrapper, which forces every interface method to have a proxy. The factory + lint is the primary defense; reviewer vigilance is tertiary.

## Future work (non-blocking)

- **Config-driven allowlist.** Today the allowlist is a module-level constant in `sanitize-email.ts`. If Aaron adds a third permitted email next month, that's a code change + deploy. A natural evolution is moving the set into openclaw.json (or the per-account Intercom config block in `plugins/intercom/src/config.ts`) so ops can edit it without a release. Not a blocker at two entries; flag this when the list grows or when the need first comes up.
- **Slack webhook on redaction.** The error log is grep-able today but not push-alerted. If the leak rate after rollout justifies it, wire a Slack post to `#hydra-heartbeat` (or a dedicated channel) when `redactions.length > 0`.
