// Shared ClickUp ticket formatting for hydra action-request tickets
// (list 901000600160). VENDORED TWIN: this file exists byte-identically as
//   plugins/support-tools/src/tools/ticket-format.ts
//   plugins/intercom/src/ticket-format.ts
// because plugins are self-contained packages (own dist/ + lockfile). Keep
// both copies in sync — each plugin's test suite has a parity test that
// fails on any divergence.
//
// HARD CONSTRAINT: ops automation (operations agent, scripts/dedup/sweeps/
// close-merged-tickets.sh) parses the JSON between ---ACTION-REQUEST--- and
// ---END-ACTION-REQUEST--- in the task DESCRIPTION. Follow-up comments use
// the distinct ---ACTION-REQUEST-UPDATE--- markers so they can never be
// mistaken for the original request block.

// Literal-union tier keeps the per-tier maps compile-time exhaustive — a new
// tier added to TIER_MAP without SLA/priority entries is a type error, not a
// silent `priority: undefined` at one of the two call sites.
export type Tier = 1 | 2 | 3;

export const TIER_MAP: Record<string, Tier> = {
  "credit-claim": 1, "credit-correction": 1, "credit-verify": 1, "profile-claim": 1, "support-general": 1, "analytics-followup": 1, "order-fulfillment": 1,
  "profile-merge": 2, "unmerge-request": 2, "bulk-credit-change": 2, "profile-update": 2, "track-merge": 2, "billing-issue": 2,
  "subscription-refund": 3, "data-deletion": 3, "dispute": 3, "data-export": 3,
};

export const TIER_TO_PRIORITY: Record<Tier, number> = { 1: 3, 2: 2, 3: 1 };

export const TIER_SLAS: Record<Tier, string> = {
  1: "2 business days",
  2: "5 business days",
  3: "5-10 business days",
};

const TIER_SLA_BUSINESS_DAYS: Record<Tier, number> = { 1: 2, 2: 5, 3: 10 };

export function getTierForAction(actionType: string): Tier {
  return TIER_MAP[actionType] ?? 1;
}

// Credit, claim and merge requests are decided by the agent lanes under written rules
// (captain 2026-10-26 21:05Z: no human queues), not by a human review queue, so there is
// no human-review turnaround to promise. The tier SLA stays INTERNAL (the ClickUp due date
// and the overdue sweep still use it) but is never handed to Caroline to quote: the
// 2026-10-26 merge audit found 27 of 30 merge asks told "within 5 business days" from this
// field while 0 merge tickets closed in 7 days. The outcome reaches the customer as a reply
// in their own Intercom conversation when it lands.
export const AGENT_LANE_ACTIONS: ReadonlySet<string> = new Set([
  "credit-claim", "credit-correction", "credit-verify", "bulk-credit-change", "profile-claim",
  "profile-merge", "track-merge", "unmerge-request",
]);

// How the outcome of a request reaches the customer, so Caroline never promises a channel
// that does not carry it (Fable caroline-instructions-1029 §2).
//   conversation       merge kinds: merge-outcome-notify replies in the ticket's conversation.
//   app_notification   profile-claim: the claim lane's message (in-app + email), not a reply here.
//   conversation_email credit kinds and person-owned kinds: this conversation and email.
//   erasure            data-deletion: the written confirmation on this thread within one month.
export type OutcomeChannel = "conversation" | "app_notification" | "conversation_email" | "erasure";
export function outcomeChannelFor(actionType: string): OutcomeChannel {
  if (actionType === "profile-merge" || actionType === "track-merge" || actionType === "unmerge-request") {
    return "conversation";
  }
  if (actionType === "profile-claim") return "app_notification";
  if (actionType === "data-deletion") return "erasure";
  return "conversation_email";
}

// The timeframe Caroline may quote to the customer: none, for every kind. Fable
// caroline-instructions-1029 §2.9/§3 (captain 2026-10-29): no day counts and no business
// days on any reply ("5-10 business days", "2 business days", "within 5 business days" are
// never said; a refund ack quoting "5-10 business days" was seen live 2026-10-28). The tier
// SLA stays INTERNAL (ClickUp due date, overdue sweep, the Slack escalation line).
export function customerSlaFor(_actionType: string): string | null {
  return null;
}

// Growth owns account/billing/support; Catalog owns the catalog data
// (credits, profiles, tracks, analytics, merges).
export const GROWTH_ACTIONS = new Set([
  "subscription-refund", "billing-issue", "data-deletion", "data-export", "dispute", "support-general", "order-fulfillment",
]);

// Short labels for the title; anything not listed renders verbatim.
const ACTION_LABELS: Record<string, string> = {
  "subscription-refund": "refund",
  "support-general": "support",
  "order-fulfillment": "order",
};

