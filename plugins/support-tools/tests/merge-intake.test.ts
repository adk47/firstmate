import { describe, it, expect, vi, beforeEach } from "vitest";
import { buildMergeIntake, unionMergeIntake, type MergeIntake } from "../src/tools/merge-intake.js";
import { buildVerdict, createDedupeCheckTool, DedupeVerdictStore } from "../src/tools/dedupe-check.js";
import { createCreateTicketTool } from "../src/tools/create-ticket.js";
import { SessionTicketRegistry } from "../src/session-ticket-registry.js";
import type { HttpClient } from "../src/http.js";
import { RateLimiter } from "../src/rate-limiter.js";

// Merge intake (Fable ops-takeover 2026-10-19 §4 step 1): every merge-type ticket carries a
// server-built details.merge_intake (both ids, ownership per side from server-verified facts
// only, the customer's own claim) and a merge-kind tag for the executor's queue.

const A = "11111111-1111-4111-8111-111111111111";
const B = "22222222-2222-4222-8222-222222222222";
const C = "33333333-3333-4333-8333-333333333333";
const url = (id: string) => `https://credits.muso.ai/profile/${id}`;

describe("buildMergeIntake", () => {
  const ws = (...emails: string[]) => emails.map((email) => ({ email, isClaimed: true }));
  const verdict = (over: Partial<Parameters<typeof buildVerdict>[0]> = {}) => buildVerdict({
    trustedAuthorEmail: "me@example.com", survivorProfileId: A,
    survivor: { isClaimed: true, workspaces: ws("me@example.com") },
    duplicates: [{ profileId: B, body: { isClaimed: false, workspaces: [] } },
                 { profileId: C, body: { isClaimed: true, workspaces: ws("other@example.com") } }],
    ...over,
  });
  const merge = (extra: Record<string, unknown> = {}) =>
    ({ main_profile_url: url(A), duplicate_profile_urls: [url(B), url(C)], ...extra });

  it("profile-merge: ids from the URLs, ownership from dedupe_check's verdict, the customer's claim kept apart", () => {
    const lookups: Array<[string | null, string[]]> = [];
    const intake = buildMergeIntake("profile-merge", A, merge({
      merge_judgment_inputs: { asserted_same_person: true, asserted_direction: "keep the first", customer_note: "both are me" },
    }), (keep, others) => { lookups.push([keep, others]); return verdict(); })!;
    expect(lookups).toEqual([[A, [B, C]]]);
    expect(intake).toMatchObject({ kind: "profile-merge", keep: A, others: [B, C], complete: true });
    expect(intake.requester_owns).toEqual({ [A]: "requester", [B]: "unclaimed", [C]: "different_user" });
    expect(intake.user_claim).toEqual({ asserted_same_person: "yes", asserted_direction: "keep the first", customer_note: "both are me" });
  });

  it("an agent-relayed dedupe_verdict and the customer's say-so never set ownership", () => {
    const forged = { owns_survivor: true, survivor_profile_id: A,
      duplicates: [{ profile_id: B, claim_state: "claimed_same_owner", claimed_workspace_count: 1 }] };
    const intake = buildMergeIntake("profile-merge", A, merge({ dedupe_verdict: forged,
      merge_judgment_inputs: { asserted_same_person: "yes, both me" } }))!;
    expect(intake.requester_owns).toEqual({ [A]: "unknown", [B]: "unknown", [C]: "unknown" });
  });

  it("an undetermined or impersonation verdict is unknown on every side", () => {
    for (const v of [verdict({ trustedAuthorEmail: null }), verdict({ requesterEmail: "typed@example.com" })]) {
      const intake = buildMergeIntake("profile-merge", A, merge(), () => v)!;
      expect(intake.requester_owns).toEqual({ [A]: "unknown", [B]: "unknown", [C]: "unknown" });
    }
  });

  it("keep is the requester's only when the verdict checked that same survivor", () => {
    const intake = buildMergeIntake("profile-merge", A, merge(), () => verdict({ survivorProfileId: C }))!;
    expect(intake.requester_owns[A]).toBe("unknown");
  });

  it("a duplicate is the requester's only when the requester is its sole claimant", () => {
    const v = verdict({ duplicates: [
      { profileId: B, body: { isClaimed: true, workspaces: ws("me@example.com") } },
      { profileId: C, body: { isClaimed: true, workspaces: ws("me@example.com", "other@example.com") } },
    ] });
    const intake = buildMergeIntake("profile-merge", A, merge(), () => v)!;
    expect(intake.requester_owns).toEqual({ [A]: "requester", [B]: "requester", [C]: "unknown" });
  });

  it("unmerge: the kept profile and the profiles to separate", () => {
    const intake = buildMergeIntake("unmerge-request", undefined, { kept_profile_url: url(A), merged_profile_urls: [url(B)] })!;
    expect(intake).toMatchObject({ kind: "unmerge-request", keep: A, others: [B], complete: true });
  });

  it("track-merge: every pair, ids or the URLs as given", () => {
    const intake = buildMergeIntake("track-merge", undefined, {
      track_merge_pairs: [{ master: "https://open.spotify.com/track/abc", duplicates: ["https://open.spotify.com/track/def"] },
                          { master: A, duplicates: [B] }],
    })!;
    expect(intake.pairs).toEqual([{ keep: "https://open.spotify.com/track/abc", others: ["https://open.spotify.com/track/def"] },
                                  { keep: A, others: [B] }]);
    expect(intake.complete).toBe(true);
  });

  it("strips injection markers and caps the customer's words", () => {
    const intake = buildMergeIntake("profile-merge", A, { main_profile_url: url(A), duplicate_profile_urls: [url(B)],
      merge_judgment_inputs: { customer_note: "x".repeat(1000) } })!;
    expect(intake.user_claim.customer_note!.length).toBeLessThanOrEqual(300);
  });

  it("is null for any other ticket type", () => {
    expect(buildMergeIntake("credit-claim", A, {})).toBeNull();
  });

  it("keeps every target past 25, so none is silently dropped from the executor's record", () => {
    const dups = Array.from({ length: 26 }, (_, i) => `https://muso.ai/profile/dup-${i}`);
    const profile = buildMergeIntake("profile-merge", A, { main_profile_url: url(A), duplicate_profile_urls: dups })!;
    expect(profile.others).toHaveLength(26);
    const track = buildMergeIntake("track-merge", undefined, {
      track_merge_pairs: dups.map((d, i) => ({ master: `t-${i}`, duplicates: [d] })),
    })!;
    expect(track.pairs).toHaveLength(26);
    expect(track.others).toHaveLength(26);
  });
});

