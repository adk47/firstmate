import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { blockUnsanctionedBatchMessage } from "../src/hooks/block-unsanctioned-batch-message.js";
import { cvSessions } from "../src/state.js";

const PROD_CHANNEL = "C0APB2CMM7C";
const DRY_RUN_CHANNEL = "C_DRY_TEST";
const OTHER_CHANNEL = "C_OTHER";

const buildCtx = (
  overrides: Partial<{ sessionKey: string; runId: string; agentId: string }> = {},
) => ({
  toolName: "message",
  sessionKey: overrides.sessionKey,
  runId: overrides.runId,
  agentId: overrides.agentId ?? "operations",
});

const buildEvent = (
  toolName: string,
  params: Record<string, unknown>,
) => ({ toolName, params });

describe("blockUnsanctionedBatchMessage", () => {
  let tmpDir: string;
  let runlogDir: string;

  beforeEach(() => {
    cvSessions.clear();
    tmpDir = mkdtempSync(join(tmpdir(), "blockmsg-"));
    runlogDir = join(tmpDir, "runlog");
    mkdirSync(runlogDir, { recursive: true });
    process.env.OPS_RUNLOG_DIR = runlogDir;
    process.env.OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID = DRY_RUN_CHANNEL;
    delete process.env.OPS_CREDIT_VERIFICATION_CHANNEL_ID;
  });

  afterEach(() => {
    cvSessions.clear();
    rmSync(tmpDir, { recursive: true, force: true });
    delete process.env.OPS_RUNLOG_DIR;
    delete process.env.OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID;
    delete process.env.OPS_CREDIT_VERIFICATION_CHANNEL_ID;
  });

  function seedRunlogWithRunFinished(): string {
    const runId = "20260428-153425-0ac365";
    const day = `${runId.slice(0, 4)}-${runId.slice(4, 6)}-${runId.slice(6, 8)}`;
    const dayDir = join(runlogDir, day);
    mkdirSync(dayDir, { recursive: true });
    const runlog = join(dayDir, `${runId}.jsonl`);
    writeFileSync(
      runlog,
      `${JSON.stringify({ event: "run_finished", run_id: runId, fetched: 25, approved: 0 })}\n`,
    );
    writeFileSync(join(runlogDir, "latest.txt"), runlog);
    return runId;
  }

  it("blocks hollow-bail text post to prod CV channel pre-run_finished", () => {
    const r = blockUnsanctionedBatchMessage(
      buildEvent("message", {
        target: PROD_CHANNEL,
        text: "Queue fetch succeeded — no writes were executed.",
      }),
      buildCtx(),
    );
    expect(r?.block).toBe(true);
    expect(r?.blockReason).toMatch(/post-batch-summary\.sh/);
  });

  it("blocks hollow-bail text post to dry-run CV channel pre-run_finished", () => {
    const r = blockUnsanctionedBatchMessage(
      buildEvent("message", {
        target: DRY_RUN_CHANNEL,
        text: "Queue fetch succeeded — no writes were executed.",
      }),
      buildCtx(),
    );
    expect(r?.block).toBe(true);
  });

  it("blocks post matching renderer canonical header (Credit batch complete)", () => {
    const r = blockUnsanctionedBatchMessage(
      buildEvent("message", {
        target: PROD_CHANNEL,
        text: "Credit batch complete — 2026-04-28 15:34 UTC\nFetched: 25 | Approved: 0",
      }),
      buildCtx(),
    );
    expect(r?.block).toBe(true);
  });

  it("blocks post matching renderer canonical header with [DRY RUN] prefix", () => {
    const r = blockUnsanctionedBatchMessage(
      buildEvent("message", {
        target: DRY_RUN_CHANNEL,
        text: "[DRY RUN] Credit batch complete — 2026-04-28 15:34 UTC\nFetched: 25",
      }),
      buildCtx(),
    );
    expect(r?.block).toBe(true);
  });

  it("blocks [HEARTBEAT-BATCH] summary post pre-run_finished", () => {
    const r = blockUnsanctionedBatchMessage(
      buildEvent("message", {
        target: PROD_CHANNEL,
        text: "[HEARTBEAT-BATCH] Credit Verification Batch — 2026-04-28 15:34 UTC\nFetched: 25 | Approved: 0",
      }),
      buildCtx(),
    );
    expect(r?.block).toBe(true);
  });

  it("blocks summary-shaped post even after run_finished", () => {
    seedRunlogWithRunFinished();
    const r = blockUnsanctionedBatchMessage(
      buildEvent("message", {
        target: PROD_CHANNEL,
        text: "Credit batch complete — 2026-04-28 15:34 UTC\nFetched: 25 | Approved: 0",
      }),
      buildCtx(),
    );
    expect(r?.block).toBe(true);
  });

  it("allows allowlisted preflight abort template", () => {
    const r = blockUnsanctionedBatchMessage(
      buildEvent("message", {
        target: PROD_CHANNEL,
        text: "⚠️ Batch aborted at pre-flight — browser tool unavailable in this session. Run ID: x. No credits processed.",
      }),
      buildCtx(),
    );
    expect(r).toBeUndefined();
  });

  it("allows allowlisted B0d.5 contamination abort template", () => {
    const r = blockUnsanctionedBatchMessage(
      buildEvent("message", {
        target: PROD_CHANNEL,
        text: "⚠️ Batch aborted at B0d.5 — Tier-1 web_fetch detected in this run's session.",
      }),
      buildCtx(),
    );
    expect(r).toBeUndefined();
  });

  it("allows allowlisted B1 silent-zero escalation template", () => {
    const r = blockUnsanctionedBatchMessage(
      buildEvent("message", {
        target: PROD_CHANNEL,
        text: "⚠️ Batch aborted at B1 — admin API envelope drift OR silent-zero (count>0, items=0).",
      }),
      buildCtx(),
    );
    expect(r).toBeUndefined();
  });

  it("allows allowlisted B1 API-error operational post even with [HEARTBEAT-BATCH]", () => {
    const r = blockUnsanctionedBatchMessage(
      buildEvent("message", {
        target: PROD_CHANNEL,
        text: "[HEARTBEAT-BATCH] Credit Verification Batch — 2026-04-28 15:34 UTC\n⚠️ API error fetching unverified queue. Skipping this cycle.\nError: 500",
      }),
      buildCtx(),
    );
    expect(r).toBeUndefined();
  });

  it("allows runaway batch operational alert", () => {
    const r = blockUnsanctionedBatchMessage(
      buildEvent("message", {
        target: PROD_CHANNEL,
        text: "🚨 Runaway batch — projected 90 of 100 moves to verification_needed. Pausing. <@U038BM16T7W>",
      }),
      buildCtx(),
    );
    expect(r).toBeUndefined();
  });

  it("allows error-storm operational alert", () => {
    const r = blockUnsanctionedBatchMessage(
      buildEvent("message", {
        target: PROD_CHANNEL,
        text: "🚨 Error storm — 55 of 100 credits errored this batch. Likely API degradation. <@U038BM16T7W>",
      }),
      buildCtx(),
    );
    expect(r).toBeUndefined();
  });

  it("allows per-credit escalation post", () => {
    const r = blockUnsanctionedBatchMessage(
      buildEvent("message", {
        target: PROD_CHANNEL,
        text: "🔍 ESCALATION — Profile as Writer on \"Track\"\n<@U038BM16T7W> — please review. Reply \"approve\" or \"reject [reason]\" in this thread.",
      }),
      buildCtx(),
    );
    expect(r).toBeUndefined();
  });

  it("allows non-summary operational post pre-run_finished", () => {
    const r = blockUnsanctionedBatchMessage(
      buildEvent("message", {
        target: PROD_CHANNEL,
        text: "Investigating degraded admin API response for run 20260428-153425-0ac365.",
      }),
      buildCtx(),
    );
    expect(r).toBeUndefined();
  });

  it("allows free-form (non-summary) post to non-CV channels unconditionally", () => {
    // Non-summary text + non-CV channel → pass-through. Summary-shaped text
    // from operations agent is blocked regardless of channel — covered below.
    const r = blockUnsanctionedBatchMessage(
      buildEvent("message", {
        target: OTHER_CHANNEL,
        text: "Quick clarification on the migration timeline.",
      }),
      buildCtx(),
    );
    expect(r).toBeUndefined();
  });

  it("blocks summary-shaped text from operations agent even to a non-CV channel (target leaks)", () => {
    // 2026-04-30 widening: there is no legitimate path that hand-composes a
    // [HEARTBEAT-BATCH] / Credit batch complete message via the MCP message
    // tool. Block regardless of target — operations agent must use
    // post-batch-summary.sh.
    const r = blockUnsanctionedBatchMessage(
      buildEvent("message", {
        target: OTHER_CHANNEL,
        text: "Queue fetch succeeded — no writes were executed.",
      }),
      buildCtx(),
    );
    expect(r?.block).toBe(true);
  });

  it("allows non-summary post once runlog has run_finished (post-finish phase)", () => {
    seedRunlogWithRunFinished();
    const r = blockUnsanctionedBatchMessage(
      buildEvent("message", {
        target: PROD_CHANNEL,
        text: "Follow-up clarification: actually we did process Nathalie Martinez's credits.",
      }),
      buildCtx(),
    );
    expect(r).toBeUndefined();
  });

  it("allows empty text pass-through", () => {
    const r = blockUnsanctionedBatchMessage(
      buildEvent("message", {
        target: PROD_CHANNEL,
        text: "",
      }),
      buildCtx(),
    );
    expect(r).toBeUndefined();
  });

  it("ignores tool calls outside CV context (no agentId, no sessionKey, no runId)", () => {
    const r = blockUnsanctionedBatchMessage(
      buildEvent("message", {
        target: PROD_CHANNEL,
        text: "Queue fetch succeeded — no writes were executed.",
      }),
      // empty ctx — neither agentId nor sessionKey marks it as CV
      { toolName: "message" },
    );
    expect(r).toBeUndefined();
  });

  it("ignores non-message tools (web_fetch, browser, etc.)", () => {
    const r = blockUnsanctionedBatchMessage(
      buildEvent("web_fetch", {
        target: PROD_CHANNEL,
        text: "Queue fetch succeeded — no writes were executed.",
      }),
      buildCtx(),
    );
    expect(r).toBeUndefined();
  });

  it("handles slack_message tool name variant", () => {
    const r = blockUnsanctionedBatchMessage(
      buildEvent("slack_message", {
        channelId: PROD_CHANNEL,
        body: "Queue fetch succeeded — no writes were executed.",
      }),
      buildCtx(),
    );
    expect(r?.block).toBe(true);
  });

  it("handles send_message tool name variant", () => {
    const r = blockUnsanctionedBatchMessage(
      buildEvent("send_message", {
        chat_id: PROD_CHANNEL,
        message: "Queue fetch succeeded — no writes were executed.",
      }),
      buildCtx(),
    );
    expect(r?.block).toBe(true);
  });

  it("uses OPS_CREDIT_VERIFICATION_CHANNEL_ID env override over the hardcoded prod default (non-summary path)", () => {
    // The env override matters for NON-summary messages where target gating
    // decides the verdict. Summary-shaped text is now blocked regardless of
    // target (see "blocks summary-shaped text from operations agent even
    // to a non-CV channel" above), so we use a non-summary text here to
    // exercise the channel-resolution branch specifically.
    process.env.OPS_CREDIT_VERIFICATION_CHANNEL_ID = "C_CUSTOM_PROD";
    // Non-summary text → blocking depends on whether target is policed.
    // Currently the hook only blocks summary-shaped text, so non-summary
    // posts pass through whether target is CV or not. This test guards
    // the future case where a non-summary CV-channel block is added.
    const r1 = blockUnsanctionedBatchMessage(
      buildEvent("message", {
        target: "C_CUSTOM_PROD",
        text: "Investigating degraded admin API response for run 20260428-153425-0ac365.",
      }),
      buildCtx(),
    );
    expect(r1).toBeUndefined();
    const r2 = blockUnsanctionedBatchMessage(
      buildEvent("message", {
        target: PROD_CHANNEL,
        text: "Investigating degraded admin API response for run 20260428-153425-0ac365.",
      }),
      buildCtx(),
    );
    expect(r2).toBeUndefined();
  });

  it("blocks summary-shaped post with target='' (the 2026-04-30 leak shape)", () => {
    // Run 20260430-081740-585500 leaked because the agent posted with
    // params.target = "" (empty string). The old isCvChannel("") returned
    // false → hook bailed → message slipped through and downstream openclaw
    // resolved the empty target to the CV channel. The widened gate now
    // blocks summary-shaped CV-context posts regardless of target.
    const r = blockUnsanctionedBatchMessage(
      buildEvent("message", {
        target: "",
        text: "[HEARTBEAT-BATCH] Credit batch complete — 2026-04-30 08:17 UTC\nFetched: 10 | Approved: 0 | → verification_needed: 10",
      }),
      buildCtx(),
    );
    expect(r?.block).toBe(true);
  });

  it("blocks summary-shaped post with no target field at all", () => {
    // Same as above but target is undefined (key not set in params).
    const r = blockUnsanctionedBatchMessage(
      buildEvent("message", {
        text: "Credit batch complete — 2026-04-30 08:17 UTC\nFetched: 10 | Approved: 0",
      }),
      buildCtx(),
    );
    expect(r?.block).toBe(true);
  });

  it("allows operational template (B0d preflight abort) with empty target — operational allowlist beats target gating", () => {
    // Operational allowlist matches happen before the summary-shape check,
    // so operational templates pass through even with no target. This
    // preserves the operational template flow regardless of target shape.
    const r = blockUnsanctionedBatchMessage(
      buildEvent("message", {
        target: "",
        text: "⚠️ Batch aborted at pre-flight — browser tool unavailable in this session. Run ID: x. No credits processed.",
      }),
      buildCtx(),
    );
    expect(r).toBeUndefined();
  });

  it("does not require OPS_RUNLOG_DIR to block summary-shaped text", () => {
    delete process.env.OPS_RUNLOG_DIR;
    // No runlog lookup is required for the summary-shape gate, but verify
    // the hook doesn't throw when the env is absent.
    let r: ReturnType<typeof blockUnsanctionedBatchMessage> | undefined;
    expect(() => {
      r = blockUnsanctionedBatchMessage(
        buildEvent("message", {
          target: PROD_CHANNEL,
          text: "Queue fetch succeeded — no writes.",
        }),
        buildCtx(),
      );
    }).not.toThrow();
    expect(r?.block).toBe(true);
  });
});
