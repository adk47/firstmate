import { describe, it, expect, vi } from "vitest";
import { shouldEnrich, enrichSession, DEFAULT_ENRICH_TIMEOUT_MS, type VerifiedIdentity } from "../src/enrichment.js";
import type { AccountSnapshot, ClassifiedEvent, IntercomSessionState } from "../src/types.js";

function userMessage(
  overrides: Partial<Extract<ClassifiedEvent, { kind: "customer_message" }>> = {},
): ClassifiedEvent {
  return {
    kind: "customer_message",
    conversationId: "conv_1",
    body: "hi",
    authorId: "user_abc",
    authorType: "user",
    verifiedEmail: "jane@example.com",
    verifiedName: "Jane",
    ...overrides,
  };
}

function stateWith(enrichment?: IntercomSessionState["enrichment"]): IntercomSessionState {
  return { enrichment } as IntercomSessionState;
}

describe("shouldEnrich", () => {
  it("returns true for an enabled, verified user with no prior enrichment", () => {
    expect(shouldEnrich({ enabled: true, classified: userMessage(), state: stateWith() })).toBe(true);
  });

  it("returns false when the feature flag is disabled", () => {
    expect(shouldEnrich({ enabled: false, classified: userMessage(), state: stateWith() })).toBe(false);
  });

  it("returns false when the author is not a user", () => {
    expect(
      shouldEnrich({ enabled: true, classified: userMessage({ authorType: "admin" }), state: stateWith() }),
    ).toBe(false);
  });

  it("returns false when there is no verified email", () => {
    expect(
      shouldEnrich({ enabled: true, classified: userMessage({ verifiedEmail: undefined }), state: stateWith() }),
    ).toBe(false);
  });

  it("returns false when there is no session state", () => {
    expect(shouldEnrich({ enabled: true, classified: userMessage(), state: null })).toBe(false);
  });

  it("returns false when this conversation was already enriched (done)", () => {
    expect(
      shouldEnrich({
        enabled: true,
        classified: userMessage(),
        state: stateWith({ status: "done", enrichedAt: "2026-01-01T00:00:00Z" }),
      }),
    ).toBe(false);
  });

  it("returns true to retry when a prior enrichment failed", () => {
    expect(
      shouldEnrich({
        enabled: true,
        classified: userMessage(),
        state: stateWith({ status: "failed", enrichedAt: "2026-01-01T00:00:00Z" }),
      }),
    ).toBe(true);
  });

  it("returns false for non-customer-message events", () => {
    const lifecycle: ClassifiedEvent = { kind: "lifecycle", conversationId: "conv_1", state: "open" };
    expect(shouldEnrich({ enabled: true, classified: lifecycle, state: stateWith() })).toBe(false);
  });
});

const IDENTITY: VerifiedIdentity = { email: "jane@example.com", name: "Jane Doe", contactId: "user_abc" };

const SNAPSHOT: AccountSnapshot = {
  profileId: "p1",
  name: "Jane Doe",
  isClaimed: true,
  creditsCount: 42,
  latestCreditTitle: "Midnight",
  latestCreditDate: "2026-05-01",
};

describe("enrichSession", () => {
  it("records verified identity + snapshot on a successful lookup (status done)", async () => {
    const state = stateWith();
    await enrichSession(state, IDENTITY, { lookupSnapshot: async () => SNAPSHOT });
    expect(state.enrichment?.status).toBe("done");
    expect(state.enrichment?.verifiedEmail).toBe("jane@example.com");
    expect(state.enrichment?.verifiedName).toBe("Jane Doe");
    expect(state.enrichment?.contactId).toBe("user_abc");
    expect(state.enrichment?.snapshot).toEqual(SNAPSHOT);
    expect(state.enrichment?.enrichedAt).toBeTruthy();
  });

  it("records identity with no snapshot when the lookup finds no confident match (status done)", async () => {
    const state = stateWith();
    await enrichSession(state, IDENTITY, { lookupSnapshot: async () => null });
    expect(state.enrichment?.status).toBe("done");
    expect(state.enrichment?.verifiedName).toBe("Jane Doe");
    expect(state.enrichment?.snapshot).toBeUndefined();
  });

  it("keeps the verified identity and marks failed (for retry) when the lookup throws — never throws", async () => {
    const state = stateWith();
    const warn = vi.fn();
    await expect(
      enrichSession(state, IDENTITY, {
        lookupSnapshot: async () => {
          throw new Error("timeout");
        },
        log: { warn },
      }),
    ).resolves.toBeUndefined();
    expect(state.enrichment?.status).toBe("failed");
    expect(state.enrichment?.verifiedName).toBe("Jane Doe"); // greeting still works
    expect(state.enrichment?.snapshot).toBeUndefined();
    expect(warn).toHaveBeenCalledOnce();
  });

  it("passes the default timeout to the lookup when none is configured", async () => {
    const state = stateWith();
    const lookupSnapshot = vi.fn(async () => SNAPSHOT);
    await enrichSession(state, IDENTITY, { lookupSnapshot });
    expect(lookupSnapshot).toHaveBeenCalledWith("jane@example.com", { timeoutMs: DEFAULT_ENRICH_TIMEOUT_MS });
  });

  it("passes a configured timeout to the lookup", async () => {
    const state = stateWith();
    const lookupSnapshot = vi.fn(async () => SNAPSHOT);
    await enrichSession(state, IDENTITY, { lookupSnapshot, timeoutMs: 800 });
    expect(lookupSnapshot).toHaveBeenCalledWith("jane@example.com", { timeoutMs: 800 });
  });
});

