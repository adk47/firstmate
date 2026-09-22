/**
 * Best-effort JSONL append to the shared Jev shadow log, in the exact row
 * shape scripts/lib/jev.sh's `_jev_shadow_log` writes (so
 * `scripts/jev-shadow-report.sh --surface caroline` works unchanged on rows
 * written from this in-process client). Writing the row is never allowed to
 * affect the primary action — any failure (missing dir, unwritable path) is
 * a single warn, never a throw.
 */
import { appendFile, mkdir } from "node:fs/promises";
import { createHash } from "node:crypto";
import { join } from "node:path";

const SHADOW_DIR = process.env.JEV_SHADOW_DIR ?? "/var/lib/hydra-jev/shadow";
const SURFACE = "caroline";

function sha256(input: string): string {
  return createHash("sha256").update(input, "utf8").digest("hex");
}

export interface JevShadowRowInput {
  conversationId: string;
  state: unknown;
  questions: unknown;
  model: string;
  provider?: string;
  answers: unknown;
  usage: unknown;
  latencyMs: number;
  actual: string;
  rc: 0 | 2 | 3;
  http: number | null;
}

export async function appendJevShadowRow(
  input: JevShadowRowInput,
  log?: { warn: (msg: string) => void },
): Promise<void> {
  try {
    await mkdir(SHADOW_DIR, { recursive: true });
    const row = {
      ts: new Date().toISOString(),
      surface: SURFACE,
      item_id: input.conversationId,
      state_sha256: sha256(JSON.stringify(input.state)),
      questions_sha256: sha256(JSON.stringify(input.questions)),
      model: input.model,
      answers: input.answers ?? null,
      usage: input.usage ?? null,
      latency_ms: input.latencyMs,
      actual: input.actual,
      rc: input.rc,
      http: input.http,
      provider: input.provider ?? "openrouter",
    };
    await appendFile(join(SHADOW_DIR, `${SURFACE}.jsonl`), `${JSON.stringify(row)}\n`, "utf8");
  } catch (err) {
    log?.warn(`[intercom:jev] shadow log append failed: ${err}`);
  }
}