// Known human-handoff reasons (see action-request SKILL.md). Unknown values
// are NOT tagged — tags are a filtering surface, not a free-form channel.
const ESCALATION_REASONS = new Set([
  "customer_requested_human", "frustration_detected", "loop_detected",
  "intercom_email_mismatch", "rights_holder",
  "sla_breach_customer_followup", "on_behalf_claim_manual_review",
]);

// Reasons that also bump the ticket to ClickUp Urgent (priority 1) when set
// on a follow-up append: the customer is already past a promised SLA.
export const URGENT_ESCALATION_REASONS = new Set(["sla_breach_customer_followup"]);

// Resolve a details.escalation_reason value to its tag, or null when the
// reason is unknown (unknown values are NOT tagged — tags are a filtering
// surface, not a free-form channel).
export function escalationTag(details?: Record<string, unknown>): string | null {
  const reason = details?.escalation_reason;
  if (typeof reason === "string" && ESCALATION_REASONS.has(reason)) {
    return `escalation:${reason.replace(/_/g, "-")}`;
  }
  return null;
}

export function musoProfileUrl(profileId: string): string {
  return `https://credits.muso.ai/profile/${profileId}`;
}

export function intercomDeeplink(workspaceId: string, conversationId: string): string {
  return `https://app.intercom.com/a/inbox/${workspaceId}/inbox/conversation/${conversationId}`;
}

const MAX_GIST_CHARS = 60;

function normalizeGist(gist: string): string {
  const collapsed = gist.replace(/\s+/g, " ").trim();
  if (collapsed.length <= MAX_GIST_CHARS) return collapsed;
  return `${collapsed.slice(0, MAX_GIST_CHARS - 1).trimEnd()}…`;
}

export function buildTicketTitle(params: { actionType: string; gist: string; customerEmail: string }): string {
  const label = ACTION_LABELS[params.actionType] ?? params.actionType;
  return `[${label}] ${normalizeGist(params.gist)} — ${params.customerEmail}`;
}

export interface TicketContentParams {
  summary: string;
  actionType: string;
  tier: Tier;
  customerEmail: string;
  customerProfileId?: string;
  details?: Record<string, unknown>;
  conversationSummary: string;
  sessionId: string;
}

function buildJsonBlock(params: TicketContentParams, openMarker: string, closeMarker: string): string {
  const actionRequest = {
    action_type: params.actionType,
    approval_tier: params.tier,
    customer_email: params.customerEmail,
    customer_profile_id: params.customerProfileId ?? null,
    details: params.details ?? {},
    conversation_summary: params.conversationSummary,
    cs_session_id: params.sessionId,
  };
  return [openMarker, JSON.stringify(actionRequest, null, 2), closeMarker].join("\n");
}

function detailBullets(details: Record<string, unknown> | undefined): string[] {
  if (!details || Object.keys(details).length === 0) return [];
  const bullets = Object.entries(details).map(
    ([k, v]) => `- ${k}: ${typeof v === "string" ? v : JSON.stringify(v)}`,
  );
  return ["**Details:**", ...bullets, ""];
}

export type TicketMarkdownParams = TicketContentParams & {
  gist: string;
  sla: string;
  customerName?: string;
  intercomUrl?: string;
};

// ClickUp truncates the description it projects as `text_content` (measured
// 2026-11-04: 333 of 784 tickets are exactly 1,500 bytes long). The
// ---ACTION-REQUEST--- JSON block sits LAST, so it is where the cut lands — 292
// of 784 are truncated mid-JSON today, which is why the ops sweep cannot parse
// them and every escalation hand-off has `details: {}`. The current body is
// already near that size, so the hand-off fix (a real question + a conversation
// excerpt, which the JSON must also carry) would push the block further past the
// cut unless the body is bounded here rather than hoped to be small.
//
// Bound the DISPLAY-and-machine duplication — `conversation_excerpt` is the only
// field that appears both as a bullet and in the JSON — never the machine block
// and never its position.
export const MAX_TICKET_DESCRIPTION_CHARS = 3000;
const EXCERPT_BULLET_MIN_CHARS = 120;

function clipToWordBoundary(text: string, maxChars: number): string {
  if (text.length <= maxChars) return text;
  const cut = text.slice(0, Math.max(1, maxChars));
  const lastSpace = cut.lastIndexOf(" ");
  if (lastSpace <= 0) return `${cut}…`;
  return `${cut.slice(0, lastSpace).trimEnd()}…`;
}

function renderTicketMarkdown(params: TicketMarkdownParams): string {
  const customer = params.customerName
    ? `${params.customerEmail} (${params.customerName})`
    : params.customerEmail;
  const profile = params.customerProfileId ? musoProfileUrl(params.customerProfileId) : "—";
  return [
    `## ${normalizeGist(params.gist)}`,
    "",
    `**Customer:** ${customer}`,
    `**Profile:** ${profile}`,
    `**Conversation:** ${params.intercomUrl ?? "—"}`,
    `**Action:** ${params.actionType} · Tier ${params.tier} · SLA ${params.sla}`,
    "",
    `**Request:** ${params.summary}`,
    "",
    ...detailBullets(params.details),
    `**Conversation summary:** ${params.conversationSummary}`,
    "",
    buildJsonBlock(params, "---ACTION-REQUEST---", "---END-ACTION-REQUEST---"),
  ].join("\n");
}

