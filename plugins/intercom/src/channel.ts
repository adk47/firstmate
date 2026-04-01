import type { IncomingMessage, ServerResponse } from "node:http";
import { createChatChannelPlugin } from "openclaw/plugin-sdk/core";
import { runPassiveAccountLifecycle } from "openclaw/plugin-sdk/channel-lifecycle";
import { registerPluginHttpRoute } from "openclaw/plugin-sdk/webhook-ingress";
import { dispatchInboundDirectDmWithRuntime } from "openclaw/plugin-sdk/channel-inbound";
import { listIntercomAccountIds, resolveIntercomAccount } from "./config.js";
import { validateHmacSignature } from "./webhook.js";
import { handleWebhookEvent } from "./handler.js";
import { createInitialSessionState, canAgentReply } from "./handoff.js";
import { RealIntercomClient, trackOutboundMessageId } from "./outbound.js";
import type { IntercomSessionState, IntercomWebhookPayload } from "./types.js";

// Module-level session store shared between startAccount (inbound) and sendText (outbound).
// Keyed by accountId → conversationId → session state.
// In-memory only — lost on restart. Acceptable for v1; durable state deferred until traffic patterns emerge.
// TODO: Add TTL-based eviction when Intercom traffic volume justifies it.
export const accountSessions = new Map<string, Map<string, IntercomSessionState>>();

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
    meta: { label: "Intercom", order: 100 },
    capabilities: { chatTypes: ["direct"] },
    config: {
      listAccountIds: (cfg: any) => listIntercomAccountIds(cfg),
      resolveAccount: ({ cfg, accountId }: { cfg: any; accountId?: string | null }) =>
        resolveIntercomAccount(cfg, accountId),
      isConfigured: (account: any) => Boolean(account.token && account.workspaceId),
    },
    gateway: {
      startAccount: async (ctx: any) => {
        const account = resolveIntercomAccount(ctx.cfg, ctx.accountId);
        const tag = `intercom:${account.accountId}`;

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

        ctx.log?.info?.(`[${tag}] starting webhook monitor`);

        const runtime = ctx.channelRuntime;
        const cfg = ctx.cfg;
        const log = ctx.log;

        await runPassiveAccountLifecycle({
          abortSignal: ctx.abortSignal,
          start: async () => {
            const unregister = registerPluginHttpRoute({
              path: "/intercom/webhook",
              auth: "none", // HMAC validation happens inside the handler
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
                  const { result } = handleWebhookEvent(payload, state, account.botAdminId);

                  log?.info?.(`[${tag}] ${payload.topic} conv=${conversationId} → ${result.action}`);

                  if (result.action === "dispatch_to_agent") {
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
                      rawBody: result.body,
                      messageId: payload.id,
                      timestamp: payload.created_at,
                      deliver: async (replyPayload: any) => {
                        const text = replyPayload?.text ?? replyPayload?.body ?? "";
                        if (!text) {
                          log?.warn?.(`[${tag}] deliver called with empty reply for conv=${result.conversationId}`);
                          return;
                        }

                        // Pre-send validation: check handoff state
                        if (state && !canAgentReply(state)) {
                          console.warn(
                            `[${tag}] deliver dropped: ${state.handoffMode}/${state.lifecycleState} conv=${result.conversationId}`,
                          );
                          return;
                        }

                        const client = new RealIntercomClient(account.token);
                        try {
                          const { messageId } = await client.replyToConversation({
                            conversationId: result.conversationId,
                            adminId: account.botAdminId,
                            body: text,
                          });
                          if (state) {
                            trackOutboundMessageId(messageId, state.outboundMessageIds);
                            state.updatedAt = new Date().toISOString();
                          }
                          log?.info?.(`[${tag}] replied conv=${result.conversationId} msgId=${messageId}`);
                        } catch (err) {
                          log?.error?.(`[${tag}] deliver reply failed conv=${result.conversationId}: ${err}`);
                        }
                      },
                      onRecordError: (err) =>
                        log?.error?.(`[${tag}] session record error: ${err}`),
                      onDispatchError: (err, info) =>
                        log?.error?.(`[${tag}] dispatch error (${info.kind}): ${err}`),
                    });
                  } else if (result.action === "escalate") {
                    const client = new RealIntercomClient(account.token);

                    // 1. Send fallback ack to customer
                    try {
                      await client.replyToConversation({
                        conversationId: result.conversationId,
                        adminId: account.botAdminId,
                        body: account.fallbackAcknowledgement,
                      });
                    } catch (err) {
                      log?.error?.(
                        `[${tag}] escalation ack failed conv=${result.conversationId}: ${err}`,
                      );
                    }

                    // 2. Reassign conversation away from bot to human team
                    try {
                      await client.assignConversation({
                        conversationId: result.conversationId,
                        adminId: account.botAdminId,
                        assigneeId: account.defaultInboxId || "0", // team ID, or "0" for Unassigned
                      });
                      log?.info?.(`[${tag}] reassigned conv=${result.conversationId} to ${account.defaultInboxId || "Unassigned"}`);
                    } catch (err) {
                      log?.error?.(
                        `[${tag}] reassignment failed conv=${result.conversationId}: ${err}`,
                      );
                    }

                    // 3. Notify team via Slack
                    if (account.fallbackSlackSupervisionChannel) {
                      const intercomUrl = `https://app.intercom.com/a/inbox/${account.workspaceId}/inbox/conversation/${result.conversationId}`;
                      try {
                        await fetch(account.fallbackSlackSupervisionChannel, {
                          method: "POST",
                          headers: { "Content-Type": "application/json" },
                          body: JSON.stringify({
                            text: `🚨 Intercom escalation: ${result.category} — <${intercomUrl}|View conversation>`,
                            blocks: [
                              {
                                type: "section",
                                text: {
                                  type: "mrkdwn",
                                  text: `🚨 *Intercom Escalation*\n*Category:* ${result.category}\n*Pattern:* \`${result.matchedPattern}\`\n*Message:* ${result.body.slice(0, 200)}${result.body.length > 200 ? "…" : ""}`,
                                },
                              },
                              {
                                type: "actions",
                                elements: [
                                  {
                                    type: "button",
                                    text: { type: "plain_text", text: "View in Intercom" },
                                    url: intercomUrl,
                                  },
                                ],
                              },
                            ],
                          }),
                        });
                      } catch (err) {
                        log?.error?.(`[${tag}] Slack escalation notification failed: ${err}`);
                      }
                    }

                    log?.warn?.(
                      `[${tag}] ESCALATED conv=${result.conversationId} ` +
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

        const client = new RealIntercomClient(account.token);
        const { messageId } = await client.replyToConversation({
          conversationId,
          adminId: account.botAdminId,
          body: text,
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