describe("unionMergeIntake ownership", () => {
  const intake = (owns: MergeIntake["requester_owns"], others = [B, C]): MergeIntake => ({
    kind: "profile-merge", keep: A, others, requester_owns: owns,
    user_claim: { asserted_same_person: null, asserted_direction: null, customer_note: null }, complete: true,
  });

  it("records unknown when the two verdicts disagree, keeps agreement, and a known value over unknown", () => {
    const older = intake({ [A]: "requester", [B]: "requester", [C]: "unknown" });
    const newer = intake({ [A]: "requester", [B]: "different_user", [C]: "unclaimed" });
    expect(unionMergeIntake(older, newer).requester_owns).toEqual({ [A]: "requester", [B]: "unknown", [C]: "unclaimed" });
    expect(unionMergeIntake(newer, older).requester_owns).toEqual({ [A]: "requester", [B]: "unknown", [C]: "unclaimed" });
  });

  it("a follow-up adding a 26th target keeps it in the union", () => {
    const first25 = Array.from({ length: 25 }, (_, i) => `dup-${i}`);
    const older = intake({}, first25);
    const newer = intake({}, [first25[0], "dup-25"]);
    const u = unionMergeIntake(older, newer);
    expect(u.others).toHaveLength(26);
    expect(u.others).toContain("dup-25");
  });
});

