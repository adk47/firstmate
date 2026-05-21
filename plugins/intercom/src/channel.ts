import type { IncomingMessage, ServerResponse } from "node:http";
import { createChatChannelPlugin } from "openclaw/plugin-sdk/core";
import { runPassiveAccountLifecycle } from "openclaw/plugin-sdk/channel-lifecycle";
import { registerPluginHttpRoute } from "openclaw/plugin-sdk/webhook-ingress";
import { dispatchInboundDirectDmWithRuntime } from "openclaw/plugin-sdk/channel-inbound";
import { resolveStateDir } from "openclaw/plugin-sdk/state-paths";
import { listIntercomAccountIds, resolveIntercomAccount, validateClickupConfig } from "./config.js";
import { validateHmacSignature } from "./webhook.js";
import { handleWebhookEvent } from "./handler.js";
import { createInitialSessionState, canAgentReply } from "./handoff.js";
import {
  createIntercomClient,
  trackOutboundMessageId,
  IntercomAssignmentConflictError,
} from "./outbound.js";
import { initStateStore, loadSessions, saveSessions } from "./state-store.js";
import {
  buildEscalationSlackMessage,
  buildEscalationSlackMessageMinimal,
} from "./slack.js";
import { createOpenRouterJudge } from "./judge.js";
import { createClickupTicket } from "./clickup.js";
import type { IntercomSessionState, IntercomWebhookPayload, KnownFacts, IntercomAccountConfig } from "./types.js";
import { DEFAULT_JUDGE_MIN_TURNS, DEFAULT_TURN_HARD_CAP, DEFAULT_JUDGE_MODEL } from "./types.js";

// Module-level session store shared between startAccount (inbound) and sendText (outbound).
// Keyed by accountId → conversationId → session state.
// Persisted to disk via state-store.ts; loaded on startup, saved on every state mutation.
// At current volumes, full-file rewrite per mutation is fine. Next step if measurable: debounced/batched writes.
export const accountSessions = new Map<string, Map<string, IntercomSessionState>>();

let stateStoreHydrated = false;

function hydrateFromMap(loaded: Map<string, Map<string, IntercomSessionState>>): void {
  accountSessions.clear();
  for (const [k, v] of loaded) accountSessions.set(k, v);
}

function countSessions(sessions: Map<string, Map<string, IntercomSessionState>>): number {
  let count = 0;
  for (const inner of sessions.values()) count += inner.size;
  return count;
}

export function getOrCreateSession(
  accountId: string,
  conversationId: string,
  workspaceId: string,
): IntercomSessionState {
  let sessions = accountSessions.get(accountId);
  if (!sessions) {
    sessions = new Map();
    accountSessions.set(accountId, sessions);
  }
  let state = sessions.get(conversationId);
  if (!state) {
    state = createInitialSessionState(conversationId, workspaceId);
    sessions.set(conversationId, state);
    saveSessions(accountSessions).catch((err) =>
      console.warn(`[intercom] failed to save new session: ${err}`),
    );
  }
  return state;
}

export function parseConversationIdFromTarget(to: string): string | null {
  if (!to) return null;
  // Session key format: agent:support:intercom:{wsId}:conversation:{convId}
  const conversationPrefix = "conversation:";
  const idx = to.lastIndexOf(conversationPrefix);
  if (idx !== -1) {
    return to.slice(idx + conversationPrefix.length) || null;
  }
  // Fall back: treat the whole string as a conversationId
  return to;
}

const MAX_BODY_BYTES = 1_048_576; // 1MB

/**
 * Join agent reply chunks into a single Intercom message body.
 *
 * The OpenClaw SDK's EmbeddedBlockChunker splits agent responses into
 * paragraph/sentence chunks for streaming channels like Slack or IRC.
 * For Intercom we want a single consolidated reply per agent turn,
 * so we buffer chunks and concatenate here.
 *
 * Rules:
 *   - Drop empty/whitespace-only chunks.
 *   - Trim trailing whitespace on each chunk.
 *   - Join with "\n\n" so markdown paragraphs survive the merge,
 *     but only between non-empty chunks (no leading/trailing blanks).
 *   - Single-chunk input passes through untouched (common case).
 */
