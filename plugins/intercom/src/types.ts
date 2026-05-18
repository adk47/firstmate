// --- Intercom webhook payload types ---

export interface IntercomWebhookPayload {
  type: "notification_event";
  app_id: string;
  data: {
    type: "notification_event_data";
    item: IntercomConversation;
  };
  topic: IntercomWebhookTopic;
  id: string;
  created_at: number;
  delivery_status: string;
  delivery_attempts: number;
}

export type IntercomWebhookTopic =
  | "conversation.user.created"
  | "conversation.user.replied"
  | "conversation.admin.replied"
  | "conversation.admin.assigned"
  | "conversation.admin.closed"
  | "conversation.admin.opened"
  | "conversation.admin.snoozed"
  | "conversation.admin.noted";

// Shared across two Intercom shapes:
//   - webhook notification payloads → `assignee` object
//   - API v2.11 GET /conversations/{id} → `admin_assignee_id` / `team_assignee_id`
// Both field sets are optional so a single type can represent either shape.
// Consumers must handle both when reading assignment state.
export interface IntercomConversation {
  type: "conversation";
  id: string;
  title: string | null;
  created_at: number;
  updated_at: number;
  open: boolean;
  state: "open" | "closed" | "snoozed";
  // Webhook payload shape. Typically absent on API v2.11 GET responses —
  // but consumers must handle the case where both this and the API
  // fields are populated (e.g., if Intercom ever converges shapes).
  assignee?: {
    type: "admin" | "nobody_admin" | "bot";
    id: string;
    name?: string;
  } | null;
  // API v2.11 GET /conversations/{id} shape. Typically absent on webhook
  // payloads. When both this and `assignee` are present, callers must
  // prefer `admin_assignee_id` (see handler.ts live check + slack.ts
  // describeAssignee — enforced by the "prefers admin_assignee_id over
  // assignee when both are present" regression tests).
  admin_assignee_id?: number | null;
  team_assignee_id?: number | null;
  conversation_parts?: {
    conversation_parts: IntercomConversationPart[];
  };
  source?: {
    body: string;
    author: IntercomAuthor;
  };
  tags?: {
    type: "tag.list";
    tags: Array<{ id: string; name: string }>;
  } | null;
}

export interface IntercomConversationPart {
  type: "conversation_part";
  id: string;
  body: string;
  part_type: string;
  created_at: number;
  author: IntercomAuthor;
}

export interface IntercomAuthor {
  type: "user" | "admin" | "bot";
  id: string;
  name?: string;
  email?: string;
}

// --- Session state ---

export type AssigneeType = "admin" | "nobody_admin" | "bot";
export type HandoffMode = "agent_active" | "human_takeover";
export type LifecycleState = "open" | "snoozed" | "closed";

export interface IntercomSessionState {
  conversationId: string;
  workspaceId: string;
  handoffMode: HandoffMode;
  lifecycleState: LifecycleState;
  currentAssigneeId: string | null;
  currentAssigneeType: AssigneeType | null;
  lastEventId: string | null;
  processedEventIds: string[];
  outboundMessageIds: string[];
  createdAt: string;
  updatedAt: string;
  knownFacts?: KnownFacts;
  escalationFiredAt?: string | null;
  userTurnCount?: number;
}

// --- Config ---

export interface IntercomAccountConfig {
  enabled: boolean;
  workspaceId: string;
  token: string;
  webhookSecret: string;
  botAdminId: string;
  defaultInboxId: string;
  fallbackSlackSupervisionChannel: string;
  fallbackAcknowledgement: string;
  requireMappedHumanAdmin: boolean;
  adminMapping: Record<string, string>;
  riskAssessment?: {
    enabled: boolean;
    judgeModel?: string;
    judgeMinTurnCount?: number;
    turnCountHardCap?: number;
    openrouterApiKey?: string;
  };
  clickup?: {
    apiKey: string;
    listId: string;
    userEmailFieldId: string;
    profileIdFieldId: string;
  };
  // Hard-skip dispatch for any inbound customer message on a conversation
  // tagged with one of these names (case-insensitive). Used to disable
  // Caroline on social-media channels (instagram, facebook, x, etc.) when
  // the upstream platform connector can't be cleanly turned off at the
  // source. Tag-based because Intercom collapses all of these channels into
  // source.type="conversation" and the only reliable channel signal in the
  // webhook payload is the workflow-applied tag. Default: no blocking.
  blockedChannelTags?: string[];
}

// --- Intercom Client ---

export interface IntercomClient {
  replyToConversation(params: {
    conversationId: string;
    adminId: string;
    body: string;
  }): Promise<{ messageId: string }>;

  assignConversation(params: {
    conversationId: string;
    adminId: string;
    assigneeId: string;
  }): Promise<void>;

  getConversation(params: {
    conversationId: string;
  }): Promise<IntercomConversation>;
}

// --- Event classification ---

export type ClassifiedEvent =
  | { kind: "customer_message"; conversationId: string; body: string; authorId: string }
  | { kind: "admin_reply"; conversationId: string; adminId: string; adminType: AssigneeType; messageId: string }
  | { kind: "assigned"; conversationId: string; assigneeId: string; assigneeType: AssigneeType }
  | { kind: "lifecycle"; conversationId: string; state: LifecycleState }
  | { kind: "noted"; conversationId: string }
  | { kind: "unknown"; topic: string };

// --- Escalation ---

export interface EscalationResult {
  triggered: boolean;
  category?: string;
  matchedPattern?: string;
}

// --- Pinned facts ---

export interface KnownFacts {
  accountEmail?: string;
  musoProfileUrl?: string;
  musoProfileId?: string;
  factsLastUpdated?: string;
}

// --- Risk assessment (replaces narrow EscalationResult for the new path) ---

export type RiskSource = "user_request" | "rule" | "judge";

export type RiskActionType =
  | "subscription-refund"
  | "dispute"
  | "support-general";

export interface RiskAssessment {
  triggered: boolean;
  source?: RiskSource;
  reason?: string;
  matchedPattern?: string;
  suggestedActionType?: RiskActionType;
  confidence?: "low" | "medium" | "high";
}

// --- Constants ---

export const MAX_PROCESSED_EVENT_IDS = 1000;
export const MAX_OUTBOUND_MESSAGE_IDS = 500;
export const DEFAULT_FALLBACK_ACK = "We're looking into this and will get back to you shortly.";

// Risk-assessment defaults — single source of truth, referenced by escalation.ts
// and channel.ts so the two stay in sync.
export const DEFAULT_JUDGE_MIN_TURNS = 4;
export const DEFAULT_TURN_HARD_CAP = 6;
export const DEFAULT_JUDGE_MODEL = "anthropic/claude-haiku-4-5-20251001";

// SLA strings surfaced verbatim to the customer in the escalation farewell.
// Source of truth: support team runbook. If support's published SLA changes,
// update this map — there is no other authoritative source.
export const TIER_SLA: Record<1 | 2 | 3, string> = {
  1: "2 business days",
  2: "5 business days",
  3: "5-10 business days",
};

// ClickUp priority maps to support tier (lower number = more urgent).
export const TIER_PRIORITY: Record<1 | 2 | 3, 1 | 2 | 3> = {
  1: 3,
  2: 2,
  3: 1,
};

// Action-type → tier ladder. Action types that don't appear here default to tier 1.
export const TIER_BY_ACTION: Record<RiskActionType, 1 | 2 | 3> = {
  "subscription-refund": 3,
  "dispute": 3,
  "support-general": 1,
};
