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
import { classifyEvent, createEventIdSet, isEventProcessed, trackEventId, isSelfReply } from "./filters.js";
import { checkEscalation, assessRisk, type AssessRiskDeps } from "./escalation.js";
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
  | { action: "escalate"; conversationId: string; assessment: RiskAssessment; body: string }
  | { action: "escalate_legacy"; conversationId: string; category: string; matchedPattern: string; body: string }
  | { action: "state_updated"; conversationId: string; description: string }
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

            if (adminAssigneeId && adminAssigneeId !== botAdminId) {
              state.handoffMode = "human_takeover";
              state.currentAssigneeId = adminAssigneeId;
              state.currentAssigneeType = "admin";
              state.updatedAt = new Date().toISOString();
              return {
                result: {
                  action: "filtered",
                  conversationId: classified.conversationId,
                  reason: `live check: human assignee ${adminAssigneeId}`,
                },
                state,
              };
            }

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

      // Update pinned facts from the customer message.
      if (state) {
        state.knownFacts = updateKnownFacts(classified.body, state.knownFacts ?? {});
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

        const isMagic = assessment.source === "user_request";
        const alreadyFired = !!state?.escalationFiredAt;

        if (assessment.triggered && (isMagic || !alreadyFired)) {
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
                    questionsVersion: version,
                    stateVariant: outcome.stateVariant,
                  });
                }
                return appendJevShadowRow({
                  conversationId: classified.conversationId,
                  state: {},
                  questions: {},
                  model: DEFAULT_JEV_MODEL,
                  provider: "openrouter",
                  answers: null,
                  usage: null,
                  latencyMs: shadowLatencyMs,
                  actual: "none",
                  rc: outcome.reason === "shape" ? 3 : 2,
                  http: outcome.httpStatus,
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
            state: {},
            questions: {},
            model: DEFAULT_JEV_MODEL,
            provider: "openrouter",
            answers: null,
            usage: null,
            latencyMs,
            actual: "none",
            rc: turnResult.reason === "shape" ? 3 : 2,
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