export function joinDeliveryChunks(chunks: string[]): string {
  const filtered = chunks
    .map((c) => c.replace(/\s+$/u, ""))
    .filter((c) => c.length > 0);
  if (filtered.length === 0) return "";
  if (filtered.length === 1) return filtered[0];
  return filtered.join("\n\n");
}

// Strip our own delimiter markers from inbound customer text before injecting
// it into the agent prompt — defense against a customer pasting a forged
// [CONVERSATION_CONTEXT] block that the agent would otherwise treat as
// authoritative ground truth.
const INJECTION_MARKER_REGEX = /\[\/?(?:CONVERSATION_CONTEXT|CUSTOMER_MESSAGE)\]/gi;

export function sanitizeCustomerMessage(message: string): string {
  if (!INJECTION_MARKER_REGEX.test(message)) return message;
  return message.replace(INJECTION_MARKER_REGEX, "").trim();
}

/**
 * Render KnownFacts as a [CONVERSATION_CONTEXT] block prepended to the
 * customer message. Empty knownFacts produces no block (no noise on first
 * contact). The agent's SOUL.md instructs it to treat this block as
 * authoritative ground truth and never echo it.
 */
export function buildAgentRawBody(message: string, facts: KnownFacts): string {
  const sanitized = sanitizeCustomerMessage(message);
  const lines: string[] = [];
  if (facts.accountEmail) lines.push(`- account email: ${facts.accountEmail}`);
  if (facts.musoProfileUrl) lines.push(`- muso profile: ${facts.musoProfileUrl}`);
  if (lines.length === 0) return sanitized;
  return [
    "[CONVERSATION_CONTEXT]",
    "Known about this user (do not re-ask):",
    ...lines,
    "[/CONVERSATION_CONTEXT]",
    "[CUSTOMER_MESSAGE]",
    sanitized,
  ].join("\n");
}

/**
 * Outbound regurgitation guard — strips any [CONVERSATION_CONTEXT] block from
 * agent replies before they hit Intercom. SOUL.md tells the agent not to echo;
 * this is cheap insurance, and the warn log surfaces every actual leak so we
 * can tell whether the SOUL rule is holding.
 */
const CONTEXT_BLOCK_REGEX = /\[CONVERSATION_CONTEXT\][\s\S]*?\[\/CONVERSATION_CONTEXT\]\s*/g;
const CONTEXT_OPEN_LINE_REGEX = /^\[CONVERSATION_CONTEXT\][^\n]*\n?/gm;

export function stripConversationContext(
  reply: string,
  log?: { warn: (msg: string) => void },
  context?: { conversationId?: string },
): string {
  if (!reply.includes("[CONVERSATION_CONTEXT]")) return reply;
  log?.warn?.(
    `[intercom] outbound stripped [CONVERSATION_CONTEXT] regurgitation conv=${context?.conversationId ?? "?"} sample=${reply.slice(0, 200)}`,
  );
  return reply.replace(CONTEXT_BLOCK_REGEX, "").replace(CONTEXT_OPEN_LINE_REGEX, "").trim();
}

// Construct the per-webhook risk-assessment options. When the flag is on AND
// an OpenRouter key is configured, the LLM-judge backstop is wired; otherwise
// only Layer 0/1/1b (magic-keyword + content rules + turn-count cap) run.
export function buildRiskOptions(
  account: IntercomAccountConfig,
  log: { warn: (msg: string) => void } | undefined,
): { riskAssessment: { enabled: boolean }; riskDeps?: import("./escalation.js").AssessRiskDeps } {
  if (!account.riskAssessment?.enabled) {
    return { riskAssessment: { enabled: false } };
  }
  const cfg = account.riskAssessment;
  const judge = cfg.openrouterApiKey
    ? createOpenRouterJudge({
        openrouterApiKey: cfg.openrouterApiKey,
        model: cfg.judgeModel ?? DEFAULT_JUDGE_MODEL,
        log: log ? { warn: (m) => log.warn(m) } : undefined,
      })
    : undefined;
  return {
    riskAssessment: { enabled: true },
    riskDeps: {
      judge,
      judgeMinTurnCount: cfg.judgeMinTurnCount ?? DEFAULT_JUDGE_MIN_TURNS,
      turnCountHardCap: cfg.turnCountHardCap ?? DEFAULT_TURN_HARD_CAP,
      log: log ? { warn: (m) => log.warn(m) } : undefined,
    },
  };
}

