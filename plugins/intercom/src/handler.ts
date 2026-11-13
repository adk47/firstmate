import type {
  IntercomWebhookPayload,
  IntercomSessionState,
  IntercomClient,
  IntercomConversation,
  IntercomConversationPart,
  RiskAssessment,
  ImageAttachmentRef,
  UnsupportedAttachmentRef,
  DocumentAttachmentRef,
} from "./types.js";
import { RateLimitError } from "./outbound.js";
import { classifyEvent, createEventIdSet, isEventProcessed, trackEventId, isSelfReply, customerSpokeLast } from "./filters.js";
import { checkEscalation, assessRisk, type AssessRiskDeps } from "./escalation.js";
import { restrictionFor } from "./restricted-accounts.js";
import { escalationGoesToQueue, humanHold } from "./assignment-policy.js";
import { updateKnownFacts } from "./extractors.js";
import { shouldEnrich, type VerifiedIdentity } from "./enrichment.js";
import {
  decide as decideJev,
  formatJevLogLine,
  type JevActionsConfig,
  type JevBands,
  type JevTurnInput,
  type JevTurnOutcome,
  type JevV2Author,
  type JevV2Part,
} from "./jev-router.js";
import { appendJevShadowRow } from "./jev-shadow-log.js";
import { containsMergeParagraph } from "./merge-reply-guard.js";
import { DEFAULT_JEV_MODEL } from "./jev-client.js";
import {
  handleAssignment,
  handleAdminReply,
  handleLifecycleChange,
  handleImplicitReopen,
  canAgentReply,
} from "./handoff.js";

// Module-level set of conversation ids we've already warned about for the
// "unexpected API shape" branch (neither admin_assignee_id nor assignee
// present on the live-check response). Prevents log spam while still
// surfacing shape drift the first time it's seen per process lifetime.
const apiShapeWarned = new Set<string>();

// Turn counting for the hard turn-count cap (escalation.ts Layer 1b) counts EXCHANGES, not
// messages: a customer message that follows another customer message with no reply in between
// (any admin comment: Caroline or a human) continues the same turn. Customers routinely split
// one ask across several messages ("Hi" / the ask / a link / another link). On 2026-10-15/16
// all 9 conversations that hit the cap (14) were long legitimate multi-step requests (merges,
// multi-track credit adds), with 3-11 sub-25-character messages each, and none would have
// reached 14 exchanges when the cap fired (9-13). The cap still bounds a runaway loop:
// every counted turn needs a reply in between.
//
// Fails toward COUNTING: when the live conversation is unavailable or the current message
// cannot be located, the message counts as a new turn, exactly as before this change.
export function continuesCustomerBurst(
  source: IntercomConversation["source"] | undefined,
  parts: IntercomConversationPart[] | undefined,
  currentBody: string,
): boolean {
  if (!parts) return false;
  const isUser = (t: string | undefined) => t === "user" || t === "lead" || t === "contact";
  const strip = (b: string | null | undefined) => (b ?? "").replace(/<[^>]*>/g, "").trim();
  // Visible customer/admin messages in order. Notes and system parts never end a burst.
  const visible: Array<{ user: boolean; body: string }> = [];
  // Attachment-only messages (e.g. an opening screenshot with an empty body) are still messages.
  if (source && (strip(source.body) || source.attachments?.length)) {
    visible.push({ user: isUser(source.author?.type), body: strip(source.body) });
  }
  for (const p of parts) {
    if (p.part_type === "note") continue;
    const body = strip(p.body);
    if (!body && !(p.attachments && p.attachments.length)) continue;
    const t = p.author?.type;
    if (isUser(t)) visible.push({ user: true, body });
    else if (t === "admin" && (p.part_type === "comment" || p.part_type === "assign_and_reopen" || p.part_type === "open")) {
      visible.push({ user: false, body });
    }
  }
  // The live GET runs after the webhook, so the current message is normally the LAST user
  // entry with nothing after it. Anything else (a later reply or message) means the GET does not
  // reflect this message as the latest, so don't guess.
  const idx = visible.length - 1;
  if (idx <= 0 || !visible[idx].user || visible[idx].body !== strip(currentBody)) return false;
  return visible[idx - 1].user;
}

