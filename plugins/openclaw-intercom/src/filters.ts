import type {
  IntercomWebhookPayload,
  ClassifiedEvent,
} from "./types.js";
import { MAX_PROCESSED_EVENT_IDS } from "./types.js";

export function classifyEvent(payload: IntercomWebhookPayload): ClassifiedEvent {
  const { topic, data } = payload;
  const conversation = data.item;
  const conversationId = conversation.id;

  switch (topic) {
    case "conversation.user.created":
    case "conversation.user.replied": {
      const lastPart = conversation.conversation_parts?.conversation_parts?.at(-1);
      const body = lastPart?.body ?? conversation.source?.body ?? "";
      if (!body) {
        return { kind: "unknown", topic: `${topic}:empty_body` };
      }
      const authorId = lastPart?.author?.id ?? conversation.source?.author?.id ?? "";
      return { kind: "customer_message", conversationId, body, authorId };
    }

    case "conversation.admin.replied": {
      const part = conversation.conversation_parts?.conversation_parts?.at(-1);
      return {
        kind: "admin_reply",
        conversationId,
        adminId: part?.author?.id ?? conversation.assignee?.id ?? "",
        messageId: part?.id ?? "",
      };
    }

    case "conversation.admin.assigned":
      return {
        kind: "assigned",
        conversationId,
        assigneeId: conversation.assignee?.id ?? "",
      };

    case "conversation.admin.closed":
      return { kind: "lifecycle", conversationId, state: "closed" };

    case "conversation.admin.snoozed":
      return { kind: "lifecycle", conversationId, state: "snoozed" };

    case "conversation.admin.opened":
      return { kind: "lifecycle", conversationId, state: "open" };

    case "conversation.admin.noted":
      return { kind: "noted", conversationId };

    default:
      return { kind: "unknown", topic };
  }
}

export function createEventIdSet(processedIds: string[]): Set<string> {
  return new Set(processedIds);
}

export function isEventProcessed(eventId: string, eventIdSet: Set<string>): boolean {
  return eventIdSet.has(eventId);
}

export function trackEventId(eventId: string, processedIds: string[]): void {
  if (processedIds.length >= MAX_PROCESSED_EVENT_IDS) {
    processedIds.shift();
  }
  processedIds.push(eventId);
}

export function isSelfReply(messageId: string, outboundIds: string[]): boolean {
  return outboundIds.includes(messageId);
}
