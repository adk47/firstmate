/**
 * Append-only JSONL ledger for the Caroline safety layer (caroline-guard-g1): inbound injection
 * hits (injection-watch.ts) and output-guard verdicts (caroline-output-guard.ts).
 *
 * One line per event, 0600 in a 0700 directory under /var/lib/hydra (survives deploys; /opt/hydra
 * is rsync-overwritten). Writing never throws into the reply path: a failed append is returned as
 * an error string for the caller to log as [intercom:ALERT]. The path is a constant (no env).
 *
 * Retention (30d) is enforced by the Python daily run, and it never rewrites this file: it renames it
 * to `ledger.jsonl.sealed-<timestamp>` and later deletes whole sealed generations, so an append here is
 * always either into the sealed generation or into a fresh file -- never into a file that gets rewritten.
 * Readers (scripts/lib/injection_watch.py `ledger_files()`) read the live file and every sealed generation.
 *
 * Deleting a generation and appending to one are SERIALIZED on a shared lock (`ledger.jsonl.ledger.lock`, an atomic
 * directory create -- a timestamp check before an unlink cannot be made safe against a writer holding the old inode,
 * QA on #1665). The append waits for the lock, and appends anyway (reporting an ALERT) if the lock cannot be had:
 * a dropped customer hit is worse than one unserialised append.
 */
import { appendFile, mkdir, chmod, rmdir, stat } from "node:fs/promises";
import { dirname } from "node:path";
import { createHash } from "node:crypto";

import { LEDGER_LOCK_STALE_MS, LEDGER_LOCK_SUFFIX, LEDGER_LOCK_WAIT_MS } from "./injection-watch.js";

export const SAFETY_LEDGER_PATH = "/var/lib/hydra/injection-watch/ledger.jsonl";

export function emailSha256(email: string | null | undefined): string | null {
  const e = (email || "").trim().toLowerCase();
  if (!e.includes("@")) return null;
  // Same normalisation as scripts/credit_review/watchlist.py norm_email + sha.
  return createHash("sha256").update(e).digest("hex");
}

let dirReady = false;

/**
 * The shared ledger lock: one atomic directory create next to the ledger (`<ledger>.ledger.lock`). Returns the lock
 * path when held, or null when it could not be taken in time -- the caller appends anyway and reports it, because a
 * dropped hit is worse than one unserialised append. The Python side takes the same lock for `append()` and for the
 * whole retention prune, which is what makes the prune's unlink safe against this writer (QA on #1665).
 */
async function acquireLedgerLock(path: string): Promise<string | null> {
  const lock = `${path}${LEDGER_LOCK_SUFFIX}`;
  const deadline = Date.now() + LEDGER_LOCK_WAIT_MS;
  for (;;) {
    try {
      await mkdir(lock, { mode: 0o700 });
      return lock;
    } catch (err) {
      const code = (err as NodeJS.ErrnoException)?.code;
      if (code !== "EEXIST") return null; // cannot lock at all (no dir / permissions): append anyway
      const stale = await stat(lock).then((s) => Date.now() - s.mtimeMs > LEDGER_LOCK_STALE_MS).catch(() => false);
      if (stale) {
        await rmdir(lock).catch(() => {}); // a crashed holder's lock
        continue;
      }
      if (Date.now() >= deadline) return null;
      await new Promise((r) => setTimeout(r, 5));
    }
  }
}

async function releaseLedgerLock(lock: string | null): Promise<void> {
  if (lock) await rmdir(lock).catch(() => {});
}

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
    const lock = await acquireLedgerLock(path);
    if (!lock) {
      console.error(`[intercom:ALERT] ledger lock busy (${LEDGER_LOCK_SUFFIX}); appending WITHOUT it: a ` +
        "concurrent prune could delete the generation this row lands in");
    }
    try {
      await appendFile(path, `${JSON.stringify(row)}\n`, { encoding: "utf8", mode: 0o600 });
    } finally {
      await releaseLedgerLock(lock);
    }
    await chmod(path, 0o600).catch(() => {});
    return null;
  } catch (err) {
    return String(err);
  }
}
