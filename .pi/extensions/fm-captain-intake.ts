// Firstmate captain prompt intake for Pi.
//
// WHY THIS EXISTS. Pressing Enter while main is mid-turn is a Pi STEER: Pi
// injects the text right after the current tool batch, before the next model
// request, so the step the model had planned next (write the brief, then
// spawn) is displaced by the new instruction and a half-finished intake is
// abandoned or delayed. Alt+Enter is Pi's "wait until I finish" lane, but the
// captain should not have to remember it. This extension turns every captain
// prompt typed while a turn is running into a DURABLE INTAKE RECORD and
// re-delivers it as a FOLLOW-UP, so the current turn finishes untouched, the
// prompt is handled next in the order it was typed, and nothing typed is ever
// lost - even across an abort, a reload, or a crash.
//
// OPT-IN. The behaviour runs only while config/captain-intake exists in this
// home (docs/configuration.md "Captain prompt intake"); with the flag absent
// every prompt keeps Pi's native steer behaviour and this file is inert.
//
// WHAT IS CAPTURED (the whole decision, stated once):
//   - source "interactive" only: an extension or RPC prompt is never captured;
//   - streamingBehavior "steer" only: an idle prompt starts a run as before,
//     and an explicit Alt+Enter follow-up is already in the right lane;
//   - a slash command, a bash-mode line ("!"), and a short urgent word such as
//     "stop" or "cancel" keep the native steer, because those are exactly the
//     prompts that must interrupt;
//   - a prompt that already carries this extension's header (one Pi returned
//     to the editor on Escape and the captain resubmitted) is not re-wrapped.
//
// THE RECORD. state/intake/<seq>.prompt holds the verbatim captain text behind
// a small header (schema, seq, at, session); seq is monotonic per home. A
// record moves - never edits - between three places that ARE its state:
//   state/intake/<seq>.prompt     pending: accepted by Pi's queue, not yet
//                                 consumed by a run (or awaiting delivery)
//   state/intake/handled/         consumed: Pi started or joined a run with it
//   state/intake/released/        returned to the captain's editor by Escape,
//                                 so re-sending it would deliver it twice
// This file is the only writer and the only owner of that layout; the
// /intake command lists it for the captain.
//
// DELIVERY VERSUS CONSUMPTION. Pi's sendUserMessage accepts a follow-up and
// exposes no later rejection, so acceptance is not consumption. Consumption is
// observed where the watch extension observes it: a streaming main consumes at
// the user message_start carrying the exact wrapped text, an idle main at
// before_agent_start. A record still pending at agent_settled will never be
// consumed from the queue: if the run was aborted Pi has already returned the
// queue to the editor (interactive Escape), so the record is RELEASED rather
// than re-sent; otherwise it is re-sent after a short grace. A record still
// pending at session_start belongs to a session that was replaced or crashed
// and is re-sent into the new one. Every transition is announced in one line
// through ctx.ui.notify, and the status line shows how many are queued.
//
// MAIN-SIDE CONTRACT. The wrapped follow-up leads with one plain line naming
// the intake number and the time it was typed, then the captain's verbatim
// text. docs/supervision-protocols/pi.md owns what main does with it:
// acknowledge in one line, then handle it, several in order. The header is
// plain text rather than an operational marker on purpose: the supervision
// branch mirrors only captain dialog and the Calm layout hides operational
// input, and this IS captain dialog.
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

type IntakeRecord = {
  seq: number;
  at: string;
  body: string;
};

type NotifyUi = {
  notify?: (message: string, type?: "info" | "warning" | "error") => void;
  setStatus?: (key: string, text: string | undefined) => void;
};

type IntakeContext = {
  ui?: NotifyUi;
  isIdle?: () => boolean;
};

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const intakeFlag = `${config}/captain-intake`;
const intakeDir = `${state}/intake`;
const handledDir = `${intakeDir}/handled`;
const releasedDir = `${intakeDir}/released`;
const statusKey = "fm-intake";