async function readRequestBody(req: IncomingMessage): Promise<string | null> {
  const chunks: Buffer[] = [];
  let totalBytes = 0;
  for await (const chunk of req) {
    const buf = typeof chunk === "string" ? Buffer.from(chunk) : chunk;
    totalBytes += buf.length;
    if (totalBytes > MAX_BODY_BYTES) return null;
    chunks.push(buf);
  }
  return Buffer.concat(chunks).toString("utf8");
}

export const intercomPlugin = createChatChannelPlugin({
  base: {
    id: "intercom",
    meta: {
      id: "intercom",
      label: "Intercom",
      selectionLabel: "Intercom",
      docsPath: "/channels/intercom",
      blurb: "Connect OpenClaw to Intercom for customer support.",
      order: 100,
    },
    capabilities: { chatTypes: ["direct"] },
    config: {
      listAccountIds: (cfg: any) => listIntercomAccountIds(cfg),
      resolveAccount: (cfg: any, accountId?: string | null) =>
        resolveIntercomAccount(cfg, accountId),
      isConfigured: (account: any) => Boolean(account.token && account.workspaceId),
    },
    gateway: {
      startAccount: async (ctx: any) => {
        const account = resolveIntercomAccount(ctx.cfg, ctx.accountId);
        const tag = `intercom:${account.accountId}`;

        // Boot-time ClickUp config validation: log loudly if a partial block
        // was provided. Without this, missing fields produce silent 401s on
        // every escalation and ops finds out only via Slack pings.
        const clickupGap = validateClickupConfig(account);
        if (clickupGap) {
          ctx.log?.error?.(
            `[${tag}] ClickUp config has partial block: missing ${clickupGap} — escalations will skip ticket creation`,
          );
        }

        const createTicket = account.clickup && !clickupGap
          ? (p: import("./escalation-action.js").CreateTicketParams) =>
              createClickupTicket(
                {
                  cfg: account.clickup!,
                  log: { error: (m) => ctx.log?.error?.(m) },
                },
                p,
              )
          : async () => ({ ok: false as const, error: "ClickUp not configured" });

        if (!account.enabled) {
          ctx.log?.info?.(`[${tag}] channel disabled, skipping`);
          return;
        }

        if (!ctx.channelRuntime) {
          ctx.log?.error?.(
            `[${tag}] channelRuntime not available — cannot dispatch to agent. ` +
            `Ensure the OpenClaw Gateway version supports channelRuntime for external plugins.`,
          );
          return;
        }

        // Hydrate session state from disk (once, on first account start)
        if (!stateStoreHydrated) {
          stateStoreHydrated = true;
          try {
            const stateDir = resolveStateDir();
            if (stateDir) {
              await initStateStore(stateDir);
              hydrateFromMap(await loadSessions());
              ctx.log?.info?.(`[${tag}] loaded ${countSessions(accountSessions)} sessions from disk`);
            } else {
              ctx.log?.warn?.(`[${tag}] stateDir not available — session persistence disabled, state will be lost on restart`);
            }
          } catch (err) {
            ctx.log?.warn?.(`[${tag}] failed to load sessions from disk: ${err}`);
          }
        }

        const riskEnabled = account.riskAssessment?.enabled === true;
        const judgeWired = riskEnabled && Boolean(account.riskAssessment?.openrouterApiKey);
        ctx.log?.info?.(
          `[${tag}] starting webhook monitor riskAssessment=${riskEnabled} judge=${judgeWired ? "wired" : "off"} ` +
            `clickup=${account.clickup && !clickupGap ? "configured" : "off"}`,
        );

        const runtime = ctx.channelRuntime;
        const cfg = ctx.cfg;
        const log = ctx.log;

        await runPassiveAccountLifecycle({
          abortSignal: ctx.abortSignal,
          start: async () => {
            const unregister = registerPluginHttpRoute({
              path: "/intercom/webhook",
              auth: "plugin", // HMAC validation happens inside the handler; "plugin" tells the gateway not to gate on its own auth.
              pluginId: "intercom",
              accountId: account.accountId,
              source: "intercom-webhook",
              handler: async (req: IncomingMessage, res: ServerResponse) => {
                if (req.method !== "POST") {
                  res.writeHead(405, { Allow: "POST" });
                  res.end();
                  return;
                }

                const rawBody = await readRequestBody(req);
                if (rawBody === null) {
                  res.writeHead(413);
                  res.end();
                  return;
                }

                const signature = (req.headers["x-hub-signature"] as string) ?? "";
                if (!validateHmacSignature(rawBody, signature, account.webhookSecret)) {
                  log?.error?.(`[${tag}] invalid HMAC signature — rejected`);
                  res.writeHead(401);
                  res.end();
                  return;
                }

                // Respond 200 immediately — Intercom expects fast response
                res.writeHead(200, { "Content-Type": "application/json" });
                res.end(JSON.stringify({ ok: true }));

                // Process asynchronously after responding
                try {
                  const payload: IntercomWebhookPayload = JSON.parse(rawBody);
                  const conversationId = payload.data?.item?.id;
                  if (!conversationId) {
                    log?.warn?.(`[${tag}] malformed payload — no conversationId`);
                    return;
                  }

                  const state = getOrCreateSession(account.accountId, conversationId, account.workspaceId);
                  const client = createIntercomClient(account.token, log);
                  const riskOptions = buildRiskOptions(account, log);
                  const { result } = await handleWebhookEvent(
                    payload,
                    state,
                    account.botAdminId,
                    client,
                    { ...riskOptions, blockedChannelTags: account.blockedChannelTags ?? [] },
                  );

                  // Persist state after every webhook that may have mutated it
                  if (result.action !== "ignored" && result.action !== "duplicate") {
                    saveSessions(accountSessions).catch((err) =>
                      log?.error?.(`[${tag}] failed to save sessions: ${err}`),
                    );
                  }

                  const reason = result.action === "filtered" ? `: ${result.reason}` : "";
                  log?.info?.(`[${tag}] ${payload.topic} conv=${conversationId} → ${result.action}${reason}`);

                  if (result.action === "dispatch_to_agent") {
                    // Assign conversation to bot if not already assigned (fire-and-forget).
                    // `IntercomAssignmentConflictError` means the conversation is already
                    // assigned to the bot — expected on gateway restart, concurrent
                    // webhooks, or manual reassigns in the Intercom UI. Treat as a no-op
                    // state sync; don't log as an error.
                    if (state.currentAssigneeId !== account.botAdminId) {
                      client.assignConversation({
                        conversationId: result.conversationId,
                        adminId: account.botAdminId,
                        assigneeId: account.botAdminId,
                      }).then(() => {
                        state.currentAssigneeId = account.botAdminId;
                        saveSessions(accountSessions).catch(() => {});
                        log?.info?.(`[${tag}] assigned conv=${result.conversationId} to bot`);
                      }).catch((err) => {
                        if (err instanceof IntercomAssignmentConflictError) {
                          state.currentAssigneeId = account.botAdminId;
                          saveSessions(accountSessions).catch(() => {});
                          return;
                        }
                        log?.warn?.(`[${tag}] failed to self-assign conv=${result.conversationId}: ${err}`);
                      });
                    }

                    // Buffer chunked deliveries from the SDK's EmbeddedBlockChunker
                    // and flush as a single Intercom reply after dispatch returns.
                    // Without this, each paragraph/sentence chunk becomes a separate
                    // Intercom message — conv=215473826733450 on 2026-04-08 produced
                    // 5 replies in 5 seconds for one customer message, which reads
                    // to the customer as the bot spamming them.
                    const bufferedChunks: string[] = [];
                    let droppedMidStream = false;

                    await dispatchInboundDirectDmWithRuntime({
                      cfg,
                      runtime: { channel: runtime },
                      channel: "intercom",
                      channelLabel: "Intercom",
                      accountId: account.accountId,
                      peer: { kind: "direct", id: result.conversationId },
                      senderId: result.authorId,
                      senderAddress: `intercom:${result.authorId}`,
                      recipientAddress: `intercom:${account.botAdminId}`,
                      conversationLabel: `Intercom conversation ${result.conversationId}`,
                      rawBody: buildAgentRawBody(result.body, state.knownFacts ?? {}),
                      messageId: payload.id,
                      timestamp: payload.created_at,
                      deliver: async (replyPayload: any) => {
                        const text = replyPayload?.text ?? replyPayload?.body ?? "";
                        if (!text) {
                          log?.warn?.(`[${tag}] deliver called with empty reply for conv=${result.conversationId}`);
                          return;
                        }

                        // If the customer took over (or closed/snoozed) while the
                        // agent was still generating, drop any further chunks.
                        // `state` is always non-null here (captured from the
                        // getOrCreateSession call above) — no `state &&` guard needed.
                        if (!canAgentReply(state)) {
                          if (!droppedMidStream) {
                            log?.warn?.(
                              `[${tag}] deliver dropped mid-stream: ${state.handoffMode}/${state.lifecycleState} conv=${result.conversationId}`,
                            );
                            droppedMidStream = true;
                          }
                          return;
                        }

                        bufferedChunks.push(text);
                      },
                      onRecordError: (err) =>
                        log?.error?.(`[${tag}] session record error: ${err}`),
                      onDispatchError: (err, info) =>
                        log?.error?.(`[${tag}] dispatch error (${info.kind}): ${err}`),
                    });

                    // Flush buffered chunks as a single Intercom reply.
                    // Re-check `canAgentReply` here to catch state flips that
                    // landed between the last `deliver` call and dispatch resolve
                    // (e.g., a human took over in the final ms of generation).
                    if (bufferedChunks.length > 0 && canAgentReply(state)) {
                      const joined = joinDeliveryChunks(bufferedChunks);
                      try {
                        const { messageId } = await client.replyToConversation({
                          conversationId: result.conversationId,
                          adminId: account.botAdminId,
                          body: stripConversationContext(joined, log ? { warn: (m) => log.warn(m) } : undefined, { conversationId: result.conversationId }),
                        });
                        trackOutboundMessageId(messageId, state.outboundMessageIds);
                        state.updatedAt = new Date().toISOString();
                        log?.info?.(
                          `[${tag}] replied conv=${result.conversationId} partId=${messageId || "<none>"} chunks=${bufferedChunks.length}`,
                        );
                      } catch (err) {
                        // Customer-facing delivery failure: grep-able alert prefix
                        // so ops can wire Slack/Sentry on `[intercom:ALERT]`.
                        // TODO(follow-up): POST to account.fallbackSlackSupervisionChannel.
                        log?.error?.(
                          `[intercom:ALERT] [${tag}] flush failed conv=${result.conversationId} chunks=${bufferedChunks.length} error=${err}`,
                        );
                      }
                    } else if (bufferedChunks.length > 0 && !droppedMidStream) {
                      log?.warn?.(
                        `[${tag}] deliver dropped after dispatch: ${state.handoffMode}/${state.lifecycleState} conv=${result.conversationId}`,
                      );
                    }
                  } else if (result.action === "escalate") {
                    const { executeEscalation } = await import("./escalation-action.js");
                    await executeEscalation({
                      state,
                      conversationId: result.conversationId,
                      assessment: result.assessment,
                      currentMessage: result.body,
                      account,
                      client,
                      saveState: async () => { await saveSessions(accountSessions); },
                      createTicket,
                      postSlack: account.fallbackSlackSupervisionChannel
                        ? async (payload) => {
                            await fetch(account.fallbackSlackSupervisionChannel, {
                              method: "POST",
                              headers: { "Content-Type": "application/json" },
                              body: JSON.stringify(payload),
                            });
                          }
                        : async () => {},
                      log: {
                        info: (m) => log?.info?.(m),
                        warn: (m) => log?.warn?.(m),
                        error: (m) => log?.error?.(m),
                      },
                    });
                    log?.warn?.(
                      `[${tag}] ESCALATED conv=${result.conversationId} ` +
                      `source=${result.assessment.source} reason=${result.assessment.reason}`,
                    );
                  } else if (result.action === "escalate_legacy") {
                    // Legacy path — runs whenever riskAssessment.enabled is false.
                    // Delete once that flag is true on all profiles and one week of
                    // clean traffic has elapsed.
                    try {
                      await client.replyToConversation({
                        conversationId: result.conversationId,
                        adminId: account.botAdminId,
                        body: account.fallbackAcknowledgement,
                      });
                    } catch (err) {
                      log?.error?.(`[${tag}] escalation ack failed conv=${result.conversationId}: ${err}`);
                    }
                    try {
                      await client.assignConversation({
                        conversationId: result.conversationId,
                        adminId: account.botAdminId,
                        assigneeId: account.defaultInboxId || "0",
                      });
                      log?.info?.(`[${tag}] reassigned conv=${result.conversationId} to ${account.defaultInboxId || "Unassigned"}`);
                    } catch (err) {
                      log?.error?.(`[${tag}] reassignment failed conv=${result.conversationId}: ${err}`);
                    }
                    if (account.fallbackSlackSupervisionChannel) {
                      const escalationSummary = {
                        conversationId: result.conversationId,
                        category: result.category,
                        matchedPattern: result.matchedPattern,
                        body: result.body,
                      };
                      let slackPayload;
                      try {
                        const conversation = await client.getConversation({ conversationId: result.conversationId });
                        slackPayload = buildEscalationSlackMessage(escalationSummary, conversation, account, state);
                      } catch (err) {
                        log?.warn?.(`[${tag}] Slack enrichment fetch failed conv=${result.conversationId}: ${err} — posting minimal`);
                        slackPayload = buildEscalationSlackMessageMinimal(escalationSummary, account);
                      }
                      try {
                        await fetch(account.fallbackSlackSupervisionChannel, {
                          method: "POST",
                          headers: { "Content-Type": "application/json" },
                          body: JSON.stringify(slackPayload),
                        });
                      } catch (err) {
                        log?.error?.(`[${tag}] Slack escalation notification failed: ${err}`);
                      }
                    }
                    log?.warn?.(
                      `[${tag}] ESCALATED (legacy) conv=${result.conversationId} ` +
                      `category=${result.category} pattern=${result.matchedPattern}`,
                    );
                  }
                } catch (err) {
                  log?.error?.(`[${tag}] webhook processing error: ${err}`);
                }
              },
            });

            log?.info?.(`[${tag}] webhook route registered at /intercom/webhook`);
            return unregister;
          },
          stop: async (unregister) => {
            unregister?.();
            accountSessions.delete(account.accountId);
            log?.info?.(`[${tag}] webhook route unregistered`);
          },
        });
      },
    },
  },
  security: {
    dm: {
      channelKey: "intercom",
      resolvePolicy: () => "open",
      resolveAllowFrom: () => undefined,
    },
  },
  threading: { topLevelReplyToMode: "reply" },
  outbound: {
    base: { deliveryMode: "direct" },
    attachedResults: {
      channel: "intercom",
      sendText: async ({ cfg, to, text, accountId }: any) => {
        const account = resolveIntercomAccount(cfg, accountId);

        const conversationId = parseConversationIdFromTarget(to);
        if (!conversationId) {
          throw new Error(`intercom sendText: cannot parse conversationId from target "${to}"`);
        }

        // Pre-send validation: if a human took over during agent generation, drop the AI reply
        const sessions = accountSessions.get(account.accountId);
        const state = sessions?.get(conversationId);
        if (state && !canAgentReply(state)) {
          console.warn(
            `[intercom:${account.accountId}] sendText dropped: ${state.handoffMode}/${state.lifecycleState} conv=${conversationId}`,
          );
          return {
            channel: "intercom" as const,
            messageId: "",
            conversationId,
            meta: { dropped: true, reason: `${state.handoffMode}/${state.lifecycleState}` },
          };
        }

        const client = createIntercomClient(account.token, {
          error: (msg) => console.error(msg),
        });
        const { messageId } = await client.replyToConversation({
          conversationId,
          adminId: account.botAdminId,
          body: stripConversationContext(text),
        });

        // Track outbound message ID for self-reply filtering
        if (state) {
          trackOutboundMessageId(messageId, state.outboundMessageIds);
          state.updatedAt = new Date().toISOString();
        }

        return {
          channel: "intercom" as const,
          messageId,
          conversationId,
          timestamp: Date.now(),
        };
      },
    },
  },
});