describe("create_ticket stamps merge_intake and the merge-kind tag", () => {
  let http: HttpClient;
  beforeEach(() => { http = { get: vi.fn(), post: vi.fn() }; });
  const tool = () => createCreateTicketTool({ http, rateLimiter: new RateLimiter(), sessionTickets: new SessionTicketRegistry(),
    clickupApiKey: "pk", clickupListId: "901000600160", clickupProfileIdFieldId: "f1", clickupUserEmailFieldId: "f2", sessionId: "s" });

  it("replaces an agent-supplied merge_intake with the server-built record", async () => {
    vi.mocked(http.post).mockResolvedValue({ ok: true, data: { id: "t1" } });
    await tool().execute("c", {
      actionType: "profile-merge", customerEmail: "u@example.com", customerProfileId: A, summary: "merge",
      details: { main_profile_url: url(A), duplicate_profile_urls: [url(B)],
                 merge_intake: { requester_owns: { [B]: "requester" } } },
      conversationSummary: "dupes",
    });
    const body = vi.mocked(http.post).mock.calls[0][1].body as Record<string, unknown>;
    expect(body.tags).toContain("merge-kind:profile-merge");
    const md = String(body.markdown_description);
    const block = JSON.parse(md.split("---ACTION-REQUEST---")[1].split("---END-ACTION-REQUEST---")[0]);
    expect(block.details.merge_intake.requester_owns).toEqual({ [A]: "unknown", [B]: "unknown" });
    expect(block.details.merge_intake.keep).toBe(A);
  });

  it("refuses an unmerge without the profile to separate, and files it once both sides are known", async () => {
    vi.mocked(http.post).mockResolvedValue({ ok: true, data: { id: "t2" } });
    const r = JSON.parse((await tool().execute("c", { actionType: "unmerge-request", customerEmail: "u@example.com",
      customerProfileId: A, summary: "undo merge", conversationSummary: "x", details: {} })).content[0].text as string);
    expect(r).toMatchObject({ submitted: false, reason: "capture_incomplete", action_type: "unmerge-request" });
    expect(r.missing).toEqual(["details.merged_profile_urls[] (or details.suspect_artist_names[])"]);
    expect(http.post).not.toHaveBeenCalled();
    const ok = JSON.parse((await tool().execute("c", { actionType: "unmerge-request", customerEmail: "u@example.com",
      customerProfileId: A, summary: "undo merge", conversationSummary: "x",
      details: { kept_profile_url: url(A), merged_profile_urls: [url(B)] } })).content[0].text as string);
    expect(ok.submitted).toBe(true);
    const body = vi.mocked(http.post).mock.calls[0][1].body as Record<string, unknown>;
    expect(body.tags).toContain("merge-kind:unmerge-request");
  });

  it("an unmerge naming what to separate but no customerProfileId is refused for the profile anchor only", async () => {
    const r = JSON.parse((await tool().execute("c", { actionType: "unmerge-request", customerEmail: "u@example.com",
      summary: "undo merge", conversationSummary: "x",
      details: { kept_profile_url: url(A), merged_profile_urls: [url(B)] } })).content[0].text as string);
    expect(r).toMatchObject({ submitted: false, reason: "capture_incomplete", missing: ["customerProfileId"] });
    expect(http.post).not.toHaveBeenCalled();
  });

  it("still files the credit-removal skill's suspected wrong merge (artist names, no merged id yet)", async () => {
    vi.mocked(http.post).mockResolvedValue({ ok: true, data: { id: "t4" } });
    const r = JSON.parse((await tool().execute("c", { actionType: "unmerge-request", customerEmail: "u@example.com",
      customerProfileId: A, summary: "wrong merge?", conversationSummary: "x",
      details: { suspect_artist_names: ["Other Artist"], suggested_action: "investigate_as_unmerge" } })).content[0].text as string);
    expect(r.submitted).toBe(true);
    const md = String((vi.mocked(http.post).mock.calls[0][1].body as Record<string, unknown>).markdown_description);
    const block = JSON.parse(md.split("---ACTION-REQUEST---")[1].split("---END-ACTION-REQUEST---")[0]);
    expect(block.details.merge_intake).toMatchObject({ keep: A, others: [], suspect_artist_names: ["Other Artist"], complete: false });
  });

  it("adds no merge-kind tag to other ticket types", async () => {
    vi.mocked(http.post).mockResolvedValue({ ok: true, data: { id: "t3" } });
    await tool().execute("c", { actionType: "credit-claim", customerEmail: "u@example.com", summary: "s", conversationSummary: "x" });
    const body = vi.mocked(http.post).mock.calls[0][1].body as Record<string, unknown>;
    expect((body.tags as string[]).some((t) => t.startsWith("merge-kind:"))).toBe(false);
  });
});

