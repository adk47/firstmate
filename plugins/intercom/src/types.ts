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

// An attachment Intercom DELIVERED that no forwarding path accepts (image/tiff,
// image/bmp, video/*, …). Same shape as the two refs above, kept distinct so it
// can never be mistaken for something the pipeline will try to download: these
// are refused at classify time and never fetched.
//
// It exists because counting the drop was not enough: a content-type dropped
// at extraction with only a log line left the agent answering from an evidence
// set it had no way to know was incomplete. Carrying the ref is what lets
// channel.ts mint an `unsupported_type` record for it.
export interface UnsupportedAttachmentRef {
  url: string;
  contentType: string;
  name?: string;
  /** WHY it was refused, decided at extraction time. Kept as a literal union
   *  here (rather than importing UnreadableReason) because attachments.ts
   *  already imports from filters.ts — the other direction would be a cycle. */
  reason: "unsupported_type" | "host_not_allowed";
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
  // ClickUp ticket id from the escalation's Step 2, kept so a rollback of
  // `escalationFiredAt` (both farewell AND Slack failed, so the retry must be
  // allowed) does not also re-file the ticket that already exists. The escalation
  // path deliberately skips the open-ticket dedupe (see clickup.ts) on the premise
  // that it fires at most once per conversation — this field is what keeps that
  // premise true across a rollback. Survives rollback ON PURPOSE.
  escalationTicketId?: string | null;
  // The suggestedActionType the ticket above was FILED with. The ticket carries
  // that action's tier, priority and ClickUp due date, and a retry can arrive
  // with a different assessment — so the SLA quoted to the customer must be
  // derived from this, not from whatever the retry reassessed.
  escalationTicketActionType?: string | null;
  // Dedup gate for the priority signal (Lane A). Set once per conversation the
  // first time Caroline's `[[PRIORITY]]` token fires, so we tag the conversation
  // `ai:data-complaint` (for the systemic watchdog's count) only once. Distinct
  // from escalationFiredAt: the priority signal is a lightweight classification
  // that leaves Caroline active, whereas escalationFiredAt gates the heavyweight
  // human-takeover handoff.
  priorityFiredAt?: string | null;
  userTurnCount?: number;
  // Personalization context for a verified, logged-in customer. Populated at
  // most once per conversation (gated behind account.personalization.enabled),
  // fetched live from systems-of-record, and held ONLY here in session state —
  // never written to openclaw memory and never indexed. See enrichment.ts.
  enrichment?: EnrichmentState;
  // Top KB snippets retrieved (mandatory pre-retrieval RAG) for THIS turn, gated
  // behind account.kbRetrieval.enabled. Injected into the agent's context as a
  // [KNOWLEDGE_BASE] block by buildAgentRawBody. Held only in this per-conversation
  // session state (so it lands in the session store with the rest of the state) and
  // overwritten every dispatch turn; never indexed into openclaw vector memory. See
  // kb-retrieval.ts.
  kbSnippets?: KbSnippet[];
  // Jev pre-turn router result for THIS turn, gated behind account.jev.enabled. On
  // a "route"/"decline" action, `block` is rendered as a [ROUTING] block by
  // buildAgentRawBody, right before [CUSTOMER_MESSAGE]. `badFaithDeclinedAt` is a
  // once-per-conversation gate: the first bad-faith turn declines, every later
  // bad-faith turn silences. Overwritten every dispatch turn (badFaithDeclinedAt
  // persists across overwrites once set). See jev-router.ts.
  jev?: {
    action: "route" | "decline" | "silence" | "escalate" | "none";
    block: string | null;
    answers?: Record<string, unknown>;
    badFaithDeclinedAt?: string | null;
  };
}

/** A single retrieved knowledge-base chunk (snippet text + provenance for logs). */
export interface KbSnippet {
  snippet: string;
  path?: string;
  score?: number;
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
  // NB: the priority signal no longer pages from this lane. On `[[PRIORITY]]`,
  // Caroline's conversation is just TAGGED `ai:data-complaint` (priority-signal.ts);
  // the Lane B watchdog (scripts/intercom-data-complaint-watchdog.py) pages
  // leadership only when a data category crosses many users (systemic). So there
  // is no per-account Slack channel / mention config here anymore.
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
  // Mandatory pre-retrieval RAG: search the reference KB on every answer-bearing
  // inbound and inject the top hits before the model generates. Default OFF (when
  // absent or enabled:false, no retrieval runs and behavior is unchanged).
  // `minScore` defaults to 0 deliberately (see kb-retrieval.ts). `timeoutMs`
  // bounds the search on the hot reply path (default 1500ms).
  kbRetrieval?: {
    enabled: boolean;
    timeoutMs?: number;
    maxResults?: number;
    minScore?: number;
    agentId?: string;
  };
  // Jev pre-turn router (docs/designs/2026-09-22-jev-caroline-router.md). One
  // typed-judgment call per turn classifies the customer message against
  // Caroline's real tool/skill inventory; the plugin acts on three of the
  // answers itself (silence, decline-then-silence, escalate) and injects the
  // rest as a [ROUTING] block. Also replaces the OpenRouter judge in
  // buildRiskOptions when enabled (same pre-turn answers, no second request).
  // `apiKey` is a SecretRef resolved to a plaintext string by
  // secret-contract-api.ts before the plugin ever reads it (mirrors
  // `clickup.apiKey`). Missing apiKey with enabled:true fails config load,
  // same as a missing token (see config.ts).
  jev?: {
    enabled: boolean;
    apiKey: string;
    model?: string;
    timeoutMs?: number;
    bands: {
      bad_faith: number;
      no_reply: number;
      human_required: number;
    };
    // Per-branch kill switches — see DEFAULT_JEV_ACTIONS. When a switch is
    // off, that branch's band hit resolves to `route` instead (silence/
    // escalate log a `suppressed=<branch>` token on the [intercom:jev] line
    // so jev-shadow-report.sh can still count what it would have done).
    actions: {
      decline: boolean;
      silence: boolean;
      escalate: boolean;
    };
  };
  // Upper bound (ms) on how long we wait for a single agent dispatch to return
  // before treating the conversation lane as wedged. The dispatch await
  // (channel.ts) is raced against this timeout; on timeout we page
  // #cs-escalations with reason `dispatch_timed_out` (see silent-dispatch.ts)
  // and post NOTHING to the customer. Must sit well above real p99 dispatch
  // latency (~10-15s observed) and below openclaw's ~360s runtime stuck-session
  // abort. Default DEFAULT_DISPATCH_TIMEOUT_MS (90s) when absent.
  dispatchTimeoutMs?: number;
  // Coalesce rapid-fire inbound messages per conversation: while one agent
  // dispatch is in flight, later dispatch_to_agent events queue and are
  // combined into the NEXT single dispatch (removes the overlapping-
  // embedded_run trigger for upstream openclaw lane wedges, #97538).
  // Webhook handling / escalation / state updates are NOT coalesced.
  // Default ON; set false to restore one-dispatch-per-message behavior.
  coalesceDispatch?: boolean;
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

