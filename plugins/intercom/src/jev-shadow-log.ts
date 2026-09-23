/**
 * Best-effort JSONL append to the shared Jev shadow log, in the exact row
 * shape scripts/lib/jev.sh's `_jev_shadow_log` writes (so
 * `scripts/jev-shadow-report.sh --surface caroline` works unchanged on rows
 * written from this in-process client). Writing the row is never allowed to
 * affect the primary action — any failure (missing dir, unwritable path,
 * lock timeout, missing flock binary) is a single warn, never a throw.
 *
 * Every row also carries the raw `state` object next to `state_sha256`, so a
 * misclassification can be replayed against Jev directly, unless
 * `storeState: false` (IntercomAccountConfig.jev.shadow.storeState, default
 * true) opts a specific call out and keeps only the hash.
 *
 * The append itself goes through the `flock` binary (`flock -w 5 <lock>
 * sh -c 'umask 077; cat >> "$1"' sh <file>`, row piped on stdin) rather than
 * Node's own fs.appendFile: Node has no native cross-process advisory lock,
 * and this is the SAME "<file>.lock" lock scripts/lib/jev.sh,
 * format-digest.sh, and jev-shadow-prune.sh's rewrite all take, so an append
 * from this process can never land mid-rewrite or interleave with another
 * writer's append. execFile is async throughout — this never blocks the
 * event loop. A lock that can't be taken within 5s (or the outer 6s
 * execFile timeout) is a warn, and the row is dropped rather than written
 * unlocked. If the `flock` binary itself is missing (ENOENT — expected on a
 * dev machine without util-linux), this falls back to a direct
 * fs.appendFile, once, with a single one-time warn so the fallback doesn't
 * spam every call.
 *
 * Shadow files hold customer message text, so they are created/kept at mode
 * 0600 — a looser-permission file left over from before this change is
 * tightened on the next append (fail-soft: a chmod failure never blocks the
 * write).
 */
import { appendFile, chmod, mkdir, stat } from "node:fs/promises";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { join } from "node:path";

const SHADOW_DIR = process.env.JEV_SHADOW_DIR ?? "/var/lib/hydra-jev/shadow";
const SURFACE = "caroline";
const SHADOW_FILE_MODE = 0o600;

// Set once the flock binary is confirmed missing, so the ENOENT fallback
// warns exactly once per process instead of on every append.
let warnedFlockMissing = false;

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
  // Default true — see IntercomAccountConfig.jev.shadow.storeState.
  storeState?: boolean;
}

async function ensureShadowFileMode(filePath: string, log?: { warn: (msg: string) => void }): Promise<void> {
  try {
    const info = await stat(filePath);
    if ((info.mode & 0o777) !== SHADOW_FILE_MODE) {
      await chmod(filePath, SHADOW_FILE_MODE);
    }
  } catch (err) {
    const code = (err as NodeJS.ErrnoException)?.code;
    if (code !== "ENOENT") {
      log?.warn(`[intercom:jev] shadow file mode check failed: ${err}`);
    }
  }
}

export async function appendJevShadowRow(
  input: JevShadowRowInput,
  log?: { warn: (msg: string) => void },
): Promise<void> {
  try {
    await mkdir(SHADOW_DIR, { recursive: true });
    const storeState = input.storeState ?? true;
    const row = {
      ts: new Date().toISOString(),
      surface: SURFACE,
      item_id: input.conversationId,
      state_sha256: sha256(JSON.stringify(input.state)),
      questions_sha256: sha256(JSON.stringify(input.questions)),
      state: storeState ? (input.state ?? null) : null,
      model: input.model,
      answers: input.answers ?? null,
      usage: input.usage ?? null,
      latency_ms: input.latencyMs,
      actual: input.actual,
      rc: input.rc,
      http: input.http,
      provider: input.provider ?? "openrouter",
    };
    const filePath = join(SHADOW_DIR, `${SURFACE}.jsonl`);
    const lockPath = `${filePath}.lock`;
    const line = `${JSON.stringify(row)}\n`;
    await ensureShadowFileMode(filePath, log);
    await appendRowLocked(filePath, lockPath, line, log);
  } catch (err) {
    log?.warn(`[intercom:jev] shadow log append failed: ${err}`);
  }
}

// Runs `flock -w 5 <lockPath> sh -c 'umask 077; cat >> "$1"' sh <filePath>`,
// piping `line` on the child's stdin. execFile has no "input" option (that's
// execFileSync-only), so this wraps it by hand rather than via
// util.promisify — doing so keeps this directly testable: tests stub
// node:child_process's execFile with a fake (file, args, options, callback)
// implementation and a fake child.stdin, with no dependency on promisify's
// undocumented `.child` passthrough.
function runFlockAppend(lockPath: string, filePath: string, line: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = execFile(
      "flock",
      ["-w", "5", lockPath, "sh", "-c", 'umask 077; cat >> "$1"', "sh", filePath],
      { timeout: 6000 },
      (err) => {
        if (err) reject(err);
        else resolve();
      },
    );
    child.stdin?.end(line);
  });
}

async function appendRowLocked(
  filePath: string,
  lockPath: string,
  line: string,
  log?: { warn: (msg: string) => void },
): Promise<void> {
  try {
    await runFlockAppend(lockPath, filePath, line);
  } catch (err) {
    const code = (err as NodeJS.ErrnoException)?.code;
    if (code === "ENOENT") {
      if (!warnedFlockMissing) {
        warnedFlockMissing = true;
        log?.warn(`[intercom:jev] flock binary not found -- falling back to a direct unlocked append`);
      }
      await appendFile(filePath, line, { encoding: "utf8", mode: SHADOW_FILE_MODE });
      return;
    }
    log?.warn(`[intercom:jev] shadow log append lock failed, row dropped: ${err}`);
  }
}
