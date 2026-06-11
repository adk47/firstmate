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
    // Initial-message attachments live HERE on a fresh conversation.user.created —
    // there's no conversation_part yet, so `conversation_parts[].attachments`
    // is empty. Without this, image-only first messages get dropped as
    // `unknown:empty_body`. (Clio review of PR #360.)
    attachments?: IntercomPartAttachment[];
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
  // Intercom delivers attachments uploaded by the customer as a sibling
  // `attachments` array on the conversation_part (sometimes typed
  // `part_attachments` in older API docs — both observed in the wild, but
  // v2.11 webhooks emit `attachments`). Optional because most parts have
  // none. URLs are short-lived signed downloads.intercomcdn.com links
  // (~30 min TTL) — fetch bytes synchronously at receive time.
  attachments?: IntercomPartAttachment[];
}

// Intercom v2.11 webhook `attachment` shape. Most fields are present on
// image uploads (height/width/filesize) but typed optional because future
// content types (audio/PDF) may omit them.
export interface IntercomPartAttachment {
  type: string;
  name: string;
  url: string;
  content_type: string;
  filesize?: number;
  height?: number;
  width?: number;
}

// Lightweight reference passed through classify → handle → dispatch. Carries
// only what downstream consumers need (the URL to download from, the MIME so
// we can persist with a sensible extension, and an opt name for diagnostics).
// Filtered to image MIMEs at classify time.
export interface ImageAttachmentRef {
  url: string;
  contentType: string;
  name?: string;
}

// Same shape as ImageAttachmentRef but filtered to DOCUMENT_MIME_ALLOWLIST
// (today: application/pdf only) at classify time. Kept as a distinct type so
// the document pipeline (persist original + rasterize pages) can't be
// accidentally fed an image ref or vice versa. See attachments.ts.
export interface DocumentAttachmentRef {
  url: string;
  contentType: string;
  name?: string;
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
  // Personalization context for a verified, logged-in customer. Populated at
  // most once per conversation (gated behind account.personalization.enabled),
  // fetched live from systems-of-record, and held ONLY here in session state —
  // never written to openclaw memory and never indexed. See enrichment.ts.
  enrichment?: EnrichmentState;
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
  // Personalization for verified, logged-in customers (Caroline greets by
  // name, references their work, etc.). Default OFF — when absent or
  // `enabled: false`, enrichment never runs and behavior is unchanged.
  // `timeoutMs` bounds each best-effort lookup call (default 2500ms).
  personalization?: {
    enabled: boolean;
    timeoutMs?: number;
  };
}

// --- Intercom Client ---

// Lean per-conversation summary lifted straight from a /conversations/search
// result row. `snippet` is the HTML-stripped first-message excerpt (customer-
// controlled text — sanitize before injecting into trusted context).
export interface ConversationSummary {
  id: string;
  title: string | null;
  state: "open" | "closed" | "snoozed";
  updatedAt: string; // ISO 8601
  snippet: string;
}

// One page of a contact's conversation search: the fetched window plus
// Intercom's total_count for the whole match set — the window may be smaller
// than the total, so counts must come from totalCount, never conversations.length.
export interface ContactConversationsPage {
  conversations: ConversationSummary[];
  totalCount: number;
}

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

  // Close a conversation. `body` is an optional admin close-note (sanitized by
  // SanitizingIntercomClient when present). Dormant capability — no consumer
  // wires this yet; it exists so ops sweeps / a future consent-close can
  // transition a conversation to "closed" instead of leaving it open forever.
  closeConversation(params: {
    conversationId: string;
    adminId: string;
    body?: string;
  }): Promise<void>;

  // Snooze a conversation until `snoozedUntil` (unix seconds). Dormant — used
  // by a future consent-close flow to park a conversation while awaiting a
  // customer reply. No consumer wires this yet.
  snoozeConversation(params: {
    conversationId: string;
    adminId: string;
    snoozedUntil: number;
  }): Promise<void>;

  // List a contact's conversations (most recent first) via one
  // POST /conversations/search round-trip — summaries come from the search
  // result list itself, no per-conversation GETs. Used by personalization
  // enrichment for prior-chat recall; correctly scoped per-contact by
  // Intercom (the system of record), which is what keeps it customer-
  // isolation-safe without touching openclaw memory.
  // `excludeConversationId` filters the current conversation server-side so
  // totalCount is the exact prior count even beyond the fetched page;
  // `timeoutMs` bounds the call (enrichment passes its own budget).
  listContactConversations(params: {
    contactId: string;
    excludeConversationId?: string;
    limit?: number;
    timeoutMs?: number;
  }): Promise<ContactConversationsPage>;
}

// --- Event classification ---

export type ClassifiedEvent =
  | {
      kind: "customer_message";
      conversationId: string;
      body: string;
      authorId: string;
      // Identity of the message author, read straight from the Intercom
      // author object (NOT mined from the message text). `authorType` is the
      // raw type; `verifiedEmail`/`verifiedName` are populated ONLY for a
      // `type: "user"` author (an Intercom identity-verified contact), so they
      // are safe to trust for personalization. A self-typed email in the body
      // never reaches these fields — see extractors.ts for that separate path.
      authorType?: "user" | "admin" | "bot";
      verifiedEmail?: string;
      verifiedName?: string;
      attachments?: ImageAttachmentRef[];
      documents?: DocumentAttachmentRef[];
    }
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

// --- Personalization enrichment (Caroline) ---

// Read-only account snapshot assembled from the Muso admin API (claiming →
// profile + credits, plus team founder/plan). PII-stripped at the source (no
// email/phone/payment). Kept distinct from the Intercom-verified identity
// (verifiedName/verifiedEmail) so a profile-lookup miss or ambiguous match
// never blocks a by-name greeting. Work fields (profileId..latestCreditDate)
// and account fields (founderSince/plan) populate independently — either
// half can be present without the other.
export interface AccountSnapshot {
  profileId?: string;
  name?: string;
  profileUrl?: string;
  isClaimed?: boolean;
  primaryRole?: string;
  creditsCount?: number;
  latestCreditTitle?: string;
  latestCreditDate?: string;
  // Founding-member year — set ONLY when the team's founder.active is true
  // (lapsed founders are omitted entirely; never surface lapsed status).
  founderSince?: number;
  // Subscription plan, e.g. "pro (annual)" / "lite" — from the team record.
  plan?: string;
}

export type EnrichmentStatus = "done" | "failed";

// Per-conversation personalization context: the Intercom-verified identity
// plus the looked-up account snapshot. Fetched at most once per conversation,
// best-effort. `status: "failed"` is retried on a later turn; `"done"` is not.
export interface EnrichmentState {
  status: EnrichmentStatus;
  enrichedAt: string;
  verifiedEmail?: string;
  verifiedName?: string;
  contactId?: string;
  snapshot?: AccountSnapshot;
  // Prior-support-chat pointer for THIS verified contact, summarized from
  // Intercom's per-contact conversation search (system of record — correctly
  // scoped per contact, which is what keeps cross-customer isolation intact).
  // Count excludes the current conversation; absent when there are none.
  priorChats?: {
    count: number;
    mostRecentTitle?: string;
    mostRecentAt?: string;
  };
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

// Tier ladder, SLA strings and ClickUp priority live in ticket-format.ts
// (vendored twin shared with plugins/support-tools) so both ticket creators
// agree on them.
