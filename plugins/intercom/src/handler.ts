import type {
  IntercomWebhookPayload,
  IntercomSessionState,
  IntercomClient,
  RiskAssessment,
} from "./types.js";
import { RateLimitError } from "./outbound.js";
import { classifyEvent, createEventIdSet, isEventProcessed, trackEventId, isSelfReply } from "./filters.js";
import { checkEscalation, assessRisk, type AssessRiskDeps } from "./escalation.js";
import { updateKnownFacts } from "./extractors.js";
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

export type HandlerAction =
  | { action: "dispatch_to_agent"; conversationId: string; body: string; authorId: string }
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
      // Handle implicit reopen if conversation was closed
      if (state && state.lifecycleState === "closed") {
        handleImplicitReopen(state, botAdminId);
      }

      // Live check: verify conversation assignee via Intercom API
      if (state && client && classified.conversationId) {
        try {
          const conversation = await client.getConversation({
            conversationId: classified.conversationId,
          });

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

      const flagOn = options?.riskAssessment?.enabled === true;

      if (flagOn) {
        const assessment = await assessRisk(
          classified.body,
          options?.recentParts ?? [],
          state ?? ({ userTurnCount: 0 } as IntercomSessionState),
          options?.riskDeps ?? {},
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

      return {
        result: {
          action: "dispatch_to_agent",
          conversationId: classified.conversationId,
          body: classified.body,
          authorId: classified.authorId,
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