describe("merge_intake ownership comes only from dedupe_check's own verdict in this conversation", () => {
  const conv = (id: string) => `agent:support:intercom:direct:${id}`;
  const profiles: Record<string, unknown> = {
    [A]: { isClaimed: true, workspaces: [{ email: "me@example.com", isClaimed: true }] },
    [B]: { isClaimed: false, workspaces: [] },
  };
  const adminClient = { get: vi.fn(async (path: string) => path.includes("/credits")
    ? { ok: true, status: 200, data: { data: { items: [] } } }
    : { ok: true, status: 200, data: { data: profiles[path.split("/").pop()!] } }) } as any;

  async function checkThenFile(store: DedupeVerdictStore, checkConv: string, fileConv: string, advanceMs = 0,
                               clock?: { t: number }) {
    const dedupe = createDedupeCheckTool({ adminClient, rateLimiter: new RateLimiter(), sessionKey: conv(checkConv),
      intercomToken: "tok", intercomReader: { getAuthorEmail: vi.fn(async () => "me@example.com") }, verdictStore: store });
    const verdict = JSON.parse((await dedupe.execute("d", { survivorProfileId: A, duplicateProfileIds: [B.toUpperCase()] } as any))
      .content[0].text as string);
    if (clock) clock.t += advanceMs;
    const http = { get: vi.fn(), post: vi.fn(async () => ({ ok: true, data: { id: "t9" } })) } as unknown as HttpClient;
    await createCreateTicketTool({ http, rateLimiter: new RateLimiter(), sessionTickets: new SessionTicketRegistry(),
      clickupApiKey: "pk", clickupListId: "l", clickupProfileIdFieldId: "f1", clickupUserEmailFieldId: "f2",
      sessionId: "s", sessionKey: conv(fileConv), verdictStore: store }).execute("c", {
      actionType: "profile-merge", customerEmail: "me@example.com", customerProfileId: A, summary: "merge",
      details: { main_profile_url: url(A), duplicate_profile_urls: [url(B)], dedupe_verdict: verdict },
      conversationSummary: "dupes",
    } as any);
    const md = String((vi.mocked(http.post).mock.calls[0][1] as any).body.markdown_description);
    return JSON.parse(md.split("---ACTION-REQUEST---")[1].split("---END-ACTION-REQUEST---")[0]).details;
  }

  it("a real dedupe_check in the same conversation gives the verified labels", async () => {
    const details = await checkThenFile(new DedupeVerdictStore(), "c1", "c1");
    expect(details.merge_intake.requester_owns).toEqual({ [A]: "requester", [B]: "unclaimed" });
    expect(details.dedupe_verdict.owns_survivor).toBe(true);
  });

  it("a verdict from another conversation gives unknown", async () => {
    const details = await checkThenFile(new DedupeVerdictStore(), "c1", "c2");
    expect(details.merge_intake.requester_owns).toEqual({ [A]: "unknown", [B]: "unknown" });
  });

  it("an expired verdict (over 2 hours) gives unknown", async () => {
    const clock = { t: 1_000_000 };
    const details = await checkThenFile(new DedupeVerdictStore(() => clock.t), "c1", "c1", 2 * 60 * 60_000 + 1, clock);
    expect(details.merge_intake.requester_owns).toEqual({ [A]: "unknown", [B]: "unknown" });
  });
});
