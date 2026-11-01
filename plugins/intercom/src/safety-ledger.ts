/**
 * Append-only JSONL ledger for the Caroline safety layer (caroline-guard-g1): inbound injection
 * hits (injection-watch.ts) and output-guard verdicts (caroline-output-guard.ts).
 *
 * One line per event, 0600 in a 0700 directory under /var/lib/hydra (survives deploys; /opt/hydra
 * is rsync-overwritten). Writing never throws into the reply path: a failed append is returned as
 * an error string for the caller to log as [intercom:ALERT]. The path is a constant (no env).
 */
import { appendFile, mkdir, chmod } from "node:fs/promises";
import { dirname } from "node:path";
import { createHash } from "node:crypto";

export const SAFETY_LEDGER_PATH = "/var/lib/hydra/injection-watch/ledger.jsonl";

export function emailSha256(email: string | null | undefined): string | null {
  const e = (email || "").trim().toLowerCase();
  if (!e.includes("@")) return null;
  // Same normalisation as scripts/credit_review/watchlist.py norm_email + sha.
  return createHash("sha256").update(e).digest("hex");
}

let dirReady = false;

/** Append one row. Returns null on success, the error text on failure (never throws). */
export async function appendSafetyLedger(row: Record<string, unknown>, path: string = SAFETY_LEDGER_PATH): Promise<string | null> {
  try {
    if (!dirReady || path !== SAFETY_LEDGER_PATH) {
      // Only the leaf directory is ever created: the parent (/var/lib/hydra) must already exist,
      // which it does on node-8 and does not on a laptop or a CI pod, so tests never write there.
      await mkdir(dirname(path), { recursive: false, mode: 0o700 }).catch((e: NodeJS.ErrnoException) => {
        if (e?.code !== "EEXIST") throw e;
      });
      if (path === SAFETY_LEDGER_PATH) dirReady = true;
    }
    await appendFile(path, `${JSON.stringify(row)}\n`, { encoding: "utf8", mode: 0o600 });
    await chmod(path, 0o600).catch(() => {});
    return null;
  } catch (err) {
    return String(err);
  }
}
