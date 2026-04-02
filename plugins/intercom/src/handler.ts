import type { IntercomWebhookPayload, IntercomSessionState, IntercomClient } from "./types.js";
import { RateLimitError } from "./outbound.js";
import { classifyEvent, createEventIdSet, isEventProcessed, trackEventId, isSelfReply } from "./filters.js";
import { checkEscalation } from "./escalation.js";
import {
  handleAssignment,
  handleAdminReply,
  handleLifecycleChange,
  handleImplicitReopen,
  canAgentReply,
} from "./handoff.js";

export type HandlerAction =
  | { action: "dispatch_to_agent"; conversationId: string; body: string; authorId: string }
  | { action: "escalate"; conversationId: string; category: string; matchedPattern: string; body: string }
  | { action: "state_updated"; conversationId: string; description: string }
  | { action: "filtered"; conversationId: string; reason: string }
  | { action: "ignored"; reason: string }
  | { action: "duplicate"; eventId: string }
  | { action: "invalid_signature" };

export async function handleWebhookEvent(
  payload: IntercomWebhookPayload,
  state: IntercomSessionState | null,
  botAdminId: string,
  client?: IntercomClient,
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

          // Check assignee from live data
          const assigneeId = conversation.assignee?.id ?? null;
          if (assigneeId && assigneeId !== botAdminId) {
            state.handoffMode = "human_takeover";
            state.currentAssigneeId = assigneeId;
            state.updatedAt = new Date().toISOString();
            return {
              result: {
                action: "filtered",
                conversationId: classified.conversationId,
                reason: `live check: human assignee ${assigneeId}`,
              },
              state,
            };
          }

          // Bot or no assignee — restore agent_active (clears stale human_takeover)
          state.handoffMode = "agent_active";
          state.currentAssigneeId = assigneeId;
          state.updatedAt = new Date().toISOString();
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

      // Check escalation before dispatching
      const escalation = checkEscalation(classified.body);

      if (escalation.triggered) {
        // Escalation auto-sets human_takeover
        if (state) {
          state.handoffMode = "human_takeover";
          state.updatedAt = new Date().toISOString();
        }
        return {
          result: {
            action: "escalate",
            conversationId: classified.conversationId,
            category: escalation.category!,
            matchedPattern: escalation.matchedPattern!,
            body: classified.body,
          },
          state,
        };
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

      // Non-bot admin reply → implicit takeover
      handleAdminReply(state, classified.adminId, botAdminId);

      if (classified.adminId !== botAdminId) {
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
        result: { action: "filtered", conversationId: classified.conversationId, reason: "bot self-reply" },
        state,
      };
    }

    case "assigned": {
      if (!state) {
        return { result: { action: "ignored", reason: "no session for assignment" }, state };
      }

      handleAssignment(state, classified.assigneeId, botAdminId);
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
