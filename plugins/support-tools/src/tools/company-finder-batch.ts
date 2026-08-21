import { Type, type Static } from "@sinclair/typebox";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdir, readdir, rename, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { textResult, type AgentTool, type AgentToolResult } from "../types.js";
import type { RateLimiter } from "../rate-limiter.js";

interface ProcessResult {
  stdout: string;
  stderr: string;
  exitCode: number | string | null;
}

type RunProcessLike = (
  file: string,
  args: readonly string[],
  signal?: AbortSignal,
) => Promise<ProcessResult>;

const SafeText = (maxLength: number) =>
  Type.String({ minLength: 1, maxLength, pattern: "^[^<>]*$" });

const Candidate = Type.Object({
  name: SafeText(300),
  domain: Type.String({ minLength: 1, maxLength: 500, pattern: "^[^<>]*$" }),
  vertical: SafeText(300),
  why: Type.Optional(SafeText(2_000)),
}, { additionalProperties: false });

const FinalCompany = Type.Object({
  name: SafeText(300),
  domain: Type.String({ minLength: 1, maxLength: 500, pattern: "^[^<>]*$" }),
  vertical: SafeText(300),
  tier: Type.Optional(SafeText(50)),
  website: Type.Optional(SafeText(500)),
  linkedin: Type.Optional(SafeText(500)),
  hq: Type.Optional(SafeText(300)),
  size: Type.Optional(SafeText(100)),
  why: Type.Optional(SafeText(2_000)),
  spend_signal: Type.Optional(SafeText(2_000)),
  first_touch: Type.Optional(SafeText(2_000)),
  evidence: Type.Optional(SafeText(4_000)),
  flags: Type.Optional(Type.Array(SafeText(500), { maxItems: 20 })),
  verification: Type.Optional(Type.Union([Type.Literal("alive"), Type.Literal("blocked")])),
  verified_at: Type.Optional(Type.String({ pattern: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$" })),
  http_code: Type.Optional(Type.String({ pattern: "^[0-9]{3}$" })),
}, { additionalProperties: false });

const TerminalReject = Type.Object({
  name: SafeText(300),
  domain: Type.String({ minLength: 1, maxLength: 500, pattern: "^[^<>]*$" }),
  reason: Type.Union([
    Type.Literal("DEAD"),
    Type.Literal("NO_LINKEDIN"),
    Type.Literal("IN_GHL"),
    Type.Literal("SUBSIDIARY"),
  ]),
  vertical: Type.Optional(SafeText(300)),
}, { additionalProperties: false });

const PrepParameters = Type.Object({
  candidates: Type.Array(Candidate, {
    maxItems: 40,
    description: "Required raw discovery union — EVERY candidate from this run, in one array. Pass [] explicitly when discovery found no candidates.",
  }),
}, { additionalProperties: false });

const FinalizeParameters = Type.Object({
  batch: Type.Array(FinalCompany, { minItems: 1, maxItems: 10 }),
  rejects: Type.Optional(Type.Array(TerminalReject, { maxItems: 100 })),
  date: Type.Optional(Type.String({ pattern: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$" })),
}, { additionalProperties: false });

type PrepParams = Static<typeof PrepParameters>;
type FinalizeParams = Static<typeof FinalizeParameters>;

interface ToolDeps {
  runnerPath: string;
  diagnosticsDir: string;
  sessionKey: string;
  sessionId: string;
  agentId: string;
  requesterSenderId?: string;
  rateLimiter: RateLimiter;
  runProcessImpl?: RunProcessLike;
}

interface StageResult {
  stdout: string;
  stderr: string;
  exitCode: number | string | null;
  diagnosticId: string;
  diagnosticWriteFailed: boolean;
}

interface DiagnosticHandle {
  id: string;
  file: string;
  inputFile: string;
  base: Record<string, unknown>;
}

export const DEFAULT_COMPANY_FINDER_RUNNER =
  process.env.COMPANY_FINDER_RUNNER ?? "/opt/hydra/scripts/company-finder/run-stage.sh";
export const DEFAULT_COMPANY_FINDER_DIAGNOSTICS_DIR =
  process.env.COMPANY_FINDER_DIAGNOSTICS_DIR ?? "/var/lib/hydra/company-finder-runs";
export const COMPANY_FINDER_CRON_SESSION =
  "agent:scout:cron:86adfcce-fe8a-4707-9c22-ad2bd4e43260";
const COMPANY_FINDER_CRON_RUN_PREFIX = `${COMPANY_FINDER_CRON_SESSION}:run:`;
const CRON_RUN_ID_PATTERN = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;

const AUTHORIZED_REQUESTERS = new Set([
  "U0AL36NADEY", // Nick
  "U7RP6HKUZ", // Aaron
  "U02S7C96CGN", // McLaren
]);
const DIAGNOSTIC_RETENTION_DAYS = 30;
const PROCESS_MAX_BUFFER = 4 * 1024 * 1024;
const ABORT_KILL_AFTER_MS = 10_000;

function signalProcessGroup(pid: number | undefined, signal: NodeJS.Signals): void {
  if (!pid) return;
  try {
    process.kill(-pid, signal);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error;
  }
}

export function runProcessGroup(
  file: string,
  args: readonly string[],
  signal?: AbortSignal,
  killAfterMs = ABORT_KILL_AFTER_MS,
): Promise<ProcessResult> {
  if (signal?.aborted) {
    return Promise.resolve({ stdout: "", stderr: "ABORTED", exitCode: "ABORTED" });
  }
  return new Promise((resolve) => {
    const child = spawn(file, args, { detached: true, stdio: ["ignore", "pipe", "pipe"] });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    let stdoutBytes = 0;
    let stderrBytes = 0;
    let forcedError: string | undefined;
    let killTimer: NodeJS.Timeout | undefined;

    const terminate = (reason: string) => {
      if (!forcedError) forcedError = reason;
      signalProcessGroup(child.pid, "SIGTERM");
      if (!killTimer) {
        killTimer = setTimeout(() => signalProcessGroup(child.pid, "SIGKILL"), killAfterMs);
        killTimer.unref();
      }
    };
    const append = (chunks: Buffer[], chunk: Buffer, stream: "stdout" | "stderr") => {
      if (stream === "stdout") stdoutBytes += chunk.length;
      else stderrBytes += chunk.length;
      if (stdoutBytes + stderrBytes > PROCESS_MAX_BUFFER) {
        terminate("COMPANY_FINDER_OUTPUT_TOO_LARGE");
        return;
      }
      chunks.push(chunk);
    };
    child.stdout.on("data", (chunk: Buffer) => append(stdout, chunk, "stdout"));
    child.stderr.on("data", (chunk: Buffer) => append(stderr, chunk, "stderr"));

    const onAbort = () => terminate("ABORTED");
    signal?.addEventListener("abort", onAbort, { once: true });
    if (signal?.aborted) onAbort();

    child.on("error", (error) => {
      forcedError = forcedError ?? error.message;
    });
    child.on("close", (code, closeSignal) => {
      signal?.removeEventListener("abort", onAbort);
      if (killTimer) clearTimeout(killTimer);
      resolve({
        stdout: Buffer.concat(stdout).toString("utf8"),
        stderr: Buffer.concat(stderr).toString("utf8") || forcedError || "",
        exitCode: forcedError ?? code ?? closeSignal,
      });
    });
  });
}

function isCompanyFinderCronSession(sessionKey: string): boolean {
  if (sessionKey === COMPANY_FINDER_CRON_SESSION) return true;
  if (!sessionKey.startsWith(COMPANY_FINDER_CRON_RUN_PREFIX)) return false;
  return CRON_RUN_ID_PATTERN.test(sessionKey.slice(COMPANY_FINDER_CRON_RUN_PREFIX.length));
}

function isAuthorized(deps: ToolDeps): boolean {
  if (deps.agentId !== "scout") return false;
  if (isCompanyFinderCronSession(deps.sessionKey)) return true;
  return Boolean(deps.requesterSenderId && AUTHORIZED_REQUESTERS.has(deps.requesterSenderId));
}

function parseObject(stdout: string): Record<string, any> | undefined {
  try {
    const value = JSON.parse(stdout.trim());
    return value && typeof value === "object" && !Array.isArray(value) ? value : undefined;
  } catch {
    return undefined;
  }
}

async function writeJsonAtomic(file: string, value: unknown): Promise<void> {
  const temporary = `${file}.${process.pid}.${randomUUID()}.tmp`;
  try {
    await writeFile(temporary, `${JSON.stringify(value)}\n`, {
      encoding: "utf8",
      mode: 0o600,
      flag: "wx",
    });
    await rename(temporary, file);
  } finally {
    await rm(temporary, { force: true });
  }
}

async function pruneDiagnostics(diagnosticsDir: string, now = new Date()): Promise<void> {
  const cutoff = new Date(now.getTime() - DIAGNOSTIC_RETENTION_DAYS * 86_400_000)
    .toISOString().slice(0, 10);
  for (const entry of await readdir(diagnosticsDir, { withFileTypes: true })) {
    if (entry.isDirectory() && /^\d{4}-\d{2}-\d{2}$/.test(entry.name) && entry.name < cutoff) {
      await rm(path.join(diagnosticsDir, entry.name), { recursive: true, force: true });
    }
  }
}

async function startDiagnostic(
  deps: ToolDeps,
  stage: "prep" | "finalize",
  toolCallId: string,
  input: unknown,
): Promise<DiagnosticHandle> {
  await mkdir(deps.diagnosticsDir, { recursive: true, mode: 0o700 });
  await pruneDiagnostics(deps.diagnosticsDir);
  const id = randomUUID();
  const dayDir = path.join(deps.diagnosticsDir, new Date().toISOString().slice(0, 10));
  await mkdir(dayDir, { recursive: true, mode: 0o700 });
  const base = {
    diagnosticId: id,
    state: "started",
    startedAt: new Date().toISOString(),
    stage,
    sessionKey: deps.sessionKey,
    toolCallId,
    stdin: input,
  };
  const file = path.join(dayDir, `${id}.json`);
  const inputFile = path.join(dayDir, `${id}.input.json`);
  try {
    await writeJsonAtomic(inputFile, input);
    await writeJsonAtomic(file, base);
  } catch (error) {
    await rm(inputFile, { force: true });
    throw error;
  }
  return { id, file, inputFile, base };
}

async function runStage(
  deps: ToolDeps,
  stage: "prep" | "finalize",
  input: unknown,
  toolCallId: string,
  signal?: AbortSignal,
): Promise<StageResult> {
  const diagnostic = await startDiagnostic(deps, stage, toolCallId, input);
  const runProcess = deps.runProcessImpl ?? runProcessGroup;
  const source = isCompanyFinderCronSession(deps.sessionKey)
    ? "cron:company-finder-daily"
    : "manual";
  let stdout = "";
  let stderr = "";
  let exitCode: number | string | null = 0;
  let result: ProcessResult;
  try {
    result = await runProcess(deps.runnerPath, [stage, diagnostic.inputFile, source], signal);
  } catch (error) {
    result = { stdout: "", stderr: String(error), exitCode: "PROCESS_LAUNCH_FAILED" };
  }
  exitCode = result.exitCode;
  stdout = result.stdout;
  stderr = result.stderr;
  await rm(diagnostic.inputFile, { force: true });

  let diagnosticWriteFailed = false;
  try {
    await writeJsonAtomic(diagnostic.file, {
      ...diagnostic.base,
      state: "finished",
      finishedAt: new Date().toISOString(),
      exitCode,
      stdout,
      stderr,
    });
  } catch (error) {
    diagnosticWriteFailed = true;
    console.error(`[company-finder] failed to finish diagnostic ${diagnostic.id}: ${String(error)}`);
  }
  return { stdout, stderr, exitCode, diagnosticId: diagnostic.id, diagnosticWriteFailed };
}

function failure(
  error: string,
  detail: string,
  diagnosticId?: string,
  exit?: number | string | null,
  extra?: Record<string, unknown>,
): AgentToolResult<unknown> {
  return textResult(JSON.stringify({
    ok: false,
    status: "failed",
    error,
    detail,
    ...(exit !== undefined ? { exit } : {}),
    ...(diagnosticId ? { diagnosticId } : {}),
    ...(extra ?? {}),
  }));
}

function stageFailure(result: StageResult): AgentToolResult<unknown> {
  if (result.diagnosticWriteFailed) {
    return failure(
      "DIAGNOSTIC_UPDATE_FAILED",
      "The stage finished but its terminal evidence could not be persisted; do not retry blindly.",
      result.diagnosticId,
      result.exitCode,
    );
  }
  const envelope = parseObject(result.stdout);
  return failure(
    envelope?.error ?? "COMPANY_FINDER_STAGE_FAILED",
    envelope?.detail ?? "The host-side stage failed; inspect the persisted diagnostic.",
    result.diagnosticId,
    envelope?.exit ?? result.exitCode,
  );
}

function authorize(deps: ToolDeps): AgentToolResult<unknown> | undefined {
  if (!isAuthorized(deps)) {
    return failure("COMPANY_FINDER_NOT_AUTHORIZED", "This tool is limited to the company-finder cron and approved requesters.");
  }
  return undefined;
}

/**
 * Per-tool, so a future "prep needs more headroom" edit cannot silently widen
 * the budget of the stage that writes the ledger and posts to Slack.
 *
 * A ceiling of 1 made the documented LEDGER_COLLISION recovery impossible for a
 * full window, and turned any caller-side mistake into a dead end. That recovery
 * costs BOTH stages a second call ("re-run prep on the union", then finalize
 * again), so 2 is the floor for each and 3 leaves room for one honest re-batch.
 *
 * This budget is NOT a concurrency guard: flock single-flight in
 * scripts/company-finder/lib/common.sh is, and above 1 call per window it becomes
 * reachable — a second simultaneous launch now returns ALREADY_RUNNING (exit 5)
 * instead of RATE_LIMITED. Both SOUL.md and the skill classify it as
 * caller-actionable so it is not escalated as an outage.
 */
const RATE_LIMIT_POLICY = {
  company_finder_prep: {
    windowMinutes: 15,
    maxCalls: 3,
    recovery:
      "company_finder_prep dedupes the ENTIRE candidate union in one call — it is not a per-candidate lookup. "
      + "If you split the union across calls, merge every remaining candidate into a single call and run it once when the window reopens.",
  },
  company_finder_finalize: {
    windowMinutes: 15,
    maxCalls: 3,
    recovery:
      "company_finder_finalize posts one assembled batch in one call. Merge the batch and run it once when the window reopens.",
  },
} as const;

type RateLimitedTool = keyof typeof RATE_LIMIT_POLICY;

/**
 * Charged only once a call is going to launch a stage, so a malformed or
 * unauthorized call cannot spend the window on work that never ran.
 */
function enforceRateLimit(deps: ToolDeps, toolName: RateLimitedTool): AgentToolResult<unknown> | undefined {
  const { windowMinutes, maxCalls, recovery } = RATE_LIMIT_POLICY[toolName];
  const verdict = deps.rateLimiter.check(deps.sessionId, toolName, windowMinutes, maxCalls);
  if (verdict.allowed) return undefined;
  // This envelope is the one thing the caller reliably reads at failure time, so
  // it carries both the correction and the reopen time. It is a caller-side
  // limit, not an outage: answer the requester, never escalate it as a tool failure.
  return failure(
    "RATE_LIMITED",
    `${toolName} already ran ${maxCalls} time(s) in this session in the last ${windowMinutes} minutes. `
      + `${recovery} Retry in ${verdict.retryAfterSeconds}s. `
      + "This is a caller-side rate limit, not an outage or an unavailable tool — tell the requester the retry time instead of escalating.",
    undefined,
    undefined,
    { retryAfterSeconds: verdict.retryAfterSeconds, requesterActionable: true },
  );
}

export function createCompanyFinderPrepTool(deps: ToolDeps): AgentTool<typeof PrepParameters, unknown> {
  return {
    name: "company_finder_prep",
    label: "Prepare Company Finder Batch",
    description: "Synchronously runs the deterministic company-finder dedupe and liveness wrapper and returns only after its complete output is captured and persisted. Call this EXACTLY ONCE per run, passing the ENTIRE candidate union — it is a batch operation, not a per-candidate lookup, and calling it per candidate exhausts the rate limit and returns nothing.",
    parameters: PrepParameters,
    async execute(toolCallId: string, params: PrepParams, signal?: AbortSignal): Promise<AgentToolResult<unknown>> {
      const denied = authorize(deps);
      if (denied) return denied;
      if (!params || !Array.isArray(params.candidates)) {
        return failure("INVALID_INPUT", "candidates is required; pass [] explicitly for no candidates");
      }
      const limited = enforceRateLimit(deps, "company_finder_prep");
      if (limited) return limited;

      let result: StageResult;
      try {
        result = await runStage(deps, "prep", params.candidates, toolCallId, signal);
      } catch (error) {
        return failure("DIAGNOSTIC_UNAVAILABLE", `The stage was not started because its diagnostic could not be created: ${String(error)}`);
      }
      if (result.exitCode !== 0) return stageFailure(result);
      if (result.diagnosticWriteFailed) return stageFailure(result);
      const parsed = parseObject(result.stdout);
      if (!parsed || !Array.isArray(parsed.survivors) || !parsed.rejects || typeof parsed.rejects !== "object" || !parsed.stats || typeof parsed.stats !== "object") {
        return failure("INVALID_STAGE_OUTPUT", "prep returned invalid JSON", result.diagnosticId);
      }
      return textResult(JSON.stringify({
        ...parsed,
        ok: true,
        status: parsed.survivors.length === 0 ? "no_candidates" : "prepared",
        terminal: parsed.survivors.length === 0,
        diagnosticId: result.diagnosticId,
      }));
    },
  };
}

export function createCompanyFinderFinalizeTool(deps: ToolDeps): AgentTool<typeof FinalizeParameters, unknown> {
  return {
    name: "company_finder_finalize",
    label: "Finalize Company Finder Batch",
    description: "Synchronously runs the company-finder ledger-and-post wrapper and returns only after its complete output is captured and persisted.",
    parameters: FinalizeParameters,
    async execute(toolCallId: string, params: FinalizeParams, signal?: AbortSignal): Promise<AgentToolResult<unknown>> {
      const denied = authorize(deps);
      if (denied) return denied;
      if (!params || !Array.isArray(params.batch) || params.batch.length === 0) {
        return failure("INVALID_INPUT", "batch must contain at least one company");
      }
      const limited = enforceRateLimit(deps, "company_finder_finalize");
      if (limited) return limited;
      const input = {
        batch: params.batch,
        rejects: params.rejects ?? [],
        ...(params.date ? { date: params.date } : {}),
      };

      let result: StageResult;
      try {
        result = await runStage(deps, "finalize", input, toolCallId, signal);
      } catch (error) {
        return failure("DIAGNOSTIC_UNAVAILABLE", `The stage was not started because its diagnostic could not be created: ${String(error)}`);
      }
      if (result.exitCode !== 0) return stageFailure(result);
      if (result.diagnosticWriteFailed) return stageFailure(result);
      const parsed = parseObject(result.stdout);
      if (!parsed || !parsed.posted || typeof parsed.posted.ts !== "string" || !parsed.ledger || typeof parsed.ledger !== "object") {
        return failure("INVALID_STAGE_OUTPUT", "finalize returned invalid JSON", result.diagnosticId);
      }
      return textResult(JSON.stringify({
        ...parsed,
        ok: true,
        status: "posted",
        terminal: true,
        diagnosticId: result.diagnosticId,
      }));
    },
  };
}