// Finding 2 (2026-09-22 PR #999 QA): assessRisk (Layer 1b judge) and runJev
// both need the conversation SO FAR to classify a follow-up correctly (e.g.
// "it still is not fixed" is meaningless without the request it answers).
// Production never supplied HandlerOptions.recentParts, so both always saw
// `[]`. Built here from the SAME `client.getConversation` response the live
// check already fetches a few lines up — zero new API calls. The live-check
// GET is taken AFTER the triggering webhook, so its own `conversation_parts`
// almost always already includes the part that produced `classified.body`;
// that trailing part is dropped below to avoid double-counting the current
// turn.
//
// QA re-review (2026-09-22, still on PR #999): Intercom stores the OPENING
// customer message on `conversation.source`, NOT in `conversation_parts` —
// see the IntercomConversation.source doc comment in types.ts. Without it,
// the common second-turn flow (source "where is my credit" -> Caroline's
// reply -> user "it still is not fixed") fed Jev only Caroline's reply,
// dropping the request the follow-up refers to. `source` is included FIRST
// (it's chronologically earliest), normalized the same way conversation
// parts are, and is itself subject to the same current-turn de-dup check —
// on a genuine first turn, `source` IS `classified.body`, so it must not be
// double-counted as "history".
function buildRecentPartsFromLiveConversation(
  source: IntercomConversation["source"] | undefined,
  parts: IntercomConversationPart[] | undefined,
  botAdminId: string,
  currentBody: string,
): { author: "user" | "bot"; body: string }[] {
  const out: { author: "user" | "bot"; body: string }[] = [];
  const currentStripped = currentBody.replace(/<[^>]*>/g, "").trim();

  if (source) {
    const body = (source.body ?? "").replace(/<[^>]*>/g, "").trim();
    // Excluded here (not via the trailing-dedup check below) because a
    // first-turn `source` is the ONLY entry in `out` at this point — there's
    // no later part to pop it off.
    if (body && body !== currentStripped) {
      const authorType = source.author?.type;
      const author: "user" | "bot" =
        authorType === "user" || authorType === ("lead" as string) || authorType === ("contact" as string)
          ? "user"
          : "bot";
      out.push({ author, body });
    }
  }

  for (const part of parts ?? []) {
    // Only real visible replies — never internal notes, assignments,
    // closes, or other system conversation_part types.
    if (part.part_type !== "comment") continue;
    const body = (part.body ?? "").replace(/<[^>]*>/g, "").trim();
    if (!body) continue;
    if (part.author?.type === "user") {
      out.push({ author: "user", body });
    } else if (part.author?.type === "admin" && part.author.id === botAdminId) {
      out.push({ author: "bot", body });
    }
    // Other admins (human takeover replies) are deliberately excluded —
    // Jev classifies Caroline's own turns, not a human agent's.
  }
  // The live-check GET runs AFTER the triggering webhook, so its trailing
  // user part is almost always the SAME message already carried separately
  // as `message`/`currentMessage` — drop it so it isn't double-counted.
  const last = out.at(-1);
  if (last && last.author === "user" && last.body === currentStripped) {
    out.pop();
  }
  return out;
}

// v2 twin of buildRecentPartsFromLiveConversation above — same source/dedup
// logic, but OTHER admins (human takeover replies) map to "human_agent"
// instead of being dropped (spec bug (c): v1 loses Jan/human replies from
// state entirely). Built alongside, never instead of, the v1 recentParts —
// v1's shape and behaviour are unchanged by this function's existence.
function buildRecentPartsV2FromLiveConversation(
  source: IntercomConversation["source"] | undefined,
  parts: IntercomConversationPart[] | undefined,
  botAdminId: string,
  currentBody: string,
): JevV2Part[] {
  const out: JevV2Part[] = [];
  const currentStripped = currentBody.replace(/<[^>]*>/g, "").trim();

  if (source) {
    const body = (source.body ?? "").replace(/<[^>]*>/g, "").trim();
    if (body && body !== currentStripped) {
      const authorType = source.author?.type;
      const author: JevV2Author =
        authorType === "user" || authorType === ("lead" as string) || authorType === ("contact" as string)
          ? "customer"
          : authorType === "admin" && source.author?.id === botAdminId
            ? "caroline"
            : "human_agent";
      out.push({ author, body });
    }
  }

  for (const part of parts ?? []) {
    if (part.part_type !== "comment") continue;
    const body = (part.body ?? "").replace(/<[^>]*>/g, "").trim();
    if (!body) continue;
    if (part.author?.type === "user") {
      out.push({ author: "customer", body });
    } else if (part.author?.type === "admin" && part.author.id === botAdminId) {
      out.push({ author: "caroline", body });
    } else if (part.author?.type === "admin") {
      out.push({ author: "human_agent", body });
    }
  }
  const last = out.at(-1);
  if (last && last.author === "customer" && last.body === currentStripped) {
    out.pop();
  }
  return out;
}

export type HandlerAction =
  // `unsupportedAttachments` rides here for the same reason `attachments` does:
  // the channel needs it to build the turn. Dropping it at this hop would put
  // the silent-drop back exactly where it was, one layer down.
  | { action: "dispatch_to_agent"; conversationId: string; body: string; authorId: string; attachments?: ImageAttachmentRef[]; documents?: DocumentAttachmentRef[]; unsupportedAttachments?: UnsupportedAttachmentRef[] }
  | {
      action: "escalate";
      conversationId: string;
      assessment: RiskAssessment;
      body: string;
      // The thread the judge saw, minus the triggering message. Carried so the
      // hand-off can name the customer's real question: by the time a turn cap
      // fires the current message is "ok" and says nothing.
      recentParts?: { author: "user" | "bot"; body: string }[];
    }
  | { action: "escalate_legacy"; conversationId: string; category: string; matchedPattern: string; body: string }
  // A listed fraud-pull contact (restricted-accounts.ts): never reaches the agent and gets no
  // customer-facing message. `note` is posted as an internal note; reassign: false keeps the
  // conversation with the human admin who already holds it.
  | { action: "restricted_hold"; conversationId: string; category: string; note: string; body: string; reassign: boolean }
  | { action: "state_updated"; conversationId: string; description: string }
  // A writer outside this plugin posted AS Caroline (a notifier, the ops write wrapper) into a
  // conversation parked on a person nobody is working: the reply re-opened it on that person.
  // channel.ts assigns it back to Caroline. Nothing is sent to the customer.
  | { action: "reclaim"; conversationId: string; reason: string }
  | { action: "filtered"; conversationId: string; reason: string }
  | { action: "ignored"; reason: string }
  | { action: "duplicate"; eventId: string }
  | { action: "invalid_signature" };

