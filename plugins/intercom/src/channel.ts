import type { IncomingMessage, ServerResponse } from "node:http";
import { createChatChannelPlugin } from "openclaw/plugin-sdk/core";
import { runPassiveAccountLifecycle } from "openclaw/plugin-sdk/channel-lifecycle";
import { registerPluginHttpRoute } from "openclaw/plugin-sdk/webhook-ingress";
import { dispatchInboundDirectDmWithRuntime } from "openclaw/plugin-sdk/channel-inbound";
import { resolveStateDir } from "openclaw/plugin-sdk/state-paths";
import { listIntercomAccountIds, resolveIntercomAccount, validateClickupConfig } from "./config.js";
import { isMonitorProbe, validateHmacSignature } from "./webhook.js";
import { handleWebhookEvent } from "./handler.js";
import { enrichSession, type VerifiedIdentity } from "./enrichment.js";
import { createSnapshotClient } from "./muso-snapshot-client.js";
import { createInitialSessionState, canAgentReply } from "./handoff.js";
import {
  createIntercomClient,
  trackOutboundMessageId,
  IntercomAssignmentConflictError,
} from "./outbound.js";
import { sanitizeReasoningLeak } from "./sanitize-reasoning-leak.js";
import { initStateStore, loadSessions, saveSessions } from "./state-store.js";
import {
  buildEscalationSlackMessage,
  buildEscalationSlackMessageMinimal,
} from "./slack.js";
import {
  detectSilentDispatch,
  buildSilentDispatchSlackPayload,
  type SilentDispatchReason,
} from "./silent-dispatch.js";
import { isIntentionalNoReply, stripNoReplySentinel } from "./no-reply.js";
import { createOpenRouterJudge } from "./judge.js";
import { createClickupTicket } from "./clickup.js";
import {
  downloadImageAttachments,
  downloadDocumentAttachments,
  buildMediaExtraContext,
  capMediaEntries,
  MAX_IMAGE_ATTACHMENTS_PER_TURN,
  MAX_MEDIA_ENTRIES_PER_TURN,
  STATEDIR_MEDIA_FALLBACK,
  type PersistedAttachment,
} from "./attachments.js";
import path from "node:path";
import type { IntercomSessionState, IntercomWebhookPayload, KnownFacts, IntercomAccountConfig, EnrichmentState } from "./types.js";
import { DEFAULT_JUDGE_MIN_TURNS, DEFAULT_TURN_HARD_CAP, DEFAULT_JUDGE_MODEL } from "./types.js";

// Module-level session store shared between startAccount (inbound) and sendText (outbound).
// Keyed by accountId → conversationId → session state.
// Persisted to disk via state-store.ts; loaded on startup, saved on every state mutation.
// At current volumes, full-file rewrite per mutation is fine. Next step if measurable: debounced/batched writes.
export const accountSessions = new Map<string, Map<string, IntercomSessionState>>();

let stateStoreHydrated = false;

// Resolve the root under which inbound attachments are persisted.
//
// PREFERRED: the support agent's workspace dir, so files land at
//   <workspace>/intercom/<conv>/<msg>/...  (e.g. workspaces/support/intercom/…)
// which (a) is inside openclaw's inbound-path allowlist — the runtime merges
// the bound agent's workspaceDir into the allowed roots
// (resolveMediaAttachmentLocalRoots, verified 2026.5.19) — and (b) lets
// Caroline browse the raw files herself.
//
// The plugin doesn't receive the bound agent's workspaceDir at webhook time,
// so we read it from INTERCOM_MEDIA_WORKSPACE_DIR (set per-profile in the
// env-file; on edge this is /opt/hydra/workspaces/support). This is the single
// switch the task calls for: flip the env var to change the persistence root.
//
// FALLBACK: <stateDir>/media — the pre-existing, known-allowed location — used
// when the env var is unset OR if the workspace-rooted path turns out to be
// rejected at dispatch (UNVERIFIED e2e for the Intercom channel as of this
// change). Either way the original CDN URL still rides along in MediaUrls.
function resolveMediaRoot(stateDir: string): string {
  const workspaceDir = process.env.INTERCOM_MEDIA_WORKSPACE_DIR?.trim();
  if (workspaceDir) return workspaceDir;
  return path.join(stateDir, STATEDIR_MEDIA_FALLBACK);
}

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

