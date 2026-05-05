import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { blockEscalationWithoutBrowse } from "../src/hooks/block-escalation-without-browse.js";
import { cvSessions } from "../src/state.js";

const PROD_CHANNEL = "C0APB2CMM7C";

const buildCtx = (
  overrides: Partial<{ sessionKey: string; runId: string; agentId: string }> = {},
) => ({
  toolName: "message",
  sessionKey: overrides.sessionKey,
  runId: overrides.runId,
  agentId: overrides.agentId ?? "operations",
});

const buildEvent = (toolName: string, params: Record<string, unknown>) => ({
  toolName,
  params,
});

const ESCALATION_BODY =
  '🔍 ESCALATION — Pau Romero as Songwriter on "Track Title" (Artist X)\n' +
  "\n" +
  "Evidence: tier-1 sources do not confirm credited role on this track.\n" +
  "\n" +
  '<@U038BM16T7W> — please review. Reply "approve" or "reject [reason]" in this thread.';

describe("blockEscalationWithoutBrowse", () => {
  let tmpDir: string;
  let runlogDir: string;
  let sessionLog: string;

  beforeEach(() => {
    cvSessions.clear();
    tmpDir = mkdtempSync(join(tmpdir(), "blockescalate-"));
    runlogDir = join(tmpDir, "runlog");
    mkdirSync(runlogDir, { recursive: true });
    sessionLog = join(tmpDir, "session.jsonl");
    writeFileSync(sessionLog, "");
    process.env.OPS_RUNLOG_DIR = runlogDir;
    process.env.CV_SESSION_LOG_OVERRIDE = sessionLog;
    delete process.env.CV_REQUIRED_PROFILE_BROWSE;
  });

  afterEach(() => {
    cvSessions.clear();
    rmSync(tmpDir, { recursive: true, force: true });
    delete process.env.OPS_RUNLOG_DIR;
    delete process.env.CV_SESSION_LOG_OVERRIDE;
    delete process.env.CV_REQUIRED_PROFILE_BROWSE;
  });

  function seedRunStarted(ts: string): void {
    const runId = "20260430-130332-c1f8f9";
    const day = `${runId.slice(0, 4)}-${runId.slice(4, 6)}-${runId.slice(6, 8)}`;
    const dayDir = join(runlogDir, day);
    mkdirSync(dayDir, { recursive: true });
    const runlog = join(dayDir, `${runId}.jsonl`);
    writeFileSync(
      runlog,
      `${JSON.stringify({ event: "run_started", run_id: runId, ts })}\n`,
    );
    writeFileSync(join(runlogDir, "latest.txt"), runlog);
  }

  function appendBrowserCall(
    callId: string,
    url: string,
    timestamp: string,
    successful: boolean = true,
    text?: string,
  ): void {
    const callLine = JSON.stringify({
      timestamp,
      message: {
        role: "assistant",
        content: [{ type: "toolCall", id: callId, name: "browser", arguments: { url } }],
      },
    });
    // Default text matches the per-profile claim used by escalationBodyFor so
    // the new (2026-05-04) per-profile gate can attribute Tier-1 loads to the
    // profile being escalated. Tests that intentionally seed non-matching
    // pages should pass an explicit `text` argument.
    const defaultText = successful ? "Test Profile songwriter on Test Track — credited" : "";
    const resultText = text ?? defaultText;
    const resultLine = JSON.stringify({
      timestamp,
      message: {
        role: "toolResult",
        toolCallId: callId,
        isError: !successful,
        content: [{ type: "text", text: resultText }],
      },
    });
    writeFileSync(sessionLog, `${callLine}\n${resultLine}\n`, { flag: "a" });
  }

  it("blocks escalation with zero browser activity in run window", () => {
    seedRunStarted("2026-04-30T13:03:00Z");
    // No browser calls seeded.
    const r = blockEscalationWithoutBrowse(
      buildEvent("message", { target: PROD_CHANNEL, text: ESCALATION_BODY }),
      buildCtx(),
    );
    expect(r?.block).toBe(true);
    expect(r?.blockReason).toMatch(/browser load/i);
    expect(r?.blockReason).toMatch(/20260430-130332-c1f8f9|20260430-111343-1605a8/);
  });

  it("allows escalation with >=2 distinct Tier-1 successful browser loads in run window", () => {
    // PR #233: threshold raised from >=1 to >=2 distinct Tier-1 hosts.
    seedRunStarted("2026-04-30T13:03:00Z");
    appendBrowserCall("b1", "https://music.apple.com/us/artist/abc-123", "2026-04-30T13:04:00Z");
    appendBrowserCall("b2", "https://musicbrainz.org/artist/abc-123", "2026-04-30T13:05:00Z");
    const r = blockEscalationWithoutBrowse(
      buildEvent("message", { target: PROD_CHANNEL, text: ESCALATION_BODY }),
      buildCtx(),
    );
    expect(r).toBeUndefined();
  });

  it("blocks when only failed browser loads exist (isError=true does not count)", () => {
    seedRunStarted("2026-04-30T13:03:00Z");
    appendBrowserCall("b1", "https://music.apple.com/us/artist/abc-123", "2026-04-30T13:04:00Z", false);
    const r = blockEscalationWithoutBrowse(
      buildEvent("message", { target: PROD_CHANNEL, text: ESCALATION_BODY }),
      buildCtx(),
    );
    expect(r?.block).toBe(true);
  });

  it("ignores browser loads from before run_started (window-scoped)", () => {
    // Yesterday's browser load should NOT count toward today's run window.
    seedRunStarted("2026-04-30T13:03:00Z");
    appendBrowserCall("b-old", "https://music.apple.com/us/artist/old", "2026-04-29T10:00:00Z");
    const r = blockEscalationWithoutBrowse(
      buildEvent("message", { target: PROD_CHANNEL, text: ESCALATION_BODY }),
      buildCtx(),
    );
    expect(r?.block).toBe(true);
  });

  it("counts browser loads from after run_started (within window) — needs 2 distinct Tier-1", () => {
    seedRunStarted("2026-04-30T13:03:00Z");
    appendBrowserCall("b-old", "https://music.apple.com/us/artist/old", "2026-04-29T10:00:00Z");
    appendBrowserCall("b-new1", "https://music.apple.com/us/artist/new", "2026-04-30T13:05:00Z");
    appendBrowserCall("b-new2", "https://allmusic.com/artist/new", "2026-04-30T13:06:00Z");
    const r = blockEscalationWithoutBrowse(
      buildEvent("message", { target: PROD_CHANNEL, text: ESCALATION_BODY }),
      buildCtx(),
    );
    expect(r).toBeUndefined();
  });

  it("does not gate non-escalation messages (operational templates)", () => {
    seedRunStarted("2026-04-30T13:03:00Z");
    // No browser activity, but the body is operational, not escalation.
    const r = blockEscalationWithoutBrowse(
      buildEvent("message", {
        target: PROD_CHANNEL,
        text: "Investigating degraded admin API response for run 20260428-153425-0ac365.",
      }),
      buildCtx(),
    );
    expect(r).toBeUndefined();
  });

  it("does not gate non-CV context (no agentId, no sessionKey, no runId)", () => {
    seedRunStarted("2026-04-30T13:03:00Z");
    const r = blockEscalationWithoutBrowse(
      buildEvent("message", { target: PROD_CHANNEL, text: ESCALATION_BODY }),
      { toolName: "message" },
    );
    expect(r).toBeUndefined();
  });

  it("does not gate non-message tools", () => {
    seedRunStarted("2026-04-30T13:03:00Z");
    const r = blockEscalationWithoutBrowse(
      buildEvent("web_fetch", { target: PROD_CHANNEL, text: ESCALATION_BODY }),
      buildCtx(),
    );
    expect(r).toBeUndefined();
  });

  it("CV_REQUIRED_PROFILE_BROWSE=0 bypasses the gate", () => {
    seedRunStarted("2026-04-30T13:03:00Z");
    process.env.CV_REQUIRED_PROFILE_BROWSE = "0";
    const r = blockEscalationWithoutBrowse(
      buildEvent("message", { target: PROD_CHANNEL, text: ESCALATION_BODY }),
      buildCtx(),
    );
    expect(r).toBeUndefined();
  });

  it("fails OPEN when no session log can be discovered (infra issue, not bypass)", () => {
    seedRunStarted("2026-04-30T13:03:00Z");
    // Override points at a non-existent path → discovery returns undefined.
    process.env.CV_SESSION_LOG_OVERRIDE = join(tmpDir, "does-not-exist.jsonl");
    const r = blockEscalationWithoutBrowse(
      buildEvent("message", { target: PROD_CHANNEL, text: ESCALATION_BODY }),
      buildCtx(),
    );
    expect(r).toBeUndefined();
  });

  it("counts unbounded window when no run_started is in the runlog", () => {
    // No runlog → no run_started_ts → unbounded window. Browser loads from
    // any time count, including past sessions. This is intentional: missing
    // runlog is an infra issue, fall back to permissive matching. Threshold
    // (>=2 distinct Tier-1) still applies.
    appendBrowserCall("b1", "https://music.apple.com/us/artist/abc-123", "2026-04-29T10:00:00Z");
    appendBrowserCall("b2", "https://musicbrainz.org/artist/abc-123", "2026-04-29T10:05:00Z");
    const r = blockEscalationWithoutBrowse(
      buildEvent("message", { target: PROD_CHANNEL, text: ESCALATION_BODY }),
      buildCtx(),
    );
    expect(r).toBeUndefined();
  });

  it("recognizes escalation shape with em-dash (—)", () => {
    seedRunStarted("2026-04-30T13:03:00Z");
    const r = blockEscalationWithoutBrowse(
      buildEvent("message", {
        target: PROD_CHANNEL,
        text: "🔍 ESCALATION — Profile X as Role on Track",
      }),
      buildCtx(),
    );
    expect(r?.block).toBe(true);
  });

  it("recognizes escalation shape with hyphen (-)", () => {
    seedRunStarted("2026-04-30T13:03:00Z");
    const r = blockEscalationWithoutBrowse(
      buildEvent("message", {
        target: PROD_CHANNEL,
        text: "🔍 ESCALATION - Profile X as Role on Track",
      }),
      buildCtx(),
    );
    expect(r?.block).toBe(true);
  });

  it('recognizes escalation shape via the "please review" reply prompt', () => {
    seedRunStarted("2026-04-30T13:03:00Z");
    const r = blockEscalationWithoutBrowse(
      buildEvent("message", {
        target: PROD_CHANNEL,
        text: 'Some prose then please review. Reply "approve" or "reject"',
      }),
      buildCtx(),
    );
    expect(r?.block).toBe(true);
  });

  it("handles slack_message tool name variant", () => {
    seedRunStarted("2026-04-30T13:03:00Z");
    const r = blockEscalationWithoutBrowse(
      buildEvent("slack_message", { channelId: PROD_CHANNEL, body: ESCALATION_BODY }),
      buildCtx(),
    );
    expect(r?.block).toBe(true);
  });

  it("handles send_message tool name variant", () => {
    seedRunStarted("2026-04-30T13:03:00Z");
    const r = blockEscalationWithoutBrowse(
      buildEvent("send_message", { chat_id: PROD_CHANNEL, message: ESCALATION_BODY }),
      buildCtx(),
    );
    expect(r?.block).toBe(true);
  });

  it("ignores empty body — pass-through (e.g. reaction tool calls)", () => {
    seedRunStarted("2026-04-30T13:03:00Z");
    const r = blockEscalationWithoutBrowse(
      buildEvent("message", { target: PROD_CHANNEL, text: "" }),
      buildCtx(),
    );
    expect(r).toBeUndefined();
  });

  it("PR #233: 1 Tier-1 host is NOT sufficient (raised from >=1 to >=2)", () => {
    // Threshold raised in PR #233 because a single decorative browser call
    // satisfied the prior >=1 floor without proving real investigation.
    seedRunStarted("2026-04-30T13:03:00Z");
    appendBrowserCall("b1", "https://music.apple.com/us/artist/abc-123", "2026-04-30T13:04:00Z");
    const r = blockEscalationWithoutBrowse(
      buildEvent("message", { target: PROD_CHANNEL, text: ESCALATION_BODY }),
      buildCtx(),
    );
    expect(r?.block).toBe(true);
    expect(r?.blockReason).toMatch(/2\s+distinct Tier-1/i);
  });

  it("PR #233: 2 successful loads to the SAME Tier-1 host count as 1 (dedup)", () => {
    // Hostname-deduped: two pages on Spotify count as one Tier-1 host. Need
    // a second distinct Tier-1 host to satisfy the gate.
    seedRunStarted("2026-04-30T13:03:00Z");
    appendBrowserCall("b1", "https://music.apple.com/us/artist/abc-123", "2026-04-30T13:04:00Z");
    appendBrowserCall("b2", "https://music.apple.com/us/artist/xyz-789", "2026-04-30T13:05:00Z");
    const r = blockEscalationWithoutBrowse(
      buildEvent("message", { target: PROD_CHANNEL, text: ESCALATION_BODY }),
      buildCtx(),
    );
    expect(r?.block).toBe(true);
  });

  it("PR #233: non-Tier-1 successful browser loads do NOT count", () => {
    // Internal muso.ai page counts toward the dispatcher's browse-required
    // gate (PR #232) but NOT toward this hook's Tier-1 quorum.
    seedRunStarted("2026-04-30T13:03:00Z");
    appendBrowserCall("b1", "https://muso.ai/profile/abc-123", "2026-04-30T13:04:00Z");
    appendBrowserCall("b2", "https://hoborec.com/artist/abc", "2026-04-30T13:05:00Z");
    const r = blockEscalationWithoutBrowse(
      buildEvent("message", { target: PROD_CHANNEL, text: ESCALATION_BODY }),
      buildCtx(),
    );
    expect(r?.block).toBe(true);
  });

  it("PR #233: www. prefix on Tier-1 hostnames is tolerated", () => {
    // Both www.musicbrainz.org and musicbrainz.org should count as the same
    // Tier-1 host (the Set has the bare form; urlHost strips www.).
    seedRunStarted("2026-04-30T13:03:00Z");
    appendBrowserCall("b1", "https://www.musicbrainz.org/artist/abc", "2026-04-30T13:04:00Z");
    appendBrowserCall("b2", "https://www.allmusic.com/artist/abc", "2026-04-30T13:05:00Z");
    const r = blockEscalationWithoutBrowse(
      buildEvent("message", { target: PROD_CHANNEL, text: ESCALATION_BODY }),
      buildCtx(),
    );
    expect(r).toBeUndefined();
  });

  it("malformed JSONL lines are skipped, not failed-CLOSED on entire log", () => {
    // A garbage line in the middle of the log shouldn't cause the gate to
    // misfire — the agent might have a corrupt line for any number of
    // reasons. As long as enough valid Tier-1 loads exist, allow.
    seedRunStarted("2026-04-30T13:03:00Z");
    writeFileSync(sessionLog, "{not json\n", { flag: "a" });
    appendBrowserCall("b1", "https://music.apple.com/us/artist/abc-123", "2026-04-30T13:04:00Z");
    appendBrowserCall("b2", "https://musicbrainz.org/artist/abc-123", "2026-04-30T13:05:00Z");
    writeFileSync(sessionLog, "another bad line\n", { flag: "a" });
    const r = blockEscalationWithoutBrowse(
      buildEvent("message", { target: PROD_CHANNEL, text: ESCALATION_BODY }),
      buildCtx(),
    );
    expect(r).toBeUndefined();
  });

  // ============================================================================
  // PR #233 follow-up — per-profile Tier-1 floor when Profile-ID line present.
  // Closes the "investigate one profile, escalate the rest" pattern observed in
  // run 20260501-093342-21352d (10 escalations, only 1 profile actually browsed).
  // ============================================================================

  const PROFILE_A = "ccd475a0-b28f-4d91-aa26-17ee786b3f5e";
  const PROFILE_B = "42b02257-aa5e-4517-9940-0b7bff488890";

  function escalationBodyFor(profileId: string): string {
    return (
      `🔍 ESCALATION — Test Profile as Songwriter on "Test Track" (Test Artist)\n` +
      `Profile-ID: ${profileId}\n` +
      `Credited-Name: Test Profile\n` +
      `Track-Title: Test Track\n` +
      `Roles: Songwriter\n` +
      "\n" +
      "Evidence: tier-1 sources do not confirm credited role on this track.\n" +
      "\n" +
      '<@U038BM16T7W> — please review. Reply "approve" or "reject [reason]" in this thread.'
    );
  }

  it("per-profile gate: 2 distinct Tier-1 hosts loaded AFTER muso.ai/profile/<uuid> → allow", () => {
    seedRunStarted("2026-04-30T13:03:00Z");
    // Anchor: agent navigates into the profile via muso.ai.
    appendBrowserCall("anchor", `https://muso.ai/profile/${PROFILE_A}`, "2026-04-30T13:04:00Z");
    // Then loads 2 distinct Tier-1 sources to investigate.
    appendBrowserCall("t1", "https://music.apple.com/us/artist/4gER", "2026-04-30T13:05:00Z");
    appendBrowserCall("t2", "https://musicbrainz.org/search?q=test", "2026-04-30T13:06:00Z");
    const r = blockEscalationWithoutBrowse(
      buildEvent("message", { target: PROD_CHANNEL, text: escalationBodyFor(PROFILE_A) }),
      buildCtx(),
    );
    expect(r).toBeUndefined();
  });

  it("per-profile gate: Tier-1 URL literally contains the profile UUID → counts directly", () => {
    seedRunStarted("2026-04-30T13:03:00Z");
    // Tier-1 URL has the muso UUID encoded in a query string — counts even
    // without a preceding muso.ai anchor (rule a).
    appendBrowserCall("t1", `https://music.apple.com/us/search?q=${PROFILE_A}`, "2026-04-30T13:04:00Z");
    appendBrowserCall("t2", `https://musicbrainz.org/search?query=${PROFILE_A}`, "2026-04-30T13:05:00Z");
    const r = blockEscalationWithoutBrowse(
      buildEvent("message", { target: PROD_CHANNEL, text: escalationBodyFor(PROFILE_A) }),
      buildCtx(),
    );
    expect(r).toBeUndefined();
  });

  it("per-profile gate: pages whose text doesn't match the dispatched profile's claim → block", () => {
    // 2026-05-04 refactor: per-profile attribution comes from response text
    // matching credited_name + track/role. Pages about a different person /
    // different track don't unlock the dispatched escalation, even if the
    // host is Tier-1.
    seedRunStarted("2026-04-30T13:03:00Z");
    appendBrowserCall("t1", "https://music.apple.com/us/artist/B", "2026-04-30T13:05:00Z", true,
      "Other Artist — different track entirely");
    appendBrowserCall("t2", "https://musicbrainz.org/artist/B", "2026-04-30T13:06:00Z", true,
      "Other Artist discography listing");
    const r = blockEscalationWithoutBrowse(
      buildEvent("message", { target: PROD_CHANNEL, text: escalationBodyFor(PROFILE_A) }),
      buildCtx(),
    );
    expect(r?.block).toBe(true);
    expect(r?.blockReason).toMatch(/per-profile/i);
    expect(r?.blockReason).toContain(PROFILE_A);
  });

  it("per-profile gate: 1 Tier-1 host with claim match → block (need >=2)", () => {
    seedRunStarted("2026-04-30T13:03:00Z");
    // Only 1 Tier-1 load with claim-matching text. Per-profile floor is 2.
    appendBrowserCall("t1", "https://music.apple.com/us/artist/4gER", "2026-04-30T13:05:00Z");
    const r = blockEscalationWithoutBrowse(
      buildEvent("message", { target: PROD_CHANNEL, text: escalationBodyFor(PROFILE_A) }),
      buildCtx(),
    );
    expect(r?.block).toBe(true);
    expect(r?.blockReason).toMatch(/1\/2/);
  });

  it("per-profile gate: only Tier-1 hosts with claim-matching response text count", () => {
    // 2026-05-04 refactor: order no longer matters; what matters is whether
    // each Tier-1 load's response text mentions the dispatched profile's
    // claim. A load whose text doesn't match (e.g. an unrelated artist's
    // page) doesn't count, even if it's a Tier-1 host.
    seedRunStarted("2026-04-30T13:03:00Z");
    appendBrowserCall("t_unrelated", "https://music.apple.com/us/artist/somebody", "2026-04-30T13:04:00Z", true,
      "Some other artist — different track");
    appendBrowserCall("t_match", "https://musicbrainz.org/artist/A", "2026-04-30T13:06:00Z");
    // Only 1 Tier-1 (musicbrainz) has claim-matching text. Spotify load is
    // an unrelated artist's page → doesn't count toward the per-profile floor.
    const r = blockEscalationWithoutBrowse(
      buildEvent("message", { target: PROD_CHANNEL, text: escalationBodyFor(PROFILE_A) }),
      buildCtx(),
    );
    expect(r?.block).toBe(true);
  });

  it("per-profile gate: 2 escalations for 2 different profiles each need their own evidence", () => {
    // Setup: agent properly investigates profile A, then properly investigates
    // profile B. Both escalations should pass independently.
    seedRunStarted("2026-04-30T13:03:00Z");
    appendBrowserCall("anchor_a", `https://muso.ai/profile/${PROFILE_A}`, "2026-04-30T13:04:00Z");
    appendBrowserCall("a_t1", "https://music.apple.com/us/artist/A", "2026-04-30T13:05:00Z");
    appendBrowserCall("a_t2", "https://musicbrainz.org/artist/A", "2026-04-30T13:06:00Z");
    appendBrowserCall("anchor_b", `https://muso.ai/profile/${PROFILE_B}`, "2026-04-30T13:07:00Z");
    appendBrowserCall("b_t1", "https://allmusic.com/artist/B", "2026-04-30T13:08:00Z");
    appendBrowserCall("b_t2", "https://discogs.com/artist/B", "2026-04-30T13:09:00Z");
    const rA = blockEscalationWithoutBrowse(
      buildEvent("message", { target: PROD_CHANNEL, text: escalationBodyFor(PROFILE_A) }),
      buildCtx(),
    );
    const rB = blockEscalationWithoutBrowse(
      buildEvent("message", { target: PROD_CHANNEL, text: escalationBodyFor(PROFILE_B) }),
      buildCtx(),
    );
    expect(rA).toBeUndefined();
    expect(rB).toBeUndefined();
  });

  it("Profile-ID matching is case-insensitive on the UUID", () => {
    // Real-world UUIDs in muso DBs are always lowercase, but the regex must
    // be permissive in case the agent uppercases it in the body.
    seedRunStarted("2026-04-30T13:03:00Z");
    appendBrowserCall("anchor", `https://muso.ai/profile/${PROFILE_A}`, "2026-04-30T13:04:00Z");
    appendBrowserCall("t1", "https://music.apple.com/us/artist/4gER", "2026-04-30T13:05:00Z");
    appendBrowserCall("t2", "https://musicbrainz.org/artist/X", "2026-04-30T13:06:00Z");
    const upperBody = escalationBodyFor(PROFILE_A.toUpperCase());
    const r = blockEscalationWithoutBrowse(
      buildEvent("message", { target: PROD_CHANNEL, text: upperBody }),
      buildCtx(),
    );
    expect(r).toBeUndefined();
  });

  it("Profile-ID absent → falls back to session-wide >=2 Tier-1 (older shape still works)", () => {
    // Backward compat: escalations without Profile-ID line still need run-wide
    // investigation but escape the per-profile bar. Useful during the SKILL
    // rollout window before all agents have updated.
    seedRunStarted("2026-04-30T13:03:00Z");
    appendBrowserCall("t1", "https://music.apple.com/us/artist/abc", "2026-04-30T13:04:00Z");
    appendBrowserCall("t2", "https://musicbrainz.org/artist/abc", "2026-04-30T13:05:00Z");
    const r = blockEscalationWithoutBrowse(
      buildEvent("message", { target: PROD_CHANNEL, text: ESCALATION_BODY }),
      buildCtx(),
    );
    expect(r).toBeUndefined();
  });
});
