import { appendFile, mkdir, open } from "node:fs/promises";
import { createHash } from "node:crypto";
import { dirname, join } from "node:path";

// Durable record for the reader/actor gate (captain 2026-11-09 20:26Z, inbox 018 step 1:
// "a named actor executing, and the ledger row written ... show me that row").
//
// Append-only JSONL, one row per decision (allow, refuse, executed) - the row is what makes
// an action attributable when nobody was watching, so it is written BEFORE the actor runs
// (allow) and again after (executed/refused_by_actor). Never rewritten, never truncated by
// this module: a rollup may read it, nothing here deletes.
export const SUPPORT_INTENT_LEDGER_PATH = "/var/lib/hydra/support-intents/ledger.jsonl";

// Execution claims (QA #1873 r2, Important 3): one file per execution id, created with
// O_EXCL, so the SECOND attempt to perform the same confirmed intent - a retry after a
// lost ledger row, a model that emits the same intent twice in one turn, two gateway
// processes - finds the claim already taken and the gate refuses `duplicate_execution`.
// The claim is taken BEFORE the allow row and never released by this module: a human
// reconciles against the ledger, the gate never performs a customer write twice.
export const SUPPORT_INTENT_CLAIMS_DIR = "/var/lib/hydra/support-intents/claims";

export type SupportIntentLedgerRow = Record<string, unknown> & { ts: string; kind: "support_intent" };

export interface SupportIntentLedger {
  append(row: SupportIntentLedgerRow): Promise<void>;
}

export interface SupportIntentClaims {
  // true = this call took the claim; false = it was already held.
  claim(executionId: string, row: Record<string, unknown>): Promise<boolean>;
}

export function fileLedger(path: string = SUPPORT_INTENT_LEDGER_PATH): SupportIntentLedger {
  return {
    async append(row) {
      await mkdir(dirname(path), { recursive: true, mode: 0o750 });
      await appendFile(path, `${JSON.stringify(row)}\n`, { mode: 0o640 });
      // A write that silently failed is worse than no row: the caller decides what to do,
      // and the gate refuses the action when the ledger throws.
    },
  };
}

export function claimFileName(executionId: string): string {
  return `${createHash("sha256").update(executionId).digest("hex")}.json`;
}

export function fileClaims(dir: string = SUPPORT_INTENT_CLAIMS_DIR): SupportIntentClaims {
  return {
    async claim(executionId, row) {
      await mkdir(dir, { recursive: true, mode: 0o750 });
      const path = join(dir, claimFileName(executionId));
      let fh;
      try {
        // "wx" = O_CREAT | O_EXCL: exactly one caller ever succeeds for a given path.
        fh = await open(path, "wx", 0o640);
      } catch (err) {
        if ((err as NodeJS.ErrnoException)?.code === "EEXIST") return false;
        throw err;
      }
      try {
        await fh.writeFile(`${JSON.stringify({ execution_id: executionId, ...row })}\n`);
      } finally {
        await fh.close();
      }
      return true;
    },
  };
}