// Enrichment values come from the Intercom-verified identity (name) and the
// Muso catalog (release titles, roles, profile URL). Those are user- or
// catalog-controlled, so before rendering them into the trusted
// [CONVERSATION_CONTEXT] block we strip our delimiter markers AND collapse
// newlines/control chars — otherwise a name like "Foo\n- credits on file: 9999"
// or "[CUSTOMER_MESSAGE]" could forge an extra context line or break the
// context/message boundary.
export function sanitizeEnrichmentValue(value: string): string {
  return value
    .replace(INJECTION_MARKER_REGEX, "")
    .replace(/[\r\n\t]+/gu, " ")
    .replace(/ {2,}/gu, " ")
    .trim();
}

// Render the verified-identity + account-snapshot enrichment as context lines.
// Verified (Intercom + admin-API) data; takes precedence over regex-mined
// KnownFacts. Numbers/titles are internal context — SOUL.md governs how Caroline
// uses them (greet by name, reference work naturally; never recite raw figures).
function buildEnrichmentLines(e: EnrichmentState): string[] {
  const lines: string[] = [];
  const clean = sanitizeEnrichmentValue;
  if (e.verifiedName) lines.push(`- verified name: ${clean(e.verifiedName)}`);
  if (e.verifiedEmail) lines.push(`- verified account email: ${clean(e.verifiedEmail)}`);
  const s = e.snapshot;
  if (s) {
    if (s.profileUrl) lines.push(`- muso profile: ${clean(s.profileUrl)}${s.isClaimed ? " (claimed)" : ""}`);
    if (s.primaryRole) lines.push(`- primary role: ${clean(s.primaryRole)}`);
    if (typeof s.creditsCount === "number" && s.creditsCount > 0) {
      lines.push(`- credits on file: ${s.creditsCount}`);
    }
    if (s.latestCreditTitle) {
      lines.push(`- latest release: "${clean(s.latestCreditTitle)}"${s.latestCreditDate ? ` (${clean(s.latestCreditDate)})` : ""}`);
    }
    if (typeof s.founderSince === "number") {
      lines.push(`- founding member: since ${s.founderSince}`);
    }
    if (s.plan) lines.push(`- plan: ${clean(s.plan)}`);
  }
  const p = e.priorChats;
  if (p && p.count > 0) {
    // Most-recent reference may be a conversation title OR a customer-typed
    // snippet — always sanitized. Date trimmed to the day; the agent doesn't
    // need timestamps.
    const recent = p.mostRecentTitle
      ? ` (most recent: "${clean(p.mostRecentTitle)}"${p.mostRecentAt ? `, ${p.mostRecentAt.slice(0, 10)}` : ""})`
      : "";
    lines.push(`- prior support chats: ${p.count}${recent}`);
  }
  return lines;
}

/**
 * Render KnownFacts (+ optional verified enrichment) as a [CONVERSATION_CONTEXT]
 * block prepended to the customer message. Empty context produces no block (no
 * noise on first contact). The agent's SOUL.md instructs it to treat this block
 * as authoritative ground truth and never echo it.
 *
 * Precedence: verified enrichment wins over the regex-mined KnownFacts — a
 * mined account email / profile URL is only shown when enrichment didn't
 * already supply a verified equivalent (so the agent never sees two emails).
 */
