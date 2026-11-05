/**
 * The Slack envelope -> the payload scripts/ops_intake/router.py consumes.
 *
 * THE ONE RULE THIS FILE EXISTS FOR: identity comes from `ctx.senderId` (the
 * Slack envelope's `user`), never from the message text. On 2026-11-02 16:31Z a
 * message on this surface began "*Jan Delmo* [12:09 AM] ask firstmate to review
 * the proof ..." - a pasted quote header. Any code that resolves a requester by
 * scraping a name out of the body would have attributed that ask (and every
 * `hide profile X` forged the same way) to Jan. `text` is data; it is passed
 * through untouched and the Python side classifies it.
 *
 * The module is import-free so vitest can exercise it with
 * `node --experimental-strip-types` and no openclaw install.
 */

export interface InboundClaimEvent {
  content?: string;
  body?: string;
  channel?: string;
  isGroup?: boolean;
  accountId?: string;
  conversationId?: string;
  messageId?: string;
  /** openclaw 2026.8 puts the envelope sender here as well as on the ctx. */
  senderId?: string;
  senderName?: string;
  /** Epoch seconds of the inbound message. NOT a row key: two asks in one
   *  second collide, so it is never used as the ts. */
  timestamp?: number;
  threadId?: string | number;
  replyToId?: string | number;
  /** Present on Slack events; a bot/system message must never become an ask. */
  botId?: string;
  subtype?: string;
  threadTs?: string;
  ts?: string;
}

export interface InboundClaimContext {
  channelId?: string;
  accountId?: string;
  conversationId?: string;
  sessionKey?: string;
  senderId?: string;
  senderName?: string;
  messageId?: string;
  isDirectMessage?: boolean;
}

export interface RouterPayload {
  account_id: string;
  channel: string;
  user_id: string;
  text: string;
  ts: string;
  thread_ts: string | null;
  is_dm: boolean;
  display_name: string | null;
  bot_id: string | null;
  subtype: string | null;
}

export type EnvelopeSkip =
  | "no-sender"
  | "no-channel"
  | "from-bot"
  | "subtype"
  | "empty"
  | "wrong-account";

export interface EnvelopeResult {
  payload: RouterPayload | null;
  skip: EnvelopeSkip | null;
}

export interface PluginConfig {
  /** Slack account this router serves. Never a channel allowlist decision. */
  account: string;
  /** DM routing: DMs on the operations account are asks (census §1: Jan wrote 9). */
  allowDirectMessages: boolean;
}

export const DEFAULT_CONFIG: PluginConfig = {
  account: "operations",
  allowDirectMessages: true,
};

/** Slack DM channel ids are `D…`; `im` conversations also set isGroup=false. */
export function isDirectMessage(channel: string, isGroup: boolean | undefined): boolean {
  return channel.startsWith("D") || isGroup === false;
}

/**
 * Build the router payload, or say why this message is not an ask.
 *
 * `bot_id` and `subtype` are carried through rather than filtered here so the
 * Python side owns ONE copy of the ignore policy (it also guards replies to its
 * own posts, which would otherwise loop).
 */
export function buildPayload(
  event: InboundClaimEvent,
  ctx: InboundClaimContext,
  config: PluginConfig = DEFAULT_CONFIG,
): EnvelopeResult {
  const account = ctx.accountId ?? event.accountId ?? "";
  if (account && account !== config.account) {
    return { payload: null, skip: "wrong-account" };
  }
  // Envelope identity: the ctx field first, then the event's own sender field.
  // Never `event.content` / a parsed name.
  const user = (ctx.senderId ?? event.senderId ?? "").trim();
  if (!user) return { payload: null, skip: "no-sender" };
  const channel = (ctx.channelId ?? event.channel ?? "").trim();
  if (!channel) return { payload: null, skip: "no-channel" };
  const botId = event.botId ?? null;
  if (botId) return { payload: null, skip: "from-bot" };
  const subtype = event.subtype ?? null;
  if (subtype) return { payload: null, skip: "subtype" };
  const text = (event.content ?? event.body ?? "").trim();
  if (!text) return { payload: null, skip: "empty" };
  // The row's idempotency key is (channel, ts). Prefer the Slack ts, then the
  // message id - both name one message, so a Slack retry updates the same row
  // instead of doubling it against the burst caps. The epoch is NOT a key: two
  // distinct asks in the same second would share a row and lose one. A message
  // with no unique key carries an empty ts: a constant would fold every such
  // message into one row and answer the second asker with the first ask's reply,
  // so the router refuses to claim it instead.
  const ts = (event.ts ?? ctx.messageId ?? event.messageId ?? "").trim();
  const thread = event.threadTs
    ?? (event.threadId != null ? String(event.threadId) : null)
    ?? (event.replyToId != null ? String(event.replyToId) : null);
  return {
    payload: {
      account_id: config.account,
      channel,
      user_id: user,
      text,
      // Slack ts is the row's identity (channel+ts is the idempotency key), so a
      // missing one is never replaced by a constant or by "now": the router
      // refuses to claim the message instead.
      ts,
      thread_ts: thread,
      is_dm: isDirectMessage(channel, event.isGroup),
      display_name: ctx.senderName ?? event.senderName ?? null,
      bot_id: botId,
      subtype,
    },
    skip: null,
  };
}

/** Channels the router may answer in. The allowlist itself lives in
 *  policies/ops-intake-actions.json (.channels) and is enforced in Python. */
export function channelAllowed(
  payload: RouterPayload,
  configuredChannels: readonly string[],
  allowDirectMessages: boolean,
): boolean {
  if (payload.is_dm) return allowDirectMessages;
  return configuredChannels.includes(payload.channel);
}

/**
 * The line posted when the router itself cannot decide.
 *
 * Fails CLOSED: claiming the message keeps the OpenClaw agent (and its credit
 * judgement) out of the thread, says plainly that nothing was done, and names the
 * human path. It never guesses a class or a verdict.
 */
export function routerUnavailableReply(detail: string): string {
  const why = detail.replace(/\s+/g, " ").slice(0, 200);
  return (
    "ops-intake · router-unavailable · failed: no action taken · " +
    `ids=none · next=human review (router error: ${why}) · ledger=-`
  );
}

/**
 * The line posted when the message cannot be keyed at all.
 *
 * `(channel, ts)` is the ask register's idempotency key, so a message with no
 * stable ts cannot become a row and the coded router cannot answer it. It must
 * still not reach an agent turn: the plugin claims it and says plainly that
 * nothing was done, naming the human path. Same contract shape as
 * `routerUnavailableReply`, with `-` where the ask id would be.
 */
export function unkeyableReply(): string {
  return (
    "ops-intake · no-ask-row · failed: no action taken · ids=none · " +
    "next=human review (message carried no stable Slack ts) · ledger=-"
  );
}