export interface HandlerOptions {
  riskAssessment?: { enabled: boolean };
  riskDeps?: AssessRiskDeps;
  recentParts?: { author: "user" | "bot"; body: string }[];
  // v2 twin of recentParts (tests only — production builds it from the live
  // conversation, see buildRecentPartsV2FromLiveConversation). Only used
  // when jev.questionsVersion is "v2" or "v2" is in jev.shadowVersions.
  recentPartsV2?: JevV2Part[];
  // When present and non-empty, any customer message on a conversation whose
  // tags include one of these names (case-insensitive) is filtered before
  // the live-check and risk paths run. Used to disable Caroline on social
  // channels (instagram, facebook, x, etc.). See IntercomAccountConfig.
  blockedChannelTags?: string[];
  // Human-hold rule (assignment-policy.ts humanHold): how long a human admin assignee silences
  // Caroline after their last reply to the customer, and which team is the explicit escalation
  // queue. Absent = the default window and no escalation team. `nowMs` is a test seam.
  humanHold?: { hours?: number; escalationTeamId?: string; nowMs?: () => number };
  // Personalization gate + hook. When `personalization.enabled` and the message
  // is from a verified `type: "user"` author, `enrich` is invoked just before a
  // dispatch (never on escalate/filter paths) to populate state.enrichment.
  // `enrich` is injected so the handler stays free of live-API deps and unit-
  // testable; it is fail-soft internally and the call site also `.catch()`es.
  personalization?: { enabled: boolean };
  enrich?: (state: IntercomSessionState, identity: VerifiedIdentity) => Promise<void>;
  // Mandatory pre-retrieval RAG. When `kbRetrieval.enabled`, `retrieveKb` runs
  // CONCURRENTLY with `enrich` just before dispatch (never on escalate/filter) to
  // populate state.kbSnippets. Injected for testability; fail-soft internally and
  // `.catch()`ed at the call site. Self-skips bare closers / empty turns.
  kbRetrieval?: { enabled: boolean };
  retrieveKb?: (state: IntercomSessionState, message: string) => Promise<void>;
  // Jev pre-turn router (docs/designs/2026-09-22-jev-caroline-router.md §B).
  // `runJev` is injected (same rationale as `enrich`/`retrieveKb`: keeps the
  // handler free of live-API deps and unit-testable) and is expected to be
  // the SAME memoized runner instance channel.ts also hands to
  // buildRiskOptions for the Jev-backed judge, so at most one Jev HTTP call
  // happens per turn. Runs after the enrichment/KB legs, on the confirmed
  // dispatch path only (same gating as those legs).
  jev?: {
    enabled: boolean;
    bands: JevBands;
    actions: JevActionsConfig;
    intents?: import("./caroline-inventory-loader.js").CarolineIntentMeta[];
    skills?: import("./caroline-inventory-loader.js").CarolineSkillMeta[];
    // Shadow-row replay knob (see IntercomAccountConfig.jev.shadow). Absent
    // means "store state" (the appendJevShadowRow call sites below default
    // to true), matching DEFAULT_JEV_SHADOW.
    shadow?: { storeState?: boolean };
    // Gates LIVE routing behaviour only (decide()'s branches + the
    // [ROUTING] block). Default "v1" — omitting this leaves prod unchanged.
    questionsVersion?: "v1" | "v2";
    // Extra questions-schema versions to shadow-call IN PARALLEL with the
    // live call, fire-and-forget, never affecting the live result or turn
    // latency. Default [] (no shadow calls). A version equal to
    // jev.questionsVersion is harmless but redundant (the live call already
    // writes a rc=0 row for it).
    shadowVersions?: string[];
  };
  runJev?: (input: JevTurnInput) => Promise<JevTurnOutcome>;
  // Fires ONE shadow-only Jev call for `version` (e.g. "v2") — invoked once
  // per entry in jev.shadowVersions, never awaited by the caller, its result
  // only ever reaches the shadow log. Injected (like runJev) so handler.ts
  // stays free of live-API/runner-construction details; channel.ts is
  // expected to route this to a version-specific memoized runner instance.
  runJevShadow?: (version: string, input: JevTurnInput) => Promise<JevTurnOutcome>;
}