  // Attach a tag (by name) to a conversation. Used by the priority signal to
  // mark a conversation `ai:data-complaint` so the Lane B systemic watchdog can
  // fold it into its cross-user cluster count. Resolves the tag by name to its
  // id (creating it if absent) then attaches it. Best-effort at the call site —
  // never let a tag failure affect the customer reply.
  addTag(conversationId: string, name: string, adminId: string): Promise<void>;

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
      /** Delivered but not forwardable (unsupported content-type). Carried so
       *  the dispatch layer can tell the agent one arrived — see
       *  `unsupported_type` in attachments.ts. */
      unsupportedAttachments?: UnsupportedAttachmentRef[];
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
  // Workspace/account display name (team.name) — set ONLY for active founders,
  // and only when it's a real label/org name. Auto-generated personal-workspace
  // defaults ("<Person>'s Workspace") are suppressed at the source, so this is a
  // safe recognition hook for org/label founders; individuals fall back to the
  // first-name greeting. Founder-gated so non-founder behaviour is unchanged.
  accountName?: string;
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
  | "data-deletion"
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

// Jev band defaults (docs/designs/2026-09-22-jev-caroline-router.md; raised
// from an earlier 0.7/0.8/0.8 to 0.85/0.90/0.90 after the 197-turn real-
// conversation backtest — a Spanish status-ping scored human_required 0.79,
// so 0.8 would have escalated it). Applied per-key in config.ts so a
// partially-specified `jev.bands` in openclaw-*.json still fails loud on an
// out-of-range value but falls back band-by-band for anything omitted —
// which is why the DEFAULT has to be safe on its own, not merely whatever
// openclaw-edge.json happens to override it with today.
//
// `bad_faith` raised again 0.85 -> 0.92 (2026-09-22): a real customer opening
// "I am the sole legal owner and proprietor of the registered entity …"
// scores 0.90 (conversation 215475985153553; stable across two full backtest
// runs), and declining that person is the exact harm this band exists to
// prevent. 0.92 keeps every true positive the troll produced.
export const DEFAULT_JEV_BANDS = {
  bad_faith: 0.92,
  no_reply: 0.9,
  human_required: 0.9,
} as const;

// Per-branch kill switches (docs/designs/2026-09-22-jev-caroline-router.md;
// added after a 202-turn backtest found no safe band for `no_reply` — real
// waiting customers like "Hi you got some news ?" still scored 0.97 with the
// closer guard — or `human_required` — the 6 customers who explicitly asked
// for a person scored median 0.39, so the keyword/rule escalation layer is
// the right detector there, not Jev). A band alone cannot express "never
// fire": probabilities reach 1.0, so 0.99 is not "off". `bad_faith` stayed
// on (97.5% agreement, zero false positives at its 0.92 band). Conservative defaults:
// decline on, silence/escalate off until backtest data says otherwise for
// those two branches specifically.
export const DEFAULT_JEV_ACTIONS = {
  decline: true,
  silence: false,
  escalate: false,
} as const;

// Default dispatch-await timeout (ms). See IntercomAccountConfig.dispatchTimeoutMs.
// 90s: >> real p99 dispatch (~10-15s) so healthy slow replies never false-page,
// and << openclaw's ~360s runtime stuck-session abort so we page BEFORE the
// runtime silently discards the wedged reply.
export const DEFAULT_DISPATCH_TIMEOUT_MS = 90_000;

// Risk-assessment defaults — single source of truth, referenced by escalation.ts
// and channel.ts so the two stay in sync.
export const DEFAULT_JUDGE_MIN_TURNS = 4;
export const DEFAULT_TURN_HARD_CAP = 6;
export const DEFAULT_JUDGE_MODEL = "anthropic/claude-haiku-4-5-20251001";

// Tier ladder, SLA strings and ClickUp priority live in ticket-format.ts
// (vendored twin shared with plugins/support-tools) so both ticket creators
// agree on them.
