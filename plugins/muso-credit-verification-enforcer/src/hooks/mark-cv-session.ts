import { markCvSession } from "../state.js";

/** Local mirrors of openclaw's inbound_claim types — structural compatibility
 *  verified at the `api.on<"inbound_claim">` registration in index.ts. */
type InboundClaimEvent = {
  content: string;
  channel: string;
  isGroup: boolean;
  body?: string;
  accountId?: string;
  conversationId?: string;
  messageId?: string;
};

type InboundClaimContext = {
  channelId: string;
  accountId?: string;
  conversationId?: string;
  sessionKey?: string;
  senderId?: string;
  messageId?: string;
};

type InboundClaimResult = { handled: boolean };

const DEFAULT_CV_CHANNEL_ID = "C0APB2CMM7C";

/** When a message arrives on the credit-verification Slack channel, mark the
 *  sessionKey as CV so subsequent tool hooks (which don't see channelId) know
 *  to fire enforcement logic. We observe and return undefined — we're not
 *  claiming the inbound. */
export function markCvSessionHook(
  _event: InboundClaimEvent,
  ctx: InboundClaimContext,
): InboundClaimResult | undefined {
  const cvChannel = process.env.OPS_CREDIT_VERIFICATION_CHANNEL_ID ?? DEFAULT_CV_CHANNEL_ID;
  if (ctx.channelId === cvChannel && ctx.sessionKey) {
    markCvSession(ctx.sessionKey);
  }
  return undefined;
}
