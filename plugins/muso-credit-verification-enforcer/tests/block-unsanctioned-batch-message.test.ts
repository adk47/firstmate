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

  it("allows free-form post to non-CV channels unconditionally", () => {
    const r = blockUnsanctionedBatchMessage(
      buildEvent("message", {
        target: OTHER_CHANNEL,
        text: "Queue fetch succeeded — no writes were executed.",
      }),
      buildCtx(),
    );
    expect(r).toBeUndefined();
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

  it("uses OPS_CREDIT_VERIFICATION_CHANNEL_ID env override over the hardcoded prod default", () => {
    process.env.OPS_CREDIT_VERIFICATION_CHANNEL_ID = "C_CUSTOM_PROD";
    const r1 = blockUnsanctionedBatchMessage(
      buildEvent("message", {
        target: "C_CUSTOM_PROD",
        text: "Queue fetch succeeded — no writes.",
      }),
      buildCtx(),
    );
    expect(r1?.block).toBe(true);
    // The hardcoded default should now NOT be policed.
    const r2 = blockUnsanctionedBatchMessage(
      buildEvent("message", {
        target: PROD_CHANNEL,
        text: "Queue fetch succeeded — no writes.",
      }),
      buildCtx(),
    );
    expect(r2).toBeUndefined();
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