export function buildAgentRawBody(
  message: string,
  facts: KnownFacts,
  enrichment?: EnrichmentState,
): string {
  const sanitized = sanitizeCustomerMessage(message);
  const lines: string[] = enrichment ? buildEnrichmentLines(enrichment) : [];
  if (!enrichment?.verifiedEmail && facts.accountEmail) {
    lines.push(`- account email: ${facts.accountEmail}`);
  }
  if (!enrichment?.snapshot?.profileUrl && facts.musoProfileUrl) {
    lines.push(`- muso profile: ${facts.musoProfileUrl}`);
  }
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

// Build the personalization `enrich` hook for a webhook handler, or undefined
// when the feature is off or admin creds are missing. The snapshot client is
// constructed ONCE per account start so its login token is reused across
// conversations. Returns undefined (not a throwing stub) so a missing-cred
// misconfig degrades to "no personalization" rather than breaking dispatch.
export function buildEnrichFn(
  account: IntercomAccountConfig,
  log?: { warn?: (m: string) => void; info?: (m: string) => void },
): ((state: IntercomSessionState, identity: VerifiedIdentity) => Promise<void>) | undefined {
  if (account.personalization?.enabled !== true) return undefined;
  const adminEmail = process.env.MUSO_ADMIN_EMAIL ?? "";
  const adminPassword = process.env.MUSO_ADMIN_PASSWORD ?? "";
  if (!adminEmail || !adminPassword) {
    log?.warn?.(
      "[intercom] personalization enabled but MUSO_ADMIN_EMAIL/PASSWORD unset — enrichment disabled",
    );
    return undefined;
  }
  const musoApiBase = process.env.MUSO_API_BASE ?? "https://api.muso.ai";
  const warnLog = log?.warn ? { warn: (m: string) => log.warn!(m) } : undefined;
  const snapshotClient = createSnapshotClient({ musoApiBase, adminEmail, adminPassword, log: warnLog });
  // Prior-chat recall reads the contact's own conversation list from Intercom
  // (system of record, correctly scoped per contact). Built once per account
  // start via the sanctioned factory.
  const intercomClient = createIntercomClient(account.token, log?.warn ? { error: (m) => log.warn!(m) } : undefined);
  const timeoutMs = account.personalization.timeoutMs;
  return (state, identity) =>
    enrichSession(state, identity, {
      lookupSnapshot: snapshotClient.lookupSnapshot,
      // Exclude the current conversation server-side so the search's
      // total_count is the exact prior count; the enrichment budget bounds
      // the Intercom call the same as the snapshot leg.
      listPriorConversations: (contactId, opts) =>
        intercomClient.listContactConversations({
          contactId,
          excludeConversationId: state.conversationId,
          limit: 5,
          timeoutMs: opts.timeoutMs,
        }),
      ...(typeof timeoutMs === "number" ? { timeoutMs } : {}),
      log: warnLog,
    });
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

        // Personalization enrich hook (verified, logged-in customers). Built
        // once per account start so the admin-API login token is reused. When
        // disabled or mis-configured this is undefined and dispatch is unchanged.
        const enrichFn = buildEnrichFn(account, log);
        ctx.log?.info?.(
          `[${tag}] personalization=${account.personalization?.enabled === true ? (enrichFn ? "on" : "on-but-uncredentialed") : "off"}`,
        );

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

                const userAgent = (req.headers["user-agent"] as string) ?? "";
                if (isMonitorProbe(userAgent, rawBody)) {
                  res.writeHead(200, { "Content-Type": "application/json" });
                  res.end(JSON.stringify({ ok: true, probe: "monitor" }));
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
                    {
                      ...riskOptions,
                      blockedChannelTags: account.blockedChannelTags ?? [],
                      personalization: account.personalization,
                      enrich: enrichFn,
                    },
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
                    let dispatchThrew: Error | null = null;

                    // If the customer attached images and/or PDFs, fetch them
                    // NOW (Intercom CDN URLs are signed with ~30 min TTL) and
                    // persist under <mediaRoot>/intercom/<conv>/<msg>/. We then
                    // pass the persisted paths to the agent runtime through
                    // `extraContext.MediaPaths` — openclaw's MsgContext shape
                    // (`channels/inbound-event/media`) the gateway turns into
                    // base64 image content blocks for vision-capable models, and
                    // (for application/pdf entries) feeds to the document-extract
                    // plugin for text. PDFs are page-rasterized to PNG so vision
                    // can also "see" them. Empty attachments+documents → no
                    // extraContext, no behavior change for text-only messages.
                    const imageRefs = result.attachments ?? [];
                    const documentRefs = result.documents ?? [];
                    let persisted: PersistedAttachment[] = [];
                    if (imageRefs.length > 0 || documentRefs.length > 0) {
                      const stateDir = resolveStateDir();
                      if (stateDir) {
                        const mediaRoot = resolveMediaRoot(stateDir);
                        const dlDeps = { log: log ? { warn: (m: string) => log.warn?.(m), info: (m: string) => log.info?.(m) } : undefined };
                        try {
                          // Reserve the slots images will take (capped) and give
                          // the document pipeline only the remainder as its budget,
                          // so PDFs aren't downloaded/rasterized just to be discarded
                          // by the post-hoc cap. Images are cheap (no rasterization)
                          // and always <= MAX_IMAGE_ATTACHMENTS_PER_TURN.
                          const imagesPlanned = Math.min(imageRefs.length, MAX_IMAGE_ATTACHMENTS_PER_TURN);
                          const docBudget = Math.max(0, MAX_MEDIA_ENTRIES_PER_TURN - imagesPlanned);
                          // Order matters: image entries first, then document
                          // entries (rasterized PNG pages then original PDF per
                          // doc). normalizeAttachments pairs path/url/type by
                          // index, so this order is what the agent receives.
                          const [images, documents] = await Promise.all([
                            imageRefs.length > 0
                              ? downloadImageAttachments({
                                  refs: imageRefs,
                                  conversationId: result.conversationId,
                                  mediaRoot,
                                  messageId: payload.id,
                                  deps: dlDeps,
                                })
                              : Promise.resolve([] as PersistedAttachment[]),
                            documentRefs.length > 0 && docBudget > 0
                              ? downloadDocumentAttachments({
                                  refs: documentRefs,
                                  conversationId: result.conversationId,
                                  mediaRoot,
                                  messageId: payload.id,
                                  budget: docBudget,
                                  deps: dlDeps,
                                })
                              : Promise.resolve([] as PersistedAttachment[]),
                          ]);
                          // Defensive final cap on the COMBINED media list. The
                          // document pipeline is already budgeted upstream (docBudget),
                          // so this normally won't truncate; it's a backstop in case
                          // image downloads plus a full doc budget ever exceed the cap.
                          const capped = capMediaEntries(images, documents);
                          if (capped.truncated) {
                            log?.warn?.(
                              `[${tag}] truncated media entries count=${capped.total} cap=${MAX_MEDIA_ENTRIES_PER_TURN} conv=${result.conversationId}`,
                            );
                          }
                          persisted = capped.entries;
                          if (persisted.length > 0) {
                            log?.info?.(
                              `[${tag}] persisted ${persisted.length} media entr(ies) (img_refs=${imageRefs.length} doc_refs=${documentRefs.length}) conv=${result.conversationId} root=${mediaRoot} bytes=${persisted.reduce((s, p) => s + p.size, 0)}`,
                            );
                          } else {
                            log?.warn?.(
                              `[${tag}] all attachments failed to persist (img_refs=${imageRefs.length} doc_refs=${documentRefs.length}) conv=${result.conversationId} — dispatching text-only`,
                            );
                          }
                        } catch (err) {
                          // The download fns swallow per-attachment errors
                          // internally — this catch covers only the directory-
                          // creation path, which shouldn't normally fail.
                          log?.error?.(
                            `[${tag}] attachment pipeline failed conv=${result.conversationId}: ${err}`,
                          );
                        }
                      } else {
                        log?.warn?.(
                          `[${tag}] stateDir unavailable — cannot persist ${imageRefs.length} image + ${documentRefs.length} doc attachment(s) conv=${result.conversationId}, dispatching text-only`,
                        );
                      }
                    }

                    const mediaExtraContext = buildMediaExtraContext(persisted);

                    // Customer can drag-drop an image/PDF with no caption — the
                    // text body is then empty. Substitute a synthetic prompt
                    // so the agent receives a non-empty turn alongside the
                    // media content block(s). Only applies when we actually
                    // have media to show; pure empty-body+no-media events
                    // are filtered upstream in classifyEvent.
                    const bodyForDispatch =
                      result.body.length === 0 && persisted.length > 0
                        ? `(Customer sent ${documentRefs.length > 0 ? "a document/attachment" : persisted.length === 1 ? "an image" : `${persisted.length} images`} with no caption.)`
                        : result.body;

                    try {
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
                      rawBody: buildAgentRawBody(bodyForDispatch, state.knownFacts ?? {}, state.enrichment),
                      messageId: payload.id,
                      timestamp: payload.created_at,
                      extraContext: mediaExtraContext,
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
                    } catch (err) {
                      // dispatchInbound itself threw — gateway WS blip, route
                      // resolution failure, recordInboundSession crash, etc.
                      // Captured here so the silent-dispatch alarm below can
                      // distinguish a thrown-dispatch from a zero-chunk one,
                      // and so the alarm runs even if dispatch never returned.
                      dispatchThrew = err instanceof Error ? err : new Error(String(err));
                    }

                    // Flush buffered chunks as a single Intercom reply.
                    // Re-check `canAgentReply` here to catch state flips that
                    // landed between the last `deliver` call and dispatch resolve
                    // (e.g., a human took over in the final ms of generation).
                    const joinedForReply = joinDeliveryChunks(bufferedChunks);
                    if (bufferedChunks.length > 0 && canAgentReply(state) && isIntentionalNoReply(joinedForReply)) {
                      // Caroline deliberately chose to stay quiet (SOUL.md
                      // "Reading the room") -- e.g. the customer just said
                      // "ok"/"thanks" after she'd already helped. Post nothing;
                      // the 👀 ack reaction remains on their message as the
                      // read-receipt. NOT a silent_dispatch failure: a chunk (the
                      // sentinel) WAS produced, so the alarm below stays quiet.
                      log?.info?.(
                        `[${tag}] intentional no-reply conv=${result.conversationId}`,
                      );
                    } else if (bufferedChunks.length > 0 && canAgentReply(state)) {
                      const joined = stripNoReplySentinel(joinedForReply);
                      if (joined.length > 0 && joined !== joinedForReply.trim()) {
                        // The model emitted the no-reply sentinel alongside real
                        // text instead of on its own (SOUL.md: the token must be
                        // the ENTIRE reply). We post the remainder and drop the
                        // token, but log it so a slipping doctrine is visible.
                        log?.warn?.(
                          `[${tag}] no-reply sentinel mixed with reply text (stripped, posting remainder) conv=${result.conversationId}`,
                        );
                      }
                      const stripped = stripConversationContext(joined, log ? { warn: (m) => log.warn(m) } : undefined, { conversationId: result.conversationId });
                      // Outbound reasoning-preamble guard. The reasoning model
                      // (gpt-5.5/codex) intermittently writes its internal plan into
                      // the reply content -- a preamble, a `---`, then the real reply
                      // (incident 2026-05-29). Strip a recoverable preamble; when we
                      // cannot safely recover a clean reply, hand the conversation to
                      // a human rather than ship leaked reasoning. Runs before the
                      // email/tool passes inside replyToConversation so it sees the
                      // original structure.
                      const guard = sanitizeReasoningLeak(stripped);
                      if (guard.action === "escalate") {
                        log?.error?.(
                          `[intercom:reasoning-leak] [${tag}] ESCALATED conv=${result.conversationId} reason=${guard.reason} markers=${JSON.stringify(guard.matchedMarkers)} sample=${JSON.stringify(guard.droppedSample ?? "")}`,
                        );
                        try {
                          await client.assignConversation({
                            conversationId: result.conversationId,
                            adminId: account.botAdminId,
                            assigneeId: account.defaultInboxId || "0",
                          });
                          log?.info?.(`[${tag}] reassigned conv=${result.conversationId} to ${account.defaultInboxId || "Unassigned"} (reasoning-leak)`);
                        } catch (err) {
                          log?.error?.(`[${tag}] reasoning-leak reassignment failed conv=${result.conversationId}: ${err}`);
                        }
                        if (account.fallbackSlackSupervisionChannel) {
                          try {
                            await fetch(account.fallbackSlackSupervisionChannel, {
                              method: "POST",
                              headers: { "Content-Type": "application/json" },
                              body: JSON.stringify({
                                text: `:warning: Caroline suppressed a reply that leaked internal reasoning (conv ${result.conversationId}, reason=${guard.reason}). The conversation was handed to a human — please follow up.`,
                              }),
                            });
                          } catch (err) {
                            log?.error?.(`[${tag}] reasoning-leak Slack notify failed conv=${result.conversationId}: ${err}`);
                          }
                        }
                      } else {
                        if (guard.action === "stripped") {
                          log?.error?.(
                            `[intercom:reasoning-leak] [${tag}] conv=${result.conversationId} action=stripped markers=${JSON.stringify(guard.matchedMarkers)} sample=${JSON.stringify(guard.droppedSample ?? "")}`,
                          );
                        }
                        try {
                          const { messageId } = await client.replyToConversation({
                            conversationId: result.conversationId,
                            adminId: account.botAdminId,
                            body: guard.body,
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
                      }
                    } else if (bufferedChunks.length > 0 && !droppedMidStream) {
                      log?.warn?.(
                        `[${tag}] deliver dropped after dispatch: ${state.handoffMode}/${state.lifecycleState} conv=${result.conversationId}`,
                      );
                    }

                    // Silent-dispatch alarm (hydra #280). Two cases:
                    //   1. dispatchInbound threw — surface the throw, since the
                    //      outer try/catch would otherwise log it as a generic
                    //      "webhook processing error" with no [intercom:ALERT].
                    //   2. dispatch returned but no chunks landed AND the conv
                    //      is still in a state where the agent should have
                    //      replied — the bug behind ~3 stranded convs/day.
                    const silentReason: SilentDispatchReason | null = dispatchThrew
                      ? "dispatch_threw"
                      : (() => {
                          const d = detectSilentDispatch({
                            bufferedChunks,
                            state,
                            droppedMidStream,
                          });
                          return d.silent ? d.reason : null;
                        })();
                    if (silentReason) {
                      const errSnippet = dispatchThrew?.message ?? null;
                      log?.error?.(
                        `[intercom:ALERT] [${tag}] silent_dispatch conv=${result.conversationId} reason=${silentReason}${errSnippet ? ` error=${errSnippet}` : ""}`,
                      );
                      if (account.fallbackSlackSupervisionChannel) {
                        const slackPayload = buildSilentDispatchSlackPayload({
                          conversationId: result.conversationId,
                          reason: silentReason,
                          errorMessage: errSnippet ?? undefined,
                          account,
                        });
                        fetch(account.fallbackSlackSupervisionChannel, {
                          method: "POST",
                          headers: { "Content-Type": "application/json" },
                          body: JSON.stringify(slackPayload),
                        }).catch((err) => {
                          log?.error?.(
                            `[${tag}] silent-dispatch Slack post failed: ${err}`,
                          );
                        });
                      }
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