describe("enrichSession — prior-chat recall", () => {
  const CONVOS = [
    { id: "conv_current", title: null, state: "open" as const, updatedAt: "2026-06-10T14:00:00.000Z", snippet: "current question" },
    { id: "conv_b", title: "Analytics question", state: "closed" as const, updatedAt: "2026-06-01T10:00:00.000Z", snippet: "my analytics are stuck" },
    { id: "conv_a", title: null, state: "closed" as const, updatedAt: "2026-05-01T10:00:00.000Z", snippet: "how do I claim my profile" },
  ];

  function stateWithConv(conversationId: string): IntercomSessionState {
    return { conversationId } as IntercomSessionState;
  }

  it("records prior-chat count and most-recent pointer, excluding the CURRENT conversation", async () => {
    const state = stateWithConv("conv_current");
    await enrichSession(state, IDENTITY, {
      lookupSnapshot: async () => null,
      listPriorConversations: async () => ({ conversations: CONVOS, totalCount: 3 }),
    });
    expect(state.enrichment?.status).toBe("done");
    expect(state.enrichment?.priorChats).toEqual({
      count: 2,
      mostRecentTitle: "Analytics question",
      mostRecentAt: "2026-06-01T10:00:00.000Z",
    });
  });

  it("uses totalCount for the count when the contact has more history than the fetched page", async () => {
    const state = stateWithConv("conv_current");
    await enrichSession(state, IDENTITY, {
      lookupSnapshot: async () => null,
      // Server-side exclusion already applied: page holds priors only.
      listPriorConversations: async () => ({ conversations: [CONVOS[1], CONVOS[2]], totalCount: 12 }),
    });
    expect(state.enrichment?.priorChats?.count).toBe(12);
    expect(state.enrichment?.priorChats?.mostRecentTitle).toBe("Analytics question");
  });

  it("falls back to the snippet when the most recent prior conversation has no title", async () => {
    const state = stateWithConv("conv_current");
    await enrichSession(state, IDENTITY, {
      lookupSnapshot: async () => null,
      listPriorConversations: async () => ({ conversations: [CONVOS[0], CONVOS[2]], totalCount: 2 }),
    });
    expect(state.enrichment?.priorChats?.count).toBe(1);
    expect(state.enrichment?.priorChats?.mostRecentTitle).toBe("how do I claim my profile");
  });

  it("omits priorChats entirely when there are no prior conversations", async () => {
    const state = stateWithConv("conv_current");
    await enrichSession(state, IDENTITY, {
      lookupSnapshot: async () => null,
      // only the current one matched
      listPriorConversations: async () => ({ conversations: [CONVOS[0]], totalCount: 1 }),
    });
    expect(state.enrichment?.priorChats).toBeUndefined();
  });

  it("does not attempt prior-chat lookup without a contactId", async () => {
    const state = stateWithConv("conv_current");
    const listPriorConversations = vi.fn(async () => ({ conversations: CONVOS, totalCount: 3 }));
    await enrichSession(state, { email: "jane@example.com", name: "Jane" }, {
      lookupSnapshot: async () => null,
      listPriorConversations,
    });
    expect(listPriorConversations).not.toHaveBeenCalled();
    expect(state.enrichment?.priorChats).toBeUndefined();
  });

  it("prior-chat lookup failure does not lose the snapshot (legs are independent)", async () => {
    const state = stateWithConv("conv_current");
    await enrichSession(state, IDENTITY, {
      lookupSnapshot: async () => SNAPSHOT,
      listPriorConversations: async () => {
        throw new Error("intercom 500");
      },
    });
    expect(state.enrichment?.snapshot).toEqual(SNAPSHOT);
    expect(state.enrichment?.priorChats).toBeUndefined();
    // marked failed so a later turn retries the missing half
    expect(state.enrichment?.status).toBe("failed");
  });

  it("snapshot failure does not lose prior chats (legs are independent)", async () => {
    const state = stateWithConv("conv_current");
    await enrichSession(state, IDENTITY, {
      lookupSnapshot: async () => {
        throw new Error("admin 500");
      },
      listPriorConversations: async () => ({ conversations: CONVOS, totalCount: 3 }),
    });
    expect(state.enrichment?.priorChats?.count).toBe(2);
    expect(state.enrichment?.snapshot).toBeUndefined();
    expect(state.enrichment?.status).toBe("failed");
  });

  it("runs both legs in parallel and passes the contactId + enrichment timeout to the prior-chat lookup", async () => {
    const state = stateWithConv("conv_current");
    const listPriorConversations = vi.fn(async () => ({ conversations: [], totalCount: 0 }));
    await enrichSession(state, IDENTITY, {
      lookupSnapshot: async () => SNAPSHOT,
      listPriorConversations,
    });
    expect(listPriorConversations).toHaveBeenCalledWith("user_abc", { timeoutMs: DEFAULT_ENRICH_TIMEOUT_MS });
  });

  it("passes a configured timeout to the prior-chat lookup (stays within the enrichment budget)", async () => {
    const state = stateWithConv("conv_current");
    const listPriorConversations = vi.fn(async () => ({ conversations: [], totalCount: 0 }));
    await enrichSession(state, IDENTITY, {
      lookupSnapshot: async () => SNAPSHOT,
      listPriorConversations,
      timeoutMs: 800,
    });
    expect(listPriorConversations).toHaveBeenCalledWith("user_abc", { timeoutMs: 800 });
  });
});