export async function handleWebhookEvent(
  payload: IntercomWebhookPayload,
  state: IntercomSessionState | null,
  botAdminId: string,
  client?: IntercomClient,
  options?: HandlerOptions,
): Promise<{ result: HandlerAction; state: IntercomSessionState | null }> {
  if (typeof payload?.data?.item?.id !== "string" || !payload?.topic || typeof payload?.id !== "string") {
    return { result: { action: "ignored", reason: "malformed payload: missing required fields" }, state };
  }

  const eventId = payload.id;
  const classified = classifyEvent(payload);

  // A conversation handed back to Caroline (the queue drain, a person's hand-back) where the
  // customer spoke last is answered NOW: the assignment is the trigger, not the customer's next
  // message. Only a thread a person actually held is resumed, so the bot's own self-assignment on
  // dispatch never re-sends a message it is already answering. Everything from here on is the
  // ordinary customer-message path, guards included.
  if (
    classified.kind === "assigned" &&
    state &&
    client &&
    classified.assigneeId === botAdminId &&
    state.handoffMode === "human_takeover"
  ) {
    let live: IntercomConversation | null = null;
    try {
      live = await client.getConversation({ conversationId: classified.conversationId });
    } catch (err) {
      console.warn(
        `[intercom:handler] hand-back conv=${classified.conversationId} could not be read, so its waiting customer is not answered until they write again: ${err}`,
      );
      live = null;
    }
    if (live && live.state === "open" && customerSpokeLast(live)) {
      handleAssignment(state, classified.assigneeId, classified.assigneeType, botAdminId);
      return handleWebhookEvent(
        { ...payload, topic: "conversation.user.replied", data: { ...payload.data, item: live } },
        state,
        botAdminId,
        client,
        options,
      );
    }
  }

  // Check idempotency if we have state
  if (state) {
    const eventIdSet = createEventIdSet(state.processedEventIds);
    if (isEventProcessed(eventId, eventIdSet)) {
      return { result: { action: "duplicate", eventId }, state };
    }
    trackEventId(eventId, state.processedEventIds);
  }

  switch (classified.kind) {
    case "customer_message": {
      // Channel-tag hard skip — runs before live-check, no API call needed.
      // The webhook payload includes the conversation's current tags; if any
      // matches a configured blocked channel (case-insensitive) we drop the
      // dispatch entirely. Lifecycle/state mutations are also skipped so the
      // conv stays in whatever state Intercom owns (typically "open" in the
      // team inbox for a human to handle).
      const blockedTags = options?.blockedChannelTags ?? [];
      if (blockedTags.length > 0) {
        const blockedLower = new Set(blockedTags.map((t) => t.toLowerCase()));
        const convTags = payload.data.item.tags?.tags ?? [];
        const matched = convTags
          .map((t) => t?.name)
          .filter((name): name is string => typeof name === "string")
          .find((name) => blockedLower.has(name.toLowerCase()));
        if (matched) {
          return {
            result: {
              action: "filtered",
              conversationId: classified.conversationId,
              reason: `blocked-channel: ${matched.toLowerCase()}`,
            },
            state,
          };
        }
      }

      // Handle implicit reopen if conversation was closed
      if (state && state.lifecycleState === "closed") {
        handleImplicitReopen(state, botAdminId);
      }

      const restriction = restrictionFor(classified.authorId);
      // Set by the live check below; read by the restricted hold (assignment-policy.ts).
      let staleHumanAssignee = false;
      let escalationQueueHolds = false;

      // Populated by the live check below (Finding 2) — feeds
      // buildRecentPartsFromLiveConversation ahead of assessRisk/runJev.
      let liveConversationParts: IntercomConversationPart[] | undefined;
      let liveConversationSource: IntercomConversation["source"] | undefined;

      // Live check: verify conversation assignee via Intercom API
      if (state && client && classified.conversationId) {
        try {
          const conversation = await client.getConversation({
            conversationId: classified.conversationId,
          });
          // Captured unconditionally, before any early return below, so a
          // filtered/escalated-elsewhere turn still leaves the freshest
          // history available — though only the dispatch path (below)
          // actually reads it. See buildRecentPartsFromLiveConversation.
          liveConversationParts = conversation.conversation_parts?.conversation_parts;
          liveConversationSource = conversation.source;
          // §2.4 posted into this thread outside the plugin (the gate's /w ref, an operator
          // re-contact) counts as sent, so the merge guard never repeats it (firstmate 028).
          if (!state.mergeParagraphSentAt) {
            const seen = [conversation.source, ...(liveConversationParts ?? [])].find(
              (p) =>
                p &&
                p.author?.type === "admin" &&
                String(p.author?.id ?? "") === botAdminId &&
                ((p as IntercomConversationPart).part_type ?? "comment") === "comment" &&
                containsMergeParagraph(p.body ?? ""),
            );
            if (seen) state.mergeParagraphSentAt = new Date().toISOString();
          }

          // Check lifecycle state from live data
          if (conversation.state === "closed" || conversation.state === "snoozed") {
            state.lifecycleState = conversation.state;
            state.updatedAt = new Date().toISOString();
            return {
              result: {
                action: "filtered",
                conversationId: classified.conversationId,
                reason: `live check: conversation ${conversation.state}`,
              },
              state,
            };
          }

          // Check assignee from live data. API v2.11 GET /conversations/{id}
          // returns admin_assignee_id (number), not the webhook-shaped
          // `assignee` object. Prefer the API field; fall back to `assignee`
          // for legacy or test-shape responses (also keeps webhook-shape
          // test fixtures exercising this branch).
          //
          // If neither signal is present, the API shape is unexpected —
          // preserve existing state rather than risk wiping a legitimate
          // human_takeover. The pre-fix code did `assignee?.id ?? null`,
          // which collapsed the missing-field case into a definitive "no
          // assignee" and silently reset state on every customer reply.
          const hasApiSignal =
            conversation.admin_assignee_id !== undefined ||
            conversation.assignee !== undefined;

          if (hasApiSignal) {
            const adminAssigneeId: string | null =
              conversation.admin_assignee_id != null
                ? String(conversation.admin_assignee_id)
                : conversation.assignee?.type === "admin"
                  ? conversation.assignee.id
                  : null;

            const teamAssigneeId: string | null =
              conversation.team_assignee_id != null ? String(conversation.team_assignee_id) : null;
            // ONE rule decides whether a human holds this conversation (assignment-policy.ts).
            // Before k1 any non-bot admin assignee silenced Caroline for ever, so a customer
            // who replied on a thread parked on a person weeks ago was simply dropped (168 such
            // replies in 24 h, measured 2026-11-11). Now a human holds it only while a human is
            // working it, or while it sits in the explicit escalation queue.
            const hold = humanHold({
              adminAssigneeId,
              teamAssigneeId,
              botAdminId,
              escalationTeamId: options?.humanHold?.escalationTeamId,
              parts: liveConversationParts,
              escalationFiredAt: state.escalationFiredAt,
              nowMs: options?.humanHold?.nowMs?.() ?? Date.now(),
              holdHours: options?.humanHold?.hours,
            });

            if (hold.held) {
              escalationQueueHolds = !adminAssigneeId;
              state.handoffMode = "human_takeover";
              state.currentAssigneeId = adminAssigneeId;
              state.currentAssigneeType = adminAssigneeId ? "admin" : null;
              state.updatedAt = new Date().toISOString();
              // A restricted contact still gets the hold below (alert + note), but
              // with reassign: false so the human keeps the conversation.
              if (!restriction) return {
                result: {
                  action: "filtered",
                  conversationId: classified.conversationId,
                  reason: `live check: ${hold.reason}`,
                },
                state,
              };
            } else if (hold.reclaim) {
              // Stale human assignment: Caroline takes the conversation back. currentAssigneeId
              // keeps the human's id so the dispatch path self-assigns the bot; the escalation
              // gate and the exchange counter restart, so a genuine risk on this new turn can
              // still escalate (with a reason, to the escalation queue) instead of being
              // swallowed by an escalation that fired weeks ago.
              console.warn(
                `[intercom:handler] reclaim conv=${classified.conversationId} for the AI queue: ${hold.reason}`,
              );
              staleHumanAssignee = true;
              state.handoffMode = "agent_active";
              state.currentAssigneeId = adminAssigneeId;
              state.currentAssigneeType = "admin";
              state.escalationFiredAt = null;
              state.escalationTicketId = null;
              state.escalationTicketActionType = null;
              state.userExchangeCount = 0;
              state.userTurnCount = 0;
              state.updatedAt = new Date().toISOString();
            } else {
              // No human admin assigned per the API. DO NOT touch handoffMode
              // — a prior handleAdminReply may have set human_takeover without
              // changing assignment (Intercom allows admins to reply without
              // assigning, and the bot self-assigns every dispatch so the API
              // ~always reports the bot as assignee). Downgrades back to
              // agent_active belong to the explicit
              // conversation.admin.assigned (handleAssignment) and
              // conversation.admin.opened (handleImplicitReopen) webhook
              // paths. Reproduced via conv=215474192304895 on 2026-05-06:
              // Jan replied → handoff = human_takeover; customer replied 7
              // min later → live check saw bot as assignee (because we'd
              // self-assigned earlier) → unconditional reset wiped Jan's
              // takeover and the bot replied over him.
              state.currentAssigneeId = adminAssigneeId;
              state.currentAssigneeType = adminAssigneeId ? "admin" : null;
              state.updatedAt = new Date().toISOString();
            }
          } else {
            // Unexpected API shape — preserve existing state, fall through.
            // Warn once per conv per process so shape drift surfaces in logs
            // (this is the exact class of bug the PR is fixing — we want
            // loud observability if it ever regresses again).
            if (!apiShapeWarned.has(classified.conversationId)) {
              apiShapeWarned.add(classified.conversationId);
              console.warn(
                `[intercom:handler] live check returned unexpected shape (no admin_assignee_id or assignee) conv=${classified.conversationId} — preserving cached state ${state.handoffMode}/${state.lifecycleState}`,
              );
            }
          }
        } catch (err) {
          if (err instanceof RateLimitError) {
            console.error(
              `[intercom:handler] rate limited during live check conv=${classified.conversationId}, retryAfter=${err.retryAfterSeconds}s`,
            );
          } else {
            console.warn(
              `[intercom:handler] live check failed for conv=${classified.conversationId}: ${err}`,
            );
          }
          // Fall through to cached state
        }
      }

      if (restriction) {
        // reassign (to the escalation queue, reason = the restriction category) only when no
        // human is working it. The holder comes from the live check when it succeeded, else
        // from cached state (a failed lookup must not move a human-held conversation). A
        // STALE human assignee does not hold it: a restricted contact parked on one person
        // weeks ago goes to the escalation queue like any other. Already in that queue = stay.
        const humanHolds =
          escalationQueueHolds ||
          (!staleHumanAssignee &&
            !!state?.currentAssigneeId &&
            state.currentAssigneeType === "admin" &&
            state.currentAssigneeId !== botAdminId);
        // Caroline stays out of this conversation until a human hands it back.
        if (state) {
          state.handoffMode = "human_takeover";
          state.updatedAt = new Date().toISOString();
        }
        return {
          result: {
            action: "restricted_hold",
            conversationId: classified.conversationId,
            category: restriction.category,
            note: restriction.note,
            body: classified.body,
            reassign: !humanHolds,
          },
          state,
        };
      }

      // Update pinned facts from the customer message.
      if (state) {
        state.knownFacts = updateKnownFacts(classified.body, state.knownFacts ?? {});
        // Exchange count for the hard cap (see continuesCustomerBurst): a message that only
        // continues the customer's own unanswered burst is the same exchange.
        const priorExchanges = state.userExchangeCount ?? state.userTurnCount ?? 0;
        state.userExchangeCount = continuesCustomerBurst(liveConversationSource, liveConversationParts, classified.body)
          ? priorExchanges
          : priorExchanges + 1;
        // Increment user-turn count (only on customer messages).
        state.userTurnCount = (state.userTurnCount ?? 0) + 1;
        state.updatedAt = new Date().toISOString();
      }

      // Finding 2: explicit options.recentParts (tests only — production
      // never sets it) wins when supplied; otherwise built from the live
      // check's already-fetched conversation, no second API call.
      const recentParts =
        options?.recentParts ??
        buildRecentPartsFromLiveConversation(liveConversationSource, liveConversationParts, botAdminId, classified.body);

      // Built once, lazily, only when v2 state is actually needed this turn
      // (live questionsVersion "v2" or "v2" in shadowVersions) — never spent
      // on a v1-only turn.
      const jevQuestionsVersion = options?.jev?.questionsVersion ?? "v1";
      const jevShadowVersions = options?.jev?.shadowVersions ?? [];
      const needsV2Parts = jevQuestionsVersion === "v2" || jevShadowVersions.includes("v2");
      const recentPartsV2 = needsV2Parts
        ? (options?.recentPartsV2 ??
          buildRecentPartsV2FromLiveConversation(liveConversationSource, liveConversationParts, botAdminId, classified.body))
        : undefined;

      const flagOn = options?.riskAssessment?.enabled === true;

      if (flagOn) {
        const assessment = await assessRisk(
          classified.body,
          recentParts,
          state ?? ({ userTurnCount: 0 } as IntercomSessionState),
          options?.riskDeps ?? {},
          // QA NO-GO on #1022 (finding 2): the risk judge shares the SAME
          // memoized runner as the later runJev call — recentPartsV2 must be
          // computed and passed here too, or a v2 turn's first call (this
          // one) permanently caches a state with an empty thread.
          recentPartsV2,
        );

        const alreadyFired = !!state?.escalationFiredAt;

        // Only a reason outside Caroline's authority leaves her (assignment-policy.ts). A request
        // for a person and the turn cap fall through to her own reply.
        const toQueue = assessment.triggered && escalationGoesToQueue(assessment);
        if (assessment.triggered && !toQueue) {
          options?.riskDeps?.log?.warn?.(
            `[intercom:handler] no hand-off conv=${classified.conversationId} reason=${assessment.source}/${assessment.reason}: Caroline answers`,
          );
        }

        if (toQueue && !alreadyFired) {
          if (state) {
            state.handoffMode = "human_takeover";
            state.updatedAt = new Date().toISOString();
          }
          return {
            result: {
              action: "escalate",
              conversationId: classified.conversationId,
              assessment,
              body: classified.body,
              recentParts,
            },
            state,
          };
        }
      } else {
        // Legacy path — runs whenever riskAssessment.enabled is false. Delete
        // once that flag is true on all profiles and one week of clean traffic
        // has elapsed.
        const escalation = checkEscalation(classified.body);
        if (escalation.triggered) {
          if (state) {
            state.handoffMode = "human_takeover";
            state.updatedAt = new Date().toISOString();
          }
          return {
            result: {
              action: "escalate_legacy",
              conversationId: classified.conversationId,
              category: escalation.category!,
              matchedPattern: escalation.matchedPattern!,
              body: classified.body,
            },
            state,
          };
        }
      }

      // Suppress dispatch if agent cannot reply (human_takeover, snoozed, closed)
      if (state && !canAgentReply(state)) {
        return {
          result: {
            action: "filtered",
            conversationId: classified.conversationId,
            reason: `suppressed: ${state.handoffMode}/${state.lifecycleState}`,
          },
          state,
        };
      }

      // Pre-dispatch context legs — run ONLY here, on the confirmed dispatch path
      // (after escalation + suppression gates), so we never spend live API calls on
      // messages that get escalated or filtered. Personalization enrichment and KB
      // retrieval run CONCURRENTLY via Promise.all: the hot reply path waits at most
      // max(enrich, kb), never the sum. Both are best-effort and `.catch()`ed so a
      // bug in either can never block a customer reply.
      if (state) {
        const legs: Promise<unknown>[] = [];
        if (
          options?.enrich &&
          shouldEnrich({ enabled: options?.personalization?.enabled === true, classified, state })
        ) {
          const identity: VerifiedIdentity = {
            email: classified.verifiedEmail!,
            name: classified.verifiedName,
            contactId: classified.authorId || undefined,
          };
          legs.push(options.enrich(state, identity).catch(() => {}));
        }
        // KB retrieval needs no verified identity (it searches the reference corpus,
        // not account data); it self-skips bare closers / empty turns.
        if (options?.retrieveKb && options?.kbRetrieval?.enabled === true) {
          legs.push(options.retrieveKb(state, classified.body).catch(() => {}));
        }
        if (legs.length > 0) await Promise.all(legs);
      }

      // Jev pre-turn router (docs/designs/2026-09-22-jev-caroline-router.md
      // §B) — runs after the enrichment/KB legs so known_facts reflects
      // whatever personalization landed this turn, and only on the confirmed
      // dispatch path (never spent on escalated/filtered/suppressed turns).
      // A Jev failure (timeout, bad shape, disabled) leaves `state.jev`
      // untouched and falls through to the unchanged dispatch below.
      if (state && options?.jev?.enabled && options.runJev) {
        // Shadow calls fire here, BEFORE the live call is awaited, so they
        // run concurrently with it and never add to this turn's latency.
        // Fire-and-forget: any hang/throw/garbage result is swallowed to a
        // warn and never reaches the live decision or the customer.
        if (options.runJevShadow) {
          for (const version of jevShadowVersions) {
            const shadowStartedAt = Date.now();
            const shadowInput: JevTurnInput =
              version === "v2"
                ? { message: classified.body, turnCount: state.userTurnCount ?? 0, recentPartsV2 }
                : { message: classified.body, turnCount: state.userTurnCount ?? 0, recentParts };
            void options
              .runJevShadow(version, shadowInput)
              .then((outcome) => {
                const shadowLatencyMs = Date.now() - shadowStartedAt;
                if (outcome.ok) {
                  // decide() here is used ONLY to compute what the shadow row's
                  // `actual` would have been — its result is never applied to
                  // state or the response, only logged.
                  const shadowDecision = decideJev(
                    outcome.answers,
                    options.jev!.bands,
                    classified.body,
                    undefined,
                    options.jev!.intents ?? [],
                    options.jev!.skills ?? [],
                    options.jev!.actions,
                    version === "v2" ? "v2" : "v1",
                  );
                  return appendJevShadowRow({
                    conversationId: classified.conversationId,
                    state: outcome.state,
                    questions: outcome.questions,
                    model: outcome.model,
                    provider: "openrouter",
                    answers: outcome.answers,
                    usage: outcome.usage,
                    latencyMs: shadowLatencyMs,
                    actual: shadowDecision.action,
                    rc: 0,
                    http: outcome.httpStatus,
                    storeState: options.jev?.shadow?.storeState ?? true,
                    questionsVersion: version,
                    stateVariant: outcome.stateVariant,
                  });
                }
                return appendJevShadowRow({
                  conversationId: classified.conversationId,
                  state: outcome.state ?? {},
                  questions: outcome.questions ?? {},
                  model: outcome.model ?? DEFAULT_JEV_MODEL,
                  provider: "openrouter",
                  answers: null,
                  usage: null,
                  latencyMs: shadowLatencyMs,
                  actual: "none",
                  rc: outcome.reason === "shape" ? 3 : 2,
                  reason: outcome.reason,
                  http: outcome.httpStatus,
                  storeState: options.jev?.shadow?.storeState ?? true,
                  questionsVersion: version,
                  stateVariant: outcome.stateVariant,
                });
              })
              .catch((err) => {
                console.warn(`[intercom:jev] shadow call version=${version} failed: ${err}`);
              });
          }
        }

        const startedAt = Date.now();
        const turnResult = await options.runJev({
          message: classified.body,
          turnCount: state.userTurnCount ?? 0,
          recentParts,
          recentPartsV2,
        });
        const latencyMs = Date.now() - startedAt;

        if (!turnResult.ok) {
          // Finding 3 (2026-09-22 PR #999 QA): state.jev persists ACROSS
          // turns (renderJevBlock reads it at render time, not decide time),
          // so leaving it untouched here re-injects a PRIOR turn's routing
          // block into a conversation this turn's Jev call never classified
          // — e.g. a stored credit_verification_check route bleeding into an
          // unrelated billing turn whose call timed out. Reset the per-turn
          // routing result while preserving the once-per-conversation
          // bad-faith memory (badFaithDeclinedAt), same as the "route"
          // branch below already does.
          state.jev = { action: "none", block: null, badFaithDeclinedAt: state.jev?.badFaithDeclinedAt };
          // Best-effort failure shadow row — jev.sh also logs failed calls,
          // so `jev-shadow-report.sh --surface caroline` must count these
          // too. `actual: "none"` because no route/decline/silence/escalate
          // decision was ever made.
          void appendJevShadowRow({
            conversationId: classified.conversationId,
            state: turnResult.state ?? {},
            questions: turnResult.questions ?? {},
            model: turnResult.model ?? DEFAULT_JEV_MODEL,
            provider: "openrouter",
            answers: null,
            usage: null,
            latencyMs,
            actual: "none",
            rc: turnResult.reason === "shape" ? 3 : 2,
            reason: turnResult.reason,
            http: turnResult.httpStatus,
            storeState: options.jev?.shadow?.storeState ?? true,
            questionsVersion: jevQuestionsVersion,
            stateVariant: turnResult.stateVariant,
          }).catch(() => {});
        }

        if (turnResult.ok) {
          const decision = decideJev(
            turnResult.answers,
            options.jev.bands,
            classified.body,
            state,
            options.jev.intents ?? [],
            options.jev.skills ?? [],
            options.jev.actions,
            jevQuestionsVersion,
          );
          console.info(
            formatJevLogLine({
              conversationId: classified.conversationId,
              action: decision.action,
              answers: turnResult.answers,
              latencyMs,
              suppressed: decision.suppressed,
            }),
          );
          // Best-effort shadow row, jev.sh's row shape (§B). `actual` is the
          // action decide() picked — only known here, not inside the runner.
          void appendJevShadowRow({
            conversationId: classified.conversationId,
            state: turnResult.state,
            questions: turnResult.questions,
            model: turnResult.model,
            provider: "openrouter",
            answers: turnResult.answers,
            usage: turnResult.usage,
            latencyMs,
            actual: decision.action,
            rc: 0,
            http: turnResult.httpStatus,
            storeState: options.jev?.shadow?.storeState ?? true,
            questionsVersion: jevQuestionsVersion,
            stateVariant: turnResult.stateVariant,
          }).catch(() => {});

          if (decision.action === "decline") {
            // badFaithDeclinedAt is the once-per-conversation gate: set here on
            // the first bad-faith turn, and carried forward on every later
            // overwrite below (a later "route" turn must never clear it, or a
            // second bad-faith message later in the same conversation would
            // wrongly decline again instead of going straight to silence).
            state.jev = { action: decision.action, block: decision.block, badFaithDeclinedAt: new Date().toISOString() };
          } else if (decision.action === "route") {
            state.jev = { action: decision.action, block: decision.block, badFaithDeclinedAt: state.jev?.badFaithDeclinedAt };
          }

          if (decision.action === "silence") {
            // Reuse the existing "no dispatch" mechanism (post nothing, keep
            // the read-receipt reaction, skip lifecycle mutation) — same
            // shape the blocked-channel-tag and suppressed-dispatch filters
            // above already return.
            return {
              result: { action: "filtered", conversationId: classified.conversationId, reason: "jev:silence" },
              state,
            };
          }

          if (decision.action === "escalate" && decision.escalation) {
            state.handoffMode = "human_takeover";
            state.updatedAt = new Date().toISOString();
            return {
              result: {
                action: "escalate",
                conversationId: classified.conversationId,
                assessment: decision.escalation,
                body: classified.body,
                recentParts,
              },
              state,
            };
          }
          // "decline" and "route" both fall through to dispatch below —
          // state.jev.block was already stored above for buildAgentRawBody
          // to render.
        } else {
          // Jev call failed/timed out/disabled-at-runtime (jev-client.ts
          // already warned its own rc=fail reason=<token> line) — still emit
          // the one-line-per-turn journal entry so a bad hour is visible as
          // a run of action=none rows, then fall through unchanged.
          console.info(
            formatJevLogLine({
              conversationId: classified.conversationId,
              action: "none",
              answers: null,
              latencyMs,
            }),
          );
        }
      }

      return {
        result: {
          action: "dispatch_to_agent",
          conversationId: classified.conversationId,
          body: classified.body,
          authorId: classified.authorId,
          ...(classified.attachments && classified.attachments.length > 0
            ? { attachments: classified.attachments }
            : {}),
          ...(classified.documents && classified.documents.length > 0
            ? { documents: classified.documents }
            : {}),
          ...(classified.unsupportedAttachments && classified.unsupportedAttachments.length > 0
            ? { unsupportedAttachments: classified.unsupportedAttachments }
            : {}),
        },
        state,
      };
    }

    case "admin_reply": {
      if (!state) {
        return { result: { action: "ignored", reason: "no session for admin reply" }, state };
      }

      // Check self-reply
      if (isSelfReply(classified.messageId, state.outboundMessageIds)) {
        return {
          result: { action: "filtered", conversationId: classified.conversationId, reason: "self-reply" },
          state,
        };
      }

      // A reply posted as Caroline by something other than this plugin (a notifier script, the
      // ops write wrapper). Measured 2026-11-11 17:33-18:25Z: one notification campaign replied
      // into 312 long-closed conversations whose assignee was a person; each reply re-opened the
      // conversation ON that person and his open queue went from 581 to 913 in an hour. Caroline
      // sent the message, so Caroline holds the thread, unless a human is really answering it
      // (assignment-policy.ts humanHold: same rule as the customer-message live check).
      if (classified.adminId === botAdminId && client && classified.conversationId) {
        try {
          const conversation = await client.getConversation({ conversationId: classified.conversationId });
          const adminAssigneeId: string | null =
            conversation.admin_assignee_id != null
              ? String(conversation.admin_assignee_id)
              : conversation.assignee?.type === "admin"
                ? conversation.assignee.id
                : null;
          if (conversation.state === "open" && adminAssigneeId && adminAssigneeId !== botAdminId) {
            const hold = humanHold({
              adminAssigneeId,
              teamAssigneeId: conversation.team_assignee_id != null ? String(conversation.team_assignee_id) : null,
              botAdminId,
              escalationTeamId: options?.humanHold?.escalationTeamId,
              parts: conversation.conversation_parts?.conversation_parts,
              escalationFiredAt: state.escalationFiredAt,
              nowMs: options?.humanHold?.nowMs?.() ?? Date.now(),
              holdHours: options?.humanHold?.hours,
            });
            if (hold.reclaim) {
              state.handoffMode = "agent_active";
              state.lifecycleState = "open";
              state.currentAssigneeId = adminAssigneeId;
              state.currentAssigneeType = "admin";
              state.updatedAt = new Date().toISOString();
              return {
                result: { action: "reclaim", conversationId: classified.conversationId, reason: hold.reason },
                state,
              };
            }
          }
        } catch {
          // Unreadable: change nothing. The customer-message live check applies the same rule
          // when the customer next writes.
        }
      }

      // Human admin reply triggers takeover; bot replies are filtered
      handleAdminReply(state, classified.adminId, classified.adminType, botAdminId);

      if (state.handoffMode === "human_takeover") {
        return {
          result: {
            action: "state_updated",
            conversationId: classified.conversationId,
            description: `human_takeover (admin ${classified.adminId} replied)`,
          },
          state,
        };
      }

      return {
        result: { action: "filtered", conversationId: classified.conversationId, reason: "non-human admin reply" },
        state,
      };
    }

    case "assigned": {
      if (!state) {
        return { result: { action: "ignored", reason: "no session for assignment" }, state };
      }

      handleAssignment(state, classified.assigneeId, classified.assigneeType, botAdminId);
      return {
        result: {
          action: "state_updated",
          conversationId: classified.conversationId,
          description: `assigned to ${classified.assigneeId}, mode: ${state.handoffMode}`,
        },
        state,
      };
    }

    case "lifecycle": {
      if (!state) {
        return { result: { action: "ignored", reason: "no session for lifecycle change" }, state };
      }

      handleLifecycleChange(state, classified.state);
      return {
        result: {
          action: "state_updated",
          conversationId: classified.conversationId,
          description: `lifecycle → ${classified.state}`,
        },
        state,
      };
    }

    case "noted":
      return { result: { action: "ignored", reason: "internal note" }, state };

    case "unknown":
      return { result: { action: "ignored", reason: `unknown topic: ${classified.topic}` }, state };
  }
}