export const INTAKE_SCHEMA = "fm-captain-intake.v1";
// The one line main reads before the captain's text. Stable so a test, the
// /intake listing, and the resubmission guard above all recognise it.
export const INTAKE_HEADER_PREFIX = "Firstmate intake #";

// Settle-time grace before an unconsumed, un-aborted record is re-sent. Pi
// defers prompts submitted during agent_settled, and a follow-up consumed in
// the settling run reports its message_start before settle, so this is only a
// guard against a reordered event, not a correctness dependency.
const resendGraceMs = positiveInteger("FM_INTAKE_RESEND_GRACE_MS", 1500);

// Short whole-message interrupts that must stay steers. Matched on the whole
// trimmed, lowercased text with trailing punctuation removed - never as a
// substring, so "stop the deploy and tell me why" is an ordinary prompt.
const urgentWords = new Set([
  "stop", "cancel", "abort", "halt", "wait", "pause", "hold on",
  "stop that", "cancel that", "never mind", "nevermind", "stop it",
]);

function positiveInteger(name: string, fallback: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  const value = Number.parseInt(raw, 10);
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

export function intakeEnabled(): boolean {
  return existsSync(intakeFlag);
}

export function isUrgentInterrupt(text: string): boolean {
  const normalized = text.trim().toLowerCase().replace(/[.!?,;:]+$/u, "").replace(/\s+/gu, " ");
  return urgentWords.has(normalized);
}

// The capture decision, stated once (see the header).
export function shouldCapture(event: {
  text: string;
  source: string;
  streamingBehavior?: string;
}): boolean {
  if (event.source !== "interactive") return false;
  if (event.streamingBehavior !== "steer") return false;
  const text = event.text;
  const trimmed = text.trim();
  if (!trimmed) return false;
  if (trimmed.startsWith("/") || trimmed.startsWith("!")) return false;
  if (trimmed.startsWith(INTAKE_HEADER_PREFIX)) return false;
  if (isUrgentInterrupt(trimmed)) return false;
  return true;
}

export function wrapIntake(record: IntakeRecord): string {
  const clock = record.at.replace(/^.*T/u, "").replace(/\.\d+Z$/u, "Z");
  return `${INTAKE_HEADER_PREFIX}${record.seq} (typed ${clock} while the previous turn was still running; acknowledge it in one line, then handle it):\n\n${record.body}`;
}

function ensureDirs(): void {
  mkdirSync(handledDir, { recursive: true });
  mkdirSync(releasedDir, { recursive: true });
}

function recordPath(seq: number): string {
  return `${intakeDir}/${seq}.prompt`;
}

function listPendingSeqs(): number[] {
  let names: string[] = [];
  try {
    names = readdirSync(intakeDir);
  } catch {
    return [];
  }
  return names
    .map((name) => /^(\d+)\.prompt$/u.exec(name))
    .filter((match): match is RegExpExecArray => match !== null)
    .map((match) => Number.parseInt(match[1], 10))
    .filter((seq) => Number.isFinite(seq))
    .sort((a, b) => a - b);
}

function maxSeq(dir: string): number {
  let names: string[] = [];
  try {
    names = readdirSync(dir);
  } catch {
    return 0;
  }
  let max = 0;
  for (const name of names) {
    const match = /^(\d+)\.prompt$/u.exec(name);
    if (!match) continue;
    const seq = Number.parseInt(match[1], 10);
    if (Number.isFinite(seq) && seq > max) max = seq;
  }
  return max;
}

function nextSeq(): number {
  return Math.max(maxSeq(intakeDir), maxSeq(handledDir), maxSeq(releasedDir)) + 1;
}

export function serializeRecord(record: IntakeRecord, session: string): string {
  return `schema=${INTAKE_SCHEMA}\nseq=${record.seq}\nat=${record.at}\nsession=${session}\n--\n${record.body}\n`;
}

export function parseRecord(content: string): IntakeRecord | undefined {
  const separator = content.indexOf("\n--\n");
  if (separator < 0) return undefined;
  const head = content.slice(0, separator).split("\n");
  if (head[0] !== `schema=${INTAKE_SCHEMA}`) return undefined;
  let seq = Number.NaN;
  let at = "";
  for (const line of head.slice(1)) {
    if (line.startsWith("seq=")) seq = Number.parseInt(line.slice(4), 10);
    else if (line.startsWith("at=")) at = line.slice(3);
  }
  if (!Number.isFinite(seq) || !at) return undefined;
  const body = content.slice(separator + 4).replace(/\n$/u, "");
  return { seq, at, body };
}

function readRecord(seq: number): IntakeRecord | undefined {
  try {
    return parseRecord(readFileSync(recordPath(seq), "utf8"));
  } catch {
    return undefined;
  }
}

function writeRecord(record: IntakeRecord, session: string): void {
  ensureDirs();
  const path = recordPath(record.seq);
  const tmp = `${path}.tmp.${process.pid}`;
  writeFileSync(tmp, serializeRecord(record, session), { mode: 0o600 });
  renameSync(tmp, path);
}

function moveRecord(seq: number, dir: string): boolean {
  try {
    renameSync(recordPath(seq), `${dir}/${seq}.prompt`);
    return true;
  } catch {
    return false;
  }
}

function dropRecord(seq: number): void {
  try {
    unlinkSync(recordPath(seq));
  } catch {
    // Already gone; nothing to drop.
  }
}

function textOfContent(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter(
      (block): block is { type: "text"; text: string } =>
        typeof block === "object" &&
        block !== null &&
        (block as { type?: unknown }).type === "text" &&
        typeof (block as { text?: unknown }).text === "string",
    )
    .map((block) => block.text)
    .join("\n");
}

export default function (pi: ExtensionAPI) {
  // Wrapped text by seq for every record this runtime has handed to Pi, so a
  // consumption event can be matched exactly rather than by prefix.
  const inFlight = new Map<number, string>();
  let resendTimer: ReturnType<typeof setTimeout> | null = null;
  let sessionId = "";

  const notify = (ctx: IntakeContext | undefined, message: string, type: "info" | "warning" | "error" = "info") => {
    try {
      ctx?.ui?.notify?.(message, type);
    } catch {
      // Notification is a courtesy; the record is the contract.
    }
  };

  const refreshStatus = (ctx: IntakeContext | undefined) => {
    const pending = listPendingSeqs().length;
    try {
      ctx?.ui?.setStatus?.(statusKey, pending > 0 ? `intake: ${pending} queued` : undefined);
    } catch {
      // Status is a courtesy; the record is the contract.
    }
  };

  // Hand one record to Pi. deliverAs follow-up queues it behind a running turn
  // and starts a run when idle. Acceptance is awaited so a refusal (compaction
  // in progress, no model) is seen here rather than lost.
  const deliver = async (record: IntakeRecord, ctx: IntakeContext | undefined): Promise<boolean> => {
    const wrapped = wrapIntake(record);
    inFlight.set(record.seq, wrapped);
    try {
      await pi.sendUserMessage(wrapped, { deliverAs: "followUp" });
      return true;
    } catch (error) {
      inFlight.delete(record.seq);
      notify(ctx, `intake #${record.seq} could not be queued: ${error instanceof Error ? error.message : String(error)}`, "warning");
      return false;
    }
  };

  const consumed = (text: string, ctx: IntakeContext | undefined) => {
    for (const [seq, wrapped] of inFlight) {
      if (wrapped !== text) continue;
      inFlight.delete(seq);
      moveRecord(seq, handledDir);
      refreshStatus(ctx);
      return;
    }
  };

  const release = (seq: number, ctx: IntakeContext | undefined) => {
    inFlight.delete(seq);
    if (moveRecord(seq, releasedDir)) {
      notify(ctx, `intake #${seq} was returned to your editor by the abort; it is kept at state/intake/released/${seq}.prompt and is not re-sent`, "warning");
    }
  };

  const resendPending = async (ctx: IntakeContext | undefined, why: string) => {
    for (const seq of listPendingSeqs()) {
      const record = readRecord(seq);
      if (!record) continue;
      if (await deliver(record, ctx)) notify(ctx, `intake #${seq} re-queued (${why})`);
    }
    refreshStatus(ctx);
  };

  const clearResendTimer = () => {
    if (resendTimer) clearTimeout(resendTimer);
    resendTimer = null;
  };

  pi.on("session_start", async (_event, ctx) => {
    clearResendTimer();
    inFlight.clear();
    sessionId = ctx.sessionManager?.getSessionId?.() ?? "";
    if (!intakeEnabled()) return;
    ensureDirs();
    if (listPendingSeqs().length > 0) await resendPending(ctx as IntakeContext, "left pending by the previous session");
    refreshStatus(ctx as IntakeContext);
  });

  pi.on("session_shutdown", () => {
    clearResendTimer();
  });

  pi.on("input", async (event, ctx) => {
    if (!intakeEnabled()) return { action: "continue" as const };
    if (!shouldCapture(event)) return { action: "continue" as const };
    const record: IntakeRecord = { seq: nextSeq(), at: new Date().toISOString(), body: event.text };
    try {
      writeRecord(record, sessionId);
    } catch (error) {
      // No durable record means no capture: Pi keeps its native steer, which
      // still delivers the prompt, and the captain is told why.
      notify(ctx as IntakeContext, `intake could not be recorded (${error instanceof Error ? error.message : String(error)}); delivering as a steer`, "warning");
      return { action: "continue" as const };
    }
    if (!(await deliver(record, ctx as IntakeContext))) {
      dropRecord(record.seq);
      return { action: "continue" as const };
    }
    notify(ctx as IntakeContext, `intake #${record.seq} queued; it is handled after the current turn and kept at state/intake/${record.seq}.prompt`);
    refreshStatus(ctx as IntakeContext);
    return { action: "handled" as const };
  });

  pi.on("message_start", (event, ctx) => {
    if (inFlight.size === 0) return;
    const message = event.message as { role?: string; content?: unknown };
    if (message.role !== "user") return;
    consumed(textOfContent(message.content), ctx as IntakeContext);
  });

  pi.on("before_agent_start", (event, ctx) => {
    if (inFlight.size === 0) return;
    if (event.messageType !== "user") return;
    consumed(event.prompt, ctx as IntakeContext);
  });

  pi.on("agent_settled", (event, ctx) => {
    if (inFlight.size === 0) return;
    const settledSeqs = [...inFlight.keys()];
    if (event.aborted) {
      for (const seq of settledSeqs) release(seq, ctx as IntakeContext);
      refreshStatus(ctx as IntakeContext);
      return;
    }
    clearResendTimer();
    resendTimer = setTimeout(() => {
      resendTimer = null;
      const still = settledSeqs.filter((seq) => inFlight.has(seq));
      if (still.length === 0) return;
      for (const seq of still) inFlight.delete(seq);
      void resendPending(ctx as IntakeContext, "not consumed by the settled turn");
    }, resendGraceMs);
  });

  pi.registerCommand("intake", {
    description: "List captain prompts captured mid-turn (pending, handled, released)",
    handler: async (_args, ctx) => {
      const pending = listPendingSeqs();
      const lines = [
        `captain intake: ${intakeEnabled() ? "on" : "off (create config/captain-intake to enable)"}`,
        `pending: ${pending.length === 0 ? "none" : pending.map((seq) => `#${seq}`).join(" ")}`,
        `handled: ${maxSeq(handledDir) || "none"} (latest) · released: ${maxSeq(releasedDir) || "none"} (latest) · records under ${intakeDir}`,
      ];
      notify(ctx as IntakeContext, lines.join("\n"));
    },
  });
}
