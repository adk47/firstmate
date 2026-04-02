import { readFile, writeFile, rename, mkdir } from "node:fs/promises";
import { join } from "node:path";
import type { IntercomSessionState } from "./types.js";

const CURRENT_VERSION = 1;
let sessionsFilePath = "";
let writeQueue: Promise<void> = Promise.resolve();

export async function initStateStore(stateDir: string): Promise<void> {
  const dir = join(stateDir, "plugins", "intercom");
  await mkdir(dir, { recursive: true });
  sessionsFilePath = join(dir, "sessions.json");
}



export async function loadSessions(): Promise<Map<string, Map<string, IntercomSessionState>>> {
  if (!sessionsFilePath) {
    throw new Error("[intercom:state-store] not initialized — call initStateStore() first");
  }
  const empty = new Map<string, Map<string, IntercomSessionState>>();

  let raw: string;
  try {
    raw = await readFile(sessionsFilePath, "utf8");
  } catch (err: any) {
    if (err?.code === "ENOENT") {
      return empty;
    }
    console.error(`[intercom:state-store] failed to read sessions file: ${err}`);
    throw err;
  }

  let parsed: any;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    console.warn(`[intercom:state-store] corrupt sessions file — starting fresh: ${err}`);
    return empty;
  }

  if (parsed?.version !== CURRENT_VERSION) {
    console.warn(
      `[intercom:state-store] unknown version ${parsed?.version} (expected ${CURRENT_VERSION}) — starting fresh`,
    );
    return empty;
  }

  const result = new Map<string, Map<string, IntercomSessionState>>();
  const sessions = parsed.sessions ?? {};
  for (const [accountId, convMap] of Object.entries(sessions)) {
    const inner = new Map<string, IntercomSessionState>();
    for (const [convId, state] of Object.entries(convMap as Record<string, IntercomSessionState>)) {
      inner.set(convId, state);
    }
    result.set(accountId, inner);
  }

  return result;
}

export async function saveSessions(
  sessions: Map<string, Map<string, IntercomSessionState>>,
): Promise<void> {
  if (!sessionsFilePath) {
    return; // Persistence not available — no-op
  }

  const obj: Record<string, Record<string, IntercomSessionState>> = {};
  for (const [accountId, convMap] of sessions) {
    const inner: Record<string, IntercomSessionState> = {};
    for (const [convId, state] of convMap) {
      inner[convId] = state;
    }
    obj[accountId] = inner;
  }

  // Serialize writes to prevent concurrent races on the .tmp file
  const doWrite = async () => {
    const data = JSON.stringify({ version: CURRENT_VERSION, sessions: obj }, null, 2);
    const tmpPath = sessionsFilePath + ".tmp";
    await writeFile(tmpPath, data, "utf8");
    await rename(tmpPath, sessionsFilePath);
  };

  writeQueue = writeQueue.then(doWrite, doWrite);
  return writeQueue;
}