export function buildTicketMarkdown(params: TicketMarkdownParams): string {
  let current = params;
  let body = renderTicketMarkdown(current);
  // Converges in one or two passes: the value is duplicated, so trimming N chars
  // from the excerpt shortens the body by about 2N (bullet + JSON).
  for (let attempt = 0; attempt < 8 && body.length > MAX_TICKET_DESCRIPTION_CHARS; attempt += 1) {
    const excerpt = current.details?.conversation_excerpt;
    if (typeof excerpt !== "string" || excerpt.length <= EXCERPT_BULLET_MIN_CHARS) break;
    const overflow = body.length - MAX_TICKET_DESCRIPTION_CHARS;
    const target = Math.max(EXCERPT_BULLET_MIN_CHARS, excerpt.length - Math.ceil(overflow / 2) - 40);
    if (target >= excerpt.length) break;
    current = {
      ...current,
      details: { ...current.details, conversation_excerpt: clipToWordBoundary(excerpt, target) },
    };
    body = renderTicketMarkdown(current);
  }
  return body;
}

export function buildFollowupComment(params: TicketContentParams): string {
  return [
    `**Customer follow-up** (${params.actionType}): ${params.summary}`,
    "",
    ...detailBullets(params.details),
    `**Conversation summary:** ${params.conversationSummary}`,
    "",
    buildJsonBlock(params, "---ACTION-REQUEST-UPDATE---", "---END-ACTION-REQUEST-UPDATE---"),
  ].join("\n");
}

// Hand-off tag (captain 2026-10-28 12:1xZ: Caroline only hands off). Every credit, claim
// and merge ticket carries `handoff:<tag>`; the verification / merge agents pick their work
// up by it. The tag is derived from the ticket kind, so it can never be missing; the only
// choice Caroline makes is `details.handoff: "document"` when the customer sent proof. Any
// other value she supplies is ignored (the kind's default wins), never passed through.
export const HANDOFF_TAGS: Record<string, { default: string; allowed: readonly string[] }> = {
  "credit-claim": { default: "credit-status", allowed: ["credit-status", "document"] },
  "credit-correction": { default: "credit-status", allowed: ["credit-status", "document"] },
  "credit-verify": { default: "credit-status", allowed: ["credit-status", "document"] },
  "bulk-credit-change": { default: "credit-status", allowed: ["credit-status", "document"] },
  "profile-claim": { default: "claim", allowed: ["claim", "document"] },
  "profile-merge": { default: "merge", allowed: ["merge"] },
  "track-merge": { default: "merge", allowed: ["merge"] },
  "unmerge-request": { default: "merge", allowed: ["merge"] },
};

export function handoffTag(actionType: string, details?: Record<string, unknown>): string | null {
  const rule = HANDOFF_TAGS[actionType];
  if (!rule) return null;
  const asked = typeof details?.handoff === "string" ? details.handoff.trim().toLowerCase() : "";
  return `handoff:${rule.allowed.includes(asked) ? asked : rule.default}`;
}

export function buildTicketTags(params: {
  actionType: string;
  tier: Tier;
  details?: Record<string, unknown>;
}): string[] {
  const tags = [
    "hydra-action-request",
    `tier-${params.tier}`,
    `action:${params.actionType}`,
    GROWTH_ACTIONS.has(params.actionType) ? "team:growth" : "team:catalog",
  ];
  const escTag = escalationTag(params.details);
  if (escTag) tags.push(escTag);
  const hand = handoffTag(params.actionType, params.details);
  if (hand) tags.push(hand);
  if (params.actionType === "analytics-followup") tags.push("analytics-followup");
  return tags;
}

// Due date for ClickUp (`due_date` ms epoch, `due_date_time: false`):
// now + the tier's SLA in business days, skipping Sat/Sun (no holiday
// calendar — the SLA strings are approximate anyway). The result is pinned
// to noon UTC, which is the same calendar date across UTC-12..+11 — every
// reader of this value (the America/New_York SLA digest and the US-based
// ClickUp workspace); an un-pinned evening time-of-day would misbucket by a
// day. (At UTC+12 and beyond noon UTC rolls to the next date, but no reader
// here is in that range.)
export function slaDueDateMs(tier: Tier, nowMs: number): number {
  let remaining = TIER_SLA_BUSINESS_DAYS[tier];
  const d = new Date(nowMs);
  while (remaining > 0) {
    d.setUTCDate(d.getUTCDate() + 1);
    const day = d.getUTCDay();
    if (day !== 0 && day !== 6) remaining--;
  }
  d.setUTCHours(12, 0, 0, 0); // canonical noon UTC — same date across UTC-12..+11
  return d.getTime();
}
