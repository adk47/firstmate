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
  "credit-claim": 1, "credit-correction": 1, "credit-verify": 1, "profile-claim": 1, "support-general": 1, "analytics-followup": 1,
  "profile-merge": 2, "unmerge-request": 2, "bulk-credit-change": 2, "profile-update": 2,
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

// Growth owns account/billing/support; Catalog owns the catalog data
// (credits, profiles, tracks, analytics, merges).
export const GROWTH_ACTIONS = new Set([
  "subscription-refund", "data-deletion", "data-export", "dispute", "support-general",
]);

// Short labels for the title; anything not listed renders verbatim.
const ACTION_LABELS: Record<string, string> = {
  "subscription-refund": "refund",
  "support-general": "support",
};

// Known human-handoff reasons (see action-request SKILL.md). Unknown values
// are NOT tagged — tags are a filtering surface, not a free-form channel.
const ESCALATION_REASONS = new Set([
  "customer_requested_human", "frustration_detected", "loop_detected",
]);

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

export function buildTicketMarkdown(
  params: TicketContentParams & {
    gist: string;
    sla: string;
    customerName?: string;
    intercomUrl?: string;
  },
): string {
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
  const reason = params.details?.escalation_reason;
  if (typeof reason === "string" && ESCALATION_REASONS.has(reason)) {
    tags.push(`escalation:${reason.replace(/_/g, "-")}`);
  }
  if (params.actionType === "analytics-followup") tags.push("analytics-followup");
  return tags;
}

// Due date for ClickUp (`due_date` ms epoch, `due_date_time: false`):
// now + the tier's SLA in business days, skipping Sat/Sun (no holiday
// calendar — the SLA strings are approximate anyway).
export function slaDueDateMs(tier: Tier, nowMs: number): number {
  let remaining = TIER_SLA_BUSINESS_DAYS[tier];
  const d = new Date(nowMs);
  while (remaining > 0) {
    d.setUTCDate(d.getUTCDate() + 1);
    const day = d.getUTCDay();
    if (day !== 0 && day !== 6) remaining--;
  }
  return d.getTime();
}
